# AtomicArc generation retirement

**Status:** AAR-0 and the conservative publication portion of AAR-1 are
implemented. Native borrow quiescence and shared reclamation remain open.
Selected SDK entry admission is also implemented in the qualification build;
it does not cover raw returned references or the complete native API.
The owner selected the [root-owned bounded C handle registry](native-foreign-handle-allocation.md)
to avoid the default allocator's foreign-thread lifetime hazard. C numeric
ID transfer is qualified separately; full AAR-1 and AAR-2 remain open.
Normal AtomicArc retirement remains disabled. This does not promote
VM-2 or threaded lifetime support. The existing language and sandbox APIs remain
unchanged.

## Scope and invariants

Extend the existing mixed manual-RC/Nim-ref trial deletion, starting with released
generation roots under the scheduler's module-mutation pause. Do not enable the
activation/returned-value collector merely because counts become readable.
Worker-private cycles, arbitrary continuations, and a collector for published
graphs are separate stages.

Nim 2.2.4's genuine AtomicArc header has one `int` RC word and a three-bit shift.
ORC has an additional `rootIdx` word and a four-bit shift. The adapter reads the
AtomicArc word with acquire ordering and verifies `1 -> 2 -> 1` using
`GC_ref`/`GC_unref`. It never writes or forces a reference count. Hybrid
`gcOrc`/`gcAtomicArc`, missing RC instrumentation, and a nonthreaded qualification
build are rejected. ARC debug/ID/leak-detector layouts remain unsupported.

Atomic reference loads do not provide a consistent graph snapshot. The owning
root lane must stop new worker admission and wait for every active Gene worker
Fiber to leave execution before counting or severing generation edges. Nested
pauses retain admission closure until the outermost pause ends. A worker or
foreign lane must receive an error rather than waiting for itself to quiesce.
Quiescence includes Fiber teardown, not just bytecode execution: the worker
drops its local reference, moves the scheduler's last reference to a retiring
slot, releases it outside the scheduler lock, and only then acknowledges
retirement. A separate retiring bit keeps the pause and progress oracle honest
without invoking native cleanup under the lock.
The retiring reference is explicitly owned and reset before acknowledgement.
Nim 2.2.4 lowered a direct nil assignment of the temporary as an overwrite;
the typed-Task string-lifetime regression detects a lost Fiber owner here.

This pause does **not** stop foreign C/Nim threads. The experiment permanently
pins Values marked published/shared and records Scope publication before handoff,
including lexical ancestors and known weak defining environments. It does not
enumerate published Scope tables or count published Value owning edges. If any
pending root is published, the entire batch is retained: hidden weak relationships
in a mutable table cannot be analyzed independently. A published graph is retained
even after the last named outside owner drops; this deliberate limit must remain
visible in reports. Publication recording is not a lock for application mutation.

Outside-held private Values are also live roots. SDK roots are conservatively
published in the experiment, including known compiled constants/default bodies;
`rootRelease` cannot revoke raw Values previously returned by `rootGet`.
Normal builds retain the existing SDK behavior. Unknown code,
error-evidence and opaque ownership remain conservative. The experiment assumes
unpublished candidates are confined to the owning lane; arbitrary unmarked
foreign Nim refs or concurrent SDK mutation are not qualified by this matrix.

## Implemented qualification stage (AAR-0)

`-d:geneAtomicGenerationRetirementProbe` is an explicit test-only opt-in. It
requires genuine `--mm:atomicArc --threads:on -d:geneRcStats`. The normal build
still reports generation retirement unavailable. The opt-in has these guards:

- A thread-local retirement/layout state, avoiding a process-global collector
  flag shared by independent lanes.
- A paused-root boundary around released-generation analysis. Direct unpaused
  calls return without reclamation.
- Published Value pinning, including weak defining-scope relationships.
- Activation prechecks stay false, and nongeneration passes remain disabled.
- Instrumented managed counters use atomic updates/reads in threaded builds;
  per-class snapshots still require quiescence to be coherent.
- The standard `threadcheck` includes a normal-build negative control.

`tests/test_atomic_generation_retirement.nim` uses the actual VM worker barrier
and existing sandbox transaction APIs. It covers synthetic namespace cycles,
scalar generations, private Types with direct methods, release/discard/failed
prepare, retained instances, private/native outside roots, active workers, nested
pauses, and a concurrently reading native thread. Canonical impl publication is
an explicitly **unqualified/retained** control, not a lifetime pass.

`tests/qualify_atomic_retirement.gene` builds distinct normal, opt-in and optional
ASAN binaries, records hashes/commands, bounds builds to 600 seconds and children
to 180 seconds, retains logs, and fails on timeout, truncated output or nonzero
status. The native ownership tests need Nim access to internal Scope/ref APIs;
orchestration is Gene.
Optional `--tsan` runs the active-worker and foreign-reader cases under
ThreadSanitizer. The initial run exposed allocator access after the old worker
inactive acknowledgement; acknowledging after teardown makes both cases pass.

## Remaining implementation stages

### AAR-1: publication provenance and native quiescence

#### Implemented conservative publication (AAR-1a)

The opt-in build adds an acquire/release Scope publication marker. The shared
Value walker records strong and weak Scope relationships for namespaces,
functions, Types/fields, Enums/variants, protocols/messages, cells, error
environments, callable views, and typed async/container handles. Ancestor marking
keeps an escaped nested environment's generation root pinned. Worker publication
also marks its Scope snapshots. Ordinary builds do not add this marker or enable
collection.

SDK root creation uses the VM publication walker before handoff, covering known
function code/constants, defaults, type expressions and Scope contents. Ingress
subscription creation records its dispatch Scope separately: a native handler
can have no lexical Scope. Neither releasing the SDK root nor physically retiring
the ingress subscription clears publication. Opaque continuations and custom
`FunctionCode` subclasses remain outside this qualified walk.

| Exposure | Current ownership/admission | Retirement treatment and remaining gate |
| --- | --- | --- |
| Worker snapshots and results | `publishSpawnCapture` / shared Value handoff; scheduler pause includes teardown. | Known Scope/code relationships pinned; no worker-local activation collection. |
| Canonical impl lookup | `markImplValuesShared` before publication; foreign lookup can retain entries. | Known defining Scopes pinned through Value edges; canonical generations remain unqualified. Impl/code inventory is not a native quiescence proof. |
| SDK `GeneRoot`, callbacks | `geneRoot` owns a Value; `rootGet` returns an independently retainable raw Value. Synchronous callbacks are owner-thread-only. | Root graph permanently published in the opt-in build. Concurrent get/release on one handle is not qualified. |
| C byte ingress | Foreign threads enter a locked, byte-only context through the single `GeneApi` layout; begin/end count in-flight callbacks. The subscription owns mediated handler/environment/Task/library IDs and a cleanup lease. | Close denies new admission; unregister plus zero in-flight/queued work permits physical retirement. The handler Scope is retained through managed tickets and can retire after release. No foreign Gene object access is allowed by this path. |
| Native module, buffer/type, environment and direct Nim Scope/Value refs | Existing APIs expose owning refs or raw fields; there is no universal borrow report. | Explicit known publication is pinned. Arbitrary unmarked transfers/mutation are unsupported by the experiment; production collection remains disabled. |

Qualification adds foreign Scope table growth/deletion during collection attempts,
foreign function-reference retain/drop transfers after SDK roots release, weak
environment and compiled-constant controls, mixed-batch retention, and late C
ingress with physical-retirement rejection. These test permanent retention;
they do not establish eventual reclamation or concurrent application table access.

#### Selected entry admission (AAR-1b, partial)

`retirement_native_gate.nim` adds a qualification-only process-wide gate for
SDK root create/get/release and native module create/value/Scope/define entry
calls. Normal builds have no gate or SDK contract change. Its process-wide domain
is deliberately conservative; unrelated applications can delay one another.

The owning VM root pauses workers first, then seals native admission and drains
owner-independent outer entries. SDK publication, module mutation and release
can invoke cleanup requiring root-lane progress, so active calls in those classes
defer collection. A nested call upgrading an already draining entry wakes the
collector, reopens admission and defers its pass. An admitted entry may finish nested SDK calls
while the gate drains; denying that nesting would deadlock the collector. Late
foreign entries wait until the outermost collector seal exits. Nested seals keep
admission closed; generation analysis defers inside an enclosing native seal.
A competing collector defers, and a collector invoked from
inside a native entry defers rather than waiting for its own lease.

Generation analysis now also requires this drained native boundary. After all
count/edge analysis finishes and candidate Scope edges are detached, native
admission reopens before last-owner drops. This lets cleanup join a foreign SDK
callback without keeping that callback behind its own fence. The collector
reservation remains held through cleanup, preventing a competing collection.
Last-owner drops execute outside the gate mutex. `finally`
paths restore admission after a successful pass, conservative refusal or failure.
An owning-thread SDK entry during analysis itself is rejected in the experiment.
This phase distinction is internal to the qualification build.

Root/module entry leases end when the API call returns. Independently retained
raw Values and Scopes still require permanent publication pins; multiple SDK
entries can run concurrently, so the gate is neither a shared-container lock nor
permission for concurrent get/release of one handle. C byte ingress uses its own
physical context fence and is not drained by this graph gate. Other native APIs,
unmarked direct Nim refs, opaque cleanup/resurrection and arbitrary continuations
are not qualified. Do not replace pins or enable shared reclamation on this evidence.

Known code publication now follows object Value edges (including Type methods,
constructors and witnesses), borrowed nominal identities, declaration metadata,
rest/error annotations, error proof/return summaries, super identities, derived
chunks, nested constructors/inline impl operands, monomorphization arguments,
web forms and native layout field expressions. Synchronous native callback
preparation also publishes its dispatch Scope and target graph. Publication
requires live references and owner-confined/pre-handoff metadata; it is not a
snapshot of concurrently mutating code or containers.

#### Remaining full native quiescence

Inventory every path that can expose a candidate Scope or Value outside its
owning lane: worker snapshots, shared impl publication, C ingress/callbacks,
`GeneRoot`, native scope/environment handles, and public Nim SDK refs. Associate
publication with the affected generation/scopes, including weak/code edges.
Worker pause alone must never stand in for this inventory.

Implement a native admission/borrow lease or an equivalent mutation epoch that
prevents new access during collection and waits for active accesses to finish.
Existing native handles remain rooted until physical retirement. If an SDK ref
cannot participate in that protocol, retain the affected graph. Changing the
public SDK ownership/access contract requires owner review before implementation.

Acceptance: a foreign reader, a foreign retain/drop transfer between graph nodes,
and a callback arriving during collection either finish before analysis or pin
the graph. Race-sensitive tests must run under a supported thread sanitizer.
Reference counts read at different instants are not sufficient evidence.

The implementation contract for a future participating native borrow is:

1. Admission belongs to the same application/collector domain as its Scope graph.
   A lease owns its root and reports every access, including retain/drop transfers
   and cleanup. Admission and collector sealing use one synchronized state.
2. The root lane closes worker admission, seals native admission, and waits for
   previously admitted borrows to end. Re-entry by a lane holding a lease must
   fail/defer collection instead of waiting for itself. Nested collection keeps
   both gates sealed until the outermost exit.
3. A sealed gate rejects or defers new native access; the exact public behavior
   needs owner review. Foreign C byte ingress may continue because it never reads
   Gene graphs; its existing context fence governs context retirement separately.
4. Only after both domains quiesce may a participating graph be inspected. Raw
   `rootGet` results and direct Nim refs still pin their graph; wrapping just the
   API call does not fence the returned object's lifetime.
5. Detach collectible Scope edges while owners remain pinned. Once no further
   analysis can inspect them, reopen native admission before last-owner cleanup;
   callbacks may need other native entries to finish. Keep a collector reservation
   until cleanup ends, with no callbacks under publication/collector locks.
   Failure/refusal paths must also restore admission in `finally`.

The owner selected opaque managed handles on 2026-09-27. The entry-call portion
above and initial opaque SDK ownership/borrow adapters are implemented; this
full managed-borrow contract is still incomplete. Do not retrofit a lease lifetime onto
the existing SDK signatures or claim that ingress begin/end fences raw Gene
Values. That SDK choice has been reviewed; further public ownership/access
changes still need explicit design review. AAR-1 remains incomplete until full
integration and the borrow/collector race matrix are complete.
The bounded C registry prevents foreign growth of Nim table storage and
defers cleanup until its admitted borrows end. Direct Nim wrapper transfer
and other raw ownership paths remain outside that qualification; see the
[selected registry contract](native-foreign-handle-allocation.md).

[Native managed borrows](native-managed-borrows.md) records the owner-selected
opaque-handle contract, SDK-family inventory, legacy export policy and remaining
implementation/acceptance sequence. Its initial adapters do not qualify
canonical/shared reclamation or permit replacing existing raw publication pins.

### AAR-2: published generation graphs

Replace permanent publication pins only where AAR-1 establishes a consistent
snapshot and a complete edge model. Keep the existing outside-root subtraction,
weak-edge liveness, inconsistent-count rejection, and borrowed-handle exclusions.
Do not enumerate a mutable shared container without its synchronization policy.
Sever scopes while they stay pinned; run arbitrary callbacks/native cleanup
through their existing lifecycle, outside collector/publication locks.

Acceptance: canonical Type/protocol/impl, retained Type/function/instance,
container and error roots, native handles, and reader/retainer races. Repeated
1/100/1,000/10,000 batches must return all managed classes and pending generation
roots to baseline after controls drop. Ordinary AtomicArc and ASAN builds must
pass. Published controls in AAR-0 must become flat before enabling this class.

### AAR-3: activation and worker-local cycles

Design safe candidate handoff from worker activations to the owning collector.
The current process-global returned-cycle watches and root-only safepoints are
not a qualified worker collector. Preserve escaped closures and canceled-task
ensure cleanup, and account for scheduler/native holders before reclamation.
Use the thread-safe diagnostic counters at quiescent checkpoints when multiple
lanes allocate/free tracked Values; a flat unsynchronized snapshot is not an oracle.

Acceptance: mixed closure/Cell/List/Map/Node graphs, parked/running Tasks,
worker results and cancellation, plus kept-callable controls. Promote only the
classes with authoritative platform, lifetime and sanitizer evidence.

## Reproduction and promotion

```sh
nim c --threads:on --path:src --hints:off -o:tmp/gene-qualification src/gene.nim
tmp/gene-qualification run tests/qualify_atomic_retirement.gene --asan --tsan
```

Results are under `tmp/atomic-retirement-qualification/`. An AAR-0 pass is an
experiment for private roots, not authorization to turn on production AtomicArc
retirement. Linux and the SERVICE heartbeat investigation remain deferred.
