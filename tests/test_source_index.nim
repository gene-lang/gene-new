import std/[strutils, unicode, unittest]
import gene/[reader, source_index, source_positions]

suite "source index — reader-backed occurrences":
  test "tokens carry exact raw spans despite cooked lexemes":
    let source = "\"a\\n\" 42 # note\n"
    let tokens = lexAllSpanned(source, includeTrivia = true)
    check source[tokens[0].startByte ..< tokens[0].endByte] == "\"a\\n\""
    check tokens[0].lexeme == "a\n"
    check source[tokens[1].startByte ..< tokens[1].endByte] == "42"
    check tokens[2].kind == tkLineComment
    check source[tokens[2].startByte ..< tokens[2].endByte] == "# note"

  test "interpolation is one exact occurrence":
    let source = "$\"hello ${name}\""
    let doc = indexSource(source)
    check doc.root.kind == skInterpolation
    check doc.root.span == ByteSpan(startByte: 0, endByte: source.len)
    check doc.children(doc.root).len == 0

  test "node rows preserve head properties and body paths":
    let doc = indexSource("(server ^host \"127.0.0.1\" ^port 8080 [a b])")
    let rows = doc.children(doc.root)
    check rows.len == 4
    check rows[0].label == "head"
    check rows[0].summary == "server"
    check rows[1].label == "host"
    check rows[2].label == "port"
    check rows[3].label == "0"
    check rows[3].syntax.kind == skList
    check pathText(rows[2].path) == "port"

  test "multi-form root uses semantic form indexes":
    let doc = indexSource("# preface\n(a)\n#_ (discarded)\n[b]")
    check doc.root.kind == skSequence
    check doc.topLevel.len == 2
    let rows = doc.children(doc.root)
    check rows[0].label == "0"
    check rows[1].label == "1"

  test "Gene paths are parsed by the real reader":
    let path = parseSourcePath("prop/0/x/-1")
    check path.len == 4
    check path[0].kind == spsProperty
    check path[1].kind == spsIndex
    check path[3].index == -1
    check pathText(path) == "prop/0/x/-1"

  test "shared positions cover bytes and UTF-16":
    let source = "aπ😀\nnext"
    let starts = lineStarts(source)
    check offsetLineCol(source, starts, "aπ".len) == (line: 1, col: 4)
    let pos = offsetToLspPos(source, starts, "aπ".len)
    check pos == LspPos(line: 0, character: 2)
    check lspPosToOffset(source, starts, pos) == "aπ".len

  test "invalid delimiter structure remains browsable with a diagnostic":
    let doc = indexSource("(server [broken)")
    check doc.diagnostics.len == 1
    check "mismatched closing delimiter" in doc.diagnostics[0].message
    check doc.topLevel.len == 1

  test "unclosed containers retain their final valid child":
    let doc = indexSource("(a b")
    let rows = doc.children(doc.root)
    check doc.diagnostics.len == 1
    check rows.len == 2
    check rows[0].summary == "a"
    check rows[1].summary == "b"

  test "malformed property and map tails are visible as error rows":
    let propDoc = indexSource("(a ^missing)")
    let propRows = propDoc.children(propDoc.root)
    check propRows.len == 2
    check propRows[1].syntax.kind == skError
    check propRows[1].summary == "missing value"

    let mapDoc = indexSource("{{key : }}")
    let mapRows = mapDoc.children(mapDoc.root)
    check mapRows.len == 1
    check mapRows[0].syntax.kind == skError
    check mapRows[0].summary == "missing value"

  test "summaries truncate only at UTF-8 rune boundaries":
    let payload = repeat("界", 30)
    let doc = indexSource("[\"" & payload & "\"]")
    let summary = doc.children(doc.root)[0].summary
    check validateUtf8(summary) == -1
    check summary.endsWith("…")

  test "paged children materialize only the requested result range":
    let doc = indexSource("[a b c d e]")
    check doc.childCount(doc.root) == 5
    let page = doc.childPage(doc.root, 2, 2)
    check page.len == 2
    check page[0].summary == "c"
    check page[1].summary == "d"
