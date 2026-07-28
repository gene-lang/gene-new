## Runtime side of the typed_native AOT boundary.
##
## The C backend (`src/gene/gir.nim`) emits functions that call
## `gene_ffi_*` / `gene_typed_native_*` helpers and never dereference
## `GeneValue`, `GeneCall`, or `GeneContext` — it only passes them as opaque
## pointers. That means this module owns their real shapes, and the C side
## needs no knowledge of the value representation.
##
## Helpers are `{.exportc, cdecl, dynlib.}` so they land in the host
## executable's dynamic symbol table. An AOT library built with
## `-undefined dynamic_lookup` (macOS) or plain `-shared` (ELF) resolves them
## from the host at `dlopen` time. The host must be linked with
## `-Wl,-export_dynamic`; see `nim.cfg`.
##
## Status codes mirror the generated `#define`s: 0 ok, 1 error, 2 panic.

import ./types

const
  AotOk* = cint(0)
  AotError* = cint(1)

proc fail(ctx: ptr AotContext, message: string): cint =
  if ctx != nil:
    ctx.failed = true
    ctx.message = message
  AotError

proc argAt(call: ptr AotCall, index: csize_t): Value =
  call.args[int(index)]

# ---------------------------------------------------------------------------
# Arity and scalar arguments
# ---------------------------------------------------------------------------

proc geneFfiCheckArity(ctx: ptr AotContext, call: ptr AotCall,
                       expected: csize_t): cint
                      {.exportc: "gene_ffi_check_arity", cdecl, dynlib.} =
  if call == nil:
    return ctx.fail("native entry received no call")
  if call.len != expected:
    return ctx.fail("native entry expects " & $expected &
      " argument(s), got " & $call.len)
  AotOk

proc geneFfiArgInt64(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
                     name: cstring, outValue: ptr int64): cint
                    {.exportc: "gene_ffi_arg_int64", cdecl, dynlib.} =
  if call == nil or index >= call.len or outValue == nil:
    return ctx.fail("native entry argument index out of range")
  let value = call.argAt(index)
  if value.kind != vkInt:
    return ctx.fail("native entry argument '" & $name & "' expects Int")
  outValue[] = value.intVal
  AotOk

proc geneFfiArgDouble(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
                      name: cstring, outValue: ptr float64): cint
                     {.exportc: "gene_ffi_arg_double", cdecl, dynlib.} =
  if call == nil or index >= call.len or outValue == nil:
    return ctx.fail("native entry argument index out of range")
  let value = call.argAt(index)
  if value.kind == vkFloat:
    outValue[] = value.floatVal
  elif value.kind == vkInt:
    outValue[] = float64(value.intVal)
  else:
    return ctx.fail("native entry argument '" & $name & "' expects Float")
  AotOk

# ---------------------------------------------------------------------------
# Scalar results
# ---------------------------------------------------------------------------

proc geneFfiResultInt64(ctx: ptr AotContext, value: int64,
                        resultOut: ptr Value): cint
                       {.exportc: "gene_ffi_result_int64", cdecl, dynlib.} =
  if resultOut == nil:
    return ctx.fail("native entry result slot is null")
  resultOut[] = newInt(value)
  AotOk

proc geneFfiResultDouble(ctx: ptr AotContext, value: float64,
                         resultOut: ptr Value): cint
                        {.exportc: "gene_ffi_result_double", cdecl, dynlib.} =
  if resultOut == nil:
    return ctx.fail("native entry result slot is null")
  resultOut[] = newFloat(value)
  AotOk

proc geneFfiResultVoid(ctx: ptr AotContext, resultOut: ptr Value): cint
                      {.exportc: "gene_ffi_result_void", cdecl, dynlib.} =
  if resultOut == nil:
    return ctx.fail("native entry result slot is null")
  resultOut[] = NIL
  AotOk

# ---------------------------------------------------------------------------
# Null-field traps
#
# A nullable typed-native base that turns out to be NULL cannot produce a
# value, so the generated guard calls these instead of dereferencing.
# ---------------------------------------------------------------------------

proc geneTypedNativeNullI64(typeName, fieldName: cstring): int64
                           {.exportc: "gene_typed_native_null_i64", cdecl, dynlib.} =
  raise newException(GeneError,
    "null " & $typeName & " has no field '" & $fieldName & "'")

proc geneTypedNativeNullF64(typeName, fieldName: cstring): float64
                           {.exportc: "gene_typed_native_null_f64", cdecl, dynlib.} =
  raise newException(GeneError,
    "null " & $typeName & " has no field '" & $fieldName & "'")

proc geneTypedNativeNullPtr(typeName, fieldName: cstring): pointer
                           {.exportc: "gene_typed_native_null_ptr", cdecl, dynlib.} =
  raise newException(GeneError,
    "null " & $typeName & " has no field '" & $fieldName & "'")
