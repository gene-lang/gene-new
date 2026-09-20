import std/[os, tempfiles, unittest]
import gene/[capabilities, compiler, printer, types, vm]
import ./capability_test_support

proc evalAuthorityProbe(source: string): string =
  let root = expandFilename(createTempDir("gene-eval-authority-", ""))
  defer: removeDir(root)
  createDir(root / "one")
  createDir(root / "two")
  let first = root / "one" / "data"
  let second = root / "two" / "data"
  writeFile(first, "first")
  writeFile(second, "second")
  let app = newFilesystemPolicyApp(root)
  let scope = newGlobalScope(app)
  scope.define("first", newStr(first))
  scope.define("second", newStr(second))
  scope.define("first_tree", newStr(root / "one"))
  let prefix = """
    (let first_policy ($capabilities/build [
      ($capabilities/entry "fs/Read" [first_tree] [])]))
    (fn can_read_first []
      (let report ($capabilities/check_requirements first_policy))
      report/admitted)
  """
  run(compileSource(prefix & source), scope).print()

suite "eval capability ceilings":
  test "dynamic Env bounds are evaluated once and cannot be widened later":
    check evalAuthorityProbe("""
      (let count ($cell 0))
      (fn choose [] (count .set (+ (count .get) 1)) first_policy)
      (let saved (env ^capabilities (choose)))
      [(count .get)
       (eval (quote ($fs/read_text first)) ^in saved)
       (try (eval (quote ($fs/read_text second)) ^in saved)
         catch MissingCapability "denied")
       (count .get)]
    """) == "[1 \"first\" \"denied\" 1]"

  test "Env bounds reject optional metadata and ordinary values":
    for source in [
      "(env ^capabilities [(fs/Read ^^optional)])",
      "(env ^capabilities ($capabilities/parse \"[(fs/Read ^^optional)]\"))",
      "(env ^capabilities nil)",
      "(env ^capabilities {^fs first_tree})",
      "(env ^capabilities [] ^capabilities [fs/Read])"]:
      checkpoint source
      expect GeneError:
        discard evalAuthorityProbe(source)

  test "a retained Env cannot restore authority removed by its evaluator":
    check evalAuthorityProbe("""
      (let saved (env ^capabilities [fs/Read]))
      [(try
         (with_capabilities []
           (eval (quote ($fs/read_text first)) ^in saved))
         catch MissingCapability "denied")
       (eval (quote ($fs/read_text first)) ^in saved)]
    """) == "[\"denied\" \"first\"]"

  test "both the Env and evaluator constrain the selected resource tree":
    check evalAuthorityProbe("""
      (let broad (env ^capabilities [fs/Read]))
      (let only_first (env ^capabilities first_policy))
      [(eval (quote ($fs/read_text first)) ^in only_first)
       (try (eval (quote ($fs/read_text second)) ^in only_first)
         catch MissingCapability "denied")
       (with_capabilities first_policy
         (eval (quote ($fs/read_text first)) ^in broad))
       (try
         (with_capabilities first_policy
           (eval (quote ($fs/read_text second)) ^in broad))
         catch MissingCapability "denied")]
    """) == "[\"first\" \"denied\" \"first\" \"denied\"]"

  test "omitted rows inherit dynamically and explicit rows retain creation limits":
    check evalAuthorityProbe("""
      (let plain (env ^bindings {^input 1}))
      (let empty (env ^capabilities []))
      (let captured (with_capabilities [] (env ^capabilities [fs/Read])))
      [(eval (quote (can_read_first)) ^in plain)
       (with_capabilities []
         (eval (quote (can_read_first)) ^in plain))
       (eval (quote (can_read_first)) ^in empty)
       (eval (quote (can_read_first)) ^in captured)]
    """) == "[true false false false]"

  test "extending an Env cannot remove its parent's capability ceiling":
    check evalAuthorityProbe("""
      (let parent (env ^capabilities []))
      (let extended (parent .extend {^input 1}))
      (let reselected (env ^parent parent ^capabilities [fs/Read]))
      [(try (eval (quote ($fs/read_text first)) ^in extended)
         catch MissingCapability "denied")
       (try (eval (quote ($fs/read_text first)) ^in reselected)
         catch MissingCapability "denied")]
    """) == "[\"denied\" \"denied\"]"

  test "escaped eval closures retain the intersected creation ceiling":
    check evalAuthorityProbe("""
      (let saved (env ^capabilities [fs/Read]))
      (let code (quote (fn [path] ($fs/read_text path))))
      (let broad (eval code ^in saved))
      (let limited (with_capabilities first_policy (eval code ^in saved)))
      [(limited first)
       (try (limited second) catch MissingCapability "denied")
       (try (with_capabilities [] (broad first)) catch MissingCapability "denied")
       (broad second)]
    """) == "[\"first\" \"denied\" \"denied\" \"second\"]"

  test "nested eval and suspended generators preserve the effective ceiling":
    check evalAuthorityProbe("""
      (let saved (env ^capabilities [fs/Read]))
      (let rows
        (with_capabilities first_policy
          (eval (quote
            (do
              (fn ^^generator produce []
                (yield ($fs/read_text first))
                (yield ($fs/read_text second)))
              (produce))) ^in saved)))
      [(try
         (with_capabilities []
           (eval (quote (eval (quote ($fs/read_text first)) ^in saved)) ^in saved))
         catch MissingCapability "denied")
       (rows .next)
       (try (rows .next) catch MissingCapability "denied")
       ($fs/read_text second)]
    """) == "[\"denied\" \"first\" \"denied\" \"second\"]"

  test "nested eval closures retain ceilings through calls and spawn":
    check evalAuthorityProbe("""
      (let saved (env ^capabilities first_policy))
      (let factory (eval (quote (fn [] (fn [path : Str = second] ($fs/read_text path)))) ^in saved))
      (let nested (factory))
      [(nested first)
       (try (nested) catch MissingCapability "denied")
       (scope (await (spawn
         (try (nested second) catch MissingCapability "denied"))))]
    """) == "[\"first\" \"denied\" \"denied\"]"

  test "closing an eval generator restores its caller's context":
    check evalAuthorityProbe("""
      (let closed ($cell false))
      (let saved (env ^capabilities first_policy))
      (let rows (eval (quote
        (do (fn ^^generator produce []
              (try (yield ($fs/read_text first))
                ensure (closed .set (can_read_first))))
            (produce))) ^in saved))
      (let value (rows .next))
      (rows .close)
      [value (closed .get) ($fs/read_text second)]
    """) == "[\"first\" true \"second\"]"

  test "spawn and suspension retain the context without narrowing the parent":
    check evalAuthorityProbe("""
      (scope
        (let ready ($channel ^capacity 1))
        (let resume ($channel ^capacity 1))
        (let task (with_capabilities []
          (spawn ^lane root (do
            (ready .send true)
            (resume .recv)
            (try ($fs/read_text first) catch MissingCapability "denied")))))
        (ready .recv)
        (let parent_value ($fs/read_text first))
        (resume .send true)
        [(await task) parent_value])
    """) == "[\"denied\" \"first\"]"

  test "plain closure creation stays dynamic while explicit binding captures":
    check evalAuthorityProbe("""
      (let plain (with_capabilities [] (fn [] ($fs/read_text first))))
      (let retained (with_capabilities [] ($runtime/bind_call plain [])))
      [(plain)
       (try (retained) catch MissingCapability "denied")
       (try (with_capabilities [] (plain)) catch MissingCapability "denied")]
    """) == "[\"first\" \"denied\" \"denied\"]"

  test "adapter close keeps its creation bound over upstream cleanup":
    for adapter in ["($map upstream (fn [x] x))",
                    "($filter upstream (fn [x] true))",
                    "($take upstream 2)", "(upstream => (fn [x] x))"]:
      checkpoint adapter
      check evalAuthorityProbe("""
        (let effects [])
        (fn ^^generator produce []
          (try (yield 1) (yield 2)
            ensure (effects .push
              (try ($fs/read_text first) catch MissingCapability "denied"))))
        (let upstream (produce))
        (upstream .next)
        (let bounded (with_capabilities [] """ & adapter & """))
        (bounded .close)
        (bounded .close)
        [effects (upstream .has_next) ($fs/read_text first)]
      """) == "[[\"denied\"] false \"first\"]"

  test "closing a suspended callback intersects saved frames with the closer":
    for adapter in ["($map ($to_stream [1]) visit)",
                    "($filter ($to_stream [1]) visit)", "([1] => visit)"]:
      checkpoint adapter
      check evalAuthorityProbe("""
        (scope
          (let ready ($channel ^capacity 1))
          (let waiting ($channel ^capacity 1))
          (let effects [])
          (fn visit [x]
            (try
              (with_capabilities [fs/Read]
                (ready .send true)
                (waiting .recv)
                x)
              ensure (effects .push
                (try ($fs/read_text first) catch MissingCapability "denied"))))
          (let pending """ & adapter & """)
          (let consumer (spawn ^lane root (pending -> $into [])))
          (let closer (spawn ^lane root
            (do (ready .recv) (with_capabilities [] (pending .close)))))
          (closer .join)
          (consumer .join)
          [effects (pending .has_next) ($fs/read_text first)])
      """) == "[[\"denied\"] false \"first\"]"

  test "a callback closing its own stream cannot restore authority in ensure":
    check evalAuthorityProbe("""
      (scope
        (let effects [])
        (var pending nil)
        (fn visit [x]
          (try (with_capabilities [] (pending .close))
            ensure (effects .push
              (try ($fs/read_text first) catch MissingCapability "denied"))))
        (set pending ([1] => visit))
        (let consumer (spawn ^lane root (pending -> $into [])))
        (consumer .join)
        [effects ($fs/read_text first)])
    """) == "[[\"denied\"] \"first\"]"

  test "close restrictions survive cleanup suspension without narrowing other tasks":
    check evalAuthorityProbe("""
      (scope
        (let ready ($channel ^capacity 1))
        (let waiting ($channel ^capacity 1))
        (let cleaning ($channel ^capacity 1))
        (let release ($channel ^capacity 1))
        (let effects [])
        (fn visit [x]
          (try (ready .send true) (waiting .recv) x
            ensure
              (cleaning .send true)
              (release .recv)
              (effects .push
                (try ($fs/read_text first) catch MissingCapability "denied"))))
        (let pending ([1] => visit))
        (let consumer (spawn ^lane root (pending -> $into [])))
        (let closer (spawn ^lane root
          (do (ready .recv) (with_capabilities [] (pending .close)))))
        (let witness (spawn ^lane root
          (do (cleaning .recv)
              (let value ($fs/read_text first))
              (release .send true) value)))
        (closer .join)
        (consumer .join)
        [effects (await witness) ($fs/read_text first)])
    """) == "[[\"denied\"] \"first\" \"first\"]"
