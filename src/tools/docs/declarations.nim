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

import std/[os, strutils, tables]
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
    seen*: Table[string, bool]

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

proc entryBase(modulePath: string): string =
  "lib/" & modulePath

proc entryId(modulePath: string, path: seq[string]): string =
  entryBase(modulePath) & "/" & path.join("/")

proc parentFor(modulePath: string, path: seq[string]): string =
  if path.len == 0: "" else: entryId(modulePath, path)

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

proc locationOf(b: DeclBuilder, value: Value): SourceLoc =
  result = b.unit.locs.getOrDefault(value.bits)
  if not result.hasSourceLoc and value.kind == vkNode:
    let loc = b.unit.locs.getOrDefault(value.bits)
    result = loc

# ---------------------------------------------------------------------------
# Signature text
# ---------------------------------------------------------------------------

proc listOffset(b: DeclBuilder, value: Value): int =
  if value.kind != vkList:
    return -1
  b.sourceLocOffset(value)

proc fallbackText(value: Value): string =
  if value.isMissing: "" else: print(value)

proc readParamsFromSource(b: var DeclBuilder, offset: int):
    tuple[positional, named: seq[DocParam], rest, namedRest: DocParam] =
  var items = splitItems(b.src, offset)
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

proc readParamsFromValues(params: Value): tuple[
    positional, named: seq[DocParam], rest, namedRest: DocParam] =
  if params.kind != vkList:
    return
  let items = params.listItems
  var i = 0
  while i < items.len:
    let item = items[i]
    if item.kind == vkSymbol and item.symVal == "^":
      if i + 1 >= items.len: break
      var param = DocParam(required: true)
      param.name = items[i + 1].symbolText
      param.local = param.name
      i += 2
      if i < items.len and items[i].kind == vkSymbol and
          items[i].symVal notin [":", "=", "^", "^^", ",", "@"]:
        param.local = items[i].symVal
        inc i
      if i < items.len and items[i].symbolText == ":":
        inc i
        if i < items.len:
          param.typ = fallbackText(items[i])
          inc i
      if i < items.len and items[i].symbolText == "=":
        inc i
        if i < items.len:
          param.default = fallbackText(items[i])
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
      continue
    if item.kind == vkSymbol and item.symVal in [",", "^^", ":"]:
      inc i
      continue
    var param = DocParam(required: true)
    param.name = if item.kind == vkSymbol: item.symVal else: fallbackText(item)
    inc i
    if i < items.len and items[i].symbolText == ":":
      inc i
      if i < items.len:
        param.typ = fallbackText(items[i])
        inc i
    if i < items.len and items[i].symbolText == "=":
      inc i
      if i < items.len:
        param.default = fallbackText(items[i])
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

proc readErrors(b: DeclBuilder, form: Value): seq[string] =
  ## The `^errors` row as written. The compiler stores `signatureErrorExprs`
  ## only for a list row, so a non-list property is not a row.
  if not form.props.hasKey("errors"):
    return
  let row = form.props["errors"]
  if row.kind notin {vkList, vkSet}:
    return
  let offset = b.listOffset(row)
  if offset >= 0:
    for span in splitItems(b.src, offset):
      let text = spanText(b.src, span)
      if text.len > 0:
        result.add text
  else:
    for item in row.listItems:
      result.add fallbackText(item)

proc readReturnType(b: DeclBuilder, form: Value, paramsIndex: int): string =
  if paramsIndex + 1 < form.body.len and
      form.body[paramsIndex + 1].kind == vkSymbol and
      form.body[paramsIndex + 1].symVal == ":":
    let params = form.body[paramsIndex]
    let offset = b.listOffset(params)
    if offset >= 0:
      var i = skipTrivia(b.src, spanOf(b.src, offset).endByte)
      if i < b.src.len and b.src[i] == ':':
        i = skipTrivia(b.src, i + 1)
        let stop = datumEnd(b.src, i)
        let text = spanText(b.src, ByteSpan(startByte: i, endByte: stop))
        if text.len > 0:
          return text
    if paramsIndex + 2 < form.body.len:
      return fallbackText(form.body[paramsIndex + 2])

proc readSignature(b: var DeclBuilder, form: Value, paramsIndex: int):
    tuple[positional, named: seq[DocParam], rest, namedRest: DocParam,
          result: string] =
  if paramsIndex >= form.body.len:
    return
  let params = form.body[paramsIndex]
  let offset = b.listOffset(params)
  let signature =
    if offset >= 0: b.readParamsFromSource(offset)
    else: readParamsFromValues(params)
  result.positional = signature.positional
  result.named = signature.named
  result.rest = signature.rest
  result.namedRest = signature.namedRest
  result.result = b.readReturnType(form, paramsIndex)

proc fillMeta(b: DeclBuilder, entry: var DocEntry, form: Value) =
  discard b
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

proc readPropsMap(b: DeclBuilder, map: Value): seq[DocParam] =
  ## `^props {^name Str ^nickname Str?}` in source order, with exact type text.
  let offset = b.sourceLocOffset(map)
  if offset < 0:
    for key, value in map.mapEntries:
      var param = DocParam(name: key, local: key, typ: fallbackText(value),
                           required: true)
      result.add param
    return
  var items = splitItems(b.src, offset)
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

proc readBodyFields(b: DeclBuilder, body: Value): tuple[
    positional: seq[DocParam], rest: DocParam] =
  let offset = b.listOffset(body)
  var texts: seq[string]
  if offset >= 0:
    for span in splitItems(b.src, offset):
      texts.add spanText(b.src, span)
  else:
    for item in body.listItems:
      texts.add fallbackText(item)
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

proc readVariants(form: Value): seq[DocVariant] =
  for i in 1 ..< form.body.len:
    let item = form.body[i]
    case item.kind
    of vkSymbol:
      result.add DocVariant(name: item.symVal)
    of vkNode:
      var variant = DocVariant(name: headText(item.head))
      for field in item.body:
        variant.fields.add fallbackText(field)
      result.add variant
    else:
      discard

proc readImplements(b: DeclBuilder, form: Value): seq[string] =
  if not form.props.hasKey("impl"):
    return
  let value = form.props["impl"]
  let offset = b.listOffset(value)
  if offset >= 0:
    for span in splitItems(b.src, offset):
      let text = spanText(b.src, span)
      if text.len > 0:
        result.add text
  elif value.kind in {vkList, vkSet}:
    for item in value.listItems:
      result.add fallbackText(item)
  else:
    result.add fallbackText(value)

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
      candidate = fileModulePath(target, parentDir(b.file), imported.path)
  except PackageError as error:
    imported.reason = shortened(error.msg)
    return
  except GeneError as error:
    imported.reason = shortened(error.msg)
    return
  imported.resolvedPackage = target.name
  imported.resolvedModule = target.relativeModulePath(candidate)

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

proc walkForm(b: var DeclBuilder, form: Value, loc: SourceLoc,
              path: seq[string], parent: string)
proc walkTypeBody(b: var DeclBuilder, form: Value, typeId, typeName: string)
proc walkProtocolBody(b: var DeclBuilder, form: Value, protocolId,
                      protocolName: string, entry: var DocEntry)

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
  b.fillMeta(entry, form)
  b.signatureEntry(entry, form, 1)
  b.addEntry(entry)

proc walkTypeBody(b: var DeclBuilder, form: Value, typeId, typeName: string) =
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
      b.walkMessage(item, loc, @[typeName], typeId, "/")
    of "ctor":
      var entry = DocEntry(kind: dkCtor, name: "ctor", parent: typeId,
                           line: loc.line, col: loc.col)
      entry.namePath = typeName & "/ctor"
      entry.id = entryBase(b.modulePath) & "/" & typeName & "/ctor"
      b.fillMeta(entry, item)
      b.signatureEntry(entry, item, 0)
      b.addEntry(entry)
    of "impl":
      b.recordImpl(item, loc)
    else:
      let found = declarationHeadInfo(head)
      if not found.found:
        b.addUnexpanded(loc.line, head, "not a known declaration")

proc walkProtocolBody(b: var DeclBuilder, form: Value, protocolId,
                      protocolName: string, entry: var DocEntry) =
  for i in 1 ..< form.body.len:
    let item = form.body[i]
    if item.kind != vkNode:
      continue
    let loc = b.nestedLoc(item, b.unit.locs.getOrDefault(form.bits))
    let head = headText(item.head)
    case head
    of "message":
      b.walkMessage(item, loc, @[protocolName], protocolId, ":")
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
  if name.endsWith("!"):
    # A fexpr keeps its bang in the source; the entry is named without it so
    # the id is the callable's ordinary spelling, and the flag records it.
    discard
  if isPrivate(form):
    b.doc.hidden.add hiddenPath(path, name)
    return

  var entry = DocEntry(kind: info.kind, name: name, parent: parent,
                       line: loc.line, col: loc.col)
  entry.namePath = (path & @[name]).join("/")
  entry.id = entryId(b.modulePath, path & @[name])
  b.fillMeta(entry, form)
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
    entry.variants = readVariants(form)

  if entry.parent.len == 0:
    entry.parent = entryBase(b.modulePath)
  b.addEntry(entry)
  if info.recurse:
    case info.kind
    of dkType:
      b.walkTypeBody(form, entry.id, name)
    of dkProtocol:
      var protocolEntry = entry
      b.walkProtocolBody(form, entry.id, name, protocolEntry)
      # walkProtocolBody may add derive entries; replace the stored copy.
      for i in 0 ..< b.doc.entries.len:
        if b.doc.entries[i].id == protocolEntry.id:
          b.doc.entries[i] = protocolEntry
          break
    of dkNs:
      for i in 1 ..< form.body.len:
        let child = form.body[i]
        b.walkForm(child, b.nestedLoc(child, loc), path & @[name], entry.id)
    else:
      discard

# ---------------------------------------------------------------------------
# Module entry point
# ---------------------------------------------------------------------------

proc buildModuleDoc*(pkg: Package, file, modulePath: string,
                     graph: MaterializedGraph): ModuleDoc =
  ## Read one module's source and return its documentation. A read error is a
  ## diagnostic with a position; the caller still writes coverage.
  result.package = pkg.name
  result.module = modulePath
  result.source = relativePath(file, pkg.root).replace('\\', '/')
  var b = DeclBuilder(doc: result, pkg: pkg, file: file, graph: graph,
                      modulePath: modulePath, seen: initTable[string, bool]())
  var src = ""
  try:
    src = readFile(file)
  except IOError as error:
    result.diagnostics.add DocDiagnostic(kind: "read_error",
      message: "cannot read file: " & error.msg, source: result.source)
    return result
  b.src = src
  b.starts = lineStarts(src)
  try:
    b.unit = readAllWithLocs(src, result.source)
  except ReadError as error:
    result.diagnostics.add DocDiagnostic(kind: "read_error",
      message: error.msg, source: result.source, line: error.line,
      col: error.col)
    return result
  for i in 0 ..< b.unit.forms.len:
    let loc = b.unit.formLocs[i]
    b.walkForm(b.unit.forms[i], loc, @[], "")
  result = b.doc
