# Typed-native SQLite example

A working end-to-end use of the experimental `typed_native` C backend
(`docs/proposals/native-type.md` Part II): Gene functions that take an unboxed
`sqlite3_stmt *` in a register and call SQLite directly, with no `GeneValue`,
no boxing, and no runtime message resolution.

## Build and run

```bash
nimble build          # produces bin/gene
nimble native_example # or: examples/native/build.sh
```

Expected output:

```
==> running (C calling Gene-compiled code)
columns: 2
rows: 3
total: 340
==> running (Gene calling native code)
42
42
```

`total` is `(10*3) + (20*5) + (30*7)`. Build artifacts go to
`build/native-example/`. The script resolves the manifest's `sqlite` system
dependency through the package resolver's explicit `pkg_config` policy;
override the explicit tools with `CC=`, `GENE=`, or `PKG_CONFIG=`.

## Files

Both directions across the boundary are covered.

**C calling Gene-compiled code:**

| file | role |
|---|---|
| `sqlite_rows.gene` | the typed-native module — compiled to C by the backend |
| `main.c` | driver: calls into the Gene-compiled entry points |

**Gene calling native code:**

| file | role |
|---|---|
| `scaled.gene` | functions with `^native_entry`, built as a loadable library |
| `call_from_gene.gene` | ordinary Gene that loads and calls them |

`build.sh` drives both.

## Gene calling native code

```gene
(import $aot [load])
(var native (load "build/native-example/libscaled.dylib"))
($println (native/triple 14))   # => 42
```

`aot/load` opens the library, reads its exported `gene_aot_module` manifest,
and binds every function carrying a `^native_entry` adapter. The call runs
compiled machine code: the adapter checks arity, unboxes the `Int`, calls the
native function, and boxes the result.

This works because the library is built with `-DGENE_AOT_DYNAMIC_ENTRIES=1`,
which compiles in the adapters, and the `gene_ffi_*` helpers they call are
exported from the `gene` executable (`src/gene/aot_runtime.nim`, plus
`-Wl,-export_dynamic` in `nim.cfg`) so they resolve at `dlopen` time.

## Managed wrappers across the boundary

Native pointers cross too, as ordinary managed wrappers. A `^native_entry`
whose result is `transfer` hands back a real Gene value:

```gene
(var p (native/make))     # native code allocated it
($head p)                 # => (type Point)
(native/get_x p)          # => 3, via a direct field load in compiled C
```

A `^native` type records the identity its compiled code was built against, and
the boundary recovers the `Type` from that identity rather than trusting the
incoming value's head. A look-alike carrying a forged handle is rejected:

```
Error: native entry argument 'p' expects a Point value
```

Ownership follows the declared mode:

- **borrow** — the wrapper stays the owner; it is still usable afterwards.
- **transfer** — ownership moves to the callee, so the wrapper is *relinquished*
  (marked closed without running its release callback, which would free memory
  the callee is about to use). Using it again fails with `is closed`, so a
  double free is not reachable from Gene.
- **copy** — the callee gets its own pointer and the original stays usable.

## Benchmark: `bench_fib.sh`

```bash
examples/native/bench_fib.sh
```

Recursive `fib` in the VM against the same function compiled and called through
the AOT boundary. `benchmarks/scripts/bench_fib_aot_c` already times compiled
fib as a standalone binary — a ceiling with no runtime involved; this measures
what a Gene program actually experiences.

Representative run (Apple clang -O2, fib(28) × 20, stable to ~1% across runs):

```
vm   time: 1291 ms      vm   rate:    15,932,718 calls/second
aot  time:   11 ms      aot  rate: 1,869,921,818 calls/second
Speedup:   117x

Boundary cost over 200000 crossings:
  aot boundary call: 52 ms     (~260 ns/call)
  vm function call:  20 ms     (~100 ns/call)
```

**Both numbers matter, and they point in opposite directions.** The recursion
never crosses the boundary — `fib` calls itself directly in C — so one crossing
covers a million calls and the compiled code runs ~117× the VM.

But a crossing costs about 2.6× a plain VM call. Calling a *trivial* native
function is slower than staying in the VM. AOT pays when the compiled function
does enough work to amortize the crossing, and `identity` exists in `fib.gene`
precisely to price that floor.

Some of the per-crossing cost is the adapter's own doing: the dispatcher looks
its entry up by name on every call, because `NativeCallProc` is `nimcall` and
cannot capture the entry pointer. Carrying the pointer on the callable instead
would remove that lookup.

## Foreign calls through compiled marshalling

`aot/load` also binds each `ffi/fn`'s generated wrapper, so a foreign call goes
through compiled marshalling code rather than the VM's dynamic FFI path:

```gene
(n/shout "hello")      # => 5     const char * borrowed for the call
(n/flip false)         # => true
(n/total 40 2)         # => 42    uint32_t + size_t
```

Every integral C parameter narrows from Gene's 64-bit `Int`, so the boundary
range-checks instead of truncating — passing `200` where the C signature says
`int8_t` is an error, not `-56`:

```
Error: native entry argument 'b' is out of range: 200 does not fit -128..127
```

Strings and buffers are *borrowed* for the call's extent (they point into the
argument's own storage), so foreign code must not retain them. A returned
`const char *` is copied, since its lifetime is unknown.

## What the generated C looks like

`(fn step_row [stmt : Stmt] : I64 (sqlite3_step stmt))` becomes:

```c
int64_t gene_native_step_row(sqlite3_stmt * stmt) {
  return sqlite3_step(stmt);
}
```

The pointer stays unboxed across Gene→Gene calls too — `read_first` lowers to a
direct call, not a dispatch:

```c
int64_t gene_native_read_first(sqlite3_stmt * stmt, int64_t first_column) {
  int64_t value = gene_native_column_i64(stmt, first_column);
  return value;
}
```

There is no `GeneValue` anywhere in the typed function bodies.

## What the subset covers

A function with a native-pointer parameter may read and write native struct
fields, bind locals, call another typed-native function / typed FFI symbol /
statically resolved qualified send, compute with `+ - *`, the comparisons and
`if`, loop with `while`, and group statements with a block-scoped `do`.

Three boundary representations cross edges without being computed with:

- **`I32`** — matches a C `int` exactly. Gene's `I32` is a range-checked Int,
  so it widens into `I64` to be computed with rather than wrapping as C would.
- **`Str`** — borrowed as a `const char *` for the call's extent. The argument
  owns the storage; foreign code must not retain it. String literals work too.
- **`^out` parameters** — passed by address and written through, so C's
  "status plus out-handle" signatures are expressible directly.

Together those retired the C shim this example used to need: `sqlite3_open`,
`sqlite3_exec`, `sqlite3_prepare_v2` and `sqlite3_close` are all bound
directly, and acquisition happens in Gene:

```gene
(fn open_db [path : Str] : Db?
  (var db : Db? nil)
  (let rc : I64 (sqlite3_open path db))
  (if (= rc 0) db nil))
```

The `while` loop still lives in `main.c` only because the driver is a C
program; `scan_total` shows the same loop compiled from Gene.

## Linking

The generated C declares the `gene_ffi_*` / `gene_typed_native_*` runtime
helpers, and `src/gene/aot_runtime.nim` defines them. They are exported from
the `gene` executable (`-Wl,-export_dynamic` in `nim.cfg`), so a library opened
with `dlopen` resolves them from the host at load time.

The dynamic entry wrappers — what interpreted Gene calls to reach these symbols
— are emitted behind `#ifdef GENE_AOT_DYNAMIC_ENTRIES` and compiled out by
default, which is what lets `sqlite_example` link as a plain C program with no
Gene runtime at all. `libscaled.dylib` is built with the macro defined, because
`aot/load` binds exactly those wrappers.

So both halves of this directory link for different reasons: the SQLite driver
needs none of the runtime, and the loadable library needs all of it.
