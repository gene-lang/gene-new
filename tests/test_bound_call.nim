import gene/[compiler, types, vm, printer, capabilities, fs_capabilities]
import std/[unittest, os, tempfiles, strutils]

proc evalBoundCall(source: string): Value =
  run(compileSource(source), newGlobalScope())

suite "runtime bound calls":
  test "binds positional and named arguments without invoking the target":
    check evalBoundCall("(var hits ($cell 0)) " &
      "(fn add [x : Int ^y : Int] : Int " &
      "  (hits .set (+ (hits .get) 1)) (+ x y)) " &
      "(var args [3]) (var named {^y 4}) " &
      "(var f ($runtime/bind_call add args ^named named)) " &
      "(args .set 0 10) (set named/y 20) " &
      "[(hits .get) (f) (hits .get)]").print() == "[0 7 1]"

  test "copies the argument shape while preserving nested identities":
    check evalBoundCall("(var cell ($cell 1)) " &
      "(fn read [c] (c .get)) " &
      "(var args [cell]) (var f ($runtime/bind_call read args)) " &
      "(args .set 0 ($cell 99)) (cell .set 7) (f)").print() == "7"

  test "a returned binding keeps its target's lexical capture alive":
    check evalBoundCall("(fn make [x] " &
      " ($runtime/bind_call (fn [y] (+ x y)) [2] ^policy {^max_steps 100})) " &
      "(var f (make 40)) (f)").print() == "42"

  test "named argument spills and constructor spreads preserve all fields":
    check evalBoundCall("(fn total [^a : Int ^b : Int ^c : Int ^d : Int ^e : Int] " &
      " (+ a (+ b (+ c (+ d e))))) " &
      "(var f ($runtime/bind_call total [] ^named {^a 1 ^b 2 ^c 3 ^d 4 ^e 5})) " &
      "(f)").print() == "15"
    check evalBoundCall("(type Thing ^props {^value Int} " &
      " (ctor [^value : Int] (set self/value value))) " &
      "(var item (new Thing {^value 7}...)) item/value").print() == "7"

  test "selectors, messages, and user callables use ordinary dispatch":
    check evalBoundCall("(var a ($runtime/bind_call /name [{^name \"Ada\"}])) " &
      "(var b ($runtime/bind_call Self:get [($cell 8)])) " &
      "[(a) (b)]").print() == "[\"Ada\" 8]"
    check evalBoundCall("(type Add ^props {^n Int} " &
      "  (impl Callable (message apply [call] : Any (+ self/n call/body/0)))) " &
      "(var f ($runtime/bind_call (Add ^n 5) [2])) (f)").print() == "7"

  test "each invocation receives a fresh instruction budget":
    check evalBoundCall("(fn value [] 7) " &
      "(var f ($runtime/bind_call value [] ^policy {^max_steps 20})) " &
      "[(f) (f) (f) (f) (f)]").print() == "[7 7 7 7 7]"

  test "instruction limits stop the target and ordinary execution resumes":
    check evalBoundCall("(fn spin [] (repeat 10000 nil)) " &
      "(var f ($runtime/bind_call spin [] ^policy {^max_steps 40})) " &
      "[(try (f) false catch Any true) (+ 2 3)]").print() == "[true 5]"

  test "message application retains the dynamic caller's budget":
    check evalBoundCall("(type Worker (message work [] (repeat 10000 nil))) " &
      "(var f ($runtime/bind_call Self:work [(Worker)] " &
      " ^policy {^max_steps 40})) (try (f) false catch Any true)").print() == "true"

  test "each binding retains its own scoped Callable implementation":
    check evalBoundCall("(type Item) " &
      "(fn make [n] (impl Callable for Item (message apply [call] n)) " &
      " ($runtime/bind_call (Item) [])) " &
      "(var first (make 1)) (var second (make 2)) " &
      "[(first) (second) (first)]").print() == "[1 2 1]"

  test "nested bindings cannot replace a stricter caller budget":
    check evalBoundCall("(var hits ($cell 0)) " &
      "(fn spin [] (repeat 10000 (hits .set (+ (hits .get) 1)))) " &
      "(fn nested [] " &
      "  (var inner ($runtime/bind_call spin [] ^policy {^max_steps 10000})) " &
      "  (inner)) " &
      "(var outer ($runtime/bind_call nested [] ^policy {^max_steps 120})) " &
      "(try (outer) nil catch Any nil) (< (hits .get) 100)").print() == "true"

  test "deadline starts when the binding is invoked":
    check evalBoundCall("(fn value [] 7) " &
      "(var f ($runtime/bind_call value [] ^policy {^timeout_ms 50})) " &
      "($sleep 80) (f)").print() == "7"

  test "memory limits apply to retained allocations in the target":
    var diagnostic = ""
    try:
      discard evalBoundCall("(fn allocate [] (var buffers []) " &
        " (repeat 100 (buffers .push ($buffer U8 65536))) buffers) " &
        "(var f ($runtime/bind_call allocate [] ^policy {^max_memory_mb 1})) (f)")
    except GeneError as error:
      diagnostic = error.msg
    check "memory limit" in diagnostic

  test "suspended calls retain their continuation and cleanup":
    check evalBoundCall("(var events ($cell [])) " &
      "(fn work [] (try ($sleep 1) 7 " &
      " ensure ((events .get) .push \"cleanup\"))) " &
      "(var f ($runtime/bind_call work [] ^policy {^max_steps 1000})) " &
      "(scope (var task (spawn ^lane root (f))) " &
      "  [(await task) (events .get)])").print() == "[7 [\"cleanup\"]]"

  test "cancellation unwinds the bound target once":
    check evalBoundCall("(var hits ($cell 0)) " &
      "(fn work [] (try ($sleep 10000) " &
      " ensure (hits .set (+ (hits .get) 1)))) " &
      "(var f ($runtime/bind_call work [] ^policy {^max_steps 1000})) " &
      "(scope (var task (spawn ^lane root (f))) " &
      "  ($sleep 1) (task .cancel) " &
      "  [(match (task .join) (when TaskOutcome/cancelled true) (else false)) " &
      "   (hits .get)])").print() == "[true 1]"

  test "recoverable errors preserve their nominal type and fields":
    check evalBoundCall("(type Boom ^props {^code Int} ^impl [Error]) " &
      "(impl Error for Boom) (var boom (Boom ^code 7)) " &
      "(fn fail_it [] (fail boom)) " &
      "(var f ($runtime/bind_call fail_it [])) " &
      "(try (f) 0 catch Boom $ex/code)").print() == "7"

  test "panics remain task outcomes rather than ordinary catchable errors":
    check evalBoundCall("(fn fail_it [] (panic \"bound panic\")) " &
      "(var f ($runtime/bind_call fail_it [])) " &
      "(scope (var task (spawn ^lane root (f))) " &
      "  (match (task .join) (when (TaskOutcome/panic message) true) " &
      "    (else false)))").print() == "true"

  test "fexprs and borrowed caller environments cannot become durable bindings":
    check evalBoundCall("(fn syntax! [] nil) " &
      "(try ($runtime/bind_call syntax! []) false catch Any true)").print() == "true"
    check evalBoundCall("(fn target [] 1) " &
      "(fn capture! [] ($runtime/bind_call target [])) " &
      "(try (capture!) false catch Any true)").print() == "true"

  test "invalid policy fields fail at binding time":
    check evalBoundCall("(fn target [] 1) " &
      "[(try ($runtime/bind_call target [] ^policy {^max_steps -1}) " &
      " false catch Any true) " &
      " (try ($runtime/bind_call target [] ^policy {^allow_ffi false}) " &
      " false catch Any true)]").print() == "[true true]"

when defined(posix):
  suite "bound call authority":
    test "creation and invocation ceilings both apply":
      let root = createTempDir("gene-bound-call-", "")
      defer: removeDir(root)
      writeFile(root / "data", "bound")
      let app = newApplication(root)
      app.setRootCapabilities(newCapabilityContext(
        @[app.filesystemCapabilities.grantReadDir(root)]))
      let scope = newGlobalScope(app)
      scope.define("file", newStr(root / "data"))
      let source = "(fn read ^capabilities * [] ($fs/read_text file)) " &
        "(var full ($runtime/bind_call read [])) " &
        "(var empty ($runtime/bind_call read [] ^capabilities [])) " &
        "(var narrow (with_capabilities [] ($runtime/bind_call read []))) " &
        "[(full) " &
        " (try (empty) false catch MissingCapability true) " &
        " (try (narrow) false catch MissingCapability true) " &
        " (try (with_capabilities [] (full)) false catch MissingCapability true)]"
      check run(compileSource(source), scope).print() ==
        "[\"bound\" true true true]"

    test "selector data resolves once against the creating scope":
      let root = createTempDir("gene-bound-selectors-", "")
      defer: removeDir(root)
      writeFile(root / "one", "one")
      writeFile(root / "two", "two")
      let app = newApplication(root)
      app.setRootCapabilities(newCapabilityContext(
        @[app.filesystemCapabilities.grantReadDir(root)]))
      let scope = newGlobalScope(app)
      scope.define("first", newStr(root / "one"))
      scope.define("second", newStr(root / "two"))
      let source = "(var path first) " &
        "(fn read ^capabilities * [] ($fs/read_text path)) " &
        "(var f ($runtime/bind_call read [] " &
        " ^capabilities (quote [(fs/ReadFile path)]))) " &
        "(var value (f)) (set path second) " &
        "[value (try (f) false catch MissingCapability true)]"
      check run(compileSource(source), scope).print() == "[\"one\" true]"
