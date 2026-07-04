import std/[os, osproc, strutils, unittest]
import gene/[repl, vm]

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

  test "main receives raw command-line argument tail":
    let rawMain = writeCliProgram("raw_arg_main.gene",
      "(fn main [args] (if (= args/raw \"a b, c\") 0 4))")
    let ran = runGene(["run", rawMain, "a", "b,", "c"])
    check ran.exitCode == 0

  test "main parameter boundary errors include source location":
    let typedMain = writeCliProgram("typed_arg_main.gene",
      "(fn main [args : (List Str)] nil)")
    let ran = runGene(["run", typedMain, "x"])
    check ran.exitCode == 1
    check "parameter 'args' expected (List Str), got vkNode" in ran.output
    check ("at " & normalizedPath(absolutePath(typedMain)) & ":1:1") in ran.output

  test "ai agent example runs offline demo without an auth token":
    buildGeneCli()
    let ran = execCmdEx("env -u OPENAI_AUTH_TOKEN -u CODEX_ACCESS_TOKEN " &
                        shellQuote(geneExe) & " run examples/ai_agent.gene")
    check ran.exitCode == 0
    check "No OPENAI_AUTH_TOKEN or CODEX_ACCESS_TOKEN set" in ran.output
    check "agent>   · tool list_dir" in ran.output
    check "Demo complete" in ran.output

  test "ai agent slash sh opens a shell loop":
    buildGeneCli()
    let command = "printf '/sh\\nprintf hi\\nexit\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "Entering shell" in ran.output
    check "hi" in ran.output
    check "sh> \nyou>" in ran.output

  test "ai agent ignores blank input":
    buildGeneCli()
    let command = "printf '   \\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "agent>" notin ran.output

  test "ai agent slash repl exposes session binding":
    buildGeneCli()
    let command = "printf '/repl\\nsession/model\\n(var x 41)\\n(+ x 1)\\nquit\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "Entering Gene REPL" in ran.output
    check "gpt-5.4-mini" in ran.output
    check "41" in ran.output
    check "42" in ran.output

  test "ai agent repl eof returns to agent prompt":
    buildGeneCli()
    let command = "printf '/repl\\nsession/model\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "gpt-5.4-mini" in ran.output
    check "gene> \nyou>" in ran.output

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

  test "eval errors include source location":
    let ran = runGene(["eval", "(missing)"])
    check ran.exitCode == 1
    check "undefined symbol: missing" in ran.output
    check "at <eval>:1:1" in ran.output

suite "cli — gene repl":
  setup:
    createDir(cliDir)

  test "runReplSession can be driven programmatically":
    let app = initModuleContext(cliDir)
    let scope = newGlobalScope(app)
    var inputs = @["(var x 2)", "(+ x 4)", ":quit"]
    var index = 0
    var outText = ""
    var errText = ""
    let reader = proc(line: var string): bool =
      if index >= inputs.len:
        return false
      line = inputs[index]
      inc index
      true
    let writeOut = proc(text: string) =
      outText.add text
    let writeErr = proc(text: string) =
      errText.add text

    let code = runReplSession(scope, reader, writeOut, writeErr)

    check code == 0
    check outText.strip.splitLines == @["2", "6"]
    check errText == ""

  test "runReplSession writes newline on interactive eof":
    let app = initModuleContext(cliDir)
    let scope = newGlobalScope(app)
    var outText = ""
    var errText = ""
    let reader = proc(line: var string): bool =
      false
    let writeOut = proc(text: string) =
      outText.add text
    let writeErr = proc(text: string) =
      errText.add text

    let code = runReplSession(scope, reader, writeOut, writeErr,
                              ReplOptions(interactive: true, prompt: "gene> "))

    check code == 0
    check outText == "gene> \n"
    check errText == ""

  test "retains declarations across input lines":
    let ran = runGeneInput(["repl"], "(var x 2)\n(+ x 3)\n")
    check ran.exitCode == 0
    check ran.output.strip.splitLines == @["2", "5"]

  test "continues reading after incomplete input":
    let ran = runGeneInput(["repl"], "(+ 1\n2)\n")
    check ran.exitCode == 0
    check ran.output.strip == "3"

  test "reports incomplete input on eof":
    let ran = runGeneInput(["repl"], "(+ 1\n")
    check ran.exitCode == 0
    check "Read error: unexpected EOF: unclosed '('" in ran.output

  test "interactive incomplete input uses continuation prompt":
    let app = initModuleContext(cliDir)
    let scope = newGlobalScope(app)
    var inputs = @["(+ 1", "2)", ":quit"]
    var index = 0
    var outText = ""
    var errText = ""
    let reader = proc(line: var string): bool =
      if index >= inputs.len:
        return false
      line = inputs[index]
      inc index
      true
    let writeOut = proc(text: string) =
      outText.add text
    let writeErr = proc(text: string) =
      errText.add text

    let code = runReplSession(scope, reader, writeOut, writeErr,
                              ReplOptions(interactive: true, prompt: "gene> "))

    check code == 0
    check outText == "gene> ....> 3\ngene> "
    check errText == ""

  test "rejects unknown repl options":
    let ran = runGene(["repl", "--bogus"])
    check ran.exitCode == 1
    check "unknown repl option: --bogus" in ran.output

  test "uses eval authority rules for each input line":
    let ran = runGeneInput(["repl"], "(import [x] from \"./missing\")\n(+ 1 2)\n")
    check ran.exitCode == 0
    check "eval cannot use import; add imports to Env" in ran.output
    check ran.output.strip.splitLines[^1] == "3"

  test "REPL_ON_ERROR enters repl after eval errors":
    buildGeneCli()
    let command = "env REPL_ON_ERROR=1 " & shellQuote(geneExe) &
                  " eval " & shellQuote("(var x 2) missing")
    let ran = execCmdEx(command, input = "x\n:quit\n")
    check ran.exitCode == 1
    check "Error: undefined symbol: missing" in ran.output
    check "REPL_ON_ERROR=1: entering Gene REPL" in ran.output
    check "\n2\n" in ran.output

  test "REPL_ON_ERROR enters module repl after run errors":
    let path = writeCliProgram("run_error_repl.gene",
      "(var x 41) (fn main [] missing)")
    buildGeneCli()
    let command = "env REPL_ON_ERROR=1 " & shellQuote(geneExe) &
                  " run " & shellQuote(path)
    let ran = execCmdEx(command, input = "x\n:quit\n")
    check ran.exitCode == 1
    check "Error: undefined symbol: missing" in ran.output
    check "REPL_ON_ERROR=1: entering Gene REPL" in ran.output
    check "\n41\n" in ran.output

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

  test "compile target c prints experimental typed-native C":
    let path = writeCliProgram("compile_c_subject.gene",
      "(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
      "(ffi/fn strlen ^library libc ^symbol \"strlen\" [s : C/CStr] : C/Size) " &
      "(fn main [] (panic \"compile c should not run\"))")
    let ran = runGene(["compile", "--target", "c", path])
    check ran.exitCode == 0
    check "#include <stdint.h>" in ran.output
    check "int64_t gene_native_add64(int64_t x, int64_t y)" in ran.output
    check "static const GeneAotModuleFunction gene_aot_module[] = {" in ran.output
    check "{\"add64\", \"gene_native_add64\", \"I64\", 2, &gene_frame_add64}," in ran.output
    check "extern size_t GENE_FFI_CDECL strlen(const char * s);" in ran.output
    check "GeneStatus gene_ffi_strlen" in ran.output
    check "Panic:" notin ran.output

  test "compile rejects reserved native targets explicitly":
    let path = writeCliProgram("compile_reserved_target.gene",
      "(fn main [] nil)")
    let ran = runGene(["compile", "--target", "llvm", path])
    check ran.exitCode == 1
    check "unsupported compile target: llvm" in ran.output

  test "file runtime errors include source location and snippet":
    let path = writeCliProgram("located_runtime_error.gene",
      "(var x 1)\n(+ x missing)\n")
    let ran = runGene(["run", path])
    check ran.exitCode == 1
    check "undefined symbol: missing" in ran.output
    check ("at " & normalizedPath(absolutePath(path)) & ":2:1") in ran.output
    check "2 | (+ x missing)" in ran.output

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
