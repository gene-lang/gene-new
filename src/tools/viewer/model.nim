## Terminal-independent structural viewer state.

import std/[options, strutils]
import ../../gene/reader
import ../source_index

type
  ViewFrame* = object
    container*: SyntaxRef
    selectedChild*: int
    firstVisible*: int
    path*: seq[SourcePathSegment]
    logicalRows: seq[SourceRow]
    hasLogicalRows: bool

  ViewerState* = object
    document*: SourceDocument
    frames*: seq[ViewFrame]
    status*: string
    showHelp*: bool
    rawMode*: bool
    serialized*: bool
    showValue*: bool
    valueFirst*: int

proc serdeTag(document: SourceDocument, syntax: SyntaxRef): string =
  if syntax.kind != skNode:
    return
  let children = document.childPage(syntax, 0, 1)
  if children.len == 1 and children[0].label == "head" and
      children[0].syntax.kind == skAtom:
    result = children[0].summary

proc serializedPayload(document: SourceDocument): Option[SyntaxRef] =
  if document.diagnostics.len > 0 or
      serdeTag(document, document.root) != "serde_v1":
    return none(SyntaxRef)
  let children = document.children(document.root)
  if children.len == 2 and children[1].label == "0":
    some(children[1].syntax)
  else:
    none(SyntaxRef)

proc logicalChildren(document: SourceDocument, syntax: SyntaxRef):
    Option[seq[SourceRow]] =
  let tag = serdeTag(document, syntax)
  if tag in ["serde_sym", "serde_float", "serde_range",
             "serde_timezone", "serde_duration"]:
    return some(newSeq[SourceRow]())
  if tag == "serde_set":
    let children = document.children(syntax)
    if children.len < 1:
      return none(seq[SourceRow])
    return some(children[1 .. ^1])
  if tag == "serde_map":
    let children = document.children(syntax)
    if children.len != 3 or children[2].syntax.kind != skList:
      return none(seq[SourceRow])
    let pairs = document.children(children[2].syntax)
    if pairs.len mod 2 != 0:
      return none(seq[SourceRow])
    var entries: seq[SourceRow]
    for index in countup(0, pairs.high, 2):
      let key = pairs[index].syntax
      if key.kind != skAtom or key.startToken >= document.tokens.len or
          document.tokens[key.startToken].kind != tkString:
        return none(seq[SourceRow])
      let name = document.tokens[key.startToken].lexeme
      var value = pairs[index + 1]
      value.label = name
      value.path = @[propertySegment(name)]
      entries.add value
    return some(entries)
  if tag == "serde_data_node":
    let children = document.children(syntax)
    if children.len < 5:
      return none(seq[SourceRow])
    var entries: seq[SourceRow]
    for index, name in ["head", "props", "meta"]:
      var item = children[index + 2]
      item.label = name
      item.path = @[propertySegment(name)]
      entries.add item
    for index in 5 ..< children.len:
      var item = children[index]
      item.label = $(index - 5)
      item.path = @[indexSegment((index - 5).int64)]
      entries.add item
    return some(entries)
  none(seq[SourceRow])

proc viewFrame(document: SourceDocument, syntax: SyntaxRef,
               path: seq[SourcePathSegment], serialized: bool): ViewFrame =
  result = ViewFrame(container: syntax, path: path)
  if serialized:
    let rows = logicalChildren(document, syntax)
    if rows.isSome:
      result.logicalRows = rows.get
      result.hasLogicalRows = true

proc newViewerState*(document: SourceDocument, rawMode = false): ViewerState =
  let payload = if rawMode: none(SyntaxRef) else: serializedPayload(document)
  let root = if payload.isSome: payload.get else: document.root
  ViewerState(document: document, rawMode: rawMode, serialized: payload.isSome,
              frames: @[viewFrame(document, root, @[], payload.isSome)])

proc frame*(state: ViewerState): ViewFrame = state.frames[^1]

proc rows*(state: ViewerState): seq[SourceRow] =
  let current = state.frames[^1]
  if current.hasLogicalRows: current.logicalRows
  else: state.document.children(current.container)

proc rowCount*(state: ViewerState): int =
  let current = state.frames[^1]
  if current.hasLogicalRows: current.logicalRows.len
  else: state.document.childCount(current.container)

proc rowPage*(state: ViewerState, first, count: int): seq[SourceRow] =
  let current = state.frames[^1]
  if current.hasLogicalRows:
    let start = min(max(first, 0), current.logicalRows.len)
    let finish = min(start + max(count, 0), current.logicalRows.len)
    current.logicalRows[start ..< finish]
  else:
    state.document.childPage(current.container, first, count)

proc rowSummary*(state: ViewerState, item: SourceRow): string =
  if not state.serialized or not item.syntax.isContainer:
    return item.summary
  let tag = serdeTag(state.document, item.syntax)
  case tag
  of "serde_set": "Set · " & $max(0, state.document.childCount(item.syntax) - 1) & " items"
  of "serde_map":
    let children = state.document.children(item.syntax)
    if children.len == 3 and children[2].syntax.kind == skList:
      "Map · " & $(state.document.childCount(children[2].syntax) div 2) & " entries"
    else: item.summary
  of "serde_data_node":
    "Node · " & $max(0, state.document.childCount(item.syntax) - 5) & " body items"
  of "serde_sym", "serde_float", "serde_range", "serde_timezone",
     "serde_duration":
    let children = state.document.children(item.syntax)
    var values: seq[string]
    for index in 1 ..< children.len:
      values.add children[index].summary
    let kind = case tag
      of "serde_sym": "Symbol"
      of "serde_float": "Float"
      of "serde_range": "Range"
      of "serde_timezone": "Timezone"
      else: "Duration"
    kind & " · " & values.join(" ")
  else:
    case item.syntax.kind
    of skList: "List · " & $state.document.childCount(item.syntax) & " items"
    of skPropMap: "Map · " & $state.document.childCount(item.syntax) & " fields"
    of skGeneralMap: "Map · " & $state.document.childCount(item.syntax) & " entries"
    else: item.summary

proc browsable*(state: ViewerState, syntax: SyntaxRef): bool =
  if not syntax.isContainer:
    return false
  if state.serialized and serdeTag(state.document, syntax) in
      ["serde_sym", "serde_float", "serde_range", "serde_timezone",
       "serde_duration"]:
    return false
  true

proc selectedRow*(state: ViewerState): Option[SourceRow] =
  let count = state.rowCount()
  if count == 0:
    return none(SourceRow)
  let index = min(max(state.frames[^1].selectedChild, 0), count - 1)
  let item = state.rowPage(index, 1)
  if item.len == 0: none(SourceRow) else: some(item[0])

proc selectedSyntax*(state: ViewerState): SyntaxRef =
  let selected = state.selectedRow()
  if selected.isSome: selected.get.syntax else: state.frames[^1].container

proc selectedBounds(state: ViewerState): tuple[start, finish: int] =
  let syntax = state.selectedSyntax()
  let start = min(max(syntax.span.startByte, 0), state.document.source.len)
  let finish = min(max(syntax.span.endByte, start), state.document.source.len)
  (start: start, finish: finish)

proc selectedByteLength*(state: ViewerState): int =
  let bounds = state.selectedBounds()
  bounds.finish - bounds.start

proc selectedExcerpt*(state: ViewerState, maxBytes = 256): string =
  let bounds = state.selectedBounds()
  var finish = min(bounds.finish, bounds.start + max(maxBytes, 0))
  if finish < bounds.finish:
    while finish > bounds.start and
        (ord(state.document.source[finish]) and 0xC0) == 0x80:
      dec finish
  state.document.source[bounds.start ..< finish]

proc selectedRaw*(state: ViewerState): string =
  let bounds = state.selectedBounds()
  state.document.source[bounds.start ..< bounds.finish]

proc currentPath*(state: ViewerState): seq[SourcePathSegment] =
  result = state.frames[^1].path
  let selected = state.selectedRow()
  if selected.isSome:
    result.add selected.get.path

proc normalize*(state: var ViewerState, viewportRows: int) =
  if state.frames.len == 0:
    state.frames = @[ViewFrame(container: state.document.root)]
  let count = state.rowCount()
  if count == 0:
    state.frames[^1].selectedChild = 0
    state.frames[^1].firstVisible = 0
    return
  state.frames[^1].selectedChild =
    min(max(state.frames[^1].selectedChild, 0), count - 1)
  let visible = max(viewportRows, 1)
  if state.frames[^1].selectedChild < state.frames[^1].firstVisible:
    state.frames[^1].firstVisible = state.frames[^1].selectedChild
  elif state.frames[^1].selectedChild >=
      state.frames[^1].firstVisible + visible:
    state.frames[^1].firstVisible =
      state.frames[^1].selectedChild - visible + 1
  state.frames[^1].firstVisible =
    min(max(state.frames[^1].firstVisible, 0), max(0, count - visible))

proc move*(state: var ViewerState, delta, viewportRows: int) =
  state.frames[^1].selectedChild += delta
  state.normalize(viewportRows)

proc page*(state: var ViewerState, delta, viewportRows: int) =
  state.move(delta * max(viewportRows, 1), viewportRows)

proc first*(state: var ViewerState, viewportRows: int) =
  state.frames[^1].selectedChild = 0
  state.normalize(viewportRows)

proc last*(state: var ViewerState, viewportRows: int) =
  state.frames[^1].selectedChild = max(0, state.rowCount() - 1)
  state.normalize(viewportRows)

proc enter*(state: var ViewerState): bool =
  let selected = state.selectedRow()
  if selected.isNone or not state.browsable(selected.get.syntax):
    return false
  var path = state.frames[^1].path
  path.add selected.get.path
  state.frames.add viewFrame(state.document, selected.get.syntax, path,
                             state.serialized)
  true

proc leave*(state: var ViewerState): bool =
  if state.frames.len <= 1:
    return false
  state.frames.setLen(state.frames.len - 1)
  true

proc root*(state: var ViewerState) =
  state.frames.setLen(1)

proc segmentsEqual(a, b: openArray[SourcePathSegment]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].kind != b[i].kind:
      return false
    case a[i].kind
    of spsProperty:
      if a[i].name != b[i].name: return false
    of spsIndex:
      if a[i].index != b[i].index: return false
  true

proc selectPath*(state: var ViewerState,
                 requested: openArray[SourcePathSegment],
                 viewportRows = 20): bool =
  state.root()
  var at = 0
  while at < requested.len:
    let items = state.rows()
    var indexedCount = 0
    if state.frames[^1].container.kind in
        {skNode, skList, skPropMap, skSequence}:
      for item in items:
        if item.path.len == 1 and item.path[0].kind == spsIndex:
          inc indexedCount
    var found = -1
    var consumed = 0
    for i, item in items:
      if item.path.len == 0 or at + item.path.len > requested.len:
        continue
      var candidate = requested[at ..< at + item.path.len]
      if item.path.len == 1 and item.path[0].kind == spsIndex and
          candidate[0].kind == spsIndex and candidate[0].index < 0 and
          indexedCount > 0:
        candidate[0] = indexSegment(indexedCount.int64 + candidate[0].index)
      if segmentsEqual(item.path, candidate):
        found = i
        consumed = item.path.len
        break
    if found < 0:
      state.normalize(viewportRows)
      return false
    state.frames[^1].selectedChild = found
    state.normalize(viewportRows)
    at += consumed
    if at < requested.len and not state.enter():
      return false
  true

proc reload*(state: var ViewerState, document: SourceDocument,
             viewportRows = 20) =
  let anchor = state.currentPath()
  state.document = document
  let payload = if state.rawMode: none(SyntaxRef)
                else: serializedPayload(document)
  state.serialized = payload.isSome
  let root = if payload.isSome: payload.get else: document.root
  state.frames = @[viewFrame(document, root, @[], state.serialized)]
  state.valueFirst = 0
  if not state.selectPath(anchor, viewportRows):
    state.status = "reloaded; nearest surviving parent selected"
  else:
    state.status = "reloaded"

proc selectOffset*(state: var ViewerState, offset: int,
                   viewportRows = 20): bool =
  state.root()
  while true:
    let items = state.rows()
    var best = -1
    var bestWidth = high(int)
    for i, item in items:
      if item.syntax.span.startByte <= offset and offset < item.syntax.span.endByte:
        let width = item.syntax.span.endByte - item.syntax.span.startByte
        if width < bestWidth:
          best = i
          bestWidth = width
    if best < 0:
      return state.frames.len > 1
    state.frames[^1].selectedChild = best
    state.normalize(viewportRows)
    if not state.browsable(items[best].syntax) or not state.enter():
      return true
