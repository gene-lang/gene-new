## Deterministic serialization for the Phase-1 executable GIR artifact.
##
## The compiler executable hash is part of every derivation, so this is an
## internal ABI rather than a long-lived interchange format. The explicit
## format number still makes malformed or mismatched payloads fail closed.

import std/[algorithm, json, jsonutils, sets, tables]
import ./[gir, printer, reader, types]

const GirArtifactFormat* = 2

proc toJsonHook(value: Value): JsonNode =
  ## Values reachable from GIR are inert reader data. Canonical Gene text is
  ## the one representation shared with manifests and lockfiles.
  %value.print()

proc fromJsonHook(value: var Value, node: JsonNode) =
  if node.kind != JString:
    raise newException(ValueError, "encoded GIR value must be a string")
  value = read(node.getStr(), "<artifact.gir>",
               ReadOptions(rejectDuplicateProps: true))

proc toJsonHook[V](table: Table[string, V],
                   options = initToJsonOptions()): JsonNode =
  ## std/jsonutils preserves table iteration order, which is deliberately not
  ## stable. Sort string-keyed compiler maps before encoding.
  result = newJObject()
  var keys: seq[string]
  for key in table.keys:
    keys.add key
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

proc toJsonHook(chunk: Chunk,
                options = initToJsonOptions()): JsonNode =
  ## `owner` is the sole upward cursor in the otherwise acyclic GIR tree.
  ## Dispatch cache entries contain process-local Value bits and are runtime
  ## state, not compiled code. Exclude both while letting jsonutils cover the
  ## closed, compiler-owned schema.
  if chunk == nil:
    return newJNull()
  let owner = chunk.owner
  let dispatchCache = chunk.dispatchCache
  chunk.owner = nil
  chunk.dispatchCache = @[]
  try:
    result = toJson(chunk[], options)
  finally:
    chunk.owner = owner
    chunk.dispatchCache = dispatchCache

proc restoreChunkOwners(root: Chunk) =
  var seenChunks = initHashSet[pointer]()
  var seenFunctions = initHashSet[pointer]()

  proc restoreChunk(chunk: Chunk, owner: FunctionProto)

  proc restoreFunction(fn: FunctionProto) =
    if fn == nil or seenFunctions.containsOrIncl(cast[pointer](fn)):
      return
    restoreChunk(fn.chunk, fn)
    restoreChunk(fn.scopelessChunk, fn)
    for defaultValue in fn.paramDefaults:
      restoreChunk(defaultValue.defaultChunk, nil)
    for parameter in fn.namedParams:
      restoreChunk(parameter.defaultValue.defaultChunk, nil)

  proc restoreChunk(chunk: Chunk, owner: FunctionProto) =
    if chunk == nil or seenChunks.containsOrIncl(cast[pointer](chunk)):
      return
    chunk.owner = owner
    chunk.dispatchCache = @[]
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
      for clause in attempt.catches:
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

proc encodeExecutableGir*(artifact: ExecutableGir): string =
  if artifact.entryIdentity.len == 0 or artifact.modules.len == 0:
    raise newException(ValueError, "cannot encode an empty GIR artifact")
  var modules = artifact.modules
  modules.sort(proc (a, b: CompiledModule): int = cmp(a.identity, b.identity))
  var seen = initHashSet[string]()
  var foundEntry = false
  for compiled in modules:
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
  result.modules = jsonTo(envelope["modules"], seq[CompiledModule])
  var seen = initHashSet[string]()
  var foundEntry = false
  var previous = ""
  for index, compiled in result.modules:
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
