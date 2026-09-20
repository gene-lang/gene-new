## Immutable provider-selected constraint primitives. These are predicates on
## concrete scalar facts, not grants. Alternative and intersection nodes retain
## exact predicates when a bounded inclusion proof cannot simplify them.

import std/[algorithm, os, strutils]
import ./[capability_literals, capability_patterns]
export capability_patterns.CapabilityCoverage
export capability_patterns.CapabilityProofBudget
export capability_patterns.newCapabilityProofBudget
export capability_patterns.CapabilityConstraintError
export capability_patterns.CapabilityProofLimitError

type
  CapabilityConstraintKind* = enum
    cckAny, cckEmpty, cckExact, cckPattern, cckTree,
    cckMaximum, cckMinimum, cckAlternatives, cckIntersection
  CapabilityConstraint* = ref object
    kindValue: CapabilityConstraintKind
    keyValue: string
    exactValue: CapabilityScalar
    patternValue: CapabilityPattern
    rootValue: string
    limitValue: int64
    operandsValue: seq[CapabilityConstraint]

let
  anyConstraint = CapabilityConstraint(kindValue: cckAny, keyValue: "*")
  emptyConstraint = CapabilityConstraint(kindValue: cckEmpty, keyValue: "!")

proc constraintAny*(): CapabilityConstraint = anyConstraint
proc constraintEmpty*(): CapabilityConstraint = emptyConstraint

proc requireConstraint(constraint: CapabilityConstraint) =
  if constraint == nil:
    raise newException(CapabilityConstraintError, "nil capability constraint")

proc kind*(constraint: CapabilityConstraint): CapabilityConstraintKind =
  constraint.requireConstraint()
  constraint.kindValue

proc canonicalKey*(constraint: CapabilityConstraint): string =
  constraint.requireConstraint()
  constraint.keyValue

proc operands*(constraint: CapabilityConstraint): seq[CapabilityConstraint] =
  constraint.requireConstraint()
  for operand in constraint.operandsValue:
    result.add operand

proc exactScalar*(constraint: CapabilityConstraint): CapabilityScalar =
  if constraint.kind != cckExact:
    raise newException(CapabilityConstraintError, "constraint is not an exact value")
  constraint.exactValue

proc scalarKey(value: CapabilityScalar): string =
  case value.kind
  of cskInvalid, cskWildcard:
    raise newException(CapabilityConstraintError,
      "wildcard is not a concrete capability value")
  of cskText: "s" & $value.text.len & ":" & value.text
  of cskInteger: "i" & $value.integer
  of cskBoolean:
    if value.boolean: "b1" else: "b0"

proc constraintExact*(value: CapabilityScalar): CapabilityConstraint =
  var normalized = value
  if value.kind == cskText:
    normalized.stringMode = csmLiteral
  CapabilityConstraint(kindValue: cckExact,
    keyValue: "=" & scalarKey(normalized), exactValue: normalized)

proc constraintPattern*(pattern: string, literal = false): CapabilityConstraint =
  let compiled = compileCapabilityPattern(pattern, literal)
  if compiled.isLiteral:
    return constraintExact(capabilityText(compiled.literalText))
  CapabilityConstraint(kindValue: cckPattern,
    keyValue: "p" & compiled.canonicalKey, patternValue: compiled)

proc constraintMaximum*(limit: int64): CapabilityConstraint =
  CapabilityConstraint(kindValue: cckMaximum,
    keyValue: "<=" & $limit, limitValue: limit)

proc constraintMinimum*(limit: int64): CapabilityConstraint =
  CapabilityConstraint(kindValue: cckMinimum,
    keyValue: ">=" & $limit, limitValue: limit)

proc constraintTree*(root: string): CapabilityConstraint =
  if not root.isAbsolute or '\0' in root:
    raise newException(CapabilityConstraintError,
      "filesystem tree constraint requires an absolute literal path")
  let path = normalizedPath(root)
  CapabilityConstraint(kindValue: cckTree,
    keyValue: "t" & $path.len & ":" & path, rootValue: path)

proc treeRoot*(constraint: CapabilityConstraint): string =
  if constraint.kind != cckTree:
    raise newException(CapabilityConstraintError, "constraint is not a tree root")
  constraint.rootValue

proc within(path, root: string): bool =
  path == root or (root == $DirSep and path.startsWith($DirSep)) or
    path.startsWith(root & $DirSep)

proc matches*(constraint: CapabilityConstraint, fact: CapabilityScalar,
              budget: var CapabilityProofBudget): bool =
  constraint.requireConstraint()
  if fact.kind in {cskInvalid, cskWildcard}:
    raise newException(CapabilityConstraintError,
      "concrete operation facts cannot contain a wildcard token")
  case constraint.kindValue
  of cckAny: true
  of cckEmpty: false
  of cckExact: scalarKey(fact) == scalarKey(constraint.exactValue)
  of cckPattern:
    fact.kind == cskText and constraint.patternValue.matches(fact.text, budget)
  of cckTree:
    fact.kind == cskText and fact.text.isAbsolute and '\0' notin fact.text and
      within(normalizedPath(fact.text), constraint.rootValue)
  of cckMaximum:
    fact.kind == cskInteger and fact.integer <= constraint.limitValue
  of cckMinimum:
    fact.kind == cskInteger and fact.integer >= constraint.limitValue
  of cckAlternatives:
    for operand in constraint.operandsValue:
      if operand.matches(fact, budget):
        return true
    false
  of cckIntersection:
    for operand in constraint.operandsValue:
      if not operand.matches(fact, budget):
        return false
    true

proc matches*(constraint: CapabilityConstraint, fact: CapabilityScalar): bool =
  var budget = newCapabilityProofBudget()
  constraint.matches(fact, budget)

proc compound(kind: CapabilityConstraintKind,
              operands: openArray[CapabilityConstraint],
              budget: var CapabilityProofBudget): CapabilityConstraint =
  var flattened: seq[CapabilityConstraint]
  for operand in operands:
    operand.requireConstraint()
    if kind == cckIntersection:
      if operand.kindValue == cckEmpty:
        return constraintEmpty()
      if operand.kindValue == cckAny:
        continue
    else:
      if operand.kindValue == cckAny:
        return constraintAny()
      if operand.kindValue == cckEmpty:
        continue
    if operand.kindValue == kind:
      flattened.add operand.operandsValue
    else:
      flattened.add operand
  flattened.sort(proc(a, b: CapabilityConstraint): int =
    cmp(a.keyValue, b.keyValue))
  var unique: seq[CapabilityConstraint]
  for operand in flattened:
    if unique.len == 0 or unique[^1].keyValue != operand.keyValue:
      unique.add operand
  if unique.len == 0:
    return if kind == cckIntersection: constraintAny() else: constraintEmpty()
  if unique.len == 1:
    return unique[0]
  if kind == cckIntersection:
    for candidate in unique:
      if candidate.kindValue == cckExact:
        for operand in unique:
          if not operand.matches(candidate.exactValue, budget):
            return constraintEmpty()
        return candidate
    var lower = low(int64)
    var upper = high(int64)
    var root = ""
    var allTrees = true
    for operand in unique:
      case operand.kindValue
      of cckMinimum: lower = max(lower, operand.limitValue)
      of cckMaximum: upper = min(upper, operand.limitValue)
      of cckTree:
        if root.len == 0 or within(operand.rootValue, root):
          root = operand.rootValue
        elif not within(root, operand.rootValue):
          return constraintEmpty()
      else: discard
      if operand.kindValue != cckTree:
        allTrees = false
    if lower > upper:
      return constraintEmpty()
    if allTrees:
      return constraintTree(root)
  var key = if kind == cckIntersection: "&" else: "|"
  for operand in unique:
    key.add $operand.keyValue.len & ":" & operand.keyValue
  CapabilityConstraint(kindValue: kind, keyValue: key, operandsValue: unique)

proc constraintAlternatives*(operands: openArray[CapabilityConstraint]):
    CapabilityConstraint =
  var budget = newCapabilityProofBudget()
  compound(cckAlternatives, operands, budget)

proc constraintIntersection*(operands: openArray[CapabilityConstraint]):
    CapabilityConstraint =
  var budget = newCapabilityProofBudget()
  compound(cckIntersection, operands, budget)

proc constraintIntersection*(operands: openArray[CapabilityConstraint],
    budget: var CapabilityProofBudget): CapabilityConstraint =
  compound(cckIntersection, operands, budget)

proc covers*(granted, requested: CapabilityConstraint,
             budget: var CapabilityProofBudget): CapabilityCoverage =
  granted.requireConstraint()
  requested.requireConstraint()
  if granted.keyValue == requested.keyValue or granted.kindValue == cckAny or
      requested.kindValue == cckEmpty:
    return ccCovered
  if requested.kindValue == cckAlternatives:
    var unknown = false
    for alternative in requested.operandsValue:
      case granted.covers(alternative, budget)
      of ccCovered: discard
      of ccNotCovered: return ccNotCovered
      of ccCannotProve: unknown = true
    return if unknown: ccCannotProve else: ccCovered
  if granted.kindValue == cckIntersection:
    var unknown = false
    for operand in granted.operandsValue:
      case operand.covers(requested, budget)
      of ccCovered: discard
      of ccNotCovered: return ccNotCovered
      of ccCannotProve: unknown = true
    return if unknown: ccCannotProve else: ccCovered
  if requested.kindValue == cckExact:
    try:
      return if granted.matches(requested.exactValue, budget): ccCovered
             else: ccNotCovered
    except CapabilityProofLimitError:
      return ccCannotProve
  if granted.kindValue == cckAlternatives:
    for alternative in granted.operandsValue:
      if alternative.covers(requested, budget) == ccCovered:
        return ccCovered
    # An arbitrary union might cover a request despite no single operand
    # containing it. Do not claim semantic noncoverage without that proof.
    return ccCannotProve
  if requested.kindValue == cckIntersection:
    for operand in requested.operandsValue:
      if granted.covers(operand, budget) == ccCovered:
        return ccCovered
    return ccCannotProve
  if granted.kindValue == cckEmpty:
    return ccNotCovered
  if requested.kindValue == cckAny:
    return ccNotCovered
  if granted.kindValue == requested.kindValue:
    case granted.kindValue
    of cckPattern:
      return granted.patternValue.covers(requested.patternValue, budget)
    of cckTree:
      return if within(requested.rootValue, granted.rootValue): ccCovered
             else: ccNotCovered
    of cckMaximum:
      return if granted.limitValue >= requested.limitValue: ccCovered
             else: ccNotCovered
    of cckMinimum:
      return if granted.limitValue <= requested.limitValue: ccCovered
             else: ccNotCovered
    else: discard
  if granted.kindValue == cckExact and requested.kindValue == cckPattern:
    return ccNotCovered
  ccCannotProve

proc covers*(granted, requested: CapabilityConstraint): CapabilityCoverage =
  var budget = newCapabilityProofBudget()
  covers(granted, requested, budget)
