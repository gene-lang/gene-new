## `gene doc build [dir]`: the documentation builder's command line.
##
## Delegated from `gene doc build` as `gene fmt` is. `gene doc <file>` keeps
## its existing runtime view; this command only writes the corpus.

import std/[os, strutils]
import ./builder

const usage = """Usage: gene-doc build [dir] [--package-root <dir>]

Reads every .gene file under the package's source root (or under `dir`),
writes one data file per module and a coverage report to
<package root>/build/docs/, and prints what it found. Nothing is compiled or
run: a module body never executes."""

proc firstLine(message: string): string =
  let newline = message.find('\n')
  if newline >= 0: message[0 ..< newline] else: message

proc runDocCli*() =
  var command = ""
  var corpusDir = ""
  var packageRoot = ""
  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--help", "-h":
      stdout.writeLine usage
      quit(0)
    of "--package-root":
      inc i
      if i > paramCount():
        stderr.writeLine "Error: --package-root expects a path"
        quit(1)
      packageRoot = paramStr(i)
    else:
      if arg.startsWith("-"):
        stderr.writeLine "Error: unknown option: " & arg
        quit(1)
      elif command.len == 0:
        command = arg
      elif corpusDir.len == 0:
        corpusDir = arg
      else:
        stderr.writeLine "Error: unexpected argument: " & arg
        quit(1)
    inc i
  if command != "build":
    if command.len == 0:
      stderr.writeLine usage
    else:
      stderr.writeLine "Error: unknown gene-doc command: " & command
    quit(1)
  let start = if packageRoot.len > 0: packageRoot else: getCurrentDir()
  try:
    var result = buildPackage(start, corpusDir)
    result.summarize()
    result.writeOutputs()
    stdout.writeLine "Gene documentation: " & result.packageName
    stdout.writeLine "  package: " & result.packageRoot
    stdout.writeLine "  modules: " & $result.modules.len
    stdout.writeLine "  entries: " & $result.entryCount
    stdout.writeLine "  with @doc: " & $result.withDoc
    stdout.writeLine "  without @doc: " & $(result.entryCount - result.withDoc)
    stdout.writeLine "  unresolved imports: " & $result.unresolvedImports
    stdout.writeLine "  unexpanded forms: " & $result.unexpandedCount
    stdout.writeLine "  diagnostics: " & $result.diagnosticCount
    for diagnostic in result.buildDiagnostics:
      stderr.writeLine "  " & diagnostic.source & ": " & diagnostic.kind &
        ": " & diagnostic.message
    for module in result.modules:
      for diagnostic in module.diagnostics:
        stderr.writeLine "  " & diagnostic.source & ":" & $diagnostic.line &
          ":" & $diagnostic.col & ": " & diagnostic.kind & ": " &
          diagnostic.message
    stdout.writeLine "  wrote: " & result.outputRoot
    if result.readErrors > 0:
      stderr.writeLine "Error: " & $result.readErrors &
        " file(s) did not read; the rest of the corpus was built"
      quit(1)
  except ValueError as error:
    stderr.writeLine "Error: " & firstLine(error.msg)
    quit(2)
  except CatchableError as error:
    stderr.writeLine "Error: " & firstLine(error.msg)
    quit(1)
