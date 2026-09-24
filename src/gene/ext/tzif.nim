## Bounded TZif v2+ reader for the optional genex/tzdb data package.
## Operates only on caller-supplied bytes; never reads the host TZ database.

type
  GeneTzifType = object
    offsetSeconds: int
    daylight: bool
    designation: string
  GeneTzifRule = object
    month, week, weekday, atSeconds: int
  GeneTzifFooter = object
    present, daylight: bool
    standardOffset, daylightOffset: int
    startRule, endRule: GeneTzifRule
  GeneTzifZone = object
    transitions: seq[int64]
    indices: seq[int]
    kinds: seq[GeneTzifType]
    footer: GeneTzifFooter

proc tzifInvalid(message: string): ref GeneError =
  newException(GeneError, "invalid TZif data: " & message)

proc tzifByte(data: string, pos: int): int =
  if pos < 0 or pos >= data.len:
    raise tzifInvalid("truncated field")
  int(uint8(data[pos]))

proc tzifU32(data: string, pos: int): uint32 =
  if pos < 0 or pos > data.len - 4:
    raise tzifInvalid("truncated 32-bit field")
  for i in pos ..< pos + 4:
    result = (result shl 8) or uint32(uint8(data[i]))

proc tzifU64(data: string, pos: int): uint64 =
  if pos < 0 or pos > data.len - 8:
    raise tzifInvalid("truncated 64-bit field")
  for i in pos ..< pos + 8:
    result = (result shl 8) or uint64(uint8(data[i]))

type GeneTzifHeader = object
  version: char
  isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt: int

proc tzifHeader(data: string, pos: int): GeneTzifHeader =
  if pos < 0 or pos > data.len - 44 or data[pos ..< pos + 4] != "TZif":
    raise tzifInvalid("missing header")
  result.version = data[pos + 4]
  if result.version notin {'\0', '2', '3', '4'}:
    raise tzifInvalid("unsupported version")
  result.isutcnt = int(tzifU32(data, pos + 20))
  result.isstdcnt = int(tzifU32(data, pos + 24))
  result.leapcnt = int(tzifU32(data, pos + 28))
  result.timecnt = int(tzifU32(data, pos + 32))
  result.typecnt = int(tzifU32(data, pos + 36))
  result.charcnt = int(tzifU32(data, pos + 40))
  if result.timecnt > 100_000 or result.typecnt < 1 or
      result.typecnt > 256 or result.charcnt < 1 or
      result.charcnt > 16_384 or result.leapcnt > 2_000 or
      result.isstdcnt > result.typecnt or result.isutcnt > result.typecnt:
    raise tzifInvalid("count exceeds bound")
  if result.leapcnt != 0:
    raise tzifInvalid("leap-second files are unsupported")

proc tzifBlockEnd(data: string, pos: int, h: GeneTzifHeader,
                   wide: bool): int =
  let timeWidth = if wide: 8'i64 else: 4'i64
  let size = int64(h.timecnt) * (timeWidth + 1) +
    int64(h.typecnt) * 6 + int64(h.charcnt) +
    int64(h.leapcnt) * (timeWidth + 4) +
    int64(h.isstdcnt + h.isutcnt)
  if size < 0 or int64(pos) + 44 + size > int64(data.len):
    raise tzifInvalid("truncated data block")
  pos + 44 + int(size)

proc tzifPosixNumber(text: string, pos: var int, maximum: int): int =
  let start = pos
  while pos < text.len and text[pos] in {'0'..'9'}:
    if result > maximum div 10:
      raise tzifInvalid("POSIX rule number exceeds bound")
    result = result * 10 + ord(text[pos]) - ord('0')
    inc pos
  if pos == start or result > maximum:
    raise tzifInvalid("invalid POSIX rule number")

proc tzifPosixName(text: string, pos: var int) =
  if pos >= text.len: raise tzifInvalid("missing POSIX designation")
  if text[pos] == '<':
    inc pos
    let start = pos
    while pos < text.len and text[pos] != '>': inc pos
    if pos == start or pos >= text.len:
      raise tzifInvalid("invalid POSIX designation")
    inc pos
  else:
    let start = pos
    while pos < text.len and text[pos] in {'A'..'Z', 'a'..'z'}: inc pos
    if pos - start < 3:
      raise tzifInvalid("invalid POSIX designation")

proc tzifPosixClock(text: string, pos: var int, maxHour: int): int =
  var sign = 1
  if pos < text.len and text[pos] in {'+', '-'}:
    if text[pos] == '-': sign = -1
    inc pos
  let hour = tzifPosixNumber(text, pos, maxHour)
  var minute, second = 0
  if pos < text.len and text[pos] == ':':
    inc pos
    minute = tzifPosixNumber(text, pos, 59)
    if pos < text.len and text[pos] == ':':
      inc pos
      second = tzifPosixNumber(text, pos, 59)
  sign * (hour * 3600 + minute * 60 + second)

proc tzifPosixRule(text: string, pos: var int): GeneTzifRule =
  if pos >= text.len or text[pos] != 'M':
    raise tzifInvalid("unsupported POSIX transition rule")
  inc pos
  result.month = tzifPosixNumber(text, pos, 12)
  if result.month < 1 or pos >= text.len or text[pos] != '.':
    raise tzifInvalid("invalid POSIX transition month")
  inc pos
  result.week = tzifPosixNumber(text, pos, 5)
  if result.week < 1 or pos >= text.len or text[pos] != '.':
    raise tzifInvalid("invalid POSIX transition week")
  inc pos
  result.weekday = tzifPosixNumber(text, pos, 6)
  result.atSeconds = 7200
  if pos < text.len and text[pos] == '/':
    inc pos
    result.atSeconds = tzifPosixClock(text, pos, 167)

proc tzifParseFooter(text: string): GeneTzifFooter =
  if text.len == 0: return
  result.present = true
  var pos = 0
  tzifPosixName(text, pos)
  result.standardOffset = -tzifPosixClock(text, pos, 167)
  if pos == text.len: return
  tzifPosixName(text, pos)
  result.daylight = true
  result.daylightOffset = result.standardOffset + 3600
  if pos < text.len and text[pos] != ',':
    result.daylightOffset = -tzifPosixClock(text, pos, 167)
  if pos >= text.len or text[pos] != ',':
    raise tzifInvalid("POSIX daylight rules are missing")
  inc pos
  result.startRule = tzifPosixRule(text, pos)
  if pos >= text.len or text[pos] != ',':
    raise tzifInvalid("POSIX end rule is missing")
  inc pos
  result.endRule = tzifPosixRule(text, pos)
  if pos != text.len:
    raise tzifInvalid("trailing POSIX rule data")

proc parseGeneTzif*(data: string): GeneTzifZone =
  if data.len < 44 or data.len > 1_048_576:
    raise tzifInvalid("file size exceeds bound")
  let first = tzifHeader(data, 0)
  var header = first
  var dataStart = 44
  var wide = false
  if first.version != '\0':
    let secondPos = tzifBlockEnd(data, 0, first, false)
    header = tzifHeader(data, secondPos)
    if header.version != first.version:
      raise tzifInvalid("second header version differs")
    dataStart = secondPos + 44
    wide = true
  let endPos = tzifBlockEnd(data, dataStart - 44, header, wide)
  let timeWidth = if wide: 8 else: 4
  for i in 0 ..< header.timecnt:
    let pos = dataStart + i * timeWidth
    let whenSeconds = if wide:
      cast[int64](tzifU64(data, pos))
    else:
      int64(cast[int32](tzifU32(data, pos)))
    if result.transitions.len > 0 and whenSeconds <= result.transitions[^1]:
      raise tzifInvalid("transitions are not increasing")
    result.transitions.add whenSeconds
  let indexStart = dataStart + header.timecnt * timeWidth
  for i in 0 ..< header.timecnt:
    let index = tzifByte(data, indexStart + i)
    if index >= header.typecnt:
      raise tzifInvalid("transition type index exceeds count")
    result.indices.add index
  let typeStart = indexStart + header.timecnt
  let namesStart = typeStart + header.typecnt * 6
  let namesEnd = namesStart + header.charcnt
  for i in 0 ..< header.typecnt:
    let pos = typeStart + i * 6
    let offset = int(cast[int32](tzifU32(data, pos)))
    let daylight = tzifByte(data, pos + 4)
    let nameIndex = tzifByte(data, pos + 5)
    if offset == low(int32).int or daylight notin [0, 1] or
        nameIndex >= header.charcnt:
      raise tzifInvalid("invalid local time type")
    var nameEnd = namesStart + nameIndex
    while nameEnd < namesEnd and data[nameEnd] != '\0': inc nameEnd
    if nameEnd >= namesEnd:
      raise tzifInvalid("unterminated designation")
    result.kinds.add GeneTzifType(offsetSeconds: offset,
      daylight: daylight == 1,
      designation: data[namesStart + nameIndex ..< nameEnd])
  if wide:
    if endPos + 2 > data.len or data[endPos] != '\n' or
        data[^1] != '\n':
      raise tzifInvalid("missing footer")
    result.footer = tzifParseFooter(data[endPos + 1 ..< data.len - 1])
  elif endPos != data.len:
    raise tzifInvalid("trailing version 1 data")

proc tzifWeekday(days: int64): int =
  let value = (days + 4) mod 7
  int(if value < 0: value + 7 else: value)

proc tzifRuleEpoch(year: int, rule: GeneTzifRule,
                   priorOffset: int): int64 =
  let first = temporalDaysFromCivil(year, rule.month, 1)
  var day = 1 + (rule.weekday - tzifWeekday(first) + 7) mod 7 +
    (rule.week - 1) * 7
  let nextMonth = if rule.month == 12:
    temporalDaysFromCivil(year + 1, 1, 1)
  else:
    temporalDaysFromCivil(year, rule.month + 1, 1)
  let monthDays = int(nextMonth - first)
  if rule.week == 5 and day > monthDays: day -= 7
  (first + int64(day - 1)) * 86_400 + int64(rule.atSeconds) -
    int64(priorOffset)

proc tzifFooterOffset(footer: GeneTzifFooter, whenSeconds: int64): int =
  if not footer.daylight: return footer.standardOffset
  let standardLocal = whenSeconds + int64(footer.standardOffset)
  let year = temporalCivilFromDays(
    temporalFloorDiv(standardLocal, 86_400)).year
  var latest = low(int64)
  result = footer.standardOffset
  for y in year - 2 .. year + 2:
    let start = tzifRuleEpoch(y, footer.startRule, footer.standardOffset)
    let finish = tzifRuleEpoch(y, footer.endRule, footer.daylightOffset)
    if start <= whenSeconds and start > latest:
      latest = start
      result = footer.daylightOffset
    if finish <= whenSeconds and finish > latest:
      latest = finish
      result = footer.standardOffset

proc geneTzifOffsetSeconds*(zone: GeneTzifZone,
                            whenSeconds: int64): int =
  if zone.kinds.len == 0: raise tzifInvalid("no local time type")
  if zone.transitions.len == 0:
    if zone.footer.present:
      return tzifFooterOffset(zone.footer, whenSeconds)
    return zone.kinds[0].offsetSeconds
  if whenSeconds < zone.transitions[0]:
    return zone.kinds[0].offsetSeconds
  if whenSeconds >= zone.transitions[^1]:
    if zone.footer.present:
      return tzifFooterOffset(zone.footer, whenSeconds)
    raise newException(GeneError,
      "TZif local time is unspecified after the last transition")
  var lo = 0
  var hi = zone.transitions.len
  while lo < hi:
    let mid = lo + (hi - lo) div 2
    if zone.transitions[mid] <= whenSeconds: lo = mid + 1
    else: hi = mid
  let index = zone.indices[lo - 1]
  if zone.kinds[index].designation == "-00":
    raise newException(GeneError, "TZif local time is unspecified")
  zone.kinds[index].offsetSeconds

proc tzifLocalDateTime(instant: int64, offsetSeconds: int,
                       zoneName: string): Value =
  if offsetSeconds mod 60 == 0 and
      offsetSeconds >= -23 * 3600 - 59 * 60 and
      offsetSeconds <= 23 * 3600 + 59 * 60:
    return temporalDateTimeFromInstant(instant, offsetSeconds div 60,
      zoneName)
  # DateTime offsets are minute-precision. Keep the exact local fields and
  # return the historical second offset separately in the result record.
  let wall = temporalDateTimeFromInstant(temporalCheckedAdd(instant,
    int64(offsetSeconds) * temporalMicrosPerSecond), 0)
  newDateTime(wall.dateTimeYear, wall.dateTimeMonth, wall.dateTimeDay,
    wall.dateTimeHour, wall.dateTimeMinute, wall.dateTimeSecond,
    wall.dateTimeMicrosecond, false, 0, zoneName)

proc tzifResult(instant: int64, offsetSeconds: int,
                zoneName, releaseId: string): Value =
  var fields = initPropTable()
  fields["datetime"] = tzifLocalDateTime(instant, offsetSeconds, zoneName)
  fields["instant"] = temporalDateTimeFromInstant(instant, 0, "UTC")
  fields["offset_seconds"] = newInt(offsetSeconds)
  fields["zone"] = newStr(zoneName)
  fields["tzdb_release"] = newStr(releaseId)
  newMap(fields)

proc tzifArguments(args: openArray[Value], label: string) =
  if args.len < 4 or args[0].kind != vkBytes or
      args[2].kind != vkString or args[3].kind != vkString or
      args[2].strVal.len == 0 or args[3].strVal.len == 0:
    raise newException(GeneError,
      label & " expects TZif Bytes, DateTime, zone Str, release Str")

proc biTemporalTzifToLocal(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 4:
    raise newException(GeneError, "temporal/_tzif_to_local expects 4 arguments")
  tzifArguments(args, "temporal/_tzif_to_local")
  let instant = temporalInstantMicros(args[1])
  let zone = parseGeneTzif(args[0].bytesVal)
  let offset = geneTzifOffsetSeconds(zone,
    temporalFloorDiv(instant, temporalMicrosPerSecond))
  tzifResult(instant, offset, args[2].strVal, args[3].strVal)

proc biTemporalTzifResolveLocal(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 5:
    raise newException(GeneError,
      "temporal/_tzif_resolve_local expects 5 arguments")
  tzifArguments(args, "temporal/_tzif_resolve_local")
  let local = args[1]
  requireDateTime("temporal/_tzif_resolve_local", local)
  if local.dateTimeHasOffset:
    raise newException(GeneError,
      "resolve_local expects a DateTime without a UTC offset")
  requireStr("temporal/_tzif_resolve_local fold", args[4])
  let fold = args[4].strVal
  if fold notin ["reject", "earlier", "later"]:
    raise newException(GeneError,
      "resolve_local fold must be reject, earlier, or later")
  let wall = temporalDaysFromCivil(local.dateTimeYear,
    local.dateTimeMonth, local.dateTimeDay) * temporalMicrosPerDay +
    int64(local.dateTimeHour) * 3600 * temporalMicrosPerSecond +
    int64(local.dateTimeMinute) * 60 * temporalMicrosPerSecond +
    int64(local.dateTimeSecond) * temporalMicrosPerSecond +
    int64(local.dateTimeMicrosecond)
  let zone = parseGeneTzif(args[0].bytesVal)
  var offsets = initHashSet[int]()
  for kind in zone.kinds: offsets.incl kind.offsetSeconds
  if zone.footer.present:
    offsets.incl zone.footer.standardOffset
    if zone.footer.daylight: offsets.incl zone.footer.daylightOffset
  var candidates: seq[tuple[instant: int64, offset: int]]
  for offset in offsets:
    let candidate = temporalCheckedAdd(wall,
      -int64(offset) * temporalMicrosPerSecond)
    let actual = geneTzifOffsetSeconds(zone,
      temporalFloorDiv(candidate, temporalMicrosPerSecond))
    if actual == offset:
      candidates.add (candidate, offset)
  if candidates.len == 0:
    raise newException(GeneError, "nonexistent local time in zone")
  candidates.sort(proc (a, b: tuple[instant: int64, offset: int]): int =
    cmp(a.instant, b.instant))
  if candidates.len > 1 and fold == "reject":
    raise newException(GeneError, "ambiguous local time in zone")
  let chosen = if fold == "later": candidates[^1] else: candidates[0]
  tzifResult(chosen.instant, chosen.offset,
    args[2].strVal, args[3].strVal)
