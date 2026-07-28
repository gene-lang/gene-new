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

import std/strutils

import ./[types, vm]

const
  AotOk* = cint(0)
  AotError* = cint(1)

type
  ## Shim function pointers generated C passes in: `GeneTypedNativeCopyFn` and
  ## `GeneTypedNativeReleaseFn`. They wrap the type's own `^copy` / `^release`
  ## C symbols, so the runtime never names those symbols itself.
  AotCopyProc* = proc(value: pointer): pointer {.cdecl.}
  AotReleaseProc* = proc(value: pointer) {.cdecl.}

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
# Managed wrapper arguments and results (proposal §6.4)
#
# Generated C hands over only strings: the identity the code was compiled
# against, the ABI layout identity, and the handle field name. Recovering the
# Type from its identity — rather than trusting the incoming value's head — is
# what makes the nominal check meaningful. The ABI identity is implied by the
# type (a `^native` type names exactly one `^abi`), so matching the type
# identity is the load-bearing check.
# ---------------------------------------------------------------------------

proc wrapperPointer(ctx: ptr AotContext, value: Value, argName: cstring,
                    typeIdentity, handleField: cstring, nullable: bool,
                    outPtr: ptr pointer): cint =
  if value.kind == vkNil:
    if not nullable:
      return ctx.fail("native entry argument '" & $argName & "' must not be nil")
    outPtr[] = nil
    return AotOk
  let wrapperType = nativeTypeByIdentity($typeIdentity)
  if wrapperType.kind != vkType:
    return ctx.fail("no native type is registered for identity '" &
      $typeIdentity & "'; its declaring module must be loaded first")
  # Ancestry, not leaf equality, and by Type identity rather than name — the
  # same rule geneWrapperField enforces. A look-alike node must not carry its
  # pointer into compiled code that will dereference it.
  if value.kind != vkNode or not value.head.typeInheritsFrom(wrapperType):
    return ctx.fail("native entry argument '" & $argName & "' expects a " &
      wrapperType.typeName & " value")
  let handle = value.props.getOrDefault($handleField, VOID)
  if handle.kind != vkCPtr:
    return ctx.fail("native entry argument '" & $argName & "' has no '" &
      $handleField & "' pointer")
  if handle.cPtrClosed:
    return ctx.fail("native entry argument '" & $argName & "' is closed")
  if handle.cPtrIsNull and not nullable:
    return ctx.fail("native entry argument '" & $argName & "' is a null pointer")
  outPtr[] = handle.cPtrAddress
  AotOk

proc geneTypedNativeArgBorrow(ctx: ptr AotContext, call: ptr AotCall,
                              index: csize_t, argName: cstring,
                              typeIdentity, abiIdentity, handleField: cstring,
                              nullable: bool, outPtr: ptr pointer): cint
                             {.exportc: "gene_typed_native_arg_borrow", cdecl,
                               dynlib.} =
  ## Borrow: the wrapper stays the owner for the call's extent, so nothing is
  ## consumed and there is nothing to roll back.
  if call == nil or index >= call.len or outPtr == nil:
    return ctx.fail("native entry argument index out of range")
  wrapperPointer(ctx, call.argAt(index), argName, typeIdentity, handleField,
                 nullable, outPtr)

proc geneTypedNativeArgTransfer(ctx: ptr AotContext, call: ptr AotCall,
                                index: csize_t, argName: cstring,
                                typeIdentity, abiIdentity, handleField: cstring,
                                nullable: bool, outPtr: ptr pointer): cint
                               {.exportc: "gene_typed_native_arg_transfer",
                                 cdecl, dynlib.} =
  ## Transfer: ownership moves to the callee, so the wrapper is closed before
  ## the call. Closing here — not after — means a later failure cannot leave
  ## two owners of the same pointer.
  if call == nil or index >= call.len or outPtr == nil:
    return ctx.fail("native entry argument index out of range")
  let value = call.argAt(index)
  let status = wrapperPointer(ctx, value, argName, typeIdentity, handleField,
                              nullable, outPtr)
  if status != AotOk:
    return status
  if value.kind == vkNode:
    let handle = value.props.getOrDefault($handleField, VOID)
    if handle.kind == vkCPtr:
      # Relinquish, never close: the callee owns the address now, and closing
      # would run the release callback on memory it is about to use.
      relinquishCPtr(handle)
  AotOk

proc geneTypedNativeArgRestore(ctx: ptr AotContext, call: ptr AotCall,
                               index: csize_t, value: pointer)
                              {.exportc: "gene_typed_native_arg_restore",
                                cdecl, dynlib.} =
  ## Rollback hook for an entry that failed after acquiring this argument.
  ## A borrow consumed nothing, and a transfer's pointer is already owned by
  ## the callee, so there is nothing to undo in either case; the hook exists so
  ## generated C has a uniform unwind path.
  discard

proc geneTypedNativeArgCopy(ctx: ptr AotContext, call: ptr AotCall,
                            index: csize_t, argName: cstring,
                            typeIdentity, abiIdentity, handleField: cstring,
                            nullable: bool, copy: AotCopyProc,
                            outPtr: ptr pointer): cint
                           {.exportc: "gene_typed_native_arg_copy", cdecl,
                             dynlib.} =
  ## Copy: the callee gets its own pointer, so the wrapper keeps ownership of
  ## the original and neither side can free the other's.
  if call == nil or index >= call.len or outPtr == nil or copy == nil:
    return ctx.fail("native entry argument index out of range")
  var borrowed: pointer
  let status = wrapperPointer(ctx, call.argAt(index), argName, typeIdentity,
                              handleField, nullable, addr borrowed)
  if status != AotOk:
    return status
  if borrowed == nil:
    outPtr[] = nil
    return AotOk
  let copied = copy(borrowed)
  if copied == nil:
    return ctx.fail("native entry argument '" & $argName & "' copy failed")
  outPtr[] = copied
  AotOk

proc identityLeafName(identity: string): string =
  ## `<source>::<ns>/<Name>` -> `Name`. A declared handle field is annotated
  ## with the ABI struct's *name* (`(C/OwnedPtr CPoint)`), so the pointer built
  ## here has to carry that, not the Gene type's name.
  result = identity
  let slash = result.rfind('/')
  if slash >= 0:
    result = result[slash + 1 .. ^1]
  let colon = result.rfind("::")
  if colon >= 0:
    result = result[colon + 2 .. ^1]

proc wrapperResult(ctx: ptr AotContext, address: pointer,
                   typeIdentity, abiIdentity, handleField: cstring,
                   nullable: bool,
                   release: AotReleaseProc, resultOut: ptr Value): cint =
  if resultOut == nil:
    return ctx.fail("native entry result slot is null")
  if address == nil:
    if not nullable:
      return ctx.fail("native entry returned an unexpected null pointer")
    resultOut[] = NIL
    return AotOk
  let wrapperType = nativeTypeByIdentity($typeIdentity)
  if wrapperType.kind != vkType:
    return ctx.fail("no native type is registered for identity '" &
      $typeIdentity & "'; its declaring module must be loaded first")
  let abiName = newSym(identityLeafName($abiIdentity))
  let handle =
    if release != nil:
      newCOwnedPtr(address, cast[CPtrReleaseProc](release), abiName)
    else:
      newCPtr(address, abiName)
  try:
    resultOut[] = newNativeWrapper(wrapperType, {($handleField): handle})
  except GeneError as e:
    return ctx.fail(e.msg)
  AotOk

proc geneTypedNativeResultTransfer(ctx: ptr AotContext, address: pointer,
                                   typeIdentity, abiIdentity,
                                   handleField: cstring, nullable: bool,
                                   release: AotReleaseProc,
                                   resultOut: ptr Value): cint
                                  {.exportc: "gene_typed_native_result_transfer",
                                    cdecl, dynlib.} =
  ## The new wrapper becomes the sole release owner.
  wrapperResult(ctx, address, typeIdentity, abiIdentity, handleField, nullable,
                release, resultOut)

proc geneTypedNativeResultCopy(ctx: ptr AotContext, address: pointer,
                               typeIdentity, abiIdentity, handleField: cstring,
                               nullable: bool, copy: AotCopyProc,
                               release: AotReleaseProc,
                               resultOut: ptr Value): cint
                              {.exportc: "gene_typed_native_result_copy", cdecl,
                                dynlib.} =
  ## The callee keeps its pointer; the wrapper owns a copy. Without this a
  ## borrowed result would be freed twice.
  if copy == nil:
    return ctx.fail("native entry result copy is unavailable")
  if address == nil:
    return wrapperResult(ctx, nil, typeIdentity, abiIdentity, handleField,
                         nullable, release, resultOut)
  let copied = copy(address)
  if copied == nil:
    return ctx.fail("native entry result copy failed")
  wrapperResult(ctx, copied, typeIdentity, abiIdentity, handleField, nullable,
                release, resultOut)

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
