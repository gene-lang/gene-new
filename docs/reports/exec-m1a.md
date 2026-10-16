# Exec M1a: readiness and lane delivery

M1a retains one worker for each active async child while replacing subprocess
I/O sleeps with the shared nonblocking pump and reusable lane notifications.
It includes the shared launcher, child-only directory/environment handling,
non-consuming exit observation and cleanup-before-reap rules.

The preserved `m1a-tree` snapshot includes the shared correctness fixes described
in the [full report](exec-milestone.md). Its standard-library driver still uses
the worker pool, and its local pipe adapters still require completion polling.

Median whole-operation times, milliseconds:

| Operation | macOS original | macOS M1a | Linux original | Linux M1a |
| --- | ---: | ---: | ---: | ---: |
| Root capture | 6.217 | 1.162 | 5.789 | 0.458 |
| Async capture | 7.566 | 1.324 | 6.345 | 0.447 |
| Synchronous inherited stdio | 1.030 | 1.029 | 0.337 | 0.318 |
| 1 MiB stdin pipe | 1671.763 | 35.879 | 1539.444 | 38.607 |
| 64 concurrent 20 ms children | 77.335 | 66.550 | 52.227 | 46.304 |
| File read behind 64 sleeping children | 1239.327 | 1226.666 | 1218.898 | 1212.192 |

M1a removes the fixed monitoring latency and materially improves I/O. It does
not resolve worker occupancy or the final stdin throughput budget. Those remain
visible in the file-read and pipe rows and are addressed by [M1b](exec-m1b.md).

The workloads validate exit status and byte counts on every timed action and
cover all six APIs at root and in root tasks. Shared launcher/pump/wake lifecycle
tests qualify their common mechanisms. The early M1a public environment suite
also passed before the shared-monitor implementation. Full final qualification,
including AtomicArc and sanitizers, is recorded separately in the full report.

[Samples, source archive, build provenance and gate definitions](../../benchmarks/baselines/2026-10-15-exec/README.md)
retain this stage independently of the final implementation. Measurements use
ORC release builds; they are not AtomicArc performance claims.
