## Human-friendly source formatter for `gene fmt`.
##
## Unlike the canonical printer (printer.nim — one line per form, fully
## desugared, used by `gene parse` and serde), this module targets people:
##
## - forms wrap at a max width with 2-space indentation and special-form
##   aware layouts (fn/if/match/type/... bodies indent under a head line);
## - reader sugar prints back as sugar: slash paths (`a/b`), quasiquote
##   (`` `x ``) / unquote (`%x`), and `($ ...)` interpolation as `$"a${b}c"`;
## - strings containing newlines print as raw multiline strings;
## - comments and blank lines BETWEEN top-level forms are preserved; a form
##   whose span contains interior comments is emitted verbatim (the reader
##   drops comments, so reformatting such a form would delete them).
##
## Formatted output must re-parse to the same canonical forms as the input
## (`tests/test_cli.nim` asserts parse-equivalence and idempotence).

import std/[strutils]
import ./reader, ./types, ./printer
import ./lsp/analysis as span

const MaxWidth = 100

# ---------------------------------------------------------------------------
# Raw-span helpers (comment detection + form extents in the original text)
# ---------------------------------------------------------------------------

proc skipStringRaw(src: string, start: int): int =
  var i = start
  if src.continuesWith("\"\"\"", i):
    i += 3
    while i < src.len:
      if src.continuesWith("\"\"\"", i): return i + 3
      inc i
    return src.len
  inc i
  while i < src.len:
    case src[i]
    of '\\': i += 2
    of '"': return i + 1
    else: inc i
  src.len

proc hasInteriorComment(src: string, a, b: int): bool =
  ## Any `# ...` / `#< >#` / `#_` comment strictly inside [a, b)?
  var i = a
  while i < b and i < src.len:
    case src[i]
    of '"': i = skipStringRaw(src, i)
    of '$':
      if i + 1 < src.len and src[i + 1] == '"': i = skipStringRaw(src, i + 1)
      else: inc i
    of '\'':
      # char literal: skip up to closing quote on the same line
      var j = i + 1
      if j < src.len and src[j] == '\\': inc j
      while j < src.len and src[j] notin {'\'', '\n'}: inc j
      i = (if j < src.len and src[j] == '\'': j + 1 else: i + 1)
    of '0':
      if i + 2 < src.len and src[i + 1] in {'!', 'x', '#'}:
        var j = i + 2
        while j < src.len and src[j] notin {'(', ')', '[', ']', '{', '}',
            ' ', '\t', '\n', '\r', ',', ';', '"', '\'', '`', '#'}:
          inc j
        if j > i + 2: i = j
        else: inc i
      else: inc i
    of '#':
      if i + 1 < src.len and src[i + 1] == '"': i = skipStringRaw(src, i + 1)
      elif i + 1 < src.len and src[i + 1] in {'(', '[', '{'}: inc i
      else:
        # Reserved '#' forms are read errors in the reader; this raw span
        # helper stays error-tolerant and treats them like comments.
        return true
    else: inc i
  false

proc formSpan(src: string, startOff: int): int =
  ## Offset just past a top-level form starting at startOff.
  var i = startOff
  while i < src.len and src[i] in {'`', '%'}: inc i
  if i < src.len and src[i] in {'(', '[', '{'}:
    return span.matchingCloseOffset(src, i)
  if i + 1 < src.len and src[i] == '#' and src[i + 1] in {'(', '[', '{'}:
    return span.matchingCloseOffset(src, i)
  if i + 1 < src.len and src[i] == '$' and src[i + 1] == '"':
    return skipStringRaw(src, i + 1)
  if i + 1 < src.len and src[i] == '#' and src[i + 1] == '"':
    i = skipStringRaw(src, i + 1)
    while i < src.len and src[i] in {'A'..'Z', 'a'..'z'}: inc i
    return i
  if i < src.len and src[i] == '"':
    return skipStringRaw(src, i)
  if i < src.len and src[i] == '\'':
    var j = i + 1
    if j < src.len and src[j] == '\\': inc j
    while j < src.len and src[j] notin {'\'', '\n', '\r'}: inc j
    return (if j < src.len and src[j] == '\'': j + 1 else: src.len)
  while i < src.len and src[i] notin {'(', ')', '[', ']', '{', '}', ' ',
      '\t', '\n', '\r', ',', ';', '"'}:
    inc i
  i

# ---------------------------------------------------------------------------
# Sugar-aware single-line rendering
# ---------------------------------------------------------------------------

proc oneLine(v: Value): string

proc isSym(v: Value, s: string): bool =
  v.kind == vkSymbol and v.symVal == s

proc pathSegment(v: Value): string =
  ## "" when the segment cannot ride in a slash path.
  case v.kind
  of vkSymbol:
    if '/' in v.symVal or v.symVal.len == 0: "" else: v.symVal
  of vkInt: print(v)
  of vkNode:
    if v.head.isSym("unquote") and v.body.len == 1 and v.props.len == 0:
      let inner = pathSegment(v.body[0])
      if inner.len > 0: "%" & inner else: ""
    else: ""
  else: ""

proc resugarPath(v: Value): string =
  ## (path a b c) -> a/b/c, or "" when any segment resists.
  if v.props.len > 0 or v.meta.len > 0 or v.body.len < 2: return ""
  var parts: seq[string]
  for item in v.body:
    let seg = pathSegment(item)
    if seg.len == 0: return ""
    parts.add seg
  parts.join("/")

proc resugarInterp(v: Value): string =
  ## ($ "a" b "c") -> $"a${b}c", or "" when unsafe (a literal `$` in any
  ## string part would re-parse as interpolation).
  if v.props.len > 0 or v.meta.len > 0 or v.body.len == 0: return ""
  var sawStr = false
  for item in v.body:
    if item.kind == vkString:
      sawStr = true
      if '$' in item.strVal or '\n' in item.strVal: return ""
  if not sawStr: return ""
  var sb = "$\""
  for item in v.body:
    if item.kind == vkString:
      for ch in item.strVal:
        case ch
        of '"': sb.add "\\\""
        of '\\': sb.add "\\\\"
        else: sb.add ch
    else:
      sb.add "${" & oneLine(item) & "}"
  sb.add '"'
  sb

proc declarationPrefixCount(head: string, body: openArray[Value]): int =
  ## Body items which conventionally precede declaration props/meta. Runtime
  ## nodes store props separately, so their original source position is not
  ## available after reading; the formatter chooses the language convention.
  case head
  of "mod", "ns", "type", "enum", "protocol":
    if body.len > 0 and body[0].kind == vkSymbol: 1 else: 0
  of "fn", "fn!", "macro", "message", "ctor":
    var n = 0
    if head != "ctor" and n < body.len and body[n].kind == vkSymbol: inc n
    if n < body.len and body[n].kind == vkList: inc n
    if n + 1 < body.len and body[n].isSym(":"): n += 2
    n
  else:
    0

proc headerBodyCount(head: string, body: openArray[Value]): int =
  ## Number of positional items kept on the opening line of a broken form.
  case head
  of "if", "if_yes", "if_not", "while", "when", "elif", "match", "case",
     "var", "set", "spawn":
    1
  of "for", "repeat":
    if body.len >= 3 and body[1].isSym("in"): 3 else: 1
  of "impl":
    if body.len >= 3 and body[1].isSym("for"): 3 else: 1
  of "do", "else", "then", "try", "loop", "supervisor":
    0
  of "fn", "fn!", "macro", "message", "ctor", "mod", "ns", "type",
     "enum", "protocol":
    declarationPrefixCount(head, body)
  else:
    # Message send keeps `x ~ msg` on the head line.
    if body.len >= 2 and body[0].isSym("~"): 2 else: 0

proc attributePrefixCount(v: Value, head: string): int =
  result = declarationPrefixCount(head, v.body)
  # Data nodes conventionally place metadata after a leading symbolic name.
  if result == 0 and v.meta.len > 0 and v.body.len > 0 and
      v.body[0].kind == vkSymbol:
    result = 1

proc addProps(sb: var string, props: PropTable, sigil: string) =
  for k, val in props:
    sb.add ' '
    if val.kind == vkBool and val.boolVal:
      sb.add sigil & sigil & k
    else:
      sb.add sigil & k & " " & oneLine(val)

proc joinItems(items: openArray[Value]): string =
  ## Space-joined, but a bare `,` symbol glues to the previous item.
  var sb = ""
  var glueNext = false
  for item in items:
    if item.isSym(","):
      sb.add ","
      glueNext = false
    elif item.isSym("^") or item.isSym("@"):
      if sb.len > 0: sb.add ' '
      sb.add oneLine(item)
      glueNext = true
    else:
      if sb.len > 0 and not glueNext: sb.add ' '
      sb.add oneLine(item)
      glueNext = false
  sb

proc pipelineParts(v: Value): tuple[base: Value, stages: seq[seq[Value]]] =
  ## Reader pipe folding and explicitly nested receiver sends have the same
  ## value shape. Canonical human style uses pipe sugar for chains of at least
  ## two sends; a single receiver send remains `(value ~ message ...)`.
  var current = v
  var reversed: seq[seq[Value]]
  while current.kind == vkNode and not current.nodeImmutable and
      current.props.len == 0 and current.meta.len == 0 and
      current.body.len >= 2 and current.body[0].isSym("~"):
    reversed.add current.body
    current = current.head
  result.base = current
  if reversed.len >= 2:
    for i in countdown(reversed.high, 0):
      result.stages.add reversed[i]

proc pipelineOneLine(v: Value): string =
  let parts = pipelineParts(v)
  if parts.stages.len < 2:
    return ""
  result = "(" & oneLine(parts.base)
  for i, stage in parts.stages:
    result.add (if i == 0: " " else: "; ")
    result.add joinItems(stage)
  result.add ')'

proc oneLine(v: Value): string =
  case v.kind
  of vkNode:
    let pipeline = pipelineOneLine(v)
    if pipeline.len > 0:
      return pipeline
    if not v.nodeImmutable and v.head.kind == vkSymbol:
      case v.head.symVal
      of "path":
        let p = resugarPath(v)
        if p.len > 0: return p
      of "quasiquote":
        if v.body.len == 1 and v.props.len == 0:
          return "`" & oneLine(v.body[0])
      of "unquote":
        if v.body.len == 1 and v.props.len == 0:
          return "%" & oneLine(v.body[0])
      of "...":
        if v.body.len == 1 and v.props.len == 0:
          return oneLine(v.body[0]) & "..."
      of "$":
        let s = resugarInterp(v)
        if s.len > 0: return s
      else: discard
    var sb = (if v.nodeImmutable: "#(" else: "(") & oneLine(v.head)
    let head = if v.head.kind == vkSymbol: v.head.symVal else: ""
    let start = attributePrefixCount(v, head)
    for i in 0 ..< start:
      sb.add " " & oneLine(v.body[i])
    addProps(sb, v.meta, "@")
    addProps(sb, v.props, "^")
    if v.body.len > start:
      sb.add " " & joinItems(v.body[start .. ^1])
    sb & ")"
  of vkList:
    (if v.listImmutable: "#[" else: "[") & joinItems(v.listItems) & "]"
  of vkMap:
    var sb = if v.mapImmutable: "#{" else: "{"
    var first = true
    for k, val in v.mapEntries:
      if not first: sb.add ' '
      first = false
      if val.kind == vkBool and val.boolVal: sb.add "^^" & k
      else: sb.add "^" & k & " " & oneLine(val)
    sb & "}"
  else:
    print(v)

proc hasMultilineString(v: Value): bool =
  case v.kind
  of vkString: '\n' in v.strVal
  of vkNode:
    if hasMultilineString(v.head): return true
    for _, p in v.props:
      if hasMultilineString(p): return true
    for item in v.body:
      if hasMultilineString(item): return true
    false
  of vkList:
    for item in v.listItems:
      if hasMultilineString(item): return true
    false
  of vkMap:
    for _, p in v.mapEntries:
      if hasMultilineString(p): return true
    false
  else: false

# ---------------------------------------------------------------------------
# Multiline layout
# ---------------------------------------------------------------------------

proc fmtValue(v: Value, indent: int): string

proc rawStr(s: string): string =
  ## Prefer the language's explicit triple-quoted spelling for multiline text.
  if '\n' in s and "\"\"\"" notin s:
    return "\"\"\"" & s & "\"\"\""
  ## Fallback for one-line text or content containing a triple delimiter.
  var sb = "\""
  for ch in s:
    case ch
    of '"': sb.add "\\\""
    of '\\': sb.add "\\\\"
    of '\n': sb.add '\n'
    of '\t': sb.add "\\t"
    of '\r': sb.add "\\r"
    else: sb.add ch
  sb & "\""

proc fits(v: Value, indent: int): bool =
  not hasMultilineString(v) and indent + oneLine(v).len <= MaxWidth

proc prefersMultiline(v: Value): bool =
  if v.kind != vkNode:
    return false
  if pipelineParts(v).stages.len >= 2:
    return true
  if v.head.kind != vkSymbol:
    return false
  let head = v.head.symVal
  let bodyCount = v.body.len
  case head
  of "fn", "fn!", "macro", "message", "ctor":
    bodyCount > headerBodyCount(head, v.body)
  of "protocol", "impl", "ns":
    bodyCount > headerBodyCount(head, v.body)
  of "if":
    if bodyCount >= 3:
      return true
    for item in v.body:
      if item.kind == vkNode and item.head.kind == vkSymbol and
          item.head.symVal in ["then", "elif", "else"]:
        return true
    false
  of "if_yes", "if_not":
    bodyCount > 2
  of "then", "else", "when", "elif":
    bodyCount > 0
  of "match", "try":
    bodyCount > 1
  of "for":
    bodyCount > headerBodyCount(head, v.body)
  of "while", "repeat", "scope", "loop", "do":
    bodyCount > headerBodyCount(head, v.body)
  else:
    false

proc breakNode(v: Value, indent: int): string =
  let pad = repeat(' ', indent + 2)
  let pipeline = pipelineParts(v)
  if pipeline.stages.len >= 2:
    var sb = "(" & oneLine(pipeline.base)
    for index, stage in pipeline.stages:
      sb.add "\n" & pad
      if index > 0: sb.add "; "
      sb.add joinItems(stage)
    return sb & ")"
  var sb = (if v.nodeImmutable: "#(" else: "(") & oneLine(v.head)
  let head = if v.head.kind == vkSymbol: v.head.symVal else: ""
  let start = attributePrefixCount(v, head)
  for index in 0 ..< start:
    sb.add " " & oneLine(v.body[index])
  addProps(sb, v.meta, "@")
  addProps(sb, v.props, "^")
  let body = v.body
  var i = start
  let inline = max(headerBodyCount(head, body), start)
  while i < body.len and i < inline:
    sb.add " " & oneLine(body[i])
    inc i
  if head == "try":
    # catch/ensure align with `try`; their bodies remain one level inside.
    let markerPad = repeat(' ', indent)
    while i < body.len:
      if body[i].isSym("catch") and i + 1 < body.len:
        sb.add "\n" & markerPad & "catch " & oneLine(body[i + 1])
        i += 2
      elif body[i].isSym("ensure"):
        sb.add "\n" & markerPad & "ensure"
        inc i
      else:
        sb.add "\n" & pad & fmtValue(body[i], indent + 2)
        inc i
  else:
    # A lone remaining string rides the head line — the common
    # `(db ~ exec "multiline sql")` / `(var css "...")` shape.
    if i == body.len - 1 and body[i].kind == vkString:
      sb.add " " & (if '\n' in body[i].strVal: rawStr(body[i].strVal)
                    else: fmtValue(body[i], indent + 2))
    else:
      while i < body.len:
        sb.add "\n" & pad & fmtValue(body[i], indent + 2)
        inc i
  sb & ")"

proc fmtValue(v: Value, indent: int): string =
  if fits(v, indent) and not prefersMultiline(v):
    return oneLine(v)
  case v.kind
  of vkString:
    rawStr(v.strVal)
  of vkNode:
    # Sugar wrappers stay glued to their (possibly multiline) inner form.
    if not v.nodeImmutable and v.head.kind == vkSymbol and
        v.props.len == 0 and v.body.len == 1:
      case v.head.symVal
      of "quasiquote": return "`" & fmtValue(v.body[0], indent + 1)
      of "unquote": return "%" & fmtValue(v.body[0], indent + 1)
      of "...": return fmtValue(v.body[0], indent) & "..."
      else: discard
    breakNode(v, indent)
  of vkList:
    let pad = repeat(' ', indent + 2)
    var sb = if v.listImmutable: "#[" else: "["
    for item in v.listItems:
      sb.add "\n" & pad & fmtValue(item, indent + 2)
    sb & "]"
  of vkMap:
    let pad = repeat(' ', indent + 2)
    var sb = if v.mapImmutable: "#{" else: "{"
    for k, p in v.mapEntries:
      sb.add "\n" & pad
      if p.kind == vkBool and p.boolVal: sb.add "^^" & k
      else: sb.add "^" & k & " " & fmtValue(p, indent + 2 + k.len + 2)
    sb & "}"
  else:
    oneLine(v)

# ---------------------------------------------------------------------------
# Source-unit formatting with comment preservation
# ---------------------------------------------------------------------------

proc emitGap(sb: var string, gap: string, afterForm: bool) =
  ## Preserve comment lines and (single) blank separations from the raw text
  ## between forms. `afterForm`: the first gap line may hold a trailing
  ## comment belonging to the previous form's last line.
  var lines = gap.split('\n')
  if afterForm:
    let tail = lines[0].strip()
    if tail.len > 0:
      sb.add " " & tail
    lines.delete(0)
  var pendingBlank = false
  for idx, line in lines:
    let t = line.strip()
    if t.len == 0:
      # A blank separation survives (collapsed to one blank line). The final
      # fragment is the next form's own line prefix, not a blank line; and
      # leading blanks at the very top of the file are dropped.
      if idx < lines.high:
        pendingBlank = sb.len > 0
    else:
      if sb.len > 0: sb.add "\n"
      if pendingBlank:
        sb.add "\n"
        pendingBlank = false
      sb.add t
  if pendingBlank:
    sb.add "\n"

proc formatSource*(src: string, sourceName = "<fmt>"): string =
  ## Human-friendly formatting of a whole source unit. Raises ReadError on
  ## unparseable input (same contract as the canonical path).
  let unit = readAllWithLocs(src, sourceName)
  let starts = span.lineStarts(src)
  var sb = ""
  var prevEnd = 0
  for i in 0 ..< unit.forms.len:
    let startOff = span.byteOffset(starts, unit.formLocs[i].line,
                                   unit.formLocs[i].col)
    # formSpan is a heuristic over raw text; degenerate token streams (a bare
    # `^` manifest prop is its own form) can make it overshoot the next
    # form's start. Never slice backwards.
    if startOff > prevEnd:
      emitGap(sb, src[prevEnd ..< startOff], afterForm = i > 0)
    if sb.len > 0:
      # Forms that shared a source line stay on one line (manifest-style
      # `^name "value"` token runs).
      if i > 0 and unit.formLocs[i].line == unit.formLocs[i - 1].line:
        sb.add " "
      else:
        sb.add "\n"
    let endOff = max(formSpan(src, startOff), startOff)
    if hasInteriorComment(src, startOff + 1, max(endOff - 1, startOff + 1)):
      # Reformatting would delete comments the reader dropped: keep verbatim.
      sb.add src[startOff ..< endOff]
    else:
      sb.add fmtValue(unit.forms[i], 0)
    prevEnd = endOff
  if src.len > prevEnd:
    emitGap(sb, src[prevEnd ..< src.len], afterForm = unit.forms.len > 0)
  if sb.len == 0 or sb[^1] != '\n':
    sb.add "\n"
  sb
