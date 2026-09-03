## Canonical printer (design Section 18).
##
## Produces deterministic Gene surface text. Props and meta are emitted in
## stored (source) order. Immutable containers use their `#`-prefix. The
## output re-reads to a structurally equal value (AST-level round-trip).

import std/[strutils, unicode]
import ./capabilities
import ./types

proc print*(v: Value): string

proc escapeStr(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else: result.add ch
  result.add "\""

proc printCapabilityArg(argument: CapabilityArg): string =
  case argument.kind
  of cakNil: result = "nil"
  of cakBool: result = if argument.boolValue: "true" else: "false"
  of cakInt: result = $argument.intValue
  of cakString: result = escapeStr(argument.stringValue)
  of cakSymbol: result = argument.symbolValue
  of cakList:
    result = "#["
    for i, item in argument.listValue:
      if i > 0: result.add " "
      result.add printCapabilityArg(item)
    result.add "]"
  of cakMap:
    result = "#{"
    for i, item in argument.mapValue:
      if i > 0: result.add " "
      result.add "^" & item.name & " " & printCapabilityArg(item.value)
    result.add "}"

proc printCapability(v: Value): string =
  if not v.capabilityIsAdmitted:
    return "(capability " & v.capabilityName & ")"
  let spec = v.capabilitySpec
  result = "(" & v.capabilityName
  for named in spec.named:
    result.add " ^" & named.name & " "
    result.add printCapabilityArg(named.value)
  for arg in spec.positional:
    result.add " "
    result.add printCapabilityArg(arg)
  result.add ")"

proc printFloat(f: float64): string =
  result = $f
  # Ensure a decimal point so it re-reads as a float, not an int.
  if '.' notin result and 'e' notin result and
     'n' notin result and 'i' notin result:
    result.add ".0"

proc escapeChar(r: Rune): string =
  let code = int32(r)
  case code
  of int32(ord('\n')): "\\n"
  of int32(ord('\r')): "\\r"
  of int32(ord('\t')): "\\t"
  of 0: "\\0"
  of int32(ord('\\')): "\\\\"
  of int32(ord('\'')): "\\'"
  else:
    if code < 0x20 or code == 0x7f:
      "\\u" & toHex(int(code), 4)
    else:
      $r

proc printBytes(data: string): string =
  ## Canonical spelling is #B16#<hex> (design §7.5); #B# and #B64# are
  ## input spellings and round-trip through this form.
  result = "#B16#"
  for ch in data:
    result.add toHex(ord(ch), 2).toLowerAscii

proc printRegex(pattern, flags: string): string =
  result = "#\""
  for ch in pattern:
    if ch == '"':
      result.add "\\\""
    else:
      result.add ch
  result.add '"'
  result.add flags

proc pad2(n: int): string =
  if n < 10: "0" & $n else: $n

proc pad4(n: int): string =
  let s = $n
  if s.len >= 4: s else: repeat("0", 4 - s.len) & s

proc fractionalMicros(microsecond: int): string =
  if microsecond == 0:
    return ""
  result = "." & align($microsecond, 6, '0')
  while result.len > 1 and result[^1] == '0':
    result.setLen(result.len - 1)

proc formatOffset(offsetMinutes: int): string =
  let sign = if offsetMinutes < 0: "-" else: "+"
  let total = abs(offsetMinutes)
  sign & pad2(total div 60) & ":" & pad2(total mod 60)

proc formatTimezone(hasOffset: bool, offsetMinutes: int,
                    timezoneName: string, allowNameOnly: bool): string =
  if hasOffset:
    if offsetMinutes == 0 and timezoneName == "UTC":
      return "Z"
    result = formatOffset(offsetMinutes)
    if timezoneName.len > 0 and timezoneName != "UTC":
      result.add "[" & timezoneName & "]"
  elif allowNameOnly and timezoneName.len > 0:
    result = "[" & timezoneName & "]"
  else:
    result = ""

proc printDate(v: Value): string =
  pad4(v.dateYear) & "-" & pad2(v.dateMonth) & "-" & pad2(v.dateDay)

proc printTime(v: Value): string =
  result = pad2(v.timeHour) & ":" & pad2(v.timeMinute)
  let tz = formatTimezone(v.timeHasOffset, v.timeOffsetMinutes,
                          v.timeTimezoneName, allowNameOnly = true)
  if v.timeSecond != 0 or v.timeMicrosecond != 0 or tz.len > 0:
    result.add ":" & pad2(v.timeSecond)
  result.add fractionalMicros(v.timeMicrosecond)
  result.add tz

proc printDateTime(v: Value): string =
  result = pad4(v.dateTimeYear) & "-" & pad2(v.dateTimeMonth) & "-" &
           pad2(v.dateTimeDay) & "T" & pad2(v.dateTimeHour) & ":" &
           pad2(v.dateTimeMinute)
  let tz = formatTimezone(v.dateTimeHasOffset, v.dateTimeOffsetMinutes,
                          v.dateTimeTimezoneName, allowNameOnly = false)
  if v.dateTimeSecond != 0 or v.dateTimeMicrosecond != 0 or tz.len > 0:
    result.add ":" & pad2(v.dateTimeSecond)
  result.add fractionalMicros(v.dateTimeMicrosecond)
  result.add tz

proc printProps(sb: var string, props: PropTable, sigil: string) =
  for k, val in props:
    sb.add ' '
    if val.kind == vkBool and val.boolVal:
      sb.add sigil & sigil & k          # ^^flag / @@flag
    else:
      sb.add sigil & k
      sb.add ' '
      sb.add print(val)

proc printMessageQualifier(value: Value): string =
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.head.symVal == "path":
    for i, part in value.body:
      if i > 0: result.add '/'
      result.add print(part)
  else:
    result = print(value)

proc printHeldExpression(value: Value): string =
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.head.symVal == "path" and value.body.len >= 2:
    if value.body[0].kind == vkSymbol and value.body[0].symVal == "gene":
      result = "$"
      for i in 1 ..< value.body.len:
        if i > 1: result.add '/'
        result.add print(value.body[i])
    else:
      result = printMessageQualifier(value)
  else:
    result = print(value)

proc printSendDescriptor(callee: Value, optional: bool): string =
  result = if optional: "?." else: "."
  if callee.kind == vkNode and callee.head.kind == vkSymbol and
      callee.head.symVal == "msg" and callee.body.len == 2 and
      callee.body[1].kind == vkSymbol:
    result.add printMessageQualifier(callee.body[0])
    result.add ':'
    result.add callee.body[1].symVal
  elif callee.kind == vkNode and callee.head.kind == vkSymbol and
      callee.head.symVal == "unquote" and callee.body.len == 1:
    result.add '%'
    let expr = callee.body[0]
    if expr.kind == vkSymbol:
      result.add expr.symVal
    else:
      result.add printHeldExpression(expr)
  elif callee.kind == vkSymbol:
    result.add callee.symVal
  else:
    result.add '%' & print(callee)

proc pathSendMarker(value: Value): tuple[found, optional: bool,
                                           rest: string] =
  if value.kind != vkSymbol:
    return
  if value.symVal.len > 2 and value.symVal.startsWith("?~"):
    return (true, true, value.symVal[2 .. ^1])
  if value.symVal.len > 1 and value.symVal[0] == '~':
    return (true, false, value.symVal[1 .. ^1])

proc printPathSegment(value: Value): string =
  if value.kind == vkNode and value.head.kind == vkSymbol and
      value.head.symVal == "unquote" and value.body.len == 1:
    let expr = value.body[0]
    if expr.kind == vkSymbol:
      return "%" & expr.symVal
    if expr.kind == vkNode and expr.head.kind == vkSymbol and
        expr.head.symVal == "path" and expr.body.len >= 2 and
        expr.body[0].kind == vkSymbol and expr.body[0].symVal == "gene":
      result = "%$"
      for i in 1 ..< expr.body.len:
        if i > 1: result.add '/'
        result.add print(expr.body[i])
      return
  print(value)

proc printPathSend(value: Value): string =
  ## Return an empty string when this is an ordinary canonical `path` node.
  ## Paths containing reader-lowered sends resugar to `x/.message` so the
  ## canonical printer never emits the removed tilde spelling.
  if value.head.kind != vkSymbol or value.head.symVal != "path" or
      value.body.len < 2:
    return
  var hasSend = false
  for part in value.body:
    if part.pathSendMarker.found:
      hasSend = true
      break
  if not hasSend:
    return
  result = printPathSegment(value.body[0])
  for i in 1 ..< value.body.len:
    result.add '/'
    let marker = value.body[i].pathSendMarker
    if marker.found:
      result.add (if marker.optional: "?." else: ".")
      result.add marker.rest
    else:
      result.add printPathSegment(value.body[i])

proc printSendNode(value: Value): string =
  var optional = false
  var callee: Value
  var argsStart = 0
  var receiver = NIL
  if value.head.kind == vkSymbol and
      value.head.symVal in ["~", "?~"] and value.body.len > 0:
    optional = value.head.symVal == "?~"
    callee = value.body[0]
    argsStart = 1
  elif value.body.len > 1 and value.body[0].kind == vkSymbol and
      value.body[0].symVal in ["~", "?~"]:
    receiver = value.head
    optional = value.body[0].symVal == "?~"
    callee = value.body[1]
    argsStart = 2
  else:
    return
  result = if value.nodeImmutable: "#(" else: "("
  if receiver.kind != vkNil:
    result.add print(receiver)
    printProps(result, value.meta, "@")
    printProps(result, value.props, "^")
    result.add ' '
  result.add printSendDescriptor(callee, optional)
  if receiver.kind == vkNil:
    printProps(result, value.meta, "@")
    printProps(result, value.props, "^")
  for i in argsStart ..< value.body.len:
    result.add ' '
    result.add print(value.body[i])
  result.add ')'

proc pipelineDelimiter*(kind: PipelineStageKind): string =
  case kind
  of pstCall: "->"
  of pstIterate: "=>"

proc printPipelineStage(stage: PipelineStage): string =
  result = print(stage.head)
  printProps(result, stage.meta, "@")
  printProps(result, stage.props, "^")
  for item in stage.body:
    result.add ' '
    result.add print(item)

proc print*(v: Value): string =
  if v.isNil: return "nil"
  case v.kind
  of vkNil:    "nil"
  of vkVoid:   "void"
  of vkBool:   (if v.boolVal: "true" else: "false")
  of vkInt:    v.intToString
  of vkFloat:  printFloat(v.floatVal)
  of vkString: escapeStr(v.strVal)
  of vkBytes:  printBytes(v.bytesVal)
  of vkRegex:  printRegex(v.regexPattern, v.regexFlags)
  of vkDate:   printDate(v)
  of vkTime:   printTime(v)
  of vkDateTime: printDateTime(v)
  of vkTimezone:
    var sb = "(timezone"
    if v.timezoneHasOffset:
      sb.add " " & $v.timezoneOffsetMinutes
      if v.timezoneName.len > 0:
        sb.add " " & escapeStr(v.timezoneName)
    else:
      sb.add " " & escapeStr(v.timezoneName)
    sb.add ")"
    sb
  of vkDuration:
    "(duration " & $v.durationMicroseconds & ")"
  of vkChar:   "'" & escapeChar(v.charVal) & "'"
  of vkSymbol: v.symVal
  of vkList:
    var sb = if v.listImmutable: "#[" else: "["
    for i, it in v.listItems:
      if i > 0: sb.add ' '
      sb.add print(it)
    sb.add ']'
    sb
  of vkMap:
    var sb = if v.mapImmutable: "#{" else: "{"
    var first = true
    for k, val in v.mapEntries:
      if not first: sb.add ' '
      first = false
      if val.kind == vkBool and val.boolVal:
        sb.add "^^" & k
      else:
        sb.add "^" & k & " " & print(val)
    sb.add '}'
    sb
  of vkSet:
    var sb = "(Set"
    for it in v.setItems:
      sb.add ' '
      sb.add print(it)
    sb.add ')'
    sb
  of vkRange:
    var sb = "(range " & $v.rangeStart & " " & $v.rangeStop
    if v.rangeStep != 1 or v.rangeInclusive:
      sb.add " " & $v.rangeStep
    if v.rangeInclusive:
      sb.add " true"
    sb.add ")"
    sb
  of vkHashMap:
    var sb = "{{"
    var first = true
    for entry in v.hashMapEntries:
      if not first: sb.add ' '
      first = false
      sb.add print(entry.key)
      sb.add " : "
      sb.add print(entry.val)
    sb.add "}}"
    sb
  of vkNode:
    if v.head.kind == vkSymbol and v.head.symVal == "#Ref" and
        v.props.len == 0 and v.meta.len == 0 and
        v.body.len == 2 and v.body[0].kind == vkSymbol:
      return "#Ref " & v.body[0].symVal & " " & print(v.body[1])
    if v.head.kind == vkSymbol and v.head.symVal == "#Deref" and
        v.props.len == 0 and v.meta.len == 0 and
        v.body.len == 1 and v.body[0].kind == vkSymbol:
      return "#Deref " & v.body[0].symVal
    let send = printSendNode(v)
    if send.len > 0:
      return send
    let pathSend = printPathSend(v)
    if pathSend.len > 0:
      return pathSend
    var sb = if v.nodeImmutable: "#(" else: "("
    sb.add print(v.head)
    printProps(sb, v.meta, "@")
    printProps(sb, v.props, "^")
    for it in v.body:
      sb.add ' '
      sb.add print(it)
    sb.add ')'
    sb
  of vkPipeline:
    var sb = if v.pipelineImmutable: "#(" else: "("
    sb.add print(v.pipelineInitial)
    for stage in v.pipelineStages:
      sb.add ' '
      sb.add pipelineDelimiter(stage.kind)
      sb.add ' '
      sb.add printPipelineStage(stage)
    sb.add ')'
    sb
  # Callables are runtime values, not literals; rendered for display only.
  of vkFunction:
    if v.isSyntaxFn:
      (if v.fnName.len > 0: "(fn " & v.fnName & ")" else: "(fexpr)")
    else:
      (if v.fnName.len > 0: "(fn " & v.fnName & ")" else: "(fn)")
  of vkNativeFn:
    "(native-fn " & v.nativeFnName & ")"
  of vkNamespace:
    "(ns " & v.nsName & ")"
  of vkModule:
    "(mod " & v.moduleName & ")"
  of vkEnv:
    "(env)"
  of vkCallerEnv:
    "(caller_env)"
  of vkCell:
    "(cell)"
  of vkAtomicCell:
    "(atomic_cell)"
  of vkStream:
    "(stream)"
  of vkTask:
    "(task)"
  of vkChannel:
    "(channel)"
  of vkActorRef:
    "(actor)"
  of vkActorContext:
    "(actor-context)"
  of vkActorStep:
    "(actor-step)"
  of vkReplyTo:
    "(reply-to)"
  of vkCPtr:
    let base =
      if v.cPtrOwned: "c_owned_ptr"
      elif v.cPtrMutable: "c_ptr"
      else: "c_const_ptr"
    if v.cPtrClosed:
      "(" & base & " closed)"
    elif v.cPtrIsNull:
      "(" & base & " null)"
    else:
      "(" & base & ")"
  of vkCSlice:
    if v.cSliceIsNull:
      "(c-slice null " & $v.cSliceLen & ")"
    else:
      "(c-slice " & $v.cSliceLen & ")"
  of vkBuffer:
    let elemType =
      if v.bufferElemType.kind == vkNil: "Any"
      else: v.bufferElemType.print()
    "(buffer " & elemType & " " & $v.bufferLen & ")"
  of vkDeviceBuffer:
    let elemType =
      if v.deviceBufferElemType.kind == vkNil: "Any"
      else: v.deviceBufferElemType.print()
    "(device-buffer " & v.deviceBufferBackend & " " & elemType & " " &
      $v.deviceBufferLen & ")"
  of vkCapability:
    printCapability(v)
  of vkFfiLibrary:
    if v.ffiLibraryClosed:
      "(ffi-library closed)"
    else:
      "(ffi-library)"
  of vkFfiCallable:
    "(ffi-callable " & v.ffiCallableName & ")"
  of vkLogger:
    "(logger " & escapeStr(v.loggerName) & ")"
  of vkEventBus:
    if v.eventBusClosed: "(event/Bus closed)" else: "(event/Bus)"
  of vkEventSubscription:
    "(event/Subscription)"
  of vkEventMatcher:
    "(event/exact " & v.eventMatcherTarget.typeName & ")"
  of vkRecordingSink:
    "(event/RecordingSink " & $v.recordedEvents.len & ")"
  of vkNullSink:
    "(event/NullSink)"
  of vkCompositeSink:
    "(event/CompositeSink " & $v.compositeSinks.len & ")"
  of vkType:
    if v.typeName.len == 0 and v.isTypeAlias:
      # An anonymous alias — `(| A B)` written as a value — has no name to
      # print, and `(type )` says nothing. Print what it expands to, which is
      # also the form that reads back.
      v.typeAliasExpr.print()
    else:
      "(type " & v.typeName & ")"
  of vkProtocol:
    "(protocol " & v.protocolName & ")"
  of vkProtocolMessage:
    "(message " & v.protocolMessageName & ")"
  of vkEnumVariant:
    v.enumVariantEnum.typeName & "/" & v.enumVariantName
