## Gene Intermediate Representation for the MVP bytecode VM.
##
## GIR is intentionally small here: stack bytecode plus nested compiled function
## prototypes. It is the handoff boundary between syntax compilation and runtime
## execution.

import std/[strutils, tables]
import ./[printer, types]

type
  OpCode* = enum
    opNoop
    opPushConst
    opLoadName
    opLoadNativeFast
    opLoadLocal
    opLoadLocalFast
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
    opApplySelector
    opMakeFn
    opMakeNamespace
    opSetModuleName
    opMakeEnv
    opEval
    opMakeType
    opMakeProtocol
    opMakeImpl
    opImport
    opCall0
    opCall1
    opCallName0
    opCallName1
    opCallLocal0
    opCallLocal1
    opCallParentLocal1
    opCallOuterLocal1
    opRecur1
    opRecur1LocalIntSubConst
    opCall2
    opCall
    opCallSplice
    opIntAdd2
    opIntSub2
    opIntMul2
    opIntLt2
    opIntGt2
    opIntLe2
    opIntGe2
    opIntAddConst
    opIntSubConst
    opIntMulConst
    opIntLtConst
    opIntGtConst
    opIntLeConst
    opIntGeConst
    opIntFast2
    opIntFastConst
    opNativeFast2
    opNativeFastConst
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
    opReturnBareInt
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

  NativeCompileOp* = enum
    ncoNone
    ncoIntAdd
    ncoIntSub
    ncoIntMul
    ncoI64Add
    ncoI64Sub
    ncoI64Mul
    ncoF64Add
    ncoF64Sub
    ncoF64Mul

  AotFrameKind* = enum
    afkNone
    afkTypedNative

  TaskFrameKind* = enum
    tfkNone
    tfkVm
    tfkGenerator

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
    positionalSlotMaySet*: seq[bool]
    namedSlots*: seq[int]
    restSlot*: int
    params*: seq[string]
    requiredPositional*: int
    simpleCall*: bool
    needsCallScope*: bool
    poolCallScope*: bool
    callScopeNeedsSlotNames*: bool
    callScopeNeedsSlotReset*: bool
    paramTypes*: seq[Value]
    hasParamTypes*: bool
    paramDefaults*: seq[ParamDefault]
    restParam*: string
    namedParams*: seq[NamedParam]
    hasNamedParamTypes*: bool
    returnType*: Value
    hasReturnType*: bool
    returnKnownBareInt*: bool
    isGenerator*: bool
    selfParentSlot*: int
    nativeOp*: NativeCompileOp
    aotExpr*: Value
    aotFrameKind*: AotFrameKind
    aotFrameCanSuspend*: bool
    taskFrameKind*: TaskFrameKind
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

  FfiParam* = object
    name*: string
    typeExpr*: Value

  FfiFnProto* = ref object
    name*: string
    library*: string
    symbol*: string
    abi*: string
    params*: seq[FfiParam]
    returnType*: Value
    release*: string

  FfiStructField* = object
    name*: string
    typeExpr*: Value
    offset*: int
    hasOffset*: bool

  FfiStructProto* = ref object
    name*: string
    layout*: string
    size*: int
    hasSize*: bool
    align*: int
    hasAlign*: bool
    fields*: seq[FfiStructField]

  FfiUnionProto* = ref object
    name*: string
    layout*: string
    size*: int
    hasSize*: bool
    align*: int
    hasAlign*: bool
    fields*: seq[FfiStructField]

  FfiSignatureKind* = enum
    fskCallback
    fskDynamic

  FfiSignatureProto* = ref object
    name*: string
    kind*: FfiSignatureKind
    abi*: string
    params*: seq[FfiParam]
    returnType*: Value
    escaping*: bool
    runtimeConstructible*: bool

  MonomorphizationSpec* = object
    functionName*: string
    typeArgs*: seq[Value]

  DirectProtocolCallSpec* = object
    messageName*: string
    protocolExpr*: Value
    receiverExpr*: Value

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
    owner* {.cursor.}: FunctionProto
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
    ffiFns*: seq[FfiFnProto]
    ffiStructs*: seq[FfiStructProto]
    ffiUnions*: seq[FfiUnionProto]
    ffiSignatures*: seq[FfiSignatureProto]
    monomorphizations*: seq[MonomorphizationSpec]
    directProtocolCalls*: seq[DirectProtocolCallSpec]
    callSites*: Table[int, Value]   # opCall/opCallSplice index -> source node (design §3 `Call ^site`)

proc newChunk*(): Chunk =
  Chunk(constants: @[], instructions: @[], functions: @[], subchunks: @[],
        imports: @[], forLoops: @[], matches: @[], tries: @[], listBuilds: @[],
        nodeBuilds: @[],
        typeProtos: @[], protocolProtos: @[], implProtos: @[],
        ffiFns: @[], ffiStructs: @[], ffiUnions: @[], ffiSignatures: @[],
        monomorphizations: @[], directProtocolCalls: @[],
        callSites: initTable[int, Value]())

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

proc addFfiFn*(chunk: Chunk, fn: FfiFnProto): int =
  result = chunk.ffiFns.len
  chunk.ffiFns.add fn

proc addFfiStruct*(chunk: Chunk, structProto: FfiStructProto): int =
  result = chunk.ffiStructs.len
  chunk.ffiStructs.add structProto

proc addFfiUnion*(chunk: Chunk, unionProto: FfiUnionProto): int =
  result = chunk.ffiUnions.len
  chunk.ffiUnions.add unionProto

proc addFfiSignature*(chunk: Chunk, signature: FfiSignatureProto): int =
  result = chunk.ffiSignatures.len
  chunk.ffiSignatures.add signature

proc addMonomorphization*(chunk: Chunk, spec: MonomorphizationSpec): int =
  result = chunk.monomorphizations.len
  chunk.monomorphizations.add spec

proc addDirectProtocolCall*(chunk: Chunk,
                            spec: DirectProtocolCallSpec): int =
  result = chunk.directProtocolCalls.len
  chunk.directProtocolCalls.add spec

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

proc formatNativeOp(op: NativeCompileOp): string =
  case op
  of ncoNone: "none"
  of ncoIntAdd: "int-add"
  of ncoIntSub: "int-sub"
  of ncoIntMul: "int-mul"
  of ncoI64Add: "i64-add"
  of ncoI64Sub: "i64-sub"
  of ncoI64Mul: "i64-mul"
  of ncoF64Add: "f64-add"
  of ncoF64Sub: "f64-sub"
  of ncoF64Mul: "f64-mul"

proc formatAotFrameKind(kind: AotFrameKind): string =
  case kind
  of afkNone: "none"
  of afkTypedNative: "typed-native"

proc formatTaskFrameKind(kind: TaskFrameKind): string =
  case kind
  of tfkNone: "none"
  of tfkVm: "vm"
  of tfkGenerator: "generator"

proc formatFfiSignatureKind(kind: FfiSignatureKind): string =
  case kind
  of fskCallback: "callback"
  of fskDynamic: "dynamic"

proc formatAotRepr(fn: FunctionProto): string =
  if fn.returnType.kind != vkSymbol:
    return ""
  case fn.returnType.symVal
  of "I64": "I64"
  of "F64": "F64"
  else: ""

proc formatInstruction(inst: Instruction): string =
  result = $inst.op
  case inst.op
  of opPushConst:
    result.add " const=" & $inst.intArg
  of opLoadName, opLoadNativeFast, opDefineName, opSetName:
    result.add " name=" & inst.name
  of opLoadLocal, opLoadLocalFast, opDefineLocal, opSetLocal:
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
  of opApplySelector:
    discard
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
  of opCall0:
    result.add " argc=0"
  of opCall1:
    result.add " argc=1"
  of opCallName0:
    result.add " name=" & inst.name & " argc=0"
  of opCallName1:
    result.add " name=" & inst.name & " argc=1"
  of opCallLocal0:
    result.add " slot=" & $inst.intArg & " name=" & inst.name & " argc=0"
  of opCallLocal1:
    result.add " slot=" & $inst.intArg & " name=" & inst.name & " argc=1"
  of opCallParentLocal1:
    result.add " slot=" & $inst.intArg & " name=" & inst.name & " argc=1"
  of opCallOuterLocal1:
    result.add " depth=" & $inst.depth & " slot=" & $inst.intArg &
      " name=" & inst.name & " argc=1"
  of opRecur1:
    result.add " argc=1"
  of opRecur1LocalIntSubConst:
    result.add " slot=" & $inst.intArg & " name=" & inst.name &
      " const=" & $inst.depth & " argc=1"
  of opCall2:
    result.add " argc=2"
  of opCall:
    result.add " argc=" & $inst.intArg
    if inst.names.len > 0:
      result.add " names=" & formatNames(inst.names)
  of opCallSplice:
    result.add " list=" & $inst.intArg
    if inst.names.len > 0:
      result.add " names=" & formatNames(inst.names)
  of opIntAdd2, opIntSub2, opIntMul2, opIntLt2, opIntGt2, opIntLe2,
     opIntGe2, opIntFast2:
    result.add " name=" & inst.name
  of opIntAddConst, opIntSubConst, opIntMulConst, opIntLtConst,
     opIntGtConst, opIntLeConst, opIntGeConst, opIntFastConst:
    result.add " name=" & inst.name & " const=" & $inst.depth
  of opNativeFast2:
    result.add " name=" & inst.name
  of opNativeFastConst:
    result.add " name=" & inst.name & " const=" & $inst.depth
  of opMatch:
    result.add " match=" & $inst.intArg
  of opMatchBind, opMatchBindReplace:
    result.add " pattern=" & $inst.intArg
  of opForEach:
    result.add " for=" & $inst.intArg
  of opTry:
    result.add " try=" & $inst.intArg
  of opTaskScope:
    result.add " body=" & $inst.intArg
  of opSpawn:
    result.add " body=" & $inst.intArg
    if inst.flag:
      result.add " worker-candidate=true"
  of opSupervisor:
    result.add " body=" & $inst.intArg & " strategy=" & inst.name
    if inst.names.len > 0:
      result.add " sinks=" & formatNames(inst.names)
  of opFail, opPanic:
    discard
  of opJumpIfFalse, opJump:
    result.add " target=" & $inst.intArg
  of opNoop, opPop, opMakeIterator, opIteratorHasNext, opIteratorNext, opAwait,
     opYield, opReturn, opReturnBareInt:
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
      if fn.nativeOp != ncoNone:
        header.add " native=" & formatNativeOp(fn.nativeOp)
      if fn.aotExpr.kind != vkNil:
        header.add " aot=c"
      if fn.aotFrameKind != afkNone:
        header.add " frame=" & formatAotFrameKind(fn.aotFrameKind)
        if fn.aotFrameCanSuspend:
          header.add " suspend=true"
      if fn.taskFrameKind != tfkNone:
        header.add " task-frame=" & formatTaskFrameKind(fn.taskFrameKind)
      if fn.checksErrors:
        header.add " errors=" & $fn.errorTypeCount
      lines.add header
      addDisassembly(lines, fn.chunk, indent & "    ")

  var aotFns: seq[string]
  for fn in chunk.functions:
    let repr = fn.formatAotRepr
    if fn.aotExpr.kind != vkNil and repr.len > 0:
      var desc = fn.name & " repr=" & repr & " arity=" & $fn.params.len
      if fn.aotFrameKind != afkNone:
        desc.add " frame=" & formatAotFrameKind(fn.aotFrameKind)
      if fn.aotFrameCanSuspend:
        desc.add " suspend=true"
      aotFns.add desc
  if aotFns.len > 0:
    lines.add indent & "typed-module-aot:"
    for i, desc in aotFns:
      lines.add indent & "  [" & $i & "] " & desc

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

  if chunk.ffiFns.len > 0:
    lines.add indent & "ffi-fns:"
    for i, fn in chunk.ffiFns:
      var params: seq[string]
      for p in fn.params:
        params.add p.name & ":" & p.typeExpr.print()
      var desc = indent & "  [" & $i & "] " & fn.name &
        " symbol=" & fn.symbol &
        " abi=" & fn.abi &
        " params=" & formatNames(params)
      if fn.library.len > 0:
        desc.add " library=" & fn.library
      if fn.returnType.kind != vkNil:
        desc.add " return=" & fn.returnType.print()
      if fn.release.len > 0:
        desc.add " release=" & fn.release
      lines.add desc

  if chunk.ffiStructs.len > 0:
    lines.add indent & "ffi-structs:"
    for i, structProto in chunk.ffiStructs:
      var fields: seq[string]
      for field in structProto.fields:
        var desc = field.name & ":" & field.typeExpr.print()
        if field.hasOffset:
          desc.add "@" & $field.offset
        fields.add desc
      var desc = indent & "  [" & $i & "] " & structProto.name &
        " layout=" & structProto.layout &
        " fields=" & formatNames(fields)
      if structProto.hasSize:
        desc.add " size=" & $structProto.size
      if structProto.hasAlign:
        desc.add " align=" & $structProto.align
      lines.add desc

  if chunk.ffiUnions.len > 0:
    lines.add indent & "ffi-unions:"
    for i, unionProto in chunk.ffiUnions:
      var fields: seq[string]
      for field in unionProto.fields:
        fields.add field.name & ":" & field.typeExpr.print()
      var desc = indent & "  [" & $i & "] " & unionProto.name &
        " layout=" & unionProto.layout &
        " fields=" & formatNames(fields)
      if unionProto.hasSize:
        desc.add " size=" & $unionProto.size
      if unionProto.hasAlign:
        desc.add " align=" & $unionProto.align
      lines.add desc

  if chunk.ffiSignatures.len > 0:
    lines.add indent & "ffi-signatures:"
    for i, signature in chunk.ffiSignatures:
      var params: seq[string]
      for p in signature.params:
        params.add p.name & ":" & p.typeExpr.print()
      var desc = indent & "  [" & $i & "] " & signature.name &
        " kind=" & formatFfiSignatureKind(signature.kind) &
        " abi=" & signature.abi &
        " params=" & formatNames(params)
      if signature.returnType.kind != vkNil:
        desc.add " return=" & signature.returnType.print()
      if signature.escaping:
        desc.add " escaping=true"
      if signature.runtimeConstructible:
        desc.add " runtime=true"
      lines.add desc

  if chunk.monomorphizations.len > 0:
    lines.add indent & "monomorphizations:"
    for i, spec in chunk.monomorphizations:
      var args: seq[string]
      for arg in spec.typeArgs:
        args.add arg.print()
      lines.add indent & "  [" & $i & "] " & spec.functionName &
        "<" & args.join(",") & ">"

  if chunk.directProtocolCalls.len > 0:
    lines.add indent & "direct-protocol-calls:"
    for i, spec in chunk.directProtocolCalls:
      lines.add indent & "  [" & $i & "] " & spec.messageName &
        " protocol=" & spec.protocolExpr.print() &
        " receiver=" & spec.receiverExpr.print()

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

proc cIdent(name: string, fallback: string): string =
  result = if name.len == 0: fallback else: name
  for i, ch in result:
    if not (ch.isAlphaNumeric or ch == '_'):
      result[i] = '_'
  if result.len == 0 or result[0].isDigit:
    result = "_" & result

proc cStringLiteral(text: string): string =
  result = "\""
  for ch in text:
    case ch
    of '\\':
      result.add "\\\\"
    of '"':
      result.add "\\\""
    of '\n':
      result.add "\\n"
    of '\r':
      result.add "\\r"
    of '\t':
      result.add "\\t"
    else:
      result.add ch
  result.add "\""

proc aotTypeName(fn: FunctionProto): string =
  fn.formatAotRepr

proc aotCType(typeName: string): string =
  case typeName
  of "I64": "int64_t"
  of "F64": "double"
  else: ""

type AotCFunction = object
  cName: string
  paramCount: int
  cType: string

type AotModuleFunction = object
  geneName: string
  cName: string
  typeName: string
  paramCount: int
  frameName: string

type MonomorphizationCRow = object
  functionName: string
  typeArgs: string

type DirectProtocolCRow = object
  messageName: string
  protocolName: string
  receiverName: string

type TaskFrameCRow = object
  functionName: string
  kind: string
  canSuspend: bool

type FfiStructCRow = object
  name: string
  layout: string
  size: int
  align: int
  fieldCount: int

type FfiStructFieldCRow = object
  structName: string
  fieldName: string
  typeName: string
  offset: int

type FfiUnionCRow = object
  name: string
  layout: string
  size: int
  align: int
  fieldCount: int

type FfiUnionFieldCRow = object
  unionName: string
  fieldName: string
  typeName: string

type FfiSignatureCRow = object
  name: string
  kind: string
  abi: string
  params: string
  resultType: string
  escaping: bool
  runtimeConstructible: bool

type FfiMarshalKind = enum
  fmkUnsupported
  fmkVoid
  fmkScalar
  fmkCStr
  fmkPtr
  fmkConstPtr
  fmkBuffer

proc emitAotCExpr(expr: Value, params: openArray[string],
                  available: Table[string, AotCFunction]): string =
  case expr.kind
  of vkSymbol:
    cIdent(expr.symVal, "arg")
  of vkInt:
    $expr.intVal
  of vkFloat:
    expr.print()
  of vkNode:
    let head = expr.head.symVal
    if head in ["+", "-", "*"] and expr.body.len == 2:
      "(" & emitAotCExpr(expr.body[0], params, available) & " " & head & " " &
        emitAotCExpr(expr.body[1], params, available) & ")"
    elif available.hasKey(head):
      var args: seq[string]
      for arg in expr.body:
        args.add emitAotCExpr(arg, params, available)
      available[head].cName & "(" & args.join(", ") & ")"
    else:
      "0"
  else:
    "0"

proc ffiTypeLabel(expr: Value): string =
  case expr.kind
  of vkSymbol:
    expr.symVal
  of vkNode:
    if expr.head.kind == vkSymbol and expr.head.symVal == "path":
      var segments: seq[string]
      for item in expr.body:
        if item.kind == vkSymbol:
          segments.add item.symVal
        else:
          segments.add ffiTypeLabel(item)
      segments.join("/")
    else:
      var parts = @[ffiTypeLabel(expr.head)]
      for item in expr.body:
        parts.add ffiTypeLabel(item)
      "(" & parts.join(" ") & ")"
  else:
    expr.print()

proc ffiCType(label: string, paramName = ""): string =
  case label
  of "C/Int8": "int8_t"
  of "C/UInt8": "uint8_t"
  of "C/Int16": "int16_t"
  of "C/UInt16": "uint16_t"
  of "C/Int32": "int32_t"
  of "C/UInt32": "uint32_t"
  of "C/Int64": "int64_t"
  of "C/UInt64": "uint64_t"
  of "C/Char": "char"
  of "C/UChar": "unsigned char"
  of "C/Short": "short"
  of "C/UShort": "unsigned short"
  of "C/Int": "int"
  of "C/UInt": "unsigned int"
  of "C/Long": "long"
  of "C/ULong": "unsigned long"
  of "C/Size": "size_t"
  of "C/PtrDiff": "ptrdiff_t"
  of "C/Float": "float"
  of "C/Double": "double"
  of "C/Bool": "bool"
  of "C/Void": "void"
  of "C/CStr": "const char *"
  else:
    if label.startsWith("(C/ConstPtr ") or label.startsWith("(C/NullableConstPtr "):
      "const void *"
    elif label.startsWith("(C/Ptr ") or label.startsWith("(C/NullablePtr ") or
        label.startsWith("(C/OwnedPtr "):
      "void *"
    elif label.startsWith("(C/Slice ") or label.startsWith("(Buffer "):
      if paramName.len > 0: "const void *"
      else: "void *"
    else:
      "void *"

proc ffiMarshalKind(label: string, isResult = false): FfiMarshalKind =
  case label
  of "C/Void":
    if isResult: fmkVoid else: fmkUnsupported
  of "C/Int8", "C/UInt8", "C/Int16", "C/UInt16", "C/Int32", "C/UInt32",
     "C/Int64", "C/UInt64", "C/Char", "C/UChar", "C/Short", "C/UShort",
     "C/Int", "C/UInt", "C/Long", "C/ULong", "C/Size", "C/PtrDiff",
     "C/Float", "C/Double", "C/Bool":
    fmkScalar
  of "C/CStr":
    fmkCStr
  else:
    if label.startsWith("(C/ConstPtr ") or
        label.startsWith("(C/NullableConstPtr "):
      fmkConstPtr
    elif label.startsWith("(C/Ptr ") or label.startsWith("(C/NullablePtr ") or
        label.startsWith("(C/OwnedPtr "):
      fmkPtr
    elif not isResult and
        (label.startsWith("(C/Slice ") or label.startsWith("(Buffer ")):
      fmkBuffer
    else:
      fmkUnsupported

proc ffiHelperSuffix(label: string): string =
  case label
  of "C/Int8": "int8"
  of "C/UInt8": "uint8"
  of "C/Int16": "int16"
  of "C/UInt16": "uint16"
  of "C/Int32": "int32"
  of "C/UInt32": "uint32"
  of "C/Int64": "int64"
  of "C/UInt64": "uint64"
  of "C/Char": "char"
  of "C/UChar": "uchar"
  of "C/Short": "short"
  of "C/UShort": "ushort"
  of "C/Int": "int"
  of "C/UInt": "uint"
  of "C/Long": "long"
  of "C/ULong": "ulong"
  of "C/Size": "size"
  of "C/PtrDiff": "ptrdiff"
  of "C/Float": "float"
  of "C/Double": "double"
  of "C/Bool": "bool"
  of "C/CStr": "cstr"
  else:
    case ffiMarshalKind(label)
    of fmkPtr: "ptr"
    of fmkConstPtr: "const_ptr"
    of fmkBuffer: "buffer"
    else: "unsupported"

proc ffiResultHelperSuffix(label: string): string =
  case ffiMarshalKind(label, isResult = true)
  of fmkVoid: "void"
  of fmkPtr, fmkConstPtr: "ptr"
  else: ffiHelperSuffix(label)

proc ffiWrapperSupported(fn: FfiFnProto, retLabel: string): bool =
  for p in fn.params:
    if ffiMarshalKind(ffiTypeLabel(p.typeExpr)) == fmkUnsupported:
      return false
  ffiMarshalKind(retLabel, isResult = true) != fmkUnsupported

proc ffiWrapperName(fn: FfiFnProto, fallback: string): string =
  "gene_ffi_" & cIdent(if fn.name.len > 0: fn.name else: fn.symbol, fallback)

proc aotModuleManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "aot_module", "aot_module")

proc monomorphizationManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "monomorphizations", "monomorphizations")

proc directProtocolManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "direct_protocol_calls", "direct_protocol_calls")

proc taskFrameManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "task_frames", "task_frames")

proc ffiStructManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "ffi_structs", "ffi_structs")

proc ffiStructFieldManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "ffi_struct_fields", "ffi_struct_fields")

proc ffiUnionManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "ffi_unions", "ffi_unions")

proc ffiUnionFieldManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "ffi_union_fields", "ffi_union_fields")

proc ffiSignatureManifestName(prefix: string): string =
  "gene_" & cIdent(prefix & "ffi_signatures", "ffi_signatures")

proc addFfiWrapper(lines: var seq[string], fn: FfiFnProto, index: int,
                   prefix: string) =
  let symbol = if fn.symbol.len > 0: fn.symbol else: fn.name
  let cSymbol = cIdent(symbol, "ffi_symbol_" & $index)
  let retLabel =
    if fn.returnType.kind == vkNil: "C/Void" else: ffiTypeLabel(fn.returnType)
  let retType = ffiCType(retLabel)
  let supported = ffiWrapperSupported(fn, retLabel)
  var declParams: seq[string]
  for i, p in fn.params:
    let label = ffiTypeLabel(p.typeExpr)
    let name = cIdent(p.name, "arg" & $i)
    declParams.add ffiCType(label, name) & " " & name
  let paramList = if declParams.len == 0: "void" else: declParams.join(", ")
  lines.add "extern " & retType & " " & cSymbol & "(" & paramList & ");"
  lines.add "GeneStatus " & ffiWrapperName(fn, prefix & "ffi_" & $index) &
    "(GeneContext *ctx, const GeneCall *call, GeneValue *result) {"
  lines.add "  /* library: " & (if fn.library.len > 0: fn.library else: "<linker>") & " */"
  lines.add "  /* abi: " & (if fn.abi.len > 0: fn.abi else: "C") & " */"
  for i, p in fn.params:
    let label = ffiTypeLabel(p.typeExpr)
    lines.add "  /* arg " & $i & " " & p.name & ": " & label &
      " -> " & ffiCType(label, p.name) & " */"
  if retLabel != "C/Void":
    lines.add "  /* result: " & retLabel & " -> GeneValue */"
  if fn.release.len > 0:
    lines.add "  /* owned release: " & fn.release & " */"
  if not supported:
    lines.add "  (void)ctx;"
    lines.add "  (void)call;"
    lines.add "  (void)result;"
    lines.add "  return GENE_FFI_WRAPPER_UNIMPLEMENTED;"
    lines.add "}"
    lines.add ""
    return
  lines.add "  GeneStatus status = gene_ffi_check_arity(ctx, call, " &
    $fn.params.len & ");"
  lines.add "  if (status != GENE_OK) return status;"
  var callArgs: seq[string]
  for i, p in fn.params:
    let label = ffiTypeLabel(p.typeExpr)
    let name = cIdent(p.name, "arg" & $i)
    case ffiMarshalKind(label)
    of fmkScalar:
      lines.add "  " & ffiCType(label, name) & " " & name & ";"
      lines.add "  status = gene_ffi_arg_" & ffiHelperSuffix(label) &
        "(ctx, call, " & $i & ", " & cStringLiteral(p.name) & ", &" &
        name & ");"
      lines.add "  if (status != GENE_OK) return status;"
      callArgs.add name
    of fmkCStr:
      lines.add "  const char *" & name & ";"
      lines.add "  status = gene_ffi_arg_cstr(ctx, call, " & $i & ", " &
        cStringLiteral(p.name) & ", &" & name & ");"
      lines.add "  if (status != GENE_OK) return status;"
      callArgs.add name
    of fmkPtr:
      lines.add "  void *" & name & ";"
      lines.add "  status = gene_ffi_arg_ptr(ctx, call, " & $i & ", " &
        cStringLiteral(p.name) & ", " & cStringLiteral(label) & ", &" &
        name & ");"
      lines.add "  if (status != GENE_OK) return status;"
      callArgs.add name
    of fmkConstPtr:
      lines.add "  const void *" & name & ";"
      lines.add "  status = gene_ffi_arg_const_ptr(ctx, call, " & $i & ", " &
        cStringLiteral(p.name) & ", " & cStringLiteral(label) & ", &" &
        name & ");"
      lines.add "  if (status != GENE_OK) return status;"
      callArgs.add name
    of fmkBuffer:
      lines.add "  GeneFfiBufferView " & name & "_view;"
      lines.add "  status = gene_ffi_arg_buffer(ctx, call, " & $i & ", " &
        cStringLiteral(p.name) & ", " & cStringLiteral(label) & ", &" &
        name & "_view);"
      lines.add "  if (status != GENE_OK) return status;"
      lines.add "  const void *" & name & " = " & name & "_view.data;"
      callArgs.add name
    else:
      discard
  let args = callArgs.join(", ")
  case ffiMarshalKind(retLabel, isResult = true)
  of fmkVoid:
    lines.add "  " & cSymbol & "(" & args & ");"
    lines.add "  return gene_ffi_result_void(ctx, result);"
  of fmkScalar, fmkCStr:
    lines.add "  " & retType & " native_result = " & cSymbol & "(" &
      args & ");"
    lines.add "  return gene_ffi_result_" & ffiResultHelperSuffix(retLabel) &
      "(ctx, native_result, result);"
  of fmkPtr, fmkConstPtr:
    lines.add "  " & retType & " native_result = " & cSymbol & "(" &
      args & ");"
    lines.add "  return gene_ffi_result_ptr(ctx, (void *)native_result, " &
      cStringLiteral(retLabel) & ", " &
      (if fn.release.len > 0: cStringLiteral(fn.release) else: "NULL") &
      ", result);"
  else:
    lines.add "  return GENE_FFI_WRAPPER_UNIMPLEMENTED;"
  lines.add "}"
  lines.add ""

proc addCBackend(lines: var seq[string], chunk: Chunk, prefix = "",
                 available: var Table[string, AotCFunction]) =
  for i, fn in chunk.ffiFns:
    addFfiWrapper(lines, fn, i, prefix)
  var structRows: seq[FfiStructCRow]
  var structFieldRows: seq[FfiStructFieldCRow]
  for structProto in chunk.ffiStructs:
    let cStructName = cIdent(structProto.name, "FfiStruct")
    if structProto.layout == "C":
      lines.add "typedef struct " & cStructName & " {"
      for i, field in structProto.fields:
        let fieldType = ffiCType(ffiTypeLabel(field.typeExpr))
        lines.add "  " & fieldType & " " &
          cIdent(field.name, "field_" & $i) & ";"
      lines.add "} " & cStructName & ";"
      if structProto.hasSize:
        lines.add "_Static_assert(sizeof(" & cStructName & ") == " &
          $structProto.size & ", " &
          cStringLiteral("ffi/struct " & structProto.name & " size mismatch") &
          ");"
      if structProto.hasAlign:
        lines.add "_Static_assert(GENE_ALIGNOF(" & cStructName & ") == " &
          $structProto.align & ", " &
          cStringLiteral("ffi/struct " & structProto.name & " align mismatch") &
          ");"
      for field in structProto.fields:
        if field.hasOffset:
          lines.add "_Static_assert(offsetof(" & cStructName & ", " &
            cIdent(field.name, "field") & ") == " & $field.offset & ", " &
            cStringLiteral("ffi/struct " & structProto.name & "." &
              field.name & " offset mismatch") & ");"
      lines.add ""
    structRows.add FfiStructCRow(name: structProto.name,
                                 layout: structProto.layout,
                                 size: if structProto.hasSize: structProto.size else: -1,
                                 align: if structProto.hasAlign: structProto.align else: -1,
                                 fieldCount: structProto.fields.len)
    for field in structProto.fields:
      structFieldRows.add FfiStructFieldCRow(
        structName: structProto.name,
        fieldName: field.name,
        typeName: ffiTypeLabel(field.typeExpr),
        offset: if field.hasOffset: field.offset else: -1)
  if structRows.len > 0:
    let manifestName = ffiStructManifestName(prefix)
    lines.add "static const GeneFfiStructInfo " & manifestName & "[] = {"
    for row in structRows:
      lines.add "  {" & cStringLiteral(row.name) & ", " &
        cStringLiteral(row.layout) & ", " & $row.size & ", " & $row.align &
        ", " & $row.fieldCount & "},"
    lines.add "};"
    lines.add "static const size_t " & manifestName & "_count = " &
      $structRows.len & ";"
    let fieldManifestName = ffiStructFieldManifestName(prefix)
    lines.add "static const GeneFfiStructFieldInfo " & fieldManifestName &
      "[] = {"
    for row in structFieldRows:
      lines.add "  {" & cStringLiteral(row.structName) & ", " &
        cStringLiteral(row.fieldName) & ", " & cStringLiteral(row.typeName) &
        ", " & $row.offset & "},"
    lines.add "};"
    lines.add "static const size_t " & fieldManifestName & "_count = " &
      $structFieldRows.len & ";"
    lines.add ""
  var unionRows: seq[FfiUnionCRow]
  var unionFieldRows: seq[FfiUnionFieldCRow]
  for unionProto in chunk.ffiUnions:
    let cUnionName = cIdent(unionProto.name, "FfiUnion")
    if unionProto.layout == "C":
      lines.add "typedef union " & cUnionName & " {"
      for i, field in unionProto.fields:
        let fieldType = ffiCType(ffiTypeLabel(field.typeExpr))
        lines.add "  " & fieldType & " " &
          cIdent(field.name, "field_" & $i) & ";"
      lines.add "} " & cUnionName & ";"
      if unionProto.hasSize:
        lines.add "_Static_assert(sizeof(" & cUnionName & ") == " &
          $unionProto.size & ", " &
          cStringLiteral("ffi/union " & unionProto.name & " size mismatch") &
          ");"
      if unionProto.hasAlign:
        lines.add "_Static_assert(GENE_ALIGNOF(" & cUnionName & ") == " &
          $unionProto.align & ", " &
          cStringLiteral("ffi/union " & unionProto.name & " align mismatch") &
          ");"
      lines.add ""
    unionRows.add FfiUnionCRow(name: unionProto.name,
                               layout: unionProto.layout,
                               size: if unionProto.hasSize: unionProto.size else: -1,
                               align: if unionProto.hasAlign: unionProto.align else: -1,
                               fieldCount: unionProto.fields.len)
    for field in unionProto.fields:
      unionFieldRows.add FfiUnionFieldCRow(
        unionName: unionProto.name,
        fieldName: field.name,
        typeName: ffiTypeLabel(field.typeExpr))
  if unionRows.len > 0:
    let manifestName = ffiUnionManifestName(prefix)
    lines.add "static const GeneFfiUnionInfo " & manifestName & "[] = {"
    for row in unionRows:
      lines.add "  {" & cStringLiteral(row.name) & ", " &
        cStringLiteral(row.layout) & ", " & $row.size & ", " & $row.align &
        ", " & $row.fieldCount & "},"
    lines.add "};"
    lines.add "static const size_t " & manifestName & "_count = " &
      $unionRows.len & ";"
    let fieldManifestName = ffiUnionFieldManifestName(prefix)
    lines.add "static const GeneFfiUnionFieldInfo " & fieldManifestName &
      "[] = {"
    for row in unionFieldRows:
      lines.add "  {" & cStringLiteral(row.unionName) & ", " &
        cStringLiteral(row.fieldName) & ", " & cStringLiteral(row.typeName) &
        "},"
    lines.add "};"
    lines.add "static const size_t " & fieldManifestName & "_count = " &
      $unionFieldRows.len & ";"
    lines.add ""
  var signatureRows: seq[FfiSignatureCRow]
  for signature in chunk.ffiSignatures:
    var params: seq[string]
    for p in signature.params:
      params.add p.name & ":" & ffiTypeLabel(p.typeExpr)
    signatureRows.add FfiSignatureCRow(
      name: signature.name,
      kind: formatFfiSignatureKind(signature.kind),
      abi: signature.abi,
      params: params.join(","),
      resultType: if signature.returnType.kind == vkNil: "C/Void" else: ffiTypeLabel(signature.returnType),
      escaping: signature.escaping,
      runtimeConstructible: signature.runtimeConstructible)
  if signatureRows.len > 0:
    let manifestName = ffiSignatureManifestName(prefix)
    lines.add "static const GeneFfiSignatureInfo " & manifestName & "[] = {"
    for row in signatureRows:
      lines.add "  {" & cStringLiteral(row.name) & ", " &
        cStringLiteral(row.kind) & ", " & cStringLiteral(row.abi) & ", " &
        cStringLiteral(row.params) & ", " & cStringLiteral(row.resultType) &
        ", " & (if row.escaping: "true" else: "false") & ", " &
        (if row.runtimeConstructible: "true" else: "false") & "},"
    lines.add "};"
    lines.add "static const size_t " & manifestName & "_count = " &
      $signatureRows.len & ";"
    lines.add ""
  var monomorphRows: seq[MonomorphizationCRow]
  for spec in chunk.monomorphizations:
    var args: seq[string]
    for arg in spec.typeArgs:
      args.add ffiTypeLabel(arg)
    lines.add "/* monomorphize " & cIdent(prefix & spec.functionName,
      spec.functionName) & "<" & args.join(",") & "> */"
    monomorphRows.add MonomorphizationCRow(functionName: spec.functionName,
                                           typeArgs: args.join(","))
  if monomorphRows.len > 0:
    let manifestName = monomorphizationManifestName(prefix)
    lines.add "static const GeneMonomorphizationSpec " & manifestName & "[] = {"
    for row in monomorphRows:
      lines.add "  {" & cStringLiteral(row.functionName) & ", " &
        cStringLiteral(row.typeArgs) & "},"
    lines.add "};"
    lines.add "static const size_t " & manifestName & "_count = " &
      $monomorphRows.len & ";"
    lines.add ""
  var directRows: seq[DirectProtocolCRow]
  for spec in chunk.directProtocolCalls:
    let protocolName = ffiTypeLabel(spec.protocolExpr)
    let receiverName = ffiTypeLabel(spec.receiverExpr)
    lines.add "/* direct-protocol " & spec.messageName & " " &
      protocolName & "/" & receiverName & " */"
    directRows.add DirectProtocolCRow(messageName: spec.messageName,
                                      protocolName: protocolName,
                                      receiverName: receiverName)
  if directRows.len > 0:
    let manifestName = directProtocolManifestName(prefix)
    lines.add "static const GeneDirectProtocolCall " & manifestName & "[] = {"
    for row in directRows:
      lines.add "  {" & cStringLiteral(row.messageName) & ", " &
        cStringLiteral(row.protocolName) & ", " &
        cStringLiteral(row.receiverName) & "},"
    lines.add "};"
    lines.add "static const size_t " & manifestName & "_count = " &
      $directRows.len & ";"
    lines.add ""
  var taskFrameRows: seq[TaskFrameCRow]
  for fn in chunk.functions:
    if fn.taskFrameKind != tfkNone:
      taskFrameRows.add TaskFrameCRow(functionName: fn.name,
                                      kind: formatTaskFrameKind(fn.taskFrameKind),
                                      canSuspend: fn.taskFrameKind == tfkVm)
  if taskFrameRows.len > 0:
    let manifestName = taskFrameManifestName(prefix)
    lines.add "static const GeneTaskFrameInfo " & manifestName & "[] = {"
    for row in taskFrameRows:
      lines.add "  {" & cStringLiteral(row.functionName) & ", " &
        cStringLiteral(row.kind) & ", " &
        (if row.canSuspend: "true" else: "false") & "},"
    lines.add "};"
    lines.add "static const size_t " & manifestName & "_count = " &
      $taskFrameRows.len & ";"
    lines.add ""
  var moduleFns: seq[AotModuleFunction]
  for i, fn in chunk.functions:
    let typeName = fn.aotTypeName
    let cType = typeName.aotCType
    if fn.aotExpr.kind != vkNil and cType.len > 0:
      let fnName = cIdent(prefix & fn.name, "fn_" & $i)
      let cName = "gene_native_" & fnName
      let frameName = "gene_frame_" & fnName
      var frameFlags = "GENE_NATIVE_FRAME_TYPED"
      if fn.aotFrameCanSuspend:
        frameFlags.add " | GENE_NATIVE_FRAME_CAN_SUSPEND"
      var params: seq[string]
      for j, param in fn.params:
        params.add cType & " " & cIdent(param, "arg" & $j)
      let paramList = if params.len == 0: "void" else: params.join(", ")
      lines.add "static const GeneNativeFrameInfo " & frameName & " = {" &
        cStringLiteral(fn.name) & ", " & frameFlags & "};"
      lines.add cType & " " & cName & "(" & paramList & ") {"
      lines.add "  (void)&" & frameName & ";"
      lines.add "  return " & emitAotCExpr(fn.aotExpr, fn.params, available) & ";"
      lines.add "}"
      lines.add ""
      available[fn.name] = AotCFunction(cName: cName, paramCount: fn.params.len,
                                        cType: cType)
      moduleFns.add AotModuleFunction(geneName: fn.name, cName: cName,
                                      typeName: typeName,
                                      paramCount: fn.params.len,
                                      frameName: frameName)
    addCBackend(lines, fn.chunk, prefix & fn.name & "_", available)
  if moduleFns.len > 0:
    let manifestName = aotModuleManifestName(prefix)
    lines.add "static const GeneAotModuleFunction " & manifestName & "[] = {"
    for fn in moduleFns:
      lines.add "  {" & cStringLiteral(fn.geneName) & ", " &
        cStringLiteral(fn.cName) & ", " & cStringLiteral(fn.typeName) & ", " &
        $fn.paramCount & ", &" & fn.frameName & "},"
    lines.add "};"
    lines.add "static const size_t " & manifestName & "_count = " &
      $moduleFns.len & ";"
    lines.add ""
  for i, sub in chunk.subchunks:
    addCBackend(lines, sub, prefix & "ns" & $i & "_", available)

proc addCBackend(lines: var seq[string], chunk: Chunk, prefix = "") =
  var available = initTable[string, AotCFunction]()
  addCBackend(lines, chunk, prefix, available)

proc emitExperimentalC*(chunk: Chunk): string =
  var lines = @[
    "/* Gene experimental typed-native C backend.",
    " * Emits fixed-representation functions and generated FFI adapter wrappers.",
    " */",
    "#include <stdbool.h>",
    "#include <stddef.h>",
    "#include <stdint.h>",
    "typedef struct GeneContext GeneContext;",
    "typedef struct GeneCall GeneCall;",
    "typedef struct GeneValue GeneValue;",
    "typedef int GeneStatus;",
    "typedef struct GeneNativeFrameInfo {",
    "  const char *name;",
    "  unsigned flags;",
    "} GeneNativeFrameInfo;",
    "typedef struct GeneAotModuleFunction {",
    "  const char *gene_name;",
    "  const char *c_symbol;",
    "  const char *repr;",
    "  int arity;",
    "  const GeneNativeFrameInfo *frame;",
    "} GeneAotModuleFunction;",
    "typedef struct GeneMonomorphizationSpec {",
    "  const char *function_name;",
    "  const char *type_args;",
    "} GeneMonomorphizationSpec;",
    "typedef struct GeneDirectProtocolCall {",
    "  const char *message_name;",
    "  const char *protocol;",
    "  const char *receiver;",
    "} GeneDirectProtocolCall;",
    "typedef struct GeneTaskFrameInfo {",
    "  const char *function_name;",
    "  const char *kind;",
    "  bool can_suspend;",
    "} GeneTaskFrameInfo;",
    "typedef struct GeneFfiStructInfo {",
    "  const char *name;",
    "  const char *layout;",
    "  int size;",
    "  int align;",
    "  size_t field_count;",
    "} GeneFfiStructInfo;",
    "typedef struct GeneFfiStructFieldInfo {",
    "  const char *struct_name;",
    "  const char *field_name;",
    "  const char *type_name;",
    "  int offset;",
    "} GeneFfiStructFieldInfo;",
    "typedef struct GeneFfiUnionInfo {",
    "  const char *name;",
    "  const char *layout;",
    "  int size;",
    "  int align;",
    "  size_t field_count;",
    "} GeneFfiUnionInfo;",
    "typedef struct GeneFfiUnionFieldInfo {",
    "  const char *union_name;",
    "  const char *field_name;",
    "  const char *type_name;",
    "} GeneFfiUnionFieldInfo;",
    "typedef struct GeneFfiSignatureInfo {",
    "  const char *name;",
    "  const char *kind;",
    "  const char *abi;",
    "  const char *params;",
    "  const char *result_type;",
    "  bool escaping;",
    "  bool runtime_constructible;",
    "} GeneFfiSignatureInfo;",
    "typedef struct GeneFfiAbiTypeInfo {",
    "  const char *gene_type;",
    "  const char *c_type;",
    "  size_t size;",
    "  size_t align;",
    "} GeneFfiAbiTypeInfo;",
    "typedef struct GeneFfiBufferView {",
    "  const void *data;",
    "  size_t len;",
    "} GeneFfiBufferView;",
    "#define GENE_NATIVE_FRAME_TYPED (1u << 0)",
    "#define GENE_NATIVE_FRAME_CAN_SUSPEND (1u << 1)",
    "#define GENE_ALIGNOF(T) offsetof(struct { char c; T x; }, x)",
    "#ifndef GENE_OK",
    "#define GENE_OK 0",
    "#endif",
    "#ifndef GENE_ERROR",
    "#define GENE_ERROR 1",
    "#endif",
    "#ifndef GENE_PANIC",
    "#define GENE_PANIC 2",
    "#endif",
    "#ifndef GENE_FFI_WRAPPER_UNIMPLEMENTED",
    "#define GENE_FFI_WRAPPER_UNIMPLEMENTED (-1)",
    "#endif",
    "extern GeneStatus gene_ffi_check_arity(GeneContext *ctx, const GeneCall *call, size_t expected);",
    "extern GeneStatus gene_ffi_arg_int8(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, int8_t *out);",
    "extern GeneStatus gene_ffi_arg_uint8(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, uint8_t *out);",
    "extern GeneStatus gene_ffi_arg_int16(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, int16_t *out);",
    "extern GeneStatus gene_ffi_arg_uint16(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, uint16_t *out);",
    "extern GeneStatus gene_ffi_arg_int32(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, int32_t *out);",
    "extern GeneStatus gene_ffi_arg_uint32(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, uint32_t *out);",
    "extern GeneStatus gene_ffi_arg_int64(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, int64_t *out);",
    "extern GeneStatus gene_ffi_arg_uint64(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, uint64_t *out);",
    "extern GeneStatus gene_ffi_arg_char(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, char *out);",
    "extern GeneStatus gene_ffi_arg_uchar(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, unsigned char *out);",
    "extern GeneStatus gene_ffi_arg_short(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, short *out);",
    "extern GeneStatus gene_ffi_arg_ushort(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, unsigned short *out);",
    "extern GeneStatus gene_ffi_arg_int(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, int *out);",
    "extern GeneStatus gene_ffi_arg_uint(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, unsigned int *out);",
    "extern GeneStatus gene_ffi_arg_long(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, long *out);",
    "extern GeneStatus gene_ffi_arg_ulong(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, unsigned long *out);",
    "extern GeneStatus gene_ffi_arg_size(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, size_t *out);",
    "extern GeneStatus gene_ffi_arg_ptrdiff(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, ptrdiff_t *out);",
    "extern GeneStatus gene_ffi_arg_float(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, float *out);",
    "extern GeneStatus gene_ffi_arg_double(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, double *out);",
    "extern GeneStatus gene_ffi_arg_bool(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, bool *out);",
    "extern GeneStatus gene_ffi_arg_cstr(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, const char **out);",
    "extern GeneStatus gene_ffi_arg_ptr(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, const char *type_name, void **out);",
    "extern GeneStatus gene_ffi_arg_const_ptr(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, const char *type_name, const void **out);",
    "extern GeneStatus gene_ffi_arg_buffer(GeneContext *ctx, const GeneCall *call, size_t index, const char *name, const char *type_name, GeneFfiBufferView *out);",
    "extern GeneStatus gene_ffi_result_void(GeneContext *ctx, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_int8(GeneContext *ctx, int8_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_uint8(GeneContext *ctx, uint8_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_int16(GeneContext *ctx, int16_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_uint16(GeneContext *ctx, uint16_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_int32(GeneContext *ctx, int32_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_uint32(GeneContext *ctx, uint32_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_int64(GeneContext *ctx, int64_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_uint64(GeneContext *ctx, uint64_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_char(GeneContext *ctx, char value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_uchar(GeneContext *ctx, unsigned char value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_short(GeneContext *ctx, short value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_ushort(GeneContext *ctx, unsigned short value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_int(GeneContext *ctx, int value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_uint(GeneContext *ctx, unsigned int value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_long(GeneContext *ctx, long value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_ulong(GeneContext *ctx, unsigned long value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_size(GeneContext *ctx, size_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_ptrdiff(GeneContext *ctx, ptrdiff_t value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_float(GeneContext *ctx, float value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_double(GeneContext *ctx, double value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_bool(GeneContext *ctx, bool value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_cstr(GeneContext *ctx, const char *value, GeneValue *result);",
    "extern GeneStatus gene_ffi_result_ptr(GeneContext *ctx, void *value, const char *type_name, const char *release_name, GeneValue *result);",
    "_Static_assert(sizeof(int8_t) == 1, \"C/Int8 must be 1 byte\");",
    "_Static_assert(sizeof(uint8_t) == 1, \"C/UInt8 must be 1 byte\");",
    "_Static_assert(sizeof(int16_t) == 2, \"C/Int16 must be 2 bytes\");",
    "_Static_assert(sizeof(uint16_t) == 2, \"C/UInt16 must be 2 bytes\");",
    "_Static_assert(sizeof(int32_t) == 4, \"C/Int32 must be 4 bytes\");",
    "_Static_assert(sizeof(uint32_t) == 4, \"C/UInt32 must be 4 bytes\");",
    "_Static_assert(sizeof(int64_t) == 8, \"C/Int64 must be 8 bytes\");",
    "_Static_assert(sizeof(uint64_t) == 8, \"C/UInt64 must be 8 bytes\");",
    "static const GeneFfiAbiTypeInfo gene_ffi_abi_types[] = {",
    "  {\"C/Int8\", \"int8_t\", sizeof(int8_t), GENE_ALIGNOF(int8_t)},",
    "  {\"C/UInt8\", \"uint8_t\", sizeof(uint8_t), GENE_ALIGNOF(uint8_t)},",
    "  {\"C/Int16\", \"int16_t\", sizeof(int16_t), GENE_ALIGNOF(int16_t)},",
    "  {\"C/UInt16\", \"uint16_t\", sizeof(uint16_t), GENE_ALIGNOF(uint16_t)},",
    "  {\"C/Int32\", \"int32_t\", sizeof(int32_t), GENE_ALIGNOF(int32_t)},",
    "  {\"C/UInt32\", \"uint32_t\", sizeof(uint32_t), GENE_ALIGNOF(uint32_t)},",
    "  {\"C/Int64\", \"int64_t\", sizeof(int64_t), GENE_ALIGNOF(int64_t)},",
    "  {\"C/UInt64\", \"uint64_t\", sizeof(uint64_t), GENE_ALIGNOF(uint64_t)},",
    "  {\"C/Char\", \"char\", sizeof(char), GENE_ALIGNOF(char)},",
    "  {\"C/UChar\", \"unsigned char\", sizeof(unsigned char), GENE_ALIGNOF(unsigned char)},",
    "  {\"C/Short\", \"short\", sizeof(short), GENE_ALIGNOF(short)},",
    "  {\"C/UShort\", \"unsigned short\", sizeof(unsigned short), GENE_ALIGNOF(unsigned short)},",
    "  {\"C/Int\", \"int\", sizeof(int), GENE_ALIGNOF(int)},",
    "  {\"C/UInt\", \"unsigned int\", sizeof(unsigned int), GENE_ALIGNOF(unsigned int)},",
    "  {\"C/Long\", \"long\", sizeof(long), GENE_ALIGNOF(long)},",
    "  {\"C/ULong\", \"unsigned long\", sizeof(unsigned long), GENE_ALIGNOF(unsigned long)},",
    "  {\"C/Size\", \"size_t\", sizeof(size_t), GENE_ALIGNOF(size_t)},",
    "  {\"C/PtrDiff\", \"ptrdiff_t\", sizeof(ptrdiff_t), GENE_ALIGNOF(ptrdiff_t)},",
    "  {\"C/Float\", \"float\", sizeof(float), GENE_ALIGNOF(float)},",
    "  {\"C/Double\", \"double\", sizeof(double), GENE_ALIGNOF(double)},",
    "  {\"C/Bool\", \"bool\", sizeof(bool), GENE_ALIGNOF(bool)},",
    "  {\"C/CStr\", \"const char *\", sizeof(const char *), GENE_ALIGNOF(const char *)},",
    "};",
    "static const size_t gene_ffi_abi_types_count = 22;",
    ""
  ]
  let headerLen = lines.len
  addCBackend(lines, chunk)
  if lines.len == headerLen:
    lines.add "/* no fixed-representation native functions or FFI wrappers */"
  lines.join("\n")
