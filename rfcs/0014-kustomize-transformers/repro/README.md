# RFC-0014 repro fixtures

Runnable fixtures backing the discussion of why `components` (and therefore
file-level `ArtifactGenerator` composition) is not a substitute for a first-class
`transformers` layer. Everything here is checked against **kustomize v5.8.1** and
builds from the repo root.

| Playground | Supports | Shows |
|---|---|---|
| [`patchlist/`](./patchlist) | phase boundary | a components list is one ordered list for two phases; no additive patch can insert before the transform tail |
| [`collision/`](./collision) | single-tree backfire | two packs sharing a `local-config` companion id collide when co-located in one build; one pass per set removes it |
| [`stages/`](./stages) | pipeline position | `components` see only what accumulated before them; `transformers` see the whole set — same pack, different coverage |
| [`order-sensitivity/`](#order-sensitivity) (root) | quiet failure | when a rename pack and a policy pack are co-located, list order silently decides whether the policy applies |

Each subdirectory has its own README with commands and expected output.

## Order-sensitivity

Same app, same two components; only `components:` list order changes.

| Consumer | Order | Result |
|---|---|---|
| `consumers/security-then-prefix` | security → prefix | `stage1-storefront` **with** hardened `securityContext` |
| `consumers/prefix-then-security` | prefix → security | rename+relabel first; `labelSelector: app=storefront` matches nothing → **baseline silently missing** |

The security pack assumes label `app=storefront`; the prefix pack rewrites that
label. Neither pack is wrong alone; together, **list order becomes policy
correctness**, and the failure mode is a green build without the securityContext.

```bash
kustomize build rfcs/0014-kustomize-transformers/repro/consumers/security-then-prefix
kustomize build rfcs/0014-kustomize-transformers/repro/consumers/prefix-then-security
# compare containers[0].securityContext
```

Note: selecting by `name: storefront` is a weak demo on current kustomize — ResMap
identity can stay sticky after a fieldSpecs-only rename. Label selectors follow the
rewritten labels and show the real non-commutativity.
