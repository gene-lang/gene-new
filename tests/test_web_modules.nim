import gene/[web, vm, types]
import std/[algorithm, os, osproc, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix

suite "web standard receiver methods":
  test "preserves browser empty-separator code units through both spellings":
    let root = createTempDir("gene-web-string-methods-", "")
    defer: removeDir(root)
    writeFile(root / "strings.gene", """
      (mod strings ^profile web)
      (fn direct [] : (List Str) ("A🙂B" .split ""))
      (fn namespace [] : (List Str) ($str/split "A🙂B" ""))
    """)
    discard buildWebModule(root / "strings.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {direct, namespace} from './strings.mjs';
      const expected = ['A', '\uD83D', '\uDE42', 'B'];
      assert.deepEqual(direct(), expected);
      assert.deepEqual(namespace(), expected);
      assert.equal(direct().join(''), 'A🙂B');
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "rejects invalid string/list method argument types and arities":
    let root = createTempDir("gene-web-method-errors-", "")
    defer: removeDir(root)
    for i, expression in ["(\"x\" .split)", "(\"x\" .split 1)",
        "([1] .get \"0\")", "([1] .get 0 1)", "([1] .join \",\")"]:
      let source = root / ("invalid_" & $i & ".gene")
      writeFile(source, "(mod invalid_" & $i & " ^profile web) " &
        "(fn run [] : Any " & expression & ")")
      expect WebProfileError:
        discard buildWebModule(source, root / "out")

suite "web bindings that shadow host globals":
  test "a local or parameter named like a browser global keeps its meaning":
    let root = createTempDir("gene-web-shadow-", "")
    defer: removeDir(root)
    writeFile(root / "shadow.gene", """
      (mod shadow ^profile web)
      (fn run [] : (List Str)
        (var document "doc")
        (let window "win")
        (for navigator in ["nav"]
          (return [document window navigator]))
        [document window])
      (fn echo [document : Str, window : Str] : Str
        (str/join [document window] "/"))
      (fn caller [document : Str] : Str
        (var window document)
        window)
      (type Box ^props {^value Str})
      (fn setter [path : Str] : Str
        (var box (Box ^value "a"))
        (set box/value path)
        box/value)
    """)
    discard buildWebModule(root / "shadow.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {run, echo, caller, setter} from './shadow.mjs';
      globalThis.document = { marker: 'host' };
      globalThis.window = { marker: 'host' };
      Object.defineProperty(globalThis, 'navigator', {
        value: { marker: 'host' }, configurable: true, writable: true });
      assert.deepEqual(run(), ['doc', 'win', 'nav']);
      assert.equal(echo('a', 'b'), 'a/b');
      assert.equal(caller('x'), 'x');
      assert.equal(setter('b'), 'b');
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

suite "web leaf predicate":
  test "distinguishes text and scalar leaves from structures and callables":
    let root = createTempDir("gene-web-leaf-", "")
    defer: removeDir(root)
    writeFile(root / "leaf.gene", """
      (mod leaf ^profile web)
      (fn classify [value : Any] : Str
        (if ($leaf? value) "leaf" else "structure"))
    """)
    discard buildWebModule(root / "leaf.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {classify} from './leaf.mjs';
      assert.equal(classify("Conversations"), 'leaf');
      assert.equal(classify(0n), 'leaf');
      assert.equal(classify(0), 'leaf');
      assert.equal(classify(true), 'leaf');
      assert.equal(classify(null), 'leaf');
      assert.equal(classify({tag: 'div', props: {}, children: []}), 'structure');
      assert.equal(classify([]), 'structure');
      assert.equal(classify(() => 1), 'structure');
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

suite "web catch types":
  test "Any and value types are rejected as catch types":
    for (clause, expected) in [
        ("Any", "Any is not an error type; use `catch Error`"),
        ("Str", "Str is not an error type")]:
      var message = ""
      try:
        discard analyzeWebModule("(mod catch_types ^profile web) " &
          "(fn run [] : Int (try 1 catch " & clause & " 2))", "catch_types.gene")
      except WebProfileError as error:
        message = error.msg
      check expected in message
    discard analyzeWebModule("(mod catch_types ^profile web) " &
      "(fn run [] : Int (try 1 catch Error 2))", "catch_types.gene")

  test "a host throw reaches a catch as a HostError or HostFault":
    let root = createTempDir("gene-web-host-throw-", "")
    defer: removeDir(root)
    writeFile(root / "host.mjs", """
      export function throw_value(kind) {
        if (kind === "string") throw "x";
        if (kind === "number") throw 3;
        if (kind === "undefined") throw undefined;
        if (kind === "type") throw new TypeError("t");
        const deep = () => deep();
        deep();
      }
    """)
    writeFile(root / "host_throw.gene", """
      (mod host_throw ^profile web)
      (js/fn throw_value [kind : Str] : Nil ^from "./host.mjs")
      (fn probe [kind : Str] : Str
        (try (throw_value kind) "returned"
          catch Fault $"fault ${$err/.message}"
          catch Error $"error ${$err/.message}"))
      (fn wrapped [kind : Str] : Bool
        (try (throw_value kind) false catch HostError true))
      (fn run [] : (List Str)
        [(probe "string") (probe "number") (probe "type")
         (try (throw_value "string") "returned" catch Throwable $err/.message)
         (if (wrapped "undefined") "host-error" else "other")
         (try (throw_value "deep") "returned" catch HostFault "host-fault")])
    """)
    discard buildWebModule(root / "host_throw.gene", root / "out")
    copyFile(root / "host.mjs", root / "out" / "host.mjs")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {run} from './host_throw.mjs';
      assert.deepEqual(run(), ["error x", "error 3", "error t", "x", "host-error", "host-fault"]);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "Throwables are JS Errors with stacks, and built-in types are constructible":
    let root = createTempDir("gene-web-error-stacks-", "")
    defer: removeDir(root)
    writeFile(root / "stacks.gene", """
      (mod stacks ^profile web)
      (type Boom : Error ^props {^code Int})
      (type Bug : Fault)
      (type Odd : RuntimeFault ^props {^name Str? ^stack Str?})
      (type Formatted : Error ^props {^code Int}
        (message message [] : Str ^errors [] ^^override $"code ${self/code}"))
      (fn user_error [] : Int (fail (Boom ^_msg "boom" ^code 1)))
      (fn user_fault [] : Int (fail (Bug ^_msg "bug")))
      (fn plain_error [] : Int (fail (Error ^_msg "plain")))
      (fn plain_fault [] : Int (fail (Fault ^_msg "fault")))
      (fn runtime_fault [] : Int (fail (RuntimeFault ^_msg "rt")))
      (fn formatted [] : Int (fail (Formatted ^code 7)))
      (fn divide [a : Int b : Int] : Int (/ a b))
      (fn unmatched [x : Int] : Int (match ^!exhaustive x when 1 1))
      (fn catches [] : (List Str)
        [(try (fail (Error ^_msg "e")) "none" catch Error $err/.message)
         (try (fail (Fault ^_msg "f")) "none" catch Error "wrong" catch Fault $err/.message)
         (try (fail (RuntimeFault ^_msg "r")) "none" catch RuntimeFault $err/.message)
         (try (fail (Odd ^_msg "o")) "none" catch RuntimeFault $err/.message)
         (try (fail (MessageFault ^_msg "m" ^where "w" ^expected "x" ^actual "y"))
           "none" catch TypeFault $err/.message)
         (try (fail (PathMissing ^_msg "p" ^segment "k")) "none" catch MatchFault $err/.message)])
      (fn caught_odd [] : Any (try (fail (Odd ^_msg "o" ^name "n" ^stack "s")) nil catch RuntimeFault $err))
      (fn caught_boom [] : Any (try (fail (Boom ^_msg "b" ^code 2)) nil catch Error $err))
      (fn read_stack [e : Any] : Any e/stack)
      (fn read_name [e : Any] : Any e/name)
      (fn same_boom [] : Bool (== (Boom ^_msg "b" ^code 2) (Boom ^_msg "b" ^code 2)))
    """)
    discard buildWebModule(root / "stacks.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import * as m from './stacks.mjs';
      const thrown = (f) => { try { f(); } catch (e) { return e; } assert.fail('no throw'); };
      for (const [f, header] of [[m.user_error, 'Boom: boom'], [m.user_fault, 'Bug: bug'],
          [m.plain_error, 'Error: plain'], [m.plain_fault, 'Fault: fault'],
          [m.runtime_fault, 'RuntimeFault: rt'], [m.formatted, 'Formatted: code 7'],
          [() => m.divide(1n, 0n), 'RuntimeFault: division by zero'],
          [() => m.unmatched(2n), 'MatchFault: no pattern matched 2']]) {
        const e = thrown(f);
        assert.ok(e instanceof Error);
        assert.equal(e.stack.split('\n')[0], header);
        assert.match(e.stack.split('\n')[1], /^\s+at /);
        assert.ok(!Object.keys(e).includes('message') && !Object.keys(e).includes('name'));
      }
      assert.deepEqual(m.catches(), ['e', 'f', 'r', 'o', 'm', 'p']);
      const odd = m.caught_odd();
      assert.deepEqual([odd.name, odd.stack, m.read_name(odd), m.read_stack(odd)], ['n', 's', 'n', 's']);
      const boom = m.caught_boom();
      assert.deepEqual([boom.name, boom.message, m.read_name(boom), m.read_stack(boom)], ['Boom', 'b', null, null]);
      assert.equal(m.same_boom(), true);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "branch catches: Error, Fault and named built-in Faults":
    let root = createTempDir("gene-web-branch-catch-", "")
    defer: removeDir(root)
    writeFile(root / "branch_catch.gene", """
      (mod branch_catch ^profile web)
      (type Probe : Error)
      (type Invariant : Fault ^props {^code Int})
      (fn typed [x : Int] : Int x)
      (fn classify [kind : Str] : Str
        (try
          (if (== kind "error") (fail (Probe ^_msg "probe"))
            else (if (== kind "fault") (fail (Invariant ^code 7 ^_msg "broken"))
              else (if (== kind "zero")
                     (// 1 0)
                     ""
                   else
                     (let v : Any kind)
                     (typed v)
                     "")))
          catch Error $"error ${$err/.message}"
          catch Invariant $"invariant ${$err/.message}"
          catch RuntimeFault $"runtime ${$err/.message}"
          catch TypeFault "type"))
      (fn rows [] : Str ^errors [] (fail (Invariant ^code 1 ^_msg "passes")))
      (fn run [] : (List Str)
        [(classify "error") (classify "fault") (classify "zero") (classify "type")
         (try (rows) catch ContractViolation "violation" catch Fault $err/.message)])
    """)
    discard buildWebModule(root / "branch_catch.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {run} from './branch_catch.mjs';
      assert.deepEqual(run(), ["error probe", "invariant broken", "runtime division by zero", "type", "passes"]);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0
    var message = ""
    try:
      discard analyzeWebModule("(mod fault_row ^profile web) (type Invariant : Fault) " &
        "(fn run [] : Int ^errors [Invariant] 1)", "fault_row.gene")
    except WebProfileError as error:
      message = error.msg
    check "Fault types are unchecked" in message

  test "a value known only as a Throwable does not satisfy a branch root":
    for (call, expected) in [
        ("(fn through [x : Throwable] : Str (require_error x))", "expected Error, got Throwable"),
        ("(fn through [x : Throwable] : Str (require_fault x))", "expected Fault, got Throwable"),
        ("(fn through [x : RuntimeFault] : Str (require_error x))", "expected Error, got RuntimeFault")]:
      var message = ""
      try:
        discard analyzeWebModule("(mod roots ^profile web) " &
          "(fn require_error [x : Error] : Str \"error\") " &
          "(fn require_fault [x : Fault] : Str \"fault\") " & call, "roots.gene")
      except WebProfileError as error:
        message = error.msg
      check expected in message
    discard analyzeWebModule("(mod roots ^profile web) " &
      "(type Bad : Error) " &
      "(fn require_throwable [x : Throwable] : Str \"any\") " &
      "(fn require_fault [x : Fault] : Str \"fault\") " &
      "(fn run [] : (List Str) [(require_throwable (Bad ^_msg \"b\")) " &
      "(require_fault (RuntimeFault ^_msg \"r\"))])", "roots.gene")

  test "a message send on an Any receiver dispatches on the runtime value":
    let root = createTempDir("gene-web-any-message-", "")
    defer: removeDir(root)
    writeFile(root / "any_message.gene", """
      (mod any_message ^profile web)
      (type Envelope (message message [] : Str "hello"))
      (type Count (message message [] : Int 7))
      (type Plain ^props {^n Int})
      (type Bad : Error)
      (fn read_message [v : Any] : Str v/.message)
      (fn send_message [v : Any] : Any v/.message)
      (fn send_optional [v : Any] : Any v/?.message)
      (fn optional_error [v : Error?] : Str? v/?.message)
      (fn present_error [v : Error] : Str v/?.message)
      (fn run [] : (List Str)
        [(read_message (Envelope))
         (read_message (Bad ^_msg "bad"))
         (try (fail (Bad ^_msg "caught")) catch Error $err/.message)
         (try (read_message (Plain ^n 1)) catch MessageFault $err/.message)
         (try (read_message 5) catch MessageFault $err/.message)
         (try (read_message nil) catch MessageFault $err/.message)])
      (fn results [] : (List Any)
        [(send_message (Count)) (send_optional nil) (send_optional (Bad ^_msg "b"))
         (optional_error nil) (optional_error (Bad ^_msg "o")) (present_error (Bad ^_msg "p"))])
    """)
    discard buildWebModule(root / "any_message.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {run, results} from './any_message.mjs';
      assert.deepEqual(run(), ["hello", "bad", "caught",
        "no message 'message' on Plain", "no message 'message' on Int",
        "no message 'message' on Nil"]);
      assert.deepEqual(results(), [7n, null, "b", null, "o", "p"]);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "built-in Throwables on JS error classes check causes and hide host fields":
    for typ in ["TypeFault", "ContractViolation"]:
      var message = ""
      try:
        discard analyzeWebModule("(mod causes ^profile web) (fn run [] : Any (" & typ &
          " ^where \"\" ^expected \"\" ^actual \"\" ^_cause 7))", "causes.gene")
      except WebProfileError as error:
        message = error.msg
      check "expected (| Throwable Nil), got Int" in message
    let root = createTempDir("gene-web-special-throwables-", "")
    defer: removeDir(root)
    writeFile(root / "special.gene", """
      (mod special ^profile web)
      (type Sub : TypeFault)
      (fn read_name [v : Any] : Any v/name)
      (fn read_where [v : Any] : Any v/where)
      (fn with_cause [c : Any] : Any (TypeFault ^where "w" ^expected "e" ^actual "a" ^_cause c))
      (fn inner_cause [] : Any
        (let made (with_cause (RuntimeFault ^_msg "inner")))
        made/_cause/.message)
      (fn same [a : Any b : Any] : Bool (== a b))
      (fn runtime_fields [] : Any (try (range 0 2 0) nil catch RuntimeFault [$err/name $err/stack]))
      (fn equalities [] : (List Bool)
        [(same (HostError ^_msg "x" ^value 1) (HostFault ^_msg "x" ^value 1))
         (same (HostError ^_msg "x" ^value 1) (HostError ^_msg "x" ^value 1))
         (same (Error ^_msg "x") (Fault ^_msg "x"))
         (same (Sub ^where "w" ^expected "e" ^actual "a") (TypeFault ^where "w" ^expected "e" ^actual "a"))
         (try (range 0 2 0) false catch RuntimeFault (same $err (RuntimeFault ^_msg $err/.message)))])
      (fn run [] : (List Any)
        [(try (fail (TypeFault ^where "w" ^expected "e" ^actual "a")) nil catch TypeFault $err/stack)
         (read_name (HostError ^_msg "h" ^value 1))
         (read_name (TypeFault ^where "w" ^expected "e" ^actual "a"))
         (read_where (TypeFault ^where "w" ^expected "e" ^actual "a"))
         (try (fail (Sub ^where "sub" ^expected "e" ^actual "a")) nil catch TypeFault $err/where)
         (try (with_cause 7) "accepted" catch TypeFault "rejected")
         (inner_cause)])
    """)
    discard buildWebModule(root / "special.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {run, runtime_fields, equalities} from './special.mjs';
      assert.deepEqual(run(), [null, null, null, "w", "sub", "rejected", "inner"]);
      assert.deepEqual(runtime_fields(), [null, null]);
      assert.deepEqual(equalities(), [false, true, false, false, true]);
      const classes = globalThis[Symbol.for("gene.error.classes.v4")];
      for (const key of ["typeFault", "contractViolation", "hostError", "hostFault"]) {
        const e = new classes[key]({ _msg: "m" });
        assert.ok(e instanceof Error);
        assert.ok(!Object.keys(e).includes('name'));
        assert.equal(e.stack.split('\n')[0], `${e.constructor.$gene_name}: m`);
        assert.throws(() => new classes[key]({ _msg: "m", _cause: 7 }), (err) => err instanceof classes.typeFault);
      }
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

suite "web macros with gensym":
  const swapSource = """
    (mod NAME ^profile web)
    (macro swap [a b]
      (let tmp ($gensym "tmp"))
      `(do (var %tmp %a) (set %a %b) (set %b %tmp)))
    (fn run [] : (List Int)
      (var tmp 1)
      (var y 2)
      (swap tmp y)
      [tmp y])
  """

  proc gensymHash(js: string): string =
    ## The 8 hex digits of the first `tmp_<hash>_0_1` binder in emitted code.
    for start in 0 ..< max(0, js.len - 16):
      if js[start .. start + 3] == "tmp_" and js[start + 12 .. start + 15] == "_0_1":
        let candidate = js[start + 4 .. start + 11]
        var hex = true
        for ch in candidate:
          if ch notin {'0'..'9', 'a'..'f'}: hex = false
        if hex: return candidate

  proc buildSwap(prefix, name: string,
                 run = false): tuple[js: string, exitCode: int, output: string] =
    let root = createTempDir(prefix, "")
    defer: removeDir(root)
    writeFile(root / (name & ".gene"), swapSource.replace("NAME", name))
    discard buildWebModule(root / (name & ".gene"), root / "out")
    result.js = readFile(root / "out" / (name & ".mjs"))
    if run:
      writeFile(root / "out" / "check.mjs",
        "import assert from 'node:assert/strict';\n" &
        "import {run} from './" & name & ".mjs';\n" &
        "assert.deepEqual(run(), [2n, 1n]);\n")
      let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
      result.exitCode = ran.exitCode
      result.output = ran.output

  test "gensym binders are emitted as written and behave correctly":
    let built = buildSwap("gene-web-gensym-run-", "swapper", run = true)
    checkpoint built.output
    check built.exitCode == 0
    check gensymHash(built.js).len == 8

  test "web output is reproducible and names the module":
    let first = buildSwap("gene-web-gensym-one-", "swapper").js
    let second = buildSwap("gene-web-gensym-two-", "swapper").js
    # across checkouts nothing differs: the source is named by file name, not
    # by its absolute path
    check first == second
    check "gene-web-gensym-one-" notin first
    # the hash comes from the module, not from the empty identity
    check gensymHash(first).len == 8
    check gensymHash(first) != "e3b0c442"
    check gensymHash(first) == gensymHash(second)
    check gensymHash(buildSwap("gene-web-gensym-other-", "other").js) !=
      gensymHash(first)

  proc outputs(dir: string): seq[(string, string)] =
    ## Every emitted file, by name, with its bytes.
    var names: seq[string]
    for path in walkFiles(dir / "*"):
      names.add extractFilename(path)
    names.sort()
    for name in names:
      result.add (name, readFile(dir / name))

  test "the same modules build to identical bytes twice, in either order, on several workers":
    let root = createTempDir("gene-web-gensym-det-", "")
    defer: removeDir(root)
    for name in ["alpha", "beta"]:
      writeFile(root / (name & ".gene"), swapSource.replace("NAME", name))
    proc buildBoth(outDir: string, order: openArray[string]) =
      for name in order:
        discard buildWebModule(root / (name & ".gene"), outDir)
    # a second checkout of the same two modules, built to its own directory
    let moved = createTempDir("gene-web-gensym-moved-", "")
    defer: removeDir(moved)
    for name in ["alpha", "beta"]:
      writeFile(moved / (name & ".gene"), swapSource.replace("NAME", name))
    for name in ["alpha", "beta"]:
      discard buildWebModule(moved / (name & ".gene"), moved / "out")
    buildBoth(root / "out_forward", ["alpha", "beta"])
    buildBoth(root / "out_again", ["alpha", "beta"])
    buildBoth(root / "out_reverse", ["beta", "alpha"])
    let reference = outputs(root / "out_forward")
    check reference.len >= 4   # two modules, each with a source map
    # byte-for-byte, the header line included: nothing here is checkout-relative
    check outputs(root / "out_again") == reference
    check outputs(moved / "out") == reference   # another checkout, every byte
    check outputs(root / "out_reverse") == reference
    # the two modules carry different hashes
    var hashes: seq[string]
    for (name, bytes) in reference:
      if name in ["alpha.mjs", "beta.mjs"]: hashes.add gensymHash(bytes)
    check hashes.len == 2
    check hashes[0].len == 8 and hashes[1].len == 8
    check hashes[0] != hashes[1]
    when defined(posix):
      var workers: seq[Pid]
      for worker in 0 ..< 3:
        let child = posix.fork()
        if child == 0:
          try:
            buildBoth(root / ("out_worker" & $worker),
                      if worker mod 2 == 0: ["alpha", "beta"] else: ["beta", "alpha"])
            posix.exitnow(0)
          except CatchableError:
            posix.exitnow(1)
        workers.add child
      for child in workers:
        var status: cint
        discard posix.waitpid(child, status, 0)
        check status == 0
      for worker in 0 ..< 3:
        check outputs(root / ("out_worker" & $worker)) == reference

suite "web navigation host bindings":
  test "web/load source and compilation failures can be caught by Gene":
    let root = createTempDir("gene-web-load-error-", "")
    defer: removeDir(root)
    writeFile(root / "invalid.gene", """
      (mod invalid ^profile web)
      (fn main [root : EventTarget] : Nil (undefined_function root))
    """)
    for entry in ["missing", "invalid"]:
      writeFile(root / (entry & "_host.gene"),
        "(var caught (try ($web/load \"" & root / (entry & ".gene") &
        "\") false catch Error true))")
      let app = newApplication(root)
      let module = app.loadFileModule(root / (entry & "_host.gene"))
      check module.moduleRootNamespace.nsScope.lookup("caught").boolVal

    writeFile(root / "panic.gene", """
      (mod panic_client ^profile web)
      (macro abort [] ($panic "web macro stopped"))
      (fn main [root : EventTarget] : Nil (abort))
    """)
    writeFile(root / "panic_host.gene",
      "(var caught (try ($web/load \"" & root / "panic.gene" &
      "\") nil catch CompileError $err/_cause))")
    let panicApp = newApplication(root)
    # A macro's Panic is a compile failure; the CompileError keeps it as the cause.
    let caught = panicApp.loadFileModule(root / "panic_host.gene").
      moduleRootNamespace.nsScope.lookup("caught")
    check caught.kind == vkNode
    check caught.head.typeName == "Panic"
    check caught.props["_msg"].strVal.contains("web macro stopped")

  test "modal focus helpers and asynchronous module loading use browser primitives":
    let root = createTempDir("gene-web-modal-", "")
    defer: removeDir(root)
    writeFile(root / "modal.gene", """
      (mod modal ^profile web)
      (fn modal [target : EventTarget] : Int
        (var previous ($dom/active_element))
        ($dom/set_inert ($dom/body) true)
        (if (&& ($dom/connected? previous) ($dom/contains? target previous))
          ($dom/focus previous))
        ($size ($dom/focusables target)))
      (fn load [url : Str, ready : (Fn [Any] Nil), error : (Fn [Str] Nil)] : Nil
        ($browser/load_module url ready error))
    """)
    discard buildWebModule(root / "modal.gene", root / "out")
    writeFile(root / "entry.gene", """
      (mod entry ^profile web)
      (fn main [target : EventTarget] : Nil ($dom/set_attribute target "loaded" "yes"))
    """)
    discard buildWebModule(root / "entry.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import { modal, load } from './modal.mjs';
      class Target extends EventTarget {
        isConnected = true;
        contains(node) { return node === this; }
        focus() { this.focused = true; }
        querySelectorAll() { return [this]; }
        hasAttribute() { return false; }
        getAttribute() { return null; }
        getClientRects() { return [{}]; }
        setAttribute(name, value) { this[name] = value; }
      }
      const target = new Target();
      globalThis.document = {activeElement: target, body: target};
      assert.equal(modal(target), 1n);
      assert.equal(target.inert, true);
      assert.equal(target.focused, true);
      await new Promise((resolve, reject) => load(new URL('./entry.mjs', import.meta.url).href,
        module => { module.main(target); resolve(); }, reject));
      assert.equal(target.loaded, 'yes');
      const error = await new Promise(resolve => load(new URL('./missing.mjs', import.meta.url).href,
        () => assert.fail('missing module loaded'), resolve));
      assert.match(error, /missing/);
      let loadFailure = false;
      const readyError = await new Promise(resolve => {
        process.once('unhandledRejection', resolve);
        load(new URL('./entry.mjs', import.meta.url).href,
          () => { throw new Error('ready callback failed'); },
          () => { loadFailure = true; resolve(new Error('misclassified as load failure')); });
      });
      assert.equal(readyError.message, 'ready callback failed');
      assert.equal(loadFailure, false);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "capture listeners preserve removal identity and shortcut fields use native events":
    let root = createTempDir("gene-web-navigation-", "")
    defer: removeDir(root)
    writeFile(root / "navigation.gene", """
      (mod navigation ^profile web)
      (fn install [target : EventTarget, handler : (Fn [Any] Nil)] : Nil
        ($dom/add_event_listener ^^capture target "keydown" handler)
        ($dom/remove_event_listener ^^capture target "keydown" handler))
      (fn shortcut [event : Any] : Bool
        (&& ($event/ctrl_key event) ($event/shift_key event)
          (! ($event/alt_key event)) (! ($event/meta_key event))
          (! ($event/repeat event)) (! ($event/is_composing event))
          (== ($event/code event) "Digit2")))
      (fn focused [target : EventTarget] : Bool ($dom/focused? target))
      (fn visit [url : Str] : Nil ($browser/push_url url))
    """)
    discard buildWebModule(root / "navigation.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import { install, shortcut, focused, visit } from './navigation.mjs';
      class Target extends EventTarget {
        addEventListener(type, handler, capture) { this.added = {type, handler, capture}; }
        removeEventListener(type, handler, capture) { this.removed = {type, handler, capture}; }
      }
      const target = new Target();
      install(target, () => {});
      assert.equal(target.added.type, 'keydown');
      assert.equal(target.added.capture, true);
      assert.equal(target.removed.handler, target.added.handler);
      assert.equal(target.removed.capture, true);
      const event = { code:'Digit2', key:'@', ctrlKey:true, shiftKey:true,
        altKey:false, metaKey:false, repeat:false, isComposing:false };
      assert.equal(shortcut(event), true);
      assert.equal(shortcut({...event, repeat:true}), false);
      assert.equal(shortcut({...event, isComposing:true}), false);
      assert.equal(shortcut({...event, ctrlKey:false}), false);
      target.ownerDocument = { activeElement: target };
      assert.equal(focused(target), true);
      target.ownerDocument.activeElement = null;
      assert.equal(focused(target), false);
      globalThis.history = { pushState(...args) { this.last = args; } };
      visit('/?view=desk');
      assert.deepEqual(history.last, [null, '', '/?view=desk']);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

proc checkWebExportRejection(facade, selection, expected: string) =
  let root = createTempDir("gene-web-exports-", "")
  defer: removeDir(root)
  writeFile(root / "provider.gene", "(mod provider ^profile web) " &
    "(type Thing ^props {^value Int}) (let count 3) " &
    "(fn make [] : Thing (Thing ^value count))")
  writeFile(root / "facade.gene", "(mod facade ^profile web) " & facade)
  writeFile(root / "entry.gene", "(mod entry ^profile web) " &
    "(import " & selection & " ^from \"./facade.gene\") (fn run [] : Int 0)")
  var diagnostic = ""
  try:
    discard buildWebModule(root / "entry.gene", root / "out")
  except WebProfileError as error:
    diagnostic = error.msg
  check expected in diagnostic

suite "web JSON data properties":
  test "parsed maps retain exact dynamic keys across mutation and round trips":
    let root = createTempDir("gene-web-json-properties-", "")
    defer: removeDir(root)
    writeFile(root / "properties.gene", """
      (mod properties ^profile web)
      (fn parse [source : Str] : Any ($json/parse source))
      (fn put [data : Any, key : Str, value : Any] : Nil (set data/%key value))
      (fn get [data : Any, key : Str] : Any data/%key)
      (fn remove [data : Any, key : Str] : Nil (data .delete key))
      (fn names [data : PropMap] : (List Str)
        (var keys : (List Str) [])
        (map_for [key value] in data (keys .push ($to_str key)))
        keys)
      (fn encode [data : Any] : Str ($json/stringify data))
    """)
    # A parser-only module must also emit the PropMap runtime it now needs.
    writeFile(root / "parser.gene", """
      (mod parser ^profile web)
      (fn parse [source : Str] : Any ($json/parse source))
    """)
    discard buildWebModule(root / "properties.gene", root / "out")
    discard buildWebModule(root / "parser.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import { parse, put, get, remove, names, encode } from './properties.mjs';
      import { parse as parseOnly } from './parser.mjs';
      const data = parse('{"nested":{},"labelReady":"separate","duplicate":1,"duplicate":2,"__proto__":{"safe":true}}');
      put(data, 'label_ready', true);
      put(data.nested, 'mount_checked', false);
      assert.equal(get(data, 'label_ready'), true);
      assert.equal(get(data, 'labelReady'), 'separate');
      assert.equal(get(data, 'missing_key'), null);
      assert.equal(get(data, '__proto__').safe, true);
      assert.equal(Object.getPrototypeOf(data), Object.prototype);
      assert.deepEqual(names(data), ['nested','labelReady','duplicate','__proto__','label_ready']);
      assert.equal(data.duplicate, 2n);
      remove(data, 'label_ready');
      assert.equal(get(data, 'label_ready'), null);
      assert.equal(get(data, 'labelReady'), 'separate');
      put(data, 'label_ready', false);
      assert.equal(parse(encode(data)).label_ready, false);
      assert.equal(parse(encode(data)).nested.mount_checked, false);
      const empty = parseOnly('{}');
      put(empty, 'label_ready', true);
      assert.equal(empty.label_ready, true);
      // Host interop still uses camelCase for ordinary foreign objects.
      const host = { textContent: 'before' };
      put(host, 'text_content', 'after');
      assert.equal(host.textContent, 'after');
      assert.equal(get(host, 'text_content'), 'after');
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

suite "web function fields":
  test "typed function paths capture the callee before argument effects":
    let root = createTempDir("gene-web-function-fields-", "")
    defer: removeDir(root)
    let source = """
      (mod callbacks ^profile web)
      (type Holder ^props {^call (Fn [Int] Int)})
      (fn change [holder : Holder] : Int
        (set holder/call (fn [value : Int] : Int (- value 100)))
        1)
      (fn run [] : Int
        (let holder (Holder ^call (fn [value : Int] : Int (+ value 41))))
        (holder/call (change holder)))
    """
    writeFile(root / "callbacks.gene", source)
    discard buildWebModule(root / "callbacks.gene", root / "out")
    writeFile(root / "out" / "check.mjs",
      "import { run } from './callbacks.mjs'; " &
      "if (run() !== 42n) throw new Error('function field was read after its arguments');")
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0
    expect WebProfileError:
      discard analyzeWebModule(source.replace("(holder/call (change holder))",
        "(holder/call \"wrong type\")"), "callbacks.gene")

suite "web module import syntax":
  test "load-only imports emit a dependency without bindings":
    let root = createTempDir("gene-web-load-only-", "")
    defer: removeDir(root)
    writeFile(root / "setup.gene",
      "(mod setup ^profile web) (const answer 42)")
    writeFile(root / "entry.gene", """
      (mod entry ^profile web)
      (import ^from "./setup")
      (const answer 7)
      (fn run [] : Int answer)
    """)
    let output = root / "out"
    discard buildWebModule(root / "entry.gene", output)
    check "import \"./setup.mjs\";" in readFile(output / "entry.mjs")
    check "import \"./setup.js\";" in readFile(output / "entry.ts")
    let setupPath = output / "setup.mjs"
    writeFile(setupPath, readFile(setupPath) & "\nglobalThis.setupRan = true;\n")
    writeFile(output / "check.mjs",
      "import {run} from './entry.mjs'; " &
      "if (!globalThis.setupRan || run() !== 7n) throw Error('bad load-only import');")
    let ran = execCmdEx("node " & quoteShell(output / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "source properties work in either position with aliases and re-exports":
    let root = createTempDir("gene-web-imports-", "")
    defer: removeDir(root)
    writeFile(root / "provider.gene", "(mod provider ^profile web) " &
      "(let from 7)")
    for source in [
      "(import from:value ^from \"./provider.gene\")",
      "(import ^from \"./provider.gene\" from:value)",
      "(import ^^export from:value ^from \"./provider.gene\")"
    ]:
      writeFile(root / "entry.gene", "(mod entry ^profile web) " & source &
        " (fn run [] : Int value)")
      discard buildWebModule(root / "entry.gene", root / "out")

  test "groups select qualified functions and re-export aliases":
    let root = createTempDir("gene-web-grouped-imports-", "")
    defer: removeDir(root)
    writeFile(root / "provider.gene", """
      (mod provider ^profile web)
      (ns calculations
        (fn identity [x : Int] : Int x)
        (ns arithmetic
          (fn add [x : Int y : Int] : Int (+ x y))
          (fn double [x : Int] : Int (* x 2))))
    """)
    writeFile(root / "facade.gene", """
      (mod facade ^profile web)
      (import calculations/[identity arithmetic/[add:sum double]]
        ^from "./provider.gene" ^^export)
    """)
    writeFile(root / "entry.gene", """
      (mod entry ^profile web)
      (import identity sum double ^from "./facade.gene")
      (fn run [] : Int (sum (identity 10) (double 16)))
    """)
    discard buildWebModule(root / "entry.gene", root / "out")
    writeFile(root / "out" / "check.mjs",
      "import {run} from './entry.mjs'; if (run() !== 42n) throw Error('bad import');")
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "old syntax and malformed source properties are rejected":
    for (source, expected) in [
      ("(import [Thing] from \"./provider.gene\")", "`from` was removed; use `^from"),
      ("(import [Thing])", "web imports must use"),
      ("(import [] ^from \"./provider.gene\")", "omit `[]` to load a module without bindings"),
      ("(import ^from \"./provider.gene\" ^^export)", "load-only imports cannot re-export"),
      ("(import [Thing] ^from \"./provider.gene\")", "file import selectors go directly after"),
      ("(import Thing : Alias ^from \"./provider.gene\")", "write the import alias as `Thing:Alias`"),
      ("(import * ^from \"./provider.gene\")", "wildcard imports are outside the web profile"),
      ("(import Thing ^from \"./provider.gene\" ^pkg \"target\")", "package imports are outside the web profile"),
      ("(import Thing ^from provider)", "^from must be a path string"),
      ("(import Thing ^from 42)", "^from must be a path string"),
      ("(import Thing ^from nil)", "^from must be a path string"),
      ("(import Thing ^^from)", "^from must be a path string"),
      ("(import Thing ^from \"./provider.gene\" ^^form)", "unexpected option: ^form")
    ]:
      checkpoint source
      checkWebExportRejection(source, "Thing", expected)

suite "web module export boundaries":
  test "ordinary imports do not implicitly re-export any declaration kind":
    for name in ["Thing", "count", "make"]:
      checkWebExportRejection(
        "(import Thing count make ^from \"./provider.gene\")", name,
        "no exported declaration: " & name)

  test "explicit false keeps an import private":
    checkWebExportRejection(
      "(import Thing ^from \"./provider.gene\" ^!export)", "Thing",
      "no exported declaration: Thing")

  test "export policy must be a literal boolean":
    checkWebExportRejection(
      "(import Thing ^from \"./provider.gene\" ^export \"yes\")", "Thing",
      "^export must be Bool")

suite "web optional parameter defaults":
  test "foreign signatures keep nullable positions required and reject defaults":
    discard analyzeWebModule("""
      (mod foreign_defaults ^profile web)
      (js/fn host [x : Int? y : Int] : Int ^from "./host.mjs")
      (fn run [] : Int (host nil 1))
    """, "foreign_defaults.gene")
    for source in [
      "(js/fn host [x : Int?] : Int ^from \"./host.mjs\") (fn run [] : Int (host))",
      "(js/fn host [x : Int = 1] : Int ^from \"./host.mjs\")"
    ]:
      expect WebProfileError:
        discard analyzeWebModule("(mod foreign_defaults ^profile web) " & source,
                                 "foreign_defaults.gene")
  test "synchronous callables reject suspending defaults including forward calls":
    for declaration in [
      "(type A ^props {} (message value [x : Int = (later)] : Int x))",
      "(type A ^props {} (ctor [x : Int = (later)] nil))",
      "(protocol P (message value [x : Int = (later)] : Int x))",
      "(protocol P (message value [x : Int = 1] : Int)) " &
        "(type A ^props {}) (impl P for A " &
        "(message value [x : Int = (later)] : Int x))",
      "(fn run [] : Int (let f (fn [x : Int = (later)] : Int x)) (f))"
    ]:
      var diagnostic = ""
      try:
        discard analyzeWebModule("(mod optional_defaults ^profile web) " &
          declaration & " (fn later [] : Int (scope 1))", "optional_defaults.gene")
      except WebProfileError as error:
        diagnostic = error.msg
      check "async parameter defaults are limited to top-level functions" in diagnostic

suite "web namespace values":
  test "a qualified extension keeps its declaration-site lexical lookup":
    var message = ""
    try:
      discard analyzeWebModule("""
        (mod namespace_lexical ^profile web)
        (ns n (fn helper [] : Int 2))
        (fn n/test [] : Int (helper))
      """, "namespace_lexical.gene")
    except WebProfileError as error:
      message = error.msg
    check "helper" in message
    check "unknown or unsupported web function" in message

  test "namespace values are branded identity values":
    let root = createTempDir("gene-web-namespace-identity-", "")
    defer: removeDir(root)
    writeFile(root / "namespace_identity.gene", """
      (mod namespace_identity ^profile web)
      (ns a)
      (ns b)
      (fn typed [x : Namespace y : Namespace] : Bool (== x y))
      (fn any_equal [x : Any y : Any] : Bool (== x y))
      (fn take_ns [x : Namespace] : Bool true)
      (fn array_as_any [] : Any [1])
      (fn probe [] : (List Bool)
        [(typed a b)
         (any_equal a b)
         (any_equal a a)
         (try (take_ns (array_as_any)) catch TypeFault false)])
    """)
    discard buildWebModule(root / "namespace_identity.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {probe} from './namespace_identity.mjs';
      assert.deepEqual(probe(), [false, false, true, false]);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

suite "web named rest and property spread":
  test "named rest collects unmatched props and spread forwards them":
    let root = createTempDir("gene-web-named-rest-", "")
    defer: removeDir(root)
    writeFile(root / "named_rest.gene", """
      (mod named_rest ^profile web)
      (fn take [^x : Int] : Int x)
      (fn collect [^attrs...] : PropMap attrs)
      (fn typed [^opts... : Int] : Int opts/count)
      (fn via_map [] : PropMap
        (let attrs {^class "card" ^id "main"})
        (collect attrs...))
      (fn via_explicit [] : PropMap
        (collect ^class "card" ^id "main"))
      (fn override [] : Int
        (let attrs {^x 2})
        (take ^x "discarded" attrs...))
      (fn via_general_map [] : PropMap
        (let attrs {{"class": "card"}})
        (collect attrs...))
      (fn typed_run [] : Int
        (typed ^count 2))
      (fn typed_bad [] : Bool
        (try (typed ^count "bad") false catch TypeFault true))
    """)
    discard buildWebModule(root / "named_rest.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {via_map, via_explicit, via_general_map, override, typed_run, typed_bad} from './named_rest.mjs';
      assert.equal(via_map().class, 'card');
      assert.equal(via_map().id, 'main');
      assert.equal(via_explicit().class, 'card');
      assert.equal(via_explicit().id, 'main');
      assert.equal(via_general_map().class, 'card');
      assert.equal(override(), 2n);
      assert.equal(typed_run(), 2n);
      assert.equal(typed_bad(), true);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "imported named rest signatures keep collecting and spreading props":
    let root = createTempDir("gene-web-import-named-rest-", "")
    defer: removeDir(root)
    writeFile(root / "attrs_lib.gene", """
      (mod attrs_lib ^profile web)
      (fn collect [^attrs...] : PropMap attrs)
    """)
    writeFile(root / "attrs_main.gene", """
      (mod attrs_main ^profile web)
      (import collect ^from "./attrs_lib.gene")
      (fn run [] : PropMap
        (let attrs {^class "card"})
        (collect attrs...))
    """)
    discard buildWebModule(root / "attrs_main.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {run} from './attrs_main.mjs';
      assert.equal(run().class, 'card');
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

suite "web map-family operations":
  test "map family reads entries and list family rejects maps":
    let root = createTempDir("gene-web-map-family-", "")
    defer: removeDir(root)
    writeFile(root / "map_family.gene", """
      (mod map_family ^profile web)
      (fn size_probe [] : Int
        (let m {^x 1 ^y 2})
        ($map_size m))
      (fn empty_probe [] : Bool
        (let m {^x 1})
        ($map_empty? m))
      (fn collection_counts [] : (List Any)
        (let items [1 2])
        (let props {^x nil})
        (let entries {{"x": 1 "y": 2}})
        (let empty_items : (List Int) [])
        [items/.size items/.empty? empty_items/.size empty_items/.empty?
         (props .size) (props .empty?) ({} .size) ({} .empty?)
         entries/.size entries/.empty?])
      (fn optional_map_size [m : PropMap?] : Int? m/?.size)
      (fn optional_list_empty [xs : (| (List Int) Nil)] : Bool? xs/?.empty?)
      (fn map_probe [] : (Map Str Int)
        (let m {{"x": 1 "y": 2}})
        ($map_map m (fn [v : Int] : Int (* v 10))))
      (fn filter_probe [] : (Map Str Int)
        (let m {{"x": 1 "y": 2}})
        ($map_filter m (fn [v : Int] : Bool (> v 1))))
      (fn pair_probe [] : (List Any)
        (var out : (List Any) [])
        (let m {{"x": 1 "y": 2}})
        (map_for [k v] in m (out .push {^key k ^value v}))
        out)
    """)
    discard buildWebModule(root / "map_family.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {size_probe, empty_probe, collection_counts, optional_map_size,
              optional_list_empty, map_probe, filter_probe, pair_probe} from './map_family.mjs';
      assert.equal(size_probe(), 2n);
      assert.equal(empty_probe(), false);
      assert.deepEqual(collection_counts(), [2n, false, 0n, true, 1n, false, 0n, true, 2n, false]);
      assert.equal(optional_map_size(null), null);
      assert.equal(optional_map_size({x: null}), 1n);
      assert.equal(optional_list_empty(null), null);
      assert.equal(optional_list_empty([1n]), false);
      assert.equal(optional_list_empty([]), true);
      assert.equal(map_probe().get('x'), 10n);
      assert.equal(map_probe().get('y'), 20n);
      assert.equal(filter_probe().has('x'), false);
      assert.equal(filter_probe().get('y'), 2n);
      assert.deepEqual(pair_probe().map(pair => [pair.key, pair.value]), [['x', 1n], ['y', 2n]]);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0

  test "the web profile rejects list-family calls on maps and extra count arguments":
    for (source, hint) in [
      ("(let m {^x 1}) ($size m)", "map_size"),
      ("(let m {^x 1}) (m .size 1)", "expects no message arguments"),
      ("(let m {^x 1}) (m .empty? ^flag true)", "named message arguments"),
      ("(let m {^x 1}) (for [k v] in m nil)", "map_for"),
      ("(let m {^x 1}) (m .map (fn [v : Any] : Any v))", "map_map"),
      ("(let m {^x 1}) ($each m (fn [v : Any] : Any v))", "map_each")
    ]:
      var message = ""
      try:
        discard analyzeWebModule("(mod map_reject ^profile web) " &
          "(fn rejected [] : Any " & source & ")", "map_reject.gene")
      except WebProfileError as error:
        message = error.msg
      check hint in message

  test "dynamic size preserves the Map rejection through Any":
    let root = createTempDir("gene-web-map-any-size-", "")
    defer: removeDir(root)
    writeFile(root / "map_any_size.gene", """
      (mod map_any_size ^profile web)
      (fn size_any [value : Any] : Int ($size value))
      (fn map_size_any [] : Int (size_any {{"x": 1}}))
      (fn list_size_any [] : Int (size_any [1 2]))
    """)
    discard buildWebModule(root / "map_any_size.gene", root / "out")
    writeFile(root / "out" / "check.mjs", """
      import assert from 'node:assert/strict';
      import {map_size_any, list_size_any} from './map_any_size.mjs';
      assert.throws(map_size_any, /map_size/);
      assert.equal(list_size_any(), 2n);
    """)
    let ran = execCmdEx("node " & quoteShell(root / "out" / "check.mjs"))
    checkpoint ran.output
    check ran.exitCode == 0
