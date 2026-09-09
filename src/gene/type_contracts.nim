## Shared normalized callable-contract policy for the VM and static backends.
## Declaration/conformance assembly supplies already resolved type identities.
import std/algorithm
import ./[diagnostics, equality, gir, printer, types]

proc isSymbol(value: Value, name: string): bool {.inline.} =
  value.kind == vkSymbol and value.symVal == name

proc typeExprHasCommutativeHead(expr: Value): bool =
  case expr.kind
  of vkNode:
    if expr.head.isSymbol("&") or expr.head.isSymbol("|"): return true
    for item in expr.body:
      if typeExprHasCommutativeHead(item): return true
    for _, item in expr.props:
      if typeExprHasCommutativeHead(item): return true
  of vkList:
    for item in expr.listItems:
      if typeExprHasCommutativeHead(item): return true
  of vkMap:
    for _, item in expr.mapEntries:
      if typeExprHasCommutativeHead(item): return true
  else: discard

proc typeOperandKey(expr: Value): string =
  # Distinct declarations can share a printed name. Identity breaks those ties
  # recursively without depending on the allocation address of syntax nodes.
  case expr.kind
  of vkType, vkProtocol: result = expr.print() & ":" & $expr.bits
  of vkNode:
    result = "(" & typeOperandKey(expr.head)
    for item in expr.body: result.add " " & typeOperandKey(item)
    var props: seq[string]
    for key, item in expr.props: props.add key & ":" & typeOperandKey(item)
    props.sort()
    for item in props: result.add " ^" & item
    result.add ")"
  of vkList:
    result = "["
    for item in expr.listItems: result.add " " & typeOperandKey(item)
    result.add "]"
  of vkMap:
    var entries: seq[string]
    for key, item in expr.mapEntries: entries.add key & ":" & typeOperandKey(item)
    entries.sort()
    result = "{"
    for item in entries: result.add " " & item
    result.add "}"
  else: result = expr.print()

proc sortTypeExprOperands*(operands: var seq[Value]) =
  ## Structural keys include nominal identity and are computed once per operand.
  ## Same-named declarations therefore normalize independently of source order.
  if operands.len < 2:
    return
  var keyed: seq[(string, Value)]
  for operand in operands:
    keyed.add (typeOperandKey(operand), operand)
  keyed.sort(proc (x, y: (string, Value)): int = cmp(x[0], y[0]))
  for i, entry in keyed:
    operands[i] = entry[1]

proc canonicalTypeExpr*(expr: Value): Value =
  ## Sort the operands of every `&`/`|` node into a stable order so two
  ## spellings of one set compare equal. Purely structural — it resolves no
  ## names, so it needs no scope and is safe at any phase, including impl
  ## registration, which runs long before boundary closure.
  if not typeExprHasCommutativeHead(expr):
    return expr
  if expr.kind == vkList:
    var items: seq[Value]
    for item in expr.listItems: items.add canonicalTypeExpr(item)
    return newList(items, expr.listImmutable)
  if expr.kind == vkMap:
    var props = initPropTable()
    for key, item in expr.mapEntries: props[key] = canonicalTypeExpr(item)
    return newMap(props, expr.mapImmutable)
  var body: seq[Value]
  for item in expr.body:
    body.add canonicalTypeExpr(item)
  if expr.head.isSymbol("&") or expr.head.isSymbol("|"):
    sortTypeExprOperands(body)
  var props = initPropTable()
  for key, item in expr.props:
    props[key] = canonicalTypeExpr(item)
  var meta = initPropTable()
  for key, item in expr.meta:
    meta[key] = item
  newNode(expr.head, props = props, body = body, meta = meta,
          immutable = expr.nodeImmutable)

proc typeExprEquivalent*(a, b: Value): bool =
  ## The one semantic-equivalence test for type expressions. Used by callable
  ## signature comparison (impl registration, before closure) and by
  ## stored-container comparison (typed `Cell`, after closure), so operand
  ## order cannot be significant in one place and not the other.
  equal(canonicalTypeExpr(a), canonicalTypeExpr(b))

proc canonicalErrorCoverage(row: openArray[Value]): seq[Value]

proc closedContractType(expr: Value, depth = 0): Value =
  ## Callers resolve lexical names first. This pass expands retained identity
  ## references and normalizes optional syntax without consulting a receiver.
  if depth > 100:
    raise newException(GeneError, "recursive alias in callable signature")
  if expr.isTypeAlias:
    let canonicalName = expr.borrowedAnnotationContractName
    if canonicalName.len > 0: return newSym(canonicalName)
    return closedContractType(expr.typeAliasExpr, depth + 1)
  case expr.kind
  of vkSymbol:
    if expr.symVal.len > 1 and expr.symVal[^1] == '?':
      newNode(newSym("?"), body = @[
        closedContractType(newSym(expr.symVal[0 .. ^2]), depth + 1)])
    else: expr
  of vkNode:
    var body: seq[Value]
    for item in expr.body: body.add closedContractType(item, depth + 1)
    var props = initPropTable()
    for key, item in expr.props:
      if key == "errors" and item.kind == vkList and
          (expr.head.isSymbol("Callable") or expr.head.isSymbol("Fn")):
        props[key] = newList(canonicalErrorCoverage(item.listItems), immutable = true)
      else:
        props[key] = closedContractType(item, depth + 1)
    newNode(closedContractType(expr.head, depth + 1), body = body, props = props)
  of vkList:
    var items: seq[Value]
    for item in expr.listItems: items.add closedContractType(item, depth + 1)
    newList(items, immutable = true)
  of vkMap:
    var props = initPropTable()
    for key, item in expr.mapEntries: props[key] = closedContractType(item, depth + 1)
    newMap(props, immutable = true)
  else: expr

proc signatureTypeEqual*(a, b: Value): bool =
  ## Omitted annotations and explicit Any have the same boundary meaning.
  let left = closedContractType(a)
  let right = closedContractType(b)
  let aAny = left.kind == vkNil or left.isSymbol("Any")
  let bAny = right.kind == vkNil or right.isSymbol("Any")
  (aAny and bAny) or
    typeExprEquivalent(left, right)

proc errorRowMembers*(row: openArray[Value]): seq[Value] =
  ## Inputs are already closed in their declaration environment. Keep named
  ## alternatives alongside Error; semantic coverage is compared separately.
  var members: seq[Value]
  proc add(expr: Value) =
    let value = closedContractType(expr)
    if value.isSymbol("Never"):
      return
    if value.kind == vkNode and value.head.isSymbol("|"):
      for member in value.body: add(member)
      return
    for existing in members:
      if signatureTypeEqual(existing, value): return
    members.add value
  for value in row: add(value)
  members

proc errorRowIsOpen*(row: openArray[Value]): bool =
  for member in errorRowMembers(row):
    if member.isErrorProtocol:
      return true
    if member.isSymbol("Error"):
      return true

proc errorRowCovers*(allowed, actual: openArray[Value]): bool =
  ## This shared predicate compares coverage, not order or diagnostic hints.
  if errorRowIsOpen(allowed): return true
  let expected = errorRowMembers(allowed)
  for member in errorRowMembers(actual):
    var covered = false
    for permitted in expected:
      if signatureTypeEqual(permitted, member):
        covered = true
        break
      var ancestor = member
      while ancestor.kind == vkType and permitted.kind == vkType:
        if ancestor.bits == permitted.bits:
          covered = true
          break
        ancestor = ancestor.typeParent
      if covered: break
    if not covered: return false
  true

proc errorRowsEquivalent*(a, b: openArray[Value]): bool =
  errorRowCovers(a, b) and errorRowCovers(b, a)

proc canonicalErrorCoverage(row: openArray[Value]): seq[Value] =
  let members = errorRowMembers(row)
  for member in members:
    if member.isErrorProtocol or member.isSymbol("Error"):
      return @[member]
  for member in members:
    var redundant = false
    for other in members:
      if not signatureTypeEqual(member, other) and
          errorRowCovers([other], [member]):
        redundant = true
        break
    if not redundant: result.add member
  result.sortTypeExprOperands()

proc callableSignatureMismatch*(expected, actual: Value): string =
  if expected.kind != vkFunction or actual.kind != vkFunction:
    return "callable category"
  if expected.isSyntaxFn != actual.isSyntaxFn:
    return "callable category (fn versus fexpr)"
  let expectedCode = expected.fnCode
  let actualCode = actual.fnCode
  if expectedCode == nil or actualCode == nil or
      not (expectedCode of FunctionProto) or not (actualCode of FunctionProto):
    return "callable implementation"
  let e = FunctionProto(expectedCode)
  let a = FunctionProto(actualCode)
  if e.params.len != a.params.len or
      e.requiredPositional != a.requiredPositional:
    return "positional parameter shape"
  if e.paramDefaults.len != a.paramDefaults.len:
    return "positional default shape"
  for i in 0 ..< e.paramDefaults.len:
    if e.paramDefaults[i].optional != a.paramDefaults[i].optional:
      return "positional default shape at parameter " & $(i + 1)
  if e.paramTypes.len != a.paramTypes.len:
    return "positional parameter types"
  for i in 0 ..< e.paramTypes.len:
    if not signatureTypeEqual(e.paramTypes[i], a.paramTypes[i]):
      return "positional parameter type at parameter " & $(i + 1)
  if (e.restParam.len != 0) != (a.restParam.len != 0):
    return "rest parameter shape"
  if not signatureTypeEqual(e.restType, a.restType):
    return "rest parameter type"
  if e.namedParams.len != a.namedParams.len:
    return "named parameter shape"
  for i in 0 ..< e.namedParams.len:
    let ep = e.namedParams[i]
    let ap = a.namedParams[i]
    if ep.arg != ap.arg:
      return "named parameter name at parameter " & $(i + 1)
    if ep.defaultValue.optional != ap.defaultValue.optional:
      return "named parameter default shape for ^" & ep.arg
    if not signatureTypeEqual(ep.typeExpr, ap.typeExpr):
      return "named parameter type for ^" & ep.arg
  if not signatureTypeEqual(e.returnType, a.returnType):
    return "return type"
  if expected.fnChecksErrors != actual.fnChecksErrors:
    return "checked error row"
  let expectedErrors = expected.fnErrorTypes
  let actualErrors = actual.fnErrorTypes
  if not errorRowsEquivalent(expectedErrors, actualErrors):
    return "checked error row"
  ""

proc validateCallableSignature*(expected, actual: Value, label: string) =
  let mismatch = callableSignatureMismatch(expected, actual)
  if mismatch.len == 0:
    return
  let expectedProto = FunctionProto(expected.fnCode)
  let actualProto = FunctionProto(actual.fnCode)
  var locations = ""
  let actualLoc = actualProto.sourceLoc.locationText()
  let expectedLoc = expectedProto.sourceLoc.locationText()
  if actualLoc.len > 0:
    locations.add " at " & actualLoc
  if expectedLoc.len > 0:
    locations.add "; inherited/declaration at " & expectedLoc
  raise newException(GeneError,
    label & " has incompatible " & mismatch & locations)
