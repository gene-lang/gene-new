## Compare the standalone C backend's exact temporaries against Gene's integer
## implementation, including results beyond the native parameter/result width.
import gene/types
import std/[os, osproc, strutils, tempfiles, unittest]

suite "checked native integer arithmetic":
  let directory = createTempDir("gene_native_integer_", "")
  let executable = directory / ("integer" & ExeExt)
  let cc = getEnv("CC", "cc")
  var flags = " -std=c11 -O2 -Wall -Wextra -Werror"
  if getEnv("GENE_NATIVE_INTEGER_SANITIZERS") == "1":
    flags.add " -fsanitize=address,undefined -fno-sanitize-recover=all"
  let compiled = execCmdEx(quoteShell(cc) & flags &
    " -I src tests/fixtures/native_integer.c -o " & quoteShell(executable))
  doAssert compiled.exitCode == 0, compiled.output

  test "promotion, cancellation, aliasing and ownership":
    let ran = execCmdEx(quoteShell(executable))
    checkpoint ran.output
    check ran.exitCode == 0
    check ran.output.strip() == "ownership and promotion: ok"

  test "boundary pairs match the VM integer operations":
    for a in [low(int64), low(int64) + 1, -1_000_000_000'i64, -1, 0, 1,
              1_000_000_000, high(int64) - 1, high(int64)]:
      for b in [low(int64), low(int64) + 1, -1_000_000_000'i64, -1, 0, 1,
                1_000_000_000, high(int64) - 1, high(int64)]:
        let x = newInt(a)
        let y = newInt(b)
        let sum = intAdd(x, y)
        let difference = intSub(x, y)
        let product = intMul(sum, difference)
        let expected = sum.intToString & "\n" & difference.intToString &
          "\n" & product.intToString & "\n" &
          intSub(intAdd(sum, product), difference).intToString
        let ran = execCmdEx(quoteShell(executable) & " " & $a & " " & $b)
        checkpoint $a & ", " & $b & ": " & ran.output
        check ran.exitCode == 0
        check ran.output.strip() == expected

  removeFile(executable)
  removeDir(directory)
