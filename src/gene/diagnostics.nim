import std/[os, strutils]
import ./types

proc locationText*(loc: SourceLoc): string =
  if not loc.hasSourceLoc:
    return ""
  let name = if loc.sourceName.len == 0: "<source>" else: loc.sourceName
  name & ":" & $loc.line & ":" & $loc.col

proc sourceLine(path: string, line: int): string =
  if path.len == 0 or path.startsWith("<") or not fileExists(path):
    return ""
  try:
    var index = 1
    for text in lines(path):
      if index == line:
        return text
      inc index
  except OSError:
    discard
  ""

proc caretLine(col: int): string =
  if col <= 1:
    return "^"
  repeat(' ', col - 1) & "^"

proc formatDiagnostic*(kind, message: string, loc = SourceLoc()): string =
  result = kind & ": " & message
  if not loc.hasSourceLoc:
    return
  result.add "\n  at " & loc.locationText()
  let line = sourceLine(loc.sourceName, loc.line)
  if line.len > 0:
    result.add "\n" & align($loc.line, 6) & " | " & line
    result.add "\n       | " & caretLine(loc.col)
