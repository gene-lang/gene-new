## AST-to-GIR compiler for the MVP execution surface.

import std/[strutils, tables]
import ./[gir, reader, types]

type
  Compiler = object
    chunk: Chunk

  ParamSpecs = object
    positional: seq[string]
    positionalDefaults: seq[ParamDefault]
    rest: string
    named: seq[NamedParam]

proc emit(c: var Compiler, op: OpCode, intArg = 0, name = "",
          names: seq[string] = @[], flag = false): int =
  c.chunk.emit Instruction(op: op, intArg: intArg, name: name, names: names, flag: flag)

proc emitConst(c: var Compiler, value: Value) =
  discard c.emit(opPushConst, c.chunk.addConst(value))

proc emitJump(c: var Compiler, op: OpCode): int =
  c.emit(op, -1)

proc patchJump(c: var Compiler, at: int) =
  c.chunk.patchJump(at, c.chunk.instructions.len)

proc isSymbol(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc compileExpr(c: var Compiler, node: Value)

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

proc compileDefaultExpr(node: Value): Chunk =
  var c = Compiler(chunk: newChunk())
  compileExpr(c, node)
  discard c.emit(opReturn)
  c.chunk

proc compileSubBody(forms: openArray[Value]): Chunk =
  var c = Compiler(chunk: newChunk())
  compileBody(c, forms)            # empty -> nil
  discard c.emit(opReturn)
  c.chunk

proc isParamTerminator(s: string): bool =
  s.len == 0 or s in [",", "^", "^^"]

proc isRestParam(s: string): bool =
  s.len > 3 and s.endsWith("...")

proc splitOptionalName(s: string): tuple[name: string, optional: bool] =
  if s.len > 1 and s.endsWith("?"):
    (s[0 .. ^2], true)
  else:
    (s, false)

proc parseParamAdornment(items: openArray[Value], i: var int): ParamDefault =
  ## Skip MVP-ignored type annotations and compile call-time defaults.
  while i < items.len:
    let s = items[i].symbolText
    case s
    of ":":
      inc i
      if i < items.len: inc i
    of "=":
      inc i
      if i >= items.len:
        raise newException(GeneError, "parameter default requires a value")
      result.optional = true
      result.defaultChunk = compileDefaultExpr(items[i])
      inc i
    else:
      break

proc paramSpecs(paramList: Value): ParamSpecs =
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
      var defaultValue = parseParamAdornment(items, i)
      if argSpec.optional:
        defaultValue.optional = true
      result.named.add NamedParam(arg: arg, local: local, defaultValue: defaultValue)
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
        var defaultValue = parseParamAdornment(items, i)
        if spec.optional:
          defaultValue.optional = true
        if defaultValue.optional:
          sawOptionalPositional = true
        elif sawOptionalPositional:
          raise newException(GeneError, "required positional parameter cannot follow an optional positional parameter")
        result.positional.add spec.name
        result.positionalDefaults.add defaultValue
        continue
      discard parseParamAdornment(items, i)

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
  if body.len >= 2:
    compileExpr(c, body[1])
  else:
    c.emitConst NIL
  if body[0].kind == vkSymbol:
    discard c.emit(opDefineName, name = body[0].symVal)
  else:
    discard c.emit(opMatchBind, c.chunk.addConst(body[0]))  # destructuring

proc compileSet(c: var Compiler, node: Value) =
  let body = node.body
  if body.len < 2 or body[0].kind != vkSymbol:
    raise newException(GeneError, "set requires a name and a value")
  compileExpr(c, body[1])
  discard c.emit(opSetName, name = body[0].symVal)

proc compileFn(c: var Compiler, node: Value) =
  let body = node.body
  var idx = 0
  var name = ""
  if body.len > 0 and body[0].kind == vkSymbol:
    name = body[0].symVal
    idx = 1
  if idx >= body.len or body[idx].kind != vkList:
    raise newException(GeneError, "fn requires a parameter vector")

  var fnCompiler = Compiler(chunk: newChunk())
  compileBodyFrom(fnCompiler, body, idx + 1)
  discard fnCompiler.emit(opReturn)

  let specs = paramSpecs(body[idx])
  let proto = FunctionProto(name: name, params: specs.positional,
                            paramDefaults: specs.positionalDefaults,
                            restParam: specs.rest, namedParams: specs.named,
                            chunk: fnCompiler.chunk)
  discard c.emit(opMakeFn, c.chunk.addFunction(proto))
  if name.len > 0:
    discard c.emit(opDefineName, name = name)

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
  discard c.emit(opImport, c.chunk.addImport(spec))

proc compileMod(c: var Compiler, node: Value) =
  ## MVP: a file is already its own module, so `(mod name body...)` just runs its
  ## body in the current module scope. The name and `@doc` meta are ignored here.
  compileBodyFrom(c, node.body, 1)

proc compileNs(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "ns requires a name")
  let name = body[0].symVal
  var nsCompiler = Compiler(chunk: newChunk())
  compileBodyFrom(nsCompiler, body, 1)
  discard nsCompiler.emit(opReturn)
  let idx = c.chunk.addSubchunk(nsCompiler.chunk)
  discard c.emit(opMakeNamespace, idx, name = name)

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

proc compileMatch(c: var Compiler, node: Value) =
  let body = node.body
  if body.len == 0:
    raise newException(GeneError, "match requires a value")
  compileExpr(c, body[0])                  # target stays on the stack
  var endJumps: seq[int]
  var hasElse = false
  for i in 1 ..< body.len:
    let clause = body[i]
    if clause.kind != vkNode or clause.head.kind != vkSymbol:
      raise newException(GeneError, "match clauses must be (when ...) or (else ...)")
    case clause.head.symVal
    of "when":
      if clause.body.len == 0:
        raise newException(GeneError, "when requires a pattern")
      discard c.emit(opTryMatch, c.chunk.addConst(clause.body[0]))
      let nextJump = c.emitJump(opJumpIfFalse)
      discard c.emit(opPop)                # drop target before the body
      compileBodyFrom(c, clause.body, 1)
      endJumps.add c.emitJump(opJump)
      c.patchJump(nextJump)
    of "else":
      discard c.emit(opPop)
      compileBody(c, clause.body)
      hasElse = true
      break
    else:
      raise newException(GeneError, "unknown match clause: " & clause.head.symVal)
  if not hasElse:
    discard c.emit(opPop)
    discard c.emit(opMatchFail)
  for at in endJumps:
    c.patchJump(at)

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
  compileExpr(c, body[1])                   # collection on the stack
  var bodyCompiler = Compiler(chunk: newChunk())
  compileBodyFrom(bodyCompiler, body, 2)
  discard bodyCompiler.emit(opReturn)
  let fp = ForProto(pattern: body[0], body: bodyCompiler.chunk)
  discard c.emit(opForEach, c.chunk.addForLoop(fp))

proc compileTry(c: var Compiler, node: Value) =
  ## (try body... catch pat recovery... [catch ...] [ensure cleanup...]) — the
  ## `catch`/`ensure` markers are bare symbols in the flat body.
  let body = node.body
  var i = 0
  var tryForms: seq[Value]
  while i < body.len and not (body[i].isSymbol("catch") or body[i].isSymbol("ensure")):
    tryForms.add body[i]
    inc i
  let tp = TryProto(body: compileSubBody(tryForms))
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
    tp.catches.add CatchClause(pattern: pattern, body: compileSubBody(recovery))
  if i < body.len and body[i].isSymbol("ensure"):
    inc i
    var ensureForms: seq[Value]
    while i < body.len:
      ensureForms.add body[i]
      inc i
    tp.ensureBody = compileSubBody(ensureForms)
  discard c.emit(opTry, c.chunk.addTry(tp))

proc compileNode(c: var Compiler, node: Value) =
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
    of "fn":
      compileFn(c, node)
      return
    of "quote":
      c.emitConst(if node.body.len >= 1: node.body[0] else: NIL)
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
    of "import":
      compileImport(c, node)
      return
    of "mod":
      compileMod(c, node)
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
    of "try":
      compileTry(c, node)
      return
    else:
      discard
  compileCall(c, node)

proc compileExpr(c: var Compiler, node: Value) =
  case node.kind
  of vkSymbol:
    discard c.emit(opLoadName, name = node.symVal)
  of vkNode:
    compileNode(c, node)
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
  compileBody(c, forms)
  discard c.emit(opReturn)
  c.chunk

proc compileForm*(form: Value): Chunk =
  let forms = @[form]
  compileForms(forms)

proc compileSource*(src: string): Chunk =
  compileForms(readAll(src))
