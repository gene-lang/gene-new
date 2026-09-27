# AtomicArc generation retirement

**Status:** qualification infrastructure and a private-generation experiment are
implemented. Normal AtomicArc retirement remains disabled. This does not promote
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
pins Values marked published/shared and does not enumerate their mutable owning
edges. Their uncounted strong references and followed weak references keep
affected scopes alive. A published graph is retained even after the last named
outside owner drops; this deliberate limit must remain visible in reports.

Outside-held private Values and native roots are also live roots. Unknown code,
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
