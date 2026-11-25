## Import forms, read as data: what an `import` or `import_impl` names.
##
## The compiler and the documentation builder must agree about an import, or
## the reference's `^imports` slot describes a different program from the one
## that runs. This module is the reader-level parser only: selectors, aliases,
## groups, wildcards, `^from`, `^pkg`, and `^export`. It never resolves or
## loads anything.

import std/[strutils, tables]
import ./[gir, import_syntax, reader, types]

proc isSymbol(value: Value, name: string): bool =
  value.kind == vkSymbol and value.symVal == name

proc importSelectorPath(value: Value): seq[string] =
  if value.kind == vkSymbol:
    let name = value.symVal
    # The reader leaves unaliased paths inside vectors as symbols.
    if '/' in name and name != "//" and not name.startsWith("/"):
      return importSelectorPath(desugarPath(name))
    if name.len > 0 and '/' notin name:
      return @[name]
  elif value.kind == vkNode and value.head.isSymbol("path") and
      value.body.len > 0 and value.props.len == 0 and value.meta.len == 0:
    for segment in value.body:
      if segment.kind != vkSymbol or segment.symVal.len == 0 or
          '/' in segment.symVal or segment.symVal.startsWith("~") or
          segment.symVal.startsWith("?~"):
        raise newException(GeneError, "import path segments must be names")
      result.add segment.symVal
    return
  raise newException(GeneError, "import selector must be a name or a namespace path")

proc isImportAliasMarker(value: Value): bool =
  value.kind == vkSymbol and value.symVal.startsWith(":")

proc invalidImportAlias(source, alias: string) {.noreturn.} =
  raise newException(GeneError, "write the import alias as `" & source & ":" &
    alias & "` with no spaces around `:`")

proc invalidImportGroupAlias(source, alias: string) {.noreturn.} =
  raise newException(GeneError,
    "alias an individual member inside the import group or write `" &
    source & ":" & alias & "` to bind the namespace")

proc readImportSelector(value, following: Value, grouped: bool): tuple[
    path: seq[string], alias: string] =
  if value.kind == vkNode and value.head.isSymbol("msg") and
      value.body.len == 2 and value.body[1].kind == vkSymbol and
      value.props.len == 0 and value.meta.len == 0:
    result.path = importSelectorPath(value.body[0])
    result.alias = value.body[1].symVal
  else:
    result.path = importSelectorPath(value)
    # A leading $ is desugared as a gene/ path before message qualification.
    if result.path.len > 1 and result.path[0] == "gene":
      let leaf = result.path[^1]
      let colon = qualifiedMessageSplit(leaf)
      if colon > 0:
        result.path[^1] = leaf[0 ..< colon]
        result.alias = leaf[colon + 1 .. ^1]
  for i, segment in result.path:
    let colon = segment.find(':')
    if colon < 0:
      continue
    if colon == segment.high and colon > 0 and i == result.path.high:
      result.path[i] = segment[0 ..< colon]
      let source = result.path.join("/")
      if following.kind == vkList:
        raise newException(GeneError, "use `" & source & "/" & renderImportGroup(following) &
          "` for an import group")
      let alias = if following.kind == vkSymbol: following.symVal else: "alias"
      invalidImportAlias(source, alias)
    if colon > 0 and colon < segment.high:
      let alias = segment[colon + 1 .. ^1]
      result.path[i] = segment[0 ..< colon]
      let source = result.path.join("/")
      let replacement =
        if grouped: source & ":" & alias & " " & source & "/" & renderImportGroup(following)
        else: source & ":" & alias
      raise newException(GeneError,
        "put the import alias at the end of the selector; write `" & replacement & "`")
    invalidImportAlias(segment.strip(chars = {':'}), "alias")
  if result.alias.len > 0:
    let tokens = lexAll(result.alias)
    if ':' in result.alias or '/' in result.alias or
        result.alias in [",", "*", "nil", "true", "false"] or
        tokens.len != 1 or tokens[0].kind != tkSymbol or
        tokens[0].lexeme != result.alias or result.alias.startsWith("."):
      raise newException(GeneError, "import alias must be a single binding name")
  if grouped and result.alias.len > 0:
    invalidImportGroupAlias(result.path.join("/"), result.alias)

proc importSelectionParts(items: openArray[Value], index: int): tuple[
    path: seq[string], alias: string, grouped: bool] =
  let value = items[index]
  let hasNext = index < items.high
  let following = if hasNext: items[index + 1] else: NIL
  result.grouped = following.kind == vkList and
    isImportGroupPrefix(value)
  (result.path, result.alias) = readImportSelector(value, following, result.grouped)
  let after = index + (if result.grouped: 2 else: 1)
  if after <= items.high and isImportAliasMarker(items[after]):
    let marker = items[after].symVal
    let alias =
      if marker.len > 1: marker[1 .. ^1]
      elif after < items.high and items[after + 1].kind == vkSymbol:
        items[after + 1].symVal
      else: "alias"
    let source = result.path.join("/")
    if result.grouped:
      invalidImportGroupAlias(source, alias)
    invalidImportAlias(source, alias)

proc collectImportSelections(items: openArray[Value], prefix: seq[string],
                             selections: var seq[ImportSelection]) =
  let initialCount = selections.len
  var i = 0
  while i < items.len:
    if items[i].isSymbol(","):
      inc i
      continue
    let (path, alias, grouped) = importSelectionParts(items, i)
    if "*" in path:
      raise newException(GeneError, "an import wildcard must be the only selector")
    let fullPath = prefix & path
    if grouped:
      collectImportSelections(items[i + 1].listItems, fullPath, selections)
      inc i, 2
    else:
      selections.add ImportSelection(name: fullPath.join("/"),
        local: if alias.len > 0: alias else: path[^1])
      inc i
  if selections.len == initialCount:
    raise newException(GeneError, "import requires at least one selection")

proc importBindingLabel*(spec: ImportSpec, name: string): string =
  if name.len == 0: spec.sourceLabel
  else: spec.sourceLabel & "/" & name

proc duplicateImportBinding*(local, first, second: string,
                            loc = SourceLoc()) {.noreturn.} =
  let error = newException(GeneError, "duplicate import binding `" & local &
    "` from `" & first & "` and `" & second & "`; use a distinct alias")
  error.loc = loc
  raise error

proc parseImportSpecImpl(node: Value): ImportSpec =
  if node.kind != vkNode or not node.head.isSymbol("import"):
    raise newException(GeneError, "expected import form")
  # Module sources are properties, just like package and export options.
  # Keep the allow-list closed so misspelled options cannot be ignored.
  for key, value in node.props:
    case key
    of "from":
      if value.kind != vkString:
        raise newException(GeneError, "import ^from must be a path string")
      result.fromModule = true
      result.modulePath = value.strVal
    of "export":
      if value.kind != vkBool:
        raise newException(GeneError, "import ^export must be Bool")
      result.reexport = value.boolVal
    of "pkg":
      if value.kind != vkString or value.strVal.len == 0:
        raise newException(GeneError,
          "import ^pkg must be a non-empty package name string")
      result.pkgName = value.strVal
    of "as":
      raise newException(GeneError,
        "import ^as was removed; use `source:alias`")
    else:
      raise newException(GeneError, "import got unexpected option: ^" & key)

  let body = node.body
  if body.len >= 2 and body[^2].isSymbol("from") and
      body[^1].kind == vkString:
    raise newException(GeneError,
      "import: `from` was removed; use `^from \"path\"`")
  if result.fromModule:
    if body.len > 0 and body[0].kind == vkList:
      if body.len == 1 and body[0].listItems.len == 0:
        raise newException(GeneError,
          "omit `[]` to load a module without bindings; write `(import ^from \"path\")`")
      raise newException(GeneError,
        "file import selectors go directly after `import`; write `(import a b ^from \"path\")`")
    elif body.len == 1:
      let (path, alias, grouped) = importSelectionParts(body, 0)
      if not grouped and path[^1] == "*" and
          "*" notin path[0 ..< path.high]:
        result.wildcard = true
        result.wildcardSegments = path[0 ..< path.high]
        result.alias = alias
      else:
        collectImportSelections(body, @[], result.selections)
    elif body.len > 0:
      collectImportSelections(body, @[], result.selections)
    result.sourceLabel = result.modulePath
    if result.wildcardSegments.len > 0:
      result.sourceLabel.add "/" & result.wildcardSegments.join("/")
  else:
    if body.len == 0:
      raise newException(GeneError, "import requires a source")
    let source = importSelectionParts(body, 0)
    result.nsSegments = source.path
    if "*" in result.nsSegments:
      raise newException(GeneError,
        "wildcard imports require `^from \"path\"`; a namespace-path import " &
        "has no `*` form")
    if body.len == 2 and source.grouped:
      collectImportSelections(body[1].listItems, @[], result.selections)
    elif body.len == 2 and source.alias.len == 0:
      if body[1].kind == vkList:
        raise newException(GeneError, "write `" & source.path.join("/") & "/" &
          renderImportGroup(body[1]) & "` to select namespace members")
      collectImportSelections(body.toOpenArray(1, 1), @[], result.selections)
    elif body.len == 1 and source.alias.len > 0:
      result.alias = source.alias
    elif body.len == 1 and source.path.len > 1:
      let member = source.path[^1]
      result.nsSegments.setLen(source.path.len - 1)
      result.selections.add ImportSelection(name: member, local: member)
    else:
      raise newException(GeneError,
        "namespace import requires `source/member`, `source/[members]`, or `source:alias`")
    result.sourceLabel = result.nsSegments.join("/")
  if result.pkgName.len > 0 and not result.fromModule:
    # `^pkg` is valid only on the `^from` form. A bare namespace path never
    # selects a package, so package selection is always explicit.
    raise newException(GeneError,
      "import ^pkg requires `^from \"path\"`; a namespace-path import never " &
      "selects a package")
  if result.pkgName.len > 0:
    result.sourceLabel = result.pkgName & "::" & result.sourceLabel
  if result.wildcard and result.alias.len == 0 and result.reexport:
    raise newException(GeneError,
      "bare wildcards do not re-export; use an alias or explicit selections")
  if result.reexport and not result.fromModule:
    raise newException(GeneError,
      "re-export requires a module-path import")
  if result.reexport and body.len == 0:
    raise newException(GeneError, "load-only imports cannot re-export; remove `^export` or select names")
  var selectedNames: Table[string, string]
  for selection in result.selections:
    if selectedNames.hasKey(selection.local):
      duplicateImportBinding(selection.local,
        result.importBindingLabel(selectedNames[selection.local]),
        result.importBindingLabel(selection.name))
    selectedNames[selection.local] = selection.name

proc parseImportSpec*(node: Value, loc: SourceLoc): ImportSpec =
  try:
    result = parseImportSpecImpl(node)
  except GeneError as error:
    if not error.loc.hasSourceLoc:
      error.loc = loc
    raise
