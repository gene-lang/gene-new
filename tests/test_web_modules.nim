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
