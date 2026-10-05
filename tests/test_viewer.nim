import std/[options, strutils, unittest]
import tools/source_index
import gene/ext/term/tui
import tools/viewer/model

suite "viewer — pure navigation model":
  test "enter leave paging and paths are terminal independent":
    var state = newViewerState(indexSource("(server ^port 8080 ^routes [[a] [b] [c]])"))
    state.move(2, 3)
    check pathText(state.currentPath()) == "routes"
    check state.enter()
    state.last(2)
    check pathText(state.currentPath()) == "routes/2"
    check state.leave()
    check pathText(state.currentPath()) == "routes"

  test "initial Gene path supports negative list indexes":
    var state = newViewerState(indexSource("{^routes [a b c]}"))
    check state.selectPath(parseSourcePath("routes/-1"))
    check state.selectedRow().get.summary == "c"

  test "negative indexes count only node body rows":
    var state = newViewerState(indexSource("(server ^port 8080 [a] [b])"))
    check state.selectPath(parseSourcePath("-1"))
    check state.selectedRow().get.summary == "[b]"

  test "reload restores the deepest surviving path":
    var state = newViewerState(indexSource("{^routes [{^method GET} {^method POST}]}"))
    check state.selectPath(parseSourcePath("routes/1/method"))
    state.reload(indexSource("{^routes [{^method PUT} {^method POST}]}"))
    check pathText(state.currentPath()) == "routes/1/method"

  test "line selection descends to the smallest occurrence":
    let source = "(server\n  ^port 8080\n  ^host \"x\")"
    var state = newViewerState(indexSource(source))
    check state.selectOffset(source.find("8080"))
    check state.selectedRow().get.summary == "8080"

  test "terminal labels align by display cells":
    let fitted = fitCells("端口", 6)
    check textWidth(fitted) == 6
    check fitted.endsWith("  ")

  test "shared SGR mouse decoding preserves both wheel directions":
    check mouseScrollFromEscape("[<64;10;4M") == 1
    check mouseScrollFromEscape("[<65;10;4M") == -1
    check mouseScrollFromEscape("[A") == 0

  test "serialized envelope opens at its payload and keeps source spans":
    let source = "(serde_v1 [#{^id 1 ^name \"first\"} #{^id 2}])"
    var state = newViewerState(indexSource(source))
    check state.serialized
    check state.rowCount() == 2
    check state.selectedRow().get.label == "0"
    check state.selectPath(parseSourcePath("1/id"))
    check state.selectedRaw() == "2"
    check pathText(state.currentPath()) == "1/id"
    state.reload(indexSource("(serde_v1 [#{^id 1} #{^id 3}])"))
    check state.serialized
    check state.selectedRaw() == "3"

  test "escaped serialized maps expose keys and set elements":
    let source = "(serde_v1 (serde_map false [\"odd key\" " &
      "(serde_set 2 3) \"simple\" [4 5]]))"
    var state = newViewerState(indexSource(source))
    check state.serialized
    check state.rowCount() == 2
    check state.rowPage(0, 2)[0].label == "odd key"
    check state.rowSummary(state.rowPage(0, 1)[0]) == "Set · 2 items"
    check state.selectPath(@[propertySegment("odd key"), indexSegment(1)])
    check state.selectedRaw() == "3"
    check pathText(state.currentPath()) == "(path \"odd key\" 1)"
    check state.selectPath(parseSourcePath("simple/0"))
    check state.selectedRaw() == "4"

  test "escaped data nodes show logical head props meta and body":
    let source = "(serde_v1 (serde_data_node false serde_sym " &
      "(serde_map false [\"x\" 1]) (serde_map false []) [2 3]))"
    var state = newViewerState(indexSource(source))
    check state.serialized
    check state.rowCount() == 4
    let items = state.rowPage(0, 4)
    check items[0].label == "head"
    check items[1].label == "props"
    check items[2].label == "meta"
    check items[3].label == "0"
    check state.selectPath(@[propertySegment("props"), propertySegment("x")])
    check state.selectedRaw() == "1"

  test "ordinary source and malformed envelopes retain source navigation":
    let ordinary = newViewerState(indexSource("(serde_v1 [1] [2])"))
    check not ordinary.serialized
    check ordinary.rowCount() == 3
    let malformed = newViewerState(indexSource("(serde_v1 [1]"))
    check not malformed.serialized
    let raw = newViewerState(indexSource("(serde_v1 [1])"), rawMode = true)
    check not raw.serialized
    check raw.rowCount() == 2

  test "selected preview stops at a UTF-8 boundary":
    let state = newViewerState(indexSource("(serde_v1 [\"界界\"])"))
    check state.selectedExcerpt(3) == "\""
    check state.selectedByteLength() == "\"界界\"".len

  test "serialized scalar tags appear as values rather than nested code":
    var state = newViewerState(indexSource(
      "(serde_v1 [(serde_sym \"a/b\") (serde_float \"nan\")])"))
    check state.rowSummary(state.rowPage(0, 1)[0]) == "Symbol · \"a/b\""
    check not state.browsable(state.selectedRow().get.syntax)
    check not state.enter()
    state.move(1, 10)
    check state.rowSummary(state.selectedRow().get) == "Float · \"nan\""
