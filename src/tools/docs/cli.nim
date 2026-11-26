## `gene doc build [dir]`: the documentation builder's command line.
##
## Delegated from `gene doc build` as `gene fmt` is. `gene doc <file>` keeps
## its existing runtime view; this command only writes the corpus.

import std/[os, strutils]
import ./builder
import ../../gene/docs_lookup

const usage = """Usage: gene-doc build [dir] [--package-root <dir>]
       gene-doc index [--corpus <dir>]
       gene-doc ls [id] [--corpus <dir>]
       gene-doc show <id or name> [--corpus <dir>]
       gene-doc search <text> [--corpus <dir>]

`build` reads every .gene file under the package's source root (or under
`dir`) and writes the builder's data files. The lookup commands read a
generated corpus (build/docs/, or the directory named by --corpus). Nothing
is compiled or run: a module body never executes."""

proc firstLine(message: string): string =
  let newline = message.find('\n')
  if newline >= 0: message[0 ..< newline] else: message

proc runDocCli*() =
  var command = ""
  var corpusArg = ""
  var packageRoot = ""
  var positional: seq[string]
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
    of "--corpus":
      inc i
      if i > paramCount():
        stderr.writeLine "Error: --corpus expects a path"
        quit(1)
      corpusArg = paramStr(i)
    else:
      if arg.startsWith("-"):
        stderr.writeLine "Error: unknown option: " & arg
        quit(1)
      if command.len == 0:
        command = arg
      else:
        positional.add arg
    inc i

  case command
  of "build":
    let start = if packageRoot.len > 0: packageRoot else: getCurrentDir()
    let dir = if positional.len > 0: positional[0] else: ""
    try:
      var result = buildPackage(start, dir)
      result.summarize()
      result.writeOutputs()
      stdout.writeLine "Gene documentation: " & result.packageName
      stdout.writeLine "  package: " & result.packageRoot
      stdout.writeLine "  modules: " & $result.modules.len
      stdout.writeLine "  entries: " & $result.entryCount
      stdout.writeLine "  with @doc: " & $result.withDoc
      stdout.writeLine "  without @doc: " & $(result.entryCount - result.withDoc)
      var unverified = 0
      for module in result.modules:
        for entry in module.entries:
          if entry.unverified:
            inc unverified
      stdout.writeLine "  unverified entries: " & $unverified
      stdout.writeLine "  unresolved imports: " & $result.unresolvedImports
      stdout.writeLine "  unexpanded forms: " & $result.unexpandedCount
      stdout.writeLine "  diagnostics: " & $result.diagnosticCount
      for diagnostic in result.buildDiagnostics:
        stderr.writeLine "  " & diagnostic.source & ": " & diagnostic.kind &
          ": " & diagnostic.message
      for module in result.modules:
        for diagnostic in module.diagnostics:
          var where = diagnostic.source
          if diagnostic.line > 0 or diagnostic.col > 0:
            where.add ":" & $diagnostic.line & ":" & $diagnostic.col
          stderr.writeLine "  " & where & ": " & diagnostic.kind & ": " &
            diagnostic.message
      stdout.writeLine "  wrote: " & result.outputRoot
      if result.readErrors > 0:
        stderr.writeLine "Error: " & $result.readErrors &
          " file(s) did not read; the rest of the corpus was built"
        quit(3)
    except ValueError as error:
      stderr.writeLine "Error: " & firstLine(error.msg)
      quit(2)
    except CatchableError as error:
      stderr.writeLine "Error: " & firstLine(error.msg)
      quit(1)
  of "index", "ls", "show", "search":
    let root = findCorpus(corpusArg)
    if root.len == 0:
      let configured = if corpusArg.len > 0: corpusArg else: getEnv("GENE_DOCS_ROOT")
      stderr.writeLine "Error: no documentation corpus found" &
        (if configured.len > 0: " at " & configured else: "") &
        ". Run `gene doc build` first."
      quit(1)
    let corpus = loadCorpus(root)
    case command
    of "index":
      stdout.write(corpus.indexText())
    of "ls":
      let id = if positional.len > 0: positional[0] else: ""
      stdout.write(corpus.lsText(id))
    of "show":
      if positional.len == 0:
        stderr.writeLine "Error: show needs an id or a name"
        quit(1)
      stdout.write(corpus.showText(positional.join(" ")))
    of "search":
      if positional.len == 0:
        stderr.writeLine "Error: search needs text"
        quit(1)
      let found = corpus.searchText(positional.join(" "))
      if found.startsWith("Error: "):
        stderr.write(found)
        quit(1)
      stdout.write(found)
    else:
      discard
  else:
    if command.len == 0:
      stderr.writeLine usage
    else:
      stderr.writeLine "Error: unknown gene-doc command: " & command
    quit(1)
