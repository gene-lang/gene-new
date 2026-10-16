import std/[atomics, os, unittest]
import gene/native_wake

type Publish = object
  wake: NativeWakeSignal
  done: Atomic[bool]

type WaitProbe = object
  lane: int
  woke: Atomic[bool]

proc waitOnce(data: ptr WaitProbe) {.thread.} =
  data.woke.store(waitNativeWake(data.lane, 1000), moRelease)

proc publish(data: ptr Publish) {.thread.} =
  sleep(10)
  data.done.store(true, moRelease)
  signalWake(data.wake)
  releaseWake(data.wake)

suite "native lane notifications":
  test "notifications coalesce and are consumed":
    let owner = newNativeWake(1001)
    for i in 0 ..< 10000: signalWake(owner.signal)
    check waitNativeWake(1001, 0)
    check not waitNativeWake(1001, 0)

  test "different lane owners do not consume each other's notifications":
    let first = newNativeWake(1002)
    let second = newNativeWake(1003)
    signalWake(first.signal)
    check not waitNativeWake(1003, 0)
    check waitNativeWake(1002, 0)
    signalWake(second.signal)
    check waitNativeWake(1003, 0)

  test "several owners on the same lane can wake its waiter":
    let first = newNativeWake(1004)
    let second = newNativeWake(1004)
    signalWake(first.signal)
    signalWake(second.signal)
    check waitNativeWake(1004, 0)
    check not waitNativeWake(1004, 0)

  test "global pending-work transitions wake all runtime lanes only":
    let first = newNativeWake(1007)
    let second = newNativeWake(1008)
    let control = newNativeWake(-1)
    signalRuntimeLanes()
    check waitNativeWake(1007, 0)
    check waitNativeWake(1008, 0)
    check not waitNativeWake(-1, 0)

  when defined(geneExecTests):
    test "a new owner interrupts an already pinned wait snapshot":
      let existing = newNativeWake(1009)
      var data = WaitProbe(lane: 1009)
      let before = nativeWakeWaitCount()
      var waiter: Thread[ptr WaitProbe]
      createThread(waiter, waitOnce, addr data)
      while nativeWakeWaitCount() == before: sleep(1)
      let added = newNativeWake(1009)
      signalWake(added.signal)
      joinThread(waiter)
      check data.woke.load(moAcquire)

  test "a producer lease survives retirement of the original owner":
    var owner = newNativeWake(1005)
    let data = cast[ptr Publish](allocShared0(sizeof(Publish)))
    data.wake = owner.signal
    retainWake(data.wake)
    var worker: Thread[ptr Publish]
    createThread(worker, publish, data)
    owner = nil
    while not data.done.load(moAcquire):
      discard waitNativeWake(1005, 100)
    joinThread(worker)
    deallocShared(data)

  test "foreign weak-key signalling does not retain a retired endpoint":
    var key: byte
    var owner = newNativeWake(1006, addr key)
    signalWakeKey(addr key)
    check waitNativeWake(1006, 0)
    owner = nil
    signalWakeKey(addr key)
    check not waitNativeWake(1006, 0)
