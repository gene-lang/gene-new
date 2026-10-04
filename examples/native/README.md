# Typed-native SQLite example

A working end-to-end use of the experimental `typed_native` C backend
(`docs/workflows.md#native-interop`): Gene functions that take an unboxed
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

Checked ABI v2 capture after the review fixes on 2026-10-04 (macOS arm64,
release/ORC host, Apple clang -O2, three runs of fib(28) × 20):

```
vm   time: median 1238 ms   (1232–1256 ms)
aot  time: median  115 ms   (112–122 ms)
Ratio of medians: 10.8x

Boundary cost over 200000 crossings:
  aot boundary call: median 73 ms   (~365 ns/iteration)
  vm function call:  median 22 ms   (~110 ns/iteration)
```

The result was 317811 on both paths in every run. The full samples are in the
[review follow-up](../../docs/proposals/optimization-review.md). The earlier
pre-guard capture remains under `benchmarks/baselines/2026-10-04-publication/aot/`.
These are local measurements, including the Gene loop's overhead in the boundary
rows. The earlier 117× figure used unchecked ABI v1 and is not representative of
the exact-integer backend. The recursion never crosses the boundary — `fib`
calls itself directly in C — so one crossing covers a million logical calls.

In this run, the boundary loop cost about 3.3× the VM-call loop. AOT pays when the compiled function
does enough work to amortize the crossing, and `identity` exists in `fib.gene`
precisely to price that floor.

Some of the per-crossing cost is the adapter's own doing: the dispatcher looks
its entry up by name on every call. The existing `NativeContextCallProc`
mechanism could carry the entry pointer on the callable and remove that lookup,
while preserving the ABI-epoch validation.

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

Strings and `C/Slice` views are borrowed for the call's extent, so foreign code
must not retain them. The current Buffer bridge copies byte-compatible elements
into temporary storage and copies mutations back after the call; it does not
yet borrow packed F32/F64 buffers. A returned `const char *` is copied.

## Checked C calls

Generated native functions use ABI version 2: a `GeneNativeError *`, the
unboxed parameters, and an out-result pointer, returning `GeneNativeStatus`.
Initialize the error record to zero and clear it after use. The out-result is
unchanged on failure. Calls through `aot/load` translate failures into Gene
errors, preserving TypeError's actual value and native stack frames.

An installed compiler can export the self-contained support header:

```sh
gene compile --c-header > gene_native.h
```

```c
#include "gene_native.h"
GeneNativeStatus gene_native_add64(GeneNativeError *, int64_t, int64_t, int64_t *);

GeneNativeError error = {0};
int64_t value = 0;
GeneNativeStatus status = gene_native_add64(&error, 20, 22, &value);
if (status == GENE_NATIVE_OK) {
  /* value is 42 */
} else {
  /* error.status, where, expected, actual_kind and frames describe failure */
}
gene_aot_error_clear(&error);
```

Pass valid result storage distinct from the error record and any storage
mutated by the callee; do not shallow-copy an error record
that owns an integer or trace allocation. A subsequent call clears an earlier
failure in that record. Concurrent calls use separate records. No Gene host
is needed for direct C calls: the generated translation unit includes the
integer/error support. Include the exported `gene_native.h` in a separate C
caller. The SQLite build script exports it into its output directory; no source
checkout is needed to obtain the contract from an installed `gene`.
Keep the generated library loaded until its error records have been cleared:
trace labels and allocator callbacks refer to that library. Diagnostic string
values borrow their original storage and must be inspected before it is released.

Integer parameters and results keep their declared machine representation.
Intermediate integer arithmetic promotes when necessary and remains exact;
an out-of-range typed binding or result is a checked TypeError. The compiler
sequences operands and calls, so errors do not require replaying effects.
Rebuild old AOT libraries: the loader rejects the previous manifest version.

Native recursion is bounded to **256 active generated calls per thread per C
module**. Crossing the limit returns `GENE_NATIVE_RUNTIME_ERROR`, translated to
a Gene `RuntimeError` through `aot/load`; the result remains untouched and later
calls still work. This differs from the VM's explicit call stack. A C build may
set `-DGENE_AOT_MAX_CALL_DEPTH=N` for a platform with a qualified stack budget.
Foreign C recursion and arbitrarily large function-local storage are outside
this guard. Rewrite very deep native recursion as a loop or execute it in the VM.

Ownership remains manual after a `^transfer`/`^copy` argument enters the callee.
Acquisition failures roll back before entry. A failure inside the native body
cannot safely restore or release every argument: foreign calls may already have
freed, retained or handed off pointers. Conversely, failure before consumption
can leave transferred/copied allocations unreleased. Until native ownership
effects and cleanup paths are represented explicitly, prefer borrowed arguments
with owner-managed cleanup around fallible kernels. Automatic post-call rollback
would make the existing release-then-fail case double-free.

## What the generated C looks like

`(fn step_row [stmt : Stmt] : I64 (sqlite3_step stmt))` becomes:

```c
GeneNativeStatus gene_native_step_row(
    GeneNativeError *error, sqlite3_stmt *stmt, int64_t *out);
```

The pointer stays unboxed across Gene→Gene calls too — `read_first` lowers to a
direct call, not a dispatch:

```c
GeneNativeStatus gene_native_read_first(
    GeneNativeError *error, sqlite3_stmt *stmt, int32_t first_column,
    int64_t *out);
```

The implementation makes a checked direct C call to `gene_native_column_i64`.
There is no `GeneValue` in typed function bodies. Integer temporaries can carry
an exact wide result without crossing into the VM.

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
  (if (== rc 0) db nil))
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
