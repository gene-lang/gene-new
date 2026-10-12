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
| Integer loop | 2.805 | 0.908 | 3.09x | 4.94 |
| Closure dispatch | 7.219 | 2.809 | 2.57x | 6.99 |
| Filter/group/sort records | 10.344 | 4.215 | 2.45x | 4.78 |
| Text indexing | 27.656 | 15.250 | 1.81x | 9.07 |
| JSON round trip | 6.078 | 2.645 | 2.30x | 0.96 |
| Event replay | 11.750 | 4.504 | 2.61x | 7.06 |

This capture was taken one change before the final runtime. The last change
touches only spawn publication and the walks' visited sets, which these
workloads do not exercise; a recapture afterwards was disturbed by other
load on the machine (samples of one build six times apart) and is not
recorded, though its fastest samples are within 3% of this table.

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
render and action failures across model turns*.

Bisecting over the intermediate binaries and then over scratch builds of the
committed tree narrowed it to the `==`/`!=` lowering alone, while every
direct comparison of equality results still matched the baseline. The
lowering was withdrawn and the numbers recaptured without it. The same
investigation found that the static error analysis modelled every
fast-operator opcode as "numeric operands or an open error, result Int";
`/`, `//`, `==` and `!=` are now modelled as the native calls they replace.

### What the hang was

Equality was never wrong. Lowering it shortens the bytecode, a root-lane
fiber is paused after 512 instructions wherever that falls, and one pause
moved into `(instance/runtime/executor/queue/.get .push request)` in Cordis's
`request_transition` — after the queue List was read, before the push. The
executor swapped the List out in that gap, the request landed on a List
nobody would read again, and the turn that joined the transition waited
forever. [slice-race/](slice-race/) holds the evidence:

| File | What it shows |
| --- | --- |
| `site-bisect.log` | Turning the lowering off per call site, without rebuilding: the hang needs exactly sites 18 (line 587) and 48 (line 1030) of `cordis/src/runtime.gene` lowered together |
| `vm-instrumentation.patch` | The three VM-only additions (idle fiber dump, cancel-injection log, budget-pause log) applied to the hanging commit; the bytecode is unchanged, so the hang reproduces under them |
| `fiber-dump.txt` | The hung state: the turn fiber parked in `TransitionTicket.join` on the request's `ready` channel, the executor parked on its wake channel |
| `pause-log-excerpt.txt` | That fiber's last pause: `runtime.gene:1043`, instruction 92, after `opResolveMessage` and before the argument load |
| `straight_line_probe.gene` | The hazard in isolation: 11 of 400 phases lose a push on the baseline binary and on every optimized one |
| `liveness_probe.gene` | Every loop and recursion form still yields to a peer under the new rule |

The scheduler now pauses a fiber whose slice is spent at the next function
entry, `for` iteration, backward loop jump or `continue`, never inside
straight-line code. With that rule the probe loses nothing and the spec
passes with `==` and `!=` lowered, so the lowering is back.

The table under Results is from that final runtime. The capture taken while
the lowering was withdrawn read 3.18x, 2.55x, 2.38x, 1.80x, 2.32x and 2.29x
in the same order; event replay, the one workload with `==` in its timed
loop, is the only one that moved beyond run-to-run variation.

## Independent rebuild

A second binary built from a fresh cache and a clean export repeated the
result for the runtime as it stood while the lowering was withdrawn. Three measured processes per executable, same size
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
complete Harness suite (179 passed) were rerun with this change. The
sanitizer, lifetime, Cordis, benchmark-tooling and wasm rows below were
rerun on the final head, after all three service-time changes, with the
same counts and no sanitizer reports. GIR
format advances to 30 for the two runtime-state fields on a chunk.

A later change skips the caller-env escape walk in a process that has never
created a CallerEnv. On a busy machine the service median was 22.8 s with it
against 25.3 s without (three samples each, overlapping); the size is
roughly 10% and is not a clean measurement. The Nim suites, the differential
programs and the complete Harness suite (179 passed) pass with it.

A third change skips the tail-call capture walk for frames whose scope the
VM already recycles. Service median 15.27 s with it against 17.37 s without
(three samples each, one capture). Nim suites, differential programs and
the complete Harness suite (179 passed) pass with it.

A final capture measures the starting tree against the final build directly
(three samples each, rotating order, quiet machine;
[service/summary.json](service/summary.json) is this capture):

| Build | Service samples (ms) | Service median (ms) | Whole-process median (ms) |
| --- | --- | ---: | ---: |
| Baseline `1e3f539` | 26091, 25205, 25244 | 25244 | 34509 |
| Final build | 14936, 14698, 15493 | 14936 | 18193 |

That is 1.69x on service time and 1.90x on whole-process time.

The slice rule and the restored `==`/`!=` lowering do not move this workload.
Two later captures on a busier machine, three samples per build each
([service/summary-slice-rule.json](service/summary-slice-rule.json) is the
first):

| Build | Service median, first capture (ms) | Second capture (ms) |
| --- | ---: | ---: |
| Baseline `1e3f539` | 26939 | 28846 |
| Final build above | 15883 | 16185 |
| With the slice rule and lowering | 15417 | 16248 |

The walks that dominated the profile at that point were then made cheaper
(a tail-fallback reason computed only for the diagnostics that read it, a
reusable visited set for the escape scan and the capture walk, leaves kept
out of the publication sets, and those sets reused across spawns; see the
implementation notes). One capture, three samples per build
([service/summary-walks.json](service/summary-walks.json)):

| Build | Service samples (ms) | Service median (ms) | Whole-process median (ms) |
| --- | --- | ---: | ---: |
| Baseline `1e3f539` | 27311, 26564, 26684 | 26684 | 36197 |
| With the slice rule and lowering | 15499, 15470, 15893 | 15499 | 18836 |
| With the cheaper walks | 11752, 11681, 11807 | 11752 | 14152 |

That is 1.32x over the previous build and, against the starting tree,
2.27x on service time and 2.56x on whole-process time.

A last change reads containers in place during publication instead of
copying every item and key, and moves a walk's inline visited entries into
its set once they overflow. One quiet capture, three samples per build
([service/summary-walks2.json](service/summary-walks2.json)):

| Build | Service samples (ms) | Service median (ms) | Whole-process median (ms) |
| --- | --- | ---: | ---: |
| With the cheaper walks | 11343, 11332, 11494 | 11343 | 13718 |
| Reading containers in place | 9792, 9802, 9934 | 9802 | 11592 |
| And spilling inline entries | 9670, 9690, 9705 | 9690 | 11393 |

That is a further 1.17x. The starting tree was not in this capture; three
later attempts to measure all three builds together were disturbed by other
load on the machine (single samples two to four times the rest) and are not
recorded. Taking the two captures together the service workload is about
2.7x faster than on the starting tree.

## Build provenance

```sh
nim c --nimcache:tmp/perf2/cache-baseline --hints:off -o:tmp/perf2/gene-baseline src/gene.nim   # at 1e3f539, before any edit
nim c --nimcache:<scratch>/ncfix --hints:off --warnings:off -o:tmp/perf2/gene-walk5 src/gene.nim   # clean export of 83eeaf9 plus in-place reads and the spill change
```

Both report `release; macosx/arm64; Nim 2.2.4; mm=orc; nim-opt=speed;
bounds=true; overflow=true`. `general/metadata.json` records executable
hashes, the Git revision, worktree status and diff, and parameters;
`runtime-source-hashes.json` lists the two executables and the changed
source files. The optimized binary was built from a clean export with only
this pass's files laid over it, so it contains none of the unrelated,
uncommitted work another session had in the worktree that day; the diff recorded in
`general/metadata.json` is the worktree's and does include that work.

The GIR format advances from 28 to 29 (two operators joined the
compiler-known set). Rebuild older GIR artifacts.

## Qualification

| Check | Result |
| --- | ---: |
| Broad compiler/runtime/integration suite | 1688 passed |
| Executable language specs (35 new) | 881 passed |
| VM, ORC | 402 passed |
| VM, AtomicArc | 402 passed |
| Reference-count/lifetime suite | 87 passed |
| Harness, complete suite from a clean export | 200 passed |
| AddressSanitizer: lifetime suite | 87 passed, 0 reports |
| AddressSanitizer: VM suites except env/eval | 390 passed, 0 reports |
| Cordis | 21 passed |
| Benchmark tooling | 15 passed |
| wasm ABI cases, scratch build | 46 passed |

Every row is from the final runtime (slice rule, `==`/`!=` lowered, cheaper
walks, in-place reads). The binary and the suites were built from clean
exports of `83eeaf9` with the changed files laid over them. On the build before the walk changes one file-watch spec (`recursive watch discovers files in newly
created directories`) failed once while five suites compiled in parallel and
passed six of six alone and in a solo rerun; it depends on how the OS
batches file events. It failed the same way once more in the final run's
parallel phase and passed in the solo run recorded here.

The 28 new specs (`spec — runtime fast paths keep ordinary semantics`) pin
the behaviours a shortcut could change: operator results and errors, operator
shadowing, dynamic paths, map keys, namespace and by-name rebinding, JSON
numbers, keys, escapes and error text, sort stability, literal `match`, and
captured loop variables. Each expectation was produced by the baseline binary.

Two more (`spec — a scheduler slice ends at a loop iteration or a function
entry`) pin the slice rule: straight-line read-then-update code is not split
between fibers (the baseline loses a push in 11 of its 300 phases), and every
loop and recursion form still yields a spent slice to a peer.

Five more put over sixteen containers in one graph for each value-graph
walk, past what the walks keep inline: a function forty containers deep in a
stored value, a stored ring with a shared part, a tail call passing a large
value that holds a closure over the caller, repeated spawns over a captured
List, and a large value stored twice. Their expectations also come from the
baseline binary.

During development the same programs, plus a multi-module import case and
thirteen `gene eval` sources, were run on the baseline and candidate binaries
after every batch and compared byte for byte. They are kept in
`differential/` with the runner as it was used (its paths point at the
scratch binaries).

The wasm target was compiled to a scratch directory and passed
`tests/test_wasm.mjs` through `GENE_WASM_MODULE`. The tracked `web/gene.js`
and `web/gene.wasm` were not regenerated.

### Harness

The complete Harness suite passes with the final runtime: 200 passed,
0 failed in 329 seconds (`verification/harness-final.log.gz`; 527 seconds
before the walk changes, 407 before the in-place reads), run
from a clean export so that edits another session was making could not
affect it. The suite grew from 179 examples during the day through that
session's commits; the runtime that withdrew the lowering passed all 179. Earlier runs are not counted: one overlapped
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
