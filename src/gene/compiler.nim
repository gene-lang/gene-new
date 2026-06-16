## AST-to-GIR compiler for the MVP execution surface.

import std/tables
import ./[gir, reader, types]

type
  Compiler = object
    chunk: Chunk

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

proc paramNames(paramList: Value): seq[string] =
  ## Extract positional parameter names from an `[a b c]` vector. Type
  ## annotations (`x : T`) and separator commas are skipped for MVP.
  if paramList.kind != vkList: return @[]
  let items = paramList.listItems
  var i = 0
  while i < items.len:
    let it = items[i]
    if it.kind == vkSymbol:
      case it.symVal
      of ",": inc i
      of ":": inc i, 2
      else:
        result.add it.symVal
        inc i
    else:
      inc i

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
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "var requires a name")
  if body.len >= 2:
    compileExpr(c, body[1])
  else:
    c.emitConst NIL
  discard c.emit(opDefineName, name = body[0].symVal)

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

  let proto = FunctionProto(name: name, params: paramNames(body[idx]),
                            chunk: fnCompiler.chunk)
  discard c.emit(opMakeFn, c.chunk.addFunction(proto))

proc compileCall(c: var Compiler, node: Value) =
  compileExpr(c, node.head)
  for arg in node.body:
    compileExpr(c, arg)
  discard c.emit(opCall, node.body.len)

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
