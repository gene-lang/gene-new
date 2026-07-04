## Canonical printer (design Section 18).
##
## Produces deterministic Gene surface text. Props and meta are emitted in
## stored (source) order. Immutable containers use their `#`-prefix. The
## output re-reads to a structurally equal value (AST-level round-trip).

import std/[strutils, unicode, tables]
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
  result = "0x"
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

proc printProps(sb: var string, props: PropTable, sigil: string) =
  for k, val in props:
    sb.add ' '
    if val.kind == vkBool and val.boolVal:
      sb.add sigil & sigil & k          # ^^flag / @@flag
    else:
      sb.add sigil & k
      sb.add ' '
      sb.add print(val)

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
    var sb = if v.nodeImmutable: "#(" else: "("
    sb.add print(v.head)
    printProps(sb, v.meta, "@")
    printProps(sb, v.props, "^")
    for it in v.body:
      sb.add ' '
      sb.add print(it)
    sb.add ')'
    sb
  # Callables are runtime values, not literals; rendered for display only.
  of vkFunction:
    if v.fnName.len > 0: "(fn " & v.fnName & ")" else: "(fn)"
  of vkNativeFn:
    "(native-fn " & v.nativeFnName & ")"
  of vkNamespace:
    "(ns " & v.nsName & ")"
  of vkModule:
    "(mod " & v.moduleName & ")"
  of vkEnv:
    "(env)"
  of vkCell:
    "(cell)"
  of vkAtomicCell:
    "(atomic-cell)"
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
      if v.cPtrOwned: "c-owned-ptr"
      elif v.cPtrMutable: "c-ptr"
      else: "c-const-ptr"
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
    "(capability " & v.capabilityName & ")"
  of vkFfiLoad:
    "(ffi-load)"
  of vkFfiLibrary:
    if v.ffiLibraryClosed:
      "(ffi-library closed)"
    else:
      "(ffi-library)"
  of vkFfiCallable:
    "(ffi-callable " & v.ffiCallableName & ")"
  of vkType:
    "(type " & v.typeName & ")"
  of vkProtocol:
    "(protocol " & v.protocolName & ")"
  of vkProtocolMessage:
    "(message " & v.protocolMessageName & ")"
