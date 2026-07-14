import std/[options, strutils, unittest]
import gene/[source_index]
import gene/tui/terminal
import gene/viewer/model

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
