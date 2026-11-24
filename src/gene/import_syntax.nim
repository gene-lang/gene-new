## Surface spelling for import selectors, shared by the formatter and diagnostics.

import std/strutils
import ./[clause_syntax, printer, types]

type ImportValueRenderer = proc(value: Value): string {.nimcall.}

proc isImportGroupPrefix*(value: Value): bool =
  (value.kind == vkNode and value.head.isSymbolNamed("path")) or
    (value.kind == vkSymbol and value.symVal.endsWith("/"))

proc importPathText(value: Value): string =
  if value.kind == vkSymbol:
    return value.symVal
  if value.kind != vkNode or not value.head.isSymbolNamed("path") or
      value.props.len > 0 or value.meta.len > 0:
    return
  var names: seq[string]
  for segment in value.body:
    if segment.kind != vkSymbol:
      return
    names.add segment.symVal
  names.join("/")

proc renderImportItems*(items: openArray[Value], render: ImportValueRenderer,
                        namespaceSource = false): seq[string]

proc renderImportGroup*(group: Value, render: ImportValueRenderer = print): string =
  (if group.listImmutable: "#[" else: "[") &
    renderImportItems(group.listItems, render).join(" ") & "]"

proc renderImportItems*(items: openArray[Value], render: ImportValueRenderer,
                        namespaceSource: bool): seq[string] =
  var i = 0
  while i < items.len:
    let item = items[i]
    let path = importPathText(item)
    if i < items.high and items[i + 1].kind == vkList and
        not items[i + 1].listImmutable and path.len > 0 and item.isImportGroupPrefix:
      let prefix =
        if namespaceSource and i == 0 and item.kind == vkNode and item.body.len > 1:
          render(item)
        else:
          path.strip(leading = false, chars = {'/'})
      result.add prefix & "/" & renderImportGroup(items[i + 1], render)
      inc i, 2
      continue
    if item.kind == vkList:
      result.add renderImportGroup(item, render)
    elif item.kind == vkNode and item.head.isSymbolNamed("msg") and
        item.props.len == 0 and item.meta.len == 0 and not item.nodeImmutable and
        item.body.len == 2 and item.body[1].kind == vkSymbol:
      let source = importPathText(item.body[0])
      result.add (if source.len == 0: render(item)
                  else: source & ":" & item.body[1].symVal)
    elif item.kind == vkNode and item.head.isSymbolNamed("path") and path.len > 0 and
        item.body.len == 1:
      result.add path & "/"
    else:
      result.add render(item)
    inc i
