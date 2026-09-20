## Included by vm.nim. Public data constructors/checks expose neither grants nor
## contexts. Every receiving boundary validates catalog and metadata again.

proc capabilityApiScope(call: ptr NativeCall): Scope =
  if call == nil or call[].dispatchScope == nil:
    raise newException(GeneError, "capability API requires an application call")
  call[].dispatchScope

proc capabilityNamed(call: ptr NativeCall, key: string, fallback: Value): Value =
  if call != nil:
    for i, name in call[].namedNames:
      if name == key:
        return retainedCopy(call[].namedValues[i])
  fallback

proc capabilityNamedOnly(call: ptr NativeCall, allowed: openArray[string]) =
  if call != nil:
    for name in call[].namedNames:
      if name notin allowed:
        raise newException(GeneError, "unknown capability API argument: " & name)

proc capabilityApiSource(call: ptr NativeCall, kind: CapabilitySourceKind):
    CapabilitySourceContext =
  capabilityNamedOnly(call, ["base", "source"])
  let base = capabilityNamed(call, "base", newStr(""))
  let name = capabilityNamed(call, "source", newStr("<capabilities>"))
  requireStr("capabilities ^base", base)
  requireStr("capabilities ^source", name)
  CapabilitySourceContext(kind: kind, baseDirectory: base.strVal, name: name.strVal)

proc builderCapabilityScalar(value: Value): CapabilityScalar =
  case value.kind
  of vkString: capabilityText(value.strVal)
  of vkBool: capabilityBoolean(value.boolVal)
  of vkInt:
    if not value.intFitsInt64:
      raise newException(GeneError, "capability integer exceeds signed 64-bit range")
    capabilityInteger(value.intVal)
  of vkCapability:
    case value.capabilityForm
    of cvfAny: capabilityAny()
    of cvfPattern: capabilityPattern(value.capabilityPatternValue)
    else:
      raise newException(GeneError, "not a scalar capability builder value")
  else:
    raise newException(GeneError, "capability builder expects scalar values")

proc builderCapabilityProperty(value: Value): CapabilityPropertyValue =
  if value.kind == vkList:
    var items: seq[CapabilityScalar]
    for item in value.listItems:
      items.add builderCapabilityScalar(item)
    capabilityValues(items)
  else:
    capabilityValue(builderCapabilityScalar(value))

proc capabilityRowArgument(name: string, value: Value): CapabilitySpecRow =
  if value.kind != vkCapability or value.capabilityForm != cvfRow:
    raise newException(GeneError, name & " expects an immutable CapabilitySpecRow")
  value.capabilityRowValue

proc biCapabilityParse(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("capabilities/parse", args)
  requireStr("capabilities/parse text", args[0])
  let source = capabilityApiSource(call, csoSource)
  let app = capabilityApiScope(call).application()
  try:
    newCapabilityRowValue(app.capabilityRegistry.normalizeCapabilityRow(
      readCapabilityLiteral(args[0].strVal, cuRequest, source), cuRequest))
  except CapabilityLiteralError as error:
    raiseCapabilityGeneError(call[].dispatchScope, "CapabilityTypeError", error.msg)
  except CapabilityError as error:
    raiseCapabilityGeneError(call[].dispatchScope, "CapabilityTypeError", error.msg)

proc biCapabilityBuild(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("capabilities/build", args)
  if args[0].kind != vkList:
    raise newException(GeneError, "capabilities/build expects a list of entry descriptions")
  let source = capabilityApiSource(call, csoBuilder)
  let app = capabilityApiScope(call).application()
  var entries: seq[CapabilityEntryLiteral]
  for value in args[0].listItems:
    if value.kind != vkCapability or value.capabilityForm != cvfBuilderEntry:
      raise newException(GeneError,
        "capabilities/build requires entries made by capabilities/entry")
    entries.add value.capabilityEntryValue
  try:
    newCapabilityRowValue(app.capabilityRegistry.normalizeCapabilityRow(
      buildCapabilityLiteral(entries, cuRequest, source), cuRequest))
  except CapabilityLiteralError as error:
    raiseCapabilityGeneError(call[].dispatchScope, "CapabilityTypeError", error.msg)
  except CapabilityError as error:
    raiseCapabilityGeneError(call[].dispatchScope, "CapabilityTypeError", error.msg)

proc biCapabilityEntry(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  capabilityNamedOnly(call, [])
  if args.len notin [3, 4]:
    raise newException(GeneError,
      "capabilities/entry expects name, body, property pairs and optional Bool")
  requireStr("capability entry name", args[0])
  if args[1].kind != vkList or args[2].kind != vkList:
    raise newException(GeneError, "capability entry body and property pairs must be lists")
  var entry = CapabilityEntryLiteral(name: args[0].strVal)
  for value in args[1].listItems:
    entry.body.add builderCapabilityScalar(value)
  for pair in args[2].listItems:
    if pair.kind != vkList or pair.listItems.len != 2:
      raise newException(GeneError, "capability property requires a name/value pair")
    requireStr("capability property name", pair.listItems[0])
    entry.properties.add CapabilityPropertyLiteral(name: pair.listItems[0].strVal,
      value: builderCapabilityProperty(pair.listItems[1]))
  if args.len == 4:
    if args[3].kind != vkBool:
      raise newException(GeneError, "optional must be Bool")
    entry.hasOptional = true
    entry.optional = args[3].boolVal
  try:
    newCapabilityEntryValue(entry)
  except CapabilityLiteralError as error:
    raiseCapabilityGeneError(capabilityApiScope(call), "CapabilityTypeError", error.msg)

proc biCapabilityPattern(args: openArray[Value]): Value {.nimcall.} =
  requireOne("capabilities/pattern", args)
  requireStr("capabilities/pattern", args[0])
  newCapabilityPatternValue(args[0].strVal)

proc biCapabilityAny(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "capabilities/any takes no arguments")
  newCapabilityAnyValue()

proc immutableStrings(values: openArray[string]): Value =
  var items: seq[Value]
  for value in values:
    items.add newStr(value)
  newList(items, immutable = true)

proc biCapabilityCheckRequirements(args: openArray[Value],
    call: ptr NativeCall): Value {.nimcall.} =
  requireOne("capabilities/check_requirements", args)
  capabilityNamedOnly(call, [])
  let row = capabilityRowArgument("check_requirements", args[0])
  let active = activeCapabilitiesForCall(call)
  try:
    let report = active.app.capabilityRegistry.checkCapabilityRequirements(active.context, row)
    var entries: seq[Value]
    for entry in report.entries:
      var properties = initPropTable()
      properties["optional"] = newBool(entry.optional)
      properties["authored_index"] = newInt(entry.authoredIndex)
      properties["authority_row"] = newInt(entry.authorityRow)
      properties["status"] = newStr(
        if entry.optional:
          case entry.status
          of caMatched: "full_match"
          of caUnmatched: "no_full_match"
          of caCannotProve: "proof_incomplete"
          of caProviderFailure: "provider_failure"
        else:
          case entry.status
          of caMatched: "matched"
          of caUnmatched: "unmatched"
          of caCannotProve: "cannot_prove"
          of caProviderFailure: "provider_failure")
      if entry.status == caProviderFailure:
        properties["failure_scope"] = newStr(
          if entry.failureScope == cfsShared: "shared" else: "entry")
      properties["failed_fields"] = immutableStrings(entry.failedFields)
      properties["unproved_fields"] = immutableStrings(entry.unprovedFields)
      entries.add newMap(properties, immutable = true)
    var properties = initPropTable()
    properties["admitted"] = newBool(report.admitted)
    properties["entries"] = newList(entries, immutable = true)
    newMap(properties, immutable = true)
  except CapabilityError as error:
    raiseCapabilityGeneError(call[].dispatchScope, "CapabilityTypeError", error.msg)

proc operationDescription(operation: CapabilityOperation): Value =
  var properties, facts = initPropTable()
  properties["capability"] = newStr(operation.capabilityType.name)
  properties["operation"] = newStr(operation.operationKind)
  var body: seq[Value]
  for value in operation.operationBody:
    case value.kind
    of cskText: body.add newStr(value.text)
    of cskInteger: body.add newInt(value.integer)
    of cskBoolean: body.add newBool(value.boolean)
    else: raise newException(GeneError, "invalid concrete operation scalar")
  properties["body"] = newList(body, immutable = true)
  for field in operation.operationFields:
    facts[field.name] = case field.value.kind
      of cskText: newStr(field.value.text)
      of cskInteger: newInt(field.value.integer)
      of cskBoolean: newBool(field.value.boolean)
      else: raise newException(GeneError, "invalid concrete operation fact")
  properties["facts"] = newMap(facts, immutable = true)
  newMap(properties, immutable = true)

proc concreteCapabilityScalar(value: Value): CapabilityScalar =
  if value.kind notin {vkString, vkInt, vkBool}:
    raise newException(GeneError, "operation facts require real scalar values")
  builderCapabilityScalar(value)

proc biCapabilityCheckOperation(args: openArray[Value],
    call: ptr NativeCall): Value {.nimcall.} =
  requireOne("capabilities/check_operation", args)
  capabilityNamedOnly(call, [])
  if args[0].kind != vkMap:
    raise newException(GeneError, "check_operation expects an operation description")
  let description = args[0].mapEntries
  for name, _ in description:
    if name notin ["capability", "operation", "body", "facts"]:
      raise newException(GeneError, "unknown operation description field: " & name)
  let name = description.getOrDefault("capability", VOID)
  let kind = description.getOrDefault("operation", VOID)
  requireStr("operation capability", name)
  requireStr("operation kind", kind)
  var body: seq[CapabilityScalar]
  let bodyValue = description.getOrDefault("body", newList())
  if bodyValue.kind != vkList:
    raise newException(GeneError, "operation body must be a list")
  for value in bodyValue.listItems:
    body.add concreteCapabilityScalar(value)
  let fieldsValue = description.getOrDefault("facts", newMap())
  if fieldsValue.kind != vkMap:
    raise newException(GeneError, "operation facts must be a map")
  var fields: seq[CapabilityOperationField]
  for key, value in fieldsValue.mapEntries:
    fields.add CapabilityOperationField(name: key, value: concreteCapabilityScalar(value))
  let active = activeCapabilitiesForCall(call)
  try:
    let operation = newCapabilityOperation(active.app.capabilityRegistry.capabilityType(name.strVal),
      kind.strVal, body, fields)
    let decision = active.app.capabilityRegistry.checkCapabilityOperation(active.context, operation)
    var resultFields = initPropTable()
    resultFields["allowed"] = newBool(decision.allowed)
    resultFields["kind"] = newStr(case decision.kind
      of cdAllow: "allow"
      of cdDeny: "deny"
      of cdProviderFailure: "provider_failure")
    resultFields["reason"] = newStr(decision.reason)
    resultFields["authority_row"] = newInt(decision.authorityRow)
    newMap(resultFields, immutable = true)
  except CapabilityError as error:
    raiseCapabilityGeneError(call[].dispatchScope, "CapabilityTypeError", error.msg)

proc biPrepareCapabilityHttp(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "http_client/prepare expects method and URL")
  capabilityNamedOnly(call, ["headers", "body"])
  requireStr("HTTP method", args[0])
  requireStr("HTTP URL", args[1])
  let body = capabilityNamed(call, "body", newStr(""))
  requireStr("HTTP body", body)
  let headers = capabilityNamed(call, "headers", newList())
  var headerValues: seq[string]
  case headers.kind
  of vkList:
    for header in headers.listItems:
      requireStr("HTTP header", header)
      headerValues.add header.strVal
  of vkMap:
    for key, value in headers.mapEntries:
      requireStr("HTTP header value", value)
      headerValues.add key & ": " & value.strVal
  else:
    raise newException(GeneError, "HTTP headers require a list or map")
  try:
    newPreparedCapabilityValue("PreparedHttpRequest",
      prepareCapabilityHttpRequest(args[0].strVal, args[1].strVal, headerValues, body.strVal))
  except CapabilityError as error:
    raiseCapabilityGeneError(capabilityApiScope(call), "CapabilityTypeError", error.msg)

proc biDescribeCapabilityHttp(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("http_client/describe_operation", args)
  if args[0].kind != vkCapability or args[0].capabilityForm != cvfPrepared or
      not (args[0].capabilityPreparedValue of PreparedCapabilityHttpRequest):
    raise newException(GeneError, "describe_operation expects a prepared HTTP request")
  let app = capabilityApiScope(call).application()
  operationDescription(HttpCapabilityProvider(app.hostCapabilityProvider).describeHttpOperation(
    PreparedCapabilityHttpRequest(args[0].capabilityPreparedValue)))

proc registerCapabilityNamespace(root: Scope) =
  let scope = newScope(root)
  scope.define("parse", builtinNativeCallFn("capabilities/parse", biCapabilityParse))
  scope.define("build", builtinNativeCallFn("capabilities/build", biCapabilityBuild))
  scope.define("entry", builtinNativeCallFn("capabilities/entry", biCapabilityEntry,
                                         acceptsNamed = false))
  scope.define("pattern", builtinNativeFn("capabilities/pattern", biCapabilityPattern))
  scope.define("any", builtinNativeFn("capabilities/any", biCapabilityAny))
  scope.define("check_requirements", builtinNativeCallFn("capabilities/check_requirements",
    biCapabilityCheckRequirements, acceptsNamed = false))
  scope.define("check_operation", builtinNativeCallFn("capabilities/check_operation",
    biCapabilityCheckOperation, acceptsNamed = false))
  root.define("capabilities", newNamespace("capabilities", scope))
