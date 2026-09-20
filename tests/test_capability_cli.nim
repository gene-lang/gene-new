import std/[options, os, osproc, strtabs, strutils, tempfiles, unittest]

let capabilityCliRoot = expandFilename(createTempDir("gene-capability-cli-", ""))
let capabilityCliExe = capabilityCliRoot / "gene"
var capabilityCliBuilt = false

proc capabilityCliBinary(): string =
  let supplied = getEnv("GENE_CAP_TEST_BIN")
  if supplied.len > 0: return supplied
  if not capabilityCliBuilt:
    let built = execCmdEx("nim c --path:src --hints:off -o:" &
      quoteShell(capabilityCliExe) & " src/gene.nim")
    if built.exitCode != 0: raise newException(IOError, built.output)
    capabilityCliBuilt = true
  capabilityCliExe

proc runCapabilityCli(args: openArray[string], directory: string,
    policy: Option[string] = none(string), input = ""): tuple[output: string, exitCode: int] =
  var environment = newStringTable(modeCaseSensitive)
  for name, value in envPairs(): environment[name] = value
  environment.del("GENE_CAPABILITIES")
  environment.del("REPL_ON_ERROR")
  environment["GENE_ARTIFACT_STORE"] = capabilityCliRoot / "artifacts"
  environment["GENE_WORKERS"] = "0"
  if policy.isSome: environment["GENE_CAPABILITIES"] = policy.get
  var command = quoteShell(capabilityCliBinary())
  for arg in args: command.add " " & quoteShell(arg)
  execCmdEx(command, env = environment, workingDir = directory, input = input)

proc capabilityCliFixture(): string =
  result = expandFilename(createTempDir("fixture-", "", capabilityCliRoot))

proc capabilityQuote(value: string): string = value.escape()

suite "capability launcher contract":
  test "empty startup still evaluates code and displays a host-selected result":
    let root = capabilityCliFixture()
    let result = runCapabilityCli(["eval", "(+ 2 3)"], root)
    check result.exitCode == 0
    check result.output.strip == "5"
    let output = runCapabilityCli(["eval", "($println \"forbidden\")"], root)
    check output.exitCode != 0
    check "UnsupportedCapability" in output.output

  test "no startup source denies application filesystem effects":
    let root = capabilityCliFixture()
    let target = root / "target"
    writeFile(root / "main.gene", "(fn main [] ($fs/write_text " &
      capabilityQuote(target) & " \"forbidden\") 0)")
    let result = runCapabilityCli(["run", root / "main.gene"], root)
    check result.exitCode != 0
    check "MissingCapability" in result.output
    check not fileExists(target)

  test "CLI grants replace defaults and allow only the named root":
    let root = capabilityCliFixture()
    createDir(root / "allowed")
    let good = root / "allowed" / "result"
    let bad = root / "outside"
    writeFile(root / "main.gene", "(fn main [] ($fs/write_text " &
      capabilityQuote(good) & " \"allowed\") (try ($fs/write_text " &
      capabilityQuote(bad) & " \"forbidden\") 9 catch MissingCapability 0))")
    let policy = "[(fs/ReadWrite " & capabilityQuote(root / "allowed") & ")]"
    let result = runCapabilityCli(["run", "--cap", policy, root / "main.gene"], root)
    checkpoint result.output
    check result.exitCode == 0
    check readFile(good) == "allowed"
    check not fileExists(bad)

  test "explicit empty policy overrides a broader environment":
    let root = capabilityCliFixture()
    let source = "(try ($fs/write_text \"output\" \"x\") false catch MissingCapability true)"
    let policy = "[(fs/ReadWrite " & capabilityQuote(root) & ")]"
    let result = runCapabilityCli(["eval", "--cap=[]", source], root, some(policy))
    check result.exitCode == 0
    check result.output.strip == "true"
    check not fileExists(root / "output")

  test "environment policy is selected when CLI policy is absent":
    let root = capabilityCliFixture()
    let policy = "[(fs/Write " & capabilityQuote(root) & ")]"
    let result = runCapabilityCli(["eval", "($fs/write_text \"output\" \"environment\")"], root, some(policy))
    checkpoint result.output
    check result.exitCode == 0
    check readFile(root / "output") == "environment"

  test "capability files keep their own resource base":
    let root = capabilityCliFixture()
    createDir(root / "config")
    createDir(root / "data")
    createDir(root / "elsewhere")
    writeFile(root / "config" / "caps.gene", "[(fs/Write \"../data\")]")
    let target = root / "data" / "result"
    let source = "($fs/write_text " & capabilityQuote(target) & " \"file\")"
    let result = runCapabilityCli(["eval", "--cap-file", root / "config" / "caps.gene", source], root / "elsewhere")
    checkpoint result.output
    check result.exitCode == 0
    check readFile(target) == "file"

  test "duplicate sources and malformed selected input never fall back":
    let root = capabilityCliFixture()
    for args in [
      @["eval", "--cap", "[]", "--capabilities", "[]", "1"],
      @["eval", "--cap", "[]", "--cap-file", "missing", "1"],
      @["eval", "--cap", "[(net/Http ^^optional)]", "1"],
      @["eval", "--cap-file", "missing", "1"]]:
      let result = runCapabilityCli(args, root, some("[net/Http]"))
      check result.exitCode != 0
    let emptyEnvironment = runCapabilityCli(["eval", "1"], root, some(""))
    check emptyEnvironment.exitCode != 0

  test "overridden invalid environment text is not evaluated or parsed":
    let root = capabilityCliFixture()
    let result = runCapabilityCli(["eval", "--capabilities", "[]", "7"], root,
      some("not a capability row"))
    check result.exitCode == 0
    check result.output.strip == "7"

  test "entry source admission does not include sibling imports":
    let root = capabilityCliFixture()
    writeFile(root / "main.gene", "(import [value] ^from \"./helper\") (fn main [] (if (== value 7) 0 9))")
    writeFile(root / "helper.gene", "(var value 7)")
    let denied = runCapabilityCli(["run", root / "main.gene"], root)
    check denied.exitCode != 0
    check "source snapshot" in denied.output
    let allowed = runCapabilityCli(["run", "--source-root", root, root / "main.gene"], root)
    checkpoint allowed.output
    check allowed.exitCode == 0

  test "source admission does not lend file-reading authority or host controls":
    let root = capabilityCliFixture()
    writeFile(root / "main.gene", """
(fn main []
  (var control (try ($runtime/sandbox_transaction) false catch UnsupportedCapability true))
  (var read (try ($fs/read_text "main.gene") false catch MissingCapability true))
  (if control (if read 0 9) 9))
""")
    let result = runCapabilityCli(["run", "--source-root", root, root / "main.gene"], root)
    checkpoint result.output
    check result.exitCode == 0

  test "removed launcher grants are rejected rather than silently merged":
    let root = capabilityCliFixture()
    writeFile(root / "main.gene", "(fn main [] 0)")
    let result = runCapabilityCli(["run", "--allow_read_write_dir", root, root / "main.gene"], root)
    check result.exitCode != 0
    check "obsolete capability flag" in result.output

  test "project execution uses verified artifacts under the empty policy":
    let root = capabilityCliFixture()
    createDir(root / "src")
    writeFile(root / "package.gene", """
{^format 1 ^name "capability/cli" ^version "1.0.0"
 ^applications [(application "main" ^entry "src/main.gene")]}
""")
    writeFile(root / "src" / "main.gene", "(fn main [] 0)")
    for iteration in 0..1:
      let result = runCapabilityCli(["run", "--package-root", root, "main"], root)
      checkpoint result.output
      check result.exitCode == 0

  test "REPL uses the same empty policy and retains private host output":
    let root = capabilityCliFixture()
    let result = runCapabilityCli(["repl", "--cap", "[]"], root,
      input = "(+ 4 5)\n:quit\n")
    check result.exitCode == 0
    check "9" in result.output

  test "test discovery and reporting are private host work under an empty policy":
    let root = capabilityCliFixture()
    let path = root / "pure_spec.gene"
    writeFile(path, """
(import $test [describe it])
(describe "pure" (it "computes" [] ($assert (== (+ 1 2) 3))))
""")
    let result = runCapabilityCli(["test", path, "--cap", "[]"], root)
    checkpoint result.output
    check result.exitCode == 0
    check "1 passed" in result.output

  test "a pre-existing test callback retains its empty registration bound":
    let root = capabilityCliFixture()
    let path = root / "bound_spec.gene"
    let target = root / "forbidden"
    writeFile(path, "(import $test [describe])\n" &
      "(fn effect [] ($fs/write_text " & capabilityQuote(target) & " \"forbidden\"))\n" &
      "(describe \"bound\" (with_capabilities [] " &
      "($test/register_example \"callback\" [] effect void)))")
    let policy = "[(fs/Write " & capabilityQuote(root) & ")]"
    let result = runCapabilityCli(["test", path, "--cap", policy], root)
    check result.exitCode != 0
    check not fileExists(target)
    check "1 errors" in result.output
