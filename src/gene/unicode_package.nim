## Unicode 15.1 NFC and Default Case Folding for package format 1 paths.
## Keeping the generated tables in-tree pins identities independently of the
## host OS, libc, Nim, or ICU version.

import std/unicode
import ./unicode_package_data

const
  HangulSBase = 0xAC00'i32
  HangulLBase = 0x1100'i32
  HangulVBase = 0x1161'i32
  HangulTBase = 0x11A7'i32
  HangulLCount = 19'i32
  HangulVCount = 21'i32
  HangulTCount = 28'i32
  HangulNCount = HangulVCount * HangulTCount
  HangulSCount = HangulLCount * HangulNCount

proc mappingIndex(records: openArray[UnicodeMapping], codePoint: int32): int =
  var low: int = 0
  var high: int = records.high
  while low <= high:
    let middle = (low + high) shr 1
    if records[middle].codePoint < codePoint:
      low = middle + 1
    elif records[middle].codePoint > codePoint:
      high = middle - 1
    else:
      return middle
  -1

proc combiningClass(codePoint: int32): int32 =
  var low: int = 0
  var high: int = unicodeCombiningClasses.high
  while low <= high:
    let middle = (low + high) shr 1
    if unicodeCombiningClasses[middle].codePoint < codePoint:
      low = middle + 1
    elif unicodeCombiningClasses[middle].codePoint > codePoint:
      high = middle - 1
    else:
      return unicodeCombiningClasses[middle].combiningClass
  0

proc decompose(codePoint: int32, output: var seq[int32]) =
  let hangulIndex = codePoint - HangulSBase
  if hangulIndex >= 0 and hangulIndex < HangulSCount:
    let leading = HangulLBase + hangulIndex div HangulNCount
    let vowel = HangulVBase + (hangulIndex mod HangulNCount) div HangulTCount
    let trailing = HangulTBase + hangulIndex mod HangulTCount
    output.add leading
    output.add vowel
    if trailing != HangulTBase:
      output.add trailing
    return
  let index = mappingIndex(unicodeCanonicalMappings, codePoint)
  if index < 0:
    output.add codePoint
    return
  let mapping = unicodeCanonicalMappings[index]
  for i in 0 ..< int(mapping.length):
    decompose(unicodeCanonicalData[int(mapping.offset) + i], output)

proc composePair(first, second: int32): int32 =
  if first >= HangulLBase and first < HangulLBase + HangulLCount and
      second >= HangulVBase and second < HangulVBase + HangulVCount:
    return HangulSBase +
      ((first - HangulLBase) * HangulVCount + second - HangulVBase) *
      HangulTCount
  let syllable = first - HangulSBase
  if syllable >= 0 and syllable < HangulSCount and
      syllable mod HangulTCount == 0 and
      second > HangulTBase and second < HangulTBase + HangulTCount:
    return first + second - HangulTBase
  var low: int = 0
  var high: int = unicodeCompositions.high
  while low <= high:
    let middle = (low + high) shr 1
    let item = unicodeCompositions[middle]
    if item.first < first or (item.first == first and item.second < second):
      low = middle + 1
    elif item.first > first or (item.first == first and item.second > second):
      high = middle - 1
    else:
      return item.composed
  -1

proc unicodeNfc151*(text: string): string =
  var decomposed: seq[int32]
  for rune in text.runes:
    decompose(int32(rune), decomposed)
  # Canonical ordering is a stable insertion within each starter segment.
  for i in 1 ..< decomposed.len:
    let currentClass = combiningClass(decomposed[i])
    if currentClass == 0:
      continue
    var j = i
    while j > 0:
      let previousClass = combiningClass(decomposed[j - 1])
      if previousClass == 0 or previousClass <= currentClass:
        break
      swap(decomposed[j], decomposed[j - 1])
      dec j
  var composed: seq[int32]
  if decomposed.len > 0:
    composed.add decomposed[0]
    var starterPosition = 0
    var starter = decomposed[0]
    var previousClass = 0'i32
    for i in 1 ..< decomposed.len:
      let codePoint = decomposed[i]
      let currentClass = combiningClass(codePoint)
      let replacement = composePair(starter, codePoint)
      if replacement >= 0 and
          (previousClass == 0 or previousClass < currentClass):
        composed[starterPosition] = replacement
        starter = replacement
      else:
        if currentClass == 0:
          starterPosition = composed.len
          starter = codePoint
        composed.add codePoint
        previousClass = currentClass
  for codePoint in composed:
    result.add Rune(codePoint).toUTF8()

proc unicodeDefaultCaseFold151*(text: string): string =
  for rune in text.runes:
    let codePoint = int32(rune)
    let index = mappingIndex(unicodeFoldMappings, codePoint)
    if index < 0:
      result.add rune.toUTF8()
    else:
      let mapping = unicodeFoldMappings[index]
      for i in 0 ..< int(mapping.length):
        result.add Rune(unicodeFoldData[int(mapping.offset) + i]).toUTF8()
