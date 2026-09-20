## Included by vm.nim. Host-only module-domain prototype used to exercise v1
## declaration identity and linkage before replacing ordinary import caches.

proc loadCapabilityDomainModule*(app: Application, owner, revision, dir, entry: string,
    ceiling: CapabilityContext, shared: seq[string] = @[],
    exposedNamespaces: seq[string] = @[], maxSteps: int64 = 1_000_000): Value =
  if app == nil or owner.len == 0 or revision.len == 0 or maxSteps <= 0:
    raise newException(GeneError, "capability module admission needs owner, revision and budget")
  if app.sandboxRoot != nil or activeSandboxPolicy != nil:
    raise newException(GeneError, "capability module admission is a host boundary")
  let registry = app.capabilityRegistry
  discard registry.policyRows(ceiling)
  let caller =
    if activeCapabilityContext != nil: activeCapabilityContext
    elif app.applicationCapabilityContext != nil: app.applicationCapabilityContext
    else: app.rootCapabilityContext
  var effective = intersectContexts(caller, ceiling)
  if not effective.isPolicyContext:
    effective = registry.newPolicyContext([])
  # Shared contracts must have been initialized by the host already. The
  # sandbox's first import cannot trigger a privileged lazy initialization.
  var sharedIdentities: seq[string]
  for item in shared:
    let path =
      if item.isAbsolute: normalizedPath(absolutePath(item))
      else: normalizedPath(app.appPackage.root / item)
    let withExt = if splitFile(path).ext.len == 0: path & ".gene" else: path
    if not app.hostInitializedModules.hasKey(app.moduleIdentityFor(withExt)):
      raise newException(GeneError,
        "shared capability contract must be initialized before domain admission")
    let sharedIdentity = $withExt.len & ":" & withExt & ":" &
      $app.hostInitializedModules[app.moduleIdentityFor(withExt)].moduleRuntimeId
    if sharedIdentity notin sharedIdentities:
      sharedIdentities.add sharedIdentity
  sharedIdentities.sort()
  var namespaces: seq[string]
  for name in exposedNamespaces:
    if name notin sandboxableNamespaces:
      raise newException(GeneError, "unknown capability-domain namespace exposure: " & name)
    if name notin namespaces:
      namespaces.add name
  namespaces.sort()
  let sourceDirectory = normalizedDir(
    if dir.isAbsolute: dir else: app.appPackage.root / dir)
  let entryPath = app.entryModulePath(sourceDirectory / entry)
  var key = "capability-domain-v1:"
  for part in [owner, revision, effective.domainKey, $maxSteps,
               sourceDirectory, sharedIdentities.join("|")]:
    key.add $part.len & ":" & part
  let failureKey = key & ":" & $entryPath.len & ":" & entryPath &
    ":" & namespaces.join(",")
  if app.capabilityDomainFailures.hasKey(failureKey):
    raise app.capabilityDomainFailures[failureKey]
  let savedCapabilities = activeCapabilityContext
  let savedPresence = activeCapabilityPresence
  let savedPolicy = activeSandboxPolicy
  let savedBudget = activeVmBudget
  let savedCompileKey = activeSandboxCompileKey
  let savedCompileDir = activeSandboxCompileDir
  var budget = evalBudgetForLimits(maxSteps, -1, -1,
    if savedBudget == nil: nil else: savedBudget[])
  activeCapabilityContext = effective
  activeCapabilityPresence = nil
  activeSandboxPolicy = ModuleExecutionPolicy(maxSteps: maxSteps,
    maxMemoryMb: -1, timeoutMs: -1,
    capabilityCeiling: effective)
  activeVmBudget = addr budget
  activeSandboxCompileKey = namespaces.join(",") & "\x1e" & key
  activeSandboxCompileDir = sourceDirectory
  var sourceRevisionKey = "capability-domain-sources-v1:"
  for part in [owner, revision]: sourceRevisionKey.add $part.len & ":" & part
  try:
    result = app.loadSandboxedModule(dir, entry, namespaces, shared, key, sourceRevisionKey)
  except CatchableError as error:
    app.capabilityDomainFailures[failureKey] = error
    raise
  finally:
    activeSandboxCompileKey = savedCompileKey
    activeSandboxCompileDir = savedCompileDir
    activeVmBudget = savedBudget
    activeSandboxPolicy = savedPolicy
    activeCapabilityPresence = savedPresence
    activeCapabilityContext = savedCapabilities
