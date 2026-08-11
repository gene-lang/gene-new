import gene/program_document
import gene/packed_format
import gene/printer
import gene/source_index
import std/[unittest, os, strutils]

proc pathsEqual(a, b: DocPath): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i].kind != b[i].kind: return false
    case a[i].kind
    of spsProperty:
      if a[i].name != b[i].name: return false
    of spsIndex:
      if a[i].index != b[i].index: return false
  true

proc commentsEqual(a, b: seq[CommentRecord]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i].formIndex != b[i].formIndex or not pathsEqual(a[i].containerPath, b[i].containerPath) or
        a[i].afterChild != b[i].afterChild or a[i].ordinal != b[i].ordinal or
        a[i].placement != b[i].placement or a[i].text != b[i].text:
      return false
  true

template checkPackedRoundTrip(src: string) =
  let doc = readDocument(src, "<test>")
  let packed = encodePacked(doc)
  let doc2 = decodePacked(packed)
  check doc2.forms.len == doc.forms.len
  for i in 0 ..< min(doc.forms.len, doc2.forms.len):
    check doc2.forms[i].print() == doc.forms[i].print()
  check commentsEqual(doc.comments, doc2.comments)
  check doc2.hasBangLine == doc.hasBangLine
  check doc2.bangLine == doc.bangLine
  check encodePacked(doc2) == packed  # encode_packed(decode_packed(x)) == x

suite "packed_format — encode/decode round trip":
  test "simple form, no comments":
    checkPackedRoundTrip("(a b c)")

  test "comments and a bang line":
    checkPackedRoundTrip("#!/usr/bin/env gene\n# leading\n(a b # trailing\n c)\n# after\n")

  test "collections: list, map, hash-map":
    checkPackedRoundTrip("[1 2 3] {^x 1 ^y 2} {{ \"k\" : 1 }}")

  test "nested containers":
    checkPackedRoundTrip("(a (b (c d) e) f)")

  test "scalar kinds covered in v0":
    checkPackedRoundTrip("(1 -2 1.5 \"str\" 'c' :sym true false nil void)")

  test "immutable node/list/map variants":
    checkPackedRoundTrip("#(a b) #[1 2] #{^x 1}")

  test "deterministic: encoding the same document twice is byte-identical":
    let doc = readDocument("(a ^x 1 [1 2 3] {^y 2})", "<test>")
    check encodePacked(doc) == encodePacked(doc)

suite "packed_format — validation and safety (fail closed)":
  test "empty input is rejected":
    expect(PackedError):
      discard decodePacked("")

  test "bad magic is rejected":
    expect(PackedError):
      discard decodePacked("XXXX\x01\x00\x00\x00")

  test "truncated right after magic+version is rejected":
    expect(PackedError):
      discard decodePacked("GNPD\x01")

  test "an unsupported future version is rejected":
    expect(PackedError):
      discard decodePacked("GNPD\x99\x00")

  test "trailing bytes after an otherwise-complete document are rejected":
    var packed = encodePacked(readDocument("(a)", "<test>"))
    packed.add "\xFF\xFF\xFF"
    expect(PackedError):
      discard decodePacked(packed)

  test "a value truncated mid-payload is rejected":
    var packed = encodePacked(readDocument("(a b c)", "<test>"))
    packed.setLen(packed.len - 3)
    expect(PackedError):
      discard decodePacked(packed)

  test "collection size limit is enforced during encode":
    var tight = defaultLimits()
    tight.maxCollectionSize = 2
    expect(PackedLimitError):
      discard encodePacked(readDocument("[1 2 3 4 5]", "<test>"), tight)

  test "nesting depth limit is enforced during encode":
    var tight = defaultLimits()
    tight.maxDepth = 2
    expect(PackedLimitError):
      discard encodePacked(readDocument("(a (b (c (d 1))))", "<test>"), tight)

  test "nesting depth limit is enforced during decode even if encode allowed it":
    let packed = encodePacked(readDocument("(a (b (c (d 1))))", "<test>"))
    var tight = defaultLimits()
    tight.maxDepth = 2
    expect(PackedLimitError):
      discard decodePacked(packed, tight)

  test "an unsupported value kind is rejected at encode time, not silently mis-encoded":
    # Regex is real reader-producible input outside this module's v0 scope.
    let doc = readDocument("(a #\"x\"i b)", "<test>")
    expect(PackedUnsupportedError):
      discard encodePacked(doc)

suite "packed_format — real corpus":
  test "every .gene file under examples/ and tests/ that this module can read also round-trips through the packed encoding":
    var scanned = 0
    var unsupported = 0
    for dir in ["examples", "tests"]:
      if not dirExists(dir): continue
      for path in walkDirRec(dir):
        if not path.endsWith(".gene"): continue
        let src =
          try: readFile(path)
          except CatchableError: continue
        let doc =
          try: readDocument(src, path)
          except CatchableError: continue
        inc scanned
        var packed: string
        try:
          packed = encodePacked(doc)
        except PackedUnsupportedError:
          inc unsupported  # a value kind outside v0 scope (regex/date/time/...); not a failure.
          continue
        except PackedLimitError as e:
          checkpoint("limit hit on " & path & ": " & e.msg)
          fail()
          continue
        let doc2 =
          try: decodePacked(packed)
          except CatchableError as e:
            checkpoint("decodePacked failed on " & path & ": " & e.msg)
            fail()
            continue
        if doc2.forms.len != doc.forms.len:
          checkpoint("form count mismatch in " & path)
          fail()
          continue
        for i in 0 ..< doc.forms.len:
          if doc2.forms[i].print() != doc.forms[i].print():
            checkpoint("form " & $i & " mismatch in " & path)
            fail()
            break
        if not commentsEqual(doc.comments, doc2.comments):
          checkpoint("comments mismatch in " & path)
          fail()
    checkpoint("scanned " & $scanned & " files, " & $unsupported &
      " hit an out-of-v0-scope value kind")
    check scanned > 0
