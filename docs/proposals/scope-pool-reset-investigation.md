# Pooled call-scope metadata investigation

2026-10-11, follow-up to finding 3 in the general-runtime benchmark review.
Status: stale metadata reproduced; runtime correction remains separate from
the namespace-ownership and loop-uniqueness fixes.

## Confirmed behavior

The diagnostic [probe](../../tests/fixtures/scope_pool_metadata_probe.nim)
compiles a pooled function and runs it under two distinct roots. Each root has
its own `ModuleRefTable`; their sandbox generation IDs are 101 and 202. A native
callback records the current scope address, generation, and whether its ref
table matches its parent's. It never retains the scope.

On Nim 2.2.4 ORC in both debug and release builds, the first function produced:

| Invocation | Scope address | Scope generation | Parent generation | Ref table matches parent |
| --- | --- | ---: | ---: | --- |
| First root | A | 101 | 101 | true |
| Second root | A | 101 | 202 | false |

The second function mutates its parameter and exercises the general acquisition
path instead of the simple one. It reuses A and also retains stale metadata.
The exact heap address is incidental; reuse and mismatched metadata are not.

`newScope` inherits `moduleRefs` and `sandboxGenerationId` from its parent.
Neither `resetCallScope` nor `acquireSimpleCallScope` refreshes these fields,
and `releaseCallScope` leaves them intact. The omission exists in the baseline
`f9d731c` as well. `nextForScope` explicitly refreshes both fields, so this
reproducer identifies a pre-existing call-pool defect, not a loop-reuse defect.

## Impact and limits of the evidence

- Confirmed: pooled activations can expose the wrong generation and retain a
  previous module's reference table.
- `materializedModuleRefValue` uses `scope.moduleRefs` as a fast-path gate. A
  stale nil/empty table can skip required materialization. Actual lookup uses
  `moduleRefRootScope`, so saying it directly resolves against the old table
  overstates what this code demonstrates.
- `popRunnableFiber` compares the fiber scope's generation against the active
  sandbox generation. Stale metadata could make a runnable fiber ineligible.
  A resulting scheduler stall has not been reproduced here.
- The review says `releaseCallScope` clears `managedBindingPins`; there is no
  such blanket clear in that routine. Pin lifetime needs its own audit rather
  than copying an assumed release recipe.

## Recommended correction

Centralize parent-derived metadata initialization and use it for fresh scopes,
both call-pool acquisition paths, and reused loop scopes. Cover transitions
between distinct tables and from a table/nonzero generation to nil/zero.
Keep slot mirroring tied to the actual chunk's layout, and audit clearing and
retention separately; not every Scope field has the same lifetime.

Turn this probe into assertions once that correction is implemented. Add
pending-reference and sandbox scheduling regressions to establish the impact
at the language/runtime boundary.

## Reproduction

From the repository root:

```sh
GENE_USER_PACKAGES="$PWD/tmp/scope-pool-packages" nim c -r --path:src \
  --nimcache:tmp/scope-pool-cache -o:tmp/scope-pool-probe \
  tests/fixtures/scope_pool_metadata_probe.nim
```
