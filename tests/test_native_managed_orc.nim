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
