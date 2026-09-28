# Native byte-ingress foundation

The C layout and return codes are declared in
[`native_api.h`](../../src/gene/native_api.h). `GeneApi` has numeric layout
version 6, but its public names and entry symbol are unversioned.
`native/ingress/open` passes a sized ingress-only view with the ingress feature
bit and `ingress_begin`, `ingress_enqueue`, and `ingress_end` entries.
A registration shim must copy this table if it needs it after registration.

The root lane creates a subscription record that roots its handler and owns a
raw shared ingress context. C code receives only that context pointer and its
generation. A callback calls `ingress_begin` before touching the context,
queues a copied payload with `ingress_enqueue`, then calls `ingress_end`.
Generation mismatch or logical close rejects entry. These C-callable helpers
use raw locks, `malloc`, and byte copies; they do not create Gene Values or
enter a Gene Scope on the foreign thread.

The initial FIFO accepts at most 256 notifications, 1 MiB queued bytes, and
64 KiB per payload. Smaller per-subscription limits are allowed. Admission
reserves count and bytes under one lock. Overflow or copy-allocation failure
rejects the notification and retains the first failure code; there is no
drop-oldest policy. Root-lane `geneIngressPop` produces the owned Bytes for a
future Gene handler. The context records received, delivered, rejected,
discarded, queue size, and in-flight C entries.

The VM completion pass polls registered subscriptions with a 32-notification
global budget and a four-notification slice per subscription. Only one Gene
handler Task runs for a subscription at a time; an awaiting handler leaves
later payloads queued. Normal completion increments `handled`. An ordinary
error, panic, or unexpected cancellation retains its TaskOutcome category,
closes admission, and discards queued payloads. Explicit close cancels a
running handler without converting that expected cancellation into an error.
The owning lane can inspect a snapshot of state, counts, queued bytes, and
first failure through the Nim-facing subscription API.

On native POSIX builds a nonblocking self-pipe carries the ingress wake. C
entry writes one byte after queue admission or rejection; the root scheduler
polls that pipe while waiting for timers. The signal does not touch Gene heap
objects. A foreign notification delivered during a long root sleep is
dispatched promptly in the focused timing test. AtomicArc external Task waits
also use this wake path while a subscription is active; they cannot enter an
indefinite condition wait that prevents root-lane unregistration completion.

Close rejects new notifications and discards queued bytes. The root may
destroy a context and release the handler root only after the foreign library
confirms no future callbacks and the in-flight entry count reaches zero.
The real C fixture exercises foreign-thread entry and an entry held across
close. It does not invoke a pointer after release.

An optional library-specific `unregisterProc` runs on one native worker with
a bounded 128-job queue. If that queue is full, the root keeps the close
obligation and retries admission on later completion passes. The worker
touches only raw job/context pointers and never runs Gene code. A successful
unregister result confirms no future callback starts; the root still waits
for in-flight C entries and the active Gene handler before retiring the
cleanup lease. A nonzero result retains the context and reports an error;
the runtime does not guess that the library has stopped callbacks. The C
fixture verifies prompt close despite a slow unregister call and that a late
entry keeps retirement pending.

The Nim library adapter may wrap a live subscription with
`newGeneIngressHandle`. The returned Gene `NativeIngressSubscription` is
non-Send and implements `IoResource:close` and `IoResource:wait_closed`;
its direct `.status` message reports state, received/delivered/handled/
rejected/discarded counts, queued count/bytes, in-flight entries, first
failure, terminal category/message, and unregister progress. Close is
idempotent and requests native cleanup promptly. Every wait_closed call
returns a fresh Task. Cancelling one waiter leaves unregistration and other
waiters intact. Success/error/panic/cancellation remain distinct terminal
Task outcomes; cleanup leases retire only after the three physical proofs.
A failed unregister reports a retained error but keeps the context pinned
until an external guarantee discharges the missing proof. An abandoned Gene
handle requests close on the root completion pass; GC alone never proves
native retirement.

For a pure C package shim, `($native/ingress/open library handler
^register "shim_register" ^unregister "shim_unregister")` provides the
root-lane creation bridge. `library` is an open `ffi/Library`; the register
symbol has the fixed `GeneIngressRegister` signature in the single C header and
receives the API table, raw ingress context, generation, and an output native
context pointer. The unregister symbol has the fixed
`GeneIngressUnregister` signature. Both symbols are required and validated
before registration runs. The package function can
wrap this call in its own Gene API; the runtime does not synthesize arbitrary
C callback signatures. Optional `^max_count`, `^max_bytes`, and
`^max_payload` select tighter queue limits.

The runtime borrows the library until physical retirement and rejects an
explicit `ffi/Library/close` while the subscription is live. A failed
registration still starts native unregistration and retains the cleanup
obligation; it does not free a context merely because opening raised. The
registration shim must return a native context that its unregister function
can safely retire, including a partial registration that reports failure.
An absent output context is an opening failure; the runtime retains its own
ingress context while attempting the binding's unregister function rather
than publishing an ownerless handle.

`genex/libuv_timer` is a package-level byte-ingress example. Its `c_library` recipe
builds against libuv 1.52.x; the Gene `open` function returns an `IoResource`
wrapper retaining the materialized image and FFI library until native
retirement. Both libuv handles live on one owner thread. Unregistration wakes
that thread with `uv_async_send`, waits for the timer and async close callbacks,
then joins the thread and frees its context. The installed-app fixture covers
10,000 create/notify/close lifetimes without the source checkout or compiler.
It verifies zero live contexts/handles after each close, 20,000 handle close
callbacks overall, and native-root/materialized-lease baselines. Linux runtime
qualification remains open.
