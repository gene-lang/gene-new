## Gene language CLI entry point.
##
## Subcommands (a subset of design Section 18):
##   gene eval "<src>"   evaluate a source string, print the result
##   gene run  <file>    load and execute a .gene file top to bottom
##   gene parse <file>   read and print canonical forms (no execution)

import std/[os]
import gene/[reader, printer, eval]

proc usage() =
  echo "Gene — a homoiconic general purpose language"
  echo ""
  echo "Usage:"
  echo "  gene eval \"<source>\"   evaluate a source string and print the result"
  echo "  gene run <file.gene>    execute a file top to bottom"
  echo "  gene parse <file.gene>  print canonical parsed forms"

proc readSourceFile(path: string): string =
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  readFile(path)

proc cmdEval(src: string) =
  try:
    echo evalStr(src).print()
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

proc cmdRun(path: string) =
  let src = readSourceFile(path)
  try:
    discard evalAll(src, newGlobalScope())
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

proc cmdParse(path: string) =
  let src = readSourceFile(path)
  try:
    for f in readAll(src):
      echo f.print()
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    quit(1)

proc main() =
  if paramCount() == 0:
    usage()
    quit(0)
  let cmd = paramStr(1)
  case cmd
  of "eval":
    if paramCount() < 2:
      stderr.writeLine "Error: 'eval' needs a source string"
      quit(1)
    cmdEval(paramStr(2))
  of "run":
    if paramCount() < 2:
      stderr.writeLine "Error: 'run' needs a file path"
      quit(1)
    cmdRun(paramStr(2))
  of "parse":
    if paramCount() < 2:
      stderr.writeLine "Error: 'parse' needs a file path"
      quit(1)
    cmdParse(paramStr(2))
  of "-h", "--help", "help":
    usage()
  else:
    # Back-compat: a bare path argument is treated as `run`.
    if fileExists(cmd):
      cmdRun(cmd)
    else:
      stderr.writeLine "Unknown command: " & cmd
      usage()
      quit(1)

main()
