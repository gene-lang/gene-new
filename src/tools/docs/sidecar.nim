## Sidecars: `<mod>.doc.gene` beside `<mod>.gene`, or alone for a native
## namespace (design §7, Q32/Q34).
##
## A sidecar holds declarations (which state a shape) and maps (which add
## prose to a declaration the source already shapes). Shape comes from the
## source when there is one; prose comes from the sidecar when it has the
## field, else from the source. A mismatch is a diagnostic, never a failed
## build: the docs still describe everything else.

import std/[strutils]
import ../../gene/[package, reader, types]
import ../declaration_heads
import ./declarations
import ./model

type
  SidecarProse* = object
    forName*: string
    doc*: string
    hasDoc*: bool
    see*: seq[string]
    hasSee*: bool
    status*: string
    hasStatus*: bool
    line*, col*: int

proc proseFromUnit(unit: SourceUnit, sourceRel: string,
                   diagnostics: var seq[DocDiagnostic]): seq[SidecarProse] =
  ## The maps of a sidecar. Declaration forms are walked by the declaration
  ## pass over the same unit, so the file is read and parsed once.
  for i in 0 ..< unit.forms.len:
    let form = unit.forms[i]
    if form.kind != vkMap:
      continue
    let loc = unit.formLocs[i]
    var prose = SidecarProse(line: loc.line, col: loc.col)
    for key, value in form.mapEntries:
      case key
      of "for":
        if value.kind == vkString:
          prose.forName = value.strVal
      of "doc":
        prose.hasDoc = true
        if value.kind == vkString:
          prose.doc = value.strVal
      of "see":
        prose.hasSee = true
        case value.kind
        of vkString:
          prose.see.add value.strVal
        of vkList, vkSet:
          for item in value.listItems:
            if item.kind == vkString:
              prose.see.add item.strVal
        else:
          discard
      of "status":
        prose.hasStatus = true
        if value.kind == vkString:
          prose.status = value.strVal
      else:
        diagnostics.add DocDiagnostic(kind: "sidecar_field",
          message: "unknown sidecar map field: ^" & key, source: sourceRel,
          line: loc.line, col: loc.col)
    if prose.forName.len == 0:
      diagnostics.add DocDiagnostic(kind: "sidecar_field",
        message: "a sidecar prose map requires ^for", source: sourceRel,
        line: loc.line, col: loc.col)
    result.add prose

proc readSidecar*(pkg: Package, file, modulePath, sourceRel: string,
                  graph: MaterializedGraph):
    tuple[doc: ModuleDoc, prose: seq[SidecarProse]] =
  ## Read a sidecar once: one SourceUnit yields both the declarations and the
  ## prose maps. A read error is one diagnostic, labelled with the sidecar's
  ## package-relative path.
  var src = ""
  try:
    src = readFile(file)
  except IOError as error:
    result.doc.package = pkg.name
    result.doc.module = modulePath
    result.doc.source = sourceRel
    result.doc.diagnostics.add DocDiagnostic(kind: "read_error",
      message: "cannot read sidecar: " & error.msg, source: sourceRel)
    return
  var unit: SourceUnit
  try:
    unit = readAllWithLocs(src, sourceRel)
  except ReadError as error:
    result.doc.package = pkg.name
    result.doc.module = modulePath
    result.doc.source = sourceRel
    result.doc.diagnostics.add DocDiagnostic(kind: "read_error",
      message: error.msg, source: sourceRel, line: error.line,
      col: error.col)
    return
  result.doc = buildModuleDocFromUnit(pkg, file, modulePath, sourceRel, graph,
                                      src, unit)
  result.prose = proseFromUnit(unit, sourceRel, result.doc.diagnostics)

proc qualifiedName(modulePath: string, entry: DocEntry): string =
  if entry.forName.len > 0:
    entry.forName
  else:
    modulePath & "/" & entry.namePath

proc paramText(param: DocParam): string =
  (if param.name.len > 0: param.name else: "_") & " : " & param.typ &
    (if param.hasDefault: " = " & param.default else: "")

proc signatureText(entry: DocEntry): string =
  var parts: seq[string]
  for param in entry.positional:
    parts.add paramText(param)
  for param in entry.named:
    parts.add "^" & param.name & " " & paramText(param)
  if entry.rest.typ.len > 0 or entry.rest.name.len > 0:
    parts.add paramText(entry.rest) & "..."
  if entry.namedRest.typ.len > 0 or entry.namedRest.name.len > 0:
    parts.add "^" & paramText(entry.namedRest) & "..."
  var text = "(" & parts.join(" ") & ")"
  if entry.result.len > 0:
    text.add ": " & entry.result
  if entry.errors.len > 0:
    text.add " ^errors [" & entry.errors.join(" ") & "]"
  text

proc shapeMismatch(source, sidecar: DocEntry): string =
  ## A sidecar restates a shape only to have it checked against the source.
  ## Bindings have no shape, so any shape in their sidecar is a mismatch.
  let callable = source.kind in {dkFn, dkMacro, dkMessage, dkCtor, dkType,
                                 dkAlias, dkFfiFn, dkFfiCallback,
                                 dkFfiSignature}
  let sidecarHasShape = sidecar.positional.len > 0 or sidecar.named.len > 0 or
    sidecar.rest.typ.len > 0 or sidecar.namedRest.typ.len > 0 or
    sidecar.result.len > 0 or sidecar.errors.len > 0
  if not callable:
    if sidecarHasShape:
      return "the source declaration has no shape"
    return ""
  if signatureText(source) != signatureText(sidecar):
    return "source " & signatureText(source) & ", sidecar " &
      signatureText(sidecar)

proc mergeProse(target: var DocEntry, sidecar: DocEntry) =
  if sidecar.hasDoc:
    target.doc = sidecar.doc
    target.hasDoc = true
  if sidecar.hasSee:
    target.see = sidecar.see
    target.hasSee = true
  if sidecar.hasStatus:
    target.status = sidecar.status
    target.hasStatus = true

proc applyProse(target: var DocEntry, prose: SidecarProse) =
  if prose.hasDoc:
    target.doc = prose.doc
    target.hasDoc = true
  if prose.hasSee:
    target.see = prose.see
    target.hasSee = true
  if prose.hasStatus:
    target.status = prose.status
    target.hasStatus = true

proc mergeSidecar*(doc: var ModuleDoc, pkg: Package, sidecarFile,
                   sidecarRel: string, standalone: bool,
                   graph: MaterializedGraph) =
  ## Read the sidecar once and fold it into `doc` by field. Every diagnostic
  ## positioned inside the sidecar names the sidecar, not the module source.
  let modulePath = doc.module
  let read = readSidecar(pkg, sidecarFile, modulePath, sidecarRel, graph)
  for diagnostic in read.doc.diagnostics:
    doc.diagnostics.add diagnostic
  if read.doc.doc.len > 0:
    doc.doc = read.doc.doc
  if not read.doc.readable:
    # The sidecar did not read; there is nothing to merge.
    return
  let sidecar = read.doc
  let prose = read.prose

  if standalone:
    doc.readable = sidecar.readable
    doc.entries = sidecar.entries
    for i in 0 ..< doc.entries.len:
      var entry = doc.entries[i]
      let expected = modulePath & "/" & entry.namePath
      if entry.forName.len == 0:
        doc.diagnostics.add DocDiagnostic(kind: "missing_for",
          message: "native documentation requires @for \"" & expected & "\"",
          source: sidecarRel, line: entry.line, col: entry.col)
        entry.forName = expected
      elif entry.forName != expected:
        doc.diagnostics.add DocDiagnostic(kind: "unresolved_for",
          message: "@for \"" & entry.forName & "\" does not name " & expected,
          source: sidecarRel, line: entry.line, col: entry.col)
      doc.entries[i] = entry
  else:
    for sidecarEntry in sidecar.entries:
      let key = qualifiedName(modulePath, sidecarEntry)
      var found = -1
      for i in 0 ..< doc.entries.len:
        if qualifiedName(modulePath, doc.entries[i]) == key:
          found = i
          break
      if found < 0:
        doc.diagnostics.add DocDiagnostic(kind: "unresolved_for",
          message: "@for \"" & key & "\" names nothing in this module",
          source: sidecarRel, line: sidecarEntry.line, col: sidecarEntry.col)
        continue
      let mismatch = shapeMismatch(doc.entries[found], sidecarEntry)
      if mismatch.len > 0:
        doc.diagnostics.add DocDiagnostic(kind: "shape_mismatch",
          message: "sidecar shape differs from the source for \"" & key &
            "\": " & mismatch,
          source: sidecarRel, line: sidecarEntry.line, col: sidecarEntry.col)
      doc.entries[found].mergeProse(sidecarEntry)

  for item in prose:
    var found = -1
    for i in 0 ..< doc.entries.len:
      if qualifiedName(modulePath, doc.entries[i]) == item.forName:
        found = i
        break
    if found < 0:
      doc.diagnostics.add DocDiagnostic(kind: "unresolved_for",
        message: "^for names nothing in this module: " & item.forName,
        source: sidecarRel, line: item.line, col: item.col)
      continue
    doc.entries[found].applyProse(item)
