## Narrow, owned wrapper around the pinned libvterm terminal state machine.
##
## Child escape bytes terminate here. Callers inspect attributed cells and
## drain emulator-generated replies; no raw child control sequence is ever
## written to the outer terminal.

import std/[os, strutils, unicode]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  const
    moduleDir = currentSourcePath.parentDir
    vtermRoot = moduleDir / "../../vendor/libvterm"

  {.passC: "-std=c99 -I" & vtermRoot / "include" &
           " -I" & vtermRoot / "src" & " -I" & moduleDir.}
  {.compile: vtermRoot / "src/encoding.c".}
  {.compile: vtermRoot / "src/keyboard.c".}
  {.compile: vtermRoot / "src/mouse.c".}
  {.compile: vtermRoot / "src/parser.c".}
  {.compile: vtermRoot / "src/pen.c".}
  {.compile: vtermRoot / "src/screen.c".}
  {.compile: vtermRoot / "src/state.c".}
  {.compile: vtermRoot / "src/unicode.c".}
  {.compile: vtermRoot / "src/vterm.c".}
  {.compile: moduleDir / "vterm_bridge.c".}

  type
    CVTerm {.importc: "GeneVTerm", header: "vterm_bridge.h".} = object
    CVTermCell {.importc: "GeneVTermCell", header: "vterm_bridge.h",
                 bycopy.} = object
      chars: array[6, uint32]
      width: uint8
      continuation: uint8
      bold: uint8
      dim: uint8
      underline: uint8
      italic: uint8
      blink: uint8
      reverse: uint8
      conceal: uint8
      strike: uint8
      fgDefault {.importc: "fg_default".}: uint8
      fgRed {.importc: "fg_red".}: uint8
      fgGreen {.importc: "fg_green".}: uint8
      fgBlue {.importc: "fg_blue".}: uint8
      bgDefault {.importc: "bg_default".}: uint8
      bgRed {.importc: "bg_red".}: uint8
      bgGreen {.importc: "bg_green".}: uint8
      bgBlue {.importc: "bg_blue".}: uint8

  proc cNew(rows, cols, scrollbackLines: cint): ptr CVTerm
    {.importc: "gene_vterm_new", header: "vterm_bridge.h".}
  proc cFree(term: ptr CVTerm)
    {.importc: "gene_vterm_free", header: "vterm_bridge.h".}
  proc cFeed(term: ptr CVTerm, bytes: pointer, len: csize_t)
    {.importc: "gene_vterm_feed", header: "vterm_bridge.h".}
  proc cResize(term: ptr CVTerm, rows, cols: cint)
    {.importc: "gene_vterm_resize", header: "vterm_bridge.h".}
  proc cOutputRead(term: ptr CVTerm, buffer: pointer, len: csize_t): csize_t
    {.importc: "gene_vterm_output_read", header: "vterm_bridge.h".}
  proc cRows(term: ptr CVTerm): cint
    {.importc: "gene_vterm_rows", header: "vterm_bridge.h".}
  proc cCols(term: ptr CVTerm): cint
    {.importc: "gene_vterm_cols", header: "vterm_bridge.h".}
  proc cGeneration(term: ptr CVTerm): uint64
    {.importc: "gene_vterm_generation", header: "vterm_bridge.h".}
  proc cCursorRow(term: ptr CVTerm): cint
    {.importc: "gene_vterm_cursor_row", header: "vterm_bridge.h".}
  proc cCursorCol(term: ptr CVTerm): cint
    {.importc: "gene_vterm_cursor_col", header: "vterm_bridge.h".}
  proc cCursorVisible(term: ptr CVTerm): cint
    {.importc: "gene_vterm_cursor_visible", header: "vterm_bridge.h".}
  proc cAltscreen(term: ptr CVTerm): cint
    {.importc: "gene_vterm_altscreen", header: "vterm_bridge.h".}
  proc cMouseMode(term: ptr CVTerm): cint
    {.importc: "gene_vterm_mouse_mode", header: "vterm_bridge.h".}
  proc cFocusReporting(term: ptr CVTerm): cint
    {.importc: "gene_vterm_focus_reporting", header: "vterm_bridge.h".}
  proc cTitle(term: ptr CVTerm): cstring
    {.importc: "gene_vterm_title", header: "vterm_bridge.h".}
  proc cWorkingDirectoryUri(term: ptr CVTerm): cstring
    {.importc: "gene_vterm_working_directory_uri", header: "vterm_bridge.h".}
  proc cGetCell(term: ptr CVTerm, row, col: cint,
                cell: ptr CVTermCell): cint
    {.importc: "gene_vterm_get_cell", header: "vterm_bridge.h".}
  proc cScrollbackCount(term: ptr CVTerm): cint
    {.importc: "gene_vterm_scrollback_count", header: "vterm_bridge.h".}
  proc cScrollbackCols(term: ptr CVTerm, line: cint): cint
    {.importc: "gene_vterm_scrollback_cols", header: "vterm_bridge.h".}
  proc cGetScrollbackCell(term: ptr CVTerm, line, col: cint,
                          cell: ptr CVTermCell): cint
    {.importc: "gene_vterm_get_scrollback_cell", header: "vterm_bridge.h".}
  proc cScrollbackDropped(term: ptr CVTerm): uint64
    {.importc: "gene_vterm_scrollback_dropped", header: "vterm_bridge.h".}
  proc cKey(term: ptr CVTerm, key, modifiers: cint)
    {.importc: "gene_vterm_key", header: "vterm_bridge.h".}
  proc cUnichar(term: ptr CVTerm, codepoint: uint32, modifiers: cint)
    {.importc: "gene_vterm_unichar", header: "vterm_bridge.h".}
  proc cPasteStart(term: ptr CVTerm)
    {.importc: "gene_vterm_paste_start", header: "vterm_bridge.h".}
  proc cPasteEnd(term: ptr CVTerm)
    {.importc: "gene_vterm_paste_end", header: "vterm_bridge.h".}
  proc cMouseMove(term: ptr CVTerm, row, col, modifiers: cint)
    {.importc: "gene_vterm_mouse_move", header: "vterm_bridge.h".}
  proc cMouseButton(term: ptr CVTerm, button, pressed, modifiers: cint)
    {.importc: "gene_vterm_mouse_button", header: "vterm_bridge.h".}
  proc cFocusIn(term: ptr CVTerm)
    {.importc: "gene_vterm_focus_in", header: "vterm_bridge.h".}
  proc cFocusOut(term: ptr CVTerm)
    {.importc: "gene_vterm_focus_out", header: "vterm_bridge.h".}

type
  TerminalKey* = enum
    vtkNone = 0,
    vtkEnter,
    vtkTab,
    vtkBackspace,
    vtkEscape,
    vtkUp,
    vtkDown,
    vtkLeft,
    vtkRight,
    vtkInsert,
    vtkDelete,
    vtkHome,
    vtkEnd,
    vtkPageUp,
    vtkPageDown,
    vtkF1 = 257,
    vtkF2,
    vtkF3,
    vtkF4,
    vtkF5,
    vtkF6,
    vtkF7,
    vtkF8,
    vtkF9,
    vtkF10,
    vtkF11,
    vtkF12

  TerminalModifiers* = distinct int

  TerminalColor* = object
    isDefault*: bool
    red*, green*, blue*: uint8

  TerminalCell* = object
    text*: string
    width*: int
    continuation*: bool
    bold*: bool
    dim*: bool
    underline*: int
    italic*, blink*, reverse*, conceal*, strike*: bool
    foreground*, background*: TerminalColor

  TerminalSnapshot* = object
    generation*: uint64
    rows*, cols*: int
    cursorRow*, cursorCol*: int
    cursorVisible*: bool
    altscreen*: bool
    mouseMode*: int
    focusReporting*: bool
    title*: string
    workingDirectoryUri*: string
    scrollbackLines*: int
    scrollbackDropped*: uint64

  VTermEmulatorObj = object
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      handle: ptr CVTerm
    scrollbackLimit: int
  VTermEmulator* = ref VTermEmulatorObj

const
  maxTerminalRows* = 512
  maxTerminalCols* = 1024
  maxTerminalGridCells* = 262_144
  maxTerminalScrollbackLines* = 10_000
  maxTerminalScrollbackCells* = 2_000_000
  terminalModNone* = TerminalModifiers(0)
  terminalModShift* = TerminalModifiers(1)
  terminalModAlt* = TerminalModifiers(2)
  terminalModCtrl* = TerminalModifiers(4)

proc `or`*(a, b: TerminalModifiers): TerminalModifiers =
  TerminalModifiers(int(a) or int(b))

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc `=destroy`(term: var VTermEmulatorObj) =
    if term.handle != nil:
      cFree(term.handle)
      term.handle = nil

proc openVTerm*(rows, cols: int, scrollbackLines = 2000): VTermEmulator =
  if rows <= 0 or cols <= 0:
    raise newException(ValueError, "terminal dimensions must be positive")
  if scrollbackLines < 0:
    raise newException(ValueError, "terminal scrollback must be non-negative")
  if rows > maxTerminalRows or cols > maxTerminalCols or
      rows * cols > maxTerminalGridCells:
    raise newException(ValueError, "terminal dimensions exceed the grid limit")
  if scrollbackLines > maxTerminalScrollbackLines or
      scrollbackLines * cols > maxTerminalScrollbackCells:
    raise newException(ValueError, "terminal scrollback exceeds its cell limit")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let handle = cNew(cint(rows), cint(cols), cint(scrollbackLines))
    if handle == nil:
      raise newException(IOError, "could not allocate terminal emulator")
    new(result)
    result.handle = handle
    result.scrollbackLimit = scrollbackLines
  else:
    raise newException(IOError, "terminal emulation is unavailable")

proc close*(term: VTermEmulator) =
  if term == nil:
    return
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if term.handle != nil:
      cFree(term.handle)
      term.handle = nil

proc requireOpen(term: VTermEmulator) =
  if term == nil:
    raise newException(IOError, "terminal emulator is nil")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if term.handle == nil:
      raise newException(IOError, "terminal emulator is closed")

proc feed*(term: VTermEmulator, bytes: string) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if bytes.len > 0:
      cFeed(term.handle, unsafeAddr bytes[0], csize_t(bytes.len))

proc resize*(term: VTermEmulator, rows, cols: int) =
  term.requireOpen()
  if rows <= 0 or cols <= 0:
    raise newException(ValueError, "terminal dimensions must be positive")
  if rows > maxTerminalRows or cols > maxTerminalCols or
      rows * cols > maxTerminalGridCells:
    raise newException(ValueError, "terminal dimensions exceed the grid limit")
  if term.scrollbackLimit * cols > maxTerminalScrollbackCells:
    raise newException(ValueError, "terminal resize exceeds the scrollback cell limit")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cResize(term.handle, cint(rows), cint(cols))

proc drainOutput*(term: VTermEmulator): string =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var chunk: array[4096, char]
    while true:
      let count = int(cOutputRead(term.handle, addr chunk[0],
                                  csize_t(chunk.len)))
      if count <= 0:
        break
      let oldLen = result.len
      result.setLen(oldLen + count)
      copyMem(addr result[oldLen], addr chunk[0], count)

proc snapshot*(term: VTermEmulator): TerminalSnapshot =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    result = TerminalSnapshot(
      generation: cGeneration(term.handle),
      rows: int(cRows(term.handle)),
      cols: int(cCols(term.handle)),
      cursorRow: int(cCursorRow(term.handle)),
      cursorCol: int(cCursorCol(term.handle)),
      cursorVisible: cCursorVisible(term.handle) != 0,
      altscreen: cAltscreen(term.handle) != 0,
      mouseMode: int(cMouseMode(term.handle)),
      focusReporting: cFocusReporting(term.handle) != 0,
      title: $cTitle(term.handle),
      workingDirectoryUri: $cWorkingDirectoryUri(term.handle),
      scrollbackLines: int(cScrollbackCount(term.handle)),
      scrollbackDropped: cScrollbackDropped(term.handle))

proc flattenCell(cell: CVTermCell): TerminalCell =
  for codepoint in cell.chars:
    if codepoint == 0:
      break
    if codepoint > 0x10FFFF'u32:
      continue
    result.text.add Rune(codepoint.int32).toUTF8
  result.width = int(cell.width)
  result.continuation = cell.continuation != 0
  result.bold = cell.bold != 0
  result.dim = cell.dim != 0
  result.underline = int(cell.underline)
  result.italic = cell.italic != 0
  result.blink = cell.blink != 0
  result.reverse = cell.reverse != 0
  result.conceal = cell.conceal != 0
  result.strike = cell.strike != 0
  result.foreground = TerminalColor(
    isDefault: cell.fgDefault != 0,
    red: cell.fgRed, green: cell.fgGreen, blue: cell.fgBlue)
  result.background = TerminalColor(
    isDefault: cell.bgDefault != 0,
    red: cell.bgRed, green: cell.bgGreen, blue: cell.bgBlue)

proc cell*(term: VTermEmulator, row, col: int): TerminalCell =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var native: CVTermCell
    if cGetCell(term.handle, cint(row), cint(col), addr native) == 0:
      raise newException(IndexDefect, "terminal cell is out of bounds")
    result = flattenCell(native)

proc scrollbackCell*(term: VTermEmulator, line, col: int): TerminalCell =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var native: CVTermCell
    if cGetScrollbackCell(term.handle, cint(line), cint(col), addr native) == 0:
      raise newException(IndexDefect, "terminal scrollback cell is out of bounds")
    result = flattenCell(native)

proc scrollbackCols*(term: VTermEmulator, line: int): int =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    result = int(cScrollbackCols(term.handle, cint(line)))

proc screenText*(term: VTermEmulator): string =
  let state = term.snapshot()
  var lines = newSeq[string](state.rows)
  for row in 0 ..< state.rows:
    for col in 0 ..< state.cols:
      let item = term.cell(row, col)
      if not item.continuation:
        lines[row].add item.text
    lines[row] = lines[row].strip(leading = false, trailing = true)
  lines.join("\n")

proc sendKey*(term: VTermEmulator, key: TerminalKey,
              modifiers = terminalModNone) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cKey(term.handle, cint(ord(key)), cint(int(modifiers)))

proc sendRune*(term: VTermEmulator, codepoint: Rune,
               modifiers = terminalModNone) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cUnichar(term.handle, uint32(codepoint.int32), cint(int(modifiers)))

proc startPaste*(term: VTermEmulator) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cPasteStart(term.handle)

proc endPaste*(term: VTermEmulator) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cPasteEnd(term.handle)

proc sendMouseMove*(term: VTermEmulator, row, col: int,
                    modifiers = terminalModNone) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cMouseMove(term.handle, cint(row), cint(col), cint(int(modifiers)))

proc sendMouseButton*(term: VTermEmulator, button: int, pressed: bool,
                      modifiers = terminalModNone) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cMouseButton(term.handle, cint(button), cint(ord(pressed)),
                 cint(int(modifiers)))

proc focusIn*(term: VTermEmulator) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cFocusIn(term.handle)

proc focusOut*(term: VTermEmulator) =
  term.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cFocusOut(term.handle)
