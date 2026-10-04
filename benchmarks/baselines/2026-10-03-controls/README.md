# Controlled baseline before P1 runtime changes

Captured at `95b4e02` using two independent fresh-cache release/ORC builds of
the same benchmark sources on macOS arm64, Nim 2.2.4, Apple clang 21.0.0.
Exact compiled-in commands, binary hashes, platform/worktree metadata and
samples are retained in `metadata.json`, `summary.json` and the raw JSONL files.

Each executable ran four times: an excluded warmup and three measured rounds.
Execution order alternated; compilation and application profiling did not run
alongside capture. Both executables reported the same 89 measurements,
iterations and checksums. The generated-C fixture completed in every run.
No CPU pinning or thermal isolation was used. This is a local baseline, not a
universal threshold or proof of improvement over a historical build.

Selected medians (nanoseconds per benchmark iteration):

| Control/workload | Build A | Build B |
| --- | ---: | ---: |
| Empty chunk | 108.54 | 109.95 |
| Constant chunk | 135.37 | 138.06 |
| Untyped unary F64 body | 313.99 | 310.88 |
| Typed unary F64 body | 446.97 | 451.41 |
| Gene object identity reference | 483.31 | 479.89 |
| Qualified trivial send | 666.83 | 664.74 |
| Type-direct send | 782.29 | 786.56 |
| Disabled logging fixture | 1517.35 | 1536.61 |

The matched F64-body difference is roughly 133–141 ns/iteration in these
builds, consistent with the earlier independent Gene-loop probe. The empty
and constant controls are substantially below the old four-argument builtin
addition row, confirming that 270 ns was not a pure `run` entry/exit floor.
Neither subtraction isolates every component of another call path.

Nim allocator retention deltas are recorded; allocation counts are `-1`
because these timing builds did not enable `nimAllocStats`. Separate
instrumented runs are required before making allocation-rate claims. p95
with three samples is just the largest observed sample.
