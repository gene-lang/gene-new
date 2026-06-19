import std/[os, osproc, strutils, unittest]

let cliDir = getTempDir() / "gene_cli_tests"
let geneExe = cliDir / "gene-test-bin"
var cliBuilt = false

proc buildGeneCli() =
  if cliBuilt:
    return
  createDir(cliDir)
  let build = execCmdEx("nim c --path:src --hints:off -o:" & geneExe & " src/gene.nim")
  if build.exitCode != 0:
    checkpoint build.output
  check build.exitCode == 0
  cliBuilt = true

proc writeCliProgram(name, src: string): string =
  createDir(cliDir)
  result = cliDir / name
  writeFile(result, src)

proc shellQuote(arg: string): string =
  if arg.len == 0:
    return "''"
  result = "'"
  for ch in arg:
    if ch == chr(39):
      result.add "'\\''"
    else:
      result.add ch
  result.add "'"

proc runGene(args: openArray[string]): tuple[output: string, exitCode: int] =
  buildGeneCli()
  var command = shellQuote(geneExe)
  for arg in args:
    command.add " " & shellQuote(arg)
  execCmdEx(command)

proc runGeneInput(args: openArray[string],
                  input: string): tuple[output: string, exitCode: int] =
  buildGeneCli()
  var command = shellQuote(geneExe)
  for arg in args:
    command.add " " & shellQuote(arg)
  execCmdEx(command, input = input)

suite "cli — gene run":
  setup:
    createDir(cliDir)

  test "main return convention controls process exit":
    let nilMain = writeCliProgram("nil_main.gene", "(fn main [] nil)")
    var ran = runGene(["run", nilMain])
    check ran.exitCode == 0

    let intMain = writeCliProgram("int_main.gene", "(fn main [] 7)")
    ran = runGene(["run", intMain])
    check ran.exitCode == 7

  test "main receives command-line arguments":
    let argMain = writeCliProgram("arg_main.gene",
      "(fn main [args] (if (= args/0 \"ok\") 0 4))")
    let ran = runGene(["run", argMain, "ok"])
    check ran.exitCode == 0

  test "invalid main return is a boundary TypeError":
    let badMain = writeCliProgram("bad_main.gene", "(fn main [] \"bad\")")
    let ran = runGene(["run", badMain])
    check ran.exitCode == 1
    check "TypeError" in ran.output
    check "main return expected Nil or Int" in ran.output

  test "oversized main return is a boundary TypeError":
    let bigMain = writeCliProgram("big_main.gene",
      "(fn main [] 9223372036854775808)")
    let ran = runGene(["run", bigMain])
    check ran.exitCode == 1
    check "TypeError" in ran.output
    check "main return Int must fit in int64" in ran.output

suite "cli — gene eval":
  setup:
    createDir(cliDir)

  test "evaluates source strings and prints the final value":
    let ran = runGene(["eval", "(var x 2) (+ x 3)"])
    check ran.exitCode == 0
    check ran.output.strip == "5"

  test "uses eval authority rules instead of ambient imports":
    let ran = runGene(["eval", "(import [x] from \"./missing\") x"])
    check ran.exitCode == 1
    check "eval cannot use import; add imports to Env" in ran.output

suite "cli — gene repl":
  setup:
    createDir(cliDir)

  test "retains declarations across input lines":
    let ran = runGeneInput(["repl"], "(var x 2)\n(+ x 3)\n")
    check ran.exitCode == 0
    check ran.output.strip.splitLines == @["2", "5"]

  test "uses eval authority rules for each input line":
    let ran = runGeneInput(["repl"], "(import [x] from \"./missing\")\n(+ 1 2)\n")
    check ran.exitCode == 0
    check "eval cannot use import; add imports to Env" in ran.output
    check ran.output.strip.splitLines[^1] == "3"

suite "cli — gene parse/fmt/compile":
  setup:
    createDir(cliDir)

  test "parse prints canonical multi-form source":
    let path = writeCliProgram("parse_subject.gene",
      "(var x   1)\n" &
      "[x   2]\n")
    let ran = runGene(["parse", path])
    check ran.exitCode == 0
    check ran.output.strip.splitLines == @[
      "(var x 1)",
      "[x 2]"
    ]

  test "fmt uses the same canonical source-unit printer":
    let path = writeCliProgram("fmt_subject.gene",
      "(quote (x @line   7 ^name \"Ada\"))\n" &
      "#{^b 2 ^a   1}")
    let ran = runGene(["fmt", path])
    check ran.exitCode == 0
    check ran.output.strip.splitLines == @[
      "(quote (x @line 7 ^name \"Ada\"))",
      "#{^b 2 ^a 1}"
    ]

  test "compile prints bytecode without executing forms":
    let path = writeCliProgram("compile_subject.gene",
      "(panic \"compile should not run\")")
    let ran = runGene(["compile", path])
    check ran.exitCode == 0
    check "opPanic" in ran.output
    check "Panic:" notin ran.output

suite "cli — gene doc":
  setup:
    createDir(cliDir)

  test "prints module metadata and declarations without calling main":
    let path = writeCliProgram("doc_subject.gene",
      "(mod docs @doc \"module docs\") " &
      "(var answer 42) " &
      "(fn helper [] answer) " &
      "(fn main [] (panic \"doc should not call main\"))")
    let ran = runGene(["doc", path])
    check ran.exitCode == 0
    let lines = ran.output.strip.splitLines
    check lines[0] == "Module: docs"
    check lines[1] == "Path: " & normalizedPath(absolutePath(path))
    check lines[2] == "Doc: module docs"
    check lines[3] == "Declarations:"
    check lines[4 .. ^1] == @[
      "- answer : Int",
      "- helper : Fn",
      "- main : Fn"
    ]
    check "this-mod" notin ran.output

  test "prints namespace declarations recursively":
    let path = writeCliProgram("doc_namespaces.gene",
      "(mod docs) " &
      "(ns util " &
      "  (var answer 42) " &
      "  (fn double [x] (+ x x)) " &
      "  (ns nested (var flag true)))")
    let ran = runGene(["doc", path])
    check ran.exitCode == 0
    let lines = ran.output.strip.splitLines
    check lines == @[
      "Module: docs",
      "Path: " & normalizedPath(absolutePath(path)),
      "Declarations:",
      "- util : Namespace",
      "Namespaces:",
      "Namespace util:",
      "- answer : Int",
      "- double : Fn",
      "- nested : Namespace",
      "Namespace util/nested:",
      "- flag : Bool"
    ]

  test "prints normalized import targets":
    let depPath = writeCliProgram("dep_for_doc.gene",
      "(var dep 1)")
    let path = writeCliProgram("doc_imports.gene",
      "(mod docs) " &
      "(import [dep : local-dep] from \"./dep_for_doc\") " &
      "(ns source (var item 2)) " &
      "(import source [item : local-item]) " &
      "(var done true)")
    let ran = runGene(["doc", path])
    check ran.exitCode == 0
    let lines = ran.output.strip.splitLines
    check lines == @[
      "Module: docs",
      "Path: " & normalizedPath(absolutePath(path)),
      "Imports:",
      "- from \"./dep_for_doc\" -> " & normalizedPath(absolutePath(depPath)) &
        " [dep : local-dep]",
      "- source [item : local-item]",
      "Declarations:",
      "- done : Bool",
      "- local-dep : Int",
      "- local-item : Int",
      "- source : Namespace",
      "Namespaces:",
      "Namespace source:",
      "- item : Int"
    ]
