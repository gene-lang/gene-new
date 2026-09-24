# Long-Lived VM Reliability

**Status:** VM-0 lifetime counters/ledger and selected VM-1 repairs are experimental. The nested `try`/`ensure` scope-unwind path now settles noncancelable I/O cleanup leases on error, panic, return, and task cancellation. Built-in protocol implementation values are published for atomic RC before worker lookup, fixing a reproducible concurrent error-admission use-after-free. VM-2 retirement is experimental for one candidate class: released, discarded, and failed-prepare sandbox generation roots. It replaces the earlier scalar-only `this_mod` repair with trial deletion over the pending roots under the module-mutation pause (see VM-2 below). Released scalar and Type/protocol/impl generations, and discarded or failed ones, hold flat managed counts through 10,000 lifetimes, and retained module, function, and instance controls still execute. A related VM-1 repair makes a Value destroyed during Nim exception unwinding complete its release; each failed preparation previously leaked 11–15 managed values. Retirement also models shared `#Ref` tables and fresh or yield-suspended generator Fibers (through a VM-installed adapter). The same unwinding rule now covers other destructors that do real work (`withoutPendingException` in `pending_exception.nim`). A test-only RC collection safepoint and macOS arm64 VM-3 probes report flat 1/100/1,000/10,000 batches for fixed eval/closure/cell/failure, escaped witness, cancellation, partial-selection cancellation and failure, in-process HTTP service, and generation vocabularies. Other mixed-cycle classes, sustained external-load service lifetime, AtomicArc, and Linux qualification remain open. Design baseline `3b2bde9`.

**Stages:** VM-0 (evidence), VM-1 (eval/ownership repairs), VM-2 (cycle coverage), VM-3 (qualification).

**Depends on:** Nothing for VM-0/1. IO/NET/NATIVE add later integration cases.

## Supported runtime and actual baseline

Qualify the cooperative VM with ORC and root-lane Gene execution first. Native I/O workers may exchange their supported native payloads; concurrent Gene worker lanes under AtomicArc remain a separately qualified feature. Browser and C lowering have separate gates.

The standalone native threaded suite built with default ORC reproducibly
crashes in its concurrent shared-Value await case; the repository's supported
AtomicArc `threadcheck` configuration passes that case. Do not count the ORC
threaded combination as qualified or silently expand the native-app profile to
it before the shared-Value ownership fault is isolated.

Dynamic FFI owned pointers now pin their release library, retire on explicit
close or reclamation, and allow an unreachable library to close afterward.
The current Nim 2.2 compiler warns that the ref finalizer constructor used for
that fallback is deprecated; migration to a supported destructor arrangement
remains a VM-3 toolchain qualification item. ORC and AtomicArc lifetime gates
pass on the current compiler.

Released-generation retirement reads the Nim 2.2 ORC reference header as its
count adapter (see VM-2). A first-use probe disables retirement when the
layout differs, and `nimble leakcheck` then fails its retirement-availability
and generation cases rather than leaking silently. Re-run `nimble leakcheck`
and the lifetime profile on every Nim upgrade before trusting retirement.

AtomicArc retirement is a separate qualification task: it needs the worker
pause plus dedicated thread tests (active worker lanes, shared impl values,
sanitizer runs) before it can be enabled. Until then AtomicArc builds retain
released generations. The memory model is pinned in `config.nims` only when
the command line names none; `nim.cfg` used to pin ORC unconditionally, so a
`--mm:atomicArc` build also defined `gcOrc` and compiled ORC's header and cycle
collector into what was reported as AtomicArc.

The current runtime is not a single tracing heap. `types.nim` uses NaN-boxed Values with manual reference counting, weak captured-scope storage/strengthening, Nim-managed scopes, and a conservative trial-deletion path for selected Cell/Env/EventBus object cycles. `runtime/gc_stats` already exposes live-managed and scheduler counters. `docs/development.md` reports remaining mixed cycles and an eval-defined type/method hang. Reproduce each on the selected revision before assigning a cause; these are reported limits, not newly reproduced results.

Do not install a second mark-and-sweep collector that assumes a scan of Application roots can see every local Value, native root, ORC edge, or worker reference. Extend the existing ownership mechanisms with an explicit edge inventory and proofs for each new candidate class.

## VM-0: evidence and observability

Add a lifetime ledger under `tests/lifetime/` with one entry per retained class: source reproducer, owning/borrowed edges, expected roots after quiescence, supported memory manager, and current result. Cover closures/scopes, nominal Types/impl witnesses, generators, Tasks/results, containers, modules/eval generations, Cells/Envs, and native roots/leases.

Extend `gc_stats` additively with available per-class allocation/live counts, candidate counts, native roots, and active cleanup leases. A counter unavailable in that build is marked unavailable, never returned as a misleading zero. Preserve existing fields. Add a test-only safe-point collection hook in the native test harness; do not make general application code depend on collection timing.

Run reproducers in child processes with a hard harness deadline and capture their last progress marker. A hang fails the test without hanging the suite. Record the runtime commit, compiler version, memory manager, thread mode, flags, and warm-up procedure.

## VM-1: ownership and eval behavior

Repair the smallest owning edge or teardown sequence that explains each reproducer. Weak edges are allowed only when an independent owner keeps the target alive; an escaped closure, Type, or method must retain everything required for a later call. Exercise both release and escape cases. A reduction in live count is not success if a retained value becomes dangling.

Support repeated eval-defined Types and methods under the existing visibility contract. Stage method/impl validation before publishing a complete selection. Failure or cancellation must not leave a partially installed Type/impl or unusable eval environment. Do not turn a transient early-rejection workaround into the completed feature. Ordinary program effects that happened before a failure remain effects; there is no whole-eval rollback.

Use the existing interruption/safe-point mechanism. A root-lane loop with a configured budget must terminate within that budget's documented checks. Native blocking work uses IO cleanup rules; VM interruption cannot imply that arbitrary C stopped or that its external writes were undone.

The canonical witnesses added by [value operations](value-operations.md) are strong roots of their code/environment. Include Type → witness → method scope → Type cycles in this inventory before VAL-1 is qualified.

## VM-2: conservative cycle coverage

Keep reference counting for acyclic values and reuse the existing trial-deletion approach. For each candidate connected component:

1. Pin candidates during analysis. Enumerate every participating strong edge, identifying borrowed/weak edges separately.
2. Derive external references by subtracting known internal owning edges from accounted references. Any unknown edge, inconsistent count, active native borrow, or shared/thread-owned node conservatively keeps the affected component alive.
3. Trace live candidates from that external-reference set. Only candidates with a complete edge model and no live external path may be reclaimed.
4. Sever owned edges with normal retain/release discipline at a root-lane safe point. Defer arbitrary user callbacks and native cleanup to their existing safe lifecycle path.

Mixed manual-RC/Nim-scope components require explicit adapters for edge accounting and release; casting an arbitrary Nim ref and forcing its count is forbidden. Until an adapter is proved, retain/report that candidate class and repair the ownership cycle at its source where possible. A native handle still callable by C remains rooted until physical retirement.

Released sandbox generations are the first adapted class (`retireReleasedGenerations` in `types.nim`). Their roots wait in an Application list, one owned reference each, and are analyzed when a generation is released, discarded, or fails preparation, and at the test collection point. The Scope/ORC-object adapter reads the ORC reference header as a complete total of boxes and Nim refs; it never writes a count. A first-use probe checks that `GC_ref`/`GC_unref` move that header by exactly one, and retirement is off when the layout is unknown, under AtomicArc (this repository defines `gcOrc` there too), and in the wasm module. Boxed Values use their manual counts. Strong edges are counted once per owner, including scope parents, promoted Type/Function scopes, impl entries, and forObjectEdges. Weak edges (defining-scope pointers, message and variant owner bits) are followed from every live node, expanded or not. Unenumerated edges (compiled-code constants, error evidence, `RootRef` state, `moduleRefs`) are never subtracted, so their targets stay alive. An over-count aborts the pass, and an active CPtr/FFI-library borrow pins its node. Only expanded Scopes that no live node reaches are torn down: their Value fields move out and are released while every doomed Scope stays pinned. Under ORC no Gene worker lane exists, so a value marked shared by impl publication is still a stable total. Retirement advances a dispatch-cache epoch component rather than `implEpoch`, which open sandbox transactions compare to detect a changed live base.

Candidate work is processed in bounded passes (initially 1,024 edges per poll). A partially analyzed component stays pinned; callbacks/tasks may resume only if mutations invalidate or restart that analysis safely. The first implementation may analyze one bounded component without yielding. Larger components must be deferred intact or processed under an explicit maintenance pause; never skip edges to meet a pause target. Publish the supported graph-size/latency envelope.

Shared AtomicArc graphs are excluded from this first reclamation path. A later threaded collector requires worker quiescence and independent thread tests; passing ORC tests cannot qualify it.

## VM-3: release gates

Use batches of 1, 100, 1,000, and 10,000 lifetimes after a fixed warm-up. Reuse a bounded set of source texts, names, and module paths so symbol interning or an intentionally retained module cache is not mistaken for a leak. Separately test explicit generation release and intentional retained roots.

| Scenario | Gate |
| --- | --- |
| Closures/cells/containers, including self and mixed cycles | After release/collection, per-class live counts equal warm baseline plus named retained controls; controls still execute correctly. |
| Repeated eval Types/methods, including failure/cancel | No hang, dangling method, leaked selection, or corruption of the next eval. |
| Partial/exhausted generators and task/actor teardown | Ensure runs once, result ownership follows await/join rules, scheduler queues drain. |
| External/native ownership | Root/handle counts return to the declared baseline only after physical cleanup; pending cleanup is reported honestly. |
| Sustained service after IO/NET | Stable queues and retained-object counts, no leak slope across batches, bounded stop and documented p95/p99 loop/collection pauses. |

RSS is supporting evidence, not the sole leak oracle. Record allocator retention and post-warm-up memory at the same quiescent checkpoints; the profile manifest fixes a finite memory-growth budget for that host before qualification. No unavailable counter or unclassified candidate may be counted as a pass for a claimed workload.

## Code and validation map

Start in `types.nim`, `vm.nim`, `native_api.nim`, and the existing RC/lifetime, protocol, VM, and native-root suites. Run the relevant `test_rc` and eval regressions per fix; run `nimble spec`, `nimble leakcheck`, and service qualification at the release boundary. Use `nimble threadcheck` only to claim threaded support or when a changed shared edge requires it. VM-0/1 should land first; VM-3 closes after the other proposals' workloads exist.
