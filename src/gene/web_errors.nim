## Error evidence shared across generated ES modules. Included by web.nim.

proc emitErrorRuntime(emitter: var WebEmitter) =
  let any = if emitter.typescript: ": any" else: ""
  let array = if emitter.typescript: ": any[]" else: ""
  let str = if emitter.typescript: ": string" else: ""
  let never = if emitter.typescript: ": never" else: ""
  let global = if emitter.typescript: "(globalThis as any)" else: "globalThis"
  emitter.line("const $gene_error_key = Symbol.for(\"gene.error.evidence.v1\");")
  emitter.line("const $gene_errors" & any & " = " & global & "[$gene_error_key] ?? (() => { const state = { evidence: new WeakMap(), defaults: new WeakSet() }; Object.defineProperty(globalThis, $gene_error_key, { value: state }); return state; })();")
  emitter.line("const $gene_error_message = Symbol.for(\"gene.Error.message\");")
  emitter.line("const $gene_contract_type = $gene_errors.contractType ?? ($gene_errors.contractType = class extends globalThis.Error { constructor(fields" & any & ") { super(fields.message); Object.assign(this, fields); this.name = \"ErrorContractViolation\"; } });")
  emitter.line("class $gene_user_type_error extends globalThis.TypeError { constructor(fields" & any & ", _body" & array & " = [], _immutable = false, _constructing = false) { super(fields.message); Object.assign(this, fields); this.name = \"TypeError\"; } }")
  emitter.line("function $gene_error_property(value" & any & ", key" & str & ")" & any & " { return value?.[Symbol.for(\"gene.node\")] === true ? value.props[key] : value?.[key]; }")
  emitter.line("function $gene_default_error_message(" & (if emitter.typescript: "this: any" else: "") & ")" & str & " { const message = $gene_error_property(this, \"message\"); if (typeof message !== \"string\") return $gene_type_error(\"Error:message return\", \"Str\", message); return message; }")
  emitter.line("$gene_errors.defaults.add($gene_default_error_message);")
  emitter.line("function $gene_error_message_default(_check" & any & " = null) { return $gene_default_error_message; }")
  emitter.line("function $gene_generated_error(value" & any & ", kind" & str & ")" & any & " { $gene_errors.evidence.set(value, { kind, formatter: $gene_default_error_message }); return value; }")
  emitter.line("function $gene_is_error(value" & any & ") { return value != null && (typeof value === \"object\" || typeof value === \"function\") && ($gene_errors.evidence.has(value) || value instanceof globalThis.Error || typeof value[$gene_error_message] === \"function\" || (value[Symbol.for(\"gene.node\")] === true && value.head === Symbol.for(\"RuntimeError\"))); }")
  emitter.line("function $gene_admit_error(value" & any & ")" & any & " {")
  inc emitter.indent
  emitter.line("if (!$gene_is_error(value)) return $gene_type_error(\"Error admission\", \"value implementing Error\", value);")
  emitter.line("if ($gene_errors.evidence.has(value)) return value;")
  emitter.line("const formatter = typeof value[$gene_error_message] === \"function\" ? value[$gene_error_message] : $gene_default_error_message;")
  emitter.line("if ($gene_errors.defaults.has(formatter) && typeof $gene_error_property(value, \"message\") !== \"string\") return $gene_type_error(\"Error admission message\", \"present Str property\", $gene_error_property(value, \"message\"));")
  emitter.line("$gene_errors.evidence.set(value, { kind: \"ordinary\", formatter }); return value;")
  dec emitter.indent
  emitter.line("}")
  emitter.line("function $gene_error_text(value" & any & ")" & str & " { $gene_admit_error(value); const text = $gene_errors.evidence.get(value).formatter.call(value); if (typeof text !== \"string\") return $gene_type_error(\"Error:message return\", \"Str\", text); return text; }")
  emitter.line("function $gene_error_contract(value" & any & ", checks" & array & " | null, where" & str & ")" & any & " {")
  # The nullable annotation above must disappear wholly in JavaScript output.
  if not emitter.typescript:
    emitter.lines[^1] = emitter.lines[^1].replace("checks | null", "checks")
  inc emitter.indent
  emitter.line("if (value?.[Symbol.for(\"gene.cancellation\")] || value?.[Symbol.for(\"gene.panic\")]) return value;")
  emitter.line("$gene_admit_error(value); if (checks === null || $gene_errors.evidence.get(value).kind !== \"ordinary\") return value;")
  emitter.line("for (const check of checks) { try { check(value, \"error contract\"); } catch (_) { continue; } return value; }")
  emitter.line("const failure" & any & " = new $gene_contract_type({ message: \"function '\" + where + \"' raised an undeclared error\", where, expected: checks.map(check => check.name), actual: value?.constructor?.name ?? \"Error\", cause: value });")
  emitter.line("return $gene_generated_error(failure, \"contract\");")
  dec emitter.indent
  emitter.line("}")
  emitter.line("function $gene_raise_type_error(where" & str & ", expected" & str & ", value" & any & ")" & never & " { const failure" & any & " = new globalThis.TypeError(`${where} expected ${expected}, got ${typeof value}`); failure.where = where; failure.expected = expected; failure.actual = typeof value; failure.actual_value = value; throw $gene_generated_error(failure, \"type\"); }")
  emitter.line()
