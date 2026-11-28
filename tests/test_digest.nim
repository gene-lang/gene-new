import std/[strutils, unittest]
import ../src/gene/digest

# FIPS 180-4 and NIST CAVP vectors.
const vectors = [
  ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
  ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
  ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
   "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
  ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" &
   "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
   "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")]

proc pattern(length: int): string =
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char((i * 31 + 7) mod 251)

suite "SHA-256":
  test "published vectors":
    for (input, expected) in vectors:
      check sha256Hex(input) == expected
      check sha256HexPortable(input) == expected

  test "one million 'a'":
    let input = repeat('a', 1_000_000)
    let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    check sha256Hex(input) == expected
    check sha256HexPortable(input) == expected

  test "the system digest agrees with the portable one at every padding boundary":
    for length in 0 .. 300:
      let input = pattern(length)
      check sha256Hex(input) == sha256HexPortable(input)
    for length in [4095, 4096, 4097, 65535, 65536, 65537, 214_000]:
      let input = pattern(length)
      check sha256Hex(input) == sha256HexPortable(input)

  test "incremental updates match one-shot hashing for any chunking":
    let input = pattern(1000)
    let expected = sha256HexPortable(input)
    for chunk in [1, 3, 31, 55, 56, 63, 64, 65, 127, 128, 333]:
      var context = initSha256()
      var at = 0
      while at < input.len:
        let take = min(chunk, input.len - at)
        context.update(input[at ..< at + take])
        at += take
      check context.finishHex() == expected

  test "finishing does not consume the context":
    var context = initSha256()
    context.update("abc")
    let first = context.finishHex()
    context.update("def")
    check first == sha256Hex("abc")
    check context.finishHex() == sha256Hex("abcdef")

  test "bytes and strings hash alike":
    let text = pattern(777)
    var bytes = newSeq[byte](text.len)
    for i, ch in text: bytes[i] = byte(ord(ch))
    var context = initSha256()
    context.update(bytes)
    check context.finishHex() == sha256Hex(text)
