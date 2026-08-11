## Reversible AI-native program format -- model-native logical unit export (v0).
##
## Implements the "First model-pilot unit recommendation" from
## `docs/proposals/reversible-ai-native-program-format.md`: a flat, linear
## sequence of typed structural/payload units over a `ProgramDocument`
## (`program_document.nim`), suitable for a model's data loader to turn into
## training positions. Structural roles use a small fixed enum; identifiers,
## strings, and comments carry their payload inline as UTF-8 text; integers
## and floats carry their canonical decimal text (kept as strings, not JSON
## numbers, so no consumer's float/bigint parser can silently lose
## precision). Every container has an explicit start/end unit pair, so a
## consumer never has to predict a subtree's length before generating it.
##
## This module is a training-data *export* format (JSON Lines, one unit
## object per line), not the durable ABI -- `packed_format.nim` remains the
## versioned, frozen wire format. JSONL trades wire compactness for being
## trivially readable from Python without a Gene runtime, which matters more
## for a first data pipeline than the byte savings would.
##
## v0 shares program_document.nim's container coverage: fully structural for
## `vkNode`/`vkList`/`vkMap`/`vkHashMap`; any other value kind (the same
## regex/range/date-family this repo's packed_format.nim also declines) is
## rejected explicitly rather than mis-emitted.

import std/[json, strutils, tables, unicode]
import ./program_document
import ./source_index
import ./printer
import ./types

type
  UnitKind* = enum
    ukFormStart, ukFormEnd
    ukNodeStart, ukNodeEnd, ukNodeImmutableStart
    ukListStart, ukListEnd, ukListImmutableStart
    ukMapStart, ukMapEnd, ukMapImmutableStart
    ukHashMapStart, ukHashMapEnd
    ukRoleHead
    ukRoleMetaKey, ukRolePropKey, ukRoleMapKey  ## payload: the key name
    ukRoleBody, ukRoleHashMapKey, ukRoleHashMapValue
    ukNil, ukVoid, ukBoolTrue, ukBoolFalse
    ukInt      ## payload: canonical decimal text, e.g. "-42"
    ukFloat    ## payload: canonical decimal text, e.g. "3.5", "inf", "nan"
    ukString, ukBytes, ukSymbol  ## payload: UTF-8 text
    ukChar     ## payload: the single character as UTF-8 text
    ukCommentStandalone, ukCommentTrailing  ## payload: raw comment text
    ukBangLine  ## payload: raw `#!...` text

  Unit* = object
    kind*: UnitKind
    text*: string  ## meaning depends on kind; "" when a kind carries no payload

  DocumentUnitsError* = object of CatchableError

proc u(kind: UnitKind, text = ""): Unit = Unit(kind: kind, text: text)

proc emitComments(units: var seq[Unit], idx: Table[string, seq[CommentEntry]],
                   formIndex: int, path: DocPath, afterChild: int) =
  let key = keyStr(formIndex, path, afterChild)
  if not idx.hasKey(key): return
  for entry in idx[key]:
    units.add u(
      (if entry.placement == cpTrailing: ukCommentTrailing else: ukCommentStandalone),
      entry.text)

proc emitOpenComments(units: var seq[Unit], idx: Table[string, seq[CommentEntry]],
                       formIndex: int, path: DocPath) =
  ## Mirrors program_document.nim's `emitOpen`: a container's opening
  ## boundary drains both the precise "before the first child" bucket (-1)
  ## and the opaque "somewhere in here" bucket (-2), in that order. Draining
  ## only -1 would silently drop every opaquely-anchored comment from the
  ## unit stream while the canonical writer still emitted it -- a
  ## representation loss the pilot's first gate exists to catch.
  ##
  ## The decoder re-anchors both buckets at -1, which reprints identically
  ## because the writer drains the two adjacently and in this same order.
  emitComments(units, idx, formIndex, path, -1)
  emitComments(units, idx, formIndex, path, -2)

proc emitValue(units: var seq[Unit], v: Value, idx: Table[string, seq[CommentEntry]],
                formIndex: int, path: DocPath) =
  case v.kind
  of vkNil: units.add u(ukNil)
  of vkVoid: units.add u(ukVoid)
  of vkBool: units.add u(if v.boolVal: ukBoolTrue else: ukBoolFalse)
  of vkInt:
    if not v.intFitsInt64:
      raise newException(DocumentUnitsError,
        "document_units v0 does not encode bigint-overflow integers")
    units.add u(ukInt, $v.intVal)
  of vkFloat: units.add u(ukFloat, v.print())
  of vkString: units.add u(ukString, v.strVal)
  of vkBytes: units.add u(ukBytes, v.bytesVal)
  of vkChar: units.add u(ukChar, $v.charVal)
  of vkSymbol: units.add u(ukSymbol, v.symVal)
  of vkNode:
    units.add u(if v.nodeImmutable: ukNodeImmutableStart else: ukNodeStart)
    emitOpenComments(units, idx, formIndex, path)
    units.add u(ukRoleHead)
    emitValue(units, v.head, idx, formIndex, path & propertySegment("head"))
    emitComments(units, idx, formIndex, path, 0)
    var i = 0
    for k, val in v.meta.pairs:
      units.add u(ukRoleMetaKey, k)
      emitValue(units, val, idx, formIndex,
                path & propertySegment("meta") & propertySegment(k))
      emitComments(units, idx, formIndex, path, 1 + i)
      inc i
    var j = 0
    for k, val in v.props.pairs:
      units.add u(ukRolePropKey, k)
      emitValue(units, val, idx, formIndex, path & propertySegment(k))
      emitComments(units, idx, formIndex, path, 1 + v.meta.len + j)
      inc j
    for bi, it in v.body:
      units.add u(ukRoleBody)
      emitValue(units, it, idx, formIndex, path & indexSegment(bi.int64))
      emitComments(units, idx, formIndex, path, 1 + v.meta.len + v.props.len + bi)
    units.add u(ukNodeEnd)
  of vkList:
    units.add u(if v.listImmutable: ukListImmutableStart else: ukListStart)
    emitOpenComments(units, idx, formIndex, path)
    for i, it in v.listItems:
      emitValue(units, it, idx, formIndex, path & indexSegment(i.int64))
      emitComments(units, idx, formIndex, path, i)
    units.add u(ukListEnd)
  of vkMap:
    units.add u(if v.mapImmutable: ukMapImmutableStart else: ukMapStart)
    emitOpenComments(units, idx, formIndex, path)
    var i = 0
    for k, val in v.mapEntries:
      units.add u(ukRoleMapKey, k)
      emitValue(units, val, idx, formIndex, path & propertySegment(k))
      emitComments(units, idx, formIndex, path, i)
      inc i
    units.add u(ukMapEnd)
  of vkHashMap:
    units.add u(ukHashMapStart)
    emitOpenComments(units, idx, formIndex, path)
    for i, entry in v.hashMapEntries:
      units.add u(ukRoleHashMapKey)
      emitValue(units, entry.key, idx, formIndex, path & indexSegment(i.int64))
      units.add u(ukRoleHashMapValue)
      emitValue(units, entry.val, idx, formIndex, path & indexSegment(i.int64))
      emitComments(units, idx, formIndex, path, i)
    units.add u(ukHashMapEnd)
  else:
    raise newException(DocumentUnitsError,
      "document_units v0 does not encode value kind " & $v.kind)

proc unitsOf*(doc: ProgramDocument): seq[Unit] =
  ## Flat logical-unit sequence for the whole document, in canonical order.
  let idx = doc.buildCommentIndex()
  if doc.hasBangLine:
    result.add u(ukBangLine, doc.bangLine)
  emitComments(result, idx, -1, @[], -1)
  for f in 0 ..< doc.forms.len:
    result.add u(ukFormStart)
    emitValue(result, doc.forms[f], idx, f, @[])
    result.add u(ukFormEnd)
    emitComments(result, idx, -1, @[], f)

proc toJsonLines*(units: seq[Unit]): string =
  ## One compact JSON object per line: {"k": "<UnitKind>", "t": "<text>"}.
  ## `t` is omitted when empty, since most structural units carry no payload.
  for unit in units:
    var obj = newJObject()
    obj["k"] = %($unit.kind)
    if unit.text.len > 0:
      obj["t"] = %unit.text
    result.add $obj
    result.add '\n'

# ---------------------------------------------------------------------------
# Decoding: units -> ProgramDocument
# ---------------------------------------------------------------------------
#
# The inverse of `unitsOf`. The proposal's first pre-registered pilot gate is
# that the training data loader and generated logical units round-trip "with
# zero representation loss", which is only checkable against a real decoder --
# so this direction is part of the format, not a test helper.
#
# Comment records are rebuilt by walking the same canonical boundaries
# `emitValue` emits them at, so `writeCanonical` reprints them identically.
# Only their relative order within a boundary is load-bearing (that is what
# `buildCommentIndex` sorts on), so a single ascending counter suffices for
# `ordinal` -- the original numbering is not recoverable and does not matter.

const decodeMaxDepth* = 512
  ## Matches packed_format.nim's `PackedLimits.maxDepth`. A decoder is fed
  ## model-generated streams, where an unbounded run of container-start units
  ## is an ordinary sampling outcome -- without this, `decodeValue`'s
  ## recursion turns that into a stack overflow (a crash the caller cannot
  ## catch) instead of a structural failure it can count.

type
  Decoder = object
    units: seq[Unit]
    pos: int
    doc: ProgramDocument
    ordinal: int
    depth: int

proc isCanonicalIntText(s: string): bool =
  ## `ukInt` payloads are exactly what `$v.intVal` produced: optional `-`,
  ## then digits. Anything else came from a corrupt or generated stream.
  var i = 0
  if i < s.len and s[i] == '-': inc i
  if i >= s.len: return false
  while i < s.len:
    if s[i] notin {'0'..'9'}: return false
    inc i
  true

proc atEnd(d: Decoder): bool {.inline.} = d.pos >= d.units.len

proc fail(d: Decoder, msg: string) {.noreturn.} =
  raise newException(DocumentUnitsError,
    "unit stream at index " & $d.pos & ": " & msg)

proc take(d: var Decoder, expected: UnitKind): Unit =
  if d.atEnd:
    d.fail("expected " & $expected & ", got end of stream")
  result = d.units[d.pos]
  if result.kind != expected:
    d.fail("expected " & $expected & ", got " & $result.kind)
  inc d.pos

proc takeComments(d: var Decoder, formIndex: int, path: DocPath, afterChild: int) =
  while not d.atEnd and
        d.units[d.pos].kind in {ukCommentStandalone, ukCommentTrailing}:
    let unit = d.units[d.pos]
    inc d.pos
    d.doc.comments.add CommentRecord(
      formIndex: formIndex, containerPath: path, afterChild: afterChild,
      ordinal: d.ordinal,
      placement:
        (if unit.kind == ukCommentTrailing: cpTrailing else: cpStandalone),
      text: unit.text)
    inc d.ordinal

proc decodeValue(d: var Decoder, formIndex: int, path: DocPath): Value

proc decodeNode(d: var Decoder, immutable: bool, formIndex: int,
                path: DocPath): Value =
  takeComments(d, formIndex, path, -1)
  discard d.take(ukRoleHead)
  let head = d.decodeValue(formIndex, path & propertySegment("head"))
  takeComments(d, formIndex, path, 0)
  var meta = initPropTable()
  var props = initPropTable()
  var body = newSeq[Value]()
  # `emitValue` emits every meta key, then every prop key, then the body, so
  # each group's count is already final when the next group starts -- which is
  # what makes these boundary indices agree with the writer's.
  var metaCount, propCount = 0
  while true:
    if d.atEnd: d.fail("unterminated node: expected " & $ukNodeEnd)
    let unit = d.units[d.pos]
    case unit.kind
    of ukRoleMetaKey:
      inc d.pos
      meta[unit.text] = d.decodeValue(
        formIndex, path & propertySegment("meta") & propertySegment(unit.text))
      takeComments(d, formIndex, path, 1 + metaCount)
      inc metaCount
    of ukRolePropKey:
      inc d.pos
      props[unit.text] = d.decodeValue(formIndex, path & propertySegment(unit.text))
      takeComments(d, formIndex, path, 1 + metaCount + propCount)
      inc propCount
    of ukRoleBody:
      inc d.pos
      let bi = body.len
      body.add d.decodeValue(formIndex, path & indexSegment(bi.int64))
      takeComments(d, formIndex, path, 1 + metaCount + propCount + bi)
    of ukNodeEnd:
      inc d.pos
      break
    else:
      d.fail("unexpected " & $unit.kind & " inside a node")
  newNode(head, props, body, meta, immutable)

proc decodeList(d: var Decoder, immutable: bool, formIndex: int,
                path: DocPath): Value =
  takeComments(d, formIndex, path, -1)
  var items = newSeq[Value]()
  while true:
    if d.atEnd: d.fail("unterminated list: expected " & $ukListEnd)
    if d.units[d.pos].kind == ukListEnd:
      inc d.pos
      break
    let i = items.len
    items.add d.decodeValue(formIndex, path & indexSegment(i.int64))
    takeComments(d, formIndex, path, i)
  newList(items, immutable)

proc decodeMap(d: var Decoder, immutable: bool, formIndex: int,
               path: DocPath): Value =
  takeComments(d, formIndex, path, -1)
  var entries = initPropTable()
  var i = 0
  while true:
    if d.atEnd: d.fail("unterminated map: expected " & $ukMapEnd)
    let unit = d.units[d.pos]
    if unit.kind == ukMapEnd:
      inc d.pos
      break
    if unit.kind != ukRoleMapKey:
      d.fail("expected " & $ukRoleMapKey & " inside a map, got " & $unit.kind)
    inc d.pos
    entries[unit.text] = d.decodeValue(formIndex, path & propertySegment(unit.text))
    takeComments(d, formIndex, path, i)
    inc i
  newMap(entries, immutable)

proc decodeHashMap(d: var Decoder, formIndex: int, path: DocPath): Value =
  takeComments(d, formIndex, path, -1)
  var entries = newSeq[HashMapEntry]()
  var i = 0
  while true:
    if d.atEnd: d.fail("unterminated hash map: expected " & $ukHashMapEnd)
    if d.units[d.pos].kind == ukHashMapEnd:
      inc d.pos
      break
    discard d.take(ukRoleHashMapKey)
    let key = d.decodeValue(formIndex, path & indexSegment(i.int64))
    discard d.take(ukRoleHashMapValue)
    let val = d.decodeValue(formIndex, path & indexSegment(i.int64))
    entries.add HashMapEntry(key: key, val: val)
    takeComments(d, formIndex, path, i)
    inc i
  newHashMap(entries)

proc decodeValue(d: var Decoder, formIndex: int, path: DocPath): Value =
  if d.atEnd: d.fail("expected a value, got end of stream")
  let unit = d.units[d.pos]
  inc d.pos
  case unit.kind
  of ukNil: NIL
  of ukVoid: VOID
  of ukBoolTrue: TRUE
  of ukBoolFalse: FALSE
  # Numeric payloads are canonical decimal *text*, and a decoder is also fed
  # model-generated streams, so a payload that is not a number has to become
  # a reportable structural failure rather than an escaping ValueError.
  of ukInt:
    # Validated rather than try/except: `newIntFromDecimal` raises a *Defect*
    # on non-numeric text, which `except CatchableError` does not catch and
    # which callers cannot recover from at all.
    if not isCanonicalIntText(unit.text):
      d.fail($ukInt & " payload is not a canonical integer: " & unit.text.escape)
    newIntFromDecimal(unit.text)
  of ukFloat:
    try: newFloat(parseFloat(unit.text))
    except CatchableError:
      d.fail($ukFloat & " payload is not a canonical float: " & unit.text.escape)
  of ukString: newStr(unit.text)
  of ukBytes: newBytes(unit.text)
  of ukChar:
    if unit.text.len == 0: d.fail("empty " & $ukChar & " payload")
    newChar(unit.text.runeAt(0))
  of ukSymbol: newSym(unit.text)
  of ukNodeStart, ukNodeImmutableStart, ukListStart, ukListImmutableStart,
     ukMapStart, ukMapImmutableStart, ukHashMapStart:
    inc d.depth
    if d.depth > decodeMaxDepth:
      d.fail("nesting depth exceeds " & $decodeMaxDepth)
    defer: dec d.depth
    case unit.kind
    of ukNodeStart: d.decodeNode(false, formIndex, path)
    of ukNodeImmutableStart: d.decodeNode(true, formIndex, path)
    of ukListStart: d.decodeList(false, formIndex, path)
    of ukListImmutableStart: d.decodeList(true, formIndex, path)
    of ukMapStart: d.decodeMap(false, formIndex, path)
    of ukMapImmutableStart: d.decodeMap(true, formIndex, path)
    else: d.decodeHashMap(formIndex, path)
  else:
    d.fail($unit.kind & " is not a value")

proc documentOf*(units: seq[Unit], sourceName = ""): ProgramDocument =
  ## Rebuilds the logical document a unit stream came from. Raises
  ## `DocumentUnitsError` on any stream the grammar does not accept, so an
  ## ill-formed (e.g. model-generated) stream is a reportable structural
  ## failure rather than a partially-built document.
  var d = Decoder(units: units)
  d.doc.sourceName = sourceName
  if not d.atEnd and d.units[0].kind == ukBangLine:
    d.doc.hasBangLine = true
    d.doc.bangLine = d.units[0].text
    d.pos = 1
  takeComments(d, -1, @[], -1)
  var f = 0
  while not d.atEnd:
    discard d.take(ukFormStart)
    d.doc.forms.add d.decodeValue(f, @[])
    discard d.take(ukFormEnd)
    takeComments(d, -1, @[], f)
    inc f
  d.doc

proc parseUnitLines*(text: string): seq[Unit] =
  ## Parses the JSON Lines `toJsonLines` produces. Blank lines are skipped;
  ## anything else that is not a `{"k": ..., "t"?: ...}` object with a known
  ## kind is an error, since silently dropping a line would turn a corrupt
  ## stream into a plausible-looking shorter document.
  let lines: seq[string] = text.splitLines()
  for lineNo in 0 ..< lines.len:
    let stripped = lines[lineNo].strip()
    if stripped.len == 0: continue
    var node: JsonNode
    try:
      node = parseJson(stripped)
    except CatchableError as e:
      raise newException(DocumentUnitsError,
        "line " & $(lineNo + 1) & ": not valid JSON: " & e.msg)
    if node.kind != JObject or not node.hasKey("k"):
      raise newException(DocumentUnitsError,
        "line " & $(lineNo + 1) & ": expected an object with a \"k\" field")
    var kind: UnitKind
    try:
      kind = parseEnum[UnitKind](node["k"].getStr)
    except ValueError:
      raise newException(DocumentUnitsError,
        "line " & $(lineNo + 1) & ": unknown unit kind " & node["k"].getStr.escape)
    result.add u(kind, if node.hasKey("t"): node["t"].getStr else: "")
