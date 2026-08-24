## The application event bus — `gene/event` (docs/events.md §4.1-§8).
##
## Included into `vm.nim` after `defineBuiltinType`, so the four things this
## needs from the VM — `applyCall`, `freezeValue`, `builtinBinding`, and the
## built-in type funnel — are all in scope.
##
## What lives here is dispatch policy. The *storage* (bus, subscription,
## matcher, and sink payloads, plus the compact event type ids `newType`
## assigns) is in `types.nim`, next to the rest of the value layer.
##
## Two rules shape the code:
##
##   * **A publication runs against a snapshot.** Subscribing, cancelling, or
##     closing during dispatch affects the *next* publication, never the one
##     executing (§7.5). The snapshot copies handler values, not indices, so a
##     `close` that releases the bus's own references mid-dispatch cannot pull
##     a handler out from under the loop.
##   * **Matching is nominal and precomputed.** A publication reads the event's
##     concrete type, reads its compact id, reads a cached ordered match list,
##     and invokes only the matching subscriptions — no path parsing, no string
##     comparison, no scan of unrelated subscriptions (§6.4).

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

proc eventMember(scope: Scope, name: string): Value =
  ## A member of the `event` namespace, resolved through `scope`'s own
  ## Application.
  ##
  ## The scope is threaded rather than reached for: `currentApplication()`
  ## *creates* an Application when none has been installed globally, and every
  ## embedding that builds its own — `gene run` included — would then get error
  ## types whose identity is not the one its own `catch` clauses resolve. Two
  ## `EventTypeError`s that print the same and match nothing is exactly the
  ## failure this avoids.
  let ns = builtinBinding(scope, "event")
  if ns.kind != vkNamespace:
    return NIL
  let binding = exportedBinding(ns, name)
  if binding.kind == vkVoid: NIL else: binding

proc raiseEventError(scope: Scope, typeName, message: string,
                     extra: openArray[(string, Value)] = []) {.noreturn.} =
  ## The event errors are ordinary declared types (§18), so the raise builds a
  ## typed node with the real type in its head whenever the namespace is
  ## reachable, and falls back to the bare symbol only if it is not — the same
  ## shape `raiseTypeError` uses.
  var props = initPropTable()
  props["message"] = newStr(message)
  for entry in extra:
    props[entry[0]] = entry[1]
  var head = newSym(typeName)
  let declared = builtinBinding(scope, typeName)
  if declared.kind == vkType:
    head = declared
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc eventErrorValue(e: ref GeneError): Value =
  if e.hasErrVal:
    e.errVal
  else:
    var props = initPropTable()
    props["message"] = newStr(e.msg)
    newNode(newSym("Error"), props = props)

# ---------------------------------------------------------------------------
# Event identity
# ---------------------------------------------------------------------------

proc eventValueType(event: Value): Value =
  ## The concrete declared type of a candidate event, or NIL. An event is a
  ## typed node; nothing else can carry event identity, because identity lives
  ## on the type declaration (§6.1).
  if event.kind == vkNode and event.head.kind == vkType:
    event.head
  else:
    NIL

proc requireEventValue(scope: Scope, event: Value): Value =
  ## Returns the event's type after checking it descends from `event/Event`.
  ##
  ## §6.1 makes the *cause* part of the contract: forgetting `^is $event/Event`
  ## leaves an ordinary, perfectly valid typed value, so the rejection has to
  ## name that rather than surface as missing internal metadata.
  let typ = eventValueType(event)
  if typ.kind != vkType or typ.eventTypeId == 0:
    let shown =
      if typ.kind == vkType: "type " & typ.typeName
      else: "a " & $event.kind & " value"
    raiseEventError(scope, "EventTypeError",
      "publish expects an event/Event descendant, got " & shown &
      "; declare the event type with ^is $event/Event",
      {"actual_value": event})
  typ

proc unionSelectorMember(scope: Scope, member: Value): Value =
  ## One alternative of a union selector, resolved to a Type.
  ##
  ## `(| A B)` written as a value already holds evaluated Types, but
  ## `(alias U (| A B))` stores the *syntax*, so `U`'s members arrive as
  ## symbols. Both spellings have to name the same subscription, so an
  ## unresolved member is closed against the caller's scope — the same scope
  ## and the same `closeTypeExpr` the annotation path uses for an alias.
  if member.kind == vkType:
    return member
  let closed = closeTypeExpr(member, scope)
  if closed.kind == vkType: closed else: NIL

proc selectorAlternatives(scope: Scope, selector: Value,
                          into: var seq[EventSubscriptionSelector]): bool =
  ## Expand a selector into the alternatives it matches on. `false` means the
  ## selector is not one the grammar accepts.
  ##
  ## The grammar is a type, `(event/exact T)`, or a union of types — the third
  ## being the same `(| A B)` a parameter annotation takes, so a subscription
  ## and a handler signature can name one thing. A union member must itself be
  ## an event type: `(| OrderPlaced Str)` is rejected rather than silently
  ## matching only the half that makes sense.
  case selector.kind
  of vkEventMatcher:
    into.add EventSubscriptionSelector(typeId: selector.eventMatcherTypeId,
                                       exact: true)
    true
  of vkType:
    if selector.isUnionType:
      for rawMember in selector.unionTypeMembers:
        let member = unionSelectorMember(scope, rawMember)
        if member.kind != vkType:
          return false
        # A union of unions flattens: `(| A U)` where `U` is itself one.
        if not selectorAlternatives(scope, member, into):
          return false
      return into.len > 0
    if selector.eventTypeId == 0:
      return false
    into.add EventSubscriptionSelector(typeId: selector.eventTypeId,
                                       exact: false)
    true
  else:
    false

proc collectSelectorTypes(scope: Scope, selector: Value,
                          into: var seq[Value]) =
  if selector.kind == vkEventMatcher:
    into.add selector.eventMatcherTarget
    return
  if selector.kind == vkType and selector.isUnionType:
    for rawMember in selector.unionTypeMembers:
      let member = unionSelectorMember(scope, rawMember)
      if member.kind == vkType:
        collectSelectorTypes(scope, member, into)
    return
  into.add selector

proc selectorTypes(scope: Scope, selector: Value): seq[Value] =
  ## The declared types a selector can deliver, for handler validation (§7.1).
  ## Flattened, so a nested union checks every leaf.
  collectSelectorTypes(scope, selector, result)

proc typeIsDescendantOf(child, ancestor: Value): bool =
  ## Nominal `^is` ancestry, inclusive of `child == ancestor`.
  var t = child
  while t.kind == vkType:
    if t.bits == ancestor.bits:
      return true
    t = t.typeParent
  false

# ---------------------------------------------------------------------------
# Handler validation (§7.1)
# ---------------------------------------------------------------------------

proc handlerParamTypeExpr(handler: Value,
                          arity: var int): Value =
  ## The handler's single declared parameter type expression, plus its declared
  ## positional arity. NIL when the parameter is unannotated, when the handler
  ## is native, or when the annotation is anything other than a plain name — an
  ## unannotated parameter accepts any event and always passes (§7.1).
  arity = -1
  if handler.kind != vkFunction:
    return NIL
  let code = handler.fnCode
  if code == nil or not (code of FunctionProto):
    return NIL
  let proto = FunctionProto(code)
  if proto.restParam.len > 0:
    # A rest parameter accepts whatever it is given; arity is unbounded.
    arity = -1
    return NIL
  arity = proto.params.len
  if not proto.hasParamTypes or proto.paramTypes.len == 0:
    return NIL
  proto.paramTypes[0]

proc resolveHandlerParamType(handler: Value, expr: Value): Value =
  ## Resolve a parameter annotation to a declared Type, or NIL when it is not a
  ## plain resolvable name.
  ##
  ## Deliberately conservative: the check below rejects only what it can *prove*
  ## incompatible, so a union, a generic, or an annotation naming something this
  ## cannot see falls through to the unchecked path rather than failing a
  ## legitimate subscribe.
  ##
  ## Resolution goes through `closeTypeExpr` against the handler's own captured
  ## scope, which is the same thing the typed call boundary does — so `Placed`,
  ## `order/Placed`, and an imported alias all reach the one type identity, and
  ## a composite annotation closes to itself and falls through.
  let scope = handler.fnScope
  if scope == nil:
    return NIL
  let closed = closeTypeExpr(expr, scope)
  if closed.kind == vkType and not closed.isTypeAlias: closed else: NIL

proc validateHandler(scope: Scope, handler, selectorType: Value,
                     selectorLabel: string) =
  ## §7.1: the handler takes one parameter, and its declared parameter type must
  ## accept every value the selector can match.
  ##
  ## Without this, a narrowly annotated handler on a family selector is accepted
  ## and then fails once per non-matching event — as an `EventPublishError`
  ## raised at a publisher that did nothing wrong, and only for the subset of
  ## events that happen to occur. Both types are in hand here, so the check is
  ## cheap and turns a recurring runtime failure into one declaration-site error.
  if handler.kind == vkFunction and handler.isSyntaxFn:
    raiseEventError(scope, "EventTypeError",
      "subscribe expects a function handler, got a fexpr")
  var arity = -1
  let paramExpr = handlerParamTypeExpr(handler, arity)
  if arity >= 0 and arity != 1:
    raiseEventError(scope, "EventTypeError",
      "subscribe expects a handler taking one event parameter, got " &
      $arity & " parameters")
  if paramExpr.kind == vkNil:
    return
  let paramType = resolveHandlerParamType(handler, paramExpr)
  if paramType.kind != vkType:
    return
  if not typeIsDescendantOf(selectorType, paramType):
    raiseEventError(scope, "EventTypeError",
      "handler parameter type " & paramType.typeName &
      " cannot accept every event " & selectorLabel & " matches; " &
      "widen the parameter to " & selectorType.typeName &
      " or subscribe to " & paramType.typeName & " instead")

# ---------------------------------------------------------------------------
# Subscription buckets and the resolved-match cache (§6.4)
# ---------------------------------------------------------------------------

proc addToBucket(buckets: var Table[int32, seq[int32]], key, index: int32) =
  buckets.withValue(key, existing):
    existing[].add index
    return
  buckets[key] = @[index]

proc removeFromBucket(buckets: var Table[int32, seq[int32]], key, index: int32) =
  buckets.withValue(key, existing):
    for i, entry in existing[]:
      if entry == index:
        existing[].delete(i)
        break
    if existing[].len == 0:
      buckets.del(key)

proc resolveMatches(data: EventBusData, eventType: Value,
                    id: int32): lent seq[int32] =
  ## The merged, subscription-ordered match list for one concrete event type.
  ##
  ## A single bus-wide generation counter invalidates every cached entry, and
  ## only laziness keeps that cheap: a stale entry is rebuilt on the next
  ## publication *of that type*, and entries for types never published again are
  ## never rebuilt. The rebuild replaces the slot with a freshly built list
  ## rather than mutating one in place, which is what lets an in-flight
  ## publication keep running against the list it already read.
  data.matchCache.withValue(id, cached):
    if cached[].generation == data.generation:
      return cached[].subs
  var merged: seq[int32]
  for ancestorId in eventType.eventMatchIds:
    data.descendantBuckets.withValue(ancestorId, bucket):
      for index in bucket[]:
        merged.add index
  data.exactBuckets.withValue(id, bucket):
    for index in bucket[]:
      merged.add index
  # Subscription order is index order: entries are appended and never removed
  # while the bus is open, so sorting the merged indices *is* ordering by
  # subscription sequence number, across the exact and family buckets alike.
  merged.sort()
  # Deduplicate. One entry can reach this list through several buckets — a
  # union subscription whose event matches two alternatives, or a family and an
  # exact bucket naming the same id — and §6.3 makes *separate* subscriptions
  # fire separately, not one subscription fire twice. Sorting has already put
  # any duplicates adjacent.
  var deduped: seq[int32]
  for index in merged:
    if deduped.len == 0 or deduped[^1] != index:
      deduped.add index
  data.matchCache[id] = EventMatchCacheEntry(generation: data.generation,
                                             subs: deduped)
  data.matchCache[id].subs

proc cancelEntry(data: EventBusData, index: int32): bool =
  ## Deactivate one subscription and unhook it from its bucket. Returns whether
  ## the subscription changed from active to cancelled (§7.3: idempotent).
  if index < 0 or index >= int32(data.subs.len):
    return false
  if not data.subs[index].active:
    return false
  data.subs[index].active = false
  # Every bucket it was listed in, not just one: a union subscription is one
  # entry reachable from several.
  for selector in data.subs[index].selectors:
    if selector.exact:
      removeFromBucket(data.exactBuckets, selector.typeId, index)
    else:
      removeFromBucket(data.descendantBuckets, selector.typeId, index)
  # The handler reference goes now rather than at collection time: §7.3 rules
  # out collection-driven cancellation precisely so release is deterministic.
  data.subs[index].handler = NIL
  inc data.generation
  true

# ---------------------------------------------------------------------------
# Bus operations
# ---------------------------------------------------------------------------

proc requireOwningLane(scope: Scope, data: EventBusData, op: string) =
  ## §9.1: a version 1 bus is lane-owned, and using one from another lane is a
  ## task-boundary error.
  ##
  ## Every *transfer* is already refused — a bus is not `Send`, so a channel,
  ## an actor message, and a worker-safe spawn capture all reject it. What that
  ## does not cover is a lane that reaches a bus without transferring a value:
  ## an embedding host thread calling in through `native_api`'s `geneCall` runs
  ## no sendability check at all, and would mutate `subs` and the bucket tables
  ## concurrently with the owning lane. This is the check for that, and it is
  ## the same thread-id ownership pattern `geneAttachThread` already uses.
  if data.ownerLane != currentEventLane():
    raiseEventError(scope, "SubscriptionError",
      op & " on an event/Bus owned by another lane; a version 1 bus is " &
      "lane-owned, and cross-lane delivery is an explicit adapter that " &
      "publishes on the destination bus's own lane")

proc requireOpenBus(scope: Scope, data: EventBusData, op: string) =
  if data.closed:
    raiseEventError(scope, "EventBusClosedError",
      op & " on a closed event/Bus")

proc errorPolicyFromValue(scope: Scope, value: Value): EventErrorPolicy =
  let variant = value.enumValueVariant
  if variant.kind == vkEnumVariant:
    case variant.enumVariantName
    of "raise_after": return eepRaiseAfter
    of "collect": return eepCollect
    else: discard
  raiseEventError(scope, "EventTypeError",
    "^error_policy expects $event/raise_after or $event/collect")

proc biEventBusNew(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 0:
    raise newException(GeneError,
      "event/Bus takes named properties only, got " & $args.len &
      " positional argument(s)")
  var policy = eepRaiseAfter
  var limit = defaultEventNestingLimit
  if call != nil:
    for i, name in call.namedNames:
      case name
      of "error_policy":
        policy = errorPolicyFromValue(scope, call.namedValues[i])
      of "nesting_limit":
        let v = call.namedValues[i]
        if v.kind != vkInt or v.intVal <= 0:
          raiseEventError(scope, "EventTypeError",
            "^nesting_limit expects a positive Int")
        limit = int(v.intVal)
      else:
        raiseEventError(scope, "EventTypeError",
          "event/Bus does not accept ^" & name)
  newEventBus(policy, limit)

proc biEventExact(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError,
      "event/exact expects 1 argument, got " & $args.len)
  let target = args[0]
  if target.kind != vkType or target.eventTypeId == 0:
    raiseEventError(scope, "EventTypeError",
      "event/exact expects an event/Event descendant type")
  newEventMatcher(target, target.eventTypeId)

proc biEventBusSubscribe(args: openArray[Value], call: ptr NativeCall): Value
                        {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 3:
    raise newException(GeneError,
      "Bus/subscribe expects a selector and a handler, got " &
      $(args.len - 1) & " argument(s)")
  requireEventBus(args[0])
  let data = busData(args[0])
  requireOwningLane(scope, data, "subscribe")
  requireOpenBus(scope, data, "subscribe")
  let selector = args[1]
  let handler = args[2]
  var selectors: seq[EventSubscriptionSelector]
  if not selectorAlternatives(scope, selector, selectors):
    raiseEventError(scope, "EventTypeError",
      "subscribe expects an event/Event descendant type, a union of them, " &
      "or an event/Matcher from event/exact",
      {"actual_value": selector})
  if not valueImplementsCallable(handler, scope):
    raiseEventError(scope, "EventTypeError",
      "subscribe expects a callable handler", {"actual_value": handler})
  rejectCallerEnvEscape("Bus/subscribe handler", handler)
  # Every alternative must satisfy the handler, not just the first: a union
  # selector delivers all of them to the same parameter.
  for selectorType in selectorTypes(scope, selector):
    validateHandler(scope, handler, selectorType,
                    (if selector.kind == vkEventMatcher:
                       "(event/exact " & selectorType.typeName & ")"
                     else: selectorType.typeName))
  var once = false
  if call != nil:
    for i, name in call.namedNames:
      case name
      of "once":
        let v = call.namedValues[i]
        if v.kind != vkBool:
          raiseEventError(scope, "EventTypeError", "^once expects a Bool")
        once = v.boolVal
      else:
        raiseEventError(scope, "EventTypeError",
          "subscribe does not accept ^" & name)
  let index = int32(data.subs.len)
  data.subs.add EventSubscriptionEntry(handler: handler,
                                       selectors: selectors,
                                       once: once,
                                       active: true)
  for selector in selectors:
    if selector.exact:
      addToBucket(data.exactBuckets, selector.typeId, index)
    else:
      addToBucket(data.descendantBuckets, selector.typeId, index)
  inc data.generation
  newEventSubscription(args[0], index)

proc publishResultValue(scope: Scope, matched, delivered, failed: int,
                        errors: sink seq[Value]): Value =
  var props = initPropTable()
  props["matched"] = newInt(matched)
  props["delivered"] = newInt(delivered)
  props["failed"] = newInt(failed)
  props["errors"] = newList(errors, immutable = true)
  var head = newSym("PublishResult")
  let declared = eventMember(scope, "PublishResult")
  if declared.kind == vkType:
    head = declared
  newNode(head, props = props)

proc freezeEventValue(scope: Scope, event: Value): Value =
  ## §6.5: the value every subscriber receives is a frozen *copy*, so the
  ## publisher may keep mutating its own reference afterwards and nothing it
  ## does is observable through the event already delivered.
  ##
  ## The `deep_frozen` check is the O(1) fast path §17.3 asks for. It reads the
  ## dedicated deep bit, never `immutable`: `freeze_shallow` sets `immutable` on
  ## a node whose children are untouched, so treating that as "already frozen"
  ## would publish a value with a mutable `Cell` reachable through it.
  if event.isDeepFrozen:
    return event
  try:
    freezeValue(event)
  except GeneError as e:
    raiseEventError(scope, "EventFrozenError",
      "publish cannot freeze the event: " & e.msg, {"actual_value": event})

proc dispatchEvent(scope: Scope, bus: Value, data: EventBusData,
                   frozen: Value, eventType: Value, id: int32): Value =
  ## Resolve, snapshot, and dispatch. Returns the `PublishResult`; applying the
  ## error policy is the caller's job, because `EventSink:emit` applies a
  ## different one (§7.2).
  if data.nestingDepth >= data.nestingLimit:
    raiseEventError(scope, "EventRecursionError",
      "nested publication exceeded the bus limit of " & $data.nestingLimit,
      {"limit": newInt(data.nestingLimit)})
  # The snapshot copies handler *values*: a `close` during dispatch releases the
  # bus's references, and §7.4 still requires the in-flight publication to run
  # to completion.
  var snapshot: seq[Value]
  block resolveAndSnapshot:
    let matches = resolveMatches(data, eventType, id)
    snapshot = newSeqOfCap[Value](matches.len)
    for index in matches:
      if not data.subs[index].active:
        continue
      if data.subs[index].once:
        # Marked consumed *before* any handler runs, so a handler that
        # republishes the same event type does not see the one-shot again.
        if data.subs[index].consumed:
          continue
        data.subs[index].consumed = true
        let handler = data.subs[index].handler
        discard cancelEntry(data, index)
        snapshot.add handler
      else:
        snapshot.add data.subs[index].handler
  var delivered = 0
  var failed = 0
  var errors: seq[Value]
  inc data.nestingDepth
  try:
    for handler in snapshot:
      var callArgs = [frozen]
      try:
        discard applyCall(handler, callArgs, NamedArgs(), scope)
        inc delivered
      except GeneError as e:
        # A subscriber error must not stop unrelated subscribers (§8).
        inc failed
        errors.add eventErrorValue(e)
  finally:
    dec data.nestingDepth
  publishResultValue(scope, snapshot.len, delivered, failed, errors)

proc publishFailure(publishResult: Value): Value =
  publishResult.props.getOrDefault("failed", newInt(0))

proc raisePublishError(scope: Scope, publishResult: Value) {.noreturn.} =
  ## Carries the count and the ordered failures, and deliberately *not* the
  ## whole `PublishResult`: nested publication would then nest each level's
  ## result inside the next, and the printed error grows exponentially with
  ## depth for information the `errors` list already holds.
  let failed = publishFailure(publishResult).intVal
  raiseEventError(scope, "EventPublishError",
    $failed & " event handler(s) failed",
    {"failed": newInt(failed),
     "errors": publishResult.props.getOrDefault("errors", newList())})

proc eventBusPublish(scope: Scope, bus: Value, event: Value): Value =
  requireEventBus(bus)
  let data = busData(bus)
  requireOwningLane(scope, data, "publish")
  requireOpenBus(scope, data, "publish")
  let eventType = requireEventValue(scope, event)
  let frozen = freezeEventValue(scope, event)
  dispatchEvent(scope, bus, data, frozen, eventType, eventType.eventTypeId)

proc biEventBusPublish(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 2:
    raise newException(GeneError,
      "Bus/publish expects 1 event, got " & $(args.len - 1))
  let publishResult = eventBusPublish(scope, args[0], args[1])
  if busData(args[0]).errorPolicy == eepRaiseAfter and
      publishFailure(publishResult).intVal > 0:
    raisePublishError(scope, publishResult)
  publishResult

proc biEventBusClose(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  ## §7.4: cancel every subscription, release the handlers, idempotent.
  ## Without it there is no deterministic way to release a bus's handlers,
  ## since §7.3 rules out collection-driven cancellation.
  if args.len != 1:
    raise newException(GeneError, "Bus/close takes no arguments")
  requireEventBus(args[0])
  let data = busData(args[0])
  requireOwningLane(scope, data, "close")
  if data.closed:
    return FALSE
  for index in 0 ..< data.subs.len:
    discard cancelEntry(data, int32(index))
  data.closed = true
  data.matchCache.clear()
  TRUE

proc biEventBusClosed(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "Bus/closed? takes no arguments")
  requireEventBus(args[0])
  requireOwningLane(scope, busData(args[0]), "closed?")
  newBool(busData(args[0]).closed)

proc biEventBusSubscriptionCount(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  ## Active subscriptions. Diagnostic surface for tests and `close` checks.
  if args.len != 1:
    raise newException(GeneError, "Bus/subscription_count takes no arguments")
  requireEventBus(args[0])
  let data = busData(args[0])
  requireOwningLane(scope, data, "subscription_count")
  var count = 0
  for entry in data.subs:
    if entry.active:
      inc count
  newInt(count)

# ---------------------------------------------------------------------------
# Subscription handle
# ---------------------------------------------------------------------------

proc biEventSubscriptionCancel(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "Subscription/cancel takes no arguments")
  if args[0].kind != vkEventSubscription:
    raise newException(GeneError,
      "Subscription/cancel expects an event/Subscription")
  let bus = subscriptionBus(args[0])
  if bus.kind != vkEventBus:
    return FALSE
  requireOwningLane(scope, busData(bus), "cancel")
  newBool(cancelEntry(busData(bus), subscriptionData(args[0]).index))

proc biEventSubscriptionActive(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "Subscription/active? takes no arguments")
  if args[0].kind != vkEventSubscription:
    raise newException(GeneError,
      "Subscription/active? expects an event/Subscription")
  let bus = subscriptionBus(args[0])
  if bus.kind != vkEventBus:
    return FALSE
  let data = busData(bus)
  requireOwningLane(scope, data, "active?")
  let index = subscriptionData(args[0]).index
  newBool(index >= 0 and index < int32(data.subs.len) and
          data.subs[index].active)

# ---------------------------------------------------------------------------
# Sinks (§5)
# ---------------------------------------------------------------------------

proc emitToSink(scope: Scope, sink: Value, event: Value): Value

proc busEmit(scope: Scope, bus: Value, event: Value): Value =
  ## `EventSink:emit` for a bus. Publishes, then reports a nonzero `failed`
  ## count as a sink failure **regardless of the bus's own error policy** (§7.2).
  ##
  ## This is the whole reason an attached `event/collect` bus cannot be
  ## misconfigured into silence: the draining adapter can only learn that
  ## observers are broken from a raise, so `collect` keeps one bad handler from
  ## aborting the others without also hiding them at the sink boundary.
  let publishResult = eventBusPublish(scope, bus, event)
  if publishFailure(publishResult).intVal > 0:
    raisePublishError(scope, publishResult)
  NIL

proc compositeEmit(scope: Scope, sink: Value, event: Value): Value =
  ## Ordered fan-out. The composite owns its own error handling (§14.5): every
  ## child is attempted, and the collected failures surface as one
  ## `EventPublishError` so a broken child is never silently dropped.
  var failed = 0
  var errors: seq[Value]
  for child in sink.compositeSinks:
    try:
      discard emitToSink(scope, child, event)
    except GeneError as e:
      inc failed
      errors.add eventErrorValue(e)
  if failed > 0:
    raiseEventError(scope, "EventPublishError",
      $failed & " composite sink(s) failed",
      {"failed": newInt(failed), "errors": newList(errors, immutable = true)})
  NIL

proc emitToSink(scope: Scope, sink: Value, event: Value): Value =
  case sink.kind
  of vkEventBus:
    busEmit(scope, sink, event)
  of vkRecordingSink:
    discard requireEventValue(scope, event)
    sink.recordEvent(freezeEventValue(scope, event))
    NIL
  of vkNullSink:
    discard requireEventValue(scope, event)
    NIL
  of vkCompositeSink:
    compositeEmit(scope, sink, event)
  else:
    # A Gene value implementing the protocol. Dispatch it as an ordinary
    # qualified send rather than reimplementing resolution here.
    let protocol = eventMember(scope, "EventSink")
    if protocol.kind != vkProtocol:
      raiseEventError(scope, "EventTypeError", "EventSink protocol is unavailable")
    let message = protocol.protocolMessages.getOrDefault("emit", NIL)
    if message.kind != vkProtocolMessage:
      raiseEventError(scope, "EventTypeError", "EventSink/emit is unavailable")
    var callArgs = [sink, event]
    applyCall(message, callArgs, NamedArgs())

proc biEventSinkEmit(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 2:
    raise newException(GeneError,
      "EventSink/emit expects 1 event, got " & $(args.len - 1))
  emitToSink(scope, args[0], args[1])

proc biRecordingSinkNew(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 0:
    raise newException(GeneError, "event/RecordingSink takes no arguments")
  newRecordingSink()

proc biRecordingSinkEvents(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "RecordingSink/events takes no arguments")
  if args[0].kind != vkRecordingSink:
    raise newException(GeneError,
      "RecordingSink/events expects an event/RecordingSink")
  var items = newSeq[Value](args[0].recordedEvents.len)
  for i, event in args[0].recordedEvents:
    items[i] = event
  newList(items, immutable = true)

proc biRecordingSinkClear(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "RecordingSink/clear takes no arguments")
  if args[0].kind != vkRecordingSink:
    raise newException(GeneError,
      "RecordingSink/clear expects an event/RecordingSink")
  args[0].clearRecordedEvents()
  NIL

proc biNullSinkNew(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 0:
    raise newException(GeneError, "event/NullSink takes no arguments")
  newNullSink()

proc biCompositeSinkNew(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError,
      "event/CompositeSink expects one List of sinks")
  if args[0].kind != vkList:
    raise newException(GeneError,
      "event/CompositeSink expects a List of sinks")
  var sinks = newSeq[Value](args[0].listItems.len)
  for i, child in args[0].listItems:
    sinks[i] = child
  newCompositeSink(sinks)

proc biCompositeSinkSinks(args: openArray[Value], call: ptr NativeCall): Value
                  {.nimcall.} =
  let scope = if call == nil: nil else: call.dispatchScope
  if args.len != 1:
    raise newException(GeneError, "CompositeSink/sinks takes no arguments")
  if args[0].kind != vkCompositeSink:
    raise newException(GeneError,
      "CompositeSink/sinks expects an event/CompositeSink")
  var items = newSeq[Value](args[0].compositeSinks.len)
  for i, child in args[0].compositeSinks:
    items[i] = child
  newList(items, immutable = true)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc registerEventNamespace(root: Scope) =
  ## `event` is a new stdlib root, registered under `gene/event` like every
  ## other lowercase stdlib namespace (§7). Case is the rule the compiler
  ## already enforces: `$event/Bus` and `(import gene/event [Bus])` both work,
  ## bare `event/Bus` does not, and `event` is deliberately *not* added to
  ## `bareCapabilityNamespaces`.
  let errorProtocol = root.vars["Error"]
  proc defineEventError(name: string, parent: Value): Value =
    result =
      if parent.kind == vkType:
        newType(name, parent, @[], @[], root)
      else:
        newType(name, NIL,
                @[TypeField(name: "message", optional: false,
                            typeExpr: newSym("Str"), scope: root)],
                @[errorProtocol], root)
    root.define(name, result)
    if parent.kind != vkType:
      root.impls.add ProtocolImpl(protocol: errorProtocol, receiver: result)

  let eventTypeError = defineEventError("EventTypeError", NIL)
  let eventFrozenError = defineEventError("EventFrozenError", NIL)
  let eventPublishError = defineEventError("EventPublishError", NIL)
  let eventRecursionError = defineEventError("EventRecursionError", NIL)
  # §18's "invalid bus/subscription ownership operation" — raised by the lane
  # check below when a bus is touched from a lane that does not own it.
  let subscriptionError = defineEventError("SubscriptionError", NIL)
  let eventBusClosedError = defineEventError("EventBusClosedError", NIL)

  let eventScope = newScope(root)

  # The root event type. `^is $event/Event` is what makes a declared type
  # publishable, and the bus's one inexpensive recognition rule (§6.1).
  let eventRootType = newType("Event", NIL, @[], @[], eventScope,
                              eventRoot = true)
  eventScope.define("Event", eventRootType)

  # `PublishResult` is the return type under *both* error policies; the policy
  # governs only whether a publication with failures raises instead of
  # returning (§7.2).
  let publishResultType = newType("PublishResult", NIL,
    @[TypeField(name: "matched", optional: false, typeExpr: newSym("Int"),
                scope: eventScope),
      TypeField(name: "delivered", optional: false, typeExpr: newSym("Int"),
                scope: eventScope),
      TypeField(name: "failed", optional: false, typeExpr: newSym("Int"),
                scope: eventScope),
      TypeField(name: "errors", optional: false, typeExpr: newSym("List"),
                scope: eventScope)],
    @[], eventScope)
  eventScope.define("PublishResult", publishResultType)

  let errorPolicyEnum = newEnum("ErrorPolicy", @[],
    [(name: "raise_after", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "collect", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL)],
    NIL, eventScope)
  eventScope.define("ErrorPolicy", errorPolicyEnum)
  # The variants are bound directly in the namespace too, because that is how
  # §8 spells them at use sites: `^error_policy $event/collect`.
  eventScope.define("raise_after",
                    enumVariantDescriptor(errorPolicyEnum, "raise_after"))
  eventScope.define("collect",
                    enumVariantDescriptor(errorPolicyEnum, "collect"))

  # One message, deliberately (§5). Filtering, buffering, retries, fan-out,
  # serialization, and error policy belong behind sink implementations instead
  # of expanding the common interface.
  #
  # §5 spells the message `^errors [EventPublishError]`, and this declaration
  # does **not** carry that: `newProtocol` has no errors parameter, so a
  # natively registered protocol cannot state a checked error row the way a
  # Gene `(protocol ...)` declaration can. The *guarantee* is implemented —
  # `emit` raises `EventPublishError` on a nonzero `failed` count under either
  # policy (§7.2), which is the entire mechanism by which an attached
  # `event/collect` bus cannot silently swallow observer failures, and the
  # spec suite pins it — but it is unchecked here rather than declared.
  # Declaring it needs `newProtocol` to accept per-message error types.
  let eventSinkProtocol = newProtocol("EventSink", ["emit"],
                                      scope = eventScope)
  eventScope.define("EventSink", eventSinkProtocol)
  root.define("EventSink", eventSinkProtocol)

  # Every event native is a `NativeCallProc`, even the ones that take no named
  # arguments: `NativeCall` is the only channel that carries the calling scope,
  # and that scope is what resolves the error types a raise must construct with
  # the caller's own identities.
  let emitNative = newNativeCallFn("EventSink/emit", biEventSinkEmit,
                                   acceptsNamed = false)

  let busType = eventScope.defineBuiltinType(vkEventBus, "Bus", {
    "subscribe": newNativeCallFn("Bus/subscribe", biEventBusSubscribe),
    "publish": newNativeCallFn("Bus/publish", biEventBusPublish,
                               acceptsNamed = false),
    "close": newNativeCallFn("Bus/close", biEventBusClose,
                             acceptsNamed = false),
    "closed?": newNativeCallFn("Bus/closed?", biEventBusClosed,
                               acceptsNamed = false),
    "subscription_count": newNativeCallFn("Bus/subscription_count",
                                          biEventBusSubscriptionCount,
                                          acceptsNamed = false),
    "emit": emitNative},
    ctor = newNativeCallFn("event/Bus", biEventBusNew))

  discard eventScope.defineBuiltinType(
    vkEventSubscription, "Subscription", {
      "cancel": newNativeCallFn("Subscription/cancel",
                                biEventSubscriptionCancel,
                                acceptsNamed = false),
      "active?": newNativeCallFn("Subscription/active?",
                                 biEventSubscriptionActive,
                                 acceptsNamed = false)})

  discard eventScope.defineBuiltinType(vkEventMatcher, "Matcher",
                                       newSeq[(string, Value)]())

  let recordingSinkType = eventScope.defineBuiltinType(
    vkRecordingSink, "RecordingSink", {
      "emit": emitNative,
      "events": newNativeCallFn("RecordingSink/events", biRecordingSinkEvents,
                                acceptsNamed = false),
      "clear": newNativeCallFn("RecordingSink/clear", biRecordingSinkClear,
                               acceptsNamed = false)},
    ctor = newNativeCallFn("event/RecordingSink", biRecordingSinkNew,
                           acceptsNamed = false))

  let nullSinkType = eventScope.defineBuiltinType(vkNullSink, "NullSink", {
      "emit": emitNative},
    ctor = newNativeCallFn("event/NullSink", biNullSinkNew,
                           acceptsNamed = false))

  let compositeSinkType = eventScope.defineBuiltinType(
    vkCompositeSink, "CompositeSink", {
      "emit": emitNative,
      "sinks": newNativeCallFn("CompositeSink/sinks", biCompositeSinkSinks,
                               acceptsNamed = false)},
    ctor = newNativeCallFn("event/CompositeSink", biCompositeSinkNew,
                           acceptsNamed = false))

  # `event/Bus` implements `EventSink`, and so do the three shipped sinks, so
  # `(sink ~ EventSink:emit event)` resolves for every one of them.
  let emitMessage = eventSinkProtocol.protocolMessages["emit"]
  for receiver in [busType, recordingSinkType, nullSinkType,
                   compositeSinkType]:
    root.impls.add ProtocolImpl(
      protocol: eventSinkProtocol, receiver: receiver,
      messages: @[ImplMessage(message: emitMessage, fn: emitNative)])

  eventScope.define("exact", newNativeCallFn("event/exact", biEventExact,
                                             acceptsNamed = false))
  eventScope.define("EventTypeError", eventTypeError)
  eventScope.define("EventFrozenError", eventFrozenError)
  eventScope.define("EventPublishError", eventPublishError)
  eventScope.define("EventRecursionError", eventRecursionError)
  eventScope.define("SubscriptionError", subscriptionError)
  eventScope.define("EventBusClosedError", eventBusClosedError)

  root.define("event", newNamespace("event", eventScope))
