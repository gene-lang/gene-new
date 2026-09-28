# Managed native extension ABI

**Status:** implementation contract for the next AAR-1 increment. The owner
selected opaque managed handles in [Native managed borrows](native-managed-borrows.md).
This ABI adds a versioned C-facing extension path. Existing v4 `GeneApi` and v5
byte-ingress layouts, symbols, packages and lifetime rules stay unchanged.

## Boundary and entry point

An installed library may export `gene_module_init_v6`. Package metadata must
declare ABI 6 before the loader looks up that symbol. The loader rejects a
missing symbol, unsupported version, too-small table, unknown required feature
bit or closed library before invoking library code. It never guesses an ABI by
calling a symbol. A library may also export v4/v5 entry points for older hosts;
each path keeps its own ownership rules.

The v6 table is a new fixed C layout with `{version, struct_size, feature_bits,
runtime_context}` followed by function pointers. All function pointers use
the C ABI, fixed-width integers, explicit byte lengths and caller-owned output
buffers. No Nim `Value`, `Scope`, `GeneRoot`, `GeneModule`, `ref object`, exception
or Nim string crosses it. The module initializer receives the table and an
opaque environment handle, returns a status code and writes a bounded copied
diagnostic. The runtime allocates the table at a stable address until the
library's last registration, producer and ingress lease physically retires;
the library may retain that pointer only for that interval.

The handle representation is an unsigned 64-bit ID, never a cast Gene pointer.
ID zero is invalid. Each call also carries `runtime_context`, so lookup checks
the owning Application/domain before touching Gene memory. IDs are monotonic
and never reused during a domain lifetime. Releasing a handle removes its
registry entry; a stale ID fails even when the native library still stores the
number. Domain close rejects new admission and waits for physical callback,
Task and ingress owners before destroying the registry.

## Minimal v6 operations

These C declarations fix the prefix and common output conventions; the
implementation's header must use these widths and field order. Status values
are `0=ok`, `1=error`, `2=panic`, `3=cancelled`, `4=pending`. A null diagnostic
descriptor is allowed; when supplied, `required` is always set and bytes
beyond `capacity` are never written. Strings and names are UTF-8 byte spans,
never NUL-dependent.

The first wire kind values are `0=nil`, `1=Bool`, `2=Int`, `3=Str`, `4=Bytes`,
`5=List`, `6=Map`, `7=Node`, `8=callable`, `9=Task`, `10=Channel`,
`11=ActorRef`, `255=other`; they are not Nim `ValueKind` ordinals.

```c
#include <stddef.h>
#include <stdint.h>

typedef uint64_t GeneHandleV6;       /* 0 is invalid */
typedef uint64_t GeneRegistrationV6; /* distinct ID space from handles */
typedef struct {
  uint8_t *data;
  size_t capacity;
  size_t required;
} GeneOutBytesV6;
typedef struct {
  const uint8_t *name;
  size_t name_len;
  GeneHandleV6 value;          /* callback-scoped unless retained */
} GeneNamedArgV6;
struct GeneApiV6;
typedef uint32_t (*GeneNativeCallbackV6)(
  const struct GeneApiV6 *api, void *user_context,
  const GeneHandleV6 *args, size_t arg_count,
  const GeneNamedArgV6 *named, size_t named_count,
  GeneHandleV6 environment,
  GeneHandleV6 *out_value, GeneHandleV6 *out_error,
  GeneOutBytesV6 *diagnostic);
typedef void (*GeneContextRetireV6)(void *user_context);
typedef struct GeneApiV6 {
  uint32_t version;
  uint32_t struct_size;
  uint64_t feature_bits;
  void *runtime_context;
  uint32_t (*attach_thread)(void *, uint64_t *, GeneOutBytesV6 *);
  uint32_t (*detach_thread)(void *, uint64_t, GeneOutBytesV6 *);
  uint32_t (*retain)(void *, GeneHandleV6, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*release)(void *, GeneHandleV6, GeneOutBytesV6 *);
  uint32_t (*kind)(void *, GeneHandleV6, uint32_t *, GeneOutBytesV6 *);
  uint32_t (*copy_bool)(void *, GeneHandleV6, uint8_t *, GeneOutBytesV6 *);
  uint32_t (*copy_i64)(void *, GeneHandleV6, int64_t *, GeneOutBytesV6 *);
  uint32_t (*copy_text)(void *, GeneHandleV6, GeneOutBytesV6 *, GeneOutBytesV6 *);
  uint32_t (*copy_bytes)(void *, GeneHandleV6, GeneOutBytesV6 *, GeneOutBytesV6 *);
  uint32_t (*new_bool)(void *, uint8_t, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*new_i64)(void *, int64_t, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*new_text)(void *, const uint8_t *, size_t,
                       GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*new_bytes)(void *, const uint8_t *, size_t,
                        GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*length)(void *, GeneHandleV6, uint32_t, size_t *, GeneOutBytesV6 *);
  uint32_t (*copy_key)(void *, GeneHandleV6, uint32_t, size_t,
                       GeneOutBytesV6 *, GeneOutBytesV6 *);
  uint32_t (*traverse)(void *, GeneHandleV6, uint32_t, size_t,
                       GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*call)(void *, GeneHandleV6, const GeneHandleV6 *, size_t,
                   GeneHandleV6, GeneHandleV6 *, GeneHandleV6 *,
                   GeneOutBytesV6 *);
  uint32_t (*define)(void *, GeneHandleV6, const uint8_t *, size_t,
                     GeneHandleV6, GeneHandleV6 *, GeneOutBytesV6 *);
  uint32_t (*register_callback)(void *, GeneHandleV6, const uint8_t *, size_t,
      GeneNativeCallbackV6, void *, GeneContextRetireV6,
      GeneHandleV6 *, GeneRegistrationV6 *, GeneOutBytesV6 *);
  uint32_t (*request_close)(void *, GeneRegistrationV6, GeneOutBytesV6 *);
  uint32_t (*wait_closed)(void *, GeneRegistrationV6, GeneHandleV6 *,
                          GeneOutBytesV6 *); /* owned Task handle */
} GeneApiV6;
typedef uint32_t (*GeneModuleInitV6)(const GeneApiV6 *, GeneHandleV6,
                                      GeneOutBytesV6 *);
```

`length`, `copy_key` and `traverse` use selectors `0=List item`, `1=Map
entry`, `2=Node body`, `3=Node prop`, `4=Node head`. `copy_key` applies only to
Map entry and Node prop. The index selects an element after a copied length
check; Node head has length one. `traverse` returns Map/Node property values,
while `copy_key` copies their keys. All traversed containers must be deeply
frozen; an unfrozen container returns a typed error instead of a pointer.
Task producer and byte-ingress function pointers are appended after the prefix
above under separate feature bits; callers must check `struct_size` before
reading them. The initial implementation must publish the exact selector and
feature constants in its C header before enabling those entries.

The first table version has the following operation families. Each returns a
small status code; `GeneStatus` categories remain distinct (`ok`, error, panic,
cancelled). A failed operation writes a copied diagnostic into a caller buffer
and reports the required length if it does not fit. No returned pointer into
Gene memory survives a call.

| Family | Inputs and result | Lane and lifetime |
| --- | --- | --- |
| `retain`, `release` | Runtime context and ID; retain returns a new owning ID. | Any attached lane. Release removes the last owner outside registry locks. |
| `kind`, scalar reads | ID; copied Bool/Int64 or required byte count plus copy for text/Bytes. | A structured attached-lane borrow for the call extent. |
| Scalar constructors | Copied Bool/Int64/UTF-8 text/Bytes; return owning ID. | Root lane for the first ABI 6 implementation. |
| Frozen traversal | ID and index/key; returns a new owning ID. | Only deep-frozen List/Map/Node values; no raw container pointer. |
| `call` | Callable ID, owning argument IDs, environment ID; returns owned value or typed error ID. | Root lane; callback runs under owner-dependent admission. |
| `define` | Environment ID, copied name bytes, value ID; returns an owned binding ID. | Root lane; the Scope owns the binding independently. |
| `new_task`, `complete`, `fail`, `cancel`, `retire` | Opaque Task producer ticket and payload/error IDs. | Physical producer owner survives user cancellation until completion/retire. Typed foreign errors require a root-lane dispatch adapter before enabled. |
| `register_callback`, `request_close`, `wait_closed` | C callback/context, environment ID, registration token. | Runtime owns the context and library lease through unregister confirmation, zero in-flight calls and result settlement. |

The table's `struct_size` permits appending new function pointers in a later
minor feature level, but a caller may only use an entry after checking both
size and feature bit. ABI 6 never appends to the v4 or v5 structs. Initial
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

## Byte ingress and compatibility

The v5 byte ingress interface remains a byte-only queue and still uses its
legacy raw-root publication contract. ABI 6 can attach that queue to a v6
registered handler by storing an owning handler ID and environment ID in the
subscription. C `begin/enqueue/end` remains byte-only: it never receives a
Gene handle, allocates a Gene value, or calls a Gene callback on the producer
thread. The root lane converts bytes to a Gene Bytes value and invokes the
registered handler. Subscription close preserves the existing two retirement
proofs: no future C callback can begin and current in-flight entries are zero.
The handler/environment IDs and library lease release only after those proofs
and the active Gene handler Task settle. A v5 subscription is never silently
upgraded to this ownership contract.

The v6 loader may reuse the existing package metadata ABI field and
`geneLoadModuleVersioned` dispatch. It must not introduce Gene syntax. The
`gene/` versus `genex/` library placement remains as specified by the
extension's actual use, not by this ABI.

## Implementation slices and gates

1. Add the isolated v6 table and exact loader branch with a C fixture that
   checks layout/version/feature negotiation. Keep v4/v5 fixture outputs
   unchanged. Establish domain/context ownership before loading a module.
2. Back IDs with the existing managed-domain registry; implement retain,
   release, copied scalar/Bytes reads, frozen traversal, call and define. A
   fixture must prove stale, wrong-domain, wrong-lane and close rejection
   without exposing raw Gene bits.
3. Add callback registration and copied arguments/results. Test nested call,
   typed error/panic/cancel propagation, close during callback, context cleanup
   re-entry and library unload refusal until physical retirement.
4. Connect v6 handler IDs to byte ingress. Test foreign enqueue while close
   races, queued overflow, handler suspension/cancellation, unregister delay,
   late valid callbacks, zero in-flight release and 1/100/1,000/10,000 cycles.
5. Qualify normal AtomicArc, opt-in collector, ASAN, supported TSAN, default
   ORC and installed-app packages. Keep AAR-2/shared reclamation disabled until
   both the managed SDK and installed extension exposure inventory is complete.

The v6 table is an additive migration path. Installed v4/v5 libraries and
direct Nim code continue to require permanent publication where they can keep
raw references. A successful v6 fixture does not remove that exclusion.
