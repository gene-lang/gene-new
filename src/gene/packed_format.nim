## Reversible AI-native program format -- durable packed binary encoding (v0).
##
## `encodePacked`/`decodePacked` implement the "Packed file encoding" and
## "Validation and safety" sections of
## `docs/proposals/reversible-ai-native-program-format.md`: a framed,
## versioned, length-checked binary encoding of a `ProgramDocument`
## (`program_document.nim`), independent of process pointers, intern ids,
## NaN-box payload bits, or host endianness.
##
## v0 value coverage: nil, void, bool, int (int64 range), float, string,
## bytes, char, symbol, node, list, map, hash-map -- every reader literal and
## collection kind actually reachable from `readAll` output except regex,
## range, date/time/datetime/timezone/duration, and out-of-int64-range
## bigints. Those are cleanly rejected with `PackedUnsupportedError` during
## encode rather than silently mis-encoded; `vkSet` and every runtime-only
## kind cannot appear in reader output at all (confirmed: Gene has no literal
## set syntax), so they need no wire representation here.
##
## Wire tags are their own explicit enum, independent of `ValueKind`'s
## ordinal, so a future reordering or extension of `ValueKind` can never
## silently change what an already-written packed file means.

import std/unicode
import ./program_document
import ./types
import ./source_index

type
  PackedError* = object of CatchableError
  PackedUnsupportedError* = object of PackedError
  PackedLimitError* = object of PackedError

  PackedLimits* = object
    maxDepth*: int
    maxCollectionSize*: int
    maxStringBytes*: int
    maxTotalForms*: int
    maxTotalAllocationBytes*: int  ## Cap on the packed buffer's own byte
                                    ## length (checked against `data.len`
                                    ## before decoding starts, and against
                                    ## the finished buffer after encoding) --
                                    ## a cheap, allocation-free proxy for
                                    ## total resource consumption, not a
                                    ## precise decoded-heap-size accounting.

const magicBytes = "GNPD"
const formatVersion = 1'u8

proc defaultLimits*(): PackedLimits =
  PackedLimits(maxDepth: 512, maxCollectionSize: 1_000_000,
               maxStringBytes: 64 * 1024 * 1024, maxTotalForms: 1_000_000,
               maxTotalAllocationBytes: 512 * 1024 * 1024)

type
  WireTag = enum
    wtNil = 0'u8, wtVoid = 1, wtBoolFalse = 2, wtBoolTrue = 3, wtInt = 4,
    wtFloat = 5, wtString = 6, wtBytes = 7, wtChar = 8, wtSymbol = 9,
    wtNode = 10, wtNodeImmutable = 11, wtList = 12, wtListImmutable = 13,
    wtMap = 14, wtMapImmutable = 15, wtHashMap = 16

  WirePathTag = enum
    wpProperty = 0'u8, wpIndex = 1

  WirePlacement = enum
    wpStandalone = 0'u8, wpTrailing = 1

# ---------------------------------------------------------------------------
# Primitive writers (unsigned LEB128 varints, zigzag for signed, raw bytes)
# ---------------------------------------------------------------------------

proc putVarint(buf: var string, v: uint64) =
  var x = v
  while true:
    var b = uint8(x and 0x7F)
    x = x shr 7
    if x != 0: b = b or 0x80'u8
    buf.add char(b)
    if x == 0: break

proc putSVarint(buf: var string, v: int64) =
  let zz = (uint64(v) shl 1) xor uint64(v shr 63)
  buf.putVarint(zz)

proc putBytes(buf: var string, s: string, limits: PackedLimits) =
  if s.len > limits.maxStringBytes:
    raise newException(PackedLimitError,
      "string/bytes payload exceeds maxStringBytes: " & $s.len)
  buf.putVarint(uint64(s.len))
  buf.add s

proc putFloat64(buf: var string, f: float64) =
  var bits: uint64
  copyMem(addr bits, unsafeAddr f, 8)
  for i in 0 ..< 8:
    buf.add char((bits shr (8 * i)) and 0xFF)

# ---------------------------------------------------------------------------
# Primitive readers -- every one bounds-checks before reading.
# ---------------------------------------------------------------------------

type Cursor = object
  data: string
  pos: int

proc atEnd(c: Cursor): bool = c.pos >= c.data.len

proc getByte(c: var Cursor): uint8 =
  if c.pos >= c.data.len:
    raise newException(PackedError, "truncated packed document (expected a byte)")
  result = uint8(c.data[c.pos])
  inc c.pos

proc getVarint(c: var Cursor): uint64 =
  var shift = 0
  while true:
    if shift > 63:
      raise newException(PackedError, "malformed varint (too long)")
    let b = c.getByte()
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: break
    shift += 7

proc getSVarint(c: var Cursor): int64 =
  let zz = c.getVarint()
  int64(zz shr 1) xor -int64(zz and 1)

proc getBytes(c: var Cursor, limits: PackedLimits): string =
  let n = c.getVarint()
  if n > uint64(limits.maxStringBytes):
    raise newException(PackedLimitError, "string/bytes payload exceeds maxStringBytes: " & $n)
  if n > uint64(c.data.len - c.pos):
    raise newException(PackedError, "truncated packed document (string/bytes payload)")
  result = c.data[c.pos ..< c.pos + int(n)]
  c.pos += int(n)

proc getFloat64(c: var Cursor): float64 =
  if c.data.len - c.pos < 8:
    raise newException(PackedError, "truncated packed document (float payload)")
  var bits: uint64
  for i in 0 ..< 8:
    bits = bits or (uint64(uint8(c.data[c.pos + i])) shl (8 * i))
  c.pos += 8
  copyMem(addr result, addr bits, 8)

# ---------------------------------------------------------------------------
# Value encoding
# ---------------------------------------------------------------------------

proc encodeValue(buf: var string, v: Value, limits: PackedLimits, depth: int) =
  if depth > limits.maxDepth:
    raise newException(PackedLimitError, "nesting depth exceeds maxDepth: " & $depth)
  case v.kind
  of vkNil: buf.add char(wtNil.uint8)
  of vkVoid: buf.add char(wtVoid.uint8)
  of vkBool: buf.add char((if v.boolVal: wtBoolTrue else: wtBoolFalse).uint8)
  of vkInt:
    if not v.intFitsInt64:
      raise newException(PackedUnsupportedError,
        "program_document v0 does not encode bigint-overflow integers")
    buf.add char(wtInt.uint8)
    buf.putSVarint(v.intVal)
  of vkFloat:
    buf.add char(wtFloat.uint8)
    buf.putFloat64(v.floatVal)
  of vkString:
    buf.add char(wtString.uint8)
    buf.putBytes(v.strVal, limits)
  of vkBytes:
    buf.add char(wtBytes.uint8)
    buf.putBytes(v.bytesVal, limits)
  of vkChar:
    buf.add char(wtChar.uint8)
    buf.putVarint(uint64(int32(v.charVal)))
  of vkSymbol:
    buf.add char(wtSymbol.uint8)
    buf.putBytes(v.symVal, limits)
  of vkNode:
    buf.add char((if v.nodeImmutable: wtNodeImmutable else: wtNode).uint8)
    encodeValue(buf, v.head, limits, depth + 1)
    if v.meta.len > limits.maxCollectionSize or v.props.len > limits.maxCollectionSize:
      raise newException(PackedLimitError, "prop/meta table exceeds maxCollectionSize")
    buf.putVarint(uint64(v.meta.len))
    for k, val in v.meta.pairs:
      buf.putBytes(k, limits)
      encodeValue(buf, val, limits, depth + 1)
    buf.putVarint(uint64(v.props.len))
    for k, val in v.props.pairs:
      buf.putBytes(k, limits)
      encodeValue(buf, val, limits, depth + 1)
    if v.body.len > limits.maxCollectionSize:
      raise newException(PackedLimitError, "node body exceeds maxCollectionSize")
    buf.putVarint(uint64(v.body.len))
    for it in v.body:
      encodeValue(buf, it, limits, depth + 1)
  of vkList:
    buf.add char((if v.listImmutable: wtListImmutable else: wtList).uint8)
    if v.listItems.len > limits.maxCollectionSize:
      raise newException(PackedLimitError, "list exceeds maxCollectionSize")
    buf.putVarint(uint64(v.listItems.len))
    for it in v.listItems:
      encodeValue(buf, it, limits, depth + 1)
  of vkMap:
    buf.add char((if v.mapImmutable: wtMapImmutable else: wtMap).uint8)
    if v.mapEntries.len > limits.maxCollectionSize:
      raise newException(PackedLimitError, "map exceeds maxCollectionSize")
    buf.putVarint(uint64(v.mapEntries.len))
    for k, val in v.mapEntries:
      buf.putBytes(k, limits)
      encodeValue(buf, val, limits, depth + 1)
  of vkHashMap:
    buf.add char(wtHashMap.uint8)
    if v.hashMapEntries.len > limits.maxCollectionSize:
      raise newException(PackedLimitError, "hash-map exceeds maxCollectionSize")
    buf.putVarint(uint64(v.hashMapEntries.len))
    for entry in v.hashMapEntries:
      encodeValue(buf, entry.key, limits, depth + 1)
      encodeValue(buf, entry.val, limits, depth + 1)
  else:
    raise newException(PackedUnsupportedError,
      "program_document v0 does not encode value kind " & $v.kind)

proc decodeValue(c: var Cursor, limits: PackedLimits, depth: int): Value =
  if depth > limits.maxDepth:
    raise newException(PackedLimitError, "nesting depth exceeds maxDepth: " & $depth)
  let tagByte = c.getByte()
  if tagByte > wtHashMap.uint8:
    raise newException(PackedError, "unknown value tag: " & $tagByte)
  let tag = WireTag(tagByte)
  case tag
  of wtNil: NIL
  of wtVoid: VOID
  of wtBoolFalse: newBool(false)
  of wtBoolTrue: newBool(true)
  of wtInt: newInt(c.getSVarint())
  of wtFloat: newFloat(c.getFloat64())
  of wtString: newStr(c.getBytes(limits))
  of wtBytes: newBytes(c.getBytes(limits))
  of wtChar: newChar(Rune(int32(c.getVarint())))
  of wtSymbol: newSym(c.getBytes(limits))
  of wtNode, wtNodeImmutable:
    let head = decodeValue(c, limits, depth + 1)
    let metaCount = c.getVarint()
    if metaCount > uint64(limits.maxCollectionSize):
      raise newException(PackedLimitError, "prop/meta table exceeds maxCollectionSize")
    var meta = initPropTable()
    for _ in 0 ..< metaCount:
      let k = c.getBytes(limits)
      meta[k] = decodeValue(c, limits, depth + 1)
    let propCount = c.getVarint()
    if propCount > uint64(limits.maxCollectionSize):
      raise newException(PackedLimitError, "prop/meta table exceeds maxCollectionSize")
    var props = initPropTable()
    for _ in 0 ..< propCount:
      let k = c.getBytes(limits)
      props[k] = decodeValue(c, limits, depth + 1)
    let bodyCount = c.getVarint()
    if bodyCount > uint64(limits.maxCollectionSize):
      raise newException(PackedLimitError, "node body exceeds maxCollectionSize")
    var body = newSeq[Value](bodyCount)
    for i in 0 ..< bodyCount.int: body[i] = decodeValue(c, limits, depth + 1)
    newNode(head, props, body, meta, immutable = tag == wtNodeImmutable)
  of wtList, wtListImmutable:
    let n = c.getVarint()
    if n > uint64(limits.maxCollectionSize):
      raise newException(PackedLimitError, "list exceeds maxCollectionSize")
    var items = newSeq[Value](n)
    for i in 0 ..< n.int: items[i] = decodeValue(c, limits, depth + 1)
    newList(items, immutable = tag == wtListImmutable)
  of wtMap, wtMapImmutable:
    let n = c.getVarint()
    if n > uint64(limits.maxCollectionSize):
      raise newException(PackedLimitError, "map exceeds maxCollectionSize")
    var entries = initPropTable()
    for _ in 0 ..< n:
      let k = c.getBytes(limits)
      entries[k] = decodeValue(c, limits, depth + 1)
    newMap(entries, immutable = tag == wtMapImmutable)
  of wtHashMap:
    let n = c.getVarint()
    if n > uint64(limits.maxCollectionSize):
      raise newException(PackedLimitError, "hash-map exceeds maxCollectionSize")
    var entries = newSeq[HashMapEntry](n)
    for i in 0 ..< n.int:
      let key = decodeValue(c, limits, depth + 1)
      let val = decodeValue(c, limits, depth + 1)
      entries[i] = HashMapEntry(key: key, val: val)
    newHashMap(entries)

# ---------------------------------------------------------------------------
# Path segment + comment record encoding
# ---------------------------------------------------------------------------

proc encodePath(buf: var string, path: DocPath, limits: PackedLimits) =
  if path.len > limits.maxDepth:
    raise newException(PackedLimitError, "comment path exceeds maxDepth")
  buf.putVarint(uint64(path.len))
  for seg in path:
    case seg.kind
    of spsProperty:
      buf.add char(wpProperty.uint8)
      buf.putBytes(seg.name, limits)
    of spsIndex:
      buf.add char(wpIndex.uint8)
      buf.putSVarint(seg.index)

proc decodePath(c: var Cursor, limits: PackedLimits): DocPath =
  let n = c.getVarint()
  if n > uint64(limits.maxDepth):
    raise newException(PackedLimitError, "comment path exceeds maxDepth")
  result = newSeq[DocPathSegment](n)
  for i in 0 ..< n.int:
    let tagByte = c.getByte()
    if tagByte > wpIndex.uint8:
      raise newException(PackedError, "unknown path segment tag: " & $tagByte)
    case WirePathTag(tagByte)
    of wpProperty: result[i] = propertySegment(c.getBytes(limits))
    of wpIndex: result[i] = indexSegment(c.getSVarint())

proc encodeComment(buf: var string, rec: CommentRecord, limits: PackedLimits) =
  buf.putSVarint(int64(rec.formIndex))
  encodePath(buf, rec.containerPath, limits)
  buf.putSVarint(int64(rec.afterChild))
  buf.putVarint(uint64(rec.ordinal))
  buf.add char((if rec.placement == cpTrailing: wpTrailing else: wpStandalone).uint8)
  buf.putBytes(rec.text, limits)

proc decodeComment(c: var Cursor, limits: PackedLimits): CommentRecord =
  result.formIndex = int(c.getSVarint())
  result.containerPath = decodePath(c, limits)
  result.afterChild = int(c.getSVarint())
  let ordVal = c.getVarint()
  if ordVal > uint64(limits.maxCollectionSize):
    raise newException(PackedLimitError, "comment ordinal implausibly large")
  result.ordinal = int(ordVal)
  let placeByte = c.getByte()
  if placeByte > wpTrailing.uint8:
    raise newException(PackedError, "unknown comment placement tag: " & $placeByte)
  result.placement = if WirePlacement(placeByte) == wpTrailing: cpTrailing else: cpStandalone
  result.text = c.getBytes(limits)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc encodePacked*(doc: ProgramDocument, limits = defaultLimits()): string =
  ## Deterministic: encoding the same document twice yields identical bytes.
  result = magicBytes
  result.add char(formatVersion)
  if doc.forms.len > limits.maxTotalForms:
    raise newException(PackedLimitError, "form count exceeds maxTotalForms")
  result.putVarint(uint64(doc.forms.len))
  for f in doc.forms:
    encodeValue(result, f, limits, 1)
  result.add (if doc.hasBangLine: char(1) else: char(0))
  if doc.hasBangLine:
    result.putBytes(doc.bangLine, limits)
  result.putVarint(uint64(doc.comments.len))
  for c in doc.comments:
    encodeComment(result, c, limits)
  if result.len > limits.maxTotalAllocationBytes:
    raise newException(PackedLimitError,
      "encoded document exceeds maxTotalAllocationBytes")

proc decodePacked*(data: string, limits = defaultLimits()): ProgramDocument =
  ## Fails closed: malformed framing, truncated input, an unsupported/future
  ## version, or any exceeded limit all raise `PackedError` (or a subtype)
  ## rather than returning a partial or best-effort document.
  if data.len > limits.maxTotalAllocationBytes:
    raise newException(PackedLimitError, "packed document exceeds maxTotalAllocationBytes")
  if data.len < magicBytes.len + 1:
    raise newException(PackedError, "truncated packed document (no magic/version)")
  if data[0 ..< magicBytes.len] != magicBytes:
    raise newException(PackedError, "bad magic: not a program_document packed file")
  var c = Cursor(data: data, pos: magicBytes.len)
  let version = c.getByte()
  if version != formatVersion:
    raise newException(PackedError, "unsupported program_document format version: " & $version)
  let formCount = c.getVarint()
  if formCount > uint64(limits.maxTotalForms):
    raise newException(PackedLimitError, "form count exceeds maxTotalForms")
  result.forms = newSeq[Value](formCount)
  for i in 0 ..< formCount.int:
    result.forms[i] = decodeValue(c, limits, 1)
  let bangFlag = c.getByte()
  if bangFlag notin {0'u8, 1'u8}:
    raise newException(PackedError, "malformed bang-line flag")
  result.hasBangLine = bangFlag == 1
  if result.hasBangLine:
    result.bangLine = c.getBytes(limits)
  let commentCount = c.getVarint()
  if commentCount > uint64(limits.maxCollectionSize):
    raise newException(PackedLimitError, "comment count exceeds maxCollectionSize")
  result.comments = newSeq[CommentRecord](commentCount)
  for i in 0 ..< commentCount.int:
    result.comments[i] = decodeComment(c, limits)
  if not c.atEnd:
    raise newException(PackedError,
      "trailing data after a complete packed document (" &
      $(data.len - c.pos) & " byte(s))")
