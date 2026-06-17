## Gene language CLI entry point.
##
## Subcommands (a subset of design Section 18):
##   gene eval "<src>"   evaluate a source string, print the result
##   gene run  <file>    load and execute a .gene file, then call main if present
##   gene parse <file>   read and print canonical forms (no execution)
##   gene fmt <file>     format source through the canonical printer
##   gene compile <file> print compiled GIR bytecode (no execution)

import std/[os]
import gene/[compiler, gir, printer, reader, types, vm]

proc usage() =
  echo "Gene — a homoiconic general purpose language"
  echo ""
  echo "Usage:"
  echo "  gene eval \"<source>\"   evaluate a source string and print the result"
  echo "  gene run <file.gene> [args...] execute a file, then call main if present"
  echo "  gene parse <file.gene>  print canonical parsed forms"
  echo "  gene fmt <file.gene>    format source through the canonical printer"
  echo "  gene compile <file.gene> print compiled GIR bytecode"

proc readSourceFile(path: string): string =
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  readFile(path)

proc cmdEval(src: string) =
  try:
    initModuleContext(getCurrentDir())   # relative imports resolve from cwd
    echo run(compileSource(src), newGlobalScope()).print()
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

proc argsList(args: openArray[string]): Value =
  var values = newSeq[Value](args.len)
  for i, arg in args:
    values[i] = newStr(arg)
  newList(values)

proc commandArgs(first: int): seq[string] =
  if first <= paramCount():
    for i in first .. paramCount():
      result.add paramStr(i)

proc exitFromMain(value: Value) =
  case value.kind
  of vkNil:
    discard
  of vkInt:
    quit(int(value.intVal))
  else:
    raise newException(GeneError,
      "main must return nil or int, got " & $value.kind)

proc cmdRun(path: string, args: openArray[string] = []) =
  let src = readSourceFile(path)
  try:
    initModuleContext(parentDir(absolutePath(path)))   # entry module dir = root
    let scope = newGlobalScope()
    discard bindThisModule(scope, splitFile(path).name)
    discard run(compileSource(src), scope)
    var mainBinding: Value
    if scope.lookupOptional("main", mainBinding):
      let result =
        if mainBinding.kind == vkFunction and mainBinding.fnParams.len == 0:
          mainBinding.call()
        else:
          mainBinding.call(@[argsList(args)])
      exitFromMain(result)
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
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

proc cmdFmt(path: string) =
  cmdParse(path)

proc cmdCompile(path: string) =
  let src = readSourceFile(path)
  try:
    echo compileSource(src).disassemble()
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine "Error: " & e.msg
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
    cmdRun(paramStr(2), commandArgs(3))
  of "parse":
    if paramCount() < 2:
      stderr.writeLine "Error: 'parse' needs a file path"
      quit(1)
    cmdParse(paramStr(2))
  of "fmt":
    if paramCount() < 2:
      stderr.writeLine "Error: 'fmt' needs a file path"
      quit(1)
    cmdFmt(paramStr(2))
  of "compile":
    if paramCount() < 2:
      stderr.writeLine "Error: 'compile' needs a file path"
      quit(1)
    cmdCompile(paramStr(2))
  of "-h", "--help", "help":
    usage()
  else:
    # Back-compat: a bare path argument is treated as `run`.
    if fileExists(cmd):
      cmdRun(cmd, commandArgs(2))
    else:
      stderr.writeLine "Unknown command: " & cmd
      usage()
      quit(1)

main()
