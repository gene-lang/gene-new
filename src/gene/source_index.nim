## Reader-backed structural source index.
##
## The index stores token ranges rather than runtime Values. Direct children
## are derived from those ranges on demand, preserving source order, duplicate
## properties, comments outside forms, and exact byte locations.

import std/[os, strutils, tables, unicode]
import ./[reader, source_positions, types]

type
  SyntaxKind* = enum
    skAtom, skNode, skList, skPropMap, skGeneralMap,
    skQuasiquote, skUnquote, skInterpolation, skComment,
    skSequence, skError

  SourcePathSegmentKind* = enum
    spsProperty, spsIndex

  SourcePathSegment* = object
    case kind*: SourcePathSegmentKind
    of spsProperty:
      name*: string
    of spsIndex:
      index*: int64

  SyntaxRef* = object
    kind*: SyntaxKind
    span*: ByteSpan
    startToken*, endToken*: int  ## Half-open token range.
    immutable*: bool
    closed*: bool                ## Containers have their source closer.

  SourceRow* = object
    syntax*: SyntaxRef
    label*: string
    summary*: string
    path*: seq[SourcePathSegment] ## Segments relative to the parent row.
    labelSpan: ByteSpan           ## Deferred label text for map keys.

  SourceDiagnostic* = object
    message*: string
    line*, col*: int

  SourceDocument* = ref object
    path*: string
    generation*: uint64
    source*: string
    lineStarts*: seq[int]
    tokens*: seq[SpannedToken]
    root*: SyntaxRef
    topLevel*: seq[SyntaxRef]
    diagnostics*: seq[SourceDiagnostic]
    childCache: Table[tuple[kind: SyntaxKind, startToken, endToken: int],
                      seq[SourceRow]]

var nextGeneration = 1'u64

proc propertySegment*(name: string): SourcePathSegment =
  SourcePathSegment(kind: spsProperty, name: name)

proc indexSegment*(index: int64): SourcePathSegment =
  SourcePathSegment(kind: spsIndex, index: index)

proc `$`*(segment: SourcePathSegment): string =
  case segment.kind
  of spsProperty: segment.name
  of spsIndex: $segment.index

proc pathText*(path: openArray[SourcePathSegment]): string =
  if path.len == 0:
    return "/"
  var parts = newSeq[string](path.len)
  for i, segment in path:
    parts[i] = $segment
  parts.join("/")

proc significant(tokens: openArray[SpannedToken], at: int): int =
  result = at
  while result < tokens.len and
      tokens[result].kind in {tkLineComment, tkBlockComment}:
    inc result

proc syntaxKind(token: SpannedToken): SyntaxKind =
  case token.kind
  of tkLParen, tkHashLParen: skNode
  of tkLBracket, tkHashLBracket: skList
  of tkLBrace, tkHashLBrace: skPropMap
  of tkHashMapStart: skGeneralMap
  of tkBacktick: skQuasiquote
  of tkPercent: skUnquote
  of tkLineComment, tkBlockComment, tkUnderscore: skComment
  else: skAtom

proc closingEnd(tokens: openArray[SpannedToken], start: int):
    tuple[endToken: int, closed: bool] =
  let opener = tokens[start].kind
  var stack: seq[TokenKind] = @[opener]
  var i = start + 1
  while i < tokens.len:
    let kind = tokens[i].kind
    if kind in {tkLParen, tkLBracket, tkLBrace, tkHashMapStart,
                tkHashLParen, tkHashLBracket, tkHashLBrace}:
      stack.add kind
    elif kind in {tkRParen, tkRBracket, tkRBrace} and stack.len > 0:
      let top = stack[^1]
      let closes =
        (kind == tkRParen and top in {tkLParen, tkHashLParen}) or
        (kind == tkRBracket and top in {tkLBracket, tkHashLBracket}) or
        (kind == tkRBrace and top in {tkLBrace, tkHashLBrace})
      if closes:
        stack.setLen(stack.len - 1)
        if stack.len == 0:
          return (endToken: i + 1, closed: true)
      elif kind == tkRBrace and top == tkHashMapStart and
          i + 1 < tokens.len and tokens[i + 1].kind == tkRBrace:
        stack.setLen(stack.len - 1)
        if stack.len == 0:
          return (endToken: i + 2, closed: true)
        inc i
    inc i
  (endToken: tokens.len, closed: false)

proc formRef(doc: SourceDocument, start: int): SyntaxRef

proc formEnd(doc: SourceDocument, start: int): int =
  let at = significant(doc.tokens, start)
  if at >= doc.tokens.len:
    return at
  let token = doc.tokens[at]
  case token.kind
  of tkLParen, tkLBracket, tkLBrace, tkHashMapStart,
     tkHashLParen, tkHashLBracket, tkHashLBrace:
    closingEnd(doc.tokens, at).endToken
  of tkBacktick, tkPercent, tkUnderscore:
    formEnd(doc, at + 1)
  of tkDollar:
    let following = significant(doc.tokens, at + 1)
    if following < doc.tokens.len and doc.tokens[following].kind == tkString and
        doc.tokens[following].startByte == token.endByte:
      following + 1
    else:
      at + 1
  else:
    at + 1

proc formRef(doc: SourceDocument, start: int): SyntaxRef =
  let at = significant(doc.tokens, start)
  if at >= doc.tokens.len:
    return SyntaxRef(kind: skError,
                     span: ByteSpan(startByte: doc.source.len,
                                    endByte: doc.source.len),
                     startToken: at, endToken: at)
  var finish: int
  var closed = true
  if doc.tokens[at].kind in {tkLParen, tkLBracket, tkLBrace, tkHashMapStart,
                             tkHashLParen, tkHashLBracket, tkHashLBrace}:
    let ending = closingEnd(doc.tokens, at)
    finish = ending.endToken
    closed = ending.closed
  else:
    finish = formEnd(doc, at)
  finish = min(finish, doc.tokens.len)
  var endByte = doc.tokens[at].endByte
  if finish > at:
    endByte = doc.tokens[finish - 1].endByte
  result = SyntaxRef(kind: syntaxKind(doc.tokens[at]),
                     span: ByteSpan(startByte: doc.tokens[at].startByte,
                                    endByte: endByte),
                     startToken: at, endToken: finish,
                     closed: closed,
                     immutable: doc.tokens[at].kind in
                       {tkHashLParen, tkHashLBracket, tkHashLBrace})
  if doc.tokens[at].kind == tkDollar and finish == at + 2:
    result.kind = skInterpolation

proc normalizedSummary(doc: SourceDocument, span: ByteSpan,
                       maxBytes = 72): string =
  if span.startByte < 0 or span.startByte >= doc.source.len or
      span.endByte <= span.startByte:
    return ""
  let finish = min(span.endByte, doc.source.len)
  var raw = doc.source[span.startByte ..< finish]
  raw = strutils.splitWhitespace(raw).join(" ")
  if raw.len <= maxBytes:
    return raw
  let budget = max(0, maxBytes - "…".len)
  for rune in raw.runes:
    let encoded = rune.toUTF8
    if result.len + encoded.len > budget:
      break
    result.add encoded
  result.add "…"

proc row(doc: SourceDocument, syntax: SyntaxRef, label: string,
         path: seq[SourcePathSegment]): SourceRow =
  discard doc
  SourceRow(syntax: syntax, label: label, path: path)

proc materialize(doc: SourceDocument, cached: SourceRow): SourceRow =
  result = cached
  if result.label.len == 0 and result.labelSpan.endByte > result.labelSpan.startByte:
    result.label = normalizedSummary(doc, result.labelSpan, 28)
  if result.summary.len == 0:
    result.summary = normalizedSummary(doc, result.syntax.span)

proc interiorBounds(doc: SourceDocument, syntax: SyntaxRef):
    tuple[first, last: int] =
  var first = syntax.startToken + 1
  var last = syntax.endToken
  if syntax.closed:
    last = syntax.endToken - 1
    if syntax.kind == skGeneralMap:
      last = syntax.endToken - 2
  (first: max(first, 0), last: max(first, last))

proc scanChildren(doc: SourceDocument, syntax: SyntaxRef): seq[SourceRow] =
  if syntax.kind == skSequence:
    for i, item in doc.topLevel:
      result.add doc.row(item, $i, @[indexSegment(i.int64)])
    return

  if syntax.kind in {skQuasiquote, skUnquote}:
    let innerAt = significant(doc.tokens, syntax.startToken + 1)
    if innerAt < syntax.endToken:
      result.add doc.row(formRef(doc, innerAt), "value", @[])
    return

  if syntax.kind notin {skNode, skList, skPropMap, skGeneralMap}:
    return

  let bounds = interiorBounds(doc, syntax)
  var at = bounds.first
  var ordinal = 0
  var isHead = syntax.kind == skNode
  while at < bounds.last:
    if doc.tokens[at].kind in {tkLineComment, tkBlockComment}:
      let comment = SyntaxRef(kind: skComment,
        span: ByteSpan(startByte: doc.tokens[at].startByte,
                       endByte: doc.tokens[at].endByte),
        startToken: at, endToken: at + 1)
      result.add doc.row(comment, "#", @[])
      inc at
      continue
    if doc.tokens[at].kind in {tkComma, tkSemi}:
      inc at
      continue
    if doc.tokens[at].kind == tkUnderscore:
      at = formEnd(doc, at)
      continue

    if syntax.kind in {skNode, skPropMap} and
        doc.tokens[at].kind in {tkCaret, tkCaretCaret, tkAt, tkAtAt}:
      let marker = doc.tokens[at].kind
      let keyAt = significant(doc.tokens, at + 1)
      if keyAt >= bounds.last or doc.tokens[keyAt].kind != tkSymbol:
        inc at
        continue
      let name = doc.tokens[keyAt].lexeme
      let flag = marker in {tkCaretCaret, tkAtAt}
      var valueRef: SyntaxRef
      if flag:
        valueRef = SyntaxRef(kind: skAtom,
          span: ByteSpan(startByte: doc.tokens[at].startByte,
                         endByte: doc.tokens[keyAt].endByte),
          startToken: at, endToken: keyAt + 1)
        at = keyAt + 1
      else:
        let valueAt = significant(doc.tokens, keyAt + 1)
        if valueAt >= bounds.last:
          valueRef = SyntaxRef(kind: skError,
            span: ByteSpan(startByte: doc.tokens[at].startByte,
                           endByte: doc.tokens[keyAt].endByte),
            startToken: at, endToken: keyAt + 1, closed: true)
          at = keyAt + 1
          let label = if marker in {tkAt, tkAtAt}: "@" & name else: name
          let segments =
            if marker in {tkAt, tkAtAt}:
              @[propertySegment("meta"), propertySegment(name)]
            else:
              @[propertySegment(name)]
          var item = doc.row(valueRef, label, segments)
          item.summary = "missing value"
          result.add item
          continue
        valueRef = formRef(doc, valueAt)
        at = valueRef.endToken
      let label = if marker in {tkAt, tkAtAt}: "@" & name else: name
      let segments =
        if marker in {tkAt, tkAtAt}:
          @[propertySegment("meta"), propertySegment(name)]
        else:
          @[propertySegment(name)]
      var item = doc.row(valueRef, label, segments)
      if flag:
        item.summary = "true"
      result.add item
      continue

    if syntax.kind == skGeneralMap:
      let keyRef = formRef(doc, at)
      var valueAt = significant(doc.tokens, keyRef.endToken)
      var colonAt = -1
      if valueAt < bounds.last and doc.tokens[valueAt].kind == tkColon:
        colonAt = valueAt
        valueAt = significant(doc.tokens, valueAt + 1)
      if valueAt >= bounds.last:
        var missing = doc.row(SyntaxRef(kind: skError, span: keyRef.span,
          startToken: keyRef.startToken, endToken: keyRef.endToken,
          closed: true), "", @[])
        missing.labelSpan = keyRef.span
        missing.summary = "missing value"
        result.add missing
        at = if colonAt >= 0: colonAt + 1 else: keyRef.endToken
        continue
      let valueRef = formRef(doc, valueAt)
      var segments: seq[SourcePathSegment]
      if doc.tokens[keyRef.startToken].kind == tkInt:
        try: segments = @[indexSegment(parseBiggestInt(doc.tokens[keyRef.startToken].lexeme))]
        except ValueError: discard
      elif doc.tokens[keyRef.startToken].kind in {tkSymbol, tkString}:
        segments = @[propertySegment(doc.tokens[keyRef.startToken].lexeme)]
      var mapped = doc.row(valueRef, "", segments)
      mapped.labelSpan = keyRef.span
      result.add mapped
      at = valueRef.endToken
      inc ordinal
      continue

    let item = formRef(doc, at)
    if item.endToken <= at:
      inc at
      continue
    if syntax.kind == skNode and isHead:
      result.add doc.row(item, "head", @[propertySegment("head")])
      isHead = false
    else:
      result.add doc.row(item, $ordinal, @[indexSegment(ordinal.int64)])
      inc ordinal
    at = item.endToken

proc cacheKey(syntax: SyntaxRef):
    tuple[kind: SyntaxKind, startToken, endToken: int] =
  (kind: syntax.kind, startToken: syntax.startToken,
   endToken: syntax.endToken)

proc cachedChildren(doc: SourceDocument, syntax: SyntaxRef): lent seq[SourceRow] =
  let key = cacheKey(syntax)
  if not doc.childCache.hasKey(key):
    doc.childCache[key] = doc.scanChildren(syntax)
  doc.childCache[key]

proc children*(doc: SourceDocument, syntax: SyntaxRef): seq[SourceRow] =
  for item in doc.cachedChildren(syntax):
    result.add doc.materialize(item)

proc childCount*(doc: SourceDocument, syntax: SyntaxRef): int =
  doc.cachedChildren(syntax).len

proc childPage*(doc: SourceDocument, syntax: SyntaxRef,
                start, count: int): seq[SourceRow] =
  let all {.cursor.} = doc.cachedChildren(syntax)
  let first = min(max(start, 0), all.len)
  let finish = min(first + max(count, 0), all.len)
  for index in first ..< finish:
    result.add doc.materialize(all[index])

proc delimiterDiagnostic(tokens: openArray[SpannedToken]): SourceDiagnostic =
  var stack: seq[tuple[kind: TokenKind, at: int]]
  var i = 0
  while i < tokens.len:
    let kind = tokens[i].kind
    if kind in {tkLParen, tkLBracket, tkLBrace, tkHashMapStart,
                tkHashLParen, tkHashLBracket, tkHashLBrace}:
      stack.add (kind: kind, at: i)
    elif kind in {tkRParen, tkRBracket, tkRBrace}:
      if stack.len == 0:
        return SourceDiagnostic(message: "unexpected closing delimiter '" &
          tokens[i].lexeme & "'", line: tokens[i].line, col: tokens[i].col)
      let top = stack[^1]
      let closes =
        (kind == tkRParen and top.kind in {tkLParen, tkHashLParen}) or
        (kind == tkRBracket and top.kind in {tkLBracket, tkHashLBracket}) or
        (kind == tkRBrace and top.kind in {tkLBrace, tkHashLBrace})
      if closes:
        stack.setLen(stack.len - 1)
      elif kind == tkRBrace and top.kind == tkHashMapStart and
          i + 1 < tokens.len and tokens[i + 1].kind == tkRBrace:
        stack.setLen(stack.len - 1)
        inc i
      else:
        return SourceDiagnostic(message: "mismatched closing delimiter '" &
          tokens[i].lexeme & "'", line: tokens[i].line, col: tokens[i].col)
    inc i
  if stack.len > 0:
    let token = tokens[stack[^1].at]
    return SourceDiagnostic(message: "unexpected EOF: unclosed '" &
      token.lexeme & "'", line: token.line, col: token.col)

proc indexSource*(source: string, path = "<source>"): SourceDocument =
  result = SourceDocument(path: path, source: source,
                          generation: nextGeneration,
                          lineStarts: lineStarts(source),
                          childCache: initTable[
                            tuple[kind: SyntaxKind, startToken, endToken: int],
                            seq[SourceRow]]())
  inc nextGeneration
  try:
    result.tokens = lexAllSpanned(source, includeEof = false, sourceName = path,
                                  includeTrivia = true)
    let delimiterError = delimiterDiagnostic(result.tokens)
    if delimiterError.message.len > 0:
      result.diagnostics.add delimiterError
    var at = 0
    while at < result.tokens.len:
      if result.tokens[at].kind in {tkLineComment, tkBlockComment}:
        inc at
        continue
      let item = formRef(result, at)
      if item.endToken <= at:
        inc at
      else:
        if item.kind != skComment:
          result.topLevel.add item
        at = item.endToken
  except ReadError as error:
    result.diagnostics.add SourceDiagnostic(message: error.msg,
      line: error.line, col: error.col)

  if result.topLevel.len == 1:
    result.root = result.topLevel[0]
  else:
    result.root = SyntaxRef(kind: skSequence,
      span: ByteSpan(startByte: 0, endByte: source.len),
      startToken: 0, endToken: result.tokens.len, closed: true)

proc loadSourceDocument*(path: string): SourceDocument =
  indexSource(readFile(path), normalizedPath(absolutePath(path)))

proc parseSourcePath*(text: string): seq[SourcePathSegment] =
  if text.len == 0 or text == "/":
    return @[]
  let forms = readAll(text, "<view-path>")
  if forms.len != 1:
    raise newException(ValueError, "view path must contain exactly one Gene path")
  let value = forms[0]
  var parts: seq[Value]
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.head.symVal in ["path", "select"]:
    parts = value.body
  elif value.kind in {vkSymbol, vkInt}:
    parts = @[value]
  else:
    raise newException(ValueError, "view path must use static Gene path segments")
  for part in parts:
    case part.kind
    of vkSymbol: result.add propertySegment(part.symVal)
    of vkInt:
      if not part.intFitsInt64:
        raise newException(ValueError, "view path index must fit in int64")
      result.add indexSegment(part.intVal)
    else:
      raise newException(ValueError,
        "view path segments must be symbols or integers")

proc lineCol*(doc: SourceDocument, syntax: SyntaxRef): tuple[line, col: int] =
  offsetLineCol(doc.source, doc.lineStarts, syntax.span.startByte)

proc isContainer*(syntax: SyntaxRef): bool =
  syntax.kind in {skNode, skList, skPropMap, skGeneralMap, skSequence,
                  skQuasiquote, skUnquote}
