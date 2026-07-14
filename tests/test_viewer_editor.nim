import std/[os, unittest]
import gene/viewer/editor

suite "viewer — external editor":
  test "configured commands are parsed without a shell":
    let editor = parseEditorCommand("nvim -f")
    check editor.executable == "nvim"
    check editor.args == @["-f"]
    check editor.editorArgs("a b.gene", 3, 7) ==
      @["-f", "+call cursor(3,7)", "a b.gene"]

  test "cursor adapters preserve the file as one argument":
    check EditorCommand(executable: "nano").editorArgs("a b", 2, 4) ==
      @["+2,4", "a b"]
    check EditorCommand(executable: "code").editorArgs("a b", 2, 4) ==
      @["--goto", "a b:2:4"]

  test "override wins over environment":
    let oldVisual = getEnv("VISUAL")
    putEnv("VISUAL", "nano")
    try:
      check resolveEditor("vim -f").executable == "vim"
    finally:
      putEnv("VISUAL", oldVisual)
