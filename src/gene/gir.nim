## Gene Intermediate Representation for the MVP bytecode VM.
##
## GIR is intentionally small here: stack bytecode plus nested compiled function
## prototypes. It is the handoff boundary between syntax compilation and runtime
## execution.

import std/strutils
import ./[printer, types]

type
  OpCode* = enum
    opPushConst
    opLoadName
    opLoadLocal
    opLoadOuterLocal
    opDefineName
    opDefineLocal
    opSetName
    opSetLocal
    opSetOuterLocal
    opPop
    opMakeList
    opMakeListSplice
    opMakeMap
    opMakeNode
    opMakeSelector
    opMakeFn
    opMakeNamespace
    opSetModuleName
    opMakeEnv
    opEval
    opMakeType
    opMakeProtocol
    opMakeImpl
    opImport
    opCall
    opMatch           # pop target, run the first matching branch in a child scope
    opMatchBind       # pop target, destructure against a pattern (or MatchError)
    opMatchBindReplace # pop target, destructure and replace existing loop binds
    opForEach         # pop a collection, run a for-loop body per item
    opMakeIterator    # pop an iterable value, push a stream iterator
    opIteratorHasNext # pop a stream iterator, push Bool
    opIteratorNext    # pop a stream iterator, push next item
    opTry             # run a body with catch clauses and an ensure block
    opTaskScope       # run a structured task scope body
    opSupervisor      # run a supervised actor-owner body
    opSpawn           # run a child task body and push a Task handle
    opAwait           # pop a Task and push/rethrow its completed result
    opFail            # pop an Error value and raise it through GeneError
    opPanic           # pop a value and raise it through GenePanic
    opYield           # suspend a generator and expose the stack top as item
    opJumpIfFalse
    opJump
    opReturn
    opCheckType
    opDeclareType

  Instruction* = object
    op*: OpCode
    intArg*: int
    depth*: int
    name*: string
    names*: seq[string]
    flag*: bool

  ParamDefault* = object
    optional*: bool
    defaultChunk*: Chunk

  NamedParam* = object
    arg*: string
    local*: string
    typeExpr*: Value
    defaultValue*: ParamDefault

  FunctionProto* = ref object of FunctionCode
    name*: string
    typeParams*: seq[string]
    localNames*: seq[string]
    positionalSlots*: seq[int]
    namedSlots*: seq[int]
    restSlot*: int
    params*: seq[string]
    requiredPositional*: int
    simpleCall*: bool
    paramTypes*: seq[Value]
    hasParamTypes*: bool
    paramDefaults*: seq[ParamDefault]
    restParam*: string
    namedParams*: seq[NamedParam]
    hasNamedParamTypes*: bool
    returnType*: Value
    hasReturnType*: bool
    isGenerator*: bool
    checksErrors*: bool
    errorTypeCount*: int
    chunk*: Chunk

  ImportSelection* = object
    name*: string         # exported name in the source
    local*: string        # local name to bind (== name unless aliased)

  ImportSpec* = object
    fromModule*: bool                 # true: `from "path"`; false: namespace path
    modulePath*: string               # the `from "path"` string
    nsSegments*: seq[string]          # namespace-path segments (e.g. std/stream)
    alias*: string                    # `^as alias`, or ""
    selections*: seq[ImportSelection]

  ForProto* = ref object
    pattern*: Value              # loop-variable pattern
    body*: Chunk                 # loop body

  MatchClause* = object
    pattern*: Value
    body*: Chunk

  MatchProto* = ref object
    clauses*: seq[MatchClause]
    elseBody*: Chunk             # nil when there is no else branch

  CatchClause* = object
    pattern*: Value              # matched against the error value
    body*: Chunk

  TryProto* = ref object
    body*: Chunk
    catches*: seq[CatchClause]
    ensureBody*: Chunk           # nil when there is no `ensure`

  NodeBuildProto* = object
    metaNames*: seq[string]
    propNames*: seq[string]
    bodyCount*: int
    bodySplices*: seq[bool]
    immutable*: bool

  ListBuildProto* = object
    splices*: seq[bool]
    immutable*: bool

  TypeProto* = ref object
    name*: string
    fields*: seq[TypeField]      # own (non-inherited) field schema
    bodyFields*: seq[TypeBodyField] # own (non-inherited) body schema
    requiredImplCount*: int
    deriveProtocolCount*: int
    deriveRequests*: seq[Value]

  ProtocolProto* = ref object
    name*: string
    messageNames*: seq[string]
    deriveFn*: FunctionProto

  ImplMessageProto* = object
    name*: string
    fn*: FunctionProto

  ImplProto* = ref object
    messages*: seq[ImplMessageProto]

  Chunk* = ref object
    constants*: seq[Value]
    instructions*: seq[Instruction]
    functions*: seq[FunctionProto]
    localNames*: seq[string]
    mirrorSlots*: bool
    subchunks*: seq[Chunk]       # bodies of `ns` declarations
    imports*: seq[ImportSpec]
    forLoops*: seq[ForProto]
    matches*: seq[MatchProto]
    tries*: seq[TryProto]
    listBuilds*: seq[ListBuildProto]
    nodeBuilds*: seq[NodeBuildProto]
    typeProtos*: seq[TypeProto]
    protocolProtos*: seq[ProtocolProto]
    implProtos*: seq[ImplProto]

proc newChunk*(): Chunk =
  Chunk(constants: @[], instructions: @[], functions: @[], subchunks: @[],
        imports: @[], forLoops: @[], matches: @[], tries: @[], listBuilds: @[],
        nodeBuilds: @[],
        typeProtos: @[], protocolProtos: @[], implProtos: @[])

proc addListBuild*(chunk: Chunk, lp: ListBuildProto): int =
  result = chunk.listBuilds.len
  chunk.listBuilds.add lp

proc addNodeBuild*(chunk: Chunk, np: NodeBuildProto): int =
  result = chunk.nodeBuilds.len
  chunk.nodeBuilds.add np

proc addType*(chunk: Chunk, tp: TypeProto): int =
  result = chunk.typeProtos.len
  chunk.typeProtos.add tp

proc addProtocol*(chunk: Chunk, pp: ProtocolProto): int =
  result = chunk.protocolProtos.len
  chunk.protocolProtos.add pp

proc addImpl*(chunk: Chunk, ip: ImplProto): int =
  result = chunk.implProtos.len
  chunk.implProtos.add ip

proc addForLoop*(chunk: Chunk, fp: ForProto): int =
  result = chunk.forLoops.len
  chunk.forLoops.add fp

proc addMatch*(chunk: Chunk, mp: MatchProto): int =
  result = chunk.matches.len
  chunk.matches.add mp

proc addTry*(chunk: Chunk, tp: TryProto): int =
  result = chunk.tries.len
  chunk.tries.add tp

proc addSubchunk*(chunk: Chunk, body: Chunk): int =
  result = chunk.subchunks.len
  chunk.subchunks.add body

proc addImport*(chunk: Chunk, spec: ImportSpec): int =
  result = chunk.imports.len
  chunk.imports.add spec

proc addConst*(chunk: Chunk, value: Value): int =
  result = chunk.constants.len
  chunk.constants.add value

proc addFunction*(chunk: Chunk, fn: FunctionProto): int =
  result = chunk.functions.len
  chunk.functions.add fn

proc emit*(chunk: Chunk, inst: Instruction): int =
  result = chunk.instructions.len
  chunk.instructions.add inst

proc patchJump*(chunk: Chunk, at, target: int) =
  chunk.instructions[at].intArg = target

proc formatNames(names: openArray[string]): string =
  "[" & names.join(",") & "]"

proc formatInstruction(inst: Instruction): string =
  result = $inst.op
  case inst.op
  of opPushConst:
    result.add " const=" & $inst.intArg
  of opLoadName, opDefineName, opSetName:
    result.add " name=" & inst.name
  of opLoadLocal, opDefineLocal, opSetLocal:
    result.add " slot=" & $inst.intArg
    if inst.name.len > 0:
      result.add " name=" & inst.name
  of opLoadOuterLocal, opSetOuterLocal:
    result.add " depth=" & $inst.depth & " slot=" & $inst.intArg
    if inst.name.len > 0:
      result.add " name=" & inst.name
  of opMakeList:
    result.add " count=" & $inst.intArg
    if inst.flag: result.add " immutable=true"
  of opMakeListSplice:
    result.add " list=" & $inst.intArg
  of opMakeMap:
    result.add " count=" & $inst.intArg & " names=" & formatNames(inst.names)
    if inst.flag: result.add " immutable=true"
  of opMakeNode:
    result.add " node=" & $inst.intArg
  of opMakeSelector:
    result.add " count=" & $inst.intArg
  of opMakeFn:
    result.add " fn=" & $inst.intArg
  of opMakeNamespace:
    result.add " ns=" & $inst.intArg & " name=" & inst.name
  of opSetModuleName:
    result.add " name=" & inst.name
  of opMakeEnv:
    discard
  of opEval:
    discard
  of opCheckType:
    result.add " type=" & $inst.intArg
    if inst.name.len > 0:
      result.add " name=" & inst.name
  of opDeclareType:
    result.add " type=" & $inst.intArg
    if inst.name.len > 0:
      result.add " name=" & inst.name
  of opMakeType:
    result.add " type=" & $inst.intArg
  of opMakeProtocol:
    result.add " protocol=" & $inst.intArg
  of opMakeImpl:
    result.add " impl=" & $inst.intArg
  of opImport:
    result.add " import=" & $inst.intArg
  of opCall:
    result.add " argc=" & $inst.intArg
    if inst.names.len > 0:
      result.add " names=" & formatNames(inst.names)
  of opMatch:
    result.add " match=" & $inst.intArg
  of opMatchBind, opMatchBindReplace:
    result.add " pattern=" & $inst.intArg
  of opForEach:
    result.add " for=" & $inst.intArg
  of opTry:
    result.add " try=" & $inst.intArg
  of opTaskScope, opSpawn:
    result.add " body=" & $inst.intArg
  of opSupervisor:
    result.add " body=" & $inst.intArg & " strategy=" & inst.name
  of opFail, opPanic:
    discard
  of opJumpIfFalse, opJump:
    result.add " target=" & $inst.intArg
  of opPop, opMakeIterator, opIteratorHasNext, opIteratorNext, opAwait, opYield,
     opReturn:
    discard

proc addDisassembly(lines: var seq[string], chunk: Chunk, indent = "") =
  lines.add indent & "constants:"
  if chunk.constants.len == 0:
    lines.add indent & "  <none>"
  else:
    for i, value in chunk.constants:
      lines.add indent & "  [" & $i & "] " & value.print()

  if chunk.localNames.len > 0:
    lines.add indent & "locals: " & formatNames(chunk.localNames)

  lines.add indent & "instructions:"
  if chunk.instructions.len == 0:
    lines.add indent & "  <none>"
  else:
    for i, inst in chunk.instructions:
      lines.add indent & "  " & $i & ": " & formatInstruction(inst)

  if chunk.functions.len > 0:
    lines.add indent & "functions:"
    for i, fn in chunk.functions:
      let label = if fn.name.len > 0: fn.name else: "<anon>"
      var header = indent & "  [" & $i & "] " & label &
        " params=" & formatNames(fn.params)
      if fn.typeParams.len > 0:
        header.add " type-params=" & formatNames(fn.typeParams)
      if fn.localNames.len > 0:
        header.add " locals=" & formatNames(fn.localNames)
      if fn.paramTypes.len > 0:
        var types: seq[string]
        for t in fn.paramTypes:
          types.add(if t.kind == vkNil: "_" else: t.print())
        header.add " param-types=" & formatNames(types)
      if fn.restParam.len > 0:
        header.add " rest=" & fn.restParam
      if fn.namedParams.len > 0:
        var names: seq[string]
        for p in fn.namedParams:
          var desc = if p.local == p.arg: p.arg else: p.arg & ":" & p.local
          if p.typeExpr.kind != vkNil:
            desc.add " " & p.typeExpr.print()
          names.add desc
        header.add " named=" & formatNames(names)
      if fn.returnType.kind != vkNil:
        header.add " return=" & fn.returnType.print()
      if fn.checksErrors:
        header.add " errors=" & $fn.errorTypeCount
      lines.add header
      addDisassembly(lines, fn.chunk, indent & "    ")

  if chunk.subchunks.len > 0:
    lines.add indent & "namespaces:"
    for i, sub in chunk.subchunks:
      lines.add indent & "  [" & $i & "]"
      addDisassembly(lines, sub, indent & "    ")

  if chunk.forLoops.len > 0:
    lines.add indent & "for-loops:"
    for i, fp in chunk.forLoops:
      lines.add indent & "  [" & $i & "] pattern=" & fp.pattern.print()
      addDisassembly(lines, fp.body, indent & "    ")

  if chunk.matches.len > 0:
    lines.add indent & "matches:"
    for i, mp in chunk.matches:
      lines.add indent & "  [" & $i & "]"
      for cl in mp.clauses:
        lines.add indent & "  when " & cl.pattern.print() & ":"
        addDisassembly(lines, cl.body, indent & "    ")
      if mp.elseBody != nil:
        lines.add indent & "  else:"
        addDisassembly(lines, mp.elseBody, indent & "    ")

  if chunk.tries.len > 0:
    lines.add indent & "tries:"
    for i, tp in chunk.tries:
      lines.add indent & "  [" & $i & "] body:"
      addDisassembly(lines, tp.body, indent & "    ")
      for j, cl in tp.catches:
        lines.add indent & "  catch " & cl.pattern.print() & ":"
        addDisassembly(lines, cl.body, indent & "    ")
      if tp.ensureBody != nil:
        lines.add indent & "  ensure:"
        addDisassembly(lines, tp.ensureBody, indent & "    ")

  if chunk.imports.len > 0:
    lines.add indent & "imports:"
    for i, spec in chunk.imports:
      var src =
        if spec.fromModule: "\"" & spec.modulePath & "\""
        else: spec.nsSegments.join("/")
      var desc = indent & "  [" & $i & "] " & src
      if spec.alias.len > 0:
        desc.add " as=" & spec.alias
      if spec.selections.len > 0:
        var sels: seq[string]
        for s in spec.selections:
          sels.add (if s.name == s.local: s.name else: s.name & ":" & s.local)
        desc.add " " & formatNames(sels)
      lines.add desc

  if chunk.protocolProtos.len > 0:
    lines.add indent & "protocols:"
    for i, pp in chunk.protocolProtos:
      var desc = indent & "  [" & $i & "] " & pp.name &
        " messages=" & formatNames(pp.messageNames)
      if pp.deriveFn != nil:
        desc.add " derive=true"
      lines.add desc

  if chunk.implProtos.len > 0:
    lines.add indent & "impls:"
    for i, ip in chunk.implProtos:
      var names: seq[string]
      for m in ip.messages:
        names.add m.name
      lines.add indent & "  [" & $i & "] messages=" & formatNames(names)

proc disassemble*(chunk: Chunk): string =
  var lines: seq[string]
  addDisassembly(lines, chunk)
  lines.join("\n")
