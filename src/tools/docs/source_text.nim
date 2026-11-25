## Source text for declared expressions, taken from the source itself.
##
## A documentation entry states a parameter's type, a default, a field type,
## and an error row **as written**. The reader gives locations for containers
## (nodes, lists, maps) but not for leaves (symbols, strings, numbers), so a
## declaration walker cannot slice those out of `SourceUnit.locs`.
##
## This module slices them from the reader's own token stream
## (`lexAllSpanned`): each datum's bytes are the span between its first and
## last token. Lexing stays in the reader, so a new literal or comment form
## cannot make the builder disagree with the language about where a datum
## starts and ends.

import std/[strutils, tables]
import ../../gene/reader
import ../source_positions

type
  SourceText* = object
    src*: string
    tokens*: seq[SpannedToken]
    starts*: Table[int, int]   ## first byte of a datum -> token index

proc isOpener(kind: TokenKind): bool =
  kind in {tkLParen, tkLBracket, tkLBrace, tkHashLParen, tkHashLBracket,
           tkHashLBrace}

proc isCloser(kind: TokenKind): bool =
  kind in {tkRParen, tkRBracket, tkRBrace}

proc isPrefix(kind: TokenKind): bool =
  kind in {tkPercent, tkBacktick, tkDollar, tkRef, tkDeref}

proc startsDatum(kind: TokenKind): bool =
  not isCloser(kind) and kind notin {tkComma, tkEof}

proc tokenStart(st: SourceText, index: int): int =
  let token = st.tokens[index]
  # `$name` is one datum whose token starts after the sigil.
  if token.kind == tkGeneMember and token.startByte > 0 and
      st.src[token.startByte - 1] == '$':
    token.startByte - 1
  else:
    token.startByte

proc initSourceText*(src: string): SourceText =
  result.src = src
  result.tokens = lexAllSpanned(src)
  for index in 0 ..< result.tokens.len:
    result.starts[result.tokenStart(index)] = index

proc datumSpan(st: SourceText, index: int):
    tuple[span: ByteSpan, next: int] =
  ## The bytes of the datum that starts at token `index`, and the token after
  ## it. Prefixes that belong to a datum (`%`, `` ` ``, `$`, `#Ref`, `#Deref`,
  ## `#@`) extend the span over their operand.
  if index >= st.tokens.len:
    return (ByteSpan(startByte: st.src.len, endByte: st.src.len), index)
  let token = st.tokens[index]
  if isOpener(token.kind):
    var depth = 0
    var i = index
    while i < st.tokens.len:
      if isOpener(st.tokens[i].kind):
        inc depth
      elif isCloser(st.tokens[i].kind):
        dec depth
        if depth == 0:
          return (ByteSpan(startByte: st.tokenStart(index),
                           endByte: st.tokens[i].endByte), i + 1)
      inc i
    return (ByteSpan(startByte: st.tokenStart(index),
                     endByte: st.src.len), st.tokens.len)
  if token.kind == tkWrap:
    # `#@ head argument` is one form whose two operands follow the marker.
    var next = index + 1
    var stop = token.endByte
    for _ in 0 .. 1:
      let part = st.datumSpan(next)
      stop = part.span.endByte
      next = part.next
    return (ByteSpan(startByte: st.tokenStart(index), endByte: stop), next)
  if isPrefix(token.kind):
    let part = st.datumSpan(index + 1)
    return (ByteSpan(startByte: st.tokenStart(index),
                     endByte: part.span.endByte), part.next)
  (ByteSpan(startByte: st.tokenStart(index), endByte: token.endByte), index + 1)

proc splitItems*(st: SourceText, openOffset: int): seq[ByteSpan] =
  ## The top-level items of the delimited form whose opening byte is at
  ## `openOffset`, each as an exact source span. Punctuation items (`:`, `=`,
  ## `^`, `@`) are returned as their own spans.
  let openIndex = st.starts.getOrDefault(openOffset, -1)
  if openIndex < 0 or not isOpener(st.tokens[openIndex].kind):
    return
  let opened = st.datumSpan(openIndex)
  let limit = opened.next - 1
  var i = openIndex + 1
  while i < limit:
    case st.tokens[i].kind
    of tkComma:
      inc i
    of tkUnderscore:
      # `#_ datum` is spacing: skip the marker and its datum.
      i = st.datumSpan(i + 1).next
    else:
      let item = st.datumSpan(i)
      if item.next <= i:
        break
      result.add item.span
      i = item.next

proc spanOf*(st: SourceText, openOffset: int): ByteSpan =
  ## The whole delimited form opening at `openOffset`.
  let openIndex = st.starts.getOrDefault(openOffset, -1)
  if openIndex < 0:
    return ByteSpan(startByte: -1, endByte: -1)
  st.datumSpan(openIndex).span

proc spanText*(src: string, span: ByteSpan): string =
  ## The exact source text a span covers, stripped of surrounding whitespace.
  if span.startByte < 0 or span.startByte >= src.len or
      span.endByte <= span.startByte:
    return ""
  src[span.startByte ..< min(span.endByte, src.len)].strip()

proc afterProperty(st: SourceText, index: int): int =
  ## `^key value`, `@key value`, and the flag spellings (`^^`, `^!`, `@@`,
  ## `@!`) may sit between a parameter vector and its return annotation.
  let kind = st.tokens[index].kind
  var i = index + 1
  if i < st.tokens.len:
    inc i # the key
  if kind in {tkCaret, tkAt} and i < st.tokens.len:
    i = st.datumSpan(i).next
  i

proc typeAfterColon*(st: SourceText, offset: int): ByteSpan =
  ## The source span of the type after a `:` that follows `offset`, skipping
  ## the form's properties and meta (the reader keeps them out of the body, so
  ## they may sit between the parameters and the return annotation), or a span
  ## with `startByte == -1` when there is no return annotation.
  var i = 0
  while i < st.tokens.len and st.tokens[i].startByte < offset:
    inc i
  while i < st.tokens.len:
    case st.tokens[i].kind
    of tkColon:
      inc i
      while i < st.tokens.len and st.tokens[i].kind == tkComma:
        inc i
      if i >= st.tokens.len or not startsDatum(st.tokens[i].kind):
        return ByteSpan(startByte: -1, endByte: -1)
      return st.datumSpan(i).span
    of tkCaret, tkCaretCaret, tkCaretBang, tkAt, tkAtAt, tkAtBang:
      i = st.afterProperty(i)
    else:
      break
  ByteSpan(startByte: -1, endByte: -1)
