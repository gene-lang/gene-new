## Leased native notifications, independent of the VM and its GC-managed data.
## A lane waits on all of its owners, supporting multiple applications on the
## same OS thread without a different application's wake being lost.
import std/os

const wakeHeader = currentSourcePath().parentDir / "native_wake.h"
{.compile: "native_wake.c".}
when defined(geneExecTests):
  {.passC: "-DGENE_EXEC_TESTS".}

type
  NativeWakeSignal* = ptr NativeWakeOpaque
  NativeWakeOpaque {.importc: "GeneNativeWake", incompleteStruct,
                      header: wakeHeader.} = object
  NativeWakeOwnerObj = object
    signal*: NativeWakeSignal
  NativeWakeOwner* = ref NativeWakeOwnerObj

proc createWake(lane: int64, key: pointer): NativeWakeSignal
  {.importc: "gene_wake_new", header: wakeHeader, gcsafe, raises: [].}
proc retainWake*(wake: NativeWakeSignal)
  {.importc: "gene_wake_retain", header: wakeHeader, gcsafe, raises: [].}
proc releaseWake*(wake: NativeWakeSignal)
  {.importc: "gene_wake_release", header: wakeHeader, gcsafe, raises: [].}
proc signalWake*(wake: NativeWakeSignal)
  {.importc: "gene_wake_signal", header: wakeHeader, gcsafe, raises: [].}
proc signalRuntimeLanes*()
  {.importc: "gene_wake_signal_lanes", header: wakeHeader, gcsafe, raises: [].}
proc signalWakeKey*(key: pointer)
  {.importc: "gene_wake_signal_key", header: wakeHeader, gcsafe, raises: [].}
proc wakeFd*(wake: NativeWakeSignal): cint
  {.importc: "gene_wake_fd", header: wakeHeader, gcsafe, raises: [].}
proc drainWake*(wake: NativeWakeSignal)
  {.importc: "gene_wake_drain", header: wakeHeader, gcsafe, raises: [].}
proc waitLane(lane: int64, timeoutMs: cint): cint
  {.importc: "gene_wake_wait", header: wakeHeader, gcsafe, raises: [].}

proc `=destroy`(owner: var NativeWakeOwnerObj) =
  releaseWake(owner.signal)
  owner.signal = nil

proc newNativeWake*(lane: int, key: pointer = nil): NativeWakeOwner =
  let signal = createWake(int64(lane), key)
  if signal == nil: raiseOSError(osLastError(), "native wake pipe")
  NativeWakeOwner(signal: signal)

proc waitNativeWake*(lane: int, timeoutMs: int): bool =
  let code = waitLane(int64(lane), cint(min(timeoutMs, int(high(cint)))))
  if code < 0: raiseOSError(OSErrorCode(-code), "native wake wait")
  code > 0

when defined(geneExecTests):
  proc nativeWakeWaitCount*(): uint64
    {.importc: "gene_wake_test_waits", header: wakeHeader, gcsafe, raises: [].}
