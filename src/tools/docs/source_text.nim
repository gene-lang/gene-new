## Source text for declared expressions, taken from the source itself.
##
## A documentation entry states a parameter's type, a default, a field type,
## and an error row **as written**. The reader gives locations for containers
## (nodes, lists, maps) but not for leaves (symbols, strings, numbers), so a
## declaration walker cannot slice those out of `SourceUnit.locs`. This module
## scans the exact text of an already-read form instead: the parameter vector
## occupies one known source range, and the items inside it can be split and
## sliced without re-reading or evaluating anything.
##
## The scanner understands the reader's lexical surface — line and block
## comments, datum comments (`#_`), strings, interpolated strings, char
## literals, regex, byte literals, and `#@` wrappers — because a naive
## delimiter count would slice a `)` inside a string.

import std/strutils
import ../source_positions

proc skipTrivia*(src: string, start: int): int
proc datumEnd*(src: string, start: int): int

proc skipString(src: string, start: int): int =
  ## `start` is at the opening quote; returns the offset just past the close.
  var i = start
  if src.continuesWith("\"\"\"", i):
    i += 3
    while i < src.len:
      if src.continuesWith("\"\"\"", i):
        return i + 3
      inc i
    return src.len
  inc i
  while i < src.len:
    case src[i]
    of '\\': i += 2
    of '"': return i + 1
    else: inc i
  src.len

proc skipCharLiteral(src: string, start: int): int =
  ## `start` is at a `'`. Gene's `'` introduces only a char literal.
  var i = start + 1
  while i < src.len and src[i] != '\n':
    if src[i] == '\\':
      i += 2
      continue
    if src[i] == '\'':
      return i + 1
    inc i
  src.len

proc skipBlockComment(src: string, start: int): int =
  var depth = 1
  var i = start + 2
  while i < src.len and depth > 0:
    if src.continuesWith("#<", i):
      inc depth
      i += 2
    elif src.continuesWith(">#", i):
      dec depth
      i += 2
    else:
      inc i
  i

proc skipLineComment(src: string, start: int): int =
  var i = start
  while i < src.len and src[i] != '\n':
    inc i
  i

proc skipTrivia(src: string, start: int): int =
  ## Skip whitespace, commas, and comments, including `#_ datum` which the
  ## reader treats as spacing.
  var i = start
  while i < src.len:
    case src[i]
    of ' ', '\t', '\r', '\n', ',':
      inc i
    of '#':
      if i + 1 < src.len and src[i + 1] == '_':
        i = skipTrivia(src, datumEnd(src, skipTrivia(src, i + 2)))
      elif i + 1 < src.len and src[i + 1] == '<':
        i = skipBlockComment(src, i)
      elif i + 1 < src.len and src[i + 1] in {'"', 'B', '(', '[', '{', '@'}:
        # A regex, bytes literal, reader-prefixed container, or wrapper is an
        # atom, not a comment.
        return i
      else:
        i = skipLineComment(src, i)
    else:
      return i

proc atomEnd(src: string, start: int): int =
  ## An atom ends at whitespace or a delimiter. `:` and `=` are included
  ## because in a parameter vector they are the separators a caller writes
  ## with spaces around them; a selector alias such as `a:b` never appears
  ## inside a signature.
  var i = start
  while i < src.len and src[i] notin {' ', '\t', '\r', '\n', ',', ';',
                                      '(', ')', '[', ']', '{', '}', ':',
                                      '='}:
    inc i
  if i == start:
    inc i
  i

proc delimitedEnd(src: string, start: int): int =
  ## Offset just past the delimiter matching the opener at `start`. A stack of
  ## expected closers keeps nested forms of different kinds straight.
  var closers: seq[char]
  var i = start
  while i < src.len:
    case src[i]
    of '(', '[', '{':
      if closers.len == 0:
        if i != start:
          return i
        if src[i] == '(': closers.add ')'
        elif src[i] == '[': closers.add ']'
        else: closers.add '}'
      else:
        closers.add(if src[i] == '(': ')'
                    elif src[i] == '[': ']'
                    else: '}')
      inc i
    of ')', ']', '}':
      if closers.len > 0 and src[i] == closers[^1]:
        closers.setLen(closers.len - 1)
        inc i
        if closers.len == 0:
          return i
      else:
        inc i
    of '"':
      i = skipString(src, i)
    of '\'':
      i = skipCharLiteral(src, i)
    of '#':
      if i + 1 < src.len and src[i + 1] == '<':
        i = skipBlockComment(src, i)
      elif i + 1 < src.len and src[i + 1] == '"':
        i = skipString(src, i + 1)
      elif i + 1 < src.len and src[i + 1] == '_':
        i = skipTrivia(src, i)
      elif i + 1 < src.len and src[i + 1] in {'(', '[', '{', '@'}:
        i = datumEnd(src, i)
      else:
        i = skipLineComment(src, i)
    else:
      inc i
  src.len

proc datumEnd(src: string, start: int): int =
  ## Offset just past the datum that starts at `start` (the first non-space
  ## byte of the datum).
  if start >= src.len:
    return src.len
  case src[start]
  of '(', '[', '{':
    return delimitedEnd(src, start)
  of '"':
    return skipString(src, start)
  of '\'':
    let stop = skipCharLiteral(src, start)
    if stop > start + 1: return stop
    return atomEnd(src, start)
  of '#':
    if start + 1 < src.len:
      case src[start + 1]
      of '<': return skipBlockComment(src, start)
      of '"': return skipString(src, start + 1)
      of '(', '[', '{': return delimitedEnd(src, start + 1)
      of '@':
        # `#@ head argument` is one form whose operands follow the marker.
        var i = skipTrivia(src, start + 2)
        i = datumEnd(src, i)
        i = skipTrivia(src, i)
        return datumEnd(src, i)
      of '_':
        return skipTrivia(src, start)
      else:
        return atomEnd(src, start)
    return atomEnd(src, start)
  of '$':
    if start + 1 < src.len and src[start + 1] == '"':
      return skipString(src, start + 2)
    return atomEnd(src, start)
  else:
    return atomEnd(src, start)

proc scanItem*(src: string, start: int): tuple[stop: int, punctuation: bool] =
  ## One item inside a form: either a datum or a single punctuation token
  ## (`:`, `=`, `^`, `^^`, `^!`, `@`, `@@`, `@!`, `;`).
  var i = skipTrivia(src, start)
  if i >= src.len:
    return (stop: i, punctuation: false)
  if src[i] in {':', '=', '^', '@', ';'}:
    if src[i] in {'^', '@'} and i + 1 < src.len and
        src[i + 1] in {'^', '!', '@'}:
      return (stop: i + 2, punctuation: true)
    return (stop: i + 1, punctuation: true)
  (stop: datumEnd(src, i), punctuation: false)

proc splitItems*(src: string, openOffset: int): seq[ByteSpan] =
  ## The top-level items of the delimited form whose opening byte is at
  ## `openOffset`, each as an exact source span. Punctuation items are
  ## included as tiny spans so callers can read `:`, `=`, `^`, and `@`.
  let closeOffset = delimitedEnd(src, openOffset)
  var i = openOffset + 1
  let limit = if closeOffset > openOffset: closeOffset - 1 else: closeOffset
  while i < limit:
    i = skipTrivia(src, i)
    if i >= limit:
      break
    let item = scanItem(src, i)
    if item.stop <= i:
      break
    result.add ByteSpan(startByte: i, endByte: min(item.stop, limit))
    i = item.stop

proc spanText*(src: string, span: ByteSpan): string =
  ## The exact source text a span covers, stripped of surrounding whitespace.
  if span.startByte < 0 or span.startByte >= src.len or
      span.endByte <= span.startByte:
    return ""
  src[span.startByte ..< min(span.endByte, src.len)].strip()

proc spanOf*(src: string, openOffset: int): ByteSpan =
  ## The span of the whole delimited form opening at `openOffset`.
  ByteSpan(startByte: openOffset, endByte: delimitedEnd(src, openOffset))
