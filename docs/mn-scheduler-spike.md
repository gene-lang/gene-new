# M:N Scheduler — Thread-Safety Spike & Staged Plan

Status: **decision doc** (spike result, no shipped threads). Date: 2026-06-22.
Branch context: `scheduler` (cooperative single-worker scheduler, stages 1–3 done).

## Goal

Decide whether/how to move the cooperative scheduler (one worker, `threadvar`
state) to the design's M:N model (§13.1: "many Gene tasks run cooperatively across
a runtime worker pool"), and what it costs.

## TL;DR

- **Atomic refcounting is cheap (~2–4% worst case), not the blocker.** Measured below.
- **The real blocker is shared mutable state — scopes above all.** A spawned task's
  scope is `newScope(parentScope)`, so tasks share a mutable scope chain; ORC
  `OBJECT_TAG` objects (cells, channels, actors) use non-atomic `GC_ref`.
- **M:N fits the share-nothing actor/channel model; it does NOT fit arbitrary
  `spawn` closures that share a parent scope.** This is a design fork, not just an
  implementation cost.
- **Recommendation: defer the OS-thread worker pool.** Keep the single-worker
  cooperative scheduler (correct and useful today). If/when M:N is prioritized,
  do it as the staged epic below, starting with `vm-shared-rc` — but only after
  deciding the scope-isolation semantics.

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

1. **Shared mutable scopes (hardest).** `opSpawn` does `taskScope = newScope(scope)`;
   the task reads/writes outer vars through the shared parent `Scope` (`slots:
   seq[Value]`, mutated by `define`/`assign`/slot ops). Two spawned tasks on
   different threads racing on a shared scope is a data race the type system does
   not currently prevent. The design's own example shares scope:
   `(scope (var a (spawn (compute-a))) (var b (spawn (compute-b))) (+ (await a) (await b)))`.
   → Needs a decision: sent/parallel work must be **scope-isolated** (share-nothing,
   like actors/channels) OR scopes need synchronization (slow, complex). The actor
   and channel models already isolate state via Sendable messages and are the
   natural unit of parallelism; arbitrary `spawn`-over-shared-scope is not.

2. **ORC `OBJECT_TAG` objects.** Cells, channels, actors, mailboxes, Envs, types,
   etc. are ORC-managed via `GC_ref`/`GC_unref`, non-atomic under `--mm:orc`.
   Cross-thread sharing needs `--mm:atomicArc` or equivalent, plus locks on their
   mutable interiors (channel buffers, actor mailboxes/state).

3. **Scheduler structures are `threadvar`.** `schedRunQueue`, `schedWaiters`,
   `currentFiberActive`, `runStackPool` are per-thread. M:N needs a shared (locked
   or lock-free work-stealing) run queue and shared wait lists; channel/actor wait
   queues become cross-thread.

4. **Publishing / `Send` boundary.** Need a pass that marks a value (and its
   reachable graph) `shared` when it crosses a worker boundary (channel send,
   spawn to another worker, `freeze`), gated by the `Send` protocol. Closures are
   Sendable only if all captures are Sendable — which loops back to (1).

## Staged plan (if/when M:N is prioritized)

- **A. `vm-shared-rc`.** Per-object `shared` flag; `rcRetain`/`rcRelease` branch to
  atomic on shared. Publishing pass at Send boundaries. (Cost bounded above.)
- **B. Scope isolation semantics.** Decide and enforce: parallel/sent work is
  share-nothing. Likely: a task that may run on another worker captures a
  frozen/owned scope snapshot, not a live shared parent. This is the real design
  work and gates everything.
- **C. Thread-safe runtime objects.** `--mm:atomicArc`; locks (or lock-free) for
  channel buffers, actor mailboxes/state, and the shared run queue + wait lists.
- **D. Worker pool.** N OS threads each running the scheduler loop over a shared/
  work-stealing queue; per-thread run-stack pools; pinned global init.
- **E. Load balancing + the deferred pieces.** Work stealing, cancellation
  (deferred), timers/async-I/O, fiber-side `actor/ask` parking.

## Recommendation

**Defer the OS-thread worker pool.** It is gated on (B) scope-isolation semantics —
a genuine design decision — not on the (cheap) refcount tax. The single-worker
cooperative scheduler is correct and already delivers suspendable tasks, channels,
await, and actors. When M:N is taken up, start with A→B above and treat actors/
channels as the unit of parallelism; do not parallelize `spawn`-over-shared-scope
without first changing its isolation model.
