## Data-boundary library additions: base64, strict reading, and atomic byte
## files. These are what an application needs to exchange binary payloads and
## untrusted Gene text without evaluating anything.
import gene/[types, compiler, vm, printer]
import std/[os, strutils, unittest]

proc evalData(source: string): Value =
  run(compileSource(source), newGlobalScope())

proc dataError(source: string): string =
  try:
    discard evalData(source)
    ""
  except CatchableError as error:
    error.msg

suite "string and list receiver methods":
  test "exposes existing text operations on literals, symbols and computed receivers":
    check evalData("""
      (let text " A,éB ")
      [(text .split ",") text/.trim text/.lower text/.upper
       (text .contains? "é") (text .starts_with? " A") (text .ends_with? " ")
       text/.byte_size ("" .empty?) (" " .empty?)
       (("a,b" .split ",") .get 1)]
    """).print() == "[[\" A\" \"éB \"] \"A,éB\" \" a,éb \" \" A,éB \" true true true 7 true false \"b\"]"
    check evalData("""
      (let text "Aé🙂Z")
      [(text .slice_bytes 1 4) (text .slice_bytes 1 1)
       ($str/from_utf8 text/.to_utf8)]
    """).print() == "[\"é\" \"\" \"Aé🙂Z\"]"

  test "list get uses path indexing and join uses the existing string function":
    check evalData("""
      (let xs [10 nil 30])
      [(xs .get 0) (xs .get -1) (xs .get 1) ($void? (xs .get 3))
       ($void? (xs .get -4)) ($void? ([] .get 0))
       (["a" "b"] .join) (["a" "b"] .join " / ") ([] .join ",")]
    """).print() == "[10 30 nil true true true \"ab\" \"a / b\" \"\"]"

  test "the documentation extraction that failed in the harness now works":
    check evalData("""
      (let chapter "Introduction## StatefulA small example## Next")
      (((chapter .split "## Stateful") .get 1) .split "##")
    """).print() == "[\"A small example\" \" Next\"]"

  test "namespace functions and messages share their native identity across applications":
    for i in 0..2:
      let scope = newGlobalScope(newApplication(getCurrentDir()))
      let strType = run(compileSource("Str"), scope)
      for name in ["split", "trim", "lower", "upper", "empty?", "byte_size",
                   "slice_bytes", "to_utf8", "starts_with?", "ends_with?", "contains?"]:
        check typeDirectMessage(strType, name).bits ==
          run(compileSource("$str/" & name), scope).bits
      check typeDirectMessage(run(compileSource("List"), scope), "join").bits ==
        run(compileSource("$str/join"), scope).bits

  test "preserves validation and leaves ambiguous string indexing explicit":
    for (source, message) in [
        ("(\"a,b\" .split \"\")", "separator must not be empty"),
        ("(\"a,b\" .split)", "str/split expects 2 arguments"),
        ("(\"a,b\" .split 1)", "separator expects a Str"),
        ("([1] .get \"0\")", "expects an Int"),
        ("([1] .get)", "List/get expects 2 arguments"),
        ("([1] .join \",\")", "str/join item expects a Str"),
        ("(\"é\" .slice_bytes 1 1)", "start must be a UTF-8 boundary"),
        ("(\"x\" .get 0)", "no message 'get' on Str")]:
      check message in dataError(source)

suite "owned byte slices":
  test "preserves binary bytes, empty boundaries, and source lifetime":
    check evalData("""
      (fn sliced []
        (let input ($binary/from_list [0 255 128 65 0]))
        ($binary/slice input 1 3))
      [($binary/to_list (sliced))
       ($binary/to_list ($binary/slice ($binary/from_list []) 0 0))
       ($binary/to_list ($binary/slice ($binary/from_list [1 2]) 2 0))]
    """).print() == "[[255 128 65] [] []]"

  test "rejects negative, oversized, and overflowing ranges":
    for bounds in ["-1 1", "0 -1", "3 0", "1 2",
                   "9223372036854775807 1", "1 9223372036854775807"]:
      check "bytes/slice range out of bounds" in dataError(
        "($binary/slice ($binary/from_list [1 2]) " & bounds & ")")

suite "UTF-8 byte decoding":
  test "decodes valid documents including empty text and non-ASCII characters":
    check evalData("($binary/decode_utf8 ($binary/from_str \"héllo 世界\"))").print() ==
      "\"héllo 世界\""
    check evalData("($binary/decode_utf8 ($binary/from_list []))").print() == "\"\""

  test "rejects invalid sequences without changing raw byte-string conversion":
    for encoded in ["[255]", "[192 128]", "[224 128 128]", "[237 160 128]",
                    "[240 128 128 128]", "[244 144 128 128]", "[240 159 146]"]:
      check "invalid UTF-8" in dataError("($binary/decode_utf8 ($binary/from_list " & encoded & "))")
    check evalData("($str/byte_size ($binary/decode_utf8 ($binary/from_list [244 143 191 191])))").print() == "4"
    check evalData("($str/byte_size ($binary/to_str ($binary/from_list [255])))").print() == "1"

suite "IEEE CRC-32":
  test "matches standard, empty and binary checksum vectors":
    check evalData("($binary/crc32 ($binary/from_str \"123456789\"))").print() == "3421780262"
    check evalData("($binary/crc32 ($binary/from_list []))").print() == "0"
    check evalData("($binary/crc32 ($binary/from_list [0]))").print() == "3523407757"
    check evalData("($binary/crc32 ($binary/from_list [255]))").print() == "4278190080"
    check evalData("($binary/crc32 ($binary/from_str \"IEND\"))").print() == "2923585666"

  test "requires an explicit byte input":
    check "Bytes" in dataError("($binary/crc32 \"123456789\")")

suite "base64":
  test "encodes Str and Bytes with padding and no line breaks":
    check evalData("($base64/encode \"hello\")").print() == "\"aGVsbG8=\""
    check evalData("($base64/encode \"\")").print() == "\"\""
    check evalData("($base64/encode ($binary/from_list [255 0 128]))").print() ==
      "\"/wCA\""
    # 60 bytes would wrap under MIME; the encoding here never does.
    check evalData("(var bytes []) (repeat i in 60 (bytes .push 65)) " &
                   "($str/contains? ($base64/encode ($binary/from_list bytes)) \"\\n\")"
                  ).print() == "false"

  test "decodes to Bytes and round-trips binary data":
    check evalData("($binary/to_list ($base64/decode \"/wCA\"))").print() ==
      "[255 0 128]"
    check evalData("($binary/to_str ($base64/decode ($base64/encode \"héllo\")))"
                  ).print() == "\"héllo\""

  test "rejects text that is not canonical base64":
    for source in ["($base64/decode \"aGVsbG8\")",        # missing padding
                   "($base64/decode \"aGV sbG8=\")",      # embedded space
                   "($base64/decode \"aGVsbG9=\")",       # non-zero trailing bits
                   "($base64/decode \"*GVsbG8=\")"]:      # outside the alphabet
      check dataError(source) == "base64/decode expects canonical base64 text"
    check dataError("($base64/encode 12)") == "base64/encode expects Bytes or a Str"

suite "strict reading":
  test "read_all keeps its ordinary behaviour without strict options":
    check evalData("(($parse/read_all \"(a ^x 1 ^x 2)\") .next)").print() ==
      "(a ^x 2)"

  test "reject_duplicate_props refuses a repeated property":
    let message = dataError(
      "(($parse/read_all \"(a ^x 1 ^x 2)\" ^^reject_duplicate_props) .next)")
    check "duplicate property '^x'" in message
    check evalData("(($parse/read_all \"(a ^x 1 (b ^y 2))\" " &
                   "^^reject_duplicate_props) .next)").print() ==
      "(a ^x 1 (b ^y 2))"

  test "max_depth bounds nesting":
    check "reader max_depth exceeded (2)" in dataError(
      "(($parse/read_all \"(a (b (c (d))))\" ^max_depth 2) .next)")
    check evalData("(($parse/read_all \"(a (b))\" ^max_depth 2) .next)").print() ==
      "(a (b))"

  test "a strict read failure is a catchable ParseError":
    check evalData("(try (($parse/read_all \"(a ^x 1 ^x 2)\" " &
                   "^^reject_duplicate_props) .next) " &
                   "catch ParseError \"caught\")").print() == "\"caught\""

  test "unknown and conflicting options are refused":
    check "unexpected named argument: depth" in
      dataError("($parse/read_all \"(a)\" ^depth 2)")
    check "^locs is not available" in
      dataError("($parse/read_all \"(a)\" ^^locs ^max_depth 2)")

suite "atomic byte files":
  test "remove_dir removes only empty directories and tolerates absence":
    let path = getTempDir() / "gene_remove_empty_dir"
    createDir(path)
    defer:
      if dirExists(path): removeDir(path)
    let quoted = "\"" & path & "\""
    writeFile(path / "keep.txt", "keep")
    check dataError("($fs/remove_dir " & quoted & ")").len > 0
    check readFile(path / "keep.txt") == "keep"
    removeFile(path / "keep.txt")
    check evalData("($fs/remove_dir " & quoted & ")").print() == "nil"
    check not dirExists(path)
    check evalData("($fs/remove_dir " & quoted & ")").print() == "nil"

  test "write_bytes_atomic replaces a file with exactly the given bytes":
    let path = getTempDir() / "gene_write_bytes_atomic.bin"
    defer:
      if fileExists(path): removeFile(path)
    let quoted = "\"" & path & "\""
    check evalData("($fs/write_bytes_atomic " & quoted &
                   " ($binary/from_list [1 2 255 0])) " &
                   "($binary/to_list ($fs/read_bytes " & quoted & "))").print() ==
      "[1 2 255 0]"
    check evalData("($fs/write_bytes_atomic " & quoted &
                   " ($binary/from_list [7])) " &
                   "($binary/to_list ($fs/read_bytes " & quoted & "))").print() ==
      "[7]"
    # No staging file is left beside the destination.
    for kind, entry in walkDir(getTempDir()):
      check not (extractFilename(entry).startsWith(
        "gene_write_bytes_atomic.bin.gene-tmp-"))

  test "write_bytes_atomic requires Bytes":
    check "expects Bytes" in
      dataError("($fs/write_bytes_atomic \"/tmp/x\" \"text\")")
