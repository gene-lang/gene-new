import gene/[compiler, native_api, native_managed, types, vm]
import std/[dynlib, os, osproc, strtabs, streams, strutils, unittest]

type
  SetMode = proc(value: uint32) {.cdecl.}
  ReadCount = proc(): uint32 {.cdecl.}
  Invoke = proc(input: int64, value: ptr int64, status,
                hasError: ptr uint32): uint32 {.cdecl.}
  ReadI64 = proc(value: ptr int64): uint32 {.cdecl.}
  ReadStatus = proc(): uint32 {.cdecl.}
  ReadId = proc(): uint64 {.cdecl.}
  ReleaseSaved = proc() {.cdecl.}
  TaskAction = proc(accepted: ptr uint8): uint32 {.cdecl.}
  TaskComplete = proc(value: int64, accepted: ptr uint8): uint32 {.cdecl.}
  StressCount = proc(count: uint32): uint32 {.cdecl.}
  StressRelease = proc() {.cdecl.}
  StressJoin = proc(completed, retired, accepted,
                    late: ptr uint32): uint32 {.cdecl.}
  SubmitCopy = proc(kind: uint32, scalar: int64, data: ptr uint8,
                    length: csize_t, attached: uint8): uint32 {.cdecl.}
  SubmitCopyF64 = proc(value: cdouble, attached: uint8): uint32 {.cdecl.}
  FloatRoundtrip = proc(value: cdouble, output: ptr cdouble,
                        attached: uint8): uint32 {.cdecl.}

proc unloadFixture(address: pointer) {.nimcall.} =
  unloadLib(cast[LibHandle](address))

proc buildFixture(): string =
  let compiler = findExe("cc")
  if compiler.len == 0: return ""
  let directory = getTempDir() / "gene-native-callback-abi-fixture"
  createDir(directory)
  result = directory / (when defined(macosx): "callback.dylib"
                        else: "callback.so")
  var args = when defined(macosx): @["-dynamiclib", "-fPIC"]
             else: @["-shared", "-fPIC"]
  args.add @["-std=c11", "-pthread", "-Isrc/gene",
             "tests/fixtures/native_callback_abi_fixture.c", "-o", result]
  when defined(geneNativeAsan): args.add "-fsanitize=address"
  when defined(geneNativeTsan): args.add "-fsanitize=thread"
  let environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): environment[key] = value
  when defined(macosx):
    let sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if dirExists(sdk): environment["SDKROOT"] = sdk
  let process = startProcess(compiler, getCurrentDir(), args,
                             env = environment,
                             options = {poStdErrToStdOut})
  let diagnostics = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  if code != 0:
    raise newException(ValueError,
      "native callback C fixture failed to compile: " & diagnostics)

suite "managed native C callback registration":
  test "copied Task queue bounds preserve a retryable producer":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
        environment, "copy-queue-fixture", GeneApiTaskCopyFeature)
      check loaded.status == gsOk
      let setMode = cast[SetMode](symAddr(handle,
        "gene_test_api_set_callback_mode"))
      let submit = cast[SubmitCopy](symAddr(handle,
        "gene_test_api_task_submit_copy"))
      let close = cast[ReadStatus](symAddr(handle, "gene_test_api_close"))
      let waitClosed = cast[ReadStatus](symAddr(handle,
        "gene_test_api_wait"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      let legacy = geneWithNativeBorrow(loaded.value,
        proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
      let callScope = newScope(host)
      callScope.define("native_mod", geneRootGet(legacy))
      let invocation = compileSource("(native_mod/native_plus_one 1)")
      setMode(11)
      let rounds = parseInt(getEnv("GENE_NATIVE_TASK_COPY_ROUNDS", "1"))
      doAssert rounds > 0 and rounds <= 1000
      for _ in 0 ..< rounds:
        var tasks: seq[Value]
        for _ in 0 ..< 256:
          tasks.add run(invocation, callScope)
          check submit(0, 0, nil, 0, 0) == 0
        let retry = run(invocation, callScope)
        check submit(0, 0, nil, 0, 0) == 1
        check geneManagedStats(domain).producers == 257
        check geneManagedStats(domain).copiedQueued == 256
        check geneManagedPoll(domain) == 32
        check geneManagedStats(domain).copiedQueued == 224
        check submit(0, 0, nil, 0, 0) == 0
        tasks.add retry
        for _ in 0 ..< 8:
          discard geneManagedPoll(domain)
        check geneManagedStats(domain).producers == 0
        check geneManagedStats(domain).copiedQueued == 0
        check geneManagedStats(domain).copiedReserved == 0
        for task in tasks:
          check task.taskDone and task.taskResult.kind == vkNil
      when defined(geneNativeCopyBudgetProbe):
        block:
          let largeTask = run(invocation, callScope)
          var large = newString(GeneApiMaxCopyBytes)
          check submit(4, 0, cast[ptr uint8](addr large[0]),
                       csize_t(large.len), 0) == 0
          let smallTask = run(invocation, callScope)
          var small = "x"
          check submit(4, 0, cast[ptr uint8](addr small[0]), 1, 0) == 1
          check geneManagedStats(domain).copiedBytes == GeneApiMaxCopyBytes
          check geneManagedPoll(domain) == 1
          check largeTask.taskResult.bytesVal.len == GeneApiMaxCopyBytes
          check submit(4, 0, cast[ptr uint8](addr small[0]), 1, 0) == 0
          check geneManagedPoll(domain) == 1
          check smallTask.taskResult.bytesVal == "x"
      check close() == 0 and waitClosed() == 0
      releaseSaved()
      geneRootRelease(legacy)
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "copied C Task results construct on the root lane":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
        environment, "copy-fixture",
        GeneApiCallbackFeature or GeneApiTaskProducerFeature or
          GeneApiTaskCopyFeature or GeneApiFloatFeature)
      check loaded.status == gsOk
      let setMode = cast[SetMode](symAddr(handle,
        "gene_test_api_set_callback_mode"))
      let submit = cast[SubmitCopy](symAddr(handle,
        "gene_test_api_task_submit_copy"))
      let submitFloat = cast[SubmitCopyF64](symAddr(handle,
        "gene_test_api_task_submit_copy_f64"))
      let floatRoundtrip = cast[FloatRoundtrip](symAddr(handle,
        "gene_test_api_f64_roundtrip"))
      let startAsync = cast[ReadStatus](symAddr(handle,
        "gene_test_api_start_async_copy"))
      let joinAsync = cast[ReadStatus](symAddr(handle,
        "gene_test_api_join_async_copy"))
      let close = cast[ReadStatus](symAddr(handle, "gene_test_api_close"))
      let waitClosed = cast[ReadStatus](symAddr(handle,
        "gene_test_api_wait"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      let legacy = geneWithNativeBorrow(loaded.value,
        proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
      let callScope = newScope(host)
      callScope.define("native_mod", geneRootGet(legacy))
      let invocation = compileSource("(native_mod/native_plus_one 1)")
      setMode(11)
      when defined(gcAtomicArc) and compileOption("threads"):
        const attachedMode = 1'u8
      else:
        const attachedMode = 0'u8
      var copiedFloat: cdouble
      check floatRoundtrip(3.25, addr copiedFloat, attachedMode) == 0
      check copiedFloat == 3.25

      let number = run(invocation, callScope)
      check submit(2, 812, nil, 0, 0) == 0
      check submit(2, 813, nil, 0, 0) == 1 # queue admission consumed token
      check not number.taskDone
      check geneManagedPoll(domain) == 1
      check number.taskResult.intVal == 812

      var word = "naïve"
      let textTask = run(invocation, callScope)
      check submit(3, 0, cast[ptr uint8](addr word[0]),
                   csize_t(word.len), attachedMode) == 0
      word[0] = 'X' # the C span no longer owns the queued bytes
      check geneManagedStats(domain).copiedBytes == 6
      check geneManagedPoll(domain) == 1
      check geneManagedStats(domain).copiedBytes == 0
      check textTask.taskResult.strVal == "naïve"

      var octets = "a\0b"
      let bytesTask = run(invocation, callScope)
      check submit(4, 0, cast[ptr uint8](addr octets[0]),
                   csize_t(octets.len), attachedMode) == 0
      octets[0] = 'X'
      check geneManagedPoll(domain) == 1
      check bytesTask.taskResult.bytesVal == "a\0b"

      let boolean = run(invocation, callScope)
      check submit(1, 1, nil, 0, 0) == 0
      check geneManagedPoll(domain) == 1
      check boolean.taskResult.boolVal

      let fractional = run(invocation, callScope)
      check submitFloat(-12.75, attachedMode) == 0
      check geneManagedPoll(domain) == 1
      check fractional.taskResult.floatVal == -12.75

      var invalid = "\xFF"
      let invalidTask = run(invocation, callScope)
      check submit(3, 0, cast[ptr uint8](addr invalid[0]), 1, 0) == 0
      check geneManagedPoll(domain) == 1
      check invalidTask.taskHasError
      check invalidTask.taskErrorMsg.contains("UTF-8")

      let canceled = run(invocation, callScope)
      check nativeTaskCancel(canceled, callScope)
      check submit(1, 1, nil, 0, 0) == 0
      check geneManagedPoll(domain) == 1
      check canceled.taskCancelled

      let queuedCanceled = run(invocation, callScope)
      check submit(2, 9, nil, 0, 0) == 0
      check nativeTaskCancel(queuedCanceled, callScope)
      check geneManagedPoll(domain) == 1
      check queuedCanceled.taskCancelled

      let retry = run(invocation, callScope)
      check submit(4, 0, nil, 1, 0) == 1 # failed validation keeps token
      check submit(4, 0, cast[ptr uint8](addr invalid[0]),
                   csize_t(GeneApiMaxCopyBytes + 1), 0) == 1
      when defined(geneNativeCopyAllocationProbe):
        geneFailNextNativeCopyAllocation()
        check submit(4, 0, cast[ptr uint8](addr invalid[0]), 1, 0) == 1
        check geneManagedStats(domain).copiedReserved == 0
      check submit(0, 0, nil, 0, 0) == 0
      check geneManagedPoll(domain) == 1
      check retry.taskResult.kind == vkNil

      when defined(gcAtomicArc) and compileOption("threads"):
        let afterClose = run(invocation, callScope)
        check close() == 0 and waitClosed() == 0
        check not geneManagedClose(domain)
        check startAsync() == 0
        var polls = 0
        while not afterClose.taskDone and polls < 1000:
          discard geneManagedPoll(domain)
          os.sleep(1)
          inc polls
        check joinAsync() == 0
        check afterClose.taskDone
        check afterClose.taskResult.strVal == "async-copy"
      else:
        check close() == 0 and waitClosed() == 0
      check geneManagedStats(domain).producers == 0
      releaseSaved()
      geneRootRelease(legacy)
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "concurrent C producers retire after mixed user cancellation":
    when not (defined(gcAtomicArc) and compileOption("threads")):
      skip()
    else:
      let path = buildFixture()
      if path.len == 0:
        skip()
      else:
        let count = parseInt(getEnv("GENE_NATIVE_TASK_STRESS_COUNT", "128"))
        doAssert count > 0 and count <= 200000
        let handle = loadLib(path)
        check handle != nil
        let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
        let host = newGlobalScope()
        discard run(compileSource("nil"), host)
        let domain = geneNewManagedDomain(host)
        let environment = geneNewManagedEnvironment(domain, host)
        let libraryRoot = geneManagedRootFromVm(domain, host, library)
        let loaded = geneManagedLoadModule(domain, libraryRoot,
          environment, "stress-fixture",
          GeneApiCallbackFeature or GeneApiTaskProducerFeature or
            GeneApiAttachedFeature)
        check loaded.status == gsOk
        let setMode = cast[SetMode](symAddr(handle,
          "gene_test_api_set_callback_mode"))
        let prepare = cast[StressCount](symAddr(handle,
          "gene_test_api_stress_prepare"))
        let start = cast[StressCount](symAddr(handle,
          "gene_test_api_stress_start"))
        let releaseWorkers = cast[StressRelease](symAddr(handle,
          "gene_test_api_stress_release"))
        let joinWorkers = cast[StressJoin](symAddr(handle,
          "gene_test_api_stress_join"))
        let close = cast[ReadStatus](symAddr(handle, "gene_test_api_close"))
        let waitClosed = cast[ReadStatus](symAddr(handle,
          "gene_test_api_wait"))
        let releaseSaved = cast[ReleaseSaved](symAddr(handle,
          "gene_test_api_release_saved"))
        let legacy = geneWithNativeBorrow(loaded.value,
          proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
        let callScope = newScope(host)
        callScope.define("native_mod", geneRootGet(legacy))
        callScope.define("stress_index", newInt(0))
        let invocation = compileSource(
          "(native_mod/native_plus_one stress_index)")
        check prepare(uint32(count)) == 0
        setMode(10)
        var tasks = newSeq[Value](count)
        for i in 0 ..< count:
          callScope.assign("stress_index", newInt(int64(i)))
          tasks[i] = run(invocation, callScope)
          check tasks[i].kind == vkTask and not tasks[i].taskDone
        check geneManagedStats(domain).producers == count
        var preCancelled = 0
        for i in 0 ..< count:
          if i mod 4 == 0:
            check nativeTaskCancel(tasks[i], callScope)
            inc preCancelled
        check close() == 0 and waitClosed() == 0
        check not geneManagedClose(domain)
        expect GeneError:
          library.closeFfiLibrary()
        check start(4) == 0 # all workers attach after close and wait
        releaseWorkers()
        for i in 0 ..< count:
          if i mod 5 == 0:
            discard nativeTaskCancel(tasks[i], callScope)
        var completed, retired, accepted, late: uint32
        check joinWorkers(addr completed, addr retired,
                          addr accepted, addr late) == 0
        check completed + retired == uint32(count)
        check retired == uint32((count + 10) div 11)
        check accepted + late == uint32(count)
        check late >= uint32(preCancelled)
        for task in tasks:
          check task.taskDone
        tasks.setLen(0)
        let drained = geneManagedStats(domain)
        check drained.producers == 0 and drained.attachments == 0
        check not geneManagedClose(domain)
        releaseSaved()
        geneRootRelease(legacy)
        geneManagedRelease(loaded.value)
        geneManagedRelease(libraryRoot)
        geneManagedEnvironmentRelease(environment)
        library.closeFfiLibrary()
        check geneManagedClose(domain)

  test "C Task producer outlives cancellation and callback registration":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
        environment, "task-fixture",
        GeneApiCallbackFeature or GeneApiTaskProducerFeature)
      check loaded.status == gsOk
      let setMode = cast[SetMode](symAddr(handle,
        "gene_test_api_set_callback_mode"))
      let complete = cast[TaskComplete](symAddr(handle,
        "gene_test_api_task_complete"))
      let completeAttached = cast[TaskComplete](symAddr(handle,
        "gene_test_api_task_complete_attached"))
      let completeNil = cast[TaskAction](symAddr(handle,
        "gene_test_api_task_complete_nil"))
      let completeNilAttached = cast[TaskAction](symAddr(handle,
        "gene_test_api_task_complete_nil_attached"))
      let taskFail = cast[TaskAction](symAddr(handle,
        "gene_test_api_task_fail"))
      let cancel = cast[TaskAction](symAddr(handle,
        "gene_test_api_task_cancel"))
      let retire = cast[TaskAction](symAddr(handle,
        "gene_test_api_task_retire"))
      let close = cast[ReadStatus](symAddr(handle, "gene_test_api_close"))
      let outside = cast[ReadStatus](symAddr(handle,
        "gene_test_api_new_task_outside_callback"))
      let waitClosed = cast[ReadStatus](symAddr(handle, "gene_test_api_wait"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      let legacy = geneWithNativeBorrow(loaded.value,
        proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
      let callScope = newScope(host)
      callScope.define("native_mod", geneRootGet(legacy))
      check outside() == 1
      setMode(9)
      var accepted: uint8
      let first = run(compileSource("(native_mod/native_plus_one 1)"),
                      callScope)
      check first.kind == vkTask and not first.taskDone
      check geneManagedStats(domain).producers == 1
      check complete(42, addr accepted) == 0 and accepted == 1
      check first.taskDone and first.taskResult.intVal == 42
      check geneManagedStats(domain).producers == 0
      check retire(addr accepted) == 1 # consumed ticket is stale

      let second = run(compileSource("(native_mod/native_plus_one 2)"),
                       callScope)
      check nativeTaskCancel(second, callScope)
      check cancel(addr accepted) == 0 and accepted == 0
      check second.taskCancelled
      check geneManagedStats(domain).producers == 1
      check complete(99, addr accepted) == 0 and accepted == 0
      check geneManagedStats(domain).producers == 0

      let third = run(compileSource("(native_mod/native_plus_one 3)"),
                      callScope)
      check taskFail(addr accepted) == 0 and accepted == 1
      check third.taskHasError and third.taskErrorMsg ==
        "native producer failure"

      let fourth = run(compileSource("(native_mod/native_plus_one 4)"),
                       callScope)
      check cancel(addr accepted) == 0 and accepted == 1
      check geneManagedStats(domain).producers == 1
      check retire(addr accepted) == 0 and accepted == 0
      check fourth.taskCancelled

      let retiredPending = run(compileSource(
        "(native_mod/native_plus_one 7)"), callScope)
      check retire(addr accepted) == 0 and accepted == 1
      check retiredPending.taskCancelled

      when defined(gcAtomicArc) and compileOption("threads"):
        let attached = run(compileSource(
          "(native_mod/native_plus_one 6)"), callScope)
        check completeAttached(66, addr accepted) == 0 and accepted == 1
        check attached.taskDone and attached.taskResult.intVal == 66
        check geneManagedStats(domain).producers == 0

      let fifth = run(compileSource("(native_mod/native_plus_one 5)"),
                      callScope)
      check close() == 0 and waitClosed() == 0
      expect GeneError:
        library.closeFfiLibrary()
      check geneManagedStats(domain).producers == 1
      check not geneManagedClose(domain)
      when defined(gcAtomicArc) and compileOption("threads"):
        check completeNilAttached(addr accepted) == 0 and accepted == 1
      else:
        check completeNil(addr accepted) == 0 and accepted == 1
      check fifth.taskDone and fifth.taskResult.kind == vkNil
      check not geneManagedClose(domain) # drains attached-lane library release
      releaseSaved()
      geneRootRelease(legacy)
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "temporary IDs, typed outcomes, reentrant close and library retirement":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
                                        environment, "callback-fixture",
                                        GeneApiCallbackFeature)
      check loaded.status == gsOk and loaded.value != nil
      let invoke = cast[Invoke](symAddr(handle, "gene_test_api_invoke"))
      let setMode = cast[SetMode](symAddr(handle,
        "gene_test_api_set_callback_mode"))
      let calls = cast[ReadCount](symAddr(handle, "gene_test_api_calls"))
      let retires = cast[ReadCount](symAddr(handle, "gene_test_api_retires"))
      let closeInside = cast[ReadCount](symAddr(handle,
        "gene_test_api_close_inside_status"))
      let reentry = cast[ReadCount](symAddr(handle,
        "gene_test_api_retire_reentry_status"))
      let stale = cast[ReadStatus](symAddr(handle,
        "gene_test_api_temporary_is_stale"))
      let staleEnvironment = cast[ReadStatus](symAddr(handle,
        "gene_test_api_environment_is_stale"))
      let retained = cast[ReadI64](symAddr(handle,
        "gene_test_api_retained_argument"))
      let waitClosed = cast[ReadStatus](symAddr(handle, "gene_test_api_wait"))
      let close = cast[ReadStatus](symAddr(handle, "gene_test_api_close"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      var value: int64
      var status, hasError: uint32
      check invoke(41, addr value, addr status, addr hasError) == 0
      check status == 0 and value == 42 and hasError == 0
      check stale() == 1
      check staleEnvironment() == 1
      check retained(addr value) == 0 and value == 41
      block:
        let legacy = geneWithNativeBorrow(loaded.value,
          proc(b: GeneNativeBorrow): GeneRoot = geneExportManagedRoot(b))
        let moduleValue = geneRootGet(legacy)
        let callScope = newScope(host)
        callScope.define("native_mod", moduleValue)
        setMode(6)
        check run(compileSource(
          "(native_mod/native_plus_one ^step 4 6)"), callScope).intVal == 10
        geneRootRelease(legacy)
      check staleEnvironment() == 1
      expect GeneError:
        library.closeFfiLibrary()
      setMode(1)
      check invoke(1, addr value, addr status, addr hasError) == 0
      check status == 1 and hasError == 1
      setMode(2)
      check invoke(1, addr value, addr status, addr hasError) == 0
      check status == 2 and hasError == 1
      setMode(3)
      check invoke(1, addr value, addr status, addr hasError) == 0
      check status == 3
      setMode(5)
      check invoke(1, addr value, addr status, addr hasError) == 0
      check status == 1
      setMode(4)
      check invoke(5, addr value, addr status, addr hasError) == 0
      check status == 0 and value == 6
      check closeInside() == 4 # self-close defers until the C frame exits
      check retires() == 1 and reentry() == 4
      check close() == 0 and retires() == 1
      let callsAtClose = calls()
      check invoke(5, addr value, addr status, addr hasError) == 0
      check status == 1 and calls() == callsAtClose
      check waitClosed() == 0
      check waitClosed() == 1 # the token is consumed by the first wait
      releaseSaved()
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "initializer failure retires registered context and releases all IDs":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      let failInit = cast[SetMode](symAddr(handle,
        "gene_test_api_fail_initializer"))
      let retires = cast[ReadCount](symAddr(handle, "gene_test_api_retires"))
      failInit(1)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let before = geneManagedStats(domain)
      when defined(geneRcStats):
        var warmManaged = -1
      for i in 0 ..< 100:
        let failed = geneManagedLoadModule(domain, libraryRoot,
                                          environment, "failed-callback-" & $i)
        check failed.status == gsError
        check retires() == uint32(i + 1)
        when defined(geneRcStats):
          if i == 0: warmManaged = liveManaged
          elif i in [1, 9, 99]: check liveManaged == warmManaged
      let after = geneManagedStats(domain)
      check after.roots == before.roots
      check after.registrations == 0
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "failed duplicate registration leaves its C context with the caller":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let duplicate = cast[SetMode](symAddr(handle,
        "gene_test_api_duplicate_registration"))
      let duplicateStatus = cast[ReadStatus](symAddr(handle,
        "gene_test_api_duplicate_status"))
      let callerFreed = cast[ReadCount](symAddr(handle,
        "gene_test_api_caller_freed_contexts"))
      let retires = cast[ReadCount](symAddr(handle, "gene_test_api_retires"))
      let close = cast[ReadStatus](symAddr(handle, "gene_test_api_close"))
      let waitClosed = cast[ReadStatus](symAddr(handle, "gene_test_api_wait"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      duplicate(1)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
                                        environment, "duplicate-callback")
      check loaded.status == gsOk
      check duplicateStatus() == 1 and callerFreed() == 1
      check retires() == 0
      check close() == 0 and waitClosed() == 0
      check retires() == 1
      releaseSaved()
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "a waiter created inside the callback settles after physical retirement":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      host.define("await_close", run(compileSource("(fn [t] (await t))"), host))
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
                                        environment, "pending-waiter")
      check loaded.status == gsOk
      let setMode = cast[SetMode](symAddr(handle,
        "gene_test_api_set_callback_mode"))
      let invoke = cast[Invoke](symAddr(handle, "gene_test_api_invoke"))
      let closeInside = cast[ReadStatus](symAddr(handle,
        "gene_test_api_close_inside_status"))
      let pendingWait = cast[ReadStatus](symAddr(handle,
        "gene_test_api_pending_wait_status"))
      let awaitWaiter = cast[ReadStatus](symAddr(handle,
        "gene_test_api_await_waiter"))
      let retires = cast[ReadCount](symAddr(handle, "gene_test_api_retires"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      setMode(7)
      var value: int64
      var status, hasError: uint32
      check invoke(7, addr value, addr status, addr hasError) == 0
      check status == 0 and value == 8
      check closeInside() == 4 and pendingWait() == 0
      check retires() == 1
      check awaitWaiter() == 0
      releaseSaved()
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "cancelling a close waiter does not cancel context retirement":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      host.define("await_close", run(compileSource("(fn [t] (await t))"), host))
      host.define("cancel_waiter", run(compileSource("(fn [t] (t .cancel))"), host))
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
                                        environment, "cancelled-waiter")
      check loaded.status == gsOk
      let setMode = cast[SetMode](symAddr(handle,
        "gene_test_api_set_callback_mode"))
      let invoke = cast[Invoke](symAddr(handle, "gene_test_api_invoke"))
      let awaitWaiter = cast[ReadStatus](symAddr(handle,
        "gene_test_api_await_waiter"))
      let retires = cast[ReadCount](symAddr(handle, "gene_test_api_retires"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      setMode(8)
      var value: int64
      var status, hasError: uint32
      check invoke(1, addr value, addr status, addr hasError) == 0
      check status == 0 and value == 2
      check retires() == 1
      check awaitWaiter() == 3
      releaseSaved()
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "repeated registrations retire without root or token growth":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let baseline = geneManagedStats(domain).roots
      let lifetimes = parseInt(getEnv("GENE_NATIVE_CALLBACK_LIFETIMES", "100"))
      check lifetimes > 0
      let close = cast[ReadStatus](symAddr(handle, "gene_test_api_close"))
      let waitClosed = cast[ReadStatus](symAddr(handle, "gene_test_api_wait"))
      let readId = cast[ReadId](symAddr(handle,
        "gene_test_api_registration_id"))
      let retires = cast[ReadCount](symAddr(handle, "gene_test_api_retires"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      var previousId: uint64
      when defined(geneRcStats):
        var warmManaged = -1
      for i in 0 ..< lifetimes:
        let loaded = geneManagedLoadModule(domain, libraryRoot,
                                          environment, "callback-" & $i)
        check loaded.status == gsOk
        check readId() > previousId
        previousId = readId()
        check close() == 0
        check waitClosed() == 0
        releaseSaved()
        geneManagedRelease(loaded.value)
        let stats = geneManagedStats(domain)
        check stats.roots == baseline and stats.registrations == 0
        when defined(geneRcStats):
          if i == 0: warmManaged = liveManaged
          elif i in [1, 9, lifetimes - 1]:
            check liveManaged == warmManaged
      check retires() == uint32(lifetimes)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)

  test "domain shutdown can close and drain a live registration":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
      let host = newGlobalScope()
      discard run(compileSource("nil"), host)
      let domain = geneNewManagedDomain(host)
      let environment = geneNewManagedEnvironment(domain, host)
      let libraryRoot = geneManagedRootFromVm(domain, host, library)
      let loaded = geneManagedLoadModule(domain, libraryRoot,
                                        environment, "shutdown-callback")
      check loaded.status == gsOk
      let retires = cast[ReadCount](symAddr(handle, "gene_test_api_retires"))
      let waitClosed = cast[ReadStatus](symAddr(handle,
        "gene_test_api_wait_without_kind"))
      let releaseSaved = cast[ReleaseSaved](symAddr(handle,
        "gene_test_api_release_saved"))
      check not geneManagedClose(domain)
      check retires() == 1
      check waitClosed() == 0
      releaseSaved()
      geneManagedRelease(loaded.value)
      geneManagedRelease(libraryRoot)
      geneManagedEnvironmentRelease(environment)
      library.closeFfiLibrary()
      check geneManagedClose(domain)
