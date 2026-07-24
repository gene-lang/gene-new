## Stack VM for compiled Gene GIR chunks.

import std/[algorithm, base64, dynlib, json, locks, math, monotimes, net, os,
            osproc, sets, strutils, tables, times, unicode]
import ./[compiler, diagnostics, equality, fmt, gir, logging, printer, reader,
          types]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import ./tui/terminal as tui_terminal
  import ./[pty_process, terminal_session, vterm]

when not defined(geneWasm):
  import std/re as nre

when not defined(emscripten) and not defined(geneWasm):
  import std/sysrand

when compileOption("threads") and defined(gcAtomicArc):
  import std/cpuinfo

when defined(posix):
  import std/posix
else:
  import std/streams

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  # Readiness-driven event loop for the stdlib net/http server (stdlib.nim).
  import std/selectors

when sizeof(csize_t) == sizeof(clong):
  type GeneCPtrDiff = clong
else:
  type GeneCPtrDiff = clonglong

type
  ReplReadLine* = proc(line: var string): bool {.closure.}
  ReplWrite* = proc(text: string) {.closure.}
  ReplOptions* = object
    interactive*: bool
    prompt*: string

# Pre-interned PropTable key ids for the computed Node projection names on
# the selector hot path (design §5 static lookup). Interned lazily on first
# use: module-init-time interning crashes under Emscripten (wasm32) where
# NimMain's global-init ordering interacts badly with the table allocator.
var
  nodeHeadKeyId = int32(-2)
  nodePropsKeyId = int32(-2)
  nodeBodyKeyId = int32(-2)
  nodeMetaKeyId = int32(-2)

proc ensureNodeProjectionKeyIds() {.inline.} =
  if nodeHeadKeyId == -2:
    nodeHeadKeyId = propKeyId("head")
    nodePropsKeyId = propKeyId("props")
    nodeBodyKeyId = propKeyId("body")
    nodeMetaKeyId = propKeyId("meta")

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import std/volatile

  # Interactive-repl SIGINT support. The handler is installed only for the
  # duration of an interactive runReplSession; outside that window these
  # globals stay false and the dispatch-loop check never fires.
  const
    replPhaseIdle = 0'i32
    replPhaseReading = 1'i32
    replPhaseEvaluating = 2'i32
  var gVmInterrupt: bool          # armed by SIGINT while a repl eval runs
  var gReplSigPhase: int32 = replPhaseIdle
  var gReplPromptBuf: array[64, char]
  var gReplPromptLen = 0

  proc replSigintHandler(sig: cint) {.noconv.} =
    case volatileLoad(addr gReplSigPhase)
    of replPhaseReading:
      # The tty's ISIG already flushed the partially-typed line; give visual
      # feedback with a fresh prompt. Only async-signal-safe write() here.
      var nl = '\n'
      discard posix.write(STDOUT_FILENO, addr nl, 1)
      if gReplPromptLen > 0:
        discard posix.write(STDOUT_FILENO, addr gReplPromptBuf[0],
                            gReplPromptLen)
    of replPhaseEvaluating:
      volatileStore(addr gVmInterrupt, true)
    else:
      discard

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

  GeneReturn = object of CatchableError
    value: Value
    targetDepth: int

  FrameKind = enum
    fkNormal
    fkTryBody
    fkCatchBody
    fkEnsureValueBody
    fkEnsureErrorBody
    fkEnsurePanicBody
    fkEnsureCancelBody
    fkEnsureReturnBody
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
    pendingReturn: ref GeneReturn
    forItems: seq[Value]
    forIndex: int
    forStream: Value
    forPattern: Value
    forBody: Chunk
    ownedScope: Scope
    namespaceName: string

  ## A suspended caller frame on the VM's explicit call-frame stack. Simple Gene
  ## function calls push one of these instead of recursing through Nim, so a call
  ## chain lives on the heap — the foundation for suspendable/resumable tasks
  ## (design §13/§17). Frames share one operand stack: each records where its
  ## region starts (stackBase) and returns truncate back to it.
  Frame = object
    chunk: Chunk
    scope: Scope
    recycleScope: bool
    stackBase: int          # this frame's region of the shared operand stack
                            # starts here; values below belong to callers
    ip: int
    validateImpls: bool
    returnType: Value       # instantiated return-type to adapt on return, or NIL
    returnLabel: string     # "return from '<fn>'" label for the adaptation error
    returnDepth: int        # frame-stack depth of this function's caller
    checksErrors: bool      # this frame is an ^errors function (translate on throw)
    errorTypes: seq[Value]  # declared error rows, when checksErrors
    fnName {.cursor.}: string # function name, for the undeclared-error message;
                            # borrowed from the proto owned by this frame's chunk
    kind: FrameKind         # current-frame completion behavior
    extra: FrameExtra       # rare state for try/ensure/for/task/ns frames
    restoreSlot: int        # same-scope recur frame restores this local slot
    restoreValue: Value

  TailTraceFrame = object
    chunk: Chunk
    ip: int
    fnName: string
    frameDepth: int

  TryHandler = object
    ## An active `try` region on the VM's handler stack. The try body runs as a
    ## Frame (so deep recursion through try-wrapped code stays on the heap); this
    ## record lets the dispatch loop's exception handler find the catch clauses
    ## and ensure block when an error unwinds back to `framesLen`.
    tp: TryProto
    scope: Scope            # enclosing scope, for catch matching and ensure
    framesLen: int          # frames.len at try entry; the handler fires when an
                            # unwinding error pops back to this depth
    stackLen: int           # shared-operand-stack length at try entry; unwinding
                            # truncates back to it before running catch clauses

  Fiber = ref object of RootObj
    ## A suspendable Gene task: the full runLoop continuation captured on the heap.
    ## A fresh fiber carries just chunk/scope (started = false); once it suspends,
    ## every register, the operand stack, and the frame/handler stacks are saved
    ## here so the scheduler can resume it later. `task` is the (Task T E) value it
    ## settles; `waitChannel`/`waitIsSend` record what it is parked on.
    chunk: Chunk
    scope: Scope
    recycleScope: bool
    stack: seq[Value]       # the whole shared operand stack at suspend
    stackBase: int          # current frame's base within it
    ip: int
    frames: seq[Frame]
    tailTraceFrames: seq[TailTraceFrame]
    handlers: seq[TryHandler]
    validateImpls: bool
    returnType: Value
    returnLabel: string
    returnDepth: int
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
    pendingReturn: ref GeneReturn
    forItems: seq[Value]
    forIndex: int
    forStream: Value
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

  SupervisorFailureRetry = object
    sink: Value
    event: Value
    scope: Scope

  AsyncIoKind = enum
    aioReadText
    aioWriteText
    aioTcpReadText
    aioTcpWriteText

  AsyncIoEnqueueResult = enum
    aioUnavailable
    aioQueued
    aioQueueFull

  AsyncIoRequest = ref object
    kind: AsyncIoKind
    path: string
    text: string
    host: string
    port: int
    maxBytes: int
    timeoutMs: int
    task: Value

  CaptureSafetyMode = enum
    csmSend
    csmWorker

  SchedulerState = ref object of RuntimeContext
    lock: Lock
    runQueue: seq[Fiber]
    waiters: seq[Fiber]
    askTimeouts: seq[AskTimeout]
    supervisorRetries: seq[SupervisorFailureRetry]
    supervisorRetryHead: int
    supervisorRetryDrops: uint64
    supervisorRetryHighWater: int
    supervisorDrainActive: bool
    when compileOption("threads") and defined(gcAtomicArc):
      workers: seq[Thread[SchedulerWorkerContext]]
      workerContexts: seq[SchedulerWorkerContext]
      workersStarted: bool
      workerLeaseCount: int
      workerStop: bool
      workerCond: Cond
      activeWorkerFibers: seq[Fiber]
      asyncIoQueue: seq[AsyncIoRequest]
      asyncIoHead: int
      activeAsyncIoWorkers: int

  SchedulerWorkerContext = ref object of RuntimeContext
    scheduler: SchedulerState
    slot: int

  SchedulerWorkerLease = object
    scheduler: SchedulerState
    active: bool

  ModuleCompileHeader = ref object
    unit: SourceUnit
    compileInterface: CompileNamespaceInterface

  ModuleCompileArtifact = ref object
    chunk: Chunk
    macroExports: Table[string, MacroDef]
    syntaxFnExports: seq[string]
    compileInterface: CompileNamespaceInterface

  Application* = ref object of RuntimeContext
    builtins: Scope
    # The whole standard library, i.e. the scope behind the `gene` namespace.
    # `builtins` is only the *lexical* root, which deliberately exposes almost
    # nothing (design §2.1): user code reaches the library as `gene/x` / `$x`.
    # Internal resolution — built-in type messages, error types raised by the
    # VM — goes through here so it does not depend on the bare surface.
    stdlib: Scope
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
    moduleCompileHeaders: Table[string, ModuleCompileHeader]
    moduleCompileArtifacts: Table[string, ModuleCompileArtifact]
    moduleCompileLoading: HashSet[string]
    implEpoch: uint64
    implScopeIndex: Table[tuple[receiver, message: uint64], seq[Scope]]
    baseScopes: seq[Scope] # enumerable module/program bases for reload checks
    currentModuleDir: string
    packageRoot: string
    # Experimental URL module sources (design §15.9). Enabled only by the
    # `gene runurl` entry; when off, URL module paths are rejected at
    # resolution time. Fetched sources are cached per run so compile-time
    # macro discovery and runtime initialization fetch each URL at most once.
    allowUrlModules*: bool
    urlSources: Table[string, tuple[finalUrl, body: string]]
    # serde stage 3+ reverse origin index: definition value bits ->
    # (module rel-path, internal path). Built lazily on first serde/write that
    # needs a ref, so module load pays nothing when serde is unused. Read never
    # touches it (it resolves directly against builtins + moduleCache).
    serdeOrigins: Table[uint64, tuple[module, path: string]]
    # Module-level typed-instance bindings, for SerdeRef identity value refs
    # (stage 6). Only heap instances are recorded, so bits never collide with
    # inline scalars.
    serdeValueOrigins: Table[uint64, tuple[module, path: string]]
    serdeOriginBuiltinsDone: bool
    serdeOriginModules: HashSet[string]

# Current threaded scheduler queues are lock-protected seqs shared with worker
# threads. Reserve enough room up front so worker parking/enqueue paths do not
# force cross-thread seq reallocation in the experimental M:N lane.
const schedulerSharedQueueInitialCap = 65536
const supervisorFailureRetryCapacity = 64

proc raiseTypeError(where, expected: string, value: Value, scope: Scope)
proc raiseCallKindError(where, expected, actual: string, value: Value,
                        scope: Scope)
proc raiseMessageError(message, receiverType: string, scope: Scope,
                       lexicalHint = false, protocol = "",
                       missingImpl = false)
proc rejectCallerEnvEscape(where: string, value: Value) {.noinline.}
proc matchesTypeExpr(expr, value: Value, scope: Scope): bool
proc adaptBoundary(where: string, typeExpr, value: Value, scope: Scope): Value
proc closeTypeExpr(expr: Value, scope: Scope): Value
proc snapshotProtocolBindings(scope: Scope): seq[Value]
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
proc application*(scope: Scope): Application
proc builtinsScope*(app: Application): Scope
proc builtinsScope*(): Scope
proc resolveModulePath*(app: Application, rawPath: string): string

proc builtinTypeBinding(scope: Scope, name: string, value: var Value): bool =
  ## Resolve a standard-library type the VM raises or checks against (`Error`,
  ## `TypeError`, `Send`, ...). These come from the `gene` scope rather than the
  ## lexical chain: nothing is pre-bound bare (design §2.1), and a local binding
  ## of the same name must not change which type an internal raise constructs.
  value = builtinBinding(scope, name)
  value.kind != vkNil

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
var activeWorkerThread {.threadvar.}: bool
var activeConstructionDepth {.threadvar.}: int

proc currentScheduler(): SchedulerState

template withSchedulerLock(s: SchedulerState, body: untyped): untyped =
  acquire(s.lock)
  try:
    body
  finally:
    release(s.lock)

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
# Explicit-scheduler variants for foreign threads that must not touch the
# scheduler ref's (non-atomic) refcount: callers hold the SchedulerState via a
# raw pointer + {.cursor.} cast (the Application keeps it alive for the
# process lifetime).
proc wakeChannelWaitersIn(s: SchedulerState, channel: Value, wakeSenders: bool)
proc wakeAllChannelWaitersIn(s: SchedulerState, channel: Value,
                             wakeSenders: bool)
proc wakeTaskWaitersIn(s: SchedulerState, task: Value)
proc enqueueRunnable(f: Fiber)
proc drainSupervisorFailures()

# Wake fibers parked in `await` on a task that has just settled.
proc wakeTaskWaiters(task: Value)

when compileOption("threads"):
  import std/atomics

  # In-flight native operations running on dedicated OS threads that will
  # settle a Task or feed a Channel (os/exec-*-async, future libcurl client).
  # Root-level blocking waits consult this before declaring deadlock: an
  # external thread can still unblock them, so they poll instead of raising.
  var externalNativeOps: Atomic[int]

  proc beginExternalNativeOp() =
    discard externalNativeOps.fetchAdd(1, moRelease)

  proc endExternalNativeOp() =
    discard externalNativeOps.fetchSub(1, moRelease)

  proc externalNativeOpsPending(): bool =
    externalNativeOps.load(moAcquire) > 0
else:
  # Without OS threads (wasm, --threads:off) the dedicated-thread native ops
  # that feed this counter are compiled out, so nothing is ever pending.
  proc externalNativeOpsPending(): bool {.inline.} =
    false

# Schedule a task's own fiber to observe a cancellation request. Awaiters are
# woken when that fiber finishes cleanup and settles the task as cancelled.
proc cancelScheduledTask(task: Value): bool

# Run one runnable fiber to its next park/completion; false if none are runnable.
# Lets a blocking root-level channel op cooperatively pump the scheduler.
proc schedulerRunOne(skipWorkerSafe = false): bool
# Non-sleeping scheduler probes for the net/http event loop (stdlib.nim): it
# must pump ready fibers and honor timer deadlines without ever letting
# schedulerRunOne sleep past socket readiness.
proc hasRunnableFiber(): bool
proc wakeExpiredTimers(now = getMonoTime()): bool
proc nextTimerDeadline(): tuple[has: bool, deadline: MonoTime]
proc schedulerRunOneUntil(deadline: MonoTime, skipWorkerSafe = false): bool
proc beginSchedulerWorkerLease(): SchedulerWorkerLease
proc endSchedulerWorkerLease(lease: SchedulerWorkerLease)
proc schedulerRunOneRoot(lease: SchedulerWorkerLease): bool
proc schedulerRunOneRootUntil(deadline: MonoTime,
                              lease: SchedulerWorkerLease): bool
proc enqueueAsyncReadText(path: string, task: Value): AsyncIoEnqueueResult
proc enqueueAsyncWriteText(path, text: string,
                           task: Value): AsyncIoEnqueueResult
proc enqueueAsyncTcpReadText(host: string, port, maxBytes, timeoutMs: int,
                             task: Value): AsyncIoEnqueueResult
proc enqueueAsyncTcpWriteText(host: string, port: int, text: string,
                              timeoutMs: int,
                              task: Value): AsyncIoEnqueueResult
proc timerDeadline(milliseconds: int64): MonoTime
proc scheduleAskTimeout(task, reply: Value, scope: Scope, timeoutMs: int64)

# Drive the scheduler until the given task settles, or raise on deadlock.
proc pumpUntilDone(task: Value)
proc pollHttpClientCompletions()
proc pollCursesInputCompletions()
proc pollOsExecAsyncCompletions()

# Actor message processing runs each handler as a scheduler fiber. scheduleActor
# enqueues the next message's handler fiber if the actor is idle; driveActor pumps
# the scheduler until the actor is idle (used by root send/ask to stay synchronous);
# wakeActorSenders wakes a fiber parked on a previously-full mailbox.
proc scheduleActor(actor: Value, scope: Scope)
proc driveActor(actor: Value)
proc closeActorAndCancelMailbox(actor: Value)
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
  Scope(application: owner, parent: parent, evalBudget: budget,
        borrowedCallerEnv: parent != nil and parent.borrowedCallerEnv)

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
  try:
    for i in 0 ..< scope.ownedTasks.len:
      let task = scope.ownedTasks[i]
      if task.kind == vkTask and not task.taskDone:
        pumpUntilDone(task)
  except CatchableError:
    scope.cancelOwnedTasks()
    raise
  finally:
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

proc actorOwnerRestartLimits(scope: Scope): tuple[maxRestarts, windowMs: int] =
  var s = scope
  while s != nil:
    if s.ownsActors:
      return (s.actorMaxRestarts, s.actorRestartWindowMs)
    s = s.parent
  (0, 0)

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

proc parentActorOwnerFailureEvents(scope: Scope): Value =
  var s = scope
  var foundOwner = false
  while s != nil:
    if s.ownsActors:
      if foundOwner:
        return s.supervisorEvents
      foundOwner = true
    s = s.parent
  NIL

proc parentActorOwnerFailureDeadLetters(scope: Scope): Value =
  var s = scope
  var foundOwner = false
  while s != nil:
    if s.ownsActors:
      if foundOwner:
        return s.supervisorDeadLetters
      foundOwner = true
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
  if not scope.entryProtocolsFrozen:
    if scope.moduleRoot or scope.implOverlayRoot:
      scope.entryProtocols = snapshotProtocolBindings(scope.parent)
    elif scope.parent != nil:
      scope.entryProtocols = scope.parent.entryProtocols
    scope.entryProtocolsFrozen = true
  if scope.slots.len == 0 and chunk.localNames.len > 0:
    scope.prepareSlots(chunk.localNames, mirror = chunk.mirrorSlots)
  for name in chunk.exportExcludedNames:
    scope.exportExcludedNames.incl name

proc protocolBindingSig(scope: Scope): int =
  ## Cheap O(chain-depth) signature of how many bindings could contribute
  ## protocol identities. Only the count changes when a binding is added, so
  ## an unchanged count lets refreshCompiledUnitEntry reuse the prior snapshot
  ## instead of re-walking every binding (the reused-scope hot path). This is
  ## sound only because module/REPL root scopes are append-only within a
  ## session: a binding is never deleted or rebound, so equal counts imply an
  ## unchanged binding set. A future unbind would have to invalidate the sig.
  var current = scope
  while current != nil:
    result += current.slotNames.len + current.vars.len
    current = current.parent

proc refreshCompiledUnitEntry(scope: Scope) =
  ## File/program roots normally execute once; eval/REPL roots execute many
  ## independently compiled units. Snapshot all bindings already committed in
  ## this scope before each such unit, without changing older function values.
  ## Repeated runs of one compiled chunk on the same scope (no new bindings)
  ## reuse the frozen snapshot rather than re-walking the whole scope chain.
  if scope.moduleRoot or scope.implOverlayRoot:
    let sig = scope.protocolBindingSig()
    if scope.entryProtocolsFrozen and scope.entrySnapshotSig == sig:
      return
    scope.entryProtocols = snapshotProtocolBindings(scope)
    scope.entryProtocolsFrozen = true
    scope.entrySnapshotSig = sig

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

proc materializeMirroredVars*(scope: Scope) =
  ## Mirrored scopes (module/eval top level, ns bodies) defer the vars-hash
  ## copy of slot writes: storeSlot only flips varsDirty, and every reader
  ## of `.vars` on a possibly-mirrored scope must call this first. Name
  ## lookups (lookup/assign/define and their variants) are exempt — they
  ## consult slots before vars, so a stale or missing mirror entry is
  ## always shadowed. Iterating or name-keyed readers are not.
  if not scope.varsDirty:
    return
  scope.varsDirty = false
  for i, name in scope.slotNames:
    if name.len > 0 and scope.slotDefined(i):
      scope.vars[name] = scope.slots[i]

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

proc raiseUndefinedSymbol(name: string) {.noReturn.} =
  var error = newException(GeneError, "undefined symbol: " & name)
  error.errorKind = gekUndefinedSymbol
  error.errorDetail = name
  raise error

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
    # Deferred mirror: top-level loops set slots far more often than anything
    # reads .vars; materializeMirroredVars settles the hash on demand.
    scope.varsDirty = true
  scope.markSlotDefined(index)

proc scopeAtDepth(scope: Scope, depth: int, name: string): Scope =
  result = scope
  for _ in 0 ..< depth:
    if result == nil:
      raiseUndefinedSymbol(name)
    result = result.parent
  if result == nil:
    raiseUndefinedSymbol(name)

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
    raiseUndefinedSymbol(name)
  scope.slots[index]

proc loadSlotAt(scope: Scope, depth, index: int, name: string): Value =
  scope.scopeAtDepth(depth, name).loadSlot(index, name)

proc defineSlot(scope: Scope, index: int, name: string, v: Value) =
  # vars is empty in plain (non-mirrored) slot scopes — the common case for
  # every (var ...) in a function body — and hasKey hashes the name before
  # noticing that. Slot-level duplicates are storeSlot's check.
  if scope.vars.len > 0 and scope.vars.hasKey(name):
    raise newException(GeneError, "duplicate binding: " & name)
  scope.storeSlot(index, name, v, requireExisting = false)

proc defineFreshCallSlot(scope: Scope, index: int, v: Value) {.inline.} =
  scope.slots[index] = functionForScopeStorage(v, scope)
  scope.markSlotDefined(index)

proc assignSlot(scope: Scope, index: int, name: string, v: Value) =
  # Fast path for the common set: defined untyped slot storing an unmanaged
  # value — skips the duplicate/undefined checks, type adaptation, and
  # functionForScopeStorage that storeSlot must consider. Kept out of the
  # dispatch loop so the opSetLocal handler stays compact. Mirrored scopes
  # qualify since the mirror write is now a deferred dirty-flag flip.
  if index >= 0 and index < scope.slots.len and scope.slotDefined(index) and
      scope.slotTypes.len == 0 and not v.isHeapBacked:
    scope.slots[index] = v
    if scope.slotMirror:
      scope.varsDirty = true
    return
  scope.storeSlot(index, name, v, requireExisting = true)

proc assignSlotAt(scope: Scope, depth, index: int, name: string, v: Value) =
  scope.scopeAtDepth(depth, name).assignSlot(index, name, v)

proc lookup*(scope: Scope, name: string): Value =
  var s = scope
  while s != nil:
    let slot = s.slotIndex(name)
    if slot >= 0:
      if s.slotDefined(slot):
        return s.slots[slot]
      raiseUndefinedSymbol(name)
    s.vars.withValue(name, value):
      return value[]
    s.wildcardFallbacks.withValue(name, fallback):
      if fallback[].parentCollision or fallback[].conflicts.len > 0:
        var sources = @[fallback[].source]
        for source in fallback[].conflicts:
          sources.add source
        if fallback[].parentCollision:
          sources.add "gene/prelude"
        raise newException(GeneError,
          "ambiguous imported name '" & name & "' from " & sources.join(", "))
      return fallback[].value
    s = s.parent
  raiseUndefinedSymbol(name)

proc lookupOptional*(scope: Scope, name: string, value: var Value): bool =
  var s = scope
  while s != nil:
    let slot = s.slotIndex(name)
    if slot >= 0:
      if s.slotDefined(slot):
        value = s.slots[slot]
        return true
      return false
    s.vars.withValue(name, found):
      value = found[]
      return true
    s.wildcardFallbacks.withValue(name, fallback):
      if fallback[].parentCollision or fallback[].conflicts.len > 0:
        var sources = @[fallback[].source]
        for source in fallback[].conflicts:
          sources.add source
        if fallback[].parentCollision:
          sources.add "gene/prelude"
        raise newException(GeneError,
          "ambiguous imported name '" & name & "' from " & sources.join(", "))
      value = fallback[].value
      return true
    s = s.parent
  false

proc nameResolvable(scope: Scope, name: string): bool =
  ## Presence probe that mirrors `lookupOptional`'s reachability without
  ## evaluating ambiguity — a parent whose own wildcard fallback is already
  ## ambiguous still *has* the name, so it must read as a collision here
  ## rather than raise (which would turn lazy import ambiguity into an eager
  ## import-time error in the nested case).
  var s = scope
  while s != nil:
    let slot = s.slotIndex(name)
    if slot >= 0:
      return s.slotDefined(slot)
    if s.vars.hasKey(name):
      return true
    if s.wildcardFallbacks.hasKey(name):
      return true
    s = s.parent
  false

proc addWildcardFallback(scope: Scope, name: string, value: Value,
                         source: string) =
  scope.wildcardFallbacks.withValue(name, existing):
    if source != existing[].source and source notin existing[].conflicts:
      existing[].conflicts.add source
    return
  do:
    let parentCollision = scope.parent != nil and
      scope.parent.nameResolvable(name)
    scope.wildcardFallbacks[name] = WildcardFallback(
      value: value, source: source, parentCollision: parentCollision)

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
    if s.wildcardFallbacks.hasKey(name):
      raise newException(GeneError,
        "cannot assign wildcard import '" & name &
        "'; import it explicitly before assignment")
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

proc rejectSyntaxCallWithoutSite(callee: Value) {.noreturn.} =
  ## Host/native calls do not carry the raw source envelope required by fn!.
  raise newException(GeneError,
    "fn! '" & callee.fnName & "' requires a source call site")

proc rejectSyntaxSend(callee: Value, scope: Scope) {.noreturn.} =
  raiseCallKindError("message send", "Callable", "SyntaxCallable", callee,
                     scope)

proc rejectMessageCall(callee: Value, scope: Scope) {.noreturn.} =
  ## `~` is the only way to invoke a message (design §3): a message identity is
  ## not callable in head position, so `(P/m x)` is a CallKindError. Qualified
  ## sends resolve the impl through `opResolveQualifiedMessage`, so an ordinary
  ## call never legitimately holds a message value here.
  raiseCallKindError("call", "Callable", "Message", callee, scope)

proc applyCall(callee: Value, args: openArray[Value], named: NamedArgs,
               dispatchScope: Scope = nil, site: Value = NIL,
               loc = SourceLoc()): Value
proc constructTypedInstance(callee: Value, args: openArray[Value],
                            named: NamedArgs): Value
proc constructWithCtor(callee: Value, args: openArray[Value], named: NamedArgs,
                       dispatchScope: Scope = nil, site: Value = NIL): Value
proc applySyntaxCall(callee: Value, callNode: Value, callerScope: Scope): Value
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

proc scopelessIntArgsOk(stack: seq[Value], argsStart, argCount: int):
    bool {.noinline.} =
  ## Typed scopeless admission requires every positional param to be bare
  ## Int, so binding-time adaptation reduces to this kind sweep over the
  ## already-pushed args. A miss falls back to the classic convention,
  ## whose binding raises the canonical parameter type error. noinline:
  ## untyped calls short-circuit before the call, and expanding the loop
  ## at two dispatch sites is the documented I-cache trap. The sweep, not
  ## the compile-time flag, carries the win at the generic evaluated-head
  ## site — runtime-defined callees compile without arg proofs.
  for i in 0 ..< argCount:
    if stack[argsStart + i].kind != vkInt:
      return false
  true

proc isSymbol(v: Value, name: string): bool =
  v.kind == vkSymbol and v.symVal == name

proc isSelector(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("select")

proc isSelectorKeySegment(v: Value): bool =
  v.kind == vkNode and v.head.isSymbol("selector_key") and v.body.len == 1

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

proc biRem(args: openArray[Value]): Value {.nimcall.} =
  ## Truncated remainder (`rem`), design §7.4: `mod` names the
  ## module form and `%` is the unquote prefix, so modulo is the identifier
  ## `rem`. Truncates toward zero to match `/`.
  requireNums("rem", args)
  if args.len != 2:
    raise newException(GeneError, "rem expects exactly 2 arguments")
  let a = args[0]
  let b = args[1]
  if a.kind == vkInt and b.kind == vkInt:
    if b.intIsZero: raise newException(GeneError, "division by zero")
    # a - (a div b) * b, truncating; reuses overflow-safe Value ops.
    return intSub(a, intMul(intDiv(a, b), b))
  let bf = b.toFloat
  if bf == 0.0: raise newException(GeneError, "division by zero")
  newFloat(a.toFloat mod bf)

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

proc biNe(args: openArray[Value]): Value {.nimcall.} =
  ## (!= a b ...) — exactly (! (== a b ...)).
  for i in 1 ..< args.len:
    if not equal(args[i-1], args[i]): return TRUE
  FALSE

proc biContains(args: openArray[Value]): Value {.nimcall.} =
  ## (xs ~ contains? x) — structural-equality membership for List and Set
  ## receivers (design §1.5: membership follows ==). Maps are deliberately
  ## unsupported: key-vs-value membership would be ambiguous.
  if args.len != 2:
    raise newException(GeneError,
      "contains? expects (collection, item), got " & $args.len & " arguments")
  case args[0].kind
  of vkList:
    for item in args[0].listItems:
      if equal(item, args[1]): return TRUE
    FALSE
  of vkSet:
    for item in args[0].setItems:
      if equal(item, args[1]): return TRUE
    FALSE
  else:
    raise newException(GeneError,
      "contains? expects a List or Set, got " & $args[0].kind)

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

proc findEqualValue(items: openArray[Value], key: Value): int =
  for i, item in items:
    if equal(item, key):
      return i
  -1

proc findHashMapKey(entries: openArray[HashMapEntry], key: Value): int =
  for i, entry in entries:
    if equal(entry.key, key):
      return i
  -1

proc requireHashStableKey(name: string, key: Value) =
  if not isHashStable(key):
    raiseTypeError(name, "HashStable", key, nil)

proc buildSet(name: string, values: openArray[Value]): Value =
  var items: seq[Value]
  for value in values:
    requireHashStableKey(name, value)
    if findEqualValue(items, value) < 0:
      items.add value
  newSet(items)

proc buildHashMap(name: string, pairs: openArray[HashMapEntry]): Value =
  var entries: seq[HashMapEntry]
  for entry in pairs:
    requireHashStableKey(name, entry.key)
    let idx = findHashMapKey(entries, entry.key)
    if entry.val.kind == vkVoid:
      if idx >= 0:
        entries.delete(idx)
    elif idx >= 0:
      entries[idx].val = entry.val
    else:
      entries.add entry
  newHashMap(entries)

proc biNot(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 1: raise newException(GeneError, "not expects 1 argument")
  newBool(not isTruthy(args[0]))

proc requireOne(name: string, args: openArray[Value]) =
  if args.len != 1:
    raise newException(GeneError, name & " expects 1 argument, got " & $args.len)

# Absence vocabulary (design §1.6). `nil?`/`void?` test the exact singleton;
# `absent?` is either absence form; `present?` is neither. `false`/`0`/`""`
# are present — this is the distinction `||`-as-default blurs and `??` respects.
proc biIsNil(args: openArray[Value]): Value {.nimcall.} =
  requireOne("nil?", args)
  newBool(args[0].kind == vkNil)

proc biIsVoid(args: openArray[Value]): Value {.nimcall.} =
  requireOne("void?", args)
  newBool(args[0].kind == vkVoid)

proc biIsAbsent(args: openArray[Value]): Value {.nimcall.} =
  requireOne("absent?", args)
  newBool(args[0].isAbsent)

proc biIsPresent(args: openArray[Value]): Value {.nimcall.} =
  requireOne("present?", args)
  newBool(not args[0].isAbsent)

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
  rejectCallerEnvEscape("cell construction", args[0])
  newCell(args[0])

proc biCellGet(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Cell/get", args)
  requireCell("Cell/get", args[0])
  args[0].cellValue

proc biCellSet(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Cell/set expects 2 arguments, got " & $args.len)
  requireCell("Cell/set", args[0])
  rejectCallerEnvEscape("Cell/set", args[1])
  args[0].setCellValue(args[1])
  args[1]

proc biCellSwap(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Cell/swap expects 2 arguments, got " & $args.len)
  requireCell("Cell/swap", args[0])
  rejectCallerEnvEscape("Cell/swap", args[1])
  let old = args[0].cellValue
  args[0].setCellValue(args[1])
  old

proc biCellUpdate(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Cell/update expects 2 arguments, got " & $args.len)
  requireCell("Cell/update", args[0])
  var callArgs = [args[0].cellValue]
  let next = applyCall(args[1], callArgs, NamedArgs())
  rejectCallerEnvEscape("Cell/update", next)
  args[0].setCellValue(next)
  next

proc requireAtomicCell(name: string, value: Value) =
  if value.kind != vkAtomicCell:
    raise newException(GeneError, name & " expects an AtomicCell")

proc biAtomicCell(args: openArray[Value]): Value {.nimcall.} =
  requireOne("atomic_cell", args)
  rejectCallerEnvEscape("atomic_cell construction", args[0])
  newAtomicCell(args[0])

proc biAtomicCellLoad(args: openArray[Value]): Value {.nimcall.} =
  requireOne("AtomicCell/load", args)
  requireAtomicCell("AtomicCell/load", args[0])
  args[0].atomicCellValue

proc biAtomicCellStore(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "AtomicCell/store expects 2 arguments, got " & $args.len)
  requireAtomicCell("AtomicCell/store", args[0])
  rejectCallerEnvEscape("AtomicCell/store", args[1])
  args[0].setAtomicCellValue(args[1])
  args[1]

proc biAtomicCellSwap(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "AtomicCell/swap expects 2 arguments, got " & $args.len)
  requireAtomicCell("AtomicCell/swap", args[0])
  rejectCallerEnvEscape("AtomicCell/swap", args[1])
  # Single locked critical section (not load-then-store), so a concurrent
  # writer can't interleave between reading the old value and writing the new
  # one (design Section 12.3: AtomicCell operations are linearizable).
  atomicCellSwap(args[0], args[1])

proc biAtomicCellCompareExchange(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "AtomicCell/compare_exchange expects 3 arguments, got " & $args.len)
  requireAtomicCell("AtomicCell/compare_exchange", args[0])
  rejectCallerEnvEscape("AtomicCell/compare_exchange", args[2])
  # Compare and swap happen under one lock acquisition, avoiding the
  # check-then-set race a separate load+same?+store would have.
  if atomicCellCompareExchange(args[0], args[1], args[2], same):
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
  var props = initPropTable()
  props["message"] = newStr("channel is closed")
  var head = newSym("ChannelClosed")
  var closedType: Value
  if builtinTypeBinding(scope, "ChannelClosed", closedType) and
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
  let scope = if call == nil: nil else: call[].dispatchScope
  var workerLease: SchedulerWorkerLease
  var workerLeaseOpen = false
  defer:
    if workerLeaseOpen:
      endSchedulerWorkerLease(workerLease)
  while true:
    let state = args[0].channelSendState()
    if state.closed:
      raiseChannelClosed(scope)
    if state.full:
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
      wakeChannelWaiters(args[0], wakeSenders = false)
      if not schedulerRunOneRoot(workerLease):
        let retry = args[0].channelSendState()
        if retry.closed or not retry.full:
          continue
        raise newException(GeneError, "Channel/send would suspend on a full channel")
      continue
    let pushed = args[0].tryPushChannel(checkedChannelSendItem(args[0], args[1],
                                             "Channel/send item", scope))
    if pushed.pushed:
      wakeChannelWaiters(args[0], wakeSenders = false)   # a buffered value may wake a receiver
      return NIL
    if pushed.closed:
      raiseChannelClosed(scope)

proc biChannelTrySend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Channel/try_send expects 2 arguments, got " & $args.len)
  requireChannel("Channel/try_send", args[0])
  let state = args[0].channelSendState()
  if state.closed or state.full:
    return FALSE
  let scope = if call == nil: nil else: call[].dispatchScope
  let pushed = args[0].tryPushChannel(checkedChannelSendItem(args[0], args[1],
                                             "Channel/try_send item", scope))
  if not pushed.pushed:
    return FALSE
  wakeChannelWaiters(args[0], wakeSenders = false)  # a new value may wake a parked receiver
  TRUE

proc nativeChannelTrySend*(channel, item: Value, scope: Scope = nil): bool =
  withScopedScheduler(scope):
    requireChannel("native channel try_send", channel)
    let state = channel.channelSendState()
    if state.closed or state.full:
      return false
    let pushed = channel.tryPushChannel(checkedChannelSendItem(channel, item,
                                               "native channel item", scope))
    if not pushed.pushed:
      return false
    wakeChannelWaiters(channel, wakeSenders = false)
    true

proc biChannelRecv(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/recv", args)
  requireChannel("Channel/recv", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  var workerLease: SchedulerWorkerLease
  var workerLeaseOpen = false
  defer:
    if workerLeaseOpen:
      endSchedulerWorkerLease(workerLease)
  while true:
    pollOsExecAsyncCompletions()
    let state = args[0].channelRecvState()
    if state.empty:
      if state.closed:
        raiseChannelClosed(scope)
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
      wakeChannelWaiters(args[0], wakeSenders = true)
      if not schedulerRunOneRoot(workerLease):
        let retry = args[0].channelRecvState()
        if retry.closed or not retry.empty:
          continue
        when compileOption("threads"):
          # A dedicated-thread native op (os/exec_stream_async) may still feed
          # or close this channel; poll instead of raising.
          if externalNativeOpsPending():
            os.sleep(1)
            continue
        raise newException(GeneError, "Channel/recv would suspend on an empty channel")
      continue
    let popped = args[0].tryPopChannel()
    if popped.popped:
      let item = checkedChannelItem(args[0], popped.item,
                                    "Channel/recv item", scope)
      wakeChannelWaiters(args[0], wakeSenders = true)  # freed space may wake a sender
      drainSupervisorFailures()
      return item

proc tryRecvVariant(scope: Scope, name: string): Value =
  if scope == nil:
    raise newException(GeneError,
      "Channel/try_recv requires a runtime scope")
  var root = scope
  while root.parent != nil:
    root = root.parent
  if not root.vars.hasKey("TryRecv") or not root.vars["TryRecv"].isEnumType:
    raise newException(GeneError, "TryRecv result type is unavailable")
  let variant = root.vars["TryRecv"].enumVariantDescriptor(name)
  if variant.kind != vkEnumVariant:
    raise newException(GeneError, "TryRecv result variant is unavailable: " & name)
  variant

proc tryRecvEmpty(scope: Scope): Value =
  scope.tryRecvVariant("empty")

proc tryRecvValue(scope: Scope, item: Value): Value =
  newNode(scope.tryRecvVariant("value"), body = @[item], immutable = true)

proc tryNextVariant(scope: Scope, name: string): Value =
  if scope == nil:
    raise newException(GeneError,
      "Stream/try_next requires a runtime scope")
  var root = scope
  while root.parent != nil:
    root = root.parent
  if not root.vars.hasKey("TryNext") or not root.vars["TryNext"].isEnumType:
    raise newException(GeneError, "TryNext result type is unavailable")
  let variant = root.vars["TryNext"].enumVariantDescriptor(name)
  if variant.kind != vkEnumVariant:
    raise newException(GeneError, "TryNext result variant is unavailable: " & name)
  variant

proc tryNextExhausted(scope: Scope): Value =
  scope.tryNextVariant("exhausted")

proc tryNextValue(scope: Scope, item: Value): Value =
  newNode(scope.tryNextVariant("value"), body = @[item], immutable = true)

proc tryNextError(scope: Scope, err: Value): Value =
  newNode(scope.tryNextVariant("error"), body = @[err], immutable = true)

proc biChannelTryRecv(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Channel/try_recv", args)
  requireChannel("Channel/try_recv", args[0])
  pollOsExecAsyncCompletions()
  let scope = if call == nil: nil else: call[].dispatchScope
  let popped = args[0].tryPopChannel()
  if not popped.popped:
    return tryRecvEmpty(scope)
  let item = checkedChannelItem(args[0], popped.item, "Channel/try_recv item",
                                scope)
  wakeChannelWaiters(args[0], wakeSenders = true)  # freed space may wake a parked sender
  drainSupervisorFailures()
  tryRecvValue(scope, item)

proc nativeChannelTryRecv*(channel: Value, scope: Scope): Value =
  withScopedScheduler(scope):
    requireChannel("native channel try_recv", channel)
    let popped = channel.tryPopChannel()
    if not popped.popped:
      return tryRecvEmpty(scope)
    let item = checkedChannelItem(channel, popped.item,
                                  "native channel item", scope)
    wakeChannelWaiters(channel, wakeSenders = true)
    drainSupervisorFailures()
    result = tryRecvValue(scope, item)

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
  var props = initPropTable()
  props["message"] = newStr("actor is closed")
  var head = newSym("ActorClosed")
  var closedType: Value
  if builtinTypeBinding(scope, "ActorClosed", closedType) and
      closedType.kind == vkType:
    head = closedType
  var e: ref GeneError
  new(e)
  e.msg = "actor is closed"
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc raiseReplyAlreadySent(scope: Scope) =
  ## ReplyTo is single-use (design §13.5); a second send is the programming
  ## error named ReplyAlreadySent (async-http-server proposal §18.2).
  const message = "reply has already been sent"
  var props = initPropTable()
  props["message"] = newStr(message)
  var head = newSym("ReplyAlreadySent")
  var sentType: Value
  if builtinTypeBinding(scope, "ReplyAlreadySent", sentType) and
      sentType.kind == vkType:
    head = sentType
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc actorErrorValue(scope: Scope, message: string): Value =
  var props = initPropTable()
  props["message"] = newStr(message)
  var head = newSym("ActorError")
  var actorError: Value
  if builtinTypeBinding(scope, "ActorError", actorError) and
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
  var props = initPropTable()
  props["actor"] = actor
  props["failed_message"] = failedMessage
  props["message"] = newStr(message)
  props["error"] = errorValue
  props["panic"] = if panic: TRUE else: FALSE
  props["strategy"] = newSym(actorFailureStrategyName(actor.actorFailureStrategy))
  var head = newSym("ActorFailure")
  var failureType: Value
  if builtinTypeBinding(scope, "ActorFailure", failureType) and
      failureType.kind == vkType:
    head = failureType
  newNode(head, props = props)

type SupervisorEmitResult = enum
  serDelivered
  serFull
  serUnavailable

proc tryEmitSupervisorFailure(sink, event: Value,
                              scope: Scope): SupervisorEmitResult =
  if sink.kind != vkChannel:
    return serUnavailable
  try:
    let state = sink.channelSendState()
    if state.closed:
      return serUnavailable
    if state.full:
      return serFull
    let pushed = sink.tryPushChannel(checkedChannelSendItem(sink, event,
                                            "supervisor failure event", scope))
    if not pushed.pushed:
      return serUnavailable
  except CatchableError:
    return serUnavailable
  wakeChannelWaiters(sink, wakeSenders = false)
  serDelivered

proc queueSupervisorFailure(sink, event: Value, scope: Scope) =
  if sink.kind != vkChannel:
    return
  let s = currentScheduler()
  withSchedulerLock(s):
    let pending = s.supervisorRetries.len - s.supervisorRetryHead
    if pending >= supervisorFailureRetryCapacity:
      inc s.supervisorRetryDrops
      return
    s.supervisorRetries.add SupervisorFailureRetry(
      sink: sink, event: event, scope: scope)
    let nextPending = pending + 1
    if nextPending > s.supervisorRetryHighWater:
      s.supervisorRetryHighWater = nextPending

proc noteDroppedSupervisorFailure() =
  let s = currentScheduler()
  withSchedulerLock(s):
    inc s.supervisorRetryDrops

proc drainSupervisorFailures() =
  ## Drain the bounded FIFO opportunistically whenever a receive frees channel
  ## space. No retry task/fiber is allocated per failure.
  let s = currentScheduler()
  withSchedulerLock(s):
    if s.supervisorDrainActive:
      return
    s.supervisorDrainActive = true
  defer:
    withSchedulerLock(s):
      s.supervisorDrainActive = false
      if s.supervisorRetryHead == s.supervisorRetries.len:
        s.supervisorRetries.setLen(0)
        s.supervisorRetryHead = 0
  while true:
    var retry: SupervisorFailureRetry
    withSchedulerLock(s):
      if s.supervisorRetryHead >= s.supervisorRetries.len:
        return
      retry = s.supervisorRetries[s.supervisorRetryHead]
    case tryEmitSupervisorFailure(retry.sink, retry.event, retry.scope)
    of serDelivered:
      withSchedulerLock(s):
        inc s.supervisorRetryHead
    of serUnavailable:
      withSchedulerLock(s):
        inc s.supervisorRetryHead
        inc s.supervisorRetryDrops
    of serFull:
      return

proc emitOrQueueSupervisorFailure(sink, fallback, event: Value, scope: Scope) =
  case tryEmitSupervisorFailure(sink, event, scope)
  of serDelivered:
    discard
  of serFull:
    if fallback.kind == vkChannel and not same(fallback, sink):
      case tryEmitSupervisorFailure(fallback, event, scope)
      of serDelivered:
        discard
      of serFull:
        queueSupervisorFailure(fallback, event, scope)
      of serUnavailable:
        queueSupervisorFailure(sink, event, scope)
    else:
      queueSupervisorFailure(sink, event, scope)
  of serUnavailable:
    if fallback.kind == vkChannel and not same(fallback, sink):
      case tryEmitSupervisorFailure(fallback, event, scope)
      of serDelivered:
        discard
      of serFull:
        queueSupervisorFailure(fallback, event, scope)
      of serUnavailable:
        noteDroppedSupervisorFailure()
    elif sink.kind == vkChannel:
      noteDroppedSupervisorFailure()

proc emitSupervisorFailure(actor, failedMessage: Value, scope: Scope,
                           message: string, errorValue: Value,
                           panic = false) =
  let event = supervisorFailureValue(scope, actor, failedMessage, message,
                                     errorValue, panic)
  emitOrQueueSupervisorFailure(actor.actorFailureEvents,
                               actor.actorFailureDeadLetters, event, scope)
  if actor.actorFailureStrategy == afsEscalate:
    emitOrQueueSupervisorFailure(actor.actorParentFailureEvents,
      actor.actorParentFailureDeadLetters, event, scope)

proc failReplyTask(reply: Value, message: string, errVal: Value = NIL,
                   hasValue = false): bool =
  if reply.kind != vkReplyTo:
    return false
  let claimed = reply.claimReplyToCancel()
  if not claimed.claimed:
    return false
  let task = claimed.task
  if task.kind != vkTask or task.taskDone:
    return true
  failTask(task, message, errVal, hasValue)
  wakeTaskWaiters(task)
  true

proc panicReplyTask(reply: Value, message: string, errVal: Value = NIL,
                    hasValue = false): bool =
  if reply.kind != vkReplyTo:
    return false
  let claimed = reply.claimReplyToCancel()
  if not claimed.claimed:
    return false
  let task = claimed.task
  if task.kind != vkTask or task.taskDone:
    return true
  panicTask(task, message, errVal, hasValue)
  wakeTaskWaiters(task)
  true

proc cancelReplyTask(reply: Value): bool =
  if reply.kind != vkReplyTo:
    return false
  let claimed = reply.claimReplyToCancel()
  if not claimed.claimed:
    return false
  let task = claimed.task
  if task.kind != vkTask:
    return true
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
    if name != "timeout_ms":
      raise newException(GeneError,
        "actor/ask got unexpected named argument: " & name)
  let index = nativeNamedIndex(call, "timeout_ms")
  if index >= 0:
    result = requireInt64("actor/ask timeout_ms", call[].namedValues[index])
    if result < 0:
      raise newException(GeneError, "actor/ask timeout_ms must be non-negative")

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
  if reply.replyToRelaxedSend:
    # Native single-producer reply edge (net/http pool): the server loop is
    # the only consumer and stays on the scheduler thread, so the Send
    # boundary is intentionally not enforced here — mirrors the request
    # direction in dispatchHttpToPool.
    return
  if not isSendableValue(result, fallbackScope):
    raiseTypeError(where, "Send", result, fallbackScope)
  markSharedValue(result)

proc biReplyToSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "ReplyTo/send expects 2 arguments, got " & $args.len)
  requireReplyTo("ReplyTo/send", args[0])
  let scope = actorDispatchScope(call)
  if args[0].replyToSent:
    raiseReplyAlreadySent(scope)
  let sent = args[0].trySendReplyTo(checkedReplyValue(args[0], args[1],
                                                      "ReplyTo/send value",
                                                      scope))
  if not sent.sent:
    raiseReplyAlreadySent(scope)
  if sent.task.kind == vkTask:
    wakeTaskWaiters(sent.task)
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
    if messageType.kind != vkNil:
      closeTypeExpr(messageType, scope)
    elif handler.kind == vkFunction and handler.fnCode != nil and
        handler.fnCode of FunctionProto:
      let proto = FunctionProto(handler.fnCode)
      if proto.paramTypes.len >= 3 and proto.paramTypes[2].kind != vkNil:
        closeTypeExpr(proto.paramTypes[2], handler.fnScope)
      else:
        newSym("Any")
    else:
      newSym("Any")
  let failureStrategy =
    if scope == nil: afsStop else: scope.actorOwnerFailureStrategy()
  let failureEvents =
    if scope == nil: NIL else: scope.actorOwnerFailureEvents()
  let failureDeadLetters =
    if scope == nil: NIL else: scope.actorOwnerFailureDeadLetters()
  let parentFailureEvents =
    if scope == nil or failureStrategy != afsEscalate:
      NIL
    else:
      scope.parentActorOwnerFailureEvents()
  let parentFailureDeadLetters =
    if scope == nil or failureStrategy != afsEscalate:
      NIL
    else:
      scope.parentActorOwnerFailureDeadLetters()
  let restartInit =
    if failureStrategy == afsRestart: initFn else: NIL
  var restartLimits: tuple[maxRestarts, windowMs: int] = (0, 0)
  if scope != nil and failureStrategy == afsRestart:
    restartLimits = scope.actorOwnerRestartLimits()
  let state = applyCall(initFn, [], NamedArgs(), scope)
  result = newActorRef(actorMailboxArg(call), state, handler, closedMessageType,
                       restartInit, failureStrategy, failureEvents,
                       failureDeadLetters, parentFailureEvents,
                       parentFailureDeadLetters,
                       maxRestarts = restartLimits.maxRestarts,
                       restartWindowMs = restartLimits.windowMs,
                       messageTypeExplicit = messageType.kind != vkNil)
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
  while true:
    let state = actor.actorSendState()
    if state.closed:
      raiseActorClosed(scope)
    if state.full:
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
      scheduleActor(actor, scope)
      if not schedulerRunOneRoot(workerLease):
        let retry = actor.actorSendState()
        if retry.closed or not retry.full:
          continue
        raise newException(GeneError, "actor/send would suspend on a full mailbox")
      continue
    let pushed = actor.tryPushActorMessage(checkedActorMessage(actor, args[1],
                                             "actor/send message", scope))
    if pushed.pushed:
      scheduleActor(actor, scope)
      if not currentFiberActive:
        driveActor(actor)   # root send stays synchronous: process the message now
      return NIL
    if pushed.closed:
      raiseActorClosed(scope)

proc biActorTrySend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/try_send expects 2 arguments, got " & $args.len)
  requireActor("actor/try_send", args[0])
  let state = args[0].actorSendState()
  if state.closed or state.full:
    return FALSE
  let scope = actorDispatchScope(call)
  let pushed = args[0].tryPushActorMessage(checkedActorMessage(args[0], args[1],
                                               "actor/try_send message", scope),
                                             workerAllowed = true)
  if not pushed.pushed:
    return FALSE
  scheduleActor(args[0], scope)
  TRUE

proc nativeActorTrySend*(actor, message: Value, scope: Scope = nil): bool =
  withScopedScheduler(scope):
    requireActor("native actor try_send", actor)
    let state = actor.actorSendState()
    if state.closed or state.full:
      return false
    let pushed = actor.tryPushActorMessage(checkedActorMessage(actor, message,
                                               "native actor message", scope),
                                             workerAllowed = true)
    if not pushed.pushed:
      return false
    scheduleActor(actor, scope)
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
    var reservationOpen = false
    defer:
      if reservationOpen:
        actor.releaseReservedActorMessage()
        wakeActorSenders(actor)
      if workerLeaseOpen:
        endSchedulerWorkerLease(workerLease)
    while true:
      let reserved = actor.tryReserveActorMessage()
      if reserved.reserved:
        reservationOpen = true
        break
      if reserved.closed:
        raiseActorClosed(scope)
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
      scheduleActor(actor, scope)
      if not schedulerRunOneRoot(workerLease):
        let retry = actor.actorSendState()
        if retry.closed or not retry.full:
          continue
        raise newException(GeneError, "actor/ask would suspend on a full mailbox")
    let task = newPendingTask()
    let reply = newReplyTo(task = task)
    var buildArgs = [reply]
    let message = applyCall(args[1], buildArgs, NamedArgs(), scope)
    let committed = actor.commitReservedActorMessage(
      checkedActorMessage(actor, message, "actor/ask message", scope), reply)
    reservationOpen = false
    if committed.closed:
      discard cancelReplyTask(reply)
      raiseActorClosed(scope)
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
  let snapshot = actor.actorSnapshotFields()
  if not snapshot.idle:
    raise newException(GeneError, "actor/snapshot requires an idle actor")
  var props = initPropTable()
  props["state"] = snapshot.state
  props["mailbox"] = newInt(snapshot.mailbox)
  props["closed"] = newBool(snapshot.closed)
  props["processing"] = newBool(snapshot.processing)
  newNode(newSym("ActorSnapshot"), props = props, immutable = true)

proc biActorUpgrade(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "actor/upgrade expects 2 arguments, got " & $args.len)
  requireActor("actor/upgrade", args[0])
  let scope = actorDispatchScope(call)
  let actor = args[0]
  let handler = args[1]
  let snapshot = actor.actorSnapshotFields()
  if not snapshot.idle:
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
  var nextState = snapshot.state
  if migrate.kind != vkNil:
    if not migrate.valueImplementsCallable(scope):
      raiseTypeError("actor/upgrade migrate", "Callable", migrate, scope)
    var migrateArgs = [snapshot.state]
    nextState = applyCall(migrate, migrateArgs, NamedArgs(), scope)
  if not actor.tryUpgradeIdleActor(nextState, handler):
    raise newException(GeneError, "actor/upgrade requires an idle actor")
  NIL

proc requireStream(name: string, value: Value) =
  if value.kind != vkStream:
    raise newException(GeneError, name & " expects a Stream")

proc requireRange(name: string, value: Value) =
  if value.kind != vkRange:
    raise newException(GeneError, name & " expects a Range")

proc requireDate(name: string, value: Value) =
  if value.kind != vkDate:
    raise newException(GeneError, name & " expects a Date")

proc requireTime(name: string, value: Value) =
  if value.kind != vkTime:
    raise newException(GeneError, name & " expects a Time")

proc requireDateTime(name: string, value: Value) =
  if value.kind != vkDateTime:
    raise newException(GeneError, name & " expects a DateTime")

proc requireTimezone(name: string, value: Value) =
  if value.kind != vkTimezone:
    raise newException(GeneError, name & " expects a Timezone")

proc requireDuration(name: string, value: Value) =
  if value.kind != vkDuration:
    raise newException(GeneError, name & " expects a Duration")

proc rangeDone(value: Value, current: int64): bool =
  let stop = value.rangeStop
  let step = value.rangeStep
  if value.rangeInclusive:
    if step > 0: current > stop else: current < stop
  else:
    if step > 0: current >= stop else: current <= stop

proc rangeCanAdvance(current, step: int64): bool =
  if step > 0:
    current <= high(int64) - step
  else:
    current >= low(int64) - step

proc pullRangeStream(stream: Value): StreamPullResult {.nimcall.} =
  let source = stream.streamSource
  let current = stream.streamRemaining
  if source.rangeDone(current):
    return StreamPullResult(has: false)
  result = StreamPullResult(has: true, item: newInt(current))
  if current.rangeCanAdvance(source.rangeStep):
    stream.setStreamRemaining(current + source.rangeStep)
  else:
    stream.closeStream()

proc rangeStream(value: Value): Value =
  requireRange("to_stream", value)
  newLazyStream(value, pullRangeStream, remaining = value.rangeStart,
                itemType = newSym("Int"), errType = newSym("Never"))

proc checkedStreamItem(stream, item: Value, where: string): Value =
  let itemType = stream.streamItemType
  if itemType.kind != vkNil:
    let itemScope = stream.streamItemScope
    if not matchesTypeExpr(itemType, item, itemScope):
      try:
        stream.closeStream()
      except CatchableError:
        discard
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

proc carriesCallerEnv(value: Value, seen: var HashSet[uint64]): bool =
  ## Detect direct or captured borrowed authority at publication boundaries.
  ## Containers are walked defensively; ordinary construction rejects them, so
  ## this remains a cold error-path check rather than a hot lookup tax.
  if value.kind == vkCallerEnv:
    return true
  if value.isHeapBacked:
    if seen.contains(value.bits):
      return false
    seen.incl value.bits
  case value.kind
  of vkFunction:
    value.fnCapturesCallerEnv
  of vkList:
    for item in value.listItems:
      if carriesCallerEnv(item, seen): return true
    false
  of vkMap:
    for _, item in value.mapEntries:
      if carriesCallerEnv(item, seen): return true
    false
  of vkSet:
    for item in value.setItems:
      if carriesCallerEnv(item, seen): return true
    false
  of vkHashMap:
    for entry in value.hashMapEntries:
      if carriesCallerEnv(entry.key, seen) or
          carriesCallerEnv(entry.val, seen): return true
    false
  of vkNode:
    if carriesCallerEnv(value.head, seen): return true
    for _, item in value.props:
      if carriesCallerEnv(item, seen): return true
    for item in value.body:
      if carriesCallerEnv(item, seen): return true
    for _, item in value.meta:
      if carriesCallerEnv(item, seen): return true
    false
  of vkNamespace:
    value.nsScope != nil and value.nsScope.borrowedCallerEnv
  of vkModule:
    carriesCallerEnv(value.moduleRootNamespace, seen)
  of vkEnv:
    if carriesCallerEnv(value.envParent, seen): return true
    for _, item in value.envBindings:
      if carriesCallerEnv(item, seen): return true
    for item in value.envImports:
      if carriesCallerEnv(item, seen): return true
    carriesCallerEnv(value.envModule, seen) or
      carriesCallerEnv(value.envCapabilities, seen) or
      carriesCallerEnv(value.envPolicy, seen)
  of vkCell:
    carriesCallerEnv(value.cellValue, seen)
  of vkAtomicCell:
    carriesCallerEnv(value.atomicCellValue, seen)
  of vkStream:
    (value.streamGeneratorScope != nil and
      value.streamGeneratorScope.borrowedCallerEnv) or
      carriesCallerEnv(value.streamSource, seen) or
      carriesCallerEnv(value.streamCallable, seen)
  else:
    false

proc carriesCallerEnv(value: Value): bool =
  var seen = initHashSet[uint64]()
  carriesCallerEnv(value, seen)

proc carriesConstruction*(value: Value): bool {.noinline.}

proc rejectCallerEnvEscape(where: string, value: Value) =
  if value.carriesCallerEnv:
    raise newException(GeneError,
      where & " cannot retain borrowed CallerEnv authority; use " &
      "Env/snapshot with explicit binding names")
  if activeConstructionDepth > 0 and value.carriesConstruction:
    raise newException(GeneError,
      where & " cannot publish an in-progress constructed instance")

proc carriesConstruction(value: Value, seenValues: var HashSet[uint64],
                         seenScopes: var HashSet[pointer]): bool

proc scopeCarriesConstruction(scope: Scope, seenValues: var HashSet[uint64],
                              seenScopes: var HashSet[pointer]): bool =
  if scope == nil:
    return false
  let key = cast[pointer](scope)
  if key in seenScopes:
    return false
  seenScopes.incl key
  scope.materializeMirroredVars()
  for _, item in scope.vars:
    if carriesConstruction(item, seenValues, seenScopes):
      return true
  for i, item in scope.slots:
    if scope.slotDefined(i) and carriesConstruction(item, seenValues, seenScopes):
      return true
  false

proc carriesConstruction(value: Value, seenValues: var HashSet[uint64],
                         seenScopes: var HashSet[pointer]): bool =
  if value.kind == vkNode and value.nodeConstructing:
    return true
  if value.isHeapBacked:
    if value.bits in seenValues:
      return false
    seenValues.incl value.bits
  case value.kind
  of vkFunction:
    scopeCarriesConstruction(value.fnScope, seenValues, seenScopes)
  of vkList:
    for item in value.listItems:
      if carriesConstruction(item, seenValues, seenScopes): return true
    false
  of vkMap:
    for _, item in value.mapEntries:
      if carriesConstruction(item, seenValues, seenScopes): return true
    false
  of vkSet:
    for item in value.setItems:
      if carriesConstruction(item, seenValues, seenScopes): return true
    false
  of vkHashMap:
    for entry in value.hashMapEntries:
      if carriesConstruction(entry.key, seenValues, seenScopes) or
          carriesConstruction(entry.val, seenValues, seenScopes): return true
    false
  of vkNode:
    if carriesConstruction(value.head, seenValues, seenScopes): return true
    for _, item in value.props:
      if carriesConstruction(item, seenValues, seenScopes): return true
    for item in value.body:
      if carriesConstruction(item, seenValues, seenScopes): return true
    for _, item in value.meta:
      if carriesConstruction(item, seenValues, seenScopes): return true
    false
  of vkCell:
    carriesConstruction(value.cellValue, seenValues, seenScopes)
  of vkAtomicCell:
    carriesConstruction(value.atomicCellValue, seenValues, seenScopes)
  of vkEnv:
    for _, item in value.envBindings:
      if carriesConstruction(item, seenValues, seenScopes): return true
    false
  else:
    false

proc carriesConstruction*(value: Value): bool =
  # Construction markers and graphs exist only in heap-backed values. Keep the
  # ubiquitous scalar return/store path allocation-free.
  if not value.isHeapBacked:
    return false
  var seenValues = initHashSet[uint64]()
  var seenScopes = initHashSet[pointer]()
  carriesConstruction(value, seenValues, seenScopes)

proc scopeCarriesConstruction(scope: Scope): bool {.noinline.} =
  var seenValues = initHashSet[uint64]()
  var seenScopes = initHashSet[pointer]()
  scopeCarriesConstruction(scope, seenValues, seenScopes)

proc raiseEndOfStream() =
  var props = initPropTable()
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

proc readContextValues(frames: openArray[ReadContextFrame]): Value =
  var values: seq[Value]
  for frame in frames:
    var props = initPropTable()
    props["source"] = newStr(frame.sourceName)
    props["opener"] = newStr(frame.opener)
    props["expected_closer"] = newStr(frame.expectedCloser)
    props["line"] = newInt(frame.line)
    props["col"] = newInt(frame.col)
    values.add newMap(props, immutable = true)
  newList(values, immutable = true)

proc raiseReaderError(name, message, typeName: string, scope: Scope,
                      sourceName = "", line = 0, col = 0,
                      contexts: openArray[ReadContextFrame] = []) =
  let fullMessage = name & ": " & message
  var props = initPropTable()
  props["message"] = newStr(fullMessage)
  if line > 0:
    props["source"] = newStr(sourceName)
    props["line"] = newInt(line)
    props["col"] = newInt(col)
    props["contexts"] = readContextValues(contexts)
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
    raiseReaderError(name, e.msg, "ParseError", scope,
                     e.sourceName, e.line, e.col, e.contextFrames)

proc biReadOne(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("read_one", args)
  let scope = if call == nil: nil else: call.dispatchScope
  let forms = readFormsFromString("read_one", args[0], scope)
  if forms.len == 0:
    return NIL
  if forms.len > 1:
    raise newException(GeneError, "read_one expects one form, got " & $forms.len)
  forms[0]

proc biReadAll(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("read_all", args)
  let scope = if call == nil: nil else: call.dispatchScope
  newStream(readFormsFromString("read_all", args[0], scope))

proc biParseFormat(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Canonical human-friendly formatting of a source string (the `gene fmt`
  ## contract): sugar restored, comments kept, forms wrapped by depth.
  requireOne("format", args)
  if args[0].kind != vkString:
    raise newException(GeneError, "format expects a Str")
  let scope = if call == nil: nil else: call.dispatchScope
  try:
    result = newStr(formatSource(args[0].strVal, "<format>"))
  except ReadError as e:
    raiseReaderError("format", e.msg, "ParseError", scope,
                     e.sourceName, e.line, e.col, e.contextFrames)

proc tokenValue(token: Token, tokenType: Value): Value =
  var props = initPropTable()
  props["kind"] = newSym(token.kind.tokenKindName)
  props["lexeme"] = newStr(token.lexeme)
  props["line"] = newInt(int64(token.line))
  props["col"] = newInt(int64(token.col))
  newNode(tokenType, props = props, immutable = true)

proc biLexAll(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("lex_all", args)
  if args[0].kind != vkString:
    raise newException(GeneError, "lex_all expects a Str")
  let scope = if call == nil: nil else: call.dispatchScope
  let tokenType = builtInTypeHead(scope, "Token")
  var tokens: seq[Value]
  try:
    for token in lexAll(args[0].strVal):
      tokens.add token.tokenValue(tokenType)
  except ReadError as e:
    raiseReaderError("lex_all", e.msg, "LexError", scope,
                     e.sourceName, e.line, e.col, e.contextFrames)
  newTypedStream(tokens, tokenType, newSym("Never"), scope)

proc requireRangeArgCount(name: string, args: openArray[Value]) =
  if args.len < 2 or args.len > 4:
    raise newException(GeneError, name & " expects 2..4 arguments, got " & $args.len)

proc biRange(args: openArray[Value]): Value {.nimcall.} =
  requireRangeArgCount("range", args)
  let start = requireInt64("range start", args[0])
  let stop = requireInt64("range stop", args[1])
  let step =
    if args.len >= 3: requireInt64("range step", args[2])
    else: 1'i64
  let inclusive =
    if args.len >= 4:
      if args[3].kind != vkBool:
        raise newException(GeneError, "range inclusive expects a Bool")
      args[3].boolVal
    else:
      false
  newRange(start, stop, step, inclusive)

proc unsignedDistanceGreater(a, b: int64): uint64 =
  ## Distance from b to a, where a >= b. Written to avoid signed overflow when
  ## the range crosses zero or touches int64 bounds.
  if b >= 0:
    uint64(a - b)
  elif a < 0:
    uint64(a - b)
  else:
    uint64(a) + uint64(-(b + 1)) + 1'u64

proc absStep(step: int64): uint64 =
  if step > 0: uint64(step)
  else: uint64(-(step + 1)) + 1'u64

proc uintCountValue(count: uint64): Value =
  if count <= uint64(high(int64)):
    newInt(int64(count))
  else:
    newIntFromDecimal($count)

proc inclusiveCountValue(dist, step: uint64): Value =
  let q = dist div step
  if q == high(uint64):
    newIntFromDecimal("18446744073709551616")
  else:
    uintCountValue(q + 1'u64)

proc rangeCountValue(value: Value): Value =
  let start = value.rangeStart
  let stop = value.rangeStop
  let step = value.rangeStep
  var dist: uint64
  if step > 0:
    if value.rangeInclusive:
      if start > stop: return newInt(0)
      dist = unsignedDistanceGreater(stop, start)
      return inclusiveCountValue(dist, step.absStep)
    if start >= stop: return newInt(0)
    dist = unsignedDistanceGreater(stop, start)
  else:
    if value.rangeInclusive:
      if start < stop: return newInt(0)
      dist = unsignedDistanceGreater(start, stop)
      return inclusiveCountValue(dist, step.absStep)
    if start <= stop: return newInt(0)
    dist = unsignedDistanceGreater(start, stop)
  uintCountValue(((dist - 1'u64) div step.absStep) + 1'u64)

proc biRangeStart(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Range/start", args)
  requireRange("Range/start", args[0])
  newInt(args[0].rangeStart)

proc biRangeStop(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Range/stop", args)
  requireRange("Range/stop", args[0])
  newInt(args[0].rangeStop)

proc biRangeStep(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Range/step", args)
  requireRange("Range/step", args[0])
  newInt(args[0].rangeStep)

proc biRangeInclusive(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Range/inclusive?", args)
  requireRange("Range/inclusive?", args[0])
  newBool(args[0].rangeInclusive)

proc biRangeSize(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Range/size", args)
  requireRange("Range/size", args[0])
  rangeCountValue(args[0])

proc intArg(name: string, value: Value): int =
  let v = requireInt64(name, value)
  if v < low(int) or v > high(int):
    raise newException(GeneError, name & " expects an Int in native int range")
  int(v)

proc biDate(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "date expects 3 arguments, got " & $args.len)
  newDate(intArg("date year", args[0]), intArg("date month", args[1]),
          intArg("date day", args[2]))

proc biTime(args: openArray[Value]): Value {.nimcall.} =
  if args.len < 2 or args.len > 6:
    raise newException(GeneError, "time expects 2..6 arguments, got " & $args.len)
  let second = if args.len >= 3: intArg("time second", args[2]) else: 0
  let microsecond =
    if args.len >= 4: intArg("time microsecond", args[3]) else: 0
  let hasOffset = args.len >= 5
  let offset = if hasOffset: intArg("time offset", args[4]) else: 0
  var name = ""
  if args.len >= 6:
    requireStr("time timezone", args[5])
    name = args[5].strVal
  newTime(intArg("time hour", args[0]), intArg("time minute", args[1]),
          second, microsecond, hasOffset, offset, name)

proc biDateTime(args: openArray[Value]): Value {.nimcall.} =
  if args.len < 5 or args.len > 9:
    raise newException(GeneError,
      "datetime expects 5..9 arguments, got " & $args.len)
  let second = if args.len >= 6: intArg("datetime second", args[5]) else: 0
  let microsecond =
    if args.len >= 7: intArg("datetime microsecond", args[6]) else: 0
  let hasOffset = args.len >= 8
  let offset = if hasOffset: intArg("datetime offset", args[7]) else: 0
  var name = ""
  if args.len >= 9:
    requireStr("datetime timezone", args[8])
    name = args[8].strVal
  newDateTime(intArg("datetime year", args[0]), intArg("datetime month", args[1]),
              intArg("datetime day", args[2]), intArg("datetime hour", args[3]),
              intArg("datetime minute", args[4]), second, microsecond,
              hasOffset, offset, name)

proc parseOffsetString(name, s: string): int =
  if s == "Z" or s == "UTC":
    return 0
  if s.len != 6 or s[0] notin {'+', '-'} or s[3] != ':':
    raise newException(GeneError, name & " expects UTC, Z, or +/-HH:MM")
  let sign = if s[0] == '-': -1 else: 1
  if not (s[1] in {'0'..'9'} and s[2] in {'0'..'9'} and
          s[4] in {'0'..'9'} and s[5] in {'0'..'9'}):
    raise newException(GeneError, name & " expects UTC, Z, or +/-HH:MM")
  let hour = (ord(s[1]) - ord('0')) * 10 + (ord(s[2]) - ord('0'))
  let minute = (ord(s[4]) - ord('0')) * 10 + (ord(s[5]) - ord('0'))
  if hour > 23 or minute > 59:
    raise newException(GeneError, name & " invalid timezone offset")
  sign * (hour * 60 + minute)

proc biTimezone(args: openArray[Value]): Value {.nimcall.} =
  if args.len < 1 or args.len > 2:
    raise newException(GeneError,
      "timezone expects 1..2 arguments, got " & $args.len)
  if args[0].kind == vkString:
    let s = args[0].strVal
    if s == "UTC" or s == "Z" or
        (s.len == 6 and s[0] in {'+', '-'} and s[3] == ':'):
      let offset = parseOffsetString("timezone", s)
      let name =
        if args.len == 2:
          requireStr("timezone name", args[1])
          args[1].strVal
        elif s == "UTC" or s == "Z":
          "UTC"
        else:
          ""
      return newTimezone(true, offset, name)
    if args.len != 1:
      raise newException(GeneError, "timezone name-only form expects 1 argument")
    return newTimezone(false, 0, s)
  let offset = intArg("timezone offset", args[0])
  var name = ""
  if args.len == 2:
    requireStr("timezone name", args[1])
    name = args[1].strVal
  newTimezone(true, offset, name)

proc biDuration(args: openArray[Value]): Value {.nimcall.} =
  requireOne("duration", args)
  newDuration(requireInt64("duration microseconds", args[0]))

proc biToday(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "today expects 0 arguments, got " & $args.len)
  let dt = now()
  newDate(dt.year, int(dt.month), dt.monthday)

proc biNow(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "now expects 0 arguments, got " & $args.len)
  let dt = now()
  newDateTime(dt.year, int(dt.month), dt.monthday, dt.hour, dt.minute,
              dt.second, dt.nanosecond div 1000, true, dt.utcOffset div 60,
              "")

proc biDateYear(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Date/year", args)
  requireDate("Date/year", args[0])
  newInt(args[0].dateYear)

proc biDateMonth(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Date/month", args)
  requireDate("Date/month", args[0])
  newInt(args[0].dateMonth)

proc biDateDay(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Date/day", args)
  requireDate("Date/day", args[0])
  newInt(args[0].dateDay)

proc biTimeHour(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Time/hour", args)
  requireTime("Time/hour", args[0])
  newInt(args[0].timeHour)

proc biTimeMinute(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Time/minute", args)
  requireTime("Time/minute", args[0])
  newInt(args[0].timeMinute)

proc biTimeSecond(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Time/second", args)
  requireTime("Time/second", args[0])
  newInt(args[0].timeSecond)

proc biTimeMicrosecond(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Time/microsecond", args)
  requireTime("Time/microsecond", args[0])
  newInt(args[0].timeMicrosecond)

proc biTimeOffset(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Time/offset", args)
  requireTime("Time/offset", args[0])
  if not args[0].timeHasOffset: NIL else: newInt(args[0].timeOffsetMinutes)

proc biTimeTimezone(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Time/timezone", args)
  requireTime("Time/timezone", args[0])
  if args[0].timeTimezoneName.len == 0: NIL else: newStr(args[0].timeTimezoneName)

proc biDateTimeYear(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/year", args)
  requireDateTime("DateTime/year", args[0])
  newInt(args[0].dateTimeYear)

proc biDateTimeMonth(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/month", args)
  requireDateTime("DateTime/month", args[0])
  newInt(args[0].dateTimeMonth)

proc biDateTimeDay(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/day", args)
  requireDateTime("DateTime/day", args[0])
  newInt(args[0].dateTimeDay)

proc biDateTimeHour(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/hour", args)
  requireDateTime("DateTime/hour", args[0])
  newInt(args[0].dateTimeHour)

proc biDateTimeMinute(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/minute", args)
  requireDateTime("DateTime/minute", args[0])
  newInt(args[0].dateTimeMinute)

proc biDateTimeSecond(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/second", args)
  requireDateTime("DateTime/second", args[0])
  newInt(args[0].dateTimeSecond)

proc biDateTimeMicrosecond(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/microsecond", args)
  requireDateTime("DateTime/microsecond", args[0])
  newInt(args[0].dateTimeMicrosecond)

proc biDateTimeOffset(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/offset", args)
  requireDateTime("DateTime/offset", args[0])
  if not args[0].dateTimeHasOffset: NIL else: newInt(args[0].dateTimeOffsetMinutes)

proc biDateTimeTimezone(args: openArray[Value]): Value {.nimcall.} =
  requireOne("DateTime/timezone", args)
  requireDateTime("DateTime/timezone", args[0])
  if args[0].dateTimeTimezoneName.len == 0:
    NIL
  else:
    newStr(args[0].dateTimeTimezoneName)

proc biTimezoneOffset(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Timezone/offset", args)
  requireTimezone("Timezone/offset", args[0])
  if not args[0].timezoneHasOffset: NIL else: newInt(args[0].timezoneOffsetMinutes)

proc biTimezoneName(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Timezone/name", args)
  requireTimezone("Timezone/name", args[0])
  if args[0].timezoneName.len == 0: NIL else: newStr(args[0].timezoneName)

proc biDurationMicroseconds(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Duration/microseconds", args)
  requireDuration("Duration/microseconds", args[0])
  newInt(args[0].durationMicroseconds)

proc biDurationMilliseconds(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Duration/milliseconds", args)
  requireDuration("Duration/milliseconds", args[0])
  newFloat(float64(args[0].durationMicroseconds) / 1_000.0)

proc biDurationSeconds(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Duration/seconds", args)
  requireDuration("Duration/seconds", args[0])
  newFloat(float64(args[0].durationMicroseconds) / 1_000_000.0)

proc biToStream(args: openArray[Value]): Value {.nimcall.} =
  requireOne("to_stream", args)
  if args[0].kind == vkRange:
    return rangeStream(args[0])
  if args[0].kind notin {vkList, vkSet}:
    raise newException(GeneError, "to_stream expects a List, Set, or Range")
  var items: seq[Value]
  case args[0].kind
  of vkList:
    for item in args[0].listItems:
      items.add item
  of vkSet:
    for item in args[0].setItems:
      items.add item
  else:
    discard
  newStream(items)

proc biToPairsStream(args: openArray[Value]): Value {.nimcall.} =
  requireOne("to_pairs_stream", args)
  if args[0].kind notin {vkMap, vkHashMap}:
    raise newException(GeneError, "to_pairs_stream expects a Map")
  var pairs: seq[Value]
  case args[0].kind
  of vkMap:
    for key, value in args[0].mapEntries:
      pairs.add newList(@[newSym(key), value])
  of vkHashMap:
    for entry in args[0].hashMapEntries:
      pairs.add newList(@[entry.key, entry.val])
  else:
    discard
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

proc biStreamTryNext(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Stream/try_next", args)
  requireStream("Stream/try_next", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  try:
    if not args[0].streamHasNext:
      return tryNextExhausted(scope)
  except GeneError as e:
    # A producer error is terminal. Return it as a tagged error variant.
    let errVal =
      if e.hasErrVal: e.errVal
      else:
        var props = initPropTable()
        props["message"] = newStr(e.msg)
        newNode(newSym("Error"), props = props)
    return tryNextError(scope, errVal)
  try:
    let item = checkedStreamNext(args[0], "Stream/try_next item")
    tryNextValue(scope, item)
  except GeneError as e:
    let errVal =
      if e.hasErrVal: e.errVal
      else:
        var props = initPropTable()
        props["message"] = newStr(e.msg)
        newNode(newSym("Error"), props = props)
    tryNextError(scope, errVal)

proc copyItems(items: openArray[Value]): seq[Value] =
  result = newSeq[Value](items.len)
  for i, item in items:
    result[i] = item

proc copyEntries(entries: PropTable): PropTable =
  result = initPropTable()
  for key, val in entries:
    result[key] = val

proc freezeValue(value: Value): Value
proc thawValue(value: Value): Value

proc freezeEntries(entries: PropTable): PropTable =
  result = initPropTable()
  for key, val in entries:
    result[key] = freezeValue(val)

proc thawEntries(entries: PropTable): PropTable =
  result = initPropTable()
  for key, val in entries:
    result[key] = thawValue(val)

proc freezeRejectName(value: Value): string =
  case value.kind
  of vkFunction: (if value.isSyntaxFn: "Fn!" else: "Fn")
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
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkBytes, vkRegex, vkRange,
     vkDate, vkTime, vkDateTime, vkTimezone, vkDuration, vkChar, vkSymbol,
     vkLogger, vkType, vkProtocol, vkProtocolMessage, vkEnumVariant:
    value
  of vkList:
    var items = newSeq[Value](value.listItems.len)
    for i, item in value.listItems:
      items[i] = freezeValue(item)
    newList(items, immutable = true)
  of vkMap:
    newMap(freezeEntries(value.mapEntries), immutable = true)
  of vkSet:
    var items = newSeq[Value](value.setItems.len)
    for i, item in value.setItems:
      items[i] = freezeValue(item)
    buildSet("freeze", items)
  of vkHashMap:
    var entries: seq[HashMapEntry]
    for entry in value.hashMapEntries:
      entries.add HashMapEntry(key: freezeValue(entry.key),
                               val: freezeValue(entry.val))
    buildHashMap("freeze", entries)
  of vkNode:
    var body = newSeq[Value](value.body.len)
    for i, item in value.body:
      body[i] = freezeValue(item)
    newNode(freezeValue(value.head),
            props = freezeEntries(value.props),
            body = body,
            meta = freezeEntries(value.meta),
            immutable = true)
  of vkFunction, vkNativeFn, vkNamespace, vkModule, vkEnv, vkCallerEnv, vkCell,
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
  of vkSet:
    var items = newSeq[Value](value.setItems.len)
    for i, item in value.setItems:
      items[i] = thawValue(item)
    buildSet("thaw", items)
  of vkHashMap:
    var entries: seq[HashMapEntry]
    for entry in value.hashMapEntries:
      entries.add HashMapEntry(key: thawValue(entry.key),
                               val: thawValue(entry.val))
    buildHashMap("thaw", entries)
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
  requireOne("freeze_shallow", args)
  case args[0].kind
  of vkList:
    newList(copyItems(args[0].listItems), immutable = true)
  of vkMap:
    newMap(copyEntries(args[0].mapEntries), immutable = true)
  of vkSet:
    newSet(copyItems(args[0].setItems))
  of vkHashMap:
    var entries: seq[HashMapEntry]
    for entry in args[0].hashMapEntries:
      entries.add entry
    newHashMap(entries)
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
  newNode(newSym("selector_key"), body = @[args[0]])

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
  scope.materializeMirroredVars()
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
  of vkBytes: "Bytes"
  of vkRegex: "Regex"
  of vkRange: "Range"
  of vkDate: "Date"
  of vkTime: "Time"
  of vkDateTime: "DateTime"
  of vkTimezone: "Timezone"
  of vkDuration: "Duration"
  of vkChar: "Char"
  of vkSymbol: "Sym"
  of vkList: "List"
  of vkMap: "Map"
  of vkSet: "Set"
  of vkHashMap: "HashMap"
  of vkNode: "Node"
  of vkFunction: (if value.isSyntaxFn: "Fn!" else: "Fn")
  of vkNativeFn: "NativeFn"
  of vkNamespace: "Namespace"
  of vkModule: "Module"
  of vkEnv: "Env"
  of vkCallerEnv: "CallerEnv"
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
  of vkLogger: "Logger"
  of vkType: "Type"
  of vkProtocol: "Protocol"
  of vkProtocolMessage: "ProtocolMessage"
  of vkEnumVariant: "EnumVariant"

proc exportedBinding(ns: Value, name: string): Value =
  if ns.kind != vkNamespace:
    return VOID
  if ns.nsIsModuleRoot and name == "this_mod":
    return VOID
  if name in ns.nsScope.exportExcludedNames:
    return VOID
  ns.nsScope.materializeMirroredVars()
  ns.nsScope.vars.getOrDefault(name, VOID)

proc namespaceDeclarationNodes(ns: Value): seq[Value] =
  for name in sortedBindingNames(ns.nsScope):
    if ns.nsIsModuleRoot and name == "this_mod":
      continue
    let value = ns.nsScope.vars[name]
    var props = initPropTable()
    props["name"] = newStr(name)
    props["kind"] = newStr(declarationKind(value))
    props["value"] = value
    # Declaration meta (@route ... on the source form) becomes real node
    # meta on the record, so decl/%meta/route works (proposal §8).
    var declMeta = initPropTable()
    if value.kind == vkFunction and value.fnCode != nil and
        value.fnCode of FunctionProto:
      let proto = FunctionProto(value.fnCode)
      for i, key in proto.declMetaKeys:
        declMeta[key] = proto.declMetaValues[i]
    result.add newNode(newSym("Declaration"), props = props, meta = declMeta)

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
  var entries = initPropTable()
  for name in sortedBindingNames(args[0].nsScope):
    entries[name] = args[0].nsScope.vars[name]
  newMap(entries)

proc biNamespaceLookup(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Namespace/lookup expects 2 arguments, got " & $args.len)
  requireNamespace("Namespace/lookup", args[0])
  args[0].nsScope.materializeMirroredVars()
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
  of "max_steps", "max_memory_mb", "timeout_ms",
     "allow_ffi", "allow_native_compile":
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
  rejectUnsupportedEvalLimit(policy, "max_memory_mb")
  rejectUnsupportedEvalLimit(policy, "timeout_ms")
  validateEvalPolicyFlag(policy, "allow_ffi")
  validateEvalPolicyFlag(policy, "allow_native_compile")
  evalPolicyNonNegativeInt(policy, "max_steps")

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

proc biEnvSnapshot(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "Env/snapshot expects a CallerEnv and a binding-name list")
  if args[0].kind != vkCallerEnv:
    raise newException(GeneError, "Env/snapshot expects a CallerEnv")
  if args[1].kind != vkList:
    raise newException(GeneError,
      "Env/snapshot binding names must be a list")
  let source = args[0].callerEnvScope
  var bindings = initTable[string, Value]()
  var seen = initHashSet[string]()
  for item in args[1].listItems:
    let name =
      case item.kind
      of vkSymbol: item.symVal
      of vkString: item.strVal
      else:
        raise newException(GeneError,
          "Env/snapshot binding names must be symbols or strings")
    if seen.contains(name):
      raise newException(GeneError,
        "Env/snapshot duplicate binding name: " & name)
    seen.incl name
    var value: Value
    if not source.lookupOptional(name, value):
      raise newException(GeneError,
        "Env/snapshot undefined binding: " & name)
    rejectCallerEnvEscape("Env/snapshot binding '" & name & "'", value)
    bindings[name] = escapeWeakFunctions(value)
  newEnv(bindings)

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
    let item = checkedStreamNext(source, "take item")
    if stream.streamRemaining == 0:
      # Reaching the bound is normal adaptor exhaustion, not cancellation.
      # Relinquish ownership now so `for`'s mandatory cleanup cannot close the
      # still-resumable upstream cursor.
      stream.detachStreamSource()
    return StreamPullResult(has: true, item: item)
  if stream.streamRemaining == 0:
    stream.detachStreamSource()
  StreamPullResult(has: false, item: NIL)

proc newSelectorCallStage(callee: Value, args: openArray[Value]): Value =
  var body = newSeqOfCap[Value](args.len + 1)
  body.add callee
  for arg in args:
    body.add arg
  newNode(newSym("call_stage"), body = body)

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
  result = newLazyStream(args[0], pullTakeStream, remaining = remaining)
  if remaining == 0:
    result.detachStreamSource()

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
  if value.kind != vkVoid:
    rejectCallerEnvEscape(name & " functional update", value)
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
            props = initPropTable()
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
            meta = initPropTable()
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
    raise newException(GeneError, "assoc_in expects 3 arguments, got " & $args.len)
  let path = selectorPath("assoc_in", args[1])
  assocAt("assoc_in", args[0], path, 0, args[2])

proc biUpdateIn(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "update_in expects 3 arguments, got " & $args.len)
  let path = selectorPath("update_in", args[1])
  updateAt("update_in", args[0], path, 0, args[2])

proc requireList(name: string, value: Value) =
  if value.kind != vkList:
    raise newException(GeneError, name & " expects a List")

proc requireMap(name: string, value: Value) =
  if value.kind notin {vkMap, vkHashMap}:
    raise newException(GeneError, name & " expects a Map")

proc requirePropMap(name: string, value: Value) =
  if value.kind != vkMap:
    raise newException(GeneError, name & " expects a PropMap")

proc requireNode(name: string, value: Value) =
  if value.kind != vkNode:
    raise newException(GeneError, name & " expects a Node")

proc biListSize(args: openArray[Value]): Value {.nimcall.} =
  requireOne("size", args)
  case args[0].kind
  of vkList:
    newInt(args[0].listItems.len)
  of vkMap:
    newInt(args[0].mapEntries.len)
  of vkSet:
    newInt(args[0].setItems.len)
  of vkHashMap:
    newInt(args[0].hashMapEntries.len)
  of vkBytes:
    newInt(args[0].bytesVal.len)
  else:
    raise newException(GeneError, "size expects a collection")

proc biListEmpty(args: openArray[Value]): Value {.nimcall.} =
  requireOne("empty?", args)
  case args[0].kind
  of vkList:
    newBool(args[0].listItems.len == 0)
  of vkMap:
    newBool(args[0].mapEntries.len == 0)
  of vkSet:
    newBool(args[0].setItems.len == 0)
  of vkHashMap:
    newBool(args[0].hashMapEntries.len == 0)
  of vkBytes:
    newBool(args[0].bytesVal.len == 0)
  else:
    raise newException(GeneError, "empty? expects a collection")

proc biListFirst(args: openArray[Value]): Value {.nimcall.} =
  requireOne("first", args)
  requireList("first", args[0])
  if args[0].listItems.len > 0: args[0].listItems[0] else: VOID

proc biListLast(args: openArray[Value]): Value {.nimcall.} =
  requireOne("last", args)
  requireList("last", args[0])
  if args[0].listItems.len > 0: args[0].listItems[^1] else: VOID

proc biListAssoc(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "List/assoc expects 3 arguments, got " & $args.len)
  requireList("List/assoc", args[0])
  rejectCallerEnvEscape("List/assoc", args[2])
  let index = updateIndex("List/assoc", args[0].listItems.len,
                          requireInt64("List/assoc", args[1]))
  var items = copyItems(args[0].listItems)
  items[index] = (if args[2].kind == vkVoid: NIL else: args[2])
  newList(items, args[0].listImmutable)

proc biListSetBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "List/set! expects 3 arguments, got " & $args.len)
  requireList("List/set!", args[0])
  rejectCallerEnvEscape("List/set!", args[2])
  let index = updateIndex("List/set!", args[0].listItems.len,
                          requireInt64("List/set!", args[1]))
  let stored = if args[2].kind == vkVoid: NIL else: args[2]
  args[0].setListItem(index, stored)
  stored

proc biListPushBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "List/push! expects 2 arguments, got " & $args.len)
  requireList("List/push!", args[0])
  rejectCallerEnvEscape("List/push!", args[1])
  let stored = if args[1].kind == vkVoid: NIL else: args[1]
  args[0].pushListItem(stored)
  stored

proc biSet(args: openArray[Value]): Value {.nimcall.} =
  buildSet("Set", args)

proc biSetHas(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Set/has expects 2 arguments, got " & $args.len)
  if args[0].kind != vkSet:
    raise newException(GeneError, "Set/has expects a Set")
  requireHashStableKey("Set/has", args[1])
  newBool(findEqualValue(args[0].setItems, args[1]) >= 0)

proc biSetSize(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Set/size", args)
  if args[0].kind != vkSet:
    raise newException(GeneError, "Set/size expects a Set")
  newInt(args[0].setItems.len)

proc biMapPutBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "Map/put! expects 3 arguments, got " & $args.len)
  requirePropMap("Map/put!", args[0])
  rejectCallerEnvEscape("Map/put!", args[2])
  args[0].putMapEntry(keySegment("Map/put!", args[1]), args[2])
  args[2]

proc biMapAssoc(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "Map/assoc expects 3 arguments, got " & $args.len)
  requireMap("Map/assoc", args[0])
  rejectCallerEnvEscape("Map/assoc", args[2])
  case args[0].kind
  of vkMap:
    var entries = copyEntries(args[0].mapEntries)
    let key = keySegment("Map/assoc", args[1])
    if args[2].kind == vkVoid:
      entries.del(key)
    else:
      entries[key] = args[2]
    newMap(entries, args[0].mapImmutable)
  of vkHashMap:
    var entries: seq[HashMapEntry]
    for entry in args[0].hashMapEntries:
      entries.add entry
    entries.add HashMapEntry(key: args[1], val: args[2])
    buildHashMap("Map/assoc", entries)
  else:
    raise newException(GeneError, "Map/assoc expects a Map")

proc biMapGet(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Map/get expects 2 arguments, got " & $args.len)
  requireMap("Map/get", args[0])
  case args[0].kind
  of vkMap:
    args[0].mapEntries.getOrDefault(keySegment("Map/get", args[1]), VOID)
  of vkHashMap:
    requireHashStableKey("Map/get", args[1])
    let idx = findHashMapKey(args[0].hashMapEntries, args[1])
    if idx >= 0: args[0].hashMapEntries[idx].val else: VOID
  else:
    VOID

proc requireRegex(name: string, value: Value) =
  if value.kind != vkRegex:
    raise newException(GeneError, name & " expects a Regex")

proc regexSlice(s: string, first, last: int): string =
  if first < 0 or first >= s.len or last < first:
    return ""
  s[first .. min(last, s.high)]

proc regexEndExclusive(first, last: int): int =
  if last < first: first else: last + 1

proc regexFindBounds(reVal: Value, s: string, start: int):
    tuple[found: bool, first, last: int,
          captures: seq[tuple[first, last: int]]] =
  when defined(geneWasm):
    raise newException(GeneError, "Regex operations are unavailable in wasm builds")
  else:
    let captureCount = reVal.regexGroupCount
    result.captures = newSeq[tuple[first, last: int]](captureCount)
    if start > s.len:
      return (false, -1, 0, result.captures)
    let bounds = nre.findBounds(s, reVal.regexCompiled, result.captures, start)
    if bounds.first < 0:
      return (false, -1, 0, result.captures)
    (true, bounds.first, bounds.last, result.captures)

proc regexMatchValue(reVal: Value, s: string, start: int,
                     matchType: Value):
    tuple[found: bool, value: Value, first, endExclusive: int] =
  let found = regexFindBounds(reVal, s, start)
  if not found.found:
    return (false, VOID, -1, start)

  var groups: seq[Value]
  for capture in found.captures:
    if capture.first < 0:
      groups.add NIL
    else:
      groups.add newStr(regexSlice(s, capture.first, capture.last))

  var namedEntries: seq[HashMapEntry]
  for name, index in reVal.regexGroupNames:
    if index >= 0 and index < groups.len:
      namedEntries.add HashMapEntry(key: newStr(name), val: groups[index])

  let endExclusive = regexEndExclusive(found.first, found.last)
  var props = initPropTable()
  props["text"] = newStr(regexSlice(s, found.first, found.last))
  props["groups"] = newList(groups, immutable = true)
  props["named"] = newHashMap(namedEntries)
  props["start"] = newInt(found.first)
  props["end"] = newInt(endExclusive)
  (true, newNode(matchType, props = props, immutable = true),
   found.first, endExclusive)

proc regexReplacementText(name: string, reVal: Value, s, tmpl: string,
                          first, last: int,
                          captures: seq[tuple[first, last: int]]): string =
  proc capture(index: int): string =
    if index == 0:
      return regexSlice(s, first, last)
    let captureIndex = index - 1
    if captureIndex < 0 or captureIndex >= captures.len:
      raise newException(GeneError,
        name & " replacement references missing capture: \\" & $index)
    let bounds = captures[captureIndex]
    if bounds.first < 0:
      return ""
    regexSlice(s, bounds.first, bounds.last)

  var i = 0
  while i < tmpl.len:
    let ch = tmpl[i]
    if ch != '\\':
      result.add ch
      inc i
      continue
    inc i
    if i >= tmpl.len:
      raise newException(GeneError, name & " replacement has trailing backslash")
    case tmpl[i]
    of '\\':
      result.add '\\'
      inc i
    of '0'..'9':
      var index = 0
      while i < tmpl.len and tmpl[i] in {'0'..'9'}:
        index = index * 10 + (ord(tmpl[i]) - ord('0'))
        inc i
      result.add capture(index)
    of 'k':
      inc i
      if i >= tmpl.len or tmpl[i] != '<':
        raise newException(GeneError,
          name & " replacement named backref must use \\k<name>")
      inc i
      let nameStart = i
      while i < tmpl.len and tmpl[i] != '>':
        inc i
      if i >= tmpl.len:
        raise newException(GeneError,
          name & " replacement named backref is missing '>'")
      let captureName = tmpl[nameStart ..< i]
      inc i
      let names = reVal.regexGroupNames
      if not names.hasKey(captureName):
        raise newException(GeneError,
          name & " replacement references unknown capture: " & captureName)
      result.add capture(names[captureName] + 1)
    else:
      raise newException(GeneError,
        name & " replacement has unsupported escape: \\" & tmpl[i])

proc regexReplace(name: string, reVal: Value, s, tmpl: string,
                  replaceAll: bool): string =
  var start = 0
  var prev = 0
  while start <= s.len:
    let found = regexFindBounds(reVal, s, start)
    if not found.found:
      break
    result.add s[prev ..< found.first]
    result.add regexReplacementText(name, reVal, s, tmpl,
                                    found.first, found.last, found.captures)
    let endExclusive = regexEndExclusive(found.first, found.last)
    if not replaceAll:
      prev = endExclusive
      break
    if endExclusive == found.first:
      if found.first < s.len:
        result.add s[found.first]
        prev = found.first + 1
        start = prev
      else:
        prev = found.first
        start = s.len + 1
    else:
      prev = endExclusive
      start = endExclusive
  result.add s[prev ..< s.len]

proc biRegex(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "Regex expects 1 pattern argument, got " & $args.len)
  requireStr("Regex pattern", args[0])
  var flags = ""
  if call != nil:
    for i, name in call[].namedNames:
      if name != "flags":
        raise newException(GeneError, "Regex got unexpected named argument: " & name)
      if call[].namedValues[i].kind != vkString:
        raise newException(GeneError, "Regex ^flags expects a Str")
      flags = call[].namedValues[i].strVal
  newRegex(args[0].strVal, flags)

proc biRegexMatch(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "regex/match expects 2 arguments, got " & $args.len)
  requireRegex("regex/match receiver", args[0])
  requireStr("regex/match input", args[1])
  let scope = if call == nil: nil else: call.dispatchScope
  let matched = regexMatchValue(args[0], args[1].strVal, 0,
                                builtInTypeHead(scope, "Match"))
  if matched.found: matched.value else: VOID

proc pullRegexFindAll(stream: Value): StreamPullResult {.nimcall.} =
  let stateCell = stream.streamSource
  if stateCell.kind != vkCell:
    return StreamPullResult(has: false, item: NIL)
  let state = stateCell.cellValue
  if state.kind != vkList or state.listItems.len != 4:
    return StreamPullResult(has: false, item: NIL)
  let reVal = state.listItems[0]
  let input = state.listItems[1]
  let startVal = state.listItems[2]
  let matchType = state.listItems[3]
  if reVal.kind != vkRegex or input.kind != vkString or startVal.kind != vkInt:
    return StreamPullResult(has: false, item: NIL)
  let s = input.strVal
  let start =
    if startVal.intFitsInt64: int(startVal.intVal)
    else: s.len + 1
  if start > s.len:
    return StreamPullResult(has: false, item: NIL)
  let matched = regexMatchValue(reVal, s, start, matchType)
  if not matched.found:
    stateCell.setCellValue(newList(@[reVal, input, newInt(s.len + 1), matchType]))
    return StreamPullResult(has: false, item: NIL)
  let nextStart =
    if matched.endExclusive > matched.first: matched.endExclusive
    elif matched.first < s.len: matched.first + 1
    else: s.len + 1
  stateCell.setCellValue(newList(@[reVal, input, newInt(nextStart), matchType]))
  StreamPullResult(has: true, item: matched.value)

proc biRegexFindAll(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "regex/find_all expects 2 arguments, got " & $args.len)
  requireRegex("regex/find_all receiver", args[0])
  requireStr("regex/find_all input", args[1])
  let scope = if call == nil: nil else: call.dispatchScope
  let matchType = builtInTypeHead(scope, "Match")
  let state = newCell(newList(@[args[0], args[1], newInt(0), matchType]))
  newLazyStream(state, pullRegexFindAll)

proc biRegexReplace(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "regex/replace expects 3 arguments, got " & $args.len)
  requireRegex("regex/replace receiver", args[0])
  requireStr("regex/replace input", args[1])
  requireStr("regex/replace template", args[2])
  newStr(regexReplace("regex/replace", args[0], args[1].strVal,
                      args[2].strVal, replaceAll = false))

proc biRegexReplaceAll(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "regex/replace_all expects 3 arguments, got " & $args.len)
  requireRegex("regex/replace_all receiver", args[0])
  requireStr("regex/replace_all input", args[1])
  requireStr("regex/replace_all template", args[2])
  newStr(regexReplace("regex/replace_all", args[0], args[1].strVal,
                      args[2].strVal, replaceAll = true))

proc biRegexSplit(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "regex/split expects 2 arguments, got " & $args.len)
  requireRegex("regex/split receiver", args[0])
  requireStr("regex/split input", args[1])
  when defined(geneWasm):
    raise newException(GeneError, "Regex operations are unavailable in wasm builds")
  else:
    var items: seq[Value]
    for part in nre.split(args[1].strVal, args[0].regexCompiled):
      items.add newStr(part)
    newList(items)

proc biNodeSetPropBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "Node/set_prop! expects 3 arguments, got " & $args.len)
  requireNode("Node/set_prop!", args[0])
  rejectCallerEnvEscape("Node/set_prop!", args[2])
  args[0].setNodeProp(keySegment("Node/set_prop!", args[1]), args[2])
  args[2]

proc biNodeSetBodyBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "Node/set_body! expects 2 arguments, got " & $args.len)
  requireNode("Node/set_body!", args[0])
  if args[1].kind != vkList:
    raise newException(GeneError, "Node/set_body! expects a List")
  rejectCallerEnvEscape("Node/set_body!", args[1])
  args[0].setNodeBody(args[1].listItems)
  args[1]

proc biNodePushBodyBang(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "Node/push_body! expects 2 arguments, got " & $args.len)
  requireNode("Node/push_body!", args[0])
  rejectCallerEnvEscape("Node/push_body!", args[1])
  args[0].pushNodeBody(args[1])
  args[1]

proc requireBuffer(name: string, value: Value) =
  if value.kind != vkBuffer:
    raise newException(GeneError, name & " expects a Buffer")

proc requireDeviceBuffer(name: string, value: Value) =
  if value.kind != vkDeviceBuffer:
    raise newException(GeneError, name & " expects a Device/Buffer")

proc bufferTypeExprArg(name: string, value: Value): Value =
  if value.kind == vkNode and value.head.isSymbol("c_abi_type") and
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
  rejectCallerEnvEscape("Buffer/set!", item)
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
  requireOne("Buffer/elem_type", args)
  requireBuffer("Buffer/elem_type", args[0])
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
  let elemType = closeTypeExpr(bufferTypeExprArg("Device/buffer elem_type", args[2]),
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
  requireOne("Device/Buffer/elem_type", args)
  requireDeviceBuffer("Device/Buffer/elem_type", args[0])
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
      let message = protocol.protocolMessages["to_str"]
      let implFn = resolveProtocolMessage(scope, message, v)
      var callArgs = [v]
      let rendered = applyCall(implFn, callArgs, NamedArgs(), scope)
      if rendered.kind != vkString:
        raiseTypeError("ToStr/to_str", "Str", rendered, scope)
      return rendered.strVal
  print(v)

proc biToStr(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("to_str", args)
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

when defined(geneWasm):
  # Under the wasm profile there is no useful process stdout; `print`/`println`
  # append to a per-eval buffer the host reads through the ABI (docs/wasm.md
  # §A.4 `gene_result_out_*`). `geneWasmCapture` is nil outside an eval so
  # startup prints (if any) are harmless.
  var geneWasmCapture*: ref string = nil
  proc geneWasmEmit(s: string) =
    if geneWasmCapture != nil: geneWasmCapture[].add s
    else: stdout.write s

  var geneWasmLogWriterReady = false
  proc ensureGeneWasmLogWriter*() =
    ## Route diagnostics to the host capture buffer. Installed lazily rather
    ## than from a module-init statement: under Emscripten, closures allocated
    ## during NimMain's global-init phase are not safely callable later (the
    ## same hazard as the symbol-intern crash), which showed up as an OOB
    ## fault on the second eval that emitted a log record.
    if geneWasmLogWriterReady:
      return
    geneWasmLogWriterReady = true
    setLogHostWriter(proc(s: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        geneWasmEmit(s))

proc biPrint(args: openArray[Value]): Value {.nimcall.} =
  var parts: seq[string]
  for a in args: parts.add displayStr(a)
  when defined(geneWasm): geneWasmEmit(parts.join(" "))
  else: stdout.write parts.join(" ")
  NIL

proc biPrintln(args: openArray[Value]): Value {.nimcall.} =
  var parts: seq[string]
  for a in args: parts.add displayStr(a)
  when defined(geneWasm):
    geneWasmEmit(parts.join(" "))
    geneWasmEmit("\n")
  else:
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
    if currentFiberActive:
      var se: ref SuspendError
      new(se)
      se.timer = true
      se.deadline = getMonoTime()
      raise se
    discard schedulerRunOne(skipWorkerSafe = false)
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

proc isDynamicFfiScalarParamLabel(label: string): bool =
  label in [
    "C/Bool", "C/Char", "C/UChar", "C/UInt64", "C/ULong", "C/PtrDiff",
    "C/Int", "C/UInt", "C/UInt32", "C/UInt16", "C/UShort", "C/UInt8",
    "C/Int16", "C/Short", "C/Int8", "C/Int32", "C/Long", "C/Int64",
    "C/Size", "C/Double", "C/Float"
  ]

proc dynamicFfiCompositeHead(expr: Value): string =
  if expr.kind == vkNode and expr.props.len == 0 and expr.meta.len == 0:
    typeExprLabel(expr.head)
  else:
    ""

proc isDynamicFfiPointerParamType(expr: Value): bool =
  expr.kind == vkNode and expr.props.len == 0 and expr.meta.len == 0 and
    expr.body.len == 1 and dynamicFfiCompositeHead(expr) in [
      "C/Ptr", "C/NullablePtr", "C/ConstPtr", "C/NullableConstPtr",
      "C/OwnedPtr"
    ]

proc isDynamicFfiSliceParamType(expr: Value): bool =
  expr.kind == vkNode and expr.props.len == 0 and expr.meta.len == 0 and
    expr.body.len == 1 and dynamicFfiCompositeHead(expr) == "C/Slice"

proc isDynamicFfiBufferParamType(expr: Value): bool =
  expr.kind == vkNode and expr.props.len == 0 and expr.meta.len == 0 and
    expr.body.len == 1 and dynamicFfiCompositeHead(expr) == "Buffer"

proc isDynamicFfiReturnType(expr: Value, label: string): bool =
  label == "C/Void" or label == "C/CStr" or
    isDynamicFfiScalarParamLabel(label) or isDynamicFfiPointerParamType(expr)

proc isSupportedDynamicFfiSignature(params: openArray[Value],
                                    returnType: Value): bool =
  let returnLabel = typeExprLabel(returnType)
  if not isDynamicFfiReturnType(returnType, returnLabel):
    return false
  case params.len
  of 0:
    true
  of 1:
    let p = typeExprLabel(params[0])
    p == "C/CStr" or isDynamicFfiScalarParamLabel(p) or
      isDynamicFfiPointerParamType(params[0]) or
      isDynamicFfiSliceParamType(params[0]) or
      isDynamicFfiBufferParamType(params[0])
  of 2:
    let a = typeExprLabel(params[0])
    let b = typeExprLabel(params[1])
    (a == "C/CStr" and b in ["C/CStr", "C/Int", "C/Size"]) or
      (a == "C/Int" and b in ["C/Int", "C/Double", "C/Float"]) or
      (a == "C/Double" and b in ["C/Double", "C/Int"]) or
      (a == "C/Float" and b in ["C/Float", "C/Int"]) or
      (a == "C/Size" and b == "C/Size") or
      (isDynamicFfiPointerParamType(params[0]) and
        (b == "C/Size" or isDynamicFfiPointerParamType(params[1])))
  of 3:
    isDynamicFfiPointerParamType(params[0]) and
      ((typeExprLabel(params[1]) == "C/Int" and
        typeExprLabel(params[2]) == "C/Size") or
       (isDynamicFfiPointerParamType(params[1]) and
        typeExprLabel(params[2]) == "C/Size"))
  else:
    false

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
  var paramLabels: seq[string]
  for param in args[2].listItems:
    paramLabels.add typeExprLabel(param)
  let returnLabel = typeExprLabel(args[3])
  if not isSupportedDynamicFfiSignature(args[2].listItems, args[3]):
    raise newException(GeneError,
      "unsupported dynamic FFI signature for '" & symbol & "': [" &
      paramLabels.join(",") & "] -> " & returnLabel)
  let address = symAddr(cast[LibHandle](args[0].ffiLibraryHandle),
                        symbol.cstring)
  if address == nil:
    raise newException(GeneError, "ffi/bind symbol not found: " & symbol)
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
  if releaseAddress != nil and not returnLabel.startsWith("(C/OwnedPtr "):
    raise newException(GeneError,
      "ffi/bind release symbol is only valid for C/OwnedPtr results")
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

proc requireString(name: string, value: Value) =
  if value.kind != vkString:
    raise newException(GeneError, name & " expects a Str")

proc biCapabilityName(args: openArray[Value]): Value {.nimcall.} =
  requireOne("Capability/name", args)
  requireCapability("Capability/name", args[0])
  newStr(args[0].capabilityName)

proc requireFsReadDir(name: string, value: Value) =
  requireCapability(name, value)
  let cap = value.capabilityName
  if cap != "Fs/ReadDir" and cap != "Fs/ReadWriteDir":
    raise newException(GeneError, name & " expects Fs/ReadDir authority")

proc requireFsWriteDir(name: string, value: Value) =
  requireCapability(name, value)
  let cap = value.capabilityName
  if cap != "Fs/WriteDir" and cap != "Fs/ReadWriteDir":
    raise newException(GeneError, name & " expects Fs/WriteDir authority")

proc requireNetConnect(name: string, value: Value) =
  requireCapability(name, value)
  if value.capabilityName != "Net/Connect":
    raise newException(GeneError, name & " expects Net/Connect authority")

proc requirePort(name: string, value: Value): int =
  let raw = requireInt64(name, value)
  if raw < 1 or raw > 65535:
    raise newException(GeneError, name & " expects a TCP port in 1..65535")
  int(raw)

proc requirePositiveInt(name: string, value: Value): int =
  let raw = requireInt64(name, value)
  if raw < 1 or raw > int32.high:
    raise newException(GeneError, name & " expects a positive Int")
  int(raw)

proc completedReadTextTask(path: string): Value =
  try:
    newCompletedTask(newStr(readFile(path)))
  except CatchableError as e:
    newFailedTask("Fs/read_text_async failed: " & e.msg)

proc completedWriteTextTask(path, text: string): Value =
  try:
    writeFile(path, text)
    newCompletedTask(NIL)
  except CatchableError as e:
    newFailedTask("Fs/write_text_async failed: " & e.msg)

proc tcpReadText(host: string, port, maxBytes, timeoutMs: int): string =
  let socket = newSocket()
  try:
    socket.connect(host, Port(port), timeoutMs)
    socket.recv(maxBytes, timeoutMs)
  finally:
    socket.close()

proc completedTcpReadTextTask(host: string, port, maxBytes,
                              timeoutMs: int): Value =
  try:
    newCompletedTask(newStr(tcpReadText(host, port, maxBytes, timeoutMs)))
  except CatchableError as e:
    newFailedTask("Net/tcp_read_text_async failed: " & e.msg)

proc tcpWriteText(host: string, port: int, text: string, timeoutMs: int) =
  let socket = newSocket()
  try:
    socket.connect(host, Port(port), timeoutMs)
    socket.send(text)
  finally:
    socket.close()

proc completedTcpWriteTextTask(host: string, port: int, text: string,
                               timeoutMs: int): Value =
  try:
    tcpWriteText(host, port, text, timeoutMs)
    newCompletedTask(NIL)
  except CatchableError as e:
    newFailedTask("Net/tcp_write_text_async failed: " & e.msg)

proc asyncIoQueueFullTask(name: string): Value =
  newFailedTask(name & " failed: async I/O queue full")

proc biFsReadTextAsync(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "Fs/read_text_async expects 2 arguments, got " & $args.len)
  requireFsReadDir("Fs/read_text_async", args[0])
  requireString("Fs/read_text_async path", args[1])
  let path = args[1].strVal
  let task = newExternalTask()
  case enqueueAsyncReadText(path, task)
  of aioQueued:
    task
  of aioUnavailable:
    completedReadTextTask(path)
  of aioQueueFull:
    asyncIoQueueFullTask("Fs/read_text_async")

proc biFsWriteTextAsync(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "Fs/write_text_async expects 3 arguments, got " & $args.len)
  requireFsWriteDir("Fs/write_text_async", args[0])
  requireString("Fs/write_text_async path", args[1])
  requireString("Fs/write_text_async text", args[2])
  let path = args[1].strVal
  let text = args[2].strVal
  let task = newExternalTask()
  case enqueueAsyncWriteText(path, text, task)
  of aioQueued:
    task
  of aioUnavailable:
    completedWriteTextTask(path, text)
  of aioQueueFull:
    asyncIoQueueFullTask("Fs/write_text_async")

proc biNetTcpReadTextAsync(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 5:
    raise newException(GeneError,
      "Net/tcp_read_text_async expects 5 arguments, got " & $args.len)
  requireNetConnect("Net/tcp_read_text_async", args[0])
  requireString("Net/tcp_read_text_async host", args[1])
  let host = args[1].strVal
  let port = requirePort("Net/tcp_read_text_async port", args[2])
  let maxBytes = requirePositiveInt("Net/tcp_read_text_async max_bytes",
                                    args[3])
  let timeoutMs = requirePositiveInt("Net/tcp_read_text_async timeout_ms",
                                     args[4])
  let task = newExternalTask()
  case enqueueAsyncTcpReadText(host, port, maxBytes, timeoutMs, task)
  of aioQueued:
    task
  of aioUnavailable:
    completedTcpReadTextTask(host, port, maxBytes, timeoutMs)
  of aioQueueFull:
    asyncIoQueueFullTask("Net/tcp_read_text_async")

proc biNetTcpWriteTextAsync(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 5:
    raise newException(GeneError,
      "Net/tcp_write_text_async expects 5 arguments, got " & $args.len)
  requireNetConnect("Net/tcp_write_text_async", args[0])
  requireString("Net/tcp_write_text_async host", args[1])
  let host = args[1].strVal
  let port = requirePort("Net/tcp_write_text_async port", args[2])
  requireString("Net/tcp_write_text_async text", args[3])
  let text = args[3].strVal
  let timeoutMs = requirePositiveInt("Net/tcp_write_text_async timeout_ms",
                                     args[4])
  let task = newExternalTask()
  case enqueueAsyncTcpWriteText(host, port, text, timeoutMs, task)
  of aioQueued:
    task
  of aioUnavailable:
    completedTcpWriteTextTask(host, port, text, timeoutMs)
  of aioQueueFull:
    asyncIoQueueFullTask("Net/tcp_write_text_async")

proc biRuntimeGcStats(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "Runtime/gc_stats expects no arguments")
  var entries = initPropTable()
  entries["live_managed"] = newInt(managedLiveCount())
  entries["rc_stats?"] =
    when defined(geneRcStats):
      TRUE
    else:
      FALSE
  let scheduler = currentScheduler()
  withSchedulerLock(scheduler):
    entries["supervisor_retry_pending"] =
      newInt(scheduler.supervisorRetries.len - scheduler.supervisorRetryHead)
    entries["supervisor_retry_capacity"] =
      newInt(supervisorFailureRetryCapacity)
    entries["supervisor_retry_high_water"] =
      newInt(scheduler.supervisorRetryHighWater)
    entries["supervisor_retry_drops"] =
      newIntFromDecimal($scheduler.supervisorRetryDrops)
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
  newNode(newSym("c_abi_type"), body = @[newSym(name)])

proc ffiTypeValue(name: string): Value =
  newNode(newSym("ffi_type"), body = @[newSym(name)])

proc runReplSessionForEnv*(env: Value,
                           readLine: ReplReadLine,
                           writeOut: ReplWrite,
                           writeErr: ReplWrite,
                           options: ReplOptions): int
proc incrementalReplScopeForEnv*(env: Value): Scope
proc run*(chunk: Chunk, scope: Scope,
          validateImplRequirements = true): Value

include ./stdlib

proc biNew(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (new T args... ^named...) — explicit constructor invocation (design
  ## §7.1.1). Runs the type's ctor when one is defined: pre-created `self`,
  ## function-style argument matching, then schema validation. Without a
  ## ctor, falls back to the same direct schema mapping as `(T ...)`.
  if args.len < 1:
    raise newException(GeneError, "new expects a Type argument")
  let callee = args[0]
  if callee.kind != vkType:
    raise newException(GeneError,
      "new expects a Type as its first argument, got " & $callee.kind)
  if callee.isEnumType:
    raise newException(GeneError,
      "enum " & callee.typeName & " is not directly constructible; use a variant")
  var named = NamedArgs()
  var dispatchScope: Scope = nil
  var site = NIL
  if call != nil:
    named = NamedArgs(names: call[].namedNames, values: call[].namedValues)
    dispatchScope = call[].dispatchScope
    site = call[].site
  if callee.typeCtor.kind != vkNil:
    constructWithCtor(callee, args.toOpenArray(1, args.len - 1), named,
                      dispatchScope, site)
  else:
    constructTypedInstance(callee, args.toOpenArray(1, args.len - 1), named)

proc biConstructType(args: openArray[Value]): Value {.nimcall.} =
  ## Data-driven direct construction. This is the runtime-map counterpart of
  ## `(T ^field value ...)`: it validates the same closed schema and never
  ## invokes a ctor. Registries can therefore retain real Gene Type values as
  ## their one schema instead of mirroring them in a string vocabulary.
  if args.len != 2:
    raise newException(GeneError, "construct_type expects (Type, Map)")
  let callee = args[0]
  if callee.kind != vkType:
    raise newException(GeneError,
      "construct_type expects a Type as its first argument")
  if callee.isEnumType:
    raise newException(GeneError,
      "construct_type does not construct enum types; use a variant")
  if args[1].kind != vkMap:
    raise newException(GeneError,
      "construct_type expects a Map as its second argument")
  var names: seq[string]
  var values: seq[Value]
  for name, value in args[1].mapEntries:
    names.add name
    values.add value
  constructTypedInstance(callee, [], NamedArgs(names: names, values: values))

proc biTypeFields(args: openArray[Value]): Value {.nimcall.} =
  ## Stable data reflection for a Type's closed property schema. Returning the
  ## original type expression keeps consumers such as schema derivation on the
  ## language's one type vocabulary instead of inventing string descriptors.
  if args.len != 1 or args[0].kind != vkType:
    raise newException(GeneError, "Type/fields expects a Type receiver")
  var fields: seq[Value]
  for field in args[0].typeFields:
    var props = initPropTable()
    props["name"] = newStr(field.name)
    props["optional"] = newBool(field.optional)
    props["type"] = field.typeExpr
    fields.add newMap(props)
  newList(fields)

proc biTypeName(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 1 or args[0].kind != vkType:
    raise newException(GeneError, "Type/name expects a Type receiver")
  newStr(args[0].typeName)

proc typeReflectionMessage(name: string): Value =
  case name
  of "fields": newNativeFn("Type/fields", biTypeFields)
  of "name": newNativeFn("Type/name", biTypeName)
  else: NIL

const bareOperatorNames = [
  # Operators are a closed, language-defined set (design §2.2): users cannot
  # declare them, so pre-binding them costs no name, and `($+ 1 2)` would be
  # noise. `$` is the concat/interpolation head.
  "+", "-", "*", "/", "<", "<=", ">", ">=", "==", "!=", "$",
]

const bareCoreNames = [
  # Language-level words rather than library functions. `panic` is the
  # unrecoverable-failure mechanism §9 reserves, and `not`/`same?` are spelled
  # forms of primitive operations (`!` and identity). Deliberately short: every
  # entry here is a name a program can no longer use freely.
  "panic", "not", "same?",
]

proc staysBare(name: string): bool =
  ## Case is the rule (design §2.1/§3): an uppercase name is a *type* — a type
  ## surface, an error type, or a type's message namespace — and stays bare
  ## because annotations resolve type names structurally, so `[xs : List]` must
  ## keep working. A lowercase name is a library function or namespace and moves
  ## under the `gene` root, reached as `$x`.
  if name.len == 0: return false
  if name[0] in {'A'..'Z'}: return true
  name in bareOperatorNames or name in bareCoreNames

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
  # Marker protocol (empty): a module-level instance whose type implements it
  # serializes by identity reference (serde, docs/serialization.md §7).
  let serdeRefProtocol = newProtocol("SerdeRef", [])
  result.define("SerdeRef", serdeRefProtocol)
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
  # SyntaxCall mirrors Call for fn! syntax calls (design §3): raw prop/body
  # syntax nodes instead of evaluated arguments.
  let syntaxCallType = newType("SyntaxCall", NIL,
                               @[
                                 TypeField(name: "named", optional: false,
                                           typeExpr: newSym("PropMap"),
                                           scope: result),
                                 TypeField(name: "site", optional: true,
                                           typeExpr: newSym("Node"),
                                           scope: result)
                               ],
                               @[], result, @[], @[],
                               @[
                                 TypeBodyField(rest: true,
                                               typeExpr: newSym("Any"),
                                               scope: result)
                               ])
  result.define("SyntaxCall", syntaxCallType)
  let callableProtocol = newProtocol("Callable", ["apply"])
  result.define("Callable", callableProtocol)
  let toStrProtocol = newProtocol("ToStr", ["to_str"])
  result.define("ToStr", toStrProtocol)
  var typeErrorFields: seq[TypeField]
  for name in ["message", "where", "expected", "actual"]:
    typeErrorFields.add TypeField(name: name, optional: false,
                                  typeExpr: newSym("Str"), scope: result)
  let typeError = newType("TypeError", NIL, typeErrorFields,
                          @[errorProtocol], result)
  result.define("TypeError", typeError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: typeError)
  # A send that resolves to a SyntaxCallable is a distinct dynamic call-kind
  # mismatch. It inherits TypeError's diagnostic fields and Error impl so
  # callers can catch it specifically without losing ordinary type matching.
  let callKindError = newType("CallKindError", typeError, @[], @[], result)
  result.define("CallKindError", callKindError)
  # A `~` send whose message resolves to no type-direct message or visible
  # protocol impl on the receiver is a recoverable MessageError (design §3/§9,
  # design §3/§9). It inherits TypeError so `catch (TypeError ...)` still
  # matches, and carries where/receiver_type/message diagnostics.
  let messageError = newType("MessageError", typeError, @[], @[], result)
  result.define("MessageError", messageError)
  let matchError = newType("MatchError", NIL,
                           @[TypeField(name: "message", optional: false,
                                       typeExpr: newSym("Str"), scope: result)],
                           @[errorProtocol], result)
  result.define("MatchError", matchError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: matchError)
  let selectorMissing = newType("SelectorMissing", matchError,
                                @[
                                  TypeField(name: "segment", optional: false,
                                            typeExpr: newSym("Any"), scope: result)
                                ],
                                @[], result)
  result.define("SelectorMissing", selectorMissing)
  let compileError = newType("CompileError", NIL,
                             @[TypeField(name: "message", optional: false,
                                         typeExpr: newSym("Str"), scope: result),
                               TypeField(name: "source", optional: true,
                                         typeExpr: newSym("Str"), scope: result),
                               TypeField(name: "line", optional: true,
                                         typeExpr: newSym("Int"), scope: result),
                               TypeField(name: "col", optional: true,
                                         typeExpr: newSym("Int"), scope: result),
                               TypeField(name: "contexts", optional: true,
                                         typeExpr: newSym("Any"), scope: result)],
                             @[errorProtocol], result)
  result.define("CompileError", compileError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: compileError)
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
  let matchType = newType("Match", NIL,
                          @[
                            TypeField(name: "text", optional: false,
                                      typeExpr: newSym("Str"), scope: result),
                            TypeField(name: "groups", optional: false,
                                      typeExpr: newNode(newSym("List"),
                                        body = @[newSym("Str?")]),
                                      scope: result),
                            TypeField(name: "named", optional: false,
                                      typeExpr: newNode(newSym("HashMap"),
                                        body = @[newSym("Str"), newSym("Str?")]),
                                      scope: result),
                            TypeField(name: "start", optional: false,
                                      typeExpr: newSym("Int"), scope: result),
                            TypeField(name: "end", optional: false,
                                      typeExpr: newSym("Int"), scope: result)
                          ],
                          @[], result)
  result.define("Match", matchType)
  let channelClosed = newType("ChannelClosed", NIL,
                              @[TypeField(name: "message", optional: false,
                                          typeExpr: newSym("Str"), scope: result)],
                              @[errorProtocol], result)
  result.define("ChannelClosed", channelClosed)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: channelClosed)
  let actorError = newType("ActorError", NIL,
                            @[TypeField(name: "message", optional: false,
                                        typeExpr: newSym("Str"), scope: result)],
                            @[errorProtocol], result)
  result.define("ActorError", actorError)
  result.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: actorError)
  let actorClosed = newType("ActorClosed", actorError, @[], @[], result)
  result.define("ActorClosed", actorClosed)
  let replyAlreadySent = newType("ReplyAlreadySent", actorError, @[], @[],
                                 result)
  result.define("ReplyAlreadySent", replyAlreadySent)
  let actorFailure = newType("ActorFailure", NIL,
                             @[
                               TypeField(name: "actor", optional: false,
                                         typeExpr: newSym("Any"), scope: result),
                               TypeField(name: "failed_message", optional: false,
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
                                receiver: actorFailure)
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
  result.define("rem", newNativeFn("rem", biRem))
  result.define("<", app.nativeLt)
  result.define(">", app.nativeGt)
  result.define("<=", app.nativeLe)
  result.define(">=", app.nativeGe)
  result.define("==", newNativeFn("==", biEq))
  result.define("!=", newNativeFn("!=", biNe))
  result.define("contains?", newNativeFn("contains?", biContains))
  result.define("same?", newNativeFn("same?", biSame))
  result.define("hash", newNativeFn("hash", biHash))
  result.define("not", newNativeFn("not", biNot))
  result.define("head", newNativeFn("head", biHead))
  result.define("props", newNativeFn("props", biProps))
  result.define("body", newNativeFn("body", biBody))
  result.define("meta", newNativeFn("meta", biMeta))
  result.define("new", newNativeCallFn("new", biNew))
  result.define("construct_type",
                newNativeFn("construct_type", biConstructType))
  result.define("to_str", newNativeCallFn("to_str", biToStr,
                                          acceptsNamed = false))
  result.define("chars", newNativeFn("chars", biChars))
  result.define("bytes", newNativeFn("bytes", biBytes))
  result.define("graphemes", newNativeFn("graphemes", biGraphemes))
  result.define("$", newNativeCallFn("$", biDollar, acceptsNamed = false))
  result.define("freeze_shallow", newNativeFn("freeze_shallow", biFreezeShallow))
  result.define("freeze", newNativeFn("freeze", biFreeze))
  result.define("thaw", newNativeFn("thaw", biThaw))
  result.define("key", newNativeFn("key", biSelectorKey))
  result.define("buffer", newNativeCallFn("buffer", biBuffer,
                                          acceptsNamed = false))
  result.define("Regex", newNativeCallFn("Regex", biRegex))
  let regexScope = newScope(result)
  regexScope.define("match", newNativeCallFn("regex/match", biRegexMatch,
                                             acceptsNamed = false))
  regexScope.define("find_all", newNativeCallFn("regex/find_all", biRegexFindAll,
                                                acceptsNamed = false))
  regexScope.define("replace", newNativeFn("regex/replace", biRegexReplace))
  regexScope.define("replace_all",
                    newNativeFn("regex/replace_all", biRegexReplaceAll))
  regexScope.define("split", newNativeFn("regex/split", biRegexSplit))
  result.define("regex", newNamespace("regex", regexScope))
  result.define("range", newNativeFn("range", biRange))
  let rangeScope = newScope(result)
  rangeScope.define("start", newNativeFn("Range/start", biRangeStart))
  rangeScope.define("stop", newNativeFn("Range/stop", biRangeStop))
  rangeScope.define("step", newNativeFn("Range/step", biRangeStep))
  rangeScope.define("inclusive?", newNativeFn("Range/inclusive?", biRangeInclusive))
  rangeScope.define("size", newNativeFn("Range/size", biRangeSize))
  result.define("Range", newNamespace("Range", rangeScope))
  result.define("date", newNativeFn("date", biDate))
  result.define("time", newNativeFn("time", biTime))
  result.define("datetime", newNativeFn("datetime", biDateTime))
  result.define("timezone", newNativeFn("timezone", biTimezone))
  result.define("duration", newNativeFn("duration", biDuration))
  result.define("today", newNativeFn("today", biToday))
  result.define("now", newNativeFn("now", biNow))
  let dateScope = newScope(result)
  dateScope.define("year", newNativeFn("Date/year", biDateYear))
  dateScope.define("month", newNativeFn("Date/month", biDateMonth))
  dateScope.define("day", newNativeFn("Date/day", biDateDay))
  result.define("Date", newNamespace("Date", dateScope))
  let timeScope = newScope(result)
  timeScope.define("hour", newNativeFn("Time/hour", biTimeHour))
  timeScope.define("minute", newNativeFn("Time/minute", biTimeMinute))
  timeScope.define("second", newNativeFn("Time/second", biTimeSecond))
  timeScope.define("microsecond", newNativeFn("Time/microsecond", biTimeMicrosecond))
  timeScope.define("offset", newNativeFn("Time/offset", biTimeOffset))
  timeScope.define("timezone", newNativeFn("Time/timezone", biTimeTimezone))
  result.define("Time", newNamespace("Time", timeScope))
  let dateTimeScope = newScope(result)
  dateTimeScope.define("year", newNativeFn("DateTime/year", biDateTimeYear))
  dateTimeScope.define("month", newNativeFn("DateTime/month", biDateTimeMonth))
  dateTimeScope.define("day", newNativeFn("DateTime/day", biDateTimeDay))
  dateTimeScope.define("hour", newNativeFn("DateTime/hour", biDateTimeHour))
  dateTimeScope.define("minute", newNativeFn("DateTime/minute", biDateTimeMinute))
  dateTimeScope.define("second", newNativeFn("DateTime/second", biDateTimeSecond))
  dateTimeScope.define("microsecond", newNativeFn("DateTime/microsecond", biDateTimeMicrosecond))
  dateTimeScope.define("offset", newNativeFn("DateTime/offset", biDateTimeOffset))
  dateTimeScope.define("timezone", newNativeFn("DateTime/timezone", biDateTimeTimezone))
  result.define("DateTime", newNamespace("DateTime", dateTimeScope))
  let timezoneScope = newScope(result)
  timezoneScope.define("offset", newNativeFn("Timezone/offset", biTimezoneOffset))
  timezoneScope.define("name", newNativeFn("Timezone/name", biTimezoneName))
  result.define("Timezone", newNamespace("Timezone", timezoneScope))
  let durationScope = newScope(result)
  durationScope.define("microseconds", newNativeFn("Duration/microseconds", biDurationMicroseconds))
  durationScope.define("milliseconds", newNativeFn("Duration/milliseconds", biDurationMilliseconds))
  durationScope.define("seconds", newNativeFn("Duration/seconds", biDurationSeconds))
  result.define("Duration", newNamespace("Duration", durationScope))
  result.define("Set", newNativeFn("Set", biSet))
  result.define("set_has?", newNativeFn("set_has?", biSetHas))
  result.define("set_size", newNativeFn("set_size", biSetSize))
  result.define("size", newNativeFn("size", biListSize))
  result.define("empty?", newNativeFn("empty?", biListEmpty))
  result.define("nil?", newNativeFn("nil?", biIsNil))
  result.define("void?", newNativeFn("void?", biIsVoid))
  result.define("absent?", newNativeFn("absent?", biIsAbsent))
  result.define("present?", newNativeFn("present?", biIsPresent))
  result.define("first", newNativeFn("first", biListFirst))
  result.define("last", newNativeFn("last", biListLast))
  let listScope = newScope(result)
  listScope.define("assoc", newNativeFn("List/assoc", biListAssoc))
  listScope.define("set!", newNativeFn("List/set!", biListSetBang))
  listScope.define("push!", newNativeFn("List/push!", biListPushBang))
  result.define("List", newNamespace("List", listScope))
  let mapScope = newScope(result)
  mapScope.define("assoc", newNativeFn("Map/assoc", biMapAssoc))
  mapScope.define("get", newNativeFn("Map/get", biMapGet))
  mapScope.define("put!", newNativeFn("Map/put!", biMapPutBang))
  result.define("Map", newNamespace("Map", mapScope))
  let nodeScope = newScope(result)
  nodeScope.define("set_prop!", newNativeFn("Node/set_prop!", biNodeSetPropBang))
  nodeScope.define("set_body!", newNativeFn("Node/set_body!", biNodeSetBodyBang))
  nodeScope.define("push_body!",
                   newNativeFn("Node/push_body!", biNodePushBodyBang))
  result.define("Node", newNamespace("Node", nodeScope))
  let bufferScope = newScope(result)
  bufferScope.define("len", newNativeFn("Buffer/len", biBufferLen))
  bufferScope.define("get", newNativeFn("Buffer/get", biBufferGet))
  bufferScope.define("set!", newNativeCallFn("Buffer/set!", biBufferSetBang,
                                             acceptsNamed = false))
  bufferScope.define("to_list", newNativeFn("Buffer/to_list", biBufferToList))
  bufferScope.define("elem_type", newNativeFn("Buffer/elem_type", biBufferElemType))
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
  deviceBufferScope.define("elem_type",
                           newNativeFn("Device/Buffer/elem_type",
                                       biDeviceBufferElemType))
  deviceScope.define("Buffer", newNamespace("Device/Buffer", deviceBufferScope))
  result.define("Device", newNamespace("Device", deviceScope))
  let capabilityScope = newScope(result)
  capabilityScope.define("name",
                         newNativeFn("Capability/name", biCapabilityName))
  result.define("Capability", newNamespace("Capability", capabilityScope))
  let runtimeScope = newScope(result)
  runtimeScope.define("gc_stats",
                      newNativeFn("Runtime/gc_stats", biRuntimeGcStats))
  result.define("Runtime", newNamespace("Runtime", runtimeScope))
  let fsScope = newScope(result)
  fsScope.define("ReadDir", newCapability("Fs/ReadDir"))
  fsScope.define("WriteDir", newCapability("Fs/WriteDir"))
  fsScope.define("ReadWriteDir", newCapability("Fs/ReadWriteDir"))
  fsScope.define("read_text_async", newNativeFn("Fs/read_text_async",
                                                biFsReadTextAsync))
  fsScope.define("write_text_async", newNativeFn("Fs/write_text_async",
                                                 biFsWriteTextAsync))
  result.define("Fs", newNamespace("Fs", fsScope))
  let netScope = newScope(result)
  netScope.define("Connect", newCapability("Net/Connect"))
  netScope.define("tcp_read_text_async",
                  newNativeFn("Net/tcp_read_text_async",
                              biNetTcpReadTextAsync))
  netScope.define("tcp_write_text_async",
                  newNativeFn("Net/tcp_write_text_async",
                              biNetTcpWriteTextAsync))
  result.define("Net", newNamespace("Net", netScope))
  result.define("cell", newNativeFn("cell", biCell))
  let cellScope = newScope(result)
  cellScope.define("get", newNativeFn("Cell/get", biCellGet))
  cellScope.define("set", newNativeFn("Cell/set", biCellSet))
  cellScope.define("swap", newNativeFn("Cell/swap", biCellSwap))
  cellScope.define("update", newNativeFn("Cell/update", biCellUpdate))
  result.define("Cell", newNamespace("Cell", cellScope))
  result.define("atomic_cell", newNativeFn("atomic_cell", biAtomicCell))
  let atomicCellScope = newScope(result)
  atomicCellScope.define("load", newNativeFn("AtomicCell/load", biAtomicCellLoad))
  atomicCellScope.define("store", newNativeFn("AtomicCell/store", biAtomicCellStore))
  atomicCellScope.define("swap", newNativeFn("AtomicCell/swap", biAtomicCellSwap))
  atomicCellScope.define("compare_exchange",
    newNativeFn("AtomicCell/compare_exchange", biAtomicCellCompareExchange))
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
  let tryRecvType = newEnum("TryRecv", @["T"],
    [(name: "empty", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "value", payloadTypes: @[newSym("T")],
      hasBacking: false, backing: NIL)],
    NIL, result)
  result.define("TryRecv", tryRecvType)
  let tryNextType = newEnum("TryNext", @["T", "E"],
    [(name: "exhausted", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "value", payloadTypes: @[newSym("T")],
      hasBacking: false, backing: NIL),
     (name: "error", payloadTypes: @[newSym("E")],
      hasBacking: false, backing: NIL)],
    NIL, result)
  result.define("TryNext", tryNextType)
  result.define("channel", newNativeCallFn("channel", biChannel))
  let channelScope = newScope(result)
  channelScope.define("send", newNativeCallFn("Channel/send", biChannelSend,
                                             acceptsNamed = false))
  channelScope.define("try_send", newNativeCallFn("Channel/try_send",
                                                 biChannelTrySend,
                                                 acceptsNamed = false))
  channelScope.define("recv", newNativeCallFn("Channel/recv", biChannelRecv,
                                             acceptsNamed = false))
  channelScope.define("try_recv", newNativeCallFn("Channel/try_recv",
                                                 biChannelTryRecv,
                                                 acceptsNamed = false))
  channelScope.define("close", newNativeCallFn("Channel/close", biChannelClose,
                                              acceptsNamed = false))
  result.define("Channel", newNamespace("Channel", channelScope))
  # A lowercase namespace holds functions; an uppercase one is a type's message
  # surface (design §3). So operations that act *on* an actor reference live on
  # `Actor` and are sent — `(a ~ send v)` — while the ones that take no receiver
  # stay functions under `actor`: `spawn` creates a reference, and `stop` /
  # `continue` are actor-body control signals.
  let actorTypeScope = newScope(result)
  actorTypeScope.define("send", newNativeCallFn("Actor/send", biActorSend,
                                                acceptsNamed = false))
  actorTypeScope.define("try_send", newNativeCallFn("Actor/try_send",
                                                    biActorTrySend,
                                                    acceptsNamed = false))
  actorTypeScope.define("ask", newNativeCallFn("Actor/ask", biActorAsk))
  actorTypeScope.define("snapshot", newNativeFn("Actor/snapshot",
                                                biActorSnapshot))
  actorTypeScope.define("upgrade", newNativeCallFn("Actor/upgrade",
                                                   biActorUpgrade))
  result.define("Actor", newNamespace("Actor", actorTypeScope))
  let actorScope = newScope(result)
  actorScope.define("spawn", newNativeCallFn("actor/spawn", biActorSpawn))
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
  envScope.define("extend", newNativeCallFn("Env/extend", biEnvExtend,
                                            acceptsNamed = false))
  envScope.define("snapshot", newNativeFn("Env/snapshot", biEnvSnapshot))
  result.define("Env", newNamespace("Env", envScope))
  result.define("read_one", newNativeCallFn("read_one", biReadOne,
                                            acceptsNamed = false))
  result.define("read_all", newNativeCallFn("read_all", biReadAll,
                                            acceptsNamed = false))
  result.define("lex_all", newNativeCallFn("lex_all", biLexAll,
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
  streamScope.define("try_next", newNativeCallFn("Stream/try_next", biStreamTryNext,
                                                 acceptsNamed = false))
  streamScope.define("close", newNativeFn("Stream/close", biStreamClose))
  result.define("Stream", newNamespace("Stream", streamScope))
  result.define("assoc_in", newNativeFn("assoc_in", biAssocIn))
  result.define("update_in", newNativeFn("update_in", biUpdateIn))
  result.define("panic", newNativeFn("panic", biPanic))
  result.define("sleep", newNativeFn("sleep", biSleep))
  result.define("print", newNativeFn("print", biPrint))
  result.define("println", newNativeFn("println", biPrintln))
  registerStdlibNamespaces(result)
  # The standard library lives under the unshadowable `gene` root and is reached
  # as `gene/x` or its `$x` sugar (design §2.1). Nothing else is pre-bound: a
  # bare name means whatever the program binds it to, so reading a name tells
  # you where it comes from. Operators stay bare — they are a closed,
  # language-defined set that users cannot declare anyway.
  let geneScope = newScope(result)
  for name, value in result.vars:
    geneScope.define(name, value)
  # Prune the lexical root to what `staysBare` keeps. GENE_BARE_BUILTINS=1
  # restores the old full surface; it exists only so the bare-name lint can be
  # collected against pre-migration sources.
  if getEnv("GENE_BARE_BUILTINS").len == 0:
    var bare: seq[(string, Value)]
    for name, value in result.vars:
      if staysBare(name):
        bare.add (name, value)
    result.vars.clear()
    for entry in bare:
      result.define(entry[0], entry[1])
  result.define("gene", newNamespace("gene", geneScope))
  # `genex` is an active, initially empty root for experimental/incubating
  # APIs; `geney`/`genez` stay reserved but undefined. All four are rejected in
  # binding position by the compiler (reservedStdlibRoots).
  result.define("genex", newNamespace("genex", newScope(result)))
  app.stdlib = geneScope

var gApplication: Application

proc normalizedDir(path: string): string =
  normalizedPath(absolutePath(if path.len > 0: path else: getCurrentDir()))

proc newSchedulerState(): SchedulerState =
  new(result)
  result.runQueue = newSeqOfCap[Fiber](schedulerSharedQueueInitialCap)
  result.waiters = newSeqOfCap[Fiber](schedulerSharedQueueInitialCap)
  result.askTimeouts = newSeqOfCap[AskTimeout](schedulerSharedQueueInitialCap)
  initLock(result.lock)
  when compileOption("threads") and defined(gcAtomicArc):
    initCond(result.workerCond)

proc newApplication*(entryDir = ""): Application =
  ## Create the runtime owner for one Gene program. MVP packages are represented
  ## by the root directory used for absolute/bare module resolution.
  let root = normalizedDir(entryDir)
  result = Application(moduleCache: initTable[string, Value](),
                       moduleLoading: initHashSet[string](),
                       moduleCompileHeaders:
                         initTable[string, ModuleCompileHeader](),
                       moduleCompileArtifacts:
                         initTable[string, ModuleCompileArtifact](),
                       moduleCompileLoading: initHashSet[string](),
                       implScopeIndex:
                         initTable[tuple[receiver, message: uint64], seq[Scope]](),
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

proc trackBaseScope(app: Application, scope: Scope) =
  ## Make `scope` enumerable for module reload. Reload walks `baseScopes` only to
  ## re-validate scoped/imported impls and rebuild the scope index, so the list
  ## must hold exactly the file-module base scopes (bindThisModule) and any other
  ## scope that actually carries a scoped/imported impl (addIndexedScope). A
  ## transient one-shot program scope registers neither and must stay collectable
  ## — retaining every `newGlobalScope` here leaked all scope-owned values for the
  ## app's lifetime. Dedup keeps a scope that is both a module base and an impl
  ## carrier from being listed twice; the list is small, so a linear scan is fine.
  for existing in app.baseScopes:
    if existing == scope:
      return
  app.baseScopes.add scope

proc newGlobalScope*(app: Application): Scope =
  ## A fresh program/module root scope. Its parent is the application's shared
  ## built-ins root, so declarations stay isolated while lookup falls through to
  ## built-ins with stable marker protocol/type identity. Enumerability for
  ## reload is granted lazily (see `trackBaseScope`), never here — a plain
  ## `run`/eval scope must be reclaimable once dropped.
  result = newScope(app.builtinsScope(), application = app)
  result.moduleRoot = true
  result.moduleStatic = true

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
  ## metadata and is exposed through the compiler-provided `this_mod` binding.
  let root = newNamespace(name, scope, path, moduleRoot = true)
  scope.moduleRoot = true
  scope.moduleStatic = true
  # A named module base is enumerable for reload (file modules, the reload
  # replacement, native modules). Already retained by moduleCache, so this adds
  # no lifetime beyond the module itself.
  scope.application().trackBaseScope(scope)
  result = newModule(name, root, path)
  scope.define("this_mod", result)

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

# --- URL module sources (design §15.9, experimental) ------------------------
#
# A module identity may be an https URL when the application was started via
# `gene runurl`. The canonical URL is the identity; every module-path import
# inside a URL module resolves RFC-3986-style against the importing module's
# URL, so a remote module can never name a local file. Relative references
# resolve against the *final* URL after redirects (see moduleSourceDir).

proc isUrlModulePath*(path: string): bool =
  path.startsWith("https://") or path.startsWith("http://")

proc urlOriginAndPath(url: string): tuple[origin, path: string] =
  ## Split "scheme://authority/path" into origin ("scheme://authority") and
  ## the absolute path (defaulting to "/").
  let authorityStart = url.find("://") + 3
  let slash = url.find('/', authorityStart)
  if slash < 0:
    (url, "/")
  else:
    (url[0 ..< slash], url[slash .. ^1])

proc urlHost(url: string): string =
  var authority = urlOriginAndPath(url).origin
  authority = authority[authority.find("://") + 3 .. ^1]
  if authority.len > 0 and authority[0] == '[':
    let close = authority.find(']')
    return if close >= 0: authority[0 .. close] else: authority
  let colon = authority.rfind(':')
  if colon >= 0: authority[0 ..< colon] else: authority

proc urlHostIsLocal(url: string): bool =
  urlHost(url) in ["localhost", "127.0.0.1", "[::1]"]

proc collapseUrlDotSegments(path: string): string =
  ## RFC 3986 §5.2.4 remove-dot-segments over an absolute URL path. `..`
  ## above the root clamps to the root, per the RFC.
  var segments: seq[string]
  for segment in path.split('/'):
    case segment
    of "", ".":
      discard
    of "..":
      if segments.len > 0:
        segments.setLen(segments.len - 1)
    else:
      segments.add segment
  "/" & segments.join("/")

proc resolveUrlRef(baseDirUrl, rawRef: string): string =
  ## Merge a module reference against a URL directory base per RFC 3986 §5.3:
  ## "/x" restarts at the origin; "./x", "../x", and bare "x" merge with the
  ## base directory path.
  let (origin, basePath) = urlOriginAndPath(baseDirUrl)
  if rawRef.startsWith("/"):
    return origin & collapseUrlDotSegments(rawRef)
  let dir = if basePath.endsWith("/"): basePath else: basePath & "/"
  origin & collapseUrlDotSegments(dir & rawRef)

proc urlModuleDir(url: string): string =
  ## Directory base of a module URL: origin plus the path up to the last '/'.
  let (origin, path) = urlOriginAndPath(url)
  let slash = path.rfind('/')
  origin & (if slash <= 0: "/" else: path[0 ..< slash])

proc validateModuleUrl(app: Application, url, rawPath: string): string =
  if not app.allowUrlModules:
    raise newException(GeneError,
      "URL module imports require a 'gene runurl' entry: " & rawPath)
  if url.contains('#') or url.contains('?'):
    raise newException(GeneError,
      "module URL must not carry a query or fragment: " & rawPath)
  if url.startsWith("http://") and not urlHostIsLocal(url):
    raise newException(GeneError,
      "module URLs require https (plain http is allowed for localhost only): " &
      rawPath)
  let (origin, path) = urlOriginAndPath(url)
  var normalized = origin & collapseUrlDotSegments(path)
  # MVP extension defaulting, applied to the URL's file segment.
  let slash = normalized.rfind('/')
  let last = normalized[slash + 1 .. ^1]
  if last.len > 0 and not last.contains('.'):
    normalized &= ".gene"
  normalized

proc resolveModulePath*(app: Application, rawPath: string): string =
  ## Normalize a `from "path"` string to a stable absolute module identity.
  if rawPath.isUrlModulePath:
    return app.validateModuleUrl(rawPath, rawPath)
  if app.currentModuleDir.isUrlModulePath:
    # Inside a remote module, every module-path import resolves against the
    # importing module's URL — a remote module can never name a local file.
    return app.validateModuleUrl(
      resolveUrlRef(app.currentModuleDir, rawPath), rawPath)
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

proc fetchUrlModuleSource(app: Application, url: string):
    tuple[finalUrl, body: string] =
  ## Fetch (or return the cached) source for a URL module identity. Both the
  ## compile-time macro-discovery phase and runtime initialization read
  ## through this cache, so each URL is fetched at most once per run.
  if app.urlSources.hasKey(url):
    return app.urlSources[url]
  if not app.allowUrlModules:
    raise newException(GeneError,
      "URL module imports require a 'gene runurl' entry: " & url)
  if app.currentModuleDir.isUrlModulePath and
      urlOriginAndPath(url).origin !=
        urlOriginAndPath(app.currentModuleDir).origin:
    # Cross-origin fetches print their provenance (design §15.9).
    stderr.writeLine "gene: fetching " & url
  var fetched = geneFetchModuleUrl(url)
  if fetched.finalUrl.len == 0:
    fetched.finalUrl = url
  if fetched.finalUrl != url and
      (not fetched.finalUrl.isUrlModulePath or
       (fetched.finalUrl.startsWith("http://") and
        not urlHostIsLocal(fetched.finalUrl))):
    raise newException(GeneError,
      "module URL redirected to a disallowed target: " & fetched.finalUrl)
  app.urlSources[url] = fetched
  fetched

proc moduleSourceDir(app: Application, absPath: string): string =
  ## The base directory used to resolve a module's own relative imports: the
  ## filesystem parent for file modules, or — for URL modules — the directory
  ## of the final URL after redirects, so a redirected module's relative
  ## imports follow its real location.
  if absPath.isUrlModulePath:
    urlModuleDir(app.fetchUrlModuleSource(absPath).finalUrl)
  else:
    parentDir(absPath)

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
  var entries = initPropTable()
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
    if pat.head.isSymbol("path"):
      return
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

proc resolvePatternPath(path: Value, scope: Scope): Value =
  if path.kind != vkNode or not path.head.isSymbol("path") or path.body.len == 0:
    return NIL
  if path.body[0].kind != vkSymbol:
    return NIL
  var current: Value
  if scope == nil or not scope.lookupOptional(path.body[0].symVal, current):
    return NIL
  for i in 1 ..< path.body.len:
    if path.body[i].kind != vkSymbol:
      return NIL
    let key = path.body[i].symVal
    case current.kind
    of vkType:
      if current.isEnumType:
        current = current.enumVariantDescriptor(key)
      else:
        let message = typeDirectMessage(current, key)
        current = if message.kind == vkNil: VOID else: message
    of vkNamespace:
      current = current.exportedBinding(key)
    of vkModule:
      current = current.moduleRootNamespace.exportedBinding(key)
    else:
      return NIL
    if current.kind == vkVoid:
      return NIL
  current

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
    if pat.head.isSymbol("path"):
      let resolved = resolvePatternPath(pat, scope)
      if resolved.kind == vkNil:
        raise newException(GeneError, "unknown pattern path: " & pat.print())
      return equal(resolved, target)
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
    if pat.head.kind == vkNode and pat.head.head.isSymbol("path"):
      let variant = resolvePatternPath(pat.head, scope)
      if variant.kind != vkEnumVariant:
        return false
      if target.enumValueVariant.bits != variant.bits:
        return false
      let items =
        if target.kind == vkNode and target.head.kind == vkEnumVariant:
          target.body
        else:
          newSeq[Value]()
      return matchSequence(pat.body, items, scope, binds)
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
  of vkSet:
    for it in coll.setItems: result.add it
  of vkHashMap:
    for entry in coll.hashMapEntries:
      result.add newList(@[entry.key, entry.val])
  of vkString:
    for r in coll.strVal.runes:
      result.add newChar(r)
  of vkStream:
    while coll.streamHasNext:
      result.add checkedStreamNext(coll, "for item")
  of vkRange:
    let stream = rangeStream(coll)
    while stream.streamHasNext:
      result.add checkedStreamNext(stream, "for item")
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
  of vkSet:
    newStream(copyItems(coll.setItems))
  of vkHashMap:
    var pairs: seq[Value]
    for entry in coll.hashMapEntries:
      pairs.add newList(@[entry.key, entry.val])
    newStream(pairs)
  of vkString:
    var chars: seq[Value]
    for r in coll.strVal.runes:
      chars.add newChar(r)
    newStream(chars)
  of vkStream:
    coll
  of vkRange:
    rangeStream(coll)
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

proc spGrow(stack: var seq[Value]) {.noinline.} =
  ## Cold path of runLoop's spush: extend working capacity. Every stack
  ## reaching here satisfies the all-zero invariant: slots in [len, capacity)
  ## hold zero bits (a valid nil Value). Growth within capacity is then just
  ## a length write; only a realloc exposes fresh garbage, and zeroing the
  ## new buffer to its full capacity re-establishes the invariant once per
  ## realloc instead of once per runLoop invocation (pooled stacks re-enter
  ## with len collapsed to 0 but capacity warm, so the invocation-hot first
  ## spush lands in the memset-free branch).
  ## Invariant holders: spop's move-out zeroes the source, spRelease
  ## NIL-assigns, setStackLenRaw shrinks over already-zeroed slots,
  ## releaseRunStack NIL-assigns the live region before pooling, and fresh
  ## seqs start with capacity 0. Any new out-of-band mutation of a run
  ## stack (add/setLen/insert) must grow through this proc.
  let oldLen = stack.len
  let newLen = max(oldLen * 2, 64)
  let oldCap = stack.capacity
  setLenUninit(stack, newLen)
  if newLen > oldCap:
    zeroMem(addr stack[oldLen], (stack.capacity - oldLen) * sizeof(Value))

proc spRelease(stack: var seq[Value], sp: var int, target: int) {.noinline.} =
  ## Cold path of runLoop's strunc: release abandoned live values above
  ## target. Balanced returns never get here.
  while sp > target:
    dec sp
    stack[sp] = NIL

template setStackLenRaw(stack: var seq[Value], n: int) =
  ## Direct length-field write for runLoop's escape normalization. Every
  ## slot in [n, len) is zeroed (spop moves out, spRelease NILs, spGrow
  ## zeroes realloc'd buffers to capacity), so no destructors are due —
  ## but both setLen and setLenUninit
  ## run the per-element destroy loop on shrink, which at ~64 dead slots
  ## per runLoop invocation dominated call-heavy workloads. Relies on the
  ## Nim 2 seqs-v2 layout (len is the first field of the seq struct).
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    static:
      doAssert sizeof(seq[Value]) == 2 * sizeof(int),
        "seqs-v2 {len, payload} layout assumption broken; fix setStackLenRaw"
    cast[ptr int](addr stack)[] = n
  else:
    stack.setLen(n)

const MaxRunStackPool = 64
const MaxFrameStackPool = 64
const MaxCallScopePool = 64

type
  VmPools = object
    ## Per-thread recycling pools for the frame-stack machinery. One threadvar
    ## object (instead of one per pool) so a pool operation resolves TLS once,
    ## and runLoop can cache `addr gVmPools` in a local and skip TLS entirely
    ## on its hot call/return paths. The address never escapes the invocation,
    ## so a suspended fiber resuming on another thread re-derives it safely.
    runStacks: array[MaxRunStackPool, seq[Value]]
    runStacksLen: int
    frameStacks: array[MaxFrameStackPool, seq[Frame]]
    frameStacksLen: int
    callScopes: array[MaxCallScopePool, Scope]
    callScopesLen: int

var gVmPools {.threadvar.}: VmPools

proc acquireRunStack(pools: var VmPools): seq[Value] {.inline.} =
  if pools.runStacksLen == 0:
    return @[]
  dec pools.runStacksLen
  result = move pools.runStacks[pools.runStacksLen]

proc acquireRunStack(): seq[Value] {.inline.} =
  acquireRunStack(gVmPools)

proc releaseRunStack(pools: var VmPools, stack: var seq[Value]) {.inline.} =
  ## NIL-assign the live region (drops refs and zeroes bits in one pass)
  ## instead of setLen(0)'s destroy loop, then collapse len directly:
  ## pooled stacks stay all-zero through their full capacity so spGrow can
  ## skip its growth memset. Balanced exits hand back len == 0, so the loop
  ## almost never runs; the yield-outside-generator error path is the one
  ## producer of a non-empty hand-back.
  for i in 0 ..< stack.len:
    stack[i] = NIL
  setStackLenRaw(stack, 0)
  if pools.runStacksLen < MaxRunStackPool:
    pools.runStacks[pools.runStacksLen] = move stack
    inc pools.runStacksLen

proc releaseRunStack(stack: var seq[Value]) {.inline.} =
  releaseRunStack(gVmPools, stack)

proc acquireFrameStack(pools: var VmPools): seq[Frame] {.inline.} =
  if pools.frameStacksLen == 0:
    return @[]
  dec pools.frameStacksLen
  result = move pools.frameStacks[pools.frameStacksLen]

proc acquireFrameStack(): seq[Frame] {.inline.} =
  acquireFrameStack(gVmPools)

proc releaseFrameStack(pools: var VmPools, frames: var seq[Frame]) {.inline.} =
  frames.setLen(0)
  if pools.frameStacksLen < MaxFrameStackPool:
    pools.frameStacks[pools.frameStacksLen] = move frames
    inc pools.frameStacksLen

proc releaseFrameStack(frames: var seq[Frame]) {.inline.} =
  releaseFrameStack(gVmPools, frames)

proc resetCallScopeSlots(scope: Scope, names: seq[string],
                         keepSlotNames = true) =
  ## Callers hand in either a fresh scope (slots empty; setLen zero-fills the
  ## growth) or a pooled one, which releaseCallScope returned to the all-NIL /
  ## no-defined-bits state — so sizing the slot array is enough; no explicit
  ## NIL pass. The resetSlots=false recur path relies on the same invariant.
  if scope.slots.len != names.len:
    scope.slots.setLen(names.len)
  scope.slotDefinedBits = 0
  if names.len > 64:
    scope.slotDefinedOverflow.setLen(names.len - 64)
  elif scope.slotDefinedOverflow.len != 0:
    scope.slotDefinedOverflow.setLen(0)
  if scope.slotTypes.len != 0:
    scope.slotTypes.setLen(0)
  if keepSlotNames:
    scope.slotNames = names
  elif scope.slotNames.len != 0:
    scope.slotNames.setLen(0)
    scope.slotMirror = false

proc seedFunctionProtocolEntry(scope: Scope, callee: Value) {.inline.} =
  ## Candidate entry identities belong to the compiled function value, not to
  ## its mutable module/REPL scope. Candidate-bearing functions are compiled
  ## with needsCallScope, so this never has to mutate the lexical parent.
  if scope != nil and callee.kind == vkFunction and scope != callee.fnScope:
    scope.entryProtocols = callee.fnProtocolEntries
    scope.entryProtocolsFrozen = true
  scope.varsDirty = false

proc resetCallScope(scope, parent: Scope, names: seq[string]) =
  scope.application =
    if parent != nil: parent.application
    else: nil
  scope.parent = parent
  scope.simpleCallScope = false
  scope.vars.clear()
  scope.varsDirty = false
  scope.varTypes.clear()
  scope.impls.setLen(0)
  scope.implOverlayRoot = false
  scope.implStageRoot = false
  scope.forceOverlayImpls = false
  scope.moduleRoot = false
  scope.moduleStatic = false
  scope.entryProtocols.setLen(0)
  scope.entryProtocolsFrozen = false
  scope.borrowedCallerEnv = parent != nil and parent.borrowedCallerEnv
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

proc acquireCallScope(pools: var VmPools, parent: Scope,
                      names: seq[string]): Scope =
  if pools.callScopesLen == 0:
    result = newScope(parent)
  else:
    dec pools.callScopesLen
    result = move pools.callScopes[pools.callScopesLen]
  result.resetCallScope(parent, names)

proc acquireCallScope(parent: Scope, names: seq[string]): Scope =
  acquireCallScope(gVmPools, parent, names)

proc acquireSimpleCallScope(pools: var VmPools, parent: Scope,
                            names: seq[string],
                            keepSlotNames = true,
                            resetSlots = true): Scope =
  # Only simpleCall functions (no opDefineName/opSetName, no opTaskScope,
  # no opSupervisor, no opSpawn, no opMakeFn that escapes the scope) reach
  # this path. That exclusion guarantees vars/varTypes/impls/ownsTasks/
  # ownedTasks/actor fields are never populated, so we skip their clearing
  # and only need to zero the slot array (done by resetCallScopeSlots).
  if pools.callScopesLen == 0:
    result = newScope(parent)
  else:
    dec pools.callScopesLen
    result = move pools.callScopes[pools.callScopesLen]
  result.application =
    if parent != nil: parent.application
    else: nil
  result.parent = parent
  result.simpleCallScope = true
  result.borrowedCallerEnv = parent != nil and parent.borrowedCallerEnv
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

proc acquireSimpleCallScope(parent: Scope, names: seq[string],
                            keepSlotNames = true,
                            resetSlots = true): Scope =
  acquireSimpleCallScope(gVmPools, parent, names, keepSlotNames, resetSlots)

proc bindSingleSimpleCallSlot(scope: Scope, slot: int, value: Value) {.inline.} =
  scope.slots[slot] = value
  if slot < 64:
    scope.slotDefinedBits = 1'u64 shl slot
  else:
    scope.markSlotDefined(slot)

proc bindSimpleCallSlots(scope: Scope, proto: FunctionProto,
                         args: openArray[Value]) {.inline.} =
  if args.len == 1:
    scope.bindSingleSimpleCallSlot(proto.positionalSlots[0], args[0])
    return
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
  proto.fastBindUnaryInt

proc canFastBindPositionalInt(proto: FunctionProto): bool {.inline.} =
  proto.fastBindPositionalInt

proc canFastBindRequiredNamed(proto: FunctionProto): bool {.inline.} =
  proto.fastBindRequiredNamed

proc checkedFrameReturnType(proto: FunctionProto, returnType: Value): Value {.inline.} =
  if proto.returnKnownBareInt:
    NIL
  else:
    returnType

proc frameNeedsImplValidation(proto: FunctionProto): bool {.inline.} =
  ## Pooled call scopes exclude opMakeType, the only instruction that appends
  ## required impl checks to a scope. Keep non-pooled scopes conservative.
  proto.needsCallScope and not proto.poolCallScope

proc bindUnaryIntCallScope(callee: Value, proto: FunctionProto,
                           arg: Value): Scope {.inline.} =
  let parent = callee.fnScope
  let paramMaySet = proto.positionalParamsMaySet
  result =
    if proto.poolCallScope:
      if paramMaySet:
        acquireCallScope(parent, proto.localNames)
      else:
        acquireSimpleCallScope(parent, proto.localNames,
          proto.callScopeNeedsSlotNames, proto.callScopeNeedsSlotReset)
    else:
      let fresh = newScope(parent)
      fresh.prepareSlots(proto.localNames)
      fresh
  let slot = proto.positionalSlots[0]
  if paramMaySet:
    result.defineFreshCallSlot(slot, arg)
    result.declareSlotType(slot, proto.paramTypes[0])
  else:
    result.bindSingleSimpleCallSlot(slot, arg)
  result.seedFunctionProtocolEntry(callee)

proc bindPositionalIntCallScope(callee: Value, proto: FunctionProto,
                                args: openArray[Value],
                                argsKnownBareInt = false): Scope {.inline.} =
  let parent = callee.fnScope
  let anyParamMaySet = proto.positionalParamsMaySet
  result =
    if proto.poolCallScope:
      if anyParamMaySet:
        acquireCallScope(parent, proto.localNames)
      else:
        acquireSimpleCallScope(parent, proto.localNames,
          proto.callScopeNeedsSlotNames, proto.callScopeNeedsSlotReset)
    else:
      let fresh = newScope(parent)
      fresh.prepareSlots(proto.localNames)
      fresh
  if anyParamMaySet:
    for i in 0 ..< args.len:
      let value = args[i]
      if not argsKnownBareInt and value.kind != vkInt:
        raiseTypeError("parameter '" & proto.params[i] & "'", "Int", value, result)
      let slot = proto.positionalSlots[i]
      result.defineFreshCallSlot(slot, value)
      result.declareSlotType(slot, proto.paramTypes[i])
  else:
    if not argsKnownBareInt:
      for i in 0 ..< args.len:
        let value = args[i]
        if value.kind != vkInt:
          raiseTypeError("parameter '" & proto.params[i] & "'", "Int", value, result)
    result.bindSimpleCallSlots(proto, args)
  result.seedFunctionProtocolEntry(callee)

proc findNamedArg(names: openArray[string], name: string): int {.inline.} =
  for i, key in names:
    if key == name:
      return i
  -1

proc bindRequiredNamedCallScope(callee: Value, proto: FunctionProto,
                                calleeName: string,
                                positional: openArray[Value],
                                namedNames: openArray[string],
                                namedValues: openArray[Value],
                                namedStart: int): Scope =
  let parent = callee.fnScope
  if positional.len != proto.params.len:
    raise newException(GeneError,
      "function '" & calleeName & "' expects " & $proto.requiredPositional & ".." &
      $proto.params.len & " argument(s), got " & $positional.len)
  for key in namedNames:
    var found = false
    for p in proto.namedParams:
      if p.arg == key:
        found = true
        break
    if not found:
      raise newException(GeneError,
        "function '" & calleeName & "' got unexpected named argument: " & key)
  for p in proto.namedParams:
    if findNamedArg(namedNames, p.arg) < 0:
      raise newException(GeneError,
        "function '" & calleeName & "' missing named argument: " & p.arg)

  result =
    if proto.poolCallScope:
      acquireCallScope(parent, proto.localNames)
    else:
      let fresh = newScope(parent)
      fresh.prepareSlots(proto.localNames)
      fresh
  result.seedFunctionProtocolEntry(callee)

  for i in 0 ..< positional.len:
    var value = positional[i]
    var declaredType = NIL
    if proto.hasParamTypes and i < proto.paramTypes.len and
        proto.paramTypes[i].kind != vkNil:
      declaredType = proto.paramTypes[i]
      if not (declaredType.isBareIntType and value.kind == vkInt):
        value = adaptBoundary("parameter '" & proto.params[i] & "'",
                              declaredType, value, result)
    result.defineFreshCallSlot(proto.positionalSlots[i], value)
    if declaredType.kind != vkNil:
      result.declareType(proto.params[i], declaredType)

  for i, p in proto.namedParams:
    let namedIndex = findNamedArg(namedNames, p.arg)
    var value = namedValues[namedStart + namedIndex]
    var declaredType = NIL
    if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
      declaredType = p.typeExpr
      if not (declaredType.isBareIntType and value.kind == vkInt):
        value = adaptBoundary("parameter '" & p.local & "'", declaredType,
                              value, result)
    result.defineFreshCallSlot(proto.namedSlots[i], value)
    if declaredType.kind != vkNil:
      result.declareType(p.local, declaredType)

proc bindRequiredNamedCallScope(callee: Value, proto: FunctionProto,
                                calleeName: string,
                                positional: openArray[Value],
                                named: NamedArgs): Scope =
  let parent = callee.fnScope
  if positional.len != proto.params.len:
    raise newException(GeneError,
      "function '" & calleeName & "' expects " & $proto.requiredPositional & ".." &
      $proto.params.len & " argument(s), got " & $positional.len)
  for key in named.names:
    var found = false
    for p in proto.namedParams:
      if p.arg == key:
        found = true
        break
    if not found:
      raise newException(GeneError,
        "function '" & calleeName & "' got unexpected named argument: " & key)
  for p in proto.namedParams:
    if named.argIndex(p.arg) < 0:
      raise newException(GeneError,
        "function '" & calleeName & "' missing named argument: " & p.arg)

  result =
    if proto.poolCallScope:
      acquireCallScope(parent, proto.localNames)
    else:
      let fresh = newScope(parent)
      fresh.prepareSlots(proto.localNames)
      fresh
  result.seedFunctionProtocolEntry(callee)

  for i in 0 ..< positional.len:
    var value = positional[i]
    var declaredType = NIL
    if proto.hasParamTypes and i < proto.paramTypes.len and
        proto.paramTypes[i].kind != vkNil:
      declaredType = proto.paramTypes[i]
      if not (declaredType.isBareIntType and value.kind == vkInt):
        value = adaptBoundary("parameter '" & proto.params[i] & "'",
                              declaredType, value, result)
    result.defineFreshCallSlot(proto.positionalSlots[i], value)
    if declaredType.kind != vkNil:
      result.declareType(proto.params[i], declaredType)

  for i, p in proto.namedParams:
    let namedIndex = named.argIndex(p.arg)
    var value = named.valueAt(namedIndex)
    var declaredType = NIL
    if proto.hasNamedParamTypes and p.typeExpr.kind != vkNil:
      declaredType = p.typeExpr
      if not (declaredType.isBareIntType and value.kind == vkInt):
        value = adaptBoundary("parameter '" & p.local & "'", declaredType,
                              value, result)
    result.defineFreshCallSlot(proto.namedSlots[i], value)
    if declaredType.kind != vkNil:
      result.declareType(p.local, declaredType)

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

proc releaseCallScope(pools: var VmPools, scope: Scope) =
  if scope == nil:
    return
  if scope.simpleCallScope:
    scope.clearDefinedCallSlots()
    if scope.slotTypes.len != 0:
      scope.slotTypes.setLen(0)
    scope.parent = nil
    scope.application = nil
    scope.evalBudget = nil
    scope.borrowedCallerEnv = false
    scope.moduleRoot = false
    scope.moduleStatic = false
    scope.entryProtocols.setLen(0)
    scope.entryProtocolsFrozen = false
    if scope.wildcardFallbacks.len != 0:
      scope.wildcardFallbacks.clear()
    if scope.exportExcludedNames.len != 0:
      scope.exportExcludedNames.clear()
    if pools.callScopesLen < MaxCallScopePool:
      pools.callScopes[pools.callScopesLen] = scope
      inc pools.callScopesLen
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
  if scope.wildcardFallbacks.len != 0:
    scope.wildcardFallbacks.clear()
  if scope.exportExcludedNames.len != 0:
    scope.exportExcludedNames.clear()
  scope.varsDirty = false
  if scope.varTypes.len != 0:
    scope.varTypes.clear()
  if scope.impls.len != 0:
    scope.impls.setLen(0)
  scope.implOverlayRoot = false
  scope.implStageRoot = false
  scope.forceOverlayImpls = false
  scope.moduleRoot = false
  scope.moduleStatic = false
  if scope.entryProtocols.len != 0:
    scope.entryProtocols.setLen(0)
  scope.entryProtocolsFrozen = false
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
  scope.borrowedCallerEnv = false
  if pools.callScopesLen < MaxCallScopePool:
    pools.callScopes[pools.callScopesLen] = scope
    inc pools.callScopesLen

proc releaseCallScope(scope: Scope) =
  releaseCallScope(gVmPools, scope)

proc qualifiedMessageName(message: Value): string =
  let owner = message.protocolMessageProtocol
  if owner.kind == vkProtocol:
    owner.protocolName & "/" & message.protocolMessageName
  else:
    message.protocolMessageName

proc resolveImplMessage(scope: Scope, protocol: Value,
                        protocolPath: openArray[string], name: string): Value =
  ## Resolve one impl-body message name against the target protocol's closure
  ## (docs/core.md §3.6.1). Qualified names (`A/do_x`, or `ns/A/do_x` for
  ## namespace-qualified owners) resolve through the named protocol's own
  ## messages; unqualified names must be unique in the closure.
  if protocolPath.len > 0:
    let spelled = protocolPath.join("/")
    var qualifier: Value
    if scope == nil or not scope.lookupOptional(protocolPath[0], qualifier):
      raise newException(GeneError,
        "impl message qualifier is not a protocol: " & spelled)
    for i in 1 ..< protocolPath.len:
      if qualifier.kind == vkModule:
        qualifier = qualifier.moduleRootNamespace
      qualifier = qualifier.exportedBinding(protocolPath[i])
    if qualifier.kind != vkProtocol:
      raise newException(GeneError,
        "impl message qualifier is not a protocol: " & spelled)
    let message = qualifier.protocolMessages.getOrDefault(name, NIL)
    if message.kind != vkProtocolMessage:
      raise newException(GeneError,
        "protocol " & spelled & " has no message: " & name)
    if not protocol.protocolClosureContains(message):
      raise newException(GeneError,
        "message " & spelled & "/" & name & " is not in protocol " &
        protocol.protocolName & "'s closure")
    return message
  let candidates = protocol.protocolClosureByName(name)
  if candidates.len == 0:
    raise newException(GeneError,
      "protocol " & protocol.protocolName & " has no message: " & name)
  if candidates.len > 1:
    var spellings: seq[string]
    for candidate in candidates:
      spellings.add qualifiedMessageName(candidate)
    raise newException(GeneError,
      "ambiguous message name '" & name & "' in impl body; qualify as one of: " &
      spellings.join(", "))
  candidates[0]

proc signatureTypeEqual(a, b: Value): bool =
  ## Omitted annotations and explicit Any have the same boundary meaning.
  let aAny = a.kind == vkNil or a.isSymbol("Any")
  let bAny = b.kind == vkNil or b.isSymbol("Any")
  (aAny and bAny) or equal(a, b)

proc callableSignatureMismatch(expected, actual: Value): string =
  if expected.kind != vkFunction or actual.kind != vkFunction:
    return "callable category"
  if expected.isSyntaxFn != actual.isSyntaxFn:
    return "callable category (fn versus fn!)"
  let expectedCode = expected.fnCode
  let actualCode = actual.fnCode
  if expectedCode == nil or actualCode == nil or
      not (expectedCode of FunctionProto) or not (actualCode of FunctionProto):
    return "callable implementation"
  let e = FunctionProto(expectedCode)
  let a = FunctionProto(actualCode)
  if e.params.len != a.params.len or
      e.requiredPositional != a.requiredPositional:
    return "positional parameter shape"
  if e.paramDefaults.len != a.paramDefaults.len:
    return "positional default shape"
  for i in 0 ..< e.paramDefaults.len:
    if e.paramDefaults[i].optional != a.paramDefaults[i].optional:
      return "positional default shape at parameter " & $(i + 1)
  if e.paramTypes.len != a.paramTypes.len:
    return "positional parameter types"
  for i in 0 ..< e.paramTypes.len:
    if not signatureTypeEqual(e.paramTypes[i], a.paramTypes[i]):
      return "positional parameter type at parameter " & $(i + 1)
  if (e.restParam.len != 0) != (a.restParam.len != 0):
    return "rest parameter shape"
  if e.namedParams.len != a.namedParams.len:
    return "named parameter shape"
  for i in 0 ..< e.namedParams.len:
    let ep = e.namedParams[i]
    let ap = a.namedParams[i]
    if ep.arg != ap.arg:
      return "named parameter name at parameter " & $(i + 1)
    if ep.defaultValue.optional != ap.defaultValue.optional:
      return "named parameter default shape for ^" & ep.arg
    if not signatureTypeEqual(ep.typeExpr, ap.typeExpr):
      return "named parameter type for ^" & ep.arg
  if not signatureTypeEqual(e.returnType, a.returnType):
    return "return type"
  if expected.fnChecksErrors != actual.fnChecksErrors:
    return "checked error row"
  let expectedErrors = expected.fnErrorTypes
  let actualErrors = actual.fnErrorTypes
  if expectedErrors.len != actualErrors.len:
    return "checked error row"
  for i in 0 ..< expectedErrors.len:
    if not equal(expectedErrors[i], actualErrors[i]):
      return "checked error row"
  ""

proc validateCallableSignature(expected, actual: Value, label: string) =
  let mismatch = callableSignatureMismatch(expected, actual)
  if mismatch.len == 0:
    return
  let expectedProto = FunctionProto(expected.fnCode)
  let actualProto = FunctionProto(actual.fnCode)
  var locations = ""
  let actualLoc = actualProto.sourceLoc.locationText()
  let expectedLoc = expectedProto.sourceLoc.locationText()
  if actualLoc.len > 0:
    locations.add " at " & actualLoc
  if expectedLoc.len > 0:
    locations.add "; inherited/declaration at " & expectedLoc
  raise newException(GeneError,
    label & " has incompatible " & mismatch & locations)

proc moduleRootScope(scope: Scope): Scope =
  var current = scope
  while current != nil:
    if current.moduleRoot:
      return current
    current = current.parent

proc stagingRoot(scope: Scope): Scope =
  var current = scope
  while current != nil:
    if current.implStageRoot:
      return current
    current = current.parent

proc hasOverlayRoot(scope: Scope): bool =
  var current = scope
  while current != nil:
    if current.implOverlayRoot:
      return true
    current = current.parent
  false

proc staticHomeRoot(scope: Scope): Scope =
  if scope == nil or not scope.moduleStatic:
    return nil
  scope.moduleRootScope()

proc fileModulePath(scope: Scope): string =
  let root = scope.moduleRootScope()
  if root == nil:
    return ""
  var module: Value
  if root.lookupOptional("this_mod", module) and module.kind == vkModule:
    return module.modulePath
  ""

proc classifyStandaloneImpl(scope: Scope, protocol, receiver: Value,
                            proto: ImplProto): ImplVisibility =
  if proto == nil or not proto.staticTopLevel or not proto.staticOperands or
      scope.hasOverlayRoot or scope.forceOverlayImpls:
    return ivOverlay
  let definingRoot = scope.moduleRootScope()
  let protocolRoot = protocol.protocolScope.staticHomeRoot()
  let receiverRoot = receiver.typeScope.staticHomeRoot()
  if definingRoot != nil and
      (definingRoot == protocolRoot or definingRoot == receiverRoot):
    ivCanonical
  else:
    ivScoped

proc classifyInlineImpl(scope: Scope, staticTopLevel: bool): ImplVisibility =
  if staticTopLevel and not scope.hasOverlayRoot and
      scope.moduleRootScope() != nil:
    ivCanonical
  else:
    ivOverlay

proc duplicateImplIn(scope: Scope, protocol, receiver: Value): bool =
  for impl in scope.impls:
    if same(impl.protocol, protocol) and same(impl.receiver, receiver):
      return true
  false

proc overlappingMessage(a, b: ProtocolImpl): Value =
  if not same(a.receiver, b.receiver):
    return NIL
  for left in a.messages:
    for right in b.messages:
      if left.message.bits == right.message.bits:
        return left.message
  NIL

proc sameImplMessages(a, b: ProtocolImpl): bool

proc validateImplConflict(existing, pending: ProtocolImpl,
                          identicalIsDuplicate = false): bool =
  ## Returns true only for an identical registration that an explicit scoped
  ## import may reuse. All other pair/message-identity overlap is rejected.
  if same(existing.protocol, pending.protocol) and
      same(existing.receiver, pending.receiver):
    if identicalIsDuplicate and existing.sameImplMessages(pending):
      return true
    raise newException(GeneError,
      "duplicate visible impl " & pending.protocol.protocolName &
      " for " & pending.receiver.typeName)
  let message = existing.overlappingMessage(pending)
  if message.kind != vkNil:
    raise newException(GeneError,
      "conflicting impls for message " & qualifiedMessageName(message) &
      " on " & pending.receiver.typeName)
  false

proc validateImplAgainstChain(scope: Scope, pending: ProtocolImpl,
                              identicalIsDuplicate = false): bool =
  var current = scope
  while current != nil:
    for existing in current.impls:
      if existing.validateImplConflict(pending, identicalIsDuplicate):
        return true
    current = current.parent
  false

proc addIndexedScope(app: Application, scope: Scope, impl: ProtocolImpl) =
  # A scope that carries a scoped/imported impl must be enumerable for reload's
  # index rebuild even when it is a plain program scope (e.g. a REPL/program that
  # ran `import_impl`), not just a file-module base. Dedup is safe here and makes
  # the rebuild pass — which re-calls this for scopes already listed — a no-op.
  app.trackBaseScope(scope)
  for entry in impl.messages:
    let key = (receiver: impl.receiver.bits, message: entry.message.bits)
    var scopes = app.implScopeIndex.getOrDefault(key)
    var present = false
    for existing in scopes:
      if existing == scope:
        present = true
        break
    if not present:
      scopes.add scope
      app.implScopeIndex[key] = scopes

proc affectedIndexedScopes(app: Application, impl: ProtocolImpl): seq[Scope] =
  for entry in impl.messages:
    let key = (receiver: impl.receiver.bits, message: entry.message.bits)
    for scope in app.implScopeIndex.getOrDefault(key):
      var present = false
      for existing in result:
        if existing == scope:
          present = true
          break
      if not present:
        result.add scope

proc registerImpl(scope: Scope, protocol, receiver: Value,
                  entries: sink seq[ImplMessage],
                  visibility = ivOverlay, exported = false) =
  if protocol.kind != vkProtocol:
    raise newException(GeneError, "impl target must be a protocol")
  if receiver.kind != vkType:
    raise newException(GeneError, "impl receiver must be a type")
  # Completeness is keyed by message identity. An explicit impl establishes
  # conformance; shared defaults fill only messages omitted by that impl.
  for message in protocol.protocolClosure:
    var count = 0
    for entry in entries:
      if entry.message.bits == message.bits:
        inc count
        let signatureFn = message.protocolMessageSignatureFn
        if signatureFn.kind != vkNil:
          validateCallableSignature(signatureFn, entry.fn,
            "impl " & protocol.protocolName & " for " & receiver.typeName &
            " message " & qualifiedMessageName(message))
    if count == 0:
      let defaultFn = message.protocolMessageDefaultFn
      if defaultFn.kind != vkNil:
        entries.add ImplMessage(message: message, fn: defaultFn)
      else:
        raise newException(GeneError,
          "impl " & protocol.protocolName & " for " & receiver.typeName &
          " is missing message: " & qualifiedMessageName(message))
    if count > 1:
      raise newException(GeneError,
        "duplicate impl message: " & qualifiedMessageName(message))
  if exported and visibility != ivScoped:
    let label = if visibility == ivCanonical: "canonical" else: "overlay"
    raise newException(GeneError, label & " impls cannot be exported")
  let pending = ProtocolImpl(protocol: protocol, receiver: receiver,
                             messages: entries, visibility: visibility,
                             exported: exported,
                             originPath: scope.fileModulePath())
  let stage = scope.stagingRoot()
  case visibility
  of ivCanonical:
    if stage != nil:
      discard stage.validateImplAgainstChain(pending)
      stage.impls.add pending
    else:
      let app = scope.application()
      let root = app.builtinsScope()
      discard root.validateImplAgainstChain(pending)
      for affected in app.affectedIndexedScopes(pending):
        discard affected.validateImplAgainstChain(pending)
      root.impls.add pending
      inc app.implEpoch
  of ivScoped:
    let target = scope.moduleRootScope()
    if target == nil:
      raise newException(GeneError, "scoped impl requires a module scope")
    discard target.validateImplAgainstChain(pending)
    target.impls.add pending
    if stage == nil:
      let app = scope.application()
      app.addIndexedScope(target, pending)
      inc app.implEpoch
  of ivOverlay:
    discard scope.validateImplAgainstChain(pending)
    scope.impls.add pending
    inc scope.application().implEpoch

proc sameImplMessages(a, b: ProtocolImpl): bool =
  if a.messages.len != b.messages.len:
    return false
  for entry in a.messages:
    var found = false
    for other in b.messages:
      if other.message.bits == entry.message.bits and same(entry.fn, other.fn):
        found = true
        break
    if not found:
      return false
  true

proc activateStagedImpls(stage: Scope) =
  if stage == nil or not stage.implStageRoot or stage.impls.len == 0:
    return
  let app = stage.application()
  let root = app.builtinsScope()
  # Validate the prospective module base scope and canonical registry before
  # publishing either. Overlay entries remain outside the enumerable index.
  for i, pending in stage.impls:
    if pending.visibility == ivCanonical:
      discard root.validateImplAgainstChain(pending)
      for affected in app.affectedIndexedScopes(pending):
        discard affected.validateImplAgainstChain(pending)
    elif pending.visibility == ivScoped:
      # A scoped impl joins its module base scope, so a pair (or inherited
      # message identity) that conflicts with an already-published canonical
      # impl must fail at assembly (proposal §4) — initial load is an
      # assembly, exactly as reload's validateProspectiveBase enforces.
      discard root.validateImplAgainstChain(pending)
    for j in i + 1 ..< stage.impls.len:
      discard stage.impls[j].validateImplConflict(pending)

  var retained: seq[ProtocolImpl]
  var changed = false
  for pending in stage.impls:
    case pending.visibility
    of ivCanonical:
      root.impls.add pending
      changed = true
    of ivScoped:
      retained.add pending
      app.addIndexedScope(stage, pending)
      changed = true
    of ivOverlay:
      retained.add pending
      changed = true
  stage.impls = retained
  if changed:
    inc app.implEpoch

proc makeImplsVisible(importingScope, sourceScope: Scope) =
  ## Ordinary value/namespace import never imports scoped policy. Canonical
  ## impls are already present in the application registry; scoped impls use
  ## `import_impl` and overlays are lexical only.
  discard importingScope
  discard sourceScope

proc importScopedImpl(importingScope, sourceScope: Scope,
                      protocol, receiver: Value) =
  let target = importingScope.moduleRootScope()
  if target == nil:
    raise newException(GeneError, "import_impl requires a module scope")
  var found = false
  var selected: ProtocolImpl
  for candidate in sourceScope.impls:
    if candidate.visibility == ivScoped and candidate.exported and
        same(candidate.protocol, protocol) and same(candidate.receiver, receiver):
      if found:
        raise newException(GeneError,
          "module exports duplicate impl " & protocol.protocolName &
          " for " & receiver.typeName)
      found = true
      selected = candidate
  if not found:
    raise newException(GeneError,
      "module does not export impl " & protocol.protocolName &
      " for " & receiver.typeName)
  var imported = selected
  imported.exported = false
  imported.imported = true
  if target.validateImplAgainstChain(imported, identicalIsDuplicate = true):
    return
  target.impls.add imported
  let app = target.application()
  app.addIndexedScope(target, imported)
  inc app.implEpoch

proc hasVisibleImpl(scope: Scope, protocol, receiver: Value): bool =
  # An impl of a protocol that ^inherits `protocol` also satisfies `protocol`
  # (docs/core.md §3.5 — structural subtyping from the impl).
  var s = scope
  while s != nil:
    for impl in s.impls:
      if protocolIsOrInherits(impl.protocol, protocol) and
          receiver.isSubtypeOf(impl.receiver):
        return true
    s = s.parent
  false

proc receiverType(value: Value): Value =
  if value.kind == vkNode and value.head.kind == vkType:
    value.head
  elif value.kind == vkNode and value.head.kind == vkEnumVariant:
    value.head.enumVariantEnum
  elif value.kind == vkEnumVariant:
    value.enumVariantEnum
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
  if protocol.kind == vkProtocol and protocol.protocolUniversal:
    return true
  scope != nil and scope.hasVisibleImpl(protocol, typ)

proc builtinBinding(scope: Scope, name: string): Value =
  ## Resolve a standard-library name for the VM's own use. This reads the
  ## `gene` scope, not the lexical root, so built-in type messages and the
  ## error types the VM raises keep working even though almost nothing is
  ## pre-bound bare (design §2.1).
  let app =
    if scope == nil: currentApplication()
    else: scope.application()
  discard app.builtinsScope()      # forces construction, which fills `stdlib`
  if app.stdlib != nil: app.stdlib.lookup(name)
  else: NIL

proc isBuiltinCallable(value: Value): bool =
  # fn! values implement SyntaxCallable, not Callable (design §3).
  (value.kind == vkFunction and not value.isSyntaxFn) or
    value.kind in {vkNativeFn, vkFfiCallable, vkType,
                   vkProtocolMessage, vkEnumVariant} or
    (value.kind == vkNode and value.isSelector)

proc valueImplementsCallable(value: Value, scope: Scope): bool =
  if value.isBuiltinCallable:
    return true
  let typ = value.receiverType
  if typ.kind != vkType:
    return false
  let protocol = builtinBinding(scope, "Callable")
  protocol.kind == vkProtocol and typeImplementsProtocol(scope, typ, protocol)

proc requireEnumTypeReceiver(name: string, args: openArray[Value]): Value =
  requireOne(name, args)
  if not args[0].isEnumType:
    raise newException(GeneError, name & " receiver must be an enum")
  args[0]

proc requireEnumVariantReceiver(name: string, args: openArray[Value]): Value =
  requireOne(name, args)
  let variant = args[0].enumValueVariant
  if variant.kind != vkEnumVariant:
    raise newException(GeneError, name & " receiver must be an enum variant")
  variant

proc biEnumVariants(args: openArray[Value]): Value =
  let enumType = requireEnumTypeReceiver("Enum/variants", args)
  var items: seq[Value]
  for variant in enumType.enumVariants:
    items.add variant
  newList(items)

proc biEnumNames(args: openArray[Value]): Value =
  let enumType = requireEnumTypeReceiver("Enum/names", args)
  var items: seq[Value]
  for variant in enumType.enumVariants:
    items.add newSym(variant.enumVariantName)
  newList(items)

proc biEnumName(args: openArray[Value]): Value =
  let variant = requireEnumVariantReceiver("Enum/name", args)
  newSym(variant.enumVariantName)

proc biEnumOrdinal(args: openArray[Value]): Value =
  let variant = requireEnumVariantReceiver("Enum/ordinal", args)
  newInt(int64(variant.enumVariantOrdinal))

proc biEnumFromName(args: openArray[Value]): Value =
  if args.len != 2:
    raise newException(GeneError, "Enum/from_name expects 2 arguments, got " & $args.len)
  if not args[0].isEnumType:
    raise newException(GeneError, "Enum/from_name receiver must be an enum")
  let key =
    case args[1].kind
    of vkSymbol: args[1].symVal
    of vkString: args[1].strVal
    else:
      return VOID
  args[0].enumVariantDescriptor(key)

proc biEnumFromOrdinal(args: openArray[Value]): Value =
  if args.len != 2:
    raise newException(GeneError, "Enum/from_ordinal expects 2 arguments, got " & $args.len)
  if not args[0].isEnumType:
    raise newException(GeneError, "Enum/from_ordinal receiver must be an enum")
  if not args[1].intFitsInt64:
    return VOID
  let ordinal = args[1].intVal
  if ordinal < 0 or ordinal > int64(high(int)):
    return VOID
  for variant in args[0].enumVariants:
    if variant.enumVariantOrdinal == int(ordinal):
      return variant
  VOID

proc biEnumBacking(args: openArray[Value]): Value =
  let variant = requireEnumVariantReceiver("Enum/backing", args)
  variant.enumVariantBacking

proc biEnumFromBacking(args: openArray[Value]): Value =
  if args.len != 2:
    raise newException(GeneError, "Enum/from_backing expects 2 arguments, got " & $args.len)
  if not args[0].isEnumType:
    raise newException(GeneError, "Enum/from_backing receiver must be an enum")
  for variant in args[0].enumVariants:
    if variant.enumVariantHasBacking and equal(variant.enumVariantBacking, args[1]):
      return variant
  VOID

proc enumReflectionMessage(name: string): Value =
  case name
  of "variants": newNativeFn("Enum/variants", biEnumVariants)
  of "names": newNativeFn("Enum/names", biEnumNames)
  of "name": newNativeFn("Enum/name", biEnumName)
  of "ordinal": newNativeFn("Enum/ordinal", biEnumOrdinal)
  of "from_name": newNativeFn("Enum/from_name", biEnumFromName)
  of "from_ordinal": newNativeFn("Enum/from_ordinal", biEnumFromOrdinal)
  of "backing": newNativeFn("Enum/backing", biEnumBacking)
  of "from_backing": newNativeFn("Enum/from_backing", biEnumFromBacking)
  else: NIL

proc typeNsMessage(scope: Scope, nsName, name: string): Value =
  ## Resolve `name` as a type-direct message from the built-in type namespace
  ## `nsName` (design §12): built-in operations are messages on their type, so
  ## `(x ~ get)` is also reachable as `(x ~ get)` and `x/~get`. Returns
  ## NIL when the namespace has no such member.
  let ns = builtinBinding(scope, nsName)
  let binding = exportedBinding(ns, name)
  if binding.kind == vkVoid: NIL else: binding

proc convertMessage(scope: Scope, name: string,
                    names: openArray[string]): Value =
  ## The stream/pipeline operations (design §6) reachable as type-direct
  ## messages on iterable/stream receivers, so `(xs ~ to_stream)` and
  ## `(s ~ map f)` dispatch — `~` has no lexical fallback (design §3).
  ## Resolved from the `stream` namespace, which carries the full pipeline
  ## surface (map/filter/take/into/each/to_stream/to_pairs_stream); `names`
  ## restricts which ops are valid for a given receiver type.
  if name notin names:
    return NIL
  let root =
    if scope == nil: builtinsScope()
    else: scope.application().builtinsScope()
  var v: Value
  if root.lookupOptional(name, v):
    return v                       # head/props/body/meta and most pipeline ops
  let streamNs = builtinBinding(scope, "stream")
  let binding = exportedBinding(streamNs, name)   # `each` lives only here
  if binding.kind == vkVoid: NIL else: binding

proc builtinReceiverMessage(scope: Scope, receiver: Value, name: string): Value =
  if receiver.isEnumType:
    let message = enumReflectionMessage(name)
    if message.kind != vkNil:
      return message
  if receiver.kind == vkType:
    let message = typeReflectionMessage(name)
    if message.kind != vkNil:
      return message
  if receiver.enumValueVariant.kind == vkEnumVariant:
    case name
    of "name", "ordinal", "backing":
      let message = enumReflectionMessage(name)
      if message.kind != vkNil:
        return message
    else:
      discard
  case receiver.kind
  of vkList:
    case name
    of "size", "empty?", "first", "last", "contains?":
      builtinBinding(scope, name)
    else:
      var m = typeNsMessage(scope, "List", name)
      if m.kind == vkNil: m = convertMessage(scope, name, ["to_stream"])
      m
  of vkSet:
    case name
    of "contains?":
      builtinBinding(scope, name)
    else:
      convertMessage(scope, name, ["to_stream"])
  of vkRange:
    var m = typeNsMessage(scope, "Range", name)
    if m.kind == vkNil: m = convertMessage(scope, name, ["to_stream"])
    m
  of vkMap, vkHashMap:
    var m = typeNsMessage(scope, "Map", name)
    if m.kind == vkNil:
      m = convertMessage(scope, name, ["to_stream", "to_pairs_stream"])
    m
  of vkNode:
    var m = typeNsMessage(scope, "Node", name)
    # head/props/body/meta are the Node protocol accessors (§1.2), reachable as
    # messages on a node in addition to the `(head n)` wrapper form (§1.3).
    if m.kind == vkNil:
      m = convertMessage(scope, name, ["head", "props", "body", "meta"])
    m
  of vkCell:
    typeNsMessage(scope, "Cell", name)
  of vkAtomicCell:
    typeNsMessage(scope, "AtomicCell", name)
  of vkStream:
    var m = typeNsMessage(scope, "Stream", name)
    if m.kind == vkNil:
      m = convertMessage(scope, name,
        ["map", "filter", "take", "into", "each", "to_pairs_stream"])
    m
  of vkChannel:
    typeNsMessage(scope, "Channel", name)
  of vkTask:
    typeNsMessage(scope, "Task", name)
  of vkReplyTo:
    typeNsMessage(scope, "ReplyTo", name)
  of vkBuffer:
    typeNsMessage(scope, "Buffer", name)
  of vkActorRef:
    typeNsMessage(scope, "Actor", name)
  of vkModule:
    typeNsMessage(scope, "Module", name)
  of vkNamespace:
    typeNsMessage(scope, "Namespace", name)
  of vkCapability:
    typeNsMessage(scope, "Capability", name)
  of vkEnv:
    typeNsMessage(scope, "Env", name)
  of vkRegex:
    let regexNs = builtinBinding(scope, "regex")
    let binding = exportedBinding(regexNs, name)
    if binding.kind == vkVoid: NIL else: binding
  of vkDate:
    let dateNs = builtinBinding(scope, "Date")
    let binding = exportedBinding(dateNs, name)
    if binding.kind == vkVoid: NIL else: binding
  of vkTime:
    let timeNs = builtinBinding(scope, "Time")
    let binding = exportedBinding(timeNs, name)
    if binding.kind == vkVoid: NIL else: binding
  of vkDateTime:
    let dateTimeNs = builtinBinding(scope, "DateTime")
    let binding = exportedBinding(dateTimeNs, name)
    if binding.kind == vkVoid: NIL else: binding
  of vkTimezone:
    let timezoneNs = builtinBinding(scope, "Timezone")
    let binding = exportedBinding(timezoneNs, name)
    if binding.kind == vkVoid: NIL else: binding
  of vkDuration:
    let durationNs = builtinBinding(scope, "Duration")
    let binding = exportedBinding(durationNs, name)
    if binding.kind == vkVoid: NIL else: binding
  of vkLogger:
    let logNs = builtinBinding(scope, "log")
    let binding = exportedBinding(logNs, name)
    if binding.kind == vkVoid: NIL else: binding
  else:
    NIL

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
  if mode == csmWorker and captured.kind == vkNativeFn and
      captured.nativeFnName in ["os/exec_async", "os/exec_stream_async"]:
    # Dedicated exec jobs retain Task/Channel ORC objects in a root-lane
    # registry; constructing that ownership graph on a worker would perform
    # non-atomic GC_ref/GC_unref operations on the wrong lane.
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
    of opLoadOuterLocal, opCallParentLocal0, opCallOuterLocal0,
        opCallParentLocal1, opCallOuterLocal1:
      if inst.depth > localDepth:
        let captureDepth = inst.depth - localDepth
        if not capturedSlotSendable(fnScope, visibleScope, captureDepth,
                                    inst.intArg, inst.name, seen, mode):
          return false
    of opSetOuterLocal:
      if inst.depth > localDepth:
        return false
    of opLoadName, opLoadNativeFast, opCallName0, opCallName1, opCallNameN:
      if not namedCaptureSendable(fnScope, visibleScope, inst.name, seen,
                                  ignoredNames, mode):
        return false
    of opSpawn:
      if mode == csmWorker:
        return false
    of opSetName:
      return false
    of opFail, opPanic:
      if mode == csmWorker:
        return false
    of opMakeNamespace:
      if mode == csmWorker:
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
  if value.kind in {vkList, vkMap, vkSet, vkHashMap, vkNode, vkFunction}:
    if seen.contains(value.bits):
      return true
    seen.incl value.bits
  case value.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkBytes, vkRegex, vkRange,
     vkDate, vkTime, vkDateTime, vkTimezone, vkDuration, vkChar, vkSymbol,
     vkNativeFn, vkAtomicCell, vkTask, vkChannel, vkActorRef, vkReplyTo,
     vkLogger, vkType, vkProtocol, vkProtocolMessage, vkEnumVariant:
    true
  of vkFunction:
    functionCapturesSendable(value, scope, seen, mode)
  of vkNode:
    if value.nodeConstructing:
      return false
    var sendProtocol: Value
    if value.head.kind == vkType and scope != nil and
        builtinTypeBinding(scope, "Send", sendProtocol) and
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
  of vkSet:
    for item in value.setItems:
      if not isSendableValue(item, scope, seen, mode):
        return false
    true
  of vkHashMap:
    for entry in value.hashMapEntries:
      if not isSendableValue(entry.key, scope, seen, mode):
        return false
      if not isSendableValue(entry.val, scope, seen, mode):
        return false
    true
  of vkNamespace:
    let root =
      if scope == nil: builtinsScope()
      else: scope.application().builtinsScope()
    value.nsScope != nil and value.nsScope.parent == root
  of vkModule, vkEnv, vkCallerEnv, vkCell, vkStream, vkActorContext,
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
    of opLoadOuterLocal, opCallParentLocal0, opCallOuterLocal0,
        opCallParentLocal1, opCallOuterLocal1:
      if inst.depth > localDepth:
        captures.addCaptureSlot(inst.depth - localDepth, inst.intArg, inst.name)
    of opLoadName, opLoadNativeFast, opCallName0, opCallName1, opCallNameN:
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
    var entries = initPropTable()
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
    var props = initPropTable()
    var body: seq[Value]
    var meta = initPropTable()
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
              immutable = value.nodeImmutable,
              constructing = value.nodeConstructing)
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
      snapshot.varsDirty = true

  let rootSnapshot = scopeMap.getOrDefault(cast[pointer](source), nil)
  if rootSnapshot != nil:
    # Settle pending mirror copies first so a name captured above as a slot
    # is not re-captured (and re-cloned) by name below.
    rootSnapshot.materializeMirroredVars()
    for name in captures.names:
      let slot = source.slotIndex(name)
      if slot >= 0:
        if not source.slotDefined(slot):
          raiseUndefinedSymbol(name)
        if not rootSnapshot.slotDefined(slot):
          rootSnapshot.slots[slot] =
            cloneForCapturedSnapshot(source.slots[slot], scopeMap)
          rootSnapshot.markSlotDefined(slot)
          if rootSnapshot.slotMirror:
            rootSnapshot.varsDirty = true
        continue
      if rootSnapshot.vars.hasKey(name):
        continue
      var value: Value
      if not source.lookupOptional(name, value):
        raiseUndefinedSymbol(name)
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
  result.moduleRoot = source.moduleRoot
  result.moduleStatic = source.moduleStatic
  result.entryProtocols = source.entryProtocols
  result.entryProtocolsFrozen = source.entryProtocolsFrozen
  result.forceOverlayImpls = source.forceOverlayImpls
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
    var messages: seq[ImplMessage]
    for entry in impl.messages:
      messages.add ImplMessage(message: entry.message,
                               fn: cloneForCapturedSnapshot(entry.fn, scopeMap))
    result.impls.add ProtocolImpl(protocol: impl.protocol,
                                  receiver: impl.receiver,
                                  messages: messages,
                                  visibility: impl.visibility,
                                  exported: impl.exported,
                                  originPath: impl.originPath,
                                  imported: impl.imported)
  result.requiredImplTypes = source.requiredImplTypes
  result.evalBudget = source.evalBudget

proc captureValueAtDepth(source: Scope, depth, slot: int,
                         name: string): tuple[scope: Scope, value: Value] =
  result.scope = capturedScope(source, depth)
  if result.scope == nil or slot < 0 or slot >= result.scope.slots.len:
    raiseUndefinedSymbol(name)
  if not result.scope.slotDefined(slot):
    raiseUndefinedSymbol(name)
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
    for message in proto.messages:
      publishSpawnFunctionProto(message.fn, seenScopes, seenValues, seenChunks)
    for inline in proto.inlineImpls:
      for message in inline.messages:
        publishSpawnFunctionProto(message.fn, seenScopes, seenValues, seenChunks)
  for proto in chunk.enumProtos:
    publishSpawnValue(proto.backingType, seenScopes, seenValues, seenChunks)
    for variant in proto.variants:
      for payloadType in variant.payloadTypes:
        publishSpawnValue(payloadType, seenScopes, seenValues, seenChunks)
      publishSpawnValue(variant.backing, seenScopes, seenValues, seenChunks)
    for message in proto.messages:
      publishSpawnFunctionProto(message.fn, seenScopes, seenValues, seenChunks)
    for inline in proto.inlineImpls:
      for message in inline.messages:
        publishSpawnFunctionProto(message.fn, seenScopes, seenValues, seenChunks)
  for proto in chunk.protocolProtos:
    for message in proto.messages:
      publishSpawnFunctionProto(message.fn, seenScopes, seenValues, seenChunks)
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
  of vkLogger:
    publishSpawnValue(value.loggerPayload, seenScopes, seenValues, seenChunks)
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
    publishSpawnValue(value.actorParentFailureEvents, seenScopes, seenValues,
                      seenChunks)
    publishSpawnValue(value.actorParentFailureDeadLetters, seenScopes,
                      seenValues, seenChunks)
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
    # okEnum also reports vkType. The type* accessors tolerate enums
    # (NIL/empty), but the lent-seq protocol accessors reject them, and enums
    # have their own edges (backing type, variant payload types) to publish.
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
    if value.isEnumType:
      publishSpawnValue(value.enumBackingType, seenScopes, seenValues,
                        seenChunks)
      for variant in value.enumVariants:
        for payload in variant.enumVariantPayloadTypes:
          publishSpawnValue(payload, seenScopes, seenValues, seenChunks)
        if variant.enumVariantHasBacking:
          publishSpawnValue(variant.enumVariantBacking, seenScopes,
                            seenValues, seenChunks)
    else:
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
    publishSpawnValue(value.protocolMessageSignatureFn, seenScopes, seenValues,
                      seenChunks)
    publishSpawnValue(value.protocolMessageDefaultFn, seenScopes, seenValues,
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
    var atBuiltins = false
    if current.application != nil:
      let app = Application(current.application)
      if app.builtins == current:
        if app.spawnBuiltinsPublished:
          return
        app.spawnBuiltinsPublished = true
        atBuiltins = true
    for i in 0 ..< current.slots.len:
      if current.slotDefined(i):
        publishSpawnValue(current.slots[i], seenScopes, seenValues, seenChunks)
    current.materializeMirroredVars()
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
    # Impls on the global root (design §10) are app-wide and reached through the
    # shared runtime, not the worker snapshot; publishing their fns would drag in
    # the impl's defining-module scope. Skip them here.
    if not atBuiltins:
      for impl in current.impls:
        publishSpawnValue(impl.protocol, seenScopes, seenValues, seenChunks)
        publishSpawnValue(impl.receiver, seenScopes, seenValues, seenChunks)
        for entry in impl.messages:
          publishSpawnValue(entry.message, seenScopes, seenValues, seenChunks)
          publishSpawnValue(entry.fn, seenScopes, seenValues, seenChunks)
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

proc validateRequiredImplType(scope: Scope, typ: Value) =
  for protocol in typ.typeRequiredProtocols:
    if not scope.typeImplementsProtocol(typ, protocol):
      raise newException(GeneError,
        "type " & typ.typeName & " requires impl " & protocol.protocolName)

proc validateRequiredImpls(scope: Scope) =
  for typ in scope.requiredImplTypes:
    scope.validateRequiredImplType(typ)

proc isErrorValue(scope: Scope, value: Value): bool =
  if value.kind != vkNode or value.head.kind != vkType:
    return false
  var errorProtocol: Value
  if not builtinTypeBinding(scope, "Error", errorProtocol) or
      errorProtocol.kind != vkProtocol:
    return false
  scope.typeImplementsProtocol(value.head, errorProtocol)

proc isErrorType(scope: Scope, typ: Value): bool =
  if typ.kind != vkType:
    return false
  var errorProtocol: Value
  if not builtinTypeBinding(scope, "Error", errorProtocol) or
      errorProtocol.kind != vkProtocol:
    return false
  scope.typeImplementsProtocol(typ, errorProtocol)

proc popCheckedErrorTypes(stack: var seq[Value], sp: var int, count: int,
                          scope: Scope): seq[Value] =
  ## Pops below runLoop's sp register (the seq's len is working capacity
  ## there, not the live top).
  result = newSeq[Value](count)
  if count > 0:
    for i in countdown(count - 1, 0):
      dec sp
      let typ = move stack[sp]
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

proc nativeNewAsyncTask*(): Value =
  newExternalTask()

proc nativeTaskComplete*(task, value: Value, scope: Scope = nil): bool =
  withScopedScheduler(scope):
    if task.kind != vkTask:
      raise newException(GeneError, "native task complete expects a Task")
    result = tryCompleteTask(task, value)
    if result:
      wakeTaskWaiters(task)

proc nativeTaskFail*(task: Value, message: string, value: Value = NIL,
                     hasValue = false, scope: Scope = nil): bool =
  withScopedScheduler(scope):
    if task.kind != vkTask:
      raise newException(GeneError, "native task fail expects a Task")
    result = tryFailTask(task, message, value, hasValue)
    if result:
      wakeTaskWaiters(task)

proc nativeTaskCancel*(task: Value, scope: Scope = nil): bool =
  withScopedScheduler(scope):
    if task.kind != vkTask:
      raise newException(GeneError, "native task cancel expects a Task")
    result = tryCancelTask(task)
    if result:
      wakeTaskWaiters(task)

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
  builtinTypeBinding(scope, "TypeError", typeError) and
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
  var props = initPropTable()
  props["message"] = newStr(message)
  var head = newSym("MatchError")
  var matchError: Value
  if builtinTypeBinding(scope, "MatchError", matchError) and
      matchError.kind == vkType:
    head = matchError
  var e: ref MatchError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc raiseCompileError(scope: Scope, message: string) =
  var props = initPropTable()
  props["message"] = newStr(message)
  var head = newSym("CompileError")
  var compileError: Value
  if builtinTypeBinding(scope, "CompileError", compileError) and
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

proc incrementalReplScopeForEnv*(env: Value): Scope =
  if env.kind != vkEnv:
    raise newException(GeneError, "repl/open expects an Env")
  result = newScope(materializeEvalParent(env))
  result.implOverlayRoot = true
  result.evalBudget = evalBudgetForPolicy(env.envPolicy, nil)
  if result.evalBudget == nil:
    # The VM interrupt flag is polled only on the budgeted-dispatch path, so
    # an incremental REPL session must always carry a budget or its evals
    # cannot be cancelled (§C7 liveness).
    result.evalBudget = EvalBudget(remaining: high(int64))

proc materializeCallerEvalParent(callerEnv: Value): Scope =
  ## Materialize a read-only overlay for one eval from the live borrowed view.
  ## The overlay is marked borrowed so any closure it creates cannot escape the
  ## surrounding syntax call. Declarations stay in eval's child scope.
  let source = callerEnv.callerEnvScope
  var chain: seq[Scope]
  let builtins = source.application().builtinsScope()
  var current = source
  while current != nil and current != builtins:
    chain.add current
    current = current.parent
  result = newScope(builtins)
  result.borrowedCallerEnv = true
  for i in countdown(chain.high, 0):
    let item = chain[i]
    # vars before slots: on mirrored scopes a not-yet-materialized vars
    # entry may be stale, and the slot overlay must win.
    for name, value in item.vars:
      result.defineOverlay(name, value)
    for index, name in item.slotNames:
      if name.len > 0 and item.slotDefined(index):
        result.defineOverlay(name, item.slots[index])
    for impl in item.impls:
      result.impls.add impl

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

proc receiverDistance(actual, target: Value): int =
  var current = actual
  var depth = 0
  while current.kind == vkType:
    if same(current, target):
      return depth
    current = current.typeParent
    inc depth
  -1

proc collectProtocolMatches(scope: Scope, recvType, message: Value,
                            bestDepth: var int, matches: var seq[Value]) =
  # Nearest-receiver selection is independent for each exact message
  # identity. Unrelated same-name identities are compared only afterward.
  for impl in scope.impls:
    let depth = recvType.receiverDistance(impl.receiver)
    if depth < 0 or (bestDepth >= 0 and depth > bestDepth):
      continue
    for entry in impl.messages:
      if entry.message.bits != message.bits:
        continue
      if bestDepth < 0 or depth < bestDepth:
        bestDepth = depth
        matches.setLen(0)
      matches.add entry.fn

proc stampSuperType(proto: FunctionProto, parent: Value,
                    seen: var HashSet[pointer]) =
  ## Record a type-direct message body's `^is` parent on its chunk, and on every
  ## chunk nested inside it, so `(super ~ m)` in the body — or in a closure
  ## lexically inside it — reads the owner's parent identity instead of
  ## resolving a shadowable name (design §10).
  if proto == nil:
    return
  for chunk in [proto.chunk, proto.scopelessChunk]:
    if chunk == nil or seen.containsOrIncl(cast[pointer](chunk)):
      continue
    chunk.superType = parent
    for nested in chunk.functions:
      stampSuperType(nested, parent, seen)

proc stampSuperType(proto: FunctionProto, parent: Value) =
  var seen = initHashSet[pointer]()
  stampSuperType(proto, parent, seen)

proc tryResolveProtocolMessage(scope: Scope, recvType, message: Value): Value =
  var matches: seq[Value]
  var bestDepth = -1
  var current = scope
  while current != nil:
    current.collectProtocolMatches(recvType, message, bestDepth, matches)
    current = current.parent
  matches.dedupeProtocolMatches()
  if matches.len > 1:
    let protocol = message.protocolMessageProtocol
    raise newException(GeneError,
      "ambiguous impl " & protocol.protocolName & " for " & recvType.typeName)
  if matches.len == 1:
    return matches[0]
  let protocol = message.protocolMessageProtocol
  if protocol.protocolUniversal:
    return message.protocolMessageDefaultFn
  NIL

proc resolveProtocolMessage(scope: Scope, message, receiver: Value): Value =
  if scope == nil:
    raise newException(GeneError,
      "protocol message '" & message.protocolMessageName &
      "' has no visible implementation scope")
  let protocol = message.protocolMessageProtocol
  let recvType = receiver.receiverType
  if recvType.kind != vkType:
    # A receiver with no nominal type carries no impl, but the send still failed
    # for the ordinary reason, so it stays a recoverable MessageError (§9).
    raiseMessageError(message.protocolMessageName, declarationKind(receiver),
                      scope, protocol = protocol.protocolName, missingImpl = true)
  result = scope.tryResolveProtocolMessage(recvType, message)
  if result.kind == vkNil:
    # A qualified send with no visible impl is a recoverable MessageError (§9).
    raiseMessageError(message.protocolMessageName, recvType.typeName, scope,
                      protocol = protocol.protocolName, missingImpl = true)

proc addProtocolCandidate(candidates: var seq[Value], value: Value) =
  if value.kind != vkProtocol:
    return
  for existing in candidates:
    if same(existing, value):
      return
  candidates.add value

proc addInterfaceProtocolCandidates(candidates: var seq[Value], value: Value,
                                    seen: var seq[uint64]) =
  if value.kind == vkProtocol:
    candidates.addProtocolCandidate(value)
    return
  if value.kind notin {vkModule, vkNamespace}:
    return
  for bits in seen:
    if bits == value.bits:
      return
  seen.add value.bits
  let namespace =
    if value.kind == vkModule: value.moduleRootNamespace
    else: value
  let bindingScope = namespace.nsScope
  bindingScope.materializeMirroredVars()
  for index, name in bindingScope.slotNames:
    if name.len > 0 and index < bindingScope.slots.len and
        bindingScope.slotDefined(index):
      candidates.addInterfaceProtocolCandidates(bindingScope.slots[index], seen)
  for name, binding in bindingScope.vars:
    if name != "this_mod":
      candidates.addInterfaceProtocolCandidates(binding, seen)

proc snapshotProtocolBindings(scope: Scope): seq[Value] =
  ## Freeze protocol identities from ordinary lexical bindings, never from
  ## the canonical impl registry. Callers retain the resulting Values.
  var current = scope
  var seenInterfaces: seq[uint64]
  while current != nil:
    for index, _ in current.slotNames:
      if index < current.slots.len and current.slotDefined(index):
        result.addInterfaceProtocolCandidates(current.slots[index],
                                              seenInterfaces)
    current.materializeMirroredVars()
    for _, value in current.vars:
      result.addInterfaceProtocolCandidates(value, seenInterfaces)
    current = current.parent

# --------------------------------------------------------------------------
# Protocol-message dispatch inline cache (design §10)
# --------------------------------------------------------------------------
# Qualified dispatch (`resolveProtocolMessage`) walks the whole send-scope
# parent chain, linear-scanning every scope's `impls` with an ^is
# receiver-distance probe per impl — ~10x a plain call. A per-call-site
# monomorphic cache turns the repeated resolution into a guard check plus a
# pointer materialization. The guard is sound because:
#   * the receiver's runtime type is compared (recvTypeBits);
#   * `implEpoch` is bumped by every impl mutation (canonical/scoped/overlay
#     add, staged activation, import_impl, reload), so any change to the
#     visible impl set — and any newly ambiguating or shadowing impl, since a
#     candidate protocol only affects the result through an impl — invalidates;
#   * a candidate protocol that gains no relevant impl is inert, so the
#     name-fixed unqualified candidate set needs no separate signal;
#   * activation-local overlay impls are the one impl source not pinned by the
#     epoch across activations, so `chainHasTransientImpls` refuses the cache
#     whenever a transient scope carries impls (fill and lookup alike).
# Type-direct messages fold into the same entry: they are immutable per type
# object, so recvTypeBits covers them.
const dispatchCacheEnabled = not (compileOption("threads") and defined(gcAtomicArc))
  ## The cache mutates per-Chunk side storage without synchronization. Only the
  ## atomicArc worker lane (`compileOption("threads") and defined(gcAtomicArc)`,
  ## the exact gate the scheduler uses) runs Chunks on multiple OS threads
  ## concurrently; there the send falls back to full resolution — correct and
  ## unchanged, just uncached. Every other build (default/test/spec/perf run
  ## orc with cooperative single-lane fibers) caches. Note Nim 2.x defaults
  ## `--threads:on`, so gating on threads alone would disable the cache
  ## everywhere.

when dispatchCacheEnabled:
  proc chainHasTransientImpls(scope: Scope): bool {.inline.} =
    ## True when a scope strictly below the first stable base (module root or
    ## eval overlay root) carries impls. Those activation-local overlay impls
    ## make a send context-sensitive — the same call site can resolve
    ## differently across activations at one epoch — so such sends are neither
    ## cached nor served from the cache. Stable-base impls (canonical/scoped/
    ## import_impl) are epoch-guarded and live on reused scope objects, so the
    ## walk stops at the base without inspecting them. Cost is O(transient
    ## depth) of `.impls.len` reads; a module/eval root send scope returns at
    ## once.
    var s = scope
    while s != nil:
      if s.moduleRoot or s.implOverlayRoot:
        return false
      if s.impls.len > 0:
        return true
      s = s.parent
    false

  proc dispatchCacheLookup(chunk: Chunk, site: int, recvType: Value,
                           msgBits, epoch: uint64): Value {.inline.} =
    ## Owned cached callee on a full guard match, else NIL. An empty slot has
    ## recvTypeBits 0, which never equals a live type's bits.
    if site >= 0 and site < chunk.dispatchCache.len:
      let e = addr chunk.dispatchCache[site]
      if e.recvTypeBits == recvType.bits and e.msgBits == msgBits and
          e.epoch == epoch:
        return ownedValueFromBits(e.calleeBits)
    NIL

  proc dispatchCacheFill(chunk: Chunk, site: int, recvType: Value,
                         msgBits, epoch: uint64, callee: Value) {.inline.} =
    ## Record a monomorphic resolution, lazily sizing the side array to the
    ## chunk's instruction count on first use. `calleeBits` is stored
    ## non-owning; it is re-materialized only while the guard (epoch) still
    ## holds, and an unchanged epoch implies the resolving impl — hence the
    ## callee — is still registered and alive.
    if site < 0:
      return
    if chunk.dispatchCache.len != chunk.instructions.len:
      chunk.dispatchCache.setLen(chunk.instructions.len)
    chunk.dispatchCache[site] = DispatchCacheEntry(
      recvTypeBits: recvType.bits, msgBits: msgBits, epoch: epoch,
      calleeBits: callee.bits)


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

proc defaultReplOptions*(interactive = false): ReplOptions =
  ReplOptions(interactive: interactive, prompt: "gene> ")

proc runReplSession*(scope: Scope,
                     readLine: ReplReadLine,
                     writeOut: ReplWrite,
                     writeErr: ReplWrite,
                     options = defaultReplOptions()): int

proc instructionLocAt(chunk: Chunk, index: int): SourceLoc =
  if chunk != nil and index >= 0 and index < chunk.instructionLocs.len:
    return chunk.instructionLocs[index]
  SourceLoc()

proc instructionLocBefore(chunk: Chunk, ip: int): SourceLoc =
  instructionLocAt(chunk, ip - 1)

proc annotateTopLevelUndefined(e: ref GeneError, chunk: Chunk,
                               errorLoc: SourceLoc) =
  if e == nil or e.errorKind != gekUndefinedSymbol or
      chunk == nil or chunk.topLevelForms.len == 0 or
      not errorLoc.hasSourceLoc:
    return
  var found = -1
  for i, info in chunk.topLevelForms:
    let loc = info.loc
    if loc.sourceName == errorLoc.sourceName and
        (loc.line < errorLoc.line or
         (loc.line == errorLoc.line and loc.col <= errorLoc.col)):
      found = i
    else:
      break
  if found < 0:
    return
  let loc = chunk.topLevelForms[found].loc
  let info = chunk.topLevelForms[found]
  let label =
    if info.nodeLike: "(" & info.label & " …)"
    else: info.label
  e.msg.add "\n  in top-level form opened at " & loc.locationText() &
            ": " & label

proc withSourceLocProps(value: Value, loc: SourceLoc): Value =
  if value.kind != vkNode or not loc.hasSourceLoc:
    return value
  var props = copyEntries(value.props)
  if not props.hasKey("file") and loc.sourceName.len > 0:
    props["file"] = newStr(loc.sourceName)
  if not props.hasKey("line"):
    props["line"] = newInt(int64(loc.line))
  if not props.hasKey("col"):
    props["col"] = newInt(int64(loc.col))
  newNode(value.head, props = props,
          body = copyItems(value.body),
          meta = copyEntries(value.meta),
          immutable = value.nodeImmutable,
          constructing = value.nodeConstructing)

proc attachSourceLoc(e: ref GeneError, loc: SourceLoc) =
  if e == nil or not loc.hasSourceLoc:
    return
  if not e.loc.hasSourceLoc:
    e.loc = loc
  if e.hasErrVal:
    e.errVal = e.errVal.withSourceLocProps(loc)

proc stackFrameValue(name, kind: string, loc = SourceLoc()): Value =
  var props = initPropTable()
  props["name"] = newStr(name)
  props["kind"] = newStr(kind)
  if loc.hasSourceLoc:
    if loc.sourceName.len > 0:
      props["file"] = newStr(loc.sourceName)
    props["line"] = newInt(int64(loc.line))
    props["col"] = newInt(int64(loc.col))
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

proc appendVmTrace(e: ref GeneError, curFnName: string, curLoc: SourceLoc,
                   frames: openArray[Frame],
                   tailTraceFrames: openArray[TailTraceFrame]) =
  var traceFrames: seq[Value]
  if curFnName.len > 0:
    traceFrames.add stackFrameValue(curFnName, "bytecode", curLoc)
  var tailIndex = tailTraceFrames.len - 1
  template appendTailTracesAtDepth(depth: int) =
    while tailIndex >= 0 and tailTraceFrames[tailIndex].frameDepth == depth:
      let tail = tailTraceFrames[tailIndex]
      if tail.fnName.len > 0:
        traceFrames.add stackFrameValue(tail.fnName, "bytecode",
                                        instructionLocBefore(tail.chunk,
                                                             tail.ip))
      dec tailIndex
  appendTailTracesAtDepth(frames.len)
  for i in countdown(frames.len - 1, 0):
    if frames[i].fnName.len > 0:
      traceFrames.add stackFrameValue(frames[i].fnName, "bytecode",
                                      instructionLocBefore(frames[i].chunk,
                                                           frames[i].ip))
    appendTailTracesAtDepth(i)
  appendTraceFrames(e, traceFrames)

proc appendNativeTrace(e: ref GeneError, calleeName: string,
                       proto: FunctionProto) =
  let kind =
    if proto.nativeOp != ncoNone or proto.aotFrameKind == afkTypedNative:
      "typed_native"
    else:
      "native"
  appendTraceFrames(e, [stackFrameValue(calleeName, kind)])

# Cooperative scheduler state. The root lane remains cooperative; in atomicArc
# threaded builds a bounded OS-worker lane can run snapshot-isolated worker
# candidates while root blocking waits keep the unsafe lane cooperative. The
# scheduler's lock-backed run queue holds runnable fibers; its wait list holds
# fibers parked on a channel, actor mailbox, task await, or timer.
# `currentFiberActive` gates suspension: only a scheduled fiber parks —
# root-level channel use keeps its original synchronous behavior.
const schedulerInstructionBudget = 2048
const schedulerWorkerTimerPollMs = 1

when compileOption("threads") and defined(gcAtomicArc):
  const MaxSchedulerWorkers = 32
  const DefaultAsyncIoQueueMax = 1024
  const MaxAsyncIoQueueMax = 65536

  proc configuredSchedulerWorkers(): int =
    let raw = getEnv("GENE_WORKERS")
    if raw.len == 0:
      result = min(4, max(1, cpuinfo.countProcessors() - 1))
      if result > MaxSchedulerWorkers:
        result = MaxSchedulerWorkers
      return
    try:
      result = parseInt(raw)
    except ValueError:
      return 0
    if result < 0:
      result = 0
    elif result > MaxSchedulerWorkers:
      result = MaxSchedulerWorkers

  proc configuredAsyncIoQueueMax(): int =
    let raw = getEnv("GENE_ASYNC_IO_MAX_QUEUE")
    if raw.len == 0:
      return DefaultAsyncIoQueueMax
    try:
      result = parseInt(raw)
    except ValueError:
      return DefaultAsyncIoQueueMax
    if result < 0:
      result = 0
    elif result > MaxAsyncIoQueueMax:
      result = MaxAsyncIoQueueMax

  proc pendingAsyncIoRequestsUnlocked(s: SchedulerState): int {.inline.} =
    s.asyncIoQueue.len - s.asyncIoHead

  proc asyncIoRequestDone(req: AsyncIoRequest): bool {.inline.} =
    req == nil or (req.task.kind == vkTask and req.task.taskDone)

  proc pruneCompletedAsyncIoRequestsUnlocked(s: SchedulerState) =
    if s.pendingAsyncIoRequestsUnlocked() == 0:
      return
    var pending = newSeqOfCap[AsyncIoRequest](s.pendingAsyncIoRequestsUnlocked())
    for i in s.asyncIoHead ..< s.asyncIoQueue.len:
      let req = s.asyncIoQueue[i]
      if not asyncIoRequestDone(req):
        pending.add req
    s.asyncIoQueue = pending
    s.asyncIoHead = 0

proc clearWaitReason(f: Fiber) =
  f.waitChannel = NIL
  f.waitActor = NIL
  f.waitTask = NIL
  f.waitTimer = false

proc workerCandidate(f: Fiber): bool {.inline.} =
  f.workerSafe

proc enqueueRunnableUnlocked(s: SchedulerState, f: Fiber) =
  ## Scheduler-thread callers only. Foreign threads must use the move-based
  ## transfer inside the wake*In procs: this proc copies the fiber ref
  ## (non-atomic inc) and clearWaitReason releases the wait-field Values —
  ## both racy off-thread. The dequeue site clears wait reasons again, which
  ## covers fibers that arrive via the move path.
  clearWaitReason(f)
  s.runQueue.add f
  when compileOption("threads") and defined(gcAtomicArc):
    if f.workerCandidate:
      broadcast(s.workerCond)

proc enqueueAsyncIoRequest(req: AsyncIoRequest): AsyncIoEnqueueResult =
  when compileOption("threads") and defined(gcAtomicArc):
    if configuredSchedulerWorkers() <= 0:
      return aioUnavailable
    let s = currentScheduler()
    var queued = false
    withSchedulerLock(s):
      s.pruneCompletedAsyncIoRequestsUnlocked()
      if s.pendingAsyncIoRequestsUnlocked() < configuredAsyncIoQueueMax():
        markSharedValue(req.task)
        s.asyncIoQueue.add req
        broadcast(s.workerCond)
        queued = true
    if queued: aioQueued else: aioQueueFull
  else:
    aioUnavailable

proc enqueueAsyncReadText(path: string,
                          task: Value): AsyncIoEnqueueResult =
  enqueueAsyncIoRequest(AsyncIoRequest(kind: aioReadText, path: path,
                                       task: task))

proc enqueueAsyncWriteText(path, text: string,
                           task: Value): AsyncIoEnqueueResult =
  enqueueAsyncIoRequest(AsyncIoRequest(kind: aioWriteText, path: path,
                                       text: text, task: task))

proc enqueueAsyncTcpReadText(host: string, port, maxBytes, timeoutMs: int,
                             task: Value): AsyncIoEnqueueResult =
  enqueueAsyncIoRequest(AsyncIoRequest(kind: aioTcpReadText, host: host,
                                       port: port, maxBytes: maxBytes,
                                       timeoutMs: timeoutMs, task: task))

proc enqueueAsyncTcpWriteText(host: string, port: int, text: string,
                              timeoutMs: int,
                              task: Value): AsyncIoEnqueueResult =
  enqueueAsyncIoRequest(AsyncIoRequest(kind: aioTcpWriteText, host: host,
                                       port: port, text: text,
                                       timeoutMs: timeoutMs, task: task))

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
  for item in actor.closeActorAndDrainMessages():
    discard cancelReplyTask(item.reply)
  wakeAllActorSenders(actor)

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

proc generatedDeriveProtocol(scope: Scope, protocol, decl: Value): Value =
  if decl.kind != vkNode:
    raise newException(GeneError, "derive generated declarations must be nodes")
  if not decl.head.isSymbol("impl") or decl.body.len < 2:
    raise newException(GeneError,
      "derive may only generate impl declarations")
  let protocolExpr = decl.body[0]
  case protocolExpr.kind
  of vkProtocol:
    result = protocolExpr
  of vkSymbol:
    if not scope.lookupOptional(protocolExpr.symVal, result):
      # Derive templates are written in the protocol's defining scope, but
      # they run in the deriving type's scope, where a namespaced protocol
      # may not be bound. The deriving protocol's own name always resolves;
      # any other target protocol must be visible at the deriving site
      # (substitute its value with %p in the template to avoid the lookup).
      if protocolExpr.symVal == protocol.protocolName:
        return protocol
      raise newException(GeneError,
        "derive generated impl protocol is undefined: " & protocolExpr.symVal)
    if result.kind != vkProtocol:
      raise newException(GeneError,
        "derive generated impl target must be a protocol")
  of vkNode:
    if protocolExpr.head.isSymbol("path") and protocolExpr.body.len >= 2:
      var resolved: Value
      let head = protocolExpr.body[0]
      if head.kind != vkSymbol or scope == nil or
          not scope.lookupOptional(head.symVal, resolved):
        raise newException(GeneError,
          "derive generated impl protocol is undefined: " & print(protocolExpr))
      for i in 1 ..< protocolExpr.body.len:
        if protocolExpr.body[i].kind != vkSymbol:
          raise newException(GeneError,
            "derive generated impl must name its protocol directly")
        if resolved.kind == vkModule:
          resolved = resolved.moduleRootNamespace
        resolved = resolved.exportedBinding(protocolExpr.body[i].symVal)
      if resolved.kind != vkProtocol:
        raise newException(GeneError,
          "derive generated impl target must be a protocol")
      result = resolved
    else:
      raise newException(GeneError,
        "derive generated impl must name its protocol directly")
  else:
    raise newException(GeneError,
      "derive generated impl must name its protocol directly")

proc runGeneratedDeriveDecl(scope: Scope, protocol, typ, decl: Value) =
  ## Run one derive-generated `(impl Q for T ...)` declaration. A derive may
  ## target any resolvable protocol (cross-protocol generation, e.g. a
  ## Delegate helper generating forwarding impls), but the receiver must be
  ## the deriving type: that co-location is what classifies the generated
  ## pair like an inline impl of the type declaration (canonical at static
  ## top level, overlay otherwise) and keeps derive from registering behavior
  ## for unrelated types at a distance.
  let generatedProtocol = generatedDeriveProtocol(scope, protocol, decl)
  if decl.body.len < 3 or not decl.body[1].isSymbol("for"):
    raise newException(GeneError,
      "derive for " & protocol.protocolName &
      " generated a malformed impl; expected (impl P for " &
      typ.typeName & " ...)")
  let receiverExpr = decl.body[2]
  # The generated impl's receiver must name the deriving type. Match the
  # spliced `%t` value by identity; otherwise match by name — during a type's
  # own derive it is not yet bound, so its name (bare, or as the last segment
  # of a qualified path like `pkg/MyType`) is what a template can spell, and
  # resolving it would fail on the mid-declaration type. The generated impl
  # always substitutes `typ` as the receiver, so this is a sanity gate against
  # an obviously-wrong target, not a strict binding check.
  let receiverName =
    if receiverExpr.kind == vkSymbol:
      receiverExpr.symVal
    elif receiverExpr.kind == vkNode and receiverExpr.head.isSymbol("path") and
        receiverExpr.body.len > 0 and receiverExpr.body[^1].kind == vkSymbol:
      receiverExpr.body[^1].symVal
    else:
      ""
  let receiverOk =
    (receiverExpr.kind == vkType and same(receiverExpr, typ)) or
    (receiverName.len > 0 and receiverName == typ.typeName)
  if not receiverOk:
    raise newException(GeneError,
      "derive for " & protocol.protocolName &
      " must target the deriving type " & typ.typeName &
      ", got: " & receiverExpr.print())
  # Substitute the validated protocol and receiver values for their spelled
  # names so the generated impl compiles/runs in the deriving type's scope
  # even when neither is bound there (e.g. declared inside a namespace).
  var body = @[generatedProtocol, decl.body[1], typ]
  for i in 3 ..< decl.body.len:
    body.add decl.body[i]
  let rewritten = newNode(decl.head, decl.props, body, decl.meta)
  discard run(compileForm(rewritten), scope, validateImplRequirements = false)

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
    runGeneratedDeriveDecl(scope, protocol, typ, generated)
  of vkList:
    for decl in generated.listItems:
      runGeneratedDeriveDecl(scope, protocol, typ, decl)
  else:
    raise newException(GeneError, "derive must return a declaration node or list")

proc consumeEvalStep(budget: EvalBudget) =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    # Repl Ctrl-C rides the budget path: it only runs for budgeted scopes
    # (interactive repl installs one), so plain program dispatch never pays
    # for the volatile load.
    if volatileLoad(addr gVmInterrupt):
      volatileStore(addr gVmInterrupt, false)
      raise newException(GeneError, "interrupted")
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
  # --- sp-register operand stack ---------------------------------------------
  # `sp` is the live stack top; the seq's len is working capacity (slots at or
  # above sp are dead: zeroed by spop's move-out, released by strunc, or
  # default-initialized by growth). Pushes and pops compile to inline
  # index ops instead of out-of-line seq add/shrink calls. The live region
  # is re-materialized as the seq len (stack.setLen(sp)) wherever the stack
  # escapes runLoop: fiber capture and the stackArg hand-back.
  var sp = stack.len

  template spush(v: Value) =
    ## Fast path inline (compare + store + inc); growth in spGrow
    ## ({.noinline.} — inline expansions at ~90 dispatch sites otherwise
    ## bloat runLoop's I-cache footprint, the documented layout trap).
    ## The pushed expression MUST be evaluated before sp or the slot is
    ## touched: arguments like `iteratorStream(spop())` mutate sp.
    block:
      var spushVal = v
      if sp >= stack.len:
        spGrow(stack)
      stack[sp] = move spushVal
      inc sp

  template spop(): Value =
    dec sp
    move stack[sp]

  template strunc(n: int) =
    ## Inline compare only; the release loop lives in spRelease
    ## ({.noinline.}) — 80+ inline while-loops in the dispatch switch are
    ## an I-cache disaster, and balanced returns run zero iterations.
    block:
      let spTarget = int(n)
      if sp > spTarget:
        spRelease(stack, sp, spTarget)

  # The operand stack is shared across frames: each frame's region starts at
  # its recorded base. The outermost frame owns [0..]; pushing a call records
  # the caller's base in its Frame and the callee continues at sp.
  var curStackBase = 0
  var ip = ipArg
  var validateImplRequirements = validateArg
  var evalBudget = scope.evalBudget
  var returnType = NIL          # current frame's return-type to adapt, or NIL
  var returnLabel = ""
  var returnDepth = 0
  # Error-boundary registers for the current frame. The outermost frame is never
  # an ^errors boundary here: direct entry points (applyCall / runPooled) wrap
  # their own try/except, so runLoop only translates frames it pushed itself.
  var curChecksErrors = false
  var curErrorTypes: seq[Value] = @[]
  # Cursor: always borrows a stable owned string — a proto/fiber name kept
  # alive by the current `chunk`/`fiber` registers, or a literal. Assigning
  # through it must never see a temporary.
  var curFnName {.cursor.} = ""
  var curFrameKind = fkNormal
  var curEnsureValue = NIL
  var curEnsureBody: Chunk = nil
  var curEnsureScope: Scope = nil
  var curPendingError: ref GeneError = nil
  var curPendingPanic: ref GenePanic = nil
  var curPendingCancel: ref GeneCancel = nil
  var curPendingReturn: ref GeneReturn = nil
  var curForItems: seq[Value] = @[]
  var curForIndex = 0
  var curForStream = NIL
  var curForPattern = NIL
  var curForBody: Chunk = nil
  var curOwnedScope: Scope = nil
  var curNamespaceName = ""
  var handlers: seq[TryHandler] # active `try` regions, innermost last
  var tailTraceFrames: seq[TailTraceFrame]
  var cancelAtSafepoint = injectCancel
  var remainingBudget = instructionBudget

  if fiber != nil and fiber.started:
    # Resuming a parked fiber: restore the full continuation captured at suspend.
    chunk = fiber.chunk
    scope = fiber.scope
    recycleScope = fiber.recycleScope
    stack = move fiber.stack
    sp = stack.len
    curStackBase = fiber.stackBase
    ip = fiber.ip
    frames = move fiber.frames
    tailTraceFrames = move fiber.tailTraceFrames
    handlers = move fiber.handlers
    validateImplRequirements = fiber.validateImpls
    returnType = fiber.returnType
    returnLabel = fiber.returnLabel
    returnDepth = fiber.returnDepth
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
    curPendingReturn = fiber.pendingReturn
    curForItems = move fiber.forItems
    curForIndex = fiber.forIndex
    curForStream = fiber.forStream
    curForPattern = fiber.forPattern
    curForBody = fiber.forBody
    curOwnedScope = fiber.ownedScope
    curNamespaceName = fiber.namespaceName
    evalBudget = scope.evalBudget
  elif fiber != nil:
    frames = acquireFrameStack(gVmPools)
    recycleScope = fiber.recycleScope
  else:
    frames = acquireFrameStack(gVmPools)

  template loadFrameRegs(f: var Frame) =
    ## Restore the per-frame registers (everything except the operand stack, which
    ## each caller handles explicitly) from a popped Frame. Managed fields are
    ## MOVED out — every caller discards the frame right after — so restoring a
    ## frame costs no refcount traffic and the leftover destroy is trivial.
    if f.restoreSlot >= 0:
      f.scope.slots[f.restoreSlot] = f.restoreValue
    chunk = move f.chunk
    scope = move f.scope
    recycleScope = f.recycleScope
    curStackBase = f.stackBase
    ip = f.ip
    validateImplRequirements = f.validateImpls
    returnType = move f.returnType
    returnLabel = move f.returnLabel
    returnDepth = f.returnDepth
    curChecksErrors = f.checksErrors
    curErrorTypes = move f.errorTypes
    curFnName = f.fnName
    curFrameKind = f.kind
    if f.extra == nil:
      curEnsureValue = NIL
      curEnsureBody = nil
      curEnsureScope = nil
      curPendingError = nil
      curPendingPanic = nil
      curPendingCancel = nil
      curPendingReturn = nil
      curForItems = @[]
      curForIndex = 0
      curForStream = NIL
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
      curPendingReturn = f.extra.pendingReturn
      curForItems = move f.extra.forItems
      curForIndex = f.extra.forIndex
      curForStream = f.extra.forStream
      curForPattern = f.extra.forPattern
      curForBody = f.extra.forBody
      curOwnedScope = f.extra.ownedScope
      curNamespaceName = f.extra.namespaceName
    evalBudget = scope.evalBudget

  template pushFrame() =
    let frameExtra =
      if curFrameKind == fkNormal and curEnsureBody == nil and
          curForItems.len == 0 and curForStream.kind != vkStream and
          curOwnedScope == nil and
          curPendingError == nil and curPendingPanic == nil and
          curPendingCancel == nil and curPendingReturn == nil:
        nil
      else:
        FrameExtra(ensureValue: curEnsureValue,
                   ensureBody: curEnsureBody,
                   ensureScope: curEnsureScope,
                   pendingError: curPendingError,
                   pendingPanic: curPendingPanic,
                   pendingCancel: curPendingCancel,
                   pendingReturn: curPendingReturn,
                   forItems: move curForItems, forIndex: curForIndex,
                   forStream: curForStream,
                   forPattern: curForPattern, forBody: curForBody,
                   ownedScope: curOwnedScope,
                   namespaceName: curNamespaceName)
    # Managed registers are MOVED into the frame; every push site immediately
    # refills them for the frame being entered, so the push itself costs no
    # refcount traffic.
    frames.add Frame(chunk: move chunk, scope: move scope,
                     recycleScope: recycleScope,
                     stackBase: curStackBase, ip: ip,
                     validateImpls: validateImplRequirements,
                     returnType: move returnType,
                     returnLabel: move returnLabel,
                     returnDepth: returnDepth,
                     checksErrors: curChecksErrors,
                     errorTypes: move curErrorTypes, fnName: curFnName,
                     kind: curFrameKind, extra: frameExtra,
                     restoreSlot: -1, restoreValue: NIL)

  template pushFrameFastNormal() =
    frames.add Frame(chunk: move chunk, scope: move scope,
                     recycleScope: recycleScope,
                     stackBase: curStackBase, ip: ip,
                     validateImpls: validateImplRequirements,
                     returnType: move returnType,
                     returnLabel: move returnLabel,
                     returnDepth: returnDepth,
                     checksErrors: curChecksErrors,
                     errorTypes: move curErrorTypes, fnName: curFnName,
                     kind: fkNormal, extra: nil,
                     restoreSlot: -1, restoreValue: NIL)
    returnDepth = frames.len

  template pushCallFrame() =
    if curFrameKind == fkNormal and curEnsureBody == nil and
        curForItems.len == 0 and curForStream.kind != vkStream and
        curOwnedScope == nil and
        curPendingError == nil and curPendingPanic == nil and
        curPendingCancel == nil and curPendingReturn == nil:
      pushFrameFastNormal()
    else:
      pushFrame()
    returnDepth = frames.len

  template enterFrame(nextChunk: Chunk, nextScope: Scope, nextValidate: bool,
                      nextKind: FrameKind = fkNormal) =
    chunk = nextChunk
    scope = nextScope
    recycleScope = false
    scope.prepareChunkScope(chunk)
    curStackBase = sp
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
    curPendingReturn = nil
    curForItems = @[]
    curForIndex = 0
    curForStream = NIL
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
    fiber.returnDepth = returnDepth
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
    fiber.pendingReturn = curPendingReturn
    fiber.forItems = move curForItems
    fiber.forIndex = curForIndex
    fiber.forStream = curForStream
    fiber.forPattern = curForPattern
    fiber.forBody = curForBody
    fiber.ownedScope = curOwnedScope
    fiber.namespaceName = curNamespaceName
    fiber.started = true
    fiber.frames = move frames
    fiber.tailTraceFrames = move tailTraceFrames
    fiber.handlers = move handlers
    setStackLenRaw(stack, sp)   # normalize: live region only escapes runLoop
    fiber.stack = move stack
    fiber.stackBase = curStackBase

  template releaseCurrentCallScope() =
    if recycleScope:
      releaseCallScope(gVmPools, scope)
      recycleScope = false

  proc scopeChainContains(start, target: Scope): bool {.inline.} =
    var current = start
    while current != nil:
      if current == target:
        return true
      current = current.parent
    false

  template trimTailTraceFrames(returnDepth: int) =
    while tailTraceFrames.len > 0 and
        tailTraceFrames[^1].frameDepth >= returnDepth:
      tailTraceFrames.setLen(tailTraceFrames.len - 1)

  template closeCurrentForStream() =
    if curForStream.kind == vkStream:
      curForStream.closeStream()
      curForStream = NIL

  proc releaseFrameCallScope(f: Frame) =
    if f.extra != nil and f.extra.forStream.kind == vkStream:
      f.extra.forStream.closeStream()
    if f.recycleScope:
      releaseCallScope(gVmPools, f.scope)

  template advanceForLoop() =
    if curForStream.kind == vkStream:
      if curForStream.streamHasNext:
        let item = checkedStreamNext(curForStream, "for item")
        let ownerScope = frames[^1].scope
        let loopScope = newScope(ownerScope)
        loopScope.prepareChunkScope(curForBody)
        var binds = initTable[string, Value]()
        if not tryMatch(curForPattern, item, loopScope, binds):
          curForStream.closeStream()
          curForStream = NIL
          raiseMatchError(loopScope, "for pattern did not match an item")
        loopScope.bindMatchedValues(binds, replaceExisting = false)
        chunk = curForBody
        scope = loopScope
        curStackBase = sp
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
        curForStream.closeStream()
        curForStream = NIL
        var owner = frames.pop()
        strunc(curStackBase)
        loadFrameRegs(owner)
        spush NIL
    elif curForIndex < curForItems.len:
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
      curStackBase = sp
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
      strunc(curStackBase)
      loadFrameRegs(owner)
      spush NIL

  template breakForLoop() =
    if curForStream.kind == vkStream:
      curForStream.closeStream()
      curForStream = NIL
    var owner = frames.pop()
    strunc(curStackBase)
    loadFrameRegs(owner)
    spush NIL

  template finishFrameReturn(retValue: Value) =
    if validateImplRequirements and scope.requiredImplTypes.len != 0:
      scope.validateRequiredImpls()
    trimTailTraceFrames(frames.len)
    releaseCurrentCallScope()
    if curFrameKind == fkNormal:
      if frames.len == 0:
        setStackLenRaw(stack, sp)   # normalize: live region only escapes runLoop
        stackArg = move stack
        ipArg = ip
        releaseFrameStack(gVmPools, frames)
        return RunStop(kind: rskReturn, value: retValue)
      else:
        strunc(curStackBase)
        # Restore from the frame in place (moves), then shrink — skips the
        # struct move a frames.pop() into a local would do.
        let callerIndex = frames.len - 1
        template caller: untyped = frames[callerIndex]
        if caller.restoreSlot >= 0 and caller.kind == fkNormal and caller.extra == nil:
          caller.scope.slots[caller.restoreSlot] = caller.restoreValue
          curStackBase = caller.stackBase
          ip = caller.ip
          returnDepth = caller.returnDepth
          if caller.recycleScope or caller.validateImpls or
              caller.returnType.kind != vkNil or caller.returnLabel.len != 0:
            recycleScope = caller.recycleScope
            validateImplRequirements = caller.validateImpls
            returnType = move caller.returnType
            returnLabel = move caller.returnLabel
        else:
          loadFrameRegs(caller)
        frames.setLen(callerIndex)
        spush retValue
    elif curFrameKind == fkEnsureErrorBody:
      raise curPendingError
    elif curFrameKind == fkEnsurePanicBody:
      raise curPendingPanic
    elif curFrameKind == fkEnsureCancelBody:
      raise curPendingCancel
    elif curFrameKind == fkEnsureReturnBody:
      raise curPendingReturn
    elif curFrameKind == fkEnsureValueBody:
      strunc(curStackBase)
      let preserved = curEnsureValue
      var owner = frames.pop()
      strunc(curStackBase)
      loadFrameRegs(owner)
      spush preserved
    elif curFrameKind == fkForBody:
      strunc(curStackBase)
      advanceForLoop()
    elif curFrameKind == fkTaskScopeBody:
      let owned = curOwnedScope
      curFrameKind = fkNormal
      try:
        owned.waitOwnedTasks()
      finally:
        owned.closeOwnedActors()
      strunc(curStackBase)
      var owner = frames.pop()
      strunc(curStackBase)
      loadFrameRegs(owner)
      spush retValue
    elif curFrameKind == fkSupervisorBody:
      let owned = curOwnedScope
      curFrameKind = fkNormal
      owned.closeOwnedActors()
      strunc(curStackBase)
      var owner = frames.pop()
      strunc(curStackBase)
      loadFrameRegs(owner)
      spush retValue
    elif curFrameKind == fkNamespaceBody:
      let nsScope = curOwnedScope
      let nsName = curNamespaceName
      strunc(curStackBase)
      var owner = frames.pop()
      strunc(curStackBase)
      loadFrameRegs(owner)
      let ns = newNamespace(nsName, nsScope)
      scope.define(nsName, ns)
      spush ns
    elif curFrameKind == fkTryBody:
      # The try body succeeded: drop its handler, run ensure, then hand its value
      # back to the enclosing frame (the owner pushed by opTry).
      strunc(curStackBase)
      let h = handlers.pop()
      if h.tp.ensureBody != nil:
        enterFrame(h.tp.ensureBody, h.scope, false, fkEnsureValueBody)
        curEnsureValue = retValue
      else:
        var owner = frames.pop()
        strunc(curStackBase)
        loadFrameRegs(owner)
        spush retValue
    elif curFrameKind == fkCatchBody:
      strunc(curStackBase)
      if curEnsureBody != nil:
        let body = curEnsureBody
        let cleanupScope = curEnsureScope
        enterFrame(body, cleanupScope, false, fkEnsureValueBody)
        curEnsureValue = retValue
      else:
        var owner = frames.pop()
        strunc(curStackBase)
        loadFrameRegs(owner)
        spush retValue
    elif frames.len == 0:
      setStackLenRaw(stack, sp)   # normalize: live region only escapes runLoop
      stackArg = move stack
      ipArg = ip
      releaseFrameStack(gVmPools, frames)
      return RunStop(kind: rskReturn, value: retValue)
    else:
      strunc(curStackBase)
      var caller = frames.pop()
      loadFrameRegs(caller)
      spush retValue

  template finishFastNormalReturn(retValue: Value) =
    trimTailTraceFrames(frames.len)
    releaseCurrentCallScope()
    if frames.len == 0:
      setStackLenRaw(stack, sp)   # normalize: live region only escapes runLoop
      stackArg = move stack
      ipArg = ip
      releaseFrameStack(gVmPools, frames)
      return RunStop(kind: rskReturn, value: retValue)
    else:
      strunc(curStackBase)
      # In-place restore + shrink; see finishFrameReturn.
      let callerIndex = frames.len - 1
      template caller: untyped = frames[callerIndex]
      if caller.restoreSlot >= 0 and caller.kind == fkNormal and caller.extra == nil:
        caller.scope.slots[caller.restoreSlot] = caller.restoreValue
        curStackBase = caller.stackBase
        ip = caller.ip
        returnDepth = caller.returnDepth
        if caller.recycleScope or caller.validateImpls or
            caller.returnType.kind != vkNil or caller.returnLabel.len != 0:
          recycleScope = caller.recycleScope
          validateImplRequirements = caller.validateImpls
          returnType = move caller.returnType
          returnLabel = move caller.returnLabel
      else:
        loadFrameRegs(caller)
      frames.setLen(callerIndex)
      spush retValue

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
    let callScope = acquireSimpleCallScope(gVmPools, scope.parent, proto.localNames,
      keepSlotNames = false, resetSlots = false)
    callScope.entryProtocols = scope.entryProtocols
    callScope.entryProtocolsFrozen = true
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
    curStackBase = sp
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
        curForStream.kind == vkStream or curOwnedScope != nil or
        curPendingError != nil or curPendingPanic != nil or
        curPendingCancel != nil or curPendingReturn != nil:
      enterRecur1Frame(arg, argKnownBareInt)
    let slot = proto.positionalSlots[0]
    let previous = scope.slots[slot]
    frames.add Frame(chunk: chunk, scope: scope, recycleScope: recycleScope,
                     stackBase: curStackBase, ip: ip,
                     validateImpls: validateImplRequirements,
                     returnType: returnType, returnLabel: returnLabel,
                     returnDepth: returnDepth,
                     checksErrors: curChecksErrors,
                     errorTypes: curErrorTypes, fnName: curFnName,
                     kind: fkNormal, extra: nil,
                     restoreSlot: slot, restoreValue: previous)
    returnDepth = frames.len
    scope.slots[slot] = arg
    curStackBase = sp
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

  template restartRecur1SameScopeFrame(arg: Value, argKnownBareInt: bool) =
    let proto = chunk.owner
    if not argKnownBareInt and proto.hasParamTypes and proto.paramTypes.len > 0 and
        proto.paramTypes[0].isBareIntType and arg.kind != vkInt:
      raiseTypeError("parameter '" & proto.params[0] & "'", "Int", arg, scope)
    scope.slots[proto.positionalSlots[0]] = arg
    strunc(curStackBase)
    ip = 0
    evalBudget = scope.evalBudget
    continue

  template canReplaceCurrentTailCall(calleeScope: Scope): bool =
    curFrameKind == fkNormal and not validateImplRequirements and
      returnType.kind == vkNil and not curChecksErrors and
      curEnsureBody == nil and curForItems.len == 0 and
      curForStream.kind != vkStream and curOwnedScope == nil and
      curPendingError == nil and curPendingPanic == nil and
      curPendingCancel == nil and curPendingReturn == nil and
      ip < chunk.instructions.len and
      chunk.instructions[ip].op in {opReturn, opReturnBareInt} and
      (not recycleScope or not scopeChainContains(calleeScope, scope))

  template enterTailCallFrame(nextProto: FunctionProto, nextScope: Scope,
                              nextRecycleScope: bool,
                              nextValidateImpls: bool,
                              nextReturnType: Value,
                              nextReturnLabel: string,
                              nextChecksErrors: bool,
                              nextErrorTypes: seq[Value],
                              nextFnName: string) =
    if curFnName.len > 0:
      tailTraceFrames.add TailTraceFrame(chunk: chunk, ip: ip,
                                         fnName: curFnName,
                                         frameDepth: frames.len)
    releaseCurrentCallScope()
    chunk = nextProto.chunk
    scope = nextScope
    recycleScope = nextRecycleScope
    strunc(curStackBase)
    ip = 0
    validateImplRequirements = nextValidateImpls
    returnType = nextReturnType
    returnLabel = nextReturnLabel
    curChecksErrors = nextChecksErrors
    curErrorTypes = nextErrorTypes
    curFnName = nextFnName
    curFrameKind = fkNormal
    evalBudget = nextScope.evalBudget
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
          spush chunk.constants[inst[].intArg]
        of opLoadName:
          spush scope.lookup(inst[].name)
        of opLoadNativeFast:
          spush scope.loadNativeFast(NativeFastKind(inst[].intArg), inst[].name)
        of opLoadLocal:
          let slot = inst[].intArg
          if slot >= 0 and slot < scope.slots.len and scope.slotDefined(slot):
            spush scope.slots[slot]
          else:
            spush scope.loadSlot(slot, inst[].name)
        of opLoadLocalFast:
          spush scope.slots[inst[].intArg]
        of opLoadArg:
          # Scopeless calls: arguments live on the shared operand stack at the
          # frame's base (they were never popped into a scope).
          spush stack[curStackBase + inst[].intArg]
        of opLoadOuterLocal:
          let slot = inst[].intArg
          let outer =
            if inst[].depth == 1:
              scope.parent
            else:
              scope.scopeAtDepth(inst[].depth, inst[].name)
          if outer != nil and slot >= 0 and slot < outer.slots.len and
              outer.slotDefined(slot):
            spush outer.slots[slot]
          else:
            spush scope.loadSlotAt(inst[].depth, slot, inst[].name)
        of opDefineName:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in var")
          scope.define(inst[].name, stack[sp - 1])
        of opDefineLocal:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in var")
          scope.defineSlot(inst[].intArg, inst[].name, stack[sp - 1])
        of opSetName:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in set")
          rejectCallerEnvEscape("set outer binding '" & inst[].name & "'",
                                stack[sp - 1])
          scope.assign(inst[].name, stack[sp - 1])
        of opSetLocal:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in set")
          scope.assignSlot(inst[].intArg, inst[].name, stack[sp - 1])
        of opSetOuterLocal:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in set")
          rejectCallerEnvEscape("set outer binding '" & inst[].name & "'",
                                stack[sp - 1])
          scope.assignSlotAt(inst[].depth, inst[].intArg, inst[].name, stack[sp - 1])
        of opPop:
          discard spop()
        of opMakeList:
          var items = newSeq[Value](inst[].intArg)
          if inst[].intArg > 0:
            for i in countdown(inst[].intArg - 1, 0):
              items[i] = spop()
          for item in items:
            rejectCallerEnvEscape("list construction", item)
          spush newList(items, inst[].flag)
        of opMakeListSplice:
          let proto = chunk.listBuilds[inst[].intArg]
          var parts = newSeq[Value](proto.splices.len)
          if proto.splices.len > 0:
            for i in countdown(proto.splices.len - 1, 0):
              parts[i] = spop()
          var items: seq[Value]
          for i, part in parts:
            if proto.splices[i]:
              appendSplicedBody(items, part)
            else:
              items.add part
          for item in items:
            rejectCallerEnvEscape("list construction", item)
          spush newList(items, proto.immutable)
        of opMakeMap:
          var values = newSeq[Value](inst[].intArg)
          if inst[].intArg > 0:
            for i in countdown(inst[].intArg - 1, 0):
              values[i] = spop()
          var entries = initPropTable()
          for i, key in inst[].names:
            if values[i].kind != vkVoid:
              rejectCallerEnvEscape("map construction", values[i])
              entries[key] = values[i]
          spush newMap(entries, inst[].flag)
        of opMakeHashMap:
          var entries = newSeq[HashMapEntry](inst[].intArg)
          if inst[].intArg > 0:
            for i in countdown(inst[].intArg - 1, 0):
              let val = spop()
              let key = spop()
              rejectCallerEnvEscape("hash-map key construction", key)
              rejectCallerEnvEscape("hash-map value construction", val)
              entries[i] = HashMapEntry(key: key, val: val)
          spush buildHashMap("general map literal", entries)
        of opMakeNode:
          let proto = chunk.nodeBuilds[inst[].intArg]
          var bodyParts = newSeq[Value](proto.bodyCount)
          if proto.bodyCount > 0:
            for i in countdown(proto.bodyCount - 1, 0):
              bodyParts[i] = spop()
          var props = initPropTable()
          if proto.propNames.len > 0:
            var propValues = newSeq[Value](proto.propNames.len)
            for i in countdown(proto.propNames.len - 1, 0):
              propValues[i] = spop()
            for i, key in proto.propNames:
              if propValues[i].kind != vkVoid:
                props[key] = propValues[i]
          var meta = initPropTable()
          if proto.metaNames.len > 0:
            var metaValues = newSeq[Value](proto.metaNames.len)
            for i in countdown(proto.metaNames.len - 1, 0):
              metaValues[i] = spop()
            for i, key in proto.metaNames:
              if metaValues[i].kind != vkVoid:
                meta[key] = metaValues[i]
          let head = spop()
          rejectCallerEnvEscape("node head construction", head)
          var body: seq[Value]
          for i, part in bodyParts:
            if proto.bodySplices.len > 0 and proto.bodySplices[i]:
              mergeSplicedNodePart(props, body, part)
            else:
              body.add part
          for _, value in props:
            rejectCallerEnvEscape("node prop construction", value)
          for value in body:
            rejectCallerEnvEscape("node body construction", value)
          for _, value in meta:
            rejectCallerEnvEscape("node meta construction", value)
          spush newNode(head, props = props, body = body, meta = meta,
                            immutable = proto.immutable)
        of opMakeSelector:
          var body = newSeq[Value](inst[].intArg)
          if inst[].intArg > 0:
            for i in countdown(inst[].intArg - 1, 0):
              body[i] = spop()
          for item in body:
            rejectCallerEnvEscape("selector construction", item)
          spush newNode(newSym("select"), body = body)
        of opApplySelector:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in selector apply")
          let target = spop()
          let selector = spop()
          spush applySelector(selector, target)
        of opApplySelectorTop:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in selector apply")
          let selector = spop()
          let target = spop()
          spush applySelector(selector, target)
        of opMakeFn:
          let proto = chunk.functions[inst[].intArg]
          let errorTypes = stack.popCheckedErrorTypes(sp, proto.errorTypeCount, scope)
          spush newFunction(proto.name, proto.params, proto, scope,
                                proto.checksErrors, errorTypes,
                                syntaxFn = proto.isSyntaxFn)
        of opMakeEnv:
          let policy = spop()
          let capabilities = spop()
          let module = spop()
          let importsValue = spop()
          let parent = spop()
          let bindingMap = spop()
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
          spush newEnv(bindingsFromMap("env ^bindings", bindingMap), parent,
                           imports, module, capabilities, policy,
                           bindingScope = scope)
        of opEval:
          let env = spop()
          let node = spop()
          if env.kind notin {vkEnv, vkCallerEnv}:
            raise newException(GeneError,
              "eval ^in must be an Env or live CallerEnv")
          let evalParent =
            if env.kind == vkCallerEnv:
              materializeCallerEvalParent(env)
            else:
              materializeEvalParent(env)
          let evalScope = newScope(evalParent)
          evalScope.implOverlayRoot = true
          evalScope.evalBudget =
            if env.kind == vkCallerEnv:
              scope.evalBudget
            else:
              evalBudgetForPolicy(env.envPolicy, scope.evalBudget)
          let evalChunk =
            try:
              compileEvalForm(node)
            except GeneError as e:
              raiseCompileError(scope, e.msg)
              newChunk()
          pushFrame()
          enterFrame(evalChunk, evalScope, true)
          continue
        of opMakeAlias:
          # (alias Name Expr): the type expr sits on the stack (compiled as a
          # quoted constant). Wrap it as a transparent alias bound to `name`.
          let expr = spop()
          spush newTypeAlias(inst[].name, expr)
        of opMakeType:
          let proto = chunk.typeProtos[inst[].intArg]
          let parent = spop()
          if parent.kind != vkNil and parent.kind != vkType:
            raise newException(GeneError, "type ^is must be a type")
          var derivedProtocols = newSeq[Value](proto.deriveProtocolCount)
          if proto.deriveProtocolCount > 0:
            for i in countdown(proto.deriveProtocolCount - 1, 0):
              let protocol = spop()
              if protocol.kind != vkProtocol:
                raise newException(GeneError, "type ^derive entries must be protocols")
              derivedProtocols[i] = protocol
          var requiredProtocols = newSeq[Value](proto.requiredImplCount)
          if proto.requiredImplCount > 0:
            for i in countdown(proto.requiredImplCount - 1, 0):
              let protocol = spop()
              if protocol.kind != vkProtocol:
                raise newException(GeneError, "type ^impl entries must be protocols")
              requiredProtocols[i] = protocol
          var inlineProtocols = newSeq[Value](proto.inlineImpls.len)
          var inlineErrorTypes = newSeq[seq[seq[Value]]](proto.inlineImpls.len)
          if proto.inlineImpls.len > 0:
            for i in countdown(proto.inlineImpls.len - 1, 0):
              let protocolValue = spop()
              if protocolValue.kind != vkProtocol:
                raise newException(GeneError, "impl target must be a protocol")
              inlineProtocols[i] = protocolValue
              let inlineMessages = proto.inlineImpls[i].messages
              inlineErrorTypes[i] = newSeq[seq[Value]](inlineMessages.len)
              for j in countdown(inlineMessages.len - 1, 0):
                inlineErrorTypes[i][j] =
                  stack.popCheckedErrorTypes(sp, inlineMessages[j].fn.errorTypeCount,
                                             scope)
          var messageErrorTypes = newSeq[seq[Value]](proto.messages.len)
          if proto.messages.len > 0:
            for i in countdown(proto.messages.len - 1, 0):
              messageErrorTypes[i] =
                stack.popCheckedErrorTypes(sp, proto.messages[i].fn.errorTypeCount, scope)
          var messages = initTable[string, Value]()
          for i, message in proto.messages:
            # `(super ~ m)` in this body delegates to the enclosing type's `^is`
            # parent; stamp that identity on the body now that it is known.
            stampSuperType(message.fn, parent)
            let fn = newFunction(message.fn.name, message.fn.params, message.fn,
                                 scope, message.fn.checksErrors,
                                 messageErrorTypes[i])
            messages[message.name] = functionForScopeStorage(fn, scope)
          if parent.kind == vkType:
            for name, messageFn in messages:
              let inherited = parent.typeDirectMessage(name)
              if inherited.kind != vkNil:
                validateCallableSignature(inherited, messageFn,
                  "type message " & proto.name & "/" & name)
          # The ctor error row compiles before the message rows, so it pops last.
          var ctorFn = NIL
          if proto.ctorFn != nil:
            let ctorErrorTypes =
              stack.popCheckedErrorTypes(sp, proto.ctorFn.errorTypeCount, scope)
            let fn = newFunction(proto.ctorFn.name, proto.ctorFn.params,
                                 proto.ctorFn, scope, proto.ctorFn.checksErrors,
                                 ctorErrorTypes)
            ctorFn = functionForScopeStorage(fn, scope)
          let typ = newType(proto.name, parent, proto.fields, requiredProtocols, scope,
                            derivedProtocols, proto.deriveRequests,
                            proto.bodyFields, messages, ctorFn)
          # Inline impls register exactly like standalone (impl P for T ...) forms
          # written after the type declaration (docs/core.md §8), before
          # ^derive runs so manual-vs-generated conflicts surface normally.
          for i, inline in proto.inlineImpls:
            var entries: seq[ImplMessage]
            for j, message in inline.messages:
              let resolved = resolveImplMessage(scope, inlineProtocols[i],
                                                message.protocolPath,
                                                message.name)
              let fn = newFunction(message.fn.name, message.fn.params,
                                   message.fn, scope, message.fn.checksErrors,
                                   inlineErrorTypes[i][j])
              entries.add ImplMessage(message: resolved,
                                      fn: functionForScopeStorage(fn, scope))
            scope.registerImpl(inlineProtocols[i], typ, entries,
              scope.classifyInlineImpl(proto.staticTopLevel))
          let savedForceOverlay = scope.forceOverlayImpls
          if not proto.staticTopLevel:
            scope.forceOverlayImpls = true
          try:
            for i, protocol in derivedProtocols:
              applyProtocolDerive(scope, protocol, typ, proto.deriveRequests[i])
          finally:
            scope.forceOverlayImpls = savedForceOverlay
          if proto.requiredImplCount > 0:
            if proto.staticTopLevel:
              scope.requiredImplTypes.add typ
            else:
              scope.validateRequiredImplType(typ)
          spush typ
        of opMakeEnum:
          let proto = chunk.enumProtos[inst[].intArg]
          var inlineProtocols = newSeq[Value](proto.inlineImpls.len)
          var inlineErrorTypes = newSeq[seq[seq[Value]]](proto.inlineImpls.len)
          if proto.inlineImpls.len > 0:
            for i in countdown(proto.inlineImpls.len - 1, 0):
              let protocolValue = spop()
              if protocolValue.kind != vkProtocol:
                raise newException(GeneError, "impl target must be a protocol")
              inlineProtocols[i] = protocolValue
              let inlineMessages = proto.inlineImpls[i].messages
              inlineErrorTypes[i] = newSeq[seq[Value]](inlineMessages.len)
              for j in countdown(inlineMessages.len - 1, 0):
                inlineErrorTypes[i][j] =
                  stack.popCheckedErrorTypes(sp, inlineMessages[j].fn.errorTypeCount,
                                             scope)
          var messageErrorTypes = newSeq[seq[Value]](proto.messages.len)
          if proto.messages.len > 0:
            for i in countdown(proto.messages.len - 1, 0):
              messageErrorTypes[i] =
                stack.popCheckedErrorTypes(sp, proto.messages[i].fn.errorTypeCount, scope)
          var messages = initTable[string, Value]()
          for i, message in proto.messages:
            let fn = newFunction(message.fn.name, message.fn.params, message.fn,
                                 scope, message.fn.checksErrors,
                                 messageErrorTypes[i])
            messages[message.name] = functionForScopeStorage(fn, scope)
          if proto.backingType.kind != vkNil:
            var seenBacking: seq[Value]
            for variant in proto.variants:
              if variant.payloadTypes.len != 0:
                raise newException(GeneError,
                  "enum ^backing is rejected when variants carry payload")
              if not variant.hasBacking:
                raise newException(GeneError,
                  "backed enum variant requires a backing value: " & variant.name)
              discard adaptBoundary("backing for " & proto.name & "/" &
                                    variant.name, proto.backingType,
                                    variant.backing, scope)
              for existing in seenBacking:
                if equal(existing, variant.backing):
                  raise newException(GeneError,
                    "duplicate backing value for enum " & proto.name)
              seenBacking.add variant.backing
          var variants: seq[tuple[name: string, payloadTypes: seq[Value],
                                  hasBacking: bool, backing: Value]]
          for variant in proto.variants:
            variants.add (variant.name, variant.payloadTypes,
                          variant.hasBacking, variant.backing)
          let enumType = newEnum(proto.name, proto.typeParams, variants,
                                 proto.backingType, scope, messages)
          for i, inline in proto.inlineImpls:
            var entries: seq[ImplMessage]
            for j, message in inline.messages:
              let resolved = resolveImplMessage(scope, inlineProtocols[i],
                                                message.protocolPath,
                                                message.name)
              let fn = newFunction(message.fn.name, message.fn.params,
                                   message.fn, scope, message.fn.checksErrors,
                                   inlineErrorTypes[i][j])
              entries.add ImplMessage(message: resolved,
                                      fn: functionForScopeStorage(fn, scope))
            scope.registerImpl(inlineProtocols[i], enumType, entries,
              scope.classifyInlineImpl(proto.staticTopLevel))
          spush enumType
        of opMakeProtocol:
          let proto = chunk.protocolProtos[inst[].intArg]
          var parents = newSeq[Value](proto.parentCount)
          if proto.parentCount > 0:
            for i in countdown(proto.parentCount - 1, 0):
              let parentProtocol = spop()
              if parentProtocol.kind != vkProtocol:
                raise newException(GeneError,
                  "protocol ^inherit entries must be protocols")
              parents[i] = parentProtocol
          var messageErrorTypes = newSeq[seq[Value]](proto.messages.len)
          if proto.messages.len > 0:
            for i in countdown(proto.messages.len - 1, 0):
              messageErrorTypes[i] =
                stack.popCheckedErrorTypes(sp, proto.messages[i].fn.errorTypeCount,
                                           scope)
          var deriveFn = NIL
          if proto.deriveFn != nil:
            deriveFn = newFunction(proto.deriveFn.name, proto.deriveFn.params,
                                   proto.deriveFn, scope)
            deriveFn = functionForScopeStorage(deriveFn, scope)
          var messageNames: seq[string]
          var signatures: seq[Value]
          var hasDefaults: seq[bool]
          for i, message in proto.messages:
            messageNames.add message.name
            var fn = newFunction(message.fn.name, message.fn.params,
                                 message.fn, scope, message.fn.checksErrors,
                                 messageErrorTypes[i])
            fn = functionForScopeStorage(fn, scope)
            signatures.add fn
            hasDefaults.add message.hasDefault
          let protocol = newProtocol(proto.name, messageNames, deriveFn,
                                     parents, signatures, hasDefaults,
                                     proto.universal, scope)
          # Message names are not bound in the enclosing scope (docs/core.md
          # §1, OQ-I): messages are reached via Protocol/name and sends.
          spush protocol
        of opMakeImpl:
          let proto = chunk.implProtos[inst[].intArg]
          var messageErrorTypes = newSeq[seq[Value]](proto.messages.len)
          if proto.messages.len > 0:
            for i in countdown(proto.messages.len - 1, 0):
              messageErrorTypes[i] =
                stack.popCheckedErrorTypes(sp, proto.messages[i].fn.errorTypeCount, scope)
          let receiver = spop()
          let protocol = spop()
          if protocol.kind != vkProtocol:
            raise newException(GeneError, "impl target must be a protocol")
          var entries: seq[ImplMessage]
          for i, message in proto.messages:
            let resolved = resolveImplMessage(scope, protocol,
                                              message.protocolPath,
                                              message.name)
            let fn = newFunction(message.fn.name, message.fn.params, message.fn,
                                 scope, message.fn.checksErrors,
                                 messageErrorTypes[i])
            entries.add ImplMessage(message: resolved,
                                    fn: functionForScopeStorage(fn, scope))
          let visibility = scope.classifyStandaloneImpl(protocol, receiver,
                                                        proto)
          scope.registerImpl(protocol, receiver, entries, visibility,
                             proto.exported)
          spush NIL
        of opMakeNamespace:
          # Run the ns body in a fresh child scope; its bindings become the
          # namespace's exports. Bind the namespace in the enclosing scope.
          let nsScope = newScope(scope)
          nsScope.moduleStatic = inst[].flag
          # Hoisted: pushFrame moves the chunk register into the frame.
          let nsBody = chunk.subchunks[inst[].intArg]
          pushFrame()
          enterFrame(nsBody, nsScope,
                     validateImplRequirements, fkNamespaceBody)
          curOwnedScope = nsScope
          curNamespaceName = inst[].name
          continue
        of opSetModuleName:
          var module: Value
          if scope.lookupOptional("this_mod", module):
            if module.kind == vkModule:
              module.setModuleName(inst[].name)
              if inst[].intArg >= 0 and inst[].intArg < chunk.constants.len:
                let metaValue = chunk.constants[inst[].intArg]
                if metaValue.kind == vkMap:
                  module.setModuleMeta(copyEntries(metaValue.mapEntries))
            elif module.kind == vkNamespace and module.nsIsModuleRoot:
              module.setNsName(inst[].name)
          spush NIL
        of opImport:
          let spec = chunk.imports[inst[].intArg]
          var source: Value
          if spec.fromModule:
            let app = scope.application()
            source = loadModuleValue(app, app.resolveModulePath(spec.modulePath))
          else:
            # Resolve the import-source root as initialized-local → builtin →
            # error. `lookupOptional` walks the scope chain (nearer in-file
            # namespace before the builtins root) and returns false for a
            # declared-but-uninitialized local slot, so a later local named
            # `db`, `str`, etc. cannot make `import db/...` observe an
            # uninitialized binding — the original hazard — while an
            # initialized in-file `(ns str ...)` is no longer silently
            # shadowed by a builtin of the same name.
            var local: Value
            if scope.lookupOptional(spec.nsSegments[0], local) and
                local.kind in {vkNamespace, vkModule}:
              source = local
            else:
              source = scope.application().builtinsScope().lookup(
                spec.nsSegments[0])
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
          var wildcardNs = sourceNs
          for segment in spec.wildcardSegments:
            wildcardNs = wildcardNs.exportedBinding(segment)
            if wildcardNs.kind != vkNamespace:
              raise newException(GeneError,
                "import namespace has no export: " &
                spec.wildcardSegments.join("/"))
          if spec.alias.len > 0:
            let aliasValue =
              if spec.wildcard and spec.wildcardSegments.len > 0: wildcardNs
              else: source
            scope.define(spec.alias, aliasValue)
          if spec.wildcard and spec.alias.len == 0:
            for name in spec.wildcardNames:
              let value = wildcardNs.exportedBinding(name)
              if value.kind == vkVoid:
                raise newException(GeneError,
                  "module compile interface export is unavailable at runtime: " &
                  spec.sourceLabel & "/" & name)
              scope.addWildcardFallback(name, value, spec.sourceLabel)
          for sel in spec.selections:
            let v = sourceNs.exportedBinding(sel.name)
            if v.kind == vkVoid:
              raise newException(GeneError, "module/namespace has no export: " & sel.name)
            scope.define(sel.local, v)
          spush NIL
        of opImportImpl:
          let spec = chunk.importImpls[inst[].intArg]
          let receiver = spop()
          let protocol = spop()
          if protocol.kind != vkProtocol:
            raise newException(GeneError,
              "import_impl target must be a protocol")
          if receiver.kind != vkType:
            raise newException(GeneError,
              "import_impl receiver must be a type")
          let app = scope.application()
          let source = loadModuleValue(app,
            app.resolveModulePath(spec.modulePath))
          scope.importScopedImpl(source.moduleRootNamespace.nsScope,
                                 protocol, receiver)
          spush NIL
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
                  spush native.value
                  continue
              if proto.scopelessChunk != nil and proto.params.len == 0:
                # Scopeless 0-arg call (see the direct-call site).
                pushCallFrame()
                scope = frames[^1].scope
                chunk = proto.scopelessChunk
                recycleScope = false
                curStackBase = sp
                ip = 0
                validateImplRequirements = false
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
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
                      acquireSimpleCallScope(gVmPools, callee.fnScope, proto.localNames,
                        proto.callScopeNeedsSlotNames,
                        proto.callScopeNeedsSlotReset)
                    else:
                      let fresh = newScope(callee.fnScope)
                      fresh.prepareSlots(proto.localNames)
                      fresh
                  else:
                    callee.fnScope
                callScope.seedFunctionProtocolEntry(callee)
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif not proto.isGenerator:
                if callee.isSyntaxFn:
                  rejectSyntaxCallWithoutSite(callee)
                let bound = bindCallScope(callee, proto, [], NamedArgs())
                let frameReturnType = proto.checkedFrameReturnType(bound.returnType)
                var lbl = ""
                if frameReturnType.kind != vkNil:
                  lbl = "return from '" & callee.fnName & "'"
                pushCallFrame()
                chunk = proto.chunk
                scope = bound.scope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
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
            value = applyCall(callee, [], NamedArgs(), scope, site,
                              instructionLocAt(chunk, ip - 1))
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            spush NIL
            captureContinuation(ip)
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          spush value
        of opCallName0, opCallName1, opCallNameN, opCallLocal1, opCallLocalN,
            opCallParentLocal0, opCallParentLocal1, opCallOuterLocal0,
            opCallOuterLocal1:
          let argCount =
            if inst[].op in {opCallName0, opCallParentLocal0,
                             opCallOuterLocal0}: 0
            elif inst[].op in {opCallNameN, opCallLocalN}: inst[].depth
            else: 1
          if sp < argCount:
            raise newException(GeneError, "VM stack underflow in direct call")
          let argsStart = sp - argCount
          var callee =
            if inst[].op in {opCallName0, opCallName1, opCallNameN}:
              scope.lookup(inst[].name)
            elif inst[].op == opCallLocal1 or inst[].op == opCallLocalN:
              let slot = inst[].intArg
              if slot >= 0 and slot < scope.slots.len and scope.slotDefined(slot):
                scope.slots[slot]
              else:
                scope.loadSlot(slot, inst[].name)
            elif inst[].op == opCallParentLocal0 or
                inst[].op == opCallParentLocal1:
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
          if callee.kind == vkProtocolMessage:
            rejectMessageCall(callee, scope)
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
                      stack.toOpenArray(argsStart, (sp - 1)), NamedArgs())
                if native.handled:
                  strunc(argsStart)
                  spush native.value
                  continue
              if proto.scopelessChunk != nil and argCount == proto.params.len and
                  (not proto.scopelessNeedsIntArgs or inst[].flag or
                   scopelessIntArgsOk(stack, argsStart, argCount)):
                # Scopeless call: the args already on the shared stack become
                # the callee's frame region (opLoadArg reads them at
                # base+index) and the callee keeps the CALLER's scope register
                # — its body never resolves names, so the scope only feeds
                # native-fast fallbacks (scope.application). No scope is
                # acquired, bound, or released; the normal return truncation
                # to curStackBase discards the args.
                pushCallFrame()
                scope = frames[^1].scope
                chunk = proto.scopelessChunk
                recycleScope = false
                curStackBase = argsStart
                ip = 0
                validateImplRequirements = false
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
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
                        acquireSimpleCallScope(gVmPools, callee.fnScope, proto.localNames,
                          proto.callScopeNeedsSlotNames,
                          proto.callScopeNeedsSlotReset)
                      else:
                        let fresh = newScope(callee.fnScope)
                        fresh.prepareSlots(proto.localNames)
                        fresh
                    if argCount > 0:
                      created.bindSimpleCallSlots(
                        proto, stack.toOpenArray(argsStart, (sp - 1)))
                    created
                  else:
                    callee.fnScope
                callScope.seedFunctionProtocolEntry(callee)
                strunc(argsStart)
                if argsStart == 0 and canReplaceCurrentTailCall(callee.fnScope):
                  enterTailCallFrame(proto, callScope, proto.poolCallScope,
                    proto.frameNeedsImplValidation, NIL, "", false, @[],
                    callee.fnName)
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif argCount == 1 and proto.canFastBindUnaryInt and
                  proto.returnKnownBareInt and
                  (inst[].flag or stack[argsStart].kind == vkInt):
                let callScope = bindUnaryIntCallScope(callee, proto,
                                                      stack[argsStart])
                strunc(argsStart)
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif argCount > 1 and proto.canFastBindPositionalInt and
                  proto.returnKnownBareInt and argCount == proto.params.len and
                  inst[].flag:
                let callScope = bindPositionalIntCallScope(callee, proto,
                  stack.toOpenArray(argsStart, (sp - 1)),
                  argsKnownBareInt = true)
                strunc(argsStart)
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif not proto.isGenerator:
                if callee.isSyntaxFn:
                  rejectSyntaxCallWithoutSite(callee)
                var boundScope: Scope
                var boundReturnType: Value
                var usedUnaryIntFast = false
                if argCount == 1 and proto.canFastBindUnaryInt and
                    (inst[].flag or stack[argsStart].kind == vkInt):
                  boundScope = bindUnaryIntCallScope(callee, proto,
                                                     stack[argsStart])
                  boundReturnType = proto.returnType
                  usedUnaryIntFast = true
                elif proto.canFastBindPositionalInt and
                    argCount == proto.params.len:
                  boundScope = bindPositionalIntCallScope(callee, proto,
                    stack.toOpenArray(argsStart, (sp - 1)),
                    argsKnownBareInt = inst[].flag)
                  boundReturnType = proto.returnType
                else:
                  let bound =
                    if argCount == 0:
                      bindCallScope(callee, proto, [], NamedArgs())
                    else:
                      bindCallScope(callee, proto,
                        stack.toOpenArray(argsStart, (sp - 1)), NamedArgs())
                  boundScope = bound.scope
                  boundReturnType = bound.returnType
                strunc(argsStart)
                boundReturnType = proto.checkedFrameReturnType(boundReturnType)
                var lbl = ""
                if boundReturnType.kind != vkNil and not usedUnaryIntFast:
                  lbl = "return from '" & callee.fnName & "'"
                pushCallFrame()
                chunk = proto.chunk
                scope = boundScope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
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
                applyCall(callee, [], NamedArgs(), scope, site,
                          instructionLocAt(chunk, ip - 1))
              else:
                applyCall(callee, stack.toOpenArray(argsStart, (sp - 1)),
                          NamedArgs(), scope, site,
                          instructionLocAt(chunk, ip - 1))
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            strunc(argsStart)
            spush NIL
            captureContinuation(ip)
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          strunc(argsStart)
          spush value
        of opRecur1:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in recur call")
          let argsStart = sp - 1
          var arg = stack[argsStart]
          strunc(argsStart)
          enterRecur1Frame(arg, inst[].flag)
        of opRecur1LocalIntSubConst, opRecur1LocalIntSubImm,
            opRecur1LocalIntSubConstSameScope, opRecur1LocalIntSubImmSameScope:
          let slot = inst[].intArg
          if slot < 0 or slot >= scope.slots.len:
            raise newException(GeneError,
              "VM local slot out of range for recur: " & inst[].name)
          let a = scope.slots[slot]
          var arg: Value
          var argKnownBareInt = true
          if inst[].op in {opRecur1LocalIntSubImm,
                           opRecur1LocalIntSubImmSameScope} and a.isSmallInt:
            arg = newInt(a.smallIntVal - int64(inst[].depth))
          else:
            let b =
              if inst[].op in {opRecur1LocalIntSubImm,
                               opRecur1LocalIntSubImmSameScope}:
                newInt(inst[].depth)
              else:
                chunk.constants[inst[].depth]
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
          if inst[].op in {opRecur1LocalIntSubConstSameScope,
                           opRecur1LocalIntSubImmSameScope}:
            if curFrameKind == fkNormal and not validateImplRequirements and
                returnType.kind == vkNil and not curChecksErrors and
                curEnsureBody == nil and curForItems.len == 0 and
                curForStream.kind != vkStream and curOwnedScope == nil and
                curPendingError == nil and curPendingPanic == nil and
                curPendingCancel == nil and curPendingReturn == nil and
                ip < chunk.instructions.len and
                chunk.instructions[ip].op in {opReturn, opReturnBareInt}:
              restartRecur1SameScopeFrame(arg, argKnownBareInt)
            else:
              enterRecur1SameScopeFrame(arg, argKnownBareInt)
          else:
            enterRecur1Frame(arg, argKnownBareInt)
        of opReturnLocalIfIntLtConst, opReturnLocalIfIntLtImm:
          let slot = inst[].intArg
          if slot < 0 or slot >= scope.slots.len:
            raise newException(GeneError,
              "VM local slot out of range for int return guard: " & inst[].name)
          let a = scope.slots[slot]
          var matched = false
          if inst[].op == opReturnLocalIfIntLtImm and a.isSmallInt:
            matched = a.smallIntVal < int64(inst[].depth)
          else:
            let b =
              if inst[].op == opReturnLocalIfIntLtImm:
                newInt(inst[].depth)
              else:
                chunk.constants[inst[].depth]
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
        of opResolveMessage:
          # Receiver-first message send (docs/core.md §9.1): an unqualified send
          # reaches only the receiver's type-direct messages (walking `^is`),
          # then the built-in type-direct surface. There is no protocol tier and
          # no lexical fallback — protocol messages are always qualified
          # (`x ~ P/m`). The resolved callee is inserted below any named argument
          # values already on the stack, then the receiver goes back on top as
          # the first positional argument.
          let receiver = spop()
          if receiver.nodeConstructing and inst[].name notin
              ["set_prop!", "set_body!", "push_body!"]:
            raise newException(GeneError,
              "cannot dispatch '" & inst[].name &
              "' on an in-progress constructed instance")
          var callee = NIL
          let recvType = receiver.receiverType
          # An unqualified send reaches only type-direct messages, walking the
          # `^is` chain (design §3/§9). Protocol messages are always qualified —
          # `(x ~ P/m)` — so a protocol impl is never reached by a bare name.
          if recvType.kind == vkType:
            when dispatchCacheEnabled:
              # site = this instruction's index (ip was advanced at loop top).
              let site = ip - 1
              let epoch = scope.application().implEpoch
              let cacheable = not scope.chainHasTransientImpls()
              if cacheable:
                callee = chunk.dispatchCacheLookup(site, recvType, 0'u64, epoch)
            if callee.kind == vkNil:
              callee = typeDirectMessage(recvType, inst[].name)
              when dispatchCacheEnabled:
                if cacheable and callee.kind != vkNil:
                  chunk.dispatchCacheFill(site, recvType, 0'u64, epoch, callee)
          if callee.kind == vkNil:
            callee = builtinReceiverMessage(scope, receiver, inst[].name)
          if callee.kind == vkNil:
            # `~` dispatches only (design §3). There is no lexical fallback — a
            # name that resolves to no type-direct message is a MessageError,
            # with a hint when it names a lexical callable (likely a call, not a
            # send) or a same-named protocol message (needs qualification).
            var lexical: Value
            let lexicalHint = scope.lookupOptional(inst[].name, lexical) and
              lexical.kind in {vkFunction, vkNativeFn}
            let recvTypeName =
              if recvType.kind == vkType: recvType.typeName
              else: declarationKind(receiver)
            raiseMessageError(inst[].name, recvTypeName, scope, lexicalHint)
          if callee.isSyntaxFn:
            rejectSyntaxSend(callee, scope)
          if inst[].intArg > 0:
            # Insert the callee below its intArg already-pushed args: shift
            # them up one slot in place (seq insert would grow len, breaking
            # the sp-register capacity invariant). Growth must go through
            # spGrow: managed setLen would leave realloc slack above the new
            # len unzeroed, breaking spGrow's all-zero-above-len invariant.
            if sp >= stack.len:
              spGrow(stack)
            var insertAt = sp - inst[].intArg
            var shiftIndex = sp
            while shiftIndex > insertAt:
              stack[shiftIndex] = move stack[shiftIndex - 1]
              dec shiftIndex
            stack[insertAt] = callee
            inc sp
          else:
            spush callee
          spush receiver
        of opSuperSend:
          # Parent delegation (design §10): resolve the message from the parent
          # of the *enclosing* type (not the receiver's runtime type), but call
          # it with `self`. The parent identity was stamped onto this chunk when
          # the type was created, so no user-visible name is resolved here and a
          # message-body local cannot redirect the delegation.
          let receiver = spop()             # self
          let superType = chunk.superType
          var callee = NIL
          if superType.kind == vkType:
            # A super site is statically monomorphic — the parent type comes
            # from the chunk and the message name from the instruction — so the
            # per-site cache only has to guard the impl epoch (reload/overlay).
            when dispatchCacheEnabled:
              let site = ip - 1
              let epoch = scope.application().implEpoch
              callee = chunk.dispatchCacheLookup(site, superType, 0'u64, epoch)
              if callee.kind == vkNil:
                callee = typeDirectMessage(superType, inst[].name)
                if callee.kind != vkNil:
                  chunk.dispatchCacheFill(site, superType, 0'u64, epoch, callee)
            else:
              callee = typeDirectMessage(superType, inst[].name)
          if callee.kind == vkNil:
            raiseMessageError(inst[].name,
              (if superType.kind == vkType: "super " & superType.typeName
               else: "super"),
              scope, false)
          if callee.isSyntaxFn:
            rejectSyntaxSend(callee, scope)
          if inst[].intArg > 0:
            if sp >= stack.len:
              spGrow(stack)
            var insertAt = sp - inst[].intArg
            var shiftIndex = sp
            while shiftIndex > insertAt:
              stack[shiftIndex] = move stack[shiftIndex - 1]
              dec shiftIndex
            stack[insertAt] = callee
            inc sp
          else:
            spush callee
          spush receiver
        of opPlaceSendReceiver:
          # [callee, receiver, named...] -> [callee, named..., receiver]. The
          # resolution itself happened before named argument evaluation.
          let namedCount = inst[].intArg
          if namedCount <= 0 or sp < namedCount + 2:
            raise newException(GeneError,
              "VM stack underflow placing message receiver")
          let receiverIndex = sp - namedCount - 1
          var receiver = move stack[receiverIndex]
          for i in receiverIndex ..< sp - 1:
            stack[i] = move stack[i + 1]
          stack[sp - 1] = move receiver
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
          let argsStart = sp - argCount
          if argsStart < 0 or argsStart < namedCount + 1:
            raise newException(GeneError, "VM stack underflow in call")
          let calleeIndex = argsStart - namedCount - 1
          var callee = stack[calleeIndex]
          # A message identity is not callable in head position (design §3):
          # qualified sends resolve their impl in opResolveQualifiedMessage, so a
          # message value reaching an ordinary call is source like `(P/m x)`.
          if callee.kind == vkProtocolMessage:
            rejectMessageCall(callee, scope)
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
                                        stack.toOpenArray(argsStart, (sp - 1)),
                                        nativeNamed)
                if native.handled:
                  strunc(calleeIndex)
                  spush native.value
                  continue
              if namedCount == 0 and proto.scopelessChunk != nil and
                  argCount == proto.params.len and
                  (not proto.scopelessNeedsIntArgs or
                   scopelessIntArgsOk(stack, argsStart, argCount)):
                # Scopeless call (see the direct-call site): shift the args
                # down over the callee so they sit at the frame base, then
                # enter without any scope acquire/bind/release.
                for i in calleeIndex ..< sp - 1:
                  stack[i] = stack[i + 1]
                strunc(sp - 1)
                pushCallFrame()
                scope = frames[^1].scope
                chunk = proto.scopelessChunk
                recycleScope = false
                curStackBase = calleeIndex
                ip = 0
                validateImplRequirements = false
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false
                curErrorTypes = @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
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
                        acquireSimpleCallScope(gVmPools, callee.fnScope, proto.localNames,
                          proto.callScopeNeedsSlotNames,
                          proto.callScopeNeedsSlotReset)
                      else:
                        let fresh = newScope(callee.fnScope)
                        fresh.prepareSlots(proto.localNames)
                        fresh
                    if argCount > 0:
                      created.bindSimpleCallSlots(
                        proto, stack.toOpenArray(argsStart, (sp - 1)))
                    created
                else:
                  callee.fnScope
                callScope.seedFunctionProtocolEntry(callee)
                strunc(calleeIndex)        # consume callee + args
                if calleeIndex == 0 and canReplaceCurrentTailCall(callee.fnScope):
                  enterTailCallFrame(proto, callScope, proto.poolCallScope,
                    proto.frameNeedsImplValidation, NIL, "", false, @[],
                    callee.fnName)
                pushCallFrame()
                chunk = proto.chunk
                scope = callScope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
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
                if callee.isSyntaxFn:
                  rejectSyntaxCallWithoutSite(callee)
                var boundScope: Scope
                var boundReturnType: Value
                if namedCount > 0 and proto.canFastBindRequiredNamed:
                  boundScope = bindRequiredNamedCallScope(callee, proto,
                    callee.fnName, stack.toOpenArray(argsStart, (sp - 1)),
                    inst[].names, stack, calleeIndex + 1)
                  boundReturnType = proto.returnType
                elif namedCount == 0 and proto.canFastBindPositionalInt and
                    argCount == proto.params.len:
                  boundScope = bindPositionalIntCallScope(callee, proto,
                    stack.toOpenArray(argsStart, (sp - 1)))
                  boundReturnType = proto.returnType
                else:
                  var named: NamedArgs
                  if namedCount > 0:
                    named = namedArgsFromStack(inst[].names, stack,
                                               calleeIndex + 1)
                  let bound =
                    if argCount == 0:
                      bindCallScope(callee, proto, [], named)
                    else:
                      bindCallScope(callee, proto,
                                    stack.toOpenArray(argsStart, (sp - 1)), named)
                  boundScope = bound.scope
                  boundReturnType = bound.returnType
                let frameReturnType = proto.checkedFrameReturnType(boundReturnType)
                strunc(calleeIndex)
                var lbl = ""
                if frameReturnType.kind != vkNil:
                  lbl = "return from '" & callee.fnName & "'"
                pushCallFrame()
                chunk = proto.chunk
                scope = boundScope
                recycleScope = proto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = proto.frameNeedsImplValidation
                returnType = frameReturnType
                returnLabel = lbl
                curChecksErrors = proto.checksErrors
                curErrorTypes = if proto.checksErrors: callee.fnErrorTypes else: @[]
                curFnName = callee.fnName
                curFrameKind = fkNormal
                evalBudget = boundScope.evalBudget
                continue
          if namedCount == 0 and argCount == 2 and callee.kind == vkNativeFn:
            let fastNative = tryFastNative2(callee, stack[argsStart], stack[argsStart + 1])
            if fastNative.handled:
              strunc(calleeIndex)
              spush fastNative.value
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
                applyCall(callee, [], named, scope, site,
                          instructionLocAt(chunk, ip - 1))
              else:
                applyCall(callee, stack.toOpenArray(argsStart, (sp - 1)),
                          named, scope, site,
                          instructionLocAt(chunk, ip - 1))
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            strunc(calleeIndex)
            spush NIL
            captureContinuation(ip)   # resume after sleep; nil is already pushed
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          strunc(calleeIndex)
          spush value
        of opCallSplice:
          var named: NamedArgs
          let proto = chunk.listBuilds[inst[].intArg]
          let partCount = proto.splices.len
          let namedCount = inst[].names.len
          let partsStart = sp - partCount
          if partsStart < 0 or partsStart < namedCount + 1:
            raise newException(GeneError, "VM stack underflow in call")
          let calleeIndex = partsStart - namedCount - 1
          var callee = stack[calleeIndex]
          if namedCount > 0:
            named = namedArgsFromStack(inst[].names, stack, calleeIndex + 1)
          var args: seq[Value]
          for i, part in stack.toOpenArray(partsStart, (sp - 1)):
            if proto.splices[i]:
              appendSplicedBody(args, part)
            else:
              args.add part
          # A message identity is not callable in head position (see opCall).
          if callee.kind == vkProtocolMessage:
            rejectMessageCall(callee, scope)
          # Frame-push paths mirror opCall: spread calls to Gene functions go onto the
          # frame stack (^errors included; only generators fall through to applyCall).
          if callee.kind == vkFunction:
            let code = callee.fnCode
            if code != nil and code of FunctionProto:
              let fnProto = FunctionProto(code)
              if fnProto.nativeOp != ncoNone:
                let native = applyNativeCompiled(callee, fnProto, args, named)
                if native.handled:
                  strunc(calleeIndex)
                  spush native.value
                  continue
              if namedCount == 0 and fnProto.simpleCall and
                  args.len == fnProto.params.len:
                let callScope =
                  if fnProto.needsCallScope:
                    let created =
                      if fnProto.poolCallScope:
                        acquireSimpleCallScope(gVmPools, callee.fnScope, fnProto.localNames,
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
                callScope.seedFunctionProtocolEntry(callee)
                strunc(calleeIndex)
                pushFrame()
                chunk = fnProto.chunk
                scope = callScope
                recycleScope = fnProto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = fnProto.frameNeedsImplValidation
                returnType = NIL
                returnLabel = ""
                curChecksErrors = false        # simpleCall never declares ^errors
                curErrorTypes = @[]
                curFnName = ""
                curFrameKind = fkNormal
                evalBudget = callScope.evalBudget
                continue
              elif not fnProto.isGenerator:
                if callee.isSyntaxFn:
                  rejectSyntaxCallWithoutSite(callee)
                var boundScope: Scope
                var boundReturnType: Value
                if namedCount == 0 and fnProto.canFastBindPositionalInt and
                    args.len == fnProto.params.len:
                  boundScope = bindPositionalIntCallScope(callee, fnProto,
                                                          args)
                  boundReturnType = fnProto.returnType
                else:
                  let bound = bindCallScope(callee, fnProto, args, named)
                  boundScope = bound.scope
                  boundReturnType = bound.returnType
                let frameReturnType = fnProto.checkedFrameReturnType(boundReturnType)
                strunc(calleeIndex)
                var lbl = ""
                if frameReturnType.kind != vkNil:
                  lbl = "return from '" & callee.fnName & "'"
                pushFrame()
                chunk = fnProto.chunk
                scope = boundScope
                recycleScope = fnProto.poolCallScope
                curStackBase = sp
                ip = 0
                validateImplRequirements = fnProto.frameNeedsImplValidation
                returnType = frameReturnType
                returnLabel = lbl
                curChecksErrors = fnProto.checksErrors
                curErrorTypes = if fnProto.checksErrors: callee.fnErrorTypes else: @[]
                curFnName = if fnProto.checksErrors: callee.fnName else: ""
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
              if args.len == 0:
                applyCall(callee, [], named, scope, site,
                          instructionLocAt(chunk, ip - 1))
              else:
                applyCall(callee, args, named, scope, site,
                          instructionLocAt(chunk, ip - 1))
          except SuspendError as se:
            if not se.timer:
              raise
            if fiber == nil:
              raise newException(GeneError, "internal: suspended outside a fiber")
            strunc(calleeIndex)
            spush NIL
            captureContinuation(ip)
            fiber.waitTimer = true
            fiber.waitDeadline = se.deadline
            return RunStop(kind: rskSuspend, value: NIL)
          strunc(calleeIndex)
          spush value
        of opIntAdd2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int add")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            var value: Value
            if smallIntAddKnown(a, b, value):
              stack[top - 2] = value
              sp = (top - 1)
              continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = intAdd(a, b)
            strunc(top - 1)
            continue
          strunc(top - 2)
          let callee = scope.loadNativeFast(nfkAdd, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntSub2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int sub")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            var value: Value
            if smallIntSubKnown(a, b, value):
              stack[top - 2] = value
              sp = (top - 1)
              continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = intSub(a, b)
            strunc(top - 1)
            continue
          strunc(top - 2)
          let callee = scope.loadNativeFast(nfkSub, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntMul2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int mul")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = intMul(a, b)
            strunc(top - 1)
            continue
          strunc(top - 2)
          let callee = scope.loadNativeFast(nfkMul, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntLt2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int lt")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal < b.smallIntVal)
            sp = (top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) < 0)
            strunc(top - 1)
            continue
          strunc(top - 2)
          let callee = scope.loadNativeFast(nfkLt, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntGt2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int gt")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal > b.smallIntVal)
            sp = (top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) > 0)
            strunc(top - 1)
            continue
          strunc(top - 2)
          let callee = scope.loadNativeFast(nfkGt, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntLe2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int le")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal <= b.smallIntVal)
            sp = (top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) <= 0)
            strunc(top - 1)
            continue
          strunc(top - 2)
          let callee = scope.loadNativeFast(nfkLe, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntGe2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int ge")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          if a.isSmallInt and b.isSmallInt:
            stack[top - 2] = newBool(a.smallIntVal >= b.smallIntVal)
            sp = (top - 1)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 2] = newBool(intCompare(a, b) >= 0)
            strunc(top - 1)
            continue
          strunc(top - 2)
          let callee = scope.loadNativeFast(nfkGe, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntAddConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int add const")
          let top = sp
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
          strunc(top - 1)
          let callee = scope.loadNativeFast(nfkAdd, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntSubConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int sub const")
          let top = sp
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
          strunc(top - 1)
          let callee = scope.loadNativeFast(nfkSub, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntMulConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int mul const")
          let top = sp
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = intMul(a, b)
            continue
          strunc(top - 1)
          let callee = scope.loadNativeFast(nfkMul, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntLtConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int lt const")
          let top = sp
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal < b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) < 0)
            continue
          strunc(top - 1)
          let callee = scope.loadNativeFast(nfkLt, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntGtConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int gt const")
          let top = sp
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal > b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) > 0)
            continue
          strunc(top - 1)
          let callee = scope.loadNativeFast(nfkGt, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntLeConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int le const")
          let top = sp
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal <= b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) <= 0)
            continue
          strunc(top - 1)
          let callee = scope.loadNativeFast(nfkLe, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntGeConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int ge const")
          let top = sp
          let a = stack[top - 1]
          let b = chunk.constants[inst[].depth]
          if a.isSmallInt and (inst[].flag or b.isSmallInt):
            stack[top - 1] = newBool(a.smallIntVal >= b.smallIntVal)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            stack[top - 1] = newBool(intCompare(a, b) >= 0)
            continue
          strunc(top - 1)
          let callee = scope.loadNativeFast(nfkGe, inst[].name)
          var args = [a, b]
          spush applyCall(callee, args, NamedArgs(), scope)
        of opIntFast2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int fast call")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          let kind = NativeFastKind(inst[].intArg)
          if a.isSmallInt and b.isSmallInt:
            case kind
            of nfkAdd:
              var value: Value
              if smallIntAddKnown(a, b, value):
                stack[top - 2] = value
                sp = (top - 1)
                continue
            of nfkSub:
              var value: Value
              if smallIntSubKnown(a, b, value):
                stack[top - 2] = value
                sp = (top - 1)
                continue
            of nfkLt:
              stack[top - 2] = newBool(a.smallIntVal < b.smallIntVal)
              sp = (top - 1)
              continue
            of nfkGt:
              stack[top - 2] = newBool(a.smallIntVal > b.smallIntVal)
              sp = (top - 1)
              continue
            of nfkLe:
              stack[top - 2] = newBool(a.smallIntVal <= b.smallIntVal)
              sp = (top - 1)
              continue
            of nfkGe:
              stack[top - 2] = newBool(a.smallIntVal >= b.smallIntVal)
              sp = (top - 1)
              continue
            else:
              discard
          if a.kind != vkInt or b.kind != vkInt:
            strunc(top - 2)
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            spush applyCall(callee, args, NamedArgs(), scope)
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
          strunc(top - 1)
        of opIntFastConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in int fast const call")
          let top = sp
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
            strunc(top - 1)
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            spush applyCall(callee, args, NamedArgs(), scope)
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
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in native fast call")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          let kind = NativeFastKind(inst[].intArg)
          if a.isSmallInt and b.isSmallInt:
            case kind
            of nfkAdd:
              var value: Value
              if smallIntAddKnown(a, b, value):
                stack[top - 2] = value
                sp = (top - 1)
                continue
            of nfkSub:
              var value: Value
              if smallIntSubKnown(a, b, value):
                stack[top - 2] = value
                sp = (top - 1)
                continue
            of nfkLt:
              stack[top - 2] = newBool(a.smallIntVal < b.smallIntVal)
              sp = (top - 1)
              continue
            of nfkGt:
              stack[top - 2] = newBool(a.smallIntVal > b.smallIntVal)
              sp = (top - 1)
              continue
            of nfkLe:
              stack[top - 2] = newBool(a.smallIntVal <= b.smallIntVal)
              sp = (top - 1)
              continue
            of nfkGe:
              stack[top - 2] = newBool(a.smallIntVal >= b.smallIntVal)
              sp = (top - 1)
              continue
            else:
              discard
          strunc(top - 2)
          let fastNative = tryFastNativeKind2(kind, a, b)
          if fastNative.handled:
            spush fastNative.value
          else:
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            spush applyCall(callee, args, NamedArgs(), scope)
        of opNativeFastConst:
          if sp < 1:
            raise newException(GeneError, "VM stack underflow in native fast const call")
          let top = sp
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
          strunc(top - 1)
          if a.kind == vkInt and b.kind == vkInt:
            case kind
            of nfkAdd:
              spush intAdd(a, b)
              continue
            of nfkSub:
              spush intSub(a, b)
              continue
            of nfkMul:
              spush intMul(a, b)
              continue
            of nfkLt:
              spush newBool(intCompare(a, b) < 0)
              continue
            of nfkGt:
              spush newBool(intCompare(a, b) > 0)
              continue
            of nfkLe:
              spush newBool(intCompare(a, b) <= 0)
              continue
            of nfkGe:
              spush newBool(intCompare(a, b) >= 0)
              continue
            else:
              discard
          let fastNative = tryFastNativeKind2(kind, a, b)
          if fastNative.handled:
            spush fastNative.value
          else:
            let callee = scope.loadNativeFast(kind, inst[].name)
            var args = [a, b]
            spush applyCall(callee, args, NamedArgs(), scope)
        of opMatch:
          let target = spop()
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
          let target = spop()
          var binds = initTable[string, Value]()
          if not tryMatch(chunk.constants[inst[].intArg], target, scope, binds):
            raiseMatchError(scope, "destructuring pattern did not match")
          scope.bindMatchedValues(binds, replaceExisting = false)
          spush target
        of opMatchBindReplace:
          let target = spop()
          var binds = initTable[string, Value]()
          if not tryMatch(chunk.constants[inst[].intArg], target, scope, binds):
            raiseMatchError(scope, "destructuring pattern did not match")
          scope.bindMatchedValues(binds, replaceExisting = true)
          spush target
        of opForEach:
          var coll = spop()
          let fp = chunk.forLoops[inst[].intArg]
          if coll.kind == vkRange:
            coll = rangeStream(coll)
          if coll.kind == vkStream:
            var item = NIL
            try:
              if not coll.streamHasNext:
                coll.closeStream()
                spush NIL
                continue
              item = checkedStreamNext(coll, "for item")
            except GeneError:
              coll.closeStream()
              raise
            let loopScope = newScope(scope)
            loopScope.prepareChunkScope(fp.body)
            var binds = initTable[string, Value]()
            if not tryMatch(fp.pattern, item, loopScope, binds):
              coll.closeStream()
              raiseMatchError(loopScope, "for pattern did not match an item")
            loopScope.bindMatchedValues(binds, replaceExisting = false)
            pushFrame()
            enterFrame(fp.body, loopScope, true, fkForBody)
            curForStream = coll
            curForPattern = fp.pattern
            curForBody = fp.body
            continue
          let items = forItems(coll)
          if items.len == 0:
            spush NIL
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
          spush iteratorStream(spop())
        of opIteratorHasNext:
          let stream = spop()
          requireStream("for iterator", stream)
          spush newBool(stream.streamHasNext)
        of opIteratorNext:
          let stream = spop()
          requireStream("for iterator", stream)
          if not stream.streamHasNext:
            raiseEndOfStream()
          spush checkedStreamNext(stream, "for item")
        of opIteratorClose:
          let stream = spop()
          requireStream("for iterator", stream)
          stream.closeStream()
        of opLoopBreak:
          if curFrameKind != fkForBody:
            raise newException(GeneError, "break is only valid inside a loop")
          strunc(curStackBase)
          breakForLoop()
          continue
        of opLoopContinue:
          if curFrameKind != fkForBody:
            raise newException(GeneError, "continue is only valid inside a loop")
          strunc(curStackBase)
          advanceForLoop()
          continue
        of opTry:
          # Run the try body as a Frame on the heap stack (not a nested runLoop), so
          # deep recursion through try-wrapped code does not grow the Nim stack. The
          # catch clauses and ensure block run on the error/exit path — on normal
          # completion via frameReturn, on a thrown error via the dispatch loop's
          # exception handler below — both keyed off the TryHandler pushed here.
          let tp = chunk.tries[inst[].intArg]
          pushFrame()
          # pushFrame moves the scope register into the frame; the try body
          # shares the enclosing scope, so re-borrow it from there.
          scope = frames[^1].scope
          handlers.add TryHandler(tp: tp, scope: scope, framesLen: frames.len)
          chunk = tp.body                 # shares the enclosing scope
          curStackBase = sp
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
          # Hoisted: pushFrame moves the chunk register into the frame.
          let taskBody = chunk.subchunks[inst[].intArg]
          pushFrame()
          enterFrame(taskBody, taskScope,
                     validateImplRequirements, fkTaskScopeBody)
          curOwnedScope = taskScope
          continue
        of opSupervisor:
          var hasEvents = false
          var hasDeadLetters = false
          var hasMaxRestarts = false
          var hasWithinMs = false
          for optionName in inst[].names:
            case optionName
            of "events": hasEvents = true
            of "dead_letter": hasDeadLetters = true
            of "max_restarts": hasMaxRestarts = true
            of "within_ms": hasWithinMs = true
            else: discard
          # Options were compiled events → dead_letter → max_restarts →
          # within_ms; pop in reverse.
          let withinMs =
            if hasWithinMs:
              int(requireInt64("supervisor ^within_ms", spop()))
            else:
              0
          let maxRestarts =
            if hasMaxRestarts:
              int(requireInt64("supervisor ^max_restarts", spop()))
            else:
              0
          let deadLetterSink =
            if hasDeadLetters:
              let sink = spop()
              requireChannel("supervisor ^dead_letter", sink)
              sink
            else:
              NIL
          let eventSink =
            if hasEvents:
              let sink = spop()
              requireChannel("supervisor ^events", sink)
              sink
            else:
              NIL
          let supervisorScope = newScope(scope)
          supervisorScope.ownsActors = true
          supervisorScope.actorFailureStrategy = supervisorStrategy(inst[].name)
          supervisorScope.supervisorEvents = eventSink
          supervisorScope.supervisorDeadLetters = deadLetterSink
          supervisorScope.actorMaxRestarts = maxRestarts
          supervisorScope.actorRestartWindowMs = withinMs
          # Hoisted: pushFrame moves the chunk register into the frame.
          let supervisorBody = chunk.subchunks[inst[].intArg]
          pushFrame()
          enterFrame(supervisorBody, supervisorScope,
                     validateImplRequirements, fkSupervisorBody)
          curOwnedScope = supervisorScope
          continue
        of opSpawn:
          # Spawn a child task as a scheduler fiber. The body is queued instead of
          # running inline, so CPU-only child work still cooperates through VM
          # safepoints. Worker-safe tasks receive a sparse captured-scope
          # snapshot; atomicArc threaded builds may hand those leaf-like tasks
          # to the opt-in worker lane.
          if scope.borrowedCallerEnv:
            raise newException(GeneError,
              "spawn cannot capture borrowed CallerEnv authority")
          if activeConstructionDepth > 0 and scope.scopeCarriesConstruction:
            raise newException(GeneError,
              "spawn cannot capture an in-progress constructed instance")
          let body = chunk.subchunks[inst[].intArg]
          let workerSafe = inst[].flag and scope.spawnCanMoveToWorker(body)
          publishSpawnCapture(scope, body)
          let taskParent =
            if workerSafe: snapshotSpawnScope(scope, body)
            else: scope
          if workerSafe:
            # Snapshotting can allocate replacement functions/containers for
            # captured scope chains. Publish the snapshot graph too so worker
            # threads see atomic manual-RC objects, not just the original graph.
            publishSpawnCapture(taskParent, body)
          let taskScope = newScope(taskParent)
          let task = spawnFiber(body, taskScope, workerSafe)
          scope.registerOwnedTask(task)
          spush task
        of opAwait:
          # Await a task. Inside a scheduled fiber, park on the task (the scheduler
          # runs others and wakes us when it settles) and re-execute opAwait on
          # resume — the task is still on the stack. At the root, drive the queue.
          let task = stack[sp - 1]
          if task.kind == vkTask and not task.taskDone:
            if currentFiberActive and fiber != nil:
              captureContinuation(ip - 1)   # task stays on the stack for re-execution
              fiber.waitTask = task
              fiber.waitChannel = NIL
              fiber.waitActor = NIL
              fiber.waitTimer = false
              return RunStop(kind: rskSuspend, value: NIL)
            elif currentFiberActive:
              # Nested native trampoline (native callback re-entered the VM)
              # inside a fiber: there is no continuation to park. An external
              # task must be waited for directly — blocking, but correct. Some
              # external operations (notably os/exec-*-async) publish a native
              # result that this scheduler thread materializes, so keep polling
              # instead of waiting indefinitely for a worker-side settlement.
              # A scheduler-owned task would need this thread to progress;
              # suspend is impossible, so fail cleanly.
              when compileOption("threads"):
                if task.taskExternalPending:
                  while not task.taskDone:
                    pollOsExecAsyncCompletions()
                    if not task.taskDone:
                      os.sleep(1)
                else:
                  raise newException(GeneError,
                    "await cannot suspend inside a native callback; " &
                    "move the await out of the callback")
              else:
                raise newException(GeneError,
                  "await cannot suspend inside a native callback; " &
                  "move the await out of the callback")
            else:
              pumpUntilDone(task)
          discard spop()
          spush awaitTaskValue(task)
        of opFail:
          let errVal = spop()
          rejectCallerEnvEscape("fail payload", errVal)
          if not scope.isErrorValue(errVal):
            raise newException(GeneError, "fail expects an Error value")
          raiseFailedValue(errVal)
        of opPanic:
          let panicVal = spop()
          rejectCallerEnvEscape("panic payload", panicVal)
          raisePanicValue(panicVal)
        of opYield:
          if not stopOnYield:
            raise newException(GeneError, "yield is only valid in a generator")
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in yield")
          # A generator suspends in its own (outermost) frame; simpleCall callees
          # never yield, so `frames` is empty here and stack/ip persist via the args.
          let yielded = escapeWeakFunctions(stack[sp - 1])
          if fiber != nil:
            captureContinuation(ip)
          else:
            setStackLenRaw(stack, sp)   # normalize: live region only escapes runLoop
            stackArg = move stack
            ipArg = ip
            releaseFrameStack(gVmPools, frames)
          return RunStop(kind: rskYield, value: yielded)
        of opExplicitReturn:
          let returnValue = if sp > 0: spop() else: VOID
          if curFrameKind == fkNormal and frames.len == returnDepth:
            frameReturn(returnValue)
          else:
            var signal: ref GeneReturn
            new(signal)
            signal.value = escapeWeakFunctions(returnValue)
            signal.targetDepth = returnDepth
            raise signal
        of opJumpIfFalse:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in conditional jump")
          let top = sp - 1
          let cond = stack[top]
          strunc(top)
          if not cond.isTruthy:
            ip = inst[].intArg
        of opJumpIfFalseOrPop:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in conditional jump")
          if stack[sp - 1].isTruthy:
            strunc(sp - 1)
          else:
            ip = inst[].intArg
        of opJumpIfTrueOrPop:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in conditional jump")
          if stack[sp - 1].isTruthy:
            ip = inst[].intArg
          else:
            strunc(sp - 1)
        of opJumpIfPresentOrPop:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in conditional jump")
          if not stack[sp - 1].isAbsent:
            ip = inst[].intArg
          else:
            strunc(sp - 1)
        of opNot:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in not")
          let top = sp - 1
          stack[top] = if stack[top].isTruthy: FALSE else: TRUE
        of opJump:
          ip = inst[].intArg
        of opSyntaxCall:
          # Stack: [.. callee, raw call node] (design §3 step 4).
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in syntax call")
          let callNode = spop()
          let callee = spop()
          spush applySyntaxCall(callee, callNode, scope)
        of opSyntaxGuard:
          # Generic evaluated-head call site (design §3): if the callee on top
          # is a fn!, perform the syntax call from the const raw node and jump
          # past the ordinary argument-evaluation + call sequence.
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in syntax guard")
          if stack[sp - 1].isSyntaxFn:
            let callee = spop()
            spush applySyntaxCall(callee, chunk.constants[inst[].depth],
                                      scope)
            ip = inst[].intArg
        of opRejectSyntaxSend:
          if sp == 0:
            raise newException(GeneError,
              "VM stack underflow checking message callable")
          if stack[sp - 1].isSyntaxFn:
            rejectSyntaxSend(stack[sp - 1], scope)
        of opResolveQualifiedMessage:
          # Qualified/dynamic send — (x ~ P/m), (x ~ %m), (x ~ (expr)). The
          # callee must be a message value; `~` dispatches only and never
          # invokes an arbitrary function or a held fn! (design §3/§8). The impl
          # is resolved here rather than by lowering the send to a flipped call,
          # so an ordinary call never legitimately receives a message value.
          if sp < 2:
            raise newException(GeneError,
              "VM stack underflow resolving qualified message")
          let message = spop()
          let receiver = spop()
          if message.kind != vkProtocolMessage:
            if message.isSyntaxFn:
              rejectSyntaxSend(message, scope)
            raiseCallKindError("message send", "Message",
                               freezeRejectName(message), message, scope)
          var callee = NIL
          when dispatchCacheEnabled:
            # A message value is first-class, so one site can see several; its
            # identity joins the guard (msgBits), as in the opCall path.
            let recvType = receiver.receiverType
            if recvType.kind == vkType and not scope.chainHasTransientImpls():
              let site = ip - 1
              let epoch = scope.application().implEpoch
              let msgBits = message.bits
              callee = chunk.dispatchCacheLookup(site, recvType, msgBits, epoch)
              if callee.kind == vkNil:
                callee = resolveProtocolMessage(scope, message, receiver)
                chunk.dispatchCacheFill(site, recvType, msgBits, epoch, callee)
          if callee.kind == vkNil:
            callee = resolveProtocolMessage(scope, message, receiver)
          if callee.isSyntaxFn:
            rejectSyntaxSend(callee, scope)
          spush callee
          spush receiver
        of opReturn:
          frameReturn(if sp > 0: spop() else: NIL)
        of opReturnBareInt:
          frameReturnBareInt(if sp > 0: spop() else: NIL)
        of opReturnIntAdd2:
          if sp < 2:
            raise newException(GeneError, "VM stack underflow in int add return")
          let top = sp
          let b = stack[top - 1]
          let a = stack[top - 2]
          strunc(top - 2)
          var value: Value
          if a.isSmallInt and b.isSmallInt and smallIntAddKnown(a, b, value):
            frameReturnBareInt(value)
            continue
          if a.kind == vkInt and b.kind == vkInt:
            frameReturnBareInt(intAdd(a, b))
            continue
          let callee = scope.loadNativeFast(nfkAdd, inst[].name)
          var args = [a, b]
          frameReturnBareInt(applyCall(callee, args, NamedArgs(), scope))
        of opCheckType:
          if sp == 0:
            raise newException(GeneError, "VM stack underflow in type check")
          stack[sp - 1] = adaptBoundary(inst[].name, chunk.constants[inst[].intArg],
                                    stack[sp - 1], scope)
        of opDeclareType:
          scope.declareType(inst[].name, chunk.constants[inst[].intArg])
        # All exits are via frameReturn / opYield above; the loop never falls through.
    except GeneError as e:
      # A recoverable error is unwinding the frame stack. Walk outward from the
      # current frame: give each enclosing `try` (a TryHandler, keyed by frame
      # depth) a chance to catch, run ensure blocks, and translate ^errors
      # boundaries on the function frames crossed. A catch that fires resumes the
      # outer dispatch loop with its result; otherwise the error propagates out.
      let errorLoc = instructionLocBefore(chunk, ip)
      let preservingFirstCleanupError =
        curFrameKind == fkEnsureErrorBody and curPendingError != nil
      var err =
        if preservingFirstCleanupError:
          curPendingError
        else:
          translateErrorBoundary(curChecksErrors, curErrorTypes, curFnName, e)
      if not preservingFirstCleanupError:
        annotateTopLevelUndefined(err, chunk, errorLoc)
        attachSourceLoc(err, errorLoc)
        appendVmTrace(err, curFnName, errorLoc, frames, tailTraceFrames)
      trimTailTraceFrames(frames.len)
      if curFrameKind == fkForBody and
          not (handlers.len > 0 and handlers[^1].framesLen == frames.len):
        closeCurrentForStream()
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
        strunc(curStackBase)
        enterFrame(body, cleanupScope, false, fkEnsureErrorBody)
        curPendingError = err
        continue
      while true:
        if handlers.len > 0 and handlers[^1].framesLen == frames.len:
          # Unwound back to this try's level. The owner frame remains on `frames`
          # while catch/ensure bodies run as ordinary VM frames, so they can park
          # and resume like the original try body.
          let h = handlers.pop()
          strunc(curStackBase)        # discard the try body's operand stack
          let ownerValidate = frames[^1].validateImpls
          let errVal =
            if err.hasErrVal: err.errVal
            else:
              var props = initPropTable()
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
            strunc(curStackBase)
            loadFrameRegs(f)
            closeCurrentForStream()
            err = translateErrorBoundary(curChecksErrors, curErrorTypes, curFnName, err)
            releaseCurrentCallScope()
        elif frames.len == 0:
          releaseFrameStack(gVmPools, frames)
          raise err
        else:
          strunc(curStackBase)    # drop the failing frame's region
          var f = frames.pop()
          loadFrameRegs(f)
          closeCurrentForStream()
          err = translateErrorBoundary(curChecksErrors, curErrorTypes, curFnName, err)
          releaseCurrentCallScope()
      # Reached only via `break` (a catch fired): fall through to the outer
      # `while true`, re-entering dispatch with the catch result on the stack.
    except GenePanic as p:
      # Panics are not catchable, but ensure blocks still run as the panic unwinds
      # out of every active `try` (innermost first), matching the old `finally`.
      if curFrameKind == fkForBody and
          not (handlers.len > 0 and handlers[^1].framesLen == frames.len):
        closeCurrentForStream()
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
        strunc(curStackBase)
        enterFrame(body, cleanupScope, false, fkEnsurePanicBody)
        curPendingPanic = p
        continue
      var cleanupStarted = false
      while handlers.len > 0:
        let h = handlers.pop()
        if h.tp.ensureBody != nil:
          strunc(curStackBase)
          enterFrame(h.tp.ensureBody, h.scope, false, fkEnsurePanicBody)
          curPendingPanic = p
          cleanupStarted = true
          break
      if cleanupStarted:
        continue
      for f in frames:
        releaseFrameCallScope(f)
      releaseFrameStack(gVmPools, frames)
      raise p
    except GeneCancel as c:
      # Cancellation is separate from recoverable Gene errors: catch clauses do
      # not see it, but cleanup still runs as the task unwinds.
      if curFrameKind == fkForBody and
          not (handlers.len > 0 and handlers[^1].framesLen == frames.len):
        closeCurrentForStream()
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
        strunc(curStackBase)
        enterFrame(body, cleanupScope, false, fkEnsureCancelBody)
        curPendingCancel = c
        continue
      var cleanupStarted = false
      while handlers.len > 0:
        let h = handlers.pop()
        if h.tp.ensureBody != nil:
          strunc(curStackBase)
          enterFrame(h.tp.ensureBody, h.scope, false, fkEnsureCancelBody)
          curPendingCancel = c
          cleanupStarted = true
          break
      if cleanupStarted:
        continue
      for f in frames:
        releaseFrameCallScope(f)
      releaseFrameStack(gVmPools, frames)
      if fiber != nil:
        return RunStop(kind: rskCancel, value: NIL)
      raise c
    except GeneReturn as r:
      # Explicit return is a structured exit: skip catches, but unwind every
      # active ensure and close loop-owned streams before leaving the nearest
      # function frame.
      if curFrameKind == fkForBody and
          not (handlers.len > 0 and handlers[^1].framesLen == frames.len):
        closeCurrentForStream()
      releaseCurrentCallScope()
      if curFrameKind == fkTaskScopeBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        try:
          owned.waitOwnedTasks()
        finally:
          owned.closeOwnedActors()
      elif curFrameKind == fkSupervisorBody:
        let owned = curOwnedScope
        curFrameKind = fkNormal
        owned.closeOwnedActors()
      if curFrameKind == fkCatchBody and curEnsureBody != nil:
        let body = curEnsureBody
        let cleanupScope = curEnsureScope
        strunc(curStackBase)
        enterFrame(body, cleanupScope, false, fkEnsureReturnBody)
        curPendingReturn = r
        continue
      var cleanupStarted = false
      while true:
        if handlers.len > 0 and handlers[^1].framesLen == frames.len:
          let h = handlers.pop()
          strunc(curStackBase)
          if h.tp.ensureBody != nil:
            enterFrame(h.tp.ensureBody, h.scope, false, fkEnsureReturnBody)
            curPendingReturn = r
            cleanupStarted = true
            break
          var owner = frames.pop()
          loadFrameRegs(owner)
          closeCurrentForStream()
          releaseCurrentCallScope()
        elif frames.len == r.targetDepth:
          frameReturn(r.value)
          cleanupStarted = true
          break
        elif frames.len == 0:
          releaseFrameStack(gVmPools, frames)
          return RunStop(kind: rskReturn, value: r.value)
        else:
          strunc(curStackBase)
          var owner = frames.pop()
          loadFrameRegs(owner)
          closeCurrentForStream()
          releaseCurrentCallScope()
      if cleanupStarted:
        continue
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
    scope.refreshCompiledUnitEntry()
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

proc runReplSession*(scope: Scope,
                     readLine: ReplReadLine,
                     writeOut: ReplWrite,
                     writeErr: ReplWrite,
                     options = defaultReplOptions()): int =
  ## Run a REPL against an existing scope. Returns 0 for a normal exit and 1
  ## when a panic aborts the session. Recoverable Gene/read errors are printed
  ## and the session continues.
  var line: string
  var pendingSource = ""
  var pendingError = ""
  let continuationPrompt = "....> "

  # Interactive sessions handle SIGINT themselves: while reading, the tty's
  # ISIG flush already discarded the partial line and the handler redraws the
  # prompt; while evaluating, the handler arms the VM interrupt flag so the
  # dispatch loop raises a catchable "interrupted" error. SA_RESTART keeps the
  # blocking readLine transparent to the signal.
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var oldSigint: Sigaction
    var sigintInstalled = false
    var installedBudget = false
    if options.interactive:
      gReplPromptLen = min(options.prompt.len, gReplPromptBuf.len)
      for i in 0 ..< gReplPromptLen:
        gReplPromptBuf[i] = options.prompt[i]
      var act: Sigaction
      act.sa_handler = replSigintHandler
      discard sigemptyset(act.sa_mask)
      act.sa_flags = SA_RESTART
      sigintInstalled = sigaction(SIGINT, act, oldSigint) == 0
      if sigintInstalled and scope.evalBudget == nil:
        # The interrupt flag is polled on the budgeted-dispatch path only, so
        # give the session an effectively unlimited budget to activate it.
        scope.evalBudget = EvalBudget(remaining: high(int64))
        installedBudget = true

  template readOneLine(dest: var string): bool =
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      if sigintInstalled:
        volatileStore(addr gReplSigPhase, replPhaseReading)
      let ok = readLine(dest)
      if sigintInstalled:
        volatileStore(addr gReplSigPhase, replPhaseEvaluating)
      ok
    else:
      readLine(dest)

  try:
    if options.interactive:
      writeOut(options.prompt)
    while readOneLine(line):
      let trimmed = line.strip()
      if pendingSource.len == 0 and trimmed.len == 0:
        if options.interactive:
          writeOut(options.prompt)
        continue
      if pendingSource.len == 0 and trimmed in [":quit", ":exit", "quit", "exit"]:
        return 0
      let source =
        if pendingSource.len == 0: line
        else: pendingSource & "\n" & line
      try:
        when defined(posix) and not defined(emscripten) and not defined(geneWasm):
          # Drop any interrupt that landed after the previous eval finished so
          # it cannot spuriously abort this line.
          volatileStore(addr gVmInterrupt, false)
        writeOut(run(compileEvalSource(source, useLocalSlots = false,
                                       sourceName = "<repl>"), scope).print() & "\n")
        pendingSource = ""
        pendingError = ""
      except ReadIncompleteError as e:
        pendingSource = source
        pendingError = e.msg
        if options.interactive:
          writeOut(continuationPrompt)
        continue
      except ReadError as e:
        pendingSource = ""
        pendingError = ""
        writeErr(formatDiagnostic("Read error", e.msg,
          SourceLoc(sourceName: e.sourceName, line: e.line, col: e.col)) & "\n")
      except GenePanic as e:
        writeErr("Panic: " & e.msg & "\n")
        return 1
      except GeneError as e:
        pendingSource = ""
        pendingError = ""
        writeErr(formatDiagnostic("Error", e.msg, e.loc) & "\n")
      if options.interactive:
        writeOut(options.prompt)
    if options.interactive:
      writeOut("\n")
    if pendingSource.len > 0:
      let msg = if pendingError.len == 0: "unexpected end of input" else: pendingError
      writeErr("Read error: " & msg & "\n")
    0
  finally:
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      if installedBudget:
        scope.evalBudget = nil
      if sigintInstalled:
        discard sigaction(SIGINT, oldSigint, nil)
        volatileStore(addr gReplSigPhase, replPhaseIdle)
        volatileStore(addr gVmInterrupt, false)

proc runReplSessionForEnv*(env: Value,
                           readLine: ReplReadLine,
                           writeOut: ReplWrite,
                           writeErr: ReplWrite,
                           options: ReplOptions): int =
  if env.kind != vkEnv:
    raise newException(GeneError, "repl/run expects an Env")
  let scope = newScope(materializeEvalParent(env))
  scope.implOverlayRoot = true
  scope.evalBudget = evalBudgetForPolicy(env.envPolicy, nil)
  runReplSession(scope, readLine, writeOut, writeErr, options)

proc runPooled(chunk: Chunk, scope: Scope,
               validateImplRequirements = true): Value =
  withScheduler(scope):
    if chunk.localNames.len == 0:
      return run(chunk, scope, validateImplRequirements)
    let workerLease = beginSchedulerWorkerLease()
    defer:
      endSchedulerWorkerLease(workerLease)
    scope.refreshCompiledUnitEntry()
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
# and atomicArc threaded builds add workers for snapshot-isolated fibers.
# ---------------------------------------------------------------------------

proc enqueueRunnable(f: Fiber) =
  let s = currentScheduler()
  withSchedulerLock(s):
    s.enqueueRunnableUnlocked(f)

proc shouldResumeInsteadOfPark(f: Fiber): bool =
  if f.task.kind == vkTask and f.task.taskCancelRequested and
      not f.task.taskDone and not f.inCancelCleanup():
    return true
  if f.waitTask.kind == vkTask and f.waitTask.taskDone:
    return true
  if f.waitChannel.kind == vkChannel:
    if f.waitChannel.channelClosed:
      return true
    if f.waitIsSend:
      return not f.waitChannel.channelFull
    return f.waitChannel.channelLen > 0
  if f.waitActor.kind == vkActorRef:
    return f.waitActor.actorClosed or not f.waitActor.actorFull
  if f.waitTimer:
    return f.waitDeadline <= getMonoTime()

proc parkFiber(f: Fiber) =
  let s = currentScheduler()
  withSchedulerLock(s):
    if f.shouldResumeInsteadOfPark():
      s.enqueueRunnableUnlocked(f)
    else:
      s.waiters.add f
      when compileOption("threads") and defined(gcAtomicArc):
        if f.waitTimer and f.workerCandidate:
          broadcast(s.workerCond)

proc hasRunnableFiber(): bool =
  let s = currentScheduler()
  withSchedulerLock(s):
    result = s.runQueue.len > 0

proc popRunnableFiber(workerOnly = false, skipWorkerSafe = false,
                      activeWorkerSlot = -1): Fiber =
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
      # Fibers woken by a foreign thread (wake*In move path) still carry their
      # wait reason: release those Values here, on the claiming thread.
      clearWaitReason(f)
      when compileOption("threads") and defined(gcAtomicArc):
        # Root deadlock detection and cancellation scans both need to see a
        # claimed fiber before it leaves the scheduler lock.
        if activeWorkerSlot >= 0 and activeWorkerSlot < s.activeWorkerFibers.len:
          s.activeWorkerFibers[activeWorkerSlot] = f
      return

proc scheduleAskTimeout(task, reply: Value, scope: Scope, timeoutMs: int64) =
  let s = currentScheduler()
  withSchedulerLock(s):
    s.askTimeouts.add AskTimeout(task: task, reply: reply, scope: scope,
                                 deadline: timerDeadline(timeoutMs))
    when compileOption("threads") and defined(gcAtomicArc):
      broadcast(s.workerCond)

proc failExpiredAskTimeouts(now: MonoTime): bool =
  let s = currentScheduler()
  var wakeTasks: seq[Value]
  withSchedulerLock(s):
    var i = 0
    while i < s.askTimeouts.len:
      let item = s.askTimeouts[i]
      if item.task.kind != vkTask or item.task.taskDone:
        s.askTimeouts.delete(i)
      elif item.deadline <= now:
        s.askTimeouts.delete(i)
        if item.task.kind == vkTask and not item.task.taskDone:
          const message = "actor/ask timed out"
          failTask(item.task, message, actorErrorValue(item.scope, message),
                   hasValue = true)
          wakeTasks.add item.task
        result = true
      else:
        inc i
  for task in wakeTasks:
    wakeTaskWaiters(task)

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

proc wakeChannelWaitersIn(s: SchedulerState, channel: Value,
                          wakeSenders: bool) =
  ## Move one fiber parked on `channel` — a receiver, or a sender when
  ## `wakeSenders` — from the wait list onto the run queue (FIFO over waiters).
  ## Runs on foreign threads (exec workers), so the transfer is rc-free: the
  ## fiber is inspected through a cursor and MOVED between the seqs — a copy
  ## would inc/dec its non-atomic refcount off-thread, racing the scheduler.
  ## Wait reasons are cleared at the dequeue site instead of here (clearing
  ## releases the wait-field Values, which must happen on the scheduler).
  withSchedulerLock(s):
    for i in 0 ..< s.waiters.len:
      let f {.cursor.} = s.waiters[i]
      if f.waitIsSend == wakeSenders and same(f.waitChannel, channel):
        when compileOption("threads") and defined(gcAtomicArc):
          if f.workerCandidate:
            broadcast(s.workerCond)
        s.runQueue.add(move s.waiters[i])
        s.waiters.delete(i)
        return

proc wakeChannelWaiters(channel: Value, wakeSenders: bool) =
  wakeChannelWaitersIn(currentScheduler(), channel, wakeSenders)

proc wakeAllChannelWaitersIn(s: SchedulerState, channel: Value,
                             wakeSenders: bool) =
  ## Channel close changes the state observed by every parked counterpart:
  ## receivers on an empty channel and senders on a full one must all resume and
  ## re-run their operation so they can raise ChannelClosed. Foreign-thread
  ## safe: rc-free move transfer, same discipline as wakeChannelWaitersIn.
  withSchedulerLock(s):
    var i = 0
    while i < s.waiters.len:
      let f {.cursor.} = s.waiters[i]
      if f.waitIsSend == wakeSenders and same(f.waitChannel, channel):
        when compileOption("threads") and defined(gcAtomicArc):
          if f.workerCandidate:
            broadcast(s.workerCond)
        s.runQueue.add(move s.waiters[i])
        s.waiters.delete(i)
      else:
        inc i

proc wakeAllChannelWaiters(channel: Value, wakeSenders: bool) =
  wakeAllChannelWaitersIn(currentScheduler(), channel, wakeSenders)

proc wakeTaskWaitersIn(s: SchedulerState, task: Value) =
  ## Move every fiber parked in `await` on `task` onto the run queue. A completed
  ## task wakes all of its awaiters (unlike a channel, which wakes one
  ## counterpart). Foreign-thread safe: rc-free move transfer, same discipline
  ## as wakeChannelWaitersIn.
  withSchedulerLock(s):
    var i = 0
    while i < s.waiters.len:
      let f {.cursor.} = s.waiters[i]
      if f.waitTask.taskSharesState(task):
        when compileOption("threads") and defined(gcAtomicArc):
          if f.workerCandidate:
            broadcast(s.workerCond)
        s.runQueue.add(move s.waiters[i])
        s.waiters.delete(i)
      else:
        inc i

proc wakeTaskWaiters(task: Value) =
  wakeTaskWaitersIn(currentScheduler(), task)

proc scopeHasActorOwner(scope: Scope): bool =
  var current = scope
  while current != nil:
    if current.ownsActors:
      return true
    current = current.parent

proc actorFiberWorkerSafe(actor, handler, state, message, reply: Value,
                          scope: Scope): bool =
  if scope.scopeHasActorOwner():
    return false
  if actor.actorFailureStrategy == afsEscalate:
    return false
  if reply.kind notin {vkNil, vkReplyTo}:
    return false
  var seen = initHashSet[uint64]()
  if not isSendableValue(handler, scope, seen, csmWorker):
    return false
  if not isSendableValue(state, scope, seen, csmWorker):
    return false
  if not isSendableValue(message, scope, seen, csmWorker):
    return false
  reply.kind == vkNil or isSendableValue(reply, scope, seen, csmWorker)

proc workerPublicationValue(value: Value, scope: Scope): tuple[ok: bool,
                                                               value: Value] =
  ## Runtime-created payloads were not part of the pre-enqueue capture graph.
  ## Preserve ordinary error shapes by freezing data-only nodes before rejecting
  ## them; payloads containing local authority (Cell, handles, Env, etc.) fail.
  var seen = initHashSet[uint64]()
  if isSendableValue(value, scope, seen, csmWorker):
    markSharedValue(value)
    return (true, value)
  try:
    let frozen = freezeValue(value)
    seen.clear()
    if isSendableValue(frozen, scope, seen, csmWorker):
      markSharedValue(frozen)
      return (true, frozen)
  except GeneError:
    discard
  (false, NIL)

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
  let state = actor.actorState
  let args = [newActorContext(actor), state, item.message]
  let bound = bindCallScope(handler, proto, args, NamedArgs())
  let workerSafe =
    item.workerAllowed and actorFiberWorkerSafe(actor, handler, state,
                                                item.message, item.reply, scope)
  if workerSafe:
    publishSpawnCapture(bound.scope, proto.chunk)
  Fiber(chunk: proto.chunk, scope: bound.scope, recycleScope: proto.poolCallScope,
        actorOwner: actor, actorReturnType: bound.returnType, actorScope: scope,
        actorAskReply: item.reply, actorMessage: item.message, started: false,
        workerSafe: workerSafe)

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
    try:
      var args = [newActorContext(actor), actor.actorState, item.message]
      let step = applyCall(actor.actorHandler, args, NamedArgs(), scope)
      if step.kind != vkActorStep:
        raiseTypeError("actor handler return", "ActorStep", step, scope)
      if step.actorStepContinue: actor.finishActorContinue(step.actorStepState)
      else: closeActorAndCancelMailbox(actor)
      if item.reply.kind == vkReplyTo and not item.reply.replyToSent:
        discard failMissingReply(item.reply, scope)
      scheduleActor(actor, scope)
    except CatchableError:
      actor.setActorProcessing(false)
      raise
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
        var step = stop.value
        if f.actorReturnType.kind != vkNil:
          step = adaptBoundary("return from actor handler", f.actorReturnType,
                               step, f.actorScope)
        if step.kind != vkActorStep:
          raiseTypeError("actor handler return", "ActorStep", step, f.actorScope)
        if f.workerSafe and activeWorkerThread and step.actorStepContinue:
          var seen = initHashSet[uint64]()
          if not isSendableValue(step.actorStepState, f.actorScope, seen,
                                 csmWorker):
            raiseTypeError("actor worker state", "Send",
                           step.actorStepState, f.actorScope)
          markSharedValue(step.actorStepState)
        if step.actorStepContinue: actor.finishActorContinue(step.actorStepState)
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
        if f.workerSafe and activeWorkerThread:
          var seen = initHashSet[uint64]()
          if not isSendableValue(stop.value, f.scope, seen, csmWorker):
            raiseTypeError("worker task result", "Send", stop.value, f.scope)
          markSharedValue(stop.value)
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
      let askSettled = failReplyTask(f.actorAskReply, e)
      var errorValue = if e.hasErrVal: e.errVal else: newStr(e.msg)
      if f.workerSafe and activeWorkerThread and e.hasErrVal:
        let published = workerPublicationValue(errorValue, f.actorScope)
        if published.ok:
          errorValue = published.value
        else:
          errorValue = newStr("actor worker error payload does not satisfy Send")
      emitSupervisorFailure(actor, f.actorMessage, f.actorScope, e.msg,
                            errorValue)
      case actor.actorFailureStrategy
      of afsRestart:
        if actor.actorRestartInit.kind == vkNil:
          closeActorAndCancelMailbox(actor)
          if not askSettled:
            raise
          return
        if not actorConsumeRestartBudget(actor):
          # ^max_restarts within ^within_ms exhausted (§18.5): stop instead
          # of thrashing through restarts.
          closeActorAndCancelMailbox(actor)
          if not askSettled:
            raise
          return
        try:
          let restartState =
            applyCall(actor.actorRestartInit, [], NamedArgs(), f.actorScope)
          if f.workerSafe and activeWorkerThread:
            var seen = initHashSet[uint64]()
            if not isSendableValue(restartState, f.actorScope, seen, csmWorker):
              raiseTypeError("actor worker restart state", "Send",
                             restartState, f.actorScope)
            markSharedValue(restartState)
          actor.finishActorContinue(restartState)
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
      var publishErrorValue = e.hasErrVal
      if f.workerSafe and activeWorkerThread and publishErrorValue:
        let published = workerPublicationValue(e.errVal, f.scope)
        publishErrorValue = published.ok
        if published.ok:
          e.errVal = published.value
      if publishErrorValue:
        failTask(f.task, e.msg, e.errVal, hasValue = true)
      elif f.workerSafe and activeWorkerThread and e.hasErrVal:
        failTask(f.task, "worker task error payload does not satisfy Send")
      else:
        failTask(f.task, e.msg)
      wakeTaskWaiters(f.task)
  except GenePanic as e:
    if isActorFiber:
      closeActorAndCancelMailbox(actor)
      discard panicReplyTask(f.actorAskReply, e)
      var errorValue = if e.hasErrVal: e.errVal else: newStr(e.msg)
      if f.workerSafe and activeWorkerThread and e.hasErrVal:
        let published = workerPublicationValue(errorValue, f.actorScope)
        if published.ok:
          errorValue = published.value
        else:
          errorValue = newStr("actor worker panic payload does not satisfy Send")
      emitSupervisorFailure(actor, f.actorMessage, f.actorScope, e.msg,
                            errorValue, panic = true)
      raise
    else:
      var publishPanicValue = e.hasErrVal
      if f.workerSafe and activeWorkerThread and publishPanicValue:
        let published = workerPublicationValue(e.errVal, f.scope)
        publishPanicValue = published.ok
        if published.ok:
          e.errVal = published.value
      if publishPanicValue:
        panicTask(f.task, e.msg, e.errVal, hasValue = true)
      elif f.workerSafe and activeWorkerThread and e.hasErrVal:
        panicTask(f.task, "worker task panic payload does not satisfy Send")
      else:
        panicTask(f.task, e.msg)
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
  proc schedulerWorkerStopRequested(s: SchedulerState): bool =
    withSchedulerLock(s):
      s.workerStop

  proc markSchedulerWorkerInactive(s: SchedulerState, slot: int, f: Fiber) =
    withSchedulerLock(s):
      var cleared = false
      if slot >= 0 and slot < s.activeWorkerFibers.len and
          s.activeWorkerFibers[slot] == f:
        s.activeWorkerFibers[slot] = nil
        cleared = true
      else:
        for i in 0 ..< s.activeWorkerFibers.len:
          if s.activeWorkerFibers[i] == f:
            s.activeWorkerFibers[i] = nil
            cleared = true
            break
      if cleared:
        broadcast(s.workerCond)

  proc schedulerHasWorkerProgressUnlocked(s: SchedulerState): bool =
    if s.activeAsyncIoWorkers > 0 or s.pendingAsyncIoRequestsUnlocked() > 0:
      return true
    for f in s.activeWorkerFibers:
      if f != nil:
        return true
    for f in s.runQueue:
      if f.workerCandidate:
        return true
    for f in s.waiters:
      if f.workerCandidate and f.waitTimer:
        return true
    for item in s.askTimeouts:
      if item.task.kind == vkTask and not item.task.taskDone:
        return true

  proc schedulerHasWorkerProgress(s: SchedulerState): bool =
    withSchedulerLock(s):
      result = s.schedulerHasWorkerProgressUnlocked()

  proc waitForSchedulerWorkerProgressChange(s: SchedulerState): bool =
    withSchedulerLock(s):
      if not s.schedulerHasWorkerProgressUnlocked():
        return false
      wait(s.workerCond, s.lock)
      true

  proc schedulerHasWorkerCandidateUnlocked(s: SchedulerState): bool =
    if s.pendingAsyncIoRequestsUnlocked() > 0:
      return true
    for f in s.runQueue:
      if f.workerCandidate:
        return true

  proc popAsyncIoRequest(s: SchedulerState): AsyncIoRequest =
    withSchedulerLock(s):
      if s.pendingAsyncIoRequestsUnlocked() == 0:
        return nil
      result = s.asyncIoQueue[s.asyncIoHead]
      inc s.asyncIoHead
      if s.asyncIoHead == s.asyncIoQueue.len:
        s.asyncIoQueue.setLen(0)
        s.asyncIoHead = 0
      elif s.asyncIoHead >= 64 and s.asyncIoHead * 2 >= s.asyncIoQueue.len:
        s.asyncIoQueue = s.asyncIoQueue[s.asyncIoHead ..< s.asyncIoQueue.len]
        s.asyncIoHead = 0
      inc s.activeAsyncIoWorkers
      broadcast(s.workerCond)

  proc finishAsyncIoRequest(s: SchedulerState) =
    withSchedulerLock(s):
      if s.activeAsyncIoWorkers > 0:
        dec s.activeAsyncIoWorkers
      broadcast(s.workerCond)

  proc runAsyncIoRequest(req: AsyncIoRequest) =
    if req.task.kind == vkTask and req.task.taskDone:
      return
    case req.kind
    of aioReadText:
      try:
        let text = readFile(req.path)
        let value = newStr(text)
        markSharedValue(value)
        if tryCompleteTask(req.task, value):
          wakeTaskWaiters(req.task)
      except CatchableError as e:
        if tryFailTask(req.task,
                       "Fs/read_text_async failed: " & e.msg):
          wakeTaskWaiters(req.task)
    of aioWriteText:
      try:
        writeFile(req.path, req.text)
        if tryCompleteTask(req.task, NIL):
          wakeTaskWaiters(req.task)
      except CatchableError as e:
        if tryFailTask(req.task,
                       "Fs/write_text_async failed: " & e.msg):
          wakeTaskWaiters(req.task)
    of aioTcpReadText:
      try:
        let text = tcpReadText(req.host, req.port, req.maxBytes,
                               req.timeoutMs)
        let value = newStr(text)
        markSharedValue(value)
        if tryCompleteTask(req.task, value):
          wakeTaskWaiters(req.task)
      except CatchableError as e:
        if tryFailTask(req.task,
                       "Net/tcp_read_text_async failed: " & e.msg):
          wakeTaskWaiters(req.task)
    of aioTcpWriteText:
      try:
        tcpWriteText(req.host, req.port, req.text, req.timeoutMs)
        if tryCompleteTask(req.task, NIL):
          wakeTaskWaiters(req.task)
      except CatchableError as e:
        if tryFailTask(req.task,
                       "Net/tcp_write_text_async failed: " & e.msg):
          wakeTaskWaiters(req.task)

  proc waitForSchedulerWorkerCandidate(s: SchedulerState) =
    var pollTimer = false
    withSchedulerLock(s):
      if s.workerStop or s.schedulerHasWorkerCandidateUnlocked():
        return
      for f in s.waiters:
        if f.workerCandidate and f.waitTimer:
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
      # std/locks has no timed Cond wait; poll only while worker-owned timers
      # or ask timeouts can make worker-lane progress.
      os.sleep(schedulerWorkerTimerPollMs)

  proc schedulerWorkerLoop(ctx: SchedulerWorkerContext) {.thread.} =
    {.cast(gcsafe).}:
      let s = ctx.scheduler
      activeScheduler = s
      activeWorkerThread = true
      while not schedulerWorkerStopRequested(s):
        discard wakeExpiredTimers()
        let req = popAsyncIoRequest(s)
        if req != nil:
          try:
            runAsyncIoRequest(req)
          finally:
            finishAsyncIoRequest(s)
          continue
        let f = popRunnableFiber(workerOnly = true, activeWorkerSlot = ctx.slot)
        if f == nil:
          waitForSchedulerWorkerCandidate(s)
          continue
        try:
          if f.task.kind == vkTask and f.task.taskDone:
            wakeTaskWaiters(f.task)
          else:
            runFiber(f)
        finally:
          markSchedulerWorkerInactive(s, ctx.slot, f)

  proc growSchedulerWorkersUnlocked(s: SchedulerState, workerCount: int) =
    let oldCount = s.workers.len
    if workerCount <= oldCount:
      return
    s.activeWorkerFibers.setLen(workerCount)
    s.workerContexts.setLen(workerCount)
    s.workers.setLen(workerCount)
    for i in oldCount ..< workerCount:
      let ctx = SchedulerWorkerContext(scheduler: s, slot: i)
      s.workerContexts[i] = ctx
      createThread(s.workers[i], schedulerWorkerLoop, ctx)

  proc startSchedulerWorkers(s: SchedulerState): bool =
    withSchedulerLock(s):
      let workerCount = configuredSchedulerWorkers()
      if s.workersStarted:
        s.growSchedulerWorkersUnlocked(workerCount)
        inc s.workerLeaseCount
        return true
      if workerCount <= 0:
        return false
      s.workerStop = false
      s.workersStarted = true
      s.workerLeaseCount = 1
      s.growSchedulerWorkersUnlocked(workerCount)
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
        s.workerContexts.setLen(0)
        s.workersStarted = false
        s.workerLeaseCount = 0
        s.workerStop = false
        s.activeWorkerFibers.setLen(0)

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
  pollOsExecAsyncCompletions()
  if schedulerRunOne(skipWorkerSafe = lease.active):
    return true
  # If the cooperative root lane has no exclusive work, let it help drain the
  # worker-candidate queue instead of idling while OS workers own all candidates.
  if lease.active and schedulerRunOne(skipWorkerSafe = false):
    return true
  when compileOption("threads") and defined(gcAtomicArc):
    if lease.active and lease.scheduler != nil and
        waitForSchedulerWorkerProgressChange(lease.scheduler):
      return true
  if schedulerWorkerLeaseHasProgress(lease):
    return true
  false

proc schedulerRunOneRootUntil(deadline: MonoTime,
                              lease: SchedulerWorkerLease): bool =
  pollOsExecAsyncCompletions()
  if schedulerRunOneUntil(deadline, skipWorkerSafe = lease.active):
    return true
  if lease.active and schedulerRunOneUntil(deadline, skipWorkerSafe = false):
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
    when compileOption("threads") and defined(gcAtomicArc):
      for f in s.activeWorkerFibers:
        if f != nil and f.task.taskSharesState(task):
          result = true

proc pumpUntilDone(task: Value) =
  ## Drive the run queue until `task` settles. Each runnable fiber advances to its
  ## next park/completion; a parked fiber resumes only when a channel op wakes it.
  ## If the queue drains with the task unfinished, it can never finish.
  let workerLease = beginSchedulerWorkerLease()
  defer:
    endSchedulerWorkerLease(workerLease)
  while not task.taskDone:
    pollOsExecAsyncCompletions()
    # Completion polling may settle the exact task we are awaiting. Do not
    # enter the scheduler afterward: the poll also ends the external-op count,
    # so an unrelated distant timer could otherwise put a completed await back
    # to sleep before this loop observes it.
    if task.taskDone:
      break
    # Polling-backed native tasks (curses input, HTTP, async exec) are settled
    # only when this root lane calls pollOsExecAsyncCompletions. A distant Gene
    # timer must not let schedulerRunOneRoot sleep past that polling boundary.
    # Keep ordinary timer sleeps efficient when no external operation exists.
    # Curses and local PTY completions are same-thread, nonblocking external
    # operations even in a non-threaded build. Poll them at a short boundary
    # instead of sleeping indefinitely for another key or unrelated timer.
    let progressed =
      if externalNativeOpsPending():
        schedulerRunOneRootUntil(timerDeadline(1), workerLease)
      else:
        schedulerRunOneRoot(workerLease)
    if not progressed:
      if task.taskDone:
        break
      if externalNativeOpsPending():
        os.sleep(1)
        continue
      when compileOption("threads") and defined(gcAtomicArc):
        if task.taskExternalPending:
          # os/exec-*-async is settled by scheduler polling, not by its worker.
          # Avoid a condition wait while any such native op may need this lane.
          if externalNativeOpsPending():
            os.sleep(1)
          else:
            discard task.waitExternalTaskChange()
          if task.taskDone:
            break
          if task.taskExternalPending:
            continue
      when compileOption("threads"):
        # A dedicated-thread native op (os/exec-*-async) can still settle this
        # task or wake a fiber that will; poll instead of declaring deadlock.
        if task.taskExternalPending or externalNativeOpsPending():
          os.sleep(1)
          continue
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

proc generatorFiber(stream: Value): Fiber =
  let continuation = stream.streamGeneratorContinuation
  if continuation == nil:
    return nil
  Fiber(continuation)

proc closeGeneratorStream(stream: Value) {.nimcall.} =
  let fiber = stream.generatorFiber
  if fiber == nil:
    return
  # Clear ownership before unwinding so a cleanup path that closes the same
  # stream remains idempotent.
  stream.clearStreamGeneratorContinuation()
  var stack: seq[Value]
  var ip = 0
  var injectCancel = true
  while true:
    let stopped = runLoop(fiber.chunk, fiber.scope, stack, ip,
                          stopOnYield = true, validateArg = false,
                          fiber = fiber, injectCancel = injectCancel)
    injectCancel = false
    case stopped.kind
    of rskCancel, rskReturn:
      break
    of rskYield:
      # Cleanup must finish; values yielded by an ensure during close have no
      # consumer and are deliberately discarded.
      continue
    else:
      raise newException(GeneError,
        "generator close did not finish cleanup")

proc pullGeneratorStream(stream: Value): StreamPullResult {.nimcall.} =
  let code = stream.streamGeneratorCode
  if code == nil or not (code of FunctionProto):
    return StreamPullResult(has: false, item: NIL)
  let proto = FunctionProto(code)
  let fiber = stream.generatorFiber
  if fiber == nil:
    return StreamPullResult(has: false, item: NIL)
  var stack: seq[Value]
  var ip = 0
  let workerLease = beginSchedulerWorkerLease()
  defer:
    endSchedulerWorkerLease(workerLease)
  var stopped: RunStop
  try:
    stopped = runLoop(proto.chunk, stream.streamGeneratorScope,
                      stack, ip, stopOnYield = true,
                      validateArg = false, fiber = fiber)
  except CatchableError:
    # runLoop has already unwound the failed continuation and its ensures.
    stream.clearStreamGeneratorContinuation()
    raise
  case stopped.kind
  of rskYield:
    StreamPullResult(has: true, item: stopped.value)
  of rskReturn:
    stream.clearStreamGeneratorContinuation()
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
    # Optional without an explicit default: `^name : T?`. Binding nil (not
    # void) keeps the binding inside its own nil-admitting annotation.
    NIL

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
    if proto.hasParamTypes and proto.paramTypes[0].kind != vkNil:
      let typeExpr = proto.paramTypes[0]
      if not (typeExpr.isBareIntType and lhs.kind == vkInt):
        lhs = adaptBoundary("parameter '" & positional[0] & "'",
                            typeExpr, lhs, callee.fnScope)
    var rhs = NIL
    if args.len > 1:
      rhs = args[1]
      if proto.hasParamTypes and proto.paramTypes[1].kind != vkNil:
        let typeExpr = proto.paramTypes[1]
        if not (typeExpr.isBareIntType and rhs.kind == vkInt):
          rhs = adaptBoundary("parameter '" & positional[1] & "'",
                              typeExpr, rhs, callee.fnScope)
    var selected =
      if proto.nativeParamIndex == 0:
        lhs
      elif proto.nativeParamIndex == 1:
        rhs
      else:
        args[proto.nativeParamIndex]
    if proto.nativeOp in {ncoIntIdentity, ncoI64Identity, ncoF64Identity}:
      for i in 2 ..< args.len:
        var value = args[i]
        if proto.hasParamTypes and i < proto.paramTypes.len and
            proto.paramTypes[i].kind != vkNil:
          let typeExpr = proto.paramTypes[i]
          if not (typeExpr.isBareIntType and value.kind == vkInt):
            value = adaptBoundary("parameter '" & positional[i] & "'",
                                  typeExpr, value, callee.fnScope)
        if i == proto.nativeParamIndex:
          selected = value

    let resultValue =
      case proto.nativeOp
      of ncoIntIdentity, ncoI64Identity, ncoF64Identity:
        selected
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
  if expr.kind == vkNode and expr.head.isSymbol("c_abi_type") and
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

proc normalizeOptionalSugar(expr: Value): Value =
  ## `T?` is documented sugar for `(? T)` (§7.4.1); comparisons must not
  ## depend on which spelling a declaration or annotation chose.
  case expr.kind
  of vkSymbol:
    if expr.symVal.len > 1 and expr.symVal.endsWith("?"):
      newNode(newSym("?"), body = @[newSym(expr.symVal[0 .. ^2])])
    else:
      expr
  of vkNode:
    var changed = false
    let head = normalizeOptionalSugar(expr.head)
    if head.bits != expr.head.bits: changed = true
    var props = initPropTable()
    for key, value in expr.props:
      let normalized = normalizeOptionalSugar(value)
      props[key] = normalized
      if normalized.bits != value.bits: changed = true
    var body: seq[Value]
    for item in expr.body:
      let normalized = normalizeOptionalSugar(item)
      body.add normalized
      if normalized.bits != item.bits: changed = true
    if changed:
      newNode(head, props = props, body = body,
              immutable = expr.nodeImmutable)
    else:
      expr
  of vkList:
    var changed = false
    var items: seq[Value]
    for item in expr.listItems:
      let normalized = normalizeOptionalSugar(item)
      items.add normalized
      if normalized.bits != item.bits: changed = true
    if changed: newList(items, expr.listImmutable) else: expr
  of vkMap:
    var changed = false
    var entries = initPropTable()
    for key, value in expr.mapEntries:
      let normalized = normalizeOptionalSugar(value)
      entries[key] = normalized
      if normalized.bits != value.bits: changed = true
    if changed: newMap(entries, expr.mapImmutable) else: expr
  else:
    expr

proc typeExprEqual(a, b: Value): bool =
  if a.isAnyType and b.isAnyType:
    return true
  if equal(a, b):
    return true
  # Only mismatches pay for sugar normalization; equal spellings return above.
  equal(normalizeOptionalSugar(a), normalizeOptionalSugar(b))

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
  of vkBytes: newSym("Bytes")
  of vkRegex: newSym("Regex")
  of vkRange: newSym("Range")
  of vkDate: newSym("Date")
  of vkTime: newSym("Time")
  of vkDateTime: newSym("DateTime")
  of vkTimezone: newSym("Timezone")
  of vkDuration: newSym("Duration")
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
  of vkSet:
    typeNode("Set", @[commonRuntimeTypeExpr(value.setItems)])
  of vkHashMap:
    var keys, values: seq[Value]
    for entry in value.hashMapEntries:
      keys.add entry.key
      values.add entry.val
    typeNode("HashMap", @[commonRuntimeTypeExpr(keys),
                          commonRuntimeTypeExpr(values)])
  of vkNode:
    if value.head.kind == vkType:
      value.head
    elif value.head.kind == vkEnumVariant:
      value.head.enumVariantEnum
    elif value.isSelector:
      newSym("Selector")
    else:
      newSym("Node")
  of vkFunction: newSym(if value.isSyntaxFn: "Fn!" else: "Fn")
  of vkNativeFn: newSym("NativeFn")
  of vkNamespace: newSym("Namespace")
  of vkModule: newSym("Module")
  of vkEnv: newSym("Env")
  of vkCallerEnv: newSym("CallerEnv")
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
  of vkLogger: newSym("Logger")
  of vkType: newSym("Type")
  of vkProtocol: newSym("Protocol")
  of vkProtocolMessage: newSym("ProtocolMessage")
  of vkEnumVariant: value.enumVariantEnum

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
    if expr.head.kind == vkType:
      return matchesTypeExpr(expr.head, value, scope)
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
    var props = initPropTable()
    for key, value in expr.props:
      props[key] = substituteTypeParams(value, bindings, typeParams)
    var meta = initPropTable()
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
    var entries = initPropTable()
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
  var props = initPropTable()
  props["message"] = newStr(message)
  props["where"] = newStr(where)
  props["expected"] = newStr(expected)
  props["actual"] = newStr($value.kind)
  props["actual_value"] = value
  var head = newSym("TypeError")
  var typeError: Value
  if builtinTypeBinding(scope, "TypeError", typeError) and
      typeError.kind == vkType:
    head = typeError
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc raiseCallKindError(where, expected, actual: string, value: Value,
                        scope: Scope) =
  let message = where & " expected " & expected & ", got " & actual
  var props = initPropTable()
  props["message"] = newStr(message)
  props["where"] = newStr(where)
  props["expected"] = newStr(expected)
  props["actual"] = newStr(actual)
  props["actual_value"] = value
  var head = newSym("CallKindError")
  var callKindError: Value
  if builtinTypeBinding(scope, "CallKindError", callKindError) and
      callKindError.kind == vkType:
    head = callKindError
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc raiseMessageError(message, receiverType: string, scope: Scope,
                       lexicalHint = false, protocol = "",
                       missingImpl = false) =
  ## Design §3/§9: a `~` send that resolves to no message on the
  ## receiver's type. Recoverable MessageError (a TypeError subtype).
  ## `lexicalHint` marks the case where the message name also names a lexical
  ## callable — a signpost that a function call, not a send, was likely meant.
  ## `missingImpl` distinguishes a known protocol message with no visible impl
  ## for the receiver; `protocol` names it when the send was qualified.
  var full =
    if missingImpl:
      "no implementation of message '" & message & "' for " & receiverType
    else:
      "no message '" & message & "' on " & receiverType
  if lexicalHint:
    full = full & "; '" & message &
      "' is a function — did you mean to call it, not send it?"
  var props = initPropTable()
  props["message"] = newStr(full)
  props["where"] = newStr("message send")
  props["receiver_type"] = newStr(receiverType)
  if protocol.len > 0:
    props["protocol"] = newStr(protocol)
  var head = newSym("MessageError")
  var messageError: Value
  if builtinTypeBinding(scope, "MessageError", messageError) and
      messageError.kind == vkType:
    head = messageError
  var e: ref GeneError
  new(e)
  e.msg = full
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc isInstanceOfType(value, expected: Value): bool =
  if expected.isEnumType:
    let enumType = value.enumValueEnum
    return enumType.kind == vkType and enumType.isSubtypeOf(expected)
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
  of "Bytes":
    (true, value.kind == vkBytes)
  of "Regex":
    (true, value.kind == vkRegex)
  of "Range":
    (true, value.kind == vkRange)
  of "Date":
    (true, value.kind == vkDate)
  of "Time":
    (true, value.kind == vkTime)
  of "DateTime":
    (true, value.kind == vkDateTime)
  of "Timezone":
    (true, value.kind == vkTimezone)
  of "Duration":
    (true, value.kind == vkDuration)
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
  of "Logger":
    (true, value.kind == vkLogger)
  of "Set":
    (true, value.kind == vkSet)
  of "Map":
    (true, value.kind in {vkMap, vkHashMap})
  of "PropMap":
    (true, value.kind == vkMap)
  of "HashMap":
    (true, value.kind == vkHashMap)
  of "Gene", "Node":
    (true, value.kind == vkNode)
  of "Fn", "Function":
    # Fn! is a sibling of Fn, not a subtype (design §3/§7.2): a fn! value
    # never satisfies an Fn-typed boundary.
    (true, value.kind == vkFunction and not value.isSyntaxFn)
  of "Fn!":
    (true, value.isSyntaxFn)
  of "NativeFn":
    (true, value.kind == vkNativeFn)
  of "Selector":
    (true, value.kind == vkNode and value.isSelector)
  of "Callable":
    # fn! values implement SyntaxCallable, not Callable (design §3).
    (true, (value.kind == vkFunction and not value.isSyntaxFn) or
      value.kind in {vkNativeFn, vkFfiCallable, vkType, vkProtocolMessage} or
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
  of "CallerEnv":
    (true, value.kind == vkCallerEnv)
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

const maxTypeAliasDepth = 256
var typeAliasDepth {.threadvar.}: int

template expandAlias(call: untyped): untyped =
  ## Guard transparent-alias expansion against a cyclic alias (`(alias A A)`
  ## or A→B→A), which would otherwise recurse until the stack overflows.
  inc typeAliasDepth
  if typeAliasDepth > maxTypeAliasDepth:
    typeAliasDepth = 0
    raise newException(GeneError, "cyclic type alias")
  try: call
  finally: dec typeAliasDepth

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
      if scope.lookupOptional(expr.symVal, resolved) and
          resolved.kind in {vkType, vkProtocol}:
        if resolved.isTypeAlias:
          return expandAlias(closeTypeExpr(resolved.typeAliasExpr, scope))
        return resolved
      let segments = expr.symVal.split('/')
      if segments.len > 1 and scope.lookupOptional(segments[0], resolved):
        for i in 1 ..< segments.len:
          if resolved.kind == vkModule:
            resolved = resolved.moduleRootNamespace
          if resolved.kind != vkNamespace:
            resolved = VOID
            break
          resolved = resolved.exportedBinding(segments[i])
        if resolved.kind in {vkType, vkProtocol}:
          if resolved.isTypeAlias:
            return expandAlias(closeTypeExpr(resolved.typeAliasExpr, scope))
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
    if expr.head.isSymbol("path") and expr.body.len > 0 and scope != nil and
        expr.body[0].kind == vkSymbol:
      var resolved: Value
      if scope.lookupOptional(expr.body[0].symVal, resolved):
        for i in 1 ..< expr.body.len:
          if expr.body[i].kind != vkSymbol:
            resolved = VOID
            break
          if resolved.kind == vkModule:
            resolved = resolved.moduleRootNamespace
          if resolved.kind != vkNamespace:
            resolved = VOID
            break
          resolved = resolved.exportedBinding(expr.body[i].symVal)
        if resolved.kind in {vkType, vkProtocol}:
          return resolved
    let closedHead = closeTypeExpr(expr.head, scope)
    var changed = closedHead.bits != expr.head.bits
    var props = initPropTable()
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
    var meta = initPropTable()
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
    var entries = initPropTable()
    for key, value in expr.mapEntries:
      let closed = closeTypeExpr(value, scope)
      entries[key] = closed
      if closed.bits != value.bits:
        changed = true
    if changed: newMap(entries, expr.mapImmutable) else: expr
  else:
    expr

proc unifySigTypeExpr(expected, actual: Value, typeParams: seq[string],
                      bindings: var Table[string, Value],
                      expectedScope, fnScope: Scope): bool =
  ## Compare a ground expected type against a declared signature component
  ## that may mention the function's type parameters. Each type parameter
  ## binds to the first ground type it meets and must stay consistent across
  ## every signature component; the check precedes closeTypeExpr so a
  ## same-named lexical type can never shadow a type parameter.
  let expected = normalizeOptionalSugar(expected)
  let actual = normalizeOptionalSugar(actual)
  if actual.kind == vkSymbol and typeParams.len > 0 and
      actual.symVal in typeParams:
    let closedExpected = closeTypeExpr(expected, expectedScope)
    if bindings.hasKey(actual.symVal):
      return typeExprEqual(closedExpected, bindings[actual.symVal])
    bindings[actual.symVal] = closedExpected
    return true
  if expected.kind == vkNode and actual.kind == vkNode:
    # Structural descent so nested type parameters ((List T), (? T), ...)
    # unify; leaves fall through to the closed nominal comparison below.
    if expected.body.len != actual.body.len:
      return false
    if expected.props.len != actual.props.len:
      return false
    for key, expectedProp in expected.props:
      if not actual.props.hasKey(key):
        return false
      if not unifySigTypeExpr(expectedProp, actual.props[key], typeParams,
                              bindings, expectedScope, fnScope):
        return false
    if not unifySigTypeExpr(expected.head, actual.head, typeParams,
                            bindings, expectedScope, fnScope):
      return false
    for i, expectedItem in expected.body:
      if not unifySigTypeExpr(expectedItem, actual.body[i], typeParams,
                              bindings, expectedScope, fnScope):
        return false
    return true
  typeExprEqual(closeTypeExpr(expected, expectedScope),
                closeTypeExpr(actual, fnScope))

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
    # `T?` is sugar for `(? T)` = `(| T Nil)`: nil, or the stripped type. The
    # `?` suffix is only special in type position, so predicate names like
    # `empty?` in value position are never affected.
    if name.len > 1 and name[^1] == '?':
      return value.kind == vkNil or
             matchesTypeExpr(newSym(name[0 ..< name.len - 1]), value, scope)
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
    if scope != nil and scope.lookupOptional(name, resolved):
      if resolved.isTypeAlias:
        return expandAlias(matchesTypeExpr(resolved.typeAliasExpr, value, scope))
      if resolved.kind == vkType:
        return value.isInstanceOfType(resolved)
      if resolved.kind == vkProtocol:
        let typ = value.receiverType
        return typ.kind == vkType and
          scope.typeImplementsProtocol(typ, resolved)
    if scope != nil:
      let segments = name.split('/')
      if segments.len > 1 and scope.lookupOptional(segments[0], resolved):
        for i in 1 ..< segments.len:
          if resolved.kind == vkModule:
            resolved = resolved.moduleRootNamespace
          if resolved.kind != vkNamespace:
            resolved = VOID
            break
          resolved = resolved.exportedBinding(segments[i])
        if resolved.isTypeAlias:
          return expandAlias(matchesTypeExpr(resolved.typeAliasExpr, value, scope))
        if resolved.kind == vkType:
          return value.isInstanceOfType(resolved)
        if resolved.kind == vkProtocol:
          let typ = value.receiverType
          return typ.kind == vkType and
            scope.typeImplementsProtocol(typ, resolved)
    raise newException(GeneError, "unknown type annotation: " & name)
  of vkNode:
    let closedExpr = closeTypeExpr(expr, scope)
    if closedExpr.bits != expr.bits:
      return matchesTypeExpr(closedExpr, value, scope)
    if expr.head.kind == vkType:
      if expr.head.isEnumType:
        let arity = expr.head.enumTypeParams.len
        if expr.body.len != arity:
          raise newException(GeneError, expr.head.typeName & " expects " &
            $arity & " type argument(s), got " & $expr.body.len)
      elif expr.body.len != 0:
        raise newException(GeneError,
          expr.head.typeName & " is not a generic type")
      return value.isInstanceOfType(expr.head)
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
      of "?":
        if expr.body.len == 0:
          raise newException(GeneError, "(? T ...) expects at least one type")
        if value.kind == vkNil:
          return true
        for alt in expr.body:
          if matchesTypeExpr(alt, value, scope):
            return true
        return false
      of "opt":
        # Legacy internal compatibility only. Never emit this spelling.
        if expr.body.len != 1:
          raise newException(GeneError, "(? T) expects one type")
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
      of "Tuple":
        if value.kind != vkList:
          return false
        if value.listItems.len != expr.body.len:
          return false
        for i, itemType in expr.body:
          if not matchesTypeExpr(itemType, value.listItems[i], scope):
            return false
        return true
      of "Fn":
        if expr.body.len != 2 or expr.body[0].kind != vkList:
          raise newException(GeneError,
            "(Fn [A ...] R ^errors [E ...]) expects parameters and a return type")
        for key, _ in expr.props:
          if key != "errors" and key != "named":
            raise newException(GeneError,
              "function type got unexpected named argument: " & key)
        if expr.props.hasKey("errors") and expr.props["errors"].kind != vkList:
          raise newException(GeneError, "function type ^errors must be a list")
        if expr.props.hasKey("named") and expr.props["named"].kind != vkMap:
          raise newException(GeneError, "function type ^named must be a map")
        if value.kind != vkFunction or value.isSyntaxFn:
          return false
        let code = value.fnCode
        if code == nil or not (code of FunctionProto):
          return false
        let proto = FunctionProto(code)
        # Usable-as matching: the type describes one call shape — `arity`
        # positionals (unbounded when it ends in a body-schema-style `T...`
        # marker) plus the ^named entries — and matches any ordinary fn that
        # admits that shape with invariant-equal parameter/return types.
        let expectedParams = expr.body[0].listItems
        var hasExpectedRest = false
        var expectedRest = NIL
        if expectedParams.len > 0:
          let last = expectedParams[^1]
          if last.kind == vkSymbol and last.symVal.len > 3 and
              last.symVal.endsWith("..."):
            hasExpectedRest = true
            expectedRest = newSym(last.symVal[0 .. ^4])
        let arity =
          if hasExpectedRest: expectedParams.len - 1 else: expectedParams.len
        if proto.requiredPositional > arity:
          return false
        if arity > proto.params.len and proto.restParam.len == 0:
          return false
        if hasExpectedRest and proto.restParam.len == 0:
          return false
        template positionalType(i: int): Value =
          if i < proto.paramTypes.len and proto.paramTypes[i].kind != vkNil:
            proto.paramTypes[i]
          else:
            # Untyped declared params and the (always untyped) rest binder
            # both admit exactly Any under MVP invariance.
            newSym("Any")
        # A generic function matches when one consistent instantiation of its
        # type parameters makes every compared signature component equal.
        var typeBindings = initTable[string, Value]()
        template sigMatches(expectedExpr, actualExpr: Value): bool =
          unifySigTypeExpr(expectedExpr, actualExpr, proto.typeParams,
                           typeBindings, scope, value.fnScope)
        for i in 0 ..< arity:
          if not sigMatches(expectedParams[i], positionalType(i)):
            return false
        if hasExpectedRest:
          # Repeated-tail values land in declared params past the fixed
          # prefix and finally in the rest binder; every landing spot must
          # carry the marker's element type. An untyped rest binder admits
          # exactly `Any`; a typed `xs... : T` binder admits `T`.
          for i in arity ..< proto.params.len:
            if not sigMatches(expectedRest, positionalType(i)):
              return false
          let restElem =
            if proto.restType.kind != vkNil: proto.restType
            else: newSym("Any")
          if not sigMatches(expectedRest, restElem):
            return false
        # ^named entries must exist with invariant-equal declared types;
        # unlisted named parameters must be optional so a caller through the
        # typed view can always omit them.
        if expr.props.hasKey("named"):
          for key, expectedNamed in expr.props["named"].mapEntries:
            var found = false
            for p in proto.namedParams:
              if p.arg == key:
                found = true
                let actualNamed =
                  if p.typeExpr.kind != vkNil: p.typeExpr
                  else: newSym("Any")
                if not sigMatches(expectedNamed, actualNamed):
                  return false
                break
            if not found:
              return false
        for p in proto.namedParams:
          if not p.defaultValue.optional:
            if not (expr.props.hasKey("named") and
                    expr.props["named"].mapEntries.hasKey(p.arg)):
              return false
        let actualReturn =
          if proto.hasReturnType: proto.returnType
          else: newSym("Any")
        if not sigMatches(expr.body[1], actualReturn):
          return false
        if expr.props.hasKey("errors"):
          let expectedErrors = expr.props["errors"].listItems
          if not value.fnChecksErrors or expectedErrors.len != value.fnErrorTypes.len:
            return false
          for i, expected in expectedErrors:
            if not sigMatches(expected, value.fnErrorTypes[i]):
              return false
        elif value.fnChecksErrors:
          return false
        return true
      of "Set":
        if value.kind != vkSet:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len != 1:
          raise newException(GeneError, "(Set T) expects one item type")
        for item in value.setItems:
          if not matchesTypeExpr(expr.body[0], item, scope):
            return false
        return true
      of "Map":
        if value.kind notin {vkMap, vkHashMap}:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len notin [1, 2]:
          raise newException(GeneError, "(Map K V) expects key and value types")
        let valueType = expr.body[^1]
        case value.kind
        of vkMap:
          for key, item in value.mapEntries:
            if expr.body.len == 2 and not matchesMapKeyType(expr.body[0], key, scope):
              return false
            if not matchesTypeExpr(valueType, item, scope):
              return false
        of vkHashMap:
          for entry in value.hashMapEntries:
            if expr.body.len == 2 and not matchesTypeExpr(expr.body[0], entry.key, scope):
              return false
            if not matchesTypeExpr(valueType, entry.val, scope):
              return false
        else:
          discard
        return true
      of "PropMap":
        if value.kind != vkMap:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len notin [1, 2]:
          raise newException(GeneError, "(PropMap K V) expects key and value types")
        let valueType = expr.body[^1]
        for key, item in value.mapEntries:
          if expr.body.len == 2 and not matchesMapKeyType(expr.body[0], key, scope):
            return false
          if not matchesTypeExpr(valueType, item, scope):
            return false
        return true
      of "HashMap":
        if value.kind != vkHashMap:
          return false
        if expr.body.len == 0:
          return true
        if expr.body.len notin [1, 2]:
          raise newException(GeneError, "(HashMap K V) expects key and value types")
        let valueType = expr.body[^1]
        for entry in value.hashMapEntries:
          if expr.body.len == 2 and not matchesTypeExpr(expr.body[0], entry.key, scope):
            return false
          if not matchesTypeExpr(valueType, entry.val, scope):
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
        if messageType.isSymbol("Any") and value.actorMessageTypeExplicit:
          return typeExprEqual(closeTypeExpr(expr.body[0], scope), messageType)
        if messageType.kind != vkNil and not messageType.isSymbol("Any"):
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
    if expr.isTypeAlias:
      expandAlias(matchesTypeExpr(expr.typeAliasExpr, value, scope))
    else:
      value.isInstanceOfType(expr)
  of vkProtocol:
    let typ = value.receiverType
    typ.kind == vkType and scope != nil and
      scope.typeImplementsProtocol(typ, expr)
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
      not value.actorMessageTypeExplicit and
      (value.actorMessageType.kind == vkNil or
       value.actorMessageType.isSymbol("Any")):
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
  v.kind == vkNode and v.head.isSymbol("call_stage") and v.body.len > 0

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
    # A symbol segment's payload is directly a PropTable key id — no string,
    # no intern-table probe. A string segment probes lookup-only: an
    # un-interned key text cannot be present in any PropTable.
    let keyId = if segment.kind == vkSymbol: segment.symbolId
                else: lookupPropKeyId(segment.strVal)
    template key: string =
      (if segment.kind == vkSymbol: segment.symVal else: segment.strVal)
    case target.kind
    of vkMap:
      if keyId < 0: VOID
      else: target.mapEntries.getOrDefaultById(keyId, VOID)
    of vkNode:
      let prop =
        if keyId < 0: VOID
        else: target.props.getOrDefaultById(keyId, VOID)
      if prop.kind != vkVoid:
        prop
      elif keyId < 0:
        VOID
      else:
        ensureNodeProjectionKeyIds()
        if keyId == nodeHeadKeyId: target.head
        elif keyId == nodePropsKeyId: newMap(target.props)
        elif keyId == nodeBodyKeyId: newList(target.body)
        elif keyId == nodeMetaKeyId: newMap(target.meta)
        else: VOID
    of vkList:
      VOID
    of vkNamespace:
      # Qualified access reads the namespace's own exports (not its parent chain).
      target.exportedBinding(key)
    of vkModule:
      target.moduleRootNamespace.exportedBinding(key)
    of vkProtocol:
      # Own message first; otherwise a unique closure match lets an inherited
      # message be spelled through the child protocol (docs/core.md §3.2).
      let own = target.protocolMessages.getOrDefault(key, VOID)
      if own.kind != vkVoid:
        own
      else:
        let candidates = target.protocolClosureByName(key)
        if candidates.len == 1:
          candidates[0]
        elif candidates.len > 1:
          raise newException(GeneError,
            "ambiguous message '" & key & "' in protocol " &
            target.protocolName & "; qualify with the defining protocol")
        else:
          VOID
    of vkType:
      if target.isEnumType:
        let variant = target.enumVariantDescriptor(key)
        if variant.kind != vkVoid:
          variant
        else:
          let message = typeDirectMessage(target, key)
          if message.kind == vkNil: VOID else: message
      else:
        # Qualified type-direct message access, e.g. Box/get (docs/core.md §8);
        # walks the ^is chain like send resolution does.
        let message = typeDirectMessage(target, key)
        if message.kind == vkNil: VOID else: message
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

proc raiseSelectorMissing(segment: Value) =
  let message = "selector lookup failed at segment: " & segment.print()
  var props = initPropTable()
  props["message"] = newStr(message)
  props["segment"] = segment
  var head = newSym("SelectorMissing")
  let root = builtinsScope()
  var missingType: Value
  if builtinTypeBinding(root, "SelectorMissing", missingType) and
      missingType.kind == vkType:
    head = missingType
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc selectorMissingResult(selector: Value, segment: Value): Value =
  if selector.selectorStrict:
    raiseSelectorMissing(segment)
  if selector.props.hasKey("default"):
    selector.props["default"]
  else:
    VOID

proc applySelector(selector, target: Value): Value =
  if selector.props.len == 0 and selector.body.len == 1:
    let segment = selector.body[0]
    case segment.kind
    of vkInt, vkSymbol, vkString:
      return staticLookup(target, segment)
    else:
      discard
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
        raiseSelectorMissing(segment)
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

proc ffiCPtrDiffArg(name: string, value: Value): GeneCPtrDiff =
  let raw = requireInt64(name, value)
  if raw < int64(low(GeneCPtrDiff)) or raw > int64(high(GeneCPtrDiff)):
    raise newException(GeneError, name & " is out of C/PtrDiff range")
  GeneCPtrDiff(raw)

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

proc compositeLabelHasSingleArg(label, head: string): bool =
  let prefix = "(" & head & " "
  if not label.startsWith(prefix) or not label.endsWith(")"):
    return false
  let argStart = prefix.len
  let argStop = label.high
  if argStart >= argStop:
    return false
  var depth = 0
  for i in argStart ..< argStop:
    case label[i]
    of '(':
      inc depth
    of ')':
      dec depth
      if depth < 0:
        return false
    of ' ':
      if depth == 0:
        return false
    else:
      discard
  depth == 0

proc isFfiPtrLabel(label: string): bool =
  label.compositeLabelHasSingleArg("C/Ptr") or
    label.compositeLabelHasSingleArg("C/NullablePtr") or
    label.compositeLabelHasSingleArg("C/ConstPtr") or
    label.compositeLabelHasSingleArg("C/NullableConstPtr") or
    label.compositeLabelHasSingleArg("C/OwnedPtr")

proc isFfiSliceLabel(label: string): bool =
  label.compositeLabelHasSingleArg("C/Slice")

proc isFfiBufferLabel(label: string): bool =
  label.compositeLabelHasSingleArg("Buffer")

proc isFfiNullablePtrLabel(label: string): bool =
  label.compositeLabelHasSingleArg("C/NullablePtr") or
    label.compositeLabelHasSingleArg("C/NullableConstPtr")

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
  if label.compositeLabelHasSingleArg("C/OwnedPtr"):
    if releaseAddress == nil:
      raise newException(GeneError,
        "FFI OwnedPtr result requires a release function")
    newCForeignOwnedPtr(address, releaseAddress, ffiPointerTarget(label))
  elif label.compositeLabelHasSingleArg("C/ConstPtr") or
      label.compositeLabelHasSingleArg("C/NullableConstPtr"):
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
  buffer: Value
  elementLabel: string
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
  result.buffer = checked
  result.elementLabel = elementLabel
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

proc copyBackFfiBufferArg(arg: FfiBufferArg) =
  if arg.buffer.kind != vkBuffer:
    return
  for i, byte in arg.bytes:
    let item =
      case arg.elementLabel
      of "C/Int8", "C/Char":
        newInt(int64(cast[int8](byte)))
      else:
        newInt(int64(byte))
    arg.buffer.setBufferItem(i, item)

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
  template returnFfiBufferResult(arg: FfiBufferArg, callExpr,
                                 resultExpr: untyped): untyped =
    block:
      let nativeResult {.inject.} = callExpr
      copyBackFfiBufferArg(arg)
      return resultExpr

  template returnFfiBufferVoid(arg: FfiBufferArg, callExpr: untyped): untyped =
    block:
      callExpr
      copyBackFfiBufferArg(arg)
      return NIL

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
      type VoidPtrDiffProc = proc(): GeneCPtrDiff {.cdecl.}
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
    of "C/Int32":
      type BoolInt32Proc = proc(x: bool): int32 {.cdecl.}
      let fn = cast[BoolInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type BoolInt16Proc = proc(x: bool): int16 {.cdecl.}
      let fn = cast[BoolInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type BoolShortProc = proc(x: bool): cshort {.cdecl.}
      let fn = cast[BoolShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type BoolInt8Proc = proc(x: bool): int8 {.cdecl.}
      let fn = cast[BoolInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type BoolCharProc = proc(x: bool): cchar {.cdecl.}
      let fn = cast[BoolCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type BoolUIntProc = proc(x: bool): cuint {.cdecl.}
      let fn = cast[BoolUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type BoolUInt32Proc = proc(x: bool): uint32 {.cdecl.}
      let fn = cast[BoolUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type BoolUInt16Proc = proc(x: bool): uint16 {.cdecl.}
      let fn = cast[BoolUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type BoolUShortProc = proc(x: bool): cushort {.cdecl.}
      let fn = cast[BoolUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type BoolUInt8Proc = proc(x: bool): uint8 {.cdecl.}
      let fn = cast[BoolUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type BoolUCharProc = proc(x: bool): uint8 {.cdecl.}
      let fn = cast[BoolUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type BoolLongProc = proc(x: bool): clong {.cdecl.}
      let fn = cast[BoolLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type BoolULongProc = proc(x: bool): culong {.cdecl.}
      let fn = cast[BoolULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type BoolInt64Proc = proc(x: bool): int64 {.cdecl.}
      let fn = cast[BoolInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type BoolUInt64Proc = proc(x: bool): uint64 {.cdecl.}
      let fn = cast[BoolUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type BoolSizeProc = proc(x: bool): csize_t {.cdecl.}
      let fn = cast[BoolSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type BoolPtrDiffProc = proc(x: bool): GeneCPtrDiff {.cdecl.}
      let fn = cast[BoolPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
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
    of "C/Int32":
      type CharInt32Proc = proc(x: cchar): int32 {.cdecl.}
      let fn = cast[CharInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type CharInt16Proc = proc(x: cchar): int16 {.cdecl.}
      let fn = cast[CharInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type CharShortProc = proc(x: cchar): cshort {.cdecl.}
      let fn = cast[CharShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type CharInt8Proc = proc(x: cchar): int8 {.cdecl.}
      let fn = cast[CharInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type CharUIntProc = proc(x: cchar): cuint {.cdecl.}
      let fn = cast[CharUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type CharUInt32Proc = proc(x: cchar): uint32 {.cdecl.}
      let fn = cast[CharUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type CharUInt16Proc = proc(x: cchar): uint16 {.cdecl.}
      let fn = cast[CharUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type CharUShortProc = proc(x: cchar): cushort {.cdecl.}
      let fn = cast[CharUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type CharUInt8Proc = proc(x: cchar): uint8 {.cdecl.}
      let fn = cast[CharUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type CharLongProc = proc(x: cchar): clong {.cdecl.}
      let fn = cast[CharLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type CharULongProc = proc(x: cchar): culong {.cdecl.}
      let fn = cast[CharULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type CharInt64Proc = proc(x: cchar): int64 {.cdecl.}
      let fn = cast[CharInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type CharUInt64Proc = proc(x: cchar): uint64 {.cdecl.}
      let fn = cast[CharUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type CharSizeProc = proc(x: cchar): csize_t {.cdecl.}
      let fn = cast[CharSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type CharPtrDiffProc = proc(x: cchar): GeneCPtrDiff {.cdecl.}
      let fn = cast[CharPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
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
    of "C/Int32":
      type UCharInt32Proc = proc(x: uint8): int32 {.cdecl.}
      let fn = cast[UCharInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type UCharInt16Proc = proc(x: uint8): int16 {.cdecl.}
      let fn = cast[UCharInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type UCharShortProc = proc(x: uint8): cshort {.cdecl.}
      let fn = cast[UCharShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type UCharInt8Proc = proc(x: uint8): int8 {.cdecl.}
      let fn = cast[UCharInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type UCharUIntProc = proc(x: uint8): cuint {.cdecl.}
      let fn = cast[UCharUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UCharUInt32Proc = proc(x: uint8): uint32 {.cdecl.}
      let fn = cast[UCharUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UCharUInt16Proc = proc(x: uint8): uint16 {.cdecl.}
      let fn = cast[UCharUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type UCharUShortProc = proc(x: uint8): cushort {.cdecl.}
      let fn = cast[UCharUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type UCharUInt8Proc = proc(x: uint8): uint8 {.cdecl.}
      let fn = cast[UCharUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UCharLongProc = proc(x: uint8): clong {.cdecl.}
      let fn = cast[UCharLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type UCharULongProc = proc(x: uint8): culong {.cdecl.}
      let fn = cast[UCharULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type UCharInt64Proc = proc(x: uint8): int64 {.cdecl.}
      let fn = cast[UCharInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type UCharUInt64Proc = proc(x: uint8): uint64 {.cdecl.}
      let fn = cast[UCharUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type UCharSizeProc = proc(x: uint8): csize_t {.cdecl.}
      let fn = cast[UCharSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type UCharPtrDiffProc = proc(x: uint8): GeneCPtrDiff {.cdecl.}
      let fn = cast[UCharPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
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
    of "C/Int32":
      type UInt64Int32Proc = proc(x: uint64): int32 {.cdecl.}
      let fn = cast[UInt64Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type UInt64Int16Proc = proc(x: uint64): int16 {.cdecl.}
      let fn = cast[UInt64Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type UInt64ShortProc = proc(x: uint64): cshort {.cdecl.}
      let fn = cast[UInt64ShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type UInt64Int8Proc = proc(x: uint64): int8 {.cdecl.}
      let fn = cast[UInt64Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type UInt64CharProc = proc(x: uint64): cchar {.cdecl.}
      let fn = cast[UInt64CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type UInt64UIntProc = proc(x: uint64): cuint {.cdecl.}
      let fn = cast[UInt64UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UInt64UInt32Proc = proc(x: uint64): uint32 {.cdecl.}
      let fn = cast[UInt64UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UInt64UInt16Proc = proc(x: uint64): uint16 {.cdecl.}
      let fn = cast[UInt64UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type UInt64UShortProc = proc(x: uint64): cushort {.cdecl.}
      let fn = cast[UInt64UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type UInt64UInt8Proc = proc(x: uint64): uint8 {.cdecl.}
      let fn = cast[UInt64UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type UInt64UCharProc = proc(x: uint64): uint8 {.cdecl.}
      let fn = cast[UInt64UCharProc](callee.ffiCallableAddress)
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
      type UInt64PtrDiffProc = proc(x: uint64): GeneCPtrDiff {.cdecl.}
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
    of "C/Int32":
      type ULongInt32Proc = proc(x: culong): int32 {.cdecl.}
      let fn = cast[ULongInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type ULongInt16Proc = proc(x: culong): int16 {.cdecl.}
      let fn = cast[ULongInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type ULongShortProc = proc(x: culong): cshort {.cdecl.}
      let fn = cast[ULongShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type ULongInt8Proc = proc(x: culong): int8 {.cdecl.}
      let fn = cast[ULongInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type ULongCharProc = proc(x: culong): cchar {.cdecl.}
      let fn = cast[ULongCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type ULongUIntProc = proc(x: culong): cuint {.cdecl.}
      let fn = cast[ULongUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type ULongUInt32Proc = proc(x: culong): uint32 {.cdecl.}
      let fn = cast[ULongUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type ULongUInt16Proc = proc(x: culong): uint16 {.cdecl.}
      let fn = cast[ULongUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type ULongUShortProc = proc(x: culong): cushort {.cdecl.}
      let fn = cast[ULongUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type ULongUInt8Proc = proc(x: culong): uint8 {.cdecl.}
      let fn = cast[ULongUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type ULongUCharProc = proc(x: culong): uint8 {.cdecl.}
      let fn = cast[ULongUCharProc](callee.ffiCallableAddress)
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
      type ULongPtrDiffProc = proc(x: culong): GeneCPtrDiff {.cdecl.}
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
      type PtrDiffIntProc = proc(x: GeneCPtrDiff): cint {.cdecl.}
      let fn = cast[PtrDiffIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type PtrDiffInt32Proc = proc(x: GeneCPtrDiff): int32 {.cdecl.}
      let fn = cast[PtrDiffInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type PtrDiffInt16Proc = proc(x: GeneCPtrDiff): int16 {.cdecl.}
      let fn = cast[PtrDiffInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type PtrDiffShortProc = proc(x: GeneCPtrDiff): cshort {.cdecl.}
      let fn = cast[PtrDiffShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type PtrDiffInt8Proc = proc(x: GeneCPtrDiff): int8 {.cdecl.}
      let fn = cast[PtrDiffInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type PtrDiffCharProc = proc(x: GeneCPtrDiff): cchar {.cdecl.}
      let fn = cast[PtrDiffCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type PtrDiffUIntProc = proc(x: GeneCPtrDiff): cuint {.cdecl.}
      let fn = cast[PtrDiffUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type PtrDiffUInt32Proc = proc(x: GeneCPtrDiff): uint32 {.cdecl.}
      let fn = cast[PtrDiffUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type PtrDiffUInt16Proc = proc(x: GeneCPtrDiff): uint16 {.cdecl.}
      let fn = cast[PtrDiffUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type PtrDiffUShortProc = proc(x: GeneCPtrDiff): cushort {.cdecl.}
      let fn = cast[PtrDiffUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type PtrDiffUInt8Proc = proc(x: GeneCPtrDiff): uint8 {.cdecl.}
      let fn = cast[PtrDiffUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type PtrDiffUCharProc = proc(x: GeneCPtrDiff): uint8 {.cdecl.}
      let fn = cast[PtrDiffUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type PtrDiffLongProc = proc(x: GeneCPtrDiff): clong {.cdecl.}
      let fn = cast[PtrDiffLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type PtrDiffULongProc = proc(x: GeneCPtrDiff): culong {.cdecl.}
      let fn = cast[PtrDiffULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type PtrDiffInt64Proc = proc(x: GeneCPtrDiff): int64 {.cdecl.}
      let fn = cast[PtrDiffInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type PtrDiffUInt64Proc = proc(x: GeneCPtrDiff): uint64 {.cdecl.}
      let fn = cast[PtrDiffUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type PtrDiffSizeProc = proc(x: GeneCPtrDiff): csize_t {.cdecl.}
      let fn = cast[PtrDiffSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type PtrDiffPtrDiffProc = proc(x: GeneCPtrDiff): GeneCPtrDiff {.cdecl.}
      let fn = cast[PtrDiffPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type PtrDiffFloatProc = proc(x: GeneCPtrDiff): cfloat {.cdecl.}
      let fn = cast[PtrDiffFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type PtrDiffDoubleProc = proc(x: GeneCPtrDiff): cdouble {.cdecl.}
      let fn = cast[PtrDiffDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type PtrDiffBoolProc = proc(x: GeneCPtrDiff): bool {.cdecl.}
      let fn = cast[PtrDiffBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type PtrDiffCStrProc = proc(x: GeneCPtrDiff): cstring {.cdecl.}
      let fn = cast[PtrDiffCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type PtrDiffVoidProc = proc(x: GeneCPtrDiff) {.cdecl.}
      let fn = cast[PtrDiffVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type PtrDiffPtrProc = proc(x: GeneCPtrDiff): pointer {.cdecl.}
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
    of "C/Int32":
      type IntInt32Proc = proc(x: cint): int32 {.cdecl.}
      let fn = cast[IntInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type IntInt16Proc = proc(x: cint): int16 {.cdecl.}
      let fn = cast[IntInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type IntShortProc = proc(x: cint): cshort {.cdecl.}
      let fn = cast[IntShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type IntInt8Proc = proc(x: cint): int8 {.cdecl.}
      let fn = cast[IntInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type IntCharProc = proc(x: cint): cchar {.cdecl.}
      let fn = cast[IntCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type IntUIntProc = proc(x: cint): cuint {.cdecl.}
      let fn = cast[IntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type IntUInt32Proc = proc(x: cint): uint32 {.cdecl.}
      let fn = cast[IntUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type IntUInt16Proc = proc(x: cint): uint16 {.cdecl.}
      let fn = cast[IntUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type IntUShortProc = proc(x: cint): cushort {.cdecl.}
      let fn = cast[IntUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type IntUInt8Proc = proc(x: cint): uint8 {.cdecl.}
      let fn = cast[IntUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type IntUCharProc = proc(x: cint): uint8 {.cdecl.}
      let fn = cast[IntUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type IntLongProc = proc(x: cint): clong {.cdecl.}
      let fn = cast[IntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type IntULongProc = proc(x: cint): culong {.cdecl.}
      let fn = cast[IntULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type IntInt64Proc = proc(x: cint): int64 {.cdecl.}
      let fn = cast[IntInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type IntUInt64Proc = proc(x: cint): uint64 {.cdecl.}
      let fn = cast[IntUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type IntSizeProc = proc(x: cint): csize_t {.cdecl.}
      let fn = cast[IntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type IntPtrDiffProc = proc(x: cint): GeneCPtrDiff {.cdecl.}
      let fn = cast[IntPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type IntFloatProc = proc(x: cint): cfloat {.cdecl.}
      let fn = cast[IntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type IntDoubleProc = proc(x: cint): cdouble {.cdecl.}
      let fn = cast[IntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type IntBoolProc = proc(x: cint): bool {.cdecl.}
      let fn = cast[IntBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
      if isFfiPtrLabel(returnLabel):
        type IntPtrProc = proc(x: cint): pointer {.cdecl.}
        let fn = cast[IntPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/UInt":
    let arg0 = ffiCUIntArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type UIntIntProc = proc(x: cuint): cint {.cdecl.}
      let fn = cast[UIntIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type UIntInt32Proc = proc(x: cuint): int32 {.cdecl.}
      let fn = cast[UIntInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type UIntInt16Proc = proc(x: cuint): int16 {.cdecl.}
      let fn = cast[UIntInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type UIntShortProc = proc(x: cuint): cshort {.cdecl.}
      let fn = cast[UIntShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type UIntInt8Proc = proc(x: cuint): int8 {.cdecl.}
      let fn = cast[UIntInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type UIntCharProc = proc(x: cuint): cchar {.cdecl.}
      let fn = cast[UIntCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type UIntUIntProc = proc(x: cuint): cuint {.cdecl.}
      let fn = cast[UIntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UIntUInt32Proc = proc(x: cuint): uint32 {.cdecl.}
      let fn = cast[UIntUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UIntUInt16Proc = proc(x: cuint): uint16 {.cdecl.}
      let fn = cast[UIntUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type UIntUShortProc = proc(x: cuint): cushort {.cdecl.}
      let fn = cast[UIntUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type UIntUInt8Proc = proc(x: cuint): uint8 {.cdecl.}
      let fn = cast[UIntUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type UIntUCharProc = proc(x: cuint): uint8 {.cdecl.}
      let fn = cast[UIntUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UIntLongProc = proc(x: cuint): clong {.cdecl.}
      let fn = cast[UIntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type UIntULongProc = proc(x: cuint): culong {.cdecl.}
      let fn = cast[UIntULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type UIntInt64Proc = proc(x: cuint): int64 {.cdecl.}
      let fn = cast[UIntInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type UIntUInt64Proc = proc(x: cuint): uint64 {.cdecl.}
      let fn = cast[UIntUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type UIntSizeProc = proc(x: cuint): csize_t {.cdecl.}
      let fn = cast[UIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type UIntPtrDiffProc = proc(x: cuint): GeneCPtrDiff {.cdecl.}
      let fn = cast[UIntPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type UIntFloatProc = proc(x: cuint): cfloat {.cdecl.}
      let fn = cast[UIntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UIntDoubleProc = proc(x: cuint): cdouble {.cdecl.}
      let fn = cast[UIntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type UIntBoolProc = proc(x: cuint): bool {.cdecl.}
      let fn = cast[UIntBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int16":
      type UInt32Int16Proc = proc(x: uint32): int16 {.cdecl.}
      let fn = cast[UInt32Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type UInt32ShortProc = proc(x: uint32): cshort {.cdecl.}
      let fn = cast[UInt32ShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type UInt32Int8Proc = proc(x: uint32): int8 {.cdecl.}
      let fn = cast[UInt32Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type UInt32CharProc = proc(x: uint32): cchar {.cdecl.}
      let fn = cast[UInt32CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type UInt32UIntProc = proc(x: uint32): cuint {.cdecl.}
      let fn = cast[UInt32UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UInt32UInt32Proc = proc(x: uint32): uint32 {.cdecl.}
      let fn = cast[UInt32UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UInt32UInt16Proc = proc(x: uint32): uint16 {.cdecl.}
      let fn = cast[UInt32UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type UInt32UShortProc = proc(x: uint32): cushort {.cdecl.}
      let fn = cast[UInt32UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type UInt32UInt8Proc = proc(x: uint32): uint8 {.cdecl.}
      let fn = cast[UInt32UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type UInt32UCharProc = proc(x: uint32): uint8 {.cdecl.}
      let fn = cast[UInt32UCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UInt32LongProc = proc(x: uint32): clong {.cdecl.}
      let fn = cast[UInt32LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type UInt32ULongProc = proc(x: uint32): culong {.cdecl.}
      let fn = cast[UInt32ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type UInt32Int64Proc = proc(x: uint32): int64 {.cdecl.}
      let fn = cast[UInt32Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type UInt32UInt64Proc = proc(x: uint32): uint64 {.cdecl.}
      let fn = cast[UInt32UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type UInt32SizeProc = proc(x: uint32): csize_t {.cdecl.}
      let fn = cast[UInt32SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type UInt32PtrDiffProc = proc(x: uint32): GeneCPtrDiff {.cdecl.}
      let fn = cast[UInt32PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type UInt32FloatProc = proc(x: uint32): cfloat {.cdecl.}
      let fn = cast[UInt32FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UInt32DoubleProc = proc(x: uint32): cdouble {.cdecl.}
      let fn = cast[UInt32DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type UInt32BoolProc = proc(x: uint32): bool {.cdecl.}
      let fn = cast[UInt32BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Short":
      type UInt16ShortProc = proc(x: uint16): cshort {.cdecl.}
      let fn = cast[UInt16ShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type UInt16Int8Proc = proc(x: uint16): int8 {.cdecl.}
      let fn = cast[UInt16Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type UInt16CharProc = proc(x: uint16): cchar {.cdecl.}
      let fn = cast[UInt16CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
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
    of "C/UShort":
      type UInt16UShortProc = proc(x: uint16): cushort {.cdecl.}
      let fn = cast[UInt16UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type UInt16UInt8Proc = proc(x: uint16): uint8 {.cdecl.}
      let fn = cast[UInt16UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type UInt16UCharProc = proc(x: uint16): uint8 {.cdecl.}
      let fn = cast[UInt16UCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UInt16UInt32Proc = proc(x: uint16): uint32 {.cdecl.}
      let fn = cast[UInt16UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UInt16LongProc = proc(x: uint16): clong {.cdecl.}
      let fn = cast[UInt16LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type UInt16ULongProc = proc(x: uint16): culong {.cdecl.}
      let fn = cast[UInt16ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type UInt16Int64Proc = proc(x: uint16): int64 {.cdecl.}
      let fn = cast[UInt16Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type UInt16UInt64Proc = proc(x: uint16): uint64 {.cdecl.}
      let fn = cast[UInt16UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type UInt16SizeProc = proc(x: uint16): csize_t {.cdecl.}
      let fn = cast[UInt16SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type UInt16PtrDiffProc = proc(x: uint16): GeneCPtrDiff {.cdecl.}
      let fn = cast[UInt16PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type UInt16FloatProc = proc(x: uint16): cfloat {.cdecl.}
      let fn = cast[UInt16FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UInt16DoubleProc = proc(x: uint16): cdouble {.cdecl.}
      let fn = cast[UInt16DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type UInt16BoolProc = proc(x: uint16): bool {.cdecl.}
      let fn = cast[UInt16BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int8":
      type UShortInt8Proc = proc(x: cushort): int8 {.cdecl.}
      let fn = cast[UShortInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type UShortCharProc = proc(x: cushort): cchar {.cdecl.}
      let fn = cast[UShortCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
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
    of "C/UInt8":
      type UShortUInt8Proc = proc(x: cushort): uint8 {.cdecl.}
      let fn = cast[UShortUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type UShortUCharProc = proc(x: cushort): uint8 {.cdecl.}
      let fn = cast[UShortUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UShortUInt32Proc = proc(x: cushort): uint32 {.cdecl.}
      let fn = cast[UShortUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UShortLongProc = proc(x: cushort): clong {.cdecl.}
      let fn = cast[UShortLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type UShortULongProc = proc(x: cushort): culong {.cdecl.}
      let fn = cast[UShortULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type UShortInt64Proc = proc(x: cushort): int64 {.cdecl.}
      let fn = cast[UShortInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type UShortUInt64Proc = proc(x: cushort): uint64 {.cdecl.}
      let fn = cast[UShortUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type UShortSizeProc = proc(x: cushort): csize_t {.cdecl.}
      let fn = cast[UShortSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type UShortPtrDiffProc = proc(x: cushort): GeneCPtrDiff {.cdecl.}
      let fn = cast[UShortPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type UShortFloatProc = proc(x: cushort): cfloat {.cdecl.}
      let fn = cast[UShortFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UShortDoubleProc = proc(x: cushort): cdouble {.cdecl.}
      let fn = cast[UShortDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type UShortBoolProc = proc(x: cushort): bool {.cdecl.}
      let fn = cast[UShortBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Short":
      type UInt8ShortProc = proc(x: uint8): cshort {.cdecl.}
      let fn = cast[UInt8ShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type UInt8Int32Proc = proc(x: uint8): int32 {.cdecl.}
      let fn = cast[UInt8Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type UInt8CharProc = proc(x: uint8): cchar {.cdecl.}
      let fn = cast[UInt8CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type UInt8UIntProc = proc(x: uint8): cuint {.cdecl.}
      let fn = cast[UInt8UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type UInt8UInt8Proc = proc(x: uint8): uint8 {.cdecl.}
      let fn = cast[UInt8UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type UInt8UCharProc = proc(x: uint8): uint8 {.cdecl.}
      let fn = cast[UInt8UCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type UInt8UInt16Proc = proc(x: uint8): uint16 {.cdecl.}
      let fn = cast[UInt8UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type UInt8UShortProc = proc(x: uint8): cushort {.cdecl.}
      let fn = cast[UInt8UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type UInt8UInt32Proc = proc(x: uint8): uint32 {.cdecl.}
      let fn = cast[UInt8UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type UInt8LongProc = proc(x: uint8): clong {.cdecl.}
      let fn = cast[UInt8LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type UInt8ULongProc = proc(x: uint8): culong {.cdecl.}
      let fn = cast[UInt8ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type UInt8Int64Proc = proc(x: uint8): int64 {.cdecl.}
      let fn = cast[UInt8Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type UInt8UInt64Proc = proc(x: uint8): uint64 {.cdecl.}
      let fn = cast[UInt8UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type UInt8SizeProc = proc(x: uint8): csize_t {.cdecl.}
      let fn = cast[UInt8SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type UInt8PtrDiffProc = proc(x: uint8): GeneCPtrDiff {.cdecl.}
      let fn = cast[UInt8PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type UInt8FloatProc = proc(x: uint8): cfloat {.cdecl.}
      let fn = cast[UInt8FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type UInt8DoubleProc = proc(x: uint8): cdouble {.cdecl.}
      let fn = cast[UInt8DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type UInt8BoolProc = proc(x: uint8): bool {.cdecl.}
      let fn = cast[UInt8BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Short":
      type Int16ShortProc = proc(x: int16): cshort {.cdecl.}
      let fn = cast[Int16ShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type Int16Int8Proc = proc(x: int16): int8 {.cdecl.}
      let fn = cast[Int16Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type Int16CharProc = proc(x: int16): cchar {.cdecl.}
      let fn = cast[Int16CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/Int32":
      type Int16Int32Proc = proc(x: int16): int32 {.cdecl.}
      let fn = cast[Int16Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt":
      type Int16UIntProc = proc(x: int16): cuint {.cdecl.}
      let fn = cast[Int16UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type Int16UInt16Proc = proc(x: int16): uint16 {.cdecl.}
      let fn = cast[Int16UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type Int16UShortProc = proc(x: int16): cushort {.cdecl.}
      let fn = cast[Int16UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type Int16UInt8Proc = proc(x: int16): uint8 {.cdecl.}
      let fn = cast[Int16UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type Int16UCharProc = proc(x: int16): uint8 {.cdecl.}
      let fn = cast[Int16UCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type Int16UInt32Proc = proc(x: int16): uint32 {.cdecl.}
      let fn = cast[Int16UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int16LongProc = proc(x: int16): clong {.cdecl.}
      let fn = cast[Int16LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type Int16ULongProc = proc(x: int16): culong {.cdecl.}
      let fn = cast[Int16ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type Int16Int64Proc = proc(x: int16): int64 {.cdecl.}
      let fn = cast[Int16Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type Int16UInt64Proc = proc(x: int16): uint64 {.cdecl.}
      let fn = cast[Int16UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type Int16SizeProc = proc(x: int16): csize_t {.cdecl.}
      let fn = cast[Int16SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type Int16PtrDiffProc = proc(x: int16): GeneCPtrDiff {.cdecl.}
      let fn = cast[Int16PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type Int16FloatProc = proc(x: int16): cfloat {.cdecl.}
      let fn = cast[Int16FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int16DoubleProc = proc(x: int16): cdouble {.cdecl.}
      let fn = cast[Int16DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type Int16BoolProc = proc(x: int16): bool {.cdecl.}
      let fn = cast[Int16BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int8":
      type ShortInt8Proc = proc(x: cshort): int8 {.cdecl.}
      let fn = cast[ShortInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type ShortCharProc = proc(x: cshort): cchar {.cdecl.}
      let fn = cast[ShortCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
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
    of "C/UInt8":
      type ShortUInt8Proc = proc(x: cshort): uint8 {.cdecl.}
      let fn = cast[ShortUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type ShortUCharProc = proc(x: cshort): uint8 {.cdecl.}
      let fn = cast[ShortUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type ShortUInt32Proc = proc(x: cshort): uint32 {.cdecl.}
      let fn = cast[ShortUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type ShortLongProc = proc(x: cshort): clong {.cdecl.}
      let fn = cast[ShortLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type ShortULongProc = proc(x: cshort): culong {.cdecl.}
      let fn = cast[ShortULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type ShortInt64Proc = proc(x: cshort): int64 {.cdecl.}
      let fn = cast[ShortInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type ShortUInt64Proc = proc(x: cshort): uint64 {.cdecl.}
      let fn = cast[ShortUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type ShortSizeProc = proc(x: cshort): csize_t {.cdecl.}
      let fn = cast[ShortSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type ShortPtrDiffProc = proc(x: cshort): GeneCPtrDiff {.cdecl.}
      let fn = cast[ShortPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type ShortFloatProc = proc(x: cshort): cfloat {.cdecl.}
      let fn = cast[ShortFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type ShortDoubleProc = proc(x: cshort): cdouble {.cdecl.}
      let fn = cast[ShortDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type ShortBoolProc = proc(x: cshort): bool {.cdecl.}
      let fn = cast[ShortBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Char":
      type Int8CharProc = proc(x: int8): cchar {.cdecl.}
      let fn = cast[Int8CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/Int16":
      type Int8Int16Proc = proc(x: int8): int16 {.cdecl.}
      let fn = cast[Int8Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type Int8ShortProc = proc(x: int8): cshort {.cdecl.}
      let fn = cast[Int8ShortProc](callee.ffiCallableAddress)
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
    of "C/UChar":
      type Int8UCharProc = proc(x: int8): uint8 {.cdecl.}
      let fn = cast[Int8UCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type Int8UInt16Proc = proc(x: int8): uint16 {.cdecl.}
      let fn = cast[Int8UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type Int8UShortProc = proc(x: int8): cushort {.cdecl.}
      let fn = cast[Int8UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type Int8UInt32Proc = proc(x: int8): uint32 {.cdecl.}
      let fn = cast[Int8UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int8LongProc = proc(x: int8): clong {.cdecl.}
      let fn = cast[Int8LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type Int8ULongProc = proc(x: int8): culong {.cdecl.}
      let fn = cast[Int8ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type Int8Int64Proc = proc(x: int8): int64 {.cdecl.}
      let fn = cast[Int8Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type Int8UInt64Proc = proc(x: int8): uint64 {.cdecl.}
      let fn = cast[Int8UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type Int8SizeProc = proc(x: int8): csize_t {.cdecl.}
      let fn = cast[Int8SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type Int8PtrDiffProc = proc(x: int8): GeneCPtrDiff {.cdecl.}
      let fn = cast[Int8PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type Int8FloatProc = proc(x: int8): cfloat {.cdecl.}
      let fn = cast[Int8FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int8DoubleProc = proc(x: int8): cdouble {.cdecl.}
      let fn = cast[Int8DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type Int8BoolProc = proc(x: int8): bool {.cdecl.}
      let fn = cast[Int8BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int16":
      type Int32Int16Proc = proc(x: int32): int16 {.cdecl.}
      let fn = cast[Int32Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type Int32ShortProc = proc(x: int32): cshort {.cdecl.}
      let fn = cast[Int32ShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type Int32Int8Proc = proc(x: int32): int8 {.cdecl.}
      let fn = cast[Int32Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type Int32CharProc = proc(x: int32): cchar {.cdecl.}
      let fn = cast[Int32CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type Int32UIntProc = proc(x: int32): cuint {.cdecl.}
      let fn = cast[Int32UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type Int32UInt32Proc = proc(x: int32): uint32 {.cdecl.}
      let fn = cast[Int32UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type Int32UInt16Proc = proc(x: int32): uint16 {.cdecl.}
      let fn = cast[Int32UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type Int32UShortProc = proc(x: int32): cushort {.cdecl.}
      let fn = cast[Int32UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type Int32UInt8Proc = proc(x: int32): uint8 {.cdecl.}
      let fn = cast[Int32UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type Int32UCharProc = proc(x: int32): uint8 {.cdecl.}
      let fn = cast[Int32UCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int32LongProc = proc(x: int32): clong {.cdecl.}
      let fn = cast[Int32LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type Int32ULongProc = proc(x: int32): culong {.cdecl.}
      let fn = cast[Int32ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type Int32Int64Proc = proc(x: int32): int64 {.cdecl.}
      let fn = cast[Int32Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type Int32UInt64Proc = proc(x: int32): uint64 {.cdecl.}
      let fn = cast[Int32UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type Int32SizeProc = proc(x: int32): csize_t {.cdecl.}
      let fn = cast[Int32SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type Int32PtrDiffProc = proc(x: int32): GeneCPtrDiff {.cdecl.}
      let fn = cast[Int32PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type Int32FloatProc = proc(x: int32): cfloat {.cdecl.}
      let fn = cast[Int32FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int32DoubleProc = proc(x: int32): cdouble {.cdecl.}
      let fn = cast[Int32DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type Int32BoolProc = proc(x: int32): bool {.cdecl.}
      let fn = cast[Int32BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int32":
      type LongInt32Proc = proc(x: clong): int32 {.cdecl.}
      let fn = cast[LongInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type LongInt16Proc = proc(x: clong): int16 {.cdecl.}
      let fn = cast[LongInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type LongShortProc = proc(x: clong): cshort {.cdecl.}
      let fn = cast[LongShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type LongInt8Proc = proc(x: clong): int8 {.cdecl.}
      let fn = cast[LongInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type LongCharProc = proc(x: clong): cchar {.cdecl.}
      let fn = cast[LongCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type LongUIntProc = proc(x: clong): cuint {.cdecl.}
      let fn = cast[LongUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type LongUInt32Proc = proc(x: clong): uint32 {.cdecl.}
      let fn = cast[LongUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type LongUInt16Proc = proc(x: clong): uint16 {.cdecl.}
      let fn = cast[LongUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type LongUShortProc = proc(x: clong): cushort {.cdecl.}
      let fn = cast[LongUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type LongUInt8Proc = proc(x: clong): uint8 {.cdecl.}
      let fn = cast[LongUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type LongUCharProc = proc(x: clong): uint8 {.cdecl.}
      let fn = cast[LongUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type LongLongProc = proc(x: clong): clong {.cdecl.}
      let fn = cast[LongLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type LongULongProc = proc(x: clong): culong {.cdecl.}
      let fn = cast[LongULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type LongInt64Proc = proc(x: clong): int64 {.cdecl.}
      let fn = cast[LongInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type LongUInt64Proc = proc(x: clong): uint64 {.cdecl.}
      let fn = cast[LongUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type LongSizeProc = proc(x: clong): csize_t {.cdecl.}
      let fn = cast[LongSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type LongPtrDiffProc = proc(x: clong): GeneCPtrDiff {.cdecl.}
      let fn = cast[LongPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type LongFloatProc = proc(x: clong): cfloat {.cdecl.}
      let fn = cast[LongFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type LongDoubleProc = proc(x: clong): cdouble {.cdecl.}
      let fn = cast[LongDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type LongBoolProc = proc(x: clong): bool {.cdecl.}
      let fn = cast[LongBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int32":
      type Int64Int32Proc = proc(x: int64): int32 {.cdecl.}
      let fn = cast[Int64Int32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type Int64Int16Proc = proc(x: int64): int16 {.cdecl.}
      let fn = cast[Int64Int16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type Int64ShortProc = proc(x: int64): cshort {.cdecl.}
      let fn = cast[Int64ShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type Int64Int8Proc = proc(x: int64): int8 {.cdecl.}
      let fn = cast[Int64Int8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type Int64CharProc = proc(x: int64): cchar {.cdecl.}
      let fn = cast[Int64CharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type Int64UIntProc = proc(x: int64): cuint {.cdecl.}
      let fn = cast[Int64UIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type Int64UInt32Proc = proc(x: int64): uint32 {.cdecl.}
      let fn = cast[Int64UInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type Int64UInt16Proc = proc(x: int64): uint16 {.cdecl.}
      let fn = cast[Int64UInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type Int64UShortProc = proc(x: int64): cushort {.cdecl.}
      let fn = cast[Int64UShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type Int64UInt8Proc = proc(x: int64): uint8 {.cdecl.}
      let fn = cast[Int64UInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type Int64UCharProc = proc(x: int64): uint8 {.cdecl.}
      let fn = cast[Int64UCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type Int64LongProc = proc(x: int64): clong {.cdecl.}
      let fn = cast[Int64LongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type Int64ULongProc = proc(x: int64): culong {.cdecl.}
      let fn = cast[Int64ULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type Int64Int64Proc = proc(x: int64): int64 {.cdecl.}
      let fn = cast[Int64Int64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type Int64UInt64Proc = proc(x: int64): uint64 {.cdecl.}
      let fn = cast[Int64UInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type Int64SizeProc = proc(x: int64): csize_t {.cdecl.}
      let fn = cast[Int64SizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type Int64PtrDiffProc = proc(x: int64): GeneCPtrDiff {.cdecl.}
      let fn = cast[Int64PtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type Int64FloatProc = proc(x: int64): cfloat {.cdecl.}
      let fn = cast[Int64FloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type Int64DoubleProc = proc(x: int64): cdouble {.cdecl.}
      let fn = cast[Int64DoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type Int64BoolProc = proc(x: int64): bool {.cdecl.}
      let fn = cast[Int64BoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int32":
      type SizeInt32Proc = proc(x: csize_t): int32 {.cdecl.}
      let fn = cast[SizeInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type SizeInt16Proc = proc(x: csize_t): int16 {.cdecl.}
      let fn = cast[SizeInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type SizeShortProc = proc(x: csize_t): cshort {.cdecl.}
      let fn = cast[SizeShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type SizeInt8Proc = proc(x: csize_t): int8 {.cdecl.}
      let fn = cast[SizeInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type SizeCharProc = proc(x: csize_t): cchar {.cdecl.}
      let fn = cast[SizeCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type SizeUIntProc = proc(x: csize_t): cuint {.cdecl.}
      let fn = cast[SizeUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type SizeUInt32Proc = proc(x: csize_t): uint32 {.cdecl.}
      let fn = cast[SizeUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type SizeUInt16Proc = proc(x: csize_t): uint16 {.cdecl.}
      let fn = cast[SizeUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type SizeUShortProc = proc(x: csize_t): cushort {.cdecl.}
      let fn = cast[SizeUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type SizeUInt8Proc = proc(x: csize_t): uint8 {.cdecl.}
      let fn = cast[SizeUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type SizeUCharProc = proc(x: csize_t): uint8 {.cdecl.}
      let fn = cast[SizeUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type SizeLongProc = proc(x: csize_t): clong {.cdecl.}
      let fn = cast[SizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type SizeULongProc = proc(x: csize_t): culong {.cdecl.}
      let fn = cast[SizeULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type SizeInt64Proc = proc(x: csize_t): int64 {.cdecl.}
      let fn = cast[SizeInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type SizeUInt64Proc = proc(x: csize_t): uint64 {.cdecl.}
      let fn = cast[SizeUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type SizeSizeProc = proc(x: csize_t): csize_t {.cdecl.}
      let fn = cast[SizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type SizePtrDiffProc = proc(x: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[SizePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type SizeFloatProc = proc(x: csize_t): cfloat {.cdecl.}
      let fn = cast[SizeFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type SizeDoubleProc = proc(x: csize_t): cdouble {.cdecl.}
      let fn = cast[SizeDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type SizeBoolProc = proc(x: csize_t): bool {.cdecl.}
      let fn = cast[SizeBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
    of "C/Int32":
      type SliceInt32Proc = proc(p: pointer, n: csize_t): int32 {.cdecl.}
      let fn = cast[SliceInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Int16":
      type SliceInt16Proc = proc(p: pointer, n: csize_t): int16 {.cdecl.}
      let fn = cast[SliceInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Short":
      type SliceShortProc = proc(p: pointer, n: csize_t): cshort {.cdecl.}
      let fn = cast[SliceShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Int8":
      type SliceInt8Proc = proc(p: pointer, n: csize_t): int8 {.cdecl.}
      let fn = cast[SliceInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Char":
      type SliceCharProc = proc(p: pointer, n: csize_t): cchar {.cdecl.}
      let fn = cast[SliceCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0.address, arg0.length))
    of "C/UInt":
      type SliceUIntProc = proc(p: pointer, n: csize_t): cuint {.cdecl.}
      let fn = cast[SliceUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/UInt32":
      type SliceUInt32Proc = proc(p: pointer, n: csize_t): uint32 {.cdecl.}
      let fn = cast[SliceUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/UInt16":
      type SliceUInt16Proc = proc(p: pointer, n: csize_t): uint16 {.cdecl.}
      let fn = cast[SliceUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/UShort":
      type SliceUShortProc = proc(p: pointer, n: csize_t): cushort {.cdecl.}
      let fn = cast[SliceUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/UInt8":
      type SliceUInt8Proc = proc(p: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[SliceUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/UChar":
      type SliceUCharProc = proc(p: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[SliceUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Long":
      type SliceLongProc = proc(p: pointer, n: csize_t): clong {.cdecl.}
      let fn = cast[SliceLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/ULong":
      type SliceULongProc = proc(p: pointer, n: csize_t): culong {.cdecl.}
      let fn = cast[SliceULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0.address, arg0.length)))
    of "C/Int64":
      type SliceInt64Proc = proc(p: pointer, n: csize_t): int64 {.cdecl.}
      let fn = cast[SliceInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0.address, arg0.length))
    of "C/UInt64":
      type SliceUInt64Proc = proc(p: pointer, n: csize_t): uint64 {.cdecl.}
      let fn = cast[SliceUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0.address, arg0.length))
    of "C/Size":
      type SliceSizeProc = proc(p: pointer, n: csize_t): csize_t {.cdecl.}
      let fn = cast[SliceSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0.address, arg0.length)))
    of "C/PtrDiff":
      type SlicePtrDiffProc = proc(p: pointer, n: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[SlicePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0.address, arg0.length)))
    of "C/Float":
      type SliceFloatProc = proc(p: pointer, n: csize_t): cfloat {.cdecl.}
      let fn = cast[SliceFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0.address, arg0.length)))
    of "C/Double":
      type SliceDoubleProc = proc(p: pointer, n: csize_t): cdouble {.cdecl.}
      let fn = cast[SliceDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0.address, arg0.length)))
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
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/Int32":
      type BufferInt32Proc = proc(p: pointer, n: csize_t): int32 {.cdecl.}
      let fn = cast[BufferInt32Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/Int16":
      type BufferInt16Proc = proc(p: pointer, n: csize_t): int16 {.cdecl.}
      let fn = cast[BufferInt16Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/Short":
      type BufferShortProc = proc(p: pointer, n: csize_t): cshort {.cdecl.}
      let fn = cast[BufferShortProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/Int8":
      type BufferInt8Proc = proc(p: pointer, n: csize_t): int8 {.cdecl.}
      let fn = cast[BufferInt8Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/Char":
      type BufferCharProc = proc(p: pointer, n: csize_t): cchar {.cdecl.}
      let fn = cast[BufferCharProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            ffiCCharResult(nativeResult))
    of "C/UInt":
      type BufferUIntProc = proc(p: pointer, n: csize_t): cuint {.cdecl.}
      let fn = cast[BufferUIntProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/UInt32":
      type BufferUInt32Proc = proc(p: pointer, n: csize_t): uint32 {.cdecl.}
      let fn = cast[BufferUInt32Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/UInt16":
      type BufferUInt16Proc = proc(p: pointer, n: csize_t): uint16 {.cdecl.}
      let fn = cast[BufferUInt16Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/UShort":
      type BufferUShortProc = proc(p: pointer, n: csize_t): cushort {.cdecl.}
      let fn = cast[BufferUShortProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/UInt8":
      type BufferUInt8Proc = proc(p: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[BufferUInt8Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/UChar":
      type BufferUCharProc = proc(p: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[BufferUCharProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/Long":
      type BufferLongProc = proc(p: pointer, n: csize_t): clong {.cdecl.}
      let fn = cast[BufferLongProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/ULong":
      type BufferULongProc = proc(p: pointer, n: csize_t): culong {.cdecl.}
      let fn = cast[BufferULongProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            ffiCUInt64Value(uint64(nativeResult)))
    of "C/Int64":
      type BufferInt64Proc = proc(p: pointer, n: csize_t): int64 {.cdecl.}
      let fn = cast[BufferInt64Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(nativeResult))
    of "C/UInt64":
      type BufferUInt64Proc = proc(p: pointer, n: csize_t): uint64 {.cdecl.}
      let fn = cast[BufferUInt64Proc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            ffiCUInt64Value(nativeResult))
    of "C/Size":
      type BufferSizeProc = proc(p: pointer, n: csize_t): csize_t {.cdecl.}
      let fn = cast[BufferSizeProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            ffiCUInt64Value(uint64(nativeResult)))
    of "C/PtrDiff":
      type BufferPtrDiffProc = proc(p: pointer, n: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[BufferPtrDiffProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newInt(int64(nativeResult)))
    of "C/Float":
      type BufferFloatProc = proc(p: pointer, n: csize_t): cfloat {.cdecl.}
      let fn = cast[BufferFloatProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newFloat(float64(nativeResult)))
    of "C/Double":
      type BufferDoubleProc = proc(p: pointer, n: csize_t): cdouble {.cdecl.}
      let fn = cast[BufferDoubleProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newFloat(float64(nativeResult)))
    of "C/Bool":
      type BufferBoolProc = proc(p: pointer, n: csize_t): bool {.cdecl.}
      let fn = cast[BufferBoolProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            newBool(nativeResult))
    of "C/CStr":
      type BufferCStrProc = proc(p: pointer, n: csize_t): cstring {.cdecl.}
      let fn = cast[BufferCStrProc](callee.ffiCallableAddress)
      returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                            ffiCStrResult("FFI result for '" &
                              callee.ffiCallableName & "'", nativeResult))
    of "C/Void":
      type BufferVoidProc = proc(p: pointer, n: csize_t) {.cdecl.}
      let fn = cast[BufferVoidProc](callee.ffiCallableAddress)
      returnFfiBufferVoid(arg0, fn(arg0.data, arg0.length))
    else:
      if isFfiPtrLabel(returnLabel):
        type BufferPtrProc = proc(p: pointer, n: csize_t): pointer {.cdecl.}
        let fn = cast[BufferPtrProc](callee.ffiCallableAddress)
        returnFfiBufferResult(arg0, fn(arg0.data, arg0.length),
                              ffiPointerResult(returnLabel, nativeResult,
                                releaseAddress))
  if paramLabels.len == 1 and isFfiPtrLabel(paramLabels[0]):
    let arg0 = ffiPointerArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    case returnLabel
    of "C/Int":
      type PtrIntProc = proc(p: pointer): cint {.cdecl.}
      let fn = cast[PtrIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type PtrInt32Proc = proc(p: pointer): int32 {.cdecl.}
      let fn = cast[PtrInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type PtrInt16Proc = proc(p: pointer): int16 {.cdecl.}
      let fn = cast[PtrInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type PtrShortProc = proc(p: pointer): cshort {.cdecl.}
      let fn = cast[PtrShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type PtrInt8Proc = proc(p: pointer): int8 {.cdecl.}
      let fn = cast[PtrInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type PtrCharProc = proc(p: pointer): cchar {.cdecl.}
      let fn = cast[PtrCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type PtrUIntProc = proc(p: pointer): cuint {.cdecl.}
      let fn = cast[PtrUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type PtrUInt32Proc = proc(p: pointer): uint32 {.cdecl.}
      let fn = cast[PtrUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type PtrUInt16Proc = proc(p: pointer): uint16 {.cdecl.}
      let fn = cast[PtrUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type PtrUShortProc = proc(p: pointer): cushort {.cdecl.}
      let fn = cast[PtrUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type PtrUInt8Proc = proc(p: pointer): uint8 {.cdecl.}
      let fn = cast[PtrUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type PtrUCharProc = proc(p: pointer): uint8 {.cdecl.}
      let fn = cast[PtrUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type PtrLongProc = proc(p: pointer): clong {.cdecl.}
      let fn = cast[PtrLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type PtrULongProc = proc(p: pointer): culong {.cdecl.}
      let fn = cast[PtrULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type PtrInt64Proc = proc(p: pointer): int64 {.cdecl.}
      let fn = cast[PtrInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type PtrUInt64Proc = proc(p: pointer): uint64 {.cdecl.}
      let fn = cast[PtrUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type PtrSizeProc = proc(p: pointer): csize_t {.cdecl.}
      let fn = cast[PtrSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type PtrPtrDiffProc = proc(p: pointer): GeneCPtrDiff {.cdecl.}
      let fn = cast[PtrPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type PtrFloatProc = proc(p: pointer): cfloat {.cdecl.}
      let fn = cast[PtrFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type PtrDoubleProc = proc(p: pointer): cdouble {.cdecl.}
      let fn = cast[PtrDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type PtrBoolProc = proc(p: pointer): bool {.cdecl.}
      let fn = cast[PtrBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
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
      if isFfiPtrLabel(returnLabel):
        type PtrPtrProc = proc(p: pointer): pointer {.cdecl.}
        let fn = cast[PtrPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
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
    of "C/Int16":
      type CStrInt16Proc = proc(s: cstring): int16 {.cdecl.}
      let fn = cast[CStrInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/Short":
      type CStrShortProc = proc(s: cstring): cshort {.cdecl.}
      let fn = cast[CStrShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/Int8":
      type CStrInt8Proc = proc(s: cstring): int8 {.cdecl.}
      let fn = cast[CStrInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/Char":
      type CStrCharProc = proc(s: cstring): cchar {.cdecl.}
      let fn = cast[CStrCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(ctext))
    of "C/UInt":
      type CStrUIntProc = proc(s: cstring): cuint {.cdecl.}
      let fn = cast[CStrUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/UInt32":
      type CStrUInt32Proc = proc(s: cstring): uint32 {.cdecl.}
      let fn = cast[CStrUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/UInt16":
      type CStrUInt16Proc = proc(s: cstring): uint16 {.cdecl.}
      let fn = cast[CStrUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/UShort":
      type CStrUShortProc = proc(s: cstring): cushort {.cdecl.}
      let fn = cast[CStrUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/UInt8":
      type CStrUInt8Proc = proc(s: cstring): uint8 {.cdecl.}
      let fn = cast[CStrUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/UChar":
      type CStrUCharProc = proc(s: cstring): uint8 {.cdecl.}
      let fn = cast[CStrUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/Long":
      type CStrLongProc = proc(s: cstring): clong {.cdecl.}
      let fn = cast[CStrLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/ULong":
      type CStrULongProc = proc(s: cstring): culong {.cdecl.}
      let fn = cast[CStrULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(ctext)))
    of "C/Int64":
      type CStrInt64Proc = proc(s: cstring): int64 {.cdecl.}
      let fn = cast[CStrInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(ctext))
    of "C/UInt64":
      type CStrUInt64Proc = proc(s: cstring): uint64 {.cdecl.}
      let fn = cast[CStrUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(ctext))
    of "C/PtrDiff":
      type CStrPtrDiffProc = proc(s: cstring): GeneCPtrDiff {.cdecl.}
      let fn = cast[CStrPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(ctext)))
    of "C/Float":
      type CStrFloatProc = proc(s: cstring): cfloat {.cdecl.}
      let fn = cast[CStrFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(ctext)))
    of "C/Double":
      type CStrDoubleProc = proc(s: cstring): cdouble {.cdecl.}
      let fn = cast[CStrDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(ctext)))
    of "C/Bool":
      type CStrBoolProc = proc(s: cstring): bool {.cdecl.}
      let fn = cast[CStrBoolProc](callee.ffiCallableAddress)
      return newBool(fn(ctext))
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
    of "C/Int32":
      type DoubleInt32Proc = proc(x: cdouble): int32 {.cdecl.}
      let fn = cast[DoubleInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type DoubleInt16Proc = proc(x: cdouble): int16 {.cdecl.}
      let fn = cast[DoubleInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type DoubleShortProc = proc(x: cdouble): cshort {.cdecl.}
      let fn = cast[DoubleShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type DoubleInt8Proc = proc(x: cdouble): int8 {.cdecl.}
      let fn = cast[DoubleInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type DoubleCharProc = proc(x: cdouble): cchar {.cdecl.}
      let fn = cast[DoubleCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type DoubleUIntProc = proc(x: cdouble): cuint {.cdecl.}
      let fn = cast[DoubleUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type DoubleUInt32Proc = proc(x: cdouble): uint32 {.cdecl.}
      let fn = cast[DoubleUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type DoubleUInt16Proc = proc(x: cdouble): uint16 {.cdecl.}
      let fn = cast[DoubleUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type DoubleUShortProc = proc(x: cdouble): cushort {.cdecl.}
      let fn = cast[DoubleUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type DoubleUInt8Proc = proc(x: cdouble): uint8 {.cdecl.}
      let fn = cast[DoubleUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type DoubleUCharProc = proc(x: cdouble): uint8 {.cdecl.}
      let fn = cast[DoubleUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type DoubleLongProc = proc(x: cdouble): clong {.cdecl.}
      let fn = cast[DoubleLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type DoubleULongProc = proc(x: cdouble): culong {.cdecl.}
      let fn = cast[DoubleULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type DoubleInt64Proc = proc(x: cdouble): int64 {.cdecl.}
      let fn = cast[DoubleInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type DoubleUInt64Proc = proc(x: cdouble): uint64 {.cdecl.}
      let fn = cast[DoubleUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type DoubleSizeProc = proc(x: cdouble): csize_t {.cdecl.}
      let fn = cast[DoubleSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type DoublePtrDiffProc = proc(x: cdouble): GeneCPtrDiff {.cdecl.}
      let fn = cast[DoublePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type DoubleFloatProc = proc(x: cdouble): cfloat {.cdecl.}
      let fn = cast[DoubleFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type DoubleDoubleProc = proc(x: cdouble): cdouble {.cdecl.}
      let fn = cast[DoubleDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type DoubleBoolProc = proc(x: cdouble): bool {.cdecl.}
      let fn = cast[DoubleBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type DoubleCStrProc = proc(x: cdouble): cstring {.cdecl.}
      let fn = cast[DoubleCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type DoubleVoidProc = proc(x: cdouble) {.cdecl.}
      let fn = cast[DoubleVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type DoublePtrProc = proc(x: cdouble): pointer {.cdecl.}
        let fn = cast[DoublePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
  if paramLabels.len == 1 and paramLabels[0] == "C/Float":
    let arg0 = ffiCFloatArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    case returnLabel
    of "C/Int":
      type FloatIntProc = proc(x: cfloat): cint {.cdecl.}
      let fn = cast[FloatIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int32":
      type FloatInt32Proc = proc(x: cfloat): int32 {.cdecl.}
      let fn = cast[FloatInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int16":
      type FloatInt16Proc = proc(x: cfloat): int16 {.cdecl.}
      let fn = cast[FloatInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Short":
      type FloatShortProc = proc(x: cfloat): cshort {.cdecl.}
      let fn = cast[FloatShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Int8":
      type FloatInt8Proc = proc(x: cfloat): int8 {.cdecl.}
      let fn = cast[FloatInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Char":
      type FloatCharProc = proc(x: cfloat): cchar {.cdecl.}
      let fn = cast[FloatCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0))
    of "C/UInt":
      type FloatUIntProc = proc(x: cfloat): cuint {.cdecl.}
      let fn = cast[FloatUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt32":
      type FloatUInt32Proc = proc(x: cfloat): uint32 {.cdecl.}
      let fn = cast[FloatUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt16":
      type FloatUInt16Proc = proc(x: cfloat): uint16 {.cdecl.}
      let fn = cast[FloatUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UShort":
      type FloatUShortProc = proc(x: cfloat): cushort {.cdecl.}
      let fn = cast[FloatUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UInt8":
      type FloatUInt8Proc = proc(x: cfloat): uint8 {.cdecl.}
      let fn = cast[FloatUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/UChar":
      type FloatUCharProc = proc(x: cfloat): uint8 {.cdecl.}
      let fn = cast[FloatUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Long":
      type FloatLongProc = proc(x: cfloat): clong {.cdecl.}
      let fn = cast[FloatLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/ULong":
      type FloatULongProc = proc(x: cfloat): culong {.cdecl.}
      let fn = cast[FloatULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/Int64":
      type FloatInt64Proc = proc(x: cfloat): int64 {.cdecl.}
      let fn = cast[FloatInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0))
    of "C/UInt64":
      type FloatUInt64Proc = proc(x: cfloat): uint64 {.cdecl.}
      let fn = cast[FloatUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0))
    of "C/Size":
      type FloatSizeProc = proc(x: cfloat): csize_t {.cdecl.}
      let fn = cast[FloatSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0)))
    of "C/PtrDiff":
      type FloatPtrDiffProc = proc(x: cfloat): GeneCPtrDiff {.cdecl.}
      let fn = cast[FloatPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0)))
    of "C/Float":
      type FloatFloatProc = proc(x: cfloat): cfloat {.cdecl.}
      let fn = cast[FloatFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Double":
      type FloatDoubleProc = proc(x: cfloat): cdouble {.cdecl.}
      let fn = cast[FloatDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0)))
    of "C/Bool":
      type FloatBoolProc = proc(x: cfloat): bool {.cdecl.}
      let fn = cast[FloatBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0))
    of "C/CStr":
      type FloatCStrProc = proc(x: cfloat): cstring {.cdecl.}
      let fn = cast[FloatCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0))
    of "C/Void":
      type FloatVoidProc = proc(x: cfloat) {.cdecl.}
      let fn = cast[FloatVoidProc](callee.ffiCallableAddress)
      fn(arg0)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type FloatPtrProc = proc(x: cfloat): pointer {.cdecl.}
        let fn = cast[FloatPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0), releaseAddress)
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
    of "C/Int32":
      type CStrCStrInt32Proc = proc(a, b: cstring): int32 {.cdecl.}
      let fn = cast[CStrCStrInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type CStrCStrInt16Proc = proc(a, b: cstring): int16 {.cdecl.}
      let fn = cast[CStrCStrInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type CStrCStrShortProc = proc(a, b: cstring): cshort {.cdecl.}
      let fn = cast[CStrCStrShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type CStrCStrInt8Proc = proc(a, b: cstring): int8 {.cdecl.}
      let fn = cast[CStrCStrInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type CStrCStrCharProc = proc(a, b: cstring): cchar {.cdecl.}
      let fn = cast[CStrCStrCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/UInt":
      type CStrCStrUIntProc = proc(a, b: cstring): cuint {.cdecl.}
      let fn = cast[CStrCStrUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt32":
      type CStrCStrUInt32Proc = proc(a, b: cstring): uint32 {.cdecl.}
      let fn = cast[CStrCStrUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type CStrCStrUInt16Proc = proc(a, b: cstring): uint16 {.cdecl.}
      let fn = cast[CStrCStrUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type CStrCStrUShortProc = proc(a, b: cstring): cushort {.cdecl.}
      let fn = cast[CStrCStrUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type CStrCStrUInt8Proc = proc(a, b: cstring): uint8 {.cdecl.}
      let fn = cast[CStrCStrUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type CStrCStrUCharProc = proc(a, b: cstring): uint8 {.cdecl.}
      let fn = cast[CStrCStrUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Long":
      type CStrCStrLongProc = proc(a, b: cstring): clong {.cdecl.}
      let fn = cast[CStrCStrLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type CStrCStrULongProc = proc(a, b: cstring): culong {.cdecl.}
      let fn = cast[CStrCStrULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/Int64":
      type CStrCStrInt64Proc = proc(a, b: cstring): int64 {.cdecl.}
      let fn = cast[CStrCStrInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type CStrCStrUInt64Proc = proc(a, b: cstring): uint64 {.cdecl.}
      let fn = cast[CStrCStrUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type CStrCStrSizeProc = proc(a, b: cstring): csize_t {.cdecl.}
      let fn = cast[CStrCStrSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type CStrCStrPtrDiffProc = proc(a, b: cstring): GeneCPtrDiff {.cdecl.}
      let fn = cast[CStrCStrPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type CStrCStrFloatProc = proc(a, b: cstring): cfloat {.cdecl.}
      let fn = cast[CStrCStrFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type CStrCStrDoubleProc = proc(a, b: cstring): cdouble {.cdecl.}
      let fn = cast[CStrCStrDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type CStrCStrBoolProc = proc(a, b: cstring): bool {.cdecl.}
      let fn = cast[CStrCStrBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
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
    of "C/Int32":
      type CStrIntInt32Proc = proc(s: cstring, x: cint): int32 {.cdecl.}
      let fn = cast[CStrIntInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type CStrIntInt16Proc = proc(s: cstring, x: cint): int16 {.cdecl.}
      let fn = cast[CStrIntInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type CStrIntShortProc = proc(s: cstring, x: cint): cshort {.cdecl.}
      let fn = cast[CStrIntShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type CStrIntInt8Proc = proc(s: cstring, x: cint): int8 {.cdecl.}
      let fn = cast[CStrIntInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type CStrIntCharProc = proc(s: cstring, x: cint): cchar {.cdecl.}
      let fn = cast[CStrIntCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/UInt":
      type CStrIntUIntProc = proc(s: cstring, x: cint): cuint {.cdecl.}
      let fn = cast[CStrIntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt32":
      type CStrIntUInt32Proc = proc(s: cstring, x: cint): uint32 {.cdecl.}
      let fn = cast[CStrIntUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type CStrIntUInt16Proc = proc(s: cstring, x: cint): uint16 {.cdecl.}
      let fn = cast[CStrIntUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type CStrIntUShortProc = proc(s: cstring, x: cint): cushort {.cdecl.}
      let fn = cast[CStrIntUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type CStrIntUInt8Proc = proc(s: cstring, x: cint): uint8 {.cdecl.}
      let fn = cast[CStrIntUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type CStrIntUCharProc = proc(s: cstring, x: cint): uint8 {.cdecl.}
      let fn = cast[CStrIntUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Long":
      type CStrIntLongProc = proc(s: cstring, x: cint): clong {.cdecl.}
      let fn = cast[CStrIntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type CStrIntULongProc = proc(s: cstring, x: cint): culong {.cdecl.}
      let fn = cast[CStrIntULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/Int64":
      type CStrIntInt64Proc = proc(s: cstring, x: cint): int64 {.cdecl.}
      let fn = cast[CStrIntInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type CStrIntUInt64Proc = proc(s: cstring, x: cint): uint64 {.cdecl.}
      let fn = cast[CStrIntUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type CStrIntSizeProc = proc(s: cstring, x: cint): csize_t {.cdecl.}
      let fn = cast[CStrIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type CStrIntPtrDiffProc = proc(s: cstring, x: cint): GeneCPtrDiff {.cdecl.}
      let fn = cast[CStrIntPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type CStrIntFloatProc = proc(s: cstring, x: cint): cfloat {.cdecl.}
      let fn = cast[CStrIntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type CStrIntDoubleProc = proc(s: cstring, x: cint): cdouble {.cdecl.}
      let fn = cast[CStrIntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type CStrIntBoolProc = proc(s: cstring, x: cint): bool {.cdecl.}
      let fn = cast[CStrIntBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
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
  if paramLabels.len == 2 and paramLabels[0] == "C/CStr" and
      paramLabels[1] == "C/Size":
    let arg0 = ffiCStrArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCSizeArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type CStrSizeIntProc = proc(s: cstring, n: csize_t): cint {.cdecl.}
      let fn = cast[CStrSizeIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type CStrSizeInt32Proc = proc(s: cstring, n: csize_t): int32 {.cdecl.}
      let fn = cast[CStrSizeInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type CStrSizeInt16Proc = proc(s: cstring, n: csize_t): int16 {.cdecl.}
      let fn = cast[CStrSizeInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type CStrSizeShortProc = proc(s: cstring, n: csize_t): cshort {.cdecl.}
      let fn = cast[CStrSizeShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type CStrSizeInt8Proc = proc(s: cstring, n: csize_t): int8 {.cdecl.}
      let fn = cast[CStrSizeInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type CStrSizeCharProc = proc(s: cstring, n: csize_t): cchar {.cdecl.}
      let fn = cast[CStrSizeCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/UInt":
      type CStrSizeUIntProc = proc(s: cstring, n: csize_t): cuint {.cdecl.}
      let fn = cast[CStrSizeUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt32":
      type CStrSizeUInt32Proc = proc(s: cstring, n: csize_t): uint32 {.cdecl.}
      let fn = cast[CStrSizeUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type CStrSizeUInt16Proc = proc(s: cstring, n: csize_t): uint16 {.cdecl.}
      let fn = cast[CStrSizeUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type CStrSizeUShortProc = proc(s: cstring, n: csize_t): cushort {.cdecl.}
      let fn = cast[CStrSizeUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type CStrSizeUInt8Proc = proc(s: cstring, n: csize_t): uint8 {.cdecl.}
      let fn = cast[CStrSizeUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type CStrSizeUCharProc = proc(s: cstring, n: csize_t): uint8 {.cdecl.}
      let fn = cast[CStrSizeUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Long":
      type CStrSizeLongProc = proc(s: cstring, n: csize_t): clong {.cdecl.}
      let fn = cast[CStrSizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type CStrSizeULongProc = proc(s: cstring, n: csize_t): culong {.cdecl.}
      let fn = cast[CStrSizeULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/Int64":
      type CStrSizeInt64Proc = proc(s: cstring, n: csize_t): int64 {.cdecl.}
      let fn = cast[CStrSizeInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type CStrSizeUInt64Proc = proc(s: cstring, n: csize_t): uint64 {.cdecl.}
      let fn = cast[CStrSizeUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type CStrSizeSizeProc = proc(s: cstring, n: csize_t): csize_t {.cdecl.}
      let fn = cast[CStrSizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type CStrSizePtrDiffProc = proc(s: cstring, n: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[CStrSizePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type CStrSizeFloatProc = proc(s: cstring, n: csize_t): cfloat {.cdecl.}
      let fn = cast[CStrSizeFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type CStrSizeDoubleProc = proc(s: cstring, n: csize_t): cdouble {.cdecl.}
      let fn = cast[CStrSizeDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type CStrSizeBoolProc = proc(s: cstring, n: csize_t): bool {.cdecl.}
      let fn = cast[CStrSizeBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type CStrSizeCStrProc = proc(s: cstring, n: csize_t): cstring {.cdecl.}
      let fn = cast[CStrSizeCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type CStrSizeVoidProc = proc(s: cstring, n: csize_t) {.cdecl.}
      let fn = cast[CStrSizeVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type CStrSizePtrProc = proc(s: cstring, n: csize_t): pointer {.cdecl.}
        let fn = cast[CStrSizePtrProc](callee.ffiCallableAddress)
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
    of "C/UInt":
      type IntIntUIntProc = proc(a, b: cint): cuint {.cdecl.}
      let fn = cast[IntIntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type IntIntInt32Proc = proc(a, b: cint): int32 {.cdecl.}
      let fn = cast[IntIntInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type IntIntInt16Proc = proc(a, b: cint): int16 {.cdecl.}
      let fn = cast[IntIntInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type IntIntShortProc = proc(a, b: cint): cshort {.cdecl.}
      let fn = cast[IntIntShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type IntIntInt8Proc = proc(a, b: cint): int8 {.cdecl.}
      let fn = cast[IntIntInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type IntIntCharProc = proc(a, b: cint): cchar {.cdecl.}
      let fn = cast[IntIntCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type IntIntLongProc = proc(a, b: cint): clong {.cdecl.}
      let fn = cast[IntIntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type IntIntULongProc = proc(a, b: cint): culong {.cdecl.}
      let fn = cast[IntIntULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type IntIntUInt32Proc = proc(a, b: cint): uint32 {.cdecl.}
      let fn = cast[IntIntUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type IntIntUInt16Proc = proc(a, b: cint): uint16 {.cdecl.}
      let fn = cast[IntIntUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type IntIntUShortProc = proc(a, b: cint): cushort {.cdecl.}
      let fn = cast[IntIntUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type IntIntUInt8Proc = proc(a, b: cint): uint8 {.cdecl.}
      let fn = cast[IntIntUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type IntIntUCharProc = proc(a, b: cint): uint8 {.cdecl.}
      let fn = cast[IntIntUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type IntIntInt64Proc = proc(a, b: cint): int64 {.cdecl.}
      let fn = cast[IntIntInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type IntIntUInt64Proc = proc(a, b: cint): uint64 {.cdecl.}
      let fn = cast[IntIntUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type IntIntSizeProc = proc(a, b: cint): csize_t {.cdecl.}
      let fn = cast[IntIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type IntIntPtrDiffProc = proc(a, b: cint): GeneCPtrDiff {.cdecl.}
      let fn = cast[IntIntPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type IntIntFloatProc = proc(a, b: cint): cfloat {.cdecl.}
      let fn = cast[IntIntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type IntIntDoubleProc = proc(a, b: cint): cdouble {.cdecl.}
      let fn = cast[IntIntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type IntIntBoolProc = proc(a, b: cint): bool {.cdecl.}
      let fn = cast[IntIntBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type IntIntCStrProc = proc(a, b: cint): cstring {.cdecl.}
      let fn = cast[IntIntCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
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
  if paramLabels.len == 2 and paramLabels[0] == "C/Int" and
      paramLabels[1] == "C/Double":
    let arg0 = ffiCIntArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCDoubleArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type IntDoubleIntProc = proc(a: cint, b: cdouble): cint {.cdecl.}
      let fn = cast[IntDoubleIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt":
      type IntDoubleUIntProc = proc(a: cint, b: cdouble): cuint {.cdecl.}
      let fn = cast[IntDoubleUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type IntDoubleInt32Proc = proc(a: cint, b: cdouble): int32 {.cdecl.}
      let fn = cast[IntDoubleInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type IntDoubleInt16Proc = proc(a: cint, b: cdouble): int16 {.cdecl.}
      let fn = cast[IntDoubleInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type IntDoubleShortProc = proc(a: cint, b: cdouble): cshort {.cdecl.}
      let fn = cast[IntDoubleShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type IntDoubleInt8Proc = proc(a: cint, b: cdouble): int8 {.cdecl.}
      let fn = cast[IntDoubleInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type IntDoubleCharProc = proc(a: cint, b: cdouble): cchar {.cdecl.}
      let fn = cast[IntDoubleCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type IntDoubleLongProc = proc(a: cint, b: cdouble): clong {.cdecl.}
      let fn = cast[IntDoubleLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type IntDoubleULongProc = proc(a: cint, b: cdouble): culong {.cdecl.}
      let fn = cast[IntDoubleULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type IntDoubleUInt32Proc = proc(a: cint, b: cdouble): uint32 {.cdecl.}
      let fn = cast[IntDoubleUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type IntDoubleUInt16Proc = proc(a: cint, b: cdouble): uint16 {.cdecl.}
      let fn = cast[IntDoubleUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type IntDoubleUShortProc = proc(a: cint, b: cdouble): cushort {.cdecl.}
      let fn = cast[IntDoubleUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type IntDoubleUInt8Proc = proc(a: cint, b: cdouble): uint8 {.cdecl.}
      let fn = cast[IntDoubleUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type IntDoubleUCharProc = proc(a: cint, b: cdouble): uint8 {.cdecl.}
      let fn = cast[IntDoubleUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type IntDoubleInt64Proc = proc(a: cint, b: cdouble): int64 {.cdecl.}
      let fn = cast[IntDoubleInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type IntDoubleUInt64Proc = proc(a: cint, b: cdouble): uint64 {.cdecl.}
      let fn = cast[IntDoubleUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type IntDoubleSizeProc = proc(a: cint, b: cdouble): csize_t {.cdecl.}
      let fn = cast[IntDoubleSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type IntDoublePtrDiffProc = proc(a: cint, b: cdouble): GeneCPtrDiff {.cdecl.}
      let fn = cast[IntDoublePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type IntDoubleFloatProc = proc(a: cint, b: cdouble): cfloat {.cdecl.}
      let fn = cast[IntDoubleFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type IntDoubleDoubleProc = proc(a: cint, b: cdouble): cdouble {.cdecl.}
      let fn = cast[IntDoubleDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type IntDoubleBoolProc = proc(a: cint, b: cdouble): bool {.cdecl.}
      let fn = cast[IntDoubleBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type IntDoubleCStrProc = proc(a: cint, b: cdouble): cstring {.cdecl.}
      let fn = cast[IntDoubleCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type IntDoubleVoidProc = proc(a: cint, b: cdouble) {.cdecl.}
      let fn = cast[IntDoubleVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type IntDoublePtrProc = proc(a: cint, b: cdouble): pointer {.cdecl.}
        let fn = cast[IntDoublePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/Int" and
      paramLabels[1] == "C/Float":
    let arg0 = ffiCIntArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCFloatArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type IntFloatIntProc = proc(a: cint, b: cfloat): cint {.cdecl.}
      let fn = cast[IntFloatIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt":
      type IntFloatUIntProc = proc(a: cint, b: cfloat): cuint {.cdecl.}
      let fn = cast[IntFloatUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type IntFloatInt32Proc = proc(a: cint, b: cfloat): int32 {.cdecl.}
      let fn = cast[IntFloatInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type IntFloatInt16Proc = proc(a: cint, b: cfloat): int16 {.cdecl.}
      let fn = cast[IntFloatInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type IntFloatShortProc = proc(a: cint, b: cfloat): cshort {.cdecl.}
      let fn = cast[IntFloatShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type IntFloatInt8Proc = proc(a: cint, b: cfloat): int8 {.cdecl.}
      let fn = cast[IntFloatInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type IntFloatCharProc = proc(a: cint, b: cfloat): cchar {.cdecl.}
      let fn = cast[IntFloatCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type IntFloatLongProc = proc(a: cint, b: cfloat): clong {.cdecl.}
      let fn = cast[IntFloatLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type IntFloatULongProc = proc(a: cint, b: cfloat): culong {.cdecl.}
      let fn = cast[IntFloatULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type IntFloatUInt32Proc = proc(a: cint, b: cfloat): uint32 {.cdecl.}
      let fn = cast[IntFloatUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type IntFloatUInt16Proc = proc(a: cint, b: cfloat): uint16 {.cdecl.}
      let fn = cast[IntFloatUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type IntFloatUShortProc = proc(a: cint, b: cfloat): cushort {.cdecl.}
      let fn = cast[IntFloatUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type IntFloatUInt8Proc = proc(a: cint, b: cfloat): uint8 {.cdecl.}
      let fn = cast[IntFloatUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type IntFloatUCharProc = proc(a: cint, b: cfloat): uint8 {.cdecl.}
      let fn = cast[IntFloatUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type IntFloatInt64Proc = proc(a: cint, b: cfloat): int64 {.cdecl.}
      let fn = cast[IntFloatInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type IntFloatUInt64Proc = proc(a: cint, b: cfloat): uint64 {.cdecl.}
      let fn = cast[IntFloatUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type IntFloatSizeProc = proc(a: cint, b: cfloat): csize_t {.cdecl.}
      let fn = cast[IntFloatSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type IntFloatPtrDiffProc = proc(a: cint, b: cfloat): GeneCPtrDiff {.cdecl.}
      let fn = cast[IntFloatPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type IntFloatFloatProc = proc(a: cint, b: cfloat): cfloat {.cdecl.}
      let fn = cast[IntFloatFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type IntFloatDoubleProc = proc(a: cint, b: cfloat): cdouble {.cdecl.}
      let fn = cast[IntFloatDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type IntFloatBoolProc = proc(a: cint, b: cfloat): bool {.cdecl.}
      let fn = cast[IntFloatBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type IntFloatCStrProc = proc(a: cint, b: cfloat): cstring {.cdecl.}
      let fn = cast[IntFloatCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type IntFloatVoidProc = proc(a: cint, b: cfloat) {.cdecl.}
      let fn = cast[IntFloatVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type IntFloatPtrProc = proc(a: cint, b: cfloat): pointer {.cdecl.}
        let fn = cast[IntFloatPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/Double" and
      paramLabels[1] == "C/Double":
    let arg0 = ffiCDoubleArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCDoubleArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type DoubleDoubleIntProc = proc(a, b: cdouble): cint {.cdecl.}
      let fn = cast[DoubleDoubleIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt":
      type DoubleDoubleUIntProc = proc(a, b: cdouble): cuint {.cdecl.}
      let fn = cast[DoubleDoubleUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type DoubleDoubleInt32Proc = proc(a, b: cdouble): int32 {.cdecl.}
      let fn = cast[DoubleDoubleInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type DoubleDoubleInt16Proc = proc(a, b: cdouble): int16 {.cdecl.}
      let fn = cast[DoubleDoubleInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type DoubleDoubleShortProc = proc(a, b: cdouble): cshort {.cdecl.}
      let fn = cast[DoubleDoubleShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type DoubleDoubleInt8Proc = proc(a, b: cdouble): int8 {.cdecl.}
      let fn = cast[DoubleDoubleInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type DoubleDoubleCharProc = proc(a, b: cdouble): cchar {.cdecl.}
      let fn = cast[DoubleDoubleCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type DoubleDoubleLongProc = proc(a, b: cdouble): clong {.cdecl.}
      let fn = cast[DoubleDoubleLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type DoubleDoubleULongProc = proc(a, b: cdouble): culong {.cdecl.}
      let fn = cast[DoubleDoubleULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type DoubleDoubleUInt32Proc = proc(a, b: cdouble): uint32 {.cdecl.}
      let fn = cast[DoubleDoubleUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type DoubleDoubleUInt16Proc = proc(a, b: cdouble): uint16 {.cdecl.}
      let fn = cast[DoubleDoubleUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type DoubleDoubleUShortProc = proc(a, b: cdouble): cushort {.cdecl.}
      let fn = cast[DoubleDoubleUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type DoubleDoubleUInt8Proc = proc(a, b: cdouble): uint8 {.cdecl.}
      let fn = cast[DoubleDoubleUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type DoubleDoubleUCharProc = proc(a, b: cdouble): uint8 {.cdecl.}
      let fn = cast[DoubleDoubleUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type DoubleDoubleInt64Proc = proc(a, b: cdouble): int64 {.cdecl.}
      let fn = cast[DoubleDoubleInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type DoubleDoubleUInt64Proc = proc(a, b: cdouble): uint64 {.cdecl.}
      let fn = cast[DoubleDoubleUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type DoubleDoubleSizeProc = proc(a, b: cdouble): csize_t {.cdecl.}
      let fn = cast[DoubleDoubleSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type DoubleDoublePtrDiffProc = proc(a, b: cdouble): GeneCPtrDiff {.cdecl.}
      let fn = cast[DoubleDoublePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type DoubleDoubleFloatProc = proc(a, b: cdouble): cfloat {.cdecl.}
      let fn = cast[DoubleDoubleFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type DoubleDoubleDoubleProc = proc(a, b: cdouble): cdouble {.cdecl.}
      let fn = cast[DoubleDoubleDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type DoubleDoubleBoolProc = proc(a, b: cdouble): bool {.cdecl.}
      let fn = cast[DoubleDoubleBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type DoubleDoubleCStrProc = proc(a, b: cdouble): cstring {.cdecl.}
      let fn = cast[DoubleDoubleCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type DoubleDoubleVoidProc = proc(a, b: cdouble) {.cdecl.}
      let fn = cast[DoubleDoubleVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type DoubleDoublePtrProc = proc(a, b: cdouble): pointer {.cdecl.}
        let fn = cast[DoubleDoublePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/Double" and
      paramLabels[1] == "C/Int":
    let arg0 = ffiCDoubleArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCIntArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type DoubleIntIntProc = proc(a: cdouble, b: cint): cint {.cdecl.}
      let fn = cast[DoubleIntIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt":
      type DoubleIntUIntProc = proc(a: cdouble, b: cint): cuint {.cdecl.}
      let fn = cast[DoubleIntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type DoubleIntInt32Proc = proc(a: cdouble, b: cint): int32 {.cdecl.}
      let fn = cast[DoubleIntInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type DoubleIntInt16Proc = proc(a: cdouble, b: cint): int16 {.cdecl.}
      let fn = cast[DoubleIntInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type DoubleIntShortProc = proc(a: cdouble, b: cint): cshort {.cdecl.}
      let fn = cast[DoubleIntShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type DoubleIntInt8Proc = proc(a: cdouble, b: cint): int8 {.cdecl.}
      let fn = cast[DoubleIntInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type DoubleIntCharProc = proc(a: cdouble, b: cint): cchar {.cdecl.}
      let fn = cast[DoubleIntCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type DoubleIntLongProc = proc(a: cdouble, b: cint): clong {.cdecl.}
      let fn = cast[DoubleIntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type DoubleIntULongProc = proc(a: cdouble, b: cint): culong {.cdecl.}
      let fn = cast[DoubleIntULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type DoubleIntUInt32Proc = proc(a: cdouble, b: cint): uint32 {.cdecl.}
      let fn = cast[DoubleIntUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type DoubleIntUInt16Proc = proc(a: cdouble, b: cint): uint16 {.cdecl.}
      let fn = cast[DoubleIntUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type DoubleIntUShortProc = proc(a: cdouble, b: cint): cushort {.cdecl.}
      let fn = cast[DoubleIntUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type DoubleIntUInt8Proc = proc(a: cdouble, b: cint): uint8 {.cdecl.}
      let fn = cast[DoubleIntUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type DoubleIntUCharProc = proc(a: cdouble, b: cint): uint8 {.cdecl.}
      let fn = cast[DoubleIntUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type DoubleIntInt64Proc = proc(a: cdouble, b: cint): int64 {.cdecl.}
      let fn = cast[DoubleIntInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type DoubleIntUInt64Proc = proc(a: cdouble, b: cint): uint64 {.cdecl.}
      let fn = cast[DoubleIntUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type DoubleIntSizeProc = proc(a: cdouble, b: cint): csize_t {.cdecl.}
      let fn = cast[DoubleIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type DoubleIntPtrDiffProc = proc(a: cdouble, b: cint): GeneCPtrDiff {.cdecl.}
      let fn = cast[DoubleIntPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type DoubleIntFloatProc = proc(a: cdouble, b: cint): cfloat {.cdecl.}
      let fn = cast[DoubleIntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type DoubleIntDoubleProc = proc(a: cdouble, b: cint): cdouble {.cdecl.}
      let fn = cast[DoubleIntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type DoubleIntBoolProc = proc(a: cdouble, b: cint): bool {.cdecl.}
      let fn = cast[DoubleIntBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type DoubleIntCStrProc = proc(a: cdouble, b: cint): cstring {.cdecl.}
      let fn = cast[DoubleIntCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type DoubleIntVoidProc = proc(a: cdouble, b: cint) {.cdecl.}
      let fn = cast[DoubleIntVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type DoubleIntPtrProc = proc(a: cdouble, b: cint): pointer {.cdecl.}
        let fn = cast[DoubleIntPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/Float" and
      paramLabels[1] == "C/Float":
    let arg0 = ffiCFloatArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCFloatArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type FloatFloatIntProc = proc(a, b: cfloat): cint {.cdecl.}
      let fn = cast[FloatFloatIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt":
      type FloatFloatUIntProc = proc(a, b: cfloat): cuint {.cdecl.}
      let fn = cast[FloatFloatUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type FloatFloatInt32Proc = proc(a, b: cfloat): int32 {.cdecl.}
      let fn = cast[FloatFloatInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type FloatFloatInt16Proc = proc(a, b: cfloat): int16 {.cdecl.}
      let fn = cast[FloatFloatInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type FloatFloatShortProc = proc(a, b: cfloat): cshort {.cdecl.}
      let fn = cast[FloatFloatShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type FloatFloatInt8Proc = proc(a, b: cfloat): int8 {.cdecl.}
      let fn = cast[FloatFloatInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type FloatFloatCharProc = proc(a, b: cfloat): cchar {.cdecl.}
      let fn = cast[FloatFloatCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type FloatFloatLongProc = proc(a, b: cfloat): clong {.cdecl.}
      let fn = cast[FloatFloatLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type FloatFloatULongProc = proc(a, b: cfloat): culong {.cdecl.}
      let fn = cast[FloatFloatULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type FloatFloatUInt32Proc = proc(a, b: cfloat): uint32 {.cdecl.}
      let fn = cast[FloatFloatUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type FloatFloatUInt16Proc = proc(a, b: cfloat): uint16 {.cdecl.}
      let fn = cast[FloatFloatUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type FloatFloatUShortProc = proc(a, b: cfloat): cushort {.cdecl.}
      let fn = cast[FloatFloatUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type FloatFloatUInt8Proc = proc(a, b: cfloat): uint8 {.cdecl.}
      let fn = cast[FloatFloatUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type FloatFloatUCharProc = proc(a, b: cfloat): uint8 {.cdecl.}
      let fn = cast[FloatFloatUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type FloatFloatInt64Proc = proc(a, b: cfloat): int64 {.cdecl.}
      let fn = cast[FloatFloatInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type FloatFloatUInt64Proc = proc(a, b: cfloat): uint64 {.cdecl.}
      let fn = cast[FloatFloatUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type FloatFloatSizeProc = proc(a, b: cfloat): csize_t {.cdecl.}
      let fn = cast[FloatFloatSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type FloatFloatPtrDiffProc = proc(a, b: cfloat): GeneCPtrDiff {.cdecl.}
      let fn = cast[FloatFloatPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type FloatFloatFloatProc = proc(a, b: cfloat): cfloat {.cdecl.}
      let fn = cast[FloatFloatFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type FloatFloatDoubleProc = proc(a, b: cfloat): cdouble {.cdecl.}
      let fn = cast[FloatFloatDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type FloatFloatBoolProc = proc(a, b: cfloat): bool {.cdecl.}
      let fn = cast[FloatFloatBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type FloatFloatCStrProc = proc(a, b: cfloat): cstring {.cdecl.}
      let fn = cast[FloatFloatCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type FloatFloatVoidProc = proc(a, b: cfloat) {.cdecl.}
      let fn = cast[FloatFloatVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type FloatFloatPtrProc = proc(a, b: cfloat): pointer {.cdecl.}
        let fn = cast[FloatFloatPtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and paramLabels[0] == "C/Float" and
      paramLabels[1] == "C/Int":
    let arg0 = ffiCFloatArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", args[0])
    let arg1 = ffiCIntArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type FloatIntIntProc = proc(a: cfloat, b: cint): cint {.cdecl.}
      let fn = cast[FloatIntIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt":
      type FloatIntUIntProc = proc(a: cfloat, b: cint): cuint {.cdecl.}
      let fn = cast[FloatIntUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type FloatIntInt32Proc = proc(a: cfloat, b: cint): int32 {.cdecl.}
      let fn = cast[FloatIntInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type FloatIntInt16Proc = proc(a: cfloat, b: cint): int16 {.cdecl.}
      let fn = cast[FloatIntInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type FloatIntShortProc = proc(a: cfloat, b: cint): cshort {.cdecl.}
      let fn = cast[FloatIntShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type FloatIntInt8Proc = proc(a: cfloat, b: cint): int8 {.cdecl.}
      let fn = cast[FloatIntInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type FloatIntCharProc = proc(a: cfloat, b: cint): cchar {.cdecl.}
      let fn = cast[FloatIntCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type FloatIntLongProc = proc(a: cfloat, b: cint): clong {.cdecl.}
      let fn = cast[FloatIntLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type FloatIntULongProc = proc(a: cfloat, b: cint): culong {.cdecl.}
      let fn = cast[FloatIntULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type FloatIntUInt32Proc = proc(a: cfloat, b: cint): uint32 {.cdecl.}
      let fn = cast[FloatIntUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type FloatIntUInt16Proc = proc(a: cfloat, b: cint): uint16 {.cdecl.}
      let fn = cast[FloatIntUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type FloatIntUShortProc = proc(a: cfloat, b: cint): cushort {.cdecl.}
      let fn = cast[FloatIntUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type FloatIntUInt8Proc = proc(a: cfloat, b: cint): uint8 {.cdecl.}
      let fn = cast[FloatIntUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type FloatIntUCharProc = proc(a: cfloat, b: cint): uint8 {.cdecl.}
      let fn = cast[FloatIntUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type FloatIntInt64Proc = proc(a: cfloat, b: cint): int64 {.cdecl.}
      let fn = cast[FloatIntInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type FloatIntUInt64Proc = proc(a: cfloat, b: cint): uint64 {.cdecl.}
      let fn = cast[FloatIntUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type FloatIntSizeProc = proc(a: cfloat, b: cint): csize_t {.cdecl.}
      let fn = cast[FloatIntSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type FloatIntPtrDiffProc = proc(a: cfloat, b: cint): GeneCPtrDiff {.cdecl.}
      let fn = cast[FloatIntPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type FloatIntFloatProc = proc(a: cfloat, b: cint): cfloat {.cdecl.}
      let fn = cast[FloatIntFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type FloatIntDoubleProc = proc(a: cfloat, b: cint): cdouble {.cdecl.}
      let fn = cast[FloatIntDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type FloatIntBoolProc = proc(a: cfloat, b: cint): bool {.cdecl.}
      let fn = cast[FloatIntBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type FloatIntCStrProc = proc(a: cfloat, b: cint): cstring {.cdecl.}
      let fn = cast[FloatIntCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type FloatIntVoidProc = proc(a: cfloat, b: cint) {.cdecl.}
      let fn = cast[FloatIntVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type FloatIntPtrProc = proc(a: cfloat, b: cint): pointer {.cdecl.}
        let fn = cast[FloatIntPtrProc](callee.ffiCallableAddress)
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
    of "C/UInt":
      type SizeSizeUIntProc = proc(a, b: csize_t): cuint {.cdecl.}
      let fn = cast[SizeSizeUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type SizeSizeInt32Proc = proc(a, b: csize_t): int32 {.cdecl.}
      let fn = cast[SizeSizeInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type SizeSizeInt16Proc = proc(a, b: csize_t): int16 {.cdecl.}
      let fn = cast[SizeSizeInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type SizeSizeShortProc = proc(a, b: csize_t): cshort {.cdecl.}
      let fn = cast[SizeSizeShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type SizeSizeInt8Proc = proc(a, b: csize_t): int8 {.cdecl.}
      let fn = cast[SizeSizeInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type SizeSizeCharProc = proc(a, b: csize_t): cchar {.cdecl.}
      let fn = cast[SizeSizeCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/Long":
      type SizeSizeLongProc = proc(a, b: csize_t): clong {.cdecl.}
      let fn = cast[SizeSizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type SizeSizeULongProc = proc(a, b: csize_t): culong {.cdecl.}
      let fn = cast[SizeSizeULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/UInt32":
      type SizeSizeUInt32Proc = proc(a, b: csize_t): uint32 {.cdecl.}
      let fn = cast[SizeSizeUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type SizeSizeUInt16Proc = proc(a, b: csize_t): uint16 {.cdecl.}
      let fn = cast[SizeSizeUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type SizeSizeUShortProc = proc(a, b: csize_t): cushort {.cdecl.}
      let fn = cast[SizeSizeUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type SizeSizeUInt8Proc = proc(a, b: csize_t): uint8 {.cdecl.}
      let fn = cast[SizeSizeUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type SizeSizeUCharProc = proc(a, b: csize_t): uint8 {.cdecl.}
      let fn = cast[SizeSizeUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int64":
      type SizeSizeInt64Proc = proc(a, b: csize_t): int64 {.cdecl.}
      let fn = cast[SizeSizeInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type SizeSizeUInt64Proc = proc(a, b: csize_t): uint64 {.cdecl.}
      let fn = cast[SizeSizeUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type SizeSizeSizeProc = proc(a, b: csize_t): csize_t {.cdecl.}
      let fn = cast[SizeSizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type SizeSizePtrDiffProc = proc(a, b: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[SizeSizePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type SizeSizeFloatProc = proc(a, b: csize_t): cfloat {.cdecl.}
      let fn = cast[SizeSizeFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type SizeSizeDoubleProc = proc(a, b: csize_t): cdouble {.cdecl.}
      let fn = cast[SizeSizeDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type SizeSizeBoolProc = proc(a, b: csize_t): bool {.cdecl.}
      let fn = cast[SizeSizeBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
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
  if paramLabels.len == 2 and isFfiPtrLabel(paramLabels[0]) and
      paramLabels[1] == "C/Size":
    let arg0 = ffiPointerArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    let arg1 = ffiCSizeArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", args[1])
    case returnLabel
    of "C/Int":
      type PtrSizeIntProc = proc(p: pointer, n: csize_t): cint {.cdecl.}
      let fn = cast[PtrSizeIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type PtrSizeInt32Proc = proc(p: pointer, n: csize_t): int32 {.cdecl.}
      let fn = cast[PtrSizeInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type PtrSizeInt16Proc = proc(p: pointer, n: csize_t): int16 {.cdecl.}
      let fn = cast[PtrSizeInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type PtrSizeShortProc = proc(p: pointer, n: csize_t): cshort {.cdecl.}
      let fn = cast[PtrSizeShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type PtrSizeInt8Proc = proc(p: pointer, n: csize_t): int8 {.cdecl.}
      let fn = cast[PtrSizeInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type PtrSizeCharProc = proc(p: pointer, n: csize_t): cchar {.cdecl.}
      let fn = cast[PtrSizeCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/UInt":
      type PtrSizeUIntProc = proc(p: pointer, n: csize_t): cuint {.cdecl.}
      let fn = cast[PtrSizeUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt32":
      type PtrSizeUInt32Proc = proc(p: pointer, n: csize_t): uint32 {.cdecl.}
      let fn = cast[PtrSizeUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type PtrSizeUInt16Proc = proc(p: pointer, n: csize_t): uint16 {.cdecl.}
      let fn = cast[PtrSizeUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type PtrSizeUShortProc = proc(p: pointer, n: csize_t): cushort {.cdecl.}
      let fn = cast[PtrSizeUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type PtrSizeUInt8Proc = proc(p: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[PtrSizeUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type PtrSizeUCharProc = proc(p: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[PtrSizeUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Long":
      type PtrSizeLongProc = proc(p: pointer, n: csize_t): clong {.cdecl.}
      let fn = cast[PtrSizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type PtrSizeULongProc = proc(p: pointer, n: csize_t): culong {.cdecl.}
      let fn = cast[PtrSizeULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/Int64":
      type PtrSizeInt64Proc = proc(p: pointer, n: csize_t): int64 {.cdecl.}
      let fn = cast[PtrSizeInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type PtrSizeUInt64Proc = proc(p: pointer, n: csize_t): uint64 {.cdecl.}
      let fn = cast[PtrSizeUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type PtrSizeSizeProc = proc(p: pointer, n: csize_t): csize_t {.cdecl.}
      let fn = cast[PtrSizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type PtrSizePtrDiffProc = proc(p: pointer, n: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[PtrSizePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type PtrSizeFloatProc = proc(p: pointer, n: csize_t): cfloat {.cdecl.}
      let fn = cast[PtrSizeFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type PtrSizeDoubleProc = proc(p: pointer, n: csize_t): cdouble {.cdecl.}
      let fn = cast[PtrSizeDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type PtrSizeBoolProc = proc(p: pointer, n: csize_t): bool {.cdecl.}
      let fn = cast[PtrSizeBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type PtrSizeCStrProc = proc(p: pointer, n: csize_t): cstring {.cdecl.}
      let fn = cast[PtrSizeCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type PtrSizeVoidProc = proc(p: pointer, n: csize_t) {.cdecl.}
      let fn = cast[PtrSizeVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type PtrSizePtrProc = proc(p: pointer, n: csize_t): pointer {.cdecl.}
        let fn = cast[PtrSizePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1), releaseAddress)
  if paramLabels.len == 2 and isFfiPtrLabel(paramLabels[0]) and
      isFfiPtrLabel(paramLabels[1]):
    let arg0 = ffiPointerArg("FFI argument 0 for '" &
      callee.ffiCallableName & "'", paramLabels[0], params[0], args[0])
    let arg1 = ffiPointerArg("FFI argument 1 for '" &
      callee.ffiCallableName & "'", paramLabels[1], params[1], args[1])
    case returnLabel
    of "C/Int":
      type PtrPtrIntProc = proc(a, b: pointer): cint {.cdecl.}
      let fn = cast[PtrPtrIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int32":
      type PtrPtrInt32Proc = proc(a, b: pointer): int32 {.cdecl.}
      let fn = cast[PtrPtrInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int16":
      type PtrPtrInt16Proc = proc(a, b: pointer): int16 {.cdecl.}
      let fn = cast[PtrPtrInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Short":
      type PtrPtrShortProc = proc(a, b: pointer): cshort {.cdecl.}
      let fn = cast[PtrPtrShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Int8":
      type PtrPtrInt8Proc = proc(a, b: pointer): int8 {.cdecl.}
      let fn = cast[PtrPtrInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Char":
      type PtrPtrCharProc = proc(a, b: pointer): cchar {.cdecl.}
      let fn = cast[PtrPtrCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1))
    of "C/UInt":
      type PtrPtrUIntProc = proc(a, b: pointer): cuint {.cdecl.}
      let fn = cast[PtrPtrUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt32":
      type PtrPtrUInt32Proc = proc(a, b: pointer): uint32 {.cdecl.}
      let fn = cast[PtrPtrUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt16":
      type PtrPtrUInt16Proc = proc(a, b: pointer): uint16 {.cdecl.}
      let fn = cast[PtrPtrUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UShort":
      type PtrPtrUShortProc = proc(a, b: pointer): cushort {.cdecl.}
      let fn = cast[PtrPtrUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UInt8":
      type PtrPtrUInt8Proc = proc(a, b: pointer): uint8 {.cdecl.}
      let fn = cast[PtrPtrUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/UChar":
      type PtrPtrUCharProc = proc(a, b: pointer): uint8 {.cdecl.}
      let fn = cast[PtrPtrUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Long":
      type PtrPtrLongProc = proc(a, b: pointer): clong {.cdecl.}
      let fn = cast[PtrPtrLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/ULong":
      type PtrPtrULongProc = proc(a, b: pointer): culong {.cdecl.}
      let fn = cast[PtrPtrULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/Int64":
      type PtrPtrInt64Proc = proc(a, b: pointer): int64 {.cdecl.}
      let fn = cast[PtrPtrInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1))
    of "C/UInt64":
      type PtrPtrUInt64Proc = proc(a, b: pointer): uint64 {.cdecl.}
      let fn = cast[PtrPtrUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1))
    of "C/Size":
      type PtrPtrSizeProc = proc(a, b: pointer): csize_t {.cdecl.}
      let fn = cast[PtrPtrSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1)))
    of "C/PtrDiff":
      type PtrPtrPtrDiffProc = proc(a, b: pointer): GeneCPtrDiff {.cdecl.}
      let fn = cast[PtrPtrPtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1)))
    of "C/Float":
      type PtrPtrFloatProc = proc(a, b: pointer): cfloat {.cdecl.}
      let fn = cast[PtrPtrFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Double":
      type PtrPtrDoubleProc = proc(a, b: pointer): cdouble {.cdecl.}
      let fn = cast[PtrPtrDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1)))
    of "C/Bool":
      type PtrPtrBoolProc = proc(a, b: pointer): bool {.cdecl.}
      let fn = cast[PtrPtrBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1))
    of "C/CStr":
      type PtrPtrCStrProc = proc(a, b: pointer): cstring {.cdecl.}
      let fn = cast[PtrPtrCStrProc](callee.ffiCallableAddress)
      return ffiCStrResult("FFI result for '" & callee.ffiCallableName & "'",
                           fn(arg0, arg1))
    of "C/Void":
      type PtrPtrVoidProc = proc(a, b: pointer) {.cdecl.}
      let fn = cast[PtrPtrVoidProc](callee.ffiCallableAddress)
      fn(arg0, arg1)
      return NIL
    else:
      if isFfiPtrLabel(returnLabel):
        type PtrPtrPtrProc = proc(a, b: pointer): pointer {.cdecl.}
        let fn = cast[PtrPtrPtrProc](callee.ffiCallableAddress)
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
    of "C/Int32":
      type PtrIntSizeInt32Proc = proc(p: pointer, x: cint, n: csize_t): int32 {.cdecl.}
      let fn = cast[PtrIntSizeInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Int16":
      type PtrIntSizeInt16Proc = proc(p: pointer, x: cint, n: csize_t): int16 {.cdecl.}
      let fn = cast[PtrIntSizeInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Short":
      type PtrIntSizeShortProc = proc(p: pointer, x: cint, n: csize_t): cshort {.cdecl.}
      let fn = cast[PtrIntSizeShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Int8":
      type PtrIntSizeInt8Proc = proc(p: pointer, x: cint, n: csize_t): int8 {.cdecl.}
      let fn = cast[PtrIntSizeInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Char":
      type PtrIntSizeCharProc = proc(p: pointer, x: cint, n: csize_t): cchar {.cdecl.}
      let fn = cast[PtrIntSizeCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1, arg2))
    of "C/UInt":
      type PtrIntSizeUIntProc = proc(p: pointer, x: cint, n: csize_t): cuint {.cdecl.}
      let fn = cast[PtrIntSizeUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UInt32":
      type PtrIntSizeUInt32Proc = proc(p: pointer, x: cint, n: csize_t): uint32 {.cdecl.}
      let fn = cast[PtrIntSizeUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UInt16":
      type PtrIntSizeUInt16Proc = proc(p: pointer, x: cint, n: csize_t): uint16 {.cdecl.}
      let fn = cast[PtrIntSizeUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UShort":
      type PtrIntSizeUShortProc = proc(p: pointer, x: cint, n: csize_t): cushort {.cdecl.}
      let fn = cast[PtrIntSizeUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UInt8":
      type PtrIntSizeUInt8Proc = proc(p: pointer, x: cint, n: csize_t): uint8 {.cdecl.}
      let fn = cast[PtrIntSizeUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UChar":
      type PtrIntSizeUCharProc = proc(p: pointer, x: cint, n: csize_t): uint8 {.cdecl.}
      let fn = cast[PtrIntSizeUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Long":
      type PtrIntSizeLongProc = proc(p: pointer, x: cint, n: csize_t): clong {.cdecl.}
      let fn = cast[PtrIntSizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/ULong":
      type PtrIntSizeULongProc = proc(p: pointer, x: cint, n: csize_t): culong {.cdecl.}
      let fn = cast[PtrIntSizeULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1, arg2)))
    of "C/Int64":
      type PtrIntSizeInt64Proc = proc(p: pointer, x: cint, n: csize_t): int64 {.cdecl.}
      let fn = cast[PtrIntSizeInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1, arg2))
    of "C/UInt64":
      type PtrIntSizeUInt64Proc = proc(p: pointer, x: cint, n: csize_t): uint64 {.cdecl.}
      let fn = cast[PtrIntSizeUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1, arg2))
    of "C/Size":
      type PtrIntSizeSizeProc = proc(p: pointer, x: cint, n: csize_t): csize_t {.cdecl.}
      let fn = cast[PtrIntSizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1, arg2)))
    of "C/PtrDiff":
      type PtrIntSizePtrDiffProc = proc(p: pointer, x: cint, n: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[PtrIntSizePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Float":
      type PtrIntSizeFloatProc = proc(p: pointer, x: cint, n: csize_t): cfloat {.cdecl.}
      let fn = cast[PtrIntSizeFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1, arg2)))
    of "C/Double":
      type PtrIntSizeDoubleProc = proc(p: pointer, x: cint, n: csize_t): cdouble {.cdecl.}
      let fn = cast[PtrIntSizeDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1, arg2)))
    of "C/Bool":
      type PtrIntSizeBoolProc = proc(p: pointer, x: cint, n: csize_t): bool {.cdecl.}
      let fn = cast[PtrIntSizeBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1, arg2))
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
    of "C/Int32":
      type PtrPtrSizeInt32Proc = proc(a, b: pointer, n: csize_t): int32 {.cdecl.}
      let fn = cast[PtrPtrSizeInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Int16":
      type PtrPtrSizeInt16Proc = proc(a, b: pointer, n: csize_t): int16 {.cdecl.}
      let fn = cast[PtrPtrSizeInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Short":
      type PtrPtrSizeShortProc = proc(a, b: pointer, n: csize_t): cshort {.cdecl.}
      let fn = cast[PtrPtrSizeShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Int8":
      type PtrPtrSizeInt8Proc = proc(a, b: pointer, n: csize_t): int8 {.cdecl.}
      let fn = cast[PtrPtrSizeInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Char":
      type PtrPtrSizeCharProc = proc(a, b: pointer, n: csize_t): cchar {.cdecl.}
      let fn = cast[PtrPtrSizeCharProc](callee.ffiCallableAddress)
      return ffiCCharResult(fn(arg0, arg1, arg2))
    of "C/UInt":
      type PtrPtrSizeUIntProc = proc(a, b: pointer, n: csize_t): cuint {.cdecl.}
      let fn = cast[PtrPtrSizeUIntProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UInt32":
      type PtrPtrSizeUInt32Proc = proc(a, b: pointer, n: csize_t): uint32 {.cdecl.}
      let fn = cast[PtrPtrSizeUInt32Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UInt16":
      type PtrPtrSizeUInt16Proc = proc(a, b: pointer, n: csize_t): uint16 {.cdecl.}
      let fn = cast[PtrPtrSizeUInt16Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UShort":
      type PtrPtrSizeUShortProc = proc(a, b: pointer, n: csize_t): cushort {.cdecl.}
      let fn = cast[PtrPtrSizeUShortProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UInt8":
      type PtrPtrSizeUInt8Proc = proc(a, b: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[PtrPtrSizeUInt8Proc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/UChar":
      type PtrPtrSizeUCharProc = proc(a, b: pointer, n: csize_t): uint8 {.cdecl.}
      let fn = cast[PtrPtrSizeUCharProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Long":
      type PtrPtrSizeLongProc = proc(a, b: pointer, n: csize_t): clong {.cdecl.}
      let fn = cast[PtrPtrSizeLongProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/ULong":
      type PtrPtrSizeULongProc = proc(a, b: pointer, n: csize_t): culong {.cdecl.}
      let fn = cast[PtrPtrSizeULongProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1, arg2)))
    of "C/Int64":
      type PtrPtrSizeInt64Proc = proc(a, b: pointer, n: csize_t): int64 {.cdecl.}
      let fn = cast[PtrPtrSizeInt64Proc](callee.ffiCallableAddress)
      return newInt(fn(arg0, arg1, arg2))
    of "C/UInt64":
      type PtrPtrSizeUInt64Proc = proc(a, b: pointer, n: csize_t): uint64 {.cdecl.}
      let fn = cast[PtrPtrSizeUInt64Proc](callee.ffiCallableAddress)
      return ffiCUInt64Value(fn(arg0, arg1, arg2))
    of "C/Size":
      type PtrPtrSizeSizeProc = proc(a, b: pointer, n: csize_t): csize_t {.cdecl.}
      let fn = cast[PtrPtrSizeSizeProc](callee.ffiCallableAddress)
      return ffiCUInt64Value(uint64(fn(arg0, arg1, arg2)))
    of "C/PtrDiff":
      type PtrPtrSizePtrDiffProc = proc(a, b: pointer, n: csize_t): GeneCPtrDiff {.cdecl.}
      let fn = cast[PtrPtrSizePtrDiffProc](callee.ffiCallableAddress)
      return newInt(int64(fn(arg0, arg1, arg2)))
    of "C/Float":
      type PtrPtrSizeFloatProc = proc(a, b: pointer, n: csize_t): cfloat {.cdecl.}
      let fn = cast[PtrPtrSizeFloatProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1, arg2)))
    of "C/Double":
      type PtrPtrSizeDoubleProc = proc(a, b: pointer, n: csize_t): cdouble {.cdecl.}
      let fn = cast[PtrPtrSizeDoubleProc](callee.ffiCallableAddress)
      return newFloat(float64(fn(arg0, arg1, arg2)))
    of "C/Bool":
      type PtrPtrSizeBoolProc = proc(a, b: pointer, n: csize_t): bool {.cdecl.}
      let fn = cast[PtrPtrSizeBoolProc](callee.ffiCallableAddress)
      return newBool(fn(arg0, arg1, arg2))
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
      if isFfiPtrLabel(returnLabel):
        type PtrPtrSizePtrProc = proc(a, b: pointer, n: csize_t): pointer {.cdecl.}
        let fn = cast[PtrPtrSizePtrProc](callee.ffiCallableAddress)
        return ffiPointerResult(returnLabel, fn(arg0, arg1, arg2),
                                releaseAddress)
  raise newException(GeneError,
    "unsupported dynamic FFI signature for '" & callee.ffiCallableName &
    "': [" & paramLabels.join(",") & "] -> " & returnLabel)

proc callNamedMap(named: NamedArgs): Value =
  var entries = initPropTable()
  for i, name in named.names:
    let value = named.valueAt(i)
    if value.kind != vkVoid:
      entries[name] = value
  newMap(entries)

proc callEnvelope(scope: Scope, args: openArray[Value], named: NamedArgs,
                  site: Value = NIL): Value =
  var props = initPropTable()
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

proc isEnumTypeParam(enumType, typeExpr: Value): bool =
  if typeExpr.kind != vkSymbol or not enumType.isEnumType:
    return false
  for name in enumType.enumTypeParams:
    if name == typeExpr.symVal:
      return true
  false

proc constructEnumVariant(variant: Value, args: openArray[Value],
                          named: NamedArgs): Value =
  if named.len != 0:
    raise newException(GeneError,
      variant.enumVariantEnum.typeName & "/" & variant.enumVariantName &
      " does not accept named arguments")
  let payloadTypes = variant.enumVariantPayloadTypes
  if args.len != payloadTypes.len:
    raise newException(GeneError,
      variant.enumVariantEnum.typeName & "/" & variant.enumVariantName &
      " expects " & $payloadTypes.len & " payload item(s), got " & $args.len)
  if payloadTypes.len == 0:
    return variant
  let enumType = variant.enumVariantEnum
  let enumScope = enumType.typeScope
  var body: seq[Value]
  for i, payloadType in payloadTypes:
    if enumType.isEnumTypeParam(payloadType):
      body.add args[i]
    else:
      body.add adaptBoundary("payload " & $i & " for " &
                             enumType.typeName & "/" &
                             variant.enumVariantName,
                             payloadType, args[i], enumScope)
  newNode(variant, body = body)

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
  # fn! binds caller_env and syntax_call as implicit leading parameters;
  # arity diagnostics must count only the user-visible syntax parameters.
  let implicit = if proto.isSyntaxFn: 2 else: 0
  template arityHead(): string =
    (if proto.isSyntaxFn: "fn! '" else: "function '") & callee.fnName &
    "' expects "
  template arityUnit(): string =
    (if proto.isSyntaxFn: " syntax argument(s), got "
     else: " argument(s), got ")
  if proto.restParam.len == 0:
    if args.len < requiredPositional or args.len > positional.len:
      raise newException(GeneError,
        arityHead() & $max(0, requiredPositional - implicit) &
        ".." & $max(0, positional.len - implicit) &
        arityUnit() & $max(0, args.len - implicit))
  elif args.len < positional.len:
    raise newException(GeneError,
      arityHead() & "at least " & $max(0, positional.len - implicit) &
      arityUnit() & $max(0, args.len - implicit))
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
  callScope.seedFunctionProtocolEntry(callee)
  if proto.isSyntaxFn and args.len > 0 and args[0].kind == vkCallerEnv:
    # Any child/eval scope and closure created during this syntax call inherits
    # the marker. Escape checks can therefore reject authority captured
    # indirectly through a closure, without scanning the whole scope graph.
    callScope.borrowedCallerEnv = true
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
      rejectCallerEnvEscape("rest parameter '" & proto.restParam & "'", rest[i])
      if proto.restType.kind != vkNil:
        rest[i] = adaptBoundary("rest parameter '" & proto.restParam & "'",
                                proto.restType, rest[i], callScope)
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

proc applyFunctionCall(callee: Value, args: openArray[Value], named: NamedArgs,
                       proto: FunctionProto): Value =
  let positional = callee.fnParams
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
    callScope.seedFunctionProtocolEntry(callee)
    try:
      return runPooled(proto.chunk, callScope,
                       validateImplRequirements = proto.frameNeedsImplValidation)
    finally:
      if proto.poolCallScope:
        releaseCallScope(callScope)
  var callScope: Scope
  var returnType: Value
  if named.len > 0 and proto.canFastBindRequiredNamed:
    callScope = bindRequiredNamedCallScope(callee, proto, callee.fnName,
                                           args, named)
    returnType = proto.returnType
  elif named.len == 0 and proto.canFastBindPositionalInt and
      args.len == proto.params.len:
    callScope = bindPositionalIntCallScope(callee, proto, args)
    returnType = proto.returnType
  else:
    let bound = bindCallScope(callee, proto, args, named)
    callScope = bound.scope
    returnType = bound.returnType
  let frameReturnType = proto.checkedFrameReturnType(returnType)
  if proto.isGenerator:
    let fiber = Fiber(chunk: proto.chunk, scope: callScope)
    var resultValue = newGeneratorStream(proto, callScope, pullGeneratorStream,
                                         closeGeneratorStream)
    resultValue.setStreamGeneratorContinuation(fiber)
    if frameReturnType.kind != vkNil:
      resultValue = adaptBoundary("return from '" & callee.fnName & "'",
                                  frameReturnType, resultValue, callScope)
    return resultValue
  try:
    var resultValue: Value
    try:
      resultValue = runPooled(proto.chunk, callScope,
                              validateImplRequirements = proto.frameNeedsImplValidation)
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

proc syntaxCallEnvelope(scope: Scope, node: Value): Value =
  ## SyntaxCall envelope (design §3): the raw prop/body syntax nodes of the
  ## call plus the site, mirroring the ordinary Call envelope shape.
  var props = initPropTable()
  var named = initPropTable()
  for key, value in node.props:
    named[key] = value
  props["named"] = newMap(named)
  props["site"] = node
  var body = newSeq[Value](node.body.len)
  for i, item in node.body:
    body[i] = item
  newNode(builtinBinding(scope, "SyntaxCall"), props = props, body = body)

proc applySyntaxCall(callee: Value, callNode: Value, callerScope: Scope): Value =
  ## Apply a fn! (design §3 step 4): the callee receives the unevaluated
  ## prop/body syntax nodes and the caller environment. `caller_env` and
  ## `syntax_call` bind as implicit leading parameters.
  if not callee.isSyntaxFn:
    raise newException(GeneError,
      "syntax call site expects a fn! value, got " & $callee.kind)
  let code = callee.fnCode
  if code == nil or not (code of FunctionProto):
    raise newException(GeneError, "fn! has no VM code")
  let proto = FunctionProto(code)
  var args = newSeqOfCap[Value](callNode.body.len + 2)
  let callerEnv = newCallerEnv(callerScope)
  args.add callerEnv
  args.add syntaxCallEnvelope(callerScope, callNode)
  for item in callNode.body:
    args.add item
  var named = NamedArgs()
  for key, value in callNode.props:
    named.names.add key
    named.values.add value
  try:
    try:
      result = applyFunctionCall(callee, args, named, proto)
      rejectCallerEnvEscape("fn! return", result)
    except GeneError as e:
      if e.hasErrVal:
        rejectCallerEnvEscape("fn! error payload", e.errVal)
      attachSourceLoc(e, proto.sourceLoc)
      raise
  finally:
    deactivateCallerEnv(callerEnv)

proc validateConstructedInstance(typ, instance: Value) =
  ## Schema validation after a ctor body runs (design §7.1.1): required fields
  ## present, unknown fields rejected, field/body types checked against the
  ## full inherited schema with boundary adaptation written back in place.
  let typeName = typ.typeName
  let fields = typ.typeFields
  let fallbackScope = typ.typeScope
  for f in fields:
    var stored: Value
    if instance.props.tryGetById(f.nameId, stored):
      let fieldScope = f.typeFieldScope(fallbackScope)
      let adapted = adaptBoundary("field '" & f.name & "' for " & typeName,
                                  f.typeExpr, stored, fieldScope)
      instance.setNodeProp(f.name, adapted)
    elif not f.optional:
      raise newException(GeneError,
        "ctor for " & typeName & " left required field '" & f.name & "' unset")
  var propIds: seq[int32]
  for id, _ in instance.props.idPairs:
    propIds.add id
  for id in propIds:
    var known = false
    for f in fields:
      if f.nameId == id:
        known = true
        break
    if not known:
      raise newException(GeneError,
        typeName & " has no field '" & propKeyText(id) & "'")
  let bodyFields = typ.typeBodyFields
  let bodyLen = instance.body.len
  var restBody = -1
  for i, f in bodyFields:
    if f.rest:
      restBody = i
      break
  if restBody < 0:
    if bodyLen != bodyFields.len:
      raise newException(GeneError,
        "ctor for " & typeName & " must leave " & $bodyFields.len &
        " body item(s), got " & $bodyLen)
    for i, f in bodyFields:
      let fieldScope = f.typeBodyFieldScope(fallbackScope)
      instance.setNodeBodyItem(i, adaptBoundary(
        "body field " & $i & " for " & typeName, f.typeExpr,
        instance.body[i], fieldScope))
  else:
    if bodyLen < restBody:
      raise newException(GeneError,
        "ctor for " & typeName & " must leave at least " & $restBody &
        " body item(s), got " & $bodyLen)
    for i in 0 ..< restBody:
      let f = bodyFields[i]
      let fieldScope = f.typeBodyFieldScope(fallbackScope)
      instance.setNodeBodyItem(i, adaptBoundary(
        "body field " & $i & " for " & typeName, f.typeExpr,
        instance.body[i], fieldScope))
    let restType = bodyFields[restBody]
    let fieldScope = restType.typeBodyFieldScope(fallbackScope)
    for i in restBody ..< bodyLen:
      instance.setNodeBodyItem(i, adaptBoundary(
        "body field " & $i & " for " & typeName, restType.typeExpr,
        instance.body[i], fieldScope))

proc constructTypedInstance(callee: Value, args: openArray[Value],
                            named: NamedArgs): Value =
  ## Direct typed-data construction (design §7.1.1): map named arguments to
  ## props and positional arguments to body fields, validate against the full
  ## schema, stamp the head with the type. Never runs a ctor — `(T ...)` is
  ## the canonical replay-safe data form.
  if callee.isTypeAlias:
    raise newException(GeneError,
      "type alias '" & callee.typeName & "' is not constructible; it names " &
      "the type " & callee.typeAliasExpr.print())
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
  var props = initPropTable()
  for f in fields:
    let argIdx = named.argIndex(f.name)
    if argIdx >= 0:
      let value = named.valueAt(argIdx)
      if value.kind == vkVoid:
        if not f.optional:
          raise newException(GeneError,
            "missing required field '" & f.name & "' for " & callee.typeName)
      else:
        let fieldScope = f.typeFieldScope(callee.typeScope)
        props.putById(f.nameId,
                      adaptBoundary("field '" & f.name & "' for " &
                                    callee.typeName, f.typeExpr, value,
                                    fieldScope))
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
      raise newException(GeneError,
        callee.typeName & " has no field '" & key & "'")
  newNode(callee, props = props, body = body)

proc constructWithCtor(callee: Value, args: openArray[Value], named: NamedArgs,
                       dispatchScope: Scope = nil, site: Value = NIL): Value =
  ## Ctor construction (design §7.1.1): pre-create the instance with the type
  ## as head, run the ctor with it bound as `self` (the implicit leading
  ## parameter), then validate the completed instance against the full
  ## inherited schema. The ctor body result is ignored.
  let instance = newNode(callee, constructing = true)
  var ctorArgs = newSeqOfCap[Value](args.len + 1)
  ctorArgs.add instance
  for a in args:
    ctorArgs.add a
  inc activeConstructionDepth
  try:
    discard applyCall(callee.typeCtor, ctorArgs, named, dispatchScope, site)
    validateConstructedInstance(callee, instance)
    instance.finishNodeConstruction()
    instance
  finally:
    dec activeConstructionDepth

proc applyCall(callee: Value, args: openArray[Value], named: NamedArgs,
               dispatchScope: Scope = nil, site: Value = NIL,
               loc = SourceLoc()): Value =
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
                          site: site,
                          loc: loc)
    callImpl(args, addr call)
  of vkFfiCallable:
    applyFfiCallable(callee, args, named)
  of vkEnumVariant:
    constructEnumVariant(callee, args, named)
  of vkFunction:
    if callee.isSyntaxFn:
      rejectSyntaxCallWithoutSite(callee)
    let code = callee.fnCode
    if code == nil or not (code of FunctionProto):
      raise newException(GeneError, "function has no VM code")
    let proto = FunctionProto(code)
    try:
      applyFunctionCall(callee, args, named, proto)
    except GeneError as e:
      attachSourceLoc(e, proto.sourceLoc)
      raise
  of vkType:
    if callee.isEnumType:
      raise newException(GeneError,
        "enum " & callee.typeName & " is not directly constructible; use a variant")
    # Direct typed-data construction: `(T ...)` never calls a ctor, even when
    # the type defines one (design §7.1.1). Constructor logic runs through
    # `new` only.
    constructTypedInstance(callee, args, named)
  of vkProtocolMessage:
    # `~` is the only way to invoke a message (design §3), so a message value
    # is not callable — not in head position and not as a higher-order function
    # (`(map xs P/m)`). Use a lambda: `(map xs (fn [x] (x ~ P/m)))`.
    rejectMessageCall(callee, dispatchScope)
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

proc importFromPath(form: Value): string =
  ## The raw `from "path"` string of a top-level import form, or "" when the
  ## form is not a from-import.
  if form.kind != vkNode or form.head.kind != vkSymbol or
      form.head.symVal != "import":
    return ""
  let body = form.body
  for i, e in body:
    if e.kind == vkSymbol and e.symVal == "from":
      if i + 1 < body.len and body[i + 1].kind == vkString:
        return body[i + 1].strVal
      return ""
  ""

proc collectStaticImportForms(forms: openArray[Value], first = 0): seq[Value] =
  if first > forms.high:
    return
  for i in first .. forms.high:
    let form = forms[i]
    if form.kind != vkNode or form.head.kind != vkSymbol:
      continue
    case form.head.symVal
    of "import":
      result.add form
    of "mod", "ns":
      for nested in collectStaticImportForms(form.body, 1):
        result.add nested
    of "do":
      for nested in collectStaticImportForms(form.body, 0):
        result.add nested
    else:
      discard

proc moduleCompileHeader(app: Application,
                         absPath: string): ModuleCompileHeader =
  if app.moduleCompileHeaders.hasKey(absPath):
    return app.moduleCompileHeaders[absPath]
  let source =
    if absPath.isUrlModulePath:
      app.fetchUrlModuleSource(absPath).body
    else:
      if not fileExists(absPath):
        raise newException(GeneError, "module not found: " & absPath)
      readFile(absPath)
  let unit = readAllWithLocs(source, absPath)
  result = ModuleCompileHeader(unit: unit,
                               compileInterface: buildCompileInterface(unit.forms))
  app.moduleCompileHeaders[absPath] = result

proc compileModuleArtifact(app: Application,
                           absPath: string): ModuleCompileArtifact =
  ## Build/cache a module's compile artifact without creating a runtime scope or
  ## executing top-level code. Wildcards and aliases consume lightweight
  ## headers; macros and explicit re-exports may require a dependency artifact.
  ## Value-only cycles remain runtime cycles.
  if app.moduleCompileArtifacts.hasKey(absPath):
    return app.moduleCompileArtifacts[absPath]
  if absPath in app.moduleCompileLoading:
    raise newException(GeneError,
      "compile-time macro dependency cycle at " & absPath)
  let header = app.moduleCompileHeader(absPath)
  app.moduleCompileLoading.incl absPath
  let savedDir = app.currentModuleDir
  app.currentModuleDir = app.moduleSourceDir(absPath)
  try:
    var importedMacros = initTable[string, Table[string, MacroDef]]()
    var importedSyntaxFns = initTable[string, seq[string]]()
    var importedInterfaces =
      initTable[string, CompileNamespaceInterface]()
    var dependencies = initTable[string, ModuleCompileArtifact]()
    var importSpecs: seq[ImportSpec]
    var ownInterface = cloneCompileInterface(header.compileInterface)
    for form in collectStaticImportForms(header.unit.forms):
      let raw = importFromPath(form)
      if raw.len == 0:
        continue
      let importSpec = parseImportSpec(form)
      importSpecs.add importSpec
      let depPath = app.resolveModulePath(raw)
      let depHeader = app.moduleCompileHeader(depPath)
      var depInterface = depHeader.compileInterface
      var dependency: ModuleCompileArtifact
      var depHasReexports = false
      for depImport in collectStaticImportForms(depHeader.unit.forms):
        if importFromPath(depImport).len > 0 and
            parseImportSpec(depImport).reexport:
          depHasReexports = true
          break
      let needsDependency = importSpec.reexport or depHasReexports
      if needsDependency:
        dependency = compileModuleArtifact(app, depPath)
        dependencies[raw] = dependency
        depInterface = dependency.compileInterface
      importedInterfaces[raw] = depInterface
      importedSyntaxFns[raw] = compileInterfacePaths(
        depInterface, cbcSyntaxFn)
      var needsMacroArtifact = false
      if importSpec.wildcard:
        let subtree = compileInterfaceAt(depInterface,
                                         importSpec.wildcardSegments)
        needsMacroArtifact =
          compileInterfacePaths(subtree, cbcMacro).len > 0
      for selection in importSpec.selections:
        let path = selection.name.split('/')
        let resolved = compileInterfaceEntryAt(depInterface,
                                               path)
        if resolved.found and resolved.entry.category == cbcMacro:
          needsMacroArtifact = true
          break
      if needsMacroArtifact:
        if dependency == nil:
          dependency = compileModuleArtifact(app, depPath)
          dependencies[raw] = dependency
          importedInterfaces[raw] = dependency.compileInterface
        importedMacros[raw] = dependency.macroExports
      if importSpec.reexport:
        let publicInterface = importedInterfaces[raw]
        if importSpec.alias.len > 0:
          let subtree = compileInterfaceAt(publicInterface,
                                           importSpec.wildcardSegments)
          ownInterface.entries[importSpec.alias] = CompileInterfaceEntry(
            category: cbcNamespace,
            namespace: cloneCompileInterface(subtree))
        for selection in importSpec.selections:
          let resolved = compileInterfaceEntryAt(
            publicInterface, selection.name.split('/'))
          if not resolved.found:
            raise newException(GeneError,
              "cannot re-export missing compile interface name: " &
              selection.name)
          var entry = resolved.entry
          if entry.category == cbcNamespace:
            entry.namespace = cloneCompileInterface(entry.namespace)
          ownInterface.entries[selection.local] = entry
    let compiled = compileFormsWithMacros(header.unit, importedMacros,
                                          importedSyntaxFns,
                                          importedInterfaces)
    var macroExports = compiled.macroExports
    var syntaxFnExports = compiled.syntaxFnExports
    for spec in importSpecs:
      if not spec.reexport or not dependencies.hasKey(spec.modulePath):
        continue
      let dependency = dependencies[spec.modulePath]
      for selection in spec.selections:
        if dependency.macroExports.hasKey(selection.name):
          macroExports[selection.local] =
            dependency.macroExports[selection.name]
        if selection.name in dependency.syntaxFnExports and
            selection.local notin syntaxFnExports:
          syntaxFnExports.add selection.local
      if spec.alias.len > 0:
        let prefix = spec.wildcardSegments.join("/")
        for path, definition in dependency.macroExports:
          if prefix.len == 0 or path == prefix or
              path.startsWith(prefix & "/"):
            let relative =
              if prefix.len == 0: path
              elif path.len > prefix.len: path[prefix.len + 1 .. ^1]
              else: ""
            if relative.len > 0:
              macroExports[spec.alias & "/" & relative] = definition
        for path in dependency.syntaxFnExports:
          if prefix.len == 0 or path.startsWith(prefix & "/"):
            let relative =
              if prefix.len == 0: path
              else: path[prefix.len + 1 .. ^1]
            let exported = spec.alias & "/" & relative
            if exported notin syntaxFnExports:
              syntaxFnExports.add exported
    syntaxFnExports.sort()
    result = ModuleCompileArtifact(chunk: compiled.chunk,
                                   macroExports: macroExports,
                                   syntaxFnExports: syntaxFnExports,
                                   compileInterface: ownInterface)
    app.moduleCompileArtifacts[absPath] = result
  finally:
    app.currentModuleDir = savedDir
    app.moduleCompileLoading.excl absPath

proc loadModuleValue(app: Application, absPath: string): Value =
  ## Initialize/cache the runtime phase of a compiled module. Compile-time
  ## macro discovery has a separate artifact cache and cycle set above and does
  ## not create scopes, grant capabilities, or execute top-level forms.
  if app.moduleCache.hasKey(absPath):
    return app.moduleCache[absPath]
  if absPath in app.moduleLoading:
    raise newException(GeneError,
      "runtime module initialization cycle at " & absPath)
  if not absPath.isUrlModulePath and not fileExists(absPath):
    raise newException(GeneError, "module not found: " & absPath)
  app.moduleLoading.incl absPath
  let modScope = newGlobalScope(app)
  modScope.implStageRoot = true
  result = bindThisModule(modScope, splitFile(absPath).name, absPath)
  let savedDir = app.currentModuleDir
  app.currentModuleDir = app.moduleSourceDir(absPath)
  try:
    let artifact = compileModuleArtifact(app, absPath)
    discard run(artifact.chunk, modScope)
    activateStagedImpls(modScope)
  finally:
    app.currentModuleDir = savedDir
    app.moduleLoading.excl absPath
  app.moduleCache[absPath] = result

proc validateImplCollection(impls: openArray[ProtocolImpl]) =
  for i in 0 ..< impls.len:
    for j in i + 1 ..< impls.len:
      discard impls[i].validateImplConflict(impls[j])

proc collectionHasImpl(impls: openArray[ProtocolImpl], typ,
                       protocol: Value): bool =
  for impl in impls:
    if protocolIsOrInherits(impl.protocol, protocol) and
        typ.isSubtypeOf(impl.receiver):
      return true
  false

proc validateProspectiveBase(scope: Scope,
                             localImpls, canonical: openArray[ProtocolImpl]) =
  var enumerable: seq[ProtocolImpl]
  for impl in localImpls:
    if impl.visibility != ivOverlay:
      enumerable.add impl
  enumerable.validateImplCollection()
  for local in enumerable:
    for global in canonical:
      discard local.validateImplConflict(global)
  for typ in scope.requiredImplTypes:
    for protocol in typ.typeRequiredProtocols:
      if not (enumerable.collectionHasImpl(typ, protocol) or
              canonical.collectionHasImpl(typ, protocol)):
        raise newException(GeneError,
          "type " & typ.typeName & " requires impl " & protocol.protocolName)

proc reloadedImporterImpl(old: ProtocolImpl,
                          newScoped: openArray[ProtocolImpl],
                          originPath: string): ProtocolImpl =
  for candidate in newScoped:
    if candidate.visibility == ivScoped and candidate.exported and
        same(candidate.protocol, old.protocol) and
        same(candidate.receiver, old.receiver):
      result = candidate
      result.exported = false
      result.imported = true
      return
  raise newException(GeneError,
    "reload removed exported impl " & old.protocol.protocolName &
    " for " & old.receiver.typeName & " from " & originPath)

proc rebuildImplScopeIndex(app: Application) =
  app.implScopeIndex.clear()
  for scope in app.baseScopes:
    for impl in scope.impls:
      if impl.visibility == ivScoped:
        app.addIndexedScope(scope, impl)

proc implActivationEpoch*(app: Application): uint64 {.inline.} =
  app.implEpoch

proc reloadFileModule*(app: Application, path: string): Value =
  ## Compile and execute a replacement off to the side, then replace canonical
  ## registrations and explicit import_impl copies in one commit. Runtime
  ## overlays are deliberately absent from the prospective checks.
  if path.isUrlModulePath:
    # URL content is mutable and unpinned; reload stays file-only until the
    # disk cache + lockfile stage of design §15.9.
    raise newException(GeneError, "reload does not support URL modules: " & path)
  var p = path
  if splitFile(p).ext.len == 0:
    p &= ".gene"
  let absPath = normalizedPath(absolutePath(p))
  if not app.isWithinPackageRoot(absPath):
    raise newException(GeneError, "module path escapes package root: " & path)
  if not app.moduleCache.hasKey(absPath):
    return loadModuleValue(app, absPath)
  if absPath in app.moduleLoading:
    raise newException(GeneError,
      "cannot reload a module during initialization: " & absPath)
  if not fileExists(absPath):
    raise newException(GeneError, "module not found: " & absPath)

  let oldRootImpls = app.builtinsScope().impls
  let oldModuleCache = app.moduleCache
  let oldHeaders = app.moduleCompileHeaders
  let oldArtifacts = app.moduleCompileArtifacts
  let oldBaseScopes = app.baseScopes
  let oldIndex = app.implScopeIndex
  let oldEpoch = app.implEpoch
  let oldSerdeOrigins = app.serdeOrigins
  let oldSerdeValueOrigins = app.serdeValueOrigins
  let oldSerdeOriginModules = app.serdeOriginModules
  let oldSerdeBuiltinsDone = app.serdeOriginBuiltinsDone
  let oldModule = app.moduleCache[absPath]
  let oldScope = oldModule.moduleRootNamespace.nsScope
  let oldInterface =
    if oldArtifacts.hasKey(absPath): oldArtifacts[absPath].compileInterface
    else: nil

  app.moduleCompileHeaders.del(absPath)
  app.moduleCompileArtifacts.del(absPath)
  app.moduleLoading.incl absPath
  let replacementScope = newGlobalScope(app)
  replacementScope.implStageRoot = true
  let replacement = bindThisModule(replacementScope,
    splitFile(absPath).name, absPath)
  let savedDir = app.currentModuleDir
  app.currentModuleDir = parentDir(absPath)
  try:
    let artifact = compileModuleArtifact(app, absPath)
    if oldInterface != nil and
        not compileInterfacesEqual(oldInterface, artifact.compileInterface):
      raise newException(GeneError,
        "reload changed the module compile interface: " & absPath)
    discard run(artifact.chunk, replacementScope)

    var canonical: seq[ProtocolImpl]
    for impl in app.builtinsScope().impls:
      if impl.originPath != absPath:
        canonical.add impl
    var newScoped: seq[ProtocolImpl]
    var retained: seq[ProtocolImpl]
    for impl in replacementScope.impls:
      case impl.visibility
      of ivCanonical:
        canonical.add impl
      of ivScoped:
        newScoped.add impl
        retained.add impl
      of ivOverlay:
        retained.add impl
    canonical.validateImplCollection()
    replacementScope.validateProspectiveBase(retained, canonical)

    var updatedScopes: seq[tuple[scope: Scope, impls: seq[ProtocolImpl]]]
    for scope in oldBaseScopes:
      if scope == oldScope:
        continue
      var changed = false
      var prospective: seq[ProtocolImpl]
      for impl in scope.impls:
        if impl.imported and impl.originPath == absPath:
          prospective.add impl.reloadedImporterImpl(newScoped, absPath)
          changed = true
        else:
          prospective.add impl
      scope.validateProspectiveBase(prospective, canonical)
      if changed:
        updatedScopes.add (scope: scope, impls: prospective)

    # Commit. No enumerable live scope is mutated before this point.
    app.builtinsScope().impls = canonical
    replacementScope.impls = retained
    for update in updatedScopes:
      update.scope.impls = update.impls
    app.moduleCache[absPath] = replacement
    var bases: seq[Scope]
    for scope in app.baseScopes:
      if scope != oldScope:
        bases.add scope
    app.baseScopes = bases
    app.rebuildImplScopeIndex()
    app.implEpoch = oldEpoch + 1
    app.serdeOrigins.clear()
    app.serdeValueOrigins.clear()
    app.serdeOriginModules.clear()
    app.serdeOriginBuiltinsDone = false
    result = replacement
  except CatchableError:
    app.builtinsScope().impls = oldRootImpls
    app.moduleCache = oldModuleCache
    app.moduleCompileHeaders = oldHeaders
    app.moduleCompileArtifacts = oldArtifacts
    app.baseScopes = oldBaseScopes
    app.implScopeIndex = oldIndex
    app.implEpoch = oldEpoch
    app.serdeOrigins = oldSerdeOrigins
    app.serdeValueOrigins = oldSerdeValueOrigins
    app.serdeOriginModules = oldSerdeOriginModules
    app.serdeOriginBuiltinsDone = oldSerdeBuiltinsDone
    raise
  finally:
    app.currentModuleDir = savedDir
    app.moduleLoading.excl absPath

proc loadUrlModule*(app: Application, url: string): Value =
  ## Experimental `gene runurl` entry (design §15.9): load a remote module
  ## graph rooted at `url`. The caller must have enabled `allowUrlModules`;
  ## resolveModulePath validates the scheme and normalizes the identity.
  loadModuleValue(app, app.resolveModulePath(url))

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

proc compileFileModule*(app: Application, path: string): Chunk =
  ## Compile a file module and its macro dependencies without running any
  ## module's runtime phase. Used by tooling/cross-compilation surfaces.
  var p = path
  if splitFile(p).ext.len == 0:
    p = p & ".gene"
  let absPath = normalizedPath(absolutePath(p))
  if not app.isWithinPackageRoot(absPath):
    raise newException(GeneError, "module path escapes package root: " & path)
  compileModuleArtifact(app, absPath).chunk
