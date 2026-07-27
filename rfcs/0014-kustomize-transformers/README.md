# RFC-0014 Kustomize Transformers API

**Status:** provisional

**Creation date:** 2026-06-11

**Last update:** 2026-07-27

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

Full-spec Kustomize transformers already work inside a single Flux `Kustomization`
today: any `PrefixSuffixTransformer`, `ImageTagTransformer`,
`ReplacementTransformer` or `LabelTransformer` can be listed under `transformers:`
in the built `kustomization.yaml`, or carried in a `spec.components` entry. This
RFC does not add a missing capability — it addresses **reuse**.

The reason fleets reach for these transformers is that in their full specification
form they are significantly more expressive than the convenience fields exposed by
the Flux `Kustomization` API (`spec.patches`, `spec.images`,
`spec.commonMetadata`). A full transformer spec supports custom `fieldSpecs`,
which enables use cases such as:

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

The capability, then, is not the gap. The gap is defining such a transformer set
once and consuming it from many `Kustomizations` across sources and tenants
without copying files. Today, Flux users who need to share a transformer set this
way have two options, both with significant drawbacks:

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
with an `ArtifactGenerator` can partially mitigate this, but it co-locates files
in a single artifact tree, which is a different operation than composing
transformer sets at build time: the composed set is fixed at generation time, and
independently authored sets whose companion resources share an identity cannot be
combined at all (see Alternatives).

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
- Preserve Kustomize transformer semantics: the resolved transformers must behave
  as a `transformers:` directive applied to the **final build output**, including
  support for custom `fieldSpecs`. This is a chain of Kustomize passes over the
  built output — one per resolved `Transformer`, so that independently authored
  sets never share an accumulator — rather than an inlining into the source
  `kustomization.yaml`; the distinction and its consequences are documented in
  Build pipeline and Drawbacks.

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
   themselves composed with Kustomize). When the path is built as a Kustomize
   root, the materialization build runs with the resource factory's
   `IncludeLocalConfigs` option enabled so that bundled `local-config` companion
   resources (replacement sources) survive materialization instead of being
   pruned by the default local-config handling; there is no `kustomize build` CLI
   flag for this, so `kustomize-controller` sets the krusty API option directly;
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
5. **No-op detection:** each resolved transformer set is expected to change the
   build output. A set whose pass leaves the output byte-identical to its input
   (it selected nothing) is recorded in status and, when
   `transformersPolicy.failOnNoop` is `true`, fails the reconciliation. This turns
   the silent-miss mode — a policy set that quietly matches nothing after an
   upstream rename — into an actionable error. Defaults to `false`, so additive
   and optional packs that legitimately match nothing on some builds stay valid.
6. **Observability:** the `Kustomization` status records the resolved transformer
   set, including whether each entry was selected explicitly or via a selector,
   and flags any set detected as a no-op.

#### Build pipeline

The resolved transformers are applied to the fully built resource set — after
`kustomize build` of `spec.path` (which already includes `spec.components`,
`spec.patches`, `spec.images` and `spec.commonMetadata`) and before
`spec.postBuild` substitutions:

```text
source artifact @ revision
  → kustomize build spec.path (components, patches, images included)
  → for each resolved Transformer, in resolution order:
        one Kustomize pass over a synthetic kustomization.yaml:
          resources:    [output of the previous step]
                        + [that Transformer's local-config companions]
          transformers: [that Transformer's manifests]
        → IgnoreLocal prunes that Transformer's companions from the pass output
  → postBuild variable substitution
  → server-side apply
```

Each resolved `Transformer` is applied in **its own Kustomize pass**, driven by a
synthetic `kustomization.yaml`. Kustomize transformer semantics, including custom
`fieldSpecs`, are preserved within each pass; resolution order is pass order.

Per-transformer passes are a design decision rather than an implementation
detail: they are what makes independently authored transformer sets composable.
Kustomize enforces resource identity uniqueness on the accumulator, and
`local-config` companions occupy an accumulator slot by GVK+name even though they
are pruned from the output. Two policy packs that both ship a companion named
`SecurityBaseline/restricted` — a naming convention, not a coincidence — can
therefore never be accumulated into a single resmap:

```text
may not add resource with an already registered id:
SecurityBaseline.v1.config.example.com/restricted.[noNs]
```

Every composition model that co-locates transformer sets into one build inherits
that failure — a single merged pass, `spec.components`, or file-level artifact
composition — and it surfaces only at compose time, since each pack validates
green on its own. With one pass per `Transformer` the packs never share an
accumulator: a companion is visible only to the transformers shipped alongside
it and is pruned again at the end of that pass, so both packs apply, with later
passes overriding earlier ones on fields they both write. The same property makes
ordering a per-consumer decision: two `Kustomizations` can consume the same two
`Transformers` in opposite order without either set being duplicated.

Because the transformers run in passes over the built output, they operate on the
final result of `spec.path` — after generators, name-hash finalization,
namespacing and the consumer's own transformers (`spec.components`,
`spec.patches`, `spec.images`, `spec.commonMetadata`) have already been applied.
This is the intended behavior ("apply this transformer set to the final build
output"), but it is deliberately **not** a 1:1 substitute for inlining the same
transformers under `transformers:` in the source `kustomization.yaml`, where they
would run before name-hash finalization and could interleave with the other
transformers. See Drawbacks.

This post-build timing is a property of the second-pass **implementation**, not
of the design. Per-set isolation comes from materializing each set against its
own accumulator — not from *when* the pass runs — so the two properties are
independent: a future implementation could apply each resolved set at its
canonical, pre-hash position in the Kustomize pipeline and remain equally
collision-free. The `v1alpha1` contract commits only to "apply each set to the
built output"; narrowing the divergence this way is left open as a compatible
refinement rather than precluded by the API.

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

> As a platform engineer, I want to propagate a hardened `securityContext` (drop
> all capabilities, no privilege escalation, read-only rootfs) into every
> container of the workloads these `Kustomizations` manage — including sidecars
> injected by third-party bases I cannot edit — from a single definition, using
> the one transformer able to deep-copy a structured value across a
> variable-length container list.

This is bulk propagation into managed manifests, not admission-time enforcement:
workloads created outside these `Kustomizations` are untouched, and a cluster-wide
guarantee remains the job of a validating admission policy. What the transformer
set buys is expressing the fan-out once — with `ReplacementTransformer`'s wildcard
`fieldPaths` — instead of copying the baseline into every overlay that needs it.

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

#### Compose sources with an `ArtifactGenerator`

Transformer files can be distributed as OCI artifacts today, but consuming them
still requires an overlay that references the files locally — which the load
restrictor forbids across artifacts. An `ArtifactGenerator`
(`source.extensions.fluxcd.io/v1beta1`, source-watcher) can copy application
manifests and transformer files from several sources into one `ExternalArtifact`,
working around the restrictor. Distribution is not the gap, though — build-time
composition is, and file-level co-location is not the same operation:

- **Composition is static and centrally owned.** `spec.sources` and the `copy`
  list enumerate the inputs at generation time, in an object owned by whoever owns
  the generator. There is no equivalent of a label selector, so a tenant cannot
  contribute a transformer pack without a commit to a platform-owned object, and
  every application/transformer-set combination needs its own artifact — each a
  full copy of the application, all regenerated whenever any pack changes.
- **Consuming still needs an overlay.** A generated artifact is a directory tree;
  something inside it must list the transformer files under `transformers:`. For a
  vendor-published application root that does not, that means committing a wrapper
  kustomization per combination — the pure-transformer overlay this RFC removes,
  relocated rather than eliminated. The `Merge` copy strategy can inject the key
  into an existing `kustomization.yaml`, but merge replaces arrays wholesale, so it
  silently drops any `transformers:` list the upstream later adds.
- **Co-location breaks independently authored sets.** Everything ends up in a
  single `kustomize build`, so two packs whose companion resources share an
  identity fail with `may not add resource with an already registered id`, and
  packs whose assumptions interact — a rename pack rewriting the labels a policy
  pack selects on — resolve by file order rather than per-consumer intent, with a
  successful build and a silently missing policy as the failure mode. The
  `Transformer` model orders sets per consumer and surfaces that miss via
  `failOnNoop`. See Build pipeline.
- **No per-set lifecycle.** The composed artifact has a single revision covering
  all inputs, with no per-transformer readiness, status or trace.

The two APIs are complementary rather than competing: `ExternalArtifact` is a
valid `Transformer.spec.sourceRef` kind, so a generated artifact can back a
transformer set that is then composed per consumer.

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

	// FailOnNoop fails the reconciliation when a resolved transformer
	// set produces output identical to its input (it selected nothing).
	// Defaults to false.
	// +optional
	FailOnNoop *bool `json:"failOnNoop,omitempty"`
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

### Versioning and canary rollout

Because consumers follow the `Transformer` object and the `Transformer` follows
only what its `sourceRef` resolves to, the object is the version pin. Pointing a
`Transformer` at an immutable ref (an OCI digest or a Git tag) means a change to
the underlying transformer files does not reach any consumer until the
`Transformer`'s pinned ref is advanced — closing the "one edit to a shared set
silently reconfigures the whole fleet" hazard. A bad edit that fails validation
leaves the `Transformer` not `Ready`, and with `failOnMissing: true` consumers
fail loudly rather than applying a broken set.

Canary rollout builds on the same property. To trial a new revision of a widely
consumed set, publish it as a second `Transformer` (e.g. `org-labels-next`)
pinned to the new ref and move a subset of consumers — or a subset of selector
labels — onto it. Once validated, advance the original `Transformer`'s pin (or
relabel) and retire the canary. Every consumer records the resolved names and
revisions in status, so the blast radius of a change is observable before and
after it is made.

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
  references from the cluster and reproduce the controller's output exactly,
  sharing the resolution and pass logic in `fluxcd/pkg/kustomize` so the CLI and
  the controller cannot diverge.
- `--local-transformers <name>=<dir>` maps transformer references to local
  directories for offline builds. It fails closed: a reference that is neither
  resolvable from the cluster nor mapped locally is an error, never a silent skip,
  so an offline build never omits a transformer set without saying so.
- `flux tree` and `flux trace` are extended to surface `Transformer` dependencies.

### Local build convergence

Reproducing a controller build locally is a `v1alpha1` requirement, not a
follow-up. `flux build kustomization` resolves and applies the same transformer
set through the same `fluxcd/pkg/kustomize` code path the controller uses, so its
output is byte-identical to what the controller applies — with the single existing
exception of `spec.postBuild` substitutions sourced from cluster Secrets and
ConfigMaps, which `flux build` already cannot reproduce offline. The
`--local-transformers` mapping keeps this working with no cluster access and fails
closed on any unmapped reference, so the offline path can never diverge by
silently dropping a set.

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
- Transformer application is a chain of Kustomize passes over the built output, not
  an inlining into the source `kustomization.yaml`. Resolved transformers always
  run after generators, name-hash finalization, namespacing and the consumer's own
  transformers, and cannot be interleaved with them. For the overwhelming majority
  of transformer kinds and `fieldSpecs` this is behaviorally indistinguishable, but
  it is not a byte-for-byte 1:1 mapping to listing the same transformers under
  `transformers:` in the original kustomization: the model optimizes for "apply
  this set to the final build output" rather than full single-pass pipeline
  equivalence. Cases that depend on running before name-hash finalization or on a
  specific interleaving with other transformers are the known divergence. This
  divergence belongs to the second-pass implementation, not the API contract; see
  Build pipeline for the pre-hash refinement that would remove it without
  sacrificing accumulator isolation.
- One pass per resolved `Transformer` means N krusty invocations for N consumed
  sets, each re-parsing the intermediate resource set. This is the price of
  accumulator isolation (see Build pipeline); it is linear in the number of
  consumed sets, not in the size of the fleet, and transformer manifests are
  small. Merging passes as an optimization is not safe in general, because it
  reintroduces companion identity collisions between independently authored sets.

## Implementation History

<!-- To be filled once an initial implementation is available in a release. -->
