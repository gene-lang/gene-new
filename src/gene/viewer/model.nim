## Terminal-independent structural viewer state.

import std/options
import ../source_index

type
  ViewFrame* = object
    container*: SyntaxRef
    selectedChild*: int
    firstVisible*: int
    path*: seq[SourcePathSegment]

  ViewerState* = object
    document*: SourceDocument
    frames*: seq[ViewFrame]
    status*: string
    showHelp*: bool

proc newViewerState*(document: SourceDocument): ViewerState =
  ViewerState(document: document,
              frames: @[ViewFrame(container: document.root)])

proc frame*(state: ViewerState): ViewFrame = state.frames[^1]

proc rows*(state: ViewerState): seq[SourceRow] =
  state.document.children(state.frames[^1].container)

proc rowCount*(state: ViewerState): int =
  state.document.childCount(state.frames[^1].container)

proc rowPage*(state: ViewerState, first, count: int): seq[SourceRow] =
  state.document.childPage(state.frames[^1].container, first, count)

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
  if selected.isNone or not selected.get.syntax.isContainer:
    return false
  var path = state.frames[^1].path
  path.add selected.get.path
  state.frames.add ViewFrame(container: selected.get.syntax, path: path)
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
  state.frames = @[ViewFrame(container: document.root)]
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
    if not items[best].syntax.isContainer or not state.enter():
      return true
