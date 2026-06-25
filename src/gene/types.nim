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
## drive retain/release automatically, so acyclic values free at count 0 — no
## global table, no per-read lock. (Adopted from the older Gene runtime.)
##
## Cycles: the `scope -> closure -> scope` case is broken with weak captured-scope
## edges (see `Scope`/`GeneFunction`). Cycles among mutable ORC-backed objects
## reached through a `Value` (e.g. a self-referential `cell`) are NOT yet collected
## — ORC cannot trace through the NaN-boxed pointer. design.md §11.1/§13 requires
## tracing collection of these; see `tests/test_rc.nim`. (Adopted from older Gene.)
##
## TODO(vm-shared-rc): RC is non-atomic and assumes single-threaded mutation, which
## matches the current MVP. When the M:N scheduler lands, give each managed object a
## per-object `shared` flag and switch to atomic inc/dec only for published values
## (see `(freeze)`), keeping thread-local objects on the cheap path.

import std/[locks, strutils, tables, unicode]

# Manual reference counting (below) relies on ARC/ORC move semantics and runs
# =copy/=sink/=dup/=destroy over raw alloc0 objects holding GC-managed fields.
# A --mm:refc build would mismanage those fields, so fail fast instead.
when not (defined(gcOrc) or defined(gcArc)):
  {.error: "gene/types requires --mm:orc or --mm:arc (see nim.cfg)".}

type
  GeneError* = object of CatchableError
    ## Recoverable Gene error. `errVal` carries a `fail`ed Gene value (e.g. an
    ## error node); `hasErrVal` distinguishes that from a plain internal error.
    errVal*: Value
    hasErrVal*: bool
  MatchError* = object of GeneError    ## pattern match / destructuring failure
  GenePanic* = object of CatchableError
    ## Unrecoverable failure (`panic`). Not caught by `try/catch`.
    errVal*: Value
    hasErrVal*: bool
  GeneCancel* = object of CatchableError
    ## Cooperative task cancellation. Not caught by ordinary Gene `try/catch`.

  ValueKind* = enum
    vkNil       ## explicit absence (`nil` : Nil)
    vkVoid      ## no-value / skip / delete (`void` : Void)
    vkBool
    vkInt       ## mathematical Int; fixnums/int64 fast paths, bigint on overflow
    vkFloat     ## F64 (design `Float` alias)
    vkString    ## immutable UTF-8 string
    vkChar      ## one Unicode scalar value
    vkSymbol    ## interned simple symbol (Sym)
    vkList      ## pure body / list
    vkMap       ## pure props / PropMap (symbol-keyed)
    vkNode      ## general node (head + props + body + meta)
    vkFunction  ## closure: params + body + captured scope
    vkNativeFn  ## built-in function implemented in Nim
    vkNamespace ## named binding container (`ns` or module root namespace)
    vkModule    ## first-class module value with a root namespace
    vkEnv       ## first-class eval environment (design Section 11.1 MVP)
    vkCell      ## first-class mutable reference (design Section 12.2)
    vkAtomicCell ## first-class shared mutable reference (design Section 12.3)
    vkStream    ## first-class pull stream (design Section 6)
    vkTask      ## first-class structured task handle (design Section 13)
    vkChannel   ## first-class bounded FIFO channel (design Section 13.2)
    vkActorRef  ## first-class actor reference (design Section 13.4)
    vkActorContext ## opaque actor handler context
    vkActorStep ## actor handler continuation/stop result
    vkReplyTo   ## one-shot actor request/reply capability
    vkType      ## a declared nominal type (design Section 7)
    vkProtocol  ## a declared protocol (design Section 10)
    vkProtocolMessage ## callable protocol message dispatcher

  ActorFailureStrategy* = enum
    afsStop
    afsRestart
    afsEscalate

  Value* = object
    bits*: uint64

  BigIntValue = object
    sign: int8                 # -1, 0, or 1
    digits: seq[uint32]        # little-endian base-1e9 limbs

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
  # 0xFFFF is the generic object tag: an open-ended set of heap kinds (namespace,
  # type, and future stream/cell/task/...) that carry their concrete `ObjKind` in
  # the object header. The payload is a GC-managed (ORC) ref; the lifecycle hooks
  # GC_ref/GC_unref it. The dedicated tags above stay for the hot core kinds.
  OBJECT_TAG    = 0xFFFF'u64

  # A float whose raw bits land in tag space (0xFFF1.. negative NaNs) is folded to
  # this canonical quiet NaN, which lives below tag space and stores directly.
  CANONICAL_NAN = 0x7FF8_0000_0000_0000'u64

  SMALL_INT_MIN = -(1'i64 shl 47)
  SMALL_INT_MAX = (1'i64 shl 47) - 1
  INT_SIGN_BIT  = 0x0000_8000_0000_0000'u64

  BIG_BASE = 1_000_000_000'u64
  BIG_BASE_DIGITS = 9

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

  ProtocolImpl* = object
    protocol*: Value
    receiver*: Value
    messages*: Table[string, Value]

  TypeBinding* = object
    expr*: Value
    scope*: Scope

  ## Opaque compiled function body used by runtime function values.
  FunctionCode* = ref object of RootObj

  ## Opaque runtime owner for scopes. The VM defines the concrete Application
  ## type; the value layer keeps only this base reference.
  RuntimeContext* = ref object of RootObj

  ## Shared instruction budget for policy-limited eval scopes. Budgets can be
  ## chained so nested evals with their own policy still consume the outer budget.
  EvalBudget* = ref object
    remaining*: int64
    parent*: EvalBudget

  ## Lexical environment for the VM (a Nim ORC ref, so pure scope/namespace
  ## cycles are collectable). A first-class `Env` (design Section 11.1) is a
  ## later, richer concept.
  ##
  ## Scope-owned functions are stored with a weak captured-scope edge so a
  ## `Scope -> Value(fn) -> Scope` cycle does not keep both sides alive. Function
  ## values escaping as run/eval results are cloned back to a strong capture.
  Scope* = ref object
    application*: RuntimeContext
    parent*: Scope
    vars*: Table[string, Value]
    slots*: seq[Value]
    slotTypes*: seq[TypeBinding]
    slotDefinedBits*: uint64
    slotDefinedOverflow*: seq[bool]
    slotNames*: seq[string]
    slotMirror*: bool
    varTypes*: Table[string, TypeBinding]
    impls*: seq[ProtocolImpl]
    requiredImplTypes*: seq[Value]
    evalBudget*: EvalBudget
    ownsActors*: bool
    actorFailureStrategy*: ActorFailureStrategy
    ownedActors*: seq[Value]

  ## Runtime call metadata for envelope-aware native functions. Positional
  ## arguments stay as an openArray parameter on NativeProc to keep the hot
  ## builtin path allocation-free.
  NativeCall* = object
    calleeName*: string
    namedNames*: seq[string]
    namedValues*: seq[Value]
    dispatchScope*: Scope
    site*: Value             # the source call-site node, or NIL (design §3)

  NativeProc* = proc(args: openArray[Value]): Value {.nimcall.}
  NativeCallProc* = proc(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.}

  GeneFunction = object
    refCount: int
    name: string
    params: seq[string]
    code: FunctionCode
    scope: Scope             # strong capture for escaping closures
    weakScope: pointer       # non-owning Scope used for scope-owned bindings
    checksErrors: bool
    errorTypes: seq[Value]

  GeneNativeFn = object
    refCount: int
    name: string
    impl: NativeProc
    callImpl: NativeCallProc
    acceptsNamed: bool

  # OBJECT_TAG heap kinds. `GeneObjectData` is the GC-managed (ORC) base; each
  # concrete kind subclasses it and `kind*` dispatches on `objKind`.
  ObjKind* = enum
    okNamespace
    okModule
    okBigInt
    okEnv
    okCell
    okAtomicCell
    okStream
    okTask
    okChannel
    okActorRef
    okActorContext
    okActorStep
    okReplyTo
    okType
    okProtocol
    okProtocolMessage

  GeneObjectData* = ref object of RootObj
    objKind*: ObjKind

  NamespaceData = ref object of GeneObjectData
    name: string
    scope: Scope          # the namespace's own bindings (its exports)
    moduleRoot: bool      # true only for loader-created module root namespaces
    modulePath: string    # non-empty only for file-backed module roots

  ModuleData = ref object of GeneObjectData
    name: string
    path: string
    root: Value
    meta: PropTable

  BigIntData = ref object of GeneObjectData
    value: BigIntValue

  EnvData = ref object of GeneObjectData
    parent: Value         # parent Env value, or NIL
    bindings: Table[string, Value]
    imports: seq[Value]
    module: Value
    capabilities: Value
    policy: Value

  CellData = ref object of GeneObjectData
    value: Value

  StreamPullResult* = object
    has*: bool
    item*: Value

  StreamPullProc* = proc(stream: Value): StreamPullResult {.nimcall.}

  StreamData = ref object of GeneObjectData
    items: seq[Value]
    index: int
    closed: bool
    source: Value
    callable: Value
    remaining: int64
    pull: StreamPullProc
    buffered: bool
    buffer: Value
    itemType: Value
    errType: Value
    itemScope: Scope
    generatorCode: FunctionCode
    generatorScope: Scope
    generatorStack: seq[Value]
    generatorIp: int

  TaskData = ref object of GeneObjectData
    done: bool
    cancelled: bool
    awaited: bool
    result: Value
    errorMsg: string
    errorValue: Value
    hasErrorValue: bool
    panicMsg: string
    panicValue: Value
    hasPanicValue: bool

  ChannelState = ref object
    items: seq[Value]
    capacity: int
    closed: bool

  ChannelData = ref object of GeneObjectData
    state: ChannelState
    itemType: Value
    itemScope: Scope

  ActorMessage* = object
    message*: Value
    reply*: Value

  ActorLifecycle = ref object
    closed: bool

  ActorData = ref object of GeneObjectData
    lifecycle: ActorLifecycle
    capacity: int
    queue: seq[ActorMessage]
    processing: bool
    state: Value
    restartInit: Value
    handler: Value
    messageType: Value
    failureStrategy: ActorFailureStrategy

  ActorContextData = ref object of GeneObjectData
    actor: Value

  ActorStepData = ref object of GeneObjectData
    continueActor: bool
    state: Value

  ReplyToData = ref object of GeneObjectData
    sent: bool
    result: Value
    resultType: Value
    resultScope: Scope
    task: Value

  TypeData = ref object of GeneObjectData
    name: string
    parent: Value         # parent Type value, or NIL
    fields: seq[TypeField]
    bodyFields: seq[TypeBodyField]
    scope: Scope          # strong only for future escaped-type anchoring
    weakScope: pointer    # defining scope for scope-owned type metadata
    requiredProtocols: seq[Value]
    derivedProtocols: seq[Value]
    deriveRequests: seq[Value]

  TypeField* = object
    name*: string
    optional*: bool       # `^name?` — may be omitted at construction
    typeExpr*: Value      # annotation syntax, or NIL for `Any`
    scope*: Scope         # strong only for future escaped-field anchoring
    weakScope*: pointer   # defining scope for scope-owned field metadata

  TypeBodyField* = object
    rest*: bool            # trailing `T...` body schema
    typeExpr*: Value       # annotation syntax, or NIL for `Any`
    scope*: Scope
    weakScope*: pointer

  ProtocolData = ref object of GeneObjectData
    name: string
    messages: OrderedTable[string, Value]
    deriveFn: Value

  ProtocolMessageData = ref object of GeneObjectData
    name: string
    protocolBits: uint64  # non-owning backreference to the owning Protocol

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

proc objData(v: Value): GeneObjectData {.inline.} =
  cast[GeneObjectData](cast[pointer](v.bits and PAYLOAD_MASK))

proc boxObject(data: GeneObjectData): Value =
  GC_ref(data)                                   # the box holds one reference
  Value(bits: (OBJECT_TAG shl TAG_SHIFT) or
              (cast[uint64](cast[pointer](data)) and PAYLOAD_MASK))

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

proc normalizeBig(x: var BigIntValue) =
  while x.digits.len > 0 and x.digits[^1] == 0'u32:
    x.digits.setLen(x.digits.len - 1)
  if x.digits.len == 0:
    x.sign = 0
  elif x.sign == 0:
    x.sign = 1

proc bigZero(): BigIntValue =
  BigIntValue(sign: 0, digits: @[])

proc bigFromUInt64(mag: uint64, sign: int8): BigIntValue =
  if mag == 0:
    return bigZero()
  result.sign = sign
  var n = mag
  while n > 0:
    result.digits.add uint32(n mod BIG_BASE)
    n = n div BIG_BASE
  result.normalizeBig()

proc bigFromInt64(v: int64): BigIntValue =
  if v == 0:
    return bigZero()
  if v < 0:
    bigFromUInt64(uint64(-(v + 1)) + 1'u64, -1)
  else:
    bigFromUInt64(uint64(v), 1)

proc cmpAbs(a, b: BigIntValue): int =
  if a.digits.len < b.digits.len: return -1
  if a.digits.len > b.digits.len: return 1
  for i in countdown(a.digits.len - 1, 0):
    if a.digits[i] < b.digits[i]: return -1
    if a.digits[i] > b.digits[i]: return 1
  0

proc cmpBig(a, b: BigIntValue): int =
  if a.sign < b.sign: return -1
  if a.sign > b.sign: return 1
  if a.sign == 0: return 0
  let c = cmpAbs(a, b)
  if a.sign > 0: c else: -c

proc addAbs(a, b: BigIntValue): BigIntValue =
  result.sign = 1
  let n = max(a.digits.len, b.digits.len)
  result.digits = newSeq[uint32](n)
  var carry: uint64
  for i in 0 ..< n:
    let av = if i < a.digits.len: uint64(a.digits[i]) else: 0'u64
    let bv = if i < b.digits.len: uint64(b.digits[i]) else: 0'u64
    let s = av + bv + carry
    result.digits[i] = uint32(s mod BIG_BASE)
    carry = s div BIG_BASE
  if carry > 0:
    result.digits.add uint32(carry)
  result.normalizeBig()

proc subAbs(a, b: BigIntValue): BigIntValue =
  ## Absolute subtraction; requires |a| >= |b|.
  result.sign = 1
  result.digits = newSeq[uint32](a.digits.len)
  var borrow: int64
  for i in 0 ..< a.digits.len:
    let av = int64(a.digits[i]) - borrow
    let bv = if i < b.digits.len: int64(b.digits[i]) else: 0'i64
    var d = av - bv
    if d < 0:
      d += int64(BIG_BASE)
      borrow = 1
    else:
      borrow = 0
    result.digits[i] = uint32(d)
  result.normalizeBig()

proc negBig(a: BigIntValue): BigIntValue =
  result = a
  result.sign = -result.sign

proc addBig(a, b: BigIntValue): BigIntValue =
  if a.sign == 0: return b
  if b.sign == 0: return a
  if a.sign == b.sign:
    result = addAbs(a, b)
    result.sign = a.sign
    return
  let c = cmpAbs(a, b)
  if c == 0:
    return bigZero()
  if c > 0:
    result = subAbs(a, b)
    result.sign = a.sign
  else:
    result = subAbs(b, a)
    result.sign = b.sign

proc subBig(a, b: BigIntValue): BigIntValue =
  addBig(a, negBig(b))

proc mulAbsSmall(a: BigIntValue, small: uint32): BigIntValue =
  if a.sign == 0 or small == 0:
    return bigZero()
  result.sign = 1
  result.digits = newSeq[uint32](a.digits.len)
  var carry: uint64
  for i in 0 ..< a.digits.len:
    let p = uint64(a.digits[i]) * uint64(small) + carry
    result.digits[i] = uint32(p mod BIG_BASE)
    carry = p div BIG_BASE
  if carry > 0:
    result.digits.add uint32(carry)
  result.normalizeBig()

proc mulBig(a, b: BigIntValue): BigIntValue =
  if a.sign == 0 or b.sign == 0:
    return bigZero()
  result.sign = a.sign * b.sign
  result.digits = newSeq[uint32](a.digits.len + b.digits.len)
  for i in 0 ..< a.digits.len:
    var carry: uint64
    for j in 0 ..< b.digits.len:
      let idx = i + j
      let p = uint64(result.digits[idx]) +
        uint64(a.digits[i]) * uint64(b.digits[j]) + carry
      result.digits[idx] = uint32(p mod BIG_BASE)
      carry = p div BIG_BASE
    var idx = i + b.digits.len
    while carry > 0:
      if idx >= result.digits.len:
        result.digits.add 0
      let s = uint64(result.digits[idx]) + carry
      result.digits[idx] = uint32(s mod BIG_BASE)
      carry = s div BIG_BASE
      inc idx
  result.normalizeBig()

proc divModSmallAbs(a: BigIntValue, small: uint32): tuple[q: BigIntValue, r: uint32] =
  if small == 0:
    raise newException(FieldDefect, "division by zero")
  if a.sign == 0:
    return (bigZero(), 0'u32)
  result.q.sign = 1
  result.q.digits = newSeq[uint32](a.digits.len)
  var rem: uint64
  for i in countdown(a.digits.len - 1, 0):
    let cur = rem * BIG_BASE + uint64(a.digits[i])
    result.q.digits[i] = uint32(cur div uint64(small))
    rem = cur mod uint64(small)
  result.r = uint32(rem)
  result.q.normalizeBig()

proc shiftAddDigit(rem: BigIntValue, digit: uint32): BigIntValue =
  if rem.sign == 0 and digit == 0:
    return bigZero()
  result.sign = 1
  result.digits = newSeq[uint32](rem.digits.len + 1)
  result.digits[0] = digit
  for i in 0 ..< rem.digits.len:
    result.digits[i + 1] = rem.digits[i]
  result.normalizeBig()

proc divAbs(a, b: BigIntValue): BigIntValue =
  if b.sign == 0:
    raise newException(FieldDefect, "division by zero")
  let c = cmpAbs(a, b)
  if c < 0: return bigZero()
  if c == 0: return bigFromUInt64(1, 1)
  if b.digits.len == 1:
    return divModSmallAbs(a, b.digits[0]).q

  result.sign = 1
  result.digits = newSeq[uint32](a.digits.len)
  var rem = bigZero()
  for i in countdown(a.digits.len - 1, 0):
    rem = shiftAddDigit(rem, a.digits[i])
    var lo: uint64 = 0
    var hi: uint64 = BIG_BASE - 1
    var qdigit: uint32 = 0
    while lo <= hi:
      let mid = (lo + hi) div 2
      let prod = mulAbsSmall(b, uint32(mid))
      if cmpAbs(prod, rem) <= 0:
        qdigit = uint32(mid)
        lo = mid + 1
      else:
        if mid == 0: break
        hi = mid - 1
    result.digits[i] = qdigit
    if qdigit != 0:
      rem = subAbs(rem, mulAbsSmall(b, qdigit))
  result.normalizeBig()

proc divBig(a, b: BigIntValue): BigIntValue =
  if b.sign == 0:
    raise newException(FieldDefect, "division by zero")
  if a.sign == 0:
    return bigZero()
  result = divAbs(a, b)
  if result.sign != 0:
    result.sign = a.sign * b.sign

proc absFitsInt64(x: BigIntValue, negative: bool): bool =
  let limit =
    if negative: bigFromUInt64(1'u64 shl 63, 1)
    else: bigFromUInt64(uint64(high(int64)), 1)
  cmpAbs(x, limit) <= 0

proc bigToInt64(x: BigIntValue): tuple[ok: bool, value: int64] =
  if x.sign == 0:
    return (true, 0'i64)
  let negative = x.sign < 0
  if not absFitsInt64(x, negative):
    return (false, 0'i64)
  var mag: uint64
  for i in countdown(x.digits.len - 1, 0):
    mag = mag * BIG_BASE + uint64(x.digits[i])
  if negative:
    if mag == (1'u64 shl 63):
      (true, low(int64))
    else:
      (true, -int64(mag))
  else:
    (true, int64(mag))

proc parseBigDecimal(s: string): BigIntValue =
  var i = 0
  var sign: int8 = 1
  if s.len > 0 and s[0] == '-':
    sign = -1
    i = 1
  if i >= s.len:
    raise newException(FieldDefect, "invalid integer literal")
  result = bigZero()
  while i < s.len:
    let ch = s[i]
    if ch < '0' or ch > '9':
      raise newException(FieldDefect, "invalid integer literal")
    result = addBig(mulAbsSmall(result, 10),
                    bigFromUInt64(uint64(ord(ch) - ord('0')), 1))
    inc i
  if result.sign != 0:
    result.sign = sign

proc bigToString(x: BigIntValue): string =
  if x.sign == 0:
    return "0"
  if x.sign < 0:
    result.add '-'
  result.add $x.digits[^1]
  for i in countdown(x.digits.len - 2, 0):
    let part = $x.digits[i]
    result.add repeat("0", BIG_BASE_DIGITS - part.len)
    result.add part

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
  of OBJECT_TAG: GC_ref(cast[GeneObjectData](cast[pointer](bits and PAYLOAD_MASK)))
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
  of OBJECT_TAG:
    # TODO(orc-cycles): this manual GC_unref frees ORC objects immediately at
    # refcount 0, which is incompatible with ORC's deferred cycle collector.
    # As a result, cycles among mutable OBJECT_TAG objects reached through a
    # Value (e.g. a self-referential cell) leak (design.md §11.1/§13; tracked by
    # the "KNOWN GAP" suite in tests/test_rc.nim). Fix: make OBJECT_TAG objects
    # fully ORC-managed (no manual free here) and add a `=trace` hook on Value.
    GC_unref(cast[GeneObjectData](cast[pointer](payload)))
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
  of OBJECT_TAG:
    case objData(v).objKind
    of okNamespace: vkNamespace
    of okModule: vkModule
    of okBigInt: vkInt
    of okEnv: vkEnv
    of okCell: vkCell
    of okAtomicCell: vkAtomicCell
    of okStream: vkStream
    of okTask: vkTask
    of okChannel: vkChannel
    of okActorRef: vkActorRef
    of okActorContext: vkActorContext
    of okActorStep: vkActorStep
    of okReplyTo: vkReplyTo
    of okType: vkType
    of okProtocol: vkProtocol
    of okProtocolMessage: vkProtocolMessage
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
  of OBJECT_TAG:
    if objData(v).objKind == okBigInt:
      let converted = bigToInt64(BigIntData(objData(v)).value)
      if converted.ok:
        return converted.value
      raise newException(FieldDefect, "Int does not fit in int64")
    raise newException(FieldDefect, "value is not an Int")
  else:
    raise newException(FieldDefect, "value is not an Int")

proc intFitsInt64*(v: Value): bool =
  if v.kind != vkInt:
    return false
  try:
    discard v.intVal
    true
  except FieldDefect:
    false

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

proc setListItem*(v: Value, index: int, value: Value) =
  if v.tagOf != LIST_TAG:
    raise newException(FieldDefect, "value is not a List")
  let p = cast[ptr GeneList](v.bits and PAYLOAD_MASK)
  if p.immutable:
    raise newException(GeneError, "cannot mutate immutable List")
  p.items[index] = (if value.kind == vkVoid: NIL else: value)

proc putMapEntry*(v: Value, key: string, value: Value) =
  if v.tagOf != MAP_TAG:
    raise newException(FieldDefect, "value is not a Map")
  let p = cast[ptr GeneMap](v.bits and PAYLOAD_MASK)
  if p.immutable:
    raise newException(GeneError, "cannot mutate immutable Map")
  if value.kind == vkVoid:
    p.entries.del(key)
  else:
    p.entries[key] = value

proc setNodeProp*(v: Value, key: string, value: Value) =
  if v.tagOf != NODE_TAG:
    raise newException(FieldDefect, "value is not a Node")
  let p = cast[ptr GeneNode](v.bits and PAYLOAD_MASK)
  if p.immutable:
    raise newException(GeneError, "cannot mutate immutable Node")
  if value.kind == vkVoid:
    p.props.del(key)
  else:
    p.props[key] = value

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
  let fn = cast[ptr GeneFunction](v.bits and PAYLOAD_MASK)
  if fn.scope != nil:
    fn.scope
  else:
    cast[Scope](fn.weakScope)

proc fnHasWeakScope*(v: Value): bool =
  if v.tagOf != FUNCTION_TAG:
    raise newException(FieldDefect, "value is not a Function")
  let fn = cast[ptr GeneFunction](v.bits and PAYLOAD_MASK)
  fn.scope == nil and fn.weakScope != nil

proc fnChecksErrors*(v: Value): bool =
  if v.tagOf != FUNCTION_TAG:
    raise newException(FieldDefect, "value is not a Function")
  cast[ptr GeneFunction](v.bits and PAYLOAD_MASK).checksErrors

proc fnErrorTypes*(v: Value): lent seq[Value] =
  if v.tagOf != FUNCTION_TAG:
    raise newException(FieldDefect, "value is not a Function")
  cast[ptr GeneFunction](v.bits and PAYLOAD_MASK).errorTypes

proc nativeFnName*(v: Value): lent string {.inline.} =
  if v.tagOf != NATIVE_FN_TAG:
    raise newException(FieldDefect, "value is not a NativeFn")
  cast[ptr GeneNativeFn](v.bits and PAYLOAD_MASK).name

proc nativeImpl*(v: Value): NativeProc {.inline.} =
  if v.tagOf != NATIVE_FN_TAG:
    raise newException(FieldDefect, "value is not a NativeFn")
  cast[ptr GeneNativeFn](v.bits and PAYLOAD_MASK).impl

proc nativeCallImpl*(v: Value): NativeCallProc {.inline.} =
  if v.tagOf != NATIVE_FN_TAG:
    raise newException(FieldDefect, "value is not a NativeFn")
  cast[ptr GeneNativeFn](v.bits and PAYLOAD_MASK).callImpl

proc nativeAcceptsNamed*(v: Value): bool {.inline.} =
  if v.tagOf != NATIVE_FN_TAG:
    raise newException(FieldDefect, "value is not a NativeFn")
  cast[ptr GeneNativeFn](v.bits and PAYLOAD_MASK).acceptsNamed

proc escapeWeakFunctions*(v: Value): Value

proc nsName*(v: Value): lent string =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okNamespace:
    raise newException(FieldDefect, "value is not a Namespace")
  NamespaceData(objData(v)).name

proc setNsName*(v: Value, name: sink string) =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okNamespace:
    raise newException(FieldDefect, "value is not a Namespace")
  NamespaceData(objData(v)).name = name

proc nsScope*(v: Value): Scope =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okNamespace:
    raise newException(FieldDefect, "value is not a Namespace")
  NamespaceData(objData(v)).scope

proc nsModulePath*(v: Value): lent string =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okNamespace:
    raise newException(FieldDefect, "value is not a Namespace")
  NamespaceData(objData(v)).modulePath

proc nsIsModuleRoot*(v: Value): bool =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okNamespace:
    raise newException(FieldDefect, "value is not a Namespace")
  NamespaceData(objData(v)).moduleRoot

proc moduleName*(v: Value): lent string =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okModule:
    raise newException(FieldDefect, "value is not a Module")
  ModuleData(objData(v)).name

proc setModuleName*(v: Value, name: sink string) =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okModule:
    raise newException(FieldDefect, "value is not a Module")
  let data = ModuleData(objData(v))
  data.name = name
  if data.root.kind == vkNamespace:
    data.root.setNsName(data.name)

proc modulePath*(v: Value): lent string =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okModule:
    raise newException(FieldDefect, "value is not a Module")
  ModuleData(objData(v)).path

proc moduleRootNamespace*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okModule:
    raise newException(FieldDefect, "value is not a Module")
  ModuleData(objData(v)).root

proc moduleMeta*(v: Value): lent PropTable =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okModule:
    raise newException(FieldDefect, "value is not a Module")
  ModuleData(objData(v)).meta

proc setModuleMeta*(v: Value, meta: sink PropTable) =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okModule:
    raise newException(FieldDefect, "value is not a Module")
  ModuleData(objData(v)).meta = meta

proc envParent*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).parent

proc envBindings*(v: Value): lent Table[string, Value] =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).bindings

proc envImports*(v: Value): lent seq[Value] =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).imports

proc envModule*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).module

proc envCapabilities*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).capabilities

proc envPolicy*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).policy

proc cellValue*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okCell:
    raise newException(FieldDefect, "value is not a Cell")
  CellData(objData(v)).value

proc setCellValue*(v, newValue: Value) =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okCell:
    raise newException(FieldDefect, "value is not a Cell")
  CellData(objData(v)).value = newValue

proc atomicCellValue*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okAtomicCell:
    raise newException(FieldDefect, "value is not an AtomicCell")
  CellData(objData(v)).value

proc setAtomicCellValue*(v, newValue: Value) =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okAtomicCell:
    raise newException(FieldDefect, "value is not an AtomicCell")
  CellData(objData(v)).value = newValue

proc streamData(v: Value): StreamData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okStream:
    raise newException(FieldDefect, "value is not a Stream")
  StreamData(objData(v))

proc skipStreamVoids(data: StreamData) =
  while not data.closed and data.index < data.items.len and
      data.items[data.index].kind == vkVoid:
    inc data.index

proc fillStreamBuffer(stream: Value, data: StreamData): bool =
  if data.buffered:
    return true
  while not data.closed:
    let pulled = data.pull(stream)
    if not pulled.has:
      data.closed = true
      data.buffer = NIL
      return false
    if pulled.item.kind != vkVoid:
      data.buffer = pulled.item
      data.buffered = true
      return true
  false

proc streamHasNext*(v: Value): bool =
  let data = streamData(v)
  if data.pull != nil:
    return fillStreamBuffer(v, data)
  if data.source.kind == vkStream:
    return not data.closed and data.source.streamHasNext()
  data.skipStreamVoids()
  not data.closed and data.index < data.items.len

proc streamPeek*(v: Value): Value =
  if not v.streamHasNext:
    raise newException(FieldDefect, "stream is exhausted")
  let data = streamData(v)
  if data.pull != nil:
    return data.buffer
  if data.source.kind == vkStream:
    return data.source.streamPeek
  data.items[data.index]

proc streamNext*(v: Value): Value =
  result = v.streamPeek
  let data = streamData(v)
  if data.pull != nil:
    data.buffered = false
    data.buffer = NIL
    return
  if data.source.kind == vkStream:
    discard data.source.streamNext
  else:
    inc data.index

proc closeStream*(v: Value) =
  let data = streamData(v)
  data.closed = true
  data.buffered = false
  data.buffer = NIL
  data.generatorCode = nil
  data.generatorScope = nil
  data.generatorStack.setLen(0)
  data.generatorIp = 0
  if data.source.kind == vkStream:
    data.source.closeStream()
  else:
    data.index = data.items.len

proc streamSource*(v: Value): Value =
  streamData(v).source

proc streamCallable*(v: Value): Value =
  streamData(v).callable

proc streamRemaining*(v: Value): int64 =
  streamData(v).remaining

proc setStreamRemaining*(v: Value, remaining: int64) =
  streamData(v).remaining = remaining

proc streamItemType*(v: Value): Value =
  streamData(v).itemType

proc streamErrType*(v: Value): Value =
  streamData(v).errType

proc streamItemScope*(v: Value): Scope =
  streamData(v).itemScope

proc streamGeneratorCode*(v: Value): FunctionCode =
  streamData(v).generatorCode

proc streamGeneratorScope*(v: Value): Scope =
  streamData(v).generatorScope

proc streamGeneratorStack*(v: Value): var seq[Value] =
  streamData(v).generatorStack

proc streamGeneratorIp*(v: Value): int =
  streamData(v).generatorIp

proc setStreamGeneratorIp*(v: Value, ip: int) =
  streamData(v).generatorIp = ip

proc taskData(v: Value): TaskData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okTask:
    raise newException(FieldDefect, "value is not a Task")
  TaskData(objData(v))

proc taskDone*(v: Value): bool =
  taskData(v).done

proc taskCancelled*(v: Value): bool =
  taskData(v).cancelled

proc taskAwaited*(v: Value): bool =
  taskData(v).awaited

proc cancelTask*(v: Value) =
  let data = taskData(v)
  if not data.done:
    data.done = true
    data.cancelled = true

proc taskResult*(v: Value): Value =
  taskData(v).result

proc taskHasError*(v: Value): bool =
  taskData(v).errorMsg.len > 0 or taskData(v).hasErrorValue

proc taskErrorMsg*(v: Value): lent string =
  taskData(v).errorMsg

proc taskErrorValue*(v: Value): Value =
  taskData(v).errorValue

proc taskHasErrorValue*(v: Value): bool =
  taskData(v).hasErrorValue

proc taskHasPanic*(v: Value): bool =
  taskData(v).panicMsg.len > 0 or taskData(v).hasPanicValue

proc taskPanicMsg*(v: Value): lent string =
  taskData(v).panicMsg

proc taskPanicValue*(v: Value): Value =
  taskData(v).panicValue

proc taskHasPanicValue*(v: Value): bool =
  taskData(v).hasPanicValue

proc clearTaskPayload*(v: Value) =
  let data = taskData(v)
  data.awaited = true
  data.result = NIL
  data.errorMsg = ""
  data.errorValue = NIL
  data.hasErrorValue = false
  data.panicMsg = ""
  data.panicValue = NIL
  data.hasPanicValue = false

proc channelData(v: Value): ChannelData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okChannel:
    raise newException(FieldDefect, "value is not a Channel")
  ChannelData(objData(v))

proc channelCapacity*(v: Value): int =
  channelData(v).state.capacity

proc channelLen*(v: Value): int =
  channelData(v).state.items.len

proc channelClosed*(v: Value): bool =
  channelData(v).state.closed

proc channelFull*(v: Value): bool =
  let data = channelData(v)
  data.state.items.len >= data.state.capacity

proc channelItemType*(v: Value): Value =
  channelData(v).itemType

proc channelItemScope*(v: Value): Scope =
  channelData(v).itemScope

proc closeChannel*(v: Value) =
  channelData(v).state.closed = true

proc pushChannel*(v, item: Value) =
  let data = channelData(v)
  data.state.items.add escapeWeakFunctions(item)

proc popChannel*(v: Value): Value =
  let data = channelData(v)
  if data.state.items.len == 0:
    raise newException(FieldDefect, "channel is empty")
  result = data.state.items[0]
  data.state.items.delete(0)

proc actorData(v: Value): ActorData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okActorRef:
    raise newException(FieldDefect, "value is not an ActorRef")
  ActorData(objData(v))

proc actorState*(v: Value): Value =
  actorData(v).state

proc setActorState*(v, state: Value) =
  actorData(v).state = escapeWeakFunctions(state)

proc actorHandler*(v: Value): Value =
  actorData(v).handler

proc actorRestartInit*(v: Value): Value =
  actorData(v).restartInit

proc actorMessageType*(v: Value): Value =
  actorData(v).messageType

proc actorFailureStrategy*(v: Value): ActorFailureStrategy =
  actorData(v).failureStrategy

proc setActorMessageType*(v, messageType: Value) =
  actorData(v).messageType = messageType

proc actorClosed*(v: Value): bool =
  actorData(v).lifecycle.closed

proc actorProcessing*(v: Value): bool =
  actorData(v).processing

proc setActorProcessing*(v: Value, processing: bool) =
  actorData(v).processing = processing

proc actorQueueLen*(v: Value): int =
  actorData(v).queue.len

proc actorFull*(v: Value): bool =
  let data = actorData(v)
  data.queue.len >= data.capacity

proc closeActor*(v: Value) =
  actorData(v).lifecycle.closed = true

proc pushActorMessage*(v, message: Value) =
  actorData(v).queue.add ActorMessage(message: escapeWeakFunctions(message),
                                      reply: NIL)

proc pushActorMessage*(v, message, reply: Value) =
  actorData(v).queue.add ActorMessage(message: escapeWeakFunctions(message),
                                      reply: reply)

proc popActorMessage*(v: Value): ActorMessage =
  let data = actorData(v)
  if data.queue.len == 0:
    raise newException(FieldDefect, "actor mailbox is empty")
  result = data.queue[0]
  data.queue.delete(0)

proc actorContextActor*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okActorContext:
    raise newException(FieldDefect, "value is not an ActorContext")
  ActorContextData(objData(v)).actor

proc actorStepContinue*(v: Value): bool =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okActorStep:
    raise newException(FieldDefect, "value is not an ActorStep")
  ActorStepData(objData(v)).continueActor

proc actorStepState*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okActorStep:
    raise newException(FieldDefect, "value is not an ActorStep")
  ActorStepData(objData(v)).state

proc replyToData(v: Value): ReplyToData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okReplyTo:
    raise newException(FieldDefect, "value is not a ReplyTo")
  ReplyToData(objData(v))

proc replyToSent*(v: Value): bool =
  replyToData(v).sent

proc replyToResult*(v: Value): Value =
  replyToData(v).result

proc replyToResultType*(v: Value): Value =
  replyToData(v).resultType

proc replyToResultScope*(v: Value): Scope =
  replyToData(v).resultScope

proc replyToTask*(v: Value): Value =
  replyToData(v).task

proc setReplyToResultType*(v, resultType: Value, scope: Scope) =
  let data = replyToData(v)
  data.resultType = resultType
  data.resultScope = scope

proc completeTask*(v, value: Value)

proc sendReplyTo*(v, result: Value) =
  let data = replyToData(v)
  if data.sent:
    raise newException(FieldDefect, "reply has already been sent")
  data.result = escapeWeakFunctions(result)
  data.sent = true
  if data.task.kind == vkTask:
    completeTask(data.task, data.result)

proc typeName*(v: Value): lent string =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  TypeData(objData(v)).name

proc typeParent*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  TypeData(objData(v)).parent

proc typeFields*(v: Value): seq[TypeField] =
  ## Full field schema, parent fields first (inheritance is merged at newType).
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  TypeData(objData(v)).fields

proc typeBodyFields*(v: Value): seq[TypeBodyField] =
  ## Full body schema, parent fields first (inheritance is merged at newType).
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  TypeData(objData(v)).bodyFields

proc typeScope*(v: Value): Scope =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  let data = TypeData(objData(v))
  if data.scope != nil:
    data.scope
  else:
    cast[Scope](data.weakScope)

proc typeFieldScope*(field: TypeField, fallback: Scope): Scope =
  if field.scope != nil:
    field.scope
  elif field.weakScope != nil:
    cast[Scope](field.weakScope)
  else:
    fallback

proc typeBodyFieldScope*(field: TypeBodyField, fallback: Scope): Scope =
  if field.scope != nil:
    field.scope
  elif field.weakScope != nil:
    cast[Scope](field.weakScope)
  else:
    fallback

proc typeRequiredProtocols*(v: Value): lent seq[Value] =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  TypeData(objData(v)).requiredProtocols

proc typeDerivedProtocols*(v: Value): lent seq[Value] =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  TypeData(objData(v)).derivedProtocols

proc typeDeriveRequests*(v: Value): lent seq[Value] =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okType:
    raise newException(FieldDefect, "value is not a Type")
  TypeData(objData(v)).deriveRequests

proc protocolName*(v: Value): lent string =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okProtocol:
    raise newException(FieldDefect, "value is not a Protocol")
  ProtocolData(objData(v)).name

proc protocolMessages*(v: Value): lent OrderedTable[string, Value] =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okProtocol:
    raise newException(FieldDefect, "value is not a Protocol")
  ProtocolData(objData(v)).messages

proc protocolDeriveFn*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okProtocol:
    raise newException(FieldDefect, "value is not a Protocol")
  ProtocolData(objData(v)).deriveFn

proc protocolMessageName*(v: Value): lent string =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okProtocolMessage:
    raise newException(FieldDefect, "value is not a ProtocolMessage")
  ProtocolMessageData(objData(v)).name

proc protocolMessageProtocol*(v: Value): Value =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okProtocolMessage:
    raise newException(FieldDefect, "value is not a ProtocolMessage")
  let bits = ProtocolMessageData(objData(v)).protocolBits
  if (bits shr TAG_SHIFT) >= MANAGED_MIN:
    rcRetain(bits)
  Value(bits: bits)

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

proc intBigValue(v: Value): BigIntValue =
  case v.bits shr TAG_SHIFT
  of INT_TAG:
    bigFromInt64(decodeSmallInt(v.bits))
  of INT64_TAG:
    bigFromInt64(cast[ptr GeneInt64](v.bits and PAYLOAD_MASK).i)
  of OBJECT_TAG:
    if objData(v).objKind == okBigInt:
      BigIntData(objData(v)).value
    else:
      raise newException(FieldDefect, "value is not an Int")
  else:
    raise newException(FieldDefect, "value is not an Int")

proc bigToValue(x: BigIntValue): Value =
  let converted = bigToInt64(x)
  if converted.ok:
    return newInt(converted.value)
  boxObject(BigIntData(objKind: okBigInt, value: x))

proc newIntFromDecimal*(s: string): Value =
  bigToValue(parseBigDecimal(s))

proc intToString*(v: Value): string =
  case v.bits shr TAG_SHIFT
  of INT_TAG, INT64_TAG:
    $v.intVal
  of OBJECT_TAG:
    if objData(v).objKind == okBigInt:
      bigToString(BigIntData(objData(v)).value)
    else:
      raise newException(FieldDefect, "value is not an Int")
  else:
    raise newException(FieldDefect, "value is not an Int")

proc intToFloat*(v: Value): float64 =
  parseFloat(v.intToString)

proc intIsZero*(v: Value): bool {.inline.} =
  case v.bits shr TAG_SHIFT
  of INT_TAG, INT64_TAG:
    v.intVal == 0
  of OBJECT_TAG:
    if objData(v).objKind == okBigInt:
      BigIntData(objData(v)).value.sign == 0
    else:
      raise newException(FieldDefect, "value is not an Int")
  else:
    raise newException(FieldDefect, "value is not an Int")

proc isInt64Backed(v: Value): bool {.inline.} =
  let tag = v.bits shr TAG_SHIFT
  tag == INT_TAG or tag == INT64_TAG

proc intCompare*(a, b: Value): int {.inline.} =
  if a.kind != vkInt or b.kind != vkInt:
    raise newException(FieldDefect, "value is not an Int")
  if a.isInt64Backed and b.isInt64Backed:
    let av = a.intVal
    let bv = b.intVal
    if av < bv: -1 elif av > bv: 1 else: 0
  else:
    cmpBig(a.intBigValue, b.intBigValue)

proc intCompareToInt64*(a: Value, b: int64): int {.inline.} =
  intCompare(a, newInt(b))

proc checkedAdd64(a, b: int64, outValue: var int64): bool {.inline.} =
  if (b > 0 and a > high(int64) - b) or
     (b < 0 and a < low(int64) - b):
    return false
  outValue = a + b
  true

proc checkedSub64(a, b: int64, outValue: var int64): bool {.inline.} =
  if (b > 0 and a < low(int64) + b) or
     (b < 0 and a > high(int64) + b):
    return false
  outValue = a - b
  true

proc absMagnitude(v: int64): uint64 {.inline.} =
  if v < 0: uint64(-(v + 1)) + 1'u64 else: uint64(v)

proc checkedMul64(a, b: int64, outValue: var int64): bool {.inline.} =
  if a == 0 or b == 0:
    outValue = 0
    return true
  if a == low(int64) and b == -1: return false
  if b == low(int64) and a == -1: return false
  let aa = absMagnitude(a)
  let bb = absMagnitude(b)
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

proc intAdd*(a, b: Value): Value {.inline.} =
  if a.isInt64Backed and b.isInt64Backed:
    var s: int64
    if checkedAdd64(a.intVal, b.intVal, s):
      return newInt(s)
  bigToValue(addBig(a.intBigValue, b.intBigValue))

proc intNeg*(a: Value): Value {.inline.} =
  if a.isInt64Backed:
    let av = a.intVal
    if av != low(int64):
      return newInt(-av)
  bigToValue(negBig(a.intBigValue))

proc intSub*(a, b: Value): Value {.inline.} =
  if a.isInt64Backed and b.isInt64Backed:
    var s: int64
    if checkedSub64(a.intVal, b.intVal, s):
      return newInt(s)
  bigToValue(subBig(a.intBigValue, b.intBigValue))

proc intMul*(a, b: Value): Value {.inline.} =
  if a.isInt64Backed and b.isInt64Backed:
    var p: int64
    if checkedMul64(a.intVal, b.intVal, p):
      return newInt(p)
  bigToValue(mulBig(a.intBigValue, b.intBigValue))

proc intDiv*(a, b: Value): Value {.inline.} =
  if b.intIsZero:
    raise newException(FieldDefect, "division by zero")
  if a.isInt64Backed and b.isInt64Backed:
    let av = a.intVal
    let bv = b.intVal
    if not (av == low(int64) and bv == -1):
      return newInt(av div bv)
  bigToValue(divBig(a.intBigValue, b.intBigValue))

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

proc withoutVoidEntries(entries: sink PropTable): PropTable =
  var hasVoid = false
  for _, val in entries:
    if val.kind == vkVoid:
      hasVoid = true
      break
  if not hasVoid:
    return entries
  result = initOrderedTable[string, Value]()
  for key, val in entries:
    if val.kind != vkVoid:
      result[key] = val

proc newMap*(entries: sink PropTable = initOrderedTable[string, Value](),
             immutable = false): Value =
  let p = createObj(GeneMap)
  p.refCount = 1
  p.immutable = immutable
  p.entries = withoutVoidEntries(entries)
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
  p.props = withoutVoidEntries(props)
  p.body = body
  p.meta = withoutVoidEntries(meta)
  boxPtr(NODE_TAG, p)

proc newFunction*(name: string, params: sink seq[string],
                  code: FunctionCode, scope: Scope,
                  checksErrors = false,
                  errorTypes: sink seq[Value] = @[]): Value =
  let p = createObj(GeneFunction)
  p.refCount = 1
  p.name = name
  p.params = params
  p.code = code
  p.scope = scope
  p.checksErrors = checksErrors
  p.errorTypes = errorTypes
  boxPtr(FUNCTION_TAG, p)

proc cloneFunctionCapture(v: Value, scope: Scope, weak: bool): Value =
  let src = cast[ptr GeneFunction](v.bits and PAYLOAD_MASK)
  let p = createObj(GeneFunction)
  p.refCount = 1
  p.name = src.name
  p.params = src.params
  p.code = src.code
  if weak:
    p.weakScope = cast[pointer](scope)
  else:
    p.scope = scope
  p.checksErrors = src.checksErrors
  p.errorTypes = src.errorTypes
  boxPtr(FUNCTION_TAG, p)

proc functionForScopeStorage*(v: Value, owner: Scope): Value =
  ## Store scope-owned functions with a weak back-edge so the owner can be
  ## reclaimed after its ordinary references are dropped.
  if v.kind == vkFunction and not v.fnHasWeakScope and v.fnScope == owner:
    return cloneFunctionCapture(v, owner, weak = true)
  v

proc escapeWeakFunctions*(v: Value): Value =
  ## Values that leave their defining run/eval boundary must keep weakly-stored
  ## lexical scopes alive. Rebuild only the containers that actually contain a
  ## weak function.
  if not v.isManaged:
    return v
  case v.kind
  of vkFunction:
    if v.fnHasWeakScope:
      return cloneFunctionCapture(v, v.fnScope, weak = false)
    v
  of vkList:
    for i, item in v.listItems:
      let escaped = escapeWeakFunctions(item)
      if escaped.bits != item.bits:
        var items = newSeq[Value](v.listItems.len)
        for j in 0 ..< i:
          items[j] = v.listItems[j]
        items[i] = escaped
        for j in i + 1 ..< v.listItems.len:
          items[j] = escapeWeakFunctions(v.listItems[j])
        return newList(items, v.listImmutable)
    v
  of vkMap:
    var changed = false
    for key, val in v.mapEntries:
      let escaped = escapeWeakFunctions(val)
      if escaped.bits != val.bits:
        changed = true
        break
    if not changed:
      return v
    var entries = initOrderedTable[string, Value]()
    for key, val in v.mapEntries:
      entries[key] = escapeWeakFunctions(val)
    newMap(entries, v.mapImmutable)
  of vkNode:
    let escapedHead = escapeWeakFunctions(v.head)
    var changed = escapedHead.bits != v.head.bits
    if not changed:
      for _, val in v.props:
        let escaped = escapeWeakFunctions(val)
        if escaped.bits != val.bits:
          changed = true
          break
    if not changed:
      for item in v.body:
        let escaped = escapeWeakFunctions(item)
        if escaped.bits != item.bits:
          changed = true
          break
    if not changed:
      for _, val in v.meta:
        let escaped = escapeWeakFunctions(val)
        if escaped.bits != val.bits:
          changed = true
          break
    if not changed:
      return v
    var props = initOrderedTable[string, Value]()
    for key, val in v.props:
      props[key] = escapeWeakFunctions(val)
    var body: seq[Value]
    for item in v.body:
      body.add escapeWeakFunctions(item)
    var meta = initOrderedTable[string, Value]()
    for key, val in v.meta:
      meta[key] = escapeWeakFunctions(val)
    newNode(escapedHead, props = props, body = body, meta = meta,
            immutable = v.nodeImmutable)
  of vkStream:
    let data = streamData(v)
    let escapedSource = escapeWeakFunctions(data.source)
    let escapedCallable = escapeWeakFunctions(data.callable)
    let escapedBuffer = escapeWeakFunctions(data.buffer)
    if escapedSource.bits == data.source.bits and
        escapedCallable.bits == data.callable.bits and
        escapedBuffer.bits == data.buffer.bits:
      return v
    boxObject(StreamData(objKind: okStream, source: escapedSource,
                         items: data.items, index: data.index,
                         callable: escapedCallable, remaining: data.remaining,
                         pull: data.pull, closed: data.closed,
                         buffered: data.buffered, buffer: escapedBuffer,
                         itemType: data.itemType, itemScope: data.itemScope,
                         generatorCode: data.generatorCode,
                         generatorScope: data.generatorScope,
                         generatorStack: data.generatorStack,
                         generatorIp: data.generatorIp))
  of vkTask:
    let data = taskData(v)
    let escapedResult = escapeWeakFunctions(data.result)
    let escapedError = escapeWeakFunctions(data.errorValue)
    let escapedPanic = escapeWeakFunctions(data.panicValue)
    if escapedResult.bits == data.result.bits and
        escapedError.bits == data.errorValue.bits and
        escapedPanic.bits == data.panicValue.bits:
      return v
    boxObject(TaskData(objKind: okTask, done: data.done,
                       cancelled: data.cancelled,
                       awaited: data.awaited,
                       result: escapedResult,
                       errorMsg: data.errorMsg,
                       errorValue: escapedError,
                       hasErrorValue: data.hasErrorValue,
                       panicMsg: data.panicMsg,
                       panicValue: escapedPanic,
                       hasPanicValue: data.hasPanicValue))
  of vkChannel:
    let data = channelData(v)
    var changed = false
    var escapedItems = newSeq[Value](data.state.items.len)
    for i, item in data.state.items:
      escapedItems[i] = escapeWeakFunctions(item)
      if escapedItems[i].bits != item.bits:
        changed = true
    if not changed:
      return v
    let escapedState = ChannelState(items: escapedItems,
                                    capacity: data.state.capacity,
                                    closed: data.state.closed)
    boxObject(ChannelData(objKind: okChannel, state: escapedState,
                          itemType: data.itemType,
                          itemScope: data.itemScope))
  of vkActorRef:
    let data = actorData(v)
    let escapedState = escapeWeakFunctions(data.state)
    let escapedRestartInit = escapeWeakFunctions(data.restartInit)
    let escapedHandler = escapeWeakFunctions(data.handler)
    var escapedQueue = newSeq[ActorMessage](data.queue.len)
    var changed = escapedState.bits != data.state.bits or
      escapedRestartInit.bits != data.restartInit.bits or
      escapedHandler.bits != data.handler.bits
    for i, item in data.queue:
      let escapedMessage = escapeWeakFunctions(item.message)
      let escapedReply = escapeWeakFunctions(item.reply)
      escapedQueue[i] = ActorMessage(message: escapedMessage,
                                     reply: escapedReply)
      if escapedMessage.bits != item.message.bits or
          escapedReply.bits != item.reply.bits:
        changed = true
    if not changed:
      return v
    boxObject(ActorData(objKind: okActorRef,
                        lifecycle: data.lifecycle,
                        capacity: data.capacity,
                        queue: escapedQueue,
                        processing: data.processing,
                        state: escapedState,
                        restartInit: escapedRestartInit,
                        handler: escapedHandler,
                        messageType: data.messageType,
                        failureStrategy: data.failureStrategy))
  of vkActorContext:
    let actor = v.actorContextActor
    let escapedActor = escapeWeakFunctions(actor)
    if escapedActor.bits == actor.bits:
      return v
    boxObject(ActorContextData(objKind: okActorContext, actor: escapedActor))
  of vkActorStep:
    let state = v.actorStepState
    let escapedState = escapeWeakFunctions(state)
    if escapedState.bits == state.bits:
      return v
    boxObject(ActorStepData(objKind: okActorStep,
                            continueActor: v.actorStepContinue,
                            state: escapedState))
  of vkReplyTo:
    let data = replyToData(v)
    let escapedResult = escapeWeakFunctions(data.result)
    let escapedTask = escapeWeakFunctions(data.task)
    if escapedResult.bits != data.result.bits or
        escapedTask.bits != data.task.bits:
      data.result = escapedResult
      data.task = escapedTask
    v
  else:
    v

proc newCompletedTask*(value: Value): Value =
  boxObject(TaskData(objKind: okTask, done: true,
                     result: escapeWeakFunctions(value)))

proc newPendingTask*(): Value =
  ## A task whose computation has not finished yet. The scheduler fills in the
  ## outcome with completeTask/failTask/panicTask once its fiber settles.
  boxObject(TaskData(objKind: okTask, done: false))

proc completeTask*(v, value: Value) =
  let data = taskData(v)
  if data.done:
    return
  data.done = true
  data.result = escapeWeakFunctions(value)

proc failTask*(v: Value, message: string, value: Value = NIL, hasValue = false) =
  let data = taskData(v)
  if data.done:
    return
  data.done = true
  data.errorMsg = message
  data.errorValue = escapeWeakFunctions(value)
  data.hasErrorValue = hasValue

proc panicTask*(v: Value, message: string, value: Value = NIL, hasValue = false) =
  let data = taskData(v)
  if data.done:
    return
  data.done = true
  data.panicMsg = message
  data.panicValue = escapeWeakFunctions(value)
  data.hasPanicValue = hasValue

proc newFailedTask*(message: string, value: Value = NIL,
                    hasValue = false): Value =
  boxObject(TaskData(objKind: okTask, done: true,
                     errorMsg: message,
                     errorValue: escapeWeakFunctions(value),
                     hasErrorValue: hasValue))

proc newPanickedTask*(message: string, value: Value = NIL,
                      hasValue = false): Value =
  boxObject(TaskData(objKind: okTask, done: true,
                     panicMsg: message,
                     panicValue: escapeWeakFunctions(value),
                     hasPanicValue: hasValue))

proc newChannel*(capacity = 16): Value =
  boxObject(ChannelData(objKind: okChannel,
                        state: ChannelState(capacity: capacity)))

proc newCheckedChannel*(source, itemType: Value, itemScope: Scope): Value =
  let data = channelData(source)
  boxObject(ChannelData(objKind: okChannel, state: data.state,
                        itemType: itemType, itemScope: itemScope))

proc newActorRef*(capacity: int, state, handler, messageType: Value,
                  restartInit: Value = NIL,
                  failureStrategy: ActorFailureStrategy = afsStop): Value =
  let storedRestartInit =
    if restartInit.kind == vkFunction:
      functionForScopeStorage(restartInit, restartInit.fnScope)
    else:
      restartInit
  let storedHandler =
    if handler.kind == vkFunction:
      functionForScopeStorage(handler, handler.fnScope)
    else:
      handler
  boxObject(ActorData(objKind: okActorRef,
                      lifecycle: ActorLifecycle(),
                      capacity: capacity,
                      state: escapeWeakFunctions(state),
                      restartInit: storedRestartInit,
                      handler: storedHandler,
                      messageType: messageType,
                      failureStrategy: failureStrategy))

proc newActorContext*(actor: Value): Value =
  boxObject(ActorContextData(objKind: okActorContext, actor: actor))

proc newActorContinue*(state: Value): Value =
  boxObject(ActorStepData(objKind: okActorStep,
                          continueActor: true,
                          state: escapeWeakFunctions(state)))

proc newActorStop*(): Value =
  boxObject(ActorStepData(objKind: okActorStep,
                          continueActor: false))

proc newReplyTo*(resultType = NIL, resultScope: Scope = nil,
                 task = NIL): Value =
  boxObject(ReplyToData(objKind: okReplyTo,
                        result: NIL,
                        resultType: resultType,
                        resultScope: resultScope,
                        task: task))

proc newNativeFn*(name: string, impl: NativeProc,
                  acceptsNamed = false): Value =
  let p = createObj(GeneNativeFn)
  p.refCount = 1
  p.name = name
  p.impl = impl
  p.acceptsNamed = acceptsNamed
  boxPtr(NATIVE_FN_TAG, p)

proc newNativeCallFn*(name: string, impl: NativeCallProc,
                      acceptsNamed = true): Value =
  let p = createObj(GeneNativeFn)
  p.refCount = 1
  p.name = name
  p.callImpl = impl
  p.acceptsNamed = acceptsNamed
  boxPtr(NATIVE_FN_TAG, p)

proc newNamespace*(name: string, scope: Scope, modulePath = "",
                   moduleRoot = false): Value =
  boxObject(NamespaceData(objKind: okNamespace, name: name, scope: scope,
                          moduleRoot: moduleRoot, modulePath: modulePath))

proc newModule*(name: string, root: Value, path = "",
                meta: sink PropTable = initOrderedTable[string, Value]()): Value =
  if root.kind != vkNamespace:
    raise newException(FieldDefect, "module root is not a Namespace")
  boxObject(ModuleData(objKind: okModule, name: name, path: path, root: root,
                       meta: meta))

proc newEnv*(bindings: sink Table[string, Value],
             parent: Value = NIL,
             imports: sink seq[Value] = @[],
             module: Value = NIL,
             capabilities: Value = NIL,
             policy: Value = NIL): Value =
  boxObject(EnvData(objKind: okEnv, parent: parent, bindings: bindings,
                    imports: imports, module: module,
                    capabilities: capabilities, policy: policy))

proc newCell*(value: Value): Value =
  boxObject(CellData(objKind: okCell, value: value))

proc newAtomicCell*(value: Value): Value =
  boxObject(CellData(objKind: okAtomicCell, value: value))

proc newStream*(items: sink seq[Value]): Value =
  boxObject(StreamData(objKind: okStream, items: items, index: 0, closed: false))

proc newTypedStream*(items: sink seq[Value], itemType, errType: Value,
                     itemScope: Scope): Value =
  boxObject(StreamData(objKind: okStream, items: items, index: 0,
                       itemType: itemType, errType: errType,
                       itemScope: itemScope, closed: false))

proc newCheckedStream*(source, itemType, errType: Value, itemScope: Scope): Value =
  boxObject(StreamData(objKind: okStream, source: source, itemType: itemType,
                       errType: errType, itemScope: itemScope, closed: false))

proc newLazyStream*(source: Value, pull: StreamPullProc,
                    callable: Value = NIL, remaining: int64 = -1): Value =
  let storedCallable =
    if callable.kind == vkFunction:
      functionForScopeStorage(callable, callable.fnScope)
    else:
      callable
  boxObject(StreamData(objKind: okStream, source: source, callable: storedCallable,
                       remaining: remaining, pull: pull, closed: false))

proc newGeneratorStream*(code: FunctionCode, scope: Scope,
                         pull: StreamPullProc): Value =
  boxObject(StreamData(objKind: okStream, pull: pull, closed: false,
                       generatorCode: code, generatorScope: scope,
                       generatorStack: @[], generatorIp: 0))

proc newType*(name: string, parent: Value, ownFields: seq[TypeField],
              requiredProtocols: sink seq[Value], scope: Scope,
              derivedProtocols: sink seq[Value] = @[],
              deriveRequests: sink seq[Value] = @[],
              ownBodyFields: seq[TypeBodyField] = @[]): Value =
  ## A nominal type. Single inheritance is merged eagerly: the parent's fields
  ## come first, then this type's own fields (design Section 7.3).
  var fields: seq[TypeField]
  var bodyFields: seq[TypeBodyField]
  if parent.kind == vkType:
    fields = typeFields(parent)
    bodyFields = typeBodyFields(parent)
  for f in ownFields:
    for inherited in fields:
      if inherited.name == f.name:
        raise newException(GeneError,
          "type " & name & " redeclares inherited field: " & f.name)
    var owned = f
    if owned.scope == nil and owned.weakScope == nil:
      owned.weakScope = cast[pointer](scope)
    fields.add owned
  if ownBodyFields.len > 0 and bodyFields.len > 0 and bodyFields[^1].rest:
    raise newException(GeneError,
      "type " & name & " cannot add body fields after inherited rest body field")
  for f in ownBodyFields:
    var owned = f
    if owned.scope == nil and owned.weakScope == nil:
      owned.weakScope = cast[pointer](scope)
    bodyFields.add owned
  boxObject(TypeData(objKind: okType, name: name, parent: parent, fields: fields,
                     bodyFields: bodyFields,
                     weakScope: cast[pointer](scope),
                     requiredProtocols: requiredProtocols,
                     derivedProtocols: derivedProtocols,
                     deriveRequests: deriveRequests))

proc newProtocolMessage*(protocol: Value, name: string): Value =
  boxObject(ProtocolMessageData(objKind: okProtocolMessage,
                                name: name,
                                protocolBits: protocol.bits))

proc newProtocol*(name: string, messageNames: openArray[string],
                  deriveFn: Value = NIL): Value =
  var messages = initOrderedTable[string, Value]()
  let data = ProtocolData(objKind: okProtocol, name: name, messages: messages,
                          deriveFn: deriveFn)
  let protocol = boxObject(data)
  for messageName in messageNames:
    data.messages[messageName] = newProtocolMessage(protocol, messageName)
  protocol

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
