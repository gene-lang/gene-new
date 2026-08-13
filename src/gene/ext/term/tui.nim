## Small owned ncurses terminal adapter shared by native CLI frontends.

import std/[strutils, unicode]

type
  TuiEventKind* = enum
    tekUnknown, tekText, tekEnter, tekEscape, tekBackspace, tekDelete, tekEof,
    tekLeft, tekRight, tekUp, tekDown, tekHome, tekEnd,
    tekPageUp, tekPageDown, tekResize, tekScrollUp, tekScrollDown,
    tekHelp, tekReload, tekQuit

  TuiEvent* = object
    kind*: TuiEventKind
    text*: string

  TuiMouseEvent* = object
    direction*: int
    row*, col*: int
    shift*, alt*, ctrl*: bool

  Terminal* = object
    opened*: bool

proc mouseScrollFromEscape*(sequence: string): int =
  ## SGR mouse reports use button 64/65 for wheel up/down. This is the fallback
  ## on ncurses mouse v1, which cannot represent the fifth mouse button.
  if sequence.startsWith("[<64;") and sequence.endsWith("M"):
    1
  elif sequence.startsWith("[<65;") and sequence.endsWith("M"):
    -1
  else:
    0

proc mouseEventFromEscape*(sequence: string): TuiMouseEvent =
  ## Parse one SGR mouse report without executing or forwarding it. Coordinates
  ## become zero-based cells; modifier bits follow the xterm protocol.
  if not sequence.startsWith("[<") or
      (not sequence.endsWith("M") and not sequence.endsWith("m")):
    return
  let fields = sequence[2 .. ^2].split(';')
  if fields.len != 3:
    return
  try:
    let code = parseInt(fields[0])
    result.col = max(0, parseInt(fields[1]) - 1)
    result.row = max(0, parseInt(fields[2]) - 1)
    result.shift = (code and 4) != 0
    result.alt = (code and 8) != 0
    result.ctrl = (code and 16) != 0
    let button = code and 0xC3
    if button == 64:
      result.direction = 1
    elif button == 65:
      result.direction = -1
  except ValueError:
    result = TuiMouseEvent()

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  {.passL: "-lncurses".}
  import std/posix

  type Window = pointer

  proc initscr(): Window {.importc, header: "<ncurses.h>".}
  proc endwin(): cint {.importc, header: "<ncurses.h>".}
  proc cbreak(): cint {.importc, header: "<ncurses.h>".}
  proc noecho(): cint {.importc, header: "<ncurses.h>".}
  proc keypad(win: Window, enabled: cint): cint {.importc, header: "<ncurses.h>".}
  proc curs_set(visibility: cint): cint {.importc, header: "<ncurses.h>".}
  proc cClear(): cint {.importc: "clear", header: "<ncurses.h>".}
  proc refresh(): cint {.importc, header: "<ncurses.h>".}
  proc cMove(y, x: cint): cint {.importc: "move", header: "<ncurses.h>".}
  proc clrtoeol(): cint {.importc, header: "<ncurses.h>".}
  proc addnstr(value: cstring, count: cint): cint {.importc, header: "<ncurses.h>".}
  proc getch(): cint {.importc, header: "<ncurses.h>".}
  proc timeout(delay: cint) {.importc, header: "<ncurses.h>".}
  proc beep(): cint {.importc, header: "<ncurses.h>".}
  proc def_prog_mode(): cint {.importc, header: "<ncurses.h>".}
  proc reset_prog_mode(): cint {.importc, header: "<ncurses.h>".}

  var stdscr {.importc: "stdscr", header: "<ncurses.h>".}: Window
  var LINES {.importc: "LINES", header: "<ncurses.h>".}: cint
  var COLS {.importc: "COLS", header: "<ncurses.h>".}: cint

  {.emit: """
#include <locale.h>
#include <ncurses.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#include <wchar.h>
static int gene_tui_open = 0;
static int gene_tui_mouse(void) {
#if NCURSES_MOUSE_VERSION > 1
  mmask_t mask = BUTTON4_PRESSED;
#ifdef BUTTON5_PRESSED
  mask |= BUTTON5_PRESSED;
#endif
  mouseinterval(0);
  mousemask(mask, NULL);
  if (isatty(STDOUT_FILENO)) {
    const char *focus = "\033[?1004h";
    write(STDOUT_FILENO, focus, sizeof("\033[?1004h") - 1);
  }
  return 1;
#else
  const char *seq = "\033[?1000h\033[?1006h\033[?1004h";
  mousemask(0, NULL);
  if (isatty(STDOUT_FILENO))
    write(STDOUT_FILENO, seq,
          sizeof("\033[?1000h\033[?1006h\033[?1004h") - 1);
  return 0;
#endif
}
static void gene_tui_no_mouse(void) {
  const char *seq =
      "\033[?1000l\033[?1002l\033[?1003l\033[?1004l\033[?1006l";
  mousemask(0, NULL);
  if (isatty(STDOUT_FILENO))
    write(STDOUT_FILENO, seq,
          sizeof("\033[?1000l\033[?1002l\033[?1003l\033[?1004l\033[?1006l") - 1);
}
static int gene_tui_mouse_event(int *row, int *col, int *modifiers) {
  MEVENT event;
  if (getmouse(&event) != OK) return 0;
  if (row) *row = event.y;
  if (col) *col = event.x;
  if (modifiers) {
    *modifiers = 0;
#ifdef BUTTON_SHIFT
    if (event.bstate & BUTTON_SHIFT) *modifiers |= 1;
#endif
#ifdef BUTTON_ALT
    if (event.bstate & BUTTON_ALT) *modifiers |= 2;
#endif
#ifdef BUTTON_CTRL
    if (event.bstate & BUTTON_CTRL) *modifiers |= 4;
#endif
  }
  if (event.bstate & BUTTON4_PRESSED) return 1;
#ifdef BUTTON5_PRESSED
  if (event.bstate & BUTTON5_PRESSED) return -1;
#endif
  return 0;
}
static int gene_tui_wcwidth(int rune) { return wcwidth((wchar_t)rune); }
static void gene_tui_restore(void) {
  if (gene_tui_open) {
    gene_tui_no_mouse();
    endwin();
    gene_tui_open = 0;
  }
}
static void gene_tui_signal(int sig) {
  gene_tui_restore();
  _exit(128 + sig);
}
static void gene_tui_install(void) {
  static int installed = 0;
  if (installed) return;
  installed = 1;
  setlocale(LC_ALL, "");
  atexit(gene_tui_restore);
  signal(SIGTERM, gene_tui_signal);
  signal(SIGHUP, gene_tui_signal);
}
static void gene_tui_mark_open(int open) { gene_tui_open = open; }
""".}

  proc cEnableMouse(): cint {.importc: "gene_tui_mouse".}
  proc cDisableMouse() {.importc: "gene_tui_no_mouse".}
  proc cMouseEvent(row, col, modifiers: ptr cint): cint
    {.importc: "gene_tui_mouse_event".}
  proc cWcwidth(rune: cint): cint {.importc: "gene_tui_wcwidth".}
  proc cInstall() {.importc: "gene_tui_install".}
  proc cMarkOpen(open: cint) {.importc: "gene_tui_mark_open".}

  const
    CursesErr = -1
    KeyEnter = 10
    KeyCtrlD = 4
    KeyReturn = 13
    KeyEsc = 27
    KeyBackspace = 263
    KeyDelete = 330
    KeyLeft = 260
    KeyRight = 261
    KeyUp = 259
    KeyDown = 258
    KeyHome = 262
    KeyEnd = 360
    KeyPageDown = 338
    KeyPageUp = 339
    KeyNcursesEnter = 343
    KeyMouse = 409
    KeyResize = 410
    KeyF1 = 265
    KeyF5 = 269
    KeyF10 = 274

  proc textWidth*(text: string): int =
    for rune in text.runes:
      let measured = int(cWcwidth(cint(rune.int32)))
      result += (if measured < 0: 1 else: measured)

  proc clipCells(text: string, width: int): string =
    if width <= 0:
      return ""
    var used = 0
    for rune in text.runes:
      let measured = int(cWcwidth(cint(rune.int32)))
      let cells = if measured < 0: 1 else: measured
      if used + cells > width:
        break
      result.add rune.toUTF8
      used += cells

  proc fitCells*(text: string, width: int): string =
    result = clipCells(text, width)
    result.add repeat(' ', max(0, width - textWidth(result)))

  proc isEscFinalByte(ch: char): bool =
    ch.ord >= 0x40 and ch.ord <= 0x7E

  proc readEscSequence(): string =
    timeout(60)
    try:
      let first = getch()
      if first == CursesErr or first < 0 or first > 255:
        return
      result.add char(first)
      if result[0] in {'[', 'O'}:
        while true:
          let ch = getch()
          if ch == CursesErr or ch < 0 or ch > 255:
            break
          let byte = char(ch)
          result.add byte
          if isEscFinalByte(byte):
            break
    finally:
      timeout(-1)

  proc eventFromEscape(sequence: string): TuiEvent =
    if mouseScrollFromEscape(sequence) > 0:
      TuiEvent(kind: tekScrollUp)
    elif mouseScrollFromEscape(sequence) < 0:
      TuiEvent(kind: tekScrollDown)
    else:
      case sequence
      of "[A", "OA": TuiEvent(kind: tekUp)
      of "[B", "OB": TuiEvent(kind: tekDown)
      of "[5~": TuiEvent(kind: tekPageUp)
      of "[6~": TuiEvent(kind: tekPageDown)
      of "": TuiEvent(kind: tekEscape)
      else: TuiEvent(kind: tekUnknown)

  proc enableMouse*(): bool = cEnableMouse() != 0
  proc disableMouse*() = cDisableMouse()
  proc takeMouseEvent*(): TuiMouseEvent =
    var row, col, modifiers: cint
    result.direction = int(cMouseEvent(addr row, addr col, addr modifiers))
    result.row = int(row)
    result.col = int(col)
    result.shift = (modifiers and 1) != 0
    result.alt = (modifiers and 2) != 0
    result.ctrl = (modifiers and 4) != 0

  proc takeMouseScroll*(): int = takeMouseEvent().direction

  proc openTerminal*(): Terminal =
    if isatty(STDIN_FILENO) == 0 or isatty(STDOUT_FILENO) == 0:
      raise newException(IOError, "interactive terminal required")
    cInstall()
    if initscr() == nil:
      raise newException(IOError, "could not initialize ncurses")
    cMarkOpen(1)
    discard cbreak()
    discard noecho()
    discard keypad(stdscr, 1)
    discard curs_set(0)
    discard enableMouse()
    Terminal(opened: true)

  proc close*(terminal: var Terminal) =
    if terminal.opened:
      disableMouse()
      discard endwin()
      cMarkOpen(0)
      terminal.opened = false

  proc suspend*(terminal: var Terminal) =
    if terminal.opened:
      disableMouse()
      discard def_prog_mode()
      discard endwin()
      cMarkOpen(0)

  proc resume*(terminal: var Terminal) =
    if terminal.opened:
      discard reset_prog_mode()
      discard refresh()
      discard enableMouse()
      cMarkOpen(1)
      discard cClear()

  proc dimensions*(terminal: Terminal): tuple[rows, cols: int] =
    discard terminal
    (rows: max(1, int(LINES)), cols: max(1, int(COLS)))

  proc clear*(terminal: Terminal) =
    discard terminal
    discard cClear()

  proc drawLine*(terminal: Terminal, row: int, text: string) =
    let size = terminal.dimensions()
    if row < 0 or row >= size.rows:
      return
    discard cMove(row.cint, 0)
    let clipped = clipCells(text, size.cols)
    discard addnstr(clipped.cstring, clipped.len.cint)
    discard clrtoeol()

  proc present*(terminal: Terminal) =
    discard terminal
    discard refresh()

  proc ring*(terminal: Terminal) =
    discard terminal
    discard beep()

  proc showCursor*(terminal: Terminal, visible: bool) =
    discard terminal
    discard curs_set(if visible: 1 else: 0)

  proc setCursor*(terminal: Terminal, row, col: int) =
    let size = terminal.dimensions()
    discard cMove(min(max(row, 0), size.rows - 1).cint,
                  min(max(col, 0), size.cols - 1).cint)

  proc readEvent*(terminal: Terminal): TuiEvent =
    discard terminal
    let ch = int(getch())
    case ch
    of CursesErr: TuiEvent(kind: tekEof)
    of KeyEnter, KeyReturn, KeyNcursesEnter: TuiEvent(kind: tekEnter)
    of KeyEsc: eventFromEscape(readEscSequence())
    of KeyCtrlD: TuiEvent(kind: tekEof)
    of KeyBackspace, 127, 8: TuiEvent(kind: tekBackspace)
    of KeyDelete: TuiEvent(kind: tekDelete)
    of KeyLeft: TuiEvent(kind: tekLeft)
    of KeyRight: TuiEvent(kind: tekRight)
    of KeyUp: TuiEvent(kind: tekUp)
    of KeyDown: TuiEvent(kind: tekDown)
    of KeyHome: TuiEvent(kind: tekHome)
    of KeyEnd: TuiEvent(kind: tekEnd)
    of KeyPageUp: TuiEvent(kind: tekPageUp)
    of KeyPageDown: TuiEvent(kind: tekPageDown)
    of KeyResize: TuiEvent(kind: tekResize)
    of KeyF1: TuiEvent(kind: tekHelp)
    of KeyF5: TuiEvent(kind: tekReload)
    of KeyF10: TuiEvent(kind: tekQuit)
    of KeyMouse:
      let direction = takeMouseScroll()
      if direction > 0: TuiEvent(kind: tekScrollUp)
      elif direction < 0: TuiEvent(kind: tekScrollDown)
      else: TuiEvent(kind: tekUnknown)
    else:
      if ch >= 32 and ch <= 255:
        var text = $char(ch)
        let expected =
          if ch < 0x80: 1
          elif ch < 0xE0: 2
          elif ch < 0xF0: 3
          else: 4
        while text.len < expected:
          let continuation = int(getch())
          if continuation < 0 or continuation > 255:
            break
          text.add char(continuation)
        TuiEvent(kind: tekText, text: text)
      else:
        TuiEvent(kind: tekUnknown)

else:
  proc enableMouse*(): bool = false
  proc disableMouse*() = discard
  proc takeMouseScroll*(): int = 0
  proc takeMouseEvent*(): TuiMouseEvent = TuiMouseEvent()
  proc openTerminal*(): Terminal =
    raise newException(IOError, "gene view is unavailable on this platform")
  proc close*(terminal: var Terminal) = discard
  proc suspend*(terminal: var Terminal) = discard
  proc resume*(terminal: var Terminal) = discard
  proc dimensions*(terminal: Terminal): tuple[rows, cols: int] = (0, 0)
  proc clear*(terminal: Terminal) = discard
  proc drawLine*(terminal: Terminal, row: int, text: string) = discard
  proc present*(terminal: Terminal) = discard
  proc ring*(terminal: Terminal) = discard
  proc showCursor*(terminal: Terminal, visible: bool) = discard
  proc setCursor*(terminal: Terminal, row, col: int) = discard
  proc textWidth*(text: string): int = text.runeLen
  proc fitCells*(text: string, width: int): string =
    let clipped = text.runeSubStr(0, max(width, 0))
    clipped & repeat(' ', max(0, width - clipped.runeLen))
  proc readEvent*(terminal: Terminal): TuiEvent = TuiEvent(kind: tekUnknown)
