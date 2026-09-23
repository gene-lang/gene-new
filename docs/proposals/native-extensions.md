# Native Extension Lifecycle

**Status:** Implementation proposal, reviewed against `3b2bde9`.

**Stages:** NATIVE-1 (native ingress/ABI), NATIVE-2 (subscription/binding), NATIVE-3 (package qualification).

**Depends on:** VM-0 diagnostics; local C fixtures work before package distribution. The retained mode is for notifications, not arbitrary synchronous C callbacks.

## Current boundary

`native_api.nim` exposes a fixed-layout GeneApi v4 and exact version checks. Call-scoped callbacks already preserve Gene error/panic/cancellation, enforce the owning root lane, and pin borrowed handles. Keep that mode. Do not append fields to the v4 structure while calling it binary compatible.

A retained C callback cannot wait for later Gene code to compute its immediate C return value. The new mode therefore copies a notification and returns a binding-defined enqueue/abort acknowledgment. Libraries requiring a synchronous computed answer continue using the call-scoped mode or need a separately designed adapter.

## ABI and binding choice

Provide a separate v5 entry symbol `gene_module_init_v5` and a v5 API table with version, structure byte size, and feature bits. Keep `gene_module_init` with the exact v4 table through an explicit compatibility path. Package metadata declares v4 or v5; the loader selects the matching entry symbol and rejects a missing/unsupported one before calling library code. A library that needs both runtimes may export both. No probing an unknown structure layout by invoking it.

Initially expose retained-subscription helpers to library-specific native shims. Each shim provides a typed static C callback entrypoint, payload copy/disposal functions, and native unregistration. This does not require a general runtime factory for arbitrary C function pointer signatures. Keep public Gene APIs as ordinary package functions and owned wrappers.

## Native ingress contract

Creation on the root lane roots the selected callable and records its Application, code/scope references, a monotonic subscription ID/generation, and native context. The C entrypoint always queues, including calls made on the root thread. It may copy a declared bounded payload and signal the scheduler; it never allocates Gene values, touches a Scope, invokes Gene, or pumps the scheduler.

Each subscription has a bounded FIFO: default 256 notifications, 1 MiB total payload, 64 KiB maximum one payload. Queue admission must atomically reserve count and bytes. Copy failures or overflow reject the incoming notification and record a counter plus the first failure; the binding returns its declared C rejection code. The root lane then fails and unregisters the subscription. Version 1 has no silent drop-oldest or generic coalescing. A notification-only library that cannot observe rejection still produces a visible subscription failure.

Drain at most 32 notifications or the host's polling work budget per pass. Start at most one Gene handler at a time per subscription. Handlers run as normal root-lane tasks and may use supported Task APIs; an awaiting handler leaves later notifications queued under the same bounds. One subscription cannot monopolize scheduler turns. An ordinary handler error fails the subscription and initiates unregistration. Panic and unexpected cancellation preserve their TaskOutcome categories and reach the owning supervisor/host policy; do not convert them to an ordinary catchable error. The wrapper retains bounded diagnostics and counters while cleanup proceeds.

## Gene lifecycle

Package wrappers implement `IoResource` from [async I/O](async-io.md) once IO-1 exists:

- `.IoResource:close` requests close immediately and is idempotent.
- `.IoResource:wait_closed` returns a fresh Task for native retirement and retained terminal error.
- A direct `.status` message returns a snapshot containing state, received/delivered/rejected counts, queued bytes, and the first failure.

State is active, closing, closed, with a retained terminal error. Explicit close rejects new notification admission, discards queued notifications with an observable count, cancels the running handler, and initiates native unregistration. An already-running handler may have performed effects; close does not reverse them.

**Native retirement needs two proofs:** the foreign library has confirmed that no future callbacks can begin, and the in-flight C-entry count has reached zero. Only then may the shim free the native context. Callable roots and the wrapper's cleanup lease additionally wait for the active Gene handler to settle; wait_closed reports full retirement only after all three obligations. Every C entry increments/decrements that count while the context is valid. A generation check rejects stale notifications in a live context; it cannot protect a pointer after that context has been freed.

Unregistration that blocks runs on a bounded native worker. Cancelling wait_closed does not cancel the unregistration obligation. The Application retains cleanup leases through shutdown as specified by IO-1. A library that cannot provide the no-future-callback guarantee cannot use this mode. Keep its context pinned and report failure; do not guess that a timeout makes freeing it safe.

## Ownership and package boundary

Opaque Gene values use registered roots. Buffer loans state element type, length, alignment, read/write mode, copy-back, and lifetime. No borrowed pointer survives its loan, and no native callback retains a buffer loan implicitly. Native receiver/close/Send checks remain authoritative. Native code admitted in-process remains trusted.

Local fixture builds may use the existing C/Nim tooling. NATIVE-3 uses PKG-2 from [package distribution](package-distribution.md) to record target, ABI, toolchain, shared-library requirements, and content digests. It does not wait for a hosted registry.

## Implementation and acceptance

| Stage | Work | Exit tests |
| --- | --- | --- |
| NATIVE-1 | Extend `native_api.nim` and `native_errors.nim` with v5 ingress/context helpers; preserve the v4 loader branch and existing synchronous tests. | Exact ABI mismatch rejection; real C fixture emits from another thread; no Gene heap access on that thread; overflow and allocation-failure paths. |
| NATIVE-2 | Root-lane polling, serialized handlers, IoResource wrapper and physical-retirement accounting. Extend `tests/fixtures/native_callback_fixture.c` and native callback/thread suites. | Close during C entry, cancellation during unregister, callback error, queued overflow, notification after logical close but before unregister, and zero roots after physical retirement. |
| NATIVE-3 | One pinned libuv timer/notification adapter in `genex`, packaged through PKG-2. | Repeated create/notify/close across two qualified platforms, installation without checkout, v4 fixture still loads. |

The libuv fixture keeps its loop/handles on one native owner thread, delivers timer notifications through the ingress queue, and uses the asynchronous close callback as the library retirement acknowledgment. Handle storage remains valid through that callback, following [libuv's handle lifecycle](https://docs.libuv.org/en/v1.x/handle.html). Test the source contract's valid late-callback window, never intentionally invoke a freed pointer and call that a recovery test. Record native handle/context/root counts over 10,000 subscription lifetimes. Backend C lowering and generic callback-pointer factories remain separate work.
