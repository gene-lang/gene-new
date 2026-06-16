## Canonical value / node model for Gene (design Section 1).
##
## Values are represented as a 64-bit NaN-box. The all-zero bit pattern is
## `nil`, non-zero non-boxed float64 values are stored directly, and reserved
## quiet-NaN payloads encode void/bool/small-int/char/positive-zero-float
## immediates or an index into the current process-local heap table.
##
## TODO(vm-memory): Heap slots are handle-indirected but not reclaimed yet, and
## heap reads currently take a global lock because seq growth can move the slot
## table. Before the VM allocates in hot loops, replace this append-only table
## with a non-moving segmented/generational handle arena that supports lock-free
## reads plus tracing/reclamation or a free-list with stale-handle detection.

import std/[locks, tables, unicode]

type
  ValueKind* = enum
    vkNil       ## explicit absence (`nil` : Nil)
    vkVoid      ## no-value / skip / delete (`void` : Void)
    vkBool
    vkInt       ## MVP: 64-bit; small int64s are immediate, large int64s heap-backed
    vkFloat     ## F64 (design `Float` alias)
    vkString    ## immutable UTF-8 string
    vkChar      ## one Unicode scalar value
    vkSymbol    ## interned simple symbol (Sym)
    vkList      ## pure body / list
    vkMap       ## pure props / PropMap (symbol-keyed)
    vkNode      ## general node (head + props + body + meta)

  Value* = object
    bits*: uint64

  ## Props and meta are symbol-keyed ordered maps. Keys are the bare symbol
  ## text (without the leading `^`/`@`). Order is preserved for deterministic
  ## printing per design Section 18.
  PropTable* = OrderedTable[string, Value]

  HeapValue = ref HeapValueObj
  HeapValueObj = object
    case kind: ValueKind
    of vkInt:
      intVal: int64
    of vkFloat:
      floatVal: float64
    of vkString:
      strVal: string
    of vkSymbol:
      symVal: string
    of vkList:
      listItems: seq[Value]
      listImmutable: bool
    of vkMap:
      mapEntries: PropTable
      mapImmutable: bool
    of vkNode:
      head: Value
      props: PropTable
      body: seq[Value]
      meta: PropTable
      nodeImmutable: bool
    of vkNil, vkVoid, vkBool, vkChar:
      discard

  BoxKind = enum
    bkNil,
    bkVoid,
    bkBool,
    bkInt,
    bkChar,
    bkFloatZero,
    bkHeap

const
  BoxPrefix = 0x7ffc000000000000'u64
  BoxPrefixMask = 0xffff000000000000'u64
  BoxKindShift = 44
  PayloadBits = 44
  PayloadMask = 0x00000fffffffffff'u64
  SmallIntSignBit = 1'u64 shl (PayloadBits - 1)
  SmallIntMin = -(1'i64 shl (PayloadBits - 1))
  SmallIntMax = (1'i64 shl (PayloadBits - 1)) - 1

var heapValues: seq[HeapValue]
var heapLock: Lock
var internLock: Lock
var internedNames = initTable[string, string]()
var internedSymbols = initTable[string, Value]()
initLock(heapLock)
initLock(internLock)

proc isBoxed(v: Value): bool {.inline.} =
  v.bits == 0 or (v.bits and BoxPrefixMask) == BoxPrefix

proc payload(v: Value): uint64 {.inline.} =
  v.bits and PayloadMask

proc boxKind(v: Value): BoxKind {.inline.} =
  BoxKind((v.bits shr BoxKindShift) and 0xf'u64)

proc makeBox(k: BoxKind, payload = 0'u64): Value {.inline.} =
  Value(bits: BoxPrefix or (uint64(ord(k)) shl BoxKindShift) or
              (payload and PayloadMask))

proc addHeap(obj: HeapValue): Value =
  acquire(heapLock)
  try:
    if heapValues.len > int(PayloadMask):
      raise newException(OverflowDefect, "Gene heap value table exhausted")
    heapValues.add obj
    result = makeBox(bkHeap, uint64(heapValues.high))
  finally:
    release(heapLock)

proc internNameLocked(v: string): string =
  if internedNames.hasKey(v):
    return internedNames[v]
  internedNames[v] = v
  internedNames[v]

proc internName*(v: string): string =
  acquire(internLock)
  try:
    result = internNameLocked(v)
  finally:
    release(internLock)

proc internSymbol(v: string): Value =
  acquire(internLock)
  try:
    result = internedSymbols.getOrDefault(v)
    if result.bits != 0:
      return
    let name = internNameLocked(v)
    result = addHeap(HeapValue(kind: vkSymbol, symVal: name))
    internedSymbols[name] = result
  finally:
    release(internLock)

proc heapObj(v: Value): HeapValue =
  if not v.isBoxed or v.boxKind != bkHeap:
    raise newException(FieldDefect, "value is not heap-backed")
  let idx = int(v.payload)
  acquire(heapLock)
  try:
    if idx < 0 or idx >= heapValues.len:
      raise newException(IndexDefect, "invalid heap value index")
    result = heapValues[idx]
  finally:
    release(heapLock)

proc floatToBits(f: float64): uint64 {.inline.} =
  cast[uint64](f)

proc bitsToFloat(bits: uint64): float64 {.inline.} =
  cast[float64](bits)

proc encodeSmallInt(v: int64): uint64 {.inline.} =
  uint64(v) and PayloadMask

proc decodeSmallInt(bits: uint64): int64 {.inline.} =
  let raw = bits and PayloadMask
  if (raw and SmallIntSignBit) != 0:
    -int64(((not raw) and PayloadMask) + 1'u64)
  else:
    int64(raw)

# ---------------------------------------------------------------------------
# Singletons
# ---------------------------------------------------------------------------

let
  NIL* = Value(bits: 0)
  VOID* = makeBox(bkVoid)
  TRUE* = makeBox(bkBool, 1)
  FALSE* = makeBox(bkBool, 0)

# ---------------------------------------------------------------------------
# Introspection accessors
# These are read-only projections. Future VM/runtime mutation should use
# dedicated update APIs rather than mutating seq/table values returned here.
# ---------------------------------------------------------------------------

proc isHeapBacked*(v: Value): bool {.inline.} =
  v.isBoxed and v.boxKind == bkHeap

proc kind*(v: Value): ValueKind {.inline.} =
  if not v.isBoxed:
    return vkFloat
  case v.boxKind
  of bkNil: vkNil
  of bkVoid: vkVoid
  of bkBool: vkBool
  of bkInt: vkInt
  of bkChar: vkChar
  of bkFloatZero: vkFloat
  of bkHeap: v.heapObj.kind

proc isNil*(v: Value): bool {.inline.} =
  v.kind == vkNil

proc boolVal*(v: Value): bool {.inline.} =
  if v.boxKind != bkBool:
    raise newException(FieldDefect, "value is not a Bool")
  v.payload != 0

proc intVal*(v: Value): int64 {.inline.} =
  if not v.isBoxed:
    raise newException(FieldDefect, "value is not an Int")
  case v.boxKind
  of bkInt: decodeSmallInt(v.payload)
  of bkHeap:
    let obj = v.heapObj
    if obj.kind == vkInt: obj.intVal
    else: raise newException(FieldDefect, "value is not an Int")
  else:
    raise newException(FieldDefect, "value is not an Int")

proc floatVal*(v: Value): float64 {.inline.} =
  if not v.isBoxed:
    return bitsToFloat(v.bits)
  if v.boxKind == bkFloatZero:
    return 0.0
  if v.boxKind == bkHeap:
    let obj = v.heapObj
    if obj.kind == vkFloat:
      return obj.floatVal
  raise newException(FieldDefect, "value is not a Float")

proc strVal*(v: Value): lent string =
  let obj = v.heapObj
  if obj.kind != vkString:
    raise newException(FieldDefect, "value is not a String")
  obj.strVal

proc charVal*(v: Value): Rune {.inline.} =
  if not v.isBoxed or v.boxKind != bkChar:
    raise newException(FieldDefect, "value is not a Char")
  Rune(int32(v.payload and 0xffffffff'u64))

proc symVal*(v: Value): lent string =
  let obj = v.heapObj
  if obj.kind != vkSymbol:
    raise newException(FieldDefect, "value is not a Symbol")
  obj.symVal

proc listItems*(v: Value): lent seq[Value] =
  let obj = v.heapObj
  if obj.kind != vkList:
    raise newException(FieldDefect, "value is not a List")
  obj.listItems

proc listImmutable*(v: Value): bool =
  let obj = v.heapObj
  if obj.kind != vkList:
    raise newException(FieldDefect, "value is not a List")
  obj.listImmutable

proc mapEntries*(v: Value): lent PropTable =
  let obj = v.heapObj
  if obj.kind != vkMap:
    raise newException(FieldDefect, "value is not a Map")
  obj.mapEntries

proc mapImmutable*(v: Value): bool =
  let obj = v.heapObj
  if obj.kind != vkMap:
    raise newException(FieldDefect, "value is not a Map")
  obj.mapImmutable

proc head*(v: Value): Value =
  let obj = v.heapObj
  if obj.kind != vkNode:
    raise newException(FieldDefect, "value is not a Node")
  obj.head

proc props*(v: Value): lent PropTable =
  let obj = v.heapObj
  if obj.kind != vkNode:
    raise newException(FieldDefect, "value is not a Node")
  obj.props

proc body*(v: Value): lent seq[Value] =
  let obj = v.heapObj
  if obj.kind != vkNode:
    raise newException(FieldDefect, "value is not a Node")
  obj.body

proc meta*(v: Value): lent PropTable =
  let obj = v.heapObj
  if obj.kind != vkNode:
    raise newException(FieldDefect, "value is not a Node")
  obj.meta

proc nodeImmutable*(v: Value): bool =
  let obj = v.heapObj
  if obj.kind != vkNode:
    raise newException(FieldDefect, "value is not a Node")
  obj.nodeImmutable

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newInt*(v: int64): Value {.inline.} =
  if v >= SmallIntMin and v <= SmallIntMax:
    Value(bits: BoxPrefix or (uint64(ord(bkInt)) shl BoxKindShift) or encodeSmallInt(v))
  else:
    addHeap(HeapValue(kind: vkInt, intVal: v))

proc newFloat*(v: float64): Value {.inline.} =
  var bits = floatToBits(v)
  if bits == 0:
    return makeBox(bkFloatZero)
  if (bits and BoxPrefixMask) == BoxPrefix:
    return addHeap(HeapValue(kind: vkFloat, floatVal: v))
  Value(bits: bits)

proc newStr*(v: sink string): Value =
  addHeap(HeapValue(kind: vkString, strVal: v))

proc newChar*(r: Rune): Value {.inline.} =
  makeBox(bkChar, uint64(int32(r)) and 0xffffffff'u64)

proc newSym*(v: string): Value =
  internSymbol(v)

proc newBool*(v: bool): Value {.inline.} =
  if v: TRUE else: FALSE

proc newList*(items: sink seq[Value] = @[], immutable = false): Value =
  addHeap(HeapValue(kind: vkList, listItems: items, listImmutable: immutable))

proc newMap*(entries: sink PropTable = initOrderedTable[string, Value](),
             immutable = false): Value =
  addHeap(HeapValue(kind: vkMap, mapEntries: entries, mapImmutable: immutable))

proc newNode*(head: Value,
              props: sink PropTable = initOrderedTable[string, Value](),
              body: sink seq[Value] = @[],
              meta: sink PropTable = initOrderedTable[string, Value](),
              immutable = false): Value =
  addHeap(HeapValue(kind: vkNode, head: head,
                    props: props, body: body, meta: meta,
                    nodeImmutable: immutable))

# ---------------------------------------------------------------------------
# Node projections (design Section 1.2 / 1.3). Scalars are fixpoints.
# ---------------------------------------------------------------------------

proc headOf*(v: Value): Value =
  if v.kind == vkNode: v.head else: v

proc propsOf*(v: Value): PropTable =
  case v.kind
  of vkNode: v.props
  of vkMap: v.mapEntries
  else: initOrderedTable[string, Value]()

proc bodyOf*(v: Value): seq[Value] =
  case v.kind
  of vkNode: v.body
  of vkList: v.listItems
  else: @[]

proc metaOf*(v: Value): PropTable =
  if v.kind == vkNode: v.meta
  else: initOrderedTable[string, Value]()

# ---------------------------------------------------------------------------
# Truthiness (design Section 1.6): false, nil, void are falsy.
# ---------------------------------------------------------------------------

proc isTruthy*(v: Value): bool {.inline.} =
  case v.kind
  of vkNil, vkVoid: false
  of vkBool: v.boolVal
  else: true

proc isImmutable*(v: Value): bool =
  case v.kind
  of vkList: v.listImmutable
  of vkMap: v.mapImmutable
  of vkNode: v.nodeImmutable
  else: false
