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

proc argWhere(name: cstring): string =
  ## Only ever called on a failing conversion. Building this eagerly cost
  ## ~275 ns per boundary crossing in allocation alone — `$name` plus two
  ## concatenations, on every argument of every call, to produce a string the
  ## success path never reads.
  "native entry argument '" & $name & "'"

const ResultWhere = "native entry result"

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

## Every scalar and string helper below delegates to the *same* converter the
## VM's dynamic FFI path uses. The hand-written table that used to live here
## disagreed with those converters at nearly every width — accepting an Int for
## a Float, dropping `C/Float`'s range check, rejecting a `Char` for `C/Char`,
## capping the 64-bit unsigned types at `high(int64)`, hardcoding `C/Long`'s
## range as 64-bit, and letting a BigInt `FieldDefect` escape through a cdecl
## frame. Compiled and interpreted code must agree, so there is exactly one
## implementation of each conversion and it is not this file's.

template defArgVia(nimName: untyped, cName: static string, CT: typedesc,
                   convert: untyped) {.dirty.} =
  ## `where` starts empty so the success path allocates nothing. The converters
  ## read it only when raising, so a failure re-runs the conversion once with
  ## the real parameter name purely to build the message — the conversions are
  ## pure in the argument, and the second run happens only on the error path
  ## where its cost is irrelevant.
  proc nimName(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
               name: cstring, outValue: ptr CT): cint
              {.exportc: cName, cdecl, dynlib.} =
    if call == nil or index >= call.len or outValue == nil:
      return ctx.fail("native entry argument index out of range")
    let value = call.argAt(index)
    var where = ""
    try:
      outValue[] = CT(convert)
      return AotOk
    except CatchableError:
      discard
    where = argWhere(name)
    try:
      outValue[] = CT(convert)
    except CatchableError as e:
      return ctx.fail(e.msg)
    AotOk

defArgVia(geneFfiArgInt8, "gene_ffi_arg_int8", int8,
          ffiCInt8Arg(where, value))
defArgVia(geneFfiArgUInt8, "gene_ffi_arg_uint8", uint8,
          ffiCUInt8Arg(where, value))
defArgVia(geneFfiArgInt16, "gene_ffi_arg_int16", int16,
          ffiCInt16Arg(where, value))
defArgVia(geneFfiArgUInt16, "gene_ffi_arg_uint16", uint16,
          ffiCUInt16Arg(where, value))
defArgVia(geneFfiArgInt32, "gene_ffi_arg_int32", int32,
          ffiCInt32Arg(where, value))
defArgVia(geneFfiArgUInt32, "gene_ffi_arg_uint32", uint32,
          ffiCUInt32Arg(where, value))
defArgVia(geneFfiArgInt64, "gene_ffi_arg_int64", int64,
          ffiCInt64Arg(where, value))
defArgVia(geneFfiArgUInt64, "gene_ffi_arg_uint64", uint64,
          ffiCUInt64Arg(where, "C/UInt64", value))
defArgVia(geneFfiArgChar, "gene_ffi_arg_char", cchar,
          ffiCCharArg(where, value))
defArgVia(geneFfiArgUChar, "gene_ffi_arg_uchar", uint8,
          ffiCUCharArg(where, value))
defArgVia(geneFfiArgShort, "gene_ffi_arg_short", cshort,
          ffiCShortArg(where, value))
defArgVia(geneFfiArgUShort, "gene_ffi_arg_ushort", cushort,
          ffiCUShortArg(where, value))
defArgVia(geneFfiArgInt, "gene_ffi_arg_int", cint,
          ffiCIntArg(where, value))
defArgVia(geneFfiArgUInt, "gene_ffi_arg_uint", cuint,
          ffiCUIntArg(where, value))
defArgVia(geneFfiArgLong, "gene_ffi_arg_long", clong,
          ffiCLongArg(where, value))
defArgVia(geneFfiArgULong, "gene_ffi_arg_ulong", culong,
          ffiCULongArg(where, value))
defArgVia(geneFfiArgSize, "gene_ffi_arg_size", csize_t,
          ffiCSizeArg(where, value))
defArgVia(geneFfiArgPtrdiff, "gene_ffi_arg_ptrdiff", GeneCPtrDiff,
          ffiCPtrDiffArg(where, value))
defArgVia(geneFfiArgDouble, "gene_ffi_arg_double", float64,
          ffiCDoubleArg(where, value))
defArgVia(geneFfiArgFloat, "gene_ffi_arg_float", float32,
          ffiCFloatArg(where, value))
defArgVia(geneFfiArgBool, "gene_ffi_arg_bool", bool,
          ffiCBoolArg(where, value))

proc geneFfiArgCStr(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
                    name: cstring, outValue: ptr cstring): cint
                   {.exportc: "gene_ffi_arg_cstr", cdecl, dynlib.} =
  ## Borrowed for the call's extent: the pointer is formed from the argument's
  ## own storage, the argument outlives the call, and foreign code must not
  ## retain it. `nil` and interior NULs are rejected, as on the dynamic path —
  ## a Gene `Str` does not admit nil, and `cstring(...)` would silently truncate
  ## at the first interior NUL.
  if call == nil or index >= call.len or outValue == nil:
    return ctx.fail("native entry argument index out of range")
  let value = call.argAt(index)
  try:
    outValue[] = ffiCStrArg("", value)
    return AotOk
  except CatchableError:
    discard
  try:
    outValue[] = ffiCStrArg(argWhere(name), value)
  except CatchableError as e:
    return ctx.fail(e.msg)
  AotOk

proc argPointer(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
                name, typeName: cstring, outValue: ptr pointer): cint =
  ## `typeName` is the full declared label — `"(C/NullablePtr CDb)"` — which the
  ## emitter has always passed and this helper used to spend only on an error
  ## message. Enforcing it is what stops a pointer to an unrelated native type
  ## reaching C code that will dereference it as something else. Nullability,
  ## closed state, and the const/owned flavors come with it.
  if call == nil or index >= call.len or outValue == nil:
    return ctx.fail("native entry argument index out of range")
  let value = call.argAt(index)
  try:
    outValue[] = ffiAotPointerArg("", $typeName, value)
    return AotOk
  except CatchableError:
    discard
  try:
    outValue[] = ffiAotPointerArg(argWhere(name), $typeName, value)
  except CatchableError as e:
    return ctx.fail(e.msg)
  AotOk

proc geneFfiArgPtr(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
                   name, typeName: cstring, outValue: ptr pointer): cint
                  {.exportc: "gene_ffi_arg_ptr", cdecl, dynlib.} =
  argPointer(ctx, call, index, name, typeName, outValue)

proc geneFfiArgConstPtr(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
                        name, typeName: cstring, outValue: ptr pointer): cint
                       {.exportc: "gene_ffi_arg_const_ptr", cdecl, dynlib.} =
  argPointer(ctx, call, index, name, typeName, outValue)

type
  AotBufferView = object
    ## Mirrors `GeneFfiBufferView` in the generated C.
    data: pointer
    len: csize_t

proc geneFfiArgBuffer(ctx: ptr AotContext, call: ptr AotCall, index: csize_t,
                      name, typeName: cstring,
                      outValue: ptr AotBufferView): cint
                     {.exportc: "gene_ffi_arg_buffer", cdecl, dynlib.} =
  ## Borrowed like `cstr`: the view points into the argument's storage and is
  ## valid for the call only. A Str is accepted as a byte view, which is what
  ## a C API taking (bytes, len) expects.
  if call == nil or index >= call.len or outValue == nil:
    return ctx.fail("native entry argument index out of range")
  let value = call.argAt(index)
  case value.kind
  of vkNil:
    outValue.data = nil
    outValue.len = 0
  of vkString:
    let s = value.strVal
    outValue.data = if s.len > 0: cast[pointer](unsafeAddr s[0]) else: nil
    outValue.len = csize_t(s.len)
  of vkCSlice:
    outValue.data = value.cSliceAddress
    outValue.len = csize_t(value.cSliceLen)
  else:
    return ctx.fail("native entry argument '" & $name &
      "' expects a " & $typeName & " buffer")
  AotOk

# ---------------------------------------------------------------------------
# Scalar results
# ---------------------------------------------------------------------------

proc geneFfiResultVoid(ctx: ptr AotContext, resultOut: ptr Value): cint
                      {.exportc: "gene_ffi_result_void", cdecl, dynlib.} =
  if resultOut == nil:
    return ctx.fail("native entry result slot is null")
  resultOut[] = NIL
  AotOk

template defResultVia(nimName: untyped, cName: static string, CT: typedesc,
                      convert: untyped) {.dirty.} =
  proc nimName(ctx: ptr AotContext, value: CT, resultOut: ptr Value): cint
              {.exportc: cName, cdecl, dynlib.} =
    if resultOut == nil:
      return ctx.fail("native entry result slot is null")
    try:
      resultOut[] = convert
    except CatchableError as e:
      return ctx.fail(e.msg)
    AotOk

defResultVia(geneFfiResultInt8, "gene_ffi_result_int8", int8,
             newInt(int64(value)))
defResultVia(geneFfiResultUInt8, "gene_ffi_result_uint8", uint8,
             newInt(int64(value)))
defResultVia(geneFfiResultInt16, "gene_ffi_result_int16", int16,
             newInt(int64(value)))
defResultVia(geneFfiResultUInt16, "gene_ffi_result_uint16", uint16,
             newInt(int64(value)))
defResultVia(geneFfiResultInt32, "gene_ffi_result_int32", int32,
             newInt(int64(value)))
defResultVia(geneFfiResultUInt32, "gene_ffi_result_uint32", uint32,
             newInt(int64(value)))
defResultVia(geneFfiResultInt64, "gene_ffi_result_int64", int64,
             newInt(value))
defResultVia(geneFfiResultUChar, "gene_ffi_result_uchar", uint8,
             newInt(int64(value)))
defResultVia(geneFfiResultShort, "gene_ffi_result_short", cshort,
             newInt(int64(value)))
defResultVia(geneFfiResultUShort, "gene_ffi_result_ushort", cushort,
             newInt(int64(value)))
defResultVia(geneFfiResultInt, "gene_ffi_result_int", cint,
             newInt(int64(value)))
defResultVia(geneFfiResultUInt, "gene_ffi_result_uint", cuint,
             newInt(int64(value)))
defResultVia(geneFfiResultLong, "gene_ffi_result_long", clong,
             newInt(int64(value)))
defResultVia(geneFfiResultPtrdiff, "gene_ffi_result_ptrdiff", GeneCPtrDiff,
             newInt(int64(value)))
defResultVia(geneFfiResultFloat, "gene_ffi_result_float", float32,
             newFloat(float64(value)))
defResultVia(geneFfiResultDouble, "gene_ffi_result_double", float64,
             newFloat(value))
defResultVia(geneFfiResultBool, "gene_ffi_result_bool", bool,
             newBool(value))

## A `C/Char` result is a Gene `Char`, not an Int — the dynamic converter has
## always produced one, and returning an Int here made the same declaration
## yield a different *type* compiled than interpreted.
defResultVia(geneFfiResultChar, "gene_ffi_result_char", cchar,
             ffiCCharResult(value))

## The 64-bit unsigned results promote past `high(int64)` rather than failing:
## `ffiCUInt64Value` widens to a decimal Int, so a legitimate C return above
## 2^63-1 is representable instead of being reported as an error.
defResultVia(geneFfiResultUInt64, "gene_ffi_result_uint64", uint64,
             ffiCUInt64Value(value))
defResultVia(geneFfiResultULong, "gene_ffi_result_ulong", culong,
             ffiCUInt64Value(uint64(value)))
defResultVia(geneFfiResultSize, "gene_ffi_result_size", csize_t,
             ffiCUInt64Value(uint64(value)))

## Copied, not borrowed: the foreign buffer's lifetime is unknown, and a Gene
## Str must stay valid after the call returns. A NULL return raises rather than
## becoming `nil`, so a null-return bug stays a boundary error instead of
## silently entering Gene as a missing value.
defResultVia(geneFfiResultCStr, "gene_ffi_result_cstr", cstring,
             ffiCStrResult(ResultWhere, value))

proc geneFfiResultPtr(ctx: ptr AotContext, value: pointer,
                      typeName, releaseName: cstring,
                      resultOut: ptr Value): cint
                     {.exportc: "gene_ffi_result_ptr", cdecl, dynlib.} =
  ## Delegates to the dynamic path's `ffiPointerResult`, which applies the rule
  ## this helper used to skip: a NULL for a non-nullable declared result is an
  ## error, not `nil`. It also builds the value with the right constructor for
  ## the declared flavor — const, owned, or plain — where this returned a plain
  ## mutable pointer regardless.
  if resultOut == nil:
    return ctx.fail("native entry result slot is null")
  var releaseAddress: pointer
  if releaseName != nil and releaseName[0] != '\0':
    releaseAddress =
      if aotSymbolResolver != nil: aotSymbolResolver($releaseName)
      else: nil
    if releaseAddress == nil:
      return ctx.fail("native entry result declares release '" &
        $releaseName & "' but the symbol was not found in any loaded AOT " &
        "library")
  try:
    resultOut[] = ffiAotPointerResult($typeName, value, releaseAddress)
  except CatchableError as e:
    return ctx.fail(e.msg)
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
                               index: csize_t, handleField: cstring,
                               value: pointer)
                              {.exportc: "gene_typed_native_arg_restore",
                                cdecl, dynlib.} =
  ## Rollback for an entry that failed *after* acquiring this argument.
  ##
  ## A transfer relinquishes the wrapper before the call, so reaching here means
  ## the callee never ran and nobody owns the pointer: the wrapper is closed and
  ## nothing will release it. Give ownership back. A borrow consumed nothing and
  ## is unaffected, which is why this is keyed off the wrapper still being
  ## closed rather than off the ownership mode.
  if call == nil or index >= call.len or value == nil:
    return
  let arg = call.argAt(index)
  if arg.kind != vkNode:
    return
  let handle = arg.props.getOrDefault($handleField, VOID)
  if handle.kind == vkCPtr and handle.cPtrClosed:
    restoreCPtr(handle, value)

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
      # `newCForeignOwnedPtr`, not `newCOwnedPtr`: the shim is a generated C
      # function and therefore `cdecl`, while `CPtrReleaseProc` is `nimcall`.
      # The two coincide on x86-64 SysV and AArch64 and differ elsewhere, so
      # casting one to the other was a latent ABI bug rather than a style nit.
      newCForeignOwnedPtr(address, cast[pointer](release), abiName)
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
