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
`build/native-example/`. The script uses `pkg-config`, then Homebrew's
keg-only prefix, then a bare `-lsqlite3`; override with `CC=` or `GENE=`.

## Files

Both directions across the boundary are covered.

**C calling Gene-compiled code:**

| file | role |
|---|---|
| `sqlite_rows.gene` | the typed-native module — compiled to C by the backend |
| `sqlite_shim.c` | thin C adapters for signatures the subset cannot express |
| `main.c` | driver: opens the database, runs the row loop |

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

## Why the loop is in C

This is the honest part. The `typed_native` subset is currently narrow, and
the example's shape is dictated by its limits rather than by preference. A
function with a native-pointer parameter may:

- read and write native struct fields;
- bind locals with `let`/`var`;
- call another typed-native function, a typed FFI symbol, or a statically
  resolved qualified protocol send (`(recv ~ P:m)`);
- compute with `+`, `-`, `*`, the comparisons, `if`, and scalar literals,
  nested freely;
- loop with `while`, and group statements with a block-scoped `do`;
- return any of the above.

That is enough to keep a whole scan in Gene. `scan_total` steps the statement,
reads both columns, multiplies and accumulates — all in one compiled C
function, with `main.c` calling it once:

```c
int64_t gene_native_scan_total(sqlite3_stmt * stmt, int64_t amount_column,
                               int64_t quantity_column, int64_t row_marker) {
  int64_t total = 0;
  while ((gene_native_step_row(stmt) == row_marker)) {
    total = (total + gene_native_row_total(stmt, amount_column,
                                           quantity_column));
  }
  return total;
}
```

The example runs the scan both ways — a C loop calling `row_total` per row,
and this single compiled call — and both report `340`.

Constraints worth knowing: both arms of an `if` must share the result
representation (a C ternary has one type, and there is no boxing available to
reconcile two), and a local declared inside a block leaves scope with it, just
as in the emitted C.

Two further limits shape `sqlite_shim.c`:

- **Out-parameters.** `sqlite3_open`/`sqlite3_prepare_v2` return handles
  through `sqlite3**`. Typed-native Gene cannot take the address of a local,
  so acquisition happens in C and Gene receives an open pointer.
- **`int` parameters.** `sqlite3_column_int64` takes `int` for the column
  index, and a Gene `I64` will not narrow into it — correctly, since `int` is
  32 bits. The shim widens the parameter to `int64_t`.
- **Literal arguments.** FFI call arguments must be bindings, not literals, so
  column indices are passed in as parameters.

## Linking

The generated C declares the `gene_ffi_*` / `gene_typed_native_*` runtime
helpers but no Gene runtime defines them yet — production AOT backends are
deferred (`docs/implementation-status.md`), and the native C ABI those helpers
need is design.md's step 12, which precedes native compilation.

So the dynamic entry wrappers (what interpreted Gene would call to reach these
symbols) are emitted behind `#ifdef GENE_AOT_DYNAMIC_ENTRIES` and compiled out
by default. That is what lets this example link standalone. Define the macro
once a runtime exports those helpers.

The practical consequence: **this example is C calling Gene-compiled code, not
a Gene program calling native code.** The second direction is exactly what the
missing ABI gates.
