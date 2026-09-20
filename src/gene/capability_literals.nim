## Inert capability grammar. This module imports neither the Gene reader/value
## runtime nor providers: reading cannot invoke constructors, macros or effects.
## Catalog/schema normalization is a separate required step. LiteralRow is
## syntax-checked data, never an admitted specification or runtime authority.

import std/[os, sets, strutils, unicode]

type
  CapabilityLiteralError* = object of CatchableError
    sourceName*: string
    line*, column*, offset*: int
  CapabilityUse* = enum
    cuGrant, cuRequest, cuBound
  CapabilitySourceKind* = enum
    csoSource, csoCommandLine, csoFile, csoEnvironment, csoBuilder
  CapabilitySourceContext* = object
    kind*: CapabilitySourceKind
    name*: string
    baseDirectory*: string
  CapabilityLocation* = object
    sourceName*: string
    line*, column*, offset*: int
  CapabilityLiteralLimits* = object
    maxBytes*, maxEntries*, maxBodyValues*, maxProperties*: int
    maxListItems*, maxStringBytes*, maxCommentDepth*: int
  CapabilityScalarKind* = enum
    cskInvalid, cskWildcard, cskText, cskInteger, cskBoolean
  CapabilityStringMode* = enum
    csmSource, csmLiteral, csmPattern
  CapabilityScalar* = object
    case kind*: CapabilityScalarKind
    of cskInvalid, cskWildcard:
      discard
    of cskText:
      text*: string
      stringMode*: CapabilityStringMode
    of cskInteger:
      integer*: int64
    of cskBoolean:
      boolean*: bool
  CapabilityPropertyValue* = object
    case isList*: bool
    of false:
      scalar*: CapabilityScalar
    of true:
      items*: seq[CapabilityScalar]
  CapabilityPropertyLiteral* = object
    name*: string
    value*: CapabilityPropertyValue
    location*: CapabilityLocation
  CapabilityEntryLiteral* = object
    name*: string
    body*: seq[CapabilityScalar]
    properties*: seq[CapabilityPropertyLiteral]
    hasOptional*, optional*: bool
    location*: CapabilityLocation
  CapabilityLiteralRow* = ref object
    entriesValue: seq[CapabilityEntryLiteral]
    sourceValue: CapabilitySourceContext
  LiteralReader = object
    text: string
    source: CapabilitySourceContext
    limits: CapabilityLiteralLimits
    use: CapabilityUse
    pos, line, column: int
    baseOffset: int

const DefaultCapabilityLiteralLimits* = CapabilityLiteralLimits(
  maxBytes: 65536, maxEntries: 256, maxBodyValues: 64, maxProperties: 32,
  maxListItems: 256, maxStringBytes: 8192, maxCommentDepth: 8)

proc capabilityText*(value: string): CapabilityScalar =
  CapabilityScalar(kind: cskText, text: value, stringMode: csmLiteral)
proc capabilityPattern*(value: string): CapabilityScalar =
  CapabilityScalar(kind: cskText, text: value, stringMode: csmPattern)
proc capabilityAny*(): CapabilityScalar =
  CapabilityScalar(kind: cskWildcard)
proc capabilityInteger*(value: int64): CapabilityScalar =
  CapabilityScalar(kind: cskInteger, integer: value)
proc capabilityBoolean*(value: bool): CapabilityScalar =
  CapabilityScalar(kind: cskBoolean, boolean: value)
proc capabilityValue*(value: CapabilityScalar): CapabilityPropertyValue =
  CapabilityPropertyValue(isList: false, scalar: value)
proc capabilityValues*(values: openArray[CapabilityScalar]):
    CapabilityPropertyValue =
  CapabilityPropertyValue(isList: true, items: @values)

proc location(r: LiteralReader): CapabilityLocation =
  CapabilityLocation(sourceName: r.source.name, line: r.line,
                     column: r.column, offset: r.pos + r.baseOffset)

proc invalid(location: CapabilityLocation, message: string) {.noReturn.} =
  let prefix = if location.sourceName.len > 0: location.sourceName & ":" else: ""
  var error = newException(CapabilityLiteralError,
    prefix & $location.line & ":" & $location.column & ": " & message)
  error.sourceName = location.sourceName
  error.line = location.line
  error.column = location.column
  error.offset = location.offset
  raise error

proc invalid(r: LiteralReader, message: string) {.noReturn.} =
  invalid(r.location, message)

proc validLimits(limits: CapabilityLiteralLimits) =
  for limit in [limits.maxBytes, limits.maxEntries, limits.maxBodyValues,
                limits.maxProperties, limits.maxListItems,
                limits.maxStringBytes, limits.maxCommentDepth]:
    if limit <= 0:
      invalid(CapabilityLocation(line: 1, column: 1),
              "capability reader limits must be positive")

proc checkedSource(source: CapabilitySourceContext): CapabilitySourceContext =
  result = source
  if source.baseDirectory.len > 0:
    if '\0' in source.baseDirectory or not source.baseDirectory.isAbsolute:
      invalid(CapabilityLocation(sourceName: source.name, line: 1, column: 1),
              "capability normalization base must be an absolute directory")
    # Lexical only: no realpath, existence test, or provider initialization.
    result.baseDirectory = normalizedPath(source.baseDirectory)

proc peek(r: LiteralReader, distance = 0): char =
  if r.pos + distance < r.text.len: r.text[r.pos + distance] else: '\0'

proc advance(r: var LiteralReader) =
  if r.pos < r.text.len:
    if r.text[r.pos] == '\n':
      inc r.line
      r.column = 1
    else:
      inc r.column
    inc r.pos

proc skipSpace(r: var LiteralReader) =
  while r.pos < r.text.len:
    if r.peek in {' ', '\t', '\r', '\n'}:
      r.advance()
    elif r.peek == '#' and r.peek(1) == '|':
      let start = r.location
      r.advance()
      r.advance()
      var depth = 1
      while depth > 0:
        if r.pos >= r.text.len:
          invalid(start, "unterminated capability comment")
        if r.peek == '#' and r.peek(1) == '|':
          inc depth
          if depth > r.limits.maxCommentDepth:
            r.invalid("capability comment nesting limit exceeded")
          r.advance()
          r.advance()
        elif r.peek == '|' and r.peek(1) == '#':
          dec depth
          r.advance()
          r.advance()
        else:
          r.advance()
    elif r.peek == '#' and r.peek(1) in {' ', '\t', '\r', '\n', '!', '\0'}:
      while r.pos < r.text.len and r.peek != '\n':
        r.advance()
    else:
      break

proc delimiter(c: char): bool =
  c in {' ', '\t', '\r', '\n', '(', ')', '[', ']', '{', '}', '^', '@',
        '"', '\'', '#', ',', ';', '$', '\0'} or ord(c) == 96

proc word(r: var LiteralReader): string =
  let start = r.pos
  while r.pos < r.text.len and not delimiter(r.peek):
    r.advance()
  if r.pos == start:
    r.invalid("expected an inert capability name or scalar")
  r.text[start ..< r.pos]

proc validIdentifier(name: string, property = false): bool =
  if name.len == 0:
    return false
  if property:
    if name[0] notin {'a'..'z', 'A'..'Z', '_'}:
      return false
    for c in name:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        return false
    return true
  let parts = name.split('/')
  if parts.len < 2:
    return false
  for i, part in parts:
    if i == parts.high and part == "*":
      continue
    if part.len == 0 or part[0] notin {'a'..'z', 'A'..'Z'}:
      return false
    for c in part:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        return false
  # Exact catalog lookup establishes canonical spelling and admitted aliases.
  true

proc escapedRune(r: var LiteralReader): string =
  if r.pos >= r.text.len:
    r.invalid("unterminated capability string escape")
  let escape = r.peek
  r.advance()
  case escape
  of 'n': return "\n"
  of 'r': return "\r"
  of 't': return "\t"
  of '0': return "\0"
  of '\\': return "\\"
  of '"': return "\""
  of '\'': return "'"
  of 'u', 'U':
    var digits = if escape == 'u': 4 else: 8
    let braced = escape == 'u' and r.peek == '{'
    if braced:
      r.advance()
      digits = 6
    var code = 0'i64
    var count = 0
    while count < digits and r.pos < r.text.len:
      let c = r.peek
      if braced and c == '}':
        break
      let n = case c
        of '0'..'9': ord(c) - ord('0')
        of 'a'..'f': ord(c) - ord('a') + 10
        of 'A'..'F': ord(c) - ord('A') + 10
        else: -1
      if n < 0:
        r.invalid("invalid Unicode escape in capability string")
      code = (code shl 4) + n
      inc count
      r.advance()
    if braced:
      if count == 0 or r.peek != '}':
        r.invalid("invalid braced Unicode escape in capability string")
      r.advance()
    elif count != digits:
      r.invalid("incomplete Unicode escape in capability string")
    if code > 0x10ffff or code in 0xd800'i64..0xdfff'i64:
      r.invalid("capability Unicode escape is not a scalar value")
    return Rune(code.int32).toUTF8()
  else:
    r.invalid("unknown capability string escape")

proc quoted(r: var LiteralReader): string =
  let start = r.location
  r.advance()
  let triple = r.peek == '"' and r.peek(1) == '"'
  if triple:
    r.advance()
    r.advance()
  while true:
    if r.pos >= r.text.len:
      invalid(start, "unterminated capability string")
    if r.peek == '"' and (not triple or
        (r.peek(1) == '"' and r.peek(2) == '"')):
      r.advance()
      if triple:
        r.advance()
        r.advance()
      break
    if r.peek == '\\':
      r.advance()
      result.add r.escapedRune()
    else:
      result.add r.peek
      r.advance()
    if result.len > r.limits.maxStringBytes:
      invalid(start, "capability string size limit exceeded")
  if validateUtf8(result) != -1:
    invalid(start, "capability string must contain valid UTF-8")

proc scalar(r: var LiteralReader): CapabilityScalar =
  r.skipSpace()
  if r.peek == '"':
    return CapabilityScalar(kind: cskText, text: r.quoted(),
                            stringMode: csmSource)
  let start = r.location
  let token = r.word()
  case token
  of "*": return capabilityAny()
  of "true": return capabilityBoolean(true)
  of "false": return capabilityBoolean(false)
  else:
    var digitStart = 0
    if token[0] == '-':
      digitStart = 1
    if token.len > digitStart + 2 and
        token[digitStart ..< digitStart + 2] == "0x":
      let negative = token[0] == '-'
      let limit = if negative: 1'u64 shl 63 else: uint64(high(int64))
      var value = 0'u64
      for i in digitStart + 2 ..< token.len:
        let digit = case token[i]
          of '0'..'9': ord(token[i]) - ord('0')
          of 'a'..'f': ord(token[i]) - ord('a') + 10
          of 'A'..'F': ord(token[i]) - ord('A') + 10
          else: -1
        if digit < 0:
          invalid(start, "invalid hexadecimal capability integer")
        if value > (limit - uint64(digit)) div 16:
          invalid(start, "capability integer is outside the signed 64-bit range")
        value = value * 16 + uint64(digit)
      if negative and value == (1'u64 shl 63):
        return capabilityInteger(low(int64))
      return capabilityInteger(if negative: -int64(value) else: int64(value))
    var decimal = digitStart < token.len
    for i in digitStart ..< token.len:
      if token[i] notin {'0'..'9'}:
        decimal = false
    if not decimal:
      invalid(start, "capability scalars must be strings, integers, booleans, or *")
    try:
      return capabilityInteger(parseBiggestInt(token))
    except ValueError:
      invalid(start, "capability integer is outside the signed 64-bit range")

proc propertyValue(r: var LiteralReader): CapabilityPropertyValue =
  r.skipSpace()
  if r.peek != '[':
    return capabilityValue(r.scalar())
  r.advance()
  result = CapabilityPropertyValue(isList: true)
  r.skipSpace()
  while r.peek != ']':
    if result.items.len >= r.limits.maxListItems:
      r.invalid("capability property list size limit exceeded")
    result.items.add r.scalar()
    let endPos = r.pos
    r.skipSpace()
    if r.peek != ']' and r.pos == endPos:
      r.invalid("capability list values must be separated by whitespace")
  r.advance()

proc validateOptional(entry: CapabilityEntryLiteral, use: CapabilityUse) =
  if entry.hasOptional and use != cuRequest:
    invalid(entry.location, "optional is allowed only in capability requests")
  if entry.optional and not entry.hasOptional:
    invalid(entry.location, "optional capability metadata must be explicit")

proc entry(r: var LiteralReader): CapabilityEntryLiteral =
  r.skipSpace()
  result.location = r.location
  let parenthesized = r.peek == '('
  if parenthesized:
    r.advance()
    r.skipSpace()
  result.name = r.word()
  if not validIdentifier(result.name):
    invalid(result.location, "invalid capability identifier: " & result.name)
  if not parenthesized:
    return
  var seen = initHashSet[string]()
  while true:
    let endPos = r.pos
    r.skipSpace()
    if r.peek == ')':
      r.advance()
      break
    if r.pos >= r.text.len:
      invalid(result.location, "unterminated capability entry")
    if r.pos == endPos:
      r.invalid("capability components must be separated by whitespace")
    if r.peek == '^':
      let propertyLocation = r.location
      r.advance()
      let flag = r.peek == '^'
      if flag:
        r.advance()
      let name = r.word()
      if not validIdentifier(name, property = true):
        invalid(propertyLocation, "invalid capability property name")
      if seen.containsOrIncl(name):
        invalid(propertyLocation, "duplicate capability property: " & name)
      if seen.len > r.limits.maxProperties:
        invalid(propertyLocation, "capability property count limit exceeded")
      if not flag:
        let endOfName = r.pos
        r.skipSpace()
        if r.pos == endOfName:
          invalid(propertyLocation, "capability property value requires whitespace")
      let value = if flag: capabilityValue(capabilityBoolean(true))
                  else: r.propertyValue()
      if name == "optional":
        if value.isList or value.scalar.kind != cskBoolean:
          invalid(propertyLocation, "optional must be a literal boolean")
        result.hasOptional = true
        result.optional = value.scalar.boolean
      else:
        result.properties.add CapabilityPropertyLiteral(
          name: name, value: value, location: propertyLocation)
    else:
      if result.body.len >= r.limits.maxBodyValues:
        r.invalid("capability body size limit exceeded")
      result.body.add r.scalar()
  result.validateOptional(r.use)

proc readCapabilityLiteralImpl(text: string, use: CapabilityUse,
    source: CapabilitySourceContext,
    limits: CapabilityLiteralLimits, prefix: bool,
    line = 1, column = 1, baseOffset = 0): CapabilityLiteralRow =
  validLimits(limits)
  var r = LiteralReader(text: text, source: checkedSource(source),
                        use: use, limits: limits, line: line, column: column,
                        baseOffset: baseOffset)
  if not prefix and text.len > limits.maxBytes:
    r.invalid("capability literal byte limit exceeded")
  if not prefix and ('\0' in text or validateUtf8(text) != -1):
    r.invalid("capability source must be UTF-8 without NUL bytes")
  r.skipSpace()
  if r.peek != '[':
    r.invalid("capability policy must be exactly one outer row")
  r.advance()
  result = CapabilityLiteralRow(sourceValue: r.source)
  r.skipSpace()
  while r.peek != ']':
    if result.entriesValue.len >= limits.maxEntries:
      r.invalid("capability row length limit exceeded")
    result.entriesValue.add r.entry()
    r.skipSpace()
  r.advance()
  if r.pos > limits.maxBytes:
    r.invalid("capability literal byte limit exceeded")
  if prefix:
    let consumed = text[0 ..< r.pos]
    if '\0' in consumed or validateUtf8(consumed) != -1:
      r.invalid("capability source must be UTF-8 without NUL bytes")
    return
  r.skipSpace()
  if r.pos != text.len:
    r.invalid("unexpected data after capability row")

proc readCapabilityLiteral*(text: string, use: CapabilityUse,
    source: CapabilitySourceContext,
    limits = DefaultCapabilityLiteralLimits): CapabilityLiteralRow =
  readCapabilityLiteralImpl(text, use, source, limits, false)

proc readCapabilityLiteralAt*(sourceText: string, offset, line, column: int,
    use: CapabilityUse, source: CapabilitySourceContext,
    limits = DefaultCapabilityLiteralLimits): CapabilityLiteralRow =
  if offset < 0 or offset >= sourceText.len or sourceText[offset] != '[':
    invalid(CapabilityLocation(sourceName: source.name, line: line, column: column),
      "capability source offset must identify an outer row")
  let last = min(sourceText.high, offset + limits.maxBytes)
  readCapabilityLiteralImpl(sourceText[offset .. last], use, source,
    limits, true, line, column, offset)

proc copyEntry(entry: CapabilityEntryLiteral): CapabilityEntryLiteral =
  result = entry
  result.body = @[]
  for scalar in entry.body:
    result.body.add scalar
  result.properties = @[]
  for property in entry.properties:
    var copied = property
    if property.value.isList:
      copied.value = CapabilityPropertyValue(isList: true)
      for item in property.value.items:
        copied.value.items.add item
    result.properties.add copied

proc entries*(row: CapabilityLiteralRow): seq[CapabilityEntryLiteral] =
  if row == nil:
    invalid(CapabilityLocation(line: 1, column: 1), "nil capability literal row")
  for entry in row.entriesValue:
    result.add copyEntry(entry)

proc source*(row: CapabilityLiteralRow): CapabilitySourceContext =
  if row == nil:
    invalid(CapabilityLocation(line: 1, column: 1), "nil capability literal row")
  row.sourceValue

proc len*(row: CapabilityLiteralRow): int =
  if row == nil: 0 else: row.entriesValue.len

proc freezeCapabilityLiteral(entries: openArray[CapabilityEntryLiteral],
    use: CapabilityUse, source: CapabilitySourceContext,
    limits: CapabilityLiteralLimits, sourceValues: bool): CapabilityLiteralRow =
  validLimits(limits)
  let source = checkedSource(source)
  let location = CapabilityLocation(sourceName: source.name, line: 1, column: 1)
  if entries.len > limits.maxEntries:
    invalid(location, "capability row length limit exceeded")
  result = CapabilityLiteralRow(sourceValue: source)
  var bytes = 2
  for input in entries:
    var entry = copyEntry(input)
    if not sourceValues or entry.location.line == 0:
      entry.location = location
    if not validIdentifier(entry.name):
      invalid(location, "invalid capability identifier: " & entry.name)
    bytes += entry.name.len + 2
    entry.validateOptional(use)
    if entry.hasOptional:
      bytes += " ^optional ".len + (if entry.optional: 4 else: 5)
    if entry.body.len > limits.maxBodyValues:
      invalid(location, "capability body size limit exceeded")
    if entry.properties.len + ord(entry.hasOptional) > limits.maxProperties:
      invalid(location, "capability property count limit exceeded")
    proc validate(value: CapabilityScalar) =
      inc bytes
      if value.kind == cskInvalid:
        invalid(location, "capability builder value is missing")
      elif value.kind == cskText:
        if value.text.len > limits.maxStringBytes or validateUtf8(value.text) != -1:
          invalid(location, "invalid or oversized capability builder string")
        if value.stringMode == csmSource and not sourceValues:
          invalid(location, "builder strings must be literal or explicit patterns")
        bytes += 2
        for c in value.text:
          bytes += (if c in {'"', '\\', '\n', '\r', '\t', '\0'}: 2 else: 1)
      elif value.kind == cskInteger:
        bytes += ($value.integer).len
      elif value.kind == cskBoolean:
        bytes += (if value.boolean: 4 else: 5)
      else:
        inc bytes
    for scalar in entry.body:
      validate(scalar)
    var seen = initHashSet[string]()
    for property in entry.properties:
      if not validIdentifier(property.name, property = true) or
          property.name == "optional":
        invalid(location, "invalid or reserved capability builder property")
      if seen.containsOrIncl(property.name):
        invalid(location, "duplicate capability property: " & property.name)
      bytes += property.name.len + 2
      if property.value.isList:
        bytes += 2
        if property.value.items.len > limits.maxListItems:
          invalid(location, "capability property list size limit exceeded")
        for item in property.value.items:
          validate(item)
      else:
        validate(property.value.scalar)
    if bytes > limits.maxBytes:
      invalid(location, "capability builder byte limit exceeded")
    result.entriesValue.add entry

proc buildCapabilityLiteral*(entries: openArray[CapabilityEntryLiteral],
    use: CapabilityUse, source: CapabilitySourceContext,
    limits = DefaultCapabilityLiteralLimits): CapabilityLiteralRow =
  freezeCapabilityLiteral(entries, use, source, limits, false)

proc buildCapabilitySourceLiteral*(entries: openArray[CapabilityEntryLiteral],
    use: CapabilityUse, source: CapabilitySourceContext,
    limits = DefaultCapabilityLiteralLimits): CapabilityLiteralRow =
  ## Compiler-only AST lowering: source strings retain provider-defined pattern
  ## meaning. The compiler checks original reader provenance before calling it.
  freezeCapabilityLiteral(entries, use, source, limits, true)
