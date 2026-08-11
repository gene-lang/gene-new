import gene/document_units
import gene/program_document
import std/[unittest, os, strutils]

template checkUnitRoundTrip(src: string) =
  ## The Model-training study's first pre-registered pilot gate: the logical
  ## units a document exports must rebuild that document with zero
  ## representation loss. Checked on the canonical projection, which is the
  ## observable both directions agree on.
  let doc = readDocument(src, "<test>")
  let canonical = writeCanonical(doc)
  let units = unitsOf(doc)
  let rebuilt = documentOf(units, "<test>")
  check writeCanonical(rebuilt) == canonical
  # The JSONL projection is the actual training-pipeline surface, so it has
  # to survive the text hop too, not just the in-memory seq.
  let reparsed = documentOf(parseUnitLines(toJsonLines(units)), "<test>")
  check writeCanonical(reparsed) == canonical

suite "document_units — units rebuild the document they came from":
  test "no comments": checkUnitRoundTrip("(a b c)")
  test "nested containers":
    checkUnitRoundTrip("(a [1 2 {^k \"v\"}] {{\"key\" : 3}})")
  test "props, meta, and body together":
    checkUnitRoundTrip("(a @doc \"hi\" ^x 1 ^^flag b c)")
  test "immutable containers":
    checkUnitRoundTrip("#(h ^p v b)")
    checkUnitRoundTrip("#[1 2 3]")
    checkUnitRoundTrip("#{^a 1}")
  test "scalars of every encodable kind":
    checkUnitRoundTrip("(a nil void true false 1 -2 3.5 \"s\" 'c' sym)")
  test "comments in every position":
    checkUnitRoundTrip("# leading\n(a b # trailing\n c)\n# between\n(d)\n# end\n")
  test "comment immediately after a container opens":
    checkUnitRoundTrip("(a # only a head\n)")
    checkUnitRoundTrip("[ # first\n 1 2]")
  test "bang line":
    checkUnitRoundTrip("#!/usr/bin/env gene\n(a b)\n")
  test "opaquely-anchored comments survive":
    # Quasiquote/unquote sugar anchors interior comments to the whole form
    # (program_document's afterChild == -2) rather than to a specific child.
    # Draining only the -1 bucket at a container's open dropped every one of
    # these from the unit stream while the canonical writer still emitted
    # them, so the stream decoded to a comment-free document.
    checkUnitRoundTrip("`(a # c\n b)")
    checkUnitRoundTrip("%(a # c\n b)")
    checkUnitRoundTrip("(a `(b # c\n d))")
    checkUnitRoundTrip("(a %(b # c\n d))")
  test "a glued-tilde send segment survives as one symbol":
    checkUnitRoundTrip("(a xs/~size)")

suite "document_units — malformed unit streams are rejected":
  test "unterminated container":
    expect DocumentUnitsError:
      discard documentOf(parseUnitLines("{\"k\":\"ukFormStart\"}\n{\"k\":\"ukListStart\"}\n"))
  test "a structural role where a value belongs":
    expect DocumentUnitsError:
      discard documentOf(parseUnitLines("{\"k\":\"ukFormStart\"}\n{\"k\":\"ukNodeEnd\"}\n"))
  test "unknown unit kind":
    expect DocumentUnitsError:
      discard parseUnitLines("{\"k\":\"ukNotAKind\"}\n")
  test "a line that is not a JSON object":
    expect DocumentUnitsError:
      discard parseUnitLines("[1, 2]\n")
    expect DocumentUnitsError:
      discard parseUnitLines("not json\n")
  test "missing form terminator":
    expect DocumentUnitsError:
      discard documentOf(parseUnitLines("{\"k\":\"ukFormStart\"}\n{\"k\":\"ukNil\"}\n"))
  test "a non-numeric int/float payload is an error, not an escaping ValueError":
    expect DocumentUnitsError:
      discard documentOf(parseUnitLines(
        "{\"k\":\"ukFormStart\"}\n{\"k\":\"ukInt\",\"t\":\"twelve\"}\n"))
    expect DocumentUnitsError:
      discard documentOf(parseUnitLines(
        "{\"k\":\"ukFormStart\"}\n{\"k\":\"ukFloat\",\"t\":\"~\"}\n"))
  test "runaway nesting is bounded, not a stack overflow":
    # A model-generated stream can open containers without ever closing them;
    # that has to be a countable structural failure, not a crash.
    var jsonl = "{\"k\":\"ukFormStart\"}\n"
    for _ in 0 .. decodeMaxDepth + 8:
      jsonl.add "{\"k\":\"ukListStart\"}\n"
    expect DocumentUnitsError:
      discard documentOf(parseUnitLines(jsonl))

suite "document_units — real corpus round trip":
  test "every .gene file under examples/ and tests/ rebuilds from its units":
    var scanned, encodable = 0
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
        let canonical =
          try: writeCanonical(doc)
          except CatchableError as e:
            checkpoint("writeCanonical failed on " & path & ": " & e.msg)
            fail()
            continue
        # A document holding a value kind v0 declines to encode (regex, the
        # date family, bigint overflow) is out of scope by construction, not
        # a round-trip failure -- packed_format.nim declines the same set.
        var units: seq[Unit]
        try:
          units = unitsOf(doc)
        except DocumentUnitsError:
          continue
        inc encodable
        let rebuilt =
          try: documentOf(parseUnitLines(toJsonLines(units)), path)
          except CatchableError as e:
            checkpoint("documentOf failed on " & path & ": " & e.msg)
            fail()
            continue
        if writeCanonical(rebuilt) != canonical:
          checkpoint("units did not rebuild " & path & " exactly")
          fail()
    checkpoint("scanned " & $scanned & " files, " & $encodable & " encodable")
    check scanned > 0
    check encodable > 0
