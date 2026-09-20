## Conservative ordinary-error inference over compiled GIR. Working over GIR
## means template macros and $err_msg have already been lowered by the compiler.
## Recursive summaries converge on finite type identities; diagnostics keep
## bounded source edges rather than recursively expanded call-chain strings.

import std/[algorithm, sets, strutils, tables]
import ./[digest, equality, gir, native_errors, printer, types]

proc mergeErrors*(target: var ErrorEffectSummary, source: ErrorEffectSummary) =
  target.open = target.open or source.open
  for item in source.named:
    var found = false
    for existing in target.named:
      if existing.identity == item.identity:
        found = true
        break
    if not found: target.named.add item
  target.named.sort(proc(a, b: ErrorTypeSummary): int = cmp(a.identity, b.identity))

proc joinedErrors*(a, b: ErrorEffectSummary): ErrorEffectSummary =
  result = a
  result.mergeErrors(b)

proc errorCoverageContains*(allowed, actual: ErrorEffectSummary): bool =
  if allowed.open: return true
  if actual.open: return false
  for item in actual.named:
    var found = false
    for candidate in allowed.named:
      if candidate.identity == item.identity or candidate.identity in item.ancestors:
        found = true
        break
    if not found: return false
  true

proc errorCoverageEqual*(a, b: ErrorEffectSummary): bool =
  errorCoverageContains(a, b) and errorCoverageContains(b, a)

proc sameErrorInformation(a, b: ErrorEffectSummary): bool =
  if a.open != b.open or a.named.len != b.named.len: return false
  for i in 0..<a.named.len:
    if a.named[i].identity != b.named[i].identity: return false
  true

proc subtractErrors*(source, caught: ErrorEffectSummary): ErrorEffectSummary =
  if caught.open: return
  result.open = source.open
  for item in source.named:
    if not errorCoverageContains(caught, ErrorEffectSummary(named: @[item])):
      result.named.add item

proc describeErrors*(row: ErrorEffectSummary): string =
  var names: seq[string]
  for item in row.named:
    if item.name notin names: names.add item.name
  if row.open: names.add "Error"
  "[" & names.join(" ") & "]"

type
  AbstractKind = enum
    avUnknown, avScalar, avList, avMap, avRange, avNode, avFunction, avNative,
    avNamespace, avType, avProtocol, avMessage, avSelector, avTask, avStream

  AbstractValue = ref object
    kind: AbstractKind
    typ: Value
    literal: Value
    hasLiteral: bool
    fn: AnalyzedFunction
    name: string
    space: ErrorEnvironment
    nominal: AnalyzedType
    contractKnown: bool
    contract: ErrorEffectSummary
    resultType: Value
    deferredKnown: bool
    deferred: ErrorEffectSummary
    caught: bool
    caughtErrors: ErrorEffectSummary
    target: Value
    dispatchContract: bool
    dispatchTypeDepth: int
    boundMessage: bool
    taskId: string
    taskPrior: bool
    taskFresh: bool
    taskIsolated: bool
    streamTaskSafe: bool
    returnOrigins: seq[ErrorProofDependency]

  ErrorBinding = object
    value: AbstractValue
    immutable: bool
    declaredType: Value

  ErrorEnvironment = ref object
    parent: ErrorEnvironment
    values: Table[string, ErrorBinding]
    source: string
    prefix: string
    hidden: HashSet[string]

  AnalyzedType = ref object
    info: ErrorTypeSummary
    parent: AnalyzedType
    protocolParents: seq[AnalyzedType]
    importedProtocolMembers: seq[AnalyzedFunction]
    methodsKnown: bool
    fields: Table[string, Value]
    methods: Table[string, AnalyzedFunction]
    constructor: AnalyzedFunction
    constructorKnown: bool
    protocol: bool

  AnalyzedFunction = ref object
    proto: FunctionProto
    environment: ErrorEnvironment
    receiver: AnalyzedType
    summary: CallableErrorSummary
    resultValue: AbstractValue
    public: bool
    requirementOnly: bool

  AbstractState = object
    stack: seq[AbstractValue]
    bindings: Table[string, ErrorBinding]
    mayConsumed: HashSet[string]
    knownTasks: HashSet[string]
    initialized: HashSet[string]

  BodyErrors = object
    errors: ErrorEffectSummary
    value: AbstractValue
    finalState: ref AbstractState
    exceptionState: ref AbstractState
    normalExit: bool
    neverReturns: bool
    mayConsumeTasks: bool
    taskCode: bool
    preservedTask: string

  ErrorAnalysisData = object
    root*: Chunk
    functions: seq[AnalyzedFunction]
    byProto: Table[pointer, AnalyzedFunction]
    byChunk: Table[pointer, ErrorEnvironment]
    types: Table[string, AnalyzedType]
    rootEnvironment: ErrorEnvironment
    imported: Table[string, CompileNamespaceInterface]
    diagnostics*: seq[CompileDiagnostic]
    initialized: bool
    collecting: bool
    steps: int
    permitted: ErrorEffectSummary
    currentChunk: Chunk
    publicValues: Table[string, tuple[value: AbstractValue, loc: SourceLoc]]

  ErrorAnalysis* = ref ErrorAnalysisData

proc `=destroy`(analysis: var ErrorAnalysisData) =
  # Inference intentionally connects environments, declarations, and returned
  # abstract values in both directions. Those temporary cycles must be broken
  # when analysis finishes, including in atomicArc builds without cycle GC.
  # Published summaries and bytecode are independent and remain untouched.
  var seen = initHashSet[pointer]()
  var environments: seq[ErrorEnvironment]
  var functions: seq[AnalyzedFunction]
  var types: seq[AnalyzedType]
  var values: seq[AbstractValue]
  proc visit(value: AbstractValue)
  proc visit(environment: ErrorEnvironment)
  proc visit(function: AnalyzedFunction)
  proc visit(typ: AnalyzedType)
  proc visit(value: AbstractValue) =
    if value == nil or seen.containsOrIncl(cast[pointer](value)): return
    values.add value
    visit(value.fn)
    visit(value.space)
    visit(value.nominal)
  proc visit(environment: ErrorEnvironment) =
    if environment == nil or seen.containsOrIncl(cast[pointer](environment)): return
    environments.add environment
    visit(environment.parent)
    for binding in environment.values.values: visit(binding.value)
  proc visit(function: AnalyzedFunction) =
    if function == nil or seen.containsOrIncl(cast[pointer](function)): return
    functions.add function
    visit(function.environment)
    visit(function.receiver)
    visit(function.resultValue)
  proc visit(typ: AnalyzedType) =
    if typ == nil or seen.containsOrIncl(cast[pointer](typ)): return
    types.add typ
    visit(typ.parent)
    for parent in typ.protocolParents: visit(parent)
    for function in typ.methods.values: visit(function)
    for function in typ.importedProtocolMembers: visit(function)
    visit(typ.constructor)
  visit(analysis.rootEnvironment)
  for environment in analysis.byChunk.values: visit(environment)
  for function in analysis.functions: visit(function)
  for function in analysis.byProto.values: visit(function)
  for typ in analysis.types.values: visit(typ)
  for item in analysis.publicValues.values: visit(item.value)
  for value in values:
    value.fn = nil
    value.space = nil
    value.nominal = nil
  for function in functions:
    function.environment = nil
    function.receiver = nil
    function.resultValue = nil
  for environment in environments:
    environment.parent = nil
    environment.values.clear()
  for typ in types:
    typ.parent = nil
    typ.protocolParents = @[]
    typ.methods.clear()
    typ.importedProtocolMembers = @[]
    typ.constructor = nil
  for _, field in fieldPairs(analysis):
    `=destroy`(field)

proc unknownValue(): AbstractValue = AbstractValue(kind: avUnknown)
proc scalarValue(name: string): AbstractValue =
  AbstractValue(kind: avScalar, typ: newSym(name))

proc copyValue(value: AbstractValue): AbstractValue =
  if value == nil: return unknownValue()
  result = AbstractValue()
  result[] = value[]

proc builtinError(name: string): ErrorTypeSummary =
  result = ErrorTypeSummary(identity: "builtin:" & name, name: name, expr: newSym(name))
  case name
  of "MessageError", "CallKindError": result.ancestors = @["builtin:TypeError"]
  of "SelectorMissing": result.ancestors = @["builtin:MatchError"]
  else: discard

proc oneError(name: string): ErrorEffectSummary =
  ErrorEffectSummary(named: @[builtinError(name)])

proc lookup(environment: ErrorEnvironment, name: string): ErrorBinding =
  var current = environment
  while current != nil:
    if current.values.hasKey(name): return current.values[name]
    current = current.parent

proc newErrorEnvironment(parent: ErrorEnvironment, source, prefix: string): ErrorEnvironment =
  ErrorEnvironment(parent: parent, values: initTable[string, ErrorBinding](),
                    source: source, prefix: prefix)

proc literalValue(value: Value): AbstractValue =
  result = AbstractValue(hasLiteral: true, literal: value)
  case value.kind
  of vkNil: result.kind = avScalar; result.typ = newSym("Nil")
  of vkVoid: result.kind = avScalar; result.typ = newSym("Void")
  of vkBool: result.kind = avScalar; result.typ = newSym("Bool")
  of vkInt: result.kind = avScalar; result.typ = newSym("Int")
  of vkFloat: result.kind = avScalar; result.typ = newSym("Float")
  of vkString: result.kind = avScalar; result.typ = newSym("Str")
  of vkChar: result.kind = avScalar; result.typ = newSym("Char")
  of vkList: result.kind = avList; result.typ = newSym("List")
  of vkMap: result.kind = avMap; result.typ = newSym("PropMap")
  of vkRange:
    result.kind = avRange
    result.typ = newSym("Range")
    result.resultType = newSym("Int")
  of vkNode:
    result.kind = if value.head.kind == vkSymbol and value.head.symVal == "select":
                    avSelector else: avNode
  else: result.kind = avUnknown

proc resolveType(analysis: ErrorAnalysis, expr: Value,
                  environment: ErrorEnvironment, depth = 0): AnalyzedType =
  if depth > 64: return nil
  if expr.kind == vkSymbol:
    if '/' in expr.symVal:
      var path: seq[Value]
      for part in expr.symVal.split('/'): path.add newSym(part)
      return analysis.resolveType(newNode(newSym("path"), body = path), environment, depth + 1)
    let binding = environment.lookup(expr.symVal)
    if binding.value != nil:
      if binding.value.nominal != nil and binding.value.kind in {avType, avProtocol}:
        return binding.value.nominal
      if binding.value.hasLiteral and binding.value.literal.bits != expr.bits:
        return analysis.resolveType(binding.value.literal, environment, depth + 1)
    if analysis.types.hasKey("builtin:" & expr.symVal):
      return analysis.types["builtin:" & expr.symVal]
  elif expr.kind == vkNode and expr.head.kind == vkSymbol and expr.head.symVal == "path":
    var current = environment
    for i, part in expr.body:
      if part.kind != vkSymbol: return nil
      if i > 0 and part.symVal in current.hidden: return nil
      let binding = if i == 0: current.lookup(part.symVal)
                    else: current.values.getOrDefault(part.symVal)
      if binding.value == nil: return nil
      if i == expr.body.high:
        if binding.value.kind in {avType, avProtocol}: return binding.value.nominal
        return nil
      if binding.value.space == nil: return nil
      current = binding.value.space

proc rowFromTypes(analysis: ErrorAnalysis, expressions: openArray[Value],
                   environment: ErrorEnvironment): ErrorEffectSummary =
  var collected: ErrorEffectSummary
  proc add(expr: Value, depth: int) =
    if depth > 64:
      collected.named.add ErrorTypeSummary(identity: "unresolved:recursive-alias",
                                             name: "recursive alias", expr: expr)
      return
    if expr.kind == vkSymbol:
      let binding = environment.lookup(expr.symVal)
      if binding.value != nil:
        if binding.value.hasLiteral and binding.value.literal.bits != expr.bits:
          add(binding.value.literal, depth + 1)
          return
        if binding.value.nominal == nil and binding.value.name == "Never": return
        if binding.value.kind == avProtocol and binding.value.nominal == nil and
            binding.value.name == "Error":
          collected.open = true
          return
    if expr.kind == vkNode and expr.head.kind == vkSymbol and expr.head.symVal == "|":
      for item in expr.body: add(item, depth + 1)
      return
    let resolved = analysis.resolveType(expr, environment)
    if resolved != nil:
      var info = resolved.info
      # The identity is the declaration's; a runtime proof must resolve the
      # spelling visible in this scope (including an import rename).
      if not (expr.kind == vkSymbol and expr.symVal == "Self"): info.expr = expr
      collected.mergeErrors(ErrorEffectSummary(named: @[info]))
    else:
      collected.mergeErrors(ErrorEffectSummary(named: @[ErrorTypeSummary(
        identity: "unresolved:" & environment.source & ":" & expr.print(),
        name: expr.print(), expr: expr)]))
  for expr in expressions: add(expr, 0)
  collected

proc localizeErrors(analysis: ErrorAnalysis, row: ErrorEffectSummary,
                    environment: ErrorEnvironment): ErrorEffectSummary =
  result = row
  for item in result.named.mitems:
    let current = analysis.resolveType(item.expr, environment)
    if current != nil and current.info.identity == item.identity: continue
    var scope = environment
    var shadowed = initHashSet[string]()
    var found = false
    while scope != nil and not found:
      var names: seq[string]
      for name in scope.values.keys: names.add name
      names.sort()
      for name in names:
        if shadowed.containsOrIncl(name) or name == "Self": continue
        let value = scope.values[name].value
        if value != nil and value.nominal != nil and value.nominal.info.identity == item.identity:
          item.expr = newSym(name)
          found = true
          break
      scope = scope.parent

proc valueFromType(analysis: ErrorAnalysis, typ: Value,
                    environment: ErrorEnvironment): AbstractValue =
  result = unknownValue()
  result.typ = typ
  if typ.kind == vkSymbol:
    if typ.symVal in ["Int", "I64", "I32", "Float", "F64", "Bool", "Str", "Nil", "Void", "Char"]:
      result.kind = avScalar
    elif typ.symVal == "List": result.kind = avList
    elif typ.symVal == "Range":
      result.kind = avRange
      result.resultType = newSym("Int")
    elif typ.symVal in ["PropMap", "Map"]: result.kind = avMap
    elif typ.symVal == "Task": result.kind = avTask
    elif typ.symVal == "Stream": result.kind = avStream
    elif typ.symVal in ["Fn", "Callable"]: result.kind = avFunction
    elif typ.symVal == "Error": result.kind = avNode
    else:
      result.nominal = analysis.resolveType(typ, environment)
      if result.nominal != nil: result.kind = avNode
  elif typ.kind == vkNode and typ.head.kind == vkSymbol:
    case typ.head.symVal
    of "path":
      result.nominal = analysis.resolveType(typ, environment)
      if result.nominal != nil: result.kind = avNode
    of "Callable", "Fn":
      result.kind = avFunction
      if typ.props.hasKey("errors") and typ.props["errors"].kind == vkList:
        result.contractKnown = true
        result.contract = analysis.rowFromTypes(typ.props["errors"].listItems, environment)
      if typ.body.len >= 2: result.resultType = typ.body[1]
    of "Task", "Stream":
      result.kind = if typ.head.symVal == "Task": avTask else: avStream
      if typ.body.len > 0: result.resultType = typ.body[0]
      if typ.body.len > 1:
        result.deferredKnown = true
        result.deferred = analysis.rowFromTypes([typ.body[1]], environment)
    of "List":
      result.kind = avList
      if typ.body.len > 0: result.resultType = typ.body[0]
    of "Map", "PropMap":
      result.kind = avMap
      if typ.body.len > 0: result.resultType = typ.body[^1]
    else: discard

proc effectiveRow(value: AbstractValue): ErrorEffectSummary =
  if value == nil: return ErrorEffectSummary(open: true)
  if value.contractKnown: result = value.contract
  elif value.fn != nil:
    if value.fn.summary.declared: result = value.fn.summary.declaredRow
    elif value.fn.requirementOnly: result.open = true
    else: result = value.fn.summary.inferredRow
  else: result.open = true
  if value.boundMessage:
    # A held message resolves its receiver in the scope captured at binding.
    # Its protocol row describes the selected implementation, not failed lookup.
    result.mergeErrors(oneError("MessageError"))

proc deferredRow(value: AbstractValue): ErrorEffectSummary =
  if value != nil and value.deferredKnown: value.deferred
  else: ErrorEffectSummary(open: true)

proc location(chunk: Chunk, index: int): SourceLoc =
  if index >= 0 and index < chunk.instructionLocs.len: chunk.instructionLocs[index]
  else: SourceLoc(sourceName: chunk.sourceName)

proc registerFunction(analysis: ErrorAnalysis, proto: FunctionProto,
                       environment: ErrorEnvironment, public = false,
                       receiver: AnalyzedType = nil,
                       requirementOnly = false): AnalyzedFunction =
  if proto == nil: return nil
  var declaration = environment
  if receiver != nil:
    declaration = newErrorEnvironment(environment, environment.source, environment.prefix)
    declaration.values["Self"] = ErrorBinding(immutable: true,
      value: AbstractValue(kind: avType, nominal: receiver, name: receiver.info.name,
                            typ: receiver.info.expr))
  let key = cast[pointer](proto)
  if analysis.byProto.hasKey(key):
    result = analysis.byProto[key]
    result.environment = declaration
    result.public = result.public or public
    return
  let identity = environment.source & "::" & environment.prefix & "/" & proto.name &
    "@" & $proto.sourceLoc.line & ":" & $proto.sourceLoc.col & ":" & $analysis.functions.len
  let summary = CallableErrorSummary(name: proto.name, identity: identity, declared: proto.checksErrors,
    resultType: proto.returnType, version: analysis.root.errorSummaryVersion)
  if receiver != nil: summary.receiverType = receiver.info
  result = AnalyzedFunction(proto: proto, environment: declaration,
    summary: summary, receiver: receiver, public: public,
    requirementOnly: requirementOnly, resultValue: unknownValue())
  analysis.byProto[key] = result
  analysis.functions.add result
  proto.errorSummary = summary

proc newErrorAnalysis*(root: Chunk,
    imported = initTable[string, CompileNamespaceInterface]()): ErrorAnalysis =
  result = ErrorAnalysis(root: root, imported: imported,
    byProto: initTable[pointer, AnalyzedFunction](),
    byChunk: initTable[pointer, ErrorEnvironment](),
    types: initTable[string, AnalyzedType]())
  let builtins = newErrorEnvironment(nil, "builtin", "")
  for name in ["RuntimeError", "TypeError", "ErrorContractViolation", "AssertionError",
               "MatchError", "SelectorMissing", "CompileError", "CallKindError",
               "MessageError", "ParseError",
               "JsonError", "OsError", "DbError", "EndOfStream"]:
    let typ = AnalyzedType(info: builtinError(name), constructorKnown: true, methodsKnown: true,
      fields: initTable[string, Value](), methods: initTable[string, AnalyzedFunction]())
    typ.fields["message"] = newSym("Str")
    result.types[typ.info.identity] = typ
    builtins.values[name] = ErrorBinding(immutable: true,
      value: AbstractValue(kind: avType, nominal: typ, name: name))
  for name in ["Int", "Str", "Bool", "Float", "F64", "I64", "I32", "Nil", "Void",
               "Any", "Never", "List", "Map", "PropMap", "Range", "Callable", "Fn", "Task", "Stream"]:
    builtins.values[name] = ErrorBinding(immutable: true,
      value: AbstractValue(kind: avType, name: name, typ: newSym(name)))
  builtins.values["Error"] = ErrorBinding(immutable: true,
    value: AbstractValue(kind: avProtocol, name: "Error"))
  let errorProtocol = AnalyzedType(info: builtinError("Error"), protocol: true,
    methodsKnown: true, methods: initTable[string, AnalyzedFunction]())
  errorProtocol.methods["message"] = AnalyzedFunction(environment: builtins,
    requirementOnly: true, public: true, resultValue: scalarValue("Str"),
    summary: CallableErrorSummary(name: "message", identity: "builtin:Error/message",
      declared: true, resultType: newSym("Str")))
  result.types["builtin:Error"] = errorProtocol
  for name in ["+", "-", "*", "/", "//", "==", "!=", "<", ">", "<=", ">=", "$", "same?", "not", "|"]:
    builtins.values[name] = ErrorBinding(immutable: true,
      value: AbstractValue(kind: avNative, name: name))
  builtins.values["gene"] = ErrorBinding(immutable: true,
    value: AbstractValue(kind: avNamespace, name: "gene"))
  result.rootEnvironment = newErrorEnvironment(builtins, root.sourceName, "")

proc bindValue(environment: ErrorEnvironment, name: string, value: AbstractValue,
                immutable = true, declaredType = NIL) =
  environment.values[name] = ErrorBinding(value: value, immutable: immutable,
                                           declaredType: declaredType)

proc at(state: AbstractState, environment: ErrorEnvironment, name: string): ErrorBinding =
  if state.bindings.hasKey(name): state.bindings[name]
  else: environment.lookup(name)

proc valueKey(value: AbstractValue): string =
  if value == nil: return "unknown"
  result = $value.kind & ":" & value.name & ":" & value.typ.print() &
    ":" & $value.contractKnown & ":" & describeErrors(value.contract) &
    ":" & $value.deferredKnown & ":" & describeErrors(value.deferred) &
    ":" & $value.caught & ":" & describeErrors(value.caughtErrors) & ":" & value.taskId
  result.add ":target=" & value.target.print()
  result.add ":bound-message=" & $value.boundMessage
  result.add ":task-state=" & $value.taskPrior & ":" & $value.taskFresh
  result.add ":task-code=" & $value.taskIsolated & ":" & $value.streamTaskSafe
  if value.fn != nil: result.add ":fn=" & value.fn.summary.identity
  if value.nominal != nil: result.add ":type=" & value.nominal.info.identity
  if value.hasLiteral: result.add ":literal=" & value.literal.print()
  for origin in value.returnOrigins:
    result.add ":return=" & origin.target.print() & ":" & $origin.returnDepth & ":" & origin.returnKind

proc mergeValue(a, b: AbstractValue): AbstractValue =
  if valueKey(a) == valueKey(b): return a
  if a == nil or b == nil or a.kind != b.kind: return unknownValue()
  result = copyValue(a)
  result.taskPrior = a.taskPrior or b.taskPrior
  result.taskFresh = a.taskFresh and b.taskFresh
  result.taskIsolated = a.taskIsolated and b.taskIsolated
  result.streamTaskSafe = a.streamTaskSafe and b.streamTaskSafe
  result.boundMessage = a.boundMessage or b.boundMessage
  proc addOrigin(origins: var seq[ErrorProofDependency], origin: ErrorProofDependency) =
    for existing in origins:
      if existing.returnDepth == origin.returnDepth and existing.returnKind == origin.returnKind and
          equal(existing.target, origin.target): return
    origins.add origin
  if a.kind in {avFunction, avMessage} and not equal(a.target, b.target):
    for candidate in [a, b]:
      if candidate.target.kind != vkNil:
        result.returnOrigins.addOrigin(ErrorProofDependency(target: candidate.target,
          producer: if candidate.fn != nil: candidate.fn.summary.identity else: candidate.name,
          returnKind: "callable"))
  for origin in b.returnOrigins:
    result.returnOrigins.addOrigin(origin)
  result.hasLiteral = false
  if not equal(a.typ, b.typ): result.typ = NIL
  if a.fn != b.fn: result.fn = nil
  if a.nominal != b.nominal: result.nominal = nil
  if a.name != b.name: result.name = ""
  if a.space != b.space: result.space = nil
  result.contractKnown = a.contractKnown and b.contractKnown
  result.contract.mergeErrors(b.contract)
  if a.kind in {avFunction, avMessage} and
      (a.contractKnown or (a.fn != nil and a.fn.summary.declared)) and
      (b.contractKnown or (b.fn != nil and b.fn.summary.declared)):
    result.contractKnown = true
    result.contract = joinedErrors(a.effectiveRow(), b.effectiveRow())
  result.deferredKnown = a.deferredKnown and b.deferredKnown
  result.deferred.mergeErrors(b.deferred)
  result.caught = a.caught and b.caught
  result.caughtErrors.mergeErrors(b.caughtErrors)
  if a.taskId != b.taskId: result.taskId = ""
  if a.target.bits != b.target.bits: result.target = NIL

proc mergeState(target: var AbstractState, source: AbstractState): bool =
  if target.stack.len != source.stack.len:
    let n = max(target.stack.len, source.stack.len)
    if target.stack.len != n:
      target.stack.setLen(n)
      result = true
    for value in target.stack.mitems:
      if valueKey(value) != valueKey(unknownValue()):
        value = unknownValue()
        result = true
  else:
    for i in 0..<target.stack.len:
      let merged = mergeValue(target.stack[i], source.stack[i])
      if valueKey(merged) != valueKey(target.stack[i]):
        target.stack[i] = merged
        result = true
  for name, binding in source.bindings:
    if not target.bindings.hasKey(name):
      target.bindings[name] = binding
      result = true
    else:
      var old = target.bindings[name]
      let merged = mergeValue(old.value, binding.value)
      if valueKey(old.value) != valueKey(merged):
        old.value = merged
        target.bindings[name] = old
        result = true
  let mayConsumed = target.mayConsumed + source.mayConsumed
  if mayConsumed != target.mayConsumed:
    target.mayConsumed = mayConsumed
    result = true
  let knownTasks = target.knownTasks + source.knownTasks
  if knownTasks != target.knownTasks:
    target.knownTasks = knownTasks
    result = true
  var initialized = initHashSet[string]()
  for name in target.initialized:
    if name in source.initialized: initialized.incl name
  if initialized != target.initialized:
    target.initialized = initialized
    result = true

proc pop(state: var AbstractState): AbstractValue =
  if state.stack.len == 0: return unknownValue()
  state.stack.pop()

proc numeric(value: AbstractValue): bool =
  value != nil and value.typ.kind == vkSymbol and
    value.typ.symVal in ["Int", "I64", "I32", "Float", "F64"]

proc literalInt64(value: AbstractValue, integer: var int64): bool =
  if value == nil or not value.hasLiteral or value.literal.kind != vkInt: return false
  try:
    integer = value.literal.intVal
    true
  except FieldDefect:
    false

proc analyzeBody(analysis: ErrorAnalysis, chunk: Chunk, environment: ErrorEnvironment,
                  function: AnalyzedFunction = nil, depth = 0,
                  permitted = ErrorEffectSummary(open: true),
                  initialState: ptr AbstractState = nil): BodyErrors

proc addErrorDependency(analysis: ErrorAnalysis, dependency: ErrorProofDependency,
                         function: AnalyzedFunction) =
  if dependency.permitted.open: return
  if function != nil:
    for existing in function.summary.dependencies:
      if existing.loc == dependency.loc and equal(existing.target, dependency.target) and
          existing.returnDepth == dependency.returnDepth and existing.returnKind == dependency.returnKind and
          existing.returnKindOnly == dependency.returnKindOnly and
          existing.returnTaskFresh == dependency.returnTaskFresh and
          existing.returnTaskIsolated == dependency.returnTaskIsolated and
          existing.returnNativeMetadata == dependency.returnNativeMetadata and
          existing.returnTypeIdentity == dependency.returnTypeIdentity and
          existing.returnTypeContract == dependency.returnTypeContract and
          existing.returnMessageIdentity == dependency.returnMessageIdentity and
          existing.typeIdentityOnly == dependency.typeIdentityOnly:
        return
    function.summary.dependencies.add dependency
  elif analysis.currentChunk != nil:
    analysis.currentChunk.errorProofDependencies.add dependency

proc retainTypeReferences(analysis: ErrorAnalysis, expression: Value,
                           environment: ErrorEnvironment, function: AnalyzedFunction,
                           loc: SourceLoc, permitted: ErrorEffectSummary) =
  if permitted.open: return
  case expression.kind
  of vkSymbol:
    var name = expression.symVal
    if name.endsWith("?"): name.setLen(name.len - 1)
    if name == "Self": return # bound to the declaring receiver by the runtime
    let value = environment.lookup(name).value
    if value != nil and value.kind == avType and value.nominal == nil and value.name == name:
      return # built-in annotation terms do not use lexical type lookup
    let resolved = analysis.resolveType(newSym(name), environment)
    if (value != nil and (value.kind in {avType, avProtocol} or
        (value.hasLiteral and value.literal.kind in {vkSymbol, vkNode}))) or resolved != nil:
      var target = newSym(name)
      if '/' in name:
        var parts: seq[Value]
        for part in name.split('/'): parts.add newSym(part)
        target = newNode(newSym("path"), body = parts)
      analysis.addErrorDependency(ErrorProofDependency(target: target,
        typeIdentityOnly: true, loc: loc), function)
  of vkList:
    for item in expression.listItems:
      analysis.retainTypeReferences(item, environment, function, loc, permitted)
  of vkNode:
    if expression.head.kind == vkSymbol and expression.head.symVal == "path":
      if analysis.resolveType(expression, environment) != nil:
        analysis.addErrorDependency(ErrorProofDependency(target: expression,
          typeIdentityOnly: true, loc: loc), function)
    else:
      for item in expression.body:
        analysis.retainTypeReferences(item, environment, function, loc, permitted)
      for _, item in expression.props:
        analysis.retainTypeReferences(item, environment, function, loc, permitted)
  else: discard

proc retainReturnedErrors(analysis: ErrorAnalysis, value: AbstractValue,
                           kind: string, function: AnalyzedFunction, loc: SourceLoc,
                           kindOnly = false) =
  if value == nil or analysis.permitted.open: return
  for origin in value.returnOrigins:
    if kindOnly and origin.returnKind.len > 0:
      continue # an adapter's callback does not determine the adapter's kind
    var dependency = origin
    dependency.returnKind = if origin.returnKind.len > 0: origin.returnKind else: kind
    if dependency.returnKind == "callable" and origin.returnDepth > 0:
      for producer in analysis.functions:
        if producer.summary.identity != origin.producer or
            producer.summary.returnContracts.len < origin.returnDepth: continue
        let contract = producer.summary.returnContracts[origin.returnDepth - 1]
        if contract.kind == "native":
          dependency.returnKind = "native"
          dependency.returnNativeMetadata = contract.nativeMetadata
        elif contract.kind == "type":
          dependency.returnKind = "type"
          dependency.returnTypeIdentity = contract.typeIdentity
          dependency.returnTypeContract = contract.typeContract
        elif contract.kind == "message":
          dependency.returnKind = "message"
          dependency.returnMessageIdentity = contract.messageIdentity
        break
    if dependency.returnDepth == 0: dependency.returnKind = ""
    dependency.returnKindOnly = kindOnly
    dependency.returnTaskFresh = kind == "task" and value.taskFresh
    dependency.returnTaskIsolated = kind == "task" and value.taskIsolated
    dependency.permitted = analysis.permitted
    dependency.loc = loc
    analysis.addErrorDependency(dependency, function)

proc callValue(analysis: ErrorAnalysis, callee: AbstractValue,
                args: seq[AbstractValue], environment: ErrorEnvironment,
                function: AnalyzedFunction, loc: SourceLoc,
                constructorCall = false, namedCount = 0): BodyErrors =
  result.value = unknownValue()
  result.mayConsumeTasks = true
  if callee == nil:
    result.errors.open = true
    return
  analysis.retainReturnedErrors(callee, "callable", function, loc)
  if not analysis.permitted.open and callee.target.kind != vkNil and
      callee.kind in {avFunction, avNative, avMessage, avType}:
    let dependency = ErrorProofDependency(target: callee.target,
      nativeMetadata: if callee.kind == avNative: builtinNativeErrorMetadata(callee.name)
                      else: NativeErrorMetadata(),
      constructorCall: constructorCall,
      messageName: if not callee.dispatchContract: ""
                   elif callee.kind == avNative: callee.name.split('/')[^1]
                   else: callee.name,
      typeDepth: callee.dispatchTypeDepth,
      producer: if callee.fn != nil: callee.fn.summary.identity else: callee.name,
      permitted: analysis.permitted, loc: loc)
    analysis.addErrorDependency(dependency, function)
  if callee.kind in {avFunction, avMessage}:
    result.errors = callee.effectiveRow()
    if callee.boundMessage and args.len == 0:
      result.errors.mergeErrors(oneError("RuntimeError"))
      return
    if callee.fn != nil:
      let target = callee.fn
      if target.proto != nil and target.proto.isGenerator:
        result.value = analysis.valueFromType(target.proto.returnType, target.environment)
        result.value.kind = avStream
        if not result.value.deferredKnown:
          result.value.deferred = target.summary.producerRow
          result.value.deferred.open = true
          result.value.deferredKnown = true
      elif target.proto != nil and target.proto.hasReturnType:
        result.value = analysis.valueFromType(target.proto.returnType, target.environment)
      elif not target.public and not callee.dispatchContract:
        result.value = copyValue(target.resultValue)
        # Only result kinds with retained proof contracts may cross an
        # unannotated factory boundary. Scalar/container shape and element
        # types are otherwise replaceable without an enforced return check.
        case result.value.kind
        of avFunction, avMessage, avNative, avType: discard
        of avTask, avStream: result.value.resultType = NIL
        else: result.value = unknownValue()
        # Inert-stream facts are local analysis facts, not part of a factory's
        # replaceable return contract. Consuming an inferred stream may run code.
        result.value.streamTaskSafe = false
        # A name inside the producer's activation is not a name in its caller.
        # Retain the producer/result path instead of reusing that local target.
        result.value.target = NIL
        result.value.returnOrigins = @[]
        if callee.target.kind != vkNil:
          result.value.returnOrigins.add ErrorProofDependency(target: callee.target,
            producer: target.summary.identity, returnDepth: 1)
        if target.summary.returnContracts.len > 0:
          let contract = target.summary.returnContracts[0]
          if result.value.kind in {avFunction, avMessage}:
            result.value.contractKnown = contract.errorsKnown
            result.value.contract = contract.errors
          elif result.value.kind in {avTask, avStream}:
            result.value.deferredKnown = contract.errorsKnown
            result.value.deferred = contract.errors
            if result.value.kind == avTask: result.value.taskFresh = contract.taskFresh
            if result.value.kind == avTask: result.value.taskIsolated = contract.taskIsolated
      else:
        result.value = analysis.valueFromType(target.summary.resultType, target.environment)
      if function != nil and function.summary.origins.len < 128:
        let origin = ErrorOrigin(declaration: function.summary.identity,
                                  callee: target.summary.identity, loc: loc)
        if origin notin function.summary.origins: function.summary.origins.add origin
      let freshTask = result.value.kind == avTask and result.value.taskFresh
      let site = loc.sourceName & ":" & $loc.line & ":" & $loc.col
      if freshTask:
        result.value.taskId = "call-task:" & site
      elif result.value.kind == avTask:
        result.value.taskId = ""
    elif callee.resultType.kind != vkNil:
      result.value = analysis.valueFromType(callee.resultType, environment)
    # A returned callable's explicit result annotation can also change when
    # its unannotated factory is replaced. Keep the path through that boundary.
    for origin in callee.returnOrigins:
      if origin.returnDepth >= MaxInferredReturnDepth:
        result.value = unknownValue()
        break
      var next = origin
      inc next.returnDepth
      next.returnKind = ""
      result.value.returnOrigins.add next
    return
  if callee.kind == avType:
    result.mayConsumeTasks = constructorCall
    if callee.nominal != nil:
      if constructorCall:
        var owner = callee.nominal
        while owner.constructor == nil and owner.parent != nil:
          owner = owner.parent
        if owner.constructor != nil:
          let constructed = analysis.callValue(AbstractValue(kind: avFunction,
            fn: owner.constructor), args, environment, function, loc)
          result.errors = constructed.errors
        elif owner.constructorKnown:
          result.errors = oneError("RuntimeError") # new T without a ctor
        else:
          result.errors.open = true
      result.value = AbstractValue(kind: avNode, nominal: callee.nominal,
                                    typ: callee.nominal.info.expr)
    elif callee.name in ["Callable", "Fn"] and args.len >= 1:
      result.value = AbstractValue(kind: avType, name: callee.name)
    else:
      result.value = analysis.valueFromType(callee.typ, environment)
      if constructorCall: result.errors.open = true
    return
  if callee.kind != avNative:
    result.errors.open = true
    return
  let native = builtinNativeErrorMetadata(callee.name)
  if native.identity.len > 0: result.mayConsumeTasks = false
  if native.identity.len > 0 and not native.nativeErrorAcceptsCall(args.len, namedCount):
    result.errors = oneError("RuntimeError")
    return
  let name = if native.identity.len > 0: native.identity[5..^1]
             elif callee.name.startsWith("gene/"): callee.name[5..^1]
             else: callee.name
  case name
  of "assert", "test/assert_equal":
    result.errors = oneError("AssertionError")
    result.value = scalarValue("Nil")
    if name == "assert" and args[0].hasLiteral and not args[0].literal.isTruthy:
      result.neverReturns = true
  of "test/assert_raises":
    result.errors = oneError("AssertionError")
    if args.len > 1:
      var caught = ErrorEffectSummary(open: args[1].name == "Error")
      if args[1].nominal != nil: caught.named.add args[1].nominal.info
      result.errors.mergeErrors(subtractErrors(args[0].effectiveRow(), caught))
      result.value = AbstractValue(kind: avNode, caught: true,
        caughtErrors: args[0].effectiveRow())
  of "==", "!=", "same?", "not", "nil?", "void?", "present?":
    result.value = scalarValue("Bool")
  of "+", "-", "*", "<", ">", "<=", ">=":
    var allNumeric = true
    for arg in args: allNumeric = allNumeric and arg.numeric
    if not allNumeric: result.errors.open = true
    result.value = if name in ["<", ">", "<=", ">="]: scalarValue("Bool")
                   else: scalarValue("Int")
  of "/", "//":
    result.errors = oneError("RuntimeError")
    result.value = scalarValue("Int")
  of "$", "to_str":
    for arg in args:
      if arg.kind != avScalar: result.errors.open = true
    result.value = scalarValue("Str")
  of "range":
    # Runtime Range accepts int64 bounds and a nonzero int64 step. Int itself
    # is arbitrary precision, so an unconstrained Int parameter is insufficient
    # to prove construction infallible even when the step defaults to one.
    var valid = args.len in 2..4
    for i in 0..<min(args.len, 3):
      let argument = args[i]
      var integer = argument.typ.kind == vkSymbol and argument.typ.symVal in ["I32", "I64"]
      var value: int64
      if argument.hasLiteral:
        integer = argument.literalInt64(value) and (i != 2 or value != 0)
      elif i == 2:
        integer = false # an unknown step can be zero
      valid = valid and integer
    if args.len == 4:
      valid = valid and args[3].typ.kind == vkSymbol and args[3].typ.symVal == "Bool"
    if not valid: result.errors = oneError("RuntimeError")
    result.value = AbstractValue(kind: avRange, typ: newSym("Range"),
                                  resultType: newSym("Int"))
  of "to_stream":
    if args.len != 1: result.errors = oneError("RuntimeError")
    if args.len > 0 and args[0].kind == avStream:
      result.value = copyValue(args[0])
    elif args.len > 0 and args[0].kind in {avList, avRange}:
      result.value = AbstractValue(kind: avStream, deferredKnown: true,
                                    resultType: args[0].resultType, streamTaskSafe: true)
    else:
      result.errors.open = true
      result.value = AbstractValue(kind: avStream)
  of "map", "filter", "filter_map", "each", "stream/map", "stream/filter",
      "stream/filter_map", "stream/each":
    if args.len == 1:
      result.value = AbstractValue(kind: avSelector)
      return
    if args[0].kind notin {avList, avMap, avStream}:
      # Other receivers use generic dispatch. In particular, Range is iterable
      # but does not acquire List's eager collection messages.
      result.errors.open = true
      return
    let lazy = args[0].kind == avStream and name notin ["each", "stream/each"]
    if args[0].kind == avStream:
      analysis.retainReturnedErrors(args[0], "stream", function, loc, kindOnly = lazy)
    let callback =
      if lazy: BodyErrors(value: unknownValue(), errors: args[1].effectiveRow())
      else: analysis.callValue(args[1],
        @[analysis.valueFromType(args[0].resultType, environment)],
        environment, function, loc)
    var effects = callback.errors
    if args[0].kind == avStream: effects.mergeErrors(args[0].deferredRow())
    elif args[0].kind notin {avList, avMap}: effects.open = true
    if lazy:
      result.value = AbstractValue(kind: avStream, deferredKnown: true, deferred: effects,
                                    returnOrigins: args[0].returnOrigins)
      for origin in args[1].returnOrigins:
        var dependency = origin
        dependency.returnKind = "callable"
        result.value.returnOrigins.add dependency
      if args[1].target.kind != vkNil:
        result.value.returnOrigins.add ErrorProofDependency(target: args[1].target,
          producer: if args[1].fn != nil: args[1].fn.summary.identity else: args[1].name,
          returnKind: "callable")
    else:
      result.errors = effects
      result.mayConsumeTasks = callback.mayConsumeTasks or
        (args[0].kind == avStream and not args[0].streamTaskSafe)
      result.value = if name in ["each", "stream/each"]: scalarValue("Nil")
                     else: AbstractValue(kind: args[0].kind,
                       typ: newSym(if args[0].kind == avMap: "PropMap" else: "List"),
                       resultType: if name in ["filter", "stream/filter"]: args[0].resultType
                                   else: callback.value.typ)
  of "into", "stream/into":
    let target = args[^1]
    if args.len == 1:
      result.value = AbstractValue(kind: avSelector)
      if target.kind notin {avList, avMap}: result.errors = oneError("RuntimeError")
      return
    if args[0].kind == avStream:
      analysis.retainReturnedErrors(args[0], "stream", function, loc)
      result.errors = args[0].deferredRow()
      result.mayConsumeTasks = not args[0].streamTaskSafe
    elif args[0].kind notin {avList, avRange}:
      result.errors.open = true
      return
    case target.kind
    of avList:
      result.value = AbstractValue(kind: avList, typ: newSym("List"))
    of avMap:
      # Every item must be a [key value] pair with a valid property key.
      # Generic collection annotations do not prove that tuple shape.
      result.errors.mergeErrors(oneError("RuntimeError"))
      result.value = AbstractValue(kind: avMap, typ: newSym("PropMap"))
    else:
      result.errors.mergeErrors(oneError("RuntimeError"))
  of "take", "stream/take":
    var count: int64
    if not args[^1].literalInt64(count) or count < 0:
      result.errors = oneError("RuntimeError")
    if args.len == 1:
      result.value = AbstractValue(kind: avSelector)
    elif args[0].kind in {avList, avStream}:
      result.value = copyValue(args[0])
      result.value.hasLiteral = false
    else:
      result.errors.open = true
  of "read_one":
    # In addition to reader errors, non-strings and multiple forms fail with
    # ordinary RuntimeError. read_one does not execute the syntax it returns.
    result.errors = joinedErrors(oneError("ParseError"), oneError("RuntimeError"))
  of "read_all":
    result.errors = oneError("ParseError")
    if args[0].typ.kind != vkSymbol or args[0].typ.symVal != "Str":
      result.errors.mergeErrors(oneError("RuntimeError"))
    result.value = AbstractValue(kind: avStream, deferredKnown: true,
                                  resultType: newSym("Any"), streamTaskSafe: true)
  of "parse_int":
    result.errors = oneError("ParseError")
    result.value = scalarValue("Int")
  of "size", "empty?":
    if args[0].kind notin {avList, avMap}: result.errors.open = true
    result.value = scalarValue(if name == "size": "Int" else: "Bool")
  of "List/push":
    result.errors = oneError("RuntimeError") # immutable/shared storage or escaping CallerEnv
    result.value = copyValue(args[1])
  of "Stream/next", "Stream/peek", "Stream/has_next", "Stream/close":
    result.mayConsumeTasks = not args[0].streamTaskSafe
    analysis.retainReturnedErrors(args[0], "stream", function, loc)
    result.errors = args[0].deferredRow()
    if name in ["Stream/next", "Stream/peek"]:
      result.errors.mergeErrors(oneError("EndOfStream"))
      result.value = analysis.valueFromType(args[0].resultType, environment)
    elif name == "Stream/has_next":
      result.value = scalarValue("Bool")
    else:
      result.value = scalarValue("Nil")
    if name != "Stream/close":
      result.errors.mergeErrors(oneError("RuntimeError")) # reentrant pulls
  of "Stream/try_next":
    # Producer failures are returned in TryNext/error, including a reentrant
    # pull; they do not escape the invocation as ordinary errors.
    result.mayConsumeTasks = not args[0].streamTaskSafe
  of "Task/join":
    # TaskOutcome contains producer failures, but an already-awaited task is
    # an invalid invocation. Joining itself does not consume the await result.
    result.errors = oneError("RuntimeError")
    result.mayConsumeTasks = true
    if not args[0].taskPrior: result.preservedTask = args[0].taskId
  else:
    result.errors.open = true

proc selectValue(analysis: ErrorAnalysis, target: AbstractValue, selector: Value,
                  environment: ErrorEnvironment): BodyErrors =
  result.value = unknownValue()
  if target == nil: return
  if selector.kind != vkNode or selector.head.kind != vkSymbol or selector.head.symVal != "select":
    result.errors.open = true
    result.mayConsumeTasks = true
    result.taskCode = true
    return
  var current = target
  for segment in selector.body:
    if segment.kind notin {vkSymbol, vkString, vkInt}:
      result.errors.open = true
      current = unknownValue()
      break
    let key = if segment.kind == vkSymbol: segment.symVal
              elif segment.kind == vkString: segment.strVal else: $segment.intVal
    let originalTarget = current.target
    if current.kind == avNamespace:
      if current.space != nil:
        let found = if key in current.space.hidden: ErrorBinding()
                    else: current.space.values.getOrDefault(key)
        current = if found.value != nil: copyValue(found.value) else: unknownValue()
      else:
        let name = current.name & "/" & key
        current = AbstractValue(kind: avNamespace, name: name)
        if builtinNativeErrorMetadata(name).identity.len > 0:
          current.kind = avNative
        elif key == "Error": current = AbstractValue(kind: avProtocol, name: "Error")
    elif current.kind == avStream:
      result.mayConsumeTasks = result.mayConsumeTasks or not current.streamTaskSafe
      result.taskCode = result.taskCode or not current.streamTaskSafe
      result.errors.mergeErrors(current.deferredRow())
      current = AbstractValue(kind: avStream, deferredKnown: true)
    elif current.kind == avUnknown:
      # Dynamic selectors may execute a selector stage or consume a Stream.
      result.errors.open = true
      result.mayConsumeTasks = true
      result.taskCode = true
      current = unknownValue()
    elif current.nominal != nil and current.nominal.fields.hasKey(key):
      current = analysis.valueFromType(current.nominal.fields[key], environment)
    elif current.caught and key == "cause":
      current = AbstractValue(kind: avNode, caught: true,
                               caughtErrors: ErrorEffectSummary(open: true))
    else:
      current = unknownValue()
    if originalTarget.kind != vkNil:
      let parts = if originalTarget.kind == vkNode and originalTarget.head.kind == vkSymbol and
                     originalTarget.head.symVal == "path": originalTarget.body
                  else: @[originalTarget]
      current.target = newNode(newSym("path"), body = parts & @[segment])
  result.value = current

proc methodsComplete(receiver: AnalyzedType): bool =
  var visiting = initHashSet[pointer]()
  proc complete(current: AnalyzedType): bool =
    if current == nil or not current.methodsKnown or
        visiting.containsOrIncl(cast[pointer](current)):
      return false
    defer: visiting.excl cast[pointer](current)
    if current.parent != nil and not complete(current.parent): return false
    for parent in current.protocolParents:
      if not complete(parent): return false
    true
  complete(receiver)

proc protocolMembers(receiver: AnalyzedType): seq[AnalyzedFunction] =
  var visiting = initHashSet[pointer]()
  proc collect(current: AnalyzedType): seq[AnalyzedFunction] =
    if current == nil or visiting.containsOrIncl(cast[pointer](current)): return
    defer: visiting.excl cast[pointer](current)
    if current.importedProtocolMembers.len > 0: return current.importedProtocolMembers
    var seen = initHashSet[string]()
    for parent in current.protocolParents:
      for methodFn in collect(parent):
        if not seen.containsOrIncl(methodFn.summary.identity): result.add methodFn
    for _, methodFn in current.methods:
      if methodFn != nil and not seen.containsOrIncl(methodFn.summary.identity): result.add methodFn
  collect(receiver)

proc visibleMethods(receiver: AnalyzedType): Table[string, AnalyzedFunction] =
  if not methodsComplete(receiver): return
  if receiver.protocol:
    for methodFn in protocolMembers(receiver):
      let name = methodFn.summary.name
      if not result.hasKey(name): result[name] = methodFn
      elif result[name] == nil or result[name].summary.identity != methodFn.summary.identity:
        result[name] = nil
    # A qualifier's own message wins. Descendants still inherit ALL identities,
    # so they may need to qualify the defining protocol to disambiguate a name.
    for name, methodFn in receiver.methods: result[name] = methodFn
  else:
    if receiver.parent != nil: result = visibleMethods(receiver.parent)
    for name, methodFn in receiver.methods: result[name] = methodFn

proc dispatchProofTarget(analysis: ErrorAnalysis, owner: AnalyzedType,
                         environment: ErrorEnvironment): tuple[expr: Value, depth: int] =
  if owner == nil: return
  let direct = analysis.resolveType(owner.info.expr, environment)
  if direct != nil and direct.info.identity == owner.info.identity:
    return (owner.info.expr, 0)
  var visited = initHashSet[pointer]()
  proc search(space: ErrorEnvironment, prefix: seq[Value], level: int): tuple[expr: Value, depth: int] =
    if space == nil or level > 32 or visited.containsOrIncl(cast[pointer](space)): return
    var names: seq[string]
    for name in space.values.keys: names.add name
    names.sort()
    for name in names:
      if prefix.len > 0 and name in space.hidden: continue
      let value = space.values[name].value
      if value == nil: continue
      let path = prefix & @[newSym(name)]
      if value.kind in {avType, avProtocol}:
        var current = value.nominal
        var depth = 0
        var parents = initHashSet[pointer]()
        while current != nil and not parents.containsOrIncl(cast[pointer](current)):
          if current.info.identity == owner.info.identity:
            return (expr: (if path.len == 1: path[0] else: newNode(newSym("path"), body = path)),
                    depth: depth)
          current = current.parent
          inc depth
      elif value.kind == avNamespace:
        let found = search(value.space, path, level + 1)
        if found.expr.kind != vkNil: return found
  var scope = environment
  while scope != nil:
    let found = search(scope, @[], 0)
    if found.expr.kind != vkNil: return found
    scope = scope.parent

proc messageValue(analysis: ErrorAnalysis, receiver, qualifier: AbstractValue,
                   name: string, environment: ErrorEnvironment): AbstractValue =
  proc nativeMessage(receiverName: string): AbstractValue =
    AbstractValue(kind: avNative, name: receiverName & "/" & name,
      target: newNode(newSym("path"), body = @[newSym("gene"), newSym(receiverName)]),
      dispatchContract: true)
  proc dispatched(function: AnalyzedFunction, owner: AnalyzedType): AbstractValue =
    # Dispatch may select an override/impl whose unannotated body differs from
    # the statically visible method or protocol default. Only an explicit
    # signature constrains every provider; a default's inferred row is not that
    # promise. Fixed-target dispatch inference needs a retained dispatch proof.
    if function == nil: return AbstractValue(kind: avMessage, name: name)
    let proof = analysis.dispatchProofTarget(owner, environment)
    AbstractValue(kind: avMessage, name: name, fn: function,
      target: proof.expr, dispatchContract: true, dispatchTypeDepth: proof.depth,
      contractKnown: true,
      contract: if function.summary.declared: function.summary.declaredRow
                else: ErrorEffectSummary(open: true))
  if qualifier != nil and qualifier.kind == avProtocol and qualifier.nominal == nil and
      qualifier.name == "Error" and name == "message":
    return AbstractValue(kind: avMessage, name: name, contractKnown: true,
                          resultType: newSym("Str"))
  if qualifier != nil and qualifier.kind == avProtocol and qualifier.nominal != nil:
    let methods = visibleMethods(qualifier.nominal)
    if methods.hasKey(name): return dispatched(methods[name], qualifier.nominal)
    return AbstractValue(kind: avMessage, name: name)
  if qualifier != nil and not (qualifier.hasLiteral and qualifier.literal.kind == vkNil):
    return AbstractValue(kind: avMessage, name: name)
  if receiver != nil and receiver.nominal != nil and not receiver.nominal.protocol:
    let methods = visibleMethods(receiver.nominal)
    if methods.hasKey(name):
      let methodFn = methods[name]
      let owner = if methodFn != nil and methodFn.receiver != nil: methodFn.receiver
                  else: receiver.nominal
      return dispatched(methodFn, owner)
  if receiver != nil and receiver.kind == avStream:
    if name in ["next", "peek", "try_next", "has_next", "close"]:
      return nativeMessage("Stream")
  if receiver != nil and receiver.kind == avTask and name == "join":
    return nativeMessage("Task")
  if receiver != nil and receiver.kind == avList and name in ["size", "empty?", "push"]:
    return nativeMessage("List")
  AbstractValue(kind: avMessage, name: name)

proc interfaceEnvironment(analysis: ErrorAnalysis, iface: CompileNamespaceInterface,
                           parent: ErrorEnvironment, prefix: string): ErrorEnvironment =
  result = newErrorEnvironment(parent, prefix, prefix)
  if iface == nil: return
  for name, entry in iface.entries:
    var value = unknownValue()
    if entry.errorType.identity == "builtin:Error":
      value = AbstractValue(kind: avProtocol, name: "Error")
    elif entry.category == cbcNamespace:
      value = AbstractValue(kind: avNamespace, name: name,
        space: analysis.interfaceEnvironment(entry.namespace, parent, prefix & "/" & name))
    elif entry.category in {cbcType, cbcProtocol}:
      let typeInfo = if entry.errorType.identity.len > 0: entry.errorType
                     else: ErrorTypeSummary(identity: prefix & "/" & name, name: name, expr: newSym(name))
      let info = AnalyzedType(info: typeInfo, protocol: entry.category == cbcProtocol,
        methodsKnown: entry.messageErrorsKnown,
        fields: initTable[string, Value](), methods: initTable[string, AnalyzedFunction]())
      analysis.types[info.info.identity] = info
      if entry.category == cbcType and entry.constructorErrors != nil:
        info.constructorKnown = true
        info.constructor = AnalyzedFunction(environment: result,
          summary: entry.constructorErrors, public: true, resultValue: unknownValue())
      value = AbstractValue(kind: if info.protocol: avProtocol else: avType,
                             nominal: info, name: name)
    elif entry.callableErrors != nil:
      let fn = AnalyzedFunction(environment: result, summary: entry.callableErrors,
                                public: true, resultValue: unknownValue())
      value = AbstractValue(kind: avFunction, fn: fn, name: name)
    result.bindValue(name, value)
  # All type bindings must exist before method result/Self annotations are read.
  for name, entry in iface.entries:
    let owner = result.lookup(name).value.nominal
    if owner == nil: continue
    for methodName, summary in entry.messageErrors:
      if summary == nil:
        owner.methods[methodName] = nil
        continue
      var declaration = result
      var receiver: AnalyzedType
      if summary.receiverType.identity.len > 0:
        receiver = analysis.types.getOrDefault(summary.receiverType.identity)
        if receiver == nil:
          receiver = AnalyzedType(info: summary.receiverType)
        declaration = newErrorEnvironment(result, prefix, prefix)
        declaration.bindValue("Self", AbstractValue(kind: avType,
          nominal: receiver, name: receiver.info.name, typ: receiver.info.expr))
      owner.methods[methodName] = AnalyzedFunction(environment: declaration,
        receiver: receiver, summary: summary, public: true,
        requirementOnly: owner.protocol, resultValue: unknownValue())
    for summary in entry.protocolMessageErrors:
      owner.importedProtocolMembers.add AnalyzedFunction(environment: result,
        summary: summary, public: true, requirementOnly: true, resultValue: unknownValue())

proc predeclare(analysis: ErrorAnalysis, chunk: Chunk, environment: ErrorEnvironment,
                 function: AnalyzedFunction) =
  if analysis.byChunk.getOrDefault(cast[pointer](chunk)) == environment: return
  analysis.byChunk[cast[pointer](chunk)] = environment
  environment.hidden = chunk.exportExcludedNames.toHashSet()
  for proto in chunk.functions:
    let fn = analysis.registerFunction(proto, environment,
      public = function == nil and proto.publicErrorInterface)
    if proto.name.len > 0:
      environment.bindValue(proto.name, AbstractValue(kind: avFunction, name: proto.name,
                                                      fn: fn, target: newSym(proto.name)))
  for proto in chunk.typeProtos:
    let identity = environment.source & "::" & environment.prefix & "/type:" & proto.name
    var info = analysis.types.getOrDefault(identity)
    if info == nil:
      info = AnalyzedType(constructorKnown: true, methodsKnown: true,
        info: ErrorTypeSummary(identity: identity, name: proto.name, expr: newSym(proto.name)),
        fields: initTable[string, Value](), methods: initTable[string, AnalyzedFunction]())
    for field in proto.fields: info.fields[field.name] = field.typeExpr
    analysis.types[info.info.identity] = info
    environment.bindValue(proto.name, AbstractValue(kind: avType, name: proto.name, nominal: info))
    let public = function == nil and proto.name notin chunk.exportExcludedNames
    for message in proto.messages:
      info.methods[message.name] = analysis.registerFunction(message.fn, environment, public, info)
    info.constructor = analysis.registerFunction(proto.ctorFn, environment, public, info)
    for impl in proto.inlineImpls:
      for message in impl.messages:
        discard analysis.registerFunction(message.fn, environment, false, info)
  for proto in chunk.protocolProtos:
    let identity = environment.source & "::" & environment.prefix & "/protocol:" & proto.name
    var info = analysis.types.getOrDefault(identity)
    if info == nil:
      info = AnalyzedType(methodsKnown: true, protocol: true,
        info: ErrorTypeSummary(identity: identity, name: proto.name, expr: newSym(proto.name)),
        fields: initTable[string, Value](), methods: initTable[string, AnalyzedFunction]())
      analysis.types[identity] = info
    environment.bindValue(proto.name, AbstractValue(kind: avProtocol, name: proto.name, nominal: info))
    for message in proto.messages:
      info.methods[message.name] = analysis.registerFunction(message.fn, environment,
        public = function == nil and proto.name notin chunk.exportExcludedNames,
        requirementOnly = not message.hasDefault)
  for proto in chunk.implProtos:
    let receiver = analysis.resolveType(proto.receiverExpr, environment)
    for message in proto.messages:
      discard analysis.registerFunction(message.fn, environment, false, receiver)
  for spec in chunk.imports:
    var space: ErrorEnvironment
    if spec.fromModule:
      space = analysis.interfaceEnvironment(analysis.imported.getOrDefault(spec.importKey),
                                            environment.parent, spec.importKey)
    else:
      space = newErrorEnvironment(nil, "builtin", spec.nsSegments.join("/"))
    if spec.alias.len > 0:
      environment.bindValue(spec.alias, AbstractValue(kind: avNamespace, name: spec.alias, space: space))
    for selected in spec.selections:
      let found = space.lookup(selected.name)
      let value = if found.value != nil: found.value
                  elif not spec.fromModule:
                    AbstractValue(kind: avNative, name: spec.nsSegments.join("/") & "/" & selected.name)
                  else: unknownValue()
      environment.bindValue(selected.local, value)
    if spec.wildcard:
      for name, binding in space.values: environment.values[name] = binding

proc analyzeBody(analysis: ErrorAnalysis, chunk: Chunk, environment: ErrorEnvironment,
                  function: AnalyzedFunction = nil, depth = 0,
                  permitted = ErrorEffectSummary(open: true),
                  initialState: ptr AbstractState = nil): BodyErrors =
  result.value = unknownValue()
  if chunk == nil: return
  if function == nil: chunk.errorsMode = analysis.root.errorsMode
  let savedPermitted = analysis.permitted
  let savedChunk = analysis.currentChunk
  analysis.permitted = permitted
  analysis.currentChunk = chunk
  defer:
    analysis.permitted = savedPermitted
    analysis.currentChunk = savedChunk
  if depth > 64:
    result.errors.open = true
    return
  analysis.predeclare(chunk, environment, function)
  var declarations = initHashSet[string]()
  for inst in chunk.instructions:
    if inst.op in {opDefineName, opDefineLocal, opRedefineName, opRedefineLocal,
                    opMakeNamespace}:
      declarations.incl inst.name
    elif inst.op == opImport:
      let spec = chunk.imports[inst.intArg]
      if spec.alias.len > 0: declarations.incl spec.alias
      for selection in spec.selections: declarations.incl selection.local
  var states = initTable[int, AbstractState]()
  var work = @[0]
  states[0] = AbstractState(bindings: environment.values)
  if initialState != nil:
    states[0].mayConsumed = initialState[].mayConsumed
    states[0].knownTasks = initialState[].knownTasks
  var errors: ErrorEffectSummary
  var returns: AbstractValue
  var returnedState: AbstractState
  var hasReturn = false
  var iterations = 0
  var exceptional: ref AbstractState
  proc observeException(state: AbstractState) =
    var snapshot = state
    snapshot.stack = @[]
    if exceptional == nil:
      new(exceptional)
      exceptional[] = snapshot
    else:
      discard exceptional[].mergeState(snapshot)
  proc freshTask(state: AbstractState, value: AbstractValue): bool =
    value != nil and value.taskId.len > 0 and not value.taskPrior and
      value.taskId in state.knownTasks and value.taskId notin state.mayConsumed
  proc allocateTask(state: var AbstractState, value: AbstractValue) =
    let id = value.taskId
    if id.len == 0: return
    if id in state.knownTasks:
      # One source site can allocate repeatedly. Old aliases refer to earlier
      # instances; a fresh allocation must not make those aliases fresh again.
      for item in state.stack.mitems:
        if item != nil and item.taskId == id:
          item = copyValue(item)
          item.taskPrior = true
      for _, binding in state.bindings.mpairs:
        if binding.value != nil and binding.value.taskId == id:
          binding.value = copyValue(binding.value)
          binding.value.taskPrior = true
    state.knownTasks.incl id
    state.mayConsumed.excl id
  proc adoptFlow(state: var AbstractState, source: AbstractState) =
    state.mayConsumed = source.mayConsumed
    state.knownTasks = source.knownTasks
    for name, binding in state.bindings.mpairs:
      if source.bindings.hasKey(name): binding = source.bindings[name]
  proc requiresFutureDeclaration(callee: AnalyzedFunction, initialized: HashSet[string]): bool =
    var seen = initHashSet[string]()
    proc visit(target: AnalyzedFunction): bool =
      if target == nil or target.summary.declared or
          seen.containsOrIncl(target.summary.identity): return false
      for dependency in target.summary.dependencies:
        let name =
          if dependency.target.kind == vkSymbol: dependency.target.symVal
          elif dependency.target.kind == vkNode and dependency.target.head.kind == vkSymbol and
              dependency.target.head.symVal == "path" and dependency.target.body.len > 0 and
              dependency.target.body[0].kind == vkSymbol: dependency.target.body[0].symVal
          else: ""
        if name.len > 0:
          if target.proto != nil and name in target.proto.localNames and
              dependency.messageName.len == 0:
            continue
          if name in declarations and name notin initialized: return true
        for candidate in analysis.functions:
          if candidate.summary.identity == dependency.producer and visit(candidate): return true
      false
    visit(callee)
  proc enqueue(ip: int, state: AbstractState) =
    if ip < 0 or ip >= chunk.instructions.len: return
    if not states.hasKey(ip):
      states[ip] = state
      work.add ip
    elif states[ip].mergeState(state):
      work.add ip
  proc finish(value: AbstractValue, state: AbstractState) =
    var returned = value
    if value != nil and value.kind == avTask:
      returned = copyValue(value)
      returned.taskFresh = state.freshTask(value)
    if not hasReturn:
      returns = returned
      returnedState = state
      hasReturn = true
    else:
      returns = mergeValue(returns, returned)
      discard returnedState.mergeState(state)
  while work.len > 0:
    let ip = work.pop()
    inc iterations
    if iterations > max(1024, chunk.instructions.len * 96):
      errors.open = true
      break
    var state = states[ip]
    let inst = chunk.instructions[ip]
    let loc = chunk.location(ip)
    var next = true
    template push(value: AbstractValue) = state.stack.add value
    template load(name: string): AbstractValue =
      block:
        if name in declarations and name notin state.initialized:
          errors.mergeErrors(oneError("RuntimeError"))
        let binding = state.at(environment, name)
        var value = copyValue(binding.value)
        value.target = newSym(name)
        if not binding.immutable and binding.declaredType.kind == vkNil and
            value.kind in {avFunction, avMessage}:
          value = unknownValue()
        value
    template absorb(body: BodyErrors) =
      errors.mergeErrors(body.errors)
      result.taskCode = result.taskCode or body.taskCode
      if body.finalState != nil:
        state.adoptFlow(body.finalState[])
      else:
        if body.mayConsumeTasks:
          for task in state.knownTasks:
            if task != body.preservedTask: state.mayConsumed.incl task
        if body.value != nil and body.value.kind == avTask and body.value.taskFresh:
          state.allocateTask(body.value)
      if body.exceptionState != nil: observeException(body.exceptionState[])
    case inst.op
    of opNoop, opSetModuleName, opDeclareType:
      if inst.op == opSetModuleName: push scalarValue("Nil")
      elif inst.op == opDeclareType and state.bindings.hasKey(inst.name):
        var binding = state.bindings[inst.name]
        binding.declaredType = chunk.constants[inst.intArg]
        state.bindings[inst.name] = binding
    of opPushConst:
      push literalValue(chunk.constants[inst.intArg])
    of opLoadName, opLoadNativeFast, opLoadLocal, opLoadLocalFast, opLoadOuterLocal, opLoadArg:
      var name = inst.name
      if name.len == 0 and inst.intArg >= 0 and inst.intArg < chunk.localNames.len:
        name = chunk.localNames[inst.intArg]
      if state.at(environment, name).value == nil and name notin ["this_mod", "this_pkg", "self"]:
        errors.mergeErrors(oneError("RuntimeError"))
      push load(name)
    of opDefineName, opDefineLocal, opRedefineName, opRedefineLocal:
      let value = if state.stack.len > 0: state.stack[^1] else: unknownValue()
      let immutable = inst.name in chunk.immutableBindings or
        (value.fn != nil and value.fn.proto != nil and value.fn.proto.name == inst.name)
      state.bindings[inst.name] = ErrorBinding(value: value, immutable: immutable)
      state.initialized.incl inst.name
      environment.values[inst.name] = state.bindings[inst.name]
      if function == nil and inst.name notin chunk.exportExcludedNames and
          value.kind in {avFunction, avMessage}:
        analysis.publicValues[environment.prefix & "/" & inst.name] = (value: value, loc: loc)
        if value.fn != nil: value.fn.public = true
    of opSetName, opSetLocal, opSetOuterLocal:
      var binding = state.at(environment, inst.name)
      binding.value = if state.stack.len > 0: state.stack[^1] else: unknownValue()
      if binding.declaredType.kind != vkNil:
        binding.value = analysis.valueFromType(binding.declaredType, environment)
      state.bindings[inst.name] = binding
    of opPop: discard state.pop()
    of opMakeList:
      var elementType = NIL
      for i in 0..<inst.intArg:
        let value = state.pop()
        if i == 0: elementType = value.typ
        elif not equal(elementType, value.typ): elementType = NIL
      push AbstractValue(kind: avList, resultType: elementType, typ: newSym("List"))
    of opMakeMap:
      for _ in inst.names: discard state.pop()
      push AbstractValue(kind: avMap)
    of opMakeHashMap:
      for _ in 0..<inst.intArg * 2: discard state.pop()
      push AbstractValue(kind: avMap)
    of opMakeNode:
      let build = chunk.nodeBuilds[inst.intArg]
      for _ in 0..<build.bodyCount + build.propNames.len + build.metaNames.len:
        discard state.pop()
      let head = state.pop()
      push AbstractValue(kind: avNode, nominal: head.nominal)
    of opMakeSelector:
      var parts = newSeq[Value](inst.intArg)
      var known = true
      for i in countdown(inst.intArg - 1, 0):
        let part = state.pop()
        known = known and part.hasLiteral
        parts[i] = part.literal
      push (if known: literalValue(newNode(newSym("select"), body = parts)) else: unknownValue())
    of opApplySelector, opApplySelectorTop:
      let a = state.pop()
      let b = state.pop()
      let selector = if inst.op == opApplySelector: b else: a
      let target = if inst.op == opApplySelector: a else: b
      let selected = analysis.selectValue(target, selector.literal, environment)
      absorb(selected)
      push selected.value
    of opMakeFn:
      let proto = chunk.functions[inst.intArg]
      for _ in 0..<proto.errorTypeCount: discard state.pop()
      let fn = analysis.registerFunction(proto, environment,
        public = function == nil and proto.publicErrorInterface)
      push AbstractValue(kind: avFunction, fn: fn, name: proto.name)
    of opMakeNamespace:
      let space = newErrorEnvironment(environment, environment.source,
                                       environment.prefix & "/" & inst.name)
      let body = analysis.analyzeBody(chunk.subchunks[inst.intArg], space, function, depth + 1, permitted)
      absorb(body)
      let value = AbstractValue(kind: avNamespace, name: inst.name, space: space)
      state.bindings[inst.name] = ErrorBinding(value: value, immutable: true)
      environment.bindValue(inst.name, value)
      state.initialized.incl inst.name
      push value
    of opMakeType:
      let proto = chunk.typeProtos[inst.intArg]
      let value = copyValue(environment.lookup(proto.name).value)
      if value.nominal != nil and state.stack.len > 0 and state.stack[0].nominal != nil:
        let parent = state.stack[0].nominal
        value.nominal.parent = parent
        value.nominal.info.ancestors = @[parent.info.identity] & parent.info.ancestors
      state.stack.setLen(0)
      push value
    of opMakeProtocol:
      let proto = chunk.protocolProtos[inst.intArg]
      let value = copyValue(environment.lookup(proto.name).value)
      if value.nominal != nil:
        value.nominal.protocolParents = @[]
        for i in countdown(proto.parentCount - 1, 0):
          let parent = state.pop()
          value.nominal.protocolParents.add(
            if parent.kind == avProtocol and parent.nominal == nil and parent.name == "Error":
              analysis.types["builtin:Error"]
            else: parent.nominal)
      state.stack.setLen(0)
      push value
    of opMakeAlias:
      let value = state.pop()
      state.bindings[inst.name] = ErrorBinding(value: value, immutable: true)
      environment.values[inst.name] = state.bindings[inst.name]
      push value
    of opMakeEnum:
      state.stack.setLen(0)
      push AbstractValue(kind: avType, name: chunk.enumProtos[inst.intArg].name)
    of opMakeImpl:
      state.stack.setLen(0)
      push scalarValue("Nil")
    of opImport:
      let spec = chunk.imports[inst.intArg]
      if spec.alias.len > 0: state.initialized.incl spec.alias
      for selection in spec.selections: state.initialized.incl selection.local
      if spec.fromModule:
        let iface = analysis.imported.getOrDefault(spec.importKey)
        if iface == nil or not iface.initializationErrorsKnown: errors.open = true
        else: errors.mergeErrors(iface.initializationErrors)
      push scalarValue("Nil")
    of opImportImpl:
      let receiver = state.pop()
      let protocol = state.pop()
      let spec = chunk.importImpls[inst.intArg]
      let iface = analysis.imported.getOrDefault(spec.modulePath)
      if iface == nil or not iface.initializationErrorsKnown or not iface.exportedImplsKnown:
        errors.open = true
      else:
        errors.mergeErrors(iface.initializationErrors)
        let protocolType = if protocol.nominal != nil: protocol.nominal
                           elif protocol.kind == avProtocol and protocol.name == "Error":
                             analysis.types["builtin:Error"]
                           else: nil
        var supplied = false
        if protocolType != nil and receiver.nominal != nil:
          for implementation in iface.exportedImpls:
            if implementation.protocolIdentity == protocolType.info.identity and
                implementation.receiverIdentity == receiver.nominal.info.identity:
              supplied = true
        if not supplied: errors.mergeErrors(oneError("RuntimeError"))
      push scalarValue("Nil")
    of opCall0, opCall1, opCall2, opCall, opNew:
      let count = case inst.op
        of opCall0: 0
        of opCall1: 1
        of opCall2: 2
        of opNew:
          if inst.flag: chunk.listBuilds[inst.intArg].splices.len else: inst.intArg
        else: inst.intArg
      var args = newSeq[AbstractValue](count)
      for i in countdown(count - 1, 0): args[i] = state.pop()
      for _ in inst.names: discard state.pop()
      let callee = state.pop()
      if function == nil and requiresFutureDeclaration(callee.fn, state.initialized):
        errors.mergeErrors(oneError("RuntimeError"))
      let call = analysis.callValue(callee, args, environment, function, loc,
                                     constructorCall = inst.op == opNew,
                                     namedCount = inst.names.len)
      absorb(call)
      result.taskCode = true
      observeException(state) # invocation can also produce a generated failure
      if call.neverReturns: next = false
      else: push call.value
    of opCallName0, opCallName1, opCallNameN, opCallLocal0, opCallLocal1,
       opCallLocalN, opCallParentLocal0, opCallParentLocal1, opCallOuterLocal0, opCallOuterLocal1:
      let count = if inst.op in {opCallName0, opCallLocal0, opCallParentLocal0, opCallOuterLocal0}: 0
                  elif inst.op in {opCallNameN, opCallLocalN}: inst.depth else: 1
      var args = newSeq[AbstractValue](count)
      for i in countdown(count - 1, 0): args[i] = state.pop()
      let callee = load(inst.name)
      if function == nil and requiresFutureDeclaration(callee.fn, state.initialized):
        errors.mergeErrors(oneError("RuntimeError"))
      let call = analysis.callValue(callee, args, environment, function, loc)
      absorb(call)
      result.taskCode = true
      observeException(state)
      if call.neverReturns: next = false
      else: push call.value
    of opRecur1, opRecur1LocalIntSubConst, opRecur1LocalIntSubImm,
       opRecur1LocalIntSubConstSameScope, opRecur1LocalIntSubImmSameScope:
      if inst.op == opRecur1: discard state.pop()
      if function != nil:
        errors.mergeErrors(AbstractValue(kind: avFunction, fn: function).effectiveRow())
      else: errors.open = true
      push unknownValue()
    of opBindMessage:
      let qualifier = state.pop()
      let bound = analysis.messageValue(nil, qualifier, inst.name, environment)
      bound.boundMessage = true
      if qualifier.kind == avProtocol and qualifier.nominal == nil and
          qualifier.name == "Error" and inst.name == "message":
        bound.fn = analysis.types["builtin:Error"].methods["message"]
        bound.target = newSym("Error")
        bound.dispatchContract = true
      push bound
    of opResolveMessage:
      let receiver = state.pop()
      push analysis.messageValue(receiver, nil, inst.name, environment)
      push receiver
    of opResolveQualifiedMessage:
      let message = copyValue(state.pop())
      let receiver = state.pop()
      let immediate = ip > 0 and chunk.instructions[ip - 1].op == opBindMessage
      if immediate:
        message.boundMessage = false
      if immediate and message.fn != nil:
        message.contractKnown = true
        message.contract = if message.fn.summary.declared: message.fn.summary.declaredRow
                           else: ErrorEffectSummary(open: true)
        if message.fn.summary.identity == "builtin:Error/message":
          # Qualified Error formatting uses the receiver's admitted witness;
          # it does not depend on the caller's current implementation set.
          message.fn = nil
          message.target = NIL
          message.dispatchContract = false
          message.resultType = newSym("Str")
      push message
      push receiver
    of opQualifiedSend:
      let qualifier = state.pop()
      let receiver = state.pop()
      push analysis.messageValue(receiver, qualifier, inst.name, environment)
      push receiver
    of opPlaceSendReceiver:
      if state.stack.len > inst.intArg:
        let i = state.stack.len - inst.intArg - 1
        let value = state.stack[i]
        state.stack.delete(i)
        push value
    of opCheckType:
      observeException(state)
      analysis.retainTypeReferences(chunk.constants[inst.intArg], environment,
        function, loc, permitted)
      let original = state.pop()
      let value = analysis.valueFromType(chunk.constants[inst.intArg], environment)
      value.caught = original.caught
      value.caughtErrors = original.caughtErrors
      value.taskId = original.taskId
      value.taskPrior = original.taskPrior
      value.taskFresh = original.taskFresh
      value.taskIsolated = original.taskIsolated
      value.streamTaskSafe = original.streamTaskSafe
      value.returnOrigins = original.returnOrigins
      if original.caught: value.kind = avNode
      push value
    of opFail:
      let value = state.pop()
      if value.caught: errors.mergeErrors(value.caughtErrors)
      elif value.nominal != nil:
        errors.mergeErrors(ErrorEffectSummary(named: @[value.nominal.info]))
        let binding = analysis.dispatchProofTarget(value.nominal, environment)
        if binding.expr.kind != vkNil and not permitted.open:
          analysis.addErrorDependency(ErrorProofDependency(target: binding.expr,
            typeIdentityOnly: true, typeDepth: binding.depth, loc: loc), function)
      else: errors.open = true
      if function != nil and function.summary.origins.len < 128:
        let origin = ErrorOrigin(declaration: function.summary.identity,
          callee: "fail " & (if value.nominal != nil: value.nominal.info.name else: "Error"), loc: loc)
        if origin notin function.summary.origins: function.summary.origins.add origin
      observeException(state)
      next = false
    of opPanic, opRejectSyntaxSend:
      next = false
    of opTry:
      let trial = chunk.tries[inst.intArg]
      let bodyEnvironment = newErrorEnvironment(environment, environment.source, environment.prefix)
      bodyEnvironment.values = state.bindings
      var protectedBy = permitted
      for clause in trial.catches:
        analysis.retainTypeReferences(clause.errorType, environment, function, loc, permitted)
        if clause.errorType.kind == vkSymbol and clause.errorType.symVal == "Any":
          protectedBy.open = true
        else:
          protectedBy.mergeErrors(analysis.rowFromTypes([clause.errorType], environment))
      let body = analysis.analyzeBody(trial.body, bodyEnvironment, function, depth + 1, protectedBy,
                                      initialState = addr state)
      result.taskCode = result.taskCode or body.taskCode
      var escaping = body.errors
      var recoveries: ErrorEffectSummary
      var value = body.value
      var exitState: ref AbstractState
      proc addExit(source: ref AbstractState) =
        if source == nil: return
        if exitState == nil:
          new(exitState)
          exitState[] = source[]
        else:
          discard exitState[].mergeState(source[])
      if body.normalExit: addExit(body.finalState)
      var catchesAll = false
      for clause in trial.catches:
        let covered = if clause.errorType.kind == vkSymbol and clause.errorType.symVal == "Any":
                        ErrorEffectSummary(open: true)
                      else: analysis.rowFromTypes([clause.errorType], environment)
        var caught: ErrorEffectSummary
        if covered.open: caught = escaping
        else:
          for item in escaping.named:
            if errorCoverageContains(covered, ErrorEffectSummary(named: @[item])):
              caught.mergeErrors(ErrorEffectSummary(named: @[item]))
          if escaping.open: caught.mergeErrors(covered)
        escaping = subtractErrors(escaping, covered)
        catchesAll = catchesAll or covered.open
        var recoveryState = if body.exceptionState != nil: body.exceptionState[] else: state
        let recoveryEnv = newErrorEnvironment(environment, environment.source, environment.prefix)
        recoveryEnv.values = recoveryState.bindings
        recoveryEnv.bindValue("$err", AbstractValue(kind: avNode, caught: true, caughtErrors: caught))
        let recovery = analysis.analyzeBody(clause.body, recoveryEnv, function, depth + 1, permitted,
                                            initialState = addr recoveryState)
        result.taskCode = result.taskCode or recovery.taskCode
        recoveries.mergeErrors(recovery.errors)
        if recovery.normalExit: addExit(recovery.finalState)
        if recovery.exceptionState != nil: observeException(recovery.exceptionState[])
        value = mergeValue(value, recovery.value)
      errors.mergeErrors(escaping)
      errors.mergeErrors(recoveries)
      if body.exceptionState != nil and (not catchesAll or escaping.open or escaping.named.len > 0):
        observeException(body.exceptionState[])
      if exitState != nil: state.adoptFlow(exitState[])
      elif body.finalState != nil: state.adoptFlow(body.finalState[])
      if trial.ensureBody != nil:
        var cleanupState = state
        if body.exceptionState != nil and not catchesAll:
          discard cleanupState.mergeState(body.exceptionState[])
        let cleanupEnv = newErrorEnvironment(environment, environment.source, environment.prefix)
        cleanupEnv.values = cleanupState.bindings
        let cleanup = analysis.analyzeBody(trial.ensureBody, cleanupEnv, function, depth + 1, permitted,
                                           initialState = addr cleanupState)
        absorb(cleanup)
      push value
    of opTaskScope, opSupervisor:
      let bodyEnvironment = newErrorEnvironment(environment, environment.source, environment.prefix)
      bodyEnvironment.values = state.bindings
      var nestedState = state
      let body = analysis.analyzeBody(chunk.subchunks[inst.intArg], bodyEnvironment, function, depth + 1, permitted,
                                      initialState = addr nestedState)
      errors.mergeErrors(body.errors)
      # Scope exit waits without consuming child outcomes. Scheduler state
      # failures (for example, deadlock) belong to the wait operation; a
      # child's deferred row belongs to await, not to this implicit wait.
      errors.mergeErrors(oneError("RuntimeError"))
      result.taskCode = result.taskCode or body.taskCode
      if body.finalState != nil:
        state.adoptFlow(body.finalState[])
      if body.exceptionState != nil: observeException(body.exceptionState[])
      push body.value
    of opSpawn:
      let bodyEnvironment = newErrorEnvironment(environment, environment.source, environment.prefix)
      bodyEnvironment.values = state.bindings
      let body = analysis.analyzeBody(chunk.subchunks[inst.intArg], bodyEnvironment, function, depth + 1)
      result.taskCode = result.taskCode or body.taskCode
      if body.taskCode:
        for task in state.knownTasks: state.mayConsumed.incl task
      let id = "spawn:" & environment.prefix & ":" & chunk.sourceName & ":" &
        $loc.line & ":" & $loc.col & ":" & $ip
      let task = AbstractValue(kind: avTask, deferredKnown: true, deferred: body.errors,
                                resultType: body.value.typ, taskId: id, taskFresh: true,
                                taskIsolated: not body.taskCode)
      state.allocateTask(task)
      push task
    of opAwait:
      let task = copyValue(state.pop())
      result.taskCode = true
      task.taskFresh = state.freshTask(task)
      let proof = copyValue(task)
      proof.taskIsolated = false
      if task.taskIsolated:
        for other in state.knownTasks:
          if other != task.taskId and other notin state.mayConsumed:
            proof.taskIsolated = true
      analysis.retainReturnedErrors(proof, "task", function, loc)
      errors.mergeErrors(task.deferredRow())
      if not task.taskFresh: errors.mergeErrors(oneError("RuntimeError"))
      if not task.taskIsolated:
        for other in state.knownTasks:
          if other != task.taskId: state.mayConsumed.incl other
      if task.taskId.len > 0:
        state.mayConsumed.incl task.taskId
      # Await consumes an error payload before propagating it. A matching catch
      # therefore inherits consumption, unlike failures preceding this await.
      observeException(state)
      push analysis.valueFromType(task.resultType, environment)
    of opMakeIterator:
      let value = state.pop()
      if value.kind == avStream:
        analysis.retainReturnedErrors(value, "stream", function, loc)
        push value
      elif value.kind in {avList, avRange}:
        push AbstractValue(kind: avStream, deferredKnown: true, resultType: value.resultType,
                            streamTaskSafe: true)
      else:
        errors.open = true
        push AbstractValue(kind: avStream)
    of opIteratorHasNext, opIteratorNext, opIteratorClose:
      let value = state.pop()
      if not value.streamTaskSafe:
        result.taskCode = true
        for task in state.knownTasks: state.mayConsumed.incl task
      errors.mergeErrors(value.deferredRow())
      push (if inst.op == opIteratorNext: analysis.valueFromType(value.resultType, environment)
            elif inst.op == opIteratorHasNext: scalarValue("Bool") else: scalarValue("Nil"))
    of opForEach:
      let structured = chunk.forLoops[inst.intArg].body.repeatControlLoop
      let iterable = if structured: scalarValue("Nil") else: state.pop()
      if not structured and iterable.kind == avStream:
        if not iterable.streamTaskSafe:
          result.taskCode = true
          for task in state.knownTasks: state.mayConsumed.incl task
        analysis.retainReturnedErrors(iterable, "stream", function, loc)
        errors.mergeErrors(iterable.deferredRow())
      elif not structured and iterable.kind notin {avList, avRange}: errors.open = true
      var loopState = state
      loopState.stack = @[]
      for iteration in 0..<32:
        let loopEnv = newErrorEnvironment(environment, environment.source, environment.prefix)
        loopEnv.values = loopState.bindings
        let body = analysis.analyzeBody(chunk.forLoops[inst.intArg].body, loopEnv,
          function, depth + 1, permitted, initialState = addr loopState)
        errors.mergeErrors(body.errors)
        result.taskCode = result.taskCode or body.taskCode
        if body.exceptionState != nil: observeException(body.exceptionState[])
        if body.finalState == nil or not loopState.mergeState(body.finalState[]): break
        if iteration == 31: errors.open = true
      state.adoptFlow(loopState)
      push scalarValue("Nil")
    of opLoopBreak, opLoopContinue:
      finish(scalarValue("Nil"), state)
      next = false
    of opMatch:
      discard state.pop()
      let matched = chunk.matches[inst.intArg]
      var value: AbstractValue
      var exhaustive = matched.elseBody != nil
      var exitState: ref AbstractState
      var branchTaskCode = false
      proc analyzeBranch(branch: Chunk): AbstractValue =
        let branchEnv = newErrorEnvironment(environment, environment.source, environment.prefix)
        branchEnv.values = state.bindings
        let body = analysis.analyzeBody(branch, branchEnv, function, depth + 1, permitted,
                                        initialState = addr state)
        errors.mergeErrors(body.errors)
        result = body.value
        if body.exceptionState != nil: observeException(body.exceptionState[])
        if body.normalExit:
          if exitState == nil:
            new(exitState)
            exitState[] = body.finalState[]
          else:
            discard exitState[].mergeState(body.finalState[])
        branchTaskCode = branchTaskCode or body.taskCode
      for clause in matched.clauses:
        if clause.pattern.kind == vkSymbol: exhaustive = true
        let branchValue = analyzeBranch(clause.body)
        value = if value == nil: branchValue else: mergeValue(value, branchValue)
      if matched.elseBody != nil:
        let branchValue = analyzeBranch(matched.elseBody)
        value = if value == nil: branchValue else: mergeValue(value, branchValue)
      if not exhaustive:
        errors.mergeErrors(oneError("MatchError"))
        observeException(state)
      result.taskCode = result.taskCode or branchTaskCode
      if exitState != nil: state.adoptFlow(exitState[])
      push (if value == nil: unknownValue() else: value)
    of opJump: enqueue(inst.intArg, state); next = false
    of opJumpIfFalse:
      let condition = state.pop()
      if not condition.hasLiteral or not condition.literal.isTruthy: enqueue(inst.intArg, state)
      if condition.hasLiteral and not condition.literal.isTruthy: next = false
    of opJumpIfFalseOrPop, opJumpIfTrueOrPop, opJumpIfPresentOrPop, opJumpIfAbsent:
      enqueue(inst.intArg, state)
      if inst.op != opJumpIfAbsent: discard state.pop()
    of opReturn, opReturnBareInt, opExplicitReturn:
      finish(state.pop(), state)
      next = false
    of opReturnLocalIfIntLtConst, opReturnLocalIfIntLtImm:
      finish(scalarValue("Int"), state)
    of opYield:
      discard state.pop()
      push scalarValue("Nil")
    of opIntAdd2, opIntSub2, opIntMul2, opIntLt2, opIntGt2, opIntLe2, opIntGe2,
       opIntFast2, opNativeFast2, opReturnIntAdd2:
      let b = state.pop()
      let a = state.pop()
      if not a.numeric or not b.numeric: errors.open = true
      let value = if inst.op in {opIntLt2, opIntGt2, opIntLe2, opIntGe2}: scalarValue("Bool")
                  else: scalarValue("Int")
      if inst.op == opReturnIntAdd2: finish(value, state); next = false
      else: push value
    of opIntAddConst, opIntSubConst, opIntMulConst, opIntLtConst, opIntGtConst,
       opIntLeConst, opIntGeConst, opIntFastConst, opNativeFastConst:
      let value = state.pop()
      if not value.numeric: errors.open = true
      push (if inst.op in {opIntLtConst, opIntGtConst, opIntLeConst, opIntGeConst}:
              scalarValue("Bool") else: scalarValue("Int"))
    of opNot:
      discard state.pop()
      push scalarValue("Bool")
    else:
      # An unsupported operation is an ordinary-error possibility, never a
      # successful empty proof. Warning and strict modes share this fallback.
      errors.open = true
      result.taskCode = true
      for task in state.knownTasks: state.mayConsumed.incl task
      observeException(state)
      state.stack = @[unknownValue()]
    if state.stack.len > 256:
      errors.open = true
      state.stack = @[unknownValue()]
    if next: enqueue(ip + 1, state)
  result.errors = errors
  result.normalExit = hasReturn
  result.exceptionState = exceptional
  new(result.finalState)
  if hasReturn:
    result.value = returns
    result.finalState[] = returnedState
  elif exceptional != nil:
    result.finalState[] = exceptional[]

proc errorModeName*(mode: ErrorCheckMode): string =
  case mode
  of ecmDynamic: "dynamic"
  of ecmWarn: "warn"
  of ecmStrict: "strict"

proc parseErrorMode*(mode: string): ErrorCheckMode =
  case mode
  of "dynamic": ecmDynamic
  of "warn": ecmWarn
  of "strict": ecmStrict
  else: raise newException(ValueError, "errors mode must be dynamic, warn, or strict")

proc inferredReturnContracts(analysis: ErrorAnalysis, value: AbstractValue,
                             owner: AnalyzedFunction): seq[ErrorReturnContract] =
  var current = value
  for _ in 0..<MaxInferredReturnDepth:
    if current == nil: break
    var contract = ErrorReturnContract(valueType: current.typ)
    case current.kind
    of avNative:
      contract.kind = "native"
      contract.nativeMetadata = builtinNativeErrorMetadata(current.name)
    of avType:
      contract.kind = "type"
      if current.nominal != nil:
        contract.typeIdentity = current.nominal.info.identity
        let visible = analysis.resolveType(current.nominal.info.expr, owner.environment)
        if visible == nil or visible.info.identity != contract.typeIdentity:
          # Generative local declarations belong to this compiled generation;
          # they have no runtime Type value in the factory's outer scope yet.
          contract.typeContract = analysis.root.errorSummaryVersion
      else:
        contract.typeIdentity = "builtin-type:" & current.name
    of avFunction, avMessage:
      contract.kind = if current.boundMessage: "message" else: "callable"
      contract.errorsKnown = current.contractKnown or current.fn != nil
      contract.errors = current.effectiveRow()
      if current.boundMessage and current.fn != nil:
        contract.messageIdentity = current.fn.summary.identity & "@" & current.fn.summary.version
    of avTask, avStream:
      contract.kind = if current.kind == avTask: "task" else: "stream"
      contract.errorsKnown = current.deferredKnown
      contract.errors = current.deferredRow()
      if current.kind == avTask: contract.taskFresh = current.taskFresh
      if current.kind == avTask: contract.taskIsolated = current.taskIsolated
    else:
      break
    result.add contract
    if contract.kind notin ["callable", "message"]: break
    if current.fn != nil:
      let target = current.fn
      if target.proto != nil and target.proto.hasReturnType:
        current = analysis.valueFromType(target.proto.returnType, target.environment)
      elif not target.public:
        current = target.resultValue
      else:
        current = analysis.valueFromType(target.summary.resultType, target.environment)
    else:
      current = analysis.valueFromType(current.resultType, analysis.rootEnvironment)

proc sameReturnContracts(a, b: seq[ErrorReturnContract]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i].kind != b[i].kind or a[i].errorsKnown != b[i].errorsKnown or
        not sameErrorInformation(a[i].errors, b[i].errors) or
        not equal(a[i].valueType, b[i].valueType) or
        a[i].nativeMetadata != b[i].nativeMetadata or a[i].typeIdentity != b[i].typeIdentity or
        a[i].typeContract != b[i].typeContract or a[i].messageIdentity != b[i].messageIdentity: return false
    if a[i].taskFresh != b[i].taskFresh: return false
    if a[i].taskIsolated != b[i].taskIsolated: return false
  true

proc retainInferredReturnSources(analysis: ErrorAnalysis, owner: AnalyzedFunction,
                                 value: AbstractValue, depth = 0,
                                 excluded: seq[string] = @[]) =
  ## Inferred return metadata is part of the installed function's interface.
  ## Preserve its source assumptions without adding the returned code's errors
  ## to the factory's invocation row. Local captures remain activation guards.
  if value == nil or depth >= MaxInferredReturnDepth: return
  let kind = case value.kind
    of avFunction, avMessage: (if value.boundMessage: "message" else: "callable")
    of avNative: "native"
    of avType: "type"
    of avTask: "task"
    of avStream: "stream"
    else: ""
  if kind.len == 0: return
  let row = if kind in ["callable", "message"]: value.effectiveRow()
            elif kind in ["native", "type"]: ErrorEffectSummary()
            else: value.deferredRow()
  if row.open: return
  proc add(source: ErrorProofDependency) =
    var dependency = source
    if dependency.target.kind == vkSymbol and dependency.target.symVal in excluded and
        dependency.messageName.len == 0:
      return
    dependency.permitted = row
    dependency.loc = owner.proto.sourceLoc
    analysis.addErrorDependency(dependency, owner)
  if value.returnOrigins.len > 0:
    for origin in value.returnOrigins:
      var dependency = origin
      dependency.returnKind = if origin.returnKind.len > 0: origin.returnKind else: kind
      if dependency.returnDepth == 0: dependency.returnKind = ""
      if kind == "native": dependency.returnNativeMetadata = builtinNativeErrorMetadata(value.name)
      elif kind == "type":
        let contracts = analysis.inferredReturnContracts(value, owner)
        if contracts.len > 0:
          dependency.returnTypeIdentity = contracts[0].typeIdentity
          dependency.returnTypeContract = contracts[0].typeContract
      elif kind == "message" and value.fn != nil:
        dependency.returnMessageIdentity = value.fn.summary.identity & "@" & value.fn.summary.version
      elif kind == "task":
        dependency.returnTaskFresh = value.taskFresh
        dependency.returnTaskIsolated = value.taskIsolated
      add(dependency)
    return # the producer's metadata retains its own deeper dependencies
  if value.target.kind != vkNil:
    add(ErrorProofDependency(target: value.target,
      producer: if value.fn != nil: value.fn.summary.identity else: value.name,
      nativeMetadata: if kind == "native": builtinNativeErrorMetadata(value.name) else: NativeErrorMetadata(),
      typeIdentityOnly: kind == "type",
      messageName: if value.dispatchContract: value.name else: "",
      typeDepth: value.dispatchTypeDepth))
  if kind == "type" and value.nominal != nil:
    var parent = value.nominal.parent
    while parent != nil:
      let binding = analysis.dispatchProofTarget(parent, owner.environment)
      if binding.expr.kind != vkNil:
        add(ErrorProofDependency(target: binding.expr, typeIdentityOnly: true, typeDepth: binding.depth))
      parent = parent.parent
  if value.fn == nil: return
  let returned = value.fn
  var locals = excluded
  if returned.proto != nil:
    for parameter in returned.proto.params: locals.add parameter
    for parameter in returned.proto.namedParams: locals.add parameter.local
    if returned.proto.restParam.len > 0: locals.add returned.proto.restParam
  if not returned.summary.declared:
    for dependency in returned.summary.dependencies:
      if dependency.target.kind == vkSymbol and dependency.target.symVal in locals and
          dependency.messageName.len == 0:
        continue
      var isLocal = returned.proto != nil and dependency.target.kind == vkSymbol and
        dependency.target.symVal in returned.proto.localNames
      if isLocal:
        # A locally declared helper's code is fixed by this returned function.
        # Follow its inferred sources rather than looking for its activation
        # slot in the factory's declaration environment.
        for candidate in analysis.functions:
          if candidate.summary.identity == dependency.producer:
            analysis.retainInferredReturnSources(owner,
              AbstractValue(kind: avFunction, fn: candidate), depth + 1, locals)
      else:
        analysis.addErrorDependency(dependency, owner)
  if returned.proto == nil or not returned.proto.hasReturnType:
    analysis.retainInferredReturnSources(owner, returned.resultValue, depth + 1, locals)

proc inferFunction(analysis: ErrorAnalysis, function: AnalyzedFunction): bool =
  if function.proto == nil: return false
  let proto = function.proto
  function.summary.dependencies = @[]
  let environment = newErrorEnvironment(function.environment, function.environment.source,
                                          function.summary.identity)
  for i, name in proto.params:
    let typ = if i < proto.paramTypes.len: proto.paramTypes[i] else: NIL
    var value = analysis.valueFromType(typ, function.environment)
    if name == "self" and function.receiver != nil:
      value = AbstractValue(kind: avNode, nominal: function.receiver,
                              typ: function.receiver.info.expr)
    environment.bindValue(name, value, immutable = false, declaredType = typ)
  for param in proto.namedParams:
    environment.bindValue(param.local, analysis.valueFromType(param.typeExpr, function.environment),
                           immutable = false, declaredType = param.typeExpr)
  if proto.restParam.len > 0:
    environment.bindValue(proto.restParam, AbstractValue(kind: avList, resultType: proto.restType))
  function.summary.declaredRow = analysis.rowFromTypes(proto.signatureErrorExprs, function.environment)
  let permitted = if function.summary.declared: function.summary.declaredRow
                  else: function.summary.inferredRow
  for typ in proto.paramTypes:
    analysis.retainTypeReferences(typ, function.environment, function, proto.sourceLoc, permitted)
  for param in proto.namedParams:
    analysis.retainTypeReferences(param.typeExpr, function.environment, function, proto.sourceLoc, permitted)
  analysis.retainTypeReferences(proto.restType, function.environment, function, proto.sourceLoc, permitted)
  analysis.retainTypeReferences(proto.returnType, function.environment, function, proto.sourceLoc, permitted)
  for typ in proto.signatureErrorExprs:
    analysis.retainTypeReferences(typ, function.environment, function, proto.sourceLoc, permitted)
  var defaults: ErrorEffectSummary
  for parameter in proto.paramDefaults:
    if parameter.defaultChunk != nil:
      defaults.mergeErrors(analysis.analyzeBody(parameter.defaultChunk, environment, function,
                                                permitted = permitted).errors)
  for parameter in proto.namedParams:
    if parameter.defaultValue.defaultChunk != nil:
      defaults.mergeErrors(analysis.analyzeBody(parameter.defaultValue.defaultChunk, environment, function,
                                                permitted = permitted).errors)
  var body = BodyErrors(value: unknownValue())
  if not function.requirementOnly:
    body = analysis.analyzeBody(proto.chunk, environment, function, permitted = permitted)
  let invoked = if proto.isGenerator: defaults else: joinedErrors(defaults, body.errors)
  result = not sameErrorInformation(function.summary.inferredRow, invoked) or
    (proto.isGenerator and not sameErrorInformation(function.summary.producerRow, body.errors)) or
    valueKey(function.resultValue) != valueKey(body.value)
  function.summary.inferredRow = analysis.localizeErrors(invoked, function.environment)
  if proto.isGenerator: function.summary.producerRow = body.errors
  function.resultValue = body.value
  function.summary.inferredResultType = body.value.typ
  let returned = if proto.hasReturnType: analysis.valueFromType(proto.returnType, environment)
                 else: body.value
  let contracts = analysis.inferredReturnContracts(returned, function)
  if not sameReturnContracts(function.summary.returnContracts, contracts): result = true
  function.summary.returnContracts = contracts
  if not proto.hasReturnType:
    analysis.retainInferredReturnSources(function, returned)
  if returned != nil:
    function.summary.resultKind = case returned.kind
      of avFunction: "callable"
      of avTask: "task"
      of avStream: "stream"
      else: ""
    function.summary.resultErrorsKnown = returned.contractKnown or returned.deferredKnown or returned.fn != nil
    function.summary.resultErrors = if returned.kind == avFunction: returned.effectiveRow()
                                   else: returned.deferredRow()

proc errorOriginPath(analysis: ErrorAnalysis, start: AnalyzedFunction): string =
  var current = start
  var seen = initHashSet[string]()
  var parts: seq[string]
  while current != nil and parts.len < 10:
    if seen.containsOrIncl(current.summary.identity):
      parts.add "(recursive)"
      break
    parts.add (if current.proto != nil and current.proto.name.len > 0: current.proto.name else: "lambda")
    var next: AnalyzedFunction
    for origin in current.summary.origins:
      if origin.callee.startsWith("fail "):
        parts.add origin.callee
        return parts.join(" -> ")
      for candidate in analysis.functions:
        if candidate.summary.identity == origin.callee and
            (candidate.summary.inferredRow.open or candidate.summary.inferredRow.named.len > 0):
          next = candidate
          break
      if next != nil: break
    current = next
  parts.join(" -> ")

proc validateErrorAnalysis*(analysis: ErrorAnalysis) =
  analysis.diagnostics = @[]
  if analysis.root.errorsMode == ecmDynamic: return
  for name, published in analysis.publicValues:
    if published.value.fn == nil and not published.value.contractKnown:
      analysis.diagnostics.add CompileDiagnostic(loc: published.loc,
        message: "error checking: public callable '" & name & "' requires an explicit invocation ^errors row")
  for function in analysis.functions:
    if function.proto == nil: continue
    let name = if function.proto.name.len > 0: function.proto.name else: "lambda"
    for item in function.summary.declaredRow.named:
      if item.identity.startsWith("unresolved:"):
        analysis.diagnostics.add CompileDiagnostic(loc: function.proto.sourceLoc,
          message: "error checking: cannot resolve error-row type " & item.name & " for '" & name & "'")
    if function.public and not function.summary.declared:
      analysis.diagnostics.add CompileDiagnostic(loc: function.proto.sourceLoc,
        message: "error checking: public callable '" & name & "' requires an explicit ^errors row")
    if function.summary.declared and not function.requirementOnly and
        not errorCoverageContains(function.summary.declaredRow, function.summary.inferredRow):
      analysis.diagnostics.add CompileDiagnostic(loc: function.proto.sourceLoc,
        message: "error checking: '" & name & "' declares " &
          describeErrors(function.summary.declaredRow) & " but may raise " &
          describeErrors(function.summary.inferredRow) &
          ". Catch the escaping errors or add them to ^errors. Origin: " &
          analysis.errorOriginPath(function))
    if function.proto.isGenerator and function.proto.hasReturnType:
      let value = analysis.valueFromType(function.proto.returnType, function.environment)
      if value.kind == avStream and value.deferredKnown and
          not errorCoverageContains(value.deferred, function.summary.producerRow):
        analysis.diagnostics.add CompileDiagnostic(loc: function.proto.sourceLoc,
          message: "error checking: generator '" & name & "' exceeds its Stream error contract")
  let initialization = analysis.root.initializationErrors
  if initialization.open or initialization.named.len > 0:
    analysis.diagnostics.add CompileDiagnostic(loc: SourceLoc(
      sourceName: analysis.root.sourceName, line: 1, col: 1),
      message: "error checking: module initialization may raise " & describeErrors(initialization) &
        "; its escaping row is empty")

proc inferErrorSummaries*(analysis: ErrorAnalysis) =
  let version = sha256Hex(analysis.root.sourceName & "\n" & analysis.root.disassemble())
  analysis.root.errorSummaryVersion = version
  analysis.collecting = true
  discard analysis.analyzeBody(analysis.root, analysis.rootEnvironment)
  analysis.collecting = false
  var settled = false
  let limit = max(32, (analysis.functions.len + 1) * (analysis.types.len + 2))
  for iteration in 0..<limit:
    var changed = false
    let before = analysis.functions.len
    var i = 0
    while i < analysis.functions.len:
      changed = analysis.inferFunction(analysis.functions[i]) or changed
      inc i
    changed = changed or before != analysis.functions.len
    if not changed:
      settled = true
      break
  if not settled:
    for function in analysis.functions: function.summary.inferredRow.open = true
  for chunkPtr in analysis.byChunk.keys:
    cast[Chunk](chunkPtr).errorProofDependencies = @[]
  let initialization = analysis.analyzeBody(analysis.root, analysis.rootEnvironment,
                                             permitted = ErrorEffectSummary())
  analysis.root.initializationErrors = initialization.errors
  for function in analysis.functions:
    if function.proto != nil:
      function.proto.errorsMode = analysis.root.errorsMode
      function.summary.version = version
  analysis.validateErrorAnalysis()

proc analyzeErrorEffects*(root: Chunk,
    imported = initTable[string, CompileNamespaceInterface]()): ErrorAnalysis =
  result = newErrorAnalysis(root, imported)
  result.inferErrorSummaries()

proc attachErrorInterfaces*(analysis: ErrorAnalysis, iface: CompileNamespaceInterface) =
  if iface == nil: return
  iface.initializationErrorsKnown = true
  iface.initializationErrors = analysis.root.initializationErrors
  iface.errorSummaryVersion = analysis.root.errorSummaryVersion
  iface.exportedImplsKnown = true
  iface.exportedImpls = @[]
  for chunkPtr, environment in analysis.byChunk:
    let chunk = cast[Chunk](chunkPtr)
    for implementation in chunk.implProtos:
      if not implementation.staticTopLevel or not implementation.staticOperands or
          not implementation.exported: continue
      let protocol = analysis.resolveType(implementation.protocolExpr, environment)
      let receiver = analysis.resolveType(implementation.receiverExpr, environment)
      if protocol != nil and receiver != nil:
        iface.exportedImpls.add CompileImplInterface(protocolIdentity: protocol.info.identity,
          receiverIdentity: receiver.info.identity)
  iface.exportedImpls.sort(proc(a, b: CompileImplInterface): int =
    cmp(a.protocolIdentity & ":" & a.receiverIdentity, b.protocolIdentity & ":" & b.receiverIdentity))
  proc attach(environment: ErrorEnvironment, target: CompileNamespaceInterface) =
    for name, entry in target.entries.mpairs:
      let binding = environment.lookup(name)
      if binding.value == nil: continue
      let nominal = if binding.value.nominal != nil: binding.value.nominal
                    elif binding.value.hasLiteral:
                      analysis.resolveType(binding.value.literal, environment)
                    else: nil
      if entry.category == cbcNamespace and binding.value.space != nil:
        attach(binding.value.space, entry.namespace)
      elif binding.value.fn != nil:
        entry.callableErrors = binding.value.fn.summary
      elif binding.value.kind in {avFunction, avMessage} and binding.value.contractKnown:
        entry.callableErrors = CallableErrorSummary(name: name,
          identity: environment.source & "::" & environment.prefix & "/value:" & name,
          version: analysis.root.errorSummaryVersion, declared: true,
          declaredRow: binding.value.contract, resultType: binding.value.resultType)
      elif binding.value.kind == avProtocol and binding.value.nominal == nil and
          binding.value.name == "Error":
        entry.errorType = analysis.types["builtin:Error"].info
      elif nominal != nil:
        entry.errorType = nominal.info
        entry.messageErrorsKnown = methodsComplete(nominal)
        entry.messageErrors = initTable[string, CallableErrorSummary]()
        for methodName, methodFn in visibleMethods(nominal):
          entry.messageErrors[methodName] = if methodFn == nil: nil else: methodFn.summary
        entry.protocolMessageErrors = @[]
        if nominal.protocol:
          for methodFn in protocolMembers(nominal):
            entry.protocolMessageErrors.add methodFn.summary
          entry.protocolMessageErrors.sort(proc(a, b: CallableErrorSummary): int = cmp(a.identity, b.identity))
        if entry.category == cbcType:
          var owner = nominal
          while owner.constructor == nil and owner.parent != nil:
            owner = owner.parent
          if owner.constructor != nil:
            entry.constructorErrors = owner.constructor.summary
          elif owner.constructorKnown:
            entry.constructorErrors = CallableErrorSummary(
              identity: nominal.info.identity & "/missing-constructor",
              version: analysis.root.errorSummaryVersion,
              inferredRow: oneError("RuntimeError"),
              resultType: nominal.info.expr)
  attach(analysis.rootEnvironment, iface)

proc errorInterfaceKey*(iface: CompileNamespaceInterface): string =
  if iface == nil: return "unknown"
  # Include every contract component consumed by dependent analysis. Source
  # versions and diagnostic call graphs are deliberately separate: neither
  # belongs in fixed-point equality or a public interface digest.
  proc part(target: var string, value: string) =
    target.add $value.len & ":" & value
  proc typeKey(typ: ErrorTypeSummary): string =
    result.part(typ.identity)
    result.part(typ.name)
    result.part(typ.expr.print())
    var ancestors = typ.ancestors
    ancestors.sort()
    for ancestor in ancestors: result.part(ancestor)
  proc rowKey(row: ErrorEffectSummary): string =
    result.part($row.open)
    var types: seq[string]
    for typ in row.named: types.add typeKey(typ)
    types.sort()
    for typ in types: result.part(typ)
  proc callableKey(summary: CallableErrorSummary): string =
    if summary == nil: return "unknown"
    result.part(summary.identity)
    result.part(summary.name)
    result.part($summary.declared)
    for row in [summary.declaredRow, summary.inferredRow, summary.producerRow,
                summary.resultErrors]:
      result.part(rowKey(row))
    result.part(summary.resultType.print())
    result.part(summary.inferredResultType.print())
    result.part(typeKey(summary.receiverType))
    result.part(summary.resultKind)
    result.part($summary.resultErrorsKnown)
    for contract in summary.returnContracts:
      result.part(contract.kind)
      result.part($contract.errorsKnown)
      result.part(rowKey(contract.errors))
      result.part(contract.valueType.print())
      result.part(contract.nativeMetadata.identity)
      result.part(contract.nativeMetadata.version)
      result.part(contract.typeIdentity)
      result.part(contract.typeContract)
      result.part(contract.messageIdentity)
      result.part($contract.taskFresh)
      result.part($contract.taskIsolated)
  result.part($iface.initializationErrorsKnown)
  result.part(rowKey(iface.initializationErrors))
  result.part($iface.exportedImplsKnown)
  var implementations: seq[string]
  for implementation in iface.exportedImpls:
    var key: string
    key.part(implementation.protocolIdentity)
    key.part(implementation.receiverIdentity)
    implementations.add key
  implementations.sort()
  for implementation in implementations: result.part(implementation)
  var names: seq[string]
  for name in iface.entries.keys: names.add name
  names.sort()
  for name in names:
    let entry = iface.entries[name]
    result.part(name)
    result.part($entry.category)
    result.part(typeKey(entry.errorType))
    result.part(callableKey(entry.callableErrors))
    result.part(callableKey(entry.constructorErrors))
    result.part($entry.messageErrorsKnown)
    var methodNames: seq[string]
    for methodName in entry.messageErrors.keys: methodNames.add methodName
    methodNames.sort()
    for methodName in methodNames:
      result.part(methodName)
      result.part(callableKey(entry.messageErrors[methodName]))
    var closure: seq[string]
    for summary in entry.protocolMessageErrors:
      closure.add callableKey(summary)
    closure.sort()
    for member in closure: result.part(member)
    result.part(errorInterfaceKey(entry.namespace))
