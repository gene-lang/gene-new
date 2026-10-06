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
