## Lexer & core parser for Gene (design §2.2)
import std/[base64, strutils, unicode, tables, parseutils]
import ./types

type
  ReadContextFrame* = object
    ## A delimited form that was open when a read error occurred. Frames are
    ## ordered outermost to innermost, so consumers can render or inspect the
    ## complete nesting without parsing the error message.
    sourceName*: string
    opener*, expectedCloser*: string
    line*, col*: int

  TokenKind* = enum
    tkEof,
    tkLParen, tkRParen,      # ( )
    tkLBracket, tkRBracket,  # [ ]
    tkLBrace, tkRBrace,      # { }
    tkHashMapStart,             # {{
    tkHashLParen,            # #(
    tkHashLBracket,          # #[
    tkHashLBrace,            # #{
    tkRef, tkDeref,          # #Ref #Deref
    tkCaret, tkCaretCaret,   # ^ ^^
    tkAt, tkAtAt,            # @ @@
    tkTilde,                 # removed spaced ~ surface; the parser rejects it
    tkArrow,                 # -> value-pipeline delimiter
    tkFatArrow,              # => per-item value-pipeline delimiter
    tkDotDotDot,             # ...
    tkString, tkBytes, tkRegex, tkInt, tkFloat, tkDate, tkTime, tkDateTime,
    tkSymbol, tkChar,
    tkComma, tkColon, tkEqual, tkSemi, tkSlash, tkPercent,
    tkBacktick, tkDollar, tkGeneMember, tkUnderscore,
    tkLineComment, tkBlockComment

  Token* = object
    kind*: TokenKind
    lexeme*: string
    flags*: string
    line*, col*: int

  SpannedToken* = object
    kind*: TokenKind
    lexeme*: string
    flags*: string
    line*, col*: int
    startByte*, endByte*: int

  ReadOptions* = object
    maxDepth*: int              # 0 means unlimited
    rejectDuplicateProps*: bool

  ReadContextEntry = object
    kind: TokenKind
    line, col: int

  ReadContextStack = object
    ## Keep the common shallow case inline: successful reads should not
    ## allocate merely to support diagnostics produced only on failure.
    inline: array[16, ReadContextEntry]
    overflow: seq[ReadContextEntry]
    depth: int

  Reader* = object
    src*: string
    sourceName*: string
    options*: ReadOptions
    pos*: int
    line*, col*: int
    tokens: seq[Token]
    tokIdx: int
    parseDepth: int
    context: ReadContextStack
    locs: Table[uint64, SourceLoc]
    captureTrivia: bool
    spannedTokens: seq[SpannedToken]

  ReadError* = object of CatchableError
    sourceName*: string
    line*, col*: int
    contextFrames*: seq[ReadContextFrame]
  ReadIncompleteError* = object of ReadError

  SourceUnit* = object
    sourceName*: string
    ## The text the forms were read from. Kept so a consumer that must
    ## reproduce a *slice* of the original — an embedded block's own source,
    ## for a client-only source map — can take the exact characters the author
    ## wrote instead of re-printing the tree and losing every column.
    source*: string
    forms*: seq[Value]
    formLocs*: seq[SourceLoc]
    locs*: Table[uint64, SourceLoc]

proc sourceLoc(tok: Token, sourceName: string): SourceLoc =
  SourceLoc(sourceName: sourceName, line: tok.line, col: tok.col)

proc snapshot(stack: ReadContextStack,
              sourceName: string): seq[ReadContextFrame] =
  result = newSeq[ReadContextFrame](stack.depth)
  let inlineCount = min(stack.depth, stack.inline.len)
  for i in 0 ..< stack.depth:
    let entry =
      if i < inlineCount: stack.inline[i]
      else: stack.overflow[i - stack.inline.len]
    let delimiters =
      case entry.kind
      of tkLParen: ("(", ")")
      of tkLBracket: ("[", "]")
      of tkLBrace: ("{", "}")
      of tkHashMapStart: ("{{", "}}")
      of tkHashLParen: ("#(", ")")
      of tkHashLBracket: ("#[", "]")
      of tkHashLBrace: ("#{", "}")
      else: ("?", "?")
    result[i] = ReadContextFrame(
      sourceName: sourceName,
      opener: delimiters[0], expectedCloser: delimiters[1],
      line: entry.line, col: entry.col)

proc frameLocation(frame: ReadContextFrame): string =
  let location = $frame.line & ":" & $frame.col
  if frame.sourceName.len > 0:
    frame.sourceName & ":" & location
  else:
    location

proc withReadContext(message: string,
                     frames: openArray[ReadContextFrame]): string =
  result = message
  if frames.len == 0:
    return
  for i in countdown(frames.high, 0):
    let frame = frames[i]
    result.add "\n  while reading '" & frame.opener & "' opened at " &
               frame.frameLocation & "; expected '" & frame.expectedCloser & "'"

proc raiseReadErrorAt(sourceName: string, line, col: int,
                      message: string,
                      contextFrames: openArray[ReadContextFrame] = []) {.noReturn.} =
  var e: ref ReadError
  new(e)
  e.msg = message.withReadContext(contextFrames)
  e.sourceName = sourceName
  e.line = line
  e.col = col
  e.contextFrames = @contextFrames
  raise e

proc raiseReadIncompleteAt(sourceName: string, line, col: int,
                           message: string,
                           contextFrames: openArray[ReadContextFrame] = []) {.noReturn.} =
  var e: ref ReadIncompleteError
  new(e)
  e.msg = message.withReadContext(contextFrames)
  e.sourceName = sourceName
  e.line = line
  e.col = col
  e.contextFrames = @contextFrames
  raise e

proc raiseReadError(r: Reader, message: string) {.noReturn.} =
  raiseReadErrorAt(r.sourceName, r.line, r.col, message,
                   r.context.snapshot(r.sourceName))

proc raiseReadErrorAt(r: Reader, tok: Token, message: string) {.noReturn.} =
  raiseReadErrorAt(r.sourceName, tok.line, tok.col, message,
                   r.context.snapshot(r.sourceName))

proc raiseReadIncomplete(r: Reader, message: string) {.noReturn.} =
  raiseReadIncompleteAt(r.sourceName, r.line, r.col, message,
                        r.context.snapshot(r.sourceName))

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
                options: ReadOptions = ReadOptions(),
                captureTrivia = false): Reader =
  Reader(src: src, sourceName: sourceName, options: options, line: 1, col: 1,
         tokens: newSeqOfCap[Token](min(src.len + 1, 4096)),
         locs: initTable[uint64, SourceLoc](), captureTrivia: captureTrivia)

proc isSymbolChar(c: char): bool =
  c notin {'(', ')', '[', ']', '{', '}', ' ', '\t', '\n', '\r', ',', ';', '\"', '\'', '`', '#'}

proc isHexDigit(c: char): bool =
  c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc isBase64Char(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}

proc isBytesDigit(prefix, c: char): bool =
  ## Internal prefix char: '!' binary, 'x' hex, '#' base64 (design §2.2
  ## byte literal dispatch).
  case prefix
  of '!': c in {'0', '1'}
  of 'x': isHexDigit(c)
  of '#': isBase64Char(c)
  else: false

proc isHexIntLexeme(lexeme: string): bool =
  ## A complete `0x` hex-digit run, with an optional leading `-` exactly as
  ## `isIntLexeme` allows for decimal. Classification happens on the whole
  ## atom rather than by scanning eagerly, so `0x1fg` is the single symbol
  ## `0x1fg` — the way `12abc` and `1-2` already lex — instead of splitting
  ## into `0x1f` and `g`, which would silently change a call's arity.
  var i = 0
  if lexeme.len > 0 and lexeme[0] == '-':
    i = 1
  if lexeme.len < i + 3 or lexeme[i] != '0' or lexeme[i + 1] != 'x':
    return false
  for j in i + 2 ..< lexeme.len:
    if not isHexDigit(lexeme[j]):
      return false
  true

proc isDigit(c: char): bool {.inline.} =
  c in {'0'..'9'}

proc canEndTemporal(r: var Reader): bool =
  r.pos >= r.src.len or not isSymbolChar(r.src[r.pos])

proc hexValue(c: char): int
proc nextChar(r: var Reader): char
proc advance(r: var Reader)
proc advanceBytes(r: var Reader, count: int)

proc tryScanHashBytesLexeme(r: var Reader, lexeme: var string): bool =
  ## r.pos is just past a '#' (next char is 'B'). Recognizes the three byte
  ## spellings #B#, #B16#, #B64# (design §2.2 / §7.5) and scans the body,
  ## including `~` continuations. Returns false without consuming anything
  ## when the prefix is not a byte literal, leaving the form reserved.
  let hashPos = r.pos - 1
  var prefix = '\0'
  var bodyStart = 0
  if r.pos + 1 < r.src.len and r.src[r.pos] == 'B' and r.src[r.pos + 1] == '#':
    prefix = '!'
    bodyStart = r.pos + 2
  elif r.pos + 3 < r.src.len and r.src[r.pos] == 'B' and
       r.src[r.pos + 1] == '1' and r.src[r.pos + 2] == '6' and
       r.src[r.pos + 3] == '#':
    prefix = 'x'
    bodyStart = r.pos + 4
  elif r.pos + 3 < r.src.len and r.src[r.pos] == 'B' and
       r.src[r.pos + 1] == '6' and r.src[r.pos + 2] == '4' and
       r.src[r.pos + 3] == '#':
    prefix = '#'
    bodyStart = r.pos + 4
  else:
    return false
  # The ordered dispatch requires a digit right after the prefix.
  if bodyStart >= r.src.len or not isBytesDigit(prefix, r.src[bodyStart]):
    return false
  lexeme = r.src[hashPos ..< bodyStart]
  r.advanceBytes(bodyStart - r.pos)
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
  ## lexeme is one of the #B family: #B# bits, #B16# hex, #B64# base64.
  ## The reader accepts all three spellings; the printer emits #B16# hex.
  if lexeme.startsWith("#B#"):
    let bitStart = 3
    let bitLen = lexeme.len - bitStart
    if bitLen mod 8 != 0:
      r.raiseReadError("bit byte literal must contain a multiple of 8 bits")
    var data = newString(bitLen div 8)
    for byteIdx in 0 ..< data.len:
      var b = 0
      for bitIdx in 0 ..< 8:
        b = (b shl 1) or
            (if lexeme[bitStart + byteIdx * 8 + bitIdx] == '1': 1 else: 0)
      data[byteIdx] = char(b)
    newBytes(data)
  elif lexeme.startsWith("#B16#"):
    let hexStart = 5
    let hexLen = lexeme.len - hexStart
    if hexLen mod 2 != 0:
      r.raiseReadError("hex byte literal must contain an even number of digits")
    var data = newString(hexLen div 2)
    for i in 0 ..< data.len:
      data[i] = char((hexValue(lexeme[hexStart + i * 2]) shl 4) or
                     hexValue(lexeme[hexStart + 1 + i * 2]))
    newBytes(data)
  elif lexeme.startsWith("#B64#"):
    var encoded = lexeme[5 .. ^1]
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

type InterpolationCloserStack = object
  inline: array[16, TokenKind]
  overflow: seq[TokenKind]
  depth: int

proc push(stack: var InterpolationCloserStack, kind: TokenKind) =
  if stack.depth < stack.inline.len:
    stack.inline[stack.depth] = kind
  else:
    let overflowIndex = stack.depth - stack.inline.len
    if overflowIndex < stack.overflow.len:
      stack.overflow[overflowIndex] = kind
    else:
      stack.overflow.add kind
  inc stack.depth

proc top(stack: InterpolationCloserStack): TokenKind =
  if stack.depth <= stack.inline.len:
    stack.inline[stack.depth - 1]
  else:
    stack.overflow[stack.depth - stack.inline.len - 1]

proc pop(stack: var InterpolationCloserStack) =
  dec stack.depth

proc trackInterpolationCloser(interpolationClosers: var InterpolationCloserStack,
                              tokKind: TokenKind): bool =
  ## Kept out of the tokenizer body so normal reads do not carry closer-stack
  ## code in their instruction-cache working set.
  case tokKind
  of tkLParen, tkHashLParen: interpolationClosers.push tkRParen
  of tkLBracket, tkHashLBracket: interpolationClosers.push tkRBracket
  of tkLBrace, tkHashLBrace: interpolationClosers.push tkRBrace
  of tkHashMapStart:
    interpolationClosers.push tkRBrace
    interpolationClosers.push tkRBrace
  of tkRParen, tkRBracket, tkRBrace:
    if interpolationClosers.depth > 0 and tokKind == interpolationClosers.top:
      interpolationClosers.pop()
      return interpolationClosers.depth == 0
  else: discard
  false

proc raiseReservedHashForm(r: var Reader, c2: char,
                           startLine, startCol: int) {.noReturn.} =
  ## '#' followed by something that is not a recognized continuation: that
  ## lexical space is reserved for future reader syntax (design §2.2).
  var snippet = "#"
  var j = r.pos
  while j < r.src.len and snippet.len < 13 and isSymbolChar(r.src[j]):
    snippet.add r.src[j]
    inc j
  if snippet.len == 1:
    snippet.add c2
  raiseReadErrorAt(r.sourceName, startLine, startCol,
    "unknown '#' form \"" & snippet & "\": '#' starts a comment only " &
    "when followed by whitespace or '!'; other '#' forms are reserved. " &
    "Write \"# " & snippet[1 .. ^1] & "\" for a comment")

proc tokenizeImpl(r: var Reader,
                  interpolationClosers: ptr InterpolationCloserStack,
                  interpolationClosed: var bool,
                  captureSpans: static bool = false) =
  ## The normal tokenizer passes nil. Interpolation supplies a closer stack;
  ## only delimiter tokens consult it, so ordinary token emission remains the
  ## original hot path.
  template addToken(reader: var Reader, tokKind: TokenKind, tokLexeme: string,
                    tokLine, tokCol, tokStart: int,
                    tokFlags: string = "") =
    when captureSpans:
      reader.spannedTokens.add SpannedToken(kind: tokKind, lexeme: tokLexeme,
        flags: tokFlags, line: tokLine, col: tokCol,
        startByte: tokStart, endByte: reader.pos)
    else:
      # Interpolation scanning needs only the lexical position and balanced
      # delimiters, not a token stream.
      if interpolationClosers == nil:
        reader.tokens.add Token(kind: tokKind, lexeme: tokLexeme, flags: tokFlags,
                                line: tokLine, col: tokCol)

  template trackDelimiter(tokKind: TokenKind) =
    if interpolationClosers != nil and
        trackInterpolationCloser(interpolationClosers[], tokKind):
      interpolationClosed = true
      return

  while r.pos < r.src.len:
    let c = r.nextChar()
    let startLine = r.line
    let startCol = r.col
    let startByte = r.pos

    case c
    of ' ', '\t', '\r', '\n':
      r.advance()
      continue
    of '#':
      r.advance()
      let c2 = r.nextChar()
      case c2
      of '(':
        r.advance(); r.addToken(tkHashLParen, "#(", startLine, startCol, startByte)
        trackDelimiter(tkHashLParen)
      of '[':
        r.advance(); r.addToken(tkHashLBracket, "#[", startLine, startCol, startByte)
        trackDelimiter(tkHashLBracket)
      of '{':
        r.advance(); r.addToken(tkHashLBrace, "#{", startLine, startCol, startByte)
        trackDelimiter(tkHashLBrace)
      of '_': r.advance(); r.addToken(tkUnderscore, "#_", startLine, startCol, startByte)
      of 'R':
        if r.src.continuesWith("Ref", r.pos) and
            (r.pos + 3 >= r.src.len or not isSymbolChar(r.src[r.pos + 3])):
          for _ in 0 ..< 3: r.advance()
          r.addToken(tkRef, "#Ref", startLine, startCol, startByte)
        else:
          r.raiseReservedHashForm(c2, startLine, startCol)
      of 'D':
        if r.src.continuesWith("Deref", r.pos) and
            (r.pos + 5 >= r.src.len or not isSymbolChar(r.src[r.pos + 5])):
          for _ in 0 ..< 5: r.advance()
          r.addToken(tkDeref, "#Deref", startLine, startCol, startByte)
        else:
          r.raiseReservedHashForm(c2, startLine, startCol)
      of '"':
        let literal = r.parseRegexLiteral()
        r.addToken(tkRegex, literal.pattern, startLine, startCol, startByte,
                   canonicalRegexFlags(literal.flags))
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
        if r.captureTrivia:
          r.addToken(tkBlockComment, r.src[startByte ..< r.pos],
                     startLine, startCol, startByte)
      of 'B':
        # #B# / #B16# / #B64# byte literals (design §2.2 / §7.5).
        var bytesLexeme = ""
        if r.tryScanHashBytesLexeme(bytesLexeme):
          r.addToken(tkBytes, bytesLexeme, startLine, startCol, startByte)
        else:
          # '#B…' without a valid byte-literal prefix is reserved.
          r.raiseReservedHashForm(c2, startLine, startCol)
      of ' ', '\t', '\r', '\n', '\0', '!':
        # Line comment: '#' followed by whitespace, end of line/input, or '!'
        # ('#!' stays a plain line comment so a first-line shebang works).
        # '\0' is nextChar's end-of-input sentinel: a bare trailing '#'.
        while r.pos < r.src.len and r.nextChar() != '\n':
          r.advance()
        if r.captureTrivia:
          r.addToken(tkLineComment, r.src[startByte ..< r.pos],
                     startLine, startCol, startByte)
      else:
        # Every other '#' form is reserved for future reader syntax
        # (design §2.2). Rejecting here keeps '#comment'-without-space a
        # loud error instead of a silent comment or symbol.
        r.raiseReservedHashForm(c2, startLine, startCol)
    of '(':
      r.advance(); r.addToken(tkLParen, "(", startLine, startCol, startByte)
      trackDelimiter(tkLParen)
    of ')':
      r.advance(); r.addToken(tkRParen, ")", startLine, startCol, startByte)
      trackDelimiter(tkRParen)
    of '[':
      r.advance(); r.addToken(tkLBracket, "[", startLine, startCol, startByte)
      trackDelimiter(tkLBracket)
    of ']':
      r.advance(); r.addToken(tkRBracket, "]", startLine, startCol, startByte)
      trackDelimiter(tkRBracket)
    of '{':
      r.advance()
      if r.nextChar() == '{':
        r.advance()
        r.addToken(tkHashMapStart, "{{", startLine, startCol, startByte)
        trackDelimiter(tkHashMapStart)
      else:
        r.addToken(tkLBrace, "{", startLine, startCol, startByte)
        trackDelimiter(tkLBrace)
    of '}':
      r.advance(); r.addToken(tkRBrace, "}", startLine, startCol, startByte)
      trackDelimiter(tkRBrace)
    of ',': r.advance(); r.addToken(tkComma, ",", startLine, startCol, startByte)
    of ':': r.advance(); r.addToken(tkColon, ":", startLine, startCol, startByte)
    of ';': r.advance(); r.addToken(tkSemi, ";", startLine, startCol, startByte)
    of '~':
      # Canonical/generated trees may contain compact `~name` path markers, and
      # `~name` remains a legal user symbol. Keep a glued tilde in one token.
      # A spaced tilde gets the pipeline-delimiter token below.
      if r.pos + 1 < r.src.len and r.src[r.pos + 1].isSymbolChar:
        let lexStart = r.pos
        r.advance()
        while r.pos < r.src.len and r.src[r.pos].isSymbolChar:
          r.advance()
        r.addToken(tkSymbol, r.src[lexStart ..< r.pos],
                   startLine, startCol, startByte)
      else:
        r.advance()
        r.addToken(tkTilde, "~", startLine, startCol, startByte)
    of '%': r.advance(); r.addToken(tkPercent, "%", startLine, startCol, startByte)
    of '`': r.advance(); r.addToken(tkBacktick, "`", startLine, startCol, startByte)
    of '$':
      # `$x` is sugar for the `gene/x` member path, so the stdlib is reachable
      # without occupying a bare name (design §2.1). A `"` is not a symbol
      # char, so `$"..."` interpolation and the bare `$` concat head both fall
      # through to the plain dollar token.
      if r.pos + 1 < r.src.len and r.src[r.pos + 1].isSymbolChar:
        r.advance()
        let lexStart = r.pos
        while r.pos < r.src.len and r.src[r.pos].isSymbolChar:
          r.advance()
        r.addToken(tkGeneMember, r.src[lexStart ..< r.pos],
                   startLine, startCol, startByte)
      else:
        r.advance()
        r.addToken(tkDollar, "$", startLine, startCol, startByte)
    of '^':
      r.advance()
      if r.nextChar() == '^':
        r.advance()
        r.addToken(tkCaretCaret, "^^", startLine, startCol, startByte)
      else:
        r.addToken(tkCaret, "^", startLine, startCol, startByte)
    of '@':
      r.advance()
      if r.nextChar() == '@':
        r.advance()
        r.addToken(tkAtAt, "@@", startLine, startCol, startByte)
      else:
        r.addToken(tkAt, "@", startLine, startCol, startByte)
    of '.':
      if r.src.continuesWith("...", r.pos):
        r.advance(); r.advance(); r.advance()
        r.addToken(tkDotDotDot, "...", startLine, startCol, startByte)
      else:
        # Fallback to symbol if it's just a dot or something else
        let start = r.pos
        while r.pos < r.src.len and isSymbolChar(r.nextChar()):
          r.advance()
        let lexeme = r.src[start ..< r.pos]
        r.addToken(tkSymbol, lexeme, startLine, startCol, startByte)
    of '\"':
      # String literal
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

      # `$` remains its own token so semantic parsing keeps the current
      # desugaring. The string token owns only the quoted source span; tooling
      # combines the adjacent pair into one interpolation occurrence.
      r.addToken(tkString, lexeme, startLine, startCol, startByte)
    of '\'':
      let lexeme = r.parseCharLiteral()
      r.addToken(tkChar, lexeme, startLine, startCol, startByte)
    else:
      var temporalLexeme = ""
      var temporalKind = tkDate
      if r.tryScanTemporalLexeme(temporalLexeme, temporalKind):
        r.addToken(temporalKind, temporalLexeme, startLine, startCol, startByte)
        continue

      # Atoms: numbers, symbols
      let start = r.pos
      while r.pos < r.src.len and isSymbolChar(r.nextChar()):
        r.advance()
      if r.pos == start:
        r.advance() # Should not happen with isSymbolChar
        continue
      if interpolationClosers != nil:
        continue
      let lexeme = r.src[start ..< r.pos]

      # Check if it's a number or symbol.
      var valFloat: float
      if lexeme.isHexIntLexeme or lexeme.isIntLexeme:
        r.addToken(tkInt, lexeme, startLine, startCol, startByte)
      elif parseutils.parseFloat(lexeme, valFloat) == lexeme.len:
        r.addToken(tkFloat, lexeme, startLine, startCol, startByte)
      elif lexeme == "->":
        # Only the whole atom is a delimiter, so `->name`, `a->b`, and `-->`
        # stay ordinary symbols without a spacing rule of their own.
        r.addToken(tkArrow, lexeme, startLine, startCol, startByte)
      elif lexeme == "=>":
        r.addToken(tkFatArrow, lexeme, startLine, startCol, startByte)
      else:
        r.addToken(tkSymbol, lexeme, startLine, startCol, startByte)

  r.addToken(tkEof, "", r.line, r.col, r.pos)

proc tokenize(r: var Reader, captureSpans: static bool = false) =
  var interpolationClosed = false
  tokenizeImpl(r, nil, interpolationClosed, captureSpans)

proc tokenizeInterpolation(r: var Reader): bool =
  var interpolationClosers: InterpolationCloserStack
  var interpolationClosed = false
  tokenizeImpl(r, addr interpolationClosers, interpolationClosed)
  interpolationClosed

proc tokenKindName*(kind: TokenKind): string =
  case kind
  of tkEof: "eof"
  of tkLParen: "l_paren"
  of tkRParen: "r_paren"
  of tkLBracket: "l_bracket"
  of tkRBracket: "r_bracket"
  of tkLBrace: "l_brace"
  of tkRBrace: "r_brace"
  of tkHashMapStart: "hash_map_start"
  of tkHashLParen: "hash_l_paren"
  of tkHashLBracket: "hash_l_bracket"
  of tkHashLBrace: "hash_l_brace"
  of tkRef: "ref"
  of tkDeref: "deref"
  of tkCaret: "caret"
  of tkCaretCaret: "caret_caret"
  of tkAt: "at"
  of tkAtAt: "at_at"
  of tkTilde: "tilde"
  of tkArrow: "arrow"
  of tkFatArrow: "fat_arrow"
  of tkDotDotDot: "dot_dot_dot"
  of tkString: "string"
  of tkBytes: "bytes"
  of tkRegex: "regex"
  of tkInt: "int"
  of tkFloat: "float"
  of tkDate: "date"
  of tkTime: "time"
  of tkDateTime: "datetime"
  of tkSymbol: "symbol"
  of tkGeneMember: "gene_member"
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
  of tkLineComment: "line_comment"
  of tkBlockComment: "block_comment"

proc lexAll*(src: string, includeEof = false, sourceName = "",
             includeTrivia = false): seq[Token] =
  ## Tokenize source into reader tokens. Ordinary comments are omitted unless
  ## `includeTrivia` is set; datum comments are always returned as the
  ## `underscore` token because they affect the parser stream.
  var r = initReader(src, sourceName, captureTrivia = includeTrivia)
  r.tokenize()
  result = r.tokens
  if not includeEof and result.len > 0 and result[^1].kind == tkEof:
    result.setLen(result.len - 1)

proc lexAllSpanned*(src: string, includeEof = false,
                    sourceName = "", includeTrivia = false): seq[SpannedToken] =
  ## Tooling token stream with exact raw byte spans. Normal semantic reads and
  ## `lexAll` retain the compact Token layout and do not write span fields.
  var r = initReader(src, sourceName, captureTrivia = includeTrivia)
  r.tokenize(captureSpans = true)
  result = r.spannedTokens
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

proc pushReadContext(r: var Reader, tok: Token) =
  let frame = ReadContextEntry(kind: tok.kind, line: tok.line, col: tok.col)
  if r.context.depth < r.context.inline.len:
    r.context.inline[r.context.depth] = frame
  else:
    r.context.overflow.add frame
  inc r.context.depth

proc restoreReadContext(r: var Reader, depth: int) =
  r.context.depth = depth
  let overflowLen = max(0, depth - r.context.inline.len)
  if r.context.overflow.len > overflowLen:
    r.context.overflow.setLen(overflowLen)

proc hasStableSourceIdentity(v: Value): bool =
  v.kind in {vkBytes, vkRegex, vkDate, vkTime, vkDateTime, vkTimezone,
             vkDuration, vkList, vkMap, vkSet, vkHashMap, vkNode, vkPipeline}

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
  r.raiseReadErrorAt(r.peek(), "property key must be a symbol")

proc qualifiedMessageSplit*(lexeme: string): int =
  ## Index of a structural `:` in `lexeme`, or -1. `:` qualifies a protocol
  ## message (`Proto:msg`, design §3) only when it is glued between two symbol
  ## characters, so the delimited uses — `x : T`, `open : alias`, `{{a : 1}}` —
  ## and a trailing `^key:` are untouched.
  result = -1
  for i in 1 ..< lexeme.len - 1:
    if lexeme[i] == ':' and lexeme[i - 1] != ':' and lexeme[i + 1] != ':':
      return i

proc dotSendPrefix(name: string): tuple[found, optional: bool, rest: string]

proc desugarPath*(lexeme: string, sourceName = "", line = 0, col = 0): Value =
  ## `sourceName`/`line`/`col` locate the diagnostic for a rejected segment;
  ## they are only read on the error path, so callers with no token in hand
  ## may leave them defaulted.
  if lexeme == "/": return newSym("/")
  # `//` is the remainder operator (design §7.4), not a selector: a selector
  # needs at least one segment, so `//` would otherwise read as the empty
  # `(select)`, which denotes nothing. Paths with an interior `//` (`a//b`)
  # keep collapsing the empty segment below.
  if lexeme == "//": return newSym("//")
  if '/' notin lexeme: return newSym(lexeme)

  let parts = lexeme.split('/')
  var body = newSeq[Value]()
  for p in parts:
    if p.len == 0: continue # leading or trailing slash
    if p.startsWith("~") or p.startsWith("?~"):
      raiseReadErrorAt(sourceName, line, col,
        "tilde message sends were removed; use '/." &
        (if p.startsWith("?~"): p[2 .. ^1] else: p[1 .. ^1]) & "'")
    let dotSend = dotSendPrefix(p)
    if dotSend.found:
      if dotSend.rest.len == 0 or dotSend.rest == "%":
        raiseReadErrorAt(sourceName, line, col,
          "message path segment requires a message name")
      body.add newSym((if dotSend.optional: "?~" else: "~") &
                      dotSend.rest)
    elif p.startsWith("%"):
      # `%x` escapes to a lexical value; `%$x` escapes to a standard-library
      # one, so `$` means `gene/` wherever a name is legal.
      let inner = p[1..^1]
      if inner.len == 0:
        # A bare `%` segment has nothing to escape to. Design §2.1 already
        # declares this short syntax invalid -- a complex stage must use the
        # `(select ...)` long form -- and accepting it is actively harmful in
        # two ways: it yields an unquoted *empty* symbol, which the printer
        # cannot write back out (`(unquote )` rereads as a body-less
        # `(unquote)`), and the following form is silently swallowed as a
        # separate argument, because `%(` ends the symbol lexeme.
        # `(!= xs/%(- i 1) "\n")` would read as a three-argument `!=` whose
        # second argument is the index expression -- a wrong program that
        # raises nothing. Checked here, inside the segment walk that already
        # exists, so no symbol token pays an extra pass over its lexeme.
        raiseReadErrorAt(sourceName, line, col,
          "'%' path segment needs a name; a computed stage must use the " &
          "long form, e.g. (select xs %stage) (design §2.1)")
      let escaped =
        if inner.startsWith("$") and inner.len > 1:
          desugarPath("gene/" & inner[1..^1], sourceName, line, col)
        else:
          newSym(inner)
      body.add newNode(newSym("unquote"), body = @[escaped])
    else:
      if p.isHexIntLexeme:
        body.add newIntFromHex(p)
      elif p.isIntLexeme:
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

type DotSendDescriptor = object
  found: bool
  optional: bool
  computed: bool
  callee: Value

proc dotSendPrefix(name: string): tuple[found, optional: bool, rest: string] =
  if name.len > 2 and name.startsWith("?."):
    return (true, true, name[2 .. ^1])
  if name.len > 1 and name[0] == '.' and not name.startsWith(".."):
    return (true, false, name[1 .. ^1])

proc stripDotQualifier(value: Value):
    tuple[found, optional: bool, qualifier: Value] =
  if value.kind == vkSymbol:
    let prefix = dotSendPrefix(value.symVal)
    if prefix.found and prefix.rest.len > 0 and prefix.rest[0] != '%':
      return (true, prefix.optional, newSym(prefix.rest))
    return
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.head.symVal == "path" and
      value.body.len > 0 and value.body[0].kind == vkSymbol:
    let name = value.body[0].symVal
    var prefix: tuple[found, optional: bool, rest: string]
    if name.len > 2 and name.startsWith("?~"):
      prefix = (true, true, name[2 .. ^1])
    elif name.len > 1 and name[0] == '~':
      prefix = (true, false, name[1 .. ^1])
    else:
      prefix = dotSendPrefix(name)
    if prefix.found and prefix.rest.len > 0 and prefix.rest[0] != '%':
      var parts = newSeq[Value](value.body.len)
      for i, part in value.body:
        parts[i] = if i == 0: newSym(prefix.rest) else: part
      return (true, prefix.optional,
              newNode(newSym("path"), body = parts))

proc dotSendDescriptor(value: Value): DotSendDescriptor =
  if value.kind == vkSymbol:
    let prefix = dotSendPrefix(value.symVal)
    if not prefix.found:
      return
    result.found = true
    result.optional = prefix.optional
    if prefix.rest == "%":
      result.computed = true
    elif prefix.rest.len > 1 and prefix.rest[0] == '%':
      let held = prefix.rest[1 .. ^1]
      let binding =
        if held.len > 1 and held[0] == '$':
          desugarPath("gene/" & held[1 .. ^1])
        else:
          newSym(held)
      result.callee = newNode(newSym("unquote"), body = @[binding])
    elif prefix.rest.len > 0:
      result.callee = newSym(prefix.rest)
    else:
      result.found = false
    return
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.head.symVal == "path" and value.body.len > 1 and
      value.body[0].kind == vkSymbol:
    let first = value.body[0].symVal
    var optional = false
    var rest: string
    if first.len > 3 and first.startsWith("?~%"):
      optional = true
      rest = first[3 .. ^1]
    elif first.len > 2 and first.startsWith("~%"):
      rest = first[2 .. ^1]
    if rest.len > 0:
      var parts: seq[Value]
      if rest.len > 1 and rest[0] == '$':
        parts.add newSym("gene")
        parts.add newSym(rest[1 .. ^1])
      else:
        parts.add newSym(rest)
      for i in 1 ..< value.body.len:
        parts.add value.body[i]
      let binding =
        if parts.len == 1: parts[0]
        else: newNode(newSym("path"), body = parts)
      result.found = true
      result.optional = optional
      result.callee = newNode(newSym("unquote"), body = @[binding])
      return
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.head.symVal == "msg" and
      value.body.len == 2 and value.body[1].kind == vkSymbol:
    let qualifier = stripDotQualifier(value.body[0])
    if qualifier.found:
      result.found = true
      result.optional = qualifier.optional
      result.callee = newNode(newSym("msg"),
        body = @[qualifier.qualifier, value.body[1]])

proc normalizeDotQualifiedPathMessage(value: Value): Value =
  ## `x/.Proto:msg` is tokenized as one qualified-message lexeme whose
  ## qualifier path contains the send marker. Split that path at the marker
  ## into receiver and protocol, then lower to the canonical send node.
  if value.kind != vkNode or value.head.kind != vkSymbol or
      value.head.symVal != "msg" or
      value.body.len != 2 or value.body[0].kind != vkNode or
      value.body[0].head.kind != vkSymbol or
      value.body[0].head.symVal != "path":
    return NIL
  let path = value.body[0].body
  var marker = -1
  var prefix: tuple[found, optional: bool, rest: string]
  for i in 1 ..< path.len:
    if path[i].kind == vkSymbol:
      let name = path[i].symVal
      var candidate: tuple[found, optional: bool, rest: string]
      if name.len > 2 and name.startsWith("?~"):
        candidate = (true, true, name[2 .. ^1])
      elif name.len > 1 and name[0] == '~':
        candidate = (true, false, name[1 .. ^1])
      else:
        candidate = dotSendPrefix(name)
      if candidate.found:
        marker = i
        prefix = candidate
        break
  if marker < 1 or prefix.rest.len == 0 or prefix.rest[0] == '%':
    return NIL
  var receiverParts = newSeq[Value](marker)
  for i in 0 ..< marker:
    receiverParts[i] = path[i]
  let receiver =
    if receiverParts.len == 1: receiverParts[0]
    else: newNode(newSym("path"), body = receiverParts)
  var qualifierParts = newSeq[Value](path.len - marker)
  qualifierParts[0] = newSym(prefix.rest)
  for i in marker + 1 ..< path.len:
    qualifierParts[i - marker] = path[i]
  let qualifier =
    if qualifierParts.len == 1: qualifierParts[0]
    else: newNode(newSym("path"), body = qualifierParts)
  let callee = newNode(newSym("msg"), body = @[qualifier, value.body[1]])
  newNode(receiver,
          body = @[newSym(if prefix.optional: "?~" else: "~"), callee])

proc normalizeDotSend*(head: Value, props: PropTable, body: seq[Value],
                       meta: PropTable, immutable: bool): Value =
  let leading = dotSendDescriptor(head)
  if leading.found:
    var args: seq[Value]
    var callee = leading.callee
    if leading.computed:
      if body.len == 0:
        raise newException(ReadError,
          "computed message send .% expects an expression")
      callee = newNode(newSym("unquote"), body = @[body[0]])
      if body.len > 1: args = body[1 .. ^1]
    else:
      args = body
    return newNode(newSym(if leading.optional: "?~" else: "~"),
                   props = props, body = @[callee] & args, meta = meta,
                   immutable = immutable)
  if body.len > 0:
    let infix = dotSendDescriptor(body[0])
    if infix.found:
      var args: seq[Value]
      var callee = infix.callee
      if infix.computed:
        if body.len < 2:
          raise newException(ReadError,
            "computed message send .% expects an expression")
        callee = newNode(newSym("unquote"), body = @[body[1]])
        if body.len > 2: args = body[2 .. ^1]
      elif body.len > 1:
        args = body[1 .. ^1]
      return newNode(head, props = props,
                     body = @[newSym(if infix.optional: "?~" else: "~"),
                              callee] & args,
                     meta = meta, immutable = immutable)
  newNode(head, props, body, meta, immutable)

proc finishNodeSegment(head: Value, props: PropTable, body: seq[Value],
                       meta: PropTable, immutable: bool): Value =
  # Dot send syntax lowers to the existing canonical send node. Dispatch,
  # protocol resolution, TCO, and tooling consume one representation.
  normalizeDotSend(head, props, body, meta, immutable)

proc finishPipelineInitial(r: var Reader, head: Value, props: PropTable,
                           body: seq[Value], meta: PropTable,
                           tok: Token): Value =
  ## The incoming value is a single form, never an implicitly wrapped segment.
  ## `(a b -> f c)` would have to guess that `a b` means `(a b)`, which reads
  ## as a call the author never wrote; the explicit `((a b) -> f c)` says it.
  if body.len > 0 or props.len > 0 or meta.len > 0:
    r.raiseReadErrorAt(tok,
      "the value before '" & tok.lexeme & "' must be a single form; " &
      "wrap the call in its own parentheses")
  head

proc isDirectPipelineSlot(value: Value): bool =
  value.kind == vkSymbol and value.symVal == "_"

proc detectPipelineSlot*(head: Value, props: PropTable,
                         body: openArray[Value]): tuple[
                           slot: PipelineSlot, count: int] =
  result.slot = PipelineSlot(kind: pskDefault, index: -1)
  if head.isDirectPipelineSlot:
    result.slot = PipelineSlot(kind: pskHead, index: -1)
    inc result.count
  for i, item in body:
    if item.isDirectPipelineSlot:
      result.slot = PipelineSlot(kind: pskBody, index: i)
      inc result.count
  for name, value in props:
    if value.isDirectPipelineSlot:
      result.slot = PipelineSlot(kind: pskProp, index: -1, name: name)
      inc result.count

proc finishPipelineStage(r: var Reader, kind: PipelineStageKind,
                         head: Value, props: PropTable,
                         body: seq[Value], meta: PropTable,
                         loc: SourceLoc): PipelineStage =
  let detected = detectPipelineSlot(head, props, body)
  if detected.count > 1:
    raiseReadErrorAt(r.sourceName, loc.line, loc.col,
      "a pipeline stage accepts at most one direct '_' slot")
  PipelineStage(kind: kind, head: head, props: props, body: body, meta: meta,
                sourceLoc: loc, slot: detected.slot)

proc materializePipelineStage*(stage: PipelineStage, replacement: Value,
                               immutable = false): Value =
  let head =
    if stage.slot.kind == pskHead: replacement
    else: stage.head
  var props = initPropTable()
  for name, value in stage.props:
    if stage.slot.kind == pskProp and name == stage.slot.name:
      props[name] = replacement
    else:
      props[name] = value
  var body = newSeqOfCap[Value](stage.body.len +
    (if stage.slot.kind == pskDefault: 1 else: 0))
  if stage.slot.kind == pskDefault:
    body.add replacement
  for i, item in stage.body:
    if stage.slot.kind == pskBody and i == stage.slot.index:
      body.add replacement
    else:
      body.add item
  var meta = initPropTable()
  for name, value in stage.meta:
    meta[name] = value
  normalizeDotSend(head, props, body, meta, immutable)

proc geneMemberPath*(name: string): Value =
  ## `$name`, the reader's spelling for a `gene` root member (design §2.1).
  newNode(newSym("path"), body = @[newSym("gene"), newSym(name)])

proc materializeIterateStage*(stage: PipelineStage, receiver: Value,
                              itemName: string, immutable = false): Value =
  ## `=>` runs its stage once per item and answers in the incoming kind, which
  ## is exactly the `map` generic of design §6.2: a `List` answers a `List`, a
  ## `Stream` stays lazy, and a user type joins by declaring the message. The
  ## per-item call is an ordinary `->` stage whose slot holds the item.
  let item = newSym(itemName)
  let call = materializePipelineStage(stage, item, immutable)
  let callback = newNode(newSym("fn"), body = @[newList(@[item]), call])
  newNode(geneMemberPath("map"), body = @[receiver, callback])

proc isSpreadNode(value: Value): bool =
  value.kind == vkNode and value.head.kind == vkSymbol and
    value.head.symVal == "..." and value.body.len == 1 and
    value.props.len == 0 and value.meta.len == 0

proc needsIterateHoist(value: Value): bool =
  ## An `=>` stage evaluates its callee and arguments once, before iterating,
  ## so anything with its own evaluation is lifted out of the callback. Symbols
  ## and literals stay inline: a symbol load is idempotent and keeping it in
  ## place preserves head dispatch for `+`, a known function, and a `.message`
  ## descriptor.
  case value.kind
  of vkNode: not value.isSpreadNode
  of vkPipeline, vkList, vkMap, vkSet, vkHashMap: true
  else: false

proc hoistIterateStage*(stage: PipelineStage, freshName: proc(): string):
    tuple[stage: PipelineStage, hoisted: seq[(string, Value)]] =
  ## Replace every separately evaluated stage component with a name bound once
  ## outside the callback. `hoisted` lists those bindings in evaluation order.
  var lifted: seq[(string, Value)]

  proc lift(value: Value): Value =
    if value.isSpreadNode:
      # The spread itself is call syntax, so only its operand is lifted.
      let inner = lift(value.body[0])
      if inner.bits == value.body[0].bits: return value
      return newNode(value.head, body = @[inner])
    if not value.needsIterateHoist: return value
    let name = freshName()
    lifted.add (name, value)
    newSym(name)

  result.stage = stage
  if stage.slot.kind != pskHead:
    result.stage.head = lift(stage.head)
  result.stage.props = initPropTable()
  for key, value in stage.props:
    result.stage.props[key] =
      if stage.slot.kind == pskProp and key == stage.slot.name: value
      else: lift(value)
  result.stage.body = @[]
  for i, value in stage.body:
    result.stage.body.add(
      if stage.slot.kind == pskBody and i == stage.slot.index: value
      else: lift(value))
  result.hoisted = lifted

proc parseNode(r: var Reader, closing: TokenKind, immutable = false): Value =
  var head = NIL
  var props = initPropTable()
  var meta = initPropTable()
  var body = newSeq[Value]()

  var first = true
  var inPipe = false
  var inPipeline = false
  var pipelineInitial = NIL
  var pipelineStages: seq[PipelineStage]
  var pendingStageKind = pstCall
  var segmentLoc = SourceLoc()
  while true:
    r.skipDatumComments()
    let k = r.peekKind()
    if k == closing or k == tkEof: break
    let tok = r.peek()
    case tok.kind
    of tkCaret, tkCaretCaret:
      if not segmentLoc.hasSourceLoc:
        segmentLoc = sourceLoc(tok, r.sourceName)
      discard r.next()
      let keyTok = r.peek()
      let key = r.parsePropKey()
      var val: Value
      if tok.kind == tkCaretCaret:
        val = TRUE
      else:
        let afterKey = r.peekKind()
        if afterKey in {closing, tkRParen, tkRBracket, tkRBrace, tkEof,
                        tkCaret, tkCaretCaret, tkAt, tkAtAt, tkComma, tkSemi,
                        tkTilde, tkArrow, tkFatArrow}:
          r.raiseReadErrorAt(keyTok,
            "property '^" & key & "' requires a value")
        val = r.parseForm()
      if r.options.rejectDuplicateProps and props.hasKey(key):
        r.raiseReadErrorAt(keyTok, "duplicate property '^" & key & "'")
      props[key] = val
    of tkAt, tkAtAt:
      if not segmentLoc.hasSourceLoc:
        segmentLoc = sourceLoc(tok, r.sourceName)
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
        let keyTok = r.peek()
        let key = r.parsePropKey()
        var val: Value
        if tok.kind == tkAtAt:
          val = TRUE
        else:
          let afterKey = r.peekKind()
          if afterKey in {closing, tkRParen, tkRBracket, tkRBrace, tkEof,
                          tkCaret, tkCaretCaret, tkAt, tkAtAt, tkComma, tkSemi,
                          tkTilde, tkArrow, tkFatArrow}:
            r.raiseReadErrorAt(keyTok,
              "meta property '@" & key & "' requires a value")
          val = r.parseForm()
        if r.options.rejectDuplicateProps and meta.hasKey(key):
          r.raiseReadErrorAt(keyTok, "duplicate meta property '@" & key & "'")
        meta[key] = val
    of tkSemi:
      # Pipe folding: (a; b) folds to ((a) b)
      if inPipeline:
        r.raiseReadErrorAt(tok,
          "cannot mix ';' head folding and '->'/'=>' value pipelines in one " &
          "form; nest one operation in its own parentheses")
      discard r.next()
      if first:
        r.raiseReadErrorAt(tok, "';' requires a preceding segment")
      let prevNode = finishNodeSegment(head, props, body, meta, immutable)
      head = prevNode
      props = initPropTable()
      meta = initPropTable()
      body = @[]
      segmentLoc = SourceLoc()
      first = false
      inPipe = true
    of tkArrow, tkFatArrow:
      if inPipe:
        r.raiseReadErrorAt(tok,
          "cannot mix ';' head folding and '->'/'=>' value pipelines in one " &
          "form; nest one operation in its own parentheses")
      if first:
        r.raiseReadErrorAt(tok,
          "'" & tok.lexeme & "' requires a preceding pipeline segment")
      discard r.next()
      if not inPipeline:
        pipelineInitial = r.finishPipelineInitial(
          head, props, body, meta, tok)
        inPipeline = true
      else:
        pipelineStages.add r.finishPipelineStage(
          pendingStageKind, head, props, body, meta, segmentLoc)
      pendingStageKind =
        if tok.kind == tkFatArrow: pstIterate else: pstCall
      head = NIL
      props = initPropTable()
      meta = initPropTable()
      body = @[]
      segmentLoc = SourceLoc()
      first = true
    of tkComma:
      discard r.next()
    else:
      if not segmentLoc.hasSourceLoc:
        segmentLoc = sourceLoc(tok, r.sourceName)
      let form = r.parseForm()
      if first:
        head = form
        first = false
      else:
        body.add form

  if r.peekKind() == tkEof:
    r.raiseReadIncomplete("unexpected EOF: unclosed '('")
  discard r.next()

  if inPipeline:
    if first:
      r.raiseReadError("a value pipeline requires a stage after its last " &
        "'->' or '=>'")
    pipelineStages.add r.finishPipelineStage(
      pendingStageKind, head, props, body, meta, segmentLoc)
    result = newPipeline(pipelineInitial, pipelineStages, immutable)
  elif inPipe:
    result = finishNodeSegment(head, props, body, meta, immutable)
  else:
    result = finishNodeSegment(head, props, body, meta, immutable)

proc parseMap(r: var Reader, closing: TokenKind, immutable = false): Value =
  var items = initPropTable()
  while true:
    r.skipDatumComments()
    let k = r.peekKind()
    if k == closing or k == tkEof: break
    let tok = r.peek()
    if tok.kind notin {tkCaret, tkCaretCaret}:
      r.raiseReadErrorAt(tok,
        "prop map entries must start with '^' or '^^'")
    discard r.next()
    let keyTok = r.peek()
    let key = r.parsePropKey()
    if tok.kind == tkCaretCaret:
      # `^^k` is true-flag sugar, same as in node props; it consumes no value.
      if r.options.rejectDuplicateProps and items.hasKey(key):
        r.raiseReadErrorAt(keyTok, "duplicate map property '^" & key & "'")
      items[key] = TRUE
      if r.peekKind() == tkComma: discard r.next()
      continue
    var val: Value
    if r.peekKind() == tkColon:
      discard r.next()
    let afterKey = r.peekKind()
    if afterKey in {closing, tkRParen, tkRBracket, tkRBrace, tkEof,
                    tkCaret, tkCaretCaret, tkAt, tkAtAt, tkComma, tkSemi}:
      r.raiseReadErrorAt(keyTok,
        "map property '^" & key & "' requires a value")
    val = r.parseForm()
    if r.options.rejectDuplicateProps and items.hasKey(key):
      r.raiseReadErrorAt(keyTok, "duplicate map property '^" & key & "'")
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

proc interpolationExpressionEnd(lexeme, sourceName: string,
                              start, line, col: int): int =
  ## `start` points at the opening `{` or `(`.  Re-lexing this suffix makes
  ## strings, regexes, comments, and nested delimiters opaque to delimiter
  ## matching, unlike character-by-character scanning of the cooked string.
  # Boundary scanning needs lexer state only. Avoid initReader's eager token
  # buffer: interpolation mode neither materializes nor parses these tokens.
  var expressionReader = Reader(
    src: lexeme, sourceName: sourceName, pos: start, line: 1, col: start + 1)
  if not expressionReader.tokenizeInterpolation():
    raiseReadIncompleteAt(sourceName, line, col,
      "unterminated interpolation '" & $lexeme[start] & "...'")
  expressionReader.pos

proc parseInterpolatedString(lexeme, sourceName: string,
                             line, col: int,
                             options: ReadOptions = ReadOptions()): Value =
  var body = newSeq[Value]()
  var i = 0
  var last = 0
  while i < lexeme.len:
    if lexeme[i..^1].startsWith("${"):
      if i > last: body.add newStr(lexeme[last ..< i])
      let start = i + 1
      i = interpolationExpressionEnd(lexeme, sourceName, start, line, col)
      let exprStr = lexeme[start + 1 ..< i - 1]
      body.add read(exprStr, sourceName, options)
      last = i
    elif lexeme[i..^1].startsWith("$("):
      if i > last: body.add newStr(lexeme[last ..< i])
      let start = i + 1
      i = interpolationExpressionEnd(lexeme, sourceName, start, line, col)
      let exprStr = lexeme[start ..< i]
      body.add read(exprStr, sourceName, options)
      last = i
    else:
      inc i
  if last < lexeme.len: body.add newStr(lexeme[last..^1])
  newNode(newSym("$"), body = body)

proc parseForm(r: var Reader, inList = false): Value =
  r.skipDatumComments()
  let tok = r.next()
  if r.options.maxDepth > 0 and r.parseDepth > r.options.maxDepth:
    r.raiseReadErrorAt(tok, "reader max_depth exceeded (" &
                       $r.options.maxDepth & ")")
  let contextDepth = r.context.depth
  inc r.parseDepth
  defer:
    dec r.parseDepth
    if r.context.depth != contextDepth:
      r.restoreReadContext(contextDepth)
  template finish(value: Value): untyped =
    let parsed = value
    r.recordSourceLoc(parsed, tok)
    return parsed
  case tok.kind
  of tkInt:
    if tok.lexeme.isHexIntLexeme:
      finish newIntFromHex(tok.lexeme)
    finish newIntFromDecimal(tok.lexeme)
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
      if lex == "?~":
        r.raiseReadErrorAt(tok,
          "'?~' message sends were removed; use '?.message'")
      let colonAt = qualifiedMessageSplit(lex)
      if colonAt > 0 and '/' notin lex[colonAt + 1 .. ^1]:
        # `Proto:msg` names a message. This is its own node, not `(path P m)`:
        # `/` selects a member and `:` names a message, and the two have to be
        # told apart to give a message value in *value* position a different
        # compilation from a member selection (design §3, decisions 2/4/5).
        # The qualifier may itself be a path: `ns/Proto:msg` names the message
        # `msg` of the protocol reached at `ns/Proto`. Only the last segment is
        # the message name, so `:` still splits exactly once.
        let message = newNode(newSym("msg"),
          body = @[desugarPath(lex[0 ..< colonAt], r.sourceName,
                               tok.line, tok.col),
                   newSym(lex[colonAt + 1 .. ^1])])
        let pathSend = normalizeDotQualifiedPathMessage(message)
        finish (if pathSend.kind == vkNil: message else: pathSend)
      if not inList:
        if lex.endsWith("..."):
          finish newNode(newSym("..."),
                         body = @[desugarPath(lex[0..^4], r.sourceName,
                                              tok.line, tok.col)])
        finish desugarPath(lex, r.sourceName, tok.line, tok.col)
      else: finish newSym(lex)
  of tkGeneMember:
    # `$x` / `$str/join` select from the `gene` root, which cannot be shadowed.
    if tok.lexeme.endsWith("..."):
      finish newNode(newSym("..."),
                     body = @[desugarPath("gene/" & tok.lexeme[0..^4],
                                          r.sourceName, tok.line, tok.col)])
    finish desugarPath("gene/" & tok.lexeme, r.sourceName, tok.line, tok.col)
  of tkRef, tkDeref:
    let nameTok = r.next()
    if nameTok.kind == tkEof:
      r.raiseReadIncomplete("unexpected end of input")
    var validName = nameTok.kind == tkSymbol and nameTok.lexeme.len > 0 and
      nameTok.lexeme[0] in {'a'..'z', '_'}
    if validName:
      for c in nameTok.lexeme:
        if c notin {'a'..'z', '0'..'9', '_'}:
          validName = false
          break
    if not validName:
      r.raiseReadErrorAt(nameTok,
        tok.lexeme & " name must be a simple snake_case symbol")
    let name = newSym(nameTok.lexeme)
    if tok.kind == tkRef:
      let value = r.parseForm(inList = inList)
      finish newNode(newSym("#Ref"), body = @[name, value])
    finish newNode(newSym("#Deref"), body = @[name])
  of tkLParen:
    r.pushReadContext(tok)
    finish r.parseNode(tkRParen)
  of tkLBracket:
    r.pushReadContext(tok)
    finish r.parseList(tkRBracket)
  of tkLBrace:
    r.pushReadContext(tok)
    finish r.parseMap(tkRBrace)
  of tkHashMapStart:
    r.pushReadContext(tok)
    finish r.parseHashMap()
  of tkHashLParen:
    r.pushReadContext(tok)
    finish r.parseNode(tkRParen, immutable = true)
  of tkHashLBracket:
    r.pushReadContext(tok)
    finish r.parseList(tkRBracket, immutable = true)
  of tkHashLBrace:
    r.pushReadContext(tok)
    finish r.parseMap(tkRBrace, immutable = true)
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
  of tkTilde:
    r.raiseReadErrorAt(tok,
      "spaced '~' has no meaning; '->' is the value-pipeline delimiter and " &
      "'.message' is the send surface")
  of tkArrow, tkFatArrow:
    r.raiseReadErrorAt(tok,
      "'" & tok.lexeme & "' is a value-pipeline delimiter and is only valid " &
      "between segments of one parenthesized form")
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
  # Moved, not copied: `initReader` already took a copy of the text and the
  # reader is finished with it here, so carrying the source on the unit costs
  # nothing beyond the copy the read already paid for. Assigning `src` instead
  # measured a consistent ~2.3% loss on `reader.web_demo.read_all`.
  result.source = move(r.src)

proc readAll*(src: string, sourceName = "",
              options: ReadOptions = ReadOptions()): seq[Value] =
  ## Read all top-level forms from src (program = { form }).
  readAllWithLocs(src, sourceName, options).forms
