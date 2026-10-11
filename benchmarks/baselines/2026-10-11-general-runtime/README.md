# General-purpose runtime optimization, second pass

Runtime baseline: `1e3f539` (the tree after the 2026-10-10 pass and its review
follow-ups). Optimized runtime: the working tree described in
[the implementation notes](../../../docs/proposals/general-runtime-optimization.md#second-pass-2026-10-11).
Host: macOS arm64, Nim 2.2.4, portable release, ORC, bounds and overflow
checks enabled. Python counterpart: Python 3.14.

## Results

Six measured fresh processes per executable, one excluded warmup, rotating
order, 5,000 input items per batch, 300 ms calibration per workload
([general/report.md](general/report.md), raw samples beside it):

| Workload | Baseline ms/batch | Optimized ms/batch | Baseline / optimized | Optimized / Python |
| --- | ---: | ---: | ---: | ---: |
| Integer loop | 2.887 | 0.939 | 3.07x | 5.05 |
| Closure dispatch | 7.469 | 2.965 | 2.52x | 7.35 |
| Filter/group/sort records | 10.641 | 4.465 | 2.38x | 4.88 |
| Text indexing | 28.625 | 15.984 | 1.79x | 9.35 |
| JSON round trip | 6.227 | 2.754 | 2.26x | 0.97 |
| Event replay | 12.047 | 4.828 | 2.50x | 7.44 |

Every result matches the baseline runtime and Python at sizes 1, 17, 257 and
2048 and in every timed process. These are separate workloads, not a weighted
language score. Python remains faster on five of the six.

Against the runtime before either pass (`f9d731c`, using the 2026-10-10
archive's baseline column measured on a busier machine) the two passes
together are roughly 3.5x to 8x; that comparison spans two captures and is
indicative only.

Kernels outside the suite, one process each, baseline then optimized
([differential/extra_kernels.gene](differential/extra_kernels.gene)):

| Kernel | Baseline ms | Optimized ms |
| --- | ---: | ---: |
| `fib 27`, untyped / typed | 42 / 39 | 42 / 38 |
| 200k sends and constructions on a declared type | 464 | 384 |
| 200k interpolated strings joined | 146 | 91 |
| 300k-element list: push, index, filter | 369 | 135 |
| 2M-iteration `while` | 269 | 187 |
| 500k higher-order closure calls | 361 | 313 |
| 300k three-way literal `match` | 226 | 150 |

These were single runs taken before the last small batch and are here to show
that paths the suite does not cover moved in the same direction, not as
precise figures. Direct recursive calls were already fast and did not change.

## Independent rebuild

A second optimized binary built from a fresh cache repeats the result. Three
measured processes per executable, same size and calibration: 2.99x
(integer), 2.44x (closures), 2.32x (records), 1.84x (text), 2.28x (JSON) and
2.53x (events), all outputs matching. Its medians are within about 3% of the
first build's. See [confirmation/report.md](confirmation/report.md).

No compiler, test suite or profiler from this work overlapped either timing
capture. The workstation is shared, and another session was editing files in
the same worktree during the day.

## Build provenance

```sh
nim c --nimcache:tmp/perf2/cache-baseline --hints:off -o:tmp/perf2/gene-baseline src/gene.nim   # at 1e3f539, before any edit
nim c --nimcache:tmp/perf2/cache-work --hints:off --warnings:off -o:tmp/perf2/gene-b7 src/gene.nim
nim c --nimcache:tmp/perf2/cache-confirm --hints:off --warnings:off -o:tmp/perf2/gene-confirm src/gene.nim
```

All three report `release; macosx/arm64; Nim 2.2.4; mm=orc; nim-opt=speed;
bounds=true; overflow=true`. `general/metadata.json` records executable
hashes, the Git revision, worktree status and diff, and parameters;
`runtime-source-hashes.json` lists the three executables and the changed
source files. The
worktree at capture time also held another session's unrelated, uncommitted
standard-library addition (`$binary/decode_utf8`) and Harness edits; they are
in the recorded diff and in the optimized binary, and touch none of the
measured paths.

The GIR format advances from 28 to 29 (four operators joined the
compiler-known set). Rebuild older GIR artifacts.

## Qualification

| Check | Result |
| --- | ---: |
| Broad compiler/runtime/integration suite | 1687 passed |
| Executable language specs (28 new) | 874 passed |
| VM, ORC | 402 passed |
| VM, AtomicArc | 402 passed |
| Reference-count/lifetime suite | 87 passed |
| AddressSanitizer: lifetime suite | 87 passed, 0 reports |
| AddressSanitizer: VM suites except env/eval | 390 passed, 0 reports |
| Cordis | 21 passed |
| Benchmark tooling | 15 passed |
| wasm ABI cases, scratch build | 46 passed |
| Harness | **not established** — see below |

The 28 new specs (`spec — runtime fast paths keep ordinary semantics`) pin
the behaviours a shortcut could change: operator results and errors, operator
shadowing, dynamic paths, map keys, namespace and by-name rebinding, JSON
numbers, keys, escapes and error text, sort stability, literal `match`, and
captured loop variables. Each expectation was produced by the baseline binary.

During development the same programs, plus a multi-module import case and
thirteen `gene eval` sources, were run on the baseline and candidate binaries
after every batch and compared byte for byte. They are kept in
`differential/` with the runner as it was used (its paths point at the
scratch binaries).

The wasm target was compiled to a scratch directory and passed
`tests/test_wasm.mjs` through `GENE_WASM_MODULE`. The tracked `web/gene.js`
and `web/gene.wasm` were not regenerated.

### Harness

The Harness suite was run once with the optimized binary and reported **180
passed, 9 failed** (`verification/harness-final.log.gz`). That run does not
qualify or disqualify this change: another session was editing the Harness
sources in the same worktree while it ran. One failure quotes a read error in
`client/media.gene`, an untracked file from that work, on a line the file no
longer contained by the end of the run; the others are web-host specs that
exited without output. The failures were not reproduced against the committed
Harness tree, and the 100-turn Harness service benchmark was not rerun for
this pass. Both should be run once the Harness tree is settled:

```sh
cd examples/gene-harness && GENE_BINARY=/path/to/gene /path/to/gene test
GENE_BENCH_SAMPLES=3 bin/gene run benchmarks/run_harness.gene tmp/new-service /path/to/before-gene /path/to/after-gene
```

One language spec, `recursive watch discovers files in newly created
directories`, failed once while five suites compiled in parallel and passed
in the final run; it depends on filesystem-event timing and exercises nothing
changed here.

The sanitizer builds use `-d:useMalloc -fsanitize=address` in recover mode
with leak detection off. The VM selection omits the env/eval suite, whose
memory-limit fixture needs Nim's allocator counter; the ordinary ORC and
AtomicArc runs cover it. This pass changed how references are counted and
where they are borrowed, which is what the sanitizer run is for; the separate
lifetime suite checks retention.

This is a macOS arm64 qualification. Linux timing is not established; the
thread-local-load saving in particular is specific to how macOS implements
thread-local storage.
