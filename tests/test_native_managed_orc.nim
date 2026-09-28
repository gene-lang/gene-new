## Managed-to-legacy handoff must be conservative under the default ORC VM too.
when not defined(gcOrc) or defined(gcAtomicArc):
  {.error: "this control requires the default ORC manager".}

import gene/[compiler, native_api, native_managed, types, vm]
import std/[os, tables, unittest]

initModuleContext(getCurrentDir())
let host = newGlobalScope()
discard run(compileSource("nil"), host)
let domain = geneNewManagedDomain(host)

suite "managed native ORC legacy handoff":
  test "a legacy Channel result cannot outlive a weak protocol Scope":
    var pending: seq[Scope]
    var itemRoot: GeneManagedRoot
    block:
      let scope = newGlobalScope()
      scope.sandboxGenerationReleased = true
      scope.define("answer", newInt(42))
      let protocol = newProtocol("PluginP", [], scope = scope)
      pending = @[scope]
      itemRoot = geneManagedRootFromVm(domain, host, protocol)
    let environment = geneNewManagedEnvironment(domain, host)
    let channel = newChannel(1)
    let managed = geneManagedRootFromVm(domain, host, channel)
    check geneManagedChannelTrySend(managed, itemRoot, environment).accepted
    geneManagedRelease(itemRoot)
    block:
      let observed = vm.nativeChannelTryRecv(channel, host)
      check observed.kind == vkNode
      check pending[0].scopePublishedForRetirement
      geneManagedRelease(managed)
      check retireReleasedGenerations(pending) == 0
      check pending[0].lookup("answer").intVal == 42
    pending[0].vars.clear() # explicit end of the legacy test's app lifetime
    geneManagedEnvironmentRelease(environment)

  test "explicit legacy export keeps weak protocol environment pinned":
    var pending: seq[Scope]
    var root: GeneManagedRoot
    block:
      let scope = newGlobalScope()
      scope.sandboxGenerationReleased = true
      scope.define("answer", newInt(42))
      pending = @[scope]
      root = geneManagedRootFromVm(domain, host,
        newProtocol("ExportedP", [], scope = scope))
    var legacy: GeneRoot
    geneWithNativeBorrow(root, proc(b: GeneNativeBorrow) =
      legacy = geneExportManagedRoot(b))
    geneManagedRelease(root)
    geneRootRelease(legacy)
    check pending[0].scopePublishedForRetirement
    check retireReleasedGenerations(pending) == 0
    check pending[0].lookup("answer").intVal == 42
    pending[0].vars.clear()

  test "Gene Actor snapshot permanently publishes managed weak state":
    var pending: seq[Scope]
    var state: GeneManagedRoot
    var environment: GeneManagedEnvironment
    block:
      let scope = newGlobalScope()
      scope.sandboxGenerationReleased = true
      scope.define("answer", newInt(42))
      pending = @[scope]
      state = geneManagedRootFromVm(domain, host,
        newProtocol("ActorStateP", [], scope = scope))
      environment = geneNewManagedEnvironment(domain, scope)
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [ctx state msg] ($actor/continue state))"), host))
    let created = geneManagedNewActor(environment, 1, state, handler)
    check created.status == gsOk
    let defined = geneManagedDefine(environment, "managed_actor", created.value)
    check defined.status == gsOk
    geneManagedRelease(defined.value)
    block:
      let observed = run(compileSource("(managed_actor .snapshot)"), pending[0])
      check observed.kind == vkNode
      check pending[0].scopePublishedForRetirement
    geneManagedRelease(created.value)
    geneManagedRelease(state)
    geneManagedRelease(handler)
    geneManagedEnvironmentRelease(environment)
    check retireReleasedGenerations(pending) == 0
    check pending[0].lookup("answer").intVal == 42
    pending[0].vars.clear()

  test "managed weak binding cycle retires after its handles release":
    proc batch(count: int) =
      for i in 0 ..< count:
        var pending: seq[Scope]
        block:
          let scope = newGlobalScope()
          scope.sandboxGenerationReleased = true
          scope.define("answer", newInt(42))
          pending = @[scope]
          let protocol = newProtocol("BoundP", [], scope = scope)
          let input = geneManagedRootFromVm(domain, host, protocol)
          let environment = geneNewManagedEnvironment(domain, scope)
          let defined = geneManagedDefine(environment, "self", input)
          check defined.status == gsOk and defined.value != nil
          geneManagedRelease(input)
          geneManagedRelease(defined.value)
          geneManagedEnvironmentRelease(environment)
        check retireReleasedGenerations(pending) > 0
    batch(1)
    when defined(geneRcStats):
      let baseline = liveManaged
      for count in [100, 1000]:
        batch(count)
        check liveManaged == baseline
