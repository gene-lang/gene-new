## `gene-fmt` — canonical human-friendly Gene source formatting.
##
## Built as its own executable rather than linked into `gene`. Formatting is a
## tool surface, not a runtime one: the `gene/parse/format` builtin was the only
## thing pulling fmt.nim — and transitively the LSP analyzer — into every Gene
## process. `gene fmt <file>` execs this binary and hands over its arguments.

import std/os
import gene/[diagnostics, reader, types]
import tools/fmt

const usage = "Usage: gene-fmt <file.gene>\n\n" &
  "Formats a Gene source file to stdout: reader sugar restored, comments\n" &
  "preserved, forms wrapped and indented by depth. `gene parse` stays canonical."

proc main() =
  if paramCount() < 1:
    stderr.writeLine usage
    quit(1)
  let path = paramStr(1)
  if path in ["--help", "-h"]:
    stdout.writeLine usage
    quit(0)
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  let src = readFile(path)
  try:
    stdout.write formatSource(src, normalizedPath(absolutePath(path)))
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg,
      SourceLoc(sourceName: e.sourceName, line: e.line, col: e.col))
    quit(1)

main()
