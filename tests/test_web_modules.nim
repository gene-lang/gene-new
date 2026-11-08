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
        "\") false catch Any true))")
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
      "\") false catch Any true))")
    let panicApp = newApplication(root)
    expect GenePanic:
      discard panicApp.loadFileModule(root / "panic_host.gene")

  test "modal focus helpers and asynchronous module loading use browser primitives":
    let root = createTempDir("gene-web-modal-", "")
    defer: removeDir(root)
    writeFile(root / "modal.gene", """
      (mod modal ^profile web)
      (fn modal [target : EventTarget] : Int
        (var previous ($dom/active_element))
        ($dom/set_inert ($dom/body) true)
        (if_yes (&& ($dom/connected? previous) ($dom/contains? target previous))
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
    "(import [" & selection & "] ^from \"./facade.gene\") (fn run [] : Int 0)")
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
        (for [key value] in data (keys .push ($to_str key)))
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
  test "source properties work in either position with aliases and re-exports":
    let root = createTempDir("gene-web-imports-", "")
    defer: removeDir(root)
    writeFile(root / "provider.gene", "(mod provider ^profile web) " &
      "(let from 7)")
    for source in [
      "(import [from : value] ^from \"./provider.gene\")",
      "(import ^from \"./provider.gene\" [from : value])",
      "(import ^^export [from : value] ^from \"./provider.gene\")"
    ]:
      writeFile(root / "entry.gene", "(mod entry ^profile web) " & source &
        " (fn run [] : Int value)")
      discard buildWebModule(root / "entry.gene", root / "out")

  test "old syntax and malformed source properties are rejected":
    for (source, expected) in [
      ("(import [Thing] from \"./provider.gene\")", "`from` was removed; use `^from"),
      ("(import [Thing])", "web imports must be"),
      ("(import ^from \"./provider.gene\")", "web imports must be"),
      ("(import [Thing] extra ^from \"./provider.gene\")", "web imports must be"),
      ("(import [Thing] ^from provider)", "^from must be a path string"),
      ("(import [Thing] ^from 42)", "^from must be a path string"),
      ("(import [Thing] ^from nil)", "^from must be a path string"),
      ("(import [Thing] ^^from)", "^from must be a path string"),
      ("(import [Thing] ^from \"./provider.gene\" ^^form)", "unexpected named argument: form")
    ]:
      checkpoint source
      checkWebExportRejection(source, "Thing", expected)

suite "web module export boundaries":
  test "ordinary imports do not implicitly re-export any declaration kind":
    for name in ["Thing", "count", "make"]:
      checkWebExportRejection(
        "(import [Thing count make] ^from \"./provider.gene\")", name,
        "no exported declaration: " & name)

  test "explicit false keeps an import private":
    checkWebExportRejection(
      "(import [Thing] ^from \"./provider.gene\" ^!export)", "Thing",
      "no exported declaration: Thing")

  test "export policy must be a literal boolean":
    checkWebExportRejection(
      "(import [Thing] ^from \"./provider.gene\" ^export \"yes\")", "Thing",
      "^export must be a literal Bool")

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
