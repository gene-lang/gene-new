## Stack VM for compiled Gene GIR chunks.

import std/[algorithm, dynlib, locks, math, monotimes, os, sets, strutils,
            tables, times, unicode]
import ./[compiler, equality, gir, printer, reader, types]

type
  RunStopKind = enum
    rskReturn
    rskYield
    rskSuspend            # fiber parked on a channel; its continuation is captured
    rskPause              # fiber yielded cooperatively at a scheduler safepoint
    rskCancel             # fiber unwound through cancellation cleanup

  RunStop = object
    kind: RunStopKind
    value: Value

  FrameKind = enum
    fkNormal
    fkTryBody
    fkCatchBody
    fkEnsureValueBody
    fkEnsureErrorBody
    fkEnsurePanicBody
    fkEnsureCancelBody
    fkForBody
    fkTaskScopeBody
    fkSupervisorBody
    fkNamespaceBody

  FrameExtra = ref object
    ensureValue: Value
    ensureBody: Chunk
    ensureScope: Scope
    pendingError: ref GeneError
    pendingPanic: ref GenePanic
    pendingCancel: ref GeneCancel
    forItems: seq[Value]
    forIndex: int
    forPattern: Value
    forBody: Chunk
    ownedScope: Scope
    namespaceName: string

  ## A suspended caller frame on the VM's explicit call-frame stack. Simple Gene
  ## function calls push one of these instead of recursing through Nim, so a call
  ## chain lives on the heap — the foundation for suspendable/resumable tasks
  ## (design §13/§17). Each frame owns its operand stack and instruction pointer.
  Frame = object
    chunk: Chunk
    scope: Scope
    recycleScope: bool
    stack: seq[Value]
    ip: int
    validateImpls: bool
    returnType: Value       # instantiated return-type to adapt on return, or NIL
    returnLabel: string     # "return from '<fn>'" label for the adaptation error
    checksErrors: bool      # this frame is an ^errors function (translate on throw)
    errorTypes: seq[Value]  # declared error rows, when checksErrors
    fnName: string          # function name, for the undeclared-error message
    kind: FrameKind         # current-frame completion behavior
    extra: FrameExtra       # rare state for try/ensure/for/task/ns frames
    restoreSlot: int        # same-scope recur frame restores this local slot
    restoreValue: Value

  TryHandler = object
    ## An active `try` region on the VM's handler stack. The try body runs as a
    ## Frame (so deep recursion through try-wrapped code stays on the heap); this
    ## record lets the dispatch loop's exception handler find the catch clauses
    ## and ensure block when an error unwinds back to `framesLen`.
    tp: TryProto
    scope: Scope            # enclosing scope, for catch matching and ensure
    framesLen: int          # frames.len at try entry; the handler fires when an
                            # unwinding error pops back to this depth

  Fiber = ref object
    ## A suspendable Gene task: the full runLoop continuation captured on the heap.
    ## A fresh fiber carries just chunk/scope (started = false); once it suspends,
    ## every register, the operand stack, and the frame/handler stacks are saved
    ## here so the scheduler can resume it later. `task` is the (Task T E) value it
    ## settles; `waitChannel`/`waitIsSend` record what it is parked on.
    chunk: Chunk
    scope: Scope
    recycleScope: bool
    stack: seq[Value]
    ip: int
    frames: seq[Frame]
    handlers: seq[TryHandler]
    validateImpls: bool
    returnType: Value
    returnLabel: string
    checksErrors: bool
    errorTypes: seq[Value]
    fnName: string
    frameKind: FrameKind
    ensureValue: Value
    ensureBody: Chunk
    ensureScope: Scope
    pendingError: ref GeneError
    pendingPanic: ref GenePanic
    pendingCancel: ref GeneCancel
    forItems: seq[Value]
    forIndex: int
    forPattern: Value
    forBody: Chunk
    ownedScope: Scope
    namespaceName: string
    started: bool          # false until first scheduled (resume restores the rest)
    workerSafe: bool       # snapshot-isolated; eligible for opt-in worker lane
    task: Value            # the Task this fiber settles, for spawn/await fibers
    actorOwner: Value      # actor this fiber is processing a message for (xor `task`)
    actorReturnType: Value # handler return type to adapt the ActorStep against
    actorScope: Scope      # dispatch scope for the actor (state checks / supervision)
    actorAskReply: Value   # ReplyTo for actor/ask messages, or NIL for sends
    actorMessage: Value    # current actor mailbox message, for failure events
    waitChannel: Value     # channel the fiber is parked on, when suspended on a channel
    waitIsSend: bool       # parked on send (vs recv)
    waitSendValue: Value   # value to deliver when a parked send resumes
    waitActor: Value       # actor the fiber is parked on, when send hit a full mailbox
    waitTask: Value        # task the fiber is parked on, when suspended in `await`
    waitTimer: bool        # fiber is parked until `waitDeadline`
    waitDeadline: MonoTime

  AskTimeout = object
    task: Value
    reply: Value
    scope: Scope
    deadline: MonoTime

  CaptureSafetyMode = enum
    csmSend
    csmWorker

  SchedulerState = ref object of RuntimeContext
    lock: Lock
    runQueue: seq[Fiber]
    waiters: seq[Fiber]
    askTimeouts: seq[AskTimeout]
    when compileOption("threads") and defined(gcAtomicArc):
      workers: seq[Thread[SchedulerState]]
      workersStarted: bool
      workerLeaseCount: int
      workerStop: bool
      workerCond: Cond
      activeWorkerCount: int

  SchedulerWorkerLease = object
    scheduler: SchedulerState
    active: bool

  Application* = ref object of RuntimeContext
    builtins: Scope
    spawnBuiltinsPublished: bool
    scheduler: SchedulerState
    nativeAdd: Value
    nativeSub: Value
    nativeMul: Value
    nativeLt: Value
    nativeGt: Value
    nativeLe: Value
    nativeGe: Value
    moduleCache: Table[string, Value]
    moduleLoading: HashSet[string]
    currentModuleDir: string
    packageRoot: string

proc raiseTypeError(where, expected: string, value: Value, scope: Scope)
proc matchesTypeExpr(expr, value: Value, scope: Scope): bool
proc adaptBoundary(where: string, typeExpr, value: Value, scope: Scope): Value
proc closeTypeExpr(expr: Value, scope: Scope): Value
proc commonRuntimeTypeExpr(values: openArray[Value]): Value
proc matchesBufferType(args: openArray[Value], value: Value,
                       scope: Scope): bool
proc matchesDeviceBufferType(args: openArray[Value], value: Value,
                             scope: Scope): bool
proc valueImplementsCallable(value: Value, scope: Scope): bool
proc typeImplementsProtocol(scope: Scope, typ, protocol: Value): bool
proc builtinBinding(scope: Scope, name: string): Value
proc resolveProtocolMessage(scope: Scope, message, receiver: Value): Value
proc isSendableValue(value: Value, scope: Scope,
                     seen: var HashSet[uint64],
                     mode = csmSend): bool
proc isSendableValue(value: Value, scope: Scope): bool
proc completedTaskFromError(e: ref GeneError): Value
proc completedTaskFromPanic(e: ref GenePanic): Value
proc schedulerForScope(scope: Scope): SchedulerState

type
  SuspendError = object of CatchableError
    ## Raised by a blocking native (channel send/recv) while a scheduled fiber is
    ## running, to suspend the whole Gene task. It is NOT a GeneError, so Gene
    ## `try/catch` never catches it; the dispatch loop turns it into rskSuspend and
    ## the scheduler parks the fiber until its wait condition is ready.
    channel: Value
    isSend: bool
    sendValue: Value
    actor: Value      # actor whose full mailbox parked this send (xor `channel`)
    timer: bool
    deadline: MonoTime

# `currentFiberActive` gates suspension: only a fiber the scheduler is running
# parks on blocking channel/actor operations. Root-level channel use keeps its
# original synchronous behavior. The active scheduler pointer and fiber-active
# flag are thread-local execution context; the queues they select are owned by
# Application.
var activeScheduler {.threadvar.}: SchedulerState
var activeFiberRunning {.threadvar.}: bool

proc currentScheduler(): SchedulerState

template withScopedScheduler(scope: Scope, body: untyped): untyped =
  let schedulerScope = scope
  let savedScheduler = activeScheduler
  if schedulerScope != nil and schedulerScope.application != nil:
    let scopedScheduler = schedulerForScope(schedulerScope)
    if activeScheduler == scopedScheduler:
      body
    else:
      activeScheduler = scopedScheduler
      try:
        body
      finally:
        activeScheduler = savedScheduler
  else:
    body

template currentFiberActive: untyped =
  activeFiberRunning

# Wake a fiber parked on `channel` (a receiver, or a sender when `wakeSenders`),
# moving it from the wait list to the run queue. Defined with the scheduler below.
proc wakeChannelWaiters(channel: Value, wakeSenders: bool)
proc wakeAllChannelWaiters(channel: Value, wakeSenders: bool)

# Wake fibers parked in `await` on a task that has just settled.
proc wakeTaskWaiters(task: Value)

# Schedule a task's own fiber to observe a cancellation request. Awaiters are
# woken when that fiber finishes cleanup and settles the task as cancelled.
proc cancelScheduledTask(task: Value): bool

# Run one runnable fiber to its next park/completion; false if none are runnable.
# Lets a blocking root-level channel op cooperatively pump the scheduler.
proc schedulerRunOne(skipWorkerSafe = false): bool
proc schedulerRunOneUntil(deadline: MonoTime, skipWorkerSafe = false): bool
proc beginSchedulerWorkerLease(): SchedulerWorkerLease
proc endSchedulerWorkerLease(lease: SchedulerWorkerLease)
proc schedulerRunOneRoot(lease: SchedulerWorkerLease): bool
proc schedulerRunOneRootUntil(deadline: MonoTime,
                              lease: SchedulerWorkerLease): bool
proc timerDeadline(milliseconds: int64): MonoTime
proc scheduleAskTimeout(task, reply: Value, scope: Scope, timeoutMs: int64)

# Drive the scheduler until the given task settles, or raise on deadlock.
proc pumpUntilDone(task: Value)

# Actor message processing runs each handler as a scheduler fiber. scheduleActor
# enqueues the next message's handler fiber if the actor is idle; driveActor pumps
# the scheduler until the actor is idle (used by root send/ask to stay synchronous);
# wakeActorSenders wakes a fiber parked on a previously-full mailbox.
proc scheduleActor(actor: Value, scope: Scope)
proc driveActor(actor: Value)
proc wakeActorSenders(actor: Value)
proc cancelOwnedActor(actor: Value)

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

proc registerOwnedTask(scope: Scope, task: Value) =
  var s = scope
  while s != nil:
    if s.ownsTasks:
      s.ownedTasks.add task
      return
    s = s.parent

proc unregisterOwnedTask(scope: Scope, task: Value): bool =
  var s = scope
  while s != nil:
    if s.ownsTasks:
      var i = 0
      while i < s.ownedTasks.len:
        if s.ownedTasks[i].taskSharesState(task):
          s.ownedTasks.delete(i)
          result = true
        else:
          inc i
    s = s.parent

proc requestTaskCancellation(task: Value) =
  if task.kind != vkTask or task.taskDone:
    return
  task.cancelTask()
  let scheduled = cancelScheduledTask(task)
  if not scheduled and not task.taskDone:
    task.finishTaskCancel()
    wakeTaskWaiters(task)

proc cancelOwnedTasks(scope: Scope) =
  if scope.ownedTasks.len == 0:
    return
  var pending: seq[Value]
  for i in countdown(scope.ownedTasks.high, 0):
    let task = scope.ownedTasks[i]
    if task.kind == vkTask and not task.taskDone:
      task.requestTaskCancellation()
      pending.add task
  try:
    for task in pending:
      if not task.taskDone:
        pumpUntilDone(task)
  finally:
    scope.ownedTasks.setLen(0)

proc waitOwnedTasks(scope: Scope) =
  if scope.ownedTasks.len == 0:
    return
  for i in 0 ..< scope.ownedTasks.len:
    let task = scope.ownedTasks[i]
    if task.kind == vkTask and not task.taskDone:
      pumpUntilDone(task)
  scope.ownedTasks.setLen(0)

proc closeOwnedActors(scope: Scope) =
  if scope.ownedActors.len == 0:
    return
  for i in countdown(scope.ownedActors.high, 0):
    if scope.ownedActors[i].kind == vkActorRef:
      cancelOwnedActor(scope.ownedActors[i])
  scope.ownedActors.setLen(0)

proc actorOwnerFailureStrategy(scope: Scope): ActorFailureStrategy =
  var s = scope
  while s != nil:
    if s.ownsActors:
      return s.actorFailureStrategy
    s = s.parent
  afsStop

proc actorOwnerFailureEvents(scope: Scope): Value =
  var s = scope
  while s != nil:
    if s.ownsActors:
      return s.supervisorEvents
    s = s.parent
  NIL

proc actorOwnerFailureDeadLetters(scope: Scope): Value =
  var s = scope
  while s != nil:
    if s.ownsActors:
      return s.supervisorDeadLetters
    s = s.parent
  NIL

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

proc slotDefined(scope: Scope, index: int): bool {.inline.} =
  if index < 64:
    (scope.slotDefinedBits and (1'u64 shl index)) != 0
  else:
    scope.slotDefinedOverflow[index - 64]

proc markSlotDefined(scope: Scope, index: int) {.inline.} =
  if index < 64:
    scope.slotDefinedBits = scope.slotDefinedBits or (1'u64 shl index)
  else:
    scope.slotDefinedOverflow[index - 64] = true

proc hasTypeBinding(binding: TypeBinding): bool {.inline.} =
  binding.expr.kind != vkNil

proc typeBindingScope(binding: TypeBinding): Scope {.inline.} =
  if binding.scope != nil:
    binding.scope
  elif binding.weakScope != nil:
    cast[Scope](binding.weakScope)
  else:
    nil

proc assignmentValue(scope: Scope, name: string, v: Value,
                     binding: TypeBinding): Value =
  if binding.hasTypeBinding:
    let bindingScope = binding.typeBindingScope
    adaptBoundary("set '" & name & "'", binding.expr, v,
                  if bindingScope == nil: scope else: bindingScope)
  else:
    v

proc declareType(scope: Scope, name: string, typeExpr: Value) =
  let binding = TypeBinding(expr: typeExpr, weakScope: cast[pointer](scope))
  let index = scope.slotIndex(name)
  if index >= 0:
    if scope.slotTypes.len < scope.slots.len:
      scope.slotTypes.setLen(scope.slots.len)
    scope.slotTypes[index] = binding
  else:
    scope.varTypes[name] = binding

proc declareSlotType(scope: Scope, index: int, typeExpr: Value) {.inline.} =
  if scope.slotTypes.len < scope.slots.len:
    scope.slotTypes.setLen(scope.slots.len)
  scope.slotTypes[index] = TypeBinding(expr: typeExpr,
                                       weakScope: cast[pointer](scope))

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

proc defineFreshCallSlot(scope: Scope, index: int, v: Value) {.inline.} =
  scope.slots[index] = functionForScopeStorage(v, scope)
  scope.markSlotDefined(index)

proc assignSlot(scope: Scope, index: int, name: string, v: Value) =
  scope.storeSlot(index, name, v, requireExisting = true)

proc assignSlotAt(scope: Scope, depth, index: int, name: string, v: Value) =
  scope.scopeAtDepth(depth, name).assignSlot(index, name, v)

proc lookup*(scope: Scope, name: string): Value =
  var s = scope
  while s != nil:
    if s.loadNamedSlot(name, result): return
    s.vars.withValue(name, value):
      return value[]
    s = s.parent
  raise newException(GeneError, "undefined symbol: " & name)

proc lookupOptional*(scope: Scope, name: string, value: var Value): bool =
  var s = scope
  while s != nil:
    if s.loadNamedSlot(name, value):
      return true
    s.vars.withValue(name, found):
      value = found[]
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
    s.vars.withValue(name, current):
      let value =
        if s.varTypes.hasKey(name): s.assignmentValue(name, v, s.varTypes[name])
        else: v
      let stored = functionForScopeStorage(value, s)
      s.vars[name] = stored
      s.syncSlot(name, stored)
      return
    s = s.parent
  raise newException(GeneError, "set of undefined symbol: " & name)

const MaxInlineNamedArgs = 4

type
  NamedArgs = object
    names: seq[string]
    values: seq[Value]
    inlineValues: array[MaxInlineNamedArgs, Value]

proc len(named: NamedArgs): int =
  named.names.len

proc valueAt(named: NamedArgs, index: int): Value =
  if named.values.len == named.names.len:
    named.values[index]
  else:
    named.inlineValues[index]

proc toSeq(named: NamedArgs): seq[Value] =
  if named.values.len == named.names.len:
    return named.values
  result = newSeq[Value](named.names.len)
  for i in 0 ..< named.names.len:
    result[i] = named.inlineValues[i]

proc namedArgsFromStack(names: seq[string], stack: openArray[Value],
                        start: int): NamedArgs =
  result.names = names
  if names.len <= MaxInlineNamedArgs:
    for i in 0 ..< names.len:
      result.inlineValues[i] = stack[start + i]
  else:
    result.values = newSeq[Value](names.len)
    for i in 0 ..< names.len:
      result.values[i] = stack[start + i]

proc hasArg(named: NamedArgs, name: string): bool =
  for key in named.names:
    if key == name: return true
  false

proc argIndex(named: NamedArgs, name: string): int =
  for i, key in named.names:
    if key == name: return i
  -1

proc getArg(named: NamedArgs, name: string): Value =
  for i, key in named.names:
    if key == name: return named.valueAt(i)
  raise newException(GeneError, "missing named argument: " & name)

proc applyCall(callee: Value, args: openArray[Value], named: NamedArgs,
               dispatchScope: Scope = nil, site: Value = NIL): Value
proc applyNativeCompiled(callee: Value, proto: FunctionProto,
                         args: openArray[Value],
                         named: NamedArgs): tuple[handled: bool, value: Value]
proc applySelector(selector, target: Value): Value
proc bindCallScope(callee: Value, proto: FunctionProto, args: openArray[Value],
                   named: NamedArgs): tuple[scope: Scope, returnType: Value]
proc errorAllowed(allowed: openArray[Value], errVal: Value): bool
proc typeExprLabel(expr: Value): string

# ---------------------------------------------------------------------------
# Built-in functions
# ---------------------------------------------------------------------------

proc isNumber(v: Value): bool = v.kind == vkInt or v.kind == vkFloat
proc toFloat(v: Value): float64 = (if v.kind == vkInt: v.intToFloat else: v.floatVal)
proc isBareIntType(expr: Value): bool {.inline.} =
  expr.kind == vkSymbol and expr.symVal == "Int"
proc isSymbol(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc isSelector(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("select")

proc isSelectorKeySegment(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("selector-key") and v.body.len == 1

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

proc tryFastNativeKind2(kind: NativeFastKind, a, b: Value): tuple[handled: bool, value: Value] {.inline.} =
  case kind
  of nfkAdd:
    var small: Value
    if smallIntAdd(a, b, small):
      (true, small)
    elif a.kind == vkInt and b.kind == vkInt:
      (true, intAdd(a, b))
    elif a.isNumber and b.isNumber:
      (true, newFloat(a.toFloat + b.toFloat))
    else:
      (false, NIL)
  of nfkSub:
    var small: Value
    if smallIntSub(a, b, small):
      (true, small)
    elif a.kind == vkInt and b.kind == vkInt:
      (true, intSub(a, b))
    elif a.isNumber and b.isNumber:
      (true, newFloat(a.toFloat - b.toFloat))
    else:
      (false, NIL)
  of nfkMul:
    if a.kind == vkInt and b.kind == vkInt:
      (true, intMul(a, b))
    elif a.isNumber and b.isNumber:
      (true, newFloat(a.toFloat * b.toFloat))
    else:
      (false, NIL)
  of nfkLt:
    if a.isSmallInt and b.isSmallInt:
      (true, newBool(a.smallIntVal < b.smallIntVal))
    elif a.kind == vkInt and b.kind == vkInt:
      (true, newBool(intCompare(a, b) < 0))
    elif a.isNumber and b.isNumber:
      (true, newBool(a.toFloat < b.toFloat))
    else:
      (false, NIL)
  of nfkGt:
    if a.isSmallInt and b.isSmallInt:
      (true, newBool(a.smallIntVal > b.smallIntVal))
    elif a.kind == vkInt and b.kind == vkInt:
      (true, newBool(intCompare(a, b) > 0))
    elif a.isNumber and b.isNumber:
      (true, newBool(a.toFloat > b.toFloat))
    else:
      (false, NIL)
  of nfkLe:
    if a.isSmallInt and b.isSmallInt:
      (true, newBool(a.smallIntVal <= b.smallIntVal))
    elif a.kind == vkInt and b.kind == vkInt:
      (true, newBool(intCompare(a, b) <= 0))
    elif a.isNumber and b.isNumber:
      (true, newBool(a.toFloat <= b.toFloat))
    else:
      (false, NIL)
  of nfkGe:
    if a.isSmallInt and b.isSmallInt:
      (true, newBool(a.smallIntVal >= b.smallIntVal))
    elif a.kind == vkInt and b.kind == vkInt:
      (true, newBool(intCompare(a, b) >= 0))
    elif a.isNumber and b.isNumber:
      (true, newBool(a.toFloat >= b.toFloat))
    else:
      (false, NIL)
  else:
    (false, NIL)

proc tryFastNative2(callee, a, b: Value): tuple[handled: bool, value: Value] {.inline.} =
  tryFastNativeKind2(callee.nativeFastKind, a, b)

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
  args[0].requestTaskCancellation()
  NIL

proc biTaskDetach(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Task/detach", args)
  requireTask("Task/detach", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  discard scope.unregisterOwnedTask(args[0])
  args[0]

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
  markSharedValue(result)

proc biChannelSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Channel/send expects 2 arguments, got " & $args.len)
  requireChannel("Channel/send", args[0])
  var workerLease: SchedulerWorkerLease
  var workerLeaseOpen = false
  defer:
    if workerLeaseOpen:
      endSchedulerWorkerLease(workerLease)
  while args[0].channelFull and not args[0].channelClosed:
    if currentFiberActive:
      # Inside a scheduled fiber: park the whole task until space frees up.
      var se: ref SuspendError
      new(se)
      se.msg = "Channel/send suspends on a full channel"
      se.channel = args[0]
      se.isSend = true
      se.sendValue = args[1]
      raise se
    # At the root: cooperatively run a fiber (a receiver may drain), then retry.
    if not workerLeaseOpen:
      workerLease = beginSchedulerWorkerLease()
      workerLeaseOpen = true
    if not schedulerRunOneRoot(workerLease):
      raise newException(GeneError, "Channel/send would suspend on a full channel")
  if args[0].channelClosed:
    raiseChannelClosed(if call == nil: nil else: call[].dispatchScope)
  let scope = if call == nil: nil else: call[].dispatchScope
  args[0].pushChannel(checkedChannelSendItem(args[0], args[1],
                                             "Channel/send item", scope))
  wakeChannelWaiters(args[0], wakeSenders = false)   # a buffered value may wake a receiver
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
  wakeChannelWaiters(args[0], wakeSenders = false)  # a new value may wake a parked receiver
  TRUE

proc nativeChannelTrySend*(channel, item: Value, scope: Scope = nil): bool =
  withScopedScheduler(scope):
    requireChannel("native channel try-send", channel)
    if channel.channelClosed or channel.channelFull:
      return false
    channel.pushChannel(checkedChannelSendItem(channel, item,
                                               "native channel item", scope))
    wakeChannelWaiters(channel, wakeSenders = false)
    true

proc biChannelRecv(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/recv", args)
  requireChannel("Channel/recv", args[0])
  var workerLease: SchedulerWorkerLease
  var workerLeaseOpen = false
  defer:
    if workerLeaseOpen:
      endSchedulerWorkerLease(workerLease)
  while args[0].channelLen == 0:
    if args[0].channelClosed:
      raiseChannelClosed(if call == nil: nil else: call[].dispatchScope)
    if currentFiberActive:
      # Inside a scheduled fiber: park the whole task until a value arrives.
      var se: ref SuspendError
      new(se)
      se.msg = "Channel/recv suspends on an empty channel"
      se.channel = args[0]
      se.isSend = false
      raise se
    # At the root: cooperatively run a fiber (a sender may push), then retry.
    if not workerLeaseOpen:
      workerLease = beginSchedulerWorkerLease()
      workerLeaseOpen = true
    if not schedulerRunOneRoot(workerLease):
      raise newException(GeneError, "Channel/recv would suspend on an empty channel")
  let scope = if call == nil: nil else: call[].dispatchScope
  let item = checkedChannelItem(args[0], args[0].popChannel(),
                                "Channel/recv item", scope)
  wakeChannelWaiters(args[0], wakeSenders = true)  # freed space may wake a sender
  return item

proc biChannelTryRecv(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/try-recv", args)
  requireChannel("Channel/try-recv", args[0])
  if args[0].channelLen == 0:
    return VOID
  let scope = if call == nil: nil else: call[].dispatchScope
  let item = checkedChannelItem(args[0], args[0].popChannel(), "Channel/try-recv item",
                                scope)
  wakeChannelWaiters(args[0], wakeSenders = true)  # freed space may wake a parked sender
  item

proc nativeChannelTryRecv*(channel: Value, scope: Scope = nil): Value =
  withScopedScheduler(scope):
    requireChannel("native channel try-recv", channel)
    if channel.channelLen == 0:
      return VOID
    result = checkedChannelItem(channel, channel.popChannel(),
                                "native channel item", scope)
    wakeChannelWaiters(channel, wakeSenders = true)

proc biChannelClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/close", args)
  requireChannel("Channel/close", args[0])
  args[0].closeChannel()
  wakeAllChannelWaiters(args[0], wakeSenders = false)
  wakeAllChannelWaiters(args[0], wakeSenders = true)
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

proc actorFailureStrategyName(strategy: ActorFailureStrategy): string =
  case strategy
  of afsStop: "stop"
  of afsRestart: "restart"
  of afsEscalate: "escalate"

proc supervisorFailureValue(scope: Scope, actor, failedMessage: Value,
                            message: string, errorValue: Value,
                            panic: bool): Value =
  var props = initOrderedTable[string, Value]()
  props["actor"] = actor
  props["failed-message"] = failedMessage
  props["message"] = newStr(message)
  props["error"] = errorValue
  props["panic"] = if panic: TRUE else: FALSE
  props["strategy"] = newSym(actorFailureStrategyName(actor.actorFailureStrategy))
  var head = newSym("ActorFailure")
  var failureType: Value
  if scope != nil and scope.lookupOptional("ActorFailure", failureType) and
      failureType.kind == vkType:
    head = failureType
  newNode(head, props = props)

proc tryEmitSupervisorFailure(sink, event: Value, scope: Scope): bool =
  if sink.kind != vkChannel or sink.channelClosed or sink.channelFull:
    return false
  try:
    sink.pushChannel(checkedChannelSendItem(sink, event,
                                            "supervisor failure event", scope))
  except CatchableError:
    return false
  wakeChannelWaiters(sink, wakeSenders = false)
  true

proc emitSupervisorFailure(actor, failedMessage: Value, scope: Scope,
                           message: string, errorValue: Value,
                           panic = false) =
  let event = supervisorFailureValue(scope, actor, failedMessage, message,
                                     errorValue, panic)
  if tryEmitSupervisorFailure(actor.actorFailureEvents, event, scope):
    return
  discard tryEmitSupervisorFailure(actor.actorFailureDeadLetters, event, scope)

proc failReplyTask(reply: Value, message: string, errVal: Value = NIL,
                   hasValue = false): bool =
  if reply.kind != vkReplyTo or reply.replyToSent:
    return false
  let task = reply.replyToTask
  if task.kind != vkTask or task.taskDone:
    return false
  failTask(task, message, errVal, hasValue)
  wakeTaskWaiters(task)
  true

proc panicReplyTask(reply: Value, message: string, errVal: Value = NIL,
                    hasValue = false): bool =
  if reply.kind != vkReplyTo or reply.replyToSent:
    return false
  let task = reply.replyToTask
  if task.kind != vkTask or task.taskDone:
    return false
  panicTask(task, message, errVal, hasValue)
  wakeTaskWaiters(task)
  true

proc cancelReplyTask(reply: Value): bool =
  if reply.kind != vkReplyTo or reply.replyToSent:
    return false
  let task = reply.replyToTask
  if task.kind != vkTask:
    return false
  if not task.taskDone:
    task.finishTaskCancel()
  wakeTaskWaiters(task)
  true

proc failReplyTask(reply: Value, e: ref GeneError): bool =
  if e.hasErrVal:
    failReplyTask(reply, e.msg, e.errVal, hasValue = true)
  else:
    failReplyTask(reply, e.msg)

proc panicReplyTask(reply: Value, e: ref GenePanic): bool =
  if e.hasErrVal:
    panicReplyTask(reply, e.msg, e.errVal, hasValue = true)
  else:
    panicReplyTask(reply, e.msg)

proc failMissingReply(reply: Value, scope: Scope): bool =
  const message = "actor/ask did not receive a reply"
  failReplyTask(reply, message, actorErrorValue(scope, message), hasValue = true)

proc actorAskTaskView(task, reply: Value, scope: Scope): Value =
  let resultType =
    if reply.replyToResultType.kind == vkNil: newSym("Any")
    else: reply.replyToResultType
  let errorType = builtinBinding(scope, "ActorError")
  let boundaryScope =
    if errorType.kind == vkType: errorType.typeScope
    else: nil
  newCheckedTask(task, resultType, errorType, boundaryScope)

proc actorAskTimeoutArg(call: ptr NativeCall): int64 =
  result = -1
  if call == nil:
    return
  for name in call[].namedNames:
    if name != "timeout-ms":
      raise newException(GeneError,
        "actor/ask got unexpected named argument: " & name)
  let index = nativeNamedIndex(call, "timeout-ms")
  if index >= 0:
    result = requireInt64("actor/ask timeout-ms", call[].namedValues[index])
    if result < 0:
      raise newException(GeneError, "actor/ask timeout-ms must be non-negative")

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
  markSharedValue(result)

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
  markSharedValue(result)

proc biReplyToSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "ReplyTo/send expects 2 arguments, got " & $args.len)
  requireReplyTo("ReplyTo/send", args[0])
  if args[0].replyToSent:
    raise newException(GeneError, "reply has already been sent")
  let scope = actorDispatchScope(call)
  let task = args[0].replyToTask
  if task.kind == vkTask and task.taskDone:
    args[0].cancelReplyTo()
    return NIL
  args[0].sendReplyTo(checkedReplyValue(args[0], args[1],
                                        "ReplyTo/send value", scope))
  if task.kind == vkTask:
    wakeTaskWaiters(task)
  NIL

# Actor message processing now runs each handler as a scheduler fiber (see
# makeActorFiber / scheduleActor / runFiber further below), so the old synchronous
# pumpActor loop is gone — handlers can suspend on channel/await, and full-mailbox
# sends park the sender.

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
  let failureEvents =
    if scope == nil: NIL else: scope.actorOwnerFailureEvents()
  let failureDeadLetters =
    if scope == nil: NIL else: scope.actorOwnerFailureDeadLetters()
  let restartInit =
    if failureStrategy == afsRestart: initFn else: NIL
  let state = applyCall(initFn, [], NamedArgs(), scope)
  result = newActorRef(actorMailboxArg(call), state, handler, closedMessageType,
                       restartInit, failureStrategy, failureEvents,
                       failureDeadLetters)
  if scope != nil:
    scope.registerOwnedActor(result)

proc biActorSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/send expects 2 arguments, got " & $args.len)
  requireActor("actor/send", args[0])
  let scope = actorDispatchScope(call)
  let actor = args[0]
  var workerLease: SchedulerWorkerLease
  var workerLeaseOpen = false
  defer:
    if workerLeaseOpen:
      endSchedulerWorkerLease(workerLease)
  while actor.actorFull and not actor.actorClosed:
    if currentFiberActive:
      # Inside a scheduled fiber: park this task until the mailbox drains.
      var se: ref SuspendError
      new(se)
      se.msg = "actor/send suspends on a full mailbox"
      se.actor = actor
      se.isSend = true
      raise se
    # At the root: cooperatively run the actor's handler fiber to free a slot.
    if not workerLeaseOpen:
      workerLease = beginSchedulerWorkerLease()
      workerLeaseOpen = true
    if not schedulerRunOneRoot(workerLease):
      raise newException(GeneError, "actor/send would suspend on a full mailbox")
  if actor.actorClosed:
    raiseActorClosed(scope)
  actor.pushActorMessage(checkedActorMessage(actor, args[1],
                                             "actor/send message", scope))
  scheduleActor(actor, scope)
  if not currentFiberActive:
    driveActor(actor)   # root send stays synchronous: process the message now
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
  scheduleActor(args[0], scope)
  if not currentFiberActive:
    driveActor(args[0])
  TRUE

proc nativeActorTrySend*(actor, message: Value, scope: Scope = nil): bool =
  withScopedScheduler(scope):
    requireActor("native actor try-send", actor)
    if actor.actorClosed or actor.actorFull:
      return false
    actor.pushActorMessage(checkedActorMessage(actor, message,
                                               "native actor message", scope))
    scheduleActor(actor, scope)
    if not currentFiberActive:
      driveActor(actor)
    true

proc biActorAsk(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/ask expects 2 arguments, got " & $args.len)
  requireActor("actor/ask", args[0])
  let scope = actorDispatchScope(call)
  let actor = args[0]
  let timeoutMs = actorAskTimeoutArg(call)
  try:
    var workerLease: SchedulerWorkerLease
    var workerLeaseOpen = false
    defer:
      if workerLeaseOpen:
        endSchedulerWorkerLease(workerLease)
    while actor.actorFull and not actor.actorClosed:
      if currentFiberActive:
        var se: ref SuspendError
        new(se)
        se.msg = "actor/ask suspends on a full mailbox"
        se.actor = actor
        se.isSend = true
        raise se
      if not workerLeaseOpen:
        workerLease = beginSchedulerWorkerLease()
        workerLeaseOpen = true
      if not schedulerRunOneRoot(workerLease):
        raise newException(GeneError, "actor/ask would suspend on a full mailbox")
    if actor.actorClosed:
      raiseActorClosed(scope)
    let task = newPendingTask()
    let reply = newReplyTo(task = task)
    var buildArgs = [reply]
    let message = applyCall(args[1], buildArgs, NamedArgs(), scope)
    actor.pushActorMessage(checkedActorMessage(actor, message,
                                               "actor/ask message", scope),
                            reply)
    if timeoutMs >= 0:
      scheduleAskTimeout(task, reply, scope, timeoutMs)
    scheduleActor(actor, scope)
    actorAskTaskView(task, reply, scope)
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

proc biActorSnapshot(args: openArray[Value]): Value {.nimcall.} =
  requireOne("actor/snapshot", args)
  requireActor("actor/snapshot", args[0])
  let actor = args[0]
  if actor.actorProcessing or actor.actorQueueLen > 0:
    raise newException(GeneError, "actor/snapshot requires an idle actor")
  var props = initOrderedTable[string, Value]()
  props["state"] = actor.actorState
  props["mailbox"] = newInt(actor.actorQueueLen)
  props["closed"] = newBool(actor.actorClosed)
  props["processing"] = newBool(actor.actorProcessing)
  newNode(newSym("ActorSnapshot"), props = props, immutable = true)

proc biActorUpgrade(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/upgrade expects 2 arguments, got " & $args.len)
  requireActor("actor/upgrade", args[0])
  let scope = actorDispatchScope(call)
  let actor = args[0]
  let handler = args[1]
  if actor.actorProcessing or actor.actorQueueLen > 0:
    raise newException(GeneError, "actor/upgrade requires an idle actor")
  if not handler.valueImplementsCallable(scope):
    raiseTypeError("actor/upgrade handler", "Callable", handler, scope)
  var migrate = NIL
  for i, name in call[].namedNames:
    if name == "migrate":
      migrate = call[].namedValues[i]
    else:
      raise newException(GeneError,
        "actor/upgrade got unexpected named argument: " & name)
  var nextState = actor.actorState
  if migrate.kind != vkNil:
    if not migrate.valueImplementsCallable(scope):
      raiseTypeError("actor/upgrade migrate", "Callable", migrate, scope)
    var migrateArgs = [actor.actorState]
    nextState = applyCall(migrate, migrateArgs, NamedArgs(), scope)
  actor.setActorState(nextState)
  actor.setActorHandler(handler)
  NIL

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
  of vkCPtr: "C pointer"
  of vkCSlice: "C slice"
  of vkBuffer: "Buffer"
  of vkDeviceBuffer: "Device/Buffer"
  of vkCapability: "Capability"
  of vkFfiLoad: "Ffi/Load"
  of vkFfiLibrary: "Ffi/Library"
  of vkFfiCallable: "Ffi/Callable"
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
     vkActorStep, vkReplyTo, vkCPtr, vkCSlice, vkBuffer, vkDeviceBuffer, vkCapability,
     vkFfiLoad, vkFfiLibrary, vkFfiCallable:
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

proc biSelectorKey(args: openArray[Value]): Value {.nimcall.} =
  requireOne("key", args)
  newNode(newSym("selector-key"), body = @[args[0]])

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
  of vkCPtr: "CPtr"
  of vkCSlice: "CSlice"
  of vkBuffer: "Buffer"
  of vkDeviceBuffer: "DeviceBuffer"
  of vkCapability: "Capability"
  of vkFfiLoad: "FfiLoad"
  of vkFfiLibrary: "FfiLibrary"
  of vkFfiCallable: "FfiCallable"
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

proc biEnvExtend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Env/extend expects 2 arguments, got " & $args.len)
  requireEnv("Env/extend", args[0])
  newEnv(bindingsFromMap("Env/extend bindings", args[1]), args[0],
         bindingScope = call.dispatchScope)

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

proc newSelectorCallStage(callee: Value, args: openArray[Value]): Value =
  var body = newSeqOfCap[Value](args.len + 1)
  body.add callee
  for arg in args:
    body.add arg
  newNode(newSym("call-stage"), body = body)

proc biStreamMap(args: openArray[Value]): Value {.nimcall.} =
  if args.len == 1:
    return newSelectorCallStage(newNativeFn("map", biStreamMap), args)
  if args.len != 2:
    raise newException(GeneError, "map expects 1 or 2 arguments, got " & $args.len)
  requireStream("map", args[0])
  newLazyStream(args[0], pullMapStream, callable = args[1])

proc biStreamFilter(args: openArray[Value]): Value {.nimcall.} =
  if args.len == 1:
    return newSelectorCallStage(newNativeFn("filter", biStreamFilter), args)
  if args.len != 2:
    raise newException(GeneError, "filter expects 1 or 2 arguments, got " & $args.len)
  requireStream("filter", args[0])
  newLazyStream(args[0], pullFilterStream, callable = args[1])

proc biStreamTake(args: openArray[Value]): Value {.nimcall.} =
  if args.len == 1:
    let remaining = requireInt64("take count", args[0])
    if remaining < 0:
      raise newException(GeneError, "take count must be non-negative")
    return newSelectorCallStage(newNativeFn("take", biStreamTake), args)
  if args.len != 2:
    raise newException(GeneError, "take expects 1 or 2 arguments, got " & $args.len)
  requireStream("take", args[0])
  var remaining = requireInt64("take count", args[1])
  if remaining < 0:
    raise newException(GeneError, "take count must be non-negative")
  newLazyStream(args[0], pullTakeStream, remaining = remaining)

proc biStreamInto(args: openArray[Value]): Value {.nimcall.} =
  if args.len == 1:
    if args[0].kind notin {vkList, vkMap}:
      raise newException(GeneError, "into expects a List or Map target")
    return newSelectorCallStage(newNativeFn("into", biStreamInto), args)
  if args.len != 2:
    raise newException(GeneError, "into expects 1 or 2 arguments, got " & $args.len)
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

proc biMapAssoc(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "Map/assoc expects 3 arguments, got " & $args.len)
  requireMap("Map/assoc", args[0])
  var entries = copyEntries(args[0].mapEntries)
  let key = keySegment("Map/assoc", args[1])
  if args[2].kind == vkVoid:
    entries.del(key)
  else:
    entries[key] = args[2]
  newMap(entries, args[0].mapImmutable)

proc biMapGet(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Map/get expects 2 arguments, got " & $args.len)
  requireMap("Map/get", args[0])
  args[0].mapEntries.getOrDefault(keySegment("Map/get", args[1]), VOID)

proc biNodeSetPropBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "Node/set-prop! expects 3 arguments, got " & $args.len)
  requireNode("Node/set-prop!", args[0])
  args[0].setNodeProp(keySegment("Node/set-prop!", args[1]), args[2])
  args[2]

proc requireBuffer(name: string, value: Value) =
  if value.kind != vkBuffer:
    raise newException(GeneError, name & " expects a Buffer")

proc requireDeviceBuffer(name: string, value: Value) =
  if value.kind != vkDeviceBuffer:
    raise newException(GeneError, name & " expects a Device/Buffer")

proc bufferTypeExprArg(name: string, value: Value): Value =
  if value.kind == vkNode and value.head.isSymbol("c-abi-type") and
      value.body.len == 1 and value.body[0].kind == vkSymbol:
    return newSym("C/" & value.body[0].symVal)
  case value.kind
  of vkSymbol, vkNode, vkType:
    value
  else:
    raise newException(GeneError,
      name & " expects a type expression or C ABI descriptor")

proc isAnyTypeValue(expr: Value): bool =
  expr.kind == vkNil or (expr.kind == vkSymbol and expr.symVal == "Any")

proc checkedBufferItem(buffer, item: Value, where: string,
                       fallbackScope: Scope): Value =
  let stored = if item.kind == vkVoid: NIL else: item
  let elemType = buffer.bufferElemType
  if elemType.isAnyTypeValue:
    return stored
  let elemScope =
    if buffer.bufferElemScope == nil: fallbackScope
    else: buffer.bufferElemScope
  adaptBoundary(where, elemType, stored, elemScope)

proc newCheckedBuffer*(elemType: Value, items: openArray[Value],
                       scope: Scope = nil): Value =
  var checkedType =
    if elemType.kind == vkNil:
      commonRuntimeTypeExpr(items)
    else:
      bufferTypeExprArg("buffer", elemType)
  checkedType = closeTypeExpr(checkedType, scope)
  var checkedItems: seq[Value]
  for item in items:
    let stored = if item.kind == vkVoid: NIL else: item
    if checkedType.isAnyTypeValue:
      checkedItems.add stored
    else:
      checkedItems.add adaptBoundary("buffer item", checkedType, stored, scope)
  newBuffer(checkedType, checkedItems)

proc getCheckedBufferItem*(buffer: Value, index: int): Value =
  if buffer.kind != vkBuffer:
    raise newException(GeneError, "Buffer/get expects a Buffer")
  readIndex(buffer.bufferItems, int64(index))

proc setCheckedBufferItem*(buffer: Value, index: int, item: Value,
                           scope: Scope = nil): Value =
  if buffer.kind != vkBuffer:
    raise newException(GeneError, "Buffer/set! expects a Buffer")
  let actualIndex = updateIndex("Buffer/set!", buffer.bufferLen, int64(index))
  result = checkedBufferItem(buffer, item, "Buffer/set! item", scope)
  buffer.setBufferItem(actualIndex, result)

proc biBuffer(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  var source: Value
  case args.len
  of 1:
    requireList("buffer", args[0])
    source = args[0]
    newCheckedBuffer(NIL, source.listItems, scope)
  of 2:
    requireList("buffer", args[1])
    source = args[1]
    newCheckedBuffer(args[0], source.listItems, scope)
  else:
    raise newException(GeneError,
      "buffer expects 1 or 2 arguments, got " & $args.len)

proc biBufferLen(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Buffer/len", args)
  requireBuffer("Buffer/len", args[0])
  newInt(args[0].bufferLen)

proc biBufferGet(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "Buffer/get expects 2 arguments, got " & $args.len)
  requireBuffer("Buffer/get", args[0])
  getCheckedBufferItem(args[0], int(requireInt64("Buffer/get", args[1])))

proc biBufferSetBang(args: openArray[Value],
                     call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "Buffer/set! expects 3 arguments, got " & $args.len)
  requireBuffer("Buffer/set!", args[0])
  let scope = if call == nil: nil else: call.dispatchScope
  setCheckedBufferItem(args[0], int(requireInt64("Buffer/set!", args[1])),
                       args[2], scope)

proc biBufferToList(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Buffer/to_list", args)
  requireBuffer("Buffer/to_list", args[0])
  newList(copyItems(args[0].bufferItems))

proc biBufferElemType(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Buffer/elem-type", args)
  requireBuffer("Buffer/elem-type", args[0])
  let elemType = args[0].bufferElemType
  if elemType.kind == vkNil: newSym("Any") else: elemType

proc biDeviceBuffer(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 4:
    raise newException(GeneError,
      "Device/buffer expects 4 arguments, got " & $args.len)
  if args[0].kind != vkCapability or args[0].capabilityName != "Device/Compute":
    raise newException(GeneError,
      "Device/buffer expects a Device/Compute capability")
  if args[1].kind != vkString:
    raiseTypeError("Device/buffer backend", "Str", args[1],
                   if call == nil: nil else: call.dispatchScope)
  let scope = if call == nil: nil else: call.dispatchScope
  let elemType = closeTypeExpr(bufferTypeExprArg("Device/buffer elem-type", args[2]),
                               scope)
  let rawLen = requireInt64("Device/buffer length", args[3])
  if rawLen < 0 or rawLen > int64(high(int)):
    raise newException(GeneError, "Device/buffer length must be non-negative")
  newDeviceBuffer(args[1].strVal, elemType, int(rawLen))

proc biDeviceBufferLen(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Device/Buffer/len", args)
  requireDeviceBuffer("Device/Buffer/len", args[0])
  newInt(args[0].deviceBufferLen)

proc biDeviceBufferBackend(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Device/Buffer/backend", args)
  requireDeviceBuffer("Device/Buffer/backend", args[0])
  newStr(args[0].deviceBufferBackend)

proc biDeviceBufferElemType(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Device/Buffer/elem-type", args)
  requireDeviceBuffer("Device/Buffer/elem-type", args[0])
  let elemType = args[0].deviceBufferElemType
  if elemType.kind == vkNil: newSym("Any") else: elemType

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

proc timerDeadline(milliseconds: int64): MonoTime =
  getMonoTime() + initDuration(milliseconds = milliseconds)

proc biSleep(args: openArray[Value]): Value {.nimcall.} =
  requireOne("sleep", args)
  let milliseconds = requireInt64("sleep", args[0])
  if milliseconds < 0:
    raise newException(GeneError, "sleep duration must be non-negative")
  if milliseconds == 0:
    return NIL
  let deadline = timerDeadline(milliseconds)
  if currentFiberActive:
    var se: ref SuspendError
    new(se)
    se.timer = true
    se.deadline = deadline
    raise se
  var workerLease: SchedulerWorkerLease
  var workerLeaseOpen = false
  defer:
    if workerLeaseOpen:
      endSchedulerWorkerLease(workerLease)
  while getMonoTime() < deadline:
    if not workerLeaseOpen:
      workerLease = beginSchedulerWorkerLease()
      workerLeaseOpen = true
    if not schedulerRunOneRootUntil(deadline, workerLease):
      let remaining = deadline - getMonoTime()
      if remaining <= initDuration():
        break
      os.sleep(max(1, int(min(remaining.inMilliseconds, int64(high(int))))))
  NIL

proc requireFfiLoad(name: string, value: Value) =
  if value.kind != vkFfiLoad:
    raise newException(GeneError, name & " expects an Ffi/Load capability")

proc requireFfiLibrary(name: string, value: Value) =
  if value.kind != vkFfiLibrary:
    raise newException(GeneError, name & " expects an Ffi/Library")

proc unloadFfiLibrary(handle: pointer) {.nimcall.} =
  unloadLib(cast[LibHandle](handle))

proc biFfiOpen(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "ffi/open expects 2 arguments, got " & $args.len)
  requireFfiLoad("ffi/open", args[0])
  requireStr("ffi/open", args[1])
  let path = args[1].strVal
  let handle = loadLib(path)
  if handle == nil:
    raise newException(GeneError, "ffi/open failed to load library: " & path)
  newFfiLibrary(cast[pointer](handle), path, unloadFfiLibrary)

proc biFfiBind(args: openArray[Value]): Value {.nimcall.} =
  if args.len notin 4..5:
    raise newException(GeneError,
      "ffi/bind expects 4..5 arguments, got " & $args.len)
  requireFfiLibrary("ffi/bind", args[0])
  if args[0].ffiLibraryClosed:
    raise newException(GeneError, "ffi/bind library is closed")
  requireStr("ffi/bind symbol", args[1])
  if args[2].kind != vkList:
    raise newException(GeneError, "ffi/bind parameter types must be a list")
  let symbol = args[1].strVal
  if symbol.len == 0:
    raise newException(GeneError, "ffi/bind symbol must not be empty")
  let address = symAddr(cast[LibHandle](args[0].ffiLibraryHandle),
                        symbol.cstring)
  if address == nil:
    raise newException(GeneError, "ffi/bind symbol not found: " & symbol)
  let returnLabel = typeExprLabel(args[3])
  var releaseName = ""
  var releaseAddress: pointer
  if args.len == 5:
    requireStr("ffi/bind release symbol", args[4])
    releaseName = args[4].strVal
    if releaseName.len == 0:
      raise newException(GeneError, "ffi/bind release symbol must not be empty")
    releaseAddress = symAddr(cast[LibHandle](args[0].ffiLibraryHandle),
                             releaseName.cstring)
    if releaseAddress == nil:
      raise newException(GeneError,
        "ffi/bind release symbol not found: " & releaseName)
  if returnLabel.startsWith("(C/OwnedPtr ") and releaseAddress == nil:
    raise newException(GeneError,
      "ffi/bind OwnedPtr result requires a release symbol")
  newFfiCallable(symbol, symbol, address, args[0], args[2].listItems,
                 args[3], releaseName, releaseAddress)

proc biFfiLibraryClose(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Ffi/Library/close", args)
  requireFfiLibrary("Ffi/Library/close", args[0])
  args[0].closeFfiLibrary()
  NIL

proc biFfiLibraryClosed(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Ffi/Library/closed?", args)
  requireFfiLibrary("Ffi/Library/closed?", args[0])
  newBool(args[0].ffiLibraryClosed)

proc biFfiLibraryPath(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Ffi/Library/path", args)
  requireFfiLibrary("Ffi/Library/path", args[0])
  newStr(args[0].ffiLibraryPath)

proc requireCPtr(name: string, value: Value) =
  if value.kind != vkCPtr:
    raise newException(GeneError, name & " expects a C pointer")

proc requireCapability(name: string, value: Value) =
  if value.kind != vkCapability:
    raise newException(GeneError, name & " expects a Capability")

proc biCapabilityName(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Capability/name", args)
  requireCapability("Capability/name", args[0])
  newStr(args[0].capabilityName)

proc biRuntimeGcStats(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "Runtime/gc-stats expects no arguments")
  var entries = initOrderedTable[string, Value]()
  entries["live-managed"] = newInt(managedLiveCount())
  entries["rc-stats?"] =
    when defined(geneRcStats):
      TRUE
    else:
      FALSE
  newMap(entries, immutable = true)

proc biCPtrClose(args: openArray[Value]): Value {.nimcall.} =
  requireOne("C/close", args)
  requireCPtr("C/close", args[0])
  args[0].closeCPtr()
  NIL

proc biCPtrClosed(args: openArray[Value]): Value {.nimcall.} =
  requireOne("C/closed?", args)
  requireCPtr("C/closed?", args[0])
  newBool(args[0].cPtrClosed)

proc cAbiTypeValue(name: string): Value =
  newNode(newSym("c-abi-type"), body = @[newSym(name)])

proc ffiTypeValue(name: string): Value =
  newNode(newSym("ffi-type"), body = @[newSym(name)])

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
  let actorFailure = newType("ActorFailure", NIL,
                             @[
                               TypeField(name: "actor", optional: false,
                                         typeExpr: newSym("Any"), scope: result),
                               TypeField(name: "failed-message", optional: false,
                                         typeExpr: newSym("Any"), scope: result),
                               TypeField(name: "message", optional: false,
                                         typeExpr: newSym("Str"), scope: result),
                               TypeField(name: "error", optional: false,
                                         typeExpr: newSym("Any"), scope: result),
                               TypeField(name: "panic", optional: false,
                                         typeExpr: newSym("Bool"), scope: result),
                               TypeField(name: "strategy", optional: false,
                                         typeExpr: newSym("Sym"), scope: result)
                             ],
                             @[sendProtocol], result)
  result.define("ActorFailure", actorFailure)
  result.impls.add ProtocolImpl(protocol: sendProtocol,
                                receiver: actorFailure,
                                messages: initTable[string, Value]())
  app.nativeAdd = newNativeFn("+", biAdd)
  app.nativeSub = newNativeFn("-", biSub)
  app.nativeMul = newNativeFn("*", biMul)
  app.nativeLt = newNativeFn("<", comparison("<", `<`))
  app.nativeGt = newNativeFn(">", comparison(">", `>`))
  app.nativeLe = newNativeFn("<=", comparison("<=", `<=`))
  app.nativeGe = newNativeFn(">=", comparison(">=", `>=`))
  result.define("+", app.nativeAdd)
  result.define("-", app.nativeSub)
  result.define("*", app.nativeMul)
  result.define("/", newNativeFn("/", biDiv))
  result.define("<", app.nativeLt)
  result.define(">", app.nativeGt)
  result.define("<=", app.nativeLe)
  result.define(">=", app.nativeGe)
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
  result.define("key", newNativeFn("key", biSelectorKey))
  result.define("buffer", newNativeCallFn("buffer", biBuffer,
                                          acceptsNamed = false))
  let listScope = newScope(result)
  listScope.define("assoc", newNativeFn("List/assoc", biListAssoc))
  listScope.define("set!", newNativeFn("List/set!", biListSetBang))
  result.define("List", newNamespace("List", listScope))
  let mapScope = newScope(result)
  mapScope.define("assoc", newNativeFn("Map/assoc", biMapAssoc))
  mapScope.define("get", newNativeFn("Map/get", biMapGet))
  mapScope.define("put!", newNativeFn("Map/put!", biMapPutBang))
  result.define("Map", newNamespace("Map", mapScope))
  let nodeScope = newScope(result)
  nodeScope.define("set-prop!", newNativeFn("Node/set-prop!", biNodeSetPropBang))
  result.define("Node", newNamespace("Node", nodeScope))
  let bufferScope = newScope(result)
  bufferScope.define("len", newNativeFn("Buffer/len", biBufferLen))
  bufferScope.define("get", newNativeFn("Buffer/get", biBufferGet))
  bufferScope.define("set!", newNativeCallFn("Buffer/set!", biBufferSetBang,
                                             acceptsNamed = false))
  bufferScope.define("to_list", newNativeFn("Buffer/to_list", biBufferToList))
  bufferScope.define("elem-type", newNativeFn("Buffer/elem-type", biBufferElemType))
  result.define("Buffer", newNamespace("Buffer", bufferScope))
  let deviceScope = newScope(result)
  deviceScope.define("Compute", newCapability("Device/Compute"))
  deviceScope.define("buffer", newNativeCallFn("Device/buffer", biDeviceBuffer,
                                               acceptsNamed = false))
  let deviceBufferScope = newScope(deviceScope)
  deviceBufferScope.define("len",
                           newNativeFn("Device/Buffer/len", biDeviceBufferLen))
  deviceBufferScope.define("backend",
                           newNativeFn("Device/Buffer/backend",
                                       biDeviceBufferBackend))
  deviceBufferScope.define("elem-type",
                           newNativeFn("Device/Buffer/elem-type",
                                       biDeviceBufferElemType))
  deviceScope.define("Buffer", newNamespace("Device/Buffer", deviceBufferScope))
  result.define("Device", newNamespace("Device", deviceScope))
  let capabilityScope = newScope(result)
  capabilityScope.define("name",
                         newNativeFn("Capability/name", biCapabilityName))
  result.define("Capability", newNamespace("Capability", capabilityScope))
  let runtimeScope = newScope(result)
  runtimeScope.define("gc-stats",
                      newNativeFn("Runtime/gc-stats", biRuntimeGcStats))
  result.define("Runtime", newNamespace("Runtime", runtimeScope))
  let fsScope = newScope(result)
  fsScope.define("ReadDir", newCapability("Fs/ReadDir"))
  fsScope.define("WriteDir", newCapability("Fs/WriteDir"))
  fsScope.define("ReadWriteDir", newCapability("Fs/ReadWriteDir"))
  result.define("Fs", newNamespace("Fs", fsScope))
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
  let cScope = newScope(result)
  cScope.define("close", newNativeFn("C/close", biCPtrClose))
  cScope.define("closed?", newNativeFn("C/closed?", biCPtrClosed))
  for name in ["Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32",
               "Int64", "UInt64", "Float", "Double", "Char", "UChar",
               "Short", "UShort", "Int", "UInt", "Long", "ULong",
               "Size", "PtrDiff", "Bool", "Void", "CStr",
               "Ptr", "NullablePtr", "ConstPtr", "NullableConstPtr",
               "OwnedPtr", "Slice"]:
    cScope.define(name, cAbiTypeValue(name))
  result.define("C", newNamespace("C", cScope))
  let ffiScope = newScope(result)
  ffiScope.define("open", newNativeFn("ffi/open", biFfiOpen))
  ffiScope.define("bind", newNativeFn("ffi/bind", biFfiBind))
  result.define("ffi", newNamespace("ffi", ffiScope))
  let ffiTypeScope = newScope(result)
  ffiTypeScope.define("Load", ffiTypeValue("Load"))
  ffiTypeScope.define("Callable", ffiTypeValue("Callable"))
  let ffiLibraryScope = newScope(ffiTypeScope)
  ffiLibraryScope.define("close",
                         newNativeFn("Ffi/Library/close", biFfiLibraryClose))
  ffiLibraryScope.define("closed?",
                         newNativeFn("Ffi/Library/closed?", biFfiLibraryClosed))
  ffiLibraryScope.define("path",
                         newNativeFn("Ffi/Library/path", biFfiLibraryPath))
  ffiTypeScope.define("Library", newNamespace("Ffi/Library", ffiLibraryScope))
  result.define("Ffi", newNamespace("Ffi", ffiTypeScope))
  let taskScope = newScope(result)
  taskScope.define("cancel", newNativeFn("Task/cancel", biTaskCancel))
  taskScope.define("detach", newNativeCallFn("Task/detach", biTaskDetach,
                                             acceptsNamed = false))
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
  actorScope.define("ask", newNativeCallFn("actor/ask", biActorAsk))
  actorScope.define("continue", newNativeFn("actor/continue", biActorContinue))
  actorScope.define("stop", newNativeFn("actor/stop", biActorStop))
  actorScope.define("snapshot", newNativeFn("actor/snapshot", biActorSnapshot))
  actorScope.define("upgrade", newNativeCallFn("actor/upgrade", biActorUpgrade))
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
  envScope.define("extend", newNativeCallFn("Env/extend", biEnvExtend,
                                            acceptsNamed = false))
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
  result.define("sleep", newNativeFn("sleep", biSleep))
  result.define("print", newNativeFn("print", biPrint))
  result.define("println", newNativeFn("println", biPrintln))

var gApplication: Application

proc normalizedDir(path: string): string =
  normalizedPath(absolutePath(if path.len > 0: path else: getCurrentDir()))

proc newSchedulerState(): SchedulerState =
  new(result)
  initLock(result.lock)
  when compileOption("threads") and defined(gcAtomicArc):
    initCond(result.workerCond)

proc newApplication*(entryDir = ""): Application =
  ## Create the runtime owner for one Gene program. MVP packages are represented
  ## by the root directory used for absolute/bare module resolution.
  let root = normalizedDir(entryDir)
  result = Application(moduleCache: initTable[string, Value](),
                       moduleLoading: initHashSet[string](),
                       scheduler: newSchedulerState(),
                       currentModuleDir: root,
                       packageRoot: root)

proc currentApplication(): Application =
  if gApplication == nil:
    gApplication = newApplication(getCurrentDir())
  gApplication

proc schedulerState(app: Application): SchedulerState =
  if app.scheduler == nil:
    app.scheduler = newSchedulerState()
  app.scheduler

proc currentScheduler(): SchedulerState =
  if activeScheduler != nil:
    return activeScheduler
  currentApplication().schedulerState()

proc schedulerForScope(scope: Scope): SchedulerState =
  if scope != nil and scope.application != nil:
    return Application(scope.application).schedulerState()
  currentApplication().schedulerState()

template withScheduler(scope: Scope, body: untyped): untyped =
  let savedScheduler = activeScheduler
  let scopedScheduler = schedulerForScope(scope)
  if activeScheduler == scopedScheduler:
    body
  else:
    activeScheduler = scopedScheduler
    try:
      body
    finally:
      activeScheduler = savedScheduler

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

proc fastNativeForKind(app: Application, kind: NativeFastKind): Value {.inline.} =
  case kind
  of nfkAdd: app.nativeAdd
  of nfkSub: app.nativeSub
  of nfkMul: app.nativeMul
  of nfkLt: app.nativeLt
  of nfkGt: app.nativeGt
  of nfkLe: app.nativeLe
  of nfkGe: app.nativeGe
  else: NIL

proc loadNativeFast(scope: Scope, kind: NativeFastKind, name: string): Value =
  let app = scope.application()
  result = app.fastNativeForKind(kind)
  if result.kind == vkNil:
    return scope.lookup(name)

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

proc pop(stack: var seq[Value]): Value {.inline.} =
  if stack.len == 0:
    raise newException(GeneError, "VM stack underflow")
  let index = stack.len - 1
  result = move stack[index]
  stack.setLen(index)

const MaxRunStackPool = 64

var runStackPool {.threadvar.}: array[MaxRunStackPool, seq[Value]]
var runStackPoolLen {.threadvar.}: int

proc acquireRunStack(): seq[Value] {.inline.} =
  if runStackPoolLen == 0:
    return @[]
  dec runStackPoolLen
  let index = runStackPoolLen
  result = move runStackPool[index]

proc releaseRunStack(stack: var seq[Value]) {.inline.} =
  stack.setLen(0)
  if runStackPoolLen < MaxRunStackPool:
    runStackPool[runStackPoolLen] = move stack
    inc runStackPoolLen

const MaxCallScopePool = 64

var callScopePool {.threadvar.}: array[MaxCallScopePool, Scope]
var callScopePoolLen {.threadvar.}: int

proc resetCallScopeSlots(scope: Scope, names: seq[string],
                         keepSlotNames = true) =
  if scope.slots.len != names.len:
    scope.slots.setLen(names.len)
  for i in 0 ..< scope.slots.len:
    scope.slots[i] = NIL
  scope.slotDefinedBits = 0
  if names.len > 64:
    scope.slotDefinedOverflow.setLen(names.len - 64)
    for i in 0 ..< scope.slotDefinedOverflow.len:
      scope.slotDefinedOverflow[i] = false
  else:
    if scope.slotDefinedOverflow.len != 0:
      scope.slotDefinedOverflow.setLen(0)
  if scope.slotTypes.len != 0:
    scope.slotTypes.setLen(0)
  if keepSlotNames:
    scope.slotNames = names
  elif scope.slotNames.len != 0:
    scope.slotNames.setLen(0)
  scope.slotMirror = false

proc resetCallScope(scope, parent: Scope, names: seq[string]) =
  scope.application =
    if parent != nil: parent.application
    else: nil
  scope.parent = parent
  scope.simpleCallScope = false
  scope.vars.clear()
  scope.varTypes.clear()
  scope.impls.setLen(0)
  scope.requiredImplTypes.setLen(0)
  scope.evalBudget =
    if parent != nil: parent.evalBudget
    else: nil
  scope.ownsTasks = false
  scope.ownedTasks.setLen(0)
  scope.ownsActors = false
  scope.actorFailureStrategy = afsStop
  scope.supervisorEvents = NIL
  scope.supervisorDeadLetters = NIL
  scope.ownedActors.setLen(0)
  scope.resetCallScopeSlots(names)

proc acquireCallScope(parent: Scope, names: seq[string]): Scope =
  if callScopePoolLen == 0:
    result = newScope(parent)
  else:
    dec callScopePoolLen
    let index = callScopePoolLen
    result = move callScopePool[index]
  result.resetCallScope(parent, names)

proc acquireSimpleCallScope(parent: Scope, names: seq[string],
                            keepSlotNames = true,
                            resetSlots = true): Scope =
  # Only simpleCall functions (no opDefineName/opSetName, no opTaskScope,
  # no opSupervisor, no opSpawn, no opMakeFn that escapes the scope) reach
  # this path. That exclusion guarantees vars/varTypes/impls/ownsTasks/
  # ownedTasks/actor fields are never populated, so we skip their clearing
  # and only need to zero the slot array (done by resetCallScopeSlots).
  if callScopePoolLen == 0:
    result = newScope(parent)
  else:
    dec callScopePoolLen
    let index = callScopePoolLen
    result = move callScopePool[index]
  result.application =
    if parent != nil: parent.application
    else: nil
  result.parent = parent
  result.simpleCallScope = true
  result.evalBudget =
    if parent != nil: parent.evalBudget
    else: nil
  if resetSlots:
    result.resetCallScopeSlots(names, keepSlotNames)
  else:
    if result.slots.len != names.len:
      result.slots.setLen(names.len)
    result.slotDefinedBits = 0
    if result.slotDefinedOverflow.len != 0:
      result.slotDefinedOverflow.setLen(0)
    if result.slotTypes.len != 0:
      result.slotTypes.setLen(0)
    if keepSlotNames:
      result.slotNames = names
    elif result.slotNames.len != 0:
      result.slotNames.setLen(0)
    result.slotMirror = false

proc bindSimpleCallSlots(scope: Scope, proto: FunctionProto,
                         args: openArray[Value]) {.inline.} =
  for i in 0 ..< args.len:
    scope.slots[proto.positionalSlots[i]] = args[i]
  if proto.positionalSlots.len <= 64:
    var bits = 0'u64
    for i in 0 ..< args.len:
      bits = bits or (1'u64 shl proto.positionalSlots[i])
    scope.slotDefinedBits = bits
  else:
    for i in 0 ..< args.len:
      scope.markSlotDefined(proto.positionalSlots[i])

proc canFastBindUnaryInt(proto: FunctionProto): bool {.inline.} =
  proto.typeParams.len == 0 and not proto.checksErrors and
    proto.params.len == 1 and proto.requiredPositional == 1 and
    proto.positionalSlots.len == 1 and proto.positionalSlots[0] >= 0 and
    proto.restParam.len == 0 and proto.namedParams.len == 0 and
    proto.hasParamTypes and proto.paramTypes.len == 1 and
    proto.paramTypes[0].isBareIntType and proto.hasReturnType and
    proto.returnType.isBareIntType and not proto.isGenerator and
    proto.paramDefaults.len == 1 and not proto.paramDefaults[0].optional

proc checkedFrameReturnType(proto: FunctionProto, returnType: Value): Value {.inline.} =
  if proto.returnKnownBareInt:
    NIL
  else:
    returnType

proc bindUnaryIntCallScope(parent: Scope, proto: FunctionProto,
                           arg: Value): Scope {.inline.} =
  result =
    if proto.poolCallScope:
      acquireCallScope(parent, proto.localNames)
    else:
      let fresh = newScope(parent)
      fresh.prepareSlots(proto.localNames)
      fresh
  let slot = proto.positionalSlots[0]
  result.defineFreshCallSlot(slot, arg)
  if proto.positionalSlotMaySet.len == 0 or proto.positionalSlotMaySet[0]:
    result.declareSlotType(slot, proto.paramTypes[0])

proc clearDefinedCallSlots(scope: Scope) {.inline.} =
  var bits = scope.slotDefinedBits
  var i = 0
  while bits != 0 and i < scope.slots.len:
    if (bits and 1'u64) != 0:
      scope.slots[i] = NIL
    bits = bits shr 1
    inc i
  scope.slotDefinedBits = 0
  if scope.slotDefinedOverflow.len != 0:
    for i in 0 ..< scope.slotDefinedOverflow.len:
      if scope.slotDefinedOverflow[i]:
        let slot = i + 64
        if slot < scope.slots.len:
          scope.slots[slot] = NIL
        scope.slotDefinedOverflow[i] = false

proc releaseCallScope(scope: Scope) =
  if scope == nil:
    return
  if scope.simpleCallScope:
    scope.clearDefinedCallSlots()
    if scope.slotTypes.len != 0:
      scope.slotTypes.setLen(0)
    scope.parent = nil
    scope.application = nil
    scope.evalBudget = nil
    if callScopePoolLen < MaxCallScopePool:
      callScopePool[callScopePoolLen] = scope
      inc callScopePoolLen
    else:
      scope.simpleCallScope = false
    return
  for i in 0 ..< scope.slots.len:
    scope.slots[i] = NIL
  scope.slotDefinedBits = 0
  if scope.slotDefinedOverflow.len != 0:
    for i in 0 ..< scope.slotDefinedOverflow.len:
      scope.slotDefinedOverflow[i] = false
  if scope.vars.len != 0:
    scope.vars.clear()
  if scope.varTypes.len != 0:
    scope.varTypes.clear()
  if scope.impls.len != 0:
    scope.impls.setLen(0)
  if scope.requiredImplTypes.len != 0:
    scope.requiredImplTypes.setLen(0)
  if scope.ownsTasks:
    scope.ownsTasks = false
  if scope.ownedTasks.len != 0:
    scope.ownedTasks.setLen(0)
  if scope.ownsActors:
    scope.ownsActors = false
  scope.actorFailureStrategy = afsStop
  scope.supervisorEvents = NIL
  scope.supervisorDeadLetters = NIL
  if scope.ownedActors.len != 0:
    scope.ownedActors.setLen(0)
  scope.parent = nil
  scope.application = nil
  scope.evalBudget = nil
  if callScopePoolLen < MaxCallScopePool:
    callScopePool[callScopePoolLen] = scope
    inc callScopePoolLen

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
  value.kind in {vkFunction, vkNativeFn, vkFfiCallable, vkType,
                 vkProtocolMessage} or
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
                          name: string, seen: var HashSet[uint64],
                          mode: CaptureSafetyMode): bool =
  let scope = capturedScope(fnScope, captureDepth)
  if scope == nil or slot < 0 or slot >= scope.slots.len:
    return false
  if not scope.slotDefined(slot):
    return false
  isSendableValue(scope.slots[slot], visibleScope, seen, mode)

proc namedCaptureSendable(fnScope, visibleScope: Scope, name: string,
                          seen: var HashSet[uint64],
                          ignoredNames: HashSet[string],
                          mode: CaptureSafetyMode): bool =
  if ignoredNames.contains(name):
    return true
  var captured: Value
  if not fnScope.lookupOptional(name, captured):
    return false
  isSendableValue(captured, visibleScope, seen, mode)

proc chunkCapturesSendable(chunk: Chunk, fnScope, visibleScope: Scope,
                           localDepth: int,
                           seen: var HashSet[uint64],
                           ignoredNames: HashSet[string],
                           mode: CaptureSafetyMode): bool

proc functionCallLocalNames(proto: FunctionProto): HashSet[string] =
  result = initHashSet[string]()
  for name in proto.params:
    result.incl name
  if proto.restParam.len > 0:
    result.incl proto.restParam
  for param in proto.namedParams:
    result.incl param.local

proc functionCapturesSendable(value: Value, visibleScope: Scope,
                              seen: var HashSet[uint64],
                              mode: CaptureSafetyMode): bool =
  let fnScope = value.fnScope
  if fnScope == nil:
    return true
  let code = value.fnCode
  if code == nil or not (code of FunctionProto):
    return false
  let proto = FunctionProto(code)
  if not chunkCapturesSendable(proto.chunk, fnScope, visibleScope, 0, seen,
                               initHashSet[string](), mode):
    return false
  let callLocals = functionCallLocalNames(proto)
  for defaultValue in proto.paramDefaults:
    if defaultValue.optional and defaultValue.defaultChunk != nil:
      if not chunkCapturesSendable(defaultValue.defaultChunk, fnScope,
                                   visibleScope, 0, seen, callLocals, mode):
        return false
  for param in proto.namedParams:
    if param.defaultValue.optional and param.defaultValue.defaultChunk != nil:
      if not chunkCapturesSendable(param.defaultValue.defaultChunk, fnScope,
                                   visibleScope, 0, seen, callLocals, mode):
        return false
  true

proc chunkCapturesSendable(chunk: Chunk, fnScope, visibleScope: Scope,
                           localDepth: int,
                           seen: var HashSet[uint64],
                           ignoredNames: HashSet[string],
                           mode: CaptureSafetyMode): bool =
  if chunk == nil:
    return true
  for inst in chunk.instructions:
    case inst.op
    of opLoadOuterLocal, opCallParentLocal1, opCallOuterLocal1:
      if inst.depth > localDepth:
        let captureDepth = inst.depth - localDepth
        if not capturedSlotSendable(fnScope, visibleScope, captureDepth,
                                    inst.intArg, inst.name, seen, mode):
          return false
    of opSetOuterLocal:
      if inst.depth > localDepth:
        return false
    of opLoadName, opLoadNativeFast, opCallName0, opCallName1:
      if not namedCaptureSendable(fnScope, visibleScope, inst.name, seen,
                                  ignoredNames, mode):
        return false
    of opSpawn:
      if mode == csmWorker:
        return false
    of opSetName:
      return false
    else:
      discard

  for body in chunk.subchunks:
    if not chunkCapturesSendable(body, fnScope, visibleScope,
                                 localDepth + 1, seen, ignoredNames, mode):
      return false
  for loop in chunk.forLoops:
    if not chunkCapturesSendable(loop.body, fnScope, visibleScope,
                                 localDepth + 1, seen, ignoredNames, mode):
      return false
  for match in chunk.matches:
    for clause in match.clauses:
      if not chunkCapturesSendable(clause.body, fnScope, visibleScope,
                                   localDepth + 1, seen, ignoredNames, mode):
        return false
    if not chunkCapturesSendable(match.elseBody, fnScope, visibleScope,
                                 localDepth + 1, seen, ignoredNames, mode):
      return false
  for attempt in chunk.tries:
    if not chunkCapturesSendable(attempt.body, fnScope, visibleScope,
                                 localDepth, seen, ignoredNames, mode):
      return false
    for clause in attempt.catches:
      if not chunkCapturesSendable(clause.body, fnScope, visibleScope,
                                   localDepth + 1, seen, ignoredNames, mode):
        return false
    if not chunkCapturesSendable(attempt.ensureBody, fnScope, visibleScope,
                                 localDepth, seen, ignoredNames, mode):
      return false
  true

proc isSendableValue(value: Value, scope: Scope,
                     seen: var HashSet[uint64],
                     mode = csmSend): bool =
  if value.kind in {vkList, vkMap, vkNode, vkFunction}:
    if seen.contains(value.bits):
      return true
    seen.incl value.bits
  case value.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkChar, vkSymbol,
     vkNativeFn, vkAtomicCell, vkTask, vkChannel, vkActorRef, vkReplyTo,
     vkType, vkProtocol, vkProtocolMessage:
    true
  of vkFunction:
    functionCapturesSendable(value, scope, seen, mode)
  of vkNode:
    var sendProtocol: Value
    if value.head.kind == vkType and scope != nil and
        scope.lookupOptional("Send", sendProtocol) and
        sendProtocol.kind == vkProtocol and
        scope.typeImplementsProtocol(value.head, sendProtocol):
      return true
    if not value.nodeImmutable:
      return false
    if not isSendableValue(value.head, scope, seen, mode):
      return false
    for _, item in value.props:
      if not isSendableValue(item, scope, seen, mode):
        return false
    for item in value.body:
      if not isSendableValue(item, scope, seen, mode):
        return false
    for _, item in value.meta:
      if not isSendableValue(item, scope, seen, mode):
        return false
    true
  of vkList:
    if not value.listImmutable:
      return false
    for item in value.listItems:
      if not isSendableValue(item, scope, seen, mode):
        return false
    true
  of vkMap:
    if not value.mapImmutable:
      return false
    for _, item in value.mapEntries:
      if not isSendableValue(item, scope, seen, mode):
        return false
    true
  of vkNamespace, vkModule, vkEnv, vkCell, vkStream, vkActorContext,
     vkActorStep, vkCPtr, vkCSlice, vkBuffer,
     vkDeviceBuffer, vkCapability, vkFfiLoad, vkFfiLibrary, vkFfiCallable:
    false

proc isSendableValue(value: Value, scope: Scope): bool =
  var seen = initHashSet[uint64]()
  isSendableValue(value, scope, seen)

proc spawnCanMoveToWorker(scope: Scope, body: Chunk): bool =
  var seen = initHashSet[uint64]()
  chunkCapturesSendable(body, scope, scope, 0, seen, initHashSet[string](),
                        csmWorker)

type
  CapturedSlot = object
    depth: int
    slot: int
    name: string

  SpawnCaptureSet = object
    slots: seq[CapturedSlot]
    names: seq[string]
    nameSet: HashSet[string]

proc addCaptureSlot(captures: var SpawnCaptureSet, depth, slot: int,
                    name: string) =
  for captured in captures.slots:
    if captured.depth == depth and captured.slot == slot:
      return
  captures.slots.add CapturedSlot(depth: depth, slot: slot, name: name)

proc addCaptureName(captures: var SpawnCaptureSet, name: string,
                    ignoredNames: HashSet[string]) =
  if ignoredNames.contains(name) or captures.nameSet.contains(name):
    return
  captures.nameSet.incl name
  captures.names.add name

proc collectSpawnCaptures(chunk: Chunk, localDepth: int,
                          ignoredNames: HashSet[string],
                          captures: var SpawnCaptureSet) =
  if chunk == nil:
    return
  for inst in chunk.instructions:
    case inst.op
    of opLoadOuterLocal, opCallParentLocal1, opCallOuterLocal1:
      if inst.depth > localDepth:
        captures.addCaptureSlot(inst.depth - localDepth, inst.intArg, inst.name)
    of opLoadName, opLoadNativeFast, opCallName0, opCallName1:
      captures.addCaptureName(inst.name, ignoredNames)
    else:
      discard

  for body in chunk.subchunks:
    collectSpawnCaptures(body, localDepth + 1, ignoredNames, captures)
  for loop in chunk.forLoops:
    collectSpawnCaptures(loop.body, localDepth + 1, ignoredNames, captures)
  for match in chunk.matches:
    for clause in match.clauses:
      collectSpawnCaptures(clause.body, localDepth + 1, ignoredNames, captures)
    collectSpawnCaptures(match.elseBody, localDepth + 1, ignoredNames, captures)
  for attempt in chunk.tries:
    collectSpawnCaptures(attempt.body, localDepth, ignoredNames, captures)
    for clause in attempt.catches:
      collectSpawnCaptures(clause.body, localDepth + 1, ignoredNames, captures)
    collectSpawnCaptures(attempt.ensureBody, localDepth, ignoredNames, captures)
  for proto in chunk.functions:
    let callLocals = functionCallLocalNames(proto)
    collectSpawnCaptures(proto.chunk, localDepth + 1, callLocals, captures)
    for defaultValue in proto.paramDefaults:
      if defaultValue.optional and defaultValue.defaultChunk != nil:
        collectSpawnCaptures(defaultValue.defaultChunk, localDepth + 1,
                             callLocals, captures)
    for param in proto.namedParams:
      if param.defaultValue.optional and param.defaultValue.defaultChunk != nil:
        collectSpawnCaptures(param.defaultValue.defaultChunk, localDepth + 1,
                             callLocals, captures)

proc cloneForCapturedSnapshot(value: Value,
                              scopeMap: var Table[pointer, Scope]): Value

proc copyChunkCapturesToSnapshots(source: Scope, chunk: Chunk,
                                  scopeMap: var Table[pointer, Scope],
                                  ignoredNames: HashSet[string])

proc captureValueAtDepth(source: Scope, depth, slot: int,
                         name: string): tuple[scope: Scope, value: Value]

proc cloneForCapturedSnapshot(value: Value,
                              scopeMap: var Table[pointer, Scope]): Value =
  case value.kind
  of vkFunction:
    let sourceScope = value.fnScope
    if sourceScope != nil:
      let key = cast[pointer](sourceScope)
      if scopeMap.hasKey(key):
        let code = value.fnCode
        if code != nil and code of FunctionProto:
          let proto = FunctionProto(code)
          copyChunkCapturesToSnapshots(sourceScope, proto.chunk, scopeMap,
                                       initHashSet[string]())
          let callLocals = functionCallLocalNames(proto)
          for defaultValue in proto.paramDefaults:
            if defaultValue.optional and defaultValue.defaultChunk != nil:
              copyChunkCapturesToSnapshots(sourceScope,
                                           defaultValue.defaultChunk,
                                           scopeMap, callLocals)
          for param in proto.namedParams:
            if param.defaultValue.optional and
                param.defaultValue.defaultChunk != nil:
              copyChunkCapturesToSnapshots(sourceScope,
                                           param.defaultValue.defaultChunk,
                                           scopeMap, callLocals)
        var params: seq[string]
        for param in value.fnParams:
          params.add param
        var errorTypes: seq[Value]
        for err in value.fnErrorTypes:
          errorTypes.add cloneForCapturedSnapshot(err, scopeMap)
        return newFunction(value.fnName, params, value.fnCode, scopeMap[key],
                           value.fnChecksErrors, errorTypes)
    value
  of vkList:
    var items: seq[Value]
    var changed = false
    for item in value.listItems:
      let cloned = cloneForCapturedSnapshot(item, scopeMap)
      if cloned.bits != item.bits:
        changed = true
      items.add cloned
    if changed: newList(items, immutable = value.listImmutable)
    else: value
  of vkMap:
    var entries = initOrderedTable[string, Value]()
    var changed = false
    for key, item in value.mapEntries:
      let cloned = cloneForCapturedSnapshot(item, scopeMap)
      if cloned.bits != item.bits:
        changed = true
      entries[key] = cloned
    if changed: newMap(entries, immutable = value.mapImmutable)
    else: value
  of vkNode:
    let clonedHead = cloneForCapturedSnapshot(value.head, scopeMap)
    var props = initOrderedTable[string, Value]()
    var body: seq[Value]
    var meta = initOrderedTable[string, Value]()
    var changed = clonedHead.bits != value.head.bits
    for key, item in value.props:
      let cloned = cloneForCapturedSnapshot(item, scopeMap)
      if cloned.bits != item.bits:
        changed = true
      props[key] = cloned
    for item in value.body:
      let cloned = cloneForCapturedSnapshot(item, scopeMap)
      if cloned.bits != item.bits:
        changed = true
      body.add cloned
    for key, item in value.meta:
      let cloned = cloneForCapturedSnapshot(item, scopeMap)
      if cloned.bits != item.bits:
        changed = true
      meta[key] = cloned
    if changed:
      newNode(clonedHead, props = props, body = body, meta = meta,
              immutable = value.nodeImmutable)
    else:
      value
  else:
    value

proc copyChunkCapturesToSnapshots(source: Scope, chunk: Chunk,
                                  scopeMap: var Table[pointer, Scope],
                                  ignoredNames: HashSet[string]) =
  var captures = SpawnCaptureSet(nameSet: initHashSet[string]())
  collectSpawnCaptures(chunk, 0, ignoredNames, captures)

  for captured in captures.slots:
    let loaded = captureValueAtDepth(source, captured.depth, captured.slot,
                                     captured.name)
    let snapshot = scopeMap.getOrDefault(cast[pointer](loaded.scope), nil)
    if snapshot == nil:
      continue
    if snapshot.slotDefined(captured.slot):
      continue
    snapshot.slots[captured.slot] = loaded.value
    snapshot.markSlotDefined(captured.slot)
    snapshot.slots[captured.slot] =
      cloneForCapturedSnapshot(loaded.value, scopeMap)
    if snapshot.slotMirror:
      snapshot.vars[captured.name] = snapshot.slots[captured.slot]

  let rootSnapshot = scopeMap.getOrDefault(cast[pointer](source), nil)
  if rootSnapshot != nil:
    for name in captures.names:
      if rootSnapshot.vars.hasKey(name):
        continue
      var value: Value
      if not source.lookupOptional(name, value):
        raise newException(GeneError, "undefined symbol: " & name)
      rootSnapshot.vars[name] = value
      rootSnapshot.vars[name] = cloneForCapturedSnapshot(value, scopeMap)

proc snapshotTypeBinding(binding: TypeBinding,
                         scopeMap: var Table[pointer, Scope]): TypeBinding =
  result.expr = cloneForCapturedSnapshot(binding.expr, scopeMap)
  if binding.scope != nil:
    let key = cast[pointer](binding.scope)
    result.scope = scopeMap.getOrDefault(key, binding.scope)
  elif binding.weakScope != nil:
    result.weakScope =
      cast[pointer](scopeMap.getOrDefault(binding.weakScope,
                                          cast[Scope](binding.weakScope)))

proc snapshotScopeChain(source: Scope,
                        scopeMap: var Table[pointer, Scope]): Scope =
  if source == nil:
    return nil
  let app = source.application()
  let builtins = app.builtinsScope()
  if source == builtins:
    return builtins
  let key = cast[pointer](source)
  if scopeMap.hasKey(key):
    return scopeMap[key]

  let parent = snapshotScopeChain(source.parent, scopeMap)
  result = newScope(parent, application = source.application)
  scopeMap[key] = result
  if source.slots.len > 0:
    result.slots = newSeq[Value](source.slots.len)
    result.slotDefinedBits = 0
    if source.slots.len > 64:
      result.slotDefinedOverflow = newSeq[bool](source.slots.len - 64)
  result.slotNames = source.slotNames
  for binding in source.slotTypes:
    result.slotTypes.add snapshotTypeBinding(binding, scopeMap)
  result.slotMirror = source.slotMirror
  for name, binding in source.varTypes:
    result.varTypes[name] = snapshotTypeBinding(binding, scopeMap)
  for impl in source.impls:
    var messages = initTable[string, Value]()
    for message, fn in impl.messages:
      messages[message] = cloneForCapturedSnapshot(fn, scopeMap)
    result.impls.add ProtocolImpl(protocol: impl.protocol,
                                  receiver: impl.receiver,
                                  messages: messages)
  result.requiredImplTypes = source.requiredImplTypes
  result.evalBudget = source.evalBudget

proc captureValueAtDepth(source: Scope, depth, slot: int,
                         name: string): tuple[scope: Scope, value: Value] =
  result.scope = capturedScope(source, depth)
  if result.scope == nil or slot < 0 or slot >= result.scope.slots.len:
    raise newException(GeneError, "undefined symbol: " & name)
  if not result.scope.slotDefined(slot):
    raise newException(GeneError, "undefined symbol: " & name)
  result.value = result.scope.slots[slot]

proc snapshotSpawnScope(source: Scope, body: Chunk): Scope =
  var scopeMap = initTable[pointer, Scope]()
  result = snapshotScopeChain(source, scopeMap)
  copyChunkCapturesToSnapshots(source, body, scopeMap, initHashSet[string]())

proc publishSpawnScope(scope: Scope, seenScopes: var HashSet[pointer],
                       seenValues: var HashSet[uint64],
                       seenChunks: var HashSet[pointer])
proc publishSpawnValue(value: Value, seenScopes: var HashSet[pointer],
                       seenValues: var HashSet[uint64],
                       seenChunks: var HashSet[pointer])

proc publishSpawnFunctionProto(proto: FunctionProto,
                               seenScopes: var HashSet[pointer],
                               seenValues: var HashSet[uint64],
                               seenChunks: var HashSet[pointer])

proc publishSpawnChunk(chunk: Chunk, seenScopes: var HashSet[pointer],
                       seenValues: var HashSet[uint64],
                       seenChunks: var HashSet[pointer]) =
  if chunk == nil:
    return
  let key = cast[pointer](chunk)
  if seenChunks.contains(key):
    return
  seenChunks.incl key
  for value in chunk.constants:
    publishSpawnValue(value, seenScopes, seenValues, seenChunks)
  for _, site in chunk.callSites:
    publishSpawnValue(site, seenScopes, seenValues, seenChunks)
  for fn in chunk.functions:
    publishSpawnFunctionProto(fn, seenScopes, seenValues, seenChunks)
  for body in chunk.subchunks:
    publishSpawnChunk(body, seenScopes, seenValues, seenChunks)
  for loop in chunk.forLoops:
    publishSpawnValue(loop.pattern, seenScopes, seenValues, seenChunks)
    publishSpawnChunk(loop.body, seenScopes, seenValues, seenChunks)
  for match in chunk.matches:
    for clause in match.clauses:
      publishSpawnValue(clause.pattern, seenScopes, seenValues, seenChunks)
      publishSpawnChunk(clause.body, seenScopes, seenValues, seenChunks)
    publishSpawnChunk(match.elseBody, seenScopes, seenValues, seenChunks)
  for attempt in chunk.tries:
    publishSpawnChunk(attempt.body, seenScopes, seenValues, seenChunks)
    for clause in attempt.catches:
      publishSpawnValue(clause.pattern, seenScopes, seenValues, seenChunks)
      publishSpawnChunk(clause.body, seenScopes, seenValues, seenChunks)
    publishSpawnChunk(attempt.ensureBody, seenScopes, seenValues, seenChunks)
  for proto in chunk.typeProtos:
    for field in proto.fields:
      publishSpawnValue(field.typeExpr, seenScopes, seenValues, seenChunks)
      publishSpawnScope(field.typeFieldScope(nil), seenScopes, seenValues, seenChunks)
    for field in proto.bodyFields:
      publishSpawnValue(field.typeExpr, seenScopes, seenValues, seenChunks)
      publishSpawnScope(field.typeBodyFieldScope(nil), seenScopes, seenValues, seenChunks)
    for value in proto.deriveRequests:
      publishSpawnValue(value, seenScopes, seenValues, seenChunks)
  for proto in chunk.protocolProtos:
    publishSpawnFunctionProto(proto.deriveFn, seenScopes, seenValues, seenChunks)
  for proto in chunk.implProtos:
    for message in proto.messages:
      publishSpawnFunctionProto(message.fn, seenScopes, seenValues, seenChunks)
  for ffi in chunk.ffiFns:
    for param in ffi.params:
      publishSpawnValue(param.typeExpr, seenScopes, seenValues, seenChunks)
    publishSpawnValue(ffi.returnType, seenScopes, seenValues, seenChunks)
  for ffi in chunk.ffiStructs:
    for field in ffi.fields:
      publishSpawnValue(field.typeExpr, seenScopes, seenValues, seenChunks)
  for ffi in chunk.ffiUnions:
    for field in ffi.fields:
      publishSpawnValue(field.typeExpr, seenScopes, seenValues, seenChunks)
  for sig in chunk.ffiSignatures:
    for param in sig.params:
      publishSpawnValue(param.typeExpr, seenScopes, seenValues, seenChunks)
    publishSpawnValue(sig.returnType, seenScopes, seenValues, seenChunks)
  for call in chunk.directProtocolCalls:
    publishSpawnValue(call.protocolExpr, seenScopes, seenValues, seenChunks)
    publishSpawnValue(call.receiverExpr, seenScopes, seenValues, seenChunks)

proc publishSpawnFunctionProto(proto: FunctionProto,
                               seenScopes: var HashSet[pointer],
                               seenValues: var HashSet[uint64],
                               seenChunks: var HashSet[pointer]) =
  if proto == nil:
    return
  for value in proto.paramTypes:
    publishSpawnValue(value, seenScopes, seenValues, seenChunks)
  for param in proto.namedParams:
    publishSpawnValue(param.typeExpr, seenScopes, seenValues, seenChunks)
    if param.defaultValue.optional:
      publishSpawnChunk(param.defaultValue.defaultChunk, seenScopes,
                        seenValues, seenChunks)
  for defaultValue in proto.paramDefaults:
    if defaultValue.optional:
      publishSpawnChunk(defaultValue.defaultChunk, seenScopes, seenValues,
                        seenChunks)
  publishSpawnValue(proto.returnType, seenScopes, seenValues, seenChunks)
  publishSpawnValue(proto.aotExpr, seenScopes, seenValues, seenChunks)
  publishSpawnChunk(proto.chunk, seenScopes, seenValues, seenChunks)

proc publishSpawnValue(value: Value, seenScopes: var HashSet[pointer],
                       seenValues: var HashSet[uint64],
                       seenChunks: var HashSet[pointer]) =
  if seenValues.contains(value.bits):
    return
  seenValues.incl value.bits
  markSharedValue(value)
  case value.kind
  of vkList:
    for item in value.listItems:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkMap:
    for _, item in value.mapEntries:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkNode:
    publishSpawnValue(value.head, seenScopes, seenValues, seenChunks)
    for _, item in value.props:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
    for item in value.body:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
    for _, item in value.meta:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkFunction:
    publishSpawnScope(value.fnScope, seenScopes, seenValues, seenChunks)
    for errType in value.fnErrorTypes:
      publishSpawnValue(errType, seenScopes, seenValues, seenChunks)
    let code = value.fnCode
    if code != nil and code of FunctionProto:
      publishSpawnFunctionProto(FunctionProto(code), seenScopes, seenValues,
                                seenChunks)
  of vkNamespace:
    publishSpawnScope(value.nsScope, seenScopes, seenValues, seenChunks)
  of vkModule:
    publishSpawnValue(value.moduleRootNamespace, seenScopes, seenValues,
                      seenChunks)
    for _, item in value.moduleMeta:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkEnv:
    publishSpawnValue(value.envParent, seenScopes, seenValues, seenChunks)
    for _, item in value.envBindings:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
    for item in value.envImports:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.envModule, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.envCapabilities, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.envPolicy, seenScopes, seenValues, seenChunks)
  of vkStream:
    publishSpawnValue(value.streamSource, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.streamCallable, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.streamItemType, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.streamErrType, seenScopes, seenValues, seenChunks)
    publishSpawnScope(value.streamItemScope, seenScopes, seenValues, seenChunks)
    publishSpawnScope(value.streamGeneratorScope, seenScopes, seenValues,
                      seenChunks)
    for item in value.streamGeneratorStack:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkTask:
    publishSpawnValue(value.taskResultType, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.taskErrorType, seenScopes, seenValues, seenChunks)
    publishSpawnScope(value.taskBoundaryScope, seenScopes, seenValues,
                      seenChunks)
    publishSpawnValue(value.taskResult, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.taskErrorValue, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.taskPanicValue, seenScopes, seenValues, seenChunks)
  of vkChannel:
    publishSpawnValue(value.channelItemType, seenScopes, seenValues, seenChunks)
    publishSpawnScope(value.channelItemScope, seenScopes, seenValues, seenChunks)
    for item in value.channelItemsSnapshot:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkActorRef:
    publishSpawnValue(value.actorState, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.actorRestartInit, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.actorHandler, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.actorMessageType, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.actorFailureEvents, seenScopes, seenValues,
                      seenChunks)
    publishSpawnValue(value.actorFailureDeadLetters, seenScopes, seenValues,
                      seenChunks)
    for item in value.actorMessagesSnapshot:
      publishSpawnValue(item.message, seenScopes, seenValues, seenChunks)
      publishSpawnValue(item.reply, seenScopes, seenValues, seenChunks)
  of vkActorContext:
    publishSpawnValue(value.actorContextActor, seenScopes, seenValues, seenChunks)
  of vkActorStep:
    publishSpawnValue(value.actorStepState, seenScopes, seenValues, seenChunks)
  of vkReplyTo:
    publishSpawnValue(value.replyToResult, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.replyToResultType, seenScopes, seenValues,
                      seenChunks)
    publishSpawnScope(value.replyToResultScope, seenScopes, seenValues,
                      seenChunks)
    publishSpawnValue(value.replyToTask, seenScopes, seenValues, seenChunks)
  of vkCPtr:
    publishSpawnValue(value.cPtrTargetType, seenScopes, seenValues, seenChunks)
  of vkCSlice:
    publishSpawnValue(value.cSliceTargetType, seenScopes, seenValues, seenChunks)
  of vkBuffer:
    publishSpawnValue(value.bufferElemType, seenScopes, seenValues, seenChunks)
    publishSpawnScope(value.bufferElemScope, seenScopes, seenValues, seenChunks)
    for item in value.bufferItems:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkDeviceBuffer:
    publishSpawnValue(value.deviceBufferElemType, seenScopes, seenValues,
                      seenChunks)
  of vkFfiCallable:
    publishSpawnValue(value.ffiCallableLibrary, seenScopes, seenValues,
                      seenChunks)
    for paramType in value.ffiCallableParamTypes:
      publishSpawnValue(paramType, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.ffiCallableReturnType, seenScopes, seenValues,
                      seenChunks)
  of vkType:
    publishSpawnValue(value.typeParent, seenScopes, seenValues, seenChunks)
    publishSpawnScope(value.typeScope, seenScopes, seenValues, seenChunks)
    for field in value.typeFields:
      publishSpawnValue(field.typeExpr, seenScopes, seenValues, seenChunks)
      publishSpawnScope(field.typeFieldScope(value.typeScope), seenScopes,
                        seenValues, seenChunks)
    for field in value.typeBodyFields:
      publishSpawnValue(field.typeExpr, seenScopes, seenValues, seenChunks)
      publishSpawnScope(field.typeBodyFieldScope(value.typeScope), seenScopes,
                        seenValues, seenChunks)
    for item in value.typeRequiredProtocols:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
    for item in value.typeDerivedProtocols:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
    for item in value.typeDeriveRequests:
      publishSpawnValue(item, seenScopes, seenValues, seenChunks)
  of vkProtocol:
    for _, message in value.protocolMessages:
      publishSpawnValue(message, seenScopes, seenValues, seenChunks)
    publishSpawnValue(value.protocolDeriveFn, seenScopes, seenValues, seenChunks)
  of vkProtocolMessage:
    publishSpawnValue(value.protocolMessageProtocol, seenScopes, seenValues,
                      seenChunks)
  else:
    discard

proc publishSpawnScope(scope: Scope, seenScopes: var HashSet[pointer],
                       seenValues: var HashSet[uint64],
                       seenChunks: var HashSet[pointer]) =
  var current = scope
  while current != nil:
    let key = cast[pointer](current)
    if seenScopes.contains(key):
      return
    seenScopes.incl key
    if current.application != nil:
      let app = Application(current.application)
      if app.builtins == current:
        if app.spawnBuiltinsPublished:
          return
        app.spawnBuiltinsPublished = true
    for i in 0 ..< current.slots.len:
      if current.slotDefined(i):
        publishSpawnValue(current.slots[i], seenScopes, seenValues, seenChunks)
    for _, value in current.vars:
      publishSpawnValue(value, seenScopes, seenValues, seenChunks)
    for binding in current.slotTypes:
      publishSpawnValue(binding.expr, seenScopes, seenValues, seenChunks)
      publishSpawnScope(binding.typeBindingScope, seenScopes, seenValues,
                        seenChunks)
    for _, binding in current.varTypes:
      publishSpawnValue(binding.expr, seenScopes, seenValues, seenChunks)
      publishSpawnScope(binding.typeBindingScope, seenScopes, seenValues,
                        seenChunks)
    for impl in current.impls:
      publishSpawnValue(impl.protocol, seenScopes, seenValues, seenChunks)
      publishSpawnValue(impl.receiver, seenScopes, seenValues, seenChunks)
      for _, message in impl.messages:
        publishSpawnValue(message, seenScopes, seenValues, seenChunks)
    for value in current.requiredImplTypes:
      publishSpawnValue(value, seenScopes, seenValues, seenChunks)
    publishSpawnValue(current.supervisorEvents, seenScopes, seenValues,
                      seenChunks)
    publishSpawnValue(current.supervisorDeadLetters, seenScopes, seenValues,
                      seenChunks)
    for task in current.ownedTasks:
      publishSpawnValue(task, seenScopes, seenValues, seenChunks)
    for actor in current.ownedActors:
      publishSpawnValue(actor, seenScopes, seenValues, seenChunks)
    current = current.parent

proc publishSpawnCapture(scope: Scope, chunk: Chunk) =
  var seenScopes = initHashSet[pointer]()
  var seenValues = initHashSet[uint64]()
  var seenChunks = initHashSet[pointer]()
  publishSpawnScope(scope, seenScopes, seenValues, seenChunks)
  publishSpawnChunk(chunk, seenScopes, seenValues, seenChunks)

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

proc taskBoundaryScopeOr(task: Value, fallback: Scope = nil): Scope =
  let boundaryScope = task.taskBoundaryScope
  if boundaryScope == nil: fallback else: boundaryScope

proc checkedTaskResult(task, value: Value): Value =
  let resultType = task.taskResultType
  if resultType.kind == vkNil:
    return value
  adaptBoundary("await task result", resultType, value,
                taskBoundaryScopeOr(task))

proc isBoundaryTypeError(value: Value, scope: Scope): bool =
  if value.kind != vkNode:
    return false
  var typeError: Value
  scope != nil and scope.lookupOptional("TypeError", typeError) and
    typeError.kind == vkType and value.head.isSubtypeOf(typeError)

proc checkTaskError(task: Value, hasValue: bool, value: Value) =
  let errorType = task.taskErrorType
  if errorType.kind == vkNil or not hasValue:
    return
  # Boundary TypeError is raised by the boundary itself, not classified as the
  # task's domain error E.
  if isBoundaryTypeError(value, taskBoundaryScopeOr(task)):
    return
  discard adaptBoundary("await task error", errorType, value,
                        taskBoundaryScopeOr(task))

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
    try:
      checkTaskError(task, hasValue, value)
    finally:
      task.clearTaskPayload()
    var e: ref GeneError
    new(e)
    e.msg = msg
    if hasValue:
      e.errVal = value
      e.hasErrVal = true
    raise e
  if task.taskCancelled:
    task.clearTaskPayload()
    raise newException(GeneCancel, "task was cancelled")
  let value = task.taskResult
  try:
    result = checkedTaskResult(task, value)
  finally:
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

proc stackFrameValue(name, kind: string): Value =
  var props = initOrderedTable[string, Value]()
  props["name"] = newStr(name)
  props["kind"] = newStr(kind)
  newNode(newSym("StackFrame"), props = props, immutable = true)

proc appendTraceFrames(e: ref GeneError, traceFrames: openArray[Value]) =
  if e == nil or traceFrames.len == 0 or not e.hasErrVal or
      e.errVal.kind != vkNode:
    return
  var props = copyEntries(e.errVal.props)
  var items: seq[Value]
  if props.hasKey("trace") and props["trace"].kind == vkList:
    items = copyItems(props["trace"].listItems)
  for frame in traceFrames:
    items.add frame
  props["trace"] = newList(items, immutable = true)
  e.errVal = newNode(e.errVal.head, props = props,
                     body = copyItems(e.errVal.body),
                     meta = copyEntries(e.errVal.meta),
                     immutable = e.errVal.nodeImmutable)

proc appendVmTrace(e: ref GeneError, curFnName: string,
                   frames: openArray[Frame]) =
  var traceFrames: seq[Value]
  if curFnName.len > 0:
    traceFrames.add stackFrameValue(curFnName, "bytecode")
  if frames.len > 0:
    for i in countdown(frames.len - 1, 0):
      if frames[i].fnName.len > 0:
        traceFrames.add stackFrameValue(frames[i].fnName, "bytecode")
  appendTraceFrames(e, traceFrames)

proc appendNativeTrace(e: ref GeneError, calleeName: string,
                       proto: FunctionProto) =
  let kind =
    if proto.nativeOp != ncoNone or proto.aotFrameKind == afkTypedNative:
      "typed-native"
    else:
      "native"
  appendTraceFrames(e, [stackFrameValue(calleeName, kind)])

# Cooperative scheduler state. The default lane is root-thread cooperative; in
# atomicArc threaded builds, `GENE_WORKERS=N` can add an opt-in OS-thread lane
# for snapshot-isolated worker candidates while root blocking waits keep the
# unsafe lane cooperative. The scheduler's lock-backed run queue holds runnable
# fibers; its wait list holds fibers parked on a channel, actor mailbox, task
# await, or timer. `currentFiberActive` gates suspension: only a scheduled fiber
# parks — root-level channel use keeps its original synchronous behavior.
const schedulerInstructionBudget = 2048
const schedulerWorkerTimerPollMs = 1

proc enqueueRunnable(f: Fiber)

proc clearWaitReason(f: Fiber) =
  f.waitChannel = NIL
  f.waitActor = NIL
  f.waitTask = NIL
  f.waitTimer = false

proc workerCandidate(f: Fiber): bool {.inline.} =
  f.workerSafe and f.actorOwner.kind != vkActorRef

template withSchedulerLock(s: SchedulerState, body: untyped): untyped =
  acquire(s.lock)
  try:
    body
  finally:
    release(s.lock)

proc enqueueRunnableUnlocked(s: SchedulerState, f: Fiber) =
  clearWaitReason(f)
  s.runQueue.add f
  when compileOption("threads") and defined(gcAtomicArc):
    if f.workerCandidate:
      signal(s.workerCond)

proc inCancelCleanup(f: Fiber): bool =
  if f.frameKind == fkEnsureCancelBody:
    return true
  for frame in f.frames:
    if frame.kind == fkEnsureCancelBody:
      return true

proc wakeAllActorSenders(actor: Value) =
  let s = currentScheduler()
  withSchedulerLock(s):
    var i = 0
    while i < s.waiters.len:
      let f = s.waiters[i]
      if f.waitActor.kind == vkActorRef and same(f.waitActor, actor):
        s.waiters.delete(i)
        s.enqueueRunnableUnlocked(f)
      else:
        inc i

proc closeActorAndCancelMailbox(actor: Value) =
  actor.closeActor()
  for item in actor.drainActorMessages():
    discard cancelReplyTask(item.reply)
  wakeAllActorSenders(actor)
  actor.setActorProcessing(false)

proc cancelOwnedActor(actor: Value) =
  ## Scope/supervisor shutdown owns actor lifetime. Closing the mailbox is not
  ## enough: queued asks and already-scheduled handler fibers would otherwise keep
  ## pending tasks alive, and parked handlers could resume after owner exit.
  closeActorAndCancelMailbox(actor)

  let s = currentScheduler()
  var repliesToCancel: seq[Value]
  withSchedulerLock(s):
    var i = 0
    while i < s.runQueue.len:
      let f = s.runQueue[i]
      if f.actorOwner.kind == vkActorRef and same(f.actorOwner, actor):
        repliesToCancel.add f.actorAskReply
        s.runQueue.delete(i)
      else:
        inc i

    i = 0
    while i < s.waiters.len:
      let f = s.waiters[i]
      if f.actorOwner.kind == vkActorRef and same(f.actorOwner, actor):
        repliesToCancel.add f.actorAskReply
        s.waiters.delete(i)
      else:
        inc i
  for reply in repliesToCancel:
    discard cancelReplyTask(reply)

proc spawnFiber(chunk: Chunk, scope: Scope, workerSafe = false): Value

proc translateErrorBoundary(checks: bool, errorTypes: seq[Value], fnName: string,
                            e: ref GeneError): ref GeneError =
  ## Apply one ^errors boundary as an exception unwinds the frame stack: declared
  ## (allowed) errors pass through unchanged; an undeclared error escaping an
  ## ^errors function is replaced with the generic "raised an undeclared error".
  ## Mirrors applyCall's per-call try/except for the frame-push (trampoline) path.
  if not checks:
    return e
  if e.hasErrVal and errorAllowed(errorTypes, e.errVal):
    return e
  newException(GeneError,
    "function '" & fnName & "' raised an undeclared error")

proc runLoop(chunkArg: Chunk, scopeArg: Scope, stackArg: var seq[Value],
             ipArg: var int, stopOnYield: bool,
             validateArg = true, fiber: Fiber = nil,
             injectCancel = false, instructionBudget = 0): RunStop

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

proc runLoop(chunkArg: Chunk, scopeArg: Scope, stackArg: var seq[Value],
             ipArg: var int, stopOnYield: bool,
             validateArg = true, fiber: Fiber = nil,
             injectCancel = false, instructionBudget = 0): RunStop =
  # Stage 1 of structured concurrency: the "current frame" lives in registers
  # below, and simple Gene function calls push the caller onto `frames` and
  # switch registers to the callee instead of recursing through Nim. A call chain
  # therefore lives on the heap (suspendable later) and pure function recursion
  # no longer grows the Nim stack. The initial frame's stack/ip alias the var
  # params so generators can still persist and resume them.
  var frames: seq[Frame]
  var chunk = chunkArg
  var scope = scopeArg
  var recycleScope = false
  var stack = move stackArg
  var ip = ipArg
  var validateImplRequirements = validateArg
  var evalBudget = scope.evalBudget
  var returnType = NIL          # current frame's return-type to adapt, or NIL
  var returnLabel = ""
  # Error-boundary registers for the current frame. The outermost frame is never
  # an ^errors boundary here: direct entry points (applyCall / runPooled) wrap
  # their own try/except, so runLoop only translates frames it pushed itself.
  var curChecksErrors = false
  var curErrorTypes: seq[Value] = @[]
  var curFnName = ""
  var curFrameKind = fkNormal
  var curEnsureValue = NIL
  var curEnsureBody: Chunk = nil
  var curEnsureScope: Scope = nil
  var curPendingError: ref GeneError = nil
  var curPendingPanic: ref GenePanic = nil
  var curPendingCancel: ref GeneCancel = nil
  var curForItems: seq[Value] = @[]
  var curForIndex = 0
  var curForPattern = NIL
  var curForBody: Chunk = nil
  var curOwnedScope: Scope = nil
  var curNamespaceName = ""
  var handlers: seq[TryHandler] # active `try` regions, innermost last
  var cancelAtSafepoint = injectCancel
  var remainingBudget = instructionBudget

  if fiber != nil and fiber.started:
    # Resuming a parked fiber: restore the full continuation captured at suspend.
    chunk = fiber.chunk
    scope = fiber.scope
    recycleScope = fiber.recycleScope
    stack = move fiber.stack
    ip = fiber.ip
    frames = move fiber.frames
    handlers = move fiber.handlers
    validateImplRequirements = fiber.validateImpls
    returnType = fiber.returnType
    returnLabel = fiber.returnLabel
    curChecksErrors = fiber.checksErrors
    curErrorTypes = fiber.errorTypes
    curFnName = fiber.fnName
    curFrameKind = fiber.frameKind
    curEnsureValue = fiber.ensureValue
    curEnsureBody = fiber.ensureBody
    curEnsureScope = fiber.ensureScope
    curPendingError = fiber.pendingError
    curPendingPanic = fiber.pendingPanic
    curPendingCancel = fiber.pendingCancel
    curForItems = move fiber.forItems
    curForIndex = fiber.forIndex
    curForPattern = fiber.forPattern
    curForBody = fiber.forBody
    curOwnedScope = fiber.ownedScope
    curNamespaceName = fiber.namespaceName
    evalBudget = scope.evalBudget

  template loadFrameRegs(f: Frame) =
    ## Restore the per-frame registers (everything except the operand stack, which
    ## each caller handles explicitly) from a popped Frame.
    if f.restoreSlot >= 0:
      f.scope.slots[f.restoreSlot] = f.restoreValue
    chunk = f.chunk
    scope = f.scope
    recycleScope = f.recycleScope
    ip = f.ip
    validateImplRequirements = f.validateImpls
    returnType = f.returnType
    returnLabel = f.returnLabel
    curChecksErrors = f.checksErrors
    curErrorTypes = f.errorTypes
    curFnName = f.fnName
    curFrameKind = f.kind
    if f.extra == nil:
      curEnsureValue = NIL
      curEnsureBody = nil
      curEnsureScope = nil
      curPendingError = nil
      curPendingPanic = nil
      curPendingCancel = nil
      curForItems = @[]
      curForIndex = 0
      curForPattern = NIL
      curForBody = nil
      curOwnedScope = nil
      curNamespaceName = ""
    else:
      curEnsureValue = f.extra.ensureValue
      curEnsureBody = f.extra.ensureBody
      curEnsureScope = f.extra.ensureScope
      curPendingError = f.extra.pendingError
      curPendingPanic = f.extra.pendingPanic
      curPendingCancel = f.extra.pendingCancel
      curForItems = move f.extra.forItems
      curForIndex = f.extra.forIndex
      curForPattern = f.extra.forPattern
      curForBody = f.extra.forBody
      curOwnedScope = f.extra.ownedScope
      curNamespaceName = f.extra.namespaceName
    evalBudget = scope.evalBudget

  template pushFrame() =
    let frameExtra =
      if curFrameKind == fkNormal and curEnsureBody == nil and
          curForItems.len == 0 and curOwnedScope == nil and
          curPendingError == nil and curPendingPanic == nil and
          curPendingCancel == nil:
        nil
      else:
        FrameExtra(ensureValue: curEnsureValue,
                   ensureBody: curEnsureBody,
                   ensureScope: curEnsureScope,
                   pendingError: curPendingError,
                   pendingPanic: curPendingPanic,
                   pendingCancel: curPendingCancel,
                   forItems: move curForItems, forIndex: curForIndex,
                   forPattern: curForPattern, forBody: curForBody,
                   ownedScope: curOwnedScope,
                   namespaceName: curNamespaceName)
    frames.add Frame(chunk: chunk, scope: scope, recycleScope: recycleScope,
                     stack: move stack, ip: ip,
                     validateImpls: validateImplRequirements,
                     returnType: returnType, returnLabel: returnLabel,
                     checksErrors: curChecksErrors,
                     errorTypes: curErrorTypes, fnName: curFnName,
                     kind: curFrameKind, extra: frameExtra,
                     restoreSlot: -1, restoreValue: NIL)

  template pushFrameFastNormal() =
    frames.add Frame(chunk: chunk, scope: scope, recycleScope: recycleScope,
                     stack: move stack, ip: ip,
                     validateImpls: validateImplRequirements,
                     returnType: returnType, returnLabel: returnLabel,
                     checksErrors: curChecksErrors,
                     errorTypes: curErrorTypes, fnName: curFnName,
                     kind: fkNormal, extra: nil,
                     restoreSlot: -1, restoreValue: NIL)

  template pushCallFrame() =
    if curFrameKind == fkNormal and curEnsureBody == nil and
        curForItems.len == 0 and curOwnedScope == nil and
        curPendingError == nil and curPendingPanic == nil and
        curPendingCancel == nil:
      pushFrameFastNormal()
    else:
      pushFrame()

  template enterFrame(nextChunk: Chunk, nextScope: Scope, nextValidate: bool,
                      nextKind: FrameKind = fkNormal) =
    chunk = nextChunk
    scope = nextScope
    recycleScope = false
    scope.prepareChunkScope(chunk)
    stack = acquireRunStack()
    ip = 0
    validateImplRequirements = nextValidate
    returnType = NIL
    returnLabel = ""
    curChecksErrors = false
    curErrorTypes = @[]
    curFnName = ""
    curFrameKind = nextKind
    curEnsureValue = NIL
    curEnsureBody = nil
    curEnsureScope = nil
    curPendingError = nil
    curPendingPanic = nil
    curPendingCancel = nil
    curForItems = @[]
    curForIndex = 0
    curForPattern = NIL
    curForBody = nil
    curOwnedScope = nil
    curNamespaceName = ""
    evalBudget = scope.evalBudget

  template captureContinuation(resumeIp: int) =
    ## Save the whole running continuation into `fiber` so the scheduler can resume
    ## it later. `resumeIp` is the instruction to re-execute on resume (the parking
    ## op, whose operands are still on the stack). The caller sets the wait reason.
    fiber.chunk = chunk
    fiber.scope = scope
    fiber.recycleScope = recycleScope
    fiber.ip = resumeIp
    fiber.validateImpls = validateImplRequirements
    fiber.returnType = returnType
    fiber.returnLabel = returnLabel
    fiber.checksErrors = curChecksErrors
    fiber.errorTypes = curErrorTypes
    fiber.fnName = curFnName
    fiber.frameKind = curFrameKind
    fiber.ensureValue = curEnsureValue
    fiber.ensureBody = curEnsureBody
    fiber.ensureScope = curEnsureScope
    fiber.pendingError = curPendingError
    fiber.pendingPanic = curPendingPanic
    fiber.pendingCancel = curPendingCancel
    fiber.forItems = move curForItems
    fiber.forIndex = curForIndex
    fiber.forPattern = curForPattern
    fiber.forBody = curForBody
    fiber.ownedScope = curOwnedScope
    fiber.namespaceName = curNamespaceName
    fiber.started = true
    fiber.frames = move frames
    fiber.handlers = move handlers
    fiber.stack = move stack

  template releaseCurrentCallScope() =
    if recycleScope:
      releaseCallScope(scope)
      recycleScope = false

  proc releaseFrameCallScope(f: Frame) =
    if f.recycleScope:
      releaseCallScope(f.scope)

  template finishFrameReturn(retValue: Value) =
    if validateImplRequirements and scope.requiredImplTypes.len != 0:
      scope.validateRequiredImpls()
    releaseCurrentCallScope()
    if curFrameKind == fkNormal:
      if frames.len == 0:
        stackArg = move stack
        ipArg = ip
        return RunStop(kind: rskReturn, value: retValue)
      else:
        releaseRunStack(stack)
        var caller = frames.pop()
        if caller.restoreSlot >= 0 and caller.kind == fkNormal and caller.extra == nil:
          caller.scope.slots[caller.restoreSlot] = caller.restoreValue
          stack = move caller.stack
          ip = caller.ip
          if caller.recycleScope or caller.validateImpls or
              caller.returnType.kind != vkNil or caller.returnLabel.len != 0:
            recycleScope = caller.recycleScope
            validateImplRequirements = caller.validateImpls
            returnType = caller.returnType
            returnLabel = caller.returnLabel
        else:
          stack = move caller.stack
          loadFrameRegs(caller)
        stack.add retValue
    elif curFrameKind == fkEnsureErrorBody:
      raise curPendingError
    elif curFrameKind == fkEnsurePanicBody:
      raise curPendingPanic
    elif curFrameKind == fkEnsureCancelBody:
      raise curPendingCancel
    elif curFrameKind == fkEnsureValueBody:
      releaseRunStack(stack)
      let preserved = curEnsureValue
      var owner = frames.pop()
      stack = move owner.stack
      loadFrameRegs(owner)
      stack.add preserved
    elif curFrameKind == fkForBody:
      releaseRunStack(stack)
      if curForIndex < curForItems.len:
        let item = curForItems[curForIndex]
        inc curForIndex
        let ownerScope = frames[^1].scope
        let loopScope = newScope(ownerScope)
        loopScope.prepareChunkScope(curForBody)
        var binds = initTable[string, Value]()
        if not tryMatch(curForPattern, item, loopScope, binds):
          raiseMatchError(loopScope, "for pattern did not match an item")
        loopScope.bindMatchedValues(binds, replaceExisting = false)
        chunk = curForBody
        scope = loopScope
        stack = acquireRunStack()
        ip = 0
        validateImplRequirements = true
        returnType = NIL
        returnLabel = ""
        curChecksErrors = false
        curErrorTypes = @[]
        curFnName = ""
        curFrameKind = fkForBody
        evalBudget = scope.evalBudget
      else:
        var owner = frames.pop()
        stack = move owner.stack
        loadFrameRegs(owner)
        stack.add NIL
    elif curFrameKind == fkTaskScopeBody:
      let owned = curOwnedScope
      curFrameKind = fkNormal
      try:
        owned.waitOwnedTasks()
      finally:
        owned.closeOwnedActors()
      releaseRunStack(stack)
      var owner = frames.pop()
      stack = move owner.stack
      loadFrameRegs(owner)
      stack.add retValue
    elif curFrameKind == fkSupervisorBody:
      let owned = curOwnedScope
      curFrameKind = fkNormal
      owned.closeOwnedActors()
      releaseRunStack(stack)
      var owner = frames.pop()
      stack = move owner.stack
      loadFrameRegs(owner)
      stack.add retValue
    elif curFrameKind == fkNamespaceBody:
      let nsScope = curOwnedScope
      let nsName = curNamespaceName
      releaseRunStack(stack)
      var owner = frames.pop()
      stack = move owner.stack
      loadFrameRegs(owner)
      let ns = newNamespace(nsName, nsScope)
      scope.define(nsName, ns)
      stack.add ns
    elif curFrameKind == fkTryBody:
      # The try body succeeded: drop its handler, run ensure, then hand its value
      # back to the enclosing frame (the owner pushed by opTry).
      releaseRunStack(stack)
      let h = handlers.pop()
      if h.tp.ensureBody != nil:
        enterFrame(h.tp.ensureBody, h.scope, false, fkEnsureValueBody)
        curEnsureValue = retValue
      else:
        var owner = frames.pop()
        stack = move owner.stack
        loadFrameRegs(owner)
        stack.add retValue
    elif curFrameKind == fkCatchBody:
      releaseRunStack(stack)
      if curEnsureBody != nil:
        let body = curEnsureBody
        let cleanupScope = curEnsureScope
        enterFrame(body, cleanupScope, false, fkEnsureValueBody)
        curEnsureValue = retValue
      else:
        var owner = frames.pop()
        stack = move owner.stack
        loadFrameRegs(owner)
        stack.add retValue
    elif frames.len == 0:
      stackArg = move stack
      ipArg = ip
      return RunStop(kind: rskReturn, value: retValue)
    else:
      releaseRunStack(stack)
      var caller = frames.pop()
      stack = move caller.stack
      loadFrameRegs(caller)
      stack.add retValue

  template finishFastNormalReturn(retValue: Value) =
    releaseCurrentCallScope()
    if frames.len == 0:
      stackArg = move stack
      ipArg = ip
      return RunStop(kind: rskReturn, value: retValue)
    else:
      releaseRunStack(stack)
      var caller = frames.pop()
      if caller.restoreSlot >= 0 and caller.kind == fkNormal and caller.extra == nil:
        caller.scope.slots[caller.restoreSlot] = caller.restoreValue
        stack = move caller.stack
        ip = caller.ip
        if caller.recycleScope or caller.validateImpls or
            caller.returnType.kind != vkNil or caller.returnLabel.len != 0:
          recycleScope = caller.recycleScope
          validateImplRequirements = caller.validateImpls
          returnType = caller.returnType
          returnLabel = caller.returnLabel
      else:
        stack = move caller.stack
        loadFrameRegs(caller)
      stack.add retValue

  template frameReturn(rawValue: Value) =
    ## Return `rawValue` from the current frame: adapt it to the frame's declared
    ## return type, then pop to the caller and push the result — or, if this is
    ## the outermost frame, return to runLoop's caller. A `try` body completing
    ## normally instead runs its ensure block and resumes the enclosing frame.
    var retValue = escapeWeakFunctions(rawValue)
    if returnType.kind != vkNil:
      if not (returnType.isBareIntType and retValue.kind == vkInt):
        let label =
          if returnLabel.len == 0 and curFnName.len > 0:
            "return from '" & curFnName & "'"
          else:
            returnLabel
        retValue = adaptBoundary(label, returnType, retValue, scope)
    finishFrameReturn(retValue)

  template frameReturnBareInt(rawValue: Value) =
    ## Fast return for frames whose compiler-proven result is an Int. This keeps
    ## normal scope/impl cleanup but skips escaping and boundary checks that are
    ## impossible for the proven scalar result.
    let retValue = rawValue
    if retValue.kind == vkInt and returnType.kind == vkNil and
        curFrameKind == fkNormal and not validateImplRequirements:
      finishFastNormalReturn(retValue)
    elif retValue.kind == vkInt and returnType.kind == vkNil:
      finishFrameReturn(retValue)
    else:
      frameReturn(retValue)

  template enterRecur1Frame(arg: Value, argKnownBareInt: bool) =
    let proto = chunk.owner
    if not argKnownBareInt and proto.hasParamTypes and proto.paramTypes.len > 0 and
        proto.paramTypes[0].isBareIntType and arg.kind != vkInt:
      raiseTypeError("parameter '" & proto.params[0] & "'", "Int", arg, scope)
    let callScope = acquireSimpleCallScope(scope.parent, proto.localNames,
      keepSlotNames = false, resetSlots = false)
    let slot = proto.positionalSlots[0]
    callScope.slots[slot] = arg
    callScope.slotDefinedBits = 1'u64 shl slot
    if curFrameKind == fkNormal:
      pushFrameFastNormal()
    else:
      pushCallFrame()
    chunk = proto.chunk
    scope = callScope
    recycleScope = true
    stack = acquireRunStack()
    ip = 0
    validateImplRequirements = false
    returnType =
      if proto.returnKnownBareInt: NIL
      elif proto.hasReturnType: proto.returnType
      else: NIL
    returnLabel = ""
    curChecksErrors = false
    curErrorTypes = @[]
    curFnName = proto.name
    curFrameKind = fkNormal
    evalBudget = callScope.evalBudget
    continue

  template enterRecur1SameScopeFrame(arg: Value, argKnownBareInt: bool) =
    let proto = chunk.owner
    if not argKnownBareInt and proto.hasParamTypes and proto.paramTypes.len > 0 and
        proto.paramTypes[0].isBareIntType and arg.kind != vkInt:
      raiseTypeError("parameter '" & proto.params[0] & "'", "Int", arg, scope)
    if curFrameKind != fkNormal or curEnsureBody != nil or curForItems.len != 0 or
        curOwnedScope != nil or curPendingError != nil or curPendingPanic != nil or
        curPendingCancel != nil:
      enterRecur1Frame(arg, argKnownBareInt)
    let slot = proto.positionalSlots[0]
    let previous = scope.slots[slot]
    frames.add Frame(chunk: chunk, scope: scope, recycleScope: recycleScope,
                     stack: move stack, ip: ip,
                     validateImpls: validateImplRequirements,
                     returnType: returnType, returnLabel: returnLabel,
                     checksErrors: curChecksErrors,
                     errorTypes: curErrorTypes, fnName: curFnName,
                     kind: fkNormal, extra: nil,
                     restoreSlot: slot, restoreValue: previous)
    scope.slots[slot] = arg
    stack = acquireRunStack()
    ip = 0
    validateImplRequirements = false
    returnType =
      if proto.returnKnownBareInt: NIL
      elif proto.hasReturnType: proto.returnType
      else: NIL
    returnLabel = ""
    curChecksErrors = false
    curErrorTypes = @[]
    curFnName = proto.name
    curFrameKind = fkNormal
    recycleScope = false
    evalBudget = scope.evalBudget
    continue

  while true:
    try:
      if cancelAtSafepoint:
        cancelAtSafepoint = false
        raise newException(GeneCancel, "task was cancelled")
      while true:
        {.computedGoto.}
        if ip >= chunk.instructions.len:
          frameReturn(NIL)
          continue
        if instructionBudget > 0:
          if remainingBudget <= 0:
            if fiber == nil:
              raise newException(GeneError,
                "internal: scheduler pause outside a fiber")
            captureContinuation(ip)
            return RunStop(kind: rskPause, value: NIL)
          dec remainingBudget
        if evalBudget != nil:
          consumeEvalStep(evalBudget)
        let inst = addr chunk.instructions[ip]
        let op = inst[].op
        inc ip
        case op
        of opNoop:
          discard
        of opPushConst:
          stack.add chunk.constants[inst[].intArg]
        of opLoadName:
          stack.add scope.lookup(inst[].name)
        of opLoadNativeFast:
          stack.add scope.loadNativeFast(NativeFastKind(inst[].intArg), inst[].name)
        of opLoadLocal:
          let slot = inst[].intArg
          if slot >= 0 and slot < scope.slots.len and scope.slotDefined(slot):
            stack.add scope.slots[slot]
          else:
            stack.add scope.loadSlot(slot, inst[].name)
        of opLoadLocalFast:
          stack.add scope.slots[inst[].intArg]
        of opLoadOuterLocal:
          let slot = inst[].intArg
          let outer =
            if inst[].depth == 1:
              scope.parent
            else:
              scope.scopeAtDepth(inst[].depth, inst[].name)
          if outer != nil and slot >= 0 and slot < outer.slots.len and
              outer.slotDefined(slot):
            stack.add outer.slots[slot]
          else:
            stack.add scope.loadSlotAt(inst[].depth, slot, inst[].name)
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
        of opApplySelector:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in selector apply")
          let target = stack.pop()
          let selector = stack.pop()
          stack.add applySelector(selector, target)
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
                           imports, module, capabilities, policy,
                           bindingScope = scope)
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
          pushFrame()
          enterFrame(evalChunk, evalScope, true)
          continue
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
          pushFrame()
          enterFrame(chunk.subchunks[inst[].intArg], nsScope,
                     validateImplRequirements, fkNamespaceBody)
          curOwnedScope = nsScope
          curNamespaceName = inst[].name
          continue
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
        of opCallLocal0:
          let slot = inst[].intArg
          var callee =
            if slot >= 0 and slot < scope.slots.len and scope.slotDefined(slot):
              scope.slots[slot]
            else:
              scope.loadSlot(slot, inst[].name)
          if callee.kind == vkFunction:
            let code = callee.fnCode
            if code != nil and code of FunctionProto:
              let proto = FunctionProto(code)
              if proto.nativeOp != ncoNone:
                let native = applyNativeCompiled(callee, proto, [], NamedArgs())
                if native.handled:
                  stack.add native.value
                  continue
              if proto.simpleCall:
                if proto.params.len != 0:
                  raise newException(GeneError,
                    "function '" & callee.fnName & "' expects " &
                    $proto.requiredPositional & ".." & $proto.params.len &
                    " argument(s), got 0")
                let callScope =
                  if proto.needsCallScope:
                    if proto.poolCallScope:
                      acquireSimpleCallScope(callee.fnScope, proto.localNames,
                        proto.callScopeNeedsSlotNames,
                        proto.callScopeNeedsSlotReset)
                    else:
                      let fresh = newScope(callee.fnScope)
                      fresh.prepareSlots(proto.localNames)
                      fresh
                  else:
                    callee.fnScope
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = proto.needsCallScope
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif not proto.isGenerator:
                let bound = bindCallScope(callee, proto, [], NamedArgs())
                let frameReturnType = proto.checkedFrameReturnType(bound.returnType)
                var lbl = ""
                if frameReturnType.kind != vkNil:
                  lbl = "return from '" & callee.fnName & "'"
                pushCallFrame()
                chunk = proto.chunk
                scope = bound.scope
                recycleScope = proto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = true
                returnType = frameReturnType
                returnLabel = lbl
                curChecksErrors = proto.checksErrors
                curErrorTypes = if proto.checksErrors: callee.fnErrorTypes else: @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = bound.scope.evalBudget
                continue
          let site =
            if callee.kind == vkFunction or
                (callee.kind == vkNativeFn and callee.nativeCallImpl == nil):
              NIL
            else:
              chunk.callSites.getOrDefault(ip - 1, NIL)
          var value: Value
          try:
            value = applyCall(callee, [], NamedArgs(), scope, site)
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            stack.add NIL
            captureContinuation(ip)
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          stack.add value
        of opCallName0, opCallName1, opCallLocal1, opCallParentLocal1,
            opCallOuterLocal1:
          let argCount =
            if inst[].op == opCallName0: 0 else: 1
          if stack.len < argCount:
            raise newException(GeneError, "VM stack underflow in direct call")
          let argsStart = stack.len - argCount
          var callee =
            if inst[].op == opCallName0 or inst[].op == opCallName1:
              scope.lookup(inst[].name)
            elif inst[].op == opCallLocal1:
              let slot = inst[].intArg
              if slot >= 0 and slot < scope.slots.len and scope.slotDefined(slot):
                scope.slots[slot]
              else:
                scope.loadSlot(slot, inst[].name)
            elif inst[].op == opCallParentLocal1:
              let slot = inst[].intArg
              let parent = scope.parent
              if parent != nil and slot >= 0 and slot < parent.slots.len and
                  parent.slotDefined(slot):
                parent.slots[slot]
              else:
                scope.loadSlotAt(1, slot, inst[].name)
            else:
              let slot = inst[].intArg
              let outer =
                if inst[].depth == 1:
                  scope.parent
                else:
                  scope.scopeAtDepth(inst[].depth, inst[].name)
              if outer != nil and slot >= 0 and slot < outer.slots.len and
                  outer.slotDefined(slot):
                outer.slots[slot]
              else:
                scope.loadSlotAt(inst[].depth, slot, inst[].name)
          if callee.kind == vkProtocolMessage and argCount >= 1:
            callee = resolveProtocolMessage(scope, callee, stack[argsStart])
          if callee.kind == vkFunction:
            let code = callee.fnCode
            if code != nil and code of FunctionProto:
              let proto = FunctionProto(code)
              if proto.nativeOp != ncoNone:
                let native =
                  if argCount == 0:
                    applyNativeCompiled(callee, proto, [], NamedArgs())
                  else:
                    applyNativeCompiled(callee, proto,
                      stack.toOpenArray(argsStart, stack.high), NamedArgs())
                if native.handled:
                  stack.setLen(argsStart)
                  stack.add native.value
                  continue
              if proto.simpleCall:
                let positionalLen = proto.params.len
                if positionalLen != argCount:
                  raise newException(GeneError,
                    "function '" & callee.fnName & "' expects " &
                    $proto.requiredPositional & ".." & $positionalLen &
                    " argument(s), got " & $argCount)
                let callScope =
                  if proto.needsCallScope:
                    let created =
                      if proto.poolCallScope:
                        acquireSimpleCallScope(callee.fnScope, proto.localNames,
                          proto.callScopeNeedsSlotNames,
                          proto.callScopeNeedsSlotReset)
                      else:
                        let fresh = newScope(callee.fnScope)
                        fresh.prepareSlots(proto.localNames)
                        fresh
                    if argCount > 0:
                      created.bindSimpleCallSlots(
                        proto, stack.toOpenArray(argsStart, stack.high))
                    created
                  else:
                    callee.fnScope
                stack.setLen(argsStart)
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = proto.needsCallScope
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif not proto.isGenerator:
                var boundScope: Scope
                var boundReturnType: Value
                var usedUnaryIntFast = false
                if argCount == 1 and proto.canFastBindUnaryInt and
                    (inst[].flag or stack[argsStart].kind == vkInt):
                  boundScope = bindUnaryIntCallScope(callee.fnScope, proto,
                                                     stack[argsStart])
                  boundReturnType = proto.checkedFrameReturnType(proto.returnType)
                  usedUnaryIntFast = true
                else:
                  let bound =
                    if argCount == 0:
                      bindCallScope(callee, proto, [], NamedArgs())
                    else:
                      bindCallScope(callee, proto,
                        stack.toOpenArray(argsStart, stack.high), NamedArgs())
                  boundScope = bound.scope
                  boundReturnType = bound.returnType
                stack.setLen(argsStart)
                boundReturnType = proto.checkedFrameReturnType(boundReturnType)
                var lbl = ""
                if boundReturnType.kind != vkNil and not usedUnaryIntFast:
                  lbl = "return from '" & callee.fnName & "'"
                pushCallFrame()
                chunk = proto.chunk
                scope = boundScope
                recycleScope = proto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = true
                returnType = boundReturnType
                returnLabel = lbl
                curChecksErrors = proto.checksErrors
                curErrorTypes = if proto.checksErrors: callee.fnErrorTypes else: @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = boundScope.evalBudget
                continue
          let site =
            if callee.kind == vkFunction or
                (callee.kind == vkNativeFn and callee.nativeCallImpl == nil):
              NIL
            else:
              chunk.callSites.getOrDefault(ip - 1, NIL)
          var value: Value
          try:
            value =
              if argCount == 0:
                applyCall(callee, [], NamedArgs(), scope, site)
              else:
                applyCall(callee, stack.toOpenArray(argsStart, stack.high),
                          NamedArgs(), scope, site)
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            stack.setLen(argsStart)
            stack.add NIL
            captureContinuation(ip)
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          stack.setLen(argsStart)
          stack.add value
        of opRecur1:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in recur call")
          let argsStart = stack.len - 1
          var arg = stack[argsStart]
          stack.setLen(argsStart)
          enterRecur1Frame(arg, inst[].flag)
        of opRecur1LocalIntSubConst, opRecur1LocalIntSubConstSameScope:
          let slot = inst[].intArg
          if slot < 0 or slot >= scope.slots.len:
            raise newException(GeneError,
              "VM local slot out of range for recur: " & inst[].name)
          let a = scope.slots[slot]
          let b = chunk.constants[inst[].depth]
          var arg: Value
          var argKnownBareInt = true
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            if not smallIntSubKnown(a, b, arg):
              arg = intSub(a, b)
          elif a.kind == vkInt and b.kind == vkInt:
            arg = intSub(a, b)
          else:
            let callee = scope.loadNativeFast(nfkSub, "-")
            var args = [a, b]
            arg = applyCall(callee, args, NamedArgs(), scope)
            argKnownBareInt = false
          ip += 2
          if inst[].op == opRecur1LocalIntSubConstSameScope:
            enterRecur1SameScopeFrame(arg, argKnownBareInt)
          else:
            enterRecur1Frame(arg, argKnownBareInt)
        of opReturnLocalIfIntLtConst:
          let slot = inst[].intArg
          if slot < 0 or slot >= scope.slots.len:
            raise newException(GeneError,
              "VM local slot out of range for int return guard: " & inst[].name)
          let a = scope.slots[slot]
          let b = chunk.constants[inst[].depth]
          var matched = false
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            matched = a.smallIntVal < b.smallIntVal
          elif a.kind == vkInt and b.kind == vkInt:
            matched = intCompare(a, b) < 0
          else:
            let callee = scope.loadNativeFast(nfkLt, "<")
            var args = [a, b]
            matched = applyCall(callee, args, NamedArgs(), scope).isTruthy
          if matched:
            frameReturnBareInt(a)
            continue
          ip += 4
        of opCall0, opCall1, opCall2, opCall:
          let argCount =
            case inst[].op
            of opCall0: 0
            of opCall1: 1
            of opCall2: 2
            else: inst[].intArg
          let namedCount =
            if inst[].op == opCall:
              inst[].names.len
            else:
              0
          let argsStart = stack.len - argCount
          if argsStart < 0 or argsStart < namedCount + 1:
            raise newException(GeneError, "VM stack underflow in call")
          let calleeIndex = argsStart - namedCount - 1
          var callee = stack[calleeIndex]
          # Protocol-message dispatch (e.g. `(run obj)`) resolves to the receiver's
          # impl up front, so the call rides the same frame-push paths below instead
          # of double-recursing through applyCall (message dispatch + impl call).
          if callee.kind == vkProtocolMessage and argCount >= 1:
            callee = resolveProtocolMessage(scope, callee, stack[argsStart])
          # Frame-push paths: route Gene function calls onto the explicit frame stack
          # instead of recursing through Nim. ^errors functions push a frame too and
          # carry their error boundary (translated by the loop's handler on throw);
          # only generators (which return a stream) still go through applyCall below.
          if callee.kind == vkFunction:
            let code = callee.fnCode
            if code != nil and code of FunctionProto:
              let proto = FunctionProto(code)
              if proto.nativeOp != ncoNone:
                var nativeNamed: NamedArgs
                if namedCount > 0:
                  nativeNamed = namedArgsFromStack(inst[].names, stack,
                                                   calleeIndex + 1)
                let native =
                  if argCount == 0:
                    applyNativeCompiled(callee, proto, [], nativeNamed)
                  else:
                    applyNativeCompiled(callee, proto,
                                        stack.toOpenArray(argsStart, stack.high),
                                        nativeNamed)
                if native.handled:
                  stack.setLen(calleeIndex)
                  stack.add native.value
                  continue
              if namedCount == 0 and proto.simpleCall:
                # Hottest path: arity + positional slots only.
                let positionalLen = proto.params.len
                if argCount != positionalLen:
                  raise newException(GeneError,
                    "function '" & callee.fnName & "' expects " &
                    $proto.requiredPositional & ".." & $positionalLen &
                    " argument(s), got " & $argCount)
                let callScope =
                  if proto.needsCallScope:
                    let created =
                      if proto.poolCallScope:
                        acquireSimpleCallScope(callee.fnScope, proto.localNames,
                          proto.callScopeNeedsSlotNames,
                          proto.callScopeNeedsSlotReset)
                      else:
                        let fresh = newScope(callee.fnScope)
                        fresh.prepareSlots(proto.localNames)
                        fresh
                    if argCount > 0:
                      created.bindSimpleCallSlots(
                        proto, stack.toOpenArray(argsStart, stack.high))
                    created
                else:
                  callee.fnScope
                stack.setLen(calleeIndex)        # consume callee + args
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = proto.needsCallScope
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false        # simpleCall never declares ^errors
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif not proto.isGenerator:
                # General call (named / defaults / rest / typed / generic / ^errors):
                # bind via the shared helper, then push a frame carrying the return
                # type to adapt and the callee's error boundary to translate on throw.
                var named: NamedArgs
                if namedCount > 0:
                  named = namedArgsFromStack(inst[].names, stack,
                                             calleeIndex + 1)
                let bound =
                  if argCount == 0:
                    bindCallScope(callee, proto, [], named)
                  else:
                    bindCallScope(callee, proto,
                                  stack.toOpenArray(argsStart, stack.high), named)
                let frameReturnType = proto.checkedFrameReturnType(bound.returnType)
                stack.setLen(calleeIndex)
                var lbl = ""
                if frameReturnType.kind != vkNil:
                  lbl = "return from '" & callee.fnName & "'"
                pushCallFrame()
                chunk = proto.chunk
                scope = bound.scope
                recycleScope = proto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = true
                returnType = frameReturnType
                returnLabel = lbl
                curChecksErrors = proto.checksErrors
                curErrorTypes = if proto.checksErrors: callee.fnErrorTypes else: @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = bound.scope.evalBudget
                continue
          if namedCount == 0 and argCount == 2 and callee.kind == vkNativeFn:
            let fastNative = tryFastNative2(callee, stack[argsStart], stack[argsStart + 1])
            if fastNative.handled:
              stack.setLen(calleeIndex)
              stack.add fastNative.value
              continue
          var named: NamedArgs
          if namedCount > 0:
            named = namedArgsFromStack(inst[].names, stack, calleeIndex + 1)
          # Call-site node for the Call envelope (design §3). Looked up only for
          # envelope-building callees; the hot Fn and plain-native paths skip it.
          let site =
            if callee.kind == vkFunction or
                (callee.kind == vkNativeFn and callee.nativeCallImpl == nil):
              NIL
            else:
              chunk.callSites.getOrDefault(ip - 1, NIL)
          var value: Value
          try:
            value =
              if argCount == 0:
                applyCall(callee, [], named, scope, site)
              else:
                applyCall(callee, stack.toOpenArray(argsStart, stack.high), named, scope, site)
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            stack.setLen(calleeIndex)
            stack.add NIL
            captureContinuation(ip)   # resume after sleep; nil is already pushed
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          stack.setLen(calleeIndex)
          stack.add value
        of opCallSplice:
          var named: NamedArgs
          let proto = chunk.listBuilds[inst[].intArg]
          let partCount = proto.splices.len
          let namedCount = inst[].names.len
          let partsStart = stack.len - partCount
          if partsStart < 0 or partsStart < namedCount + 1:
            raise newException(GeneError, "VM stack underflow in call")
          let calleeIndex = partsStart - namedCount - 1
          var callee = stack[calleeIndex]
          if namedCount > 0:
            named = namedArgsFromStack(inst[].names, stack, calleeIndex + 1)
          var args: seq[Value]
          for i, part in stack.toOpenArray(partsStart, stack.high):
            if proto.splices[i]:
              appendSplicedBody(args, part)
            else:
              args.add part
          # Resolve protocol-message dispatch to the receiver's impl up front (see
          # opCall) so spread message calls ride the frame-push paths below too.
          if callee.kind == vkProtocolMessage and args.len >= 1:
            callee = resolveProtocolMessage(scope, callee, args[0])
          # Frame-push paths mirror opCall: spread calls to Gene functions go onto the
          # frame stack (^errors included; only generators fall through to applyCall).
          if callee.kind == vkFunction:
            let code = callee.fnCode
            if code != nil and code of FunctionProto:
              let fnProto = FunctionProto(code)
              if fnProto.nativeOp != ncoNone:
                let native = applyNativeCompiled(callee, fnProto, args, named)
                if native.handled:
                  stack.setLen(calleeIndex)
                  stack.add native.value
                  continue
              if namedCount == 0 and fnProto.simpleCall and
                  args.len == fnProto.params.len:
                let callScope =
                  if fnProto.needsCallScope:
                    let created =
                      if fnProto.poolCallScope:
                        acquireSimpleCallScope(callee.fnScope, fnProto.localNames,
                          fnProto.callScopeNeedsSlotNames,
                          fnProto.callScopeNeedsSlotReset)
                      else:
                        let fresh = newScope(callee.fnScope)
                        fresh.prepareSlots(fnProto.localNames)
                        fresh
                    if args.len > 0:
                      created.bindSimpleCallSlots(fnProto, args)
                    created
                  else:
                    callee.fnScope
                stack.setLen(calleeIndex)
                pushFrame()
                chunk = fnProto.chunk
                scope = callScope
                recycleScope = fnProto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = fnProto.needsCallScope
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false        # simpleCall never declares ^errors
                curErrorTypes = @[]
                curFnName = ""
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif not fnProto.isGenerator:
                let bound = bindCallScope(callee, fnProto, args, named)
                let frameReturnType = fnProto.checkedFrameReturnType(bound.returnType)
                stack.setLen(calleeIndex)
                var lbl = ""
                if frameReturnType.kind != vkNil:
                  lbl = "return from '" & callee.fnName & "'"
                pushFrame()
                chunk = fnProto.chunk
                scope = bound.scope
                recycleScope = fnProto.poolCallScope
                stack = acquireRunStack()
                ip = 0
                validateImplRequirements = true
                returnType = frameReturnType
                returnLabel = lbl
                curChecksErrors = fnProto.checksErrors
                curErrorTypes = if fnProto.checksErrors: callee.fnErrorTypes else: @[]
                curFnName = if fnProto.checksErrors: callee.fnName else: ""
                curFrameKind = fkNormal
                evalBudget = bound.scope.evalBudget
                continue
          let site =
            if callee.kind == vkFunction or
                (callee.kind == vkNativeFn and callee.nativeCallImpl == nil):
              NIL
            else:
              chunk.callSites.getOrDefault(ip - 1, NIL)
          var value: Value
          try:
            value =
              if args.len == 0:
                applyCall(callee, [], named, scope, site)
              else:
                applyCall(callee, args, named, scope, site)
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            stack.setLen(calleeIndex)
            stack.add NIL
            captureContinuation(ip)
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          stack.setLen(calleeIndex)
          stack.add value
        of opIntAdd2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int add")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            var value: Value
            if smallIntAddKnown(a, b, value):
              stack[top - 2] = value
              setLenUninit(stack, top - 1)
              continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = intAdd(a, b)
            stack.setLen(top - 1)
            continue
          stack.setLen(top - 2)
          let callee = scope.loadNativeFast(nfkAdd, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntSub2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int sub")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            var value: Value
            if smallIntSubKnown(a, b, value):
              stack[top - 2] = value
              setLenUninit(stack, top - 1)
              continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = intSub(a, b)
            stack.setLen(top - 1)
            continue
          stack.setLen(top - 2)
          let callee = scope.loadNativeFast(nfkSub, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntMul2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int mul")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = intMul(a, b)
            stack.setLen(top - 1)
            continue
          stack.setLen(top - 2)
          let callee = scope.loadNativeFast(nfkMul, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntLt2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int lt")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal < b.smallIntVal)
            setLenUninit(stack, top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) < 0)
            stack.setLen(top - 1)
            continue
          stack.setLen(top - 2)
          let callee = scope.loadNativeFast(nfkLt, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntGt2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int gt")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal > b.smallIntVal)
            setLenUninit(stack, top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) > 0)
            stack.setLen(top - 1)
            continue
          stack.setLen(top - 2)
          let callee = scope.loadNativeFast(nfkGt, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntLe2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int le")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal <= b.smallIntVal)
            setLenUninit(stack, top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) <= 0)
            stack.setLen(top - 1)
            continue
          stack.setLen(top - 2)
          let callee = scope.loadNativeFast(nfkLe, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntGe2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int ge")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal >= b.smallIntVal)
            setLenUninit(stack, top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) >= 0)
            stack.setLen(top - 1)
            continue
          stack.setLen(top - 2)
          let callee = scope.loadNativeFast(nfkGe, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntAddConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int add const")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            var value: Value
            if smallIntAddKnown(a, b, value):
              stack[top - 1] = value
              continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = intAdd(a, b)
            continue
          stack.setLen(top - 1)
          let callee = scope.loadNativeFast(nfkAdd, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntSubConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int sub const")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            var value: Value
            if smallIntSubKnown(a, b, value):
              stack[top - 1] = value
              continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = intSub(a, b)
            continue
          stack.setLen(top - 1)
          let callee = scope.loadNativeFast(nfkSub, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntMulConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int mul const")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = intMul(a, b)
            continue
          stack.setLen(top - 1)
          let callee = scope.loadNativeFast(nfkMul, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntLtConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int lt const")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal < b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) < 0)
            continue
          stack.setLen(top - 1)
          let callee = scope.loadNativeFast(nfkLt, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntGtConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int gt const")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal > b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) > 0)
            continue
          stack.setLen(top - 1)
          let callee = scope.loadNativeFast(nfkGt, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntLeConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int le const")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal <= b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) <= 0)
            continue
          stack.setLen(top - 1)
          let callee = scope.loadNativeFast(nfkLe, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntGeConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int ge const")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal >= b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) >= 0)
            continue
          stack.setLen(top - 1)
          let callee = scope.loadNativeFast(nfkGe, inst[].name)
          var args = [a, b]
          stack.add applyCall(callee, args, NamedArgs(), scope)
        of opIntFast2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in int fast call")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          let kind = NativeFastKind(inst[].intArg)
          if a.isSmallInt and b.isSmallInt:
            case kind
            of nfkAdd:
              var value: Value
              if smallIntAddKnown(a, b, value):
                stack[top - 2] = value
                setLenUninit(stack, top - 1)
                continue
            of nfkSub:
              var value: Value
              if smallIntSubKnown(a, b, value):
                stack[top - 2] = value
                setLenUninit(stack, top - 1)
                continue
            of nfkLt:
              stack[top - 2] = newBool(a.smallIntVal < b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            of nfkGt:
              stack[top - 2] = newBool(a.smallIntVal > b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            of nfkLe:
              stack[top - 2] = newBool(a.smallIntVal <= b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            of nfkGe:
              stack[top - 2] = newBool(a.smallIntVal >= b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            else:
              discard
          if a.kind != vkInt or b.kind != vkInt:
            stack.setLen(top - 2)
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            stack.add applyCall(callee, args, NamedArgs(), scope)
            continue
          case kind
          of nfkAdd:
            stack[top - 2] = intAdd(a, b)
          of nfkSub:
            stack[top - 2] = intSub(a, b)
          of nfkMul:
            stack[top - 2] = intMul(a, b)
          of nfkLt:
            stack[top - 2] = newBool(intCompare(a, b) < 0)
          of nfkGt:
            stack[top - 2] = newBool(intCompare(a, b) > 0)
          of nfkLe:
            stack[top - 2] = newBool(intCompare(a, b) <= 0)
          of nfkGe:
            stack[top - 2] = newBool(intCompare(a, b) >= 0)
          else:
            raise newException(GeneError, "internal: unsupported int fast op")
          stack.setLen(top - 1)
        of opIntFastConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in int fast const call")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          let kind = NativeFastKind(inst[].intArg)
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            case kind
            of nfkAdd:
              var value: Value
              if smallIntAddKnown(a, b, value):
                stack[top - 1] = value
                continue
            of nfkSub:
              var value: Value
              if smallIntSubKnown(a, b, value):
                stack[top - 1] = value
                continue
            of nfkLt:
              stack[top - 1] = newBool(a.smallIntVal < b.smallIntVal)
              continue
            of nfkGt:
              stack[top - 1] = newBool(a.smallIntVal > b.smallIntVal)
              continue
            of nfkLe:
              stack[top - 1] = newBool(a.smallIntVal <= b.smallIntVal)
              continue
            of nfkGe:
              stack[top - 1] = newBool(a.smallIntVal >= b.smallIntVal)
              continue
            else:
              discard
          if a.kind != vkInt or b.kind != vkInt:
            stack.setLen(top - 1)
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            stack.add applyCall(callee, args, NamedArgs(), scope)
            continue
          case kind
          of nfkAdd:
            stack[top - 1] = intAdd(a, b)
          of nfkSub:
            stack[top - 1] = intSub(a, b)
          of nfkMul:
            stack[top - 1] = intMul(a, b)
          of nfkLt:
            stack[top - 1] = newBool(intCompare(a, b) < 0)
          of nfkGt:
            stack[top - 1] = newBool(intCompare(a, b) > 0)
          of nfkLe:
            stack[top - 1] = newBool(intCompare(a, b) <= 0)
          of nfkGe:
            stack[top - 1] = newBool(intCompare(a, b) >= 0)
          else:
            raise newException(GeneError, "internal: unsupported int fast const op")
        of opNativeFast2:
          if stack.len < 2:
            raise newException(GeneError, "VM stack underflow in native fast call")
          let top = stack.len
          let b = stack[top - 1]
          let a = stack[top - 2]
          let kind = NativeFastKind(inst[].intArg)
          if a.isSmallInt and b.isSmallInt:
            case kind
            of nfkAdd:
              var value: Value
              if smallIntAddKnown(a, b, value):
                stack[top - 2] = value
                setLenUninit(stack, top - 1)
                continue
            of nfkSub:
              var value: Value
              if smallIntSubKnown(a, b, value):
                stack[top - 2] = value
                setLenUninit(stack, top - 1)
                continue
            of nfkLt:
              stack[top - 2] = newBool(a.smallIntVal < b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            of nfkGt:
              stack[top - 2] = newBool(a.smallIntVal > b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            of nfkLe:
              stack[top - 2] = newBool(a.smallIntVal <= b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            of nfkGe:
              stack[top - 2] = newBool(a.smallIntVal >= b.smallIntVal)
              setLenUninit(stack, top - 1)
              continue
            else:
              discard
          stack.setLen(top - 2)
          let fastNative = tryFastNativeKind2(kind, a, b)
          if fastNative.handled:
            stack.add fastNative.value
          else:
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            stack.add applyCall(callee, args, NamedArgs(), scope)
        of opNativeFastConst:
          if stack.len < 1:
            raise newException(GeneError, "VM stack underflow in native fast const call")
          let top = stack.len
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          let kind = NativeFastKind(inst[].intArg)
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            case kind
            of nfkAdd:
              var value: Value
              if smallIntAddKnown(a, b, value):
                stack[top - 1] = value
                continue
            of nfkSub:
              var value: Value
              if smallIntSubKnown(a, b, value):
                stack[top - 1] = value
                continue
            of nfkLt:
              stack[top - 1] = newBool(a.smallIntVal < b.smallIntVal)
              continue
            of nfkGt:
              stack[top - 1] = newBool(a.smallIntVal > b.smallIntVal)
              continue
            of nfkLe:
              stack[top - 1] = newBool(a.smallIntVal <= b.smallIntVal)
              continue
            of nfkGe:
              stack[top - 1] = newBool(a.smallIntVal >= b.smallIntVal)
              continue
            else:
              discard
          stack.setLen(top - 1)
          if a.kind == vkInt and b.kind == vkInt:
            case kind
            of nfkAdd:
              stack.add intAdd(a, b)
              continue
            of nfkSub:
              stack.add intSub(a, b)
              continue
            of nfkMul:
              stack.add intMul(a, b)
              continue
            of nfkLt:
              stack.add newBool(intCompare(a, b) < 0)
              continue
            of nfkGt:
              stack.add newBool(intCompare(a, b) > 0)
              continue
            of nfkLe:
              stack.add newBool(intCompare(a, b) <= 0)
              continue
            of nfkGe:
              stack.add newBool(intCompare(a, b) >= 0)
              continue
            else:
              discard
          let fastNative = tryFastNativeKind2(kind, a, b)
          if fastNative.handled:
            stack.add fastNative.value
          else:
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            stack.add applyCall(callee, args, NamedArgs(), scope)
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
              pushFrame()
              enterFrame(cl.body, branchScope, validateImplRequirements)
              handled = true
              break
          if not handled:
            if mp.elseBody != nil:
              let branchScope = newScope(scope)
              branchScope.prepareChunkScope(mp.elseBody)
              pushFrame()
              enterFrame(mp.elseBody, branchScope, validateImplRequirements)
            else:
              raiseMatchError(scope, "no matching pattern")
          if handled or mp.elseBody != nil:
            continue
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
          let items = forItems(coll)
          if items.len == 0:
            stack.add NIL
            continue
          block enterFirstForItem:
            let item = items[0]
            let loopScope = newScope(scope)
            loopScope.prepareChunkScope(fp.body)
            var binds = initTable[string, Value]()
            if not tryMatch(fp.pattern, item, loopScope, binds):
              raiseMatchError(loopScope, "for pattern did not match an item")
            loopScope.bindMatchedValues(binds, replaceExisting = false)
            pushFrame()
            enterFrame(fp.body, loopScope, true, fkForBody)
            curForItems = items
            curForIndex = 1
            curForPattern = fp.pattern
            curForBody = fp.body
            continue
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
          # Run the try body as a Frame on the heap stack (not a nested runLoop), so
          # deep recursion through try-wrapped code does not grow the Nim stack. The
          # catch clauses and ensure block run on the error/exit path — on normal
          # completion via frameReturn, on a thrown error via the dispatch loop's
          # exception handler below — both keyed off the TryHandler pushed here.
          let tp = chunk.tries[inst[].intArg]
          pushFrame()
          handlers.add TryHandler(tp: tp, scope: scope, framesLen: frames.len)
          chunk = tp.body                 # shares the enclosing scope
          stack = acquireRunStack()
          ip = 0
          validateImplRequirements = false
          returnType = NIL
          returnLabel = ""
          curChecksErrors = false
          curErrorTypes = @[]
          curFnName = ""
          curFrameKind = fkTryBody
          evalBudget = scope.evalBudget
          continue
        of opTaskScope:
          let taskScope = newScope(scope)
          taskScope.ownsTasks = true
          taskScope.ownsActors = true
          taskScope.actorFailureStrategy = afsStop
          pushFrame()
          enterFrame(chunk.subchunks[inst[].intArg], taskScope,
                     validateImplRequirements, fkTaskScopeBody)
          curOwnedScope = taskScope
          continue
        of opSupervisor:
          var hasEvents = false
          var hasDeadLetters = false
          for sinkName in inst[].names:
            if sinkName == "events":
              hasEvents = true
            elif sinkName == "dead-letter":
              hasDeadLetters = true
          let deadLetterSink =
            if hasDeadLetters:
              let sink = stack.pop()
              requireChannel("supervisor ^dead-letter", sink)
              sink
            else:
              NIL
          let eventSink =
            if hasEvents:
              let sink = stack.pop()
              requireChannel("supervisor ^events", sink)
              sink
            else:
              NIL
          let supervisorScope = newScope(scope)
          supervisorScope.ownsActors = true
          supervisorScope.actorFailureStrategy = supervisorStrategy(inst[].name)
          supervisorScope.supervisorEvents = eventSink
          supervisorScope.supervisorDeadLetters = deadLetterSink
          pushFrame()
          enterFrame(chunk.subchunks[inst[].intArg], supervisorScope,
                     validateImplRequirements, fkSupervisorBody)
          curOwnedScope = supervisorScope
          continue
        of opSpawn:
          # Spawn a child task as a scheduler fiber. The body is queued instead of
          # running inline, so CPU-only child work still cooperates through VM
          # safepoints. Worker-safe tasks receive a sparse captured-scope
          # snapshot; atomicArc threaded builds may hand those leaf-like tasks
          # to the opt-in worker lane.
          let body = chunk.subchunks[inst[].intArg]
          let workerSafe = inst[].flag and scope.spawnCanMoveToWorker(body)
          publishSpawnCapture(scope, body)
          let taskParent =
            if workerSafe: snapshotSpawnScope(scope, body)
            else: scope
          let taskScope = newScope(taskParent)
          let task = spawnFiber(body, taskScope, workerSafe)
          scope.registerOwnedTask(task)
          stack.add task
        of opAwait:
          # Await a task. Inside a scheduled fiber, park on the task (the scheduler
          # runs others and wakes us when it settles) and re-execute opAwait on
          # resume — the task is still on the stack. At the root, drive the queue.
          let task = stack[^1]
          if task.kind == vkTask and not task.taskDone:
            if currentFiberActive:
              captureContinuation(ip - 1)   # task stays on the stack for re-execution
              fiber.waitTask = task
              fiber.waitChannel = NIL
              fiber.waitActor = NIL
              fiber.waitTimer = false
              return RunStop(kind: rskSuspend, value: NIL)
            pumpUntilDone(task)
          discard stack.pop()
          stack.add awaitTaskValue(task)
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
          # A generator suspends in its own (outermost) frame; simpleCall callees
          # never yield, so `frames` is empty here and stack/ip persist via the args.
          let yielded = escapeWeakFunctions(stack[^1])
          stackArg = move stack
          ipArg = ip
          return RunStop(kind: rskYield, value: yielded)
        of opJumpIfFalse:
          if stack.len == 0:
            raise newException(GeneError, "VM stack underflow in conditional jump")
          let top = stack.len - 1
          let cond = stack[top]
          stack.setLen(top)
          if not cond.isTruthy:
            ip = inst[].intArg
        of opJump:
          ip = inst[].intArg
        of opReturn:
          frameReturn(if stack.len > 0: stack.pop() else: NIL)
        of opReturnBareInt:
          frameReturnBareInt(if stack.len > 0: stack.pop() else: NIL)
        of opCheckType:
          if stack.len == 0:
            raise newException(GeneError, "VM stack underflow in type check")
          stack[^1] = adaptBoundary(inst[].name, chunk.constants[inst[].intArg],
                                    stack[^1], scope)
        of opDeclareType:
          scope.declareType(inst[].name, chunk.constants[inst[].intArg])
        # All exits are via frameReturn / opYield above; the loop never falls through.
    except GeneError as e:
      # A recoverable error is unwinding the frame stack. Walk outward from the
      # current frame: give each enclosing `try` (a TryHandler, keyed by frame
      # depth) a chance to catch, run ensure blocks, and translate ^errors
      # boundaries on the function frames crossed. A catch that fires resumes the
      # outer dispatch loop with its result; otherwise the error propagates out.
      var err = translateErrorBoundary(curChecksErrors, curErrorTypes, curFnName, e)
      appendVmTrace(err, curFnName, frames)
      releaseCurrentCallScope()
      if curFrameKind == fkTaskScopeBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        try:
          owned.cancelOwnedTasks()
        finally:
          owned.closeOwnedActors()
      elif curFrameKind == fkSupervisorBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        owned.closeOwnedActors()
      if curFrameKind == fkCatchBody and curEnsureBody != nil:
        let body = curEnsureBody
        let cleanupScope = curEnsureScope
        releaseRunStack(stack)
        enterFrame(body, cleanupScope, false, fkEnsureErrorBody)
        curPendingError = err
        continue
      while true:
        if handlers.len > 0 and handlers[^1].framesLen == frames.len:
          # Unwound back to this try's level. The owner frame remains on `frames`
          # while catch/ensure bodies run as ordinary VM frames, so they can park
          # and resume like the original try body.
          let h = handlers.pop()
          releaseRunStack(stack)        # discard the try body's operand stack
          let ownerValidate = frames[^1].validateImpls
          let errVal =
            if err.hasErrVal: err.errVal
            else:
              var props = initOrderedTable[string, Value]()
              props["message"] = newStr(err.msg)
              newNode(newSym("Error"), props = props)
          var caught = false
          for cl in h.tp.catches:
            var binds = initTable[string, Value]()
            if tryMatch(cl.pattern, errVal, h.scope, binds):
              let catchScope = newScope(h.scope)
              catchScope.prepareChunkScope(cl.body)
              catchScope.bindMatchedValues(binds, replaceExisting = false)
              enterFrame(cl.body, catchScope, ownerValidate, fkCatchBody)
              curEnsureBody = h.tp.ensureBody
              curEnsureScope = h.scope
              caught = true
              break
          if caught:
            break
          elif h.tp.ensureBody != nil:
            enterFrame(h.tp.ensureBody, h.scope, false, fkEnsureErrorBody)
            curPendingError = err
            break
          else:
            # No catch matched: keep unwinding the (possibly re-labelled) error.
            var f = frames.pop()
            stack = move f.stack
            loadFrameRegs(f)
            err = translateErrorBoundary(curChecksErrors, curErrorTypes, curFnName, err)
            releaseCurrentCallScope()
        elif frames.len == 0:
          raise err
        else:
          releaseRunStack(stack)
          var f = frames.pop()
          stack = move f.stack
          loadFrameRegs(f)
          err = translateErrorBoundary(curChecksErrors, curErrorTypes, curFnName, err)
          releaseCurrentCallScope()
      # Reached only via `break` (a catch fired): fall through to the outer
      # `while true`, re-entering dispatch with the catch result on the stack.
    except GenePanic as p:
      # Panics are not catchable, but ensure blocks still run as the panic unwinds
      # out of every active `try` (innermost first), matching the old `finally`.
      releaseCurrentCallScope()
      if curFrameKind == fkTaskScopeBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        try:
          owned.cancelOwnedTasks()
        finally:
          owned.closeOwnedActors()
      elif curFrameKind == fkSupervisorBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        owned.closeOwnedActors()
      if curFrameKind == fkCatchBody and curEnsureBody != nil:
        let body = curEnsureBody
        let cleanupScope = curEnsureScope
        releaseRunStack(stack)
        enterFrame(body, cleanupScope, false, fkEnsurePanicBody)
        curPendingPanic = p
        continue
      var cleanupStarted = false
      while handlers.len > 0:
        let h = handlers.pop()
        if h.tp.ensureBody != nil:
          releaseRunStack(stack)
          enterFrame(h.tp.ensureBody, h.scope, false, fkEnsurePanicBody)
          curPendingPanic = p
          cleanupStarted = true
          break
      if cleanupStarted:
        continue
      for f in frames:
        releaseFrameCallScope(f)
      raise p
    except GeneCancel as c:
      # Cancellation is separate from recoverable Gene errors: catch clauses do
      # not see it, but cleanup still runs as the task unwinds.
      releaseCurrentCallScope()
      if curFrameKind == fkTaskScopeBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        try:
          owned.cancelOwnedTasks()
        finally:
          owned.closeOwnedActors()
      elif curFrameKind == fkSupervisorBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        owned.closeOwnedActors()
      if curFrameKind == fkCatchBody and curEnsureBody != nil:
        let body = curEnsureBody
        let cleanupScope = curEnsureScope
        releaseRunStack(stack)
        enterFrame(body, cleanupScope, false, fkEnsureCancelBody)
        curPendingCancel = c
        continue
      var cleanupStarted = false
      while handlers.len > 0:
        let h = handlers.pop()
        if h.tp.ensureBody != nil:
          releaseRunStack(stack)
          enterFrame(h.tp.ensureBody, h.scope, false, fkEnsureCancelBody)
          curPendingCancel = c
          cleanupStarted = true
          break
      if cleanupStarted:
        continue
      for f in frames:
        releaseFrameCallScope(f)
      if fiber != nil:
        return RunStop(kind: rskCancel, value: NIL)
      raise c
    except SuspendError as se:
      # A blocking channel op asked to park this fiber. Capture the whole
      # continuation into `fiber` and hand control back to the scheduler. The
      # suspending op is re-executed on resume, so rewind ip to it (ip-1); the
      # operand stack still holds its callee + args (opCall had not consumed them).
      # `try` handlers travel along in `handlers`, so ensure blocks do not run.
      if fiber == nil:
        raise newException(GeneError, "internal: suspended outside a fiber")
      captureContinuation(ip - 1)   # re-execute the channel/actor op (operands on stack)
      fiber.waitChannel = se.channel
      fiber.waitActor = se.actor
      fiber.waitIsSend = se.isSend
      fiber.waitSendValue = se.sendValue
      fiber.waitTask = NIL
      fiber.waitTimer = se.timer
      fiber.waitDeadline = se.deadline
      return RunStop(kind: rskSuspend, value: NIL)

proc run*(chunk: Chunk, scope: Scope, validateImplRequirements = true): Value =
  withScheduler(scope):
    let workerLease = beginSchedulerWorkerLease()
    defer:
      endSchedulerWorkerLease(workerLease)
    scope.prepareChunkScope(chunk)
    var stack: seq[Value]
    var ip = 0
    let stopped = runLoop(chunk, scope, stack, ip, stopOnYield = false,
                          validateArg = validateImplRequirements)
    if stopped.kind == rskYield:
      raise newException(GeneError, "yield is only valid in a generator")
    if stopped.kind == rskPause:
      raise newException(GeneError, "internal: scheduler pause outside a fiber")
    if stopped.kind == rskCancel:
      raise newException(GeneCancel, "task was cancelled")
    stopped.value

proc runPooled(chunk: Chunk, scope: Scope,
               validateImplRequirements = true): Value =
  withScheduler(scope):
    if chunk.localNames.len == 0:
      return run(chunk, scope, validateImplRequirements)
    scope.prepareChunkScope(chunk)
    var stack = acquireRunStack()
    var ip = 0
    var stopped: RunStop
    try:
      stopped = runLoop(chunk, scope, stack, ip, stopOnYield = false,
                        validateArg = validateImplRequirements)
    finally:
      releaseRunStack(stack)
    if stopped.kind == rskYield:
      raise newException(GeneError, "yield is only valid in a generator")
    if stopped.kind == rskPause:
      raise newException(GeneError, "internal: scheduler pause outside a fiber")
    if stopped.kind == rskCancel:
      raise newException(GeneCancel, "task was cancelled")
    stopped.value

# ---------------------------------------------------------------------------
# Cooperative task scheduler (design §13.1). Fibers are suspendable Gene tasks;
# they park on channel ops, task awaits, actor mailbox backpressure, and timers.
# The production M:N lifecycle is still open; today the root lane is cooperative
# and atomicArc threaded builds can opt into workers for snapshot-isolated fibers.
# ---------------------------------------------------------------------------

proc enqueueRunnable(f: Fiber) =
  let s = currentScheduler()
  withSchedulerLock(s):
    s.enqueueRunnableUnlocked(f)

proc parkFiber(f: Fiber) =
  let s = currentScheduler()
  withSchedulerLock(s):
    s.waiters.add f

proc hasRunnableFiber(): bool =
  let s = currentScheduler()
  withSchedulerLock(s):
    result = s.runQueue.len > 0

proc popRunnableFiber(workerOnly = false, skipWorkerSafe = false): Fiber =
  let s = currentScheduler()
  withSchedulerLock(s):
    var i = 0
    while i < s.runQueue.len:
      let f = s.runQueue[i]
      let isWorkerCandidate = f.workerCandidate
      if workerOnly and not isWorkerCandidate:
        inc i
        continue
      if skipWorkerSafe and isWorkerCandidate:
        inc i
        continue
      result = f
      s.runQueue.delete(i)
      return

proc scheduleAskTimeout(task, reply: Value, scope: Scope, timeoutMs: int64) =
  let s = currentScheduler()
  withSchedulerLock(s):
    s.askTimeouts.add AskTimeout(task: task, reply: reply, scope: scope,
                                 deadline: timerDeadline(timeoutMs))

proc failExpiredAskTimeouts(now: MonoTime): bool =
  let s = currentScheduler()
  var expired: seq[AskTimeout]
  withSchedulerLock(s):
    var i = 0
    while i < s.askTimeouts.len:
      let item = s.askTimeouts[i]
      if item.task.kind != vkTask or item.task.taskDone:
        s.askTimeouts.delete(i)
      elif item.deadline <= now:
        expired.add item
        s.askTimeouts.delete(i)
      else:
        inc i
  for item in expired:
    if item.task.kind == vkTask and not item.task.taskDone:
      const message = "actor/ask timed out"
      failTask(item.task, message, actorErrorValue(item.scope, message),
               hasValue = true)
      wakeTaskWaiters(item.task)
    result = true

proc wakeExpiredTimers(now = getMonoTime()): bool =
  let s = currentScheduler()
  withSchedulerLock(s):
    var i = 0
    while i < s.waiters.len:
      let f = s.waiters[i]
      if f.waitTimer and f.waitDeadline <= now:
        s.waiters.delete(i)
        s.enqueueRunnableUnlocked(f)
        result = true
      else:
        inc i
  if failExpiredAskTimeouts(now):
    result = true

proc nextTimerDeadline(): tuple[has: bool, deadline: MonoTime] =
  let s = currentScheduler()
  withSchedulerLock(s):
    for f in s.waiters:
      if f.waitTimer:
        if not result.has or f.waitDeadline < result.deadline:
          result.has = true
          result.deadline = f.waitDeadline
    for item in s.askTimeouts:
      if item.task.kind == vkTask and not item.task.taskDone:
        if not result.has or item.deadline < result.deadline:
          result.has = true
          result.deadline = item.deadline

proc sleepUntil(deadline: MonoTime) =
  let remaining = deadline - getMonoTime()
  if remaining <= initDuration():
    return
  os.sleep(max(1, int(min(remaining.inMilliseconds, int64(high(int))))))

proc wakeChannelWaiters(channel: Value, wakeSenders: bool) =
  ## Move one fiber parked on `channel` — a receiver, or a sender when
  ## `wakeSenders` — from the wait list onto the run queue (FIFO over waiters).
  let s = currentScheduler()
  withSchedulerLock(s):
    for i in 0 ..< s.waiters.len:
      let f = s.waiters[i]
      if f.waitIsSend == wakeSenders and same(f.waitChannel, channel):
        s.waiters.delete(i)
        s.enqueueRunnableUnlocked(f)
        return

proc wakeAllChannelWaiters(channel: Value, wakeSenders: bool) =
  ## Channel close changes the state observed by every parked counterpart:
  ## receivers on an empty channel and senders on a full one must all resume and
  ## re-run their operation so they can raise ChannelClosed.
  let s = currentScheduler()
  withSchedulerLock(s):
    var i = 0
    while i < s.waiters.len:
      let f = s.waiters[i]
      if f.waitIsSend == wakeSenders and same(f.waitChannel, channel):
        s.waiters.delete(i)
        s.enqueueRunnableUnlocked(f)
      else:
        inc i

proc wakeTaskWaiters(task: Value) =
  ## Move every fiber parked in `await` on `task` onto the run queue. A completed
  ## task wakes all of its awaiters (unlike a channel, which wakes one counterpart).
  let s = currentScheduler()
  withSchedulerLock(s):
    var i = 0
    while i < s.waiters.len:
      let f = s.waiters[i]
      if f.waitTask.taskSharesState(task):
        s.waiters.delete(i)
        s.enqueueRunnableUnlocked(f)
      else:
        inc i

proc makeActorFiber(actor: Value, item: ActorMessage, scope: Scope): Fiber =
  ## Build a fiber that runs the actor's handler on one message. Returns nil if the
  ## handler is not a fiber-able Gene function (the caller then processes inline).
  let handler = actor.actorHandler
  if handler.kind != vkFunction or handler.fnCode == nil or
      not (handler.fnCode of FunctionProto):
    return nil
  let proto = FunctionProto(handler.fnCode)
  if proto.isGenerator:
    return nil
  let args = [newActorContext(actor), actor.actorState, item.message]
  let bound = bindCallScope(handler, proto, args, NamedArgs())
  Fiber(chunk: proto.chunk, scope: bound.scope, actorOwner: actor,
        actorReturnType: bound.returnType, actorScope: scope,
        actorAskReply: item.reply, actorMessage: item.message, started: false)

proc scheduleActor(actor: Value, scope: Scope) =
  ## If the actor is idle (no live handler fiber) and has a queued message, start
  ## processing it: pop the message, wake a parked sender (a slot just freed), mark
  ## the actor busy, and enqueue its handler fiber on the run queue.
  let started = actor.tryStartActorMessage()
  if not started.started:
    return
  let item = started.item
  wakeActorSenders(actor)
  let f = makeActorFiber(actor, item, scope)
  if f == nil:
    # Non-fiber handler (no current surface produces this): process inline.
    actor.setActorProcessing(false)
    var args = [newActorContext(actor), actor.actorState, item.message]
    let step = applyCall(actor.actorHandler, args, NamedArgs(), scope)
    if step.kind != vkActorStep:
      raiseTypeError("actor handler return", "ActorStep", step, scope)
    if step.actorStepContinue: actor.setActorState(step.actorStepState)
    else: closeActorAndCancelMailbox(actor)
    if item.reply.kind == vkReplyTo and not item.reply.replyToSent:
      discard failMissingReply(item.reply, scope)
    scheduleActor(actor, scope)
  else:
    enqueueRunnable(f)

proc runFiber(f: Fiber) =
  ## Run or resume `f` until it completes or parks. A spawn/await fiber settles its
  ## task and wakes its awaiters; an actor handler fiber applies its ActorStep (or
  ## failure strategy) and advances the actor to its next message. A parked fiber
  ## had its continuation captured by the dispatch loop, so just keep it on the
  ## wait list.
  if not f.started:
    f.scope.prepareChunkScope(f.chunk)
  var dummyStack: seq[Value]
  var dummyIp = 0
  let savedActive = currentFiberActive
  currentFiberActive = true
  defer: currentFiberActive = savedActive
  let actor = f.actorOwner
  let isActorFiber = actor.kind == vkActorRef
  try:
    let injectCancel =
      f.task.kind == vkTask and f.task.taskCancelRequested and
        not f.task.taskDone and not f.inCancelCleanup()
    let stop = runLoop(f.chunk, f.scope, dummyStack, dummyIp, stopOnYield = false,
                       validateArg = true, fiber = f,
                       injectCancel = injectCancel,
                       instructionBudget = schedulerInstructionBudget)
    if isActorFiber:
      case stop.kind
      of rskReturn:
        actor.setActorProcessing(false)
        var step = stop.value
        if f.actorReturnType.kind != vkNil:
          step = adaptBoundary("return from actor handler", f.actorReturnType,
                               step, f.actorScope)
        if step.kind != vkActorStep:
          raiseTypeError("actor handler return", "ActorStep", step, f.actorScope)
        if step.actorStepContinue: actor.setActorState(step.actorStepState)
        else: closeActorAndCancelMailbox(actor)
        if f.actorAskReply.kind == vkReplyTo and
            not f.actorAskReply.replyToSent:
          discard failMissingReply(f.actorAskReply, f.actorScope)
        scheduleActor(actor, f.actorScope)
      of rskSuspend:
        parkFiber(f)                # handler parked mid-message; actor stays busy
      of rskPause:
        enqueueRunnable(f)          # handler stays busy but yields to peers
      of rskCancel:
        closeActorAndCancelMailbox(actor)
        if not cancelReplyTask(f.actorAskReply):
          raise newException(GeneCancel, "task was cancelled")
      of rskYield:
        closeActorAndCancelMailbox(actor)
        raise newException(GeneError, "actor handler cannot yield")
    else:
      case stop.kind
      of rskReturn:
        completeTask(f.task, stop.value)
        wakeTaskWaiters(f.task)
      of rskSuspend:
        parkFiber(f)
      of rskPause:
        enqueueRunnable(f)
      of rskCancel:
        f.task.finishTaskCancel()
        wakeTaskWaiters(f.task)
      of rskYield:
        failTask(f.task, "yield is only valid in a generator")
        wakeTaskWaiters(f.task)
  except GeneError as e:
    if isActorFiber:
      actor.setActorProcessing(false)
      let askSettled = failReplyTask(f.actorAskReply, e)
      let errorValue = if e.hasErrVal: e.errVal else: newStr(e.msg)
      emitSupervisorFailure(actor, f.actorMessage, f.actorScope, e.msg,
                            errorValue)
      case actor.actorFailureStrategy
      of afsRestart:
        if actor.actorRestartInit.kind == vkNil:
          closeActorAndCancelMailbox(actor)
          if not askSettled:
            raise
          return
        try:
          actor.setActorState(applyCall(actor.actorRestartInit, [], NamedArgs(),
                                         f.actorScope))
        except CatchableError:
          closeActorAndCancelMailbox(actor)
          raise
        scheduleActor(actor, f.actorScope)    # recovered; process the next message
      of afsEscalate:
        closeActorAndCancelMailbox(actor)
        raise
      of afsStop:
        closeActorAndCancelMailbox(actor)
        if not askSettled:
          raise
    else:
      if e.hasErrVal: failTask(f.task, e.msg, e.errVal, hasValue = true)
      else: failTask(f.task, e.msg)
      wakeTaskWaiters(f.task)
  except GenePanic as e:
    if isActorFiber:
      closeActorAndCancelMailbox(actor)
      discard panicReplyTask(f.actorAskReply, e)
      let errorValue = if e.hasErrVal: e.errVal else: newStr(e.msg)
      emitSupervisorFailure(actor, f.actorMessage, f.actorScope, e.msg,
                            errorValue, panic = true)
      raise
    else:
      if e.hasErrVal: panicTask(f.task, e.msg, e.errVal, hasValue = true)
      else: panicTask(f.task, e.msg)
      wakeTaskWaiters(f.task)
  except CatchableError as e:
    if not (e of GeneCancel):
      raise
    if isActorFiber:
      closeActorAndCancelMailbox(actor)
      if not cancelReplyTask(f.actorAskReply):
        raise
    else:
      f.task.finishTaskCancel()
      wakeTaskWaiters(f.task)

when compileOption("threads") and defined(gcAtomicArc):
  const MaxSchedulerWorkers = 32

  proc configuredSchedulerWorkers(): int =
    let raw = getEnv("GENE_WORKERS")
    if raw.len == 0:
      return 0
    try:
      result = parseInt(raw)
    except ValueError:
      return 0
    if result < 0:
      result = 0
    elif result > MaxSchedulerWorkers:
      result = MaxSchedulerWorkers

  proc schedulerWorkerStopRequested(s: SchedulerState): bool =
    withSchedulerLock(s):
      s.workerStop

  proc markSchedulerWorkerActive(s: SchedulerState, active: bool) =
    withSchedulerLock(s):
      if active:
        inc s.activeWorkerCount
      elif s.activeWorkerCount > 0:
        dec s.activeWorkerCount

  proc schedulerHasWorkerProgress(s: SchedulerState): bool =
    withSchedulerLock(s):
      if s.activeWorkerCount > 0:
        return true
      for f in s.runQueue:
        if f.workerCandidate:
          return true

  proc schedulerHasWorkerCandidateUnlocked(s: SchedulerState): bool =
    for f in s.runQueue:
      if f.workerCandidate:
        return true

  proc waitForSchedulerWorkerCandidate(s: SchedulerState) =
    var pollTimer = false
    withSchedulerLock(s):
      if s.workerStop or s.schedulerHasWorkerCandidateUnlocked():
        return
      for f in s.waiters:
        if f.waitTimer:
          pollTimer = true
          break
      if not pollTimer:
        for item in s.askTimeouts:
          if item.task.kind == vkTask and not item.task.taskDone:
            pollTimer = true
            break
      if not pollTimer:
        wait(s.workerCond, s.lock)
        return
    if pollTimer:
      # std/locks has no timed Cond wait; poll only while scheduler timers exist.
      os.sleep(schedulerWorkerTimerPollMs)

  proc schedulerWorkerLoop(s: SchedulerState) {.thread.} =
    {.cast(gcsafe).}:
      activeScheduler = s
      while not schedulerWorkerStopRequested(s):
        discard wakeExpiredTimers()
        let f = popRunnableFiber(workerOnly = true)
        if f == nil:
          waitForSchedulerWorkerCandidate(s)
          continue
        if f.task.kind == vkTask and f.task.taskDone:
          wakeTaskWaiters(f.task)
          continue
        markSchedulerWorkerActive(s, true)
        try:
          runFiber(f)
        finally:
          markSchedulerWorkerActive(s, false)

  proc startSchedulerWorkers(s: SchedulerState): bool =
    withSchedulerLock(s):
      if s.workersStarted:
        inc s.workerLeaseCount
        return true
      let workerCount = configuredSchedulerWorkers()
      if workerCount <= 0:
        return false
      s.workerStop = false
      s.activeWorkerCount = 0
      s.workers.setLen(workerCount)
      s.workersStarted = true
      s.workerLeaseCount = 1
      for i in 0 ..< workerCount:
        createThread(s.workers[i], schedulerWorkerLoop, s)
      true

  proc stopSchedulerWorkers(s: SchedulerState) =
    var shouldJoin = false
    withSchedulerLock(s):
      if s.workerLeaseCount > 0:
        dec s.workerLeaseCount
      if s.workersStarted and s.workerLeaseCount == 0:
        s.workerStop = true
        broadcast(s.workerCond)
        shouldJoin = true
    if shouldJoin:
      for i in 0 ..< s.workers.len:
        joinThread(s.workers[i])
      withSchedulerLock(s):
        s.workers.setLen(0)
        s.workersStarted = false
        s.workerLeaseCount = 0
        s.workerStop = false
        s.activeWorkerCount = 0

proc beginSchedulerWorkerLease(): SchedulerWorkerLease =
  when compileOption("threads") and defined(gcAtomicArc):
    result.scheduler = currentScheduler()
    result.active = startSchedulerWorkers(result.scheduler)

proc endSchedulerWorkerLease(lease: SchedulerWorkerLease) =
  when compileOption("threads") and defined(gcAtomicArc):
    if lease.active:
      stopSchedulerWorkers(lease.scheduler)

proc schedulerWorkerLeaseHasProgress(lease: SchedulerWorkerLease): bool =
  when compileOption("threads") and defined(gcAtomicArc):
    lease.active and lease.scheduler != nil and
      lease.scheduler.schedulerHasWorkerProgress()
  else:
    false

proc schedulerRunOneRoot(lease: SchedulerWorkerLease): bool =
  if schedulerRunOne(skipWorkerSafe = lease.active):
    return true
  if schedulerWorkerLeaseHasProgress(lease):
    os.sleep(1)
    return true
  false

proc schedulerRunOneRootUntil(deadline: MonoTime,
                              lease: SchedulerWorkerLease): bool =
  if schedulerRunOneUntil(deadline, skipWorkerSafe = lease.active):
    return true
  if schedulerWorkerLeaseHasProgress(lease):
    os.sleep(1)
    return true
  false

proc spawnFiber(chunk: Chunk, scope: Scope, workerSafe = false): Value =
  ## Create a child task + fiber and enqueue it for scheduler execution. This keeps
  ## spawn asynchronous even when the body is CPU-only; await/drain/root blocking
  ## operations drive the run queue until the task completes or parks.
  let task = newPendingTask()
  let f = Fiber(chunk: chunk, scope: scope, task: task, actorOwner: NIL,
                started: false, workerSafe: workerSafe)
  enqueueRunnable(f)
  task

proc schedulerRunOne(skipWorkerSafe = false): bool =
  ## Run one runnable fiber to its next park/completion. If only timer waiters
  ## remain, sleep until the next timer expires and run the awakened fiber.
  if wakeExpiredTimers() and not hasRunnableFiber():
    return true
  var f = popRunnableFiber(skipWorkerSafe = skipWorkerSafe)
  while f == nil:
    let next = nextTimerDeadline()
    if not next.has:
      return false
    sleepUntil(next.deadline)
    if wakeExpiredTimers() and not hasRunnableFiber():
      return true
    f = popRunnableFiber(skipWorkerSafe = skipWorkerSafe)
  if f.task.kind == vkTask and f.task.taskDone:
    wakeTaskWaiters(f.task)
    return true
  runFiber(f)
  true

proc schedulerRunOneUntil(deadline: MonoTime, skipWorkerSafe = false): bool =
  ## Run one fiber, waiting for timers only up to `deadline`. Used by root-level
  ## sleep so it can advance already-scheduled work without oversleeping its own
  ## timer.
  if wakeExpiredTimers() and not hasRunnableFiber():
    return true
  var f = popRunnableFiber(skipWorkerSafe = skipWorkerSafe)
  while f == nil:
    let next = nextTimerDeadline()
    if not next.has:
      return false
    if next.deadline > deadline:
      return false
    sleepUntil(next.deadline)
    if wakeExpiredTimers() and not hasRunnableFiber():
      return true
    f = popRunnableFiber(skipWorkerSafe = skipWorkerSafe)
  if f.task.kind == vkTask and f.task.taskDone:
    wakeTaskWaiters(f.task)
    return true
  runFiber(f)
  true

proc cancelScheduledTask(task: Value): bool =
  ## Mark the task's own continuation for cancellation and move any parked
  ## continuation back to the run queue so runFiber can inject GeneCancel and
  ## let ensure blocks unwind. If the fiber is already in the run queue, it
  ## stays there — runFiber checks taskCancelRequested dynamically on entry.
  ## Fibers merely awaiting this task are left parked; wakeTaskWaiters runs
  ## after the task finally settles.
  let s = currentScheduler()
  withSchedulerLock(s):
    var i = 0
    while i < s.runQueue.len:
      if s.runQueue[i].task.taskSharesState(task):
        result = true # already runnable; runFiber will inject cancel next turn
        inc i
      else:
        inc i
    i = 0
    while i < s.waiters.len:
      let f = s.waiters[i]
      if f.task.taskSharesState(task):
        s.waiters.delete(i)
        s.enqueueRunnableUnlocked(f)
        result = true
      else:
        inc i

proc pumpUntilDone(task: Value) =
  ## Drive the run queue until `task` settles. Each runnable fiber advances to its
  ## next park/completion; a parked fiber resumes only when a channel op wakes it.
  ## If the queue drains with the task unfinished, it can never finish.
  let workerLease = beginSchedulerWorkerLease()
  defer:
    endSchedulerWorkerLease(workerLease)
  while not task.taskDone:
    if not schedulerRunOneRoot(workerLease):
      raise newException(GeneError,
        "deadlock: awaited task is blocked with no runnable task to unblock it")

proc wakeActorSenders(actor: Value) =
  ## Wake one fiber parked on a previously-full mailbox of `actor` (FIFO), now that
  ## a slot has freed up; it re-executes its send on resume.
  let s = currentScheduler()
  withSchedulerLock(s):
    for i in 0 ..< s.waiters.len:
      let f = s.waiters[i]
      if same(f.waitActor, actor):
        s.waiters.delete(i)
        s.enqueueRunnableUnlocked(f)
        return

proc driveActor(actor: Value) =
  ## Pump the scheduler until `actor` is idle (its mailbox is drained and no handler
  ## fiber is live) or closed. Used by root-level send/ask so they stay synchronous:
  ## the message is fully processed before the call returns.
  var workerLease: SchedulerWorkerLease
  var workerLeaseOpen = false
  defer:
    if workerLeaseOpen:
      endSchedulerWorkerLease(workerLease)
  while not actor.actorClosed and
      (actor.actorProcessing or actor.actorQueueLen > 0):
    if not workerLeaseOpen:
      workerLease = beginSchedulerWorkerLease()
      workerLeaseOpen = true
    if not schedulerRunOneRoot(workerLease):
      break

proc pullGeneratorStream(stream: Value): StreamPullResult {.nimcall.} =
  let code = stream.streamGeneratorCode
  if code == nil or not (code of FunctionProto):
    return StreamPullResult(has: false, item: NIL)
  let proto = FunctionProto(code)
  var ip = stream.streamGeneratorIp
  let stopped = runLoop(proto.chunk, stream.streamGeneratorScope,
                        stream.streamGeneratorStack, ip,
                        stopOnYield = true,
                        validateArg = false)
  stream.setStreamGeneratorIp(ip)
  case stopped.kind
  of rskYield:
    StreamPullResult(has: true, item: stopped.value)
  of rskReturn:
    stream.closeStream()
    StreamPullResult(has: false, item: NIL)
  of rskSuspend:
    raise newException(GeneError, "generator cannot suspend on a channel")
  of rskPause:
    raise newException(GeneError, "internal: generator paused by scheduler")
  of rskCancel:
    raise newException(GeneCancel, "task was cancelled")

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

proc checkedAddI64(a, b: int64, outValue: var int64): bool {.inline.} =
  if (b > 0 and a > high(int64) - b) or
     (b < 0 and a < low(int64) - b):
    return false
  outValue = a + b
  true

proc checkedSubI64(a, b: int64, outValue: var int64): bool {.inline.} =
  if (b > 0 and a < low(int64) + b) or
     (b < 0 and a > high(int64) + b):
    return false
  outValue = a - b
  true

proc absMagnitudeI64(v: int64): uint64 {.inline.} =
  if v < 0: uint64(-(v + 1)) + 1'u64 else: uint64(v)

proc checkedMulI64(a, b: int64, outValue: var int64): bool {.inline.} =
  if a == 0 or b == 0:
    outValue = 0
    return true
  if a == low(int64) and b == -1: return false
  if b == low(int64) and a == -1: return false
  let aa = absMagnitudeI64(a)
  let bb = absMagnitudeI64(b)
  let negative = (a < 0) xor (b < 0)
  let limit = if negative: 1'u64 shl 63 else: uint64(high(int64))
  if aa > limit div bb:
    return false
  let mag = aa * bb
  if negative:
    outValue = if mag == (1'u64 shl 63): low(int64) else: -int64(mag)
  else:
    outValue = int64(mag)
  true

proc nativeI64Result(op: NativeCompileOp, lhs, rhs: Value): Value =
  var nativeResult: int64
  let ok =
    case op
    of ncoI64Add: checkedAddI64(lhs.intVal, rhs.intVal, nativeResult)
    of ncoI64Sub: checkedSubI64(lhs.intVal, rhs.intVal, nativeResult)
    of ncoI64Mul: checkedMulI64(lhs.intVal, rhs.intVal, nativeResult)
    else: false
  if ok:
    return newInt(nativeResult)
  case op
  of ncoI64Add: intAdd(lhs, rhs)
  of ncoI64Sub: intSub(lhs, rhs)
  of ncoI64Mul: intMul(lhs, rhs)
  else: NIL

proc nativeF64Result(op: NativeCompileOp, lhs, rhs: Value): Value =
  case op
  of ncoF64Add: newFloat(lhs.floatVal + rhs.floatVal)
  of ncoF64Sub: newFloat(lhs.floatVal - rhs.floatVal)
  of ncoF64Mul: newFloat(lhs.floatVal * rhs.floatVal)
  else: NIL

proc applyNativeCompiled(callee: Value, proto: FunctionProto,
                         args: openArray[Value],
                         named: NamedArgs): tuple[handled: bool, value: Value] =
  if proto.nativeOp == ncoNone:
    return (false, NIL)
  if named.len != 0:
    return (false, NIL)
  try:
    let positional = callee.fnParams
    if args.len != positional.len:
      raise newException(GeneError,
        "function '" & callee.fnName & "' expects " & $proto.requiredPositional &
        ".." & $positional.len & " argument(s), got " & $args.len)

    var lhs = args[0]
    var rhs = args[1]
    if proto.hasParamTypes and proto.paramTypes[0].kind != vkNil:
      lhs = adaptBoundary("parameter '" & positional[0] & "'",
                          proto.paramTypes[0], lhs, callee.fnScope)
    if proto.hasParamTypes and proto.paramTypes[1].kind != vkNil:
      rhs = adaptBoundary("parameter '" & positional[1] & "'",
                          proto.paramTypes[1], rhs, callee.fnScope)

    let resultValue =
      case proto.nativeOp
      of ncoIntAdd:
        intAdd(lhs, rhs)
      of ncoIntSub:
        intSub(lhs, rhs)
      of ncoIntMul:
        intMul(lhs, rhs)
      of ncoI64Add, ncoI64Sub, ncoI64Mul:
        nativeI64Result(proto.nativeOp, lhs, rhs)
      of ncoF64Add, ncoF64Sub, ncoF64Mul:
        nativeF64Result(proto.nativeOp, lhs, rhs)
      of ncoNone:
        NIL

    if proto.hasReturnType and not proto.returnKnownBareInt:
      return (true, adaptBoundary("return from '" & callee.fnName & "'",
                                  proto.returnType, resultValue, callee.fnScope))
    return (true, resultValue)
  except GeneError as e:
    appendNativeTrace(e, callee.fnName, proto)
    raise

proc typeExprLabel(expr: Value): string =
  if expr.kind == vkNil:
    return "Any"
  if expr.kind == vkNode and expr.head.isSymbol("c-abi-type") and
      expr.body.len == 1 and expr.body[0].kind == vkSymbol:
    return "C/" & expr.body[0].symVal
  if expr.kind == vkNode and expr.head.isSymbol("path"):
    var parts: seq[string]
    for part in expr.body:
      if part.kind != vkSymbol:
        return expr.print()
      parts.add part.symVal
    return parts.join("/")
  if expr.kind == vkNode and expr.props.len == 0 and expr.meta.len == 0:
    var parts = @[typeExprLabel(expr.head)]
    for item in expr.body:
      parts.add typeExprLabel(item)
    return "(" & parts.join(" ") & ")"
  expr.print()

proc isAnyType(expr: Value): bool =
  expr.kind == vkNil or (expr.kind == vkSymbol and expr.symVal == "Any")

proc typeExprEqual(a, b: Value): bool =
  if a.isAnyType and b.isAnyType:
    return true
  equal(a, b)

proc typeNode(name: string, body: sink seq[Value] = @[]): Value =
  newNode(newSym(name), body = body)

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
  of vkBuffer:
    let elemType = value.bufferElemType
    if elemType.kind == vkNil:
      newSym("Buffer")
    else:
      typeNode("Buffer", @[elemType])
  of vkDeviceBuffer:
    let elemType = value.deviceBufferElemType
    if elemType.kind == vkNil:
      newSym("Device/Buffer")
    else:
      typeNode("Device/Buffer", @[elemType])
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
  of vkTask:
    let resultType = value.taskResultType
    if resultType.kind == vkNil:
      newSym("Task")
    else:
      let errType =
        if value.taskErrorType.kind == vkNil: newSym("Any")
        else: value.taskErrorType
      typeNode("Task", @[resultType, errType])
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
  of vkCPtr:
    let name =
      if value.cPtrOwned: "C/OwnedPtr"
      elif value.cPtrMutable: "C/Ptr"
      else: "C/ConstPtr"
    let targetType =
      if value.cPtrTargetType.kind == vkNil: newSym("Any")
      else: value.cPtrTargetType
    typeNode(name, @[targetType])
  of vkCSlice:
    let targetType =
      if value.cSliceTargetType.kind == vkNil: newSym("Any")
      else: value.cSliceTargetType
    typeNode("C/Slice", @[targetType])
  of vkCapability: newSym("Capability")
  of vkFfiLoad: newSym("Ffi/Load")
  of vkFfiLibrary: newSym("Ffi/Library")
  of vkFfiCallable: newSym("Ffi/Callable")
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
    let closedExpr = closeTypeExpr(expr, scope)
    if closedExpr.bits != expr.bits:
      return matchesTypeExpr(closedExpr, value, scope)
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
      of "Buffer":
        if value.kind != vkBuffer:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(Buffer T) expects one item type")
        let itemType =
          if value.bufferElemType.kind == vkNil:
            newSym("Any")
          else:
            value.bufferElemType
        if expr.body[0].kind == vkSymbol and expr.body[0].symVal in typeParams:
          return bindings.bindTypeParam(expr.body[0].symVal, itemType)
        return matchesBufferType(expr.body, value, scope)
      of "Device/Buffer":
        if value.kind != vkDeviceBuffer:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(Device/Buffer T) expects one item type")
        let itemType =
          if value.deviceBufferElemType.kind == vkNil:
            newSym("Any")
          else:
            value.deviceBufferElemType
        if expr.body[0].kind == vkSymbol and expr.body[0].symVal in typeParams:
          return bindings.bindTypeParam(expr.body[0].symVal, itemType)
        return matchesDeviceBufferType(expr.body, value, scope)
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
      of "Task":
        if value.kind != vkTask:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 2:
          raise newException(GeneError, "(Task result err) expects result and error types")
        let resultType = value.taskResultType
        if resultType.kind != vkNil and expr.body[0].kind == vkSymbol and
            expr.body[0].symVal in typeParams:
          if not bindings.bindTypeParam(expr.body[0].symVal, resultType):
            return false
        let errType = value.taskErrorType
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

proc strHasInteriorNul(value: Value): bool =
  value.kind == vkString and '\0' in value.strVal

proc matchesCAbiType(name: string, value: Value): tuple[known, ok: bool] =
  case name
  of "C/Int8":
    (true, value.intInRange(-128'i64, 127'i64))
  of "C/UInt8":
    (true, value.intInRange(0'i64, 255'i64))
  of "C/Int16":
    (true, value.intInRange(-32768'i64, 32767'i64))
  of "C/UInt16":
    (true, value.intInRange(0'i64, 65535'i64))
  of "C/Int32":
    (true, value.intInRange(-2147483648'i64, 2147483647'i64))
  of "C/UInt32":
    (true, value.intInRange(0'i64, 4294967295'i64))
  of "C/Int64":
    (true, value.intInRange(low(int64), high(int64)))
  of "C/UInt64":
    (true, value.intInDecimalRange("0", "18446744073709551615"))
  of "C/Char":
    (true, value.kind == vkChar or value.intInRange(-128'i64, 127'i64))
  of "C/UChar":
    (true, value.kind == vkChar or value.intInRange(0'i64, 255'i64))
  of "C/Short":
    (true, value.intInRange(-32768'i64, 32767'i64))
  of "C/UShort":
    (true, value.intInRange(0'i64, 65535'i64))
  of "C/Int":
    (true, value.intInRange(-2147483648'i64, 2147483647'i64))
  of "C/UInt":
    (true, value.intInRange(0'i64, 4294967295'i64))
  of "C/Long":
    (true, value.intInRange(low(int64), high(int64)))
  of "C/ULong":
    (true, value.intInDecimalRange("0", "18446744073709551615"))
  of "C/Size":
    (true, value.intInDecimalRange("0", "18446744073709551615"))
  of "C/PtrDiff":
    (true, value.intInRange(low(int64), high(int64)))
  of "C/Float":
    (true, value.floatInF32Range)
  of "C/Double":
    (true, value.kind == vkFloat)
  of "C/Bool":
    (true, value.kind == vkBool)
  of "C/Void":
    (true, value.kind in {vkNil, vkVoid})
  of "C/CStr":
    (true, value.kind == vkString and not value.strHasInteriorNul)
  else:
    (false, false)

proc matchesBuiltinType(name: string, value: Value): tuple[known, ok: bool] =
  let cAbi = matchesCAbiType(name, value)
  if cAbi.known:
    return cAbi
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
  of "Buffer":
    (true, value.kind == vkBuffer)
  of "Device/Buffer":
    (true, value.kind == vkDeviceBuffer)
  of "Capability":
    (true, value.kind == vkCapability)
  of "Ffi/Load":
    (true, value.kind == vkFfiLoad)
  of "Ffi/Library":
    (true, value.kind == vkFfiLibrary)
  of "Ffi/Callable":
    (true, value.kind == vkFfiCallable)
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
    (true, value.kind in {vkFunction, vkNativeFn, vkFfiCallable, vkType,
                          vkProtocolMessage} or
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
    if expr.head.isSymbol("path") and expr.body.len == 2 and
        expr.body[1].kind == vkSymbol:
      if expr.body[0].isSymbol("C"):
        return newSym("C/" & expr.body[1].symVal)
      if expr.body[0].isSymbol("Ffi"):
        return newSym("Ffi/" & expr.body[1].symVal)
      if expr.body[0].isSymbol("Device"):
        return newSym("Device/" & expr.body[1].symVal)
    let closedHead = closeTypeExpr(expr.head, scope)
    var changed = closedHead.bits != expr.head.bits
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
      newNode(closedHead, props = props, body = body, meta = meta,
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

proc cPtrTargetMatches(expected, actual: Value, scope: Scope): bool =
  let closedExpected = closeTypeExpr(expected, scope)
  if closedExpected.isAnyType:
    return true
  if actual.kind == vkNil:
    return false
  let closedActual = closeTypeExpr(actual, scope)
  typeExprEqual(closedExpected, closedActual)

proc matchesCPtrType(name: string, args: openArray[Value],
                     value: Value, scope: Scope): bool =
  if args.len != 1:
    raise newException(GeneError, "(" & name & " T) expects one target type")
  let nullable = name == "C/NullablePtr" or name == "C/NullableConstPtr"
  let needsMutable = name == "C/Ptr" or name == "C/NullablePtr" or
    name == "C/OwnedPtr"
  let needsOwned = name == "C/OwnedPtr"
  if nullable and value.kind == vkNil:
    return true
  if value.kind != vkCPtr:
    return false
  if value.cPtrClosed:
    return false
  if not nullable and value.cPtrIsNull:
    return false
  if needsMutable and not value.cPtrMutable:
    return false
  if needsOwned and not value.cPtrOwned:
    return false
  cPtrTargetMatches(args[0], value.cPtrTargetType, scope)

proc matchesCSliceType(name: string, args: openArray[Value],
                       value: Value, scope: Scope): bool =
  if args.len != 1:
    raise newException(GeneError, "(" & name & " T) expects one target type")
  if value.kind != vkCSlice:
    return false
  if value.cSliceLen < 0:
    return false
  if value.cSliceIsNull and value.cSliceLen != 0:
    return false
  cPtrTargetMatches(args[0], value.cSliceTargetType, scope)

proc matchesBufferType(args: openArray[Value], value: Value,
                       scope: Scope): bool =
  if value.kind != vkBuffer:
    return false
  if args.len == 0:
    return true
  if args.len != 1:
    raise newException(GeneError, "(Buffer T) expects one item type")
  let expected = closeTypeExpr(args[0], scope)
  if expected.isAnyTypeValue:
    return true
  let actual = value.bufferElemType
  if actual.kind == vkNil or actual.isAnyTypeValue:
    return false
  typeExprEqual(expected, closeTypeExpr(actual, value.bufferElemScope))

proc matchesDeviceBufferType(args: openArray[Value], value: Value,
                             scope: Scope): bool =
  if value.kind != vkDeviceBuffer:
    return false
  if args.len == 0:
    return true
  if args.len != 1:
    raise newException(GeneError, "(Device/Buffer T) expects one item type")
  let expected = closeTypeExpr(args[0], scope)
  if expected.isAnyTypeValue:
    return true
  let actual = value.deviceBufferElemType
  if actual.kind == vkNil or actual.isAnyTypeValue:
    return false
  typeExprEqual(expected, closeTypeExpr(actual, scope))

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
    let closedExpr = closeTypeExpr(expr, scope)
    if closedExpr.bits != expr.bits:
      return matchesTypeExpr(closedExpr, value, scope)
    if expr.head.kind == vkSymbol:
      case expr.head.symVal
      of "path":
        return matchesTypeExpr(closeTypeExpr(expr, scope), value, scope)
      of "C/Ptr", "C/NullablePtr", "C/ConstPtr", "C/NullableConstPtr",
         "C/OwnedPtr":
        return matchesCPtrType(expr.head.symVal, expr.body, value, scope)
      of "C/Slice":
        return matchesCSliceType(expr.head.symVal, expr.body, value, scope)
      of "Buffer":
        return matchesBufferType(expr.body, value, scope)
      of "Device/Buffer":
        return matchesDeviceBufferType(expr.body, value, scope)
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
        let resultType = value.taskResultType
        if resultType.kind != vkNil and
            not typeExprEqual(closeTypeExpr(expr.body[0], scope), resultType):
          return false
        let errType = value.taskErrorType
        if errType.kind != vkNil and
            not typeExprEqual(closeTypeExpr(expr.body[1], scope), errType):
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
  if typeExpr.kind == vkNode and typeExpr.head.isSymbol("Task") and
      typeExpr.body.len == 2:
    let boundaryScope =
      if scope == nil: nil
      else: scope.application().builtinsScope()
    return newCheckedTask(value, closeTypeExpr(typeExpr.body[0], scope),
                          closeTypeExpr(typeExpr.body[1], scope), boundaryScope)
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

proc isSelectorCallStage(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("call-stage") and v.body.len > 0

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
      raise newException(GeneError, "selector contains an unresolved dynamic segment")
    VOID
  else:
    VOID

proc applySelectorCallStage(stage, target: Value): Value =
  if stage.body.len == 0:
    raise newException(GeneError, "selector call stage requires a callee")
  case stage.body.len
  of 1:
    var callArgs = [target]
    applyCall(stage.body[0], callArgs, NamedArgs())
  of 2:
    var callArgs = [target, stage.body[1]]
    applyCall(stage.body[0], callArgs, NamedArgs())
  of 3:
    var callArgs = [target, stage.body[1], stage.body[2]]
    applyCall(stage.body[0], callArgs, NamedArgs())
  else:
    var callArgs = newSeqOfCap[Value](stage.body.len)
    callArgs.add target
    for i in 1 ..< stage.body.len:
      callArgs.add stage.body[i]
    applyCall(stage.body[0], callArgs, NamedArgs())

proc selectorStrict(selector: Value): bool =
  if not selector.props.hasKey("strict"):
    return false
  let value = selector.props["strict"]
  if value.kind != vkBool:
    raise newException(GeneError, "selector ^strict must be Bool")
  value.boolVal

proc selectorMissingResult(selector: Value, segment: Value): Value =
  if selector.selectorStrict:
    raise newException(GeneError,
      "selector lookup failed at segment: " & segment.print())
  if selector.props.hasKey("default"):
    selector.props["default"]
  else:
    VOID

proc applySelector(selector, target: Value): Value =
  let strict = selector.selectorStrict
  result = target
  for segment in selector.body:
    result =
      case segment.kind
      of vkFunction, vkNativeFn, vkFfiCallable:
        block:
          var callArgs = [result]
          applyCall(segment, callArgs, NamedArgs())
      of vkNode:
        if segment.isSelectorKeySegment:
          staticLookup(result, segment.body[0])
        elif segment.isSelectorCallStage:
          applySelectorCallStage(segment, result)
        elif segment.isSelector:
          block:
            var callArgs = [result]
            applyCall(segment, callArgs, NamedArgs())
        else:
          staticLookup(result, segment)
      else:
        staticLookup(result, segment)
    if result.kind == vkVoid:
      if strict:
        raise newException(GeneError,
          "selector lookup failed at segment: " & segment.print())
      return selector.selectorMissingResult(segment)

proc ensureNoInteriorNul(name: string, text: string) =
  for ch in text:
    if ch == '\0':
      raise newException(GeneError, name & " rejects strings with interior NUL")

proc ffiCIntArg(name: string, value: Value): cint =
  let raw = requireInt64(name, value)
  if raw < int64(low(cint)) or raw > int64(high(cint)):
    raise newException(GeneError, name & " is out of C/Int range")
  cint(raw)

proc ffiCInt32Arg(name: string, value: Value): int32 =
  let raw = requireInt64(name, value)
  if raw < int64(low(int32)) or raw > int64(high(int32)):
    raise newException(GeneError, name & " is out of C/Int32 range")
  int32(raw)

proc ffiCInt16Arg(name: string, value: Value): int16 =
  let raw = requireInt64(name, value)
  if raw < int64(low(int16)) or raw > int64(high(int16)):
    raise newException(GeneError, name & " is out of C/Int16 range")
  int16(raw)

proc ffiCShortArg(name: string, value: Value): cshort =
  let raw = requireInt64(name, value)
  if raw < int64(low(cshort)) or raw > int64(high(cshort)):
    raise newException(GeneError, name & " is out of C/Short range")
  cshort(raw)

proc ffiCInt8Arg(name: string, value: Value): int8 =
  let raw = requireInt64(name, value)
  if raw < int64(low(int8)) or raw > int64(high(int8)):
    raise newException(GeneError, name & " is out of C/Int8 range")
  int8(raw)

proc ffiCCharArg(name: string, value: Value): cchar =
  if value.kind == vkChar:
    let raw = int64(int32(value.charVal))
    if raw > 127:
      raise newException(GeneError, name & " is out of C/Char range")
    return cchar(raw)
  let raw = requireInt64(name, value)
  if raw < -128 or raw > 127:
    raise newException(GeneError, name & " is out of C/Char range")
  cchar(uint8(raw and 0xff))

proc ffiCUIntArg(name: string, value: Value): cuint =
  let raw = requireInt64(name, value)
  if raw < 0 or raw > int64(high(cuint)):
    raise newException(GeneError, name & " is out of C/UInt range")
  cuint(raw)

proc ffiCUInt32Arg(name: string, value: Value): uint32 =
  let raw = requireInt64(name, value)
  if raw < 0 or raw > int64(high(uint32)):
    raise newException(GeneError, name & " is out of C/UInt32 range")
  uint32(raw)

proc ffiCUInt16Arg(name: string, value: Value): uint16 =
  let raw = requireInt64(name, value)
  if raw < 0 or raw > int64(high(uint16)):
    raise newException(GeneError, name & " is out of C/UInt16 range")
  uint16(raw)

proc ffiCUShortArg(name: string, value: Value): cushort =
  let raw = requireInt64(name, value)
  if raw < 0 or raw > int64(high(cushort)):
    raise newException(GeneError, name & " is out of C/UShort range")
  cushort(raw)

proc ffiCUInt8Arg(name: string, value: Value): uint8 =
  let raw = requireInt64(name, value)
  if raw < 0 or raw > int64(high(uint8)):
    raise newException(GeneError, name & " is out of C/UInt8 range")
  uint8(raw)

proc ffiCUCharArg(name: string, value: Value): uint8 =
  if value.kind == vkChar:
    let raw = int64(int32(value.charVal))
    if raw > int64(high(uint8)):
      raise newException(GeneError, name & " is out of C/UChar range")
    return uint8(raw)
  let raw = requireInt64(name, value)
  if raw < 0 or raw > int64(high(uint8)):
    raise newException(GeneError, name & " is out of C/UChar range")
  uint8(raw)

proc ffiCLongArg(name: string, value: Value): clong =
  let raw = requireInt64(name, value)
  when sizeof(clong) < sizeof(int64):
    if raw < int64(low(clong)) or raw > int64(high(clong)):
      raise newException(GeneError, name & " is out of C/Long range")
  clong(raw)

proc ffiCInt64Arg(name: string, value: Value): int64 =
  requireInt64(name, value)

proc ffiCUInt64Value(value: uint64): Value =
  if value <= uint64(high(int64)):
    newInt(int64(value))
  else:
    newIntFromDecimal($value)

proc ffiCUInt64Arg(name, label: string, value: Value,
                   maxValue = "18446744073709551615"): uint64 =
  if value.kind != vkInt:
    raise newException(GeneError, name & " expects an Int")
  if intCompare(value, newInt(0)) < 0 or
      intCompare(value, newIntFromDecimal(maxValue)) > 0:
    raise newException(GeneError, name & " is out of " & label & " range")
  try:
    parseUInt(value.intToString)
  except ValueError:
    raise newException(GeneError, name & " is out of " & label & " range")

proc ffiCULongArg(name: string, value: Value): culong =
  culong(ffiCUInt64Arg(name, "C/ULong", value, $high(culong)))

proc ffiCPtrDiffArg(name: string, value: Value): int =
  let raw = requireInt64(name, value)
  when sizeof(int) < sizeof(int64):
    if raw < int64(low(int)) or raw > int64(high(int)):
      raise newException(GeneError, name & " is out of C/PtrDiff range")
  int(raw)

proc ffiCSizeArg(name: string, value: Value): csize_t =
  csize_t(ffiCUInt64Arg(name, "C/Size", value, $high(csize_t)))

proc ffiCBoolArg(name: string, value: Value): bool =
  if value.kind != vkBool:
    raiseTypeError(name, "C/Bool", value, nil)
  value.boolVal

proc ffiCDoubleArg(name: string, value: Value): cdouble =
  if value.kind != vkFloat:
    raiseTypeError(name, "C/Double", value, nil)
  cdouble(value.floatVal)

proc ffiCFloatArg(name: string, value: Value): cfloat =
  if value.kind != vkFloat:
    raiseTypeError(name, "C/Float", value, nil)
  if not value.floatInF32Range:
    raise newException(GeneError, name & " is out of C/Float range")
  cfloat(value.floatVal)

proc ffiCStrArg(name: string, value: Value): cstring =
  if value.kind != vkString:
    raiseTypeError(name, "Str", value, nil)
  let text = value.strVal
  ensureNoInteriorNul(name, text)
  text.cstring

proc ffiCStrResult(name: string, value: cstring): Value =
  if value == nil:
    raise newException(GeneError, name & " returned null C/CStr")
  newStr($value)

proc ffiCCharResult(value: cchar): Value =
  newChar(Rune(ord(value)))

proc isFfiPtrLabel(label: string): bool =
  label.startsWith("(C/Ptr ") or label.startsWith("(C/NullablePtr ") or
    label.startsWith("(C/ConstPtr ") or
    label.startsWith("(C/NullableConstPtr ") or
    label.startsWith("(C/OwnedPtr ")

proc isFfiSliceLabel(label: string): bool =
  label.startsWith("(C/Slice ")

proc isFfiBufferLabel(label: string): bool =
  label.startsWith("(Buffer ")

proc isFfiNullablePtrLabel(label: string): bool =
  label.startsWith("(C/NullablePtr ") or
    label.startsWith("(C/NullableConstPtr ")

proc ffiPointerTarget(label: string): Value =
  if label.endsWith(")") and label.startsWith("("):
    let space = label.find(' ')
    if space >= 0 and space + 1 < label.high:
      return newSym(label[(space + 1) ..< label.high])
  NIL

proc ffiPointerResult(label: string, address: pointer,
                      releaseAddress: pointer = nil): Value =
  if address == nil and not isFfiNullablePtrLabel(label):
    raise newException(GeneError, "FFI returned null for non-null pointer result")
  if label.startsWith("(C/OwnedPtr "):
    if releaseAddress == nil:
      raise newException(GeneError,
        "FFI OwnedPtr result requires a release function")
    newCForeignOwnedPtr(address, releaseAddress, ffiPointerTarget(label))
  elif label.startsWith("(C/ConstPtr ") or
      label.startsWith("(C/NullableConstPtr "):
    newCConstPtr(address, ffiPointerTarget(label))
  else:
    newCPtr(address, ffiPointerTarget(label))

proc ffiPointerArg(name, label: string, typeExpr, value: Value): pointer =
  let checked = adaptBoundary(name, typeExpr, value, nil)
  if checked.kind == vkNil and isFfiNullablePtrLabel(label):
    return nil
  if checked.kind != vkCPtr:
    raiseTypeError(name, label, value, nil)
  checked.cPtrAddress

proc ffiSliceArg(name, label: string, typeExpr, value: Value):
    tuple[address: pointer, length: csize_t] =
  let checked = adaptBoundary(name, typeExpr, value, nil)
  if checked.kind != vkCSlice:
    raiseTypeError(name, label, value, nil)
  (checked.cSliceAddress, csize_t(checked.cSliceLen))

type FfiBufferArg = object
  bytes: seq[uint8]
  data: pointer
  length: csize_t

proc ffiBufferArg(name, label: string, typeExpr, value: Value): FfiBufferArg =
  let checked = adaptBoundary(name, typeExpr, value, nil)
  if checked.kind != vkBuffer:
    raiseTypeError(name, label, value, nil)
  let elementLabel = ffiPointerTarget(label).print()
  if elementLabel notin ["C/UInt8", "C/UChar", "C/Char", "C/Int8"]:
    raise newException(GeneError,
      name & " only supports dynamic FFI buffers of byte-compatible C types")
  let items = checked.bufferItems
  result.bytes = newSeq[uint8](items.len)
  for i, item in items:
    let itemName = name & " item " & $i
    result.bytes[i] =
      case elementLabel
      of "C/UInt8":
        ffiCUInt8Arg(itemName, item)
      of "C/UChar":
        ffiCUCharArg(itemName, item)
      of "C/Char":
        uint8(ffiCCharArg(itemName, item))
      else:
        uint8(ffiCInt8Arg(itemName, item))
  result.length = csize_t(result.bytes.len)
  if result.bytes.len > 0:
    result.data = cast[pointer](addr result.bytes[0])

proc applyFfiCallable(callee: Value, args: openArray[Value],
                      named: NamedArgs): Value =
  if named.len != 0:
    raise newException(GeneError,
      "FFI callable '" & callee.ffiCallableName & "' does not accept named arguments")
  if callee.ffiCallableLibrary.ffiLibraryClosed:
    raise newException(GeneError,
      "FFI callable '" & callee.ffiCallableName & "' library is closed")
  let params = callee.ffiCallableParamTypes
  if args.len != params.len:
    raise newException(GeneError,
      "FFI callable '" & callee.ffiCallableName & "' expects " &
      $params.len & " argument(s), got " & $args.len)
  var paramLabels: seq[string]
  for param in params:
    paramLabels.add typeExprLabel(param)
  let returnLabel = typeExprLabel(callee.ffiCallableReturnType)
  let releaseAddress = callee.ffiCallableReleaseAddress
  if paramLabels.len == 0:
    case returnLabel
    of "C/Void":
      type VoidVoidProc = proc() {.cdecl.}
      let fn = cast[VoidVoidProc](callee.ffiCallableAddress)
      fn()
      return NIL
    of "C/Int":
      type VoidIntProc = proc(): cint {.cdecl.}
      let fn = cast[VoidIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/Int32":
      type VoidInt32Proc = proc(): int32 {.cdecl.}
      let fn = cast[VoidInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/Int16":
      type VoidInt16Proc = proc(): int16 {.cdecl.}
      let fn = cast[VoidInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/Short":
      type VoidShortProc = proc(): cshort {.cdecl.}
      let fn = cast[VoidShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/Int8":
      type VoidInt8Proc = proc(): int8 {.cdecl.}
      let fn = cast[VoidInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/Char":
      type VoidCharProc = proc(): cchar {.cdecl.}
      let fn = cast[VoidCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn())
    of "C/UInt":
      type VoidUIntProc = proc(): cuint {.cdecl.}
      let fn = cast[VoidUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/UInt32":
      type VoidUInt32Proc = proc(): uint32 {.cdecl.}
      let fn = cast[VoidUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/UInt16":
      type VoidUInt16Proc = proc(): uint16 {.cdecl.}
      let fn = cast[VoidUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/UShort":
      type VoidUShortProc = proc(): cushort {.cdecl.}
      let fn = cast[VoidUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/UInt8":
      type VoidUInt8Proc = proc(): uint8 {.cdecl.}
      let fn = cast[VoidUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/UChar":
      type VoidUCharProc = proc(): uint8 {.cdecl.}
      let fn = cast[VoidUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/Long":
      type VoidLongProc = proc(): clong {.cdecl.}
      let fn = cast[VoidLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/ULong":
      type VoidULongProc = proc(): culong {.cdecl.}
      let fn = cast[VoidULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn()))
    of "C/Int64":
      type VoidInt64Proc = proc(): int64 {.cdecl.}
      let fn = cast[VoidInt64Proc](callee.ffiCallableAddress)
      return newInt(fn())
    of "C/UInt64":
      type VoidUInt64Proc = proc(): uint64 {.cdecl.}
      let fn = cast[VoidUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn())
    of "C/Size":
      type VoidSizeProc = proc(): csize_t {.cdecl.}
      let fn = cast[VoidSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn()))
    of "C/PtrDiff":
      type VoidPtrDiffProc = proc(): int {.cdecl.}
      let fn = cast[VoidPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn()))
    of "C/Float":
      type VoidFloatProc = proc(): cfloat {.cdecl.}
      let fn = cast[VoidFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn()))
    of "C/Double":
      type VoidDoubleProc = proc(): cdouble {.cdecl.}
      let fn = cast[VoidDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn()))
    of "C/Bool":
      type VoidBoolProc = proc(): bool {.cdecl.}
      let fn = cast[VoidBoolProc](callee.ffiCallableAddress)
      return newBool(fn())
    of "C/CStr":
      type VoidCStrProc = proc(): cstring {.cdecl.}
      let fn = cast[VoidCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn())
    else:
      if isFfiPtrLabel(returnLabel):
        type VoidPtrProc = proc(): pointer {.cdecl.}
        let fn = cast[VoidPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Bool":
    let arg0 = ffiCBoolArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type BoolIntProc = proc(x: bool): cint {.cdecl.}
      let fn = cast[BoolIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type BoolUIntProc = proc(x: bool): cuint {.cdecl.}
      let fn = cast[BoolUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type BoolLongProc = proc(x: bool): clong {.cdecl.}
      let fn = cast[BoolLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type BoolSizeProc = proc(x: bool): csize_t {.cdecl.}
      let fn = cast[BoolSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type BoolFloatProc = proc(x: bool): cfloat {.cdecl.}
      let fn = cast[BoolFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type BoolDoubleProc = proc(x: bool): cdouble {.cdecl.}
      let fn = cast[BoolDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type BoolBoolProc = proc(x: bool): bool {.cdecl.}
      let fn = cast[BoolBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type BoolCStrProc = proc(x: bool): cstring {.cdecl.}
      let fn = cast[BoolCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type BoolVoidProc = proc(x: bool) {.cdecl.}
      let fn = cast[BoolVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type BoolPtrProc = proc(x: bool): pointer {.cdecl.}
        let fn = cast[BoolPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Char":
    let arg0 = ffiCCharArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type CharIntProc = proc(x: cchar): cint {.cdecl.}
      let fn = cast[CharIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type CharUIntProc = proc(x: cchar): cuint {.cdecl.}
      let fn = cast[CharUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type CharLongProc = proc(x: cchar): clong {.cdecl.}
      let fn = cast[CharLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type CharSizeProc = proc(x: cchar): csize_t {.cdecl.}
      let fn = cast[CharSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type CharFloatProc = proc(x: cchar): cfloat {.cdecl.}
      let fn = cast[CharFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type CharDoubleProc = proc(x: cchar): cdouble {.cdecl.}
      let fn = cast[CharDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Char":
      type CharCharProc = proc(x: cchar): cchar {.cdecl.}
      let fn = cast[CharCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UChar":
      type CharUCharProc = proc(x: cchar): uint8 {.cdecl.}
      let fn = cast[CharUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Bool":
      type CharBoolProc = proc(x: cchar): bool {.cdecl.}
      let fn = cast[CharBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type CharCStrProc = proc(x: cchar): cstring {.cdecl.}
      let fn = cast[CharCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type CharVoidProc = proc(x: cchar) {.cdecl.}
      let fn = cast[CharVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type CharPtrProc = proc(x: cchar): pointer {.cdecl.}
        let fn = cast[CharPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/UChar":
    let arg0 = ffiCUCharArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type UCharIntProc = proc(x: uint8): cint {.cdecl.}
      let fn = cast[UCharIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UCharUIntProc = proc(x: uint8): cuint {.cdecl.}
      let fn = cast[UCharUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UCharLongProc = proc(x: uint8): clong {.cdecl.}
      let fn = cast[UCharLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type UCharSizeProc = proc(x: uint8): csize_t {.cdecl.}
      let fn = cast[UCharSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type UCharFloatProc = proc(x: uint8): cfloat {.cdecl.}
      let fn = cast[UCharFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UCharDoubleProc = proc(x: uint8): cdouble {.cdecl.}
      let fn = cast[UCharDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Char":
      type UCharCharProc = proc(x: uint8): cchar {.cdecl.}
      let fn = cast[UCharCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UChar":
      type UCharUCharProc = proc(x: uint8): uint8 {.cdecl.}
      let fn = cast[UCharUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Bool":
      type UCharBoolProc = proc(x: uint8): bool {.cdecl.}
      let fn = cast[UCharBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type UCharCStrProc = proc(x: uint8): cstring {.cdecl.}
      let fn = cast[UCharCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type UCharVoidProc = proc(x: uint8) {.cdecl.}
      let fn = cast[UCharVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type UCharPtrProc = proc(x: uint8): pointer {.cdecl.}
        let fn = cast[UCharPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/UInt64":
    let arg0 = ffiCUInt64Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", "C/UInt64", args[0])
    case returnLabel
    of "C/Int":
      type UInt64IntProc = proc(x: uint64): cint {.cdecl.}
      let fn = cast[UInt64IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UInt64UIntProc = proc(x: uint64): cuint {.cdecl.}
      let fn = cast[UInt64UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UInt64LongProc = proc(x: uint64): clong {.cdecl.}
      let fn = cast[UInt64LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type UInt64ULongProc = proc(x: uint64): culong {.cdecl.}
      let fn = cast[UInt64ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type UInt64Int64Proc = proc(x: uint64): int64 {.cdecl.}
      let fn = cast[UInt64Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type UInt64UInt64Proc = proc(x: uint64): uint64 {.cdecl.}
      let fn = cast[UInt64UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type UInt64SizeProc = proc(x: uint64): csize_t {.cdecl.}
      let fn = cast[UInt64SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type UInt64PtrDiffProc = proc(x: uint64): int {.cdecl.}
      let fn = cast[UInt64PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type UInt64FloatProc = proc(x: uint64): cfloat {.cdecl.}
      let fn = cast[UInt64FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UInt64DoubleProc = proc(x: uint64): cdouble {.cdecl.}
      let fn = cast[UInt64DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type UInt64BoolProc = proc(x: uint64): bool {.cdecl.}
      let fn = cast[UInt64BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type UInt64CStrProc = proc(x: uint64): cstring {.cdecl.}
      let fn = cast[UInt64CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type UInt64VoidProc = proc(x: uint64) {.cdecl.}
      let fn = cast[UInt64VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type UInt64PtrProc = proc(x: uint64): pointer {.cdecl.}
        let fn = cast[UInt64PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/ULong":
    let arg0 = ffiCULongArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type ULongIntProc = proc(x: culong): cint {.cdecl.}
      let fn = cast[ULongIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type ULongUIntProc = proc(x: culong): cuint {.cdecl.}
      let fn = cast[ULongUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type ULongLongProc = proc(x: culong): clong {.cdecl.}
      let fn = cast[ULongLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type ULongULongProc = proc(x: culong): culong {.cdecl.}
      let fn = cast[ULongULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type ULongInt64Proc = proc(x: culong): int64 {.cdecl.}
      let fn = cast[ULongInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type ULongUInt64Proc = proc(x: culong): uint64 {.cdecl.}
      let fn = cast[ULongUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type ULongSizeProc = proc(x: culong): csize_t {.cdecl.}
      let fn = cast[ULongSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type ULongPtrDiffProc = proc(x: culong): int {.cdecl.}
      let fn = cast[ULongPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type ULongFloatProc = proc(x: culong): cfloat {.cdecl.}
      let fn = cast[ULongFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type ULongDoubleProc = proc(x: culong): cdouble {.cdecl.}
      let fn = cast[ULongDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type ULongBoolProc = proc(x: culong): bool {.cdecl.}
      let fn = cast[ULongBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type ULongCStrProc = proc(x: culong): cstring {.cdecl.}
      let fn = cast[ULongCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type ULongVoidProc = proc(x: culong) {.cdecl.}
      let fn = cast[ULongVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type ULongPtrProc = proc(x: culong): pointer {.cdecl.}
        let fn = cast[ULongPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/PtrDiff":
    let arg0 = ffiCPtrDiffArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type PtrDiffIntProc = proc(x: int): cint {.cdecl.}
      let fn = cast[PtrDiffIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type PtrDiffUIntProc = proc(x: int): cuint {.cdecl.}
      let fn = cast[PtrDiffUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type PtrDiffLongProc = proc(x: int): clong {.cdecl.}
      let fn = cast[PtrDiffLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type PtrDiffULongProc = proc(x: int): culong {.cdecl.}
      let fn = cast[PtrDiffULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type PtrDiffInt64Proc = proc(x: int): int64 {.cdecl.}
      let fn = cast[PtrDiffInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type PtrDiffUInt64Proc = proc(x: int): uint64 {.cdecl.}
      let fn = cast[PtrDiffUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type PtrDiffSizeProc = proc(x: int): csize_t {.cdecl.}
      let fn = cast[PtrDiffSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type PtrDiffPtrDiffProc = proc(x: int): int {.cdecl.}
      let fn = cast[PtrDiffPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type PtrDiffFloatProc = proc(x: int): cfloat {.cdecl.}
      let fn = cast[PtrDiffFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type PtrDiffDoubleProc = proc(x: int): cdouble {.cdecl.}
      let fn = cast[PtrDiffDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type PtrDiffBoolProc = proc(x: int): bool {.cdecl.}
      let fn = cast[PtrDiffBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type PtrDiffCStrProc = proc(x: int): cstring {.cdecl.}
      let fn = cast[PtrDiffCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type PtrDiffVoidProc = proc(x: int) {.cdecl.}
      let fn = cast[PtrDiffVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type PtrDiffPtrProc = proc(x: int): pointer {.cdecl.}
        let fn = cast[PtrDiffPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Int":
    let arg0 = ffiCIntArg("FFI argument 0 for '" & callee.ffiCallableName & "'",
                          args[0])
    case returnLabel
    of "C/Int":
      type IntIntProc = proc(x: cint): cint {.cdecl.}
      let fn = cast[IntIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type IntUIntProc = proc(x: cint): cuint {.cdecl.}
      let fn = cast[IntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type IntLongProc = proc(x: cint): clong {.cdecl.}
      let fn = cast[IntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type IntSizeProc = proc(x: cint): csize_t {.cdecl.}
      let fn = cast[IntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type IntFloatProc = proc(x: cint): cfloat {.cdecl.}
      let fn = cast[IntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type IntDoubleProc = proc(x: cint): cdouble {.cdecl.}
      let fn = cast[IntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type IntCStrProc = proc(x: cint): cstring {.cdecl.}
      let fn = cast[IntCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type IntVoidProc = proc(x: cint) {.cdecl.}
      let fn = cast[IntVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      discard
  if paramLabels.len == 1 and paramLabels[0] == "C/UInt":
    let arg0 = ffiCUIntArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type UIntIntProc = proc(x: cuint): cint {.cdecl.}
      let fn = cast[UIntIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UIntUIntProc = proc(x: cuint): cuint {.cdecl.}
      let fn = cast[UIntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UIntLongProc = proc(x: cuint): clong {.cdecl.}
      let fn = cast[UIntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type UIntSizeProc = proc(x: cuint): csize_t {.cdecl.}
      let fn = cast[UIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type UIntFloatProc = proc(x: cuint): cfloat {.cdecl.}
      let fn = cast[UIntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UIntDoubleProc = proc(x: cuint): cdouble {.cdecl.}
      let fn = cast[UIntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type UIntCStrProc = proc(x: cuint): cstring {.cdecl.}
      let fn = cast[UIntCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type UIntVoidProc = proc(x: cuint) {.cdecl.}
      let fn = cast[UIntVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type UIntPtrProc = proc(x: cuint): pointer {.cdecl.}
        let fn = cast[UIntPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/UInt32":
    let arg0 = ffiCUInt32Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type UInt32IntProc = proc(x: uint32): cint {.cdecl.}
      let fn = cast[UInt32IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type UInt32Int32Proc = proc(x: uint32): int32 {.cdecl.}
      let fn = cast[UInt32Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UInt32UIntProc = proc(x: uint32): cuint {.cdecl.}
      let fn = cast[UInt32UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UInt32UInt32Proc = proc(x: uint32): uint32 {.cdecl.}
      let fn = cast[UInt32UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UInt32LongProc = proc(x: uint32): clong {.cdecl.}
      let fn = cast[UInt32LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type UInt32Int64Proc = proc(x: uint32): int64 {.cdecl.}
      let fn = cast[UInt32Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type UInt32SizeProc = proc(x: uint32): csize_t {.cdecl.}
      let fn = cast[UInt32SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type UInt32FloatProc = proc(x: uint32): cfloat {.cdecl.}
      let fn = cast[UInt32FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UInt32DoubleProc = proc(x: uint32): cdouble {.cdecl.}
      let fn = cast[UInt32DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type UInt32CStrProc = proc(x: uint32): cstring {.cdecl.}
      let fn = cast[UInt32CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type UInt32VoidProc = proc(x: uint32) {.cdecl.}
      let fn = cast[UInt32VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type UInt32PtrProc = proc(x: uint32): pointer {.cdecl.}
        let fn = cast[UInt32PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/UInt16":
    let arg0 = ffiCUInt16Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type UInt16IntProc = proc(x: uint16): cint {.cdecl.}
      let fn = cast[UInt16IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type UInt16Int16Proc = proc(x: uint16): int16 {.cdecl.}
      let fn = cast[UInt16Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type UInt16Int32Proc = proc(x: uint16): int32 {.cdecl.}
      let fn = cast[UInt16Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UInt16UIntProc = proc(x: uint16): cuint {.cdecl.}
      let fn = cast[UInt16UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UInt16UInt16Proc = proc(x: uint16): uint16 {.cdecl.}
      let fn = cast[UInt16UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UInt16UInt32Proc = proc(x: uint16): uint32 {.cdecl.}
      let fn = cast[UInt16UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UInt16LongProc = proc(x: uint16): clong {.cdecl.}
      let fn = cast[UInt16LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type UInt16Int64Proc = proc(x: uint16): int64 {.cdecl.}
      let fn = cast[UInt16Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type UInt16SizeProc = proc(x: uint16): csize_t {.cdecl.}
      let fn = cast[UInt16SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type UInt16FloatProc = proc(x: uint16): cfloat {.cdecl.}
      let fn = cast[UInt16FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UInt16DoubleProc = proc(x: uint16): cdouble {.cdecl.}
      let fn = cast[UInt16DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type UInt16CStrProc = proc(x: uint16): cstring {.cdecl.}
      let fn = cast[UInt16CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type UInt16VoidProc = proc(x: uint16) {.cdecl.}
      let fn = cast[UInt16VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type UInt16PtrProc = proc(x: uint16): pointer {.cdecl.}
        let fn = cast[UInt16PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/UShort":
    let arg0 = ffiCUShortArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type UShortIntProc = proc(x: cushort): cint {.cdecl.}
      let fn = cast[UShortIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type UShortInt16Proc = proc(x: cushort): int16 {.cdecl.}
      let fn = cast[UShortInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type UShortShortProc = proc(x: cushort): cshort {.cdecl.}
      let fn = cast[UShortShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type UShortInt32Proc = proc(x: cushort): int32 {.cdecl.}
      let fn = cast[UShortInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UShortUIntProc = proc(x: cushort): cuint {.cdecl.}
      let fn = cast[UShortUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UShortUInt16Proc = proc(x: cushort): uint16 {.cdecl.}
      let fn = cast[UShortUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type UShortUShortProc = proc(x: cushort): cushort {.cdecl.}
      let fn = cast[UShortUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UShortUInt32Proc = proc(x: cushort): uint32 {.cdecl.}
      let fn = cast[UShortUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UShortLongProc = proc(x: cushort): clong {.cdecl.}
      let fn = cast[UShortLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type UShortInt64Proc = proc(x: cushort): int64 {.cdecl.}
      let fn = cast[UShortInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type UShortSizeProc = proc(x: cushort): csize_t {.cdecl.}
      let fn = cast[UShortSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type UShortFloatProc = proc(x: cushort): cfloat {.cdecl.}
      let fn = cast[UShortFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UShortDoubleProc = proc(x: cushort): cdouble {.cdecl.}
      let fn = cast[UShortDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type UShortCStrProc = proc(x: cushort): cstring {.cdecl.}
      let fn = cast[UShortCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type UShortVoidProc = proc(x: cushort) {.cdecl.}
      let fn = cast[UShortVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type UShortPtrProc = proc(x: cushort): pointer {.cdecl.}
        let fn = cast[UShortPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/UInt8":
    let arg0 = ffiCUInt8Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type UInt8IntProc = proc(x: uint8): cint {.cdecl.}
      let fn = cast[UInt8IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type UInt8Int8Proc = proc(x: uint8): int8 {.cdecl.}
      let fn = cast[UInt8Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type UInt8Int16Proc = proc(x: uint8): int16 {.cdecl.}
      let fn = cast[UInt8Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type UInt8Int32Proc = proc(x: uint8): int32 {.cdecl.}
      let fn = cast[UInt8Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UInt8UIntProc = proc(x: uint8): cuint {.cdecl.}
      let fn = cast[UInt8UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type UInt8UInt8Proc = proc(x: uint8): uint8 {.cdecl.}
      let fn = cast[UInt8UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UInt8UInt16Proc = proc(x: uint8): uint16 {.cdecl.}
      let fn = cast[UInt8UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UInt8UInt32Proc = proc(x: uint8): uint32 {.cdecl.}
      let fn = cast[UInt8UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UInt8LongProc = proc(x: uint8): clong {.cdecl.}
      let fn = cast[UInt8LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type UInt8Int64Proc = proc(x: uint8): int64 {.cdecl.}
      let fn = cast[UInt8Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type UInt8SizeProc = proc(x: uint8): csize_t {.cdecl.}
      let fn = cast[UInt8SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type UInt8FloatProc = proc(x: uint8): cfloat {.cdecl.}
      let fn = cast[UInt8FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UInt8DoubleProc = proc(x: uint8): cdouble {.cdecl.}
      let fn = cast[UInt8DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type UInt8CStrProc = proc(x: uint8): cstring {.cdecl.}
      let fn = cast[UInt8CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type UInt8VoidProc = proc(x: uint8) {.cdecl.}
      let fn = cast[UInt8VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type UInt8PtrProc = proc(x: uint8): pointer {.cdecl.}
        let fn = cast[UInt8PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Int16":
    let arg0 = ffiCInt16Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type Int16IntProc = proc(x: int16): cint {.cdecl.}
      let fn = cast[Int16IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type Int16Int16Proc = proc(x: int16): int16 {.cdecl.}
      let fn = cast[Int16Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type Int16Int32Proc = proc(x: int16): int32 {.cdecl.}
      let fn = cast[Int16Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type Int16UIntProc = proc(x: int16): cuint {.cdecl.}
      let fn = cast[Int16UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type Int16UInt32Proc = proc(x: int16): uint32 {.cdecl.}
      let fn = cast[Int16UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int16LongProc = proc(x: int16): clong {.cdecl.}
      let fn = cast[Int16LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type Int16Int64Proc = proc(x: int16): int64 {.cdecl.}
      let fn = cast[Int16Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type Int16SizeProc = proc(x: int16): csize_t {.cdecl.}
      let fn = cast[Int16SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type Int16FloatProc = proc(x: int16): cfloat {.cdecl.}
      let fn = cast[Int16FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int16DoubleProc = proc(x: int16): cdouble {.cdecl.}
      let fn = cast[Int16DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type Int16CStrProc = proc(x: int16): cstring {.cdecl.}
      let fn = cast[Int16CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type Int16VoidProc = proc(x: int16) {.cdecl.}
      let fn = cast[Int16VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type Int16PtrProc = proc(x: int16): pointer {.cdecl.}
        let fn = cast[Int16PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Short":
    let arg0 = ffiCShortArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type ShortIntProc = proc(x: cshort): cint {.cdecl.}
      let fn = cast[ShortIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type ShortInt16Proc = proc(x: cshort): int16 {.cdecl.}
      let fn = cast[ShortInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type ShortShortProc = proc(x: cshort): cshort {.cdecl.}
      let fn = cast[ShortShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type ShortInt32Proc = proc(x: cshort): int32 {.cdecl.}
      let fn = cast[ShortInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type ShortUIntProc = proc(x: cshort): cuint {.cdecl.}
      let fn = cast[ShortUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type ShortUInt16Proc = proc(x: cshort): uint16 {.cdecl.}
      let fn = cast[ShortUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type ShortUShortProc = proc(x: cshort): cushort {.cdecl.}
      let fn = cast[ShortUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type ShortUInt32Proc = proc(x: cshort): uint32 {.cdecl.}
      let fn = cast[ShortUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type ShortLongProc = proc(x: cshort): clong {.cdecl.}
      let fn = cast[ShortLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type ShortInt64Proc = proc(x: cshort): int64 {.cdecl.}
      let fn = cast[ShortInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type ShortSizeProc = proc(x: cshort): csize_t {.cdecl.}
      let fn = cast[ShortSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type ShortFloatProc = proc(x: cshort): cfloat {.cdecl.}
      let fn = cast[ShortFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type ShortDoubleProc = proc(x: cshort): cdouble {.cdecl.}
      let fn = cast[ShortDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type ShortCStrProc = proc(x: cshort): cstring {.cdecl.}
      let fn = cast[ShortCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type ShortVoidProc = proc(x: cshort) {.cdecl.}
      let fn = cast[ShortVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type ShortPtrProc = proc(x: cshort): pointer {.cdecl.}
        let fn = cast[ShortPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Int8":
    let arg0 = ffiCInt8Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type Int8IntProc = proc(x: int8): cint {.cdecl.}
      let fn = cast[Int8IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type Int8Int8Proc = proc(x: int8): int8 {.cdecl.}
      let fn = cast[Int8Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type Int8Int16Proc = proc(x: int8): int16 {.cdecl.}
      let fn = cast[Int8Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type Int8Int32Proc = proc(x: int8): int32 {.cdecl.}
      let fn = cast[Int8Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type Int8UIntProc = proc(x: int8): cuint {.cdecl.}
      let fn = cast[Int8UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type Int8UInt8Proc = proc(x: int8): uint8 {.cdecl.}
      let fn = cast[Int8UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type Int8UInt16Proc = proc(x: int8): uint16 {.cdecl.}
      let fn = cast[Int8UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type Int8UInt32Proc = proc(x: int8): uint32 {.cdecl.}
      let fn = cast[Int8UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int8LongProc = proc(x: int8): clong {.cdecl.}
      let fn = cast[Int8LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type Int8Int64Proc = proc(x: int8): int64 {.cdecl.}
      let fn = cast[Int8Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type Int8SizeProc = proc(x: int8): csize_t {.cdecl.}
      let fn = cast[Int8SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type Int8FloatProc = proc(x: int8): cfloat {.cdecl.}
      let fn = cast[Int8FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int8DoubleProc = proc(x: int8): cdouble {.cdecl.}
      let fn = cast[Int8DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type Int8CStrProc = proc(x: int8): cstring {.cdecl.}
      let fn = cast[Int8CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type Int8VoidProc = proc(x: int8) {.cdecl.}
      let fn = cast[Int8VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type Int8PtrProc = proc(x: int8): pointer {.cdecl.}
        let fn = cast[Int8PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Int32":
    let arg0 = ffiCInt32Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type Int32IntProc = proc(x: int32): cint {.cdecl.}
      let fn = cast[Int32IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type Int32Int32Proc = proc(x: int32): int32 {.cdecl.}
      let fn = cast[Int32Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type Int32UIntProc = proc(x: int32): cuint {.cdecl.}
      let fn = cast[Int32UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int32LongProc = proc(x: int32): clong {.cdecl.}
      let fn = cast[Int32LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type Int32Int64Proc = proc(x: int32): int64 {.cdecl.}
      let fn = cast[Int32Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type Int32SizeProc = proc(x: int32): csize_t {.cdecl.}
      let fn = cast[Int32SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type Int32FloatProc = proc(x: int32): cfloat {.cdecl.}
      let fn = cast[Int32FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int32DoubleProc = proc(x: int32): cdouble {.cdecl.}
      let fn = cast[Int32DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type Int32CStrProc = proc(x: int32): cstring {.cdecl.}
      let fn = cast[Int32CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type Int32VoidProc = proc(x: int32) {.cdecl.}
      let fn = cast[Int32VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type Int32PtrProc = proc(x: int32): pointer {.cdecl.}
        let fn = cast[Int32PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Long":
    let arg0 = ffiCLongArg("FFI argument 0 for '" & callee.ffiCallableName & "'",
                           args[0])
    case returnLabel
    of "C/Int":
      type LongIntProc = proc(x: clong): cint {.cdecl.}
      let fn = cast[LongIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type LongUIntProc = proc(x: clong): cuint {.cdecl.}
      let fn = cast[LongUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type LongLongProc = proc(x: clong): clong {.cdecl.}
      let fn = cast[LongLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type LongSizeProc = proc(x: clong): csize_t {.cdecl.}
      let fn = cast[LongSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type LongFloatProc = proc(x: clong): cfloat {.cdecl.}
      let fn = cast[LongFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type LongDoubleProc = proc(x: clong): cdouble {.cdecl.}
      let fn = cast[LongDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type LongCStrProc = proc(x: clong): cstring {.cdecl.}
      let fn = cast[LongCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type LongVoidProc = proc(x: clong) {.cdecl.}
      let fn = cast[LongVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type LongPtrProc = proc(x: clong): pointer {.cdecl.}
        let fn = cast[LongPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Int64":
    let arg0 = ffiCInt64Arg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type Int64IntProc = proc(x: int64): cint {.cdecl.}
      let fn = cast[Int64IntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type Int64UIntProc = proc(x: int64): cuint {.cdecl.}
      let fn = cast[Int64UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int64LongProc = proc(x: int64): clong {.cdecl.}
      let fn = cast[Int64LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int64":
      type Int64Int64Proc = proc(x: int64): int64 {.cdecl.}
      let fn = cast[Int64Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/Size":
      type Int64SizeProc = proc(x: int64): csize_t {.cdecl.}
      let fn = cast[Int64SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type Int64FloatProc = proc(x: int64): cfloat {.cdecl.}
      let fn = cast[Int64FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int64DoubleProc = proc(x: int64): cdouble {.cdecl.}
      let fn = cast[Int64DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type Int64CStrProc = proc(x: int64): cstring {.cdecl.}
      let fn = cast[Int64CStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type Int64VoidProc = proc(x: int64) {.cdecl.}
      let fn = cast[Int64VoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type Int64PtrProc = proc(x: int64): pointer {.cdecl.}
        let fn = cast[Int64PtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Size":
    let arg0 = ffiCSizeArg("FFI argument 0 for '" & callee.ffiCallableName & "'",
                           args[0])
    case returnLabel
    of "C/Int":
      type SizeIntProc = proc(x: csize_t): cint {.cdecl.}
      let fn = cast[SizeIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type SizeUIntProc = proc(x: csize_t): cuint {.cdecl.}
      let fn = cast[SizeUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type SizeLongProc = proc(x: csize_t): clong {.cdecl.}
      let fn = cast[SizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type SizeSizeProc = proc(x: csize_t): csize_t {.cdecl.}
      let fn = cast[SizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type SizeFloatProc = proc(x: csize_t): cfloat {.cdecl.}
      let fn = cast[SizeFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type SizeDoubleProc = proc(x: csize_t): cdouble {.cdecl.}
      let fn = cast[SizeDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type SizeCStrProc = proc(x: csize_t): cstring {.cdecl.}
      let fn = cast[SizeCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type SizeVoidProc = proc(x: csize_t) {.cdecl.}
      let fn = cast[SizeVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type SizePtrProc = proc(x: csize_t): pointer {.cdecl.}
        let fn = cast[SizePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and isFfiSliceLabel(paramLabels[0]):
    let arg0 = ffiSliceArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    case returnLabel
    of "C/Int":
      type SliceIntProc = proc(p: pointer, n: csize_t): cint {.cdecl.}
      let fn = cast[SliceIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/UInt":
      type SliceUIntProc = proc(p: pointer, n: csize_t): cuint {.cdecl.}
      let fn = cast[SliceUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Long":
      type SliceLongProc = proc(p: pointer, n: csize_t): clong {.cdecl.}
      let fn = cast[SliceLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Size":
      type SliceSizeProc = proc(p: pointer, n: csize_t): csize_t {.cdecl.}
      let fn = cast[SliceSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0.address, arg0.length)))
    of "C/Bool":
      type SliceBoolProc = proc(p: pointer, n: csize_t): bool {.cdecl.}
      let fn = cast[SliceBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0.address, arg0.length))
    of "C/CStr":
      type SliceCStrProc = proc(p: pointer, n: csize_t): cstring {.cdecl.}
      let fn = cast[SliceCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0.address, arg0.length))
    of "C/Void":
      type SliceVoidProc = proc(p: pointer, n: csize_t) {.cdecl.}
      let fn = cast[SliceVoidProc](callee.ffiCallableAddress)
      fn(arg0.address, arg0.length)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type SlicePtrProc = proc(p: pointer, n: csize_t): pointer {.cdecl.}
        let fn = cast[SlicePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0.address, arg0.length),
                                releaseAddress)
  if paramLabels.len == 1 and isFfiBufferLabel(paramLabels[0]):
    let arg0 = ffiBufferArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    case returnLabel
    of "C/Int":
      type BufferIntProc = proc(p: pointer, n: csize_t): cint {.cdecl.}
      let fn = cast[BufferIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.data, arg0.length)))
    of "C/UInt":
      type BufferUIntProc = proc(p: pointer, n: csize_t): cuint {.cdecl.}
      let fn = cast[BufferUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.data, arg0.length)))
    of "C/Long":
      type BufferLongProc = proc(p: pointer, n: csize_t): clong {.cdecl.}
      let fn = cast[BufferLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.data, arg0.length)))
    of "C/Size":
      type BufferSizeProc = proc(p: pointer, n: csize_t): csize_t {.cdecl.}
      let fn = cast[BufferSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0.data, arg0.length)))
    of "C/Bool":
      type BufferBoolProc = proc(p: pointer, n: csize_t): bool {.cdecl.}
      let fn = cast[BufferBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0.data, arg0.length))
    of "C/CStr":
      type BufferCStrProc = proc(p: pointer, n: csize_t): cstring {.cdecl.}
      let fn = cast[BufferCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0.data, arg0.length))
    of "C/Void":
      type BufferVoidProc = proc(p: pointer, n: csize_t) {.cdecl.}
      let fn = cast[BufferVoidProc](callee.ffiCallableAddress)
      fn(arg0.data, arg0.length)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type BufferPtrProc = proc(p: pointer, n: csize_t): pointer {.cdecl.}
        let fn = cast[BufferPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0.data, arg0.length),
                                releaseAddress)
  if paramLabels.len == 1 and isFfiPtrLabel(paramLabels[0]):
    let arg0 = ffiPointerArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    case returnLabel
    of "C/Int":
      type PtrIntProc = proc(p: pointer): cint {.cdecl.}
      let fn = cast[PtrIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type PtrUIntProc = proc(p: pointer): cuint {.cdecl.}
      let fn = cast[PtrUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type PtrLongProc = proc(p: pointer): clong {.cdecl.}
      let fn = cast[PtrLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type PtrSizeProc = proc(p: pointer): csize_t {.cdecl.}
      let fn = cast[PtrSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type PtrFloatProc = proc(p: pointer): cfloat {.cdecl.}
      let fn = cast[PtrFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type PtrDoubleProc = proc(p: pointer): cdouble {.cdecl.}
      let fn = cast[PtrDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/CStr":
      type PtrCStrProc = proc(p: pointer): cstring {.cdecl.}
      let fn = cast[PtrCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type PtrVoidProc = proc(p: pointer) {.cdecl.}
      let fn = cast[PtrVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      discard
  if paramLabels.len == 1 and paramLabels[0] == "C/CStr":
    let ctext = ffiCStrArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Size":
      type CStrSizeProc = proc(s: cstring): csize_t {.cdecl.}
      let fn = cast[CStrSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(ctext)))
    of "C/Int":
      type CStrIntProc = proc(s: cstring): cint {.cdecl.}
      let fn = cast[CStrIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/Int32":
      type CStrInt32Proc = proc(s: cstring): int32 {.cdecl.}
      let fn = cast[CStrInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/UInt":
      type CStrUIntProc = proc(s: cstring): cuint {.cdecl.}
      let fn = cast[CStrUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/UInt32":
      type CStrUInt32Proc = proc(s: cstring): uint32 {.cdecl.}
      let fn = cast[CStrUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/Float":
      type CStrFloatProc = proc(s: cstring): cfloat {.cdecl.}
      let fn = cast[CStrFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(ctext)))
    of "C/Double":
      type CStrDoubleProc = proc(s: cstring): cdouble {.cdecl.}
      let fn = cast[CStrDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(ctext)))
    of "C/CStr":
      type CStrCStrProc = proc(s: cstring): cstring {.cdecl.}
      let fn = cast[CStrCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(ctext))
    of "C/Void":
      type CStrVoidProc = proc(s: cstring) {.cdecl.}
      let fn = cast[CStrVoidProc](callee.ffiCallableAddress)
      fn(ctext)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type CStrPtrProc = proc(s: cstring): pointer {.cdecl.}
        let fn = cast[CStrPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(ctext), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Double":
    let arg0 = ffiCDoubleArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type DoubleIntProc = proc(x: cdouble): cint {.cdecl.}
      let fn = cast[DoubleIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type DoubleUIntProc = proc(x: cdouble): cuint {.cdecl.}
      let fn = cast[DoubleUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type DoubleLongProc = proc(x: cdouble): clong {.cdecl.}
      let fn = cast[DoubleLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type DoubleSizeProc = proc(x: cdouble): csize_t {.cdecl.}
      let fn = cast[DoubleSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type DoubleFloatProc = proc(x: cdouble): cfloat {.cdecl.}
      let fn = cast[DoubleFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type DoubleDoubleProc = proc(x: cdouble): cdouble {.cdecl.}
      let fn = cast[DoubleDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Void":
      type DoubleVoidProc = proc(x: cdouble) {.cdecl.}
      let fn = cast[DoubleVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      discard
  if paramLabels.len == 1 and paramLabels[0] == "C/Float":
    let arg0 = ffiCFloatArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type FloatIntProc = proc(x: cfloat): cint {.cdecl.}
      let fn = cast[FloatIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type FloatUIntProc = proc(x: cfloat): cuint {.cdecl.}
      let fn = cast[FloatUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type FloatLongProc = proc(x: cfloat): clong {.cdecl.}
      let fn = cast[FloatLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Size":
      type FloatSizeProc = proc(x: cfloat): csize_t {.cdecl.}
      let fn = cast[FloatSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Float":
      type FloatFloatProc = proc(x: cfloat): cfloat {.cdecl.}
      let fn = cast[FloatFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type FloatDoubleProc = proc(x: cfloat): cdouble {.cdecl.}
      let fn = cast[FloatDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Void":
      type FloatVoidProc = proc(x: cfloat) {.cdecl.}
      let fn = cast[FloatVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      discard
  if paramLabels.len == 2 and paramLabels[0] == "C/CStr" and
      paramLabels[1] == "C/CStr":
    let arg0 = ffiCStrArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCStrArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type CStrCStrIntProc = proc(a, b: cstring): cint {.cdecl.}
      let fn = cast[CStrCStrIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Size":
      type CStrCStrSizeProc = proc(a, b: cstring): csize_t {.cdecl.}
      let fn = cast[CStrCStrSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/CStr":
      type CStrCStrCStrProc = proc(a, b: cstring): cstring {.cdecl.}
      let fn = cast[CStrCStrCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type CStrCStrVoidProc = proc(a, b: cstring) {.cdecl.}
      let fn = cast[CStrCStrVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type CStrCStrPtrProc = proc(a, b: cstring): pointer {.cdecl.}
        let fn = cast[CStrCStrPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/CStr" and
      paramLabels[1] == "C/Int":
    let arg0 = ffiCStrArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCIntArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type CStrIntIntProc = proc(s: cstring, x: cint): cint {.cdecl.}
      let fn = cast[CStrIntIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Size":
      type CStrIntSizeProc = proc(s: cstring, x: cint): csize_t {.cdecl.}
      let fn = cast[CStrIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/CStr":
      type CStrIntCStrProc = proc(s: cstring, x: cint): cstring {.cdecl.}
      let fn = cast[CStrIntCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type CStrIntVoidProc = proc(s: cstring, x: cint) {.cdecl.}
      let fn = cast[CStrIntVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type CStrIntPtrProc = proc(s: cstring, x: cint): pointer {.cdecl.}
        let fn = cast[CStrIntPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/Int" and
      paramLabels[1] == "C/Int":
    let arg0 = ffiCIntArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCIntArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type IntIntIntProc = proc(a, b: cint): cint {.cdecl.}
      let fn = cast[IntIntIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Long":
      type IntIntLongProc = proc(a, b: cint): clong {.cdecl.}
      let fn = cast[IntIntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Size":
      type IntIntSizeProc = proc(a, b: cint): csize_t {.cdecl.}
      let fn = cast[IntIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/Bool":
      type IntIntBoolProc = proc(a, b: cint): bool {.cdecl.}
      let fn = cast[IntIntBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/Void":
      type IntIntVoidProc = proc(a, b: cint) {.cdecl.}
      let fn = cast[IntIntVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type IntIntPtrProc = proc(a, b: cint): pointer {.cdecl.}
        let fn = cast[IntIntPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/Size" and
      paramLabels[1] == "C/Size":
    let arg0 = ffiCSizeArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCSizeArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type SizeSizeIntProc = proc(a, b: csize_t): cint {.cdecl.}
      let fn = cast[SizeSizeIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Long":
      type SizeSizeLongProc = proc(a, b: csize_t): clong {.cdecl.}
      let fn = cast[SizeSizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Size":
      type SizeSizeSizeProc = proc(a, b: csize_t): csize_t {.cdecl.}
      let fn = cast[SizeSizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/CStr":
      type SizeSizeCStrProc = proc(a, b: csize_t): cstring {.cdecl.}
      let fn = cast[SizeSizeCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type SizeSizeVoidProc = proc(a, b: csize_t) {.cdecl.}
      let fn = cast[SizeSizeVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type SizeSizePtrProc = proc(a, b: csize_t): pointer {.cdecl.}
        let fn = cast[SizeSizePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 3 and isFfiPtrLabel(paramLabels[0]) and
      paramLabels[1] == "C/Int" and paramLabels[2] == "C/Size":
    let arg0 = ffiPointerArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    let arg1 = ffiCIntArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    let arg2 = ffiCSizeArg("FFI argument 2 for '" &
      callee.ffiCallableName & "'", args[2])
    case returnLabel
    of "C/Int":
      type PtrIntSizeIntProc = proc(p: pointer, x: cint, n: csize_t): cint {.cdecl.}
      let fn = cast[PtrIntSizeIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Size":
      type PtrIntSizeSizeProc = proc(p: pointer, x: cint, n: csize_t): csize_t {.cdecl.}
      let fn = cast[PtrIntSizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1, arg2)))
    of "C/CStr":
      type PtrIntSizeCStrProc = proc(p: pointer, x: cint, n: csize_t): cstring {.cdecl.}
      let fn = cast[PtrIntSizeCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1, arg2))
    of "C/Void":
      type PtrIntSizeVoidProc = proc(p: pointer, x: cint, n: csize_t) {.cdecl.}
      let fn = cast[PtrIntSizeVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1, arg2)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type PtrIntSizePtrProc = proc(p: pointer, x: cint, n: csize_t): pointer {.cdecl.}
        let fn = cast[PtrIntSizePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1, arg2), releaseAddress)
  if paramLabels.len == 3 and isFfiPtrLabel(paramLabels[0]) and
      isFfiPtrLabel(paramLabels[1]) and paramLabels[2] == "C/Size":
    let arg0 = ffiPointerArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    let arg1 = ffiPointerArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", paramLabels[1], params[1], args[1])
    let arg2 = ffiCSizeArg("FFI argument 2 for '" &
      callee.ffiCallableName & "'", args[2])
    case returnLabel
    of "C/Int":
      type PtrPtrSizeIntProc = proc(a, b: pointer, n: csize_t): cint {.cdecl.}
      let fn = cast[PtrPtrSizeIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/CStr":
      type PtrPtrSizeCStrProc = proc(a, b: pointer, n: csize_t): cstring {.cdecl.}
      let fn = cast[PtrPtrSizeCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1, arg2))
    of "C/Void":
      type PtrPtrSizeVoidProc = proc(a, b: pointer, n: csize_t) {.cdecl.}
      let fn = cast[PtrPtrSizeVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1, arg2)
      return NIL
    else:
      discard
  raise newException(GeneError,
    "unsupported dynamic FFI signature for '" & callee.ffiCallableName &
    "': [" & paramLabels.join(",") & "] -> " & returnLabel)

proc callNamedMap(named: NamedArgs): Value =
  var entries = initOrderedTable[string, Value]()
  for i, name in named.names:
    let value = named.valueAt(i)
    if value.kind != vkVoid:
      entries[name] = value
  newMap(entries)

proc callEnvelope(scope: Scope, args: openArray[Value], named: NamedArgs,
                  site: Value = NIL): Value =
  var props = initOrderedTable[string, Value]()
  props["named"] = callNamedMap(named)
  if site.kind != vkNil:
    props["site"] = site
  var body = newSeq[Value](args.len)
  for i, arg in args:
    body[i] = arg
  newNode(builtinBinding(scope, "Call"), props = props, body = body)

proc applyUserCallable(callee: Value, args: openArray[Value], named: NamedArgs,
                       dispatchScope: Scope, site: Value = NIL): Value =
  let protocol = builtinBinding(dispatchScope, "Callable")
  let message = protocol.protocolMessages["apply"]
  let implFn = resolveProtocolMessage(dispatchScope, message, callee)
  let envelope = callEnvelope(dispatchScope, args, named, site)
  var callArgs = [callee, envelope]
  applyCall(implFn, callArgs, NamedArgs(), dispatchScope)

proc bindCallScope(callee: Value, proto: FunctionProto, args: openArray[Value],
                   named: NamedArgs): tuple[scope: Scope, returnType: Value] =
  ## Build a fully-bound call scope for a non-simple function call: arity check,
  ## named-arg validation, generic inference, per-parameter type adaptation,
  ## defaults, and rest gathering. Returns the scope plus the instantiated return
  ## type (NIL if none). Shared by applyCall (recursive path) and the opCall /
  ## opCallSplice frame push (trampoline). It does not run the body, nor handle
  ## generators or ^errors — those stay with the caller.
  let positional = callee.fnParams
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

  let callScope =
    if proto.poolCallScope:
      acquireCallScope(callee.fnScope, proto.localNames)
    else:
      let fresh = newScope(callee.fnScope)
      fresh.prepareSlots(proto.localNames)
      fresh
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
      let namedIndex = named.argIndex(p.arg)
      if namedIndex >= 0 and proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
        let value = named.valueAt(namedIndex)
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
      if not (typeExpr.isBareIntType and value.kind == vkInt):
        value = adaptBoundary("parameter '" & positional[i] & "'",
                              typeExpr, value, callScope)
    if i < proto.positionalSlots.len and proto.positionalSlots[i] >= 0:
      callScope.defineFreshCallSlot(proto.positionalSlots[i], value)
    else:
      callScope.define(positional[i], value)
    if declaredType.kind != vkNil:
      callScope.declareType(positional[i], declaredType)
  for pIndex, p in proto.namedParams:
    let namedIndex = named.argIndex(p.arg)
    if namedIndex >= 0:
      var value = named.valueAt(namedIndex)
      var declaredType = NIL
      if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
        let typeExpr = instantiateTypeExpr(p.typeExpr, typeBindings,
                                           proto.typeParams)
        declaredType = typeExpr
        if not (typeExpr.isBareIntType and value.kind == vkInt):
          value = adaptBoundary("parameter '" & p.local & "'", typeExpr,
                                value, callScope)
      if pIndex < proto.namedSlots.len and proto.namedSlots[pIndex] >= 0:
        callScope.defineFreshCallSlot(proto.namedSlots[pIndex], value)
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
      if not (typeExpr.isBareIntType and value.kind == vkInt):
        boundValue = adaptBoundary("parameter '" & positional[i] & "'",
                                   typeExpr, value, callScope)
    if i < proto.positionalSlots.len and proto.positionalSlots[i] >= 0:
      callScope.defineFreshCallSlot(proto.positionalSlots[i], boundValue)
    else:
      callScope.define(positional[i], boundValue)
    if declaredType.kind != vkNil:
      callScope.declareType(positional[i], declaredType)
  if proto.restParam.len > 0:
    var rest = newSeq[Value](args.len - positional.len)
    for i in 0 ..< rest.len:
      rest[i] = args[positional.len + i]
    if proto.restSlot >= 0:
      callScope.defineFreshCallSlot(proto.restSlot, newList(rest))
    else:
      callScope.define(proto.restParam, newList(rest))
  for pIndex, p in proto.namedParams:
    if named.argIndex(p.arg) < 0:
      if p.defaultValue.optional:
        var value = p.defaultValue.defaultValue(callScope)
        var declaredType = NIL
        if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
          let typeExpr = instantiateTypeExpr(p.typeExpr, typeBindings,
                                             proto.typeParams)
          declaredType = typeExpr
          if not (typeExpr.isBareIntType and value.kind == vkInt):
            value = adaptBoundary("parameter '" & p.local & "'", typeExpr,
                                  value, callScope)
        if pIndex < proto.namedSlots.len and proto.namedSlots[pIndex] >= 0:
          callScope.defineFreshCallSlot(proto.namedSlots[pIndex], value)
        else:
          callScope.define(p.local, value)
        if declaredType.kind != vkNil:
          callScope.declareType(p.local, declaredType)
      else:
        raise newException(GeneError,
          "function '" & callee.fnName & "' missing named argument: " & p.arg)
  var rt = NIL
  if proto.hasReturnType:
    rt = instantiateTypeExpr(proto.returnType, typeBindings, proto.typeParams)
  (callScope, rt)

proc applyCall(callee: Value, args: openArray[Value], named: NamedArgs,
               dispatchScope: Scope = nil, site: Value = NIL): Value =
  case callee.kind
  of vkNativeFn:
    if named.len == 0 and args.len == 2:
      let fast = tryFastNative2(callee, args[0], args[1])
      if fast.handled:
        return fast.value
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
                          namedValues: named.toSeq(),
                          dispatchScope: dispatchScope,
                          site: site)
    callImpl(args, addr call)
  of vkFfiCallable:
    applyFfiCallable(callee, args, named)
  of vkFunction:
    let positional = callee.fnParams
    let code = callee.fnCode
    if code == nil or not (code of FunctionProto):
      raise newException(GeneError, "function has no VM code")
    let proto = FunctionProto(code)
    let native = applyNativeCompiled(callee, proto, args, named)
    if native.handled:
      return native.value
    if proto.simpleCall and named.len == 0:
      if args.len != positional.len:
        raise newException(GeneError,
          "function '" & callee.fnName & "' expects " & $proto.requiredPositional &
          ".." & $positional.len &
          " argument(s), got " & $args.len)
      let callScope =
        if proto.needsCallScope:
          let created =
            if proto.poolCallScope:
              acquireSimpleCallScope(callee.fnScope, proto.localNames,
                proto.callScopeNeedsSlotNames,
                proto.callScopeNeedsSlotReset)
            else:
              let fresh = newScope(callee.fnScope)
              fresh.prepareSlots(proto.localNames)
              fresh
          if args.len > 0:
            created.bindSimpleCallSlots(proto, args)
          created
        else:
          callee.fnScope
      try:
        return runPooled(proto.chunk, callScope,
                         validateImplRequirements = proto.needsCallScope)
      finally:
        if proto.poolCallScope:
          releaseCallScope(callScope)
    let (callScope, returnType) = bindCallScope(callee, proto, args, named)
    let frameReturnType = proto.checkedFrameReturnType(returnType)
    if proto.isGenerator:
      var resultValue = newGeneratorStream(proto, callScope, pullGeneratorStream)
      if frameReturnType.kind != vkNil:
        resultValue = adaptBoundary("return from '" & callee.fnName & "'",
                                    frameReturnType, resultValue, callScope)
      return resultValue
    try:
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
      if frameReturnType.kind != vkNil:
        resultValue = adaptBoundary("return from '" & callee.fnName & "'",
                                    frameReturnType, resultValue, callScope)
      resultValue
    finally:
      if proto.poolCallScope:
        releaseCallScope(callScope)
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
    applyCall(implFn, args, named, dispatchScope, site)
  of vkNode:
    if not callee.isSelector:
      if callee.valueImplementsCallable(dispatchScope):
        return applyUserCallable(callee, args, named, dispatchScope, site)
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

proc call*(callee: Value, args: seq[Value], namedNames: seq[string],
           namedValues: seq[Value], dispatchScope: Scope = nil,
           site: Value = NIL): Value =
  if namedNames.len != namedValues.len:
    raise newException(GeneError, "native call named argument mismatch")
  applyCall(callee, args, NamedArgs(names: namedNames, values: namedValues),
            dispatchScope, site)

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
