# Native-backed types: managed wrappers and typed-native pointers

Gene needs two representations at two different execution layers:

- **managed wrappers** are ordinary dynamic Gene values and remain the default;
- **typed-native pointers** are unboxed machine values inside compiled typed
  regions and cross into dynamic Gene only through an explicit wrapper adapter.

This is not a choice between two dynamic `Value` encodings. The allocation-free
path belongs in native code generation, where exact representations are already
known.

Here **typed-native** names a compiler representation/backend only. It is not a
system-library requirement (`package-build.md` §8), a generic native build
artifact, or the `mixed` application-image mode in `distribution.md`; those
modules consume this backend only when their own contracts explicitly say so.

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

The empty Gene schema is intentional. Direct construction and `set_prop`
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
    (set self/handle (pq_connect_db conninfo))
    (set self/conninfo conninfo)))

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
   `set self/field` validates and initializes them. Metadata may opt into
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

**Status (2026-07-29): the §10 measurement gate is met and the §6.4 dynamic
boundary is implemented, including ABI validation and the epoch guard that keeps
it true after a reload. See §6.4's two dated subsections.**

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

§11 item 5 (wrapper borrow/transfer adapters) is now implemented. The generated
C never dereferences `GeneValue`, `GeneCall`, or `GeneContext` — it only passes
them to helpers — so no public C value ABI was required after all;
`src/gene/aot_runtime.nim` owns those shapes and exports the helpers, and
`aot/load` binds a compiled library's `^native_entry` functions as ordinary
callables:

```gene
(import $aot [load])
(var native (load "libpoint.dylib"))
(var p (native/make))     ; native code allocated it; a managed Point comes back
(native/get_x p)          ; direct field load in compiled C
```

A `^native` type records the identity its compiled code was built against
(`TypeData.nativeIdentity`), and the boundary recovers the `Type` from that
identity instead of trusting the incoming value's head, so a look-alike cannot
carry a forged handle into compiled code. Ownership follows the declared mode:
borrow leaves the wrapper usable, transfer *relinquishes* it (closed without
running the release callback, which would free memory the callee is about to
use), and copy leaves the original intact.

### Overlay scope for direct protocol sends (decided 2026-07-28)

`docs/scoped-impls.md` §7 allows a direct protocol call only when the winning
unconditional canonical pair is known and no overlay is reachable, guarded by
the activation epoch in a runtime with loading/reload, and lets closed-world
AOT omit that guard.

**The typed-native backend is not declared closed-world.** Its overlay check is
module-local: a send does not lower if any overlay-only impl anywhere in the
compiling module declares that message, in any position and in any order. A
cross-module overlay installed after compilation is *not* detected — compiled
code keeps calling the canonical impl where interpreted code would dispatch to
the overlay.

That gap is accepted for now rather than closed. Declaring the path
closed-world was rejected: it would make the divergence permanent and silent,
which is the failure mode this backend has already paid for twice (a `"0"`
emitter fallback, and bare sends resolving to protocol impls). The epoch guard
is the intended answer, deferred because it needs a boxed dynamic fallback per
specialized send and only earns that cost once the backend leaves experimental
status. Until then the limitation is: do not install a cross-module overlay
over a type whose module has been AOT-compiled.

### Build integration deferred (decided 2026-07-28)

There is no `gene build` producing a linked artifact; `examples/native` drives
`cc` from a shell script. That is deliberate and waits on package and
dependency support.

**Update:** the package prototype models Gene dependencies only — there is
still no declaration for a native library, its
headers, or its link metadata, which is exactly the graph this deferral named.
`package-build.md` now separates two deliverables: its Phase 0
`system_library` resolver removes hardcoded native discovery from the existing
experimental harness, while its Phases 1-3 produce managed, linked `gene build`
artifacts. Phase 0 unblocks package-aware experimentation; Phase 3 completes
the build integration deferred here.

A build command's whole job is deciding what to compile and what to link
against, and both answers come from the dependency graph — which libraries a
module needs, where their headers and archives live, and what the compiled
output may assume is already present. Building it against today's flat model
would bake in an answer that package support would immediately invalidate, and
the shell script is a perfectly honest stand-in until then.

The lowerable subset now covers field access, locals, direct/FFI/protocol
calls, arithmetic, comparisons, `if`, `while`, and block statements.

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

Native fields are not Gene props. `set_prop`, node construction, serde, and
schema derivation do not address foreign memory.

### 6.3.1 Out-parameters

C routinely returns values through a pointer parameter — `sqlite3_open` fills a
`sqlite3**`, `sqlite3_prepare_v2` fills a `sqlite3_stmt**`. Typed-native Gene
has no way to take the address of a local, so these signatures were unreachable
and had to be wrapped by hand in C.

`^out` marks which parameters are out-parameters. It is metadata only: the
parameter keeps its ordinary *value* type, and the marker is what makes the
emitted declaration take one more indirection and the call site pass an
address.

```gene
(ffi/fn sqlite3_open
  ^library libsqlite3
  ^symbol "sqlite3_open"
  ^out db
  [filename : C/CStr db : Db?] : C/Int)

(fn open_memory [] : Db?
  (var db : Db? nil)
  (let rc : I64 (sqlite3_open ":memory:" db))
  (if (= rc 0) db nil))
```

```c
extern int GENE_FFI_CDECL sqlite3_open(const char *filename, CDb **db);

CDb *gene_native_open_memory(void) {
  CDb *db = NULL;
  int64_t rc = sqlite3_open(":memory:", &db);
  return ((rc == 0) ? db : NULL);
}
```

The return type stays the real C return, so status handling stays in the
caller's hands rather than being folded into the declaration. Several
out-parameters need no special treatment — `^out [stmt tail]` marks two and
passes two addresses — because nothing is ever returned as a product. That
matters: a typed-native call yields exactly one machine value, and `(Tuple A B)`
is a boxed Gene list, so any design that returned the outs together would not
lower.

Constraints:

- An argument in an `^out` position must be a **mutable local**. Not a
  temporary, which has no address, and not a parameter, since writing through
  one would not be visible to the Gene caller. The address is therefore formed
  at the call and dies with it, which is what makes this safe where a general
  address-of operator would need escape analysis.
- Every name in `^out` must appear in the parameter list, so the declaration
  still describes the real C signature.
- The callee owns what it writes: an out-parameter is not an ownership
  transfer, and §9's borrow/transfer/copy rules apply to the value afterwards
  exactly as they would to any other pointer.

Deferred: calling an `^out` function from *dynamic* Gene. The generated
`gene_ffi_*` wrapper has no incoming value for an out slot and nowhere obvious
to surface the result — that is where returning a tuple would come back. Until
that is designed, `^out` functions are typed-native only and the dynamic
wrapper reports the call as unsupported rather than guessing.

### 6.3.2 Strings as a boundary representation

`Str` resolves to `const char *`, borrowed for the call's extent. Like `I32`
it crosses edges — parameter, local, FFI argument — and is never computed
with; the subset has no string operations, and any that arrive later belong in
dynamic Gene where a `Str` is a real value.

```gene
(fn open_db [path : Str] : Db?
  (var db : Db? nil)
  (let rc : I64 (sqlite3_open path db))
  (if (= rc 0) db nil))
```

Lifetime is the whole design constraint. A `Str` argument owns the storage the
pointer refers to and outlives the call, so the borrow is valid throughout and
foreign code must not retain it — the same rule `gene_ffi_arg_cstr` already
applies at the dynamic boundary, which borrows from the argument's own storage
rather than a temporary. String *literals* are safer still: they have static
lifetime, so `(sqlite3_open ":memory:" db)` is always valid.

Literal arguments in general became lowerable with this: an FFI argument used
to have to be a binding, so neither `":memory:"` nor a plain `1` could be
passed. An integer literal takes the narrowest representation that holds it, so
it satisfies a C `int` parameter as readily as a 64-bit one, and `nil` takes
its representation from the parameter it fills.

Together with §6.3.1 this retired the hand-written C shim in
`examples/native`: `sqlite3_open`, `sqlite3_exec`, `sqlite3_prepare_v2` and
`sqlite3_close` are now bound directly, and acquisition happens in Gene.

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

### ABI validation (implemented 2026-07-29)

Type identity implies the ABI within one build, not across one, so the layout
check above needs a fingerprint rather than a name comparison. Two are computed:
a **layout fingerprint** over the declared descriptor, and a **contract
fingerprint** over the complete code-generation contract, nesting the first.

The contract is wider than the layout because compiled code bakes in more than
offsets: `^copy` and `^release` become call targets, `^wrapper` becomes a string
literal at every boundary helper, `^mutable` decides whether a field store
lowers at all, and the handle's declared type decides what an ownership transfer
means. A library compiled against `^copy old_copy` would otherwise keep applying
it after the type was re-registered with `^copy new_copy` — same ABI, same
layout, no signal.

Both are shallow: a pointer field contributes an identity string rather than its
pointee's fingerprint, since `CNode.next : Node` is self-referential and a
transitive hash would not terminate. Completeness comes instead from the
manifest being transitively complete.

A compiled library therefore exports `gene_aot_native_types`, one row per native
type its code depends on — **transitively**, not merely those crossing the
boundary. That distinction is load-bearing: code that takes a `Parent` and reads
`parent/child/value` presents only `Parent` at the boundary while holding
`Node`'s offsets, so a check driven by what crosses would never examine it. A
layout table alone could not express this contract at all, because the runtime
registry is keyed by *Type* identity and the claim needing proof is that the
live `Node` type still maps to the ABI the code was built against.

`aot/load` validates every row before binding anything, and the whole load is
transactional. A missing manifest means the library predates this checking and
is rejected rather than trusted.

Load-time validation is a snapshot, so a **native-type activation epoch** keeps
it true: it moves whenever a registered type's contract fingerprint changes —
never merely because recompiling minted a fresh `Type` object — and each loaded
library re-validates its full requirement set when the epoch has moved,
refusing the call before native code runs. This is the same mechanism the
dispatch cache uses, and the same activation-epoch guard §"Overlay scope for
direct protocol sends" names as the eventual answer there.

### Boundary contracts share the interpreter's converters (2026-07-29)

The generated adapters call the same conversion functions the VM's dynamic FFI
path calls, rather than a parallel implementation. The parallel one disagreed at
nearly every width — accepting an `Int` for a float parameter, dropping
`C/Float`'s range check, rejecting a `Char` for `C/Char` and returning an `Int`
for it, capping the 64-bit unsigned types, and turning a NULL `C/CStr` result
into `nil`. Divergence between compiled and interpreted code is the failure mode
this backend has already paid for repeatedly, so the property worth having is
that one implementation exists, not that two agree.

`C/Slice` and `Buffer` are separate: a slice borrows, while a Buffer marshals
into storage owned by the call and copies back after the callee runs, making a
`Buffer` parameter an out-parameter.

Pointer fields in an `ffi/struct` resolve their pointee **in the declaring
module** and record its nominal and ABI identities. Resolving the raw syntax at
each use site let an imported `Node? next` bind to whatever `Node` a consuming
module happened to declare — a silent miscompile that read a different layout,
and one C could not catch while such fields rendered as `void *`. They now
render as the real pointee type. A pointee naming an ordinary C type or an
opaque foreign tag resolves to neither identity, which is not an error.

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
