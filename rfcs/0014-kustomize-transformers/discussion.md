# Discussion pitch: Kustomize Transformers as a Flux API

<!--
Opener for github.com/fluxcd/flux2/discussions (category: Ideas).
Not part of the RFC PR. Full draft: https://github.com/vgromanov/flux2/blob/rfc-transformers/rfcs/0014-kustomize-transformers/README.md
-->

**Proposed title:** `[RFC] Transformer API: sourced, reusable Kustomize transformers for Kustomizations`

---

Flux exposes a small, curated subset of Kustomize's transformation surface:
`spec.patches`, `spec.images`, `spec.commonMetadata`, plus whatever fits into a
`kustomization.yaml`'s convenience fields. But Kustomize's real power lives one
layer below, in full-spec builtin transformers — `PrefixSuffixTransformer`,
`ImageTagTransformer`, `ReplacementTransformer`, `LabelTransformer` and friends —
where every transformer accepts custom `fieldSpecs` and `ReplacementTransformer`
adds structured deep-copy with wildcard field paths.

That layer is where real-world fleet problems get solved: scoping a rename to
selected kinds and their cross-references, rewriting images that operators keep
in annotations or CR fields, enforcing a security baseline on every container of
every workload. Flux users can reach it today, but only by paying a structural
tax:

- every app/environment combination needs a **pure-transformer overlay** whose
  only job is to attach transformer files to a base;
- the same transformer sets get **duplicated across overlays and sources** — the
  Kustomize load restrictor forbids sharing files across directory trees, let
  alone across source artifacts (e.g. app from `OCIRepository`, config from Git);
- `spec.components` can't span sources, couples ordering to accumulation, and has
  no independent lifecycle — no way to version, validate or observe a transformer
  set on its own.

## Idea

A new `Transformer` API in `kustomize.toolkit.fluxcd.io`, reconciled by
kustomize-controller. It sources a set of transformer manifests from any Flux
source, validates that the path emits only builtin transformer kinds, and reports
readiness. `Kustomization` consumes it by explicit reference or label selector:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1alpha1
kind: Transformer
metadata:
  name: org-labels
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository # GitRepository | OCIRepository | Bucket | ExternalArtifact
    name: fleet-config
  path: ./transformers/org-labels
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
spec:
  # ...existing fields...
  transformers:
    - name: org-labels
      namespace: flux-system
  transformerSelectors:
    - matchLabels:
        environment: staging
```

The resolved transformers are applied to the build output before `postBuild`, as
a second Kustomize pass over the built result (see Open questions for the
semantics this commits to, and how it differs from a single-pass `transformers:`
directive). Transformers are build inputs, never applied to the cluster. Define
once, consume from any number of `Kustomizations`, across sources and tenants.

## What full-spec transformers unlock

### Security baseline fan-out with `ReplacementTransformer`

Enforce a hardened `securityContext` on every container of every workload —
including sidecars injected by third-party bases you cannot edit. The baseline
ships as a `local-config` companion (a valid replacement source during build,
pruned from output), and wildcard `fieldPaths` cover container lists of any
length — something neither strategic-merge nor JSON6902 patches can express:

```yaml
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
---
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

Published once as a labeled `Transformer`, consumed by every tenant
`Kustomization` via a selector. Today this requires copying both files into every
overlay that needs them.

### Image rewriting in non-standard fields with `ImageTagTransformer`

`spec.images` only reaches the well-known container image paths. Operators
routinely keep operand image references in CR fields and annotations — exactly
what custom `fieldSpecs` were made for:

```yaml
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

One `Transformer`, referenced from every environment `Kustomization` — instead of
a per-environment overlay whose only purpose is hosting this file. For air-gapped
mirrors, this is the difference between one definition and N copies.

### Surgical renaming with `PrefixSuffixTransformer`

`namePrefix` renames everything in the build. A full-spec transformer renames
only the selected kinds while keeping cross-references consistent — here,
deploying the same unmodifiable OCI artifact into several staging slots:

```yaml
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

The `Kustomization` builds from the `OCIRepository`, the transformer comes from a
Git-backed `Transformer` — composition across source boundaries that plain
Kustomize forbids.

## Scope guardrails

- Builtin transformer kinds only — no exec/container KRM functions in v1; plus
  `local-config` companion resources as replacement sources.
- Namespace-local selectors; explicit cross-namespace refs follow the existing
  `--no-cross-namespace-refs` semantics.
- Behind a `Transformers` feature gate, off by default; zero behavior change for
  existing objects, and `spec.patches`/`spec.images`/`spec.components` are
  untouched.

## Open questions / feedback wanted

### 1. Semantics: this is a second pass, not canonical `transformers:`

The resolved transformers are applied as a **second Kustomize pass** over the
fully built output — after generators, name-hash finalization, namespacing and
the `Kustomization`'s own transformers (`spec.components`/`patches`/`images`/
`commonMetadata`). That is the intended model ("apply this set to the final build
output"), but it is **not** a 1:1 mapping to listing the same transformers under
`transformers:` in a `kustomization.yaml`, where they would run before name-hash
finalization and could interleave with the other transformers. For the
overwhelming majority of transformer kinds this is behaviorally
indistinguishable; the divergence is real only for cases that depend on running
before hashing or on a specific interleaving. Is "apply to the final build
output" the right contract to commit to, or is closer single-pass fidelity worth
pursuing?

### 2. Implementation shape

Three options, each a different compromise:

**a. Dedicated `Transformer` kind + reconciler in kustomize-controller** (this
draft). Reuses source plumbing and fan-out; adds a CRD but no new binary.

**b. Standalone/independent controller.** Pro: cleanly follows the
"one controller, one concern" guideline. Con: a `Transformer` is inherently a
cross-breed of a source controller (fetch → validate → publish an artifact) and
kustomize-controller (build-time consumption); a standalone controller would
re-implement source-controller responsibilities for little isolation gain.

**c. Pipelines only — no new API/reconciler.** Drop the `Transformer` kind
entirely. The `transformers*` fields on `Kustomization` reference **other
`Kustomizations`**, whose build output supplies either a transformer set or
resources. A new `spec.buildOnly` flag marks a `Kustomization` whose build is
never delivered to any destination (no server-side apply, no health checks) — it
exists only to be consumed by other `Kustomizations`. A consumer can
reference several such units, each with its own `sourceRef`, so composition
**across sources** falls out for free (app from `OCIRepository`, transformers
from Git, replacement sources from anywhere). Each consumed unit is homogeneous —
builtin transformers only, or resources only, never mixed within one unit.
Resource units are built with `IncludeLocalConfigs: true` and accumulated into the
consumer's resmap under `resources:` (so `local-config` replacement sources
survive to the transformer pass and are pruned at the consumer's final build);
transformer units are applied under `transformers:`. This reuses everything Flux
already has (sources, build, validation, status, fan-out) and adds only a
consumption edge plus one flag. A full draft of this variant exists at
[`README-v2.md`](https://github.com/vgromanov/flux2/blob/rfc-transformers/rfcs/0014-kustomize-transformers/README-v2.md).

### 3. Why option (c) also helps the local-config / mixture problem

A standalone `Transformer` reconciler must re-implement the "only transformer
kinds + `local-config` companions" validation by hand. If the transformer set is
just another `Kustomization` build, that check largely comes for free: a
`buildOnly` Kustomization is built by Kustomize itself, so an illegal mixture (a
non-transformer, non-`local-config` resource in the `transformers:` field, or a
replacement source that never enters the resmap) fails exactly the way canonical
`kustomize build` fails. It does not make the second-pass model byte-identical to
single-pass, but it inherits canonical Kustomize's **failure mode** — which is
most of the validation value.

### Still open from the original draft

- Selector semantics: is namespace-local matching with `failOnMissing` the right
  multi-tenancy default?
- Application point: after the full build, before `postBuild` — any use cases
  that need a different ordering?

A full RFC draft (API sketch, resolution semantics, user stories, security
considerations) is ready.
