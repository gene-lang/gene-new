## Included by compiler.nim: lower capability literals without expression
## evaluation, parameter binding, reader extensions or application name lookup.

proc sourceCapabilityName(value: Value): string =
  if value.kind == vkSymbol:
    return value.symVal
  if value.kind != vkNode or not value.head.isSymbol("path") or
      value.props.len != 0 or value.meta.len != 0 or value.invalidCapabilitySyntax:
    raise newException(GeneError, "capability identifier must be namespace/Name")
  for segment in value.body:
    if segment.kind != vkSymbol:
      raise newException(GeneError, "capability identifiers are inert names")
    if result.len > 0: result.add '/'
    result.add segment.symVal

proc sourceCapabilityScalar(value: Value): CapabilityScalar =
  case value.kind
  of vkString:
    CapabilityScalar(kind: cskText, text: value.strVal, stringMode: csmSource)
  of vkBool: capabilityBoolean(value.boolVal)
  of vkInt:
    if not value.intFitsInt64:
      raise newException(GeneError, "capability integer exceeds signed 64-bit range")
    capabilityInteger(value.intVal)
  of vkSymbol:
    if value.symVal != "*":
      raise newException(GeneError,
        "capability literals do not look up variables; use capabilities/build")
    capabilityAny()
  else:
    raise newException(GeneError, "invalid scalar in inert capability literal")

proc sourceCapabilityProperty(value: Value): CapabilityPropertyValue =
  if value.kind == vkList:
    if value.listImmutable or value.invalidCapabilitySyntax:
      raise newException(GeneError, "capability property requires a flat literal list")
    var values: seq[CapabilityScalar]
    for item in value.listItems:
      values.add sourceCapabilityScalar(item)
    capabilityValues(values)
  else:
    capabilityValue(sourceCapabilityScalar(value))

proc sourceCapabilityBase(name: string): string =
  # Portable package identities are diagnostic names, not filesystem paths.
  # Their declaring base is supplied when the module artifact is linked.
  if "://" in name or "::" in name or name.startsWith("<"):
    return ""
  if name.len == 0: getCurrentDir()
  else: parentDir(absolutePath(name))

proc legacyCapabilityArg(value: CapabilityScalar): CapabilityArg =
  case value.kind
  of cskWildcard: capSymbol("*")
  of cskText: capString(value.text)
  of cskInteger: capInt(value.integer)
  of cskBoolean: capBool(value.boolean)
  else: raise newException(GeneError, "invalid capability scalar")

proc compileCapabilityRow(c: Compiler, value: Value,
                          proto: FunctionProto = nil,
                          allowLexical = false,
                          use = cuRequest): CapabilityRow =
  discard proto
  discard allowLexical
  if value.kind != vkList or value.listImmutable or value.invalidCapabilitySyntax:
    raise newException(GeneError, "capabilities require one inert literal row")
  result.kind = crkSelect
  let source = CapabilitySourceContext(kind: csoSource, name: c.sourceName,
    baseDirectory: sourceCapabilityBase(c.sourceName))
  var entries: seq[CapabilityEntryLiteral]
  for item in value.listItems:
    var entry: CapabilityEntryLiteral
    let loc = if c.sourceLocs != nil and c.sourceLocs[].hasKey(item.bits):
                c.sourceLocs[][item.bits] else: c.currentLoc
    entry.location = CapabilityLocation(sourceName: c.sourceName,
      line: loc.line, column: loc.col)
    var arguments: seq[Value]
    var properties = initPropTable()
    if item.kind == vkNode:
      if item.nodeDuplicateProps:
        raise newException(GeneError, "duplicate property in capability literal")
      if item.invalidCapabilitySyntax or item.meta.len != 0 or item.nodeImmutable:
        raise newException(GeneError, "invalid syntax in capability literal")
      if item.head.isSymbol("path"):
        entry.name = sourceCapabilityName(item)
      else:
        entry.name = sourceCapabilityName(item.head)
        arguments = item.body
        properties = item.props
    else:
      entry.name = sourceCapabilityName(item)
    if entry.name in ["fs/ReadDir", "fs/ReadFile", "fs/WriteDir",
                      "fs/WriteFile", "fs/ReadWriteDir"]:
      raise newException(GeneError,
        "legacy filesystem capability name; use fs/Read, fs/Write or fs/ReadWrite")
    if c.enforceCapabilityCatalog and not entry.name.endsWith("/*") and
        not c.capabilityCatalog.hasKey(entry.name):
      raise newException(GeneError, "unknown or host-unadmitted capability: " & entry.name)
    for argument in arguments:
      entry.body.add sourceCapabilityScalar(argument)
    for key, property in properties:
      if key == "optional":
        if property.kind != vkBool:
          raise newException(GeneError, "optional must be a literal Bool")
        entry.hasOptional = true
        entry.optional = property.boolVal
      else:
        entry.properties.add CapabilityPropertyLiteral(name: key,
          value: sourceCapabilityProperty(property))
    var selector = CapabilitySelectorTemplate(
      kind: if entry.name.endsWith("/*"): cskNamespace else: cskExact,
      typeName: entry.name, optional: entry.optional, hasOptional: entry.hasOptional)
    if selector.kind == cskNamespace:
      selector.namespaceName = entry.name[0 ..< entry.name.len - 2]
    for scalar in entry.body:
      selector.positional.add capLiteral(legacyCapabilityArg(scalar))
    for field in entry.properties:
      var argument: CapabilityArg
      if field.value.isList:
        var items: seq[CapabilityArg]
        for scalar in field.value.items:
          items.add legacyCapabilityArg(scalar)
        argument = capList(items)
      else:
        argument = legacyCapabilityArg(field.value.scalar)
      selector.named.add CapabilityTemplateNamedArg(name: field.name,
        value: capLiteral(argument))
    selector.named.sort(proc(a, b: CapabilityTemplateNamedArg): int = cmp(a.name, b.name))
    result.selectors.add selector
    entries.add entry
  try:
    if c.unitSource.len > 0 and c.sourceLocs != nil and
        c.sourceLocs[].hasKey(value.bits):
      let loc = c.sourceLocs[][value.bits]
      var offset = 0
      var line = 1
      while line < loc.line and offset < c.unitSource.len:
        let next = c.unitSource.find('\n', offset)
        if next < 0: break
        offset = next + 1
        inc line
      offset += max(0, loc.col - 1)
      if line == loc.line and offset < c.unitSource.len and c.unitSource[offset] == '[':
        result.literal = readCapabilityLiteralAt(c.unitSource, offset,
          loc.line, loc.col, use, source)
    if result.literal == nil:
      result.literal = buildCapabilitySourceLiteral(entries, use, source)
  except CapabilityLiteralError as error:
    raise newException(GeneError, error.msg)

proc compileCapabilitySelection*(value: Value): CapabilityRow =
  Compiler().compileCapabilityRow(value, use = cuBound)

proc normalizedFunctionCapabilityRow(c: Compiler, node: Value,
                                     proto: FunctionProto,
                                     isPublic: bool): CapabilityRow =
  discard isPublic
  if node.nodeDuplicateCapabilities:
    raise newException(GeneError, "duplicate callable capability declaration")
  if node.props.hasKey("capabilities"):
    return c.compileCapabilityRow(node.props["capabilities"], proto)
  CapabilityRow(kind: crkInherit)
