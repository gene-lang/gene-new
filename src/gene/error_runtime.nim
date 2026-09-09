## Runtime half of gradual error checking. Included by vm.nim so admission,
## retained protocol dispatch, and reporting use the ordinary call machinery.

proc `=destroy`(lease: var StrictErrorLeaseData) =
  for registration in lease.registrations:
    # The application keeps inactive index entries until its next sweep. Clear
    # the entire record so syntax, error rows, and native metadata release their
    # compiler/value graphs too. Detach before any nested destructor can run.
    var retired = move registration[]
    reset(retired)
  `=destroy`(lease.registrations)
  `=destroy`(lease.deferred)
  `=destroy`(lease.keep)

proc strictTargetParts(target: Value): seq[string] =
  if target.kind == vkSymbol:
    return @[target.symVal]
  if target.kind == vkNode and target.head.isSymbol("path"):
    for item in target.body:
      if item.kind notin {vkSymbol, vkString}: return @[]
      result.add(if item.kind == vkSymbol: item.symVal else: item.strVal)

proc strictCallableSignature(value: Value): Value =
  ## Reify just the closed signature, without retaining an executable/scope or
  ## installing another lease. The shared comparator remains authoritative.
  if value.kind != vkFunction or not (value.fnCode of FunctionProto): return NIL
  let original = FunctionProto(value.fnCode)
  let scope = value.fnScope
  let normalized = normalizeOptionalParameters(original, scope)
  let signature = FunctionProto(name: original.name, sourceLoc: original.sourceLoc,
    params: normalized.params, requiredPositional: normalized.requiredPositional,
    restParam: normalized.restParam)
  try:
    for typ in normalized.paramTypes: signature.paramTypes.add closeTypeExpr(typ, scope)
    for parameter in normalized.paramDefaults:
      signature.paramDefaults.add ParamDefault(optional: parameter.optional)
    for parameter in normalized.namedParams:
      signature.namedParams.add NamedParam(arg: parameter.arg, local: parameter.local,
        typeExpr: closeTypeExpr(parameter.typeExpr, scope),
        defaultValue: ParamDefault(optional: parameter.defaultValue.optional))
    signature.restType = closeTypeExpr(normalized.restType, scope)
    let resultType = if normalized.hasReturnType: normalized.returnType else: NIL
    signature.returnType = closeTypeExpr(resultType, scope)
  except GeneError:
    return NIL
  newFunction(value.fnName, value.fnParams, signature, nil,
              value.fnChecksErrors, value.fnErrorTypes)

proc withoutInvocationErrors(signature: Value): Value =
  if signature.kind != vkNode: return signature
  var props = initPropTable()
  for name, value in signature.props:
    if name != "errors": props[name] = value
  newNode(signature.head, props = props, body = signature.body)

proc strictDispatchSubject(registration: StrictErrorRegistration, value: Value): Value =
  result = value
  if value.kind == vkProtocolMessage and value.protocolMessageIsBound:
    if value.protocolMessageName != registration.messageName: return NIL
    result = value.protocolMessageQualifier
  for _ in 0 ..< registration.typeDepth:
    if result.kind != vkType: return NIL
    result = result.typeParent

proc strictProtocolMessage(protocol: Value, name: string): Value =
  if protocol.kind != vkProtocol: return NIL
  if protocol.protocolMessages.hasKey(name): return protocol.protocolMessages[name]
  let inherited = protocol.protocolClosureByName(name)
  if inherited.len == 1: inherited[0] else: NIL

proc strictDispatchSignature(subject: Value, name: string): Value =
  if subject.kind == vkType:
    return subject.typeDirectMessage(name)
  let message = strictProtocolMessage(subject, name)
  if message.kind == vkProtocolMessage: return message.protocolMessageSignatureFn
  NIL

proc pinStrictOrigin(registration: StrictErrorRegistration, origin: Scope) =
  if origin == nil: return
  var owned = cast[Scope](registration.declarationScope)
  while owned != nil:
    if owned == origin: return # already retained by the function's own scope
    owned = owned.parent
  if origin notin registration.scopePins: registration.scopePins.add origin

proc strictAllowedTypes(registration: StrictErrorRegistration, context: Scope):
    tuple[ok: bool, types: seq[Value]] =
  try:
    for item in registration.sourceAllowed.named:
      var typ = closeTypeExpr(item.expr, context)
      if typ.kind == vkSymbol and not context.lookupOptional(typ.symVal, typ): return
      if typ.kind notin {vkType, vkProtocol}: return
      result.types.add typ
    result.ok = true
  except GeneError:
    discard

proc strictMember(value: Value, path: openArray[string], application: Application = nil): Value =
  result = value
  for name in path:
    if result.kind == vkModule: result = result.moduleRootNamespace
    if result.kind != vkNamespace: return VOID
    if application != nil and result.nsScope.application() != application:
      return VOID # this application's mutation guards cannot protect foreign slots
    result = result.exportedBinding(name)
    if result.kind == vkVoid: return

proc strictPrefixContext(registration: StrictErrorRegistration,
                          path: seq[string], candidate: Value): Scope =
  let declaration = cast[Scope](registration.declarationScope)
  var originals: seq[Value]
  var value: Value
  if path.len > 1:
    if not declaration.lookupOptional(path[0], value): return nil
    for i in 0 ..< path.len - 1:
      if value.kind == vkModule: value = value.moduleRootNamespace
      if value.kind != vkNamespace: return nil
      originals.add value
      if i < path.len - 2: value = strictMember(value, [path[i + 1]])
  var replacement = candidate
  for i in countdown(path.len - 2, 0):
    let original = originals[i].nsScope
    original.materializeMirroredVars()
    let proxy = newScope(original.parent)
    proxy.exportExcludedNames = original.exportExcludedNames
    for name, member in original.vars: proxy.vars[name] = member
    proxy.vars[path[i + 1]] = replacement
    replacement = newNamespace(path[i], proxy)
  result = newScope(declaration)
  result.vars[path[0]] = replacement

proc resolveStrictRegistration(registration: StrictErrorRegistration): Value =
  let declaration = cast[Scope](registration.declarationScope)
  let parts = strictTargetParts(registration.target)
  if declaration == nil or parts.len == 0: return VOID
  if not registration.allowedReady:
    let allowed = registration.strictAllowedTypes(declaration)
    if allowed.ok:
      registration.allowed = allowed.types
      registration.allowedReady = true
  registration.prefixes = @[]
  var current = declaration
  while current != nil:
    if current.slotIndex(parts[0]) >= 0 or current.vars.hasKey(parts[0]): break
    current = current.parent
  if current == nil: current = declaration # a prospective local declaration
  var value: Value
  for i, name in parts:
    if i == parts.high:
      registration.targetScope = cast[pointer](current)
      registration.name = name
    else:
      registration.prefixes.add (scope: cast[pointer](current), name: name,
        path: parts[0..i], remaining: parts[i+1..^1])
    if i == 0:
      if not current.lookupOptional(name, value): return VOID
    else:
      current.materializeMirroredVars()
      if name in current.exportExcludedNames: return VOID
      value = current.vars.getOrDefault(name, VOID)
      if value.kind == vkVoid: return VOID
    if i < parts.high:
      if value.kind == vkModule: value = value.moduleRootNamespace
      if value.kind != vkNamespace: return VOID
      current = value.nsScope
  if not registration.allowedReady: return VOID
  if registration.typeIdentityOnly:
    let subject = registration.strictDispatchSubject(value)
    if subject.kind notin {vkType, vkProtocol}: return VOID
    if registration.subject.kind == vkNil:
      registration.subject = subject
      registration.pinStrictOrigin(if subject.kind == vkType: subject.typeScope
                                   else: subject.protocolScope)
  var callable = value
  if registration.messageName.len > 0:
    let subject = registration.strictDispatchSubject(value)
    if subject.kind notin {vkType, vkProtocol}: return VOID
    if registration.subject.kind == vkNil:
      registration.subject = subject
      let origin = if subject.kind == vkType: subject.typeScope else: subject.protocolScope
      registration.originScope = cast[pointer](origin)
      registration.originName = if subject.kind == vkType: subject.typeName else: subject.protocolName
      registration.pinStrictOrigin(origin)
    callable = strictDispatchSignature(subject, registration.messageName)
    if callable.kind == vkFunction: registration.pinStrictOrigin(callable.fnScope)
  if callable.kind == vkNativeFn and registration.baselineNative.kind == vkNil:
    registration.baselineNative = callable
  if callable.kind == vkFunction and registration.baselineSignature.kind == vkNil:
    registration.baselineSignature = strictCallableSignature(callable)
  if callable.kind == vkCallableView and registration.baselineViewSignature.kind == vkNil:
    registration.baselineViewSignature = callable.callableViewSignature
  registration.ready = true
  value

proc strictCandidateFits(registration: StrictErrorRegistration, value: Value): bool =
  if registration.typeIdentityOnly:
    let subject = registration.strictDispatchSubject(value)
    return subject.kind in {vkType, vkProtocol} and
      (registration.subject.kind == vkNil or same(subject, registration.subject))
  if registration.messageName.len > 0 and
      (value.kind in {vkType, vkProtocol} or
       (value.kind == vkProtocolMessage and value.protocolMessageIsBound)):
    let subject = registration.strictDispatchSubject(value)
    if registration.subject.kind != vkNil and not same(subject, registration.subject):
      return false # nominal/protocol identity is part of the dispatch proof
    let methodFn = strictDispatchSignature(subject, registration.messageName)
    if methodFn.kind == vkFunction and not methodFn.fnChecksErrors: return false
    if methodFn.kind notin {vkFunction, vkNativeFn}: return false
    return registration.strictCandidateFits(methodFn)
  if registration.nativeMetadata.identity.len > 0 and
      (value.kind != vkNativeFn or value.nativeErrorMetadata != registration.nativeMetadata):
    return false
  if registration.returnDepth > 0:
    if value.kind != vkFunction or not (value.fnCode of FunctionProto): return false
    let proto = FunctionProto(value.fnCode)
    let summary = proto.errorSummary
    if summary == nil or summary.returnContracts.len < registration.returnDepth: return false
    # A new inferred contract with mutable sources needs its own live guards.
    # Strict compilation installs those on the producer. Mere warning-mode
    # metadata is insufficient to protect a newly substituted producer's scope.
    if summary.dependencies.len > 0 and proto.errorsMode != ecmStrict: return false
    let contract = summary.returnContracts[registration.returnDepth - 1]
    if contract.kind != registration.returnKind: return false
    if registration.returnTaskFresh and not contract.taskFresh: return false
    if registration.returnTaskIsolated and not contract.taskIsolated: return false
    if contract.kind == "native":
      return contract.nativeMetadata.identity.len > 0 and
        contract.nativeMetadata == registration.returnNativeMetadata
    if contract.kind == "type":
      return contract.typeIdentity.len > 0 and
        contract.typeIdentity == registration.returnTypeIdentity and
        contract.typeContract == registration.returnTypeContract
    if contract.kind == "message" and (contract.messageIdentity.len == 0 or
        contract.messageIdentity != registration.returnMessageIdentity): return false
    if registration.returnKindOnly: return true
    if not contract.errorsKnown or contract.errors.open: return false
    var actual: seq[Value]
    try:
      for item in contract.errors.named:
        var typ = closeTypeExpr(item.expr, value.fnScope)
        if typ.kind == vkSymbol and not value.fnScope.lookupOptional(typ.symVal, typ): return false
        if typ.kind notin {vkType, vkProtocol}: return false
        actual.add typ
    except GeneError:
      return false
    return errorRowCovers(registration.allowed, actual)
  if value.kind == vkType:
    if not registration.constructorCall: return not value.isNativeWrapperType
    let ctor = value.typeConstructor
    if ctor.kind == vkNil:
      return errorRowCovers(registration.allowed,
        @[builtInTypeHead(value.typeScope, "RuntimeError")])
    return registration.strictCandidateFits(ctor)
  if value.kind == vkNativeFn:
    return registration.baselineNative.kind == vkNativeFn and
      value.bits == registration.baselineNative.bits
  var actual: seq[Value]
  if value.kind == vkCallableView:
    let signature = value.callableViewSignature
    if registration.baselineSignature.kind != vkNil: return false
    if registration.baselineViewSignature.kind != vkNil and not signatureTypeEqual(
        withoutInvocationErrors(registration.baselineViewSignature), withoutInvocationErrors(signature)):
      return false
    if not signature.props.hasKey("errors"): return false
    actual = signature.props["errors"].listItems
  elif value.kind == vkFunction and not value.isSyntaxFn:
    if registration.baselineViewSignature.kind != vkNil: return false
    if registration.baselineSignature.kind != vkNil:
      let signature = strictCallableSignature(value)
      if signature.kind == vkNil: return false
      let mismatch = callableSignatureMismatch(registration.baselineSignature, signature)
      if mismatch.len > 0 and mismatch != "checked error row": return false
    if value.fnChecksErrors:
      actual = value.fnErrorTypes
    else:
      if not (value.fnCode of FunctionProto): return false
      let summary = FunctionProto(value.fnCode).errorSummary
      if summary == nil or summary.inferredRow.open: return false
      for item in summary.inferredRow.named:
        var typ = closeTypeExpr(item.expr, value.fnScope)
        if typ.kind == vkSymbol and not value.fnScope.lookupOptional(typ.symVal, typ): return false
        if typ.kind notin {vkType, vkProtocol}: return false
        actual.add typ
  else:
    return false
  errorRowCovers(registration.allowed, actual)

proc addStrictDependencies(lease: StrictErrorLease, dependencies: seq[ErrorProofDependency],
                            scope: Scope, label: string, seen: var HashSet[string]) =
  let app = scope.application()
  proc outerDependencies(value: Value): seq[ErrorProofDependency] =
    let proto = FunctionProto(value.fnCode)
    if proto.errorSummary == nil: return
    for dependency in proto.errorSummary.dependencies:
      let parts = strictTargetParts(dependency.target)
      if proto.errorsMode == ecmStrict and parts.len > 0 and parts[0] in proto.localNames:
        # Its own activation lease validates locals when they are declared.
        # They are not slots in the producer's outer declaration scope.
        if parts[0] notin proto.params or
            (dependency.messageName.len == 0 and not dependency.typeIdentityOnly): continue
      result.add dependency
  for dependency in dependencies:
    if dependency.permitted.open: continue
    var key = $cast[uint](scope) & ":" & dependency.target.print() &
      ":" & $dependency.constructorCall & ":" & dependency.messageName &
      ":" & $dependency.typeDepth & ":" & dependency.nativeMetadata.identity &
      ":" & dependency.nativeMetadata.version & ":" & $dependency.returnDepth & ":" & dependency.returnKind
    key.add ":kind-only=" & $dependency.returnKindOnly
    key.add ":fresh-task=" & $dependency.returnTaskFresh
    key.add ":isolated-task=" & $dependency.returnTaskIsolated
    key.add ":native-result=" & dependency.returnNativeMetadata.identity & ":" & dependency.returnNativeMetadata.version &
      ":type-result=" & dependency.returnTypeIdentity & ":" & dependency.returnTypeContract &
      ":type-binding=" & $dependency.typeIdentityOnly & ":message-result=" & dependency.returnMessageIdentity
    for item in dependency.permitted.named: key.add ":" & item.identity
    if seen.containsOrIncl(key): continue
    let registration = StrictErrorRegistration(active: true,
      nativeMetadata: dependency.nativeMetadata,
      returnDepth: dependency.returnDepth, returnKind: dependency.returnKind,
      returnKindOnly: dependency.returnKindOnly,
      returnTaskFresh: dependency.returnTaskFresh,
      returnTaskIsolated: dependency.returnTaskIsolated,
      returnNativeMetadata: dependency.returnNativeMetadata,
      returnTypeIdentity: dependency.returnTypeIdentity, returnTypeContract: dependency.returnTypeContract,
      returnMessageIdentity: dependency.returnMessageIdentity,
      typeIdentityOnly: dependency.typeIdentityOnly,
      constructorCall: dependency.constructorCall,
      messageName: dependency.messageName, typeDepth: dependency.typeDepth,
      declarationScope: cast[pointer](scope), target: dependency.target,
      sourceAllowed: dependency.permitted, label: label)
    let target = registration.resolveStrictRegistration()
    if target.kind == vkVoid and registration.targetScope == nil:
      let parts = strictTargetParts(dependency.target)
      if parts.len == 1:
        registration.targetScope = cast[pointer](scope)
        registration.name = parts[0]
    lease.registrations.add registration
    app.strictErrorRegistrations.add registration
    if target.kind == vkFunction and (not target.fnChecksErrors or dependency.returnDepth > 0) and
        target.fnCode of FunctionProto:
      let summary = FunctionProto(target.fnCode).errorSummary
      if summary != nil:
        addStrictDependencies(lease, outerDependencies(target), target.fnScope, label, seen)
    elif target.kind == vkType and dependency.constructorCall:
      let ctor = target.typeConstructor
      if ctor.kind == vkFunction and not ctor.fnChecksErrors and ctor.fnCode of FunctionProto:
        let summary = FunctionProto(ctor.fnCode).errorSummary
        if summary != nil:
          addStrictDependencies(lease, outerDependencies(ctor), ctor.fnScope, label, seen)

proc strictInitializationLease(chunk: Chunk, scope: Scope): RootRef =
  if chunk == nil or chunk.errorsMode != ecmStrict or chunk.errorProofDependencies.len == 0:
    return nil
  let lease = StrictErrorLease()
  var seen = initHashSet[string]()
  addStrictDependencies(lease, chunk.errorProofDependencies, scope,
                        "module initialization", seen)
  for registration in lease.registrations:
    if registration.ready:
      let value = registration.resolveStrictRegistration()
      if not registration.strictCandidateFits(value):
        raise newException(GeneError, "strict initializer dependency requires revalidation: " &
          registration.target.print())
  lease

proc installStrictErrorLease(value: Value, scope: Scope) {.nimcall.} =
  if value.kind != vkFunction or not (value.fnCode of FunctionProto): return
  let proto = FunctionProto(value.fnCode)
  if proto.errorsMode != ecmStrict or proto.errorSummary == nil or
      proto.errorSummary.dependencies.len == 0: return
  let lease = StrictErrorLease()
  var immediate: seq[ErrorProofDependency]
  for dependency in proto.errorSummary.dependencies:
    let parts = strictTargetParts(dependency.target)
    if parts.len > 0 and parts[0] in proto.localNames:
      if parts[0] in proto.params:
        if dependency.messageName.len > 0 or dependency.typeIdentityOnly: immediate.add dependency
      else:
        lease.deferred.add dependency
    else:
      immediate.add dependency
  var seen = initHashSet[string]()
  addStrictDependencies(lease, immediate, scope, proto.name, seen)
  value.setFnErrorLease(lease)
  # A proof lease is continuation state. Keep it on a real activation scope,
  # including across suspension and while a binding is being replaced.
  proto.simpleCall = false
  proto.needsCallScope = true
  proto.scopelessChunk = nil
  proto.nativeOp = ncoNone

proc activateStrictErrorLease(value: Value, scope: Scope): RootRef =
  let original = StrictErrorLease(value.fnErrorLease)
  for registration in original.registrations:
    let target = registration.resolveStrictRegistration()
    if not registration.ready or target.kind == vkVoid:
      raise newException(GeneError, "strict error dependency is not ready: " &
        registration.target.print() & " in " & registration.label)
    if not registration.strictCandidateFits(target):
      raise newException(GeneError, "strict error assumption requires revalidation: " &
        registration.target.print() & " in " & registration.label)
  if original.deferred.len == 0: return original
  let activation = StrictErrorLease(keep: original)
  var seen = initHashSet[string]()
  addStrictDependencies(activation, original.deferred, scope, value.fnName, seen)
  activation

proc checkStrictBindingUpdate(scope: Scope, name: string, value: Value) =
  if scope == nil or scope.application == nil: return
  let app = scope.application()
  if app.strictErrorRegistrations.len == 0: return
  if app.strictErrorRegistrations.len > 256:
    var live: seq[StrictErrorRegistration]
    for registration in app.strictErrorRegistrations:
      if registration.active: live.add registration
    app.strictErrorRegistrations = live
  var moved: seq[StrictErrorRegistration]
  for registration in app.strictErrorRegistrations:
    if not registration.active: continue
    if not registration.ready: discard registration.resolveStrictRegistration()
    if registration.targetScope == cast[pointer](scope) and registration.name == name:
      if not registration.strictCandidateFits(value):
        raise newException(GeneError, "replacement of '" & name &
          "' broadens a retained strict error assumption in " & registration.label &
          "; revalidate the dependent code before publication")
    else:
      for prefix in registration.prefixes:
        if prefix.scope == cast[pointer](scope) and prefix.name == name:
          let target = strictMember(value, prefix.remaining, app)
          let context = registration.strictPrefixContext(prefix.path, value)
          let allowed = if context != nil: registration.strictAllowedTypes(context)
                        else: (ok: false, types: newSeq[Value]())
          let checking = StrictErrorRegistration()
          checking[] = registration[]
          checking.allowed = allowed.types
          if not allowed.ok or
              (registration.allowedReady and not errorRowsEquivalent(registration.allowed, allowed.types)) or
              not checking.strictCandidateFits(target):
            raise newException(GeneError, "replacement of namespace '" & name &
              "' requires revalidation of strict dependent " & registration.label)
          moved.add registration
  # The write follows this callback. Resolve these paths again on the next
  # update/call so a replacement namespace's member slots are protected too.
  for registration in moved: registration.ready = false

proc checkStrictScopeRemoval(app: Application, scope: Scope) =
  for registration in app.strictErrorRegistrations:
    if not registration.active: continue
    if not registration.ready: discard registration.resolveStrictRegistration()
    let target = cast[Scope](if registration.originScope != nil:
                              registration.originScope else: registration.targetScope)
    let owner = cast[Scope](registration.declarationScope)
    if target != nil and target.moduleRootScope() == scope.moduleRootScope() and
        (owner == nil or owner.moduleRootScope() != scope.moduleRootScope()):
      raise newException(GeneError, "module replacement/removal affects strict dependent " &
        registration.label & "; revalidate it before publication")

proc checkStrictScopeReplacement(app: Application, previous, replacement: Scope) =
  proc corresponding(oldScope, newScope, wanted: Scope): Scope =
    if oldScope == wanted: return newScope
    oldScope.materializeMirroredVars()
    newScope.materializeMirroredVars()
    for name, value in oldScope.vars:
      if value.kind != vkNamespace or not newScope.vars.hasKey(name): continue
      let fresh = newScope.vars[name]
      if fresh.kind != vkNamespace: continue
      let found = corresponding(value.nsScope, fresh.nsScope, wanted)
      if found != nil: return found
  for registration in app.strictErrorRegistrations:
    if not registration.active: continue
    if not registration.ready: discard registration.resolveStrictRegistration()
    let byOrigin = registration.originScope != nil
    let target = cast[Scope](if byOrigin: registration.originScope else: registration.targetScope)
    if target == nil or target.moduleRootScope() != previous.moduleRootScope(): continue
    let fresh = corresponding(previous, replacement, target)
    var value: Value
    let name = if byOrigin: registration.originName else: registration.name
    var fits = fresh != nil and fresh.lookupOptional(name, value)
    if fits and byOrigin:
      # Origin lookup is already at the declaring ancestor, not its imported
      # descendant alias. Do not apply the caller's parent steps a second time.
      fits = same(value, registration.subject) and
        registration.strictCandidateFits(strictDispatchSignature(value, registration.messageName))
    elif fits:
      fits = registration.strictCandidateFits(value)
    if not fits:
      raise newException(GeneError, "module replacement broadens a retained strict error assumption in " &
        registration.label & "; revalidate the dependent before publication")

proc checkStrictImplChanges(app: Application, canonical: seq[ProtocolImpl],
                            scopes: seq[ImplScopeUpdate]) =
  if app.strictErrorRegistrations.len == 0: return
  let root = app.builtinsScope()
  proc visible(scope: Scope, prospective: bool): seq[ProtocolImpl] =
    var current = scope
    while current != nil:
      var implementations = current.impls
      if prospective:
        if current == root: implementations = canonical
        else:
          for update in scopes:
            if update.scope == current:
              implementations = update.impls
              break
      result.add implementations
      current = current.parent
  for registration in app.strictErrorRegistrations:
    if not registration.active or registration.messageName.len == 0: continue
    if not registration.ready: discard registration.resolveStrictRegistration()
    let protocol = registration.subject
    let message = strictProtocolMessage(protocol, registration.messageName)
    if message.kind != vkProtocolMessage: continue
    let declaration = cast[Scope](registration.declarationScope)
    let future = visible(declaration, true)
    # Keep each concrete message/receiver provider represented by this proof.
    # A replacement body can differ while retaining the checked contract;
    # removing its dispatch identity requires dependent revalidation.
    for existing in visible(declaration, false):
      var original: Value
      for entry in existing.messages:
        if same(entry.message, message): original = entry.fn
      if original.kind == vkNil: continue
      var preserved = false
      for replacement in future:
        if not same(replacement.receiver, existing.receiver): continue
        for entry in replacement.messages:
          if same(entry.message, message):
            # Assembly already compares the full, Self-substituted signature.
            # Here compare error coverage, not an abstract protocol's Self
            # parameter against a concrete implementation parameter.
            if same(entry.fn, original) or
                (entry.fn.kind == vkFunction and entry.fn.fnChecksErrors and
                 errorRowCovers(registration.allowed, entry.fn.fnErrorTypes)):
              preserved = true
      if not preserved:
        raise newException(GeneError,
          "impl replacement/removal invalidates strict dependent " & registration.label &
          " at " & protocol.protocolName & ":" & registration.messageName &
          " for " & existing.receiver.typeName & "; revalidate it before publication")

proc buildErrorProtocol(root: Scope): Value =
  let compiled = compileSource(
    "(fn message [self] : Str ^errors [] self/message)",
    sourceName = "<builtin Error:message>")
  let proto = compiled.functions[0]
  proto.builtinErrorMessage = true
  let formatter = newFunction("Error:message", @["self"], proto, root,
                               checksErrors = true)
  let stored = functionForScopeStorage(formatter, root)
  root.application().errorDefaultMessage = stored
  newProtocol("Error", ["message"], signatures = [stored],
    hasDefaults = [true], scope = root, errorRoot = true)

proc normalizeErrorTypes(scope: Scope, expressions: openArray[Value]): seq[Value] =
  var collected: seq[Value]
  proc add(expression: Value, depth: int) =
    if depth > 64: raise newException(GeneError, "recursive alias in error row")
    var typ = closeTypeExpr(expression, scope)
    if typ.isSymbol("Never"): return
    if typ.kind == vkSymbol: typ = scope.lookup(typ.symVal)
    if typ.isTypeAlias:
      add(typ.typeAliasExpr, depth + 1)
      return
    if typ.kind == vkNode and typ.head.isSymbol("|"):
      for member in typ.body: add(member, depth + 1)
      return
    if not scope.isErrorType(typ):
      raise newException(GeneError, "^errors entries must be Error types")
    let stored = if expression.isBorrowedTypeAnnotation: expression else: typ
    for existing in collected:
      if signatureTypeEqual(existing, stored): return
    collected.add stored
  for expression in expressions: add(expression, 0)
  collected

proc usesDefaultErrorMessage(formatter: Value, app: Application): bool =
  discard app
  formatter.kind == vkFunction and formatter.fnCode of FunctionProto and
    FunctionProto(formatter.fnCode).builtinErrorMessage

proc validateDefaultErrorBacking(receiver, formatter: Value, scope: Scope) =
  if not formatter.usesDefaultErrorMessage(scope.application()): return
  # Opaque native representations are checked without invoking the formatter
  # at admission. An ordinary source schema must prove a required Str field.
  if receiver.isNativeWrapperType: return
  var current = receiver
  while current.kind == vkType:
    for field in current.typeFields:
      if field.name != "message": continue
      let declaring = if field.scope != nil: field.scope
                      elif field.weakScope != nil: cast[Scope](field.weakScope)
                      else: scope
      let typ = closeTypeExpr(field.typeExpr, declaring)
      if not field.optional and
          (signatureTypeEqual(typ, newSym("Str")) or
           same(typ, builtinBinding(scope, "Str"))):
        return
      raise newException(GeneError,
        "default Error:message requires a required Str message property on " &
        receiver.typeName & "; provide a custom Error:message implementation")
    current = current.typeParent
  raise newException(GeneError,
    "default Error:message requires a required Str message property on " &
    receiver.typeName & "; provide a custom Error:message implementation")

proc checkErrorFormatterLane(value, formatter: Value, scope: Scope) =
  if currentEventLane() != currentScheduler().rootLane:
    var seen = initHashSet[uint64]()
    if not isSendableValue(formatter, scope, seen, csmWorker):
      # Do not install a new hidden edge to non-Send state on a shared node.
      # Keep the rejected original value in the generated admission diagnostic.
      raiseTypeError("Error admission", "Error with a Send-safe formatter", value, scope)

proc retainedErrorFormatter(value: Value, scope: Scope): Value =
  result = value.errorEvidence.formatter
  checkErrorFormatterLane(value, result, scope)

proc admitErrorValue(value: Value, scope: Scope): Value =
  if value.hasErrorWitness:
    discard retainedErrorFormatter(value, scope)
    return value
  if scope == nil:
    let context = if activeVmScope != nil: activeVmScope[] else: builtinsScope()
    return admitErrorValue(value, context)
  let app = scope.application()
  let protocol = builtinBinding(scope, "Error")
  let sourceScope = if value.generatedFailure: app.builtinsScope() else: scope
  if value.generatedFailure:
    # Generated diagnostics have known built-in conformance. Resolving a
    # pending/failed user impl assembly here could recursively fail admission.
    value.installErrorWitness(protocol, app.errorDefaultMessage, app.builtinsScope())
    return value
  let builtin = value.kind == vkNode and value.head.kind == vkType and
    value.head.typeScope == app.builtinsScope()
  if value.kind != vkNode or value.head.kind != vkType or
      (not builtin and not sourceScope.typeImplementsProtocol(value.head, protocol)):
    raiseTypeError("Error admission", "value implementing Error", value, scope)
  var formatter: Value
  try:
    if builtin:
      # Built-in diagnostics must remain admissible in restricted roots and
      # after an execution budget expires. No user code or assembly is needed.
      var matches: seq[Value]
      var bestDepth = -1
      var current = sourceScope
      while current != nil:
        current.collectProtocolMatches(value.head, protocol.protocolMessages["message"],
                                         bestDepth, matches)
        current = current.parent
      if matches.len == 0:
        app.builtinsScope().collectProtocolMatches(value.head,
          protocol.protocolMessages["message"], bestDepth, matches)
      matches.dedupeProtocolMatches()
      if matches.len == 1: formatter = matches[0]
      else: raise newException(GeneError, "ambiguous built-in Error conformance")
    else:
      formatter = resolveProtocolMessage(sourceScope,
        protocol.protocolMessages["message"], value)
  except GeneError as resolution:
    raiseTypeError("Error admission", "unambiguous Error conformance", value, scope,
                   hint = resolution.msg)
  if formatter.usesDefaultErrorMessage(app):
    let backing = value.props.getOrDefault("message", VOID)
    if backing.kind != vkString:
      raiseTypeError("Error admission message", "present Str property", backing, scope)
  checkErrorFormatterLane(value, formatter, scope)
  if formatter.kind == vkFunction:
    let environment = formatter.fnScope
    value.installErrorWitness(protocol, functionForScopeStorage(formatter, environment), environment)
  else:
    value.installErrorWitness(protocol, formatter, sourceScope)
  value

proc normalizeFailure(error: ref GeneError, scope: Scope): ref GeneError =
  let context = if scope != nil: scope
                elif activeVmScope != nil: activeVmScope[] else: builtinsScope()
  result = error
  if not error.hasErrVal:
    error.errVal = runtimeErrorValue(context, error.msg)
    error.hasErrVal = true
  try:
    error.errVal = admitErrorValue(error.errVal, context)
  except GeneError as admission:
    # Admission failures are generated TypeErrors. Admit their known built-in
    # formatter in the built-ins scope, never through the rejected local impl.
    result = admission
    if admission.hasErrVal:
      discard admitErrorValue(admission.errVal, context.application().builtinsScope())

proc makeErrorContractViolation(error: ref GeneError, allowed: seq[Value],
                                name: string, scope: Scope): ref GeneError =
  if error.hasErrVal and error.errVal.generatedFailure:
    return error
  let message = "function '" & name & "' raised an undeclared error"
  var props = initPropTable()
  props["message"] = newStr(message)
  props["where"] = newStr(name)
  props["expected"] = newList(allowed, immutable = true)
  props["actual"] = error.errVal.head
  props["cause"] = error.errVal
  let value = newNode(builtInTypeHead(scope, "ErrorContractViolation"), props = props)
  value.setFailureClassification(fcGeneratedContractViolation)
  discard admitErrorValue(value, scope)
  result = newException(GeneError, message)
  result.errVal = value
  result.hasErrVal = true
  result.loc = error.loc

proc enforceDeferredErrors(value, errorType: Value, where: string, scope: Scope) =
  if errorType.kind == vkNil or value.generatedFailure:
    return
  let context = if scope != nil: scope
                elif activeVmScope != nil: activeVmScope[] else: builtinsScope()
  let admitted = admitErrorValue(value, context)
  if matchesTypeExpr(errorType, admitted, context): return
  let error = newException(GeneError, "deferred error exceeded its contract")
  error.errVal = admitted
  error.hasErrVal = true
  raise makeErrorContractViolation(error, @[closeTypeExpr(errorType, context)],
                                    where, context)

proc errorDisplayMessage*(error: ref GeneError, scope: Scope): string =
  ## Formatting is terminal observation, not error admission. A broken custom
  ## formatter never replaces the original failure or recursively formats its
  ## own failure. `$err_msg` itself has no such fallback.
  let failure = normalizeFailure(error, scope)
  let value = failure.errVal
  if value.hasErrorWitness:
    try:
      let text = applyCall(retainedErrorFormatter(value, scope), [value], NamedArgs(), scope)
      if text.kind == vkString: return text.strVal
    except CatchableError:
      discard
  if error.msg.len > 0: return error.msg
  if value.kind == vkNode and value.head.kind == vkType:
    return "failure of " & value.head.typeName
  "ordinary error"

proc errorDiagnosticMessage*(error: ref GeneError, scope: Scope): string =
  ## Terminal diagnostics retain the nominal label while obtaining display
  ## text from the Error protocol. Untyped/compiler diagnostics keep their
  ## existing text; the generic RuntimeError label would add no information.
  let label =
    if error.hasErrVal and error.errVal.kind == vkNode and
        error.errVal.head.kind == vkType and
        error.errVal.head.typeName != "RuntimeError": error.errVal.head.typeName
    else: ""
  let message = errorDisplayMessage(error, scope)
  if label.len > 0 and not message.startsWith(label & ":"):
    label & ": " & message
  else:
    message
