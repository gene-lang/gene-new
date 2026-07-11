## LSP document analysis for Gene (docs/lsp.md).
##
## Pure functions from source text to LSP-shaped data: parse diagnostics,
## a hierarchical document-symbol tree, and a flat definition index used by
## go-to-definition / hover / workspace-symbol. Uses the real reader
## (`readAllWithLocs`), so positions come from the tokenizer, not regexes:
## `formLocs` positions every top-level form and `locs` positions every
## nested heap value (nodes, lists), which covers all declaration forms.
##
## Coordinate systems: the reader reports 1-based line and 1-based BYTE
## column; LSP wants 0-based line and 0-based UTF-16 code-unit column.
## Conversions live here so the server never sees reader coordinates.

import std/[strutils, tables, unicode]
import ../reader, ../types

const
  # LSP SymbolKind constants (the protocol's numeric encoding).
  skModule* = 2
  skNamespace* = 3
  skClass* = 5
  skMethod* = 6
  skEnum* = 10
  skInterface* = 11
  skFunction* = 12
  skVariable* = 13
  skConstructor* = 9
  skEnumMember* = 22
  skObject* = 19

type
  LspPos* = object
    line*: int        ## 0-based
    character*: int   ## 0-based UTF-16 code units

  LspRange* = object
    start*: LspPos
    endPos*: LspPos

  LspDiagnostic* = object
    message*: string
    range*: LspRange

  DocSymbol* = object
    name*: string
    detail*: string
    kind*: int
    range*: LspRange          ## whole form
    selectionRange*: LspRange ## the declared name token
    children*: seq[DocSymbol]

  FlatDef* = object
    name*: string
    containerName*: string
    kind*: int
    range*: LspRange
    selectionRange*: LspRange
    signature*: string        ## first source line of the form, for hover

  DocAnalysis* = object
    parsed*: bool             ## false => parse error; symbols may be empty
    diagnostics*: seq[LspDiagnostic]
    symbols*: seq[DocSymbol]

# ---------------------------------------------------------------------------
# Position conversion
# ---------------------------------------------------------------------------

proc lineStarts*(src: string): seq[int] =
  ## Byte offset of the start of each line (line 0 at offset 0).
  result = @[0]
  for i in 0 ..< src.len:
    if src[i] == '\n':
      result.add i + 1

proc lineSlice(src: string, starts: seq[int], line0: int): string =
  if line0 < 0 or line0 >= starts.len:
    return ""
  let first = starts[line0]
  var last = if line0 + 1 < starts.len: starts[line0 + 1] - 1 else: src.len
  if last > first and last - 1 < src.len and last - 1 >= 0 and
      src[last - 1] == '\r':
    dec last
  if last < first:
    last = first
  src[first ..< last]

proc byteColToUtf16*(lineText: string, byteCol0: int): int =
  ## 0-based byte column within a line -> 0-based UTF-16 code units.
  var bytePos = 0
  var units = 0
  for rune in lineText.runes:
    if bytePos >= byteCol0:
      break
    bytePos += rune.toUTF8.len
    units += (if rune.int32 > 0xFFFF'i32: 2 else: 1)
  units

proc utf16ColToByte*(lineText: string, utf16Col: int): int =
  ## 0-based UTF-16 code units -> 0-based byte column within a line.
  var bytePos = 0
  var units = 0
  for rune in lineText.runes:
    if units >= utf16Col:
      break
    bytePos += rune.toUTF8.len
    units += (if rune.int32 > 0xFFFF'i32: 2 else: 1)
  bytePos

proc toLspPos*(src: string, starts: seq[int], line1, col1: int): LspPos =
  ## Reader (1-based line, 1-based byte col) -> LSP position.
  let line0 = max(line1 - 1, 0)
  LspPos(line: line0,
         character: byteColToUtf16(lineSlice(src, starts, line0),
                                   max(col1 - 1, 0)))

proc byteOffset*(starts: seq[int], line1, col1: int): int =
  ## Reader position -> absolute byte offset.
  let line0 = max(line1 - 1, 0)
  if line0 >= starts.len:
    return (if starts.len > 0: starts[^1] else: 0)
  starts[line0] + max(col1 - 1, 0)

proc offsetToLspPos*(src: string, starts: seq[int], offset: int): LspPos =
  var line0 = 0
  for i in countdown(starts.high, 0):
    if starts[i] <= offset:
      line0 = i
      break
  LspPos(line: line0,
         character: byteColToUtf16(lineSlice(src, starts, line0),
                                   offset - starts[line0]))

proc lspPosToOffset*(src: string, starts: seq[int], pos: LspPos): int =
  if pos.line < 0 or pos.line >= starts.len:
    return src.len
  starts[pos.line] + utf16ColToByte(lineSlice(src, starts, pos.line),
                                    pos.character)

# ---------------------------------------------------------------------------
# Raw-text scanning (form extents and name tokens). The scanner respects the
# reader's lexical surface: line comments (# ...), nested block comments
# (#< ... >#), strings ("...", """...""", $"..."), and regex literals (#"...").
# ---------------------------------------------------------------------------

proc skipString(src: string, start: int): int =
  ## `start` is at the opening quote. Returns the offset just past the close.
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
    of '\\':
      i += 2
    of '"':
      return i + 1
    else:
      inc i
  src.len

const symbolStop = {'(', ')', '[', ']', '{', '}', ' ', '\t', '\n', '\r',
                    ',', ';', '"', '\'', '`', '#'}

proc charLiteralEnd(src: string, start: int): int =
  ## `start` is at a `'`. Gene's `'` exclusively introduces a char literal
  ## ('a', '\n', '\u{1F600}'). Returns the offset just past the closing
  ## quote, or -1 when this is not a well-formed char literal.
  var i = start + 1
  if i >= src.len or src[i] in {'\n', '\r', '\''}:
    return -1
  if src[i] == '\\':
    inc i
    var guard = 0
    while i < src.len and guard < 12:
      if src[i] == '\'':
        return i + 1
      if src[i] in {'\n', '\r'}:
        return -1
      inc i
      inc guard
    return -1
  i += runeLenAt(src, i)
  if i < src.len and src[i] == '\'':
    return i + 1
  -1

proc bytesLiteralEnd(src: string, start: int): int =
  ## `start` is at a `0`. Bytes literals are 0!binary / 0xhex / 0#base64
  ## (src/gene/reader.nim tryScanBytesLexeme). Returns the offset past the
  ## token, or -1 when this is not a bytes literal. Without this, the `#` of
  ## a base64 literal would read as a line comment and swallow the rest of
  ## the line, corrupting form ranges.
  if start + 2 >= src.len or src[start] != '0':
    return -1
  let prefix = src[start + 1]
  let digitOk =
    case prefix
    of '!': src[start + 2] in {'0', '1'}
    of 'x': src[start + 2] in {'0'..'9', 'a'..'f', 'A'..'F'}
    of '#': src[start + 2] in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}
    else: false
  if not digitOk:
    return -1
  var i = start + 2
  while i < src.len and src[i] notin symbolStop:
    inc i
  i

proc skipCommentOrAtom(src: string, i: var int): bool =
  ## If `i` sits at a comment or string-ish atom (strings, regexes, char and
  ## bytes literals), advance past it and return true. Otherwise leave `i`
  ## alone and return false.
  if i >= src.len:
    return false
  case src[i]
  of '"':
    i = skipString(src, i)
    true
  of '$':
    if i + 1 < src.len and src[i + 1] == '"':
      i = skipString(src, i + 1)
      true
    else:
      false
  of '\'':
    let e = charLiteralEnd(src, i)
    if e > 0:
      i = e
      true
    else:
      false
  of '0':
    let e = bytesLiteralEnd(src, i)
    if e > 0:
      i = e
      true
    else:
      false
  of '#':
    if i + 1 < src.len:
      case src[i + 1]
      of '"':
        i = skipString(src, i + 1)
        true
      of '<':
        var depth = 1
        i += 2
        while i < src.len and depth > 0:
          if src.continuesWith("#<", i):
            inc depth; i += 2
          elif src.continuesWith(">#", i):
            dec depth; i += 2
          else:
            inc i
        true
      of '(', '[', '{', '_':
        false   # set/list/map literal or datum comment: not a comment token
      else:
        # Whitespace/'!' continuations are real line comments. Reserved '#'
        # forms are read errors in the reader; this raw scanner stays
        # error-tolerant and skips them like comments so span math survives
        # invalid buffers (diagnostics come from the real reader).
        while i < src.len and src[i] != '\n':
          inc i
        true
    else:
      i = src.len
      true
  else:
    false

proc matchingCloseOffset*(src: string, openOffset: int): int =
  ## Balanced scan from an opening (/[/{ to just past its matching close.
  ## Returns src.len when unbalanced (open form at EOF).
  var i = openOffset
  var depth = 0
  while i < src.len:
    if skipCommentOrAtom(src, i):
      continue
    case src[i]
    of '(', '[', '{':
      inc depth
      inc i
    of ')', ']', '}':
      dec depth
      inc i
      if depth <= 0:
        return i
    else:
      inc i
  src.len

proc tokenEnd(src: string, start: int): int =
  var i = start
  while i < src.len and src[i] notin symbolStop:
    inc i
  if i == start and i < src.len:
    inc i   # single delimiter char
  i

proc nextTokenStart(src: string, start: int): int =
  ## Skip whitespace, commas, and comments; return the next token offset.
  ## Datum comments (`#_ datum`) are spacing per reader semantics: the marker
  ## AND its following datum are skipped, and runs of `#_` stack — so
  ## `(fn #_ old actual [x] ...)` locates `actual` as the declared name.
  var i = start
  var discards = 0
  while i < src.len:
    case src[i]
    of ' ', '\t', '\r', '\n', ',':
      inc i
      continue
    of '#':
      if i + 1 < src.len and src[i + 1] == '_':
        inc discards
        i += 2
        continue
      var j = i
      if skipCommentOrAtom(src, j) and j > i and
          (i + 1 >= src.len or src[i + 1] notin {'(', '[', '{'}):
        i = j
        continue
    else:
      var j = i
      if skipCommentOrAtom(src, j) and j > i and discards > 0:
        # A string/char/bytes atom being discarded by a pending #_.
        i = j
        dec discards
        continue
    # A real token starts here.
    if discards == 0:
      return i
    # Discard one datum, like the reader's parseForm would consume it:
    # quasiquote/unquote prefixes attach to the following form (`old is ONE
    # datum), then a bracketed form (including #(/#[/#{ literals) or a
    # single atom.
    while i < src.len and src[i] in {'`', '%'}:
      inc i
      while i < src.len and src[i] in {' ', '\t', '\r', '\n', ','}:
        inc i
    if i >= src.len:
      break
    if src[i] in {'(', '[', '{'} or
        (src[i] == '#' and i + 1 < src.len and src[i + 1] in {'(', '[', '{'}):
      i = matchingCloseOffset(src, i)
    else:
      var j = i
      if skipCommentOrAtom(src, j) and j > i:
        i = j
      else:
        i = tokenEnd(src, i)
    dec discards
  src.len

proc nameSelectionRange(src: string, starts: seq[int],
                        formOffset: int): LspRange =
  ## The token after the head symbol — the declared name — as an LSP range.
  ## Falls back to the head token when the form has no name.
  var i = formOffset
  if i < src.len and src[i] == '(':
    inc i
  let headStart = nextTokenStart(src, i)
  let headEnd = tokenEnd(src, headStart)
  var nameStart = nextTokenStart(src, headEnd)
  var nameEnd = tokenEnd(src, nameStart)
  if nameStart >= src.len or src[nameStart] in {'(', '[', '{', ')'}:
    nameStart = headStart
    nameEnd = headEnd
  LspRange(start: offsetToLspPos(src, starts, nameStart),
           endPos: offsetToLspPos(src, starts, nameEnd))

proc findTokenRange(src: string, starts: seq[int],
                    fromOffset, toOffset: int, word: string): LspRange =
  ## First standalone occurrence of `word` inside [fromOffset, toOffset).
  ## Zero range at fromOffset when not found.
  var i = fromOffset
  while i < toOffset and i < src.len:
    if skipCommentOrAtom(src, i):
      continue
    if src[i] in symbolStop:
      inc i
      continue
    let e = tokenEnd(src, i)
    if src[i ..< e] == word:
      return LspRange(start: offsetToLspPos(src, starts, i),
                      endPos: offsetToLspPos(src, starts, e))
    i = e
  let p = offsetToLspPos(src, starts, fromOffset)
  LspRange(start: p, endPos: p)

# ---------------------------------------------------------------------------
# Symbol extraction from parsed forms
# ---------------------------------------------------------------------------

proc symName(v: Value): string =
  if v.kind == vkSymbol: v.symVal else: ""

proc firstSourceLine(src: string, starts: seq[int], r: LspRange): string =
  lineSlice(src, starts, r.start.line).strip()

proc formRange(src: string, starts: seq[int], loc: SourceLoc): LspRange =
  let startOff = byteOffset(starts, loc.line, loc.col)
  let endOff = matchingCloseOffset(src, startOff)
  LspRange(start: offsetToLspPos(src, starts, startOff),
           endPos: offsetToLspPos(src, starts, endOff))

proc declFromNode(form: Value, loc: SourceLoc, unit: SourceUnit,
                  src: string, starts: seq[int]): seq[DocSymbol]

proc childDecls(parentForm: Value, unit: SourceUnit,
                src: string, starts: seq[int]): seq[DocSymbol] =
  ## Nested declarations (message/ctor/impl inside type/protocol bodies,
  ## anything inside ns bodies). Nested nodes carry entries in unit.locs.
  for item in parentForm.body:
    if item.kind != vkNode:
      continue
    let loc = unit.locs.getOrDefault(item.bits)
    if not loc.hasSourceLoc:
      continue
    result.add declFromNode(item, loc, unit, src, starts)

proc declFromNode(form: Value, loc: SourceLoc, unit: SourceUnit,
                  src: string, starts: seq[int]): seq[DocSymbol] =
  if form.kind != vkNode or form.head.kind != vkSymbol:
    return
  let headName = form.head.symVal
  let range = formRange(src, starts, loc)
  let startOff = byteOffset(starts, loc.line, loc.col)
  let body = form.body

  proc named(kind: int, name: string, detail = ""): DocSymbol =
    DocSymbol(name: name, detail: detail, kind: kind, range: range,
              selectionRange: nameSelectionRange(src, starts, startOff))

  case headName
  of "fn", "fn!", "macro":
    if body.len > 0 and body[0].kind == vkSymbol:
      result.add named(skFunction, body[0].symVal,
                       if headName == "fn": "" else: headName)
  of "var":
    if body.len > 0 and body[0].kind == vkSymbol:
      result.add named(skVariable, body[0].symVal)
  of "type":
    if body.len > 0 and body[0].kind == vkSymbol:
      var sym = named(skClass, body[0].symVal)
      sym.children = childDecls(form, unit, src, starts)
      result.add sym
  of "enum":
    if body.len > 0 and body[0].kind == vkSymbol:
      var sym = named(skEnum, body[0].symVal)
      let endOff = matchingCloseOffset(src, startOff)
      for i in 1 ..< body.len:
        case body[i].kind
        of vkSymbol:
          # Unit variants are bare symbols with no loc entry: find the token.
          let r = findTokenRange(src, starts, startOff + 1, endOff,
                                 body[i].symVal)
          sym.children.add DocSymbol(name: body[i].symVal, kind: skEnumMember,
                                     range: r, selectionRange: r)
        of vkNode:
          # Tuple variants are nodes: (ok Any)
          if body[i].head.kind == vkSymbol:
            let vloc = unit.locs.getOrDefault(body[i].bits)
            if vloc.hasSourceLoc:
              let vr = formRange(src, starts, vloc)
              sym.children.add DocSymbol(name: body[i].head.symVal,
                                         kind: skEnumMember, range: vr,
                                         selectionRange: vr)
        else:
          discard
      result.add sym
  of "protocol":
    if body.len > 0 and body[0].kind == vkSymbol:
      var sym = named(skInterface, body[0].symVal)
      sym.children = childDecls(form, unit, src, starts)
      result.add sym
  of "impl":
    # (impl P for T body...) or inline (impl P body...) inside a type
    var name = "impl"
    if body.len > 0 and body[0].kind == vkSymbol:
      name = "impl " & body[0].symVal
      if body.len > 2 and symName(body[1]) == "for" and
          body[2].kind == vkSymbol:
        name.add " for " & body[2].symVal
    var sym = named(skObject, name)
    sym.children = childDecls(form, unit, src, starts)
    result.add sym
  of "message":
    if body.len > 0 and body[0].kind == vkSymbol:
      result.add named(skMethod, body[0].symVal)
  of "ctor":
    result.add named(skConstructor, "ctor")
  of "ns":
    if body.len > 0 and body[0].kind == vkSymbol:
      var sym = named(skNamespace, body[0].symVal)
      sym.children = childDecls(form, unit, src, starts)
      result.add sym
  of "mod":
    if body.len > 0 and body[0].kind == vkSymbol:
      result.add named(skModule, body[0].symVal)
  else:
    discard

proc analyze*(src: string, sourceName = "<lsp>"): DocAnalysis =
  ## Parse and extract diagnostics + document symbols. A parse error yields
  ## one diagnostic and no symbols (callers keep the last good symbol tree).
  let starts = lineStarts(src)
  try:
    let unit = readAllWithLocs(src, sourceName)
    result.parsed = true
    for i in 0 ..< unit.forms.len:
      result.symbols.add declFromNode(unit.forms[i], unit.formLocs[i], unit,
                                      src, starts)
  except ReadError as e:
    let start = toLspPos(src, starts, e.line, e.col)
    result.parsed = false
    result.diagnostics.add LspDiagnostic(
      message: e.msg,
      range: LspRange(start: start,
                      endPos: LspPos(line: start.line,
                                     character: start.character + 1)))

proc flattenDefs*(symbols: seq[DocSymbol], src: string,
                  container = ""): seq[FlatDef] =
  ## Flatten a symbol tree into the definition index used by definition,
  ## hover, and workspace/symbol.
  let starts = lineStarts(src)
  for s in symbols:
    result.add FlatDef(name: s.name, containerName: container, kind: s.kind,
                       range: s.range, selectionRange: s.selectionRange,
                       signature: firstSourceLine(src, starts, s.range))
    result.add flattenDefs(s.children, src, s.name)

proc wordAt*(src: string, starts: seq[int], pos: LspPos): string =
  ## The symbol token under an LSP position. Slash paths yield the segment
  ## under the cursor; leading quote/property sigils are stripped.
  let line = lineSlice(src, starts, pos.line)
  if line.len == 0:
    return ""
  var col = utf16ColToByte(line, pos.character)
  if col >= line.len:
    col = line.len - 1
  if line[col] in symbolStop:
    if col > 0 and line[col - 1] notin symbolStop:
      dec col
    else:
      return ""
  var first = col
  while first > 0 and line[first - 1] notin symbolStop:
    dec first
  var last = col
  while last < line.len and line[last] notin symbolStop:
    inc last
  var word = line[first ..< last]
  # Segment under the cursor for slash paths (a/b/c): compute both segment
  # boundaries against the ORIGINAL word, then slice once — slicing early and
  # indexing with stale offsets was an out-of-bounds Defect on 3+ segments.
  if '/' in word:
    let rel = min(max(col - first, 0), word.len - 1)
    var segStart = 0
    var segEnd = word.len
    for i in 0 ..< word.len:
      if word[i] == '/':
        if i >= rel:
          segEnd = i
          break
        segStart = i + 1
    if segStart <= segEnd:
      word = word[segStart ..< segEnd]
  while word.len > 0 and word[0] in {'\'', '^', '%', '@', '$'}:
    word = word[1 .. ^1]
  word
