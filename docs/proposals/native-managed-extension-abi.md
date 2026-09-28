# Managed native extension ABI

**Status:** one public C layout, `GeneApi`, lives in
[`native_api.h`](../../src/gene/native_api.h). Numeric layout version 6 is the
only supported native extension version. The managed loader, opaque handles,
copied scalar reads, frozen traversal, call/define, and AtomicArc attached-lane
admission are implemented against a compiled C fixture. Synchronous retained
C callback registration now has temporary argument IDs, typed outcomes,
root-lane close, and physical library/context retirement. Its Task producer
family holds an independent library borrow until physical settlement or
retirement. The copied-result entry lets attached workers submit fresh
Nil/Bool/Int/Text/Bytes while the root lane constructs Gene values. Byte
ingress is
present in this same layout and powers `genex/libuv_timer`; subscriptions now
keep handler, environment, active Task and library ownership through managed
IDs until physical release. Package-native module loading now uses
`$pkg/native_module` and retains its domain, table, library and artifact
lease through close. The owner
selected opaque handles in
[Native managed borrows](native-managed-borrows.md). Current qualification is
recorded in the [consolidated native ABI evidence](../profiles/native-app.md#native-ownership-and-c-abi).

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
and handler settlement. The managed loader borrows its library through
initialization; each successful callback registration keeps an independent
borrow until its C context retires. Each C Task producer has its own library
borrow. A native shim cannot use its table or context after physical
retirement.

The handle representation is an unsigned 64-bit ID, never a cast Gene pointer.
ID zero is invalid. Each call also carries `runtime_context`, so lookup checks
the owning Application/domain before touching Gene memory. IDs are monotonic
and never reused during a domain lifetime. Releasing a handle removes its
registry entry; a stale ID fails even when the native library still stores the
number. Domain close rejects new handles and callbacks but admits an attached
lane while a C producer token is live so it can finish the producer. It
reports pending while mediated
handles, borrows, producers, callback tokens, or C attachment tokens remain.
Domain close requests callback closure and reports pending until token waiters
consume the registrations and other owners release.

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
Feature bit 6 (`GENE_API_CALLBACK_FEATURE = 64`) is advertised by the managed
loader for synchronous retained callbacks. The ingress-only table does not
advertise it.
Feature bit 7 (`GENE_API_TASK_PRODUCER_FEATURE = 128`) advertises the five
Task producer entries appended after ingress. It requires the callback feature.
Feature bit 8 (`GENE_API_TASK_COPY_FEATURE = 256`) advertises
`task_submit_copy` after the producer entries. It requires the producer bit.

`length`, `copy_key` and `traverse` use selectors `0=List item`, `1=Map
entry`, `2=Node body`, `3=Node prop`, `4=Node head`. `copy_key` applies only to
Map entry and Node prop. The index selects an element after a copied length
check; Node head has length one. `traverse` returns Map/Node property values,
while `copy_key` copies their keys. All traversed containers must be deeply
frozen; an unfrozen container returns a typed error instead of a pointer.
Byte-ingress entries follow `lookup`; Task producer entries follow ingress,
then `task_submit_copy`.
Callers check both `struct_size` and the feature bit before reading an
optional slot.

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
| `new_task`, `task_complete`, `task_fail`, `task_cancel`, `task_retire` | Owning Task ID, distinct opaque producer token, and payload/error IDs. | New Task on the root lane during a registered callback; settlement on root or attached lane. The physical owner survives user cancellation until completion, failure or retirement. Typed foreign errors require a root-lane dispatch adapter before enabled. |
| `task_submit_copy` | Producer token and copied Nil/Bool/Int/Text/Bytes source; status means queue admission. | Root or attached lane; the root poll constructs the Gene value and consumes the producer. Bounds and cancellation behavior are in [copied Task results](native-task-result-handoff.md). |
| `register_callback`, `request_close`, `wait_closed` | C callback/context, initializer environment ID, registration token. | Root lane; context and library borrow retire after close and zero in-flight calls. `wait_closed` consumes the token and returns an owning Task ID. |

The table's `struct_size` permits appending new function pointers in a later
minor feature level, but a caller may only use an entry after checking both
size and feature bit. The single ABI uses feature bits for optional operations. Initial
implementation can expose a subset behind feature bits; an extension that
requires an absent bit fails at initialization with a copied diagnostic.

## Native callback registration

`register_callback` is admitted during `gene_module_init`, when the loader
knows the matching library and module environment. It stores a C function
pointer, foreign context, context retirement callback, owning environment
handle, and a library borrow. Gene sees
the resulting callable through the existing native-function surface; no Gene
syntax or call convention changes. Invocation is on the runtime root lane and
receives temporary callback-scoped IDs for positional/named arguments. These
IDs are invalidated on return. Native code calls `retain` before storing an
argument beyond the callback. On `OK`, `out_value = 0` means Gene `nil`;
otherwise it must be an owning ID. On failure, `out_value` must be zero and
`out_error` may be an owning typed error ID. The runtime consumes each owning
output exactly once. Returning a temporary argument/environment ID without
retaining it is rejected. Native code may not return a pointer to transient
argument bytes as a result. The callback itself is synchronous, but it may
return an owning Task ID. `new_task` is admitted only inside an active
registered callback after module initialization has completed, and only for
that callback's environment. It returns the
Task ID and a distinct producer token. The runtime consumes the callback's
returned Task ID; the token keeps an independent Task owner, environment ID,
runtime pin and library borrow. The callback can return while native work is
still active. `task_complete` accepts a live payload ID or zero for `nil`;
`task_fail` copies a message and accepts zero or a live typed error ID.
Both consume the token and report whether the user Task accepted the outcome.
Invalid inputs are rejected before token consumption; once settlement is
admitted, the token retires even if the VM reports an error.
`task_cancel` requests user cancellation and reports acceptance but retains
the token. `task_retire` consumes it after physical cleanup and cancels the
Task if still pending. Stale tokens fail. The C caller retains ownership of
any payload/error IDs it owns and releases them separately. Attached lanes
must first use `attach_thread`, including when a domain is closing with a
live producer. An attached-lane result payload must be deep-frozen, and
typed failure IDs are restricted to the root lane. Final
environment and library-borrow release is performed on the runtime root
lane, including after attached-lane settlement. This lets module close wait
for physical completion even when the user Task was cancelled or its callback
registration retired.
An attached worker cannot create a fresh Str or Bytes ID with the root-lane
constructors. For a result computed only after the callback returns, the
[copied Task result handoff](native-task-result-handoff.md) accepts Nil, Bool,
Int, Text or Bytes through feature bit 8 (`GENE_API_TASK_COPY_FEATURE = 256`).
It copies the payload and queues root-lane construction without exposing a
Gene pointer or changing `task_complete` acceptance semantics. More complex
graphs use byte ingress and a root-lane Gene handler.
On registration failure ownership of `user_context` stays with the caller; on
success it transfers to the runtime and the retirement callback runs exactly
once after physical close. No callback or retirement function runs under a
registry or scheduler lock.
On initializer failure the loader closes every registration created during that
initializer, completes physical retirement, and releases every handle created
by the failed initializer. A callback failure may provide a copied diagnostic
and preserves error, panic, or cancellation status.

The registration token is distinct from every Gene value handle. Closing it
denies new invocations and waits for in-flight calls to finish before invoking
the foreign retirement callback. Last-owner drops and foreign retirement
callbacks run outside the domain and scheduler locks. Re-entrant close from
inside the same callback reports pending, then completes after callback exit.
`wait_closed` returns a fresh Task that settles after context retirement and
library release; it consumes the registration token. Callers request close
first, call `wait_closed` once, and may retain the returned Task handle if
they need multiple waiters. Cancelling that Task does not cancel retirement.
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

Each subscription has a dedicated managed owner. It stores owning handler,
dispatch-environment, active Task and optional library IDs; the root lane
invokes the handler through a managed borrow. A stable child Scope records the
Application at opening even when the VM's dispatch Scope inherits that identity
from the active scheduler. The subscription itself keeps no raw handler,
dispatch Scope, library root or active Task. Its waiters still own their caller
Scopes through the existing I/O Task leases. The handler's former permanent
raw-publication pin is gone; release of the managed IDs follows all three
physical retirement proofs. The byte queue and `$native/ingress/open` syntax
are unchanged.

The Nim `geneManagedLoadModule` loader is now reached through the selected
`$pkg/native_module` path for `gene_api` binaries. The returned `NativeModule`
IoResource owns the managed domain, module ID, open library and materialized
artifact lease. A source-built `c_library` marks `^abi_kind gene_api`; a
prebuilt `native_binary` declares the same ABI explicitly. The installed
source-built fixture passes 10,000 compiler-free lifetimes; the same installed
app loads a selected prebuilt variant. It rejects ordinary `c_abi`, rolls back
initializer failure, and closes an abandoned owner without
making an escaped Module callable jump into unloaded C code. The exact
Gene-facing contract is in [Packaged managed native modules](../spec/native-module.md).

## Qualification and remaining gates

The installed package close path passes a pending Task producer control. The
C callback and producer fixture passes default ORC, AtomicArc, ASAN, and TSAN
with initializer rollback, typed outcomes, re-entry, and repeated close/wait.
Its concurrent control creates 10,000 Tasks under AtomicArc with RC tracking,
cancels a quarter before worker release, races more user cancellation against
four attached C workers, and closes the domain before those workers attach.
It verifies every Task is terminal, every producer and attachment retires,
and the library closes after root-lane release. The same control passes with
1,000 Tasks under ASAN and TSAN. `GENE_NATIVE_TASK_STRESS_COUNT` sets the
count for longer runs (maximum 200,000 per run); the normal threaded gate uses
128. The separate RC-enabled callback registration probe reaches 10,000
lifetimes. Shared reclamation remains disabled until the managed ownership
and exposure inventory is complete. Late callback registration outside
`gene_module_init` remains a separate design choice.

Direct Nim helper functions still serve in-repo runtime code; there is no
second native module ABI or versioned loader.
