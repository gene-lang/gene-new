# Managed native extension ABI

**Status:** one public C layout, `GeneApi`, lives in
[`native_api.h`](../../src/gene/native_api.h). Numeric layout version 6 is the
only supported native extension version. The managed loader, opaque handles,
copied scalar reads, frozen traversal, call/define, and AtomicArc attached-lane
admission are implemented against a compiled C fixture. Byte ingress is
present in this same layout and powers `genex/libuv_timer`; its Gene handler
is still rooted by the existing subscription implementation. General retained
C callback registration and full managed ownership for ingress subscriptions
remain to be implemented. The owner selected opaque handles in
[Native managed borrows](native-managed-borrows.md). Current qualification is
recorded in the [single native C ABI audit](../profiles/native-app-2026-09-28-native-abi-consolidation.md).

## Boundary and entry point

A loadable module exports `gene_module_init`. Package selection validates the
single supported numeric ABI version. The managed loader checks the open
library, initializer symbol, and required feature bits before invoking C.
The initializer checks `version` and `struct_size` before using the table.
There is no legacy symbol dispatch. The initializer receives an opaque
owning environment ID and a caller-owned copied diagnostic buffer. Its C
signature and full table layout are in
[`native_api.h`](../../src/gene/native_api.h). No Nim `Value`, `Scope`,
`GeneRoot`, `GeneModule`, exception, or Nim string crosses this boundary.

The managed loader keeps a table at a stable per-domain address. The
`native/ingress/open` bridge passes an ingress-only view of the same layout;
its register function must copy the table before returning if it needs its
function pointers later. Both paths obey feature-bit negotiation. The ingress
bridge retains its library through physical unregister, zero in-flight entries,
and handler settlement. The managed loader still needs an
equivalent lease for future callback and producer registrations. A native shim
cannot use its table or context after physical retirement.

The handle representation is an unsigned 64-bit ID, never a cast Gene pointer.
ID zero is invalid. Each call also carries `runtime_context`, so lookup checks
the owning Application/domain before touching Gene memory. IDs are monotonic
and never reused during a domain lifetime. Releasing a handle removes its
registry entry; a stale ID fails even when the native library still stores the
number. Domain close rejects new admission and reports pending while mediated
handles, borrows, producers, or C attachment tokens remain. Future callback
registration must add its physical owners to this close accounting.

## C operations

The C header fixes the prefix and common output conventions. Status values
are `0=ok`, `1=error`, `2=panic`, `3=cancelled`, `4=pending`. A null diagnostic
descriptor is allowed; when supplied, `required` is always set and bytes
beyond `capacity` are never written. Strings and names are UTF-8 byte spans,
never NUL-dependent.

The first wire kind values are `0=nil`, `1=Bool`, `2=Int`, `3=Str`, `4=Bytes`,
`5=List`, `6=Map`, `7=Node`, `8=callable`, `9=Task`, `10=Channel`,
`11=ActorRef`, `255=other`; they are not Nim `ValueKind` ordinals.

Feature bit 0 (`GENE_API_IDENTITY_FEATURE = 1`) currently permits only
root-lane `retain`, `release`, `kind` and `new_i64` on every manager. Feature
bit 4 extends retain/release/kind to explicitly attached AtomicArc lanes;
construction stays on the root lane.

Feature bit 1 (`GENE_API_SCALAR_FEATURE = 2`) adds root-lane Bool/Int64
copies, copied Str/Bytes reads and Bool/Str/Bytes constructors. Incoming text
must be valid UTF-8; Bytes may contain any octets. One copied input is bounded
to 64 MiB, and both output reads support a length probe with a zero-capacity
buffer. Neither feature exposes a Gene pointer.

Feature bit 2 (`GENE_API_CALL_DEFINE_FEATURE = 4`) adds root-lane environment
lookup, positional call and definition. Calls accept at most 4,096 positional
IDs and return separate owning value/error IDs with copied status. A definition
stores its known weak/code Scope provenance in the target binding until
redefinition or Scope retirement; the returned ID has its own independent
ticket. This permits Scope-bearing functions and protocols without permanent
publication.

Feature bit 3 (`GENE_API_FROZEN_FEATURE = 8`) adds root-lane length, copied
key and child-handle traversal for deeply frozen List/Map/Node values. Child
handles inherit the parent's known weak/code Scope provenance. Selectors and
ordering are fixed below; mutable and shallow-frozen containers fail with a
copied error. Map and Node keys are copied by insertion-order index while the
symbol-table lock protects the interned key sequence. Enumerating every key
is linear in the number of entries.

Feature bit 4 (`GENE_API_ATTACHED_FEATURE = 16`) is advertised only in
threaded AtomicArc builds. A C thread receives a monotonic attachment token,
bounded to 256 simultaneous tokens per domain. The token retains its runtime
through physical detach; wrong-lane detach leaves it live. While attached, the
thread may retain/release IDs and use kind, copied scalar/Bytes reads and
deep-frozen traversal. Constructors, environment lookup, calls and definitions
remain root-lane operations. New reads are rejected before attach, after
detach and after domain close. Release and detach remain available after close
so shutdown can drain physical owners; `geneManagedClose` reports pending
while any token remains. Default ORC does not advertise this bit.

The header is normative; it defines the complete fixed prefix and the
appended ingress entries. `GENE_API_VERSION` is `6`. Feature bit 5
(`GENE_API_INGRESS_FEATURE = 32`) enables `ingress_begin`,
`ingress_enqueue`, and `ingress_end`. The ingress-only view advertises no
managed-handle operations. A module table advertises only implemented
families. Null slots must never be called.
`GENE_API_CALLBACK_FEATURE = 64` is reserved but never advertised until
registration and physical retirement are implemented.

`length`, `copy_key` and `traverse` use selectors `0=List item`, `1=Map
entry`, `2=Node body`, `3=Node prop`, `4=Node head`. `copy_key` applies only to
Map entry and Node prop. The index selects an element after a copied length
check; Node head has length one. `traverse` returns Map/Node property values,
while `copy_key` copies their keys. All traversed containers must be deeply
frozen; an unfrozen container returns a typed error instead of a pointer.
Byte-ingress entries follow `lookup` in the current layout. Future task
producer operations may append new slots; callers check both `struct_size`
and the feature bit before reading an optional slot.

The first table version has the following operation families. Each returns a
small status code; `GeneStatus` categories remain distinct (`ok`, error, panic,
cancelled). A failed operation writes a copied diagnostic into a caller buffer
and reports the required length if it does not fit. No returned pointer into
Gene memory survives a call.

| Family | Inputs and result | Lane and lifetime |
| --- | --- | --- |
| `retain`, `release` | Runtime context and ID; retain returns a new owning ID. | Any attached lane. Release removes the last owner outside registry locks. |
| `kind`, scalar reads | ID; copied Bool/Int64 or required byte count plus copy for text/Bytes. | A structured attached-lane borrow for the call extent. |
| Scalar constructors | Copied Bool/Int64/UTF-8 text/Bytes; return owning ID. | Root lane for the current implementation. |
| Frozen traversal | ID and index/key; returns a new owning ID. | Only deep-frozen List/Map/Node values; no raw container pointer. |
| `call` | Callable ID, owning argument IDs, environment ID; returns owned value or typed error ID. | Root lane; callback runs under owner-dependent admission. |
| `define` | Environment ID, copied name bytes, value ID; returns an owned binding ID. | Root lane; the Scope owns the binding independently. |
| `lookup` | Environment ID and copied name; returns an owning ID. | Root lane; resolves lexical parents under the same managed provenance walk. |
| `new_task`, `complete`, `fail`, `cancel`, `retire` | Opaque Task producer ticket and payload/error IDs. | Physical producer owner survives user cancellation until completion/retire. Typed foreign errors require a root-lane dispatch adapter before enabled. |
| `register_callback`, `request_close`, `wait_closed` | C callback/context, environment ID, registration token. | Runtime owns the context and library lease through unregister confirmation, zero in-flight calls and result settlement. |

The table's `struct_size` permits appending new function pointers in a later
minor feature level, but a caller may only use an entry after checking both
size and feature bit. The single ABI uses feature bits for optional operations. Initial
implementation can expose a subset behind feature bits; an extension that
requires an absent bit fails at initialization with a copied diagnostic.

## Native callback registration

`register_callback` stores a C function pointer, foreign context, context
retirement callback, environment handle and a strong library lease. Gene sees
the resulting callable through the existing native-function surface; no Gene
syntax or call convention changes. Invocation is on the runtime root lane and
receives temporary callback-scoped IDs for positional/named arguments. These
IDs are invalidated on return. Native code calls `retain` before storing an
argument beyond the callback. A returned value or typed error must be an
owning ID; the runtime consumes that ID exactly once. Native code may not
return a pointer to transient argument bytes as a result.
On registration failure ownership of `user_context` stays with the caller; on
success it transfers to the runtime and the retirement callback runs exactly
once after physical close. No callback or retirement function runs under a
registry or scheduler lock.
On initializer failure the loader closes every registration created during that
initializer, waits for physical retirement, then releases the environment and
library lease. A callback that returns a non-OK status leaves `out_value` zero;
it may return an owned typed `out_error` ID or a copied diagnostic. The runtime
consumes whichever owning output ID is present before leaving the callback
frame, even when the callback itself reports failure.

The registration token is distinct from every Gene value handle. Closing it
denies new invocations and waits for in-flight calls to finish before invoking
the foreign retirement callback. Physical retirement also waits for any
runtime-owned result Task to settle. Last-owner drops and foreign retirement
callbacks run outside the domain and scheduler locks. Re-entrant close from
inside the same callback reports pending, then completes after callback exit.
The library cannot unload while any registration, callback frame, producer or
ingress context still names its code.

## Byte ingress and managed ownership

The three C ingress functions operate only on a runtime-created byte queue.
They never accept Gene handles or call Gene on the producer thread. A C shim
receives an opaque ingress context and generation through its typed register
symbol, then calls `ingress_begin`, `ingress_enqueue`, and `ingress_end` in
order. The queue copies bytes. Close waits for a physical no-future-callback
unregister acknowledgment, zero in-flight C entries, and active Gene handler
settlement before freeing context or releasing the library lease.

The implemented subscription still holds a legacy rooted Gene handler and
Scope. The remaining migration is to store owning handler/environment IDs and
have the root lane invoke them through the managed registry. Only then can the
handler's raw publication pin be removed. This change must keep the byte queue
and the three physical retirement proofs intact. The Gene-side syntax
`$native/ingress/open` remains unchanged.

The managed loader currently exists as `geneManagedLoadModule` in Nim. Package
binary selection validates numeric ABI version 6, but invoking this loader
through every package-native path and retaining its library lease across
registrations are still integration work.

## Remaining implementation gates

1. Implement `register_callback`, `request_close`, and `wait_closed` with
   owning environment IDs, copied arguments/results, a runtime-owned context,
   and physical C retirement. Keep the feature bit absent until this passes
   nested calls, typed failures, close during callback, re-entry, and unload
   refusal while a callback is live.
2. Migrate ingress subscription handler/Scope ownership to managed IDs without
   changing `$native/ingress/open` or C byte entry. Prove cancellation,
   unregister delay, queued overflow, and 1/100/1,000/10,000 lifetimes.
3. Wire the managed loader into package-native module loading and retain its
   domain, table, and library until all registrations and producers retire.
4. Qualify default ORC, threaded AtomicArc, ASAN, supported TSAN, and
   installed packages. Shared reclamation remains disabled until the managed
   ownership and exposure inventory is complete.

Direct Nim helper functions still serve in-repo runtime code; there is no
second native module ABI or versioned loader.
