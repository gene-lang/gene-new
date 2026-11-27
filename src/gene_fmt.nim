## `gene-fmt` — canonical human-friendly Gene source formatting.
##
## Built as its own executable rather than linked into `gene`. Formatting is a
## tool surface, not a runtime one: the `gene/parse/format` builtin was the only
## thing pulling fmt.nim — and transitively the LSP analyzer — into every Gene
## process. `gene fmt <file>` execs this binary and hands over its arguments.

import std/[os, terminal]
import gene/[diagnostics, reader, types]
import tools/fmt

const usage = "Usage: gene-fmt [<file.gene>|-]\n\n" &
  "Formats Gene source from a file or stdin and writes it to stdout."

proc main() =
  if paramCount() < 1 and isatty(stdin):
    stderr.writeLine usage
    quit(1)
  let path = if paramCount() < 1: "-" else: paramStr(1)
  if path in ["--help", "-h"]:
    stdout.writeLine usage
    quit(0)
  if path != "-" and not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  try:
    if path == "-":
      stdout.write formatSource(stdin.readAll(), "<stdin>")
    else:
      stdout.write formatSource(readFile(path), normalizedPath(absolutePath(path)))
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg,
      SourceLoc(sourceName: e.sourceName, line: e.line, col: e.col))
    quit(1)
  except IOError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

main()
