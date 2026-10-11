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
| Integer loop | 2.883 | 0.905 | 3.18x | 4.86 |
| Closure dispatch | 7.422 | 2.906 | 2.55x | 7.23 |
| Filter/group/sort records | 10.609 | 4.461 | 2.38x | 4.97 |
| Text indexing | 28.344 | 15.766 | 1.80x | 9.27 |
| JSON round trip | 6.234 | 2.691 | 2.32x | 0.95 |
| Event replay | 11.953 | 5.211 | 2.29x | 8.12 |

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

## A regression found after the first capture

The first optimized build also lowered `==` and `!=` to the fast-operator
opcodes. Its numbers were captured, confirmed by an independent rebuild
(within about 3%), and committed — and then the Harness suite, run from a
clean export of the committed tree, showed one spec hanging with that build
and passing with the baseline: *Harness UI publication feedback repairs
render and action failures across model turns*. The run stalls at service
startup, before any `composition/changed` event.

Bisecting over the intermediate binaries and then over scratch builds of the
committed tree narrowed it to the `==`/`!=` lowering alone: with only that
withdrawn, the spec passes in its usual 16 seconds. Every direct comparison
of equality results — small Ints, wide Ints, Floats, strings, containers,
typed instances, nil and void operands, typed and untyped functions — still
matched the baseline, so the mechanism was **not isolated**. One side effect
of the lowering is that small predicates built from `==` begin to satisfy the
scopeless-call opcode whitelist; a build with the lowering restored but such
functions barred from scopeless calls still hung, so that is not the cause.

The corrected runtime therefore keeps `==` and `!=` as ordinary calls and
lowers only `/` and `//`. The same investigation found that the static error
analysis modelled every fast-operator opcode as "numeric operands or an open
error, result Int"; `/` and `//` are now modelled as the native calls they
replace, so division's own error effects are back.

All numbers and logs in this directory are from the corrected runtime. The
only workload that moved is event replay (2.50x before the correction, 2.29x
after), which is where `==` appears in the timed loop.

## Independent rebuild

A second binary built from a fresh cache and a clean export of the corrected
tree repeats the result. Three measured processes per executable, same size
and calibration: 3.08x (integer), 2.51x (closures), 2.42x (records), 1.79x
(text), 2.22x (JSON) and 2.34x (events), all outputs matching. See
[confirmation/report.md](confirmation/report.md).

## Harness service benchmark

The compute-kernel work above did not move the 100-turn Harness service
workload: 26.39 s on the baseline against 26.41 s. A profile of that workload
showed why. 46% of main-thread samples were in `publishSpawnCapture`, which
on every `spawn` re-walked the whole code graph reachable from the spawning
scope.

A chunk whose publication subtree is pure compile-time data is now walked
once and skipped afterwards. Three measured processes per executable after
an excluded warmup, rotating order, each with a fresh workspace
([service/summary.json](service/summary.json)):

| Build | Service median (ms) | Whole-process median (ms) |
| --- | ---: | ---: |
| Baseline `1e3f539` | 29731 | 39332 |
| Kernel work only | 27885 | 37908 |
| With remembered publication | 18709 | 23537 |

That is 1.59x on service time against the baseline in the same capture. The
general workloads do not spawn and are unaffected. Chunks that declare
types, enums, protocols, impls, macros, FFI, web modules or imports are still
walked on every spawn, because their walk reaches scopes or runtime state;
so is every scope. The Nim suites (including the AtomicArc VM suite and the
atomic generation-retirement test), the differential programs and the
complete Harness suite (179 passed) were rerun with this change; the
sanitizer, Cordis, benchmark-tooling and wasm rows below predate it. GIR
format advances to 30 for the two runtime-state fields on a chunk.

## Build provenance

```sh
nim c --nimcache:tmp/perf2/cache-baseline --hints:off -o:tmp/perf2/gene-baseline src/gene.nim   # at 1e3f539, before any edit
nim c --nimcache:<scratch>/cache-var --hints:off --warnings:off -o:tmp/perf2/gene-var-final2 src/gene.nim   # clean export of the corrected tree
```

Both report `release; macosx/arm64; Nim 2.2.4; mm=orc; nim-opt=speed;
bounds=true; overflow=true`. `general/metadata.json` records executable
hashes, the Git revision, worktree status and diff, and parameters;
`runtime-source-hashes.json` lists the two executables and the changed
source files. The optimized binary was built from a clean export of the
corrected tree, so it contains none of the unrelated, uncommitted work another
session had in the worktree that day; the diff recorded in
`general/metadata.json` is the worktree's and does include that work.

The GIR format advances from 28 to 29 (two operators joined the
compiler-known set). Rebuild older GIR artifacts.

## Qualification

| Check | Result |
| --- | ---: |
| Broad compiler/runtime/integration suite | 1685 passed |
| Executable language specs (28 new) | 874 passed |
| VM, ORC | 402 passed |
| VM, AtomicArc | 402 passed |
| Reference-count/lifetime suite | 87 passed |
| Harness, complete suite from a clean export | 179 passed |
| AddressSanitizer: lifetime suite | 87 passed, 0 reports |
| AddressSanitizer: VM suites except env/eval | 390 passed, 0 reports |
| Cordis | 21 passed |
| Benchmark tooling | 15 passed |
| wasm ABI cases, scratch build | 46 passed |

Every row is from the corrected runtime, built and run from a clean export
of the committed tree.

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

The complete Harness suite passes with the corrected runtime: 179 passed,
0 failed (`verification/harness-final.log.gz`), run from a clean export of
the committed tree so that edits another session was making to the Harness
sources could not affect it. Earlier runs are not counted: one overlapped
those edits, one used an export that lacked the repository docs the Harness
reads, and one overlapped heavy machine load that timed out web-host startup
specs which pass when rerun alone.

The sanitizer builds use `-d:useMalloc -fsanitize=address` in recover mode
with leak detection off. The VM selection omits the env/eval suite, whose
memory-limit fixture needs Nim's allocator counter; the ordinary ORC and
AtomicArc runs cover it. This pass changed how references are counted and
where they are borrowed, which is what the sanitizer run is for; the separate
lifetime suite checks retention.

This is a macOS arm64 qualification. Linux timing is not established; the
thread-local-load saving in particular is specific to how macOS implements
thread-local storage.
