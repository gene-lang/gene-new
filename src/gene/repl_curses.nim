## Ncurses-backed Gene REPL.
##
## This is an opt-in terminal frontend for the same declaration-persistent
## runReplSession loop used by the plain CLI REPL. It keeps evaluated output in
## a scrollback area and owns the bottom line as an editable prompt.

{.passL: "-lncurses".}

import std/strutils
import ./[types, vm]

type Window = pointer

proc initscr(): Window {.importc, header: "<ncurses.h>".}
proc endwin(): cint {.importc, header: "<ncurses.h>".}
proc cbreak(): cint {.importc, header: "<ncurses.h>".}
proc noecho(): cint {.importc, header: "<ncurses.h>".}
proc keypad(win: Window, bf: cint): cint {.importc, header: "<ncurses.h>".}
proc curs_set(visibility: cint): cint {.importc, header: "<ncurses.h>".}
proc cClear(): cint {.importc: "clear", header: "<ncurses.h>".}
proc refresh(): cint {.importc, header: "<ncurses.h>".}
proc cMove(y, x: cint): cint {.importc: "move", header: "<ncurses.h>".}
proc clrtoeol(): cint {.importc, header: "<ncurses.h>".}
proc addnstr(s: cstring, n: cint): cint {.importc, header: "<ncurses.h>".}
proc getch(): cint {.importc, header: "<ncurses.h>".}
proc beep(): cint {.importc, header: "<ncurses.h>".}

var stdscr {.importc: "stdscr", header: "<ncurses.h>".}: Window
var LINES {.importc: "LINES", header: "<ncurses.h>".}: cint
var COLS {.importc: "COLS", header: "<ncurses.h>".}: cint

const
  KeyCtrlD = 4
  KeyEnter = 10
  KeyReturn = 13
  KeyBackspace = 263
  KeyDelete = 330
  KeyLeft = 260
  KeyRight = 261
  KeyHome = 262
  KeyEnd = 360

proc addScreenText(text: string, maxWidth: int) =
  if maxWidth <= 0:
    return
  let clipped =
    if text.len > maxWidth: text.substr(0, maxWidth - 1)
    else: text
  discard addnstr(clipped.cstring, clipped.len.cint)

proc appendOutput(lines: var seq[string], text: string) =
  var start = 0
  for i, ch in text:
    if ch == '\n':
      if i > start:
        lines.add text.substr(start, i - 1)
      else:
        lines.add ""
      start = i + 1
  if start < text.len:
    lines.add text.substr(start)

proc draw(lines: openArray[string], prompt, input: string, cursor: int) =
  discard cClear()
  let height = max(1, int(LINES))
  let width = max(1, int(COLS))
  let outputRows = max(0, height - 1)
  let first = max(0, lines.len - outputRows)
  for row in 0 ..< min(outputRows, lines.len):
    discard cMove(row.cint, 0)
    addScreenText(lines[first + row], width)
    discard clrtoeol()

  discard cMove((height - 1).cint, 0)
  addScreenText(prompt & input, width)
  discard clrtoeol()
  discard cMove((height - 1).cint, min(width - 1, prompt.len + cursor).cint)
  discard refresh()

proc runCursesRepl*(scope: Scope, prompt = "gene> "): int =
  if initscr() == nil:
    stderr.writeLine "Error: could not initialize ncurses"
    return 1
  try:
    discard cbreak()
    discard noecho()
    discard keypad(stdscr, 1)
    discard curs_set(1)

    var outputLines: seq[string]
    var input = ""
    var cursor = 0

    let reader = proc(line: var string): bool =
      while true:
        draw(outputLines, prompt, input, cursor)
        let ch = getch()
        case ch
        of KeyCtrlD:
          return false
        of KeyEnter, KeyReturn:
          line = input
          outputLines.add prompt & input
          input.setLen(0)
          cursor = 0
          return true
        of KeyBackspace, 127, 8:
          if cursor > 0:
            input.delete(cursor - 1 .. cursor - 1)
            dec cursor
          else:
            discard beep()
        of KeyDelete:
          if cursor < input.len:
            input.delete(cursor .. cursor)
          else:
            discard beep()
        of KeyLeft:
          if cursor > 0: dec cursor else: discard beep()
        of KeyRight:
          if cursor < input.len: inc cursor else: discard beep()
        of KeyHome:
          cursor = 0
        of KeyEnd:
          cursor = input.len
        else:
          if ch >= 32 and ch <= 255:
            input.insert($char(ch), cursor)
            inc cursor
          else:
            discard beep()

    let writeOut = proc(text: string) =
      appendOutput(outputLines, text)
      draw(outputLines, prompt, input, cursor)

    let writeErr = proc(text: string) =
      appendOutput(outputLines, text)
      draw(outputLines, prompt, input, cursor)

    result = runReplSession(scope, reader, writeOut, writeErr,
                            ReplOptions(interactive: false, prompt: prompt))
  finally:
    discard endwin()
