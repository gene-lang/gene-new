import std/[os, strutils, tempfiles, unittest]
import gene/[capabilities, compiler, fs_capabilities, native_effects, printer, types, vm]
import ./capability_test_support

var nativeEffectProbeCalls = 0
proc nativeEffectProbe(args: openArray[Value]): Value {.nimcall.} =
  inc nativeEffectProbeCalls
  newInt(99)

proc nativeEffectRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let active = activeCapabilitiesForCall(call)
  try:
    newStr(active.app.filesystemCapabilities.readText(active.context, args[0].strVal))
  except CapabilityError as error:
    raiseCapabilityOperationError(call[].dispatchScope, "test/native_read", "fs/Read", error)

proc nativeEffectApp(root: string): Application =
  result = newApplication(root)
  result.setRootCapabilities(result.capabilities.newPolicyContext([]))

proc nativeEffectEval(scope: Scope, source: string): Value =
  run(compileSource(source, useLocalSlots = false), scope)

suite "native effect dispositions":
  test "the native catalog is explicit, unique and ordered":
    var previous = ""
    for rule in NativeEffectRules:
      check rule.name > previous
      check rule.kind != nekUnclassified
      check builtinNativeEffectKind(rule.name) == rule.kind
      previous = rule.name
    check builtinNativeEffectKind("unreviewed/native") == nekUnclassified
    check builtinNativeEffectKind("gene/println") == nekUnclassified

  test "unclassified native names cannot inherit builtin authority or fast paths":
    let app = nativeEffectApp(getCurrentDir())
    for name in ["+", "println", "net/http_client/send", "date"]:
      let scope = newGlobalScope(app)
      let native = newNativeFn(name, nativeEffectProbe, fastKind = nfkAdd)
      check native.nativeEffectKind == nekUnclassified
      check native.nativeFastKind == nfkNone
      scope.define("target", native)
      nativeEffectProbeCalls = 0
      check scope.nativeEffectEval("""
(try (target 1 2) catch UnsupportedCapability $err/reason)
""").strVal == "unclassified_native"
      check nativeEffectProbeCalls == 0

  test "an explicitly admitted pure extension executes its own implementation":
    let app = nativeEffectApp(getCurrentDir())
    let scope = newGlobalScope(app)
    scope.define("target", newNativeFn("+", nativeEffectProbe,
      effectKind = nekCapabilityFree))
    nativeEffectProbeCalls = 0
    check scope.nativeEffectEval("(target 1 2)").intVal == 99
    check nativeEffectProbeCalls == 1
    check scope.nativeEffectEval("(+ 1 2)").intVal == 3

  test "every unsupported disposition rejects before native code executes":
    let app = nativeEffectApp(getCurrentDir())
    for rule in NativeEffectRules:
      if rule.kind != nekUnsupported: continue
      let scope = newGlobalScope(app)
      scope.define("target", newNativeFn(rule.name, nativeEffectProbe,
        effectKind = rule.kind))
      nativeEffectProbeCalls = 0
      checkpoint rule.name
      check scope.nativeEffectEval("""
(try (target) catch UnsupportedCapability $err/reason)
""").strVal == "unsupported_operation"
      check nativeEffectProbeCalls == 0

  test "ordinary effect families reject through their real public entry points":
    let root = expandFilename(createTempDir("gene-native-effects-", ""))
    defer: removeDir(root)
    let marker = root / "must-not-exist"
    let calls = [
      "($println \"forbidden\")", "($now)", "($today)",
      "($os/get_env \"PATH\")", "($os/process_id)", "($os/stdin_tty?)",
      "($os/read_input)", "($os/begin_interrupt)",
      "($os/exec ^cmd \"touch\" ^args [" & newStr(marker).print() & "])",
      "($crypto/random_hex 16)",
      "($db/sqlite/open " & newStr(marker).print() & ")",
      "($net/tcp_write_text_async \"127.0.0.1\" 1 \"x\" 100)",
      "($net/http/listen)", "($net/http/status)",
      "($net/http/ws_accept)", "($net/http/ws_send)", "($curses/open)",
      "($terminal/open)", "($fs/watch " & newStr(root).print() & ")",
      "($fs/try_lock " & newStr(marker).print() & ")",
      "($ffi/open \"missing-library\")", "($aot/load \"missing-library\")",
      "($web/load)", "($runtime/gc_stats)",
      "($repl/open (env))", "($test/run)"]
    let app = nativeEffectApp(root)
    for expression in calls:
      let scope = newGlobalScope(app)
      checkpoint expression
      check scope.nativeEffectEval("(try " & expression &
        " false catch UnsupportedCapability true)").boolVal
      check not fileExists(marker)

  test "aliases, held values, bound calls and callable adapters retain dispositions":
    let app = nativeEffectApp(getCurrentDir())
    let scope = newGlobalScope(app)
    check scope.nativeEffectEval("""
(import $os [get_env : environment])
(var held environment)
(var bound ($runtime/bind_call held ["PATH"]))
(var adapted : (Callable [Str] Any) held)
[(try (environment "PATH") false catch UnsupportedCapability true)
 (try (held "PATH") false catch UnsupportedCapability true)
 (try (bound) false catch UnsupportedCapability true)
 (try (adapted "PATH") false catch UnsupportedCapability true)]
""").print() == "[true true true true]"

  test "data-only dates, serialization, hashing and computation remain usable":
    let app = nativeEffectApp(getCurrentDir())
    let scope = newGlobalScope(app)
    check scope.nativeEffectEval("""
[(+ 2 3) (($date 2026 9 20) .year)
 ($serde/read_data ($serde/write_data [1 2]))
 ($crypto/secure_equal? "same" "same")]
""").print() == "[5 2026 [1 2] true]"

  test "unsupported registration does not run an initializer callback":
    let app = nativeEffectApp(getCurrentDir())
    let scope = newGlobalScope(app)
    check scope.nativeEffectEval("""
(var count ($cell 0))
(fn init [] (count .set 1))
(fn handle [state message] state)
(try ($actor/spawn ^init init ^handle handle) catch UnsupportedCapability nil)
(count .get)
""").intVal == 0

  test "ordinary normalized execution rejects hidden FFI declarations before body work":
    let app = nativeEffectApp(getCurrentDir())
    let scope = newGlobalScope(app)
    expect GeneError:
      discard scope.nativeEffectEval("(fn later [] (ffi/struct CPoint ^fields [[x C/Int]]))")

  test "unclassified callbacks remain rejected through bounded and adapted calls":
    let app = nativeEffectApp(getCurrentDir())
    let scope = newGlobalScope(app)
    scope.define("target", newNativeFn("test/unreviewed", nativeEffectProbe))
    nativeEffectProbeCalls = 0
    check scope.nativeEffectEval("""
(var bound ($runtime/bind_call target []))
(var adapted : (Callable [] Any) target)
[(try (bound) false catch UnsupportedCapability true)
 (try (adapted) false catch UnsupportedCapability true)]
""").print() == "[true true]"
    check nativeEffectProbeCalls == 0

  test "a narrowed legacy caller cannot enter native declarations through blocks or functions":
    for body in [
      "(with_capabilities [] (count .set 1) (ffi/struct CPoint ^fields [[x C/Int]]))",
      "(fn later [] (count .set 1) (ffi/struct CPoint ^fields [[x C/Int]])) (with_capabilities [] (later))"]:
      let app = newApplication(getCurrentDir())
      let scope = newGlobalScope(app)
      discard scope.nativeEffectEval("(var count ($cell 0))")
      checkpoint body
      var denied = ""
      try: discard scope.nativeEffectEval(body)
      except GeneError as error: denied = error.msg
      check "native declarations" in denied
      check scope.nativeEffectEval("(count .get)").intVal == 0

  test "crossing an unannotated host scope preserves the normalized profile":
    let app = nativeEffectApp(getCurrentDir())
    let origin = newGlobalScope(app)
    origin.moduleRoot = true
    let target = origin.nativeEffectEval("(fn get_now [] ($now))")
    let caller = newGlobalScope(app)
    caller.moduleRoot = true
    caller.define("target", target)
    check caller.nativeEffectEval("""
(try (target) false catch UnsupportedCapability true)
""").boolVal

  test "direct host-native entry establishes and restores the supplied context":
    let app = nativeEffectApp(getCurrentDir())
    let scope = newGlobalScope(app)
    let target = newNativeFn("unreviewed", nativeEffectProbe)
    nativeEffectProbeCalls = 0
    expect GeneError: discard call(target, @[], @[], @[], scope)
    check nativeEffectProbeCalls == 0
    let pure = newNativeFn("pure", nativeEffectProbe, effectKind = nekCapabilityFree)
    check call(pure, @[], @[], @[], scope).intVal == 99

  test "guarded native extensions use current and retained caller ceilings":
    let root = expandFilename(createTempDir("gene-native-guarded-extension-", ""))
    defer: removeDir(root)
    let path = root / "data"
    writeFile(path, "guarded")
    let app = newFilesystemPolicyApp(root)
    let scope = newGlobalScope(app)
    let target = newNativeCallFn("test/read", nativeEffectRead, effectKind = nekGuarded)
    scope.define("target", target)
    scope.define("path", newStr(path))
    check scope.nativeEffectEval("""
[(target path) (try (with_capabilities [] (target path)) false
  catch MissingCapability true)]
""").print() == "[\"guarded\" true]"
    let retained = newScope(scope)
    retained.evalCapabilityCeiling = app.capabilities.newPolicyContext([])
    expect GeneError: discard call(target, @[newStr(path)], @[], @[], retained)
    check call(target, @[newStr(path)], @[], @[], scope).strVal == "guarded"
    var captured = NativeCall(dispatchScope: scope,
      capabilityContext: app.capabilities.newPolicyContext([]))
    expect GeneError: discard nativeEffectRead([newStr(path)], addr captured)

  test "lazy callback registration preserves source origins through broader consumers":
    let root = expandFilename(createTempDir("gene-native-lazy-origin-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", """
(fn wrap [callback] ($map ($to_stream [1]) callback))
(fn take [source] ($take source 1))
""")
    let app = nativeEffectApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    scope.define("private", newNativeFn("test/private", nativeEffectProbe,
      effectKind = nekHostControl))
    nativeEffectProbeCalls = 0
    check scope.nativeEffectEval("""
(var direct (plugin/wrap private))
(var broad ($map ($to_stream [1]) private))
(var retained (plugin/take broad))
[(try (direct .next) false catch UnsupportedCapability true)
 (try (retained .next) false catch UnsupportedCapability true)]
""").print() == "[true true]"
    check nativeEffectProbeCalls == 0
    check scope.nativeEffectEval("(private)").intVal == 99

  test "take keeps its creation bound over a broader lazy effect":
    let root = expandFilename(createTempDir("gene-native-take-bound-", ""))
    defer: removeDir(root)
    let path = root / "data"
    writeFile(path, "guarded")
    let app = newFilesystemPolicyApp(root)
    let scope = newGlobalScope(app)
    scope.define("path", newStr(path))
    check scope.nativeEffectEval("""
(var source ($map ($to_stream [path]) $fs/read_text))
(var retained (with_capabilities [] ($take source 1)))
[(try (retained .next) false catch MissingCapability true)
 ($fs/read_text path)]
""").print() == "[true \"guarded\"]"

  test "adapter cleanup retains source bounds around a host generator":
    let root = expandFilename(createTempDir("gene-native-close-source-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", """
(fn wrap [source] ($take source 2))
""")
    let app = nativeEffectApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    scope.define("private", newNativeFn("test/private", nativeEffectProbe,
      effectKind = nekHostControl))
    nativeEffectProbeCalls = 0
    check scope.nativeEffectEval("""
(let effects [])
(fn ^^generator produce []
  (try (yield 1) (yield 2)
    ensure (effects .push
      (try (private) catch UnsupportedCapability "denied"))))
(let upstream (produce))
(upstream .next)
(let bounded (plugin/wrap upstream))
(bounded .close)
effects
""").print() == "[\"denied\"]"
    check nativeEffectProbeCalls == 0
    check scope.nativeEffectEval("(private)").intVal == 99

  test "suspended callback cleanup retains the closing plugin's source policy":
    let root = expandFilename(createTempDir("gene-native-close-callback-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", "(fn close [stream] (stream .close))")
    let app = nativeEffectApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    scope.define("private", newNativeFn("test/private", nativeEffectProbe,
      effectKind = nekHostControl))
    nativeEffectProbeCalls = 0
    check scope.nativeEffectEval("""
(scope
  (let ready ($channel ^capacity 1))
  (let waiting ($channel ^capacity 1))
  (let effects [])
  (fn visit [x]
    (try (ready .send true) (waiting .recv) x
      ensure (effects .push
        (try (private) catch UnsupportedCapability "denied"))))
  (let pending ([1] => visit))
  (let consumer (spawn ^lane root (pending -> $into [])))
  (let closer (spawn ^lane root (do (ready .recv) (plugin/close pending))))
  (closer .join)
  (consumer .join)
  effects)
""").print() == "[\"denied\"]"
    check nativeEffectProbeCalls == 0
    check scope.nativeEffectEval("(private)").intVal == 99
