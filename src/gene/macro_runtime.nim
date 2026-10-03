## Included by vm.nim after its ordinary evaluator and module loader exist.
## Macro definitions contain portable source context; execution state is owned
## by a compilation session and uses a separate Application/module instance.

type
  MacroInstanceStatus = enum
    misCold, misInitializing, misReady, misFailed

  MacroPhaseInstance = ref object
    context: MacroDefinitionContext
    scope: Scope
    definitions: Table[string, MacroDef]
    status: MacroInstanceStatus
    failure: string
    loaderOwned: bool

  CompiledMacroBody = ref object
    definition: MacroDef # retain the identity used by the cache key
    initial: Chunk
    initialized: Chunk
    needsBindings: bool

  MacroRuntimeStateData = object of RootObj
    application: Application
    instances: Table[string, MacroPhaseInstance]
    contextKeys: Table[pointer, tuple[context: MacroDefinitionContext, key: string]]
    builtinInstance: MacroPhaseInstance
    activeBudget: EvalBudget
    bodies: Table[tuple[definition: pointer, names: seq[string]], CompiledMacroBody]

  MacroRuntimeState = ref MacroRuntimeStateData

  RetiredMacroContext = ref object
    application: Application
    scopes: seq[Scope]

  MacroRetirementQueue = object
    pending: seq[RetiredMacroContext]
    draining: bool

var macroRetirementQueue {.threadvar.}: ptr MacroRetirementQueue

proc tryRetireMacroContext(retired: RetiredMacroContext): bool =
  if retired.application == nil: return true
  if retired.application.compilerOwnerLane != currentEventLane(): return false
  var roots: RuntimeContextRoots
  template own(scope: Scope) =
    if scope != nil and scope.application == retired.application:
      roots.addOwnedScope(scope)
  for scope in retired.scopes: own(scope)
  for name, field in fieldPairs(retired.application[]):
    when field is Scope:
      own(field)
    elif field is Value:
      roots.addOwnedValue(field)
    elif field is seq[Scope]:
      for scope in field: own(scope)
    elif field is Table[string, Scope]:
      for _, scope in field: own(scope)
    elif field is Table[string, Value]:
      for _, value in field: roots.addOwnedValue(value)
    elif field is Table[tuple[receiver, message: uint64], seq[Scope]]:
      for _, scopes in field:
        for scope in scopes: own(scope)
  if not retireRuntimeContextScopes(retired.application, roots): return false
  for name, field in fieldPairs(retired.application[]):
    when field is Scope or field is Value:
      reset(field)
    elif field is seq[Scope] or field is Table[string, Scope] or
        field is Table[string, Value] or
        field is Table[tuple[receiver, message: uint64], seq[Scope]]:
      reset(field)
  retired.scopes.setLen(0)
  true

proc drainMacroContexts() {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    if macroRetirementQueue == nil or macroRetirementQueue.draining or
        activeMacroSession != nil: return
    macroRetirementQueue.draining = true
    try:
      var pending = move macroRetirementQueue.pending
      for retired in pending:
        if not tryRetireMacroContext(retired):
          macroRetirementQueue.pending.add retired
    finally:
      macroRetirementQueue.draining = false

proc `=destroy`(state: var MacroRuntimeStateData) =
  withoutPendingException:
    let retired = RetiredMacroContext(application: move state.application)
    for _, instance in state.instances: retired.scopes.add instance.scope
    if state.builtinInstance != nil: retired.scopes.add state.builtinInstance.scope
    for name, field in fieldPairs(state):
      `=destroy`(field)
    if not tryRetireMacroContext(retired):
      # Keep one owner while external helpers/Env values are alive. Retry at
      # VM safe points, after those external references can have disappeared.
      # Like ordinary cycle watches, the queue is not destroyed at shutdown.
      if macroRetirementQueue == nil:
        macroRetirementQueue = create(MacroRetirementQueue)
      macroRetirementQueue.pending.add retired

macroContextRetirementHook = drainMacroContexts

proc macroRuntimeState(session: MacroExecutionSession): MacroRuntimeState =
  if session.runtimeState != nil:
    return MacroRuntimeState(session.runtimeState)
  let host =
    if session.hostContext != nil: Application(session.hostContext)
    elif activeVmScope != nil: activeVmScope[].application()
    else: currentApplication()
  let phaseApp = newApplication(host.packageGraph, host.launchDir)
  phaseApp.privateCompilerContext = true
  phaseApp.compilerOwnerLane = currentEventLane()
  phaseApp.compileArtifactTemplates = host.compileArtifactTemplates
  for identity, artifact in host.moduleCompileArtifacts:
    phaseApp.compileArtifactTemplates[identity] = artifact
  # A compilation needs its own module instances and implementation registry,
  # not another copy of the intrinsic library. Intrinsic Values already have
  # process-stable identities; retain them through the host's library scopes.
  # The lexical root and its impl table are private to the phase, so registering
  # a definition-side implementation cannot alter the runtime application's root.
  let hostBuiltins = host.builtinsScope()
  let phaseBuiltins = newScope(application = phaseApp)
  phaseBuiltins.vars = hostBuiltins.vars
  phaseBuiltins.impls = host.intrinsicImpls
  phaseApp.intrinsicImpls = host.intrinsicImpls
  phaseApp.builtins = phaseBuiltins
  phaseApp.stdlib = host.stdlib
  phaseApp.errorDefaultMessage = host.errorDefaultMessage
  phaseApp.boundCallTemplate = host.boundCallTemplate
  phaseApp.streamCallbackTemplate = host.streamCallbackTemplate
  phaseApp.collectionCallbackTemplate = host.collectionCallbackTemplate
  phaseApp.sortCallbackTemplate = host.sortCallbackTemplate
  phaseApp.outputCallbackTemplate = host.outputCallbackTemplate
  phaseApp.callableViewTemplate = host.callableViewTemplate
  phaseApp.nativeAdd = host.nativeAdd
  phaseApp.nativeSub = host.nativeSub
  phaseApp.nativeMul = host.nativeMul
  phaseApp.nativeLt = host.nativeLt
  phaseApp.nativeGt = host.nativeGt
  phaseApp.nativeLe = host.nativeLe
  phaseApp.nativeGe = host.nativeGe
  if host.sandboxRoot != nil:
    # Rebuild the same grant surface in the phase Application. Reusing the
    # host's Scope mixes Error/impl ownership between Applications and can
    # replace a budget failure with an error-admission failure.
    let allowed = host.sandboxRoot.lookup("gene").nsScope
    var grants: seq[string]
    for name in sandboxableNamespaces:
      if allowed.vars.hasKey(name): grants.add name
    phaseApp.sandboxRoot = phaseApp.sandboxedBuiltins(grants)
  phaseApp.sandboxKey = host.sandboxKey
  phaseApp.sandboxDir = host.sandboxDir
  phaseApp.sandboxRestricting = host.sandboxRestricting
  phaseApp.sandboxShared = host.sandboxShared
  phaseApp.allowUrlModules = host.allowUrlModules
  phaseApp.urlSources = host.urlSources
  result = MacroRuntimeState(application: phaseApp)
  session.runtimeState = result

proc macroModulePath(app: Application, context: MacroDefinitionContext): string

proc macroPhaseInstance(state: MacroRuntimeState,
                        context: MacroDefinitionContext): MacroPhaseInstance =
  if context == nil:
    if state.builtinInstance == nil:
      state.builtinInstance = MacroPhaseInstance(
        scope: newGlobalScope(state.application), status: misReady)
    return state.builtinInstance
  let address = cast[pointer](context)
  if not state.contextKeys.hasKey(address):
    if context.moduleIdentity.len > 0:
      var source = ""
      for form in context.forms:
        source.add form.print()
        source.add '\n'
      state.contextKeys[address] = (context, context.moduleIdentity & "\x1f" & sha256Hex(source))
    else:
      state.contextKeys[address] = (context, "local:" & $cast[uint](address))
  let key = state.contextKeys[address].key
  if not state.instances.hasKey(key):
    let module = state.application.moduleCache.getOrDefault(context.moduleIdentity)
    if context.moduleIdentity.len > 0 and module.kind == vkModule:
      let scope = module.moduleRootNamespace.nsScope
      let bindings = asMacroBindings(scope.compilerMacros)
      state.instances[key] = MacroPhaseInstance(context: context, scope: scope,
        status: misReady,
        definitions: if bindings == nil: initTable[string, MacroDef]() else: bindings.definitions)
    else:
      var initializing: Scope
      if context.moduleIdentity.len > 0 and context.moduleIdentity in state.application.moduleLoading:
        let path = state.application.macroModulePath(context)
        for scope in state.application.baseScopes:
          let owner = scope.vars.getOrDefault("this_mod")
          if owner.kind == vkModule and owner.modulePath == path:
            initializing = scope
            break
      if initializing != nil:
        let bindings = asMacroBindings(initializing.compilerMacros)
        state.instances[key] = MacroPhaseInstance(context: context, scope: initializing,
          status: misInitializing, loaderOwned: true,
          definitions: if bindings == nil: initTable[string, MacroDef]() else: bindings.definitions)
      else:
        state.instances[key] = MacroPhaseInstance(context: context,
          scope: newGlobalScope(state.application))
  state.instances[key]

proc macroModulePath(app: Application, context: MacroDefinitionContext): string =
  if context.moduleIdentity.len == 0: return ""
  if context.moduleSourcePath.len > 0:
    for pkg in app.resolvedPackages():
      if context.moduleIdentity.startsWith(pkg.packageIdentity & "::"):
        return normalizedPath(pkg.root / context.moduleSourcePath)
  # URL and external ad-hoc/sandbox modules retain their explicit source path.
  if context.sourceName.isUrlModulePath or context.sourceName.isAbsolute:
    return context.sourceName
  raise newException(GeneError,
    "macro definition module is not in the selected package graph: " & context.moduleIdentity)

proc macroNeedsDefinitionBindings(chunk: Chunk): bool =
  if chunk == nil:
    return false
  for instruction in chunk.instructions:
    case instruction.op
    of opLoadName, opCallName0, opCallName1, opCallNameN, opSetName:
      # Even an intrinsic spelling can be shadowed in the definition module.
      # Name-based access needs that lexical environment before it can choose
      # a binding; presence in the intrinsic parent is not sufficient evidence.
      return true
    of opMakeEnv, opEval, opSyntaxCall, opImport, opImportImpl:
      return true
    else:
      discard
  for nested in chunk.subchunks:
    if macroNeedsDefinitionBindings(nested):
      return true
  for function in chunk.functions:
    if macroNeedsDefinitionBindings(function.chunk):
      return true
    for parameter in function.paramDefaults:
      if macroNeedsDefinitionBindings(parameter.defaultChunk):
        return true
    for parameter in function.namedParams:
      if macroNeedsDefinitionBindings(parameter.defaultValue.defaultChunk):
        return true
  for loop in chunk.forLoops:
    if macroNeedsDefinitionBindings(loop.body):
      return true
  for matcher in chunk.matches:
    for clause in matcher.clauses:
      if macroNeedsDefinitionBindings(clause.body):
        return true
    if macroNeedsDefinitionBindings(matcher.elseBody):
      return true
  for attempt in chunk.tries:
    if macroNeedsDefinitionBindings(attempt.body) or
        macroNeedsDefinitionBindings(attempt.ensureBody):
      return true
    for clause in attempt.catches:
      if macroNeedsDefinitionBindings(clause.body):
        return true
  false

proc initializeMacroInstance(state: MacroRuntimeState,
                             instance: MacroPhaseInstance,
                             session: MacroExecutionSession,
                             budget: CompileBudget) =
  if instance.loaderOwned and instance.status == misInitializing and
      instance.context.moduleIdentity notin state.application.moduleLoading:
    if state.application.moduleCache.hasKey(instance.context.moduleIdentity):
      instance.status = misReady
    else:
      instance.status = misFailed
      instance.failure = "macro definition module initialization failed: " & instance.context.moduleIdentity
  case instance.status
  of misReady, misInitializing:
    # Initializers can expand macros using bindings initialized earlier in the
    # same phase instance. A missing forward dependency still fails normally.
    return
  of misFailed:
    raise newException(GeneError, instance.failure)
  of misCold:
    discard
  instance.status = misInitializing
  let app = state.application
  let savedDir = app.currentModuleDir
  let savedPackage = app.currentPackage
  let sourceName = instance.context.sourceName
  var module = NIL
  var registeredLoading = false
  proc initializeForms(forms: seq[Value], target: Scope, path: seq[string],
                       definitions: var Table[string, MacroDef]) =
    var owned: seq[string]
    for form in forms:
      if form.kind == vkNode and form.head.isSymbol("ns") and
          form.body.len > 0 and form.body[0].kind == vkSymbol:
        let name = form.body[0].symVal
        let nested = newScope(target)
        nested.moduleStatic = target.moduleStatic
        target.define(name, newNamespace(name, nested))
        var childDefinitions = definitions
        initializeForms(form.body[1 .. ^1], nested, path & @[name], childDefinitions)
        let childContext = asMacroBindings(nested.compilerMacros)
        if childContext != nil:
          for local in childContext.ownedNames:
            definitions[name & "/" & local] = childDefinitions[local]
        continue
      let compiled = compileMacroPhaseForm(instance.context, form,
        definitions, session, budget, namespacePath = path, ownedNames = owned)
      definitions = compiled.macros
      owned = compiled.chunk.finalMacroContext.ownedNames
      discard run(compiled.chunk, target)
  try:
    let modulePath = app.macroModulePath(instance.context)
    if modulePath.len > 0:
      if instance.context.moduleIdentity in app.moduleLoading:
        raise newException(GeneError,
          "macro module initialization cycle at " & instance.context.moduleIdentity)
      app.moduleLoading.incl instance.context.moduleIdentity
      registeredLoading = true
      app.currentModuleDir = app.moduleSourceDir(modulePath)
      app.currentPackage = app.packageForModule(modulePath)
      module = bindThisModule(instance.scope, splitFile(modulePath).name,
        modulePath, app.currentPackage)
    elif sourceName.len > 0 and fileExists(sourceName):
      app.currentModuleDir = parentDir(normalizedPath(absolutePath(sourceName)))
      app.currentPackage = app.packageForModule(normalizedPath(absolutePath(sourceName)))
    initializeForms(instance.context.forms, instance.scope, @[], instance.definitions)
    instance.status = misReady
    if module.kind == vkModule:
      app.moduleCache[instance.context.moduleIdentity] = module
  except GeneError as error:
    instance.status = misFailed
    instance.failure = "initializing macro definition environment '" &
      sourceName & "': " & error.msg
    raise newException(GeneError, instance.failure)
  finally:
    if registeredLoading: app.moduleLoading.excl instance.context.moduleIdentity
    app.currentModuleDir = savedDir
    app.currentPackage = savedPackage

proc macroDefinitionScope(instance: MacroPhaseInstance,
                          path: seq[string]): Scope =
  result = instance.scope
  for name in path:
    let namespace = result.lookup(name)
    if namespace.kind != vkNamespace:
      raise newException(GeneError,
        "macro definition namespace is not available: " & name)
    result = namespace.nsScope

proc evaluateMacroBody(definition: MacroDef, bindings: Table[string, Value],
                       session: MacroExecutionSession,
                       budget: CompileBudget): Value {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    if session.runtimeDefinitionScope != nil:
      var names: seq[string]
      for name in bindings.keys: names.add name
      names.sort()
      var arguments: seq[Value]
      for name in names: arguments.add bindings[name]
      let code = compileMacroBody(definition, names, definition.lexicalMacros, session, budget)
      let scope = session.runtimeDefinitionScope
      let savedMacros = scope.compilerMacros
      let savedBudget = scope.evalBudget
      if activeVmBudget != nil: scope.evalBudget = activeVmBudget[]
      try:
        let function = run(code, scope)
        return applyCall(function, arguments, NamedArgs(), scope, loc = definition.sourceLoc)
      finally:
        scope.compilerMacros = savedMacros
        scope.evalBudget = savedBudget
    let state = macroRuntimeState(session)
    let instance = state.macroPhaseInstance(definition.context)
    var names: seq[string]
    for name in bindings.keys:
      names.add name
    names.sort()
    var arguments: seq[Value]
    for name in names:
      arguments.add bindings[name]
    let bodyKey = (cast[pointer](definition), names)
    if not state.bodies.hasKey(bodyKey):
      let code = compileMacroBody(definition, names, definition.lexicalMacros, session, budget)
      state.bodies[bodyKey] = CompiledMacroBody(definition: definition,
        initial: code, needsBindings: macroNeedsDefinitionBindings(code))
    let compiled = state.bodies[bodyKey]
    var body = compiled.initial
    let savedBudget = instance.scope.evalBudget
    let previousBudget = state.activeBudget
    let parentBudget = if previousBudget != nil: previousBudget
                       elif activeVmBudget != nil: activeVmBudget[]
                       else: nil
    var invocationBudget: EvalBudget
    if budget != nil:
      if budget.runtimeBudget == nil:
        budget.runtimeBudget = EvalBudget(remaining: budget.remaining,
          parent: parentBudget, hasDeadline: budget.hasDeadline,
          deadline: budget.deadline, hasMemoryLimit: budget.hasMemoryLimit,
          memoryBaseline: budget.memoryBaseline,
          memoryLimitBytes: budget.memoryLimitBytes)
      invocationBudget = budget.runtimeBudget
    else:
      invocationBudget = parentBudget
    instance.scope.evalBudget = invocationBudget
    state.activeBudget = invocationBudget
    try:
      var lexical = instance.scope
      if instance.status == misReady:
        lexical = macroDefinitionScope(instance, definition.namespacePath)
      if compiled.needsBindings:
        state.initializeMacroInstance(instance, session, budget)
        if compiled.initialized != nil and instance.status == misReady:
          body = compiled.initialized
        else:
          var definitions = definition.lexicalMacros
          for name, macroDefinition in instance.definitions:
            definitions[name] = macroDefinition
          body = compileMacroBody(definition, names, definitions, session, budget)
          # Reentrant initializers have only partially populated bindings.
          # Cache the definitive body only after initialization completes.
          if instance.status == misReady:
            compiled.initialized = body
        lexical = macroDefinitionScope(instance, definition.namespacePath)
      # A namespace can outlive the invocation that initialized it. Bind this
      # invocation's budget dynamically instead of reusing its captured one.
      let savedLexicalBudget = lexical.evalBudget
      lexical.evalBudget = invocationBudget
      try:
        let function = run(body, lexical)
        result = applyCall(function, arguments, NamedArgs(), lexical,
                           loc = definition.sourceLoc)
      finally:
        lexical.evalBudget = savedLexicalBudget
    finally:
      if budget != nil and invocationBudget != nil:
        budget.remaining = invocationBudget.remaining
      instance.scope.evalBudget = savedBudget
      state.activeBudget = previousBudget

macroEvaluator = evaluateMacroBody
