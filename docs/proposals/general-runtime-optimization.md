# General-purpose runtime optimization

Work branch: `perf/general-workloads`, based on runtime revision `f9d731c`.
The runtime implementation and regression tests are committed as `349dab2`.

The objective is to reduce ordinary application overhead without changing Gene
syntax, evaluation rules, ownership rules, or execution-policy enforcement.
The paired Gene/Python workloads live in `benchmarks/general/`; the real
Harness service probe exercises admission, model-free turns, transcript
snapshots, patch application, and durable completion.

## Implementation

- Simple `for` bindings avoid allocating a temporary pattern-match table.
  Destructuring still uses the complete matcher.
- An iteration can reuse its scope storage only when the compiler's existing
  non-capture analysis allows it and a runtime check positively proves unique
  ownership. Captures and native retained scopes prevent reuse. Unsupported
  refcount layouts and AtomicArc use fresh scopes. Bindings and annotations
  are cleared before reuse; stream, error, cancellation, and loop-exit handling
  keep their existing paths.
- Name lookup and selected namespace accesses borrow scope references during
  read-only walks. `nsScope` returns an owning reference; the explicitly named
  `borrowedNsScope` accessor requires its namespace owner to remain alive.
  Regression coverage includes proc-local retention after namespace release
  and heap-valued aliased lookup output.
- Immediate scalar assignments avoid constructing an error label for an
  authority/construction check that cannot reject an immediate value. Heap
  values retain the complete checks. Binding contracts remain enforced.
- Borrowed-authority and tail-call capture checks inspect container contents
  without copying their backing storage or property names. Small visited sets
  stay inline and larger graphs use a hash set. Cycles still terminate, and
  the same graph edges and tail-call eligibility rules are checked. Regressions
  include a captured mutable binding beyond a 40-container cycle and closures
  stored in node heads.

The internal executable-GIR format advances from 27 to 28 to carry the loop
reuse hint. This invalidates old compiled artifacts; it does not change source
syntax or language behavior. Super-specialized chunk copies preserve the hint.

## Review follow-up (2026-10-11)

Findings 1, 2, and 4 are addressed:

- Restored the owning `nsScope` API and limited `borrowedNsScope` to explicit
  read-only accesses whose namespace remains rooted. The previous claim that
  a proc-local binding automatically retained a `lent Scope` was incorrect.
- Scope uniqueness now requires the successful runtime refcount-layout probe,
  as well as a supported memory manager. An unrecognized layout disables reuse.
- New proc-local regressions release the namespace before reading a heap value
  through its retained scope, and exercise heap-valued aliased lookup output.
  A non-retaining native observer proves actual iteration reuse; a test-only
  failed layout probe proves the fresh-scope fallback. The existing native
  retention regression verifies that retained iteration bindings stay distinct.

`nimble test` and `nimble verify` enable `geneScopeReuseTests` for the broad
suite, so the failed-probe regression is part of normal verification. The hook
is absent from production builds. Direct VM testing can use:

```sh
GENE_USER_PACKAGES="$PWD/tmp/review-packages" nim c -r \
  -d:geneScopeReuseTests --path:src --nimcache:tmp/review-vm-cache \
  -o:tmp/review-vm tests/test_vm.nim
```

Initial follow-up verification: 398 VM tests pass under ORC debug and AtomicArc;
87 RC/lifetime tests pass. AddressSanitizer passes the four new ownership/reuse
tests plus the existing native-retention and loop-binding/exit tests (six
selected cases, with leak detection disabled). Nim `--expandArc` confirms
that the retained proc-local scope now has an owning reference and destructor.
Local build and test logs are in `tmp/bench-review-fixes/`.

Finding 3 was confirmed and fixed in a subsequent change. Fresh, pooled, and
reused scopes share parent-context initialization; idle pool entries release
old module tables and clear their generation IDs. Regressions verify both
acquisition paths, transitions to nil/zero, and correct errors for unresolved
references. The corrected runtime passes 402 VM tests on ORC and AtomicArc,
115 module/sandbox tests, 87 lifetime tests, and ten targeted AddressSanitizer
cases. See [the reset investigation](scope-pool-reset-investigation.md).
The archived benchmark timings below precede these follow-ups; performance
has not been remeasured for these changes.

## Second pass (2026-10-11)

Baseline for this pass: `1e3f539`, the tree after the review follow-ups above.
Evidence: [2026-10-11 results](../../benchmarks/baselines/2026-10-11-general-runtime/README.md).

The first pass removed allocation from scope setup. Profiles of that runtime
showed the remaining time was not in any one operation but in costs repeated
on every instruction: thread-local loads, reference counts on cyclic types,
string hashing for names the compiler already knows, and generic paths taken
for the most common operand shapes. Each item below removes one of those
without changing what a program can observe.

### Reference counting

- **Retain and release settle the common case without a thread-local load.**
  Nim loads the thread's error flag on entry to any proc with a checked
  operation or a call it must assume can raise, and on macOS that load is a
  function call. `rcRetain`/`rcRelease` are now short procs with unchecked
  count arithmetic that handle an unshared object staying alive, and reach the
  full bodies through an `importc` alias (which Nim treats as non-raising).
  The full bodies are unchanged and repeat every test.
- **Hot paths borrow `Scope` and `Application` instead of owning them.**
  Each owned copy of a reference to a cyclic type is a count round trip plus
  an ORC cycle-candidate registration. Outer-slot loads and stores, the
  per-iteration loop entry, the strict-binding check before every store, and
  the dispatch-epoch read now use cursors or a cast view of a reference the
  current scope already holds. `inheritScopeContext` stores a field only when
  it changes.
- A sort moves its entries between buffers instead of copying them, and
  `withoutVoidEntries`, map iteration and JSON encoding no longer copy each
  key's text.

### Names and keys

- **A `Str` remembers its interned key id.** Using a string as a map or
  property key took a global lock and hashed the text every time. A `Str` is
  immutable, so the id is cached on the object after the first use. `Map/get`,
  `Map/put`, `has_key?` and path lookup use ids and no longer copy the key.
- **Empty tables are not probed.** `Table.withValue` and `HashSet.contains`
  hash the key before noticing the table is empty; name lookup and namespace
  export checks now test the length first.
- **`/` and `//` join the compiler-known operators**, under the same rule
  as `+ - * < > <= >=`: only where the name is not lexically bound, imported,
  or compiled for dynamic lookup. Their fast path covers two small Ints (and
  declines a zero divisor); every other operand pair calls the same native
  function as before. The static error analysis models them as that call,
  not as error-free arithmetic. GIR format advances to 29.
- **`==` and `!=` are lowered the same way**, after a detour. Their fast
  path compares two small Ints by their bits; every other operand pair calls
  the native `==`/`!=`. The first build that lowered them made one Harness
  spec hang, so they were withdrawn until the cause was known. The cause was
  not equality at all: see "Slice boundaries" below.
- **By-name load cache.** A name the compiler cannot bind lexically (an
  imported function, a type, the root `gene` before every `$ns/fn`) is found
  by walking the scope chain. The activation scopes are still inspected on
  every load; what the walk finds at the module root or its parent is
  remembered per site.
- **Namespace member cache.** `$str/split` and `some_ns/member` resolve a
  constant path through namespaces; the selector-apply site remembers the
  result for that namespace object. Which namespace `gene` denotes is still
  resolved through the scope chain every time, so a module under a restricted
  root keeps reaching its own standard library.

Both caches are validated by two stamps on `Scope`, `namesGen` and `slotsGen`
(see `types.nim`). **Every change to a scope's `vars`, `wildcardFallbacks`,
`exportExcludedNames`, slot names or private slots must call `touchNames`,
and every slot write in a mirrored scope must call `touchSlots`.** A missed
call is a stale read of a rebound name. Stamps come from one process-wide
counter, so a scope allocated at a recycled address cannot match a remembered
stamp. The two are separate so that a top-level loop writing module variables
does not invalidate what is remembered about names the module does not bind.
The caches share the dispatch cache's side storage and its gate: they are off
in the AtomicArc worker build.

### Opcodes

- A one-key path read on a Map (`row/amount`) and a one-segment dynamic path
  on a List or Map (`xs/%i`) are a direct table or index read; the selector
  node for the dynamic form is never built. The skipped instruction is still
  charged to instruction and evaluation budgets.
- An unqualified send whose site keeps seeing one receiver type — built-in or
  declared — is answered from the dispatch cache without taking a reference
  to the type.
- Loop iteration reuse keeps the complete scope reset the review asked for,
  but tests each container before clearing it, keeps the slot-name list when
  it is already the body's, and leaves the reused scope in its register.
- A `match` clause's binding table is allocated on first insert, so a literal
  clause or a failed clause allocates nothing.
- Int multiplication uses the C compiler's overflow-checked multiply instead
  of a division; small-Int add, subtract and compare avoid checked arithmetic
  that cannot overflow.

### JSON

`json/parse` takes an unescaped string in one copy, resolves repeated object
keys through a small per-parse cache, and parses plain integers of up to 18
digits without a temporary string. `json/stringify` appends unescaped runs
rather than single characters. Error messages and offsets are unchanged.

### Results

Six measured processes per executable, rotating order, 5,000 items, 300 ms
calibration:

| Workload | Before ms/batch | After ms/batch | Speedup | After / Python |
| --- | ---: | ---: | ---: | ---: |
| Integer loop | 2.707 | 0.872 | 3.10x | 4.81 |
| Closure dispatch | 6.992 | 2.781 | 2.51x | 7.02 |
| Filter/group/sort records | 10.078 | 4.086 | 2.47x | 4.63 |
| Text indexing | 26.750 | 14.469 | 1.85x | 8.71 |
| JSON round trip | 5.867 | 2.543 | 2.31x | 0.93 |
| Event replay | 11.484 | 4.402 | 2.61x | 6.99 |

This capture is of the final runtime, with everything described below.
While the `==` lowering was withdrawn event replay read 2.29x; the nested
loop change moved text indexing from about 1.81x to 1.85x; nothing else
moved beyond run-to-run variation after the first part of the pass.

Verification for this pass, on the final runtime: 1,688 broad-suite cases,
892 language specs (46 new: 44 pinning what a shortcut could change, 2
pinning the slice rule), 402 VM cases under both ORC and AtomicArc, 89
lifetime cases, and the complete Harness suite (200 cases) run from a clean
export. AddressSanitizer (lifetime suite and 390 VM cases, no reports),
Cordis, benchmark tooling and wasm ABI cases also pass on it. The evidence
README records the regression, how it was traced, and the artefacts.

### Spawn publication

The kernel work did not move the 100-turn Harness service workload (26.39 s
against 26.41 s). Its profile put 46% of main-thread samples in
`publishSpawnCapture`: every `spawn` re-walked the scope chain and all the
code reachable from it, with fresh visited sets. Code does not change between
spawns and marking a value shared is permanent, so `publishSpawnChunk` now
remembers a chunk once its walk has covered it and found nothing below it
that can change. Chunks that declare types, enums, protocols, impls, macros,
FFI, web modules or imports are never remembered — their walk reaches scopes
or runtime state — and neither is a chunk with an unremembered chunk beneath
it. Scopes are still walked on every spawn. A managed-value publication
(`completePublication`) neither uses nor sets the mark.

One consequence to know: a value pushed at run time into a *quoted literal*
container is no longer re-marked through the constant pool on later spawns;
it is still marked when any scope reaches it.

Service time in one rotating capture: 29.73 s baseline, 27.89 s with the
kernel work only, 18.71 s with remembered publication (1.59x). The Nim
suites including AtomicArc and atomic generation retirement, the
differential programs and the full Harness suite pass with it. GIR format
advances to 30.

### Caller-env escape check

Every map put, list push and cell set of a heap value calls
`rejectCallerEnvEscape`, which walks the whole value graph looking for a
borrowed CallerEnv; storing a large transcript walks all of it. `newCallerEnv`
is the only place such a value is made, so until it has run in the process
the walk is skipped. A program that calls any `fn!` gets no benefit. The
service profile had 10% of main-thread samples in this walk; a rerun of the
service benchmark on a busy machine gave a median 22.8 s with the shortcut
against 25.3 s without (samples 22.1/22.8/25.8 against 24.1/25.3/26.2), so
treat the size as roughly 10%, not as measured precisely.

### Tail-call capture check

After those two changes the service profile was led by the tail-call capture
check (`scopeValuesCaptureScope`, 25%): each tail call walked every argument's
value graph for anything holding the scope being replaced. When the frame's
scope is one the VM will recycle into the call-scope pool (`recycleScope`)
and no closure was found holding it (`closureHeld`), nothing can hold it —
pooling already depends on that — so the walk is skipped. Other frames walk
as before. Service median in one capture: 17.37 s without, 15.27 s with.

Measured directly against the starting tree in one quiet capture, the three
service changes together take the 100-turn workload from a median 25.24 s
to 14.94 s (1.69x), and whole-process time from 34.5 s to 18.2 s.

What remains at the top of the service profile is the per-spawn scope walk
(20% before this change) and weak-function escape (12%), both whole-graph
walks with a visited set over the same large values.

### Slice boundaries

Lowering `==` changes nothing a program can compute, but it replaces three
instructions and a call with one instruction. A root-lane fiber is paused
after 512 instructions, wherever that count happened to fall, so every pause
after the first lowered comparison moved.

One of them moved into Cordis's `request_transition`, between the two halves
of `(instance/runtime/executor/queue/.get .push request)`: the fiber had read
the executor's queue List and resolved `.push`, and was paused before making
the call. The executor then ran, took the List with
`(executor/queue .swap (fresh_list))`, and went back to waiting. The resumed
fiber pushed its request onto the List the executor had already taken, the
wake-up found an empty queue, and the fiber that later joined that
transition waited forever. The Harness turn that had published a plugin hung
in `await_transition_task`.

How this was established, since no added trace survived it (any statement
added near the site moved the pause again and the hang vanished):

1. Source bisection without rebuilding. A lexical binding named `==` turns
   the lowering off for one file, and a renamed alias turns it off for one
   call. The hang needed exactly two of the 200 equality sites in
   `cordis/src/runtime.gene` lowered together, both executed in the fiber's
   last slice before the push.
2. A VM built from the hanging commit with three additions that leave the
   bytecode alone: a dump of every fiber's Gene stack once the scheduler has
   idled for 30 s, a log of every cancellation injected at a resume, and a
   log of every budget pause. The dump showed the turn fiber parked on the
   ticket's `ready` channel and the executor parked on its wake channel. The
   cancellation log ruled cancellation out (all 231 hit deadline timers or
   tasks that had not started). The pause log showed that fiber's last pause
   at `runtime.gene:1043`, instruction 92: after `opResolveMessage`, before
   the argument load.
3. A stand-alone probe. Three producers read a queue List, make eight more
   built-in sends and push, while a consumer swaps the List; 11 of 400
   preemption phases lose a push. The same count on the tree this pass
   started from, so the hazard predates every change here.

The change log entry that introduced the short slices says scheduling
remains cooperative. It was not, for exactly this kind of code: nothing in
`(queue/.get .push request)` suspends, and it could still be interleaved.

The fix is in the scheduler, not in Cordis. A spent slice no longer ends
between any two instructions. The fiber runs on to the next point where work
is about to repeat — a function entry, a `for` iteration, a backward loop
jump or `continue` — and pauses there (`sliceMayEndHere` in `vm.nim`). Every
unbounded computation passes such a point, so a CPU-bound fiber still yields
after about 512 instructions; a slice is now a minimum rather than an exact
length. Straight-line code is never split, and because a requested
cancellation is injected when a paused fiber resumes, cancellation cannot
land inside straight-line code either. Code that calls a Gene function or
loops between a read and its update can still be interleaved there, as
before.

With that rule the probe loses nothing, the spec that hung passes with
`==`/`!=` lowered, and two specs pin the rule: straight-line read-then-update
code is not split, and every loop and recursion form still yields a spent
slice to a peer.

### Value-graph walks

With the slice rule in, the service profile was three walks over the same
large values: spawn publication (26% of samples), the weak-function escape
scan behind every store and return (20%), and the tail-call capture check
(18%). About 18% of all samples were hash-set bookkeeping inside them. None
of the walks could be skipped outright; each got cheaper.

- **A reason nobody read.** When a tail-marked call cannot reuse its frame
  the VM works out why, which includes the capture walk over every bound
  value, and hands the answer to the tail-call statistics and the
  `--report_tail_fallbacks` report. Both are off by default. The reason is
  now computed only when one of them is on.
- **A visited set that is emptied by one increment.** The escape scan and
  the capture walk keep the first sixteen containers inline and used to put
  the rest in a fresh `HashSet`, growing and rehashing it on every store of
  a large value. `StampedSet` (`types.nim`) is an open-addressing table whose
  slots carry a stamp; a new walk bumps the stamp and reuses the table. Each
  thread keeps one for the escape scan and one for the capture walk. Both
  walks only read, so nothing can start a second one inside them; a flag
  still sends a nested walk to its own `HashSet`. The escape walk proper,
  which mutates and can release values, keeps a private set as before.
- **Leaves are not remembered during publication.** Publication inserted
  every value into two hash sets, immediates included. An immediate has
  nothing to publish and is skipped. A Str, a wide Int and a native function
  have no children and marking them shared is idempotent, so they are marked
  and not entered in either set. The two sets are `StampedSet`s now, and the
  thread reuses one pair across spawns instead of rebuilding it for the
  whole reachable graph each time.
- **Containers are read in place.** Publication and shared-marking iterated
  by value: `for item in list` copied and counted every item, and a Map's or
  Node's `pairs` copied every key string as well. They index the storage
  directly now, as the capture walk already did; nothing either walk reaches
  adds to or removes from a List, Map or Node.
- **Spilled entries stay spilled.** A walk past its sixteen inline entries
  kept comparing each new container against all sixteen before asking the
  set. The inline entries now move into the set with the first one that does
  not fit. The capture walk also returns at once for an immediate.

**Counting published objects.** The count fast paths from the first part of
this pass stopped at the shared mark: a published object counts atomically,
so it went to the full body. A program that spawns publishes most of its
data, so in the Harness nearly every count took the call. A published
object's count is now raised with the same atomic add in place, and lowered
in place by a compare-and-exchange that only succeeds while the count stays
above one; reaching zero, and every object with release-time bookkeeping,
still goes to the full body. A probe that publishes 2,000 rows and then
reads them in a loop runs in 206-215 ms instead of 268-273 ms (four
alternating runs, best of seven rounds each). Two lifetime tests publish
data and plain nodes, count them several hundred times and require that
nothing outlives the program.

Service median, three samples per build in one capture: 14.87 s before
these changes, 13.82 s with the first two, 12.29 s with the leaf rule. The
final capture, with the reused publication sets as well, reads 15.50 s
before and 11.75 s after (1.32x), and 26.68 s on the tree this pass started
from: 2.27x on service time overall, 2.56x on whole-process time. Reading
containers in place and spilling the inline entries then take a separate
quiet capture from 11.34 s to 9.69 s (1.17x). A final capture of the
starting tree against the end of the pass reads 31.36 s and 11.76 s: 2.67x
on service time, 3.08x on whole-process time. The complete Harness suite
runs in 329 s; it took 527 s before these changes. Five specs put more than sixteen
containers in one graph for each walk (a function forty containers deep in
a stored value, a stored ring with a shared part, a tail call passing a
large value that holds a closure over the caller, repeated spawns over a
captured List, and a large value stored twice).

The service's cost per turn also grows with the session. On the final
runtime the same probe takes 62 ms per turn over 25 turns, 71 ms over 50,
78 ms over 75, 86 ms over 100 and 93 ms over 120: about a third of a
millisecond more per turn for every turn already taken, because each walk
covers a record history that keeps growing. The 100-turn figure used
throughout is one point on that line.

**Publishing only what can leave the lane.** Publication exists so that a
fiber can run on a worker thread under atomic counting. An actor's handler
fiber is published only when it is worker-safe (`actorFiber`); a `spawn`
published its captured graph every time, including for a task that cannot
leave its lane and shares its scope with code on the same thread. `spawn`
now follows the actor rule. For a task that stays on its lane this removes
the walk altogether, and its values are no longer marked shared, so the
runtime can again re-weaken and reclaim cycles through them (existing issue
4 below). Five samples per build in one capture on a moderately loaded
machine: 11.83 s before and 10.94 s after on service time (about 8%), 14.24 s
and 12.19 s whole-process; the complete Harness suite runs in 285 s instead
of about 345 s. Every suite passes unchanged, including the VM suite under
AtomicArc, where worker-safe tasks are still published; no test relied on a
lane-bound task marking its captures. What this does change is which values
carry the shared mark, so it is called out in the change log. A direct capture
of the starting tree against the final build then reads 35.42 s and 11.97 s
(2.96x on service time, 3.64x whole-process), on a machine slower than in
the quiet captures.

What these walks still cost is the walking itself: publication is a third
of the service profile, the escape scan about an eighth. Each re-reads a
graph that has not changed since the last store or spawn, and avoiding that
needs a record of what changed, which no container keeps today.

### Nested loops

A `for` body reuses its iteration scope from one item to the next when the
compiler proves nothing made in the body can hold that scope and the VM
finds, at run time, that nothing else owns it. The compile-time half used
to reject any body containing another `for`, so the outer loop of a nested
pair allocated a fresh scope per item. A body now passes when its inner
loops pass the same test; the run-time ownership check is unchanged. A
kernel of 200 rows of three items runs in 200-214 ms instead of 230-239 ms,
and text indexing, whose inner loop walks the words of each line, is about
6% faster (15.63 ms to 14.69 ms in one before/after capture). Eleven specs
cover break, continue and return from an inner loop, bindings made before
and after it, closures made inside it, empty inner loops, and loops reached
through calls and recursion.

Two related changes were measured and dropped. Taking a loop's first
iteration scope from the call-scope pool and returning it when the loop
ends, and pooling the call scope of a function whose loops pass the test,
each worked and each left a function that runs one short loop at the same
speed: in that profile the per-iteration reset and item binding cost far
more than the two allocations.

### A use-after-free in fiber resume

Repeating the complete Harness suite on the final build crashed once in
three runs, in the allocator, under `input_modes_spec`. Crash reports with
the same signature exist for earlier builds of this pass and for a binary
built the day before it started, so the fault was already there.

A sanitizer build of the runtime, run on that one spec file, reported a heap
use-after-free in every run, at `captureContinuation`. A frame's function
name is a borrowed string, on the assumption that the text belongs to a
function prototype. On resume the dispatch loop took the name from the
fiber's own saved copy instead, and frames pushed afterwards borrowed that.
The next capture from a function with a longer name replaced the saved copy
and freed the old text; returning to the outer frame and suspending again
read it. A resumed name is now taken from the prototype when that is where
it came from, and otherwise from a per-thread table of names that are never
freed (`stableResumedFnName`). The sanitizer build reports nothing on the
spec with the change, and a twelve-line reproduction (a task that sleeps,
calls a function with a longer name that sleeps, and sleeps again) is in the
VM scheduler suite, which the sanitizer run covers.

### What is still slow

- Each `for` iteration is a frame with its own scope. The reset is now cheap
  but not free: in a function that runs one three-item loop, reusing the
  scope and binding the item are about a quarter of the time. A compile-time
  "simple body" class, like `simpleCall` for functions, would allow a
  slots-only reset. Across the suite this path (`reuseForScope`,
  `resetCallScope`, `bindForItem`, `storeSlot`) is 20-25% of records, event
  replay and text indexing. The existing scope-free whitelist is too narrow
  to reuse (it admits no calls), and a wider one cannot prove much: a native
  called from the body receives the scope and may define into it, which is
  why every iteration resets about forty fields that are almost always
  already clear. The change that would remove the cost is structural: move
  the rarely used fields of `Scope` behind one optional extension object, so
  that a reset is one pointer test.
- A match branch and the first iteration of every loop allocate a fresh
  `Scope` (about sixty fields). Pooling them needs the same ownership proof
  loop reuse uses.
- Passing a scope-bound closure as an argument clones it (weak-capture
  promotion); a call through a local closure costs about five times a direct
  recursive call.
- Constructing a typed instance and sending to it remain several times
  slower than the equivalent built-in operations.
- Nim's goto-exceptions put an error-flag test after most calls. Helpers the
  C compiler does not inline pay a thread-local load each; the dispatch loop
  still calls several of them out of line.

## Measurement and qualification

Portable release builds retain bounds and overflow checks. Measurements must
alternate independently built baseline/current executables, exclude warmup and
calibration, verify identical results, and preserve raw samples and build
identities. Timing runs must not overlap this task's compilation or validation.
The host is a shared macOS arm64 workstation, so sample spread is part of the
evidence. Python is a workload reference, not a claim that either language has
one universal speed ratio.

The first two passes improved the general workloads but left Harness service
time essentially unchanged. A subsequent service profile accounted for 10,584
main-thread samples: about 50% belonged to scope-retention/escape work and 31%
to publication. That evidence motivated borrowing during the tail-call capture
walk. Idle worker-thread samples are excluded from those percentages.

The Harness probe now uses the supported scripted profile instead of the
retired `open_session_service ^provider` argument. Workload version 2 checks
completed receipts and exact output-file contents. Its absolute times must not
be compared with the October 4 callback-based capture. Runtime comparisons use
the same version-2 source and fresh workspaces for both binaries.

The [final evidence](../../benchmarks/baselines/2026-10-10-general-runtime/README.md)
records 1.20–1.74x improvements across the general workloads and a 1.39x
Harness service improvement (53.1 to 38.1 seconds per 100 turns). An independent
fresh-cache rebuild confirms 1.19–1.71x improvements on the general workloads.
The evidence includes raw samples, hashes, source snapshots, profiles, and
qualification logs. Initial noisy captures are not the headline estimate.

The final source currently passes 1,678 broad-suite cases, 846 language specs,
395 VM cases under both ORC and AtomicArc, 87 lifetime cases, and 21 Cordis
cases. A targeted AddressSanitizer run using the system allocator passes 383
VM cases. The normal builds cover all 395, including the allocation-budget
fixture: that fixture depends on Nim's occupied-memory counter, which is
unavailable with `-d:useMalloc`. An initial unfiltered sanitizer attempt was
stopped at that fixture and is retained as an incomplete run, not counted as
passing. Sanitizer leak detection is disabled; the separate RC suite checks
managed retention.

The final-build Harness run passed 178 cases and failed its one-shot activation
expiry fixture. Its one-second global startup budget could expire required
documentation/command plugins; startup diagnostics reproduced the timeouts on
both baseline and optimized runtimes. The fixture now verifies readiness with
a five-second activation budget and waits 6.5 seconds before scheduling the
trigger, retaining the original expiry invariant and 20-second completion
bound. Its three-case file passes on the optimized runtime, and the revised
expiry case passes on the baseline. All 179 cases are covered across the full
and focused runs; the original full run is retained as 178/1, not relabeled as
an entirely green run. No runtime budget or language semantics were changed.

## Existing issues exposed during investigation

These observations reproduce on the unchanged baseline and remain separate
from this optimization:

1. A function stored in a node head through a local weak binding can lose its
   captured value. This returns `nil` on both the baseline and the second
   optimized build, although the function should retain `x`:

   ```gene
   (var saved nil)
   (fn retain [value] (set saved value) 0)
   (fn outer [x]
     (let inner (fn [] x))
     (set x (+ x 1))
     (retain ($node/rebuild (quote (held)) ^head inner)))
   (outer 11)
   (($head saved))
   ```

   A direct function literal in the node head works. This is a lifetime defect
   to investigate, not a supported workaround or a changed semantic contract.

2. A source tail call after some `repeat` loops can fall back with
   `operand_region`. A cycle-construction fixture reproduced this on the
   baseline with `--report_tail_fallbacks`. The capture-check regression builds
   its graph outside the tested function so that it actually exercises the
   captured-scope guard. Investigate the leftover operand separately.

3. Existing verification fixtures contained malformed `^^^override`, or used
   `^^!override` where they intended `^^override false`. Those fixtures were
   repaired to exercise their original override checks. Three printer/error
   expectations and one LSP column expectation were aligned with independently
   verified baseline behavior. These test-only repairs are a separate commit;
   they did not alter the reader or message-resolution rules.

4. A program-level typed instance that a spawn publishes is not reclaimed.
   With the lifetime suite's `leakedManaged` helper, on the tree before the
   counting change:

   ```gene
   (type Box ^props {^value Any})
   (var boxes []) (var i 0)
   (while (< i 20) (boxes .push (Box ^value [i])) (set i (+ i 1)))
   (var task (spawn ^lane root ($size boxes))) (await task)
   ```

   followed by twenty passes that read each box, leaves 41 managed objects
   behind. Published Maps, Lists, Strs and untyped nodes are all reclaimed.
   The cause is the shared mark, not a held reference: an instance, its type
   and the scope that declares the type form a cycle, the runtime breaks such
   cycles by re-weakening on release, and it does not do that to a value
   marked shared. This is fixed for the common case by the last change of
   the pass (see "Publishing only what can leave the lane"): a task that
   stays on its lane no longer marks what it captures, and a lifetime test
   holds this program at zero. A worker-safe task's captures are still
   marked and would still be kept.

   A separate observation from the same helper, which needs no spawn: twenty
   closures made in a top-level `while` loop and pushed onto a top-level List
   leave 21 objects behind when the program scope is dropped, called or not.
   That is a cycle through the program's own root scope at teardown and was
   not looked into further.

5. The Harness performance probe cannot run much past 120 turns.
   `examples/gene-harness/probes/performance.gene <workspace> 140` (and 160,
   180, 200) stops with `SessionError: session ... still has a round` from
   `src/runtime/sessions.gene`, on the starting tree and on every build of
   this pass alike; 120 turns complete. The probe joins the session's watcher
   and submits the next round, so something still holds a round for the
   session at that point. Not investigated.
