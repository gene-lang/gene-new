# Package

version       = "0.1.0"
author        = "G. Cao"
description    = "Gene — a homoiconic general purpose language"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["gene"]

# Dependencies

requires "nim >= 2.0.0"

task test, "Run the test suite":
  exec "nim c -r --path:src --hints:off tests/test_all.nim"
