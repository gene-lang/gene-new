## AST-to-GIR compiler for the MVP execution surface.

import std/[sets, strutils, tables]
import ./[equality, gir, reader, types]

type
  KnownFunctionSig = object
    arity: int
    returnType: Value

  LoopCompileContext = object
    isInline: bool
    continueTarget: int
    breakJumps: seq[int]
    continueJumps: seq[int]

  Compiler = object
    chunk: Chunk
    sourceName: string
    sourceLocs: Table[uint64, SourceLoc]
    formLocs: seq[SourceLoc]
    currentLoc: SourceLoc
    selfAvailable: bool
    seenModDecl: bool
    allowYield: bool
    sawYield: bool
    loopDepth: int
    loopStack: seq[LoopCompileContext]
    gensym: int
    useLocalSlots: bool
    localSlots: Table[string, int]
    fastLocalLoads: Table[string, int]
    localTypes: Table[string, Value]
    localFunctionSigs: Table[string, KnownFunctionSig]
    localNames: seq[string]
    parentSlots: seq[Table[string, int]]
    parentFunctionSigs: seq[Table[string, KnownFunctionSig]]
    ffiLibraryNames: Table[string, bool]
    macros: Table[string, MacroDef]
    hasMacros: bool
    macroExpansionDepth: int
    allowAmbientImports: bool
    # Cross-module macros (design §11/§15): the module loader pre-loads each
    # top-level `from "path"` dependency and hands us its macro exports keyed
    # by the raw path string as written in the source. Selections that name a
    # macro are spliced into `macros` at compile time and recorded here so
    # they are not re-exported and not looked up as runtime bindings.
    importedMacroSets: Table[string, Table[string, MacroDef]]
    importedMacroNames: HashSet[string]

  ParamSpecs = object
    positional: seq[string]
    positionalTypes: seq[Value]
    positionalDefaults: seq[ParamDefault]
    rest: string
    named: seq[NamedParam]

  ParamAdornment = object
    typeExpr: Value
    defaultValue: ParamDefault

  MacroDefault = object
    optional: bool
    hasExpr: bool
    defaultExpr: Value

  MacroParam = object
    pattern: Value
    defaultValue: MacroDefault

  MacroNamedParam = object
    arg: string
    pattern: Value
    defaultValue: MacroDefault

  ## Exported so the module loader can carry a module's macro definitions to
  ## the compilers of importing modules (design §11 + §15: macros are module
  ## exports). The fields stay private — embedders only shuttle the values.
  MacroDef* = object
    params: seq[MacroParam]
    named: seq[MacroNamedParam]
    rest: string
    body: seq[Value]

const MaxMacroExpansionDepth = 100

proc emit(c: var Compiler, op: OpCode, intArg = 0, name = "",
          depth = 0,
          names: seq[string] = @[], flag = false): int =
  c.chunk.emit(Instruction(op: op, intArg: intArg, depth: depth,
                           name: name, names: names, flag: flag),
               c.currentLoc)

proc callOpForArity(argCount: int): OpCode =
  case argCount
  of 0: opCall0
  of 1: opCall1
  of 2: opCall2
  else: opCall

proc emitPlainCall(c: var Compiler, argCount: int): int =
  let op = callOpForArity(argCount)
  c.emit(op, argCount)

proc hasStableSourceIdentity(v: Value): bool =
  v.kind in {vkList, vkMap, vkNode}

proc sourceLocFor(c: Compiler, v: Value): SourceLoc =
  if v.hasStableSourceIdentity and c.sourceLocs.hasKey(v.bits):
    return c.sourceLocs[v.bits]
  c.currentLoc

proc enableLocalSlots(c: var Compiler) =
  c.useLocalSlots = true
  c.localSlots = initTable[string, int]()
  c.fastLocalLoads = initTable[string, int]()
  c.localTypes = initTable[string, Value]()
  c.localFunctionSigs = initTable[string, KnownFunctionSig]()
  c.localNames = @[]

proc reserveLocal(c: var Compiler, name: string): int =
  # One name, one meaning: a binding may not reuse a visible macro's name —
  # head-position dispatch would still pick the macro, so the binding could
  # never mean the same thing in both positions (design §11).
  if c.hasMacros and c.macros.hasKey(name):
    raise newException(GeneError,
      "binding '" & name & "' conflicts with a macro of the same name")
  if not c.useLocalSlots:
    return -1
  if c.localSlots.hasKey(name):
    return c.localSlots[name]
  result = c.localNames.len
  c.localSlots[name] = result
  c.localNames.add name

proc localSlot(c: Compiler, name: string): int =
  if c.useLocalSlots and c.localSlots.hasKey(name):
    return c.localSlots[name]
  -1

proc isBareIntType(expr: Value): bool =
  expr.kind == vkSymbol and expr.symVal == "Int"

proc recordLocalType(c: var Compiler, name: string, typeExpr: Value) =
  if c.useLocalSlots and c.localSlots.hasKey(name) and typeExpr.kind != vkNil:
    c.localTypes[name] = typeExpr

proc localType(c: Compiler, name: string): Value =
  if c.useLocalSlots and c.localTypes.hasKey(name):
    return c.localTypes[name]
  NIL

proc parentSlot(c: Compiler, name: string): tuple[depth: int, slot: int] =
  for i, slots in c.parentSlots:
    if slots.hasKey(name):
      return (i + 1, slots[name])
  (-1, -1)

proc parentFrames(c: Compiler): seq[Table[string, int]] =
  if c.useLocalSlots:
    result.add c.localSlots
  result.add c.parentSlots

proc parentFunctionSigFrames(c: Compiler): seq[Table[string, KnownFunctionSig]] =
  if c.useLocalSlots:
    result.add c.localFunctionSigs
  result.add c.parentFunctionSigs

proc lexicalFunctionSig(c: Compiler, name: string):
    tuple[found: bool, sig: KnownFunctionSig] =
  let slot = c.localSlot(name)
  if slot >= 0:
    if c.localFunctionSigs.hasKey(name):
      return (true, c.localFunctionSigs[name])
    return
  let outer = c.parentSlot(name)
  if outer.slot >= 0:
    let index = outer.depth - 1
    if index >= 0 and index < c.parentFunctionSigs.len and
        c.parentFunctionSigs[index].hasKey(name):
      return (true, c.parentFunctionSigs[index][name])

proc functionSigFromParts(positionalCount: int, typeParams: openArray[string],
                          returnType: Value):
    tuple[known: bool, sig: KnownFunctionSig] =
  if typeParams.len == 0 and returnType.kind != vkNil:
    return (true, KnownFunctionSig(arity: positionalCount,
                                   returnType: returnType))

proc recordLocalFunctionSig(c: var Compiler, name: string, proto: FunctionProto) =
  if c.useLocalSlots and c.localSlots.hasKey(name) and
      proto.typeParams.len == 0 and proto.hasReturnType:
    c.localFunctionSigs[name] = KnownFunctionSig(arity: proto.params.len,
                                                 returnType: proto.returnType)

proc nativeFastLoadKind(name: string): NativeFastKind =
  case name
  of "+": nfkAdd
  of "-": nfkSub
  of "*": nfkMul
  # Division keeps the regular native-call path for now. Its zero checks and
  # integer/float result rules need a separate measured fast path, not just
  # inclusion in the generic binary opNativeFast2 lowering.
  of "<": nfkLt
  of ">": nfkGt
  of "<=": nfkLe
  of ">=": nfkGe
  else: nfkNone

proc isSelfEvaluatingFastConst(v: Value): bool =
  case v.kind
  of vkNil, vkBool, vkInt, vkFloat, vkString, vkChar:
    true
  else:
    false

proc exprKnownBareInt(c: Compiler, v: Value): bool

proc formsKnownBareInt(c: Compiler, forms: openArray[Value], start = 0): bool =
  forms.len > start and c.exprKnownBareInt(forms[forms.high])

proc exprKnownBareInt(c: Compiler, v: Value): bool =
  case v.kind
  of vkInt:
    true
  of vkSymbol:
    c.localType(v.symVal).isBareIntType
  of vkNode:
    if v.props.len == 0 and v.head.kind == vkSymbol:
      case v.head.symVal
      of "+", "-", "*":
        v.body.len == 2 and c.localSlot(v.head.symVal) < 0 and
          c.parentSlot(v.head.symVal).slot < 0 and
          c.exprKnownBareInt(v.body[0]) and c.exprKnownBareInt(v.body[1])
      of "if":
        if v.body.len >= 2 and v.body[1].kind == vkNode and
            v.body[1].head.kind == vkSymbol and v.body[1].head.symVal == "then":
          var known = c.formsKnownBareInt(v.body[1].body)
          var hasDefault = false
          for i in 2 ..< v.body.len:
            let clause = v.body[i]
            if clause.kind != vkNode or clause.head.kind != vkSymbol:
              continue
            case clause.head.symVal
            of "elif":
              known = known and clause.body.len > 1 and
                c.formsKnownBareInt(clause.body, 1)
            of "else":
              known = known and c.formsKnownBareInt(clause.body)
              hasDefault = true
              break
            else:
              discard
          known and hasDefault
        else:
          v.body.len >= 3 and c.exprKnownBareInt(v.body[1]) and
            c.exprKnownBareInt(v.body[2])
      else:
        let sig = c.lexicalFunctionSig(v.head.symVal)
        sig.found and sig.sig.arity == v.body.len and
          sig.sig.returnType.isBareIntType
    else:
      false
  else:
    false

proc hasLexicalBinding(c: Compiler, name: string): bool =
  if c.localSlot(name) >= 0:
    return true
  c.parentSlot(name).slot >= 0

proc lexicalCallSlot(c: Compiler, name: string): tuple[op: OpCode, depth: int, slot: int] =
  let slot = c.localSlot(name)
  if slot >= 0:
    return (opCallLocal1, 0, slot)
  let outer = c.parentSlot(name)
  if outer.slot >= 0:
    if outer.depth == 1:
      return (opCallParentLocal1, outer.depth, outer.slot)
    return (opCallOuterLocal1, outer.depth, outer.slot)
  (opCall, -1, -1)

proc lexicalCallSlot0(c: Compiler, name: string): tuple[op: OpCode, depth: int, slot: int] =
  let slot = c.localSlot(name)
  if slot >= 0:
    return (opCallLocal0, 0, slot)
  let outer = c.parentSlot(name)
  if outer.slot >= 0:
    if outer.depth == 1:
      return (opCallParentLocal0, outer.depth, outer.slot)
    return (opCallOuterLocal0, outer.depth, outer.slot)
  (opCall, -1, -1)

proc emitLoadBinding(c: var Compiler, name: string) =
  # One name, one meaning: a macro name may not be used in value position
  # (design §11). Macros are compile-time rewriters, not runtime values.
  if c.hasMacros and c.macros.hasKey(name):
    raise newException(GeneError,
      "macro '" & name & "' cannot be used as a value; call it in head position")
  let slot = c.localSlot(name)
  if slot >= 0:
    if c.fastLocalLoads.hasKey(name) and c.fastLocalLoads[name] == slot:
      discard c.emit(opLoadLocalFast, slot, name = name)
    else:
      discard c.emit(opLoadLocal, slot, name = name)
  else:
    let outer = c.parentSlot(name)
    if outer.slot >= 0:
      discard c.emit(opLoadOuterLocal, outer.slot, depth = outer.depth, name = name)
    else:
      let fastKind = nativeFastLoadKind(name)
      if fastKind != nfkNone:
        discard c.emit(opLoadNativeFast, ord(fastKind), name = name)
      else:
        discard c.emit(opLoadName, name = name)

proc intFast2Op(kind: NativeFastKind): OpCode =
  case kind
  of nfkAdd: opIntAdd2
  of nfkSub: opIntSub2
  of nfkMul: opIntMul2
  of nfkLt: opIntLt2
  of nfkGt: opIntGt2
  of nfkLe: opIntLe2
  of nfkGe: opIntGe2
  else: opIntFast2

proc intFastConstOp(kind: NativeFastKind): OpCode =
  case kind
  of nfkAdd: opIntAddConst
  of nfkSub: opIntSubConst
  of nfkMul: opIntMulConst
  of nfkLt: opIntLtConst
  of nfkGt: opIntGtConst
  of nfkLe: opIntLeConst
  of nfkGe: opIntGeConst
  else: opIntFastConst

proc emitDefineBinding(c: var Compiler, name: string) =
  if c.useLocalSlots:
    discard c.emit(opDefineLocal, c.reserveLocal(name), name = name)
  else:
    discard c.emit(opDefineName, name = name)

proc emitSetBinding(c: var Compiler, name: string) =
  let slot = c.localSlot(name)
  if slot >= 0:
    discard c.emit(opSetLocal, slot, name = name)
  else:
    let outer = c.parentSlot(name)
    if outer.slot >= 0:
      discard c.emit(opSetOuterLocal, outer.slot, depth = outer.depth, name = name)
    else:
      discard c.emit(opSetName, name = name)

proc emitDeclareType(c: var Compiler, name: string, typeExpr: Value) =
  discard c.emit(opDeclareType, c.chunk.addConst(typeExpr), name = name)

proc emitConst(c: var Compiler, value: Value) =
  discard c.emit(opPushConst, c.chunk.addConst(value))

proc compileFn(c: var Compiler, node: Value, inferredName = "")

proc emitJump(c: var Compiler, op: OpCode): int =
  c.emit(op, -1)

proc patchJump(c: var Compiler, at: int) =
  c.chunk.patchJump(at, c.chunk.instructions.len)

proc compileBreak(c: var Compiler, node: Value) =
  if node.body.len != 0 or node.props.len != 0:
    raise newException(GeneError, "break expects no arguments")
  if c.loopDepth <= 0:
    raise newException(GeneError, "break is only valid inside a loop")
  if c.loopStack.len > 0 and c.loopStack[^1].isInline:
    c.loopStack[^1].breakJumps.add c.emitJump(opJump)
  else:
    discard c.emit(opLoopBreak)

proc compileContinue(c: var Compiler, node: Value) =
  if node.body.len != 0 or node.props.len != 0:
    raise newException(GeneError, "continue expects no arguments")
  if c.loopDepth <= 0:
    raise newException(GeneError, "continue is only valid inside a loop")
  if c.loopStack.len > 0 and c.loopStack[^1].isInline:
    if c.loopStack[^1].continueTarget >= 0:
      discard c.emit(opJump, c.loopStack[^1].continueTarget)
    else:
      c.loopStack[^1].continueJumps.add c.emitJump(opJump)
  else:
    discard c.emit(opLoopContinue)

proc isSymbol(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc isPath(v: Value, segments: openArray[string]): bool =
  if v.kind != vkNode or not v.head.isSymbol("path") or v.body.len != segments.len:
    return false
  for i, segment in segments:
    if v.body[i].kind != vkSymbol or v.body[i].symVal != segment:
      return false
  true

proc compileExpr(c: var Compiler, node: Value, allowModDecl = false)

proc childCompiler(c: Compiler): Compiler =
  Compiler(chunk: newChunk(c.sourceName), sourceName: c.sourceName,
           sourceLocs: c.sourceLocs, currentLoc: c.currentLoc,
           selfAvailable: c.selfAvailable,
           ffiLibraryNames: c.ffiLibraryNames,
           macros: c.macros, hasMacros: c.hasMacros,
           macroExpansionDepth: c.macroExpansionDepth,
           allowAmbientImports: c.allowAmbientImports,
           importedMacroSets: c.importedMacroSets,
           importedMacroNames: c.importedMacroNames)

proc nextTemp(c: var Compiler, prefix: string): string =
  inc c.gensym
  "__gene_" & prefix & "_" & $c.gensym

proc containsYield(value: Value): bool =
  case value.kind
  of vkNode:
    if value.head.isSymbol("yield"):
      return true
    if value.head.isSymbol("fn") or value.head.isSymbol("quote") or
        value.head.isSymbol("quasiquote"):
      return false
    for _, item in value.props:
      if containsYield(item):
        return true
    for item in value.body:
      if containsYield(item):
        return true
    false
  of vkList:
    for item in value.listItems:
      if containsYield(item):
        return true
    false
  of vkMap:
    for _, item in value.mapEntries:
      if containsYield(item):
        return true
    false
  else:
    false

proc containsAwait(value: Value): bool =
  case value.kind
  of vkNode:
    if value.head.isSymbol("await"):
      return true
    if value.head.isSymbol("fn") or value.head.isSymbol("quote") or
        value.head.isSymbol("quasiquote"):
      return false
    for _, item in value.props:
      if containsAwait(item):
        return true
    for item in value.body:
      if containsAwait(item):
        return true
    false
  of vkList:
    for item in value.listItems:
      if containsAwait(item):
        return true
    false
  of vkMap:
    for _, item in value.mapEntries:
      if containsAwait(item):
        return true
    false
  else:
    false

proc bodyContainsYield(body: openArray[Value], first: int): bool =
  if first > body.high:
    return false
  for i in first .. body.high:
    if containsYield(body[i]):
      return true
  false

proc bodyContainsAwait(body: openArray[Value], first: int): bool =
  if first > body.high:
    return false
  for i in first .. body.high:
    if containsAwait(body[i]):
      return true
  false

proc isTypedPattern(pat: Value): bool =
  pat.kind == vkNode and pat.head.kind == vkSymbol and pat.body.len > 0 and
    pat.body[0].isSymbol(":")

proc requireTypedPatternShape(pat: Value) =
  if pat.body.len != 2:
    raise newException(GeneError, "typed pattern requires a name and one type")

proc patternBindsSelf(pattern: Value): bool =
  case pattern.kind
  of vkSymbol:
    return pattern.symVal == "self"
  of vkList:
    for item in pattern.listItems:
      if patternBindsSelf(item):
        return true
  of vkMap:
    for _, value in pattern.mapEntries:
      if patternBindsSelf(value):
        return true
  of vkNode:
    if pattern.isTypedPattern:
      pattern.requireTypedPatternShape()
      return pattern.head.symVal == "self"
    for _, value in pattern.props:
      if patternBindsSelf(value):
        return true
    for item in pattern.body:
      if patternBindsSelf(item):
        return true
  else:
    return false

proc isRestPattern(pat: Value): bool =
  pat.kind == vkSymbol and pat.symVal.len > 3 and pat.symVal.endsWith("...")

proc addPatternBinding(names: var seq[string], seen: var Table[string, bool],
                       name: string) =
  if name.len == 0 or name == "_" or seen.hasKey(name):
    return
  seen[name] = true
  names.add name

proc collectPatternBindingNames(pat: Value, names: var seq[string],
                                seen: var Table[string, bool])

proc sameNameSet(a, b: openArray[string]): bool =
  if a.len != b.len:
    return false
  var seen = initTable[string, bool]()
  for name in a:
    seen[name] = true
  for name in b:
    if not seen.hasKey(name):
      return false
  true

proc patternBindingNames(pat: Value): seq[string] =
  var seen = initTable[string, bool]()
  collectPatternBindingNames(pat, result, seen)

proc collectPatternBindingNames(pat: Value, names: var seq[string],
                                seen: var Table[string, bool]) =
  case pat.kind
  of vkSymbol:
    if pat.isRestPattern:
      addPatternBinding(names, seen, pat.symVal[0 .. ^4])
    else:
      addPatternBinding(names, seen, pat.symVal)
  of vkList:
    for item in pat.listItems:
      collectPatternBindingNames(item, names, seen)
  of vkMap:
    for _, valuePat in pat.mapEntries:
      collectPatternBindingNames(valuePat, names, seen)
  of vkNode:
    if pat.isTypedPattern:
      pat.requireTypedPatternShape()
      addPatternBinding(names, seen, pat.head.symVal)
      return
    if pat.head.kind == vkSymbol:
      case pat.head.symVal
      of "unquote":
        return
      of "|":
        if pat.body.len == 0:
          return
        let baseline = patternBindingNames(pat.body[0])
        for i in 1 ..< pat.body.len:
          if not sameNameSet(baseline, patternBindingNames(pat.body[i])):
            raise newException(GeneError,
              "alternation pattern alternatives must bind the same names")
        for name in baseline:
          addPatternBinding(names, seen, name)
        return
      of "&":
        for sub in pat.body:
          collectPatternBindingNames(sub, names, seen)
        return
      of "not":
        if pat.body.len == 1 and patternBindingNames(pat.body[0]).len > 0:
          raise newException(GeneError,
            "pattern (not p) must not introduce bindings")
        return
      else:
        discard
    for _, valuePat in pat.props:
      collectPatternBindingNames(valuePat, names, seen)
    for item in pat.body:
      collectPatternBindingNames(item, names, seen)
  else:
    discard

proc compileBody(c: var Compiler, body: openArray[Value]) =
  if body.len == 0:
    c.emitConst NIL
    return
  for i in 0 ..< body.len:
    compileExpr(c, body[i])
    if i < body.high:
      discard c.emit(opPop)

proc compileBodyFrom(c: var Compiler, body: openArray[Value], first: int) =
  if first > body.high:
    c.emitConst NIL
    return
  for i in first .. body.high:
    compileExpr(c, body[i])
    if i < body.high:
      discard c.emit(opPop)

proc symbolText(v: Value): string =
  if v.kind == vkSymbol: v.symVal else: ""

proc compileDefaultExpr(c: Compiler, node: Value): Chunk =
  var child = c.childCompiler()
  compileExpr(child, node)
  discard child.emit(opReturn)
  child.chunk

proc chunkNeedsCallScope(chunk: Chunk): bool =
  if chunk.localNames.len > 0 or chunk.subchunks.len > 0 or
      chunk.forLoops.len > 0 or chunk.matches.len > 0 or
      chunk.tries.len > 0:
    return true
  for inst in chunk.instructions:
    case inst.op
    of opLoadOuterLocal, opCallParentLocal0, opCallOuterLocal0,
       opCallParentLocal1, opCallOuterLocal1, opSetOuterLocal, opDefineName,
       opDefineLocal, opSetModuleName, opMakeFn,
       opMakeNamespace, opMakeType, opMakeProtocol, opMakeImpl, opImport,
       opMatch, opMatchBind, opMatchBindReplace, opForEach, opTry,
       opTaskScope, opSupervisor, opSpawn, opAwait, opYield:
      return true
    else:
      discard
  false

proc chunkCanPoolCallScope(chunk: Chunk): bool =
  if chunk.subchunks.len > 0 or chunk.forLoops.len > 0 or
      chunk.matches.len > 0 or chunk.tries.len > 0:
    return false
  for inst in chunk.instructions:
    case inst.op
    of opMakeFn, opMakeEnv, opMakeNamespace, opMakeType, opMakeProtocol,
       opMakeImpl, opImport, opMatch, opMatchBind, opMatchBindReplace,
       opForEach, opTry, opTaskScope, opSupervisor, opSpawn, opAwait, opYield:
      return false
    else:
      discard
  true

proc chunkNeedsCallScopeSlotNames(chunk: Chunk): bool =
  for inst in chunk.instructions:
    case inst.op
    of opDeclareType:
      return true
    else:
      discard
  false

proc chunkMaySetSlot(chunk: Chunk, slot: int): bool =
  if chunk.subchunks.len > 0 or chunk.forLoops.len > 0 or
      chunk.matches.len > 0 or chunk.tries.len > 0:
    return true
  for inst in chunk.instructions:
    if inst.op == opSetLocal and inst.intArg == slot:
      return true
  false

proc chunkMutatesOuterScope(chunk: Chunk, localDepth = 0): bool =
  if chunk == nil:
    return false
  for inst in chunk.instructions:
    case inst.op
    of opSetOuterLocal:
      if inst.depth > localDepth:
        return true
    of opSetName:
      return true
    else:
      discard
  for body in chunk.subchunks:
    if chunkMutatesOuterScope(body, localDepth + 1):
      return true
  for loop in chunk.forLoops:
    if chunkMutatesOuterScope(loop.body, localDepth + 1):
      return true
  for match in chunk.matches:
    for clause in match.clauses:
      if chunkMutatesOuterScope(clause.body, localDepth + 1):
        return true
    if chunkMutatesOuterScope(match.elseBody, localDepth + 1):
      return true
  for attempt in chunk.tries:
    if chunkMutatesOuterScope(attempt.body, localDepth):
      return true
    for clause in attempt.catches:
      if chunkMutatesOuterScope(clause.body, localDepth + 1):
        return true
    if chunkMutatesOuterScope(attempt.ensureBody, localDepth):
      return true
  false

proc chunkContainsSpawn(chunk: Chunk): bool =
  if chunk == nil:
    return false
  for inst in chunk.instructions:
    if inst.op == opSpawn:
      return true
  for body in chunk.subchunks:
    if chunkContainsSpawn(body):
      return true
  for loop in chunk.forLoops:
    if chunkContainsSpawn(loop.body):
      return true
  for match in chunk.matches:
    for clause in match.clauses:
      if chunkContainsSpawn(clause.body):
        return true
    if chunkContainsSpawn(match.elseBody):
      return true
  for attempt in chunk.tries:
    if chunkContainsSpawn(attempt.body):
      return true
    for clause in attempt.catches:
      if chunkContainsSpawn(clause.body):
        return true
    if chunkContainsSpawn(attempt.ensureBody):
      return true
  for proto in chunk.functions:
    if chunkContainsSpawn(proto.chunk):
      return true
    for defaultValue in proto.paramDefaults:
      if defaultValue.optional and defaultValue.defaultChunk != nil and
          chunkContainsSpawn(defaultValue.defaultChunk):
        return true
    for param in proto.namedParams:
      if param.defaultValue.optional and
          param.defaultValue.defaultChunk != nil and
          chunkContainsSpawn(param.defaultValue.defaultChunk):
        return true
  false

proc chunkMaySetOuterSlot(chunk: Chunk, depth, slot: int): bool =
  if chunk.subchunks.len > 0 or chunk.forLoops.len > 0 or
      chunk.matches.len > 0 or chunk.tries.len > 0:
    return true
  for inst in chunk.instructions:
    if inst.op == opSetOuterLocal and inst.depth == depth and
        inst.intArg == slot:
      return true
  false

proc canUseTypedIntRecur1(proto: FunctionProto): bool =
  ## A typed unary Int function can use the same recursive call machinery as a
  ## simple call when the parameter slot never needs a runtime type binding.
  proto.typeParams.len == 0 and not proto.checksErrors and
    proto.params.len == 1 and proto.requiredPositional == 1 and
    proto.positionalSlots.len == 1 and proto.positionalSlots[0] >= 0 and
    proto.positionalSlotMaySet.len == 1 and not proto.positionalSlotMaySet[0] and
    proto.restParam.len == 0 and proto.namedParams.len == 0 and
    proto.hasParamTypes and proto.paramTypes.len == 1 and
    proto.paramTypes[0].isBareIntType and proto.hasReturnType and
    proto.returnType.isBareIntType and not proto.isGenerator and
    proto.paramDefaults.len == 1 and not proto.paramDefaults[0].optional

proc canUseSameScopeRecur1(proto: FunctionProto): bool =
  ## Same-scope recursion mutates only the single parameter slot and restores it
  ## when the callee returns. Keep this to the minimal no-local/no-subframe shape.
  (proto.simpleCall or proto.canUseTypedIntRecur1) and proto.localNames.len == 1 and
    proto.positionalSlots[0] == 0 and proto.localNames[0] == proto.params[0] and
    proto.taskFrameKind == tfkNone and proto.chunk.subchunks.len == 0 and
    proto.chunk.forLoops.len == 0 and proto.chunk.matches.len == 0 and
    proto.chunk.tries.len == 0 and proto.chunk.functions.len == 0

proc canUseRecur1(proto: FunctionProto): bool =
  proto.selfParentSlot >= 0 and proto.params.len == 1 and
    proto.requiredPositional == 1 and proto.positionalSlots.len == 1 and
    proto.positionalSlots[0] >= 0 and proto.poolCallScope and
    not proto.callScopeNeedsSlotNames and
    not proto.callScopeNeedsSlotReset and
    (proto.simpleCall or proto.canUseTypedIntRecur1)

proc smallIntConstValue(chunk: Chunk, constIndex: int): tuple[ok: bool, value: int] =
  if constIndex >= 0 and constIndex < chunk.constants.len:
    let v = chunk.constants[constIndex]
    if v.isSmallInt:
      return (true, int(v.smallIntVal))
  (false, 0)

proc rewriteTailReturnGuards(proto: FunctionProto) =
  ## Collapse the tail shape produced for `(if (< x const) x ...)`.
  ## The replacement returns directly on the true branch and skips the four
  ## now-dead condition/then/jump instructions on the false branch. The VM op
  ## keeps a dynamic fallback, so this is also safe for untyped native-fast `<`.
  var i = 0
  while i + 4 < proto.chunk.instructions.len:
    let load = proto.chunk.instructions[i]
    let cmp = proto.chunk.instructions[i + 1]
    let jumpFalse = proto.chunk.instructions[i + 2]
    let trueLoad = proto.chunk.instructions[i + 3]
    let jumpEnd = proto.chunk.instructions[i + 4]
    let loadLocal = load.op == opLoadLocalFast or load.op == opLoadLocal
    let trueLoadLocal = trueLoad.op == opLoadLocalFast or
      trueLoad.op == opLoadLocal
    let cmpLtConst = cmp.op == opIntLtConst or
      (cmp.op == opNativeFastConst and NativeFastKind(cmp.intArg) == nfkLt)
    if loadLocal and cmpLtConst and
        jumpFalse.op == opJumpIfFalse and jumpFalse.intArg == i + 5 and
        trueLoadLocal and trueLoad.intArg == load.intArg and
        jumpEnd.op == opJump and jumpEnd.intArg >= 0 and
        jumpEnd.intArg < proto.chunk.instructions.len and
        proto.chunk.instructions[jumpEnd.intArg].op in {opReturn, opReturnBareInt}:
      let imm = proto.chunk.smallIntConstValue(cmp.depth)
      proto.chunk.instructions[i] = Instruction(
        op: (if imm.ok: opReturnLocalIfIntLtImm else: opReturnLocalIfIntLtConst),
        intArg: load.intArg,
        depth: (if imm.ok: imm.value else: cmp.depth),
        name: load.name, flag: cmp.flag)
      proto.chunk.instructions[i + 1] = Instruction(op: opNoop)
      proto.chunk.instructions[i + 2] = Instruction(op: opNoop)
      proto.chunk.instructions[i + 3] = Instruction(op: opNoop)
      proto.chunk.instructions[i + 4] = Instruction(op: opNoop)
      inc i, 5
    else:
      inc i

proc rewriteBareIntReturnAdds(proto: FunctionProto) =
  ## Collapse the fibonacci-like `(+ (self ...) (self ...))` tail return into
  ## one VM dispatch. Keep this narrower than all Int tail adds: other recursive
  ## shapes can depend on more general frame/stack behavior.
  var i = 0
  while i + 1 < proto.chunk.instructions.len:
    let add = proto.chunk.instructions[i]
    let ret = proto.chunk.instructions[i + 1]
    var sameScopeRecurs = 0
    let scanStart = max(0, i - 6)
    for j in scanStart ..< i:
      if proto.chunk.instructions[j].op in {
          opRecur1LocalIntSubConstSameScope,
          opRecur1LocalIntSubImmSameScope}:
        inc sameScopeRecurs
    if add.op == opIntAdd2 and ret.op == opReturnBareInt and
        sameScopeRecurs >= 2:
      proto.chunk.instructions[i] = Instruction(op: opReturnIntAdd2,
                                                name: add.name)
      proto.chunk.instructions[i + 1] = Instruction(op: opNoop)
      inc i, 2
    else:
      inc i

proc rewriteSelfRecursiveCalls(parent: Chunk) =
  for proto in parent.functions:
    if proto.canUseRecur1 and
        not parent.chunkMaySetSlot(proto.selfParentSlot) and
        not proto.chunk.chunkMaySetOuterSlot(1, proto.selfParentSlot):
      for inst in proto.chunk.instructions.mitems:
        if inst.op == opCallParentLocal1 and inst.intArg == proto.selfParentSlot and
            inst.name == proto.name:
          inst.op = opRecur1
      if proto.canUseTypedIntRecur1 or proto.simpleCall:
        let paramSlot = proto.positionalSlots[0]
        var i = 0
        while i + 2 < proto.chunk.instructions.len:
          let load = proto.chunk.instructions[i]
          let sub = proto.chunk.instructions[i + 1]
          let recur = proto.chunk.instructions[i + 2]
          let loadParam = (load.op == opLoadLocalFast or load.op == opLoadLocal) and
            load.intArg == paramSlot
          let subConst = sub.op == opIntSubConst or
            (sub.op == opNativeFastConst and
             NativeFastKind(sub.intArg) == nfkSub)
          if loadParam and subConst and recur.op == opRecur1 and
              (recur.flag or proto.simpleCall):
            let imm = proto.chunk.smallIntConstValue(sub.depth)
            let fusedOp =
              if imm.ok and proto.canUseSameScopeRecur1:
                opRecur1LocalIntSubImmSameScope
              elif imm.ok:
                opRecur1LocalIntSubImm
              elif proto.canUseSameScopeRecur1:
                opRecur1LocalIntSubConstSameScope
              else:
                opRecur1LocalIntSubConst
            proto.chunk.instructions[i] = Instruction(
              op: fusedOp, intArg: paramSlot,
              depth: (if imm.ok: imm.value else: sub.depth),
              name: load.name, flag: imm.ok)
            proto.chunk.instructions[i + 1] = Instruction(op: opNoop)
            proto.chunk.instructions[i + 2] = Instruction(op: opNoop)
            inc i, 3
          else:
            inc i
      proto.rewriteTailReturnGuards()
    proto.rewriteBareIntReturnAdds()
    proto.chunk.rewriteSelfRecursiveCalls()

proc functionNameAndTypeParams(form: Value): tuple[name: string, typeParams: seq[string]] =
  if form.kind == vkSymbol:
    return (form.symVal, @[])
  if form.kind == vkNode and form.head.kind == vkSymbol:
    result.name = form.head.symVal
    if result.name.len == 0:
      raise newException(GeneError, "generic function requires a name")
    var seen = initTable[string, bool]()
    for arg in form.body:
      if arg.kind != vkSymbol:
        raise newException(GeneError, "generic function type parameters must be names")
      if arg.symVal.len == 0:
        raise newException(GeneError, "generic function type parameter requires a name")
      if seen.hasKey(arg.symVal):
        raise newException(GeneError, "duplicate generic type parameter: " & arg.symVal)
      seen[arg.symVal] = true
      result.typeParams.add arg.symVal
    return
  raise newException(GeneError, "function name must be a symbol or (name type...)")

proc compileSubBody(c: Compiler, forms: openArray[Value],
                    pattern: Value = NIL, scoped = false): Chunk =
  var child = c.childCompiler()
  if scoped:
    child.enableLocalSlots()
    child.parentSlots = c.parentFrames()
    for name in patternBindingNames(pattern):
      discard child.reserveLocal(name)
      if name == "self":
        child.selfAvailable = true
  elif patternBindsSelf(pattern):
    child.selfAvailable = true
  compileBody(child, forms)            # empty -> nil
  discard child.emit(opReturn)
  if scoped:
    child.chunk.localNames = child.localNames
  child.chunk

proc isParamTerminator(s: string): bool =
  s.len == 0 or s in [",", "^", "^^"]

proc isRestParam(s: string): bool =
  s.len > 3 and s.endsWith("...")

proc splitOptionalName(s: string): tuple[name: string, optional: bool] =
  if s.len > 1 and s.endsWith("?"):
    (s[0 .. ^2], true)
  else:
    (s, false)

proc parseParamAdornment(c: Compiler, items: openArray[Value],
                         i: var int): ParamAdornment =
  ## Parse type annotations and compile call-time defaults.
  while i < items.len:
    let s = items[i].symbolText
    case s
    of ":":
      inc i
      if i >= items.len:
        raise newException(GeneError, "parameter annotation requires a type")
      result.typeExpr = items[i]
      inc i
    of "=":
      inc i
      if i >= items.len:
        raise newException(GeneError, "parameter default requires a value")
      result.defaultValue.optional = true
      result.defaultValue.defaultChunk = c.compileDefaultExpr(items[i])
      inc i
    else:
      break

proc paramSpecs(c: Compiler, paramList: Value): ParamSpecs =
  ## Extract positional and named parameter bindings from an `[a ^name b]`
  ## vector. The reader preserves vectors as flat tokens, so `^name` appears as
  ## `^` followed by `name`, and rest params appear as symbols like `xs...`.
  if paramList.kind != vkList: return
  let items = paramList.listItems
  var i = 0
  var sawRest = false
  var sawOptionalPositional = false
  while i < items.len:
    let s = items[i].symbolText
    case s
    of "":
      inc i
    of ",":
      inc i
    of "^", "^^":
      if sawRest:
        raise newException(GeneError, "named parameter cannot follow a rest parameter")
      inc i
      if i >= items.len or items[i].kind != vkSymbol:
        raise newException(GeneError, "named parameter requires a name")
      var argSpec = splitOptionalName(items[i].symVal)
      if argSpec.name.len == 0:
        raise newException(GeneError, "named parameter requires a name")
      let arg = argSpec.name
      inc i
      var local = arg
      if i < items.len:
        let maybeLocal = items[i].symbolText
        if not maybeLocal.isParamTerminator and maybeLocal notin [":", "="]:
          let localSpec = splitOptionalName(maybeLocal)
          local = localSpec.name
          if local.len == 0:
            raise newException(GeneError, "named parameter local requires a name")
          if localSpec.optional:
            argSpec.optional = true
          inc i
      var adornment = c.parseParamAdornment(items, i)
      if argSpec.optional:
        adornment.defaultValue.optional = true
      result.named.add NamedParam(arg: arg, local: local,
                                  typeExpr: adornment.typeExpr,
                                  defaultValue: adornment.defaultValue)
    of ":", "=":
      raise newException(GeneError, "parameter annotation requires a parameter")
    else:
      if sawRest:
        raise newException(GeneError, "parameter cannot follow a rest parameter")
      if s.isRestParam:
        if sawOptionalPositional:
          raise newException(GeneError, "rest parameter cannot follow an optional positional parameter")
        result.rest = s[0 .. ^4]
        if result.rest.len == 0:
          raise newException(GeneError, "rest parameter requires a name")
        sawRest = true
        inc i
        if i < items.len and items[i].symbolText in [":", "="]:
          raise newException(GeneError, "rest parameter cannot have an annotation or default")
      else:
        let spec = splitOptionalName(s)
        if spec.name.len == 0:
          raise newException(GeneError, "parameter requires a name")
        inc i
        var adornment = c.parseParamAdornment(items, i)
        if spec.optional:
          adornment.defaultValue.optional = true
        if adornment.defaultValue.optional:
          sawOptionalPositional = true
        elif sawOptionalPositional:
          raise newException(GeneError, "required positional parameter cannot follow an optional positional parameter")
        result.positional.add spec.name
        result.positionalTypes.add adornment.typeExpr
        result.positionalDefaults.add adornment.defaultValue
        continue
      discard c.parseParamAdornment(items, i)

proc validateMacroParamPattern(pattern: Value) =
  discard patternBindingNames(pattern)

proc macroTypedPattern(pattern, typeExpr: Value): Value =
  if pattern.kind != vkSymbol or pattern.isRestPattern:
    raise newException(GeneError,
      "macro parameter type annotation requires a binding name")
  newNode(pattern, body = @[newSym(":"), typeExpr])

proc implicitMacroDefault(): MacroDefault =
  MacroDefault(optional: true)

proc macroDefaultExpr(expr: Value): MacroDefault =
  MacroDefault(optional: true, hasExpr: true, defaultExpr: expr)

proc parseMacroFlatAdornment(items: openArray[Value], i: var int,
                             pattern: Value): tuple[pattern: Value,
                                                    defaultValue: MacroDefault] =
  result.pattern = pattern
  while i < items.len:
    case items[i].symbolText
    of ":":
      inc i
      if i >= items.len:
        raise newException(GeneError,
          "macro parameter annotation requires a type")
      if result.pattern.isTypedPattern:
        raise newException(GeneError,
          "macro parameter already has a type annotation")
      result.pattern = macroTypedPattern(result.pattern, items[i])
      inc i
    of "=":
      inc i
      if i >= items.len:
        raise newException(GeneError,
          "macro parameter default requires a value")
      result.defaultValue = macroDefaultExpr(items[i])
      inc i
    else:
      break

proc isMacroNamedTerminator(value: Value): bool =
  value.kind == vkSymbol and value.symVal in [",", "^", "^^"]

proc macroParamDef(c: Compiler, paramList: Value): tuple[params: seq[MacroParam],
                                                         named: seq[MacroNamedParam],
                                                         rest: string] =
  if paramList.kind != vkList:
    return
  let items = paramList.listItems
  var i = 0
  var sawRest = false
  var sawOptionalPositional = false
  while i < items.len:
    let item = items[i]
    let s = item.symbolText
    case s
    of "":
      if sawRest:
        raise newException(GeneError, "parameter cannot follow a rest parameter")
      inc i
      let adornment = parseMacroFlatAdornment(items, i, item)
      if adornment.defaultValue.optional:
        sawOptionalPositional = true
      elif sawOptionalPositional:
        raise newException(GeneError,
          "required positional parameter cannot follow an optional positional parameter")
      validateMacroParamPattern(adornment.pattern)
      result.params.add MacroParam(pattern: adornment.pattern,
                                   defaultValue: adornment.defaultValue)
    of ",":
      inc i
    of "^", "^^":
      if sawRest:
        raise newException(GeneError, "named parameter cannot follow a rest parameter")
      inc i
      if i >= items.len or items[i].kind != vkSymbol:
        raise newException(GeneError, "named parameter requires a name")
      let argSpec = splitOptionalName(items[i].symVal)
      if argSpec.name.len == 0:
        raise newException(GeneError, "named parameter requires a name")
      var defaultValue =
        if argSpec.optional: implicitMacroDefault() else: MacroDefault()
      let arg = argSpec.name
      inc i
      var pattern = newSym(arg)
      if i < items.len:
        let maybePattern = items[i]
        let maybeSymbol = maybePattern.symbolText
        if not maybePattern.isMacroNamedTerminator and
            maybeSymbol notin [":", "="]:
          if maybePattern.kind == vkSymbol:
            let localSpec = splitOptionalName(maybePattern.symVal)
            if localSpec.name.len == 0:
              raise newException(GeneError,
                "named parameter local requires a name")
            if localSpec.optional:
              defaultValue = implicitMacroDefault()
            pattern = newSym(localSpec.name)
          else:
            pattern = maybePattern
          inc i
      let adornment = parseMacroFlatAdornment(items, i, pattern)
      if adornment.defaultValue.optional:
        defaultValue = adornment.defaultValue
      validateMacroParamPattern(adornment.pattern)
      result.named.add MacroNamedParam(arg: arg, pattern: adornment.pattern,
                                       defaultValue: defaultValue)
    of ":":
      raise newException(GeneError,
        "macro parameter annotation requires a parameter")
    of "=":
      raise newException(GeneError,
        "macro parameter default requires a parameter")
    else:
      if sawRest:
        raise newException(GeneError, "parameter cannot follow a rest parameter")
      if s.isRestParam:
        if sawOptionalPositional:
          raise newException(GeneError,
            "rest parameter cannot follow an optional positional parameter")
        result.rest = s[0 .. ^4]
        if result.rest.len == 0:
          raise newException(GeneError, "rest parameter requires a name")
        sawRest = true
        inc i
        if i < items.len and items[i].symbolText in [":", "="]:
          raise newException(GeneError,
            "rest parameter cannot have an annotation or default")
      else:
        let spec = splitOptionalName(s)
        if spec.name.len == 0:
          raise newException(GeneError, "parameter requires a name")
        var defaultValue =
          if spec.optional: implicitMacroDefault() else: MacroDefault()
        var pattern = newSym(spec.name)
        inc i
        let adornment = parseMacroFlatAdornment(items, i, pattern)
        if adornment.defaultValue.optional:
          defaultValue = adornment.defaultValue
        if defaultValue.optional:
          sawOptionalPositional = true
        elif sawOptionalPositional:
          raise newException(GeneError,
            "required positional parameter cannot follow an optional positional parameter")
        validateMacroParamPattern(adornment.pattern)
        result.params.add MacroParam(pattern: adornment.pattern,
                                     defaultValue: defaultValue)
  result

proc macroTemplateValue(expr: Value, env: Table[string, Value],
                        c: var Compiler): Value

proc appendMacroSplice(target: var seq[Value], value: Value) =
  case value.kind
  of vkList:
    for item in value.listItems:
      target.add item
  of vkNode:
    for item in value.body:
      target.add item
  else:
    raise newException(GeneError, "macro splice expects a list or node")

proc macroSpliceExpr(value: Value, env: Table[string, Value],
                     c: var Compiler,
                     depth: int): tuple[splice: bool, value: Value] =
  if depth != 1 or value.kind != vkNode or not value.head.isSymbol("unquote"):
    return
  if value.body.len != 1:
    raise newException(GeneError, "unquote requires one expression")
  let inner = value.body[0]
  if inner.kind == vkNode and inner.head.isSymbol("..."):
    if inner.body.len != 1:
      raise newException(GeneError, "splice requires one expression")
    return (true, macroTemplateValue(inner.body[0], env, c))

proc macroFresh(c: var Compiler, name: string): string =
  inc c.gensym
  "__gene_macro_" & $c.gensym & "_" & name

proc hygienicSymbol(value: Value, hygiene: Table[string, string]): Value =
  if value.kind == vkSymbol and hygiene.hasKey(value.symVal):
    newSym(hygiene[value.symVal])
  else:
    value

proc introducedBinderName(node: Value): string =
  if node.kind != vkNode or node.head.kind != vkSymbol or node.body.len == 0:
    return ""
  case node.head.symVal
  of "var", "type", "protocol", "ns", "macro":
    if node.body[0].kind == vkSymbol:
      return node.body[0].symVal
  of "fn":
    if node.body.len >= 2 and node.body[1].kind == vkList:
      if node.body[0].kind == vkSymbol:
        return node.body[0].symVal
      if node.body[0].kind == vkNode and node.body[0].head.kind == vkSymbol:
        return node.body[0].head.symVal
  else:
    discard
  ""

proc expandMacroQuasi(value: Value, env: Table[string, Value], depth: int,
                      c: var Compiler,
                      hygiene: var Table[string, string]): Value

proc expandMacroQuasiMap(source: PropTable, env: Table[string, Value],
                         depth: int, c: var Compiler,
                         hygiene: var Table[string, string]): PropTable =
  result = initOrderedTable[string, Value]()
  for key, item in source:
    result[key] = expandMacroQuasi(item, env, depth, c, hygiene)

proc expandMacroDoNode(node: Value, env: Table[string, Value], depth: int,
                       c: var Compiler,
                       hygiene: var Table[string, string]): Value =
  var localHygiene = hygiene
  var localIntroduced = initTable[string, string]()
  for item in node.body:
    let name = introducedBinderName(item)
    if name.len > 0 and not localIntroduced.hasKey(name):
      localIntroduced[name] = c.macroFresh(name)
      localHygiene[name] = localIntroduced[name]
  var meta = expandMacroQuasiMap(node.meta, env, depth, c, localHygiene)
  var props = expandMacroQuasiMap(node.props, env, depth, c, localHygiene)
  var body: seq[Value]
  for item in node.body:
    body.add expandMacroQuasi(item, env, depth, c, localHygiene)
  newNode(hygienicSymbol(node.head, localHygiene), props = props, body = body,
          meta = meta, immutable = node.nodeImmutable)

proc expandMacroQuasiNodeParts(node: Value, env: Table[string, Value],
                               depth: int, c: var Compiler,
                               hygiene: var Table[string, string]): Value =
  var meta = initOrderedTable[string, Value]()
  for key, item in node.meta:
    meta[key] = expandMacroQuasi(item, env, depth, c, hygiene)
  var props = initOrderedTable[string, Value]()
  for key, item in node.props:
    props[key] = expandMacroQuasi(item, env, depth, c, hygiene)
  let head =
    if node.head.kind == vkSymbol:
      hygienicSymbol(node.head, hygiene)
    else:
      expandMacroQuasi(node.head, env, depth, c, hygiene)
  var body: seq[Value]
  for item in node.body:
    let splice = macroSpliceExpr(item, env, c, depth)
    if splice.splice:
      body.appendMacroSplice(splice.value)
    else:
      body.add expandMacroQuasi(item, env, depth, c, hygiene)
  newNode(head, props = props, body = body, meta = meta,
          immutable = node.nodeImmutable)

proc expandMacroQuasiNode(node: Value, env: Table[string, Value],
                          depth: int, c: var Compiler,
                          hygiene: var Table[string, string]): Value =
  if node.head.isSymbol("unquote"):
    if node.body.len != 1:
      raise newException(GeneError, "unquote requires one expression")
    if depth == 1:
      return macroTemplateValue(node.body[0], env, c)
    expandMacroQuasiNodeParts(node, env, depth - 1, c, hygiene)
  elif node.head.isSymbol("quasiquote"):
    if node.body.len != 1:
      raise newException(GeneError, "quasiquote expects one template")
    expandMacroQuasiNodeParts(node, env, depth + 1, c, hygiene)
  elif depth == 1 and node.head.isSymbol("do"):
    expandMacroDoNode(node, env, depth, c, hygiene)
  else:
    let name = introducedBinderName(node)
    if depth == 1 and name.len > 0 and not hygiene.hasKey(name):
      var localHygiene = hygiene
      localHygiene[name] = c.macroFresh(name)
      expandMacroQuasiNodeParts(node, env, depth, c, localHygiene)
    else:
      expandMacroQuasiNodeParts(node, env, depth, c, hygiene)

proc expandMacroQuasi(value: Value, env: Table[string, Value], depth: int,
                      c: var Compiler,
                      hygiene: var Table[string, string]): Value =
  case value.kind
  of vkNode:
    expandMacroQuasiNode(value, env, depth, c, hygiene)
  of vkList:
    var items: seq[Value]
    for item in value.listItems:
      let splice = macroSpliceExpr(item, env, c, depth)
      if splice.splice:
        items.appendMacroSplice(splice.value)
      else:
        items.add expandMacroQuasi(item, env, depth, c, hygiene)
    newList(items, value.listImmutable)
  of vkMap:
    var entries = initOrderedTable[string, Value]()
    for key, item in value.mapEntries:
      entries[key] = expandMacroQuasi(item, env, depth, c, hygiene)
    newMap(entries, value.mapImmutable)
  of vkSymbol:
    hygienicSymbol(value, hygiene)
  else:
    value

proc macroTemplateValue(expr: Value, env: Table[string, Value],
                        c: var Compiler): Value =
  if expr.kind == vkSymbol and env.hasKey(expr.symVal):
    return env[expr.symVal]
  if expr.kind == vkNode and expr.head.isSymbol("quote"):
    if expr.body.len != 1:
      raise newException(GeneError, "quote expects one expression")
    return expr.body[0]
  if expr.kind == vkNode and expr.head.isSymbol("quasiquote"):
    if expr.body.len != 1:
      raise newException(GeneError, "quasiquote expects one template")
    var hygiene = initTable[string, string]()
    return expandMacroQuasi(expr.body[0], env, 1, c, hygiene)
  expr

proc macroMetaAsMap(target: Value): Value =
  var entries = initOrderedTable[string, Value]()
  if target.kind == vkNode:
    for key, val in target.meta:
      entries[key] = val
  newMap(entries)

proc macroMatchesTypeExpr(expr, value: Value): bool

proc macroMatchesBuiltinType(name: string, value: Value): tuple[known, ok: bool] =
  case name
  of "Any":
    (true, true)
  of "Never":
    (true, false)
  of "Nil":
    (true, value.kind == vkNil)
  of "Void":
    (true, value.kind == vkVoid)
  of "Bool":
    (true, value.kind == vkBool)
  of "Str", "String":
    (true, value.kind == vkString)
  of "Char":
    (true, value.kind == vkChar)
  of "Sym", "Symbol":
    (true, value.kind == vkSymbol)
  of "Int", "Integer":
    (true, value.kind == vkInt)
  of "Number":
    (true, value.kind in {vkInt, vkFloat})
  of "Float", "F32", "F64":
    (true, value.kind == vkFloat)
  of "List":
    (true, value.kind == vkList)
  of "Map", "PropMap":
    (true, value.kind == vkMap)
  of "Gene", "Node":
    (true, value.kind == vkNode)
  of "Selector":
    (true, value.kind == vkNode and value.head.isSymbol("select"))
  else:
    (false, false)

proc macroMatchesTypeExpr(expr, value: Value): bool =
  case expr.kind
  of vkSymbol:
    let name = expr.symVal
    # `T?` is sugar for `(opt T)`; see matchesTypeExpr in vm.nim.
    if name.len > 1 and name[^1] == '?':
      return value.kind == vkNil or
             macroMatchesTypeExpr(newSym(name[0 ..< name.len - 1]), value)
    let builtin = macroMatchesBuiltinType(name, value)
    if builtin.known:
      return builtin.ok
    raise newException(GeneError, "unknown macro type annotation: " & name)
  of vkNode:
    if expr.head.kind == vkSymbol:
      case expr.head.symVal
      of "|":
        for alt in expr.body:
          if macroMatchesTypeExpr(alt, value):
            return true
        return false
      of "opt":
        if expr.body.len != 1:
          raise newException(GeneError, "(opt T) expects one macro type")
        return value.kind == vkNil or macroMatchesTypeExpr(expr.body[0], value)
      of "List":
        if value.kind != vkList:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(List T) expects one macro item type")
        for item in value.listItems:
          if not macroMatchesTypeExpr(expr.body[0], item):
            return false
        return true
      of "Map", "PropMap":
        if value.kind != vkMap:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len notin [1, 2]:
          raise newException(GeneError, "(Map K V) expects macro key and value types")
        let valueType = expr.body[^1]
        for key, item in value.mapEntries:
          if expr.body.len == 2 and not macroMatchesTypeExpr(expr.body[0], newSym(key)):
            return false
          if not macroMatchesTypeExpr(valueType, item):
            return false
        return true
      else:
        discard
    raise newException(GeneError, "unsupported macro type annotation")
  else:
    raise newException(GeneError, "unsupported macro type annotation")

proc macroTryMatch(pattern, target: Value,
                   env: var Table[string, Value]): bool

proc macroPatternItems(target: Value): tuple[items: seq[Value], ok: bool] =
  case target.kind
  of vkList:
    for item in target.listItems:
      result.items.add item
    result.ok = true
  of vkNode:
    for item in target.body:
      result.items.add item
    result.ok = true
  else:
    discard

proc macroMatchSequence(patterns, items: seq[Value],
                        env: var Table[string, Value]): bool =
  var ps: seq[Value]
  for pattern in patterns:
    if not pattern.isSymbol(","):
      ps.add pattern
  var restIdx = -1
  for i, pattern in ps:
    if pattern.isRestPattern:
      restIdx = i
      break
  var trial = env
  if restIdx < 0:
    if ps.len != items.len:
      return false
    for i in 0 ..< ps.len:
      if not macroTryMatch(ps[i], items[i], trial):
        return false
    env = trial
    return true
  let before = restIdx
  let after = ps.len - restIdx - 1
  if items.len < before + after:
    return false
  for i in 0 ..< before:
    if not macroTryMatch(ps[i], items[i], trial):
      return false
  let restName = ps[restIdx].symVal[0 .. ^4]
  if restName != "_":
    var rest: seq[Value]
    for i in before ..< items.len - after:
      rest.add items[i]
    trial[restName] = newList(rest)
  for i in 0 ..< after:
    if not macroTryMatch(ps[restIdx + 1 + i],
                         items[items.len - after + i], trial):
      return false
  env = trial
  true

proc macroTryMatch(pattern, target: Value,
                   env: var Table[string, Value]): bool =
  case pattern.kind
  of vkSymbol:
    let name = pattern.symVal
    if name == "_":
      return true
    env[name] = target
    true
  of vkInt, vkFloat, vkString, vkBool, vkChar, vkNil, vkVoid:
    equal(pattern, target)
  of vkList:
    let (items, ok) = macroPatternItems(target)
    if not ok:
      return false
    macroMatchSequence(pattern.listItems, items, env)
  of vkMap:
    var trial = env
    for key, valuePattern in pattern.mapEntries:
      var field: Value
      case target.kind
      of vkMap:
        if not target.mapEntries.hasKey(key):
          return false
        field = target.mapEntries[key]
      of vkNode:
        if not target.props.hasKey(key):
          return false
        field = target.props[key]
      else:
        return false
      if not macroTryMatch(valuePattern, field, trial):
        return false
    env = trial
    true
  of vkNode:
    if pattern.isTypedPattern:
      pattern.requireTypedPatternShape()
      if not macroMatchesTypeExpr(pattern.body[1], target):
        return false
      let name = pattern.head.symVal
      if name != "_":
        env[name] = target
      return true
    if pattern.head.kind == vkSymbol:
      case pattern.head.symVal
      of "unquote":
        if pattern.body.len != 1 or pattern.body[0].kind != vkSymbol:
          raise newException(GeneError, "pattern %name expects a name")
        if not env.hasKey(pattern.body[0].symVal):
          raise newException(GeneError,
            "macro pattern comparison requires an earlier binding: " &
              pattern.body[0].symVal)
        return equal(target, env[pattern.body[0].symVal])
      of "@":
        if pattern.body.len != 2:
          raise newException(GeneError,
            "pattern (@ meta value) expects two patterns")
        var trial = env
        if not macroTryMatch(pattern.body[0], macroMetaAsMap(target), trial):
          return false
        if not macroTryMatch(pattern.body[1], target, trial):
          return false
        env = trial
        return true
      of "|":
        discard patternBindingNames(pattern)
        for sub in pattern.body:
          var trial = env
          if macroTryMatch(sub, target, trial):
            env = trial
            return true
        return false
      of "&":
        var trial = env
        for sub in pattern.body:
          if not macroTryMatch(sub, target, trial):
            return false
        env = trial
        return true
      of "not":
        if pattern.body.len != 1:
          raise newException(GeneError, "pattern (not p) expects one pattern")
        discard patternBindingNames(pattern)
        var throwaway = env
        return not macroTryMatch(pattern.body[0], target, throwaway)
      else:
        discard
    if target.kind != vkNode:
      return false
    if not equal(pattern.head, target.head):
      return false
    var trial = env
    for key, valuePattern in pattern.props:
      if not target.props.hasKey(key):
        return false
      if not macroTryMatch(valuePattern, target.props[key], trial):
        return false
    if not macroMatchSequence(pattern.body, target.body, trial):
      return false
    env = trial
    true
  else:
    false

proc bindMacroPattern(pattern, target: Value,
                      env: var Table[string, Value],
                      what: string) =
  var trial = env
  if not macroTryMatch(pattern, target, trial):
    raise newException(GeneError, "macro " & what & " pattern did not match")
  env = trial

proc requiredMacroParamCount(params: openArray[MacroParam]): int =
  for param in params:
    if param.defaultValue.optional:
      return
    inc result

proc bindMacroImplicitVoid(pattern: Value, env: var Table[string, Value]) =
  for name in patternBindingNames(pattern):
    env[name] = VOID

proc bindMacroDefault(c: var Compiler, pattern: Value,
                      defaultValue: MacroDefault,
                      env: var Table[string, Value],
                      what: string) =
  if defaultValue.hasExpr:
    bindMacroPattern(pattern, macroTemplateValue(defaultValue.defaultExpr, env, c),
                     env, what)
  else:
    bindMacroImplicitVoid(pattern, env)

proc expandMacro(c: var Compiler, def: MacroDef, node: Value): Value =
  let args = node.body
  let requiredParams = requiredMacroParamCount(def.params)
  if args.len < requiredParams:
    raise newException(GeneError, "macro expects at least " & $requiredParams &
      " argument(s), got " & $args.len)
  if def.rest.len == 0 and args.len > def.params.len:
    raise newException(GeneError, "macro expects at most " & $def.params.len &
      " argument(s), got " & $args.len)
  var env = initTable[string, Value]()
  for i, param in def.params:
    if i < args.len:
      bindMacroPattern(param.pattern, args[i], env, "argument")
    elif param.defaultValue.optional:
      c.bindMacroDefault(param.pattern, param.defaultValue, env, "argument")
  for p in def.named:
    if node.props.hasKey(p.arg):
      bindMacroPattern(p.pattern, node.props[p.arg], env, "named argument")
    elif p.defaultValue.optional:
      c.bindMacroDefault(p.pattern, p.defaultValue, env, "named argument")
    else:
      raise newException(GeneError,
        "macro missing named argument: " & p.arg)
  for key, _ in node.props:
    var found = false
    for p in def.named:
      if p.arg == key:
        found = true
        break
    if not found:
      raise newException(GeneError,
        "macro got unexpected named argument: " & key)
  if def.rest.len > 0:
    var rest: seq[Value]
    for i in def.params.len ..< args.len:
      rest.add args[i]
    env[def.rest] = newList(rest)
  if def.body.len != 1:
    raise newException(GeneError,
      "template macros require exactly one body expression")
  macroTemplateValue(def.body[0], env, c)

proc compileMacroCall(c: var Compiler, node: Value, def: MacroDef) =
  if c.macroExpansionDepth >= MaxMacroExpansionDepth:
    raise newException(GeneError, "macro expansion depth exceeded")
  inc c.macroExpansionDepth
  try:
    compileExpr(c, c.expandMacro(def, node))
  finally:
    dec c.macroExpansionDepth

proc compileMacro(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 2:
    raise newException(GeneError, "macro requires a name and parameter vector")
  if body[0].kind != vkSymbol or body[0].symVal.len == 0:
    raise newException(GeneError, "macro name must be a symbol")
  if body[1].kind != vkList:
    raise newException(GeneError, "macro requires a parameter vector")
  let sig = c.macroParamDef(body[1])
  if c.hasMacros and c.macros.hasKey(body[0].symVal):
    raise newException(GeneError, "duplicate macro: " & body[0].symVal)
  # One name, one meaning (design §11): a macro may not reuse the name of a
  # visible binding — call sites would silently switch from the function to
  # the macro while value positions kept the old binding.
  if c.localSlot(body[0].symVal) >= 0 or c.parentSlot(body[0].symVal).slot >= 0:
    raise newException(GeneError,
      "macro '" & body[0].symVal & "' conflicts with a binding of the same name")
  if not c.hasMacros:
    c.macros = initTable[string, MacroDef]()
  var macroBody: seq[Value]
  for i in 2 ..< body.len:
    macroBody.add body[i]
  c.macros[body[0].symVal] = MacroDef(params: sig.params,
                                      named: sig.named,
                                      rest: sig.rest,
                                      body: macroBody)
  c.hasMacros = true
  c.emitConst NIL

proc rejectReservedEffects(node: Value) =
  if node.props.hasKey("effects"):
    raise newException(GeneError, "^effects is reserved for a future static effect system")

proc isNeverErrorRowEntry(value: Value): bool =
  value.kind == vkSymbol and value.symVal == "Never"

proc compileErrorRow(c: var Compiler, node: Value): tuple[checks: bool, count: int] =
  rejectReservedEffects(node)
  if not node.props.hasKey("errors"):
    return
  let row = node.props["errors"]
  if row.kind != vkList:
    raise newException(GeneError, "^errors must be a list")
  result.checks = true
  var normalized: seq[Value]
  for errorType in row.listItems:
    if errorType.isNeverErrorRowEntry:
      continue
    var duplicate = false
    for existing in normalized:
      if equal(existing, errorType):
        duplicate = true
        break
    if duplicate:
      continue
    normalized.add errorType
  for errorType in normalized:
    compileExpr(c, errorType)
    inc result.count

proc requiredPositionalCount(specs: ParamSpecs): int =
  for i in 0 ..< specs.positional.len:
    if i < specs.positionalDefaults.len and specs.positionalDefaults[i].optional:
      break
    inc result

proc hasOptionalPositional(specs: ParamSpecs): bool =
  for defaultValue in specs.positionalDefaults:
    if defaultValue.optional:
      return true

proc nativeScalarType(expr: Value): string =
  if expr.kind != vkSymbol:
    return ""
  case expr.symVal
  of "Int": "Int"
  of "I64": "I64"
  of "F64": "F64"
  else: ""

proc fixedAotType(expr: Value): string =
  if expr.kind != vkSymbol:
    return ""
  case expr.symVal
  of "I64": "I64"
  of "F64": "F64"
  else: ""

proc nativeArithmeticOp(typeName, opName: string): NativeCompileOp =
  case typeName
  of "Int":
    case opName
    of "+": ncoIntAdd
    of "-": ncoIntSub
    of "*": ncoIntMul
    else: ncoNone
  of "I64":
    case opName
    of "+": ncoI64Add
    of "-": ncoI64Sub
    of "*": ncoI64Mul
    else: ncoNone
  of "F64":
    case opName
    of "+": ncoF64Add
    of "-": ncoF64Sub
    of "*": ncoF64Mul
    else: ncoNone
  else:
    ncoNone

proc nativeIdentityOp(typeName: string): NativeCompileOp =
  case typeName
  of "Int": ncoIntIdentity
  of "I64": ncoI64Identity
  of "F64": ncoF64Identity
  else: ncoNone

proc detectNativeCompileOp(specs: ParamSpecs, body: openArray[Value],
                           bodyStart: int, returnType: Value,
                           typeParams: openArray[string],
                           checksErrors, sawYield: bool):
    tuple[op: NativeCompileOp, paramIndex: int] =
  ## Native-compilation slices for small typed scalar shapes. Dynamic function
  ## entry still performs normal boundary checks before these ops run.
  if typeParams.len != 0 or checksErrors or sawYield:
    return (ncoNone, 0)
  if specs.rest.len != 0 or specs.named.len != 0:
    return (ncoNone, 0)
  if specs.hasOptionalPositional or body.len != bodyStart + 1:
    return (ncoNone, 0)
  let typeName = returnType.nativeScalarType
  if typeName.len == 0:
    return (ncoNone, 0)
  for t in specs.positionalTypes:
    if t.nativeScalarType != typeName:
      return (ncoNone, 0)

  let expr = body[bodyStart]
  if expr.kind == vkSymbol:
    for i, param in specs.positional:
      if expr.symVal == param:
        return (nativeIdentityOp(typeName), i)
    return (ncoNone, 0)

  if specs.positional.len != 2:
    return (ncoNone, 0)
  if expr.kind != vkNode or expr.props.len != 0 or expr.meta.len != 0 or
      expr.body.len != 2 or expr.head.kind != vkSymbol:
    return (ncoNone, 0)
  if expr.body[0].kind != vkSymbol or expr.body[1].kind != vkSymbol:
    return (ncoNone, 0)
  if expr.body[0].symVal != specs.positional[0] or
      expr.body[1].symVal != specs.positional[1]:
    return (ncoNone, 0)

  (nativeArithmeticOp(typeName, expr.head.symVal), 0)

proc aotAvailableFunctions(functions: openArray[FunctionProto],
                           typeName: string): Table[string, int] =
  for fn in functions:
    if fn.aotExpr.kind == vkNil or fn.returnType.fixedAotType != typeName:
      continue
    var supported = true
    for t in fn.paramTypes:
      if t.fixedAotType != typeName:
        supported = false
        break
    if supported:
      result[fn.name] = fn.params.len

proc isAotExpr(expr: Value, params: openArray[string], typeName: string,
               available: Table[string, int]): bool =
  case expr.kind
  of vkSymbol:
    expr.symVal in params
  of vkInt:
    typeName == "I64" and expr.intFitsInt64
  of vkFloat:
    typeName == "F64"
  of vkNode:
    if expr.props.len != 0 or expr.meta.len != 0 or expr.head.kind != vkSymbol:
      return false
    let head = expr.head.symVal
    if head in ["+", "-", "*"]:
      if expr.body.len != 2:
        return false
      return isAotExpr(expr.body[0], params, typeName, available) and
        isAotExpr(expr.body[1], params, typeName, available)
    if available.hasKey(head) and available[head] == expr.body.len:
      for arg in expr.body:
        if not isAotExpr(arg, params, typeName, available):
          return false
      return true
    false
  else:
    false

proc detectAotExpr(c: Compiler, specs: ParamSpecs, body: openArray[Value],
                   bodyStart: int, returnType: Value,
                   typeParams: openArray[string],
                   checksErrors, sawYield: bool): Value =
  if typeParams.len != 0 or checksErrors or sawYield:
    return NIL
  if specs.rest.len != 0 or specs.named.len != 0 or specs.hasOptionalPositional:
    return NIL
  if body.len != bodyStart + 1:
    return NIL
  let typeName = returnType.fixedAotType
  if typeName.len == 0:
    return NIL
  for t in specs.positionalTypes:
    if t.fixedAotType != typeName:
      return NIL
  let available = aotAvailableFunctions(c.chunk.functions, typeName)
  let expr = body[bodyStart]
  if expr.isAotExpr(specs.positional, typeName, available): expr else: NIL

proc buildFunctionProto(c: Compiler, name: string, paramList: Value,
                        body: openArray[Value], bodyStart: int,
                        typeParams: seq[string] = @[],
                        checksErrors = false,
                        errorTypeCount = 0): FunctionProto =
  var start = bodyStart
  var returnType = NIL
  if start < body.len and body[start].isSymbol(":"):
    inc start
    if start >= body.len:
      raise newException(GeneError, "function return annotation requires a type")
    returnType = body[start]
    inc start

  let specs = c.paramSpecs(paramList)
  var seenLocals = initTable[string, bool]()
  for local in specs.positional:
    if seenLocals.hasKey(local):
      raise newException(GeneError, "duplicate parameter binding: " & local)
    seenLocals[local] = true
  for p in specs.named:
    if seenLocals.hasKey(p.local):
      raise newException(GeneError, "duplicate parameter binding: " & p.local)
    seenLocals[p.local] = true
  if specs.rest.len > 0:
    if seenLocals.hasKey(specs.rest):
      raise newException(GeneError, "duplicate parameter binding: " & specs.rest)
    seenLocals[specs.rest] = true
  var fnCompiler = c.childCompiler()
  fnCompiler.enableLocalSlots()
  fnCompiler.parentSlots = c.parentFrames()
  fnCompiler.parentFunctionSigs = c.parentFunctionSigFrames()
  if name.len > 0 and c.localSlot(name) >= 0 and
      fnCompiler.parentFunctionSigs.len > 0:
    let sig = functionSigFromParts(specs.positional.len, typeParams, returnType)
    if sig.known:
      fnCompiler.parentFunctionSigs[0][name] = sig.sig
  var positionalSlots: seq[int]
  for i, name in specs.positional:
    let slot = fnCompiler.reserveLocal(name)
    positionalSlots.add slot
    if i < specs.positionalTypes.len:
      fnCompiler.recordLocalType(name, specs.positionalTypes[i])
      if specs.positionalTypes[i].isBareIntType:
        fnCompiler.fastLocalLoads[name] = slot
  var namedSlots: seq[int]
  for p in specs.named:
    namedSlots.add fnCompiler.reserveLocal(p.local)
    fnCompiler.recordLocalType(p.local, p.typeExpr)
  var restSlot = -1
  if specs.rest.len > 0:
    restSlot = fnCompiler.reserveLocal(specs.rest)
  fnCompiler.allowYield = true
  if "self" in specs.positional or specs.rest == "self":
    fnCompiler.selfAvailable = true
  for p in specs.named:
    if p.local == "self":
      fnCompiler.selfAvailable = true
      break
  compileBodyFrom(fnCompiler, body, start)
  let returnKnownBareInt =
    returnType.isBareIntType and not fnCompiler.sawYield and
      fnCompiler.formsKnownBareInt(body, start)
  discard fnCompiler.emit(if returnKnownBareInt: opReturnBareInt else: opReturn)
  fnCompiler.chunk.localNames = fnCompiler.localNames
  var positionalSlotMaySet: seq[bool]
  for slot in positionalSlots:
    positionalSlotMaySet.add fnCompiler.chunk.chunkMaySetSlot(slot)

  var hasParamTypes = false
  for t in specs.positionalTypes:
    if t.kind != vkNil:
      hasParamTypes = true
      break
  var hasNamedParamTypes = false
  for p in specs.named:
    if p.typeExpr.kind != vkNil:
      hasNamedParamTypes = true
      break
  let selfParentSlot =
    if name.len > 0: c.localSlot(name)
    else: -1
  let simpleCall = typeParams.len == 0 and not checksErrors and
                   specs.rest.len == 0 and specs.named.len == 0 and
                   not hasParamTypes and not hasNamedParamTypes and
                   returnType.kind == vkNil and not fnCompiler.sawYield and
                   not specs.hasOptionalPositional
  let needsCallScope = chunkNeedsCallScope(fnCompiler.chunk)
  var defaultsCanCapture = specs.hasOptionalPositional
  if not defaultsCanCapture:
    for p in specs.named:
      if p.defaultValue.optional:
        defaultsCanCapture = true
        break
  let poolCallScope = needsCallScope and not defaultsCanCapture and
                      chunkCanPoolCallScope(fnCompiler.chunk)
  let callScopeNeedsSlotNames = fnCompiler.chunk.chunkNeedsCallScopeSlotNames()
  let callScopeNeedsSlotReset =
    fnCompiler.localNames.len != specs.positional.len or specs.positional.len > 64
  let native = specs.detectNativeCompileOp(body, start, returnType,
                                           typeParams, checksErrors,
                                           fnCompiler.sawYield)
  let aotExpr = c.detectAotExpr(specs, body, start, returnType,
                                typeParams, checksErrors, fnCompiler.sawYield)
  let aotFrameKind =
    if aotExpr.kind == vkNil: afkNone
    else: afkTypedNative
  let taskFrameKind =
    if fnCompiler.sawYield: tfkGenerator
    elif bodyContainsAwait(body, start): tfkVm
    else: tfkNone
  var fastBindUnaryInt =
    typeParams.len == 0 and not checksErrors and specs.positional.len == 1 and
    specs.requiredPositionalCount == 1 and positionalSlots.len == 1 and
    positionalSlots[0] >= 0 and specs.rest.len == 0 and specs.named.len == 0 and
    hasParamTypes and specs.positionalTypes.len == 1 and
    specs.positionalTypes[0].isBareIntType and returnType.isBareIntType and
    not fnCompiler.sawYield and specs.positionalDefaults.len == 1 and
    not specs.positionalDefaults[0].optional
  var fastBindPositionalInt =
    typeParams.len == 0 and not checksErrors and not fnCompiler.sawYield and
    specs.rest.len == 0 and specs.named.len == 0 and specs.positional.len > 0 and
    specs.requiredPositionalCount == specs.positional.len and
    positionalSlots.len == specs.positional.len and hasParamTypes and
    specs.positionalTypes.len == specs.positional.len and returnType.isBareIntType and
    specs.positionalDefaults.len == specs.positional.len
  if fastBindPositionalInt:
    for i in 0 ..< specs.positional.len:
      if positionalSlots[i] < 0 or not specs.positionalTypes[i].isBareIntType or
          specs.positionalDefaults[i].optional:
        fastBindPositionalInt = false
        break
  result = FunctionProto(name: name, sourceLoc: c.currentLoc,
                         typeParams: typeParams,
                         params: specs.positional,
                         localNames: fnCompiler.localNames,
                         positionalSlots: positionalSlots,
                         positionalSlotMaySet: positionalSlotMaySet,
                         namedSlots: namedSlots,
                         restSlot: restSlot,
                         requiredPositional: specs.requiredPositionalCount,
                         simpleCall: simpleCall,
                         needsCallScope: needsCallScope,
                         poolCallScope: poolCallScope,
                         callScopeNeedsSlotNames: callScopeNeedsSlotNames,
                         callScopeNeedsSlotReset: callScopeNeedsSlotReset,
                         paramTypes: specs.positionalTypes,
                         hasParamTypes: hasParamTypes,
                         paramDefaults: specs.positionalDefaults,
                         restParam: specs.rest, namedParams: specs.named,
                         hasNamedParamTypes: hasNamedParamTypes,
                         returnType: returnType,
                         hasReturnType: returnType.kind != vkNil,
                         returnKnownBareInt: returnKnownBareInt,
                         fastBindUnaryInt: fastBindUnaryInt,
                         fastBindPositionalInt: fastBindPositionalInt,
                         isGenerator: fnCompiler.sawYield,
                         selfParentSlot: selfParentSlot,
                         nativeOp: native.op,
                         nativeParamIndex: native.paramIndex,
                         aotExpr: aotExpr,
                         aotFrameKind: aotFrameKind,
                         aotFrameCanSuspend: false,
                         taskFrameKind: taskFrameKind,
                         checksErrors: checksErrors,
                         errorTypeCount: errorTypeCount,
                         chunk: fnCompiler.chunk)
  result.chunk.owner = result

proc compileIf(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0:
    c.emitConst NIL
    return

  if body.len >= 2 and body[1].kind == vkNode and body[1].head.isSymbol("then"):
    compileExpr(c, body[0])
    var nextJump = c.emitJump(opJumpIfFalse)
    compileBody(c, body[1].body)
    var endJumps: seq[int]
    endJumps.add c.emitJump(opJump)
    c.patchJump(nextJump)

    var hasDefault = false
    for i in 2 ..< body.len:
      let clause = body[i]
      if clause.kind != vkNode or clause.head.kind != vkSymbol:
        continue
      case clause.head.symVal
      of "elif":
        if clause.body.len == 0:
          continue
        compileExpr(c, clause.body[0])
        nextJump = c.emitJump(opJumpIfFalse)
        compileBodyFrom(c, clause.body, 1)
        endJumps.add c.emitJump(opJump)
        c.patchJump(nextJump)
      of "else":
        compileBody(c, clause.body)
        hasDefault = true
        break
      else:
        discard

    if not hasDefault:
      c.emitConst NIL
    for at in endJumps:
      c.patchJump(at)
    return

  compileExpr(c, body[0])
  let elseJump = c.emitJump(opJumpIfFalse)
  if body.len >= 2:
    compileExpr(c, body[1])
  else:
    c.emitConst NIL
  let endJump = c.emitJump(opJump)
  c.patchJump(elseJump)
  if body.len >= 3:
    compileExpr(c, body[2])
  else:
    c.emitConst NIL
  c.patchJump(endJump)

# && and || evaluate operands left to right, stop at the first falsy (&&) or
# truthy (||) operand, and yield the last operand evaluated — not a coerced
# Bool — so `(|| maybe-void "default")` works as a default-value form.
proc compileShortCircuit(c: var Compiler, node: Value, op: OpCode,
                         emptyValue: Value) =
  let body = node.body
  if body.len == 0:
    c.emitConst emptyValue
    return
  var jumps: seq[int] = @[]
  for i in 0 ..< body.len:
    compileExpr(c, body[i])
    if i < body.len - 1:
      jumps.add c.emitJump(op)
  for at in jumps:
    c.patchJump(at)

proc compileNot(c: var Compiler, node: Value) =
  if node.body.len != 1:
    raise newException(GeneError, "! expects exactly one argument")
  compileExpr(c, node.body[0])
  discard c.emit(opNot)

proc compileVar(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0:
    raise newException(GeneError, "var requires a name or pattern")
  let typed = body.len >= 2 and body[1].isSymbol(":")
  if typed and body.len < 3:
    raise newException(GeneError, "var type annotation requires a type")
  let valueIndex = if typed: 3 else: 1
  if c.useLocalSlots and body[0].kind == vkSymbol and body.len > valueIndex and
      body[valueIndex].kind == vkNode and body[valueIndex].head.isSymbol("fn"):
    discard c.reserveLocal(body[0].symVal)
  if body.len > valueIndex:
    if body[0].kind == vkSymbol and body[valueIndex].kind == vkNode and
        body[valueIndex].head.isSymbol("fn"):
      compileFn(c, body[valueIndex], inferredName = body[0].symVal)
    else:
      compileExpr(c, body[valueIndex])
  else:
    c.emitConst NIL
  if typed:
    let where =
      if body[0].kind == vkSymbol: "var '" & body[0].symVal & "'"
      else: "var destructuring"
    discard c.emit(opCheckType, c.chunk.addConst(body[2]), name = where)
  if body[0].kind == vkSymbol:
    c.emitDefineBinding(body[0].symVal)
    if typed:
      c.recordLocalType(body[0].symVal, body[2])
      c.emitDeclareType(body[0].symVal, body[2])
    if body[0].symVal == "self":
      c.selfAvailable = true
  else:
    if c.useLocalSlots:
      for name in patternBindingNames(body[0]):
        discard c.reserveLocal(name)
    discard c.emit(opMatchBind, c.chunk.addConst(body[0]))  # destructuring
    if patternBindsSelf(body[0]):
      c.selfAvailable = true

proc compileSet(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 2 or body[0].kind != vkSymbol:
    raise newException(GeneError, "set requires a name and a value")
  compileExpr(c, body[1])
  c.emitSetBinding(body[0].symVal)

proc compileFn(c: var Compiler, node: Value, inferredName: string) =
  let body = node.body
  var idx = 0
  var name = ""
  var definesName = false
  var typeParams: seq[string]
  if body.len > 0 and (body[0].kind == vkSymbol or body[0].kind == vkNode):
    let nameSpec = functionNameAndTypeParams(body[0])
    name = nameSpec.name
    typeParams = nameSpec.typeParams
    definesName = name.len > 0
    idx = 1
  elif inferredName.len > 0:
    name = inferredName
  if idx >= body.len or body[idx].kind != vkList:
    raise newException(GeneError, "fn requires a parameter vector")

  if definesName and c.useLocalSlots:
    discard c.reserveLocal(name)
  let errorRow = compileErrorRow(c, node)
  let proto = buildFunctionProto(c, name, body[idx], body, idx + 1,
                                 typeParams = typeParams,
                                 checksErrors = errorRow.checks,
                                 errorTypeCount = errorRow.count)
  c.recordLocalFunctionSig(name, proto)
  discard c.emit(opMakeFn, c.chunk.addFunction(proto))
  if definesName:
    c.emitDefineBinding(name)

proc importSelections(sel: Value): seq[ImportSelection] =
  ## Parse a single name `add` or a `[add, sub : minus]` selection list. The
  ## reader keeps vectors as flat tokens, so `,` and `:` arrive as symbols.
  if sel.kind == vkSymbol:
    return @[ImportSelection(name: sel.symVal, local: sel.symVal)]
  if sel.kind != vkList:
    raise newException(GeneError, "import selection must be a name or [list]")
  let items = sel.listItems
  var i = 0
  while i < items.len:
    let s = items[i].symbolText
    if s == "," or s == "":
      inc i
      continue
    var local = s
    inc i
    if i < items.len and items[i].symbolText == ":":
      inc i
      if i >= items.len or items[i].kind != vkSymbol:
        raise newException(GeneError, "import alias requires a name")
      local = items[i].symVal
      inc i
    result.add ImportSelection(name: s, local: local)

proc nsPathSegments(v: Value): seq[string] =
  if v.kind == vkSymbol:
    result.add v.symVal
  elif v.kind == vkNode and v.head.isSymbol("path"):
    for seg in v.body:
      if seg.kind != vkSymbol:
        raise newException(GeneError, "import namespace path must be symbols")
      result.add seg.symVal
  else:
    raise newException(GeneError, "import source must be a namespace path or `from \"path\"`")

proc literalName(v: Value, context: string): string =
  case v.kind
  of vkString:
    v.strVal
  of vkSymbol:
    v.symVal
  of vkNode:
    if v.head.isSymbol("path"):
      var segments: seq[string]
      for segment in v.body:
        if segment.kind != vkSymbol:
          raise newException(GeneError, context & " must be a string, symbol, or symbol path")
        segments.add segment.symVal
      segments.join("/")
    else:
      raise newException(GeneError, context & " must be a string, symbol, or symbol path")
  else:
    raise newException(GeneError, context & " must be a string, symbol, or symbol path")

proc propLiteral(node: Value, key, defaultValue, context: string): string =
  if not node.props.hasKey(key):
    return defaultValue
  literalName(node.props[key], context & " ^" & key)

proc propInt(node: Value, key: string, defaultValue: int,
             context: string, hasValue: var bool): int =
  if not node.props.hasKey(key):
    hasValue = false
    return defaultValue
  let value = node.props[key]
  if value.kind != vkInt:
    raise newException(GeneError, context & " ^" & key & " must be an Int")
  hasValue = true
  int(value.intVal)

proc propBool(node: Value, key: string, defaultValue: bool,
              context: string): bool =
  if not node.props.hasKey(key):
    return defaultValue
  let value = node.props[key]
  if value.kind != vkBool:
    raise newException(GeneError, context & " ^" & key & " must be a Bool")
  value.boolVal

proc parseFfiParams(params: Value, context = "ffi/fn"): seq[FfiParam] =
  if params.kind != vkList:
    raise newException(GeneError, context & " parameters must be a [list]")
  let items = params.listItems
  var i = 0
  while i < items.len:
    if items[i].isSymbol(","):
      inc i
      continue
    if items[i].kind != vkSymbol:
      raise newException(GeneError, context & " parameter must start with a name")
    let name = items[i].symVal
    inc i
    if i >= items.len or not items[i].isSymbol(":"):
      raise newException(GeneError, context & " parameter '" & name & "' requires a type")
    inc i
    if i >= items.len:
      raise newException(GeneError, context & " parameter '" & name & "' is missing a type")
    result.add FfiParam(name: name, typeExpr: items[i])
    inc i

proc parseFfiReturn(body: seq[Value], idx: var int, context: string): Value =
  result = newSym("C/Void")
  if idx < body.len:
    if not body[idx].isSymbol(":"):
      raise newException(GeneError, context & " return type must follow `:`")
    inc idx
    if idx >= body.len:
      raise newException(GeneError, context & " return type is missing")
    result = body[idx]
    inc idx

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
    $expr.kind

proc ffiAggregateTypeHead(expr: Value): string =
  case expr.kind
  of vkSymbol:
    expr.symVal
  of vkNode:
    if expr.head.kind == vkSymbol:
      expr.head.symVal
    elif expr.head.kind == vkNode and expr.head.head.isSymbol("path"):
      literalName(expr.head, "FFI aggregate field type")
    else:
      ""
  else:
    ""

proc ffiAggregateTypeDescription(expr: Value): string =
  ffiTypeLabel(expr)

proc validateFfiAggregateFieldType(context, fieldName: string, expr: Value) =
  const scalarFields = [
    "C/Int8", "C/UInt8", "C/Int16", "C/UInt16", "C/Int32", "C/UInt32",
    "C/Int64", "C/UInt64", "C/Char", "C/UChar", "C/Short", "C/UShort",
    "C/Int", "C/UInt", "C/Long", "C/ULong", "C/Size", "C/PtrDiff",
    "C/Float", "C/Double", "C/Bool", "C/CStr"
  ]
  const pointerFields = [
    "C/Ptr", "C/NullablePtr", "C/ConstPtr", "C/NullableConstPtr", "C/OwnedPtr"
  ]
  let head = ffiAggregateTypeHead(expr)
  if expr.kind == vkSymbol and head in scalarFields:
    return
  if expr.kind == vkNode and head in pointerFields and expr.body.len == 1:
    return
  raise newException(GeneError,
    context & " field '" & fieldName & "' type must be a scalar, C/CStr, " &
    "or pointer-like ABI type, got " & ffiAggregateTypeDescription(expr))

proc isFfiScalarOrCStrLabel(label: string): bool =
  label in [
    "C/Int8", "C/UInt8", "C/Int16", "C/UInt16", "C/Int32", "C/UInt32",
    "C/Int64", "C/UInt64", "C/Char", "C/UChar", "C/Short", "C/UShort",
    "C/Int", "C/UInt", "C/Long", "C/ULong", "C/Size", "C/PtrDiff",
    "C/Float", "C/Double", "C/Bool", "C/CStr"
  ]

proc ffiCompositeHead(expr: Value): string =
  if expr.kind == vkNode:
    ffiTypeLabel(expr.head)
  else:
    ""

proc isFfiPointerType(expr: Value): bool =
  expr.kind == vkNode and expr.body.len == 1 and
    ffiCompositeHead(expr) in [
      "C/Ptr", "C/NullablePtr", "C/ConstPtr", "C/NullableConstPtr",
      "C/OwnedPtr"
    ]

proc isFfiBufferArgType(expr: Value): bool =
  expr.kind == vkNode and expr.body.len == 1 and
    ffiCompositeHead(expr) in ["C/Slice", "Buffer"]

proc validateFfiFnParamType(context, paramName: string, expr: Value) =
  let label = ffiTypeLabel(expr)
  if isFfiScalarOrCStrLabel(label) or isFfiPointerType(expr) or
      isFfiBufferArgType(expr):
    return
  raise newException(GeneError,
    context & " parameter '" & paramName & "' has unsupported C wrapper type " &
    label)

proc validateFfiFnReturnType(context: string, expr: Value, release: string) =
  let label = ffiTypeLabel(expr)
  if label == "C/Void" or isFfiScalarOrCStrLabel(label) or
      isFfiPointerType(expr):
    if label.startsWith("(C/OwnedPtr ") and release.len == 0:
      raise newException(GeneError,
        context & " return type " & label & " requires ^release")
    if release.len > 0 and not label.startsWith("(C/OwnedPtr "):
      raise newException(GeneError,
        context & " ^release is only valid for C/OwnedPtr results")
    return
  raise newException(GeneError,
    context & " return type has unsupported C wrapper type " & label)

proc validateFfiCallingConvention(context, calling: string) =
  case calling.toLowerAscii
  of "c", "cdecl", "stdcall":
    discard
  else:
    raise newException(GeneError,
      context & " ^calling must be C, cdecl, or stdcall")

proc validateFfiAbi(context, abi: string) =
  if abi.toLowerAscii != "c":
    raise newException(GeneError, context & " ^abi must be C")

proc validateFfiLayout(context, layout: string) =
  if layout.toLowerAscii != "c":
    raise newException(GeneError, context & " ^layout must be C")

proc parseFfiAggregateFields(context: string, fields: Value,
                             allowOffsets: bool): seq[FfiStructField] =
  if fields.kind != vkList:
    raise newException(GeneError, context & " ^fields must be a [list]")
  for field in fields.listItems:
    if field.kind != vkList:
      raise newException(GeneError, context & " field must be a [field Type] list")
    let items = field.listItems
    if items.len < 2 or items[0].kind != vkSymbol:
      raise newException(GeneError, context & " field must be [name Type]")
    let validLen =
      if allowOffsets: items.len in [2, 5]
      else: items.len == 2
    if not validLen:
      raise newException(GeneError,
        if allowOffsets:
          context & " field must be [name Type] or [name Type ^offset Int]"
        else:
          context & " field must be [name Type]")
    var hasOffset = false
    var offset = -1
    if items.len == 5:
      if items[2].symbolText notin ["^", "^^"] or
          items[3].symbolText != "offset" or items[4].kind != vkInt:
        raise newException(GeneError,
          context & " field offset must be written as ^offset Int")
      hasOffset = true
      offset = int(items[4].intVal)
    validateFfiAggregateFieldType(context, items[0].symVal, items[1])
    result.add FfiStructField(name: items[0].symVal, typeExpr: items[1],
                              offset: offset, hasOffset: hasOffset)

proc parseFfiStructFields(fields: Value): seq[FfiStructField] =
  parseFfiAggregateFields("ffi/struct", fields, allowOffsets = true)

proc parseFfiUnionFields(fields: Value): seq[FfiStructField] =
  parseFfiAggregateFields("ffi/union", fields, allowOffsets = false)

proc compileFfiLibrary(c: var Compiler, node: Value) =
  let body = node.body
  if body.len != 1 or body[0].kind != vkSymbol:
    raise newException(GeneError, "ffi/library requires a name")
  let name = body[0].symVal
  if c.ffiLibraryNames.hasKey(name):
    raise newException(GeneError, "duplicate ffi/library: " & name)
  for key, _ in node.props:
    if key notin ["linux", "macos", "windows"]:
      raise newException(GeneError,
        "ffi/library has unsupported property ^" & key)
  let proto = FfiLibraryProto(
    name: name,
    linux: propLiteral(node, "linux", "", "ffi/library"),
    macos: propLiteral(node, "macos", "", "ffi/library"),
    windows: propLiteral(node, "windows", "", "ffi/library"))
  if proto.linux.len == 0 and proto.macos.len == 0 and proto.windows.len == 0:
    raise newException(GeneError,
      "ffi/library requires at least one target library name")
  c.ffiLibraryNames[name] = true
  discard c.chunk.addFfiLibrary(proto)
  c.emitConst(newSym(proto.name))
  c.emitDefineBinding(proto.name)

proc compileFfiFn(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 2 or body[0].kind != vkSymbol:
    raise newException(GeneError, "ffi/fn requires a name and parameter list")
  let name = body[0].symVal
  if body[1].kind != vkList:
    raise newException(GeneError, "ffi/fn requires a parameter list")
  var ret = newSym("C/Void")
  var idx = 2
  if idx < body.len:
    if not body[idx].isSymbol(":"):
      raise newException(GeneError, "ffi/fn return type must follow `:`")
    inc idx
    if idx >= body.len:
      raise newException(GeneError, "ffi/fn return type is missing")
    ret = body[idx]
    inc idx
  if idx < body.len:
    raise newException(GeneError, "ffi/fn has unexpected body forms")
  let symbol = propLiteral(node, "symbol", name, "ffi/fn")
  let library = propLiteral(node, "library", "", "ffi/fn")
  if node.props.hasKey("library") and library.len == 0:
    raise newException(GeneError, "ffi/fn ^library must not be empty")
  let release = propLiteral(node, "release", "", "ffi/fn")
  if node.props.hasKey("release") and release.len == 0:
    raise newException(GeneError, "ffi/fn ^release must not be empty")
  let proto = FfiFnProto(name: name,
                         library: library,
                         libraryDeclared: library.len > 0 and
                           c.ffiLibraryNames.hasKey(library),
                         symbol: symbol,
                         abi: propLiteral(node, "abi", "C", "ffi/fn"),
                         calling: propLiteral(node, "calling", "C", "ffi/fn"),
                         params: parseFfiParams(body[1]),
                         returnType: ret,
                         release: release)
  for param in proto.params:
    validateFfiFnParamType("ffi/fn", param.name, param.typeExpr)
  validateFfiFnReturnType("ffi/fn", proto.returnType, proto.release)
  validateFfiAbi("ffi/fn", proto.abi)
  validateFfiCallingConvention("ffi/fn", proto.calling)
  discard c.chunk.addFfiFn(proto)
  c.emitConst(newNativeFn(name, nil))
  c.emitDefineBinding(name)

proc compileFfiStruct(c: var Compiler, node: Value) =
  let body = node.body
  if body.len != 1 or body[0].kind != vkSymbol:
    raise newException(GeneError, "ffi/struct requires a name")
  if not node.props.hasKey("fields"):
    raise newException(GeneError, "ffi/struct requires ^fields")
  var hasSize = false
  var hasAlign = false
  let layout = propLiteral(node, "layout", "C", "ffi/struct")
  validateFfiLayout("ffi/struct", layout)
  let proto = FfiStructProto(
    name: body[0].symVal,
    layout: layout,
    size: propInt(node, "size", -1, "ffi/struct", hasSize),
    hasSize: hasSize,
    align: propInt(node, "align", -1, "ffi/struct", hasAlign),
    hasAlign: hasAlign,
    fields: parseFfiStructFields(node.props["fields"]))
  discard c.chunk.addFfiStruct(proto)
  c.emitConst(newSym(proto.name))
  c.emitDefineBinding(proto.name)

proc compileFfiUnion(c: var Compiler, node: Value) =
  let body = node.body
  if body.len != 1 or body[0].kind != vkSymbol:
    raise newException(GeneError, "ffi/union requires a name")
  if not node.props.hasKey("fields"):
    raise newException(GeneError, "ffi/union requires ^fields")
  var hasSize = false
  var hasAlign = false
  let layout = propLiteral(node, "layout", "C", "ffi/union")
  validateFfiLayout("ffi/union", layout)
  let proto = FfiUnionProto(
    name: body[0].symVal,
    layout: layout,
    size: propInt(node, "size", -1, "ffi/union", hasSize),
    hasSize: hasSize,
    align: propInt(node, "align", -1, "ffi/union", hasAlign),
    hasAlign: hasAlign,
    fields: parseFfiUnionFields(node.props["fields"]))
  discard c.chunk.addFfiUnion(proto)
  c.emitConst(newSym(proto.name))
  c.emitDefineBinding(proto.name)

proc compileFfiSignature(c: var Compiler, node: Value,
                         kind: FfiSignatureKind) =
  let context =
    if kind == fskCallback: "ffi/callback"
    else: "ffi/signature"
  let body = node.body
  if body.len < 2 or body[0].kind != vkSymbol:
    raise newException(GeneError, context & " requires a name and parameter list")
  if body[1].kind != vkList:
    raise newException(GeneError, context & " requires a parameter list")
  var idx = 2
  let ret = parseFfiReturn(body, idx, context)
  if idx < body.len:
    raise newException(GeneError, context & " has unexpected body forms")
  let proto = FfiSignatureProto(
    name: body[0].symVal,
    kind: kind,
    abi: propLiteral(node, "abi", "C", context),
    params: parseFfiParams(body[1], context),
    returnType: ret,
    escaping: propBool(node, "escaping", false, context),
    runtimeConstructible: kind == fskDynamic)
  validateFfiAbi(context, proto.abi)
  if kind == fskCallback:
    if proto.escaping:
      raise newException(GeneError,
        "ffi/callback ^escaping true is not supported yet")
    for param in proto.params:
      validateFfiFnParamType(context, param.name, param.typeExpr)
    validateFfiFnReturnType(context, proto.returnType, "")
  discard c.chunk.addFfiSignature(proto)
  c.emitConst(newSym(proto.name))
  c.emitDefineBinding(proto.name)

proc compileImport(c: var Compiler, node: Value) =
  if not c.allowAmbientImports:
    raise newException(GeneError, "eval cannot use import; add imports to Env")
  var spec: ImportSpec
  if node.props.hasKey("as"):
    let a = node.props["as"]
    if a.kind != vkSymbol:
      raise newException(GeneError, "import ^as requires a name")
    spec.alias = a.symVal
  let body = node.body
  var fromIdx = -1
  for i, e in body:
    if e.isSymbol("from"):
      fromIdx = i
      break
  if fromIdx >= 0:
    spec.fromModule = true
    if fromIdx + 1 >= body.len or body[fromIdx + 1].kind != vkString:
      raise newException(GeneError, "import: `from` requires a path string")
    spec.modulePath = body[fromIdx + 1].strVal
    if fromIdx == 1:
      spec.selections = importSelections(body[0])
    elif fromIdx > 1:
      raise newException(GeneError, "import: malformed `from` clause")
  else:
    if body.len == 0:
      raise newException(GeneError, "import requires a source")
    spec.nsSegments = nsPathSegments(body[0])
    if body.len >= 2:
      spec.selections = importSelections(body[1])
  if spec.alias.len == 0 and spec.selections.len == 0:
    raise newException(GeneError, "import needs `^as` or a selection list")
  # Cross-module macros: selections that name a macro exported by the target
  # module become compile-time definitions here and are stripped from the
  # runtime spec (macros are not runtime namespace bindings). The opImport
  # still runs so the module executes and its impls become visible.
  if spec.fromModule and c.importedMacroSets.hasKey(spec.modulePath):
    let exported = c.importedMacroSets[spec.modulePath]
    var runtimeSelections: seq[ImportSelection]
    for sel in spec.selections:
      if exported.hasKey(sel.name):
        if c.hasMacros and c.macros.hasKey(sel.local):
          raise newException(GeneError, "duplicate macro: " & sel.local)
        if c.localSlot(sel.local) >= 0 or c.parentSlot(sel.local).slot >= 0:
          raise newException(GeneError,
            "macro '" & sel.local & "' conflicts with a binding of the same name")
        if not c.hasMacros:
          c.macros = initTable[string, MacroDef]()
          c.hasMacros = true
        c.macros[sel.local] = exported[sel.name]
        c.importedMacroNames.incl sel.local
      else:
        runtimeSelections.add sel
    spec.selections = runtimeSelections
  if c.useLocalSlots:
    if spec.alias.len > 0:
      discard c.reserveLocal(spec.alias)
    for sel in spec.selections:
      discard c.reserveLocal(sel.local)
  discard c.emit(opImport, c.chunk.addImport(spec))

proc compileMod(c: var Compiler, node: Value, allowModDecl: bool) =
  ## A file/source unit already has a loader-created Module; `(mod name @meta
  ## body...)` names that module, stores its metadata, and runs the body in the
  ## current module scope.
  if not allowModDecl:
    raise newException(GeneError, "mod must be a top-level form")
  if c.seenModDecl:
    raise newException(GeneError, "duplicate module declaration")
  if node.body.len == 0 or node.body[0].kind != vkSymbol:
    raise newException(GeneError, "mod requires a name")
  c.seenModDecl = true
  var meta = initOrderedTable[string, Value]()
  for key, val in node.meta:
    meta[key] = val
  discard c.emit(opSetModuleName, c.chunk.addConst(newMap(meta)),
                 name = node.body[0].symVal)
  if node.body.len > 1:
    discard c.emit(opPop)
    compileBodyFrom(c, node.body, 1)

proc compileNs(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "ns requires a name")
  let name = body[0].symVal
  var nsCompiler = c.childCompiler()
  nsCompiler.enableLocalSlots()
  nsCompiler.parentSlots = c.parentFrames()
  compileBodyFrom(nsCompiler, body, 1)
  discard nsCompiler.emit(opReturn)
  nsCompiler.chunk.localNames = nsCompiler.localNames
  nsCompiler.chunk.mirrorSlots = true
  discard c.reserveLocal(name)
  let idx = c.chunk.addSubchunk(nsCompiler.chunk)
  discard c.emit(opMakeNamespace, idx, name = name)

proc compileEnv(c: var Compiler, node: Value) =
  if node.body.len != 0:
    raise newException(GeneError, "env does not take positional arguments")
  for key, _ in node.props:
    if key notin ["bindings", "parent", "imports", "module", "capabilities", "policy"]:
      raise newException(GeneError, "env unknown option: ^" & key)
  if node.props.hasKey("bindings"):
    compileExpr(c, node.props["bindings"])
  else:
    c.emitConst newMap()
  if node.props.hasKey("parent"):
    compileExpr(c, node.props["parent"])
  else:
    c.emitConst NIL
  if node.props.hasKey("imports"):
    compileExpr(c, node.props["imports"])
  else:
    c.emitConst newList()
  if node.props.hasKey("module"):
    compileExpr(c, node.props["module"])
  else:
    c.emitConst NIL
  if node.props.hasKey("capabilities"):
    compileExpr(c, node.props["capabilities"])
  else:
    c.emitConst NIL
  if node.props.hasKey("policy"):
    compileExpr(c, node.props["policy"])
  else:
    c.emitConst NIL
  discard c.emit(opMakeEnv)

proc compileEval(c: var Compiler, node: Value) =
  if node.body.len != 1:
    raise newException(GeneError, "eval expects one node")
  if not node.props.hasKey("in"):
    raise newException(GeneError, "eval requires ^in Env")
  for key, _ in node.props:
    if key != "in":
      raise newException(GeneError, "eval unknown option: ^" & key)
  compileExpr(c, node.body[0])
  compileExpr(c, node.props["in"])
  discard c.emit(opEval)

proc compileQuasiTemplate(c: var Compiler, value: Value, depth: int)

proc quasiSpliceExpr(value: Value, depth: int): tuple[splice: bool, expr: Value] =
  if depth != 1 or value.kind != vkNode or not value.head.isSymbol("unquote"):
    return
  if value.body.len != 1:
    raise newException(GeneError, "unquote requires one expression")
  let inner = value.body[0]
  if inner.kind == vkNode and inner.head.isSymbol("..."):
    if inner.body.len != 1:
      raise newException(GeneError, "splice requires one expression")
    return (true, inner.body[0])

proc compileQuasiMap(c: var Compiler, value: Value, depth: int) =
  var keys: seq[string]
  for key, item in value.mapEntries:
    keys.add key
    compileQuasiTemplate(c, item, depth)
  discard c.emit(opMakeMap, keys.len, names = keys, flag = value.mapImmutable)

proc compileQuasiList(c: var Compiler, value: Value, depth: int) =
  var splices: seq[bool]
  var hasSplice = false
  for item in value.listItems:
    let splice = item.quasiSpliceExpr(depth)
    if splice.splice:
      compileExpr(c, splice.expr)
      splices.add true
      hasSplice = true
    else:
      compileQuasiTemplate(c, item, depth)
      splices.add false
  if hasSplice:
    let idx = c.chunk.addListBuild(ListBuildProto(splices: splices,
                                                  immutable: value.listImmutable))
    discard c.emit(opMakeListSplice, idx)
  else:
    discard c.emit(opMakeList, value.listItems.len, flag = value.listImmutable)

proc compileQuasiNodeParts(c: var Compiler, node: Value, depth: int) =
  compileQuasiTemplate(c, node.head, depth)
  var metaNames: seq[string]
  for key, item in node.meta:
    metaNames.add key
    compileQuasiTemplate(c, item, depth)
  var propNames: seq[string]
  for key, item in node.props:
    propNames.add key
    compileQuasiTemplate(c, item, depth)
  var bodySplices: seq[bool]
  var hasBodySplice = false
  for item in node.body:
    let splice = item.quasiSpliceExpr(depth)
    if splice.splice:
      compileExpr(c, splice.expr)
      bodySplices.add true
      hasBodySplice = true
    else:
      compileQuasiTemplate(c, item, depth)
      bodySplices.add false
  let idx = c.chunk.addNodeBuild(NodeBuildProto(metaNames: metaNames,
                                                propNames: propNames,
                                                bodyCount: node.body.len,
                                                bodySplices:
                                                  (if hasBodySplice: bodySplices else: @[]),
                                                immutable: node.nodeImmutable))
  discard c.emit(opMakeNode, idx)

proc compileQuasiNode(c: var Compiler, node: Value, depth: int) =
  if node.head.isSymbol("unquote"):
    if node.body.len != 1:
      raise newException(GeneError, "unquote requires one expression")
    if depth == 1:
      compileExpr(c, node.body[0])
      return
    compileQuasiNodeParts(c, node, depth - 1)
  elif node.head.isSymbol("quasiquote"):
    if node.body.len != 1:
      raise newException(GeneError, "quasiquote expects one template")
    compileQuasiNodeParts(c, node, depth + 1)
  else:
    compileQuasiNodeParts(c, node, depth)

proc compileQuasiTemplate(c: var Compiler, value: Value, depth: int) =
  case value.kind
  of vkNode:
    compileQuasiNode(c, value, depth)
  of vkList:
    compileQuasiList(c, value, depth)
  of vkMap:
    compileQuasiMap(c, value, depth)
  else:
    c.emitConst value

proc compileQuasiquote(c: var Compiler, node: Value) =
  if node.body.len != 1:
    raise newException(GeneError, "quasiquote expects one template")
  compileQuasiTemplate(c, node.body[0], 1)

proc selectorLiteral(parts: openArray[Value],
                     props: OrderedTable[string, Value]): Value =
  var body = newSeq[Value](parts.len)
  for i, part in parts:
    body[i] = part
  newNode(newSym("select"), props = props, body = body)

proc isUnquoteSegment(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("unquote")

proc compileSelector(c: var Compiler, node: Value) =
  let parts = node.body
  var dynamic = false
  for part in parts:
    if part.isUnquoteSegment:
      dynamic = true
      break
  if not dynamic and node.props.len == 0:
    c.emitConst selectorLiteral(parts, node.props)
    return

  if node.props.len == 0:
    for part in parts:
      if part.isUnquoteSegment:
        if part.body.len != 1:
          raise newException(GeneError, "selector unquote requires one expression")
        compileExpr(c, part.body[0])
      else:
        c.emitConst part
    discard c.emit(opMakeSelector, parts.len)
    return

  c.emitConst newSym("select")
  var propNames: seq[string]
  for key, value in node.props:
    propNames.add key
    compileExpr(c, value)
  for part in parts:
    if part.isUnquoteSegment:
      if part.body.len != 1:
        raise newException(GeneError, "selector unquote requires one expression")
      compileExpr(c, part.body[0])
    else:
      c.emitConst part
  let idx = c.chunk.addNodeBuild(NodeBuildProto(propNames: propNames,
                                                bodyCount: parts.len))
  discard c.emit(opMakeNode, idx)

proc compileSelectorParts(c: var Compiler, parts: openArray[Value]) =
  var body = newSeq[Value](parts.len)
  for i, part in parts:
    body[i] = part
  compileSelector(c, newNode(newSym("select"), body = body))

proc isPathSendSegment(part: Value): bool =
  part.kind == vkSymbol and part.symVal.len > 1 and part.symVal.startsWith("~")

proc pathSendName(part: Value): string =
  part.symVal[1 .. ^1]

proc compilePath(c: var Compiler, node: Value) =
  let parts = node.body
  if parts.len == 0:
    c.emitConst VOID
    return
  if parts.len == 1:
    compileExpr(c, parts[0])
    return
  compileExpr(c, parts[0])
  var i = 1
  while i < parts.len:
    if parts[i].isPathSendSegment:
      discard c.emit(opResolveMessage, name = parts[i].pathSendName)
      c.chunk.callSites[c.emitPlainCall(1)] = node
      inc i
    else:
      let start = i
      while i < parts.len and not parts[i].isPathSendSegment:
        inc i
      compileSelectorParts(c, parts.toOpenArray(start, i - 1))
      discard c.emit(opApplySelectorTop)

proc valueSpreadExpr(value: Value): tuple[spread: bool, expr: Value] =
  case value.kind
  of vkSymbol:
    if value.symVal.len > 3 and value.symVal.endsWith("..."):
      return (true, desugarPath(value.symVal[0..^4]))
  of vkNode:
    if value.head.isSymbol("..."):
      if value.props.len != 0 or value.meta.len != 0 or value.body.len != 1:
        raise newException(GeneError, "spread requires one expression")
      return (true, value.body[0])
  else:
    discard
  (false, NIL)

proc isStandaloneSpreadMarker(value: Value): bool =
  value.kind == vkSymbol and value.symVal == "..."

proc compileEvaluatedListItem(c: var Compiler, item: Value) =
  if item.kind == vkSymbol and item.symVal != "/" and '/' in item.symVal:
    compileExpr(c, desugarPath(item.symVal))
  else:
    compileExpr(c, item)

proc compileSpreadPart(c: var Compiler, item: Value, forList: bool) =
  if forList:
    compileEvaluatedListItem(c, item)
  else:
    compileExpr(c, item)

proc compileSpreadValues(c: var Compiler, values: openArray[Value], start: int,
                         forList: bool, splices: var seq[bool],
                         hasSplice: var bool) =
  var i = start
  while i < values.len:
    let item = values[i]
    if item.isStandaloneSpreadMarker:
      raise newException(GeneError, "spread marker requires a preceding value")
    if i + 1 < values.len and values[i + 1].isStandaloneSpreadMarker:
      compileSpreadPart(c, item, forList)
      splices.add true
      hasSplice = true
      i += 2
      continue
    let spread = item.valueSpreadExpr
    if spread.spread:
      compileExpr(c, spread.expr)
      splices.add true
      hasSplice = true
    else:
      compileSpreadPart(c, item, forList)
      splices.add false
    inc i

proc hasValueSpread(values: openArray[Value]): bool =
  var i = 0
  while i < values.len:
    if values[i].isStandaloneSpreadMarker:
      return true
    if i + 1 < values.len and values[i + 1].isStandaloneSpreadMarker:
      return true
    if values[i].valueSpreadExpr.spread:
      return true
    inc i

proc compileListValue(c: var Compiler, value: Value) =
  var splices: seq[bool]
  var hasSplice = false
  compileSpreadValues(c, value.listItems, 0, forList = true, splices, hasSplice)
  if hasSplice:
    let idx = c.chunk.addListBuild(ListBuildProto(splices: splices,
                                                  immutable: value.listImmutable))
    discard c.emit(opMakeListSplice, idx)
  else:
    discard c.emit(opMakeList, value.listItems.len, flag = value.listImmutable)

proc compileCall(c: var Compiler, node: Value)

proc compileSend(c: var Compiler, node: Value, receiver: Value,
                 sendName: string, argsStart: int) =
  ## Message send (docs/core.md §9.1): the name after `~` resolves
  ## receiver-first at runtime, falling back to the lexical binding. Stack
  ## shape matches ordinary calls: [callee, named..., receiver, args...].
  var names: seq[string]
  for k, value in node.props:
    names.add k
    compileExpr(c, value)
  compileExpr(c, receiver)
  discard c.emit(opResolveMessage, names.len, name = sendName)
  var splices = @[false]
  var hasSplice = false
  compileSpreadValues(c, node.body, argsStart, forList = false, splices,
                      hasSplice)
  if hasSplice:
    let idx = c.chunk.addListBuild(ListBuildProto(splices: splices))
    c.chunk.callSites[c.emit(opCallSplice, idx, names = names)] = node
  else:
    let argCount = node.body.len - argsStart + 1
    let callIndex =
      if names.len == 0:
        c.emitPlainCall(argCount)
      else:
        c.emit(opCall, argCount, names = names)
    c.chunk.callSites[callIndex] = node

proc compileCall(c: var Compiler, node: Value) =
  if node.body.len > 1 and node.body[0].kind == vkSymbol and
      node.body[0].symVal == "~":
    # (x ~ f a) — infix message send / flipped call (docs/core.md §9.1).
    if node.body[1].kind == vkSymbol and
        not node.props.hasKey("protocol") and
        not node.props.hasKey("receiver") and
        not node.props.hasKey("types"):
      compileSend(c, node, node.head, node.body[1].symVal, 2)
      return
    # Qualified or expression callees keep flipped-call semantics:
    # (x ~ X/f a) => (X/f x a). Direct-call metadata also stays on this path.
    var args = newSeqOfCap[Value](node.body.len - 1)
    args.add node.head
    for i in 2 ..< node.body.len:
      args.add node.body[i]
    compileCall(c, newNode(node.body[1], node.props, args, node.meta))
    return
  if node.props.len == 0 and node.head.kind == vkSymbol and node.body.len == 0:
    let direct = c.lexicalCallSlot0(node.head.symVal)
    if direct.slot >= 0:
      c.chunk.callSites[c.emit(direct.op, direct.slot,
                               name = node.head.symVal,
                               depth = direct.depth)] = node
      return
    if not c.hasLexicalBinding(node.head.symVal):
      c.chunk.callSites[c.emit(opCallName0, name = node.head.symVal)] = node
      return
  if node.props.len == 0 and node.head.kind == vkSymbol and node.body.len == 2:
    let fastKind = nativeFastLoadKind(node.head.symVal)
    if fastKind != nfkNone and not c.hasLexicalBinding(node.head.symVal):
      compileExpr(c, node.body[0])
      if node.body[1].isSelfEvaluatingFastConst:
        let constIndex = c.chunk.addConst(node.body[1])
        # Fast-const opcodes use flag to mean the RHS constant is a small Int.
        let constIsSmallInt = node.body[1].isSmallInt
        if c.exprKnownBareInt(node.body[0]) and node.body[1].kind == vkInt:
          discard c.emit(intFastConstOp(fastKind), ord(fastKind), name = node.head.symVal,
                         depth = constIndex, flag = constIsSmallInt)
        else:
          discard c.emit(opNativeFastConst, ord(fastKind), name = node.head.symVal,
                         depth = constIndex, flag = constIsSmallInt)
      else:
        compileExpr(c, node.body[1])
        if c.exprKnownBareInt(node.body[0]) and c.exprKnownBareInt(node.body[1]):
          discard c.emit(intFast2Op(fastKind), ord(fastKind), name = node.head.symVal)
        else:
          discard c.emit(opNativeFast2, ord(fastKind), name = node.head.symVal)
      return
  if node.props.len == 0 and node.head.kind == vkSymbol and node.body.len == 1:
    let direct = c.lexicalCallSlot(node.head.symVal)
    if direct.slot >= 0:
      let argKnownBareInt = c.exprKnownBareInt(node.body[0])
      compileExpr(c, node.body[0])
      c.chunk.callSites[c.emit(direct.op, direct.slot, name = node.head.symVal,
                               depth = direct.depth,
                               flag = argKnownBareInt)] = node
      return
    if not c.hasLexicalBinding(node.head.symVal):
      compileExpr(c, node.body[0])
      c.chunk.callSites[c.emit(opCallName1, name = node.head.symVal)] = node
      return
  if node.props.len == 0 and node.head.kind == vkSymbol and node.body.len > 1 and
      not node.body.hasValueSpread:
    let slot = c.localSlot(node.head.symVal)
    if slot >= 0:
      var argsKnownBareInt = true
      for arg in node.body:
        argsKnownBareInt = argsKnownBareInt and c.exprKnownBareInt(arg)
        compileExpr(c, arg)
      c.chunk.callSites[c.emit(opCallLocalN, slot, name = node.head.symVal,
                               depth = node.body.len,
                               flag = argsKnownBareInt)] = node
      return
  if node.props.hasKey("types") and node.head.kind == vkSymbol:
    let types = node.props["types"]
    if types.kind != vkList:
      raise newException(GeneError, "call ^types must be a list")
    discard c.chunk.addMonomorphization(MonomorphizationSpec(
      functionName: node.head.symVal,
      typeArgs: types.listItems))
  let hasProtocol = node.props.hasKey("protocol")
  let hasReceiver = node.props.hasKey("receiver")
  if hasProtocol or hasReceiver:
    if not (hasProtocol and hasReceiver):
      raise newException(GeneError,
        "direct protocol call metadata requires ^protocol and ^receiver")
    if node.head.kind != vkSymbol:
      raise newException(GeneError,
        "direct protocol call metadata requires a message name")
    discard c.chunk.addDirectProtocolCall(DirectProtocolCallSpec(
      messageName: node.head.symVal,
      protocolExpr: node.props["protocol"],
      receiverExpr: node.props["receiver"]))
    # Message names are not lexical bindings (docs/core.md §1); reach the
    # message through the protocol value: (path <protocol> <name>).
    compileExpr(c, newNode(newSym("path"),
                           body = @[node.props["protocol"], node.head]))
  else:
    compileExpr(c, node.head)
  var names: seq[string]
  for k, value in node.props:
    if k in ["types", "protocol", "receiver"]:
      continue
    names.add k
    compileExpr(c, value)
  var splices: seq[bool]
  var hasSplice = false
  compileSpreadValues(c, node.body, 0, forList = false, splices, hasSplice)
  if hasSplice:
    let idx = c.chunk.addListBuild(ListBuildProto(splices: splices))
    c.chunk.callSites[c.emit(opCallSplice, idx, names = names)] = node
  else:
    let callIndex =
      if names.len == 0:
        c.emitPlainCall(node.body.len)
      else:
        c.emit(opCall, node.body.len, names = names)
    c.chunk.callSites[callIndex] = node

proc compileLeadingSelfCall(c: var Compiler, node: Value) =
  # (~ f a) => (self ~ f a): message send to lexical self (docs/core.md §9.1).
  if node.body.len == 0:
    raise newException(GeneError, "`~` requires a callable")
  if not c.selfAvailable:
    raise newException(GeneError, "leading `~` requires lexical self")
  if node.body[0].kind == vkSymbol and
      not node.props.hasKey("protocol") and
      not node.props.hasKey("receiver") and
      not node.props.hasKey("types"):
    compileSend(c, node, newSym("self"), node.body[0].symVal, 1)
    return
  let hasProtocol = node.props.hasKey("protocol")
  let hasReceiver = node.props.hasKey("receiver")
  if hasProtocol or hasReceiver:
    if not (hasProtocol and hasReceiver):
      raise newException(GeneError,
        "direct protocol call metadata requires ^protocol and ^receiver")
    if node.body[0].kind != vkSymbol:
      raise newException(GeneError,
        "direct protocol call metadata requires a message name")
    discard c.chunk.addDirectProtocolCall(DirectProtocolCallSpec(
      messageName: node.body[0].symVal,
      protocolExpr: node.props["protocol"],
      receiverExpr: node.props["receiver"]))
    # Message names are not lexical bindings (docs/core.md §1); reach the
    # message through the protocol value: (path <protocol> <name>).
    compileExpr(c, newNode(newSym("path"),
                           body = @[node.props["protocol"], node.body[0]]))
  else:
    compileExpr(c, node.body[0])
  var names: seq[string]
  for k, value in node.props:
    if k in ["types", "protocol", "receiver"]:
      continue
    names.add k
    compileExpr(c, value)
  var splices = @[false]
  var hasSplice = false
  compileExpr(c, newSym("self"))
  compileSpreadValues(c, node.body, 1, forList = false, splices, hasSplice)
  if hasSplice:
    let idx = c.chunk.addListBuild(ListBuildProto(splices: splices))
    c.chunk.callSites[c.emit(opCallSplice, idx, names = names)] = node
  else:
    let callIndex =
      if names.len == 0:
        c.emitPlainCall(node.body.len)
      else:
        c.emit(opCall, node.body.len, names = names)
    c.chunk.callSites[callIndex] = node

proc compileMatch(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0:
    raise newException(GeneError, "match requires a value")
  compileExpr(c, body[0])
  let mp = MatchProto(clauses: @[], elseBody: nil)
  for i in 1 ..< body.len:
    let clause = body[i]
    if clause.kind != vkNode or clause.head.kind != vkSymbol:
      raise newException(GeneError, "match clauses must be (when ...) or (else ...)")
    case clause.head.symVal
    of "when":
      if clause.body.len == 0:
        raise newException(GeneError, "when requires a pattern")
      var branchBody: seq[Value]
      for j in 1 ..< clause.body.len:
        branchBody.add clause.body[j]
      mp.clauses.add MatchClause(pattern: clause.body[0],
                                  body: c.compileSubBody(branchBody,
                                                         clause.body[0],
                                                         scoped = true))
    of "else":
      mp.elseBody = c.compileSubBody(clause.body, scoped = true)
      break
    else:
      raise newException(GeneError, "unknown match clause: " & clause.head.symVal)
  discard c.emit(opMatch, c.chunk.addMatch(mp))

proc compileWhile(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0:
    raise newException(GeneError, "while requires a condition")
  let start = c.chunk.instructions.len
  c.loopStack.add LoopCompileContext(isInline: true, continueTarget: start)
  inc c.loopDepth
  compileExpr(c, body[0])
  let exitJump = c.emitJump(opJumpIfFalse)
  compileBodyFrom(c, body, 1)
  discard c.emit(opPop)                     # discard each iteration's body value
  discard c.emit(opJump, start)             # loop back to the condition
  c.patchJump(exitJump)
  let loop = c.loopStack.pop()
  for jump in loop.breakJumps:
    c.patchJump(jump)
  dec c.loopDepth
  c.emitConst NIL                           # while evaluates to nil

proc compileLoop(c: var Compiler, node: Value) =
  if node.props.len != 0:
    raise newException(GeneError, "loop does not accept props")
  let body = node.body
  if body.len == 0:
    raise newException(GeneError, "loop requires a body")
  let start = c.chunk.instructions.len
  c.loopStack.add LoopCompileContext(isInline: true, continueTarget: start)
  inc c.loopDepth
  compileBodyFrom(c, body, 0)
  discard c.emit(opPop)                     # discard each iteration's body value
  discard c.emit(opJump, start)
  let loop = c.loopStack.pop()
  for jump in loop.breakJumps:
    c.patchJump(jump)
  dec c.loopDepth
  c.emitConst NIL

proc compileRepeat(c: var Compiler, node: Value) =
  let body = node.body
  if node.props.len != 0:
    raise newException(GeneError, "repeat does not accept props")
  if body.len == 0:
    raise newException(GeneError, "repeat requires a count")

  if body.len >= 2 and body[1].isSymbol("in"):
    if body.len < 3:
      raise newException(GeneError, "repeat requires an index, in, and a count")
    if body[0].kind != vkSymbol:
      raise newException(GeneError, "repeat index must be a local name")
    let indexName = body[0].symVal
    let limitName = c.nextTemp("repeat_limit")
    compileExpr(c, body[2])
    c.emitDefineBinding(limitName)
    c.emitConst newInt(0)
    c.emitDefineBinding(indexName)

    let start = c.chunk.instructions.len
    c.emitLoadBinding(indexName)
    c.emitLoadBinding(limitName)
    discard c.emit(opNativeFast2, ord(nfkLt), name = "<")
    let exitJump = c.emitJump(opJumpIfFalse)

    c.loopStack.add LoopCompileContext(isInline: true, continueTarget: -1)
    inc c.loopDepth
    compileBodyFrom(c, body, 3)
    discard c.emit(opPop)                   # discard each iteration's body value
    c.loopStack[^1].continueTarget = c.chunk.instructions.len
    for jump in c.loopStack[^1].continueJumps:
      c.patchJump(jump)
    c.emitLoadBinding(indexName)
    c.emitConst newInt(1)
    discard c.emit(opNativeFast2, ord(nfkAdd), name = "+")
    c.emitSetBinding(indexName)
    discard c.emit(opPop)                   # discard set result
    discard c.emit(opJump, start)
    c.patchJump(exitJump)
    let loop = c.loopStack.pop()
    for jump in loop.breakJumps:
      c.patchJump(jump)
    dec c.loopDepth
    c.emitConst NIL
    return

  let remainingName = c.nextTemp("repeat_remaining")
  compileExpr(c, body[0])
  c.emitDefineBinding(remainingName)

  let start = c.chunk.instructions.len
  c.emitLoadBinding(remainingName)
  c.emitConst newInt(0)
  discard c.emit(opNativeFast2, ord(nfkGt), name = ">")
  let exitJump = c.emitJump(opJumpIfFalse)

  c.loopStack.add LoopCompileContext(isInline: true, continueTarget: -1)
  inc c.loopDepth
  compileBodyFrom(c, body, 1)
  discard c.emit(opPop)                     # discard each iteration's body value
  c.loopStack[^1].continueTarget = c.chunk.instructions.len
  for jump in c.loopStack[^1].continueJumps:
    c.patchJump(jump)
  c.emitLoadBinding(remainingName)
  c.emitConst newInt(1)
  discard c.emit(opNativeFast2, ord(nfkSub), name = "-")
  c.emitSetBinding(remainingName)
  discard c.emit(opPop)                     # discard set result
  discard c.emit(opJump, start)
  c.patchJump(exitJump)
  let loop = c.loopStack.pop()
  for jump in loop.breakJumps:
    c.patchJump(jump)
  dec c.loopDepth
  c.emitConst NIL

proc compileFor(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 3:
    raise newException(GeneError, "for requires a pattern, in, and an iterable")
  if body[1].kind != vkSymbol or body[1].symVal != "in":
    raise newException(GeneError, "for requires 'in' after the pattern")
  if c.allowYield and body.bodyContainsYield(3):
    let iterName = c.nextTemp("iter")
    compileExpr(c, body[2])                   # iterable on the stack
    discard c.emit(opMakeIterator)
    c.emitDefineBinding(iterName)

    let start = c.chunk.instructions.len
    c.loopStack.add LoopCompileContext(isInline: true, continueTarget: start)
    inc c.loopDepth
    c.emitLoadBinding(iterName)
    discard c.emit(opIteratorHasNext)
    let exitJump = c.emitJump(opJumpIfFalse)

    c.emitLoadBinding(iterName)
    discard c.emit(opIteratorNext)
    discard c.emit(opMatchBindReplace, c.chunk.addConst(body[0]))
    discard c.emit(opPop)                     # discard the matched item
    compileBodyFrom(c, body, 3)
    discard c.emit(opPop)                     # discard each iteration's body value
    discard c.emit(opJump, start)
    c.patchJump(exitJump)
    let loop = c.loopStack.pop()
    for jump in loop.breakJumps:
      c.patchJump(jump)
    dec c.loopDepth
    c.emitLoadBinding(iterName)
    discard c.emit(opIteratorClose)
    c.emitConst NIL
    return

  compileExpr(c, body[2])                   # iterable on the stack
  var bodyCompiler = c.childCompiler()
  bodyCompiler.loopDepth = c.loopDepth + 1
  bodyCompiler.enableLocalSlots()
  bodyCompiler.parentSlots = c.parentFrames()
  for name in patternBindingNames(body[0]):
    discard bodyCompiler.reserveLocal(name)
    if name == "self":
      bodyCompiler.selfAvailable = true
  if patternBindsSelf(body[0]):
    bodyCompiler.selfAvailable = true
  compileBodyFrom(bodyCompiler, body, 3)
  discard bodyCompiler.emit(opReturn)
  bodyCompiler.chunk.localNames = bodyCompiler.localNames
  let fp = ForProto(pattern: body[0], body: bodyCompiler.chunk)
  discard c.emit(opForEach, c.chunk.addForLoop(fp))

proc compileYield(c: var Compiler, node: Value) =
  if not c.allowYield:
    raise newException(GeneError, "yield is only valid inside fn")
  if node.props.len != 0 or node.body.len != 1:
    raise newException(GeneError, "yield expects one value")
  compileExpr(c, node.body[0])
  discard c.emit(opYield)
  c.sawYield = true

proc compileTry(c: var Compiler, node: Value) =
  ## (try body... catch pat recovery... [catch ...] [ensure cleanup...]) — the
  ## `catch`/`ensure` markers are bare symbols in the flat body.
  let body = node.body
  var i = 0
  var tryForms: seq[Value]
  while i < body.len and not (body[i].isSymbol("catch") or body[i].isSymbol("ensure")):
    tryForms.add body[i]
    inc i
  let tp = TryProto(body: c.compileSubBody(tryForms))
  while i < body.len and body[i].isSymbol("catch"):
    inc i
    if i >= body.len:
      raise newException(GeneError, "catch requires a pattern")
    let pattern = body[i]
    inc i
    var recovery: seq[Value]
    while i < body.len and not (body[i].isSymbol("catch") or body[i].isSymbol("ensure")):
      recovery.add body[i]
      inc i
    tp.catches.add CatchClause(pattern: pattern,
                               body: c.compileSubBody(recovery, pattern,
                                                      scoped = true))
  if i < body.len and body[i].isSymbol("ensure"):
    inc i
    var ensureForms: seq[Value]
    while i < body.len:
      ensureForms.add body[i]
      inc i
    tp.ensureBody = c.compileSubBody(ensureForms)
  discard c.emit(opTry, c.chunk.addTry(tp))

proc compileTaskScope(c: var Compiler, node: Value) =
  if node.props.len != 0:
    raise newException(GeneError, "scope does not accept named arguments")
  let body = c.compileSubBody(node.body, scoped = true)
  discard c.emit(opTaskScope, c.chunk.addSubchunk(body))

proc compileSupervisor(c: var Compiler, node: Value) =
  for key in node.props.keys:
    if key notin ["strategy", "events", "dead-letter"]:
      raise newException(GeneError,
        "supervisor got unexpected named argument: " & key)
  if not node.props.hasKey("strategy"):
    raise newException(GeneError, "supervisor requires ^strategy")
  let strategyExpr = node.props["strategy"]
  if strategyExpr.kind != vkSymbol:
    raise newException(GeneError, "supervisor ^strategy must be a name")
  let strategy = strategyExpr.symVal
  if strategy notin ["restart", "stop", "escalate"]:
    raise newException(GeneError,
      "unsupported supervisor strategy: " & strategy)
  let hasEvents = node.props.hasKey("events")
  if hasEvents:
    compileExpr(c, node.props["events"])
  let hasDeadLetter = node.props.hasKey("dead-letter")
  if hasDeadLetter:
    compileExpr(c, node.props["dead-letter"])
  var sinkNames: seq[string]
  if hasEvents:
    sinkNames.add "events"
  if hasDeadLetter:
    sinkNames.add "dead-letter"
  let body = c.compileSubBody(node.body, scoped = true)
  discard c.emit(opSupervisor, c.chunk.addSubchunk(body), name = strategy,
                 names = sinkNames)

proc compileSpawn(c: var Compiler, node: Value) =
  if node.props.len != 0 or node.body.len != 1:
    raise newException(GeneError, "spawn expects one expression")
  let body = c.compileSubBody(node.body, scoped = true)
  discard c.emit(opSpawn, c.chunk.addSubchunk(body),
                 flag = not body.chunkMutatesOuterScope() and
                   not body.chunkContainsSpawn())

proc compileAwait(c: var Compiler, node: Value) =
  if node.props.len != 0 or node.body.len != 1:
    raise newException(GeneError, "await expects one Task")
  compileExpr(c, node.body[0])
  discard c.emit(opAwait)

proc compileFail(c: var Compiler, node: Value) =
  if node.props.len != 0 or node.body.len != 1:
    raise newException(GeneError, "fail expects one Error value")
  compileExpr(c, node.body[0])
  discard c.emit(opFail)

proc compilePanic(c: var Compiler, node: Value) =
  if node.props.len != 0 or node.body.len > 1:
    raise newException(GeneError, "panic expects zero or one value")
  if node.body.len == 0:
    c.emitConst newStr("panic")
  else:
    compileExpr(c, node.body[0])
  discard c.emit(opPanic)

proc deriveProtocolExpr(request: Value): Value =
  if request.kind == vkNode:
    request.head
  else:
    request

proc parseTypeBodySchema(schema: Value): seq[TypeBodyField] =
  if schema.kind != vkList:
    raise newException(GeneError, "type ^body must be a list")
  var sawRest = false
  for item in schema.listItems:
    if item.isSymbol(","):
      continue
    if sawRest:
      raise newException(GeneError,
        "type ^body rest field must be the final body field")
    if item.kind == vkSymbol and item.symVal.endsWith("..."):
      let name = item.symVal[0 .. ^4]
      if name.len == 0:
        raise newException(GeneError, "type ^body rest field requires a type")
      result.add TypeBodyField(rest: true, typeExpr: newSym(name))
      sawRest = true
    else:
      result.add TypeBodyField(typeExpr: item)

proc rejectUnknownTypeProps(node: Value) =
  for key in node.props.keys:
    if key in ["props", "body", "impl", "derive", "is"]:
      continue
    if key in ["sealed", "repr"]:
      raise newException(GeneError,
        "type ^" & key & " is reserved for future native layout optimization")
    raise newException(GeneError,
      "type got unexpected named argument: " & key)

proc messageNameParts(node: Value): tuple[protocolPath: seq[string], name: string] =
  ## A message name is a simple symbol, or a qualified path in impl bodies for
  ## disambiguating same-named closure messages (docs/core.md §3.6.1):
  ## `Protocol/name`, or `ns/Protocol/name` for namespace-qualified owners.
  if node.kind != vkNode or not node.head.isSymbol("message"):
    raise newException(GeneError, "protocol/impl body must contain message declarations")
  if node.body.len < 2 or node.body[1].kind != vkList:
    raise newException(GeneError, "message requires a name and parameter vector")
  let nameForm = node.body[0]
  if nameForm.kind == vkSymbol:
    return (@[], nameForm.symVal)
  if nameForm.kind == vkNode and nameForm.head.isSymbol("path") and
      nameForm.body.len >= 2:
    var segments: seq[string]
    for segment in nameForm.body:
      if segment.kind != vkSymbol:
        raise newException(GeneError,
          "message requires a name and parameter vector")
      segments.add segment.symVal
    return (segments[0 ..^ 2], segments[^1])
  raise newException(GeneError, "message requires a name and parameter vector")

proc messageName(node: Value): string =
  let parts = messageNameParts(node)
  if parts.protocolPath.len > 0:
    raise newException(GeneError,
      "qualified message names are only valid in impl bodies: " &
      parts.protocolPath.join("/") & "/" & parts.name)
  parts.name

proc implMessageProto(c: var Compiler, node: Value): ImplMessageProto =
  let parts = messageNameParts(node)
  let displayName =
    if parts.protocolPath.len > 0: parts.protocolPath.join("/") & "/" & parts.name
    else: parts.name
  let errorRow = compileErrorRow(c, node)
  ImplMessageProto(name: parts.name,
                   protocolPath: parts.protocolPath,
                   fn: buildFunctionProto(c, displayName, node.body[1],
                                          node.body, 2,
                                          checksErrors = errorRow.checks,
                                          errorTypeCount = errorRow.count))

proc compileType(c: var Compiler, node: Value) =
  ## (type Name ^props {...} ^body [...] ^is Parent ^impl [P] ^derive [P]
  ##  (message name [self] ...) ...) —
  ## field annotations and protocol references are checked at runtime. Derive
  ## requests are passed to protocol-local derive forms after the type is created.
  ## Body items after the name are type-direct messages (docs/core.md §8).
  let body = node.body
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "type requires a name")
  rejectUnknownTypeProps(node)
  let name = body[0].symVal
  var messageNodes: seq[Value]
  var implNodes: seq[Value]
  for i in 1 ..< body.len:
    let item = body[i]
    if item.kind == vkNode and item.head.isSymbol("message"):
      messageNodes.add item
    elif item.kind == vkNode and item.head.isSymbol("impl"):
      implNodes.add item
    else:
      raise newException(GeneError,
        "type body items must be message or impl declarations")
  var messages: seq[ImplMessageProto]
  var seenMessages = initTable[string, bool]()
  for item in messageNodes:
    rejectReservedEffects(item)
    let mp = implMessageProto(c, item)
    if mp.protocolPath.len > 0:
      raise newException(GeneError,
        "type-direct message names must be simple: " &
        mp.protocolPath.join("/") & "/" & mp.name)
    if seenMessages.hasKey(mp.name):
      raise newException(GeneError, "duplicate type message: " & mp.name)
    seenMessages[mp.name] = true
    messages.add mp
  # Inline impls (docs/core.md §8): (impl P (message ...) ...) with the
  # receiver implied — the enclosing type. Each impl emits its message error
  # rows and then its protocol expression, in declaration order.
  var inlineImpls: seq[InlineImplProto]
  for item in implNodes:
    if item.body.len == 0:
      raise newException(GeneError, "inline impl requires a protocol")
    var implMessages: seq[ImplMessageProto]
    var seenImplMessages = initTable[string, bool]()
    for j in 1 ..< item.body.len:
      let msgNode = item.body[j]
      if msgNode.kind != vkNode or not msgNode.head.isSymbol("message"):
        raise newException(GeneError,
          "inline impl body items must be message declarations " &
          "(the enclosing type is the receiver)")
      let mp = implMessageProto(c, msgNode)
      let key = mp.protocolPath.join("/") & "/" & mp.name
      if seenImplMessages.hasKey(key):
        raise newException(GeneError, "duplicate impl message: " & mp.name)
      seenImplMessages[key] = true
      implMessages.add mp
    compileExpr(c, item.body[0])
    inlineImpls.add InlineImplProto(messages: implMessages)
  var fields: seq[TypeField]
  if node.props.hasKey("props"):
    let schema = node.props["props"]
    if schema.kind != vkMap:
      raise newException(GeneError, "type ^props must be a map")
    for key, _ in schema.mapEntries:
      if key.endsWith("?"):
        fields.add TypeField(name: key[0 .. ^2], optional: true,
                             typeExpr: schema.mapEntries[key])
      else:
        fields.add TypeField(name: key, optional: false,
                             typeExpr: schema.mapEntries[key])
  var bodyFields: seq[TypeBodyField]
  if node.props.hasKey("body"):
    bodyFields = parseTypeBodySchema(node.props["body"])
  var requiredImplCount = 0
  if node.props.hasKey("impl"):
    let required = node.props["impl"]
    if required.kind != vkList:
      raise newException(GeneError, "type ^impl must be a list")
    for protocolExpr in required.listItems:
      # List items keep glued slash paths as symbols (p/A); desugar like
      # ordinary evaluated list items so namespace-qualified protocols work.
      compileEvaluatedListItem(c, protocolExpr)
      inc requiredImplCount
  var deriveProtocolCount = 0
  var deriveRequests: seq[Value]
  if node.props.hasKey("derive"):
    let derived = node.props["derive"]
    if derived.kind != vkList:
      raise newException(GeneError, "type ^derive must be a list")
    for request in derived.listItems:
      let protocolExpr = deriveProtocolExpr(request)
      if protocolExpr.kind == vkNil or protocolExpr.kind == vkVoid:
        raise newException(GeneError, "type ^derive entries must name protocols")
      compileEvaluatedListItem(c, protocolExpr)
      deriveRequests.add request
      inc deriveProtocolCount
  if node.props.hasKey("is"):
    compileExpr(c, node.props["is"])         # parent type value
  else:
    c.emitConst NIL
  discard c.emit(opMakeType,
                 c.chunk.addType(TypeProto(name: name,
                                           fields: fields,
                                           bodyFields: bodyFields,
                                           requiredImplCount: requiredImplCount,
                                           deriveProtocolCount: deriveProtocolCount,
                                           deriveRequests: deriveRequests,
                                           messages: messages,
                                           inlineImpls: inlineImpls)))
  c.emitDefineBinding(name)

proc compileProtocol(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "protocol requires a name")
  let name = body[0].symVal
  var messageNames: seq[string]
  var seen = initTable[string, bool]()
  var deriveFn: FunctionProto
  for i in 1 ..< body.len:
    if body[i].kind == vkNode and body[i].head.isSymbol("derive"):
      if deriveFn != nil:
        raise newException(GeneError, "protocol has duplicate derive form")
      if body[i].body.len == 0 or body[i].body[0].kind != vkList:
        raise newException(GeneError, "derive requires a parameter vector")
      deriveFn = buildFunctionProto(c, name & "/derive", body[i].body[0],
                                    body[i].body, 1)
      continue
    let message = messageName(body[i])
    rejectReservedEffects(body[i])
    if seen.hasKey(message):
      raise newException(GeneError, "duplicate protocol message: " & message)
    seen[message] = true
    messageNames.add message
  var parentCount = 0
  if node.props.hasKey("inherit"):
    let parents = node.props["inherit"]
    if parents.kind != vkList:
      raise newException(GeneError, "protocol ^inherit must be a list")
    for parentExpr in parents.listItems:
      # List items keep glued slash paths as symbols (p/A); desugar like
      # ordinary evaluated list items so namespace-qualified parents work.
      compileEvaluatedListItem(c, parentExpr)
      inc parentCount
  # Message names are deliberately not bound in the enclosing scope
  # (docs/core.md §1, OQ-I): messages are reached via qualified access
  # (Protocol/name) and sends only.
  let idx = c.chunk.addProtocol(ProtocolProto(name: name,
                                              messageNames: messageNames,
                                              deriveFn: deriveFn,
                                              parentCount: parentCount))
  discard c.emit(opMakeProtocol, idx)
  c.emitDefineBinding(name)

proc compileImpl(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 2:
    raise newException(GeneError, "impl requires a protocol and receiver type")
  compileExpr(c, body[0])
  compileExpr(c, body[1])
  var messages: seq[ImplMessageProto]
  var seen = initTable[string, bool]()
  for i in 2 ..< body.len:
    let mp = implMessageProto(c, body[i])
    let key = mp.protocolPath.join("/") & "/" & mp.name
    if seen.hasKey(key):
      raise newException(GeneError, "duplicate impl message: " & mp.name)
    seen[key] = true
    messages.add mp
  let idx = c.chunk.addImpl(ImplProto(messages: messages))
  discard c.emit(opMakeImpl, idx)

proc compileNode(c: var Compiler, node: Value, allowModDecl: bool) =
  let h = node.head
  if h.isPath(["ffi", "library"]):
    compileFfiLibrary(c, node)
    return
  if h.isPath(["ffi", "fn"]):
    compileFfiFn(c, node)
    return
  if h.isPath(["ffi", "struct"]):
    compileFfiStruct(c, node)
    return
  if h.isPath(["ffi", "union"]):
    compileFfiUnion(c, node)
    return
  if h.isPath(["ffi", "callback"]):
    compileFfiSignature(c, node, fskCallback)
    return
  if h.isPath(["ffi", "signature"]):
    compileFfiSignature(c, node, fskDynamic)
    return
  if h.kind == vkSymbol:
    case h.symVal
    of "do":
      compileBody(c, node.body)
      return
    of "if":
      compileIf(c, node)
      return
    of "&&":
      compileShortCircuit(c, node, opJumpIfFalseOrPop, TRUE)
      return
    of "||":
      compileShortCircuit(c, node, opJumpIfTrueOrPop, NIL)
      return
    of "!":
      compileNot(c, node)
      return
    of "var":
      compileVar(c, node)
      return
    of "set":
      compileSet(c, node)
      return
    of "~":
      compileLeadingSelfCall(c, node)
      return
    of "fn":
      compileFn(c, node)
      return
    of "macro":
      compileMacro(c, node)
      return
    of "quote":
      c.emitConst(if node.body.len >= 1: node.body[0] else: NIL)
      return
    of "quasiquote":
      compileQuasiquote(c, node)
      return
    of "select":
      compileSelector(c, node)
      return
    of "path":
      compilePath(c, node)
      return
    of "ns":
      compileNs(c, node)
      return
    of "env":
      compileEnv(c, node)
      return
    of "eval":
      compileEval(c, node)
      return
    of "import":
      compileImport(c, node)
      return
    of "mod":
      compileMod(c, node, allowModDecl)
      return
    of "match":
      compileMatch(c, node)
      return
    of "while":
      compileWhile(c, node)
      return
    of "loop":
      compileLoop(c, node)
      return
    of "repeat":
      compileRepeat(c, node)
      return
    of "for":
      compileFor(c, node)
      return
    of "break":
      compileBreak(c, node)
      return
    of "continue":
      compileContinue(c, node)
      return
    of "yield":
      compileYield(c, node)
      return
    of "try":
      compileTry(c, node)
      return
    of "scope":
      compileTaskScope(c, node)
      return
    of "supervisor":
      compileSupervisor(c, node)
      return
    of "spawn":
      compileSpawn(c, node)
      return
    of "await":
      compileAwait(c, node)
      return
    of "fail":
      compileFail(c, node)
      return
    of "panic":
      compilePanic(c, node)
      return
    of "type":
      compileType(c, node)
      return
    of "protocol":
      compileProtocol(c, node)
      return
    of "impl":
      compileImpl(c, node)
      return
    of "derive":
      raise newException(GeneError,
        "derive is only valid inside a protocol declaration")
    else:
      if c.hasMacros and c.macros.hasKey(h.symVal):
        compileMacroCall(c, node, c.macros[h.symVal])
        return
  compileCall(c, node)

proc compileExpr(c: var Compiler, node: Value, allowModDecl = false) =
  let savedLoc = c.currentLoc
  let exprLoc = c.sourceLocFor(node)
  if exprLoc.hasSourceLoc:
    c.currentLoc = exprLoc
  defer:
    c.currentLoc = savedLoc
  case node.kind
  of vkSymbol:
    c.emitLoadBinding(node.symVal)
  of vkNode:
    compileNode(c, node, allowModDecl)
  of vkList:
    compileListValue(c, node)
  of vkMap:
    var keys: seq[string]
    for k, value in node.mapEntries:
      keys.add k
      compileExpr(c, value)
    discard c.emit(opMakeMap, keys.len, names = keys, flag = node.mapImmutable)
  else:
    c.emitConst node

proc compileFormsInto(c: var Compiler, forms: openArray[Value],
                      useLocalSlots: bool): Chunk =
  if useLocalSlots:
    c.enableLocalSlots()
  if forms.len == 0:
    c.emitConst NIL
  else:
    for i in 0 ..< forms.len:
      let savedLoc = c.currentLoc
      if i < c.formLocs.len and c.formLocs[i].hasSourceLoc:
        c.currentLoc = c.formLocs[i]
      try:
        compileExpr(c, forms[i], allowModDecl = true)
        if i < forms.high:
          discard c.emit(opPop)
      except GeneError as e:
        if not e.loc.hasSourceLoc:
          e.loc = c.currentLoc
        raise
      c.currentLoc = savedLoc
  discard c.emit(opReturn)
  if useLocalSlots:
    c.chunk.localNames = c.localNames
    c.chunk.mirrorSlots = true
  c.chunk.rewriteSelfRecursiveCalls()
  c.chunk

proc compileForms*(forms: openArray[Value],
                   allowAmbientImports = true,
                   useLocalSlots = true): Chunk =
  var c = Compiler(chunk: newChunk(), allowAmbientImports: allowAmbientImports,
                   ffiLibraryNames: initTable[string, bool](),
                   sourceLocs: initTable[uint64, SourceLoc]())
  compileFormsInto(c, forms, useLocalSlots)

proc compileSourceUnit*(unit: SourceUnit,
                        allowAmbientImports = true,
                        useLocalSlots = true): Chunk =
  var c = Compiler(chunk: newChunk(unit.sourceName),
                   sourceName: unit.sourceName,
                   sourceLocs: unit.locs,
                   formLocs: unit.formLocs,
                   allowAmbientImports: allowAmbientImports,
                   ffiLibraryNames: initTable[string, bool]())
  compileFormsInto(c, unit.forms, useLocalSlots)

proc compileFormsWithMacros*(forms: openArray[Value],
    importedMacros: Table[string, Table[string, MacroDef]]):
    tuple[chunk: Chunk, macroExports: Table[string, MacroDef]] =
  ## Module-loader entry point (design §11/§15): compile a source unit with the
  ## macro exports of its `from "path"` dependencies available (keyed by the
  ## raw path string), and return this unit's own macro definitions — imported
  ## macros are usable but not re-exported.
  var c = Compiler(chunk: newChunk(), allowAmbientImports: true,
                   ffiLibraryNames: initTable[string, bool](),
                   sourceLocs: initTable[uint64, SourceLoc](),
                   importedMacroSets: importedMacros)
  result.chunk = compileFormsInto(c, forms, useLocalSlots = true)
  if c.hasMacros:
    for name, def in c.macros:
      if name notin c.importedMacroNames:
        result.macroExports[name] = def

proc compileFormsWithMacros*(unit: SourceUnit,
    importedMacros: Table[string, Table[string, MacroDef]]):
    tuple[chunk: Chunk, macroExports: Table[string, MacroDef]] =
  var c = Compiler(chunk: newChunk(unit.sourceName),
                   sourceName: unit.sourceName,
                   sourceLocs: unit.locs,
                   formLocs: unit.formLocs,
                   allowAmbientImports: true,
                   ffiLibraryNames: initTable[string, bool](),
                   importedMacroSets: importedMacros)
  result.chunk = compileFormsInto(c, unit.forms, useLocalSlots = true)
  if c.hasMacros:
    for name, def in c.macros:
      if name notin c.importedMacroNames:
        result.macroExports[name] = def

proc compileForm*(form: Value): Chunk =
  let forms = @[form]
  compileForms(forms)

proc compileEvalForm*(form: Value): Chunk =
  ## Eval code receives only explicit Env bindings/imports/module context. It
  ## must not use source-level imports to acquire ambient module-loader authority.
  let forms = @[form]
  compileForms(forms, allowAmbientImports = false)

proc compileEvalSource*(src: string, useLocalSlots = true,
                        sourceName = "<eval>"): Chunk =
  ## CLI/REPL eval receives source text but still uses eval authority rules.
  compileSourceUnit(readAllWithLocs(src, sourceName),
                    allowAmbientImports = false,
                    useLocalSlots = useLocalSlots)

proc compileSource*(src: string, sourceName = ""): Chunk =
  compileSourceUnit(readAllWithLocs(src, sourceName))
