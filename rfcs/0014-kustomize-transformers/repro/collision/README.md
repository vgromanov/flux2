# local-config identity collision playground

Two independently authored policy packs both ship a `local-config` companion
with the same identity (`SecurityBaseline/restricted`). Alone each is fine.
AG (or listing both under `spec.components`) co-locates them into one build →
Kustomize rejects the duplicate accumulator id.

| Consumer | Composition | Result |
|---|---|---|
| `consumers/one-pack` | baseline-a only | builds |
| `consumers/both-packs` | baseline-a + baseline-b, one build | **fails**: already registered id |
| `./passes.sh` | one pass per pack (RFC-0014 pipeline) | builds; B overrides A |

```bash
kustomize build rfcs/0014-kustomize-transformers/repro/collision/consumers/one-pack     # OK
kustomize build rfcs/0014-kustomize-transformers/repro/collision/consumers/both-packs   # FAIL
# may not add resource with an already registered id:
#   SecurityBaseline.v1.config.example.com/restricted.[noNs]

./rfcs/0014-kustomize-transformers/repro/collision/passes.sh                            # OK, both packs applied
```

`local-config` is stripped from **output** but still occupies an accumulator slot
by GVK+name — same uniqueness rules as real resources.

This is the AG arse-bite: packs validated in isolation; collision appears only at
compose time. `passes.sh` is the counter-demo the RFC relies on — the controller
composes at the object level, so each companion is visible only to the
transformers shipped with it and is pruned again at the end of its own pass.

See `as-transformers/` for the same collision when packs are wired via
`resources:` + `transformers:` instead of `components:`.
