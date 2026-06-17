## Canonical value / node model for Gene (design Section 1).
##
## Values are represented as a 64-bit NaN-box (`Value.bits`):
##
##   * `bits == 0`                      -> `nil` (so a zero-initialized Value is nil)
##   * top 16 bits < 0xFFF1             -> an IEEE float64 stored directly
##   * top 16 bits in 0xFFF1..0xFFF6    -> a void/bool/small-int/char/+0.0/symbol
##                                         immediate (no allocation)
##   * top 16 bits >= 0xFFF8            -> a *managed* heap pointer (string, list,
##                                         map, node, function, native function, or
##                                         large int) carried in the low 48 bits
##
## Managed objects are manually heap-allocated and reference counted. Each starts
## with a `refCount` header; `Value`'s `=copy`/`=sink`/`=dup`/`=destroy` hooks
## drive retain/release automatically, so values free at count 0 — no global table,
## no per-read lock, no leak. (Adopted from the older Gene runtime.)
##
## TODO(vm-shared-rc): RC is non-atomic and assumes single-threaded mutation, which
## matches the current MVP. When the M:N scheduler lands, give each managed object a
## per-object `shared` flag and switch to atomic inc/dec only for published values
## (see `(freeze)`), keeping thread-local objects on the cheap path.

import std/[locks, tables, unicode]

# Manual reference counting (below) relies on ARC/ORC move semantics and runs
# =copy/=sink/=dup/=destroy over raw alloc0 objects holding GC-managed fields.
# A --mm:refc build would mismanage those fields, so fail fast instead.
when not (defined(gcOrc) or defined(gcArc)):
  {.error: "gene/types requires --mm:orc or --mm:arc (see nim.cfg)".}

type
  GeneError* = object of CatchableError

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
    vkFunction  ## closure: params + body + captured scope
    vkNativeFn  ## built-in function implemented in Nim
    vkNamespace ## named binding container (module root or nested `ns`)

  Value* = object
    bits*: uint64

const
  TAG_SHIFT = 48
  PAYLOAD_MASK = 0x0000_FFFF_FFFF_FFFF'u64

  # Immediate tags (no allocation, no refcount).
  VOID_TAG      = 0xFFF1'u64
  BOOL_TAG      = 0xFFF2'u64
  INT_TAG       = 0xFFF3'u64
  CHAR_TAG      = 0xFFF4'u64
  FLOATZERO_TAG = 0xFFF5'u64
  SYMBOL_TAG    = 0xFFF6'u64

  # Managed tags (heap pointer in payload, refcounted). All >= MANAGED_MIN so the
  # lifecycle hooks can test "needs refcount" with a single shift+compare.
  MANAGED_MIN   = 0xFFF8'u64
  STRING_TAG    = 0xFFF8'u64
  LIST_TAG      = 0xFFF9'u64
  MAP_TAG       = 0xFFFA'u64
  NODE_TAG      = 0xFFFB'u64
  INT64_TAG     = 0xFFFC'u64
  FUNCTION_TAG  = 0xFFFD'u64
  NATIVE_FN_TAG = 0xFFFE'u64
  NAMESPACE_TAG = 0xFFFF'u64
  # NOTE: 0xFFFF is the LAST managed tag (range 0xFFF8..0xFFFF = 8 kinds, all now
  # used). The next heap kind (Stream, Cell, Task, Env, ...) must move to a generic
  # object tag that carries its concrete kind in the object header, instead of a
  # dedicated NaN-box tag per type.

  # A float whose raw bits land in tag space (0xFFF1.. negative NaNs) is folded to
  # this canonical quiet NaN, which lives below tag space and stores directly.
  CANONICAL_NAN = 0x7FF8_0000_0000_0000'u64

  SMALL_INT_MIN = -(1'i64 shl 47)
  SMALL_INT_MAX = (1'i64 shl 47) - 1
  INT_SIGN_BIT  = 0x0000_8000_0000_0000'u64

# ---------------------------------------------------------------------------
# Value lifecycle hooks (must precede any Value-containing type so the managed
# heap objects below pick up these hooks, not an implicitly-generated one).
# ---------------------------------------------------------------------------

proc rcRetain(bits: uint64) {.raises: [].}
proc rcRelease(bits: uint64) {.raises: [].}

proc `=destroy`(v: Value) {.inline.} =
  if (v.bits shr TAG_SHIFT) >= MANAGED_MIN:
    rcRelease(v.bits)

proc `=copy`(dest: var Value, src: Value) {.inline.} =
  if dest.bits == src.bits: return
  if (src.bits shr TAG_SHIFT) >= MANAGED_MIN: rcRetain(src.bits)
  if (dest.bits shr TAG_SHIFT) >= MANAGED_MIN: rcRelease(dest.bits)
  dest.bits = src.bits

proc `=sink`(dest: var Value, src: Value) {.inline.} =
  if (dest.bits shr TAG_SHIFT) >= MANAGED_MIN: rcRelease(dest.bits)
  dest.bits = src.bits

proc `=dup`(src: Value): Value {.inline.} =
  if (src.bits shr TAG_SHIFT) >= MANAGED_MIN: rcRetain(src.bits)
  result.bits = src.bits

type
  ## Props and meta are symbol-keyed ordered maps. Keys are the bare symbol
  ## text (without the leading `^`/`@`). Order is preserved for deterministic
  ## printing per design Section 18.
  PropTable* = OrderedTable[string, Value]

  # Managed heap objects. Manually allocated (alloc0 / dealloc); each begins with
  # a refCount header used by retain/release.
  GeneString = object
    refCount: int
    s: string

  GeneInt64 = object
    refCount: int
    i: int64

  GeneList = object
    refCount: int
    immutable: bool
    items: seq[Value]

  GeneMap = object
    refCount: int
    immutable: bool
    entries: PropTable

  GeneNode = object
    refCount: int
    immutable: bool
    head: Value
    props: PropTable
    body: seq[Value]
    meta: PropTable

  ## Opaque compiled function body used by runtime function values.
  FunctionCode* = ref object of RootObj

  ## Lexical environment for the VM (a Nim ORC ref, so scope cycles are
  ## collectable). A first-class `Env` (design Section 11.1) is a later, richer
  ## concept.
  Scope* = ref object
    parent*: Scope
    vars*: Table[string, Value]

  ## A built-in function implemented in Nim. Positional args only for MVP.
  NativeProc* = proc(args: openArray[Value]): Value {.nimcall.}

  GeneFunction = object
    refCount: int
    name: string
    params: seq[string]
    code: FunctionCode
    scope: Scope

  GeneNativeFn = object
    refCount: int
    name: string
    impl: NativeProc

  GeneNamespace = object
    refCount: int
    name: string
    scope: Scope          # the namespace's own bindings (its exports)

# ---------------------------------------------------------------------------
# Interning (symbols are immediate indices; prop-key strings are deduplicated)
# ---------------------------------------------------------------------------

var
  symbolNames: seq[string]              # symbol id -> text
  symbolIds: Table[string, int]         # text -> symbol id
  internedNames: Table[string, string]  # deduped prop-key strings
  internLock: Lock
initLock(internLock)

# ---------------------------------------------------------------------------
# Low-level box helpers
# ---------------------------------------------------------------------------

template tagOf(v: Value): uint64 = v.bits shr TAG_SHIFT

proc isManaged(v: Value): bool {.inline.} =
  (v.bits shr TAG_SHIFT) >= MANAGED_MIN

proc isImmediateFloat(v: Value): bool {.inline.} =
  ## True when the bits decode as an IEEE float64 stored directly.
  v.bits != 0 and (v.bits shr TAG_SHIFT) < VOID_TAG

proc mkImm(tag: uint64, payload = 0'u64): Value {.inline.} =
  Value(bits: (tag shl TAG_SHIFT) or (payload and PAYLOAD_MASK))

proc boxPtr(tag: uint64, p: pointer): Value {.inline.} =
  Value(bits: (tag shl TAG_SHIFT) or (cast[uint64](p) and PAYLOAD_MASK))

when defined(geneRcStats):
  # Opt-in diagnostic: counts live managed (heap, refcounted) objects so tests can
  # assert that retain/release balance. Zero cost unless `-d:geneRcStats` is set.
  var liveManaged*: int
  template trackAlloc = inc liveManaged
  template trackFree = dec liveManaged
else:
  template trackAlloc = discard
  template trackFree = discard

proc createObj(T: typedesc): ptr T {.inline.} =
  trackAlloc()
  cast[ptr T](alloc0(sizeof(T)))

proc encodeSmallInt(v: int64): uint64 {.inline.} =
  uint64(v) and PAYLOAD_MASK

proc decodeSmallInt(bits: uint64): int64 {.inline.} =
  let raw = bits and PAYLOAD_MASK
  if (raw and INT_SIGN_BIT) != 0:
    cast[int64](raw or not PAYLOAD_MASK)   # sign-extend bits 48..63
  else:
    cast[int64](raw)

# ---------------------------------------------------------------------------
# Reference counting bodies
# ---------------------------------------------------------------------------

proc rcRetain(bits: uint64) =
  case bits shr TAG_SHIFT
  of STRING_TAG: inc cast[ptr GeneString](bits and PAYLOAD_MASK).refCount
  of INT64_TAG:  inc cast[ptr GeneInt64](bits and PAYLOAD_MASK).refCount
  of LIST_TAG:   inc cast[ptr GeneList](bits and PAYLOAD_MASK).refCount
  of MAP_TAG:    inc cast[ptr GeneMap](bits and PAYLOAD_MASK).refCount
  of NODE_TAG:   inc cast[ptr GeneNode](bits and PAYLOAD_MASK).refCount
  of FUNCTION_TAG:  inc cast[ptr GeneFunction](bits and PAYLOAD_MASK).refCount
  of NATIVE_FN_TAG: inc cast[ptr GeneNativeFn](bits and PAYLOAD_MASK).refCount
  of NAMESPACE_TAG: inc cast[ptr GeneNamespace](bits and PAYLOAD_MASK).refCount
  else: discard

proc rcRelease(bits: uint64) =
  let payload = bits and PAYLOAD_MASK
  if payload == 0: return
  case bits shr TAG_SHIFT
  of STRING_TAG:
    let p = cast[ptr GeneString](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  of INT64_TAG:
    let p = cast[ptr GeneInt64](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  of LIST_TAG:
    let p = cast[ptr GeneList](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  of MAP_TAG:
    let p = cast[ptr GeneMap](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  of NODE_TAG:
    let p = cast[ptr GeneNode](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  of FUNCTION_TAG:
    let p = cast[ptr GeneFunction](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  of NATIVE_FN_TAG:
    let p = cast[ptr GeneNativeFn](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  of NAMESPACE_TAG:
    let p = cast[ptr GeneNamespace](payload)
    dec p.refCount
    if p.refCount == 0: reset(p[]); dealloc(p); trackFree()
  else: discard

# ---------------------------------------------------------------------------
# Singletons
# ---------------------------------------------------------------------------

let
  NIL* = Value(bits: 0)
  VOID* = mkImm(VOID_TAG)
  TRUE* = mkImm(BOOL_TAG, 1)
  FALSE* = mkImm(BOOL_TAG, 0)

# ---------------------------------------------------------------------------
# Introspection accessors
# These are read-only projections. Future VM/runtime mutation should use
# dedicated update APIs rather than mutating seq/table values returned here.
# ---------------------------------------------------------------------------

proc isHeapBacked*(v: Value): bool {.inline.} =
  v.isManaged

proc kind*(v: Value): ValueKind {.inline.} =
  if v.bits == 0: return vkNil
  let tag = v.bits shr TAG_SHIFT
  if tag < VOID_TAG: return vkFloat   # direct float (incl. +/-Inf, canonical NaN)
  case tag
  of VOID_TAG: vkVoid
  of BOOL_TAG: vkBool
  of INT_TAG: vkInt
  of CHAR_TAG: vkChar
  of FLOATZERO_TAG: vkFloat
  of SYMBOL_TAG: vkSymbol
  of STRING_TAG: vkString
  of INT64_TAG: vkInt
  of LIST_TAG: vkList
  of MAP_TAG: vkMap
  of NODE_TAG: vkNode
  of FUNCTION_TAG: vkFunction
  of NATIVE_FN_TAG: vkNativeFn
  of NAMESPACE_TAG: vkNamespace
  else: vkNil

proc isNil*(v: Value): bool {.inline.} =
  v.bits == 0

proc boolVal*(v: Value): bool {.inline.} =
  if v.tagOf != BOOL_TAG:
    raise newException(FieldDefect, "value is not a Bool")
  (v.bits and PAYLOAD_MASK) != 0

proc intVal*(v: Value): int64 {.inline.} =
  case v.bits shr TAG_SHIFT
  of INT_TAG: decodeSmallInt(v.bits)
  of INT64_TAG: cast[ptr GeneInt64](v.bits and PAYLOAD_MASK).i
  else: raise newException(FieldDefect, "value is not an Int")

proc floatVal*(v: Value): float64 {.inline.} =
  if v.isImmediateFloat:
    return cast[float64](v.bits)
  if v.tagOf == FLOATZERO_TAG:
    return 0.0
  raise newException(FieldDefect, "value is not a Float")

proc strVal*(v: Value): lent string =
  if v.tagOf != STRING_TAG:
    raise newException(FieldDefect, "value is not a String")
  cast[ptr GeneString](v.bits and PAYLOAD_MASK).s

proc charVal*(v: Value): Rune {.inline.} =
  if v.tagOf != CHAR_TAG:
    raise newException(FieldDefect, "value is not a Char")
  Rune(int32(v.bits and 0xffffffff'u64))

proc symVal*(v: Value): lent string =
  if v.tagOf != SYMBOL_TAG:
    raise newException(FieldDefect, "value is not a Symbol")
  symbolNames[int(v.bits and PAYLOAD_MASK)]

proc listItems*(v: Value): lent seq[Value] =
  if v.tagOf != LIST_TAG:
    raise newException(FieldDefect, "value is not a List")
  cast[ptr GeneList](v.bits and PAYLOAD_MASK).items

proc listImmutable*(v: Value): bool =
  if v.tagOf != LIST_TAG:
    raise newException(FieldDefect, "value is not a List")
  cast[ptr GeneList](v.bits and PAYLOAD_MASK).immutable

proc mapEntries*(v: Value): lent PropTable =
  if v.tagOf != MAP_TAG:
    raise newException(FieldDefect, "value is not a Map")
  cast[ptr GeneMap](v.bits and PAYLOAD_MASK).entries

proc mapImmutable*(v: Value): bool =
  if v.tagOf != MAP_TAG:
    raise newException(FieldDefect, "value is not a Map")
  cast[ptr GeneMap](v.bits and PAYLOAD_MASK).immutable

proc head*(v: Value): Value =
  if v.tagOf != NODE_TAG:
    raise newException(FieldDefect, "value is not a Node")
  cast[ptr GeneNode](v.bits and PAYLOAD_MASK).head

proc props*(v: Value): lent PropTable =
  if v.tagOf != NODE_TAG:
    raise newException(FieldDefect, "value is not a Node")
  cast[ptr GeneNode](v.bits and PAYLOAD_MASK).props

proc body*(v: Value): lent seq[Value] =
  if v.tagOf != NODE_TAG:
    raise newException(FieldDefect, "value is not a Node")
  cast[ptr GeneNode](v.bits and PAYLOAD_MASK).body

proc meta*(v: Value): lent PropTable =
  if v.tagOf != NODE_TAG:
    raise newException(FieldDefect, "value is not a Node")
  cast[ptr GeneNode](v.bits and PAYLOAD_MASK).meta

proc nodeImmutable*(v: Value): bool =
  if v.tagOf != NODE_TAG:
    raise newException(FieldDefect, "value is not a Node")
  cast[ptr GeneNode](v.bits and PAYLOAD_MASK).immutable

proc fnName*(v: Value): lent string =
  if v.tagOf != FUNCTION_TAG:
    raise newException(FieldDefect, "value is not a Function")
  cast[ptr GeneFunction](v.bits and PAYLOAD_MASK).name

proc fnParams*(v: Value): lent seq[string] =
  if v.tagOf != FUNCTION_TAG:
    raise newException(FieldDefect, "value is not a Function")
  cast[ptr GeneFunction](v.bits and PAYLOAD_MASK).params

proc fnCode*(v: Value): FunctionCode =
  if v.tagOf != FUNCTION_TAG:
    raise newException(FieldDefect, "value is not a Function")
  cast[ptr GeneFunction](v.bits and PAYLOAD_MASK).code

proc fnScope*(v: Value): Scope =
  if v.tagOf != FUNCTION_TAG:
    raise newException(FieldDefect, "value is not a Function")
  cast[ptr GeneFunction](v.bits and PAYLOAD_MASK).scope

proc nativeFnName*(v: Value): lent string =
  if v.tagOf != NATIVE_FN_TAG:
    raise newException(FieldDefect, "value is not a NativeFn")
  cast[ptr GeneNativeFn](v.bits and PAYLOAD_MASK).name

proc nativeImpl*(v: Value): NativeProc =
  if v.tagOf != NATIVE_FN_TAG:
    raise newException(FieldDefect, "value is not a NativeFn")
  cast[ptr GeneNativeFn](v.bits and PAYLOAD_MASK).impl

proc nsName*(v: Value): lent string =
  if v.tagOf != NAMESPACE_TAG:
    raise newException(FieldDefect, "value is not a Namespace")
  cast[ptr GeneNamespace](v.bits and PAYLOAD_MASK).name

proc nsScope*(v: Value): Scope =
  if v.tagOf != NAMESPACE_TAG:
    raise newException(FieldDefect, "value is not a Namespace")
  cast[ptr GeneNamespace](v.bits and PAYLOAD_MASK).scope

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newInt*(v: int64): Value {.inline.} =
  if v >= SMALL_INT_MIN and v <= SMALL_INT_MAX:
    mkImm(INT_TAG, encodeSmallInt(v))
  else:
    let p = createObj(GeneInt64)
    p.refCount = 1
    p.i = v
    boxPtr(INT64_TAG, p)

proc newFloat*(v: float64): Value {.inline.} =
  let raw = cast[uint64](v)
  if raw == 0:
    return mkImm(FLOATZERO_TAG)            # +0.0 (raw 0 is reserved for nil)
  if (raw shr TAG_SHIFT) >= VOID_TAG:
    return Value(bits: CANONICAL_NAN)      # negative NaN colliding with tag space
  Value(bits: raw)

proc newStr*(v: sink string): Value =
  let p = createObj(GeneString)
  p.refCount = 1
  p.s = v
  boxPtr(STRING_TAG, p)

proc newChar*(r: Rune): Value {.inline.} =
  mkImm(CHAR_TAG, uint64(int32(r)) and 0xffffffff'u64)

proc newSym*(v: string): Value =
  acquire(internLock)
  try:
    var id = symbolIds.getOrDefault(v, -1)
    if id < 0:
      id = symbolNames.len
      symbolNames.add v
      symbolIds[v] = id
    result = mkImm(SYMBOL_TAG, uint64(id))
  finally:
    release(internLock)

proc newBool*(v: bool): Value {.inline.} =
  if v: TRUE else: FALSE

proc newList*(items: sink seq[Value] = @[], immutable = false): Value =
  let p = createObj(GeneList)
  p.refCount = 1
  p.immutable = immutable
  p.items = items
  boxPtr(LIST_TAG, p)

proc newMap*(entries: sink PropTable = initOrderedTable[string, Value](),
             immutable = false): Value =
  let p = createObj(GeneMap)
  p.refCount = 1
  p.immutable = immutable
  p.entries = entries
  boxPtr(MAP_TAG, p)

proc newNode*(head: Value,
              props: sink PropTable = initOrderedTable[string, Value](),
              body: sink seq[Value] = @[],
              meta: sink PropTable = initOrderedTable[string, Value](),
              immutable = false): Value =
  let p = createObj(GeneNode)
  p.refCount = 1
  p.immutable = immutable
  p.head = head
  p.props = props
  p.body = body
  p.meta = meta
  boxPtr(NODE_TAG, p)

proc newFunction*(name: string, params: sink seq[string],
                  code: FunctionCode, scope: Scope): Value =
  let p = createObj(GeneFunction)
  p.refCount = 1
  p.name = name
  p.params = params
  p.code = code
  p.scope = scope
  boxPtr(FUNCTION_TAG, p)

proc newNativeFn*(name: string, impl: NativeProc): Value =
  let p = createObj(GeneNativeFn)
  p.refCount = 1
  p.name = name
  p.impl = impl
  boxPtr(NATIVE_FN_TAG, p)

proc newNamespace*(name: string, scope: Scope): Value =
  let p = createObj(GeneNamespace)
  p.refCount = 1
  p.name = name
  p.scope = scope
  boxPtr(NAMESPACE_TAG, p)

proc internName*(v: string): string =
  ## Deduplicate a prop-key string so identical keys share storage.
  acquire(internLock)
  try:
    result = internedNames.getOrDefault(v)
    if result.len == 0 and v.len != 0:
      internedNames[v] = v
      result = v
  finally:
    release(internLock)

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
