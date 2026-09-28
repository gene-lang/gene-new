# Native Extension Lifecycle

**Status:** the byte-ingress queue, typed registration, root-lane dispatch,
bounded cleanup, and owned Gene subscriptions are implemented. The
`genex/libuv_timer` package now uses the single opaque C API in
[`native_api.h`](../../src/gene/native_api.h). Its libuv owner thread sends
notifications through byte ingress and joins after both asynchronous handle
close callbacks. The consolidated adapter passed a 10,000-lifetime macOS
installed-app probe with its source checkout hidden and compiler unavailable;
native roots and materialized leases returned to baseline. Linux runtime
qualification remains open. The current validation record is the
[native ABI evidence](../profiles/native-app.md#native-ownership-and-c-abi).

**Stages:** NATIVE-1 (native ingress/ABI), NATIVE-2 (subscription/binding), NATIVE-3 (package qualification).

**Depends on:** VM-0 diagnostics; local C fixtures work before package distribution. Byte ingress handles retained foreign notifications; the managed callback feature handles synchronous Gene-to-C calls.

## Current boundary and binding choice

There is one C-facing `GeneApi` layout and one optional module initializer,
`gene_module_init`. Both are declared in
[`native_api.h`](../../src/gene/native_api.h). The numeric `version` field is
6, the only accepted layout in this greenfield project; `struct_size` and
feature bits let a module reject a missing operation before calling it.
`gene_module_init` receives an opaque environment handle and copied diagnostic
buffer. The former Nim versioned table and its dynamic loader have been
removed. Direct Nim helper functions remain for in-repo runtime code.

A foreign notification callback cannot wait for later Gene code to compute its
immediate C return value. Byte ingress therefore copies a notification and returns a
binding-defined enqueue/abort acknowledgment. A package shim provides typed C
registration and unregistration symbols; the runtime does not fabricate
arbitrary callback pointer signatures. Gene packages expose ordinary functions
and owned wrappers.

The managed loader and `native/ingress/open` use the same C structure.
`native/ingress/open` passes an ingress-only view whose feature bits advertise
only the three byte functions. A module initializer receives a stable
per-domain table with the mediated operations and ingress functions. The
register function must copy the table if it needs it after registration
returns. Native code may call only entries whose feature bits are present.

## Native ingress contract

Creation on the root lane gives the selected callable and dispatch environment
owning managed IDs, records a stable Application identity and monotonic
subscription ID/generation, and creates the native byte context. The C
entrypoint always queues, including calls made on the root thread. It may
copy a declared bounded payload and signal the scheduler; it never allocates
Gene values, touches a Scope, invokes Gene, or pumps the scheduler.

Each subscription has a bounded FIFO: default 256 notifications, 1 MiB total payload, 64 KiB maximum one payload. Queue admission must atomically reserve count and bytes. Copy failures or overflow reject the incoming notification and record a counter plus the first failure; the binding returns its declared C rejection code. The root lane then fails and unregisters the subscription. The queue has no silent drop-oldest or generic coalescing. A notification-only library that cannot observe rejection still produces a visible subscription failure.

Drain at most 32 notifications or the host's polling work budget per pass. Start at most one Gene handler at a time per subscription. Handlers run as normal root-lane tasks and may use supported Task APIs; an awaiting handler leaves later notifications queued under the same bounds. One subscription cannot monopolize scheduler turns. An ordinary handler error fails the subscription and initiates unregistration. Panic and unexpected cancellation preserve their TaskOutcome categories and reach the owning supervisor/host policy; do not convert them to an ordinary catchable error. The wrapper retains bounded diagnostics and counters while cleanup proceeds.

## Gene lifecycle

Package wrappers implement `IoResource` from [async I/O](async-io.md):

- `.IoResource:close` requests close immediately and is idempotent.
- `.IoResource:wait_closed` returns a fresh Task for native retirement and retained terminal error.
- A direct `.status` message returns a snapshot containing state, received/delivered/rejected counts, queued bytes, and the first failure.

State is active, closing, closed, with a retained terminal error. Explicit close rejects new notification admission, discards queued notifications with an observable count, cancels the running handler, and initiates native unregistration. An already-running handler may have performed effects; close does not reverse them.

**Native retirement needs two proofs:** the foreign library has confirmed that no future callbacks can begin, and the in-flight C-entry count has reached zero. Only then may the shim free the native context. Managed handler/environment/Task IDs and the wrapper's cleanup lease additionally wait for the active Gene handler to settle; wait_closed reports full retirement only after all three obligations. Every C entry increments/decrements that count while the context is valid. A generation check rejects stale notifications in a live context; it cannot protect a pointer after that context has been freed.

Unregistration that blocks runs on a bounded native worker. Cancelling wait_closed does not cancel the unregistration obligation. The Application retains cleanup leases through shutdown as specified by IO-1. A library that cannot provide the no-future-callback guarantee cannot use this mode. Keep its context pinned and report failure; do not guess that a timeout makes freeing it safe.

## Ownership and package boundary

Opaque Gene values use mediated owning IDs at the public C boundary. Buffer loans state element type, length, alignment, read/write mode, copy-back, and lifetime. No borrowed pointer survives its loan, and no native callback retains a buffer loan implicitly. Native receiver/close/Send checks remain authoritative. Native code admitted in-process remains trusted.

Local fixture builds may use the existing C/Nim tooling. NATIVE-3 uses PKG-2 from [package distribution](package-distribution.md) to record target, ABI, toolchain, shared-library requirements, and content digests. It does not wait for a hosted registry.

## Implementation and acceptance

| Stage | Work | Exit tests |
| --- | --- | --- |
| NATIVE-1 | Maintain byte-ingress/context helpers behind the single C API layout; registration shims reject mismatched version, size, or feature bits. | Exact ABI mismatch rejection; real C fixture emits from another thread; no Gene heap access on that thread; overflow and allocation-failure paths. |
| NATIVE-2 | Root-lane polling, serialized handlers, IoResource wrapper and physical-retirement accounting. Extend the C ingress fixture and native callback/thread suites. | Close during C entry, cancellation during unregister, callback error, queued overflow, notification after logical close but before unregister, and zero roots after physical retirement. |
| NATIVE-3 | One pinned libuv timer/notification adapter in `genex`, packaged through PKG-2. | Repeated create/notify/close across two qualified platforms, installation without checkout, one ABI header and initializer. |

The libuv fixture keeps its loop/handles on one native owner thread, delivers timer notifications through the ingress queue, and uses the asynchronous close callback as the library retirement acknowledgment. Handle storage remains valid through that callback, following [libuv's handle lifecycle](https://docs.libuv.org/en/v1.x/handle.html). Test the source contract's valid late-callback window, never intentionally invoke a freed pointer and call that a recovery test. Record native handle/context/root counts over 10,000 subscription lifetimes. Backend C lowering and generic callback-pointer factories remain separate work.
