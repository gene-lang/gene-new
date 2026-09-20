## Full-string capability patterns and bounded language inclusion.
## A policy pattern is compiled once. Concrete operation text is never parsed
## as a pattern. Inclusion explores pairs of determinized NFA states rather
## than matching the source spelling of one pattern against the other.

import std/[sets, unicode]

type
  CapabilityConstraintError* = object of CatchableError
  CapabilityProofLimitError* = object of CapabilityConstraintError
  CapabilityCoverage* = enum
    ccCovered, ccNotCovered, ccCannotProve
  CapabilityProofBudget* = object
    remaining*: int
  PatternToken = object
    wildcard: bool
    character: Rune
  CapabilityPattern* = ref object
    tokens: seq[PatternToken]
    identity: string
    literal: string
    hasWildcard: bool
  PatternState = seq[int]
  PatternStatePair = tuple[requested, granted: PatternState]

const
  MaxCapabilityPatternRunes* = 1024
  MaxCapabilityOperationStringBytes* = 65536
  DefaultCapabilityProofWork* = 65536

proc newCapabilityProofBudget*(work = DefaultCapabilityProofWork):
    CapabilityProofBudget =
  if work < 0:
    raise newException(CapabilityConstraintError,
      "capability proof budget must not be negative")
  CapabilityProofBudget(remaining: work)

proc spend(budget: var CapabilityProofBudget, work: int) =
  if work > budget.remaining:
    budget.remaining = 0
    raise newException(CapabilityProofLimitError,
      "capability pattern evaluation budget exhausted")
  budget.remaining -= work

proc compileCapabilityPattern*(text: string, literal = false): CapabilityPattern =
  if validateUtf8(text) != -1 or text.len > MaxCapabilityPatternRunes * 4:
    raise newException(CapabilityConstraintError,
      "capability pattern is invalid UTF-8 or exceeds its size limit")
  result = CapabilityPattern()
  var escaped = false
  for character in text.runes:
    if not literal and not escaped and character == Rune(ord('\\')):
      escaped = true
      continue
    if escaped and character notin [Rune(ord('\\')), Rune(ord('*'))]:
      raise newException(CapabilityConstraintError,
        "capability patterns escape only asterisk and backslash")
    let wildcard = not literal and not escaped and character == Rune(ord('*'))
    escaped = false
    if wildcard and result.tokens.len > 0 and result.tokens[^1].wildcard:
      continue
    result.tokens.add PatternToken(wildcard: wildcard, character: character)
    if result.tokens.len > MaxCapabilityPatternRunes:
      raise newException(CapabilityConstraintError,
        "capability pattern rune limit exceeded")
    if wildcard:
      result.hasWildcard = true
      result.identity.add "*;"
    else:
      result.identity.add $int32(character) & ";"
      result.literal.add character.toUTF8()
  if escaped:
    raise newException(CapabilityConstraintError,
      "unterminated capability pattern escape")

proc canonicalKey*(pattern: CapabilityPattern): string =
  if pattern == nil:
    raise newException(CapabilityConstraintError, "nil capability pattern")
  pattern.identity

proc isLiteral*(pattern: CapabilityPattern): bool =
  pattern != nil and not pattern.hasWildcard

proc literalText*(pattern: CapabilityPattern): string =
  if not pattern.isLiteral:
    raise newException(CapabilityConstraintError, "pattern is not literal text")
  pattern.literal

proc closure(pattern: CapabilityPattern, initial: PatternState,
             budget: var CapabilityProofBudget): PatternState =
  budget.spend(pattern.tokens.len + initial.len + 1)
  var present = newSeq[bool](pattern.tokens.len + 1)
  for index in initial:
    present[index] = true
  for index in 0 ..< pattern.tokens.len:
    if present[index] and pattern.tokens[index].wildcard:
      present[index + 1] = true
  for index, yes in present:
    if yes:
      result.add index

proc advance(pattern: CapabilityPattern, state: PatternState, character: Rune,
             budget: var CapabilityProofBudget): PatternState =
  budget.spend(state.len)
  var next: PatternState
  for index in state:
    if index == pattern.tokens.len:
      continue
    let token = pattern.tokens[index]
    if token.wildcard:
      next.add index
    elif token.character == character:
      next.add index + 1
  if next.len > 0:
    result = pattern.closure(next, budget)

proc accepts(pattern: CapabilityPattern, state: PatternState): bool =
  state.len > 0 and state[^1] == pattern.tokens.len

proc matches*(pattern: CapabilityPattern, text: string,
              budget: var CapabilityProofBudget): bool =
  if pattern == nil:
    raise newException(CapabilityConstraintError, "nil capability pattern")
  if text.len > MaxCapabilityOperationStringBytes or validateUtf8(text) != -1:
    raise newException(CapabilityConstraintError,
      "concrete capability string is invalid or exceeds its size limit")
  budget.spend(text.len + 1)
  if not pattern.hasWildcard:
    return text == pattern.literal
  if pattern.tokens.len == 1 and pattern.tokens[0].wildcard:
    return true
  var state = pattern.closure(@[0], budget)
  for character in text.runes:
    state = pattern.advance(state, character, budget)
    if state.len == 0:
      return false
  pattern.accepts(state)

proc matches*(pattern: CapabilityPattern, text: string): bool =
  var budget = newCapabilityProofBudget()
  pattern.matches(text, budget)

proc pairKey(pair: PatternStatePair): string =
  for state in pair.requested:
    result.add $state & ","
  result.add "/"
  for state in pair.granted:
    result.add $state & ","

proc covers*(granted, requested: CapabilityPattern,
             budget: var CapabilityProofBudget): CapabilityCoverage =
  if granted == nil or requested == nil:
    raise newException(CapabilityConstraintError, "nil capability pattern")
  if granted.identity == requested.identity or
      (granted.tokens.len == 1 and granted.tokens[0].wildcard):
    return ccCovered
  try:
    if not requested.hasWildcard:
      return if granted.matches(requested.literal, budget): ccCovered
             else: ccNotCovered
    var alphabet: seq[Rune]
    var seenCharacters = initHashSet[int32]()
    for pattern in [granted, requested]:
      for token in pattern.tokens:
        budget.spend(1)
        if not token.wildcard and
            not seenCharacters.containsOrIncl(int32(token.character)):
          alphabet.add token.character
    # Every character not mentioned by a literal has the same transition.
    # A negative sentinel represents that class and cannot equal a valid Rune.
    alphabet.add Rune(-1)
    let initial: PatternStatePair = (
      requested.closure(@[0], budget), granted.closure(@[0], budget))
    var pending = @[initial]
    var visited = initHashSet[string]()
    visited.incl initial.pairKey
    var cursor = 0
    while cursor < pending.len:
      let pair = pending[cursor]
      inc cursor
      budget.spend(1)
      if requested.accepts(pair.requested) and
          not granted.accepts(pair.granted):
        return ccNotCovered
      for character in alphabet:
        let nextRequested = requested.advance(pair.requested, character, budget)
        if nextRequested.len == 0:
          continue
        let next: PatternStatePair = (
          nextRequested, granted.advance(pair.granted, character, budget))
        if not visited.containsOrIncl(next.pairKey):
          pending.add next
    ccCovered
  except CapabilityProofLimitError:
    ccCannotProve

proc covers*(granted, requested: CapabilityPattern): CapabilityCoverage =
  var budget = newCapabilityProofBudget()
  covers(granted, requested, budget)
