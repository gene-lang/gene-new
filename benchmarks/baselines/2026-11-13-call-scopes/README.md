Evidence for two call-scope changes on `perf/python-gap` (2026-11-13), default
builds on an Apple M4 Pro.

| Commit | Change |
| --- | --- |
| `9c929dac` | A pooled call scope whose parent is a loaded module's root keeps that context, and the message Self type, between calls; the pool drops it before any trial deletion and when the outermost run returns |
| `3d35bd52` | Scopeless bodies may hold locals (in cells after the arguments) and `set` paths |
| the commit after them | The Self type is no longer kept |

All files of `pairs/` come from `../2026-11-12-panics/pairs/pairn.sh` over
`benchmarks/kernels/kernels.gene`, 7 rotating rounds, with `B` = `3d499e85`.
The kernel file has no call with a local; `instructions.txt` and
`scripts/call-with-local.gene` show that gain.

- `pairs/kernels.tsv` and `pairs/kernels-self-type.tsv`: `F` = `3d35bd52`, and
  `D` = the same with the four seeding call sites given one 3-argument call.
  `F/B`: send 0.90-0.91 (7 of 7), but str_interp 1.08-1.09, list_push_for
  1.05-1.06, field_write 1.05, closure, field_rw, map_literal and typed_call
  1.03, each in 0 or 1 of 7 rounds, with the same instructions as `B`.
- `pairs/kernels-final.tsv`: `X` = context kept, Self type not, so the
  dispatch loop's call sites are as they were: send 0.87 (7 of 7), the rest
  0.98-1.03 except str_interp 1.08 and field_write 1.03.
- `pairs/kernels-out-of-line.tsv`: `Y` = `X` with opStoreArg's handler out
  of line: worse (str_interp 1.10, list pushes 1.05). Not kept.

The remaining str_interp and field_write cost (up to 6% in one batch) runs the
same instructions as `B`: it is the new opStoreArg arm moving `runLoop`'s
blocks, which no profile-free build controls.

D3 as proposed (`docs/proposals/vm-dispatch-core.md`) keeps a non-leaf body's
locals in its frame too, with the scope register holding the defining scope.
What landed is the leaf half: a body that makes no call, creates no closure
and runs no loop. A call with one local costs 0.80 of the instructions and
0.75 of the cycles it did, per call net of the loop.

Gates, against `9c1c159a` by test name and, for `test_rc`, by leak count:
`test_all` (the same 5 failures), the spec runner (942 of 942),
`test_poll_window`, `test_rc` (the same 54 failures with the same counts),
`test_value_backend_boundaries`, `test_boundary_fast_paths` and
`test_fast_loop`.
