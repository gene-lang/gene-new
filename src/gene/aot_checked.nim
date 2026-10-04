## Included by gir.nim. Lower accepted native syntax into sequenced C statements.
## Integer expressions own exact temporaries; machine representations are checked
## only at annotated bindings, call edges, foreign stores and returns.
type
  CheckedKind = enum ckInteger, ckFloat, ckString, ckPointer, ckNil, ckVoid
  CheckedValue = object
    kind: CheckedKind
    code: string
    cType: string
    tag: string # integer storage can carry a Bool; never confuse false with 0
  CheckedBinding = object
    repr: AotRepr
    code: string
    boxed: bool
    tag: string
    annotated: bool
  CheckedEmitter = object
    fn: FunctionProto
    available: Table[string, AotCFunction]
    structNames: FfiStructCNames
    used: HashSet[string]
    next: int
    error, output, status, cleanup: string
    boundaryName: string
    boundaryLoc: SourceLoc
    declarations, body, integers, scalars: seq[string]
    bindings: Table[string, CheckedBinding]

proc fresh(c: var CheckedEmitter): string =
  while true:
    result = "gene_v_" & $c.next
    inc c.next
    if result notin c.used:
      c.used.incl result
      return

proc line(c: var CheckedEmitter, text: string) = c.body.add "  " & text

proc scalar(c: var CheckedEmitter, kind: CheckedKind, cType: string): CheckedValue =
  result = CheckedValue(kind: kind, code: c.fresh(), cType: cType)
  c.declarations.add "  " & cType & " " & result.code & " = 0;"
  c.scalars.add result.code

proc integer(c: var CheckedEmitter, tag = "GENE_NATIVE_INT"): CheckedValue =
  result = CheckedValue(kind: ckInteger, code: c.fresh(),
                        cType: "GeneNativeInt", tag: tag)
  c.declarations.add "  GeneNativeInt " & result.code & " = {0};"
  c.integers.add result.code

proc flag(c: var CheckedEmitter): string =
  result = c.fresh()
  c.declarations.add "  bool " & result & " = false;"
  c.scalars.add result

proc kindFlag(c: var CheckedEmitter): string =
  result = c.fresh()
  c.declarations.add "  GeneNativeValueKind " & result & " = GENE_NATIVE_INT;"
  c.scalars.add result

proc drop(c: var CheckedEmitter, value: CheckedValue) =
  if value.kind == ckInteger:
    c.line "gene_aot_int_drop(&" & value.code & ");"
  elif value.kind notin {ckVoid, ckNil}:
    c.line "(void)" & value.code & ";"

proc failJump(c: var CheckedEmitter) =
  if c.boundaryName.len > 0:
    c.line "gene_aot_error_frame(" & c.error & ", " & cStringLiteral(c.boundaryName) &
      ", " & cStringLiteral(c.boundaryLoc.sourceName) & ", " &
      $c.boundaryLoc.line & ", " & $c.boundaryLoc.col & ");"
  c.line "goto " & c.cleanup & ";"

proc checkedStatus(c: var CheckedEmitter, call: string) =
  c.line c.status & " = " & call & ";"
  c.line "if (" & c.status & " != GENE_NATIVE_OK) {"
  c.failJump()
  c.line "}"

proc fail(c: var CheckedEmitter, status, where, expected: string) =
  c.line c.status & " = gene_aot_error_set(" & c.error & ", " & status &
    ", " & cStringLiteral(where) & ", " & cStringLiteral(expected) & ");"
  c.failJump()

proc requireInteger(c: var CheckedEmitter, value: CheckedValue, where, expected: string) =
  if value.kind != ckInteger:
    discard aotLoweringGap(c.fn.aotExpr, "non-integer at an integer boundary")
  if value.tag != "GENE_NATIVE_INT":
    c.line "if (" & value.tag & " != GENE_NATIVE_INT) {"
    c.line c.status & " = gene_aot_error_set(" & c.error &
      ", GENE_NATIVE_TYPE_ERROR, " & cStringLiteral(where) & ", " &
      cStringLiteral(expected) & ");"
    c.line c.error & "->actual_kind = " & value.tag & ";"
    c.line "gene_aot_int_copy(&" & c.error & "->actual_int, &" & value.code & ");"
    c.line c.error & "->actual_bool = (" & value.code & ".small != 0);"
    c.failJump()
    c.line "}"

proc machine(c: var CheckedEmitter, value: CheckedValue, repr: AotRepr,
             where: string): string =
  let target = repr.aotCType(c.structNames)
  case repr.kind
  of arkI64, arkI32:
    let label = if repr.kind == arkI64: "I64" else: "I32"
    c.requireInteger(value, where, label)
    let temp = c.scalar(ckInteger, target)
    c.checkedStatus("gene_aot_require_" & label.toLowerAscii & "(" &
      c.error & ", &" & value.code & ", " & cStringLiteral(where) &
      ", &" & temp.code & ")")
    result = temp.code
  of arkF64:
    if value.kind != ckFloat:
      discard aotLoweringGap(c.fn.aotExpr, "non-F64 at an F64 boundary")
    result = value.code
  of arkCStr:
    if value.kind != ckString:
      discard aotLoweringGap(c.fn.aotExpr, "non-Str at a Str boundary")
    c.line "if (" & value.code & " == NULL) {"
    c.fail("GENE_NATIVE_TYPE_ERROR", where, "Str")
    c.line "}"
    result = value.code
  of arkNativePtr:
    if value.kind notin {ckPointer, ckNil}:
      discard aotLoweringGap(c.fn.aotExpr, "non-pointer at a native boundary")
    if not repr.nullable:
      c.line "if (" & value.code & " == NULL) {"
      c.fail("GENE_NATIVE_TYPE_ERROR", where, repr.typeName)
      c.line "}"
    result = value.code
  of arkNone:
    result = value.code

proc truth(value: CheckedValue): string =
  case value.kind
  of ckInteger:
    if value.tag == "GENE_NATIVE_INT" or value.tag == "GENE_NATIVE_CHAR": "true"
    elif value.tag == "GENE_NATIVE_BOOL": "(" & value.code & ".small != 0)"
    else: "(" & value.tag & " != GENE_NATIVE_BOOL || " & value.code & ".small != 0)"
  of ckNil, ckVoid: "false"
  of ckPointer: "(" & value.code & " != NULL)"
  else: "true"

proc nonInteger(value: CheckedValue): string =
  if value.tag == "GENE_NATIVE_INT": "false"
  elif value.tag.startsWith("GENE_NATIVE_"): "true"
  else: "(" & value.tag & " != GENE_NATIVE_INT)"

proc nativeResult(c: var CheckedEmitter, code, cType: string,
                  repr: AotRepr): CheckedValue =
  if repr.kind in {arkI64, arkI32}:
    result = c.integer()
    c.line result.code & " = gene_aot_int((int64_t)(" & code & "));"
  elif repr.kind == arkF64 or cType in ["double", "float"]:
    result = c.scalar(ckFloat, "double")
    c.line result.code & " = " & code & ";"
  elif repr.kind == arkCStr or cType == "const char *":
    result = c.scalar(ckString, "const char *")
    c.line result.code & " = " & code & ";"
  elif cType == "void":
    c.line code & ";"
    result.kind = ckVoid
  elif cType == "bool":
    result = c.integer("GENE_NATIVE_BOOL")
    c.line result.code & " = gene_aot_int(" & code & ");"
  elif cType == "char":
    result = c.integer("GENE_NATIVE_CHAR")
    c.line result.code & " = gene_aot_int((unsigned char)(" & code & "));"
  elif repr.kind == arkNativePtr or '*' in cType:
    result = c.scalar(ckPointer, cType)
    c.line result.code & " = " & code & ";"
  else:
    result = c.integer()
    c.line result.code & " = gene_aot_int((int64_t)(" & code & "));"

proc read(c: var CheckedEmitter, name: string): CheckedValue =
  if not c.bindings.hasKey(name):
    discard aotLoweringGap(newSym(name), "no native binding")
  let binding = c.bindings[name]
  if binding.boxed:
    let copiedFlag = c.kindFlag()
    result = c.integer(copiedFlag)
    c.line "gene_aot_int_copy(&" & result.code & ", &" & binding.code & ");"
    c.line copiedFlag & " = " & binding.tag & ";"
  else:
    result = c.nativeResult(binding.code, binding.repr.aotCType(c.structNames), binding.repr)

proc assign(c: var CheckedEmitter, name: string, value: CheckedValue, where: string) =
  let binding = c.bindings[name]
  if binding.boxed:
    if value.kind != ckInteger:
      discard aotLoweringGap(c.fn.aotExpr, "incompatible inferred local")
    c.line "gene_aot_int_copy(&" & binding.code & ", &" & value.code & ");"
    c.line binding.tag & " = " & value.tag & ";"
  else:
    let converted = c.machine(value, binding.repr, where)
    c.line binding.code & " = " & converted & ";"

proc expression(c: var CheckedEmitter, expr: Value): CheckedValue
proc statement(c: var CheckedEmitter, expr: Value)

proc call(c: var CheckedEmitter, target: AotCFunction,
          args: seq[Value]): CheckedValue =
  var values: seq[CheckedValue]
  # Snapshot all ordinary arguments before validating any call edge. An invalid
  # early argument must not suppress an effect in a later argument expression.
  for i, arg in args:
    if i < target.outParams.len and target.outParams[i]:
      values.add CheckedValue(kind: ckVoid, code: arg.symVal)
    else:
      values.add c.expression(arg)
  var rendered: seq[string]
  var outSlots = initTable[string, tuple[code: string, repr: AotRepr]]()
  var outTypes = initTable[string, AotReprKind]()
  var outOrder: seq[string]
  let previousBoundary = c.boundaryName
  let previousLocation = c.boundaryLoc
  if target.checked:
    c.boundaryName = target.geneName
    c.boundaryLoc = target.sourceLoc
  for i, value in values:
    if i < target.outParams.len and target.outParams[i]:
      let binding = c.bindings[value.code]
      let targetRepr = target.paramReprs[i]
      if outTypes.hasKey(value.code) and outTypes[value.code] != targetRepr.kind:
        discard aotLoweringGap(args[i], "one out binding has incompatible foreign representations")
      outTypes[value.code] = targetRepr.kind
      let sourceType = if binding.boxed: "int64_t" else: binding.repr.aotCType(c.structNames)
      let targetType = targetRepr.aotCType(c.structNames)
      if outSlots.hasKey(value.code):
        let prior = outSlots[value.code]
        if prior.repr.kind != targetRepr.kind:
          discard aotLoweringGap(args[i], "one out binding has incompatible foreign representations")
        rendered.add "&" & prior.code
      elif sourceType != targetType:
        # A wider foreign out slot must not overwrite a narrower Gene binding.
        # Marshal through one shared slot per binding, then check the write-back.
        let snapshot = c.read(value.code)
        let converted = c.machine(snapshot, targetRepr, "parameter '" & target.paramNames[i] & "'")
        let raw = c.scalar(ckPointer, targetType)
        c.line raw.code & " = " & converted & ";"
        c.drop(snapshot)
        outSlots[value.code] = (raw.code, targetRepr)
        outOrder.add value.code
        rendered.add "&" & raw.code
      elif binding.boxed:
        let snapshot = c.read(value.code)
        discard c.machine(snapshot, binding.repr, "parameter '" & target.paramNames[i] & "'")
        c.drop(snapshot)
        rendered.add "&" & binding.code & ".small"
      else:
        rendered.add "&" & binding.code
    else:
      let label = if i < target.paramNames.len: target.paramNames[i] else: "arg" & $i
      rendered.add c.machine(value, target.paramReprs[i], "parameter '" & label & "'")
  while rendered.len < target.paramCount: rendered.add "NULL"
  c.boundaryName = previousBoundary
  c.boundaryLoc = previousLocation
  if target.checked:
    let raw = c.scalar(ckPointer, target.cType)
    c.checkedStatus(target.cName & "(" & (@[c.error] & rendered & @["&" & raw.code]).join(", ") & ")")
    result = c.nativeResult(raw.code, target.cType, target.returnRepr)
  else:
    result = c.nativeResult(target.cName & "(" & rendered.join(", ") & ")",
                            target.cType, target.returnRepr)
  for name in outOrder:
    let slot = outSlots[name]
    let value = c.nativeResult(slot.code, slot.repr.aotCType(c.structNames), slot.repr)
    c.assign(name, value, "set '" & name & "'")
    c.drop(value)
  for value in values: c.drop(value)

proc field(c: var CheckedEmitter, expr: Value, checkNull = true): tuple[base: CheckedValue, access, cType, typeName, name: string] =
  if expr.body.len != 2 or expr.body[0].kind != vkSymbol or expr.body[1].kind != vkSymbol:
    discard aotLoweringGap(expr, "native fields require a binding and a field name")
  let binding = c.bindings[expr.body[0].symVal]
  result.base = c.read(expr.body[0].symVal)
  let name = expr.body[1].symVal
  result.typeName = binding.repr.typeName
  result.name = name
  if checkNull:
    c.line "if (" & result.base.code & " == NULL) {"
    c.fail("GENE_NATIVE_NULL_FIELD", binding.repr.typeName, name)
    c.line "}"
  result.access = result.base.code & "->" & cIdent(name, "field")
  for item in binding.repr.nativeType.abi.fields:
    if item.name == name:
      result.cType = ffiCType(ffiTypeLabel(item.typeExpr))
      return
  discard aotLoweringGap(expr, "unknown native field")

proc expression(c: var CheckedEmitter, expr: Value): CheckedValue =
  case expr.kind
  of vkSymbol: result = c.read(expr.symVal)
  of vkInt:
    result = c.integer()
    let literal = if expr.intVal == low(int64): "(-9223372036854775807LL - 1)" else: $expr.intVal
    c.line "gene_aot_int_drop(&" & result.code & ");"
    c.line result.code & " = gene_aot_int(" & literal & ");"
  of vkFloat:
    result = c.scalar(ckFloat, "double")
    c.line result.code & " = " & expr.print() & ";"
  of vkString:
    result = c.scalar(ckString, "const char *")
    c.line result.code & " = " & cStringLiteral(expr.strVal) & ";"
  of vkNil: result = CheckedValue(kind: ckNil, code: "NULL", cType: "void *")
  of vkNode:
    let mathName = aotMathBuiltinCName(expr.head)
    if mathName.len > 0:
      let argument = c.expression(expr.body[0])
      result = c.scalar(ckFloat, "double")
      c.line result.code & " = " & mathName & "(" & argument.code & ");"
      c.drop(argument)
      return
    if expr.head.kind != vkSymbol: discard aotLoweringGap(expr, "unsupported native call head")
    let head = expr.head.symVal
    if head in ["+", "-", "*", "/", "<", ">", "<=", ">=", "="] and expr.body.len == 2:
      let left = c.expression(expr.body[0])
      let right = c.expression(expr.body[1])
      let comparison = head in ["<", ">", "<=", ">=", "="]
      let op = if head == "=": "==" else: head
      if left.kind == ckInteger and right.kind == ckInteger:
        if comparison:
          if head != "=" and (left.tag != "GENE_NATIVE_INT" or right.tag != "GENE_NATIVE_INT"):
            c.line "if (" & nonInteger(left) & " || " & nonInteger(right) & ") {"
            c.line c.status & " = gene_aot_operator_error(" & c.error & ", " & cStringLiteral(head) & ", " & left.tag & ", " & right.tag & ", true);"
            c.line "goto " & c.cleanup & ";"
            c.line "}"
          result = c.integer("GENE_NATIVE_BOOL")
          c.line "gene_aot_int_drop(&" & result.code & ");"
          let sameKind = if head == "=" and left.tag != right.tag: "(" & left.tag & " == " & right.tag & ") && " else: ""
          c.line result.code & " = gene_aot_int(" & sameKind & "(gene_aot_int_compare(&" & left.code & ", &" & right.code & ") " & op & " 0));"
        else:
          if head == "/": discard aotLoweringGap(expr, "integer division is not lowered")
          if left.tag != "GENE_NATIVE_INT" or right.tag != "GENE_NATIVE_INT":
            c.line "if (" & nonInteger(left) & " || " & nonInteger(right) & ") {"
            c.line c.status & " = gene_aot_operator_error(" & c.error & ", " & cStringLiteral(head) & ", " & left.tag & ", " & right.tag & ", false);"
            c.line "goto " & c.cleanup & ";"
            c.line "}"
          result = c.integer()
          let operation = case head
            of "+": "add"
            of "-": "sub"
            else: "mul"
          c.line "if (!gene_aot_int_" & operation & "(&" & result.code & ", &" & left.code & ", &" & right.code & ")) {"
          c.fail("GENE_NATIVE_NO_MEMORY", "native integer allocation failed", "")
          c.line "}"
      elif left.kind == ckFloat and right.kind == ckFloat:
        if comparison:
          if head != "=":
            c.line "if (isnan(" & left.code & ") || isnan(" & right.code & ")) {"
            c.fail("GENE_NATIVE_ORDER_ERROR", "NaN has no default ordering", "")
            c.line "}"
          result = c.integer("GENE_NATIVE_BOOL")
          c.line "gene_aot_int_drop(&" & result.code & ");"
          c.line result.code & " = gene_aot_int(" & left.code & " " & op & " " & right.code & ");"
        else:
          result = c.scalar(ckFloat, "double")
          c.line result.code & " = " & left.code & " " & op & " " & right.code & ";"
      else: discard aotLoweringGap(expr, "mixed native arithmetic representations")
      c.drop(left)
      c.drop(right)
    elif head == "if":
      let condition = c.expression(expr.body[0])
      let branch = c.flag()
      c.line branch & " = " & truth(condition) & ";"
      c.drop(condition)
      c.line "if (" & branch & ") {"
      let yes = c.expression(expr.body[1])
      if yes.kind == ckInteger:
        result = c.integer(c.kindFlag())
        c.line "gene_aot_int_copy(&" & result.code & ", &" & yes.code & ");"
        c.line result.tag & " = " & yes.tag & ";"
      else:
        result = c.scalar(if yes.kind == ckNil: ckPointer else: yes.kind,
                          if yes.kind == ckNil: "void *" else: yes.cType)
        c.line result.code & " = " & yes.code & ";"
      c.drop(yes)
      c.line "} else {"
      let no = c.expression(expr.body[2])
      if result.kind == ckInteger and no.kind == ckInteger:
        c.line "gene_aot_int_copy(&" & result.code & ", &" & no.code & ");"
        c.line result.tag & " = " & no.tag & ";"
      elif result.kind == no.kind or (result.kind == ckPointer and no.kind == ckNil):
        c.line result.code & " = " & no.code & ";"
      else: discard aotLoweringGap(expr, "incompatible native conditional arms")
      c.drop(no)
      c.line "}"
    elif head == "do":
      for i in 0 ..< expr.body.high: c.statement(expr.body[i])
      result = c.expression(expr.body[^1])
    elif head == "path":
      let access = c.field(expr)
      result = c.nativeResult(access.access, access.cType, AotRepr())
    elif head == "set":
      if expr.body[0].kind == vkSymbol:
        result = c.expression(expr.body[1])
        c.assign(expr.body[0].symVal, result, "set '" & expr.body[0].symVal & "'")
      else:
        let access = c.field(expr.body[0], checkNull = false)
        result = c.expression(expr.body[1])
        c.line "if (" & access.base.code & " == NULL) {"
        c.fail("GENE_NATIVE_NULL_FIELD", access.typeName, access.name)
        c.line "}"
        if result.kind == ckInteger:
          let raw = c.machine(result, AotRepr(kind: arkI64, typeName: "I64"), "native field store")
          c.line access.access & " = " & raw & ";"
        else: c.line access.access & " = " & result.code & ";"
    elif expr.body.len >= 2 and expr.body[0].kind == vkSymbol and expr.body[0].symVal == "~":
      let receiver = c.bindings[head].repr
      let message = expr.body[1]
      let protocol = if message.kind == vkNode: ffiTypeLabel(message.body[0]) else: ""
      let name = if message.kind == vkNode: message.body[1].symVal else: message.symVal
      let key = aotSendKey(receiver.nativeType.identity, protocol, name)
      if not c.available.hasKey(key): discard aotLoweringGap(expr, "no emitted native implementation")
      result = c.call(c.available[key], @[newSym(head)] & expr.body[2 .. ^1])
    elif c.available.hasKey(head):
      result = c.call(c.available[head], expr.body)
    else: discard aotLoweringGap(expr, "unsupported native expression")
  else: discard aotLoweringGap(expr, "unsupported native value")

proc statement(c: var CheckedEmitter, expr: Value) =
  if expr.kind == vkNode and expr.head.kind == vkSymbol:
    let head = expr.head.symVal
    if head in ["var", "let"]:
      let name = expr.body[0].symVal
      var repr: AotRepr
      for local in c.fn.aotLocals:
        if local.name == name: repr = local.repr
      let annotated = expr.body.len == 4 and expr.body[1].kind == vkSymbol and expr.body[1].symVal == ":"
      let initial = c.expression(expr.body[if annotated: 3 else: 1])
      var binding = CheckedBinding(repr: repr, annotated: annotated)
      if not annotated and repr.kind == arkI64:
        let value = c.integer()
        binding.code = value.code
        binding.boxed = true
        binding.tag = c.kindFlag()
      else:
        binding.code = c.scalar(ckPointer, repr.aotCType(c.structNames)).code
      c.bindings[name] = binding
      c.assign(name, initial, "var '" & name & "'")
      c.drop(initial)
      return
    if head == "while":
      c.line "while (true) {"
      let condition = c.expression(expr.body[0])
      let decision = c.flag()
      c.line decision & " = " & truth(condition) & ";"
      c.drop(condition)
      c.line "if (!" & decision & ") break;"
      for i in 1 ..< expr.body.len: c.statement(expr.body[i])
      c.line "}"
      return
    if head == "do":
      for item in expr.body: c.statement(item)
      return
  let value = c.expression(expr)
  c.drop(value)

proc emitCheckedAotFunctionImpl(lines: var seq[string], fn: FunctionProto, cName: string,
                            available: Table[string, AotCFunction],
                            structNames: FfiStructCNames, frameName = "") =
  var c = CheckedEmitter(fn: fn, available: available, structNames: structNames)
  for _, target in available: c.used.incl target.cName
  c.used.incl cName
  c.error = c.fresh()
  c.output = c.fresh()
  c.status = c.fresh()
  c.cleanup = c.fresh()
  var params = @["GeneNativeError *" & c.error]
  for i, name in fn.params:
    let repr = fn.aotParamReprs[i]
    let code = c.fresh()
    params.add repr.aotCType(structNames) & " " & code
    c.bindings[name] = CheckedBinding(repr: repr, code: code, annotated: true)
    c.line "(void)" & code & ";"
    if (repr.kind == arkNativePtr and not repr.nullable) or repr.kind == arkCStr:
      c.line "if (" & code & " == NULL) {"
      c.fail("GENE_NATIVE_TYPE_ERROR", "parameter '" & name & "'", repr.typeName)
      c.line "}"
  params.add fn.aotReturnRepr.aotCType(structNames) & " *" & c.output
  let value = c.expression(fn.aotExpr)
  let returned = c.machine(value, fn.aotReturnRepr, "return from '" & fn.name & "'")
  c.line "*" & c.output & " = " & returned & ";"
  c.drop(value)
  lines.add "GeneNativeStatus " & cName & "(" & params.join(", ") & ") {"
  if frameName.len > 0: lines.add "  (void)&" & frameName & ";"
  lines.add "  if (" & c.error & " == NULL) return GENE_NATIVE_BAD_ARGUMENT;"
  lines.add "  if (" & c.output & " == NULL) return gene_aot_error_set(" & c.error &
    ", GENE_NATIVE_BAD_ARGUMENT, \"native result pointer is NULL\", \"\");"
  lines.add "  if (" & c.error & "->status != GENE_NATIVE_OK) gene_aot_error_clear(" & c.error & ");"
  lines.add "  GeneNativeStatus " & c.status & " = GENE_NATIVE_OK;"
  lines.add c.declarations
  lines.add c.body
  lines.add "  goto " & c.cleanup & ";"
  lines.add c.cleanup & ":;"
  for name in c.integers: lines.add "  gene_aot_int_drop(&" & name & ");"
  for name in c.scalars: lines.add "  (void)" & name & ";"
  lines.add "  if (" & c.status & " != GENE_NATIVE_OK) gene_aot_error_frame(" & c.error & ", " &
    cStringLiteral(fn.name) & ", " & cStringLiteral(fn.sourceLoc.sourceName) & ", " &
    $fn.sourceLoc.line & ", " & $fn.sourceLoc.col & ");"
  lines.add "  return " & c.status & ";"
  lines.add "}"
  lines.add ""

proc emitCheckedAotFunction(lines: var seq[string], fn: FunctionProto, cName: string,
                            available: Table[string, AotCFunction],
                            structNames: FfiStructCNames, frameName = "") =
  try:
    emitCheckedAotFunctionImpl(lines, fn, cName, available, structNames, frameName)
  except GeneError as error:
    raise newException(GeneError, "typed_native function " & fn.name & ": " & error.msg)
