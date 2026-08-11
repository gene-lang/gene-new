import gene/[compiler, gir, types, vm, printer]
import std/[os, osproc, strutils, unittest]

let modDir = getTempDir() / "gene_module_tests"

proc writeModule(name, src: string) =
  writeFile(modDir / name, src)

proc runProgram(src: string): Value =
  ## Run a program whose relative imports resolve from `modDir`.
  initModuleContext(modDir)
  run(compileSource(src), newGlobalScope())

proc runProgramInOwnApp(src: string): Value =
  ## Run with a **per-run** Application, the way `gene run` does — the program's
  ## app is deliberately *not* the process-global default.
  ##
  ## `runProgram` makes those the same object, which hides a whole class of
  ## defect: a builtin that reaches for the global instead of the caller's app
  ## looks correct there and is wrong in every real run. That is exactly how
  ## `$runtime/load_sandboxed` shipped loading a mod into a second, empty
  ## Application.
  initModuleContext(getTempDir())
  run(compileSource(src), newGlobalScope(newApplication(modDir)))

proc loadSandboxed(dir, entry, grants: string, shared = "[]"): string =
  ## A `$runtime/load_sandboxed` call, as source. The directory and the entry are
  ## separate arguments: `dir` is the sandbox boundary and the host supplies it,
  ## `entry` is what a manifest names and resolves inside it (§D5.2). `shared` is
  ## the only way out of `dir`, and it defaults to nothing — a sandbox that shares
  ## nothing is the one every case below should have to opt out of.
  "($runtime/load_sandboxed \"" & dir.replace("\\", "/") & "\" \"" & entry &
    "\" " & grants & " " & shared & ")"

proc checkCCompiles(source, label: string) =
  let path = modDir / (label & ".c")
  writeFile(path, source)
  let checked = execCmdEx(
    quoteShell(getEnv("CC", "cc")) & " -std=c11 -fsyntax-only " &
      quoteShell(path))
  checkpoint checked.output
  check checked.exitCode == 0

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

  test "typed-native layout metadata crosses a selected module import":
    writeModule("native_layout.gene",
      "(ffi/struct CTimespec " &
      "  ^fields [[tv_sec C/Long] [tv_nsec C/Long]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^mutable true})")
    writeModule("native_layout_user.gene",
      "(import [Timespec] from \"./native_layout\") " &
      "(fn seconds [t : Timespec] : I64 t/tv_sec)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_layout_user.gene")
      .emitExperimentalC()
    check "typedef struct CTimespec" in c
    check "int64_t gene_native_seconds(CTimespec * t)" in c
    check "return t->tv_sec;" in c

  test "typed-native wrapper adapters retain imported ownership metadata":
    writeModule("native_wrapper.gene",
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"timespec_free\" ^copy \"timespec_copy\"})")
    writeModule("native_wrapper_user.gene",
      "(import [Timespec] from \"./native_wrapper\") " &
      "(fn clone_timespec ^native_entry {^t borrow ^result copy} " &
      "  [t : Timespec] : Timespec t)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_wrapper_user.gene")
      .emitExperimentalC()
    let typeIdentity = normalizedPath(absolutePath(
      modDir / "native_wrapper.gene")) & "::Timespec"
    let abiIdentity = normalizedPath(absolutePath(
      modDir / "native_wrapper.gene")) & "::CTimespec"
    check ("\"" & typeIdentity & "\"") in c
    check ("\"" & abiIdentity & "\"") in c
    check "timespec_copy((const CTimespec *)value)" in c
    check "timespec_free((CTimespec *)value)" in c
    checkCCompiles(c, "native_wrapper_adapter_import")

  test "typed-native metadata follows a module alias annotation":
    writeModule("native_alias_layout.gene",
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec ^native {^abi CTimespec ^lifecycle manual})")
    writeModule("native_alias_user.gene",
      "(import * : native from \"./native_alias_layout\") " &
      "(fn seconds [t : native/Timespec] : I64 t/tv_sec)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_alias_user.gene")
      .emitExperimentalC()
    check "gene_native_seconds" in c
    check "return t->tv_sec;" in c
    checkCCompiles(c, "native_alias_import")

  test "an imported layout can back a re-exported native Type":
    writeModule("native_abi_only.gene",
      "(ffi/struct CRecord ^fields [[value C/Int64]])")
    writeModule("native_type_only.gene",
      "(import [CRecord] from \"./native_abi_only\") " &
      "(type Record ^native {^abi CRecord ^lifecycle manual})")
    writeModule("native_type_user.gene",
      "(import [Record] from \"./native_type_only\") " &
      "(fn value [p : Record] : I64 p/value)")
    let chunk = newApplication(modDir)
      .compileFileModule(modDir / "native_type_user.gene")
    let dependency = normalizedPath(absolutePath(
      modDir / "native_abi_only.gene")) & "::CRecord"
    check dependency in chunk.ffiStructDependencies
    check dependency in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "gene_native_value" in c
    check "return p->value;" in c
    checkCCompiles(c, "native_imported_abi")

  test "typed-native metadata survives an explicit re-export":
    writeModule("native_reexport_base.gene",
      "(ffi/struct CRecord ^fields [[value C/Int64]]) " &
      "(type Record ^native {^abi CRecord ^lifecycle manual})")
    writeModule("native_reexport_mid.gene",
      "(import [Record] from \"./native_reexport_base\" ^export true)")
    writeModule("native_reexport_user.gene",
      "(import [Record] from \"./native_reexport_mid\") " &
      "(fn value [p : Record] : I64 p/value)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_reexport_user.gene")
      .emitExperimentalC()
    check "gene_native_value" in c
    check "return p->value;" in c
    checkCCompiles(c, "native_type_reexport")

  test "typed-native ABI changes invalidate the module compile interface":
    writeModule("native_reload.gene",
      "(ffi/struct CRecord ^fields [[value C/Long]]) " &
      "(type Record ^native {^abi CRecord ^lifecycle manual})")
    let app = newApplication(modDir)
    discard app.loadFileModule(modDir / "native_reload.gene")
    writeModule("native_reload.gene",
      "(ffi/struct CRecord ^fields [[value C/Double]]) " &
      "(type Record ^native {^abi CRecord ^lifecycle manual})")
    expect GeneError:
      discard app.reloadFileModule(modDir / "native_reload.gene")

  test "typed-native codegen keeps same-named imported layouts distinct":
    writeModule("native_left.gene",
      "(ffi/struct CRecord ^fields [[left C/Int64]]) " &
      "(type LeftRecord ^native {^abi CRecord ^lifecycle manual})")
    writeModule("native_right.gene",
      "(ffi/struct CRecord ^fields [[right C/Double]]) " &
      "(type RightRecord ^native {^abi CRecord ^lifecycle manual})")
    writeModule("native_collision_user.gene",
      "(import [LeftRecord] from \"./native_left\") " &
      "(import [RightRecord] from \"./native_right\") " &
      "(fn left_value [p : LeftRecord] : I64 p/left) " &
      "(fn right_value [p : RightRecord] : F64 p/right)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_collision_user.gene")
      .emitExperimentalC()
    check "return p->left;" in c
    check "return p->right;" in c
    checkCCompiles(c, "native_layout_collision")

  test "aliased selection (name : local)":
    writeModule("math.gene", "(fn sub [a b] (- a b))")
    check runProgram("(import [sub : minus] from \"./math\") (minus 10 4)").print() == "6"
    check runProgram("(import sub : minus from \"./math\") " &
      "(minus 9 4)").print() == "5"

  test "bare wildcard imports are non-reexporting fallbacks":
    writeModule("wild_base.gene",
      "(var answer 42) (fn twice [x] (* x 2))")
    writeModule("wild_mid.gene",
      "(import * from \"./wild_base\") " &
      "(var observed (twice answer))")
    let app = newApplication(modDir)
    let mid = app.loadFileModule(modDir / "wild_mid.gene")
    check mid.moduleRootNamespace.nsScope.lookup("observed").print() == "84"
    expect GeneError:
      discard run(compileSource(
        "(import [answer] from \"./wild_mid\") answer"),
        newGlobalScope(app))

  test "wildcard collisions are lazy and share the prelude collision domain":
    writeModule("wild_left.gene", "(var shared 1) (var left_only 2)")
    writeModule("wild_right.gene", "(var shared 3) (var right_only 4)")
    writeModule("wild_builtin.gene", "(var map 42)")
    writeModule("wild_unused_user.gene",
      "(import * from \"./wild_left\") " &
      "(import * from \"./wild_right\") " &
      "(var observed (+ left_only right_only))")
    writeModule("wild_collision_user.gene",
      "(import * from \"./wild_left\") " &
      "(import * from \"./wild_right\") (var observed shared)")
    writeModule("wild_builtin_user.gene",
      "(import * from \"./wild_builtin\") (var observed map)")
    writeModule("wild_qualified_user.gene",
      "(import * : imported from \"./wild_builtin\") " &
      "(var observed [(== gene/map gene/map) imported/map])")
    let app = newApplication(modDir)
    let unused = app.loadFileModule(modDir / "wild_unused_user.gene")
    check unused.moduleRootNamespace.nsScope.lookup("observed").print() == "6"
    var collision = ""
    try:
      discard app.loadFileModule(modDir / "wild_collision_user.gene")
    except GeneError as error:
      collision = error.msg
    check collision.contains("ambiguous imported name 'shared'")
    check collision.contains("./wild_left")
    check collision.contains("./wild_right")
    # `map` is no longer a bare built-in (it lives under `gene`, reached as
    # `$map`), so a wildcard-imported `map` no longer collides with anything and
    # resolves to the imported value.
    let builtin = app.loadFileModule(modDir / "wild_builtin_user.gene")
    check builtin.moduleRootNamespace.nsScope.lookup("observed").print() == "42"
    let qualified = app.loadFileModule(modDir / "wild_qualified_user.gene")
    check qualified.moduleRootNamespace.nsScope.lookup("observed").print() ==
      "[true 42]"

  test "static declarations and selected imports beat wildcard fallback":
    writeModule("wild_explicit.gene", "(var answer 42)")
    writeModule("wild_before_local.gene",
      "(import * from \"./wild_explicit\") " &
      "(var observed answer) (var answer 1)")
    writeModule("wild_before_function_local.gene",
      "(import * from \"./wild_explicit\") " &
      "(fn observe [] answer (var answer 1)) (var observed (observe))")
    writeModule("wild_selected_user.gene",
      "(import * from \"./wild_explicit\") " &
      "(import [answer] from \"./wild_explicit\") (var observed answer)")
    let app = newApplication(modDir)
    expect GeneError:
      discard app.loadFileModule(modDir / "wild_before_local.gene")
    expect GeneError:
      discard app.loadFileModule(modDir / "wild_before_function_local.gene")
    let selected = app.loadFileModule(modDir / "wild_selected_user.gene")
    check selected.moduleRootNamespace.nsScope.lookup("observed").print() ==
      "42"

  test "wildcard and alias imports reject conditional placement":
    writeModule("wild_conditional.gene", "(var answer 42)")
    expect GeneError:
      discard runProgram("(if true " &
        "(import * from \"./wild_conditional\"))")
    expect GeneError:
      discard runProgram("(if true " &
        "(import * : m from \"./wild_conditional\"))")
    expect GeneError:
      discard runProgram("(if true " &
        "(import [answer] from \"./wild_conditional\" ^export true))")

  test "namespace wildcard and alias use the static namespace interface":
    writeModule("nested.gene",
      "(ns math (var answer 42) (fn twice [x] (* x 2)))")
    writeModule("nested_user.gene",
      "(import math/* from \"./nested\") " &
      "(import math/* : m from \"./nested\") " &
      "(var observed [(twice answer) (m/twice m/answer)])")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "nested_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() ==
      "[84 84]"

  test "wildcards carry macro metadata and selected fexprs stay explicit":
    writeModule("syntax_exports.gene",
      "(macro twice [x] `(+ %x %x)) " &
      "(fn raw! [x] x) " &
      "(ns tools " &
      "  (macro thrice [x] `(+ %x %x %x)))")
    writeModule("syntax_user.gene",
      "(import * from \"./syntax_exports\") " &
      "(import * : syntax from \"./syntax_exports\") " &
      "(import [raw!] from \"./syntax_exports\") " &
      "(import tools/* : tools from \"./syntax_exports\") " &
      "(var observed [(twice 21) (syntax/twice 20) " &
      "  (tools/thrice 10) (raw! (+ 1 2))])")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "syntax_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() ==
      "[42 40 30 (+ 1 2)]"

  test "private declarations stay out of selections and wildcard interfaces":
    writeModule("private_exports.gene",
      "(var public 1) (var hidden ^private true 2) " &
      "(var visible ^private false 4) " &
      "(ns secret ^private true (var value 3))")
    writeModule("private_user.gene",
      "(import * from \"./private_exports\") (var observed public)")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "private_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "1"
    check run(compileSource(
      "(import [visible] from \"./private_exports\") visible"),
      newGlobalScope(app)).print() == "4"
    expect GeneError:
      discard run(compileSource(
        "(import [hidden] from \"./private_exports\") hidden"),
        newGlobalScope(app))
    expect GeneError:
      discard run(compileSource(
        "(import [secret] from \"./private_exports\") secret"),
        newGlobalScope(app))
    check run(compileSource(
      "(import * : exports from \"./private_exports\") exports/hidden"),
      newGlobalScope(app)).kind == vkVoid

  test "explicit selected re-exports enter downstream wildcard interfaces":
    writeModule("reexport_base.gene",
      "(var answer 42) (macro twice [x] `(+ %x %x))")
    writeModule("reexport_mid.gene",
      "(import [answer twice] from \"./reexport_base\" ^export true)")
    writeModule("reexport_user.gene",
      "(import * from \"./reexport_mid\") " &
      "(var observed [(twice answer) answer])")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "reexport_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() ==
      "[84 42]"

  test "explicit alias re-exports retain their namespace interface":
    writeModule("alias_reexport_base.gene", "(var answer 42)")
    writeModule("alias_reexport_mid.gene",
      "(import * : base from \"./alias_reexport_base\" ^export true)")
    writeModule("alias_reexport_user.gene",
      "(import * from \"./alias_reexport_mid\") " &
      "(var observed base/answer)")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "alias_reexport_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "42"

  test "bind module value with wildcard alias":
    writeModule("math.gene", "(var pi 3) (fn add [a b] (+ a b))")
    check runProgram("(import * : m from \"./math\") m/pi").print() == "3"
    check runProgram("(import * : m from \"./math\") (m/add 1 1)").print() == "2"
    expect GeneError:
      discard runProgram("(import from \"./math\" ^as m)")
    expect GeneError:
      discard runProgram("(import gene/stream ^as stream)")

  test "module reflection exposes normalized file path":
    writeModule("math.gene", "(var pi 3)")
    let expected = normalizedPath(absolutePath("math.gene", modDir))
    check runProgram("(import * : m from \"./math\") (m ~ path)").strVal ==
      expected

  test "imported module roots expose declaration streams":
    writeModule("decls.gene", "(var exported 7)")
    check runProgram("(import * : m from \"./decls\") " &
      "(var ds ($filter ($declarations m) (fn [d] (== d/name \"exported\")))) " &
      "(ds ~ next)").print() ==
      "(Declaration ^name \"exported\" ^kind \"Int\" ^value 7)"

  test "runtime declarations exclude compile-time macros":
    writeModule("macro_decls.gene",
      "(macro twice [x] `(+ %x %x)) (var runtime-value 7)")
    check runProgram("(import * : m from \"./macro_decls\") " &
      "(var macros ($filter ($declarations m) (fn [d] (== d/name \"twice\")))) " &
      "(var values ($filter ($declarations m) " &
      "  (fn [d] (== d/name \"runtime-value\")))) " &
      "(var decl (values ~ next)) " &
      "[(macros ~ has_next) decl/value]").print() ==
      "[false 7]"

  test "file modules receive a this_mod binding":
    writeModule("self.gene",
      "(var x 9) " &
      "(var ds ($filter ($declarations this_mod) (fn [d] (== d/name \"x\")))) " &
      "(var decl (ds ~ next)) " &
      "(var seen decl/value)")
    check runProgram("(import [seen] from \"./self\") seen").print() == "9"

  test "this_mod exposes module reflection helpers":
    writeModule("selfpath.gene",
      "(var marker 42) " &
      "(var root (this_mod ~ root_namespace)) " &
      "(var reflected [(this_mod ~ name) " &
      "                (this_mod ~ path) " &
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
      "(var reflected [(this_mod ~ name) " &
      "                (/doc (this_mod ~ meta))])")
    check runProgram("(import [reflected] from \"./meta\") reflected").print() ==
      "[\"renamed\" \"module docs\"]"

  test "Module annotations accept module values":
    writeModule("math.gene", "(var pi 3)")
    check runProgram("(import * : m from \"./math\") " &
      "(fn module_path [m : Module] (m ~ path)) (module_path m)").strVal ==
      normalizedPath(absolutePath("math.gene", modDir))
    expect GeneError:
      discard runProgram("(fn module_id [m : Module] m) (module_id [1])")
    expect GeneError:
      discard runProgram("(ns local (var x 1)) " &
        "(fn module_id [m : Module] m) (module_id local)")

  test "a module is loaded once (cache returns the same module value)":
    writeModule("m.gene", "(var v 1)")
    check runProgram("(import * : a from \"./m\") (import * : b from \"./m\") (== a b)").print() == "true"

  test "entry file modules load through the application cache":
    let entryPath = modDir / "entry.gene"
    writeFile(entryPath, "(var value 11) (fn main [] value)")
    let app = newApplication(modDir)
    let entryModule = app.loadFileModule(entryPath)
    let imported = run(compileSource("(import * : e from \"./entry\") e"),
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
      "(fn local_json [user] (user ~ ToJson:to_json))")
    check runProgram("(import [ToJson] from \"./json\") " &
      "(import [User] from \"./model\") " &
      "(import [local_json] from \"./json_ext\") " &
      "(local_json (User ^name \"Ada\"))").print() == "\"Ada\""
    expect GeneError:
      discard runProgram("(import [ToJson] from \"./json\") " &
        "(import [User] from \"./model\") " &
        "(import * : ext from \"./json_ext\") " &
        "((User ^name \"Ada\") ~ ToJson:to_json)")

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
      "((User ^name \"Ada\") ~ ToJson:to_json)").print() == "\"Ada\""

  test "only exported scoped impls are importable":
    writeModule("export_base.gene",
      "(protocol P (message value [self])) (type T ^props {})")
    writeModule("canonical_export.gene",
      "(protocol P (message value [self])) (type T ^props {}) " &
      "(impl P for T ^export true (message value [self] 1))")
    expect GeneError:
      discard runProgram("(import * : bad from \"./canonical_export\")")

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
      discard runProgram("(import * : bad from \"./overlay_export\")")

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
    check run(compileSource("((Item) ~ Render:render)"), scope).print() == "\"one\""
    let before = app.implActivationEpoch
    writeModule("reload_ext.gene",
      "(import [Render Item] from \"./reload_base\") " &
      "(impl Render for Item ^export true " &
      "  (message render [self] : Str \"two\"))")
    discard app.reloadFileModule(modDir / "reload_ext.gene")
    check app.implActivationEpoch == before + 1
    check run(compileSource("((Item) ~ Render:render)"), scope).print() == "\"two\""

    let stableEpoch = app.implActivationEpoch
    writeModule("reload_ext.gene",
      "(import [Render Item] from \"./reload_base\") (var removed true)")
    expect GeneError:
      discard app.reloadFileModule(modDir / "reload_ext.gene")
    check app.implActivationEpoch == stableEpoch
    check run(compileSource("((Item) ~ Render:render)"), scope).print() == "\"two\""

  test "reload rejects compile-interface changes":
    writeModule("reload_interface.gene", "(var value 1)")
    let app = newApplication(modDir)
    let original = app.loadFileModule(modDir / "reload_interface.gene")
    check original.moduleRootNamespace.nsScope.lookup("value").print() == "1"
    writeModule("reload_interface.gene", "(var value 2) (var added 3)")
    expect GeneError:
      discard app.reloadFileModule(modDir / "reload_interface.gene")
    check app.loadFileModule(modDir / "reload_interface.gene").bits ==
      original.bits
    writeModule("reload_interface.gene", "(var value 2)")
    let replacement = app.reloadFileModule(modDir / "reload_interface.gene")
    check replacement.moduleRootNamespace.nsScope.lookup("value").print() == "2"

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
      discard run(compileSource("(import * : bad from \"./ext_bad\")"), scope)
    expect GeneError:
      discard run(compileSource("((A) ~ P:value)"), scope)
    check run(compileSource("((B) ~ P:value)"), scope).print() ==
      "\"existing\""

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

  test "module aliases and re-exports contribute protocol interfaces":
    writeModule("interface_base.gene",
      "(protocol Render (message render [self] : Str)) " &
      "(type T ^props {}) " &
      "(impl Render for T (message render [self] : Str \"interface\"))")
    writeModule("interface_mid.gene",
      "(import [Render T] from \"./interface_base\" ^export true)")
    check runProgram("(import * : base from \"./interface_base\") " &
      "((base/T) ~ base/Render:render)").print() == "\"interface\""
    check runProgram("(import [Render T] from \"./interface_mid\") " &
      "((T) ~ Render:render)").print() == "\"interface\""

  test "caught import failures do not establish protocol candidates":
    writeModule("candidate_type.gene", "(type T ^props {})")
    var message = ""
    try:
      discard runProgram("(import [T] from \"./candidate_type\") " &
        "(try (import [Render] from \"./missing_protocol\") catch _ nil) " &
        "((T) ~ render)")
    except GeneError as error:
      message = error.msg
    check message.contains("no message 'render' on T")
    check not message.contains("uninitialized protocol candidate")

  test "runtime import cycles have a runtime-phase diagnostic":
    writeModule("a.gene", "(import * : b from \"./b\") (var x 1)")
    writeModule("b.gene", "(import * : a from \"./a\") (var y 2)")
    var message = ""
    try:
      discard runProgram("(import * : a from \"./a\") a/x")
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

  test "gene exposes builtins and stdlib namespaces without shadowing":
    check runProgram("[(== gene/Error Error) " &
      "(gene/str/join [\"a\" \"b\"] \"-\")]").print() ==
      "[true \"a-b\"]"
    discard compileSource(
      "(fn log_message [logger] (gene/log/info logger \"hello\"))")
    for source in [
      "(var gene 1)",
      "(fn f [genex] genex)",
      "(var [geney] [1])",
      "(set gene 1)",
      "(mod gene)",
      "(import * : gene from \"./reserved_source\")"
    ]:
      if source.contains("reserved_source"):
        writeModule("reserved_source.gene", "(var value 1)")
      expect GeneError:
        discard runProgram(source)

  test "module declarations do not include built-ins":
    writeModule("decls2.gene", "(var only-me 1)")
    # Filtering the module's declarations for a built-in name finds nothing,
    # because built-ins live in the shared parent scope, not the module root.
    check runProgram("(import * : m from \"./decls2\") " &
      "(var ds ($filter ($declarations m) (fn [d] (== d/name \"map\")))) " &
      "(ds ~ has_next)").print() == "false"
    check runProgram("(import * : m from \"./decls2\") " &
      "(var ds ($filter ($declarations m) (fn [d] (== d/name \"this_mod\")))) " &
      "(ds ~ has_next)").print() == "false"

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

  test "bind an in-file namespace with colon alias":
    initModuleContext(getTempDir())
    check run(compileSource("(ns m (var a 5)) (import m : mm) mm/a"),
      newGlobalScope()).print() == "5"

  test "co-located namespace impls are canonical":
    initModuleContext(getTempDir())
    check run(compileSource(
      "(protocol Show (message show [self] : Str)) " &
      "(type T ^props {}) " &
      "(ns ext (impl Show for T (message show [self] : Str \"ok\"))) " &
      "((T) ~ Show:show)"),
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
      "(eval (quote ((T) ~ Show:show)) ^in e)").print() == "\"ok\""

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
      "[((T) ~ Show:show) (marker)]").print() == "[\"shared\" 1]"
    # local-module-first (the previously working order must stay working)
    check runProgram("(import [marker] from \"./uses_shared\") " &
      "(import [Show T] from \"./shared\") " &
      "[((T) ~ Show:show) (marker)]").print() == "[\"shared\" 1]"

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

suite "modules — the capability sandbox (design §D5)":
  ## §D5 claimed since revision 1 that "a mod that never receives
  ## `$fs/WriteDir` cannot write a file no matter what it evaluates". §D5.1
  ## measured that false — `$fs` is `gene/fs`, `gene` resolves out of the shared
  ## builtins root, and no `import` line is needed — and left exactly one shape
  ## standing: a module root parented to a *restricted* builtins scope.
  ##
  ## These are that shape's properties. The first is the escape §D5.1 published.
  setup:
    removeDir(modDir)
    createDir(modDir)
    removeFile(getTempDir() / "gene_sandbox_escape")

  test "a denied namespace cannot be reached, with no import line":
    ## §D5.1's exact program, verbatim.
    writeModule("evil.gene",
      "($fs/write_text $fs/WriteDir \"" &
      (getTempDir() / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"escaped\")")
    expect GeneError:
      discard runProgram(loadSandboxed(modDir, "evil.gene", "[]"))
    check not fileExists(getTempDir() / "gene_sandbox_escape")

  test "a granted namespace still works":
    writeModule("good.gene",
      "($fs/write_text $fs/WriteDir \"" &
      (getTempDir() / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"allowed\") (fn ok [] : Int 1)")
    discard runProgram(loadSandboxed(modDir, "good.gene", "[\"fs\"]"))
    check fileExists(getTempDir() / "gene_sandbox_escape")

  test "the restriction reaches a module the sandboxed one imports":
    ## The half that makes it a boundary rather than a speed bump: a mod that
    ## cannot name `$fs` must not be able to import a friend that can.
    writeModule("helper.gene",
      "(fn sneak [] : Str ($fs/write_text $fs/WriteDir \"" &
      (getTempDir() / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"via import\") \"wrote\")")
    writeModule("viaimport.gene",
      "(import [sneak] from \"./helper\") (sneak)")
    expect GeneError:
      discard runProgram(loadSandboxed(modDir, "viaimport.gene", "[]"))
    check not fileExists(getTempDir() / "gene_sandbox_escape")

  test "calling into a sandboxed module later is still restricted":
    ## The restriction is on the module's scope, not on the load, so a function
    ## exported *out* of a sandbox carries it — which is what makes a mod API
    ## safe to call back into on a tick.
    writeModule("quiet_helper.gene",
      "(fn sneak [p : Str] : Str ($fs/write_text $fs/WriteDir p \"w\") \"wrote\")")
    writeModule("quiet.gene",
      "(import [sneak] from \"./quiet_helper\") " &
      "(fn try_it [p : Str] : Str (sneak p))")
    expect GeneError:
      discard runProgram(
        "(var m " & loadSandboxed(modDir, "quiet.gene", "[]") & ") " &
        "(m/try_it \"" &
        (getTempDir() / "gene_sandbox_escape").replace("\\", "/") & "\")")
    check not fileExists(getTempDir() / "gene_sandbox_escape")

  test "trusted code keeps full authority over a file a sandbox also loaded":
    ## The module cache is keyed by the grant set. Without that it is a hole in
    ## both directions — a module the engine already loaded with full authority
    ## handed to a mod that must not have it, and a module first loaded under a
    ## sandbox coming back stripped for trusted code. This is the second
    ## direction, which is the one that would look like a mysterious bug rather
    ## than a breach.
    writeModule("shared_helper.gene",
      "(fn sneak [p : Str] : Str ($fs/write_text $fs/WriteDir p \"w\") \"wrote\")")
    writeModule("sandboxed_user.gene",
      "(import [sneak] from \"./shared_helper\") (fn noop [] : Int 1)")
    check runProgram(
      loadSandboxed(modDir, "sandboxed_user.gene", "[]") & " " &
      "(import [sneak] from \"./shared_helper\") " &
      "(sneak \"" &
      (getTempDir() / "gene_sandbox_escape").replace("\\", "/") & "\")"
      ).print() == "\"wrote\""
    check fileExists(getTempDir() / "gene_sandbox_escape")

  test "a sandbox cannot load another sandbox":
    ## Nesting would let a mod choose its own grants, and the grants a mod gets
    ## are the manifest's to decide.
    writeModule("inner.gene", "(fn ok [] : Int 1)")
    writeModule("nester.gene", loadSandboxed(modDir, "inner.gene", "[\"fs\"]"))
    expect GeneError:
      discard runProgram(loadSandboxed(modDir, "nester.gene", "[\"runtime\"]"))

  test "an unknown grant is refused rather than ignored":
    ## A manifest asking for "filesystem" instead of "fs" would otherwise load
    ## with less authority than it declared and fail somewhere unrelated.
    writeModule("plain.gene", "(fn ok [] : Int 1)")
    expect GeneError:
      discard runProgram(loadSandboxed(modDir, "plain.gene", "[\"filesystem\"]"))

  test "a mod loads into the caller's application, so a shared type is one type":
    ## The property M7's runtime loader stands on, and the one the cases above
    ## cannot see: the host and the mod must agree on a **type**. They only do if
    ## the mod's imports find the host's already-loaded modules, and that only
    ## happens if the load runs in the caller's Application.
    ##
    ## This runs in its own app on purpose. Under `runProgram` the program's app
    ## *is* the process-global default, so a builtin reaching for the global gets
    ## the right answer by coincidence — which is why the miclone loader failed
    ## with "expected Reg, got (type Reg)" while all eight cases above were green.
    ##
    ## §9's layout is load-bearing: the mod is its own directory under `mods/`, so
    ## the host module it imports lies outside the sandbox boundary and is shared
    ## (§D5.2). Sandbox the whole tree instead and the host module is restricted
    ## too, and the types differ again for an unrelated reason.
    let modRoot = modDir / "mods" / "shared_mod"
    createDir(modRoot / "src")
    writeModule("host_type.gene",
      "(type Reg ^props {^n Int} (ctor [n : Int] (set self/n n)))")
    writeFile(modRoot / "src" / "shared_mod.gene",
      "(import [Reg] from \"../../../host_type\") " &
      "(fn take_it [r : Reg] : Int r/n)")
    check runProgramInOwnApp(
      "(import [Reg] from \"./host_type\") " &
      "(var m " & loadSandboxed(modRoot, "src/shared_mod.gene", "[]",
                                "[\"" & (modDir / "host_type.gene").replace("\\", "/") & "\"]") & ") " &
      "(m/take_it (new Reg 7))").print() == "7"

  test "a mod's own sibling file is inside the sandbox, however deep the entry":
    ## §D5.2 said "the sandbox covers the mod's own directory" and derived that
    ## directory from the entry — `moduleSourceDir(entry).parentDir()`. Measured,
    ## that was false, and this is the program that measured it: a manifest picks
    ## its own `^entry`, so an entry two directories down put `free.gene` — the
    ## mod's own file — *outside* the mod's sandbox with full host authority, and
    ## §D5.1's escape worked again under `^grants []`.
    ##
    ## The boundary is now `load_sandboxed`'s `dir` argument, which the trusted
    ## host supplies and the loaded code cannot influence.
    let modRoot = modDir / "mods" / "deep_mod"
    createDir(modRoot / "src" / "a")
    writeFile(modRoot / "free.gene",
      "(fn go [] : Nil ($fs/write_text $fs/WriteDir \"" &
      (getTempDir() / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"escaped\"))")
    writeFile(modRoot / "src" / "a" / "deep_mod.gene",
      "(import [go] from \"../../free\") (go)")
    expect GeneError:
      discard runProgram(
        loadSandboxed(modRoot, "src/a/deep_mod.gene", "[]"))
    check not fileExists(getTempDir() / "gene_sandbox_escape")
    # The control, so this cannot rot into a pass for the wrong reason. Same
    # layout, same import, `fs` granted: it must load and write. Without this the
    # case above would still be green if `../../free` simply stopped resolving.
    discard runProgram(loadSandboxed(modRoot, "src/a/deep_mod.gene", "[\"fs\"]"))
    check fileExists(getTempDir() / "gene_sandbox_escape")

  test "an out-of-dir import the host did not share is refused":
    ## §D5.2 said "the restriction covers everything the module imports" and did
    ## not do that: a module outside `dir` loaded with **full host authority**, and
    ## the mod writes the import path, so the reachable set was the whole package
    ## root. Measured against the real layout: a mod granted nothing imported the
    ## host's `server/storage.gene`, called `open_world`/`write_meta`, and wrote a
    ## file of its choosing. The host cannot meet "do not leave reachable code
    ## where a mod can reach it" — so the host names the shared set instead.
    writeModule("host_authority.gene",
      "(fn touch [p : Str] : Str ($fs/write_text $fs/WriteDir p \"host\") \"w\")")
    let modRoot = modDir / "mods" / "reacher"
    createDir(modRoot / "src")
    writeFile(modRoot / "src" / "reacher.gene",
      "(import [touch] from \"../../../host_authority\") " &
      "(fn go [p : Str] : Str (touch p))")
    expect GeneError:
      discard runProgram(loadSandboxed(modRoot, "src/reacher.gene", "[]"))
    check not fileExists(getTempDir() / "gene_sandbox_escape")
    # The control, so this is a refusal about *authority* and not a broken path:
    # named as shared, the identical import loads and works.
    check runProgram(
      "(var m " & loadSandboxed(modRoot, "src/reacher.gene", "[]",
        "[\"" & (modDir / "host_authority.gene").replace("\\", "/") & "\"]") &
      ") (m/go \"" &
      (getTempDir() / "gene_sandbox_escape").replace("\\", "/") & "\")"
      ).print() == "\"w\""
    check fileExists(getTempDir() / "gene_sandbox_escape")

  test "a granted `runtime` cannot re-enter the sandbox after its load finished":
    ## The nesting guard read `sandboxRoot != nil`, which is true only *during* a
    ## load. A mod granted `runtime` could therefore export a function, be called
    ## later on a tick, and pick its own grants — the guard had already been
    ## unset. It is at the call site now, so it answers for *who is asking* rather
    ## than for what moment it is.
    let modRoot = modDir / "mods" / "climber2"
    createDir(modRoot / "src")
    createDir(modRoot / "inner")
    writeFile(modRoot / "inner" / "inner.gene",
      "($fs/write_text $fs/WriteDir \"" &
      (getTempDir() / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"grants I chose myself\")")
    writeFile(modRoot / "src" / "climber2.gene",
      "(fn escalate [] : Any ($runtime/load_sandboxed \"" &
      modRoot.replace("\\", "/") & "/inner\" \"inner.gene\" [\"fs\"] []))")
    expect GeneError:
      discard runProgram(
        "(var m " & loadSandboxed(modRoot, "src/climber2.gene",
                                  "[\"runtime\"]") & ") (m/escalate)")
    check not fileExists(getTempDir() / "gene_sandbox_escape")

  test "and the host's own loader is not reachable to launder that call":
    ## The other half, and the one the allowlist owns. A mod cannot be stopped
    ## from calling a *host* function that loads sandboxes — that call's scope
    ## chain is the host's, so no call-site test can see the mod behind it. What
    ## stops it is that the host module is not importable unless the host shared
    ## it. This is the shape the escape took against the real layout: the mod
    ## imported `server/mods_runtime.gene` and called `load_mod_at` on a directory
    ## whose manifest it shipped with `^grants ["fs"]`.
    ##
    ## **So the residual obligation is one line and it is checkable: do not share
    ## a module that loads sandboxes.** That is enforceable by reading the
    ## allowlist, unlike "do not leave reachable code where a mod can reach it",
    ## which was a claim about the whole package root.
    writeModule("host_loader.gene",
      "(fn load_it [d : Str e : Str] : Any " &
      "  ($runtime/load_sandboxed d e [\"fs\"] []))")
    let modRoot = modDir / "mods" / "climber3"
    createDir(modRoot / "src")
    writeFile(modRoot / "src" / "climber3.gene",
      "(import [load_it] from \"../../../host_loader\") " &
      "(fn go [] : Any (load_it \"x\" \"y.gene\"))")
    expect GeneError:
      discard runProgram(loadSandboxed(modRoot, "src/climber3.gene", "[]"))

  test "an entry that points out of its own directory is refused":
    ## The other half of the same rule. If the entry could escape `dir`, the mod's
    ## own code would load unrestricted and the boundary would have the subject on
    ## the wrong side of it.
    writeModule("outside.gene", "(fn ok [] : Int 1)")
    createDir(modDir / "mods" / "climber")
    expect GeneError:
      discard runProgram(
        loadSandboxed(modDir / "mods" / "climber", "../../outside.gene", "[]"))

  test "computation is not withheld — a sandbox can still do arithmetic":
    ## The list is what reaches outside the process. A sandbox that could not
    ## use `math` or `str` would be one that cannot work rather than one that
    ## cannot harm.
    writeModule("compute.gene",
      "(fn f [] : Int ($math/abs -3))")
    discard runProgram(loadSandboxed(modDir, "compute.gene", "[]"))
