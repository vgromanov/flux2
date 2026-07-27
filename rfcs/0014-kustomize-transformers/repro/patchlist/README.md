# Three ways to stack feature components onto a Flux Kustomization

Base deploys the app and already ends with a transform-only pack that must
stay last:

```text
[app-defaults, harden]
```

Three stacks add the same features (`monitoring`, `redis-cache`,
`logging-labels`) with different patch techniques:

| Stack | Technique | Result |
|---|---|---|
| `stacks/additive-fail` | JSON6902 `op: add` `/spec/components/-` | harden **not** last |
| `stacks/indexed-insert` | JSON6902 `op: add` at shifting indices | harden last (fragile) |
| `stacks/strategic-merge` | SMP restates the full list | harden last (non-modular) |

```bash
kustomize build rfcs/0014-kustomize-transformers/repro/patchlist/base
kustomize build rfcs/0014-kustomize-transformers/repro/patchlist/stacks/additive-fail     | yq .spec.components
kustomize build rfcs/0014-kustomize-transformers/repro/patchlist/stacks/indexed-insert    | yq .spec.components
kustomize build rfcs/0014-kustomize-transformers/repro/patchlist/stacks/strategic-merge   | yq .spec.components
```

Expected:

```text
additive-fail:     [app-defaults, harden, monitoring, redis-cache, logging-labels]
indexed-insert:    [app-defaults, monitoring, redis-cache, logging-labels, harden]
strategic-merge:   [app-defaults, monitoring, redis-cache, logging-labels, harden]
```

### Why none of these are a good API

1. **Append** is modular but wrong: resource packs land after the transform
   tail (see `../stages/order` — green build, unhardened workload).
2. **Indexed insert** is correct only while every author knows the current
   length and the transform boundary index; the next append elsewhere breaks
   the arithmetic.
3. **Strategic merge** is correct but requires restating every entry — the
   overlay author needs global knowledge of the tail (defaults + harden + all
   features).

Root cause: `spec.components` is one ordered list for two phases (accumulate,
then transform). Position is the only boundary. A separate transformers field
makes both lists append-only.
