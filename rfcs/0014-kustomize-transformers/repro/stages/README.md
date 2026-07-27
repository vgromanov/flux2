# Stage-ordering playground (components vs transformers)

Components are accumulated; transformers are applied to the whole set. Same pack,
same app, only the attachment point changes.

Pipeline order inside one kustomization target (kustomize v5.8.1):

```text
resources:  →  components:  →  generators  →  builtin transformers
                                              (patches, images, commonMetadata,
                                               namespace, namePrefix)
            →  transformers:  →  [top level only] name hashing → nameref fixup
```

A component's transformers therefore see the resources accumulated *before* that
component and nothing else. A `transformers:` entry sees everything.

## 1. Pack vs. a container injected by `patches`

`patches` stands in for Flux `spec.patches`, which kustomize-controller injects
into the root kustomization. The pack hardens every container of every Deployment.

| Root | Result |
|---|---|
| `as-component` | app hardened, **injected sidecar not hardened** — exit 0, no warning |
| `as-transformers` | both containers hardened |

```bash
kustomize build rfcs/0014-kustomize-transformers/repro/stages/as-component     | grep -c securityContext   # 1
kustomize build rfcs/0014-kustomize-transformers/repro/stages/as-transformers  | grep -c securityContext   # 2
```

The component runs before the parent's own patch stage, so the sidecar does not
exist yet. Nothing fails; the policy is just absent from one container.

## 2. Pack vs. a resource added by another component

Pure accumulation visibility, no patches involved.

| Root | Result |
|---|---|
| `order/pack-then-addon` | exporter Deployment **not hardened** |
| `order/addon-then-pack` | both Deployments hardened |

Both builds are green. Which one you get depends on list order alone.

## Where the RFC's model sits

Three attachment points, ordered by how late they see the resource set:

1. `components:` — sees only what was accumulated before it.
2. `transformers:` — sees the finished target, before name hashing.
3. RFC second pass — sees the finished build, after hashing.

Each step later sees more of the output and is further from the source
kustomization's own semantics. Note 2 is the fidelity sweet spot: an
`ArtifactGenerator` composition that lands the pack under a wrapper's
`transformers:` gets it. What it does not get is per-consumer composition, packs
with colliding companions (see `../collision`), or selection from cluster state.
