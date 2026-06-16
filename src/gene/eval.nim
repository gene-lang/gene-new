## Tree-walking evaluator (design Section 3: callable-first evaluation).
##
## This is the first executable layer over the reader + value model. It is a
## direct AST interpreter, not the bytecode VM the design ultimately targets
## (Section 17) — that comes later. Scope is a simple lexical chain; the
## first-class `Env` of Section 11.1 is a later, richer concept.
##
## Supported now: self-evaluating literals, symbol lookup, the `do/if/var/set/fn/
## quote` special forms, callable-first application, and closures. Named args
## (props), pattern destructuring, macros, and modules are not handled yet.

import std/[tables, strutils]
import ./types
import ./reader
import ./equality   # `equal` for the `=` builtin
import ./printer    # `print` for displaying non-string values

type
  GeneError* = object of CatchableError

# ---------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------

proc newScope*(parent: Scope = nil): Scope =
  Scope(parent: parent, vars: initTable[string, Value]())

proc lookup(scope: Scope, name: string): Value =
  var s = scope
  while s != nil:
    if s.vars.hasKey(name): return s.vars[name]
    s = s.parent
  raise newException(GeneError, "undefined symbol: " & name)

proc define(scope: Scope, name: string, v: Value) =
  scope.vars[name] = v

proc assign(scope: Scope, name: string, v: Value) =
  var s = scope
  while s != nil:
    if s.vars.hasKey(name):
      s.vars[name] = v
      return
    s = s.parent
  raise newException(GeneError, "set of undefined symbol: " & name)

# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

proc eval*(node: Value, scope: Scope): Value

proc evalBody(body: openArray[Value], scope: Scope): Value =
  result = NIL
  for f in body:
    result = eval(f, scope)

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
      of ":": inc i, 2          # skip ':' and the following type token
      else:
        result.add it.symVal
        inc i
    else:
      inc i

proc apply(callee: Value, args: seq[Value]): Value =
  case callee.kind
  of vkNativeFn:
    callee.nativeImpl()(args)
  of vkFunction:
    let params = callee.fnParams
    if args.len != params.len:
      raise newException(GeneError,
        "function '" & callee.fnName & "' expects " & $params.len &
        " argument(s), got " & $args.len)
    let callScope = newScope(callee.fnScope)
    for i, p in params:
      callScope.define(p, args[i])
    evalBody(callee.fnBody, callScope)
  else:
    raise newException(GeneError, "value is not callable: " & $callee.kind)

proc evalIf(node: Value, scope: Scope): Value =
  let body = node.body
  if body.len == 0: return NIL
  let cond = eval(body[0], scope)
  # Full form: (if c (then ...) (elif c2 ...) (else ...))
  if body.len >= 2 and body[1].kind == vkNode and
     body[1].head.kind == vkSymbol and body[1].head.symVal == "then":
    if isTruthy(cond):
      return evalBody(body[1].body, scope)
    for i in 2 ..< body.len:
      let clause = body[i]
      if clause.kind != vkNode or clause.head.kind != vkSymbol: continue
      case clause.head.symVal
      of "elif":
        if clause.body.len >= 1 and isTruthy(eval(clause.body[0], scope)):
          return evalBody(clause.body[1 .. ^1], scope)
      of "else":
        return evalBody(clause.body, scope)
      else: discard
    return NIL
  # Compact form: (if cond then-expr else-expr)
  if isTruthy(cond):
    if body.len >= 2: eval(body[1], scope) else: NIL
  else:
    if body.len >= 3: eval(body[2], scope) else: NIL

proc evalVar(node: Value, scope: Scope): Value =
  let body = node.body
  if body.len == 0 or body[0].kind != vkSymbol:
    raise newException(GeneError, "var requires a name")
  let v = if body.len >= 2: eval(body[1], scope) else: NIL
  scope.define(body[0].symVal, v)
  v

proc evalSet(node: Value, scope: Scope): Value =
  let body = node.body
  if body.len < 2 or body[0].kind != vkSymbol:
    raise newException(GeneError, "set requires a name and a value")
  let v = eval(body[1], scope)
  scope.assign(body[0].symVal, v)
  v

proc evalFn(node: Value, scope: Scope): Value =
  let body = node.body
  var idx = 0
  var name = ""
  if body.len > 0 and body[0].kind == vkSymbol:
    name = body[0].symVal
    idx = 1
  if idx >= body.len or body[idx].kind != vkList:
    raise newException(GeneError, "fn requires a parameter vector")
  let params = paramNames(body[idx])
  let fnBody = if idx + 1 <= body.high: body[idx + 1 .. ^1] else: @[]
  newFunction(name, params, fnBody, scope)

proc evalNode(node: Value, scope: Scope): Value =
  let h = node.head
  if h.kind == vkSymbol:
    case h.symVal
    of "do": return evalBody(node.body, scope)
    of "if": return evalIf(node, scope)
    of "var": return evalVar(node, scope)
    of "set": return evalSet(node, scope)
    of "fn": return evalFn(node, scope)
    of "quote": return (if node.body.len >= 1: node.body[0] else: NIL)
    else: discard
  # Callable-first: evaluate head, evaluate positional args, apply.
  let callee = eval(h, scope)
  var args = newSeq[Value](node.body.len)
  for i, a in node.body:
    args[i] = eval(a, scope)
  apply(callee, args)

proc eval*(node: Value, scope: Scope): Value =
  case node.kind
  of vkSymbol:
    lookup(scope, node.symVal)
  of vkNode:
    evalNode(node, scope)
  of vkList:
    # Vector literal: evaluate each element, preserving mutability class.
    var items = newSeq[Value](node.listItems.len)
    for i, it in node.listItems:
      items[i] = eval(it, scope)
    newList(items, node.listImmutable)
  of vkMap:
    var entries = initOrderedTable[string, Value]()
    for k, val in node.mapEntries:
      entries[k] = eval(val, scope)
    newMap(entries, node.mapImmutable)
  else:
    node   # nil/void/bool/int/float/string/char/fn are self-evaluating

# ---------------------------------------------------------------------------
# Built-in functions
# ---------------------------------------------------------------------------

proc isNumber(v: Value): bool = v.kind == vkInt or v.kind == vkFloat
proc toFloat(v: Value): float64 = (if v.kind == vkInt: v.intVal.float64 else: v.floatVal)

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
  result.define("print", newNativeFn("print", biPrint))
  result.define("println", newNativeFn("println", biPrintln))

# ---------------------------------------------------------------------------
# Top-level helpers
# ---------------------------------------------------------------------------

proc evalAll*(src: string, scope: Scope): Value =
  ## Evaluate every top-level form in `src` in order; return the last result.
  result = NIL
  for form in readAll(src):
    result = eval(form, scope)

proc evalStr*(src: string): Value =
  ## Evaluate a program string in a fresh global scope.
  evalAll(src, newGlobalScope())
