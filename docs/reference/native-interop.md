# Foreign and native interop

**Status:** detailed design reference and rationale. The implemented contracts
are [modules](../spec/modules.md), [authority](../spec/authority.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 16. Foreign function interface

FFI is a core architectural constraint, even if some convenience features are implemented after the first interpreter. It affects `Callable`, typed boundaries, memory ownership, garbage collection, modules, threading, and binary layout.

Gene defines three related interop layers:

1. a stable **native extension ABI** for functions and types implemented against the Gene runtime API;
2. a typed **C ABI binding layer** for calling external libraries;
3. higher-level wrappers and native modules that expose safe, idiomatic Gene APIs.

The C ABI is the first foreign target. C++, Rust, Nim, CUDA, and other systems integrate through C-compatible exports or through the native extension ABI.

### 16.1 Native functions

A native function is a first-class `NativeFn` value implementing `Callable`. Gene code calls it exactly like any other callable:

```gene
(strlen text)
(text .strlen)
```

The runtime-level native call shape is conceptually:

```text
NativeFn(Context, Call) -> Gene value or Error
```

A C-compatible entry point may use an ABI like:

```c
typedef struct GeneContext GeneContext;
typedef struct GeneCall GeneCall;
typedef struct GeneValue GeneValue;

typedef enum GeneStatus {
  GENE_OK,
  GENE_ERROR,
  GENE_PANIC
} GeneStatus;

typedef GeneStatus (*GeneNativeFn)(
  GeneContext *ctx,
  const GeneCall *call,
  GeneValue *result
);
```

`GeneCall` preserves positional arguments, named arguments, and call-site information. A native function validates or extracts arguments through the runtime API and writes either a result or an error.

The public ABI must not expose Nim object layouts, VM stack addresses, heap object layouts, or collector-specific pointers.

### 16.2 Typed C declarations

FFI declarations are compile-time declarations provided by the `ffi` module. They do not need to be core special forms.

```gene
(ffi/library libc
  ^linux "libc.so.6"
  ^macos "libSystem.B.dylib"
  ^windows "msvcrt.dll")

(ffi/fn strlen
  ^library libc
  ^symbol "strlen"
  ^abi C
  [s : C/CStr] : C/Size)
```

Usage is an ordinary call:

```gene
(var n : C/Size
  (strlen "hello"))
```

The compiler should generate a typed adapter whenever the declaration is statically known. Generated wrappers are the MVP mechanism: they are easier to validate, faster to call, and easier to debug than interpreting arbitrary ABI signatures at runtime.

Runtime signature construction through `libffi` or an equivalent library is optional post-MVP functionality.

An FFI declaration may specify a calling convention when the platform requires it:

```gene
(ffi/fn WindowProc
  ^library user32
  ^calling stdcall
  [...])
```

The default is the platform C calling convention.

### 16.3 Explicit ABI types

Gene types do not imply foreign binary layouts. `Int`, `Bool`, `Str`, and ordinary Gene records must not be used as if they were C types.

The FFI module provides explicit ABI types:

```gene
C/Int8     C/UInt8
C/Int16    C/UInt16
C/Int32    C/UInt32
C/Int64    C/UInt64
C/Float    C/Double
C/Char     C/UChar
C/Short    C/UShort
C/Int      C/UInt
C/Long     C/ULong
C/Size     C/PtrDiff
C/Bool     C/Void
C/CStr

(C/Ptr T)
(C/ConstPtr T)
(C/Array T n)
```

Fixed-width types should be preferred. Platform C aliases such as `C/Long` retain the target platform's ABI width.

Basic generics provide useful checking for pointer and container types:

```gene
(C/Ptr SDL_Window)
(C/ConstPtr C/Char)
(C/Slice C/Float)
```

The type argument describes the pointed-to value; it does not imply that the foreign memory is a normal Gene value.

### 16.4 Gradual typed boundaries and marshalling

Every FFI call is a typed boundary.

If an argument has type `Any`, Gene validates and marshals it according to the declared foreign parameter type before native code begins:

```gene
(strlen dynamic_value)
```

If `dynamic_value` cannot be converted to `C/CStr`, the runtime raises a recoverable boundary `TypeError`. Native code is not entered.

Automatic marshalling is limited to conversions with clear ownership and lifetime:

- checked numeric conversion, such as `Int` to `C/Int32`;
- `Bool` to the declared C boolean representation;
- `Str` to a temporary call-scoped `C/CStr`, rejecting strings with interior NUL unless the declaration explicitly uses a byte-slice form;
- typed `Buffer T` or `C/Slice T` to pointer-plus-length arguments;
- `nil` to a null pointer only when the declared parameter permits null.

Numeric conversion must check range. It must not silently truncate unless the declaration or call explicitly requests truncation.

A temporary C string or temporary marshalled buffer is valid only for the duration of the foreign call. A foreign function that retains a pointer requires an explicit owned, pinned, or copied value.

### 16.5 Pointers, buffers, and ownership

Raw foreign pointers are not ordinary Gene references.

The FFI foundation should provide:

```gene
(C/Ptr T)           # non-null raw pointer by default
(C/NullablePtr T)   # nullable raw pointer
(C/ConstPtr T)      # read-only non-null raw pointer
(C/NullableConstPtr T) # nullable read-only raw pointer
(C/OwnedPtr T)      # foreign pointer plus release operation
(C/Slice T)         # non-owning pointer and element count
(Buffer T)          # Gene-owned contiguous storage
```

A raw `C/Ptr` is non-owning. The programmer or wrapper is responsible for ensuring that its owner remains alive. Pointer arithmetic, arbitrary memory reads/writes, and unchecked casts belong to an explicitly unsafe FFI API, not normal selector or field access.

An owned result may declare its release function:

```gene
(ffi/fn SDL_CreateWindow
  ^library sdl
  ^symbol "SDL_CreateWindow"
  ^release SDL_DestroyWindow
  [...] : (C/OwnedPtr SDL_Window))
```

`C/OwnedPtr` should support deterministic cleanup through `close`. A finalizer may be a fallback, but finalization must not be the primary resource-management mechanism.

A foreign function returning borrowed memory should return `C/Ptr`, `C/ConstPtr`, or `C/Slice`, not `C/OwnedPtr`.

### 16.6 C structs and unions

C-layout records are declared explicitly:

```gene
(ffi/struct Timespec
  ^fields [
    [tv_sec  C/Long]
    [tv_nsec C/Long]
  ])
```

The compiler computes and verifies field offsets, alignment, size, and target ABI layout.

MVP restrictions:

- C layout only;
- no C++ object layout;
- no bitfields;
- no implicit packing;
- structs passed through pointers first;
- by-value struct arguments/results only after ABI conformance tests;
- unions, flexible array members, and variadic functions deferred.

A foreign struct value is not automatically a normal Gene node. Libraries wrap
it instead, using the pattern below.

#### Wrapper types: giving foreign data a Gene identity

A **wrapper type** is a nominal type marked `^repr native_wrapper` whose props
hold an opaque pointer. It is how every shipped native surface — `db/sqlite`,
`db/postgres`, `terminal/Session` — gives foreign data a Gene identity:

```gene
(var c (open ":memory:"))
c            # ((type SqliteDb) ^handle (c_owned_ptr) ^backend "sqlite" ...)
($head c)    # (type SqliteDb) — a real Type, so annotations and impls apply
c/backend    # "sqlite"
(c .Db:exec "create table t (a int)")
```

Because the value is just a node whose head is a `Type`, it needs no special
case anywhere: selectors, type-direct messages, protocol impls, nominal
ancestry, and annotations all work. Third-party code can implement its
own protocol for a library's native type without the library's cooperation
(§10.1).

**The marker is what makes the handle unforgeable, and it is load-bearing.**
A wrapper's declared fields are ordinary `^props`, but the representation
marker changes two things:

- **Only a `ctor` creates one.** Every other path that stamps the type onto a
  node rejects it: `(T ...)` direct construction, `construct_type`, serde,
  `assoc_in`/`update_in` reconstruction, head replacement, and a node literal
  with an unquoted Type head. Use `(new T ...)`. Without this, `(SqliteDb)`
  would produce a handle-less value that passes a `SqliteDb` annotation and
  fails only at its first query.
- **Declared fields are initializer-only.** `(set self/handle …)` works while
  the ctor's in-progress `self` is still constructing (§7.1.1) and is rejected
  afterwards, so `(c .set_prop ^handle "junk")` cannot make the next native
  call read a `Str` as a pointer. `set_body` and `push_body` are rejected on
  a completed wrapper for the same reason.

The rule is inherited through the nominal parent: a Gene-side subtype may add messages and
impls, but it does not reopen construction on the parent's native payload.

So a binding is an ordinary typed FFI declaration plus an ordinary Gene type:

```gene
(type PgConn
  ^repr native_wrapper
  ^props {^handle (C/OwnedPtr PGconn) ^conninfo Str}

  (ctor [conninfo : Str]
    (set self/handle (pq_connect_db conninfo))
    (set self/conninfo conninfo)))

(var db (new PgConn "postgresql://localhost/app"))
```

The declared schema supplies validation — ctor completion requires every
declared field and checks its type — while the write restriction supplies the
unforgeability an empty schema used to provide. If the ctor raises, the
in-progress instance is unwound and every owned pointer it already installed is
released immediately rather than waiting for reclamation.

Native extensions can also build wrappers directly, through three `GeneApi`
entries (`src/gene/native_api.nim`): `defineWrapperType` creates the marked
type with its declared schema and registers it in the module, `newWrapper`
instantiates one against that same schema for extensions that do not express
construction in Gene, and `wrapperField` reads a prop back under a nominal
check, so a look-alike node cannot reach a pointer dereference.

**Receiver admission is by Type identity, and it is ancestry, not equality.**
The check accepts the wrapper Type or a nominal descendant of it, comparing Type
*values* rather than names — two modules may each define a `Conn`, and a name
check would let one module's value carry its pointer into the other's native
code, or let a hand-written look-alike index into a session table it never
opened. Every in-tree surface admits receivers this way.

Two consequences follow from a wrapper being an opaque, write-closed value:

- **Deep `freeze` rejects it; `freeze_shallow` and `thaw` return it
  unchanged.** `freeze` is a promise about everything reachable, and a live
  handle cannot keep it — the `closed` cell and the pointer still change
  through the original — while rebuilding the node would be construction by
  another name. Shallow freeze promises only that the container's own
  head/props/body are fixed, which a completed wrapper already satisfies.
- **serde reopens rather than reconstructs.** `serde/write` refuses a wrapper
  instance outright; a wrapper that should survive a round trip defines the
  `serde_state`/`serde_restore` message pair (§7), which runs user code behind
  `^allow_restore` instead of rebuilding a handle from data. A blob can never
  forge one.

Two limits are part of the contract:

- **Selectors read the wrapper's props, never foreign memory.** `c/backend`
  projects the Gene node holding the pointer; nothing dereferences the C value.
  Projecting a C struct's fields would need a foreign-record storage module
  that owns reads, writes, and liveness — deferred, and deliberately not
  spelled as layout metadata on `type`, because an ordinary instance stores
  fields in props/body and every operation over it (construction, mutation,
  equality, printing, freeze, `Send`, serde) assumes that representation.
- **Release is explicit.** An owned pointer's destructor runs when the value
  becomes unreachable, which is a reclamation fallback, not resource
  management (§16.5). Wrapper APIs expose an explicit `close` and report
  `closed?`; using a closed handle raises rather than dereferencing.

### 16.7 Errors across the boundary

FFI distinguishes three failure classes:

1. **Gene-to-ABI boundary mismatch** — a dynamic/`Any` value that fails an FFI parameter's boundary check raises a **recoverable** `TypeError` *before* the foreign function is called, consistent with the `Any`→typed boundary rule (§9). A fully typed wrapper that violates its own declared ABI contract internally is a **panic**, not a recoverable error.
2. **Expected foreign failure** — the low-level binding returns its C result, status, or `errno`; an ordinary Gene wrapper translates it into a typed Gene error.
3. **Native crash or memory corruption** — process-level failure; Gene cannot promise recovery.

The low-level FFI does not guess whether null, `-1`, a status code, or `errno` means failure. That policy belongs in a wrapper:

```gene
(fn open_file [path : Str] : File
  ^errors [FsError]
  (var p (c_fopen path "rb"))
  (if ($nil? p)
    (fail (FsError ^path path ^errno (ffi/errno)))
    (File ^handle p)))
```

Only types implementing the `Error` marker protocol may appear in `^errors` or be raised through `fail`.

### 16.8 Rooting and garbage collection

Native code must not retain raw Gene heap pointers.

Values passed into a native call remain valid for that call. A native function that keeps a Gene value beyond the call must create a runtime-managed root:

```text
root = gene_root(ctx, value)
value = gene_root_get(root)
gene_root_release(root)
```

The exact C names are ABI details, but the semantic rules are mandatory:

- an unrooted Gene value must not be retained across calls or VM safepoints;
- an in-progress constructed instance cannot be rooted;
- native code must use runtime APIs to inspect and construct Gene values;
- native code must not retain interior pointers into movable objects;
- pinned byte/string storage must be explicitly requested and released;
- all roots owned by an extension must be released when no longer needed.

This keeps the extension ABI compatible with a future moving or generational collector.

### 16.9 Native extension modules

A compiled extension module exports one versioned initialization function:

```c
GeneStatus gene_module_init(
  const GeneApi *api,
  GeneModule *module
);
```

The runtime passes a versioned API table. The extension may register:

- native functions;
- constants;
- native opaque types;
- protocol implementations;
- destructors/finalizers;
- module initialization and shutdown hooks.

The API table should include an ABI version and feature-size information. New runtime versions may append functions without changing existing offsets. An incompatible major ABI version must fail module loading cleanly.

Native types should normally expose opaque handles. Their internals belong to the extension, while optional protocol implementations provide `Node`, `Callable`, `Closeable`, or domain-specific behavior.

The API table's `defineWrapperType` / `newWrapper` / `wrapperField` entries are
how an extension builds such a type; §16.6 describes the pattern and why the
`^repr native_wrapper` marker is load-bearing. They exist as validated entry
points precisely so an extension cannot construct a "wrapper" whose handle
Gene code could then forge or overwrite: `newWrapper` requires a marked type
and validates its declared schema.

### 16.10 Dynamic loading and active capability context

Runtime library loading requires `ffi/Load` permission in the active context:

```gene
(fn open_plugin [path : Str]
  ^capabilities [(ffi/Load path)]
  ($ffi/open path))
```

The returned library handle identifies that library and retains its origin
restriction. Binding a symbol and invoking a dynamic FFI callable check the
retained restriction together with the active context. Passing the handle
does not delegate permission.

Build/package native dependencies are part of the trusted build configuration;
recording one does not turn a runtime handle into a grant. Native libraries and
adapters remain trusted code after admission.

Additional raw-pointer permission categories are future design. They are not
implemented guarantees of native-code confinement; see the authority contract.

### 16.11 Callbacks and foreign threads

Callbacks are harder than outbound calls because they may escape and may arrive on foreign threads.

A callback type may be expressed as:

```gene
(C/Callback [C/Int32 (C/Ptr C/Void)] C/Int32)
```

MVP callback support should begin with synchronous, non-escaping callbacks invoked on the current attached VM thread.

Escaping callbacks require an explicit callback handle that roots the Gene closure and is deterministically released. A foreign thread must attach to the runtime or enqueue work onto a Gene scheduler before executing Gene code. It must not enter the VM using an arbitrary unmanaged thread.

Callbacks, foreign-thread attachment, and reentrancy rules are post-core FFI work, but the native ABI must leave room for them.

### 16.12 FFI and GPU/native compute

GPU support should build on the same foundations rather than becoming a second unrelated interop system:

- explicit native modules;
- stable native call ABI;
- typed contiguous `Buffer T` values;
- explicit host/device ownership;
- asynchronous operation handles;
- explicit synchronization and error translation.

A GPU buffer is not a `C/Ptr` and should use a distinct device-specific type. CUDA, HIP, Metal, Vulkan, and accelerator libraries can first be exposed through native extension modules. Kernel syntax and compiler-generated device code are separate later design questions.

MVP native-compute scaffolding exposes `$device/Compute` authority and opaque
`$device/Buffer` handles with backend, element-type, and length metadata only.
They are not `C/Ptr` values, do not expose raw memory access, and are intended
as the stable boundary for later CUDA/HIP/Metal/Vulkan extension modules.

### 16.13 FFI MVP

The first FFI milestone includes:

- `NativeFn` integrated with `Callable`;
- a versioned runtime API table and native module initializer;
- opaque Gene values plus rooting;
- generated C wrappers for fixed-width scalars, `C/CStr`, pointers, and buffers;
- explicit typed C declarations;
- basic opaque handles and `C/OwnedPtr` cleanup;
- target-specific static/dynamic library names;
- runtime `$ffi/Load` capability for arbitrary dynamic loading.

Current implementation status: the interpreter has the native-call foundation,
version-checked native module initializer lookup, root handles, generated
`ffi/fn` C wrappers for supported scalar, `C/CStr`, pointer, `C/Slice`, and
`Buffer` ABI shapes, target-specific `ffi/library` metadata, runtime
`ffi/open`/`ffi/bind`, and deterministic `C/OwnedPtr` cleanup through `C/close`
when a release symbol is supplied. This is still an MVP FFI surface, not a
complete production FFI layer.

Deferred:

- runtime-created arbitrary signatures;
- C variadic functions;
- C++ ABI binding;
- bitfields and complex unions;
- general by-value aggregate ABI support;
- escaping callbacks and arbitrary foreign-thread entry;
- automatic header parsing as part of the language core;
- GPU kernel language/compiler integration.

### 16.14 Native compilation and mixed execution

Gene supports compiling sufficiently typed functions and modules to native machine code while preserving interoperability with bytecode and dynamic Gene code. Native compilation is incremental: a program may contain native-compiled typed functions, bytecode functions, native extension functions, and dynamically dispatched values at the same time.

A typed function such as:

```gene
(fn dot [a : (Buffer F32), b : (Buffer F32)] : F32
  ...)
```

may be compiled to a direct internal native signature using unboxed scalars and typed buffer references. The source-level call syntax does not change.

Gene therefore has two related internal calling conventions:

1. **Dynamic Gene ABI** — uses `GeneValue`, `GeneCall`, named arguments, `Callable`, dynamic dispatch, and recoverable error status.
2. **Typed native ABI** — uses statically selected representations, direct positional arguments, known return/error layouts, and direct calls where possible.

The compiler generates adapters between them. A native-compiled typed function still has a dynamic entry adapter so that ordinary untyped Gene code can call it:

```text
dynamic caller
→ validate typed arguments
→ unbox/adapt
→ typed native function
→ box/adapt result
→ dynamic caller
```

Crossing from `Any` into a typed native function uses the same gradual typed-boundary rule as assignment and typed arguments. Invalid dynamic input raises a recoverable boundary `TypeError` before the typed body begins.

#### Typed-to-typed calls

When caller and callee are both statically known and native-compiled, the compiler emits a direct native call. It may avoid:

- `GeneCall` allocation;
- boxing of primitive values;
- runtime argument matching;
- dynamic protocol lookup;
- repeated typed-boundary checks.

A typed function may still use dynamic operations. Operations involving `Any`, reflective selectors, unrestricted `eval`, dynamic `Callable` values, or unresolved protocol dispatch are emitted as calls to runtime helpers. The surrounding function remains native-compiled.

#### Native-to-bytecode and dynamic calls

Native-compiled Gene code may call any Gene callable, including bytecode functions. The compiler emits a runtime trampoline conceptually equivalent to:

```c
GeneStatus gene_call(
  GeneContext *ctx,
  GeneValue callee,
  const GeneCall *call,
  GeneValue *result
);
```

The mixed call path is:

```text
native typed code
→ box live arguments as GeneValue
→ construct GeneCall
→ enter Callable/apply or bytecode VM
→ receive GeneValue or Gene error
→ validate and unbox the expected typed result
→ resume native code
```

A result that does not satisfy the native caller's expected type raises a recoverable boundary `TypeError` when the value came from dynamic code. Recoverable Gene errors propagate through `GeneStatus` and the caller's checked/dynamic error rules. Panic remains a distinct fatal state.

Before entering the VM, generated native code must root any live Gene values that may survive a safepoint, enter a VM-compatible thread/state, and preserve a logical Gene stack frame. Stack traces should cross native/VM boundaries as one call chain.

#### Generics and specialization

Typed generic functions may initially use selective monomorphization:

```gene
(fn (sum t) [xs : (Buffer t)] : t
  ...)
```

Concrete calls such as `(Buffer I64)` and `(Buffer F64)` may receive separate native versions. The compiler may use a shared boxed implementation when specialization is not profitable or when types remain dynamic. Native compilation therefore does not require every generic instantiation to be monomorphized.

#### Protocol dispatch

If the receiver type and exactly one visible implementation are statically known, a protocol message call may compile to a direct native call. If the receiver or implementation is dynamic, native code invokes the runtime protocol dispatcher. The selected visible implementation is part of the compiled module's dependency information.

#### Data representation

Primitive values, typed buffers, and FFI ABI values can use unboxed native representations. Ordinary open Gene node/type values remain managed references unless the type makes a future explicit stable-layout promise such as `^sealed` or `^repr`. Native compilation must not silently expose VM object layout as a C ABI.

#### Eligibility and fallback

A function is eligible for typed native compilation when its parameter, return, local, and checked-error representations are sufficiently known. Unknown values may remain boxed, and unsupported operations may call runtime helpers. Eligibility is therefore granular rather than all-or-nothing.

The intended progression is:

1. bytecode execution for all code;
2. AOT compilation of selected typed functions;
3. AOT compilation of typed modules;
4. specialization of hot generic functions;
5. optional JIT compilation after the runtime and ABI stabilize.

The first backend may emit C for portability and straightforward integration with Nim and existing toolchains. LLVM or another lower-level backend may be added later for JIT, SIMD, and accelerator-oriented optimization.

---
