# RFC-0014 Kustomize Transformers API

**Status:** provisional

**Creation date:** 2026-06-11

**Last update:** 2026-06-11

## Summary

This RFC proposes a new API called `Transformer` in the `kustomize.toolkit.fluxcd.io`
group that allows Kustomize transformer configurations to be sourced, versioned and
reused as build inputs by Flux `Kustomization` objects. A `Transformer` materializes
a set of Kustomize transformer manifests (e.g. `PrefixSuffixTransformer`,
`ImageTagTransformer`, `ReplacementTransformer`) from a Flux source, and a
`Kustomization` selects transformers by explicit reference or by label selector.
The selected transformers are applied to the build output of the `Kustomization`
before the resulting manifests are applied to the cluster.

Transformers are build inputs, not cluster objects: their content is never applied
to the cluster directly.

## Motivation

Kustomize transformers in their full specification form are significantly more
expressive than the convenience fields exposed by `kustomization.yaml` and by the
Flux `Kustomization` API (`spec.patches`, `spec.images`, `spec.commonMetadata`).
A full transformer spec supports custom `fieldSpecs`, which enables use cases such as:

- applying a name prefix or suffix only to a limited set of resource kinds and
  reference fields, instead of every name field in the build;
- running an `ImageTagTransformer` against non-standard fields — a very common
  scenario for operators that store image references in annotations, config blobs
  or custom resource fields;
- targeted label and annotation propagation into nested fields that the built-in
  `commonLabels`/`commonAnnotations` defaults do not cover;
- propagating whole structured values with `ReplacementTransformer` — the power
  tool of the set: it deep-copies entire subtrees (e.g. a complete
  `securityContext`) from a source resource into selected targets, and it is the
  only builtin transformer capable of modifying lists of objects in bulk via
  wildcard `fieldPaths` (e.g. `spec.template.spec.containers.*.securityContext`),
  something neither JSON6902 nor strategic-merge patches can express.

Today, Flux users who need this level of control have two options, both with
significant drawbacks:

1. **Pure-transformer overlays.** Every application/environment combination gets a
   Kustomize overlay whose only purpose is to attach a set of transformers to a base.
   This leads to directory sprawl and duplication: the same transformer set is copied
   into every overlay that needs it, and the Kustomize load restrictor prevents
   sharing transformer files across directory trees, let alone across source
   artifacts.

2. **`spec.components`.** Components can carry transformers, but they are resolved
   relative to the `Kustomization` source artifact, so they cannot be shared across
   sources. They also couple transformer ordering to the component accumulation
   order and have no independent lifecycle: there is no way to version, validate or
   observe a transformer set on its own.

The duplication problem is most acute when deployments span several sources, e.g.
application manifests delivered via `OCIRepository` and environment configuration
via `GitRepository`. Since Kustomize cannot reference files across artifact
boundaries, the transformer set must be vendored into every source, and keeping the
copies in sync becomes a manual process. Composing artifacts from several sources
via a 3rd party `ExternalArtifact` controller can partially mitigate this, but at
the cost of reduced visibility and added source management complexity — different
transformer sets have to be mounted at the same path across composed artifacts
(see Alternatives).

A dedicated `Transformer` API lets transformer sets be sourced, versioned and
selected like applications: defined once, validated independently, and consumed by
any number of `Kustomizations` across sources and tenants.

### Goals

- Define a Flux API for declaring reusable sets of Kustomize transformers backed by
  Flux sources (`GitRepository`, `OCIRepository`, `Bucket`, `ExternalArtifact`).
- Extend the Flux `Kustomization` API to consume transformers by explicit reference
  and by label selector, with deterministic ordering and dedup semantics.
- Reduce the number of pure-transformer overlays in user repositories.
- Deduplicate transformer sets across overlays, repositories and source artifacts.
- Expose the full expressiveness of Kustomize transformer specs (custom
  `fieldSpecs`) without growing the `Kustomization` API field by field.
- Preserve Kustomize semantics: applying the resolved transformers must be
  equivalent in behavior to the `transformers:` directive in a
  `kustomization.yaml`.

### Non-Goals

- Provide a general plugin mechanism. Exec/container KRM functions and other
  non-builtin transformer plugins are out of scope for the initial version.
- Apply transformer content to the cluster. `Transformer` artifacts are consumed
  at build time only.
- Replace the existing `spec.patches`, `spec.images`, `spec.components` or
  `spec.postBuild` fields. These remain unchanged and fully supported.
- Cross-namespace label selectors. In the initial version, selectors only match
  `Transformer` objects in the namespace of the `Kustomization`.
- Generate or template transformer content. The `Transformer` reconciler fetches
  and validates existing manifests; authoring stays in Git/OCI.

## Proposal

### The `Transformer` API

A new namespaced custom resource `Transformer` is added to
`kustomize.toolkit.fluxcd.io` and reconciled by `kustomize-controller`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1alpha1
kind: Transformer
metadata:
  name: staging-name-prefix
  namespace: apps
  labels:
    app.kubernetes.io/part-of: storefront
    environment: staging
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository # GitRepository | OCIRepository | Bucket | ExternalArtifact
    name: app-config
  path: ./transformers/env/staging/prefix
  # Restrict which transformer kinds the path may emit.
  # When unset, all Kustomize builtin transformer kinds are accepted.
  allowedKinds:
    - PrefixSuffixTransformer
    - PatchTransformer
status:
  conditions:
    - type: Ready
      status: "True"
      reason: Succeeded
      message: "validated 2 transformers from revision main@sha1:..."
  lastValidatedRevision: main@sha1:b7c3e2...
  transformers:
    - apiVersion: builtin
      kind: PrefixSuffixTransformer
      name: staging-prefix
```

On each reconciliation, `kustomize-controller`:

1. resolves `spec.sourceRef` and fetches the source artifact;
2. loads the manifests at `spec.path` — either plain transformer YAML files, or a
   Kustomize root that is built first (allowing transformer sets that are
   themselves composed with Kustomize);
3. validates that the result contains only Kustomize transformer resources, and
   only kinds permitted by `spec.allowedKinds`;
4. records the validated revision and the inventory of transformer objects in the
   status, and marks the object `Ready`.

A `Transformer` that emits non-transformer resources, or kinds outside the allow
list, is marked not `Ready` and is never consumed by `Kustomizations`.

### Consuming transformers from a `Kustomization`

The Flux `Kustomization` API gains three optional fields: `transformers` for
explicit references, `transformerSelectors` for label-based selection, and
`transformersPolicy` for resolution behavior:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: storefront-staging
  namespace: apps
spec:
  interval: 10m
  prune: true
  sourceRef:
    kind: OCIRepository
    name: storefront
  path: ./deploy
  transformers:
    - name: staging-name-prefix
    - name: team-labels
      namespace: shared-transformers
  transformerSelectors:
    - matchLabels:
        tenant: acme
        environment: staging
  transformersPolicy:
    failOnMissing: true
```

#### Resolution semantics

1. **Order:** explicit `transformers` are applied in list order, followed by the
   matches of each entry in `transformerSelectors` (matches within a selector are
   sorted by name for determinism).
2. **Dedup:** a `Transformer` matched both by reference and by selector (or by
   multiple selectors) is applied exactly once, at its first position.
3. **Selector scope:** selectors match only `Transformer` objects in the namespace
   of the `Kustomization`. Explicit references may target other namespaces, subject
   to the same cross-namespace access controls as `sourceRef`
   (`--no-cross-namespace-refs`).
4. **failOnMissing:** when `true` (default), reconciliation fails if a referenced
   `Transformer` does not exist or is not `Ready`, and if a selector matches zero
   objects. When `false`, missing references and empty selector results are
   skipped — this enables optional per-tenant or per-environment transformer packs.
5. **Observability:** the `Kustomization` status records the resolved transformer
   set, including whether each entry was selected explicitly or via a selector.

#### Build pipeline

The resolved transformers are applied to the fully built resource set — after
`kustomize build` of `spec.path` (which already includes `spec.components`,
`spec.patches`, `spec.images` and `spec.commonMetadata`) and before
`spec.postBuild` substitutions:

```text
source artifact @ revision
  → kustomize build spec.path (components, patches, images included)
  → apply resolved Transformer sets (in resolution order)
  → postBuild variable substitution
  → server-side apply
```

This is implemented as a second Kustomize pass with a synthetic
`kustomization.yaml` that lists the build output (plus any `local-config`
companion resources shipped with the transformer sets) under `resources:` and the
resolved transformer manifests under `transformers:`, preserving exact Kustomize
semantics including custom `fieldSpecs`.

Whenever a consumed `Transformer` changes (new validated revision), all
`Kustomizations` referencing it are requeued, mirroring the existing
source-change fan-out behavior.

### User Stories

#### Story 1: Org-wide labels without per-app overlays

> As a platform engineer, I maintain a mandatory set of label and annotation
> transformers (cost-center, team ownership, compliance markers) with custom
> `fieldSpecs` that reach into pod templates and operator CRs. I want every tenant
> `Kustomization` to consume them without copying transformer files into each
> tenant repository.

The platform team keeps the transformer set in a fleet repository:

```yaml
# fleet-config repository: ./transformers/org-labels/labels.yaml
apiVersion: builtin
kind: LabelTransformer
metadata:
  name: org-labels
labels:
  example.com/cost-center: cc-1042
  example.com/compliance: pci-dss
fieldSpecs:
  - path: metadata/labels
    create: true
  - kind: Deployment
    path: spec/template/metadata/labels
    create: true
  - kind: ExampleOperator
    path: spec/workload/metadata/labels
    create: true
```

and exposes it once as a `Transformer`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1alpha1
kind: Transformer
metadata:
  name: org-labels
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: fleet-config
  path: ./transformers/org-labels
```

Tenant `Kustomizations` reference it without copying any files:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: storefront
  namespace: tenant-a
spec:
  interval: 10m
  prune: true
  sourceRef:
    kind: GitRepository
    name: storefront
  path: ./deploy/production
  transformers:
    - name: org-labels
      namespace: flux-system
```

Updating the transformer set in the fleet repository rolls it out to all
consumers on their next reconciliation.

#### Story 2: Image overrides in non-standard fields

> As an operator of a third-party Kubernetes operator, the operand image is
> configured via a custom resource field and an annotation, not via a standard
> `spec.containers[].image` path. I want to retarget those images to my private
> registry across all environments.

A single transformer file covers the standard and non-standard image locations,
including an annotation key (escaped `/`) and custom resource fields:

```yaml
# fleet-config repository: ./transformers/operand-images/images.yaml
apiVersion: builtin
kind: ImageTagTransformer
metadata:
  name: operand-images
imageTag:
  name: ghcr.io/example/operand
  newName: registry.internal.example.com/mirror/operand
  newTag: 1.25.3
fieldSpecs:
  - kind: ExampleOperator
    path: spec/operandImage
  - kind: ExampleOperator
    path: spec/sidecars/image
  - kind: Deployment
    path: metadata/annotations/example.com\/operand-image
```

Exposed as a `Transformer` named `operand-images`, it is referenced from every
environment `Kustomization`:

```yaml
spec:
  transformers:
    - name: operand-images
      namespace: flux-system
```

Today this requires a per-environment pure-transformer overlay whose only purpose
is to host the transformer file.

#### Story 3: Security baseline propagation in bulk

> As a platform security engineer, I must enforce a hardened `securityContext`
> (drop all capabilities, no privilege escalation, read-only rootfs) on every
> container of every workload, including sidecars injected by third-party bases I
> cannot edit.

The transformer set ships the baseline as a companion resource annotated with
`config.kubernetes.io/local-config` — per Kustomize semantics it is available as
a replacement source during the build and pruned from the output — together with
a `ReplacementTransformer` that fans it out:

```yaml
# fleet-config repository: ./transformers/security-baseline/baseline.yaml
apiVersion: config.example.com/v1
kind: SecurityBaseline
metadata:
  name: restricted
  annotations:
    config.kubernetes.io/local-config: "true"
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

```yaml
# fleet-config repository: ./transformers/security-baseline/replacement.yaml
apiVersion: builtin
kind: ReplacementTransformer
metadata:
  name: security-baseline
replacements:
  - source:
      kind: SecurityBaseline
      name: restricted
      fieldPath: securityContext
    targets:
      - select:
          kind: Deployment
        fieldPaths:
          - spec.template.spec.containers.*.securityContext
        options:
          create: true
      - select:
          kind: StatefulSet
        fieldPaths:
          - spec.template.spec.containers.*.securityContext
        options:
          create: true
```

The replacement deep-copies the entire `securityContext` object, and the wildcard
`fieldPaths` cover every element of the container list regardless of its length —
something neither strategic-merge nor JSON6902 patches can do generically.
Published once as a labeled `Transformer`, the baseline is consumed by every
tenant `Kustomization` via a selector:

```yaml
spec:
  transformerSelectors:
    - matchLabels:
        policy.example.com/security-baseline: "true"
```

#### Story 4: Scoped prefixing across multiple sources

> As a Flux user deploying the same application from an `OCIRepository` into
> several staging namespaces, I want to prefix only `Deployments`, `Services` and
> their cross-references — not every named resource — and I cannot modify the OCI
> artifact contents.

A `PrefixSuffixTransformer` with restricted `fieldSpecs` lives in the
configuration Git repository, prefixing only the selected kinds and keeping
cross-references (here, the Ingress backend) consistent:

```yaml
# app-config repository: ./transformers/staging-prefix/prefix.yaml
apiVersion: builtin
kind: PrefixSuffixTransformer
metadata:
  name: staging-prefix
prefix: stage1-
fieldSpecs:
  - kind: Deployment
    path: metadata/name
  - kind: Service
    path: metadata/name
  - kind: Ingress
    path: spec/rules/http/paths/backend/service/name
```

Each staging `Kustomization` builds from the OCI artifact while consuming the
transformer from the Git-backed `Transformer` — composition across source
boundaries that plain Kustomize forbids:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: storefront-stage1
  namespace: staging
spec:
  interval: 10m
  prune: true
  sourceRef:
    kind: OCIRepository
    name: storefront
  path: ./deploy
  targetNamespace: stage1
  transformers:
    - name: staging-prefix
```

No pure-transformer overlay and no vendoring of transformer files into the OCI
artifact is needed.

#### Story 5: Optional tenant packs via selectors

> As a multi-tenant platform operator, some tenants ship an optional set of
> replacement transformers. I want tenant `Kustomizations` to pick them up when
> present and proceed without them otherwise.

The platform-managed tenant `Kustomization` selects optional packs with
`failOnMissing: false`; tenants opt in by creating labeled `Transformer` objects
in their namespace:

```yaml
# Tenant opt-in: a labeled Transformer in the tenant namespace
apiVersion: kustomize.toolkit.fluxcd.io/v1alpha1
kind: Transformer
metadata:
  name: acme-replacements
  namespace: tenant-acme
  labels:
    example.com/tenant-pack: "true"
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: acme-config
  path: ./transformers
---
# Platform-managed Kustomization, identical for every tenant
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: acme-apps
  namespace: tenant-acme
spec:
  interval: 10m
  prune: true
  sourceRef:
    kind: GitRepository
    name: acme-apps
  path: ./deploy
  transformerSelectors:
    - matchLabels:
        example.com/tenant-pack: "true"
  transformersPolicy:
    failOnMissing: false
```

Tenants without a pack reconcile unchanged; creating the labeled `Transformer`
is the only opt-in step.

### Alternatives

#### Keep using pure-transformer overlays

The status quo. It works but scales poorly: the number of overlays grows with the
product of applications and environments, transformer files are duplicated across
directory trees and source artifacts, and the Kustomize load restrictor prevents
sharing. This RFC exists to eliminate exactly this pattern.

#### Extend `spec.components`

Components can already carry transformers, but they are resolved within the
`Kustomization` source artifact and cannot span sources. Making components
source-addressable would conflate two concepts (resource accumulation and
transformation) and inherit Kustomize component ordering semantics that are
ill-suited for the "apply this transformer set to the final build output" use
case.

#### Grow the `Kustomization` convenience fields

`spec.images`, `spec.patches` and `spec.commonMetadata` could be extended with
`fieldSpecs` support. This would re-implement a growing subset of the Kustomize
transformer configuration surface inside the Flux API, field by field, and would
still not solve deduplication across `Kustomizations` and sources.

#### Inline transformer definitions

Instead of `sourceRef`, the `Transformer` spec could embed transformer manifests
inline. This loses Git/OCI versioning and review of transformer content and makes
the cluster API the source of truth, which conflicts with GitOps principles. An
additive `spec.inline` mode could be considered later for trivial cases; it is out
of scope for the initial version.

#### Share transformers via `ExternalArtifact` or OCI artifacts

Transformer files can be distributed as OCI artifacts today, but consuming them
still requires an overlay that references the files locally — which the load
restrictor forbids across artifacts. A 3rd party `ExternalArtifact` controller
could compose application manifests and transformer sets from several sources
into a single artifact, working around the restrictor. This shifts the problem
rather than solving it: every transformer-set variant has to be mounted at the
same well-known path inside the composed artifact, composition logic lives
outside Flux with reduced visibility (no per-transformer status, readiness or
trace), and source management complexity grows with each app/transformer
combination. Distribution is not the gap; build-time composition is.

## Design Details

The `Transformer` API will be added to `kustomize-controller/api` under version
`v1alpha1` and reconciled by `kustomize-controller`. No new controller is
introduced.

The CRD will be bundled with the `kustomize-controller` CRDs in the standard Flux
distribution and documented under the `kustomize.toolkit.fluxcd.io` API reference.

### API additions

```go
// TransformerSpec defines a set of Kustomize transformers
// materialized from a Flux source.
type TransformerSpec struct {
	// +required
	Interval metav1.Duration `json:"interval"`

	// +required
	SourceRef CrossNamespaceSourceReference `json:"sourceRef"`

	// Path to a directory containing transformer manifests or a
	// Kustomize root that emits only transformer resources.
	// +optional
	Path string `json:"path,omitempty"`

	// AllowedKinds restricts which builtin transformer kinds
	// the path may emit. When empty, all builtin transformer
	// kinds are accepted.
	// +optional
	AllowedKinds []string `json:"allowedKinds,omitempty"`
}

// TransformerReference refers to a Transformer object.
type TransformerReference struct {
	// +required
	Name string `json:"name"`

	// +optional
	Namespace string `json:"namespace,omitempty"`
}

// TransformerSelector selects Transformer objects by labels
// in the namespace of the Kustomization.
type TransformerSelector struct {
	// +optional
	MatchLabels map[string]string `json:"matchLabels,omitempty"`
}

// TransformersPolicy configures transformer resolution behavior.
type TransformersPolicy struct {
	// FailOnMissing fails the reconciliation when a referenced
	// Transformer is missing or not ready, or when a selector
	// matches no objects. Defaults to true.
	// +optional
	FailOnMissing *bool `json:"failOnMissing,omitempty"`
}

// KustomizationSpec additions:
type KustomizationSpec struct {
	// ... existing fields ...

	// +optional
	Transformers []TransformerReference `json:"transformers,omitempty"`

	// +optional
	TransformerSelectors []TransformerSelector `json:"transformerSelectors,omitempty"`

	// +optional
	TransformersPolicy *TransformersPolicy `json:"transformersPolicy,omitempty"`
}
```

Explicit references and label selectors are split into two list fields to avoid
`oneOf` semantics per list item.

### Validation

The `Transformer` reconciler accepts only Kustomize builtin transformer kinds
(`PrefixSuffixTransformer`, `LabelTransformer`, `AnnotationsTransformer`,
`ImageTagTransformer`, `ReplacementTransformer`, `PatchTransformer`,
`PatchStrategicMergeTransformer`, `PatchJson6902Transformer`,
`NamespaceTransformer`, `ReplicaCountTransformer`, `HashTransformer`).

One exception is made for companion data resources annotated with
`config.kubernetes.io/local-config: "true"`: they are accepted alongside
transformers to serve as replacement sources and, per standard Kustomize
semantics, are pruned from the build output and never applied to the cluster.

Any other resource at `spec.path` fails validation. Exec and container KRM
function annotations are rejected. CEL validation rules on the CRD enforce that
`allowedKinds` entries belong to the builtin set.

### Revision coupling

At `Kustomization` build time, the controller fetches the source artifact of each
resolved `Transformer` from source-controller storage at the revision recorded in
`Transformer.status.lastValidatedRevision` and renders the transformer set
deterministically. No new artifact storage endpoint is introduced; the existing
source artifact distribution and digest verification are reused.

### Multi-tenancy and security

- Cross-namespace explicit references are subject to the existing
  `--no-cross-namespace-refs` flag, consistent with `sourceRef` handling.
- Label selectors are namespace-local by design, preventing tenants from
  selecting transformers they do not own.
- When a service account is impersonated via `Kustomization.spec.serviceAccountName`,
  access to referenced `Transformer` objects is checked with the impersonated
  identity.
- Transformer content can mutate any field of the build output; consuming a
  `Transformer` requires the same level of trust as consuming a source. Cluster
  administrators can restrict `Transformer` creation with standard RBAC and
  validating admission policies.

### Feature gate

The feature will be gated behind a `Transformers` feature gate on
`kustomize-controller`, disabled by default in the `v1alpha1` phase:

- With the gate disabled, the new `Kustomization` fields are ignored and a warning
  event is emitted if they are set; existing behavior is unchanged.
- Enabling the gate changes no behavior for `Kustomizations` that do not set the
  new fields.
- Disabling the gate after use causes `Kustomizations` with transformer references
  to reconcile without them (with a warning event), never to fail; whether a
  build silently diverges from the desired state is mitigated by the warning
  events and a dedicated status condition.
- Operators can detect usage via the `Kustomization` status (resolved transformer
  set) and controller metrics labeled by feature.

### CLI

- `flux get transformers` lists `Transformer` objects with readiness and revision.
- `flux reconcile transformer` and `flux suspend/resume transformer` follow the
  existing command patterns.
- `flux build kustomization` and `flux diff kustomization` resolve `Transformer`
  references from the cluster; a `--local-transformers <dir>` flag allows offline
  builds by mapping transformer names to local directories.
- `flux tree` and `flux trace` are extended to surface `Transformer` dependencies.

### Drawbacks

- A `Kustomization` build is no longer reproducible from its source artifact
  alone; the resolved transformer revisions are part of the build input. This is
  mitigated by recording the full resolved set (names, revisions, digests) in the
  `Kustomization` status.
- Label selectors introduce action-at-a-distance: creating a labeled `Transformer`
  changes the output of existing `Kustomizations`. This is by design (opt-in via
  selectors) and namespace-scoped, but must be prominently documented.
- Additional watches and fan-out (one `Transformer` to many `Kustomizations`)
  increase controller load; the implementation reuses the existing source
  index/requeue machinery.

## Implementation History

<!-- To be filled once an initial implementation is available in a release. -->
