## Qualification-only AtomicArc generation retirement. Normal builds stay off.
when not defined(gcAtomicArc) or defined(gcOrc) or not defined(geneRcStats):
  {.error: "this suite requires genuine AtomicArc and geneRcStats".}

import gene/[compiler, native_api, printer, types, vm]
import std/[json, monotimes, os, strutils, tables, times, unittest]
when defined(geneAtomicGenerationRetirementProbe):
  import gene/[gir, retirement_native_gate]

initModuleContext(getCurrentDir())
let host = newGlobalScope()
discard run(compileSource("nil"), host)

proc privateRoot(): Scope =
  result = newGlobalScope()
  result.sandboxGenerationReleased = true
  result.define("answer", newInt(42))
  result.define("payload", newList(@[newStr("private")]))
  result.define("self", newNamespace("self", result))

when defined(geneAtomicGenerationRetirementProbe):
  var workerStarted, workerActive, workerFinished: int
  var collectorRoots: seq[Scope] # owning root lane only
  proc workerProbe(args: openArray[Value]): Value {.nimcall.} =
    discard atomicFetchAdd(addr workerActive, 1, ATOMIC_ACQ_REL)
    atomicStoreN(addr workerStarted, 1, ATOMIC_RELEASE)
    os.sleep(100)
    discard atomicFetchSub(addr workerActive, 1, ATOMIC_ACQ_REL)
    atomicStoreN(addr workerFinished, 1, ATOMIC_RELEASE)
    newInt(42)
  proc waitWorker(args: openArray[Value]): Value {.nimcall.} =
    let deadline = getMonoTime() + initDuration(seconds = 2)
    while atomicLoadN(addr workerStarted, ATOMIC_ACQUIRE) == 0:
      if getMonoTime() >= deadline:
        raise newException(GeneError, "worker did not start before the qualification deadline")
      os.sleep(1)
    NIL
  proc collectProbe(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    let retired = testRetireAtomicGenerationRoots(call[].dispatchScope,
                                                  collectorRoots, nested = true)
    doAssert atomicLoadN(addr workerActive, ATOMIC_ACQUIRE) == 0
    doAssert atomicLoadN(addr workerFinished, ATOMIC_ACQUIRE) == 1
    newInt(retired)

  type ForeignReader = ref object
    value: Value
    stop, started, reads, bad: int
  proc foreignReader(reader: ForeignReader) {.thread.} =
    {.cast(gcsafe).}:
      atomicStoreN(addr reader.started, 1, ATOMIC_RELEASE)
      while atomicLoadN(addr reader.stop, ATOMIC_ACQUIRE) == 0:
        if reader.value.nsScope.lookup("answer").intVal != 42:
          atomicStoreN(addr reader.bad, 1, ATOMIC_RELEASE)
        discard atomicFetchAdd(addr reader.reads, 1, ATOMIC_RELAXED)

  type ForeignMutation = ref object
    value: Value
    stop, started, writes: int
  proc foreignMutation(state: ForeignMutation) {.thread.} =
    {.cast(gcsafe).}:
      atomicStoreN(addr state.started, 1, ATOMIC_RELEASE)
      # This lane alone owns the table while the root lane attempts collection.
      # Changing its capacity also detects a collector enumerating stale data.
      while atomicLoadN(addr state.stop, ATOMIC_ACQUIRE) == 0:
        for i in 0 ..< 32:
          state.value.nsScope.vars["foreign" & $i] = newInt(i)
        for i in 0 ..< 32:
          state.value.nsScope.vars.del("foreign" & $i)
        discard atomicFetchAdd(addr state.writes, 1, ATOMIC_RELEASE)

  type ForeignTransfer = ref object
    values: array[2, Value]
    stop, started, transfers, bad: int
  proc foreignTransfer(state: ForeignTransfer) {.thread.} =
    {.cast(gcsafe).}:
      var held = state.values[0]
      atomicStoreN(addr state.started, 1, ATOMIC_RELEASE)
      while atomicLoadN(addr state.stop, ATOMIC_ACQUIRE) == 0:
        for value in state.values:
          held = value
          if held.fnScope.lookup("answer").intVal != 42:
            atomicStoreN(addr state.bad, 1, ATOMIC_RELEASE)
          discard atomicFetchAdd(addr state.transfers, 1, ATOMIC_RELAXED)

  type ForeignIngress = ref object
    context: pointer
    generation: uint64
    finish, started, admitted: int
  proc foreignIngress(state: ForeignIngress) {.thread.} =
    {.cast(gcsafe).}:
      let admitted = geneIngressBegin(state.context, state.generation)
      atomicStoreN(addr state.admitted, int(admitted), ATOMIC_RELEASE)
      atomicStoreN(addr state.started, 1, ATOMIC_RELEASE)
      while atomicLoadN(addr state.finish, ATOMIC_ACQUIRE) == 0: os.sleep(1)
      if admitted == 1: geneIngressEnd(state.context)
  proc ingressHandler(args: openArray[Value]): Value {.nimcall.} = NIL

  type NativeEntry = ref object
    root: GeneRoot
    started, finished, bad: int
  proc drainingNativeEntry(state: NativeEntry) {.thread.} =
    {.cast(gcsafe).}:
      doAssert enterRetirementNativeAccess()
      try:
        atomicStoreN(addr state.started, 1, ATOMIC_RELEASE)
        os.sleep(100)
        # A nested SDK operation must finish even after admission is sealed.
        if geneRootGet(state.root).intVal != 42:
          atomicStoreN(addr state.bad, 1, ATOMIC_RELEASE)
        atomicStoreN(addr state.finished, 1, ATOMIC_RELEASE)
      finally:
        leaveRetirementNativeAccess()
  proc lateNativeEntry(state: NativeEntry) {.thread.} =
    {.cast(gcsafe).}:
      atomicStoreN(addr state.started, 1, ATOMIC_RELEASE)
      if geneRootGet(state.root).intVal != 42:
        atomicStoreN(addr state.bad, 1, ATOMIC_RELEASE)
      atomicStoreN(addr state.finished, 1, ATOMIC_RELEASE)

  var sdkCleanupCalls: int
  proc sdkCleanup(address: pointer) {.nimcall.} =
    doAssert not retirementNativeGateSnapshot().sealed
    doAssert retirementNativeGateSnapshot().depth == 1
    let root = geneRoot(newInt(42))
    doAssert geneRootGet(root).intVal == 42
    geneRootRelease(root)
    inc sdkCleanupCalls

  var ownerAcknowledged: int
  proc dependentCleanup(address: pointer) {.nimcall.} =
    let deadline = getMonoTime() + initDuration(seconds = 2)
    while atomicLoadN(addr ownerAcknowledged, ATOMIC_ACQUIRE) == 0:
      doAssert getMonoTime() < deadline, "collector blocked the cleanup's owning lane"
      os.sleep(1)
  proc dependentNativeEntry(state: NativeEntry) {.thread.} =
    {.cast(gcsafe).}:
      doAssert enterRetirementNativeAccess()
      try:
        atomicStoreN(addr state.started, 1, ATOMIC_RELEASE)
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while not retirementNativeGateSnapshot().sealed:
          doAssert getMonoTime() < deadline
          os.sleep(1)
        # Upgrade a previously admitted entry after the collector starts draining.
        geneRootRelease(state.root)
        atomicStoreN(addr state.finished, 1, ATOMIC_RELEASE)
      finally:
        leaveRetirementNativeAccess()

  var cleanupStarted, cleanupTimedOut: int
  var cleanupEntry: NativeEntry
  proc cleanupNativeEntry(state: NativeEntry) {.thread.} =
    {.cast(gcsafe).}:
      while atomicLoadN(addr cleanupStarted, ATOMIC_ACQUIRE) == 0: os.sleep(1)
      lateNativeEntry(state)
  proc foreignSdkCleanup(address: pointer) {.nimcall.} =
    atomicStoreN(addr cleanupStarted, 1, ATOMIC_RELEASE)
    let deadline = getMonoTime() + initDuration(seconds = 2)
    while atomicLoadN(addr cleanupEntry.finished, ATOMIC_ACQUIRE) == 0:
      if getMonoTime() >= deadline:
        atomicStoreN(addr cleanupTimedOut, 1, ATOMIC_RELEASE)
        return
      os.sleep(1)

suite "AtomicArc generation retirement qualification":
  test "activation retirement stays disabled":
    let root = privateRoot()
    check not root.scopeHasOtherOwners()
    check not root.callScopeMayCycle()
    check retireReturningCallScope(root) == 0
    root.vars.clear() # deliberate teardown of a test-owned cycle

  when not defined(geneAtomicGenerationRetirementProbe):
    test "normal AtomicArc does not enable generation retirement":
      check not generationRetirementAvailable()
      var roots = @[privateRoot()]
      check retireReleasedGenerations(roots) == 0
      check roots.len == 1
      check roots[0].lookup("answer").intVal == 42
      roots[0].vars.clear()
  else:
    test "the AtomicArc header adapter passes its independent layout probe":
      check generationRetirementAvailable()

    test "a direct unpaused call cannot retire a private root":
      var roots = @[privateRoot()]
      check retireReleasedGenerations(roots) == 0
      check roots.len == 1
      check testRetireAtomicGenerationRoots(host, roots) > 0
      check roots.len == 0

    test "native admission drains existing entries before analysis":
      let native = geneRoot(newInt(42))
      for i in 0 ..< 10:
        let state = NativeEntry(root: native)
        var thread: Thread[NativeEntry]
        createThread(thread, drainingNativeEntry, state)
        try:
          let deadline = getMonoTime() + initDuration(seconds = 2)
          while atomicLoadN(addr state.started, ATOMIC_ACQUIRE) == 0:
            doAssert getMonoTime() < deadline
            os.sleep(1)
          var roots = @[privateRoot()]
          check testRetireAtomicGenerationRoots(host, roots) > 0
          check atomicLoadN(addr state.finished, ATOMIC_ACQUIRE) == 1
          check atomicLoadN(addr state.bad, ATOMIC_ACQUIRE) == 0
        finally:
          joinThread(thread)
      geneRootRelease(native)
      check retirementNativeGateSnapshot().active == 0
      check not retirementNativeGateSnapshot().sealed

    test "late SDK entry waits through nested collector seals":
      let native = geneRoot(newInt(42))
      let state = NativeEntry(root: native)
      var roots = @[privateRoot()]
      check trySealRetirementNativeAccess()
      check trySealRetirementNativeAccess()
      var thread: Thread[NativeEntry]
      createThread(thread, lateNativeEntry, state)
      try:
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while retirementNativeGateSnapshot().waiting == 0:
          doAssert getMonoTime() < deadline
          os.sleep(1)
        check atomicLoadN(addr state.finished, ATOMIC_ACQUIRE) == 0
        unsealRetirementNativeAccess()
        check retirementNativeGateSnapshot().sealed
        check retirementNativeGateSnapshot().depth == 1
        check testRetireAtomicGenerationRoots(host, roots, nested = true) == 0
        check retirementNativeGateSnapshot().sealed
        check atomicLoadN(addr state.finished, ATOMIC_ACQUIRE) == 0
      finally:
        while retirementNativeGateSnapshot().depth > 0:
          unsealRetirementNativeAccess()
        joinThread(thread)
      check atomicLoadN(addr state.finished, ATOMIC_ACQUIRE) == 1
      check atomicLoadN(addr state.bad, ATOMIC_ACQUIRE) == 0
      geneRootRelease(native)
      check retirementNativeGateSnapshot().waiting == 0
      check testRetireAtomicGenerationRoots(host, roots) > 0

    test "owner dependent native cleanup defers a draining collector":
      proc ownedResource(): GeneRoot =
        let resource = newCOwnedPtr(cast[pointer](1), dependentCleanup)
        geneRoot(resource)
      atomicStoreN(addr ownerAcknowledged, 0, ATOMIC_RELEASE)
      let state = NativeEntry(root: ownedResource())
      var thread: Thread[NativeEntry]
      createThread(thread, dependentNativeEntry, state)
      var roots = @[privateRoot()]
      try:
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while atomicLoadN(addr state.started, ATOMIC_ACQUIRE) == 0:
          doAssert getMonoTime() < deadline
          os.sleep(1)
        check testRetireAtomicGenerationRoots(host, roots) == 0
        check not retirementNativeGateSnapshot().sealed
        check roots.len == 1
      finally:
        atomicStoreN(addr ownerAcknowledged, 1, ATOMIC_RELEASE)
        joinThread(thread)
      check atomicLoadN(addr state.finished, ATOMIC_ACQUIRE) == 1
      check testRetireAtomicGenerationRoots(host, roots) > 0

    test "collection inside a native entry defers without self deadlock":
      var roots = @[privateRoot()]
      check enterRetirementNativeAccess()
      try:
        check testRetireAtomicGenerationRoots(host, roots, nested = true) == 0
        check roots.len == 1
      finally:
        leaveRetirementNativeAccess()
      check testRetireAtomicGenerationRoots(host, roots) > 0

    test "native admission unwinds failures and rejects analysis reentry":
      expect GeneError: discard geneRootGet(nil)
      check retirementNativeGateSnapshot().active == 0
      check trySealRetirementNativeAccess()
      try:
        expect GeneError: discard geneRoot(newInt(1))
        check retirementNativeGateSnapshot().active == 0
      finally:
        unsealRetirementNativeAccess()
      let native = geneRoot(newInt(42))
      geneRootRelease(native)
      check enterRetirementNativeAccess(mayNeedOwnerProgress = true)
      try:
        check not trySealRetirementNativeAccess()
      finally:
        leaveRetirementNativeAccess()

    test "last owner SDK cleanup runs outside the admission lock":
      proc install(scope: Scope) =
        # End the creator's temporary owner before collection starts.
        let resource = newCOwnedPtr(cast[pointer](1), sdkCleanup)
        scope.define("native", resource)
      var roots = @[privateRoot()]
      sdkCleanupCalls = 0
      install(roots[0])
      check testRetireAtomicGenerationRoots(host, roots) > 0
      check sdkCleanupCalls == 1
      check retirementNativeGateSnapshot().active == 0
      check not retirementNativeGateSnapshot().sealed

    test "foreign SDK callbacks can finish after Scope edges detach":
      proc install(scope: Scope) =
        let resource = newCOwnedPtr(cast[pointer](1), foreignSdkCleanup)
        scope.define("native", resource)
      let native = geneRoot(newInt(42))
      cleanupEntry = NativeEntry(root: native)
      atomicStoreN(addr cleanupStarted, 0, ATOMIC_RELEASE)
      atomicStoreN(addr cleanupTimedOut, 0, ATOMIC_RELEASE)
      var thread: Thread[NativeEntry]
      createThread(thread, cleanupNativeEntry, cleanupEntry)
      var roots = @[privateRoot()]
      install(roots[0])
      try:
        check testRetireAtomicGenerationRoots(host, roots) > 0
      finally:
        atomicStoreN(addr cleanupStarted, 1, ATOMIC_RELEASE)
        joinThread(thread)
      check atomicLoadN(addr cleanupTimedOut, ATOMIC_ACQUIRE) == 0
      check atomicLoadN(addr cleanupEntry.finished, ATOMIC_ACQUIRE) == 1
      check atomicLoadN(addr cleanupEntry.bad, ATOMIC_ACQUIRE) == 0
      geneRootRelease(native)
      cleanupEntry = nil
      check retirementNativeGateSnapshot().depth == 0

    test "private namespace cycles are flat through 10000 retirements":
      proc batch(count: int) =
        for i in 0 ..< count:
          var roots = @[privateRoot()]
          check testRetireAtomicGenerationRoots(host, roots, nested = true) > 0
          check roots.len == 0
      batch(20)
      let baseline = liveManaged
      let classes = managedLiveByKind()
      for count in [1, 100, 1000, 10000]:
        batch(count)
        check liveManaged == baseline
        check managedLiveByKind() == classes
        echo $(%*{"class": "private_namespace", "batch": count,
                  "live": liveManaged, "baseline": baseline})

    test "outside-owned private values retain a root until they are dropped":
      var roots = @[privateRoot()]
      var retained = roots[0].lookup("self")
      check testRetireAtomicGenerationRoots(host, roots) == 0
      check retained.nsScope.lookup("answer").intVal == 42
      retained = NIL
      check testRetireAtomicGenerationRoots(host, roots) > 0
      check roots.len == 0

    test "SDK root publication remains pinned after rootRelease":
      proc rootNamespace(scope: Scope): GeneRoot = geneRoot(scope.lookup("self"))
      proc rootedAnswer(root: GeneRoot): int64 =
        geneRootGet(root).nsScope.lookup("answer").intVal
      var roots = @[privateRoot()]
      let retained = rootNamespace(roots[0])
      check testRetireAtomicGenerationRoots(host, roots) == 0
      check rootedAnswer(retained) == 42
      geneRootRelease(retained)
      check testRetireAtomicGenerationRoots(host, roots) == 0
      check roots[0].scopePublishedForRetirement
      roots[0].vars.clear() # explicit cleanup; published collection is not enabled
      roots.setLen(0)

    test "publication pins lexical ancestors and weak defining scopes":
      var roots = @[privateRoot()]
      block:
        let nested = newScope(roots[0])
        let protocol = newProtocol("Foreign", [], scope = nested)
        markSharedValue(protocol)
        check nested.scopePublishedForRetirement
        check roots[0].scopePublishedForRetirement
      check testRetireAtomicGenerationRoots(host, roots) == 0
      roots[0].vars.clear()
      roots.setLen(0)

    test "a published candidate retains the whole mixed batch":
      var roots = @[privateRoot(), privateRoot()]
      markSharedValue(roots[0].lookup("self"))
      check testRetireAtomicGenerationRoots(host, roots) == 0
      check roots.len == 2
      check roots[1].lookup("answer").intVal == 42
      for root in roots: root.vars.clear()
      roots.setLen(0)

    test "native roots publish Scope edges in compiled constants":
      var roots = @[privateRoot()]
      block:
        let proto = compileSource("(fn [] nil)").functions[0]
        proto.chunk.constants.add roots[0].lookup("self")
        let retained = geneRoot(newFunction("constant", @[], proto, host))
        check roots[0].scopePublishedForRetirement
        geneRootRelease(retained)
        proto.chunk.constants.setLen(0)
      check testRetireAtomicGenerationRoots(host, roots) == 0
      roots[0].vars.clear()
      roots.setLen(0)

    test "native Type method code publishes its constant environments":
      var roots = @[privateRoot()]
      block:
        let proto = compileSource("(fn [] nil)").functions[0]
        proto.chunk.constants.add roots[0].lookup("self")
        let methodValue = newFunction("constant", @[], proto, host)
        let typ = newType("NativeCode", NIL, @[], @[], host,
                          messages = {"constant": methodValue}.toTable)
        let native = geneRoot(typ)
        check roots[0].scopePublishedForRetirement
        geneRootRelease(native)
        proto.chunk.constants.setLen(0)
      check testRetireAtomicGenerationRoots(host, roots) == 0
      roots[0].vars.clear()
      roots.setLen(0)

    test "code headers and error proof targets publish their environments":
      for shape in ["metadata", "error_target", "constructor", "derived_chunk"]:
        var roots = @[privateRoot()]
        block:
          let proto = compileSource("(fn [] nil)").functions[0]
          let child = compileSource("(fn [] nil)").functions[0]
          child.chunk.constants.add roots[0].lookup("self")
          case shape
          of "metadata":
            proto.declMetaValues = @[newFunction("metadata", @[], child, host)]
          of "error_target":
            proto.errorSummary = CallableErrorSummary(dependencies: @[
              ErrorProofDependency(target: newFunction("proof", @[], child, host))])
          of "constructor":
            proto.chunk.typeProtos.add TypeProto(name: "Nested", ctorFn: child)
          of "derived_chunk":
            proto.scopelessChunk = child.chunk
          else: discard
          let native = geneRoot(newFunction("header", @[], proto, host))
          check roots[0].scopePublishedForRetirement
          geneRootRelease(native)
          child.chunk.constants.setLen(0)
        check testRetireAtomicGenerationRoots(host, roots) == 0
        roots[0].vars.clear()
        roots.setLen(0)

    test "native module Scope exposure stays pinned after its handle drops":
      var roots = @[privateRoot()]
      block:
        let module = newGeneModule("native", scope = roots[0])
        check geneModuleScope(module) == roots[0]
        check roots[0].scopePublishedForRetirement
      check testRetireAtomicGenerationRoots(host, roots) == 0
      roots[0].vars.clear()
      roots.setLen(0)

    test "prepared synchronous native callback dispatch Scopes stay pinned":
      var roots = @[privateRoot()]
      block:
        let callback = newNativeSyncCallback(newNativeFn("callback", ingressHandler), roots[0])
        check callback != nil
        check roots[0].scopePublishedForRetirement
      check testRetireAtomicGenerationRoots(host, roots) == 0
      roots[0].vars.clear()
      roots.setLen(0)

    test "published namespace graphs stay pinned even after an owner drops":
      var roots = @[privateRoot()]
      var retained = roots[0].lookup("self")
      markSharedValue(retained)
      check testRetireAtomicGenerationRoots(host, roots) == 0
      retained = NIL
      check testRetireAtomicGenerationRoots(host, roots) == 0
      check roots[0].lookup("answer").intVal == 42
      # Deliberate test cleanup, not a claim that published collection works.
      roots[0].vars.clear()
      roots.setLen(0)

    test "a real worker completes before nested retirement enters its barrier":
      let previous = getEnv("GENE_WORKERS")
      putEnv("GENE_WORKERS", "2")
      try:
        for i in 0 ..< 10:
          let scope = newGlobalScope()
          scope.define("worker_probe", newNativeFn("worker_probe", workerProbe))
          scope.define("wait_worker", newNativeFn("wait_worker", waitWorker))
          scope.define("collect_probe", newNativeCallFn("collect_probe", collectProbe))
          atomicStoreN(addr workerStarted, 0, ATOMIC_RELEASE)
          atomicStoreN(addr workerFinished, 0, ATOMIC_RELEASE)
          collectorRoots = @[privateRoot()]
          let actual = run(compileSource("""
            (let task (spawn (worker_probe)))
            (wait_worker)
            (let retired (collect_probe))
            [retired (await task)]
          """), scope)
          check actual.listItems[0].intVal > 0
          check actual.listItems[1].intVal == 42
          check collectorRoots.len == 0
      finally:
        putEnv("GENE_WORKERS", previous)

    test "a foreign native reader is protected by published-value pinning":
      var roots = @[privateRoot()]
      let reader = ForeignReader(value: roots[0].lookup("self"))
      markSharedValue(reader.value)
      var thread: Thread[ForeignReader]
      createThread(thread, foreignReader, reader)
      try:
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while atomicLoadN(addr reader.started, ATOMIC_ACQUIRE) == 0:
          doAssert getMonoTime() < deadline
          os.sleep(1)
        for i in 0 ..< 1000:
          check testRetireAtomicGenerationRoots(host, roots) == 0
        check atomicLoadN(addr reader.reads, ATOMIC_ACQUIRE) > 0
        check atomicLoadN(addr reader.bad, ATOMIC_ACQUIRE) == 0
      finally:
        atomicStoreN(addr reader.stop, 1, ATOMIC_RELEASE)
        joinThread(thread)
      roots[0].vars.clear() # deliberate cleanup after the foreign thread exits
      roots.setLen(0)

    test "a foreign Scope writer is never enumerated by retirement":
      var roots = @[privateRoot()]
      let native = geneRoot(roots[0].lookup("self"))
      let state = ForeignMutation(value: geneRootGet(native))
      geneRootRelease(native)
      var thread: Thread[ForeignMutation]
      createThread(thread, foreignMutation, state)
      try:
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while atomicLoadN(addr state.writes, ATOMIC_ACQUIRE) == 0:
          doAssert getMonoTime() < deadline
          os.sleep(1)
        for i in 0 ..< 1000:
          check testRetireAtomicGenerationRoots(host, roots) == 0
        check atomicLoadN(addr state.writes, ATOMIC_ACQUIRE) > 0
      finally:
        atomicStoreN(addr state.stop, 1, ATOMIC_RELEASE)
        joinThread(thread)
      check roots[0].lookup("answer").intVal == 42
      roots[0].vars.clear()
      roots.setLen(0)

    test "foreign retain drop transfers remain permanently pinned":
      var roots = @[privateRoot(), privateRoot()]
      var state: ForeignTransfer
      block:
        let first = geneRoot(newFunction("first", @[], nil, roots[0]))
        let second = geneRoot(newFunction("second", @[], nil, roots[1]))
        state = ForeignTransfer(values: [geneRootGet(first), geneRootGet(second)])
        geneRootRelease(first)
        geneRootRelease(second)
      var thread: Thread[ForeignTransfer]
      createThread(thread, foreignTransfer, state)
      try:
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while atomicLoadN(addr state.transfers, ATOMIC_ACQUIRE) == 0:
          doAssert getMonoTime() < deadline
          os.sleep(1)
        for i in 0 ..< 1000:
          check testRetireAtomicGenerationRoots(host, roots) == 0
        check atomicLoadN(addr state.transfers, ATOMIC_ACQUIRE) > 0
        check atomicLoadN(addr state.bad, ATOMIC_ACQUIRE) == 0
      finally:
        atomicStoreN(addr state.stop, 1, ATOMIC_RELEASE)
        joinThread(thread)
      state.values = [NIL, NIL]
      for root in roots: root.vars.clear()
      roots.setLen(0)

    test "late C ingress retains its Scope until physical retirement":
      var roots = @[privateRoot()]
      let subscription = newGeneIngressSubscription(
        newNativeFn("ingress", ingressHandler), roots[0])
      let state = ForeignIngress(context: subscription.context,
                                 generation: subscription.id)
      var thread: Thread[ForeignIngress]
      createThread(thread, foreignIngress, state)
      try:
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while atomicLoadN(addr state.started, ATOMIC_ACQUIRE) == 0:
          doAssert getMonoTime() < deadline
          os.sleep(1)
        check atomicLoadN(addr state.admitted, ATOMIC_ACQUIRE) == 1
        geneIngressRequestCloseSubscription(subscription)
        geneIngressConfirmUnregistered(subscription.context)
        check geneIngressBegin(subscription.context, subscription.id) == 0
        check not geneIngressCanRetire(subscription.context)
        expect GeneError: geneIngressReleaseSubscription(subscription)
        for i in 0 ..< 1000:
          check testRetireAtomicGenerationRoots(host, roots) == 0
        check roots[0].lookup("answer").intVal == 42
      finally:
        atomicStoreN(addr state.finish, 1, ATOMIC_RELEASE)
        joinThread(thread)
      check geneIngressCanRetire(subscription.context)
      geneIngressReleaseSubscription(subscription)
      check subscription.released
      check testRetireAtomicGenerationRoots(host, roots) == 0
      roots[0].vars.clear()
      roots.setLen(0)

    test "actual scalar sandbox generations retire after release":
      let directory = getCurrentDir() / "tests/profiles/native-app/lifetime/plugin"
      let options = "{^dir " & newStr(directory).print() &
        " ^entry \"simple.gene\" ^grants [] ^shared [] ^label \"atomic\" " &
        "^policy {^max_steps 1000 ^max_memory_mb 16 ^timeout_ms 1000}}"
      let source = "(let tx ($runtime/sandbox_transaction)) " &
        "(let generation (tx .prepare " & options & ")) " &
        "(let candidate (generation .module)) ($assert (== candidate/answer 42)) " &
        "(tx .commit) (generation .release) nil"
      proc one() =
        discard run(compileSource(source), newGlobalScope())
        discard run(compileSource("($runtime/test_collect)"), host)
      for i in 0 ..< 20: one()
      let baseline = liveManaged
      let classes = managedLiveByKind()
      for count in [1, 100, 1000, 10000]:
        for i in 0 ..< count: one()
        check liveManaged == baseline
        check managedLiveByKind() == classes
        echo $(%*{"class": "scalar_generation", "batch": count,
                  "live": liveManaged, "baseline": baseline})

    test "private Type generations retire on release discard and failed prepare":
      let directory = getCurrentDir() / "tests/fixtures/atomic_retirement"
      proc options(entry: string): string =
        "{^dir " & newStr(directory).print() & " ^entry " & newStr(entry).print() &
        " ^grants [] ^shared [] ^label \"atomic-types\" " &
        "^policy {^max_steps 1000 ^max_memory_mb 16 ^timeout_ms 1000}}"
      let good = options("private_type.gene")
      let failed = options("failing_type.gene")
      let forms = [
        "(let tx ($runtime/sandbox_transaction)) (let g (tx .prepare " & good &
        ")) (tx .commit) (g .release) nil",
        "(let tx ($runtime/sandbox_transaction)) (let g (tx .prepare " & good &
        ")) (tx .discard) nil",
        "(let tx ($runtime/sandbox_transaction)) (try (tx .prepare " & failed &
        ") catch Any nil) (tx .discard) nil"]
      proc batch(count: int) =
        for i in 0 ..< count:
          for source in forms: discard run(compileSource(source), newGlobalScope())
        discard run(compileSource("($runtime/test_collect)"), host)
      batch(20)
      let baseline = liveManaged
      let classes = managedLiveByKind()
      for count in [1, 100, 1000]:
        batch(count)
        check liveManaged == baseline
        check managedLiveByKind() == classes
        echo $(%*{"class": "private_type_generations", "batch": count,
                  "live": liveManaged, "baseline": baseline})

    test "a retained private Type instance remains callable after generation release":
      proc queuedRoots(): int64 =
        let stats = run(compileSource("($runtime/gc_stats)"), host)
        stats.mapEntries["released_generation_roots"].intVal
      let beforeRoots = queuedRoots()
      let directory = getCurrentDir() / "tests/fixtures/atomic_retirement"
      let scope = newGlobalScope()
      let options = "{^dir " & newStr(directory).print() &
        " ^entry \"private_type.gene\" ^grants [] ^shared [] ^label \"kept\" " &
        "^policy {^max_steps 1000 ^max_memory_mb 16 ^timeout_ms 1000}}"
      discard run(compileSource("(var saved nil) (let tx ($runtime/sandbox_transaction)) " &
        "(let g (tx .prepare " & options & ")) " &
        "(var candidate (g .module)) (set saved candidate/item) (set candidate nil) " &
        "(tx .commit) (g .release) nil",
        useLocalSlots = false), scope)
      # Use an ordinary binding/projection, not a trailing expression selector.
      check run(compileSource("($runtime/test_collect) (saved .value)",
        useLocalSlots = false), scope).intVal == 7
      check queuedRoots() == beforeRoots + 1
      discard run(compileSource("(set saved nil) ($runtime/test_collect)",
        useLocalSlots = false), scope)
      check queuedRoots() == beforeRoots

    test "canonical impl publication is retained and explicitly remains unqualified":
      let directory = getCurrentDir() / "tests/profiles/native-app/lifetime/plugin"
      let options = "{^dir " & newStr(directory).print() &
        " ^entry \"plugin.gene\" ^grants [] ^shared [] ^label \"published\" " &
        "^policy {^max_steps 1000 ^max_memory_mb 16 ^timeout_ms 1000}}"
      let source = "(let tx ($runtime/sandbox_transaction)) " &
        "(let g (tx .prepare " & options & ")) (tx .commit) (g .release) nil"
      let before = liveManaged
      for i in 0 ..< 5: discard run(compileSource(source), newGlobalScope())
      discard run(compileSource("($runtime/test_collect)"), host)
      let retainedValues = managedLiveCount() - before
      let stats = run(compileSource("($runtime/gc_stats)"), host)
      check stats.mapEntries["released_generation_roots"].intVal >= 5
      check retainedValues > 0
      echo $(%*{"class": "published_impl_generation", "qualified": false,
                "retained_values": retainedValues})
