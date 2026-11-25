## Design check 6 for the `str` native namespace.
##
## `src/gene/lib/str.doc.gene` documents natives that have no source file of
## their own. It is read here with the reader only and never compiled or run.
## The declarations must name the natives the VM actually registers, carry a
## real `@doc` and an empty `^errors` row, and accept the arity they declare.
##
## Natives carry no arity metadata, so the arity is probed by calling each one
## with 0..declared_max+1 positional arguments. Only an `expects N argument(s)`
## failure counts as arity rejection; a type failure would not.
import std/[os, strutils, tables, unittest]
import gene/[compiler, reader, types, vm]
import tools/docs/builder as docBuilder
from tools/docs/model import ModuleDoc

proc strDeclRepoRoot(): string =
  normalizedPath(parentDir(currentSourcePath()) / "..")

const
  strDeclPath = parentDir(currentSourcePath()) / ".." /
    "src/gene/lib/str.doc.gene"
  strDeclExpectedNatives = 13

type
  StrDecl = object
    name: string
    forName: string
    doc: string
    sees: seq[string]
    required: int
    optional: int
    params: int
    typedParams: int
    hasReturn: bool
    errorsLen: int

  StrDeclTable = object
    moduleName: string
    moduleDoc: string
    moduleCount: int
    decls: seq[StrDecl]
    problems: seq[string]

proc strDeclProblem(table: var StrDeclTable, label, message: string) =
  table.problems.add label & ": " & message

proc strDeclArityRejection(message: string, got: var int): bool =
  ## True when `message` is a native's own arity check, e.g.
  ## `str/join expects 1..2 arguments, got 0` or
  ## `str/trim expects 1 argument, got 3`.
  const gotMarker = ", got "
  const expectsMarker = " expects "
  let gotAt = message.rfind(gotMarker)
  if gotAt < 0: return false
  try:
    got = parseInt(message[gotAt + gotMarker.len .. ^1])
  except ValueError:
    return false
  let expectsAt = message.find(expectsMarker)
  if expectsAt < 0 or expectsAt > gotAt: return false
  let declared = message[expectsAt + expectsMarker.len ..< gotAt]
  if declared.endsWith(" argument"):
    let count = declared[0 ..< declared.len - " argument".len]
    result = count.len > 0 and count.allCharsInSet(Digits)
  elif declared.endsWith(" arguments"):
    let span = declared[0 ..< declared.len - " arguments".len]
    let dots = span.find("..")
    if dots < 0:
      result = span.len > 0 and span.allCharsInSet(Digits)
    else:
      result = dots > 0 and
        span[0 ..< dots].allCharsInSet(Digits) and
        span[dots + 2 .. ^1].allCharsInSet(Digits)
  else:
    result = false

proc strDeclReadParams(params: Value, label: string, table: var StrDeclTable,
                       decl: var StrDecl) =
  ## Walks a declaration's parameter vector the way the compiler reads it:
  ## `name [: Type] [= default]`, separated by optional commas. The sidecar
  ## uses only positional parameters, which this asserts.
  if params.kind != vkList:
    table.strDeclProblem(label, "parameter list is not a List")
    return
  let items = params.listItems
  var i = 0
  while i < items.len:
    let item = items[i]
    if item.kind == vkSymbol and item.symVal in ["", ","]:
      inc i
      continue
    if item.kind != vkSymbol:
      table.strDeclProblem(label, "parameter is not a symbol")
      return
    if item.symVal in ["^", "^^"] or item.symVal.endsWith("..."):
      table.strDeclProblem(label, "str declarations use only positional parameters")
      return
    inc i
    inc decl.params
    if i < items.len and items[i].kind == vkSymbol and items[i].symVal == ":":
      inc decl.typedParams
      inc i
      if i >= items.len:
        table.strDeclProblem(label, "parameter type annotation is missing")
        return
      inc i
    if i < items.len and items[i].kind == vkSymbol and items[i].symVal == "=":
      inc decl.optional
      inc i
      if i >= items.len:
        table.strDeclProblem(label, "parameter default is missing")
        return
      inc i
    else:
      inc decl.required

proc strDeclRead(path: string): StrDeclTable =
  var unit: SourceUnit
  try:
    unit = readAllWithLocs(readFile(path), path)
  except CatchableError as error:
    result.strDeclProblem(path, "cannot read the sidecar: " & error.msg)
    return
  for index, form in unit.forms:
    let label = path & ":" & $unit.formLocs[index].line
    if form.kind != vkNode or form.head.kind != vkSymbol:
      result.strDeclProblem(label, "top-level form is not a node with a symbol head")
      continue
    case form.head.symVal
    of "mod":
      inc result.moduleCount
      if form.body.len >= 1 and form.body[0].kind == vkSymbol:
        result.moduleName = form.body[0].symVal
      else:
        result.strDeclProblem(label, "mod form has no name")
      let doc = form.meta.getOrDefault("doc")
      if doc.kind == vkString:
        result.moduleDoc = doc.strVal
      else:
        result.strDeclProblem(label, "mod form has no @doc string")
    of "fn":
      var decl = StrDecl()
      if form.body.len < 3:
        result.strDeclProblem(label, "declaration has no name, parameters, or body")
        continue
      if form.body[0].kind != vkSymbol:
        result.strDeclProblem(label, "declaration name is not a symbol")
        continue
      decl.name = form.body[0].symVal
      strDeclReadParams(form.body[1], label, result, decl)
      # `: Ret` sits between the parameter vector and the body.
      var bodyStart = 2
      if form.body.len > 2 and form.body[2].kind == vkSymbol and
          form.body[2].symVal == ":":
        decl.hasReturn = true
        bodyStart = 4
      if form.body.len != bodyStart + 1:
        result.strDeclProblem(label, "declaration must have exactly one body form")
      elif form.body[^1].kind != vkNil:
        result.strDeclProblem(label, "declaration body must be nil")
      let forValue = form.meta.getOrDefault("for")
      if forValue.kind == vkString:
        decl.forName = forValue.strVal
      else:
        result.strDeclProblem(label, "declaration has no @for string")
      let doc = form.meta.getOrDefault("doc")
      if doc.kind == vkString:
        decl.doc = doc.strVal
      else:
        result.strDeclProblem(label, "declaration has no @doc string")
      if form.meta.hasKey("see"):
        let see = form.meta["see"]
        if see.kind != vkList:
          result.strDeclProblem(label, "@see is not a List")
        else:
          for item in see.listItems:
            if item.kind != vkString or item.strVal.len == 0:
              result.strDeclProblem(label, "@see items must be non-empty Str values")
            else:
              decl.sees.add item.strVal
      if not form.props.hasKey("errors"):
        result.strDeclProblem(label, "declaration has no ^errors row")
      else:
        let errors = form.props["errors"]
        if errors.kind != vkList:
          result.strDeclProblem(label, "^errors is not a List")
        else:
          decl.errorsLen = errors.listItems.len
      result.decls.add decl
    else:
      # The sidecar holds one module header and declarations, nothing else.
      result.strDeclProblem(label, "unexpected top-level form: " & form.head.symVal)

proc strDeclNatives(scope: Scope, found: var bool): Table[string, string] =
  ## Member name -> the native's registered name (`str/join`), from the real
  ## runtime's `$str` namespace. `$x` is the standard library's `gene/x`, and
  ## the library namespaces live in the `gene` namespace, not the bare root.
  let gene =
    try:
      lookup(scope, "gene")
    except GeneError:
      NIL
  if gene.kind != vkNamespace: return
  var namespace: Value
  if not lookupOptional(nsScope(gene), "str", namespace): return
  if namespace.kind != vkNamespace: return
  found = true
  for member, value in nsScope(namespace).vars:
    if value.kind == vkNativeFn:
      result[member] = value.nativeFnName

let strDeclDummyArgs = {
  "byte_size": @["\"x\"", "\"y\""],
  "contains?": @["\"abc\"", "\"b\"", "\"c\""],
  "empty?": @["\"\"", "\"x\""],
  "ends_with?": @["\"abc\"", "\"bc\"", "\"c\""],
  "from_utf8": @["($str/to_utf8 \"x\")", "($str/to_utf8 \"y\")"],
  "join": @["[\"a\" \"b\"]", "\"-\"", "\"!\""],
  "lower": @["\"AbC\"", "\"x\""],
  "slice_bytes": @["\"Aé🙂Z\"", "1", "4", "2"],
  "split": @["\"a,b\"", "\",\"", "\"b\""],
  "starts_with?": @["\"abc\"", "\"ab\"", "\"a\""],
  "to_utf8": @["\"Aé\"", "\"x\""],
  "trim": @["\"  x  \"", "\"y\""],
  "upper": @["\"aBc\"", "\"x\""],
}.toTable

let strDeclTable = strDeclRead(strDeclPath)
let strDeclScope = newGlobalScope()
var strDeclFoundStrNamespace = false
let strDeclRegistered = strDeclNatives(strDeclScope, strDeclFoundStrNamespace)

suite "str declarations":
  test "the sidecar reads as one module header plus declarations":
    for problem in strDeclTable.problems:
      checkpoint problem
    check strDeclTable.problems.len == 0
    check strDeclTable.moduleCount == 1
    check strDeclTable.moduleName == "str"
    check strDeclTable.moduleDoc.len > 0
    check strDeclTable.decls.len > 0
    for decl in strDeclTable.decls:
      check decl.name.len > 0
      check decl.forName.len > 0
      check decl.doc.len > 0
      check decl.hasReturn
      check decl.params > 0
      check decl.typedParams == decl.params
      check decl.errorsLen == 0

  test "every registered $str native has exactly one @for declaration":
    check strDeclFoundStrNamespace
    check strDeclRegistered.len == strDeclExpectedNatives
    var declared = initTable[string, int]()
    for decl in strDeclTable.decls:
      declared.mgetOrPut(decl.forName, 0).inc
    for member, nativeName in strDeclRegistered:
      let key = "gene/" & nativeName
      if declared.getOrDefault(key) != 1:
        checkpoint member & " expects exactly one @for \"" & key &
          "\" declaration, got " & $declared.getOrDefault(key)
      check declared.getOrDefault(key) == 1

  test "every @for names a registered native":
    for decl in strDeclTable.decls:
      if not decl.forName.startsWith("gene/str/"):
        check false
        continue
      let member = decl.forName["gene/str/".len .. ^1]
      if not strDeclRegistered.hasKey(member):
        checkpoint decl.forName & " names no registered $str native"
      check strDeclRegistered.hasKey(member)
      if strDeclRegistered.hasKey(member):
        check "gene/" & strDeclRegistered[member] == decl.forName
        check decl.name == member

  test "declared arity agrees with each native's argument check":
    for decl in strDeclTable.decls:
      if not decl.forName.startsWith("gene/str/"):
        check false
        continue
      let member = decl.forName["gene/str/".len .. ^1]
      if not strDeclRegistered.hasKey(member):
        check false
        continue
      if not strDeclDummyArgs.hasKey(member):
        checkpoint "no dummy arguments are defined for " & member
        check false
        continue
      let dummies = strDeclDummyArgs[member]
      let declaredMax = decl.required + decl.optional
      let declaredRange = decl.required .. declaredMax
      var accepted: seq[int]
      var strayFailures: seq[string]
      for count in 0 .. declaredMax + 1:
        if count > dummies.len:
          checkpoint "too few dummy arguments for " & member
          check false
          break
        var call = "($str/" & member
        for i in 0 ..< count:
          call.add " " & dummies[i]
        call.add ")"
        try:
          discard run(compileSource(call), strDeclScope)
          accepted.add count
        except CatchableError as error:
          var got = -1
          if strDeclArityRejection(error.msg, got):
            check got == count
            check count notin declaredRange
          else:
            accepted.add count
            if count in declaredRange:
              strayFailures.add call & " failed outside its arity check: " & error.msg
      var expected: seq[int]
      for count in declaredRange: expected.add count
      if accepted != expected:
        checkpoint member & " accepts " & $accepted & ", declaration says " & $expected
      check accepted == expected
      for failure in strayFailures:
        checkpoint failure
      check strayFailures.len == 0
      # `^errors []` promises no ordinary Error escapes. A rejected call is a
      # fault (the native raises a plain GeneError), so a Gene-level probe
      # catching `Error` before `Fault` must report "fault".
      let faultProbe = "(try ($str/" & member &
        ") catch Error \"error\" catch Fault \"fault\")"
      let faultKind = run(compileSource(faultProbe), strDeclScope)
      check faultKind.kind == vkString
      if faultKind.kind == vkString:
        check faultKind.strVal == "fault"

  test "the builder turns the sidecar into the module data":
    ## Check 6 must validate what the builder emits, not only a second parse
    ## of the sidecar: a bug in the declaration pass would otherwise pass.
    let build = docBuilder.buildPackage(strDeclRepoRoot(),
      strDeclRepoRoot() / "src/gene/lib")
    var strModule: ModuleDoc
    for doc in build.modules:
      if doc.module == "gene/str":
        strModule = doc
    check strModule.module == "gene/str"
    check strModule.diagnostics.len == 0
    check strModule.entries.len == strDeclTable.decls.len
    for entry in strModule.entries:
      checkpoint "entry: " & entry.id
      check entry.id == "lib/gene/str/" & entry.name
      check entry.forName == "gene/str/" & entry.name
      check entry.named.len == 0
      check entry.errors.len == 0
      check entry.doc.len > 0
      var declared: StrDecl
      var found = false
      for decl in strDeclTable.decls:
        if decl.name == entry.name:
          declared = decl
          found = true
      check found
      if found:
        check entry.positional.len == declared.params
        var required = 0
        for param in entry.positional:
          if param.required: inc required
        check required == declared.required
        check entry.doc == declared.doc
        check entry.see == declared.sees
        check (entry.result.len > 0) == declared.hasReturn
