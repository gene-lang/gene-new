import gene/program_document
import gene/reader
import gene/printer
import std/[unittest, os, strutils]

template checkRoundTrip(src: string) =
  ## Read -> write -> read must reach a fixed point, and every comment byte
  ## in the source must survive into the canonical output.
  let doc = readDocument(src, "<test>")
  let out1 = writeCanonical(doc)
  let doc2 = readDocument(out1, "<test2>")
  let out2 = writeCanonical(doc2)
  check out1 == out2
  for t in lexAllSpanned(src, includeTrivia = true):
    if t.kind in {tkLineComment, tkBlockComment}:
      if t.startByte == 0 and src.len >= 2 and src[0] == '#' and src[1] == '!':
        continue
      check src[t.startByte ..< t.endByte] in out1
  let reforms = readAll(out1, "<test3>")
  check reforms.len == doc.forms.len
  for i in 0 ..< min(reforms.len, doc.forms.len):
    check reforms[i].print() == doc.forms[i].print()

suite "program_document — comment placement and canonical round trip":
  test "no comments":
    checkRoundTrip("(a b c)")

  test "standalone comments before, between, and after top-level forms":
    checkRoundTrip("# leading\n(a b)\n# middle\n(c d)\n# trailing\n")

  test "trailing comment on a body element":
    checkRoundTrip("(a b # note\n c)")

  test "comment immediately before the close of a node with an empty tail":
    checkRoundTrip("(a # only a head\n)")

  test "trailing comment inside a list":
    checkRoundTrip("[1 2 # two\n 3]")

  test "props and body interleaved in source regroup canonically":
    let doc = readDocument("(a ^x 1 b ^y 2 c)", "<test>")
    check doc.comments.len == 0
    check writeCanonical(doc) == "(a ^x 1 ^y 2 b c)"

  test "meta and props both present":
    checkRoundTrip("(a @doc \"hi\" ^x 1 b)")

  test "bang line is preserved as the first line and excluded from comments":
    let doc = readDocument("#!/usr/bin/env gene\n(a b)\n", "<test>")
    check doc.hasBangLine
    check doc.bangLine == "#!/usr/bin/env gene"
    check doc.comments.len == 0
    checkRoundTrip("#!/usr/bin/env gene\n(a b)\n")

  test "a later #! is an ordinary positional comment, not a bang line":
    let doc = readDocument("(a)\n#!not a bang line\n(b)", "<test>")
    check not doc.hasBangLine
    check doc.comments.len == 1

  test "map literal":
    checkRoundTrip("{^x 1 ^y 2}")

  test "hash-map literal":
    checkRoundTrip("{{ \"k1\" : 1 \"k2\" : 2 }}")

  test "multiple standalone comments in a row keep their order":
    let doc = readDocument("(a\n # one\n # two\n b)", "<test>")
    check doc.comments.len == 2
    check doc.comments[0].text == "# one"
    check doc.comments[1].text == "# two"
    checkRoundTrip("(a\n # one\n # two\n b)")

  test "comment nested three levels deep survives":
    checkRoundTrip("(a (b (c # deep\n d) e) f)")

  test "nested block comment":
    checkRoundTrip("(a #< outer #< inner ># still outer ># b)")

  test "datum comment and its discarded form are absent from the document":
    let doc = readDocument("(a #_ (discarded form) b)", "<test>")
    check doc.comments.len == 0
    check writeCanonical(doc) == "(a b)"

  test "comment inside reader sugar is preserved, anchored to the sugar's canonical form":
    let doc = readDocument("`(a # inside quasi\n b)", "<test>")
    check doc.comments.len == 1
    let outText = writeCanonical(doc)
    check "# inside quasi" in outText
    # Semantic content must still be exactly the desugared quasiquote form.
    let reforms = readAll(outText, "<test2>")
    check reforms.len == 1
    check reforms[0].print() == doc.forms[0].print()

  test "multi-form source unit preserves a comment between forms":
    checkRoundTrip("(a)\n# between\n(b)\n(c)")

suite "program_document — real corpus round trip":
  test "every .gene file under examples/ and tests/ round-trips without losing a comment or crashing":
    var scanned = 0
    for dir in ["examples", "tests"]:
      if not dirExists(dir): continue
      for path in walkDirRec(dir):
        if not path.endsWith(".gene"): continue
        let src =
          try: readFile(path)
          except CatchableError: continue
        inc scanned
        let doc =
          try: readDocument(src, path)
          except CatchableError as e:
            checkpoint("readDocument failed on " & path & ": " & e.msg)
            fail()
            continue
        let out1 =
          try: writeCanonical(doc)
          except CatchableError as e:
            checkpoint("writeCanonical failed on " & path & ": " & e.msg)
            fail()
            continue
        # Completeness: no comment byte may be silently dropped, anywhere.
        for i, t in lexAllSpanned(src, includeTrivia = true):
          if t.kind in {tkLineComment, tkBlockComment}:
            if i == 0 and t.startByte == 0 and src.len >= 2 and src[0] == '#' and src[1] == '!':
              continue
            if src[t.startByte ..< t.endByte] notin out1:
              checkpoint("comment dropped in " & path & ": " & src[t.startByte ..< t.endByte])
              fail()
        let doc2 =
          try: readDocument(out1, path & "#2")
          except CatchableError as e:
            checkpoint("re-readDocument failed on " & path & ": " & e.msg)
            fail()
            continue
        let out2 =
          try: writeCanonical(doc2)
          except CatchableError as e:
            checkpoint("re-writeCanonical failed on " & path & ": " & e.msg)
            fail()
            continue
        if out1 != out2:
          checkpoint("not idempotent: " & path)
          fail()
        let reforms =
          try: readAll(out1, path & "#3")
          except CatchableError as e:
            checkpoint("reread failed on " & path & ": " & e.msg)
            fail()
            continue
        if reforms.len != doc.forms.len:
          checkpoint("form count mismatch in " & path & ": " & $reforms.len &
            " vs " & $doc.forms.len)
          fail()
        else:
          for i in 0 ..< reforms.len:
            if reforms[i].print() != doc.forms[i].print():
              checkpoint("form " & $i & " mismatch in " & path)
              fail()
    checkpoint("scanned " & $scanned & " files")
    check scanned > 0
