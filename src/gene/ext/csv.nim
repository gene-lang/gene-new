## CSV data and incremental row parser for the gene/csv namespace.
## This file is included by stdlib.nim in the VM compilation unit.

type
  CsvMode = enum
    csvFieldStart, csvUnquoted, csvQuoted, csvAfterQuote

  CsvParserState = object
    mode: CsvMode
    delimiter: char
    field: string
    row: seq[string]
    readyRow: seq[string]
    rowReady: bool
    rowStarted: bool
    expectLf: bool
    offset: int
    recordIndex: int
    recordBytes: int
    maxFieldBytes: int
    maxRecordBytes: int
    maxColumns: int
    scope: Scope

  CsvReaderRecord = ref object
    applicationPtr: pointer # identity only; do not retain the caller's scope
    parser: CsvParserState
    source: Value
    ownSource: bool
    hasHeaders: bool
    headers: seq[string]
    headerSeen: bool
    buffered: string
    cursor: int
    bomPending: string
    bomDone: bool
    eof: bool
    failed: bool
    closed: bool
    pending: Value
    closedSignal: Value
    sourceClosedTask: Value
    peakPayloadBytes: int

const
  csvDefaultMaxBytes = 16 * 1024 * 1024
  csvDefaultMaxFieldBytes = 1024 * 1024
  csvDefaultMaxRecordBytes = 8 * 1024 * 1024
  csvDefaultMaxColumns = 4096
  csvHardMaxBytes = 64 * 1024 * 1024
  csvHardMaxColumns = 16384

var csvReaderLock: Lock
var csvReaderRecords = initTable[uint64, CsvReaderRecord]()
initLock(csvReaderLock)

proc csvReaderOpenCount(app: Application): int =
  withLock csvReaderLock:
    for _, record in csvReaderRecords:
      if record.applicationPtr == cast[pointer](app) and not record.closed:
        inc result

proc csvParserPayloadBytes(record: CsvReaderRecord): int =
  result = record.buffered.len + record.bomPending.len +
    record.parser.field.len
  for field in record.parser.row:
    result += field.len
  for field in record.parser.readyRow:
    result += field.len
  for name in record.headers:
    result += name.len

proc csvNotePeak(record: CsvReaderRecord) =
  record.peakPayloadBytes = max(record.peakPayloadBytes,
                                csvParserPayloadBytes(record))

proc csvReaderPayloadStats(app: Application): tuple[current, peakResource: int] =
  withLock csvReaderLock:
    for _, record in csvReaderRecords:
      if record.applicationPtr == cast[pointer](app):
        result.current += csvParserPayloadBytes(record)
        result.peakResource = max(result.peakResource,
                                  record.peakPayloadBytes)

proc releaseCsvReaderRecord(id: uint64) {.raises: [].} =
  var retired: CsvReaderRecord
  withLock csvReaderLock:
    discard csvReaderRecords.pop(id, retired)
  # Dropping the source/pending Task may itself release another CsvReader.
  # Do that outside the table lock so nested resource release cannot deadlock.
  reset(retired)

proc raiseCsvError(state: CsvParserState, message: string) {.noreturn.} =
  var props = initPropTable()
  props["message"] = newStr("csv: " & message)
  props["offset"] = newInt(state.offset)
  props["record"] = newInt(if state.rowReady: state.recordIndex
                           else: state.recordIndex + 1)
  props["field"] = newInt(state.row.len + 1)
  var error: ref GeneError
  new(error)
  error.msg = "csv: " & message
  let typ =
    if state.scope != nil and state.scope.application().stdlib != nil:
      state.scope.application().stdlib.vars["csv"].nsScope.vars["CsvError"]
    else:
      builtInTypeHead(state.scope, "CsvError")
  error.errVal = newNode(typ, props = props)
  error.hasErrVal = true
  raise error

proc csvAppendField(state: var CsvParserState) =
  if state.row.len >= state.maxColumns:
    raiseCsvError(state, "column limit exceeded")
  let bad = unicode.validateUtf8(state.field)
  if bad >= 0:
    raiseCsvError(state, "field is not valid UTF-8")
  state.row.add move state.field
  state.field = ""
  state.mode = csvFieldStart

proc csvAppendByte(state: var CsvParserState, ch: char) =
  if state.field.len >= state.maxFieldBytes:
    raiseCsvError(state, "field byte limit exceeded")
  state.field.add ch

proc csvCompleteRow(state: var CsvParserState) =
  csvAppendField(state)
  state.readyRow = move state.row
  state.row = @[]
  state.rowReady = true
  state.rowStarted = false
  state.recordBytes = 0
  inc state.recordIndex

proc csvPushByte(state: var CsvParserState, ch: char): bool =
  ## A completed row is exposed immediately. A later streaming adapter can
  ## stop feeding here instead of queuing the rest of a large input chunk.
  if state.rowReady:
    raiseCsvError(state, "consume the completed row before feeding another byte")
  inc state.offset
  if state.expectLf:
    if ch != '\n':
      raiseCsvError(state, "CR outside quotes must be followed by LF")
    state.expectLf = false
    csvCompleteRow(state)
    return true
  if state.recordBytes >= state.maxRecordBytes:
    raiseCsvError(state, "record byte limit exceeded")
  inc state.recordBytes
  state.rowStarted = true
  case state.mode
  of csvQuoted:
    if ch == '"':
      state.mode = csvAfterQuote
    else:
      csvAppendByte(state, ch)
  of csvAfterQuote:
    if ch == '"':
      csvAppendByte(state, '"')
      state.mode = csvQuoted
    elif ch == state.delimiter:
      csvAppendField(state)
    elif ch == '\n':
      csvCompleteRow(state)
    elif ch == '\r':
      state.expectLf = true
    else:
      raiseCsvError(state, "unexpected byte after closing quote")
  of csvFieldStart:
    if ch == '"':
      state.mode = csvQuoted
    elif ch == state.delimiter:
      csvAppendField(state)
    elif ch == '\n':
      csvCompleteRow(state)
    elif ch == '\r':
      state.expectLf = true
    else:
      csvAppendByte(state, ch)
      state.mode = csvUnquoted
  of csvUnquoted:
    if ch == '"':
      raiseCsvError(state, "quote in unquoted field")
    elif ch == state.delimiter:
      csvAppendField(state)
    elif ch == '\n':
      csvCompleteRow(state)
    elif ch == '\r':
      state.expectLf = true
    else:
      csvAppendByte(state, ch)
  result = state.rowReady

proc csvFinish(state: var CsvParserState): bool =
  if state.expectLf:
    raiseCsvError(state, "input ends after CR")
  if state.mode == csvQuoted:
    raiseCsvError(state, "unclosed quoted field")
  if not state.rowStarted:
    return false
  csvCompleteRow(state)
  result = true

proc csvOptionLimit(name: string, value: Value, maximum: int,
                    state: CsvParserState): int =
  if value.kind != vkInt or not value.intFitsInt64 or value.intVal < 1 or
      value.intVal > maximum:
    raiseCsvError(state, name & " must be a positive bounded Int")
  int(value.intVal)

proc csvDelimiter(value: Value, state: CsvParserState): char =
  if value.kind != vkString or value.strVal.len != 1 or
      value.strVal[0] in {'"', '\r', '\n'} or ord(value.strVal[0]) > 127:
    raiseCsvError(state, "delimiter must be one ASCII byte other than quote/newline")
  value.strVal[0]

proc csvRowValue(row: seq[string], headers: seq[string], hasHeaders: bool,
                 state: CsvParserState): Value =
  if hasHeaders:
    if row.len != headers.len:
      raiseCsvError(state, "row width differs from header")
    var props = initPropTable()
    for i, name in headers:
      props[name] = newStr(row[i])
    result = newMap(props)
  else:
    var values: seq[Value]
    for field in row:
      values.add newStr(field)
    result = newList(values)

proc csvTakeReadyRow(state: var CsvParserState, headers: var seq[string],
                     headerSeen: var bool, hasHeaders: bool): Value =
  if not state.rowReady:
    return VOID
  let row = move state.readyRow
  state.rowReady = false
  if hasHeaders and not headerSeen:
    var seen = initHashSet[string]()
    for name in row:
      if name.len == 0 or name in seen:
        raiseCsvError(state, "header names must be nonempty and distinct")
      seen.incl name
    headers = row
    headerSeen = true
    return VOID
  csvRowValue(row, headers, hasHeaders, state)

proc biCsvParseRows(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  var state = CsvParserState(delimiter: ',', maxFieldBytes: csvDefaultMaxFieldBytes,
    maxRecordBytes: csvDefaultMaxRecordBytes, maxColumns: csvDefaultMaxColumns,
    scope: scope)
  if args.len != 1 or args[0].kind != vkString:
    raiseCsvError(state, "parse_rows expects one Str input")
  var hasHeaders = false
  var maxBytes = csvDefaultMaxBytes
  if call != nil:
    for i, name in call[].namedNames:
      let option = call[].namedValues[i]
      case name
      of "headers":
        if option.kind != vkBool: raiseCsvError(state, "headers must be Bool")
        hasHeaders = option.boolVal
      of "delimiter": state.delimiter = csvDelimiter(option, state)
      of "max_bytes":
        maxBytes = csvOptionLimit(name, option, csvHardMaxBytes, state)
      of "max_field_bytes":
        state.maxFieldBytes = csvOptionLimit(name, option, csvHardMaxBytes, state)
      of "max_record_bytes":
        state.maxRecordBytes = csvOptionLimit(name, option, csvHardMaxBytes, state)
      of "max_columns":
        state.maxColumns = csvOptionLimit(name, option, csvHardMaxColumns, state)
      else: raiseCsvError(state, "unknown named argument: " & name)
  let input = args[0].strVal
  if input.len > maxBytes:
    raiseCsvError(state, "input byte limit exceeded")
  let start = if input.startsWith("\xEF\xBB\xBF"): 3 else: 0
  state.offset = start
  var headers: seq[string]
  var headerSeen = false
  var rows: seq[Value]
  proc acceptReadyRow() =
    let value = csvTakeReadyRow(state, headers, headerSeen, hasHeaders)
    if value.kind != vkVoid:
      rows.add value
  for i in start ..< input.len:
    if csvPushByte(state, input[i]):
      acceptReadyRow()
  if csvFinish(state):
    acceptReadyRow()
  result = newList(rows)

proc biCsvEncodeRow(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  var state = CsvParserState(delimiter: ',', maxFieldBytes: csvDefaultMaxFieldBytes,
    maxRecordBytes: csvDefaultMaxRecordBytes, maxColumns: csvDefaultMaxColumns,
    scope: scope)
  if args.len != 1 or args[0].kind != vkList or args[0].listItems.len == 0:
    raiseCsvError(state, "encode_row expects a nonempty List of Str")
  if call != nil:
    for i, name in call[].namedNames:
      if name != "delimiter": raiseCsvError(state, "unknown named argument: " & name)
      state.delimiter = csvDelimiter(call[].namedValues[i], state)
  if args[0].listItems.len > state.maxColumns:
    raiseCsvError(state, "column limit exceeded")
  var encoded = ""
  for i, value in args[0].listItems:
    if value.kind != vkString:
      raiseCsvError(state, "encode_row fields must be Str")
    let field = value.strVal
    if field.len > state.maxFieldBytes or unicode.validateUtf8(field) >= 0:
      raiseCsvError(state, "field is too large or invalid UTF-8")
    if i > 0: encoded.add state.delimiter
    let quoted = state.delimiter in field or '"' in field or
                 '\r' in field or '\n' in field
    if quoted: encoded.add '"'
    for ch in field:
      if ch == '"': encoded.add '"'
      encoded.add ch
    if quoted: encoded.add '"'
    if encoded.len > state.maxRecordBytes:
      raiseCsvError(state, "encoded record byte limit exceeded")
  encoded.add "\r\n"
  if encoded.len > state.maxRecordBytes:
    raiseCsvError(state, "encoded record byte limit exceeded")
  result = newBytes(encoded)

proc csvReaderRecord(value: Value, scope: Scope): CsvReaderRecord =
  let errorState = CsvParserState(scope: scope)
  let csvType = scope.application().stdlib.vars["csv"].nsScope.vars["CsvReader"]
  if value.kind != vkNode or
      value.head.bits != csvType.bits:
    raiseCsvError(errorState, "expected CsvReader")
  withLock csvReaderLock:
    result = csvReaderRecords.getOrDefault(value.nodeResourceId)
  if result == nil or result.applicationPtr != cast[pointer](scope.application()):
    raiseCsvError(errorState, "reader is no longer available")
  if currentEventLane() != schedulerForScope(scope).rootLane:
    raiseCsvError(errorState, "reader requires the root lane")

proc csvStepResult(kind: int, row: Value = NIL): Value =
  newList(@[newInt(kind), row])

proc csvPushStreamByte(record: CsvReaderRecord, ch: char) =
  if record.bomDone:
    discard csvPushByte(record.parser, ch)
    return
  record.bomPending.add ch
  if record.bomPending == "\xEF" or record.bomPending == "\xEF\xBB":
    return
  record.bomDone = true
  if record.bomPending == "\xEF\xBB\xBF":
    record.parser.offset = 3
  else:
    for pending in record.bomPending:
      discard csvPushByte(record.parser, pending)
  record.bomPending.setLen(0)

proc csvAdvance(record: CsvReaderRecord, scope: Scope): Value =
  record.parser.scope = scope
  defer:
    csvNotePeak(record)
    record.parser.scope = nil
  if record.closed or record.failed:
    raiseCsvError(record.parser, "reader is closed")
  try:
    while true:
      if record.parser.rowReady:
        csvNotePeak(record)
        let row = csvTakeReadyRow(record.parser, record.headers,
                                  record.headerSeen, record.hasHeaders)
        if row.kind != vkVoid:
          return csvStepResult(1, row)
      if record.cursor < record.buffered.len:
        let ch = record.buffered[record.cursor]
        inc record.cursor
        record.csvPushStreamByte(ch)
        if record.cursor == record.buffered.len:
          record.buffered.setLen(0)
          record.cursor = 0
        continue
      if not record.eof:
        return csvStepResult(0)
      if not record.bomDone and record.bomPending.len > 0:
        record.bomDone = true
        let pending = move record.bomPending
        for ch in pending:
          discard csvPushByte(record.parser, ch)
        continue
      if csvFinish(record.parser):
        continue
      return csvStepResult(2)
  except GeneError:
    record.failed = true
    raise

proc biCsvReader(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  var state = CsvParserState(delimiter: ',', maxFieldBytes: csvDefaultMaxFieldBytes,
    maxRecordBytes: csvDefaultMaxRecordBytes, maxColumns: csvDefaultMaxColumns,
    scope: scope)
  if scope == nil or args.len != 1:
    raiseCsvError(state, "reader expects one AsyncReader")
  let stdlib = scope.application().stdlib
  let ioScope = stdlib.vars["io"].nsScope
  let asyncReader = ioScope.vars["AsyncReader"]
  if not scope.typeImplementsProtocol(projectHead(args[0]), asyncReader):
    raiseCsvError(state, "source must implement AsyncReader")
  var hasHeaders = false
  var ownSource = false
  if call != nil:
    for i, name in call[].namedNames:
      let option = call[].namedValues[i]
      case name
      of "headers":
        if option.kind != vkBool: raiseCsvError(state, "headers must be Bool")
        hasHeaders = option.boolVal
      of "own_reader":
        if option.kind != vkBool: raiseCsvError(state, "own_reader must be Bool")
        ownSource = option.boolVal
      of "delimiter": state.delimiter = csvDelimiter(option, state)
      of "max_field_bytes":
        state.maxFieldBytes = csvOptionLimit(name, option, csvHardMaxBytes, state)
      of "max_record_bytes":
        state.maxRecordBytes = csvOptionLimit(name, option, csvHardMaxBytes, state)
      of "max_columns":
        state.maxColumns = csvOptionLimit(name, option, csvHardMaxColumns, state)
      else: raiseCsvError(state, "unknown named argument: " & name)
  if ownSource and not scope.typeImplementsProtocol(projectHead(args[0]),
      ioScope.vars["IoResource"]):
    raiseCsvError(state, "owned source must implement IoResource")
  state.scope = nil
  let record = CsvReaderRecord(applicationPtr: cast[pointer](scope.application()),
    parser: state,
    source: args[0], ownSource: ownSource, hasHeaders: hasHeaders,
    closedSignal: newExternalTask())
  result = newNode(stdlib.vars["csv"].nsScope.vars["CsvReader"],
                   immutable = true)
  result.setNodeResourceId(nextRuntimeResourceId())
  withLock csvReaderLock:
    csvReaderRecords[result.nodeResourceId] = record

proc biCsvReaderFeed(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 2:
    raiseCsvError(CsvParserState(scope: scope), "reader feed expects two arguments")
  let record = csvReaderRecord(args[0], scope)
  record.parser.scope = scope
  defer:
    csvNotePeak(record)
    record.parser.scope = nil
  if record.closed or record.failed or record.eof or
      record.cursor < record.buffered.len:
    raiseCsvError(record.parser, "reader cannot accept another chunk")
  if args[1].kind == vkNil:
    record.eof = true
  elif args[1].kind == vkBytes:
    if args[1].bytesVal.len == 0 or args[1].bytesVal.len > 65536:
      raiseCsvError(record.parser, "source returned an invalid chunk size")
    record.buffered = args[1].bytesVal
    record.cursor = 0
  else:
    raiseCsvError(record.parser, "source must return Bytes or nil")
  NIL

proc biCsvReaderStep(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raiseCsvError(CsvParserState(scope: scope), "reader step expects one argument")
  csvAdvance(csvReaderRecord(args[0], scope), scope)

proc biCsvReaderFinishNext(args: openArray[Value],
                           call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raiseCsvError(CsvParserState(scope: scope), "reader finish expects one argument")
  let record = csvReaderRecord(args[0], scope)
  record.pending = NIL
  NIL

proc biCsvReaderSourceClosed(args: openArray[Value],
                             call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raiseCsvError(CsvParserState(scope: scope),
      "source close state expects one argument")
  csvReaderRecord(args[0], scope).sourceClosedTask

proc biCsvReaderNext(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raiseCsvError(CsvParserState(scope: scope), "next expects no arguments")
  let record = csvReaderRecord(args[0], scope)
  var errorState = record.parser
  errorState.scope = scope
  if record.closed or record.failed:
    raiseCsvError(errorState, "reader is closed")
  if record.pending.kind == vkTask and not record.pending.taskDone:
    raiseCsvError(errorState, "next is already pending")
  record.pending = NIL
  result = applyCall(scope.application().csvNextHelper, [args[0], record.source],
                     NamedArgs(), scope)
  if result.kind != vkTask:
    raiseCsvError(errorState, "next did not create a Task")
  if not result.taskDone:
    record.pending = result

proc biCsvReaderClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raiseCsvError(CsvParserState(scope: scope), "close expects no arguments")
  let record = csvReaderRecord(args[0], scope)
  if record.closed: return NIL
  record.closed = true
  csvNotePeak(record)
  record.parser.field = ""
  record.parser.row = @[]
  record.parser.readyRow = @[]
  record.headers = @[]
  record.buffered = ""
  record.bomPending = ""
  record.cursor = 0
  let pending = record.pending
  record.pending = NIL
  if pending.kind == vkTask and not pending.taskDone:
    discard nativeTaskCancel(pending, scope)
  discard nativeTaskComplete(record.closedSignal, NIL, scope)
  if record.ownSource:
    try:
      let ioScope = scope.application().stdlib.vars["io"].nsScope
      let protocol = ioScope.vars["IoResource"]
      let closer = resolveProtocolMessage(scope,
        protocol.protocolMessages["close"], record.source)
      discard applyCall(closer, [record.source], NamedArgs(), scope)
      let waiter = resolveProtocolMessage(scope,
        protocol.protocolMessages["wait_closed"], record.source)
      record.sourceClosedTask = applyCall(waiter, [record.source],
                                          NamedArgs(), scope)
      if record.sourceClosedTask.kind != vkTask:
        raise newException(GeneError, "upstream wait_closed did not return Task")
    except CatchableError as failure:
      var props = initPropTable()
      props["message"] = newStr("csv upstream close failed: " & failure.msg)
      let error = newNode(scope.application().stdlib.vars["csv"].nsScope.vars["CsvError"],
                          props = props)
      record.sourceClosedTask = newFailedTask(failure.msg, error,
                                               hasValue = true)
  record.source = NIL
  NIL

proc biCsvReaderWaitClosed(args: openArray[Value],
                           call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raiseCsvError(CsvParserState(scope: scope), "wait_closed expects no arguments")
  let record = csvReaderRecord(args[0], scope)
  applyCall(scope.application().csvWaitClosedHelper,
    [args[0], record.closedSignal],
    NamedArgs(), scope)
