## Reversible AI-native program format -- logical program document (v0).
##
## Implements the "logical program document" and canonical `.gene` projection
## from `docs/proposals/reversible-ai-native-program-format.md`: the reader
## already produces a complete, comment-free semantic form tree (`readAll`);
## this module adds the missing piece -- a positional comment overlay kept
## out of the `Value` hot path -- and a document-level canonical writer that
## reprints forms with those comments interleaved back at their canonical
## structural boundaries.
##
## v0 scope: comment placement is fully structural (recursing through node
## head/meta/props/body, list items, map entries, and hash-map values) for
## `vkNode`, `vkList`, `vkMap`, and `vkHashMap`. Any other container shape
## (quasiquote/unquote/interpolation sugar, or any future syntax kind) is
## treated as opaque: interior comments are still captured -- never silently
## dropped -- but anchored to that whole sugar form's boundary rather than to
## a specific child. `readDocument` additionally cross-checks every comment
## token in the source against the records it built and falls back to a
## coarse per-form bucket for anything the structural walk missed, so comment
## loss is a correctness bug this module can catch in its own tests, not a
## silent possibility.

import std/[tables, algorithm]
import ./reader
import ./source_index
import ./source_positions
import ./types
import ./printer

type
  CommentPlacement* = enum
    cpStandalone  ## Own line(s), not trailing a value.
    cpTrailing    ## End-of-line comment trailing the preceding completed value.

  DocPathSegment* = SourcePathSegment
  DocPath* = seq[DocPathSegment]

  CommentRecord* = object
    formIndex*: int      ## -1 = root-level (between/around top-level forms).
    containerPath*: DocPath  ## Path from the form root to the enclosing container.
    afterChild*: int     ## See boundary-key convention below.
    ordinal*: int         ## Disambiguates multiple comments at the same key.
    placement*: CommentPlacement
    text*: string          ## Raw source text of the comment, `#`/block delimiters included.

  ProgramDocument* = object
    sourceName*: string
    hasBangLine*: bool
    bangLine*: string     ## Raw `#!...` text, no trailing newline. Valid only if hasBangLine.
    forms*: seq[Value]
    comments*: seq[CommentRecord]  ## Deterministic discovery order (see readDocument).

## Boundary-key convention for `CommentRecord`:
##   formIndex == -1:  containerPath is always empty; `afterChild` is the
##     index of the top-level form this root-level comment follows (-1 =
##     before the first form / start of file, after any bang line).
##   formIndex >= 0, containerPath == @[]:
##     afterChild is the canonical position (see below) of the child of the
##     form's own root value that this comment follows (-1 = before that
##     root value's first child).
##   formIndex >= 0, containerPath non-empty:
##     same, but relative to the container reached by descending containerPath
##     from the form's root value.
##   afterChild == -2: opaque placement -- this comment fell inside a
##     structural shape (or a scanChildren gap) this module does not finely
##     resolve; anchored to containerPath as a whole, not a specific child.
## Canonical child position, per container kind (matches printer.nim's
## emission order exactly, which is what makes the writer and reader agree):
##   vkNode:  0 = head; then meta entries in PropTable order (offset 1); then
##            props entries in PropTable order (offset 1 + meta.len); then
##            body entries in seq order (offset 1 + meta.len + props.len).
##   vkList:  seq index directly.
##   vkMap:   PropTable order directly (no head/meta slot).
##   vkHashMap: seq index directly (source order == entries order).

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

proc keyStr(formIndex: int, path: DocPath, afterChild: int): string =
  result = $formIndex
  result.add '#'
  for seg in path:
    case seg.kind
    of spsProperty:
      result.add "p:"
      result.add seg.name
      result.add ';'
    of spsIndex:
      result.add "i:"
      result.add $seg.index
      result.add ';'
  result.add '@'
  result.add $afterChild

proc positionInPropTable(t: PropTable, name: string): int =
  ## -1 if not found.
  result = 0
  for k in t.keys:
    if k == name: return result
    inc result
  return -1

proc commentTokenRange(sdoc: SourceDocument, first, last: int): seq[int] =
  ## Indexes (into sdoc.tokens) of every comment token in [first, last).
  for i in first ..< last:
    if sdoc.tokens[i].kind in {tkLineComment, tkBlockComment}:
      result.add i

proc sameLine(sdoc: SourceDocument, endByte, startByte: int): bool =
  offsetLineCol(sdoc.source, sdoc.lineStarts, max(endByte - 1, 0)).line ==
    offsetLineCol(sdoc.source, sdoc.lineStarts, startByte).line

# ---------------------------------------------------------------------------
# readDocument: .gene source -> ProgramDocument
# ---------------------------------------------------------------------------

type CommentSink = object
  comments: seq[CommentRecord]
  ordinals: Table[string, int]
  covered: seq[bool]   ## Parallel to sdoc.tokens; marks tokens already recorded.

proc addComment(sink: var CommentSink, sdoc: SourceDocument, tokenIdx: int,
                 formIndex: int, path: DocPath, afterChild: int,
                 placement: CommentPlacement) =
  if sink.covered[tokenIdx]: return
  sink.covered[tokenIdx] = true
  let key = keyStr(formIndex, path, afterChild)
  let ord = sink.ordinals.getOrDefault(key, 0)
  sink.ordinals[key] = ord + 1
  let tok = sdoc.tokens[tokenIdx]
  sink.comments.add CommentRecord(formIndex: formIndex, containerPath: path,
    afterChild: afterChild, ordinal: ord, placement: placement,
    text: sdoc.source[tok.startByte ..< tok.endByte])

proc scanOpaque(sink: var CommentSink, sdoc: SourceDocument, syntax: SyntaxRef,
                 formIndex: int, path: DocPath) =
  ## Safety net: capture every not-yet-covered comment token in this token
  ## range, anchored coarsely to `path`. Guarantees no comment is dropped.
  for i in syntax.startToken ..< syntax.endToken:
    if sdoc.tokens[i].kind in {tkLineComment, tkBlockComment} and not sink.covered[i]:
      sink.addComment(sdoc, i, formIndex, path, -2, cpStandalone)

proc resolveChild(containerValue: Value, path: DocPath):
    tuple[pos: int, value: Value, ok: bool] =
  ## Canonical position + value of a direct structural child, given the
  ## relative `SourcePathSegment` path source_index assigned it.
  if containerValue.kind == vkNode:
    if path.len == 1 and path[0].kind == spsProperty and path[0].name == "head":
      return (0, containerValue.head, true)
    if path.len == 2 and path[0].kind == spsProperty and path[0].name == "meta" and
        path[1].kind == spsProperty:
      let idx = positionInPropTable(containerValue.meta, path[1].name)
      if idx < 0: return (0, Value(), false)
      return (1 + idx, containerValue.meta[path[1].name], true)
    if path.len == 1 and path[0].kind == spsProperty:
      let idx = positionInPropTable(containerValue.props, path[0].name)
      if idx < 0: return (0, Value(), false)
      return (1 + containerValue.meta.len + idx, containerValue.props[path[0].name], true)
    if path.len == 1 and path[0].kind == spsIndex:
      let i = path[0].index.int
      if i < 0 or i >= containerValue.body.len: return (0, Value(), false)
      return (1 + containerValue.meta.len + containerValue.props.len + i,
              containerValue.body[i], true)
    return (0, Value(), false)
  elif containerValue.kind == vkList:
    if path.len == 1 and path[0].kind == spsIndex:
      let i = path[0].index.int
      if i < 0 or i >= containerValue.listItems.len: return (0, Value(), false)
      return (i, containerValue.listItems[i], true)
    return (0, Value(), false)
  elif containerValue.kind == vkMap:
    if path.len == 1 and path[0].kind == spsProperty:
      let idx = positionInPropTable(containerValue.mapEntries, path[0].name)
      if idx < 0: return (0, Value(), false)
      return (idx, containerValue.mapEntries[path[0].name], true)
    return (0, Value(), false)
  else:
    return (0, Value(), false)

proc isFineContainer(k: SyntaxKind): bool =
  k in {skNode, skList, skPropMap}

proc walkContainer(sink: var CommentSink, sdoc: SourceDocument, syntax: SyntaxRef,
                    formIndex: int, path: DocPath, containerValue: Value)

proc walkHashMap(sink: var CommentSink, sdoc: SourceDocument, syntax: SyntaxRef,
                  formIndex: int, path: DocPath, containerValue: Value) =
  let kids = sdoc.children(syntax)
  var afterChild = -1
  var prevEndByte = -1
  var counter = 0
  for row in kids:
    if row.syntax.kind == skComment:
      let placement =
        if afterChild >= 0 and prevEndByte >= 0 and
            sameLine(sdoc, prevEndByte, row.syntax.span.startByte):
          cpTrailing
        else:
          cpStandalone
      sink.addComment(sdoc, row.syntax.startToken, formIndex, path, afterChild, placement)
      continue
    afterChild = counter
    prevEndByte = row.syntax.span.endByte
    inc counter
    if counter <= containerValue.hashMapEntries.len:
      let childVal = containerValue.hashMapEntries[counter - 1].val
      if isFineContainer(row.syntax.kind) or row.syntax.kind == skGeneralMap:
        let childPath = path & row.path
        if row.syntax.kind == skGeneralMap:
          walkHashMap(sink, sdoc, row.syntax, formIndex, childPath, childVal)
        else:
          walkContainer(sink, sdoc, row.syntax, formIndex, childPath, childVal)
      elif isContainer(row.syntax):
        scanOpaque(sink, sdoc, row.syntax, formIndex, path & row.path)
  scanOpaque(sink, sdoc, syntax, formIndex, path)  # catches key/value gaps etc.

proc walkContainer(sink: var CommentSink, sdoc: SourceDocument, syntax: SyntaxRef,
                    formIndex: int, path: DocPath, containerValue: Value) =
  if syntax.kind == skGeneralMap:
    walkHashMap(sink, sdoc, syntax, formIndex, path, containerValue)
    return
  if not isFineContainer(syntax.kind):
    scanOpaque(sink, sdoc, syntax, formIndex, path)
    return
  let kids = sdoc.children(syntax)
  var afterChild = -1
  var prevEndByte = -1
  for row in kids:
    if row.syntax.kind == skComment:
      let placement =
        if afterChild >= 0 and prevEndByte >= 0 and
            sameLine(sdoc, prevEndByte, row.syntax.span.startByte):
          cpTrailing
        else:
          cpStandalone
      sink.addComment(sdoc, row.syntax.startToken, formIndex, path, afterChild, placement)
      continue
    let resolved = resolveChild(containerValue, row.path)
    if not resolved.ok:
      # Structural mismatch between the source-level heuristic and the real
      # value (e.g. a marker scanChildren allows syntactically but this kind
      # doesn't model, such as `@meta` inside a `{}` map). Never lose the
      # comments in this subtree -- fall back to opaque capture for it -- but
      # still track it as "a child happened here" for line-adjacency.
      afterChild = if afterChild < 0: -1 else: afterChild + 1
      prevEndByte = row.syntax.span.endByte
      scanOpaque(sink, sdoc, row.syntax, formIndex, path)
      continue
    afterChild = resolved.pos
    prevEndByte = row.syntax.span.endByte
    if isContainer(row.syntax):
      let childPath = path & row.path
      if row.syntax.kind == skGeneralMap:
        walkHashMap(sink, sdoc, row.syntax, formIndex, childPath, resolved.value)
      elif isFineContainer(row.syntax.kind):
        walkContainer(sink, sdoc, row.syntax, formIndex, childPath, resolved.value)
      else:
        scanOpaque(sink, sdoc, row.syntax, formIndex, childPath)

proc readDocument*(source: string, sourceName = ""): ProgramDocument =
  let unit = readAllWithLocs(source, sourceName)
  result.sourceName = sourceName
  result.forms = unit.forms

  let sdoc = indexSource(source, sourceName)
  if sdoc.diagnostics.len > 0:
    raise newException(ReadError, "cannot build a program document: " &
      sdoc.diagnostics[0].message)

  var sink = CommentSink(covered: newSeq[bool](sdoc.tokens.len))

  # Bang line: only a `#!` comment at byte offset zero.
  var rootStart = 0
  if sdoc.tokens.len > 0 and sdoc.tokens[0].kind == tkLineComment and
      sdoc.tokens[0].startByte == 0 and
      source.len >= 2 and source[0] == '#' and source[1] == '!':
    result.hasBangLine = true
    result.bangLine = source[sdoc.tokens[0].startByte ..< sdoc.tokens[0].endByte]
    sink.covered[0] = true
    rootStart = 1

  # Root level: comments before/between/after top-level forms.
  if sdoc.topLevel.len == 0:
    for i in commentTokenRange(sdoc, rootStart, sdoc.tokens.len):
      sink.addComment(sdoc, i, -1, @[], -1, cpStandalone)
  else:
    for i in commentTokenRange(sdoc, rootStart, sdoc.topLevel[0].startToken):
      sink.addComment(sdoc, i, -1, @[], -1, cpStandalone)
    for f in 0 ..< sdoc.topLevel.len:
      if f + 1 < sdoc.topLevel.len:
        for i in commentTokenRange(sdoc, sdoc.topLevel[f].endToken,
                                    sdoc.topLevel[f + 1].startToken):
          sink.addComment(sdoc, i, -1, @[], f, cpStandalone)
      else:
        for i in commentTokenRange(sdoc, sdoc.topLevel[f].endToken, sdoc.tokens.len):
          sink.addComment(sdoc, i, -1, @[], f, cpStandalone)

  # Per-form structural walk.
  if sdoc.topLevel.len != unit.forms.len:
    raise newException(ReadError,
      "program document: structural/semantic form count mismatch (" &
      $sdoc.topLevel.len & " vs " & $unit.forms.len & ")")
  for f in 0 ..< unit.forms.len:
    let syntax = sdoc.topLevel[f]
    let value = unit.forms[f]
    if isFineContainer(syntax.kind):
      walkContainer(sink, sdoc, syntax, f, @[], value)
    elif syntax.kind == skGeneralMap:
      walkHashMap(sink, sdoc, syntax, f, @[], value)
    elif isContainer(syntax):
      scanOpaque(sink, sdoc, syntax, f, @[])
    # Atoms have no interior to scan.

  # Completeness safety net: any comment token not yet covered (should only
  # happen for shapes genuinely outside this module's structural knowledge)
  # is attached to the nearest enclosing top-level form, or root level.
  for i in 0 ..< sdoc.tokens.len:
    if sdoc.tokens[i].kind in {tkLineComment, tkBlockComment} and not sink.covered[i]:
      var owner = -1
      var afterChild = -1
      for f in 0 ..< sdoc.topLevel.len:
        if i >= sdoc.topLevel[f].startToken and i < sdoc.topLevel[f].endToken:
          owner = f
          afterChild = -2
          break
        elif i >= sdoc.topLevel[f].endToken:
          afterChild = f
      sink.addComment(sdoc, i, owner, @[], afterChild, cpStandalone)

  result.comments = sink.comments

# ---------------------------------------------------------------------------
# writeCanonical: ProgramDocument -> .gene text
# ---------------------------------------------------------------------------

type CommentEntry = tuple[ordinal: int, placement: CommentPlacement, text: string]

proc buildCommentIndex(doc: ProgramDocument): Table[string, seq[CommentEntry]] =
  var byKey = initTable[string, seq[CommentEntry]]()
  for c in doc.comments:
    let key = keyStr(c.formIndex, c.containerPath, c.afterChild)
    byKey.mgetOrPut(key, @[]).add (c.ordinal, c.placement, c.text)
  for key, lst in byKey:
    var sorted = lst
    sorted.sort(proc(a, b: CommentEntry): int = cmp(a.ordinal, b.ordinal))
    result[key] = sorted

proc emitComments(sb: var string, idx: Table[string, seq[CommentEntry]],
                   formIndex: int, path: DocPath, afterChild: int): bool =
  ## Emits every comment at this boundary. A trailing comment stays on the
  ## current line (leading space, no leading newline); a standalone comment
  ## gets its own line. Every comment is followed by a forced newline, since
  ## a line comment consumes to end-of-line and would otherwise swallow
  ## whatever is written next. Returns true iff `sb` now ends with that
  ## forced newline (so the caller must not add its own separating space).
  let key = keyStr(formIndex, path, afterChild)
  if not idx.hasKey(key): return false
  for entry in idx[key]:
    if entry.placement == cpTrailing:
      sb.add ' '
    elif sb.len > 0 and sb[^1] != '\n':
      sb.add '\n'
    sb.add entry.text
    sb.add '\n'
  true

proc emitOpen(sb: var string, idx: Table[string, seq[CommentEntry]],
              formIndex: int, path: DocPath): bool =
  ## Drains both the precise "before first child" (-1) and the opaque
  ## "somewhere in here, exact position not tracked" (-2) comments right
  ## after a container's opening delimiter, so opaque-anchored comments
  ## (see scanOpaque) are never silently dropped by the writer.
  let a = emitComments(sb, idx, formIndex, path, -1)
  let b = emitComments(sb, idx, formIndex, path, -2)
  a or b

proc writeValue(sb: var string, v: Value, idx: Table[string, seq[CommentEntry]],
                 formIndex: int, path: DocPath)

proc writeValue(sb: var string, v: Value, idx: Table[string, seq[CommentEntry]],
                 formIndex: int, path: DocPath) =
  case v.kind
  of vkNode:
    sb.add(if v.nodeImmutable: "#(" else: "(")
    var justBroke = emitOpen(sb, idx, formIndex, path)
    writeValue(sb, v.head, idx, formIndex, path & propertySegment("head"))
    justBroke = emitComments(sb, idx, formIndex, path, 0)
    var i = 0
    for k, val in v.meta.pairs:
      if not justBroke: sb.add ' '
      if val.kind == vkBool and val.boolVal:
        sb.add "@@" & k
      else:
        sb.add "@" & k & ' '
        writeValue(sb, val, idx, formIndex, path & propertySegment("meta") & propertySegment(k))
      justBroke = emitComments(sb, idx, formIndex, path, 1 + i)
      inc i
    var j = 0
    for k, val in v.props.pairs:
      if not justBroke: sb.add ' '
      if val.kind == vkBool and val.boolVal:
        sb.add "^^" & k
      else:
        sb.add "^" & k & ' '
        writeValue(sb, val, idx, formIndex, path & propertySegment(k))
      justBroke = emitComments(sb, idx, formIndex, path, 1 + v.meta.len + j)
      inc j
    for bi, it in v.body:
      if not justBroke: sb.add ' '
      writeValue(sb, it, idx, formIndex, path & indexSegment(bi.int64))
      justBroke = emitComments(sb, idx, formIndex, path, 1 + v.meta.len + v.props.len + bi)
    sb.add ')'
  of vkList:
    sb.add(if v.listImmutable: "#[" else: "[")
    var justBroke = emitOpen(sb, idx, formIndex, path)
    for i, it in v.listItems:
      if not justBroke and i > 0: sb.add ' '
      writeValue(sb, it, idx, formIndex, path & indexSegment(i.int64))
      justBroke = emitComments(sb, idx, formIndex, path, i)
    sb.add ']'
  of vkMap:
    sb.add(if v.mapImmutable: "#{" else: "{")
    var justBroke = emitOpen(sb, idx, formIndex, path)
    var i = 0
    for k, val in v.mapEntries:
      if not justBroke and i > 0: sb.add ' '
      if val.kind == vkBool and val.boolVal:
        sb.add "^^" & k
      else:
        sb.add "^" & k & " "
        writeValue(sb, val, idx, formIndex, path & propertySegment(k))
      justBroke = emitComments(sb, idx, formIndex, path, i)
      inc i
    sb.add '}'
  of vkHashMap:
    sb.add "{{"
    var justBroke = emitOpen(sb, idx, formIndex, path)
    for i, entry in v.hashMapEntries:
      if not justBroke and i > 0: sb.add ' '
      sb.add print(entry.key)
      sb.add " : "
      writeValue(sb, entry.val, idx, formIndex, path & indexSegment(i.int64))
      justBroke = emitComments(sb, idx, formIndex, path, i)
    sb.add "}}"
  else:
    sb.add print(v)

proc writeCanonical*(doc: ProgramDocument): string =
  let idx = doc.buildCommentIndex()
  var sb = ""
  if doc.hasBangLine:
    sb.add doc.bangLine
    sb.add '\n'
  discard emitComments(sb, idx, -1, @[], -1)
  for f in 0 ..< doc.forms.len:
    if sb.len > 0 and sb[^1] != '\n': sb.add '\n'
    writeValue(sb, doc.forms[f], idx, f, @[])
    discard emitComments(sb, idx, -1, @[], f)
  result = sb
