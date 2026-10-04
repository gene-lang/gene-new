# Release application samples before P1 changes

Captured after the controlled baseline, with no concurrent assessment build or
benchmark. Host: macOS arm64, Nim 2.2.4, release/ORC with runtime checks.
The executable was the fresh default-mode `tmp/optimization-implementation/gene`.
Its SHA-256 is `2e40fd438126ac0d02018aeda9043929ce638d83f98b8a8d5791943e4f623015`.
The raw macOS `sample` reports are compressed here without modification; expand
them and run `benchmarks/summarize_sample.gene` to reproduce the JSON summaries.
Uncompressed report SHA-256 values are
`f9911e6340903cfe28452a81818be726dec6be92d1132553e1c8e593acf5033b`
(harness) and `bc9bd3e7f7caab2b5aba3c123e435de577ef0f738921d9b2d3d06a4d2c750fc9`
(worldgen).

Workloads, run from the repository root with an isolated `GENE_USER_PACKAGES`:

```sh
tmp/optimization-implementation/gene run examples/gene-harness/probes/performance.gene tmp/optimization-implementation/harness-profile 100
tmp/optimization-implementation/gene run examples/miclone/probes/run_worldgen.gene --repeat-seconds 15
```

Each was sampled once, starting about one second after launch, with
`sample PID 10 1 -mayDie -file REPORT`: ten seconds at a requested 1 ms interval.
Sampler and workload both exited successfully. The harness completed 100 real
service/turn/patch operations, asserted every output file, and reported 35,451 ms
including sampling overhead. World generation completed 20 batches of 16 blocks
in its bounded repeated-work phase. These profiled durations are not uninstrumented
speed baselines. The numeric workload is the native server's generator; the
client mesher runs on V8 and requires a separate web-backend investigation.

## Attribution

The Gene summary tool uses the **main-thread call tree**, subtracts direct-child
sample counts to obtain exclusive leaves, and attributes each leaf to its highest-
priority recognized ancestor. Recursive frames are counted once. It checks that
all exclusive leaves sum exactly to the main-thread total; its synthetic spec
also verifies recursion and idle-worker exclusion. Categories and precedence
are explicit in the tool. They are an investigation aid, not exact subsystem
CPU timers. Inlining/Clang outlining limits attribution; zeros below do not prove
a path costs nothing. Main-thread waits and unidentified VM work remain in the
unattributed bucket. The idle async-I/O worker is excluded.

| Bucket | Harness (7,219 samples) | Worldgen (7,622 samples) |
| --- | ---: | ---: |
| Publication / shared-graph marking | 47.83% | 0% |
| Scope escape / retention checks | 29.03% | 0.05% |
| Call binding / contracts | 0.33% | 22.61% |
| Name lookup | 0.61% | 16.20% |
| Reference counting outside the above | 1.11% | 11.18% |
| Allocation/copy outside the above | 1.69% | 2.09% |
| Unattributed, including waits and inlined work | 19.39% | 47.87% |

This ranks publication and escape work first for the service, then call/contract
and lookup work for native numeric execution. The microbenchmark's disabled-log
and monomorphic-send gaps remain useful controls, but these samples do not rank
them ahead of the observed application work.

Source inspection identifies a concrete publication candidate:
`publishSpawnValue` calls `markSharedValue` for each visited value, and the latter
allocates a fresh visited set and recursively marks that value's graph again.
Investigate sharing the marking visit set **within one publication traversal**,
while keeping it separate from VM scope/code visitation and fresh for every
publication. Preserve weak-scope promotion, ownership and concurrent handoff
contracts; do not turn it into a persistent "already shared" graph cache.
