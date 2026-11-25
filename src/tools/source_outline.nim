## Token-derived declaration outline for unfinished buffers.
##
## The source index knows exact token spans even when a buffer does not parse;
## the language server knows which forms are declarations
## (`tools/lsp/analysis.nim`). This module applies the LSP's declaration cases
## to indexed tokens, so an editor can show a usable outline while the user is
## mid-edit and tests can compare the two implementations directly.
##
## Only top-level declarations are reported. Nested declarations stay
## navigable through the structure tree, which is derived from the same index
## and therefore always agrees with this outline about spelling and spans.

import ../gene/reader
import ./declaration_heads
import ./source_index
import ./source_positions

type
  OutlineRow* = object
    name*: string            ## The declared name as the LSP reports it.
    head*: string            ## The declaration head (`fn`, `impl`, …).
    kind*: int               ## LSP SymbolKind.
    detail*: string          ## `macro`, `generator`, or empty.
    span*: ByteSpan          ## The whole declaration form.
    nameSpan*: ByteSpan      ## The declared name token.
    closed*: bool            ## False while a delimiter or wrapper is missing.

proc rawText*(doc: SourceDocument, span: ByteSpan): string =
  ## The exact source text a token range covers. The index keeps token
  ## positions rather than values, so this is the only spelling a caller has.
  if span.startByte < 0 or span.startByte >= doc.source.len:
    return ""
  let finish = min(span.endByte, doc.source.len)
  if finish <= span.startByte:
    return ""
  doc.source[span.startByte ..< finish]

proc digitLabel(label: string): bool =
  if label.len == 0:
    return false
  for ch in label:
    if ch notin {'0'..'9'}:
      return false
  true

proc declarationRefs(doc: SourceDocument): seq[SyntaxRef] =
  result = doc.topLevel

proc symbolAt(doc: SourceDocument, row: SourceRow): bool =
  ## Whether the row is exactly one symbol token. The LSP requires a `vkSymbol`
  ## operand for a declaration name; a list, map, string, or number in that
  ## position is not a name.
  row.syntax.startToken >= 0 and row.syntax.startToken < doc.tokens.len and
    doc.tokens[row.syntax.startToken].kind == tkSymbol

proc propTrue(doc: SourceDocument, rows: seq[SourceRow], name: string): bool =
  ## A declaration property set to boolean true, in either spelling:
  ## `^^generator` (flag sugar) or `^generator true`.
  discard doc
  for row in rows:
    if row.label == name and row.summary == "true":
      return true

proc positionalRows(rows: seq[SourceRow]): seq[SourceRow] =
  for row in rows:
    if digitLabel(row.label):
      result.add row

proc operandRow(doc: SourceDocument, operands: seq[SourceRow],
                index: int): tuple[found: bool, row: SourceRow] =
  if index < operands.len and symbolAt(doc, operands[index]):
    result = (found: true, row: operands[index])

proc nameRow(doc: SourceDocument, operands: seq[SourceRow],
             row: var SourceRow): bool =
  let found = doc.operandRow(operands, 0)
  if found.found:
    row = found.row
    return true

proc fromSyntax(doc: SourceDocument, decl: SyntaxRef,
                found: var bool): OutlineRow =
  ## One indexed top-level form, interpreted with the shared declaration
  ## table. The table decides whether the form declares, its kind, and where
  ## its name is; this proc only reads the name token and the detail flag.
  found = false
  if decl.kind != skNode:
    return
  let rows = doc.children(decl)
  var headRow: SourceRow
  var hasHead = false
  for row in rows:
    if row.label == "head":
      headRow = row
      hasHead = true
      break
  if not hasHead or not symbolAt(doc, headRow):
    return
  let head = rawText(doc, headRow.syntax.span)
  let foundHead = declarationHeadInfo(head)
  if not foundHead.found or not foundHead.info.symbol:
    return
  let info = foundHead.info
  let operands = positionalRows(rows)
  var row = OutlineRow(head: head, span: decl.span,
                       nameSpan: headRow.syntax.span, closed: decl.closed)

  template nameFrom(index: int, body: untyped): untyped =
    block:
      var candidate: SourceRow
      if doc.nameRow(operands, candidate):
        row.name = rawText(doc, candidate.syntax.span)
        row.nameSpan = candidate.syntax.span
        body
      else:
        return

  row.kind = lspKind(info.kind)
  case info.name
  of dnkFirst:
    nameFrom(0):
      row.detail = lspDetail(info.kind, propTrue(doc, rows, "generator"))
  of dnkImpl:
    # `(impl P for T body…)` or an inline `(impl P body…)`; a malformed impl is
    # still a declaration, named `impl`, exactly as the LSP reports it.
    row.name = "impl"
    let first = doc.operandRow(operands, 0)
    if first.found:
      row.name = "impl " & rawText(doc, first.row.syntax.span)
      row.nameSpan = first.row.syntax.span
      if operands.len > 2 and symbolAt(doc, operands[1]) and
          rawText(doc, operands[1].syntax.span) == "for":
        let target = doc.operandRow(operands, 2)
        if target.found:
          row.name.add " for " & rawText(doc, target.row.syntax.span)
  of dnkCtor:
    row.name = "ctor"
  of dnkMod:
    nameFrom(0):
      discard
  of dnkNone:
    return
  result = row
  found = true

proc outline*(doc: SourceDocument): seq[OutlineRow] =
  ## Ordered top-level declarations. A form the LSP would not report as a
  ## declaration is skipped here too, which is what keeps a stray call such as
  ## `(+ 1 2)` from appearing as a false positive.
  for decl in doc.declarationRefs:
    var found = false
    let row = doc.fromSyntax(decl, found)
    if found:
      result.add row
