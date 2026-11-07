import gene/[compiler, gir, gir_codec, types, vm, printer]
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

proc runSandboxProgram(src: string): Value =
  ## Sandbox cases use a fresh application rooted at the fixture directory.
  ##
  ## `newApplication`'s argument anchors *module resolution* only. Relative file
  ## paths deliberately follow the launch directory instead, so that
  ## `gene run path/to/app.gene` cannot reinterpret "tmp/x" beneath the entry
  ## file (vm.nim, newApplicationState) — the CLI passes the entry's package
  ## root here. So fixtures use absolute paths beneath the fixture root.
  let app = newApplication(modDir)
  run(compileSource(src), newGlobalScope(app))

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
    check runProgram("(import [add] ^from \"./math\") (add 2 3)").print() == "5"

  test "import a single binding":
    writeModule("math.gene", "(var pi 3)")
    check runProgram("(import pi ^from \"./math\") pi").print() == "3"

  test "module source properties may precede or follow selections":
    writeModule("math.gene", "(var pi 3)")
    for source in [
      "(import ^from \"./math\" pi) pi",
      "(import ^from \"./math\" [pi : value]) value",
      "(import pi ^from \"./math\" : value) value",
      "(import ^from \"./math\" * : math) math/pi"
    ]:
      check runProgram(source).print() == "3"

  test "from is available as an imported binding and namespace name":
    writeModule("keywords.gene", "(var from 7)")
    check runProgram("(import from ^from \"./keywords\") from").print() == "7"
    check runProgram("(ns from (var value 8)) " &
      "(import from [value]) value").print() == "8"

  test "module imports reject old syntax and malformed source properties":
    for (source, expected) in [
      ("(import pi from \"./math\")", "`from` was removed; use `^from"),
      ("(import * : math from \"./math\")", "`from` was removed; use `^from"),
      ("(import pi ^from math)", "^from must be a path string"),
      ("(import pi ^from 42)", "^from must be a path string"),
      ("(import pi ^from nil)", "^from must be a path string"),
      ("(import pi ^^from)", "^from must be a path string"),
      ("(import ^from \"./math\")", "requires a selection or wildcard"),
      ("(import pi extra ^from \"./math\")", "^from requires a selection"),
      ("(import pi ^from \"./math\" ^form \"./other\")", "unexpected option: ^form")
    ]:
      var diagnostic = ""
      try:
        discard compileSource(source)
      except GeneError as error:
        diagnostic = error.msg
      checkpoint source
      check expected in diagnostic

  test "module reference tables are isolated by defining module":
    writeModule("refs_a.gene",
      "#Ref shared [1]\n(fn get_shared [] ($deref shared))")
    writeModule("refs_b.gene",
      "#Ref shared [2]\n(fn get_shared [] ($deref shared))")
    check runProgram(
      "(import [get_shared : get_a] ^from \"./refs_a\") " &
      "(import [get_shared : get_b] ^from \"./refs_b\") " &
      "(var a (get_a)) (var b (get_b)) " &
      "[(a .first) (b .first) (same? a b)]").print() ==
      "[1 2 false]"

  test "a module with unresolved structural fixups is not published":
    writeModule("bad_refs.gene", "(var pending #Deref never)")
    expect GeneError:
      discard runProgram("(import * ^from \"./bad_refs\")")

  test "typed-native layout metadata crosses a selected module import":
    writeModule("native_layout.gene",
      "(ffi/struct CTimespec " &
      "  ^fields [[tv_sec C/Long] [tv_nsec C/Long]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^^mutable})")
    writeModule("native_layout_user.gene",
      "(import [Timespec] ^from \"./native_layout\") " &
      "(fn seconds [t : Timespec] : I64 t/tv_sec)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_layout_user.gene")
      .emitExperimentalC()
    check "typedef struct CTimespec" in c
    check "GeneNativeStatus gene_native_seconds(GeneNativeError *" in c
    check "->tv_sec" in c
    checkCCompiles(c, "native_selected_import")

  test "typed-native wrapper adapters retain imported ownership metadata":
    writeModule("native_wrapper.gene",
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"timespec_free\" ^copy \"timespec_copy\"})")
    writeModule("native_wrapper_user.gene",
      "(import [Timespec] ^from \"./native_wrapper\") " &
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
      "(import * : native ^from \"./native_alias_layout\") " &
      "(fn seconds [t : native/Timespec] : I64 t/tv_sec)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_alias_user.gene")
      .emitExperimentalC()
    check "gene_native_seconds" in c
    check "->tv_sec" in c
    checkCCompiles(c, "native_alias_import")

  test "an imported layout can back a re-exported native Type":
    writeModule("native_abi_only.gene",
      "(ffi/struct CRecord ^fields [[value C/Int64]])")
    writeModule("native_type_only.gene",
      "(import [CRecord] ^from \"./native_abi_only\") " &
      "(type Record ^native {^abi CRecord ^lifecycle manual})")
    writeModule("native_type_user.gene",
      "(import [Record] ^from \"./native_type_only\") " &
      "(fn value [p : Record] : I64 p/value)")
    let chunk = newApplication(modDir)
      .compileFileModule(modDir / "native_type_user.gene")
    let dependency = normalizedPath(absolutePath(
      modDir / "native_abi_only.gene")) & "::CRecord"
    check dependency in chunk.ffiStructDependencies
    check dependency in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "gene_native_value" in c
    check "->value" in c
    checkCCompiles(c, "native_imported_abi")

  test "typed-native metadata survives an explicit re-export":
    writeModule("native_reexport_base.gene",
      "(ffi/struct CRecord ^fields [[value C/Int64]]) " &
      "(type Record ^native {^abi CRecord ^lifecycle manual})")
    writeModule("native_reexport_mid.gene",
      "(import [Record] ^from \"./native_reexport_base\" ^^export)")
    writeModule("native_reexport_user.gene",
      "(import [Record] ^from \"./native_reexport_mid\") " &
      "(fn value [p : Record] : I64 p/value)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_reexport_user.gene")
      .emitExperimentalC()
    check "gene_native_value" in c
    check "->value" in c
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
      "(import [LeftRecord] ^from \"./native_left\") " &
      "(import [RightRecord] ^from \"./native_right\") " &
      "(fn left_value [p : LeftRecord] : I64 p/left) " &
      "(fn right_value [p : RightRecord] : F64 p/right)")
    let c = newApplication(modDir)
      .compileFileModule(modDir / "native_collision_user.gene")
      .emitExperimentalC()
    check "->left" in c
    check "->right" in c
    checkCCompiles(c, "native_layout_collision")

  test "aliased selection (name : local)":
    writeModule("math.gene", "(fn sub [a b] (- a b))")
    check runProgram("(import [sub : minus] ^from \"./math\") (minus 10 4)").print() == "6"
    check runProgram("(import sub : minus ^from \"./math\") " &
      "(minus 9 4)").print() == "5"

  test "bare wildcard imports are non-reexporting fallbacks":
    writeModule("wild_base.gene",
      "(var answer 42) (fn twice [x] (* x 2))")
    writeModule("wild_mid.gene",
      "(import * ^from \"./wild_base\") " &
      "(var observed (twice answer))")
    let app = newApplication(modDir)
    let mid = app.loadFileModule(modDir / "wild_mid.gene")
    check mid.moduleRootNamespace.nsScope.lookup("observed").print() == "84"
    expect GeneError:
      discard run(compileSource(
        "(import [answer] ^from \"./wild_mid\") answer"),
        newGlobalScope(app))

  test "wildcard collisions are lazy and share the prelude collision domain":
    writeModule("wild_left.gene", "(var shared 1) (var left_only 2)")
    writeModule("wild_right.gene", "(var shared 3) (var right_only 4)")
    writeModule("wild_builtin.gene", "(var map 42)")
    writeModule("wild_unused_user.gene",
      "(import * ^from \"./wild_left\") " &
      "(import * ^from \"./wild_right\") " &
      "(var observed (+ left_only right_only))")
    writeModule("wild_collision_user.gene",
      "(import * ^from \"./wild_left\") " &
      "(import * ^from \"./wild_right\") (var observed shared)")
    writeModule("wild_builtin_user.gene",
      "(import * ^from \"./wild_builtin\") (var observed map)")
    writeModule("wild_qualified_user.gene",
      "(import * : imported ^from \"./wild_builtin\") " &
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
      "(import * ^from \"./wild_explicit\") " &
      "(var observed answer) (var answer 1)")
    writeModule("wild_before_function_local.gene",
      "(import * ^from \"./wild_explicit\") " &
      "(fn observe [] answer (var answer 1)) (var observed (observe))")
    writeModule("wild_selected_user.gene",
      "(import * ^from \"./wild_explicit\") " &
      "(import [answer] ^from \"./wild_explicit\") (var observed answer)")
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
        "(import * ^from \"./wild_conditional\"))")
    expect GeneError:
      discard runProgram("(if true " &
        "(import * : m ^from \"./wild_conditional\"))")
    expect GeneError:
      discard runProgram("(if true " &
        "(import [answer] ^from \"./wild_conditional\" ^^export))")

  test "namespace wildcard and alias use the static namespace interface":
    writeModule("nested.gene",
      "(ns math (var answer 42) (fn twice [x] (* x 2)))")
    writeModule("nested_user.gene",
      "(import math/* ^from \"./nested\") " &
      "(import math/* : m ^from \"./nested\") " &
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
      "(import * ^from \"./syntax_exports\") " &
      "(import * : syntax ^from \"./syntax_exports\") " &
      "(import [raw!] ^from \"./syntax_exports\") " &
      "(import tools/* : tools ^from \"./syntax_exports\") " &
      "(var observed [(twice 21) (syntax/twice 20) " &
      "  (tools/thrice 10) (raw! (+ 1 2))])")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "syntax_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() ==
      "[42 40 30 (+ 1 2)]"

  test "macro bodies resolve private definition helpers through imports":
    writeModule("macro_helpers.gene",
      "(fn helper ^^private [x] (* x 100)) " &
      "(macro computed [x] (helper x)) " &
      "(macro emitted [x] `(helper %x))")
    writeModule("macro_helper_user.gene",
      "(import [computed emitted] ^from \"./macro_helpers\") " &
      "(fn helper [x] (+ x 1)) " &
      "(var observed [(computed 2) (emitted 2)])")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "macro_helper_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "[200 3]"

  test "aliases and re-exports preserve body lookup and caller syntax lookup":
    writeModule("macro_lookup_origin.gene",
      "(fn helper ^^private [x] (* x 100)) " &
      "(macro computed [x] (helper x)) " &
      "(macro emitted [x] `(helper %x))")
    writeModule("macro_lookup_reexport.gene",
      "(import [computed : calculate emitted : invoke] " &
      "^from \"./macro_lookup_origin\" ^^export)")
    writeModule("macro_lookup_user.gene", "(import * : library ^from \"./macro_lookup_reexport\") " &
      "(import [calculate : selected] ^from \"./macro_lookup_reexport\") " &
      "(fn helper [x] (+ x 1)) " &
      "(var observed [(library/calculate 2) (library/invoke 2) (selected 2)])")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "macro_lookup_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "[200 3 200]"
    writeModule("macro_lookup_missing.gene",
      "(import [invoke] ^from \"./macro_lookup_reexport\") (invoke 2)")
    var failure = ""
    try: discard app.loadFileModule(modDir / "macro_lookup_missing.gene")
    except GeneError as error: failure = error.msg
    check "undefined symbol: helper" in failure

  test "generated helper macro calls require caller visibility":
    writeModule("macro_callsite_helpers.gene",
      "(macro helper ^^private [x] `(* %x 100)) " &
      "(macro emitted [x] `(helper %x))")
    writeModule("macro_callsite_user.gene",
      "(import [emitted] ^from \"./macro_callsite_helpers\") " &
      "(macro helper [x] `(+ %x 1)) (var observed (emitted 2))")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "macro_callsite_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "3"
    writeModule("macro_callsite_missing.gene",
      "(import [emitted] ^from \"./macro_callsite_helpers\") (emitted 2)")
    var failure = ""
    try: discard app.loadFileModule(modDir / "macro_callsite_missing.gene")
    except GeneError as error: failure = error.msg
    check "undefined symbol: helper" in failure

  test "macro definition modules retain identity without dependency source":
    writeModule("macro_identity.gene",
      "(mod original) (fn helper ^^private [x] (+ x 1)) " &
      "(macro module_name [] this_mod/.name) " &
      "(macro computed [x] (helper x))")
    let compilerApp = newApplication(modDir)
    let original = compilerApp.compileFileModuleBundle(modDir / "macro_identity.gene",
      compilerApp.applicationPackage.id)
    let decoded = decodeExecutableGir(encodeExecutableGir(original))
    removeFile(modDir / "macro_identity.gene")
    writeModule("macro_identity_user.gene",
      "(mod caller) (import [module_name computed] ^from \"./macro_identity\") " &
      "(var observed [(module_name) (computed 41)])")
    let app = newApplication(modDir)
    app.installCompiledModules(decoded.modules)
    let loaded = app.loadFileModule(modDir / "macro_identity_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "[\"original\" 42]"

  test "gensym binders are reproducible and survive an artifact round trip":
    writeModule("gensym_artifact.gene",
      "(mod gensym_artifact) " &
      "(macro swap [a b] (let tmp ($gensym \"tmp\")) " &
      "  `(do (var %tmp %a) (set %a %b) (set %b %tmp))) " &
      "(var tmp 1) (var y 2) (swap tmp y) (var observed [tmp y])")
    let firstApp = newApplication(modDir)
    let original = firstApp.compileFileModuleBundle(modDir / "gensym_artifact.gene",
      firstApp.applicationPackage.id)
    let secondApp = newApplication(modDir)
    let again = secondApp.compileFileModuleBundle(modDir / "gensym_artifact.gene",
      secondApp.applicationPackage.id)
    let encoded = encodeExecutableGir(original)
    # Nothing in a gensym is random or order-dependent.
    check encodeExecutableGir(again) == encoded
    check encoded.contains("tmp_")
    let decoded = decodeExecutableGir(encoded)
    removeFile(modDir / "gensym_artifact.gene")
    let app = newApplication(modDir)
    app.installCompiledModules(decoded.modules)
    let loaded = app.loadFileModule(modDir / "gensym_artifact.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "[2 1]"

  test "gensym names carry the module hash: modules differ, a moved checkout matches":
    let body = "(macro names [] (let t ($gensym \"tmp\")) `(quote %t)) " &
      "(var observed (names))"
    writeModule("hash_a.gene", body)
    writeModule("hash_b.gene", body)
    let app = newApplication(modDir)
    let a = app.loadFileModule(modDir / "hash_a.gene")
      .moduleRootNamespace.nsScope.lookup("observed").print()
    let b = app.loadFileModule(modDir / "hash_b.gene")
      .moduleRootNamespace.nsScope.lookup("observed").print()
    check a.startsWith("tmp_")
    check a.endsWith("_0_1")
    check b.endsWith("_0_1")
    check a != b
    # The same module under another checkout root: an application's own
    # modules identify by their relative path, so the hash is the same.
    let moved = getTempDir() / "gene_module_tests_moved"
    removeDir(moved)
    createDir(moved)
    defer: removeDir(moved)
    writeFile(moved / "hash_a.gene", body)
    let movedApp = newApplication(moved)
    check movedApp.loadFileModule(moved / "hash_a.gene")
      .moduleRootNamespace.nsScope.lookup("observed").print() == a

  test "a module-level macro cannot insert its own module value":
    writeModule("insert_module.gene",
      "(macro m [] `(quote %this_mod)) (var observed (m))")
    let app = newApplication(modDir)
    var message = ""
    try:
      discard app.loadFileModule(modDir / "insert_module.gene")
    except GeneError as error:
      message = error.msg
    check "cannot insert compile-time module 'insert_module' into generated code" in message

  test "a macro cannot launder its own helper through an argument it mutates":
    ## `smuggle` pushes its compile-time `helper` into the list the caller
    ## supplied. The caller supplied no function, so the result is rejected,
    ## through `eval` and through a local macro's result as well as directly.
    writeModule("launder_def.gene",
      "(var calls 0) " &
      "(fn helper [] (set calls (+ calls 1)) calls) " &
      "(fn read_calls [] calls) " &
      "(macro smuggle [items] (items .push helper) `(quote %items))")
    let app = newApplication(modDir)
    for caller in [
        "(import [smuggle] ^from \"./launder_def\") (smuggle [])",
        "(import [smuggle] ^from \"./launder_def\") " &
          "(var picked (eval `(smuggle []) ^in (env)))",
        "(import [smuggle] ^from \"./launder_def\") " &
          "(fn run [] (macro local [] `(smuggle [])) (local)) (var picked (run))"]:
      writeModule("launder_user.gene", caller)
      var message = ""
      try:
        discard newApplication(modDir).loadFileModule(modDir / "launder_user.gene")
      except GeneError as error:
        message = error.msg
      checkpoint caller
      check "cannot insert compile-time function 'helper'" in message
    # the valid case still works: a function the caller itself supplies
    writeModule("launder_user.gene",
      "(import [helper read_calls smuggle] ^from \"./launder_def\") " &
      "(macro forward [syntax] syntax) " &
      "(var picked (eval `(forward %helper) ^in (env))) " &
      "(var observed [(same? picked helper) (picked) (read_calls)])")
    check app.loadFileModule(modDir / "launder_user.gene")
      .moduleRootNamespace.nsScope.lookup("observed").print() == "[true 1 1]"

  test "a printed expansion pasted into another module is not captured":
    let swapMacro = "(macro swap [a b] (let tmp ($gensym \"tmp\")) " &
      "`(do (var %tmp %a) (set %a %b) (set %b %tmp))) "
    writeModule("paste_a.gene",
      "(macro names [] (let t ($gensym \"tmp\")) `(quote %t)) " &
      "(var observed (names))")
    let app = newApplication(modDir)
    let printed = app.loadFileModule(modDir / "paste_a.gene")
      .moduleRootNamespace.nsScope.lookup("observed").print()
    # module A's `tmp_<hash>_0_1` is an ordinary caller name in module B, whose
    # own `swap` makes a different one
    writeModule("paste_b.gene", swapMacro &
      "(var " & printed & " 1) (var y 2) (swap " & printed & " y) " &
      "(var observed [" & printed & " y])")
    check app.loadFileModule(modDir / "paste_b.gene")
      .moduleRootNamespace.nsScope.lookup("observed").print() == "[2 1]"

  test "macro body imports use verified artifacts after source removal":
    writeModule("phase_dep.gene",
      "(type PhaseBox ^props {^value Int} (message value [] : Int self/value)) " &
      "(fn add [x : Int] : Int (+ x 1))")
    writeModule("phase_macros.gene",
      "(import [add] ^from \"./phase_dep\") (macro computed [x] (add x))")
    writeModule("phase_user.gene",
      "(import [computed] ^from \"./phase_macros\") (var observed (computed 41))")
    let compilerApp = newApplication(modDir)
    let bundle = decodeExecutableGir(encodeExecutableGir(
      compilerApp.compileFileModuleBundle(modDir / "phase_user.gene",
        compilerApp.applicationPackage.id)))
    removeFile(modDir / "phase_dep.gene")
    removeFile(modDir / "phase_macros.gene")
    let app = newApplication(modDir)
    app.installCompiledModules(bundle.modules)
    # Initialize the dependency first as well: the phase must not execute
    # against a runtime instance or mutate its compiler template.
    let dependency = app.loadFileModule(modDir / "phase_dep.gene")
    let runtimeScope = newGlobalScope(app)
    runtimeScope.define("dep", dependency)
    check run(compileSource("[(dep/add 3) ((dep/PhaseBox ^value 7) .value)]"),
      runtimeScope).print() == "[4 7]"
    writeModule("phase_second_user.gene",
      "(import [computed] ^from \"./phase_macros\") (var observed (computed 42))")
    let loaded = app.loadFileModule(modDir / "phase_second_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "43"

  test "phase imports preserve runtime constants in source-compiled templates":
    # The constant is an intrinsic: a module-level macro may insert a native
    # function of the `gene` root, but not a definition of its own module.
    writeModule("phase_value_dep.gene",
      "(macro apply_helper [x] `(%$to_str %x)) " &
      "(var offset (apply_helper 2)) (fn add [x] ($to_str offset x))")
    writeModule("phase_value_macros.gene",
      "(import [add] ^from \"./phase_value_dep\") (macro computed [x] (add x))")
    writeModule("phase_value_user.gene",
      "(import [computed] ^from \"./phase_value_macros\") (var observed (computed 40))")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "phase_value_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "\"240\""

  test "macros and phase imports share one definition module instance":
    writeModule("phase_counter.gene",
      "(var count 0) (fn next [] (set count (+ count 1))) " &
      "(macro next_value [] (next))")
    writeModule("phase_counter_bridge.gene",
      "(import [next] ^from \"./phase_counter\") (macro via_bridge [] (next))")
    writeModule("phase_counter_user.gene",
      "(import [via_bridge] ^from \"./phase_counter_bridge\") " &
      "(import [next_value count] ^from \"./phase_counter\") " &
      "(var observed [(via_bridge) (next_value) count])")
    let loaded = newApplication(modDir).loadFileModule(modDir / "phase_counter_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "[1 2 0]"

  test "reentrant phase eval uses bindings already initialized by the module loader":
    writeModule("phase_reentrant.gene",
      "(var count 0) (fn next [] (set count (+ count 1))) " &
      "(macro next_value [] (next)) " &
      "(var baked (eval (quote (next_value)) ^in (env)))")
    writeModule("phase_reentrant_bridge.gene",
      "(import [next] ^from \"./phase_reentrant\") (macro via_bridge [] (next))")
    writeModule("phase_reentrant_user.gene",
      "(import [via_bridge] ^from \"./phase_reentrant_bridge\") " &
      "(var observed (via_bridge))")
    let loaded = newApplication(modDir).loadFileModule(modDir / "phase_reentrant_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "2"

  test "qualified imported macros yield to a shadowing namespace value":
    writeModule("macro_alias.gene", "(macro twice [x] `(+ %x %x))")
    writeModule("macro_alias_user.gene",
      "(import * : tools ^from \"./macro_alias\") " &
      "(fn f [tools] (tools/twice 3)) " &
      "(var observed [(f {^twice (fn [x] (* x 10))}) (tools/twice 3)])")
    let loaded = newApplication(modDir).loadFileModule(modDir / "macro_alias_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "[30 6]"

  test "Env module imports expose public macros including re-exports":
    writeModule("env_macros.gene",
      "(macro twice [x] `(+ %x %x)) (macro secret ^^private [] 99)")
    writeModule("env_macro_mid.gene",
      "(import [twice] ^from \"./env_macros\" ^^export)")
    check runProgram("(let e (env ^imports [\"./env_macro_mid\"])) " &
      "(eval (quote (twice 3)) ^in e)").print() == "6"
    check runProgram("(let e (env ^imports [\"./env_macros\"])) " &
      "(try (eval (quote (secret)) ^in e) catch Any \"private\")").print() == "\"private\""
    writeModule("env_macro_alias_mid.gene",
      "(import * : tools ^from \"./env_macros\" ^^export)")
    check runProgram("(let e (env ^imports [\"./env_macro_alias_mid\"])) " &
      "(eval (quote (tools/twice 3)) ^in e)").print() == "6"

  test "private declarations stay out of selections and wildcard interfaces":
    writeModule("private_exports.gene",
      "(var public 1) (var hidden ^^private 2) " &
      "(var visible ^!private 4) " &
      "(ns secret ^^private (var value 3))")
    writeModule("private_user.gene",
      "(import * ^from \"./private_exports\") (var observed public)")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "private_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "1"
    check run(compileSource(
      "(import [visible] ^from \"./private_exports\") visible"),
      newGlobalScope(app)).print() == "4"
    expect GeneError:
      discard run(compileSource(
        "(import [hidden] ^from \"./private_exports\") hidden"),
        newGlobalScope(app))
    expect GeneError:
      discard run(compileSource(
        "(import [secret] ^from \"./private_exports\") secret"),
        newGlobalScope(app))
    check run(compileSource(
      "(import * : exports ^from \"./private_exports\") exports/hidden"),
      newGlobalScope(app)).kind == vkVoid

  test "explicit selected re-exports enter downstream wildcard interfaces":
    writeModule("reexport_base.gene",
      "(var answer 42) (macro twice [x] `(+ %x %x))")
    writeModule("reexport_mid.gene",
      "(import [answer twice] ^from \"./reexport_base\" ^^export)")
    writeModule("reexport_user.gene",
      "(import * ^from \"./reexport_mid\") " &
      "(var observed [(twice answer) answer])")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "reexport_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() ==
      "[84 42]"

  test "explicit alias re-exports retain their namespace interface":
    writeModule("alias_reexport_base.gene", "(var answer 42)")
    writeModule("alias_reexport_mid.gene",
      "(import * : base ^from \"./alias_reexport_base\" ^^export)")
    writeModule("alias_reexport_user.gene",
      "(import * ^from \"./alias_reexport_mid\") " &
      "(var observed base/answer)")
    let app = newApplication(modDir)
    let loaded = app.loadFileModule(modDir / "alias_reexport_user.gene")
    check loaded.moduleRootNamespace.nsScope.lookup("observed").print() == "42"

  test "bind module value with wildcard alias":
    writeModule("math.gene", "(var pi 3) (fn add [a b] (+ a b))")
    check runProgram("(import * : m ^from \"./math\") m/pi").print() == "3"
    check runProgram("(import * : m ^from \"./math\") (m/add 1 1)").print() == "2"
    expect GeneError:
      discard runProgram("(import ^from \"./math\" ^as m)")
    expect GeneError:
      discard runProgram("(import gene/stream ^as stream)")

  test "module reflection exposes normalized file path":
    writeModule("math.gene", "(var pi 3)")
    let expected = normalizedPath(absolutePath("math.gene", modDir))
    check runProgram("(import * : m ^from \"./math\") (m .path)").strVal ==
      expected

  test "imported module roots expose declaration streams":
    writeModule("decls.gene", "(var exported 7)")
    check runProgram("(import * : m ^from \"./decls\") " &
      "(var ds ($filter ($declarations m) (fn [d] (== d/name \"exported\")))) " &
      "(ds .next)").print() ==
      "(Declaration ^name \"exported\" ^kind \"Int\" ^value 7)"

  test "runtime declarations exclude compile-time macros":
    writeModule("macro_decls.gene",
      "(macro twice [x] `(+ %x %x)) (var runtime-value 7)")
    check runProgram("(import * : m ^from \"./macro_decls\") " &
      "(var macros ($filter ($declarations m) (fn [d] (== d/name \"twice\")))) " &
      "(var values ($filter ($declarations m) " &
      "  (fn [d] (== d/name \"runtime-value\")))) " &
      "(var decl (values .next)) " &
      "[(macros .has_next) decl/value]").print() ==
      "[false 7]"

  test "file modules receive a this_mod binding":
    writeModule("self.gene",
      "(var x 9) " &
      "(var ds ($filter ($declarations this_mod) (fn [d] (== d/name \"x\")))) " &
      "(var decl (ds .next)) " &
      "(var seen decl/value)")
    check runProgram("(import [seen] ^from \"./self\") seen").print() == "9"

  test "this_mod exposes module reflection helpers":
    writeModule("selfpath.gene",
      "(var marker 42) " &
      "(var root (this_mod .root_namespace)) " &
      "(var reflected [(this_mod .name) " &
      "                (this_mod .path) " &
      "                (== root this_mod) " &
      "                (/marker root)])")
    let reflected = runProgram("(import [reflected] ^from \"./selfpath\") reflected")
    check reflected.listItems[0].strVal == "selfpath"
    check reflected.listItems[1].strVal ==
      normalizedPath(absolutePath("selfpath.gene", modDir))
    check reflected.listItems[2].boolVal == false
    check reflected.listItems[3].intVal == 42

  test "mod metadata persists on the module value":
    writeModule("meta.gene",
      "(mod renamed @doc \"module docs\") " &
      "(var reflected [(this_mod .name) " &
      "                (/doc (this_mod .meta))])")
    check runProgram("(import [reflected] ^from \"./meta\") reflected").print() ==
      "[\"renamed\" \"module docs\"]"

  test "Module annotations accept module values":
    writeModule("math.gene", "(var pi 3)")
    check runProgram("(import * : m ^from \"./math\") " &
      "(fn module_path [m : Module] (m .path)) (module_path m)").strVal ==
      normalizedPath(absolutePath("math.gene", modDir))
    expect GeneError:
      discard runProgram("(fn module_id [m : Module] m) (module_id [1])")
    expect GeneError:
      discard runProgram("(ns local (var x 1)) " &
        "(fn module_id [m : Module] m) (module_id local)")

  test "a module is loaded once (cache returns the same module value)":
    writeModule("m.gene", "(var v 1)")
    check runProgram("(import * : a ^from \"./m\") (import * : b ^from \"./m\") (== a b)").print() == "true"

  test "entry file modules load through the application cache":
    let entryPath = modDir / "entry.gene"
    writeFile(entryPath, "(var value 11) (fn main [] value)")
    let app = newApplication(modDir)
    let entryModule = app.loadFileModule(entryPath)
    let imported = run(compileSource("(import * : e ^from \"./entry\") e"),
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
    let src = "(import [value] ^from \"./lib\") value"
    check run(compileSource(src), newGlobalScope(appA)).print() == "\"A\""
    check run(compileSource(src), newGlobalScope(appB)).print() == "\"B\""
    writeFile(dirA / "lib.gene", "(var value \"changed\")")
    check run(compileSource(src), newGlobalScope(appA)).print() == "\"A\""

  test "transitive imports resolve relative to each module":
    writeModule("base.gene", "(fn one [] 1)")
    writeModule("mid.gene", "(import [one] ^from \"./base\") (fn two [] (+ (one) (one)))")
    check runProgram("(import [two] ^from \"./mid\") (two)").print() == "2"

  test "ordinary imports do not import scoped extension impls":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext.gene",
      "(import [ToJson] ^from \"./json\") " &
      "(import [User] ^from \"./model\") " &
      "(impl ToJson for User (message to_json [self] : Str self/name)) " &
      "(fn local_json [user] (user .ToJson:to_json))")
    check runProgram("(import [ToJson] ^from \"./json\") " &
      "(import [User] ^from \"./model\") " &
      "(import [local_json] ^from \"./json_ext\") " &
      "(local_json (User ^name \"Ada\"))").print() == "\"Ada\""
    expect GeneError:
      discard runProgram("(import [ToJson] ^from \"./json\") " &
        "(import [User] ^from \"./model\") " &
        "(import * : ext ^from \"./json_ext\") " &
        "((User ^name \"Ada\") .ToJson:to_json)")

  test "import_impl imports one exported scoped pair idempotently":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext.gene",
      "(import [ToJson] ^from \"./json\") " &
      "(import [User] ^from \"./model\") " &
      "(impl ToJson for User ^^export " &
      "  (message to_json [self] : Str self/name))")
    for source in [
      "(import_impl ToJson for User ^from \"./json_ext\") ",
      "(import_impl ^from \"./json_ext\" ToJson for User) ",
      "(import_impl ToJson ^from \"./json_ext\" for User) "
    ]:
      check runProgram("(import [ToJson] ^from \"./json\") " &
        "(import [User] ^from \"./model\") " & source & source &
        "((User ^name \"Ada\") .ToJson:to_json)").print() == "\"Ada\""

  test "import_impl is accepted wherever import is and is visible where import binds":
    writeModule("pl_label.gene", "(protocol Label (message label [self] : Str))")
    writeModule("pl_item.gene", "(type Item)")
    writeModule("pl_ext.gene",
      "(import [Label] ^from \"./pl_label\") " &
      "(import [Item] ^from \"./pl_item\") " &
      "(var tag \"local\") " &
      "(impl Label for Item ^^export (message label [self] : Str \"local\"))")
    let header = "(import [Label] ^from \"./pl_label\") " &
      "(import [Item] ^from \"./pl_item\") (let item (Item)) "
    # Each position runs `{I}` then `{U}` and leaves the result in `inside`.
    # `nested` positions keep both kinds of import to their activation; the
    # others run in the module's base scope, so the import joins the module.
    let positions = [
      ("fn", true, "(fn run [] {I} {U}) (let inside (run))"),
      ("fn with locals", true,
        "(fn run [seed] (let t seed) {I} {U}) (let inside (run 1))"),
      ("lambda", true, "(let run (fn [] {I} {U})) (let inside (run))"),
      ("nested blocks in a fn", true,
        "(fn run [flag] (do (if flag (then (do {I})))) {U}) (let inside (run true))"),
      ("type message", true,
        "(type Holder ^props {} (message run [] {I} {U})) " &
        "(let inside ((Holder) .run))"),
      ("impl message", true,
        "(type Holder ^props {}) (protocol Run (message run [])) " &
        "(impl Run for Holder (message run [] {I} {U})) " &
        "(let inside ((Holder) .Run:run))"),
      ("ctor", true,
        "(type Holder ^props {^v Any} (ctor [] {I} (set self/v {U}))) " &
        "(let holder (new Holder)) (let inside holder/v)"),
      ("spawn in a fn", true,
        "(fn run [] (await (spawn (do {I} {U})))) (let inside (run))"),
      ("top-level spawn", true, "(let inside (await (spawn (do {I} {U}))))"),
      ("macro-marked block", true,
        "(macro with_ext [body...] `(do {I} %body...)) (let inside (with_ext {U}))"),
      ("macro expanded in a fn", true,
        "(fn run [] (macro make [] `(do {I} {U})) (make)) (let inside (run))"),
      ("top-level for body", true,
        "(var inside nil) (for x in [1] {I} (set inside {U}))"),
      ("scope body", true, "(let inside (scope {I} {U}))"),
      ("supervisor body", true, "(let inside (supervisor ^strategy stop {I} {U}))"),
      ("ns body", true, "(ns box {I} (fn get [] {U})) (let inside (box/get))"),
      ("top-level conditional", false, "(let inside (if true (then {I} {U})))"),
      ("top-level try", false, "(let inside (try {I} {U} catch Any nil))"),
      ("top-level do", false, "(do {I}) (let inside {U})"),
      ("after code", false, "(let x 1) {I} (let inside {U})")
    ]
    for (kind, nested, code) in positions:
      checkpoint kind
      var results: seq[string]
      for (importForm, use) in [
        ("(import [tag] ^from \"./pl_ext\")", "tag"),
        ("(import_impl Label for Item ^from \"./pl_ext\")", "item/.Label:label")
      ]:
        let program = header &
          code.replace("{I}", importForm).replace("{U}", use) &
          " [inside (try " & use & " catch Any \"hidden\")]"
        results.add runProgram(program).print()
      check results[0] == results[1]
      check results[1] ==
        (if nested: "[\"local\" \"hidden\"]" else: "[\"local\" \"local\"]")
    # A `mod` form's body is module level as well, before or after code.
    check runProgram("(mod pl_body " & header &
      "(let x 1) (import_impl Label for Item ^from \"./pl_ext\") " &
      "item/.Label:label)").print() == "\"local\""
    # eval rejects both.
    for form in ["(import [tag] ^from \"./pl_ext\")",
                 "(import_impl Label for Item ^from \"./pl_ext\")"]:
      expect GeneError:
        discard runProgram(header &
          "(eval (quote " & form & ") ^in (env ^bindings {^Label Label ^Item Item}))")

  test "a nested import_impl belongs to its activation and never shadows":
    writeModule("act_label.gene", "(protocol Label (message label [self] : Str))")
    writeModule("act_item.gene", "(type Item)")
    for name in ["one", "two"]:
      writeModule("act_" & name & ".gene",
        "(import [Label] ^from \"./act_label\") " &
        "(import [Item] ^from \"./act_item\") " &
        "(impl Label for Item ^^export (message label [self] : Str \"" & name & "\"))")
    writeModule("act_lib.gene",
      "(import [Label] ^from \"./act_label\") " &
      "(import [Item] ^from \"./act_item\") " &
      "(fn label_one [i] (import_impl Label for Item ^from \"./act_one\") i/.Label:label) " &
      "(fn sibling [i] (try i/.Label:label catch Any \"hidden\"))")
    let header = "(import [Label] ^from \"./act_label\") " &
      "(import [Item] ^from \"./act_item\") " &
      "(let item (Item)) "
    let one = "(import_impl Label for Item ^from \"./act_one\")"
    let two = "(import_impl Label for Item ^from \"./act_two\")"
    # Interleaved activations each use their own pair; a closure keeps the
    # policy of the activation that made it; a library function's import stays
    # in that call, so neither the library nor the caller sees it.
    check runProgram(header &
      "(import [label_one sibling] ^from \"./act_lib\") " &
      "(fn one_fn [] " & one & " item/.Label:label) " &
      "(fn two_fn [] " & two & " item/.Label:label) " &
      "(fn escaping [] " & one & " (fn [] item/.Label:label)) " &
      "(macro with_two [body...] `(do " & two & " %body...)) " &
      "(let kept (escaping)) " &
      "[(one_fn) (two_fn) (one_fn) (two_fn) (kept) (with_two item/.Label:label) " &
      " (label_one item) (sibling item) " &
      " (try item/.Label:label catch Any \"hidden\")]").print() ==
      "[\"one\" \"two\" \"one\" \"two\" \"one\" \"two\" \"one\" \"hidden\" \"hidden\"]"
    # Impls never shadow: an identical pair already visible is a no-op, a
    # different provider of a visible pair is a conflict, and the conflict
    # leaves the visible pair in place.
    check runProgram(header & one &
      " (fn same [] " & one & " item/.Label:label) " &
      "(fn other [] " & two & " item/.Label:label) " &
      "[(same) (try (other) catch Any \"conflict\") item/.Label:label]").print() ==
      "[\"one\" \"conflict\" \"one\"]"
    var diagnostic = ""
    try:
      discard runProgram(header &
        "(fn nested [] " & one & " ((fn [] " & two & " item/.Label:label))) (nested)")
    except GeneError as error:
      diagnostic = error.msg
    check "duplicate visible impl Label for Item" in diagnostic

  test "a module's imported impls are all in place before its first statement runs":
    writeModule("fin4_proto.gene",
      "(protocol Label (message label [self] : Str)) (type Item) (type Other)")
    for (name, text) in [("fin4_a", "item"), ("fin4_b", "other")]:
      writeModule(name & ".gene",
        "(import [Label Item Other] ^from \"./fin4_proto\") " &
        "(impl Label for " & (if text == "item": "Item" else: "Other") &
        " ^^export (message label [self] : Str \"" & text & "\"))")
    writeModule("fin4_root.gene",
      "(import [Label Item Other] ^from \"./fin4_proto\") " &
      "(import_impl Label for Item ^from \"./fin4_a\") " &
      "(import_impl Label for Other ^from \"./fin4_b\") " &
      "(var first ((Item) .Label:label)) " &
      "(var second ((Other) .Label:label))")
    check runProgram(
      "(import [first second] ^from \"./fin4_root\") [first second]").print() ==
      "[\"item\" \"other\"]"

  test "import_impl rejects positional from and malformed source properties":
    for (source, expected) in [
      ("(import_impl P for T from \"./provider\")", "`from` was removed; use `^from"),
      ("(import_impl P for T)", "import_impl requires:"),
      ("(import_impl P for ^from \"./provider\")", "import_impl requires:"),
      ("(import_impl P T ^from \"./provider\")", "import_impl requires:"),
      ("(import_impl P for T extra ^from \"./provider\")", "import_impl requires:"),
      ("(import_impl P for T ^from provider)", "^from must be a path string"),
      ("(import_impl P for T ^from 42)", "^from must be a path string"),
      ("(import_impl P for T ^from nil)", "^from must be a path string"),
      ("(import_impl P for T ^^from)", "^from must be a path string"),
      ("(import_impl P for T ^from \"./provider\" ^^export)", "unexpected option: ^export"),
      ("(import_impl P ^for T ^from \"./provider\")", "unexpected option: ^for")
    ]:
      var diagnostic = ""
      try:
        discard compileSource(source)
      except GeneError as error:
        diagnostic = error.msg
      checkpoint source
      check expected in diagnostic

  test "only exported scoped impls are importable":
    writeModule("export_base.gene",
      "(protocol P (message value [self])) (type T ^props {})")
    writeModule("canonical_export.gene",
      "(protocol P (message value [self])) (type T ^props {}) " &
      "(impl P for T ^^export (message value [self] 1))")
    expect GeneError:
      discard runProgram("(import * : bad ^from \"./canonical_export\")")

    writeModule("private_ext.gene",
      "(import [P T] ^from \"./export_base\") " &
      "(impl P for T (message value [self] 1))")
    expect GeneError:
      discard runProgram("(import [P T] ^from \"./export_base\") " &
        "(import_impl P for T ^from \"./private_ext\")")

    writeModule("overlay_export.gene",
      "(import [P T] ^from \"./export_base\") " &
      "(fn install [] " &
      "  (impl P for T ^^export (message value [self] 1))) " &
      "(install)")
    expect GeneError:
      discard runProgram("(import * : bad ^from \"./overlay_export\")")

  test "protocol-typed boundaries use their declaration module":
    writeModule("typed_base.gene",
      "(protocol Named (message name [self] : Str)) " &
      "(type User ^props {^name Str})")
    writeModule("typed_ext.gene",
      "(import [Named User] ^from \"./typed_base\") " &
      "(impl Named for User ^^export " &
      "  (message name [self] : Str self/name))")
    writeModule("typed_lib.gene",
      "(import [Named] ^from \"./typed_base\") " &
      "(fn accept [x : Named] true) " &
      "(fn count [xs : (List Named)] (xs .size)) " &
      "(type Box ^props {^item Named})")
    check runProgram(
      "(import [Named User] ^from \"./typed_base\") " &
      "(import [accept count Box] ^from \"./typed_lib\") " &
      "(import_impl Named for User ^from \"./typed_ext\") " &
      "(fn local_accept [x : Named] true) " &
      "(type LocalBox ^props {^item Named}) " &
      "(var u (User ^name \"Ada\")) " &
      "(var local_box (LocalBox ^item u)) " &
      "[(local_accept u) local_box/item/name " &
      " (try (accept u) catch Any false) " &
      " (try (count [u]) catch Any false) " &
      " (try (Box ^item u) catch Any false)]").print() ==
      "[true \"Ada\" false false false]"

  test "conflicting explicitly imported scoped impls are rejected":
    writeModule("json.gene",
      "(protocol ToJson (message to_json [self] : Str))")
    writeModule("model.gene",
      "(type User ^props {^name Str})")
    writeModule("json_ext_a.gene",
      "(import [ToJson] ^from \"./json\") " &
      "(import [User] ^from \"./model\") " &
      "(impl ToJson for User ^^export " &
      "  (message to_json [self] : Str self/name))")
    writeModule("json_ext_b.gene",
      "(import [ToJson] ^from \"./json\") " &
      "(import [User] ^from \"./model\") " &
      "(impl ToJson for User ^^export " &
      "  (message to_json [self] : Str \"other\"))")
    expect GeneError:
      discard runProgram("(import [ToJson] ^from \"./json\") " &
        "(import [User] ^from \"./model\") " &
        "(import_impl ToJson for User ^from \"./json_ext_a\") " &
        "(import_impl ToJson for User ^from \"./json_ext_b\")")

  test "reload updates exact scoped imports atomically":
    writeModule("reload_base.gene",
      "(protocol Render (message render [self] : Str)) " &
      "(type Item ^props {})")
    writeModule("reload_ext.gene",
      "(import [Render Item] ^from \"./reload_base\") " &
      "(impl Render for Item ^^export " &
      "  (message render [self] : Str \"one\"))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource(
      "(import [Render Item] ^from \"./reload_base\") " &
      "(import_impl Render for Item ^from \"./reload_ext\")"), scope)
    check run(compileSource("((Item) .Render:render)"), scope).print() == "\"one\""
    let before = app.implActivationEpoch
    writeModule("reload_ext.gene",
      "(import [Render Item] ^from \"./reload_base\") " &
      "(impl Render for Item ^^export " &
      "  (message render [self] : Str \"two\"))")
    discard app.reloadFileModule(modDir / "reload_ext.gene")
    check app.implActivationEpoch == before + 1
    check run(compileSource("((Item) .Render:render)"), scope).print() == "\"two\""

    let stableEpoch = app.implActivationEpoch
    writeModule("reload_ext.gene",
      "(import [Render Item] ^from \"./reload_base\") (var removed true)")
    expect GeneError:
      discard app.reloadFileModule(modDir / "reload_ext.gene")
    check app.implActivationEpoch == stableEpoch
    check run(compileSource("((Item) .Render:render)"), scope).print() == "\"two\""

  test "retained transports follow their authoring module across reload":
    # Contract expectation, written before running: a held Message, a checked
    # Callable view, a closure and a Path all resolve at application time in the
    # scope they were authored in, and reload recomposes that scope's imported
    # impl atomically. So after a same-interface replacement every retained
    # transport and every send site (warmed or new) sees the new body, a
    # rejected replacement leaves the published body intact, and a host scope
    # with no pair still cannot send directly.
    writeModule("ret_base.gene",
      "(protocol Render (message render [] : Str)) (type Item ^props {})")
    writeModule("ret_prov.gene",
      "(import [Render Item] ^from \"./ret_base\") " &
      "(impl Render for Item ^^export (message render [] : Str \"one\"))")
    writeModule("ret_author.gene",
      "(import [Render Item] ^from \"./ret_base\") " &
      "(import_impl Render for Item ^from \"./ret_prov\") " &
      "(fn raw [] Render:render) " &
      "(fn as_view [op : (Callable [Any] Str)] op) " &
      "(fn view [] (as_view Render:render)) " &
      "(fn closure [] (fn [a] a/.Render:render)) " &
      "(fn path_value [] /.Render:render) " &
      "(fn warmed [a] a/.Render:render) " &
      "(fn later [a] a/.Render:render)")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource(
      "(import [Item] ^from \"./ret_base\") " &
      "(import [Render] ^from \"./ret_base\") " &
      "(import [raw view closure path_value warmed later] ^from \"./ret_author\") " &
      "(var item (Item)) (var op (raw)) (var checked (view)) " &
      "(var cl (closure)) (var pv (path_value))"), scope)
    proc observe(): string =
      run(compileSource(
        "[(warmed item) (later item) (op item) (checked item) (cl item) (pv item) " &
        " (try item/.Render:render catch Any \"hidden\")]"), scope).print()
    check observe() ==
      "[\"one\" \"one\" \"one\" \"one\" \"one\" \"one\" \"hidden\"]"
    let before = app.implActivationEpoch
    writeModule("ret_prov.gene",
      "(import [Render Item] ^from \"./ret_base\") " &
      "(impl Render for Item ^^export (message render [] : Str \"two\"))")
    discard app.reloadFileModule(modDir / "ret_prov.gene")
    check app.implActivationEpoch == before + 1
    check observe() ==
      "[\"two\" \"two\" \"two\" \"two\" \"two\" \"two\" \"hidden\"]"
    # A rejected replacement (the export disappears) leaves the published body.
    let stable = app.implActivationEpoch
    writeModule("ret_prov.gene",
      "(import [Render Item] ^from \"./ret_base\") (var removed true)")
    expect GeneError:
      discard app.reloadFileModule(modDir / "ret_prov.gene")
    check app.implActivationEpoch == stable
    check observe() ==
      "[\"two\" \"two\" \"two\" \"two\" \"two\" \"two\" \"hidden\"]"
    # A retained operation applied to a fresh receiver still resolves in its
    # authored scope, not at the host.
    check run(compileSource("(op (Item))"), scope).print() == "\"two\""

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

  test "load and reload accept message-free ^impl declarations without impls":
    writeModule("reload_marker.gene",
      "(protocol Marker) (type Token ^props {} ^impl [Marker Send])")
    let app = newApplication(modDir)
    discard app.loadFileModule(modDir / "reload_marker.gene")
    writeModule("reload_marker.gene",
      "(protocol Marker) (type Token ^props {} ^impl [Marker Send]) ")
    discard app.reloadFileModule(modDir / "reload_marker.gene")
    let scope = newGlobalScope(app)
    check run(compileSource(
      "(import [Marker Token] ^from \"./reload_marker\") " &
      "(match (Token) (when (m : Marker) true) (else false))"), scope).print() == "true"

  test "reload recomposes inherited impl entries through scoped imports":
    writeModule("self_base.gene", """
      (protocol P (message value [] : Int))
      (type Base ^props {}) (type Child : Base ^props {})
    """)
    writeModule("self_parent.gene", """
      (import [P Base] ^from "./self_base")
      (impl P for Base ^^export (message value [] : Int 1))
    """)
    writeModule("self_child.gene", """
      (import [P Base Child] ^from "./self_base")
      (import_impl P for Base ^from "./self_parent")
      (impl P for Child ^^export)
    """)
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource("""
      (import [P Child] ^from "./self_base")
      (import_impl P for Child ^from "./self_child")
      (fn use_child [] ((Child) .P:value))
    """), scope)
    check run(compileSource("(use_child)"), scope).print() == "1"
    writeModule("self_parent.gene", """
      (import [P Base] ^from "./self_base")
      (impl P for Base ^^export (message value [] : Int 2))
    """)
    let epoch = app.implActivationEpoch
    discard app.reloadFileModule(modDir / "self_parent.gene")
    check app.implActivationEpoch == epoch + 1
    check run(compileSource("(use_child)"), scope).print() == "2"
    # The caller imported only the composed child pair, not the parent pair.
    expect GeneError:
      discard run(compileSource("(import [Base] ^from \"./self_base\") ((Base) .P:value)"), scope)

  test "new canonical ancestor bindings cannot rewrite a scoped child conformance":
    let app = newApplication(modDir)
    let home = newGlobalScope(app)
    discard run(compileSource("""
      (protocol P (message value [] : Int))
      (type Base ^props {}) (type Child : Base ^props {})
    """, useLocalSlots = false), home)
    let scope = newGlobalScope(app)
    # Selected imports preserve these same runtime identities. This second
    # root owns neither operand, so its static impl is scoped and indexed.
    scope.define("P", home.lookup("P"))
    scope.define("Child", home.lookup("Child"))
    discard run(compileSource("(impl P for Child (message value [] : Int 7))",
                              useLocalSlots = false), scope)
    let epoch = app.implActivationEpoch
    # Execute a later static unit in P's existing home, preserving both type
    # and protocol identity. A reload that redefined P would test a different
    # protocol and could fail for an unrelated interface change instead.
    var rejected = false
    try:
      discard run(compileSource("(impl P for Base (message value [] : Int 1))",
                                useLocalSlots = false), home)
    except GeneError as error:
      rejected = true
      check "Self bindings" in error.msg
    check rejected
    check app.implActivationEpoch == epoch
    check run(compileSource("((Child) .P:value)"), scope).print() == "7"

  test "failed module activation does not publish earlier staged impls":
    writeModule("base.gene",
      "(protocol P (message value [self] : Str)) " &
      "(type A ^props {}) (type B ^props {}) " &
      "(impl P for B (message value [self] : Str \"existing\"))")
    writeModule("ext_bad.gene",
      "(import [P A B] ^from \"./base\") " &
      "(impl P for A (message value [self] : Str \"staged\")) " &
      "(impl P for B (message value [self] : Str \"conflict\"))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource(
      "(import [P A B] ^from \"./base\")"), scope)
    expect GeneError:
      discard run(compileSource("(import * : bad ^from \"./ext_bad\")"), scope)
    expect GeneError:
      discard run(compileSource("((A) .P:value)"), scope)
    check run(compileSource("((B) .P:value)"), scope).print() ==
      "\"existing\""

  test "package-root-relative paths (/x and bare x)":
    writeModule("math.gene", "(var pi 3) (fn add [a b] (+ a b))")
    check runProgram("(import [pi] ^from \"/math\") pi").print() == "3"
    check runProgram("(import [add] ^from \"math\") (add 1 2)").print() == "3"

  test "module paths cannot escape the package root":
    let outside = modDir & "_outside.gene"
    writeFile(outside, "(var secret 99)")
    try:
      discard runProgram("(import [secret] ^from \"../gene_module_tests_outside\") secret")
      fail()
    except GeneError as e:
      check e.msg.contains("module path escapes package root")
    finally:
      removeFile(outside)

  test "missing export raises":
    writeModule("math.gene", "(var pi 3)")
    expect GeneError: discard runProgram("(import [nope] ^from \"./math\")")

  test "selected imports reject duplicate local bindings":
    writeModule("math.gene", "(var pi 3) (var tau 6)")
    expect GeneError:
      discard runProgram("(import [pi] ^from \"./math\") (var pi 4)")
    expect GeneError:
      discard runProgram("(import [pi : n, tau : n] ^from \"./math\")")

  test "missing module raises":
    expect GeneError: discard runProgram("(import [x] ^from \"./does-not-exist\")")

  test "module aliases and re-exports contribute protocol interfaces":
    writeModule("interface_base.gene",
      "(protocol Render (message render [self] : Str)) " &
      "(type T ^props {}) " &
      "(impl Render for T (message render [self] : Str \"interface\"))")
    writeModule("interface_mid.gene",
      "(import [Render T] ^from \"./interface_base\" ^^export)")
    check runProgram("(import * : base ^from \"./interface_base\") " &
      "((base/T) .base/Render:render)").print() == "\"interface\""
    check runProgram("(import [Render T] ^from \"./interface_mid\") " &
      "((T) .Render:render)").print() == "\"interface\""

  test "caught import failures do not establish protocol candidates":
    writeModule("candidate_type.gene", "(type T ^props {})")
    var message = ""
    try:
      discard runProgram("(import [T] ^from \"./candidate_type\") " &
        "(try (import [Render] ^from \"./missing_protocol\") catch Any nil) " &
        "((T) .render)")
    except GeneError as error:
      message = error.msg
    check message.contains("no message 'render' on T")
    check not message.contains("uninitialized protocol candidate")

  test "runtime import cycles have a runtime-phase diagnostic":
    writeModule("a.gene", "(import * : b ^from \"./b\") (var x 1)")
    writeModule("b.gene", "(import * : a ^from \"./a\") (var y 2)")
    var message = ""
    try:
      discard runProgram("(import * : a ^from \"./a\") a/x")
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
    check runProgram("(import [Boom, boom] ^from \"./erra\") " &
      "(fn f ^errors [Boom] [] (boom)) " &
      "(try (f) catch Boom $err/message)").print() == "\"x\""

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
      "(import * : gene ^from \"./reserved_source\")"
    ]:
      if source.contains("reserved_source"):
        writeModule("reserved_source.gene", "(var value 1)")
      expect GeneError:
        discard runProgram(source)

  test "module declarations do not include built-ins":
    writeModule("decls2.gene", "(var only-me 1)")
    # Filtering the module's declarations for a built-in name finds nothing,
    # because built-ins live in the shared parent scope, not the module root.
    check runProgram("(import * : m ^from \"./decls2\") " &
      "(var ds ($filter ($declarations m) (fn [d] (== d/name \"map\")))) " &
      "(ds .has_next)").print() == "false"
    check runProgram("(import * : m ^from \"./decls2\") " &
      "(var ds ($filter ($declarations m) (fn [d] (== d/name \"this_mod\")))) " &
      "(ds .has_next)").print() == "false"

  test "selected imports cannot pull built-ins out of a module":
    writeModule("decls2.gene", "(var only-me 1)")
    expect GeneError:
      discard runProgram("(import [map] ^from \"./decls2\")")

  test "selected imports cannot pull this_mod out of a module":
    writeModule("decls3.gene", "(var only-me 1)")
    expect GeneError:
      discard runProgram("(import [this_mod] ^from \"./decls3\")")

suite "modules — diagnostics advice and lexical import paths":
  setup:
    removeDir(modDir)
    createDir(modDir)

  test "advice treats an exported provider as exported after another module imported it":
    writeModule("adv_proto.gene",
      "(protocol Shown (message show [] : Str)) (type Widget ^props {})")
    writeModule("adv_prov.gene",
      "(import [Shown Widget] ^from \"./adv_proto\") " &
      "(impl Shown for Widget ^^export (message show [] : Str \"w\"))")
    writeModule("adv_importer.gene",
      "(import [Shown Widget] ^from \"./adv_proto\") " &
      "(import_impl Shown for Widget ^from \"./adv_prov\") (var done 1)")
    writeModule("adv_main.gene",
      "(import [Shown Widget] ^from \"./adv_proto\") " &
      "(import [done] ^from \"./adv_importer\") " &
      "(var shown ((Widget) .Shown:show))")
    var msg = ""
    try:
      discard runProgram("(import [shown] ^from \"./adv_main\")")
    except GeneError as error:
      msg = error.msg
    check "no implementation of message 'show'" in msg
    check "not exported" notin msg
    check "^^export" notin msg
    # The suggestion is a portable spelling: relative to the checking module,
    # no extension, and no absolute filesystem path inside the copied source.
    check "(import_impl Shown for Widget ^from \"./adv_prov\")" in msg
    check "^from \"" & modDir notin msg

  test "duplicate impl diagnostics name both origins and the migration":
    writeModule("dup_proto.gene",
      "(protocol P (message m [] : Int)) (type T ^props {}) " &
      "(impl P for T (message m [] : Int 1))")
    writeModule("dup_ext.gene",
      "(import [P T] ^from \"./dup_proto\") " &
      "(impl P for T ^^export (message m [] : Int 2))")
    var msg = ""
    try:
      discard runProgram("(import [P T] ^from \"./dup_proto\") " &
        "(import_impl P for T ^from \"./dup_ext\")")
    except GeneError as error:
      msg = error.msg
    check "duplicate visible impl P for T" in msg
    check "canonical impl from" in msg
    check "dup_proto.gene" in msg
    check "scoped impl from" in msg
    check "dup_ext.gene" in msg
    check "its own protocol" in msg
    # Two scoped providers for one pair name both modules without the advice
    # that only applies to a canonical impl.
    writeModule("dup_scoped_proto.gene",
      "(protocol Q (message m [] : Int)) (type U ^props {})")
    for name in ["dup_a", "dup_b"]:
      writeModule(name & ".gene",
        "(import [Q U] ^from \"./dup_scoped_proto\") " &
        "(impl Q for U ^^export (message m [] : Int 1))")
    msg = ""
    try:
      discard runProgram("(import [Q U] ^from \"./dup_scoped_proto\") " &
        "(import_impl Q for U ^from \"./dup_a\") " &
        "(import_impl Q for U ^from \"./dup_b\")")
    except GeneError as error:
      msg = error.msg
    check "dup_a.gene" in msg
    check "dup_b.gene" in msg
    check "its own protocol" notin msg

  test "incompatible Self bindings explain the parent and child dependency":
    writeModule("self_proto.gene",
      "(protocol Format (message head [] : Str)) " &
      "(type Article ^props {}) (type Note : Article ^props {})")
    writeModule("self_child.gene",
      "(import [Format Note] ^from \"./self_proto\") " &
      "(impl Format for Note ^^export (message head [] : Str \"n\"))")
    writeModule("self_parent.gene",
      "(import [Format Article] ^from \"./self_proto\") " &
      "(impl Format for Article ^^export (message head [] : Str \"a\"))")
    var msg = ""
    try:
      discard runProgram("(import [Format Article Note] ^from \"./self_proto\") " &
        "(import_impl Format for Note ^from \"./self_child\") " &
        "(import_impl Format for Article ^from \"./self_parent\")")
    except GeneError as error:
      msg = error.msg
    check "incompatible established Self bindings for Format on Note and Article" in msg
    check "self_child.gene" in msg
    check "self_parent.gene" in msg
    check "parent pair is visible" in msg

  test "an import executed inside a library function resolves its path against the library":
    # The entry sits one directory above the library, so a path resolved against
    # the entry (the old behavior) would look for ./proto beside the entry.
    createDir(modDir / "lib")
    writeFile(modDir / "lib" / "proto.gene",
      "(protocol Label (message label [self] : Str)) (type Item)")
    writeFile(modDir / "lib" / "policy.gene",
      "(import [Label Item] ^from \"./proto\") " &
      "(impl Label for Item ^^export (message label [self] : Str \"lib\"))")
    writeFile(modDir / "lib" / "api.gene",
      "(import [Label] ^from \"./proto\") " &
      "(fn late_make [] (import [Item] ^from \"./proto\") (Item)) " &
      "(fn labelled [item] (import [Item] ^from \"./proto\") " &
      "  (import_impl Label for Item ^from \"./policy\") item/.Label:label)")
    check runProgram(
      "(import [late_make] ^from \"./lib/api\") " &
      "(late_make) nil").print() == "nil"
    # import_impl executed in a library function resolves the same way.
    check runProgram(
      "(import [late_make labelled] ^from \"./lib/api\") " &
      "(labelled (late_make))").print() == "\"lib\""

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
      "((T) .Show:show)"),
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
      "(eval (quote ((T) .Show:show)) ^in e)").print() == "\"ok\""

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
      "(import [T] ^from \"./shared\") (fn marker [] 1)")
    # shared-first, then the local module that also imports it
    check runProgram("(import [Show T] ^from \"./shared\") " &
      "(import [marker] ^from \"./uses_shared\") " &
      "[((T) .Show:show) (marker)]").print() == "[\"shared\" 1]"
    # local-module-first (the previously working order must stay working)
    check runProgram("(import [marker] ^from \"./uses_shared\") " &
      "(import [Show T] ^from \"./shared\") " &
      "[((T) .Show:show) (marker)]").print() == "[\"shared\" 1]"

  test "conflicting impls for one protocol and receiver still raise":
    writeModule("conflict_shared.gene",
      "(protocol Show2 (message show2 [self] : Str)) " &
      "(type U ^props {})")
    writeModule("impl_one.gene",
      "(import [Show2 U] ^from \"./conflict_shared\") " &
      "(impl Show2 for U ^^export " &
      "  (message show2 [self] : Str \"one\"))")
    writeModule("impl_two.gene",
      "(import [Show2 U] ^from \"./conflict_shared\") " &
      "(impl Show2 for U ^^export " &
      "  (message show2 [self] : Str \"two\"))")
    expect GeneError:
      discard runProgram("(import [Show2 U] ^from \"./conflict_shared\") " &
        "(import_impl Show2 for U ^from \"./impl_one\") " &
        "(import_impl Show2 for U ^from \"./impl_two\") nil")

suite "modules — the sandbox loader (design §D5)":
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
    removeFile(modDir / "gene_sandbox_escape")

  test "a denied namespace cannot be reached, with no import line":
    ## §D5.1's exact program, verbatim.
    writeModule("evil.gene",
      "($fs/write_text \"" &
      (modDir / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"escaped\")")
    var raised = false
    try:
      discard runSandboxProgram(loadSandboxed(modDir, "evil.gene", "[]"))
    except GeneError as error:
      raised = true
      check "cannot call $fs/write_text: gene/fs is not defined here" in error.msg
    check raised
    check not fileExists(modDir / "gene_sandbox_escape")

  test "a granted namespace works after initialization":
    writeModule("good.gene",
      "(fn write_it [p : Str] : Int ($fs/write_text p \"allowed\") 1)")
    check runSandboxProgram(
      "(var m " & loadSandboxed(modDir, "good.gene", "[\"fs\"]") & ") " &
      "(m/write_it \"" &
      (modDir / "gene_sandbox_escape").replace("\\", "/") & "\")"
      ).print() == "1"
    check fileExists(modDir / "gene_sandbox_escape")

  test "a macro body that uses only $ names keeps the sandbox's grants":
    ## A `$name` is `gene/name`. A macro body that uses nothing else no longer
    ## re-runs its defining file at compile time, so it must still resolve
    ## `gene` from the sandbox's restricted root, not from the host's.
    let escape = (modDir / "gene_sandbox_escape").replace("\\", "/")
    writeModule("macro_fs.gene",
      "(macro touch_it [] (do ($fs/write_text \"" & escape & "\" \"macro\") 1)) " &
      "(fn run [] (touch_it))")
    var raised = false
    try:
      discard runSandboxProgram("(var m " &
        loadSandboxed(modDir, "macro_fs.gene", "[]") & ") (m/run)")
    except GeneError as error:
      raised = true
      check "gene/fs is not defined here" in error.msg
    check raised
    check not fileExists(modDir / "gene_sandbox_escape")
    check runSandboxProgram("(var m " &
      loadSandboxed(modDir, "macro_fs.gene", "[\"fs\"]") & ") (m/run)").print() == "1"
    check readFile(modDir / "gene_sandbox_escape") == "macro"

  test "the restriction reaches a module the sandboxed one imports":
    ## The half that makes it a boundary rather than a speed bump: a mod that
    ## cannot name `$fs` must not be able to import a friend that can.
    writeModule("helper.gene",
      "(fn sneak [] : Str ($fs/write_text \"" &
      (modDir / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"via import\") \"wrote\")")
    writeModule("viaimport.gene",
      "(import [sneak] ^from \"./helper\") (sneak)")
    expect GeneError:
      discard runSandboxProgram(loadSandboxed(modDir, "viaimport.gene", "[]"))
    check not fileExists(modDir / "gene_sandbox_escape")

  test "calling into a sandboxed module later is still restricted":
    ## The restriction is on the module's scope, not on the load, so a function
    ## exported *out* of a sandbox carries it — which is what makes a mod API
    ## safe to call back into on a tick.
    writeModule("quiet_helper.gene",
      "(fn sneak [p : Str] : Str ($fs/write_text p \"w\") \"wrote\")")
    writeModule("quiet.gene",
      "(import [sneak] ^from \"./quiet_helper\") " &
      "(fn try_it [p : Str] : Str (sneak p))")
    expect GeneError:
      discard runSandboxProgram(
        "(var m " & loadSandboxed(modDir, "quiet.gene", "[]") & ") " &
        "(m/try_it \"" &
        (modDir / "gene_sandbox_escape").replace("\\", "/") & "\")")
    check not fileExists(modDir / "gene_sandbox_escape")

  test "trusted code keeps full authority over a file a sandbox also loaded":
    ## The module cache is keyed by the grant set. Without that it is a hole in
    ## both directions — a module the engine already loaded with full authority
    ## handed to a mod that must not have it, and a module first loaded under a
    ## sandbox coming back stripped for trusted code. This is the second
    ## direction, which is the one that would look like a mysterious bug rather
    ## than a breach.
    writeModule("shared_helper.gene",
      "(fn sneak [p : Str] : Str ($fs/write_text p \"w\") \"wrote\")")
    writeModule("sandboxed_user.gene",
      "(import [sneak] ^from \"./shared_helper\") (fn noop [] : Int 1)")
    check runSandboxProgram(
      loadSandboxed(modDir, "sandboxed_user.gene", "[]") & " " &
      "(import [sneak] ^from \"./shared_helper\") " &
      "(sneak \"" &
      (modDir / "gene_sandbox_escape").replace("\\", "/") & "\")"
      ).print() == "\"wrote\""
    check fileExists(modDir / "gene_sandbox_escape")

  test "a sandbox cannot load another sandbox":
    ## Nesting would let a mod choose its own grants, and the grants a mod gets
    ## are the manifest's to decide.
    writeModule("inner.gene", "(fn ok [] : Int 1)")
    writeModule("nester.gene", loadSandboxed(modDir, "inner.gene", "[\"fs\"]"))
    expect GeneError:
      discard runSandboxProgram(loadSandboxed(modDir, "nester.gene", "[\"runtime\"]"))

  test "an unknown grant is refused rather than ignored":
    ## A manifest asking for "filesystem" instead of "fs" would otherwise load
    ## with less authority than it declared and fail somewhere unrelated.
    writeModule("plain.gene", "(fn ok [] : Int 1)")
    expect GeneError:
      discard runSandboxProgram(loadSandboxed(modDir, "plain.gene", "[\"filesystem\"]"))

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
      "(import [Reg] ^from \"../../../host_type\") " &
      "(fn take_it [r : Reg] : Int r/n)")
    check runProgramInOwnApp(
      "(import [Reg] ^from \"./host_type\") " &
      "(var m " & loadSandboxed(modRoot, "src/shared_mod.gene", "[]",
                                "[\"" & (modDir / "host_type.gene").replace("\\", "/") & "\"]") & ") " &
      "(m/take_it (new Reg 7))").print() == "7"

  test "external source directories retain shared types and relative dependencies":
    let externalRoot = getTempDir() / "gene_external_module_tests"
    removeDir(externalRoot)
    createDir(externalRoot / "src")
    defer: removeDir(externalRoot)
    createDir(modDir / "src")
    writeModule("src/plugin_api.gene",
      "(type Reg ^props {^n Int})")
    # A same-named owned file is still relative to the plugin, not redirected
    # to the host's shared contract.
    writeFile(externalRoot / "src" / "plugin_api.gene", "(var n 5)")
    writeFile(externalRoot / "src" / "helper.gene",
      "(import [n] ^from \"./plugin_api\") (fn offset [] n)")
    writeFile(externalRoot / "src" / "plugin.gene",
      "(import [Reg] ^from \"src/plugin_api.gene\") " &
      "(import [offset] ^from \"./helper\") " &
      "(fn take_it [r : Reg] : Int (+ r/n (offset)))")
    check runProgramInOwnApp(
      "(import [Reg] ^from \"src/plugin_api.gene\") " &
      "(var m " & loadSandboxed(externalRoot, "src/plugin.gene", "[]",
                                "[\"src/plugin_api.gene\"]") & ") " &
      "(import [Reg : StillReg] ^from \"src/plugin_api.gene\") " &
      "(m/take_it (StillReg ^n 7))").print() == "12"

  test "complete grants see live canonical host implementations through a shared contract":
    let pluginRoot = modDir / "mods" / "full_contract"
    createDir(pluginRoot)
    writeModule("host_api.gene",
      "(protocol PublicHost (message state [] : Int))")
    writeFile(pluginRoot / "plugin.gene",
      "(import [PublicHost] ^from \"host_api.gene\") " &
      "(fn read [host] : Int (host .PublicHost:state)) " &
      "(fn experimental_hidden [] ($absent? genex))")
    let program =
      "(import [PublicHost] ^from \"./host_api\") (type Host) " &
      "(var m " & loadSandboxed(pluginRoot, "plugin.gene",
        "($runtime/sandbox_namespaces)", "[\"host_api.gene\"]") & ") " &
      # Register after creating the sandbox root: a copied impl list would
      # still miss the implementation and make a cached root stale.
      "(impl PublicHost for Host (message state [] : Int 7)) " &
      "[(m/read (Host)) (m/experimental_hidden)]"
    check runSandboxProgram(program).print() == "[7 true]"
    expect GeneError:
      discard runSandboxProgram(program.replace(
        "($runtime/sandbox_namespaces)", "[\"fs\"]"))

  test "external sources cannot escape their directory or reach unshared host modules":
    let externalRoot = getTempDir() / "gene_external_module_tests"
    removeDir(externalRoot)
    createDir(externalRoot)
    defer: removeDir(externalRoot)
    writeModule("secret.gene", "(var secret 42)")
    writeFile(externalRoot / "plugin.gene",
      "(import [secret] ^from \"secret.gene\") secret")
    expect GeneError:
      discard runSandboxProgram(loadSandboxed(externalRoot, "plugin.gene", "[]"))
    expect GeneError:
      discard runSandboxProgram(loadSandboxed(externalRoot,
        "../gene_module_tests/secret.gene", "[]"))
    when defined(posix):
      createSymlink(modDir / "secret.gene", externalRoot / "linked.gene")
      expect GeneError:
        discard runSandboxProgram(loadSandboxed(externalRoot, "linked.gene", "[]"))
    writeFile(externalRoot / "plugin.gene",
      "(fn touch [p : Str] ($fs/write_text p \"external\"))")
    expect GeneError:
      discard runSandboxProgram("(var m " &
        loadSandboxed(externalRoot, "plugin.gene", "[]") & ") " &
        "(m/touch \"" & (modDir / "gene_sandbox_escape").replace("\\", "/") & "\")")
    discard runSandboxProgram("(var m " &
      loadSandboxed(externalRoot, "plugin.gene", "[\"fs\"]") & ") " &
      "(m/touch \"" & (modDir / "gene_sandbox_escape").replace("\\", "/") & "\")")
    check readFile(modDir / "gene_sandbox_escape") == "external"

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
      "(fn go [] : Nil ($fs/write_text \"" &
      (modDir / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"escaped\"))")
    writeFile(modRoot / "src" / "a" / "deep_mod.gene",
      "(import [go] ^from \"../../free\") (fn run [] : Nil (go))")
    expect GeneError:
      discard runSandboxProgram(
        "(var m " & loadSandboxed(modRoot, "src/a/deep_mod.gene", "[]") & ") " &
        "(m/run)")
    check not fileExists(modDir / "gene_sandbox_escape")
    # The control, so this cannot rot into a pass for the wrong reason. Same
    # layout, same import, `fs` granted: it must load and write. Without this the
    # case above would still be green if `../../free` simply stopped resolving.
    discard runSandboxProgram(
      "(var m " & loadSandboxed(modRoot, "src/a/deep_mod.gene", "[\"fs\"]") & ") " &
      "(m/run)")
    check fileExists(modDir / "gene_sandbox_escape")

  test "an out-of-dir import the host did not share is refused":
    ## §D5.2 said "the restriction covers everything the module imports" and did
    ## not do that: a module outside `dir` loaded with **full host authority**, and
    ## the mod writes the import path, so the reachable set was the whole package
    ## root. Measured against the real layout: a mod granted nothing imported the
    ## host's `server/storage.gene`, called `open_world`/`write_meta`, and wrote a
    ## file of its choosing. The host cannot meet "do not leave reachable code
    ## where a mod can reach it" — so the host names the shared set instead.
    writeModule("host_authority.gene",
      "(fn touch [p : Str] : Str ($fs/write_text p \"host\") \"w\")")
    let modRoot = modDir / "mods" / "reacher"
    createDir(modRoot / "src")
    writeFile(modRoot / "src" / "reacher.gene",
      "(import [touch] ^from \"../../../host_authority\") " &
      "(fn go [p : Str] : Str (touch p))")
    expect GeneError:
      discard runSandboxProgram(loadSandboxed(modRoot, "src/reacher.gene", "[]"))
    check not fileExists(modDir / "gene_sandbox_escape")
    # The control, so this is a refusal about *authority* and not a broken path:
    # named as shared, the identical import loads and works.
    check runSandboxProgram(
      "(var m " & loadSandboxed(modRoot, "src/reacher.gene", "[]",
        "[\"" & (modDir / "host_authority.gene").replace("\\", "/") & "\"]") &
      ") (m/go \"" &
      (modDir / "gene_sandbox_escape").replace("\\", "/") & "\")"
      ).print() == "\"w\""
    check fileExists(modDir / "gene_sandbox_escape")

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
      "($fs/write_text \"" &
      (modDir / "gene_sandbox_escape").replace("\\", "/") &
      "\" \"grants I chose myself\")")
    writeFile(modRoot / "src" / "climber2.gene",
      "(fn escalate [] : Any ($runtime/load_sandboxed \"" &
      modRoot.replace("\\", "/") & "/inner\" \"inner.gene\" [\"fs\"] []))")
    expect GeneError:
      discard runSandboxProgram(
        "(var m " & loadSandboxed(modRoot, "src/climber2.gene",
                                  "[\"runtime\"]") & ") (m/escalate)")
    check not fileExists(modDir / "gene_sandbox_escape")

  test "a granted `runtime` cannot create a sandbox transaction":
    let modRoot = modDir / "mods" / "transaction_climber"
    createDir(modRoot)
    writeFile(modRoot / "plugin.gene",
      "(fn escalate [] ($runtime/sandbox_transaction))")
    expect GeneError:
      discard runSandboxProgram(
        "(var m " & loadSandboxed(modRoot, "plugin.gene", "[\"runtime\"]") &
        ") (m/escalate)")

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
      "(import [load_it] ^from \"../../../host_loader\") " &
      "(fn go [] : Any (load_it \"x\" \"y.gene\"))")
    expect GeneError:
      discard runSandboxProgram(loadSandboxed(modRoot, "src/climber3.gene", "[]"))

  test "an entry that points out of its own directory is refused":
    ## The other half of the same rule. If the entry could escape `dir`, the mod's
    ## own code would load unrestricted and the boundary would have the subject on
    ## the wrong side of it.
    writeModule("outside.gene", "(fn ok [] : Int 1)")
    createDir(modDir / "mods" / "climber")
    expect GeneError:
      discard runSandboxProgram(
        loadSandboxed(modDir / "mods" / "climber", "../../outside.gene", "[]"))

  test "computation is not withheld — a sandbox can still do arithmetic":
    ## The list is what reaches outside the process. A sandbox that could not
    ## use `math` or `str` would be one that cannot work rather than one that
    ## cannot harm.
    writeModule("compute.gene",
      "(fn f [] : Int ($math/abs -3))")
    discard runSandboxProgram(loadSandboxed(modDir, "compute.gene", "[]"))

  test "sandbox generations stay prospective until commit and release cleanly":
    let root = modDir / "generation_basic"
    createDir(root)
    writeFile(root / "plugin.gene", "(var answer 42)")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let beforeModules = app.moduleCacheEntryCount()
    let beforeHeaders = app.moduleCompileHeaderCount()
    let beforeArtifacts = app.moduleCompileArtifactCount()
    check run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var generation " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"plugin.gene\" ^grants [] ^shared [] ^label \"basic\" " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
      "(var candidate (generation .module)) " &
      "candidate/answer"), scope).print() == "42"
    check app.moduleCacheEntryCount() == beforeModules
    check app.moduleCompileHeaderCount() == beforeHeaders
    check app.moduleCompileArtifactCount() == beforeArtifacts

    discard run(compileSource("(tx .commit)"), scope)
    check app.moduleCacheEntryCount() == beforeModules + 1
    check app.moduleCompileHeaderCount() == beforeHeaders + 1
    check app.moduleCompileArtifactCount() == beforeArtifacts + 1

    discard run(compileSource("(generation .release)"), scope)
    check app.moduleCacheEntryCount() == beforeModules
    check app.moduleCompileHeaderCount() == beforeHeaders
    check app.moduleCompileArtifactCount() == beforeArtifacts
    discard run(compileSource("(generation .release)"), scope)

  test "discard is idempotent and invalidates prepared generations":
    let root = modDir / "generation_discard"
    createDir(root)
    writeFile(root / "plugin.gene", "(var answer 7)")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let beforeModules = app.moduleCacheEntryCount()
    let beforeHeaders = app.moduleCompileHeaderCount()
    let beforeArtifacts = app.moduleCompileArtifactCount()
    let beforeImpls = app.canonicalImplCount()
    discard run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var generation " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"plugin.gene\" ^grants [] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}}))"),
      scope)
    discard run(compileSource("(tx .discard) (tx .discard)"), scope)
    check app.moduleCacheEntryCount() == beforeModules
    check app.moduleCompileHeaderCount() == beforeHeaders
    check app.moduleCompileArtifactCount() == beforeArtifacts
    check app.canonicalImplCount() == beforeImpls
    check run(compileSource(
      "(try (generation .module) false catch Any true)"), scope).boolVal
    check run(compileSource(
      "(try (tx .commit) false catch Any true)"), scope).boolVal

  test "one sandbox transaction commits several generations atomically":
    let root = modDir / "generation_batch"
    createDir(root)
    writeFile(root / "left.gene", "(var answer 20)")
    writeFile(root / "right.gene", "(var answer 22)")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let beforeModules = app.moduleCacheEntryCount()
    discard run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var left (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "  ^entry \"left.gene\" ^grants [] ^shared [] " &
      "  ^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
      "(var right (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "  ^entry \"right.gene\" ^grants [] ^shared [] " &
      "  ^policy {^max_memory_mb 16 ^timeout_ms 1000}}))"),
      scope)
    check app.moduleCacheEntryCount() == beforeModules
    discard run(compileSource("(tx .commit) (tx .commit)",
                              useLocalSlots = false), scope)
    check app.moduleCacheEntryCount() == beforeModules + 2
    check run(compileSource(
      "(var left_module (left .module)) " &
      "(var right_module (right .module)) " &
      "(+ left_module/answer right_module/answer)",
      useLocalSlots = false), scope).intVal == 42
    discard run(compileSource("(left .release) (right .release)",
                              useLocalSlots = false), scope)
    check app.moduleCacheEntryCount() == beforeModules

  test "sandbox transaction commit rejects a changed live module base":
    let root = modDir / "generation_stale"
    createDir(root)
    writeFile(root / "candidate.gene", "(var answer 1)")
    writeFile(root / "live.gene", "(var answer 2)")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    discard run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var generation (tx .prepare {^dir \"" &
      root.replace("\\", "/") & "\" ^entry \"candidate.gene\" " &
      "^grants [] ^shared [] " &
      "^policy {^max_memory_mb 16 ^timeout_ms 1000}}))"),
      scope)
    discard app.loadFileModule(root / "live.gene")
    check run(compileSource(
      "(try (tx .commit) false catch Any true)"), scope).boolVal
    discard run(compileSource("(tx .discard)"), scope)

  test "sandbox generation policy bounds initialization and escaped calls":
    let root = modDir / "generation_policy"
    createDir(root)
    writeFile(root / "bad_top.gene", "(while true nil)")
    writeFile(root / "bad_call.gene",
      "(fn spin [] (while true nil))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let topMessage = run(compileSource(
      "(var top_tx ($runtime/sandbox_transaction)) " &
      "(var top_error (try " &
      "  (top_tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"bad_top.gene\" ^grants [] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 100}}) " &
      "  \"missing\" catch Any $err/message)) " &
      "(top_tx .discard) top_error"), scope).strVal
    check "timeout" in topMessage
    let callMessage = run(compileSource(
      "(var call_tx ($runtime/sandbox_transaction)) " &
      "(var call_generation " &
      "  (call_tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"bad_call.gene\" ^grants [] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 100}})) " &
      "(var call_module (call_generation .module)) " &
      "(var call_error (try (call_module/spin) \"missing\" " &
      "  catch Any $err/message)) " &
      "(call_tx .discard) call_error",
      useLocalSlots = false), scope).strVal
    check "timeout" in callMessage

  test "sandbox generation policy bounds macro expansion and compilation":
    let root = modDir / "generation_compile_policy"
    createDir(root)
    writeFile(root / "large_macro.gene",
      "(macro many [] (while true nil)) " &
      "(var expanded (many))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let beforeModules = app.moduleCacheEntryCount()
    let beforeHeaders = app.moduleCompileHeaderCount()
    let beforeArtifacts = app.moduleCompileArtifactCount()
    let beforeImpls = app.canonicalImplCount()
    let message = run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var compile_error (try " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"large_macro.gene\" ^grants [] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 100}}) " &
      "  \"missing\" catch Any $err/message)) " &
      "(tx .discard) compile_error"), scope).strVal
    check "timeout" in message
    check app.moduleCacheEntryCount() == beforeModules
    check app.moduleCompileHeaderCount() == beforeHeaders
    check app.moduleCompileArtifactCount() == beforeArtifacts
    check app.canonicalImplCount() == beforeImpls

  test "failed preparation leaves the transaction candidate unchanged":
    let root = modDir / "generation_failed_prepare"
    createDir(root)
    writeFile(root / "dependency.gene", "(var leaked 1)")
    writeFile(root / "bad.gene",
      "(import [leaked] ^from \"./dependency\") (while true nil)")
    writeFile(root / "good.gene", "(var answer 42)")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let beforeModules = app.moduleCacheEntryCount()
    let beforeHeaders = app.moduleCompileHeaderCount()
    let beforeArtifacts = app.moduleCompileArtifactCount()
    let beforeImpls = app.canonicalImplCount()
    check run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(try " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"bad.gene\" ^grants [] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}}) " &
      "  false catch Any true)", useLocalSlots = false), scope).boolVal
    discard run(compileSource(
      "(var generation " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"good.gene\" ^grants [] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
      "(tx .commit)", useLocalSlots = false), scope)
    check app.moduleCacheEntryCount() == beforeModules + 1
    check app.moduleCompileHeaderCount() == beforeHeaders + 1
    check app.moduleCompileArtifactCount() == beforeArtifacts + 1
    check app.canonicalImplCount() == beforeImpls
    check run(compileSource(
      "(var candidate (generation .module)) candidate/answer",
      useLocalSlots = false),
      scope).intVal == 42
    discard run(compileSource("(generation .release)"), scope)
    check app.moduleCacheEntryCount() == beforeModules
    check app.moduleCompileHeaderCount() == beforeHeaders
    check app.moduleCompileArtifactCount() == beforeArtifacts

  test "sandbox compilation enforces timeout and memory policies":
    let root = modDir / "generation_compile_limits"
    createDir(root)
    writeFile(root / "simple.gene", "(var answer 1)")
    writeFile(root / "large.gene",
      "(var values [" & repeat(" 1", 100000) & "])")

    proc prepareError(entry, policy: string): string =
      let app = newApplication(modDir)
      let scope = newGlobalScope(app)
      run(compileSource(
        "(var tx ($runtime/sandbox_transaction)) " &
        "(var message (try " &
        "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
        "    ^entry \"" & entry & "\" ^grants [] ^shared [] " &
        "    ^policy " & policy & "}) " &
        "  \"missing\" catch Any $err/message)) " &
        "(tx .discard) message"), scope).strVal

    check "compile timeout" in prepareError(
      "simple.gene",
      "{^max_memory_mb 16 ^timeout_ms 0}")
    check "compile memory" in prepareError(
      "large.gene",
      "{^max_memory_mb 0 ^timeout_ms 1000}")

  test "sandbox generation policy rejects native declarations":
    let root = modDir / "generation_native_policy"
    createDir(root)
    writeFile(root / "native.gene",
      "(ffi/struct CPoint ^fields [[x C/Int]])")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let message = run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var message (try " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"native.gene\" ^grants [\"ffi\"] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}}) " &
      "  \"missing\" catch Any $err/message)) " &
      "(tx .discard) message"), scope).strVal
    check "disables FFI" in message

  test "sandbox preparation does not run unrelated root-lane tasks":
    let root = modDir / "generation_quiescence"
    createDir(root)
    writeFile(root / "plugin.gene",
      "(var candidate_seen ($cell 0)) " &
      "(var candidate_task " &
      "  (spawn ^lane root (candidate_seen .set 1))) " &
      "(await candidate_task) (var answer candidate_seen/.get)")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    check run(compileSource(
      "(var observed ($cell 0)) " &
      "(var unrelated (spawn ^lane root (observed .set 1))) " &
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var generation " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"plugin.gene\" ^grants [] ^shared [] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
      "(var during (observed .get)) " &
      "(tx .discard) (await unrelated) [during (observed .get)]"),
      scope).print() == "[0 1]"

  test "generation graphs include owned, shared, runtime, and compile edges":
    let root = modDir / "generation_graph"
    createDir(root)
    writeFile(root / "macros.gene",
      "(macro add_one [value] `(+ %value 1))")
    writeFile(root / "dep.gene", "(var dep 20)")
    writeModule("generation_shared.gene", "(var shared_value 21)")
    writeFile(root / "plugin.gene",
      "(import [add_one] ^from \"./macros\") " &
      "(import [dep] ^from \"./dep\") " &
      "(import [shared_value] ^from \"../generation_shared\") " &
      "(var answer (add_one (+ dep shared_value)))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let sharedPath = (modDir / "generation_shared.gene").replace("\\", "/")
    let graph = run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var generation " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"plugin.gene\" ^grants [] " &
      "    ^shared [\"" & sharedPath & "\"] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
      "(generation .graph)"), scope)
    check graph.kind == vkMap
    check graph.mapImmutable
    check graph.mapEntries["nodes"].listImmutable
    var sawOwned = false
    var sawShared = false
    var sawRuntime = false
    var sawCompile = false
    var previousPath = ""
    for node in graph.mapEntries["nodes"].listItems:
      check node.mapImmutable
      let nodePath = node.mapEntries["path"].strVal
      check previousPath.len == 0 or previousPath <= nodePath
      previousPath = nodePath
      let digest = node.mapEntries["source_digest"].strVal
      let interfaceDigest = node.mapEntries["compile_interface_digest"].strVal
      check digest.startsWith("sha256:") and digest.len == 71
      check interfaceDigest.startsWith("sha256:") and interfaceDigest.len == 71
      if node.mapEntries["owned"].boolVal:
        sawOwned = true
      else:
        sawShared = true
      var previousDependency = ""
      for dependency in node.mapEntries["dependencies"].listItems:
        let dependencyKey = dependency.mapEntries["identity"].strVal & "\x1f" &
          dependency.mapEntries["phase"].strVal
        check previousDependency.len == 0 or
          previousDependency <= dependencyKey
        previousDependency = dependencyKey
        case dependency.mapEntries["phase"].strVal
        of "runtime": sawRuntime = true
        of "compile": sawCompile = true
        else: discard
    check sawOwned
    check sawShared
    check sawRuntime
    check sawCompile
    discard run(compileSource("(tx .discard)"), scope)

  test "generation graph digests separate source from compile interface":
    let root = modDir / "generation_digests"
    createDir(root)
    let path = root / "plugin.gene"

    proc graphFor(source: string): Value =
      writeFile(path, source)
      let app = newApplication(modDir)
      let scope = newGlobalScope(app)
      run(compileSource(
        "(var tx ($runtime/sandbox_transaction)) " &
        "(var generation " &
        "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
        "    ^entry \"plugin.gene\" ^grants [] ^shared [] " &
        "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
        "(var graph (generation .graph)) (tx .discard) graph"), scope)

    proc rootNode(graph: Value): Value =
      let rootIdentity = graph.mapEntries["root"].strVal
      for node in graph.mapEntries["nodes"].listItems:
        if node.mapEntries["identity"].strVal == rootIdentity:
          return node
      NIL

    let first = rootNode(graphFor("(fn answer [] : Int 1)"))
    let implementationOnly = rootNode(graphFor("(fn answer [] : Int 2)"))
    let interfaceChange = rootNode(graphFor(
      "(fn answer [] : Int 2) (var added true)"))
    check first.kind == vkMap
    check first.mapEntries["source_digest"].strVal !=
      implementationOnly.mapEntries["source_digest"].strVal
    check first.mapEntries["compile_interface_digest"].strVal ==
      implementationOnly.mapEntries["compile_interface_digest"].strVal
    check implementationOnly.mapEntries["compile_interface_digest"].strVal !=
      interfaceChange.mapEntries["compile_interface_digest"].strVal

    proc errorDigest(source: string): string =
      let node = rootNode(graphFor("(mod plugin ^errors_mode strict)\n" & source))
      node.mapEntries["compile_interface_digest"].strVal

    let closed = errorDigest("(fn answer [] : Int ^errors [] 1)")
    check closed == errorDigest("(fn answer [] : Int ^errors [] 2)")
    check closed != errorDigest("(fn answer [] : Int ^errors [Error] 1)")
    let factory = "(fn factory [] : (Callable [] Int ^errors ROW) ^errors [] " &
      "(fn [] : Int ^errors [] 1))"
    check errorDigest(factory.replace("ROW", "[]")) !=
      errorDigest(factory.replace("ROW", "[Error]"))
    let deferred = "(fn produce [] : (Task Int ROW) ^errors [] (spawn 1))"
    check errorDigest(deferred.replace("ROW", "Never")) !=
      errorDigest(deferred.replace("ROW", "Error"))

  test "prepared candidate protocols work without publishing to live scopes":
    let root = modDir / "generation_protocol"
    createDir(root)
    writeModule("generation_contract.gene",
      "(protocol Readable (message read [] : Int)) " &
      "(fn check [value : Readable] : Readable value)")
    writeFile(root / "plugin.gene",
      "(import [Readable] ^from \"../generation_contract\") " &
      "(type Item) " &
      "(impl Readable for Item (message read [] : Int 42)) " &
      "(fn make [] (Item))")
    let app = newApplication(modDir)
    let scope = newGlobalScope(app)
    let contractPath = (modDir / "generation_contract.gene").replace("\\", "/")
    check run(compileSource(
      "(import [Readable check] ^from \"./generation_contract\") " &
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var generation " &
      "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
      "    ^entry \"plugin.gene\" ^grants [] " &
      "    ^shared [\"" & contractPath & "\"] " &
      "    ^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
      "(var candidate (generation .module)) " &
      "(var item (candidate/make)) " &
      "[(same? (check item) item) (item .Readable:read)]"), scope).print() ==
      "[true 42]"
    discard run(compileSource("(tx .discard)"), scope)

  test "repeated generation commit and release leaves no runtime roots":
    let root = modDir / "generation_repeated"
    createDir(root)
    writeFile(root / "plugin.gene",
      "(protocol Local (message value [] : Int)) " &
      "(type Item) " &
      "(impl Local for Item (message value [] : Int 1)) " &
      "(var item (Item))")
    let app = newApplication(modDir)
    discard app.builtinsScope()
    let beforeModules = app.moduleCacheEntryCount()
    let beforeHeaders = app.moduleCompileHeaderCount()
    let beforeArtifacts = app.moduleCompileArtifactCount()
    let beforeImpls = app.canonicalImplCount()
    for i in 0 ..< 5:
      let scope = newGlobalScope(app)
      discard run(compileSource(
        "(var tx ($runtime/sandbox_transaction)) " &
        "(var generation " &
        "  (tx .prepare {^dir \"" & root.replace("\\", "/") & "\" " &
        "    ^entry \"plugin.gene\" ^grants [] ^shared [] ^label \"cycle-" &
        $i & "\" ^policy {^max_memory_mb 16 " &
        "    ^timeout_ms 1000}})) " &
        "(tx .commit) (generation .release)"), scope)
      check app.moduleCacheEntryCount() == beforeModules
      check app.moduleCompileHeaderCount() == beforeHeaders
      check app.moduleCompileArtifactCount() == beforeArtifacts
      check app.canonicalImplCount() == beforeImpls

  test "released generation retains this_mod for an escaped function":
    let root = modDir / "generation_retained_self"
    createDir(root)
    writeFile(root / "self.gene", "(fn identity [] this_mod)")
    let scope = newGlobalScope(newApplication(modDir))
    check run(compileSource(
      "(var tx ($runtime/sandbox_transaction)) " &
      "(var generation (tx .prepare {^dir \"" & root.replace("\\", "/") &
      "\" ^entry \"self.gene\" ^grants [] ^shared [] ^label \"retained\" " &
      "^policy {^max_memory_mb 16 ^timeout_ms 1000}})) " &
      "(var saved (generation .module)) " &
      "(var identity saved/identity) " &
      "(tx .commit) (generation .release) " &
      "(same? (identity) saved)"), scope).boolVal
