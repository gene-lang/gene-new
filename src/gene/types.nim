## Canonical value / node model for Gene (design Section 1).
##
## Values are represented as a 64-bit NaN-box (`Value.bits`):
##
##   * `bits == 0`                      -> `nil` (so a zero-initialized Value is nil)
##   * top 16 bits < 0xFFF1             -> an IEEE float64 stored directly
##   * top 16 bits in 0xFFF1..0xFFF6    -> a void/bool/small-int/char/+0.0/symbol
##                                         immediate (no allocation)
##   * top 16 bits >= 0xFFF7            -> a *managed* heap pointer (cycle-tracked
##                                         object, string, list, map, node,
##                                         function, native function, large int,
##                                         or opaque object) carried in
##                                         the low 48 bits
##
## Managed objects are manually heap-allocated and reference counted. Each starts
## with a `refCount` header; `Value`'s `=copy`/`=sink`/`=dup`/`=destroy` hooks
## drive retain/release automatically, so acyclic values free at count 0 — no
## global table, no per-read lock. (Adopted from the older Gene runtime.)
##
## Cycles: the `scope -> closure -> scope` case is broken with weak captured-scope
## edges (see `Scope`/`GeneFunction`). Direct mutable Cell/Env object cycles
## reached through a `Value` (e.g. a self-referential `cell`) are reclaimed by a
## conservative trial-deletion pass, because ORC cannot directly trace through
## NaN-boxed payload bits. Env-bound functions created in the Env's owner scope
## use the same weak-scope storage and are strengthened when the Env escapes.
## See `tests/test_rc.nim`.
##
## Values crossing a `Send` boundary, plus captured values published to spawned
## fibers, are marked shared; in threaded builds manual RC objects then use atomic
## inc/dec while thread-local objects stay on the cheap non-atomic path. Generic
## ORC objects also carry the marker, but a full M:N worker pool still needs
## atomicArc (or equivalent) for those OBJECT_TAG refs and isolated spawn scopes.

import std/[locks, sets, strutils, sysatomics, tables, unicode]

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
    vkCPtr      ## opaque C pointer / owned foreign handle
    vkCSlice    ## opaque non-owning C pointer + element count
    vkBuffer    ## Gene-owned typed contiguous storage
    vkDeviceBuffer ## opaque accelerator/device buffer handle
    vkCapability ## explicit named runtime authority value
    vkFfiLoad   ## explicit authority to load native libraries at runtime
    vkFfiLibrary ## loaded native library handle
    vkFfiCallable ## dynamically bound foreign callable
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
  MANAGED_MIN   = 0xFFF7'u64
  CYCLE_OBJECT_TAG = 0xFFF7'u64
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
    shared: int
    s: string

  GeneInt64 = object
    refCount: int
    shared: int
    i: int64

  GeneList = object
    refCount: int
    shared: int
    immutable: bool
    items: seq[Value]

  GeneMap = object
    refCount: int
    shared: int
    immutable: bool
    entries: PropTable

  GeneNode = object
    refCount: int
    shared: int
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
    scope*: Scope           # strong only for future escaped bindings
    weakScope*: pointer     # ordinary scope-owned binding back-reference

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
    simpleCallScope*: bool
    varTypes*: Table[string, TypeBinding]
    impls*: seq[ProtocolImpl]
    requiredImplTypes*: seq[Value]
    evalBudget*: EvalBudget
    ownsTasks*: bool
    ownedTasks*: seq[Value]
    ownsActors*: bool
    actorFailureStrategy*: ActorFailureStrategy
    supervisorEvents*: Value
    supervisorDeadLetters*: Value
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
  CPtrReleaseProc* = proc(address: pointer) {.nimcall.}
  FfiLibraryCloseProc* = proc(handle: pointer) {.nimcall.}

  NativeFastKind* = enum
    nfkNone
    nfkAdd
    nfkSub
    nfkMul
    nfkLt
    nfkGt
    nfkLe
    nfkGe

  GeneFunction = object
    refCount: int
    shared: int
    name: string
    params: seq[string]
    code: FunctionCode
    scope: Scope             # strong capture for escaping closures
    weakScope: pointer       # non-owning Scope used for scope-owned bindings
    checksErrors: bool
    errorTypes: seq[Value]

  GeneNativeFn = object
    refCount: int
    shared: int
    name: string
    impl: NativeProc
    callImpl: NativeCallProc
    acceptsNamed: bool
    fastKind: NativeFastKind

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
    okCPtr
    okCSlice
    okBuffer
    okDeviceBuffer
    okCapability
    okFfiLoad
    okFfiLibrary
    okFfiCallable
    okType
    okProtocol
    okProtocolMessage

  GeneObjectData* = ref object of RootObj
    objKind*: ObjKind
    shared*: int

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
    cycleRefs: int            # Value-held refs, for trial-deletion collection
    parent: Value         # parent Env value, or NIL
    bindings: Table[string, Value]
    imports: seq[Value]
    module: Value
    capabilities: Value
    policy: Value

  CellData = ref object of GeneObjectData
    cycleRefs: int            # Value-held refs, for trial-deletion collection
    value: Value

  AtomicCellData = ref object of CellData
    ## Inherits CellData's layout (cycleRefs/value) so the shared cycle-
    ## tracking code below keeps working unchanged; adds the lock that makes
    ## load/store/swap/compare-exchange linearizable (design Section 12.3).
    lock: Lock

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

  TaskState = ref object
    lock: Lock
    when compileOption("threads") and defined(gcAtomicArc):
      cond: Cond
    done: bool
    cancelRequested: bool
    cancelled: bool
    awaited: bool
    external: bool
    result: Value
    errorMsg: string
    errorValue: Value
    hasErrorValue: bool
    panicMsg: string
    panicValue: Value
    hasPanicValue: bool

  TaskData = ref object of GeneObjectData
    state: TaskState
    resultType: Value
    errorType: Value
    boundaryScope: Scope

  ChannelState = ref object
    lock: Lock
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
    workerAllowed*: bool

  ActorLifecycle = ref object
    closed: bool

  ActorData = ref object of GeneObjectData
    lock: Lock
    lifecycle: ActorLifecycle
    capacity: int
    queue: seq[ActorMessage]
    reservedMessages: int
    processing: bool
    state: Value
    restartInit: Value
    handler: Value
    messageType: Value
    failureStrategy: ActorFailureStrategy
    failureEvents: Value
    failureDeadLetters: Value
    parentFailureEvents: Value
    parentFailureDeadLetters: Value

  ActorContextData = ref object of GeneObjectData
    actor: Value

  ActorStepData = ref object of GeneObjectData
    continueActor: bool
    state: Value

  ReplyToData = ref object of GeneObjectData
    lock: Lock
    sent: bool
    result: Value
    resultType: Value
    resultScope: Scope
    task: Value

  CPtrData = ref object of GeneObjectData
    address: pointer
    targetType: Value
    mutable: bool
    owned: bool
    closed: bool
    release: CPtrReleaseProc
    foreignRelease: pointer

  CSliceData = ref object of GeneObjectData
    address: pointer
    length: int
    targetType: Value
    mutable: bool

  BufferData = ref object of GeneObjectData
    elemType: Value
    elemScope: Scope
    items: seq[Value]

  DeviceBufferData = ref object of GeneObjectData
    backend: string
    elemType: Value
    length: int

  CapabilityData = ref object of GeneObjectData
    name: string

  FfiLoadData = ref object of GeneObjectData

  FfiLibraryData = ref object of GeneObjectData
    handle: pointer
    path: string
    closed: bool
    close: FfiLibraryCloseProc

  FfiCallableData = ref object of GeneObjectData
    name: string
    symbol: string
    address: pointer
    library: Value
    paramTypes: seq[Value]
    returnType: Value
    releaseName: string
    releaseAddress: pointer

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

proc isObjectTagged(v: Value): bool {.inline.} =
  let tag = v.bits shr TAG_SHIFT
  tag == OBJECT_TAG or tag == CYCLE_OBJECT_TAG

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
  var tag = OBJECT_TAG
  case data.objKind
  of okEnv:
    EnvData(data).cycleRefs = 1
    tag = CYCLE_OBJECT_TAG
  of okCell, okAtomicCell:
    CellData(data).cycleRefs = 1
    tag = CYCLE_OBJECT_TAG
  else:
    discard
  GC_ref(data)                                   # the box holds one reference
  Value(bits: (tag shl TAG_SHIFT) or
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

proc managedLiveCount*(): int =
  when defined(geneRcStats):
    liveManaged
  else:
    0

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
# Conservative OBJECT_TAG cycle collection
# ---------------------------------------------------------------------------

var objectCycleCollecting = false

proc objectPayload(data: GeneObjectData): uint64 {.inline.} =
  cast[uint64](cast[pointer](data)) and PAYLOAD_MASK

proc tracksObjectCycles(data: GeneObjectData): bool {.inline.} =
  data.objKind in {okCell, okAtomicCell, okEnv}

proc objectCycleRefs(data: GeneObjectData): int {.inline.} =
  case data.objKind
  of okEnv:
    EnvData(data).cycleRefs
  of okCell, okAtomicCell:
    CellData(data).cycleRefs
  else:
    0

template forObjectEdges(data: GeneObjectData, edgeBits: untyped, body: untyped) =
  template emit(valueExpr: Value) =
    block:
      let edgeBits {.inject.} = valueExpr.bits
      body

  case data.objKind
  of okNamespace:
    discard
  of okModule:
    let d = ModuleData(data)
    emit(d.root)
    for _, val in d.meta:
      emit(val)
  of okBigInt:
    discard
  of okEnv:
    let d = EnvData(data)
    emit(d.parent)
    for _, val in d.bindings:
      emit(val)
    for val in d.imports:
      emit(val)
    emit(d.module)
    emit(d.capabilities)
    emit(d.policy)
  of okCell, okAtomicCell:
    emit(CellData(data).value)
  of okStream:
    let d = StreamData(data)
    for val in d.items:
      emit(val)
    emit(d.source)
    emit(d.callable)
    emit(d.buffer)
    emit(d.itemType)
    emit(d.errType)
    for val in d.generatorStack:
      emit(val)
  of okTask:
    let d = TaskData(data)
    emit(d.resultType)
    emit(d.errorType)
  of okChannel:
    emit(ChannelData(data).itemType)
  of okActorRef:
    let d = ActorData(data)
    for item in d.queue:
      emit(item.message)
      emit(item.reply)
    emit(d.state)
    emit(d.restartInit)
    emit(d.handler)
    emit(d.messageType)
    emit(d.failureEvents)
    emit(d.failureDeadLetters)
    emit(d.parentFailureEvents)
    emit(d.parentFailureDeadLetters)
  of okActorContext:
    emit(ActorContextData(data).actor)
  of okActorStep:
    emit(ActorStepData(data).state)
  of okReplyTo:
    let d = ReplyToData(data)
    emit(d.result)
    emit(d.resultType)
    emit(d.task)
  of okCPtr:
    emit(CPtrData(data).targetType)
  of okCSlice:
    emit(CSliceData(data).targetType)
  of okBuffer:
    let d = BufferData(data)
    emit(d.elemType)
    for val in d.items:
      emit(val)
  of okDeviceBuffer:
    emit(DeviceBufferData(data).elemType)
  of okCapability, okFfiLoad, okFfiLibrary:
    discard
  of okFfiCallable:
    let d = FfiCallableData(data)
    emit(d.library)
    for val in d.paramTypes:
      emit(val)
    emit(d.returnType)
  of okType:
    let d = TypeData(data)
    emit(d.parent)
    for field in d.fields:
      emit(field.typeExpr)
    for field in d.bodyFields:
      emit(field.typeExpr)
    for val in d.requiredProtocols:
      emit(val)
    for val in d.derivedProtocols:
      emit(val)
    for val in d.deriveRequests:
      emit(val)
  of okProtocol:
    let d = ProtocolData(data)
    for _, val in d.messages:
      emit(val)
    emit(d.deriveFn)
  of okProtocolMessage:
    discard

proc collectObjectGraph(data: GeneObjectData,
                        counts: var Table[uint64, int],
                        nodes: var seq[GeneObjectData]) =
  if data == nil:
    return
  let payload = objectPayload(data)
  if counts.hasKey(payload):
    return
  if not tracksObjectCycles(data):
    return
  counts[payload] = objectCycleRefs(data)
  nodes.add(data)
  forObjectEdges(data, edgeBits):
    if (edgeBits shr TAG_SHIFT) == CYCLE_OBJECT_TAG:
      let child = cast[GeneObjectData](cast[pointer](edgeBits and PAYLOAD_MASK))
      if tracksObjectCycles(child):
        collectObjectGraph(child, counts, nodes)

proc clearValueSlot(slot: var Value) {.inline.} =
  slot = Value(bits: 0)

proc clearObjectEdges(data: GeneObjectData) =
  case data.objKind
  of okNamespace:
    NamespaceData(data).scope = nil
  of okModule:
    let d = ModuleData(data)
    clearValueSlot(d.root)
    d.meta = initOrderedTable[string, Value]()
  of okBigInt:
    discard
  of okEnv:
    let d = EnvData(data)
    clearValueSlot(d.parent)
    d.bindings = initTable[string, Value]()
    d.imports.setLen(0)
    clearValueSlot(d.module)
    clearValueSlot(d.capabilities)
    clearValueSlot(d.policy)
  of okCell, okAtomicCell:
    clearValueSlot(CellData(data).value)
  of okStream:
    let d = StreamData(data)
    d.items.setLen(0)
    clearValueSlot(d.source)
    clearValueSlot(d.callable)
    clearValueSlot(d.buffer)
    clearValueSlot(d.itemType)
    clearValueSlot(d.errType)
    d.itemScope = nil
    d.generatorScope = nil
    d.generatorStack.setLen(0)
  of okTask:
    let d = TaskData(data)
    d.state = nil
    clearValueSlot(d.resultType)
    clearValueSlot(d.errorType)
    d.boundaryScope = nil
  of okChannel:
    let d = ChannelData(data)
    d.state = nil
    clearValueSlot(d.itemType)
    d.itemScope = nil
  of okActorRef:
    let d = ActorData(data)
    d.lifecycle = nil
    d.queue.setLen(0)
    clearValueSlot(d.state)
    clearValueSlot(d.restartInit)
    clearValueSlot(d.handler)
    clearValueSlot(d.messageType)
    clearValueSlot(d.failureEvents)
    clearValueSlot(d.failureDeadLetters)
    clearValueSlot(d.parentFailureEvents)
    clearValueSlot(d.parentFailureDeadLetters)
  of okActorContext:
    clearValueSlot(ActorContextData(data).actor)
  of okActorStep:
    clearValueSlot(ActorStepData(data).state)
  of okReplyTo:
    let d = ReplyToData(data)
    clearValueSlot(d.result)
    clearValueSlot(d.resultType)
    d.resultScope = nil
    clearValueSlot(d.task)
  of okCPtr:
    clearValueSlot(CPtrData(data).targetType)
  of okCSlice:
    clearValueSlot(CSliceData(data).targetType)
  of okBuffer:
    let d = BufferData(data)
    clearValueSlot(d.elemType)
    d.elemScope = nil
    d.items.setLen(0)
  of okDeviceBuffer:
    clearValueSlot(DeviceBufferData(data).elemType)
  of okCapability, okFfiLoad, okFfiLibrary:
    discard
  of okFfiCallable:
    let d = FfiCallableData(data)
    clearValueSlot(d.library)
    d.paramTypes.setLen(0)
    clearValueSlot(d.returnType)
  of okType:
    let d = TypeData(data)
    clearValueSlot(d.parent)
    d.fields.setLen(0)
    d.bodyFields.setLen(0)
    d.scope = nil
    d.weakScope = nil
    d.requiredProtocols.setLen(0)
    d.derivedProtocols.setLen(0)
    d.deriveRequests.setLen(0)
  of okProtocol:
    let d = ProtocolData(data)
    d.messages = initOrderedTable[string, Value]()
    clearValueSlot(d.deriveFn)
  of okProtocolMessage:
    ProtocolMessageData(data).protocolBits = 0

proc tryCollectObjectCycle(seed: GeneObjectData) =
  if seed == nil or objectCycleCollecting or not tracksObjectCycles(seed):
    return

  objectCycleCollecting = true
  try:
    var counts = initTable[uint64, int]()
    var nodes: seq[GeneObjectData] = @[]
    collectObjectGraph(seed, counts, nodes)

    for data in nodes:
      forObjectEdges(data, edgeBits):
        if (edgeBits shr TAG_SHIFT) == CYCLE_OBJECT_TAG:
          let payload = edgeBits and PAYLOAD_MASK
          if counts.hasKey(payload):
            counts[payload] = counts.getOrDefault(payload) - 1

    for _, count in counts:
      if count != 0:
        return

    for data in nodes:
      clearObjectEdges(data)
  finally:
    objectCycleCollecting = false

# ---------------------------------------------------------------------------
# Reference counting bodies
# ---------------------------------------------------------------------------

template threadedRc: bool =
  compileOption("threads")

template isSharedFlag(flag: var int): bool =
  when threadedRc:
    atomicLoadN(addr flag, ATOMIC_ACQUIRE) != 0
  else:
    flag != 0

template markSharedFlag(flag: var int) =
  when threadedRc:
    if atomicLoadN(addr flag, ATOMIC_ACQUIRE) == 0:
      atomicStoreN(addr flag, 1, ATOMIC_RELEASE)
  else:
    flag = 1

template retainManual(p: untyped) =
  when threadedRc:
    if isSharedFlag(p.shared):
      discard atomicFetchAdd(addr p.refCount, 1, ATOMIC_RELAXED)
    else:
      inc p.refCount
  else:
    inc p.refCount

template releaseManual(p: untyped, body: untyped) =
  when threadedRc:
    if isSharedFlag(p.shared):
      if atomicFetchSub(addr p.refCount, 1, ATOMIC_ACQ_REL) == 1:
        body
    else:
      dec p.refCount
      if p.refCount == 0:
        body
  else:
    dec p.refCount
    if p.refCount == 0:
      body

template markManualShared(p: untyped) =
  markSharedFlag(p.shared)

proc markObjectShared(data: GeneObjectData) {.inline.} =
  if data != nil:
    markSharedFlag(data.shared)

proc markSharedBits(bits: uint64, seen: var HashSet[uint64])

proc markObjectSharedGraph(data: GeneObjectData, seen: var HashSet[uint64]) =
  if data == nil:
    return
  let key = objectPayload(data)
  if seen.contains(key):
    return
  seen.incl key
  markObjectShared(data)
  case data.objKind
  of okTask:
    let d = TaskData(data)
    markSharedBits(d.resultType.bits, seen)
    markSharedBits(d.errorType.bits, seen)
    var result, errorValue, panicValue: Value
    acquire(d.state.lock)
    try:
      result = d.state.result
      errorValue = d.state.errorValue
      panicValue = d.state.panicValue
    finally:
      release(d.state.lock)
    markSharedBits(result.bits, seen)
    markSharedBits(errorValue.bits, seen)
    markSharedBits(panicValue.bits, seen)
  of okChannel:
    let d = ChannelData(data)
    markSharedBits(d.itemType.bits, seen)
    var items: seq[Value]
    acquire(d.state.lock)
    try:
      items = d.state.items
    finally:
      release(d.state.lock)
    for item in items:
      markSharedBits(item.bits, seen)
  of okActorRef:
    let d = ActorData(data)
    var state, restartInit, handler, messageType, failureEvents,
      failureDeadLetters, parentFailureEvents, parentFailureDeadLetters: Value
    var queue: seq[ActorMessage]
    acquire(d.lock)
    try:
      state = d.state
      restartInit = d.restartInit
      handler = d.handler
      messageType = d.messageType
      failureEvents = d.failureEvents
      failureDeadLetters = d.failureDeadLetters
      parentFailureEvents = d.parentFailureEvents
      parentFailureDeadLetters = d.parentFailureDeadLetters
      queue = d.queue
    finally:
      release(d.lock)
    markSharedBits(state.bits, seen)
    markSharedBits(restartInit.bits, seen)
    markSharedBits(handler.bits, seen)
    markSharedBits(messageType.bits, seen)
    markSharedBits(failureEvents.bits, seen)
    markSharedBits(failureDeadLetters.bits, seen)
    markSharedBits(parentFailureEvents.bits, seen)
    markSharedBits(parentFailureDeadLetters.bits, seen)
    for item in queue:
      markSharedBits(item.message.bits, seen)
      markSharedBits(item.reply.bits, seen)
  else:
    forObjectEdges(data, edgeBits):
      markSharedBits(edgeBits, seen)

proc markSharedBits(bits: uint64, seen: var HashSet[uint64]) =
  let tag = bits shr TAG_SHIFT
  if tag < MANAGED_MIN:
    return
  if seen.contains(bits):
    return
  seen.incl bits
  case tag
  of STRING_TAG:
    markManualShared(cast[ptr GeneString](bits and PAYLOAD_MASK))
  of INT64_TAG:
    markManualShared(cast[ptr GeneInt64](bits and PAYLOAD_MASK))
  of LIST_TAG:
    let p = cast[ptr GeneList](bits and PAYLOAD_MASK)
    markManualShared(p)
    for item in p.items:
      markSharedBits(item.bits, seen)
  of MAP_TAG:
    let p = cast[ptr GeneMap](bits and PAYLOAD_MASK)
    markManualShared(p)
    for _, item in p.entries:
      markSharedBits(item.bits, seen)
  of NODE_TAG:
    let p = cast[ptr GeneNode](bits and PAYLOAD_MASK)
    markManualShared(p)
    markSharedBits(p.head.bits, seen)
    for _, item in p.props:
      markSharedBits(item.bits, seen)
    for item in p.body:
      markSharedBits(item.bits, seen)
    for _, item in p.meta:
      markSharedBits(item.bits, seen)
  of FUNCTION_TAG:
    let p = cast[ptr GeneFunction](bits and PAYLOAD_MASK)
    markManualShared(p)
    for item in p.errorTypes:
      markSharedBits(item.bits, seen)
  of NATIVE_FN_TAG:
    markManualShared(cast[ptr GeneNativeFn](bits and PAYLOAD_MASK))
  of CYCLE_OBJECT_TAG, OBJECT_TAG:
    markObjectSharedGraph(
      cast[GeneObjectData](cast[pointer](bits and PAYLOAD_MASK)), seen)
  else:
    discard

proc markSharedValue*(value: Value) =
  ## Mark a value graph as published across a Send boundary. Manual refcounted
  ## objects switch to atomic RC after this marker in threaded builds; generic
  ## ORC object refs still need the later atomicArc/worker-pool stage before true
  ## M:N execution.
  var seen = initHashSet[uint64]()
  markSharedBits(value.bits, seen)

proc rcRetain(bits: uint64) =
  case bits shr TAG_SHIFT
  of STRING_TAG: retainManual(cast[ptr GeneString](bits and PAYLOAD_MASK))
  of INT64_TAG:  retainManual(cast[ptr GeneInt64](bits and PAYLOAD_MASK))
  of LIST_TAG:   retainManual(cast[ptr GeneList](bits and PAYLOAD_MASK))
  of MAP_TAG:    retainManual(cast[ptr GeneMap](bits and PAYLOAD_MASK))
  of NODE_TAG:   retainManual(cast[ptr GeneNode](bits and PAYLOAD_MASK))
  of FUNCTION_TAG:  retainManual(cast[ptr GeneFunction](bits and PAYLOAD_MASK))
  of NATIVE_FN_TAG: retainManual(cast[ptr GeneNativeFn](bits and PAYLOAD_MASK))
  of CYCLE_OBJECT_TAG:
    let data = cast[GeneObjectData](cast[pointer](bits and PAYLOAD_MASK))
    case data.objKind
    of okEnv:
      let d = EnvData(data)
      when threadedRc:
        if isSharedFlag(data.shared):
          discard atomicFetchAdd(addr d.cycleRefs, 1, ATOMIC_RELAXED)
        else:
          inc d.cycleRefs
      else:
        inc d.cycleRefs
    of okCell, okAtomicCell:
      let d = CellData(data)
      when threadedRc:
        if isSharedFlag(data.shared):
          discard atomicFetchAdd(addr d.cycleRefs, 1, ATOMIC_RELAXED)
        else:
          inc d.cycleRefs
      else:
        inc d.cycleRefs
    else:
      discard
    GC_ref(data)
  of OBJECT_TAG: GC_ref(cast[GeneObjectData](cast[pointer](bits and PAYLOAD_MASK)))
  else: discard

proc rcRelease(bits: uint64) =
  let payload = bits and PAYLOAD_MASK
  if payload == 0: return
  case bits shr TAG_SHIFT
  of STRING_TAG:
    let p = cast[ptr GeneString](payload)
    releaseManual(p):
      reset(p[]); dealloc(p); trackFree()
  of INT64_TAG:
    let p = cast[ptr GeneInt64](payload)
    releaseManual(p):
      reset(p[]); dealloc(p); trackFree()
  of LIST_TAG:
    let p = cast[ptr GeneList](payload)
    releaseManual(p):
      reset(p[]); dealloc(p); trackFree()
  of MAP_TAG:
    let p = cast[ptr GeneMap](payload)
    releaseManual(p):
      reset(p[]); dealloc(p); trackFree()
  of NODE_TAG:
    let p = cast[ptr GeneNode](payload)
    releaseManual(p):
      reset(p[]); dealloc(p); trackFree()
  of FUNCTION_TAG:
    let p = cast[ptr GeneFunction](payload)
    releaseManual(p):
      reset(p[]); dealloc(p); trackFree()
  of NATIVE_FN_TAG:
    let p = cast[ptr GeneNativeFn](payload)
    releaseManual(p):
      reset(p[]); dealloc(p); trackFree()
  of CYCLE_OBJECT_TAG:
    let data = cast[GeneObjectData](cast[pointer](payload))
    var shouldTryCycle = false
    case data.objKind
    of okEnv:
      let d = EnvData(data)
      let newRefs =
        when threadedRc:
          if isSharedFlag(data.shared):
            atomicFetchSub(addr d.cycleRefs, 1, ATOMIC_ACQ_REL) - 1
          else:
            if d.cycleRefs > 0:
              dec d.cycleRefs
            d.cycleRefs
        else:
          if d.cycleRefs > 0:
            dec d.cycleRefs
          d.cycleRefs
      shouldTryCycle = newRefs > 0
    of okCell, okAtomicCell:
      let d = CellData(data)
      let newRefs =
        when threadedRc:
          if isSharedFlag(data.shared):
            atomicFetchSub(addr d.cycleRefs, 1, ATOMIC_ACQ_REL) - 1
          else:
            if d.cycleRefs > 0:
              dec d.cycleRefs
            d.cycleRefs
        else:
          if d.cycleRefs > 0:
            dec d.cycleRefs
          d.cycleRefs
      shouldTryCycle = newRefs > 0
    else:
      discard
    GC_unref(data)
    if shouldTryCycle:
      tryCollectObjectCycle(data)
  of OBJECT_TAG:
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
  of CYCLE_OBJECT_TAG, OBJECT_TAG:
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
    of okCPtr: vkCPtr
    of okCSlice: vkCSlice
    of okBuffer: vkBuffer
    of okDeviceBuffer: vkDeviceBuffer
    of okCapability: vkCapability
    of okFfiLoad: vkFfiLoad
    of okFfiLibrary: vkFfiLibrary
    of okFfiCallable: vkFfiCallable
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

proc nativeFastKind*(v: Value): NativeFastKind {.inline.} =
  if v.tagOf != NATIVE_FN_TAG:
    raise newException(FieldDefect, "value is not a NativeFn")
  cast[ptr GeneNativeFn](v.bits and PAYLOAD_MASK).fastKind

proc ffiCallableData(v: Value): FfiCallableData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okFfiCallable:
    raise newException(FieldDefect, "value is not an FfiCallable")
  FfiCallableData(objData(v))

proc ffiCallableName*(v: Value): lent string =
  ffiCallableData(v).name

proc ffiCallableSymbol*(v: Value): lent string =
  ffiCallableData(v).symbol

proc ffiCallableAddress*(v: Value): pointer =
  ffiCallableData(v).address

proc ffiCallableLibrary*(v: Value): Value =
  ffiCallableData(v).library

proc ffiCallableParamTypes*(v: Value): lent seq[Value] =
  ffiCallableData(v).paramTypes

proc ffiCallableReturnType*(v: Value): Value =
  ffiCallableData(v).returnType

proc ffiCallableReleaseName*(v: Value): lent string =
  ffiCallableData(v).releaseName

proc ffiCallableReleaseAddress*(v: Value): pointer =
  ffiCallableData(v).releaseAddress

proc newEnv*(bindings: sink Table[string, Value],
             parent: Value = NIL,
             imports: sink seq[Value] = @[],
             module: Value = NIL,
             capabilities: Value = NIL,
             policy: Value = NIL,
             bindingScope: Scope = nil): Value

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
  if not v.isObjectTagged or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).parent

proc envBindings*(v: Value): lent Table[string, Value] =
  if not v.isObjectTagged or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).bindings

proc envImports*(v: Value): lent seq[Value] =
  if not v.isObjectTagged or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).imports

proc envModule*(v: Value): Value =
  if not v.isObjectTagged or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).module

proc envCapabilities*(v: Value): Value =
  if not v.isObjectTagged or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).capabilities

proc envPolicy*(v: Value): Value =
  if not v.isObjectTagged or objData(v).objKind != okEnv:
    raise newException(FieldDefect, "value is not an Env")
  EnvData(objData(v)).policy

proc cellValue*(v: Value): Value =
  if not v.isObjectTagged or objData(v).objKind != okCell:
    raise newException(FieldDefect, "value is not a Cell")
  CellData(objData(v)).value

proc setCellValue*(v, newValue: Value) =
  if not v.isObjectTagged or objData(v).objKind != okCell:
    raise newException(FieldDefect, "value is not a Cell")
  CellData(objData(v)).value = newValue

proc asAtomicCellData(v: Value): AtomicCellData =
  if not v.isObjectTagged or objData(v).objKind != okAtomicCell:
    raise newException(FieldDefect, "value is not an AtomicCell")
  AtomicCellData(objData(v))

template withAtomicCellLock(d: AtomicCellData, body: untyped): untyped =
  acquire(d.lock)
  try:
    body
  finally:
    release(d.lock)

proc atomicCellValue*(v: Value): Value =
  let d = v.asAtomicCellData
  withAtomicCellLock(d):
    result = d.value

proc setAtomicCellValue*(v, newValue: Value) =
  let d = v.asAtomicCellData
  withAtomicCellLock(d):
    d.value = newValue

proc atomicCellSwap*(v, newValue: Value): Value =
  ## Reads the current value and replaces it as a single locked critical
  ## section (not a separate load + store), so a concurrent swap/CAS cannot
  ## interleave between the read and the write.
  let d = v.asAtomicCellData
  withAtomicCellLock(d):
    result = d.value
    d.value = newValue

proc atomicCellCompareExchange*(v, expected, newValue: Value,
                                eq: proc (a, b: Value): bool): bool =
  ## Compares the current value against `expected` using the caller-supplied
  ## equality (`same?`, from equality.nim — types.nim can't import it without
  ## a cycle) and swaps in the same locked critical section as the compare,
  ## avoiding the check-then-set race of separate load/compare/store calls.
  let d = v.asAtomicCellData
  withAtomicCellLock(d):
    if eq(d.value, expected):
      d.value = newValue
      result = true
    else:
      result = false

proc streamData(v: Value): StreamData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okStream:
    raise newException(FieldDefect, "value is not a Stream")
  StreamData(objData(v))

template withTaskStateLock(s: TaskState, body: untyped): untyped =
  acquire(s.lock)
  try:
    body
  finally:
    release(s.lock)

template withChannelStateLock(s: ChannelState, body: untyped): untyped =
  acquire(s.lock)
  try:
    body
  finally:
    release(s.lock)

template withActorLock(d: ActorData, body: untyped): untyped =
  acquire(d.lock)
  try:
    body
  finally:
    release(d.lock)

template withReplyToLock(d: ReplyToData, body: untyped): untyped =
  acquire(d.lock)
  try:
    body
  finally:
    release(d.lock)

proc newTaskState(done = false, cancelRequested = false, cancelled = false,
                  awaited = false, external = false, taskResult = NIL, errorMsg = "",
                  errorValue = NIL, hasErrorValue = false,
                  panicMsg = "", panicValue = NIL,
                  hasPanicValue = false): TaskState =
  new(result)
  initLock(result.lock)
  when compileOption("threads") and defined(gcAtomicArc):
    initCond(result.cond)
  result.done = done
  result.cancelRequested = cancelRequested
  result.cancelled = cancelled
  result.awaited = awaited
  result.external = external
  result.result = taskResult
  result.errorMsg = errorMsg
  result.errorValue = errorValue
  result.hasErrorValue = hasErrorValue
  result.panicMsg = panicMsg
  result.panicValue = panicValue
  result.hasPanicValue = hasPanicValue

proc newChannelState(capacity: int, items: seq[Value] = @[],
                     closed = false): ChannelState =
  new(result)
  initLock(result.lock)
  result.items = items
  result.capacity = capacity
  result.closed = closed

proc newActorData(capacity: int, state, restartInit, handler,
                  messageType: Value,
                  failureStrategy: ActorFailureStrategy,
                  failureEvents, failureDeadLetters: Value,
                  parentFailureEvents: Value = NIL,
                  parentFailureDeadLetters: Value = NIL,
                  lifecycle = ActorLifecycle()): ActorData =
  result = ActorData(objKind: okActorRef,
                     lifecycle: lifecycle,
                     capacity: capacity,
                     state: state,
                     restartInit: restartInit,
                     handler: handler,
                     messageType: messageType,
                     failureStrategy: failureStrategy,
                     failureEvents: failureEvents,
                     failureDeadLetters: failureDeadLetters,
                     parentFailureEvents: parentFailureEvents,
                     parentFailureDeadLetters: parentFailureDeadLetters)
  initLock(result.lock)

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

proc taskState(v: Value): TaskState =
  taskData(v).state

proc taskDone*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.done

proc taskCancelled*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.cancelled

proc taskCancelRequested*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.cancelRequested

proc taskAwaited*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.awaited

proc taskExternalPending*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.external and not data.done

proc waitExternalTaskChange*(v: Value): bool =
  ## Wait for a native/external operation to settle this task. Returns true when
  ## the task is now done; false means it was not an external-pending task.
  when compileOption("threads") and defined(gcAtomicArc):
    let data = taskState(v)
    withTaskStateLock(data):
      if not data.external or data.done:
        return data.done
      wait(data.cond, data.lock)
      result = data.done
  else:
    false

proc cancelTask*(v: Value) =
  let data = taskState(v)
  withTaskStateLock(data):
    if not data.done:
      data.cancelRequested = true

proc tryCancelTask*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    if data.done:
      return
    data.done = true
    data.cancelRequested = false
    data.cancelled = true
    data.external = false
    result = true
    when compileOption("threads") and defined(gcAtomicArc):
      broadcast(data.cond)

proc finishTaskCancel*(v: Value) =
  discard tryCancelTask(v)

proc taskResult*(v: Value): Value =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.result

proc taskHasError*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.errorMsg.len > 0 or data.hasErrorValue

proc taskErrorMsg*(v: Value): string =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.errorMsg

proc taskErrorValue*(v: Value): Value =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.errorValue

proc taskHasErrorValue*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.hasErrorValue

proc taskHasPanic*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.panicMsg.len > 0 or data.hasPanicValue

proc taskPanicMsg*(v: Value): string =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.panicMsg

proc taskPanicValue*(v: Value): Value =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.panicValue

proc taskHasPanicValue*(v: Value): bool =
  let data = taskState(v)
  withTaskStateLock(data):
    result = data.hasPanicValue

proc taskResultType*(v: Value): Value =
  taskData(v).resultType

proc taskErrorType*(v: Value): Value =
  taskData(v).errorType

proc taskBoundaryScope*(v: Value): Scope =
  taskData(v).boundaryScope

proc taskSharesState*(a, b: Value): bool =
  a.kind == vkTask and b.kind == vkTask and taskData(a).state == taskData(b).state

proc clearTaskPayload*(v: Value) =
  let data = taskState(v)
  withTaskStateLock(data):
    data.awaited = true
    data.cancelRequested = false
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
  let state = channelData(v).state
  withChannelStateLock(state):
    result = state.capacity

proc channelLen*(v: Value): int =
  let state = channelData(v).state
  withChannelStateLock(state):
    result = state.items.len

proc channelItemsSnapshot*(v: Value): seq[Value] =
  let state = channelData(v).state
  withChannelStateLock(state):
    result = state.items

proc channelClosed*(v: Value): bool =
  let state = channelData(v).state
  withChannelStateLock(state):
    result = state.closed

proc channelFull*(v: Value): bool =
  let state = channelData(v).state
  withChannelStateLock(state):
    result = state.items.len >= state.capacity

proc channelSendState*(v: Value): tuple[closed: bool, full: bool] =
  let state = channelData(v).state
  withChannelStateLock(state):
    result.closed = state.closed
    result.full = state.items.len >= state.capacity

proc channelRecvState*(v: Value): tuple[closed: bool, empty: bool] =
  let state = channelData(v).state
  withChannelStateLock(state):
    result.closed = state.closed
    result.empty = state.items.len == 0

proc channelItemType*(v: Value): Value =
  channelData(v).itemType

proc channelItemScope*(v: Value): Scope =
  channelData(v).itemScope

proc closeChannel*(v: Value) =
  let state = channelData(v).state
  withChannelStateLock(state):
    state.closed = true

proc pushChannel*(v, item: Value) =
  let stored = escapeWeakFunctions(item)
  let state = channelData(v).state
  withChannelStateLock(state):
    state.items.add stored

proc tryPushChannel*(v, item: Value): tuple[pushed: bool, closed: bool,
                                            full: bool] =
  let stored = escapeWeakFunctions(item)
  let state = channelData(v).state
  withChannelStateLock(state):
    if state.closed:
      result.closed = true
    elif state.items.len >= state.capacity:
      result.full = true
    else:
      state.items.add stored
      result.pushed = true

proc popChannel*(v: Value): Value =
  let state = channelData(v).state
  withChannelStateLock(state):
    if state.items.len == 0:
      raise newException(FieldDefect, "channel is empty")
    result = state.items[0]
    state.items.delete(0)

proc tryPopChannel*(v: Value): tuple[popped: bool, item: Value] =
  let state = channelData(v).state
  withChannelStateLock(state):
    if state.items.len == 0:
      return (false, NIL)
    result.item = state.items[0]
    state.items.delete(0)
    result.popped = true

proc actorData(v: Value): ActorData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okActorRef:
    raise newException(FieldDefect, "value is not an ActorRef")
  ActorData(objData(v))

proc actorState*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.state

proc setActorState*(v, state: Value) =
  let stored = escapeWeakFunctions(state)
  let data = actorData(v)
  withActorLock(data):
    data.state = stored

proc actorHandler*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.handler

proc setActorHandler*(v, handler: Value) =
  let stored = escapeWeakFunctions(handler)
  let data = actorData(v)
  withActorLock(data):
    data.handler = stored

proc actorSnapshotFields*(v: Value): tuple[state: Value, mailbox: int,
                                           closed: bool, processing: bool,
                                           idle: bool] =
  let data = actorData(v)
  withActorLock(data):
    result.state = data.state
    result.mailbox = data.queue.len
    result.closed = data.lifecycle.closed
    result.processing = data.processing
    result.idle = not data.processing and data.queue.len == 0 and
      data.reservedMessages == 0

proc finishActorContinue*(v, state: Value) =
  let stored = escapeWeakFunctions(state)
  let data = actorData(v)
  withActorLock(data):
    data.state = stored
    data.processing = false

proc tryUpgradeIdleActor*(v, state, handler: Value): bool =
  let storedState = escapeWeakFunctions(state)
  let storedHandler = escapeWeakFunctions(handler)
  let data = actorData(v)
  withActorLock(data):
    if data.processing or data.queue.len > 0 or data.reservedMessages > 0:
      return false
    data.state = storedState
    data.handler = storedHandler
    result = true

proc actorRestartInit*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.restartInit

proc actorMessageType*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.messageType

proc actorFailureStrategy*(v: Value): ActorFailureStrategy =
  let data = actorData(v)
  withActorLock(data):
    result = data.failureStrategy

proc actorFailureEvents*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.failureEvents

proc actorFailureDeadLetters*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.failureDeadLetters

proc actorParentFailureEvents*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.parentFailureEvents

proc actorParentFailureDeadLetters*(v: Value): Value =
  let data = actorData(v)
  withActorLock(data):
    result = data.parentFailureDeadLetters

proc setActorMessageType*(v, messageType: Value) =
  let data = actorData(v)
  withActorLock(data):
    data.messageType = messageType

proc actorClosed*(v: Value): bool =
  let data = actorData(v)
  withActorLock(data):
    result = data.lifecycle.closed

proc actorProcessing*(v: Value): bool =
  let data = actorData(v)
  withActorLock(data):
    result = data.processing

proc setActorProcessing*(v: Value, processing: bool) =
  let data = actorData(v)
  withActorLock(data):
    data.processing = processing

proc actorQueueLen*(v: Value): int =
  let data = actorData(v)
  withActorLock(data):
    result = data.queue.len

proc actorFull*(v: Value): bool =
  let data = actorData(v)
  withActorLock(data):
    result = data.queue.len + data.reservedMessages >= data.capacity

proc actorSendState*(v: Value): tuple[closed: bool, full: bool] =
  let data = actorData(v)
  withActorLock(data):
    result.closed = data.lifecycle.closed
    result.full = data.queue.len + data.reservedMessages >= data.capacity

proc closeActor*(v: Value) =
  let data = actorData(v)
  withActorLock(data):
    data.lifecycle.closed = true

proc drainActorMessages*(v: Value): seq[ActorMessage] =
  let data = actorData(v)
  withActorLock(data):
    result = data.queue
    data.queue.setLen(0)

proc closeActorAndDrainMessages*(v: Value): seq[ActorMessage] =
  let data = actorData(v)
  withActorLock(data):
    data.lifecycle.closed = true
    result = data.queue
    data.queue.setLen(0)
    data.reservedMessages = 0
    data.processing = false

proc actorMessagesSnapshot*(v: Value): seq[ActorMessage] =
  let data = actorData(v)
  withActorLock(data):
    result = data.queue

proc pushActorMessage*(v, message: Value) =
  let stored = escapeWeakFunctions(message)
  let data = actorData(v)
  withActorLock(data):
    data.queue.add ActorMessage(message: stored, reply: NIL,
                                workerAllowed: false)

proc pushActorMessage*(v, message, reply: Value) =
  let stored = escapeWeakFunctions(message)
  let data = actorData(v)
  withActorLock(data):
    data.queue.add ActorMessage(message: stored, reply: reply,
                                workerAllowed: true)

proc tryPushActorMessage*(v, message: Value,
                          workerAllowed = false): tuple[pushed: bool,
                                                        closed: bool,
                                                        full: bool] =
  let stored = escapeWeakFunctions(message)
  let data = actorData(v)
  withActorLock(data):
    if data.lifecycle.closed:
      result.closed = true
    elif data.queue.len + data.reservedMessages >= data.capacity:
      result.full = true
    else:
      data.queue.add ActorMessage(message: stored, reply: NIL,
                                  workerAllowed: workerAllowed)
      result.pushed = true

proc tryPushActorMessage*(v, message, reply: Value): tuple[pushed: bool,
                                                           closed: bool,
                                                           full: bool] =
  let stored = escapeWeakFunctions(message)
  let data = actorData(v)
  withActorLock(data):
    if data.lifecycle.closed:
      result.closed = true
    elif data.queue.len + data.reservedMessages >= data.capacity:
      result.full = true
    else:
      data.queue.add ActorMessage(message: stored, reply: reply,
                                  workerAllowed: true)
      result.pushed = true

proc tryReserveActorMessage*(v: Value): tuple[reserved: bool, closed: bool,
                                              full: bool] =
  let data = actorData(v)
  withActorLock(data):
    if data.lifecycle.closed:
      result.closed = true
    elif data.queue.len + data.reservedMessages >= data.capacity:
      result.full = true
    else:
      inc data.reservedMessages
      result.reserved = true

proc releaseReservedActorMessage*(v: Value) =
  let data = actorData(v)
  withActorLock(data):
    if data.reservedMessages > 0:
      dec data.reservedMessages

proc commitReservedActorMessage*(v, message, reply: Value): tuple[pushed: bool,
                                                                  closed: bool] =
  let stored = escapeWeakFunctions(message)
  let data = actorData(v)
  withActorLock(data):
    if data.reservedMessages > 0:
      dec data.reservedMessages
    if data.lifecycle.closed:
      result.closed = true
    else:
      data.queue.add ActorMessage(message: stored, reply: reply,
                                  workerAllowed: true)
      result.pushed = true

proc popActorMessage*(v: Value): ActorMessage =
  let data = actorData(v)
  withActorLock(data):
    if data.queue.len == 0:
      raise newException(FieldDefect, "actor mailbox is empty")
    result = data.queue[0]
    data.queue.delete(0)

proc tryStartActorMessage*(v: Value): tuple[started: bool, item: ActorMessage] =
  let data = actorData(v)
  withActorLock(data):
    if data.processing or data.lifecycle.closed or data.queue.len == 0:
      return (false, ActorMessage())
    result.item = data.queue[0]
    data.queue.delete(0)
    data.processing = true
    result.started = true

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
  let data = replyToData(v)
  withReplyToLock(data):
    result = data.sent

proc replyToResult*(v: Value): Value =
  let data = replyToData(v)
  withReplyToLock(data):
    result = data.result

proc replyToResultType*(v: Value): Value =
  let data = replyToData(v)
  withReplyToLock(data):
    result = data.resultType

proc replyToResultScope*(v: Value): Scope =
  let data = replyToData(v)
  withReplyToLock(data):
    result = data.resultScope

proc replyToTask*(v: Value): Value =
  let data = replyToData(v)
  withReplyToLock(data):
    result = data.task

proc setReplyToResultType*(v, resultType: Value, scope: Scope) =
  let data = replyToData(v)
  withReplyToLock(data):
    data.resultType = resultType
    data.resultScope = scope

proc cancelReplyTo*(v: Value) =
  let data = replyToData(v)
  withReplyToLock(data):
    data.sent = true
    data.result = NIL
    data.task = NIL

proc completeTask*(v, value: Value)

proc claimReplyToCancel*(v: Value): tuple[claimed: bool, task: Value] =
  let data = replyToData(v)
  withReplyToLock(data):
    if data.sent:
      return
    data.sent = true
    data.result = NIL
    result.task = data.task
    data.task = NIL
    result.claimed = true

proc trySendReplyTo*(v, value: Value): tuple[sent: bool, task: Value,
                                             discarded: bool] =
  let stored = escapeWeakFunctions(value)
  let data = replyToData(v)
  withReplyToLock(data):
    if data.sent:
      return
    if data.task.kind == vkTask and data.task.taskDone:
      data.sent = true
      data.result = NIL
      data.task = NIL
      result.sent = true
      result.discarded = true
      return
    data.result = stored
    data.sent = true
    result.task = data.task
    data.task = NIL
    result.sent = true
  if result.task.kind == vkTask:
    completeTask(result.task, stored)

proc sendReplyTo*(v, value: Value) =
  if not trySendReplyTo(v, value).sent:
    raise newException(FieldDefect, "reply has already been sent")

proc cPtrData(v: Value): CPtrData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okCPtr:
    raise newException(FieldDefect, "value is not a C pointer")
  CPtrData(objData(v))

proc cPtrAddress*(v: Value): pointer =
  cPtrData(v).address

proc cPtrTargetType*(v: Value): Value =
  cPtrData(v).targetType

proc cPtrMutable*(v: Value): bool =
  cPtrData(v).mutable

proc cPtrOwned*(v: Value): bool =
  cPtrData(v).owned

proc cPtrClosed*(v: Value): bool =
  cPtrData(v).closed

proc cPtrIsNull*(v: Value): bool =
  let data = cPtrData(v)
  data.address == nil

proc closeCPtr*(v: Value) =
  let data = cPtrData(v)
  if not data.owned:
    raise newException(GeneError, "cannot close a borrowed C pointer")
  if data.closed:
    return
  if data.release != nil and data.address != nil:
    data.release(data.address)
  elif data.foreignRelease != nil and data.address != nil:
    type ForeignReleaseProc = proc(address: pointer) {.cdecl.}
    cast[ForeignReleaseProc](data.foreignRelease)(data.address)
  data.address = nil
  data.closed = true

proc cSliceData(v: Value): CSliceData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okCSlice:
    raise newException(FieldDefect, "value is not a C slice")
  CSliceData(objData(v))

proc cSliceAddress*(v: Value): pointer =
  cSliceData(v).address

proc cSliceLen*(v: Value): int =
  cSliceData(v).length

proc cSliceTargetType*(v: Value): Value =
  cSliceData(v).targetType

proc cSliceMutable*(v: Value): bool =
  cSliceData(v).mutable

proc cSliceIsNull*(v: Value): bool =
  cSliceData(v).address == nil

proc bufferData(v: Value): BufferData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okBuffer:
    raise newException(FieldDefect, "value is not a Buffer")
  BufferData(objData(v))

proc bufferElemType*(v: Value): Value =
  bufferData(v).elemType

proc bufferElemScope*(v: Value): Scope =
  bufferData(v).elemScope

proc bufferLen*(v: Value): int =
  bufferData(v).items.len

proc bufferItems*(v: Value): seq[Value] =
  bufferData(v).items

proc bufferItem*(v: Value, index: int): Value =
  let data = bufferData(v)
  if index < 0 or index >= data.items.len:
    raise newException(FieldDefect, "buffer index out of range")
  data.items[index]

proc setBufferItem*(v: Value, index: int, item: Value) =
  let data = bufferData(v)
  if index < 0 or index >= data.items.len:
    raise newException(FieldDefect, "buffer index out of range")
  data.items[index] = escapeWeakFunctions(item)

proc deviceBufferData(v: Value): DeviceBufferData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okDeviceBuffer:
    raise newException(FieldDefect, "value is not a Device/Buffer")
  DeviceBufferData(objData(v))

proc deviceBufferBackend*(v: Value): string =
  deviceBufferData(v).backend

proc deviceBufferElemType*(v: Value): Value =
  deviceBufferData(v).elemType

proc deviceBufferLen*(v: Value): int =
  deviceBufferData(v).length

proc capabilityData(v: Value): CapabilityData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okCapability:
    raise newException(FieldDefect, "value is not a capability")
  CapabilityData(objData(v))

proc capabilityName*(v: Value): string =
  capabilityData(v).name

proc ffiLibraryData(v: Value): FfiLibraryData =
  if v.tagOf != OBJECT_TAG or objData(v).objKind != okFfiLibrary:
    raise newException(FieldDefect, "value is not an FFI library")
  FfiLibraryData(objData(v))

proc ffiLibraryHandle*(v: Value): pointer =
  ffiLibraryData(v).handle

proc ffiLibraryPath*(v: Value): string =
  ffiLibraryData(v).path

proc ffiLibraryClosed*(v: Value): bool =
  ffiLibraryData(v).closed

proc closeFfiLibrary*(v: Value) =
  let data = ffiLibraryData(v)
  if data.closed:
    return
  if data.close != nil and data.handle != nil:
    data.close(data.handle)
  data.handle = nil
  data.closed = true

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

proc isSmallInt*(v: Value): bool {.inline.} =
  (v.bits shr TAG_SHIFT) == INT_TAG

proc smallIntVal*(v: Value): int64 {.inline.} =
  decodeSmallInt(v.bits)

proc smallIntAddKnown*(a, b: Value, outValue: var Value): bool {.inline.} =
  let s = a.smallIntVal + b.smallIntVal
  if s < SMALL_INT_MIN or s > SMALL_INT_MAX:
    return false
  outValue = mkImm(INT_TAG, encodeSmallInt(s))
  true

proc smallIntSubKnown*(a, b: Value, outValue: var Value): bool {.inline.} =
  let s = a.smallIntVal - b.smallIntVal
  if s < SMALL_INT_MIN or s > SMALL_INT_MAX:
    return false
  outValue = mkImm(INT_TAG, encodeSmallInt(s))
  true

proc smallIntAdd*(a, b: Value, outValue: var Value): bool {.inline.} =
  if not (a.isSmallInt and b.isSmallInt):
    return false
  smallIntAddKnown(a, b, outValue)

proc smallIntSub*(a, b: Value, outValue: var Value): bool {.inline.} =
  if not (a.isSmallInt and b.isSmallInt):
    return false
  smallIntSubKnown(a, b, outValue)

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

proc weakenScopeFunctions(v: Value, owner: Scope): Value =
  if owner == nil or not v.isManaged:
    return v
  case v.kind
  of vkFunction:
    functionForScopeStorage(v, owner)
  of vkList:
    for i, item in v.listItems:
      let weakened = weakenScopeFunctions(item, owner)
      if weakened.bits != item.bits:
        var items = newSeq[Value](v.listItems.len)
        for j in 0 ..< i:
          items[j] = v.listItems[j]
        items[i] = weakened
        for j in i + 1 ..< v.listItems.len:
          items[j] = weakenScopeFunctions(v.listItems[j], owner)
        return newList(items, v.listImmutable)
    v
  of vkMap:
    var changed = false
    for _, val in v.mapEntries:
      let weakened = weakenScopeFunctions(val, owner)
      if weakened.bits != val.bits:
        changed = true
        break
    if not changed:
      return v
    var entries = initOrderedTable[string, Value]()
    for key, val in v.mapEntries:
      entries[key] = weakenScopeFunctions(val, owner)
    newMap(entries, v.mapImmutable)
  of vkNode:
    let weakenedHead = weakenScopeFunctions(v.head, owner)
    var changed = weakenedHead.bits != v.head.bits
    if not changed:
      for _, val in v.props:
        let weakened = weakenScopeFunctions(val, owner)
        if weakened.bits != val.bits:
          changed = true
          break
    if not changed:
      for item in v.body:
        let weakened = weakenScopeFunctions(item, owner)
        if weakened.bits != item.bits:
          changed = true
          break
    if not changed:
      for _, val in v.meta:
        let weakened = weakenScopeFunctions(val, owner)
        if weakened.bits != val.bits:
          changed = true
          break
    if not changed:
      return v
    var props = initOrderedTable[string, Value]()
    for key, val in v.props:
      props[key] = weakenScopeFunctions(val, owner)
    var body: seq[Value]
    for item in v.body:
      body.add weakenScopeFunctions(item, owner)
    var meta = initOrderedTable[string, Value]()
    for key, val in v.meta:
      meta[key] = weakenScopeFunctions(val, owner)
    newNode(weakenedHead, props = props, body = body, meta = meta,
            immutable = v.nodeImmutable)
  of vkBuffer:
    let data = bufferData(v)
    var changed = false
    var items = newSeq[Value](data.items.len)
    for i, item in data.items:
      let weakened = weakenScopeFunctions(item, owner)
      items[i] = weakened
      if weakened.bits != item.bits:
        changed = true
    if not changed:
      return v
    boxObject(BufferData(objKind: okBuffer, elemType: data.elemType,
                         elemScope: data.elemScope, items: items))
  else:
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
    let state = data.state
    var done: bool
    var cancelRequested: bool
    var cancelled: bool
    var awaited: bool
    var sourceResult: Value
    var errorMsg: string
    var sourceError: Value
    var hasErrorValue: bool
    var panicMsg: string
    var sourcePanic: Value
    var hasPanicValue: bool
    withTaskStateLock(state):
      done = state.done
      cancelRequested = state.cancelRequested
      cancelled = state.cancelled
      awaited = state.awaited
      sourceResult = state.result
      errorMsg = state.errorMsg
      sourceError = state.errorValue
      hasErrorValue = state.hasErrorValue
      panicMsg = state.panicMsg
      sourcePanic = state.panicValue
      hasPanicValue = state.hasPanicValue
    let escapedResult = escapeWeakFunctions(sourceResult)
    let escapedError = escapeWeakFunctions(sourceError)
    let escapedPanic = escapeWeakFunctions(sourcePanic)
    if escapedResult.bits == sourceResult.bits and
        escapedError.bits == sourceError.bits and
        escapedPanic.bits == sourcePanic.bits:
      return v
    boxObject(TaskData(objKind: okTask,
                       state: newTaskState(done = done,
                         cancelRequested = cancelRequested,
                         cancelled = cancelled,
                         awaited = awaited,
                         taskResult = escapedResult,
                         errorMsg = errorMsg,
                         errorValue = escapedError,
                         hasErrorValue = hasErrorValue,
                         panicMsg = panicMsg,
                         panicValue = escapedPanic,
                         hasPanicValue = hasPanicValue),
                       resultType: data.resultType,
                       errorType: data.errorType,
                       boundaryScope: data.boundaryScope))
  of vkChannel:
    let data = channelData(v)
    var sourceItems: seq[Value]
    var capacity: int
    var closed: bool
    withChannelStateLock(data.state):
      sourceItems = data.state.items
      capacity = data.state.capacity
      closed = data.state.closed
    var changed = false
    var escapedItems = newSeq[Value](sourceItems.len)
    for i, item in sourceItems:
      escapedItems[i] = escapeWeakFunctions(item)
      if escapedItems[i].bits != item.bits:
        changed = true
    if not changed:
      return v
    let escapedState = newChannelState(capacity, escapedItems, closed)
    boxObject(ChannelData(objKind: okChannel, state: escapedState,
                          itemType: data.itemType,
                          itemScope: data.itemScope))
  of vkActorRef:
    let data = actorData(v)
    var lifecycle: ActorLifecycle
    var capacity: int
    var processing: bool
    var reservedMessages: int
    var sourceState: Value
    var sourceRestartInit: Value
    var sourceHandler: Value
    var sourceMessageType: Value
    var failureStrategy: ActorFailureStrategy
    var sourceFailureEvents: Value
    var sourceFailureDeadLetters: Value
    var sourceParentFailureEvents: Value
    var sourceParentFailureDeadLetters: Value
    var sourceQueue: seq[ActorMessage]
    withActorLock(data):
      lifecycle = data.lifecycle
      capacity = data.capacity
      processing = data.processing
      reservedMessages = data.reservedMessages
      sourceState = data.state
      sourceRestartInit = data.restartInit
      sourceHandler = data.handler
      sourceMessageType = data.messageType
      failureStrategy = data.failureStrategy
      sourceFailureEvents = data.failureEvents
      sourceFailureDeadLetters = data.failureDeadLetters
      sourceParentFailureEvents = data.parentFailureEvents
      sourceParentFailureDeadLetters = data.parentFailureDeadLetters
      sourceQueue = data.queue
    let escapedState = escapeWeakFunctions(sourceState)
    let escapedRestartInit = escapeWeakFunctions(sourceRestartInit)
    let escapedHandler = escapeWeakFunctions(sourceHandler)
    let escapedFailureEvents = escapeWeakFunctions(sourceFailureEvents)
    let escapedFailureDeadLetters = escapeWeakFunctions(sourceFailureDeadLetters)
    let escapedParentFailureEvents =
      escapeWeakFunctions(sourceParentFailureEvents)
    let escapedParentFailureDeadLetters =
      escapeWeakFunctions(sourceParentFailureDeadLetters)
    var escapedQueue = newSeq[ActorMessage](sourceQueue.len)
    var changed = escapedState.bits != sourceState.bits or
      escapedRestartInit.bits != sourceRestartInit.bits or
      escapedHandler.bits != sourceHandler.bits or
      escapedFailureEvents.bits != sourceFailureEvents.bits or
      escapedFailureDeadLetters.bits != sourceFailureDeadLetters.bits or
      escapedParentFailureEvents.bits != sourceParentFailureEvents.bits or
      escapedParentFailureDeadLetters.bits != sourceParentFailureDeadLetters.bits
    for i, item in sourceQueue:
      let escapedMessage = escapeWeakFunctions(item.message)
      let escapedReply = escapeWeakFunctions(item.reply)
      escapedQueue[i] = ActorMessage(message: escapedMessage,
                                     reply: escapedReply,
                                     workerAllowed: item.workerAllowed)
      if escapedMessage.bits != item.message.bits or
          escapedReply.bits != item.reply.bits:
        changed = true
    if not changed:
      return v
    let escapedData = newActorData(capacity,
      state = escapedState,
      restartInit = escapedRestartInit,
      handler = escapedHandler,
      messageType = sourceMessageType,
      failureStrategy = failureStrategy,
      failureEvents = escapedFailureEvents,
      failureDeadLetters = escapedFailureDeadLetters,
      parentFailureEvents = escapedParentFailureEvents,
      parentFailureDeadLetters = escapedParentFailureDeadLetters,
      lifecycle = lifecycle)
    escapedData.queue = escapedQueue
    escapedData.processing = processing
    escapedData.reservedMessages = reservedMessages
    boxObject(escapedData)
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
    var sourceResult: Value
    var sourceTask: Value
    withReplyToLock(data):
      sourceResult = data.result
      sourceTask = data.task
    let escapedResult = escapeWeakFunctions(sourceResult)
    let escapedTask = escapeWeakFunctions(sourceTask)
    if escapedResult.bits != sourceResult.bits or
        escapedTask.bits != sourceTask.bits:
      withReplyToLock(data):
        if data.result.bits == sourceResult.bits:
          data.result = escapedResult
        if data.task.bits == sourceTask.bits:
          data.task = escapedTask
    v
  of vkEnv:
    let data = EnvData(objData(v))
    let escapedParent = escapeWeakFunctions(data.parent)
    var changed = escapedParent.bits != data.parent.bits
    var bindings = initTable[string, Value]()
    for key, val in data.bindings:
      let escaped = escapeWeakFunctions(val)
      bindings[key] = escaped
      if escaped.bits != val.bits:
        changed = true
    var imports = newSeq[Value](data.imports.len)
    for i, item in data.imports:
      let escaped = escapeWeakFunctions(item)
      imports[i] = escaped
      if escaped.bits != item.bits:
        changed = true
    let escapedModule = escapeWeakFunctions(data.module)
    let escapedCapabilities = escapeWeakFunctions(data.capabilities)
    let escapedPolicy = escapeWeakFunctions(data.policy)
    if escapedModule.bits != data.module.bits or
        escapedCapabilities.bits != data.capabilities.bits or
        escapedPolicy.bits != data.policy.bits:
      changed = true
    if not changed:
      return v
    newEnv(bindings, escapedParent, imports, escapedModule,
           escapedCapabilities, escapedPolicy)
  of vkCPtr:
    v
  of vkCSlice:
    v
  of vkBuffer:
    let data = bufferData(v)
    var changed = false
    var items = newSeq[Value](data.items.len)
    for i, item in data.items:
      let escaped = escapeWeakFunctions(item)
      items[i] = escaped
      if escaped.bits != item.bits:
        changed = true
    if not changed:
      return v
    boxObject(BufferData(objKind: okBuffer, elemType: data.elemType,
                         elemScope: data.elemScope, items: items))
  of vkFfiCallable:
    let data = ffiCallableData(v)
    let escapedLibrary = escapeWeakFunctions(data.library)
    if escapedLibrary.bits == data.library.bits:
      return v
    boxObject(FfiCallableData(objKind: okFfiCallable,
                              name: data.name,
                              symbol: data.symbol,
                              address: data.address,
                              library: escapedLibrary,
                              paramTypes: data.paramTypes,
                              returnType: data.returnType,
                              releaseName: data.releaseName,
                              releaseAddress: data.releaseAddress))
  of vkDeviceBuffer, vkCapability, vkFfiLoad, vkFfiLibrary:
    v
  else:
    v

proc newCompletedTask*(value: Value): Value =
  boxObject(TaskData(objKind: okTask,
                     state: newTaskState(done = true,
                       taskResult = escapeWeakFunctions(value))))

proc newPendingTask*(): Value =
  ## A task whose computation has not finished yet. The scheduler fills in the
  ## outcome with completeTask/failTask/panicTask once its fiber settles.
  boxObject(TaskData(objKind: okTask, state: newTaskState(done = false)))

proc newExternalTask*(): Value =
  ## A task whose result is owned by a native/external operation. Awaiting it is
  ## treated as external progress rather than scheduler deadlock.
  boxObject(TaskData(objKind: okTask,
                     state: newTaskState(done = false, external = true)))

proc tryCompleteTask*(v, value: Value): bool =
  let stored = escapeWeakFunctions(value)
  let data = taskState(v)
  withTaskStateLock(data):
    if data.done:
      return
    data.done = true
    data.cancelRequested = false
    data.external = false
    data.result = stored
    result = true
    when compileOption("threads") and defined(gcAtomicArc):
      broadcast(data.cond)

proc completeTask*(v, value: Value) =
  discard tryCompleteTask(v, value)

proc tryFailTask*(v: Value, message: string, value: Value = NIL,
                  hasValue = false): bool =
  let stored = escapeWeakFunctions(value)
  let data = taskState(v)
  withTaskStateLock(data):
    if data.done:
      return
    data.done = true
    data.cancelRequested = false
    data.external = false
    data.errorMsg = message
    data.errorValue = stored
    data.hasErrorValue = hasValue
    result = true
    when compileOption("threads") and defined(gcAtomicArc):
      broadcast(data.cond)

proc failTask*(v: Value, message: string, value: Value = NIL, hasValue = false) =
  discard tryFailTask(v, message, value, hasValue)

proc tryPanicTask*(v: Value, message: string, value: Value = NIL,
                   hasValue = false): bool =
  let stored = escapeWeakFunctions(value)
  let data = taskState(v)
  withTaskStateLock(data):
    if data.done:
      return
    data.done = true
    data.cancelRequested = false
    data.external = false
    data.panicMsg = message
    data.panicValue = stored
    data.hasPanicValue = hasValue
    result = true
    when compileOption("threads") and defined(gcAtomicArc):
      broadcast(data.cond)

proc panicTask*(v: Value, message: string, value: Value = NIL, hasValue = false) =
  discard tryPanicTask(v, message, value, hasValue)

proc newFailedTask*(message: string, value: Value = NIL,
                    hasValue = false): Value =
  boxObject(TaskData(objKind: okTask,
                     state: newTaskState(done = true,
                       errorMsg = message,
                       errorValue = escapeWeakFunctions(value),
                       hasErrorValue = hasValue)))

proc newPanickedTask*(message: string, value: Value = NIL,
                      hasValue = false): Value =
  boxObject(TaskData(objKind: okTask,
                     state: newTaskState(done = true,
                       panicMsg = message,
                       panicValue = escapeWeakFunctions(value),
                       hasPanicValue = hasValue)))

proc newCheckedTask*(source, resultType, errorType: Value,
                     boundaryScope: Scope): Value =
  let data = taskData(source)
  boxObject(TaskData(objKind: okTask, state: data.state,
                     resultType: resultType, errorType: errorType,
                     boundaryScope: boundaryScope))

proc newChannel*(capacity = 16): Value =
  boxObject(ChannelData(objKind: okChannel,
                        state: newChannelState(capacity)))

proc newCheckedChannel*(source, itemType: Value, itemScope: Scope): Value =
  let data = channelData(source)
  boxObject(ChannelData(objKind: okChannel, state: data.state,
                        itemType: itemType, itemScope: itemScope))

proc newActorRef*(capacity: int, state, handler, messageType: Value,
                  restartInit: Value = NIL,
                  failureStrategy: ActorFailureStrategy = afsStop,
                  failureEvents: Value = NIL,
                  failureDeadLetters: Value = NIL,
                  parentFailureEvents: Value = NIL,
                  parentFailureDeadLetters: Value = NIL): Value =
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
  boxObject(newActorData(capacity,
                         state = escapeWeakFunctions(state),
                         restartInit = storedRestartInit,
                         handler = storedHandler,
                         messageType = messageType,
                         failureStrategy = failureStrategy,
                         failureEvents = failureEvents,
                         failureDeadLetters = failureDeadLetters,
                         parentFailureEvents = parentFailureEvents,
                         parentFailureDeadLetters = parentFailureDeadLetters))

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
  let data = ReplyToData(objKind: okReplyTo,
                         result: NIL,
                         resultType: resultType,
                         resultScope: resultScope,
                         task: task)
  initLock(data.lock)
  boxObject(data)

proc newCPtr*(address: pointer, targetType: Value = NIL,
              mutable = true): Value =
  boxObject(CPtrData(objKind: okCPtr, address: address,
                     targetType: targetType, mutable: mutable))

proc newCConstPtr*(address: pointer, targetType: Value = NIL): Value =
  newCPtr(address, targetType, mutable = false)

proc newCOwnedPtr*(address: pointer, release: CPtrReleaseProc,
                   targetType: Value = NIL, mutable = true): Value =
  boxObject(CPtrData(objKind: okCPtr, address: address,
                     targetType: targetType, mutable: mutable,
                     owned: true, release: release))

proc newCForeignOwnedPtr*(address: pointer, releaseAddress: pointer,
                          targetType: Value = NIL,
                          mutable = true): Value =
  boxObject(CPtrData(objKind: okCPtr, address: address,
                     targetType: targetType, mutable: mutable,
                     owned: true, foreignRelease: releaseAddress))

proc newCSlice*(address: pointer, length: int, targetType: Value = NIL,
                mutable = true): Value =
  if length < 0:
    raise newException(GeneError, "C slice length must be non-negative")
  boxObject(CSliceData(objKind: okCSlice, address: address, length: length,
                       targetType: targetType, mutable: mutable))

proc newBuffer*(elemType: Value = NIL, items: sink seq[Value] = @[],
                elemScope: Scope = nil): Value =
  for i in 0 ..< items.len:
    if items[i].kind == vkVoid:
      items[i] = NIL
    else:
      items[i] = escapeWeakFunctions(items[i])
  boxObject(BufferData(objKind: okBuffer, elemType: elemType,
                       elemScope: elemScope, items: items))

proc newDeviceBuffer*(backend: string, elemType: Value, length: int): Value =
  if backend.len == 0:
    raise newException(GeneError, "Device/Buffer backend must not be empty")
  if length < 0:
    raise newException(GeneError, "Device/Buffer length must be non-negative")
  boxObject(DeviceBufferData(objKind: okDeviceBuffer,
                             backend: backend,
                             elemType: elemType,
                             length: length))

proc newFfiLoadCapability*(): Value =
  boxObject(FfiLoadData(objKind: okFfiLoad))

proc newCapability*(name: string): Value =
  if name.len == 0:
    raise newException(GeneError, "capability name must not be empty")
  boxObject(CapabilityData(objKind: okCapability, name: name))

proc newFfiLibrary*(handle: pointer, path: string,
                    close: FfiLibraryCloseProc): Value =
  if handle == nil:
    raise newException(GeneError, "FFI library handle must not be nil")
  boxObject(FfiLibraryData(objKind: okFfiLibrary, handle: handle,
                           path: path, close: close))

proc newFfiCallable*(name, symbol: string, address: pointer, library: Value,
                     paramTypes: seq[Value], returnType: Value,
                     releaseName = "", releaseAddress: pointer = nil): Value =
  if address == nil:
    raise newException(GeneError, "FFI callable address must not be nil")
  boxObject(FfiCallableData(objKind: okFfiCallable,
                            name: name,
                            symbol: symbol,
                            address: address,
                            library: library,
                            paramTypes: paramTypes,
                            returnType: returnType,
                            releaseName: releaseName,
                            releaseAddress: releaseAddress))

proc classifyNativeFastKind(name: string): NativeFastKind =
  case name
  of "+": nfkAdd
  of "-": nfkSub
  of "*": nfkMul
  of "<": nfkLt
  of ">": nfkGt
  of "<=": nfkLe
  of ">=": nfkGe
  else: nfkNone

proc newNativeFn*(name: string, impl: NativeProc,
                  acceptsNamed = false): Value =
  let p = createObj(GeneNativeFn)
  p.refCount = 1
  p.name = name
  p.impl = impl
  p.acceptsNamed = acceptsNamed
  p.fastKind = classifyNativeFastKind(name)
  boxPtr(NATIVE_FN_TAG, p)

proc newNativeCallFn*(name: string, impl: NativeCallProc,
                      acceptsNamed = true): Value =
  let p = createObj(GeneNativeFn)
  p.refCount = 1
  p.name = name
  p.callImpl = impl
  p.acceptsNamed = acceptsNamed
  p.fastKind = nfkNone
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
             policy: Value = NIL,
             bindingScope: Scope = nil): Value =
  var storedBindings = initTable[string, Value]()
  for key, value in bindings:
    storedBindings[key] = weakenScopeFunctions(value, bindingScope)
  boxObject(EnvData(objKind: okEnv, parent: parent, bindings: storedBindings,
                    imports: imports, module: module,
                    capabilities: capabilities, policy: policy))

proc newCell*(value: Value): Value =
  boxObject(CellData(objKind: okCell, value: value))

proc newAtomicCell*(value: Value): Value =
  let d = AtomicCellData(objKind: okAtomicCell, value: value)
  initLock(d.lock)
  boxObject(d)

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
