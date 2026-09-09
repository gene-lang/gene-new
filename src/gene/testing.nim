## Assertions and the native-VM test runner. Included by vm.nim so callbacks
## use its ordinary call, type matching, error, and authority machinery.

proc testCallScope(call: ptr NativeCall): Scope =
  if call == nil or call.dispatchScope == nil:
    raise newException(GeneError, "testing operation requires a caller scope")
  call.dispatchScope

proc testMessage(args: openArray[Value], at: int, fallback: string,
                 scope: Scope): string =
  if args.len == at or args[at].kind == vkNil:
    return fallback
  if args[at].kind != vkString:
    raiseTypeError("assertion message", "Str?", args[at], scope)
  args[at].strVal

proc raiseAssertion(message: string, call: ptr NativeCall,
                    comparison = false, actual = NIL, expected = NIL) =
  let scope = testCallScope(call)
  var props = initPropTable()
  props["message"] = newStr(message)
  if comparison:
    props["has_comparison"] = TRUE
    # Preserve operand availability across property/exception boundaries that
    # normalize Void by removing its property.
    props["actual_present"] = TRUE
    props["expected_present"] = TRUE
    props["actual"] = actual
    props["expected"] = expected
  let error = newException(GeneError, message)
  error.errVal = newNode(builtInTypeHead(scope, "AssertionError"), props = props)
  error.hasErrVal = true
  error.attachSourceLoc(call.loc)
  raise error

proc biAssert(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = testCallScope(call)
  if args.len notin 1..2:
    raise newException(GeneError, "assert expects a condition and optional message")
  let message = testMessage(args, 1, "assertion failed", scope)
  if not args[0].isTruthy:
    raiseAssertion(message, call)
  NIL

proc biAssertEqual(args: openArray[Value],
                   call: ptr NativeCall): Value {.nimcall.} =
  let scope = testCallScope(call)
  if args.len notin 2..3:
    raise newException(GeneError,
      "test/assert_equal expects actual, expected, and an optional message")
  let message = testMessage(args, 2, "values are not equal", scope)
  if not equal(args[0], args[1]):
    raiseAssertion(message, call, true, args[0], args[1])
  NIL

proc biAssertRaises(args: openArray[Value],
                    call: ptr NativeCall): Value {.nimcall.} =
  let scope = testCallScope(call)
  if args.len notin 2..3:
    raise newException(GeneError,
      "test/assert_raises expects a callable, error type, and optional message")
  let message = testMessage(args, 2, "expected an error, but the call returned", scope)
  if not valueImplementsCallable(args[0], scope):
    raiseTypeError("test/assert_raises", "Callable", args[0], scope)
  if args[1].kind notin {vkType, vkProtocol}:
    raiseTypeError("test/assert_raises error_type", "Type or Protocol", args[1], scope)
  try:
    discard applyCall(args[0], [], NamedArgs(), scope, loc = call.loc)
  except GeneError as error:
    let value = normalizeFailure(error, scope).errVal
    if matchesTypeExpr(args[1], value, scope):
      return value
    raise
  raiseAssertion(message, call)

proc testingRegistry(scope: Scope): TestRegistry =
  var laneCall = NativeCall(dispatchScope: scope)
  discard biRuntimeRequireRootLane([], addr laneCall)
  let app = scope.application()
  if app.tests == nil:
    app.tests = TestRegistry()
  app.tests

proc testLocationValue(loc: SourceLoc): Value =
  var props = initPropTable()
  props["file"] = newStr(loc.sourceName)
  props["line"] = newInt(loc.line)
  props["col"] = newInt(loc.col)
  newMap(props, immutable = true)

proc testDisplayValue(value: Value): string

proc testDiagnostic(error: ref GeneError, phase: string,
                    scope: Scope, fallback: SourceLoc): Value =
  var props = initPropTable()
  let value = if error.hasErrVal: error.errVal
              else: runtimeErrorValue(scope, error.msg)
  props["error_type"] = if value.kind == vkNode: value.head
                        else: builtInTypeHead(scope, "RuntimeError")
  props["message"] = newStr(errorDisplayMessage(error, scope))
  props["phase"] = newStr(phase)
  props["assertion"] = newBool(matchesTypeExpr(
    builtInTypeHead(scope, "AssertionError"), value, scope))
  props["location"] = testLocationValue(
    if error.loc.hasSourceLoc: error.loc else: fallback)
  if value.kind == vkNode:
    # Snapshot display data at the failure, before teardown can mutate operands.
    # Results do not retain arbitrary fixture graphs (including their cycles).
    if value.props.getOrDefault("has_comparison", FALSE).isTruthy:
      for key in ["actual", "expected"]:
        props[key] = newStr(if value.props.hasKey(key):
          testDisplayValue(value.props[key])
          elif value.props.getOrDefault(key & "_present", FALSE).isTruthy: "void"
          else: "<unavailable>")
    let diagnosticProps = value.errorProperties()
    if diagnosticProps.hasKey("trace"):
      props["trace"] = newStr(testDisplayValue(diagnosticProps["trace"]))
  newMap(props, immutable = true)

proc checkTestRegistration(registry: TestRegistry) =
  if registry.running:
    raise newException(GeneError, "cannot register tests during a test run")

proc testCallback(params, fn: Value, loc: SourceLoc): TestCallback =
  if params.kind != vkList or params.listItems.len > 1 or
      (params.listItems.len == 1 and
       (params.listItems[0].kind != vkSymbol or
        params.listItems[0].symVal.endsWith("..."))):
    raise newException(GeneError, "test body parameters must be [] or [name]")
  if fn.kind != vkFunction or fn.isSyntaxFn:
    raise newException(GeneError, "test body requires an ordinary function")
  let capture = fn.fnScope
  TestCallback(fn: functionForScopeStorage(fn, capture), capture: capture,
    takesContext: params.listItems.len == 1, loc: loc)

proc biTestRegisterGroup(args: openArray[Value],
                         call: ptr NativeCall): Value {.nimcall.} =
  let scope = testCallScope(call)
  let registry = testingRegistry(scope)
  registry.checkTestRegistration()
  try:
    if args.len != 2:
      raise newException(GeneError, "test/register_group expects a description and body")
    requireStr("test group description", args[0])
    if args[1].kind != vkFunction or args[1].isSyntaxFn:
      raise newException(GeneError, "test group body requires an ordinary function")
    let group = TestEntry(description: args[0].strVal, loc: call.loc, isGroup: true)
    if registry.groups.len == 0:
      registry.roots.add group
    else:
      registry.groups[^1].children.add group
    registry.groups.add group
    try:
      discard applyCall(args[1], [], NamedArgs(), scope, loc = call.loc)
    finally:
      registry.groups.setLen(registry.groups.len - 1)
  except GeneError as error:
    if registry.diagnostics.len == 0:
      registry.diagnostics.add testDiagnostic(error, "registration", scope, call.loc)
    raise
  NIL

proc biTestRegisterExample(args: openArray[Value],
                           call: ptr NativeCall): Value {.nimcall.} =
  let scope = testCallScope(call)
  let registry = testingRegistry(scope)
  registry.checkTestRegistration()
  try:
    if registry.groups.len == 0:
      raise newException(GeneError, "it requires an active describe/context group")
    if args.len != 4:
      raise newException(GeneError, "test/register_example expects four arguments")
    requireStr("test example description", args[0])
    if args[3].kind != vkVoid and
        (args[3].kind != vkString or args[3].strVal.len == 0):
      raise newException(GeneError, "it ^skip requires a nonempty literal string")
    let callback = testCallback(args[1], args[2], call.loc)
    registry.groups[^1].children.add TestEntry(description: args[0].strVal,
      loc: call.loc, body: callback,
      skipReason: if args[3].kind == vkVoid: "" else: args[3].strVal)
  except GeneError as error:
    if registry.diagnostics.len == 0:
      registry.diagnostics.add testDiagnostic(error, "registration", scope, call.loc)
    raise
  NIL

proc biTestRegisterHook(args: openArray[Value],
                        call: ptr NativeCall): Value {.nimcall.} =
  let scope = testCallScope(call)
  let registry = testingRegistry(scope)
  registry.checkTestRegistration()
  try:
    if registry.groups.len == 0:
      raise newException(GeneError, "test hooks require an active describe/context group")
    if args.len != 3 or args[0].kind != vkString or
        args[0].strVal notin ["before_each", "after_each"]:
      raise newException(GeneError, "invalid test hook registration")
    let callback = testCallback(args[1], args[2], call.loc)
    if args[0].strVal == "before_each":
      registry.groups[^1].beforeEach.add callback
    else:
      registry.groups[^1].afterEach.add callback
  except GeneError as error:
    if registry.diagnostics.len == 0:
      registry.diagnostics.add testDiagnostic(error, "registration", scope, call.loc)
    raise
  NIL

proc testDisplayValue(value: Value): string =
  ## Diagnostic rendering must neither invoke user methods nor recurse forever
  ## into a cyclic value. Bound traversal as well as the final string size.
  var seen = initHashSet[uint64]()
  var remaining = 1200
  var output = ""
  proc add(s: string) =
    if remaining > 0:
      let n = min(remaining, s.len)
      output.add s[0..<n]
      remaining -= n
  proc render(v: Value, depth: int) =
    if remaining <= 0: return
    if depth >= 12:
      add("...")
      return
    let container = v.kind in {vkList, vkMap, vkSet, vkHashMap, vkNode}
    if container:
      if v.bits in seen:
        add("<cycle>")
        return
      seen.incl v.bits
    defer:
      if container: seen.excl v.bits
    case v.kind
    of vkList, vkSet:
      add(if v.kind == vkList: "[" else: "(Set ")
      let items = if v.kind == vkList: v.listItems else: v.setItems
      for i, item in items:
        if remaining <= 0: break
        if i > 0: add(" ")
        render(item, depth + 1)
      add(if v.kind == vkList: "]" else: ")")
    of vkMap, vkNode:
      add(if v.kind == vkMap: "{" else: "(")
      if v.kind == vkNode: render(v.head, depth + 1)
      let entries = if v.kind == vkMap: v.mapEntries else: v.props
      for key, item in entries:
        if remaining <= 0: break
        add(" ^" & key & " ")
        render(item, depth + 1)
      if v.kind == vkNode:
        for item in v.body:
          if remaining <= 0: break
          add(" ")
          render(item, depth + 1)
      add(if v.kind == vkMap: "}" else: ")")
    of vkHashMap:
      add("{{")
      for entry in v.hashMapEntries:
        if remaining <= 0: break
        render(entry.key, depth + 1)
        add(" : ")
        render(entry.val, depth + 1)
        add(" ")
      add("}}")
    of vkString:
      add(print(newStr(v.strVal[0..<min(v.strVal.len, remaining)])))
    of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkChar, vkSymbol, vkType,
       vkProtocol, vkFunction, vkNativeFn:
      add(print(v))
    else:
      add("<" & $v.kind & ">")
  render(value, 0)
  if remaining == 0: output.add "..."
  output

proc formatTestReport*(resultValue: Value): string =
  proc renderDiagnostic(diagnostic: Value): string =
    let entries = diagnostic.mapEntries
    let location = entries["location"].mapEntries
    result = "    " & entries["phase"].strVal & ": " &
      entries["message"].strVal & "\n"
    if location["file"].strVal.len > 0:
      result.add "      at " & location["file"].strVal & ":" &
        $location["line"].intVal & ":" & $location["col"].intVal & "\n"
    if entries.hasKey("expected"):
      result.add "      expected: " & entries["expected"].strVal & "\n"
      result.add "        actual: " & entries["actual"].strVal & "\n"
  let props = resultValue.props
  for example in props["examples"].listItems:
    let entries = example.mapEntries
    result.add "[" & entries["status"].strVal & "] " & entries["name"].strVal
    if entries.hasKey("reason"): result.add " (" & entries["reason"].strVal & ")"
    result.add "\n"
    for diagnostic in entries["diagnostics"].listItems:
      result.add renderDiagnostic(diagnostic)
  for diagnostic in props["diagnostics"].listItems:
    result.add renderDiagnostic(diagnostic)
  result.add $props["passed"].intVal & " passed, " &
    $props["failed"].intVal & " failed, " & $props["errors"].intVal &
    " errors, " & $props["skipped"].intVal & " skipped\n"
  if props["exit_code"].intVal == 2:
    result.add "No examples selected.\n"

proc runTests*(scope: Scope, name = "", report = true): Value =
  let registry = testingRegistry(scope)
  if registry.running:
    raise newException(GeneError, "a test run is already in progress")
  if registry.groups.len > 0 or registry.collecting:
    raise newException(GeneError, "cannot run tests during registration")
  registry.running = true
  defer: registry.running = false
  let roots = registry.roots
  var examples: seq[Value]
  var passed, failed, errors, skipped: int
  proc invoke(callback: TestCallback, context: Value) =
    if callback.takesContext:
      discard applyCall(callback.fn, [context], NamedArgs(), scope, loc = callback.loc)
    else:
      discard applyCall(callback.fn, [], NamedArgs(), scope, loc = callback.loc)
  proc runExample(entry: TestEntry, groups: seq[TestEntry], fullName: string) =
    if name.len > 0 and name notin fullName: return
    var diagnostics: seq[Value]
    var status = "passed"
    if entry.skipReason.len > 0:
      status = "skipped"
      inc skipped
    else:
      let context = newMap()
      var entered = 0
      var setupOk = true
      try:
        for group in groups:
          inc entered
          for hook in group.beforeEach:
            try: invoke(hook, context)
            except GeneError as error:
              diagnostics.add testDiagnostic(error, "before_each", scope, hook.loc)
              setupOk = false
              break
          if not setupOk: break
        if setupOk:
          try: invoke(entry.body, context)
          except GeneError as error:
            diagnostics.add testDiagnostic(error, "example", scope, entry.loc)
      finally:
        for i in countdown(entered - 1, 0):
          for j in countdown(groups[i].afterEach.len - 1, 0):
            let hook = groups[i].afterEach[j]
            try: invoke(hook, context)
            except GeneError as error:
              diagnostics.add testDiagnostic(error, "after_each", scope, hook.loc)
      for diagnostic in diagnostics:
        if not diagnostic.mapEntries["assertion"].boolVal:
          status = "error"
          break
        status = "failed"
      case status
      of "passed": inc passed
      of "failed": inc failed
      else: inc errors
    var props = initPropTable()
    props["name"] = newStr(fullName)
    props["status"] = newStr(status)
    props["location"] = testLocationValue(entry.loc)
    props["diagnostics"] = newList(diagnostics, immutable = true)
    if entry.skipReason.len > 0: props["reason"] = newStr(entry.skipReason)
    examples.add newMap(props, immutable = true)
  proc visit(entry: TestEntry, groups: seq[TestEntry], prefix: string) =
    let fullName = if prefix.len == 0: entry.description
                   else: prefix & " " & entry.description
    if entry.isGroup:
      let ancestors = groups & @[entry]
      for child in entry.children: visit(child, ancestors, fullName)
    else:
      runExample(entry, groups, fullName)
  if registry.diagnostics.len == 0:
    for root in roots: visit(root, @[], "")
  var props = initPropTable()
  props["passed"] = newInt(passed)
  props["failed"] = newInt(failed)
  props["errors"] = newInt(errors)
  props["skipped"] = newInt(skipped)
  props["examples"] = newList(examples, immutable = true)
  props["diagnostics"] = newList(registry.diagnostics, immutable = true)
  props["exit_code"] = newInt(
    if failed + errors > 0 or registry.diagnostics.len > 0: 1
    elif examples.len == 0: 2
    else: 0)
  result = newNode(builtInTypeHead(scope, "TestResult"), props = props, immutable = true)
  if report:
    discard biPrint([newStr(formatTestReport(result))])

proc beginTestCollection*(scope: Scope) =
  let registry = testingRegistry(scope)
  if registry.running or registry.collecting:
    raise newException(GeneError, "test collection is already active")
  registry.collecting = true

proc finishTestCollection*(scope: Scope) =
  testingRegistry(scope).collecting = false

proc recordTestCollectionError*(scope: Scope, error: ref GeneError) =
  let registry = testingRegistry(scope)
  if registry.diagnostics.len == 0:
    registry.diagnostics.add testDiagnostic(error, "collection", scope, error.loc)

proc biTestRun(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = testCallScope(call)
  if args.len != 0:
    raise newException(GeneError, "test/run expects no positional arguments")
  var name = ""
  var report = true
  for i, key in call.namedNames:
    let value = call.namedValues[i]
    case key
    of "name":
      requireStr("test/run ^name", value)
      name = value.strVal
    of "report":
      if value.kind != vkBool:
        raiseTypeError("test/run ^report", "Bool", value, scope)
      report = value.boolVal
    else:
      raise newException(GeneError, "test/run got unexpected named argument: " & key)
  runTests(scope, name, report)

proc registerTestingNamespace(root: Scope) =
  let errorProtocol = root.vars["Error"]
  let assertionType = newType("AssertionError", NIL,
    @[TypeField(name: "message", typeExpr: newSym("Str"), scope: root),
      TypeField(name: "has_comparison", typeExpr: newSym("Bool"), optional: true, scope: root),
      TypeField(name: "actual_present", typeExpr: newSym("Bool"), optional: true, scope: root),
      TypeField(name: "expected_present", typeExpr: newSym("Bool"), optional: true, scope: root),
      TypeField(name: "actual", typeExpr: newSym("Any"), optional: true, scope: root),
      TypeField(name: "expected", typeExpr: newSym("Any"), optional: true, scope: root)],
    @[errorProtocol], root)
  root.define("AssertionError", assertionType)
  root.impls.add ProtocolImpl(protocol: errorProtocol, receiver: assertionType)
  var fields: seq[TypeField]
  for name in ["passed", "failed", "errors", "skipped", "exit_code"]:
    fields.add TypeField(name: name, typeExpr: newSym("Int"), scope: root)
  for name in ["examples", "diagnostics"]:
    fields.add TypeField(name: name, typeExpr: newSym("List"), scope: root)
  let resultType = newType("TestResult", NIL, fields, @[], root)
  root.define("TestResult", resultType)
  root.define("assert", builtinNativeCallFn("assert", biAssert, acceptsNamed = false))
  let ns = newScope(root)
  ns.define("AssertionError", assertionType)
  ns.define("TestResult", resultType)
  ns.define("assert_equal", builtinNativeCallFn("test/assert_equal", biAssertEqual,
                                           acceptsNamed = false))
  ns.define("assert_raises", builtinNativeCallFn("test/assert_raises", biAssertRaises,
                                            acceptsNamed = false))
  ns.define("register_group", newNativeCallFn("test/register_group",
    biTestRegisterGroup, acceptsNamed = false))
  ns.define("register_example", newNativeCallFn("test/register_example",
    biTestRegisterExample, acceptsNamed = false))
  ns.define("register_hook", newNativeCallFn("test/register_hook",
    biTestRegisterHook, acceptsNamed = false))
  ns.define("run", newNativeCallFn("test/run", biTestRun))
  root.define("test", newNamespace("test", ns))
