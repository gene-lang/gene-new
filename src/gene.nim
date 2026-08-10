## Gene language CLI entry point.
##
## Subcommands (a subset of design Section 18):
##   gene eval "<src>"   evaluate a source string, print the result
##   gene repl           read/eval/print source lines from stdin
##   gene run  <file>    load and execute a .gene file, then call main if present
##   gene runurl <url>   (experimental) run a remote entry module (design §15.9)
##   gene parse <file>   read and print canonical forms (no execution)
##   gene fmt <file>     format source through the canonical printer
##   gene compile <file> print compiled GIR bytecode (no execution)
##   gene compile --target c <file> print experimental typed_native C
##   gene doc <file>     print module metadata, imports, and declarations

import std/[algorithm, os, osproc, sets, streams, strutils, tables]
import gene/[build, compiler, diagnostics, document_units, fmt, gir, package,
             packed_format, printer, program_document, reader, repl,
             repl_curses, logging, logging_config, system_dependency, types,
             vm, web]
# Imported for its side effect: the typed_native AOT boundary helpers are
# {.exportc, dynlib.}, and importing the module is what puts them in this
# executable's dynamic symbol table for a dlopened AOT library to resolve.
import gene/aot_runtime
import gene/lsp/server as lsp_server
import gene/viewer/app as viewer_app

proc usage() =
  echo "Gene — a homoiconic general purpose language"
  echo ""
  echo "Usage:"
  echo "  gene eval \"<source>\"   evaluate a source string and print the result"
  echo "  gene repl [--curses]   read/eval/print source lines from stdin"
  echo "  gene run [--log-config path] [--package-root dir] [--debug] <file.gene>"
  echo "           [--grant name=expr] [--] [args...]"
  echo "                              execute a file and explicitly grant main capabilities"
  echo "  gene runurl <https-url> [args...]  (experimental) run a remote entry module;"
  echo "                              relative imports resolve against the module's URL"
  echo "  gene parse <file.gene>  print canonical parsed forms"
  echo "  gene fmt <file.gene>    human-friendly format: sugar restored, comments kept"
  echo "  gene docpack <file.gene> -o <out>  encode a reversible packed document"
  echo "                              (docs/proposals/reversible-ai-native-program-format.md)"
  echo "  gene docunpack <file>    decode a packed document to canonical .gene"
  echo "  gene compile <file.gene> print compiled GIR bytecode"
  echo "  gene compile --target c <file.gene> print experimental typed_native C"
  echo "  gene build [target] [options] build a package product"
  echo "  gene build --all [options] build every workspace product"
  echo "  gene build --target web [--out-dir dir] <file.gene> emit web ESM + types"
  echo "  gene test [selector]     build and run package tests"
  echo "  gene clean               remove project build views and sandboxes"
  echo "  gene doc <file.gene>    print module metadata, imports, and declarations"
  echo "  gene pkg <command>      init/add/remove/resolve/update/sync/vendor/members/tree/why"
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
  packageRoot: string
  debugging: bool
  targetTriple: string
  profile: string
  mode: BuildMode
  sealed: bool
  open: bool
  debugInfo: string
  locked: bool
  offline: bool
  preferBinary: bool
  sourceOnly: bool
  rebuild: bool
  explain: bool
  jobs: int

proc parseRunCli(label = "run", pathNoun = "a file path",
                 pathRequired = true): RunCli =
  result.profile = "dev"
  result.mode = bmVm
  var profileExplicit = false
  var release = false
  var i = 2
  while i <= paramCount() and result.path.len == 0:
    let arg = paramStr(i)
    case arg
    of "--log-config", "--package-root", "--target", "--profile", "--mode",
       "--debug_info", "--jobs":
      inc i
      if i > paramCount():
        raise newException(ValueError, arg & " expects a value")
      let value = paramStr(i)
      case arg
      of "--log-config": result.logConfig = value
      of "--package-root": result.packageRoot = value
      of "--target": result.targetTriple = value
      of "--profile":
        result.profile = value
        profileExplicit = true
      of "--mode":
        case value
        of "vm": result.mode = bmVm
        of "mixed": result.mode = bmMixed
        else: raise newException(ValueError, "--mode expects vm or mixed")
      of "--debug_info": result.debugInfo = value
      of "--jobs": result.jobs = parseInt(value)
      else: discard
    of "--debug":
      result.debugging = true
    of "--sealed": result.sealed = true
    of "--open": result.open = true
    of "--locked": result.locked = true
    of "--offline": result.offline = true
    of "--prefer_binary": result.preferBinary = true
    of "--source": result.sourceOnly = true
    of "--rebuild": result.rebuild = true
    of "--explain": result.explain = true
    of "--release": release = true
    else:
      if arg.startsWith("--log-config="):
        result.logConfig = arg[13 .. ^1]
      elif arg.startsWith("--package-root="):
        result.packageRoot = arg[15 .. ^1]
      elif arg.startsWith("--target="):
        result.targetTriple = arg[9 .. ^1]
      elif arg.startsWith("--profile="):
        result.profile = arg[10 .. ^1]
        profileExplicit = true
      elif arg.startsWith("--mode="):
        case arg[7 .. ^1]
        of "vm": result.mode = bmVm
        of "mixed": result.mode = bmMixed
        else: raise newException(ValueError, "--mode expects vm or mixed")
      elif arg.startsWith("--debug_info="):
        result.debugInfo = arg[13 .. ^1]
      elif arg.startsWith("--jobs="):
        result.jobs = parseInt(arg[7 .. ^1])
      elif arg.startsWith("-"):
        raise newException(ValueError, "unknown run option: " & arg)
      else:
        result.path = arg
    inc i
  if result.sealed and result.open:
    raise newException(ValueError, "--sealed and --open conflict")
  if result.preferBinary and result.sourceOnly:
    raise newException(ValueError, "--prefer_binary and --source conflict")
  if release and profileExplicit:
    raise newException(ValueError, "--release conflicts with --profile")
  if release:
    result.profile = "release"
  if result.jobs < 0:
    raise newException(ValueError, "--jobs cannot be negative")
  if pathRequired and result.path.len == 0:
    raise newException(ValueError, "'" & label & "' needs " & pathNoun)
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

proc invokeEntryMain(scope: Scope, args: openArray[string]) =
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

proc applicationForEntry(absPath, packageRootOverride: string): Application =
  ## Package discovery for a file-oriented command (proposal §4). An explicit
  ## `--package-root` replaces the discovery start directory; it never changes
  ## the process working directory, and the entry file must be inside it.
  ## Without an override the root is an ancestor of the entry's directory by
  ## construction, so the containment check only bites here and on `import`.
  if packageRootOverride.len == 0:
    return newApplicationForEntryFile(absPath)
  let root = normalizedPath(absolutePath(packageRootOverride))
  if not dirExists(root):
    raise newException(GeneError, "--package-root is not a directory: " &
                       packageRootOverride)
  result = newApplication(root)
  result.requireEntryWithinPackage(absPath)

proc cmdRun(path: string, args: openArray[string] = [],
            packageRootOverride = "") =
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  var app: Application = nil
  var replScope: Scope = nil
  try:
    let absPath = normalizedPath(absolutePath(path))
    app = applicationForEntry(absPath, packageRootOverride)
    let entryModule = app.loadFileModule(absPath)
    let scope = entryModule.moduleRootNamespace.nsScope
    replScope = scope
    invokeEntryMain(scope, args)
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

proc cmdRunUrl(url: string, args: openArray[string] = [],
               packageRootOverride = "") =
  ## Experimental URL entry (design §15.9): run a remote module graph. URL
  ## sources are enabled only for this entry; `gene run` never fetches, and
  ## package resolution never fetches for either entry. A URL entry has no
  ## entry file, so its application package is discovered from the launch
  ## working directory (proposal §4, §13).
  if not (url.startsWith("https://") or url.startsWith("http://")):
    stderr.writeLine "Error: 'runurl' needs an https:// (or localhost http://) URL"
    quit(1)
  var app: Application = nil
  var replScope: Scope = nil
  try:
    app = newApplication(if packageRootOverride.len > 0: packageRootOverride
                         else: getCurrentDir())
    app.allowUrlModules = true
    let entryModule = app.loadUrlModule(url)
    let scope = entryModule.moduleRootNamespace.nsScope
    replScope = scope
    invokeEntryMain(scope, args)
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

proc cmdDocPack(path: string, outPath: string) =
  ## docs/proposals/reversible-ai-native-program-format.md packed format:
  ## read `path` into a ProgramDocument (form tree + positional comments) and
  ## write its packed binary encoding to `outPath`.
  let src = readSourceFile(path)
  let absPath = normalizedPath(absolutePath(path))
  try:
    let doc = readDocument(src, absPath)
    let packed = encodePacked(doc)
    writeFile(outPath, packed)
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)
  except PackedError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

proc cmdDocUnits(path: string, outPath: string) =
  ## docs/proposals/reversible-ai-native-program-format.md model-native
  ## logical unit export (src/gene/document_units.nim): JSON Lines, one flat
  ## unit per line, for a training data loader to consume directly.
  let src = readSourceFile(path)
  let absPath = normalizedPath(absolutePath(path))
  try:
    let doc = readDocument(src, absPath)
    let units = unitsOf(doc)
    writeFile(outPath, toJsonLines(units))
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)
  except DocumentUnitsError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

proc cmdDocUnpack(path: string) =
  ## Inverse of `gene pack`: decode a packed document and print its
  ## canonical `.gene` projection.
  let data =
    try: readFile(path)
    except IOError as e:
      stderr.writeLine "Error: " & e.msg
      quit(1)
  try:
    let doc = decodePacked(data)
    stdout.write writeCanonical(doc)
  except PackedError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

proc cmdCompile(path: string) =
  let absPath = normalizedPath(absolutePath(path))
  try:
    let app = newApplicationForEntryFile(absPath)
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
    let app = newApplicationForEntryFile(absPath)
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

type BuildWebCli = object
  path: string
  outDir: string

proc parseBuildWebCli(): BuildWebCli =
  result.outDir = "dist"
  var target = ""
  var i = 2
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--target", "--out-dir":
      inc i
      if i > paramCount():
        raise newException(ValueError, arg & " expects a value")
      if arg == "--target": target = paramStr(i)
      else: result.outDir = paramStr(i)
    else:
      if arg.startsWith("--target="):
        target = arg[9 .. ^1]
      elif arg.startsWith("--out-dir="):
        result.outDir = arg[10 .. ^1]
      elif arg.startsWith("-"):
        raise newException(ValueError, "unknown build option: " & arg)
      elif result.path.len == 0:
        result.path = arg
      else:
        raise newException(ValueError, "build accepts one entry file")
    inc i
  if target != "web":
    raise newException(ValueError, "unsupported build target: " & target)
  if result.path.len == 0:
    raise newException(ValueError, "'build --target web' needs a file path")

proc cmdBuildWeb(options: BuildWebCli) =
  try:
    let outputs = buildWebModule(options.path, options.outDir)
    for output in outputs:
      echo normalizedPath(output)
  except ReadError as e:
    stderr.writeLine formatDiagnostic("Read error", e.msg, e.readErrorLoc)
    quit(1)
  except WebProfileError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)
  except CatchableError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

type ProjectBuildCli = object
  product: string
  packageRoot: string
  targetTriple: string
  profile: string
  profileExplicit: bool
  mode: BuildMode
  debugInfo: string
  all: bool
  sealed: bool
  open: bool
  locked: bool
  offline: bool
  preferBinary: bool
  sourceOnly: bool
  rebuild: bool
  explain: bool
  verifyReproducible: bool
  jobs: int

proc isDirectWebBuild(): bool =
  var i = 2
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--target" and i < paramCount() and paramStr(i + 1) == "web":
      return true
    if arg == "--target=web":
      return true
    inc i

proc parseProjectBuildCli(label = "build"): ProjectBuildCli =
  result.profile = "dev"
  result.mode = bmVm
  var profileExplicit = false
  var release = false
  var i = 2
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--target", "--profile", "--mode", "--debug_info", "--jobs",
       "--package-root":
      inc i
      if i > paramCount():
        raise newException(ValueError, arg & " expects a value")
      let value = paramStr(i)
      case arg
      of "--target": result.targetTriple = value
      of "--profile":
        result.profile = value
        profileExplicit = true
        result.profileExplicit = true
      of "--mode":
        case value
        of "vm": result.mode = bmVm
        of "mixed": result.mode = bmMixed
        else: raise newException(ValueError, "--mode expects vm or mixed")
      of "--debug_info": result.debugInfo = value
      of "--jobs": result.jobs = parseInt(value)
      of "--package-root": result.packageRoot = value
      else: discard
    of "--all": result.all = true
    of "--sealed": result.sealed = true
    of "--open": result.open = true
    of "--locked": result.locked = true
    of "--offline": result.offline = true
    of "--prefer_binary": result.preferBinary = true
    of "--source": result.sourceOnly = true
    of "--rebuild": result.rebuild = true
    of "--explain": result.explain = true
    of "--verify_reproducible": result.verifyReproducible = true
    of "--release": release = true
    else:
      if arg.startsWith("--target="):
        result.targetTriple = arg[9 .. ^1]
      elif arg.startsWith("--profile="):
        result.profile = arg[10 .. ^1]
        profileExplicit = true
        result.profileExplicit = true
      elif arg.startsWith("--mode="):
        let value = arg[7 .. ^1]
        case value
        of "vm": result.mode = bmVm
        of "mixed": result.mode = bmMixed
        else: raise newException(ValueError, "--mode expects vm or mixed")
      elif arg.startsWith("--debug_info="):
        result.debugInfo = arg[13 .. ^1]
      elif arg.startsWith("--jobs="):
        result.jobs = parseInt(arg[7 .. ^1])
      elif arg.startsWith("--package-root="):
        result.packageRoot = arg[15 .. ^1]
      elif arg.startsWith("-"):
        raise newException(ValueError, "unknown " & label & " option: " & arg)
      elif result.product.len == 0:
        result.product = arg
      else:
        raise newException(ValueError,
          label & " accepts at most one target or selector")
    inc i
  if result.all and result.product.len > 0:
    raise newException(ValueError, "--all conflicts with a product target")
  if result.sealed and result.open:
    raise newException(ValueError, "--sealed and --open conflict")
  if result.preferBinary and result.sourceOnly:
    raise newException(ValueError, "--prefer_binary and --source conflict")
  if release and profileExplicit:
    raise newException(ValueError, "--release conflicts with --profile")
  if release:
    result.profile = "release"
    result.profileExplicit = true
  if result.jobs < 0:
    raise newException(ValueError, "--jobs cannot be negative")

proc materializeProject(start: string, locked, offline,
                        includeDevelopment: bool): MaterializedGraph =
  let root = workspaceRootFor(start)
  if root.kind == pkAdHoc:
    raise newException(ValueError,
      "project build requires a package.gene; use gene run for an ad-hoc file")
  let manager = newPackageManager()
  let resolution =
    if locked:
      manager.loadResolutionLock(start)
    else:
      let solved = manager.resolve(ResolveRequest(
        startDir: start, includeDevelopment: includeDevelopment,
        offline: offline))
      discard solved.writeResolutionLock()
      solved
  result = manager.sync(resolution, SyncPolicy(offline: offline,
                                               locked: locked))
  result.includeDevelopment = includeDevelopment
  result.includeBuild = false

proc projectBuildEngine(): BuildEngine =
  newBuildEngine(BuildEnvironment(
    artifactStore: newLocalArtifactStore(userArtifactStoreDir()),
    toolchains: newToolchainSet(runningCompilerIdentity(),
                               hostCPU & "-" & hostOS),
    systemDependencyProviders: newSystemDependencyResolver()))

proc buildRequest(options: ProjectBuildCli, packageId, target: string):
                  BuildRequest =
  BuildRequest(rootPackageId: packageId, target: target,
    targetTriple: options.targetTriple, profile: options.profile,
    mode: options.mode, sealed: options.sealed, open: options.open,
    debugInfo: options.debugInfo, preferBinary: options.preferBinary,
    sourceOnly: options.sourceOnly, rebuild: options.rebuild,
    verifyReproducible: options.verifyReproducible,
    maxParallelism: options.jobs)

proc declaredTargets(pkg: Package): seq[string] =
  if pkg.hasLibrary:
    result.add "library"
  for application in pkg.applications:
    result.add application.name

proc childBuildArgs(options: ProjectBuildCli, packageRoot,
                    target: string): seq[string] =
  result = @["build", target, "--package-root", packageRoot, "--locked",
             "--profile", options.profile, "--mode", $options.mode,
             "--jobs", "1"]
  if options.targetTriple.len > 0:
    result.add @["--target", options.targetTriple]
  if options.debugInfo.len > 0:
    result.add @["--debug_info", options.debugInfo]
  if options.sealed: result.add "--sealed"
  if options.open: result.add "--open"
  if options.offline: result.add "--offline"
  if options.preferBinary: result.add "--prefer_binary"
  if options.sourceOnly: result.add "--source"
  if options.rebuild: result.add "--rebuild"
  if options.explain: result.add "--explain"
  if options.verifyReproducible: result.add "--verify_reproducible"

proc runParallelBuilds(options: ProjectBuildCli, graph: MaterializedGraph,
                       work: seq[tuple[packageId, target: string]]) =
  ## Pure-Gene compiler actions are process-isolated so independent workspace
  ## products can build concurrently without sharing VM heaps. Outputs are
  ## collected and emitted in plan order for deterministic logs.
  let requested = if options.jobs > 0: options.jobs else: countProcessors()
  let parallelism = max(1, min(requested, work.len))
  type RunningBuild = object
    index: int
    process: Process
  var running: seq[RunningBuild]
  var outputs = newSeq[string](work.len)
  var statuses = newSeq[int](work.len)
  var next = 0
  while next < work.len or running.len > 0:
    while next < work.len and running.len < parallelism:
      let item = work[next]
      let packageRoot = graph.packagesById[item.packageId].root
      let process = startProcess(getAppFilename(), graph.workspaceRoot,
        args = childBuildArgs(options, packageRoot, item.target),
        options = {poStdErrToStdOut})
      running.add RunningBuild(index: next, process: process)
      inc next
    let current = running[0]
    outputs[current.index] = current.process.outputStream.readAll()
    statuses[current.index] = current.process.waitForExit()
    current.process.close()
    running.delete(0)
  var failed = false
  for i, output in outputs:
    stdout.write output
    if statuses[i] != 0:
      failed = true
  if failed:
    raise newException(ValueError,
      "one or more workspace products failed to build")

proc cmdProjectBuild(options: ProjectBuildCli) =
  let start =
    if options.packageRoot.len > 0: options.packageRoot else: getCurrentDir()
  let graph = materializeProject(start, options.locked, options.offline, false)
  let engine = projectBuildEngine()
  var work: seq[tuple[packageId, target: string]]
  if options.all:
    var roots = graph.rootPackageIds
    roots.sort(proc (a, b: string): int =
      cmp(graph.packagesById[a].root, graph.packagesById[b].root))
    for id in roots:
      for target in declaredTargets(graph.packagesById[id]):
        work.add (id, target)
  else:
    work.add (graph.activePackageId, options.product)
  if work.len == 0:
    raise newException(ValueError, "workspace declares no build targets")
  if options.all and work.len > 1 and options.jobs != 1:
    runParallelBuilds(options, graph, work)
    return
  for item in work:
    let built = engine.build(options.buildRequest(item.packageId, item.target),
                             graph)
    let artifact = built.rootArtifact
    echo "Built " & artifact.packageName & ":" & artifact.target & " -> " &
      built.projectView
    if options.explain:
      echo built.explanation

proc selectedApplication(pkg: Package, name: string): ApplicationTarget =
  if name.len == 0:
    if pkg.applications.len != 1:
      raise newException(ValueError,
        "run requires an application name unless the package declares exactly one")
    return pkg.applications[0]
  for application in pkg.applications:
    if application.name == name:
      return application
  raise newException(ValueError,
    "package has no application target named " & name)

proc cmdProjectRun(options: RunCli) =
  let start =
    if options.packageRoot.len > 0: options.packageRoot else: getCurrentDir()
  try:
    let graph = materializeProject(start, options.locked, options.offline,
                                   false)
    let pkg = graph.packagesById[graph.activePackageId]
    let application = selectedApplication(pkg, options.path)
    let engine = projectBuildEngine()
    let built = engine.build(BuildRequest(rootPackageId: pkg.id,
      target: application.name, targetTriple: options.targetTriple,
      profile: options.profile, mode: options.mode, sealed: options.sealed,
      open: options.open, debugInfo: options.debugInfo,
      preferBinary: options.preferBinary, sourceOnly: options.sourceOnly,
      rebuild: options.rebuild, maxParallelism: options.jobs), graph)
    if options.explain:
      echo built.explanation
    let executionGraph = built.executionGraph
    let executionPackage = executionGraph.packagesById[pkg.id]
    let app = newApplication(executionGraph, executionPackage.root)
    for artifact in built.artifacts:
      app.installCompiledModules(artifact.compiledModules)
    let chunk = built.rootArtifact.compiledChunk
    if chunk == nil:
      raise newException(ValueError,
        "build produced no executable GIR artifact")
    let entry = app.loadCompiledFileModule(
      executionPackage.root / application.entry, chunk)
    invokeEntryMain(entry.moduleRootNamespace.nsScope, options.args)
  except ReadError as error:
    stderr.writeLine formatDiagnostic("Read error", error.msg,
                                      error.readErrorLoc)
    quit(1)
  except GenePanic as error:
    stderr.writeLine "Panic: " & error.msg
    quit(1)
  except GeneError as error:
    stderr.writeLine formatDiagnostic("Error", error.msg, error.loc)
    quit(1)
  except CatchableError as error:
    stderr.writeLine "Error: " & error.msg
    quit(1)

proc cmdProjectTest(options: ProjectBuildCli) =
  try:
    if options.all:
      raise newException(ValueError, "gene test does not accept --all")
    let start =
      if options.packageRoot.len > 0: options.packageRoot else: getCurrentDir()
    let graph = materializeProject(start, options.locked, options.offline, true)
    let pkg = graph.packagesById[graph.activePackageId]
    if not pkg.hasTests:
      raise newException(ValueError, pkg.name & " has no ^tests target")
    let testRoot = pkg.root / pkg.tests.root
    if not dirExists(testRoot):
      raise newException(ValueError, "test root does not exist: " & testRoot)
    var paths: seq[string]
    let selector = options.product
    for path in walkDirRec(testRoot, yieldFilter = {pcFile}):
      let relative = relativePath(path, pkg.root).replace('\\', '/')
      if path.endsWith(".gene") and
          (selector.len == 0 or selector in relative):
        paths.add relative
    paths.sort()
    if paths.len == 0:
      raise newException(ValueError, "no package tests matched: " & selector)
    let engine = projectBuildEngine()
    for relative in paths:
      var request = options.buildRequest(pkg.id, "test")
      request.testEntry = relative
      if not options.profileExplicit:
        request.profile = "test"
      let built = engine.build(request, graph)
      if options.explain:
        echo built.explanation
      let executionGraph = built.executionGraph
      let executionPackage = executionGraph.packagesById[pkg.id]
      let app = newApplication(executionGraph, executionPackage.root)
      for artifact in built.artifacts:
        app.installCompiledModules(artifact.compiledModules)
      let chunk = built.rootArtifact.compiledChunk
      if chunk == nil:
        raise newException(ValueError,
          "build produced no executable GIR artifact")
      let entry = app.loadCompiledFileModule(
        executionPackage.root / relative, chunk)
      invokeEntryMain(entry.moduleRootNamespace.nsScope, @[])
      echo "[OK] " & relative
  except ReadError as error:
    stderr.writeLine formatDiagnostic("Read error", error.msg,
                                      error.readErrorLoc)
    quit(1)
  except GenePanic as error:
    stderr.writeLine "Panic: " & error.msg
    quit(1)
  except GeneError as error:
    stderr.writeLine formatDiagnostic("Error", error.msg, error.loc)
    quit(1)
  except CatchableError as error:
    stderr.writeLine "Error: " & error.msg
    quit(1)

proc cmdClean() =
  let root = workspaceRootFor(getCurrentDir()).root
  var removed: seq[string]
  for path in [root / ".gene" / "build", root / ".gene" / "sandboxes"]:
    if dirExists(path):
      removeDir(path)
      removed.add path
  if removed.len == 0:
    echo "Project build view is already clean"
  else:
    for path in removed:
      echo "Removed " & path

proc unavailableBuildFeature(command: string) =
  stderr.writeLine "Error: BUILD_FEATURE_UNAVAILABLE: 'gene " & command &
    "' has not passed its demand gate"
  quit(1)

proc docDeclarationNames(scope: Scope, includeThisModule = false): seq[string] =
  scope.materializeMirroredVars()
  for name in scope.vars.keys:
    if includeThisModule or name notin ["this_mod", "this_pkg"]:
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
    result = "- from \"" & spec.modulePath & "\""
    if spec.pkgName.len > 0:
      result.add " ^pkg \"" & spec.pkgName & "\""
    result.add " -> " & app.resolveModuleRef(spec.modulePath, spec.pkgName)
  else:
    result = "- " & spec.nsSegments.join("/")
  if spec.alias.len > 0:
    result.add " : " & spec.alias
  elif spec.wildcard:
    result.add " *"
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
    let app = newApplicationForEntryFile(absPath)
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

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# gene pkg (docs/proposals/package.md §11)
# ---------------------------------------------------------------------------

type PkgCli = object
  action: string
  arguments: seq[string]
  packageRoot: string
  locked: bool
  offline: bool
  workspace: bool
  dependencyPath: string
  initKind: string

proc parsePkgCli(): PkgCli =
  var i = 2
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--package-root":
      inc i
      if i > paramCount():
        raise newException(ValueError, "--package-root expects a path")
      result.packageRoot = paramStr(i)
    of "--path":
      inc i
      if i > paramCount():
        raise newException(ValueError, "--path expects a path")
      result.dependencyPath = paramStr(i)
    of "--locked": result.locked = true
    of "--offline": result.offline = true
    of "--workspace": result.workspace = true
    of "--lib", "--app", "--mixed":
      if result.initKind.len > 0:
        raise newException(ValueError,
          "choose exactly one of --lib, --app, or --mixed")
      result.initKind = arg[2 .. ^1]
    else:
      if arg.startsWith("--package-root="):
        result.packageRoot = arg[15 .. ^1]
      elif arg.startsWith("--path="):
        result.dependencyPath = arg[7 .. ^1]
      elif arg.startsWith("-"):
        raise newException(ValueError, "unknown pkg option: " & arg)
      elif result.action.len == 0:
        result.action = arg
      else:
        result.arguments.add arg
    inc i
  if result.action.len == 0:
    raise newException(ValueError,
      "'pkg' needs a subcommand: init, add, remove, resolve, update, sync, " &
      "vendor, members, tree, why, publish, or cache")

proc pkgStart(options: PkgCli): string =
  if options.packageRoot.len > 0: options.packageRoot else: getCurrentDir()

proc pkgResolution(manager: PackageManager, start: string): Resolution =
  let lockPath = packageLockPathFor(start)
  if fileExists(lockPath): manager.loadResolutionLock(start)
  else: manager.resolve(ResolveRequest(startDir: start))

proc cmdPkgResolve(options: PkgCli) =
  let start = options.pkgStart()
  let manager = newPackageManager()
  if options.action == "resolve" and options.arguments.len > 0:
    raise newException(ValueError, "'pkg resolve' accepts no arguments")
  if options.action == "update" and options.arguments.len > 1:
    raise newException(ValueError, "'pkg update' accepts at most one alias")
  if options.action == "update" and options.locked:
    raise newException(ValueError, "--locked forbids dependency updates")
  if options.locked:
    let resolution = manager.loadResolutionLock(start)
    echo "Lock is current: " & packageLockPathFor(start)
    echo "Instances: " & $resolution.packagesById.len
    return
  let unlocked =
    if options.action == "update": options.arguments
    else: @[]
  let resolution = manager.resolve(ResolveRequest(startDir: start,
                                                  unlockAliases: unlocked,
                                                  unlockAll:
                                                    options.action == "update" and
                                                    unlocked.len == 0,
                                                  offline: options.offline))
  let lockPath = resolution.writeResolutionLock()
  echo "Resolved " & $resolution.packagesById.len & " package instance(s)"
  echo "Lock: " & lockPath

proc cmdPkgSync(options: PkgCli): MaterializedGraph =
  let start = options.pkgStart()
  let manager = newPackageManager()
  let resolution = manager.loadResolutionLock(start)
  result = manager.sync(resolution,
    SyncPolicy(offline: options.offline, locked: options.locked))
  echo "Synchronized " & $result.packagesById.len & " package instance(s)"

proc cmdPkgVendor(options: PkgCli) =
  let graph = cmdPkgSync(options)
  let manager = newPackageManager()
  let receipt = manager.vendor(graph, VendorRequest())
  echo "Vendored " & $receipt.packagePaths.len & " immutable package object(s)"
  echo "Vendor root: " & receipt.root

proc cmdPkgMembers(options: PkgCli) =
  let start = options.pkgStart()
  let root = workspaceRootFor(start)
  echo root.name & " " & root.root
  for member in workspaceMembers(start):
    echo member.name & " " & member.root

proc cmdPkgTree(options: PkgCli) =
  let start = options.pkgStart()
  let manager = newPackageManager()
  let resolution = manager.pkgResolution(start)
  var ids: seq[string]
  for id in resolution.packagesById.keys:
    ids.add id
  ids.sort()
  for id in ids:
    let pkg = resolution.packagesById[id]
    let marker = if id == resolution.activePackageId: "* " else: "  "
    echo marker & pkg.name & " " & pkg.version & " [" & id & "]"
    var aliases: seq[string]
    for alias in pkg.dependencyEdges.keys:
      aliases.add alias
    aliases.sort()
    for alias in aliases:
      echo "    " & alias & " -> " & pkg.dependencyEdges[alias]

proc cmdPkgWhy(options: PkgCli) =
  if options.arguments.len != 1:
    raise newException(ValueError, "'pkg why' needs one package name or id")
  let needle = options.arguments[0]
  let manager = newPackageManager()
  let resolution = manager.pkgResolution(options.pkgStart())
  type PathItem = tuple[id, path: string]
  var pending: seq[PathItem]
  var seen = initHashSet[string]()
  pending.add (resolution.activePackageId,
               resolution.packagesById[resolution.activePackageId].name)
  var found = false
  while pending.len > 0:
    let item = pending[0]
    pending.delete(0)
    if item.id in seen:
      continue
    seen.incl item.id
    let pkg = resolution.packagesById[item.id]
    if item.id == needle or pkg.name == needle:
      echo item.path & " [" & item.id & "]"
      found = true
    var aliases: seq[string]
    for alias in pkg.dependencyEdges.keys:
      aliases.add alias
    aliases.sort()
    for alias in aliases:
      let target = pkg.dependencyEdges[alias]
      pending.add (target, item.path & " --" & alias & "--> " &
        resolution.packagesById[target].name)
  if not found:
    raise newException(ValueError, "package is not present in the graph: " & needle)

proc localPackageName(path: string): string =
  var name = extractFilename(normalizedPath(absolutePath(path))).toLowerAscii()
  for ch in name.mitems:
    if ch notin {'a' .. 'z', '0' .. '9', '_'}:
      ch = '_'
  while name.len > 0 and name[0] == '_':
    name = if name.len == 1: "" else: name[1 .. ^1]
  if name.len == 0:
    name = "package"
  "local/" & name

proc registerWorkspaceMember(memberRoot: string):
    tuple[manifestPath, original: string, changed: bool] =
  let parentManifestRoot = findManifestDir(parentDir(memberRoot))
  if parentManifestRoot.len == 0:
    return
  let workspaceRoot = workspaceRootFor(parentDir(memberRoot))
  if workspaceRoot.kind != pkRegular or workspaceRoot.root == memberRoot or
      not containsPath(workspaceRoot.realRoot, canonicalPath(memberRoot)):
    return
  result.manifestPath = workspaceRoot.manifestPath
  result.original = readFile(result.manifestPath)
  let forms = readAll(result.original, result.manifestPath,
                      ReadOptions(rejectDuplicateProps: true))
  if forms.len != 1 or forms[0].kind != vkMap:
    raise newException(ValueError, "workspace package.gene must contain one map")
  var manifest = initPropTable()
  for key, value in forms[0].mapEntries:
    manifest[key] = value
  var workspace = initPropTable()
  var members: seq[Value]
  if manifest.hasKey("workspace"):
    if manifest["workspace"].kind != vkMap:
      raise newException(ValueError, "^workspace must be a map")
    for key, value in manifest["workspace"].mapEntries:
      workspace[key] = value
    if workspace.hasKey("members"):
      if workspace["members"].kind != vkList:
        raise newException(ValueError, "^workspace.^members must be a list")
      members = workspace["members"].listItems
  let relative = relativePath(memberRoot, workspaceRoot.root).replace('\\', '/')
  for value in members:
    if value.kind == vkString and
        workspaceMemberMatches(value.strVal, relative):
      return
  members.add newStr(relative)
  workspace["members"] = newList(members)
  manifest["workspace"] = newMap(workspace)
  writeFile(result.manifestPath, newMap(manifest).print() & "\n")
  result.changed = true

proc cmdPkgInit(options: PkgCli) =
  if options.initKind.len == 0:
    raise newException(ValueError,
      "'pkg init' requires exactly one of --lib, --app, or --mixed")
  if options.arguments.len > 1:
    raise newException(ValueError, "'pkg init' accepts at most one directory")
  let root = normalizedPath(absolutePath(
    if options.arguments.len == 1: options.arguments[0]
    else: options.pkgStart()))
  let manifestPath = root / ManifestFileName
  if fileExists(manifestPath):
    raise newException(ValueError, "package already exists: " & manifestPath)
  createDir(root)
  let name = localPackageName(root)
  var manifest = "{^format 1 ^name \"" & name & "\" ^version \"0.1.0\""
  if options.initKind in ["lib", "mixed"]:
    manifest.add " ^library {^entry \"src/index.gene\"}"
    createDir(root / "src")
    writeFile(root / "src/index.gene", "")
  if options.initKind in ["app", "mixed"]:
    manifest.add " ^applications [(application \"" & name.split('/')[1] &
      "\" ^entry \"src/main.gene\")]"
    createDir(root / "src")
    writeFile(root / "src/main.gene", "(fn main [] 0)\n")
  if options.initKind == "mixed":
    createDir(root / "packages")
  manifest.add "}\n"
  writeFile(manifestPath, manifest)
  let registration = registerWorkspaceMember(root)
  try:
    let resolution = newPackageManager().resolve(ResolveRequest(startDir: root))
    discard resolution.writeResolutionLock()
  except CatchableError:
    if registration.changed:
      writeFile(registration.manifestPath, registration.original)
    raise
  echo "Initialized " & name & " at " & root

proc parseDependencyCoordinate(text: string): tuple[alias, name, constraint: string] =
  let equals = text.find('=')
  let at = text.rfind('@')
  if equals <= 0 or at <= equals + 1 or at == text.high:
    raise newException(ValueError,
      "dependency must be <alias>=<owner/name>@<constraint>")
  result.alias = text[0 ..< equals]
  result.name = text[equals + 1 ..< at]
  result.constraint = text[at + 1 .. ^1]

proc rewriteDependencies(options: PkgCli, remove: bool) =
  if options.locked:
    raise newException(ValueError, "--locked forbids manifest and lock rewrites")
  if options.arguments.len != 1:
    raise newException(ValueError,
      "'pkg " & options.action & "' needs one dependency argument")
  let start = options.pkgStart()
  let packageRoot = findManifestDir(start)
  if packageRoot.len == 0:
    raise newException(ValueError, "no package.gene found from " & start)
  let manifestPath = packageRoot / ManifestFileName
  let original = readFile(manifestPath)
  let forms = readAll(original, manifestPath,
                      ReadOptions(rejectDuplicateProps: true))
  if forms.len != 1 or forms[0].kind != vkMap:
    raise newException(ValueError, "package.gene must contain one map")
  var manifestEntries = initPropTable()
  for key, value in forms[0].mapEntries:
    manifestEntries[key] = value
  var dependencies = initPropTable()
  if manifestEntries.hasKey("dependencies"):
    if manifestEntries["dependencies"].kind != vkMap:
      raise newException(ValueError, "^dependencies must be a map")
    for key, value in manifestEntries["dependencies"].mapEntries:
      dependencies[key] = value
  let alias =
    if remove: options.arguments[0]
    else: parseDependencyCoordinate(options.arguments[0]).alias
  if remove:
    if not dependencies.hasKey(alias):
      raise newException(ValueError, "dependency alias is not declared: " & alias)
    dependencies.del(alias)
  else:
    let coordinate = parseDependencyCoordinate(options.arguments[0])
    if dependencies.hasKey(coordinate.alias):
      raise newException(ValueError,
        "dependency alias is already declared: " & coordinate.alias)
    var props = initPropTable()
    if options.workspace:
      props["workspace"] = TRUE
    if options.dependencyPath.len > 0:
      props["path"] = newStr(options.dependencyPath)
    if options.workspace and options.dependencyPath.len > 0:
      raise newException(ValueError, "--workspace and --path are mutually exclusive")
    dependencies[coordinate.alias] = newNode(newSym("dep"), props,
      @[newStr(coordinate.name), newStr(coordinate.constraint)])
  manifestEntries["dependencies"] = newMap(dependencies)
  writeFile(manifestPath, newMap(manifestEntries).print() & "\n")
  try:
    let resolution = newPackageManager().resolve(ResolveRequest(startDir: packageRoot))
    discard resolution.writeResolutionLock()
  except CatchableError:
    writeFile(manifestPath, original)
    raise
  echo (if remove: "Removed " else: "Added ") & alias

proc cmdPkg() =
  var options: PkgCli
  try:
    options = parsePkgCli()
    case options.action
    of "init": cmdPkgInit(options)
    of "add": rewriteDependencies(options, false)
    of "remove": rewriteDependencies(options, true)
    of "resolve", "update": cmdPkgResolve(options)
    of "sync": discard cmdPkgSync(options)
    of "vendor": cmdPkgVendor(options)
    of "members": cmdPkgMembers(options)
    of "tree": cmdPkgTree(options)
    of "why": cmdPkgWhy(options)
    of "publish":
      raise newException(ValueError,
        "'pkg publish' requires a configured registry adapter")
    of "cache":
      if options.arguments != @["gc"]:
        raise newException(ValueError, "usage: gene pkg cache gc")
      let collected = newPackageManager().cacheGc()
      echo "Package cache GC: kept " & $collected.keptObjects &
        ", removed " & $collected.removedObjects &
        " object(s); removed " & $collected.removedRootReceipts &
        " stale root receipt(s)"
    else:
      raise newException(ValueError,
        "unknown pkg subcommand: " & options.action)
  except GeneError as e:
    stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
    quit(1)
  except CatchableError as e:
    stderr.writeLine "Error: " & e.msg
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
      options = parseRunCli(pathRequired = false)
      configureRunLogging(options)
    except CatchableError as e:
      stderr.writeLine "Error: " & e.msg
      quit(1)
    if options.path.len > 0 and fileExists(options.path):
      cmdRun(options.path, options.args, options.packageRoot)
    elif options.path.endsWith(".gapp"):
      stderr.writeLine "Error: BUILD_FEATURE_UNAVAILABLE: portable .gapp " &
        "execution is not implemented"
      quit(1)
    else:
      cmdProjectRun(options)
  of "runurl":
    var options: RunCli
    try:
      options = parseRunCli(label = "runurl", pathNoun = "an https:// URL")
      configureRunLogging(options)
    except CatchableError as e:
      stderr.writeLine "Error: " & e.msg
      quit(1)
    cmdRunUrl(options.path, options.args, options.packageRoot)
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
  of "docpack":
    if paramCount() < 4 or paramStr(3) != "-o":
      stderr.writeLine "Error: 'docpack' needs a file path and '-o <output>'"
      quit(1)
    cmdDocPack(paramStr(2), paramStr(4))
  of "docunpack":
    if paramCount() < 2:
      stderr.writeLine "Error: 'docunpack' needs a file path"
      quit(1)
    cmdDocUnpack(paramStr(2))
  of "docunits":
    if paramCount() < 4 or paramStr(3) != "-o":
      stderr.writeLine "Error: 'docunits' needs a file path and '-o <output>'"
      quit(1)
    cmdDocUnits(paramStr(2), paramStr(4))
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
  of "build":
    try:
      if isDirectWebBuild():
        cmdBuildWeb(parseBuildWebCli())
      else:
        cmdProjectBuild(parseProjectBuildCli())
    except GeneError as e:
      stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
      quit(1)
    except CatchableError as e:
      stderr.writeLine "Error: " & e.msg
      quit(1)
  of "test":
    try:
      cmdProjectTest(parseProjectBuildCli("test"))
    except GeneError as e:
      stderr.writeLine formatDiagnostic("Error", e.msg, e.loc)
      quit(1)
    except CatchableError as e:
      stderr.writeLine "Error: " & e.msg
      quit(1)
  of "clean":
    if paramCount() != 1:
      stderr.writeLine "Error: 'clean' accepts no arguments"
      quit(1)
    cmdClean()
  of "pack", "bundle", "inspect", "verify", "sign", "install",
     "uninstall", "rollback", "installed":
    unavailableBuildFeature(cmd)
  of "doc":
    if paramCount() < 2:
      stderr.writeLine "Error: 'doc' needs a file path"
      quit(1)
    cmdDoc(paramStr(2))
  of "pkg":
    cmdPkg()
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
