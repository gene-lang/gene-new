## Flat clause decoding for `if`, `if_present`, and `match`.
##
## The reader gives every child of a form the same representation, so a clause
## marker is an ordinary Symbol among the immediate children of its owning
## form. This module is the single decoder for that shape: the VM compiler,
## the macro tree expander, the static value analyses, the web backend, and the
## formatter all read clauses through it.
##
## The decoder is deliberately representation-only: it records the condition,
## pattern, arm bodies, and fallback in source order. Scope, exhaustiveness,
## and evaluation rules belong to each consumer.

import ./types

type
  ClauseArmKind* = enum
    cakThen    ## the `if` truthy arm, or the `if_present` present body
    cakElif
    cakWhen
    cakElse

  ClauseArm* = object
    kind*: ClauseArmKind
    header*: Value   ## an `elif` condition or a `when` pattern; else nil
    body*: seq[Value]

  IfClauses* = object
    condition*: Value
    arms*: seq[ClauseArm]  ## cakThen followed by zero or more cakElif
    elseBody*: seq[Value]
    hasElse*: bool

  PresentClauses* = object
    binder*: Value
    tested*: Value
    body*: seq[Value]
    elseBody*: seq[Value]
    hasElse*: bool

  MatchClauses* = object
    value*: Value
    arms*: seq[ClauseArm]  ## cakWhen arms in order
    elseBody*: seq[Value]
    hasElse*: bool

  IfSplit = tuple[condition: Value, arms: seq[ClauseArm],
                  elseBody: seq[Value], hasElse: bool, valid: bool,
                  reason: string]
  PresentSplit = tuple[clauses: PresentClauses, valid: bool, reason: string]
  MatchSplit = tuple[value: Value, arms: seq[ClauseArm], elseBody: seq[Value],
                     hasElse: bool, valid: bool, reason: string]

proc isSymbolNamed*(value: Value, name: string): bool {.inline.} =
  value.kind == vkSymbol and value.symVal == name

proc isClauseNode*(value: Value, names: openArray[string]): bool =
  ## A legacy grouped clause: an immediate node child such as `(then …)`.
  if value.kind != vkNode or value.head.kind != vkSymbol:
    return false
  for name in names:
    if value.head.symVal == name:
      return true
  false

proc isClauseMarker*(value: Value, names: openArray[string]): bool =
  ## Whether an immediate child is a bare marker symbol. A node whose head is
  ## such a name is a legacy grouped clause, not a marker; the splitters reject
  ## it above with a migration message.
  if value.kind != vkSymbol:
    return false
  for name in names:
    if value.symVal == name:
      return true
  false

proc armError(form: string, reason: string) {.noReturn.} =
  raise newException(GeneError, form & ": " & reason)

proc failIf(reason: string): IfSplit =
  (condition: Value(), arms: @[], elseBody: @[], hasElse: false, valid: false,
   reason: reason)

proc failPresent(reason: string): PresentSplit =
  (clauses: PresentClauses(), valid: false, reason: reason)

proc failMatch(reason: string): MatchSplit =
  (value: Value(), arms: @[], elseBody: @[], hasElse: false, valid: false,
   reason: reason)

proc splitIfArms(node: Value): IfSplit =
  ## Split a flat `if` body without raising. `(if x)` has no arms and returns
  ## nil. The leading `else` form `(if x else c)` is the else-only shape.
  let body = node.body
  if body.len == 0:
    return failIf("requires a condition")
  result.condition = body[0]
  result.valid = true
  if body.len == 1:
    return
  for i in 1 ..< body.len:
    if body[i].isClauseNode(["then", "elif", "else"]):
      return failIf(
        "grouped clause syntax was removed; write flat arms, for example " &
        "(if condition a else b)")

  if body[1].isClauseMarker(["else"]):
    if body.len < 3:
      return failIf("else requires a body")
    result.hasElse = true
    for i in 2 ..< body.len:
      if body[i].isClauseMarker(["else", "elif"]):
        return failIf("arms must not follow else")
      result.elseBody.add body[i]
    if result.elseBody.len == 0:
      return failIf("else requires a body")
    return

  var current = ClauseArm(kind: cakThen)
  var i = 1
  while i < body.len:
    let item = body[i]
    if item.isClauseMarker(["elif"]):
      if current.body.len == 0:
        return failIf("each arm requires at least one expression")
      if i + 1 >= body.len:
        return failIf("elif requires a condition")
      result.arms.add current
      current = ClauseArm(kind: cakElif, header: body[i + 1])
      i += 2
    elif item.isClauseMarker(["else"]):
      if current.body.len == 0:
        return failIf("each arm requires at least one expression")
      result.arms.add current
      result.hasElse = true
      for j in i + 1 ..< body.len:
        if body[j].isClauseMarker(["else", "elif"]):
          return failIf("arms must not follow else")
        result.elseBody.add body[j]
      if result.elseBody.len == 0:
        return failIf("else requires a body")
      return
    else:
      current.body.add item
      inc i
  if current.body.len == 0:
    return failIf("each arm requires at least one expression")
  result.arms.add current

proc decodeIf*(node: Value): IfClauses =
  ## Decode a flat `if`. Raises GeneError for a missing condition, an empty
  ## written arm, a repeated `else`, or an arm after `else`.
  let split = splitIfArms(node)
  if not split.valid:
    armError("if", split.reason)
  result.condition = split.condition
  result.arms = split.arms
  result.elseBody = split.elseBody
  result.hasElse = split.hasElse

proc tryDecodeIf*(node: Value):
    tuple[clauses: IfClauses, valid: bool, reason: string] =
  ## The formatter and analyses need the shape of malformed forms too.
  let split = splitIfArms(node)
  result.valid = split.valid
  result.reason = split.reason
  result.clauses.condition = split.condition
  result.clauses.arms = split.arms
  result.clauses.elseBody = split.elseBody
  result.clauses.hasElse = split.hasElse

proc splitPresentClauses(node: Value): PresentSplit =
  let body = node.body
  if body.len < 3:
    return failPresent("requires a name, an expression and a body")
  result.clauses.binder = body[0]
  result.clauses.tested = body[1]
  result.valid = true
  var elseAt = -1
  for i in 2 ..< body.len:
    if body[i].isClauseNode(["else", "then", "elif"]):
      return failPresent(
        "grouped clause syntax was removed; write body forms and an optional " &
        "bare else")
    if body[i].isClauseMarker(["else"]):
      if elseAt >= 0:
        return failPresent("else must appear once and last")
      elseAt = i
    elif body[i].isClauseMarker(["elif"]):
      return failPresent("takes body forms and an optional else, not elif")
  let last = if elseAt >= 0: elseAt else: body.len
  for i in 2 ..< last:
    result.clauses.body.add body[i]
  if result.clauses.body.len == 0:
    return failPresent("requires a body")
  if elseAt >= 0:
    result.clauses.hasElse = true
    for i in elseAt + 1 ..< body.len:
      if body[i].isClauseMarker(["else", "elif"]):
        return failPresent("else must appear once and last")
      result.clauses.elseBody.add body[i]
    if result.clauses.elseBody.len == 0:
      return failPresent("else requires a body")

proc decodeIfPresent*(node: Value): PresentClauses =
  let split = splitPresentClauses(node)
  if not split.valid:
    armError("if_present", split.reason)
  result = split.clauses

proc tryDecodeIfPresent*(node: Value):
    tuple[clauses: PresentClauses, valid: bool, reason: string] =
  splitPresentClauses(node)

proc splitMatchArms(node: Value): MatchSplit =
  let body = node.body
  if body.len < 2:
    return failMatch("requires a value and at least one arm")
  result.value = body[0]
  result.valid = true
  for i in 1 ..< body.len:
    if body[i].isClauseNode(["when", "else"]):
      return failMatch(
        "grouped clause syntax was removed; write when pattern body... else body...")

  var i = 1
  while i < body.len:
    let item = body[i]
    if item.isClauseMarker(["when"]):
      if i + 1 >= body.len:
        return failMatch("when requires a pattern")
      var arm = ClauseArm(kind: cakWhen, header: body[i + 1])
      i += 2
      while i < body.len and not body[i].isClauseMarker(["when", "else"]):
        arm.body.add body[i]
        inc i
      if arm.body.len == 0:
        return failMatch("each when arm requires at least one expression")
      result.arms.add arm
    elif item.isClauseMarker(["else"]):
      for j in i + 1 ..< body.len:
        if body[j].isClauseMarker(["when", "else"]):
          return failMatch("arms must not follow else")
        result.elseBody.add body[j]
      if result.elseBody.len == 0:
        return failMatch("else requires a body")
      result.hasElse = true
      return
    else:
      return failMatch("requires when/else arms")
  if result.arms.len == 0:
    return failMatch("requires at least one arm")

proc decodeMatch*(node: Value): MatchClauses =
  let split = splitMatchArms(node)
  if not split.valid:
    armError("match", split.reason)
  result.value = split.value
  result.arms = split.arms
  result.elseBody = split.elseBody
  result.hasElse = split.hasElse

proc tryDecodeMatch*(node: Value):
    tuple[clauses: MatchClauses, valid: bool, reason: string] =
  let split = splitMatchArms(node)
  result.valid = split.valid
  result.reason = split.reason
  result.clauses.value = split.value
  result.clauses.arms = split.arms
  result.clauses.elseBody = split.elseBody
  result.clauses.hasElse = split.hasElse

proc rebuildIf*(node: Value, clauses: IfClauses): Value =
  ## Put decoded arms back into the flat reader shape. The macro tree expander
  ## uses this after expanding each arm body.
  var body = @[clauses.condition]
  for arm in clauses.arms:
    if arm.kind == cakElif:
      body.add newSym("elif")
      body.add arm.header
    for form in arm.body:
      body.add form
  if clauses.hasElse:
    body.add newSym("else")
    for form in clauses.elseBody:
      body.add form
  newNode(node.head, node.props, body, node.meta, node.nodeImmutable)

proc rebuildIfPresent*(node: Value, clauses: PresentClauses): Value =
  var body = @[clauses.binder, clauses.tested]
  for form in clauses.body:
    body.add form
  if clauses.hasElse:
    body.add newSym("else")
    for form in clauses.elseBody:
      body.add form
  newNode(node.head, node.props, body, node.meta, node.nodeImmutable)

proc rebuildMatch*(node: Value, clauses: MatchClauses): Value =
  var body = @[clauses.value]
  for arm in clauses.arms:
    body.add newSym("when")
    body.add arm.header
    for form in arm.body:
      body.add form
  if clauses.hasElse:
    body.add newSym("else")
    for form in clauses.elseBody:
      body.add form
  newNode(node.head, node.props, body, node.meta, node.nodeImmutable)
