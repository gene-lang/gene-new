## Stack VM for compiled Gene GIR chunks.

import std/[os, sets, strutils, tables]
import ./[compiler, equality, gir, printer, types]

# ---------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------

proc newScope*(parent: Scope = nil): Scope =
  Scope(parent: parent, vars: initTable[string, Value](), impls: @[],
        requiredImplTypes: @[])

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

proc applyCall(callee: Value, args: seq[Value], named: NamedArgs,
               dispatchScope: Scope = nil): Value

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

proc biPanic(args: openArray[Value]): Value {.nimcall.} =
  let v = if args.len >= 1: args[0] else: newStr("panic")
  var e: ref GenePanic
  new(e)
  e.msg = "panic: " & print(v)
  e.errVal = v
  e.hasErrVal = true
  raise e

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
  let errorProtocol = newProtocol("Error", [])
  result.define("Error", errorProtocol)
  var typeErrorFields: seq[TypeField]
  for name in ["message", "where", "expected", "actual"]:
    typeErrorFields.add TypeField(name: name, optional: false,
                                  typeExpr: newSym("Str"), scope: result)
  let typeError = newType("TypeError", NIL, typeErrorFields,
                          @[errorProtocol], result)
  result.define("TypeError", typeError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: typeError,
                                messages: initTable[string, Value]())
  let matchError = newType("MatchError", NIL,
                           @[TypeField(name: "message", optional: false,
                                       typeExpr: newSym("Str"), scope: result)],
                           @[errorProtocol], result)
  result.define("MatchError", matchError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: matchError,
                                messages: initTable[string, Value]())
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
  result.define("panic", newNativeFn("panic", biPanic))
  result.define("print", newNativeFn("print", biPrint))
  result.define("println", newNativeFn("println", biPrintln))

# ---------------------------------------------------------------------------
# Module loading (design §15.4/§15.6)
# ---------------------------------------------------------------------------
#
# A single-Application MVP: global cache + cycle set + current/root directories.
# Each module gets its own global scope (fresh built-ins), so modules are
# isolated from one another and from their importer.

var
  moduleCache: Table[string, Value]   # normalized abs path -> namespace value
  moduleLoading: HashSet[string]      # paths mid-load, for cycle detection
  currentModuleDir = getCurrentDir()  # dir of the module currently executing
  packageRoot = getCurrentDir()       # root for bare and absolute "/x" paths

proc initModuleContext*(entryDir: string) =
  ## Reset the loader for a fresh program run rooted at `entryDir`.
  moduleCache = initTable[string, Value]()
  moduleLoading = initHashSet[string]()
  let dir = if entryDir.len > 0: entryDir else: getCurrentDir()
  currentModuleDir = dir
  packageRoot = dir

proc resolveModulePath(rawPath: string): string =
  ## Normalize a `from "path"` string to a stable absolute module identity.
  var p = rawPath
  if splitFile(p).ext.len == 0:
    p = p & ".gene"          # MVP extension policy
  let base =
    if p.startsWith("./") or p.startsWith("../"): currentModuleDir
    else: packageRoot        # bare and leading-"/" resolve from the root
  if p.startsWith("/"):
    p = p[1 .. ^1]
  normalizedPath(absolutePath(p, base))

proc loadModuleNamespace(absPath: string): Value

proc isSubtypeOf(actual, expected: Value): bool {.inline.} =
  if expected.kind != vkType:
    return false
  var t = actual
  while t.kind == vkType:
    if t.bits == expected.bits:
      return true
    t = t.typeParent
  false

# ---------------------------------------------------------------------------
# Pattern matching (design §8)
# ---------------------------------------------------------------------------
#
# `tryMatch` walks a pattern AST against a target value, collecting bindings into
# `binds` (committed by the caller only on success). Supported: `_` wildcard,
# bare-name bind, scalar literal (=), `%name` (compare to a lexical value), list
# `[a b rest...]`, map/props `{^k p}` (open), and `(| & not)`. Node-shape/type
# patterns and typed `x : T` are deferred until the type system lands.

proc isSymbolP(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc isRestPattern(p: Value): bool =
  p.kind == vkSymbol and p.symVal.len > 3 and p.symVal.endsWith("...")

proc patternItems(target: Value): tuple[items: seq[Value], ok: bool] =
  case target.kind
  of vkList: (target.listItems, true)
  of vkNode: (target.body, true)
  else: (newSeq[Value](), false)

proc tryMatch(pat, target: Value, scope: Scope,
              binds: var Table[string, Value]): bool

proc matchSequence(pats, items: seq[Value], scope: Scope,
                   binds: var Table[string, Value]): bool =
  ## Positional match of a pattern sequence (commas dropped) against items,
  ## supporting a single trailing `name...` rest pattern. Used by both list
  ## patterns and node-body patterns.
  var ps: seq[Value]
  for p in pats:
    if not p.isSymbolP(","): ps.add p
  var restIdx = -1
  for i, p in ps:
    if p.isRestPattern:
      restIdx = i
      break
  if restIdx < 0:
    if ps.len != items.len: return false
    for i in 0 ..< ps.len:
      if not tryMatch(ps[i], items[i], scope, binds): return false
    return true
  let before = restIdx
  let after = ps.len - restIdx - 1
  if items.len < before + after: return false
  for i in 0 ..< before:
    if not tryMatch(ps[i], items[i], scope, binds): return false
  let restName = ps[restIdx].symVal[0 .. ^4]   # drop trailing "..."
  if restName != "_":
    var rest = newSeq[Value](items.len - before - after)
    for i in 0 ..< rest.len: rest[i] = items[before + i]
    binds[restName] = newList(rest)
  for i in 0 ..< after:
    if not tryMatch(ps[restIdx + 1 + i], items[items.len - after + i], scope, binds):
      return false
  true

proc tryMatch(pat, target: Value, scope: Scope,
              binds: var Table[string, Value]): bool =
  case pat.kind
  of vkSymbol:
    let name = pat.symVal
    if name == "_": return true            # wildcard
    binds[name] = target                   # bind
    true
  of vkInt, vkFloat, vkString, vkBool, vkChar, vkNil, vkVoid:
    equal(pat, target)                     # literal
  of vkList:
    let (items, ok) = patternItems(target)
    if not ok: return false
    matchSequence(pat.listItems, items, scope, binds)
  of vkMap:
    for key, vpat in pat.mapEntries:
      var fieldVal: Value
      case target.kind
      of vkMap:
        if not target.mapEntries.hasKey(key): return false
        fieldVal = target.mapEntries[key]
      of vkNode:
        if not target.props.hasKey(key): return false
        fieldVal = target.props[key]
      else: return false
      if not tryMatch(vpat, fieldVal, scope, binds): return false
    true
  of vkNode:
    if pat.head.kind == vkSymbol:
      case pat.head.symVal
      of "unquote":          # %name -> compare to a lexical value
        if pat.body.len != 1 or pat.body[0].kind != vkSymbol:
          raise newException(GeneError, "pattern %name expects a name")
        return equal(target, scope.lookup(pat.body[0].symVal))
      of "|":                # alternation
        for sub in pat.body:
          var trial = binds
          if tryMatch(sub, target, scope, trial):
            binds = trial
            return true
        return false
      of "&":                # conjunction
        for sub in pat.body:
          if not tryMatch(sub, target, scope, binds): return false
        return true
      of "not":              # negation, introduces no bindings
        if pat.body.len != 1:
          raise newException(GeneError, "pattern (not p) expects one pattern")
        var throwaway = binds
        return not tryMatch(pat.body[0], target, scope, throwaway)
      else: discard
    # General node-shape pattern `(Head ^k kp body...)`: head matched literally,
    # props open (mentioned keys required), body matched positionally.
    if target.kind != vkNode: return false
    var headOk = equal(pat.head, target.head)
    if not headOk and pat.head.kind == vkSymbol and target.head.kind == vkType:
      # `(Task ^id id)` against a Task instance: resolve the pattern head to a type
      var resolved: Value
      if scope.lookupOptional(pat.head.symVal, resolved):
        headOk = resolved.kind == vkType and target.head.isSubtypeOf(resolved)
    if not headOk: return false
    for key, vpat in pat.props:
      if not target.props.hasKey(key): return false
      if not tryMatch(vpat, target.props[key], scope, binds): return false
    matchSequence(pat.body, target.body, scope, binds)
  else:
    raise newException(GeneError, "unsupported pattern: " & print(pat))

proc forItems(coll: Value): seq[Value] =
  case coll.kind
  of vkList:
    for it in coll.listItems: result.add it
  of vkNode:
    for it in coll.body: result.add it
  of vkMap:
    for k, v in coll.mapEntries: result.add newList(@[newStr(k), v])
  of vkNil, vkVoid:
    discard
  else:
    raise newException(GeneError, "for: cannot iterate " & $coll.kind)

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

proc pop(stack: var seq[Value]): Value =
  if stack.len == 0:
    raise newException(GeneError, "VM stack underflow")
  result = stack[^1]
  stack.setLen(stack.len - 1)

proc registerImpl(scope: Scope, protocol, receiver: Value,
                  messages: sink Table[string, Value]) =
  if protocol.kind != vkProtocol:
    raise newException(GeneError, "impl target must be a protocol")
  if receiver.kind != vkType:
    raise newException(GeneError, "impl receiver must be a type")
  for name in protocol.protocolMessages.keys:
    if not messages.hasKey(name):
      raise newException(GeneError,
        "impl " & protocol.protocolName & " for " & receiver.typeName &
        " is missing message: " & name)
  for name in messages.keys:
    if not protocol.protocolMessages.hasKey(name):
      raise newException(GeneError,
        "protocol " & protocol.protocolName & " has no message: " & name)
  var s = scope
  while s != nil:
    for impl in s.impls:
      if same(impl.protocol, protocol) and same(impl.receiver, receiver):
        raise newException(GeneError,
          "duplicate visible impl " & protocol.protocolName &
          " for " & receiver.typeName)
    s = s.parent
  scope.impls.add ProtocolImpl(protocol: protocol, receiver: receiver,
                               messages: messages)

proc hasVisibleImpl(scope: Scope, protocol, receiver: Value): bool =
  var s = scope
  while s != nil:
    for impl in s.impls:
      if same(impl.protocol, protocol) and receiver.isSubtypeOf(impl.receiver):
        return true
    s = s.parent
  false

proc receiverType(value: Value): Value =
  if value.kind == vkNode and value.head.kind == vkType:
    value.head
  else:
    NIL

proc scopeChainContains(scope, target: Scope): bool =
  var s = scope
  while s != nil:
    if s == target:
      return true
    s = s.parent
  false

proc typeImplementsProtocol(scope: Scope, typ, protocol: Value): bool =
  if scope != nil and scope.hasVisibleImpl(protocol, typ):
    return true
  var t = typ
  while t.kind == vkType:
    let definingScope = t.typeScope
    if definingScope != nil and
        (scope == nil or not scope.scopeChainContains(definingScope)) and
        definingScope.hasVisibleImpl(protocol, typ):
      return true
    t = t.typeParent
  false

proc validateRequiredImpls(scope: Scope) =
  for typ in scope.requiredImplTypes:
    for protocol in typ.typeRequiredProtocols:
      if not scope.typeImplementsProtocol(typ, protocol):
        raise newException(GeneError,
          "type " & typ.typeName & " requires impl " & protocol.protocolName)

proc isErrorValue(scope: Scope, value: Value): bool =
  if value.kind != vkNode or value.head.kind != vkType:
    return false
  var errorProtocol: Value
  if scope == nil or not scope.lookupOptional("Error", errorProtocol) or
      errorProtocol.kind != vkProtocol:
    return false
  scope.typeImplementsProtocol(value.head, errorProtocol)

proc isErrorType(scope: Scope, typ: Value): bool =
  if typ.kind != vkType:
    return false
  var errorProtocol: Value
  if scope == nil or not scope.lookupOptional("Error", errorProtocol) or
      errorProtocol.kind != vkProtocol:
    return false
  scope.typeImplementsProtocol(typ, errorProtocol)

proc popCheckedErrorTypes(stack: var seq[Value], count: int,
                          scope: Scope): seq[Value] =
  result = newSeq[Value](count)
  if count > 0:
    for i in countdown(count - 1, 0):
      let typ = stack.pop()
      if not scope.isErrorType(typ):
        raise newException(GeneError, "^errors entries must be Error types")
      result[i] = typ

proc raiseFailedValue(value: Value) =
  var e: ref GeneError
  new(e)
  e.msg = "fail: " & print(value)
  e.errVal = value
  e.hasErrVal = true
  raise e

proc raiseMatchError(scope: Scope, message: string) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var head = newSym("MatchError")
  var matchError: Value
  if scope != nil and scope.lookupOptional("MatchError", matchError) and
      matchError.kind == vkType:
    head = matchError
  var e: ref MatchError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc collectProtocolMatches(scope: Scope, protocol, recvType, message: Value,
                            matches: var seq[Value]) =
  for impl in scope.impls:
    if same(impl.protocol, protocol) and recvType.isSubtypeOf(impl.receiver):
      if not impl.messages.hasKey(message.protocolMessageName):
        raise newException(GeneError,
          "impl " & protocol.protocolName & " for " & impl.receiver.typeName &
          " is missing message: " & message.protocolMessageName)
      matches.add impl.messages[message.protocolMessageName]

proc collectProtocolMatchesChain(scope: Scope, protocol, recvType, message: Value,
                                 matches: var seq[Value]) =
  var s = scope
  while s != nil:
    collectProtocolMatches(s, protocol, recvType, message, matches)
    s = s.parent

proc hasSeenScope(seen: openArray[Scope], scope: Scope): bool =
  for item in seen:
    if item == scope:
      return true
  false

proc collectProtocolMatchesExtra(scope, currentScope: Scope, protocol, recvType,
                                 message: Value, seen: var seq[Scope],
                                 matches: var seq[Value]) =
  var s = scope
  while s != nil:
    if not currentScope.scopeChainContains(s) and not seen.hasSeenScope(s):
      seen.add s
      collectProtocolMatches(s, protocol, recvType, message, matches)
    s = s.parent

proc resolveProtocolMessage(scope: Scope, message, receiver: Value): Value =
  if scope == nil:
    raise newException(GeneError,
      "protocol message '" & message.protocolMessageName &
      "' has no visible implementation scope")
  let protocol = message.protocolMessageProtocol
  let recvType = receiver.receiverType
  if recvType.kind != vkType:
    raise newException(GeneError,
      "protocol message '" & message.protocolMessageName &
      "' requires a typed receiver")
  var matches: seq[Value]
  collectProtocolMatchesChain(scope, protocol, recvType, message, matches)
  var seenExtraScopes: seq[Scope]
  var typ = recvType
  while typ.kind == vkType:
    let definingScope = typ.typeScope
    if definingScope != nil and not scope.scopeChainContains(definingScope):
      collectProtocolMatchesExtra(definingScope, scope, protocol, recvType, message,
                                  seenExtraScopes, matches)
    typ = typ.typeParent
  if matches.len == 0:
    raise newException(GeneError,
      "missing impl " & protocol.protocolName & " for " & recvType.typeName)
  if matches.len > 1:
    raise newException(GeneError,
      "ambiguous impl " & protocol.protocolName & " for " & recvType.typeName)
  matches[0]

proc run*(chunk: Chunk, scope: Scope, validateImplRequirements = true): Value =
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
      let errorTypes = stack.popCheckedErrorTypes(proto.errorTypeCount, scope)
      stack.add newFunction(proto.name, proto.params, proto, scope,
                            proto.checksErrors, errorTypes)
    of opMakeType:
      let proto = chunk.typeProtos[inst.intArg]
      let parent = stack.pop()
      if parent.kind != vkNil and parent.kind != vkType:
        raise newException(GeneError, "type ^is must be a type")
      var derivedProtocols = newSeq[Value](proto.deriveProtocolCount)
      if proto.deriveProtocolCount > 0:
        for i in countdown(proto.deriveProtocolCount - 1, 0):
          let protocol = stack.pop()
          if protocol.kind != vkProtocol:
            raise newException(GeneError, "type ^derive entries must be protocols")
          derivedProtocols[i] = protocol
      var requiredProtocols = newSeq[Value](proto.requiredImplCount)
      if proto.requiredImplCount > 0:
        for i in countdown(proto.requiredImplCount - 1, 0):
          let protocol = stack.pop()
          if protocol.kind != vkProtocol:
            raise newException(GeneError, "type ^impl entries must be protocols")
          requiredProtocols[i] = protocol
      let typ = newType(proto.name, parent, proto.fields, requiredProtocols, scope,
                        derivedProtocols, proto.deriveRequests)
      if proto.requiredImplCount > 0:
        scope.requiredImplTypes.add typ
      stack.add typ
    of opMakeProtocol:
      let proto = chunk.protocolProtos[inst.intArg]
      let protocol = newProtocol(proto.name, proto.messageNames)
      for _, message in protocol.protocolMessages:
        scope.define(message.protocolMessageName, message)
      stack.add protocol
    of opMakeImpl:
      let proto = chunk.implProtos[inst.intArg]
      var messageErrorTypes = newSeq[seq[Value]](proto.messages.len)
      if proto.messages.len > 0:
        for i in countdown(proto.messages.len - 1, 0):
          messageErrorTypes[i] =
            stack.popCheckedErrorTypes(proto.messages[i].fn.errorTypeCount, scope)
      let receiver = stack.pop()
      let protocol = stack.pop()
      var messages = initTable[string, Value]()
      for i, message in proto.messages:
        messages[message.name] =
          newFunction(message.fn.name, message.fn.params, message.fn, scope,
                      message.fn.checksErrors, messageErrorTypes[i])
      scope.registerImpl(protocol, receiver, messages)
      stack.add NIL
    of opMakeNamespace:
      # Run the ns body in a fresh child scope; its bindings become the
      # namespace's exports. Bind the namespace in the enclosing scope.
      let nsScope = newScope(scope)
      discard run(chunk.subchunks[inst.intArg], nsScope)
      let ns = newNamespace(inst.name, nsScope)
      scope.define(inst.name, ns)
      stack.add ns
    of opImport:
      let spec = chunk.imports[inst.intArg]
      var sourceNs: Value
      if spec.fromModule:
        sourceNs = loadModuleNamespace(resolveModulePath(spec.modulePath))
      else:
        # Namespace path: resolve segments against the current scope.
        sourceNs = scope.lookup(spec.nsSegments[0])
        for i in 1 ..< spec.nsSegments.len:
          if sourceNs.kind != vkNamespace:
            raise newException(GeneError,
              "import: '" & spec.nsSegments[0 ..< i].join("/") & "' is not a namespace")
          sourceNs = sourceNs.nsScope.vars.getOrDefault(spec.nsSegments[i], VOID)
      if sourceNs.kind != vkNamespace:
        raise newException(GeneError, "import source is not a namespace")
      if spec.alias.len > 0:
        scope.define(spec.alias, sourceNs)
      for sel in spec.selections:
        let v = sourceNs.nsScope.vars.getOrDefault(sel.name, VOID)
        if v.kind == vkVoid:
          raise newException(GeneError, "module/namespace has no export: " & sel.name)
        scope.define(sel.local, v)
      stack.add NIL
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
      stack.add applyCall(callee, args, named, scope)
    of opMatchBind:
      let target = stack.pop()
      var binds = initTable[string, Value]()
      if not tryMatch(chunk.constants[inst.intArg], target, scope, binds):
        raiseMatchError(scope, "destructuring pattern did not match")
      for k, v in binds: scope.define(k, v)
      stack.add target
    of opTryMatch:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in match")
      let target = stack[^1]                # peek; target survives for the next clause
      var binds = initTable[string, Value]()
      if tryMatch(chunk.constants[inst.intArg], target, scope, binds):
        for k, v in binds: scope.define(k, v)
        stack.add TRUE
      else:
        stack.add FALSE
    of opMatchFail:
      raiseMatchError(scope, "no matching pattern")
    of opForEach:
      let coll = stack.pop()
      let fp = chunk.forLoops[inst.intArg]
      for item in forItems(coll):
        let loopScope = newScope(scope)
        var binds = initTable[string, Value]()
        if not tryMatch(fp.pattern, item, loopScope, binds):
          raiseMatchError(loopScope, "for pattern did not match an item")
        for k, v in binds: loopScope.define(k, v)
        discard run(fp.body, loopScope)
      stack.add NIL
    of opTry:
      let tp = chunk.tries[inst.intArg]
      var resultVal = NIL
      try:
        try:
          resultVal = run(tp.body, scope, validateImplRequirements = false)
        except GeneError as e:       # recoverable; GenePanic is NOT a GeneError
          let errVal =
            if e.hasErrVal: e.errVal
            else:
              var props = initOrderedTable[string, Value]()
              props["message"] = newStr(e.msg)
              newNode(newSym("Error"), props = props)
          var handled = false
          for cl in tp.catches:
            var binds = initTable[string, Value]()
            if tryMatch(cl.pattern, errVal, scope, binds):
              for k, v in binds: scope.define(k, v)
              resultVal = run(cl.body, scope, validateImplRequirements = false)
              handled = true
              break
          if not handled:
            raise                    # re-raise; the finally still runs ensure
      finally:
        if tp.ensureBody != nil:
          discard run(tp.ensureBody, scope, validateImplRequirements = false)
      stack.add resultVal
    of opFail:
      let errVal = stack.pop()
      if not scope.isErrorValue(errVal):
        raise newException(GeneError, "fail expects an Error value")
      raiseFailedValue(errVal)
    of opJumpIfFalse:
      let cond = stack.pop()
      if not cond.isTruthy:
        ip = inst.intArg
    of opJump:
      ip = inst.intArg
    of opReturn:
      result = if stack.len > 0: stack.pop() else: NIL
      if validateImplRequirements:
        scope.validateRequiredImpls()
      return
  result = NIL
  if validateImplRequirements:
    scope.validateRequiredImpls()

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

proc typeExprLabel(expr: Value): string =
  if expr.kind == vkNil: "Any" else: expr.print()

proc raiseTypeError(where, expected: string, value: Value, scope: Scope) =
  let message = where & " expected " & expected & ", got " & $value.kind
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  props["where"] = newStr(where)
  props["expected"] = newStr(expected)
  props["actual"] = newStr($value.kind)
  var head = newSym("TypeError")
  var typeError: Value
  if scope != nil and scope.lookupOptional("TypeError", typeError) and
      typeError.kind == vkType:
    head = typeError
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc isInstanceOfType(value, expected: Value): bool =
  value.kind == vkNode and value.head.kind == vkType and
    value.head.isSubtypeOf(expected)

proc matchesBuiltinType(name: string, value: Value): tuple[known, ok: bool] =
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
  of "Int", "Integer", "Fixnum", "I8", "I16", "I32", "I64", "U8", "U16", "U32", "U64":
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
  of "Fn", "Function":
    (true, value.kind == vkFunction)
  of "Callable":
    (true, value.kind in {vkFunction, vkNativeFn, vkType, vkProtocolMessage} or
      (value.kind == vkNode and value.isSelector))
  of "Type":
    (true, value.kind == vkType)
  of "Protocol":
    (true, value.kind == vkProtocol)
  of "ProtocolMessage":
    (true, value.kind == vkProtocolMessage)
  of "Namespace":
    (true, value.kind == vkNamespace)
  else:
    (false, false)

proc matchesTypeExpr(expr, value: Value, scope: Scope): bool =
  if expr.kind == vkNil:
    return true
  case expr.kind
  of vkSymbol:
    let builtin = matchesBuiltinType(expr.symVal, value)
    if builtin.known:
      return builtin.ok
    var resolved: Value
    if scope.lookupOptional(expr.symVal, resolved) and resolved.kind == vkType:
      return value.isInstanceOfType(resolved)
    raise newException(GeneError, "unknown type annotation: " & expr.symVal)
  of vkNode:
    if expr.head.kind == vkSymbol:
      case expr.head.symVal
      of "|":
        for alt in expr.body:
          if matchesTypeExpr(alt, value, scope):
            return true
        return false
      of "opt":
        if expr.body.len != 1:
          raise newException(GeneError, "(opt T) expects one type")
        return value.kind == vkNil or matchesTypeExpr(expr.body[0], value, scope)
      of "List":
        if value.kind != vkList:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(List T) expects one item type")
        for item in value.listItems:
          if not matchesTypeExpr(expr.body[0], item, scope):
            return false
        return true
      of "Map", "PropMap":
        if value.kind != vkMap:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(Map T) expects one value type in this MVP")
        for _, item in value.mapEntries:
          if not matchesTypeExpr(expr.body[0], item, scope):
            return false
        return true
      else:
        discard
    raise newException(GeneError, "unsupported type annotation: " & expr.print())
  of vkType:
    value.isInstanceOfType(expr)
  else:
    raise newException(GeneError, "unsupported type annotation: " & expr.print())

proc checkBoundary(where: string, typeExpr, value: Value, scope: Scope) =
  if typeExpr.kind == vkNil:
    return
  if not matchesTypeExpr(typeExpr, value, scope):
    raiseTypeError(where, typeExpr.typeExprLabel, value, scope)

proc errorAllowed(allowed: openArray[Value], errVal: Value): bool =
  if errVal.kind != vkNode or errVal.head.kind != vkType:
    return false
  for typ in allowed:
    if errVal.head.isSubtypeOf(typ):
      return true
  false

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
    of vkProtocol:
      target.protocolMessages.getOrDefault(key, VOID)
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

proc applyCall(callee: Value, args: seq[Value], named: NamedArgs,
               dispatchScope: Scope = nil): Value =
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
      if proto.hasParamTypes and i < proto.paramTypes.len and
          proto.paramTypes[i].kind != vkNil:
        checkBoundary("parameter '" & positional[i] & "'", proto.paramTypes[i],
                      args[i], callScope)
      callScope.define(positional[i], args[i])
    for p in proto.namedParams:
      if named.hasArg(p.arg):
        let value = named.getArg(p.arg)
        if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
          checkBoundary("parameter '" & p.local & "'", p.typeExpr, value, callScope)
        callScope.define(p.local, value)
    for i in providedPositional ..< positional.len:
      let fallback = proto.positionalDefault(i)
      if not fallback.optional:
        raise newException(GeneError,
          "function '" & callee.fnName & "' missing positional argument: " & positional[i])
      let value = fallback.defaultValue(callScope)
      if proto.hasParamTypes and i < proto.paramTypes.len and
          proto.paramTypes[i].kind != vkNil:
        checkBoundary("parameter '" & positional[i] & "'", proto.paramTypes[i],
                      value, callScope)
      callScope.define(positional[i], value)
    if proto.restParam.len > 0:
      var rest = newSeq[Value](args.len - positional.len)
      for i in 0 ..< rest.len:
        rest[i] = args[positional.len + i]
      callScope.define(proto.restParam, newList(rest))
    for p in proto.namedParams:
      if not named.hasArg(p.arg):
        if p.defaultValue.optional:
          let value = p.defaultValue.defaultValue(callScope)
          if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
            checkBoundary("parameter '" & p.local & "'", p.typeExpr, value, callScope)
          callScope.define(p.local, value)
        else:
          raise newException(GeneError,
            "function '" & callee.fnName & "' missing named argument: " & p.arg)
    var resultValue: Value
    try:
      resultValue = run(proto.chunk, callScope)
    except GeneError as e:
      if not callee.fnChecksErrors:
        raise
      if e.hasErrVal and errorAllowed(callee.fnErrorTypes, e.errVal):
        raise
      raise newException(GeneError,
        "function '" & callee.fnName & "' raised an undeclared error")
    if proto.hasReturnType:
      checkBoundary("return from '" & callee.fnName & "'", proto.returnType,
                    resultValue, callScope)
    resultValue
  of vkType:
    # Construct a typed instance: a node with the type as head, validated props.
    if args.len != 0:
      raise newException(GeneError,
        "constructing " & callee.typeName & " takes named fields only")
    let fields = callee.typeFields
    var props = initOrderedTable[string, Value]()
    for f in fields:
      if named.hasArg(f.name):
        let value = named.getArg(f.name)
        let fieldScope = if f.scope == nil: callee.typeScope else: f.scope
        checkBoundary("field '" & f.name & "' for " & callee.typeName,
                      f.typeExpr, value, fieldScope)
        props[f.name] = value
      elif not f.optional:
        raise newException(GeneError,
          "missing required field '" & f.name & "' for " & callee.typeName)
    for key in named.names:
      var known = false
      for f in fields:
        if f.name == key:
          known = true
          break
      if not known:
        raise newException(GeneError, callee.typeName & " has no field '" & key & "'")
    newNode(callee, props = props)
  of vkProtocolMessage:
    if args.len == 0:
      raise newException(GeneError,
        "protocol message '" & callee.protocolMessageName & "' expects a receiver")
    let implFn = resolveProtocolMessage(dispatchScope, callee, args[0])
    applyCall(implFn, args, named, dispatchScope)
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

proc loadModuleNamespace(absPath: string): Value =
  ## Load, execute, and cache a module; return its root namespace. Modules run at
  ## most once (cache) and import cycles are rejected (loading set).
  if moduleCache.hasKey(absPath):
    return moduleCache[absPath]
  if absPath in moduleLoading:
    raise newException(GeneError, "import cycle detected at " & absPath)
  if not fileExists(absPath):
    raise newException(GeneError, "module not found: " & absPath)
  moduleLoading.incl absPath
  let src = readFile(absPath)
  let modScope = newGlobalScope()
  let savedDir = currentModuleDir
  currentModuleDir = parentDir(absPath)
  try:
    discard run(compileSource(src), modScope)
  finally:
    currentModuleDir = savedDir
    moduleLoading.excl absPath
  result = newNamespace(splitFile(absPath).name, modScope)
  moduleCache[absPath] = result
