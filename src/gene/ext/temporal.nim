## Fixed-precision calendar and instant operations for gene/temporal.
## No host timezone database or process-local TZ setting is consulted.

const temporalMicrosPerSecond = 1_000_000'i64
const temporalMicrosPerDay = 86_400'i64 * temporalMicrosPerSecond

proc temporalDaysFromCivil(year, month, day: int): int64 =
  ## Proleptic Gregorian days relative to 1970-01-01.
  let y = int64(year) - (if month <= 2: 1'i64 else: 0'i64)
  let era = y div 400
  let yoe = y - era * 400
  let mp = int64(month) + (if month > 2: -3'i64 else: 9'i64)
  let doy = (153 * mp + 2) div 5 + int64(day) - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc temporalCivilFromDays(days: int64): tuple[year, month, day: int] =
  let z = days + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var year = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let day = doy - (153 * mp + 2) div 5 + 1
  let month = mp + (if mp < 10: 3'i64 else: -9'i64)
  if month <= 2: inc year
  (int(year), int(month), int(day))

proc temporalCheckedAdd(a, b: int64): int64 =
  if (b > 0 and a > high(int64) - b) or
      (b < 0 and a < low(int64) - b):
    raise newException(GeneError, "temporal arithmetic overflows Int64")
  a + b

proc temporalFloorDiv(a, b: int64): int64 =
  result = a div b
  if a mod b < 0: dec result

proc temporalInstantMicros(value: Value): int64 =
  requireDateTime("temporal instant", value)
  if not value.dateTimeHasOffset:
    raise newException(GeneError,
      "temporal instant requires an explicit UTC offset")
  let day = temporalDaysFromCivil(value.dateTimeYear,
    value.dateTimeMonth, value.dateTimeDay)
  let wallMicros = day * temporalMicrosPerDay +
    int64(value.dateTimeHour) * 3600 * temporalMicrosPerSecond +
    int64(value.dateTimeMinute) * 60 * temporalMicrosPerSecond +
    int64(value.dateTimeSecond) * temporalMicrosPerSecond +
    int64(value.dateTimeMicrosecond)
  wallMicros - int64(value.dateTimeOffsetMinutes) * 60 *
    temporalMicrosPerSecond

proc temporalDateTimeFromInstant(instant: int64, offsetMinutes: int,
                                 name = ""): Value =
  let localMicros = temporalCheckedAdd(instant,
    int64(offsetMinutes) * 60 * temporalMicrosPerSecond)
  let days = temporalFloorDiv(localMicros, temporalMicrosPerDay)
  let date = temporalCivilFromDays(days)
  if date.year < 1 or date.year > 9999:
    raise newException(GeneError, "temporal result is outside DateTime range")
  let withinDay = localMicros - days * temporalMicrosPerDay
  let hour = int(withinDay div (3600 * temporalMicrosPerSecond))
  let minute = int((withinDay div (60 * temporalMicrosPerSecond)) mod 60)
  let second = int((withinDay div temporalMicrosPerSecond) mod 60)
  let microsecond = int(withinDay mod temporalMicrosPerSecond)
  newDateTime(date.year, date.month, date.day, hour, minute, second,
    microsecond, true, offsetMinutes, name)

proc temporalDigits(text: string, start, count: int): int =
  if start < 0 or count < 1 or start + count > text.len:
    raise newException(GeneError, "invalid RFC3339 timestamp")
  for index in start ..< start + count:
    if text[index] notin {'0'..'9'}:
      raise newException(GeneError, "invalid RFC3339 timestamp")
    result = result * 10 + ord(text[index]) - ord('0')

proc temporalPad(value, width: int): string =
  result = $value
  while result.len < width: result = "0" & result

proc biTemporalAddDays(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "temporal/add_days expects Date and Int")
  requireDate("temporal/add_days", args[0])
  let change = requireInt64("temporal/add_days", args[1])
  let current = temporalDaysFromCivil(args[0].dateYear,
    args[0].dateMonth, args[0].dateDay)
  if change < temporalDaysFromCivil(1, 1, 1) - current or
      change > temporalDaysFromCivil(9999, 12, 31) - current:
    raise newException(GeneError, "temporal/add_days is outside Date range")
  let date = temporalCivilFromDays(current + change)
  newDate(date.year, date.month, date.day)

proc biTemporalAdd(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "temporal/add expects DateTime and Duration")
  requireDateTime("temporal/add", args[0])
  requireDuration("temporal/add", args[1])
  let instant = temporalCheckedAdd(temporalInstantMicros(args[0]),
    args[1].durationMicroseconds)
  let offset = args[0].dateTimeOffsetMinutes
  # An elapsed-duration operation cannot claim the old named-zone rule still
  # applies after a transition. Retain only the fixed offset (or UTC).
  temporalDateTimeFromInstant(instant, offset,
    if offset == 0 and args[0].dateTimeTimezoneName == "UTC": "UTC" else: "")

proc biTemporalDifference(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "temporal/difference expects two offset DateTimes")
  let left = temporalInstantMicros(args[0])
  let right = temporalInstantMicros(args[1])
  newDuration(temporalCheckedAdd(left, -right))

proc biTemporalToUtc(args: openArray[Value]): Value {.nimcall.} =
  requireOne("temporal/to_utc", args)
  temporalDateTimeFromInstant(temporalInstantMicros(args[0]), 0, "UTC")

proc biTemporalParseRfc3339(args: openArray[Value]): Value {.nimcall.} =
  requireOne("temporal/parse_rfc3339", args)
  requireStr("temporal/parse_rfc3339", args[0])
  let source = args[0].strVal
  if source.len < 20 or source[4] != '-' or source[7] != '-' or
      source[10] notin {'T', 't'} or source[13] != ':' or source[16] != ':':
    raise newException(GeneError, "invalid RFC3339 timestamp")
  let year = temporalDigits(source, 0, 4)
  let month = temporalDigits(source, 5, 2)
  let day = temporalDigits(source, 8, 2)
  let hour = temporalDigits(source, 11, 2)
  let minute = temporalDigits(source, 14, 2)
  let second = temporalDigits(source, 17, 2)
  if second == 60:
    raise newException(GeneError, "RFC3339 leap seconds are unsupported")
  var pos = 19
  var microsecond = 0
  if pos < source.len and source[pos] == '.':
    inc pos
    let start = pos
    while pos < source.len and source[pos] in {'0'..'9'}: inc pos
    let digits = pos - start
    if digits < 1 or digits > 6:
      raise newException(GeneError,
        "RFC3339 fractional seconds require 1..6 digits")
    microsecond = temporalDigits(source, start, digits)
    for _ in digits ..< 6: microsecond *= 10
  var offset = 0
  if pos + 1 == source.len and source[pos] in {'Z', 'z'}:
    discard
  elif pos + 6 == source.len and source[pos] in {'+', '-'} and
      source[pos + 3] == ':':
    let hours = temporalDigits(source, pos + 1, 2)
    let minutes = temporalDigits(source, pos + 4, 2)
    if hours > 23 or minutes > 59 or
        (source[pos] == '-' and hours == 0 and minutes == 0):
      raise newException(GeneError, "invalid RFC3339 UTC offset")
    offset = (hours * 60 + minutes) * (if source[pos] == '-': -1 else: 1)
  else:
    raise newException(GeneError, "RFC3339 timestamp requires UTC offset")
  newDateTime(year, month, day, hour, minute, second, microsecond,
    true, offset, if offset == 0 and source[pos] in {'Z', 'z'}: "UTC" else: "")

proc biTemporalFormatRfc3339(args: openArray[Value]): Value {.nimcall.} =
  requireOne("temporal/format_rfc3339", args)
  let value = args[0]
  discard temporalInstantMicros(value)
  var output = temporalPad(value.dateTimeYear, 4) & "-" &
    temporalPad(value.dateTimeMonth, 2) & "-" &
    temporalPad(value.dateTimeDay, 2) & "T" &
    temporalPad(value.dateTimeHour, 2) & ":" &
    temporalPad(value.dateTimeMinute, 2) & ":" &
    temporalPad(value.dateTimeSecond, 2)
  if value.dateTimeMicrosecond != 0:
    var fraction = temporalPad(value.dateTimeMicrosecond, 6)
    while fraction.len > 0 and fraction[^1] == '0':
      fraction.setLen(fraction.len - 1)
    output.add "." & fraction
  let offset = value.dateTimeOffsetMinutes
  if offset == 0:
    output.add "Z"
  else:
    let magnitude = abs(offset)
    output.add (if offset < 0: "-" else: "+") &
      temporalPad(magnitude div 60, 2) & ":" &
      temporalPad(magnitude mod 60, 2)
  newStr(output)
