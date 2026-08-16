## Runtime event production — `gene/runtime` (docs/proposals/events.md §10-§13,
## §19, §20).
##
## Two rules shape everything here, and they are the two the proposal calls
## central:
##
##   * **A disabled category costs one predictable mask check.** The check reads
##     a process-global `uint32`, not a field behind a heap traversal, and the
##     record it guards is built only on the taken branch — no `Value`, no
##     string, no clock read, no queue write when the bit is clear.
##   * **The VM never invokes a Gene handler from an emission site.** Emission
##     writes a fixed-size native record into a bounded queue. A separate
##     adapter materializes Gene values and calls `EventSink:emit`, and only at
##     a safe point.
##
## Version 1 is one producer and one queue (§22 phase 2 step 2), and the
## instrumented categories are `lifecycle`, `module`, and `task` (step 3).
## `actor`, `gc`, `call`, `allocation`, and `instruction` are accepted by the
## configuration parser and produce nothing yet; `capability` is reserved and
## cannot be implemented until capabilities.md defines its event shapes (§10.2).

# ---------------------------------------------------------------------------
# The disabled-path gate
# ---------------------------------------------------------------------------

var gRuntimeEventMask: uint32 = 0
  ## The enabled category bits, where the VM can read them without a heap
  ## traversal on each event site (§17.1). Zero — the default — is the whole
  ## disabled path: one load, one and, one branch not taken.

var gRuntimeEventStream: RuntimeEventStreamData = nil
  ## The process's stream, or nil. Version 1 fixes the configuration when the
  ## runtime is created (§10.3), so this is written once by
  ## `configureRuntimeEvents` and never reconfigured behind a running program.

template categoryBit(category: RuntimeEventCategory): uint32 =
  1'u32 shl uint32(ord(category))

template runtimeEventEnabled*(category: RuntimeEventCategory): bool =
  (gRuntimeEventMask and categoryBit(category)) != 0

proc runtimeEventCategoryName*(category: RuntimeEventCategory): string =
  case category
  of recLifecycle: "lifecycle"
  of recModule: "module"
  of recTask: "task"
  of recActor: "actor"
  of recCapability: "capability"
  of recGc: "gc"
  of recCall: "call"
  of recAllocation: "allocation"
  of recInstruction: "instruction"

proc runtimeEventCategoryFromName*(name: string):
    tuple[known: bool, category: RuntimeEventCategory] =
  for category in RuntimeEventCategory:
    if runtimeEventCategoryName(category) == name:
      return (true, category)
  (false, recLifecycle)

const defaultRuntimeEventCategories* = {recLifecycle, recModule, recTask,
                                        recActor, recGc}
  ## What `^runtime_events true` normalizes to (§10.2) — the documented default
  ## set, deliberately not every category: `call`, `allocation`, and
  ## `instruction` are high-frequency and require explicit selection, and
  ## `capability` joins only once its event shapes exist.

const implementedRuntimeEventCategories* = {recLifecycle, recModule, recTask}
  ## The categories that currently have emission sites. Selecting one of the
  ## others is accepted and simply produces no records; it is a configuration
  ## the program may already be written against, not an error.

const defaultRuntimeEventBufferCapacity* = 1024

proc categoryMaskOf*(categories: set[RuntimeEventCategory]): uint32 =
  for category in categories:
    result = result or categoryBit(category)

# ---------------------------------------------------------------------------
# The bounded queue (§12.1, §12.2)
# ---------------------------------------------------------------------------

proc pushRuntimeRecord(stream: RuntimeEventStreamData,
                       record: var RuntimeEventRecord) =
  ## Drop-oldest, deliberately (§12.2). A queue overflows exactly when the
  ## runtime is producing faster than the consumer drains — around a stall, a
  ## cascade of failures, or a crash — and there the records adjacent to the
  ## failure are the ones worth keeping. Dropping the incoming record would
  ## preserve whatever happened to be in the buffer first, which for the
  ## diagnostic uses in §1 is the least useful window.
  let queue = stream.queue
  inc queue.nextSequence
  record.sequence = queue.nextSequence
  record.producerId = stream.producerId
  inc stream.produced
  if queue.count == queue.capacity:
    let victimSequence = queue.records[queue.head].sequence
    if queue.dropped == 0:
      queue.firstDroppedSequence = victimSequence
    queue.lastDroppedSequence = victimSequence
    inc queue.dropped
    inc stream.dropped
    queue.records[queue.head] = record
    queue.head = (queue.head + 1) mod queue.capacity
  else:
    queue.records[(queue.head + queue.count) mod queue.capacity] = record
    inc queue.count

proc popRuntimeRecord(queue: RuntimeEventQueue): RuntimeEventRecord =
  result = queue.records[queue.head]
  queue.head = (queue.head + 1) mod queue.capacity
  dec queue.count

proc internRuntimeName(stream: RuntimeEventStreamData, name: string): int32 =
  ## Names and source locations travel as stable interned ids, never as strings
  ## in the record (§11.1). The consumer resolves them while materializing.
  stream.internedIds.withValue(name, existing):
    return existing[]
  result = int32(stream.internedNames.len)
  stream.internedNames.add name
  stream.internedIds[name] = result

proc internedRuntimeName(stream: RuntimeEventStreamData, id: int64): string =
  if id >= 0 and id < stream.internedNames.len:
    stream.internedNames[int(id)]
  else:
    ""

# ---------------------------------------------------------------------------
# Emission (§11.1)
# ---------------------------------------------------------------------------

var gRuntimeTaskTraceCounter: int64 = 0

proc nextRuntimeTaskTraceId*(): int64 =
  ## Task correlation ids are handed out only while the `task` category is on,
  ## so an uninstrumented run never pays for the counter.
  inc gRuntimeTaskTraceCounter
  gRuntimeTaskTraceCounter

proc emitRuntimeRecord(kind: RuntimeEventKind, fieldA = 0'i64,
                       fieldB = 0'i64, fieldC = 0'i64, flags = 0'u32) =
  ## The slow half of an enabled site. Callers must have checked the category
  ## bit first; this never checks it again, and it is `noinline` so the check at
  ## the call site stays a branch over a call rather than an inlined body.
  let stream = gRuntimeEventStream
  if stream == nil:
    return
  var record = RuntimeEventRecord(kind: kind, flags: flags,
                                  fieldA: fieldA, fieldB: fieldB,
                                  fieldC: fieldC)
  if stream.includeTimestamps:
    record.timeNs = inNanoseconds(getMonoTime() - stream.epoch)
  pushRuntimeRecord(stream, record)

template runtimeEvent*(category: RuntimeEventCategory, body: untyped) =
  ## The whole disabled path. Everything that could allocate, read a clock, or
  ## touch the queue lives inside `body`, on the taken branch only.
  if runtimeEventEnabled(category):
    body

proc emitRuntimeModuleEvent*(kind: RuntimeEventKind, path: string,
                             durationNs: int64 = 0) =
  let stream = gRuntimeEventStream
  if stream == nil:
    return
  # Interning happens here rather than at the call site so a disabled category
  # never reaches the table at all.
  let moduleId = internRuntimeName(stream, path)
  emitRuntimeRecord(kind, int64(moduleId), durationNs)

proc emitRuntimeTaskEvent*(kind: RuntimeEventKind, taskTraceId: int64,
                           durationNs: int64 = 0) =
  emitRuntimeRecord(kind, taskTraceId, durationNs)

proc emitRuntimeLifecycleEvent*(kind: RuntimeEventKind) =
  emitRuntimeRecord(kind)

# ---------------------------------------------------------------------------
# Materialization (§11.2)
# ---------------------------------------------------------------------------

proc runtimeNamespaceMember(scope: Scope, path: openArray[string]): Value =
  ## Walk `runtime/...` by name once, at attach time. Nothing on the drain path
  ## resolves names — the types are cached on the stream.
  var current = builtinBinding(scope, "runtime")
  for segment in path:
    if current.kind != vkNamespace:
      return NIL
    let next = exportedBinding(current, segment)
    if next.kind == vkVoid:
      return NIL
    current = next
  current

proc runtimeEventTypeFor(scope: Scope, kind: RuntimeEventKind): Value =
  case kind
  of rekRuntimeStarted: runtimeNamespaceMember(scope, ["lifecycle", "Started"])
  of rekRuntimeStopping: runtimeNamespaceMember(scope, ["lifecycle", "Stopping"])
  of rekRuntimeStopped: runtimeNamespaceMember(scope, ["lifecycle", "Stopped"])
  of rekModuleLoadStarted: runtimeNamespaceMember(scope, ["module", "LoadStarted"])
  of rekModuleLoaded: runtimeNamespaceMember(scope, ["module", "Loaded"])
  of rekModuleFailed: runtimeNamespaceMember(scope, ["module", "Failed"])
  of rekTaskSpawned: runtimeNamespaceMember(scope, ["task", "Spawned"])
  of rekTaskCompleted: runtimeNamespaceMember(scope, ["task", "Completed"])
  of rekTaskFailed: runtimeNamespaceMember(scope, ["task", "Failed"])
  of rekTaskCancelled: runtimeNamespaceMember(scope, ["task", "Cancelled"])

proc cacheRuntimeEventTypes(stream: RuntimeEventStreamData, scope: Scope) =
  if stream.typesCached:
    return
  for kind in RuntimeEventKind:
    stream.eventTypes[kind] = runtimeEventTypeFor(scope, kind)
  stream.droppedType = runtimeNamespaceMember(scope, ["EventsDropped"])
  stream.typesCached = true

proc materializeRuntimeEvent(stream: RuntimeEventStreamData,
                             record: RuntimeEventRecord): Value =
  ## Build the frozen public value. `^producer_id` and `^sequence` describe the
  ## observing context; a concrete event's own subject gets its own
  ## specifically-named field (§11.2), which is why a task event carries
  ## `^completed_task_id` rather than overloading the inherited `^task_id`.
  let typ = stream.eventTypes[record.kind]
  if typ.kind != vkType:
    return NIL
  var props = initPropTable()
  props["producer_id"] = newInt(record.producerId)
  props["sequence"] = newInt(record.sequence)
  if stream.includeTimestamps:
    props["time_ns"] = newInt(record.timeNs)
  case record.kind
  of rekRuntimeStarted, rekRuntimeStopping, rekRuntimeStopped:
    discard
  of rekModuleLoadStarted:
    props["module_id"] = newInt(record.fieldA)
    props["module_name"] = newStr(internedRuntimeName(stream, record.fieldA))
  of rekModuleLoaded, rekModuleFailed:
    props["module_id"] = newInt(record.fieldA)
    props["module_name"] = newStr(internedRuntimeName(stream, record.fieldA))
    if record.fieldB > 0:
      props["duration_ns"] = newInt(record.fieldB)
  of rekTaskSpawned:
    props["spawned_task_id"] = newInt(record.fieldA)
  of rekTaskCompleted:
    props["completed_task_id"] = newInt(record.fieldA)
  of rekTaskFailed:
    props["failed_task_id"] = newInt(record.fieldA)
  of rekTaskCancelled:
    props["cancelled_task_id"] = newInt(record.fieldA)
  # Constructed deep-frozen: the props are scalars, so the composed invariant
  # holds by construction and `publish` takes its O(1) already-frozen path
  # rather than copying the payload again (events.md §6.5, §17.3).
  newNode(typ, props = props, immutable = true, deepFrozen = true)

proc materializeDroppedSummary(stream: RuntimeEventStreamData): Value =
  let typ = stream.droppedType
  if typ.kind != vkType:
    return NIL
  let queue = stream.queue
  inc queue.nextSequence
  var props = initPropTable()
  props["producer_id"] = newInt(stream.producerId)
  props["sequence"] = newInt(queue.nextSequence)
  props["dropped_producer_id"] = newInt(stream.producerId)
  props["dropped_count"] = newInt(queue.dropped)
  props["first_dropped_sequence"] = newInt(queue.firstDroppedSequence)
  props["last_dropped_sequence"] = newInt(queue.lastDroppedSequence)
  newNode(typ, props = props, immutable = true, deepFrozen = true)

# ---------------------------------------------------------------------------
# Safe-point draining (§12.3, §12.4)
# ---------------------------------------------------------------------------

proc drainRuntimeEvents*(scope: Scope): int {.discardable.} =
  ## Read records, resolve interned ids, create and freeze the public value,
  ## emit it to the attached sink, and — crucially — catch anything `emit`
  ## raises, count it, and keep draining without changing the observed
  ## operation's result (§12.3 step 5).
  ##
  ## `stats` is the only channel through which a program learns that its
  ## observers are broken, which is why `EventSink:emit` has to surface handler
  ## failures rather than absorb them (§7.2).
  let stream = gRuntimeEventStream
  if stream == nil or stream.draining or stream.sink.kind == vkNil:
    return 0
  let queue = stream.queue
  if queue.count == 0 and queue.dropped == 0:
    return 0
  let sinkScope = if stream.attachScope != nil: stream.attachScope else: scope
  cacheRuntimeEventTypes(stream, sinkScope)
  # §12.4: instrumentation is suppressed while the adapter invokes observers.
  # Without it, observing a call would make another call, which would produce
  # another event, indefinitely. Application publication through `event/Bus` is
  # not suppressed — only runtime instrumentation generated by observer
  # dispatch.
  stream.draining = true
  let savedMask = gRuntimeEventMask
  gRuntimeEventMask = 0
  try:
    if queue.dropped > 0:
      # Synthesized by the consumer, not inserted recursively through the queue
      # (§12.2). It goes first because drop-oldest lost records that preceded
      # everything still buffered.
      let summary = materializeDroppedSummary(stream)
      queue.dropped = 0
      queue.firstDroppedSequence = 0
      queue.lastDroppedSequence = 0
      if summary.kind != vkNil:
        try:
          discard emitToSink(sinkScope, stream.sink, summary)
          inc stream.delivered
          inc result
        except GeneError:
          inc stream.sinkFailures
    while queue.count > 0:
      let record = popRuntimeRecord(queue)
      let event = materializeRuntimeEvent(stream, record)
      if event.kind == vkNil:
        continue
      try:
        discard emitToSink(sinkScope, stream.sink, event)
        inc stream.delivered
        inc result
      except GeneError:
        inc stream.sinkFailures
  finally:
    gRuntimeEventMask = savedMask
    stream.draining = false

proc drainRuntimeEventsAtSafePoint*(scope: Scope) {.inline.} =
  ## The guard every in-VM safe point shares: nothing to do unless a stream
  ## exists, a sink is attached, and there is something buffered.
  let stream = gRuntimeEventStream
  if stream == nil or stream.draining or stream.sink.kind == vkNil:
    return
  if stream.queue.count == 0 and stream.queue.dropped == 0:
    return
  discard drainRuntimeEvents(scope)

# ---------------------------------------------------------------------------
# Configuration (§10.1)
# ---------------------------------------------------------------------------

proc configureRuntimeEvents*(categories: set[RuntimeEventCategory],
                             bufferCapacity = defaultRuntimeEventBufferCapacity,
                             includeTimestamps = true): Value {.discardable.} =
  ## Create the process's runtime event stream. Version 1 fixes the category
  ## configuration here (§10.3): predictable overhead, one queue provisioning,
  ## no races while changing instrumentation, reproducible tests.
  if categories.card == 0:
    gRuntimeEventMask = 0
    gRuntimeEventStream = nil
    return NIL
  let capacity = max(1, bufferCapacity)
  let stream = newRuntimeEventStreamData(categoryMaskOf(categories), capacity,
                                         includeTimestamps)
  gRuntimeEventStream = stream
  gRuntimeEventMask = stream.categoryMask
  result = boxRuntimeEventStream(stream)
  runtimeEvent(recLifecycle):
    emitRuntimeLifecycleEvent(rekRuntimeStarted)

proc runtimeEventStreamValue*(): Value =
  if gRuntimeEventStream == nil: NIL
  else: boxRuntimeEventStream(gRuntimeEventStream)

proc shutdownRuntimeEvents*(scope: Scope) =
  ## Orderly shutdown drains already-produced records (§12.3, §23). The two
  ## lifecycle records are emitted around the final drain so a consumer sees
  ## `Stopping` with the rest of the trace and `Stopped` as the last record.
  let stream = gRuntimeEventStream
  if stream == nil:
    return
  runtimeEvent(recLifecycle):
    emitRuntimeLifecycleEvent(rekRuntimeStopping)
  discard drainRuntimeEvents(scope)
  runtimeEvent(recLifecycle):
    emitRuntimeLifecycleEvent(rekRuntimeStopped)
  discard drainRuntimeEvents(scope)

# ---------------------------------------------------------------------------
# Gene surface
# ---------------------------------------------------------------------------

proc requireEventStream(scope: Scope, value: Value, op: string):
    RuntimeEventStreamData =
  if value.kind != vkEventStream:
    raiseEventError(scope, "RuntimeEventsDisabled",
      op & " expects a runtime/EventStream")
  eventStreamData(value)

proc biRuntimeStreamAttach(args: openArray[Value], call: ptr NativeCall): Value
                          {.nimcall.} =
  ## §13: a stream accepts one effective sink in version 1. Fan-out belongs in
  ## `event/CompositeSink`; replacing a sink is an explicit detach and attach.
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 2:
    raise newException(GeneError,
      "EventStream/attach expects one sink, got " & $(args.len - 1))
  let stream = requireEventStream(scope, args[0], "attach")
  if stream.sink.kind != vkNil:
    raiseEventError(scope, "RuntimeEventAttachError",
      "a runtime/EventStream accepts one sink; detach the current one first")
  let sink = args[1]
  if sink.kind notin EventSinkKinds and sink.kind != vkNode:
    raiseEventError(scope, "RuntimeEventAttachError",
      "attach expects a value implementing EventSink",
      {"actual_value": sink})
  var replay = true
  if call != nil:
    for i, name in call.namedNames:
      case name
      of "replay_buffer":
        let v = call.namedValues[i]
        if v.kind != vkBool:
          raiseEventError(scope, "RuntimeEventConfigError",
            "^replay_buffer expects a Bool")
        replay = v.boolVal
      else:
        raiseEventError(scope, "RuntimeEventConfigError",
          "attach does not accept ^" & name)
  let queue = stream.queue
  let droppedBefore = queue.dropped
  let firstBuffered =
    if queue.count > 0: queue.records[queue.head].sequence else: 0'i64
  var replayed = 0
  if not replay:
    # Start with the next record: discard what the queue already holds, but
    # keep the dropped span so `dropped_before_attach` still reports it.
    queue.head = 0
    queue.count = 0
  stream.sink = sink
  stream.attachScope = scope
  if replay:
    # Replay is best-effort and bounded by `buffer_capacity` (§13). Nothing
    # drained the queue before this point, so a startup that produced more
    # records than the buffer holds already lost its earliest ones, and the
    # caller is told exactly how many.
    replayed = drainRuntimeEvents(scope)
  var props = initPropTable()
  props["replayed_count"] = newInt(replayed)
  props["dropped_before_attach"] = newInt(droppedBefore)
  if firstBuffered > 0:
    props["first_replayed_sequence"] = newInt(firstBuffered)
  var head = newSym("AttachResult")
  let declared = runtimeNamespaceMember(scope, ["AttachResult"])
  if declared.kind == vkType:
    head = declared
  newNode(head, props = props)

proc biRuntimeStreamDetach(args: openArray[Value], call: ptr NativeCall): Value
                          {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "EventStream/detach takes no arguments")
  let stream = requireEventStream(scope, args[0], "detach")
  if stream.sink.kind == vkNil:
    return FALSE
  stream.sink = NIL
  stream.attachScope = nil
  TRUE

proc biRuntimeStreamFlush(args: openArray[Value], call: ptr NativeCall): Value
                         {.nimcall.} =
  ## Drains records already emitted. It does not wait for unrelated tasks to
  ## finish (§14.4).
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "EventStream/flush takes no arguments")
  discard requireEventStream(scope, args[0], "flush")
  newInt(drainRuntimeEvents(scope))

proc biRuntimeStreamStats(args: openArray[Value], call: ptr NativeCall): Value
                         {.nimcall.} =
  ## A cheap immutable snapshot (§19). Diagnostic, and may race with active
  ## producers; each field is memory-safe on its own.
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "EventStream/stats takes no arguments")
  let stream = requireEventStream(scope, args[0], "stats")
  var props = initPropTable()
  props["produced"] = newInt(stream.produced)
  props["delivered"] = newInt(stream.delivered)
  props["dropped"] = newInt(stream.dropped)
  props["sink_failures"] = newInt(stream.sinkFailures)
  props["queued"] = newInt(stream.queue.count)
  var head = newSym("EventStats")
  let declared = runtimeNamespaceMember(scope, ["EventStats"])
  if declared.kind == vkType:
    head = declared
  newNode(head, props = props)

proc biRuntimeStreamCategories(args: openArray[Value],
                               call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "EventStream/categories takes no arguments")
  let stream = requireEventStream(scope, args[0], "categories")
  var items: seq[Value]
  for category in RuntimeEventCategory:
    if (stream.categoryMask and categoryBit(category)) != 0:
      items.add newSym(runtimeEventCategoryName(category))
  newList(items, immutable = true, deepFrozen = true)

proc biRuntimeStreamCapacity(args: openArray[Value],
                             call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "EventStream/capacity takes no arguments")
  newInt(requireEventStream(scope, args[0], "capacity").queue.capacity)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc registerRuntimeEventTypes*(root: Scope, runtimeScope: Scope,
                                eventRootType: Value) =
  ## The public runtime event catalog (§11.2). Each family namespace declares
  ## its family base type as `Event` — the only naming convention the design
  ## needs — and the nominal `^is` chain is the only hierarchy: there is no
  ## parallel topic tree to keep in sync with it.
  let errorProtocol = root.vars["Error"]
  proc defineRuntimeError(name: string): Value =
    result = newType(name, NIL,
                     @[TypeField(name: "message", optional: false,
                                 typeExpr: newSym("Str"), scope: root)],
                     @[errorProtocol], root)
    root.define(name, result)
    root.impls.add ProtocolImpl(protocol: errorProtocol, receiver: result)
    runtimeScope.define(name, result)

  # §18: there is deliberately no `RuntimeEventSinkError`. A sink failure while
  # draining is caught, counted in `sink_failures`, and never raised to
  # anything, so an error type for it would be dead interface surface.
  discard defineRuntimeError("RuntimeEventsDisabled")
  discard defineRuntimeError("RuntimeEventConfigError")
  discard defineRuntimeError("RuntimeEventAttachError")
  discard defineRuntimeError("RuntimeEventFlushError")

  proc field(name, typeName: string, optional = false): TypeField =
    TypeField(name: name, optional: optional, typeExpr: newSym(typeName),
              scope: runtimeScope)

  # `^producer_id` and `^task_id` identify the *observing context* — which
  # producer emitted the record and, if it happened inside a task, which task.
  # They are not the subject of the event; a concrete event's subject gets its
  # own specifically-named field.
  let runtimeEventType = newType("Event", eventRootType,
    @[field("producer_id", "Int"),
      field("sequence", "Int"),
      field("time_ns", "Int?", optional = true),
      field("task_id", "Int?", optional = true)],
    @[], runtimeScope)
  runtimeScope.define("Event", runtimeEventType)

  proc defineFamily(name: string): Scope =
    result = newScope(runtimeScope)
    let base = newType("Event", runtimeEventType, @[], @[], result)
    result.define("Event", base)
    runtimeScope.define(name, newNamespace("runtime/" & name, result))

  proc familyBase(family: Scope): Value = family.vars["Event"]

  proc defineEvent(family: Scope, name: string,
                   fields: openArray[TypeField]) =
    family.define(name, newType(name, familyBase(family), @fields, @[], family))

  let lifecycle = defineFamily("lifecycle")
  lifecycle.defineEvent("Started", [])
  lifecycle.defineEvent("Stopping", [])
  lifecycle.defineEvent("Stopped", [])

  let moduleFamily = defineFamily("module")
  moduleFamily.defineEvent("LoadStarted",
    [field("module_id", "Int"), field("module_name", "Str")])
  moduleFamily.defineEvent("Loaded",
    [field("module_id", "Int"), field("module_name", "Str"),
     field("duration_ns", "Int?", optional = true)])
  moduleFamily.defineEvent("Failed",
    [field("module_id", "Int"), field("module_name", "Str"),
     field("duration_ns", "Int?", optional = true)])

  let taskFamily = defineFamily("task")
  taskFamily.defineEvent("Spawned", [field("spawned_task_id", "Int")])
  taskFamily.defineEvent("Completed",
    [field("completed_task_id", "Int"),
     field("duration_ns", "Int?", optional = true)])
  taskFamily.defineEvent("Failed",
    [field("failed_task_id", "Int"),
     field("duration_ns", "Int?", optional = true)])
  taskFamily.defineEvent("Cancelled",
    [field("cancelled_task_id", "Int"),
     field("duration_ns", "Int?", optional = true)])

  # The inherited `^producer_id`/`^sequence` describe the summary itself, which
  # the consumer synthesizes; the `dropped_*` fields describe the queue that
  # lost records. Deliberately separate (§12.2): a bare count would leave a tool
  # unable to distinguish "lost the startup burst" from "lost the records
  # immediately before the failure".
  runtimeScope.define("EventsDropped", newType("EventsDropped",
    runtimeEventType,
    @[field("dropped_producer_id", "Int"),
      field("dropped_count", "Int"),
      field("first_dropped_sequence", "Int"),
      field("last_dropped_sequence", "Int")],
    @[], runtimeScope))

  runtimeScope.define("AttachResult", newType("AttachResult", NIL,
    @[field("replayed_count", "Int"),
      field("dropped_before_attach", "Int"),
      field("first_replayed_sequence", "Int?", optional = true)],
    @[], runtimeScope))

  runtimeScope.define("EventStats", newType("EventStats", NIL,
    @[field("produced", "Int"),
      field("delivered", "Int"),
      field("dropped", "Int"),
      field("sink_failures", "Int"),
      field("queued", "Int")],
    @[], runtimeScope))

  discard runtimeScope.defineBuiltinType(vkEventStream, "EventStream", {
    "attach": newNativeCallFn("EventStream/attach", biRuntimeStreamAttach),
    "detach": newNativeCallFn("EventStream/detach", biRuntimeStreamDetach,
                              acceptsNamed = false),
    "flush": newNativeCallFn("EventStream/flush", biRuntimeStreamFlush,
                             acceptsNamed = false),
    "stats": newNativeCallFn("EventStream/stats", biRuntimeStreamStats,
                             acceptsNamed = false),
    "categories": newNativeCallFn("EventStream/categories",
                                  biRuntimeStreamCategories,
                                  acceptsNamed = false),
    "capacity": newNativeCallFn("EventStream/capacity",
                                biRuntimeStreamCapacity,
                                acceptsNamed = false)})
