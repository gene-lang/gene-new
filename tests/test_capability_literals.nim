import std/[strutils, unittest]
import gene/capability_literals

proc capabilityLiteralSource(): CapabilitySourceContext =
  CapabilitySourceContext(kind: csoSource, name: "policy.gene",
                          baseDirectory: "/workspace")

proc parseCapabilityTest(text: string, use = cuRequest,
    limits = DefaultCapabilityLiteralLimits): CapabilityLiteralRow =
  readCapabilityLiteral(text, use, capabilityLiteralSource(), limits)

suite "inert capability literals":
  test "complete entries retain ordered bodies, fields, flags and source":
    let row = parseCapabilityTest("""
[
  (fs/Read "/one" "/two")
  (net/Http ^methods ["GET" "POST"] ^^optional)
  (test/Limits 5 ^enabled false 4 ^modes [])
  fs/*
]
""")
    let entries = row.entries
    check row.len == 4
    check entries[0].body[0].text == "/one"
    check entries[0].body[1].text == "/two"
    check entries[1].optional
    check entries[1].hasOptional
    check entries[1].properties.len == 1
    check entries[1].properties[0].name == "methods"
    check entries[1].properties[0].value.items[1].text == "POST"
    check entries[2].body[1].integer == 4
    check not entries[2].properties[0].value.scalar.boolean
    check entries[2].properties[1].value.items.len == 0
    check entries[3].name == "fs/*"
    check entries[0].location.line == 2
    check row.source.baseDirectory == "/workspace"

  test "all receiving contexts accept explicit empty rows":
    for use in CapabilityUse:
      check parseCapabilityTest("[]", use).len == 0

  test "false optional metadata is preserved and rejected in grants and bounds":
    for flag in ["^^optional", "^optional true", "^optional false"]:
      let text = "[(net/Http " & flag & ")]"
      check parseCapabilityTest(text).entries[0].hasOptional
      for use in [cuGrant, cuBound]:
        expect CapabilityLiteralError:
          discard parseCapabilityTest(text, use)
    check not parseCapabilityTest(
      "[(net/Http ^optional false)]").entries[0].optional

  test "duplicates fail before optional or unrestricted entries can hide them":
    for text in [
      "[(net/Http ^optional true ^^optional)]",
      "[(net/Http ^^optional ^optional false)]",
      "[net/Http (net/Http ^methods [] ^methods [\"GET\"])]",
      "[(net/Http ^^optional ^hosts [] ^hosts [])]"]:
      expect CapabilityLiteralError:
        discard parseCapabilityTest(text)

  test "duplicate diagnostics identify the original source location":
    let text = "[\n (net/Http ^methods [] ^methods [])\n]"
    try:
      discard parseCapabilityTest(text)
      check false
    except CapabilityLiteralError as error:
      check error.sourceName == "policy.gene"
      check error.line == 2
      check error.offset == text.rfind("^methods")
      check "duplicate" in error.msg

  test "expressions, lookups, metadata and reader extensions are rejected":
    for text in [
      "[(fs/Read path)]", "[(fs/Read (compute_path))]",
      "[(net/Http ^methods [GET])]", "[(fs/Read $\"interpolated\")]",
      "[(test/Limits nil)]", "[(test/Limits void)]",
      "[(test/Limits 3.5)]", "[(test/Limits 1e3)]",
      "[(test/Limits [1 2])]", "[(test/Limits ^x [[1]])]",
      "[(test/Limits ^x {^a 1})]", "[(test/Limits ^x #[1])]",
      "[(test/Limits @x 1)]", "[_ fs/Read]", "[#(fs/Read)]",
      "[(net/Http ^optional *)]", "[(net/Http ^optional \"true\")]",
      "[(net/Http ^optional [true])]"]:
      checkpoint text
      expect CapabilityLiteralError:
        discard parseCapabilityTest(text)

  test "one outer row, complete tokens and valid identifiers are required":
    for text in ["", "*", "fs/Read", "(fs/Read)", "[] []", "[] trailing",
                 "[*]", "[fs//Read]", "[fs/]", "[fs/*/Read]", "[Read]",
                 "[(fs/Read\"/tmp\")]", "[(net/Http ^hosts [\"a\"\"b\"])]",
                 "[(fs/Read", "[", "[(net/Http ^methods ["]:
      checkpoint text
      expect CapabilityLiteralError:
        discard parseCapabilityTest(text)

  test "source strings distinguish wildcard tokens and retain pattern escapes":
    let values = parseCapabilityTest(
      """[(test/Limits * "*" "a\\*d" "\u{1f642}" "\U0001F642")]"""
    ).entries[0].body
    check values[0].kind == cskWildcard
    check values[1].kind == cskText
    check values[1].text == "*"
    check values[1].stringMode == csmSource
    check values[2].text == "a\\*d"
    check values[3].text == "🙂"
    check values[4].text == "🙂"
    for escape in [r"\uD800", r"\U00110000", r"\u{}", r"\u{1234567}", r"\x42"]:
      expect CapabilityLiteralError:
        discard parseCapabilityTest("[(test/Limits \"" & escape & "\")]")

  test "integer range is checked rather than overflowing":
    let values = parseCapabilityTest(
      "[(test/Limits -9223372036854775808 9223372036854775807 5)]"
    ).entries[0].body
    check values[0].integer == low(int64)
    check values[1].integer == high(int64)
    check values[2].integer == 5
    check parseCapabilityTest("[(test/Limits 0x7fffffffffffffff)]"
      ).entries[0].body[0].integer == high(int64)
    check parseCapabilityTest("[(test/Limits -0x8000000000000000)]"
      ).entries[0].body[0].integer == low(int64)
    for number in ["9223372036854775808", "-9223372036854775809", "+", "+5", "--1",
                   "0x8000000000000000", "-0x8000000000000001", "0x1fg"]:
      expect CapabilityLiteralError:
        discard parseCapabilityTest("[(test/Limits " & number & ")]")

  test "comments are inert and nesting is bounded":
    check parseCapabilityTest("# initial\n[#| outer #| inner |# |# fs/Read]").len == 1
    expect CapabilityLiteralError:
      discard parseCapabilityTest("[#| never closes")
    var limits = DefaultCapabilityLiteralLimits
    limits.maxCommentDepth = 1
    expect CapabilityLiteralError:
      discard parseCapabilityTest("[#| #| too deep |# |#]", limits = limits)

  test "byte, row, body, property, list and string limits reject excess":
    for kind in 0..5:
      var limits = DefaultCapabilityLiteralLimits
      var text: string
      case kind
      of 0:
        limits.maxBytes = 2
        text = "[fs/Read]"
      of 1:
        limits.maxEntries = 1
        text = "[fs/Read fs/Write]"
      of 2:
        limits.maxBodyValues = 1
        text = "[(fs/Read \"/a\" \"/b\")]"
      of 3:
        limits.maxProperties = 1
        text = "[(net/Http ^^optional ^methods [])]"
      of 4:
        limits.maxListItems = 1
        text = "[(net/Http ^methods [\"GET\" \"POST\"])]"
      else:
        limits.maxStringBytes = 1
        text = "[(fs/Read \"ab\")]"
      expect CapabilityLiteralError:
        discard parseCapabilityTest(text, limits = limits)

suite "checked capability literal builder":
  test "untrusted strings cannot create entries and patterns require opt-in":
    let injected = "x\") (fs/ReadWrite \"/"
    let row = buildCapabilityLiteral([
      CapabilityEntryLiteral(name: "fs/Read", body: @[capabilityText(injected)]),
      CapabilityEntryLiteral(name: "net/Http", properties: @[
        CapabilityPropertyLiteral(name: "hosts",
          value: capabilityValues([capabilityText("*"), capabilityPattern("*.example.com")]))])
    ], cuBound, capabilityLiteralSource())
    check row.len == 2
    check row.entries[0].body[0].text == injected
    let hosts = row.entries[1].properties[0].value.items
    check hosts[0].stringMode == csmLiteral
    check hosts[1].stringMode == csmPattern

  test "builder input and inspection cannot mutate a published row":
    var input = @[CapabilityEntryLiteral(name: "fs/Read",
      body: @[capabilityText("/original")],
      properties: @[CapabilityPropertyLiteral(name: "modes",
        value: capabilityValues([capabilityText("read")]))])]
    let row = buildCapabilityLiteral(input, cuRequest, capabilityLiteralSource())
    input[0].body[0].text[1] = 'X'
    input[0].properties[0].value.items[0].text = "write"
    var exposed = row.entries
    exposed[0].body[0].text = "/changed"
    exposed[0].properties[0].value.items[0].text[0] = 'X'
    check row.entries[0].body[0].text == "/original"
    check row.entries[0].properties[0].value.items[0].text == "read"

  test "builder validates metadata, duplicates, source bases and limits":
    for use in [cuGrant, cuBound]:
      expect CapabilityLiteralError:
        discard buildCapabilityLiteral([
          CapabilityEntryLiteral(name: "net/Http", hasOptional: true)
        ], use, capabilityLiteralSource())
    expect CapabilityLiteralError:
      discard buildCapabilityLiteral([
        CapabilityEntryLiteral(name: "net/Http", properties: @[
          CapabilityPropertyLiteral(name: "methods", value: capabilityValue(capabilityAny())),
          CapabilityPropertyLiteral(name: "methods", value: capabilityValue(capabilityAny()))])
      ], cuRequest, capabilityLiteralSource())
    expect CapabilityLiteralError:
      discard buildCapabilityLiteral([], cuGrant,
        CapabilitySourceContext(baseDirectory: "relative"))
    var limits = DefaultCapabilityLiteralLimits
    limits.maxStringBytes = 1
    expect CapabilityLiteralError:
      discard buildCapabilityLiteral([
        CapabilityEntryLiteral(name: "fs/Read", body: @[capabilityText("ab")])
      ], cuBound, capabilityLiteralSource(), limits)

  test "source-interpreted strings cannot be smuggled through the builder":
    let raw = parseCapabilityTest("[(fs/Read \"*\")]")
    expect CapabilityLiteralError:
      discard buildCapabilityLiteral(raw.entries, cuBound, raw.source)

  test "missing builder values do not default to unrestricted permission":
    expect CapabilityLiteralError:
      discard buildCapabilityLiteral([
        CapabilityEntryLiteral(name: "net/Http", properties: @[
          CapabilityPropertyLiteral(name: "hosts")])
      ], cuBound, capabilityLiteralSource())
    expect CapabilityLiteralError:
      discard buildCapabilityLiteral([
        CapabilityEntryLiteral(name: "fs/Read", body: @[CapabilityScalar()])
      ], cuBound, capabilityLiteralSource())
