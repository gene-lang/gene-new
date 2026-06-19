## Lexer & core parser for Gene (design §2.2)
import std/[strutils, unicode, tables, parseutils]
import ./types

type
  TokenKind* = enum
    tkEof,
    tkLParen, tkRParen,      # ( )
    tkLBracket, tkRBracket,  # [ ]
    tkLBrace, tkRBrace,      # { }
    tkHashLParen,            # #(
    tkHashLBracket,          # #[
    tkHashLBrace,            # #{
    tkCaret, tkCaretCaret,   # ^ ^^
    tkAt, tkAtAt,            # @ @@
    tkTilde,                 # ~
    tkDotDotDot,             # ...
    tkString, tkInt, tkFloat, tkSymbol, tkChar,
    tkComma, tkColon, tkEqual, tkSemi, tkSlash, tkPercent,
    tkBacktick, tkDollar, tkUnderscore

  Token* = object
    kind*: TokenKind
    lexeme*: string
    line*, col*: int

  Reader* = object
    src*: string
    pos*: int
    line*, col*: int
    tokens: seq[Token]
    tokIdx: int

  ReadError* = object of CatchableError

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

proc initReader(src: string): Reader =
  Reader(src: src, line: 1, col: 1,
         tokens: newSeqOfCap[Token](min(src.len + 1, 4096)))

proc isSymbolChar(c: char): bool =
  c notin {'(', ')', '[', ']', '{', '}', ' ', '\t', '\n', '\r', ',', ';', '\"', '\'', '`', '#'}

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
      raise newException(ReadError, "unterminated Unicode character escape")
    let value = hexValue(r.nextChar())
    if value < 0:
      raise newException(ReadError, "invalid Unicode character escape")
    code = code * 16 + value
    r.advance()
  if not isUnicodeScalar(code):
    raise newException(ReadError, "Unicode character escape is not a scalar value")
  Rune(int32(code))

proc parseBracedUnicodeEscape(r: var Reader): Rune =
  r.advance() # consume {
  var code = 0
  var digits = 0
  while r.pos < r.src.len and r.nextChar() != '}':
    let value = hexValue(r.nextChar())
    if value < 0:
      raise newException(ReadError, "invalid Unicode character escape")
    code = code * 16 + value
    digits += 1
    if digits > 6:
      raise newException(ReadError, "Unicode character escape is too large")
    r.advance()
  if r.pos >= r.src.len or r.nextChar() != '}':
    raise newException(ReadError, "unterminated Unicode character escape")
  r.advance() # consume }
  if digits == 0 or not isUnicodeScalar(code):
    raise newException(ReadError, "Unicode character escape is not a scalar value")
  Rune(int32(code))

proc parseCharEscape(r: var Reader): Rune =
  if r.pos >= r.src.len:
    raise newException(ReadError, "unterminated character literal")
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
    raise newException(ReadError, "unknown character escape")

proc parseCharLiteral(r: var Reader): string =
  r.advance() # consume opening '
  if r.pos >= r.src.len:
    raise newException(ReadError, "unterminated character literal")
  if r.nextChar() == '\'':
    raise newException(ReadError, "empty character literal")

  let ch =
    if r.nextChar() == '\\':
      r.advance()
      r.parseCharEscape()
    else:
      if r.nextChar() in {'\n', '\r'}:
        raise newException(ReadError, "unterminated character literal")
      let width = runeLenAt(r.src, r.pos)
      let decoded = runeAt(r.src, r.pos)
      r.advanceBytes(width)
      decoded

  if r.pos >= r.src.len or r.nextChar() != '\'':
    raise newException(ReadError, "character literal must contain one Unicode scalar value")
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
          raise newException(ReadError, "unterminated block comment")
      else:
        # Line comment
        while r.pos < r.src.len and r.nextChar() != '\n':
          r.advance()
    of '(': r.advance(); r.tokens.add Token(kind: tkLParen, lexeme: "(", line: startLine, col: startCol)
    of ')': r.advance(); r.tokens.add Token(kind: tkRParen, lexeme: ")", line: startLine, col: startCol)
    of '[': r.advance(); r.tokens.add Token(kind: tkLBracket, lexeme: "[", line: startLine, col: startCol)
    of ']': r.advance(); r.tokens.add Token(kind: tkRBracket, lexeme: "]", line: startLine, col: startCol)
    of '{': r.advance(); r.tokens.add Token(kind: tkLBrace, lexeme: "{", line: startLine, col: startCol)
    of '}': r.advance(); r.tokens.add Token(kind: tkRBrace, lexeme: "}", line: startLine, col: startCol)
    of ',': r.advance(); r.tokens.add Token(kind: tkComma, lexeme: ",", line: startLine, col: startCol)
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
      var triple = false
      if r.src.continuesWith("\"\"", r.pos):
        triple = true
        r.advance(); r.advance()
        var closed = false
        while r.pos < r.src.len:
          if r.src.continuesWith("\"\"\"", r.pos):
            r.advance(); r.advance(); r.advance()
            closed = true
            break
          lexeme.add r.nextChar()
          r.advance()
        if not closed:
          raise newException(ReadError, "unterminated triple-quoted string literal")
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
            let esc = r.nextChar()
            case esc
            of 'n': lexeme.add '\n'
            of 'r': lexeme.add '\r'
            of 't': lexeme.add '\t'
            of '\\': lexeme.add '\\'
            of '\"': lexeme.add '\"'
            else: lexeme.add esc
            r.advance()
          else:
            lexeme.add c2
            r.advance()
        if not closed:
          raise newException(ReadError, "unterminated string literal")

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
      # Atoms: numbers, symbols
      let start = r.pos
      while r.pos < r.src.len and isSymbolChar(r.nextChar()):
        r.advance()
      let lexeme = r.src[start ..< r.pos]
      
      if lexeme.len == 0:
        r.advance() # Should not happen with isSymbolChar
        continue

      # Check if it's a number
      var valFloat: float
      if lexeme.isIntLexeme:
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
  of tkInt: "int"
  of tkFloat: "float"
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

proc lexAll*(src: string, includeEof = false): seq[Token] =
  ## Tokenize source into significant reader tokens. Whitespace and ordinary
  ## comments are spacing and are not returned; datum comments are returned as
  ## the `underscore` token because they affect the parser stream.
  var r = initReader(src)
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

proc skipDatumComments(r: var Reader) =
  ## Datum comments (`#_`) are spacing (design §2.2 `datum_comment`): each `#_`
  ## discards the following form and yields no AST node. Runs of `#_` stack,
  ## since `parseForm` itself skips leading datum comments before its datum.
  while r.peekKind() == tkUnderscore:
    discard r.next()
    if r.peekKind() in {tkEof, tkRParen, tkRBracket, tkRBrace}:
      raise newException(ReadError, "#_ datum comment requires a following form")
    discard r.parseForm()

proc parsePropKey(r: var Reader): string =
  r.skipDatumComments()
  if r.peekKind() == tkSymbol:
    let idx = r.tokIdx
    r.tokIdx += 1
    return internName(r.tokens[idx].lexeme)
  let keyForm = r.parseForm()
  if keyForm.kind == vkSymbol: keyForm.symVal else: ""

proc desugarPath(lexeme: string): Value =
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
    raise newException(ReadError, "unexpected EOF: unclosed '['")
  discard r.next() # consume closing
  result = newList(items, immutable)

proc parseNode(r: var Reader, closing: TokenKind, immutable = false): Value =
  var head = NIL
  var props = initOrderedTable[string, Value]()
  var meta = initOrderedTable[string, Value]()
  var body = newSeq[Value]()

  var first = true
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
      let prevNode = newNode(head, props, body, meta, immutable)
      head = prevNode
      props = initOrderedTable[string, Value]()
      meta = initOrderedTable[string, Value]()
      body = @[]
      first = false
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
    raise newException(ReadError, "unexpected EOF: unclosed '('")
  discard r.next()

  # Flipped call sugar: (x ~ f a) -> (f x a)
  if body.len > 0 and body[0].kind == vkSymbol and body[0].symVal == "~":
    # (head ~ f b1 b2 ...)
    if body.len >= 2:
      let f = body[1]
      let args = @[head] & body[2..^1]
      result = newNode(f, props, args, meta, immutable)
    else:
      result = newNode(head, props, body, meta, immutable)
  elif head.kind == vkSymbol and head.symVal == "~":
    # Keep omitted-self flipped calls distinct; the compiler inserts `self`
    # only when that lexical binding is available.
    result = newNode(head, props, body, meta, immutable)
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
    var val: Value = NIL
    if r.peekKind() == tkColon:
      discard r.next()
    let afterKey = r.peekKind()
    if afterKey != closing and afterKey != tkComma:
      val = r.parseForm()
    items[key] = val
    if r.peekKind() == tkComma: discard r.next()
  if r.peekKind() == tkEof:
    raise newException(ReadError, "unexpected EOF: unclosed '{'")
  discard r.next()
  result = newMap(items, immutable)

proc read*(src: string): Value

proc parseInterpolatedString(lexeme: string): Value =
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
        raise newException(ReadError, "unterminated interpolation '${...}'")
      let exprStr = lexeme[start ..< i-1]
      body.add read(exprStr)
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
        raise newException(ReadError, "unterminated interpolation '$(...)'")
      let exprStr = lexeme[start ..< i]
      body.add read(exprStr)
      last = i
    else: i += 1
  if last < lexeme.len: body.add newStr(lexeme[last..^1])
  return newNode(newSym("$"), body = body)

proc parseForm(r: var Reader, inList = false): Value =
  r.skipDatumComments()
  let tok = r.next()
  case tok.kind
  of tkInt: return newIntFromDecimal(tok.lexeme)
  of tkFloat: return newFloat(parseFloat(tok.lexeme))
  of tkString: return newStr(tok.lexeme)
  of tkChar: return newChar(runeAt(tok.lexeme, 0))
  of tkSymbol:
    case tok.lexeme
    of "true": return TRUE
    of "false": return FALSE
    of "nil": return NIL
    of "void": return VOID
    else:
      let lex = tok.lexeme
      if not inList:
        if lex.endsWith("..."):
          return newNode(newSym("..."), body = @[desugarPath(lex[0..^4])])
        return desugarPath(lex)
      else: return newSym(lex)
  of tkLParen: return r.parseNode(tkRParen)
  of tkLBracket: return r.parseList(tkRBracket)
  of tkLBrace: return r.parseMap(tkRBrace)
  of tkHashLParen: return r.parseNode(tkRParen, immutable = true)
  of tkHashLBracket: return r.parseList(tkRBracket, immutable = true)
  of tkHashLBrace: return r.parseMap(tkRBrace, immutable = true)
  of tkBacktick:
    let inner = r.parseForm(inList)
    return newNode(newSym("quasiquote"), body = @[inner])
  of tkPercent:
    # Inside a vector the flat token stream is preserved verbatim.
    if inList: return newSym("%")
    let inner = r.parseForm(inList = false)
    return newNode(newSym("unquote"), body = @[inner])
  of tkCaret: return newSym("^")
  of tkCaretCaret: return newSym("^^")
  of tkAt: return newSym("@")
  of tkAtAt: return newSym("@@")
  of tkColon: return newSym(":")
  of tkEqual: return newSym("=")
  of tkComma: return newSym(",")
  of tkTilde: return newSym("~")
  of tkDotDotDot: return newSym("...")
  of tkDollar:
    if r.peekKind() == tkString:
      let s = r.next()
      return parseInterpolatedString(s.lexeme)
    return newSym("$")
  of tkRParen, tkRBracket, tkRBrace:
    raise newException(ReadError, "unexpected closing delimiter '" & tok.lexeme & "'")
  of tkEof:
    raise newException(ReadError, "unexpected end of input")
  else: return NIL

proc read*(src: string): Value =
  var r = initReader(src)
  r.tokenize()
  r.skipDatumComments()
  if r.peekKind() == tkEof: return NIL
  return r.parseForm(inList = false)

proc readAll*(src: string): seq[Value] =
  ## Read all top-level forms from src (program = { form }).
  var r = initReader(src)
  r.tokenize()
  while true:
    r.skipDatumComments()
    if r.peekKind() == tkEof: break
    result.add r.parseForm(inList = false)
