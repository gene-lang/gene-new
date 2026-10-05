## Native curses frontend for `gene view`.

import std/[options, os, unicode]
import ../source_index
import ../../gene/ext/term/tui
import ./[editor, model]

type
  ViewerOptions* = object
    path*: string
    readonly*: bool
    editor*: string
    initialPath*: string
    line*: int
    col*: int
    noColor*: bool
    rawMode*: bool

proc kindName(kind: SyntaxKind): string =
  case kind
  of skAtom: "Atom"
  of skNode: "Node"
  of skList: "List"
  of skPropMap: "Map"
  of skGeneralMap: "GeneralMap"
  of skQuasiquote: "Quasiquote"
  of skUnquote: "Unquote"
  of skInterpolation: "Interpolation"
  of skComment: "Comment"
  of skSequence: "Sequence"
  of skError: "Error"

proc fitLabel(label: string, width: int): string =
  fitCells(label, width)

proc renderHelp(terminal: Terminal, bodyFirst, bodyRows: int) =
  let help = [
    "Navigation",
    "  Up/Down, j/k       previous/next sibling",
    "  PageUp/PageDown    move one viewport",
    "  Home/End           first/last sibling",
    "  Right/Enter, l     enter container",
    "  Left/Backspace, h  return to parent",
    "  g                   document root",
    "",
    "File",
    "  v                   show full selected value",
    "  In value view: j/k, PgUp/PgDn scroll; v/Esc return",
    "  e                   external editor at selection",
    "  r, F5               reload and restore Gene path",
    "  q, F10              quit",
    "  ?, F1               close help"
  ]
  for i in 0 ..< min(bodyRows, help.len):
    terminal.drawLine(bodyFirst + i, help[i])

proc wrappedPage(value: string, width, first, count: int):
    tuple[lines: seq[string], total: int] =
  let columns = max(width, 1)
  var line = ""
  var cells = 0
  var index = 0
  template finishLine() =
    if index >= first and index < first + count:
      result.lines.add line
    inc index
    line.setLen(0)
    cells = 0
  for rune in value.runes:
    if rune.int32 == 10:
      finishLine()
      continue
    let glyph = if rune.int32 == 9: "  " else: rune.toUTF8
    let size = max(1, textWidth(glyph))
    if cells > 0 and cells + size > columns:
      finishLine()
    line.add glyph
    cells += size
  finishLine()
  result.total = index

proc listViewport(sizeRows: int, state: ViewerState): int =
  let previewRows = if state.serialized and sizeRows >= 12 and not state.showHelp and
      not state.showValue: 4 else: 0
  max(1, sizeRows - 3 - previewRows)

proc render(terminal: Terminal, state: var ViewerState, options: ViewerOptions) =
  let size = terminal.dimensions()
  let bodyFirst = 2
  let bodyRows = listViewport(size.rows, state)
  state.normalize(bodyRows)
  let count = state.rowCount()
  let selected = state.selectedRow()
  var selectedPath = state.frame().path
  if selected.isSome:
    selectedPath.add selected.get.path
  terminal.clear()
  let validity = if state.document.diagnostics.len == 0: "valid" else: "invalid"
  let mode = if state.serialized: "Serialized data" else: "Source"
  terminal.drawLine(0, mode & " · " & $state.document.source.len &
    " bytes · " & validity & " · " & extractFilename(state.document.path))
  terminal.drawLine(1, "Path: " & pathText(selectedPath))

  var valueTotal = 0
  if state.showHelp:
    terminal.renderHelp(bodyFirst, bodyRows)
  elif state.showValue:
    let raw = state.selectedRaw()
    let page = wrappedPage(raw, size.cols, state.valueFirst, bodyRows)
    valueTotal = page.total
    state.valueFirst = min(max(state.valueFirst, 0),
                           max(0, page.total - bodyRows))
    let shown = if state.valueFirst == 0: page else:
      wrappedPage(raw, size.cols, state.valueFirst, bodyRows)
    for index, line in shown.lines:
      terminal.drawLine(bodyFirst + index, line)
  else:
    if count == 0 and state.document.diagnostics.len > 0:
      let diagnostic = state.document.diagnostics[0]
      terminal.drawLine(bodyFirst, "read error at " & $diagnostic.line & ":" &
        $diagnostic.col & ": " & diagnostic.message)
    elif count == 0:
      terminal.drawLine(bodyFirst, "(no children)")
    else:
      let first = state.frame().firstVisible
      let items = state.rowPage(first, bodyRows)
      for offset, item in items:
        let index = first + offset
        let marker = if index == state.frame().selectedChild: "> " else: "  "
        let container = if state.browsable(item.syntax): "▸ " else: "  "
        terminal.drawLine(bodyFirst + index - first,
          marker & fitLabel(item.label, 18) & container & state.rowSummary(item))
    if state.serialized and size.rows >= 12:
      let preview = wrappedPage(state.selectedExcerpt(max(512, size.cols * 3)),
                                size.cols, 0, 2)
      terminal.drawLine(bodyFirst + bodyRows,
        "Selected value · " & $state.selectedByteLength() &
        " bytes · v full view")
      for index, line in preview.lines:
        terminal.drawLine(bodyFirst + bodyRows + 1 + index, line)

  let syntax = if selected.isSome: selected.get.syntax else: state.frame().container
  let location = state.document.lineCol(syntax)
  let position = if count == 0: "0/0" else: $(state.frame().selectedChild + 1) & "/" & $count
  var status = kindName(syntax.kind) & " · line " & $location.line & ":" &
    $location.col & " · " & position
  if state.status.len > 0:
    status.add " · " & state.status
  else:
    status.add " · e editor  r reload  ? help  q quit"
  if options.readonly:
    status.add " · readonly"
  if state.showValue:
    status = "Value · line " & $(state.valueFirst + 1) & "/" & $valueTotal &
      " · j/k scroll  v return  q quit"
  terminal.drawLine(size.rows - 1, status)
  terminal.present()

proc reloadDocument(state: var ViewerState, options: ViewerOptions,
                    viewportRows: int) =
  try:
    state.reload(loadSourceDocument(options.path), viewportRows)
  except CatchableError as error:
    state.status = "reload failed: " & error.msg

proc editSelection(terminal: var Terminal, state: var ViewerState,
                   options: ViewerOptions, viewportRows: int) =
  if options.readonly:
    state.status = "readonly: editor launch disabled"
    return
  let syntax = state.selectedSyntax()
  let location = state.document.lineCol(syntax)
  try:
    let command = resolveEditor(options.editor)
    terminal.suspend()
    var exitCode = -1
    try:
      exitCode = launchEditor(command, state.document.path,
                              location.line, location.col)
    finally:
      terminal.resume()
    state.reloadDocument(options, viewportRows)
    if exitCode != 0:
      state.status = "editor exited with status " & $exitCode
  except CatchableError as error:
    terminal.resume()
    state.status = "editor failed: " & error.msg

proc validateFile(path: string) =
  if not fileExists(path):
    raise newException(IOError, "file not found: " & path)
  if getFileInfo(path, followSymlink = true).kind != pcFile:
    raise newException(IOError, "gene view requires a regular file: " & path)

proc runViewer*(options: ViewerOptions): int =
  validateFile(options.path)
  var state = newViewerState(loadSourceDocument(options.path), options.rawMode)
  if options.initialPath.len > 0:
    let requested = parseSourcePath(options.initialPath)
    if not state.selectPath(requested):
      state.status = "path not found: " & options.initialPath
  elif options.line > 0:
    let line0 = min(max(options.line - 1, 0), state.document.lineStarts.high)
    let offset = state.document.lineStarts[line0] + max(options.col - 1, 0)
    if not state.selectOffset(offset):
      state.status = "no syntax at requested location"

  var terminal = openTerminal()
  try:
    var running = true
    while running:
      let size = terminal.dimensions()
      let viewportRows = listViewport(size.rows, state)
      terminal.render(state, options)
      let event = terminal.readEvent()
      state.status.setLen(0)
      if state.showValue:
        case event.kind
        of tekUp, tekScrollUp: state.valueFirst = max(0, state.valueFirst - 1)
        of tekDown, tekScrollDown: inc state.valueFirst
        of tekPageUp: state.valueFirst = max(0, state.valueFirst - viewportRows)
        of tekPageDown: state.valueFirst += viewportRows
        of tekHome: state.valueFirst = 0
        of tekEnd: state.valueFirst = high(int) div 2
        of tekLeft, tekBackspace, tekEscape: state.showValue = false
        of tekQuit, tekEof: running = false
        of tekText:
          case event.text
          of "q": running = false
          of "v", "h": state.showValue = false
          of "j": inc state.valueFirst
          of "k": state.valueFirst = max(0, state.valueFirst - 1)
          of "g": state.valueFirst = 0
          else: discard
        else: discard
        continue
      case event.kind
      of tekUp: state.move(-1, viewportRows)
      of tekDown: state.move(1, viewportRows)
      of tekPageUp: state.page(-1, viewportRows)
      of tekPageDown: state.page(1, viewportRows)
      of tekScrollUp: state.move(-3, viewportRows)
      of tekScrollDown: state.move(3, viewportRows)
      of tekHome: state.first(viewportRows)
      of tekEnd: state.last(viewportRows)
      of tekEnter, tekRight:
        if not state.enter(): terminal.ring()
      of tekLeft, tekBackspace:
        if not state.leave(): terminal.ring()
      of tekResize: state.normalize(viewportRows)
      of tekHelp: state.showHelp = not state.showHelp
      of tekReload: state.reloadDocument(options, viewportRows)
      of tekQuit: running = false
      of tekEscape:
        if state.showHelp: state.showHelp = false
      of tekText:
        case event.text
        of "q": running = false
        of "j": state.move(1, viewportRows)
        of "k": state.move(-1, viewportRows)
        of "l":
          if not state.enter(): terminal.ring()
        of "h":
          if not state.leave(): terminal.ring()
        of "g": state.root()
        of "r": state.reloadDocument(options, viewportRows)
        of "e": terminal.editSelection(state, options, viewportRows)
        of "v":
          state.showValue = true
          state.valueFirst = 0
        of "?": state.showHelp = not state.showHelp
        of "i": state.status = "inline editing is deferred; use e"
        of "/": state.status = "search is deferred"
        else: terminal.ring()
      of tekEof: running = false
      else: discard
  finally:
    terminal.close()
