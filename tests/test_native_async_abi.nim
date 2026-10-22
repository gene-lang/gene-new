## Native Task producers off the root lane: copied failures, unattached
## submission, queued retirement, cancellation signals, two-phase module close
## and image pinning (tmp/async-improvements.md items 1-4).
import gene/[compiler, native_api, native_managed, types, vm]
import std/[dynlib, os, osproc, strtabs, streams, strutils, unittest]

type
  Submit = proc(index, kind: uint32, scalar: int64, data: ptr uint8,
                length: csize_t, mode: uint32): uint32 {.cdecl.}
  Fail = proc(index, useFactory: uint32, message: ptr uint8,
              messageLength: csize_t, detailKind: uint32, detailScalar: int64,
              detailData: ptr uint8, detailLength: csize_t,
              mode: uint32): uint32 {.cdecl.}
  IndexMode = proc(index, mode: uint32): uint32 {.cdecl.}
  FlagQuery = proc(index, mode: uint32, flag: ptr uint8): uint32 {.cdecl.}
  Sync = proc(index, which, mode: uint32): uint32 {.cdecl.}
  Closing = proc(mode: uint32, flag: ptr uint8): uint32 {.cdecl.}
  Burst = proc(first, count, threads: uint32): uint32 {.cdecl.}
  Range = proc(first, count: uint32): uint32 {.cdecl.}
  Count = proc(): uint32 {.cdecl.}
  Action = proc() {.cdecl.}
  Driver = proc() {.cdecl, gcsafe.}
  Index = proc(index: uint32): uint32 {.cdecl.}
  IndexDelay = proc(index, delay: uint32): uint32 {.cdecl.}
  SetOptions = proc(value: uint32) {.cdecl.}
  CancelCounts = proc(index: uint32, fired, retired,
                      violations: ptr uint32) {.cdecl.}
  BaseSubmit = proc(value: int64): uint32 {.cdecl.}
  BaseFloat = proc(input: cdouble, output: ptr cdouble): uint32 {.cdecl.}

const
  Inline = 0'u32
  Attached = 1'u32
  Unattached = 2'u32
  NoDetail = high(uint32)
  CopyI64 = 2'u32
  CopyText = 3'u32
  OptPin = 1'u32
  OptTwoPhase = 2'u32
  OptJoinOnRetire = 4'u32
  threaded = defined(gcAtomicArc) and compileOption("threads")
  # Attached threads exist only in threaded AtomicArc builds.
  workerMode = when threaded: Attached else: Unattached

proc unloadFixture(address: pointer) {.nimcall.} =
  # ASan on macOS keeps an unloaded instrumented image's global redzones in
  # shadow memory, and a different fixture later mapped at that address
  # trips over them (inside ASan's own module constructor). Instrumented
  # fixtures therefore stay mapped for the process.
  # `-d:geneNativeAsanUnload` restores unloading for one-test-per-process
  # ASan runs, where no different image loads afterwards.
  when not defined(geneNativeAsan) or defined(geneNativeAsanUnload):
    unloadLib(cast[LibHandle](address))

proc unloadPinnedFixture(address: pointer) {.nimcall.} =
  # A pinned image is never unmapped, so a real unload is safe under ASan.
  unloadLib(cast[LibHandle](address))

proc buildFixture(source, name: string): string =
  ## Each pinned image stays mapped for the process, so tests that pin build
  ## their own copy instead of sharing static state with later tests.
  let compiler = findExe("cc")
  if compiler.len == 0: return ""
  let directory = getTempDir() / "gene-native-async-fixture"
  createDir(directory)
  result = directory / (name & (when defined(macosx): ".dylib" else: ".so"))
  var args = when defined(macosx): @["-dynamiclib", "-fPIC"]
             else: @["-shared", "-fPIC"]
  args.add @["-std=c11", "-D_DEFAULT_SOURCE", "-pthread", "-Isrc/gene",
             "-Itests/fixtures", source, "-o", result]
  when defined(geneNativeAsan): args.add "-fsanitize=address"
  when defined(geneNativeTsan): args.add "-fsanitize=thread"
  let environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): environment[key] = value
  when defined(macosx):
    let sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if dirExists(sdk): environment["SDKROOT"] = sdk
  let process = startProcess(compiler, getCurrentDir(), args,
                             env = environment, options = {poStdErrToStdOut})
  let diagnostics = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  if code != 0:
    raise newException(ValueError, "native fixture failed to compile: " &
      diagnostics)

proc fn[T](handle: LibHandle, name: string): T =
  let address = symAddr(handle, name)
  doAssert address != nil, "fixture symbol missing: " & name
  cast[T](address)

const prelude = """
(type GpuError ^props {^message Str ^detail Any})
(impl Error for GpuError)
(var factory_calls 0)
(fn gpu_error [message detail]
  (set factory_calls (+ factory_calls 1))
  (GpuError ^message message ^detail detail))
(fn raising_factory [message detail]
  (fail (GpuError ^message "nested" ^detail nil)))
(fn wrong_factory [message detail] 42)
(fn spinning_factory [message detail]
  (var spins 0)
  (while true (set spins (+ spins 1))))
(fn checked [t] : (Task Any GpuError) t)
(fn outcome [t]
  (try ["ok" (await t)]
    catch GpuError ["gpu" $err/message $err/detail]
    catch TypeError ["type" $err/message]
    catch ErrorContractViolation ["violation"]
    catch RuntimeError ["runtime" $err/message]))
"""

type Harness = object
  handle: LibHandle
  library: Value
  host, scope: Scope
  domain: GeneManagedDomain
  environment: GeneManagedEnvironment
  libraryRoot, loaded: GeneManagedRoot
  legacy: GeneRoot

proc openHarness(path, name: string, options = 0'u32,
                 required = 0'u64,
                 unload: proc(address: pointer) {.nimcall.} = unloadFixture):
                 Harness =
  result.handle = loadLib(path)
  doAssert result.handle != nil
  fn[SetOptions](result.handle, "gene_async_set_options")(options)
  result.library = newFfiLibrary(cast[pointer](result.handle), path, unload)
  result.host = newGlobalScope()
  discard run(compileSource(prelude), result.host)
  result.domain = geneNewManagedDomain(result.host)
  result.environment = geneNewManagedEnvironment(result.domain, result.host)
  result.libraryRoot = geneManagedRootFromVm(result.domain, result.host,
                                             result.library)
  let loaded = geneManagedLoadModule(result.domain, result.libraryRoot,
                                     result.environment, name, required)
  doAssert loaded.status == gsOk, loaded.message
  result.loaded = loaded.value
  result.legacy = geneWithNativeBorrow(loaded.value,
    proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
  result.scope = newScope(result.host)
  result.scope.define("native", geneRootGet(result.legacy))

proc eval(h: Harness, source: string): Value =
  run(compileSource(source), h.scope)

proc start(h: Harness, index: int): Value =
  result = h.eval("(native/start " & $index & ")")
  doAssert result.kind == vkTask and not result.taskDone

proc outcome(h: Harness, task: Value, checkedTask = false): Value =
  let probe = newScope(h.scope)
  probe.define("subject", task)
  run(compileSource(if checkedTask: "(outcome (checked subject))"
                    else: "(outcome subject)"), probe)

proc drain(h: Harness) =
  for _ in 0 ..< 200:
    discard geneManagedPoll(h.domain)
    let stats = geneManagedStats(h.domain)
    if stats.copiedQueued == 0 and stats.retireQueued == 0: return

proc closeHarness(h: var Harness) =
  doAssert fn[Count](h.handle, "gene_async_close_registrations")() == 0
  fn[Action](h.handle, "gene_async_release_saved")()
  geneRootRelease(h.legacy)
  geneManagedRelease(h.loaded)
  geneManagedRelease(h.libraryRoot)
  geneManagedEnvironmentRelease(h.environment)
  h.library.closeFfiLibrary()
  doAssert geneManagedClose(h.domain)

proc text(value: string): (ptr uint8, csize_t) =
  if value.len == 0: (nil, csize_t(0))
  else: (cast[ptr uint8](unsafeAddr value[0]), csize_t(value.len))

let asyncSource = "tests/fixtures/native_async_fixture.c"

suite "native Task producers off the root lane":
  test "copied failures build typed errors on the root lane":
    let path = buildFixture(asyncSource, "async-failures")
    if path.len == 0: skip()
    else:
      var h = openHarness(path, "failures")
      let fail = fn[Fail](h.handle, "gene_async_fail")
      let submit = fn[Submit](h.handle, "gene_async_submit")
      discard h.eval("(native/register_factory gpu_error)")
      let lost = "device lost"
      let (lostData, lostLength) = text(lost)
      let typed = h.start(1)
      check fail(1, 1, lostData, lostLength, CopyI64, 7, nil, 0,
                 workerMode) == 0
      check fail(1, 1, lostData, lostLength, CopyI64, 7, nil, 0,
                 workerMode) == 1 # the queued failure consumed the token
      check not typed.taskDone
      check geneManagedPoll(h.domain) == 1
      let typedOutcome = h.outcome(typed)
      check typedOutcome.listItems[0].strVal == "gpu"
      check typedOutcome.listItems[1].strVal == lost
      check typedOutcome.listItems[2].intVal == 7

      let vram = "vram"
      let (vramData, vramLength) = text(vram)
      let contract = h.start(2)
      check fail(2, 1, lostData, lostLength, CopyText, 0, vramData,
                 vramLength, Unattached) == 0
      h.drain()
      let declared = h.outcome(contract, checkedTask = true)
      check declared.listItems[0].strVal == "gpu"
      check declared.listItems[2].strVal == "vram"

      let plain = h.start(3)
      let plainText = "plain failure"
      let (plainData, plainLength) = text(plainText)
      check fail(3, 0, plainData, plainLength, NoDetail, 0, nil, 0,
                 Unattached) == 0
      h.drain()
      let runtime = h.outcome(plain)
      check runtime.listItems[0].strVal == "runtime"
      check runtime.listItems[1].strVal == plainText

      discard h.eval("(native/register_factory raising_factory)")
      let raised = h.start(4)
      check fail(4, 1, lostData, lostLength, NoDetail, 0, nil, 0, Inline) == 0
      h.drain()
      check h.outcome(raised).listItems[0].strVal == "type"
      let raisedChecked = h.start(5)
      check fail(5, 1, lostData, lostLength, NoDetail, 0, nil, 0, Inline) == 0
      h.drain()
      check h.outcome(raisedChecked, checkedTask = true).listItems[0].strVal ==
        "type" # a generated failure passes the declared contract

      discard h.eval("(native/register_factory wrong_factory)")
      let wrong = h.start(6)
      check fail(6, 1, lostData, lostLength, NoDetail, 0, nil, 0, Inline) == 0
      h.drain()
      check h.outcome(wrong).listItems[0].strVal == "type"

      discard h.eval("(native/register_factory spinning_factory)")
      let spinning = h.start(7)
      check fail(7, 1, lostData, lostLength, NoDetail, 0, nil, 0, Inline) == 0
      h.drain() # the factory's budget ends the spin
      check h.outcome(spinning).listItems[0].strVal == "type"

      # A factory released after queueing fails with the native message.
      let stale = h.start(8)
      check fail(8, 1, lostData, lostLength, NoDetail, 0, nil, 0, Inline) == 0
      discard h.eval("(native/register_factory gpu_error)")
      h.drain()
      let staleOutcome = h.outcome(stale)
      check staleOutcome.listItems[0].strVal == "runtime"
      check staleOutcome.listItems[1].strVal.contains(lost)

      # Cancellation before the drain skips the factory.
      let callsBefore = h.eval("factory_calls").intVal
      let cancelled = h.start(9)
      check fail(9, 1, lostData, lostLength, NoDetail, 0, nil, 0, Inline) == 0
      check nativeTaskCancel(cancelled, h.scope)
      h.drain()
      check cancelled.taskCancelled
      check h.eval("factory_calls").intVal == callsBefore
      check geneManagedStats(h.domain).producers == 0

      var invalid = "\xFF"
      let badMessage = h.start(10)
      check fail(10, 0, cast[ptr uint8](addr invalid[0]), 1, NoDetail, 0, nil,
                 0, Inline) == 0
      h.drain()
      check h.outcome(badMessage).listItems[1].strVal.contains("UTF-8")

      # Copied results and failures share one bounded queue.
      for i in 0 ..< 256:
        discard h.start(100 + i)
        check submit(uint32(100 + i), 0, 0, nil, 0, Inline) == 0
      let overflow = h.start(400)
      check fail(400, 0, plainData, plainLength, NoDetail, 0, nil, 0,
                 Inline) == 1
      check geneManagedPoll(h.domain) == 32
      check fail(400, 0, plainData, plainLength, NoDetail, 0, nil, 0,
                 Inline) == 0
      h.drain()
      check overflow.taskHasError

      # Module close waits for a queued failure.
      let last = h.start(401)
      check fail(401, 0, plainData, plainLength, NoDetail, 0, nil, 0,
                 Unattached) == 0
      check geneManagedStats(h.domain).copiedQueued == 1
      check fn[Count](h.handle, "gene_async_close_registrations")() == 0
      fn[Action](h.handle, "gene_async_release_saved")()
      geneRootRelease(h.legacy)
      geneManagedRelease(h.loaded)
      geneManagedRelease(h.libraryRoot)
      geneManagedEnvironmentRelease(h.environment)
      check not last.taskDone
      # Close drains the queued failure before it decides.
      check geneManagedClose(h.domain)
      check last.taskHasError
      check geneManagedStats(h.domain).producers == 0
      h.library.closeFfiLibrary()

  test "threads that never attached submit, fail and retire":
    let path = buildFixture(asyncSource, "async-unattached")
    if path.len == 0: skip()
    else:
      var h = openHarness(path, "unattached")
      let submit = fn[Submit](h.handle, "gene_async_submit")
      let retireQueued = fn[IndexMode](h.handle, "gene_async_retire_queued")
      let sync = fn[Sync](h.handle, "gene_async_sync")
      let burst = fn[Burst](h.handle, "gene_async_burst")
      let number = h.start(1)
      check submit(1, CopyI64, 5, nil, 0, Unattached) == 0
      check geneManagedPoll(h.domain) == 1
      check number.taskResult.intVal == 5

      let retiredTask = h.start(2)
      check retireQueued(2, Unattached) == 0
      check retireQueued(2, Unattached) == 1 # consumed token
      h.drain()
      check retiredTask.taskCancelled
      check geneManagedStats(h.domain).producers == 0

      # Synchronous settlement still needs the root lane or an attachment.
      let rejected = h.start(3)
      for which in 0'u32 .. 3'u32:
        check sync(3, which, Unattached) == 1
      check not rejected.taskDone
      check submit(3, 0, 0, nil, 0, Inline) == 0
      h.drain()

      # Queued retirement bypasses the copy budgets.
      for i in 0 ..< 256:
        discard h.start(100 + i)
        check submit(uint32(100 + i), 0, 0, nil, 0, Unattached) == 0
      let full = h.start(400)
      check submit(400, 0, 0, nil, 0, Unattached) == 1
      check retireQueued(400, Unattached) == 0
      check geneManagedStats(h.domain).retireQueued == 1
      for _ in 0 ..< 12: discard geneManagedPoll(h.domain)
      check full.taskCancelled
      check geneManagedStats(h.domain).producers == 0

      let rounds = parseInt(getEnv("GENE_NATIVE_ASYNC_ROUNDS", "4"))
      doAssert rounds > 0 and rounds <= 1000
      for round in 0 ..< rounds:
        var tasks = newSeq[Value](256)
        for i in 0 ..< 256: tasks[i] = h.start(i)
        check burst(0, 256, 4) == 0 # every thread exits before the drain
        for _ in 0 ..< 32: discard geneManagedPoll(h.domain)
        let stats = geneManagedStats(h.domain)
        check stats.producers == 0 and stats.copiedQueued == 0 and
              stats.retireQueued == 0 and stats.copiedReserved == 0
        for i, task in tasks:
          if i mod 7 == 0: check task.taskCancelled
          elif i mod 3 == 0: check task.taskErrorMsg == "burst failure"
          else: check task.taskResult.intVal == i
      h.closeHarness()

  test "a full queue during module close still retires every producer":
    let path = buildFixture(asyncSource, "async-full-close")
    if path.len == 0: skip()
    else:
      var h = openHarness(path, "fullclose")
      let submit = fn[Submit](h.handle, "gene_async_submit")
      let retireQueued = fn[IndexMode](h.handle, "gene_async_retire_queued")
      var settled, extras: seq[Value]
      for i in 0 ..< 256:
        settled.add h.start(i)
        check submit(uint32(i), CopyI64, int64(i), nil, 0, Unattached) == 0
      for i in 256 ..< 260: extras.add h.start(i)
      # Module close begins: registrations close, the domain seals.
      check fn[Count](h.handle, "gene_async_close_registrations")() == 0
      fn[Action](h.handle, "gene_async_release_saved")()
      geneRootRelease(h.legacy)
      geneManagedRelease(h.loaded)
      geneManagedRelease(h.libraryRoot)
      geneManagedEnvironmentRelease(h.environment)
      check geneManagedStats(h.domain).copiedQueued == 256
      # The extra jobs have physically ended, but their results do not fit.
      for i in 256'u32 ..< 260'u32:
        check submit(i, CopyI64, 0, nil, 0, Unattached) == 1
        check retireQueued(i, Unattached) == 0
      check geneManagedStats(h.domain).retireQueued == 4
      check not geneManagedClose(h.domain) # close is under way, still queued
      for _ in 0 ..< 16: discard geneManagedPoll(h.domain)
      check geneManagedStats(h.domain).producers == 0
      for i, task in settled:
        check task.taskDone and task.taskResult.intVal == i
      for task in extras: check task.taskCancelled
      h.library.closeFfiLibrary()
      check geneManagedClose(h.domain)

  test "cancellation reaches native code":
    let path = buildFixture(asyncSource, "async-cancel")
    if path.len == 0: skip()
    else:
      var h = openHarness(path, "cancel")
      let query = fn[FlagQuery](h.handle, "gene_async_cancel_requested")
      let sync = fn[Sync](h.handle, "gene_async_sync")
      let submit = fn[Submit](h.handle, "gene_async_submit")
      let onCancel = fn[Index](h.handle, "gene_async_on_cancel")
      let counts = fn[CancelCounts](h.handle, "gene_async_cancel_counts")
      let delayed = fn[IndexDelay](h.handle, "gene_async_delayed_submit")
      let joinWorkers = fn[Action](h.handle, "gene_async_join_workers")
      var flag: uint8
      let flagged = h.start(1)
      check query(1, Unattached, addr flag) == 0 and flag == 0
      let canceller = newScope(h.scope)
      canceller.define("subject", flagged)
      discard run(compileSource("(subject .cancel)"), canceller)
      check flagged.taskCancelled
      discard geneManagedPoll(h.domain)
      check query(1, Unattached, addr flag) == 0 and flag == 1
      check query(1, Inline, addr flag) == 0 and flag == 1
      check sync(1, 3, Inline) == 0 # retire after the job ends
      check query(1, Unattached, addr flag) == 1 # consumed token

      let late = h.start(2)
      check nativeTaskCancel(late, h.scope)
      check submit(2, CopyI64, 1, nil, 0, Unattached) == 0
      h.drain()
      check late.taskCancelled and geneManagedStats(h.domain).producers == 0
      let refused = h.start(7)
      check nativeTaskCancel(refused, h.scope)
      var accepted = 9'u8
      check fn[proc(index: uint32, accepted: ptr uint8): uint32 {.cdecl.}](
        h.handle, "gene_async_complete_accepted")(7, addr accepted) == 0
      check accepted == 0 # settlement after a cancel is not accepted
      check refused.taskCancelled and geneManagedStats(h.domain).producers == 0

      var fired, retired, violations: uint32
      let watched = h.start(3)
      check onCancel(3) == 0
      check onCancel(3) == 1 # one registration per producer
      check nativeTaskCancel(watched, h.scope)
      discard geneManagedPoll(h.domain)
      counts(3, addr fired, addr retired, addr violations)
      check fired == 1 and retired == 0
      check sync(3, 3, Inline) == 0
      counts(3, addr fired, addr retired, addr violations)
      check retired == 1 and violations == 0

      let quiet = h.start(4)
      check onCancel(4) == 0
      check submit(4, CopyI64, 4, nil, 0, Unattached) == 0
      h.drain()
      check quiet.taskResult.intVal == 4
      counts(4, addr fired, addr retired, addr violations)
      check fired == 0 and retired == 1 and violations == 0

      let early = h.start(5)
      check nativeTaskCancel(early, h.scope)
      check onCancel(5) == 0 # registered after the cancel
      discard geneManagedPoll(h.domain)
      counts(5, addr fired, addr retired, addr violations)
      check fired == 1
      check submit(5, CopyI64, 5, nil, 0, Unattached) == 0
      h.drain()
      counts(5, addr fired, addr retired, addr violations)
      check retired == 1 and violations == 0

      let races = parseInt(getEnv("GENE_NATIVE_ASYNC_RACES", "64"))
      var raced: seq[Value]
      for i in 0 ..< races:
        let index = 1000 + i
        raced.add h.start(index)
        check onCancel(uint32(index)) == 0
        check delayed(uint32(index), uint32((i * 37) mod 400)) == 0
        sleep((i * 13) mod 3)
        discard nativeTaskCancel(raced[^1], h.scope)
        discard geneManagedPoll(h.domain)
      joinWorkers()
      for _ in 0 ..< 64:
        discard geneManagedPoll(h.domain)
        if geneManagedStats(h.domain).producers == 0: break
      check geneManagedStats(h.domain).producers == 0
      for i in 0 ..< races:
        counts(uint32(1000 + i), addr fired, addr retired, addr violations)
        check fired <= 1 and retired == 1 and violations == 0
        check raced[i].taskDone

      # The registration and producer retire before a pending retire(context).
      let outlived = h.start(6)
      check onCancel(6) == 0
      check fn[Count](h.handle, "gene_async_close_registrations")() == 0
      expect GeneError:
        h.library.closeFfiLibrary()
      check submit(6, 0, 0, nil, 0, Unattached) == 0
      h.drain()
      counts(6, addr fired, addr retired, addr violations)
      check outlived.taskDone and retired == 1 and violations == 0
      fn[Action](h.handle, "gene_async_release_saved")()
      geneRootRelease(h.legacy)
      geneManagedRelease(h.loaded)
      geneManagedRelease(h.libraryRoot)
      geneManagedEnvironmentRelease(h.environment)
      h.library.closeFfiLibrary()
      check geneManagedClose(h.domain)

  test "job memory outlives a cancelled Task":
    let path = buildFixture(asyncSource, "async-memory")
    if path.len == 0: skip()
    else:
      var h = openHarness(path, "memory")
      let job = h.start(1)
      check fn[Index](h.handle, "gene_async_buffer_job")(1) == 0
      check nativeTaskCancel(job, h.scope)
      fn[Action](h.handle, "gene_async_drop_buffer")()
      let freed = fn[Count](h.handle, "gene_async_buffers_freed")
      check freed() == 0 # the running job still holds its reference
      fn[Action](h.handle, "gene_async_join_workers")()
      h.drain()
      check freed() == 1 and job.taskCancelled
      check geneManagedStats(h.domain).producers == 0
      h.closeHarness()

  test "a module built against the earlier header loads":
    let path = buildFixture("tests/fixtures/native_base_header_fixture.c",
                            "async-base-header")
    if path.len == 0: skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot, environment,
                                        "base", GeneApiTaskCopyFeature)
      check loaded.status == gsOk
      let legacy = geneWithNativeBorrow(loaded.value,
        proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
      let scope = newScope(host)
      scope.define("base", geneRootGet(legacy))
      let task = run(compileSource("(base/start)"), scope)
      check fn[BaseSubmit](handle, "gene_base_submit")(41) == 0
      check geneManagedPoll(domain) == 1
      check task.taskResult.intVal == 41
      var copied: cdouble
      check fn[BaseFloat](handle, "gene_base_float_roundtrip")(2.5,
        addr copied) == 0 and copied == 2.5
      check fn[Count](handle, "gene_base_close")() == 0
      geneRootRelease(legacy)
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "a refused pin fails module initialization":
    let path = buildFixture(asyncSource, "async-pin-refused")
    if path.len == 0: skip()
    else:
      let handle = loadLib(path)
      fn[SetOptions](handle, "gene_async_set_options")(OptPin)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      geneFailNextNativePin()
      let loaded = geneManagedLoadModule(domain, libraryRoot, environment,
                                        "refused")
      check loaded.status == gsError
      check loaded.message.contains("refused to pin")
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

suite "two-phase native module close":
  proc closeScenario(name: string, dropHandle: bool) =
    let path = buildFixture(asyncSource, "async-two-phase-" & name)
    let handle = loadLib(path)
    fn[SetOptions](handle, "gene_async_set_options")(
      OptTwoPhase or OptJoinOnRetire)
    let submit = fn[Submit](handle, "gene_async_submit")
    let background = fn[Range](handle, "gene_async_background")
    let backgroundDone = fn[Count](handle, "gene_async_background_done")
    let retires = fn[Count](handle, "gene_async_context_retires")
    let closing = fn[Closing](handle, "gene_async_module_closing")
    let host = newGlobalScope()
    discard run(compileSource(prelude), host)
    let scope = newScope(host)
    var module = geneManagedOpenNativeModule(path, name, scope)
    scope.define("module", module)
    scope.define("native", run(compileSource("(module .module)"), scope))
    var tasks: seq[Value]
    for i in 0 ..< 256:
      tasks.add run(compileSource("(native/start " & $i & ")"), scope)
      check submit(uint32(i), CopyI64, int64(i), nil, 0, Inline) == 0
    for i in 256 ..< 260:
      tasks.add run(compileSource("(native/start " & $i & ")"), scope)
    check background(256, 4) == 0 # these retry while the queue is full
    let settled = run(compileSource("(native/start 300)"), scope)
    let recordsBefore = geneManagedNativeModuleCount()
    if dropHandle:
      module = NIL
      scope.assign("module", NIL)
    else:
      discard run(compileSource(
        "(import $io [IoResource]) (module .IoResource:close)"), scope)
      check run(compileSource("(let s (module .status)) s/close_phase"),
                newScope(scope)).strVal == "prepare"
    var flag: uint8
    var polls = 0
    while polls < 2000:
      geneManagedPollNativeModules()
      if polls == 0:
        check closing(Inline, addr flag) == 0 and flag == 1
        expect GeneError: # phase one admits no new producers
          discard run(compileSource("(native/start 301)"), scope)
        check retires() == 0 # registrations stay open in phase one
        discard run(compileSource("(native/settle 300 9)"), scope)
      if retires() == 3: break
      sleep(1)
      inc polls
    for _ in 0 ..< 20: geneManagedPollNativeModules()
    if dropHandle: # the closed record of an unreachable handle is removed
      check geneManagedNativeModuleCount() == recordsBefore - 1
    if not dropHandle:
      check run(compileSource("(let s (module .status)) s/state"),
                newScope(scope)).strVal == "closed"
    check backgroundDone() == 4
    check settled.taskResult.intVal == 9
    for i, task in tasks:
      check task.taskDone and task.taskResult.intVal == i
    check retires() == 3 # joining retirement callbacks did not deadlock

  test "explicit close drains producers before retiring registrations":
    closeScenario("explicit", dropHandle = false)

  test "a dropped handle closes in the same order":
    closeScenario("dropped", dropHandle = true)

  test "a worker that attaches after close begins still finishes":
    # AtomicArc: the worker attaches late and settles synchronously. ORC has
    # no attachment, so its held worker uses the queued entries instead.
    const holdSymbol = when threaded: "gene_async_hold_attacher"
                       else: "gene_async_hold_unattached"
    block:
      for dropHandle in [false, true]:
        let name = if dropHandle: "held-dropped" else: "held-explicit"
        let path = buildFixture(asyncSource, "async-" & name)
        let handle = loadLib(path)
        fn[SetOptions](handle, "gene_async_set_options")(OptTwoPhase)
        let host = newGlobalScope()
        discard run(compileSource(prelude), host)
        let scope = newScope(host)
        var module = geneManagedOpenNativeModule(path, name, scope)
        scope.define("module", module)
        scope.define("native", run(compileSource("(module .module)"), scope))
        let completed = run(compileSource("(native/start 2)"), scope)
        let retired = run(compileSource("(native/start 3)"), scope)
        check fn[Index](handle, holdSymbol)(2) == 0
        let recordsBefore = geneManagedNativeModuleCount()
        if dropHandle:
          module = NIL
          scope.assign("module", NIL)
        else:
          discard run(compileSource(
            "(import $io [IoResource]) (module .IoResource:close)"), scope)
        for _ in 0 ..< 5: geneManagedPollNativeModules()
        check fn[Count](handle, "gene_async_context_retires")() == 0
        check fn[Count](handle, "gene_async_release_attacher")() == 0
        check fn[Index](handle, holdSymbol)(3) == 0
        check fn[Count](handle, "gene_async_release_attacher")() == 0
        for _ in 0 ..< 200:
          geneManagedPollNativeModules()
          if fn[Count](handle, "gene_async_context_retires")() == 3: break
          sleep(1)
        check completed.taskDone and completed.taskResult.kind == vkNil
        check retired.taskCancelled
        check fn[Count](handle, "gene_async_context_retires")() == 3
        for _ in 0 ..< 20: geneManagedPollNativeModules()
        if dropHandle:
          check geneManagedNativeModuleCount() == recordsBefore - 1
        else:
          check run(compileSource("(let s (module .status)) s/state"),
                    newScope(scope)).strVal == "closed"

  test "a module that does not opt in keeps today's close order":
    let path = buildFixture(asyncSource, "async-single-phase")
    let handle = loadLib(path)
    fn[SetOptions](handle, "gene_async_set_options")(0)
    let host = newGlobalScope()
    discard run(compileSource(prelude), host)
    let scope = newScope(host)
    let module = geneManagedOpenNativeModule(path, "single", scope)
    scope.define("module", module)
    scope.define("native", run(compileSource("(module .module)"), scope))
    let live = run(compileSource("(native/start 1)"), scope)
    discard run(compileSource(
      "(import $io [IoResource]) (module .IoResource:close)"), scope)
    # Today's order: every registration retires while a producer is live.
    check fn[Count](handle, "gene_async_context_retires")() == 3
    check run(compileSource("(let s (module .status)) s/close_phase"),
              newScope(scope)).strVal == "retire"
    check fn[Sync](handle, "gene_async_sync")(1, 3, Inline) == 0
    for _ in 0 ..< 20: geneManagedPollNativeModules()
    check live.taskCancelled
    check run(compileSource("(let s (module .status)) s/state"),
              newScope(scope)).strVal == "closed"

const patternSource = """
(import $io [IoResource])
(var stopping false)
(var reopened 0)
(fn ingress_handler [bytes]
  (let index (native/record_index bytes))
  (let kind (native/record_kind bytes))
  (if (== kind 3) (panic "handler panic") nil)
  (if (== kind 4)
    (do (let sleeper (spawn ($sleep 1000))) (sleeper .cancel) (await sleeper))
    nil)
  (try
    (if (== kind 1)
      (native/settle_err index
        (GpuError ^message "device" ^detail (native/record_value bytes)))
      (native/settle_ok index (native/record_value bytes)))
    catch Error
      (native/settle_err index (RuntimeError ^message "malformed record"))))
(fn open_subscription []
  ($native/ingress/open pattern_library ingress_handler
    ^register "gene_pattern_register" ^unregister "gene_pattern_unregister"
    ^max_count 1))
(var current_sub (open_subscription))
(fn supervise []
  (while (== stopping false)
    # join reports the subscription's error, panic or cancellation as an
    # outcome; await would raise it here and end the supervisor.
    ((current_sub .IoResource:wait_closed) .join)
    (if (== stopping false)
      (do
        (native/reenqueue)
        (set current_sub (open_subscription))
        (set reopened (+ reopened 1)))
      nil)))
(var supervisor ((spawn (supervise)) .detach))
"""

suite "ingress completion pattern":
  test "stored records survive overflow, handler faults and close":
    let path = buildFixture("tests/fixtures/native_ingress_pattern_fixture.c",
                            "ingress-pattern")
    if path.len == 0: skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource(prelude), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot, environment,
                                        "pattern")
      check loaded.status == gsOk
      let legacy = geneWithNativeBorrow(loaded.value,
        proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
      let scope = newScope(host)
      scope.define("native", geneRootGet(legacy))
      scope.define("pattern_library", library)
      let complete = fn[proc(index, kind: uint32, value: int64) {.cdecl.}](
        handle, "gene_pattern_complete")
      let rejected = fn[Count](handle, "gene_pattern_rejected")
      fn[Action](handle, "gene_pattern_start_retry")()
      discard run(compileSource(patternSource), scope)
      proc eval(source: string): Value =
        run(compileSource(source), newScope(scope))
      proc drive(tasks: openArray[Value]) =
        for _ in 0 ..< 6000:
          var done = true
          for task in tasks: done = done and task.taskDone
          if done: return
          discard eval("($sleep 5)")
      proc start(index: int): Value = eval("(native/start " & $index & ")")

      # Overflow: the queue holds one record, so the second and third are
      # rejected. A rejection fails the subscription; the supervisor reopens
      # it and the retry timer delivers the stored records, including the last.
      let first = @[start(0), start(1), start(2)]
      complete(0, 0, 10)
      complete(1, 0, 11)
      complete(2, 0, 12) # no completion follows this one
      drive(first)
      for i, task in first:
        check task.taskDone and task.taskResult.intVal == 10 + i
      check rejected() >= 1
      # The last completion itself was rejected, and no completion followed
      # it; the retry timer, not a later completion, delivered it.
      check fn[Index](handle, "gene_pattern_rejections")(2) >= 1
      check fn[Index](handle, "gene_pattern_retry_delivered")(2) == 1
      let afterOverflow = eval("reopened").intVal
      check afterOverflow >= 1

      # A malformed record settles its Task and keeps the subscription open.
      let malformed = start(3)
      complete(3, 2, 0)
      drive([malformed])
      # The handler's own catch settled it: the error is its RuntimeError,
      # and the subscription that delivered it is still active.
      let malformedProbe = newScope(scope)
      malformedProbe.define("subject", malformed)
      let malformedOutcome = run(compileSource("(outcome subject)"),
                                 malformedProbe)
      check malformedOutcome.listItems[0].strVal == "runtime"
      check malformedOutcome.listItems[1].strVal == "malformed record"
      check eval("(let s (current_sub .status)) s/state").strVal == "active"
      let typed = start(4)
      complete(4, 1, 44)
      drive([typed])
      let probe = newScope(scope)
      probe.define("subject", typed)
      let typedOutcome = run(compileSource("(outcome subject)"), probe)
      check typedOutcome.listItems[0].strVal == "gpu"
      check typedOutcome.listItems[2].intVal == 44

      # A panicking and a cancelled handler each close the subscription; the
      # supervisor survives both and the redelivered records settle.
      let panicked = start(5)
      complete(5, 3, 55)
      drive([panicked])
      check panicked.taskDone and panicked.taskResult.intVal == 55
      let afterPanic = eval("reopened").intVal
      check afterPanic > afterOverflow
      let cancelled = start(6)
      complete(6, 4, 66)
      drive([cancelled])
      check cancelled.taskDone and cancelled.taskResult.intVal == 66
      check eval("reopened").intVal > afterPanic

      # The package's own close: wait for physical completion, settle or
      # retire, then close the subscription and the registrations.
      let running = @[start(7), start(8), start(9)]
      for i in 7'u32 .. 9'u32:
        check fn[proc(index, delay: uint32): uint32 {.cdecl.}](handle,
          "gene_pattern_complete_later")(i, 30) == 0
      fn[Action](handle, "gene_pattern_join_drivers")()
      # Every driver callback has returned and its thread has exited before
      # any token retires or the library's last borrow can be released.
      check fn[Count](handle, "gene_pattern_drivers_active")() == 0
      check fn[Count](handle, "gene_pattern_driver_completions")() >= 3
      drive(running)
      for i, task in running:
        check task.taskDone and task.taskResult.intVal == 7 + i
      discard eval("(native/retire_all)")
      fn[Action](handle, "gene_pattern_stop_retry")()
      discard eval("(set stopping true)")
      discard eval("(current_sub .IoResource:close)")
      let supervisor = eval("supervisor")
      drive([supervisor])
      check supervisor.taskDone
      check geneManagedStats(domain).producers == 0
      check fn[Count](handle, "gene_pattern_teardown")() == 0
      geneRootRelease(legacy)
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      for _ in 0 ..< 200:
        try:
          library.closeFfiLibrary() # the subscription retires its borrow
          break
        except GeneError:
          discard eval("($sleep 5)")
      check geneManagedClose(domain)

  test "the pattern closes in order under two-phase close":
    for dropHandle in [false, true]:
      let name = if dropHandle: "pattern-dropped" else: "pattern-explicit"
      let path = buildFixture(
        "tests/fixtures/native_ingress_pattern_fixture.c", name)
      let handle = loadLib(path)
      fn[SetOptions](handle, "gene_pattern_set_two_phase")(1)
      let host = newGlobalScope()
      discard run(compileSource(prelude), host)
      let scope = newScope(host)
      var module = geneManagedOpenNativeModule(path, name, scope)
      scope.define("module", module)
      scope.define("native", run(compileSource("(module .module)"), scope))
      scope.define("pattern_library",
        newFfiLibrary(cast[pointer](loadLib(path)), path, unloadFixture))
      fn[Action](handle, "gene_pattern_start_retry")()
      discard run(compileSource(patternSource), scope)
      proc eval(source: string): Value =
        run(compileSource(source), newScope(scope))
      var running: seq[Value]
      for i in 0 ..< 3:
        running.add eval("(native/start " & $i & ")")
        check fn[proc(index, delay: uint32): uint32 {.cdecl.}](handle,
          "gene_pattern_complete_later")(uint32(i), 40) == 0
      let recordsBefore = geneManagedNativeModuleCount()
      if dropHandle:
        module = NIL
        scope.assign("module", NIL)
      else:
        discard eval("(module .IoResource:close)")
      # Phase one: jobs still run; the handler's settle calls stay callable.
      for _ in 0 ..< 2000:
        geneManagedPollNativeModules()
        discard eval("($sleep 2)")
        var done = true
        for task in running: done = done and task.taskDone
        if done and geneManagedNativeModuleCount() < recordsBefore: break
        if done and not dropHandle and eval(
            "(let s (module .status)) s/state").strVal == "closed": break
      fn[Action](handle, "gene_pattern_join_drivers")()
      # Every driver callback has returned and its thread has exited before
      # any token retires or the library's last borrow can be released.
      check fn[Count](handle, "gene_pattern_drivers_active")() == 0
      check fn[Count](handle, "gene_pattern_driver_completions")() >= 3
      for i, task in running:
        check task.taskDone and task.taskResult.intVal == i
      if dropHandle:
        check geneManagedNativeModuleCount() == recordsBefore - 1
      else:
        check eval("(let s (module .status)) s/state").strVal == "closed"
      fn[Action](handle, "gene_pattern_stop_retry")()
      discard eval("(set stopping true)")
      discard eval("(current_sub .IoResource:close)")
      let supervisor = eval("supervisor")
      for _ in 0 ..< 400:
        if supervisor.taskDone: break
        discard eval("($sleep 5)")
      check supervisor.taskDone

# Last on purpose: under ASan on macOS, loading another instrumented image
# after one is pinned (RTLD_NODELETE) trips ASan's global registration inside
# dyld, so no fixture may load after this test.
suite "pinned native images":
  test "a pinned image keeps library code mapped after close":
    let path = buildFixture(asyncSource, "async-pinned")
    if path.len == 0: skip()
    else:
      var h = openHarness(path, "pinned", OptPin,
                          unload = unloadPinnedFixture)
      let tailDone = fn[Count](h.handle, "gene_async_tail_done")
      let driver = fn[Driver](h.handle, "gene_async_driver_callback")
      let task = h.start(1)
      check fn[Index](h.handle, "gene_async_tail_worker")(1) == 0
      var driverThread: Thread[Driver]
      createThread(driverThread, proc(callback: Driver) {.thread.} =
        sleep(20)
        callback(), driver)
      for _ in 0 ..< 100:
        discard geneManagedPoll(h.domain)
        if task.taskDone: break
        sleep(5)
      check task.taskResult.intVal == 7
      h.closeHarness() # unloads, but the pinned image stays mapped
      joinThread(driverThread)
      for _ in 0 ..< 100:
        if tailDone() == 2: break
        sleep(10)
      check tailDone() == 2
