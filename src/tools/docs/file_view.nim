## `gene doc <file>`: one module's doc, imports, and declarations, read the way
## the corpus builder reads them. Nothing is compiled or run: a top-level form
## never executes and `main` is never called.
##
## Kinds follow the runtime's names (`Fn`, `Macro`, `Namespace`, `Type`). A
## `let`/`var`/`const` shows its declared type or its literal initializer's
## type; when only running the form would tell, it shows the declaring head
## (`var`).

import std/[algorithm, os, strutils]
import ../../gene/package
import ../declaration_heads
import ./builder
import ./declarations
import ./model
import ./package_walk
import ./sidecar

type
  FileView* = object
    text*: string               ## the report, for standard output
    diagnostics*: seq[string]   ## one line each, for standard error
    readFailed*: bool           ## the module's source did not read

proc kindText(entry: DocEntry): string =
  case entry.kind
  of dkFn:
    if entry.name.len > 1 and entry.name.endsWith("!"): "Fexpr" else: "Fn"
  of dkMacro: "Macro"
  of dkType, dkEnum, dkAlias: "Type"
  of dkProtocol: "Protocol"
  of dkNs: "Namespace"
  of dkMod: "Module"
  of dkLet, dkVar, dkConst:
    if entry.valueType.len > 0: entry.valueType else: geneKindName(entry.kind)
  else: geneKindName(entry.kind)

proc declarationsUnder(doc: ModuleDoc, parent: string): seq[DocEntry] =
  ## A module's or namespace's own declarations, public and private. Type
  ## members (messages, the ctor) belong to their type, not to this list.
  for entry in doc.entries:
    if entry.parent == parent and entry.kind notin {dkMessage, dkCtor}:
      result.add entry
  for entry in doc.privates:
    if entry.parent == parent:
      result.add entry
  result.sort(proc (a, b: DocEntry): int = cmp(a.name, b.name))

proc collectNamespaces(doc: ModuleDoc, parent: string,
                       namespaces: var seq[DocEntry]) =
  for entry in doc.declarationsUnder(parent):
    if entry.kind == dkNs and entry.id.len > 0:
      namespaces.add entry
      doc.collectNamespaces(entry.id, namespaces)

proc importText(imported: DocImport): string =
  if imported.fromModule:
    result = (if imported.implImport: "- import_impl from " else: "- from ") &
      qq(imported.path)
    if imported.pkg.len > 0:
      result.add " ^pkg " & qq(imported.pkg)
    if imported.resolvedFile.len > 0:
      result.add " -> " & imported.resolvedFile
    else:
      result.add " -> unresolved: " & imported.reason
  elif imported.path.len > 0:
    result = "- " & imported.path
  else:
    return "- unreadable import: " & imported.reason
  if imported.alias.len > 0:
    result.add " : " & imported.alias
  elif imported.wildcard:
    result.add " *"
  if imported.selections.len > 0:
    var selections: seq[string]
    for selection in imported.selections:
      if selection.name == selection.local:
        selections.add selection.name
      else:
        selections.add selection.name & " : " & selection.local
    result.add " [" & selections.join(", ") & "]"

proc diagnosticText(diagnostic: DocDiagnostic): string =
  var where = diagnostic.source
  if diagnostic.line > 0 or diagnostic.col > 0:
    where.add ":" & $diagnostic.line & ":" & $diagnostic.col
  where & ": " & diagnostic.kind & ": " & diagnostic.message

proc fileView*(path: string): FileView =
  ## Raises what package discovery raises (a manifest that does not read).
  let file = normalizedPath(absolutePath(path))
  let (pkg, graph, graphDiagnostic) = packageAndGraph(parentDir(file))
  if graphDiagnostic.kind.len > 0:
    result.diagnostics.add diagnosticText(graphDiagnostic)
  # A sidecar given on its own stands alone unless its module source is
  # beside it; then the pair is the module, as in the corpus.
  var source = file
  var sidecarFile = ""
  if file.isSidecar:
    let sibling = file[0 ..< file.len - DocSuffix.len] & SourceSuffix
    if fileExists(sibling):
      source = sibling
      sidecarFile = file
    else:
      source = ""
      sidecarFile = file
  elif fileExists(sidecarFor(file)):
    sidecarFile = sidecarFor(file)
  let modulePath = pkg.modulePathFor(if source.len > 0: source else: file)
  var doc: ModuleDoc
  if source.len > 0:
    doc = buildModuleDoc(pkg, source, modulePath, graph)
  else:
    doc = ModuleDoc(package: pkg.name, module: modulePath,
                    source: pkg.relativeToRoot(file), readable: true)
  if sidecarFile.len > 0 and doc.readable:
    mergeSidecar(doc, pkg, sidecarFile, pkg.relativeToRoot(sidecarFile),
                 source.len == 0, graph)
  for diagnostic in doc.diagnostics:
    result.diagnostics.add diagnosticText(diagnostic)
  if not doc.readable:
    result.readFailed = true
    return

  var lines: seq[string]
  let shown = if source.len > 0: source else: file
  var stem = splitFile(shown).name
  if stem.endsWith(".doc"):
    stem.setLen(stem.len - ".doc".len)
  lines.add "Module: " & (if doc.name.len > 0: doc.name else: stem)
  lines.add "Path: " & shown
  if doc.doc.len > 0:
    lines.add "Doc: " & doc.doc
  if doc.imports.len > 0:
    lines.add "Imports:"
    for imported in doc.imports:
      lines.add importText(imported)
  lines.add "Declarations:"
  let root = "lib/" & doc.module
  for entry in doc.declarationsUnder(root):
    lines.add "- " & entry.name & " : " & kindText(entry)
  var namespaces: seq[DocEntry]
  doc.collectNamespaces(root, namespaces)
  if namespaces.len > 0:
    lines.add "Namespaces:"
    for ns in namespaces:
      lines.add "Namespace " & ns.namePath & ":"
      for entry in doc.declarationsUnder(ns.id):
        lines.add "- " & entry.name & " : " & kindText(entry)
  result.text = lines.join("\n") & "\n"
