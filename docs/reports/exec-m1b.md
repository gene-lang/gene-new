# Exec M1b: one monitor for live processes

M1b moves async process lifetimes from workers to one native readiness monitor.
Inherited terminal handoffs remain serialized. File jobs retain their existing
pool, so long-running children no longer hold its workers. Local pipe adapters
notify the owning lane, and native line publication wakes once per ready chunk.

Median whole-operation times, milliseconds:

| Operation | macOS M1a | macOS final | Linux M1a | Linux final |
| --- | ---: | ---: | ---: | ---: |
| Capture inside a root task | 1.277 | 1.088 | 0.469 | 0.363 |
| 1 MiB stdin pipe | 35.879 | 3.339 | 38.607 | 2.319 |
| 1 MiB stdout pipe | 23.762 | 3.084 | 25.160 | 2.101 |
| 64 concurrent 20 ms children | 66.550 | 42.174 | 46.304 | 36.710 |
| File read behind 64 sleeping children | 1226.666 | 3.091 | 1212.192 | 1.604 |

The first M1b candidate missed the fixed stdin-throughput gate. Sampling
attributed 88% of main-thread samples to byte slicing. The final candidate uses
a bulk copy for owned byte slices, with overflow-safe bounds checks. The same
gate then passed; the original failed capture remains in the evidence.

All 44 final performance gates pass on both qualified platforms. A controlled
runtime test records at least 64 active children and one monitor, while short
commands and file reads progress. A slow consumer receives every byte without
suspending unrelated children. The ownership tests cover cancellation, timeout,
shutdown, stale signal authority, new wake registration during sleep, and
exec-only waits without periodic scheduler wakeups.

See the [full report and verification matrix](exec-milestone.md) and the
[reproducible evidence](../../benchmarks/baselines/2026-10-15-exec/README.md).
Cleanup-context and timeout-origin distinctions remain unchanged; native
pipelines, shell parsing and broad native-adapter migration remain deferred.
