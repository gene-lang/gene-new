## Stack VM for compiled Gene GIR chunks.

import std/[strutils, tables]
import ./[equality, gir, printer, types]

# ---------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------

proc newScope*(parent: Scope = nil): Scope =
  Scope(parent: parent, vars: initTable[string, Value]())

proc lookup*(scope: Scope, name: string): Value =
  var s = scope
  while s != nil:
    if s.vars.hasKey(name): return s.vars[name]
    s = s.parent
  raise newException(GeneError, "undefined symbol: " & name)

proc lookupOptional*(scope: Scope, name: string, value: var Value): bool =
  var s = scope
  while s != nil:
    if s.vars.hasKey(name):
      value = s.vars[name]
      return true
    s = s.parent
  false

proc define*(scope: Scope, name: string, v: Value) =
  scope.vars[name] = v

proc assign*(scope: Scope, name: string, v: Value) =
  var s = scope
  while s != nil:
    if s.vars.hasKey(name):
      s.vars[name] = v
      return
    s = s.parent
  raise newException(GeneError, "set of undefined symbol: " & name)

type
  NamedArgs = object
    names: seq[string]
    values: seq[Value]

proc len(named: NamedArgs): int =
  named.names.len

proc hasArg(named: NamedArgs, name: string): bool =
  for key in named.names:
    if key == name: return true
  false

proc getArg(named: NamedArgs, name: string): Value =
  for i, key in named.names:
    if key == name: return named.values[i]
  raise newException(GeneError, "missing named argument: " & name)

proc applyCall(callee: Value, args: seq[Value], named: NamedArgs): Value

# ---------------------------------------------------------------------------
# Built-in functions
# ---------------------------------------------------------------------------

proc isNumber(v: Value): bool = v.kind == vkInt or v.kind == vkFloat
proc toFloat(v: Value): float64 = (if v.kind == vkInt: v.intVal.float64 else: v.floatVal)
proc isSymbol(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc isSelector(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("select")

proc requireNums(name: string, args: openArray[Value]) =
  for a in args:
    if not a.isNumber:
      raise newException(GeneError, name & " expects numbers, got " & $a.kind)

proc biAdd(args: openArray[Value]): Value {.nimcall.} =
  requireNums("+", args)
  var allInt = true
  for a in args:
    if a.kind == vkFloat: allInt = false
  if allInt:
    var s: int64 = 0
    for a in args: s += a.intVal
    newInt(s)
  else:
    var s: float64 = 0
    for a in args: s += a.toFloat
    newFloat(s)

proc biSub(args: openArray[Value]): Value {.nimcall.} =
  requireNums("-", args)
  if args.len == 0: return newInt(0)
  var allInt = true
  for a in args:
    if a.kind == vkFloat: allInt = false
  if args.len == 1:
    return (if allInt: newInt(-args[0].intVal) else: newFloat(-args[0].toFloat))
  if allInt:
    var s = args[0].intVal
    for i in 1 ..< args.len: s -= args[i].intVal
    newInt(s)
  else:
    var s = args[0].toFloat
    for i in 1 ..< args.len: s -= args[i].toFloat
    newFloat(s)

proc biMul(args: openArray[Value]): Value {.nimcall.} =
  requireNums("*", args)
  var allInt = true
  for a in args:
    if a.kind == vkFloat: allInt = false
  if allInt:
    var s: int64 = 1
    for a in args: s *= a.intVal
    newInt(s)
  else:
    var s: float64 = 1
    for a in args: s *= a.toFloat
    newFloat(s)

proc biDiv(args: openArray[Value]): Value {.nimcall.} =
  requireNums("/", args)
  if args.len < 2:
    raise newException(GeneError, "/ expects at least 2 arguments")
  var allInt = true
  for a in args:
    if a.kind == vkFloat: allInt = false
  if allInt:
    var s = args[0].intVal
    for i in 1 ..< args.len:
      if args[i].intVal == 0: raise newException(GeneError, "division by zero")
      s = s div args[i].intVal
    newInt(s)
  else:
    var s = args[0].toFloat
    for i in 1 ..< args.len:
      let d = args[i].toFloat
      if d == 0.0: raise newException(GeneError, "division by zero")
      s = s / d
    newFloat(s)

template comparison(name: string, op: untyped): NativeProc =
  (proc(args: openArray[Value]): Value {.nimcall.} =
    requireNums(name, args)
    for i in 1 ..< args.len:
      if not op(args[i-1].toFloat, args[i].toFloat): return FALSE
    TRUE)

proc biEq(args: openArray[Value]): Value {.nimcall.} =
  for i in 1 ..< args.len:
    if not equal(args[i-1], args[i]): return FALSE
  TRUE

proc biNot(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 1: raise newException(GeneError, "not expects 1 argument")
  newBool(not isTruthy(args[0]))

proc requireOne(name: string, args: openArray[Value]) =
  if args.len != 1:
    raise newException(GeneError, name & " expects 1 argument, got " & $args.len)

proc biHead(args: openArray[Value]): Value {.nimcall.} =
  requireOne("head", args)
  headOf(args[0])

proc biProps(args: openArray[Value]): Value {.nimcall.} =
  requireOne("props", args)
  newMap(propsOf(args[0]))

proc biBody(args: openArray[Value]): Value {.nimcall.} =
  requireOne("body", args)
  newList(bodyOf(args[0]))

proc biMeta(args: openArray[Value]): Value {.nimcall.} =
  requireOne("meta", args)
  newMap(metaOf(args[0]))

proc copyItems(items: openArray[Value]): seq[Value] =
  result = newSeq[Value](items.len)
  for i, item in items:
    result[i] = item

proc copyEntries(entries: PropTable): PropTable =
  result = initOrderedTable[string, Value]()
  for key, val in entries:
    result[key] = val

proc keySegment(name: string, segment: Value): string =
  case segment.kind
  of vkSymbol:
    segment.symVal
  of vkString:
    segment.strVal
  else:
    raise newException(GeneError,
      name & " expects a symbol/string path segment, got " & $segment.kind)

proc readIndex(items: openArray[Value], rawIndex: int64): Value =
  var idx = rawIndex
  if idx < 0:
    idx = int64(items.len) + idx
  if idx < 0 or idx >= int64(items.len):
    return VOID
  items[int(idx)]

proc updateIndex(name: string, itemsLen: int, rawIndex: int64): int =
  var idx = rawIndex
  if idx < 0:
    idx = int64(itemsLen) + idx
  if idx < 0 or idx >= int64(itemsLen):
    raise newException(GeneError, name & " index out of range: " & $rawIndex)
  int(idx)

proc selectorPath(name: string, path: Value): seq[Value] =
  if not path.isSelector:
    raise newException(GeneError, name & " expects a selector path")
  if path.body.len == 0:
    raise newException(GeneError, name & " expects a non-empty selector path")
  for segment in path.body:
    case segment.kind
    of vkInt, vkSymbol, vkString:
      result.add segment
    else:
      raise newException(GeneError,
        name & " cannot update through selector stage: " & $segment.kind)

proc readUpdateChild(name: string, target, segment: Value): Value =
  case target.kind
  of vkMap:
    target.mapEntries.getOrDefault(keySegment(name, segment), VOID)
  of vkList:
    if segment.kind != vkInt:
      raise newException(GeneError, name & " expects an integer list path segment")
    readIndex(target.listItems, segment.intVal)
  of vkNode:
    case segment.kind
    of vkInt:
      readIndex(target.body, segment.intVal)
    of vkSymbol, vkString:
      let key = keySegment(name, segment)
      if target.props.hasKey(key):
        target.props[key]
      else:
        case key
        of "head": target.head
        of "props": newMap(copyEntries(target.props))
        of "body": newList(copyItems(target.body))
        of "meta": newMap(copyEntries(target.meta))
        else: VOID
    else:
      VOID
  else:
    raise newException(GeneError,
      name & " cannot update through " & $target.kind)

proc writeUpdateChild(name: string, target, segment, value: Value): Value =
  case target.kind
  of vkMap:
    var entries = copyEntries(target.mapEntries)
    let key = keySegment(name, segment)
    if value.kind == vkVoid:
      entries.del(key)
    else:
      entries[key] = value
    newMap(entries, target.mapImmutable)
  of vkList:
    if segment.kind != vkInt:
      raise newException(GeneError, name & " expects an integer list path segment")
    var items = copyItems(target.listItems)
    items[updateIndex(name, items.len, segment.intVal)] =
      if value.kind == vkVoid: NIL else: value
    newList(items, target.listImmutable)
  of vkNode:
    var props = copyEntries(target.props)
    var body = copyItems(target.body)
    var meta = copyEntries(target.meta)
    case segment.kind
    of vkInt:
      body[updateIndex(name, body.len, segment.intVal)] =
        if value.kind == vkVoid: NIL else: value
    of vkSymbol, vkString:
      let key = keySegment(name, segment)
      if target.props.hasKey(key) or key notin ["head", "props", "body", "meta"]:
        if value.kind == vkVoid:
          props.del(key)
        else:
          props[key] = value
      else:
        case key
        of "head":
          if value.kind == vkVoid:
            raise newException(GeneError, name & " cannot remove a node head")
          return newNode(value, props, body, meta, target.nodeImmutable)
        of "props":
          if value.kind == vkVoid:
            props = initOrderedTable[string, Value]()
          elif value.kind == vkMap:
            props = copyEntries(value.mapEntries)
          else:
            raise newException(GeneError, name & " /props expects a map value")
        of "body":
          if value.kind == vkVoid:
            body = @[]
          elif value.kind == vkList:
            body = copyItems(value.listItems)
          else:
            raise newException(GeneError, name & " /body expects a list value")
        of "meta":
          if value.kind == vkVoid:
            meta = initOrderedTable[string, Value]()
          elif value.kind == vkMap:
            meta = copyEntries(value.mapEntries)
          else:
            raise newException(GeneError, name & " /meta expects a map value")
        else:
          discard
    else:
      raise newException(GeneError,
        name & " cannot update through selector stage: " & $segment.kind)
    newNode(target.head, props, body, meta, target.nodeImmutable)
  else:
    raise newException(GeneError,
      name & " cannot update through " & $target.kind)

proc assocAt(name: string, target: Value, path: openArray[Value],
             pos: int, value: Value): Value =
  let segment = path[pos]
  if pos == path.high:
    return writeUpdateChild(name, target, segment, value)
  let child = readUpdateChild(name, target, segment)
  if child.kind == vkVoid:
    raise newException(GeneError, name & " missing intermediate path segment")
  writeUpdateChild(name, target, segment, assocAt(name, child, path, pos + 1, value))

proc updateAt(name: string, target: Value, path: openArray[Value],
              pos: int, updater: Value): Value =
  let segment = path[pos]
  if pos == path.high:
    let current = readUpdateChild(name, target, segment)
    let nextValue = applyCall(updater, @[current], NamedArgs())
    return writeUpdateChild(name, target, segment, nextValue)
  let child = readUpdateChild(name, target, segment)
  if child.kind == vkVoid:
    raise newException(GeneError, name & " missing intermediate path segment")
  writeUpdateChild(name, target, segment, updateAt(name, child, path, pos + 1, updater))

proc biAssocIn(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "assoc-in expects 3 arguments, got " & $args.len)
  let path = selectorPath("assoc-in", args[1])
  assocAt("assoc-in", args[0], path, 0, args[2])

proc biUpdateIn(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "update-in expects 3 arguments, got " & $args.len)
  let path = selectorPath("update-in", args[1])
  updateAt("update-in", args[0], path, 0, args[2])

proc displayStr(v: Value): string =
  ## print/println render strings as raw text and everything else via the printer.
  if v.kind == vkString: v.strVal else: print(v)

proc biPrint(args: openArray[Value]): Value {.nimcall.} =
  var parts: seq[string]
  for a in args: parts.add displayStr(a)
  stdout.write parts.join(" ")
  NIL

proc biPrintln(args: openArray[Value]): Value {.nimcall.} =
  var parts: seq[string]
  for a in args: parts.add displayStr(a)
  stdout.write parts.join(" ")
  stdout.write "\n"
  NIL

proc newGlobalScope*(): Scope =
  result = newScope()
  result.define("+", newNativeFn("+", biAdd))
  result.define("-", newNativeFn("-", biSub))
  result.define("*", newNativeFn("*", biMul))
  result.define("/", newNativeFn("/", biDiv))
  result.define("<", newNativeFn("<", comparison("<", `<`)))
  result.define(">", newNativeFn(">", comparison(">", `>`)))
  result.define("<=", newNativeFn("<=", comparison("<=", `<=`)))
  result.define(">=", newNativeFn(">=", comparison(">=", `>=`)))
  result.define("=", newNativeFn("=", biEq))
  result.define("not", newNativeFn("not", biNot))
  result.define("head", newNativeFn("head", biHead))
  result.define("props", newNativeFn("props", biProps))
  result.define("body", newNativeFn("body", biBody))
  result.define("meta", newNativeFn("meta", biMeta))
  result.define("assoc-in", newNativeFn("assoc-in", biAssocIn))
  result.define("update-in", newNativeFn("update-in", biUpdateIn))
  result.define("print", newNativeFn("print", biPrint))
  result.define("println", newNativeFn("println", biPrintln))

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

proc pop(stack: var seq[Value]): Value =
  if stack.len == 0:
    raise newException(GeneError, "VM stack underflow")
  result = stack[^1]
  stack.setLen(stack.len - 1)

proc run*(chunk: Chunk, scope: Scope): Value =
  var stack: seq[Value]
  var ip = 0
  while ip < chunk.instructions.len:
    let inst = chunk.instructions[ip]
    inc ip
    case inst.op
    of opPushConst:
      stack.add chunk.constants[inst.intArg]
    of opLoadName:
      stack.add scope.lookup(inst.name)
    of opDefineName:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in var")
      scope.define(inst.name, stack[^1])
    of opSetName:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in set")
      scope.assign(inst.name, stack[^1])
    of opPop:
      discard stack.pop()
    of opMakeList:
      var items = newSeq[Value](inst.intArg)
      if inst.intArg > 0:
        for i in countdown(inst.intArg - 1, 0):
          items[i] = stack.pop()
      stack.add newList(items, inst.flag)
    of opMakeMap:
      var values = newSeq[Value](inst.intArg)
      if inst.intArg > 0:
        for i in countdown(inst.intArg - 1, 0):
          values[i] = stack.pop()
      var entries = initOrderedTable[string, Value]()
      for i, key in inst.names:
        entries[key] = values[i]
      stack.add newMap(entries, inst.flag)
    of opMakeSelector:
      var body = newSeq[Value](inst.intArg)
      if inst.intArg > 0:
        for i in countdown(inst.intArg - 1, 0):
          body[i] = stack.pop()
      stack.add newNode(newSym("select"), body = body)
    of opMakeFn:
      let proto = chunk.functions[inst.intArg]
      stack.add newFunction(proto.name, proto.params, proto, scope)
    of opMakeNamespace:
      # Run the ns body in a fresh child scope; its bindings become the
      # namespace's exports. Bind the namespace in the enclosing scope.
      let nsScope = newScope(scope)
      discard run(chunk.subchunks[inst.intArg], nsScope)
      let ns = newNamespace(inst.name, nsScope)
      scope.define(inst.name, ns)
      stack.add ns
    of opCall:
      var args = newSeq[Value](inst.intArg)
      if inst.intArg > 0:
        for i in countdown(inst.intArg - 1, 0):
          args[i] = stack.pop()
      var named: NamedArgs
      if inst.names.len > 0:
        named.names = inst.names
        named.values = newSeq[Value](inst.names.len)
        for i in countdown(inst.names.len - 1, 0):
          named.values[i] = stack.pop()
      let callee = stack.pop()
      stack.add applyCall(callee, args, named)
    of opJumpIfFalse:
      let cond = stack.pop()
      if not cond.isTruthy:
        ip = inst.intArg
    of opJump:
      ip = inst.intArg
    of opReturn:
      return (if stack.len > 0: stack.pop() else: NIL)
  NIL

proc positionalDefault(proto: FunctionProto, index: int): ParamDefault =
  if index < proto.paramDefaults.len:
    proto.paramDefaults[index]
  else:
    ParamDefault()

proc requiredPositionalCount(proto: FunctionProto): int =
  for i in 0 ..< proto.params.len:
    if proto.positionalDefault(i).optional:
      break
    inc result

proc defaultValue(defaultValue: ParamDefault, scope: Scope): Value =
  if defaultValue.defaultChunk != nil:
    run(defaultValue.defaultChunk, scope)
  else:
    VOID

proc isSelectorStage(v: Value): bool =
  case v.kind
  of vkFunction, vkNativeFn:
    true
  of vkNode:
    v.isSelector
  else:
    false

proc lookupIndex(items: openArray[Value], rawIndex: int64): Value =
  var idx = rawIndex
  if idx < 0:
    idx = int64(items.len) + idx
  if idx < 0 or idx >= int64(items.len):
    return VOID
  items[int(idx)]

proc staticLookup(target, segment: Value): Value =
  if target.kind == vkVoid:
    return VOID
  case segment.kind
  of vkInt:
    case target.kind
    of vkList:
      lookupIndex(target.listItems, segment.intVal)
    of vkNode:
      lookupIndex(target.body, segment.intVal)
    else:
      VOID
  of vkSymbol, vkString:
    let key = if segment.kind == vkSymbol: segment.symVal else: segment.strVal
    case target.kind
    of vkMap:
      if target.mapEntries.hasKey(key): target.mapEntries[key] else: VOID
    of vkNode:
      if target.props.hasKey(key):
        target.props[key]
      else:
        case key
        of "head": target.head
        of "props": newMap(target.props)
        of "body": newList(target.body)
        of "meta": newMap(target.meta)
        else: VOID
    of vkList:
      case key
      of "size": newInt(target.listItems.len)
      of "empty?": newBool(target.listItems.len == 0)
      of "first": (if target.listItems.len > 0: target.listItems[0] else: VOID)
      of "last": (if target.listItems.len > 0: target.listItems[^1] else: VOID)
      else: VOID
    of vkNamespace:
      # Qualified access reads the namespace's own exports (not its parent chain).
      target.nsScope.vars.getOrDefault(key, VOID)
    else:
      VOID
  of vkNode:
    if segment.head.isSymbol("unquote"):
      raise newException(GeneError, "dynamic selector stages are not implemented")
    VOID
  else:
    VOID

proc applySelector(selector, target: Value): Value =
  result = target
  for segment in selector.body:
    result =
      if segment.isSelectorStage:
        applyCall(segment, @[result], NamedArgs())
      else:
        staticLookup(result, segment)
    if result.kind == vkVoid:
      return VOID

proc applyCall(callee: Value, args: seq[Value], named: NamedArgs): Value =
  case callee.kind
  of vkNativeFn:
    if named.len != 0:
      raise newException(GeneError,
        "native function '" & callee.nativeFnName & "' does not accept named arguments")
    callee.nativeImpl()(args)
  of vkFunction:
    let positional = callee.fnParams
    let code = callee.fnCode
    if code == nil or not (code of FunctionProto):
      raise newException(GeneError, "function has no VM code")
    let proto = FunctionProto(code)
    let requiredPositional = proto.requiredPositionalCount()
    if proto.restParam.len == 0:
      if args.len < requiredPositional or args.len > positional.len:
        raise newException(GeneError,
          "function '" & callee.fnName & "' expects " & $requiredPositional &
          ".." & $positional.len &
          " argument(s), got " & $args.len)
    elif args.len < positional.len:
      raise newException(GeneError,
        "function '" & callee.fnName & "' expects at least " & $positional.len &
        " argument(s), got " & $args.len)
    for key in named.names:
      var found = false
      for p in proto.namedParams:
        if p.arg == key:
          found = true
          break
      if not found:
        raise newException(GeneError,
          "function '" & callee.fnName & "' got unexpected named argument: " & key)

    let callScope = newScope(callee.fnScope)
    let providedPositional = min(args.len, positional.len)
    for i in 0 ..< providedPositional:
      callScope.define(positional[i], args[i])
    for p in proto.namedParams:
      if named.hasArg(p.arg):
        callScope.define(p.local, named.getArg(p.arg))
    for i in providedPositional ..< positional.len:
      let fallback = proto.positionalDefault(i)
      if not fallback.optional:
        raise newException(GeneError,
          "function '" & callee.fnName & "' missing positional argument: " & positional[i])
      callScope.define(positional[i], fallback.defaultValue(callScope))
    if proto.restParam.len > 0:
      var rest = newSeq[Value](args.len - positional.len)
      for i in 0 ..< rest.len:
        rest[i] = args[positional.len + i]
      callScope.define(proto.restParam, newList(rest))
    for p in proto.namedParams:
      if not named.hasArg(p.arg):
        if p.defaultValue.optional:
          callScope.define(p.local, p.defaultValue.defaultValue(callScope))
        else:
          raise newException(GeneError,
            "function '" & callee.fnName & "' missing named argument: " & p.arg)
    run(proto.chunk, callScope)
  of vkNode:
    if not callee.isSelector:
      raise newException(GeneError, "value is not callable: " & $callee.kind)
    if named.len != 0:
      raise newException(GeneError, "selector calls do not accept named arguments")
    if args.len != 1:
      raise newException(GeneError, "selector expects 1 argument, got " & $args.len)
    applySelector(callee, args[0])
  else:
    raise newException(GeneError, "value is not callable: " & $callee.kind)

proc call*(callee: Value, args: seq[Value] = @[]): Value =
  applyCall(callee, args, NamedArgs())
