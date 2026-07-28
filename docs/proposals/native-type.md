# Native-backed types: managed wrappers and typed-native pointers

Gene needs two representations at two different execution layers:

- **managed wrappers** are ordinary dynamic Gene values and remain the default;
- **typed-native pointers** are unboxed machine values inside compiled typed
  regions and cross into dynamic Gene only through an explicit wrapper adapter.

This is not a choice between two dynamic `Value` encodings. The allocation-free
path belongs in native code generation, where exact representations are already
known.

---

# Part I — Current managed wrappers

**Status (2026-07-28): §4 items 1, 2, 4, and 5 are implemented; item 3 is
implemented except its `^mut` opt-in (see below); item 6 is answered and
closed.** `^repr native_wrapper` marks the Type, every non-ctor construction
path rejects a marked head, declared fields are initializer-only, a failed ctor
releases the owned pointers it installed (props *and* body), and `newWrapper`
requires a marked Type and validates the declared schema. The shipped
surfaces — `SqliteDb`, `PostgresDb`, `SqliteStore`, `FsStore`, and the
terminal/curses/repl sessions — declare real schemas and are built through that
same factory, so no in-tree type is exempt from the invariant.

**Item 6 is answered: no.** The `vm.native_wrapper.*` benchmarks decompose the
shipped shape one factor at a time (2026-07-28, release): the `CPtrData` is
~50 ns, node + prop table + an `Any` field check ~615 ns, and the same factory
call with a `(C/OwnedPtr T)` handle field ~3.13 µs. Those last two differ only
in the declared field type, so the compound C-pointer boundary check — not the
allocations a compact object would merge — is ~2.5 µs of the cost. Compact
storage would attack the ~565 ns term instead. Revisit only if the compound
C-type check gets cheaper; the useful optimization lives there, not in a new
representation.

**Item 3's `^mut` opt-in is deliberately not implemented.** The write policy
itself is in place — declared fields are initializer-only — but `^mut` must
arrive as the ordinary all-types field-write policy, and adding it for wrappers
alone would be exactly the second wrapper-specific mutability mechanism item 3
forbids. Until it lands, wrapper metadata that must change after construction
holds a `Cell`, as the in-tree session types do.

The sections below describe the state that motivated the work; §16.6 of
`docs/design.md` is the current contract.

## 1. Representation

The shipped pattern is an ordinary Gene node whose head is a `Type` and whose
hidden props contain native state:

```gene
(import $db/sqlite [open Db])
(var c (open ":memory:"))

c          ; ((type SqliteDb) ^handle (c_owned_ptr) ^backend "sqlite" ...)
($head c)  ; (type SqliteDb)
c/path     ; ":memory:"
(c ~ Db:exec "select 1")
```

The native-extension interface exposes:

- `defineWrapperType` — creates an empty-schema nominal Type;
- `newWrapper` — creates a Type-headed node with native-owned props;
- `wrapperField` — reads a hidden prop for native code.

The empty Gene schema is intentional. Direct construction and `set_prop!`
cannot supply or replace `handle`, while native code can populate it through
`newWrapper`. Dispatch, annotations, selectors, protocols, and user impls use
the ordinary node machinery.

## 2. Lifecycle and cost

The node owns a `c_owned_ptr`. Explicit `close` is deterministic; the pointer's
release callback on reclamation is only a fallback. Native entry points check
receiver identity, pointer kind, null, and closed state before use.

The present shape normally involves a wrapper node, a prop table, and a
`CPtrData` object. That buys runtime Type identity, Gene-side metadata, GC
tracing, shared closed state across aliases, and fallback release. For database
and network calls this allocation cost may be irrelevant; it must be measured
rather than assumed important.

## 3. Status and remaining weaknesses

### 3.1 Exact Type identity — complete

Since `c43fda7`, `wrapperField` and the in-tree database guards compare exact
Type values rather than names. Two modules may safely define Types with the
same name; a cross-module regression test covers this case.

### 3.2 Empty-schema Types remain directly constructible

Gene code can create `(SqliteDb)` with no handle. It cannot forge a pointer, so
the native guard remains safe, but the value passes a `SqliteDb` nominal
boundary and fails only at its first database operation.

Adding an ordinary `ctor` does not fix this: `(T ...)` intentionally remains
direct data construction even when `T` has a ctor. A ctor becomes the right
creation interface only after the wrapper marker makes every other construction
path reject the Type.

### 3.3 Wrapper status is not represented on Type

`defineWrapperType` creates an ordinary empty-schema Type, and `newWrapper`
accepts any empty-schema Type. The VM cannot distinguish a deliberate native
wrapper from an ordinary fieldless Gene type.

## 4. Improvements to managed wrappers

The low-friction design is a normal Gene Type and ctor around small typed FFI
functions. A library binding should not need a native function that manually
assembles every wrapper node:

```gene
(ffi/fn pq_connect_db
  ^library libpq
  ^symbol "PQconnectdb"
  ^release "PQfinish"
  [conninfo : C/CStr] : (C/OwnedPtr PGconn))

(type PgConn
  ^repr native_wrapper
  ^props {
    ^handle   (C/OwnedPtr PGconn)
    ^conninfo Str
  }

  (ctor [conninfo : Str]
    (set! self/handle (pq_connect_db conninfo))
    (set! self/conninfo conninfo)))

(var db (new PgConn "postgresql://localhost/app"))
```

The ordinary ctor is a good fit once wrapper fields are initializer-only: it
already pre-creates `self`, supports inheritance, runs Gene code, and validates
the completed instance. The native layer only exposes typed primitive
operations such as open, close, exec, and query. Gene code supplies the nominal
Type, constructor, messages, protocols, and friendly errors. The declared
schema supplies validation; restricting later writes preserves the
unforgeability previously obtained from an empty schema.

Required changes, independent of typed-native compilation:

1. **Add a Type representation marker.** `^repr native_wrapper` marks the Type;
   `defineWrapperType` creates the same representation for fully native modules.
2. **Reject non-ctor construction.** `(T ...)`, `construct_type`, `assoc_in`,
   `update_in`, head replacement, and other reconstruction paths reject a
   `native_wrapper` head. Inherit this rule through `^is`, allowing Gene-side
   subtypes and messages without reopening construction.
3. **Use the ordinary field-write policy.** Declared props are read-only after
   construction unless marked `^mut`; this is not a second wrapper-specific
   mutability mechanism. During the existing constructing state,
   `set! self/field` validates and initializes them. Metadata may opt into
   `^mut`, but native handle fields must not.
4. **Use the ordinary schema as the invariant.** Ctor completion requires every
   declared field and validates types, including the exact `C/OwnedPtr` target.
   If construction raises, unwind the in-progress instance and deterministically
   release every initialized owned field before propagating the error; do not
   wait for reclamation.
5. **Keep `newWrapper` as the low-level factory.** It requires a
   `native_wrapper` Type and validates the same declared schema, for extensions
   that cannot or do not want to express construction in Gene. It is no longer
   justified by an empty-schema convention.
6. **Prototype compact storage.** A dedicated managed wrapper object could
   carry Type identity, native payload, close state, and fixed native fields in
   one allocation while presenting the same `$head`/selector/dispatch
   interface. This uses the generic object representation, not a new immediate
   tag. Benchmark it first: it adds VM representation cases and may not matter
   for calls dominated by foreign work.

This makes wrapping libcurl, SQLite, PostgreSQL, and similar libraries mostly a
typed FFI declaration plus an ordinary Gene Type. Managed-wrapper equality
remains its shipped structural-node behavior in this proposal. Changing it to
identity semantics would be a separate behavior change and needs its own
justification and tests.

---

# Part II — Unboxed pointers in `typed_native`

**Status (2026-07-28): the §10 measurement gate is met; the §6.4 dynamic
boundary is blocked on work this proposal does not own.**

The C backend lowers native-pointer parameters, locals, scalar and
pointer-valued field loads and stores, direct typed calls, and statically
resolved qualified protocol sends. Measured in release on the emitted C, not
on a hand-written analogue:

| path | ns/op |
|---|---|
| generated C field load | 0.51 |
| inlined Nim ceiling | 0.57 |
| dynamic wrapper getter | 245 |

The emitted path matches the hand-written ceiling and is ~480x the dynamic
wrapper, so §10's "one-load path" question is answered yes and §11 items 1-4
are done.

§11 item 5 (wrapper borrow/transfer adapters) cannot be finished here. The
generated C declares 59 `gene_ffi_*` / `gene_typed_native_*` helpers and the
runtime defines none of them: production AOT backends are deferred
(`docs/implementation-status.md`), and the native C ABI those helpers need —
opaque `GeneValue`, root handles, native registration, the VM trampoline — is
step 12 of design.md's implementation order, which precedes native
compilation. Self-contained typed-native functions compile and run standalone
today; anything crossing the dynamic boundary, including every
`^native_entry` adapter, will not link until that ABI exists. The adapters are
specified and code-generated, and are covered by tests against a mock harness.

## 5. Goal and scope

The goal is one-load foreign field access and direct native calls inside code
whose representations are fixed by compilation. The existing experimental C
backend already emits unboxed fixed-width functions and direct typed calls:

```text
gene compile --target c module.gene
```

Extend that backend so a parameter such as `t : Timespec` is a C pointer in a
register, not a `GeneValue`. Do not add another NaN-box tag. The immediate tag
space is already occupied, and a tag would solve a dynamic-value problem that
compiled typed regions do not have.

Call this capability `typed_native`. It is experimental until the C backend can
compile a representative pointer-and-struct example end to end.

## 6. Four required capabilities

### 6.1 Unboxed foreign pointers

Within an eligible compiled function, a native-backed parameter, local, or
return value uses its ABI machine representation, normally `void*` or a typed C
pointer. The compiler has the exact Gene Type and emits no `Value`, node,
pointer box, tag, witness slot, or dynamic dispatch lookup.

An unboxed typed-native function is eligible only when every operation can be
lowered statically. A protocol send therefore requires a known concrete
receiver and visible impl. Otherwise compilation of that typed-native path
fails; the author must use the explicit box adapter in §6.4 or keep the whole
path in ordinary dynamic Gene. The compiler never inserts a wrapper allocation
for an unresolved send.

### 6.2 Compile-time layout attachment

Illustrative source shape:

```gene
(ffi/struct CTimespec
  ^fields [[tv_sec C/Long] [tv_nsec C/Long]])

(type Timespec
  ^native {^abi CTimespec ^lifecycle manual ^mutable true})
```

`Timespec` remains the nominal Gene Type. Its typed-native representation is a
pointer to the resolved `CTimespec` layout.

### 6.3 Direct fields and calls

Inside a compiled typed region:

```gene
(fn seconds [t : Timespec] : I64
  t/tv_sec)
```

lowers to a null policy check if required and one C field/offset load. Writable
fields similarly lower to an ABI-checked store. A typed FFI/native call lowers
directly without `GeneCall`, argument boxing, or runtime message resolution.

Native fields are not Gene props. `set_prop!`, node construction, serde, and
schema derivation do not address foreign memory.

### 6.4 Explicit dynamic boxing

A raw typed-native pointer cannot enter interpreted code, `Any`, an untyped
function, a general Gene collection, reflection, pattern matching, or a channel
as an unboxed value. Crossing that seam explicitly creates or consumes the
managed wrapper from Part I:

```text
typed native pointer
→ explicit box/ownership transfer
→ managed wrapper GeneValue
→ bytecode or dynamic Gene
```

The reverse adapter validates the exact wrapper Type, liveness, and ABI layout,
then borrows or transfers the pointer into the compiled call. Boxing is the only
place the wrapper allocation appears; it is never an implicit optimization or
silent representation change.

This uses the mixed-execution model already specified in `design.md` §16.14.
It does not add Type witnesses to every VM call frame, inline cache,
`NamedArgs`, or container element.

## 7. Layout resolution is the main compiler change

Today `compileFfiStruct` stores an `FfiStructProto` in the declaring chunk's
compile-time `ffiStructs` table, then binds the source name to a plain symbol.
The binding does not lead back to the layout, and another module cannot import
the metadata needed to lower a field access.

The implementation must therefore define a real compile-time interface:

1. give each `ffi/struct` layout a stable module-qualified identity;
2. resolve `^abi CTimespec` while compiling the Type declaration;
3. attach the resolved layout descriptor to the Type's compile metadata;
4. export/import that metadata with the nominal Type;
5. record layout dependencies in compiled-module invalidation data;
6. lower static field names to verified offsets and ABI conversions.

Runtime expression lookup remains unchanged. Layout names are resolved in the
compiler's static metadata context, not evaluated as values and not looked up
through a fourth ad hoc runtime namespace.

The initial field subset should be fixed-width scalars and pointers already
supported by the generated FFI adapters. Nested records, unions, arrays,
bitfields, and by-value aggregate calls remain deferred.

## 8. Nullability and reflection

Inside a compiled typed region, `Timespec?` may use a nullable pointer
representation. It is not a dynamic `(| Timespec Nil)` value while unboxed.
At an explicit dynamic boundary, null becomes `nil` and a non-null pointer
becomes the managed wrapper, producing the ordinary Gene union there.

Runtime projections such as `$head`, `$props`, and `$meta` operate on dynamic
Gene values, so they require boxing. The compiler need not invent runtime node
projections for an unboxed register; it may constant-fold type reflection only
when that is separately specified and observable behavior remains identical.

## 9. Manual lifecycle

Native compilation does not make manual pointers safe. Within a typed-native
region:

- free exactly once;
- do not use any alias afterward;
- keep owners alive longer than borrowed pointers;
- keep the native library loaded while its pointers or callbacks are used;
- do not cross threads unless the foreign interface guarantees safety.

Use-after-free, double-free, and dangling borrows remain native memory errors.
No `closed?` guarantee exists without a managed wrapper or foreign-library
support.

Boxing must state ownership explicitly:

- **borrow** — the wrapper or typed caller remains owner for the call's extent;
- **transfer** — the new managed wrapper becomes the sole release owner;
- **copy** — only when the native Type defines a real copy operation.

Null maps to `nil`; it is never boxed as a non-null native instance.

## 10. Prototype and measurement gate

Before scheduling the full design, extend the C-backend prototype just enough
to compile one layout and one getter:

```gene
(fn seconds [t : Timespec] : I64 t/tv_sec)
```

Measure:

- interpreted wrapper + native getter in a tight loop;
- typed-native compiled field access in the same loop;
- wrapper creation/boxing separately;
- a realistic SQLite/libcurl call to confirm whether foreign work dominates.

Inspect generated C or machine code to verify the typed path is a direct load,
not a runtime helper, and test that an unresolved protocol send is rejected
rather than boxed implicitly. If the field-access loop does not show a
meaningful win, defer the feature or narrow it to code-generation use cases
that do.

The current backend handles fixed scalar expressions and direct calls; pointer
parameters, layout-bearing Types, field loads, and dynamic box adapters are new
work. The prototype determines whether this is an extension of a viable
backend or still primarily backend construction.

## 11. Implementation order after the gate

1. Export/import stable `ffi/struct` layout metadata.
2. Attach a resolved ABI layout to nominal Type compile metadata.
3. Add unboxed pointer parameters/results to typed-native C signatures.
4. Lower scalar native-field reads and direct native calls.
5. Add explicit wrapper borrow/transfer adapters at dynamic boundaries.
6. Add opt-in writes, nullable pointers, and selected specialization.
7. Expand layout coverage only with tests and benchmark evidence.

---

# Side-by-side comparison

| Property | Managed wrapper | `typed_native` pointer |
|---|---|---|
| Execution layer | Dynamic/bytecode Gene | Compiled typed region |
| Representation | Gene node + native handle | C pointer/register |
| Runtime Type identity | Stored in wrapper head | Known by compiler |
| Dynamic Gene features | Fully available | Require explicit boxing |
| Dispatch | Existing Type-keyed runtime dispatch | Direct when statically resolved |
| Foreign fields | Native getter or wrapper props | Direct compiled load/store |
| Native calls | Dynamic/native-call interface | Direct typed ABI call |
| Lifecycle | Explicit close + fallback reclamation | Manual while unboxed |
| Alias invalidation | Shared closed pointer state | No detection; aliases dangle |
| Null | Checked managed pointer or `nil` | Nullable register; `nil` when boxed |
| Reflection | Ordinary `$head`/props/body/meta | Box first |
| Crossing `Any` | Natural | Explicit wrapper box |
| Current status | Shipped | Experimental C backend extension |
| Main implementation risk | Wrapper invariants and compact storage | Cross-module layout metadata/codegen |
| Best fit | General libraries and dynamic Gene | Tight typed FFI/struct code |

## Recommendation

Harden managed wrappers first with the Type marker and construction rule in
§4. In parallel, run the narrow typed-native field-access prototype and
benchmark gate in §10. Proceed with the larger layout/codegen work only if that
prototype demonstrates the intended one-load path and a useful performance
win. Do not spend dynamic `Value` tag space or widen VM calling conventions for
an optimization whose natural seam is compiled typed code.
