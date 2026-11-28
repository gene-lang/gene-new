## Dependency-free content digests shared by package and build infrastructure.
## Digesting is deliberately off the VM and reader hot paths.

const sha256RoundConstants: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotateRight(value: uint32, amount: int): uint32 {.inline.} =
  (value shr amount) or (value shl (32 - amount))

const hexDigits = "0123456789abcdef"

proc hexOfState(state: array[8, uint32]): string =
  result = newStringOfCap(64)
  for word in state:
    for shift in countdown(28, 0, 4):
      result.add hexDigits[int((word shr shift) and 0xf'u32)]

# Portable implementation. It is the only one on targets without a system
# digest, and it stays compiled everywhere so a test can compare it with the
# system one.

type PortableSha256 = object
  state: array[8, uint32]
  buffer: array[64, byte]
  bufferLen: int
  totalLen: uint64

proc initPortable(): PortableSha256 =
  result.state = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32,
                  0xa54ff53a'u32, 0x510e527f'u32, 0x9b05688c'u32,
                  0x1f83d9ab'u32, 0x5be0cd19'u32]

{.push boundChecks: off, overflowChecks: off.}

proc compressBlock(state: var array[8, uint32],
                   block64: ptr UncheckedArray[byte]) =
  ## One 64-byte block. The indexes are constants or loop counters below the
  ## array sizes, so the checks it would otherwise carry prove nothing.
  var schedule: array[64, uint32]
  for i in 0 ..< 16:
    let j = i * 4
    schedule[i] = (uint32(block64[j]) shl 24) or
                  (uint32(block64[j + 1]) shl 16) or
                  (uint32(block64[j + 2]) shl 8) or
                  uint32(block64[j + 3])
  for i in 16 ..< 64:
    let s0 = rotateRight(schedule[i - 15], 7) xor
             rotateRight(schedule[i - 15], 18) xor
             (schedule[i - 15] shr 3)
    let s1 = rotateRight(schedule[i - 2], 17) xor
             rotateRight(schedule[i - 2], 19) xor
             (schedule[i - 2] shr 10)
    schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1
  var a = state[0]
  var b = state[1]
  var c = state[2]
  var d = state[3]
  var e = state[4]
  var f = state[5]
  var g = state[6]
  var h = state[7]
  for i in 0 ..< 64:
    let big1 = rotateRight(e, 6) xor rotateRight(e, 11) xor
               rotateRight(e, 25)
    let choose = (e and f) xor ((not e) and g)
    let temp1 = h + big1 + choose + sha256RoundConstants[i] + schedule[i]
    let big0 = rotateRight(a, 2) xor rotateRight(a, 13) xor
               rotateRight(a, 22)
    let majority = (a and b) xor (a and c) xor (b and c)
    let temp2 = big0 + majority
    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2
  state[0] += a
  state[1] += b
  state[2] += c
  state[3] += d
  state[4] += e
  state[5] += f
  state[6] += g
  state[7] += h

proc updatePortable(context: var PortableSha256, data: ptr UncheckedArray[byte],
                    count: int) =
  ## Whole blocks are compressed straight from the input. Only the tail is
  ## copied into the context's buffer.
  var at = 0
  context.totalLen += uint64(count)
  if context.bufferLen > 0:
    let take = min(64 - context.bufferLen, count)
    copyMem(addr context.buffer[context.bufferLen], addr data[0], take)
    context.bufferLen += take
    at = take
    if context.bufferLen == 64:
      compressBlock(context.state, cast[ptr UncheckedArray[byte]](
        addr context.buffer[0]))
      context.bufferLen = 0
  while count - at >= 64:
    compressBlock(context.state, cast[ptr UncheckedArray[byte]](addr data[at]))
    at += 64
  if at < count:
    copyMem(addr context.buffer[0], addr data[at], count - at)
    context.bufferLen = count - at

{.pop.}

proc finishPortable(context: PortableSha256): string =
  var final = context
  let bitLen = final.totalLen * 8'u64
  var padding: array[72, byte]
  padding[0] = 0x80'u8
  let padLen = (if final.bufferLen < 56: 56 - final.bufferLen
                else: 120 - final.bufferLen)
  for shift in 0 ..< 8:
    padding[padLen + shift] = byte((bitLen shr (56 - 8 * shift)) and 0xff'u64)
  updatePortable(final, cast[ptr UncheckedArray[byte]](addr padding[0]),
                 padLen + 8)
  hexOfState(final.state)

# macOS has the SHA-2 instructions behind CommonCrypto, which hashes several
# times faster than portable code. Content-addressed storage hashes every
# segment, and the build cache hashes every artifact it loads.
const useSystemDigest = defined(macosx) and not defined(geneWasm)

when useSystemDigest:
  type CcSha256Ctx {.importc: "CC_SHA256_CTX",
                     header: "<CommonCrypto/CommonDigest.h>".} = object
  proc ccSha256Init(ctx: ptr CcSha256Ctx): cint
    {.importc: "CC_SHA256_Init", header: "<CommonCrypto/CommonDigest.h>".}
  proc ccSha256Update(ctx: ptr CcSha256Ctx, data: pointer, len: uint32): cint
    {.importc: "CC_SHA256_Update", header: "<CommonCrypto/CommonDigest.h>".}
  proc ccSha256Final(digest: ptr byte, ctx: ptr CcSha256Ctx): cint
    {.importc: "CC_SHA256_Final", header: "<CommonCrypto/CommonDigest.h>".}

  type Sha256Context* = object
    native: CcSha256Ctx

  proc initSha256*(): Sha256Context =
    discard ccSha256Init(addr result.native)

  proc updateRaw(context: var Sha256Context, data: pointer, count: int) =
    # CC_SHA256_Update takes a 32-bit length.
    var offset = 0
    while offset < count:
      let chunk = min(count - offset, 1 shl 30)
      discard ccSha256Update(addr context.native,
                             cast[pointer](cast[uint](data) + uint(offset)),
                             uint32(chunk))
      offset += chunk

  proc finishHex*(context: Sha256Context): string =
    var final = context
    var digest: array[32, byte]
    discard ccSha256Final(addr digest[0], addr final.native)
    result = newStringOfCap(64)
    for value in digest:
      result.add hexDigits[int(value shr 4)]
      result.add hexDigits[int(value and 0xf)]
else:
  type Sha256Context* = object
    portable: PortableSha256

  proc initSha256*(): Sha256Context =
    result.portable = initPortable()

  proc updateRaw(context: var Sha256Context, data: pointer, count: int) =
    updatePortable(context.portable, cast[ptr UncheckedArray[byte]](data),
                   count)

  proc finishHex*(context: Sha256Context): string =
    finishPortable(context.portable)

proc update*(context: var Sha256Context, data: string) =
  if data.len > 0:
    context.updateRaw(unsafeAddr data[0], data.len)

proc update*(context: var Sha256Context, data: openArray[byte]) =
  if data.len > 0:
    context.updateRaw(unsafeAddr data[0], data.len)

proc sha256Hex*(data: string): string =
  var context = initSha256()
  context.update(data)
  context.finishHex()

proc sha256HexPortable*(data: string): string =
  ## The portable implementation, for tests that compare it with the system one.
  var context = initPortable()
  if data.len > 0:
    updatePortable(context, cast[ptr UncheckedArray[byte]](unsafeAddr data[0]),
                   data.len)
  finishPortable(context)

proc sha256File*(path: string): string =
  ## Stream a file into SHA-256. Compiler and tool identities use this instead
  ## of a version label so a rebuilt executable can never reuse derivations
  ## produced by different compiler bytes.
  var file: File
  if not open(file, path, fmRead):
    raise newException(IOError, "cannot open file for hashing: " & path)
  var context = initSha256()
  var buffer: array[64 * 1024, byte]
  try:
    while true:
      let count = file.readBuffer(addr buffer[0], buffer.len)
      if count <= 0:
        break
      context.update(buffer.toOpenArray(0, count - 1))
  finally:
    close(file)
  context.finishHex()
