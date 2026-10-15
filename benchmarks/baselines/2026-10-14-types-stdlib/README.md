# Typed boundaries and stdlib dispatch — 2026-10-14

Evidence for the scoped implementation of `tmp/optimization.md`. All numbers
are from one shared macOS/arm64 workstation, Nim 2.2.4, ORC release builds with
bounds and overflow checks enabled. They describe these workloads and builds.

## Executables and source

| Role | SHA-256 |
| --- | --- |
| Baseline (`014eb0c2`, before VM changes) | `41f0414cca02ca6741b9a6d1dea509c635fe8b1cf7aa5e9951ef7d3ebd510eac` |
| Final | `193173af215b1ba6592963ac775637110d4bf22352fedc6266eb8546d1ba6c87` |

[Build/source hashes](builds/) identify each executable. Benchmark metadata
records the worktree at measurement time, which can contain later source edits;
the recorded build source hashes identify the actual executable inputs.
The final binary is installed as `bin/gene` after qualification. Binaries,
compiler caches and generated test workspaces are not retained here.

Harness comparisons use identical source, including the receipt retention fix
and the guard avoiding a copy when there are at most 128 receipts.

## Results

Operation results use one excluded warmup process and three measured fresh
processes per executable, rotating executable order. Each row performs one
million iterations. Gross time includes loop work. Net time subtracts that
process's empty-loop control; it is a diagnostic estimate, not application cost.
Raw rows and provenance: [operations](operations/summary.json).

| Operation | Baseline gross ns | Final gross ns | Baseline net ns | Final net ns |
| --- | ---: | ---: | ---: | ---: |
| Typed Int counter | 144 | 70 | 92 | 16 |
| Typed Float stores | 198 | 129 | 146 | 74 |
| Any call | 456 | 356 | 404 | 303 |
| Float parameter and result call | 389 | 359 | 337 | 305 |
| String parameter and result call | 441 | 411 | 389 | 357 |
| Mixed two-argument typed call | 430 | 397 | 378 | 342 |
| Stdlib-path native call | 184 | 118 | 132 | 63 |
| Native bound to a local | 118 | 104 | 66 | 49 |
| Untyped call control | 169 | 166 | 117 | 112 |

Not every microbenchmark became faster. The empty-loop control moved from
52 to 54 ns and buffer writes from 326 to 339 ns. No uniform opcode speedup is
claimed. The complete row set is retained, including those controls.

General workloads use five measured processes after warmup, with calibrated
batches targeting 200 ms. Results were checked against the Python reference
at sizes 1, 17, 257 and 2048 before timing. No final general-workload median is
higher than the original baseline. [Full distributions](general/summary.json),
[previous-stage comparison](general-step5/summary.json), and
[comparison against native dispatch alone](general-vs-native/summary.json).

| General workload | Baseline ms/batch | Final ms/batch |
| --- | ---: | ---: |
| Integer loop | 0.7852 | 0.7773 |
| Closure dispatch | 2.7031 | 2.7031 |
| Records | 4.0313 | 3.7031 |
| Text index | 14.3750 | 12.2188 |
| JSON round trip | 2.5781 | 2.5000 |
| Event replay | 4.3906 | 3.7344 |

Harness uses one excluded warmup and three measured fresh workspaces per
executable, rotating order. Service timing excludes snapshot capture and
startup; process timing includes them. Checkpoints and durability are unchanged.

| Workload | Checksum | Baseline service median | Final service median | Baseline process median | Final process median |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 turns | 15100 | 7657 ms | 7507 ms | 9639 ms | 9467 ms |
| 200 turns | 35100 | 17857 ms | 17754 ms | 19986 ms | 19866 ms |

[100-turn raw runs](harness-100/summary.json) and
[200-turn raw runs](harness-200/summary.json). The modest application improvement
is consistent with the workload's substantial filesystem and waiting costs.
It should not be extrapolated to external model latency or other applications.

The [final service profile](profile/summary.json) sampled six seconds of a
separate scripted 200-turn run. Its 4,049 main-thread samples include 727 in
`__semwait_signal`; open, rename, unlink, link, fsync and stat also appear near
the top. The ancestor buckets leave about 80% outside their recognized groups,
so they are not an upper bound on optimization opportunity. This sampled run
is diagnostic evidence and is excluded from the timing distributions.

## Qualification

| Gate | Result | Evidence |
| --- | --- | --- |
| VM under ORC | 428 passed | [log](verification/vm-orc.txt) |
| VM under AtomicArc | 428 passed | [log](verification/vm-atomic.txt) |
| Executable language specs | 892 passed | [log](verification/specs.txt) |
| Lifetime/refcount suite | 90 passed | [log](verification/lifetime.txt) |
| Real AtomicArc workers | 50 passed | [log](verification/workers.txt) |
| Harness | 254 passed | [log](verification/harness.txt) |
| ASAN: new boundaries/calls/caches | 25 passed; no ASAN errors | [log](verification/asan-boundaries-calls-caches.txt) |
| Deeper cache replacement: ORC / AtomicArc / ASAN | 8 passed in each run | [ORC](verification/deep-cache-orc.txt), [AtomicArc](verification/deep-cache-atomic.txt), [ASAN](verification/deep-cache-asan.txt) |

Loopback TCP/HTTP fixtures ran with local networking permitted. ASAN used
`detect_leaks=0:halt_on_error=1`; refcount/lifetime assertions separately cover
retention. The deeper-path assertion was added after the full VM runs and
rechecked in all three modes; production source did not change.

## Reproduction

Build baseline and candidate independently before timing. Runtime build:

```sh
nim c -d:release --path:src --hints:off --warnings:off --nimcache:NEW_CACHE -o:NEW_EXE src/gene.nim
```

From the repository root, with fresh output/workspace directories:

```sh
GENE_BENCH_SAMPLES=3 bin/gene run benchmarks/run_ops.gene NEW_OPS 1000000 BASELINE_EXE FINAL_EXE
GENE_BENCH_SAMPLES=5 GENE_BENCH_TARGET_MS=200 bin/gene run benchmarks/run_general.gene NEW_GENERAL FINAL_EXE PYTHON_EXE 5000 BASELINE_EXE
GENE_BENCH_SAMPLES=3 bin/gene run benchmarks/run_harness.gene NEW_HARNESS BASELINE_EXE FINAL_EXE
GENE_BENCH_SAMPLES=3 GENE_BENCH_TURNS=200 bin/gene run benchmarks/run_harness.gene NEW_LONG_HARNESS BASELINE_EXE FINAL_EXE
```

Use writable `GENE_USER_PACKAGES` and `GENE_ARTIFACT_STORE` directories when
running in a restricted environment. Finish builds and other test workloads
before collecting timings. See the benchmark metadata for exact versions,
source state, source hashes, iteration counts and individual measurements.
