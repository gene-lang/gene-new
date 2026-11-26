## The declaration pass: read a module's forms, never run them.
##
## `readAllWithLocs` gives the forms and their positions. The shared head table
## (`tools/declaration_heads.nim`) says which forms declare something and what
## to read from each. Types and defaults are sliced from the source text
## (`source_text.nim`), because the reader keeps no location for leaves.
##
## Nothing here evaluates a form, expands a macro, or resolves a name to a
## value. An unknown head becomes an `^unexpanded` record instead of being
## silently dropped.

import std/[os, oserrors, strutils, tables]
import ../../gene/[gir, import_spec, module_resolver, package, printer, reader, types]
import ../declaration_heads
import ../source_positions
import ./model
import ./source_text

type
  DeclBuilder* = object
    doc*: ModuleDoc
    src*: string
    starts*: seq[int]
    unit*: SourceUnit
    graph*: MaterializedGraph
    pkg*: Package
    file*: string
    modulePath*: string
    text*: SourceText
    seen*: Table[string, bool]
    unverified*: bool     ## inside a form flagged `@@unverified`

proc sourceLocOffset(b: DeclBuilder, value: Value): int =
  let loc = b.unit.locs.getOrDefault(value.bits)
  if not loc.hasSourceLoc:
    return -1
  byteOffset(b.starts, loc.line, loc.col)

proc metaString(form: Value, key: string): tuple[present: bool, value: string] =
  if form.kind != vkNode or not form.meta.hasKey(key):
    return (present: false, value: "")
  let value = form.meta[key]
  if value.kind == vkString:
    (present: true, value: value.strVal)
  else:
    (present: true, value: print(value))

proc metaStrings(form: Value, key: string): seq[string] =
  ## `@see` is one string or a list of them; return the list spelling always.
  if form.kind != vkNode or not form.meta.hasKey(key):
    return
  let value = form.meta[key]
  case value.kind
  of vkString:
    result.add value.strVal
  of vkList, vkSet:
    for item in value.listItems:
      if item.kind == vkString:
        result.add item.strVal
  else:
    discard

proc symbolText(value: Value): string =
  if value.kind == vkSymbol: value.symVal else: ""

proc propTrue(form: Value, key: string): bool =
  if form.kind != vkNode or not form.props.hasKey(key):
    return false
  let value = form.props[key]
  value.kind == vkBool and value.boolVal

proc isPrivate(form: Value): bool = propTrue(form, "private")

proc isUnverified(form: Value): bool =
  ## `@@unverified`: doc meta, like `@doc` and `@for`, so it is not a property
  ## of the declaration the language compiles.
  form.kind == vkNode and form.meta.hasKey("unverified") and
    form.meta["unverified"].kind == vkBool and form.meta["unverified"].boolVal

proc entryBase(modulePath: string): string =
  "lib/" & modulePath

proc entryId(modulePath: string, path: seq[string]): string =
  entryBase(modulePath) & "/" & path.join("/")

proc addEntry(b: var DeclBuilder, entry: DocEntry) =
  if b.seen.hasKey(entry.id):
    b.doc.diagnostics.add DocDiagnostic(
      kind: "duplicate_entry", message: "duplicate entry id: " & entry.id,
      source: b.doc.source, line: entry.line, col: entry.col)
    return
  b.seen[entry.id] = true
  b.doc.entries.add entry

proc addDiagnostic(b: var DeclBuilder, kind, message: string, line = 0,
                   col = 0) =
  b.doc.diagnostics.add DocDiagnostic(kind: kind, message: message,
                                      source: b.doc.source, line: line, col: col)

proc addUnexpanded(b: var DeclBuilder, line: int, head, reason: string) =
  b.doc.unexpanded.add DocUnexpanded(line: line, head: head, reason: reason)

# ---------------------------------------------------------------------------
# Signature text
# ---------------------------------------------------------------------------

proc listOffset(b: DeclBuilder, value: Value): int =
  if value.kind != vkList:
    return -1
  b.sourceLocOffset(value)

proc readParamsFromSource(b: var DeclBuilder, offset: int):
    tuple[positional, named: seq[DocParam], rest, namedRest: DocParam] =
  var items = splitItems(b.text, offset)
  var i = 0
  while i < items.len:
    let span = items[i]
    let text = spanText(b.src, span)
    let punct = b.src[span.startByte] in {':', '=', '^', '@', ';'}
    if punct:
      if text in ["^", "^^", "^!"]:
        if i + 1 >= items.len:
          break
        var param = DocParam(required: true)
        param.name = spanText(b.src, items[i + 1])
        i += 2
        param.local = param.name
        if i < items.len and b.src[items[i].startByte] notin {':', '=', '^', '@'}:
          param.local = spanText(b.src, items[i])
          inc i
        if i < items.len and b.src[items[i].startByte] == ':':
          inc i
          if i < items.len:
            param.typ = spanText(b.src, items[i])
            inc i
        if i < items.len and b.src[items[i].startByte] == '=':
          inc i
          if i < items.len:
            param.default = spanText(b.src, items[i])
            param.hasDefault = true
            param.required = false
            inc i
        if param.name.endsWith("..."):
          param.name.setLen(param.name.len - 3)
          if param.local.endsWith("..."):
            param.local.setLen(param.local.len - 3)
          result.namedRest = param
        else:
          result.named.add param
      else:
        inc i
      continue
    var param = DocParam(required: true)
    param.name = text
    inc i
    if i < items.len and b.src[items[i].startByte] == ':':
      inc i
      if i < items.len:
        param.typ = spanText(b.src, items[i])
        inc i
    if i < items.len and b.src[items[i].startByte] == '=':
      inc i
      if i < items.len:
        param.default = spanText(b.src, items[i])
        param.hasDefault = true
        param.required = false
        inc i
    if param.name.endsWith("..."):
      param.name.setLen(param.name.len - 3)
      param.local = param.name
      param.required = false
      result.rest = param
    else:
      param.local = param.name
      result.positional.add param

proc readErrors(b: var DeclBuilder, form: Value): seq[string] =
  ## The `^errors` row as written. The compiler stores `signatureErrorExprs`
  ## only for a list row, so a non-list property is not a row.
  if not form.props.hasKey("errors"):
    return
  let row = form.props["errors"]
  if row.kind notin {vkList, vkSet}:
    return
  let offset = b.listOffset(row)
  if offset < 0:
    b.addDiagnostic("source_missing", "error row has no source location")
    return
  for span in splitItems(b.text, offset):
    let text = spanText(b.src, span)
    if text.len > 0:
      result.add text

proc readReturnType(b: var DeclBuilder, form: Value,
                    paramsIndex: int): string =
  if paramsIndex + 1 < form.body.len and
      form.body[paramsIndex + 1].kind == vkSymbol and
      form.body[paramsIndex + 1].symVal == ":":
    let offset = b.listOffset(form.body[paramsIndex])
    if offset < 0:
      b.addDiagnostic("source_missing", "parameter vector has no source location")
      return
    let span = typeAfterColon(b.text, spanOf(b.text, offset).endByte)
    if span.startByte >= 0:
      return spanText(b.src, span)

proc readSignature(b: var DeclBuilder, form: Value, paramsIndex: int):
    tuple[positional, named: seq[DocParam], rest, namedRest: DocParam,
          result: string] =
  if paramsIndex >= form.body.len:
    return
  let offset = b.listOffset(form.body[paramsIndex])
  if offset < 0:
    b.addDiagnostic("source_missing", "parameter vector has no source location")
    return
  let signature = b.readParamsFromSource(offset)
  result.positional = signature.positional
  result.named = signature.named
  result.rest = signature.rest
  result.namedRest = signature.namedRest
  result.result = b.readReturnType(form, paramsIndex)

proc fillMeta(entry: var DocEntry, form: Value) =
  let doc = metaString(form, "doc")
  if doc.present:
    entry.doc = doc.value
    entry.hasDoc = true
  entry.see = metaStrings(form, "see")
  entry.hasSee = form.kind == vkNode and form.meta.hasKey("see")
  let status = metaString(form, "status")
  if status.present:
    entry.status = status.value
    entry.hasStatus = true
  let forName = metaString(form, "for")
  if forName.present:
    entry.forName = forName.value

# ---------------------------------------------------------------------------
# Type bodies
# ---------------------------------------------------------------------------

proc readPropsMap(b: var DeclBuilder, map: Value): seq[DocParam] =
  ## `^props {^name Str ^nickname Str?}` in source order, with exact type text.
  let offset = b.sourceLocOffset(map)
  if offset < 0:
    b.addDiagnostic("source_missing", "field map has no source location")
    return
  var items = splitItems(b.text, offset)
  var i = 0
  while i < items.len:
    let text = spanText(b.src, items[i])
    if text in ["^", "^^", "^!", "@", "@@", "@!"]:
      inc i
      if i >= items.len:
        break
      let key = spanText(b.src, items[i])
      inc i
      if i >= items.len:
        break
      var param = DocParam(name: key, local: key,
                           typ: spanText(b.src, items[i]), required: true)
      if param.typ.endsWith("?"):
        param.required = false
      result.add param
      inc i
    else:
      inc i

proc readBodyFields(b: var DeclBuilder, body: Value): tuple[
    positional: seq[DocParam], rest: DocParam] =
  let offset = b.listOffset(body)
  var texts: seq[string]
  if offset < 0:
    b.addDiagnostic("source_missing", "body field list has no source location")
    return
  for span in splitItems(b.text, offset):
    texts.add spanText(b.src, span)
  for text in texts:
    if text.len == 0:
      continue
    var param = DocParam(typ: text, required: true)
    if text.endsWith("..."):
      param.typ.setLen(param.typ.len - 3)
      param.required = false
      result.rest = param
    else:
      result.positional.add param

proc readVariants(b: var DeclBuilder, form: Value): seq[DocVariant] =
  for i in 1 ..< form.body.len:
    let item = form.body[i]
    case item.kind
    of vkSymbol:
      result.add DocVariant(name: item.symVal)
    of vkNode:
      var variant = DocVariant(name: headText(item.head))
      let offset = b.sourceLocOffset(item)
      if offset >= 0:
        let items = splitItems(b.text, offset)
        for j in 1 ..< items.len:
          variant.fields.add spanText(b.src, items[j])
      else:
        b.addDiagnostic("source_missing", "enum variant has no source location")
      result.add variant
    else:
      discard

proc readImplements(b: var DeclBuilder, form: Value): seq[string] =
  if not form.props.hasKey("impl"):
    return
  let value = form.props["impl"]
  let offset = b.listOffset(value)
  if offset < 0:
    b.addDiagnostic("source_missing", "^impl row has no source location")
    return
  for span in splitItems(b.text, offset):
    let text = spanText(b.src, span)
    if text.len > 0:
      result.add text

# ---------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------

proc shortened(message: string): string =
  let newline = message.find('\n')
  if newline >= 0: message[0 ..< newline] else: message

proc resolveImport(b: DeclBuilder, imported: var DocImport) =
  ## Resolve like the loader: `^pkg` selects a package, then the module path is
  ## package-relative; without it a `./` path is module-relative and a bare
  ## path is library-root-relative. A failure is a reason, never an error.
  var target = b.pkg
  if imported.pkg.len > 0:
    try:
      target = b.graph.packageForAlias(b.pkg.id, imported.pkg)
    except PackageError as error:
      imported.reason = "package alias is not in the graph: " &
        shortened(error.msg)
      return
  var candidate = ""
  try:
    if imported.pkg.len > 0:
      candidate = packageModulePath(target, imported.path)
    else:
      candidate = resolveFileModule(target, parentDir(b.file), imported.path)
  except PackageError as error:
    imported.reason = shortened(error.msg)
    return
  except GeneError as error:
    imported.reason = shortened(error.msg)
    return
  if not fileExists(candidate):
    # The resolver returns its best candidate even when nothing is there,
    # because the loader fails later when it opens the file. `^resolved` in
    # documentation must mean the module exists.
    imported.reason = "module not found: " & imported.path
    return
  imported.resolvedPackage = target.name
  imported.resolvedModule = target.relativeModulePath(candidate)
  imported.resolvedFile = candidate

proc recordImport(b: var DeclBuilder, form: Value, loc: SourceLoc) =
  let head = headText(form.head)
  if head == "import_impl":
    var imported = DocImport(implImport: true, fromModule: true,
                             line: loc.line, col: loc.col)
    if form.props.hasKey("from") and form.props["from"].kind == vkString:
      imported.path = form.props["from"].strVal
    else:
      imported.reason = "import_impl requires ^from"
    if imported.path.len > 0:
      b.resolveImport(imported)
    b.doc.imports.add imported
    return
  var spec: ImportSpec
  try:
    spec = parseImportSpec(form, loc)
  except GeneError as error:
    b.doc.imports.add DocImport(reason: shortened(error.msg),
                                line: loc.line, col: loc.col)
    return
  var imported = DocImport(line: loc.line, col: loc.col)
  imported.fromModule = spec.fromModule
  imported.pkg = spec.pkgName
  imported.reexport = spec.reexport
  imported.alias = spec.alias
  imported.wildcard = spec.wildcard
  for selection in spec.selections:
    imported.selections.add (name: selection.name, local: selection.local)
  if spec.fromModule:
    imported.path = spec.modulePath
    b.resolveImport(imported)
  else:
    imported.path = spec.nsSegments.join("/")
    if spec.nsSegments.len >= 2 and spec.nsSegments[0] == "gene":
      # A `$name`/`gene/…` namespace is always the runtime's, wherever the
      # importing module lives.
      imported.resolvedPackage = "gene/runtime"
      imported.resolvedModule = spec.nsSegments.join("/")
    else:
      imported.reason = "namespace path is not a module"
  b.doc.imports.add imported

# ---------------------------------------------------------------------------
# Walking
# ---------------------------------------------------------------------------

proc literalTypeName(value: Value): string =
  ## The type a literal initializer has without running anything. A call, a
  ## name, or a quoted form is known only by evaluating it.
  case value.kind
  of vkNil: "Nil"
  of vkBool: "Bool"
  of vkInt: "Int"
  of vkFloat: "Float"
  of vkString: "Str"
  of vkChar: "Char"
  of vkRegex: "Regex"
  of vkList: "List"
  of vkMap: "Map"
  of vkSet: "Set"
  else: ""

proc valueTypeText(form: Value, kind: DeclKind): string =
  ## `(var name : T value)` gives `T` as written; `(var name 42)` gives the
  ## literal's type; anything else gives "".
  if kind notin {dkLet, dkVar, dkConst}:
    return ""
  if form.body.len >= 3 and form.body[1].kind == vkSymbol and
      form.body[1].symVal == ":":
    return print(form.body[2])
  if form.body.len >= 2:
    return literalTypeName(form.body[1])
  if form.body.len == 1:
    return "Nil"

proc walkForm(b: var DeclBuilder, form: Value, loc: SourceLoc,
              path: seq[string], parent: string)
proc walkTypeBody(b: var DeclBuilder, form: Value, typeId: string,
                  typePath: seq[string])
proc walkProtocolBody(b: var DeclBuilder, form: Value, protocolId: string,
                      protocolPath: seq[string])

proc nestedLoc(b: DeclBuilder, form: Value, fallback: SourceLoc): SourceLoc =
  let loc = b.unit.locs.getOrDefault(form.bits)
  if loc.hasSourceLoc: loc else: fallback

proc signatureEntry(b: var DeclBuilder, entry: var DocEntry, form: Value,
                    paramsIndex: int) =
  let signature = b.readSignature(form, paramsIndex)
  entry.positional = signature.positional
  entry.named = signature.named
  entry.rest = signature.rest
  entry.namedRest = signature.namedRest
  entry.result = signature.result
  entry.errors = b.readErrors(form)
  entry.generator = propTrue(form, "generator")
  entry.fexpr = entry.name.len > 1 and entry.name.endsWith("!")

proc recordImpl(b: var DeclBuilder, form: Value, loc: SourceLoc) =
  var protocol = ""
  var receiver = ""
  if form.body.len > 0 and form.body[0].kind == vkSymbol:
    protocol = form.body[0].symVal
  if form.body.len > 2 and form.body[1].kind == vkSymbol and
      form.body[1].symVal == "for" and form.body[2].kind == vkSymbol:
    receiver = form.body[2].symVal
  b.doc.impls.add DocImpl(protocol: protocol, receiver: receiver,
                          line: loc.line, col: loc.col)

proc hiddenPath(path: seq[string], name: string): string =
  (path & @[name]).join("/")

proc walkMessage(b: var DeclBuilder, form: Value, loc: SourceLoc,
                 path: seq[string], parent, separator: string) =
  ## A `message` inside a type or protocol. Type messages are spelled
  ## `Type/message`; protocol requirements take the send spelling
  ## `Protocol:message`.
  if form.body.len == 0 or form.body[0].kind != vkSymbol:
    b.addUnexpanded(loc.line, "message", "message has no name")
    return
  let name = form.body[0].symVal
  var entry = DocEntry(kind: dkMessage, name: name, parent: parent,
                       line: loc.line, col: loc.col)
  entry.namePath = path.join("/") & separator & name
  entry.id = entryBase(b.modulePath) & "/" & path.join("/") & separator & name
  entry.fillMeta(form)
  entry.ownUnverified = form.isUnverified
  entry.unverified = b.unverified or entry.ownUnverified
  b.signatureEntry(entry, form, 1)
  b.addEntry(entry)

proc walkTypeBody(b: var DeclBuilder, form: Value, typeId: string,
                  typePath: seq[string]) =
  # `(type Name : Parent members...)`: the parent type is not a member.
  var memberStart = 1
  if form.body.len > 1 and form.body[1].kind == vkSymbol and
      form.body[1].symVal == ":":
    memberStart = 3
  for i in memberStart ..< form.body.len:
    let item = form.body[i]
    if item.kind != vkNode:
      continue
    let loc = b.nestedLoc(item, b.unit.locs.getOrDefault(form.bits))
    let head = headText(item.head)
    case head
    of "message":
      b.walkMessage(item, loc, typePath, typeId, "/")
    of "ctor":
      var entry = DocEntry(kind: dkCtor, name: "ctor", parent: typeId,
                           line: loc.line, col: loc.col)
      entry.namePath = typePath.join("/") & "/ctor"
      entry.id = entryId(b.modulePath, typePath & @["ctor"])
      entry.fillMeta(item)
      entry.ownUnverified = item.isUnverified
      entry.unverified = b.unverified or entry.ownUnverified
      b.signatureEntry(entry, item, 0)
      b.addEntry(entry)
    of "impl":
      b.recordImpl(item, loc)
    else:
      let found = declarationHeadInfo(head)
      if not found.found:
        b.addUnexpanded(loc.line, head, "not a known declaration")

proc walkProtocolBody(b: var DeclBuilder, form: Value, protocolId: string,
                      protocolPath: seq[string]) =
  for i in 1 ..< form.body.len:
    let item = form.body[i]
    if item.kind != vkNode:
      continue
    let loc = b.nestedLoc(item, b.unit.locs.getOrDefault(form.bits))
    let head = headText(item.head)
    case head
    of "message":
      b.walkMessage(item, loc, protocolPath, protocolId, ":")
    of "derive":
      # A protocol's `derive` form defines how derived types are constructed.
      # It is a compiler-time member, not a reference entry of its own.
      discard
    else:
      let found = declarationHeadInfo(head)
      if not found.found:
        b.addUnexpanded(loc.line, head, "not a known declaration")

proc walkForm(b: var DeclBuilder, form: Value, loc: SourceLoc,
              path: seq[string], parent: string) =
  if form.kind != vkNode:
    return
  let head = headText(form.head)
  if head.len == 0:
    b.addUnexpanded(loc.line, "", "head is not a name")
    return
  # `mod` names the module and runs its body in the module scope: the body's
  # declarations belong to the module itself, not to a namespace.
  if head == "mod":
    if form.body.len > 0 and form.body[0].kind == vkSymbol and path.len == 0:
      b.doc.name = form.body[0].symVal
      let doc = metaString(form, "doc")
      if doc.present:
        b.doc.doc = doc.value
    for i in 1 ..< form.body.len:
      b.walkForm(form.body[i], b.nestedLoc(form.body[i], loc), path, parent)
    return
  # A top-level `do` is a transparent grouping form; its declarations are
  # module declarations.
  if head == "do":
    for child in form.body:
      b.walkForm(child, b.nestedLoc(child, loc), path, parent)
    return
  let found = declarationHeadInfo(head)
  if not found.found:
    let (known, class) = headClass(head)
    if known:
      # A statement or data form: ignored silently by definition.
      discard
    else:
      b.addUnexpanded(loc.line, head,
                      "head is neither a declaration nor a known statement")
    return
  let info = found.info
  case info.kind
  of dkImport, dkImportImpl:
    b.recordImport(form, loc)
    return
  of dkImpl:
    b.recordImpl(form, loc)
    return
  of dkDerive:
    b.addUnexpanded(loc.line, head, "derive is only valid inside a protocol")
    return
  else:
    discard

  var name = ""
  case info.name
  of dnkFirst:
    if form.body.len > 0 and form.body[0].kind == vkSymbol:
      name = form.body[0].symVal
  of dnkCtor:
    name = "ctor"
  of dnkMod:
    if form.body.len > 0 and form.body[0].kind == vkSymbol:
      name = form.body[0].symVal
  of dnkImpl:
    discard
  of dnkNone:
    discard
  if name.len == 0:
    b.addUnexpanded(loc.line, head, "declaration has no readable name")
    return
  if info.exportable and isPrivate(form):
    b.doc.hidden.add hiddenPath(path, name)
    # The corpus documents only the path; `gene doc <file>` also shows the kind.
    b.doc.privates.add DocEntry(kind: info.kind, name: name,
      namePath: (path & @[name]).join("/"),
      parent: (if parent.len > 0: parent else: entryBase(b.modulePath)),
      valueType: valueTypeText(form, info.kind), line: loc.line, col: loc.col)
    return

  var entry = DocEntry(kind: info.kind, name: name, parent: parent,
                       line: loc.line, col: loc.col)
  entry.namePath = (path & @[name]).join("/")
  entry.id = entryId(b.modulePath, path & @[name])
  entry.valueType = valueTypeText(form, info.kind)
  entry.fillMeta(form)
  entry.ownUnverified = form.isUnverified
  entry.unverified = b.unverified or entry.ownUnverified
  if info.callable:
    let paramsIndex =
      case info.kind
      of dkCtor: 0
      else: 1
    b.signatureEntry(entry, form, paramsIndex)
  if info.kind == dkType:
    if form.props.hasKey("props"):
      entry.named = b.readPropsMap(form.props["props"])
    if form.props.hasKey("body"):
      let fields = b.readBodyFields(form.props["body"])
      entry.positional = fields.positional
      entry.rest = fields.rest
    entry.implements = b.readImplements(form)
  if info.kind == dkEnum:
    entry.variants = b.readVariants(form)

  if entry.parent.len == 0:
    entry.parent = entryBase(b.modulePath)
  b.addEntry(entry)
  if info.recurse:
    # A flagged form flags everything declared inside it.
    let outer = b.unverified
    b.unverified = entry.unverified
    case info.kind
    of dkType:
      b.walkTypeBody(form, entry.id, path & @[name])
    of dkProtocol:
      b.walkProtocolBody(form, entry.id, path & @[name])
    of dkNs:
      for i in 1 ..< form.body.len:
        let child = form.body[i]
        b.walkForm(child, b.nestedLoc(child, loc), path & @[name], entry.id)
    else:
      discard
    b.unverified = outer

# ---------------------------------------------------------------------------
# Module entry point
# ---------------------------------------------------------------------------

proc buildModuleDocFromUnit*(pkg: Package, file, modulePath, sourceRel: string,
                             graph: MaterializedGraph, src: string,
                             unit: SourceUnit): ModuleDoc =
  ## Walk an already-read source unit. The VM-side caller reads once; sidecars
  ## share this so their declarations and prose maps come from one parse.
  result.package = pkg.name
  result.module = modulePath
  result.source = sourceRel
  result.readable = true
  var b = DeclBuilder(doc: result, pkg: pkg, file: file, graph: graph,
                      modulePath: modulePath, seen: initTable[string, bool]())
  b.src = src
  b.text = initSourceText(src)
  b.starts = lineStarts(src)
  b.unit = unit
  for i in 0 ..< b.unit.forms.len:
    let loc = b.unit.formLocs[i]
    b.walkForm(b.unit.forms[i], loc, @[], "")
  result = b.doc

proc buildModuleDoc*(pkg: Package, file, modulePath: string,
                     graph: MaterializedGraph): ModuleDoc =
  ## Read one module's source and return its documentation. A read error is a
  ## diagnostic with a position; the caller still writes coverage.
  let sourceRel = relativePath(file, pkg.root).replace('\\', '/')
  result.package = pkg.name
  result.module = modulePath
  result.source = sourceRel
  var src = ""
  try:
    src = readFile(file)
  except IOError as error:
    # The OS message carries the absolute path; the diagnostic already names
    # the package-relative file, and the data must not depend on the checkout.
    result.diagnostics.add DocDiagnostic(kind: "read_error",
      message: "cannot read file: " & sourceRel & ": " &
        osErrorMsg(osLastError()),
      source: sourceRel)
    return
  var unit: SourceUnit
  try:
    unit = readAllWithLocs(src, sourceRel)
  except ReadError as error:
    result.diagnostics.add DocDiagnostic(kind: "read_error",
      message: error.msg, source: sourceRel, line: error.line,
      col: error.col)
    return
  result = buildModuleDocFromUnit(pkg, file, modulePath, sourceRel, graph,
                                  src, unit)
