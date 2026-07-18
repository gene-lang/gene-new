## Gene language CLI entry point.
##
## Subcommands (a subset of design Section 18):
##   gene eval "<src>"   evaluate a source string, print the result
##   gene repl           read/eval/print source lines from stdin
##   gene run  <file>    load and execute a .gene file, then call main if present
##   gene parse <file>   read and print canonical forms (no execution)
##   gene fmt <file>     format source through the canonical printer
##   gene compile <file> print compiled GIR bytecode (no execution)
##   gene compile --target c <file> print experimental typed_native C
##   gene doc <file>     print module metadata, imports, and declarations

import std/[algorithm, os, strutils, tables]
import gene/[compiler, diagnostics, fmt, gir, printer, reader, repl,
             repl_curses, logging, logging_config, types, vm]
import gene/lsp/server as lsp_server
import gene/viewer/app as viewer_app

proc usage() =
  echo "Gene — a homoiconic general purpose language"
  echo ""
  echo "Usage:"
  echo "  gene eval \"<source>\"   evaluate a source string and print the result"
  echo "  gene repl [--curses]   read/eval/print source lines from stdin"
  echo "  gene run [--log-config path] [--debug] <file.gene>"
  echo "           [--grant name=expr] [--] [args...]"
  echo "                              execute a file and explicitly grant main capabilities"
  echo "  gene parse <file.gene>  print canonical parsed forms"
  echo "  gene fmt <file.gene>    format source through the canonical printer"
  echo "  gene compile <file.gene> print compiled GIR bytecode"
  echo "  gene compile --target c <file.gene> print experimental typed_native C"
  echo "  gene doc <file.gene>    print module metadata, imports, and declarations"
  echo "  gene view [options] <file.gene> browse source structure and edit externally"
  echo "  gene lsp                run the language server over stdio (docs/lsp.md)"

proc readSourceFile(path: string): string =
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  readFile(path)

proc readErrorLoc(e: ref ReadError): SourceLoc =
  SourceLoc(sourceName: e.sourceName, line: e.line, col: e.col)

proc replOnErrorEnabled(): bool =
  let value = getEnv("REPL_ON_ERROR").strip().toLowerAscii()
  value in ["1", "true", "yes", "on"]

proc replFallbackScope(scope: Scope, app: Application = nil): Scope =
  if scope != nil:
    return scope
  if app != nil:
    return newGlobalScope(app)
  newGlobalScope(initModuleContext(getCurrentDir()))

proc maybeReplOnError(scope: Scope, app: Application = nil) =
  if replOnErrorEnabled():
    stderr.writeLine "REPL_ON_ERROR=1: entering Gene REPL (:quit to exit)."
    let code = runRepl(replFallbackScope(scope, app))
    if code != 0:
      quit(code)

proc cmdEval(src: string) =
  let app = initModuleContext(getCurrentDir())
  let scope = newGlobalScope(app)
  try:
    echo run(compileEvalSource(src, sourceName = "<eval>"), scope).print()
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    maybeReplOnError(scope, app)
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
    maybeReplOnError(scope, app)
    quit(1)

proc cursesReplEnabled(): bool =
  let value = getEnv("GENE_REPL_NCURSES").strip().toLowerAscii()
  value in ["1", "true", "yes", "on"]

proc cmdRepl(useCurses = false) =
  let app = initModuleContext(getCurrentDir())
  let scope = newGlobalScope(app)
  let code =
    if useCurses or cursesReplEnabled():
      runCursesRepl(scope)
    else:
      runRepl(scope)
  if code != 0:
    quit(code)

proc argsValue(args: openArray[string]): Value =
  # Preserve positional argv compatibility through node body indexes while
  # exposing the whole shell argument tail for future script-level parsing.
  var props = initPropTable()
  props["raw"] = newStr(args.join(" "))
  var values = newSeq[Value](args.len)
  for i, arg in args:
    values[i] = newStr(arg)
  newNode(newSym("args"), props = props, body = values)

proc commandArgs(first: int): seq[string] =
  if first <= paramCount():
    for i in first .. paramCount():
      result.add paramStr(i)

proc parseViewCli(): viewer_app.ViewerOptions =
  result.col = 1
  var i = 2
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

type RunCli = object
  path: string
  args: seq[string]
  logConfig: string
  debugging: bool

proc parseRunCli(): RunCli =
  var i = 2
  while i <= paramCount() and result.path.len == 0:
    let arg = paramStr(i)
    case arg
    of "--log-config":
      inc i
      if i > paramCount():
        raise newException(ValueError, "--log-config expects a path")
      result.logConfig = paramStr(i)
    of "--debug":
      result.debugging = true
    else:
      if arg.startsWith("--log-config="):
        result.logConfig = arg[13 .. ^1]
      else:
        result.path = arg
    inc i
  if result.path.len == 0:
    raise newException(ValueError, "'run' needs a file path")
  result.args = commandArgs(i)

proc configureRunLogging(options: RunCli) =
  var config =
    if options.logConfig.len > 0:
      loadLoggingConfig(options.logConfig)
    else:
      defaultLoggingConfig()
  if options.debugging:
    config.overrides.add LogRouteOverride(name: "gene", hasLevel: true,
                                           level: llDebug)
  installLoggingConfig(config)

proc configureLspLogging() =
  var config = defaultLoggingConfig()
  if getEnv("GENE_LSP_LOG", "").strip().toLowerAscii() in
      ["1", "true", "yes", "on"]:
    config.overrides.add LogRouteOverride(name: "gene/lsp", hasLevel: true,
                                           level: llDebug)
  installLoggingConfig(config)

type MainGrantSpec = object
  name: string
  expr: string

proc splitMainInvocation(raw: openArray[string]): tuple[args: seq[string],
                                                        grants: seq[MainGrantSpec]] =
  var hostOptions = true
  var i = 0
  while i < raw.len:
    if hostOptions and raw[i] == "--":
      hostOptions = false
      inc i
      continue
    var spec = ""
    if hostOptions and raw[i] == "--grant":
      inc i
      if i >= raw.len:
        raise newException(GeneError, "--grant expects name=expression")
      spec = raw[i]
    elif hostOptions and raw[i].startsWith("--grant="):
      spec = raw[i][8 .. ^1]
    else:
      result.args.add raw[i]
      inc i
      continue
    let equals = spec.find('=')
    if equals <= 0 or equals == spec.high:
      raise newException(GeneError, "--grant expects name=expression")
    let name = spec[0 ..< equals]
    for existing in result.grants:
      if existing.name == name:
        raise newException(GeneError, "duplicate main grant: " & name)
    result.grants.add MainGrantSpec(name: name, expr: spec[equals + 1 .. ^1])
    inc i

proc raiseMainReturnTypeError(scope: Scope, value: Value) =
  let message = "main return expected Nil or Int, got " & $value.kind
  var props = initPropTable()
  props["message"] = newStr(message)
  props["where"] = newStr("main return")
  props["expected"] = newStr("Nil or Int")
  props["actual"] = newStr($value.kind)
  var head = newSym("TypeError")
  var typeError: Value
  if scope.lookupOptional("TypeError", typeError) and typeError.kind == vkType:
    head = typeError
  var e: ref GeneError
  new(e)
  e.msg = "TypeError: " & message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc raiseMainReturnRangeError(scope: Scope) =
  let message = "main return Int must fit in int64"
  var props = initPropTable()
  props["message"] = newStr(message)
  props["where"] = newStr("main return")
  props["expected"] = newStr("int64-range Int")
  props["actual"] = newStr("Int")
  var head = newSym("TypeError")
  var typeError: Value
  if scope.lookupOptional("TypeError", typeError) and typeError.kind == vkType:
    head = typeError
  var e: ref GeneError
  new(e)
  e.msg = "TypeError: " & message
  e.errVal = newNode(head, props = props)
  e.hasErrVal = true
  raise e

proc exitFromMain(scope: Scope, value: Value) =
  case value.kind
  of vkNil:
    discard
  of vkInt:
    if not value.intFitsInt64:
      raiseMainReturnRangeError(scope)
    quit(int(value.intVal))
  else:
    raiseMainReturnTypeError(scope, value)

proc cmdRun(path: string, args: openArray[string] = []) =
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  var app: Application = nil
  var replScope: Scope = nil
  try:
    let absPath = normalizedPath(absolutePath(path))
    app = newApplication(parentDir(absPath))
    let entryModule = app.loadFileModule(absPath)
    let scope = entryModule.moduleRootNamespace.nsScope
    replScope = scope
    var mainBinding: Value
    if scope.lookupOptional("main", mainBinding):
      let invocation = splitMainInvocation(args)
      var grantNames: seq[string]
      var grantValues: seq[Value]
      for grant in invocation.grants:
        grantNames.add grant.name
        grantValues.add run(compileEvalSource(grant.expr,
                                              sourceName = "<main-grant:" &
                                                grant.name & ">"), scope)
      let positional =
        if mainBinding.kind == vkFunction and mainBinding.fnParams.len == 0:
          newSeq[Value]()
        else:
          @[argsValue(invocation.args)]
      let result = mainBinding.call(positional, grantNames, grantValues, scope)
      exitFromMain(scope, result)
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    maybeReplOnError(replScope, app)
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
    maybeReplOnError(replScope, app)
    quit(1)

proc cmdParse(path: string) =
  let src = readSourceFile(path)
  try:
    for f in readAll(src, normalizedPath(absolutePath(path))):
      echo f.print()
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)

proc cmdFmt(path: string) =
  ## Human-friendly formatting (src/gene/fmt.nim): wrapped/indented forms,
  ## reader sugar restored, comments preserved. `gene parse` stays canonical.
  let src = readSourceFile(path)
  let absPath = normalizedPath(absolutePath(path))
  try:
    stdout.write formatSource(src, absPath)
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)

proc cmdCompile(path: string) =
  let absPath = normalizedPath(absolutePath(path))
  try:
    let app = newApplication(parentDir(absPath))
    echo app.compileFileModule(absPath).disassemble()
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
    quit(1)

proc cmdCompileC(path: string) =
  let absPath = normalizedPath(absolutePath(path))
  try:
    let app = newApplication(parentDir(absPath))
    echo app.compileFileModule(absPath).emitExperimentalC()
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
    quit(1)

proc docDeclarationNames(scope: Scope, includeThisModule = false): seq[string] =
  scope.materializeMirroredVars()
  for name in scope.vars.keys:
    if includeThisModule or name != "this_mod":
      result.add name
  result.sort()

proc writeDocDeclarations(scope: Scope, includeThisModule = false) =
  for name in docDeclarationNames(scope, includeThisModule):
    echo "- " & name & " : " & declarationKind(scope.vars[name])

proc collectDocNamespaces(ns: Value, prefix: string,
                          namespaces: var seq[tuple[path: string, ns: Value]]) =
  for name in docDeclarationNames(ns.nsScope):
    let value = ns.nsScope.vars[name]
    if value.kind == vkNamespace:
      let path = if prefix.len == 0: name else: prefix & "/" & name
      namespaces.add (path: path, ns: value)
      collectDocNamespaces(value, path, namespaces)

proc collectDocImports(chunk: Chunk, imports: var seq[ImportSpec]) =
  if chunk == nil:
    return
  for spec in chunk.imports:
    imports.add spec
  for subchunk in chunk.subchunks:
    collectDocImports(subchunk, imports)
  for fn in chunk.functions:
    collectDocImports(fn.chunk, imports)
  for loop in chunk.forLoops:
    collectDocImports(loop.body, imports)
  for match in chunk.matches:
    for clause in match.clauses:
      collectDocImports(clause.body, imports)
    collectDocImports(match.elseBody, imports)
  for attempt in chunk.tries:
    collectDocImports(attempt.body, imports)
    for clause in attempt.catches:
      collectDocImports(clause.body, imports)
    collectDocImports(attempt.ensureBody, imports)

proc docSelectionText(sel: ImportSelection): string =
  if sel.name == sel.local:
    sel.name
  else:
    sel.name & " : " & sel.local

proc docImportText(app: Application, spec: ImportSpec): string =
  if spec.fromModule:
    result = "- from \"" & spec.modulePath & "\" -> " &
      app.resolveModulePath(spec.modulePath)
  else:
    result = "- " & spec.nsSegments.join("/")
  if spec.alias.len > 0:
    result.add " ^as " & spec.alias
  if spec.selections.len > 0:
    var selections: seq[string]
    for sel in spec.selections:
      selections.add docSelectionText(sel)
    result.add " [" & selections.join(", ") & "]"

proc writeDocImports(app: Application, chunk: Chunk) =
  var imports: seq[ImportSpec]
  collectDocImports(chunk, imports)
  if imports.len > 0:
    echo "Imports:"
    for spec in imports:
      echo docImportText(app, spec)

proc cmdDoc(path: string) =
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  try:
    let absPath = normalizedPath(absolutePath(path))
    let app = newApplication(parentDir(absPath))
    let chunk = compileSource(readSourceFile(absPath), absPath)
    let module = app.loadFileModule(absPath)
    echo "Module: " & module.moduleName
    echo "Path: " & module.modulePath
    let meta = module.moduleMeta
    if meta.hasKey("doc") and meta["doc"].kind == vkString:
      echo "Doc: " & meta["doc"].strVal
    writeDocImports(app, chunk)
    echo "Declarations:"
    let rootScope = module.moduleRootNamespace.nsScope
    writeDocDeclarations(rootScope)
    var namespaces: seq[tuple[path: string, ns: Value]]
    collectDocNamespaces(module.moduleRootNamespace, "", namespaces)
    if namespaces.len > 0:
      echo "Namespaces:"
      for item in namespaces:
        echo "Namespace " & item.path & ":"
        writeDocDeclarations(item.ns.nsScope)
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
    quit(1)

proc main() =
  resetLogging()
  defer: shutdownLogging()
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
  of "repl":
    var useCurses = false
    if paramCount() >= 2:
      for i in 2 .. paramCount():
        case paramStr(i)
        of "--curses":
          useCurses = true
        else:
          stderr.writeLine "Error: unknown repl option: " & paramStr(i)
          quit(1)
    cmdRepl(useCurses)
  of "run":
    var options: RunCli
    try:
      options = parseRunCli()
      configureRunLogging(options)
    except CatchableError as e:
      stderr.writeLine "Error: " & e.msg
      quit(1)
    cmdRun(options.path, options.args)
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
    if paramStr(2) == "--target":
      if paramCount() < 4:
        stderr.writeLine "Error: 'compile --target' needs a target and file path"
        quit(1)
      if paramStr(3) != "c":
        stderr.writeLine "Error: unsupported compile target: " & paramStr(3)
        quit(1)
      cmdCompileC(paramStr(4))
    elif paramStr(2) == "--c":
      if paramCount() < 3:
        stderr.writeLine "Error: 'compile --c' needs a file path"
        quit(1)
      cmdCompileC(paramStr(3))
    else:
      cmdCompile(paramStr(2))
  of "doc":
    if paramCount() < 2:
      stderr.writeLine "Error: 'doc' needs a file path"
      quit(1)
    cmdDoc(paramStr(2))
  of "view":
    try:
      quit(viewer_app.runViewer(parseViewCli()))
    except CatchableError as error:
      stderr.writeLine "Error: " & error.msg
      quit(1)
  of "lsp":
    configureLspLogging()
    quit(runLspServer())
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
