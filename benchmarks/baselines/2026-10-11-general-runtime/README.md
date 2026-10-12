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
| Integer loop | 2.707 | 0.872 | 3.10x | 4.81 |
| Closure dispatch | 6.992 | 2.781 | 2.51x | 7.02 |
| Filter/group/sort records | 10.078 | 4.086 | 2.47x | 4.63 |
| Text indexing | 26.750 | 14.469 | 1.85x | 8.71 |
| JSON round trip | 5.867 | 2.543 | 2.31x | 0.93 |
| Event replay | 11.484 | 4.402 | 2.61x | 6.99 |

This capture is of the final runtime, taken on a quiet machine after the
last change (samples of one build within 14% of each other). Earlier
captures in this directory's history bracket it: 3.18x, 2.55x, 2.38x, 1.80x,
2.32x and 2.29x while the `==` lowering was withdrawn, and 3.09x, 2.57x,
2.45x, 1.81x, 2.30x and 2.61x before the last three changes.

The last change of the pass lets a loop body that contains only reusable
loops reuse its own iteration scope. Its kernel
([differential/loop_kernels.gene](differential/loop_kernels.gene), 200 rows
of three items) runs in 200-214 ms instead of 230-239 ms, and a before/after
capture of the workloads reads 15.63 ms to 14.69 ms for text indexing.

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

Event replay, the one workload with `==` in its timed loop, is the only one
the lowering moved beyond run-to-run variation: 2.29x without it, 2.5-2.6x
with it.

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

That is a further 1.17x. The starting tree was not in this capture, and the
machine did not stay quiet for another: three attempts to measure all three
builds together had single samples two to four times the rest and are not
recorded. A fourth, with every build slowed by about a third but only one
stray sample
([service/summary-walks3-loaded.json](service/summary-walks3-loaded.json)),
reads 34.72 s on the starting tree, 16.18 s with the cheaper walks and
13.15 s on the build with in-place reads: 2.64x. The two quiet captures
taken together give about 2.7x.

The final change counts published objects in place (an atomic add, and a
compare-and-exchange that never reaches zero) instead of calling the full
body for each. A CPU-only probe that publishes 2,000 rows and reads them in
a loop ([differential/published_counting_probe.gene](differential/published_counting_probe.gene))
runs in 206-215 ms instead of 268-273 ms over four alternating runs. The
service capture for it was again taken under load
([service/summary-counting-loaded.json](service/summary-counting-loaded.json)):
35.31 s on the starting tree, 14.70 s before the change and 13.53 s after
(samples 13.27-14.98 s and 13.14-14.15 s), so about 8% on this workload and
2.6x overall in that capture.

A last capture measures the starting tree against the final build of the
whole pass directly, three samples each with no stray sample, on a machine
that was not fully quiet ([service/summary-final.json](service/summary-final.json)):

| Build | Service samples (ms) | Service median (ms) | Whole-process median (ms) |
| --- | --- | ---: | ---: |
| Baseline `1e3f539` | 29474, 31421, 31355 | 31355 | 41592 |
| Final build | 9581, 11758, 12029 | 11758 | 13489 |

That is 2.67x on service time and 3.08x on whole-process time.

## Publishing only worker-safe tasks

The last change makes `spawn` publish its captured graph only for a
worker-safe task, the rule an actor's handler fiber already followed. Five
samples per build in one capture on a moderately loaded machine
([service/summary-worker-publication.json](service/summary-worker-publication.json)):

| Build | Service samples (ms) | Service median (ms) | Whole-process median (ms) |
| --- | --- | ---: | ---: |
| Before | 11981, 11467, 11834, 11539, 12399 | 11834 | 14238 |
| Publishing only worker-safe tasks | 10478, 11169, 10335, 12264, 10935 | 10935 | 12188 |

That is about 8% on service time and 14% on whole-process time, and the
complete Harness suite runs in 285 s instead of about 345 s. A lifetime test
now holds the typed-instance program that used to keep 41 objects at zero.
The general table and the direct baseline capture above predate this change;
the general workloads do not spawn. Four complete Harness runs soaked the
change afterwards, all passing in 270-288 s with no crash report, and on the
final tree the VM suite passed six times in a row and the spec suite three.

A direct capture of the starting tree against this final build, three
samples each on a quiet machine
([service/summary-final-worker-publication.json](service/summary-final-worker-publication.json)):

| Build | Service samples (ms) | Service median (ms) | Whole-process median (ms) |
| --- | --- | ---: | ---: |
| Baseline `1e3f539` | 25161, 25480, 25816 | 25480 | 34392 |
| Final build | 8394, 8539, 8618 | 8539 | 9714 |

That is 2.98x on service time and 3.54x on whole-process time for the pass
as a whole.

## A crash found by repeating the suite

Running the complete Harness suite three more times on the final build
crashed once, inside the allocator, in `input_modes_spec`. macOS crash
reports with the same signature exist for an intermediate build of this pass
and for a binary built on 10 October, the day before it started. A sanitizer
build of the runtime reported a heap use-after-free on that spec file in
every run: a resumed fiber's frames borrowed its saved function name, which
the next capture from a deeper function freed. The fix (the name is taken
from the function prototype, or from a table of names that are never freed)
leaves the sanitizer with nothing to report on the spec, and a short
reproduction is in the VM scheduler suite. The rows under Qualification are
from the runtime with the fix; the benchmark captures were taken just
before it, and the change is confined to fiber resume. Nine further complete
Harness runs on the fixed build (the qualification run and two soaks of
three and five) all passed with no crash report. The complete Harness suite was also
run once under the sanitizer build of the fixed runtime: no sanitizer
report in 200 examples; three examples failed there on latency bounds the
slower build cannot meet. The Cordis suite, the benchmark specs, the
differential programs, the scheduler and loop probes and forty turns of the
service probe also ran under that build with no sanitizer report. The broad
test suite itself cannot be used this way: built with the sanitizer it
overflows the stack in nested dispatch loops (its frames grow several-fold)
after 215 cases and no sanitizer report, so the sanitizer evidence is the
lifetime and VM suites plus the runs of the runtime binary listed here.

## Build provenance

```sh
nim c --nimcache:tmp/perf2/cache-baseline --hints:off -o:tmp/perf2/gene-baseline src/gene.nim   # at 1e3f539, before any edit
nim c --nimcache:<scratch>/ncfix --hints:off --warnings:off -o:tmp/perf2/gene-loop4 src/gene.nim   # clean export of 2fc14a5 plus nested-loop scope reuse
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
| Broad compiler/runtime/integration suite | 1689 passed |
| Executable language specs (46 new) | 892 passed |
| VM, ORC | 403 passed |
| VM, AtomicArc | 403 passed |
| Reference-count/lifetime suite (3 new) | 90 passed |
| Harness, complete suite from a clean export | 200 passed |
| AddressSanitizer: lifetime suite | 90 passed, 0 reports |
| AddressSanitizer: VM suites except env/eval | 391 passed, 0 reports |
| Cordis | 21 passed |
| Benchmark tooling | 15 passed |
| wasm ABI cases, scratch build | 46 passed |

Every row is from the final runtime (slice rule, `==`/`!=` lowered, cheaper
walks, in-place reads, in-place counting of published objects, nested-loop
scope reuse, the fiber-resume fix, worker-only publication). The binary and
the suites were built from clean exports of `084b888` with the changed
files laid over them. One VM test that pinned the
old rule (any nested `for` makes the outer body allocate) was updated to the
new one; the broad, VM and sanitizer VM rows are from the rerun with it. On the build before the walk changes one file-watch spec (`recursive watch discovers files in newly
created directories`) failed once while five suites compiled in parallel and
passed six of six alone and in a solo rerun; it depends on how the OS
batches file events. It has failed that way in three parallel phases in all
and passed every time alone, including the solo run recorded here.

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

Eleven more cover nested loops: break, continue and return from an inner
loop, bindings made before and after it, closures made inside it, empty
inner loops, and loops reached through calls and recursion.

During development the same programs, plus a multi-module import case and
thirteen `gene eval` sources, were run on the baseline and candidate binaries
after every batch and compared byte for byte. They are kept in
`differential/` with the runner as it was used (its paths point at the
scratch binaries).

The wasm target was compiled to a scratch directory and passed
`tests/test_wasm.mjs` through `GENE_WASM_MODULE`. Built the same way, the
wasm payload is 7,850,848 bytes at `1e3f539` and 7,960,874 bytes at the
branch head, 110 KB (1.4%) more; that difference includes another session's
commits on the same branch as well as this pass. The tracked `web/gene.js`
and `web/gene.wasm` were not regenerated.

### Harness

The complete Harness suite passes with the final runtime: 200 passed,
0 failed in 353 seconds, started on a loaded machine
(`verification/harness-final.log.gz`; 347 seconds on the build before; 527 seconds
before the walk changes, 407 before the in-place reads, and 329 on the
build before the counting change, on a quieter machine), run
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
