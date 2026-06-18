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
  of vkType:
    "(type " & v.typeName & ")"
  of vkProtocol:
    "(protocol " & v.protocolName & ")"
  of vkProtocolMessage:
    "(message " & v.protocolMessageName & ")"
