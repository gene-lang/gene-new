## Ncurses-backed Gene REPL.
##
## This is an opt-in terminal frontend for the same declaration-persistent
## runReplSession loop used by the plain CLI REPL. It keeps evaluated output in
## a scrollback area and owns the bottom line as an editable prompt.

import std/strutils
import ./[types, vm]
import ./tui/terminal

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

proc draw(terminal: Terminal, lines: openArray[string], prompt, input: string,
          cursor: int) =
  terminal.clear()
  let size = terminal.dimensions()
  let height = size.rows
  let outputRows = max(0, height - 1)
  let first = max(0, lines.len - outputRows)
  for row in 0 ..< min(outputRows, lines.len):
    terminal.drawLine(row, lines[first + row])
  terminal.drawLine(height - 1, prompt & input)
  terminal.showCursor(true)
  terminal.setCursor(height - 1, min(size.cols - 1, prompt.len + cursor))
  terminal.present()

proc runCursesRepl*(scope: Scope, prompt = "gene> "): int =
  var terminal: Terminal
  try:
    terminal = openTerminal()
  except IOError as error:
    stderr.writeLine "Error: " & error.msg
    return 1
  try:
    var outputLines: seq[string]
    var input = ""
    var cursor = 0

    let reader = proc(line: var string): bool =
      while true:
        draw(terminal, outputLines, prompt, input, cursor)
        let event = terminal.readEvent()
        case event.kind
        of tekEof:
          return false
        of tekEnter:
          line = input
          outputLines.add prompt & input
          input.setLen(0)
          cursor = 0
          return true
        of tekBackspace:
          if cursor > 0:
            input.delete(cursor - 1 .. cursor - 1)
            dec cursor
          else:
            terminal.ring()
        of tekDelete:
          if cursor < input.len:
            input.delete(cursor .. cursor)
          else:
            terminal.ring()
        of tekLeft:
          if cursor > 0: dec cursor else: terminal.ring()
        of tekRight:
          if cursor < input.len: inc cursor else: terminal.ring()
        of tekHome:
          cursor = 0
        of tekEnd:
          cursor = input.len
        of tekText:
          input.insert(event.text, cursor)
          cursor += event.text.len
        else: terminal.ring()

    let writeOut = proc(text: string) =
      appendOutput(outputLines, text)
      draw(terminal, outputLines, prompt, input, cursor)

    let writeErr = proc(text: string) =
      appendOutput(outputLines, text)
      draw(terminal, outputLines, prompt, input, cursor)

    result = runReplSession(scope, reader, writeOut, writeErr,
                            ReplOptions(interactive: false, prompt: prompt))
  finally:
    terminal.close()
