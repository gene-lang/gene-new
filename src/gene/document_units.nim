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

import std/[json, tables, unicode]
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
    emitComments(units, idx, formIndex, path, -1)
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
    emitComments(units, idx, formIndex, path, -1)
    for i, it in v.listItems:
      emitValue(units, it, idx, formIndex, path & indexSegment(i.int64))
      emitComments(units, idx, formIndex, path, i)
    units.add u(ukListEnd)
  of vkMap:
    units.add u(if v.mapImmutable: ukMapImmutableStart else: ukMapStart)
    emitComments(units, idx, formIndex, path, -1)
    var i = 0
    for k, val in v.mapEntries:
      units.add u(ukRoleMapKey, k)
      emitValue(units, val, idx, formIndex, path & propertySegment(k))
      emitComments(units, idx, formIndex, path, i)
      inc i
    units.add u(ukMapEnd)
  of vkHashMap:
    units.add u(ukHashMapStart)
    emitComments(units, idx, formIndex, path, -1)
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
