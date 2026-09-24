## IANA tzdata2026d, compiled by zic -b slim. The upstream source tarball is
## sha256:0cb2aa8e333c3dc049badc42a0c61f21987b8cd44e107fa900bad764aacc7767.
import gene/[types, vm]
import std/[os, strutils, unittest]

suite "TZif reader — pinned IANA data":
  test "all packaged zones parse at current and future instants":
    var count = 0
    for path in walkDirRec("src/genex/tzdb/zoneinfo"):
      let zone = parseGeneTzif(readFile(path))
      discard geneTzifOffsetSeconds(zone, 1719835200'i64)
      discard geneTzifOffsetSeconds(zone, 4118126400'i64)
      inc count
    check count == 597

  test "all zones match a pinned independent offset oracle":
    var count = 0
    for line in readFile("tests/fixtures/tzif/offset_oracle.tsv").splitLines():
      if line.len == 0 or line[0] == '#': continue
      let columns = line.split('\t')
      check columns.len == 3
      if columns.len != 3: break
      let zone = parseGeneTzif(readFile("src/genex/tzdb/zoneinfo" /
        columns[0]))
      let instant = parseBiggestInt(columns[1])
      let expected = parseInt(columns[2])
      let actual = geneTzifOffsetSeconds(zone, instant)
      if actual != expected:
        checkpoint(columns[0] & " at " & columns[1])
        check actual == expected
        break
      inc count
    check count == 3582

  test "historical seconds and current/future daylight rules are exact":
    let ny = parseGeneTzif(readFile("tests/fixtures/tzif/New_York"))
    check geneTzifOffsetSeconds(ny, -2840097600'i64) == -17762
    check geneTzifOffsetSeconds(ny, 1710072000'i64) == -14400
    check geneTzifOffsetSeconds(ny, 1719835200'i64) == -14400
    check geneTzifOffsetSeconds(ny, 4118126400'i64) == -14400
    check geneTzifOffsetSeconds(ny, 13585233600'i64) == -14400

    let london = parseGeneTzif(readFile("tests/fixtures/tzif/London"))
    check geneTzifOffsetSeconds(london, 1710072000'i64) == 0
    check geneTzifOffsetSeconds(london, 1719835200'i64) == 3600
    check geneTzifOffsetSeconds(london, 4118126400'i64) == 3600

    let kolkata = parseGeneTzif(readFile("tests/fixtures/tzif/Kolkata"))
    check geneTzifOffsetSeconds(kolkata, -2840097600'i64) == 19270
    check geneTzifOffsetSeconds(kolkata, 4118126400'i64) == 19800

  test "truncation, bad header, and changed transition indices fail":
    let original = readFile("tests/fixtures/tzif/New_York")
    expect GeneError:
      discard parseGeneTzif(original[0 ..< 30])
    var badMagic = original
    badMagic[0] = 'X'
    expect GeneError:
      discard parseGeneTzif(badMagic)
    var badCount = original
    for i in 32 .. 35: badCount[i] = '\xFF'
    expect GeneError:
      discard parseGeneTzif(badCount)
