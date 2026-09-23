# Native Extension Lifecycle

**Status:** Proposed design; Gene's native API v4, owned wrappers, buffers, and call-scoped synchronous callbacks are the current baseline.  
**Purpose:** Support ordinary external C libraries, including callbacks retained after the initiating call, without calling the Gene VM unsafely from foreign threads.  
**Boundary:** Native code admitted in-process is trusted; this does not add a language permission system.

## Compatibility decision

Keep v4 extension loading and call-scoped callbacks working. Introduce a versioned extension ABI for the new retained-callback mode; an incompatible binary fails at load with its required/available ABI versions. A package records the native binary's target triple, ABI version, digest, and required shared libraries, as described in [package distribution](package-distribution.md). Loading a different binary under the same identity is an error, not an implicit fallback.

Gene values remain opaque to C. A native extension retains a Gene value only through a registered root handle, and releases it on the owning Application's lane. Buffer loans state element type, byte length, mutability, alignment, pin/copy behavior, and the exact period the native side may access them. A callee cannot retain a borrowed pointer after the loan closes. Existing native-wrapper close, constructor, and Send rules remain authoritative.

## Retained callback contract

Add an owned `NativeSubscription` wrapper whose `close` method starts native unregistration and whose terminal status confirms the foreign library can no longer invoke the callback. The extension holds one callback context until that confirmation. It never frees the C context merely because Gene requested close or a Task was cancelled. A library unable to provide a no-more-callbacks guarantee cannot use this mode safely; it must use a process adapter or a binding-specific isolation strategy.

A retained callback always copies a bounded, declared C payload into a native ingress queue and signals the Application, even if native code happened to call it on the root lane. The Gene root lane later drains that queue, converts payloads to Gene values, and invokes the rooted Gene function as ordinary scheduled work. Direct invocation remains available only to the existing call-scoped callback mode during its active foreign-call window. No foreign thread allocates Gene heap values, accesses a Scope, runs the scheduler, or calls a Gene function directly. The queue has a declared capacity and explicit overflow behavior (`reject`, `coalesce`, or binding-specific loss with a counter); it cannot silently grow. Payload conversion failure and callback errors are observable on the subscription, not unwound through C.

Closing a subscription stops new admission, drains or discards queued payloads under its selected policy, asks the native library to unregister, waits for the library's terminal confirmation through a Task/status query, and then releases the Gene root and C context. Cancellation of the waiting Task does not skip native unregistration. Application shutdown reports a still-active subscription and follows a bounded stop policy; it does not free memory still reachable by C. A generation number on the context rejects late notifications from an old registration.

## Extension packaging and diagnostics

The extension package contains a declarative build recipe or immutable platform binary plus its headers/library dependency identities. Builds run outside the Gene VM and include compiler, target, flags, source digests, and dependency digests in their artifact identity. The loader reports the exact missing library, ABI mismatch, or symbol. Native faults may still terminate the process; Gene errors, panic, and cancellation cross the safe native boundary using the existing status model.

## Implementation stages

1. Preserve v4 conformance and extract reusable root/borrow/close checks from the SQLite callback adapter. Add a small C fixture that retains a callback and invokes it later on another thread.
2. Implement bounded native ingress and root-lane delivery, with explicit queue overflow and callback-result/error reporting. Test cancellation, close races, late callbacks, and repeated registration without leaked roots.
3. Expose the `NativeSubscription` lifecycle through one real third-party library binding. Package and install it on two declared target platforms; run it without the source tree.
4. Add optional C-backend lowering only after VM behavior is stable. The VM remains the reference for this proposal.

**Acceptance:** the fixture can register, receive, cancel, unregister, and restart a retained callback repeatedly, including foreign-thread delivery and a late-call race, with no Gene VM entry from a foreign thread and no retained roots after terminal close.
