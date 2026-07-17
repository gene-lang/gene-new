import std/[strutils, unittest]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import gene/vterm

  suite "embedded terminal — libvterm state":
    test "ANSI, Unicode, cursor, and colors become attributed cells":
      let terminal = openVTerm(4, 20, scrollbackLines = 8)
      defer: terminal.close()

      terminal.feed("hello\e[31;1mR\e[0m\r\n界e\u0301")
      let state = terminal.snapshot()
      check state.rows == 4
      check state.cols == 20
      check state.cursorRow == 1
      check state.cursorCol == 3
      check terminal.cell(0, 0).text == "h"
      check terminal.cell(0, 5).text == "R"
      check terminal.cell(0, 5).bold
      check terminal.cell(0, 5).foreground.red > 0
      check terminal.cell(1, 0).text == "界"
      check terminal.cell(1, 0).width == 2
      check terminal.cell(1, 1).continuation
      check terminal.cell(1, 2).text == "e\u0301"

    test "escape sequences split at every byte produce the same state":
      let input = "a\e[2;4H\e[38;2;1;2;3mZ\e[0m\e]2;worker title\a"
      let whole = openVTerm(4, 12)
      let split = openVTerm(4, 12)
      defer:
        whole.close()
        split.close()

      whole.feed(input)
      for byte in input:
        split.feed($byte)

      check split.screenText() == whole.screenText()
      check split.snapshot().cursorRow == whole.snapshot().cursorRow
      check split.snapshot().cursorCol == whole.snapshot().cursorCol
      check split.snapshot().title == "worker title"
      check split.cell(1, 3).foreground.red == 1
      check split.cell(1, 3).foreground.green == 2
      check split.cell(1, 3).foreground.blue == 3

    test "SGR attributes and indexed or true colors remain cell data":
      let terminal = openVTerm(2, 8)
      defer: terminal.close()

      terminal.feed(
        "\e[1;2;3;4;5;7;8;9;38;5;196;48;2;1;2;3mX\e[0m")
      let cell = terminal.cell(0, 0)
      check cell.text == "X"
      check cell.bold
      check cell.dim
      check cell.italic
      check cell.underline == 1
      check cell.blink
      check cell.reverse
      check cell.conceal
      check cell.strike
      check not cell.foreground.isDefault
      check (cell.foreground.red, cell.foreground.green,
             cell.foreground.blue) == (255'u8, 0'u8, 0'u8)
      check (cell.background.red, cell.background.green,
             cell.background.blue) == (1'u8, 2'u8, 3'u8)

    test "insert delete erase and partial scroll regions update exact cells":
      let terminal = openVTerm(4, 10, scrollbackLines = 8)
      defer: terminal.close()

      terminal.feed("abcdef\e[1;3H\e[2@")
      check terminal.cell(0, 0).text == "a"
      check terminal.cell(0, 1).text == "b"
      check terminal.cell(0, 2).text == ""
      check terminal.cell(0, 3).text == ""
      check terminal.cell(0, 4).text == "c"
      terminal.feed("\e[2J\e[Habcdef\e[1;3H\e[2P")
      check terminal.screenText().splitLines()[0] == "abef"
      terminal.feed("\e[2J\e[Habcdef\e[1;3H\e[2X")
      check terminal.cell(0, 0).text == "a"
      check terminal.cell(0, 1).text == "b"
      check terminal.cell(0, 2).text == ""
      check terminal.cell(0, 3).text == ""
      check terminal.cell(0, 4).text == "e"

      terminal.feed("\e[2J\e[H111\r\n222\r\n333\r\n444")
      terminal.feed("\e[2;4r\e[4;1H\r\n555")
      let lines = terminal.screenText().splitLines()
      check lines[0] == "111"
      check lines[1] == "333"
      check lines[2] == "444"
      check lines[3] == "555"
      check terminal.snapshot().scrollbackLines == 0

    test "alternate screen and terminal replies stay inside the emulator":
      let terminal = openVTerm(3, 10)
      defer: terminal.close()

      discard terminal.drainOutput()
      terminal.feed("normal\e[?1049hALT")
      check terminal.snapshot().altscreen
      check terminal.screenText().startsWith("ALT")
      terminal.feed("\e[6n")
      let reply = terminal.drainOutput()
      check reply.startsWith("\e[")
      check reply.endsWith("R")
      terminal.feed("\e[?1049l")
      check not terminal.snapshot().altscreen
      check terminal.screenText().startsWith("normal")

    test "normal-screen scrollback is bounded with explicit loss":
      let terminal = openVTerm(2, 8, scrollbackLines = 2)
      defer: terminal.close()

      terminal.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive")
      let state = terminal.snapshot()
      check state.scrollbackLines == 2
      check state.scrollbackDropped >= 1
      check terminal.scrollbackCols(0) == 8

    test "key encoding follows application cursor mode":
      let terminal = openVTerm(2, 8)
      defer: terminal.close()

      discard terminal.drainOutput()
      terminal.sendKey(vtkUp)
      check terminal.drainOutput() == "\e[A"
      terminal.feed("\e[?1h")
      terminal.sendKey(vtkUp)
      check terminal.drainOutput() == "\eOA"

    test "paste mouse focus and OSC metadata are emulated, not printed":
      let terminal = openVTerm(2, 12)
      defer: terminal.close()

      discard terminal.drainOutput()
      terminal.feed("\e[?2004h")
      terminal.startPaste()
      check terminal.drainOutput() == "\e[200~"
      terminal.endPaste()
      check terminal.drainOutput() == "\e[201~"

      terminal.feed("\e[?1004h")
      check terminal.snapshot().focusReporting
      terminal.focusIn()
      check terminal.drainOutput() == "\e[I"
      terminal.focusOut()
      check terminal.drainOutput() == "\e[O"

      terminal.feed("\e[?1000h\e[?1006h")
      check terminal.snapshot().mouseMode > 0
      terminal.sendMouseMove(1, 2)
      terminal.sendMouseButton(1, true)
      check terminal.drainOutput() == "\e[<0;3;2M"

      terminal.feed("\e]2;pane title\a\e]7;file://host/tmp/project\e\\")
      check terminal.snapshot().title == "pane title"
      check terminal.snapshot().workingDirectoryUri ==
        "file://host/tmp/project"

    test "oversized and malformed control strings remain bounded":
      let terminal = openVTerm(2, 8)
      defer: terminal.close()

      let hostile = "\e]7;file://host/" & repeat("x", 5000) & "\e\\"
      for byte in hostile:
        terminal.feed($byte)
      check terminal.snapshot().workingDirectoryUri.len <= 1023
      terminal.feed("\e[999999999999999999999999;999999999999999999H")
      check terminal.snapshot().rows == 2
      check terminal.snapshot().cols == 8
      discard terminal.cell(1, 7)
