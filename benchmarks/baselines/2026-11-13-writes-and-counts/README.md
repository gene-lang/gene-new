Evidence for six changes on `perf/python-gap` (2026-11-13), all default
builds on an Apple M4 Pro, and for two experiments that were not kept.

| Commit | Change |
| --- | --- |
| `8680f69c` | A one-key write of an unmanaged value to a Node stored in one place (`trySetUnmanagedProp`, called from the out-of-line `runSetPath`) |
| `7c87bc6b` | `rcRetainFull`/`rcReleaseFull` read object boxes through cursors and casts, not counted locals and checked conversions |
| `723a5dff` | Construction: the type's scope read only for a pending contract, the call site read in place, names tried in declaration order, Node stores decided by tag |
| `60407486` | Interpolation appends Str and small Int parts in place |
| `8917a7fd` | `NativeCall` borrows the native's name, the call location and the dispatch scope; 229 natives read the scope through a cursor |
| `5e46f412` | Frame returns test for an impl assembly before calling `finishImplAssembly` |

- `pairs/kernels.tsv`: `../2026-11-12-panics/pairs/pairn.sh` over
  `benchmarks/kernels/kernels.gene`, 7 rotating rounds, labels `B`
  (`9c1c159a`), `C` (`723a5dff`'s code) and `K` (`C` with `kind` forced
  inline). Summarize with `../2026-11-12-panics/pairs/summn.py FILE B C K`.
  `C/B`: field_write 0.746, alloc_record 0.819, send 0.885, field_rw 0.910
  (each 7 of 7 rounds); every other kernel 0.97-1.03.
- `pairs/kernels-head.tsv`: the same, labels `B`, `C` and `F` (`5e46f412`).
  `F/B`: str_interp 0.650, map_strkey 0.788, field_write 0.805, alloc_record
  0.839, send 0.896, field_rw 0.903 (each 7 of 7); typed_list_param 1.045 with
  1.5% fewer instructions than `B`; every other kernel 0.98-1.03.
- `kernels/`: `benchmarks/run_kernels.gene` with `5e46f412` as `gene`,
  CPython 3.14.3 as `python` and `9c1c159a` as `baseline`.
- `instructions.txt`: instructions retired for each step, and for the two
  experiments, from `scripts/`.
- `patches/kind-always-inline.patch`: `kind` as two table reads with
  `always_inline`. Fewer instructions on most kernels (typed calls -2.3%,
  sends -1.0%), but typed-list-param +3.2%: inlining `kind` pushed
  `scopelessScalarArgsOk` out of `runLoop`. The table body alone changed
  nothing; LLVM kept about 400 out-of-line `kind` calls in `runLoop` either
  way.
- ARC (`--mm:arc`, no cycle collector) was not faster: `rememberCycle` costs a
  call, and the collector itself never runs in these kernels.

Gates for each step, against `9c1c159a` by test name: `test_all` (5 failures
before and after, the `gene doc` and custom-source cases), the spec runner
(942 of 942, with `SDKROOT` set to the 26.5 SDK for its native builds; one
run of `8917a7fd`'s tree lost "recursive watch discovers files in newly
created directories" to file-event timing under load, and that test passed 5
of 5 alone on the same binary and in the full run of `5e46f412`),
`test_poll_window`, `test_rc` with `-d:geneRcStats` (54 failing leak checks
before and after, with the same counts line for line),
`test_value_backend_boundaries` (1 failure before and after),
`test_boundary_fast_paths` and `test_fast_loop`.
