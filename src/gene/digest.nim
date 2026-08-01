## Dependency-free content digests shared by package and build infrastructure.
## Digesting is deliberately off the VM and reader hot paths.

import std/strutils

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

type Sha256Context* = object
  state: array[8, uint32]
  buffer: array[64, byte]
  bufferLen: int
  totalLen: uint64

proc initSha256*(): Sha256Context =
  result.state = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32,
                  0xa54ff53a'u32, 0x510e527f'u32, 0x9b05688c'u32,
                  0x1f83d9ab'u32, 0x5be0cd19'u32]

proc compress(context: var Sha256Context) =
  var schedule: array[64, uint32]
  for i in 0 ..< 16:
    let j = i * 4
    schedule[i] = (uint32(context.buffer[j]) shl 24) or
                  (uint32(context.buffer[j + 1]) shl 16) or
                  (uint32(context.buffer[j + 2]) shl 8) or
                  uint32(context.buffer[j + 3])
  for i in 16 ..< 64:
    let s0 = rotateRight(schedule[i - 15], 7) xor
             rotateRight(schedule[i - 15], 18) xor
             (schedule[i - 15] shr 3)
    let s1 = rotateRight(schedule[i - 2], 17) xor
             rotateRight(schedule[i - 2], 19) xor
             (schedule[i - 2] shr 10)
    schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1
  var a = context.state[0]
  var b = context.state[1]
  var c = context.state[2]
  var d = context.state[3]
  var e = context.state[4]
  var f = context.state[5]
  var g = context.state[6]
  var h = context.state[7]
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
  context.state[0] += a
  context.state[1] += b
  context.state[2] += c
  context.state[3] += d
  context.state[4] += e
  context.state[5] += f
  context.state[6] += g
  context.state[7] += h
  context.bufferLen = 0

proc updateByte(context: var Sha256Context, value: byte) {.inline.} =
  context.buffer[context.bufferLen] = value
  inc context.bufferLen
  inc context.totalLen
  if context.bufferLen == context.buffer.len:
    context.compress()

proc update*(context: var Sha256Context, data: string) =
  for ch in data:
    context.updateByte(byte(ord(ch)))

proc update*(context: var Sha256Context, data: openArray[byte]) =
  for value in data:
    context.updateByte(value)

proc finishHex*(context: Sha256Context): string =
  var final = context
  let bitLen = final.totalLen * 8'u64
  final.updateByte(0x80'u8)
  while final.bufferLen != 56:
    final.updateByte(0'u8)
  for shift in countdown(56, 0, 8):
    final.updateByte(byte((bitLen shr shift) and 0xff'u64))
  for word in final.state:
    result.add toHex(word, 8).toLowerAscii()

proc sha256Hex*(data: string): string =
  var context = initSha256()
  context.update(data)
  context.finishHex()

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
