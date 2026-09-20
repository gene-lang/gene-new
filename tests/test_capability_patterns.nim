import std/unittest
import gene/capability_patterns

suite "capability pattern predicates":
  test "matching covers the full string and wildcard spans characters":
    let pattern = compileCapabilityPattern("a*d")
    for value in ["ad", "abcd", "a/long/path/d", "a🙂d"]:
      check pattern.matches(value)
    for value in ["xabcdy", "abc", "a", "d"]:
      check not pattern.matches(value)
    check compileCapabilityPattern("*").matches("")
    check compileCapabilityPattern("").matches("")
    check not compileCapabilityPattern("").matches("x")

  test "literal values and escaped patterns have the same exact meaning":
    let literal = compileCapabilityPattern("a*d", literal = true)
    let escaped = compileCapabilityPattern("a\\*d")
    check literal.canonicalKey == escaped.canonicalKey
    check literal.matches("a*d")
    check not literal.matches("abcd")
    check compileCapabilityPattern("a\\\\b").matches("a\\b")
    for malformed in ["a\\", "a\\?b"]:
      expect CapabilityConstraintError:
        discard compileCapabilityPattern(malformed)

  test "concrete asterisks never become patterns":
    check not compileCapabilityPattern("abc").matches("a*c")
    check compileCapabilityPattern("a*c", literal = true).matches("a*c")
    check not compileCapabilityPattern("a*c", literal = true).matches("abc")

  test "containment is language inclusion rather than pattern-source matching":
    let exactStar = compileCapabilityPattern("a\\*d")
    let wildcard = compileCapabilityPattern("a*d")
    check exactStar.matches("a*d")
    check exactStar.covers(wildcard) == ccNotCovered
    check wildcard.covers(exactStar) == ccCovered
    check compileCapabilityPattern("a*b").covers(
      compileCapabilityPattern("a*ab")) == ccCovered
    check compileCapabilityPattern("ab*").covers(
      compileCapabilityPattern("a*b")) == ccNotCovered
    check compileCapabilityPattern("*ab*").covers(
      compileCapabilityPattern("*a*b*")) == ccNotCovered

  test "canonicalization merges only adjacent wildcard tokens":
    check compileCapabilityPattern("a***b").canonicalKey ==
      compileCapabilityPattern("a*b").canonicalKey
    check compileCapabilityPattern("a*\\*b").canonicalKey !=
      compileCapabilityPattern("a*b").canonicalKey
    check compileCapabilityPattern("🙂*").covers(
      compileCapabilityPattern("🙂a*")) == ccCovered

  test "proof exhaustion is inconclusive and runtime exhaustion is an error":
    var proofBudget = newCapabilityProofBudget(1)
    check compileCapabilityPattern("a*b").covers(
      compileCapabilityPattern("a*ab"), proofBudget) == ccCannotProve
    var matchBudget = newCapabilityProofBudget(1)
    expect CapabilityProofLimitError:
      discard compileCapabilityPattern("a*b").matches("aaab", matchBudget)
    expect CapabilityConstraintError:
      discard newCapabilityProofBudget(-1)

  test "bounded finite model finds no false positive containment":
    let spellings = ["", "*", "a", "b", "a*", "*a", "a*b", "*ab*", "*a*b*",
                     "a\\*b", "**a**", "a*a", "\\*", "🙂*"]
    var samples = @["", "*", "a*b", "🙂", "🙂a"]
    var frontier = @[""]
    for depth in 1..5:
      var next: seq[string]
      for prefix in frontier:
        for character in ["a", "b"]:
          next.add prefix & character
      samples.add next
      frontier = next
    for broad in spellings:
      let granted = compileCapabilityPattern(broad)
      for narrow in spellings:
        let requested = compileCapabilityPattern(narrow)
        let coverage = granted.covers(requested)
        if coverage == ccCovered:
          for sample in samples:
            if requested.matches(sample):
              checkpoint broad & " covers " & narrow & " at " & sample
              check granted.matches(sample)
