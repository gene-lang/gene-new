## Shared VM/wasm semantic samples and refusal at unsupported compiler boundaries.
import gene/[compiler, gir, printer, types, vm, web]
import std/[json, strutils, unittest]

suite "value operations — backend boundaries":
  test "native VM agrees with the shared wasm samples":
    let manifest = parseFile("tests/fixtures/value_operations.json")
    for fixture in manifest["cases"]:
      let scope = newGlobalScope()
      var actual = ""
      var status = 0
      var chunk: Chunk
      try: chunk = compileSource(fixture["source"].getStr())
      except CatchableError as error:
        status = 3
        actual = error.msg
      if status == 0:
        try: actual = run(chunk, scope).print()
        except GenePanic as error:
          status = 2
          actual = error.msg
        except CatchableError as error:
          status = 1
          actual = error.msg
      checkpoint fixture["id"].getStr()
      check status == fixture{"status"}.getInt(0)
      if fixture.hasKey("contains"):
        check fixture["contains"].getStr() in actual
      else:
        check actual == fixture["text"].getStr()

  let eq = "(impl ValueEq for Key (message equal [other : Key] : Bool true)) "
  let indexed = "(impl IndexRead for Key (message size [] : Int 1) " &
                "(message at [index : Int] : Any nil)) "
  let declarations = @[
    ("ValueEq", eq),
    ("ValueHash", eq & "(impl ValueHash for Key (message hash [] : Int 7)) "),
    ("ValueOrder", "(impl ValueOrder for Key (message compare [other : Key] : Int 0)) "),
    ("IndexRead", indexed),
    ("IndexWrite", indexed & "(impl IndexWrite for Key " &
     "(message put_at [index : Int value : Any] : Any value)) ")]

  test "web emission refuses unavailable canonical value witnesses":
    for (name, declaration) in declarations:
      var rejected = false
      try:
        discard analyzeWebModule("(mod boundary ^profile web) " &
                                 "(type Key ^props {}) " & declaration,
                                 "value_boundary.gene")
      except WebProfileError as error:
        rejected = true
        check "unknown web protocol" in error.msg
      checkpoint name
      check rejected

  test "typed-native C emission refuses witness-bearing native wrappers":
    for (name, declaration) in declarations:
      let operation = case name
        of "ValueEq": "(== a a)"
        of "ValueHash": "($hash a)"
        of "ValueOrder": "(< a a)"
        of "IndexRead": "a/0"
        else: "(set a/0 1)"
      let returnType = if name in ["ValueEq", "ValueOrder"]: "Bool" else: "Int"
      let source = "(ffi/struct Raw ^fields []) " &
        "(type Key ^native {^abi Raw ^lifecycle manual}) " & declaration &
        "(fn use_key [a : Key] : " & returnType & " " & operation & ")"
      var rejected = false
      try:
        discard compileSource(source).emitExperimentalC()
      except CatchableError as error:
        rejected = true
        check "cannot lower" in error.msg
      checkpoint name
      check rejected
