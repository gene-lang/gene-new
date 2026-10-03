## Deterministic serialization for the Phase-1 executable GIR artifact.
##
## The compiler executable hash is part of every derivation, so this is an
## internal ABI rather than a long-lived interchange format. The explicit
## format number still makes malformed or mismatched payloads fail closed.

import std/[algorithm, json, jsonutils, sets, strutils, tables]
import ./[gir, printer, reader, types]

# The number changes when the chunk layout or opcode/value meaning changes, so
# a stale artifact fails closed. Path values replaced Selector values while
# reusing the same bytecode slots, so that migration also advances the format.
const GirArtifactFormat* = 26

proc validateModuleSourcePath(path: string) =
  # Empty remains available to host-created, explicitly path-bound chunks.
  # Packaged artifacts require this field when admitted by the launcher.
  if path.len == 0: return
  if path.startsWith("/") or '\\' in path or '\0' in path or
      (path.len >= 2 and path[1] == ':'):
    raise newException(ValueError, "GIR source path must be package-relative")
  for part in path.split('/'):
    if part in ["", ".", ".."]:
      raise newException(ValueError, "GIR source path is not normalized")

proc toJsonHook(scope: Scope): JsonNode =
  if scope != nil:
    raise newException(ValueError, "executable GIR cannot serialize a live scope")
  newJNull()

proc fromJsonHook(scope: var Scope, node: JsonNode) =
  if node.kind != JNull:
    raise newException(ValueError, "encoded GIR must not contain a live scope")
  scope = nil

proc toJsonHook(cache: CompilerPreparationCache): JsonNode =
  newJNull()

proc fromJsonHook(cache: var CompilerPreparationCache, node: JsonNode) =
  if node.kind != JNull:
    raise newException(ValueError, "encoded GIR must not contain a compiler cache")
  cache = CompilerPreparationCache()

proc validateInertValue(value: Value, seen: var HashSet[uint64]) =
  if value.kind > vkPipeline:
    raise newException(ValueError, "executable GIR contains a runtime value: " & $value.kind)
  if value.kind notin {vkNode, vkList, vkMap, vkSet, vkHashMap, vkPipeline}: return
  if seen.containsOrIncl(value.bits): return
  case value.kind
  of vkNode:
    if value.nodeResourceId != 0 or value.hasErrorWitness:
      raise newException(ValueError, "executable GIR contains a retained runtime resource")
    validateInertValue(value.head, seen)
    for item in value.body: validateInertValue(item, seen)
    for _, item in value.props: validateInertValue(item, seen)
    for _, item in value.meta: validateInertValue(item, seen)
  of vkList:
    for item in value.listItems: validateInertValue(item, seen)
  of vkMap:
    for _, item in value.mapEntries: validateInertValue(item, seen)
  of vkSet:
    for item in value.setItems: validateInertValue(item, seen)
  of vkHashMap:
    for entry in value.hashMapEntries:
      validateInertValue(entry.key, seen)
      validateInertValue(entry.val, seen)
  of vkPipeline:
    validateInertValue(value.pipelineInitial, seen)
    for stage in value.pipelineStages:
      validateInertValue(stage.head, seen)
      for item in stage.body: validateInertValue(item, seen)
      for _, item in stage.props: validateInertValue(item, seen)
      for _, item in stage.meta: validateInertValue(item, seen)
  else: discard

proc toJsonHook(value: Value): JsonNode
proc fromJsonHook(value: var Value, node: JsonNode)

proc needsSyntaxTree(value: Value, seen: var HashSet[uint64]): bool =
  ## Constructed symbols need not have a reader spelling: "a/b", "$err", "true",
  ## and compiler-private labels are examples. Detect these before using text.
  if value.kind in {vkNode, vkList, vkMap, vkSet, vkHashMap, vkPipeline} and
      seen.containsOrIncl(value.bits): return false
  case value.kind
  of vkSymbol:
    let name = value.symVal
    # A conservative text fast path, not a restriction on legal symbol names.
    # Every other spelling gets the lossless structural representation.
    if name in ["+", "-", "*", "/", "//", "<", ">", "<=", ">=", "==", "!=",
                "!", "&&", "||", "??", "=", ":"]:
      return false
    if name.len == 0 or name.toLowerAscii() in ["nil", "void", "true", "false", "nan", "inf"]:
      return true
    if name[0] notin {'a'..'z', 'A'..'Z', '_'}: return true
    for character in name:
      if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '?', '!', '-'}:
        return true
    return false
  of vkNode:
    if needsSyntaxTree(value.head, seen): return true
    for item in value.body:
      if needsSyntaxTree(item, seen): return true
    for _, item in value.props:
      if needsSyntaxTree(item, seen): return true
    for _, item in value.meta:
      if needsSyntaxTree(item, seen): return true
  of vkList:
    for item in value.listItems:
      if needsSyntaxTree(item, seen): return true
  of vkMap:
    for _, item in value.mapEntries:
      if needsSyntaxTree(item, seen): return true
  of vkSet:
    for item in value.setItems:
      if needsSyntaxTree(item, seen): return true
  of vkHashMap:
    for item in value.hashMapEntries:
      if needsSyntaxTree(item.key, seen) or needsSyntaxTree(item.val, seen): return true
  of vkPipeline:
    if needsSyntaxTree(value.pipelineInitial, seen): return true
    for stage in value.pipelineStages:
      if needsSyntaxTree(stage.head, seen): return true
      for item in stage.body:
        if needsSyntaxTree(item, seen): return true
      for _, item in stage.props:
        if needsSyntaxTree(item, seen): return true
      for _, item in stage.meta:
        if needsSyntaxTree(item, seen): return true
  else: discard

proc encodeSyntaxTree(value: Value, active: var HashSet[uint64]): JsonNode

proc encodeSyntaxItems(items: openArray[Value], active: var HashSet[uint64]): JsonNode =
  result = newJArray()
  for item in items: result.add encodeSyntaxTree(item, active)

proc encodeSyntaxProps(props: PropTable, active: var HashSet[uint64]): JsonNode =
  result = newJArray()
  for name, value in props:
    result.add %*[%name, encodeSyntaxTree(value, active)]

proc encodeSyntaxTree(value: Value, active: var HashSet[uint64]): JsonNode =
  let composite = value.kind in {vkNode, vkList, vkMap, vkSet, vkHashMap, vkPipeline}
  if composite and active.containsOrIncl(value.bits):
    raise newException(ValueError, "executable GIR cannot encode cyclic constructed syntax")
  defer:
    if composite: active.excl value.bits
  case value.kind
  of vkSymbol: %*{"symbol": value.symVal}
  of vkList:
    %*{"list": encodeSyntaxItems(value.listItems, active), "immutable": value.listImmutable}
  of vkMap:
    %*{"map": encodeSyntaxProps(value.mapEntries, active), "immutable": value.mapImmutable}
  of vkNode:
    %*{"node": [encodeSyntaxTree(value.head, active), encodeSyntaxProps(value.props, active),
                encodeSyntaxItems(value.body, active), encodeSyntaxProps(value.meta, active)],
       "immutable": value.nodeImmutable}
  of vkSet: %*{"set": encodeSyntaxItems(value.setItems, active)}
  of vkHashMap:
    var pairs = newJArray()
    for entry in value.hashMapEntries:
      pairs.add %*[encodeSyntaxTree(entry.key, active), encodeSyntaxTree(entry.val, active)]
    %*{"hashmap": pairs}
  of vkPipeline:
    var stages = newJArray()
    for stage in value.pipelineStages:
      stages.add %*{"kind": toJson(stage.kind), "head": encodeSyntaxTree(stage.head, active),
        "props": encodeSyntaxProps(stage.props, active), "body": encodeSyntaxItems(stage.body, active),
        "meta": encodeSyntaxProps(stage.meta, active), "sourceLoc": toJson(stage.sourceLoc),
        "slot": toJson(stage.slot)}
    %*{"pipeline": encodeSyntaxTree(value.pipelineInitial, active),
       "stages": stages, "immutable": value.pipelineImmutable}
  else: %value.print()

proc decodeSyntaxItems(node: JsonNode): seq[Value] =
  if node.kind != JArray:
    raise newException(ValueError, "encoded GIR syntax items must be an array")
  for item in node:
    var value: Value
    fromJsonHook(value, item)
    result.add value

proc decodeSyntaxProps(node: JsonNode): PropTable =
  result = initPropTable()
  if node.kind != JArray:
    raise newException(ValueError, "encoded GIR syntax properties must be an array")
  for entry in node:
    if entry.kind != JArray or entry.len != 2 or entry[0].kind != JString or
        result.hasKey(entry[0].getStr()):
      raise newException(ValueError, "encoded GIR syntax property is invalid or duplicated")
    var value: Value
    fromJsonHook(value, entry[1])
    result[entry[0].getStr()] = value

proc validateDecodedSyntax(value: Value) =
  var seen = initHashSet[uint64]()
  value.validateInertValue(seen)

proc toJsonHook(value: Value): JsonNode =
  ## Values reachable from GIR are inert reader data. The sole tagged
  ## exception is an ffi/fn declaration stub with no callable native entry.
  ## Canonical Gene text handles all ordinary values.
  if value.kind == vkNativeFn:
    let metadata = value.nativeErrorMetadata
    if value.nativeImpl != nil or value.nativeCallImpl != nil or
        value.nativeAcceptsNamed or value.nativeFastKind != nfkNone or
        metadata.identity.len > 0 or metadata.version.len > 0 or
        value.nativeFnName.len == 0 or value.nativeFnName.len > 256:
      raise newException(ValueError,
        "executable GIR contains an active native function")
    result = newJObject()
    result["ffi_stub"] = %value.nativeFnName
    return
  var seen = initHashSet[uint64]()
  value.validateInertValue(seen)
  seen.clear()
  if needsSyntaxTree(value, seen):
    seen.clear()
    encodeSyntaxTree(value, seen)
  else:
    %value.print()

proc fromJsonHook(value: var Value, node: JsonNode) =
  if node.kind == JObject:
    if node.hasKey("symbol") and node.len == 1 and node["symbol"].kind == JString:
      value = newSym(node["symbol"].getStr())
      return
    let hasImmutable = node.hasKey("immutable") and node["immutable"].kind == JBool
    if node.len == 2 and hasImmutable:
      let immutable = node["immutable"].getBool()
      if node.hasKey("list"):
        value = newList(decodeSyntaxItems(node["list"]), immutable)
        validateDecodedSyntax(value)
        return
      if node.hasKey("map"):
        value = newMap(decodeSyntaxProps(node["map"]), immutable)
        validateDecodedSyntax(value)
        return
      if node.hasKey("node"):
        let parts = node["node"]
        if parts.kind != JArray or parts.len != 4:
          raise newException(ValueError, "encoded GIR syntax node is invalid")
        var head: Value
        fromJsonHook(head, parts[0])
        value = newNode(head, decodeSyntaxProps(parts[1]), decodeSyntaxItems(parts[2]),
          decodeSyntaxProps(parts[3]), immutable)
        validateDecodedSyntax(value)
        return
    if node.len == 1 and node.hasKey("set"):
      value = newSet(decodeSyntaxItems(node["set"]))
      validateDecodedSyntax(value)
      return
    if node.len == 1 and node.hasKey("hashmap"):
      if node["hashmap"].kind != JArray:
        raise newException(ValueError, "encoded GIR syntax map must be an array")
      var entries: seq[HashMapEntry]
      for entry in node["hashmap"]:
        if entry.kind != JArray or entry.len != 2:
          raise newException(ValueError, "encoded GIR syntax map entry is invalid")
        var key, item: Value
        fromJsonHook(key, entry[0])
        fromJsonHook(item, entry[1])
        entries.add HashMapEntry(key: key, val: item)
      value = newHashMap(entries)
      validateDecodedSyntax(value)
      return
    if node.len == 3 and node.hasKey("pipeline") and node.hasKey("stages") and hasImmutable:
      var initial: Value
      fromJsonHook(initial, node["pipeline"])
      if node["stages"].kind != JArray:
        raise newException(ValueError, "encoded GIR syntax pipeline stages must be an array")
      var stages: seq[PipelineStage]
      for entry in node["stages"]:
        if entry.kind != JObject or entry.len != 7:
          raise newException(ValueError, "encoded GIR syntax pipeline stage is invalid")
        for key in ["kind", "head", "props", "body", "meta", "sourceLoc", "slot"]:
          if not entry.hasKey(key):
            raise newException(ValueError, "encoded GIR syntax pipeline stage is incomplete")
        var stage = PipelineStage(kind: jsonTo(entry["kind"], PipelineStageKind),
          props: decodeSyntaxProps(entry["props"]), body: decodeSyntaxItems(entry["body"]),
          meta: decodeSyntaxProps(entry["meta"]),
          sourceLoc: jsonTo(entry["sourceLoc"], SourceLoc), slot: jsonTo(entry["slot"], PipelineSlot))
        fromJsonHook(stage.head, entry["head"])
        stages.add stage
      value = newPipeline(initial, stages, node["immutable"].getBool())
      validateDecodedSyntax(value)
      return
    if node.len != 1 or not node.hasKey("ffi_stub") or
        node["ffi_stub"].kind != JString or
        node["ffi_stub"].getStr().len == 0 or
        node["ffi_stub"].getStr().len > 256:
      raise newException(ValueError,
        "encoded GIR native stub is invalid")
    value = newNativeFn(node["ffi_stub"].getStr(), nil)
    return
  if node.kind != JString:
    raise newException(ValueError, "encoded GIR value must be a string")
  value = read(node.getStr(), "<artifact.gir>",
               ReadOptions(rejectDuplicateProps: true))
  validateDecodedSyntax(value)

type
  EncodedMacroContext = object
    sourceName: string
    moduleIdentity: string
    moduleSourcePath: string
    forms: seq[Value]
    importedMacros: Table[string, Table[string, MacroDef]]
    importedSyntaxFns: Table[string, seq[string]]
    importedInterfaces: Table[string, CompileNamespaceInterface]

  MacroCodecState = ref object
    definitionIds: Table[pointer, int]
    contextIds: Table[pointer, int]
    definitions: Table[int, MacroDef]
    contexts: Table[int, MacroDefinitionContext]
    pendingDefinitions: HashSet[int]
    pendingContexts: HashSet[int]

var macroCodecState {.threadvar.}: MacroCodecState

template withMacroCodec(body: untyped): untyped =
  let previousMacroCodec = macroCodecState
  macroCodecState = MacroCodecState()
  try:
    body
  finally:
    macroCodecState = previousMacroCodec

proc toJsonHook(context: MacroDefinitionContext): JsonNode
proc fromJsonHook(context: var MacroDefinitionContext, node: JsonNode)
proc toJsonHook(definition: MacroDef): JsonNode
proc fromJsonHook(definition: var MacroDef, node: JsonNode)
proc toJsonHook[V](table: Table[string, V],
                   options = initToJsonOptions()): JsonNode =
  ## Sorting also makes graph ids stable when contexts share definitions.
  result = newJObject()
  var keys: seq[string]
  for key in table.keys: keys.add key
  keys.sort()
  for key in keys:
    result[key] = toJson(table[key], options)

proc fromJsonHook[V](table: var Table[string, V], node: JsonNode,
                     options = Joptions()) =
  if node.kind != JObject:
    raise newException(ValueError, "encoded GIR table must be an object")
  table = initTable[string, V]()
  for key, value in node:
    table[key] = jsonTo(value, V, options)

proc graphReference(node: JsonNode): int =
  if node.kind != JObject:
    raise newException(ValueError, "encoded macro graph entry must be an object")
  if node.hasKey("ref"):
    if node.len != 1 or node["ref"].kind != JInt or node["ref"].getInt() <= 0:
      raise newException(ValueError, "invalid encoded macro reference")
    return node["ref"].getInt()
  if node.len != 2 or not node.hasKey("id") or not node.hasKey("value") or
      node["id"].kind != JInt or node["id"].getInt() <= 0:
    raise newException(ValueError, "invalid encoded macro graph entry")

proc toJsonHook(definition: MacroDef): JsonNode =
  if definition == nil: return newJNull()
  let key = cast[pointer](definition)
  if macroCodecState.definitionIds.hasKey(key):
    return %*{"ref": macroCodecState.definitionIds[key]}
  let id = macroCodecState.definitionIds.len + 1
  macroCodecState.definitionIds[key] = id
  result = %*{"id": id}
  result["value"] = toJson(definition[])

proc fromJsonHook(definition: var MacroDef, node: JsonNode) =
  if node.kind == JNull:
    raise newException(ValueError, "encoded macro definition is missing")
  let reference = graphReference(node)
  if reference > 0:
    if not macroCodecState.definitions.hasKey(reference) or
        reference in macroCodecState.pendingDefinitions:
      raise newException(ValueError, "invalid or cyclic macro definition reference")
    definition = macroCodecState.definitions[reference]
    return
  let id = node["id"].getInt()
  if id != macroCodecState.definitions.len + 1:
    raise newException(ValueError, "macro definition ids must be unique and ordered")
  new(definition)
  macroCodecState.definitions[id] = definition
  macroCodecState.pendingDefinitions.incl id
  fromJson(definition[], node["value"])
  macroCodecState.pendingDefinitions.excl id

proc toJsonHook(context: MacroDefinitionContext): JsonNode =
  if context == nil: return newJNull()
  let key = cast[pointer](context)
  if macroCodecState.contextIds.hasKey(key):
    return %*{"ref": macroCodecState.contextIds[key]}
  let id = macroCodecState.contextIds.len + 1
  macroCodecState.contextIds[key] = id
  # locs is keyed by in-process Value identities. Persisting those keys leaks
  # addresses, breaks determinism, and cannot locate re-read artifact values.
  # MacroDef.sourceLoc carries the portable definition diagnostic location.
  result = %*{"id": id}
  result["value"] = toJson(EncodedMacroContext(sourceName: context.sourceName, forms: context.forms,
    moduleIdentity: context.moduleIdentity, moduleSourcePath: context.moduleSourcePath,
    importedMacros: context.importedMacros,
    importedSyntaxFns: context.importedSyntaxFns,
    importedInterfaces: context.importedInterfaces))

proc fromJsonHook(context: var MacroDefinitionContext, node: JsonNode) =
  if node.kind == JNull:
    context = nil
    return
  let reference = graphReference(node)
  if reference > 0:
    if not macroCodecState.contexts.hasKey(reference) or
        reference in macroCodecState.pendingContexts:
      raise newException(ValueError, "invalid or cyclic macro context reference")
    context = macroCodecState.contexts[reference]
    return
  let id = node["id"].getInt()
  if id != macroCodecState.contexts.len + 1:
    raise newException(ValueError, "macro context ids must be unique and ordered")
  context = MacroDefinitionContext()
  macroCodecState.contexts[id] = context
  macroCodecState.pendingContexts.incl id
  let decoded = jsonTo(node["value"], EncodedMacroContext)
  validateModuleSourcePath(decoded.moduleSourcePath)
  context[] = MacroDefinitionContext(sourceName: decoded.sourceName,
    moduleIdentity: decoded.moduleIdentity, moduleSourcePath: decoded.moduleSourcePath,
    forms: decoded.forms, importedMacros: decoded.importedMacros,
    importedSyntaxFns: decoded.importedSyntaxFns,
    importedInterfaces: decoded.importedInterfaces)[]
  macroCodecState.pendingContexts.excl id

proc fromJsonHook(call: var RuntimeMacroCall, node: JsonNode) =
  # Pipeline assemblers return syntax without a single macro definition. Keep
  # the nil exception local to that case; ordinary definition entries cannot
  # be missing from the portable identity graph.
  if node.kind != JObject or node.len != 4 or
      not node.hasKey("definition") or not node.hasKey("syntax") or
      not node.hasKey("context") or not node.hasKey("pipeline") or
      node["pipeline"].kind != JBool:
    raise newException(ValueError, "invalid runtime macro call metadata")
  call.pipeline = node["pipeline"].getBool()
  if call.pipeline:
    if node["definition"].kind != JNull:
      raise newException(ValueError, "pipeline macro assembler has a definition")
  else:
    call.definition = jsonTo(node["definition"], MacroDef)
  call.syntax = jsonTo(node["syntax"], Value)
  call.context = jsonTo(node["context"], RuntimeExpansionContext)

proc toJsonHook(table: Table[int, Value],
                options = initToJsonOptions()): JsonNode =
  ## JSON object keys cannot represent integer instruction offsets without an
  ## implicit conversion. Encode an ordered pair list instead.
  result = newJArray()
  var keys: seq[int]
  for key in table.keys:
    keys.add key
  keys.sort()
  for key in keys:
    var entry = newJObject()
    entry["key"] = %key
    entry["value"] = toJson(table[key], options)
    result.add entry

proc fromJsonHook(table: var Table[int, Value], node: JsonNode,
                  options = Joptions()) =
  if node.kind != JArray:
    raise newException(ValueError,
      "encoded GIR call-site table must be an array")
  table = initTable[int, Value]()
  var previous = -1
  for entry in node:
    if entry.kind != JObject or entry.len != 2 or
        not entry.hasKey("key") or not entry.hasKey("value") or
        entry["key"].kind != JInt:
      raise newException(ValueError, "invalid encoded GIR call-site entry")
    let key = entry["key"].getInt()
    if key <= previous:
      raise newException(ValueError,
        "encoded GIR call-site offsets must be unique and ordered")
    previous = key
    table[key] = jsonTo(entry["value"], Value, options)

proc toJsonHook(fn: FunctionProto, options = initToJsonOptions()): JsonNode

proc validateUnlinkedFunction(fn: FunctionProto) =
  if fn == nil: return
  if fn.annotationSelfBits != 0 or fn.contractResolved or fn.signatureHadSelf or
      fn.builtinErrorMessage or fn.boundExecutionPolicy != nil:
    raise newException(ValueError, "executable GIR contains runtime-only invocation metadata")

proc toJsonHook(chunk: Chunk,
                options = initToJsonOptions()): JsonNode =
  ## `owner` is the sole upward cursor in the otherwise acyclic GIR tree.
  ## Dispatch cache entries contain process-local Value bits and are runtime
  ## state, not compiled code. Exclude both while letting jsonutils cover the
  ## closed, compiler-owned schema.
  if chunk == nil:
    return newJNull()
  # A phase can clone a template while another lane executes it. Filter a
  # local copy; temporarily clearing the live owner/cache would race the VM.
  var portable = chunk[]
  portable.owner = nil
  portable.dispatchCache = @[]
  portable.macroRuntimeLease = nil
  toJson(portable, options)

proc toJsonHook(fn: FunctionProto, options: ToJsonOptions): JsonNode =
  if fn == nil: return newJNull()
  validateUnlinkedFunction(fn)
  toJson(fn[], options)

proc restoreChunkOwners(root: Chunk, allowRuntimeState = false) =
  var seenChunks = initHashSet[pointer]()
  var seenFunctions = initHashSet[pointer]()

  proc validateDependency(dependency: ErrorProofDependency) =
    if dependency.returnDepth < 0 or dependency.returnDepth > MaxInferredReturnDepth or
        (dependency.returnDepth == 0 and (dependency.returnKind.len > 0 or dependency.returnKindOnly)) or
        (dependency.returnDepth > 0 and dependency.returnKind notin ["callable", "task", "stream", "native", "type", "message"]):
      raise newException(ValueError, "encoded GIR contains an invalid return-contract dependency")

  proc validateSummary(summary: CallableErrorSummary) =
    if summary == nil: return
    if summary.returnContracts.len > MaxInferredReturnDepth:
      raise newException(ValueError, "encoded GIR return-contract chain exceeds its bound")
    for contract in summary.returnContracts:
      if contract.kind notin ["callable", "task", "stream", "native", "type", "message"]:
        raise newException(ValueError, "encoded GIR contains an invalid return-contract kind")
    for dependency in summary.dependencies: validateDependency(dependency)

  proc restoreChunk(chunk: Chunk, owner: FunctionProto)

  proc restoreFunction(fn: FunctionProto) =
    if fn == nil or seenFunctions.containsOrIncl(cast[pointer](fn)):
      return
    validateUnlinkedFunction(fn)
    validateSummary(fn.errorSummary)
    restoreChunk(fn.chunk, fn)
    restoreChunk(fn.scopelessChunk, fn)
    for defaultValue in fn.paramDefaults:
      restoreChunk(defaultValue.defaultChunk, nil)
    for parameter in fn.namedParams:
      restoreChunk(parameter.defaultValue.defaultChunk, nil)

  proc restoreChunk(chunk: Chunk, owner: FunctionProto) =
    if chunk == nil or seenChunks.containsOrIncl(cast[pointer](chunk)):
      return
    if chunk.macroRuntimeLease != nil and not allowRuntimeState:
      raise newException(ValueError, "encoded GIR contains runtime macro state")
    var previousPrivate = -1
    for slot in chunk.privateLocalSlots:
      if slot <= previousPrivate or slot >= chunk.localNames.len:
        raise newException(ValueError, "encoded GIR contains invalid private local slots")
      previousPrivate = slot
    for declaration in chunk.runtimeMacroDefinitions:
      if declaration.definition == nil or not declaration.definition.runtime or
          declaration.slot < -1 or
          (declaration.slot >= 0 and declaration.slot notin chunk.privateLocalSlots):
        raise newException(ValueError, "encoded GIR contains invalid runtime macro storage")
    for call in chunk.runtimeMacroCalls:
      if call.context.loopDepth < 0 or
          (not call.pipeline and (call.definition == nil or
            not call.definition.runtime or call.syntax.kind != vkNode)):
        raise newException(ValueError, "encoded GIR contains invalid runtime macro call")
    for inst in chunk.instructions:
      case inst.op
      of opDefineRuntimeMacro:
        if inst.intArg < 0 or inst.intArg >= chunk.runtimeMacroDefinitions.len:
          raise newException(ValueError, "encoded GIR contains invalid runtime macro definition index")
      of opInvokeRuntimeMacro, opExecuteRuntimeMacro:
        if inst.intArg < 0 or inst.intArg >= chunk.runtimeMacroCalls.len or
            (inst.op == opInvokeRuntimeMacro and chunk.runtimeMacroCalls[inst.intArg].pipeline):
          raise newException(ValueError, "encoded GIR contains invalid runtime macro call index")
      of opRuntimePipelineStage:
        if inst.intArg < 0 or inst.intArg >= chunk.functions.len or
            chunk.functions[inst.intArg] == nil or not chunk.functions[inst.intArg].isMacroBody:
          raise newException(ValueError, "encoded GIR contains invalid runtime pipeline assembler")
      else: discard
    chunk.owner = owner
    chunk.dispatchCache = @[]
    for dependency in chunk.errorProofDependencies: validateDependency(dependency)
    for fn in chunk.functions:
      restoreFunction(fn)
    for body in chunk.subchunks:
      restoreChunk(body, nil)
    for loop in chunk.forLoops:
      restoreChunk(loop.body, nil)
    for match in chunk.matches:
      for clause in match.clauses:
        restoreChunk(clause.body, nil)
      restoreChunk(match.elseBody, nil)
    for attempt in chunk.tries:
      restoreChunk(attempt.body, nil)
      for clause in attempt.catches.mitems:
        # The compiler synthesizes a literal "$err" binding symbol. Reading
        # its printed spelling expands the source-level dollar shorthand into
        # a path, so it is not a faithful encoding of this internal pattern.
        # Rebuild from the authoritative source error type on every decode.
        clause.pattern = newNode(newSym("$err"),
          body = @[newSym(":"), clause.errorType])
        restoreChunk(clause.body, nil)
      restoreChunk(attempt.ensureBody, nil)
    for proto in chunk.typeProtos:
      restoreFunction(proto.ctorFn)
      for message in proto.messages:
        restoreFunction(message.fn)
      for implementation in proto.inlineImpls:
        for message in implementation.messages:
          restoreFunction(message.fn)
    for proto in chunk.enumProtos:
      for message in proto.messages:
        restoreFunction(message.fn)
      for implementation in proto.inlineImpls:
        for message in implementation.messages:
          restoreFunction(message.fn)
    for proto in chunk.protocolProtos:
      restoreFunction(proto.deriveFn)
      for message in proto.messages:
        restoreFunction(message.fn)
    for proto in chunk.implProtos:
      for message in proto.messages:
        restoreFunction(message.fn)

  restoreChunk(root, nil)

proc copyExecutionTemplate[T](source: T, copies: var Table[pointer, pointer]): T =
  ## Copy mutable compiler structures, retaining constant Value identity and
  ## immutable macro definition data. Unlike artifact encoding, in-memory GIR
  ## may contain a function value emitted by an ordinary macro body.
  when T is Value or T is Scope or T is MacroDef or
      T is MacroDefinitionContext or T is MacroBindings:
    result = source
  elif T is CompilerPreparationCache:
    result = CompilerPreparationCache()
  elif T is RootRef and not (T is FunctionProto):
    result = source
  elif T is ref:
    if source == nil: return nil
    let key = cast[pointer](source)
    if copies.hasKey(key): return cast[T](copies[key])
    new(result)
    copies[key] = cast[pointer](result)
    result[] = copyExecutionTemplate(source[], copies)
  elif T is Table:
    for key, value in source:
      result[key] = copyExecutionTemplate(value, copies)
  elif T is seq:
    for value in source:
      result.add copyExecutionTemplate(value, copies)
  elif T is object or T is tuple:
    for name, original, copied in fieldPairs(source, result):
      when T is typeof(default(Chunk)[]) and name in ["owner", "dispatchCache"]:
        discard
      else:
        copied = copyExecutionTemplate(original, copies)
  else:
    result = source

proc cloneModuleExecutionTemplate*(compiled: CompiledModule): CompiledModule =
  var copies: Table[pointer, pointer]
  result = copyExecutionTemplate(compiled, copies)
  result.chunk.restoreChunkOwners(allowRuntimeState = true)

proc cloneCompiledChunk*(chunk: Chunk): Chunk =
  ## Each initialized domain owns its mutable invocation metadata. Clone the
  ## inert compiler template before the runtime links declarations into it.
  if chunk == nil:
    raise newException(ValueError, "compiled chunk is missing")
  withMacroCodec:
    result = jsonTo(toJson(chunk), Chunk)
  result.restoreChunkOwners()

proc cloneCompiledModule*(compiled: CompiledModule): CompiledModule =
  withMacroCodec:
    result = jsonTo(toJson(compiled), CompiledModule)
  result.chunk.restoreChunkOwners()

proc encodeExecutableGir*(artifact: ExecutableGir): string =
  if artifact.entryIdentity.len == 0 or artifact.modules.len == 0:
    raise newException(ValueError, "cannot encode an empty GIR artifact")
  var modules = artifact.modules
  modules.sort(proc (a, b: CompiledModule): int = cmp(a.identity, b.identity))
  var seen = initHashSet[string]()
  var foundEntry = false
  for compiled in modules:
    validateModuleSourcePath(compiled.sourcePath)
    if compiled.identity.len == 0 or compiled.chunk == nil or
        compiled.compileInterface == nil or
        seen.containsOrIncl(compiled.identity):
      raise newException(ValueError,
        "GIR artifact module identities must be unique and non-empty")
    if compiled.identity == artifact.entryIdentity:
      foundEntry = true
  if not foundEntry:
    raise newException(ValueError,
      "GIR artifact entry is absent from its module bundle")
  var envelope = newJObject()
  envelope["gir_format"] = %GirArtifactFormat
  envelope["entry_identity"] = %artifact.entryIdentity
  withMacroCodec:
    envelope["modules"] = toJson(modules)
  $envelope

proc decodeExecutableGir*(payload: string): ExecutableGir =
  let envelope = parseJson(payload)
  if envelope.kind != JObject or envelope.len != 3 or
      not envelope.hasKey("gir_format") or
      envelope["gir_format"].kind != JInt or
      envelope["gir_format"].getInt() != GirArtifactFormat or
      not envelope.hasKey("entry_identity") or
      envelope["entry_identity"].kind != JString or
      not envelope.hasKey("modules"):
    raise newException(ValueError, "unsupported or malformed GIR artifact")
  result.entryIdentity = envelope["entry_identity"].getStr()
  withMacroCodec:
    result.modules = jsonTo(envelope["modules"], seq[CompiledModule])
  var seen = initHashSet[string]()
  var foundEntry = false
  var previous = ""
  for index, compiled in result.modules:
    validateModuleSourcePath(compiled.sourcePath)
    if compiled.identity.len == 0 or compiled.chunk == nil or
        compiled.compileInterface == nil or
        seen.containsOrIncl(compiled.identity) or
        (index > 0 and compiled.identity <= previous):
      raise newException(ValueError,
        "GIR artifact module identities must be unique and ordered")
    previous = compiled.identity
    if compiled.identity == result.entryIdentity:
      foundEntry = true
    compiled.chunk.restoreChunkOwners()
  if result.entryIdentity.len == 0 or not foundEntry:
    raise newException(ValueError,
      "GIR artifact entry is absent from its module bundle")
