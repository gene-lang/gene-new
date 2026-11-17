## Throwable classes and branch tests shared across generated ES modules.
## Included by web.nim.
##
## A Gene Throwable on web is one of:
## - an instance of a class whose static `$gene_branch` is "error" or "fault":
##   user types under `Error` or `Fault`, and the built-in classes below;
## - a RuntimeFault (or other built-in Fault) raised as Gene node data.
## The branch decides `catch Error` and `catch Fault`, as the parent chain does
## on the VM. A thrown value that is neither is a host throw: the catch prologue
## wraps it as a HostError, or a HostFault for stack or memory exhaustion.
## Every built-in class lives in one registry on `globalThis`, so `instanceof`
## holds across the modules of an application.

proc emitErrorRuntime(emitter: var WebEmitter) =
  let any = if emitter.typescript: ": any" else: ""
  let array = if emitter.typescript: ": any[]" else: ""
  let str = if emitter.typescript: ": string" else: ""
  let branchType = if emitter.typescript: ": string | null" else: ""
  let never = if emitter.typescript: ": never" else: ""
  let global = if emitter.typescript: "(globalThis as any)" else: "globalThis"
  emitter.line("const $gene_error_key = Symbol.for(\"gene.error.classes.v2\");")
  emitter.line("const $gene_errors" & any & " = " & global & "[$gene_error_key] ?? (() => { const state" & any & " = {}; Object.defineProperty(globalThis, $gene_error_key, { value: state }); return state; })();")
  emitter.line("const $gene_error_message = Symbol.for(\"gene.Error.message\");")
  # A built-in Throwable: fields as given, `_msg` also as the JS message.
  proc builtinClass(emitter: var WebEmitter, name, key, base, branch, jsName: string,
                    runtime = false) =
    let ctorParams = "(fields" & any & " = {}, _body" & array & " = [], _immutable = false, _constructing = false)"
    emitter.line("const " & name & any & " = $gene_errors." & key & " ?? ($gene_errors." & key &
      " = class extends " & base & " { static $gene_branch = \"" & branch & "\";" &
      (if runtime: " static $gene_runtime = true;" else: "") &
      " constructor" & ctorParams & " { super(fields?._msg ?? \"\"); Object.assign(this, fields); this.name = \"" & jsName & "\"; } });")
  emitter.builtinClass("$gene_contract_type", "contractViolation", "globalThis.Error", "fault", "ContractViolation")
  emitter.builtinClass("$gene_type_fault", "typeFault", "globalThis.TypeError", "fault", "TypeFault")
  emitter.builtinClass("$gene_host_error", "hostError", "globalThis.Error", "error", "HostError")
  emitter.builtinClass("$gene_host_fault", "hostFault", "globalThis.Error", "fault", "HostFault")
  # A message-only runtime failure from a generated helper: a RuntimeFault,
  # kept a JS TypeError/RangeError/Error so host tooling still reads it.
  for (name, key, base) in [("$gene_runtime_type_error", "runtimeTypeError", "globalThis.TypeError"),
                            ("$gene_runtime_range_error", "runtimeRangeError", "globalThis.RangeError"),
                            ("$gene_runtime_error", "runtimeError", "globalThis.Error")]:
    emitter.line("const " & name & any & " = $gene_errors." & key & " ?? ($gene_errors." & key &
      " = class extends " & base & " { static $gene_branch = \"fault\"; static $gene_runtime = true; constructor(message" & str & ") { super(message); Object.assign(this, { _msg: message }); this.name = \"RuntimeFault\"; } });")
  emitter.line("const $gene_node_faults = new Set([\"RuntimeFault\", \"MessageFault\", \"CallKindFault\", \"AssertionFault\", \"RuntimeLaneFault\", \"OrderFault\", \"RefFault\", \"ReplyAlreadySent\", \"ValueProtocolPending\", \"ValueNotHashable\", \"ValueOperationReentry\"]);")
  emitter.line("function $gene_branch_of(value" & any & ")" & branchType & " {")
  inc emitter.indent
  emitter.line("if (value == null || (typeof value !== \"object\" && typeof value !== \"function\")) return null;")
  emitter.line("const branch = value.constructor?.$gene_branch;")
  emitter.line("if (branch === \"error\" || branch === \"fault\") return branch;")
  emitter.line("if (value[Symbol.for(\"gene.panic\")] === true) return \"fault\";")
  emitter.line("if (value[Symbol.for(\"gene.node\")] === true && typeof value.head === \"symbol\" && $gene_node_faults.has(Symbol.keyFor(value.head) ?? \"\")) return \"fault\";")
  emitter.line("return null;")
  dec emitter.indent
  emitter.line("}")
  emitter.line("function $gene_is_error(value" & any & ") { return $gene_branch_of(value) === \"error\"; }")
  emitter.line("function $gene_host_text(value" & any & ")" & str & " { if (value instanceof globalThis.Error) return String(value.message); try { return String(value); } catch (_) { return \"host value\"; } }")
  emitter.line("function $gene_wrap_thrown(value" & any & ")" & any & " {")
  inc emitter.indent
  emitter.line("if ($gene_branch_of(value) !== null) return value;")
  emitter.line("const text = $gene_host_text(value);")
  emitter.line("const exhausted = (value instanceof globalThis.RangeError && /call stack|allocation failed|out of memory/i.test(text)) || (value?.name === \"InternalError\" && /recursion|memory/i.test(text));")
  emitter.line("return exhausted ? new $gene_host_fault({ _msg: text, value }) : new $gene_host_error({ _msg: text, value });")
  dec emitter.indent
  emitter.line("}")
  emitter.line("function $gene_error_property(value" & any & ", key" & str & ")" & any & " { return value?.[Symbol.for(\"gene.node\")] === true ? value.props[key] : value?.[key]; }")
  emitter.line("function $gene_default_error_message(" & (if emitter.typescript: "this: any" else: "") & ")" & str & " { const stored = $gene_error_property(this, \"_msg\"); if (typeof stored === \"string\") return stored; if (stored != null) return $gene_type_error(\"message return\", \"Str\", stored); return this instanceof globalThis.Error ? String(this.message) : \"\"; }")
  emitter.line("function $gene_error_message_default(_check" & any & " = null) { return $gene_default_error_message; }")
  emitter.line("function $gene_admit_error(value" & any & ")" & any & " { if ($gene_branch_of(value) === null) return $gene_type_error(\"Error admission\", \"value of an Error or Fault type\", value); return value; }")
  emitter.line("function $gene_error_text(value" & any & ")" & str & " { const formatter = typeof value?.[$gene_error_message] === \"function\" ? value[$gene_error_message] : $gene_default_error_message; const text = formatter.call(value); if (typeof text !== \"string\") return $gene_type_error(\"message return\", \"Str\", text); return text; }")
  emitter.line("function $gene_error_contract(value" & any & ", checks" & array & " | null, where" & str & ")" & any & " {")
  # The nullable annotation above must disappear wholly in JavaScript output.
  if not emitter.typescript:
    emitter.lines[^1] = emitter.lines[^1].replace("checks | null", "checks")
  inc emitter.indent
  emitter.line("if (value?.[Symbol.for(\"gene.cancellation\")]) return value;")
  # Rows check Errors only: a Fault passes through unchanged.
  emitter.line("const error = $gene_wrap_thrown(value); if (checks === null || $gene_branch_of(error) !== \"error\") return error;")
  emitter.line("for (const check of checks) { try { check(error, \"error contract\"); } catch (_) { continue; } return error; }")
  emitter.line("return new $gene_contract_type({ _msg: \"function '\" + where + \"' raised an undeclared error\", where, expected: checks.map(check => check.name), actual: error?.constructor?.name ?? \"Error\", _cause: error });")
  dec emitter.indent
  emitter.line("}")
  emitter.line("function $gene_raise_type_error(where" & str & ", expected" & str & ", value" & any & ")" & never & " { const message = `${where} expected ${expected}, got ${typeof value}`; throw new $gene_type_fault({ _msg: message, where, expected, actual: typeof value, actual_value: value }); }")
  emitter.line()
