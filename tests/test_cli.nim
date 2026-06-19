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
