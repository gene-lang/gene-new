## AST-to-GIR compiler for the MVP execution surface.

import std/[strutils, tables]
import ./[equality, gir, reader, types]

type
  Compiler = object
    chunk: Chunk
    selfAvailable: bool
    seenModDecl: bool
    allowYield: bool
    sawYield: bool
    gensym: int
    useLocalSlots: bool
    localSlots: Table[string, int]
    localNames: seq[string]
    parentSlots: seq[Table[string, int]]
    macros: Table[string, MacroDef]
    hasMacros: bool
    macroExpansionDepth: int
    allowAmbientImports: bool

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

  MacroDef = object
    params: seq[MacroParam]
    named: seq[MacroNamedParam]
    rest: string
    body: seq[Value]

const MaxMacroExpansionDepth = 100

proc emit(c: var Compiler, op: OpCode, intArg = 0, name = "",
          depth = 0,
          names: seq[string] = @[], flag = false): int =
  c.chunk.emit Instruction(op: op, intArg: intArg, depth: depth,
                           name: name, names: names, flag: flag)

proc callOpForArity(argCount: int): OpCode =
  case argCount
  of 0: opCall0
  of 1: opCall1
  of 2: opCall2
  else: opCall

proc emitPlainCall(c: var Compiler, argCount: int): int =
  let op = callOpForArity(argCount)
  c.emit(op, argCount)

proc enableLocalSlots(c: var Compiler) =
  c.useLocalSlots = true
  c.localSlots = initTable[string, int]()
  c.localNames = @[]

proc reserveLocal(c: var Compiler, name: string): int =
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

proc parentSlot(c: Compiler, name: string): tuple[depth: int, slot: int] =
  for i, slots in c.parentSlots:
    if slots.hasKey(name):
      return (i + 1, slots[name])
  (-1, -1)

proc parentFrames(c: Compiler): seq[Table[string, int]] =
  if c.useLocalSlots:
    result.add c.localSlots
  result.add c.parentSlots

proc nativeFastLoadKind(name: string): NativeFastKind =
  case name
  of "+": nfkAdd
  of "-": nfkSub
  of "*": nfkMul
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

proc emitLoadBinding(c: var Compiler, name: string) =
  let slot = c.localSlot(name)
  if slot >= 0:
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

proc emitJump(c: var Compiler, op: OpCode): int =
  c.emit(op, -1)

proc patchJump(c: var Compiler, at: int) =
  c.chunk.patchJump(at, c.chunk.instructions.len)

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
  Compiler(chunk: newChunk(), selfAvailable: c.selfAvailable,
           macros: c.macros, hasMacros: c.hasMacros,
           macroExpansionDepth: c.macroExpansionDepth,
           allowAmbientImports: c.allowAmbientImports)

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
    of opLoadOuterLocal, opSetOuterLocal, opDefineName, opDefineLocal,
       opSetModuleName, opMakeFn,
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
    let builtin = macroMatchesBuiltinType(expr.symVal, value)
    if builtin.known:
      return builtin.ok
    raise newException(GeneError, "unknown macro type annotation: " & expr.symVal)
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

proc detectNativeCompileOp(specs: ParamSpecs, body: openArray[Value],
                           bodyStart: int, returnType: Value,
                           typeParams: openArray[string],
                           checksErrors, sawYield: bool): NativeCompileOp =
  ## First native-compilation slice: direct two-Int arithmetic. The dynamic
  ## function entry still performs normal boundary checks before this op runs.
  if typeParams.len != 0 or checksErrors or sawYield:
    return ncoNone
  if specs.positional.len != 2 or specs.rest.len != 0 or specs.named.len != 0:
    return ncoNone
  if specs.hasOptionalPositional or body.len != bodyStart + 1:
    return ncoNone
  let typeName = returnType.nativeScalarType
  if typeName.len == 0:
    return ncoNone
  for t in specs.positionalTypes:
    if t.nativeScalarType != typeName:
      return ncoNone

  let expr = body[bodyStart]
  if expr.kind != vkNode or expr.props.len != 0 or expr.meta.len != 0 or
      expr.body.len != 2 or expr.head.kind != vkSymbol:
    return ncoNone
  if expr.body[0].kind != vkSymbol or expr.body[1].kind != vkSymbol:
    return ncoNone
  if expr.body[0].symVal != specs.positional[0] or
      expr.body[1].symVal != specs.positional[1]:
    return ncoNone

  nativeArithmeticOp(typeName, expr.head.symVal)

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
  var positionalSlots: seq[int]
  for name in specs.positional:
    positionalSlots.add fnCompiler.reserveLocal(name)
  var namedSlots: seq[int]
  for p in specs.named:
    namedSlots.add fnCompiler.reserveLocal(p.local)
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
  discard fnCompiler.emit(opReturn)
  fnCompiler.chunk.localNames = fnCompiler.localNames

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
  let nativeOp = specs.detectNativeCompileOp(body, start, returnType,
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
  FunctionProto(name: name, typeParams: typeParams, params: specs.positional,
                localNames: fnCompiler.localNames,
                positionalSlots: positionalSlots,
                namedSlots: namedSlots,
                restSlot: restSlot,
                requiredPositional: specs.requiredPositionalCount,
                simpleCall: simpleCall,
                needsCallScope: needsCallScope,
                poolCallScope: poolCallScope,
                paramTypes: specs.positionalTypes,
                hasParamTypes: hasParamTypes,
                paramDefaults: specs.positionalDefaults,
                restParam: specs.rest, namedParams: specs.named,
                hasNamedParamTypes: hasNamedParamTypes,
                returnType: returnType,
                hasReturnType: returnType.kind != vkNil,
                isGenerator: fnCompiler.sawYield,
                nativeOp: nativeOp,
                aotExpr: aotExpr,
                aotFrameKind: aotFrameKind,
                aotFrameCanSuspend: false,
                taskFrameKind: taskFrameKind,
                checksErrors: checksErrors,
                errorTypeCount: errorTypeCount,
                chunk: fnCompiler.chunk)

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
      c.emitDeclareType(body[0].symVal, body[2])
    if body[0].symVal == "self":
      c.selfAvailable = true
  else:
    discard c.emit(opMatchBind, c.chunk.addConst(body[0]))  # destructuring
    if patternBindsSelf(body[0]):
      c.selfAvailable = true

proc compileSet(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 2 or body[0].kind != vkSymbol:
    raise newException(GeneError, "set requires a name and a value")
  compileExpr(c, body[1])
  c.emitSetBinding(body[0].symVal)

proc compileFn(c: var Compiler, node: Value) =
  let body = node.body
  var idx = 0
  var name = ""
  var typeParams: seq[string]
  if body.len > 0 and (body[0].kind == vkSymbol or body[0].kind == vkNode):
    let nameSpec = functionNameAndTypeParams(body[0])
    name = nameSpec.name
    typeParams = nameSpec.typeParams
    idx = 1
  if idx >= body.len or body[idx].kind != vkList:
    raise newException(GeneError, "fn requires a parameter vector")

  if name.len > 0 and c.useLocalSlots:
    discard c.reserveLocal(name)
  let errorRow = compileErrorRow(c, node)
  let proto = buildFunctionProto(c, name, body[idx], body, idx + 1,
                                 typeParams = typeParams,
                                 checksErrors = errorRow.checks,
                                 errorTypeCount = errorRow.count)
  discard c.emit(opMakeFn, c.chunk.addFunction(proto))
  if name.len > 0:
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
    result.add FfiStructField(name: items[0].symVal, typeExpr: items[1],
                              offset: offset, hasOffset: hasOffset)

proc parseFfiStructFields(fields: Value): seq[FfiStructField] =
  parseFfiAggregateFields("ffi/struct", fields, allowOffsets = true)

proc parseFfiUnionFields(fields: Value): seq[FfiStructField] =
  parseFfiAggregateFields("ffi/union", fields, allowOffsets = false)

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
  let proto = FfiFnProto(name: name,
                         library: propLiteral(node, "library", "", "ffi/fn"),
                         symbol: symbol,
                         abi: propLiteral(node, "abi", "C", "ffi/fn"),
                         params: parseFfiParams(body[1]),
                         returnType: ret,
                         release: propLiteral(node, "release", "", "ffi/fn"))
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
  let proto = FfiStructProto(
    name: body[0].symVal,
    layout: propLiteral(node, "layout", "C", "ffi/struct"),
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
  let proto = FfiUnionProto(
    name: body[0].symVal,
    layout: propLiteral(node, "layout", "C", "ffi/union"),
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

proc compilePath(c: var Compiler, node: Value) =
  let parts = node.body
  if parts.len == 0:
    c.emitConst VOID
    return
  if parts.len == 1:
    compileExpr(c, parts[0])
    return
  compileSelectorParts(c, parts.toOpenArray(1, parts.high))
  compileExpr(c, parts[0])
  discard c.emitPlainCall(1)

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

proc compileCall(c: var Compiler, node: Value) =
  if node.props.len == 0 and node.head.kind == vkSymbol and node.body.len == 0:
    if not c.hasLexicalBinding(node.head.symVal):
      c.chunk.callSites[c.emit(opCallName0, name = node.head.symVal)] = node
      return
  if node.props.len == 0 and node.head.kind == vkSymbol and node.body.len == 2:
    let fastKind = nativeFastLoadKind(node.head.symVal)
    if fastKind != nfkNone and not c.hasLexicalBinding(node.head.symVal):
      compileExpr(c, node.body[0])
      if node.body[1].isSelfEvaluatingFastConst:
        let constIndex = c.chunk.addConst(node.body[1])
        discard c.emit(opNativeFastConst, ord(fastKind), name = node.head.symVal,
                       depth = constIndex)
      else:
        compileExpr(c, node.body[1])
        discard c.emit(opNativeFast2, ord(fastKind), name = node.head.symVal)
      return
  if node.props.len == 0 and node.head.kind == vkSymbol and node.body.len == 1:
    let direct = c.lexicalCallSlot(node.head.symVal)
    if direct.slot >= 0:
      compileExpr(c, node.body[0])
      c.chunk.callSites[c.emit(direct.op, direct.slot, name = node.head.symVal,
                               depth = direct.depth)] = node
      return
    if not c.hasLexicalBinding(node.head.symVal):
      compileExpr(c, node.body[0])
      c.chunk.callSites[c.emit(opCallName1, name = node.head.symVal)] = node
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
  if node.body.len == 0:
    raise newException(GeneError, "`~` requires a callable")
  if not c.selfAvailable:
    raise newException(GeneError, "leading `~` requires lexical self")
  compileExpr(c, node.body[0])
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
  compileExpr(c, body[0])
  let exitJump = c.emitJump(opJumpIfFalse)
  compileBodyFrom(c, body, 1)
  discard c.emit(opPop)                     # discard each iteration's body value
  discard c.emit(opJump, start)             # loop back to the condition
  c.patchJump(exitJump)
  c.emitConst NIL                           # while evaluates to nil

proc compileFor(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 2:
    raise newException(GeneError, "for requires a pattern and a collection")
  if c.allowYield and body.bodyContainsYield(2):
    let iterName = c.nextTemp("iter")
    compileExpr(c, body[1])                   # collection on the stack
    discard c.emit(opMakeIterator)
    c.emitDefineBinding(iterName)

    let start = c.chunk.instructions.len
    c.emitLoadBinding(iterName)
    discard c.emit(opIteratorHasNext)
    let exitJump = c.emitJump(opJumpIfFalse)

    c.emitLoadBinding(iterName)
    discard c.emit(opIteratorNext)
    discard c.emit(opMatchBindReplace, c.chunk.addConst(body[0]))
    discard c.emit(opPop)                     # discard the matched item
    compileBodyFrom(c, body, 2)
    discard c.emit(opPop)                     # discard each iteration's body value
    discard c.emit(opJump, start)
    c.patchJump(exitJump)
    c.emitConst NIL
    return

  compileExpr(c, body[1])                   # collection on the stack
  var bodyCompiler = c.childCompiler()
  bodyCompiler.enableLocalSlots()
  bodyCompiler.parentSlots = c.parentFrames()
  for name in patternBindingNames(body[0]):
    discard bodyCompiler.reserveLocal(name)
    if name == "self":
      bodyCompiler.selfAvailable = true
  if patternBindsSelf(body[0]):
    bodyCompiler.selfAvailable = true
  compileBodyFrom(bodyCompiler, body, 2)
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
  discard c.emit(opSpawn, c.chunk.addSubchunk(body))

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

proc compileType(c: var Compiler, node: Value) =
  ## (type Name ^props {...} ^body [...] ^is Parent ^impl [P] ^derive [P]) —
  ## field annotations and protocol references are checked at runtime. Derive
  ## requests are passed to protocol-local derive forms after the type is created.
  let body = node.body
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "type requires a name")
  rejectUnknownTypeProps(node)
  let name = body[0].symVal
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
      compileExpr(c, protocolExpr)
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
      compileExpr(c, protocolExpr)
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
                                           deriveRequests: deriveRequests)))
  c.emitDefineBinding(name)

proc messageName(node: Value): string =
  if node.kind != vkNode or not node.head.isSymbol("message"):
    raise newException(GeneError, "protocol/impl body must contain message declarations")
  if node.body.len < 2 or node.body[0].kind != vkSymbol or node.body[1].kind != vkList:
    raise newException(GeneError, "message requires a name and parameter vector")
  node.body[0].symVal

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
  for message in messageNames:
    discard c.reserveLocal(message)
  let idx = c.chunk.addProtocol(ProtocolProto(name: name,
                                              messageNames: messageNames,
                                              deriveFn: deriveFn))
  discard c.emit(opMakeProtocol, idx)
  c.emitDefineBinding(name)

proc implMessageProto(c: var Compiler, node: Value): ImplMessageProto =
  let name = messageName(node)
  let errorRow = compileErrorRow(c, node)
  ImplMessageProto(name: name,
                   fn: buildFunctionProto(c, name, node.body[1], node.body, 2,
                                          checksErrors = errorRow.checks,
                                          errorTypeCount = errorRow.count))

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
    if seen.hasKey(mp.name):
      raise newException(GeneError, "duplicate impl message: " & mp.name)
    seen[mp.name] = true
    messages.add mp
  let idx = c.chunk.addImpl(ImplProto(messages: messages))
  discard c.emit(opMakeImpl, idx)

proc compileNode(c: var Compiler, node: Value, allowModDecl: bool) =
  let h = node.head
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
    of "for":
      compileFor(c, node)
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

proc compileForms*(forms: openArray[Value],
                   allowAmbientImports = true,
                   useLocalSlots = true): Chunk =
  var c = Compiler(chunk: newChunk(), allowAmbientImports: allowAmbientImports)
  if useLocalSlots:
    c.enableLocalSlots()
  if forms.len == 0:
    c.emitConst NIL
  else:
    for i in 0 ..< forms.len:
      compileExpr(c, forms[i], allowModDecl = true)
      if i < forms.high:
        discard c.emit(opPop)
  discard c.emit(opReturn)
  if useLocalSlots:
    c.chunk.localNames = c.localNames
    c.chunk.mirrorSlots = true
  c.chunk

proc compileForm*(form: Value): Chunk =
  let forms = @[form]
  compileForms(forms)

proc compileEvalForm*(form: Value): Chunk =
  ## Eval code receives only explicit Env bindings/imports/module context. It
  ## must not use source-level imports to acquire ambient module-loader authority.
  let forms = @[form]
  compileForms(forms, allowAmbientImports = false)

proc compileEvalSource*(src: string, useLocalSlots = true): Chunk =
  ## CLI/REPL eval receives source text but still uses eval authority rules.
  compileForms(readAll(src), allowAmbientImports = false,
               useLocalSlots = useLocalSlots)

proc compileSource*(src: string): Chunk =
  compileForms(readAll(src))
