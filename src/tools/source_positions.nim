## Shared UTF-8 source position helpers for reader-backed tooling.
##
## Source offsets and reader columns are bytes. LSP columns are UTF-16 code
## units. Keeping the conversions here lets the LSP, structural viewer, and
## future diagnostics share one coordinate implementation.

import std/unicode

type
  ByteSpan* = object
    startByte*, endByte*: int  ## Half-open UTF-8 byte range.

  LspPos* = object
    line*: int                 ## 0-based.
    character*: int            ## 0-based UTF-16 code units.

proc lineStarts*(src: string): seq[int] =
  result = @[0]
  for i in 0 ..< src.len:
    if src[i] == '\n':
      result.add i + 1

proc lineSlice*(src: string, starts: seq[int], line0: int): string =
  if line0 < 0 or line0 >= starts.len:
    return ""
  let first = starts[line0]
  var last = if line0 + 1 < starts.len: starts[line0 + 1] - 1 else: src.len
  if last > first and last - 1 < src.len and src[last - 1] == '\r':
    dec last
  if last < first:
    last = first
  src[first ..< last]

proc byteColToUtf16*(lineText: string, byteCol0: int): int =
  var bytePos = 0
  for rune in lineText.runes:
    if bytePos >= byteCol0:
      break
    bytePos += rune.toUTF8.len
    result += (if rune.int32 > 0xFFFF'i32: 2 else: 1)

proc utf16ColToByte*(lineText: string, utf16Col: int): int =
  var units = 0
  for rune in lineText.runes:
    if units >= utf16Col:
      break
    result += rune.toUTF8.len
    units += (if rune.int32 > 0xFFFF'i32: 2 else: 1)

proc byteOffset*(starts: seq[int], line1, col1: int): int =
  let line0 = max(line1 - 1, 0)
  if line0 >= starts.len:
    return (if starts.len > 0: starts[^1] else: 0)
  starts[line0] + max(col1 - 1, 0)

proc offsetLineCol*(src: string, starts: seq[int], offset: int):
    tuple[line, col: int] =
  let bounded = min(max(offset, 0), src.len)
  var line0 = 0
  for i in countdown(starts.high, 0):
    if starts[i] <= bounded:
      line0 = i
      break
  (line: line0 + 1, col: bounded - starts[line0] + 1)

proc toLspPos*(src: string, starts: seq[int], line1, col1: int): LspPos =
  let line0 = max(line1 - 1, 0)
  LspPos(line: line0,
         character: byteColToUtf16(lineSlice(src, starts, line0),
                                   max(col1 - 1, 0)))

proc offsetToLspPos*(src: string, starts: seq[int], offset: int): LspPos =
  let pos = offsetLineCol(src, starts, offset)
  toLspPos(src, starts, pos.line, pos.col)

proc lspPosToOffset*(src: string, starts: seq[int], pos: LspPos): int =
  if pos.line < 0 or pos.line >= starts.len:
    return src.len
  starts[pos.line] + utf16ColToByte(lineSlice(src, starts, pos.line),
                                    pos.character)
