## `gene-viewer` — browse Gene source structure and edit externally.
##
## Built as its own executable rather than linked into `gene`. `gene view`
## execs this binary; execv is what lets the full-screen viewer own the
## controlling terminal directly rather than through a parent process.
##
## Options are parsed from argv[1] here, where `gene view` parsed from argv[2]
## (past the subcommand name) — the delegation drops "view" before handing over.

import std/[os, strutils]
import tools/viewer/app as viewer_app

proc parseViewCli(): viewer_app.ViewerOptions =
  result.col = 1
  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--readonly": result.readonly = true
    of "--no-color": result.noColor = true
    of "--editor", "--path", "--line":
      inc i
      if i > paramCount():
        raise newException(ValueError, arg & " expects a value")
      let value = paramStr(i)
      case arg
      of "--editor": result.editor = value
      of "--path": result.initialPath = value
      of "--line":
        let parts = value.split(':', maxsplit = 1)
        result.line = parseInt(parts[0])
        if parts.len == 2: result.col = parseInt(parts[1])
        if result.line <= 0 or result.col <= 0:
          raise newException(ValueError, "--line expects positive N[:COLUMN]")
      else: discard
    else:
      if arg.startsWith("--editor="):
        result.editor = arg[9 .. ^1]
      elif arg.startsWith("--path="):
        result.initialPath = arg[7 .. ^1]
      elif arg.startsWith("--line="):
        let parts = arg[7 .. ^1].split(':', maxsplit = 1)
        result.line = parseInt(parts[0])
        if parts.len == 2: result.col = parseInt(parts[1])
        if result.line <= 0 or result.col <= 0:
          raise newException(ValueError, "--line expects positive N[:COLUMN]")
      elif arg.startsWith("-"):
        raise newException(ValueError, "unknown view option: " & arg)
      elif result.path.len == 0:
        result.path = arg
      else:
        raise newException(ValueError, "view accepts one file path")
    inc i
  if result.path.len == 0:
    raise newException(ValueError, "'view' needs a file path")
  if result.initialPath.len > 0 and result.line > 0:
    raise newException(ValueError, "--path and --line are mutually exclusive")

try:
  quit(viewer_app.runViewer(parseViewCli()))
except ValueError as error:
  stderr.writeLine "Error: " & error.msg
  quit(1)
except CatchableError as error:
  stderr.writeLine "Error: " & error.msg
  quit(1)
