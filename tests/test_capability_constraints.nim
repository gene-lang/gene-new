import std/unittest
import gene/[capability_literals, capability_constraints]

suite "normalized capability constraints":
  test "numeric limits and exact identifiers use different orderings":
    check constraintMaximum(5).covers(constraintMaximum(4)) == ccCovered
    check constraintMaximum(4).covers(constraintMaximum(5)) == ccNotCovered
    check constraintMinimum(4).covers(constraintMinimum(5)) == ccCovered
    check constraintMinimum(5).covers(constraintMinimum(4)) == ccNotCovered
    check constraintExact(capabilityInteger(8081)).covers(
      constraintExact(capabilityInteger(8080))) == ccNotCovered
    check constraintExact(capabilityBoolean(true)).covers(
      constraintExact(capabilityBoolean(false))) == ccNotCovered

  test "allowed lists, absent restrictions and empty coverage are distinct":
    let methods = constraintAlternatives([
      constraintExact(capabilityText("GET")),
      constraintExact(capabilityText("POST"))])
    check methods.matches(capabilityText("GET"))
    check not methods.matches(capabilityText("HEAD"))
    check constraintAny().covers(methods) == ccCovered
    check methods.covers(constraintAny()) != ccCovered
    check constraintAlternatives([]).kind == cckEmpty
    check constraintIntersection([]).kind == cckAny
    check methods.covers(constraintEmpty()) == ccCovered

  test "tree containment uses component boundaries and lexical normalization":
    let tree = constraintTree("/tmp")
    check tree.matches(capabilityText("/tmp"))
    check tree.matches(capabilityText("/tmp/sub/file"))
    check tree.matches(capabilityText("/tmp/sub/../file"))
    check not tree.matches(capabilityText("/tmp-old/file"))
    check not tree.matches(capabilityText("/tmp/../outside"))
    check tree.covers(constraintTree("/tmp/sub")) == ccCovered
    check tree.covers(constraintTree("/tmp-old")) == ccNotCovered
    check constraintTree("/").covers(tree) == ccCovered
    expect CapabilityConstraintError:
      discard constraintTree("relative")

  test "intersections retain exact predicates and normalize proven emptiness":
    let left = constraintPattern("a*b*")
    let right = constraintPattern("*bc")
    let intersection = constraintIntersection([left, right])
    for text in ["abc", "abbc", "abcd", "bc", "axc"]:
      let fact = capabilityText(text)
      check intersection.matches(fact) == (left.matches(fact) and right.matches(fact))
    check constraintIntersection([
      constraintMaximum(4), constraintMinimum(5)]).kind == cckEmpty
    check constraintIntersection([
      constraintTree("/one"), constraintTree("/two")]).kind == cckEmpty
    check constraintIntersection([
      constraintExact(capabilityText("GET")),
      constraintExact(capabilityText("POST"))]).kind == cckEmpty

  test "canonical field unions and intersections are order independent":
    let a = constraintExact(capabilityText("a"))
    let b = constraintExact(capabilityText("b"))
    check constraintAlternatives([a, b, a]).canonicalKey ==
      constraintAlternatives([b, a]).canonicalKey
    let tree = constraintTree("/tmp")
    check constraintIntersection([tree, tree, constraintAny()]).canonicalKey ==
      tree.canonicalKey
    check constraintIntersection([tree, constraintTree("/tmp/sub")]).canonicalKey ==
      constraintTree("/tmp/sub").canonicalKey

  test "operation facts cannot use permission wildcards":
    expect CapabilityConstraintError:
      discard constraintAny().matches(capabilityAny())

  test "finite facts verify every positive proof and exact intersection":
    let constraints = @[
      constraintAny(), constraintEmpty(),
      constraintMaximum(0), constraintMinimum(0),
      constraintExact(capabilityInteger(1)),
      constraintExact(capabilityBoolean(false)),
      constraintExact(capabilityText("a")),
      constraintPattern("a*"), constraintPattern("*b"),
      constraintAlternatives([constraintPattern("a*"), constraintPattern("*b")]),
      constraintIntersection([constraintPattern("a*"), constraintPattern("*b")]),
      constraintTree("/tmp")]
    var facts = @[capabilityBoolean(false), capabilityBoolean(true)]
    for number in -3..3:
      facts.add capabilityInteger(number)
    for text in ["", "a", "b", "ab", "a*b", "/tmp", "/tmp/x", "/outside"]:
      facts.add capabilityText(text)
    for broad in constraints:
      for narrow in constraints:
        let proof = broad.covers(narrow)
        let intersection = constraintIntersection([broad, narrow])
        for fact in facts:
          check intersection.matches(fact) ==
            (broad.matches(fact) and narrow.matches(fact))
          if proof == ccCovered and narrow.matches(fact):
            checkpoint broad.canonicalKey & " covers " & narrow.canonicalKey
            check broad.matches(fact)
