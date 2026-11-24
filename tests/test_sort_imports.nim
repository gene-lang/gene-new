import std/[strutils, unittest]
import gene/[reader, types]
import tools/fmt

proc importForm(source: string): Value =
  readAll(source)[0]

suite "import selector sorting":
  test "capitalised selectors sort before lower-case selectors":
    let value = importForm("(import b A a B ^from \"x\")")
    check formatImportForm(value) == "(import A B a b ^from \"x\")"

  test "aliases, qualified selects, and groups sort recursively":
    let value = importForm(
      "(import z:last m/[d:C b a] a/b:beta A:C ^from \"x\")")
    check formatImportForm(value) ==
      "(import A:C a/b:beta m/[a b d:C] z:last ^from \"x\")"

  test "namespace member imports sort inside the group":
    let value = importForm("(import $fs [watch real_path WatcherClosed])")
    check formatImportForm(value) ==
      "(import $fs/[WatcherClosed real_path watch])"

  test "sorting is idempotent and keeps the source property last":
    let value = importForm("(import b A a B ^from \"x\")")
    let once = formatImportForm(value)
    check formatImportForm(importForm(once)) == once
    check once.endsWith("^from \"x\")")
