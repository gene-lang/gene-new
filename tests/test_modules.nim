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
      "(var ds (filter (declarations m) (fn [d] (== d/name \"exported\")))) " &
      "(ds ~ Stream/next)").print() ==
      "(Declaration ^name \"exported\" ^kind \"Int\" ^value 7)"

  test "runtime declarations exclude compile-time macros":
    writeModule("macro_decls.gene",
      "(macro twice [x] `(+ %x %x)) (var runtime-value 7)")
    check runProgram("(import from \"./macro_decls\" ^as m) " &
      "(var macros (filter (declarations m) (fn [d] (== d/name \"twice\")))) " &
      "(var values (filter (declarations m) " &
      "  (fn [d] (== d/name \"runtime-value\")))) " &
      "(var decl (values ~ Stream/next)) " &
      "[(macros ~ Stream/has_next) decl/value]").print() ==
      "[false 7]"

  test "file modules receive a this_mod binding":
    writeModule("self.gene",
      "(var x 9) " &
      "(var ds (filter (declarations this_mod) (fn [d] (== d/name \"x\")))) " &
      "(var decl (ds ~ Stream/next)) " &
      "(var seen decl/value)")
    check runProgram("(import [seen] from \"./self\") seen").print() == "9"

  test "this_mod exposes module reflection helpers":
    writeModule("selfpath.gene",
      "(var marker 42) " &
      "(var root (this_mod ~ Module/root_namespace)) " &
      "(var reflected [(this_mod ~ Module/name) " &
      "                (this_mod ~ Module/path) " &
      "                (== root this_mod) " &
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
      "(var reflected [(this_mod ~ Module/name) " &
      "                (/doc (this_mod ~ Module/meta))])")
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
    check runProgram("(import from \"./m\" ^as a) (import from \"./m\" ^as b) (== a b)").print() == "true"

  test "entry file modules load through the application cache":
    let entryPath = modDir / "entry.gene"
    writeFile(entryPath, "(var value 11) (fn main [] value)")
    let app = newApplication(modDir)
    let entryModule = app.loadFileModule(entryPath)
    let imported = run(compileSource("(import from \"./entry\" ^as e) e"),
                       newGlobalScope(app))
    check imported.bits == entryModule.bits
    var mainBinding: Value
    check entryModule.moduleRootNamespace.nsScope.lookupOptional("main", mainBinding)
    check mainBinding.call().print() == "11"

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

  test "ordinary imports do not import scoped extension impls":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson for User (message to_json [self] : Str self/name)) " &
      "(fn local_json [user] (user ~ to_json))")
    check runProgram("(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(import [local_json] from \"./json_ext\") " &
      "(local_json (User ^name \"Ada\"))").print() == "\"Ada\""
    expect GeneError:
      discard runProgram("(import [ToJson] from \"./json\") " &
        "(import [User] from \"./model\") " &
        "(import from \"./json_ext\" ^as ext) " &
        "((User ^name \"Ada\") ~ to_json)")

  test "import_impl imports one exported scoped pair idempotently":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson for User ^export true " &
      "  (message to_json [self] : Str self/name))")
    check runProgram("(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(import_impl ToJson for User from \"./json_ext\") " &
      "(import_impl ToJson for User from \"./json_ext\") " &
      "((User ^name \"Ada\") ~ to_json)").print() == "\"Ada\""

  test "only exported scoped impls are importable":
    writeModule("export_base.gene",
      "(protocol P (message value [self])) (type T ^props {})")
    writeModule("canonical_export.gene",
      "(protocol P (message value [self])) (type T ^props {}) " &
      "(impl P for T ^export true (message value [self] 1))")
    expect GeneError:
      discard runProgram("(import from \"./canonical_export\" ^as bad)")

    writeModule("private_ext.gene",
      "(import [P T] from \"./export_base\") " &
      "(impl P for T (message value [self] 1))")
    expect GeneError:
      discard runProgram("(import [P T] from \"./export_base\") " &
        "(import_impl P for T from \"./private_ext\")")

    writeModule("overlay_export.gene",
      "(import [P T] from \"./export_base\") " &
      "(fn install [] " &
      "  (impl P for T ^export true (message value [self] 1))) " &
      "(install)")
    expect GeneError:
      discard runProgram("(import from \"./overlay_export\" ^as bad)")

  test "protocol-typed boundaries use their declaration module":
    writeModule("typed_base.gene",
      "(protocol Named (message name [self] : Str)) " &
      "(type User ^props {^name Str})")
    writeModule("typed_ext.gene",
      "(import [Named User] from \"./typed_base\") " &
      "(impl Named for User ^export true " &
      "  (message name [self] : Str self/name))")
    writeModule("typed_lib.gene",
      "(import [Named] from \"./typed_base\") " &
      "(fn accept [x : Named] true) " &
      "(fn count [xs : (List Named)] (xs ~ size)) " &
      "(type Box ^props {^item Named})")
    check runProgram(
      "(import [Named User] from \"./typed_base\") " &
      "(import [accept count Box] from \"./typed_lib\") " &
      "(import_impl Named for User from \"./typed_ext\") " &
      "(fn local_accept [x : Named] true) " &
      "(type LocalBox ^props {^item Named}) " &
      "(var u (User ^name \"Ada\")) " &
      "(var local_box (LocalBox ^item u)) " &
      "[(local_accept u) local_box/item/name " &
      " (try (accept u) catch _ false) " &
      " (try (count [u]) catch _ false) " &
      " (try (Box ^item u) catch _ false)]").print() ==
      "[true \"Ada\" false false false]"

  test "conflicting explicitly imported scoped impls are rejected":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext_a.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson for User ^export true " &
      "  (message to_json [self] : Str self/name))")
    writeModule("json_ext_b.gene",
      "(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(impl ToJson for User ^export true " &
      "  (message to_json [self] : Str \"other\"))")
    expect GeneError:
      discard runProgram("(import [ToJson] from \"./json\") " &
        "(import [User] from \"./model\") " &
        "(import_impl ToJson for User from \"./json_ext_a\") " &
        "(import_impl ToJson for User from \"./json_ext_b\")")

  test "reload updates exact scoped imports atomically":
    writeModule("reload_base.gene",
      "(protocol Render (message render [self] : Str)) " &
      "(type Item ^props {})")
    writeModule("reload_ext.gene",
      "(import [Render Item] from \"./reload_base\") " &
      "(impl Render for Item ^export true " &
      "  (message render [self] : Str \"one\"))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource(
      "(import [Render Item] from \"./reload_base\") " &
      "(import_impl Render for Item from \"./reload_ext\")"), scope)
    check run(compileSource("((Item) ~ render)"), scope).print() == "\"one\""
    let before = app.implActivationEpoch
    writeModule("reload_ext.gene",
      "(import [Render Item] from \"./reload_base\") " &
      "(impl Render for Item ^export true " &
      "  (message render [self] : Str \"two\"))")
    discard app.reloadFileModule(modDir / "reload_ext.gene")
    check app.implActivationEpoch == before + 1
    check run(compileSource("((Item) ~ render)"), scope).print() == "\"two\""

    let stableEpoch = app.implActivationEpoch
    writeModule("reload_ext.gene",
      "(import [Render Item] from \"./reload_base\") (var removed true)")
    expect GeneError:
      discard app.reloadFileModule(modDir / "reload_ext.gene")
    check app.implActivationEpoch == stableEpoch
    check run(compileSource("((Item) ~ render)"), scope).print() == "\"two\""

  test "failed module activation does not publish earlier staged impls":
    writeModule("base.gene",
      "(protocol P (message value [self] : Str)) " &
      "(type A ^props {}) (type B ^props {}) " &
      "(impl P for B (message value [self] : Str \"existing\"))")
    writeModule("ext_bad.gene",
      "(import [P A B] from \"./base\") " &
      "(impl P for A (message value [self] : Str \"staged\")) " &
      "(impl P for B (message value [self] : Str \"conflict\"))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource(
      "(import [P A B] from \"./base\")"), scope)
    expect GeneError:
      discard run(compileSource("(import from \"./ext_bad\" ^as bad)"), scope)
    expect GeneError:
      discard run(compileSource("((A) ~ P/value)"), scope)
    check run(compileSource("((B) ~ P/value)"), scope).print() ==
      "\"existing\""

  test "later canonical applicability can make a fixed name ambiguous":
    writeModule("late_base.gene",
      "(protocol A (message render [self] : Str)) " &
      "(protocol B (message render [self] : Str)) " &
      "(type T ^props {}) " &
      "(impl A for T (message render [self] : Str \"a\"))")
    writeModule("late_q.gene",
      "(import [B T] from \"./late_base\") " &
      "(protocol Q ^inherit [B]) " &
      "(impl Q for T (message render [self] : Str \"b\"))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource(
      "(import [A B T] from \"./late_base\") " &
      "(fn send_render [x] (x ~ render))"), scope)
    check run(compileSource("(send_render (T))"), scope).print() == "\"a\""
    discard run(compileSource("(import from \"./late_q\" ^as q)"), scope)
    expect GeneError:
      discard run(compileSource("(send_render (T))"), scope)

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

  test "conditional imports contribute only on must paths":
    writeModule("conditional_protocol.gene",
      "(protocol Render (message render [self] : Str)) " &
      "(type T ^props {}) " &
      "(impl Render for T (message render [self] : Str \"ok\"))")
    check runProgram("(import [T] from \"./conditional_protocol\") " &
      "(if_yes true " &
      "  (import [Render] from \"./conditional_protocol\") " &
      "  ((T) ~ render))").print() == "\"ok\""
    expect GeneError:
      discard runProgram("(import [T] from \"./conditional_protocol\") " &
        "(if true (import [Render] from \"./conditional_protocol\")) " &
        "((T) ~ render)")
    check runProgram("(import [T] from \"./conditional_protocol\") " &
      "(if true (import [Render] from \"./conditional_protocol\")) " &
      "((T) ~ Render/render)").print() == "\"ok\""
    check runProgram("(import [T] from \"./conditional_protocol\") " &
      "(if false " &
      "  (import [Render] from \"./conditional_protocol\") " &
      "  (import [Render] from \"./conditional_protocol\")) " &
      "((T) ~ render)").print() == "\"ok\""

  test "module aliases and re-exports contribute protocol interfaces":
    writeModule("interface_base.gene",
      "(protocol Render (message render [self] : Str)) " &
      "(type T ^props {}) " &
      "(impl Render for T (message render [self] : Str \"interface\"))")
    writeModule("interface_mid.gene",
      "(import [Render T] from \"./interface_base\")")
    check runProgram("(import from \"./interface_base\" ^as base) " &
      "((base/T) ~ render)").print() == "\"interface\""
    check runProgram("(import [Render T] from \"./interface_mid\") " &
      "((T) ~ render)").print() == "\"interface\""

  test "caught import failures do not establish protocol candidates":
    writeModule("candidate_type.gene", "(type T ^props {})")
    var message = ""
    try:
      discard runProgram("(import [T] from \"./candidate_type\") " &
        "(try (import [Render] from \"./missing_protocol\") catch _ nil) " &
        "((T) ~ render)")
    except GeneError as error:
      message = error.msg
    check message.contains("undefined symbol: render")
    check not message.contains("uninitialized protocol candidate")

  test "runtime import cycles have a runtime-phase diagnostic":
    writeModule("a.gene", "(import from \"./b\" ^as b) (var x 1)")
    writeModule("b.gene", "(import from \"./a\" ^as a) (var y 2)")
    var message = ""
    try:
      discard runProgram("(import from \"./a\" ^as a) a/x")
    except GeneError as e:
      message = e.msg
    check message.contains("runtime module initialization cycle")

suite "modules — built-in identity and scope hygiene":
  setup:
    removeDir(modDir)
    createDir(modDir)

  test "checked errors cross module boundaries (shared Error identity)":
    # `Boom` implements module A's `Error`; the importer checks `^errors [Boom]`
    # against its own built-in `Error`. These must be the same protocol value.
    writeModule("erra.gene",
      "(type Boom ^props {^message Str} ^impl [Error]) " &
      "(impl Error for Boom) " &
      "(fn boom ^errors [Boom] [] (fail (Boom ^message \"x\")))")
    check runProgram("(import [Boom, boom] from \"./erra\") " &
      "(fn f ^errors [Boom] [] (boom)) " &
      "(try (f) catch (Boom ^message m) m)").print() == "\"x\""

  test "module declarations do not include built-ins":
    writeModule("decls2.gene", "(var only-me 1)")
    # Filtering the module's declarations for a built-in name finds nothing,
    # because built-ins live in the shared parent scope, not the module root.
    check runProgram("(import from \"./decls2\" ^as m) " &
      "(var ds (filter (declarations m) (fn [d] (== d/name \"map\")))) " &
      "(ds ~ Stream/has_next)").print() == "false"
    check runProgram("(import from \"./decls2\" ^as m) " &
      "(var ds (filter (declarations m) (fn [d] (== d/name \"this_mod\")))) " &
      "(ds ~ Stream/has_next)").print() == "false"

  test "selected imports cannot pull built-ins out of a module":
    writeModule("decls2.gene", "(var only-me 1)")
    expect GeneError:
      discard runProgram("(import [map] from \"./decls2\")")

  test "selected imports cannot pull this_mod out of a module":
    writeModule("decls3.gene", "(var only-me 1)")
    expect GeneError:
      discard runProgram("(import [this_mod] from \"./decls3\")")

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

  test "co-located namespace impls are canonical":
    initModuleContext(getTempDir())
    check run(compileSource(
      "(protocol Show (message show [self] : Str)) " &
      "(type T ^props {}) " &
      "(ns ext (impl Show for T (message show [self] : Str \"ok\"))) " &
      "((T) ~ show)"),
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
    check run(compileSource("(mod explicit) this_mod"), scope).print() ==
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
      "(impl Show for T (message show [self] : Str \"ok\"))")
    check runProgram("(var e (env ^imports [\"./showlib\"])) " &
      "(eval (quote ((T) ~ show)) ^in e)").print() == "\"ok\""

suite "modules — impl activation across module paths":
  setup:
    removeDir(modDir)
    createDir(modDir)

  test "identical impls re-imported through two module paths activate once":
    ## Regression: module activation (activateStagedImpls) used the strict
    ## protocol+receiver duplicate check, so importing a native namespace
    ## carrying impls (db/sqlite) BEFORE a local module that also imports it
    ## raised "duplicate visible impl" — while the reverse order worked.
    ## Identical registrations reached through different module paths must
    ## activate once, in either order; the shared common-module shape must
    ## work too.
    writeModule("shared.gene",
      "(protocol Show (message show [self] : Str)) " &
      "(type T ^props {}) " &
      "(impl Show for T (message show [self] : Str \"shared\"))")
    writeModule("uses_shared.gene",
      "(import [T] from \"./shared\") (fn marker [] 1)")
    # shared-first, then the local module that also imports it
    check runProgram("(import [Show T] from \"./shared\") " &
      "(import [marker] from \"./uses_shared\") " &
      "[((T) ~ show) (marker)]").print() == "[\"shared\" 1]"
    # local-module-first (the previously working order must stay working)
    check runProgram("(import [marker] from \"./uses_shared\") " &
      "(import [Show T] from \"./shared\") " &
      "[((T) ~ show) (marker)]").print() == "[\"shared\" 1]"

  test "conflicting impls for one protocol and receiver still raise":
    writeModule("conflict_shared.gene",
      "(protocol Show2 (message show2 [self] : Str)) " &
      "(type U ^props {})")
    writeModule("impl_one.gene",
      "(import [Show2 U] from \"./conflict_shared\") " &
      "(impl Show2 for U ^export true " &
      "  (message show2 [self] : Str \"one\"))")
    writeModule("impl_two.gene",
      "(import [Show2 U] from \"./conflict_shared\") " &
      "(impl Show2 for U ^export true " &
      "  (message show2 [self] : Str \"two\"))")
    expect GeneError:
      discard runProgram("(import [Show2 U] from \"./conflict_shared\") " &
        "(import_impl Show2 for U from \"./impl_one\") " &
        "(import_impl Show2 for U from \"./impl_two\") nil")
