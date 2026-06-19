## Stack VM for compiled Gene GIR chunks.

import std/[algorithm, math, os, sets, strutils, tables, unicode]
import ./[compiler, equality, gir, printer, reader, types]

type
  Application* = ref object of RuntimeContext
    builtins: Scope
    moduleCache: Table[string, Value]
    moduleLoading: HashSet[string]
    currentModuleDir: string
    packageRoot: string

proc raiseTypeError(where, expected: string, value: Value, scope: Scope)
proc matchesTypeExpr(expr, value: Value, scope: Scope): bool
proc adaptBoundary(where: string, typeExpr, value: Value, scope: Scope): Value
proc closeTypeExpr(expr: Value, scope: Scope): Value
proc typeImplementsProtocol(scope: Scope, typ, protocol: Value): bool
proc builtinBinding(scope: Scope, name: string): Value
proc resolveProtocolMessage(scope: Scope, message, receiver: Value): Value
proc isSendableValue(value: Value, scope: Scope,
                     seen: var HashSet[uint64]): bool
proc isSendableValue(value: Value, scope: Scope): bool
proc completedTaskFromError(e: ref GeneError): Value
proc completedTaskFromPanic(e: ref GenePanic): Value

# ---------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------

proc newScope*(parent: Scope = nil,
               application: RuntimeContext = nil): Scope =
  # Tables and seqs stay at Nim's zero-value empty state until a scope actually
  # needs named declarations, impls, or required protocol checks.
  let owner =
    if application != nil: application
    elif parent != nil: parent.application
    else: nil
  let budget =
    if parent != nil: parent.evalBudget
    else: nil
  Scope(application: owner, parent: parent, evalBudget: budget)

proc registerOwnedActor(scope: Scope, actor: Value) =
  var s = scope
  while s != nil:
    if s.ownsActors:
      s.ownedActors.add actor
      return
    s = s.parent

proc closeOwnedActors(scope: Scope) =
  if scope.ownedActors.len == 0:
    return
  for i in countdown(scope.ownedActors.high, 0):
    if scope.ownedActors[i].kind == vkActorRef:
      scope.ownedActors[i].closeActor()
  scope.ownedActors.setLen(0)

proc actorOwnerFailureStrategy(scope: Scope): ActorFailureStrategy =
  var s = scope
  while s != nil:
    if s.ownsActors:
      return s.actorFailureStrategy
    s = s.parent
  afsStop

proc supervisorStrategy(name: string): ActorFailureStrategy =
  case name
  of "restart": afsRestart
  of "stop": afsStop
  of "escalate": afsEscalate
  else:
    raise newException(GeneError, "unsupported supervisor strategy: " & name)

proc prepareSlots(scope: Scope, names: seq[string], mirror = false) =
  if names.len == 0:
    return
  scope.slots = newSeq[Value](names.len)
  scope.slotDefinedBits = 0
  if names.len > 64:
    scope.slotDefinedOverflow = newSeq[bool](names.len - 64)
  scope.slotNames = names
  scope.slotMirror = mirror

proc prepareChunkScope(scope: Scope, chunk: Chunk) =
  if scope.slots.len == 0 and chunk.localNames.len > 0:
    scope.prepareSlots(chunk.localNames, mirror = chunk.mirrorSlots)

proc checkSlot(scope: Scope, index: int, name: string) =
  if index < 0 or index >= scope.slots.len:
    raise newException(GeneError, "invalid local slot for symbol: " & name)

proc slotIndex(scope: Scope, name: string): int =
  for index, slotName in scope.slotNames:
    if slotName == name:
      return index
  -1

proc slotDefined(scope: Scope, index: int): bool =
  if index < 64:
    (scope.slotDefinedBits and (1'u64 shl index)) != 0
  else:
    scope.slotDefinedOverflow[index - 64]

proc markSlotDefined(scope: Scope, index: int) =
  if index < 64:
    scope.slotDefinedBits = scope.slotDefinedBits or (1'u64 shl index)
  else:
    scope.slotDefinedOverflow[index - 64] = true

proc hasTypeBinding(binding: TypeBinding): bool {.inline.} =
  binding.expr.kind != vkNil

proc assignmentValue(scope: Scope, name: string, v: Value,
                     binding: TypeBinding): Value =
  if binding.hasTypeBinding:
    adaptBoundary("set '" & name & "'", binding.expr, v, binding.scope)
  else:
    v

proc declareType(scope: Scope, name: string, typeExpr: Value) =
  let binding = TypeBinding(expr: typeExpr, scope: scope)
  let index = scope.slotIndex(name)
  if index >= 0:
    if scope.slotTypes.len < scope.slots.len:
      scope.slotTypes.setLen(scope.slots.len)
    scope.slotTypes[index] = binding
  else:
    scope.varTypes[name] = binding

proc storeSlot(scope: Scope, index: int, name: string, v: Value,
               requireExisting: bool) =
  scope.checkSlot(index, name)
  if requireExisting and not scope.slotDefined(index):
    raise newException(GeneError, "set of undefined symbol: " & name)
  if not requireExisting and scope.slotDefined(index):
    raise newException(GeneError, "duplicate binding: " & name)
  let value =
    if requireExisting and index < scope.slotTypes.len:
      scope.assignmentValue(name, v, scope.slotTypes[index])
    else:
      v
  let stored = functionForScopeStorage(value, scope)
  scope.slots[index] = stored
  if scope.slotMirror:
    scope.vars[name] = stored
  scope.markSlotDefined(index)

proc scopeAtDepth(scope: Scope, depth: int, name: string): Scope =
  result = scope
  for _ in 0 ..< depth:
    if result == nil:
      raise newException(GeneError, "undefined symbol: " & name)
    result = result.parent
  if result == nil:
    raise newException(GeneError, "undefined symbol: " & name)

proc storeNamedSlot(scope: Scope, name: string, v: Value,
                    requireExisting: bool): bool =
  if scope.slots.len == 0:
    return false
  let index = scope.slotIndex(name)
  if index < 0:
    return false
  if requireExisting and not scope.slotDefined(index):
    return false
  scope.storeSlot(index, name, v, requireExisting)
  true

proc loadNamedSlot(scope: Scope, name: string, value: var Value): bool =
  if scope.slots.len == 0:
    return false
  let index = scope.slotIndex(name)
  if index >= 0 and scope.slotDefined(index):
    value = scope.slots[index]
    return true
  false

proc syncSlot(scope: Scope, name: string, v: Value) =
  for index, slotName in scope.slotNames:
    if slotName == name:
      scope.slots[index] = v
      scope.markSlotDefined(index)
      return

proc loadSlot(scope: Scope, index: int, name: string): Value =
  scope.checkSlot(index, name)
  if not scope.slotDefined(index):
    raise newException(GeneError, "undefined symbol: " & name)
  scope.slots[index]

proc loadSlotAt(scope: Scope, depth, index: int, name: string): Value =
  scope.scopeAtDepth(depth, name).loadSlot(index, name)

proc defineSlot(scope: Scope, index: int, name: string, v: Value) =
  if scope.vars.hasKey(name):
    raise newException(GeneError, "duplicate binding: " & name)
  scope.storeSlot(index, name, v, requireExisting = false)

proc assignSlot(scope: Scope, index: int, name: string, v: Value) =
  scope.storeSlot(index, name, v, requireExisting = true)

proc assignSlotAt(scope: Scope, depth, index: int, name: string, v: Value) =
  scope.scopeAtDepth(depth, name).assignSlot(index, name, v)

proc lookup*(scope: Scope, name: string): Value =
  var s = scope
  while s != nil:
    if s.loadNamedSlot(name, result): return
    if s.vars.hasKey(name): return s.vars[name]
    s = s.parent
  raise newException(GeneError, "undefined symbol: " & name)

proc lookupOptional*(scope: Scope, name: string, value: var Value): bool =
  var s = scope
  while s != nil:
    if s.loadNamedSlot(name, value):
      return true
    if s.vars.hasKey(name):
      value = s.vars[name]
      return true
    s = s.parent
  false

proc define*(scope: Scope, name: string, v: Value) =
  if scope.storeNamedSlot(name, v, requireExisting = false):
    return
  if scope.vars.hasKey(name):
    raise newException(GeneError, "duplicate binding: " & name)
  scope.vars[name] = functionForScopeStorage(v, scope)

proc defineOverlay(scope: Scope, name: string, v: Value) =
  ## Internal overlay write for Env materialization: child Env bindings should
  ## shadow copied parent bindings without acting like source declarations.
  scope.vars[name] = v

proc assign*(scope: Scope, name: string, v: Value) =
  var s = scope
  while s != nil:
    if s.storeNamedSlot(name, v, requireExisting = true):
      return
    if s.vars.hasKey(name):
      let value =
        if s.varTypes.hasKey(name): s.assignmentValue(name, v, s.varTypes[name])
        else: v
      let stored = functionForScopeStorage(value, s)
      s.vars[name] = stored
      s.syncSlot(name, stored)
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

proc applyCall(callee: Value, args: openArray[Value], named: NamedArgs,
               dispatchScope: Scope = nil): Value
proc typeExprLabel(expr: Value): string

# ---------------------------------------------------------------------------
# Built-in functions
# ---------------------------------------------------------------------------

proc isNumber(v: Value): bool = v.kind == vkInt or v.kind == vkFloat
proc toFloat(v: Value): float64 = (if v.kind == vkInt: v.intToFloat else: v.floatVal)
proc isSymbol(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc isSelector(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("select")

proc requireNums(name: string, args: openArray[Value]) =
  for a in args:
    if not a.isNumber:
      raise newException(GeneError, name & " expects numbers, got " & $a.kind)

proc requireInt64(name: string, value: Value): int64 =
  if value.kind != vkInt:
    raise newException(GeneError, name & " expects an Int")
  try:
    value.intVal
  except FieldDefect:
    raise newException(GeneError, name & " expects an Int in int64 range")

proc biAdd(args: openArray[Value]): Value {.nimcall.} =
  requireNums("+", args)
  var allInt = true
  for a in args:
    if a.kind == vkFloat: allInt = false
  if allInt:
    if args.len == 0:
      return newInt(0)
    var s = args[0]
    for i in 1 ..< args.len: s = intAdd(s, args[i])
    s
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
    return (if allInt: intNeg(args[0]) else: newFloat(-args[0].toFloat))
  if allInt:
    var s = args[0]
    for i in 1 ..< args.len: s = intSub(s, args[i])
    s
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
    if args.len == 0:
      return newInt(1)
    var s = args[0]
    for i in 1 ..< args.len: s = intMul(s, args[i])
    s
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
    var s = args[0]
    for i in 1 ..< args.len:
      if args[i].intIsZero: raise newException(GeneError, "division by zero")
      s = intDiv(s, args[i])
    s
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
      let ok =
        if args[i-1].kind == vkInt and args[i].kind == vkInt:
          op(intCompare(args[i-1], args[i]), 0)
        else:
          op(args[i-1].toFloat, args[i].toFloat)
      if not ok: return FALSE
    TRUE)

proc biEq(args: openArray[Value]): Value {.nimcall.} =
  for i in 1 ..< args.len:
    if not equal(args[i-1], args[i]): return FALSE
  TRUE

proc biSame(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "same? expects 2 arguments, got " & $args.len)
  newBool(same(args[0], args[1]))

proc biHash(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "hash expects 1 argument, got " & $args.len)
  if not isHashStable(args[0]):
    raise newException(GeneError, "hash expects a hash-stable value")
  newInt(int64(hash(args[0])))

proc biNot(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 1: raise newException(GeneError, "not expects 1 argument")
  newBool(not isTruthy(args[0]))

proc requireOne(name: string, args: openArray[Value]) =
  if args.len != 1:
    raise newException(GeneError, name & " expects 1 argument, got " & $args.len)

proc requireStr(name: string, value: Value) =
  if value.kind != vkString:
    raise newException(GeneError, name & " expects a Str")

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

proc requireCell(name: string, value: Value) =
  if value.kind != vkCell:
    raise newException(GeneError, name & " expects a Cell")

proc biCell(args: openArray[Value]): Value {.nimcall.} =
  requireOne("cell", args)
  newCell(args[0])

proc biCellGet(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Cell/get", args)
  requireCell("Cell/get", args[0])
  args[0].cellValue

proc biCellSet(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Cell/set expects 2 arguments, got " & $args.len)
  requireCell("Cell/set", args[0])
  args[0].setCellValue(args[1])
  args[1]

proc biCellSwap(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Cell/swap expects 2 arguments, got " & $args.len)
  requireCell("Cell/swap", args[0])
  let old = args[0].cellValue
  args[0].setCellValue(args[1])
  old

proc biCellUpdate(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Cell/update expects 2 arguments, got " & $args.len)
  requireCell("Cell/update", args[0])
  var callArgs = [args[0].cellValue]
  let next = applyCall(args[1], callArgs, NamedArgs())
  args[0].setCellValue(next)
  next

proc requireAtomicCell(name: string, value: Value) =
  if value.kind != vkAtomicCell:
    raise newException(GeneError, name & " expects an AtomicCell")

proc biAtomicCell(args: openArray[Value]): Value {.nimcall.} =
  requireOne("atomic-cell", args)
  newAtomicCell(args[0])

proc biAtomicCellLoad(args: openArray[Value]): Value {.nimcall.} =
  requireOne("AtomicCell/load", args)
  requireAtomicCell("AtomicCell/load", args[0])
  args[0].atomicCellValue

proc biAtomicCellStore(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "AtomicCell/store expects 2 arguments, got " & $args.len)
  requireAtomicCell("AtomicCell/store", args[0])
  args[0].setAtomicCellValue(args[1])
  args[1]

proc biAtomicCellSwap(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "AtomicCell/swap expects 2 arguments, got " & $args.len)
  requireAtomicCell("AtomicCell/swap", args[0])
  let old = args[0].atomicCellValue
  args[0].setAtomicCellValue(args[1])
  old

proc biAtomicCellCompareExchange(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "AtomicCell/compare-exchange expects 3 arguments, got " & $args.len)
  requireAtomicCell("AtomicCell/compare-exchange", args[0])
  if same(args[0].atomicCellValue, args[1]):
    args[0].setAtomicCellValue(args[2])
    TRUE
  else:
    FALSE

proc requireTask(name: string, value: Value) =
  if value.kind != vkTask:
    raise newException(GeneError, name & " expects a Task")

proc biTaskCancel(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Task/cancel", args)
  requireTask("Task/cancel", args[0])
  args[0].cancelTask()
  NIL

proc requireChannel(name: string, value: Value) =
  if value.kind != vkChannel:
    raise newException(GeneError, name & " expects a Channel")

proc raiseChannelClosed(scope: Scope) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr("channel is closed")
  var head = newSym("ChannelClosed")
  var closedType: Value
  if scope != nil and scope.lookupOptional("ChannelClosed", closedType) and
      closedType.kind == vkType:
    head = closedType
  var e: ref GeneError
  new(e)
  e.msg = "channel is closed"
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc nativeNamedIndex(call: ptr NativeCall, name: string): int =
  if call == nil:
    return -1
  for i, key in call[].namedNames:
    if key == name:
      return i
  -1

proc channelCapacityArg(args: openArray[Value], call: ptr NativeCall): int =
  if args.len != 0:
    raise newException(GeneError, "channel expects no positional arguments")
  result = 16
  if call != nil:
    for name in call[].namedNames:
      if name != "capacity":
        raise newException(GeneError, "channel got unexpected named argument: " & name)
    let index = nativeNamedIndex(call, "capacity")
    if index >= 0:
      let raw = requireInt64("channel capacity", call[].namedValues[index])
      if raw > int64(high(int)):
        raise newException(GeneError, "channel capacity is too large")
      result = int(raw)
  if result <= 0:
    raise newException(GeneError, "channel capacity must be positive")

proc biChannel(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  newChannel(channelCapacityArg(args, call))

proc checkedChannelItem(channel, item: Value, where: string,
                        fallbackScope: Scope): Value =
  let itemType = channel.channelItemType
  if itemType.kind == vkNil:
    return item
  let itemScope =
    if channel.channelItemScope == nil: fallbackScope
    else: channel.channelItemScope
  adaptBoundary(where, itemType, item, itemScope)

proc checkedChannelSendItem(channel, item: Value, where: string,
                            fallbackScope: Scope): Value =
  result = checkedChannelItem(channel, item, where, fallbackScope)
  if not isSendableValue(result, fallbackScope):
    raiseTypeError(where, "Send", result, fallbackScope)

proc biChannelSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Channel/send expects 2 arguments, got " & $args.len)
  requireChannel("Channel/send", args[0])
  if args[0].channelClosed:
    raiseChannelClosed(if call == nil: nil else: call[].dispatchScope)
  if args[0].channelFull:
    raise newException(GeneError, "Channel/send would suspend on a full channel")
  let scope = if call == nil: nil else: call[].dispatchScope
  args[0].pushChannel(checkedChannelSendItem(args[0], args[1],
                                             "Channel/send item", scope))
  NIL

proc biChannelTrySend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Channel/try-send expects 2 arguments, got " & $args.len)
  requireChannel("Channel/try-send", args[0])
  if args[0].channelClosed or args[0].channelFull:
    return FALSE
  let scope = if call == nil: nil else: call[].dispatchScope
  args[0].pushChannel(checkedChannelSendItem(args[0], args[1],
                                             "Channel/try-send item", scope))
  TRUE

proc biChannelRecv(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/recv", args)
  requireChannel("Channel/recv", args[0])
  if args[0].channelLen > 0:
    let scope = if call == nil: nil else: call[].dispatchScope
    return checkedChannelItem(args[0], args[0].popChannel(),
                              "Channel/recv item", scope)
  if args[0].channelClosed:
    raiseChannelClosed(if call == nil: nil else: call[].dispatchScope)
  raise newException(GeneError, "Channel/recv would suspend on an empty channel")

proc biChannelTryRecv(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/try-recv", args)
  requireChannel("Channel/try-recv", args[0])
  if args[0].channelLen == 0:
    return VOID
  let scope = if call == nil: nil else: call[].dispatchScope
  checkedChannelItem(args[0], args[0].popChannel(), "Channel/try-recv item",
                     scope)

proc biChannelClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/close", args)
  requireChannel("Channel/close", args[0])
  args[0].closeChannel()
  NIL

proc requireActor(name: string, value: Value) =
  if value.kind != vkActorRef:
    raise newException(GeneError, name & " expects an ActorRef")

proc raiseActorClosed(scope: Scope) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr("actor is closed")
  var head = newSym("ActorClosed")
  var closedType: Value
  if scope != nil and scope.lookupOptional("ActorClosed", closedType) and
      closedType.kind == vkType:
    head = closedType
  var e: ref GeneError
  new(e)
  e.msg = "actor is closed"
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc actorErrorValue(scope: Scope, message: string): Value =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var head = newSym("ActorError")
  var actorError: Value
  if scope != nil and scope.lookupOptional("ActorError", actorError) and
      actorError.kind == vkType:
    head = actorError
  newNode(head, props = props)

proc completedActorErrorTask(scope: Scope, message: string): Value =
  newFailedTask(message, actorErrorValue(scope, message), hasValue = true)

proc actorMailboxArg(call: ptr NativeCall): int =
  result = 16
  if call == nil:
    return
  let index = nativeNamedIndex(call, "mailbox")
  if index >= 0:
    let raw = requireInt64("actor/spawn mailbox", call[].namedValues[index])
    if raw > int64(high(int)):
      raise newException(GeneError, "actor/spawn mailbox is too large")
    result = int(raw)
  if result <= 0:
    raise newException(GeneError, "actor/spawn mailbox must be positive")

proc actorNamedValue(call: ptr NativeCall, name: string): Value =
  let index = nativeNamedIndex(call, name)
  if index < 0:
    raise newException(GeneError, "actor/spawn missing named argument: " & name)
  call[].namedValues[index]

proc actorOptionalNamedValue(call: ptr NativeCall, name: string): Value =
  let index = nativeNamedIndex(call, name)
  if index < 0: NIL else: call[].namedValues[index]

proc actorDispatchScope(call: ptr NativeCall): Scope =
  if call == nil: nil else: call[].dispatchScope

proc checkActorSpawnNames(call: ptr NativeCall) =
  if call == nil:
    return
  for name in call[].namedNames:
    if name notin ["mailbox", "init", "handle", "type"]:
      raise newException(GeneError,
        "actor/spawn got unexpected named argument: " & name)

proc checkedActorMessage(actor, message: Value, where: string,
                         scope: Scope): Value =
  let messageType = actor.actorMessageType
  result =
    if messageType.kind == vkNil: message
    else: adaptBoundary(where, messageType, message, scope)
  if not isSendableValue(result, scope):
    raiseTypeError(where, "Send", result, scope)

proc requireReplyTo(name: string, value: Value) =
  if value.kind != vkReplyTo:
    raise newException(GeneError, name & " expects a ReplyTo")

proc checkedReplyValue(reply, value: Value, where: string,
                       fallbackScope: Scope): Value =
  let resultType = reply.replyToResultType
  let resultScope =
    if reply.replyToResultScope == nil: fallbackScope
    else: reply.replyToResultScope
  result =
    if resultType.kind == vkNil: value
    else: adaptBoundary(where, resultType, value, resultScope)
  if not isSendableValue(result, fallbackScope):
    raiseTypeError(where, "Send", result, fallbackScope)

proc biReplyToSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "ReplyTo/send expects 2 arguments, got " & $args.len)
  requireReplyTo("ReplyTo/send", args[0])
  if args[0].replyToSent:
    raise newException(GeneError, "reply has already been sent")
  let scope = actorDispatchScope(call)
  args[0].sendReplyTo(checkedReplyValue(args[0], args[1],
                                        "ReplyTo/send value", scope))
  NIL

proc pumpActor(actor: Value, scope: Scope) =
  if actor.actorProcessing:
    return
  actor.setActorProcessing(true)
  try:
    while actor.actorQueueLen > 0 and not actor.actorClosed:
      let message = actor.popActorMessage()
      try:
        var args = [newActorContext(actor), actor.actorState, message]
        let step = applyCall(actor.actorHandler, args, NamedArgs(), scope)
        if step.kind != vkActorStep:
          raiseTypeError("actor handler return", "ActorStep", step, scope)
        if step.actorStepContinue:
          actor.setActorState(step.actorStepState)
        else:
          actor.closeActor()
      except GenePanic:
        actor.closeActor()
        raise
      except CatchableError:
        if actor.actorFailureStrategy == afsRestart:
          let initFn = actor.actorRestartInit
          if initFn.kind == vkNil:
            actor.closeActor()
            raise
          try:
            actor.setActorState(applyCall(initFn, [], NamedArgs(), scope))
          except GenePanic:
            actor.closeActor()
            raise
          except CatchableError:
            actor.closeActor()
            raise
        else:
          actor.closeActor()
          raise
  finally:
    actor.setActorProcessing(false)

proc biActorSpawn(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "actor/spawn expects no positional arguments")
  checkActorSpawnNames(call)
  let scope = actorDispatchScope(call)
  let initFn = actorNamedValue(call, "init")
  let handler = actorNamedValue(call, "handle")
  let messageType = actorOptionalNamedValue(call, "type")
  let closedMessageType =
    if messageType.kind == vkNil: NIL else: closeTypeExpr(messageType, scope)
  let failureStrategy =
    if scope == nil: afsStop else: scope.actorOwnerFailureStrategy()
  let restartInit =
    if failureStrategy == afsRestart: initFn else: NIL
  let state = applyCall(initFn, [], NamedArgs(), scope)
  result = newActorRef(actorMailboxArg(call), state, handler, closedMessageType,
                       restartInit, failureStrategy)
  if scope != nil:
    scope.registerOwnedActor(result)

proc biActorSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/send expects 2 arguments, got " & $args.len)
  requireActor("actor/send", args[0])
  let scope = actorDispatchScope(call)
  if args[0].actorClosed:
    raiseActorClosed(scope)
  if args[0].actorFull:
    raise newException(GeneError, "actor/send would suspend on a full mailbox")
  args[0].pushActorMessage(checkedActorMessage(args[0], args[1],
                                               "actor/send message", scope))
  args[0].pumpActor(scope)
  NIL

proc biActorTrySend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/try-send expects 2 arguments, got " & $args.len)
  requireActor("actor/try-send", args[0])
  if args[0].actorClosed or args[0].actorFull:
    return FALSE
  let scope = actorDispatchScope(call)
  args[0].pushActorMessage(checkedActorMessage(args[0], args[1],
                                               "actor/try-send message", scope))
  args[0].pumpActor(scope)
  TRUE

proc biActorAsk(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/ask expects 2 arguments, got " & $args.len)
  requireActor("actor/ask", args[0])
  let scope = actorDispatchScope(call)
  let reply = newReplyTo()
  try:
    if args[0].actorClosed:
      raiseActorClosed(scope)
    if args[0].actorFull:
      raise newException(GeneError, "actor/ask would suspend on a full mailbox")
    var buildArgs = [reply]
    let message = applyCall(args[1], buildArgs, NamedArgs(), scope)
    args[0].pushActorMessage(checkedActorMessage(args[0], message,
                                                 "actor/ask message", scope))
    args[0].pumpActor(scope)
    if not reply.replyToSent:
      return completedActorErrorTask(scope, "actor/ask did not receive a reply")
    newCompletedTask(reply.replyToResult)
  except GeneError as e:
    completedTaskFromError(e)
  except GenePanic as e:
    completedTaskFromPanic(e)

proc biActorContinue(args: openArray[Value]): Value {.nimcall.} =
  requireOne("actor/continue", args)
  newActorContinue(args[0])

proc biActorStop(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "actor/stop expects no arguments")
  newActorStop()

proc requireStream(name: string, value: Value) =
  if value.kind != vkStream:
    raise newException(GeneError, name & " expects a Stream")

proc checkedStreamItem(stream, item: Value, where: string): Value =
  let itemType = stream.streamItemType
  if itemType.kind != vkNil:
    let itemScope = stream.streamItemScope
    if not matchesTypeExpr(itemType, item, itemScope):
      raiseTypeError(where, itemType.typeExprLabel, item, itemScope)
  item

proc checkedStreamPeek(stream: Value, where: string): Value =
  checkedStreamItem(stream, stream.streamPeek, where)

proc checkedStreamNext(stream: Value, where: string): Value =
  result = checkedStreamPeek(stream, where)
  discard stream.streamNext

proc requireNamespace(name: string, value: Value) =
  if value.kind != vkNamespace:
    raise newException(GeneError, name & " expects a Namespace")

proc requireModule(name: string, value: Value) =
  if value.kind != vkModule:
    raise newException(GeneError, name & " expects a Module")

proc requireEnv(name: string, value: Value) =
  if value.kind != vkEnv:
    raise newException(GeneError, name & " expects an Env")

proc raiseEndOfStream() =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr("end of stream")
  var e: ref GeneError
  new(e)
  e.msg = "end of stream"
  e.errVal = newNode(newSym("EndOfStream"), props = props)
  e.hasErrVal = true
  raise e

proc builtInTypeHead(scope: Scope, name: string): Value =
  var root = scope
  while root != nil and root.parent != nil:
    root = root.parent
  if root != nil:
    var typ: Value
    if root.lookupOptional(name, typ) and typ.kind == vkType:
      return typ
  newSym(name)

proc raiseReaderError(name, message, typeName: string, scope: Scope) =
  let fullMessage = name & ": " & message
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(fullMessage)
  var e: ref GeneError
  new(e)
  e.msg = fullMessage
  e.errVal = newNode(builtInTypeHead(scope, typeName), props = props)
  e.hasErrVal = true
  raise e

proc readFormsFromString(name: string, value: Value, scope: Scope): seq[Value] =
  if value.kind != vkString:
    raise newException(GeneError, name & " expects a Str")
  try:
    result = readAll(value.strVal)
  except ReadError as e:
    raiseReaderError(name, e.msg, "ParseError", scope)

proc biReadOne(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("read-one", args)
  let scope = if call == nil: nil else: call.dispatchScope
  let forms = readFormsFromString("read-one", args[0], scope)
  if forms.len == 0:
    return NIL
  if forms.len > 1:
    raise newException(GeneError, "read-one expects one form, got " & $forms.len)
  forms[0]

proc biReadAll(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("read-all", args)
  let scope = if call == nil: nil else: call.dispatchScope
  newStream(readFormsFromString("read-all", args[0], scope))

proc tokenValue(token: Token, tokenType: Value): Value =
  var props = initOrderedTable[string, Value]()
  props["kind"] = newSym(token.kind.tokenKindName)
  props["lexeme"] = newStr(token.lexeme)
  props["line"] = newInt(int64(token.line))
  props["col"] = newInt(int64(token.col))
  newNode(tokenType, props = props, immutable = true)

proc biLexAll(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("lex-all", args)
  if args[0].kind != vkString:
    raise newException(GeneError, "lex-all expects a Str")
  let scope = if call == nil: nil else: call.dispatchScope
  let tokenType = builtInTypeHead(scope, "Token")
  var tokens: seq[Value]
  try:
    for token in lexAll(args[0].strVal):
      tokens.add token.tokenValue(tokenType)
  except ReadError as e:
    raiseReaderError("lex-all", e.msg, "LexError", scope)
  newTypedStream(tokens, tokenType, newSym("Never"), scope)

proc biToStream(args: openArray[Value]): Value {.nimcall.} =
  requireOne("to_stream", args)
  if args[0].kind != vkList:
    raise newException(GeneError, "to_stream expects a List")
  var items: seq[Value]
  for item in args[0].listItems:
    items.add item
  newStream(items)

proc biToPairsStream(args: openArray[Value]): Value {.nimcall.} =
  requireOne("to_pairs_stream", args)
  if args[0].kind != vkMap:
    raise newException(GeneError, "to_pairs_stream expects a Map")
  var pairs: seq[Value]
  for key, value in args[0].mapEntries:
    pairs.add newList(@[newSym(key), value])
  newStream(pairs)

proc biStreamHasNext(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Stream/has_next", args)
  requireStream("Stream/has_next", args[0])
  newBool(args[0].streamHasNext)

proc biStreamPeek(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Stream/peek", args)
  requireStream("Stream/peek", args[0])
  if not args[0].streamHasNext:
    raiseEndOfStream()
  checkedStreamPeek(args[0], "Stream/peek item")

proc biStreamNext(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Stream/next", args)
  requireStream("Stream/next", args[0])
  if not args[0].streamHasNext:
    raiseEndOfStream()
  checkedStreamNext(args[0], "Stream/next item")

proc biStreamClose(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Stream/close", args)
  requireStream("Stream/close", args[0])
  args[0].closeStream()
  NIL

proc copyItems(items: openArray[Value]): seq[Value] =
  result = newSeq[Value](items.len)
  for i, item in items:
    result[i] = item

proc copyEntries(entries: PropTable): PropTable =
  result = initOrderedTable[string, Value]()
  for key, val in entries:
    result[key] = val

proc freezeValue(value: Value): Value
proc thawValue(value: Value): Value

proc freezeEntries(entries: PropTable): PropTable =
  result = initOrderedTable[string, Value]()
  for key, val in entries:
    result[key] = freezeValue(val)

proc thawEntries(entries: PropTable): PropTable =
  result = initOrderedTable[string, Value]()
  for key, val in entries:
    result[key] = thawValue(val)

proc freezeRejectName(value: Value): string =
  case value.kind
  of vkFunction: "Fn"
  of vkNativeFn: "NativeFn"
  of vkNamespace: "Namespace"
  of vkModule: "Module"
  of vkEnv: "Env"
  of vkCell: "Cell"
  of vkAtomicCell: "AtomicCell"
  of vkStream: "Stream"
  of vkTask: "Task"
  of vkChannel: "Channel"
  of vkActorRef: "ActorRef"
  of vkActorContext: "ActorContext"
  of vkActorStep: "ActorStep"
  of vkReplyTo: "ReplyTo"
  else: $value.kind

proc freezeValue(value: Value): Value =
  case value.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkChar, vkSymbol,
     vkType, vkProtocol, vkProtocolMessage:
    value
  of vkList:
    var items = newSeq[Value](value.listItems.len)
    for i, item in value.listItems:
      items[i] = freezeValue(item)
    newList(items, immutable = true)
  of vkMap:
    newMap(freezeEntries(value.mapEntries), immutable = true)
  of vkNode:
    var body = newSeq[Value](value.body.len)
    for i, item in value.body:
      body[i] = freezeValue(item)
    newNode(freezeValue(value.head),
            props = freezeEntries(value.props),
            body = body,
            meta = freezeEntries(value.meta),
            immutable = true)
  of vkFunction, vkNativeFn, vkNamespace, vkModule, vkEnv, vkCell,
     vkAtomicCell, vkStream, vkTask, vkChannel, vkActorRef, vkActorContext,
     vkActorStep, vkReplyTo:
    raise newException(GeneError, "freeze cannot freeze " & freezeRejectName(value))

proc thawValue(value: Value): Value =
  case value.kind
  of vkList:
    var items = newSeq[Value](value.listItems.len)
    for i, item in value.listItems:
      items[i] = thawValue(item)
    newList(items, immutable = false)
  of vkMap:
    newMap(thawEntries(value.mapEntries), immutable = false)
  of vkNode:
    var body = newSeq[Value](value.body.len)
    for i, item in value.body:
      body[i] = thawValue(item)
    newNode(thawValue(value.head),
            props = thawEntries(value.props),
            body = body,
            meta = thawEntries(value.meta),
            immutable = false)
  else:
    value

proc biFreezeShallow(args: openArray[Value]): Value {.nimcall.} =
  requireOne("freeze-shallow", args)
  case args[0].kind
  of vkList:
    newList(copyItems(args[0].listItems), immutable = true)
  of vkMap:
    newMap(copyEntries(args[0].mapEntries), immutable = true)
  of vkNode:
    newNode(args[0].head,
            props = copyEntries(args[0].props),
            body = copyItems(args[0].body),
            meta = copyEntries(args[0].meta),
            immutable = true)
  else:
    args[0]

proc biFreeze(args: openArray[Value]): Value {.nimcall.} =
  requireOne("freeze", args)
  freezeValue(args[0])

proc biThaw(args: openArray[Value]): Value {.nimcall.} =
  requireOne("thaw", args)
  thawValue(args[0])

proc keySegment(name: string, segment: Value): string =
  case segment.kind
  of vkSymbol:
    segment.symVal
  of vkString:
    segment.strVal
  else:
    raise newException(GeneError,
      name & " expects a symbol/string path segment, got " & $segment.kind)

proc sortedBindingNames(scope: Scope): seq[string] =
  for key in scope.vars.keys:
    result.add key
  result.sort()

proc declarationKind*(value: Value): string =
  case value.kind
  of vkNil: "Nil"
  of vkVoid: "Void"
  of vkBool: "Bool"
  of vkInt: "Int"
  of vkFloat: "Float"
  of vkString: "Str"
  of vkChar: "Char"
  of vkSymbol: "Sym"
  of vkList: "List"
  of vkMap: "Map"
  of vkNode: "Node"
  of vkFunction: "Fn"
  of vkNativeFn: "NativeFn"
  of vkNamespace: "Namespace"
  of vkModule: "Module"
  of vkEnv: "Env"
  of vkCell: "Cell"
  of vkAtomicCell: "AtomicCell"
  of vkStream: "Stream"
  of vkTask: "Task"
  of vkChannel: "Channel"
  of vkActorRef: "ActorRef"
  of vkActorContext: "ActorContext"
  of vkActorStep: "ActorStep"
  of vkReplyTo: "ReplyTo"
  of vkType: "Type"
  of vkProtocol: "Protocol"
  of vkProtocolMessage: "ProtocolMessage"

proc exportedBinding(ns: Value, name: string): Value =
  if ns.kind != vkNamespace:
    return VOID
  if ns.nsIsModuleRoot and name == "this-mod":
    return VOID
  ns.nsScope.vars.getOrDefault(name, VOID)

proc namespaceDeclarationNodes(ns: Value): seq[Value] =
  for name in sortedBindingNames(ns.nsScope):
    if ns.nsIsModuleRoot and name == "this-mod":
      continue
    let value = ns.nsScope.vars[name]
    var props = initOrderedTable[string, Value]()
    props["name"] = newStr(name)
    props["kind"] = newStr(declarationKind(value))
    props["value"] = value
    result.add newNode(newSym("Declaration"), props = props)

proc biDeclarations(args: openArray[Value]): Value {.nimcall.} =
  requireOne("declarations", args)
  case args[0].kind
  of vkNamespace:
    newStream(namespaceDeclarationNodes(args[0]))
  of vkModule:
    newStream(namespaceDeclarationNodes(args[0].moduleRootNamespace))
  else:
    raise newException(GeneError, "declarations expects a Module or Namespace")

proc biNamespaceBindings(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Namespace/bindings", args)
  requireNamespace("Namespace/bindings", args[0])
  var entries = initOrderedTable[string, Value]()
  for name in sortedBindingNames(args[0].nsScope):
    entries[name] = args[0].nsScope.vars[name]
  newMap(entries)

proc biNamespaceLookup(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Namespace/lookup expects 2 arguments, got " & $args.len)
  requireNamespace("Namespace/lookup", args[0])
  args[0].nsScope.vars.getOrDefault(keySegment("Namespace/lookup", args[1]), VOID)

proc biNamespaceDeclarations(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Namespace/declarations", args)
  requireNamespace("Namespace/declarations", args[0])
  newStream(namespaceDeclarationNodes(args[0]))

proc biModuleRootNamespace(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Module/root_namespace", args)
  requireModule("Module/root_namespace", args[0])
  args[0].moduleRootNamespace

proc biModulePath(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Module/path", args)
  requireModule("Module/path", args[0])
  let path = args[0].modulePath
  if path.len == 0: NIL else: newStr(path)

proc biModuleName(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Module/name", args)
  requireModule("Module/name", args[0])
  newStr(args[0].moduleName)

proc biModuleMeta(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Module/meta", args)
  requireModule("Module/meta", args[0])
  newMap(copyEntries(args[0].moduleMeta))

proc biModuleDeclarations(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Module/declarations", args)
  requireModule("Module/declarations", args[0])
  newStream(namespaceDeclarationNodes(args[0].moduleRootNamespace))

proc bindingsFromMap(name: string, value: Value): Table[string, Value] =
  if value.kind != vkMap:
    raise newException(GeneError, name & " must be a map")
  result = initTable[string, Value]()
  for k, v in value.mapEntries:
    result[k] = v

proc evalPolicyProp(policy: Value, name: string): Value =
  case policy.kind
  of vkMap:
    if policy.mapEntries.hasKey(name): policy.mapEntries[name] else: VOID
  of vkNode:
    if policy.props.hasKey(name): policy.props[name] else: VOID
  else:
    VOID

proc validateEvalPolicyPropName(name: string) =
  case name
  of "max-steps", "max-memory-mb", "timeout-ms",
     "allow-ffi", "allow-native-compile":
    discard
  else:
    raise newException(GeneError,
      "env ^policy got unexpected field: " & name)

proc validateEvalPolicyPropNames(policy: Value) =
  case policy.kind
  of vkMap:
    for name in policy.mapEntries.keys:
      validateEvalPolicyPropName(name)
  of vkNode:
    for name in policy.props.keys:
      validateEvalPolicyPropName(name)
  else:
    discard

proc evalPolicyNonNegativeInt(policy: Value, name: string): int64 =
  let value = evalPolicyProp(policy, name)
  if value.kind in {vkNil, vkVoid}:
    return -1
  if value.kind != vkInt or not value.intFitsInt64 or value.intVal < 0:
    raise newException(GeneError,
      "env ^policy ^" & name & " must be a non-negative Int")
  value.intVal

proc rejectUnsupportedEvalLimit(policy: Value, name: string) =
  if evalPolicyProp(policy, name).kind notin {vkNil, vkVoid}:
    discard evalPolicyNonNegativeInt(policy, name)
    raise newException(GeneError,
      "env ^policy ^" & name & " is not supported yet")

proc validateEvalPolicyFlag(policy: Value, name: string) =
  let value = evalPolicyProp(policy, name)
  if value.kind in {vkNil, vkVoid}:
    return
  if value.kind != vkBool:
    raise newException(GeneError,
      "env ^policy ^" & name & " must be a Bool")
  if value.boolVal:
    raise newException(GeneError,
      "env ^policy ^" & name & " true is not supported yet")

proc evalPolicyMaxSteps(policy: Value): int64 =
  if policy.kind in {vkNil, vkVoid}:
    return -1
  if policy.kind notin {vkMap, vkNode}:
    raise newException(GeneError, "env ^policy must be a map or node")
  validateEvalPolicyPropNames(policy)
  rejectUnsupportedEvalLimit(policy, "max-memory-mb")
  rejectUnsupportedEvalLimit(policy, "timeout-ms")
  validateEvalPolicyFlag(policy, "allow-ffi")
  validateEvalPolicyFlag(policy, "allow-native-compile")
  evalPolicyNonNegativeInt(policy, "max-steps")

proc evalBudgetForPolicy(policy: Value, parent: EvalBudget): EvalBudget =
  let maxSteps = evalPolicyMaxSteps(policy)
  if maxSteps < 0:
    parent
  else:
    EvalBudget(remaining: maxSteps, parent: parent)

proc biEnvExtend(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Env/extend expects 2 arguments, got " & $args.len)
  requireEnv("Env/extend", args[0])
  newEnv(bindingsFromMap("Env/extend bindings", args[1]), args[0])

proc pullMapStream(stream: Value): StreamPullResult {.nimcall.} =
  let source = stream.streamSource
  while source.streamHasNext:
    let item = checkedStreamNext(source, "map item")
    var callArgs = [item]
    return StreamPullResult(
      has: true,
      item: applyCall(stream.streamCallable, callArgs, NamedArgs()))
  StreamPullResult(has: false, item: NIL)

proc pullFilterStream(stream: Value): StreamPullResult {.nimcall.} =
  let source = stream.streamSource
  while source.streamHasNext:
    let item = checkedStreamNext(source, "filter item")
    var callArgs = [item]
    if applyCall(stream.streamCallable, callArgs, NamedArgs()).isTruthy:
      return StreamPullResult(has: true, item: item)
  StreamPullResult(has: false, item: NIL)

proc pullTakeStream(stream: Value): StreamPullResult {.nimcall.} =
  let source = stream.streamSource
  while stream.streamRemaining > 0 and source.streamHasNext:
    stream.setStreamRemaining(stream.streamRemaining - 1)
    return StreamPullResult(
      has: true,
      item: checkedStreamNext(source, "take item"))
  StreamPullResult(has: false, item: NIL)

proc biStreamMap(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "map expects 2 arguments, got " & $args.len)
  requireStream("map", args[0])
  newLazyStream(args[0], pullMapStream, callable = args[1])

proc biStreamFilter(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "filter expects 2 arguments, got " & $args.len)
  requireStream("filter", args[0])
  newLazyStream(args[0], pullFilterStream, callable = args[1])

proc biStreamTake(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "take expects 2 arguments, got " & $args.len)
  requireStream("take", args[0])
  var remaining = requireInt64("take count", args[1])
  if remaining < 0:
    raise newException(GeneError, "take count must be non-negative")
  newLazyStream(args[0], pullTakeStream, remaining = remaining)

proc biStreamInto(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "into expects 2 arguments, got " & $args.len)
  requireStream("into", args[0])
  case args[1].kind
  of vkList:
    var items = copyItems(args[1].listItems)
    while args[0].streamHasNext:
      items.add checkedStreamNext(args[0], "into item")
    newList(items, args[1].listImmutable)
  of vkMap:
    var entries = copyEntries(args[1].mapEntries)
    while args[0].streamHasNext:
      let pair = checkedStreamNext(args[0], "into item")
      if pair.kind != vkList or pair.listItems.len != 2:
        raise newException(GeneError, "into Map expects [key value] stream items")
      let key = keySegment("into", pair.listItems[0])
      let val = pair.listItems[1]
      if val.kind == vkVoid:
        entries.del(key)
      else:
        entries[key] = val
    newMap(entries, args[1].mapImmutable)
  else:
    raise newException(GeneError, "into expects a List or Map target")

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
    readIndex(target.listItems, requireInt64(name, segment))
  of vkNode:
    case segment.kind
    of vkInt:
      readIndex(target.body, requireInt64(name, segment))
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
    items[updateIndex(name, items.len, requireInt64(name, segment))] =
      if value.kind == vkVoid: NIL else: value
    newList(items, target.listImmutable)
  of vkNode:
    var props = copyEntries(target.props)
    var body = copyItems(target.body)
    var meta = copyEntries(target.meta)
    case segment.kind
    of vkInt:
      body[updateIndex(name, body.len, requireInt64(name, segment))] =
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
    var callArgs = [current]
    let nextValue = applyCall(updater, callArgs, NamedArgs())
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

proc requireList(name: string, value: Value) =
  if value.kind != vkList:
    raise newException(GeneError, name & " expects a List")

proc requireMap(name: string, value: Value) =
  if value.kind != vkMap:
    raise newException(GeneError, name & " expects a Map")

proc requireNode(name: string, value: Value) =
  if value.kind != vkNode:
    raise newException(GeneError, name & " expects a Node")

proc biListAssoc(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "List/assoc expects 3 arguments, got " & $args.len)
  requireList("List/assoc", args[0])
  let index = updateIndex("List/assoc", args[0].listItems.len,
                          requireInt64("List/assoc", args[1]))
  var items = copyItems(args[0].listItems)
  items[index] = (if args[2].kind == vkVoid: NIL else: args[2])
  newList(items, args[0].listImmutable)

proc biListSetBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "List/set! expects 3 arguments, got " & $args.len)
  requireList("List/set!", args[0])
  let index = updateIndex("List/set!", args[0].listItems.len,
                          requireInt64("List/set!", args[1]))
  let stored = if args[2].kind == vkVoid: NIL else: args[2]
  args[0].setListItem(index, stored)
  stored

proc biMapPutBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "Map/put! expects 3 arguments, got " & $args.len)
  requireMap("Map/put!", args[0])
  args[0].putMapEntry(keySegment("Map/put!", args[1]), args[2])
  args[2]

proc biNodeSetPropBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "Node/set-prop! expects 3 arguments, got " & $args.len)
  requireNode("Node/set-prop!", args[0])
  args[0].setNodeProp(keySegment("Node/set-prop!", args[1]), args[2])
  args[2]

proc displayStr(v: Value, scope: Scope = nil): string =
  ## print/println render strings as raw text and everything else via the printer.
  if v.kind == vkString:
    return v.strVal
  if scope != nil and v.kind == vkNode and v.head.kind == vkType:
    let protocol = builtinBinding(scope, "ToStr")
    if protocol.kind == vkProtocol and
        scope.typeImplementsProtocol(v.head, protocol):
      let message = protocol.protocolMessages["to-str"]
      let implFn = resolveProtocolMessage(scope, message, v)
      var callArgs = [v]
      let rendered = applyCall(implFn, callArgs, NamedArgs(), scope)
      if rendered.kind != vkString:
        raiseTypeError("ToStr/to-str", "Str", rendered, scope)
      return rendered.strVal
  print(v)

proc biToStr(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("to-str", args)
  let scope = if call == nil: nil else: call.dispatchScope
  newStr(displayStr(args[0], scope))

proc biChars(args: openArray[Value]): Value {.nimcall.} =
  requireOne("chars", args)
  requireStr("chars", args[0])
  var items: seq[Value]
  for r in args[0].strVal.runes:
    items.add newChar(r)
  newList(items)

proc biBytes(args: openArray[Value]): Value {.nimcall.} =
  requireOne("bytes", args)
  requireStr("bytes", args[0])
  var items: seq[Value]
  for b in args[0].strVal:
    items.add newInt(int64(ord(b)))
  newList(items)

proc biGraphemes(args: openArray[Value]): Value {.nimcall.} =
  requireOne("graphemes", args)
  requireStr("graphemes", args[0])
  let s = args[0].strVal
  var items: seq[Value]
  var i = 0
  while i < s.len:
    let width = s.graphemeLen(i)
    items.add newStr(s.substr(i, i + width - 1))
    i += width
  newList(items)

proc biDollar(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  var resultStr = ""
  for arg in args:
    resultStr.add displayStr(arg, scope)
  newStr(resultStr)

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

proc buildBuiltins(app: Application): Scope =
  ## Construct a fresh built-ins root scope holding all standard bindings and the
  ## singleton marker protocols/types (`Error`, `Send`, `TypeError`, ...). One of
  ## these is shared per application (see `builtinsScope`) so built-in identity is
  ## stable across modules.
  result = newScope(application = app)
  let errorProtocol = newProtocol("Error", [])
  result.define("Error", errorProtocol)
  let sendProtocol = newProtocol("Send", [])
  result.define("Send", sendProtocol)
  let callType = newType("Call", NIL,
                         @[
                           TypeField(name: "named", optional: false,
                                     typeExpr: newSym("PropMap"), scope: result),
                           TypeField(name: "site", optional: true,
                                     typeExpr: newSym("Node"), scope: result)
                         ],
                         @[], result, @[], @[],
                         @[
                           TypeBodyField(rest: true,
                                         typeExpr: newSym("Any"),
                                         scope: result)
                         ])
  result.define("Call", callType)
  let callableProtocol = newProtocol("Callable", ["apply"])
  result.define("Callable", callableProtocol)
  for _, message in callableProtocol.protocolMessages:
    result.define(message.protocolMessageName, message)
  let toStrProtocol = newProtocol("ToStr", ["to-str"])
  result.define("ToStr", toStrProtocol)
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
  let compileError = newType("CompileError", NIL,
                             @[TypeField(name: "message", optional: false,
                                         typeExpr: newSym("Str"), scope: result)],
                             @[errorProtocol], result)
  result.define("CompileError", compileError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: compileError,
                                messages: initTable[string, Value]())
  let parseError = newType("ParseError", compileError, @[], @[], result)
  result.define("ParseError", parseError)
  let lexError = newType("LexError", compileError, @[], @[], result)
  result.define("LexError", lexError)
  let tokenType = newType("Token", NIL,
                          @[
                            TypeField(name: "kind", optional: false,
                                      typeExpr: newSym("Sym"), scope: result),
                            TypeField(name: "lexeme", optional: false,
                                      typeExpr: newSym("Str"), scope: result),
                            TypeField(name: "line", optional: false,
                                      typeExpr: newSym("Int"), scope: result),
                            TypeField(name: "col", optional: false,
                                      typeExpr: newSym("Int"), scope: result)
                          ],
                          @[], result)
  result.define("Token", tokenType)
  let channelClosed = newType("ChannelClosed", NIL,
                              @[TypeField(name: "message", optional: false,
                                          typeExpr: newSym("Str"), scope: result)],
                              @[errorProtocol], result)
  result.define("ChannelClosed", channelClosed)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: channelClosed,
                                messages: initTable[string, Value]())
  let actorError = newType("ActorError", NIL,
                            @[TypeField(name: "message", optional: false,
                                        typeExpr: newSym("Str"), scope: result)],
                            @[errorProtocol], result)
  result.define("ActorError", actorError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: actorError,
                                messages: initTable[string, Value]())
  let actorClosed = newType("ActorClosed", actorError, @[], @[], result)
  result.define("ActorClosed", actorClosed)
  result.define("+", newNativeFn("+", biAdd))
  result.define("-", newNativeFn("-", biSub))
  result.define("*", newNativeFn("*", biMul))
  result.define("/", newNativeFn("/", biDiv))
  result.define("<", newNativeFn("<", comparison("<", `<`)))
  result.define(">", newNativeFn(">", comparison(">", `>`)))
  result.define("<=", newNativeFn("<=", comparison("<=", `<=`)))
  result.define(">=", newNativeFn(">=", comparison(">=", `>=`)))
  result.define("=", newNativeFn("=", biEq))
  result.define("same?", newNativeFn("same?", biSame))
  result.define("hash", newNativeFn("hash", biHash))
  result.define("not", newNativeFn("not", biNot))
  result.define("head", newNativeFn("head", biHead))
  result.define("props", newNativeFn("props", biProps))
  result.define("body", newNativeFn("body", biBody))
  result.define("meta", newNativeFn("meta", biMeta))
  result.define("to-str", newNativeCallFn("to-str", biToStr,
                                          acceptsNamed = false))
  result.define("chars", newNativeFn("chars", biChars))
  result.define("bytes", newNativeFn("bytes", biBytes))
  result.define("graphemes", newNativeFn("graphemes", biGraphemes))
  result.define("$", newNativeCallFn("$", biDollar, acceptsNamed = false))
  result.define("freeze-shallow", newNativeFn("freeze-shallow", biFreezeShallow))
  result.define("freeze", newNativeFn("freeze", biFreeze))
  result.define("thaw", newNativeFn("thaw", biThaw))
  let listScope = newScope(result)
  listScope.define("assoc", newNativeFn("List/assoc", biListAssoc))
  listScope.define("set!", newNativeFn("List/set!", biListSetBang))
  result.define("List", newNamespace("List", listScope))
  let mapScope = newScope(result)
  mapScope.define("put!", newNativeFn("Map/put!", biMapPutBang))
  result.define("Map", newNamespace("Map", mapScope))
  let nodeScope = newScope(result)
  nodeScope.define("set-prop!", newNativeFn("Node/set-prop!", biNodeSetPropBang))
  result.define("Node", newNamespace("Node", nodeScope))
  result.define("cell", newNativeFn("cell", biCell))
  let cellScope = newScope(result)
  cellScope.define("get", newNativeFn("Cell/get", biCellGet))
  cellScope.define("set", newNativeFn("Cell/set", biCellSet))
  cellScope.define("swap", newNativeFn("Cell/swap", biCellSwap))
  cellScope.define("update", newNativeFn("Cell/update", biCellUpdate))
  result.define("Cell", newNamespace("Cell", cellScope))
  result.define("atomic-cell", newNativeFn("atomic-cell", biAtomicCell))
  let atomicCellScope = newScope(result)
  atomicCellScope.define("load", newNativeFn("AtomicCell/load", biAtomicCellLoad))
  atomicCellScope.define("store", newNativeFn("AtomicCell/store", biAtomicCellStore))
  atomicCellScope.define("swap", newNativeFn("AtomicCell/swap", biAtomicCellSwap))
  atomicCellScope.define("compare-exchange",
    newNativeFn("AtomicCell/compare-exchange", biAtomicCellCompareExchange))
  result.define("AtomicCell", newNamespace("AtomicCell", atomicCellScope))
  let taskScope = newScope(result)
  taskScope.define("cancel", newNativeFn("Task/cancel", biTaskCancel))
  result.define("Task", newNamespace("Task", taskScope))
  result.define("channel", newNativeCallFn("channel", biChannel))
  let channelScope = newScope(result)
  channelScope.define("send", newNativeCallFn("Channel/send", biChannelSend,
                                             acceptsNamed = false))
  channelScope.define("try-send", newNativeCallFn("Channel/try-send",
                                                 biChannelTrySend,
                                                 acceptsNamed = false))
  channelScope.define("recv", newNativeCallFn("Channel/recv", biChannelRecv,
                                             acceptsNamed = false))
  channelScope.define("try-recv", newNativeCallFn("Channel/try-recv",
                                                 biChannelTryRecv,
                                                 acceptsNamed = false))
  channelScope.define("close", newNativeCallFn("Channel/close", biChannelClose,
                                              acceptsNamed = false))
  result.define("Channel", newNamespace("Channel", channelScope))
  let actorScope = newScope(result)
  actorScope.define("spawn", newNativeCallFn("actor/spawn", biActorSpawn))
  actorScope.define("send", newNativeCallFn("actor/send", biActorSend,
                                           acceptsNamed = false))
  actorScope.define("try-send", newNativeCallFn("actor/try-send",
                                               biActorTrySend,
                                               acceptsNamed = false))
  actorScope.define("ask", newNativeCallFn("actor/ask", biActorAsk,
                                           acceptsNamed = false))
  actorScope.define("continue", newNativeFn("actor/continue", biActorContinue))
  actorScope.define("stop", newNativeFn("actor/stop", biActorStop))
  result.define("actor", newNamespace("actor", actorScope))
  let replyToScope = newScope(result)
  replyToScope.define("send", newNativeCallFn("ReplyTo/send", biReplyToSend,
                                             acceptsNamed = false))
  result.define("ReplyTo", newNamespace("ReplyTo", replyToScope))
  result.define("declarations", newNativeFn("declarations", biDeclarations))
  let namespaceScope = newScope(result)
  namespaceScope.define("bindings", newNativeFn("Namespace/bindings", biNamespaceBindings))
  namespaceScope.define("lookup", newNativeFn("Namespace/lookup", biNamespaceLookup))
  namespaceScope.define("declarations",
    newNativeFn("Namespace/declarations", biNamespaceDeclarations))
  result.define("Namespace", newNamespace("Namespace", namespaceScope))
  let moduleScope = newScope(result)
  moduleScope.define("root_namespace",
    newNativeFn("Module/root_namespace", biModuleRootNamespace))
  moduleScope.define("name", newNativeFn("Module/name", biModuleName))
  moduleScope.define("path", newNativeFn("Module/path", biModulePath))
  moduleScope.define("meta", newNativeFn("Module/meta", biModuleMeta))
  moduleScope.define("declarations",
    newNativeFn("Module/declarations", biModuleDeclarations))
  result.define("Module", newNamespace("Module", moduleScope))
  let envScope = newScope(result)
  envScope.define("extend", newNativeFn("Env/extend", biEnvExtend))
  result.define("Env", newNamespace("Env", envScope))
  result.define("read-one", newNativeCallFn("read-one", biReadOne,
                                            acceptsNamed = false))
  result.define("read-all", newNativeCallFn("read-all", biReadAll,
                                            acceptsNamed = false))
  result.define("lex-all", newNativeCallFn("lex-all", biLexAll,
                                           acceptsNamed = false))
  result.define("to_stream", newNativeFn("to_stream", biToStream))
  result.define("to_pairs_stream", newNativeFn("to_pairs_stream", biToPairsStream))
  result.define("map", newNativeFn("map", biStreamMap))
  result.define("filter", newNativeFn("filter", biStreamFilter))
  result.define("take", newNativeFn("take", biStreamTake))
  result.define("into", newNativeFn("into", biStreamInto))
  let streamScope = newScope(result)
  streamScope.define("has_next", newNativeFn("Stream/has_next", biStreamHasNext))
  streamScope.define("peek", newNativeFn("Stream/peek", biStreamPeek))
  streamScope.define("next", newNativeFn("Stream/next", biStreamNext))
  streamScope.define("close", newNativeFn("Stream/close", biStreamClose))
  result.define("Stream", newNamespace("Stream", streamScope))
  result.define("assoc-in", newNativeFn("assoc-in", biAssocIn))
  result.define("update-in", newNativeFn("update-in", biUpdateIn))
  result.define("panic", newNativeFn("panic", biPanic))
  result.define("print", newNativeFn("print", biPrint))
  result.define("println", newNativeFn("println", biPrintln))

var gApplication: Application

proc normalizedDir(path: string): string =
  normalizedPath(absolutePath(if path.len > 0: path else: getCurrentDir()))

proc newApplication*(entryDir = ""): Application =
  ## Create the runtime owner for one Gene program. MVP packages are represented
  ## by the root directory used for absolute/bare module resolution.
  let root = normalizedDir(entryDir)
  result = Application(moduleCache: initTable[string, Value](),
                       moduleLoading: initHashSet[string](),
                       currentModuleDir: root,
                       packageRoot: root)

proc currentApplication(): Application =
  if gApplication == nil:
    gApplication = newApplication(getCurrentDir())
  gApplication

proc application*(scope: Scope): Application =
  if scope != nil and scope.application != nil:
    return Application(scope.application)
  currentApplication()

proc builtinsScope*(app: Application): Scope =
  ## The single built-ins root scope for this application. Every module/program
  ## scope created for `app` shares these built-in protocol/type values.
  if app.builtins == nil:
    app.builtins = buildBuiltins(app)
  app.builtins

proc builtinsScope*(): Scope =
  currentApplication().builtinsScope()

proc newGlobalScope*(app: Application): Scope =
  ## A fresh program/module root scope. Its parent is the application's shared
  ## built-ins root, so declarations stay isolated while lookup falls through to
  ## built-ins with stable marker protocol/type identity.
  newScope(app.builtinsScope(), application = app)

proc newGlobalScope*(): Scope =
  newGlobalScope(currentApplication())

proc bindThisModule*(scope: Scope, name: string, path = ""): Value =
  ## Create the first-class module value for a module root scope. The root
  ## namespace owns declarations; the Module value carries identity, path, and
  ## metadata and is exposed through the compiler-provided `this-mod` binding.
  let root = newNamespace(name, scope, path, moduleRoot = true)
  result = newModule(name, root, path)
  scope.define("this-mod", result)

# ---------------------------------------------------------------------------
# Module loading (design §15.4/§15.6)
# ---------------------------------------------------------------------------
#
proc initModuleContext*(entryDir: string): Application {.discardable.} =
  ## Reset the default loader for a fresh program run rooted at `entryDir`.
  ## Existing callers can ignore the returned Application; new code can keep it
  ## and pass it to `newGlobalScope(app)`.
  gApplication = newApplication(entryDir)
  gApplication

proc isWithinPackageRoot(app: Application, path: string): bool =
  let root = normalizedPath(absolutePath(app.packageRoot))
  if path == root:
    return true
  let prefix =
    if root.len > 0 and root[^1] == DirSep: root
    else: root & $DirSep
  path.startsWith(prefix)

proc resolveModulePath*(app: Application, rawPath: string): string =
  ## Normalize a `from "path"` string to a stable absolute module identity.
  var p = rawPath
  if splitFile(p).ext.len == 0:
    p = p & ".gene"          # MVP extension policy
  let base =
    if p.startsWith("./") or p.startsWith("../"): app.currentModuleDir
    else: app.packageRoot    # bare and leading-"/" resolve from the root
  if p.startsWith("/"):
    p = p[1 .. ^1]
  result = normalizedPath(absolutePath(p, base))
  if not app.isWithinPackageRoot(result):
    raise newException(GeneError, "module path escapes package root: " & rawPath)

proc loadModuleValue(app: Application, absPath: string): Value

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
# `[a b rest...]`, map/props `{^k p}` (open), typed `x : T`, `(@ meta value)`,
# `(| & not)`, and node-shape/type patterns.

proc isSymbolP(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc isRestPattern(p: Value): bool =
  p.kind == vkSymbol and p.symVal.len > 3 and p.symVal.endsWith("...")

proc isTypedPattern(p: Value): bool =
  p.kind == vkNode and p.head.kind == vkSymbol and p.body.len > 0 and
    p.body[0].isSymbolP(":")

proc requireTypedPatternShape(p: Value) =
  if p.body.len != 2:
    raise newException(GeneError, "typed pattern requires a name and one type")

proc patternItems(target: Value): tuple[items: seq[Value], ok: bool] =
  case target.kind
  of vkList: (target.listItems, true)
  of vkNode: (target.body, true)
  else: (newSeq[Value](), false)

proc tryMatch(pat, target: Value, scope: Scope,
              binds: var Table[string, Value]): bool

proc metaAsMap(target: Value): Value =
  var entries = initOrderedTable[string, Value]()
  if target.kind == vkNode:
    for key, val in target.meta:
      entries[key] = val
  newMap(entries)

proc collectPatternBindings(pat: Value, names: var HashSet[string])

proc alternationBindingNames(alternatives: seq[Value]): HashSet[string] =
  result = initHashSet[string]()
  if alternatives.len == 0:
    return
  collectPatternBindings(alternatives[0], result)
  for i in 1 ..< alternatives.len:
    var names = initHashSet[string]()
    collectPatternBindings(alternatives[i], names)
    if names != result:
      raise newException(GeneError,
        "alternation pattern alternatives must bind the same names")

proc collectPatternBindings(pat: Value, names: var HashSet[string]) =
  case pat.kind
  of vkSymbol:
    if pat.symVal == "_":
      return
    if pat.isRestPattern:
      let restName = pat.symVal[0 .. ^4]
      if restName != "_":
        names.incl restName
    else:
      names.incl pat.symVal
  of vkList:
    for item in pat.listItems:
      collectPatternBindings(item, names)
  of vkMap:
    for _, valuePat in pat.mapEntries:
      collectPatternBindings(valuePat, names)
  of vkNode:
    if pat.isTypedPattern:
      pat.requireTypedPatternShape()
      if pat.head.symVal != "_":
        names.incl pat.head.symVal
      return
    if pat.head.kind == vkSymbol:
      case pat.head.symVal
      of "unquote":
        return
      of "|":
        for name in alternationBindingNames(pat.body):
          names.incl name
        return
      of "&":
        for sub in pat.body:
          collectPatternBindings(sub, names)
        return
      of "not":
        if pat.body.len == 1:
          var negNames = initHashSet[string]()
          collectPatternBindings(pat.body[0], negNames)
          if negNames.len > 0:
            raise newException(GeneError,
              "pattern (not p) must not introduce bindings")
        return
      else:
        discard
    for _, valuePat in pat.props:
      collectPatternBindings(valuePat, names)
    for item in pat.body:
      collectPatternBindings(item, names)
  else:
    discard

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
    if pat.isTypedPattern:
      pat.requireTypedPatternShape()
      if not matchesTypeExpr(pat.body[1], target, scope):
        return false
      if pat.head.symVal != "_":
        binds[pat.head.symVal] =
          adaptBoundary("pattern '" & pat.head.symVal & "'",
                        pat.body[1], target, scope)
      return true
    if pat.head.kind == vkSymbol:
      case pat.head.symVal
      of "unquote":          # %name -> compare to a lexical value
        if pat.body.len != 1 or pat.body[0].kind != vkSymbol:
          raise newException(GeneError, "pattern %name expects a name")
        return equal(target, scope.lookup(pat.body[0].symVal))
      of "@":                # meta pattern plus value pattern
        if pat.body.len != 2:
          raise newException(GeneError,
            "pattern (@ meta value) expects two patterns")
        var trial = binds
        if not tryMatch(pat.body[0], metaAsMap(target), scope, trial):
          return false
        if not tryMatch(pat.body[1], target, scope, trial):
          return false
        binds = trial
        return true
      of "|":                # alternation
        discard alternationBindingNames(pat.body)
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
        var negNames = initHashSet[string]()
        collectPatternBindings(pat.body[0], negNames)
        if negNames.len > 0:
          raise newException(GeneError,
            "pattern (not p) must not introduce bindings")
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
    for k, v in coll.mapEntries: result.add newList(@[newSym(k), v])
  of vkStream:
    while coll.streamHasNext:
      result.add checkedStreamNext(coll, "for item")
  of vkNil, vkVoid:
    discard
  else:
    raise newException(GeneError, "for: cannot iterate " & $coll.kind)

proc iteratorStream(coll: Value): Value =
  case coll.kind
  of vkList:
    newStream(copyItems(coll.listItems))
  of vkNode:
    newStream(copyItems(coll.body))
  of vkMap:
    var pairs: seq[Value]
    for k, v in coll.mapEntries:
      pairs.add newList(@[newSym(k), v])
    newStream(pairs)
  of vkStream:
    coll
  of vkNil, vkVoid:
    var empty: seq[Value]
    newStream(empty)
  else:
    raise newException(GeneError, "for: cannot iterate " & $coll.kind)

proc bindMatchedValues(scope: Scope, binds: Table[string, Value],
                       replaceExisting: bool) =
  for k, v in binds:
    if replaceExisting:
      if scope.storeNamedSlot(k, v, requireExisting = true):
        continue
      if scope.vars.hasKey(k):
        let stored = functionForScopeStorage(v, scope)
        scope.vars[k] = stored
        scope.syncSlot(k, stored)
        continue
    scope.define(k, v)

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

proc pop(stack: var seq[Value]): Value =
  if stack.len == 0:
    raise newException(GeneError, "VM stack underflow")
  result = stack[^1]
  stack.setLen(stack.len - 1)

const MaxRunStackPool = 64

var runStackPool {.threadvar.}: seq[seq[Value]]

proc acquireRunStack(): seq[Value] =
  if runStackPool.len == 0:
    return @[]
  let index = runStackPool.high
  result = runStackPool[index]
  runStackPool.setLen(index)

proc releaseRunStack(stack: var seq[Value]) =
  stack.setLen(0)
  if runStackPool.len < MaxRunStackPool:
    runStackPool.add stack

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

proc sameImplMessages(a, b: ProtocolImpl): bool =
  if a.messages.len != b.messages.len:
    return false
  for name, fn in a.messages:
    if not b.messages.hasKey(name) or not same(fn, b.messages[name]):
      return false
  true

proc makeImplsVisible(importingScope, sourceScope: Scope) =
  for imported in sourceScope.impls:
    var duplicate = false
    var s = importingScope
    while s != nil:
      for existing in s.impls:
        if same(existing.protocol, imported.protocol) and
            same(existing.receiver, imported.receiver):
          if existing.sameImplMessages(imported):
            duplicate = true
            break
          raise newException(GeneError,
            "duplicate visible impl " & imported.protocol.protocolName &
            " for " & imported.receiver.typeName)
      if duplicate:
        break
      s = s.parent
    if not duplicate:
      importingScope.impls.add imported

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

proc builtinBinding(scope: Scope, name: string): Value =
  let root =
    if scope == nil: builtinsScope()
    else: scope.application().builtinsScope()
  root.lookup(name)

proc isBuiltinCallable(value: Value): bool =
  value.kind in {vkFunction, vkNativeFn, vkType, vkProtocolMessage} or
    (value.kind == vkNode and value.isSelector)

proc valueImplementsCallable(value: Value, scope: Scope): bool =
  if value.isBuiltinCallable:
    return true
  let typ = value.receiverType
  if typ.kind != vkType:
    return false
  let protocol = builtinBinding(scope, "Callable")
  protocol.kind == vkProtocol and typeImplementsProtocol(scope, typ, protocol)

proc capturedScope(scope: Scope, captureDepth: int): Scope =
  if captureDepth <= 0:
    return nil
  result = scope
  for _ in 1 ..< captureDepth:
    if result == nil:
      return nil
    result = result.parent

proc capturedSlotSendable(fnScope, visibleScope: Scope, captureDepth, slot: int,
                          name: string, seen: var HashSet[uint64]): bool =
  let scope = capturedScope(fnScope, captureDepth)
  if scope == nil or slot < 0 or slot >= scope.slots.len:
    return false
  if not scope.slotDefined(slot):
    return false
  isSendableValue(scope.slots[slot], visibleScope, seen)

proc chunkCapturesSendable(chunk: Chunk, fnScope, visibleScope: Scope,
                           localDepth: int,
                           seen: var HashSet[uint64],
                           ignoredNames: HashSet[string]): bool

proc functionCallLocalNames(proto: FunctionProto): HashSet[string] =
  result = initHashSet[string]()
  for name in proto.params:
    result.incl name
  if proto.restParam.len > 0:
    result.incl proto.restParam
  for param in proto.namedParams:
    result.incl param.local

proc functionCapturesSendable(value: Value, visibleScope: Scope,
                              seen: var HashSet[uint64]): bool =
  let fnScope = value.fnScope
  if fnScope == nil:
    return true
  let code = value.fnCode
  if code == nil or not (code of FunctionProto):
    return false
  let proto = FunctionProto(code)
  if not chunkCapturesSendable(proto.chunk, fnScope, visibleScope, 0, seen,
                               initHashSet[string]()):
    return false
  let callLocals = functionCallLocalNames(proto)
  for defaultValue in proto.paramDefaults:
    if defaultValue.optional and defaultValue.defaultChunk != nil:
      if not chunkCapturesSendable(defaultValue.defaultChunk, fnScope,
                                   visibleScope, 0, seen, callLocals):
        return false
  for param in proto.namedParams:
    if param.defaultValue.optional and param.defaultValue.defaultChunk != nil:
      if not chunkCapturesSendable(param.defaultValue.defaultChunk, fnScope,
                                   visibleScope, 0, seen, callLocals):
        return false
  true

proc chunkCapturesSendable(chunk: Chunk, fnScope, visibleScope: Scope,
                           localDepth: int,
                           seen: var HashSet[uint64],
                           ignoredNames: HashSet[string]): bool =
  if chunk == nil:
    return true
  for inst in chunk.instructions:
    case inst.op
    of opLoadOuterLocal:
      if inst.depth > localDepth:
        let captureDepth = inst.depth - localDepth
        if not capturedSlotSendable(fnScope, visibleScope, captureDepth,
                                    inst.intArg, inst.name, seen):
          return false
    of opSetOuterLocal:
      if inst.depth > localDepth:
        return false
    of opLoadName:
      if not ignoredNames.contains(inst.name):
        var captured: Value
        if not fnScope.lookupOptional(inst.name, captured):
          return false
        if not isSendableValue(captured, visibleScope, seen):
          return false
    of opSetName:
      return false
    else:
      discard

  for body in chunk.subchunks:
    if not chunkCapturesSendable(body, fnScope, visibleScope,
                                 localDepth + 1, seen, ignoredNames):
      return false
  for loop in chunk.forLoops:
    if not chunkCapturesSendable(loop.body, fnScope, visibleScope,
                                 localDepth + 1, seen, ignoredNames):
      return false
  for match in chunk.matches:
    for clause in match.clauses:
      if not chunkCapturesSendable(clause.body, fnScope, visibleScope,
                                   localDepth + 1, seen, ignoredNames):
        return false
    if not chunkCapturesSendable(match.elseBody, fnScope, visibleScope,
                                 localDepth + 1, seen, ignoredNames):
      return false
  for attempt in chunk.tries:
    if not chunkCapturesSendable(attempt.body, fnScope, visibleScope,
                                 localDepth, seen, ignoredNames):
      return false
    for clause in attempt.catches:
      if not chunkCapturesSendable(clause.body, fnScope, visibleScope,
                                   localDepth + 1, seen, ignoredNames):
        return false
    if not chunkCapturesSendable(attempt.ensureBody, fnScope, visibleScope,
                                 localDepth, seen, ignoredNames):
      return false
  true

proc isSendableValue(value: Value, scope: Scope,
                     seen: var HashSet[uint64]): bool =
  if value.kind in {vkList, vkMap, vkNode, vkFunction}:
    if seen.contains(value.bits):
      return true
    seen.incl value.bits
  case value.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkChar, vkSymbol,
     vkNativeFn, vkActorRef, vkReplyTo, vkType, vkProtocol, vkProtocolMessage:
    true
  of vkFunction:
    functionCapturesSendable(value, scope, seen)
  of vkNode:
    var sendProtocol: Value
    if value.head.kind == vkType and scope != nil and
        scope.lookupOptional("Send", sendProtocol) and
        sendProtocol.kind == vkProtocol and
        scope.typeImplementsProtocol(value.head, sendProtocol):
      return true
    if not value.nodeImmutable:
      return false
    if not isSendableValue(value.head, scope, seen):
      return false
    for _, item in value.props:
      if not isSendableValue(item, scope, seen):
        return false
    for item in value.body:
      if not isSendableValue(item, scope, seen):
        return false
    for _, item in value.meta:
      if not isSendableValue(item, scope, seen):
        return false
    true
  of vkList:
    if not value.listImmutable:
      return false
    for item in value.listItems:
      if not isSendableValue(item, scope, seen):
        return false
    true
  of vkMap:
    if not value.mapImmutable:
      return false
    for _, item in value.mapEntries:
      if not isSendableValue(item, scope, seen):
        return false
    true
  of vkNamespace, vkModule, vkEnv, vkCell, vkAtomicCell, vkStream, vkTask,
     vkChannel, vkActorContext, vkActorStep:
    false

proc isSendableValue(value: Value, scope: Scope): bool =
  var seen = initHashSet[uint64]()
  isSendableValue(value, scope, seen)

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

proc raisePanicValue(value: Value) =
  var e: ref GenePanic
  new(e)
  e.msg = displayStr(value)
  e.errVal = value
  e.hasErrVal = true
  raise e

proc completedTaskFromError(e: ref GeneError): Value =
  if e.hasErrVal:
    newFailedTask(e.msg, e.errVal, hasValue = true)
  else:
    newFailedTask(e.msg)

proc completedTaskFromPanic(e: ref GenePanic): Value =
  if e.hasErrVal:
    newPanickedTask(e.msg, e.errVal, hasValue = true)
  else:
    newPanickedTask(e.msg)

proc awaitTaskValue(task: Value): Value =
  if task.kind != vkTask:
    raise newException(GeneError, "await expects a Task")
  if task.taskAwaited:
    raise newException(GeneError, "task result has already been awaited")
  # The current completed-task MVP consumes the payload on await. That breaks
  # Task -> closure result -> scope -> Task cycles until live task frames have
  # an explicit scheduler-owned reclamation path.
  if task.taskHasPanic:
    let msg = $task.taskPanicMsg
    let hasValue = task.taskHasPanicValue
    let value = task.taskPanicValue
    task.clearTaskPayload()
    var e: ref GenePanic
    new(e)
    e.msg = msg
    if hasValue:
      e.errVal = value
      e.hasErrVal = true
    raise e
  if task.taskHasError:
    let msg = $task.taskErrorMsg
    let hasValue = task.taskHasErrorValue
    let value = task.taskErrorValue
    task.clearTaskPayload()
    var e: ref GeneError
    new(e)
    e.msg = msg
    if hasValue:
      e.errVal = value
      e.hasErrVal = true
    raise e
  result = task.taskResult
  task.clearTaskPayload()

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

proc raiseCompileError(scope: Scope, message: string) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var head = newSym("CompileError")
  var compileError: Value
  if scope != nil and scope.lookupOptional("CompileError", compileError) and
      compileError.kind == vkType:
    head = compileError
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc namespaceForEnvSource(source: Value): Value =
  case source.kind
  of vkModule:
    source.moduleRootNamespace
  of vkNamespace:
    source
  else:
    VOID

proc normalizeEnvImport(app: Application, item: Value): Value =
  case item.kind
  of vkModule, vkNamespace:
    item
  of vkString:
    loadModuleValue(app, app.resolveModulePath(item.strVal))
  else:
    raise newException(GeneError,
      "env ^imports entries must be modules, namespaces, or module path strings")

proc envChain(env: Value): seq[Value] =
  if env.kind != vkEnv:
    raise newException(GeneError, "expected Env")
  let parent = env.envParent
  if parent.kind != vkNil:
    result = envChain(parent)
  result.add env

proc nearestEnvModule(chain: openArray[Value]): Value =
  if chain.len == 0:
    return NIL
  for i in countdown(chain.high, 0):
    let module = chain[i].envModule
    if module.kind != vkNil:
      return module
  NIL

proc importNamespaceBindings(target: Scope, source: Value) =
  let sourceNs = namespaceForEnvSource(source)
  if sourceNs.kind != vkNamespace:
    raise newException(GeneError, "env import source is not a namespace")
  target.makeImplsVisible(sourceNs.nsScope)
  for name in sortedBindingNames(sourceNs.nsScope):
    let value = sourceNs.exportedBinding(name)
    if value.kind != vkVoid:
      target.define(name, value)

proc materializeEvalParent(env: Value): Scope =
  let chain = envChain(env)
  let module = nearestEnvModule(chain)
  var current = builtinsScope()
  if module.kind != vkNil:
    let moduleScope = newScope(current)
    moduleScope.importNamespaceBindings(module)
    current = moduleScope

  var importScope: Scope
  for itemEnv in chain:
    for imported in itemEnv.envImports:
      if importScope == nil:
        importScope = newScope(current)
      importScope.importNamespaceBindings(imported)
  if importScope != nil:
    current = importScope

  for itemEnv in chain:
    let capabilities = itemEnv.envCapabilities
    if capabilities.kind != vkNil:
      let capabilityScope = newScope(current)
      for k, v in bindingsFromMap("env ^capabilities", capabilities):
        capabilityScope.defineOverlay(k, v)
      current = capabilityScope

    let bindingScope = newScope(current)
    for k, v in itemEnv.envBindings:
      bindingScope.defineOverlay(k, v)
    current = bindingScope
  current

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

proc dedupeProtocolMatches(matches: var seq[Value]) =
  var unique: seq[Value]
  for candidate in matches:
    var duplicate = false
    for existing in unique:
      if same(existing, candidate):
        duplicate = true
        break
    if not duplicate:
      unique.add candidate
  matches = unique

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
  matches.dedupeProtocolMatches()
  if matches.len == 0:
    raise newException(GeneError,
      "missing impl " & protocol.protocolName & " for " & recvType.typeName)
  if matches.len > 1:
    raise newException(GeneError,
      "ambiguous impl " & protocol.protocolName & " for " & recvType.typeName)
  matches[0]

proc appendSplicedBody(target: var seq[Value], value: Value) =
  case value.kind
  of vkList:
    for item in value.listItems:
      target.add item
  of vkNode:
    for item in value.body:
      target.add item
  else:
    raise newException(GeneError, "splice expects a list or node")

proc mergeSplicedNodePart(props: var PropTable, body: var seq[Value],
                          value: Value) =
  case value.kind
  of vkList:
    for item in value.listItems:
      body.add item
  of vkMap:
    for key, item in value.mapEntries:
      props[key] = item
  of vkNode:
    for key, item in value.props:
      props[key] = item
    for item in value.body:
      body.add item
  else:
    raise newException(GeneError, "node splice expects a list, map, or node")

proc run*(chunk: Chunk, scope: Scope, validateImplRequirements = true): Value

type
  RunStopKind = enum
    rskReturn
    rskYield

  RunStop = object
    kind: RunStopKind
    value: Value

proc runLoop(chunk: Chunk, scope: Scope, stack: var seq[Value], ip: var int,
             stopOnYield: bool,
             validateImplRequirements = true): RunStop

proc generatedDeriveProtocol(scope: Scope, decl: Value): Value =
  if decl.kind != vkNode:
    raise newException(GeneError, "derive generated declarations must be nodes")
  if not decl.head.isSymbol("impl") or decl.body.len < 2:
    raise newException(GeneError,
      "derive may only generate impl declarations for its own protocol")
  let protocolExpr = decl.body[0]
  case protocolExpr.kind
  of vkProtocol:
    result = protocolExpr
  of vkSymbol:
    if not scope.lookupOptional(protocolExpr.symVal, result):
      raise newException(GeneError,
        "derive generated impl protocol is undefined: " & protocolExpr.symVal)
    if result.kind != vkProtocol:
      raise newException(GeneError,
        "derive generated impl target must be a protocol")
  else:
    raise newException(GeneError,
      "derive generated impl must name its protocol directly")

proc runGeneratedDeriveDecl(scope: Scope, protocol, decl: Value) =
  let generatedProtocol = generatedDeriveProtocol(scope, decl)
  if not same(generatedProtocol, protocol):
    raise newException(GeneError,
      "derive may only generate impl declarations for its own protocol")
  discard run(compileForm(decl), scope, validateImplRequirements = false)

proc applyProtocolDerive(scope: Scope, protocol, typ, request: Value) =
  let deriveFn = protocol.protocolDeriveFn
  if deriveFn.kind == vkNil:
    raise newException(GeneError,
      "protocol " & protocol.protocolName & " has no derive form")
  var callArgs = [typ, request]
  let generated = applyCall(deriveFn, callArgs, NamedArgs(), scope)
  case generated.kind
  of vkNil, vkVoid:
    discard
  of vkNode:
    runGeneratedDeriveDecl(scope, protocol, generated)
  of vkList:
    for decl in generated.listItems:
      runGeneratedDeriveDecl(scope, protocol, decl)
  else:
    raise newException(GeneError, "derive must return a declaration node or list")

proc consumeEvalStep(budget: EvalBudget) =
  var current = budget
  while current != nil:
    if current.remaining <= 0:
      raise newException(GeneError, "eval max steps exceeded")
    dec current.remaining
    current = current.parent

proc runLoop(chunk: Chunk, scope: Scope, stack: var seq[Value], ip: var int,
             stopOnYield: bool,
             validateImplRequirements = true): RunStop =
  let evalBudget = scope.evalBudget
  while true:
    {.computedGoto.}
    if ip >= chunk.instructions.len:
      break
    if evalBudget != nil:
      consumeEvalStep(evalBudget)
    let inst = addr chunk.instructions[ip]
    let op = inst[].op
    inc ip
    case op
    of opPushConst:
      stack.add chunk.constants[inst[].intArg]
    of opLoadName:
      stack.add scope.lookup(inst[].name)
    of opLoadLocal:
      stack.add scope.loadSlot(inst[].intArg, inst[].name)
    of opLoadOuterLocal:
      stack.add scope.loadSlotAt(inst[].depth, inst[].intArg, inst[].name)
    of opDefineName:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in var")
      scope.define(inst[].name, stack[^1])
    of opDefineLocal:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in var")
      scope.defineSlot(inst[].intArg, inst[].name, stack[^1])
    of opSetName:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in set")
      scope.assign(inst[].name, stack[^1])
    of opSetLocal:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in set")
      scope.assignSlot(inst[].intArg, inst[].name, stack[^1])
    of opSetOuterLocal:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in set")
      scope.assignSlotAt(inst[].depth, inst[].intArg, inst[].name, stack[^1])
    of opPop:
      discard stack.pop()
    of opMakeList:
      var items = newSeq[Value](inst[].intArg)
      if inst[].intArg > 0:
        for i in countdown(inst[].intArg - 1, 0):
          items[i] = stack.pop()
      stack.add newList(items, inst[].flag)
    of opMakeListSplice:
      let proto = chunk.listBuilds[inst[].intArg]
      var parts = newSeq[Value](proto.splices.len)
      if proto.splices.len > 0:
        for i in countdown(proto.splices.len - 1, 0):
          parts[i] = stack.pop()
      var items: seq[Value]
      for i, part in parts:
        if proto.splices[i]:
          appendSplicedBody(items, part)
        else:
          items.add part
      stack.add newList(items, proto.immutable)
    of opMakeMap:
      var values = newSeq[Value](inst[].intArg)
      if inst[].intArg > 0:
        for i in countdown(inst[].intArg - 1, 0):
          values[i] = stack.pop()
      var entries = initOrderedTable[string, Value]()
      for i, key in inst[].names:
        if values[i].kind != vkVoid:
          entries[key] = values[i]
      stack.add newMap(entries, inst[].flag)
    of opMakeNode:
      let proto = chunk.nodeBuilds[inst[].intArg]
      var bodyParts = newSeq[Value](proto.bodyCount)
      if proto.bodyCount > 0:
        for i in countdown(proto.bodyCount - 1, 0):
          bodyParts[i] = stack.pop()
      var props = initOrderedTable[string, Value]()
      if proto.propNames.len > 0:
        var propValues = newSeq[Value](proto.propNames.len)
        for i in countdown(proto.propNames.len - 1, 0):
          propValues[i] = stack.pop()
        for i, key in proto.propNames:
          if propValues[i].kind != vkVoid:
            props[key] = propValues[i]
      var meta = initOrderedTable[string, Value]()
      if proto.metaNames.len > 0:
        var metaValues = newSeq[Value](proto.metaNames.len)
        for i in countdown(proto.metaNames.len - 1, 0):
          metaValues[i] = stack.pop()
        for i, key in proto.metaNames:
          if metaValues[i].kind != vkVoid:
            meta[key] = metaValues[i]
      let head = stack.pop()
      var body: seq[Value]
      for i, part in bodyParts:
        if proto.bodySplices.len > 0 and proto.bodySplices[i]:
          mergeSplicedNodePart(props, body, part)
        else:
          body.add part
      stack.add newNode(head, props = props, body = body, meta = meta,
                        immutable = proto.immutable)
    of opMakeSelector:
      var body = newSeq[Value](inst[].intArg)
      if inst[].intArg > 0:
        for i in countdown(inst[].intArg - 1, 0):
          body[i] = stack.pop()
      stack.add newNode(newSym("select"), body = body)
    of opMakeFn:
      let proto = chunk.functions[inst[].intArg]
      let errorTypes = stack.popCheckedErrorTypes(proto.errorTypeCount, scope)
      stack.add newFunction(proto.name, proto.params, proto, scope,
                            proto.checksErrors, errorTypes)
    of opMakeEnv:
      let policy = stack.pop()
      let capabilities = stack.pop()
      let module = stack.pop()
      let importsValue = stack.pop()
      let parent = stack.pop()
      let bindingMap = stack.pop()
      if bindingMap.kind != vkMap:
        raise newException(GeneError, "env ^bindings must be a map")
      if parent.kind != vkNil and parent.kind != vkEnv:
        raise newException(GeneError, "env ^parent must be an Env")
      if importsValue.kind != vkList:
        raise newException(GeneError, "env ^imports must be a list")
      if module.kind != vkNil and module.kind notin {vkModule, vkNamespace}:
        raise newException(GeneError, "env ^module must be a Module or Namespace")
      if capabilities.kind != vkNil and capabilities.kind != vkMap:
        raise newException(GeneError, "env ^capabilities must be a map")
      discard evalPolicyMaxSteps(policy)
      var imports: seq[Value]
      let app = scope.application()
      for item in importsValue.listItems:
        imports.add normalizeEnvImport(app, item)
      stack.add newEnv(bindingsFromMap("env ^bindings", bindingMap), parent,
                       imports, module, capabilities, policy)
    of opEval:
      let env = stack.pop()
      let node = stack.pop()
      if env.kind != vkEnv:
        raise newException(GeneError, "eval ^in must be an Env")
      let evalScope = newScope(materializeEvalParent(env))
      evalScope.evalBudget = evalBudgetForPolicy(env.envPolicy, scope.evalBudget)
      let evalChunk =
        try:
          compileEvalForm(node)
        except GeneError as e:
          raiseCompileError(scope, e.msg)
          newChunk()
      stack.add run(evalChunk, evalScope)
    of opMakeType:
      let proto = chunk.typeProtos[inst[].intArg]
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
                        derivedProtocols, proto.deriveRequests,
                        proto.bodyFields)
      if proto.requiredImplCount > 0:
        scope.requiredImplTypes.add typ
      for i, protocol in derivedProtocols:
        applyProtocolDerive(scope, protocol, typ, proto.deriveRequests[i])
      stack.add typ
    of opMakeProtocol:
      let proto = chunk.protocolProtos[inst[].intArg]
      var deriveFn = NIL
      if proto.deriveFn != nil:
        deriveFn = newFunction(proto.deriveFn.name, proto.deriveFn.params,
                               proto.deriveFn, scope)
        deriveFn = functionForScopeStorage(deriveFn, scope)
      let protocol = newProtocol(proto.name, proto.messageNames, deriveFn)
      for _, message in protocol.protocolMessages:
        scope.define(message.protocolMessageName, message)
      stack.add protocol
    of opMakeImpl:
      let proto = chunk.implProtos[inst[].intArg]
      var messageErrorTypes = newSeq[seq[Value]](proto.messages.len)
      if proto.messages.len > 0:
        for i in countdown(proto.messages.len - 1, 0):
          messageErrorTypes[i] =
            stack.popCheckedErrorTypes(proto.messages[i].fn.errorTypeCount, scope)
      let receiver = stack.pop()
      let protocol = stack.pop()
      var messages = initTable[string, Value]()
      for i, message in proto.messages:
        let fn = newFunction(message.fn.name, message.fn.params, message.fn,
                             scope, message.fn.checksErrors,
                             messageErrorTypes[i])
        messages[message.name] = functionForScopeStorage(fn, scope)
      scope.registerImpl(protocol, receiver, messages)
      stack.add NIL
    of opMakeNamespace:
      # Run the ns body in a fresh child scope; its bindings become the
      # namespace's exports. Bind the namespace in the enclosing scope.
      let nsScope = newScope(scope)
      discard run(chunk.subchunks[inst[].intArg], nsScope)
      let ns = newNamespace(inst[].name, nsScope)
      scope.define(inst[].name, ns)
      stack.add ns
    of opSetModuleName:
      var module: Value
      if scope.lookupOptional("this-mod", module):
        if module.kind == vkModule:
          module.setModuleName(inst[].name)
          if inst[].intArg >= 0 and inst[].intArg < chunk.constants.len:
            let metaValue = chunk.constants[inst[].intArg]
            if metaValue.kind == vkMap:
              module.setModuleMeta(copyEntries(metaValue.mapEntries))
        elif module.kind == vkNamespace and module.nsIsModuleRoot:
          module.setNsName(inst[].name)
      stack.add NIL
    of opImport:
      let spec = chunk.imports[inst[].intArg]
      var source: Value
      if spec.fromModule:
        let app = scope.application()
        source = loadModuleValue(app, app.resolveModulePath(spec.modulePath))
      else:
        # Namespace path: resolve segments against the current scope.
        source = scope.lookup(spec.nsSegments[0])
        for i in 1 ..< spec.nsSegments.len:
          if source.kind == vkModule:
            source = source.moduleRootNamespace
          if source.kind != vkNamespace:
            raise newException(GeneError,
              "import: '" & spec.nsSegments[0 ..< i].join("/") & "' is not a namespace")
          source = source.exportedBinding(spec.nsSegments[i])
      let sourceNs =
        case source.kind
        of vkModule:
          source.moduleRootNamespace
        of vkNamespace:
          source
        else:
          VOID
      if sourceNs.kind != vkNamespace:
        raise newException(GeneError, "import source is not a namespace")
      scope.makeImplsVisible(sourceNs.nsScope)
      if spec.alias.len > 0:
        scope.define(spec.alias, source)
      for sel in spec.selections:
        let v = sourceNs.exportedBinding(sel.name)
        if v.kind == vkVoid:
          raise newException(GeneError, "module/namespace has no export: " & sel.name)
        scope.define(sel.local, v)
      stack.add NIL
    of opCall:
      var named: NamedArgs
      let argCount = inst[].intArg
      let namedCount = inst[].names.len
      let argsStart = stack.len - argCount
      if argsStart < 0 or argsStart < namedCount + 1:
        raise newException(GeneError, "VM stack underflow in call")
      let calleeIndex = argsStart - namedCount - 1
      let callee = stack[calleeIndex]
      if inst[].names.len > 0:
        named.names = inst[].names
        named.values = newSeq[Value](inst[].names.len)
        for i in 0 ..< inst[].names.len:
          named.values[i] = stack[calleeIndex + 1 + i]
      let value =
        if argCount == 0:
          applyCall(callee, [], named, scope)
        else:
          applyCall(callee, stack.toOpenArray(argsStart, stack.high), named, scope)
      stack.setLen(calleeIndex)
      stack.add value
    of opMatch:
      let target = stack.pop()
      let mp = chunk.matches[inst[].intArg]
      var handled = false
      for cl in mp.clauses:
        var binds = initTable[string, Value]()
        if tryMatch(cl.pattern, target, scope, binds):
          let branchScope = newScope(scope)
          branchScope.prepareChunkScope(cl.body)
          branchScope.bindMatchedValues(binds, replaceExisting = false)
          stack.add run(cl.body, branchScope,
                        validateImplRequirements = validateImplRequirements)
          handled = true
          break
      if not handled:
        if mp.elseBody != nil:
          stack.add run(mp.elseBody, newScope(scope),
                        validateImplRequirements = validateImplRequirements)
        else:
          raiseMatchError(scope, "no matching pattern")
    of opMatchBind:
      let target = stack.pop()
      var binds = initTable[string, Value]()
      if not tryMatch(chunk.constants[inst[].intArg], target, scope, binds):
        raiseMatchError(scope, "destructuring pattern did not match")
      scope.bindMatchedValues(binds, replaceExisting = false)
      stack.add target
    of opMatchBindReplace:
      let target = stack.pop()
      var binds = initTable[string, Value]()
      if not tryMatch(chunk.constants[inst[].intArg], target, scope, binds):
        raiseMatchError(scope, "destructuring pattern did not match")
      scope.bindMatchedValues(binds, replaceExisting = true)
      stack.add target
    of opForEach:
      let coll = stack.pop()
      let fp = chunk.forLoops[inst[].intArg]
      for item in forItems(coll):
        let loopScope = newScope(scope)
        loopScope.prepareChunkScope(fp.body)
        var binds = initTable[string, Value]()
        if not tryMatch(fp.pattern, item, loopScope, binds):
          raiseMatchError(loopScope, "for pattern did not match an item")
        loopScope.bindMatchedValues(binds, replaceExisting = false)
        discard run(fp.body, loopScope)
      stack.add NIL
    of opMakeIterator:
      stack.add iteratorStream(stack.pop())
    of opIteratorHasNext:
      let stream = stack.pop()
      requireStream("for iterator", stream)
      stack.add newBool(stream.streamHasNext)
    of opIteratorNext:
      let stream = stack.pop()
      requireStream("for iterator", stream)
      if not stream.streamHasNext:
        raiseEndOfStream()
      stack.add checkedStreamNext(stream, "for item")
    of opTry:
      let tp = chunk.tries[inst[].intArg]
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
              let catchScope = newScope(scope)
              catchScope.prepareChunkScope(cl.body)
              catchScope.bindMatchedValues(binds, replaceExisting = false)
              resultVal = run(cl.body, catchScope,
                              validateImplRequirements = validateImplRequirements)
              handled = true
              break
          if not handled:
            raise                    # re-raise; the finally still runs ensure
      finally:
        if tp.ensureBody != nil:
          discard run(tp.ensureBody, scope, validateImplRequirements = false)
      stack.add resultVal
    of opTaskScope:
      let taskScope = newScope(scope)
      taskScope.ownsActors = true
      taskScope.actorFailureStrategy = afsStop
      try:
        stack.add run(chunk.subchunks[inst[].intArg], taskScope)
      finally:
        taskScope.closeOwnedActors()
    of opSupervisor:
      let supervisorScope = newScope(scope)
      supervisorScope.ownsActors = true
      supervisorScope.actorFailureStrategy = supervisorStrategy(inst[].name)
      try:
        stack.add run(chunk.subchunks[inst[].intArg], supervisorScope)
      finally:
        supervisorScope.closeOwnedActors()
    of opSpawn:
      let taskScope = newScope(scope)
      try:
        stack.add newCompletedTask(run(chunk.subchunks[inst[].intArg], taskScope))
      except GeneError as e:
        stack.add completedTaskFromError(e)
      except GenePanic as e:
        stack.add completedTaskFromPanic(e)
    of opAwait:
      stack.add awaitTaskValue(stack.pop())
    of opFail:
      let errVal = stack.pop()
      if not scope.isErrorValue(errVal):
        raise newException(GeneError, "fail expects an Error value")
      raiseFailedValue(errVal)
    of opPanic:
      raisePanicValue(stack.pop())
    of opYield:
      if not stopOnYield:
        raise newException(GeneError, "yield is only valid in a generator")
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in yield")
      result = RunStop(kind: rskYield, value: escapeWeakFunctions(stack[^1]))
      return
    of opJumpIfFalse:
      let cond = stack.pop()
      if not cond.isTruthy:
        ip = inst[].intArg
    of opJump:
      ip = inst[].intArg
    of opReturn:
      result = RunStop(kind: rskReturn,
                       value: escapeWeakFunctions(if stack.len > 0: stack.pop() else: NIL))
      if validateImplRequirements:
        scope.validateRequiredImpls()
      return
    of opCheckType:
      if stack.len == 0:
        raise newException(GeneError, "VM stack underflow in type check")
      stack[^1] = adaptBoundary(inst[].name, chunk.constants[inst[].intArg],
                                stack[^1], scope)
    of opDeclareType:
      scope.declareType(inst[].name, chunk.constants[inst[].intArg])
  result = RunStop(kind: rskReturn, value: NIL)
  if validateImplRequirements:
    scope.validateRequiredImpls()

proc run*(chunk: Chunk, scope: Scope, validateImplRequirements = true): Value =
  scope.prepareChunkScope(chunk)
  var stack: seq[Value]
  var ip = 0
  let stopped = runLoop(chunk, scope, stack, ip, stopOnYield = false,
                        validateImplRequirements = validateImplRequirements)
  if stopped.kind == rskYield:
    raise newException(GeneError, "yield is only valid in a generator")
  stopped.value

proc runPooled(chunk: Chunk, scope: Scope,
               validateImplRequirements = true): Value =
  if chunk.localNames.len == 0:
    return run(chunk, scope, validateImplRequirements)
  scope.prepareChunkScope(chunk)
  var stack = acquireRunStack()
  var ip = 0
  var stopped: RunStop
  try:
    stopped = runLoop(chunk, scope, stack, ip, stopOnYield = false,
                      validateImplRequirements = validateImplRequirements)
  finally:
    releaseRunStack(stack)
  if stopped.kind == rskYield:
    raise newException(GeneError, "yield is only valid in a generator")
  stopped.value

proc pullGeneratorStream(stream: Value): StreamPullResult {.nimcall.} =
  let code = stream.streamGeneratorCode
  if code == nil or not (code of FunctionProto):
    return StreamPullResult(has: false, item: NIL)
  let proto = FunctionProto(code)
  var ip = stream.streamGeneratorIp
  let stopped = runLoop(proto.chunk, stream.streamGeneratorScope,
                        stream.streamGeneratorStack, ip,
                        stopOnYield = true,
                        validateImplRequirements = false)
  stream.setStreamGeneratorIp(ip)
  case stopped.kind
  of rskYield:
    StreamPullResult(has: true, item: stopped.value)
  of rskReturn:
    stream.closeStream()
    StreamPullResult(has: false, item: NIL)

proc positionalDefault(proto: FunctionProto, index: int): ParamDefault =
  if index < proto.paramDefaults.len:
    proto.paramDefaults[index]
  else:
    ParamDefault()

proc requiredPositionalCount(proto: FunctionProto): int =
  proto.requiredPositional

proc defaultValue(defaultValue: ParamDefault, scope: Scope): Value =
  if defaultValue.defaultChunk != nil:
    run(defaultValue.defaultChunk, scope)
  else:
    VOID

proc typeExprLabel(expr: Value): string =
  if expr.kind == vkNil: "Any" else: expr.print()

proc isAnyType(expr: Value): bool =
  expr.kind == vkNil or (expr.kind == vkSymbol and expr.symVal == "Any")

proc typeExprEqual(a, b: Value): bool =
  if a.isAnyType and b.isAnyType:
    return true
  equal(a, b)

proc typeNode(name: string, body: sink seq[Value] = @[]): Value =
  newNode(newSym(name), body = body)

proc commonRuntimeTypeExpr(values: openArray[Value]): Value

proc runtimeTypeExpr(value: Value): Value =
  case value.kind
  of vkNil: newSym("Nil")
  of vkVoid: newSym("Void")
  of vkBool: newSym("Bool")
  of vkInt: newSym("Int")
  of vkFloat: newSym("Float")
  of vkString: newSym("Str")
  of vkChar: newSym("Char")
  of vkSymbol: newSym("Sym")
  of vkList:
    typeNode("List", @[commonRuntimeTypeExpr(value.listItems)])
  of vkMap:
    var values: seq[Value]
    for _, item in value.mapEntries:
      values.add item
    typeNode("Map", @[commonRuntimeTypeExpr(values)])
  of vkNode:
    if value.head.kind == vkType:
      value.head
    elif value.isSelector:
      newSym("Selector")
    else:
      newSym("Node")
  of vkFunction: newSym("Fn")
  of vkNativeFn: newSym("NativeFn")
  of vkNamespace: newSym("Namespace")
  of vkModule: newSym("Module")
  of vkEnv: newSym("Env")
  of vkCell: newSym("Cell")
  of vkAtomicCell: newSym("AtomicCell")
  of vkStream:
    let itemType = value.streamItemType
    if itemType.kind == vkNil:
      newSym("Stream")
    else:
      let errType =
        if value.streamErrType.kind == vkNil: newSym("Any")
        else: value.streamErrType
      typeNode("Stream", @[itemType, errType])
  of vkTask: newSym("Task")
  of vkChannel:
    let itemType = value.channelItemType
    if itemType.kind == vkNil:
      newSym("Channel")
    else:
      typeNode("Channel", @[itemType])
  of vkActorRef:
    let messageType = value.actorMessageType
    if messageType.kind == vkNil:
      newSym("ActorRef")
    else:
      typeNode("ActorRef", @[messageType])
  of vkActorContext: newSym("ActorContext")
  of vkActorStep: newSym("ActorStep")
  of vkReplyTo:
    let resultType = value.replyToResultType
    if resultType.kind == vkNil:
      newSym("ReplyTo")
    else:
      typeNode("ReplyTo", @[resultType])
  of vkType: newSym("Type")
  of vkProtocol: newSym("Protocol")
  of vkProtocolMessage: newSym("ProtocolMessage")

proc commonRuntimeTypeExpr(values: openArray[Value]): Value =
  if values.len == 0:
    return newSym("Any")
  result = runtimeTypeExpr(values[0])
  for i in 1 ..< values.len:
    let next = runtimeTypeExpr(values[i])
    if not typeExprEqual(result, next):
      return newSym("Any")

proc bindTypeParam(bindings: var Table[string, Value], name: string,
                   inferred: Value): bool =
  if inferred.isAnyType:
    return true
  if not bindings.hasKey(name) or bindings[name].isAnyType:
    bindings[name] = inferred
    return true
  typeExprEqual(bindings[name], inferred)

proc matchesMapKeyType(expr: Value, key: string, scope: Scope): bool =
  ## Map keys are currently stored as canonical strings after both symbol and
  ## string key paths. Until the value layer preserves key provenance, accept a
  ## key if either visible representation satisfies the requested boundary.
  expr.isAnyType or matchesTypeExpr(expr, newSym(key), scope) or
    matchesTypeExpr(expr, newStr(key), scope)

proc inferTypeExpr(expr, value: Value, scope: Scope, typeParams: openArray[string],
                   bindings: var Table[string, Value]): bool =
  if expr.kind == vkNil:
    return true
  case expr.kind
  of vkSymbol:
    if expr.symVal in typeParams:
      return bindings.bindTypeParam(expr.symVal, runtimeTypeExpr(value))
    return matchesTypeExpr(expr, value, scope)
  of vkNode:
    if expr.head.kind == vkSymbol:
      case expr.head.symVal
      of "List":
        if value.kind != vkList:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(List T) expects one item type")
        for item in value.listItems:
          if not inferTypeExpr(expr.body[0], item, scope, typeParams, bindings):
            return false
        return true
      of "Map", "PropMap":
        if value.kind != vkMap:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len notin [1, 2]:
          raise newException(GeneError, "(Map K V) expects key and value types")
        let valueType = expr.body[^1]
        for key, item in value.mapEntries:
          if expr.body.len == 2 and expr.body[0].kind != vkSymbol and
              not matchesMapKeyType(expr.body[0], key, scope):
            return false
          if expr.body.len == 2 and expr.body[0].kind == vkSymbol and
              expr.body[0].symVal notin typeParams and
              not matchesMapKeyType(expr.body[0], key, scope):
            return false
          if not inferTypeExpr(valueType, item, scope, typeParams, bindings):
            return false
        return true
      of "Stream":
        if value.kind != vkStream:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 2:
          raise newException(GeneError, "(Stream item err) expects item and error types")
        let itemType = value.streamItemType
        if itemType.kind != vkNil and expr.body[0].kind == vkSymbol and
            expr.body[0].symVal in typeParams:
          if not bindings.bindTypeParam(expr.body[0].symVal, itemType):
            return false
        let errType = value.streamErrType
        if errType.kind != vkNil and expr.body[1].kind == vkSymbol and
            expr.body[1].symVal in typeParams:
          if not bindings.bindTypeParam(expr.body[1].symVal, errType):
            return false
        return true
      of "Channel":
        if value.kind != vkChannel:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(Channel T) expects one item type")
        let itemType = value.channelItemType
        if itemType.kind != vkNil and expr.body[0].kind == vkSymbol and
            expr.body[0].symVal in typeParams:
          return bindings.bindTypeParam(expr.body[0].symVal, itemType)
        return true
      of "ActorRef":
        if value.kind != vkActorRef:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(ActorRef M) expects one message type")
        let messageType = value.actorMessageType
        if messageType.kind != vkNil and expr.body[0].kind == vkSymbol and
            expr.body[0].symVal in typeParams:
          return bindings.bindTypeParam(expr.body[0].symVal, messageType)
        return true
      of "ReplyTo":
        if value.kind != vkReplyTo:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(ReplyTo R) expects one result type")
        let resultType = value.replyToResultType
        if resultType.kind != vkNil and expr.body[0].kind == vkSymbol and
            expr.body[0].symVal in typeParams:
          return bindings.bindTypeParam(expr.body[0].symVal, resultType)
        return true
      else:
        discard
    return matchesTypeExpr(expr, value, scope)
  else:
    matchesTypeExpr(expr, value, scope)

proc substituteTypeParams(expr: Value, bindings: Table[string, Value],
                          typeParams: openArray[string]): Value =
  if expr.kind == vkNil:
    return NIL
  case expr.kind
  of vkSymbol:
    if expr.symVal in typeParams:
      return bindings.getOrDefault(expr.symVal, newSym("Any"))
    expr
  of vkNode:
    var props = initOrderedTable[string, Value]()
    for key, value in expr.props:
      props[key] = substituteTypeParams(value, bindings, typeParams)
    var meta = initOrderedTable[string, Value]()
    for key, value in expr.meta:
      meta[key] = substituteTypeParams(value, bindings, typeParams)
    var body: seq[Value]
    for item in expr.body:
      body.add substituteTypeParams(item, bindings, typeParams)
    newNode(substituteTypeParams(expr.head, bindings, typeParams),
            props = props, body = body, meta = meta,
            immutable = expr.nodeImmutable)
  of vkList:
    var items: seq[Value]
    for item in expr.listItems:
      items.add substituteTypeParams(item, bindings, typeParams)
    newList(items, expr.listImmutable)
  of vkMap:
    var entries = initOrderedTable[string, Value]()
    for key, value in expr.mapEntries:
      entries[key] = substituteTypeParams(value, bindings, typeParams)
    newMap(entries, expr.mapImmutable)
  else:
    expr

proc instantiateTypeExpr(expr: Value, bindings: Table[string, Value],
                         typeParams: openArray[string]): Value {.inline.} =
  if typeParams.len == 0:
    expr
  else:
    substituteTypeParams(expr, bindings, typeParams)

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

proc intInRange(value: Value, low, high: int64): bool {.inline.} =
  value.kind == vkInt and
    value.intCompareToInt64(low) >= 0 and
    value.intCompareToInt64(high) <= 0

proc intInDecimalRange(value: Value, low, high: string): bool =
  value.kind == vkInt and
    intCompare(value, newIntFromDecimal(low)) >= 0 and
    intCompare(value, newIntFromDecimal(high)) <= 0

const F32_MAX_FINITE = 3.4028234663852886e38

proc floatInF32Range(value: Value): bool =
  if value.kind != vkFloat:
    return false
  case classify(value.floatVal)
  of fcNan, fcInf, fcNegInf:
    true
  else:
    abs(value.floatVal) <= F32_MAX_FINITE

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
  of "Int", "Integer":
    (true, value.kind == vkInt)
  of "SignedInt":
    (true, value.kind == vkInt)
  of "UnsignedInt":
    (true, value.kind == vkInt and value.intCompareToInt64(0) >= 0)
  of "Fixnum":
    (true, value.kind == vkInt and not value.isHeapBacked)
  of "I64":
    (true, value.intInRange(low(int64), high(int64)))
  of "I8":
    (true, value.intInRange(-128'i64, 127'i64))
  of "I16":
    (true, value.intInRange(-32768'i64, 32767'i64))
  of "I32":
    (true, value.intInRange(-2147483648'i64, 2147483647'i64))
  of "U8":
    (true, value.intInRange(0'i64, 255'i64))
  of "U16":
    (true, value.intInRange(0'i64, 65535'i64))
  of "U32":
    (true, value.intInRange(0'i64, 4294967295'i64))
  of "U64":
    (true, value.intInDecimalRange("0", "18446744073709551615"))
  of "Number":
    (true, value.kind in {vkInt, vkFloat})
  of "Float", "F64":
    (true, value.kind == vkFloat)
  of "F32":
    (true, value.floatInF32Range)
  of "List":
    (true, value.kind == vkList)
  of "Map", "PropMap":
    (true, value.kind == vkMap)
  of "Gene", "Node":
    (true, value.kind == vkNode)
  of "Fn", "Function":
    (true, value.kind == vkFunction)
  of "NativeFn":
    (true, value.kind == vkNativeFn)
  of "Selector":
    (true, value.kind == vkNode and value.isSelector)
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
  of "Module":
    (true, value.kind == vkModule)
  of "Env":
    (true, value.kind == vkEnv)
  of "Cell":
    (true, value.kind == vkCell)
  of "AtomicCell":
    (true, value.kind == vkAtomicCell)
  of "Stream":
    (true, value.kind == vkStream)
  of "Task":
    (true, value.kind == vkTask)
  of "Channel":
    (true, value.kind == vkChannel)
  of "ActorRef":
    (true, value.kind == vkActorRef)
  of "ActorContext":
    (true, value.kind == vkActorContext)
  of "ActorStep":
    (true, value.kind == vkActorStep)
  of "ReplyTo":
    (true, value.kind == vkReplyTo)
  else:
    (false, false)

proc closeTypeExpr(expr: Value, scope: Scope): Value =
  ## Convert nominal type references that require lexical lookup into direct
  ## Type values before storing a boundary on an escaping runtime object. Builtin
  ## annotation names stay symbolic so hot scalar checks keep their cheap path.
  case expr.kind
  of vkSymbol:
    let builtin = matchesBuiltinType(expr.symVal, NIL)
    let canBeLocalBuiltin = expr.symVal == "Task" or
      expr.symVal == "Channel" or
      expr.symVal == "ActorRef" or
      expr.symVal == "ActorContext" or
      expr.symVal == "ActorStep" or
      expr.symVal == "ReplyTo"
    if (not builtin.known or canBeLocalBuiltin) and scope != nil:
      var resolved: Value
      if scope.lookupOptional(expr.symVal, resolved) and resolved.kind == vkType:
        return resolved
    expr
  of vkNode:
    var changed = false
    var props = initOrderedTable[string, Value]()
    for key, value in expr.props:
      let closed = closeTypeExpr(value, scope)
      props[key] = closed
      if closed.bits != value.bits:
        changed = true
    var body: seq[Value]
    for item in expr.body:
      let closed = closeTypeExpr(item, scope)
      body.add closed
      if closed.bits != item.bits:
        changed = true
    var meta = initOrderedTable[string, Value]()
    for key, value in expr.meta:
      let closed = closeTypeExpr(value, scope)
      meta[key] = closed
      if closed.bits != value.bits:
        changed = true
    if changed:
      newNode(expr.head, props = props, body = body, meta = meta,
              immutable = expr.nodeImmutable)
    else:
      expr
  of vkList:
    var changed = false
    var items: seq[Value]
    for item in expr.listItems:
      let closed = closeTypeExpr(item, scope)
      items.add closed
      if closed.bits != item.bits:
        changed = true
    if changed: newList(items, expr.listImmutable) else: expr
  of vkMap:
    var changed = false
    var entries = initOrderedTable[string, Value]()
    for key, value in expr.mapEntries:
      let closed = closeTypeExpr(value, scope)
      entries[key] = closed
      if closed.bits != value.bits:
        changed = true
    if changed: newMap(entries, expr.mapImmutable) else: expr
  else:
    expr

proc matchesTypeExpr(expr, value: Value, scope: Scope): bool =
  if expr.kind == vkNil:
    return true
  case expr.kind
  of vkSymbol:
    var resolved: Value
    let name = expr.symVal
    if name == "Callable":
      return value.valueImplementsCallable(scope)
    # Some built-ins are both annotations/namespaces and legal nominal names in
    # user code; let local nominal declarations win for bare annotations.
    if scope != nil and
        ((name.len == 4 and name == "Task") or
         (name.len == 7 and name == "Channel") or
         (name.len == 8 and name == "ActorRef") or
         (name.len == 12 and name == "ActorContext") or
         (name.len == 9 and name == "ActorStep") or
         (name.len == 7 and name == "ReplyTo")) and
        scope.lookupOptional(name, resolved) and
        resolved.kind == vkType:
      return value.isInstanceOfType(resolved)
    let builtin = matchesBuiltinType(name, value)
    if builtin.known:
      return builtin.ok
    if scope != nil and scope.lookupOptional(name, resolved) and
        resolved.kind == vkType:
      return value.isInstanceOfType(resolved)
    raise newException(GeneError, "unknown type annotation: " & name)
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
        if expr.body.len notin [1, 2]:
          raise newException(GeneError, "(Map K V) expects key and value types")
        let valueType = expr.body[^1]
        for key, item in value.mapEntries:
          if expr.body.len == 2 and not matchesMapKeyType(expr.body[0], key, scope):
            return false
          if not matchesTypeExpr(valueType, item, scope):
            return false
        return true
      of "Stream":
        if value.kind != vkStream:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 2:
          raise newException(GeneError, "(Stream item err) expects item and error types")
        return true
      of "Task":
        if value.kind != vkTask:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 2:
          raise newException(GeneError, "(Task result err) expects result and error types")
        return true
      of "Channel":
        if value.kind != vkChannel:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(Channel T) expects one item type")
        let itemType = value.channelItemType
        if itemType.kind != vkNil:
          return typeExprEqual(closeTypeExpr(expr.body[0], scope), itemType)
        return true
      of "ActorRef":
        if value.kind != vkActorRef:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(ActorRef M) expects one message type")
        let messageType = value.actorMessageType
        if messageType.kind != vkNil:
          return typeExprEqual(closeTypeExpr(expr.body[0], scope), messageType)
        return true
      of "ActorContext":
        if value.kind != vkActorContext:
          return false
        if expr.body.len notin [0, 1]:
          raise newException(GeneError, "(ActorContext M) expects one message type")
        return true
      of "ActorStep":
        if value.kind != vkActorStep:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(ActorStep S) expects one state type")
        if value.actorStepContinue:
          return matchesTypeExpr(expr.body[0], value.actorStepState, scope)
        return true
      of "ReplyTo":
        if value.kind != vkReplyTo:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(ReplyTo R) expects one result type")
        let resultType = value.replyToResultType
        if resultType.kind != vkNil:
          return typeExprEqual(closeTypeExpr(expr.body[0], scope), resultType)
        return true
      else:
        discard
    raise newException(GeneError, "unsupported type annotation: " & expr.print())
  of vkType:
    value.isInstanceOfType(expr)
  else:
    raise newException(GeneError, "unsupported type annotation: " & expr.print())

proc adaptBoundary(where: string, typeExpr, value: Value, scope: Scope): Value =
  if typeExpr.kind == vkNil:
    return value
  if not matchesTypeExpr(typeExpr, value, scope):
    raiseTypeError(where, typeExpr.typeExprLabel, value, scope)
  if typeExpr.kind == vkNode and typeExpr.head.isSymbol("Stream") and
      typeExpr.body.len == 2:
    return newCheckedStream(value, typeExpr.body[0], typeExpr.body[1], scope)
  if typeExpr.kind == vkNode and typeExpr.head.isSymbol("Channel") and
      typeExpr.body.len == 1:
    return newCheckedChannel(value, closeTypeExpr(typeExpr.body[0], scope), nil)
  if typeExpr.kind == vkNode and typeExpr.head.isSymbol("ActorRef") and
      typeExpr.body.len == 1 and value.kind == vkActorRef and
      value.actorMessageType.kind == vkNil:
    value.setActorMessageType(closeTypeExpr(typeExpr.body[0], scope))
  if typeExpr.kind == vkNode and typeExpr.head.isSymbol("ReplyTo") and
      typeExpr.body.len == 1 and value.kind == vkReplyTo and
      value.replyToResultType.kind == vkNil:
    let resultType = closeTypeExpr(typeExpr.body[0], scope)
    if value.replyToSent:
      discard adaptBoundary(where, resultType, value.replyToResult, scope)
    value.setReplyToResultType(resultType, scope)
  value

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
  if target.kind == vkStream:
    var items: seq[Value]
    while target.streamHasNext:
      let item = staticLookup(checkedStreamNext(target, "selector item"), segment)
      if item.kind != vkVoid:
        items.add item
    return newStream(items)
  case segment.kind
  of vkInt:
    case target.kind
    of vkList:
      if segment.intFitsInt64: lookupIndex(target.listItems, segment.intVal) else: VOID
    of vkNode:
      if segment.intFitsInt64: lookupIndex(target.body, segment.intVal) else: VOID
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
      target.exportedBinding(key)
    of vkModule:
      target.moduleRootNamespace.exportedBinding(key)
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
        block:
          var callArgs = [result]
          applyCall(segment, callArgs, NamedArgs())
      else:
        staticLookup(result, segment)
    if result.kind == vkVoid:
      return VOID

proc callNamedMap(named: NamedArgs): Value =
  var entries = initOrderedTable[string, Value]()
  for i, name in named.names:
    if named.values[i].kind != vkVoid:
      entries[name] = named.values[i]
  newMap(entries)

proc callEnvelope(scope: Scope, args: openArray[Value], named: NamedArgs): Value =
  var props = initOrderedTable[string, Value]()
  props["named"] = callNamedMap(named)
  var body = newSeq[Value](args.len)
  for i, arg in args:
    body[i] = arg
  newNode(builtinBinding(scope, "Call"), props = props, body = body)

proc applyUserCallable(callee: Value, args: openArray[Value], named: NamedArgs,
                       dispatchScope: Scope): Value =
  let protocol = builtinBinding(dispatchScope, "Callable")
  let message = protocol.protocolMessages["apply"]
  let implFn = resolveProtocolMessage(dispatchScope, message, callee)
  let envelope = callEnvelope(dispatchScope, args, named)
  var callArgs = [callee, envelope]
  applyCall(implFn, callArgs, NamedArgs(), dispatchScope)

proc applyCall(callee: Value, args: openArray[Value], named: NamedArgs,
               dispatchScope: Scope = nil): Value =
  case callee.kind
  of vkNativeFn:
    let impl = callee.nativeImpl
    if impl != nil:
      if named.len != 0:
        if not callee.nativeAcceptsNamed:
          raise newException(GeneError,
            "native function '" & callee.nativeFnName & "' does not accept named arguments")
        raise newException(GeneError,
          "native function '" & callee.nativeFnName & "' cannot receive named arguments")
      return impl(args)
    let callImpl = callee.nativeCallImpl
    if callImpl == nil:
      raise newException(GeneError,
        "native function '" & callee.nativeFnName & "' has no implementation")
    if named.len != 0 and not callee.nativeAcceptsNamed:
      raise newException(GeneError,
        "native function '" & callee.nativeFnName & "' does not accept named arguments")
    var call = NativeCall(calleeName: callee.nativeFnName,
                          namedNames: named.names,
                          namedValues: named.values,
                          dispatchScope: dispatchScope)
    callImpl(args, addr call)
  of vkFunction:
    let positional = callee.fnParams
    let code = callee.fnCode
    if code == nil or not (code of FunctionProto):
      raise newException(GeneError, "function has no VM code")
    let proto = FunctionProto(code)
    if proto.simpleCall and named.len == 0:
      if args.len != positional.len:
        raise newException(GeneError,
          "function '" & callee.fnName & "' expects " & $proto.requiredPositional &
          ".." & $positional.len &
          " argument(s), got " & $args.len)
      let callScope = newScope(callee.fnScope)
      callScope.prepareSlots(proto.localNames)
      for i in 0 ..< args.len:
        callScope.defineSlot(proto.positionalSlots[i], positional[i], args[i])
      return runPooled(proto.chunk, callScope)
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
    callScope.prepareSlots(proto.localNames)
    var typeBindings: Table[string, Value]
    if proto.typeParams.len > 0:
      typeBindings = initTable[string, Value]()
      let providedForInference = min(args.len, positional.len)
      for i in 0 ..< providedForInference:
        if proto.hasParamTypes and i < proto.paramTypes.len and
            proto.paramTypes[i].kind != vkNil:
          if not inferTypeExpr(proto.paramTypes[i], args[i], callScope,
                               proto.typeParams, typeBindings):
            let expected = substituteTypeParams(proto.paramTypes[i], typeBindings,
                                                proto.typeParams)
            raiseTypeError("parameter '" & positional[i] & "'",
                           expected.typeExprLabel, args[i], callScope)
      for p in proto.namedParams:
        if named.hasArg(p.arg) and proto.hasNamedParamTypes and
            p.typeExpr.kind != vkNil:
          let value = named.getArg(p.arg)
          if not inferTypeExpr(p.typeExpr, value, callScope,
                               proto.typeParams, typeBindings):
            let expected = substituteTypeParams(p.typeExpr, typeBindings,
                                                proto.typeParams)
            raiseTypeError("parameter '" & p.local & "'",
                           expected.typeExprLabel, value, callScope)
    let providedPositional = min(args.len, positional.len)
    for i in 0 ..< providedPositional:
      var value = args[i]
      var declaredType = NIL
      if proto.hasParamTypes and i < proto.paramTypes.len and
          proto.paramTypes[i].kind != vkNil:
        let typeExpr = instantiateTypeExpr(proto.paramTypes[i], typeBindings,
                                           proto.typeParams)
        declaredType = typeExpr
        value = adaptBoundary("parameter '" & positional[i] & "'",
                              typeExpr, value, callScope)
      if i < proto.positionalSlots.len and proto.positionalSlots[i] >= 0:
        callScope.defineSlot(proto.positionalSlots[i], positional[i], value)
      else:
        callScope.define(positional[i], value)
      if declaredType.kind != vkNil:
        callScope.declareType(positional[i], declaredType)
    for pIndex, p in proto.namedParams:
      if named.hasArg(p.arg):
        var value = named.getArg(p.arg)
        var declaredType = NIL
        if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
          let typeExpr = instantiateTypeExpr(p.typeExpr, typeBindings,
                                             proto.typeParams)
          declaredType = typeExpr
          value = adaptBoundary("parameter '" & p.local & "'", typeExpr,
                                value, callScope)
        if pIndex < proto.namedSlots.len and proto.namedSlots[pIndex] >= 0:
          callScope.defineSlot(proto.namedSlots[pIndex], p.local, value)
        else:
          callScope.define(p.local, value)
        if declaredType.kind != vkNil:
          callScope.declareType(p.local, declaredType)
    for i in providedPositional ..< positional.len:
      let fallback = proto.positionalDefault(i)
      if not fallback.optional:
        raise newException(GeneError,
          "function '" & callee.fnName & "' missing positional argument: " & positional[i])
      let value = fallback.defaultValue(callScope)
      var boundValue = value
      var declaredType = NIL
      if proto.hasParamTypes and i < proto.paramTypes.len and
          proto.paramTypes[i].kind != vkNil:
        let typeExpr = instantiateTypeExpr(proto.paramTypes[i], typeBindings,
                                           proto.typeParams)
        declaredType = typeExpr
        boundValue = adaptBoundary("parameter '" & positional[i] & "'",
                                   typeExpr, value, callScope)
      if i < proto.positionalSlots.len and proto.positionalSlots[i] >= 0:
        callScope.defineSlot(proto.positionalSlots[i], positional[i], boundValue)
      else:
        callScope.define(positional[i], boundValue)
      if declaredType.kind != vkNil:
        callScope.declareType(positional[i], declaredType)
    if proto.restParam.len > 0:
      var rest = newSeq[Value](args.len - positional.len)
      for i in 0 ..< rest.len:
        rest[i] = args[positional.len + i]
      if proto.restSlot >= 0:
        callScope.defineSlot(proto.restSlot, proto.restParam, newList(rest))
      else:
        callScope.define(proto.restParam, newList(rest))
    for pIndex, p in proto.namedParams:
      if not named.hasArg(p.arg):
        if p.defaultValue.optional:
          var value = p.defaultValue.defaultValue(callScope)
          var declaredType = NIL
          if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
            let typeExpr = instantiateTypeExpr(p.typeExpr, typeBindings,
                                               proto.typeParams)
            declaredType = typeExpr
            value = adaptBoundary("parameter '" & p.local & "'", typeExpr,
                                  value, callScope)
          if pIndex < proto.namedSlots.len and proto.namedSlots[pIndex] >= 0:
            callScope.defineSlot(proto.namedSlots[pIndex], p.local, value)
          else:
            callScope.define(p.local, value)
          if declaredType.kind != vkNil:
            callScope.declareType(p.local, declaredType)
        else:
          raise newException(GeneError,
            "function '" & callee.fnName & "' missing named argument: " & p.arg)
    if proto.isGenerator:
      var resultValue = newGeneratorStream(proto, callScope, pullGeneratorStream)
      if proto.hasReturnType:
        let returnType = instantiateTypeExpr(proto.returnType, typeBindings,
                                             proto.typeParams)
        resultValue = adaptBoundary("return from '" & callee.fnName & "'",
                                    returnType, resultValue, callScope)
      return resultValue
    var resultValue: Value
    try:
      resultValue = runPooled(proto.chunk, callScope)
    except GeneError as e:
      if not callee.fnChecksErrors:
        raise
      if e.hasErrVal and errorAllowed(callee.fnErrorTypes, e.errVal):
        raise
      raise newException(GeneError,
        "function '" & callee.fnName & "' raised an undeclared error")
    if proto.hasReturnType:
      let returnType = instantiateTypeExpr(proto.returnType, typeBindings,
                                           proto.typeParams)
      resultValue = adaptBoundary("return from '" & callee.fnName & "'",
                                  returnType, resultValue, callScope)
    resultValue
  of vkType:
    # Construct a typed instance: a node with the type as head and validated
    # props/body fields.
    let fields = callee.typeFields
    let bodyFields = callee.typeBodyFields
    if args.len != 0 and bodyFields.len == 0:
      raise newException(GeneError,
        "constructing " & callee.typeName & " takes named fields only")
    var body: seq[Value]
    var restBody = -1
    for i, f in bodyFields:
      if f.rest:
        restBody = i
        break
    if restBody < 0:
      if args.len != bodyFields.len:
        raise newException(GeneError,
          "constructing " & callee.typeName & " expects " &
          $bodyFields.len & " body item(s), got " & $args.len)
      for i, f in bodyFields:
        let fieldScope = f.typeBodyFieldScope(callee.typeScope)
        body.add adaptBoundary("body field " & $i & " for " &
                               callee.typeName, f.typeExpr, args[i],
                               fieldScope)
    else:
      if args.len < restBody:
        raise newException(GeneError,
          "constructing " & callee.typeName & " expects at least " &
          $restBody & " body item(s), got " & $args.len)
      for i in 0 ..< restBody:
        let f = bodyFields[i]
        let fieldScope = f.typeBodyFieldScope(callee.typeScope)
        body.add adaptBoundary("body field " & $i & " for " &
                               callee.typeName, f.typeExpr, args[i],
                               fieldScope)
      let restType = bodyFields[restBody]
      let fieldScope = restType.typeBodyFieldScope(callee.typeScope)
      for i in restBody ..< args.len:
        body.add adaptBoundary("body field " & $i & " for " &
                               callee.typeName, restType.typeExpr, args[i],
                               fieldScope)
    var props = initOrderedTable[string, Value]()
    for f in fields:
      if named.hasArg(f.name):
        let value = named.getArg(f.name)
        if value.kind == vkVoid:
          if not f.optional:
            raise newException(GeneError,
              "missing required field '" & f.name & "' for " & callee.typeName)
        else:
          let fieldScope = f.typeFieldScope(callee.typeScope)
          props[f.name] = adaptBoundary("field '" & f.name & "' for " &
                                        callee.typeName, f.typeExpr, value,
                                        fieldScope)
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
    newNode(callee, props = props, body = body)
  of vkProtocolMessage:
    if args.len == 0:
      raise newException(GeneError,
        "protocol message '" & callee.protocolMessageName & "' expects a receiver")
    let implFn = resolveProtocolMessage(dispatchScope, callee, args[0])
    applyCall(implFn, args, named, dispatchScope)
  of vkNode:
    if not callee.isSelector:
      if callee.valueImplementsCallable(dispatchScope):
        return applyUserCallable(callee, args, named, dispatchScope)
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

proc loadModuleValue(app: Application, absPath: string): Value =
  ## Load, execute, and cache a module; return its first-class Module value.
  ## Modules run at most once (cache) and import cycles are rejected (loading set).
  if app.moduleCache.hasKey(absPath):
    return app.moduleCache[absPath]
  if absPath in app.moduleLoading:
    raise newException(GeneError, "import cycle detected at " & absPath)
  if not fileExists(absPath):
    raise newException(GeneError, "module not found: " & absPath)
  app.moduleLoading.incl absPath
  let src = readFile(absPath)
  let modScope = newGlobalScope(app)
  result = bindThisModule(modScope, splitFile(absPath).name, absPath)
  let savedDir = app.currentModuleDir
  app.currentModuleDir = parentDir(absPath)
  try:
    discard run(compileSource(src), modScope)
  finally:
    app.currentModuleDir = savedDir
    app.moduleLoading.excl absPath
  app.moduleCache[absPath] = result

proc loadFileModule*(app: Application, path: string): Value =
  ## Load a host file path as an application module. This is used by program
  ## startup; source-level `from "path"` imports still go through
  ## `resolveModulePath` so leading slash stays package-root-relative there.
  var p = path
  if splitFile(p).ext.len == 0:
    p = p & ".gene"
  let absPath = normalizedPath(absolutePath(p))
  if not app.isWithinPackageRoot(absPath):
    raise newException(GeneError, "module path escapes package root: " & path)
  loadModuleValue(app, absPath)
