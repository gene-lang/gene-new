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
  of vkChar:   int32(a.charVal) == int32(b.charVal)
  of vkSymbol: a.symVal == b.symVal
  of vkList:
    if a.listItems.len != b.listItems.len: return false
    for i in 0 ..< a.listItems.len:
      if not equal(a.listItems[i], b.listItems[i]): return false
    true
  of vkMap:
    tablesEqual(a.mapEntries, b.mapEntries)
  of vkNode:
    # meta-blind: head + props + body only
    if not equal(a.head, b.head): return false
    if a.body.len != b.body.len: return false
    for i in 0 ..< a.body.len:
      if not equal(a.body[i], b.body[i]): return false
    tablesEqual(a.props, b.props)
  of vkFunction, vkNativeFn, vkNamespace, vkModule, vkEnv, vkCell, vkAtomicCell,
     vkStream, vkTask, vkChannel, vkActorRef, vkActorContext, vkActorStep,
     vkReplyTo, vkType, vkProtocol, vkProtocolMessage:
    # callable and opaque runtime values have identity equality
    a.bits == b.bits

proc same*(a, b: Value): bool =
  ## Scalars are representation-independent values, so small and heap-backed
  ## ints follow the same contract. Lists, maps, nodes, and callables use
  ## heap identity.
  if a.kind != b.kind:
    return false
  case a.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkChar, vkSymbol:
    equal(a, b)
  of vkList, vkMap, vkNode, vkFunction, vkNativeFn, vkNamespace, vkModule,
     vkEnv, vkCell, vkAtomicCell, vkStream, vkTask, vkChannel, vkActorRef,
     vkActorContext, vkActorStep, vkReplyTo, vkType, vkProtocol,
     vkProtocolMessage:
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
  of vkChar:   h = h !& hash(int32(v.charVal))
  of vkSymbol: h = h !& hash(v.symVal)
  of vkList:
    for it in v.listItems: h = h !& hash(it)
  of vkMap:
    var acc: Hash = 0
    for k, val in v.mapEntries:
      acc = acc xor (hash(k) !& hash(val))   # order-independent
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
     vkReplyTo, vkType, vkProtocol, vkProtocolMessage:
    h = h !& hash(v.bits)
  !$h

proc isHashStable*(v: Value, seen: var HashSet[uint64]): bool =
  if v.kind in {vkList, vkMap, vkNode}:
    if seen.contains(v.bits):
      return true
    seen.incl v.bits

  case v.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkChar, vkSymbol,
     vkFunction, vkNativeFn, vkNamespace, vkModule, vkEnv, vkStream, vkTask,
     vkChannel, vkActorRef, vkActorContext, vkActorStep, vkReplyTo, vkType,
     vkProtocol, vkProtocolMessage:
    true
  of vkCell, vkAtomicCell:
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
