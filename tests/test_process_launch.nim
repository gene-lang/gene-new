import std/[atomics, json, options, os, posix, streams, strutils, tempfiles, unittest]
import gene/process_launch

when defined(geneExecTests) and compileOption("threads"):
  proc shutdownLaunch(path: cstring) {.thread.} =
    let process = launchProcess(getAppFilename(),
      ["--process-fixture", "shutdown-child", $path], ownGroup = true)
    discard process.waitForExit()
    process.close()

  proc releaseShutdownSpawn() {.thread.} =
    sleep(50)
    testHoldSpawn(0)

if paramCount() >= 2 and paramStr(1) == "--process-fixture":
  case paramStr(2)
  of "cwd": stdout.writeLine(getCurrentDir())
  of "env":
    stdout.writeLine(getEnv("GENE_EXEC_VALUE", "missing"))
    stdout.writeLine(getEnv("PATH", "missing"))
  of "args":
    var arguments: seq[string]
    for i in 3 .. paramCount(): arguments.add paramStr(i)
    stdout.writeLine($(%arguments))
  of "status": quit(37)
  of "sleep": sleep(100)
  of "shutdown-child":
    writeFile(paramStr(3), $getCurrentProcessId())
    sleep(2000) # Bound orphan lifetime if shutdown cleanup regresses.
  of "shutdown-parent":
    when defined(geneExecTests) and compileOption("threads"):
      let path = allocCStringArray(@[paramStr(3)])
      testHoldSpawn(1)
      var launch: Thread[cstring]
      createThread(launch, shutdownLaunch, path[0])
      for attempt in 0..<1000:
        if testSpawnWaiting() != 0 and fileExists(paramStr(3)): break
        sleep(1)
      if testSpawnWaiting() == 0 or not fileExists(paramStr(3)): quit(5)
      var release: Thread[void]
      createThread(release, releaseShutdownSpawn)
      quit(0) # Deliberately exit while launch is between spawn and registration.
    else: quit(2)
  else: quit(2)
  quit(0)

proc captured(program: string, args: openArray[string], directory = "",
              environment = none(seq[string])): tuple[status: int, text: string] =
  let child = launchProcess(program, args, directory, environment)
  defer: child.close()
  child.closeInput()
  result.text = child.outputStream.readAll()
  result.status = child.waitForExit()

when compileOption("threads"):
  type DirectoryProbe = object
    executable, directory, expected: cstring
    failures: Atomic[int]
  proc overlappingLaunches(probe: ptr DirectoryProbe) {.thread.} =
    for i in 0..<24:
      try:
        let directory = if i mod 2 == 0: $probe.directory else: ""
        let process = launchProcess($probe.executable,
          ["--process-fixture", "cwd"], directory)
        process.closeInput()
        discard process.outputStream.readAll()
        if process.waitForExit() != 0: discard probe.failures.fetchAdd(1)
        process.close()
        try:
          discard launchProcess("gene-missing-overlap-91f", directory = $probe.directory)
          discard probe.failures.fetchAdd(1)
        except OSError: discard
        if getCurrentDir() != $probe.expected or not fileExists("gene.nimble"):
          discard probe.failures.fetchAdd(1)
      except CatchableError: discard probe.failures.fetchAdd(1)

when defined(geneExecTests) and compileOption("threads"):
  type RetirementProbe = object
    slot: cint
    done: Atomic[int]
  proc retirePinnedGroup(probe: ptr RetirementProbe) {.thread.} =
    testRetireGroup(probe.slot)
    probe.done.store(1, moRelease)

suite "POSIX process launch":
  test "a failed launch never changes the parent's directory":
    let original = getCurrentDir()
    let directory = createTempDir("gene-launch-fail-", "")
    defer: removeDir(directory)
    expect OSError:
      discard launchProcess("gene-missing-process-9ae0174", directory = directory)
    check getCurrentDir() == original

  test "child cwd is isolated and bad directories report a launch error":
    let original = getCurrentDir()
    let directory = createTempDir("gene-launch-cwd-", "")
    defer: removeDir(directory)
    let child = captured(getAppFilename(), ["--process-fixture", "cwd"], directory)
    check child.status == 0
    check child.text.strip() == expandFilename(directory)
    check getCurrentDir() == original
    expect OSError:
      discard launchProcess(getAppFilename(), directory = directory / "missing")
    check getCurrentDir() == original

  test "literal arguments retain spaces empty strings and shell characters":
    let args = @["--process-fixture", "args", "", "two words", "$HOME", "a | b", "*.gene"]
    let child = captured(getAppFilename(), args)
    check child.status == 0
    check parseJson(child.text) == %args[2 .. ^1]

  test "the supplied environment controls both launch lookup and the child":
    let directory = createTempDir("gene-launch-path-", "")
    defer: removeDir(directory)
    let program = directory / "gene-path-fixture"
    createSymlink(getAppFilename(), program)
    defer: removeFile(program)
    let child = captured("gene-path-fixture", ["--process-fixture", "env"],
      environment = some(@["PATH=" & directory, "GENE_EXEC_VALUE=literal $HOME"]))
    check child.status == 0
    check child.text == "literal $HOME\n" & directory & "\n"

  test "relative PATH entries and executable paths use the child directory":
    let directory = createTempDir("gene-launch-relative-", "")
    defer: removeDir(directory)
    let program = directory / "gene-relative-fixture"
    createSymlink(getAppFilename(), program)
    defer: removeFile(program)
    let byPath = captured("gene-relative-fixture", ["--process-fixture", "cwd"],
      directory, some(@["PATH=."]))
    let byFile = captured("./gene-relative-fixture", ["--process-fixture", "cwd"],
      directory)
    check byPath.status == 0
    check byPath.text == byFile.text
    check byFile.status == 0
    check byFile.text.strip() == expandFilename(directory)

  test "scripts need a shebang or an explicitly selected interpreter":
    let directory = createTempDir("gene-launch-script-", "")
    defer: removeDir(directory)
    let program = directory / "script"
    writeFile(program, "printf explicit-shell\n")
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    defer: removeFile(program)
    expect OSError:
      discard launchProcess(program)
    let explicit = captured("/bin/sh", [program])
    check explicit.status == 0
    check explicit.text == "explicit-shell"
    writeFile(program, "#!/bin/sh\nprintf shebang\n")
    let withHeader = captured(program, [])
    check withHeader.status == 0
    check withHeader.text == "shebang"

  test "directory, PATH and executable dot components retain kernel semantics":
    let directory = createTempDir("gene-launch-components-", "")
    createDir(directory / "actual" / "inner")
    createSymlink(directory / "actual" / "inner", directory / "link")
    createSymlink(getAppFilename(), directory / "actual" / "component-tool")
    defer:
      removeFile(directory / "actual" / "component-tool")
      removeFile(directory / "link")
      removeDir(directory / "actual" / "inner")
      removeDir(directory / "actual")
      removeDir(directory)
    let relative = relativePath(directory, getCurrentDir()) & "/link/.."
    let byDir = captured(getAppFilename(), ["--process-fixture", "cwd"], relative)
    check byDir.text.strip() == expandFilename(directory / "actual")
    let byPath = captured("component-tool", ["--process-fixture", "status"],
      directory, some(@["PATH=link/.."]))
    check byPath.status == 37
    let byFile = captured("link/../component-tool", ["--process-fixture", "status"], directory)
    check byFile.status == 37
    expect OSError:
      discard launchProcess(getAppFilename(), directory =
        relativePath(directory, getCurrentDir()) & "/missing/..")

  test "PATH continues past denied candidates and retains permission errors":
    let directory = createTempDir("gene-launch-precedence-", "")
    createDir(directory / "first")
    createDir(directory / "second")
    let blocked = directory / "first" / "choice"
    let selected = directory / "second" / "choice"
    writeFile(blocked, "not executable")
    setFilePermissions(blocked, {fpUserRead, fpUserWrite})
    createSymlink(getAppFilename(), selected)
    defer:
      removeFile(blocked)
      removeFile(selected)
      removeDir(directory / "first")
      removeDir(directory / "second")
      removeDir(directory)
    check captured("choice", ["--process-fixture", "status"], directory,
      some(@["PATH=first:missing:second"])).status == 37
    var denied = false
    try:
      discard launchProcess("choice", directory = directory,
        environment = some(@["PATH=first:missing"]))
    except OSError as error: denied = error.errorCode == EACCES
    check denied

  test "exit observation keeps status waitable until the designated reap":
    let child = launchProcess(getAppFilename(), ["--process-fixture", "status"],
                              ownGroup = true)
    defer: child.close()
    child.closeInput()
    check child.waitExit(5000)
    check child.exitStatus == 37
    check posix.kill(Pid(child.processID), 0) == 0
    check child.reap() == 37
    check child.reap() == 37
    # Late signal requests on a reaped handle do not use a recycled PID.
    when defined(geneExecTests):
      let signals = testSignalCalls()
    child.killGroup()
    when defined(geneExecTests):
      check testSignalCalls() == signals
      check testUnsafeReaps() == 0
    var status: cint
    check waitpid(Pid(child.processID), status, WNOHANG) == -1
    check errno == ECHILD

  test "a bounded wait does not consume a live child":
    let child = launchProcess(getAppFilename(), ["--process-fixture", "sleep"])
    defer: child.close()
    child.closeInput()
    check not child.waitExit(0)
    check child.waitForExit(5000) == 0

  test "close caches final status and cannot close reused descriptors":
    let child = launchProcess(getAppFilename(), ["--process-fixture", "status"])
    check child.waitExit(5000)
    child.close()
    var pipe: array[2, cint]
    check processPipe(addr pipe) == 0
    defer:
      discard posix.close(pipe[0])
      discard posix.close(pipe[1])
    child.close()
    check child.waitForExit() == 37
    check fcntl(pipe[0], F_GETFD) >= 0
    check fcntl(pipe[1], F_GETFD) >= 0

  test "automatic SIGCHLD reaping is rejected before launch":
    var old, ignored: Sigaction
    ignored.sa_handler = SIG_IGN
    discard sigemptyset(ignored.sa_mask)
    require sigaction(SIGCHLD, ignored, old) == 0
    try:
      expect OSError:
        discard launchProcess(getAppFilename(), ["--process-fixture", "status"])
    finally:
      discard sigaction(SIGCHLD, old, nil)

  test "selected exit backend is observable":
    let process = launchProcess(getAppFilename(), ["--process-fixture", "sleep"])
    defer: process.close()
    when defined(linux) and defined(geneExecTests):
      if getEnv("GENE_TEST_EXEC_EXIT_BACKEND", "auto") == "poll":
        check not process.hasExitNotification
      else:
        # The qualification kernel supports pidfd; report feature detection
        # rather than claiming the fallback is an event-driven result.
        echo "  exit backend: ", (if process.hasExitNotification: "pidfd" else: "poll")
    else:
      echo "  exit backend: ", (if process.hasExitNotification: "notification" else: "poll")
    check process.waitForExit(5000) == 0

  when compileOption("threads"):
    test "overlapping launches and relative file checks never see child cwd":
      let directory = createTempDir("gene-launch-overlap-", "")
      defer: removeDir(directory)
      let text = allocCStringArray(@[getAppFilename(), directory, getCurrentDir()])
      defer: deallocCStringArray(text)
      var probe = DirectoryProbe(executable: text[0], directory: text[1], expected: text[2])
      var threads: array[3, Thread[ptr DirectoryProbe]]
      for thread in threads.mitems: createThread(thread, overlappingLaunches, addr probe)
      for i in 0..<200:
        check getCurrentDir() == $probe.expected
        check fileExists("gene.nimble")
        sleep(1)
      for thread in threads.mitems: joinThread(thread)
      check probe.failures.load() == 0

  when defined(geneExecTests) and compileOption("threads"):
    test "process exit closes the spawn-to-registration cleanup gap":
      let directory = createTempDir("gene-launch-shutdown-", "")
      let path = directory / "child.pid"
      defer:
        if fileExists(path): removeFile(path)
        removeDir(directory)
      let parent = launchProcess(getAppFilename(),
        ["--process-fixture", "shutdown-parent", path])
      defer: parent.close()
      check parent.waitForExit(5000) == 0
      require fileExists(path)
      let child = Pid(parseInt(readFile(path)))
      require child > 0
      var alive = true
      for attempt in 0..<30:
        when defined(linux):
          try: alive = ") Z " notin readFile("/proc/" & $child & "/stat")
          except IOError, OSError: alive = false
        else: alive = getpgid(child) >= 0
        if not alive: break
        sleep(10)
      check not alive

    test "registry retirement excludes an in-flight cleanup reader":
      # Synthetic identities exercise stale callbacks without signalling any
      # real process or relying on host PID exhaustion.
      let slot = testRegisterGroup(123456789)
      require slot >= 0
      check testPinGroup(slot) == 123456789
      var probe = RetirementProbe(slot: slot)
      var thread: Thread[ptr RetirementProbe]
      createThread(thread, retirePinnedGroup, addr probe)
      while testGroupPid(slot) != 0: sleep(1)
      check probe.done.load(moAcquire) == 0
      testUnpinGroup(slot)
      joinThread(thread)
      check probe.done.load(moAcquire) == 1
      check testPinGroup(slot) == 0
      testUnpinGroup(slot)
