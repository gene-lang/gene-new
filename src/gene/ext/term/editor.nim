## External editor resolution and cursor-position adapters.

import std/[os, osproc, strutils]

type
  EditorCommand* = object
    executable*: string
    args*: seq[string]

proc parseEditorCommand*(raw: string): EditorCommand =
  let parts = parseCmdLine(raw)
  if parts.len == 0:
    raise newException(ValueError, "editor command is empty")
  result.executable = parts[0]
  if parts.len > 1:
    result.args = parts[1 .. ^1]

proc resolveEditor*(override = ""): EditorCommand =
  for configured in [override, getEnv("VISUAL"), getEnv("EDITOR")]:
    if configured.strip().len > 0:
      return parseEditorCommand(configured)
  for candidate in ["nvim", "vim", "vi"]:
    let found = findExe(candidate)
    if found.len > 0:
      return EditorCommand(executable: found)
  raise newException(ValueError,
    "no editor found; set $VISUAL or $EDITOR, or pass --editor")

proc editorArgs*(editor: EditorCommand, path: string,
                 line, col: int): seq[string] =
  result = editor.args
  let family = splitFile(editor.executable).name.toLowerAscii()
  case family
  of "nvim", "vim", "vi":
    result.add "+call cursor(" & $line & "," & $col & ")"
    result.add path
  of "nano":
    result.add "+" & $line & "," & $col
    result.add path
  of "emacs", "emacsclient":
    result.add "+" & $line & ":" & $col
    result.add path
  of "code", "codium":
    result.add "--goto"
    result.add path & ":" & $line & ":" & $col
  else:
    result.add path

proc launchEditor*(editor: EditorCommand, path: string,
                   line, col: int): int =
  let process = startProcess(editor.executable,
                             args = editor.editorArgs(path, line, col),
                             options = {poParentStreams, poUsePath})
  try:
    result = process.waitForExit()
  finally:
    process.close()
