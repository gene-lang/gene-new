import gene/web
import std/[os, osproc, strutils, tempfiles, unittest]

suite "web navigation host bindings":
  test "capture listeners preserve removal identity and shortcut fields use native events":
    let root = createTempDir("gene-web-navigation-", "")
    defer: removeDir(root)
    writeFile(root / "navigation.gene", """
      (mod navigation ^profile web)
      (fn install [target : EventTarget, handler : (Fn [Any] Void)] : Void
        ($dom/add_event_listener ^^capture target "keydown" handler)
        ($dom/remove_event_listener ^^capture target "keydown" handler))
      (fn shortcut [event : Any] : Bool
        (&& ($event/ctrl_key event) ($event/shift_key event)
          (! ($event/alt_key event)) (! ($event/meta_key event))
          (! ($event/repeat event)) (! ($event/is_composing event))
          (== ($event/code event) "Digit2")))
      (fn focused [target : EventTarget] : Bool ($dom/focused? target))
      (fn visit [url : Str] : Void ($browser/push_url url))
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
      (fn put [data : Any, key : Str, value : Any] : Void (set data/%key value))
      (fn get [data : Any, key : Str] : Any data/%key)
      (fn remove [data : Any, key : Str] : Void (set data/%key void))
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
      assert.equal(get(data, 'missing_key'), undefined);
      assert.equal(get(data, '__proto__').safe, true);
      assert.equal(Object.getPrototypeOf(data), Object.prototype);
      assert.deepEqual(names(data), ['nested','labelReady','duplicate','__proto__','label_ready']);
      assert.equal(data.duplicate, 2n);
      remove(data, 'label_ready');
      assert.equal(get(data, 'label_ready'), undefined);
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
