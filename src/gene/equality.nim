## Structural equality, reference identity, and hashing (design Section 1.5).
##
##   (= a b)     -> `equal`: structural, meta-blind
##   (same? a b) -> `same`:  scalar value identity or heap identity
##
## Hashing follows `=`. Meta never participates in equality or hashing.
## Mutable/immutable representation does not affect equality (e.g. [1 2 3]
## equals #[1 2 3]).

import std/[tables, hashes, sets]
import ./types

proc equal*(a, b: Value): bool

proc tablesEqual(a, b: PropTable): bool =
  if a.len != b.len: return false
  for k, va in a:
    if not b.hasKey(k): return false
    if not equal(va, b[k]): return false
  true

proc setContains(items: openArray[Value], needle: Value): bool =
  for item in items:
    if equal(item, needle):
      return true
  false

proc hashMapGet(entries: openArray[HashMapEntry], key: Value,
                value: var Value): bool =
  for entry in entries:
    if equal(entry.key, key):
      value = entry.val
      return true
  false

proc equal*(a, b: Value): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  case a.kind
  of vkNil, vkVoid: true
  of vkBool:   a.boolVal == b.boolVal
  of vkInt:    intCompare(a, b) == 0
  of vkFloat:  a.floatVal == b.floatVal
  of vkString: a.strVal == b.strVal
  of vkBytes:  a.bytesVal == b.bytesVal
  of vkRegex:  a.regexPattern == b.regexPattern and a.regexFlags == b.regexFlags
  of vkRange:
    a.rangeStart == b.rangeStart and a.rangeStop == b.rangeStop and
      a.rangeStep == b.rangeStep and a.rangeInclusive == b.rangeInclusive
  of vkDate:
    a.dateYear == b.dateYear and a.dateMonth == b.dateMonth and
      a.dateDay == b.dateDay
  of vkTime:
    a.timeHour == b.timeHour and a.timeMinute == b.timeMinute and
      a.timeSecond == b.timeSecond and
      a.timeMicrosecond == b.timeMicrosecond and
      a.timeHasOffset == b.timeHasOffset and
      a.timeOffsetMinutes == b.timeOffsetMinutes and
      a.timeTimezoneName == b.timeTimezoneName
  of vkDateTime:
    a.dateTimeYear == b.dateTimeYear and
      a.dateTimeMonth == b.dateTimeMonth and
      a.dateTimeDay == b.dateTimeDay and
      a.dateTimeHour == b.dateTimeHour and
      a.dateTimeMinute == b.dateTimeMinute and
      a.dateTimeSecond == b.dateTimeSecond and
      a.dateTimeMicrosecond == b.dateTimeMicrosecond and
      a.dateTimeHasOffset == b.dateTimeHasOffset and
      a.dateTimeOffsetMinutes == b.dateTimeOffsetMinutes and
      a.dateTimeTimezoneName == b.dateTimeTimezoneName
  of vkTimezone:
    a.timezoneHasOffset == b.timezoneHasOffset and
      a.timezoneOffsetMinutes == b.timezoneOffsetMinutes and
      a.timezoneName == b.timezoneName
  of vkDuration:
    a.durationMicroseconds == b.durationMicroseconds
  of vkChar:   int32(a.charVal) == int32(b.charVal)
  of vkSymbol: a.symVal == b.symVal
  of vkList:
    if a.listItems.len != b.listItems.len: return false
    for i in 0 ..< a.listItems.len:
      if not equal(a.listItems[i], b.listItems[i]): return false
    true
  of vkMap:
    tablesEqual(a.mapEntries, b.mapEntries)
  of vkSet:
    if a.setItems.len != b.setItems.len: return false
    for item in a.setItems:
      if not setContains(b.setItems, item): return false
    true
  of vkHashMap:
    if a.hashMapEntries.len != b.hashMapEntries.len: return false
    for entry in a.hashMapEntries:
      var other: Value
      if not hashMapGet(b.hashMapEntries, entry.key, other):
        return false
      if not equal(entry.val, other):
        return false
    true
  of vkNode:
    # meta-blind: head + props + body only
    if not equal(a.head, b.head): return false
    if a.body.len != b.body.len: return false
    for i in 0 ..< a.body.len:
      if not equal(a.body[i], b.body[i]): return false
    tablesEqual(a.props, b.props)
  of vkFunction, vkNativeFn, vkNamespace, vkModule, vkEnv, vkCell, vkAtomicCell,
     vkStream, vkTask, vkChannel, vkActorRef, vkActorContext, vkActorStep,
     vkReplyTo, vkCPtr, vkCSlice, vkBuffer, vkDeviceBuffer, vkCapability, vkFfiLoad,
     vkFfiLibrary, vkFfiCallable, vkType, vkProtocol, vkProtocolMessage,
     vkEnumVariant:
    # callable and opaque runtime values have identity equality
    a.bits == b.bits

proc same*(a, b: Value): bool =
  ## Scalars are representation-independent values, so small and heap-backed
  ## ints follow the same contract. Lists, maps, nodes, and callables use
  ## heap identity.
  if a.kind != b.kind:
    return false
  case a.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkBytes, vkRegex, vkRange,
     vkDate, vkTime, vkDateTime, vkTimezone, vkDuration, vkChar, vkSymbol:
    equal(a, b)
  of vkList, vkMap, vkSet, vkHashMap, vkNode, vkFunction, vkNativeFn, vkNamespace, vkModule,
     vkEnv, vkCell, vkAtomicCell, vkStream, vkTask, vkChannel, vkActorRef,
     vkActorContext, vkActorStep, vkReplyTo, vkCPtr, vkCSlice, vkBuffer,
     vkDeviceBuffer, vkCapability, vkFfiLoad, vkFfiLibrary, vkFfiCallable, vkType, vkProtocol,
     vkProtocolMessage, vkEnumVariant:
    a.bits == b.bits

proc hash*(v: Value): Hash =
  if v.isNil: return hash(0)
  var h: Hash = hash(ord(v.kind))
  case v.kind
  of vkNil, vkVoid: discard
  of vkBool:   h = h !& hash(v.boolVal)
  of vkInt:    h = h !& hash(v.intToString)
  of vkFloat:  h = h !& hash(v.floatVal)
  of vkString: h = h !& hash(v.strVal)
  of vkBytes:  h = h !& hash(v.bytesVal)
  of vkRegex:
    h = h !& hash(v.regexPattern)
    h = h !& hash(v.regexFlags)
  of vkRange:
    h = h !& hash(v.rangeStart)
    h = h !& hash(v.rangeStop)
    h = h !& hash(v.rangeStep)
    h = h !& hash(v.rangeInclusive)
  of vkDate:
    h = h !& hash(v.dateYear)
    h = h !& hash(v.dateMonth)
    h = h !& hash(v.dateDay)
  of vkTime:
    h = h !& hash(v.timeHour)
    h = h !& hash(v.timeMinute)
    h = h !& hash(v.timeSecond)
    h = h !& hash(v.timeMicrosecond)
    h = h !& hash(v.timeHasOffset)
    h = h !& hash(v.timeOffsetMinutes)
    h = h !& hash(v.timeTimezoneName)
  of vkDateTime:
    h = h !& hash(v.dateTimeYear)
    h = h !& hash(v.dateTimeMonth)
    h = h !& hash(v.dateTimeDay)
    h = h !& hash(v.dateTimeHour)
    h = h !& hash(v.dateTimeMinute)
    h = h !& hash(v.dateTimeSecond)
    h = h !& hash(v.dateTimeMicrosecond)
    h = h !& hash(v.dateTimeHasOffset)
    h = h !& hash(v.dateTimeOffsetMinutes)
    h = h !& hash(v.dateTimeTimezoneName)
  of vkTimezone:
    h = h !& hash(v.timezoneHasOffset)
    h = h !& hash(v.timezoneOffsetMinutes)
    h = h !& hash(v.timezoneName)
  of vkDuration:
    h = h !& hash(v.durationMicroseconds)
  of vkChar:   h = h !& hash(int32(v.charVal))
  of vkSymbol: h = h !& hash(v.symVal)
  of vkList:
    for it in v.listItems: h = h !& hash(it)
  of vkMap:
    var acc: Hash = 0
    for k, val in v.mapEntries:
      acc = acc xor (hash(k) !& hash(val))   # order-independent
    h = h !& acc
  of vkSet:
    var acc: Hash = 0
    for it in v.setItems:
      acc = acc xor hash(it)
    h = h !& acc
  of vkHashMap:
    var acc: Hash = 0
    for entry in v.hashMapEntries:
      acc = acc xor (hash(entry.key) !& hash(entry.val))
    h = h !& acc
  of vkNode:
    h = h !& hash(v.head)
    for it in v.body: h = h !& hash(it)
    var acc: Hash = 0
    for k, val in v.props:
      acc = acc xor (hash(k) !& hash(val))
    h = h !& acc
  of vkFunction, vkNativeFn, vkNamespace, vkModule, vkEnv, vkCell, vkAtomicCell,
     vkStream, vkTask, vkChannel, vkActorRef, vkActorContext, vkActorStep,
     vkReplyTo, vkCPtr, vkCSlice, vkBuffer, vkDeviceBuffer, vkCapability, vkFfiLoad,
     vkFfiLibrary, vkFfiCallable, vkType, vkProtocol, vkProtocolMessage,
     vkEnumVariant:
    h = h !& hash(v.bits)
  !$h

proc isHashStable*(v: Value, seen: var HashSet[uint64]): bool =
  if v.kind in {vkList, vkMap, vkSet, vkHashMap, vkNode}:
    if seen.contains(v.bits):
      return true
    seen.incl v.bits

  case v.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkBytes, vkRegex, vkRange,
     vkDate, vkTime, vkDateTime, vkTimezone, vkDuration, vkChar, vkSymbol,
     vkFunction, vkNativeFn, vkNamespace, vkModule, vkEnv, vkStream, vkTask,
     vkChannel, vkActorRef, vkActorContext, vkActorStep, vkReplyTo, vkType,
     vkProtocol, vkProtocolMessage, vkEnumVariant:
    true
  of vkCell, vkAtomicCell, vkCPtr, vkCSlice, vkBuffer, vkDeviceBuffer, vkCapability,
     vkFfiLoad, vkFfiLibrary, vkFfiCallable:
    false
  of vkList:
    if not v.listImmutable:
      return false
    for item in v.listItems:
      if not isHashStable(item, seen):
        return false
    true
  of vkMap:
    if not v.mapImmutable:
      return false
    for _, val in v.mapEntries:
      if not isHashStable(val, seen):
        return false
    true
  of vkSet:
    for item in v.setItems:
      if not isHashStable(item, seen):
        return false
    true
  of vkHashMap:
    for entry in v.hashMapEntries:
      if not isHashStable(entry.key, seen):
        return false
      if not isHashStable(entry.val, seen):
        return false
    true
  of vkNode:
    if not v.nodeImmutable:
      return false
    if not isHashStable(v.head, seen):
      return false
    for _, val in v.props:
      if not isHashStable(val, seen):
        return false
    for item in v.body:
      if not isHashStable(item, seen):
        return false
    true

proc isHashStable*(v: Value): bool =
  var seen = initHashSet[uint64]()
  isHashStable(v, seen)
