# Pooled call-scope metadata investigation

2026-10-11, follow-up to finding 3 in the general-runtime benchmark review.
Status: fixed after the namespace-ownership and loop-uniqueness changes in
`c43b40e`.

## Confirmed behavior

The diagnostic [probe](../../tests/fixtures/scope_pool_metadata_probe.nim)
compiles a pooled function and runs it under distinct roots. The first two have
their own `ModuleRefTable` and sandbox generation IDs 101 and 202; the third
has no table and generation zero. A native
callback records the current scope address, generation, and whether its ref
table matches its parent's. It never retains the scope.

Before the fix, on Nim 2.2.4 ORC in both debug and release builds, the first
function produced:

| Invocation | Scope address | Scope generation | Parent generation | Ref table matches parent |
| --- | --- | ---: | ---: | --- |
| First root | A | 101 | 101 | true |
| Second root | A | 101 | 202 | false |

The original probe's second function mutated its parameter but still used the
simple acquisition path. The corrected probe uses a typed parameter to select
the general path and asserts the actual `simpleCallScope` flag. Regression tests
reproduce stale metadata on both paths. The exact heap address is incidental;
reuse and mismatched metadata are not.

`newScope` inherits `moduleRefs` and `sandboxGenerationId` from its parent.
Previously neither `resetCallScope` nor `acquireSimpleCallScope` refreshed these
fields, and `releaseCallScope` left them intact. The omission exists in the
baseline `f9d731c` as well. `nextForScope` explicitly refreshed both fields, so this
reproducer identifies a pre-existing call-pool defect, not a loop-reuse defect.

## Impact and limits of the evidence

- Confirmed: pooled activations can expose the wrong generation and retain a
  previous module's reference table.
- Confirmed functional failure: when a native supplies an internal unresolved
  reference marker, loading that local in a pooled function could return the
  marker instead of raising `RefNotResolved`. Both acquisition paths now raise.
- `materializedModuleRefValue` uses `scope.moduleRefs` as a fast-path gate. A
  stale nil/empty table skipped required materialization. Actual lookup uses
  `moduleRefRootScope`, so saying it directly resolves against the old table
  overstates what this code demonstrates.
- `popRunnableFiber` compares the fiber scope's generation against the active
  sandbox generation. Stale metadata could make a runnable fiber ineligible.
  A resulting scheduler stall has not been reproduced here.
- The review says `releaseCallScope` clears `managedBindingPins`; there is no
  such blanket clear in that routine. Pin lifetime needs its own audit rather
  than copying an assumed release recipe.

## Implemented correction

`inheritScopeContext` centralizes parent-derived metadata for fresh scopes,
both call-pool acquisition paths, and reused loop scopes. Release calls the
same helper with a nil parent, dropping the old module table and clearing the
generation ID along with the existing parent/application/budget references.
Slot mirroring is an explicit reset argument for loop bodies; call activations
start without mirroring. The general reset also clears import/export lookup
metadata, matching fresh scopes and the release paths.

The probe now asserts correct inheritance through 101 → 202 → 0 and table →
different table → nil. VM regressions also assert the same scope storage is
reused, idle entries drop their inherited table/generation, and unresolved
references raise at the local read. Managed binding-pin lifetime rules remain
unchanged; this is not a blanket reset of every Scope field.

Verification: 402 VM tests pass on ORC and AtomicArc, 115 module/sandbox tests
pass, and 87 RC/lifetime tests pass. Ten selected ownership/reuse/retention cases
pass under AddressSanitizer with leak detection disabled. The module suite
includes prepared-generation activation, task handling, commit, and release;
no new scheduler-stall reproducer is claimed. Logs are in `tmp/scope-pool-fix/`.

## Reproduction

From the repository root:

```sh
GENE_USER_PACKAGES="$PWD/tmp/scope-pool-packages" nim c -r --path:src \
  --nimcache:tmp/scope-pool-cache -o:tmp/scope-pool-probe \
  tests/fixtures/scope_pool_metadata_probe.nim
```
