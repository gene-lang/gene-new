## Native extension plumbing. The public C ABI is the opaque `GeneApi` in
## native_api.h; the direct Nim helpers below serve in-repo runtime code.
## Roots keep their Values alive, and geneCall uses normal dynamic dispatch.

import std/[algorithm, dynlib, json, locks, os, sets, tables]
when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import std/posix

import ./ext/logging
import ./[types, vm]
when defined(geneAtomicGenerationRetirementProbe):
  import ./retirement_native_gate

template withRetirementNativeAdmission(mayNeedOwnerProgress: static[bool], body: untyped) =
  when defined(geneAtomicGenerationRetirementProbe):
    if not enterRetirementNativeAccess(mayNeedOwnerProgress):
      raise newException(GeneError, "native access cannot enter generation analysis")
    try: body
    finally: leaveRetirementNativeAccess()
  else:
    body

export vm.NativeSyncCallback, vm.newNativeSyncCallback,
       vm.beginNativeCallbackCall, vm.withNativeSyncCallback,
       vm.invokeNativeSyncCallback, vm.finishNativeCallbackCall

type
  GeneWrapperField* = object
    ## One declared prop of a native wrapper type. `typeExpr` is an ordinary
    ## Gene type expression (`newSym("Str")`, `(C/OwnedPtr PGconn)`, …) or NIL
    ## for `Any`; `optional` mirrors the nil-admitting field rule (design §7.1).
    name*: string
    typeExpr*: Value
    optional*: bool

  GeneIngressBeginProc* = proc(context: pointer,
                               generation: uint64): cint {.cdecl.}
  GeneIngressEnqueueProc* = proc(context, data: pointer,
                                 length: csize_t): cint {.cdecl.}
  GeneIngressEndProc* = proc(context: pointer) {.cdecl.}
  GeneIngressUnregisterProc* = proc(context: pointer): cint {.cdecl.}
  # The single C-facing layout.
  GeneOutBytes* {.bycopy.} = object
    data*: ptr uint8
    capacity*: csize_t
    required*: csize_t
  GeneNamedArg* {.bycopy.} = object
    name*: ptr uint8
    nameLen*: csize_t
    value*: uint64
  GeneCopiedResult* {.bycopy.} = object
    kind*: uint32
    scalar*: int64
    real*: float64
    data*: ptr uint8
    length*: csize_t
  GeneNativeCallbackProc* = proc(api: ptr GeneApi, userContext: pointer,
      arguments: ptr uint64, argumentCount: csize_t,
      named: ptr GeneNamedArg, namedCount: csize_t,
      environment: uint64, output, error: ptr uint64,
      diagnostic: ptr GeneOutBytes): uint32 {.cdecl.}
  GeneContextRetireProc* = proc(userContext: pointer) {.cdecl.}
  GeneApi* {.bycopy.} = object
    version*: uint32
    structSize*: uint32
    featureBits*: uint64
    runtimeContext*: pointer
    attachThread*, detachThread*, retain*, release*, kind*: pointer
    copyBool*, copyI64*, copyText*, copyBytes*: pointer
    newBool*, newI64*, newText*, newBytes*: pointer
    length*, copyKey*, traverse*, call*, define*: pointer
    registerCallback*, requestClose*, waitClosed*, lookup*: pointer
    ingressBegin*: GeneIngressBeginProc
    ingressEnqueue*: GeneIngressEnqueueProc
    ingressEnd*: GeneIngressEndProc
    newTask*, taskComplete*, taskFail*, taskCancel*, taskRetire*: pointer
    taskSubmitCopy*: pointer
    copyF64*, newF64*: pointer
    reserveForeignRoots*: pointer
  GeneModuleInitCProc* = proc(api: ptr GeneApi, environment: uint64,
                               diagnostic: ptr GeneOutBytes): uint32 {.cdecl.}
  GeneIngressRegisterProc* = proc(api: ptr GeneApi, context: pointer,
                                    generation: uint64,
                                    nativeContext: ptr pointer): cint {.cdecl.}

  GeneIngressSlot = object
    data: pointer
    length: int
  GeneIngressState = object
    lock: Lock
    generation: uint64
    ownerThreadId: int
    maxCount, maxBytes, maxPayload: int
    head, tail, queuedCount, queuedBytes: int
    inFlight: int
    received, delivered, rejected, discarded: uint64
    firstFailure: cint
    closed, unregistered, wakePending, failNextAllocation: bool
    slots: array[256, GeneIngressSlot]
  GeneIngressContext* = ptr GeneIngressState
  GeneIngressStats* = object
    generation*: uint64
    queuedCount*, queuedBytes*, inFlight*: int
    received*, delivered*, rejected*, discarded*: uint64
    firstFailure*: cint
    closed*, unregistered*, wakePending*: bool
  GeneIngressSubscription* = ref object
    id*: uint64
    context*: GeneIngressContext
    application: Application
    ownerLane*: int
    managedOwner: RootRef
    released*: bool
    closeRequested*: bool
    handled*: uint64
    terminalStatus*: GeneStatus
    terminalMessage*: string
    dispatching: bool
    unregisterProc: GeneIngressUnregisterProc
    unregisterContext: pointer
    unregisterJob: ptr GeneUnregisterJob
    unregisterQueued: bool
    unregisterFailed: bool
    cleanupLease: Value
    waiters: seq[GeneIngressWaiter]
    handleId: uint64
    handleGone, autoRetire: bool
    finalContextStats: GeneIngressStats
  GeneIngressWaiter = object
    task, lease: Value
    scope: Scope
  GeneIngressSubscriptionStatus* = object
    state*: string
    context*: GeneIngressStats
    handled*: uint64
    terminalStatus*: GeneStatus
    terminalMessage*: string
    unregisterPending*: bool
  GeneIngressManagedResult* = object
    status*: GeneStatus
    message*: string
    pending*, completed*: bool
  GeneIngressManagedHooks* = object
    open*: proc(handler: Value, scope: Scope, library: Value): RootRef {.nimcall.}
    dispatch*: proc(owner: RootRef, payload: string):
                    GeneIngressManagedResult {.nimcall.}
    settle*: proc(owner: RootRef): GeneIngressManagedResult {.nimcall.}
    cancel*: proc(owner: RootRef) {.nimcall.}
    release*: proc(owner: RootRef) {.nimcall.}

  GeneUnregisterJob = object
    callback: GeneIngressUnregisterProc
    context: pointer
    code: cint
    done: bool
  GeneUnregisterService = object
    lock: Lock
    cond: Cond
    jobs: array[128, ptr GeneUnregisterJob]
    head, tail, count: int
    stopRequested: bool

  GeneStatus* = enum
    gsOk
    gsError
    gsPanic
    gsCancelled

  GeneRoot* = ref object
    value: Value
    released: bool

  GeneCallbackHandle* = ref object
    callee: GeneRoot
    ownerThreadId: int
    active: bool
    released: bool

  GeneThreadAttachment* = ref object
    ownerThreadId: int
    released: bool

  GeneCall* = object
    args*: seq[Value]
    namedNames*: seq[string]
    namedValues*: seq[Value]
    dispatchScope*: Scope
    site*: Value

  GeneResult* = object
    status*: GeneStatus
    value*: Value
    message*: string
    errorValue*: Value
    hasErrorValue*: bool

  GeneModule* = ref object
    value: Value
    scope: Scope

const GeneApiVersion* = 6'u32
const GeneApiIngressFeature* = 32'u64
const GeneIngressMaxCount* = 256
const GeneIngressMaxBytes* = 1024 * 1024
const GeneIngressMaxPayload* = 64 * 1024
const GeneIngressAccepted* = 0.cint
const GeneIngressClosed* = -1.cint
const GeneIngressOverflow* = -2.cint
const GeneIngressAllocationFailed* = -3.cint
const GeneIngressEntryMissing* = -4.cint

var geneThreadAttachDepth {.threadvar.}: int
var ingressEntryDepth {.threadvar.}: int
var ingressEntryStack {.threadvar.}: array[16, pointer]
var ingressSubscriptions = initTable[uint64, GeneIngressSubscription]()
var ingressHandles = initTable[uint64, GeneIngressSubscription]()
var ingressHandleLock: Lock
initLock(ingressHandleLock)
var ingressPollCursor: uint64
var ingressPollActive: bool
var ingressManagedHooks: GeneIngressManagedHooks
var unregisterService: ptr GeneUnregisterService
var unregisterThread: ref Thread[void]
var ingressWakeRead = -1.cint
var ingressWakeWrite = -1.cint
var nativeWakeUsers: int # root-lane producer owners sharing the ingress wake pipe

proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(value: pointer) {.importc: "free", header: "<stdlib.h>".}
proc signalIngressWake() {.gcsafe.}

proc installNativeIngressManagedHooks*(hooks: GeneIngressManagedHooks) =
  ## Installed by native_managed at startup; the lower-level byte queue does
  ## not import the managed registry back through a circular dependency.
  if hooks.open == nil or hooks.dispatch == nil or hooks.settle == nil or
      hooks.cancel == nil or hooks.release == nil:
    raise newException(GeneError, "native ingress managed hooks are incomplete")
  ingressManagedHooks = hooks

proc nativeUnregisterWorker() {.thread.} =
  {.cast(gcsafe).}:
    let service = unregisterService
    while true:
      var job: ptr GeneUnregisterJob
      withLock service.lock:
        while service.count == 0 and not service.stopRequested:
          wait(service.cond, service.lock)
        if service.stopRequested and service.count == 0:
          break
        job = service.jobs[service.head]
        service.jobs[service.head] = nil
        service.head = (service.head + 1) mod service.jobs.len
        dec service.count
      job.code = job.callback(job.context)
      atomicStoreN(addr job.done, true, ATOMIC_RELEASE)
      signalIngressWake()

proc ensureUnregisterWorker() =
  if unregisterService != nil: return
  let service = cast[ptr GeneUnregisterService](
    cMalloc(csize_t(sizeof(GeneUnregisterService))))
  if service == nil:
    raise newException(GeneError,
      "native unregister worker allocation failed")
  zeroMem(service, sizeof(GeneUnregisterService))
  initLock(service.lock)
  initCond(service.cond)
  unregisterService = service
  try:
    var worker: ref Thread[void]
    new(worker)
    createThread(worker[], nativeUnregisterWorker)
    unregisterThread = worker
  except CatchableError:
    unregisterService = nil
    deinitCond(service.cond)
    deinitLock(service.lock)
    cFree(service)
    raise

proc enqueueUnregister(job: ptr GeneUnregisterJob): bool =
  ensureUnregisterWorker()
  let service = unregisterService
  withLock service.lock:
    if service.stopRequested or service.count >= service.jobs.len:
      return false
    service.jobs[service.tail] = job
    service.tail = (service.tail + 1) mod service.jobs.len
    inc service.count
    signal(service.cond)
  true

proc stopUnregisterWorker() =
  let service = unregisterService
  if service == nil: return
  withLock service.lock:
    service.stopRequested = true
    signal(service.cond)
  if unregisterThread != nil:
    joinThread(unregisterThread[])
    unregisterThread = nil
  unregisterService = nil
  deinitCond(service.cond)
  deinitLock(service.lock)
  cFree(service)

proc ensureIngressWakePipe() =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if ingressWakeRead >= 0: return
    var fds: array[2, cint]
    if posix.pipe(fds) != 0:
      raise newException(GeneError, "native ingress wake pipe failed")
    if fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) or O_NONBLOCK) < 0 or
        fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL, 0) or O_NONBLOCK) < 0 or
        fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 or
        fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0:
      discard posix.close(fds[0])
      discard posix.close(fds[1])
      raise newException(GeneError, "native ingress wake pipe setup failed")
    ingressWakeRead = fds[0]
    ingressWakeWrite = fds[1]

proc closeIngressWakePipe() =
  if nativeWakeUsers > 0: return
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if ingressWakeRead >= 0: discard posix.close(ingressWakeRead)
    if ingressWakeWrite >= 0: discard posix.close(ingressWakeWrite)
    ingressWakeRead = -1
    ingressWakeWrite = -1

proc signalIngressWake() {.gcsafe.} =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if ingressWakeWrite >= 0:
      var byte = 'w'
      discard posix.write(ingressWakeWrite, addr byte, 1)

proc geneHoldNativeWake*() =
  ## Root-lane ownership; C producers keep the pipe open after ingress closes.
  ensureIngressWakePipe()
  inc nativeWakeUsers

proc geneReleaseNativeWake*() =
  if nativeWakeUsers <= 0:
    raise newException(GeneError, "native wake owner is unavailable")
  dec nativeWakeUsers
  if nativeWakeUsers == 0 and ingressSubscriptions.len == 0:
    closeIngressWakePipe()

proc geneSignalNativeWake*() {.gcsafe.} =
  signalIngressWake()

proc waitIngressWake(timeoutMs: int): bool {.nimcall.} =
  if ingressSubscriptions.len == 0 and nativeWakeUsers == 0:
    os.sleep(timeoutMs)
    return false
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if ingressWakeRead < 0:
      os.sleep(timeoutMs)
      return false
    var descriptor = TPollfd(fd: ingressWakeRead, events: POLLIN)
    let ready = posix.poll(addr descriptor, Tnfds(1), cint(timeoutMs))
    if ready > 0:
      var bytes: array[128, char]
      while posix.read(ingressWakeRead, addr bytes[0], bytes.len) > 0:
        discard
      return true
  else:
    os.sleep(timeoutMs)
  false

proc newGeneIngressContext*(generation: uint64,
                            maxCount = GeneIngressMaxCount,
                            maxBytes = GeneIngressMaxBytes,
                            maxPayload = GeneIngressMaxPayload):
                            GeneIngressContext =
  if generation == 0 or maxCount < 1 or maxCount > GeneIngressMaxCount or
      maxBytes < 1 or maxBytes > GeneIngressMaxBytes or
      maxPayload < 1 or maxPayload > GeneIngressMaxPayload or
      maxPayload > maxBytes:
    raise newException(GeneError, "native ingress limits are invalid")
  result = cast[GeneIngressContext](allocShared0(sizeof(GeneIngressState)))
  if result == nil:
    raise newException(GeneError, "native ingress allocation failed")
  initLock(result.lock)
  result.generation = generation
  result.ownerThreadId = getThreadId()
  result.maxCount = maxCount
  result.maxBytes = maxBytes
  result.maxPayload = maxPayload

proc geneIngressBegin*(context: pointer,
                       generation: uint64): cint {.cdecl, gcsafe.} =
  let state = cast[GeneIngressContext](context)
  if state == nil or ingressEntryDepth >= ingressEntryStack.len:
    return 0
  withLock state.lock:
    if state.closed or state.unregistered or
        state.generation != generation:
      return 0
    inc state.inFlight
  ingressEntryStack[ingressEntryDepth] = context
  inc ingressEntryDepth
  1

proc geneIngressEnqueue*(context, data: pointer,
                         length: csize_t): cint {.cdecl, gcsafe.} =
  let state = cast[GeneIngressContext](context)
  if state == nil or ingressEntryDepth <= 0 or
      ingressEntryStack[ingressEntryDepth - 1] != context:
    return GeneIngressEntryMissing
  withLock state.lock:
    if state.closed or state.unregistered:
      inc state.rejected
      if state.firstFailure == 0: state.firstFailure = GeneIngressClosed
      state.wakePending = true
      signalIngressWake()
      return GeneIngressClosed
    if length > csize_t(state.maxPayload) or
        (length > 0 and data == nil) or
        state.queuedCount >= state.maxCount or
        length > csize_t(state.maxBytes - state.queuedBytes):
      inc state.rejected
      if state.firstFailure == 0: state.firstFailure = GeneIngressOverflow
      state.wakePending = true
      signalIngressWake()
      return GeneIngressOverflow
    if state.failNextAllocation:
      state.failNextAllocation = false
      inc state.rejected
      if state.firstFailure == 0:
        state.firstFailure = GeneIngressAllocationFailed
      state.wakePending = true
      signalIngressWake()
      return GeneIngressAllocationFailed
    let copied = cMalloc(max(csize_t(1), length))
    if copied == nil:
      inc state.rejected
      if state.firstFailure == 0:
        state.firstFailure = GeneIngressAllocationFailed
      state.wakePending = true
      signalIngressWake()
      return GeneIngressAllocationFailed
    if length > 0:
      copyMem(copied, data, int(length))
    state.slots[state.tail] = GeneIngressSlot(data: copied,
                                               length: int(length))
    state.tail = (state.tail + 1) mod GeneIngressMaxCount
    inc state.queuedCount
    inc state.queuedBytes, int(length)
    inc state.received
    state.wakePending = true
    signalIngressWake()
  GeneIngressAccepted

proc geneIngressEnd*(context: pointer) {.cdecl, gcsafe.} =
  if context == nil or ingressEntryDepth <= 0 or
      ingressEntryStack[ingressEntryDepth - 1] != context:
    return
  let state = cast[GeneIngressContext](context)
  withLock state.lock:
    if state.inFlight > 0: dec state.inFlight
  dec ingressEntryDepth
  ingressEntryStack[ingressEntryDepth] = nil

proc requireIngressOwner(context: GeneIngressContext) =
  if context == nil or context.ownerThreadId != getThreadId():
    raise newException(GeneError,
      "native ingress context requires its owning lane")

proc geneIngressStats*(context: GeneIngressContext): GeneIngressStats =
  requireIngressOwner(context)
  withLock context.lock:
    result = GeneIngressStats(generation: context.generation,
      queuedCount: context.queuedCount, queuedBytes: context.queuedBytes,
      inFlight: context.inFlight, received: context.received,
      delivered: context.delivered, rejected: context.rejected,
      discarded: context.discarded, firstFailure: context.firstFailure,
      closed: context.closed, unregistered: context.unregistered,
      wakePending: context.wakePending)

proc geneIngressPop*(context: GeneIngressContext,
                     payload: var string): bool =
  requireIngressOwner(context)
  withLock context.lock:
    if context.queuedCount == 0:
      return false
    let slot = context.slots[context.head]
    payload = newString(slot.length)
    if slot.length > 0:
      copyMem(addr payload[0], slot.data, slot.length)
    cFree(slot.data)
    context.slots[context.head] = GeneIngressSlot()
    context.head = (context.head + 1) mod GeneIngressMaxCount
    dec context.queuedCount
    dec context.queuedBytes, slot.length
    inc context.delivered
    if context.queuedCount == 0: context.wakePending = false
  true

proc geneIngressFailNextAllocation*(context: GeneIngressContext) =
  requireIngressOwner(context)
  withLock context.lock:
    context.failNextAllocation = true

proc geneIngressClose*(context: GeneIngressContext) =
  requireIngressOwner(context)
  withLock context.lock:
    if context.closed: return
    context.closed = true
    while context.queuedCount > 0:
      let slot = context.slots[context.head]
      cFree(slot.data)
      context.slots[context.head] = GeneIngressSlot()
      context.head = (context.head + 1) mod GeneIngressMaxCount
      dec context.queuedCount
      dec context.queuedBytes, slot.length
      inc context.discarded
    context.wakePending = false

proc geneIngressConfirmUnregistered*(context: GeneIngressContext) =
  requireIngressOwner(context)
  withLock context.lock:
    if not context.closed:
      raise newException(GeneError,
        "native ingress must close before unregistration is confirmed")
    context.unregistered = true

proc geneIngressCanRetire*(context: GeneIngressContext): bool =
  requireIngressOwner(context)
  withLock context.lock:
    result = context.closed and context.unregistered and
      context.inFlight == 0 and context.queuedCount == 0

proc geneIngressDestroy*(context: GeneIngressContext) =
  requireIngressOwner(context)
  if not geneIngressCanRetire(context):
    raise newException(GeneError,
      "native ingress cannot retire before callback quiescence")
  deinitLock(context.lock)
  deallocShared(context)

proc geneApiIngress*(): GeneApi
proc errorResult(e: ref GeneError): GeneResult

proc geneNewLogger*(name: string): RuntimeLogger =
  newRuntimeLogger(name)

proc geneLogEnabled*(logger: RuntimeLogger, level: LogLevel): bool =
  logger != nil and logger.enabled(level)

proc geneLogEmit*(logger: RuntimeLogger, level: LogLevel,
                  message, payloadJson: string): GeneResult =
  try:
    if logger == nil:
      raise newException(GeneError, "native log logger is nil")
    var payload = newJObject()
    if payloadJson.len > 0:
      payload = parseJson(payloadJson)
      if payload.kind != JObject:
        raise newException(GeneError,
          "native log payload JSON must encode an object")
    logger.emit(level, message, payload)
    result.status = gsOk
    result.value = NIL
  except GeneError as e:
    result = errorResult(e)
  except CatchableError as e:
    result.status = gsError
    result.message = "native log payload JSON: " & e.msg

proc errorResult(e: ref GeneError): GeneResult =
  result.status = gsError
  result.message = e.msg
  result.hasErrorValue = e.hasErrVal
  if e.hasErrVal:
    result.errorValue = e.errVal

proc panicResult(e: ref GenePanic): GeneResult =
  result.status = gsPanic
  result.message = e.msg
  result.hasErrorValue = e.hasErrVal
  if e.hasErrVal:
    result.errorValue = e.errVal

proc cancelResult(e: ref GeneCancel): GeneResult =
  GeneResult(status: gsCancelled, message: e.msg)

proc geneRoot*(value: Value): GeneRoot =
  withRetirementNativeAdmission(true):
    vm.requireNativeRootable(value)
    # A scope-owned Path can contain a held message with a weak back-reference
    # to that scope. A native root outlives the scope's storage, so publish an
    # escaped copy rather than retaining the scope-owned value as-is.
    let rooted = escapeWeakFunctions(value)
    when defined(geneAtomicGenerationRetirementProbe):
      vm.publishNativeRootForRetirement(rooted)
    result = GeneRoot(value: rooted)
    noteNativeRootCreated()

proc geneRootGet*(root: GeneRoot): Value =
  withRetirementNativeAdmission(false):
    if root == nil or root.released:
      raise newException(GeneError, "native root has been released")
    result = root.value

proc geneRootRelease*(root: GeneRoot) =
  withRetirementNativeAdmission(true):
    if root == nil or root.released:
      return
    root.value = NIL
    root.released = true
    noteNativeRootReleased()

proc newGeneIngressSubscription*(handler: Value, scope: Scope,
                                 maxCount = GeneIngressMaxCount,
                                 maxBytes = GeneIngressMaxBytes,
                                 maxPayload = GeneIngressMaxPayload,
                                 unregisterProc: GeneIngressUnregisterProc = nil,
                                 unregisterContext: pointer = nil,
                                 library: Value = NIL):
                                 GeneIngressSubscription =
  requireNativeRootLane(scope)
  if ingressManagedHooks.open == nil:
    raise newException(GeneError,
      "native ingress requires the managed owner adapter")
  ensureIngressWakePipe()
  let id = nextRuntimeResourceId()
  let application = scope.application()
  var managedOwner: RootRef
  try:
    managedOwner = ingressManagedHooks.open(handler, scope, library)
    result = GeneIngressSubscription(id: id,
      context: newGeneIngressContext(id, maxCount, maxBytes, maxPayload),
      application: application,
      ownerLane: currentEventLane(), managedOwner: managedOwner,
      unregisterProc: unregisterProc)
    result.unregisterContext = if unregisterContext == nil:
      cast[pointer](result.context) else: unregisterContext
    result.cleanupLease = nativeNewIoCleanupLease(scope)
    ingressSubscriptions[id] = result
  except CatchableError:
    if result != nil and result.context != nil:
      geneIngressClose(result.context)
      geneIngressConfirmUnregistered(result.context)
      geneIngressDestroy(result.context)
    if result != nil and result.cleanupLease.kind == vkTask:
      discard nativeRetireIoCleanupLease(result.cleanupLease, scope)
    if managedOwner != nil:
      ingressManagedHooks.release(managedOwner)
    if ingressSubscriptions.len == 0:
      closeIngressWakePipe()
    raise

proc settleIngressHandler(subscription: GeneIngressSubscription): bool

proc settleIngressWaiter(subscription: GeneIngressSubscription,
                         waiter: GeneIngressWaiter) =
  case subscription.terminalStatus
  of gsOk:
    discard nativeTaskComplete(waiter.task, NIL, waiter.scope)
  of gsError:
    discard nativeTaskFail(waiter.task, subscription.terminalMessage,
                           scope = waiter.scope)
  of gsPanic:
    discard nativeTaskPanic(waiter.task, subscription.terminalMessage,
                            waiter.scope)
  of gsCancelled:
    discard nativeTaskCancel(waiter.task, waiter.scope)
  discard nativeRetireIoCleanupLease(waiter.lease, waiter.scope)

proc advanceIngressUnregistration(subscription: GeneIngressSubscription) =
  if not subscription.closeRequested or subscription.unregisterProc == nil:
    return
  if subscription.unregisterJob == nil:
    let job = cast[ptr GeneUnregisterJob](
      cMalloc(csize_t(sizeof(GeneUnregisterJob))))
    if job == nil:
      if subscription.terminalStatus == gsOk:
        subscription.terminalStatus = gsError
        subscription.terminalMessage = "native unregister job allocation failed"
      return
    zeroMem(job, sizeof(GeneUnregisterJob))
    job.callback = subscription.unregisterProc
    job.context = subscription.unregisterContext
    subscription.unregisterJob = job
  let job = subscription.unregisterJob
  if not subscription.unregisterQueued:
    try:
      subscription.unregisterQueued = enqueueUnregister(job)
    except CatchableError as error:
      if subscription.terminalStatus == gsOk:
        subscription.terminalStatus = gsError
        subscription.terminalMessage = "native unregister worker: " & error.msg
      return
  if subscription.unregisterQueued and
      atomicLoadN(addr job.done, ATOMIC_ACQUIRE):
    let code = job.code
    cFree(job)
    subscription.unregisterJob = nil
    subscription.unregisterQueued = false
    subscription.unregisterProc = nil
    if code == 0:
      geneIngressConfirmUnregistered(subscription.context)
    else:
      subscription.unregisterFailed = true
      if subscription.terminalStatus == gsOk:
        subscription.terminalStatus = gsError
        subscription.terminalMessage =
          "native unregistration returned " & $code
      for waiter in subscription.waiters:
        subscription.settleIngressWaiter(waiter)
      subscription.waiters.setLen(0)

proc geneIngressReleaseSubscription*(subscription: GeneIngressSubscription) =
  if subscription == nil or subscription.released:
    return
  if subscription.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native subscription release requires the owning lane")
  if subscription.dispatching or not subscription.settleIngressHandler():
    raise newException(GeneError,
      "native subscription handler is still active")
  subscription.advanceIngressUnregistration()
  if subscription.unregisterJob != nil or
      not geneIngressCanRetire(subscription.context):
    raise newException(GeneError,
      "native subscription cannot release before physical retirement")
  subscription.finalContextStats = geneIngressStats(subscription.context)
  ingressManagedHooks.release(subscription.managedOwner)
  subscription.managedOwner = nil
  if subscription.cleanupLease.kind == vkTask:
    discard nativeRetireIoCleanupLease(subscription.cleanupLease)
    subscription.cleanupLease = NIL
  geneIngressDestroy(subscription.context)
  ingressSubscriptions.del(subscription.id)
  if subscription.handleId != 0 and
      atomicLoadN(addr subscription.handleGone, ATOMIC_ACQUIRE):
    withLock ingressHandleLock:
      ingressHandles.del(subscription.handleId)
  if ingressSubscriptions.len == 0:
    stopUnregisterWorker()
    closeIngressWakePipe()
  subscription.context = nil
  subscription.released = true
  for waiter in subscription.waiters:
    subscription.settleIngressWaiter(waiter)
  subscription.waiters.setLen(0)

proc geneIngressRequestCloseSubscription*(
    subscription: GeneIngressSubscription) =
  if subscription == nil or subscription.released or
      subscription.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native subscription close requires the owning lane")
  if not subscription.closeRequested:
    subscription.closeRequested = true
    geneIngressClose(subscription.context)
    ingressManagedHooks.cancel(subscription.managedOwner)
  subscription.advanceIngressUnregistration()

proc geneIngressSubscriptionStatus*(subscription: GeneIngressSubscription):
                                    GeneIngressSubscriptionStatus =
  if subscription == nil or
      subscription.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native subscription status requires a live owning-lane subscription")
  result.context = if subscription.released:
    subscription.finalContextStats
    else: geneIngressStats(subscription.context)
  result.state =
    if subscription.released: "closed"
    elif subscription.closeRequested or result.context.closed: "closing"
    else: "active"
  result.handled = subscription.handled
  result.terminalStatus = subscription.terminalStatus
  result.terminalMessage = subscription.terminalMessage
  result.unregisterPending = subscription.unregisterJob != nil or
    (subscription.closeRequested and subscription.unregisterProc != nil and
     not result.context.unregistered)

proc geneIngressWaitClosed*(subscription: GeneIngressSubscription,
                            callerScope: Scope): Value =
  if subscription == nil or callerScope == nil or
      subscription.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native wait_closed requires an owning-lane subscription and scope")
  if subscription.released or subscription.unregisterFailed:
    result = newExternalTask()
    case subscription.terminalStatus
    of gsOk: discard nativeTaskComplete(result, NIL, callerScope)
    of gsError: discard nativeTaskFail(result,
      subscription.terminalMessage, scope = callerScope)
    of gsPanic: discard nativeTaskPanic(result,
      subscription.terminalMessage, callerScope)
    of gsCancelled: discard nativeTaskCancel(result, callerScope)
    return
  let operation = nativeNewIoOperation(callerScope)
  result = operation.task
  subscription.waiters.add GeneIngressWaiter(task: operation.task,
    lease: operation.cleanupLease, scope: callerScope)

proc newGeneIngressHandle*(subscription: GeneIngressSubscription,
                           scope: Scope): Value =
  if subscription == nil or subscription.released or scope == nil or
      subscription.handleId != 0 or
      subscription.application != scope.application() or
      subscription.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native ingress handle requires its live owning Application")
  result = newRuntimeResourceHandle(scope, "NativeIngressSubscription",
                                    subscription.id)
  subscription.handleId = subscription.id
  subscription.autoRetire = true
  withLock ingressHandleLock:
    ingressHandles[subscription.id] = subscription

proc ingressHandleRecord(value: Value, scope: Scope): GeneIngressSubscription =
  if value.kind != vkNode or value.nodeResourceId == 0 or scope == nil:
    raise newException(GeneError,
      "native ingress operation requires a subscription handle")
  withLock ingressHandleLock:
    result = ingressHandles.getOrDefault(value.nodeResourceId)
  if result == nil or result.application != scope.application() or
      result.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native ingress handle is unavailable on this lane")

proc ingressSymbol(value: Value, label: string): string =
  if value.kind != vkString or value.strVal.len == 0 or
      value.strVal.len > 128 or value.strVal[0] notin
        {'A'..'Z', 'a'..'z', '_'}:
    raise newException(GeneError,
      "native ingress " & label & " must be a C symbol Str")
  for ch in value.strVal:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
      raise newException(GeneError,
        "native ingress " & label & " must be a C symbol Str")
  value.strVal

proc biIngressHandleOpen(args: openArray[Value],
                         call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if scope == nil or args.len != 2 or args[0].kind != vkFfiLibrary or
      args[0].ffiLibraryClosed:
    raise newException(GeneError,
      "native/ingress/open expects an open ffi/Library and handler")
  requireNativeRootLane(scope)
  var registerName, unregisterName = ""
  var maxCount = GeneIngressMaxCount
  var maxBytes = GeneIngressMaxBytes
  var maxPayload = GeneIngressMaxPayload
  var seen = initHashSet[string]()
  for i, name in call[].namedNames:
    if name in seen:
      raise newException(GeneError,
        "duplicate native/ingress/open option: " & name)
    seen.incl name
    let value = call[].namedValues[i]
    case name
    of "register": registerName = ingressSymbol(value, name)
    of "unregister": unregisterName = ingressSymbol(value, name)
    of "max_count", "max_bytes", "max_payload":
      let bound = case name
        of "max_count": GeneIngressMaxCount
        of "max_bytes": GeneIngressMaxBytes
        else: GeneIngressMaxPayload
      if value.kind != vkInt or not value.intFitsInt64 or
          value.intVal < 1 or value.intVal > bound:
        raise newException(GeneError,
          "native ingress limits must be bounded positive Ints")
      case name
      of "max_count": maxCount = int(value.intVal)
      of "max_bytes": maxBytes = int(value.intVal)
      else: maxPayload = int(value.intVal)
    else:
      raise newException(GeneError,
        "unexpected native/ingress/open option: " & name)
  if registerName.len == 0 or unregisterName.len == 0:
    raise newException(GeneError,
      "native/ingress/open requires ^register and ^unregister")
  if maxPayload > maxBytes:
    raise newException(GeneError,
      "native ingress max_payload must not exceed max_bytes")
  let libraryHandle = cast[LibHandle](args[0].ffiLibraryHandle)
  let registration = cast[GeneIngressRegisterProc](symAddr(libraryHandle,
    registerName.cstring))
  let unregistration = cast[GeneIngressUnregisterProc](symAddr(libraryHandle,
    unregisterName.cstring))
  if registration == nil or unregistration == nil:
    raise newException(GeneError,
      "native ingress registration symbols are missing")
  let subscription = newGeneIngressSubscription(args[1], scope,
    maxCount = maxCount, maxBytes = maxBytes, maxPayload = maxPayload,
    unregisterProc = unregistration, library = args[0])
  var api = geneApiIngress()
  var nativeContext: pointer
  let code = registration(addr api, cast[pointer](subscription.context),
                          subscription.id, addr nativeContext)
  if nativeContext == nil:
    subscription.autoRetire = true
    geneIngressRequestCloseSubscription(subscription)
    raise newException(GeneError,
      "native registration returned no unregister context")
  subscription.unregisterContext = nativeContext
  if code != 0:
    subscription.autoRetire = true
    geneIngressRequestCloseSubscription(subscription)
    raise newException(GeneError,
      "native registration returned " & $code)
  try:
    result = newGeneIngressHandle(subscription, scope)
  except CatchableError:
    subscription.autoRetire = true
    geneIngressRequestCloseSubscription(subscription)
    raise

proc biIngressHandleClose(args: openArray[Value],
                          call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raise newException(GeneError,
      "NativeIngressSubscription.close expects one receiver")
  let subscription = ingressHandleRecord(args[0], scope)
  if not subscription.released:
    geneIngressRequestCloseSubscription(subscription)
  NIL

proc biIngressHandleWaitClosed(args: openArray[Value],
                               call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raise newException(GeneError,
      "NativeIngressSubscription.wait_closed expects one receiver")
  geneIngressWaitClosed(ingressHandleRecord(args[0], scope), scope)

proc biIngressHandleStatus(args: openArray[Value],
                           call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raise newException(GeneError,
      "NativeIngressSubscription.status expects one receiver")
  let status = geneIngressSubscriptionStatus(
    ingressHandleRecord(args[0], scope))
  var fields = initPropTable()
  fields["state"] = newStr(status.state)
  fields["received"] = newInt(int64(status.context.received))
  fields["delivered"] = newInt(int64(status.context.delivered))
  fields["handled"] = newInt(int64(status.handled))
  fields["rejected"] = newInt(int64(status.context.rejected))
  fields["discarded"] = newInt(int64(status.context.discarded))
  fields["queued_count"] = newInt(status.context.queuedCount)
  fields["queued_bytes"] = newInt(status.context.queuedBytes)
  fields["in_flight"] = newInt(status.context.inFlight)
  fields["first_failure"] = newInt(status.context.firstFailure)
  fields["terminal_kind"] = newStr($status.terminalStatus)
  fields["terminal_message"] = newStr(status.terminalMessage)
  fields["unregister_pending"] = newBool(status.unregisterPending)
  newMap(fields)

proc releaseIngressHandleRecord(id: uint64) {.nimcall, raises: [].} =
  var retired: GeneIngressSubscription
  withLock ingressHandleLock:
    let subscription = ingressHandles.getOrDefault(id)
    if subscription != nil:
      atomicStoreN(addr subscription.handleGone, true, ATOMIC_RELEASE)
      if subscription.released:
        discard ingressHandles.pop(id, retired)
  reset(retired)

proc geneCall*(callee: Value, call: GeneCall): GeneResult =
  try:
    result.status = gsOk
    result.value = vm.call(callee, call.args, call.namedNames, call.namedValues,
                           call.dispatchScope, call.site)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)
  except GeneCancel as e:
    result = cancelResult(e)

proc failIngressHandler(subscription: GeneIngressSubscription,
                        status: GeneStatus, message: string) =
  if subscription.terminalStatus == gsOk:
    subscription.terminalStatus = status
    subscription.terminalMessage = message
  subscription.geneIngressRequestCloseSubscription()

proc settleIngressHandler(subscription: GeneIngressSubscription): bool =
  let settled = ingressManagedHooks.settle(subscription.managedOwner)
  if settled.pending:
    return false
  if settled.completed:
    case settled.status
    of gsOk: inc subscription.handled
    of gsCancelled:
      if not subscription.closeRequested:
        subscription.failIngressHandler(gsCancelled,
          "native notification handler was cancelled")
    else:
      subscription.failIngressHandler(settled.status, settled.message)
  true

proc geneIngressPollSubscription*(subscription: GeneIngressSubscription,
                                  budget = 32): int =
  if subscription == nil or subscription.released or
      subscription.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native ingress poll requires a live owning-lane subscription")
  if subscription.dispatching or budget <= 0:
    return
  subscription.advanceIngressUnregistration()
  let stats = geneIngressStats(subscription.context)
  if stats.firstFailure != 0 and
      (stats.firstFailure != GeneIngressClosed or
       not subscription.closeRequested):
    subscription.failIngressHandler(gsError,
      "native ingress rejected notification: " & $stats.firstFailure)
  if not subscription.settleIngressHandler():
    return
  if subscription.closeRequested or stats.closed:
    return
  while result < min(32, budget):
    var payload = ""
    if not geneIngressPop(subscription.context, payload):
      break
    inc result
    subscription.dispatching = true
    var called: GeneIngressManagedResult
    try:
      called = ingressManagedHooks.dispatch(subscription.managedOwner, payload)
    except GenePanic as error:
      called = GeneIngressManagedResult(status: gsPanic, message: error.msg)
    except GeneCancel as error:
      called = GeneIngressManagedResult(status: gsCancelled, message: error.msg)
    except CatchableError as error:
      called = GeneIngressManagedResult(status: gsError, message: error.msg)
    finally:
      subscription.dispatching = false
    if subscription.released:
      break
    if called.status != gsOk:
      if called.status != gsCancelled or not subscription.closeRequested:
        subscription.failIngressHandler(called.status, called.message)
      break
    if called.pending:
      if subscription.closeRequested:
        ingressManagedHooks.cancel(subscription.managedOwner)
      if not subscription.settleIngressHandler():
        break
      if subscription.closeRequested:
        break
    elif called.completed:
      inc subscription.handled

proc pollGeneIngressSubscriptions(scheduler: SchedulerState) {.nimcall.} =
  if ingressPollActive or ingressSubscriptions.len == 0:
    return
  ingressPollActive = true
  try:
    var ids: seq[uint64]
    for id in ingressSubscriptions.keys:
      ids.add id
    ids.sort()
    if ids.len == 0: return
    let start = int(ingressPollCursor mod uint64(ids.len))
    inc ingressPollCursor
    var remaining = 32
    for offset in 0 ..< ids.len:
      if remaining <= 0: break
      let id = ids[(start + offset) mod ids.len]
      if not ingressSubscriptions.hasKey(id): continue
      let subscription = ingressSubscriptions[id]
      if subscription.ownerLane != currentEventLane() or
          subscription.released or subscription.managedOwner == nil or
          not schedulerOwnsApplication(scheduler, subscription.application):
        continue
      if subscription.autoRetire and
          atomicLoadN(addr subscription.handleGone, ATOMIC_ACQUIRE) and
          not subscription.closeRequested:
        geneIngressRequestCloseSubscription(subscription)
      remaining -= geneIngressPollSubscription(subscription,
        min(4, remaining))
      if subscription.autoRetire and subscription.closeRequested and
          not subscription.dispatching and
          geneIngressCanRetire(subscription.context):
        if subscription.settleIngressHandler():
          geneIngressReleaseSubscription(subscription)
  finally:
    ingressPollActive = false

proc hasGeneIngressSubscriptions(scheduler: SchedulerState): bool {.nimcall.} =
  for subscription in ingressSubscriptions.values:
    if not subscription.released and
        schedulerOwnsApplication(scheduler, subscription.application):
      return true

installNativeIngressPollHook(pollGeneIngressSubscriptions)
installNativeIngressSleepHook(waitIngressWake)
installNativeIngressActiveHook(hasGeneIngressSubscriptions)
installNativeIngressAdapter(NativeIngressAdapter(
  open: biIngressHandleOpen,
  close: biIngressHandleClose,
  waitClosed: biIngressHandleWaitClosed,
  status: biIngressHandleStatus))
installNativeIngressHandleReleaseHook(releaseIngressHandleRecord)

proc newGeneModule*(name: string, path = "",
                    scope: Scope = nil): GeneModule =
  withRetirementNativeAdmission(true):
    let moduleScope =
      if scope == nil: newGlobalScope()
      else: scope
    let moduleValue = bindThisModule(moduleScope, name, path)
    when defined(geneAtomicGenerationRetirementProbe):
      vm.publishNativeScopeForRetirement(moduleScope)
    result = GeneModule(value: moduleValue, scope: moduleScope)

proc geneModuleValue*(module: GeneModule): Value =
  withRetirementNativeAdmission(true):
    if module == nil:
      raise newException(GeneError, "native module is nil")
    when defined(geneAtomicGenerationRetirementProbe):
      vm.publishNativeRootForRetirement(module.value)
    result = module.value

proc geneModuleScope*(module: GeneModule): Scope =
  withRetirementNativeAdmission(true):
    if module == nil:
      raise newException(GeneError, "native module is nil")
    when defined(geneAtomicGenerationRetirementProbe):
      vm.publishNativeScopeForRetirement(module.scope)
    result = module.scope

proc geneModuleDefine*(module: GeneModule, name: string,
                       value: Value): GeneResult =
  try:
    withRetirementNativeAdmission(true):
      when defined(geneAtomicGenerationRetirementProbe):
        vm.publishNativeRootForRetirement(value)
      module.geneModuleScope.define(name, value)
      result.status = gsOk
      result.value = value
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneModuleDefineNative*(module: GeneModule, name: string,
                             impl: NativeProc): GeneResult =
  geneModuleDefine(module, name, newNativeFn(name, impl))

proc geneModuleDefineNativeCall*(module: GeneModule, name: string,
                                 impl: NativeCallProc,
                                 acceptsNamed: bool): GeneResult =
  geneModuleDefine(module, name,
                   newNativeCallFn(name, impl, acceptsNamed = acceptsNamed))

proc geneDefineWrapperType*(module: GeneModule, name: string,
                            fields: openArray[GeneWrapperField]): GeneResult =
  ## Define a **wrapper type**: a nominal Gene type marked `^repr
  ## native_wrapper`, for native values whose payload is an opaque pointer.
  ##
  ## The marker is the safety mechanism. It makes every ordinary construction
  ## path — `(T ...)`, `construct_type`, serde, functional update, node
  ## literals — reject the type, and it makes the declared props
  ## initializer-only, so Gene code can neither forge an instance nor overwrite
  ## a handle with a `Str` that the next native call would read as a pointer.
  ## The schema is now free to describe the real fields: `geneNewWrapper`
  ## validates against it, which is why declaring one no longer makes the props
  ## forgeable. This is the same representation a Gene-side
  ## `(type T ^repr native_wrapper ...)` declaration produces.
  try:
    if name.len == 0:
      raise newException(GeneError, "wrapper type requires a name")
    let scope = geneModuleScope(module)
    if scope == nil:
      raise newException(GeneError, "wrapper type requires a module scope")
    var schema: seq[TypeField]
    for field in fields:
      if field.name.len == 0:
        raise newException(GeneError, "wrapper field requires a name")
      # Leave `scope` nil: newType installs the ordinary *weak* defining scope.
      # A strong field scope would close a Scope → Type → field.scope → Scope
      # cycle that the collector cannot see, so every discarded native module
      # would leak its scope.
      schema.add TypeField(name: field.name, optional: field.optional,
                           typeExpr: field.typeExpr)
    let typ = newType(name, NIL, schema, @[], scope,
                      repr = trNativeWrapper)
    result = geneModuleDefine(module, name, typ)
    if result.status == gsOk:
      result.value = typ
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewWrapper*(wrapperType: Value,
                     props: openArray[(string, Value)]): GeneResult =
  ## Instantiate a wrapper type with native-owned props, for extensions that
  ## cannot or do not want to express construction as a Gene `ctor`. It
  ## requires a `native_wrapper` type and validates the declared schema, so
  ## native-built and ctor-built instances satisfy the same invariant.
  try:
    result.status = gsOk
    result.value = vm.newNativeWrapper(wrapperType, props)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneWrapperField*(instance, wrapperType: Value,
                       name: string): GeneResult =
  ## Read a native-owned prop back, checking the instance really is one of
  ## `wrapperType`. Native code must not trust a caller-supplied value's head:
  ## the nominal check is what stops a look-alike node reaching a pointer
  ## dereference, and it mirrors the in-tree `dbConnHandleValue` guard.
  try:
    if wrapperType.kind != vkType:
      raise newException(GeneError, "geneWrapperField expects a Type")
    # Compare Type *identity*, never the name. Two modules may each define a
    # `Conn`, and a name check would let one module's wrapper carry its pointer
    # into the other's native code — which then dereferences memory it does not
    # own. Ancestry, not leaf equality: a Gene-side subtype inherits the
    # wrapper rule (design §16.6), so it is a legitimate receiver here; a leaf
    # check would accept the parent and reject its own subtype.
    if instance.kind != vkNode or
        not instance.head.typeInheritsFrom(wrapperType):
      raise newException(GeneError,
        "expected a " & wrapperType.typeName & " value")
    result.status = gsOk
    result.value = instance.props.getOrDefault(name, VOID)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewCPtr*(address: pointer, targetType: Value): Value =
  newCPtr(address, targetType)

proc geneNewCConstPtr*(address: pointer, targetType: Value): Value =
  newCConstPtr(address, targetType)

proc geneNewCOwnedPtr*(address: pointer, release: CPtrReleaseProc,
                       targetType: Value): Value =
  newCOwnedPtr(address, release, targetType)

proc geneCloseCPtr*(value: Value): GeneResult =
  try:
    value.closeCPtr()
    result.status = gsOk
    result.value = NIL
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewCSlice*(address: pointer, length: int, targetType: Value): Value =
  newCSlice(address, length, targetType)

proc geneNewBuffer*(elemType: Value, items: seq[Value],
                    scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value = newCheckedBuffer(elemType, items, scope)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneBufferLen*(buffer: Value): GeneResult =
  try:
    if buffer.kind != vkBuffer:
      raise newException(GeneError, "Buffer/len expects a Buffer")
    result.status = gsOk
    result.value = newInt(buffer.bufferLen)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneBufferGet*(buffer: Value, index: int): GeneResult =
  try:
    result.status = gsOk
    result.value = getCheckedBufferItem(buffer, index)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneBufferSet*(buffer: Value, index: int, item: Value,
                    scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value = setCheckedBufferItem(buffer, index, item, scope)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneChannelTrySend*(channel: Value, item: GeneRoot,
                         scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeChannelTrySend(channel, geneRootGet(item), scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneChannelTryRecv*(channel: Value, scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value = vm.nativeChannelTryRecv(channel, scope)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneActorTrySend*(actor: Value, message: GeneRoot,
                       scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeActorTrySend(actor, geneRootGet(message), scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewAsyncTask*(): Value =
  vm.nativeNewAsyncTask()

proc geneTaskComplete*(task: Value, value: GeneRoot,
                       scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeTaskComplete(task, geneRootGet(value), scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneTaskFail*(task: Value, message: string, value: GeneRoot,
                   hasValue: bool, scope: Scope): GeneResult =
  try:
    result.status = gsOk
    let errValue =
      if hasValue: geneRootGet(value)
      else: NIL
    result.value =
      if vm.nativeTaskFail(task, message, errValue, hasValue, scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneTaskCancel*(task: Value, scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeTaskCancel(task, scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewCallback*(callee: Value): GeneCallbackHandle =
  GeneCallbackHandle(callee: geneRoot(callee), ownerThreadId: getThreadId())

proc geneCallCallback*(callback: GeneCallbackHandle,
                       call: GeneCall): GeneResult =
  try:
    if callback == nil:
      result.status = gsError
      result.message = "native callback has been released"
      return
    if callback.ownerThreadId != getThreadId():
      result.status = gsError
      result.message = "native callback belongs to another lane"
      return
    if callback.released:
      result.status = gsError
      result.message = "native callback has been released"
      return
    if geneThreadAttachDepth <= 0:
      result.status = gsError
      result.message = "native thread is not attached"
      return
    if callback.active:
      result.status = gsError
      result.message = "synchronous native callback re-entry is not supported"
      return
    callback.active = true
    try:
      let callee = geneRootGet(callback.callee)
      let scope = if call.dispatchScope != nil: call.dispatchScope
                  elif callee.kind == vkFunction: callee.fnScope
                  else: nil
      let frame = newNativeSyncCallback(callee, scope)
      beginNativeCallbackCall(frame)
      withNativeSyncCallback(frame):
        result.value = invokeNativeSyncCallback(frame, call.args,
          call.namedNames, call.namedValues, call.site)
        result.status = gsOk
      finishNativeCallbackCall(frame)
    finally:
      callback.active = false
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)
  except GeneCancel as e:
    result = cancelResult(e)

proc geneReleaseCallback*(callback: GeneCallbackHandle) =
  if callback == nil: return
  if callback.ownerThreadId != getThreadId():
    raise newException(GeneError, "native callback belongs to another lane")
  if callback.released: return
  if callback.active:
    raise newException(GeneError, "cannot release an executing native callback")
  geneRootRelease(callback.callee)
  callback.released = true

proc geneAttachThread*(): GeneThreadAttachment =
  inc geneThreadAttachDepth
  GeneThreadAttachment(ownerThreadId: getThreadId())

proc geneDetachThread*(attachment: GeneThreadAttachment) =
  if attachment == nil or attachment.released:
    return
  if attachment.ownerThreadId != getThreadId() or geneThreadAttachDepth <= 0:
    return
  dec geneThreadAttachDepth
  attachment.released = true

proc geneThreadAttached*(): bool =
  geneThreadAttachDepth > 0

proc geneApiIngress*(): GeneApi =
  ## The ingress-only view uses the same C layout as managed modules. Native
  ## registrations may retain this table by value, but only its feature bit is
  ## available; the context remains owned by the subscription.
  GeneApi(version: GeneApiVersion,
    structSize: uint32(sizeof(GeneApi)),
    featureBits: GeneApiIngressFeature,
    ingressBegin: geneIngressBegin,
    ingressEnqueue: geneIngressEnqueue,
    ingressEnd: geneIngressEnd)
