import gene/[compiler, types, vm, printer]
import std/[os, strutils, unittest]

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

  test "bind module value with ^as":
    writeModule("math.gene", "(var pi 3) (fn add [a b] (+ a b))")
    check runProgram("(import from \"./math\" ^as m) m/pi").print() == "3"
    check runProgram("(import from \"./math\" ^as m) (m/add 1 1)").print() == "2"

  test "module reflection exposes normalized file path":
    writeModule("math.gene", "(var pi 3)")
    let expected = normalizedPath(absolutePath("math.gene", modDir))
    check runProgram("(import from \"./math\" ^as m) (m ~ Module/path)").strVal ==
      expected

  test "imported module roots expose declaration streams":
    writeModule("decls.gene", "(var exported 7)")
    check runProgram("(import from \"./decls\" ^as m) " &
      "(var ds (filter (declarations m) (fn [d] (= d/name \"exported\")))) " &
      "(ds ~ Stream/next)").print() ==
      "(Declaration ^name \"exported\" ^kind \"Int\" ^value 7)"
    check runProgram("(import from \"./decls\" ^as m) " &
      "(var ds (filter (m ~ Module/declarations) (fn [d] (= d/name \"exported\")))) " &
      "(ds ~ Stream/next)").print() ==
      "(Declaration ^name \"exported\" ^kind \"Int\" ^value 7)"

  test "file modules receive a this-mod binding":
    writeModule("self.gene",
      "(var x 9) " &
      "(var ds (filter (declarations this-mod) (fn [d] (= d/name \"x\")))) " &
      "(var decl (ds ~ Stream/next)) " &
      "(var seen decl/value)")
    check runProgram("(import [seen] from \"./self\") seen").print() == "9"

  test "this-mod exposes module reflection helpers":
    writeModule("selfpath.gene",
      "(var marker 42) " &
      "(var root (this-mod ~ Module/root_namespace)) " &
      "(var reflected [(this-mod ~ Module/name) " &
      "                (this-mod ~ Module/path) " &
      "                (= root this-mod) " &
      "                (/marker root)])")
    let reflected = runProgram("(import [reflected] from \"./selfpath\") reflected")
    check reflected.listItems[0].strVal == "selfpath"
    check reflected.listItems[1].strVal ==
      normalizedPath(absolutePath("selfpath.gene", modDir))
    check reflected.listItems[2].boolVal == false
    check reflected.listItems[3].intVal == 42

  test "mod metadata persists on the module value":
    writeModule("meta.gene",
      "(mod renamed @doc \"module docs\") " &
      "(var reflected [(this-mod ~ Module/name) " &
      "                (/doc (this-mod ~ Module/meta))])")
    check runProgram("(import [reflected] from \"./meta\") reflected").print() ==
      "[\"renamed\" \"module docs\"]"

  test "Module annotations accept module values":
    writeModule("math.gene", "(var pi 3)")
    check runProgram("(import from \"./math\" ^as m) " &
      "(fn module_path [m : Module] (m ~ Module/path)) (module_path m)").strVal ==
      normalizedPath(absolutePath("math.gene", modDir))
    expect GeneError:
      discard runProgram("(fn module_id [m : Module] m) (module_id [1])")
    expect GeneError:
      discard runProgram("(ns local (var x 1)) " &
        "(fn module_id [m : Module] m) (module_id local)")

  test "a module is loaded once (cache returns the same module value)":
    writeModule("m.gene", "(var v 1)")
    check runProgram("(import from \"./m\" ^as a) (import from \"./m\" ^as b) (= a b)").print() == "true"

  test "applications isolate module cache and package roots":
    let dirA = modDir / "app-a"
    let dirB = modDir / "app-b"
    createDir(dirA)
    createDir(dirB)
    writeFile(dirA / "lib.gene", "(var value \"A\")")
    writeFile(dirB / "lib.gene", "(var value \"B\")")
    let appA = newApplication(dirA)
    let appB = newApplication(dirB)
    discard initModuleContext(dirB)
    let src = "(import [value] from \"./lib\") value"
    check run(compileSource(src), newGlobalScope(appA)).print() == "\"A\""
    check run(compileSource(src), newGlobalScope(appB)).print() == "\"B\""
    writeFile(dirA / "lib.gene", "(var value \"changed\")")
    check run(compileSource(src), newGlobalScope(appA)).print() == "\"A\""

  test "transitive imports resolve relative to each module":
    writeModule("base.gene", "(fn one [] 1)")
    writeModule("mid.gene", "(import [one] from \"./base\") (fn two [] (+ (one) (one)))")
    check runProgram("(import [two] from \"./mid\") (two)").print() == "2"

  test "imported modules make extension impls visible":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson User (message to_json [self] : Str self/name))")
    check runProgram("(import [ToJson, to_json] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(import from \"./json_ext\" ^as ext) " &
      "(to_json (User ^name \"Ada\"))").print() == "\"Ada\""

  test "reimporting the same extension impl is idempotent":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson User (message to_json [self] : Str self/name))")
    check runProgram("(import [ToJson, to_json] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(import from \"./json_ext\" ^as ext1) " &
      "(import from \"./json_ext\" ^as ext2) " &
      "(to_json (User ^name \"Ada\"))").print() == "\"Ada\""

  test "conflicting imported extension impls are rejected":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext_a.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson User (message to_json [self] : Str self/name))")
    writeModule("json_ext_b.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson User (message to_json [self] : Str \"other\"))")
    expect GeneError:
      discard runProgram("(import [ToJson] from \"./json\") " &
        "(import [User] from \"./model\") " &
        "(import from \"./json_ext_a\" ^as a) " &
        "(import from \"./json_ext_b\" ^as b)")

  test "package-root-relative paths (/x and bare x)":
    writeModule("math.gene", "(var pi 3) (fn add [a b] (+ a b))")
    check runProgram("(import [pi] from \"/math\") pi").print() == "3"
    check runProgram("(import [add] from \"math\") (add 1 2)").print() == "3"

  test "module paths cannot escape the package root":
    let outside = modDir & "_outside.gene"
    writeFile(outside, "(var secret 99)")
    try:
      discard runProgram("(import [secret] from \"../gene_module_tests_outside\") secret")
      fail()
    except GeneError as e:
      check e.msg.contains("module path escapes package root")
    finally:
      removeFile(outside)

  test "missing export raises":
    writeModule("math.gene", "(var pi 3)")
    expect GeneError: discard runProgram("(import [nope] from \"./math\")")

  test "selected imports reject duplicate local bindings":
    writeModule("math.gene", "(var pi 3) (var tau 6)")
    expect GeneError:
      discard runProgram("(import [pi] from \"./math\") (var pi 4)")
    expect GeneError:
      discard runProgram("(import [pi : n, tau : n] from \"./math\")")

  test "missing module raises":
    expect GeneError: discard runProgram("(import [x] from \"./does-not-exist\")")

  test "import cycle is rejected":
    writeModule("a.gene", "(import from \"./b\" ^as b) (var x 1)")
    writeModule("b.gene", "(import from \"./a\" ^as a) (var y 2)")
    expect GeneError: discard runProgram("(import from \"./a\" ^as a) a/x")

suite "modules — built-in identity and scope hygiene":
  setup:
    removeDir(modDir)
    createDir(modDir)

  test "checked errors cross module boundaries (shared Error identity)":
    # `Boom` implements module A's `Error`; the importer checks `^errors [Boom]`
    # against its own built-in `Error`. These must be the same protocol value.
    writeModule("erra.gene",
      "(type Boom ^props {^message Str} ^impl [Error]) " &
      "(impl Error Boom) " &
      "(fn boom ^errors [Boom] [] (fail (Boom ^message \"x\")))")
    check runProgram("(import [Boom, boom] from \"./erra\") " &
      "(fn f ^errors [Boom] [] (boom)) " &
      "(try (f) catch (Boom ^message m) m)").print() == "\"x\""

  test "module declarations do not include built-ins":
    writeModule("decls2.gene", "(var only-me 1)")
    # Filtering the module's declarations for a built-in name finds nothing,
    # because built-ins live in the shared parent scope, not the module root.
    check runProgram("(import from \"./decls2\" ^as m) " &
      "(var ds (filter (declarations m) (fn [d] (= d/name \"map\")))) " &
      "(ds ~ Stream/has_next)").print() == "false"
    check runProgram("(import from \"./decls2\" ^as m) " &
      "(var ds (filter (declarations m) (fn [d] (= d/name \"this-mod\")))) " &
      "(ds ~ Stream/has_next)").print() == "false"

  test "selected imports cannot pull built-ins out of a module":
    writeModule("decls2.gene", "(var only-me 1)")
    expect GeneError:
      discard runProgram("(import [map] from \"./decls2\")")

  test "selected imports cannot pull this-mod out of a module":
    writeModule("decls3.gene", "(var only-me 1)")
    expect GeneError:
      discard runProgram("(import [this-mod] from \"./decls3\")")

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

  test "namespace imports make extension impls visible":
    initModuleContext(getTempDir())
    check run(compileSource(
      "(protocol Show (message show [self] : Str)) " &
      "(type T ^props {}) " &
      "(ns ext (impl Show T (message show [self] : Str \"ok\"))) " &
      "(import ext ^as imported) " &
      "(show (T))"),
      newGlobalScope()).print() == "\"ok\""

  test "mod header runs its body":
    initModuleContext(getTempDir())
    check run(compileSource("(mod demo @doc \"hi\") (var x 7) x"),
      newGlobalScope()).print() == "7"

  test "mod declarations follow MVP placement rules":
    expect GeneError:
      discard compileSource("(mod)")
    expect GeneError:
      discard compileSource("(mod \"demo\")")
    expect GeneError:
      discard compileSource("(mod a) (mod b)")
    expect GeneError:
      discard compileSource("(do (mod nested))")
    check run(compileSource("(quote (mod data))"),
      newGlobalScope()).print() == "(mod data)"

  test "explicit mod names the current module root":
    let scope = newGlobalScope()
    discard bindThisModule(scope, "implicit")
    check run(compileSource("(mod explicit) this-mod"), scope).print() ==
      "(mod explicit)"

suite "modules — Env imports":
  setup:
    removeDir(modDir)
    createDir(modDir)

  test "eval env can import a module path string":
    writeModule("envlib.gene", "(var answer 42)")
    check runProgram("(var e (env ^imports [\"./envlib\"])) " &
      "(eval (quote answer) ^in e)").print() == "42"

  test "eval env module imports make impls visible":
    writeModule("showlib.gene",
      "(protocol Show (message show [self] : Str)) " &
      "(type T ^props {}) " &
      "(impl Show T (message show [self] : Str \"ok\"))")
    check runProgram("(var e (env ^imports [\"./showlib\"])) " &
      "(eval (quote (show (T))) ^in e)").print() == "\"ok\""
