## Tests for the flat-clause source migration (tools/migrate_flat_syntax.nim).
##
## The legacy decoder inside the tool is frozen; these cases pin its agreement
## with the flat decoder the compiler now uses.

import std/[strutils, unittest]
import ../tools/migrate_flat_syntax

proc flat(source: string): string =
  rewriteGeneSource(source, mmFlat).text

proc grouped(source: string): string =
  rewriteGeneSource(source, mmGrouped).text

suite "migration — flat clause rewrite":
  test "positional two-arm if gains a flat else":
    check flat("(if c a b)") == "(if c a else b)"

  test "positional one-arm if keeps its spelling":
    check flat("(if c a)") == "(if c a)"

  test "if_yes becomes a do-wrapped truthy arm":
    check flat("(if_yes c a b)") == "(if c (do a b))"
    check flat("(if_yes c a)") == "(if c a)"

  test "a grouped if flattens without changing its arms":
    check flat("(if c (then a) (else b))") == "(if c a else b)"
    check flat("(if c (then a b) (elif d e) (else f g))") ==
      "(if c a b elif d e else f g)"

  test "a grouped match flattens its when and else arms":
    check flat("(match x (when 1 \"one\") (when 2 \"two\") (else \"other\"))") ==
      "(match x when 1 \"one\" when 2 \"two\" else \"other\")"

  test "if_present flattens its trailing else":
    check flat("(if_present x e a b (else c d))") ==
      "(if_present x e a b else c d)"

  test "quoted data keeps the shape its author wrote":
    let source = "(quote (if c (then a) (else b)))"
    check flat(source) == source

  test "comments between an if and its arms survive":
    let source = "(if c\n  (then a)\n  # keep this\n  (else b))"
    check "# keep this" in flat(source)

  test "a marker-valued body is wrapped in do":
    check flat("(if c a else)") == "(if c a else (do else))"
    check flat("(if c else)") == "(if c (do else))"
    check flat("(match x (when 1 else) (else when))") ==
      "(match x when 1 (do else) else (do when))"
    check flat("(if_present x e a (else else))") ==
      "(if_present x e a else (do else))"

  test "extra positional operands are reported, not guessed":
    let result = rewriteGeneSource("(if c a b d)", mmFlat)
    check result.text == "(if c a b d)"
    check result.issues.len == 1
    check "extra operands" in result.issues[0].message

  test "an executable template is reported for review":
    let result = rewriteGeneSource(
      "(macro m [c] `(if %c (then 1) (else 2)))", mmFlat)
    check result.issues.len == 1
    check "quoted template" in result.issues[0].message

  test "the grouped target is idempotent":
    let source = "(if c a b) (if_yes d e f) (match x (when 1 1) (else 0))"
    let once = grouped(source)
    check once ==
      "(if c (then a) (else b)) (if d (then e f)) " &
      "(match x (when 1 1) (else 0))"
    check grouped(once) == once

  test "one-shot flat equals grouped then flat":
    let source = "(if c a b) (if_yes d e f) " &
      "(if g (then h i) (else j)) (match x (when 1 1) (else 0))"
    check flat(source) == flat(grouped(source))

  test "nim string literals are rewritten in place":
    let source = "let x = \"(if c a b)\"\n"
    let result = rewriteNimSource(source, mmFlat)
    check result.text == "let x = \"(if c a else b)\"\n"

  test "concatenated nim literals are rewritten as one unit":
    let source = "let x = \"(if c \" & \"a b)\"\n"
    let result = rewriteNimSource(source, mmFlat)
    check "else b" in result.text
    check result.issues.len == 0

  test "a positional guard that still needs review keeps its text":
    let source = "let x = \"(if c a b d)\"\n"
    let result = rewriteNimSource(source, mmFlat)
    check result.text == source
    check result.issues.len == 1
