# RFC-0014 Kustomize Transformers API — Alternative v2: Build-only Kustomizations

**Status:** provisional

**Creation date:** 2026-06-12

**Last update:** 2026-07-27

> [!NOTE]
> This is an **alternative** draft to the primary proposal in
> [`README.md`](./README.md). The primary draft (call it *v1*) introduces a
> dedicated `Transformer` CRD reconciled by `kustomize-controller`. This v2 draft
> explores option (c) from [`discussion.md`](./discussion.md): solve the same
> problems **without a new kind or reconciler**, by letting a `Kustomization`
> consume the build output of other `Kustomizations` and marking reusable,
> never-applied units with a `spec.buildOnly` flag. The two drafts are mutually
> exclusive; the trade-off is discussed under [Alternatives](#alternatives).

## Summary

This RFC proposes extending the Flux `Kustomization` API so that one
`Kustomization` can consume the build output of other `Kustomizations` as **build
inputs** — either as Kustomize transformer sets (applied as `transformers:`) or as
companion resources (accumulated as `resources:`). A new `spec.buildOnly` boolean
marks a `Kustomization` that is sourced, built and validated, has its result
recorded in status, but is **never applied to a cluster** (no server-side apply,
health checks, pruning or inventory). Build-only Kustomizations become reusable,
independently versioned, observable build inputs that any number of
`Kustomizations` can compose — across sources and tenants — using full-spec
Kustomize transformers without per-overlay duplication.

No new custom resource kind and no new controller are introduced. The feature is
expressed entirely as additive `Kustomization` fields plus build-pipeline behavior
in `kustomize-controller`.

## Motivation

The motivation is identical to the primary draft: Flux exposes only a curated
subset of Kustomize's transformation surface (`spec.patches`, `spec.images`,
`spec.commonMetadata`), while the full power — custom `fieldSpecs` on every
builtin transformer and `ReplacementTransformer`'s structured deep-copy with
wildcard field paths — is reachable today only by paying a structural tax:
pure-transformer overlays, transformer files duplicated across overlays and source
artifacts (the Kustomize load restrictor forbids sharing across trees and
artifacts), or `spec.components` that cannot span sources and have no independent
lifecycle. See [`README.md`](./README.md#motivation) for the full treatment.

Where this draft differs is the *shape of the solution*. The primary draft adds a
`Transformer` kind. This draft observes that Flux already has a controller that
fetches a source, runs `kustomize build`, validates the result and reports
readiness — the `Kustomization` itself. The only things missing for transformer
reuse are (1) a way to consume one `Kustomization`'s build output inside another's
build, and (2) a way to say "build and validate this, but do not deploy it." Both
are small, additive changes that reuse the existing source, build, validation,
status and fan-out machinery.

A key consequence: because each consumed unit is an ordinary Kustomize build, the
"only transformer kinds + `local-config` companions" validation that v1's
reconciler must implement by hand comes largely **for free** — an illegal mixture
fails exactly the way canonical `kustomize build` fails (see
[Validation inherited from Kustomize](#validation-inherited-from-kustomize)).

### Goals

- Let a `Kustomization` consume the build output of other `Kustomizations` as
  build inputs, applied as `transformers:` or accumulated as `resources:`.
- Add `spec.buildOnly` so a `Kustomization` can be a build input without ever
  being applied to a cluster.
- Reduce pure-transformer overlays and deduplicate transformer sets across
  overlays, repositories and source artifacts.
- Expose the full expressiveness of Kustomize transformer specs (custom
  `fieldSpecs`) without growing the `Kustomization` API field by field.
- Reuse the existing source/build/validation/status/fan-out machinery; add no new
  kind and no new controller.
- Preserve Kustomize transformer semantics: consumed transformers behave as a
  `transformers:` directive applied to the **final build output**. This is a chain
  of Kustomize passes over the built output — one per group of consumed units, so
  that independently authored packs never share an accumulator — not an inlining
  into the source `kustomization.yaml`; the distinction and its consequences are
  documented in [Build pipeline](#build-pipeline) and [Drawbacks](#drawbacks).

### Non-Goals

- Provide a general plugin mechanism. Exec/container KRM functions and other
  non-builtin transformer plugins are out of scope for the initial version.
- Apply build-input content to the cluster. Consumed `buildOnly` Kustomizations
  are build inputs only.
- Replace `spec.patches`, `spec.images`, `spec.components` or `spec.postBuild`.
  These remain unchanged and fully supported.
- Publish a new artifact type or storage endpoint. Composition reuses existing
  source-controller artifacts and the controller's build machinery.
- Cross-namespace label selectors. Selectors match only `Kustomization` objects in
  the namespace of the consumer.

## Proposal

### `spec.buildOnly`

A new optional boolean `spec.buildOnly` on `Kustomization`:

- When `true`, the `Kustomization` is reconciled normally up to and including
  `kustomize build` and validation, and records its resolved revision and object
  inventory in status — but the controller performs **no** server-side apply, no
  health assessment, no pruning and manages no cluster inventory. It produces no
  cluster side effects.
- It remains a first-class object: it has an `interval`, can be suspended,
  reports `Ready`, and participates in source-change fan-out.
- It exists to be referenced by other `Kustomizations` as a build input.

A `buildOnly` Kustomization is the unit of reuse that replaces v1's `Transformer`
object.

### Consuming build inputs

The `Kustomization` API gains three optional fields, mirroring v1 for easy
comparison, but referencing **other `Kustomizations`** rather than `Transformer`
objects:

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
    # group 1: a transformer unit on its own
    - name: staging-name-prefix
    # group 2 opens with a resource unit; the selector below contributes the
    # transformer unit that consumes its companion
    - name: security-baseline-data
      namespace: flux-system
  transformerSelectors:
    - matchLabels:
        policy.example.com/security-baseline: "true"
  transformersPolicy:
    failOnMissing: true
```

Each referenced/selected object must be a `buildOnly` `Kustomization` that is
`Ready`. The consumer materializes each one (see [Build pipeline](#build-pipeline))
and **routes it by content**:

- a unit whose build output contains only builtin transformer kinds is applied as
  `transformers:`;
- a unit whose build output contains only resources (including `local-config`
  companions) is accumulated as `resources:`.

#### Homogeneity rule

A consumed unit must be **homogeneous**: either all builtin transformer kinds, or
all resources — never a mix within one unit. Transformer sets and their companion
data live in *separate* `buildOnly` Kustomizations and are composed at the
consumer. This is the strict-separation refinement of v1's "bundled companion"
model, and it is what makes content-based routing unambiguous.

The consequence is that a pack's data unit and transformer unit are paired
**positionally**: they must be adjacent in the resolved list so they fall into the
same pass (see [Resolution semantics](#resolution-semantics)). Explicit references
give that ordering directly; selector-resolved matches are name-sorted, so a
pack's units must be named to sort adjacently (e.g. a shared prefix, as in
[Story 2](#story-2-security-baseline-as-two-composed-units-the-showcase-for-this-draft)).
v1 avoids the question entirely by bundling companions inside one `Transformer`;
this is a real concession of v2, listed under [Drawbacks](#drawbacks).

#### Resolution semantics

1. **Order and grouping:** explicit `transformers` are resolved in list order,
   followed by the matches of each entry in `transformerSelectors` (matches within
   a selector sorted by name for determinism). The resolved list is then
   partitioned into consecutive groups — each a run of resource units followed by
   a run of transformer units — and each group is applied in one Kustomize pass
   (see [Build pipeline](#build-pipeline)). A resource unit is therefore visible
   only to the transformer units that follow it in the same group.
2. **Dedup:** a unit matched both by reference and by selector (or by multiple
   selectors) is materialized once.
3. **Selector scope:** selectors match only `Kustomization` objects in the
   consumer's namespace. Explicit references may target other namespaces, subject
   to `--no-cross-namespace-refs`.
4. **failOnMissing:** when `true` (default), reconciliation fails if a referenced
   `Kustomization` does not exist, is not `buildOnly`, or is not `Ready`, and if a
   selector matches zero objects. When `false`, missing references and empty
   selector results are skipped.
5. **Cycle detection:** a `buildOnly` Kustomization may itself consume other
   `buildOnly` Kustomizations; the controller rejects reference cycles.
6. **No-op detection:** a resolved group whose pass leaves the output identical to
   its input (it selected nothing) is recorded in status and, when
   `transformersPolicy.failOnNoop` is `true`, fails the reconciliation — turning a
   silent miss (e.g. a policy group whose target labels were renamed upstream)
   into an actionable error. Defaults to `false`.
7. **Observability:** the consumer status records the resolved input set, each
   entry's pinned revision, whether it was selected explicitly or via a selector,
   and any group detected as a no-op.

### Build pipeline

The resolved inputs are applied to the consumer's fully built resource set —
after `kustomize build` of `spec.path` (which already includes `spec.components`,
`spec.patches`, `spec.images` and `spec.commonMetadata`) and before
`spec.postBuild`:

```text
consumer source @ revision
  → kustomize build spec.path (components, patches, images included)
  → resolve referenced buildOnly Kustomizations (deterministic order)
      → resource units: build from pinned revision with IncludeLocalConfigs
      → transformer units: build from pinned revision, collect manifests
  → partition the resolved list into groups: a run of resource units followed by
    a run of transformer units
  → for each group, in order, one Kustomize pass over a synthetic kustomization.yaml:
        resources:    [output of the previous step] + [the group's resource units]
        transformers: [the group's transformer-unit manifests]
      → IgnoreLocal prunes that group's local-config companions from the pass output
  → postBuild variable substitution
  → server-side apply
```

Each referenced `buildOnly` Kustomization is **materialized from its pinned source
revision** (recorded in its status) rather than from a newly published artifact;
no new artifact storage endpoint is introduced. The controller may cache rendered
output keyed by revision as an optimization. Reproducibility is preserved by
recording every consumed revision in the consumer's status.

Resource units are built with the resource factory's `IncludeLocalConfigs` option
enabled, so `local-config` companion resources survive materialization and are
available as replacement sources in the pass that consumes them; they are pruned
from that pass's output by the normal local-config handling.

#### Why one pass per group, not one merged pass

Merging every resolved unit into a single synthetic pass is simpler but breaks the
composition it is meant to enable. Kustomize enforces resource identity uniqueness
on the accumulator, and `local-config` companions occupy a slot by GVK+name even
though they are pruned from the output. Two policy packs that both ship a
companion named `SecurityBaseline/restricted` — a naming convention, not a
coincidence — cannot land in one resmap:

```text
may not add resource with an already registered id:
SecurityBaseline.v1.config.example.com/restricted.[noNs]
```

That failure is shared by every model that co-locates sets into one build (a
merged pass, `spec.components`, or artifact-level file composition), and it
surfaces only at compose time, since each pack validates green on its own.
Grouping keeps each companion visible only to the transformer units in its own
group, so both packs apply, with later groups overriding earlier ones on fields
they both write.

Because the transformers run in passes over the built output, they operate on the
final result of the consumer's own build — after generators, name-hash
finalization, namespacing and the consumer's own transformers have already been
applied. This is the intended behavior ("apply this set to the final build
output"), but it is deliberately **not** a 1:1 substitute for inlining the same
transformers under `transformers:` in the source `kustomization.yaml`, where they
would run before name-hash finalization and could interleave with the other
transformers. See [Drawbacks](#drawbacks).

As in v1, this timing is a property of the pass implementation, not the design:
group isolation comes from materializing each group against its own accumulator,
not from when the pass runs, so a future implementation could apply each group at
its canonical pre-hash position and stay equally collision-free.

### Validation inherited from Kustomize

Because every consumed unit is an ordinary Kustomize build, most validation is
inherited for free rather than re-implemented:

- A unit that tries to mix transformer kinds and ordinary resources, or that lists
  a non-transformer under `transformers:`, fails its **own** `kustomize build` the
  same way a hand-written kustomization would.
- A `ReplacementTransformer` whose source is not present in the resmap fails with
  Kustomize's native "nothing selected by …" error.

The controller adds only a thin classification check on top: confirm a unit's
output is homogeneous (all transformer kinds, or all resources) and that
transformer kinds are within the builtin set. Exec/container KRM function
annotations are rejected.

### User Stories

#### Story 1: Org-wide labels without per-app overlays

A platform team keeps a `LabelTransformer` with custom `fieldSpecs` in a fleet
repository and exposes it as a `buildOnly` Kustomization:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: org-labels
  namespace: flux-system
spec:
  interval: 10m
  buildOnly: true
  sourceRef:
    kind: GitRepository
    name: fleet-config
  path: ./transformers/org-labels
```

Tenant `Kustomizations` reference it without copying files:

```yaml
spec:
  transformers:
    - name: org-labels
      namespace: flux-system
```

Updating the fleet repository rolls out to all consumers on their next
reconciliation, via the existing source-change fan-out.

#### Story 2: Security baseline as two composed units (the showcase for this draft)

The security baseline is split into two homogeneous `buildOnly` Kustomizations: a
**resource unit** carrying the `local-config` companion, and a **transformer unit**
carrying the `ReplacementTransformer`. They may live in different repositories and
even different sources. As in v1 Story 3, this is bulk propagation into the
manifests these `Kustomizations` manage, not admission-time enforcement of the
whole cluster; the value is expressing the structured fan-out once.

```yaml
# Resource unit — sourced from fleet-config (Git)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: security-baseline-data
  namespace: flux-system
  labels:
    policy.example.com/security-baseline: "true"
spec:
  interval: 10m
  buildOnly: true
  sourceRef:
    kind: GitRepository
    name: fleet-config
  path: ./security/baseline-data   # emits the SecurityBaseline local-config resource
---
# Transformer unit — sourced independently
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: security-baseline-xform
  namespace: flux-system
  labels:
    policy.example.com/security-baseline: "true"
spec:
  interval: 10m
  buildOnly: true
  sourceRef:
    kind: OCIRepository
    name: policy-bundle
  path: ./security/replacement      # emits the ReplacementTransformer
```

The companion resource (built with `IncludeLocalConfigs`) and the transformer:

```yaml
# ./security/baseline-data
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
# ./security/replacement
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

A tenant `Kustomization` consumes both via one selector:

```yaml
spec:
  transformerSelectors:
    - matchLabels:
        policy.example.com/security-baseline: "true"
```

Both units match the same selector and sort adjacently (`…-data` before
`…-xform`), so they form one group and are applied in a single pass: the consumer
accumulates the `SecurityBaseline` (resource unit) into that pass's resmap and
applies the `ReplacementTransformer` (transformer unit); the replacement
deep-copies the `securityContext` into every container of every
`Deployment`/`StatefulSet`; the `local-config` source is pruned from the pass
output. A second pack selected by the same label forms its own group, so its
companion may reuse the `restricted` name without colliding.
Cross-source composition (Git companion + OCI transformer) happens at the
consumer, with each unit independently versioned and observable.

#### Story 3: Scoped prefixing across sources

A `PrefixSuffixTransformer` with restricted `fieldSpecs` lives in a Git-backed
`buildOnly` Kustomization and is consumed by `Kustomizations` that build their
application from an unrelated `OCIRepository` — composition across source
boundaries that plain Kustomize forbids. (Identical in spirit to v1 Story 4, with
the transformer set expressed as a `buildOnly` Kustomization.)

#### Story 4: Optional tenant packs via selectors

A platform-managed consumer selects optional packs with `failOnMissing: false`;
tenants opt in by creating a labeled `buildOnly` Kustomization in their namespace.
Tenants without a pack reconcile unchanged. (Identical in spirit to v1 Story 5.)

### Alternatives

#### Dedicated `Transformer` CRD + reconciler (the primary draft, v1)

See [`README.md`](./README.md). A dedicated kind gives transformer sets a
first-class identity: their own status, `flux get transformers`, dedicated
printer columns, and trace/tree integration. The cost is a new CRD plus a new
reconciler that re-implements source fetching, building and the "only transformer
kinds + local-config" validation — responsibilities that already exist in
source-controller and `kustomize build`. v1 optimizes for **discoverability and a
clean conceptual model**; this v2 optimizes for **reuse of existing machinery and
minimal new surface**.

The decisive trade-off between v1 and v2 is therefore *first-class concept vs.
minimal surface*:

- v1: a `Transformer` is obviously a transformer set; great discoverability;
  companions bundled with their transformers, so pass scoping needs no ordering
  rules; new kind + reconciler to build and maintain.
- v2: a transformer set is "a `Kustomization` with `buildOnly: true`"; almost no
  new surface and free canonical validation; but the concept is less
  self-documenting, overloads `Kustomization` with a dual role, and the
  homogeneity split makes companion scoping positional.

#### Compose sources with an `ArtifactGenerator`

An `ArtifactGenerator` (`source.extensions.fluxcd.io/v1beta1`, source-watcher) can
copy application manifests and transformer files from several sources into one
`ExternalArtifact`. It solves distribution across source boundaries, not build-time
composition: the input set is a static enumeration in a centrally owned object with
no selector equivalent, consuming it still requires a committed wrapper
kustomization per combination, and co-locating independently authored packs in one
build hits the companion identity collision described under
[Build pipeline](#why-one-pass-per-group-not-one-merged-pass). See
[`README.md`](./README.md#compose-sources-with-an-artifactgenerator) for the full
treatment. The two are complementary: an `ExternalArtifact` is a valid `sourceRef`
for a `buildOnly` Kustomization.

#### Standalone independent controller

Rejected in [`discussion.md`](./discussion.md): a transformer concept is a
cross-breed of a source controller (fetch/validate/publish) and
kustomize-controller (build-time consumption); a standalone controller would
duplicate source-controller responsibilities for little isolation gain.

#### Grow the `Kustomization` convenience fields

Re-implements a growing subset of the Kustomize transformer surface inside the
Flux API field by field, and still does not solve deduplication across
`Kustomizations` and sources.

## Design Details

### API additions

```go
// KustomizationSpec additions:
type KustomizationSpec struct {
	// ... existing fields ...

	// BuildOnly marks this Kustomization as a build input: it is sourced,
	// built and validated, and its result is recorded in status, but it is
	// never applied to a cluster (no server-side apply, health checks,
	// pruning or inventory). It exists to be consumed by other Kustomizations
	// via their transformers/transformerSelectors fields.
	// +optional
	BuildOnly bool `json:"buildOnly,omitempty"`

	// Transformers references buildOnly Kustomizations whose build output is
	// consumed as build inputs. A unit emitting only builtin transformer
	// kinds is applied as transformers; a unit emitting only resources
	// (including local-config companions) is accumulated as resources.
	// +optional
	Transformers []KustomizationReference `json:"transformers,omitempty"`

	// TransformerSelectors selects buildOnly Kustomizations by labels in the
	// namespace of this Kustomization.
	// +optional
	TransformerSelectors []KustomizationSelector `json:"transformerSelectors,omitempty"`

	// +optional
	TransformersPolicy *TransformersPolicy `json:"transformersPolicy,omitempty"`
}

// KustomizationReference refers to a buildOnly Kustomization object.
type KustomizationReference struct {
	// +required
	Name string `json:"name"`

	// +optional
	Namespace string `json:"namespace,omitempty"`
}

// KustomizationSelector selects buildOnly Kustomization objects by labels
// in the namespace of the consuming Kustomization.
type KustomizationSelector struct {
	// +optional
	MatchLabels map[string]string `json:"matchLabels,omitempty"`
}

// TransformersPolicy configures input resolution behavior.
type TransformersPolicy struct {
	// FailOnMissing fails reconciliation when a referenced Kustomization is
	// missing, not buildOnly, or not ready, or when a selector matches no
	// objects. Defaults to true.
	// +optional
	FailOnMissing *bool `json:"failOnMissing,omitempty"`

	// FailOnNoop fails reconciliation when a resolved group produces output
	// identical to its input (it selected nothing). Defaults to false.
	// +optional
	FailOnNoop *bool `json:"failOnNoop,omitempty"`
}
```

> [!NOTE]
> **Open naming question.** The `transformers`/`transformerSelectors` field names
> are kept for parallelism with v1, but in this draft they also admit *resource*
> units. A clearer alternative is to name the family `buildInputs` /
> `buildInputSelectors` (content-routed), or to split it into explicit
> `transformers` and `resourceInputs` lists. Routing by content keeps the API
> small; explicit fields make intent obvious. To be resolved in discussion.

### Materialization and reproducibility

At consumer build time the controller fetches each referenced unit's source
artifact at the revision pinned in that unit's status and builds it deterministically.
No new artifact storage endpoint is introduced; existing source artifact
distribution and digest verification are reused. The full resolved set (names,
namespaces, revisions, digests) is recorded in the consumer status, so a consumer
build remains reproducible even though it depends on inputs beyond its own source.

Versioning and canary rollout work as in v1 ([README.md](./README.md#versioning-and-canary-rollout)):
a `buildOnly` Kustomization pinned to an immutable ref is the version pin, a bad
edit that fails its own build leaves it not `Ready` so `failOnMissing` consumers
fail loudly, and a canary is a second `buildOnly` object on the new ref that a
subset of consumers or selector labels move onto.

`flux build kustomization` reproduces a consumer build offline through the same
`fluxcd/pkg/kustomize` code path the controller uses, mapping consumed units to
local directories and failing closed on any unmapped reference — the same local
build convergence guarantee described for v1
([README.md](./README.md#local-build-convergence)).

### How this feature is enabled / disabled

- The feature is gated behind a `Transformers` feature gate on
  `kustomize-controller`, disabled by default in the initial phase.
- With the gate disabled, `spec.buildOnly`, `spec.transformers` and
  `spec.transformerSelectors` are ignored and a warning event is emitted if set;
  existing behavior is unchanged.
- Enabling the gate changes no behavior for `Kustomizations` that set none of the
  new fields.
- Disabling the gate after use causes consumers to reconcile without their inputs
  (with a warning event and a dedicated status condition), and `buildOnly`
  objects revert to ordinary (applied) Kustomizations — operators must be warned
  prominently, since a `buildOnly` object losing its flag would begin applying to
  the cluster. (See Drawbacks; this is the sharpest operational edge of v2.)

### How an operator determines the feature is in use

- The `Kustomization` status records the resolved input set and each consumed
  revision.
- A `buildOnly` printer column / status field surfaces never-applied units in
  `flux get kustomizations`.
- Controller metrics are labeled by feature.

### Multi-tenancy and security

- Cross-namespace explicit references follow the existing
  `--no-cross-namespace-refs` flag, consistent with `sourceRef`.
- Selectors are namespace-local by design.
- When a service account is impersonated via `spec.serviceAccountName`, access to
  referenced `Kustomizations` is checked with the impersonated identity. Note that
  a consumed unit's content can mutate any field of the consumer's build output;
  consuming a `buildOnly` Kustomization requires the same trust as consuming a
  source.

### Drawbacks

- **Dual role for `Kustomization`.** A single kind now means both "deliver this to
  the cluster" and "build this as an input." A `buildOnly` object losing its flag
  (manual edit, gate disabled) would start applying to the cluster — an
  operationally sharp edge that must be guarded with validation and warnings.
- **Reduced discoverability.** A transformer set is no longer a self-documenting
  kind; it is a `Kustomization` with a flag. This is the core concession relative
  to v1.
- **Extra-pass deviation.** As in v1, consumed transformers run after the
  consumer's full build and cannot interleave with the consumer's own
  transformers or run before name-hash finalization. Indistinguishable for the
  vast majority of transformer kinds; the divergence is real only for pre-hash or
  interleaving-dependent cases, and belongs to the pass implementation rather than
  the API contract (see Build pipeline for the pre-hash refinement).
- **Positional pairing of data and transformer units.** Because homogeneity splits
  a pack into two objects, keeping a companion in scope for its own transformers
  depends on the two units landing in the same group — explicit ordering, or names
  that sort adjacently under a selector. v1's bundled companions make the scoping
  intrinsic. A mis-ordered pair fails loudly with Kustomize's "nothing selected
  by …", but it is an avoidable footgun that v1 does not have.
- **Pass count.** One pass per group means N krusty invocations for N groups. Linear
  in consumed units, not in fleet size, and merging groups is not a safe
  optimization because it reintroduces companion identity collisions.
- **Reproducibility depends on inputs.** A consumer build is no longer reproducible
  from its own source artifact alone; mitigated by recording all consumed
  revisions/digests in status.
- **Recursive build cost.** Consuming chains of `buildOnly` Kustomizations adds
  build work and requires cycle detection; the implementation reuses the existing
  source index/requeue machinery.

## Implementation History

<!-- To be filled once an initial implementation is available in a release. -->
