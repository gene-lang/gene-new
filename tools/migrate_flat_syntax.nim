## Reader-based migration from grouped/positional `if` to flat clause syntax.
##
## Two targets:
##   --to grouped  Normalize legacy positional forms to `(then …)`/`(else …)`
##                 so the repository still runs on the old compiler.
##   --to flat     Accept a legacy or grouped checkout and emit the cutover
##                 spelling: flat arms, `do` for a one-arm sequence, and flat
##                 `when`/`else` arms for `match`.
##
## The legacy decoder is frozen here. The flat decoder is shared with the
## compiler (`gene/clause_syntax`). The tool edits only the byte ranges of the
## forms it rewrites, so surrounding whitespace and comments survive.
##
## Nothing is written unless `--write` is passed; the default previews the
## changed lines.
##
## `--strip-if-do` removes redundant `(do …)` wrappers from `if` arms and
## re-renders only those forms in the canonical flat layout, preserving
## comments, quoted data, and the surrounding source.
##
## Run the flat target on a clean legacy checkout. After phase 3 a positional
## `(if c a b)` is an intentional two-expression truthy arm, which the legacy
## decoder cannot distinguish from the old two-arm form; do not rerun the flat
## target as a formatter.

import std/[algorithm, os, osproc, strutils, tables]
import ../src/gene/[clause_syntax, reader, types]
import ../src/tools/fmt
import ../src/tools/source_index

type
  MigrationMode* = enum
    mmGrouped
    mmFlat
    mmStripIfDo
    mmFormatClauses

  MigrationIssue* = object
    path*: string
    line*, col*: int
    message*: string

  Edit* = object
    startByte*, endByte*: int
    text*: string

  RewriteResult* = object
    text*: string
    changes*: int
    edits*: seq[Edit]
    issues*: seq[MigrationIssue]

  FormKind* = enum
    fkAtom, fkGroup

  Form* = ref object
    kind*: FormKind
    startByte*, endByte*: int
    headStart*, headEnd*: int
    headText*: string
    headForm*: Form        ## a computed/head-position form, for recursion
    openEnd*: int          ## byte just after the opener (groups)
    closeStart*: int       ## byte of the closer, or -1
    body*: seq[Form]       ## forms after the head, props excluded
    props*: seq[Form]      ## property/meta value forms, for recursion
    closed*: bool          ## a group with both delimiters; false in partial text

const
  IfHeads = ["if", "if_yes", "if_present", "match"]

proc isGroup*(f: Form): bool = f.kind == fkGroup
proc isAtom*(f: Form): bool = f.kind == fkAtom
proc hasHead*(f: Form, name: string): bool =
  f.kind == fkGroup and f.headText == name

# ---------------------------------------------------------------------------
# Building a Form tree from the reader-backed structural index
# ---------------------------------------------------------------------------

proc buildForm(doc: SourceDocument, syntaxRef: SyntaxRef): Form =
  ## Convert a token-range syntax tree to the small form tree the migration
  ## reasons about. Props stay available for recursion but never count as
  ## clause children.
  let startByte = syntaxRef.span.startByte
  let endByte = syntaxRef.span.endByte
  result = Form(kind: fkAtom, startByte: startByte, endByte: endByte,
                headStart: startByte, headEnd: endByte, closeStart: -1,
                closed: true)
  case syntaxRef.kind
  of skAtom, skComment, skError, skInterpolation:
    discard
  of skQuasiquote, skUnquote, skSequence, skNode, skList, skPropMap,
      skGeneralMap:
    result.kind = fkGroup
    result.closed = syntaxRef.closed
    result.openEnd = doc.tokens[syntaxRef.startToken].endByte
    if syntaxRef.closed:
      var closeToken = syntaxRef.endToken - 1
      if syntaxRef.kind == skGeneralMap and closeToken > syntaxRef.startToken:
        dec closeToken
      result.closeStart = doc.tokens[closeToken].startByte
    else:
      result.closeStart = endByte
    var rows = children(doc, syntaxRef)
    if syntaxRef.kind == skQuasiquote or syntaxRef.kind == skUnquote:
      result.headText = if syntaxRef.kind == skQuasiquote: "quasiquote" else: "unquote"
      for row in rows:
        result.body.add buildForm(doc, row.syntax)
      return
    if syntaxRef.kind == skSequence:
      for row in rows:
        result.body.add buildForm(doc, row.syntax)
      return
    var headSeen = false
    for row in rows:
      if row.label == "head":
        headSeen = true
        result.headStart = row.syntax.span.startByte
        result.headEnd = row.syntax.span.endByte
        result.headForm = buildForm(doc, row.syntax)
        result.headText = doc.source[row.syntax.span.startByte ..
          (row.syntax.span.endByte - 1)].strip()
        continue
      if row.label.len > 0 and row.label[0] in {'0'..'9'}:
        result.body.add buildForm(doc, row.syntax)
      else:
        result.props.add buildForm(doc, row.syntax)
    if syntaxRef.kind != skNode:
      # Lists and maps have no head; their rows are already in body order.
      discard headSeen

proc parseGeneForms*(text: string, path = "<source>"): seq[Form] =
  ## Parse a Gene source unit into forms. Returns an empty sequence when the
  ## unit does not read; the caller reports the diagnostic.
  let doc = indexSource(text, path)
  for diagnostic in doc.diagnostics:
    raise newException(ValueError, diagnostic.message & " (" & $diagnostic.line &
      ":" & $diagnostic.col & ")")
  for item in doc.topLevel:
    result.add buildForm(doc, item)

# ---------------------------------------------------------------------------
# Frozen legacy clause decoding
# ---------------------------------------------------------------------------

type
  FormArmKind = enum
    fakThen, fakElif, fakWhen, fakElse

  FormArm = object
    kind: FormArmKind
    header: Form          ## elif condition / when pattern
    body: seq[Form]
    clause: Form          ## the grouping `(elif …)`/`(when …)`/`(else …)` node

  LegacyIf = object
    valid: bool
    reason: string
    flatLike: bool
    grouped: bool
    condition: Form
    thenBody: seq[Form]
    thenClause: Form
    arms: seq[FormArm]
    elseBody: seq[Form]
    hasElse: bool

  LegacyPresent = object
    valid: bool
    reason: string
    flatLike: bool
    binder: Form
    tested: Form
    body: seq[Form]
    elseBody: seq[Form]
    hasElse: bool
    elseClause: Form

  LegacyMatch = object
    valid: bool
    reason: string
    flatLike: bool
    value: Form
    arms: seq[FormArm]
    elseBody: seq[Form]
    hasElse: bool

proc atomicText(f: Form, text: string): string =
  if f.kind != fkAtom or f.startByte < 0 or f.endByte > text.len:
    return ""
  text[f.startByte ..< f.endByte]

proc isBareMarker(f: Form, text: string, names: openArray[string]): bool =
  let value = atomicText(f, text)
  for name in names:
    if value == name:
      return true
  false

proc decodeLegacyIf(f: Form, text: string): LegacyIf =
  let body = f.body
  if body.len == 0:
    return LegacyIf(valid: false, reason: "if requires a condition")
  result.valid = true
  result.condition = body[0]
  if body.len == 1:
    return
  # A bare marker in an arm position of a legacy positional form is a body
  # value, not a marker; `(do else)` keeps that reading after the cutover.
  if body.len == 2 and body[1].isBareMarker(text, ["elif", "else"]):
    result.thenBody = @[body[1]]
    result.arms.add FormArm(kind: fakThen, body: result.thenBody)
    return
  if body.len == 3 and not body[1].isBareMarker(text, ["elif", "else"]) and
      body[2].isBareMarker(text, ["elif", "else"]):
    result.thenBody = @[body[1]]
    result.elseBody = @[body[2]]
    result.hasElse = true
    result.arms.add FormArm(kind: fakThen, body: result.thenBody)
    result.arms.add FormArm(kind: fakElse, body: result.elseBody)
    return
  # Already flat (or phase-2 output): markers among the immediate children.
  var flat = false
  for i in 1 ..< body.len:
    if body[i].isBareMarker(text, ["elif", "else"]):
      flat = true
  if flat:
    result.flatLike = true
    var arm = FormArm(kind: fakThen)
    var i = 1
    var sawElse = false
    while i < body.len:
      if body[i].isBareMarker(text, ["elif"]):
        if arm.body.len == 0:
          return LegacyIf(valid: false,
                          reason: "each arm requires at least one expression")
        if i + 1 >= body.len:
          return LegacyIf(valid: false, reason: "elif requires a condition")
        result.arms.add arm
        arm = FormArm(kind: fakElif, header: body[i + 1])
        i += 2
      elif body[i].isBareMarker(text, ["else"]):
        if arm.body.len == 0 and not (result.arms.len == 0 and i == 1):
          return LegacyIf(valid: false,
                          reason: "each arm requires at least one expression")
        if result.arms.len > 0 or i > 1:
          result.arms.add arm
        elif arm.body.len > 0:
          result.arms.add arm
        for j in i + 1 ..< body.len:
          result.elseBody.add body[j]
        result.hasElse = true
        sawElse = true
        break
      else:
        arm.body.add body[i]
        inc i
    if not sawElse:
      if arm.body.len == 0:
        return LegacyIf(valid: false,
                        reason: "each arm requires at least one expression")
      result.arms.add arm
    return
  if body[1].hasHead("then"):
    result.grouped = true
    let clause = body[1]
    result.thenClause = clause
    for i in 0 ..< clause.body.len:
      result.thenBody.add clause.body[i]
    if result.thenBody.len == 0:
      return LegacyIf(valid: false, reason: "then requires a body")
    result.arms.add FormArm(kind: fakThen, body: result.thenBody,
                            clause: clause)
    var i = 2
    while i < body.len:
      let clause = body[i]
      if clause.hasHead("elif"):
        if clause.body.len < 2:
          return LegacyIf(valid: false,
                          reason: "elif requires a condition and a body")
        var clauseBody: seq[Form]
        for j in 1 ..< clause.body.len:
          clauseBody.add clause.body[j]
        result.arms.add FormArm(kind: fakElif, header: clause.body[0],
                                body: clauseBody, clause: clause)
        inc i
      elif clause.hasHead("else"):
        if i != body.high:
          return LegacyIf(valid: false, reason: "else must be the final clause")
        for j in 0 ..< clause.body.len:
          result.elseBody.add clause.body[j]
        if result.elseBody.len == 0:
          return LegacyIf(valid: false, reason: "else requires a body")
        result.hasElse = true
        result.arms.add FormArm(kind: fakElse, body: result.elseBody,
                                clause: clause)
        inc i
      else:
        return LegacyIf(valid: false,
                        reason: "mixed positional/grouped or non-clause form")
    return
  # Positional two-arm form.
  case body.len
  of 2:
    result.thenBody = @[body[1]]
    result.arms.add FormArm(kind: fakThen, body: result.thenBody)
  of 3:
    result.thenBody = @[body[1]]
    result.elseBody = @[body[2]]
    result.hasElse = true
    result.arms.add FormArm(kind: fakThen, body: result.thenBody)
    result.arms.add FormArm(kind: fakElse, body: result.elseBody)
  else:
    return LegacyIf(valid: false,
                    reason: "positional if has extra operands; review by hand")

proc decodeLegacyPresent(f: Form, text: string): LegacyPresent =
  let body = f.body
  if body.len < 3:
    return LegacyPresent(valid: false,
      reason: "if_present requires a name, an expression and a body")
  result.valid = true
  result.binder = body[0]
  result.tested = body[1]
  var elseAt = -1
  for i in 2 ..< body.len:
    if body[i].hasHead("else"):
      if elseAt >= 0:
        return LegacyPresent(valid: false, reason: "else must be the last form")
      elseAt = i
    elif body[i].isBareMarker(text, ["else"]):
      elseAt = -2
      result.flatLike = true
      break
    elif body[i].hasHead("then") or body[i].hasHead("elif") or
        body[i].isBareMarker(text, ["elif"]):
      return LegacyPresent(valid: false,
        reason: "takes body forms and an optional else, not then/elif")
  if result.flatLike:
    # Flat marker: leave the form alone; flat decoding owns it.
    var arm = FormArm(kind: fakThen)
    var i = 2
    while i < body.len:
      if body[i].isBareMarker(text, ["else"]):
        result.elseBody = body[i + 1 .. ^1]
        result.hasElse = true
        break
      arm.body.add body[i]
      inc i
    result.body = arm.body
    return
  let last = if elseAt >= 0: elseAt else: body.len
  for i in 2 ..< last:
    result.body.add body[i]
  if result.body.len == 0:
    return LegacyPresent(valid: false, reason: "requires a body")
  if elseAt >= 0:
    if elseAt != body.high:
      return LegacyPresent(valid: false, reason: "else must be the last form")
    let clause = body[elseAt]
    result.elseClause = clause
    for j in 0 ..< clause.body.len:
      result.elseBody.add clause.body[j]
    if result.elseBody.len == 0:
      return LegacyPresent(valid: false, reason: "else requires a body")
    result.hasElse = true

proc decodeLegacyMatch(f: Form, text: string): LegacyMatch =
  let body = f.body
  if body.len < 2:
    return LegacyMatch(valid: false,
                       reason: "match requires a value and at least one arm")
  result.valid = true
  result.value = body[0]
  if body.len > 1:
    if body[1].isBareMarker(text, ["when", "else"]):
      result.flatLike = true
      return
    if not body[1].hasHead("when") and not body[1].hasHead("else"):
      return LegacyMatch(valid: false, reason: "requires when/else arms")
  for i in 1 ..< body.len:
    let clause = body[i]
    if clause.hasHead("when"):
      if clause.body.len < 2:
        return LegacyMatch(valid: false,
                           reason: "when requires a pattern and a body")
      var arm = FormArm(kind: fakWhen, header: clause.body[0], clause: clause)
      for j in 1 ..< clause.body.len:
        arm.body.add clause.body[j]
      result.arms.add arm
    elif clause.hasHead("else"):
      if i != body.high:
        return LegacyMatch(valid: false, reason: "else must be the final arm")
      var arm = FormArm(kind: fakElse, clause: clause)
      for j in 0 ..< clause.body.len:
        arm.body.add clause.body[j]
      if arm.body.len == 0:
        return LegacyMatch(valid: false, reason: "else requires a body")
      result.arms.add arm
      result.elseBody = arm.body
      result.hasElse = true
    else:
      return LegacyMatch(valid: false, reason: "requires when/else arms")

# ---------------------------------------------------------------------------
# Rewriting
# ---------------------------------------------------------------------------

proc lineOf(text: string, offset: int): int =
  result = 1
  let bounded = min(max(offset, 0), text.len)
  for i in 0 ..< bounded:
    if text[i] == '\n':
      inc result

proc addDelete(edits: var seq[Edit], startByte, endByte: int) =
  if endByte > startByte:
    edits.add Edit(startByte: startByte, endByte: endByte, text: "")

proc addReplace(edits: var seq[Edit], startByte, endByte: int, text: string) =
  if endByte > startByte:
    edits.add Edit(startByte: startByte, endByte: endByte, text: text)

proc addInsert(edits: var seq[Edit], at: int, text: string) =
  edits.add Edit(startByte: at, endByte: at, text: text)

proc wrapMarkerBody(edits: var seq[Edit], text: string, form: Form) =
  ## A body whose whole expression is the symbol `else`, `elif`, or `when`
  ## would read as a marker after flattening; `(do …)` preserves the value.
  if form.kind != fkAtom:
    return
  let value = atomicText(form, text)
  if value in ["elif", "else", "when"]:
    edits.addInsert(form.startByte, "(do ")
    edits.addInsert(form.endByte, ")")

proc wrapMarkerBodies(edits: var seq[Edit], text: string,
                      forms: openArray[Form]) =
  for form in forms:
    wrapMarkerBody(edits, text, form)

proc stripWrapper(edits: var seq[Edit], clause: Form) =
  ## `(when a b)` -> `when a b`; only the two parens are removed.
  if clause.kind != fkGroup or clause.closeStart < 0:
    return
  edits.addDelete(clause.startByte, clause.startByte + 1)
  edits.addDelete(clause.closeStart, clause.closeStart + 1)

proc stripThenWrapper(edits: var seq[Edit], text: string, clause: Form) =
  ## Remove `(then`/its closing paren, leaving the body forms.
  if clause.kind != fkGroup or clause.headText != "then" or clause.closeStart < 0:
    return
  var openerEnd = clause.headEnd
  if clause.body.len > 0:
    let gapStart = clause.headEnd
    let gapEnd = clause.body[0].startByte
    if gapEnd >= gapStart and '#' notin text[gapStart ..< gapEnd]:
      openerEnd = gapEnd
  edits.addDelete(clause.startByte, openerEnd)
  edits.addDelete(clause.closeStart, clause.closeStart + 1)

proc containsCandidate(form: Form): bool =
  if form.kind != fkGroup:
    return false
  if form.headText in IfHeads:
    return true
  for item in form.body:
    if containsCandidate(item): return true
  for item in form.props:
    if containsCandidate(item): return true
  false

proc rewriteIf(form: Form, text: string, mode: MigrationMode,
               edits: var seq[Edit], issues: var seq[MigrationIssue],
               path: string)
proc rewriteIfYes(form: Form, text: string, mode: MigrationMode,
                  edits: var seq[Edit])
proc rewriteIfNot(form: Form, text: string, mode: MigrationMode,
                  edits: var seq[Edit])
proc rewriteIfPresent(form: Form, text: string, mode: MigrationMode,
                      edits: var seq[Edit], issues: var seq[MigrationIssue],
                      path: string)
proc rewriteMatch(form: Form, text: string, mode: MigrationMode,
                  edits: var seq[Edit], issues: var seq[MigrationIssue],
                  path: string)
proc rewriteForm(form: Form, text: string, mode: MigrationMode,
                 edits: var seq[Edit], issues: var seq[MigrationIssue],
                 path: string)

proc needsMigration(form: Form, text: string): bool =
  if form.kind != fkGroup:
    return false
  case form.headText
  of "if":
    let decoded = decodeLegacyIf(form, text)
    if not decoded.valid or decoded.grouped:
      return true
    if not decoded.flatLike and decoded.hasElse:
      return true
    for arm in decoded.arms:
      for item in arm.body:
        if needsMigration(item, text): return true
    for item in decoded.elseBody:
      if needsMigration(item, text): return true
    false
  of "if_yes":
    true
  of "if_not":
    for item in form.body[1 .. ^1]:
      if item.kind == fkGroup and item.headText == "then":
        return true
    false
  of "if_present":
    let decoded = decodeLegacyPresent(form, text)
    if not decoded.valid or (not decoded.flatLike and decoded.hasElse):
      return true
    for item in decoded.body:
      if needsMigration(item, text): return true
    for item in decoded.elseBody:
      if needsMigration(item, text): return true
    false
  of "match":
    let decoded = decodeLegacyMatch(form, text)
    if not decoded.valid or not decoded.flatLike:
      return true
    false
  of "quote", "quasiquote":
    false
  else:
    if form.headForm != nil and needsMigration(form.headForm, text):
      return true
    for item in form.body:
      if needsMigration(item, text): return true
    for item in form.props:
      if needsMigration(item, text): return true
    false

proc containsQuotedCandidate(form: Form, text: string): bool =
  if form.kind != fkGroup:
    return false
  if form.headText == "unquote":
    return false
  if form.headText in IfHeads and needsMigration(form, text):
    return true
  if form.headForm != nil and containsQuotedCandidate(form.headForm, text):
    return true
  for item in form.body:
    if containsQuotedCandidate(item, text): return true
  for item in form.props:
    if containsQuotedCandidate(item, text): return true
  false

proc rewriteUnquotes(form: Form, text: string, mode: MigrationMode,
                     edits: var seq[Edit], issues: var seq[MigrationIssue],
                     path: string) =
  ## Quoted structure keeps its written shape, but `%(…)` inside a template is
  ## executable code and is migrated.
  if form.kind != fkGroup:
    return
  if form.headText == "unquote":
    for item in form.body:
      rewriteForm(item, text, mode, edits, issues, path)
    return
  for item in form.body:
    rewriteUnquotes(item, text, mode, edits, issues, path)
  for item in form.props:
    rewriteUnquotes(item, text, mode, edits, issues, path)
  if form.headForm != nil:
    rewriteUnquotes(form.headForm, text, mode, edits, issues, path)

proc rewriteForm(form: Form, text: string, mode: MigrationMode,
                 edits: var seq[Edit], issues: var seq[MigrationIssue],
                 path: string) =
  if mode == mmStripIfDo:
    return
  if form.kind != fkGroup:
    return
  if not form.closed:
    issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte),
      message: "unterminated form; likely split across concatenated strings; " &
      "review by hand")
    return
  let head = form.headText
  if head == "quote":
    return
  if head == "quasiquote":
    rewriteUnquotes(form, text, mode, edits, issues, path)
    if containsQuotedCandidate(form, text):
      if getEnv("MIG_DEBUG") == "1":
        stderr.writeLine("quoted candidate: " &
          text[form.startByte ..< min(form.startByte + 160, form.endByte)])
      issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte),
        message: "quoted template builds clause syntax; review by hand")
    return
  if head == "unquote":
    for item in form.body:
      rewriteForm(item, text, mode, edits, issues, path)
    return
  if head.endsWith("!") and head notin ["if_not"]:
    if needsMigration(form, text):
      issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte),
        message: "fexpr argument needs migration; review by hand")
    return
  # Recurse into props, a computed head, and the body before touching this form.
  for item in form.props:
    rewriteForm(item, text, mode, edits, issues, path)
  if form.headForm != nil:
    rewriteForm(form.headForm, text, mode, edits, issues, path)
  for item in form.body:
    rewriteForm(item, text, mode, edits, issues, path)
  case head
  of "if":
    rewriteIf(form, text, mode, edits, issues, path)
  of "if_not":
    rewriteIfNot(form, text, mode, edits)
  of "if_yes":
    rewriteIfYes(form, text, mode, edits)
  of "if_present":
    rewriteIfPresent(form, text, mode, edits, issues, path)
  of "match":
    rewriteMatch(form, text, mode, edits, issues, path)
  else:
    discard

proc rewriteIf(form: Form, text: string, mode: MigrationMode,
               edits: var seq[Edit], issues: var seq[MigrationIssue],
               path: string) =
  let decoded = decodeLegacyIf(form, text)
  if not decoded.valid:
    issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte), message: decoded.reason)
    return
  if decoded.flatLike:
    return
  if not decoded.grouped:
    if mode == mmFlat:
      # Positional: insert the marker between the truthy and false arms.
      wrapMarkerBodies(edits, text, decoded.thenBody)
      wrapMarkerBodies(edits, text, decoded.elseBody)
      if decoded.hasElse:
        edits.addInsert(decoded.elseBody[0].startByte, "else ")
      return
    # Grouped target: wrap a positional two-arm form.
    if decoded.arms.len < 2:
      wrapMarkerBodies(edits, text, decoded.thenBody)
      return
    let thenArm = decoded.arms[0]
    let elseArm = decoded.arms[1]
    wrapMarkerBodies(edits, text, thenArm.body)
    wrapMarkerBodies(edits, text, elseArm.body)
    edits.addInsert(thenArm.body[0].startByte, "(then ")
    edits.addInsert(thenArm.body[^1].endByte, ")")
    edits.addInsert(elseArm.body[0].startByte, "(else ")
    edits.addInsert(elseArm.body[^1].endByte, ")")
    return
  # Grouped -> flat.
  if mode == mmGrouped:
    return
  if decoded.thenClause.kind != fkGroup:
    issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte), message: "empty then clause")
    return
  if decoded.thenBody.len == 0:
    issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte), message: "then requires a body")
    return
  var openerEnd = decoded.thenClause.headEnd
  if decoded.thenBody.len > 0:
    let gapStart = decoded.thenClause.headEnd
    let gapEnd = decoded.thenBody[0].startByte
    if gapEnd >= gapStart and '#' notin text[gapStart ..< gapEnd]:
      openerEnd = gapEnd
  wrapMarkerBodies(edits, text, decoded.thenBody)
  wrapMarkerBodies(edits, text, decoded.elseBody)
  for arm in decoded.arms:
    if arm.kind == fakElif:
      wrapMarkerBodies(edits, text, arm.body)
  edits.addDelete(decoded.thenClause.startByte, openerEnd)
  edits.addDelete(decoded.thenClause.closeStart, decoded.thenClause.closeStart + 1)
  if decoded.arms.len == 1 and not decoded.hasElse and decoded.thenBody.len > 1:
    edits.addInsert(decoded.thenBody[0].startByte, "(do ")
    edits.addInsert(decoded.thenBody[^1].endByte, ")")
  for arm in decoded.arms:
    if arm.kind == fakElif or arm.kind == fakElse:
      stripWrapper(edits, arm.clause)

proc rewriteIfYes(form: Form, text: string, mode: MigrationMode,
                  edits: var seq[Edit]) =
  edits.addReplace(form.headStart, form.headEnd, "if")
  if form.body.len < 2:
    return
  let branch = form.body[1 .. ^1]
  if mode == mmGrouped:
    edits.addInsert(branch[0].startByte, "(then ")
    edits.addInsert(branch[^1].endByte, ")")
  elif branch.len > 1:
    edits.addInsert(branch[0].startByte, "(do ")
    edits.addInsert(branch[^1].endByte, ")")

proc rewriteIfNot(form: Form, text: string, mode: MigrationMode,
                  edits: var seq[Edit]) =
  ## `if_not` has a flat body already; only a leftover `(then ...)` group from
  ## the old clause spelling needs unwrapping.
  if mode != mmFlat or form.body.len < 2:
    return
  for item in form.body[1 .. ^1]:
    if item.kind == fkGroup and item.headText == "then":
      stripThenWrapper(edits, text, item)

proc rewriteIfPresent(form: Form, text: string, mode: MigrationMode,
                      edits: var seq[Edit], issues: var seq[MigrationIssue],
                      path: string) =
  let decoded = decodeLegacyPresent(form, text)
  if not decoded.valid:
    issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte), message: decoded.reason)
    return
  if decoded.flatLike or mode == mmGrouped:
    return
  wrapMarkerBodies(edits, text, decoded.body)
  wrapMarkerBodies(edits, text, decoded.elseBody)
  if decoded.hasElse:
    stripWrapper(edits, decoded.elseClause)

proc rewriteMatch(form: Form, text: string, mode: MigrationMode,
                  edits: var seq[Edit], issues: var seq[MigrationIssue],
                  path: string) =
  let decoded = decodeLegacyMatch(form, text)
  if not decoded.valid:
    issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte), message: decoded.reason)
    return
  if decoded.flatLike or mode == mmGrouped:
    return
  for arm in decoded.arms:
    wrapMarkerBodies(edits, text, arm.body)
  for arm in decoded.arms:
    if arm.kind == fakWhen or arm.kind == fakElse:
      stripWrapper(edits, arm.clause)

# ---------------------------------------------------------------------------
# Edit application
# ---------------------------------------------------------------------------

proc applyEdits(text: string, edits: seq[Edit]): string =
  var ordered = edits
  ordered.sort(proc (a, b: Edit): int =
    result = cmp(b.startByte, a.startByte)
    if result == 0:
      result = cmp(b.endByte, a.endByte))
  result = text
  var limit = text.len
  for edit in ordered:
    let startByte = min(max(edit.startByte, 0), result.len)
    let endByte = min(max(edit.endByte, startByte), result.len)
    if endByte > limit:
      # Overlapping edits would corrupt the source; keep the earlier one.
      continue
    result = result[0 ..< startByte] & edit.text & result[endByte .. ^1]
    limit = startByte

proc validateFlatValue(value: Value): string =
  ## Re-read the rewritten unit and confirm every clause form decodes with the
  ## same decoder the compiler uses. Quoted data and templates keep their
  ## written shape and are not checked.
  case value.kind
  of vkNode:
    if value.head.kind == vkSymbol:
      case value.head.symVal
      of "quote", "quasiquote":
        return ""
      of "if":
        let split = tryDecodeIf(value)
        if not split.valid:
          return "if " & split.reason
      of "if_present":
        let split = tryDecodeIfPresent(value)
        if not split.valid:
          return "if_present " & split.reason
      of "match":
        let split = tryDecodeMatch(value)
        if not split.valid:
          return "match " & split.reason
      of "if_yes":
        return "if_yes remains"
      else:
        discard
    for key, item in value.props:
      let error = validateFlatValue(item)
      if error.len > 0: return error
    let headError = validateFlatValue(value.head)
    if headError.len > 0: return headError
    for item in value.body:
      let error = validateFlatValue(item)
      if error.len > 0: return error
    ""
  of vkList:
    for item in value.listItems:
      let error = validateFlatValue(item)
      if error.len > 0: return error
    ""
  of vkMap:
    for key, item in value.mapEntries:
      let error = validateFlatValue(item)
      if error.len > 0: return error
    ""
  of vkHashMap:
    for entry in value.hashMapEntries:
      let error = validateFlatValue(entry.key)
      if error.len > 0: return error
      let valueError = validateFlatValue(entry.val)
      if valueError.len > 0: return valueError
    ""
  of vkSet:
    for item in value.setItems:
      let error = validateFlatValue(item)
      if error.len > 0: return error
    ""
  else:
    ""

proc validateFlatSource*(text: string, path: string, issues: var seq[MigrationIssue]) =
  var forms: seq[Value]
  try:
    forms = readAll(text, path)
  except CatchableError as error:
    issues.add MigrationIssue(path: path, message:
      "rewritten source does not read: " & error.msg)
    return
  for form in forms:
    let error = validateFlatValue(form)
    if error.len > 0:
      issues.add MigrationIssue(path: path, message:
        "rewritten source does not decode: " & error)
      return

proc onlyLocationMeta(value: Value): bool =
  for key, _ in value.meta:
    if key notin ["source", "line", "col"]:
      return false
  true

const CommentSentinelPrefix = "@@GENE_COMMENT_"

proc isCommentSentinel(value: Value): bool =
  value.kind == vkString and value.strVal.startsWith(CommentSentinelPrefix)

proc spliceDoBody(forms: seq[Value], changed: var bool): seq[Value] =
  ## Sentinels stand in for comments; they do not make an arm multi-expression.
  var meaningful = 0
  var doNode = NIL
  for form in forms:
    if isCommentSentinel(form):
      continue
    inc meaningful
    if form.kind == vkNode and form.head.kind == vkSymbol and
        form.head.symVal == "do" and form.props.len == 0 and
        onlyLocationMeta(form) and form.body.len > 0:
      doNode = form
    else:
      return forms
  if meaningful != 1 or doNode.kind == vkNil:
    return forms
  var body: seq[Value]
  for form in forms:
    if isCommentSentinel(form):
      body.add form
    else:
      for item in doNode.body:
        body.add item
  changed = true
  body

proc stripIfDoValue(value: Value): tuple[value: Value, changed: bool] =
  ## Remove a `do` that is the whole body of an `if` arm. The arm already runs
  ## its forms in order, so the wrapper is redundant; nested `if` forms in the
  ## spliced body are cleaned in the same pass.
  case value.kind
  of vkNode:
    if value.head.kind == vkSymbol and
        value.head.symVal in ["quote", "quasiquote"]:
      return (value, false)
    var changed = false
    var head = value.head
    let headResult = stripIfDoValue(value.head)
    if headResult.changed:
      head = headResult.value
      changed = true
    var props = value.props
    for key, item in value.props:
      let itemResult = stripIfDoValue(item)
      if itemResult.changed:
        props[key] = itemResult.value
        changed = true
    var body: seq[Value]
    for item in value.body:
      let itemResult = stripIfDoValue(item)
      body.add itemResult.value
      changed = changed or itemResult.changed
    var node =
      if changed:
        newNode(head, props, body, value.meta, value.nodeImmutable)
      else:
        value
    if node.head.kind == vkSymbol and node.head.symVal == "if":
      let split = tryDecodeIf(node)
      if split.valid:
        var clauses = split.clauses
        var spliced = false
        for i in 0 ..< clauses.arms.len:
          clauses.arms[i].body = spliceDoBody(clauses.arms[i].body, spliced)
        clauses.elseBody = spliceDoBody(clauses.elseBody, spliced)
        if spliced:
          node = rebuildIf(node, clauses)
          changed = true
    (node, changed)
  of vkList:
    var items: seq[Value]
    var changed = false
    for item in value.listItems:
      let itemResult = stripIfDoValue(item)
      items.add itemResult.value
      changed = changed or itemResult.changed
    if changed: (newList(items, value.listImmutable), true) else: (value, false)
  of vkMap:
    var entries = initPropTable()
    var changed = false
    for key, item in value.mapEntries:
      let itemResult = stripIfDoValue(item)
      entries[key] = itemResult.value
      changed = changed or itemResult.changed
    if changed: (newMap(entries, value.mapImmutable), true) else: (value, false)
  of vkHashMap:
    var entries: seq[HashMapEntry]
    var changed = false
    for entry in value.hashMapEntries:
      let keyResult = stripIfDoValue(entry.key)
      let valueResult = stripIfDoValue(entry.val)
      entries.add HashMapEntry(key: keyResult.value, val: valueResult.value)
      changed = changed or keyResult.changed or valueResult.changed
    if changed: (newHashMap(entries), true) else: (value, false)
  of vkSet:
    var items: seq[Value]
    var changed = false
    for item in value.setItems:
      let itemResult = stripIfDoValue(item)
      items.add itemResult.value
      changed = changed or itemResult.changed
    if changed: (newSet(items), true) else: (value, false)
  else:
    (value, false)

proc hasLoneDoArm(form: Form, text: string): bool =
  let body = form.body
  var i = 1
  var armBody: seq[Form]
  var found = false
  template closeArm() =
    if armBody.len == 1 and armBody[0].hasHead("do"):
      found = true
  while i < body.len:
    if body[i].isBareMarker(text, ["elif"]):
      closeArm()
      armBody = @[]
      i += 2
    elif body[i].isBareMarker(text, ["else"]):
      closeArm()
      armBody = @[]
      inc i
    else:
      armBody.add body[i]
      inc i
  closeArm()
  found

proc renderIfForm(form: Form, raw: string, text: string,
                  path: string, issues: var seq[MigrationIssue],
                  requireDoChange = true): string =
  ## Format one if form after splicing its do arms. Comments are swapped for
  ## unique string sentinels before reading, then restored as comments. This
  ## keeps comments at their original arm/argument positions while still
  ## letting the formatter lay the form out canonically.
  var comments: seq[tuple[startByte, endByte: int, text: string]]
  try:
    for token in lexAllSpanned(raw, includeTrivia = true):
      if token.kind in {tkLineComment, tkBlockComment}:
        comments.add (token.startByte, token.endByte,
                      raw[token.startByte ..< token.endByte])
  except CatchableError:
    return ""
  var sentinelled = raw
  var sentinels: seq[tuple[token, comment: string]]
  for i in countdown(comments.high, 0):
    let token = "\"@@GENE_COMMENT_" & $form.startByte & "_" & $i & "@@\""
    sentinels.add (token, comments[i].text)
    sentinelled = sentinelled[0 ..< comments[i].startByte] & token &
      sentinelled[comments[i].endByte .. ^1]
  var stripped: tuple[value: Value, changed: bool]
  var wraps: Table[uint64, WrapSyntax]
  try:
    let read = readAllWithLocs(sentinelled, path)
    if read.forms.len != 1 or read.forms[0].kind != vkNode:
      return ""
    wraps = read.wraps
    stripped = stripIfDoValue(read.forms[0])
  except CatchableError as error:
    issues.add MigrationIssue(path: path, line: lineOf(text, form.startByte),
      message: "cannot re-read if form: " & error.msg)
    return ""
  if requireDoChange and not stripped.changed:
    return ""
  let lineStart = text.rfind('\n', 0, form.startByte) + 1
  let column = form.startByte - lineStart
  var rendered = formatForm(stripped.value, wraps, column)
  for (token, comment) in sentinels:
    var replacement = comment
    if comment.startsWith("#") and not comment.startsWith("#<"):
      let at = rendered.find(token)
      if at >= 0:
        let lineBegin = rendered.rfind('\n', 0, at) + 1
        var lineEnd = rendered.find('\n', at + token.len)
        if lineEnd < 0: lineEnd = rendered.len
        var indentLen = 0
        while lineBegin + indentLen < at and
            rendered[lineBegin + indentLen] == ' ':
          inc indentLen
        # A line comment swallows the rest of its line. If formatter output
        # put code after the sentinel, move that code to the next line.
        if rendered[at + token.len ..< lineEnd].strip().len > 0:
          replacement = comment & "\n" & repeat(' ', indentLen + 2)
    rendered = rendered.replace(token, replacement)
  rendered

proc hasCommentToken(raw: string): bool =
  try:
    for token in lexAllSpanned(raw, includeTrivia = true):
      if token.kind in {tkLineComment, tkBlockComment}:
        return true
  except CatchableError:
    return false
  false

proc formatClauseForms(forms: seq[Form], text: string, edits: var seq[Edit],
                       issues: var seq[MigrationIssue], path: string)

proc formatClauseUnquotes(form: Form, text: string, edits: var seq[Edit],
                          issues: var seq[MigrationIssue], path: string) =
  if form.kind != fkGroup:
    return
  if form.headText == "quote":
    return
  if form.headText == "unquote":
    formatClauseForms(form.body, text, edits, issues, path)
    return
  if form.headForm != nil:
    formatClauseUnquotes(form.headForm, text, edits, issues, path)
  for item in form.props:
    formatClauseUnquotes(item, text, edits, issues, path)
  for item in form.body:
    formatClauseUnquotes(item, text, edits, issues, path)

proc formatClauseForms(forms: seq[Form], text: string, edits: var seq[Edit],
                       issues: var seq[MigrationIssue], path: string) =
  for form in forms:
    if form.kind != fkGroup:
      continue
    if form.headText == "quote":
      continue
    if form.headText == "quasiquote":
      formatClauseUnquotes(form, text, edits, issues, path)
      continue
    if form.headText == "unquote":
      formatClauseForms(form.body, text, edits, issues, path)
      continue
    if form.headText in ["if", "if_not", "match", "if_present"]:
      let raw = text[form.startByte ..< form.endByte]
      let rendered = renderIfForm(form, raw, text, path, issues,
                                  requireDoChange = false)
      if rendered.len > 0:
        edits.add Edit(startByte: form.startByte, endByte: form.endByte,
                       text: rendered)
        continue
    if form.headForm != nil:
      formatClauseForms(@[form.headForm], text, edits, issues, path)
    formatClauseForms(form.props, text, edits, issues, path)
    formatClauseForms(form.body, text, edits, issues, path)

proc stripIfDoForms(forms: seq[Form], text: string, edits: var seq[Edit],
                    issues: var seq[MigrationIssue], path: string)

proc stripIfDoUnquotes(form: Form, text: string, edits: var seq[Edit],
                       issues: var seq[MigrationIssue], path: string) =
  ## Quoted structure stays data, but `%(…)` inside a template is code.
  if form.kind != fkGroup:
    return
  if form.headText == "quote":
    return
  if form.headText == "unquote":
    stripIfDoForms(form.body, text, edits, issues, path)
    return
  if form.headForm != nil:
    stripIfDoUnquotes(form.headForm, text, edits, issues, path)
  for item in form.props:
    stripIfDoUnquotes(item, text, edits, issues, path)
  for item in form.body:
    stripIfDoUnquotes(item, text, edits, issues, path)

proc stripIfDoForms(forms: seq[Form], text: string, edits: var seq[Edit],
                    issues: var seq[MigrationIssue], path: string) =
  for form in forms:
    if form.kind != fkGroup:
      continue
    if form.headText == "quote":
      continue
    if form.headText == "quasiquote":
      stripIfDoUnquotes(form, text, edits, issues, path)
      continue
    if form.headText == "unquote":
      stripIfDoForms(form.body, text, edits, issues, path)
      continue
    if form.headText == "if_not":
      for item in form.body[1 .. ^1]:
        if item.hasHead("then"):
          stripThenWrapper(edits, text, item)
          stripIfDoForms(item.body, text, edits, issues, path)
        else:
          stripIfDoForms(@[item], text, edits, issues, path)
      continue
    if form.headText == "if":
      let raw = text[form.startByte ..< form.endByte]
      if getEnv("MIG_DEBUG") == "1":
        stderr.writeLine("if at " & $lineOf(text, form.startByte) &
          " lone=" & $hasLoneDoArm(form, text) & " comments=" &
          $hasCommentToken(raw))
      try:
        let values = readAll(raw, path)
        if values.len == 1 and values[0].kind == vkNode:
          let stripped = stripIfDoValue(values[0])
          if stripped.changed and hasLoneDoArm(form, text):
            let rendered = renderIfForm(form, raw, text, path, issues)
            if rendered.len > 0:
              edits.add Edit(startByte: form.startByte, endByte: form.endByte,
                             text: rendered)
              continue
      except CatchableError as error:
        issues.add MigrationIssue(path: path,
          line: lineOf(text, form.startByte),
          message: "cannot re-read if form: " & error.msg)
        continue
    # Recurse into children; a changed `if` was replaced as a whole.
    if form.headForm != nil:
      stripIfDoForms(@[form.headForm], text, edits, issues, path)
    stripIfDoForms(form.props, text, edits, issues, path)
    stripIfDoForms(form.body, text, edits, issues, path)

proc rewriteGeneSource*(text: string, mode: MigrationMode,
                        path = "<source>"): RewriteResult =
  var issues: seq[MigrationIssue]
  var edits: seq[Edit]
  var forms: seq[Form]
  try:
    forms = parseGeneForms(text, path)
  except ValueError as e:
    issues.add MigrationIssue(path: path, message: e.msg)
    return RewriteResult(text: text, issues: issues)
  if mode == mmFormatClauses:
    formatClauseForms(forms, text, edits, issues, path)
  elif mode == mmStripIfDo:
    stripIfDoForms(forms, text, edits, issues, path)
  else:
    for form in forms:
      rewriteForm(form, text, mode, edits, issues, path)
  result.text = applyEdits(text, edits)
  result.changes = edits.len
  result.edits = edits
  result.issues = issues
  if result.changes > 0:
    validateFlatSource(result.text, path, result.issues)

proc rewriteMarkdownSource*(text: string, mode: MigrationMode,
                            path = "<markdown>"): RewriteResult =
  ## Rewrite only fenced `gene` blocks; prose, headings, and other fences stay
  ## byte-for-byte.
  var issues: seq[MigrationIssue]
  var edits: seq[Edit]
  var lineStarts = @[0]
  for i, c in text:
    if c == '\n':
      lineStarts.add i + 1
  let lines = text.splitLines()
  var i = 0
  while i < lines.len:
    let stripped = lines[i].strip()
    if stripped.startsWith("```gene"):
      let first = i + 1
      var last = first
      while last < lines.len and not lines[last].strip().startsWith("```"):
        inc last
      let startByte = if first < lineStarts.len: lineStarts[first] else: text.len
      let endByte = if last < lineStarts.len: lineStarts[last] else: text.len
      if endByte > startByte:
        let content = text[startByte ..< endByte]
        let inner = rewriteGeneSource(content, mode, path)
        for edit in inner.edits:
          edits.add Edit(startByte: edit.startByte + startByte,
                         endByte: edit.endByte + startByte, text: edit.text)
        for issue in inner.issues:
          issues.add issue
      i = last + 1
    else:
      inc i
  result.text = applyEdits(text, edits)
  result.changes = edits.len
  result.edits = edits
  result.issues = issues

# ---------------------------------------------------------------------------
# Nim string-literal rewriting
# ---------------------------------------------------------------------------

type
  NimLiteral = object
    kind: char            ## 's' single-quoted, 't' triple-quoted
    literalStart*, literalEnd*: int
    contentStart*: int
    contentEnd*: int

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc nimLiterals(text: string): seq[NimLiteral] =
  ## Locate the content ranges of Nim string literals. Gene code in tests
  ## lives in these literals; comments and Nim code itself are not rewritten.
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '#':
      if i + 1 < text.len and text[i + 1] == '[':
        var depth = 1
        i += 2
        while i < text.len and depth > 0:
          if text.continuesWith("#[", i):
            inc depth
            i += 2
          elif text.continuesWith("]#", i):
            dec depth
            i += 2
          else:
            inc i
      else:
        while i < text.len and text[i] != '\n': inc i
    elif c == '"':
      if text.continuesWith("\"\"\"", i):
        let start = i + 3
        var j = start
        while j < text.len and not text.continuesWith("\"\"\"", j):
          inc j
        result.add NimLiteral(kind: 't', literalStart: i,
                              literalEnd: min(j + 3, text.len),
                              contentStart: start,
                              contentEnd: min(j, text.len))
        i = if j < text.len: j + 3 else: text.len
      else:
        var raw = false
        var k = i - 1
        while k >= 0 and text[k] == ' ':
          dec k
        if k >= 0 and text[k] in {'r', 'R'}:
          var before = k - 1
          raw = before < 0 or not isIdentChar(text[before])
        let start = i + 1
        var j = start
        while j < text.len:
          if text[j] == '\\' and not raw:
            j += 2
          elif text[j] == '"':
            break
          else:
            inc j
        result.add NimLiteral(kind: 's', literalStart: i,
                              literalEnd: min(j + 1, text.len),
                              contentStart: start,
                              contentEnd: min(j, text.len))
        i = if j < text.len: j + 1 else: text.len
    elif c == '\'':
      # A char literal is `'x'` or `'\x'`; an apostrophe in prose is not one.
      if i + 2 < text.len and text[i + 1] != '\\' and
          text[i + 1] != '\n' and text[i + 2] == '\'':
        i += 3
      elif i + 3 < text.len and text[i + 1] == '\\' and
          text[i + 3] == '\'':
        i += 4
      else:
        inc i
    else:
      inc i

type
  ScanMode = enum
    smGene
    smNimEscaped

  Scanner = object
    text: string
    pos: int
    mode: ScanMode

proc atEnd(s: Scanner): bool = s.pos >= s.text.len

proc skipSpace(s: var Scanner) =
  while s.pos < s.text.len:
    let c = s.text[s.pos]
    if c in {' ', '\t', '\r', '\n', ',', ';'}:
      inc s.pos
    elif c == '#':
      if s.pos + 1 < s.text.len and s.text[s.pos + 1] == '<':
        s.pos += 2
        while s.pos + 1 < s.text.len and
            not (s.text[s.pos] == '>' and s.text[s.pos + 1] == '#'):
          inc s.pos
        s.pos = min(s.pos + 2, s.text.len)
      elif s.mode == smNimEscaped and s.pos + 1 < s.text.len and
          s.text[s.pos + 1] == '/':
        inc s.pos
      else:
        while s.pos < s.text.len and s.text[s.pos] != '\n':
          if s.mode == smNimEscaped and s.text[s.pos] == '\\' and
              s.pos + 1 < s.text.len and s.text[s.pos + 1] == 'n':
            s.pos += 2
            break
          inc s.pos
    elif s.mode == smNimEscaped and c == '\\' and s.pos + 1 < s.text.len and
        s.text[s.pos + 1] in {'n', 't', 'r', '0', '\\'}:
      s.pos += 2
    else:
      break

proc scanString(s: var Scanner): (int, int) =
  let start = s.pos
  if s.text.continuesWith("\"\"\"", s.pos):
    s.pos += 3
    while s.pos < s.text.len and not s.text.continuesWith("\"\"\"", s.pos):
      inc s.pos
    s.pos = min(s.pos + 3, s.text.len)
    return (start, s.pos)
  if s.mode == smNimEscaped and s.pos + 1 < s.text.len and
      s.text[s.pos] == '\\' and s.text[s.pos + 1] == '"':
    s.pos += 2
    while s.pos + 1 < s.text.len:
      if s.text[s.pos] == '\\' and s.text[s.pos + 1] == '"':
        s.pos += 2
        return (start, s.pos)
      if s.text[s.pos] == '\\':
        s.pos += 2
      else:
        inc s.pos
    return (start, s.pos)
  inc s.pos
  while s.pos < s.text.len:
    if s.text[s.pos] == '\\':
      s.pos += 2
    elif s.text[s.pos] == '"':
      inc s.pos
      return (start, s.pos)
    else:
      inc s.pos

proc closingFor(openToken: string): string =
  case openToken
  of "(": ")"
  of "[": "]"
  of "{": "}"
  of "#(": ")"
  of "#[": "]"
  of "#{": "}"
  of "{{": "}}"
  of "#@": ""
  of "`", "%", "~", "?~", "$": ""
  else: ""

proc scanForm(s: var Scanner): Form

proc scanChildren(s: var Scanner, closer: string, node: Form) =
  while not s.atEnd:
    s.skipSpace()
    if s.atEnd: return
    if closer.len > 0 and s.text.continuesWith(closer, s.pos):
      return
    if s.text[s.pos] in {'^', '@'}:
      # A property or meta group: keep it out of the clause body, but retain
      # its span so nested code in a property value is still rewritten.
      let propStart = s.pos
      var markerLen = 1
      if s.pos + 1 < s.text.len and s.text[s.pos + 1] in {'^', '!'}:
        markerLen = 2
      let marker = s.text[s.pos ..< s.pos + markerLen]
      s.pos += markerLen
      s.skipSpace()
      let key = scanForm(s)
      var propForm = key
      if marker == "^" or marker == "@":
        s.skipSpace()
        let value = scanForm(s)
        if value != nil:
          propForm = value
      if propForm == nil or propForm.endByte <= propStart:
        inc s.pos
        continue
      node.props.add propForm
      continue
    let before = s.pos
    let child = scanForm(s)
    if child != nil:
      node.body.add child
    if s.pos == before:
      inc s.pos

proc scanForm(s: var Scanner): Form =
  s.skipSpace()
  if s.atEnd:
    return nil
  let start = s.pos
  let c = s.text[s.pos]
  if s.mode == smNimEscaped and c == '\\' and s.pos + 1 < s.text.len:
    if s.text[s.pos + 1] == '"':
      let (_, finish) = s.scanString()
      return Form(kind: fkAtom, startByte: start, endByte: finish,
                  headStart: start, headEnd: finish, closeStart: -1,
                  closed: true)
    s.pos += 2
    return scanForm(s)
  if c == '"' or (c == '\\' and s.pos + 1 < s.text.len and
      s.text[s.pos + 1] == '"'):
    let (_, finish) = s.scanString()
    return Form(kind: fkAtom, startByte: start, endByte: finish,
                headStart: start, headEnd: finish, closeStart: -1,
                closed: true)
  if c == '\'':
    inc s.pos
    while s.pos < s.text.len:
      if s.text[s.pos] == '\\':
        s.pos += 2
      elif s.text[s.pos] == '\'':
        inc s.pos
        break
      else:
        inc s.pos
    return Form(kind: fkAtom, startByte: start, endByte: s.pos,
                headStart: start, headEnd: s.pos, closeStart: -1,
                closed: true)
  if c == '(' or c == '[' or c == '{':
    let opener = $c
    let closer = closingFor(opener)
    inc s.pos
    var node = Form(kind: fkGroup, startByte: start, headStart: start,
                    headEnd: start + opener.len, openEnd: s.pos,
                    closeStart: -1)
    if opener == "{" and not s.atEnd and s.text[s.pos] == '{':
      inc s.pos
      node.openEnd = s.pos
    s.scanChildren(closer, node)
    if not s.atEnd and s.text.continuesWith(closer, s.pos):
      node.closeStart = s.pos
      s.pos += closer.len
      node.endByte = s.pos
      node.closed = true
    else:
      node.closeStart = s.pos
      node.endByte = s.pos
      node.closed = false
    # A `(…)` node's first child is its head and is not a body form.
    if opener == "(" and node.body.len > 0:
      let head = node.body[0]
      node.headStart = head.startByte
      node.headEnd = head.endByte
      node.headText = if head.kind == fkAtom:
                        s.text[head.startByte ..< head.endByte]
                      else: ""
      node.headForm = head
      node.body.delete(0)
    return node
  if c == '#' and s.pos + 1 < s.text.len and s.text[s.pos + 1] in {'(', '[', '{'}:
    let opener = "#" & $s.text[s.pos + 1]
    let closer = closingFor(opener)
    s.pos += 2
    var node = Form(kind: fkGroup, startByte: start, headStart: start,
                    headEnd: s.pos, openEnd: s.pos, closeStart: -1)
    s.scanChildren(closer, node)
    if not s.atEnd and s.text.continuesWith(closer, s.pos):
      node.closeStart = s.pos
      s.pos += closer.len
      node.closed = true
    node.endByte = s.pos
    if opener == "#(" and node.body.len > 0:
      let head = node.body[0]
      node.headStart = head.startByte
      node.headEnd = head.endByte
      node.headText = if head.kind == fkAtom:
                        s.text[head.startByte ..< head.endByte]
                      else: ""
      node.headForm = head
      node.body.delete(0)
    return node
  if c == '`' or c == '%':
    # Quasiquote and unquote keep their operand as a form so template code is
    # visible to the migration (and to the quoted-template report).
    s.pos += 1
    let operand = scanForm(s)
    var node = Form(kind: fkGroup,
                    headText: (if c == '`': "quasiquote" else: "unquote"),
                    startByte: start, headStart: start, headEnd: s.pos,
                    openEnd: s.pos, closeStart: -1, closed: true)
    if operand != nil:
      node.body.add operand
      node.endByte = operand.endByte
    else:
      node.endByte = s.pos
    return node
  if c == '$' and s.pos + 1 < s.text.len and
      (s.text[s.pos + 1] == '"' or
       (s.text[s.pos + 1] == '\\' and s.pos + 2 < s.text.len and
        s.text[s.pos + 2] == '"')):
    # Interpolation keeps its operand as one atom; its quoted body is data.
    inc s.pos
    let (_, finish) = s.scanString()
    s.pos = finish
    return Form(kind: fkAtom, startByte: start, endByte: finish,
                headStart: start, headEnd: finish, closeStart: -1,
                closed: true)
  if c == '~' or c == '?' or
      (c == '#' and s.pos + 1 < s.text.len and s.text[s.pos + 1] == '@'):
    # Prefix send forms: one child operand.
    if c == '~' and s.pos + 1 < s.text.len and s.text[s.pos + 1] == '~':
      s.pos += 2
    else:
      while s.pos < s.text.len and s.text[s.pos] in {'~', '?', '@', '#'}:
        inc s.pos
    let operand = scanForm(s)
    if operand != nil:
      return Form(kind: fkAtom, startByte: start, endByte: operand.endByte,
                  headStart: start, headEnd: s.pos, closeStart: -1,
                  closed: true)
    return Form(kind: fkAtom, startByte: start, endByte: s.pos,
                headStart: start, headEnd: s.pos, closeStart: -1,
                closed: true)
  if c == '#' and s.pos + 1 < s.text.len and s.text[s.pos + 1] == '"':
    inc s.pos
    let (_, finish) = s.scanString()
    s.pos = finish
    return Form(kind: fkAtom, startByte: start, endByte: finish,
                headStart: start, headEnd: finish, closeStart: -1,
                closed: true)
  # Atom: run to a delimiter.
  var j = s.pos
  while j < s.text.len and s.text[j] notin
      {' ', '\t', '\r', '\n', '(', ')', '[', ']', '{', '}', ',', ';', '"',
       '\'', '`', '#'}:
    if s.mode == smNimEscaped and s.text[j] == '\\' and j + 1 < s.text.len:
      j += 2
    else:
      inc j
  s.pos = j
  Form(kind: fkAtom, startByte: start, endByte: s.pos, headStart: start,
       headEnd: s.pos, closeStart: -1, closed: true)

proc dumpForm(f: Form, text: string, depth = 0) =
  if f == nil: return
  stderr.writeLine(repeat(' ', depth) & f.headText & " kind=" & $f.kind &
    " closed=" & $f.closed & " body=" & $f.body.len & " text=" &
    (if f.endByte > f.startByte and f.endByte <= text.len:
       text[f.startByte ..< min(f.startByte + 40, f.endByte)]
     else: ""))
  for child in f.body:
    dumpForm(child, text, depth + 2)

proc parseScannedForms(text: string, mode: ScanMode): seq[Form] =
  var s = Scanner(text: text, pos: 0, mode: mode)
  while not s.atEnd:
    s.skipSpace()
    if s.atEnd: break
    let before = s.pos
    let form = scanForm(s)
    if form != nil:
      result.add form
    if s.pos == before:
      inc s.pos

proc gapJoinsLiterals(gap: string): bool =
  ## Whether the text between two string literals is only whitespace, comments
  ## and `&`, so Nim concatenates them into one runtime string.
  var i = 0
  while i < gap.len:
    let c = gap[i]
    if c in {' ', '\t', '\r', '\n', '&'}:
      inc i
    elif c == '#':
      if i + 1 < gap.len and gap[i + 1] == '[':
        var depth = 1
        i += 2
        while i < gap.len and depth > 0:
          if gap.continuesWith("#[", i):
            inc depth; i += 2
          elif gap.continuesWith("]#", i):
            dec depth; i += 2
          else:
            inc i
      else:
        while i < gap.len and gap[i] != '\n': inc i
    else:
      return false
  true

proc locateIn(starts: seq[int], count, offset: int): int =
  result = 0
  while result + 1 < count and offset >= starts[result + 1]:
    inc result

proc rewriteNimSource*(text: string, mode: MigrationMode,
                       path = "<source>"): RewriteResult =
  var issues: seq[MigrationIssue]
  var edits: seq[Edit]
  let literals = nimLiterals(text)
  let debug = getEnv("MIG_DEBUG") == "1"
  # Group concatenated literals so a form split across `"…" & "…"` is seen as
  # one unit; the migration then edits the literals it came from.
  var groups: seq[seq[int]]
  var i = 0
  while i < literals.len:
    var group = @[i]
    var j = i
    while j + 1 < literals.len and literals[j].kind == literals[j + 1].kind and
        gapJoinsLiterals(text[literals[j].literalEnd ..< literals[j + 1].literalStart]):
      group.add j + 1
      inc j
    groups.add group
    i = j + 1

  for group in groups:
    let first = group[0]
    if debug:
      stderr.writeLine("group of " & $group.len & " at " &
        $literals[first].contentStart)
    var combined = ""
    var starts: seq[int]
    for index in group:
      starts.add combined.len
      combined.add text[literals[index].contentStart ..< literals[index].contentEnd]
    if debug and "(match" in combined:
      stderr.writeLine("COMBINED: " & combined)
    if "(if" notin combined and "(match" notin combined and
        "if_yes" notin combined and "if_present" notin combined:
      continue
    let scanMode = if literals[first].kind == 't': smGene else: smNimEscaped
    var forms: seq[Form]
    try:
      forms = parseScannedForms(combined, scanMode)
    except CatchableError:
      continue
    var localEdits: seq[Edit]
    let issueStart = issues.len
    if mode == mmStripIfDo:
      # Triple-quoted literals hold plain Gene source. Single-quoted literals
      # are escaped and stay for the caller to review.
      if literals[first].kind != 't':
        continue
      stripIfDoForms(forms, combined, localEdits, issues, path)
    else:
      if debug and "(match" in combined:
        for form in forms:
          dumpForm(form, combined)
      for form in forms:
        rewriteForm(form, combined, mode, localEdits, issues, path)
    let firstLine = lineOf(text, literals[first].contentStart)
    for i in issueStart ..< issues.len:
      issues[i].line = firstLine + issues[i].line - 1

    for edit in localEdits:
      let startLiteral = locateIn(starts, group.len, edit.startByte)
      let endLiteral = locateIn(starts, group.len, edit.endByte)
      if startLiteral == endLiteral:
        let base = literals[group[startLiteral]].contentStart
        edits.add Edit(startByte: base + edit.startByte - starts[startLiteral],
                       endByte: base + edit.endByte - starts[startLiteral],
                       text: edit.text)
      else:
        # The edit crosses a literal boundary. Keep the replacement at the
        # start literal and delete the remainder of the span.
        let firstStart = literals[group[startLiteral]].contentStart
        let firstLen = literals[group[startLiteral]].contentEnd - firstStart
        let localStart = edit.startByte - starts[startLiteral]
        edits.add Edit(startByte: firstStart + localStart,
                       endByte: firstStart + firstLen, text: edit.text)
        for k in startLiteral + 1 ..< endLiteral:
          edits.add Edit(startByte: literals[group[k]].contentStart,
                         endByte: literals[group[k]].contentEnd, text: "")
        let lastBase = literals[group[endLiteral]].contentStart
        let localEnd = edit.endByte - starts[endLiteral]
        if localEnd > 0:
          edits.add Edit(startByte: lastBase, endByte: lastBase + localEnd,
                         text: "")

  result.text = applyEdits(text, edits)
  result.changes = edits.len
  result.edits = edits
  result.issues = issues

# ---------------------------------------------------------------------------
# Preview and main
# ---------------------------------------------------------------------------

proc preview(path, oldText, newText: string, edits: seq[Edit]) =
  if edits.len == 0 or oldText == newText:
    return
  var minLine = high(int)
  var maxLine = 0
  for edit in edits:
    let line = lineOf(oldText, edit.startByte)
    minLine = min(minLine, line)
    maxLine = max(maxLine, lineOf(oldText, edit.endByte))
  echo "--- " & path
  echo "+++ " & path
  echo "@@ line " & $minLine & " @@"
  let oldLines = oldText.splitLines()
  for i in max(0, minLine - 2) ..< min(oldLines.len, maxLine + 1):
    echo "-" & oldLines[i]
  block:
    # Recompute the edited line region in the new text by applying only the
    # edits that touch it. A preview needs reviewable lines, not a full diff.
    var regionEdits: seq[Edit]
    let regionStart = minLine
    let regionEnd = maxLine
    for edit in edits:
      if lineOf(oldText, edit.startByte) <= regionEnd + 1 and
          lineOf(oldText, edit.endByte) >= regionStart - 1:
        regionEdits.add edit
    let rebuilt = applyEdits(oldText, regionEdits)
    let newLines = rebuilt.splitLines()
    let newStart = max(0, minLine - 2)
    let newEnd = min(newLines.len, maxLine + 1)
    for i in newStart ..< newEnd:
      echo "+" & newLines[i]

proc collectGitFiles(): seq[string] =
  let listed = execProcess("git", args = ["ls-files"], options = {poUsePath})
  for line in listed.splitLines():
    let path = line.strip()
    if path.len > 0 and (path.endsWith(".gene") or path.endsWith(".md")):
      result.add path

proc isTestSource(path: string): bool =
  path.startsWith("tests/") or path.contains("/tests/")

proc main(): int =
  var mode = mmFlat
  var write = false
  var summary = false
  var selected: seq[string]
  for argument in commandLineParams():
    case argument
    of "--to":
      discard
    of "grouped":
      mode = mmGrouped
    of "flat":
      mode = mmFlat
    of "--write":
      write = true
    of "--check", "--summary":
      if argument == "--summary": summary = true
    of "--strip-if-do", "--remove-if-do":
      mode = mmStripIfDo
    of "--format-clauses", "--reindent-clauses":
      mode = mmFormatClauses
    else:
      if argument.startsWith("--to="):
        mode = if argument.endsWith("grouped"): mmGrouped else: mmFlat
      else:
        selected.add argument
  if selected.len == 0:
    selected = collectGitFiles()
  var changedFiles = 0
  var changedForms = 0
  var issueCount = 0
  for path in selected:
    if not fileExists(path):
      continue
    let oldText = readFile(path)
    let rewritten =
      if path.endsWith(".nim") or path.endsWith(".json"):
        rewriteNimSource(oldText, mode, path)
      elif path.endsWith(".md"):
        rewriteMarkdownSource(oldText, mode, path)
      else:
        rewriteGeneSource(oldText, mode, path)
    for issue in rewritten.issues:
      echo path & ":" & $issue.line & ": " & issue.message
      inc issueCount
    if rewritten.text != oldText:
      inc changedFiles
      changedForms += rewritten.changes
      if write:
        writeFile(path, rewritten.text)
      elif not summary:
        preview(path, oldText, rewritten.text, rewritten.edits)
  if write:
    echo $changedFiles & " files changed, " & $changedForms & " edits"
  else:
    echo $changedFiles & " files would change, " & $changedForms & " edits"
  if issueCount > 0:
    echo $issueCount & " forms need review"
  if write and issueCount > 0:
    return 1
  0

when isMainModule:
  quit(main())
