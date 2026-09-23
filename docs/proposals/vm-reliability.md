# Long-Lived VM Reliability

**Status:** Proposed qualification and repair plan; it does not claim the listed runtime limits are fixed.  
**Purpose:** Make repeated eval, tasks, modules, and closures safe enough for long-running Gene services and tools.  
**Reference:** The VM is the first qualified backend. The web and C backends need separate lifetime evidence.

## Current risks and target contract

`docs/development.md` reports unreclaimed mixed scope/closure cycles, no ORC cycle collection for AtomicArc, and a hang involving eval-defined nominal types and methods. These are release blockers for the `native-app` service workload, not reasons to narrow Gene's public eval and type semantics silently. Every successfully ended task, generator, eval scope, and module generation must release resources it owns once no Application root, user value, or native root retains them. Reachable values remain valid. An arbitrary Gene program still must explicitly close external resources whose deterministic close matters; collection does not substitute for transaction/connection shutdown.

## Ownership and reclamation design

Document the strong-edge graph among Application/module roots, Scopes, capture cells, closures, generators, Tasks, actor mailboxes, native roots, and containers. Add counters for live instances and retained bytes by category to `$runtime/gc_stats`, plus a way for test code to request a safe-point collection pass. Counters are diagnostics, not a new semantic promise about exact collection time.

Use reference counting for acyclic paths as today. Add a root-lane cycle-reclamation pass for Gene-owned graphs that can contain Scope/closure/container cycles. It marks from Application roots, live task/scheduler roots, explicit native roots, and externally held Gene values, then breaks only unreachable cycles at a safe point. The pass must not run Gene finalizers or arbitrary user code while graph invariants are half-updated. Native handles are closed by their owning wrappers or explicit close contracts; a collector may release an unreachable wrapper only after its native borrow/lease has ended. Worker-owned Send snapshots and AtomicArc edges must be included in root accounting or held outside the candidate graph until safely joined. The first implementation may be stop-the-world on the root lane with a documented pause budget; concurrent collection is not required.

If the current Value/Scope representation cannot enumerate and sever a particular strong edge safely, move that cycle candidate behind a tracked wrapper before enabling collection for it. Never force-free an arbitrary Nim reference from an incomplete graph. A collection pass that cannot prove an object's unreachability retains it and reports an unhandled candidate in diagnostics; qualification remains blocked until that class is resolved.

Before choosing a collector implementation, build a minimal reproducer for each reported leak and inventory all strong edges. If a specific edge can be made weak without changing lexical lifetime semantics, do so, but do not treat one weak-edge fix as proof that user-created cycles are handled. The public target is reachable/unreachable behavior, not a particular collector algorithm.

## Eval and interruption

Compile and execute eval-defined nominal types/methods repeatedly in a fresh Env and in a retained Env. They must either work under the ordinary module/eval visibility contract or fail promptly with a documented typed error before publishing a partial definition. The selected target is to support them; an early rejection is only a temporary diagnostic while the hang is repaired. Compilation, method registration, and scope teardown cannot leave a half-selected type or method after cancellation. A runaway foreground program must hit its configured step/time limit while event receipt and operator stop stay responsive.

## Qualification suite

Run each case at 1, 100, 1,000, and 10,000 cycles, in a fresh process and a process kept alive throughout:

- Create and release closures with mutable captures, self-reference, and container/scope cycles; retain one control closure and verify it still works.
- Create, partially consume, close, and naturally exhaust generators; spawn/cancel/join tasks; register/remove actors and callbacks.
- Repeatedly eval functions, nominal types, methods, and imports, including one compilation failure and one cancellation during setup.
- Serve repeated HTTP requests with database/file activity and injected slow/failed clients; compare live object counts and retained memory after quiescent collection points.

The suite runs in a subprocess with a timeout so a hang is a failing test, not a stuck CI job. A test passes when live counts return to their defined baseline plus explicitly retained controls, external handle counts return to zero, no output/operation is duplicated after cancellation, and memory reaches a stable plateau within a published envelope. Record allocator and platform details; do not infer a leak from one RSS sample or hide a growing live-object count behind free allocator pages. Include p95/p99 pause and request latency in the sustained-service report.

## Implementation order

1. Add reproducers, edge inventory, and counters; capture the existing baseline without altering semantics.
2. Fix the eval/type hang and install the safe-point cycle path with root/native lease tests. Keep current VM specs and local application tests passing.
3. Run the qualification suite and [native-app service fixture](python-replacement-profile.md) on supported platforms. Promote the profile only after the published lifetime and responsiveness gates pass.

**Acceptance:** a 10,000-cycle long-lived process retains only deliberately reachable state, closes all test-owned resources, stays responsive to cancellation, and repeatedly defines/uses eval-local types without hanging or corrupting later executions.
