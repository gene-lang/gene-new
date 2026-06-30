# M:N Scheduler — Thread-Safety Spike & Staged Plan

Status: **decision doc** (spike result plus staged implementation notes). Date:
2026-06-28; updated 2026-06-30 for the default bounded worker lease.
Branch context: `scheduler` (cooperative single-worker scheduler, channel/task/
actor suspension, explicit `Task/cancel`, and error/cancel scope-exit child-task
cancellation with cleanup plus normal-exit child waiting done; actor scope
shutdown cancels pending asks and parked handlers; bounded worker-candidate OS
worker lane started).

Follow-up implementation note: scheduler run/wait/timeout queues have moved from
raw `threadvar` storage into per-`Application` scheduler state with a lock, task
state plus channel/actor interiors now have object-local locks, and Send
boundaries now mark value graphs as shared so threaded builds can switch
manual-RC objects to atomic retain/release after publication. Spawned fibers now
publish their captured scope/value graph as well, including task/channel/actor
interior payloads that are protected by their object locks. Worker-candidate
spawn bodies now run against sparse captured-scope snapshots once their runtime
captures satisfy `Send`. In `--mm:atomicArc --threads:on` builds,
root program execution and root scheduler pumping for `await`, structured-scope
cleanup, channel waits, actor mailbox waits/driving, and `sleep` now start a
bounded worker lease by default in `--mm:atomicArc --threads:on` builds.
`GENE_WORKERS=N` overrides the worker count, and `GENE_WORKERS=0` disables the
worker lane. That lane lets OS worker threads consume snapshot-isolated worker
candidates while unsafe shared-scope work remains on the cooperative root lane;
root waits also help drain worker candidates once cooperative-only work is
exhausted.
Worker candidates are leaf-like: bytecode/runtime eligibility rejects bodies and
reachable captured functions that contain nested `spawn`. A threaded `atomicArc`
smoke gate now covers value operations, VM behavior, worker-candidate execution
during root execution and root waits, cancellation/wait races at higher worker
counts, and RC leak accounting, including typed task/channel and actor ask paths.
This removes more runtime data-race classes and keeps ORC-object atomicity
regressions visible, but it is still not production M:N: work stealing, async
I/O, pinned lifecycle, and production semantics remain open. Idle worker threads
park on a condition-variable wakeup when no worker-candidate fiber or scheduler
timer is queued; timer waiters and `actor/ask` timeouts signal parked workers so
timeout progress is not tied only to root scheduler pumping. Worker-owned fibers
are tracked while active so root deadlock detection and cancellation do not miss
claimed work.

## Goal

Decide whether/how to move the cooperative scheduler (one worker, `threadvar`
state) to the design's M:N model (§13.1: "many Gene tasks run cooperatively across
a runtime worker pool"), and what it costs.

## TL;DR

- **Atomic refcounting is cheap (~2–4% worst case), not the blocker.** Measured below.
- **The real blocker is shared mutable state — scopes above all.** Unsafe spawned
  tasks can still share a mutable parent scope chain; worker-candidate tasks now
  avoid that by using captured-scope snapshots.
- **M:N fits the share-nothing actor/channel model and snapshot-isolated
  leaf-like worker-candidate spawns; it does NOT fit arbitrary `spawn` closures
  that share a parent scope or create nested unsafely shared tasks.**
- **Recommendation: keep worker execution bounded and restricted while hardening
  semantics.** The cooperative root lane remains the safety baseline for
  shared-scope tasks. The first OS worker lane now runs snapshot-isolated
  candidates by default in atomicArc threaded builds, with root-lane helping
  during waits; the remaining M:N work is lifecycle, broader load balancing, and
  async integration.

## Measurement: atomic-RC hot-path cost

Prototype: made every manual refcount atomic (`inc/dec` → `atomicInc/atomicDec` in
`rcRetain`/`rcRelease`), the worst case where *all* values pay the atomic tax. arm64
(Apple Silicon), `--mm:orc --threads:on`, steady-state (cold first run discarded),
3 runs each via `nimble perf`.

| benchmark | baseline ops/s | all-atomic ops/s | Δ |
|---|---|---|---|
| `vm.simple_call` | ~4.51M | ~4.32M | **−4.2%** |
| `vm.named_call` | ~1.63M | ~1.63M | ~0% |
| `value.node.construct_access` | ~4.06M | ~3.99M | −1.7% |
| `equality.structural_node` | ~11.5M | ~11.4M | −1% |
| `value.small_int.construct_access` | ~725M | ~725M | 0% (immediates, no RC) |

Notes:
- Worst case is ~2–4% on the hottest paths; uncontended arm64 atomics are cheap.
  x86 `LOCK`-prefixed ops may cost a bit more but are still modest uncontended.
- The intended design (per-object `shared` flag, atomic only for *published*
  values — see `TODO(vm-shared-rc)` in `types.nim`) keeps thread-local objects on
  the plain path, so steady-state cost for the common case is **below** this bound
  (just a flag load + predictable branch).
- Conclusion: **refcount atomicity does not block M:N.**

## The real blockers (ranked)

1. **Shared mutable scopes.** Legacy cooperative `opSpawn` can still use a live
   parent `Scope` when the body mutates outer bindings or captures non-`Send`
   values. Two such tasks on different threads racing on a shared scope would be
   a data race. Worker-candidate spawns now avoid that live parent by running
   against sparse snapshots of the captured parent scope. The design's own
   example shares scope:
   `(scope (var a (spawn (compute-a))) (var b (spawn (compute-b))) (+ (await a) (await b)))`.
   → The implementation direction is now explicit: sent/parallel work is
   **scope-isolated** (share-nothing, like actors/channels). The actor and
   channel models already isolate state via Sendable messages and are the natural
   unit of parallelism; arbitrary `spawn`-over-shared-scope is not.

2. **ORC `OBJECT_TAG` objects.** Cells, channels, actors, mailboxes, Envs, types,
   etc. are ORC-managed via `GC_ref`/`GC_unref`, non-atomic under `--mm:orc`.
   Cross-thread sharing needs `--mm:atomicArc` or equivalent. The main mutable
   interiors used by the scheduler path now have locks and threaded smoke
   coverage, but the worker pool must run under that threaded memory-manager
   configuration.

3. **Scheduler structures need production orchestration.** The runnable/wait/
   timeout queues are now per-`Application` and lock-backed, and task/channel/
   actor interiors have local locks. The bounded worker lane consumes only
   snapshot-isolated candidates, root waits help drain those candidates once
   cooperative-only work is exhausted, idle workers use condition-variable
   wakeups rather than fixed polling, timer additions wake parked workers, and
   worker-owned fibers stay visible to root deadlock/cancellation checks while
   active. M:N still needs production lifecycle, work stealing, richer timer/I/O
   ownership, async I/O integration, and publication rules. `runStackPool`,
   `callScopePool`, and active scheduler context remain per-thread caches/context.

4. **Publishing / `Send` boundary.** Channel sends, actor messages/replies, and
   spawned fibers now mark reachable value graphs `shared` for threaded manual
   RC. Spawn bytecode marks leaf-like bodies that do not mutate outer bindings or
   contain nested `spawn` as worker candidates, and enqueue records that bit only
   when runtime captures are `Send` and reachable captured functions are also
   leaf-like. Eligible tasks get sparse captured-scope snapshots, including
   transitive captures of captured functions. The bounded worker lane consumes
   those eligible tasks while unsafe shared-scope tasks remain cooperative.
   Worker-owned fibers are tracked under the scheduler lock, and parking rechecks
   channel/task/actor/timer readiness so a wakeup that races with suspension does
   not disappear.

## Staged plan (if/when M:N is prioritized)

- **A. `vm-shared-rc`.** Per-object `shared` flag; `rcRetain`/`rcRelease` branch to
  atomic on shared. Publishing pass at Send boundaries and spawned-fiber capture
  boundaries. **Manual-RC publication has landed; true worker execution must run
  under atomicArc or equivalent for generic ORC object refs.**
- **B. Scope isolation semantics.** Parallel/sent work is share-nothing.
  Worker-candidate tasks already receive sparse captured-scope snapshots instead
  of a live shared parent (`no outer mutation`, no nested `spawn`, plus `Send`
  captures). The bounded worker lane consumes only those eligible fibers.
- **C. Thread-safe runtime objects.** `--mm:atomicArc`; locks (or lock-free) for
  channel buffers, actor mailboxes/state, and the shared run queue + wait lists.
  The queue/object-locking portion has started, Send-boundary and spawned-fiber
  manual-RC publication have landed, and `nimble threadcheck`/`nimble verify`
  exercise atomicArc smoke coverage, including the worker-candidate lane.
- **D. Worker pool.** A bounded OS-thread lease consumes snapshot-isolated
  worker-candidate fibers from the shared scheduler queue during root execution
  and root waits. AtomicArc threaded builds start the lease by default, with
  `GENE_WORKERS=N` for explicit sizing and `GENE_WORKERS=0` for disabling it.
  Idle worker parking now uses scheduler condition-variable wakeups, root waits
  help with worker candidates, and scheduler timers wake parked workers.
  Production work stealing, richer timer/I/O ownership, per-thread tuning, and
  pinned global init remain open.
- **E. Load balancing + the deferred pieces.** Work stealing and async-I/O.

## Recommendation

**Keep the OS-thread worker lane bounded and restricted.** It is gated on
consuming only snapshot-isolated leaf worker-candidate tasks and on `atomicArc`
threaded builds; the remaining work is production lifecycle/orchestration, not
the cheap refcount tax. The cooperative root lane is correct and already delivers
suspendable tasks, channels, await, actor handlers, `actor/ask`, explicit task
cancellation, and child-task cancellation when a scope exits by
error/cancellation. Task cancellation resumes parked fibers through the normal
`GeneCancel` unwind path, so `ensure` cleanup runs before the task is finally
observed as cancelled. Normal scope exit waits for live child tasks. Owned actor
shutdown cancels queued asks and parked handler fibers so closed actors cannot
resume after their owner exits. Treat actors/channels and snapshot-isolated leaf
spawns as the units of parallelism; do not parallelize legacy
`spawn`-over-shared-scope.
