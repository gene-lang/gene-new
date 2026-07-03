## Gene language CLI entry point.
##
## Subcommands (a subset of design Section 18):
##   gene eval "<src>"   evaluate a source string, print the result
##   gene repl           read/eval/print source lines from stdin
##   gene run  <file>    load and execute a .gene file, then call main if present
##   gene parse <file>   read and print canonical forms (no execution)
##   gene fmt <file>     format source through the canonical printer
##   gene compile <file> print compiled GIR bytecode (no execution)
##   gene compile --target c <file> print experimental typed-native C
##   gene doc <file>     print module metadata, imports, and declarations

import std/[algorithm, os, strutils, tables]
import gene/[compiler, gir, printer, reader, repl, repl_curses, types, vm]

proc usage() =
  echo "Gene — a homoiconic general purpose language"
  echo ""
  echo "Usage:"
  echo "  gene eval \"<source>\"   evaluate a source string and print the result"
  echo "  gene repl [--curses]   read/eval/print source lines from stdin"
  echo "  gene run <file.gene> [args...] execute a file, then call main if present"
  echo "  gene parse <file.gene>  print canonical parsed forms"
  echo "  gene fmt <file.gene>    format source through the canonical printer"
  echo "  gene compile <file.gene> print compiled GIR bytecode"
  echo "  gene compile --target c <file.gene> print experimental typed-native C"
  echo "  gene doc <file.gene>    print module metadata, imports, and declarations"

proc readSourceFile(path: string): string =
  if not fileExists(path):
    stderr.writeLine "Error: file not found: " & path
    quit(1)
  readFile(path)

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
    echo run(compileEvalSource(src), scope).print()
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    maybeReplOnError(scope, app)
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine "Error: " & e.msg
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

proc argsList(args: openArray[string]): Value =
  var values = newSeq[Value](args.len)
  for i, arg in args:
    values[i] = newStr(arg)
  newList(values)

proc commandArgs(first: int): seq[string] =
  if first <= paramCount():
    for i in first .. paramCount():
      result.add paramStr(i)

proc raiseMainReturnTypeError(scope: Scope, value: Value) =
  let message = "main return expected Nil or Int, got " & $value.kind
  var props = initOrderedTable[string, Value]()
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
  var props = initOrderedTable[string, Value]()
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
      let result =
        if mainBinding.kind == vkFunction and mainBinding.fnParams.len == 0:
          mainBinding.call()
        else:
          mainBinding.call(@[argsList(args)])
      exitFromMain(scope, result)
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    maybeReplOnError(replScope, app)
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine "Error: " & e.msg
    maybeReplOnError(replScope, app)
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

proc cmdCompileC(path: string) =
  let src = readSourceFile(path)
  try:
    echo compileSource(src).emitExperimentalC()
  except ReadError as e:
    stderr.writeLine "Read error: " & e.msg
    quit(1)
  except GenePanic as e:
    stderr.writeLine "Panic: " & e.msg
    quit(1)
  except GeneError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

proc docDeclarationNames(scope: Scope, includeThisModule = false): seq[string] =
  for name in scope.vars.keys:
    if includeThisModule or name != "this-mod":
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
    let chunk = compileSource(readSourceFile(absPath))
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
