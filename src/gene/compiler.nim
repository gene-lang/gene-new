## AST-to-GIR compiler for the MVP execution surface.

import std/[strutils, tables]
import ./[gir, reader, types]

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

  ParamSpecs = object
    positional: seq[string]
    positionalTypes: seq[Value]
    positionalDefaults: seq[ParamDefault]
    rest: string
    named: seq[NamedParam]

  ParamAdornment = object
    typeExpr: Value
    defaultValue: ParamDefault

  MacroDef = object
    params: seq[string]
    rest: string
    body: seq[Value]

const MaxMacroExpansionDepth = 100

proc emit(c: var Compiler, op: OpCode, intArg = 0, name = "",
          depth = 0,
          names: seq[string] = @[], flag = false): int =
  c.chunk.emit Instruction(op: op, intArg: intArg, depth: depth,
                           name: name, names: names, flag: flag)

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

proc emitLoadBinding(c: var Compiler, name: string) =
  let slot = c.localSlot(name)
  if slot >= 0:
    discard c.emit(opLoadLocal, slot, name = name)
  else:
    let outer = c.parentSlot(name)
    if outer.slot >= 0:
      discard c.emit(opLoadOuterLocal, outer.slot, depth = outer.depth, name = name)
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

proc compileExpr(c: var Compiler, node: Value, allowModDecl = false)

proc childCompiler(c: Compiler): Compiler =
  Compiler(chunk: newChunk(), selfAvailable: c.selfAvailable,
           macros: c.macros, hasMacros: c.hasMacros,
           macroExpansionDepth: c.macroExpansionDepth)

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

proc bodyContainsYield(body: openArray[Value], first: int): bool =
  if first > body.high:
    return false
  for i in first .. body.high:
    if containsYield(body[i]):
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

proc macroParamDef(c: Compiler, paramList: Value): tuple[params: seq[string], rest: string] =
  let specs = c.paramSpecs(paramList)
  if specs.named.len != 0:
    raise newException(GeneError, "macro named parameters are not implemented")
  for t in specs.positionalTypes:
    if t.kind != vkNil:
      raise newException(GeneError, "macro parameter type annotations are not implemented")
  for defaultValue in specs.positionalDefaults:
    if defaultValue.optional:
      raise newException(GeneError, "macro parameter defaults are not implemented")
  (specs.positional, specs.rest)

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
  var body: seq[Value]
  for item in node.body:
    let splice = macroSpliceExpr(item, env, c, depth)
    if splice.splice:
      body.appendMacroSplice(splice.value)
    else:
      body.add expandMacroQuasi(item, env, depth, c, hygiene)
  newNode(hygienicSymbol(node.head, hygiene), props = props, body = body,
          meta = meta, immutable = node.nodeImmutable)

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

proc expandMacro(c: var Compiler, def: MacroDef, node: Value): Value =
  if node.props.len != 0:
    raise newException(GeneError, "macro calls with props are not implemented")
  let args = node.body
  if args.len < def.params.len:
    raise newException(GeneError, "macro expects at least " & $def.params.len &
      " argument(s), got " & $args.len)
  if def.rest.len == 0 and args.len != def.params.len:
    raise newException(GeneError, "macro expects " & $def.params.len &
      " argument(s), got " & $args.len)
  var env = initTable[string, Value]()
  for i, name in def.params:
    env[name] = args[i]
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
  c.macros[body[0].symVal] = MacroDef(params: sig.params, rest: sig.rest,
                                      body: macroBody)
  c.hasMacros = true
  c.emitConst NIL

proc compileErrorRow(c: var Compiler, node: Value): tuple[checks: bool, count: int] =
  if not node.props.hasKey("errors"):
    return
  let row = node.props["errors"]
  if row.kind != vkList:
    raise newException(GeneError, "^errors must be a list")
  result.checks = true
  for errorType in row.listItems:
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
  FunctionProto(name: name, typeParams: typeParams, params: specs.positional,
                localNames: fnCompiler.localNames,
                positionalSlots: positionalSlots,
                namedSlots: namedSlots,
                restSlot: restSlot,
                requiredPositional: specs.requiredPositionalCount,
                simpleCall: simpleCall,
                paramTypes: specs.positionalTypes,
                hasParamTypes: hasParamTypes,
                paramDefaults: specs.positionalDefaults,
                restParam: specs.rest, namedParams: specs.named,
                hasNamedParamTypes: hasNamedParamTypes,
                returnType: returnType,
                hasReturnType: returnType.kind != vkNil,
                isGenerator: fnCompiler.sawYield,
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

proc compileImport(c: var Compiler, node: Value) =
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

proc selectorLiteral(parts: openArray[Value]): Value =
  var body = newSeq[Value](parts.len)
  for i, part in parts:
    body[i] = part
  newNode(newSym("select"), body = body)

proc isUnquoteSegment(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("unquote")

proc compileSelector(c: var Compiler, parts: openArray[Value]) =
  var dynamic = false
  for part in parts:
    if part.isUnquoteSegment:
      dynamic = true
      break
  if not dynamic:
    c.emitConst selectorLiteral(parts)
    return

  for part in parts:
    if part.isUnquoteSegment:
      if part.body.len != 1:
        raise newException(GeneError, "selector unquote requires one expression")
      compileExpr(c, part.body[0])
    else:
      c.emitConst part
  discard c.emit(opMakeSelector, parts.len)

proc compilePath(c: var Compiler, node: Value) =
  let parts = node.body
  if parts.len == 0:
    c.emitConst VOID
    return
  if parts.len == 1:
    compileExpr(c, parts[0])
    return
  compileSelector(c, parts.toOpenArray(1, parts.high))
  compileExpr(c, parts[0])
  discard c.emit(opCall, 1)

proc compileCall(c: var Compiler, node: Value) =
  compileExpr(c, node.head)
  var names: seq[string]
  for k, value in node.props:
    names.add k
    compileExpr(c, value)
  for arg in node.body:
    compileExpr(c, arg)
  discard c.emit(opCall, node.body.len, names = names)

proc compileLeadingSelfCall(c: var Compiler, node: Value) =
  if node.body.len == 0:
    raise newException(GeneError, "`~` requires a callable")
  if not c.selfAvailable:
    raise newException(GeneError, "leading `~` requires lexical self")
  compileExpr(c, node.body[0])
  var names: seq[string]
  for k, value in node.props:
    names.add k
    compileExpr(c, value)
  compileExpr(c, newSym("self"))
  for i in 1 ..< node.body.len:
    compileExpr(c, node.body[i])
  discard c.emit(opCall, node.body.len, names = names)

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

proc compileFail(c: var Compiler, node: Value) =
  if node.props.len != 0 or node.body.len != 1:
    raise newException(GeneError, "fail expects one Error value")
  compileExpr(c, node.body[0])
  discard c.emit(opFail)

proc deriveProtocolExpr(request: Value): Value =
  if request.kind == vkNode:
    request.head
  else:
    request

proc compileType(c: var Compiler, node: Value) =
  ## (type Name ^props {...} ^is Parent ^impl [P] ^derive [P]) — field
  ## annotations and protocol references are checked at runtime. Derive requests
  ## are passed to protocol-local derive forms after the type is created.
  let body = node.body
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "type requires a name")
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
      compileSelector(c, node.body)
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
    of "fail":
      compileFail(c, node)
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
    for item in node.listItems:
      compileExpr(c, item)
    discard c.emit(opMakeList, node.listItems.len, flag = node.listImmutable)
  of vkMap:
    var keys: seq[string]
    for k, value in node.mapEntries:
      keys.add k
      compileExpr(c, value)
    discard c.emit(opMakeMap, keys.len, names = keys, flag = node.mapImmutable)
  else:
    c.emitConst node

proc compileForms*(forms: openArray[Value]): Chunk =
  var c = Compiler(chunk: newChunk())
  c.enableLocalSlots()
  if forms.len == 0:
    c.emitConst NIL
  else:
    for i in 0 ..< forms.len:
      compileExpr(c, forms[i], allowModDecl = true)
      if i < forms.high:
        discard c.emit(opPop)
  discard c.emit(opReturn)
  c.chunk.localNames = c.localNames
  c.chunk.mirrorSlots = true
  c.chunk

proc compileForm*(form: Value): Chunk =
  let forms = @[form]
  compileForms(forms)

proc compileSource*(src: string): Chunk =
  compileForms(readAll(src))
