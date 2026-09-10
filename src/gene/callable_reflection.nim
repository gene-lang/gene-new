## Inert descriptions of existing invocation contracts. This module never
## calls Gene code, evaluates defaults, or retains a target/environment in its
## output. The VM supplies static type lookup and already selected contracts.
import std/[algorithm, sets, strutils]
import ./[compiler, gir, types]

type ReflectionTypeLookup* = proc(expr: Value, scope: Scope): Value {.nimcall.}

type ReflectionOptions* = object
  category*, origin*: string
  abstractSelf*, skipReceiver*, requirement*: bool
  constructedType*: Value
  prototype*: FunctionProto

proc symbol(value: Value, name: string): bool =
  value.kind == vkSymbol and value.symVal == name

proc safeAnnotation(expr: Value, scope: Scope, lookup: ReflectionTypeLookup,
                    depth = 0, abstractSelf = false, unresolved: seq[string] = @[]): Value =
  ## Unknown/dynamic annotations become Void internally, never executable
  ## syntax in the public description. Copy only supported type structure,
  ## dropping metadata and owning borrowed nominal references.
  if depth > 64: return VOID
  if expr.isTypeAlias:
    if expr.isOpaqueAbiAnnotation: return VOID
    return safeAnnotation(expr.typeAliasExpr, scope, lookup, depth + 1, abstractSelf, unresolved)
  case expr.kind
  of vkType, vkProtocol: return expr
  of vkSymbol:
    if expr.symVal in unresolved: return VOID
    if abstractSelf and expr.symVal == "Self": return expr
    if expr.symVal.endsWith("?") and expr.symVal.len > 1:
      let base = safeAnnotation(newSym(expr.symVal[0 .. ^2]), scope, lookup, depth + 1, abstractSelf, unresolved)
      if base.kind == vkVoid: return VOID
      return newNode(newSym("?"), body = @[base], immutable = true)
    let resolved = lookup(expr, scope)
    if resolved.kind in {vkType, vkProtocol}:
      return safeAnnotation(resolved, scope, lookup, depth + 1, abstractSelf, unresolved)
    if resolved.kind == vkSymbol: return resolved
  of vkNode:
    if expr.head.symbol("path"):
      let resolved = lookup(expr, scope)
      if resolved.kind in {vkType, vkProtocol, vkSymbol}:
        return safeAnnotation(resolved, scope, lookup, depth + 1, abstractSelf, unresolved)
      return VOID
    if expr.head.kind != vkSymbol or expr.head.symVal notin
        ["?", "|", "&", "...", "List", "Buffer", "Task", "Stream",
         "Channel", "Callable", "Fn"]:
      return VOID
    var body: seq[Value]
    for item in expr.body:
      let safe = safeAnnotation(item, scope, lookup, depth + 1, abstractSelf, unresolved)
      if safe.kind == vkVoid: return VOID
      body.add safe
    var props = initPropTable()
    for key, item in expr.props:
      if key notin ["named", "errors"]: return VOID
      let safe = safeAnnotation(item, scope, lookup, depth + 1, abstractSelf, unresolved)
      if safe.kind == vkVoid: return VOID
      props[key] = safe
    return newNode(expr.head, props = props, body = body, immutable = true)
  of vkList:
    var items: seq[Value]
    for item in expr.listItems:
      let safe = safeAnnotation(item, scope, lookup, depth + 1, abstractSelf, unresolved)
      if safe.kind == vkVoid: return VOID
      items.add safe
    return newList(items, immutable = true)
  of vkMap:
    var props = initPropTable()
    for key, item in expr.mapEntries:
      let safe = safeAnnotation(item, scope, lookup, depth + 1, abstractSelf, unresolved)
      if safe.kind == vkVoid: return VOID
      props[key] = safe
    return newMap(props, immutable = true)
  else: discard
  VOID

proc parameter(name, local: string, typ: Value, required, hasDefault: bool,
               scope: Scope, lookup: ReflectionTypeLookup, abstractSelf = false,
               unresolved: seq[string] = @[]): Value =
  var props = initPropTable()
  props["name"] = if name.len == 0: NIL else: newStr(name)
  props["local"] = if local.len == 0: NIL else: newStr(local)
  props["required"] = newBool(required)
  props["has_default"] = newBool(hasDefault)
  let safe = safeAnnotation(if typ.kind == vkNil: newSym("Any") else: typ,
                            scope, lookup, abstractSelf = abstractSelf, unresolved = unresolved)
  props["type_known"] = newBool(safe.kind != vkVoid)
  props["type"] = if safe.kind == vkVoid: NIL else: safe
  newMap(props, immutable = true)

proc reflectedRestType*(value: Value): Value =
  ## Same repeated-element spelling used by checked Callable invocation.
  if value.kind == vkSymbol and value.symVal.len > 3 and value.symVal.endsWith("..."):
    return newSym(value.symVal[0 ..< value.symVal.len - 3])
  if value.kind == vkNode and value.head.symbol("...") and value.body.len == 1:
    return value.body[0]
  NIL

proc describeCallable*(target: Value, lookup: ReflectionTypeLookup,
                        options = ReflectionOptions()): Value =
  var props = initPropTable()
  props["format"] = newInt(1)
  props["shape_known"] = FALSE
  props["completeness"] = newSym("unknown")
  props["origin"] = newSym("unknown")
  props["category"] = newSym("unsupported")
  props["name"] = NIL
  props["source"] = NIL
  props["doc"] = NIL
  # Compiler contract identity/version are descriptive, never runtime handles.
  # No cache is maintained: names cannot accidentally select a replaced target.
  props["contract_identity"] = NIL
  props["contract_version"] = NIL
  props["execution"] = newSym("unknown")
  props["abstract_self"] = newBool(options.abstractSelf)
  var scope: Scope
  var positional, named: seq[Value]
  var rest = NIL
  var resultType = VOID
  var errors: seq[Value]
  var errorsChecked = false
  var minimum = 0
  case target.kind
  of vkFunction:
    props["category"] = newSym(if target.isSyntaxFn: "fexpr" else: "function")
    if target.isSyntaxFn or target.fnCode == nil or not (target.fnCode of FunctionProto):
      return newNode(newSym("SignatureDescription"), props = props, immutable = true)
    let proto = if options.prototype != nil: options.prototype else: FunctionProto(target.fnCode)
    scope = target.fnScope
    var typeParameters: seq[Value]
    for name in proto.typeParams: typeParameters.add newStr(name)
    props["type_parameters"] = newList(typeParameters, immutable = true)
    props["origin"] = newSym("declared")
    props["name"] = newStr(target.fnName)
    props["execution"] = newSym(if proto.isGenerator: "generator" else: "ordinary")
    if options.requirement:
      # A protocol's default body does not select the eventual impl kind.
      props["execution"] = newSym("unknown")
    var source = initPropTable()
    source["name"] = newStr(proto.sourceLoc.sourceName)
    source["line"] = newInt(proto.sourceLoc.line)
    source["column"] = newInt(proto.sourceLoc.col)
    props["source"] = newMap(source, immutable = true)
    for i, key in proto.declMetaKeys:
      if key == "doc" and i < proto.declMetaValues.len and
          proto.declMetaValues[i].kind == vkString:
        props["doc"] = proto.declMetaValues[i]
    if proto.errorSummary != nil:
      props["contract_identity"] = newStr(proto.errorSummary.identity)
      props["contract_version"] = newStr(proto.errorSummary.version)
    let start = if options.skipReceiver: 1 else: 0
    minimum = max(0, proto.requiredPositional - start)
    for i in start ..< proto.params.len:
      let name = proto.params[i]
      let typ = if i < proto.paramTypes.len: proto.paramTypes[i] else: NIL
      positional.add parameter(name, name, typ, i < proto.requiredPositional,
        i < proto.paramDefaults.len and proto.paramDefaults[i].defaultChunk != nil,
        scope, lookup, options.abstractSelf, proto.typeParams)
    for p in proto.namedParams:
      named.add parameter(p.arg, p.local, p.typeExpr, not p.defaultValue.optional,
        p.defaultValue.defaultChunk != nil, scope, lookup, options.abstractSelf, proto.typeParams)
    if proto.restParam.len > 0:
      rest = parameter(proto.restParam, proto.restParam, proto.restType, false, false,
                       scope, lookup, options.abstractSelf, proto.typeParams)
    if proto.hasReturnType:
      resultType = safeAnnotation(proto.returnType, scope, lookup,
        abstractSelf = options.abstractSelf, unresolved = proto.typeParams)
    if options.constructedType.kind == vkType:
      resultType = options.constructedType
      props["construction"] = newSym("new")
    errorsChecked = target.fnChecksErrors
    errors = target.fnErrorTypes
    if options.requirement and proto.signatureErrorExprs.len > 0:
      errors = proto.signatureErrorExprs
  of vkCallableView:
    props["category"] = newSym("checked_view")
    props["origin"] = newSym("checked_view")
    scope = target.callableViewScope
    let signature = target.callableViewSignature
    for typ in signature.body[0].listItems:
      let element = reflectedRestType(typ)
      if element.kind == vkNil:
        positional.add parameter("", "", typ, true, false, scope, lookup)
      else:
        rest = parameter("", "", element, false, false, scope, lookup)
    minimum = positional.len
    if signature.props.hasKey("named"):
      var names: seq[string]
      for key, _ in signature.props["named"].mapEntries: names.add key
      names.sort()
      for key in names:
        let typ = signature.props["named"].mapEntries[key]
        named.add parameter(key, "", typ, not typeExprAdmitsNil(typ), false, scope, lookup)
    resultType = safeAnnotation(signature.body[1], scope, lookup)
    errorsChecked = signature.props.hasKey("errors")
    if errorsChecked: errors = signature.props["errors"].listItems
  of vkFfiCallable:
    props["category"] = newSym("native")
    props["origin"] = newSym("native_declared")
    props["name"] = newStr(target.ffiCallableName)
    for typ in target.ffiCallableParamTypes:
      positional.add parameter("", "", typ, true, false, nil, lookup)
    minimum = positional.len
    resultType = safeAnnotation(target.ffiCallableReturnType, nil, lookup)
  of vkNativeFn: props["category"] = newSym("native")
  of vkProtocolMessage: props["category"] = newSym("message")
  of vkType:
    props["category"] = newSym("type")
    props["name"] = newStr(target.typeName)
    props["construction"] = newSym("data")
    if not target.isEnumType and not target.isTypeAlias and
        not target.isNativeWrapperType and not target.typeContractPending and
        target.typeNativeCtor.kind == vkNil:
      props["origin"] = newSym("schema")
      scope = target.typeScope
      for field in target.typeBodyFields:
        let p = parameter("", "", field.typeExpr, not field.rest, false,
                          field.typeBodyFieldScope(scope), lookup)
        if field.rest: rest = p
        else: positional.add p
      minimum = positional.len
      for field in target.typeFields:
        named.add parameter(field.name, field.name, field.typeExpr,
          not field.optional, false, field.typeFieldScope(scope), lookup)
      resultType = target
    elif target.typeNativeCtor.kind != vkNil:
      props["construction"] = newSym("native")
  of vkEnumVariant:
    props["category"] = newSym("enum_variant")
    props["origin"] = newSym("schema")
    props["construction"] = newSym("data")
    let enumType = target.enumVariantEnum
    props["name"] = newStr(enumType.typeName & "/" & target.enumVariantName)
    scope = enumType.typeScope
    for typ in target.enumVariantPayloadTypes:
      positional.add parameter("", "", typ, true, false, scope, lookup,
                                unresolved = enumType.enumTypeParams)
    minimum = positional.len
    resultType = enumType
  of vkNode:
    if target.head.symbol("select"):
      props["category"] = newSym("selector")
      props["origin"] = newSym("builtin")
      positional.add parameter("value", "", NIL, true, false, nil, lookup)
      minimum = 1
  else: discard
  let shapeKnown = not props["origin"].symbol("unknown")
  if options.category.len > 0: props["category"] = newSym(options.category)
  if options.origin.len > 0: props["origin"] = newSym(options.origin)
  if not shapeKnown:
    return newNode(newSym("SignatureDescription"), props = props, immutable = true)
  props["shape_known"] = TRUE
  props["positional"] = newList(positional, immutable = true)
  props["named"] = newList(named, immutable = true)
  props["rest"] = rest
  props["minimum_positional"] = newInt(minimum)
  props["result_known"] = newBool(resultType.kind != vkVoid)
  props["result"] = if resultType.kind == vkVoid: NIL else: resultType
  var deferred = initPropTable()
  deferred["known"] = FALSE
  if resultType.kind == vkNode and resultType.head.kind == vkSymbol and
      resultType.head.symVal in ["Stream", "Task"] and resultType.body.len == 2:
    deferred["known"] = TRUE
    deferred["kind"] = newSym(resultType.head.symVal.toLowerAscii())
    deferred["value_type"] = resultType.body[0]
    deferred["error_type"] = resultType.body[1]
  props["deferred"] = newMap(deferred, immutable = true)
  var errorProps = initPropTable()
  errorProps["checked"] = newBool(errorsChecked)
  errorProps["known"] = newBool(errorsChecked)
  var safeErrors: seq[Value]
  for typ in errors:
    let safe = safeAnnotation(typ, scope, lookup, abstractSelf = options.abstractSelf)
    if safe.kind == vkVoid: errorProps["known"] = FALSE
    else: safeErrors.add safe
  errorProps["types"] = if errorsChecked: newList(safeErrors, immutable = true) else: NIL
  props["invocation_errors"] = newMap(errorProps, immutable = true)
  if options.constructedType.kind == vkType:
    # The ctor's row bounds its body/defaults, not the subsequent validation
    # of the constructed instance. Do not claim `new` inherits an empty row.
    props["constructor_errors"] = props["invocation_errors"]
    errorProps = initPropTable()
    errorProps["checked"] = FALSE
    errorProps["known"] = FALSE
    errorProps["types"] = NIL
    props["invocation_errors"] = newMap(errorProps, immutable = true)
  var complete = resultType.kind != vkVoid and errorProps["known"] == TRUE
  for p in positional: complete = complete and p.mapEntries["type_known"] == TRUE
  for p in named: complete = complete and p.mapEntries["type_known"] == TRUE
  if rest.kind != vkNil: complete = complete and rest.mapEntries["type_known"] == TRUE
  props["completeness"] = newSym(if complete: "known" else: "partial")
  newNode(newSym("SignatureDescription"), props = props, immutable = true)

proc withReflectionProperties*(description: Value,
                                properties: openArray[(string, Value)]): Value =
  var props = initPropTable()
  for key, value in description.props: props[key] = value
  for (key, value) in properties: props[key] = value
  newNode(description.head, props = props, immutable = true)

proc bindArgumentShape*(description, positional, named: Value): Value =
  ## Descriptions are data, not admission tokens. Even a copied/edited
  ## description can only validate a shape; invocation always checks the target.
  template invalid(message: string) =
    raise newException(GeneError, "runtime/bind_shape: " & message)
  if description.kind != vkNode or not description.head.symbol("SignatureDescription"):
    invalid("expected a SignatureDescription")
  let d = description.props
  if d.getOrDefault("format", NIL) != newInt(1) or
      d.getOrDefault("shape_known", NIL) != TRUE:
    invalid("signature has no known argument shape")
  if positional.kind != vkList or named.kind != vkMap:
    invalid("expected a positional List and named PropMap")
  let parameters = d.getOrDefault("positional", NIL)
  let names = d.getOrDefault("named", NIL)
  let minimum = d.getOrDefault("minimum_positional", NIL)
  let rest = d.getOrDefault("rest", NIL)
  if parameters.kind != vkList or names.kind != vkList or minimum.kind != vkInt or
      minimum.intVal < 0 or minimum.intVal > parameters.listItems.len or
      rest.kind notin {vkNil, vkMap}:
    invalid("malformed argument shape")
  if positional.listItems.len < minimum.intVal or
      (rest.kind == vkNil and positional.listItems.len > parameters.listItems.len):
    invalid("positional argument count does not match the signature")
  var allowed = initHashSet[string]()
  var omittedNamed: seq[Value]
  for parameter in names.listItems:
    if parameter.kind != vkMap: invalid("malformed named parameter")
    let name = parameter.mapEntries.getOrDefault("name", NIL)
    let required = parameter.mapEntries.getOrDefault("required", NIL)
    if name.kind != vkString or required.kind != vkBool or name.strVal in allowed:
      invalid("malformed named parameter")
    allowed.incl name.strVal
    if not named.mapEntries.hasKey(name.strVal):
      if required == TRUE: invalid("missing named argument: " & name.strVal)
      omittedNamed.add name
  for key, _ in named.mapEntries:
    if key notin allowed: invalid("unexpected named argument: " & key)
  var omittedPositional: seq[Value]
  for i in positional.listItems.len ..< parameters.listItems.len:
    omittedPositional.add newInt(i)
  var props = initPropTable()
  # Only freeze the envelope. Nested payloads retain ordinary alias identity.
  var supplied: seq[Value]
  for value in positional.listItems: supplied.add value
  var suppliedNamed = initPropTable()
  for key, value in named.mapEntries: suppliedNamed[key] = value
  props["positional"] = newList(supplied, immutable = true)
  props["named"] = newMap(suppliedNamed, immutable = true)
  props["omitted_positional"] = newList(omittedPositional, immutable = true)
  props["omitted_named"] = newList(omittedNamed, immutable = true)
  newNode(newSym("BoundShape"), props = props, immutable = true)
