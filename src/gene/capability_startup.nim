## Host-only startup source selection and normalized grant initialization.
## Neither policy text nor a selected source is runtime authority by itself.
import std/[options, os, strutils]
import ./[capabilities, fs_capabilities]

type
  CapabilityStartupOrigin* = enum
    csoBuiltinDefault, csoCliLiteral, csoCliFile, csoEnvironmentVariable,
    csoHostConfiguration
  CapabilityStartupOptions* = object
    present: bool
    file: bool
    value: string
    optionName: string
  CapabilityHostDefault* = object
    present: bool
    text: string
    source: CapabilitySourceContext
  CapabilityStartupSelection* = object
    originValue: CapabilityStartupOrigin
    textValue: string
    fileValue: string
    sourceValue: CapabilitySourceContext
    capturedValue: CapabilityLiteralRow
  CapabilityStartupAuthority* = ref object
    contextValue: CapabilityContext
    effectiveValue: seq[CapabilityPolicyEntry]
    owned: seq[CapabilityGrant]
    closed: bool
  CapabilityStartupError* = object of CapabilityError
    cleanupFailure*: ref CatchableError

proc capabilityOption*(name: string): bool =
  name in ["--capabilities", "--cap", "--capabilities-file", "--cap-file"]

proc setCapabilityOption*(options: var CapabilityStartupOptions,
    name, value: string) =
  if not name.capabilityOption:
    raise newException(CapabilityError, "unknown capability startup option")
  if options.present:
    raise newException(CapabilityError,
      "at most one command-line capability source may be supplied")
  options = CapabilityStartupOptions(present: true,
    file: name in ["--capabilities-file", "--cap-file"], value: value,
    optionName: name)

proc consumeCapabilityOption*(options: var CapabilityStartupOptions,
    args: openArray[string], index: var int): bool =
  ## Consume one option, including its value; leave unrelated arguments alone.
  if index < 0 or index >= args.len: return false
  let argument = args[index]
  let separator = argument.find('=')
  let name = if separator < 0: argument else: argument[0 ..< separator]
  if not name.capabilityOption: return false
  if separator >= 0:
    options.setCapabilityOption(name, argument[separator + 1 .. ^1])
    inc index
  else:
    if index + 1 >= args.len:
      raise newException(CapabilityError, name & " requires a value")
    options.setCapabilityOption(name, args[index + 1])
    index += 2
  true

proc hostCapabilityDefault*(text, baseDirectory: string,
    name = "host capability configuration"): CapabilityHostDefault =
  CapabilityHostDefault(present: true, text: text,
    source: CapabilitySourceContext(kind: csoFile, name: name,
      baseDirectory: baseDirectory))

proc origin*(selection: CapabilityStartupSelection): CapabilityStartupOrigin =
  selection.originValue
proc source*(selection: CapabilityStartupSelection): CapabilitySourceContext =
  selection.sourceValue
proc capabilityFile*(selection: CapabilityStartupSelection): string =
  selection.fileValue

proc selectCapabilityStartup*(options: CapabilityStartupOptions,
    launchDirectory: string, environment: Option[string] = none(string),
    hostDefault = CapabilityHostDefault()): CapabilityStartupSelection =
  ## Selection is pure. Do not parse/read overridden sources, or fall back if
  ## the selected source subsequently fails reading or validation.
  if not launchDirectory.isAbsolute or '\0' in launchDirectory:
    raise newException(CapabilityError, "startup requires an absolute captured launch directory")
  let launch = normalizedPath(launchDirectory)
  if options.present:
    result.sourceValue = CapabilitySourceContext(kind: csoCommandLine,
      name: options.optionName, baseDirectory: launch)
    if options.file:
      if options.value.len == 0 or '\0' in options.value:
        raise newException(CapabilityError, "capability file path is empty or invalid")
      result.originValue = csoCliFile
      result.fileValue = normalizedPath(absolutePath(options.value, launch))
      result.sourceValue = CapabilitySourceContext(kind: csoFile,
        name: result.fileValue, baseDirectory: parentDir(result.fileValue))
    else:
      result.originValue = csoCliLiteral
      result.textValue = options.value
  elif environment.isSome:
    result.originValue = csoEnvironmentVariable
    result.textValue = environment.get
    result.sourceValue = CapabilitySourceContext(kind: csoEnvironment,
      name: "GENE_CAPABILITIES", baseDirectory: launch)
  elif hostDefault.present:
    result.originValue = csoHostConfiguration
    result.textValue = hostDefault.text
    result.sourceValue = hostDefault.source
  else:
    result.originValue = csoBuiltinDefault
    result.textValue = "[]"
    result.sourceValue = CapabilitySourceContext(kind: csoCommandLine,
      name: "built-in capability default", baseDirectory: launch)

proc readStartupCapabilityFile(provider: FilesystemProvider, path: string): string =
  if provider == nil:
    raise newException(CapabilityError, "capability-file selection requires a host file reader")
  let registry = provider.capabilityRegistry
  let literal = buildCapabilityLiteral([
    CapabilityEntryLiteral(name: "fs/Read", body: @[capabilityText(parentDir(path))])],
    cuGrant, CapabilitySourceContext(name: "startup configuration acquisition"))
  let policy = registry.normalizeCapabilityRow(literal, cuGrant)
  let grant = provider.initializeFilesystemGrant(policy.entries[0].policy)
  defer: provider.releaseFilesystemGrant(grant)
  let context = registry.newPolicyContext([grant])
  let file = provider.openFilesystemFile(context, path)
  defer: file.close()
  result = file.readBytes(context, DefaultCapabilityLiteralLimits.maxBytes + 1)
  if result.len > DefaultCapabilityLiteralLimits.maxBytes:
    raise newException(CapabilityError, "capability file byte limit exceeded")

proc startupCapabilityPolicy*(registry: CapabilityRegistry,
    selection: CapabilityStartupSelection,
    fileProvider: FilesystemProvider = nil): CapabilitySpecRow =
  if selection.capturedValue != nil:
    return registry.normalizeCapabilityRow(selection.capturedValue, cuGrant)
  let text = if selection.originValue == csoCliFile:
               readStartupCapabilityFile(fileProvider, selection.fileValue)
             else: selection.textValue
  registry.normalizeCapabilityRow(
    readCapabilityLiteral(text, cuGrant, selection.sourceValue), cuGrant)

proc captureCapabilityStartup*(registry: CapabilityRegistry,
    selection: CapabilityStartupSelection,
    fileProvider: FilesystemProvider = nil): CapabilityStartupSelection =
  result = selection
  if result.capturedValue == nil:
    let text = if selection.originValue == csoCliFile:
                 readStartupCapabilityFile(fileProvider, selection.fileValue)
               else: selection.textValue
    result.capturedValue = readCapabilityLiteral(text, cuGrant, selection.sourceValue)
  # Validate before other startup work, but retain inert data so another
  # admitted application catalog can normalize it without rereading the file.
  discard registry.normalizeCapabilityRow(result.capturedValue, cuGrant)

proc startupCapabilityPolicies*(registry: CapabilityRegistry,
    selected: CapabilitySpecRow,
    ceilings: openArray[CapabilitySpecRow] = []): seq[CapabilityPolicyEntry] =
  ## Distribute intersections over complete entries, never over their fields.
  ## No state is initialized until all rows and all intersections are ready.
  registry.validateUse(selected, cuGrant)
  if ceilings.len > MaxCapabilityAuthorityRows:
    raise newException(CapabilityError, "startup ceiling count limit exceeded")
  for ceiling in ceilings: registry.validateUse(ceiling, cuBound)
  for entry in selected.entries:
    if not entry.policy.emptyPolicy: result.add entry.policy
  var budget = newCapabilityProofBudget()
  for ceiling in ceilings:
    var next: seq[CapabilityPolicyEntry]
    for left in result:
      let provider = registry.providerFor(left.capabilityType)
      for right in ceiling.entries:
        if budget.remaining <= 0:
          raise newException(CapabilityError, "startup intersection work limit exceeded")
        dec budget.remaining
        if provider != registry.providerFor(right.policy.capabilityType): continue
        for entry in provider.intersectStartupPolicies(left, right.policy, budget):
          if entry == nil or registry.providerFor(entry.capabilityType) != provider:
            raise newException(CapabilityError, "provider returned an invalid startup intersection")
          if entry.emptyPolicy: continue
          if registry.compareCapabilityEntries(left, entry, budget).status != ccCovered or
              registry.compareCapabilityEntries(right.policy, entry, budget).status != ccCovered:
            raise newException(CapabilityError,
              "provider startup intersection is not proved within both inputs")
          if next.len >= MaxNormalizedCapabilityEntries:
            raise newException(CapabilityError, "startup policy expansion limit exceeded")
          next.add entry
    result = next

proc close*(authority: CapabilityStartupAuthority) =
  if authority == nil or authority.closed: return
  authority.closed = true
  var failure: ref CatchableError
  for index in countdown(authority.owned.high, 0):
    let grant = authority.owned[index]
    let provider = grant.owningProvider
    provider.revoke(grant)
    try:
      provider.releaseCapabilityGrant(grant)
    except CatchableError as error:
      if failure == nil: failure = error
  authority.owned.setLen(0)
  if failure != nil: raise failure

proc context*(authority: CapabilityStartupAuthority): CapabilityContext =
  if authority == nil:
    raise newException(CapabilityError, "startup authority is nil")
  authority.contextValue

proc effectivePolicies*(authority: CapabilityStartupAuthority): seq[CapabilityPolicyEntry] =
  if authority == nil:
    raise newException(CapabilityError, "startup authority is nil")
  for entry in authority.effectiveValue: result.add entry

proc initializeStartupCapabilities*(registry: CapabilityRegistry,
    selected: CapabilitySpecRow,
    ceilings: openArray[CapabilitySpecRow] = []): CapabilityStartupAuthority =
  let policies = registry.startupCapabilityPolicies(selected, ceilings)
  let authority = CapabilityStartupAuthority(effectiveValue: policies)
  try:
    for entry in policies:
      let provider = registry.providerFor(entry.capabilityType)
      let grant = provider.initializeCapabilityGrant(entry)
      if grant == nil or not grant.isOwnedBy(provider):
        raise newException(CapabilityError, "provider returned an invalid startup grant")
      authority.owned.add grant
      if grant.normalizedPolicy.canonicalKey != entry.canonicalKey:
        raise newException(CapabilityError, "provider changed the startup grant policy")
    authority.contextValue = registry.newPolicyContext(authority.owned)
    authority
  except:
    let cause = getCurrentException()
    try:
      authority.close()
    except CatchableError as cleanup:
      let failure = newException(CapabilityStartupError,
        "startup grant initialization failed and resource cleanup also failed")
      failure.parent = cause
      failure.cleanupFailure = cleanup
      raise failure
    raise

proc selectStartupCapabilities*(registry: CapabilityRegistry,
    available: CapabilityContext, selected: CapabilitySpecRow,
    ceilings: openArray[CapabilitySpecRow] = []): CapabilityContext =
  ## An embedder's existing authority is reused, not reissued. Its grant
  ## references, live validity and independent rows remain in the result.
  registry.validateUse(selected, cuGrant)
  if ceilings.len > MaxCapabilityAuthorityRows:
    raise newException(CapabilityError, "startup ceiling count limit exceeded")
  for ceiling in ceilings: registry.validateUse(ceiling, cuBound)
  result = registry.attenuateCapabilities(available, selected)
  for ceiling in ceilings:
    result = registry.attenuateCapabilities(result, ceiling)
