import gene/[compiler, native_api, printer, types, vm]
import std/[tables, unittest]

suite "native api — roots and trampoline":
  test "roots retain values until released":
    let root = geneRoot(newStr("kept"))
    check geneRootGet(root).print() == "\"kept\""
    geneRootRelease(root)
    expect GeneError:
      discard geneRootGet(root)

  test "geneCall invokes Gene callables through the dynamic trampoline":
    let scope = newGlobalScope()
    let callee = run(compileSource("(fn [x] (+ x 1))"), scope)
    let called = geneCall(callee, GeneCall(args: @[newInt(41)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value.print() == "42"

  test "geneCall preserves named arguments and call status":
    let scope = newGlobalScope()
    let callee = run(compileSource("(fn [x ^scale s] (* x s))"), scope)
    let called = geneCall(callee, GeneCall(args: @[newInt(6)],
                                           namedNames: @["scale"],
                                           namedValues: @[newInt(7)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value.print() == "42"

  test "geneCall preserves call-site metadata for Callable values":
    let scope = newGlobalScope()
    let callee = run(compileSource("(type Probe) " &
                                   "(impl Callable Probe " &
                                   "  (message apply [self call] call/site)) " &
                                   "(Probe)"),
                     scope)
    let site = newNode(newSym("native-site"), body = @[newInt(7)])
    let called = geneCall(callee, GeneCall(dispatchScope: scope, site: site))
    check called.status == gsOk
    check called.value.print() == "(native-site 7)"

  test "geneCall reports recoverable errors and panics without exposing exceptions":
    let scope = newGlobalScope()
    discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                              "(impl Error Boom)"),
                scope)
    let failer = run(compileSource("(fn [] (fail (Boom ^message \"bad\")))"),
                     scope)
    let failed = geneCall(failer, GeneCall(dispatchScope: scope))
    check failed.status == gsError
    check failed.hasErrorValue
    check failed.errorValue.kind == vkNode
    check failed.errorValue.props["message"].strVal == "bad"

    let panicker = run(compileSource("(fn [] (panic \"halt\"))"), scope)
    let panicked = geneCall(panicker, GeneCall(dispatchScope: scope))
    check panicked.status == gsPanic
    check panicked.message == "halt"

  test "versioned API table exposes roots and trampoline":
    let api = geneApi()
    let scope = newGlobalScope()
    let root = api.root(newInt(12))
    check api.rootGet(root).print() == "12"
    api.rootRelease(root)

    let callee = run(compileSource("(fn [x] (* x 2))"), scope)
    let called = api.call(callee, GeneCall(args: @[newInt(21)],
                                           dispatchScope: scope))
    check api.version == GeneApiVersion
    check called.status == gsOk
    check called.value.print() == "42"
