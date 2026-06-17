import gene/[compiler, types, vm, printer]
import std/[os, unittest]

let modDir = getTempDir() / "gene_module_tests"

proc writeModule(name, src: string) =
  writeFile(modDir / name, src)

proc runProgram(src: string): Value =
  ## Run a program whose relative imports resolve from `modDir`.
  initModuleContext(modDir)
  run(compileSource(src), newGlobalScope())

suite "modules — file imports":
  setup:
    removeDir(modDir)
    createDir(modDir)

  test "import selected bindings":
    writeModule("math.gene", "(fn add [a b] (+ a b))\n(var pi 3)")
    check runProgram("(import [add] from \"./math\") (add 2 3)").print() == "5"

  test "import a single binding":
    writeModule("math.gene", "(var pi 3)")
    check runProgram("(import pi from \"./math\") pi").print() == "3"

  test "aliased selection (name : local)":
    writeModule("math.gene", "(fn sub [a b] (- a b))")
    check runProgram("(import [sub : minus] from \"./math\") (minus 10 4)").print() == "6"

  test "bind module root namespace with ^as":
    writeModule("math.gene", "(var pi 3) (fn add [a b] (+ a b))")
    check runProgram("(import from \"./math\" ^as m) m/pi").print() == "3"
    check runProgram("(import from \"./math\" ^as m) (m/add 1 1)").print() == "2"

  test "imported module roots expose declaration streams":
    writeModule("decls.gene", "(var exported 7)")
    check runProgram("(import from \"./decls\" ^as m) " &
      "(var ds (filter (declarations m) (fn [d] (= d/name \"exported\")))) " &
      "(ds ~ Stream/next)").print() ==
      "(Declaration ^name \"exported\" ^kind \"Int\" ^value 7)"

  test "a module is loaded once (cache returns the same namespace)":
    writeModule("m.gene", "(var v 1)")
    check runProgram("(import from \"./m\" ^as a) (import from \"./m\" ^as b) (= a b)").print() == "true"

  test "transitive imports resolve relative to each module":
    writeModule("base.gene", "(fn one [] 1)")
    writeModule("mid.gene", "(import [one] from \"./base\") (fn two [] (+ (one) (one)))")
    check runProgram("(import [two] from \"./mid\") (two)").print() == "2"

  test "package-root-relative paths (/x and bare x)":
    writeModule("math.gene", "(var pi 3) (fn add [a b] (+ a b))")
    check runProgram("(import [pi] from \"/math\") pi").print() == "3"
    check runProgram("(import [add] from \"math\") (add 1 2)").print() == "3"

  test "missing export raises":
    writeModule("math.gene", "(var pi 3)")
    expect GeneError: discard runProgram("(import [nope] from \"./math\")")

  test "missing module raises":
    expect GeneError: discard runProgram("(import [x] from \"./does-not-exist\")")

  test "import cycle is rejected":
    writeModule("a.gene", "(import from \"./b\" ^as b) (var x 1)")
    writeModule("b.gene", "(import from \"./a\" ^as a) (var y 2)")
    expect GeneError: discard runProgram("(import from \"./a\" ^as a) a/x")

suite "modules — namespace-path imports and mod":
  test "import selected bindings from an in-file namespace":
    initModuleContext(getTempDir())
    check run(compileSource(
      "(ns m (var a 1) (fn double [x] (* x 2))) (import m [a, double]) (double a)"),
      newGlobalScope()).print() == "2"

  test "bind an in-file namespace with ^as":
    initModuleContext(getTempDir())
    check run(compileSource("(ns m (var a 5)) (import m ^as mm) mm/a"),
      newGlobalScope()).print() == "5"

  test "mod header runs its body":
    initModuleContext(getTempDir())
    check run(compileSource("(mod demo @doc \"hi\") (var x 7) x"),
      newGlobalScope()).print() == "7"
