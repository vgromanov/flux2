# Variant: collision with `transformers:` (not `components:`)

Same two packs as the parent example (`SecurityBaseline/restricted`
local-config companions + ReplacementTransformers). Intake differs:

| Field | Holds |
|---|---|
| `resources:` | app + `local-config` baseline(s) |
| `transformers:` | ReplacementTransformer manifest(s) |

| Consumer | Result |
|---|---|
| `one-pack/` | builds |
| `both-packs/` | **fails** on duplicate baseline id |

```bash
kustomize build rfcs/0014-kustomize-transformers/repro/collision/as-transformers/one-pack
kustomize build rfcs/0014-kustomize-transformers/repro/collision/as-transformers/both-packs
# may not add resource with an already registered id:
#   SecurityBaseline.v1.config.example.com/restricted.[noNs]
```

Collision is accumulator identity under `resources:`, not a components-only
problem — any co-location (AG, hand merge, `transformers:` wiring) that puts
both companions into one build hits the same wall.

`packs/` is the shared source; `one-pack/` and `both-packs/` keep in-tree
copies so the load restrictor is happy.
