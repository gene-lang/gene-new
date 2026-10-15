# General-purpose and Harness runtime optimization

Runtime baseline: `f9d731c`. Optimized runtime: `349dab2`.
Work branch: `perf/general-workloads`.
Host qualification: macOS arm64, Nim 2.2.4, portable release, ORC, bounds and
overflow checks enabled. Python counterpart: Python 3.14.3.

## Results

The final runtime reduces scope allocation, temporary pattern-binding tables,
reference-count churn during read-only lookup, and copying in graph-retention
checks. Source syntax, execution budgets, construction/authority checks, and
tail-call eligibility rules are preserved. See the
[implementation and investigation notes](../../../docs/reports/general-runtime-optimization.md).

Six measured fresh processes per executable, one excluded warmup, rotating
order, 5,000 input items per batch, and 300 ms calibration per workload:

| Workload | Baseline ms/batch | Optimized ms/batch | Baseline / optimized |
| --- | ---: | ---: | ---: |
| Integer loop | 7.609 | 4.367 | 1.74x |
| Closure dispatch | 15.094 | 11.344 | 1.33x |
| Filter/group/sort records | 21.656 | 15.906 | 1.36x |
| Text indexing | 59.188 | 42.688 | 1.39x |
| JSON round trip | 12.281 | 9.188 | 1.34x |
| Event replay | 21.938 | 18.281 | 1.20x |

Every result matches both the original runtime and Python. These are separate
workloads, not a weighted overall language score. Python remains faster on
these cases; the full comparison is in [general/report.md](general/report.md).
Raw samples and distributions are in `general/`. The shared workstation had
other applications running; the longer final capture has much narrower spread
than the initial exploratory capture, which is not used for headline claims.

The real Harness workload performs 100 sequential model-free turns, applies
100 patches, waits for successful durable receipts, and reads transcript
snapshots. Each process uses a fresh workspace. Three measured processes per
binary follow an excluded warmup, with rotating order:

| Build | Service samples (ms) | Service median (ms) | Whole-process median (ms) |
| --- | --- | ---: | ---: |
| Unchanged baseline | 52018, 56936, 53105 | 53105 | 74993 |
| Optimized runtime | 38621, 37951, 38117 | 38117 | 52666 |

The service median improves **1.39x**, or about **28% less elapsed time**.
Every run verified checksum **15100**, completed receipts, and exact contents
of all 100 patched files. Whole-process time also includes startup and teardown;
it must not be presented as pure turn time. Workload version 2 uses the current
scripted profile, so these absolute times are not comparable with the older
October 4 callback-based workload.

## Independent rebuild

An independent fresh-cache rebuild repeats the improvement. Three measured
processes per executable at the same size and calibration give speedups of
1.71x (integer), 1.37x (closures), 1.37x (records), 1.38x (text), 1.32x (JSON),
and 1.19x (events). All outputs match. Its optimized medians are within about
2.3% of the first final build's medians. See
[confirmation/report.md](confirmation/report.md) and the accompanying raw
samples and executable hashes. This confirms the general workloads; the
100-turn application capture above uses the first final build.

## Build and source provenance

The baseline and final release CLIs were compiled independently from fresh
caches using the same command structure:

```sh
nim c --nimcache:tmp/general-optimization/cache-before --hints:off -o:tmp/general-optimization/gene-baseline src/gene.nim
nim c --nimcache:tmp/general-optimization/cache-v3 --hints:off -o:tmp/general-optimization/gene-v3 src/gene.nim
nim c --nimcache:tmp/general-optimization/cache-confirm --hints:off -o:tmp/general-optimization/gene-confirm src/gene.nim
```

The first command used the unchanged runtime source; generated C was complete
before edits began. The other two use the final source. All builds report
`release; macosx/arm64; Nim 2.2.4; mm=orc; nim-opt=speed; bounds=true;
overflow=true`. No compiler, test suite, or profiler from this task overlapped
the timing captures.

Binary hashes, version output, Git revision/worktree/diff, OS, parameters, raw
stdout/stderr and workload source snapshots accompany the results. The captures
precede the final commits; the saved source diff records the measured worktree.
`runtime-source-hashes.json` identifies the final runtime files. Large temporary
workspaces remain under `tmp/general-optimization/`, outside this archive.

The internal GIR format changes from 27 to 28 for scope-reuse metadata. Rebuild
older GIR artifacts; source-language syntax is unchanged.

## Qualification

| Check | Result |
| --- | ---: |
| Broad compiler/runtime/integration suite | 1678 passed |
| Executable language specs | 846 passed |
| VM, ORC | 395 passed |
| VM, AtomicArc | 395 passed |
| Reference-count/lifetime suite | 87 passed |
| AddressSanitizer VM selection | 383 passed |
| Cordis | 21 passed |
| Harness | 178 passed in full run; corrected trigger file 3/3 passed (179 unique cases covered) |
| Benchmark tooling | 15 passed |

The ASan build uses `-d:useMalloc`, `-fsanitize=address`, and
`ASAN_OPTIONS=detect_leaks=0`. It runs all VM suites except env/eval, whose
allocation-limit fixture depends on Nim's occupied-memory counter. That counter
is unavailable under useMalloc, so the original unfiltered run was stopped at
that fixture. Its incomplete log is retained, and is not counted as a pass.
Normal ORC/AtomicArc runs cover all 395 cases, including the memory-budget
checks. The separate RC suite checks managed retention; ASan is not a leak
qualification. `verification/run-asan-vm.gene` preserves the exact selection.

The tests cover captured and native-retained scopes, per-iteration state,
loop exits, cancellation, borrowed caller environments, cyclic graphs, node
heads, aliased lookup output, temporary namespaces, and artifact cloning.
Some stale pre-existing flag/diagnostic/LSP fixtures were repaired in a separate
commit after baseline reproduction; runtime parsing behavior was not changed.

The initial final-build Harness run was **178 passed, 1 failed**. The failure
was its short activation-expiry fixture: a one-second global budget could time
out required documentation/command plugins during startup, leaving the trigger
due but unable to admit a round. Startup diagnostics reproduced those timeouts
on both baseline and optimized runtimes. The fixture now allows five seconds
for activation, verifies required plugins are ready, and waits 6.5 seconds
before scheduling work. Its 20-second trigger-completion bound is unchanged.
The corrected three-case file passes on the optimized runtime, and the revised
expiry case also passes on the baseline. This retains the expired-activation
invariant; it is not a runtime-budget change. The full suite was not rerun
after this test-only correction. Initial, diagnostic and focused logs are
retained under `verification/`.

This is a macOS arm64 qualification. It does not establish Linux timing,
production AtomicArc reclamation, arbitrary native-extension safety, or a new
sustained-service qualification.

## Profile evidence and reproduction

The v2 application profile (before the final retention-walk optimization)
accounts for all 10,584 main-thread samples: 50.13% in scope retention/escape
and 30.92% in publication. Idle workers are excluded. The compressed profile
and summary are in `profile/`; profile percentages are not absolute subsystem
timers and the profiled duration is excluded from timing distributions.

From the repository root, with fresh output directories and preserved binaries:

```sh
GENE_BENCH_SAMPLES=6 GENE_BENCH_TARGET_MS=300 bin/gene run benchmarks/run_general.gene tmp/new-general /path/to/after-gene /path/to/python3 5000 /path/to/before-gene
GENE_BENCH_SAMPLES=3 bin/gene run benchmarks/run_harness.gene tmp/new-service /path/to/before-gene /path/to/after-gene
```

Use an isolated `GENE_USER_PACKAGES` when running under a filesystem sandbox.
Keep assessment builds, tests and profiling out of the measurement window.
