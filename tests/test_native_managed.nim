## Opaque managed SDK ownership and AtomicArc generation controls.
when not defined(gcAtomicArc) or defined(gcOrc) or
    not defined(geneAtomicGenerationRetirementProbe) or not defined(geneRcStats):
  {.error: "managed native qualification requires genuine AtomicArc retirement probe".}

import gene/[compiler, native_api, native_managed, retirement_native_gate,
             types, vm]
import std/[monotimes, os, tables, times, unittest]

initModuleContext(getCurrentDir())
let host = newGlobalScope()
discard run(compileSource("nil"), host)
let domain = geneNewManagedDomain(host)

proc privateGeneration(): tuple[roots: seq[Scope], root: GeneManagedRoot] =
  let scope = newGlobalScope()
  scope.sandboxGenerationReleased = true
  scope.define("answer", newInt(42))
  scope.define("self", newNamespace("self", scope))
  result.roots = @[scope]
  result.root = geneManagedRootFromVm(domain, host, scope.lookup("self"))

proc unrootedPrivateGeneration(): seq[Scope] =
  let scope = newGlobalScope()
  scope.sandboxGenerationReleased = true
  scope.define("self", newNamespace("self", scope))
  @[scope]

let weakCode = compileSource("(fn [] 42)").functions[0]
proc privateWeakFunction(): tuple[roots: seq[Scope], root: GeneManagedRoot] =
  let scope = newGlobalScope()
  scope.sandboxGenerationReleased = true
  scope.define("answer", newFunction("answer", @[], weakCode, scope))
  let weak = scope.vars["answer"]
  doAssert weak.fnHasWeakScope
  result.roots = @[scope]
  result.root = geneManagedRootFromVm(domain, host, weak)

proc privateWeakProtocol(): tuple[roots: seq[Scope], root: GeneManagedRoot] =
  let scope = newGlobalScope()
  scope.sandboxGenerationReleased = true
  scope.define("answer", newInt(42))
  let protocol = newProtocol("PluginP", [], scope = scope)
  result.roots = @[scope]
  result.root = geneManagedRootFromVm(domain, host, protocol)

proc privateChannelCycle(): tuple[roots: seq[Scope], channel, item: GeneManagedRoot] =
  let scope = newGlobalScope()
  scope.sandboxGenerationReleased = true
  let channel = newChannel(1)
  scope.define("queue", channel)
  let item = newProtocol("QueuedP", [], scope = scope)
  result.roots = @[scope]
  result.channel = geneManagedRootFromVm(domain, host, channel)
  result.item = geneManagedRootFromVm(domain, host, item)

type ReaderState = ref object
  root: GeneManagedRoot
  stop, reads, bad: int

proc foreignReader(state: ReaderState) {.thread.} =
  {.cast(gcsafe).}:
    let attached = geneAttachThread()
    try:
      while atomicLoadN(addr state.stop, ATOMIC_ACQUIRE) == 0:
        let kind = geneWithNativeBorrow(state.root,
          proc(borrow: GeneNativeBorrow): ValueKind = geneManagedKind(borrow))
        if kind != vkNamespace:
          atomicStoreN(addr state.bad, 1, ATOMIC_RELEASE)
        discard atomicFetchAdd(addr state.reads, 1, ATOMIC_RELAXED)
    finally:
      geneDetachThread(attached)

type WaitingState = ref object
  root: GeneManagedRoot
  started, acknowledged, bad: int

proc waitingBorrow(state: WaitingState) {.thread.} =
  {.cast(gcsafe).}:
    let attached = geneAttachThread()
    try:
      geneWithNativeBorrow(state.root, proc(b: GeneNativeBorrow) =
        atomicStoreN(addr state.started, 1, ATOMIC_RELEASE)
        let deadline = getMonoTime() + initDuration(seconds = 2)
        while atomicLoadN(addr state.acknowledged, ATOMIC_ACQUIRE) == 0:
          if getMonoTime() >= deadline:
            atomicStoreN(addr state.bad, 1, ATOMIC_RELEASE)
            return
          os.sleep(1)
        if geneManagedKind(b) != vkInt:
          atomicStoreN(addr state.bad, 1, ATOMIC_RELEASE))
    finally:
      geneDetachThread(attached)

type WrongLaneState = ref object
  borrow: GeneNativeBorrow
  rejected: bool

proc wrongLane(state: WrongLaneState) {.thread.} =
  {.cast(gcsafe).}:
    try:
      discard geneManagedKind(state.borrow)
    except GeneError:
      state.rejected = true

type TaskState = ref object
  task: GeneManagedTask
  value: GeneManagedRoot
  environment: GeneManagedEnvironment
  accepted, bad: int

proc foreignCompletion(state: TaskState) {.thread.} =
  {.cast(gcsafe).}:
    let attached = geneAttachThread()
    try:
      let ack = geneManagedTaskComplete(state.task, state.value,
                                         state.environment)
      if ack.status != gsOk: atomicStoreN(addr state.bad, 1, ATOMIC_RELEASE)
      if ack.accepted: atomicStoreN(addr state.accepted, 1, ATOMIC_RELEASE)
    finally:
      geneDetachThread(attached)

var cleanupCalls: int
proc managedCleanup(address: pointer) {.nimcall.} =
  # Re-enter the registry while its former last owner is being destroyed.
  let before = geneManagedStats(domain)
  doAssert before.roots == 0
  let replacement = geneManagedRootFromVm(domain, host, newInt(7))
  doAssert geneWithNativeBorrow(replacement,
    proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 7
  geneManagedRelease(replacement)
  inc cleanupCalls

var pointerReleases: int
proc releaseManagedPointer(address: pointer) {.nimcall.} =
  doAssert address == cast[pointer](1)
  discard geneManagedStats(domain) # cleanup must be outside the registry lock
  inc pointerReleases

var managedActorRootLane: int
var managedActorWorkerSeen: int
proc recordManagedActorWorker(args: openArray[Value]): Value {.nimcall.} =
  if currentEventLane() != managedActorRootLane:
    atomicStoreN(addr managedActorWorkerSeen, 1, ATOMIC_RELEASE)
  NIL

suite "managed native handles":
  test "copied scalar text and binary bytes leave a borrow safely":
    let integer = geneManagedRootFromVm(domain, host, newInt(42))
    check geneWithNativeBorrow(integer,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 42
    geneManagedRelease(integer)
    let textRoot = geneManagedRootFromVm(domain, host, newStr("Gene"))
    let copied = geneWithNativeBorrow(textRoot,
      proc(b: GeneNativeBorrow): string = geneManagedText(b))
    geneManagedRelease(textRoot)
    check copied == "Gene"
    let bytesRoot = geneManagedRootFromVm(domain, host, newBytes("\x00\xFFx"))
    let octets = geneWithNativeBorrow(bytesRoot,
      proc(b: GeneNativeBorrow): seq[byte] = geneManagedBytes(b))
    geneManagedRelease(bytesRoot)
    check octets == @[0'u8, 255'u8, 120'u8]

  test "managed calls return owned values and typed errors":
    let callable = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [x] (+ x 1))"), host))
    let failing = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [] (fail (AssertionError ^message \"managed\")))"), host))
    let argument = geneManagedRootFromVm(domain, host, newInt(41))
    let environment = geneNewManagedEnvironment(domain, host)
    let success = geneWithNativeBorrow(callable,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedCall(b, @[argument], environment))
    check success.status == gsOk and success.value != nil and success.error == nil
    check geneWithNativeBorrow(success.value,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 42
    let failed = geneWithNativeBorrow(failing,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedCall(b, [], environment))
    check failed.status == gsError and failed.value == nil
    check failed.error != nil
    check geneWithNativeBorrow(failed.error,
      proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b)) == vkNode
    geneManagedRelease(success.value)
    geneManagedRelease(failed.error)
    geneManagedRelease(argument)
    geneManagedRelease(callable)
    geneManagedRelease(failing)
    geneManagedEnvironmentRelease(environment)
    check geneManagedStats(domain).roots == 0

  test "frozen container traversal returns independently owned handles":
    let list = geneManagedRootFromVm(domain, host,
      newList(@[newInt(42), newStr("child")], immutable = true,
              deepFrozen = true))
    var child: GeneManagedRoot
    geneWithNativeBorrow(list, proc(b: GeneNativeBorrow) =
      check geneManagedListLength(b) == 2
      child = geneManagedListAt(b, 1)
      expect GeneError: discard geneManagedListAt(b, 2))
    geneManagedRelease(list)
    check geneWithNativeBorrow(child,
      proc(b: GeneNativeBorrow): string = geneManagedText(b)) == "child"
    geneManagedRelease(child)

    var entries = initPropTable()
    entries["answer"] = newInt(42)
    let map = geneManagedRootFromVm(domain, host,
      newMap(entries, immutable = true, deepFrozen = true))
    let item = geneWithNativeBorrow(map,
      proc(b: GeneNativeBorrow): GeneManagedRoot =
        geneManagedMapAt(b, "answer"))
    geneManagedRelease(map)
    check geneWithNativeBorrow(item,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 42
    geneManagedRelease(item)

    var props = initPropTable()
    props["answer"] = newInt(42)
    let node = geneManagedRootFromVm(domain, host,
      newNode(newSym("Box"), props, @[newStr("body")],
              immutable = true, deepFrozen = true))
    geneWithNativeBorrow(node, proc(b: GeneNativeBorrow) =
      let head = geneManagedNodeHead(b)
      let prop = geneManagedNodeProp(b, "answer")
      let body = geneManagedNodeBodyAt(b, 0)
      check geneWithNativeBorrow(head,
        proc(x: GeneNativeBorrow): ValueKind = geneManagedKind(x)) == vkSymbol
      check geneWithNativeBorrow(prop,
        proc(x: GeneNativeBorrow): int64 = geneManagedInt64(x)) == 42
      check geneWithNativeBorrow(body,
        proc(x: GeneNativeBorrow): string = geneManagedText(x)) == "body"
      geneManagedRelease(head)
      geneManagedRelease(prop)
      geneManagedRelease(body))
    geneManagedRelease(node)

    let mutable = geneManagedRootFromVm(domain, host, newList(@[newInt(1)]))
    geneWithNativeBorrow(mutable, proc(b: GeneNativeBorrow) =
      expect GeneError: discard geneManagedListLength(b))
    geneManagedRelease(mutable)
    check geneManagedStats(domain).roots == 0

  test "managed native wrapper fields retain owned pointer tickets":
    let environment = geneNewManagedEnvironment(domain, host)
    let typ = geneManagedDefineWrapperType(environment, "ManagedWrapper",
      [GeneManagedWrapperField(name: "handle")])
    check typ.status == gsOk and typ.value != nil
    let before = pointerReleases
    let owned = geneManagedNewOwnedCPtr(environment, cast[pointer](1),
                                        releaseManagedPointer)
    check owned.status == gsOk and owned.value != nil
    let instance = geneManagedNewWrapper(typ.value,
      [("handle", owned.value)], environment)
    check instance.status == gsOk and instance.value != nil
    let field = geneManagedWrapperField(instance.value, typ.value,
                                        "handle", environment)
    check field.status == gsOk and field.value != nil
    check geneWithNativeBorrow(field.value,
      proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b)) == vkCPtr
    geneManagedRelease(owned.value)
    geneManagedRelease(instance.value)
    check pointerReleases == before
    geneWithNativeBorrow(field.value, proc(b: GeneNativeBorrow) =
      geneManagedWithCPtr(b, proc(address: pointer) =
        check address == cast[pointer](1)
        check geneManagedCloseCPtr(b).status == gsError)
      check geneManagedCloseCPtr(b).status == gsOk)
    check pointerReleases == before + 1
    geneManagedRelease(field.value)
    geneManagedRelease(typ.value)
    geneManagedEnvironmentRelease(environment)

  test "managed environment definition owns its binding independently":
    let environment = geneNewManagedEnvironment(domain, host)
    let value = geneManagedRootFromVm(domain, host, newInt(42))
    let defined = geneManagedDefine(environment, "native_answer", value)
    check defined.status == gsOk and defined.value != nil
    geneManagedRelease(value)
    check geneWithNativeBorrow(defined.value,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 42
    geneManagedRelease(defined.value)
    geneManagedEnvironmentRelease(environment)

  test "managed definitions transfer weak Scope tickets to binding and result":
    let target = newGlobalScope()
    let environment = geneNewManagedEnvironment(domain, target)
    var first = privateWeakProtocol()
    let defined = geneManagedDefine(environment, "plugin", first.root)
    check defined.status == gsOk and defined.value != nil
    geneManagedRelease(first.root)
    check testRetireAtomicGenerationRoots(host, first.roots) == 0
    target.assign("plugin", newInt(1))
    check testRetireAtomicGenerationRoots(host, first.roots) == 0
    geneManagedRelease(defined.value)
    check testRetireAtomicGenerationRoots(host, first.roots) > 0

    var second = privateWeakProtocol()
    let another = geneManagedDefine(environment, "plugin2", second.root)
    check another.status == gsOk and another.value != nil
    geneManagedRelease(second.root)
    geneManagedRelease(another.value)
    check testRetireAtomicGenerationRoots(host, second.roots) == 0
    target.assign("plugin2", newInt(2))
    check testRetireAtomicGenerationRoots(host, second.roots) > 0
    geneManagedEnvironmentRelease(environment)

  test "managed weak definition cycles retire after every owner drops":
    proc batch(count: int) =
      for i in 0 ..< count:
        var roots: seq[Scope]
        block:
          let scope = newGlobalScope()
          scope.sandboxGenerationReleased = true
          scope.define("answer", newInt(42))
          roots = @[scope]
          let protocol = newProtocol("DefinedP", [], scope = scope)
          let input = geneManagedRootFromVm(domain, host, protocol)
          let environment = geneNewManagedEnvironment(domain, scope)
          let defined = geneManagedDefine(environment, "self", input)
          check defined.status == gsOk and defined.value != nil
          geneManagedRelease(input)
          geneManagedRelease(defined.value)
          geneManagedEnvironmentRelease(environment)
        check testRetireAtomicGenerationRoots(host, roots) > 0
    batch(1)
    let baseline = liveManaged
    let classes = managedLiveByKind()
    for count in [100, 1000, 10000]:
      batch(count)
      check liveManaged == baseline
      check managedLiveByKind() == classes

  test "private managed buffers keep typed item ownership":
    let environment = geneNewManagedEnvironment(domain, host)
    let initial = geneManagedRootFromVm(domain, host, newInt(41))
    let buffer = geneManagedNewBuffer(environment, nil, @[initial])
    check buffer.status == gsOk and buffer.value != nil
    geneManagedRelease(initial)
    geneWithNativeBorrow(buffer.value, proc(b: GeneNativeBorrow) =
      check geneManagedBufferLength(b) == 1
      let found = geneManagedBufferGet(b, 0, environment)
      check found.status == gsOk
      check geneWithNativeBorrow(found.value,
        proc(item: GeneNativeBorrow): int64 = geneManagedInt64(item)) == 41
      geneManagedRelease(found.value)
      let replacement = geneManagedRootFromVm(domain, host, newInt(42))
      let stored = geneManagedBufferSet(b, 0, replacement, environment)
      check stored.status == gsOk
      geneManagedRelease(stored.value)
      geneManagedRelease(replacement)
      let finalItem = geneManagedBufferGet(b, 0, environment)
      check geneWithNativeBorrow(finalItem.value,
        proc(item: GeneNativeBorrow): int64 = geneManagedInt64(item)) == 42
      geneManagedRelease(finalItem.value))
    geneManagedRelease(buffer.value)
    geneManagedEnvironmentRelease(environment)

  test "published mutable buffers stay outside managed traversal":
    let environment = geneNewManagedEnvironment(domain, host)
    let value = vm.newCheckedBuffer(NIL, @[newInt(7)], host)
    let root = geneManagedRootFromVm(domain, host, value)
    markSharedValue(value) # an existing worker/raw exposure
    geneWithNativeBorrow(root, proc(b: GeneNativeBorrow) =
      expect GeneError: discard geneManagedBufferLength(b))
    geneManagedRelease(root)
    geneManagedEnvironmentRelease(environment)

  test "managed Tasks keep a physical producer owner after user root release":
    let environment = geneNewManagedEnvironment(domain, host)
    let task = geneManagedNewTask(environment)
    let userRoot = geneManagedTaskRoot(task)
    let kept = geneWithNativeBorrow(userRoot,
      proc(b: GeneNativeBorrow): GeneManagedRoot = geneManagedRetain(b))
    let payload = geneManagedRootFromVm(domain, host, newInt(42))
    geneWithNativeBorrow(kept, proc(b: GeneNativeBorrow) =
      expect GeneError: discard geneManagedTaskOutcome(b, environment))
    geneManagedRelease(userRoot)
    check geneManagedStats(domain).producers == 1
    let ack = geneManagedTaskComplete(task, payload, environment)
    check ack.status == gsOk and ack.accepted
    check geneManagedStats(domain).producers == 0
    let outcome = geneWithNativeBorrow(kept,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedTaskOutcome(b, environment))
    check outcome.status == gsOk and outcome.value != nil
    check geneWithNativeBorrow(outcome.value,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 42
    geneManagedRelease(outcome.value)
    geneManagedRelease(kept)
    geneManagedRelease(payload)
    geneManagedEnvironmentRelease(environment)

  test "cancelled Task retains producer until physical completion":
    let environment = geneNewManagedEnvironment(domain, host)
    let task = geneManagedNewTask(environment)
    let userRoot = geneManagedTaskRoot(task)
    let payload = geneManagedRootFromVm(domain, host, newInt(42))
    let cancelled = geneManagedTaskCancel(task, environment)
    check cancelled.status == gsOk and cancelled.accepted
    geneManagedRelease(userRoot)
    check geneManagedStats(domain).producers == 1
    let late = geneManagedTaskComplete(task, payload, environment)
    check late.status == gsOk and not late.accepted
    check geneManagedStats(domain).producers == 0
    expect GeneError: discard geneManagedTaskRetire(task, environment)
    geneManagedRelease(payload)
    geneManagedEnvironmentRelease(environment)

  test "completed Task keeps a weak protocol environment after input release":
    let environment = geneNewManagedEnvironment(domain, host)
    var candidate = privateWeakProtocol()
    let task = geneManagedNewTask(environment)
    let userRoot = geneManagedTaskRoot(task)
    let ack = geneManagedTaskComplete(task, candidate.root, environment)
    check ack.status == gsOk and ack.accepted
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    check candidate.roots[0].lookup("answer").intVal == 42
    let outcome = geneWithNativeBorrow(userRoot,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedTaskOutcome(b, environment))
    check outcome.status == gsOk and outcome.value != nil
    geneManagedRelease(userRoot)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    geneManagedRelease(outcome.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedEnvironmentRelease(environment)

  test "managed Channel owns a weak protocol Scope until dequeue":
    let environment = geneNewManagedEnvironment(domain, host)
    var candidate = privateWeakProtocol()
    let channel = geneManagedNewChannel(environment, 1)
    check channel.status == gsOk and channel.value != nil
    let sent = geneManagedChannelTrySend(channel.value, candidate.root,
                                          environment)
    check sent.status == gsOk and sent.accepted
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    let received = geneManagedChannelTryRecv(channel.value, environment)
    check received.status == gsOk and received.hasValue
    check geneWithNativeBorrow(received.value,
      proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b)) == vkProtocol
    geneManagedRelease(channel.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    geneManagedRelease(received.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedEnvironmentRelease(environment)

  test "managed Channel drop releases queued Scope tickets":
    let environment = geneNewManagedEnvironment(domain, host)
    var candidate = privateWeakProtocol()
    let channel = geneManagedNewChannel(environment, 1)
    check geneManagedChannelTrySend(channel.value, candidate.root,
                                     environment).accepted
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    geneManagedRelease(channel.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedEnvironmentRelease(environment)

  test "managed Channel preserves bounded capacity and typed admission":
    let environment = geneNewManagedEnvironment(domain, host)
    let first = geneManagedRootFromVm(domain, host, newInt(41))
    let second = geneManagedRootFromVm(domain, host, newInt(42))
    let channel = geneManagedNewChannel(environment, 1)
    check geneManagedChannelTrySend(channel.value, first,
                                     environment).accepted
    let full = geneManagedChannelTrySend(channel.value, second, environment)
    check full.status == gsOk and not full.accepted
    let received = geneManagedChannelTryRecv(channel.value, environment)
    check received.status == gsOk and received.hasValue
    check geneWithNativeBorrow(received.value,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 41
    let empty = geneManagedChannelTryRecv(channel.value, environment)
    check empty.status == gsOk and not empty.hasValue
    geneManagedRelease(received.value)
    geneManagedRelease(channel.value)
    geneManagedRelease(first)
    geneManagedRelease(second)

    let intType = geneManagedRootFromVm(domain, host, newSym("Int"))
    let typed = geneManagedNewChannel(environment, 1, intType)
    var candidate = privateWeakProtocol()
    let rejected = geneManagedChannelTrySend(typed.value, candidate.root,
                                              environment)
    check rejected.status == gsError
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedRelease(typed.value)
    geneManagedRelease(intType)
    geneManagedEnvironmentRelease(environment)

  test "managed Actor transfers weak message ownership through handler and state":
    let environment = geneNewManagedEnvironment(domain, host)
    let initial = geneManagedRootFromVm(domain, host, newInt(0))
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [ctx state msg] ($actor/continue msg))"), host))
    let created = geneManagedNewActor(environment, 1, initial, handler)
    check created.status == gsOk and created.value != nil
    var candidate = privateWeakProtocol()
    let sent = geneManagedActorTrySend(created.value, candidate.root,
                                        environment)
    check sent.status == gsOk and sent.accepted
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    discard run(compileSource("($sleep 1)"), host)
    let state = geneManagedActorState(created.value, environment)
    check state.status == gsOk and state.value != nil
    check geneWithNativeBorrow(state.value,
      proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b)) == vkProtocol
    geneManagedRelease(created.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    geneManagedRelease(state.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedRelease(initial)
    geneManagedRelease(handler)
    geneManagedEnvironmentRelease(environment)

  test "managed Actor retains queued message under backpressure":
    let environment = geneNewManagedEnvironment(domain, host)
    let initial = geneManagedRootFromVm(domain, host, newInt(0))
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [ctx state msg] ($actor/continue state))"), host))
    let created = geneManagedNewActor(environment, 1, initial, handler)
    var candidate = privateWeakProtocol()
    let first = geneManagedActorTrySend(created.value, candidate.root,
                                         environment)
    check first.status == gsOk and first.accepted
    let second = geneManagedActorTrySend(created.value, candidate.root,
                                          environment)
    check second.status == gsOk and second.accepted
    let full = geneManagedActorTrySend(created.value, candidate.root,
                                        environment)
    check full.status == gsOk and not full.accepted
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    discard run(compileSource("($sleep 1)"), host)
    geneManagedRelease(created.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedRelease(initial)
    geneManagedRelease(handler)
    geneManagedEnvironmentRelease(environment)

  test "managed Actor keeps message provenance while its handler is parked":
    let environment = geneNewManagedEnvironment(domain, host)
    let initial = geneManagedRootFromVm(domain, host, newInt(0))
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource(
        "(fn [ctx state msg] ($sleep 10) ($actor/continue state))"), host))
    let created = geneManagedNewActor(environment, 1, initial, handler)
    var candidate = privateWeakProtocol()
    check geneManagedActorTrySend(created.value, candidate.root,
                                   environment).accepted
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    discard run(compileSource("($sleep 1)"), host)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    geneManagedRelease(created.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    discard run(compileSource("($sleep 20)"), host)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedRelease(initial)
    geneManagedRelease(handler)
    geneManagedEnvironmentRelease(environment)

  test "managed Actor and defining Scope cycle retires after handles drop":
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [ctx state msg] ($actor/continue state))"), host))
    proc batch(count: int) =
      for i in 0 ..< count:
        var candidate = privateWeakProtocol()
        let environment = geneNewManagedEnvironment(domain, candidate.roots[0])
        let created = geneManagedNewActor(environment, 1, candidate.root, handler)
        check created.status == gsOk
        let defined = geneManagedDefine(environment, "actor", created.value)
        check defined.status == gsOk and defined.value != nil
        geneManagedRelease(defined.value)
        geneManagedRelease(created.value)
        geneManagedRelease(candidate.root)
        geneManagedEnvironmentRelease(environment)
        check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    batch(1)
    let baseline = liveManaged
    let classes = managedLiveByKind()
    for count in [100, 1000, 10000]:
      batch(count)
      check liveManaged == baseline
      check managedLiveByKind() == classes
    geneManagedRelease(handler)

  test "managed Actor stays on root until worker allocations are qualified":
    managedActorRootLane = currentEventLane()
    atomicStoreN(addr managedActorWorkerSeen, 0, ATOMIC_RELEASE)
    host.define("record-managed-worker",
      newNativeFn("record-managed-worker", recordManagedActorWorker))
    let environment = geneNewManagedEnvironment(domain, host)
    let initial = geneManagedRootFromVm(domain, host, newInt(0))
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [ctx state msg] (record-managed-worker) " &
                        "($actor/continue msg))"), host))
    let created = geneManagedNewActor(environment, 1, initial, handler)
    var candidate = privateWeakProtocol()
    check geneManagedActorTrySend(created.value, candidate.root,
                                   environment).accepted
    geneManagedRelease(candidate.root)
    discard run(compileSource(
      "(var i 0) (while (< i 800000) (set i (+ i 1))) ($sleep 1)"), host)
    check atomicLoadN(addr managedActorWorkerSeen, ATOMIC_ACQUIRE) == 0
    check not candidate.roots[0].scopePublishedForRetirement
    let state = geneManagedActorState(created.value, environment)
    check state.status == gsOk and state.value != nil
    geneManagedRelease(created.value)
    geneManagedRelease(state.value)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedRelease(initial)
    geneManagedRelease(handler)
    geneManagedEnvironmentRelease(environment)

  test "managed Actor close rejects further sends and reports lifecycle":
    let environment = geneNewManagedEnvironment(domain, host)
    let initial = geneManagedRootFromVm(domain, host, newInt(0))
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [ctx state msg] ($actor/continue state))"), host))
    let created = geneManagedNewActor(environment, 1, initial, handler)
    let before = geneManagedActorStatus(created.value, environment)
    check not before.closed and before.idle
    let closed = geneManagedActorClose(created.value, environment)
    check closed.status == gsOk and closed.accepted
    check geneManagedActorStatus(created.value, environment).closed
    let sent = geneManagedActorTrySend(created.value, initial, environment)
    check sent.status == gsOk and not sent.accepted
    geneManagedRelease(created.value)
    geneManagedRelease(initial)
    geneManagedRelease(handler)
    geneManagedEnvironmentRelease(environment)

  test "Gene typing upgrade and raw snapshot respect managed Actor tickets":
    var scope = newGlobalScope()
    scope.sandboxGenerationReleased = true
    let environment = geneNewManagedEnvironment(domain, scope)
    let initial = geneManagedRootFromVm(domain, host, newInt(0))
    let handler = geneManagedRootFromVm(domain, host,
      run(compileSource("(fn [ctx state msg] ($actor/continue state))"), host))
    let created = geneManagedNewActor(environment, 1, initial, handler)
    let defined = geneManagedDefine(environment, "managed_actor", created.value)
    check defined.status == gsOk
    geneManagedRelease(defined.value)
    let snapshot = run(compileSource(
      "(var typed : (ActorRef Int) managed_actor) " &
      "(typed .upgrade (fn [ctx state msg] ($actor/continue msg))) " &
      "(typed .snapshot)"), scope)
    check snapshot.kind == vkNode
    let bad = geneManagedRootFromVm(domain, host, newStr("wrong"))
    let rejected = geneManagedActorTrySend(created.value, bad, environment)
    check rejected.status == gsError
    geneManagedRelease(bad)
    geneManagedRelease(created.value)
    geneManagedRelease(initial)
    geneManagedRelease(handler)
    geneManagedEnvironmentRelease(environment)
    var roots = @[scope]
    scope = nil
    check testRetireAtomicGenerationRoots(host, roots) > 0

  test "legacy Channel receive permanently publishes a managed item":
    let environment = geneNewManagedEnvironment(domain, host)
    var candidate = privateWeakProtocol()
    let channel = newChannel(1)
    let managed = geneManagedRootFromVm(domain, host, channel)
    check geneManagedChannelTrySend(managed, candidate.root,
                                     environment).accepted
    geneManagedRelease(candidate.root)
    block:
      let observed = vm.nativeChannelTryRecv(channel, host)
      check observed.kind == vkNode
      check candidate.roots[0].scopePublishedForRetirement
    geneManagedRelease(managed)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    candidate.roots[0].vars.clear() # explicit cleanup, not a collection pass
    geneManagedEnvironmentRelease(environment)

  test "closed managed Channel cycles retire with queued weak Scopes":
    let environment = geneNewManagedEnvironment(domain, host)
    proc batch(count: int) =
      for i in 0 ..< count:
        var candidate = privateChannelCycle()
        let sent = geneManagedChannelTrySend(candidate.channel, candidate.item,
                                              environment)
        check sent.status == gsOk and sent.accepted
        geneManagedRelease(candidate.item)
        geneManagedRelease(candidate.channel)
        check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    batch(20)
    let baseline = liveManaged
    let classes = managedLiveByKind()
    for count in [1, 100, 1000, 10000]:
      batch(count)
      check liveManaged == baseline
      check managedLiveByKind() == classes
    geneManagedEnvironmentRelease(environment)

  test "attached foreign lane completes a managed Task":
    let environment = geneNewManagedEnvironment(domain, host)
    let task = geneManagedNewTask(environment)
    let userRoot = geneManagedTaskRoot(task)
    let payload = geneManagedRootFromVm(domain, host, newInt(42))
    let state = TaskState(task: task, value: payload, environment: environment)
    var thread: Thread[TaskState]
    createThread(thread, foreignCompletion, state)
    joinThread(thread)
    check atomicLoadN(addr state.bad, ATOMIC_ACQUIRE) == 0
    check atomicLoadN(addr state.accepted, ATOMIC_ACQUIRE) == 1
    check geneManagedStats(domain).producers == 0
    geneManagedRelease(userRoot)
    geneManagedRelease(payload)
    geneManagedEnvironmentRelease(environment)

  test "release IDs never alias after registry growth":
    let before = geneManagedStats(domain).nextId
    for i in 0 ..< 1000:
      let root = geneManagedRootFromVm(domain, host, newInt(i))
      geneManagedRelease(root)
      geneManagedRelease(root)
      expect GeneError:
        discard geneWithNativeBorrow(root,
          proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b))
    let stats = geneManagedStats(domain)
    check stats.roots == 0 and stats.borrows == 0
    check stats.nextId == before + 1000'u64

  test "last owner cleanup runs outside registry and admission locks":
    proc resourceRoot(): GeneManagedRoot =
      let resource = newCOwnedPtr(cast[pointer](1), managedCleanup)
      geneManagedRootFromVm(domain, host, resource)
    let root = resourceRoot()
    let before = cleanupCalls
    geneManagedRelease(root)
    check cleanupCalls == before + 1
    check geneManagedStats(domain).roots == 0

  test "a released handle cannot invalidate an admitted borrow":
    let root = geneManagedRootFromVm(domain, host, newInt(42))
    var escaped: GeneNativeBorrow
    geneWithNativeBorrow(root, proc(b: GeneNativeBorrow) =
      escaped = b
      geneManagedRelease(root)
      check geneManagedInt64(b) == 42)
    expect GeneError: discard geneManagedKind(escaped)
    expect GeneError:
      discard geneWithNativeBorrow(root,
        proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b))
    check geneManagedStats(domain).roots == 0

  test "wrong lane is rejected before reading a live borrow":
    let root = geneManagedRootFromVm(domain, host, newInt(42))
    geneWithNativeBorrow(root, proc(b: GeneNativeBorrow) =
      let state = WrongLaneState(borrow: b)
      var thread: Thread[WrongLaneState]
      createThread(thread, wrongLane, state)
      joinThread(thread)
      check state.rejected)
    geneManagedRelease(root)

  test "structured borrow closes admission after callback failure":
    let root = geneManagedRootFromVm(domain, host, newInt(42))
    expect GeneError:
      geneWithNativeBorrow(root, proc(b: GeneNativeBorrow) =
        check geneManagedInt64(b) == 42
        raise newException(GeneError, "injected managed callback failure"))
    check geneManagedStats(domain).borrows == 0
    check retirementNativeGateSnapshot().active == 0
    geneManagedRelease(root)

  test "cross-runtime roots are rejected before handoff":
    let otherApp = newApplication(getCurrentDir())
    let foreignScope = newGlobalScope(otherApp)
    expect GeneError:
      discard geneManagedRootFromVm(domain, foreignScope, newInt(42))

  test "foreign attached lane traverses handles while collector defers":
    var candidate = privateGeneration()
    let reader = ReaderState(root: candidate.root)
    var thread: Thread[ReaderState]
    createThread(thread, foreignReader, reader)
    try:
      let deadline = getMonoTime() + initDuration(seconds = 2)
      while atomicLoadN(addr reader.reads, ATOMIC_ACQUIRE) == 0:
        doAssert getMonoTime() < deadline
        os.sleep(1)
      for i in 0 ..< 1000:
        check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
      check atomicLoadN(addr reader.bad, ATOMIC_ACQUIRE) == 0
    finally:
      atomicStoreN(addr reader.stop, 1, ATOMIC_RELEASE)
      joinThread(thread)
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0

  test "owner-dependent borrow callback never blocks its collecting lane":
    let root = geneManagedRootFromVm(domain, host, newInt(42))
    let state = WaitingState(root: root)
    var thread: Thread[WaitingState]
    createThread(thread, waitingBorrow, state)
    var roots = unrootedPrivateGeneration()
    try:
      let deadline = getMonoTime() + initDuration(seconds = 2)
      while atomicLoadN(addr state.started, ATOMIC_ACQUIRE) == 0:
        doAssert getMonoTime() < deadline
        os.sleep(1)
      check testRetireAtomicGenerationRoots(host, roots) == 0
      check roots.len == 1
    finally:
      atomicStoreN(addr state.acknowledged, 1, ATOMIC_RELEASE)
      joinThread(thread)
    check atomicLoadN(addr state.bad, ATOMIC_ACQUIRE) == 0
    check testRetireAtomicGenerationRoots(host, roots) > 0
    geneManagedRelease(root)

  test "private managed generations retire after their handles drop":
    proc batch(count: int) =
      for i in 0 ..< count:
        var candidate = privateGeneration()
        check not candidate.roots[0].scopePublishedForRetirement
        check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
        geneManagedRelease(candidate.root)
        check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    batch(20)
    let baseline = liveManaged
    let classes = managedLiveByKind()
    for count in [1, 100, 1000, 10000]:
      batch(count)
      check liveManaged == baseline
      check managedLiveByKind() == classes

  test "weak defining Scopes remain live through cloned managed handles":
    let environment = geneNewManagedEnvironment(domain, host)
    var candidate = privateWeakFunction()
    check not candidate.roots[0].scopePublishedForRetirement
    let cloned = geneWithNativeBorrow(candidate.root,
      proc(b: GeneNativeBorrow): GeneManagedRoot = geneManagedRetain(b))
    geneManagedRelease(candidate.root)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    let returned = geneWithNativeBorrow(cloned,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedCall(b, [], environment))
    check returned.status == gsOk
    check geneWithNativeBorrow(returned.value,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b)) == 42
    geneManagedRelease(returned.value)
    geneManagedRelease(cloned)
    check testRetireAtomicGenerationRoots(host, candidate.roots) > 0
    geneManagedEnvironmentRelease(environment)

  test "legacy export is irreversible even after both roots release":
    var candidate = privateGeneration()
    var legacy: GeneRoot
    geneWithNativeBorrow(candidate.root, proc(b: GeneNativeBorrow) =
      legacy = geneExportManagedRoot(b))
    check candidate.roots[0].scopePublishedForRetirement
    geneManagedRelease(candidate.root)
    geneRootRelease(legacy)
    check testRetireAtomicGenerationRoots(host, candidate.roots) == 0
    candidate.roots[0].vars.clear() # explicit cleanup, not collection evidence

  test "shutdown closes admission and waits for owned roots and borrows":
    let root = geneManagedRootFromVm(domain, host, newInt(42))
    let environment = geneNewManagedEnvironment(domain, host)
    let channel = geneManagedNewChannel(environment, 1)
    let task = geneManagedNewTask(environment)
    let taskRoot = geneManagedTaskRoot(task)
    geneWithNativeBorrow(root, proc(b: GeneNativeBorrow) =
      check not geneManagedClose(domain)
      check geneManagedInt64(b) == 42)
    check geneManagedChannelTrySend(channel.value, root,
                                     environment).status == gsError
    let settled = geneManagedTaskComplete(task, root, environment)
    check settled.status == gsOk and settled.accepted
    check geneManagedStats(domain).producers == 0
    expect GeneError:
      discard geneWithNativeBorrow(root,
        proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b))
    geneManagedRelease(channel.value)
    geneManagedRelease(taskRoot)
    geneManagedEnvironmentRelease(environment)
    geneManagedRelease(root)
    check geneManagedClose(domain)
    let stats = geneManagedStats(domain)
    check stats.closed and stats.roots == 0 and stats.borrows == 0
