## Lexer & core parser for Gene (design §2.2)
import std/[base64, strutils, unicode, tables, parseutils]
import ./types

type
  TokenKind* = enum
    tkEof,
    tkLParen, tkRParen,      # ( )
    tkLBracket, tkRBracket,  # [ ]
    tkLBrace, tkRBrace,      # { }
    tkHashMapStart,             # {{
    tkHashLParen,            # #(
    tkHashLBracket,          # #[
    tkHashLBrace,            # #{
    tkCaret, tkCaretCaret,   # ^ ^^
    tkAt, tkAtAt,            # @ @@
    tkTilde,                 # ~
    tkDotDotDot,             # ...
    tkString, tkBytes, tkRegex, tkInt, tkFloat, tkDate, tkTime, tkDateTime,
    tkSymbol, tkChar,
    tkComma, tkColon, tkEqual, tkSemi, tkSlash, tkPercent,
    tkBacktick, tkDollar, tkUnderscore

  Token* = object
    kind*: TokenKind
    lexeme*: string
    flags*: string
    line*, col*: int

  ReadOptions* = object
    maxDepth*: int              # 0 means unlimited

  Reader* = object
    src*: string
    sourceName*: string
    options*: ReadOptions
    pos*: int
    line*, col*: int
    tokens: seq[Token]
    tokIdx: int
    parseDepth: int
    locs: Table[uint64, SourceLoc]

  ReadError* = object of CatchableError
    sourceName*: string
    line*, col*: int
  ReadIncompleteError* = object of ReadError

  SourceUnit* = object
    sourceName*: string
    forms*: seq[Value]
    formLocs*: seq[SourceLoc]
    locs*: Table[uint64, SourceLoc]

proc sourceLoc(tok: Token, sourceName: string): SourceLoc =
  SourceLoc(sourceName: sourceName, line: tok.line, col: tok.col)

proc raiseReadErrorAt(sourceName: string, line, col: int,
                      message: string) {.noReturn.} =
  var e: ref ReadError
  new(e)
  e.msg = message
  e.sourceName = sourceName
  e.line = line
  e.col = col
  raise e

proc raiseReadIncompleteAt(sourceName: string, line, col: int,
                           message: string) {.noReturn.} =
  var e: ref ReadIncompleteError
  new(e)
  e.msg = message
  e.sourceName = sourceName
  e.line = line
  e.col = col
  raise e

proc raiseReadError(r: Reader, message: string) {.noReturn.} =
  raiseReadErrorAt(r.sourceName, r.line, r.col, message)

proc raiseReadErrorAt(r: Reader, tok: Token, message: string) {.noReturn.} =
  raiseReadErrorAt(r.sourceName, tok.line, tok.col, message)

proc raiseReadIncomplete(r: Reader, message: string) {.noReturn.} =
  raiseReadIncompleteAt(r.sourceName, r.line, r.col, message)

proc isIntLexeme(lexeme: string): bool =
  if lexeme.len == 0:
    return false
  var i = 0
  if lexeme[0] == '-':
    if lexeme.len == 1:
      return false
    i = 1
  while i < lexeme.len:
    if lexeme[i] < '0' or lexeme[i] > '9':
      return false
    inc i
  true

proc initReader(src: string, sourceName = "",
                options: ReadOptions = ReadOptions()): Reader =
  Reader(src: src, sourceName: sourceName, options: options, line: 1, col: 1,
         tokens: newSeqOfCap[Token](min(src.len + 1, 4096)),
         locs: initTable[uint64, SourceLoc]())

proc isSymbolChar(c: char): bool =
  c notin {'(', ')', '[', ']', '{', '}', ' ', '\t', '\n', '\r', ',', ';', '\"', '\'', '`', '#'}

proc isHexDigit(c: char): bool =
  c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc isBase64Char(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}

proc isBytesPrefix(c: char): bool =
  c in {'!', 'x', '#'}

proc isBytesDigit(prefix, c: char): bool =
  case prefix
  of '!': c in {'0', '1'}
  of 'x': isHexDigit(c)
  of '#': isBase64Char(c)
  else: false

proc isBytesLexeme(lexeme: string): bool =
  if lexeme.len <= 2 or lexeme[0] != '0':
    return false
  case lexeme[1]
  of '!':
    if lexeme.len == 2: return false
    for i in 2 ..< lexeme.len:
      if lexeme[i] notin {'0', '1'}:
        return false
    true
  of 'x':
    if lexeme.len == 2: return false
    for i in 2 ..< lexeme.len:
      if not isHexDigit(lexeme[i]):
        return false
    true
  of '#':
    if lexeme.len == 2: return false
    for i in 2 ..< lexeme.len:
      if not isBase64Char(lexeme[i]):
        return false
    true
  else:
    false

proc isDigit(c: char): bool {.inline.} =
  c in {'0'..'9'}

proc canEndTemporal(r: var Reader): bool =
  r.pos >= r.src.len or not isSymbolChar(r.src[r.pos])

proc hexValue(c: char): int
proc nextChar(r: var Reader): char
proc advance(r: var Reader)
proc advanceBytes(r: var Reader, count: int)

proc tryScanBytesLexeme(r: var Reader, lexeme: var string): bool =
  if r.pos + 2 >= r.src.len or r.src[r.pos] != '0' or
      not isBytesPrefix(r.src[r.pos + 1]) or
      not isBytesDigit(r.src[r.pos + 1], r.src[r.pos + 2]):
    return false
  let prefix = r.src[r.pos + 1]
  lexeme = "0"
  lexeme.add prefix
  r.advance()
  r.advance()
  while r.pos < r.src.len:
    let c = r.nextChar()
    if isBytesDigit(prefix, c):
      lexeme.add c
      r.advance()
    elif c == '~':
      r.advance()
      while r.pos < r.src.len and r.nextChar() in {' ', '\t', '\r', '\n'}:
        r.advance()
      if r.pos >= r.src.len or not isBytesDigit(prefix, r.nextChar()):
        r.raiseReadIncomplete("byte literal continuation requires another byte group")
    else:
      break
  true

proc scanNDigits(r: var Reader, lexeme: var string, count: int): bool =
  if r.pos + count > r.src.len:
    return false
  for i in 0 ..< count:
    if not isDigit(r.src[r.pos + i]):
      return false
  for _ in 0 ..< count:
    lexeme.add r.nextChar()
    r.advance()
  true

proc scanChar(r: var Reader, lexeme: var string, ch: char): bool =
  if r.pos >= r.src.len or r.nextChar() != ch:
    return false
  lexeme.add ch
  r.advance()
  true

proc scanFraction(r: var Reader, lexeme: var string): bool =
  if r.pos >= r.src.len or r.nextChar() != '.':
    return true
  lexeme.add '.'
  r.advance()
  if r.pos >= r.src.len or not isDigit(r.nextChar()):
    return false
  while r.pos < r.src.len and isDigit(r.nextChar()):
    lexeme.add r.nextChar()
    r.advance()
  true

proc scanBracketedTimezone(r: var Reader, lexeme: var string): bool =
  if r.pos >= r.src.len or r.nextChar() != '[':
    return true
  lexeme.add '['
  r.advance()
  var closed = false
  while r.pos < r.src.len:
    let c = r.nextChar()
    lexeme.add c
    r.advance()
    if c == ']':
      closed = true
      break
    if c in {'\n', '\r'}:
      return false
  closed

proc scanTimezoneSuffix(r: var Reader, lexeme: var string): bool =
  if r.pos >= r.src.len:
    return true
  let c = r.nextChar()
  if c == 'Z':
    lexeme.add c
    r.advance()
    return r.scanBracketedTimezone(lexeme)
  if c == '+' or c == '-':
    lexeme.add c
    r.advance()
    if not r.scanNDigits(lexeme, 2): return false
    if not r.scanChar(lexeme, ':'): return false
    if not r.scanNDigits(lexeme, 2): return false
    return r.scanBracketedTimezone(lexeme)
  if c == '[':
    return r.scanBracketedTimezone(lexeme)
  true

proc scanTimeBody(r: var Reader, lexeme: var string): bool =
  if not r.scanNDigits(lexeme, 2): return false
  if not r.scanChar(lexeme, ':'): return false
  if not r.scanNDigits(lexeme, 2): return false
  if r.pos < r.src.len and r.nextChar() == ':':
    lexeme.add ':'
    r.advance()
    if not r.scanNDigits(lexeme, 2): return false
  if not r.scanFraction(lexeme): return false
  r.scanTimezoneSuffix(lexeme)

proc tryScanTemporalLexeme(r: var Reader, lexeme: var string,
                           kind: var TokenKind): bool =
  if r.pos >= r.src.len or not isDigit(r.nextChar()):
    return false

  let startPos = r.pos
  let startLine = r.line
  let startCol = r.col
  template resetAndReturnFalse(): untyped =
    r.pos = startPos
    r.line = startLine
    r.col = startCol
    lexeme.setLen(0)
    return false

  if r.pos + 5 <= r.src.len and isDigit(r.src[r.pos]) and
      isDigit(r.src[r.pos + 1]) and r.src[r.pos + 2] == ':' and
      isDigit(r.src[r.pos + 3]) and isDigit(r.src[r.pos + 4]):
    if not r.scanTimeBody(lexeme): resetAndReturnFalse()
    if not r.canEndTemporal: resetAndReturnFalse()
    kind = tkTime
    return true

  if r.pos + 10 <= r.src.len and
      isDigit(r.src[r.pos]) and isDigit(r.src[r.pos + 1]) and
      isDigit(r.src[r.pos + 2]) and isDigit(r.src[r.pos + 3]) and
      r.src[r.pos + 4] == '-' and
      isDigit(r.src[r.pos + 5]) and isDigit(r.src[r.pos + 6]) and
      r.src[r.pos + 7] == '-' and
      isDigit(r.src[r.pos + 8]) and isDigit(r.src[r.pos + 9]):
    if not r.scanNDigits(lexeme, 4): resetAndReturnFalse()
    if not r.scanChar(lexeme, '-'): resetAndReturnFalse()
    if not r.scanNDigits(lexeme, 2): resetAndReturnFalse()
    if not r.scanChar(lexeme, '-'): resetAndReturnFalse()
    if not r.scanNDigits(lexeme, 2): resetAndReturnFalse()
    if r.pos < r.src.len and r.nextChar() == 'T':
      lexeme.add 'T'
      r.advance()
      if not r.scanTimeBody(lexeme): resetAndReturnFalse()
      if not r.canEndTemporal: resetAndReturnFalse()
      kind = tkDateTime
      return true
    if not r.canEndTemporal: resetAndReturnFalse()
    kind = tkDate
    return true

  false

proc parseBytesLiteral(r: var Reader, lexeme: string): Value =
  case lexeme[1]
  of '!':
    let bitLen = lexeme.len - 2
    if bitLen mod 8 != 0:
      r.raiseReadError("bit byte literal must contain a multiple of 8 bits")
    var data = newString(bitLen div 8)
    for byteIdx in 0 ..< data.len:
      var b = 0
      for bitIdx in 0 ..< 8:
        b = (b shl 1) or (if lexeme[2 + byteIdx * 8 + bitIdx] == '1': 1 else: 0)
      data[byteIdx] = char(b)
    newBytes(data)
  of 'x':
    let hexLen = lexeme.len - 2
    if hexLen mod 2 != 0:
      r.raiseReadError("hex byte literal must contain an even number of digits")
    var data = newString(hexLen div 2)
    for i in 0 ..< data.len:
      data[i] = char((hexValue(lexeme[2 + i * 2]) shl 4) or
                     hexValue(lexeme[3 + i * 2]))
    newBytes(data)
  of '#':
    var encoded = lexeme[2 .. ^1]
    let pad = encoded.len mod 4
    if pad != 0:
      encoded.add repeat("=", 4 - pad)
    try:
      newBytes(base64.decode(encoded))
    except ValueError:
      r.raiseReadError("invalid base64 byte literal")
  else:
    r.raiseReadError("invalid byte literal")

proc parseDigits(lexeme: string, start, count: int): int =
  for i in 0 ..< count:
    result = result * 10 + (ord(lexeme[start + i]) - ord('0'))

proc parseFractionMicros(lexeme: string, pos: var int): int =
  if pos >= lexeme.len or lexeme[pos] != '.':
    return 0
  inc pos
  let start = pos
  while pos < lexeme.len and isDigit(lexeme[pos]):
    inc pos
  let digits = pos - start
  if digits == 0:
    raise newException(ValueError, "fraction requires at least one digit")
  var micros = 0
  let used = min(digits, 6)
  for i in 0 ..< used:
    micros = micros * 10 + (ord(lexeme[start + i]) - ord('0'))
  for _ in used ..< 6:
    micros *= 10
  micros

proc parseZoneName(lexeme: string, pos: var int): string =
  if pos >= lexeme.len or lexeme[pos] != '[':
    return ""
  inc pos
  let start = pos
  while pos < lexeme.len and lexeme[pos] != ']':
    inc pos
  if pos >= lexeme.len:
    raise newException(ValueError, "unterminated timezone name bracket")
  result = lexeme[start ..< pos]
  inc pos
  if '/' notin result:
    raise newException(ValueError,
      "IANA timezone name must contain '/': " & result)

proc parseTimezone(lexeme: string, pos: var int,
                   allowNameOnly: bool): tuple[hasOffset: bool,
                                               offsetMinutes: int,
                                               timezoneName: string] =
  if pos >= lexeme.len:
    return (false, 0, "")
  case lexeme[pos]
  of 'Z':
    inc pos
    result = (true, 0, "UTC")
    let zone = parseZoneName(lexeme, pos)
    if zone.len > 0:
      result.timezoneName = zone
  of '+', '-':
    let sign = if lexeme[pos] == '-': -1 else: 1
    inc pos
    if pos + 5 > lexeme.len or lexeme[pos + 2] != ':':
      raise newException(ValueError, "invalid timezone offset")
    let hour = parseDigits(lexeme, pos, 2)
    pos += 3
    let minute = parseDigits(lexeme, pos, 2)
    pos += 2
    if hour > 23 or minute > 59:
      raise newException(ValueError, "invalid timezone offset")
    result = (true, sign * (hour * 60 + minute), "")
    result.timezoneName = parseZoneName(lexeme, pos)
  of '[':
    if not allowNameOnly:
      raise newException(ValueError,
        "DateTime literal requires offset or Z before [Zone/Name]")
    result = (false, 0, parseZoneName(lexeme, pos))
  else:
    return (false, 0, "")

proc expectEnd(lexeme: string, pos: int) =
  if pos != lexeme.len:
    raise newException(ValueError, "unexpected trailing characters")

proc parseTemporalLiteral(r: var Reader, kind: TokenKind,
                          lexeme: string): Value =
  try:
    case kind
    of tkDate:
      let year = parseDigits(lexeme, 0, 4)
      let month = parseDigits(lexeme, 5, 2)
      let day = parseDigits(lexeme, 8, 2)
      result = newDate(year, month, day)
    of tkTime:
      var pos = 0
      let hour = parseDigits(lexeme, pos, 2)
      pos += 3
      let minute = parseDigits(lexeme, pos, 2)
      pos += 2
      var second = 0
      if pos < lexeme.len and lexeme[pos] == ':':
        inc pos
        second = parseDigits(lexeme, pos, 2)
        pos += 2
      let microsecond = parseFractionMicros(lexeme, pos)
      let tz = parseTimezone(lexeme, pos, allowNameOnly = true)
      expectEnd(lexeme, pos)
      result = newTime(hour, minute, second, microsecond, tz.hasOffset,
                       tz.offsetMinutes, tz.timezoneName)
    of tkDateTime:
      let year = parseDigits(lexeme, 0, 4)
      let month = parseDigits(lexeme, 5, 2)
      let day = parseDigits(lexeme, 8, 2)
      var pos = 11
      let hour = parseDigits(lexeme, pos, 2)
      pos += 3
      let minute = parseDigits(lexeme, pos, 2)
      pos += 2
      var second = 0
      if pos < lexeme.len and lexeme[pos] == ':':
        inc pos
        second = parseDigits(lexeme, pos, 2)
        pos += 2
      let microsecond = parseFractionMicros(lexeme, pos)
      let tz = parseTimezone(lexeme, pos, allowNameOnly = false)
      expectEnd(lexeme, pos)
      result = newDateTime(year, month, day, hour, minute, second,
                           microsecond, tz.hasOffset, tz.offsetMinutes,
                           tz.timezoneName)
    else:
      r.raiseReadError("internal: unsupported temporal token")
  except GeneError as e:
    r.raiseReadError(e.msg)
  except ValueError as e:
    r.raiseReadError(e.msg)

proc parseRegexLiteral(r: var Reader): tuple[pattern, flags: string] =
  if r.nextChar() != '"':
    r.raiseReadError("internal: regex literal must start with a quote")
  r.advance() # consume opening quote
  if r.src.continuesWith("\"\"", r.pos):
    r.advance()
    r.advance()
    var closed = false
    while r.pos < r.src.len:
      if r.src.continuesWith("\"\"\"", r.pos):
        r.advanceBytes(3)
        closed = true
        break
      result.pattern.add r.nextChar()
      r.advance()
    if not closed:
      r.raiseReadIncomplete("unterminated regex literal")
  else:
    var closed = false
    while r.pos < r.src.len:
      let c = r.nextChar()
      if c == '\\':
        result.pattern.add c
        r.advance()
        if r.pos >= r.src.len:
          r.raiseReadIncomplete("unterminated regex literal")
        result.pattern.add r.nextChar()
        r.advance()
      elif c == '"':
        r.advance()
        closed = true
        break
      else:
        result.pattern.add c
        r.advance()
    if not closed:
      r.raiseReadIncomplete("unterminated regex literal")

  while r.pos < r.src.len and r.nextChar() in {'A'..'Z', 'a'..'z'}:
    result.flags.add r.nextChar()
    r.advance()
  try:
    discard newRegex(result.pattern, result.flags)
  except GeneError as e:
    r.raiseReadError(e.msg)

proc nextChar(r: var Reader): char =
  if r.pos < r.src.len:
    result = r.src[r.pos]
  else:
    result = '\0'

proc advance(r: var Reader) =
  if r.pos < r.src.len:
    if r.src[r.pos] == '\n':
      r.line += 1
      r.col = 1
    else:
      r.col += 1
    r.pos += 1

proc advanceBytes(r: var Reader, count: int) =
  for _ in 0 ..< count:
    r.advance()

proc hexValue(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc isUnicodeScalar(code: int): bool =
  code >= 0 and code <= 0x10ffff and not (code >= 0xd800 and code <= 0xdfff)

proc parseFixedUnicodeEscape(r: var Reader, digits: int): Rune =
  var code = 0
  for _ in 0 ..< digits:
    if r.pos >= r.src.len:
      r.raiseReadIncomplete("unterminated Unicode character escape")
    let value = hexValue(r.nextChar())
    if value < 0:
      r.raiseReadError("invalid Unicode character escape")
    code = code * 16 + value
    r.advance()
  if not isUnicodeScalar(code):
    r.raiseReadError("Unicode character escape is not a scalar value")
  Rune(int32(code))

proc parseBracedUnicodeEscape(r: var Reader): Rune =
  r.advance() # consume {
  var code = 0
  var digits = 0
  while r.pos < r.src.len and r.nextChar() != '}':
    let value = hexValue(r.nextChar())
    if value < 0:
      r.raiseReadError("invalid Unicode character escape")
    code = code * 16 + value
    digits += 1
    if digits > 6:
      r.raiseReadError("Unicode character escape is too large")
    r.advance()
  if r.pos >= r.src.len or r.nextChar() != '}':
    r.raiseReadIncomplete("unterminated Unicode character escape")
  r.advance() # consume }
  if digits == 0 or not isUnicodeScalar(code):
    r.raiseReadError("Unicode character escape is not a scalar value")
  Rune(int32(code))

proc parseEscapeRune(r: var Reader, context: string): Rune =
  if r.pos >= r.src.len:
    r.raiseReadIncomplete("unterminated " & context)
  let esc = r.nextChar()
  r.advance()
  case esc
  of 'n': Rune(int32(ord('\n')))
  of 'r': Rune(int32(ord('\r')))
  of 't': Rune(int32(ord('\t')))
  of '0': Rune(0)
  of '\\': Rune(int32(ord('\\')))
  of '\'': Rune(int32(ord('\'')))
  of '"': Rune(int32(ord('"')))
  of 'u':
    if r.pos < r.src.len and r.nextChar() == '{':
      r.parseBracedUnicodeEscape()
    else:
      r.parseFixedUnicodeEscape(4)
  of 'U':
    r.parseFixedUnicodeEscape(8)
  else:
    r.raiseReadError("unknown character escape")

proc parseCharEscape(r: var Reader): Rune =
  r.parseEscapeRune("character literal")

proc parseCharLiteral(r: var Reader): string =
  r.advance() # consume opening '
  if r.pos >= r.src.len:
    r.raiseReadIncomplete("unterminated character literal")
  if r.nextChar() == '\'':
    r.raiseReadError("empty character literal")

  let ch =
    if r.nextChar() == '\\':
      r.advance()
      r.parseCharEscape()
    else:
      if r.nextChar() in {'\n', '\r'}:
        r.raiseReadError("unterminated character literal")
      let width = runeLenAt(r.src, r.pos)
      let decoded = runeAt(r.src, r.pos)
      r.advanceBytes(width)
      decoded

  if r.pos >= r.src.len or r.nextChar() != '\'':
    if r.pos >= r.src.len:
      r.raiseReadIncomplete("unterminated character literal")
    r.raiseReadError("character literal must contain one Unicode scalar value")
  r.advance()
  ch.toUTF8()

proc tokenize(r: var Reader) =
  while r.pos < r.src.len:
    let c = r.nextChar()
    let startLine = r.line
    let startCol = r.col

    case c
    of ' ', '\t', '\r', '\n':
      r.advance()
      continue
    of '#':
      r.advance()
      let c2 = r.nextChar()
      case c2
      of '(': r.advance(); r.tokens.add Token(kind: tkHashLParen, lexeme: "#(", line: startLine, col: startCol)
      of '[': r.advance(); r.tokens.add Token(kind: tkHashLBracket, lexeme: "#[", line: startLine, col: startCol)
      of '{': r.advance(); r.tokens.add Token(kind: tkHashLBrace, lexeme: "#{", line: startLine, col: startCol)
      of '_': r.advance(); r.tokens.add Token(kind: tkUnderscore, lexeme: "#_", line: startLine, col: startCol)
      of '"':
        let literal = r.parseRegexLiteral()
        r.tokens.add Token(kind: tkRegex, lexeme: literal.pattern,
                           flags: canonicalRegexFlags(literal.flags),
                           line: startLine, col: startCol)
      of '<':
        # Block comment #< ... >#
        r.advance()
        var depth = 1
        while r.pos < r.src.len and depth > 0:
          if r.src.continuesWith("#<", r.pos):
            depth += 1
            r.advance(); r.advance()
          elif r.src.continuesWith(">#", r.pos):
            depth -= 1
            r.advance(); r.advance()
          else:
            r.advance()
        if depth > 0:
          r.raiseReadIncomplete("unterminated block comment")
      else:
        # Line comment
        while r.pos < r.src.len and r.nextChar() != '\n':
          r.advance()
    of '(': r.advance(); r.tokens.add Token(kind: tkLParen, lexeme: "(", line: startLine, col: startCol)
    of ')': r.advance(); r.tokens.add Token(kind: tkRParen, lexeme: ")", line: startLine, col: startCol)
    of '[': r.advance(); r.tokens.add Token(kind: tkLBracket, lexeme: "[", line: startLine, col: startCol)
    of ']': r.advance(); r.tokens.add Token(kind: tkRBracket, lexeme: "]", line: startLine, col: startCol)
    of '{':
      r.advance()
      if r.nextChar() == '{':
        r.advance()
        r.tokens.add Token(kind: tkHashMapStart, lexeme: "{{", line: startLine, col: startCol)
      else:
        r.tokens.add Token(kind: tkLBrace, lexeme: "{", line: startLine, col: startCol)
    of '}': r.advance(); r.tokens.add Token(kind: tkRBrace, lexeme: "}", line: startLine, col: startCol)
    of ',': r.advance(); r.tokens.add Token(kind: tkComma, lexeme: ",", line: startLine, col: startCol)
    of ':': r.advance(); r.tokens.add Token(kind: tkColon, lexeme: ":", line: startLine, col: startCol)
    of ';': r.advance(); r.tokens.add Token(kind: tkSemi, lexeme: ";", line: startLine, col: startCol)
    of '~': r.advance(); r.tokens.add Token(kind: tkTilde, lexeme: "~", line: startLine, col: startCol)
    of '%': r.advance(); r.tokens.add Token(kind: tkPercent, lexeme: "%", line: startLine, col: startCol)
    of '`': r.advance(); r.tokens.add Token(kind: tkBacktick, lexeme: "`", line: startLine, col: startCol)
    of '$':
      r.advance()
      if r.nextChar() == '"':
        # Interpolated string handled by string logic
        r.tokens.add Token(kind: tkDollar, lexeme: "$", line: startLine, col: startCol)
      else:
        r.tokens.add Token(kind: tkDollar, lexeme: "$", line: startLine, col: startCol)
    of '^':
      r.advance()
      if r.nextChar() == '^':
        r.advance()
        r.tokens.add Token(kind: tkCaretCaret, lexeme: "^^", line: startLine, col: startCol)
      else:
        r.tokens.add Token(kind: tkCaret, lexeme: "^", line: startLine, col: startCol)
    of '@':
      r.advance()
      if r.nextChar() == '@':
        r.advance()
        r.tokens.add Token(kind: tkAtAt, lexeme: "@@", line: startLine, col: startCol)
      else:
        r.tokens.add Token(kind: tkAt, lexeme: "@", line: startLine, col: startCol)
    of '.':
      if r.src.continuesWith("...", r.pos):
        r.advance(); r.advance(); r.advance()
        r.tokens.add Token(kind: tkDotDotDot, lexeme: "...", line: startLine, col: startCol)
      else:
        # Fallback to symbol if it's just a dot or something else
        let start = r.pos
        while r.pos < r.src.len and isSymbolChar(r.nextChar()):
          r.advance()
        let lexeme = r.src[start ..< r.pos]
        r.tokens.add Token(kind: tkSymbol, lexeme: lexeme, line: startLine, col: startCol)
    of '\"':
      # String literal
      let isInterpolated = r.tokens.len > 0 and r.tokens[^1].kind == tkDollar and
                           r.tokens[^1].line == startLine and r.tokens[^1].col == startCol - 1

      r.advance()
      var lexeme = ""
      if r.src.continuesWith("\"\"", r.pos):
        r.advance(); r.advance()
        var closed = false
        while r.pos < r.src.len:
          if r.src.continuesWith("\"\"\"", r.pos):
            r.advanceBytes(3)
            closed = true
            break
          let c2 = r.nextChar()
          if c2 == '\\':
            r.advance()
            lexeme.add r.parseEscapeRune("triple-quoted string literal").toUTF8()
          else:
            lexeme.add c2
            r.advance()
        if not closed:
          r.raiseReadIncomplete("unterminated triple-quoted string literal")
      else:
        var closed = false
        while r.pos < r.src.len:
          let c2 = r.nextChar()
          if c2 == '\"':
            r.advance()
            closed = true
            break
          if c2 == '\\':
            r.advance()
            lexeme.add r.parseEscapeRune("string literal").toUTF8()
          else:
            lexeme.add c2
            r.advance()
        if not closed:
          r.raiseReadIncomplete("unterminated string literal")

      if isInterpolated:
        # Simple implementation: split by ${...}
        # A real one would tokenize the expressions inside.
        # For now, let's just mark it.
        r.tokens[^1].kind = tkString # Change tkDollar to tkString
        r.tokens[^1].lexeme = lexeme
        r.tokens[^1].kind = tkDollar # Revert, we'll handle it in parser
        # Actually, let's keep it simple for now.
        # The EBNF says interpolated_string is its own thing.

      r.tokens.add Token(kind: tkString, lexeme: lexeme, line: startLine, col: startCol)
    of '\'':
      let lexeme = r.parseCharLiteral()
      r.tokens.add Token(kind: tkChar, lexeme: lexeme, line: startLine, col: startCol)
    else:
      var bytesLexeme = ""
      if r.tryScanBytesLexeme(bytesLexeme):
        r.tokens.add Token(kind: tkBytes, lexeme: bytesLexeme, line: startLine, col: startCol)
        continue
      var temporalLexeme = ""
      var temporalKind = tkDate
      if r.tryScanTemporalLexeme(temporalLexeme, temporalKind):
        r.tokens.add Token(kind: temporalKind, lexeme: temporalLexeme,
                           line: startLine, col: startCol)
        continue

      # Atoms: numbers, symbols
      let start = r.pos
      while r.pos < r.src.len and isSymbolChar(r.nextChar()):
        r.advance()
      let lexeme = r.src[start ..< r.pos]
      
      if lexeme.len == 0:
        r.advance() # Should not happen with isSymbolChar
        continue

      # Check if it's a byte literal or number.
      var valFloat: float
      if isBytesLexeme(lexeme):
        r.tokens.add Token(kind: tkBytes, lexeme: lexeme, line: startLine, col: startCol)
      elif lexeme.isIntLexeme:
        r.tokens.add Token(kind: tkInt, lexeme: lexeme, line: startLine, col: startCol)
      elif parseutils.parseFloat(lexeme, valFloat) == lexeme.len:
        r.tokens.add Token(kind: tkFloat, lexeme: lexeme, line: startLine, col: startCol)
      else:
        r.tokens.add Token(kind: tkSymbol, lexeme: lexeme, line: startLine, col: startCol)

  r.tokens.add Token(kind: tkEof, lexeme: "", line: r.line, col: r.col)

proc tokenKindName*(kind: TokenKind): string =
  case kind
  of tkEof: "eof"
  of tkLParen: "l-paren"
  of tkRParen: "r-paren"
  of tkLBracket: "l-bracket"
  of tkRBracket: "r-bracket"
  of tkLBrace: "l-brace"
  of tkRBrace: "r-brace"
  of tkHashMapStart: "hash-map-start"
  of tkHashLParen: "hash-l-paren"
  of tkHashLBracket: "hash-l-bracket"
  of tkHashLBrace: "hash-l-brace"
  of tkCaret: "caret"
  of tkCaretCaret: "caret-caret"
  of tkAt: "at"
  of tkAtAt: "at-at"
  of tkTilde: "tilde"
  of tkDotDotDot: "dot-dot-dot"
  of tkString: "string"
  of tkBytes: "bytes"
  of tkRegex: "regex"
  of tkInt: "int"
  of tkFloat: "float"
  of tkDate: "date"
  of tkTime: "time"
  of tkDateTime: "datetime"
  of tkSymbol: "symbol"
  of tkChar: "char"
  of tkComma: "comma"
  of tkColon: "colon"
  of tkEqual: "equal"
  of tkSemi: "semi"
  of tkSlash: "slash"
  of tkPercent: "percent"
  of tkBacktick: "backtick"
  of tkDollar: "dollar"
  of tkUnderscore: "underscore"

proc lexAll*(src: string, includeEof = false, sourceName = ""): seq[Token] =
  ## Tokenize source into significant reader tokens. Whitespace and ordinary
  ## comments are spacing and are not returned; datum comments are returned as
  ## the `underscore` token because they affect the parser stream.
  var r = initReader(src, sourceName)
  r.tokenize()
  result = r.tokens
  if not includeEof and result.len > 0 and result[^1].kind == tkEof:
    result.setLen(result.len - 1)

proc peek(r: Reader): Token =
  if r.tokIdx < r.tokens.len:
    result = r.tokens[r.tokIdx]
  else:
    result = Token(kind: tkEof)

proc peekKind(r: Reader): TokenKind =
  if r.tokIdx < r.tokens.len:
    r.tokens[r.tokIdx].kind
  else:
    tkEof

proc next(r: var Reader): Token =
  result = r.peek()
  if r.tokIdx < r.tokens.len:
    r.tokIdx += 1

proc parseForm(r: var Reader, inList = false): Value

proc hasStableSourceIdentity(v: Value): bool =
  v.kind in {vkBytes, vkRegex, vkDate, vkTime, vkDateTime, vkTimezone,
             vkDuration, vkList, vkMap, vkSet, vkHashMap, vkNode}

proc recordSourceLoc(r: var Reader, value: Value, tok: Token) =
  if value.hasStableSourceIdentity:
    let loc = tok.sourceLoc(r.sourceName)
    r.locs[value.bits] = loc

proc skipDatumComments(r: var Reader) =
  ## Datum comments (`#_`) are spacing (design §2.2 `datum_comment`): each `#_`
  ## discards the following form and yields no AST node. Runs of `#_` stack,
  ## since `parseForm` itself skips leading datum comments before its datum.
  while r.peekKind() == tkUnderscore:
    discard r.next()
    let k = r.peekKind()
    if k == tkEof:
      r.raiseReadIncomplete("#_ datum comment requires a following form")
    if k in {tkRParen, tkRBracket, tkRBrace}:
      r.raiseReadError("#_ datum comment requires a following form")
    discard r.parseForm()

proc parsePropKey(r: var Reader): string =
  r.skipDatumComments()
  if r.peekKind() == tkSymbol:
    let idx = r.tokIdx
    r.tokIdx += 1
    return internName(r.tokens[idx].lexeme)
  let keyForm = r.parseForm()
  if keyForm.kind == vkSymbol: keyForm.symVal else: ""

proc desugarPath*(lexeme: string): Value =
  if lexeme == "/": return newSym("/")
  if '/' notin lexeme: return newSym(lexeme)

  let parts = lexeme.split('/')
  var body = newSeq[Value]()
  for p in parts:
    if p.len == 0: continue # leading or trailing slash
    if p.startsWith("%"):
      body.add newNode(newSym("unquote"), body = @[newSym(p[1..^1])])
    else:
      if p.isIntLexeme:
        body.add newIntFromDecimal(p)
      else:
        body.add newSym(p)

  if lexeme.startsWith("/"):
    return newNode(newSym("select"), body = body)
  else:
    # Context-neutral path node; the compiler resolves it as an access chain
    # or static qualified name according to context (design §2.1).
    return newNode(newSym("path"), body = body)

proc parseList(r: var Reader, closing: TokenKind, immutable = false): Value =
  var items = newSeq[Value]()
  while true:
    r.skipDatumComments()
    let k = r.peekKind()
    if k == closing or k == tkEof: break
    items.add r.parseForm(inList = true)
  if r.peekKind() == tkEof:
    r.raiseReadIncomplete("unexpected EOF: unclosed '['")
  discard r.next() # consume closing
  result = newList(items, immutable)

proc containsPipeSlot(value: Value): bool

proc containsPipeSlot(entries: PropTable): bool =
  for _, value in entries:
    if containsPipeSlot(value):
      return true

proc containsPipeSlot(values: seq[Value]): bool =
  for value in values:
    if containsPipeSlot(value):
      return true

proc containsPipeSlot(value: Value): bool =
  case value.kind
  of vkSymbol:
    value.symVal == "_"
  of vkList:
    containsPipeSlot(value.listItems)
  of vkMap:
    containsPipeSlot(value.mapEntries)
  of vkSet:
    containsPipeSlot(value.setItems)
  of vkHashMap:
    for entry in value.hashMapEntries:
      if containsPipeSlot(entry.key) or containsPipeSlot(entry.val):
        return true
    false
  of vkNode:
    containsPipeSlot(value.head) or containsPipeSlot(value.props) or
      containsPipeSlot(value.body) or containsPipeSlot(value.meta)
  else:
    false

proc replacePipeSlot(value, replacement: Value): Value

proc replacePipeSlot(entries: PropTable, replacement: Value): PropTable =
  result = initOrderedTable[string, Value]()
  for key, value in entries:
    result[key] = replacePipeSlot(value, replacement)

proc replacePipeSlot(values: seq[Value], replacement: Value): seq[Value] =
  result = newSeqOfCap[Value](values.len)
  for value in values:
    result.add replacePipeSlot(value, replacement)

proc replacePipeSlot(value, replacement: Value): Value =
  case value.kind
  of vkSymbol:
    if value.symVal == "_": replacement else: value
  of vkList:
    newList(replacePipeSlot(value.listItems, replacement), value.listImmutable)
  of vkMap:
    newMap(replacePipeSlot(value.mapEntries, replacement), value.mapImmutable)
  of vkSet:
    newSet(replacePipeSlot(value.setItems, replacement))
  of vkHashMap:
    var entries: seq[HashMapEntry]
    for entry in value.hashMapEntries:
      entries.add HashMapEntry(key: replacePipeSlot(entry.key, replacement),
                               val: replacePipeSlot(entry.val, replacement))
    newHashMap(entries)
  of vkNode:
    newNode(replacePipeSlot(value.head, replacement),
            replacePipeSlot(value.props, replacement),
            replacePipeSlot(value.body, replacement),
            replacePipeSlot(value.meta, replacement),
            value.nodeImmutable)
  else:
    value

proc finishNodeSegment(head: Value, props: PropTable, body: seq[Value],
                       meta: PropTable, immutable: bool): Value =
  # Message sends (x ~ f a) are preserved as read; the compiler resolves the
  # message receiver-first (docs/core.md §9), so the reader must not erase
  # the `~` by desugaring to (f x a).
  newNode(head, props, body, meta, immutable)

proc pipeSegmentExpr(forms: seq[Value], props: PropTable, meta: PropTable,
                     immutable: bool): Value =
  if forms.len == 0:
    return NIL
  if forms.len == 1 and props.len == 0 and meta.len == 0:
    return forms[0]
  var body = newSeqOfCap[Value](max(0, forms.len - 1))
  for i in 1 ..< forms.len:
    body.add forms[i]
  finishNodeSegment(forms[0], props, body, meta, immutable)

proc finishPipeSegment(head: Value, props: PropTable, body: seq[Value],
                       meta: PropTable, immutable, inPipe: bool): Value =
  if inPipe and (containsPipeSlot(body) or containsPipeSlot(props) or
                 containsPipeSlot(meta)):
    let segment = pipeSegmentExpr(body, props, meta, immutable)
    return replacePipeSlot(segment, head)
  finishNodeSegment(head, props, body, meta, immutable)

proc parseNode(r: var Reader, closing: TokenKind, immutable = false): Value =
  var head = NIL
  var props = initOrderedTable[string, Value]()
  var meta = initOrderedTable[string, Value]()
  var body = newSeq[Value]()

  var first = true
  var inPipe = false
  while true:
    r.skipDatumComments()
    let k = r.peekKind()
    if k == closing or k == tkEof: break
    let tok = r.peek()
    case tok.kind
    of tkCaret, tkCaretCaret:
      discard r.next()
      let key = r.parsePropKey()
      var val: Value
      let afterKey = r.peekKind()
      if afterKey in {closing, tkRParen, tkRBracket, tkRBrace, tkEof} or
         afterKey in {tkCaret, tkCaretCaret, tkAt, tkAtAt}:
        val = TRUE
      else:
        val = r.parseForm()
      props[key] = val
    of tkAt, tkAtAt:
      if r.tokIdx + 1 >= r.tokens.len or r.tokens[r.tokIdx + 1].kind != tkSymbol:
        discard r.next()
        let form = newSym(tok.lexeme)
        if first:
          head = form
          first = false
        else:
          body.add form
      else:
        discard r.next()
        let key = r.parsePropKey()
        var val: Value
        let afterKey = r.peekKind()
        if afterKey in {closing, tkRParen, tkRBracket, tkRBrace, tkEof} or
           afterKey in {tkCaret, tkCaretCaret, tkAt, tkAtAt}:
          val = TRUE
        else:
          val = r.parseForm()
        meta[key] = val
    of tkSemi:
      # Pipe folding: (a; b) -> ((a) b)
      discard r.next()
      let prevNode = finishPipeSegment(head, props, body, meta, immutable, inPipe)
      head = prevNode
      props = initOrderedTable[string, Value]()
      meta = initOrderedTable[string, Value]()
      body = @[]
      first = false
      inPipe = true
    of tkComma:
      discard r.next()
    else:
      let form = r.parseForm()
      if first:
        head = form
        first = false
      else:
        body.add form

  if r.peekKind() == tkEof:
    r.raiseReadIncomplete("unexpected EOF: unclosed '('")
  discard r.next()

  if inPipe:
    result = finishPipeSegment(head, props, body, meta, immutable, inPipe)
  else:
    result = newNode(head, props, body, meta, immutable)

proc parseMap(r: var Reader, closing: TokenKind, immutable = false): Value =
  var items = initOrderedTable[string, Value]()
  while true:
    r.skipDatumComments()
    let k = r.peekKind()
    if k == closing or k == tkEof: break
    let tok = r.peek()
    if tok.kind in {tkCaret, tkCaretCaret}:
      discard r.next()
    let key = r.parsePropKey()
    if tok.kind == tkCaretCaret:
      # `^^k` is true-flag sugar, same as in node props; it consumes no value.
      items[key] = TRUE
      if r.peekKind() == tkComma: discard r.next()
      continue
    var val: Value = NIL
    if r.peekKind() == tkColon:
      discard r.next()
    let afterKey = r.peekKind()
    if afterKey != closing and afterKey != tkComma:
      val = r.parseForm()
    items[key] = val
    if r.peekKind() == tkComma: discard r.next()
  if r.peekKind() == tkEof:
    r.raiseReadIncomplete("unexpected EOF: unclosed '{'")
  discard r.next()
  result = newMap(items, immutable)

proc parseHashMap(r: var Reader): Value =
  var entries: seq[HashMapEntry]
  while true:
    r.skipDatumComments()
    let k = r.peekKind()
    if k == tkEof: break
    if k == tkRBrace:
      if r.tokIdx + 1 < r.tokens.len and r.tokens[r.tokIdx + 1].kind == tkRBrace:
        break
      r.raiseReadIncomplete("unexpected EOF: unclosed '{{'")
    let key = r.parseForm()
    if r.peekKind() != tkColon:
      r.raiseReadError("general map entries require ':' between key and value")
    discard r.next()
    if r.peekKind() in {tkRBrace, tkEof}:
      r.raiseReadError("general map entry requires a value")
    let val = r.parseForm()
    entries.add HashMapEntry(key: key, val: val)
    if r.peekKind() == tkComma: discard r.next()
  if r.peekKind() == tkEof:
    r.raiseReadIncomplete("unexpected EOF: unclosed '{{'")
  discard r.next()
  discard r.next()
  result = newHashMap(entries)

proc read*(src: string, sourceName = "",
           options: ReadOptions = ReadOptions()): Value

proc parseInterpolatedString(lexeme, sourceName: string,
                             line, col: int,
                             options: ReadOptions = ReadOptions()): Value =
  var body = newSeq[Value]()
  var i = 0
  var last = 0
  while i < lexeme.len:
    if lexeme[i..^1].startsWith("${"):
      if i > last: body.add newStr(lexeme[last ..< i])
      i += 2
      let start = i
      var depth = 1
      while i < lexeme.len and depth > 0:
        if lexeme[i] == '{': depth += 1
        elif lexeme[i] == '}': depth -= 1
        i += 1
      if depth > 0:
        raiseReadIncompleteAt(sourceName, line, col,
                              "unterminated interpolation '${...}'")
      let exprStr = lexeme[start ..< i-1]
      body.add read(exprStr, sourceName, options)
      last = i
    elif lexeme[i..^1].startsWith("$("):
      if i > last: body.add newStr(lexeme[last ..< i])
      i += 1
      let start = i
      var depth = 1
      i += 1
      while i < lexeme.len and depth > 0:
        if lexeme[i] == '(': depth += 1
        elif lexeme[i] == ')': depth -= 1
        i += 1
      if depth > 0:
        raiseReadIncompleteAt(sourceName, line, col,
                              "unterminated interpolation '$(...)'")
      let exprStr = lexeme[start ..< i]
      body.add read(exprStr, sourceName, options)
      last = i
    else: i += 1
  if last < lexeme.len: body.add newStr(lexeme[last..^1])
  return newNode(newSym("$"), body = body)

proc parseForm(r: var Reader, inList = false): Value =
  r.skipDatumComments()
  let tok = r.next()
  if r.options.maxDepth > 0 and r.parseDepth > r.options.maxDepth:
    r.raiseReadErrorAt(tok, "reader max-depth exceeded (" &
                       $r.options.maxDepth & ")")
  inc r.parseDepth
  defer: dec r.parseDepth
  template finish(value: Value): untyped =
    let parsed = value
    r.recordSourceLoc(parsed, tok)
    return parsed
  case tok.kind
  of tkInt: finish newIntFromDecimal(tok.lexeme)
  of tkFloat: finish newFloat(parseFloat(tok.lexeme))
  of tkString: finish newStr(tok.lexeme)
  of tkBytes: finish r.parseBytesLiteral(tok.lexeme)
  of tkRegex: finish newRegex(tok.lexeme, tok.flags)
  of tkDate, tkTime, tkDateTime: finish r.parseTemporalLiteral(tok.kind, tok.lexeme)
  of tkChar: finish newChar(runeAt(tok.lexeme, 0))
  of tkSymbol:
    case tok.lexeme
    of "true": finish TRUE
    of "false": finish FALSE
    of "nil": finish NIL
    of "void": finish VOID
    else:
      let lex = tok.lexeme
      if not inList:
        if lex.endsWith("..."):
          finish newNode(newSym("..."), body = @[desugarPath(lex[0..^4])])
        finish desugarPath(lex)
      else: finish newSym(lex)
  of tkLParen: finish r.parseNode(tkRParen)
  of tkLBracket: finish r.parseList(tkRBracket)
  of tkLBrace: finish r.parseMap(tkRBrace)
  of tkHashMapStart: finish r.parseHashMap()
  of tkHashLParen: finish r.parseNode(tkRParen, immutable = true)
  of tkHashLBracket: finish r.parseList(tkRBracket, immutable = true)
  of tkHashLBrace: finish r.parseMap(tkRBrace, immutable = true)
  of tkBacktick:
    let inner = r.parseForm(inList)
    finish newNode(newSym("quasiquote"), body = @[inner])
  of tkPercent:
    # Inside a vector the flat token stream is preserved verbatim.
    if inList: finish newSym("%")
    let inner = r.parseForm(inList = false)
    finish newNode(newSym("unquote"), body = @[inner])
  of tkCaret: finish newSym("^")
  of tkCaretCaret: finish newSym("^^")
  of tkAt: finish newSym("@")
  of tkAtAt: finish newSym("@@")
  of tkColon: finish newSym(":")
  of tkEqual: finish newSym("=")
  of tkComma: finish newSym(",")
  of tkTilde: finish newSym("~")
  of tkDotDotDot: finish newSym("...")
  of tkDollar:
    let nextTok = r.peek()
    if nextTok.kind == tkString and nextTok.line == tok.line and
        nextTok.col == tok.col + 1:
      let s = r.next()
      finish parseInterpolatedString(s.lexeme, r.sourceName, tok.line, tok.col,
                                     r.options)
    finish newSym("$")
  of tkRParen, tkRBracket, tkRBrace:
    r.raiseReadErrorAt(tok, "unexpected closing delimiter '" & tok.lexeme & "'")
  of tkEof:
    r.raiseReadIncomplete("unexpected end of input")
  else: finish NIL

proc read*(src: string, sourceName = "",
           options: ReadOptions = ReadOptions()): Value =
  var r = initReader(src, sourceName, options)
  r.tokenize()
  r.skipDatumComments()
  if r.peekKind() == tkEof: return NIL
  return r.parseForm(inList = false)

proc readAllWithLocs*(src: string, sourceName = "",
                      options: ReadOptions = ReadOptions()): SourceUnit =
  ## Read all top-level forms from src (program = { form }).
  var r = initReader(src, sourceName, options)
  r.tokenize()
  while true:
    r.skipDatumComments()
    if r.peekKind() == tkEof: break
    let before = r.peek()
    let form = r.parseForm(inList = false)
    result.forms.add form
    result.formLocs.add before.sourceLoc(sourceName)
  result.sourceName = sourceName
  result.locs = r.locs

proc readAll*(src: string, sourceName = "",
              options: ReadOptions = ReadOptions()): seq[Value] =
  ## Read all top-level forms from src (program = { form }).
  readAllWithLocs(src, sourceName, options).forms
