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

proc runGene(args: openArray[string]): tuple[output: string, exitCode: int] =
  buildGeneCli()
  var command = geneExe
  for arg in args:
    command.add " " & arg
  execCmdEx(command)

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
