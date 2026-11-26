## The data the builder emits: one module's documentation, as plain Gene data.
##
## The builder's contract with the later Markdown/site/db generator is a file,
## not a type. Everything here therefore has a stable rendering with a fixed
## field order and no timestamps, so the same source tree produces the same
## bytes. See design §7 "As built (M1)" for the schema decisions.

import std/[algorithm, strutils]
import ../../gene/[printer, types]
import ../declaration_heads

type
  DocParam* = object
    ## One parameter as written. `name` is the caller-facing name, `local`
    ## the binding (they differ only for named parameters); `typ` and
    ## `default` are exact source text.
    name*, local*, typ*, default*: string
    required*, hasDefault*: bool

  DocVariant* = object
    name*: string
    fields*: seq[string]

  DocEntry* = object
    id*: string
    name*: string
    namePath*: string        ## local path from the module (`List/push`, `Tool:x`)
    parent*: string          ## "" for a module-level entry
    kind*: DeclKind
    doc*: string
    hasDoc*, hasSee*, hasStatus*: bool   ## prose field presence, for merging
    see*: seq[string]
    status*: string
    line*, col*: int
    forName*: string         ## `@for`: the native a declaration documents
    unverified*: bool        ## declared by `@@unverified` in a sidecar; the source does not show it
    ownUnverified*: bool     ## this entry's own form carries `@@unverified` (not a parent's)
    sourceFile*: string      ## package-relative file of `^loc` when it is not the module's `^source`
    positional*, named*: seq[DocParam]
    rest*, namedRest*: DocParam
    result*: string
    errors*: seq[string]
    generator*, fexpr*: bool
    variants*: seq[DocVariant]
    implements*: seq[string]
    valueType*: string       ## `let`/`var`/`const`: the declared type, or a
                             ## literal initializer's type; "" when only
                             ## running the form would tell. Read by
                             ## `gene doc <file>`; not rendered.

  DocImport* = object
    path*: string
    pkg*: string
    fromModule*: bool
    implImport*: bool
    resolvedPackage*, resolvedModule*: string
    reason*: string
    selections*: seq[tuple[name, local: string]]
    alias*: string
    wildcard*: bool
    reexport*: bool
    line*, col*: int
    resolvedFile*: string    ## the resolved module's absolute path, for
                             ## `gene doc <file>`. Never rendered: the data
                             ## carries no checkout path.

  DocImpl* = object
    protocol*, receiver*: string
    line*, col*: int

  DocDiagnostic* = object
    kind*: string
    message*: string
    source*: string
    line*, col*: int

  DocUnexpanded* = object
    line*: int
    head*: string
    reason*: string

  ModuleDoc* = object
    package*, module*, source*: string
    readable*: bool          ## false when the module's own source did not read
    name*: string            ## the name a top-level `(mod name …)` gives; not rendered
    doc*: string
    imports*: seq[DocImport]
    entries*: seq[DocEntry]
    hidden*: seq[string]
    privates*: seq[DocEntry] ## the private declarations behind `hidden`, with
                             ## their kinds, for `gene doc <file>`; not rendered
    impls*: seq[DocImpl]
    unexpanded*: seq[DocUnexpanded]
    diagnostics*: seq[DocDiagnostic]

# ---------------------------------------------------------------------------
# Rendering. Every value is quoted through the canonical printer, so a string
# that needs escapes is written the way Gene reads it back.
# ---------------------------------------------------------------------------

proc q*(s: string): string =
  if s.len == 0: "nil" else: print(newStr(s))

proc qq*(s: string): string =
  ## A string that is always quoted, even when empty.
  print(newStr(s))

proc qs*(values: openArray[string]): string =
  var parts: seq[string]
  for value in values:
    parts.add qq(value)
  "[" & parts.join(" ") & "]"

proc qsym*(kind: DeclKind): string =
  geneKindName(kind)

proc renderLoc(line, col: int): string =
  "{^line " & $line & " ^col " & $col & "}"

proc renderParam(param: DocParam): string =
  var fields = @["^name " & (if param.name.len > 0: qq(param.name) else: "nil"),
                 "^local " & (if param.local.len > 0: qq(param.local) else: "nil")]
  if param.typ.len > 0:
    fields.add "^type " & qq(param.typ)
  fields.add "^required " & $param.required
  fields.add "^has_default " & $param.hasDefault
  if param.hasDefault:
    fields.add "^default " & qq(param.default)
  "{" & fields.join(" ") & "}"

proc renderParams(params: seq[DocParam]): string =
  if params.len == 0:
    return "[]"
  var parts: seq[string]
  for param in params:
    parts.add renderParam(param)
  "[" & parts.join(" ") & "]"

proc renderEntry(entry: DocEntry): string =
  var lines: seq[string]
  lines.add "  {^id " & qq(entry.id) & " ^name " & qq(entry.name) &
    " ^kind " & qsym(entry.kind)
  if entry.parent.len > 0:
    lines.add "   ^parent " & qq(entry.parent)
  if entry.forName.len > 0:
    lines.add "   ^for " & qq(entry.forName)
  if entry.unverified:
    lines.add "   ^unverified true"
  if entry.sourceFile.len > 0:
    lines.add "   ^source " & qq(entry.sourceFile)
  lines.add "   ^positional " & renderParams(entry.positional)
  lines.add "   ^named " & renderParams(entry.named)
  lines.add "   ^rest " &
    (if entry.rest.name.len > 0 or entry.rest.typ.len > 0:
       renderParam(entry.rest)
     else: "nil")
  lines.add "   ^named_rest " &
    (if entry.namedRest.name.len > 0 or entry.namedRest.typ.len > 0:
       renderParam(entry.namedRest)
     else: "nil")
  lines.add "   ^result " & (if entry.result.len > 0: qq(entry.result) else: "nil")
  lines.add "   ^errors " & qs(entry.errors)
  lines.add "   ^generator " & $entry.generator & " ^fexpr " & $entry.fexpr
  if entry.variants.len > 0:
    var variants: seq[string]
    for variant in entry.variants:
      var fields = @["^name " & qq(variant.name)]
      if variant.fields.len > 0:
        fields.add "^fields " & qs(variant.fields)
      variants.add "{" & fields.join(" ") & "}"
    lines.add "   ^variants [" & variants.join(" ") & "]"
  if entry.implements.len > 0:
    lines.add "   ^implements " & qs(entry.implements)
  lines.add "   ^doc " & q(entry.doc)
  if entry.see.len > 0:
    lines.add "   ^see " & qs(entry.see)
  if entry.status.len > 0:
    lines.add "   ^status " & qq(entry.status)
  lines.add "   ^loc " & renderLoc(entry.line, entry.col) & "}"
  lines.join("\n")

proc renderImport(imported: DocImport): string =
  var fields = @["^path " & qq(imported.path),
                 "^pkg " & q(imported.pkg),
                 "^from " & $imported.fromModule,
                 "^impl " & $imported.implImport]
  if imported.resolvedModule.len > 0:
    fields.add "^resolved {^package " & qq(imported.resolvedPackage) &
      " ^module " & qq(imported.resolvedModule) & "}"
  else:
    fields.add "^resolved nil ^reason " & qq(imported.reason)
  if imported.selections.len > 0:
    var selected: seq[string]
    for (name, local) in imported.selections:
      selected.add "{^name " & qq(name) & " ^local " & qq(local) & "}"
    fields.add "^selections [" & selected.join(" ") & "]"
  if imported.alias.len > 0:
    fields.add "^alias " & qq(imported.alias)
  fields.add "^wildcard " & $imported.wildcard
  fields.add "^export " & $imported.reexport
  fields.add "^loc {" & "^line " & $imported.line & " ^col " & $imported.col & "}"
  "  {" & fields.join(" ") & "}"

proc renderDiagnostic(diagnostic: DocDiagnostic): string =
  ## A diagnostic without a position (an I/O failure has no line) omits
  ## `^loc` rather than claiming line 0, column 0.
  result = "  {^kind " & qq(diagnostic.kind) & " ^message " &
    qq(diagnostic.message) & " ^source " & qq(diagnostic.source)
  if diagnostic.line > 0 or diagnostic.col > 0:
    result.add " ^loc " & renderLoc(diagnostic.line, diagnostic.col)
  result.add "}"

proc renderImpl(impl: DocImpl): string =
  "  {^protocol " & qq(impl.protocol) & " ^receiver " & qq(impl.receiver) &
    " ^loc " & renderLoc(impl.line, impl.col) & "}"

proc renderUnexpanded(item: DocUnexpanded): string =
  var fields = @["^line " & $item.line, "^head " & qq(item.head)]
  if item.reason.len > 0:
    fields.add "^reason " & qq(item.reason)
  "  {" & fields.join(" ") & "}"

proc renderModuleDoc*(doc: ModuleDoc): string =
  ## One `ModuleDoc` as Gene data. Entries are sorted by id and every other
  ## list is in a source- or name-derived order, so the bytes are stable.
  var lines: seq[string]
  var entries = doc.entries
  entries.sort(proc (a, b: DocEntry): int = cmp(a.id, b.id))
  var hidden = doc.hidden
  hidden.sort()
  lines.add "{^format 1"
  lines.add " ^package " & qq(doc.package)
  lines.add " ^module " & qq(doc.module)
  lines.add " ^source " & qq(doc.source)
  lines.add " ^doc " & q(doc.doc)
  if doc.imports.len == 0:
    lines.add " ^imports []"
  else:
    lines.add " ^imports ["
    for imported in doc.imports:
      lines.add renderImport(imported)
    lines.add " ]"
  if entries.len == 0:
    lines.add " ^entries []"
  else:
    lines.add " ^entries ["
    for entry in entries:
      lines.add renderEntry(entry)
    lines.add " ]"
  if hidden.len == 0:
    lines.add " ^hidden []"
  else:
    lines.add " ^hidden " & qs(hidden)
  if doc.impls.len == 0:
    lines.add " ^impls []"
  else:
    lines.add " ^impls ["
    for impl in doc.impls:
      lines.add renderImpl(impl)
    lines.add " ]"
  if doc.unexpanded.len == 0:
    lines.add " ^unexpanded []"
  else:
    lines.add " ^unexpanded ["
    for item in doc.unexpanded:
      lines.add renderUnexpanded(item)
    lines.add " ]"
  if doc.diagnostics.len == 0:
    lines.add " ^diagnostics []"
  else:
    lines.add " ^diagnostics ["
    for diagnostic in doc.diagnostics:
      lines.add renderDiagnostic(diagnostic)
    lines.add " ]"
  lines.add "}"
  lines.join("\n") & "\n"
