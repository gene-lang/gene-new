## Restricted Gene -> readable TypeScript/ESM backend.
##
## This module owns a web-only semantic IR. It deliberately does not consume or
## mutate GIR; unsupported forms fail while building the IR, before emission.

import std/[json, os, sets, strutils, tables]
import ./[compiler, printer, reader, types]

type
  WebProfileError* = object of CatchableError

  WebTypeKind* = enum
    wtkNil, wtkVoid, wtkBool, wtkStr, wtkSym, wtkInt, wtkF64,
    wtkAny, wtkNever, wtkList, wtkPropMap, wtkMap, wtkNode, wtkRange,
    wtkCallback, wtkTask, wtkStream, wtkNominal, wtkUnion,
    ## The one host type the profile names. It exists so an entry point and a
    ## listener registration can be *checked* rather than taking `Any`, whose
    ## generated validator is `return value;` and therefore validates nothing.
    ## It admits exactly the operations the DOM ABI allows on a target.
    wtkDomTarget

  WebType* = ref object
    kind*: WebTypeKind
    item*: WebType
    params*: seq[WebType]
    returnType*: WebType
    name*: string
    members*: seq[WebType]

  WebExprKind* = enum
    wekNil, wekVoid, wekBool, wekStr, wekSym, wekInt, wekF64,
    wekBinding, wekList, wekPropMap, wekMap, wekNode, wekRange,
    wekIf, wekCall, wekBuiltin, wekCheck, wekNot, wekAnd, wekOr, wekCoalesce,
    wekBinary, wekDo,
    wekBind, wekSet, wekSetPath, wekWhile, wekLoop, wekRepeat, wekFor,
    wekBreak, wekContinue, wekReturn, wekMatch, wekTry, wekFail,
    wekPath, wekSelector, wekSend, wekNew, wekEnum, wekDomRender,
    wekDomListener, wekLambda, wekAwait,
    wekSpawn, wekScope, wekYield, wekMessage

  WebExpr* = ref object
    kind*: WebExprKind
    typ*: WebType
    loc*: SourceLoc
    text*: string
    boolValue*: bool
    children*: seq[WebExpr]
    external*: bool
    paramTypes*: seq[WebType]
    immutable*: bool
    mutable*: bool
    propCount*: int
    keys*: seq[string]
    patterns*: seq[Value]
    params*: seq[WebParam]     # wekLambda: the inline callback's parameters

  WebParam* = object
    sourceName*: string
    emittedName*: string
    typ*: WebType
    loc*: SourceLoc

  WebFunction* = ref object
    sourceName*: string
    emittedName*: string
    params*: seq[WebParam]
    returnType*: WebType
    body*: WebExpr
    loc*: SourceLoc
    generator*: bool
    async*: bool
    publicExport*: bool
    namespacePath*: seq[string]

  WebNamespace* = ref object
    sourceName*: string
    emittedName*: string
    path*: seq[string]
    functions*: seq[WebFunction]

  WebImportSelection* = object
    sourceName*: string
    localName*: string

  WebImport* = object
    sourcePath*: string
    resolvedPath*: string
    selections*: seq[WebImportSelection]
    loc*: SourceLoc

  WebExtern* = object
    sourceName*: string
    emittedName*: string
    importName*: string
    modulePath*: string
    params*: seq[WebParam]
    returnType*: WebType
    loc*: SourceLoc

  WebField* = object
    sourceName*: string
    emittedName*: string
    typ*: WebType
    optional*: bool

  WebMethod* = ref object
    sourceName*: string
    emittedName*: string
    params*: seq[WebParam]
    returnType*: WebType
    body*: WebExpr
    loc*: SourceLoc
    sourceForm: Value

  WebConstructor* = ref object
    params*: seq[WebParam]
    body*: WebExpr
    loc*: SourceLoc
    sourceForm: Value

  WebTypeDecl* = ref object
    sourceName*: string
    emittedName*: string
    parentName*: string
    fields*: seq[WebField]
    bodyFields*: seq[WebType]
    bodyRest*: WebType
    methods*: seq[WebMethod]
    constructor*: WebConstructor
    implementedProtocols*: seq[string]
    implementsError*: bool
    loc*: SourceLoc

  WebEnumVariant* = object
    sourceName*: string
    emittedName*: string
    payload*: seq[WebType]

  WebEnumDecl* = ref object
    sourceName*: string
    identityName*: string
    emittedName*: string
    variants*: seq[WebEnumVariant]
    loc*: SourceLoc

  WebProtocolMessage* = ref object
    sourceName*: string
    symbolName*: string
    params*: seq[WebParam]
    returnType*: WebType
    loc*: SourceLoc

  WebProtocolDecl* = ref object
    sourceName*: string
    emittedName*: string
    messages*: seq[WebProtocolMessage]
    loc*: SourceLoc

  WebImplMethod* = ref object
    protocolName*: string
    targetName*: string
    message*: WebProtocolMessage
    params*: seq[WebParam]
    returnType*: WebType
    body*: WebExpr
    loc*: SourceLoc
    sourceForm: Value

  WebImplDecl* = ref object
    protocolName*: string
    targetName*: string
    methods*: seq[WebImplMethod]
    loc*: SourceLoc

  WebModule* = ref object
    name*: string
    sourcePath*: string
    ## Base name for emitted artifacts. Empty means "derive it from
    ## sourcePath", which is what a file on disk wants; an embedded block has
    ## no file of its own and names itself.
    assetName*: string
    ## Set only for a block embedded in a host module. It holds *that block's*
    ## text and nothing else, and its presence is what makes the module
    ## embedded: no file exists to import from, so file imports are rejected
    ## and the source map may publish this string instead of reading a path
    ## that would hand a browser the whole server.
    embeddedSource*: string
    embedded*: bool
    ## The `(mod …)` header's position — the one location a diagnostic about
    ## the module *as a whole* (a missing entry, say) can honestly name.
    loc*: SourceLoc
    imports*: seq[WebImport]
    externs*: seq[WebExtern]
    functions*: seq[WebFunction]
    types*: seq[WebTypeDecl]
    visibleTypes*: seq[WebTypeDecl]
    enums*: seq[WebEnumDecl]
    visibleEnums*: seq[WebEnumDecl]
    protocols*: seq[WebProtocolDecl]
    visibleProtocols*: seq[WebProtocolDecl]
    impls*: seq[WebImplDecl]
    namespaces*: seq[WebNamespace]

  WebArtifacts* = object
    js*, ts*, declarations*, sourceMap*, tsSourceMap*: string

  WebFunctionSig = object
    params: seq[WebType]
    returnType: WebType
    callName: string
    valueName: string
    external: bool
    generator: bool
    async: bool

  WebBinding = object
    typ: WebType
    mutable: bool

  WebCallSite = object
    ## One statically resolved call, recorded during the single analysis pass so
    ## asyncness can be propagated over the call graph afterwards instead of by
    ## re-analyzing bodies. `caller` is empty for calls in a method, constructor,
    ## or impl body, which cannot be async and so contribute no edge.
    expr: WebExpr
    callee: string
    caller: string

  WebFunctionValueRef = object
    ## A function referenced as a value. Whether that is legal depends on the
    ## callee's final asyncness, which is not known until propagation ends.
    name: string
    loc: SourceLoc

  WebAnalysis = ref object
    unit: SourceUnit
    signatures: Table[string, WebFunctionSig]
    loopDepth: int
    currentReturn: WebType
    asyncDepth: int
    generatorDepth: int
    currentYield: WebType
    scopeDepth: int
    typeDecls: Table[string, WebTypeDecl]
    enumDecls: Table[string, WebEnumDecl]
    protocolDecls: Table[string, WebProtocolDecl]
    errorTypes: HashSet[string]
    protocolImplTargets: HashSet[string]
    currentTypeName: string
    currentNamespace: seq[string]
    currentFunction: string
    # Nearest enclosing form the analyzer has descended through, so a
    # diagnostic about a positionless scalar still names a place in the source.
    currentLoc: SourceLoc
    callSites: seq[WebCallSite]
    functionValueRefs: seq[WebFunctionValueRef]

  WebEmitter = object
    lines: seq[string]
    lineLocs: seq[SourceLoc]
    indent: int
    nextTemp: int
    typescript: bool
    currentLoc: SourceLoc
    scopeStack: seq[string]
    nominalTypes: HashSet[string] # decides node-vs-class patterns
    # Enclosing function's declared return type, so `wekReturn` can yield the
    # declared unit under a `Nil`/`Void` signature instead of the given value.
    currentReturnType: WebType

const jsReserved = [
  # `arguments` and `eval` are not keywords, but ES modules are always strict
  # and strict mode forbids binding either name, so they need the same prefix
  # escape as a reserved word.
  "arguments", "await", "break", "case", "catch", "class", "const", "continue",
  "debugger", "default", "delete", "do", "else", "enum", "eval", "export",
  "extends", "false", "finally", "for", "function", "if", "implements",
  "import", "in", "instanceof", "interface", "let", "new", "null",
  "package", "private", "protected", "public", "return", "static", "super",
  "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
  "void", "while", "with", "yield"]

proc isSym(value: Value, name: string): bool {.inline.} =
  value.kind == vkSymbol and value.symVal == name

proc isPath(value: Value, segments: openArray[string]): bool =
  if value.kind != vkNode or not value.head.isSym("path") or
      value.body.len != segments.len:
    return false
  for i, segment in segments:
    if not value.body[i].isSym(segment): return false
  true

proc sameType(a, b: WebType): bool =
  if a == nil or b == nil or a.kind != b.kind:
    return false
  case a.kind
  of wtkList, wtkTask, wtkStream:
    sameType(a.item, b.item)
  of wtkMap:
    a.params.len == 2 and b.params.len == 2 and
      sameType(a.params[0], b.params[0]) and sameType(a.params[1], b.params[1])
  of wtkCallback:
    if a.params.len != b.params.len or not sameType(a.returnType, b.returnType):
      return false
    for i in 0 ..< a.params.len:
      if not sameType(a.params[i], b.params[i]): return false
    true
  of wtkNominal:
    a.name == b.name
  of wtkUnion:
    if a.members.len != b.members.len: return false
    for i in 0 ..< a.members.len:
      if not sameType(a.members[i], b.members[i]): return false
    true
  else:
    true

proc webType(kind: WebTypeKind, item: WebType = nil): WebType =
  WebType(kind: kind, item: item)

proc unionType(types: varargs[WebType]): WebType =
  var members: seq[WebType]
  for typ in types:
    if typ == nil: continue
    if typ.kind == wtkNever: continue
    let candidates = if typ.kind == wtkUnion: typ.members else: @[typ]
    for candidate in candidates:
      var found = false
      for existing in members:
        if sameType(existing, candidate): found = true
      if not found: members.add candidate
  if members.len == 0: return webType(wtkNever)
  if members.len == 1: return members[0]
  WebType(kind: wtkUnion, members: members)

proc withoutAbsent(typ: WebType): WebType =
  if typ.kind in {wtkNil, wtkVoid}: return webType(wtkNever)
  if typ.kind != wtkUnion: return typ
  var members: seq[WebType]
  for member in typ.members:
    if member.kind notin {wtkNil, wtkVoid}: members.add member
  if members.len == 0: webType(wtkNever)
  elif members.len == 1: members[0]
  else: WebType(kind: wtkUnion, members: members)

proc accepts(analysis: WebAnalysis, expected, actual: WebType): bool =
  if expected == nil or actual == nil or expected.kind == wtkAny or
      actual.kind == wtkNever:
    return true
  if expected.kind == wtkUnion:
    for member in expected.members:
      if accepts(analysis, member, actual): return true
    return false
  if actual.kind == wtkUnion:
    for member in actual.members:
      if not accepts(analysis, expected, member): return false
    return true
  if expected.kind == actual.kind:
    case expected.kind
    of wtkList, wtkTask, wtkStream:
      return accepts(analysis, expected.item, actual.item)
    of wtkCallback:
      if expected.params.len != actual.params.len: return false
      for i in 0 ..< expected.params.len:
        if not accepts(analysis, expected.params[i], actual.params[i]): return false
      return accepts(analysis, expected.returnType, actual.returnType)
    of wtkMap:
      return accepts(analysis, expected.params[0], actual.params[0]) and
        accepts(analysis, expected.params[1], actual.params[1])
    else: discard
  if expected.kind == wtkNominal and
      analysis.protocolDecls.hasKey(expected.name):
    var target = case actual.kind
      of wtkNominal: actual.name
      of wtkNil: "Nil"
      of wtkStr: "Str"
      of wtkList: "List"
      else: ""
    while target.len > 0:
      if expected.name & "\x1f" & target in analysis.protocolImplTargets:
        return true
      if not analysis.typeDecls.hasKey(target): break
      target = analysis.typeDecls[target].parentName
  sameType(expected, actual)

proc typeName(typ: WebType): string =
  case typ.kind
  of wtkNil: "Nil"
  of wtkVoid: "Void"
  of wtkBool: "Bool"
  of wtkStr: "Str"
  of wtkSym: "Sym"
  of wtkInt: "Int"
  of wtkF64: "F64"
  of wtkAny: "Any"
  of wtkNever: "Never"
  of wtkList: "(List " & typeName(typ.item) & ")"
  of wtkPropMap: "PropMap"
  of wtkMap: "(Map " & typeName(typ.params[0]) & " " & typeName(typ.params[1]) & ")"
  of wtkNode: "Node"
  of wtkRange: "Range"
  of wtkDomTarget: "EventTarget"
  of wtkTask: "(Task " & typeName(typ.item) & ")"
  of wtkStream: "(Stream " & typeName(typ.item) & ")"
  of wtkNominal: typ.name
  of wtkUnion:
    var parts: seq[string]
    for member in typ.members: parts.add typeName(member)
    "(| " & parts.join(" ") & ")"
  of wtkCallback:
    var params: seq[string]
    for item in typ.params: params.add typeName(item)
    "(Callback [" & params.join(" ") & "] " & typeName(typ.returnType) & ")"

proc mangleWebName*(name: string): string

proc tsType(typ: WebType): string =
  case typ.kind
  of wtkNil: "null"
  of wtkVoid: "undefined"
  of wtkBool: "boolean"
  of wtkStr: "string"
  of wtkSym: "symbol"
  of wtkInt: "bigint"
  of wtkF64: "number"
  of wtkAny: "unknown"
  of wtkNever: "never"
  of wtkList: "ReadonlyArray<" & tsType(typ.item) & ">"
  of wtkPropMap: "Record<string, unknown>"
  of wtkMap: "GeneMap<" & tsType(typ.params[0]) & ", " & tsType(typ.params[1]) & ">"
  of wtkNode: "GeneNode"
  of wtkRange: "GeneRange"
  of wtkDomTarget: "EventTarget"
  of wtkTask: "GeneTask<" & tsType(typ.item) & ">"
  of wtkStream: "GeneStream<" & tsType(typ.item) & ">"
  of wtkNominal: mangleWebName(typ.name)
  of wtkUnion:
    var parts: seq[string]
    for member in typ.members: parts.add tsType(member)
    parts.join(" | ")
  of wtkCallback:
    var params: seq[string]
    for i, item in typ.params: params.add "arg" & $i & ": " & tsType(item)
    "(" & params.join(", ") & ") => " & tsType(typ.returnType)

proc validatorSuffix(typ: WebType): string =
  case typ.kind
  of wtkNil: "nil"
  of wtkVoid: "void"
  of wtkBool: "bool"
  of wtkStr: "str"
  of wtkSym: "sym"
  of wtkInt: "int"
  of wtkF64: "f64"
  of wtkAny: "any"
  of wtkNever: "never"
  of wtkList: "list_" & validatorSuffix(typ.item)
  of wtkPropMap: "prop_map"
  of wtkMap: "map_" & validatorSuffix(typ.params[0]) & "_" & validatorSuffix(typ.params[1])
  of wtkNode: "node"
  of wtkRange: "range"
  of wtkDomTarget: "event_target"
  of wtkTask: "task_" & validatorSuffix(typ.item)
  of wtkStream: "stream_" & validatorSuffix(typ.item)
  of wtkNominal: "nominal_" & mangleWebName(typ.name)
  of wtkUnion:
    var parts: seq[string]
    for member in typ.members: parts.add validatorSuffix(member)
    "union_" & parts.join("_")
  of wtkCallback:
    var parts: seq[string]
    for param in typ.params: parts.add validatorSuffix(param)
    "callback_" & parts.join("_") & "_to_" &
      validatorSuffix(typ.returnType)

proc validatorName(typ: WebType): string =
  "$gene_check_" & validatorSuffix(typ)

proc divisorGuard(typ: WebType): string =
  ## `/` and `//` route their divisor through this so a zero divisor raises the
  ## same Gene error the VM raises (`vm.nim` `biDiv`/`biRem`) instead of
  ## producing `Infinity` (F64) or a JS `RangeError` (Int).
  if typ.kind == wtkF64: "$gene_f64_divisor" else: "$gene_int_divisor"

proc locFor(analysis: WebAnalysis, value: Value,
            fallback = SourceLoc()): SourceLoc =
  ## Only containers carry positions, so a diagnostic about a bare symbol,
  ## string, or number would otherwise have none at all. Falling back to the
  ## nearest enclosing form the analyzer descended through gives every
  ## diagnostic a location — the form containing the offending scalar, which is
  ## what a reader needs to find it.
  if value.kind in {vkNode, vkList, vkMap, vkSet, vkHashMap} and
      analysis.unit.locs.hasKey(value.bits):
    analysis.unit.locs[value.bits]
  elif fallback.hasSourceLoc:
    fallback
  else:
    analysis.currentLoc

proc webError(loc: SourceLoc, message: string): ref WebProfileError =
  var prefix = ""
  if loc.hasSourceLoc:
    prefix = loc.sourceName & ":" & $loc.line & ":" & $loc.col & ": "
  newException(WebProfileError, prefix & message)

proc rejectUnknownProps(form: Value, loc: SourceLoc, label: string,
                        admitted: openArray[string]) =
  ## "Anything not admitted here is rejected before emission with a
  ## source-located reason" (docs/web-profile.md) has to hold for declaration
  ## properties too. Silently ignoring one turns a typo into a type with no
  ## fields and turns a documented exclusion — Gene spells derive as
  ## `^derive [P]` on the type, and `^repr native_wrapper` forbids direct
  ## construction — into a silently dropped prop.
  for key in form.props.keys:
    if key in admitted: continue
    case key
    of "derive":
      raise webError(loc,
        "derive is outside the web profile: it remains VM module-initialization behavior")
    of "repr", "native":
      raise webError(loc, label & " ^" & key &
        " is outside the web profile: native representations require the native loader")
    of "effects":
      raise webError(loc,
        "^effects is outside the web profile: static effect rows are reserved and browser authority is explicit")
    of "private":
      raise webError(loc, label & " ^private is outside the web profile: " &
        "web module visibility is the emitted export list")
    else:
      raise webError(loc, label & " got unexpected named argument: " & key)

proc parseWebType(value: Value, loc: SourceLoc): WebType =
  if value.kind == vkSymbol:
    if value.symVal.len > 1 and value.symVal.endsWith("?"):
      return unionType(parseWebType(newSym(value.symVal[0 .. ^2]), loc),
                       webType(wtkNil))
    case value.symVal
    of "Nil": return webType(wtkNil)
    of "Void": return webType(wtkVoid)
    of "Bool": return webType(wtkBool)
    of "Str": return webType(wtkStr)
    of "Sym": return webType(wtkSym)
    of "Int": return webType(wtkInt)
    of "F64": return webType(wtkF64)
    of "Any": return webType(wtkAny)
    of "Never": return webType(wtkNever)
    of "PropMap": return webType(wtkPropMap)
    of "Node": return webType(wtkNode)
    of "Range": return webType(wtkRange)
    of "EventTarget": return webType(wtkDomTarget)
    else:
      return WebType(kind: wtkNominal, name: value.symVal)
  if value.kind == vkNode and value.head.isSym("List") and
      value.body.len == 1:
    return webType(wtkList, parseWebType(value.body[0], loc))
  if value.kind == vkNode and (value.head.isSym("Callback") or
      value.head.isSym("Fn")) and
      value.body.len == 2 and value.body[0].kind == vkList:
    result = webType(wtkCallback)
    for paramType in value.body[0].listItems:
      if not paramType.isSym(","):
        result.params.add parseWebType(paramType, loc)
    result.returnType = parseWebType(value.body[1], loc)
    return
  if value.kind == vkNode and value.head.isSym("Map") and value.body.len == 2:
    return WebType(kind: wtkMap,
      params: @[parseWebType(value.body[0], loc), parseWebType(value.body[1], loc)])
  if value.kind == vkNode and value.head.isSym("Task") and value.body.len == 1:
    return webType(wtkTask, parseWebType(value.body[0], loc))
  if value.kind == vkNode and value.head.isSym("Stream") and value.body.len >= 1:
    return webType(wtkStream, parseWebType(value.body[0], loc))
  if value.kind == vkNode and value.head.isSym("?") and value.body.len == 1:
    return unionType(parseWebType(value.body[0], loc), webType(wtkNil))
  if value.kind == vkNode and value.head.isSym("|") and value.body.len >= 2:
    var members: seq[WebType]
    for member in value.body: members.add parseWebType(member, loc)
    return WebType(kind: wtkUnion, members: members)
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.body.len >= 1:
    return WebType(kind: wtkNominal, name: value.head.symVal)
  raise webError(loc, "unsupported web type annotation: " & value.print())

proc mangleWebName*(name: string): string =
  for c in name:
    case c
    of 'A'..'Z', 'a'..'z', '0'..'9', '_': result.add c
    of '$': result.add "$$"
    of '?': result.add "$q"
    of '!': result.add "$b"
    of '-': result.add "$h"
    else:
      result.add "$x"
      result.add toHex(ord(c), 2)
  if result.len == 0:
    result = "$e"
  elif result[0] in {'0'..'9'}:
    result = "$n$" & result
  elif result in jsReserved:
    result = "$r$" & result

proc isJsImportName(name: string): bool =
  if name.len == 0 or name[0] notin {'A'..'Z', 'a'..'z', '_', '$'}:
    return false
  for c in name:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '$'}:
      return false
  true

proc parseParams(analysis: WebAnalysis, value: Value,
                 fnLoc: SourceLoc): seq[WebParam] =
  if value.kind != vkList:
    raise webError(fnLoc, "web function requires a parameter vector")
  var i = 0
  while i < value.listItems.len:
    if value.listItems[i].isSym(","):
      inc i
      continue
    let name = value.listItems[i]
    if name.kind != vkSymbol:
      raise webError(analysis.locFor(value, fnLoc),
        "web parameters must be simple named bindings")
    if i + 2 >= value.listItems.len or
        not value.listItems[i + 1].isSym(":"):
      raise webError(analysis.locFor(value, fnLoc),
        "exported web parameter '" & name.symVal & "' requires an annotation")
    let typ = parseWebType(value.listItems[i + 2], analysis.locFor(value, fnLoc))
    result.add WebParam(sourceName: name.symVal,
                        emittedName: mangleWebName(name.symVal), typ: typ,
                        loc: analysis.locFor(value, fnLoc))
    inc i, 3

proc containsForm(value: Value, name: string): bool =
  if value.kind != vkNode: return false
  if value.head.isSym("quote"): return false
  if value.head.isSym(name): return true
  if containsForm(value.head, name): return true
  for _, item in value.props:
    if containsForm(item, name): return true
  for item in value.body:
    if containsForm(item, name): return true

proc parseFunctionHeader(analysis: WebAnalysis, form: Value): WebFunction =
  let loc = analysis.locFor(form)
  if form.body.len < 5 or form.body[0].kind != vkSymbol or
      form.body[1].kind != vkList:
    raise webError(loc,
      "web function requires a name, annotated parameters, return type, and body")
  if not form.body[2].isSym(":"):
    raise webError(loc,
      "exported web function '" & form.body[0].symVal &
      "' requires a return annotation")
  result = WebFunction(sourceName: form.body[0].symVal,
                       emittedName: mangleWebName(form.body[0].symVal),
                       params: parseParams(analysis, form.body[1], loc),
                       returnType: parseWebType(form.body[3], loc), loc: loc)
  # `async` is not a syntactic property of one body — see `resolveAsync`.
  result.generator = containsForm(form, "yield")

proc validateCallableProps(analysis: WebAnalysis, form: Value,
                           loc: SourceLoc, label: string) =
  rejectUnknownProps(form, loc, label, ["errors"])
  if not form.props.hasKey("errors"): return
  let row = form.props["errors"]
  if row.kind != vkList:
    raise webError(loc, label & " ^errors must be a type vector")
  var seen = initHashSet[string]()
  for item in row.listItems:
    if item.isSym(","): continue
    let typ = parseWebType(item, loc)
    if typ.kind == wtkNever: continue
    if typ.kind != wtkNominal:
      raise webError(loc, label & " ^errors entries must name Error types")
    if typ.name in seen:
      raise webError(loc, label & " ^errors contains duplicate " & typ.name)
    seen.incl typ.name
    if typ.name notin analysis.errorTypes:
      raise webError(loc, label & " ^errors type " & typ.name &
        " does not implement Error")

proc parseWebImport(form: Value, loc: SourceLoc,
                    importerPath: string): WebImport =
  if form.body.len != 3 or form.body[0].kind != vkList or
      not form.body[1].isSym("from") or form.body[2].kind != vkString:
    raise webError(loc,
      "web imports must be `(import [names] from \"./relative.gene\")`")
  rejectUnknownProps(form, loc, "import", [])
  result.sourcePath = form.body[2].strVal
  if not (result.sourcePath.startsWith("./") or
          result.sourcePath.startsWith("../")):
    raise webError(loc, "web imports must use a relative module path")
  result.resolvedPath = normalizedPath(
    absolutePath(parentDir(importerPath) / result.sourcePath))
  if splitFile(result.resolvedPath).ext.len == 0:
    result.resolvedPath.add ".gene"
  result.loc = loc
  var i = 0
  let items = form.body[0].listItems
  while i < items.len:
    if items[i].isSym(","):
      inc i
      continue
    if items[i].kind != vkSymbol:
      raise webError(loc, "web import selections must be names")
    let sourceName = items[i].symVal
    var localName = sourceName
    if i + 2 < items.len and items[i + 1].isSym(":"):
      if items[i + 2].kind != vkSymbol:
        raise webError(loc, "web import alias must be a name")
      localName = items[i + 2].symVal
      inc i, 3
    else:
      inc i
    result.selections.add WebImportSelection(sourceName: sourceName,
                                              localName: localName)
  if result.selections.len == 0:
    raise webError(loc, "web import requires at least one selection")

proc parseWebExtern(analysis: WebAnalysis, form: Value,
                    loc: SourceLoc): WebExtern =
  if form.body.len != 4 or form.body[0].kind != vkSymbol or
      form.body[1].kind != vkList or not form.body[2].isSym(":"):
    raise webError(loc,
      "js/fn requires a name, annotated parameters, and return type")
  rejectUnknownProps(form, loc, "js/fn", ["from", "import"])
  if not form.props.hasKey("from") or form.props["from"].kind != vkString:
    raise webError(loc, "js/fn requires a Str ^from module specifier")
  result.sourceName = form.body[0].symVal
  result.emittedName = "$js_" & mangleWebName(result.sourceName)
  result.modulePath = form.props["from"].strVal
  if result.modulePath.len == 0:
    raise webError(loc, "js/fn ^from must not be empty")
  result.importName = result.sourceName
  if form.props.hasKey("import"):
    if form.props["import"].kind != vkString or
        form.props["import"].strVal.len == 0:
      raise webError(loc, "js/fn ^import must be a non-empty Str")
    result.importName = form.props["import"].strVal
  if not isJsImportName(result.importName):
    raise webError(loc, "js/fn ^import must be a JavaScript identifier")
  result.params = parseParams(analysis, form.body[1], loc)
  result.returnType = parseWebType(form.body[3], loc)
  result.loc = loc

proc typeAllowsNil(typ: WebType): bool =
  if typ.kind == wtkNil: return true
  if typ.kind == wtkUnion:
    for member in typ.members:
      if typeAllowsNil(member): return true

proc parseWebTypeDecl(analysis: WebAnalysis, form: Value,
                      loc: SourceLoc): WebTypeDecl =
  if form.body.len < 1 or form.body[0].kind != vkSymbol:
    raise webError(loc, "web type requires a name")
  rejectUnknownProps(form, loc, "type", ["is", "props", "body"])
  result = WebTypeDecl(sourceName: form.body[0].symVal,
    emittedName: mangleWebName(form.body[0].symVal), loc: loc)
  if form.props.hasKey("is"):
    if form.props["is"].kind != vkSymbol:
      raise webError(loc, "web type ^is must be a declared type name")
    result.parentName = form.props["is"].symVal
  if form.props.hasKey("props"):
    let fields = form.props["props"]
    if fields.kind != vkMap:
      raise webError(loc, "web type ^props must be a property map")
    for name, annotation in fields.mapEntries:
      let typ = parseWebType(annotation, loc)
      result.fields.add WebField(sourceName: name,
        emittedName: mangleWebName(name), typ: typ,
        optional: typeAllowsNil(typ))
  if form.props.hasKey("body"):
    let schema = form.props["body"]
    if schema.kind != vkList:
      raise webError(loc, "web type ^body must be a type vector")
    var annotations: seq[Value]
    for annotation in schema.listItems:
      if not annotation.isSym(","): annotations.add annotation
    for i, annotation in annotations:
      if annotation.kind == vkSymbol and annotation.symVal.endsWith("..."):
        if result.bodyRest != nil or i != annotations.high:
          raise webError(loc, "web type ^body accepts one final repeated type")
        result.bodyRest = parseWebType(
          newSym(annotation.symVal[0 .. ^4]), loc)
      else:
        if result.bodyRest != nil:
          raise webError(loc, "web type ^body repeated type must be final")
        result.bodyFields.add parseWebType(annotation, loc)
  for i in 1 ..< form.body.len:
    let member = form.body[i]
    if member.kind != vkNode or member.head.kind != vkSymbol:
      raise webError(loc, "web type body accepts ctor and message declarations")
    if member.head.symVal == "ctor":
      if result.constructor != nil or member.body.len < 1:
        raise webError(loc, "web type accepts one non-empty ctor declaration")
      result.constructor = WebConstructor(
        params: parseParams(analysis, member.body[0], loc), loc: loc,
        sourceForm: member)
    elif member.head.symVal == "message":
      if member.body.len < 5 or member.body[0].kind != vkSymbol or
          member.body[1].kind != vkList or not member.body[2].isSym(":"):
        raise webError(loc, "web message requires name, parameters, return, and body")
      let methodDecl = WebMethod(sourceName: member.body[0].symVal,
        emittedName: mangleWebName(member.body[0].symVal),
        params: parseParams(analysis, member.body[1], loc),
        returnType: parseWebType(member.body[3], loc), loc: loc,
        sourceForm: member)
      result.methods.add methodDecl
    else:
      raise webError(loc, "web type member '" & member.head.symVal &
        "' is unsupported")

proc parseWebEnumDecl(form: Value, loc: SourceLoc): WebEnumDecl =
  if form.body.len < 2 or form.body[0].kind != vkSymbol:
    raise webError(loc, "web enum requires a name and variants")
  rejectUnknownProps(form, loc, "enum", [])
  result = WebEnumDecl(sourceName: form.body[0].symVal,
    identityName: form.body[0].symVal,
    emittedName: mangleWebName(form.body[0].symVal), loc: loc)
  var start = 1
  if form.body[1].kind == vkList: start = 2 # erased generic parameters
  for i in start ..< form.body.len:
    let variant = form.body[i]
    if variant.kind == vkSymbol:
      result.variants.add WebEnumVariant(sourceName: variant.symVal,
        emittedName: mangleWebName(variant.symVal))
    elif variant.kind == vkNode and variant.head.kind == vkSymbol:
      # Only the ordered tuple payload is consumed. Named fields would be a
      # struct variant, which this profile does not emit, so accepting them
      # silently would drop them.
      rejectUnknownProps(variant, loc,
        "enum variant " & variant.head.symVal, [])
      var payload: seq[WebType]
      for annotation in variant.body:
        payload.add parseWebType(annotation, loc)
      result.variants.add WebEnumVariant(sourceName: variant.head.symVal,
        emittedName: mangleWebName(variant.head.symVal), payload: payload)
    else:
      raise webError(loc, "unsupported web enum variant")

proc parseProtocolParams(analysis: WebAnalysis, value: Value,
                         loc: SourceLoc): seq[WebParam] =
  if value.kind != vkList:
    raise webError(loc, "web protocol message requires a parameter vector")
  var items: seq[Value]
  for item in value.listItems:
    if not item.isSym(","): items.add item
  var i = 0
  if items.len > 0 and items[0].isSym("self"): inc i
  while i < items.len:
    if items[i].kind != vkSymbol or i + 2 >= items.len or
        not items[i + 1].isSym(":"):
      raise webError(loc, "web protocol parameters require annotations")
    result.add WebParam(sourceName: items[i].symVal,
      emittedName: mangleWebName(items[i].symVal),
      typ: parseWebType(items[i + 2], loc), loc: loc)
    inc i, 3

proc parseWebProtocolDecl(analysis: WebAnalysis, form: Value,
                          loc: SourceLoc): WebProtocolDecl =
  if form.body.len < 1 or form.body[0].kind != vkSymbol:
    raise webError(loc, "web protocol requires a name")
  rejectUnknownProps(form, loc, "protocol", [])
  result = WebProtocolDecl(sourceName: form.body[0].symVal,
    emittedName: mangleWebName(form.body[0].symVal), loc: loc)
  for i in 1 ..< form.body.len:
    let member = form.body[i]
    if member.kind != vkNode or not member.head.isSym("message") or
        member.body.len < 4 or member.body[0].kind != vkSymbol or
        member.body[1].kind != vkList or not member.body[2].isSym(":"):
      raise webError(loc, "web protocol accepts message signatures")
    let name = member.body[0].symVal
    # A signature's `^errors` row is erased; the types in it are checked on the
    # impl side, where `impl Error for T` has already been registered.
    rejectUnknownProps(member, loc, "protocol message " & name, ["errors"])
    result.messages.add WebProtocolMessage(sourceName: name,
      symbolName: "$" & result.emittedName & "$" & mangleWebName(name),
      params: parseProtocolParams(analysis, member.body[1], loc),
      returnType: parseWebType(member.body[3], loc), loc: loc)

proc findProtocolMessage(declaration: WebProtocolDecl,
                         name: string): WebProtocolMessage =
  for messageDecl in declaration.messages:
    if messageDecl.sourceName == name: return messageDecl
  raise newException(WebProfileError,
    "web protocol " & declaration.sourceName & " has no message " & name)

proc parseWebImplDecl(analysis: WebAnalysis, form: Value,
                      loc: SourceLoc): WebImplDecl =
  if form.body.len < 3 or form.body[0].kind != vkSymbol or
      not form.body[1].isSym("for") or form.body[2].kind != vkSymbol:
    raise webError(loc, "web impl requires `impl Protocol for Type`")
  rejectUnknownProps(form, loc, "impl", [])
  result = WebImplDecl(protocolName: form.body[0].symVal,
    targetName: form.body[2].symVal, loc: loc)
  if not analysis.protocolDecls.hasKey(result.protocolName):
    raise webError(loc, "unknown web protocol: " & result.protocolName)
  if not analysis.typeDecls.hasKey(result.targetName) and
      result.targetName notin ["Nil", "Str", "List"]:
    raise webError(loc,
      "web impl target must be a declared type or the builtin Nil, Str, or List")
  let protocol = analysis.protocolDecls[result.protocolName]
  for i in 3 ..< form.body.len:
    let member = form.body[i]
    if member.kind != vkNode or not member.head.isSym("message") or
        member.body.len < 5 or member.body[0].kind != vkSymbol or
        member.body[1].kind != vkList or not member.body[2].isSym(":"):
      raise webError(loc, "web impl accepts message definitions")
    let messageDecl = findProtocolMessage(protocol, member.body[0].symVal)
    result.methods.add WebImplMethod(protocolName: result.protocolName,
      targetName: result.targetName, message: messageDecl,
      params: parseProtocolParams(analysis, member.body[1], loc),
      returnType: parseWebType(member.body[3], loc), loc: loc,
      sourceForm: member)

proc findField(analysis: WebAnalysis, typ: WebType,
               name: string): WebType =
  if typ == nil or typ.kind != wtkNominal or
      not analysis.typeDecls.hasKey(typ.name):
    return nil
  var declaration = analysis.typeDecls[typ.name]
  while declaration != nil:
    for field in declaration.fields:
      if field.sourceName == name: return field.typ
    if declaration.parentName.len == 0 or
        not analysis.typeDecls.hasKey(declaration.parentName): break
    declaration = analysis.typeDecls[declaration.parentName]

proc analysisFields(analysis: WebAnalysis,
                    declaration: WebTypeDecl): seq[WebField] =
  if declaration.parentName.len > 0 and
      analysis.typeDecls.hasKey(declaration.parentName):
    result.add analysis.analysisFields(
      analysis.typeDecls[declaration.parentName])
  result.add declaration.fields

proc analysisBodySchema(analysis: WebAnalysis,
                        declaration: WebTypeDecl): tuple[
                          fixed: seq[WebType], rest: WebType] =
  if declaration.parentName.len > 0 and
      analysis.typeDecls.hasKey(declaration.parentName):
    result = analysis.analysisBodySchema(
      analysis.typeDecls[declaration.parentName])
  result.fixed.add declaration.bodyFields
  if declaration.bodyRest != nil: result.rest = declaration.bodyRest

proc findBodyType(analysis: WebAnalysis, typ: WebType,
                  index: int): WebType =
  if typ == nil or typ.kind != wtkNominal or index < 0 or
      not analysis.typeDecls.hasKey(typ.name): return nil
  let schema = analysis.analysisBodySchema(analysis.typeDecls[typ.name])
  if index < schema.fixed.len: schema.fixed[index]
  else: schema.rest

proc findMethod(analysis: WebAnalysis, typ: WebType,
                name: string): WebMethod =
  if typ == nil or typ.kind != wtkNominal or
      not analysis.typeDecls.hasKey(typ.name):
    return nil
  var declaration = analysis.typeDecls[typ.name]
  while declaration != nil:
    for methodDecl in declaration.methods:
      if methodDecl.sourceName == name: return methodDecl
    if declaration.parentName.len == 0 or
        not analysis.typeDecls.hasKey(declaration.parentName): break
    declaration = analysis.typeDecls[declaration.parentName]

proc findConstructor(analysis: WebAnalysis,
                     declaration: WebTypeDecl): WebConstructor =
  var current = declaration
  while current != nil:
    if current.constructor != nil: return current.constructor
    if current.parentName.len == 0 or
        not analysis.typeDecls.hasKey(current.parentName): break
    current = analysis.typeDecls[current.parentName]

proc findVariant(declaration: WebEnumDecl,
                 name: string): WebEnumVariant =
  for variant in declaration.variants:
    if variant.sourceName == name: return variant
  raise newException(WebProfileError,
    "web enum " & declaration.sourceName & " has no variant " & name)

proc builtinImplTarget(typ: WebType): string =
  if typ == nil: return ""
  case typ.kind
  of wtkNil: "Nil"
  of wtkStr: "Str"
  of wtkList: "List"
  else: ""

proc implFunctionName(protocolName, targetName, messageName: string): string =
  "$gene_impl_protocol_" & mangleWebName(protocolName) & "_" &
    mangleWebName(targetName) & "_" & mangleWebName(messageName)

proc analyzeExpr(analysis: WebAnalysis, value: Value,
                 bindings: var Table[string, WebBinding],
                 expected: WebType = nil): WebExpr

proc usesAsyncPrimitive(expr: WebExpr): bool

proc copyBindings(bindings: Table[string, WebBinding]):
    Table[string, WebBinding] =
  result = initTable[string, WebBinding]()
  for name, binding in bindings:
    result[name] = binding

proc analyzeSequence(analysis: WebAnalysis, forms: openArray[Value],
                     bindings: var Table[string, WebBinding],
                     expected: WebType = nil,
                     loc = SourceLoc()): WebExpr =
  result = WebExpr(kind: wekDo, typ: webType(wtkNil), loc: loc)
  if forms.len == 0:
    result.children.add WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
    return
  for i, form in forms:
    let itemExpected = if i == forms.high: expected else: nil
    result.children.add analysis.analyzeExpr(form, bindings, itemExpected)
  result.typ = result.children[^1].typ

proc bindPattern(analysis: WebAnalysis, pattern: Value, targetType: WebType,
                 bindings: var Table[string, WebBinding],
                 mutable = false) =
  case pattern.kind
  of vkSymbol:
    if pattern.symVal != "_":
      if bindings.hasKey(pattern.symVal):
        raise newException(WebProfileError,
          "duplicate web pattern binding: " & pattern.symVal)
      bindings[pattern.symVal] = WebBinding(typ: targetType, mutable: mutable)
  of vkList:
    let itemType =
      if targetType != nil and targetType.kind == wtkList: targetType.item
      else: webType(wtkAny)
    for item in pattern.listItems:
      if item.kind == vkSymbol and item.symVal.endsWith("..."):
        let name = item.symVal[0 .. ^4]
        if name != "_":
          bindPattern(analysis, newSym(name), webType(wtkList, itemType),
                      bindings, mutable)
      elif not item.isSym(","):
        bindPattern(analysis, item, itemType, bindings, mutable)
  of vkMap:
    for _, item in pattern.mapEntries:
      bindPattern(analysis, item, webType(wtkAny), bindings, mutable)
  of vkNode:
    if pattern.head.isSym("...") and pattern.body.len == 1 and
        pattern.body[0].kind == vkSymbol:
      let itemType = if targetType != nil: targetType else: webType(wtkAny)
      bindPattern(analysis, pattern.body[0], webType(wtkList, itemType),
                  bindings, mutable)
      return
    if pattern.head.isSym("unquote"):
      return
    if pattern.head.isSym("|") or pattern.head.isSym("&"):
      if pattern.body.len > 0:
        bindPattern(analysis, pattern.body[0], targetType, bindings, mutable)
      return
    if pattern.head.isSym("not"):
      return
    var payloadTypes: seq[WebType]
    if pattern.head.kind == vkNode and pattern.head.head.isSym("path") and
        pattern.head.body.len == 2 and pattern.head.body[0].kind == vkSymbol and
        pattern.head.body[1].kind == vkSymbol and
        analysis.enumDecls.hasKey(pattern.head.body[0].symVal):
      payloadTypes = findVariant(analysis.enumDecls[pattern.head.body[0].symVal],
                                 pattern.head.body[1].symVal).payload
    for i, item in pattern.body:
      let itemType = if i < payloadTypes.len: payloadTypes[i]
                     else: webType(wtkAny)
      bindPattern(analysis, item, itemType, bindings, mutable)
    for key, item in pattern.props:
      var fieldType = webType(wtkAny)
      if pattern.head.kind == vkSymbol and
          analysis.typeDecls.hasKey(pattern.head.symVal):
        let resolved = analysis.findField(
          WebType(kind: wtkNominal, name: pattern.head.symVal), key)
        if resolved != nil: fieldType = resolved
      bindPattern(analysis, item, fieldType, bindings, mutable)
  else:
    discard

proc normalizeWebPattern(analysis: WebAnalysis, pattern: Value): Value =
  case pattern.kind
  of vkList:
    var items: seq[Value]
    for item in pattern.listItems: items.add analysis.normalizeWebPattern(item)
    newList(items, pattern.listImmutable)
  of vkMap:
    var entries = initPropTable()
    for key, item in pattern.mapEntries:
      entries[key] = analysis.normalizeWebPattern(item)
    newMap(entries, pattern.mapImmutable)
  of vkNode:
    var head = analysis.normalizeWebPattern(pattern.head)
    if head.kind == vkNode and head.head.isSym("path") and
        head.body.len == 2 and head.body[0].kind == vkSymbol and
        analysis.enumDecls.hasKey(head.body[0].symVal):
      let declaration = analysis.enumDecls[head.body[0].symVal]
      if declaration.identityName != declaration.sourceName:
        head = newNode(newSym("path"), body = @[
          newSym(declaration.identityName), head.body[1]])
    var props = initPropTable()
    for key, item in pattern.props:
      props[key] = analysis.normalizeWebPattern(item)
    var body: seq[Value]
    for item in pattern.body: body.add analysis.normalizeWebPattern(item)
    newNode(head, props, body)
  else: pattern

proc analyzeDatum(analysis: WebAnalysis, value: Value,
                  loc: SourceLoc): WebExpr =
  case value.kind
  of vkNil: result = WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
  of vkVoid: result = WebExpr(kind: wekVoid, typ: webType(wtkVoid), loc: loc)
  of vkBool: result = WebExpr(kind: wekBool, typ: webType(wtkBool), loc: loc,
                              boolValue: value.boolVal)
  of vkInt: result = WebExpr(kind: wekInt, typ: webType(wtkInt), loc: loc,
                             text: value.intToString)
  of vkFloat: result = WebExpr(kind: wekF64, typ: webType(wtkF64), loc: loc,
                               text: $value.floatVal)
  of vkString: result = WebExpr(kind: wekStr, typ: webType(wtkStr), loc: loc,
                                text: value.strVal)
  of vkSymbol: result = WebExpr(kind: wekSym, typ: webType(wtkSym), loc: loc,
                                text: value.symVal)
  of vkList:
    result = WebExpr(kind: wekList, loc: loc, immutable: value.listImmutable)
    var itemType: WebType
    for item in value.listItems:
      let child = analysis.analyzeDatum(item, loc)
      itemType = if itemType == nil: child.typ else: unionType(itemType, child.typ)
      result.children.add child
    if itemType == nil: itemType = webType(wtkAny)
    result.typ = webType(wtkList, itemType)
  of vkMap:
    result = WebExpr(kind: wekPropMap, typ: webType(wtkPropMap), loc: loc,
                     immutable: value.mapImmutable)
    for key, item in value.mapEntries:
      result.keys.add key
      result.children.add analysis.analyzeDatum(item, loc)
  of vkNode:
    result = WebExpr(kind: wekNode, typ: webType(wtkNode), loc: loc,
                     immutable: value.nodeImmutable)
    if value.head.kind == vkSymbol: result.text = value.head.symVal
    else: result.text = value.head.print()
    for key, item in value.props:
      result.keys.add key
      result.children.add analysis.analyzeDatum(item, loc)
      inc result.propCount
    for item in value.body:
      result.children.add analysis.analyzeDatum(item, loc)
  else:
    raise webError(loc, "quoted " & $value.kind & " is outside the web profile")

proc analyzeTemplate(analysis: WebAnalysis, value: Value,
                     bindings: var Table[string, WebBinding],
                     loc: SourceLoc): WebExpr =
  if value.kind == vkNode and value.head.isSym("unquote") and
      value.body.len == 1:
    return analysis.analyzeExpr(value.body[0], bindings)
  case value.kind
  of vkNode:
    result = WebExpr(kind: wekNode, typ: webType(wtkNode), loc: loc,
                     immutable: true)
    if value.head.kind == vkSymbol: result.text = value.head.symVal
    else: result.text = value.head.print()
    for key, item in value.props:
      result.keys.add key
      result.children.add analysis.analyzeTemplate(item, bindings, loc)
      inc result.propCount
    for item in value.body:
      result.children.add analysis.analyzeTemplate(item, bindings, loc)
  of vkList:
    result = WebExpr(kind: wekList, typ: webType(wtkList, webType(wtkAny)),
                     loc: loc, immutable: true)
    for item in value.listItems:
      result.children.add analysis.analyzeTemplate(item, bindings, loc)
  of vkMap:
    result = WebExpr(kind: wekPropMap, typ: webType(wtkPropMap), loc: loc,
                     immutable: true)
    for key, item in value.mapEntries:
      result.keys.add key
      result.children.add analysis.analyzeTemplate(item, bindings, loc)
  else:
    result = analysis.analyzeDatum(value, loc)

proc isStatementType(typ: WebType): bool {.inline.} =
  ## `Nil` and `Void` are statement signatures: the body's trailing value is
  ## discarded and the function yields the declared unit. Mirrors the VM's
  ## `isStatementReturnType`, and the two must stay in step or the same source
  ## means different things on the two backends.
  typ != nil and (typ.kind == wtkNil or typ.kind == wtkVoid)

proc statementUnit(typ: WebType): string {.inline.} =
  if typ != nil and typ.kind == wtkVoid: "undefined" else: "null"

proc requireType(analysis: WebAnalysis, loc: SourceLoc, actual,
                 expected: WebType, label: string) =
  if not accepts(analysis, expected, actual):
    raise webError(loc, label & " expected " & typeName(expected) &
      ", got " & typeName(actual))

proc analyzeKnownCall(analysis: WebAnalysis, value: Value,
                      bindings: var Table[string, WebBinding],
                      expected: WebType, sourceName: string,
                      signature: WebFunctionSig,
                      loc: SourceLoc): WebExpr =
  if value.body.len != signature.params.len:
    raise webError(loc, "web call '" & sourceName & "' expects " &
      $signature.params.len & " argument(s)")
  result = WebExpr(kind: wekCall, typ: signature.returnType, loc: loc,
    text: signature.callName, external: signature.external,
    paramTypes: signature.params, immutable: signature.generator,
    boolValue: signature.async)
  # An extern can never become async; a call through a callback binding names no
  # entry in `signatures`. Everything else is a call-graph edge, and its
  # `boolValue` is rewritten once propagation settles.
  if not signature.external and analysis.signatures.hasKey(sourceName):
    analysis.callSites.add WebCallSite(expr: result, callee: sourceName,
                                       caller: analysis.currentFunction)
  if result.typ.kind == wtkAny and expected != nil: result.typ = expected
  for i, argument in value.body:
    let analyzed = analysis.analyzeExpr(argument, bindings,
                                         signature.params[i])
    requireType(analysis, loc, analyzed.typ, signature.params[i],
                "argument " & $(i + 1) & " of " & sourceName)
    result.children.add analyzed

proc analyzeCall(analysis: WebAnalysis, value: Value,
                 bindings: var Table[string, WebBinding], expected: WebType): WebExpr =
  let loc = analysis.locFor(value)
  if value.body.len >= 2 and (value.body[0].isSym("~") or
      value.body[0].isSym("?~")):
    let isSuper = value.head.isSym("super")
    var receiver: WebExpr
    if isSuper:
      if analysis.currentTypeName.len == 0 or
          not analysis.typeDecls.hasKey(analysis.currentTypeName):
        raise webError(loc, "super send is only valid in a web type message")
      let current = analysis.typeDecls[analysis.currentTypeName]
      if current.parentName.len == 0 or
          not analysis.typeDecls.hasKey(current.parentName):
        raise webError(loc, "web super send requires a declared parent type")
      receiver = WebExpr(kind: wekBinding,
        typ: WebType(kind: wtkNominal, name: current.parentName),
        loc: loc, text: "super")
    else:
      receiver = analysis.analyzeExpr(value.head, bindings)
    var messageName = ""
    var protocolMessage: WebProtocolMessage
    if value.body[1].kind == vkSymbol:
      messageName = value.body[1].symVal
    elif value.body[1].kind == vkNode and value.body[1].head.isSym("msg") and
        value.body[1].body.len == 2 and value.body[1].body[1].kind == vkSymbol:
      var protocolName = ""
      let qualifier = value.body[1].body[0]
      if qualifier.kind == vkSymbol: protocolName = qualifier.symVal
      elif qualifier.kind == vkNode and qualifier.head.isSym("path") and
          qualifier.body.len == 1 and qualifier.body[0].kind == vkSymbol:
        protocolName = qualifier.body[0].symVal
      if not analysis.protocolDecls.hasKey(protocolName):
        raise webError(loc, "unknown web protocol in qualified send")
      messageName = value.body[1].body[1].symVal
      protocolMessage = findProtocolMessage(
        analysis.protocolDecls[protocolName], messageName)
    else:
      raise webError(loc, "web send requires a statically known message")
    var methodDecl = if protocolMessage == nil:
                       analysis.findMethod(receiver.typ, messageName)
                     else: nil
    if protocolMessage != nil:
      if isSuper:
        if value.body.len - 2 != protocolMessage.params.len:
          raise webError(loc, "web protocol message " & messageName &
            " expects " & $protocolMessage.params.len & " argument(s)")
        let qualifier = value.body[1].body[0]
        if qualifier.kind != vkSymbol:
          raise webError(loc, "web protocol super qualifier must be static")
        let protocolName = qualifier.symVal
        var provider = analysis.typeDecls[analysis.currentTypeName].parentName
        while provider.len > 0 and
            protocolName & "\x1f" & provider notin analysis.protocolImplTargets:
          if not analysis.typeDecls.hasKey(provider): provider = ""
          else: provider = analysis.typeDecls[provider].parentName
        if provider.len == 0:
          raise webError(loc, "web protocol super has no implementation above " &
            analysis.currentTypeName)
        result = WebExpr(kind: wekSend, typ: protocolMessage.returnType,
          loc: loc, text: messageName,
          keys: @[protocolMessage.symbolName, mangleWebName(provider)],
          external: true,
          children: @[WebExpr(kind: wekBinding,
            typ: WebType(kind: wtkNominal, name: analysis.currentTypeName),
            loc: loc, text: "self")])
        for i in 2 ..< value.body.len:
          result.children.add analysis.analyzeExpr(value.body[i], bindings,
            protocolMessage.params[i - 2].typ)
        return
      if value.body.len - 2 != protocolMessage.params.len:
        raise webError(loc, "web protocol message " & messageName &
          " expects " & $protocolMessage.params.len & " argument(s)")
      result = WebExpr(kind: wekSend, typ: protocolMessage.returnType, loc: loc,
        text: messageName, keys: @[protocolMessage.symbolName],
        boolValue: value.body[0].isSym("?~"), children: @[receiver])
      let builtinTarget = builtinImplTarget(receiver.typ)
      if builtinTarget.len > 0:
        let qualifier = value.body[1].body[0]
        let protocolName = if qualifier.kind == vkSymbol: qualifier.symVal else: ""
        if protocolName.len == 0 or
            protocolName & "\x1f" & builtinTarget notin analysis.protocolImplTargets:
          raise webError(loc, "web builtin " & builtinTarget &
            " has no visible impl for protocol " & protocolName)
        result.keys = @[
          implFunctionName(protocolName, builtinTarget, messageName), "$builtin"]
        result.external = true
      for i in 2 ..< value.body.len:
        var paramType = protocolMessage.params[i - 2].typ
        if paramType.kind == wtkNominal and paramType.name == "Self":
          paramType = receiver.typ
        result.children.add analysis.analyzeExpr(value.body[i], bindings,
                                                  paramType)
      return
    if methodDecl == nil and receiver.typ.kind == wtkStream and
        messageName in ["has_next", "peek", "next", "close"]:
      let returnType = case messageName
        of "has_next": webType(wtkBool)
        of "peek", "next": receiver.typ.item
        else: webType(wtkVoid)
      methodDecl = WebMethod(sourceName: messageName,
        emittedName: messageName, returnType: returnType, loc: loc)
    if methodDecl == nil and receiver.typ.kind == wtkTask and
        messageName == "cancel":
      methodDecl = WebMethod(sourceName: messageName,
        emittedName: messageName, returnType: webType(wtkVoid), loc: loc)
    if methodDecl == nil and receiver.typ.kind == wtkMap and
        messageName in ["get", "size"]:
      let params = case messageName
        of "get": @[WebParam(sourceName: "key",
          emittedName: "key", typ: receiver.typ.params[0], loc: loc)]
        else: newSeq[WebParam]()
      let returnType = case messageName
        of "get": receiver.typ.params[1]
        else: webType(wtkInt)
      methodDecl = WebMethod(sourceName: messageName,
        emittedName: messageName, params: params, returnType: returnType, loc: loc)
    if methodDecl == nil:
      raise webError(loc, "web type " & typeName(receiver.typ) &
        " has no message " & messageName)
    if value.body.len - 2 != methodDecl.params.len:
      raise webError(loc, "web message " & messageName & " expects " &
        $methodDecl.params.len & " argument(s)")
    result = WebExpr(kind: wekSend, typ: methodDecl.returnType, loc: loc,
      text: methodDecl.emittedName, boolValue: value.body[0].isSym("?~"),
      external: isSuper,
      children: @[receiver])
    for i in 2 ..< value.body.len:
      result.children.add analysis.analyzeExpr(value.body[i], bindings,
                                                methodDecl.params[i - 2].typ)
    return
  if value.head.kind != vkSymbol:
    if (value.head.isPath(["gene", "dom", "render"]) or
        value.head.isPath(["dom", "render"])):
      if value.body.len != 1:
        raise webError(loc, "dom/render expects one node value")
      return WebExpr(kind: wekDomRender, typ: webType(wtkAny), loc: loc,
        children: @[analysis.analyzeExpr(value.body[0], bindings,
                                         webType(wtkNode))])
    for listenerOp in ["add_event_listener", "remove_event_listener"]:
      if not (value.head.isPath(["gene", "dom", listenerOp]) or
              value.head.isPath(["dom", listenerOp])):
        continue
      # The one browser capability progressive enhancement actually needs. It
      # is a compiler-owned typed intrinsic, not a member on `Any`: the target
      # is checked, the event type is a `Str`, and the handler is a checked
      # `Callback` so a wrong arity or return fails here rather than at the
      # first click.
      if value.body.len != 3:
        raise webError(loc, "dom/" & listenerOp &
          " expects a target, an event type, and a handler")
      let handlerType = webType(wtkCallback)
      handlerType.params = @[webType(wtkAny)]
      handlerType.returnType = webType(wtkVoid)
      return WebExpr(kind: wekDomListener, typ: webType(wtkVoid), loc: loc,
        text: listenerOp,
        children: @[
          analysis.analyzeExpr(value.body[0], bindings, webType(wtkDomTarget)),
          analysis.analyzeExpr(value.body[1], bindings, webType(wtkStr)),
          analysis.analyzeExpr(value.body[2], bindings, handlerType)])
    if value.head.kind == vkNode and value.head.head.isSym("path") and not
        (value.head.body.len == 2 and value.head.body[0].kind == vkSymbol and
         analysis.enumDecls.hasKey(value.head.body[0].symVal)):
      var segments: seq[string]
      for segment in value.head.body:
        if segment.kind != vkSymbol:
          raise webError(loc, "web stdlib path must resolve statically")
        segments.add segment.symVal
      if segments.len > 0 and segments[0] == "gene": segments.delete(0)
      let builtin = segments.join("/")
      if analysis.signatures.hasKey(builtin):
        return analysis.analyzeKnownCall(value, bindings, expected, builtin,
          analysis.signatures[builtin], loc)
      if segments.len > 0 and segments[0] == "actor":
        raise webError(loc,
          "actors are outside the web profile: actors require the VM scheduler")
      if segments.len > 0 and segments[0] in ["channel", "supervisor"]:
        raise webError(loc,
          "actors and channels are outside the web profile: they require the VM scheduler")
      if segments.len > 0 and segments[0] in
          ["ffi", "c", "C", "dl", "native"]:
        raise webError(loc,
          "FFI is outside the web profile: browsers cannot load native libraries")
      if segments.len > 0 and segments[0] in
          ["fs", "net", "process", "env", "capability"]:
        raise webError(loc,
          "capabilities are outside the web profile: browser authority must cross an explicit JS boundary")
      if builtin in ["freeze", "thaw"]:
        raise webError(loc,
          "deep freeze/thaw is outside the web profile: it requires persistent structural sharing")
      var paramTypes: seq[WebType]
      var returnType: WebType
      case builtin
      of "actor/spawn":
        raise webError(loc,
          "actors are outside the web profile: actors require the VM scheduler")
      of "str/join":
        paramTypes = @[webType(wtkList, webType(wtkStr)), webType(wtkStr)]
        returnType = webType(wtkStr)
      of "str/split":
        paramTypes = @[webType(wtkStr), webType(wtkStr)]
        returnType = webType(wtkList, webType(wtkStr))
      of "str/trim", "str/lower", "url/encode_component",
          "url/decode_component", "html/escape", "html/attr_escape":
        paramTypes = @[webType(wtkStr)]
        returnType = webType(wtkStr)
      of "str/starts_with?", "str/ends_with?", "str/contains?":
        paramTypes = @[webType(wtkStr), webType(wtkStr)]
        returnType = webType(wtkBool)
      of "json/parse":
        paramTypes = @[webType(wtkStr)]
        returnType = if expected != nil: expected else: webType(wtkAny)
      of "json/stringify":
        paramTypes = @[webType(wtkAny)]
        returnType = webType(wtkStr)
      of "console/log", "console/warn", "console/error":
        # `Any` rather than `Str`, deliberately: the values worth logging from a
        # DOM handler are the event and the element, and forcing them through
        # string interpolation would print "[object HTMLElement]" instead of
        # something devtools can expand.
        paramTypes = @[webType(wtkAny)]
        returnType = webType(wtkVoid)
      of "dom/prevent_default", "dom/stop_propagation":
        paramTypes = @[webType(wtkAny)]
        returnType = webType(wtkVoid)
      of "http/post_form", "http/get":
        # Continuation-passing rather than `Task`-returning, because the only
        # caller that matters is a DOM event handler: the listener ABI requires
        # `Callback [Any] Void`, and `spawn` requires an enclosing `scope`, so
        # an async request cannot be started from a handler at all. A success
        # callback can.
        #
        # Only success is a callback. A non-2xx status or a transport failure
        # rethrows on the task queue, which makes it an ordinary uncaught error
        # reaching window.onerror and devtools — the alternative, an optional
        # error callback, makes silently discarding failures the default.
        let onOk = webType(wtkCallback)
        onOk.params = @[webType(wtkStr)]
        onOk.returnType = webType(wtkVoid)
        paramTypes =
          if builtin == "http/get": @[webType(wtkStr), onOk]
          else: @[webType(wtkStr), webType(wtkStr), onOk]
        returnType = webType(wtkVoid)
      of "size":
        paramTypes = @[webType(wtkAny)]
        returnType = webType(wtkInt)
      of "node/head":
        paramTypes = @[webType(wtkNode)]
        returnType = webType(wtkSym)
      of "node/props":
        paramTypes = @[webType(wtkNode)]
        returnType = webType(wtkPropMap)
      of "node/body":
        paramTypes = @[webType(wtkNode)]
        returnType = webType(wtkList, webType(wtkAny))
      of "to_stream":
        if value.body.len != 1:
          raise webError(loc, "web to_stream expects one List")
        let input = analysis.analyzeExpr(value.body[0], bindings)
        if input.typ.kind != wtkList:
          raise webError(loc, "web to_stream expects a List")
        return WebExpr(kind: wekBuiltin, typ: webType(wtkStream, input.typ.item),
          loc: loc, text: builtin, children: @[input])
      of "map", "filter":
        if value.body.len != 2:
          raise webError(loc, "web " & builtin & " expects stream and callback")
        let input = analysis.analyzeExpr(value.body[0], bindings)
        if input.typ.kind != wtkStream:
          raise webError(loc, "web " & builtin & " expects a Stream")
        let callbackExpected = WebType(kind: wtkCallback,
          params: @[input.typ.item],
          returnType: if builtin == "filter": webType(wtkBool)
                      elif expected != nil and expected.kind == wtkList:
                        expected.item
                      else: webType(wtkAny))
        let callback = analysis.analyzeExpr(value.body[1], bindings,
                                             callbackExpected)
        let itemType = if builtin == "filter": input.typ.item
                       else: callback.typ.returnType
        return WebExpr(kind: wekBuiltin, typ: webType(wtkStream, itemType),
          loc: loc, text: builtin, children: @[input, callback])
      of "into":
        if value.body.len != 2:
          raise webError(loc, "web into expects stream and destination")
        let input = analysis.analyzeExpr(value.body[0], bindings)
        if input.typ.kind != wtkStream:
          raise webError(loc, "web into expects a Stream")
        let destination = analysis.analyzeExpr(value.body[1], bindings, expected)
        if destination.typ.kind notin {wtkList, wtkPropMap}:
          raise webError(loc, "web into supports mutable List and PropMap destinations")
        return WebExpr(kind: wekBuiltin, typ: destination.typ, loc: loc,
          text: builtin, children: @[input, destination])
      else:
        raise webError(loc, "portable web stdlib does not provide " & builtin)
      if value.body.len != paramTypes.len:
        raise webError(loc, "web " & builtin & " expects " &
          $paramTypes.len & " argument(s)")
      result = WebExpr(kind: wekBuiltin, typ: returnType, loc: loc,
                       text: builtin)
      for i, item in value.body:
        result.children.add analysis.analyzeExpr(item, bindings, paramTypes[i])
      return
    if value.head.kind == vkNode and value.head.head.isSym("path") and
        value.head.body.len == 2 and value.head.body[0].kind == vkSymbol and
        value.head.body[1].kind == vkSymbol and
        analysis.enumDecls.hasKey(value.head.body[0].symVal):
      let declaration = analysis.enumDecls[value.head.body[0].symVal]
      let variant = findVariant(declaration, value.head.body[1].symVal)
      if value.body.len != variant.payload.len:
        raise webError(loc, "web enum variant " & variant.sourceName &
          " expects " & $variant.payload.len & " value(s)")
      result = WebExpr(kind: wekEnum,
        typ: WebType(kind: wtkNominal, name: declaration.sourceName),
        text: declaration.identityName & "/" & variant.sourceName, loc: loc)
      for i, item in value.body:
        result.children.add analysis.analyzeExpr(item, bindings,
                                                  variant.payload[i])
      return
    if value.head.kind == vkNode and value.head.head.isSym("path") and
        value.head.body.len >= 2 and value.head.body[0].isSym("gene") and
        value.head.body[1].isSym("actor"):
      raise webError(loc,
        "actors are outside the web profile: actors require the VM scheduler")
    raise webError(loc, "dynamic calls are outside the web profile")
  let name = value.head.symVal
  case name
  of "fn!":
    raise webError(loc,
      "fn! is outside the web profile: it requires a live evaluator and retained call syntax")
  of "eval":
    raise webError(loc,
      "eval is outside the web profile: it requires the whole Gene front end in the browser")
  of "supervisor":
    raise webError(loc,
      "actors are outside the web profile: supervisors require the VM scheduler")
  of "import_impl":
    raise webError(loc,
      "import_impl is outside the web profile: web impl visibility must be fixed at compile time")
  of "derive":
    raise webError(loc,
      "derive is outside the web profile: it remains VM module-initialization behavior")
  of "$freeze", "$thaw", "freeze", "thaw":
    raise webError(loc,
      "deep freeze/thaw is outside the web profile: it requires persistent structural sharing")
  of "AtomicCell":
    raise webError(loc,
      "AtomicCell is outside the web profile: the target is single-threaded")
  of "Channel", "ActorRef":
    raise webError(loc,
      name & " is outside the web profile: actors and channels require the VM scheduler")
  else: discard
  if name == "msg":
    if value.body.len != 2 or value.body[0].kind != vkSymbol or
        value.body[1].kind != vkSymbol or
        not analysis.protocolDecls.hasKey(value.body[0].symVal):
      raise webError(loc, "web message value requires static Protocol:message")
    let protocol = analysis.protocolDecls[value.body[0].symVal]
    let messageDecl = findProtocolMessage(protocol, value.body[1].symVal)
    var callbackType = WebType(kind: wtkCallback,
      params: @[webType(wtkAny)], returnType: messageDecl.returnType)
    for param in messageDecl.params: callbackType.params.add param.typ
    if expected != nil and expected.kind == wtkCallback and
        expected.params.len == callbackType.params.len and
        accepts(analysis, expected.returnType, callbackType.returnType):
      callbackType = expected
    return WebExpr(kind: wekMessage, typ: callbackType, loc: loc,
      text: messageDecl.symbolName, paramTypes: callbackType.params)
  if name == "quote":
    if value.body.len != 1:
      raise webError(loc, "web quote expects one datum")
    return analysis.analyzeDatum(value.body[0], loc)
  if name == "quasiquote":
    if value.body.len != 1:
      raise webError(loc, "web quasiquote expects one template")
    return analysis.analyzeTemplate(value.body[0], bindings, loc)
  if name == "range":
    if value.body.len notin [2, 3]:
      raise webError(loc, "web range expects start, stop, and optional step")
    let start = analysis.analyzeExpr(value.body[0], bindings, webType(wtkInt))
    let stop = analysis.analyzeExpr(value.body[1], bindings, webType(wtkInt))
    let step = if value.body.len == 3:
      analysis.analyzeExpr(value.body[2], bindings, webType(wtkInt))
    else: WebExpr(kind: wekInt, typ: webType(wtkInt), loc: loc, text: "1")
    return WebExpr(kind: wekRange, typ: webType(wtkRange), loc: loc,
      boolValue: value.props.hasKey("inclusive") and
        value.props["inclusive"].kind == vkBool and value.props["inclusive"].boolVal,
      children: @[start, stop, step])
  if name == "path":
    if value.body.len < 2:
      raise webError(loc, "web path requires a base and member")
    var qualifiedSegments: seq[string]
    var qualified = true
    for segment in value.body:
      if segment.kind != vkSymbol: qualified = false
      else: qualifiedSegments.add segment.symVal
    let qualifiedName = qualifiedSegments.join("/")
    if qualified and analysis.signatures.hasKey(qualifiedName):
      let signature = analysis.signatures[qualifiedName]
      return WebExpr(kind: wekBinding,
        typ: WebType(kind: wtkCallback, params: signature.params,
          returnType: signature.returnType),
        loc: loc, text: signature.valueName)
    if value.body.len == 2 and value.body[0].kind == vkSymbol and
        value.body[1].kind == vkSymbol and
        analysis.enumDecls.hasKey(value.body[0].symVal):
      let declaration = analysis.enumDecls[value.body[0].symVal]
      let variant = findVariant(declaration, value.body[1].symVal)
      if variant.payload.len != 0:
        raise webError(loc, "web enum payload variant must be called")
      return WebExpr(kind: wekEnum,
        typ: WebType(kind: wtkNominal, name: declaration.sourceName),
        text: declaration.identityName & "/" & variant.sourceName, loc: loc)
    result = WebExpr(kind: wekPath, loc: loc)
    result.children.add analysis.analyzeExpr(value.body[0], bindings)
    for i in 1 ..< value.body.len:
      let segment = value.body[i]
      if segment.kind == vkSymbol:
        result.keys.add segment.symVal
      elif segment.kind == vkInt:
        result.keys.add segment.intToString
      elif segment.kind == vkNode and segment.head.isSym("unquote") and
          segment.body.len == 1:
        result.keys.add ""
        result.children.add analysis.analyzeExpr(segment.body[0], bindings)
      else:
        raise webError(loc, "web path segment must be static or `%` dynamic")
    let baseType = result.children[0].typ
    if baseType.kind == wtkList and result.keys.len == 1:
      result.typ = baseType.item
    elif baseType.kind == wtkNominal and result.keys.len == 1:
      if result.keys[0].len > 0 and
          result.keys[0].allCharsInSet({'0'..'9'}):
        result.typ = analysis.findBodyType(baseType, parseInt(result.keys[0]))
      else:
        result.typ = analysis.findField(baseType, result.keys[0])
      if result.typ == nil:
        raise webError(loc, "web type " & baseType.name & " has no field " &
          result.keys[0])
    elif expected != nil:
      result.typ = expected
    else:
      result.typ = webType(wtkAny)
    return
  if name == "select":
    if value.body.len == 0:
      raise webError(loc, "web selector requires at least one segment")
    result = WebExpr(kind: wekSelector,
      typ: if expected != nil: expected
           else: WebType(kind: wtkCallback, params: @[webType(wtkAny)],
                         returnType: webType(wtkAny)), loc: loc)
    if value.props.hasKey("strict"):
      if value.props["strict"].kind != vkBool:
        raise webError(loc, "web selector ^strict must be Bool")
      result.boolValue = value.props["strict"].boolVal
    if value.props.hasKey("default"):
      result.propCount = 1
      result.children.add analysis.analyzeExpr(value.props["default"], bindings)
    for segment in value.body:
      if segment.kind == vkSymbol: result.keys.add segment.symVal
      elif segment.kind == vkInt: result.keys.add segment.intToString
      elif segment.kind == vkNode and segment.head.isSym("unquote") and
          segment.body.len == 1:
        result.keys.add ""
        result.children.add analysis.analyzeExpr(segment.body[0], bindings)
      else: raise webError(loc, "unsupported web selector segment")
    return
  if name == "set!":
    if value.body.len != 2 or value.body[0].kind != vkNode or
        not value.body[0].head.isSym("path"):
      raise webError(loc, "web set! expects a slash path and value")
    var pathExpr = analysis.analyzeCall(value.body[0], bindings, nil)
    let assigned = analysis.analyzeExpr(value.body[1], bindings, pathExpr.typ)
    return WebExpr(kind: wekSetPath, typ: assigned.typ, loc: loc,
      keys: pathExpr.keys, children: pathExpr.children & @[assigned])
  if name == "new":
    if value.body.len < 1 or value.body[0].kind != vkSymbol or
        not analysis.typeDecls.hasKey(value.body[0].symVal):
      raise webError(loc, "web new expects a declared type")
    let declaration = analysis.typeDecls[value.body[0].symVal]
    let constructor = analysis.findConstructor(declaration)
    if constructor == nil:
      raise webError(loc, "web type " & declaration.sourceName &
        " has no constructor")
    if value.body.len - 1 != constructor.params.len:
      raise webError(loc, "web constructor " & declaration.sourceName &
        " expects " & $constructor.params.len & " argument(s)")
    result = WebExpr(kind: wekNew,
      typ: WebType(kind: wtkNominal, name: declaration.sourceName),
      loc: loc, text: declaration.emittedName, boolValue: true)
    for i in 1 ..< value.body.len:
      result.children.add analysis.analyzeExpr(value.body[i], bindings,
        constructor.params[i - 1].typ)
    return
  if name == "fail":
    if value.body.len != 1:
      raise webError(loc, "web fail expects one error value")
    let errorValue = analysis.analyzeExpr(value.body[0], bindings)
    if errorValue.typ.kind != wtkNominal or
        errorValue.typ.name notin analysis.errorTypes:
      raise webError(loc, "web fail value must implement Error")
    return WebExpr(kind: wekFail, typ: webType(wtkNever), loc: loc,
      children: @[errorValue])
  if name == "try":
    var i = 0
    var tryForms: seq[Value]
    while i < value.body.len and not (value.body[i].isSym("catch") or
                                      value.body[i].isSym("ensure")):
      tryForms.add value.body[i]
      inc i
    if tryForms.len == 0:
      raise webError(loc, "web try requires a body")
    var tryBindings = copyBindings(bindings)
    let tryBody = analysis.analyzeSequence(tryForms, tryBindings, expected, loc)
    result = WebExpr(kind: wekTry, typ: tryBody.typ, loc: loc,
                     children: @[tryBody])
    while i < value.body.len and value.body[i].isSym("catch"):
      inc i
      if i >= value.body.len:
        raise webError(loc, "web catch requires a pattern")
      let pattern = value.body[i]
      inc i
      var catchForms: seq[Value]
      while i < value.body.len and not (value.body[i].isSym("catch") or
                                        value.body[i].isSym("ensure")):
        catchForms.add value.body[i]
        inc i
      var catchBindings = copyBindings(bindings)
      bindPattern(analysis, pattern, webType(wtkAny), catchBindings)
      let catchBody = analysis.analyzeSequence(catchForms, catchBindings,
                                               expected, loc)
      result.patterns.add pattern
      result.keys.add "catch"
      result.children.add catchBody
      result.typ = unionType(result.typ, catchBody.typ)
    if i < value.body.len:
      if not value.body[i].isSym("ensure"):
        raise webError(loc, "unexpected form after web try catches")
      inc i
      var ensureForms: seq[Value]
      while i < value.body.len:
        ensureForms.add value.body[i]
        inc i
      var ensureBindings = copyBindings(bindings)
      result.children.add analysis.analyzeSequence(ensureForms,
        ensureBindings, nil, loc)
      result.keys.add "ensure"
    return
  if name == "yield":
    if analysis.generatorDepth == 0 or value.body.len != 1:
      raise webError(loc, "web yield expects one value inside a stream function")
    let yielded = analysis.analyzeExpr(value.body[0], bindings,
      if value.body[0].kind == vkVoid: nil else: analysis.currentYield)
    return WebExpr(kind: wekYield, typ: webType(wtkVoid), loc: loc,
                   children: @[yielded])
  if name == "scope":
    inc analysis.scopeDepth
    var scopeBindings = copyBindings(bindings)
    let body = analysis.analyzeSequence(value.body, scopeBindings,
                                        expected, loc)
    dec analysis.scopeDepth
    return WebExpr(kind: wekScope, typ: body.typ, loc: loc,
                   children: @[body])
  if name == "spawn":
    if analysis.scopeDepth == 0 or value.body.len != 1:
      raise webError(loc, "web spawn expects one expression inside scope")
    let body = analysis.analyzeExpr(value.body[0], bindings)
    return WebExpr(kind: wekSpawn, typ: webType(wtkTask, body.typ), loc: loc,
                   children: @[body])
  if name == "await":
    if value.body.len != 1:
      raise webError(loc, "web await expects one Task")
    let task = analysis.analyzeExpr(value.body[0], bindings)
    if task.typ.kind != wtkTask:
      raise webError(loc, "web await expects Task, got " & typeName(task.typ))
    return WebExpr(kind: wekAwait, typ: task.typ.item, loc: loc,
                   children: @[task])
  if name == "fn" and value.body.len > 0 and value.body[0].kind == vkList:
    # An inline callback. The profile has had `Callback` types since P2 but no
    # way to write one, so every callback had to be a named top-level function
    # — which closes over nothing, and therefore cannot carry the one thing a
    # callback usually needs: the values from the site that registered it.
    #
    # A named `(fn name [...] ...)` is a declaration handled elsewhere; the
    # parameter list in body[0] is what distinguishes the two.
    if value.body.len < 4 or not value.body[1].isSym(":"):
      raise webError(loc,
        "web callback requires annotated parameters, a return type, and a body")
    if containsForm(value, "yield"):
      raise webError(loc,
        "web callback cannot be a generator: name it and use (fn name ...)")
    analysis.validateCallableProps(value, loc, "callback")
    let params = parseParams(analysis, value.body[0], loc)
    let returnType = parseWebType(value.body[2], loc)
    # Copied, not shared: the body may shadow and rebind freely, and those
    # bindings must not escape into the enclosing scope.
    var inner = copyBindings(bindings)
    var seen = initHashSet[string]()
    for param in params:
      if param.sourceName in seen:
        raise webError(param.loc,
          "duplicate web callback parameter: " & param.sourceName)
      seen.incl param.sourceName
      # A parameter shadowing an enclosing binding is ordinary lexical scoping,
      # and JS gives the arrow function the same rule.
      inner[param.sourceName] = WebBinding(typ: param.typ)
    let savedReturn = analysis.currentReturn
    analysis.currentReturn = returnType
    var bodyForms: seq[Value]
    for i in 3 ..< value.body.len: bodyForms.add value.body[i]
    let bodyExpected = if returnType.isStatementType: nil else: returnType
    let body = analysis.analyzeSequence(bodyForms, inner, bodyExpected, loc)
    analysis.currentReturn = savedReturn
    if not returnType.isStatementType:
      requireType(analysis, loc, body.typ, returnType, "return of web callback")
    if usesAsyncPrimitive(body):
      # The value's type is `Callback`, which carries no asyncness, so a caller
      # would drop the `await` and hand a Promise to a typed boundary — the
      # same rule `checkFunctionValueRefs` enforces for named functions.
      raise webError(loc,
        "web callback cannot await: Callback types carry no asyncness")
    var callbackType = webType(wtkCallback)
    for param in params: callbackType.params.add param.typ
    callbackType.returnType = returnType
    return WebExpr(kind: wekLambda, typ: callbackType, loc: loc,
                   params: params, children: @[body])
  if name == "do":
    return analysis.analyzeSequence(value.body, bindings, expected, loc)
  if name in ["let", "var"]:
    if value.body.len notin [2, 4]:
      raise webError(loc, "web " & name &
        " expects a pattern, optional type annotation, and value")
    let pattern = value.body[0]
    var declared: WebType = nil
    var initializerIndex = 1
    if value.body.len == 4:
      if not value.body[1].isSym(":"):
        raise webError(loc, "web " & name & " annotation requires `:`")
      declared = parseWebType(value.body[2], loc)
      initializerIndex = 3
    let initializer = analysis.analyzeExpr(value.body[initializerIndex],
                                            bindings, declared)
    let typ = if declared == nil: initializer.typ else: declared
    if pattern.kind == vkSymbol:
      let bindingName = pattern.symVal
      if bindings.hasKey(bindingName):
        raise webError(loc, "duplicate web binding: " & bindingName)
      bindings[bindingName] = WebBinding(typ: typ, mutable: name == "var")
      return WebExpr(kind: wekBind, typ: typ, loc: loc,
        text: mangleWebName(bindingName), mutable: name == "var",
        children: @[initializer])
    bindPattern(analysis, pattern, typ, bindings, name == "var")
    return WebExpr(kind: wekBind, typ: typ, loc: loc,
      mutable: name == "var", children: @[initializer], patterns: @[pattern])
  if name == "set":
    if value.body.len != 2 or value.body[0].kind != vkSymbol:
      raise webError(loc, "web set expects a bare binding and value")
    let bindingName = value.body[0].symVal
    if not bindings.hasKey(bindingName):
      raise webError(loc, "set of unresolved web binding: " & bindingName)
    if not bindings[bindingName].mutable:
      raise webError(loc, "cannot set immutable web binding: " & bindingName)
    let assigned = analysis.analyzeExpr(value.body[1], bindings,
                                        bindings[bindingName].typ)
    return WebExpr(kind: wekSet, typ: assigned.typ, loc: loc,
      text: mangleWebName(bindingName), children: @[assigned])
  if name in ["if_yes", "if_not"]:
    if value.body.len < 2:
      raise webError(loc, "web " & name & " expects a condition and body")
    let condition = analysis.analyzeExpr(value.body[0], bindings)
    var branchBindings = copyBindings(bindings)
    let branch = analysis.analyzeSequence(value.body.toOpenArray(1,
      value.body.high), branchBindings, expected, loc)
    let nilExpr = WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
    let yes = if name == "if_yes": branch else: nilExpr
    let no = if name == "if_yes": nilExpr else: branch
    return WebExpr(kind: wekIf, typ: unionType(branch.typ, nilExpr.typ),
      loc: loc, children: @[condition, yes, no])
  if name == "while":
    if value.body.len < 1:
      raise webError(loc, "web while expects a condition")
    let condition = analysis.analyzeExpr(value.body[0], bindings)
    inc analysis.loopDepth
    var loopBindings = copyBindings(bindings)
    var bodyForms: seq[Value]
    for i in 1 ..< value.body.len: bodyForms.add value.body[i]
    let body = analysis.analyzeSequence(bodyForms, loopBindings, nil, loc)
    dec analysis.loopDepth
    return WebExpr(kind: wekWhile, typ: webType(wtkNil), loc: loc,
      children: @[condition, body])
  if name == "loop":
    inc analysis.loopDepth
    var loopBindings = copyBindings(bindings)
    let body = analysis.analyzeSequence(value.body, loopBindings, nil, loc)
    dec analysis.loopDepth
    return WebExpr(kind: wekLoop, typ: webType(wtkNil), loc: loc,
      children: @[body])
  if name == "repeat":
    if value.body.len < 1:
      raise webError(loc, "web repeat expects a count")
    var countIndex = 0
    var indexName = ""
    if value.body.len >= 3 and value.body[0].kind == vkSymbol and
        value.body[1].isSym("in"):
      indexName = value.body[0].symVal
      countIndex = 2
    let count = analysis.analyzeExpr(value.body[countIndex], bindings,
                                     webType(wtkInt))
    inc analysis.loopDepth
    var loopBindings = copyBindings(bindings)
    if indexName.len > 0:
      loopBindings[indexName] = WebBinding(typ: webType(wtkInt))
    let bodyStart = countIndex + 1
    var bodyForms: seq[Value]
    for i in bodyStart ..< value.body.len: bodyForms.add value.body[i]
    let body = analysis.analyzeSequence(bodyForms, loopBindings, nil, loc)
    dec analysis.loopDepth
    return WebExpr(kind: wekRepeat, typ: webType(wtkNil), loc: loc,
      text: mangleWebName(indexName), children: @[count, body])
  if name == "for":
    if value.body.len < 3 or not value.body[1].isSym("in"):
      raise webError(loc, "web for requires `for pattern in iterable`")
    let iterable = analysis.analyzeExpr(value.body[2], bindings)
    var itemType: WebType
    case iterable.typ.kind
    of wtkList, wtkStream: itemType = iterable.typ.item
    of wtkRange: itemType = webType(wtkInt)
    of wtkStr: itemType = webType(wtkStr)
    of wtkNil, wtkVoid: itemType = webType(wtkAny)
    else: raise webError(loc, "web for cannot iterate " & typeName(iterable.typ))
    inc analysis.loopDepth
    var loopBindings = copyBindings(bindings)
    bindPattern(analysis, value.body[0], itemType, loopBindings)
    var bodyForms: seq[Value]
    for i in 3 ..< value.body.len: bodyForms.add value.body[i]
    let body = analysis.analyzeSequence(bodyForms, loopBindings, nil, loc)
    dec analysis.loopDepth
    return WebExpr(kind: wekFor, typ: webType(wtkNil), loc: loc,
      text: if value.body[0].kind == vkSymbol:
              mangleWebName(value.body[0].symVal)
            else: "",
      patterns: @[value.body[0]], children: @[iterable, body])
  if name in ["break", "continue"]:
    if value.body.len != 0:
      raise webError(loc, "web " & name & " expects no arguments")
    if analysis.loopDepth == 0:
      raise webError(loc, name & " is only valid inside a web loop")
    return WebExpr(kind: if name == "break": wekBreak else: wekContinue,
      typ: webType(wtkNever), loc: loc)
  if name == "match":
    if value.body.len < 2:
      raise webError(loc, "web match expects a value and at least one arm")
    let matched = analysis.analyzeExpr(value.body[0], bindings)
    result = WebExpr(kind: wekMatch, loc: loc, children: @[matched])
    var resultType: WebType = nil
    var hasElse = false
    for i in 1 ..< value.body.len:
      let arm = value.body[i]
      if arm.kind != vkNode or arm.head.kind != vkSymbol:
        raise webError(loc, "web match arms must be when or else clauses")
      var armBindings = copyBindings(bindings)
      var bodyStart = 0
      if arm.head.symVal == "when":
        if arm.body.len < 2:
          raise webError(loc, "web match when requires a pattern and body")
        result.patterns.add analysis.normalizeWebPattern(arm.body[0])
        result.keys.add "when"
        bindPattern(analysis, arm.body[0], matched.typ, armBindings)
        bodyStart = 1
      elif arm.head.symVal == "else":
        if hasElse or i != value.body.high:
          raise webError(loc, "web match else must be the final unique arm")
        hasElse = true
        result.patterns.add Value()
        result.keys.add "else"
      else:
        raise webError(loc, "web match arms must be when or else clauses")
      var armForms: seq[Value]
      for j in bodyStart ..< arm.body.len: armForms.add arm.body[j]
      let analyzed = analysis.analyzeSequence(armForms, armBindings,
                                               expected, loc)
      result.children.add analyzed
      resultType = if resultType == nil: analyzed.typ
                   else: unionType(resultType, analyzed.typ)
    result.typ = if resultType == nil: webType(wtkNever) else: resultType
    return
  if name == "return":
    if value.body.len > 1:
      raise webError(loc, "web return expects zero or one value")
    # Same rule as the VM compiler: under a `Nil`/`Void` signature the frame
    # yields the declared unit, so a returned value could only be discarded.
    if analysis.currentReturn != nil and
        analysis.currentReturn.isStatementType and value.body.len == 1 and
        value.body[0].kind notin {vkNil, vkVoid}:
      raise webError(loc,
        "return in a Nil/Void function takes no value; " &
        "use (return) or (return nil)")
    let returned = if value.body.len == 0:
      WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
    else: analysis.analyzeExpr(value.body[0], bindings, analysis.currentReturn)
    if analysis.currentReturn != nil and
        not analysis.currentReturn.isStatementType:
      requireType(analysis, loc, returned.typ, analysis.currentReturn,
        "web return")
    return WebExpr(kind: wekReturn, typ: webType(wtkNever), loc: loc,
      children: @[returned])
  if name == "if":
    if value.body.len >= 2 and value.body[1].kind == vkNode and
        value.body[1].head.isSym("then"):
      let condition = analysis.analyzeExpr(value.body[0], bindings)
      var yesBindings = copyBindings(bindings)
      let yes = analysis.analyzeSequence(value.body[1].body, yesBindings,
                                          expected, loc)
      var no = WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
      for i in countdown(value.body.high, 2):
        let clause = value.body[i]
        if clause.kind != vkNode or clause.head.kind != vkSymbol:
          raise webError(loc, "web if clauses must be elif or else")
        if clause.head.symVal == "else":
          if i != value.body.high:
            raise webError(loc, "web if else must be final")
          var elseBindings = copyBindings(bindings)
          no = analysis.analyzeSequence(clause.body, elseBindings,
                                        expected, loc)
        elif clause.head.symVal == "elif":
          if clause.body.len < 2:
            raise webError(loc, "web elif requires condition and body")
          var elifBindings = copyBindings(bindings)
          let elifCondition = analysis.analyzeExpr(clause.body[0], elifBindings)
          var elifForms: seq[Value]
          for j in 1 ..< clause.body.len: elifForms.add clause.body[j]
          let elifYes = analysis.analyzeSequence(elifForms, elifBindings,
                                                 expected, loc)
          no = WebExpr(kind: wekIf, typ: unionType(elifYes.typ, no.typ),
            loc: loc, children: @[elifCondition, elifYes, no])
        else:
          raise webError(loc, "web if clauses must be elif or else")
      return WebExpr(kind: wekIf, typ: unionType(yes.typ, no.typ), loc: loc,
                     children: @[condition, yes, no])
    if value.body.len notin [2, 3]:
      raise webError(loc, "web if expects a condition and one or two branches")
    let condition = analysis.analyzeExpr(value.body[0], bindings)
    var yesBindings = copyBindings(bindings)
    let yes = analysis.analyzeExpr(value.body[1], yesBindings, expected)
    let no =
      if value.body.len == 3:
        block:
          var noBindings = copyBindings(bindings)
          analysis.analyzeExpr(value.body[2], noBindings, expected)
      else:
        WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
    let joined = unionType(yes.typ, no.typ)
    if expected != nil and not accepts(analysis, expected, joined):
      raise webError(loc, "web if branches do not join into " & typeName(expected))
    return WebExpr(kind: wekIf, typ: joined, loc: loc,
                   children: @[condition, yes, no])
  if name in ["!", "&&", "||", "??"]:
    if name == "!":
      if value.body.len != 1:
        raise webError(loc, "web ! expects one operand")
      return WebExpr(kind: wekNot, typ: webType(wtkBool), loc: loc,
        children: @[analysis.analyzeExpr(value.body[0], bindings)])
    if value.body.len == 0:
      if name == "&&":
        return WebExpr(kind: wekBool, typ: webType(wtkBool), loc: loc,
                       boolValue: true)
      return WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
    let kind = case name
      of "&&": wekAnd
      of "||": wekOr
      else: wekCoalesce
    result = analysis.analyzeExpr(value.body[0], bindings)
    for i in 1 ..< value.body.len:
      let right = analysis.analyzeExpr(value.body[i], bindings)
      let joined = if kind == wekCoalesce:
                     unionType(withoutAbsent(result.typ), right.typ)
                   else: unionType(result.typ, right.typ)
      result = WebExpr(kind: kind, typ: joined,
        loc: loc, children: @[result, right])
    if expected != nil and not accepts(analysis, expected, result.typ):
      raise webError(loc, "web " & name & " operands do not join into " &
        typeName(expected))
    return
  # The closed operator set of design §7.4. `//` is the truncated remainder,
  # not integer division: `%` is the unquote prefix and `mod` names the module
  # form, so `%` never denotes arithmetic and is deliberately absent here.
  if name == "$":
    # Concatenation is variadic, because `$"a ${x} b"` desugars to one `$` per
    # *segment*: capping it at two operands rejected every interpolation with
    # more than one hole, which is most of them.
    if value.body.len == 0:
      raise webError(loc, "web $ requires at least one Str value")
    # Every scalar the VM's `$` displays. Restricting this to `Str` made
    # `$"n=${count}"` compile on the server and fail in the browser — the exact
    # silent-divergence class §5 of the proposal exists to prevent. Containers
    # stay out: their display is `print` semantics, a much larger contract than
    # interpolation needs.
    const displayable = {wtkStr, wtkInt, wtkF64, wtkBool, wtkNil, wtkVoid,
                         wtkSym}
    var parts: seq[WebExpr]
    for item in value.body:
      let part = analysis.analyzeExpr(item, bindings)
      var kinds: set[WebTypeKind]
      if part.typ.kind == wtkUnion:
        for member in part.typ.members: kinds.incl member.kind
      else:
        kinds.incl part.typ.kind
      if not (kinds <= displayable):
        raise webError(loc, "web $ displays Str, Int, F64, Bool, Nil, Void, " &
          "and Sym values, got " & typeName(part.typ))
      parts.add part
    if parts.len == 1 and parts[0].typ.kind == wtkStr:
      return parts[0]
    if parts.len == 1:
      # `$"${n}"` is a conversion, not a concatenation. Folding against an
      # empty literal keeps one code path and still yields a Str — returning
      # the operand unchanged would silently type the whole expression as Int.
      parts.insert(WebExpr(kind: wekStr, typ: webType(wtkStr), loc: loc,
                           text: ""), 0)
    result = parts[0]
    for i in 1 ..< parts.len:
      result = WebExpr(kind: wekBinary, typ: webType(wtkStr), loc: loc,
                       text: "$", children: @[result, parts[i]])
    return
  if name in ["+", "-", "*", "/", "//", "<", "<=", ">", ">=",
              "==", "!=", "same?"]:
    if value.body.len != 2:
      raise webError(loc, "web operator '" & name & "' expects two operands")
    let left = analysis.analyzeExpr(value.body[0], bindings)
    let right = analysis.analyzeExpr(value.body[1], bindings, left.typ)
    if not sameType(left.typ, right.typ):
      raise webError(loc, "web operator '" & name & "' requires identical types")
    if name in ["+", "-", "*", "/", "//", "<", "<=", ">", ">="] and
        left.typ.kind notin {wtkInt, wtkF64}:
      raise webError(loc, "web operator '" & name & "' requires Int or F64")
    let resultType =
      if name in ["<", "<=", ">", ">=", "==", "!=", "same?"]:
        webType(wtkBool)
      else: left.typ
    return WebExpr(kind: wekBinary, typ: resultType, loc: loc, text: name,
                   children: @[left, right])
  if analysis.typeDecls.hasKey(name):
    let declaration = analysis.typeDecls[name]
    result = WebExpr(kind: wekNew,
      typ: WebType(kind: wtkNominal, name: name), loc: loc,
      text: declaration.emittedName, immutable: value.nodeImmutable)
    var seen = initHashSet[string]()
    for key, fieldValue in value.props:
      let fieldType = analysis.findField(result.typ, key)
      if fieldType == nil:
        raise webError(loc, "unknown field ^" & key & " for web type " & name)
      seen.incl key
      result.keys.add key
      result.children.add analysis.analyzeExpr(fieldValue, bindings, fieldType)
      inc result.propCount
    for field in analysis.analysisFields(declaration):
      if not field.optional and field.sourceName notin seen:
        raise webError(loc, "missing required field ^" & field.sourceName &
          " for web type " & name)
    let bodySchema = analysis.analysisBodySchema(declaration)
    if value.body.len < bodySchema.fixed.len or
        (bodySchema.rest == nil and value.body.len > bodySchema.fixed.len):
      raise webError(loc, "web type " & name & " body expects " &
        $bodySchema.fixed.len &
        (if bodySchema.rest == nil: " value(s)" else: " or more values"))
    for i, bodyValue in value.body:
      let bodyType = if i < bodySchema.fixed.len: bodySchema.fixed[i]
                     else: bodySchema.rest
      result.children.add analysis.analyzeExpr(bodyValue, bindings, bodyType)
    return
  var signature: WebFunctionSig
  var resolvedName = name
  if not analysis.signatures.hasKey(resolvedName) and
      analysis.currentNamespace.len > 0:
    let qualified = (analysis.currentNamespace & @[name]).join("/")
    if analysis.signatures.hasKey(qualified): resolvedName = qualified
  if analysis.signatures.hasKey(resolvedName):
    signature = analysis.signatures[resolvedName]
  elif bindings.hasKey(name) and bindings[name].typ.kind == wtkCallback:
    signature = WebFunctionSig(params: bindings[name].typ.params,
      returnType: bindings[name].typ.returnType,
      callName: mangleWebName(name), valueName: mangleWebName(name))
  else:
    raise webError(loc, "call to unknown or unsupported web function: " & name)
  result = analysis.analyzeKnownCall(value, bindings, expected, resolvedName,
                                     signature, loc)

proc analyzeExpr(analysis: WebAnalysis, value: Value,
                 bindings: var Table[string, WebBinding],
                 expected: WebType = nil): WebExpr =
  let loc = analysis.locFor(value)
  if loc.hasSourceLoc:
    analysis.currentLoc = loc
  case value.kind
  of vkNil:
    result = WebExpr(kind: wekNil, typ: webType(wtkNil), loc: loc)
  of vkVoid:
    result = WebExpr(kind: wekVoid, typ: webType(wtkVoid), loc: loc)
  of vkBool:
    result = WebExpr(kind: wekBool, typ: webType(wtkBool), loc: loc,
                     boolValue: value.boolVal)
  of vkString:
    result = WebExpr(kind: wekStr, typ: webType(wtkStr), loc: loc,
                     text: value.strVal)
  of vkFloat:
    result = WebExpr(kind: wekF64, typ: webType(wtkF64), loc: loc,
                     text: $value.floatVal)
  of vkInt:
    result = WebExpr(kind: wekInt, typ: webType(wtkInt), loc: loc,
                     text: value.intToString)
  of vkSymbol:
    if bindings.hasKey(value.symVal):
      result = WebExpr(kind: wekBinding, typ: bindings[value.symVal].typ, loc: loc,
                       text: mangleWebName(value.symVal))
    elif analysis.signatures.hasKey(value.symVal):
      let signature = analysis.signatures[value.symVal]
      # A callback type carries no asyncness, so a caller invoking it through
      # the binding would drop the `await` and hand a Promise to a typed
      # boundary. Whether this callee is async is only known after propagation,
      # so record the reference and check it there.
      analysis.functionValueRefs.add WebFunctionValueRef(name: value.symVal,
                                                         loc: loc)
      result = WebExpr(kind: wekBinding,
        typ: WebType(kind: wtkCallback, params: signature.params,
                     returnType: signature.returnType),
        loc: loc, text: signature.valueName)
    else:
      raise webError(loc, "unresolved web binding: " & value.symVal)
  of vkList:
    var itemType = if expected != nil and expected.kind == wtkList:
                     expected.item else: nil
    result = WebExpr(kind: wekList, loc: loc,
                     immutable: value.listImmutable)
    for item in value.listItems:
      let analyzed = analysis.analyzeExpr(item, bindings, itemType)
      if itemType == nil: itemType = analyzed.typ
      requireType(analysis, loc, analyzed.typ, itemType, "list item")
      result.children.add analyzed
    if itemType == nil:
      raise webError(loc, "empty web list requires an expected (List T) type")
    result.typ = webType(wtkList, itemType)
  of vkMap:
    result = WebExpr(kind: wekPropMap, typ: webType(wtkPropMap), loc: loc,
                     immutable: value.mapImmutable)
    for key, item in value.mapEntries:
      result.keys.add key
      result.children.add analysis.analyzeExpr(item, bindings)
  of vkHashMap:
    var keyType, valueType: WebType
    result = WebExpr(kind: wekMap, loc: loc)
    for entry in value.hashMapEntries:
      let key = analysis.analyzeExpr(entry.key, bindings, keyType)
      let item = analysis.analyzeExpr(entry.val, bindings, valueType)
      if keyType == nil: keyType = key.typ
      if valueType == nil: valueType = item.typ
      requireType(analysis, loc, key.typ, keyType, "map key")
      requireType(analysis, loc, item.typ, valueType, "map value")
      result.children.add key
      result.children.add item
    if keyType == nil or valueType == nil:
      if expected == nil or expected.kind != wtkMap:
        raise webError(loc, "empty web Map requires an expected (Map K V) type")
      keyType = expected.params[0]
      valueType = expected.params[1]
    result.typ = WebType(kind: wtkMap, params: @[keyType, valueType])
  of vkNode:
    result = analysis.analyzeCall(value, bindings, expected)
  else:
    raise webError(loc, $value.kind & " is outside the web profile")
  if expected != nil:
    if result.typ.kind == wtkAny and expected.kind != wtkAny:
      result = WebExpr(kind: wekCheck, typ: expected, loc: loc,
        children: @[result])
    requireType(analysis, loc, result.typ, expected, "web expression")

proc awaitsAtRuntime(expr: WebExpr): bool =
  ## Every construct the emitter lowers with a JS `await`: the enclosing
  ## function has to be `async` or the emitted module does not parse. A call is
  ## included when its callee is async, which is what makes asyncness a property
  ## of the call graph rather than of one body. Only meaningful once
  ## `resolveAsync` has settled every call site.
  if expr == nil: return false
  if expr.kind in {wekAwait, wekScope}: return true
  if expr.kind == wekCall and expr.boolValue: return true
  for child in expr.children:
    if awaitsAtRuntime(child): return true

proc usesAsyncPrimitive(expr: WebExpr): bool =
  ## The two forms that make a function async on their own. `spawn` is not one:
  ## it is only legal inside a `scope`, which already is.
  if expr == nil: return false
  if expr.kind in {wekAwait, wekScope}: return true
  for child in expr.children:
    if usesAsyncPrimitive(child): return true

proc checkFunctionValueRefs(analysis: WebAnalysis) =
  for reference in analysis.functionValueRefs:
    if analysis.signatures.hasKey(reference.name) and
        analysis.signatures[reference.name].async:
      raise webError(reference.loc, "web async function '" & reference.name &
        "' cannot be used as a callback value: callback types are synchronous")
  analysis.functionValueRefs.setLen(0)

proc resolveAsync(analysis: WebAnalysis, functions: openArray[WebFunction]) =
  ## Asyncness is a property of the call graph: the emitter writes `await` at a
  ## call site because the *callee* is async, so the caller must be async too,
  ## transitively and across module boundaries.
  ##
  ## One reverse-edge worklist pass over the edges recorded during analysis
  ## settles this in O(functions + call sites). Re-analyzing every body until the
  ## flags converge costs a full analysis pass per link in the longest caller
  ## chain, which is quadratic on a chain of mutually calling functions.
  var callers = initTable[string, seq[string]]()
  for site in analysis.callSites:
    if site.caller.len == 0: continue # a method body cannot become async
    callers.mgetOrPut(site.callee, @[]).add site.caller
  var asyncNames = initHashSet[string]()
  var pending: seq[string]
  proc mark(name: string) =
    if name.len == 0 or name in asyncNames: return
    asyncNames.incl name
    pending.add name
  # An imported signature already carries its own module's resolved asyncness,
  # which is what carries the property across the module graph.
  for name, signature in analysis.signatures:
    if signature.async: mark(name)
  for fn in functions:
    if usesAsyncPrimitive(fn.body): mark(fn.sourceName)
  while pending.len > 0:
    let callee = pending.pop()
    if not callers.hasKey(callee): continue
    for caller in callers[callee]: mark(caller)
  for fn in functions:
    if fn.sourceName notin asyncNames: continue
    fn.async = true
    var signature = analysis.signatures[fn.sourceName]
    signature.async = true
    analysis.signatures[fn.sourceName] = signature
    if fn.generator:
      raise webError(fn.loc, "web generator '" & fn.sourceName &
        "' cannot be async: GeneStream wraps a synchronous iterator")
  # Each call site recorded whatever the callee's flag was mid-pass; rewrite them
  # all from the settled signatures.
  for site in analysis.callSites:
    site.expr.boolValue = analysis.signatures[site.callee].async
  analysis.callSites.setLen(0)
  analysis.checkFunctionValueRefs()

proc rejectAsyncBody(body: WebExpr, loc: SourceLoc, label: string) =
  ## Only top-level functions carry an `async` flag through to emission — a
  ## method or constructor has nowhere to put one, and a send has nowhere to put
  ## the matching `await`. Reject instead of emitting an `await` in a plain
  ## method body.
  if awaitsAtRuntime(body):
    raise webError(loc, "web async is limited to top-level functions: " &
      label & " cannot use scope/await or call an async function")

proc analyzeWebUnitWithImports(unit: SourceUnit, sourcePath: string,
                               imported: Table[string, WebFunctionSig],
                               importedTypes: Table[string, WebTypeDecl],
                               importedEnums: Table[string, WebEnumDecl],
                               importedProtocols: Table[string, WebProtocolDecl],
                               importedMacros: Table[string,
                                 Table[string, MacroDef]],
                               macroExports: var Table[string, MacroDef],
                               embedded = false): WebModule =
  let frontEnd = expandSourceUnitMacros(unit, importedMacros)
  macroExports = frontEnd.macroExports
  var analysis = WebAnalysis(
    unit: frontEnd.expanded,
    signatures: imported,
    typeDecls: importedTypes,
    enumDecls: importedEnums,
    protocolDecls: importedProtocols,
    errorTypes: initHashSet[string](),
    protocolImplTargets: initHashSet[string]())
  for name, declaration in importedTypes:
    if declaration.implementsError:
      analysis.errorTypes.incl name
    for protocolName in declaration.implementedProtocols:
      analysis.protocolImplTargets.incl(protocolName & "\x1f" & name)
  analysis.protocolDecls["Error"] = WebProtocolDecl(
    sourceName: "Error", emittedName: "Error")
  if analysis.unit.forms.len == 0:
    raise webError(SourceLoc(sourceName: sourcePath, line: 1, col: 1),
      "web build requires a module")
  let moduleForm = analysis.unit.forms[0]
  let moduleLoc = analysis.locFor(moduleForm,
                                  analysis.unit.formLocs[0])
  if moduleForm.kind != vkNode or not moduleForm.head.isSym("mod") or
      moduleForm.body.len != 1 or moduleForm.body[0].kind != vkSymbol:
    raise webError(moduleLoc, "web build requires `(mod name ^profile web)`")
  if not moduleForm.props.hasKey("profile") or
      not moduleForm.props["profile"].isSym("web"):
    raise webError(moduleLoc, "web module requires `^profile web`")
  rejectUnknownProps(moduleForm, moduleLoc, "mod", ["profile"])
  result = WebModule(name: moduleForm.body[0].symVal,
                     sourcePath: sourcePath, embedded: embedded,
                     loc: moduleLoc)
  # Declaration names and schemas are collected before executable bodies so
  # annotations, construction, recursion, and sends resolve independent of
  # source order.
  for i in 1 ..< analysis.unit.forms.len:
    let form = analysis.unit.forms[i]
    let loc = analysis.locFor(form, analysis.unit.formLocs[i])
    if form.kind != vkNode or form.head.kind != vkSymbol: continue
    if form.head.symVal == "type":
      let declaration = parseWebTypeDecl(analysis, form, loc)
      if analysis.typeDecls.hasKey(declaration.sourceName):
        raise webError(loc, "duplicate web type: " & declaration.sourceName)
      analysis.typeDecls[declaration.sourceName] = declaration
      result.types.add declaration
    elif form.head.symVal == "enum":
      let declaration = parseWebEnumDecl(form, loc)
      if analysis.enumDecls.hasKey(declaration.sourceName):
        raise webError(loc, "duplicate web enum: " & declaration.sourceName)
      analysis.enumDecls[declaration.sourceName] = declaration
      result.enums.add declaration
    elif form.head.symVal == "protocol":
      let declaration = parseWebProtocolDecl(analysis, form, loc)
      if analysis.protocolDecls.hasKey(declaration.sourceName):
        raise webError(loc, "duplicate web protocol: " & declaration.sourceName)
      analysis.protocolDecls[declaration.sourceName] = declaration
      result.protocols.add declaration
  for _, declaration in analysis.protocolDecls:
    if declaration.sourceName != "Error":
      result.visibleProtocols.add declaration
  for _, declaration in analysis.typeDecls:
    result.visibleTypes.add declaration
  for _, declaration in analysis.enumDecls:
    result.visibleEnums.add declaration
  for i in 1 ..< analysis.unit.forms.len:
    let form = analysis.unit.forms[i]
    let loc = analysis.locFor(form, analysis.unit.formLocs[i])
    if form.kind == vkNode and form.head.isSym("impl"):
      let implementation = parseWebImplDecl(analysis, form, loc)
      result.impls.add implementation
      analysis.protocolImplTargets.incl(
        implementation.protocolName & "\x1f" & implementation.targetName)
      if implementation.protocolName == "Error":
        analysis.errorTypes.incl implementation.targetName
        if analysis.typeDecls.hasKey(implementation.targetName):
          analysis.typeDecls[implementation.targetName].implementsError = true
      elif analysis.typeDecls.hasKey(implementation.targetName):
        analysis.typeDecls[implementation.targetName].implementedProtocols.add(
          implementation.protocolName)
  var headers: seq[tuple[form: Value, fn: WebFunction]]
  let moduleResult = result
  proc registerFunction(form: Value, namespacePath: seq[string],
                        loc: SourceLoc) =
    let fn = parseFunctionHeader(analysis, form)
    analysis.validateCallableProps(form, loc, "function " & fn.sourceName)
    let memberName = fn.sourceName
    if namespacePath.len > 0:
      fn.namespacePath = namespacePath
      fn.sourceName = (namespacePath & @[memberName]).join("/")
      fn.emittedName = mangleWebName((namespacePath & @[memberName]).join("$"))
    else:
      fn.publicExport = true
    if analysis.signatures.hasKey(fn.sourceName):
      raise webError(loc, "duplicate web function: " & fn.sourceName)
    var paramTypes: seq[WebType]
    for param in fn.params: paramTypes.add param.typ
    analysis.signatures[fn.sourceName] = WebFunctionSig(
      params: paramTypes, returnType: fn.returnType,
      callName: "$gene_impl_" & fn.emittedName,
      valueName: fn.emittedName, generator: fn.generator, async: fn.async)
    headers.add (form, fn)

  proc registerNamespace(form: Value, parentPath: seq[string],
                         loc: SourceLoc) =
    if form.body.len < 1 or form.body[0].kind != vkSymbol:
      raise webError(loc, "web ns requires a static name")
    rejectUnknownProps(form, loc, "ns", [])
    let path = parentPath & @[form.body[0].symVal]
    let declaration = WebNamespace(sourceName: form.body[0].symVal,
      emittedName: mangleWebName(path.join("$")), path: path)
    moduleResult.namespaces.add declaration
    for i in 1 ..< form.body.len:
      let member = form.body[i]
      let memberLoc = analysis.locFor(member, loc)
      if member.kind != vkNode or member.head.kind != vkSymbol:
        raise webError(memberLoc,
          "web ns accepts only static fn and nested ns declarations")
      if member.head.isSym("fn"):
        registerFunction(member, path, memberLoc)
        declaration.functions.add headers[^1].fn
      elif member.head.isSym("ns"):
        registerNamespace(member, path, memberLoc)
      else:
        raise webError(memberLoc, "web ns member '" & member.head.symVal &
          "' is outside the static namespace profile")

  for i in 1 ..< analysis.unit.forms.len:
    let form = analysis.unit.forms[i]
    let loc = analysis.locFor(form, analysis.unit.formLocs[i])
    if form.kind != vkNode:
      raise webError(loc, "top-level executable data is outside the web profile")
    if form.head.isPath(["js", "fn"]):
      if result.embedded:
        # Generated routes serve compiler output only. A `^from` specifier
        # inside an embedded block is either a bare specifier the server
        # cannot guarantee, or a hand-written host shim wearing a URL — and
        # admitting the second is how the one-authored-file property dies.
        raise webError(loc, "js/fn is outside an embedded web module: " &
          "generated routes serve compiler output, not authored files")
      let extern = parseWebExtern(analysis, form, loc)
      if analysis.signatures.hasKey(extern.sourceName):
        raise webError(loc, "duplicate web binding: " & extern.sourceName)
      var paramTypes: seq[WebType]
      for param in extern.params: paramTypes.add param.typ
      analysis.signatures[extern.sourceName] = WebFunctionSig(
        params: paramTypes, returnType: extern.returnType,
        callName: extern.emittedName, valueName: extern.emittedName,
        external: true)
      result.externs.add extern
      continue
    if form.head.kind != vkSymbol:
      raise webError(loc, "top-level form is outside the web profile")
    if form.head.symVal == "import":
      if result.embedded:
        # A relative path here would name a second file a human has to write
        # and keep in sync, which is exactly the product this form exists to
        # refuse. Compile-time macro imports disappear before emission and are
        # a different thing, but they are a host-module concern.
        raise webError(loc, "import is outside an embedded web module: " &
          "the block sees the web prelude and its own declarations only")
      var webImport = parseWebImport(form, loc, sourcePath)
      if importedMacros.hasKey(webImport.sourcePath):
        let macros = importedMacros[webImport.sourcePath]
        var runtimeSelections: seq[WebImportSelection]
        for selection in webImport.selections:
          if not macros.hasKey(selection.sourceName):
            runtimeSelections.add selection
        webImport.selections = runtimeSelections
      if webImport.selections.len > 0:
        result.imports.add webImport
      continue
    if form.head.symVal == "fn!":
      raise webError(loc,
        "fn! is outside the web profile: it requires a live evaluator and retained call syntax")
    if form.head.symVal in ["type", "enum", "protocol", "impl"]:
      continue
    case form.head.symVal
    of "derive":
      raise webError(loc,
        "derive is outside the web profile: it remains VM module-initialization behavior")
    of "import_impl":
      raise webError(loc,
        "import_impl is outside the web profile: web impl visibility must be fixed at compile time")
    of "ns":
      registerNamespace(form, @[], loc)
      continue
    else: discard
    if form.head.symVal != "fn":
      raise webError(loc, "top-level '" & form.head.symVal &
        "' is outside the web profile")
    registerFunction(form, @[], loc)
  for header in headers:
    var bindings = initTable[string, WebBinding]()
    for param in header.fn.params:
      if bindings.hasKey(param.sourceName):
        raise webError(param.loc, "duplicate web parameter: " & param.sourceName)
      bindings[param.sourceName] = WebBinding(typ: param.typ)
    analysis.currentReturn = header.fn.returnType
    analysis.currentNamespace = header.fn.namespacePath
    analysis.currentFunction = header.fn.sourceName
    if header.fn.generator:
      if header.fn.returnType.kind != wtkStream:
        raise webError(header.fn.loc,
          "web generator return annotation must be (Stream Item Error)")
      inc analysis.generatorDepth
      analysis.currentYield = header.fn.returnType.item
    let forms = header.form.body
    var bodyExprs: seq[WebExpr]
    for i in 4 ..< forms.len:
      let expected = if i == forms.high and not header.fn.generator and
                        not header.fn.returnType.isStatementType:
                       header.fn.returnType
                     else: nil
      bodyExprs.add analysis.analyzeExpr(forms[i], bindings, expected)
    if bodyExprs.len == 0:
      raise webError(header.fn.loc, "web function requires a body")
    if bodyExprs.len == 1:
      header.fn.body = bodyExprs[0]
    else:
      header.fn.body = WebExpr(kind: wekDo, typ: bodyExprs[^1].typ,
                               loc: header.fn.loc, children: bodyExprs)
    if header.fn.generator:
      dec analysis.generatorDepth
      analysis.currentYield = nil
    elif not header.fn.returnType.isStatementType:
      requireType(analysis, header.fn.loc, header.fn.body.typ,
                  header.fn.returnType,
                  "return of " & header.fn.sourceName)
    result.functions.add header.fn
  analysis.currentFunction = ""
  analysis.resolveAsync(result.functions)
  analysis.currentReturn = nil
  analysis.currentNamespace = @[]
  for declaration in result.types:
    let selfType = WebType(kind: wtkNominal, name: declaration.sourceName)
    for methodDecl in declaration.methods:
      var bindings = initTable[string, WebBinding]()
      bindings["self"] = WebBinding(typ: selfType)
      for param in methodDecl.params:
        bindings[param.sourceName] = WebBinding(typ: param.typ)
      var forms: seq[Value]
      for i in 4 ..< methodDecl.sourceForm.body.len:
        forms.add methodDecl.sourceForm.body[i]
      analysis.currentReturn = methodDecl.returnType
      analysis.currentTypeName = declaration.sourceName
      analysis.validateCallableProps(methodDecl.sourceForm, methodDecl.loc,
        "message " & methodDecl.sourceName)
      methodDecl.body = analysis.analyzeSequence(forms, bindings,
        (if methodDecl.returnType.isStatementType: nil
         else: methodDecl.returnType), methodDecl.loc)
      if not methodDecl.returnType.isStatementType:
        requireType(analysis, methodDecl.loc, methodDecl.body.typ,
                    methodDecl.returnType,
                    "return of message " & methodDecl.sourceName)
      rejectAsyncBody(methodDecl.body, methodDecl.loc,
        "message " & methodDecl.sourceName)
    if declaration.constructor != nil:
      var bindings = initTable[string, WebBinding]()
      bindings["self"] = WebBinding(typ: selfType)
      for param in declaration.constructor.params:
        bindings[param.sourceName] = WebBinding(typ: param.typ)
      var forms: seq[Value]
      for i in 1 ..< declaration.constructor.sourceForm.body.len:
        forms.add declaration.constructor.sourceForm.body[i]
      analysis.currentReturn = nil
      analysis.currentTypeName = declaration.sourceName
      analysis.validateCallableProps(declaration.constructor.sourceForm,
        declaration.constructor.loc, "constructor " & declaration.sourceName)
      declaration.constructor.body = analysis.analyzeSequence(forms, bindings,
        nil, declaration.constructor.loc)
      rejectAsyncBody(declaration.constructor.body,
        declaration.constructor.loc, "constructor " & declaration.sourceName)
  for implementation in result.impls:
    let selfType = case implementation.targetName
      of "Nil": webType(wtkNil)
      of "Str": webType(wtkStr)
      of "List": webType(wtkList, webType(wtkAny))
      else: WebType(kind: wtkNominal, name: implementation.targetName)
    for implMethod in implementation.methods:
      var bindings = initTable[string, WebBinding]()
      bindings["self"] = WebBinding(typ: selfType)
      for param in implMethod.params:
        bindings[param.sourceName] = WebBinding(typ: param.typ)
      var forms: seq[Value]
      for i in 4 ..< implMethod.sourceForm.body.len:
        forms.add implMethod.sourceForm.body[i]
      analysis.currentReturn = implMethod.returnType
      analysis.currentTypeName = implementation.targetName
      analysis.validateCallableProps(implMethod.sourceForm, implMethod.loc,
        "protocol message " & implMethod.message.sourceName)
      implMethod.body = analysis.analyzeSequence(forms, bindings,
        (if implMethod.returnType.isStatementType: nil
         else: implMethod.returnType), implMethod.loc)
      if not implMethod.returnType.isStatementType:
        requireType(analysis, implMethod.loc, implMethod.body.typ,
                    implMethod.returnType,
                    "return of protocol message " &
                      implMethod.message.sourceName)
      rejectAsyncBody(implMethod.body, implMethod.loc,
        "protocol message " & implMethod.message.sourceName)
  # Method bodies were analyzed after propagation, so their references are
  # already checkable against settled signatures.
  analysis.checkFunctionValueRefs()
  analysis.currentReturn = nil
  analysis.currentTypeName = ""

proc analyzeWebModuleWithImports(source, sourcePath: string,
                                 imported: Table[string, WebFunctionSig],
                                 importedTypes: Table[string, WebTypeDecl],
                                 importedEnums: Table[string, WebEnumDecl],
                                 importedProtocols: Table[string, WebProtocolDecl],
                                 importedMacros: Table[string,
                                   Table[string, MacroDef]],
                                 macroExports: var Table[string, MacroDef]): WebModule =
  analyzeWebUnitWithImports(readAllWithLocs(source, sourcePath), sourcePath,
    imported, importedTypes, importedEnums, importedProtocols, importedMacros,
    macroExports)

proc analyzeWebModule*(source, sourcePath: string): WebModule =
  var macroExports: Table[string, MacroDef]
  analyzeWebModuleWithImports(source, sourcePath,
    initTable[string, WebFunctionSig](),
    initTable[string, WebTypeDecl](),
    initTable[string, WebEnumDecl](),
    initTable[string, WebProtocolDecl](),
    initTable[string, Table[string, MacroDef]](), macroExports)

proc line(emitter: var WebEmitter, text = "") =
  emitter.lines.add repeat(' ', emitter.indent * 2) & text
  emitter.lineLocs.add emitter.currentLoc

proc temp(emitter: var WebEmitter): string =
  result = "$t" & $emitter.nextTemp
  inc emitter.nextTemp

proc jsString(value: string): string =
  $(%value)

proc truthy(value: string): string =
  "(" & value & " !== false && " & value & " != null)"

proc isRepeatable(value: string): bool =
  ## True when a JS expression can be interpolated twice with no second
  ## evaluation: a bare identifier, a keyword literal, or a numeric literal.
  ## Anything else — a call, a property read that may hit a getter, arithmetic —
  ## must be bound to a temp before `truthy` doubles it.
  if value.len == 0: return false
  if value in ["true", "false", "null", "undefined"]: return true
  var i = 0
  if value[0] in {'A'..'Z', 'a'..'z', '_', '$'}:
    while i < value.len and value[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_', '$'}:
      inc i
    return i == value.len
  while i < value.len and value[i] in {'0'..'9', '.', 'n'}:
    inc i
  i > 0 and i == value.len

proc truthyExpr(emitter: var WebEmitter, value: string): string =
  ## `truthy` interpolates its operand twice, so a condition that can evaluate
  ## must be bound first. Without this, `(if (f) …)` and `(while (f) …)` call
  ## `f` twice per test — a miscompilation whenever `f` has an effect.
  if isRepeatable(value): truthy(value)
  else:
    let slot = emitter.temp()
    emitter.line("const " & slot & " = " & value & ";")
    truthy(slot)

proc isJsIdent(name: string): bool =
  if name.len == 0: return false
  if name[0] notin {'A'..'Z', 'a'..'z', '_', '$'}: return false
  for ch in name:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '$'}: return false
  true

proc isNumericKey(key: string): bool =
  key.len > 0 and key.allCharsInSet({'0'..'9'})

proc directRead(emitter: WebEmitter, expr: WebExpr, base: string,
                segments: seq[string]): string =
  ## `$gene_get` is a six-branch generic helper, and on a path the analysis has
  ## already resolved every one of those branches is dead. Emitting the property
  ## read directly is what lets V8 see a monomorphic access instead of a
  ## megamorphic call — the difference is the bulk of the web profile's gap to
  ## hand-written JS on a hot loop.
  ##
  ## Only a single proven hop qualifies. `analyzeExpr` types a path of one
  ## segment and falls back to `Any` beyond that, so a longer path has no
  ## proven intermediate type to reason about. Returns "" when the general
  ## helper must be kept.
  if expr.keys.len != 1: return ""
  let baseType = expr.children[0].typ
  if baseType == nil: return ""
  let key = expr.keys[0]
  if key.len > 0:
    # A declared class: never a node (no `$gene_node`), never nil (`T?` is a
    # union, not a nominal), and the field name is stored unmangled by the
    # constructor's `Object.assign`, so the camelCase fallback cannot fire.
    # Numeric keys are excluded: those mean body slots, not properties.
    if baseType.kind == wtkNominal and baseType.name in emitter.nominalTypes and
        not isNumericKey(key):
      return (if isJsIdent(key): base & "." & key
              else: base & "[" & jsString(key) & "]")
    if baseType.kind == wtkList and isNumericKey(key):
      return base & "[" & key & "]"
    return ""
  # Dynamic `%` index into a list. A plain array carries no `$gene_body` and no
  # `$gene_node`, so only the bigint coercion is live — and only for `Int`.
  if baseType.kind != wtkList: return ""
  let indexType = expr.children[1].typ
  if indexType == nil or segments.len != 1: return ""
  case indexType.kind
  of wtkF64: return base & "[" & segments[0] & "]"
  of wtkInt: return base & "[Number(" & segments[0] & ")]"
  else: return ""

proc emitPattern(emitter: var WebEmitter, pattern: Value, target: string,
                 declarations: var seq[string]): string =
  case pattern.kind
  of vkNil: target & " === null"
  of vkVoid: target & " === undefined"
  of vkBool: target & " === " & (if pattern.boolVal: "true" else: "false")
  of vkInt: target & " === " & pattern.intToString & "n"
  of vkFloat: target & " === " & $pattern.floatVal
  of vkString: target & " === " & jsString(pattern.strVal)
  of vkSymbol:
    if pattern.symVal == "_":
      "true"
    else:
      declarations.add "const " & mangleWebName(pattern.symVal) & " = " &
        target & ";"
      "true"
  of vkList:
    var tests = @["Array.isArray(" & target & ")"]
    var items: seq[Value]
    for item in pattern.listItems:
      if not item.isSym(","): items.add item
    var restIndex = -1
    for i, item in items:
      if item.kind == vkSymbol and item.symVal.endsWith("..."):
        if restIndex >= 0:
          raise newException(WebProfileError,
            "web list pattern accepts at most one rest binding")
        restIndex = i
    if restIndex < 0:
      for i, item in items:
        tests.add emitter.emitPattern(item, target & "[" & $i & "]",
                                      declarations)
      tests.add target & ".length === " & $items.len
    else:
      let suffixCount = items.len - restIndex - 1
      tests.add target & ".length >= " & $(items.len - 1)
      for i in 0 ..< restIndex:
        tests.add emitter.emitPattern(items[i], target & "[" & $i & "]",
                                      declarations)
      let restName = items[restIndex].symVal[0 .. ^4]
      if restName != "_":
        declarations.add "const " & mangleWebName(restName) & " = " &
          target & ".slice(" & $restIndex & ", " & target & ".length - " &
          $suffixCount & ");"
      for i in (restIndex + 1) ..< items.len:
        let suffixOffset = items.len - i
        tests.add emitter.emitPattern(items[i],
          target & "[" & target & ".length - " & $suffixOffset & "]",
          declarations)
    "(" & tests.join(" && ") & ")"
  of vkMap:
    var tests = @[target & " != null", "typeof " & target & " === \"object\""]
    for key, item in pattern.mapEntries:
      tests.add "Object.prototype.hasOwnProperty.call(" & target & ", " &
        jsString(key) & ")"
      tests.add emitter.emitPattern(item, target & "[" & jsString(key) & "]",
                                    declarations)
    "(" & tests.join(" && ") & ")"
  of vkNode:
    if pattern.head.isSym("path") and pattern.body.len == 2 and
        pattern.body[0].kind == vkSymbol and pattern.body[1].kind == vkSymbol:
      target & "?.$gene_tag === " &
        jsString(pattern.body[0].symVal & "/" & pattern.body[1].symVal)
    elif pattern.head.isSym("unquote") and pattern.body.len == 1 and
        pattern.body[0].kind == vkSymbol:
      target & " === " & mangleWebName(pattern.body[0].symVal)
    elif pattern.head.isSym("not") and pattern.body.len == 1:
      var ignored: seq[string]
      "!(" & emitter.emitPattern(pattern.body[0], target, ignored) & ")"
    elif pattern.head.isSym("|") and pattern.body.len >= 2:
      var alternatives: seq[string]
      for item in pattern.body:
        var localDecls: seq[string]
        alternatives.add emitter.emitPattern(item, target, localDecls)
      "(" & alternatives.join(" || ") & ")"
    elif pattern.head.isSym("&") and pattern.body.len >= 2:
      var tests: seq[string]
      for item in pattern.body:
        tests.add emitter.emitPattern(item, target, declarations)
      "(" & tests.join(" && ") & ")"
    elif pattern.head.kind == vkNode and pattern.head.head.isSym("path"):
      var parts: seq[string]
      for item in pattern.head.body:
        if item.kind == vkSymbol: parts.add item.symVal
      let tag = parts.join("/")
      var tests = @[target & "?.$gene_tag === " & jsString(tag),
                    target & ".$gene_values.length === " & $pattern.body.len]
      for i, item in pattern.body:
        tests.add emitter.emitPattern(item,
          target & ".$gene_values[" & $i & "]", declarations)
      "(" & tests.join(" && ") & ")"
    elif pattern.head.kind == vkSymbol:
      var bodyPatterns: seq[Value]
      for item in pattern.body:
        if item.kind == vkNode and item.head.isSym("...") and
            item.body.len == 1 and item.body[0].kind == vkSymbol:
          bodyPatterns.add newSym(item.body[0].symVal & "...")
        else:
          bodyPatterns.add item
      # One pattern form over two representations, as in the VM: a plain symbol
      # head matches a type instance *and* Gene node data carrying that head.
      # Gene node data is the shape the VM raises builtin errors as, which is
      # what lets `catch (Error ^message m)` read the same value here. Listed
      # props must be present (extra props in the data are ignored) and the body
      # must match exactly.
      let nodeTest = "($gene_is_node(" & target & ") && " & target &
        ".head === Symbol.for(" & jsString(pattern.head.symVal) & "))"
      var tests: seq[string]
      if pattern.head.symVal in emitter.nominalTypes:
        tests.add "(" & target & " instanceof " &
          mangleWebName(pattern.head.symVal) & " || " & nodeTest & ")"
      else:
        tests.add nodeTest
      for key, item in pattern.props:
        tests.add "$gene_has_field(" & target & ", " & jsString(key) & ")"
        tests.add emitter.emitPattern(item,
          "$gene_field(" & target & ", " & jsString(key) & ")", declarations)
      tests.add emitter.emitPattern(newList(bodyPatterns),
        "$gene_body_of(" & target & ")", declarations)
      "(" & tests.join(" && ") & ")"
    else:
      raise newException(WebProfileError, "unsupported emitted web pattern")
  else:
    raise newException(WebProfileError,
      "unsupported emitted web pattern kind: " & $pattern.kind)

proc emitExpr(emitter: var WebEmitter, expr: WebExpr): string =
  case expr.kind
  of wekNil: "null"
  of wekVoid: "undefined"
  of wekBool: (if expr.boolValue: "true" else: "false")
  of wekStr: jsString(expr.text)
  of wekSym: "Symbol.for(" & jsString(expr.text) & ")"
  of wekInt: expr.text & "n"
  of wekF64: expr.text
  of wekBinding: expr.text
  of wekList:
    var items: seq[string]
    for child in expr.children: items.add emitter.emitExpr(child)
    let literal = "[" & items.join(", ") & "]"
    if expr.immutable: "Object.freeze(" & literal & ")" else: literal
  of wekPropMap:
    var entries: seq[string]
    for i, child in expr.children:
      entries.add jsString(expr.keys[i]) & ": " & emitter.emitExpr(child)
    let literal = "({" & entries.join(", ") & "})"
    if expr.immutable: "Object.freeze(" & literal & ")" else: literal
  of wekMap:
    var entries: seq[string]
    var i = 0
    while i < expr.children.len:
      entries.add "[" & emitter.emitExpr(expr.children[i]) & ", " &
        emitter.emitExpr(expr.children[i + 1]) & "]"
      inc i, 2
    "new GeneMap([" & entries.join(", ") & "])"
  of wekNode:
    var props: seq[string]
    for i in 0 ..< expr.propCount:
      props.add jsString(expr.keys[i]) & ": " & emitter.emitExpr(expr.children[i])
    var body: seq[string]
    for i in expr.propCount ..< expr.children.len:
      body.add emitter.emitExpr(expr.children[i])
    "new GeneNode(Symbol.for(" & jsString(expr.text) & "), {" &
      props.join(", ") &
      "}, [" & body.join(", ") & "], " &
      (if expr.immutable: "true" else: "false") & ")"
  of wekRange:
    "new GeneRange(" & emitter.emitExpr(expr.children[0]) & ", " &
      emitter.emitExpr(expr.children[1]) & ", " &
      emitter.emitExpr(expr.children[2]) & ", " &
      (if expr.boolValue: "true" else: "false") & ")"
  of wekCall:
    var arguments: seq[string]
    for i, child in expr.children:
      let argument = emitter.emitExpr(child)
      if expr.external:
        arguments.add validatorName(expr.paramTypes[i]) & "(" & argument &
          ", " & jsString(expr.text & " JS argument " & $(i + 1)) & ")"
      else:
        arguments.add argument
    var call = expr.text & "(" & arguments.join(", ") & ")"
    if expr.immutable: call = "new GeneStream(" & call & ")"
    if expr.boolValue: call = "await " & call
    if expr.external:
      validatorName(expr.typ) & "(" & call & ", " &
        jsString(expr.text & " JS return") & ")"
    else:
      call
  of wekBuiltin:
    var arguments: seq[string]
    for child in expr.children: arguments.add emitter.emitExpr(child)
    case expr.text
    of "str/join": arguments[0] & ".join(" & arguments[1] & ")"
    of "str/split": arguments[0] & ".split(" & arguments[1] & ")"
    of "str/trim": arguments[0] & ".trim()"
    of "str/lower": arguments[0] & ".toLowerCase()"
    of "str/starts_with?": arguments[0] & ".startsWith(" & arguments[1] & ")"
    of "str/ends_with?": arguments[0] & ".endsWith(" & arguments[1] & ")"
    of "str/contains?": arguments[0] & ".includes(" & arguments[1] & ")"
    of "url/encode_component": "encodeURIComponent(" & arguments[0] & ")"
    of "url/decode_component": "decodeURIComponent(" & arguments[0] & ")"
    of "html/escape", "html/attr_escape":
      "$gene_html_escape(" & arguments[0] & ")"
    of "json/parse": "$gene_json_parse(" & arguments[0] & ")"
    of "json/stringify": "$gene_json_stringify(" & arguments[0] & ")"
    of "console/log": "console.log(" & arguments[0] & ")"
    of "console/warn": "console.warn(" & arguments[0] & ")"
    of "console/error": "console.error(" & arguments[0] & ")"
    of "dom/prevent_default": "$gene_dom_prevent_default(" & arguments[0] & ")"
    of "dom/stop_propagation": "$gene_dom_stop_propagation(" & arguments[0] & ")"
    of "http/get":
      "$gene_http_request(\"GET\", " & arguments[0] & ", null, " &
        arguments[1] & ")"
    of "http/post_form":
      "$gene_http_request(\"POST\", " & arguments[0] & ", " & arguments[1] &
        ", " & arguments[2] & ")"
    of "size": "BigInt(Array.isArray(" & arguments[0] & ") || typeof " &
      arguments[0] & " === \"string\" ? " &
      (if emitter.typescript: "(" & arguments[0] & " as any)" else: arguments[0]) &
      ".length : " &
      (if emitter.typescript: "(" & arguments[0] & " as any)" else: arguments[0]) &
      ".size)"
    of "node/head": arguments[0] & ".head"
    of "node/props": arguments[0] & ".props"
    of "node/body": arguments[0] & ".body"
    of "to_stream": "new GeneStream(" & arguments[0] & "[Symbol.iterator]())"
    of "map": "$gene_stream_map(" & arguments[0] & ", " & arguments[1] & ")"
    of "filter": "$gene_stream_filter(" & arguments[0] & ", " & arguments[1] & ")"
    of "into": "$gene_stream_into(" & arguments[0] & ", " & arguments[1] & ")"
    else: raise newException(WebProfileError,
      "internal portable stdlib emitter gap: " & expr.text)
  of wekCheck:
    validatorName(expr.typ) & "(" & emitter.emitExpr(expr.children[0]) &
      ", \"typed boundary\")"
  of wekBinary:
    var left = emitter.emitExpr(expr.children[0])
    var right = emitter.emitExpr(expr.children[1])
    if expr.text == "$":
      # JS `+` on a non-string does not agree with Gene display — `null` prints
      # as "null", not "nil" — so anything that is not already a Str goes
      # through the display helper.
      if expr.children[0].typ.kind != wtkStr:
        left = "$gene_str(" & left & ")"
      if expr.children[1].typ.kind != wtkStr:
        right = "$gene_str(" & right & ")"
    if expr.text in ["==", "!="] and expr.children[0].typ.kind in
        {wtkList, wtkPropMap, wtkMap, wtkNode, wtkAny, wtkNominal}:
      (if expr.text == "!=": "!" else: "") &
        "$gene_equal(" & left & ", " & right & ")"
    else:
      let op =
        if expr.text == "==": "==="
        elif expr.text == "!=": "!=="
        elif expr.text == "same?": "==="
        elif expr.text == "$": "+"
        elif expr.text == "//": "%" # Gene `//` is the truncated remainder.
        else: expr.text
      # `/` truncates for two Ints (bigint division already does) and `//` is
      # the truncated remainder, but both raise the VM's Gene error on a zero
      # divisor instead of returning Infinity or throwing a JS RangeError.
      let guarded =
        if expr.text in ["/", "//"]: divisorGuard(expr.typ) & "(" & right & ")"
        else: right
      "(" & left & " " & op & " " & guarded & ")"
  of wekNot:
    "!" & emitter.truthyExpr(emitter.emitExpr(expr.children[0]))
  of wekIf:
    let condition = emitter.emitExpr(expr.children[0])
    let guard = emitter.truthyExpr(condition)
    let target = emitter.temp()
    emitter.line("let " & target & ";")
    emitter.line("if " & guard & " {")
    inc emitter.indent
    let yes = emitter.emitExpr(expr.children[1])
    emitter.line(target & " = " & yes & ";")
    dec emitter.indent
    emitter.line("} else {")
    inc emitter.indent
    let no = emitter.emitExpr(expr.children[2])
    emitter.line(target & " = " & no & ";")
    dec emitter.indent
    emitter.line("}")
    target
  of wekAnd, wekOr, wekCoalesce:
    let left = emitter.emitExpr(expr.children[0])
    let target = emitter.temp()
    emitter.line("let " & target & " = " & left & ";")
    let condition = case expr.kind
      of wekAnd: truthy(target)
      of wekOr: "!" & truthy(target)
      else: target & " == null"
    emitter.line("if (" & condition & ") {")
    inc emitter.indent
    let right = emitter.emitExpr(expr.children[1])
    emitter.line(target & " = " & right & ";")
    dec emitter.indent
    emitter.line("}")
    target
  of wekDo:
    for i in 0 ..< expr.children.high:
      let value = emitter.emitExpr(expr.children[i])
      emitter.line("void " & value & ";")
    emitter.emitExpr(expr.children[^1])
  of wekBind:
    let value = emitter.emitExpr(expr.children[0])
    if expr.patterns.len == 0:
      emitter.line((if expr.mutable: "let " else: "const ") & expr.text &
        (if emitter.typescript: ": " & tsType(expr.typ) else: "") &
        " = " & value & ";")
      expr.text
    else:
      let target = emitter.temp()
      emitter.line("const " & target & " = " & value & ";")
      var declarations: seq[string]
      let condition = emitter.emitPattern(expr.patterns[0], target, declarations)
      emitter.line("if (!(" & condition & ")) throw new GeneMatchError(" & target & ");")
      for declaration in declarations:
        emitter.line(if expr.mutable: "let " & declaration[6 .. ^1]
                     else: declaration)
      target
  of wekSet:
    let value = emitter.emitExpr(expr.children[0])
    emitter.line(expr.text & " = " & value & ";")
    expr.text
  of wekWhile:
    emitter.line("while (true) {")
    inc emitter.indent
    let condition = emitter.emitExpr(expr.children[0])
    emitter.line("if (!" & emitter.truthyExpr(condition) & ") break;")
    let body = emitter.emitExpr(expr.children[1])
    if expr.children[1].typ.kind != wtkNever: emitter.line("void " & body & ";")
    dec emitter.indent
    emitter.line("}")
    "null"
  of wekLoop:
    emitter.line("while (true) {")
    inc emitter.indent
    let body = emitter.emitExpr(expr.children[0])
    if expr.children[0].typ.kind != wtkNever: emitter.line("void " & body & ";")
    dec emitter.indent
    emitter.line("}")
    "null"
  of wekRepeat:
    let count = emitter.temp()
    emitter.line("const " & count & " = " & emitter.emitExpr(expr.children[0]) & ";")
    let index = if expr.text.len > 0: expr.text else: emitter.temp()
    emitter.line("for (let " & index & " = 0n; " & index & " < " & count &
      "; " & index & "++) {")
    inc emitter.indent
    let body = emitter.emitExpr(expr.children[1])
    if expr.children[1].typ.kind != wtkNever: emitter.line("void " & body & ";")
    dec emitter.indent
    emitter.line("}")
    "null"
  of wekFor:
    let itemName = if expr.text.len > 0: expr.text else: emitter.temp()
    emitter.line("for (const " & itemName & " of " &
      emitter.emitExpr(expr.children[0]) & ") {")
    inc emitter.indent
    if expr.text.len == 0:
      var declarations: seq[string]
      let condition = emitter.emitPattern(expr.patterns[0], itemName, declarations)
      emitter.line("if (!(" & condition & ")) throw new GeneMatchError(" & itemName & ");")
      for declaration in declarations: emitter.line(declaration)
    let body = emitter.emitExpr(expr.children[1])
    if expr.children[1].typ.kind != wtkNever: emitter.line("void " & body & ";")
    dec emitter.indent
    emitter.line("}")
    "null"
  of wekBreak:
    emitter.line("break;")
    "undefined"
  of wekContinue:
    emitter.line("continue;")
    "undefined"
  of wekReturn:
    let returned = emitter.emitExpr(expr.children[0])
    if emitter.currentReturnType.isStatementType:
      emitter.line("void " & returned & ";")
      emitter.line("return " & statementUnit(emitter.currentReturnType) & ";")
    else:
      emitter.line("return " & returned & ";")
    "undefined"
  of wekFail:
    emitter.line("throw " & emitter.emitExpr(expr.children[0]) & ";")
    "undefined"
  of wekMatch:
    let matched = emitter.temp()
    let target = emitter.temp()
    emitter.line("const " & matched & " = " & emitter.emitExpr(expr.children[0]) & ";")
    emitter.line("let " & target & ";")
    for i in 0 ..< expr.patterns.len:
      var declarations: seq[string]
      let condition = if expr.keys[i] == "else": "true"
                      else: emitter.emitPattern(expr.patterns[i], matched,
                                                declarations)
      emitter.line((if i == 0: "if" else: "else if") & " (" & condition & ") {")
      inc emitter.indent
      for declaration in declarations: emitter.line(declaration)
      let arm = emitter.emitExpr(expr.children[i + 1])
      emitter.line(target & " = " & arm & ";")
      dec emitter.indent
      emitter.line("}")
    if expr.keys.len == 0 or expr.keys[^1] != "else":
      emitter.line("else { throw new GeneMatchError(" & matched & "); }")
    target
  of wekPath:
    var current = emitter.emitExpr(expr.children[0])
    var dynamicIndex = 1
    var segments: seq[string]
    for key in expr.keys:
      if key.len > 0: segments.add jsString(key)
      else:
        segments.add emitter.emitExpr(expr.children[dynamicIndex])
        inc dynamicIndex
    let direct = emitter.directRead(expr, current, segments)
    if direct.len > 0: direct
    else:
      for segment in segments:
        current = "$gene_get(" & current & ", " & segment & ")"
      current
  of wekSelector:
    let receiver = emitter.temp()
    let current = emitter.temp()
    var defaultName = ""
    if expr.propCount == 1:
      defaultName = emitter.temp()
      emitter.line("const " & defaultName & " = " &
        emitter.emitExpr(expr.children[0]) & ";")
    var capturedSegments: seq[string]
    var dynamicIndex = expr.propCount
    for key in expr.keys:
      if key.len > 0:
        capturedSegments.add jsString(key)
      else:
        let captured = emitter.temp()
        emitter.line("const " & captured & " = " &
          emitter.emitExpr(expr.children[dynamicIndex]) & ";")
        inc dynamicIndex
        capturedSegments.add captured
    var statements = "let " & current & " = " & receiver & "; "
    for segment in capturedSegments:
      statements.add current & " = $gene_get(" & current & ", " & segment & "); "
      if expr.boolValue:
        statements.add "if (" & current & " === undefined) throw new GeneSelectorMissing(" & segment & "); "
      elif defaultName.len > 0:
        statements.add "if (" & current & " === undefined) return " &
          defaultName & "; "
      else:
        statements.add "if (" & current & " === undefined) return undefined; "
    "(" & receiver & ") => { " & statements & "return " & current & "; }"
  of wekMessage:
    var params, args: seq[string]
    for i, typ in expr.paramTypes:
      let name = if i == 0: "$receiver" else: "$arg" & $i
      params.add name & (if emitter.typescript: ": " & tsType(typ) else: "")
      if i > 0: args.add name
    let receiver = if emitter.typescript: "($receiver as any)" else: "$receiver"
    "(" & params.join(", ") & ") => " & receiver & "[" & expr.text & "](" &
      args.join(", ") & ")"
  of wekSetPath:
    var container = emitter.emitExpr(expr.children[0])
    var dynamicIndex = 1
    for i in 0 ..< expr.keys.high:
      let key = expr.keys[i]
      let segment = if key.len > 0: jsString(key)
                    else:
                      let emitted = emitter.emitExpr(expr.children[dynamicIndex])
                      inc dynamicIndex
                      emitted
      container = "$gene_get(" & container & ", " & segment & ")"
    let lastKey = expr.keys[^1]
    let lastSegment = if lastKey.len > 0: jsString(lastKey)
                      else:
                        let emitted = emitter.emitExpr(expr.children[dynamicIndex])
                        inc dynamicIndex
                        emitted
    "$gene_set(" & container & ", " & lastSegment & ", " &
      emitter.emitExpr(expr.children[^1]) & ")"
  of wekSend:
    var receiver = emitter.emitExpr(expr.children[0])
    var arguments: seq[string]
    for i in 1 ..< expr.children.len:
      arguments.add emitter.emitExpr(expr.children[i])
    if expr.keys.len == 2 and expr.keys[1] == "$builtin":
      return expr.keys[0] & "(" & receiver &
        (if arguments.len > 0: ", " & arguments.join(", ") else: "") & ")"
    if expr.keys.len == 2 and expr.external:
      return expr.keys[1] & ".prototype[" & expr.keys[0] & "].call(" &
        receiver &
        (if arguments.len > 0: ", " & arguments.join(", ") else: "") & ")"
    let member = if expr.keys.len > 0: "[" & expr.keys[0] & "]"
                 else: "." & expr.text
    if expr.keys.len > 0 and emitter.typescript:
      receiver = "(" & receiver & " as any)"
    if expr.boolValue:
      let target = emitter.temp()
      emitter.line("const " & target & " = " & receiver & ";")
      "(" & target & " == null ? " & target & " : " & target & member &
        "(" & arguments.join(", ") & "))"
    else:
      if expr.text == "size" and expr.children[0].typ.kind == wtkMap:
        "BigInt(" & receiver & ".size)"
      else:
        receiver & member & "(" & arguments.join(", ") & ")"
  of wekNew:
    var arguments: seq[string]
    for child in expr.children: arguments.add emitter.emitExpr(child)
    if expr.boolValue:
      expr.text & ".$gene_new(" & arguments.join(", ") & ")"
    else:
      var fields: seq[string]
      for i in 0 ..< expr.propCount:
        let key = expr.keys[i]
        fields.add jsString(key) & ": " & arguments[i]
      var body: seq[string]
      for i in expr.propCount ..< arguments.len:
        body.add(if expr.children[i].kind == wekVoid: "null" else: arguments[i])
      "new " & expr.text & "({" & fields.join(", ") & "}, [" &
        body.join(", ") & "], false, " &
        (if expr.immutable: "true" else: "false") & ")"
  of wekEnum:
    let slash = expr.text.find('/')
    let enumName = mangleWebName(expr.text[0 ..< slash])
    let variantName = mangleWebName(expr.text[slash + 1 .. ^1])
    if expr.children.len == 0:
      enumName & "." & variantName
    else:
      var arguments: seq[string]
      for child in expr.children: arguments.add emitter.emitExpr(child)
      enumName & "." & variantName & "(" & arguments.join(", ") & ")"
  of wekDomRender:
    "$gene_dom_render(" & emitter.emitExpr(expr.children[0]) & ")"
  of wekLambda:
    # An arrow function, so `this` is not rebound — a Gene callback has no
    # receiver, and `function` would silently give it one at a DOM call site.
    # Statements the body needs are emitted into the arrow's own block rather
    # than hoisted out of it, which is what makes the capture correct.
    var params: seq[string]
    for param in expr.params:
      params.add param.emittedName &
        (if emitter.typescript: ": " & tsType(param.typ) else: "")
    let signature = "(" & params.join(", ") & ")" &
      (if emitter.typescript: ": " & tsType(expr.typ.returnType) else: "")
    let savedLines = emitter.lines
    let savedLocs = emitter.lineLocs
    emitter.lines = @[]
    emitter.lineLocs = @[]
    let savedIndent = emitter.indent
    emitter.indent = savedIndent + 1
    let bodyValue = emitter.emitExpr(expr.children[0])
    let bodyLines = emitter.lines
    let bodyLocs = emitter.lineLocs
    emitter.indent = savedIndent
    emitter.lines = savedLines
    emitter.lineLocs = savedLocs
    if bodyLines.len == 0:
      # A pure expression body needs no block, and no statement slot.
      signature & " => " & bodyValue
    else:
      # The body needed statements, so the arrow is bound to a temp and the
      # call site names it. Always a `const`, never a patched-up line: the
      # emitter owns every line it writes here, so there is nothing to search
      # for and nothing to desync.
      let target = emitter.temp()
      emitter.line("const " & target & " = " & signature & " => {")
      for i, text in bodyLines:
        emitter.lines.add text
        emitter.lineLocs.add bodyLocs[i]
      inc emitter.indent
      if expr.typ.returnType.kind == wtkVoid:
        emitter.line("void " & bodyValue & ";")
      else:
        emitter.line("return " & bodyValue & ";")
      dec emitter.indent
      emitter.line("};")
      target
  of wekDomListener:
    let target = emitter.emitExpr(expr.children[0])
    let eventType = emitter.emitExpr(expr.children[1])
    let handler = emitter.emitExpr(expr.children[2])
    "$gene_dom_" & expr.text & "(" & target & ", " & eventType & ", " &
      handler & ")"
  of wekTry:
    let target = emitter.temp()
    emitter.line("let " & target & ";")
    emitter.line("try {")
    inc emitter.indent
    emitter.line(target & " = " & emitter.emitExpr(expr.children[0]) & ";")
    dec emitter.indent
    emitter.line("}")
    if expr.patterns.len > 0:
      let caught = emitter.temp()
      emitter.line("catch (" & caught & ") {")
      inc emitter.indent
      emitter.line("if ($gene_cancelled(" & caught & ")) throw " & caught & ";")
      for i, pattern in expr.patterns:
        var declarations: seq[string]
        let condition = emitter.emitPattern(pattern, caught, declarations)
        emitter.line((if i == 0: "if" else: "else if") & " (" & condition & ") {")
        inc emitter.indent
        for declaration in declarations: emitter.line(declaration)
        emitter.line(target & " = " & emitter.emitExpr(expr.children[i + 1]) & ";")
        dec emitter.indent
        emitter.line("}")
      emitter.line("else { throw " & caught & "; }")
      dec emitter.indent
      emitter.line("}")
    if expr.keys.len > 0 and expr.keys[^1] == "ensure":
      emitter.line("finally {")
      inc emitter.indent
      let cleanup = emitter.emitExpr(expr.children[^1])
      emitter.line("void " & cleanup & ";")
      dec emitter.indent
      emitter.line("}")
    target
  of wekYield:
    let yielded = emitter.temp()
    emitter.line("const " & yielded & " = " & emitter.emitExpr(expr.children[0]) & ";")
    emitter.line("if (" & yielded & " !== undefined) yield " & yielded & ";")
    "undefined"
  of wekAwait:
    "await $gene_await(" & emitter.emitExpr(expr.children[0]) & ")"
  of wekSpawn:
    if emitter.scopeStack.len == 0:
      raise newException(WebProfileError, "internal spawn outside scope")
    let task = emitter.temp()
    emitter.line("const " & task & " = $gene_spawn(" & emitter.scopeStack[^1] &
      ", async () => {")
    inc emitter.indent
    let body = emitter.emitExpr(expr.children[0])
    emitter.line("return " & body & ";")
    dec emitter.indent
    emitter.line("});")
    task
  of wekScope:
    let target = emitter.temp()
    let scopeName = emitter.temp()
    emitter.line("const " & target & " = await $gene_scope(async (" &
      scopeName & (if emitter.typescript: ": any" else: "") & ") => {")
    inc emitter.indent
    emitter.scopeStack.add scopeName
    let body = emitter.emitExpr(expr.children[0])
    discard emitter.scopeStack.pop()
    emitter.line("return " & body & ";")
    dec emitter.indent
    emitter.line("});")
    target

proc emitFunction(emitter: var WebEmitter, fn: WebFunction) =
  let previousLoc = emitter.currentLoc
  emitter.currentLoc = fn.loc
  var params: seq[string]
  for param in fn.params:
    let annotation = if emitter.typescript: ": " & tsType(param.typ) else: ""
    params.add param.emittedName & annotation
  let returnAnnotation =
    if emitter.typescript: ": " & tsType(fn.returnType) else: ""
  let implementationReturn = if fn.generator and emitter.typescript:
    ": Generator<" & tsType(fn.returnType.item) & ", void, unknown>"
  elif fn.async and emitter.typescript:
    ": Promise<" & tsType(fn.returnType) & ">"
  else: returnAnnotation
  let functionPrefix = if fn.async and fn.generator: "async function* "
                       elif fn.async: "async function "
                       elif fn.generator: "function* "
                       else: "function "
  emitter.line(functionPrefix &
               "$gene_impl_" & fn.emittedName & "(" & params.join(", ") &
               ")" & implementationReturn & " {")
  inc emitter.indent
  let savedReturnType = emitter.currentReturnType
  emitter.currentReturnType = if fn.generator: nil else: fn.returnType
  let value = emitter.emitExpr(fn.body)
  emitter.currentReturnType = savedReturnType
  if fn.generator:
    emitter.line("void " & value & ";")
  elif fn.returnType.isStatementType:
    # Evaluate the body for effect, then yield the declared unit — the same
    # rule the VM applies in `frameReturn`. A body typed `Never` already
    # returned or threw, so a trailing return would only be dead code.
    if fn.body.typ.kind != wtkNever:
      emitter.line("void " & value & ";")
      emitter.line("return " & statementUnit(fn.returnType) & ";")
  else:
    emitter.line("return " & value & ";")
  dec emitter.indent
  emitter.line("}")
  emitter.line()
  emitter.currentLoc = previousLoc

  var wrapperParams: seq[string]
  for param in fn.params:
    let annotation = if emitter.typescript: ": " & tsType(param.typ) else: ""
    wrapperParams.add param.emittedName & annotation
  let wrapperReturn = if fn.async and emitter.typescript:
                        ": Promise<" & tsType(fn.returnType) & ">"
                      else: returnAnnotation
  emitter.line((if fn.publicExport: "export " else: "") &
               (if fn.async: "async " else: "") & "function " &
               fn.emittedName & "(" & wrapperParams.join(", ") & ")" &
               wrapperReturn & " {")
  inc emitter.indent
  var checkedArgs: seq[string]
  for param in fn.params:
    let checked = validatorName(param.typ) & "(" & param.emittedName &
      ", " & jsString(fn.sourceName & " argument " & param.sourceName) & ")"
    checkedArgs.add checked
  var call = "$gene_impl_" & fn.emittedName & "(" & checkedArgs.join(", ") & ")"
  if fn.generator: call = "new GeneStream(" & call & ")"
  if fn.async: call = "await " & call
  emitter.line("return " & validatorName(fn.returnType) & "(" & call &
               ", " & jsString(fn.sourceName & " return") & ");")
  dec emitter.indent
  emitter.line("}")
  emitter.line()

proc collectValidatorTypes(typ: WebType, types: var seq[WebType]) =
  if typ.kind in {wtkList, wtkTask, wtkStream}:
    collectValidatorTypes(typ.item, types)
  elif typ.kind == wtkMap:
    collectValidatorTypes(typ.params[0], types)
    collectValidatorTypes(typ.params[1], types)
  elif typ.kind == wtkUnion:
    for member in typ.members: collectValidatorTypes(member, types)
  elif typ.kind == wtkCallback:
    for param in typ.params: collectValidatorTypes(param, types)
    collectValidatorTypes(typ.returnType, types)
  for existing in types:
    if sameType(existing, typ): return
  types.add typ

iterator expressionRoots(module: WebModule): WebExpr =
  ## Every analyzed expression tree the emitter will walk. Emission
  ## prerequisites — which runtime classes, helpers, and validators a module
  ## needs — are all "does any expression anywhere do X", so they share this one
  ## definition of "anywhere" rather than each restating it.
  for fn in module.functions:
    if fn.body != nil: yield fn.body
  for declaration in module.types:
    for methodDecl in declaration.methods:
      if methodDecl.body != nil: yield methodDecl.body
    if declaration.constructor != nil and declaration.constructor.body != nil:
      yield declaration.constructor.body
  for implementation in module.impls:
    for implMethod in implementation.methods:
      if implMethod.body != nil: yield implMethod.body

proc moduleAny(module: WebModule, predicate: proc(expr: WebExpr): bool): bool =
  for root in module.expressionRoots:
    if predicate(root): return true

proc usesStructuralEquality(expr: WebExpr): bool =
  if expr.kind == wekBinary and expr.text in ["==", "!="] and
      expr.children[0].typ.kind in
        {wtkList, wtkPropMap, wtkMap, wtkNode, wtkAny, wtkNominal}:
    return true
  for child in expr.children:
    if usesStructuralEquality(child): return true

proc moduleUsesStructuralEquality(module: WebModule): bool =
  module.moduleAny(usesStructuralEquality)

proc usesDisplayConcat(expr: WebExpr): bool =
  ## A `$` with a non-Str operand, which is what needs the display helper. A
  ## Str-only concatenation stays a plain `+`.
  if expr.kind == wekBinary and expr.text == "$" and
      (expr.children[0].typ.kind != wtkStr or
       expr.children[1].typ.kind != wtkStr):
    return true
  for child in expr.children:
    if usesDisplayConcat(child): return true

proc moduleUsesDisplayConcat(module: WebModule): bool =
  module.moduleAny(usesDisplayConcat)

proc usesExprKind(expr: WebExpr, kinds: set[WebExprKind]): bool =
  if expr.kind in kinds: return true
  for child in expr.children:
    if usesExprKind(child, kinds): return true

proc moduleUsesExprKind(module: WebModule,
                        kinds: set[WebExprKind]): bool =
  module.moduleAny(proc(expr: WebExpr): bool = usesExprKind(expr, kinds))

proc usesStrictSelector(expr: WebExpr): bool =
  if expr.kind == wekSelector and expr.boolValue: return true
  for child in expr.children:
    if usesStrictSelector(child): return true

proc moduleUsesStrictSelector(module: WebModule): bool =
  module.moduleAny(usesStrictSelector)

proc usesPatternMatching(expr: WebExpr): bool =
  if expr.kind == wekMatch or expr.patterns.len > 0: return true
  for child in expr.children:
    if usesPatternMatching(child): return true

proc moduleUsesPatternMatching(module: WebModule): bool =
  module.moduleAny(usesPatternMatching)

proc usesGeneCatch(expr: WebExpr): bool =
  if expr.kind == wekTry and expr.patterns.len > 0: return true
  for child in expr.children:
    if usesGeneCatch(child): return true

proc moduleUsesGeneCatch(module: WebModule): bool =
  module.moduleAny(usesGeneCatch)

const patternFormHeads = ["path", "unquote", "not", "|", "&", "..."]

proc patternHasSymbolHead(pattern: Value): bool =
  ## Mirrors `emitPattern`'s dispatch: a node pattern with a plain-symbol head is
  ## the two-representation form, so the module needs the node brand and the
  ## field accessors whether or not that head names a declared type.
  case pattern.kind
  of vkList:
    for item in pattern.listItems:
      if patternHasSymbolHead(item): return true
  of vkMap:
    for _, item in pattern.mapEntries:
      if patternHasSymbolHead(item): return true
  of vkNode:
    if pattern.head.kind == vkSymbol and
        pattern.head.symVal notin patternFormHeads:
      return true
    for _, item in pattern.props:
      if patternHasSymbolHead(item): return true
    for item in pattern.body:
      if patternHasSymbolHead(item): return true
  else: discard

proc usesSymbolHeadPattern(expr: WebExpr): bool =
  for pattern in expr.patterns:
    if patternHasSymbolHead(pattern): return true
  for child in expr.children:
    if usesSymbolHeadPattern(child): return true

proc nominalTypeNames(module: WebModule): HashSet[string] =
  for declaration in module.types: result.incl declaration.sourceName
  for declaration in module.visibleTypes: result.incl declaration.sourceName

proc moduleUsesSymbolHeadPattern(module: WebModule): bool =
  module.moduleAny(usesSymbolHeadPattern)

proc usesDivision(expr: WebExpr, kind: WebTypeKind): bool =
  if expr.kind == wekBinary and expr.text in ["/", "//"] and
      expr.typ.kind == kind: return true
  for child in expr.children:
    if usesDivision(child, kind): return true

proc moduleUsesDivision(module: WebModule, kind: WebTypeKind): bool =
  module.moduleAny(proc(expr: WebExpr): bool = usesDivision(expr, kind))

proc usesBuiltin(expr: WebExpr, names: openArray[string]): bool =
  if expr.kind == wekBuiltin and expr.text in names: return true
  for child in expr.children:
    if usesBuiltin(child, names): return true

proc moduleUsesBuiltin(module: WebModule, names: openArray[string]): bool =
  let admitted = @names
  module.moduleAny(proc(expr: WebExpr): bool = usesBuiltin(expr, admitted))

proc containsTypeKind(typ: WebType, kind: WebTypeKind): bool =
  if typ == nil: return false
  if typ.kind == kind: return true
  case typ.kind
  of wtkList, wtkTask, wtkStream: containsTypeKind(typ.item, kind)
  of wtkMap:
    containsTypeKind(typ.params[0], kind) or
      containsTypeKind(typ.params[1], kind)
  of wtkCallback:
    for param in typ.params:
      if containsTypeKind(param, kind): return true
    containsTypeKind(typ.returnType, kind)
  of wtkUnion:
    for member in typ.members:
      if containsTypeKind(member, kind): return true
    false
  else: false

proc moduleUsesTypeKind(module: WebModule, kind: WebTypeKind): bool =
  for fn in module.functions:
    if containsTypeKind(fn.returnType, kind): return true
    for param in fn.params:
      if containsTypeKind(param.typ, kind): return true
  for extern in module.externs:
    if containsTypeKind(extern.returnType, kind): return true
    for param in extern.params:
      if containsTypeKind(param.typ, kind): return true
  for declaration in module.types:
    for field in declaration.fields:
      if containsTypeKind(field.typ, kind): return true
    for bodyType in declaration.bodyFields:
      if containsTypeKind(bodyType, kind): return true
    if containsTypeKind(declaration.bodyRest, kind): return true
    for methodDecl in declaration.methods:
      if containsTypeKind(methodDecl.returnType, kind): return true
      for param in methodDecl.params:
        if containsTypeKind(param.typ, kind): return true
    if declaration.constructor != nil:
      for param in declaration.constructor.params:
        if containsTypeKind(param.typ, kind): return true
  for declaration in module.enums:
    for variant in declaration.variants:
      for payloadType in variant.payload:
        if containsTypeKind(payloadType, kind): return true
  for declaration in module.protocols:
    for messageDecl in declaration.messages:
      if containsTypeKind(messageDecl.returnType, kind): return true
      for param in messageDecl.params:
        if containsTypeKind(param.typ, kind): return true
  for implementation in module.impls:
    for methodDecl in implementation.methods:
      if containsTypeKind(methodDecl.returnType, kind): return true
      for param in methodDecl.params:
        if containsTypeKind(param.typ, kind): return true

proc exprUsesTypeKind(expr: WebExpr, kind: WebTypeKind): bool =
  if containsTypeKind(expr.typ, kind): return true
  for child in expr.children:
    if exprUsesTypeKind(child, kind): return true

proc moduleExprUsesTypeKind(module: WebModule, kind: WebTypeKind): bool =
  module.moduleAny(proc(expr: WebExpr): bool = exprUsesTypeKind(expr, kind))

proc emitStructuralEquality(emitter: var WebEmitter,
                            includeMaps, includeObjects: bool) =
  let params =
    if emitter.typescript: "a: any, b: any"
    else: "a, b"
  emitter.line("function $gene_equal(" & params & ")" &
    (if emitter.typescript: ": boolean" else: "") & " {")
  inc emitter.indent
  emitter.line("if (a === b) return true;")
  emitter.line("if (typeof a === \"symbol\" && typeof b === \"symbol\") return Symbol.keyFor(a) === Symbol.keyFor(b);")
  emitter.line("if (Array.isArray(a) || Array.isArray(b)) {")
  inc emitter.indent
  emitter.line("if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;")
  emitter.line("for (let i = 0; i < a.length; i++) if (!$gene_equal(a[i], b[i])) return false;")
  emitter.line("return true;")
  dec emitter.indent
  emitter.line("}")
  if includeMaps:
    emitter.line("const aMap = a?.$gene_map === true; const bMap = b?.$gene_map === true;")
    emitter.line("if (aMap || bMap) {")
    inc emitter.indent
    emitter.line("if (!aMap || !bMap || a.size !== b.size) return false;")
    emitter.line("const unmatched = [...b.entries()];")
    emitter.line("outer: for (const [key, value] of a) { for (let i = 0; i < unmatched.length; i++) { if ($gene_equal(key, unmatched[i][0]) && $gene_equal(value, unmatched[i][1])) { unmatched.splice(i, 1); continue outer; } } return false; }")
    emitter.line("return true;")
    dec emitter.indent
    emitter.line("}")
  if includeObjects:
    emitter.line("if (a && b && typeof a === \"object\" && typeof b === \"object\") {")
    inc emitter.indent
    emitter.line("const aKeys = Object.keys(a).filter(key => key !== \"meta\");")
    emitter.line("const bKeys = Object.keys(b).filter(key => key !== \"meta\");")
    emitter.line("if (aKeys.length !== bKeys.length) return false;")
    emitter.line("for (const key of aKeys) if (!Object.prototype.hasOwnProperty.call(b, key) || !$gene_equal(a[key], b[key])) return false;")
    emitter.line("return true;")
    dec emitter.indent
    emitter.line("}")
  emitter.line("return false;")
  dec emitter.indent
  emitter.line("}")
  emitter.line()

proc emitValidators(emitter: var WebEmitter, module: WebModule) =
  var types: seq[WebType]
  for fn in module.functions:
    for param in fn.params: collectValidatorTypes(param.typ, types)
    collectValidatorTypes(fn.returnType, types)
  for extern in module.externs:
    for param in extern.params: collectValidatorTypes(param.typ, types)
    collectValidatorTypes(extern.returnType, types)
  for declaration in module.types:
    for field in declaration.fields: collectValidatorTypes(field.typ, types)
    for bodyType in declaration.bodyFields:
      collectValidatorTypes(bodyType, types)
    if declaration.bodyRest != nil:
      collectValidatorTypes(declaration.bodyRest, types)
    for methodDecl in declaration.methods:
      for param in methodDecl.params: collectValidatorTypes(param.typ, types)
      collectValidatorTypes(methodDecl.returnType, types)
    if declaration.constructor != nil:
      for param in declaration.constructor.params:
        collectValidatorTypes(param.typ, types)
  for declaration in module.enums:
    for variant in declaration.variants:
      for typ in variant.payload: collectValidatorTypes(typ, types)
  for implementation in module.impls:
    for implMethod in implementation.methods:
      for param in implMethod.params: collectValidatorTypes(param.typ, types)
      collectValidatorTypes(implMethod.returnType, types)
  let errorParams =
    if emitter.typescript: "where: string, expected: string, value: unknown"
    else: "where, expected, value"
  emitter.line("function $gene_type_error(" & errorParams & ")" &
    (if emitter.typescript: ": never" else: "") & " {")
  inc emitter.indent
  emitter.line("throw new TypeError(`${where} expected ${expected}, got ${typeof value}`);")
  dec emitter.indent
  emitter.line("}")
  emitter.line()
  for typ in types:
    let valueParams =
      if emitter.typescript: "value: unknown, where: string"
      else: "value, where"
    let validatorReturn =
      if emitter.typescript: ": " & tsType(typ) else: ""
    emitter.line("function " & validatorName(typ) & "(" & valueParams & ")" &
      validatorReturn & " {")
    inc emitter.indent
    case typ.kind
    of wtkNil:
      emitter.line("if (value !== null) $gene_type_error(where, \"Nil\", value);")
    of wtkVoid:
      emitter.line("if (value !== undefined) $gene_type_error(where, \"Void\", value);")
    of wtkBool:
      emitter.line("if (typeof value !== \"boolean\") $gene_type_error(where, \"Bool\", value);")
    of wtkStr:
      emitter.line("if (typeof value !== \"string\") $gene_type_error(where, \"Str\", value);")
    of wtkSym:
      emitter.line("if (typeof value !== \"symbol\") $gene_type_error(where, \"Sym\", value);")
    of wtkInt:
      emitter.line("if (typeof value !== \"bigint\") $gene_type_error(where, \"Int\", value);")
    of wtkF64:
      emitter.line("if (typeof value !== \"number\") $gene_type_error(where, \"F64\", value);")
    of wtkAny:
      discard
    of wtkNever:
      emitter.line("$gene_type_error(where, \"Never\", value);")
    of wtkList:
      emitter.line("if (!Array.isArray(value)) $gene_type_error(where, \"" &
        typeName(typ) & "\", value);")
      emitter.line("for (const item of value) " & validatorName(typ.item) &
        "(item, `${where} item`);")
    of wtkCallback:
      emitter.line("if (typeof value !== \"function\") $gene_type_error(where, \"Callback\", value);")
    of wtkPropMap:
      emitter.line("if (value === null || typeof value !== \"object\" || Array.isArray(value)) $gene_type_error(where, \"PropMap\", value);")
    of wtkMap:
      emitter.line("if (!(value instanceof GeneMap)) $gene_type_error(where, \"Map\", value);")
      emitter.line("for (const [key, item] of value) {")
      inc emitter.indent
      emitter.line(validatorName(typ.params[0]) & "(key, `${where} key`);")
      emitter.line(validatorName(typ.params[1]) & "(item, `${where} value`);")
      dec emitter.indent
      emitter.line("}")
    of wtkNode:
      emitter.line("if (!$gene_is_node(value)) $gene_type_error(where, \"Node\", value);")
    of wtkDomTarget:
      # The honest check: exactly the operations the DOM ABI lets a target
      # receive. Structural rather than `instanceof EventTarget` so a node in
      # another realm (an iframe, a test document) still validates.
      emitter.line("if (value === null || (typeof value !== \"object\" && " &
        "typeof value !== \"function\") || typeof (value" &
        (if emitter.typescript: " as { addEventListener?: unknown }" else: "") &
        ").addEventListener !== \"function\") " &
        "$gene_type_error(where, \"EventTarget\", value);")
    of wtkRange:
      emitter.line("if (!(value instanceof GeneRange)) $gene_type_error(where, \"Range\", value);")
    of wtkTask:
      emitter.line("if (!(value instanceof GeneTask)) $gene_type_error(where, \"Task\", value);")
    of wtkStream:
      let nextAccess = if emitter.typescript:
                         "(value as { next?: unknown }).next"
                       else: "value.next"
      emitter.line("if (value === null || typeof value !== \"object\" || typeof " &
        nextAccess & " !== \"function\") $gene_type_error(where, \"Stream\", value);")
    of wtkNominal:
      var isEnum = false
      var protocol: WebProtocolDecl
      for declaration in module.visibleEnums:
        if declaration.sourceName == typ.name: isEnum = true
      for declaration in module.visibleProtocols:
        if declaration.sourceName == typ.name: protocol = declaration
      if protocol != nil:
        emitter.line("if (value == null) $gene_type_error(where, " &
          jsString(typ.name) & ", value);")
        for messageDecl in protocol.messages:
          let access = if emitter.typescript:
            "(value as any)[" & messageDecl.symbolName & "]"
          else: "value[" & messageDecl.symbolName & "]"
          emitter.line("if (typeof " & access & " !== \"function\") $gene_type_error(where, " &
            jsString(typ.name) & ", value);")
      elif isEnum:
        let tagged = if emitter.typescript:
                       "(value as any).$gene_tag"
                     else: "value.$gene_tag"
        emitter.line("if (value === null || typeof value !== \"object\" || typeof " &
          tagged & " !== \"string\" || !" & tagged & ".startsWith(" &
          jsString(typ.name & "/") & ")) $gene_type_error(where, " &
          jsString(typ.name) & ", value);")
      else:
        emitter.line("if (!(value instanceof " & mangleWebName(typ.name) & ")) $gene_type_error(where, " & jsString(typ.name) & ", value);")
    of wtkUnion:
      # Union validators use individual predicates below; the generated
      # runtime accepts a member if its validator returns without throwing.
      var names: seq[string]
      for member in typ.members: names.add validatorName(member)
      emitter.line("let $gene_ok = false;")
      emitter.line("for (const check of [" & names.join(", ") & "]) {")
      inc emitter.indent
      emitter.line("try { check(value, where); $gene_ok = true; break; } catch {}");
      dec emitter.indent
      emitter.line("}")
      emitter.line("if (!$gene_ok) $gene_type_error(where, " & jsString(typeName(typ)) & ", value);")
    if typ.kind == wtkCallback:
      var callbackParams, checkedParams: seq[string]
      for i, param in typ.params:
        let name = "arg" & $i
        callbackParams.add name &
          (if emitter.typescript: ": unknown" else: "")
        checkedParams.add validatorName(param) & "(" & name &
          ", `${where} argument " & $(i + 1) & "`)"
      emitter.line("return (" & callbackParams.join(", ") & ") => {")
      inc emitter.indent
      emitter.line("const result = value(" & checkedParams.join(", ") & ");")
      emitter.line("return " & validatorName(typ.returnType) &
        "(result, `${where} return`);")
      dec emitter.indent
      emitter.line("};")
    else:
      emitter.line("return value" &
        (if emitter.typescript: " as " & tsType(typ) else: "") & ";")
    dec emitter.indent
    emitter.line("}")
    emitter.line()

proc allFields(module: WebModule, declaration: WebTypeDecl): seq[WebField] =
  if declaration.parentName.len > 0:
    for parent in module.visibleTypes:
      if parent.sourceName == declaration.parentName:
        result.add allFields(module, parent)
        break
  result.add declaration.fields

proc allImplementedProtocols(module: WebModule,
                             declaration: WebTypeDecl): seq[string] =
  if declaration.parentName.len > 0:
    for parent in module.visibleTypes:
      if parent.sourceName == declaration.parentName:
        result.add allImplementedProtocols(module, parent)
        break
  for protocolName in declaration.implementedProtocols:
    if protocolName notin result: result.add protocolName

proc allBodySchema(module: WebModule,
                   declaration: WebTypeDecl): tuple[
                     fixed: seq[WebType], rest: WebType] =
  if declaration.parentName.len > 0:
    for parent in module.visibleTypes:
      if parent.sourceName == declaration.parentName:
        result = allBodySchema(module, parent)
        break
  result.fixed.add declaration.bodyFields
  if declaration.bodyRest != nil: result.rest = declaration.bodyRest

proc inheritedConstructor(module: WebModule,
                          declaration: WebTypeDecl): WebConstructor =
  var current = declaration
  while current != nil:
    if current.constructor != nil: return current.constructor
    if current.parentName.len == 0: break
    let parentName = current.parentName
    current = nil
    for candidate in module.visibleTypes:
      if candidate.sourceName == parentName:
        current = candidate
        break

proc emitTypeDeclaration(emitter: var WebEmitter, module: WebModule,
                         declaration: WebTypeDecl) =
  emitter.currentLoc = declaration.loc
  let extendsClause = if declaration.parentName.len > 0:
                        " extends " & mangleWebName(declaration.parentName)
                      else: ""
  emitter.line("export class " & declaration.emittedName & extendsClause & " {")
  inc emitter.indent
  if emitter.typescript:
    for field in allFields(module, declaration):
      emitter.line("declare " & field.emittedName &
        (if field.optional: "?" else: "") &
        ": " & tsType(field.typ) & ";")
    emitter.line("declare $gene_body: unknown[];")
    for implementation in module.impls:
      if implementation.targetName != declaration.sourceName: continue
      for implMethod in implementation.methods:
        var params: seq[string]
        for param in implMethod.params:
          params.add param.emittedName & ": " & tsType(param.typ)
        emitter.line("declare readonly [" & implMethod.message.symbolName &
          "]: (" & params.join(", ") & ") => " &
          tsType(implMethod.returnType) & ";")
  let fieldsType = if emitter.typescript:
    ": Record<string, unknown> = {}, body: unknown[] = [], $in_progress: boolean = false, immutable: boolean = false"
  else: " = {}, body = [], $in_progress = false, immutable = false"
  emitter.line("constructor(fields" & fieldsType & ") {")
  inc emitter.indent
  if declaration.parentName.len > 0:
    emitter.line("super(fields, body, true);")
  emitter.line("Object.assign(this, fields);")
  emitter.line("this.$gene_body = body.map(value => value === undefined ? null : value);")
  emitter.line("if (!$in_progress) { this.$gene_validate(); if (immutable) { Object.freeze(this.$gene_body); Object.freeze(this); } }")
  dec emitter.indent
  emitter.line("}")
  emitter.line("$gene_validate()" &
    (if emitter.typescript: ": void" else: "") & " {")
  inc emitter.indent
  var allowedFields = @[jsString("$gene_body")]
  for field in allFields(module, declaration):
    allowedFields.add jsString(field.sourceName)
  var allowedChecks: seq[string]
  for fieldName in allowedFields: allowedChecks.add "key !== " & fieldName
  emitter.line("for (const key of Object.keys(this)) if (" &
    (if allowedChecks.len == 0: "true" else: allowedChecks.join(" && ")) &
    ") $gene_type_error(" &
    jsString(declaration.sourceName & " field") &
    ", \"closed schema\", key);")
  for field in allFields(module, declaration):
    if not field.optional:
      emitter.line("if (!Object.prototype.hasOwnProperty.call(this, " &
        jsString(field.sourceName) & ")) $gene_type_error(" &
        jsString(declaration.sourceName & " field " & field.sourceName) &
        ", " & jsString(typeName(field.typ)) & ", undefined);")
    emitter.line("if (this[" & jsString(field.sourceName) & "] !== undefined) " &
      validatorName(field.typ) & "(this[" & jsString(field.sourceName) & "], " &
      jsString(declaration.sourceName & " field " & field.sourceName) & ");")
  let bodySchema = allBodySchema(module, declaration)
  emitter.line("if (this.$gene_body.length < " & $bodySchema.fixed.len &
    (if bodySchema.rest == nil:
      " || this.$gene_body.length > " & $bodySchema.fixed.len
     else: "") & ") $gene_type_error(" &
    jsString(declaration.sourceName & " body") & ", " &
    jsString(if bodySchema.rest == nil: $bodySchema.fixed.len & " values"
             else: $bodySchema.fixed.len & " or more values") &
    ", this.$gene_body);")
  for i, bodyType in bodySchema.fixed:
    emitter.line(validatorName(bodyType) & "(this.$gene_body[" & $i & "], " &
      jsString(declaration.sourceName & " body " & $i) & ");")
  if bodySchema.rest != nil:
    emitter.line("for (let i = " & $bodySchema.fixed.len &
      "; i < this.$gene_body.length; i++) " & validatorName(bodySchema.rest) &
      "(this.$gene_body[i], " &
      jsString(declaration.sourceName & " repeated body") & ");")
  dec emitter.indent
  emitter.line("}")
  let constructor = inheritedConstructor(module, declaration)
  if constructor != nil:
    var params: seq[string]
    for param in constructor.params:
      params.add param.emittedName &
        (if emitter.typescript: ": " & tsType(param.typ) else: "")
    emitter.line("static $gene_new(" & params.join(", ") & ")" &
      (if emitter.typescript: ": " & declaration.emittedName else: "") & " {")
    inc emitter.indent
    emitter.line("const self = new " & declaration.emittedName & "({}, [], true);")
    let body = emitter.emitExpr(constructor.body)
    emitter.line("void " & body & ";")
    emitter.line("self.$gene_validate();")
    emitter.line("return self;")
    dec emitter.indent
    emitter.line("}")
  for methodDecl in declaration.methods:
    var params: seq[string]
    for param in methodDecl.params:
      params.add param.emittedName &
        (if emitter.typescript: ": " & tsType(param.typ) else: "")
    emitter.line(methodDecl.emittedName & "(" & params.join(", ") & ")" &
      (if emitter.typescript: ": " & tsType(methodDecl.returnType) else: "") & " {")
    inc emitter.indent
    emitter.line("const self = this;")
    for param in methodDecl.params:
      emitter.line(param.emittedName & " = " & validatorName(param.typ) & "(" &
        param.emittedName & ", " &
        jsString(declaration.sourceName & "." & methodDecl.sourceName &
          " argument " & param.sourceName) & ");")
    let body = emitter.emitExpr(methodDecl.body)
    emitter.line("return " & validatorName(methodDecl.returnType) & "(" & body &
      ", " & jsString(declaration.sourceName & "." & methodDecl.sourceName &
        " return") & ");")
    dec emitter.indent
    emitter.line("}")
  dec emitter.indent
  emitter.line("}")
  emitter.line()

proc emitEnumDeclaration(emitter: var WebEmitter,
                         declaration: WebEnumDecl) =
  emitter.currentLoc = declaration.loc
  if emitter.typescript:
    var variants: seq[string]
    for variant in declaration.variants:
      variants.add "Readonly<{ $gene_tag: " &
        jsString(declaration.sourceName & "/" & variant.sourceName) &
        "; $gene_values: ReadonlyArray<unknown> }>"
    emitter.line("export type " & declaration.emittedName & " = " &
      variants.join(" | ") & ";")
  emitter.line("export const " & declaration.emittedName & " = Object.freeze({")
  inc emitter.indent
  for variant in declaration.variants:
    let tag = declaration.sourceName & "/" & variant.sourceName
    if variant.payload.len == 0:
      emitter.line(variant.emittedName & ": Object.freeze({ $gene_tag: " &
        jsString(tag) & ", $gene_values: Object.freeze([]) }),")
    else:
      var params: seq[string]
      var values: seq[string]
      for i, typ in variant.payload:
        params.add "value" & $i &
          (if emitter.typescript: ": " & tsType(typ) else: "")
        values.add "value" & $i
      emitter.line(variant.emittedName & ": (" & params.join(", ") & ")" &
        (if emitter.typescript: ": " & declaration.emittedName else: "") &
        " => Object.freeze({ $gene_tag: " & jsString(tag) &
        ", $gene_values: Object.freeze([" & values.join(", ") & "]) }),")
  dec emitter.indent
  emitter.line("});")
  emitter.line()

proc emitProtocolDeclaration(emitter: var WebEmitter,
                             declaration: WebProtocolDecl) =
  emitter.currentLoc = declaration.loc
  for messageDecl in declaration.messages:
    emitter.line("export const " & messageDecl.symbolName & " = Symbol(" &
      jsString(declaration.sourceName & ":" & messageDecl.sourceName) & ");")
  if emitter.typescript:
    emitter.line("export interface " & declaration.emittedName & " {")
    inc emitter.indent
    for messageDecl in declaration.messages:
      var params: seq[string]
      for param in messageDecl.params:
        params.add param.emittedName & ": " & tsType(param.typ)
      emitter.line("readonly [" & messageDecl.symbolName & "]: (" &
        params.join(", ") & ") => " & tsType(messageDecl.returnType) & ";")
    dec emitter.indent
    emitter.line("}")
  if declaration.messages.len > 0:
    var members: seq[string]
    for messageDecl in declaration.messages:
      members.add(mangleWebName(messageDecl.sourceName) & ": " &
        messageDecl.symbolName)
    emitter.line("export const " & declaration.emittedName &
      " = Object.freeze({" & members.join(", ") & "});")
  if declaration.messages.len > 0: emitter.line()

proc emitImplDeclaration(emitter: var WebEmitter,
                         implementation: WebImplDecl) =
  emitter.currentLoc = implementation.loc
  let builtinTarget = implementation.targetName in ["Nil", "Str", "List"]
  for implMethod in implementation.methods:
    var params: seq[string]
    if builtinTarget:
      let selfType = case implementation.targetName
        of "Nil": "null"
        of "Str": "string"
        else: "ReadonlyArray<unknown>"
      params.add "self" & (if emitter.typescript: ": " & selfType else: "")
    elif emitter.typescript:
      params.add "this: " & mangleWebName(implementation.targetName)
    for param in implMethod.params:
      params.add param.emittedName &
        (if emitter.typescript: ": " & tsType(param.typ) else: "")
    if builtinTarget:
      emitter.line("function " & implFunctionName(implementation.protocolName,
        implementation.targetName, implMethod.message.sourceName) & "(" &
        params.join(", ") & ")" &
        (if emitter.typescript: ": " & tsType(implMethod.returnType) else: "") &
        " {")
    else:
      emitter.line("Object.defineProperty(" & mangleWebName(implementation.targetName) &
        ".prototype, " & implMethod.message.symbolName & ", { configurable: false, value: function(" &
        params.join(", ") & ")" &
        (if emitter.typescript: ": " & tsType(implMethod.returnType) else: "") & " {")
    inc emitter.indent
    if not builtinTarget: emitter.line("const self = this;")
    for param in implMethod.params:
      emitter.line(param.emittedName & " = " & validatorName(param.typ) & "(" &
        param.emittedName & ", " &
        jsString(implementation.protocolName & ":" &
          implMethod.message.sourceName & " argument " & param.sourceName) &
        ");")
    let body = emitter.emitExpr(implMethod.body)
    emitter.line("return " & validatorName(implMethod.returnType) & "(" & body &
      ", " & jsString(implementation.protocolName & ":" &
        implMethod.message.sourceName & " return") & ");")
    dec emitter.indent
    emitter.line(if builtinTarget: "}" else: "} });")
  if implementation.methods.len > 0: emitter.line()

proc emitModule(module: WebModule, typescript: bool,
                lineLocs: var seq[SourceLoc]): string =
  let nominalTypes = nominalTypeNames(module)
  var emitter = WebEmitter(typescript: typescript, nominalTypes: nominalTypes)
  emitter.line("// Generated from " & module.sourcePath & "; target es2022.")
  for imported in module.imports:
    emitter.currentLoc = imported.loc
    var selections: seq[string]
    for selection in imported.selections:
      let sourceName = mangleWebName(selection.sourceName)
      let localName = mangleWebName(selection.localName)
      if sourceName == localName: selections.add sourceName
      else: selections.add sourceName & " as " & localName
    let target = "./" & splitFile(imported.resolvedPath).name &
      (if typescript: ".js" else: ".mjs")
    emitter.line("import { " & selections.join(", ") & " } from " &
                 jsString(target) & ";")
  for extern in module.externs:
    emitter.currentLoc = extern.loc
    emitter.line("import { " & extern.importName & " as " &
                 extern.emittedName & " } from " &
                 jsString(extern.modulePath) & ";")
  emitter.currentLoc = SourceLoc()
  if module.imports.len > 0 or module.externs.len > 0: emitter.line()
  var needsNode = false
  var needsRange = false
  var needsPath = false
  var needsStream = false
  var needsAsync = false
  var needsDom = false
  var needsMap = false
  let needsIntDivisor = moduleUsesDivision(module, wtkInt)
  let needsF64Divisor = moduleUsesDivision(module, wtkF64)
  needsNode = moduleUsesTypeKind(module, wtkNode) or
    moduleUsesExprKind(module, {wekNode}) or
    needsIntDivisor or needsF64Divisor # the divisor guards raise a Gene node
  needsRange = moduleUsesTypeKind(module, wtkRange) or
    moduleUsesExprKind(module, {wekRange})
  needsPath = moduleUsesExprKind(module, {wekPath, wekSelector, wekSetPath})
  needsDom = moduleUsesExprKind(module, {wekDomRender})
  let needsDomEvents = moduleUsesExprKind(module, {wekDomListener}) or
    moduleUsesTypeKind(module, wtkDomTarget)
  needsMap = moduleUsesTypeKind(module, wtkMap) or
    moduleUsesExprKind(module, {wekMap})
  needsStream = moduleUsesTypeKind(module, wtkStream)
  # Keyed on what the emitted code actually references, not on `fn.async`: a
  # function is async as soon as it calls one, and such a caller may never touch
  # `scope`, `spawn`, `await`, or a `Task` value of its own.
  needsAsync = moduleUsesTypeKind(module, wtkTask) or
    moduleExprUsesTypeKind(module, wtkTask) or
    moduleUsesExprKind(module, {wekScope, wekSpawn, wekAwait})
  let needsGeneCatch = moduleUsesGeneCatch(module)
  let needsPatternFields = moduleUsesSymbolHeadPattern(module)
  let needsNodeBrand = needsNode or needsPath or needsDom or needsPatternFields
  for fn in module.functions:
    if fn.generator: needsStream = true
  if moduleUsesBuiltin(module, ["to_stream", "map", "filter", "into"]):
    needsStream = true
  if needsAsync or needsGeneCatch:
    # Cancellation is branded with a registry symbol, not a `kind` string: a
    # nominal Gene type may declare its own `^kind Str` field, and a structural
    # test would make `(fail (T ^kind "gene_cancellation"))` uncatchable. A
    # symbol key cannot collide with a Gene field name, and `Symbol.for` is the
    # one identity that survives the module boundary the class does not.
    emitter.line("const $gene_cancellation = Symbol.for(\"gene.cancellation\");")
    emitter.line()
  if needsNodeBrand:
    # Same reasoning for node identity. `instanceof GeneNode` is false for a node
    # built in another module, which silently turned an imported node's prop read
    # into `undefined` and would keep node catch patterns from ever matching.
    emitter.line("const $gene_node = Symbol.for(\"gene.node\");")
    # A type predicate, not a `boolean`: a Gene catch variable is `unknown` under
    # strict TypeScript, and the pattern tests that follow read `.head`/`.props`.
    emitter.line("function $gene_is_node(value" &
      (if typescript: ": unknown" else: "") & ")" &
      (if typescript:
         ": value is { head: symbol; props: Record<string, unknown>; body: unknown[] }"
       else: "") &
      " { return typeof value === \"object\" && value !== null && " &
      "$gene_node in value; }")
    emitter.line()
  if needsPatternFields:
    # A symbol-head pattern matches a type instance *or* Gene node data with
    # that head, exactly as the VM does, so its accessors have to read both
    # shapes. Presence is separate from value: naming an absent optional field
    # is a non-match in the VM, not a binding of `nil`.
    let valueParam = if typescript: "value: unknown" else: "value"
    let keyParam = if typescript: "key: string" else: "key"
    emitter.line("function $gene_has_field(" & valueParam & ", " & keyParam &
      ")" & (if typescript: ": boolean" else: "") &
      " { return $gene_is_node(value) ? " &
      "Object.prototype.hasOwnProperty.call(value.props, key) : " &
      "Object.prototype.hasOwnProperty.call(value" &
      (if typescript: " as object" else: "") & ", key); }")
    emitter.line("function $gene_field(" & valueParam & ", " & keyParam & ")" &
      (if typescript: ": unknown" else: "") &
      " { return $gene_is_node(value) ? value.props[key] : (value" &
      (if typescript: " as Record<string, unknown>" else: "") & ")[key]; }")
    emitter.line("function $gene_body_of(" & valueParam & ")" &
      (if typescript: ": unknown[]" else: "") &
      " { return $gene_is_node(value) ? value.body : (value" &
      (if typescript: " as { $gene_body: unknown[] }" else: "") &
      ").$gene_body; }")
    emitter.line()
  if needsMap:
    emitter.line("export class GeneMap" &
      (if typescript: "<K, V>" else: "") & " {")
    inc emitter.indent
    if typescript: emitter.line("private items: Array<[K, V]> = [];")
    emitter.line((if typescript: "readonly " else: "") & "$gene_map = true;")
    emitter.line("constructor(entries" &
      (if typescript: ": Iterable<[K, V]> = []" else: " = []") &
      ") { this.items = []; for (const [key, value] of entries) this.#insert(key, value); }")
    emitter.line("get size()" & (if typescript: ": number" else: "") &
      " { return this.items.length; }")
    emitter.line((if typescript: "private " else: "") & "indexOf(key" &
      (if typescript: ": K" else: "") & ")" &
      (if typescript: ": number" else: "") &
      " { return this.items.findIndex(entry => $gene_equal(entry[0], key)); }")
    emitter.line("get(key" & (if typescript: ": K" else: "") & ")" &
      (if typescript: ": V | undefined" else: "") &
      " { const index = this.indexOf(key); return index < 0 ? undefined : this.items[index][1]; }")
    emitter.line("has(key" & (if typescript: ": K" else: "") & ")" &
      (if typescript: ": boolean" else: "") &
      " { return this.indexOf(key) >= 0; }")
    emitter.line("#insert(key" & (if typescript: ": K, value: V" else: ", value") &
      ")" & (if typescript: ": this" else: "") &
      " { const index = this.indexOf(key); if (index < 0) this.items.push([key, value]); else this.items[index][1] = value; return this; }")
    emitter.line("[Symbol.iterator]()" &
      (if typescript: ": Iterator<[K, V]>" else: "") &
      " { return this.items[Symbol.iterator](); }")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if needsNode or needsPath or needsDom:
    emitter.line("export class GeneNode {")
    inc emitter.indent
    let publicField = if typescript: "public " else: ""
    emitter.line((if typescript: "readonly " else: "") &
      "[$gene_node] = true;")
    emitter.line("constructor(" & publicField & "head" &
      (if typescript: ": symbol" else: "") & ", " & publicField & "props" &
      (if typescript: ": Record<string, unknown> = {}" else: " = {}") &
      ", " & publicField & "body" &
      (if typescript: ": unknown[] = []" else: " = []") & ", immutable" &
      (if typescript: ": boolean = false" else: " = false") & ") {}")
    # Parameter properties initialize TS output; the runnable ESM is emitted
    # directly, so give both artifacts the same explicit assignments.
    emitter.lines[^1] = emitter.lines[^1][0 .. ^4] & " { this.head = head; this.props = props; this.body = body; if (immutable) { Object.freeze(this.props); Object.freeze(this.body); Object.freeze(this); } }"
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if needsIntDivisor or needsF64Divisor:
    # A zero divisor is a catchable Gene error in the VM for both numeric types
    # (`vm.nim` `biDiv`/`biRem`), so raise the VM's own value rather than
    # letting JS return Infinity or throw a RangeError.
    let divisionByZero = "throw new GeneNode(Symbol.for(\"Error\"), " &
      "{ message: \"division by zero\" }, [], true);"
    if needsIntDivisor:
      let intType = if typescript: ": bigint" else: ""
      emitter.line("function $gene_int_divisor(divisor" & intType & ")" &
        intType & " { if (divisor === 0n) " & divisionByZero &
        " return divisor; }")
    if needsF64Divisor:
      let f64Type = if typescript: ": number" else: ""
      emitter.line("function $gene_f64_divisor(divisor" & f64Type & ")" &
        f64Type & " { if (divisor === 0) " & divisionByZero &
        " return divisor; }")
    emitter.line()
  if needsRange:
    emitter.line("export class GeneRange {")
    inc emitter.indent
    let fieldTypes = if typescript: ": bigint" else: ""
    let rangePublic = if typescript: "public " else: ""
    emitter.line("constructor(" & rangePublic & "start" & fieldTypes & ", " &
      rangePublic & "stop" & fieldTypes & ", " & rangePublic & "step" &
      fieldTypes & " = 1n, " & rangePublic & "inclusive" &
      (if typescript: ": boolean" else: "") & " = false) {")
    inc emitter.indent
    emitter.line("this.start = start; this.stop = stop; this.step = step; this.inclusive = inclusive;")
    emitter.line("if (step === 0n) throw new RangeError(\"range step must not be zero\");")
    dec emitter.indent
    emitter.line("}")
    emitter.line("*[Symbol.iterator]()" &
      (if typescript: ": Generator<bigint>" else: "") & " {")
    inc emitter.indent
    emitter.line("const forward = this.step > 0n;")
    emitter.line("for (let value = this.start; forward ? (this.inclusive ? value <= this.stop : value < this.stop) : (this.inclusive ? value >= this.stop : value > this.stop); value += this.step) yield value;")
    dec emitter.indent
    emitter.line("}")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if needsStream:
    emitter.line("export class GeneEndOfStream extends Error {")
    inc emitter.indent
    emitter.line("constructor() { super(\"end of stream\"); this.name = \"EndOfStream\"; }")
    dec emitter.indent
    emitter.line("}")
    emitter.line("export class GeneStream" &
      (if typescript: "<T>" else: "") & " {")
    inc emitter.indent
    if typescript:
      emitter.line("private buffered: IteratorResult<T> | undefined;")
      emitter.line("private closed = false;")
    let privateField = if typescript: "private " else: ""
    emitter.line("constructor(" & privateField & "source" &
      (if typescript: ": Iterator<T>" else: "") &
      ") { this.source = source; this.buffered = undefined; this.closed = false; }")
    emitter.line(privateField & "pull()" &
      (if typescript: ": IteratorResult<T>" else: "") & " {")
    inc emitter.indent
    emitter.line("if (this.closed) return { done: true, value: undefined }" &
      (if typescript: " as IteratorReturnResult<any>" else: "") & ";")
    emitter.line("if (this.buffered === undefined) this.buffered = this.source.next();")
    emitter.line("return this.buffered;")
    dec emitter.indent
    emitter.line("}")
    emitter.line("has_next()" & (if typescript: ": boolean" else: "") &
      " { return !this.pull().done; }")
    emitter.line("peek()" & (if typescript: ": T" else: "") & " {")
    inc emitter.indent
    emitter.line("const item = this.pull(); if (item.done) throw new GeneEndOfStream(); return item.value;")
    dec emitter.indent
    emitter.line("}")
    emitter.line("next()" & (if typescript: ": T" else: "") & " {")
    inc emitter.indent
    emitter.line("const item = this.pull(); if (item.done) throw new GeneEndOfStream(); this.buffered = undefined; return item.value;")
    dec emitter.indent
    emitter.line("}")
    emitter.line("close()" & (if typescript: ": void" else: "") & " {")
    inc emitter.indent
    emitter.line("if (this.closed) return; this.closed = true; this.buffered = undefined; if (typeof this.source.return === \"function\") this.source.return();")
    dec emitter.indent
    emitter.line("}")
    emitter.line("*[Symbol.iterator]()" &
      (if typescript: ": Generator<T, void, unknown>" else: "") & " {")
    inc emitter.indent
    emitter.line("try { while (this.has_next()) yield this.next(); } finally { this.close(); }")
    dec emitter.indent
    emitter.line("}")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
    if moduleUsesBuiltin(module, ["map", "filter", "into"]):
      let anyType = if typescript: ": any" else: ""
      emitter.line("function $gene_stream_map(source" & anyType & ", mapper" &
        anyType & ")" & anyType & " {")
      inc emitter.indent
      emitter.line("function* mapped() { try { while (source.has_next()) yield mapper(source.next()); } finally { source.close(); } } return new GeneStream(mapped());")
      dec emitter.indent
      emitter.line("}")
      emitter.line("function $gene_stream_filter(source" & anyType &
        ", predicate" & anyType & ")" & anyType & " {")
      inc emitter.indent
      emitter.line("function* filtered() { try { while (source.has_next()) { const item = source.next(); const keep = predicate(item); if (keep !== false && keep != null) yield item; } } finally { source.close(); } } return new GeneStream(filtered());")
      dec emitter.indent
      emitter.line("}")
      emitter.line("function $gene_stream_into(source" & anyType &
        ", destination" & anyType & ")" & anyType & " {")
      inc emitter.indent
      emitter.line("try { while (source.has_next()) { const item = source.next(); if (Array.isArray(destination)) destination.push(item); else destination[item[0]] = item[1]; } return destination; } finally { source.close(); }")
      dec emitter.indent
      emitter.line("}")
      emitter.line()
  if needsAsync:
    emitter.line("export class GeneCancellation {")
    inc emitter.indent
    if typescript: emitter.line("readonly kind: \"gene_cancellation\";")
    emitter.line((if typescript: "readonly " else: "") &
      "[$gene_cancellation] = true;")
    emitter.line("constructor() { this.kind = \"gene_cancellation\"; }")
    dec emitter.indent
    emitter.line("}")
    emitter.line("export class GeneTask" &
      (if typescript: "<T>" else: "") & " {")
    inc emitter.indent
    if typescript:
      emitter.line("promise: Promise<T>;")
      emitter.line("cancelled = false;")
    emitter.line("constructor(promise" &
      (if typescript: ": Promise<T>" else: "") &
      ") { this.promise = promise; this.cancelled = false; }")
    emitter.line("cancel()" & (if typescript: ": undefined" else: "") &
      " { this.cancelled = true; return undefined; }")
    if typescript:
      emitter.line("then<TResult1 = T, TResult2 = never>(onfulfilled?: ((value: T) => TResult1 | PromiseLike<TResult1>) | null, onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null): Promise<TResult1 | TResult2> { return this.promise.then(onfulfilled, onrejected); }")
    else:
      emitter.line("then(onfulfilled, onrejected) { return this.promise.then(onfulfilled, onrejected); }")
    dec emitter.indent
    emitter.line("}")
    let anyType = if typescript: ": any" else: ""
    emitter.line("function $gene_spawn(scope" & anyType & ", thunk" & anyType &
      ")" & anyType & " {")
    inc emitter.indent
    emitter.line("let task" & (if typescript: ": GeneTask<any>" else: "") & ";")
    emitter.line("const promise = Promise.resolve().then(async () => { if (task.cancelled) throw new GeneCancellation(); const value = await thunk(); if (task.cancelled) throw new GeneCancellation(); return value; });")
    emitter.line("task = new GeneTask(promise); scope.tasks.add(task); return task;")
    dec emitter.indent
    emitter.line("}")
    let asyncReturn = if typescript: ": Promise<any>" else: ""
    emitter.line("async function $gene_await(task" & anyType & ")" & asyncReturn &
      " { if (task.cancelled) throw new GeneCancellation(); const value = await task; if (task.cancelled) throw new GeneCancellation(); return value; }")
    emitter.line("async function $gene_scope(body" & anyType & ")" & asyncReturn & " {")
    inc emitter.indent
    emitter.line("const scope = { tasks: new Set" &
      (if typescript: "<GeneTask<any>>" else: "") & "() };")
    emitter.line("try { const value = await body(scope); await Promise.allSettled([...scope.tasks].map(task => task.promise)); return value; }")
    emitter.line("catch (error) { for (const task of scope.tasks) task.cancel(); await Promise.allSettled([...scope.tasks].map(task => task.promise)); throw error; }")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if needsGeneCatch:
    # Emitted for every module with a Gene catch, whether or not that module
    # uses async: cancellation can arrive from an imported async function, and
    # it must never be offered to a Gene catch pattern.
    emitter.line("function $gene_cancelled(error" &
      (if typescript: ": unknown" else: "") & ")" &
      (if typescript: ": boolean" else: "") &
      " { return typeof error === \"object\" && error !== null && " &
      "$gene_cancellation in error; }")
    emitter.line()
  if needsDom:
    let anyType = if typescript: ": any" else: ""
    emitter.line("function $gene_dom_render(value" & anyType & ", doc" & anyType &
      " = globalThis.document)" & anyType & " {")
    inc emitter.indent
    emitter.line("if (value == null || value === false) return doc.createTextNode(\"\");")
    emitter.line("if (Array.isArray(value)) { const fragment = doc.createDocumentFragment(); for (const child of value) fragment.append($gene_dom_render(child, doc)); return fragment; }")
    emitter.line("if (!$gene_is_node(value)) return doc.createTextNode(String(typeof value === \"symbol\" ? (Symbol.keyFor(value) ?? value.description) : value));")
    emitter.line("const tag = Symbol.keyFor(value.head) ?? value.head.description;")
    emitter.line("const element = doc.createElement(tag);")
    emitter.line("for (const [rawName, prop] of Object.entries(value.props)) {")
    inc emitter.indent
    emitter.line("if (rawName.startsWith(\"on_\") && typeof prop === \"function\") { element.addEventListener(rawName.slice(3).replaceAll(\"_\", \"\"), prop); continue; }")
    emitter.line("const name = rawName === \"class_name\" ? \"class\" : rawName.replaceAll(\"_\", \"-\");")
    emitter.line("if (prop === false || prop == null) continue;")
    emitter.line("if (prop === true) element.setAttribute(name, \"\"); else element.setAttribute(name, String(prop));")
    dec emitter.indent
    emitter.line("}")
    emitter.line("for (const child of value.body) element.append($gene_dom_render(child, doc));")
    emitter.line("return element;")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if needsDomEvents:
    # The listener is passed through unwrapped so `remove_event_listener` can
    # find it again by identity. There is nothing to adapt: the analyzer has
    # already required a `Callback [Any] Void`, and the emitted Gene function
    # validates its own parameter, so the checking the ABI promises happens at
    # the registration site and inside the handler rather than in a wrapper the
    # remover could not reproduce.
    let targetParam = if typescript: "target: EventTarget" else: "target"
    let typeParam = if typescript: "type: string" else: "type"
    let handlerParam =
      if typescript: "handler: (event: unknown) => void" else: "handler"
    let voidReturn = if typescript: ": void" else: ""
    emitter.line("function $gene_dom_add_event_listener(" & targetParam &
      ", " & typeParam & ", " & handlerParam & ")" & voidReturn &
      " { target.addEventListener(type, handler" &
      (if typescript: " as EventListener" else: "") & "); }")
    emitter.line("function $gene_dom_remove_event_listener(" & targetParam &
      ", " & typeParam & ", " & handlerParam & ")" & voidReturn &
      " { target.removeEventListener(type, handler" &
      (if typescript: " as EventListener" else: "") & "); }")
    emitter.line()
  if moduleUsesDisplayConcat(module):
    # Gene display, not JS `String()`: `null` is "nil", `undefined` is "void",
    # and a symbol is its name. Interpolation is the one place the two
    # backends have to agree character-for-character, since the result is
    # usually what the user sees.
    emitter.line("function $gene_str(value" &
      (if typescript: ": unknown" else: "") & ")" &
      (if typescript: ": string" else: "") & " {")
    inc emitter.indent
    emitter.line("if (typeof value === \"string\") return value;")
    emitter.line("if (value === null) return \"nil\";")
    emitter.line("if (value === undefined) return \"void\";")
    emitter.line("if (typeof value === \"symbol\") return Symbol.keyFor(value) ?? value.description ?? \"\";")
    emitter.line("return String(value);")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if moduleUsesBuiltin(module, ["dom/prevent_default", "dom/stop_propagation"]):
    # Typed as `Any` because an Event has no profile type; the guard is what
    # keeps a mistaken receiver from failing silently, which is the failure mode
    # that makes "is my handler even running?" hard to answer.
    let eventParam = if typescript: "event: any" else: "event"
    let voidReturn = if typescript: ": void" else: ""
    emitter.line("function $gene_dom_prevent_default(" & eventParam & ")" &
      voidReturn & " { if (typeof event?.preventDefault !== \"function\") " &
      "throw new TypeError(\"dom/prevent_default expected an Event\"); " &
      "event.preventDefault(); }")
    emitter.line("function $gene_dom_stop_propagation(" & eventParam & ")" &
      voidReturn & " { if (typeof event?.stopPropagation !== \"function\") " &
      "throw new TypeError(\"dom/stop_propagation expected an Event\"); " &
      "event.stopPropagation(); }")
    emitter.line()
  if moduleUsesBuiltin(module, ["http/get", "http/post_form"]):
    let dynamic = if typescript: ": any" else: ""
    let voidReturn = if typescript: ": void" else: ""
    emitter.line("function $gene_http_request(method" & dynamic & ", url" &
      dynamic & ", body" & dynamic & ", on_ok" & dynamic & ")" & voidReturn &
      " {")
    inc emitter.indent
    emitter.line("const init = body === null ? { method } : { method, headers: { \"content-type\": \"application/x-www-form-urlencoded\" }, body };")
    emitter.line("fetch(url, init).then((response) => {")
    inc emitter.indent
    # A 4xx/5xx is a resolved promise in fetch, so it has to be turned into a
    # rejection explicitly or a failed write would run the success path.
    emitter.line("if (!response.ok) throw new Error(`${method} ${url} failed: ${response.status} ${response.statusText}`);")
    emitter.line("return response.text();")
    dec emitter.indent
    emitter.line("}).then(on_ok).catch((error) => { queueMicrotask(() => { throw error; }); });")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if moduleUsesBuiltin(module, ["html/escape", "html/attr_escape"]):
    emitter.line("function $gene_html_escape(value" &
      (if typescript: ": string" else: "") & ")" &
      (if typescript: ": string" else: "") &
      " { return value.replaceAll(\"&\", \"&amp;\").replaceAll(\"<\", \"&lt;\").replaceAll(\">\", \"&gt;\").replaceAll(\"\\\"\", \"&quot;\").replaceAll(\"'\", \"&#39;\"); }")
    emitter.line()
  if moduleUsesBuiltin(module, ["json/parse", "json/stringify"]):
    let dynamic = if typescript: ": any" else: ""
    emitter.line("function $gene_json_parse(text" &
      (if typescript: ": string" else: "") & ")" & dynamic & " {")
    inc emitter.indent
    emitter.line("let i = 0;")
    emitter.line("const ws = () => { while (/\\s/.test(text[i] ?? \"\")) i++; };")
    emitter.line("const value = ()" & dynamic & " => {")
    inc emitter.indent
    emitter.line("ws(); const start = i; const ch = text[i];")
    emitter.line("if (ch === \"\\\"\") { i++; let escaped = false; while (i < text.length) { const c = text[i++]; if (!escaped && c === \"\\\"\") break; if (!escaped && c === \"\\\\\") escaped = true; else escaped = false; } return JSON.parse(text.slice(start, i)); }")
    emitter.line("if (ch === \"[\") { i++; const out" &
      (if typescript: ": any[]" else: "") &
      " = []; ws(); if (text[i] === \"]\") { i++; return out; } while (true) { out.push(value()); ws(); if (text[i++] === \"]\") return out; } }")
    emitter.line("if (ch === \"{\") { i++; const out" &
      (if typescript: ": Record<string, any>" else: "") &
      " = {}; ws(); if (text[i] === \"}\") { i++; return out; } while (true) { ws(); const key = value(); ws(); if (text[i++] !== \":\") throw new SyntaxError(\"expected JSON colon\"); out[key] = value(); ws(); if (text[i++] === \"}\") return out; } }")
    emitter.line("if (text.startsWith(\"true\", i)) { i += 4; return true; } if (text.startsWith(\"false\", i)) { i += 5; return false; } if (text.startsWith(\"null\", i)) { i += 4; return null; }")
    emitter.line("const match = text.slice(i).match(/^-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?/); if (!match) throw new SyntaxError(`invalid JSON at ${i}`); i += match[0].length; return /[.eE]/.test(match[0]) ? Number(match[0]) : BigInt(match[0]);")
    dec emitter.indent
    emitter.line("};")
    emitter.line("const result = value(); ws(); if (i !== text.length) throw new SyntaxError(`trailing JSON at ${i}`); return result;")
    dec emitter.indent
    emitter.line("}")
    emitter.line("function $gene_json_stringify(value" & dynamic & ")" &
      (if typescript: ": string" else: "") & " {")
    inc emitter.indent
    emitter.line("const seen = new WeakSet();")
    emitter.line("const encode = (item" & dynamic & ")" &
      (if typescript: ": string" else: "") & " => {")
    inc emitter.indent
    emitter.line("if (item === null) return \"null\"; if (typeof item === \"bigint\") return item.toString(); if (typeof item === \"number\") { if (!Number.isFinite(item)) throw new TypeError(\"JSON cannot encode non-finite F64\"); return String(item); } if (typeof item === \"string\" || typeof item === \"boolean\") return JSON.stringify(item);")
    emitter.line("if (typeof item !== \"object\") throw new TypeError(`JSON cannot encode ${typeof item}`); if (seen.has(item)) throw new TypeError(\"JSON cannot encode cycles\"); seen.add(item);")
    emitter.line("let result; if (Array.isArray(item)) result = `[${item.map(encode).join(\",\")}]`; else if (item?.$gene_map === true) result = `{${[...item].map(([key, val]) => { if (typeof key !== \"string\") throw new TypeError(\"JSON Map keys must be Str\"); return `${JSON.stringify(key)}:${encode(val)}`; }).join(\",\")}}`; else result = `{${Object.entries(item).map(([key, val]) => `${JSON.stringify(key)}:${encode(val)}`).join(\",\")}}`; seen.delete(item); return result;")
    dec emitter.indent
    emitter.line("}; return encode(value);")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if needsPath:
    let dynamic = if typescript: ": any" else: ""
    emitter.line("function $gene_get(value" & dynamic & ", key" & dynamic & ")" &
      dynamic & " {")
    inc emitter.indent
    emitter.line("if (value == null) return undefined;")
    emitter.line("if (typeof key === \"bigint\") key = Number(key);")
    emitter.line("if (value?.$gene_map === true) return value.get(key);")
    emitter.line("if (Array.isArray(value?.$gene_body) && typeof key === \"number\") return value.$gene_body[key];")
    emitter.line("if ($gene_is_node(value) && typeof key === \"string\" && Object.prototype.hasOwnProperty.call(value.props, key)) return value.props[key];")
    emitter.line("if (typeof key === \"string\" && !(key in Object(value))) { const camel = key.replace(/_([a-z])/g, (_, ch) => ch.toUpperCase()); if (camel in Object(value)) key = camel; }")
    emitter.line("return value[key];")
    dec emitter.indent
    emitter.line("}")
    emitter.line("function $gene_set(value" & dynamic & ", key" & dynamic &
      ", next" & dynamic & ")" & dynamic & " {")
    inc emitter.indent
    emitter.line("if (value == null) throw new TypeError(\"cannot mutate an absent value\");")
    emitter.line("if (Object.isFrozen(value)) throw new TypeError(\"cannot mutate a frozen value\");")
    emitter.line("if (typeof key === \"bigint\") key = Number(key);")
    emitter.line("if (value?.$gene_map === true) throw new TypeError(\"cannot mutate an immutable Map\");")
    emitter.line("if (Array.isArray(value?.$gene_body) && typeof key === \"number\") { const length = value.$gene_body.length; const previous = value.$gene_body[key]; value.$gene_body[key] = next === undefined ? null : next; try { value.$gene_validate(); } catch (error) { value.$gene_body.length = length; if (key < length) value.$gene_body[key] = previous; throw error; } return next; }")
    emitter.line("if (Array.isArray(value) && next === undefined) next = null;")
    emitter.line("if ($gene_is_node(value) && typeof key === \"string\") { if (next === undefined) delete value.props[key]; else value.props[key] = next; return next; }")
    emitter.line("if (typeof key === \"string\" && !(key in Object(value))) key = key.replace(/_([a-z])/g, (_, ch) => ch.toUpperCase());")
    emitter.line("const had = Object.prototype.hasOwnProperty.call(value, key); const previous = value[key];")
    emitter.line("if (next === undefined) delete value[key]; else value[key] = next;")
    emitter.line("if (typeof value.$gene_validate === \"function\") { try { value.$gene_validate(); } catch (error) { if (had) value[key] = previous; else delete value[key]; throw error; } }")
    emitter.line("return next;")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  if moduleUsesStrictSelector(module):
    emitter.line("class GeneSelectorMissing extends Error {")
    inc emitter.indent
    emitter.line("constructor(segment" &
      (if typescript: ": unknown" else: "") &
      ") { super(`selector segment ${String(segment)} is missing`); this.name = \"SelectorMissing\"; }")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  for declaration in module.enums:
    emitter.emitEnumDeclaration(declaration)
  for declaration in module.protocols:
    emitter.emitProtocolDeclaration(declaration)
  var emittedTypes = initHashSet[string]()
  var visitingTypes = initHashSet[string]()
  proc emitTypeAndParent(declaration: WebTypeDecl) =
    if declaration.sourceName in emittedTypes: return
    if declaration.sourceName in visitingTypes:
      raise webError(declaration.loc,
        "web type inheritance cycle includes " & declaration.sourceName)
    visitingTypes.incl declaration.sourceName
    if declaration.parentName.len > 0:
      var foundParent = false
      for parent in module.types:
        if parent.sourceName == declaration.parentName:
          emitTypeAndParent(parent)
          foundParent = true
          break
      if not foundParent:
        for parent in module.visibleTypes:
          if parent.sourceName == declaration.parentName:
            foundParent = true
            break
      if not foundParent:
        raise newException(WebProfileError,
          "web parent type is not declared in this module: " &
          declaration.parentName)
    emitter.emitTypeDeclaration(module, declaration)
    visitingTypes.excl declaration.sourceName
    emittedTypes.incl declaration.sourceName
  for declaration in module.types:
    emitTypeAndParent(declaration)
  for implementation in module.impls:
    emitter.emitImplDeclaration(implementation)
  if moduleUsesPatternMatching(module):
    emitter.line("class GeneMatchError extends Error {")
    inc emitter.indent
    emitter.line("constructor(value" &
      (if typescript: ": unknown" else: "") & ") {")
    inc emitter.indent
    emitter.line("super(`no pattern matched ${String(value)}`);")
    emitter.line("this.name = \"MatchError\";")
    dec emitter.indent
    emitter.line("}")
    dec emitter.indent
    emitter.line("}")
    emitter.line()
  var needsEquality = needsMap or moduleUsesStructuralEquality(module)
  if needsEquality:
    let needsObjectEquality =
      moduleExprUsesTypeKind(module, wtkPropMap) or
      moduleExprUsesTypeKind(module, wtkNode) or
      moduleExprUsesTypeKind(module, wtkNominal) or
      moduleExprUsesTypeKind(module, wtkAny)
    emitter.emitStructuralEquality(needsMap, needsObjectEquality)
  emitter.emitValidators(module)
  for fn in module.functions:
    emitter.emitFunction(fn)
  if module.namespaces.len > 0:
    for i in countdown(module.namespaces.high, 0):
      let namespace = module.namespaces[i]
      var members: seq[string]
      for fn in namespace.functions:
        let memberName = fn.sourceName.split('/')[^1]
        members.add jsString(memberName) & ": " & fn.emittedName
      for child in module.namespaces:
        if child.path.len == namespace.path.len + 1 and
            child.path[0 ..< namespace.path.len] == namespace.path:
          members.add jsString(child.sourceName) & ": " & child.emittedName
      emitter.line((if namespace.path.len == 1: "export " else: "") &
        "const " & namespace.emittedName & " = Object.freeze({" &
        members.join(", ") & "});")
    emitter.line()
  result = emitter.lines.join("\n")
  lineLocs = emitter.lineLocs
  if result.len == 0 or result[^1] != '\n': result.add '\n'

proc emitDeclarations(module: WebModule): string =
  result.add "// Generated Gene web-profile declarations (TypeScript 5.9.2).\n"
  if moduleUsesTypeKind(module, wtkMap):
    result.add "export declare class GeneMap<K, V> implements Iterable<[K, V]> {\n"
    result.add "  constructor(entries?: Iterable<[K, V]>);\n"
    result.add "  readonly size: number;\n"
    result.add "  get(key: K): V | undefined;\n"
    result.add "  has(key: K): boolean;\n"
    result.add "  [Symbol.iterator](): Iterator<[K, V]>;\n"
    result.add "}\n"
  if moduleUsesTypeKind(module, wtkNode):
    result.add "export declare class GeneNode {\n"
    result.add "  head: symbol; props: Record<string, unknown>; body: unknown[];\n"
    result.add "  constructor(head: symbol, props?: Record<string, unknown>, body?: unknown[], immutable?: boolean);\n"
    result.add "}\n"
  if moduleUsesTypeKind(module, wtkRange):
    result.add "export declare class GeneRange implements Iterable<bigint> {\n"
    result.add "  constructor(start: bigint, stop: bigint, step?: bigint, inclusive?: boolean);\n"
    result.add "  [Symbol.iterator](): Generator<bigint>;\n"
    result.add "}\n"
  if moduleUsesTypeKind(module, wtkStream):
    result.add "export declare class GeneEndOfStream extends Error {}\n"
    result.add "export declare class GeneStream<T> implements Iterable<T> {\n"
    result.add "  constructor(source: Iterator<T>);\n"
    result.add "  has_next(): boolean; peek(): T; next(): T; close(): void;\n"
    result.add "  [Symbol.iterator](): Generator<T, void, unknown>;\n"
    result.add "}\n"
  if moduleUsesTypeKind(module, wtkTask):
    result.add "export declare class GeneCancellation { readonly kind: \"gene_cancellation\"; }\n"
    result.add "export declare class GeneTask<T> implements PromiseLike<T> {\n"
    result.add "  constructor(promise: Promise<T>);\n"
    result.add "  readonly promise: Promise<T>; cancel(): undefined;\n"
    result.add "  then<TResult1 = T, TResult2 = never>(onfulfilled?: ((value: T) => TResult1 | PromiseLike<TResult1>) | null, onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null): Promise<TResult1 | TResult2>;\n"
    result.add "}\n"
  for declaration in module.enums:
    var variants: seq[string]
    for variant in declaration.variants:
      variants.add "Readonly<{ $gene_tag: " &
        jsString(declaration.sourceName & "/" & variant.sourceName) &
        "; $gene_values: ReadonlyArray<unknown> }>"
    result.add "export type " & declaration.emittedName & " = " &
      variants.join(" | ") & ";\n"
    result.add "export declare const " & declaration.emittedName & ": {\n"
    for variant in declaration.variants:
      if variant.payload.len == 0:
        result.add "  readonly " & variant.emittedName & ": " &
          declaration.emittedName & ";\n"
      else:
        var params: seq[string]
        for i, typ in variant.payload:
          params.add "value" & $i & ": " & tsType(typ)
        result.add "  readonly " & variant.emittedName & ": (" &
          params.join(", ") & ") => " & declaration.emittedName & ";\n"
    result.add "};\n"
  for declaration in module.protocols:
    result.add "export interface " & declaration.emittedName & " {\n"
    for messageDecl in declaration.messages:
      var params: seq[string]
      for param in messageDecl.params:
        params.add param.emittedName & ": " & tsType(param.typ)
      result.add "  readonly [" & messageDecl.symbolName & "]: (" &
        params.join(", ") & ") => " & tsType(messageDecl.returnType) & ";\n"
    result.add "}\n"
    for messageDecl in declaration.messages:
      result.add "export declare const " & messageDecl.symbolName &
        ": unique symbol;\n"
    if declaration.messages.len > 0:
      result.add "export declare const " & declaration.emittedName &
        ": Readonly<{\n"
      for messageDecl in declaration.messages:
        result.add "  " & mangleWebName(messageDecl.sourceName) & ": typeof " &
          messageDecl.symbolName & ";\n"
      result.add "}>;\n"
  for declaration in module.types:
    result.add "export declare class " & declaration.emittedName &
      (if declaration.parentName.len > 0:
        " extends " & mangleWebName(declaration.parentName)
       else: "") & " {\n"
    for field in allFields(module, declaration):
      result.add "  " & field.emittedName &
        (if field.optional: "?" else: "") & ": " & tsType(field.typ) & ";\n"
    result.add "  $gene_body: unknown[];\n"
    for implementation in module.impls:
      if implementation.targetName != declaration.sourceName: continue
      for implMethod in implementation.methods:
        var params: seq[string]
        for param in implMethod.params:
          params.add param.emittedName & ": " & tsType(param.typ)
        result.add "  readonly [" & implMethod.message.symbolName & "]: (" &
          params.join(", ") & ") => " & tsType(implMethod.returnType) & ";\n"
    result.add "  constructor(fields?: Record<string, unknown>, body?: unknown[], $in_progress?: boolean, immutable?: boolean);\n"
    let constructor = inheritedConstructor(module, declaration)
    if constructor != nil:
      var params: seq[string]
      for param in constructor.params:
        params.add param.emittedName & ": " & tsType(param.typ)
      result.add "  static $gene_new(" & params.join(", ") & "): " &
        declaration.emittedName & ";\n"
    for methodDecl in declaration.methods:
      var params: seq[string]
      for param in methodDecl.params:
        params.add param.emittedName & ": " & tsType(param.typ)
      result.add "  " & methodDecl.emittedName & "(" & params.join(", ") &
        "): " & tsType(methodDecl.returnType) & ";\n"
    result.add "}\n"
  for fn in module.functions:
    if not fn.publicExport: continue
    var params: seq[string]
    for param in fn.params:
      params.add param.emittedName & ": " & tsType(param.typ)
    result.add "export declare function " & fn.emittedName & "(" &
      params.join(", ") & "): " &
      (if fn.async: "Promise<" & tsType(fn.returnType) & ">"
       else: tsType(fn.returnType)) & ";\n"
  for namespace in module.namespaces:
    if namespace.path.len != 1: continue
    result.add "export declare const " & namespace.emittedName &
      ": Readonly<{\n"
    for fn in namespace.functions:
      var params: seq[string]
      for param in fn.params:
        params.add param.emittedName & ": " & tsType(param.typ)
      result.add "  " & mangleWebName(fn.sourceName.split('/')[^1]) & ": (" &
        params.join(", ") & ") => " &
        (if fn.async: "Promise<" & tsType(fn.returnType) & ">"
         else: tsType(fn.returnType)) & ";\n"
    for child in module.namespaces:
      if child.path.len == 2 and child.path[0] == namespace.path[0]:
        result.add "  " & mangleWebName(child.sourceName) & ": Readonly<Record<string, unknown>>;\n"
    result.add "}>;\n"

const sourceMapBase64 =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

proc encodeVlq(value: int): string =
  var encoded = if value < 0: ((-value) shl 1) or 1 else: value shl 1
  while true:
    var digit = encoded and 31
    encoded = encoded shr 5
    if encoded > 0: digit = digit or 32
    result.add sourceMapBase64[digit]
    if encoded == 0: break

proc sourceMappings(lineLocs: openArray[SourceLoc]): string =
  var previousSourceLine = 0
  var previousSourceCol = 0
  for i, loc in lineLocs:
    if i > 0: result.add ';'
    if not loc.hasSourceLoc: continue
    let sourceLine = max(0, loc.line - 1)
    let sourceCol = max(0, loc.col - 1)
    result.add encodeVlq(0) # generated column
    result.add encodeVlq(0) # source index
    result.add encodeVlq(sourceLine - previousSourceLine)
    result.add encodeVlq(sourceCol - previousSourceCol)
    previousSourceLine = sourceLine
    previousSourceCol = sourceCol

proc webAssetName*(module: WebModule): string =
  ## The base name for this module's artifacts. A file on disk is named by its
  ## path; an embedded block has no file and carries its own name.
  if module.assetName.len > 0: module.assetName
  else: splitFile(module.sourcePath).name

proc sourceMapContent(module: WebModule): string =
  ## What a browser is allowed to read. For an embedded block that is the
  ## block's own text and nothing else — reading `sourcePath` here would hand
  ## every browser the entire server module the block happens to live in.
  if module.embedded: module.embeddedSource
  else: readFile(module.sourcePath)

proc emitSourceMap(module: WebModule, outputName: string,
                   lineLocs: openArray[SourceLoc]): string =
  $(%*{
    "version": 3,
    "file": outputName,
    "sourceRoot": "",
    "sources": [module.sourcePath],
    "sourcesContent": [sourceMapContent(module)],
    "names": newSeq[string](),
    "mappings": sourceMappings(lineLocs)
  })

proc emitWebArtifacts*(module: WebModule): WebArtifacts =
  var jsLocs, tsLocs: seq[SourceLoc]
  result.js = emitModule(module, false, jsLocs)
  result.ts = emitModule(module, true, tsLocs)
  result.declarations = emitDeclarations(module)
  let base = module.webAssetName()
  result.sourceMap = emitSourceMap(module, base & ".mjs", jsLocs)
  result.tsSourceMap = emitSourceMap(module, base & ".ts", tsLocs)
  result.js.add "//# sourceMappingURL=" & base & ".mjs.map\n"
  result.ts.add "//# sourceMappingURL=" & base & ".ts.map\n"

# --- the compile_web_asset seam ----------------------------------------------
#
# One interface owns everything a caller would otherwise re-derive: when to
# compile, where the bytes go, how the map is redacted, how the entry is
# checked, and what URLs the result answers to. Two adapters sit on it — the
# file adapter above (`gene build --target web`, unchanged) and the serve
# adapter the runtime uses. Neither application code nor request handling ever
# sees JavaScript, a hash, or a source map.

type
  WebAssetRoute* = object
    ## One publishable file. The name is relative to whatever asset base the
    ## owning application is configured with, so relocating the whole
    ## deployment under a reverse-proxy prefix moves every route at once.
    fileName*: string
    contentType*: string
    body*: string
    isSourceMap*: bool

  WebAsset* = ref object
    ## An immutable compiled entry. Everything a caller might be tempted to
    ## reach for — the JavaScript, its map, the hashes, the entry's name — is
    ## private; the only public surface is "what routes do you publish" and
    ## "what does a script tag for you look like".
    name: string
    identity: string
    entryFile: string
    mapFile: string
    js: string
    sourceMap: string
    entryName: string
    entryAsync: bool

# A compact SHA-256. Content addressing is the cache-correctness boundary for
# every generated route, so a hash collision would serve stale bytes under a
# fresh URL; that rules out the cheap non-cryptographic hashes. Kept local
# rather than pulling in `std/sha1` (deprecated) or a new dependency.
const sha256K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(value: uint32, bits: int): uint32 {.inline.} =
  (value shr bits) or (value shl (32 - bits))

proc sha256Hex(data: string): string =
  var state: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var padded = data
  padded.add '\x80'
  while padded.len mod 64 != 56: padded.add '\0'
  let bitLen = uint64(data.len) * 8
  for i in countdown(7, 0):
    padded.add char((bitLen shr (i * 8)) and 0xff)
  var w: array[64, uint32]
  var offset = 0
  while offset < padded.len:
    for i in 0 ..< 16:
      let base = offset + i * 4
      w[i] = (uint32(byte(padded[base])) shl 24) or
             (uint32(byte(padded[base + 1])) shl 16) or
             (uint32(byte(padded[base + 2])) shl 8) or
             uint32(byte(padded[base + 3]))
    for i in 16 ..< 64:
      let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
      let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    for i in 0 ..< 64:
      let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let temp1 = h + s1 + ch + sha256K[i] + w[i]
      let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let temp2 = s0 + maj
      h = g; g = f; f = e
      e = d + temp1
      d = c; c = b; b = a
      a = temp1 + temp2
    state[0] += a; state[1] += b; state[2] += c; state[3] += d
    state[4] += e; state[5] += f; state[6] += g; state[7] += h
    offset += 64
  const hexDigits = "0123456789abcdef"
  for word in state:
    for i in countdown(7, 0):
      result.add hexDigits[int((word shr (i * 4)) and 0xf)]

proc webContentHash*(bytes: string): string =
  ## The content address every generated route is named by. Truncated to 128
  ## bits: still far past any collision an application can produce, and short
  ## enough that a URL stays readable in devtools.
  sha256Hex(bytes)[0 ..< 32]

proc jsIdentifierIsSafe(name: string): bool =
  if name.len == 0: return false
  for i, c in name:
    case c
    of 'A'..'Z', 'a'..'z', '_', '$': discard
    of '0'..'9':
      if i == 0: return false
    else: return false
  true

proc webAssetEntryFile*(asset: WebAsset): string = asset.entryFile
proc webAssetIdentity*(asset: WebAsset): string = asset.identity
proc webAssetName*(asset: WebAsset): string = asset.name

proc webAssetRoutes*(asset: WebAsset): seq[WebAssetRoute] =
  ## Everything this asset publishes. The map is listed even when a deployment
  ## chooses not to answer for it, so the decision stays with the server rather
  ## than being baked into bytes that are already hashed.
  @[WebAssetRoute(fileName: asset.entryFile,
                  contentType: "text/javascript; charset=utf-8",
                  body: asset.js),
    WebAssetRoute(fileName: asset.mapFile,
                  contentType: "application/json; charset=utf-8",
                  body: asset.sourceMap, isSourceMap: true)]

proc webAssetMountModule*(asset: WebAsset, mountId: string): WebAssetRoute =
  ## The placement bootstrap: the only code that knows a mount id. It is a
  ## generated sibling importing a generated sibling by a relative specifier,
  ## so the pair relocates together under any asset base, and its own content
  ## address covers both the mount id and the entry hash it names — which is
  ## why the entry has to be hashed first.
  var lines: seq[string]
  lines.add "// Generated mount for " & asset.identity & "; do not edit."
  lines.add "import { " & asset.entryName & " } from " &
    jsString("./" & asset.entryFile) & ";"
  lines.add "const root = document.getElementById(" & jsString(mountId) & ");"
  lines.add "if (root === null) throw new Error(" &
    jsString("gene web mount \"" & mountId & "\" is not in the document") & ");"
  if asset.entryAsync:
    # A rejected entry must not decay into an unhandled rejection, which many
    # pages never surface. Rethrowing on the task queue makes it an ordinary
    # uncaught error: it reaches window.onerror, the console, and any error
    # reporter already installed.
    lines.add "Promise.resolve(" & asset.entryName &
      "(root)).catch((error) => { queueMicrotask(() => { throw error; }); });"
  else:
    lines.add asset.entryName & "(root);"
  let body = lines.join("\n") & "\n"
  WebAssetRoute(fileName: asset.name & ".mount-" & webContentHash(body) & ".js",
                contentType: "text/javascript; charset=utf-8", body: body)

proc checkWebEntry(module: WebModule, identity: string):
    tuple[name: string, async: bool] =
  ## `main : EventTarget -> Void`, verified against the analyzed module rather
  ## than against a string appended after emission. A missing, duplicated, or
  ## mis-typed entry is reported at the declaration the author wrote.
  var found: WebFunction = nil
  for fn in module.functions:
    if fn.namespacePath.len == 0 and fn.sourceName == "main":
      if found != nil:
        raise webError(fn.loc, "web module " & identity &
          " declares more than one `main`")
      found = fn
  if found == nil:
    raise webError(module.loc, "web module " & identity &
      " has no entry: it must declare `(fn main [root : EventTarget] : Void ...)`")
  if found.generator:
    raise webError(found.loc, "web module entry `main` must not be a generator")
  if found.params.len != 1:
    raise webError(found.loc,
      "web module entry `main` takes exactly one mount parameter, got " &
      $found.params.len)
  if found.params[0].typ.kind != wtkDomTarget:
    raise webError(found.loc,
      "web module entry `main` must take `EventTarget`, got " &
      typeName(found.params[0].typ))
  if found.returnType.kind != wtkVoid:
    raise webError(found.loc,
      "web module entry `main` must return Void, got " &
      typeName(found.returnType))
  if not jsIdentifierIsSafe(found.emittedName):
    raise webError(found.loc, "web module entry `main` has no emittable name")
  (found.emittedName, found.async)

proc compileWebAsset*(unit: SourceUnit, identity, assetName,
                      embeddedSource: string): WebAsset =
  ## The seam. In: one synthetic source unit and the stable identity it is
  ## known by. Out: an immutable asset that knows its own URLs. Hashing order
  ## is fixed here and nowhere else, because it is genuinely circular
  ## otherwise: the JavaScript ends with the map's URL, so the map has to be
  ## finished and named before the JavaScript can be.
  var macroExports: Table[string, MacroDef]
  let module = analyzeWebUnitWithImports(unit, identity,
    initTable[string, WebFunctionSig](),
    initTable[string, WebTypeDecl](),
    initTable[string, WebEnumDecl](),
    initTable[string, WebProtocolDecl](),
    initTable[string, Table[string, MacroDef]](), macroExports,
    embedded = true)
  module.assetName = assetName
  module.embeddedSource = embeddedSource
  let entry = checkWebEntry(module, identity)
  var jsLocs: seq[SourceLoc]
  var js = emitModule(module, false, jsLocs)
  # 1. the map names a stable file, never a content-addressed one;
  let sourceMap = emitSourceMap(module, assetName & ".js", jsLocs)
  # 2. hashing it fixes the map's URL;
  let mapFile = assetName & "-" & webContentHash(sourceMap) & ".js.map"
  # 3. only now may that URL be appended to the JavaScript;
  js.add "//# sourceMappingURL=" & mapFile & "\n"
  # 4. and hashing the finished JavaScript fixes the entry's URL.
  let entryFile = assetName & "-" & webContentHash(js) & ".js"
  WebAsset(name: assetName, identity: identity, entryFile: entryFile,
           mapFile: mapFile, js: js, sourceMap: sourceMap,
           entryName: entry.name, entryAsync: entry.async)

proc writeWebModule(module: WebModule, outDir: string,
                    resultPaths: var seq[string]) =
  let artifacts = emitWebArtifacts(module)
  createDir(outDir)
  let base = module.webAssetName()
  let outputs = [
    (outDir / (base & ".mjs"), artifacts.js),
    (outDir / (base & ".ts"), artifacts.ts),
    (outDir / (base & ".d.ts"), artifacts.declarations),
    (outDir / (base & ".mjs.map"), artifacts.sourceMap),
    (outDir / (base & ".ts.map"), artifacts.tsSourceMap)
  ]
  for (path, content) in outputs:
    writeFile(path, content)
    resultPaths.add path

proc buildWebModule*(sourcePath, outDir: string): seq[string] =
  let entry = normalizedPath(absolutePath(sourcePath))
  if not fileExists(entry):
    raise newException(WebProfileError, "file not found: " & sourcePath)
  var states = initTable[string, int]() # 1 visiting, 2 complete
  var modules = initTable[string, WebModule]()
  var macroArtifacts = initTable[string, Table[string, MacroDef]]()
  var order: seq[string]
  var basenames = initTable[string, string]()

  proc visit(path: string) =
    if states.getOrDefault(path) == 1:
      raise newException(WebProfileError,
        "web module initialization cycle: " & path)
    if states.getOrDefault(path) == 2:
      return
    if not fileExists(path):
      raise newException(WebProfileError, "web import not found: " & path)
    states[path] = 1
    let source = readFile(path)
    let unit = readAllWithLocs(source, path)
    var importSpecs: seq[WebImport]
    for i, form in unit.forms:
      if i > 0 and form.kind == vkNode and form.head.isSym("import"):
        let loc =
          if unit.locs.hasKey(form.bits): unit.locs[form.bits]
          else: unit.formLocs[i]
        importSpecs.add parseWebImport(form, loc, path)
    for spec in importSpecs:
      visit(spec.resolvedPath)
    var imported = initTable[string, WebFunctionSig]()
    var importedTypes = initTable[string, WebTypeDecl]()
    var importedEnums = initTable[string, WebEnumDecl]()
    var importedProtocols = initTable[string, WebProtocolDecl]()
    var importedMacros = initTable[string, Table[string, MacroDef]]()
    for spec in importSpecs:
      let dependency = modules[spec.resolvedPath]
      let dependencyMacros = macroArtifacts[spec.resolvedPath]
      importedMacros[spec.sourcePath] = dependencyMacros
      var protocolAliases = initTable[string, string]()
      for selection in spec.selections:
        for declaration in dependency.protocols:
          if declaration.sourceName == selection.sourceName:
            protocolAliases[selection.sourceName] = selection.localName
      for selection in spec.selections:
        if dependencyMacros.hasKey(selection.sourceName):
          continue
        var found: WebFunction = nil
        for fn in dependency.functions:
          if fn.sourceName == selection.sourceName:
            found = fn
            break
        if found == nil:
          var foundDeclaration = false
          for declaration in dependency.types:
            if declaration.sourceName == selection.sourceName:
              let bodySchema = allBodySchema(dependency, declaration)
              var implementedProtocols: seq[string]
              for protocolName in allImplementedProtocols(dependency,
                                                          declaration):
                implementedProtocols.add protocolAliases.getOrDefault(
                  protocolName, protocolName)
              importedTypes[selection.localName] = WebTypeDecl(
                sourceName: selection.localName,
                emittedName: mangleWebName(selection.localName),
                fields: allFields(dependency, declaration),
                bodyFields: bodySchema.fixed, bodyRest: bodySchema.rest,
                methods: declaration.methods,
                constructor: inheritedConstructor(dependency, declaration),
                implementedProtocols: implementedProtocols,
                implementsError: declaration.implementsError,
                loc: spec.loc)
              foundDeclaration = true
          for declaration in dependency.enums:
            if declaration.sourceName == selection.sourceName:
              importedEnums[selection.localName] = WebEnumDecl(
                sourceName: selection.localName,
                identityName: declaration.identityName,
                emittedName: mangleWebName(selection.localName),
                variants: declaration.variants, loc: spec.loc)
              foundDeclaration = true
          for declaration in dependency.protocols:
            if declaration.sourceName == selection.sourceName:
              let importedProtocol = WebProtocolDecl(
                sourceName: selection.localName,
                emittedName: mangleWebName(selection.localName), loc: spec.loc)
              for messageDecl in declaration.messages:
                importedProtocol.messages.add WebProtocolMessage(
                  sourceName: messageDecl.sourceName,
                  symbolName: mangleWebName(selection.localName) & "." &
                    mangleWebName(messageDecl.sourceName),
                  params: messageDecl.params,
                  returnType: messageDecl.returnType, loc: spec.loc)
              importedProtocols[selection.localName] = importedProtocol
              foundDeclaration = true
          if not foundDeclaration:
            raise webError(spec.loc, "web module has no exported declaration: " &
              selection.sourceName)
          continue
        if imported.hasKey(selection.localName):
          raise webError(spec.loc, "duplicate web import: " & selection.localName)
        var paramTypes: seq[WebType]
        for param in found.params: paramTypes.add param.typ
        imported[selection.localName] = WebFunctionSig(
          params: paramTypes, returnType: found.returnType,
          callName: mangleWebName(selection.localName),
          valueName: mangleWebName(selection.localName),
          generator: false, async: found.async)
    var macroExports: Table[string, MacroDef]
    let module = analyzeWebModuleWithImports(source, path, imported,
                                             importedTypes, importedEnums,
                                             importedProtocols,
                                             importedMacros, macroExports)
    let base = splitFile(path).name
    if basenames.hasKey(base) and basenames[base] != path:
      raise newException(WebProfileError,
        "web output module name collision: " & basenames[base] & " and " & path)
    basenames[base] = path
    modules[path] = module
    macroArtifacts[path] = macroExports
    states[path] = 2
    order.add path

  visit(entry)
  for path in order:
    writeWebModule(modules[path], outDir, result)
