import gene/web
import std/[os, strutils, tempfiles, unittest]

proc checkWebExportRejection(facade, selection, expected: string) =
  let root = createTempDir("gene-web-exports-", "")
  defer: removeDir(root)
  writeFile(root / "provider.gene", "(mod provider ^profile web) " &
    "(type Thing ^props {^value Int}) (let count 3) " &
    "(fn make [] : Thing (Thing ^value count))")
  writeFile(root / "facade.gene", "(mod facade ^profile web) " & facade)
  writeFile(root / "entry.gene", "(mod entry ^profile web) " &
    "(import [" & selection & "] from \"./facade.gene\") (fn run [] : Int 0)")
  var diagnostic = ""
  try:
    discard buildWebModule(root / "entry.gene", root / "out")
  except WebProfileError as error:
    diagnostic = error.msg
  check expected in diagnostic

suite "web module export boundaries":
  test "ordinary imports do not implicitly re-export any declaration kind":
    for name in ["Thing", "count", "make"]:
      checkWebExportRejection(
        "(import [Thing count make] from \"./provider.gene\")", name,
        "no exported declaration: " & name)

  test "explicit false keeps an import private":
    checkWebExportRejection(
      "(import [Thing] from \"./provider.gene\" ^export false)", "Thing",
      "no exported declaration: Thing")

  test "export policy must be a literal boolean":
    checkWebExportRejection(
      "(import [Thing] from \"./provider.gene\" ^export \"yes\")", "Thing",
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
