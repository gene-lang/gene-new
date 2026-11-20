## The `gene-viewer --machine` contract used by browser editors.
##
## The editor decision that matters here is offsets: a browser textarea speaks
## UTF-16 code units, the reader speaks UTF-8 bytes, and a supplementary code
## point makes the two disagree. These tests pin both coordinate systems to the
## same buffer, and pin the partial/lexical split that tells an editor whether
## to show a stale outline or a fresh one.

import std/[json, strutils, unittest]
import tools/[source_index, source_positions]
import tools/viewer/machine

proc option(mode: MachineMode = mmAnalyze): MachineOptions =
  result = MachineOptions(mode: mode, name: "<test>", version: 7,
                          selectUtf16: -1, selectUtf16Start: -1,
                          selectUtf16End: -1,
                          rowLimit: machineDefaultRowLimit,
                          childLimit: machineDefaultChildLimit,
                          depthLimit: machineDefaultDepthLimit,
                          maxBytes: machineDefaultMaxBytes)

proc outlineNames(response: JsonNode): seq[string] =
  for row in response["outline"]:
    result.add row["name"].getStr & "/" & $row["kind"].getInt

proc spanText(src: string, row: JsonNode): string =
  src[row["startByte"].getInt ..< row["endByte"].getInt]

suite "gene-viewer machine — analyze":
  test "outline, tree, and selection come from one index":
    let src = "(mod demo)\n(var counter 0)\n(fn bump [] counter)"
    var options = option()
    options.hasSelection = true
    options.selectUtf16 = 18
    let response = analyzeResponse(src, options)
    check response["ok"].getBool
    check response["parsed"].getBool
    check not response["partial"].getBool
    check response["version"].getInt == 7
    check response["outline"].len == 3
    check outlineNames(response) == @["demo/2", "counter/13", "bump/12"]
    check response["tree"]["kind"].getStr == "sequence"
    check response["tree"]["children"].len == 3
    check response["selected"]["found"].getBool
    check response["selected"]["kind"].getStr == "node"
    let selected = response["selected"]
    check spanText(src, selected) == "(var counter 0)"
    check selected["path"].getStr == "1"
    check selected["children"].len == 3
    check selected["children"][1]["label"].getStr == "0"
    check selected["children"][1]["summary"].getStr == "counter"

  test "supplementary code points keep byte and UTF-16 offsets exact":
    let src = "(fn 𝄞 [x] x)\n(var plain 1)"
    let response = analyzeResponse(src, option())
    let rows = response["outline"]
    check rows.len == 2
    check rows[0]["name"].getStr == "𝄞"
    # The name starts after "(fn " = 4 bytes and 4 UTF-16 units.
    check rows[0]["nameStartByte"].getInt == 4
    check rows[0]["nameStartUtf16"].getInt == 4
    # 𝄞 is four UTF-8 bytes and two UTF-16 code units.
    check rows[0]["nameEndByte"].getInt == 8
    check rows[0]["nameEndUtf16"].getInt == 6
    # The second declaration shifted by one byte less than by UTF-16 units.
    check rows[1]["startByte"].getInt == 16
    check rows[1]["startUtf16"].getInt == 14
    check src[rows[1]["startByte"].getInt ..< rows[1]["endByte"].getInt] ==
      "(var plain 1)"

  test "a caret inside a nested form selects the innermost container":
    let src = "(outer (inner 🙂 (deep 𝄞 tree)) tail)"
    var options = option()
    options.hasSelection = true
    let table = buildUtf16Table(src)
    options.selectUtf16Start = utf16At(src, table, src.find("𝄞"))
    options.selectUtf16End = options.selectUtf16Start
    # The browser knows only UTF-16 offsets; the helper resolves them against
    # the exact text it was given.
    let response = analyzeResponse(src, options)
    check response["selected"]["found"].getBool
    check spanText(src, response["selected"]) == "(deep 𝄞 tree)"

  test "a single-form buffer selects the form itself, not only its children":
    let src = "(fn 🙂 [x] x"
    var options = option()
    options.hasSelection = true
    options.selectUtf16 = 4
    let response = analyzeResponse(src, options)
    check response["selected"]["found"].getBool
    check spanText(src, response["selected"]) == src
    check response["selected"]["startByte"].getInt == 0
    check response["selected"]["endByte"].getInt == 14
    check response["selected"]["endUtf16"].getInt == 12

  test "selection offsets are resolved from UTF-16 in the CLI options":
    let src = "(a 🙂) (b 𝄞)"
    var options = option()
    options.hasSelection = true
    let table = buildUtf16Table(src)
    options.selectUtf16 = utf16At(src, table, src.find("𝄞"))
    let response = analyzeResponse(src, options)
    check response["selected"]["found"].getBool

  test "an unfinished buffer keeps its outline and marks it partial":
    let src = "(mod demo)\n(fn open []\n  (var inner 1)"
    let response = analyzeResponse(src, option())
    check response["ok"].getBool
    check not response["parsed"].getBool
    check response["partial"].getBool
    check response["diagnostics"].len >= 1
    check response["outline"].len == 2
    check response["outline"][0]["closed"].getBool
    check not response["outline"][1]["closed"].getBool
    check response["tree"]["children"][0]["closed"].getBool
    check not response["tree"]["children"][1]["closed"].getBool

  test "a lexical failure reports no outline for that text":
    let response = analyzeResponse("(fn broken [] \"unterminated)", option())
    check not response["ok"].getBool
    check response["outline"].len == 0
    check response["diagnostics"].len == 1
    let diagnostic = response["diagnostics"][0]
    check diagnostic["message"].getStr.len > 0
    check diagnostic["startByte"].getInt >= 0

  test "tree rows are bounded and say what they left out":
    var options = option()
    options.rowLimit = 2
    options.childLimit = 2
    let src = "(" & repeat("(a b) ", 12) & ")"
    let response = analyzeResponse(src, options)
    check response["limits"]["truncated"].getBool
    check response["tree"]["more"].getInt == 10
    check response["tree"]["children"].len == 2
    check response["tree"]["truncated"].getBool

  test "empty input is a valid empty buffer":
    let response = analyzeResponse("", option())
    check response["ok"].getBool
    check response["parsed"].getBool
    check response["outline"].len == 0
    check response["tree"]["children"].len == 0

  test "tree rows carry a snapshot-local identity beside the path":
    let doc = indexSource("(server ^host \"a\" [1 2])")
    let response = analyzeResponse(doc.source, option())
    var ids: seq[int]
    var paths: seq[string]
    for child in response["tree"]["children"]:
      ids.add child["id"].getInt
      paths.add child["path"].getStr
    check ids == @[0, 1, 2]
    check paths == @["head", "host", "0"]
    let list = response["tree"]["children"][2]
    var nested: seq[string]
    for child in list["children"]:
      nested.add child["path"].getStr
    check nested == @["0/0", "0/1"]

suite "gene-viewer machine — format":
  test "format returns the formatter's text and change flag":
    let src = "(fn  f[x]x)"
    let response = formatResponse(src, option(mmFormat))
    check response["ok"].getBool
    check response["changed"].getBool
    check response["text"].getStr == "(fn f [x]\n  x)\n"
    let same = formatResponse(response["text"].getStr, option(mmFormat))
    check not same["changed"].getBool

  test "unformattable text reports the reader diagnostic":
    let response = formatResponse("(fn broken ", option(mmFormat))
    check not response["ok"].getBool
    check response["diagnostics"].len == 1

suite "gene-viewer machine — CLI":
  test "the mode and options parse":
    let analyze = parseMachineCli(["analyze", "--name", "draft.gene",
                                   "--version", "4", "--select-utf16", "9",
                                   "--row-limit", "12"])
    check analyze.mode == mmAnalyze
    check analyze.name == "draft.gene"
    check analyze.version == 4
    check analyze.selectUtf16 == 9
    check analyze.rowLimit == 12
    let format = parseMachineCli(["format", "--text-file=/tmp/x.gene"])
    check format.mode == mmFormat
    check format.textFile == "/tmp/x.gene"

  test "unknown options and missing modes are rejected":
    expect ValueError:
      discard parseMachineCli([])
    expect ValueError:
      discard parseMachineCli(["render"])
    expect ValueError:
      discard parseMachineCli(["analyze", "--nope", "1"])
    expect ValueError:
      discard parseMachineCli(["analyze", "--row-limit", "many"])

  test "byte and UTF-16 offsets round-trip through the same buffer":
    let src = "a🙂b𝄞c\nplain\r\nline"
    let table = buildUtf16Table(src)
    for candidate in 0 .. src.len:
      if candidate > 0 and candidate < src.len and
          (ord(src[candidate]) and 0xC0) == 0x80:
        continue
      let unit = utf16At(src, table, candidate)
      check byteAt(src, table, unit) == candidate
