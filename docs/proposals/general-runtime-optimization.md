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
- **`==` and `!=` were lowered the same way and then withdrawn.** With them
  lowered, one Harness spec hung at service startup while every direct
  comparison of equality results still matched the old runtime; bisection
  isolated the lowering but not the mechanism. They remain ordinary calls
  (the native keeps its own small-Int shortcut). Scopeless-call eligibility
  of small `==` predicates was tested and ruled out as the cause. Anyone
  retrying this must run the Harness suite, not only the specs.
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
| Integer loop | 2.883 | 0.905 | 3.18x | 4.86 |
| Closure dispatch | 7.422 | 2.906 | 2.55x | 7.23 |
| Filter/group/sort records | 10.609 | 4.461 | 2.38x | 4.97 |
| Text indexing | 28.344 | 15.766 | 1.80x | 9.27 |
| JSON round trip | 6.234 | 2.691 | 2.32x | 0.95 |
| Event replay | 11.953 | 5.211 | 2.29x | 8.12 |

Verification for this pass, on the corrected runtime: 1,685 broad-suite
cases, 874 language specs (28 new, pinning what a shortcut could change), 402
VM cases under both ORC and AtomicArc, 87 lifetime cases, and the complete
Harness suite (179 cases) run from a clean export of the committed tree.
AddressSanitizer (lifetime suite and 390 VM cases, no reports), Cordis,
benchmark tooling and wasm ABI cases also pass on it, and an independent
fresh-cache rebuild repeats the speedups within about 3%. The evidence README
records the regression, how it was bisected, and what remains unexplained.

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

### What is still slow

- Each `for` iteration is a frame with its own scope. The reset is now cheap
  but not free; a compile-time "simple body" class, like `simpleCall` for
  functions, would allow a slots-only reset.
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
