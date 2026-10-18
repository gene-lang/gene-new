## Exec's public contract. Keep this suite standalone: its executable also
## serves as an isolated child that observes cwd, argv and environment.
import std/[json, monotimes, os, strutils, tempfiles, times, unittest]
import gene/[compiler, printer, types, vm]
when defined(geneExecTests): import gene/native_wake

if paramCount() >= 2 and paramStr(1) == "--exec-fixture":
  case paramStr(2)
  of "write":
    let payload = %*{"directory": getCurrentDir(),
      "value": getEnv("GENE_EXEC_VALUE", "missing"),
      "path": getEnv("PATH", "missing"),
      "empty": getEnv("GENE_EXEC_EMPTY", "missing"),
      "other": getEnv("GENE_EXEC_OTHER", "missing"),
      "removed": not existsEnv("GENE_EXEC_REMOVE")}
    writeFile(paramStr(3), $payload)
  of "print": stdout.write getEnv("GENE_EXEC_VALUE", "missing")
  of "sleep": sleep(if paramCount() > 2: parseInt(paramStr(3)) else: 100)
  of "late-line":
    sleep(180)
    stdout.writeLine("ready")
  of "wait":
    stdout.writeLine("ready")
    stdout.flushFile()
    while not fileExists(paramStr(3)): sleep(5)
  of "bulk":
    let chunk = repeat('x', 65536)
    for i in 0..<64:
      stdout.write(chunk)
      stderr.write(chunk)
  else: quit(2)
  quit(0)

proc execScope(directory: string): Scope =
  result = newGlobalScope(newApplication(getCurrentDir()))
  result.define("fixture", newStr(getAppFilename()))
  result.define("directory", newStr(directory))
  result.define("output", newStr(directory / "result.json"))

proc checkChildSettings(directory, parentPath: string) =
  let output = parseFile(directory / "result.json")
  check output["directory"].getStr == expandFilename(directory)
  check output["value"].getStr == "literal $HOME"
  check output["empty"].getStr == ""
  check output["removed"].getBool
  check output["path"].getStr == directory &
    (if parentPath.len > 0: $PathSep & parentPath else: "")

suite "os/exec child settings":
  test "detached launch exposes literal argv and the shared child environment contract":
    let directory = createTempDir("gene-public-detached-", "")
    defer: removeDir(directory)
    let scope = execScope(directory)
    scope.define("log", newStr(directory / "child.log"))
    let child = run(compileSource("""
      ($os/spawn_detached ^dir directory ^output log
        ^env {^GENE_EXEC_VALUE "literal $HOME" ^GENE_EXEC_EMPTY ""
              ^GENE_EXEC_REMOVE nil ^PATH directory}
        fixture "--exec-fixture" "write" output)
    """), scope)
    check child.kind == vkInt
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while not fileExists(directory / "result.json") and getMonoTime() < deadline: sleep(10)
    check fileExists(directory / "result.json")
    checkChildSettings(directory, getEnv("PATH"))
    check fileExists(directory / "child.log")
    check run(compileSource("($os/process_alive? ($os/process_id))"), scope).print() == "true"

  test "all six exec variants share dir and env semantics":
    let directory = createTempDir("gene-exec-settings-", "")
    let originalCwd = getCurrentDir()
    let parentPath = getEnv("PATH")
    let hadValue = existsEnv("GENE_EXEC_VALUE")
    let originalValue = getEnv("GENE_EXEC_VALUE")
    let hadRemove = existsEnv("GENE_EXEC_REMOVE")
    let originalRemove = getEnv("GENE_EXEC_REMOVE")
    putEnv("GENE_EXEC_VALUE", "parent")
    putEnv("GENE_EXEC_REMOVE", "parent")
    defer:
      if hadValue: putEnv("GENE_EXEC_VALUE", originalValue)
      else: delEnv("GENE_EXEC_VALUE")
      if hadRemove: putEnv("GENE_EXEC_REMOVE", originalRemove)
      else: delEnv("GENE_EXEC_REMOVE")
      removeFile(directory / "result.json")
      removeDir(directory)
    let options = """ ^dir directory
      ^env {^GENE_EXEC_VALUE "literal $HOME" ^GENE_EXEC_REMOVE nil
            ^GENE_EXEC_EMPTY "" ^PATH directory}
      fixture "--exec-fixture" "write" output"""
    for variant in ["exec", "exec_async", "exec_stream", "exec_stream_async",
                    "exec_stdio", "exec_stdio_async"]:
      let scope = execScope(directory)
      var call = "($os/" & variant & options
      var prefix = ""
      if variant == "exec_stream_async":
        prefix = "(let channel ($channel ^capacity 1)) "
        call.add " ^stdout_chan channel"
      call.add ")"
      if variant.endsWith("_async"): call = "(await " & call & ")"
      let source = prefix & "(let result " & call & ") " &
        (if "stdio" in variant: "result" else: "result/status")
      for inFiber in [false, true]:
        checkpoint variant & " fiber=" & $inFiber
        let invocation = if inFiber: "(await (spawn ^lane root (do " & source & ")))"
                         else: source
        check run(compileSource(invocation), scope).print() == "0"
        checkChildSettings(directory, parentPath)
        check getCurrentDir() == originalCwd
        check getEnv("GENE_EXEC_VALUE") == "parent"
        check getEnv("GENE_EXEC_REMOVE") == "parent"
        check getEnv("PATH") == parentPath

  test "async execution owns the submitted environment":
    let scope = execScope(getTempDir())
    let result = run(compileSource("""
      (let child_env {^GENE_EXEC_VALUE "submitted"})
      (let child ($os/exec_async ^env child_env fixture "--exec-fixture" "print"))
      (child_env .put "GENE_EXEC_VALUE" "changed")
      (/stdout (await child))
    """), scope)
    check result.print() == "\"submitted\""

  test "PATH prefixes affect executable lookup and relative entries use dir":
    let directory = createTempDir("gene-exec-lookup-", "")
    let program = directory / "gene-exec-lookup-fixture"
    createSymlink(getAppFilename(), program)
    defer:
      removeFile(program)
      removeDir(directory)
    let scope = execScope(directory)
    let result = run(compileSource("""
      (let direct ($os/exec ^dir directory
        ^env {^PATH "." ^GENE_EXEC_VALUE "direct"}
        "gene-exec-lookup-fixture" "--exec-fixture" "print"))
      (let async (await ($os/exec_async ^dir directory
        ^env {^PATH "." ^GENE_EXEC_VALUE "async"}
        "gene-exec-lookup-fixture" "--exec-fixture" "print")))
      [direct/stdout async/stdout]
    """), scope)
    check result.print() == "[\"direct\" \"async\"]"

  test "empty PATH prefixes retain inheritance and nil removes PATH":
    let directory = createTempDir("gene-exec-path-values-", "")
    let original = getEnv("PATH")
    defer:
      removeFile(directory / "result.json")
      removeDir(directory)
    let scope = execScope(directory)
    discard run(compileSource("""
      ($os/exec ^env {^PATH ""} fixture "--exec-fixture" "write" output)
    """), scope)
    check parseFile(directory / "result.json")["path"].getStr == original
    discard run(compileSource("""
      ($os/exec ^env {^PATH nil} fixture "--exec-fixture" "write" output)
    """), scope)
    check parseFile(directory / "result.json")["path"].getStr == "missing"
    check getEnv("PATH") == original

  test "shell sequences and pipelines receive the effective environment":
    let scope = execScope(getTempDir())
    let result = run(compileSource("""
      ($os/exec ^^full ^env {^GENE_EXEC_VALUE "one two"}
        "printf '%s' \"$GENE_EXEC_VALUE\" | tr a-z A-Z; printf done")
    """), scope)
    check result.mapEntries["status"].print() == "0"
    check result.mapEntries["stdout"].print() == "\"ONE TWOdone\""

  test "invalid environment settings fail before launching":
    for source in [
      """($os/exec ^env [] fixture "--exec-fixture" "sleep")""",
      """($os/exec ^env {^KEY 42} fixture "--exec-fixture" "sleep")""",
      """($os/exec ^env {^"BAD=KEY" "value"} fixture "--exec-fixture" "sleep")""",
      """($os/exec ^env {^"" "value"} fixture "--exec-fixture" "sleep")""",
      """($os/exec ^env {^KEY nul} fixture "--exec-fixture" "sleep")""",
      """(do (let overrides {}) (overrides .put nul "value")
        ($os/exec ^env overrides fixture "--exec-fixture" "sleep"))""",
      """($os/exec ^dir nul fixture "--exec-fixture" "sleep")""",
      """($os/exec ^cwd "." fixture "--exec-fixture" "sleep")"""]:
      let scope = execScope(getTempDir())
      scope.define("nul", newStr("bad\0value"))
      check run(compileSource("(try " & source &
        " false catch Any true)"), scope).print() == "true"

  test "captured synchronous execution supplies EOF on stdin":
    let scope = execScope(getTempDir())
    let result = run(compileSource("""
      (let plain ($os/exec "cat" ^timeout_ms 1000))
      (let streamed ($os/exec_stream "cat" ^timeout_ms 1000))
      [plain/status plain/timed_out streamed/status streamed/timed_out]
    """), scope)
    check result.print() == "[0 false 0 false]"

  test "relative dir preserves symlink and invalid dot components":
    let directory = createTempDir("gene-exec-relative-dir-", "")
    createDir(directory / "actual" / "inner")
    createSymlink(directory / "actual" / "inner", directory / "link")
    defer:
      if fileExists(directory / "result.json"): removeFile(directory / "result.json")
      removeFile(directory / "link")
      removeDir(directory / "actual" / "inner")
      removeDir(directory / "actual")
      removeDir(directory)
    let scope = execScope(directory)
    scope.define("raw_dir", newStr(relativePath(directory, getCurrentDir()) & "/link/.."))
    scope.define("bad_dir", newStr(relativePath(directory, getCurrentDir()) & "/missing/.."))
    for call in [
      """($os/exec ^dir raw_dir fixture "--exec-fixture" "write" output)""",
      """(await ($os/exec_async ^dir raw_dir fixture "--exec-fixture" "write" output))"""]:
      check run(compileSource("(/status " & call & ")"), scope).print() == "0"
      check parseFile(directory / "result.json")["directory"].getStr ==
        expandFilename(directory / "actual")
    check run(compileSource("""
      (try ($os/exec ^dir bad_dir fixture "--exec-fixture" "print") false catch Any true)
    """), scope).print() == "true"

  test "every variant rejects executable text without a shebang":
    let directory = createTempDir("gene-exec-script-policy-", "")
    let path = directory / "plain-script"
    writeFile(path, "exit 17\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    defer:
      removeFile(path)
      removeDir(directory)
    for variant in ["exec", "exec_async", "exec_stream", "exec_stream_async",
                    "exec_stdio", "exec_stdio_async"]:
      let scope = execScope(directory)
      scope.define("script", newStr(path))
      var invocation = "($os/" & variant & " script"
      if variant == "exec_stream_async": invocation.add " ^stdout_chan ($channel ^capacity 1)"
      invocation.add ")"
      if variant.endsWith("_async"): invocation = "(await " & invocation & ")"
      for inFiber in [false, true]:
        let call = if inFiber: "(await (spawn ^lane root " & invocation & "))"
                   else: invocation
        checkpoint variant & " fiber=" & $inFiber
        check run(compileSource("(try " & call & " false catch Any true)"), scope).print() == "true"

  test "PATH priority, empty inheritance, removal, and relative program paths":
    let directory = createTempDir("gene-exec-path-priority-", "")
    createDir(directory / "first")
    createDir(directory / "second")
    for pair in [("first", "11"), ("second", "22")]:
      let program = directory / pair[0] / "gene-path-choice"
      writeFile(program, "#!/bin/sh\nexit " & pair[1] & "\n")
      setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    let hadPath = existsEnv("PATH")
    let oldPath = getEnv("PATH")
    defer:
      if hadPath: putEnv("PATH", oldPath)
      else: delEnv("PATH")
      for entry in ["first", "second"]:
        removeFile(directory / entry / "gene-path-choice")
        removeDir(directory / entry)
      if fileExists(directory / "result.json"): removeFile(directory / "result.json")
      removeDir(directory)
    let scope = execScope(directory)
    putEnv("PATH", directory / "second")
    check run(compileSource("""
      (let selected ($os/exec ^dir directory ^env {^PATH "first:second"}
        "gene-path-choice"))
      (let relative (await ($os/exec_async ^dir directory "./second/gene-path-choice")))
      [selected/status relative/status]
    """), scope).print() == "[11 22]"
    for inherited in ["", "absent"]:
      if inherited == "absent": delEnv("PATH")
      else: putEnv("PATH", "")
      discard run(compileSource("""
        ($os/exec ^env {^PATH ""} fixture "--exec-fixture" "write" output)
      """), scope)
      check parseFile(directory / "result.json")["path"].getStr ==
        (if inherited == "absent": "missing" else: "")
      check run(compileSource("""
        (/status ($os/exec ^dir directory ^env {^PATH "first"} "gene-path-choice"))
      """), scope).print() == "11"
    putEnv("PATH", "/gene-unusable-parent-path")
    check run(compileSource("""
      (/status ($os/exec ^env {^PATH nil} "sh" "-c" "exit 0"))
    """), scope).print() == "0"

suite "os/exec notifications and monitor":
  when defined(geneExecTests):
    test "submission failure releases leases and leaves the next job usable":
      let scope = execScope(getTempDir())
      execRejectNextSubmission()
      check run(compileSource("""
        (try ($os/exec_async fixture "--exec-fixture" "print") false catch Any true)
      """), scope).print() == "true"
      check execPendingCounts() == (0, 0)
      check run(compileSource("""
        (/status (await ($os/exec_async fixture "--exec-fixture" "print")))
      """), scope).print() == "0"
      check execPendingCounts() == (0, 0)

    test "queued requests own cwd and environment and exclude queue time":
      let directory = createTempDir("gene-exec-queued-", "")
      let originalCwd = getCurrentDir()
      let hadOther = existsEnv("GENE_EXEC_OTHER")
      let originalOther = getEnv("GENE_EXEC_OTHER")
      let scope = execScope(directory)
      defer:
        execPauseMonitor(false)
        setCurrentDir(originalCwd)
        if hadOther: putEnv("GENE_EXEC_OTHER", originalOther)
        else: delEnv("GENE_EXEC_OTHER")
        if fileExists(directory / "result.json"): removeFile(directory / "result.json")
        removeDir(directory)
      putEnv("GENE_EXEC_OTHER", "before")
      execPauseMonitor(true)
      let queued = run(compileSource("""
        (let child_env {^GENE_EXEC_VALUE "submitted"})
        (let queued ($os/exec_async ^dir "." ^env child_env ^timeout_ms 500
          fixture "--exec-fixture" "write" output))
        (child_env .put "GENE_EXEC_VALUE" "changed")
        queued
      """), scope)
      scope.define("queued_task", queued)
      putEnv("GENE_EXEC_OTHER", "after")
      setCurrentDir(directory)
      sleep(600)
      execPauseMonitor(false)
      check run(compileSource("(/status (await queued_task))"), scope).print() == "0"
      check getCurrentDir() == expandFilename(directory)
      let observed = parseFile(directory / "result.json")
      check observed["directory"].getStr == originalCwd
      check observed["value"].getStr == "submitted"
      check observed["other"].getStr == "before"
      check execPendingCounts() == (0, 0)

  test "a blocked output destination does not suspend another child":
    let value = run(compileSource("""
      (let IoResource $io/IoResource)
      (let endpoints ($io/pipe))
      (let noisy ($os/exec_stream_async fixture "--exec-fixture" "bulk"
        ^stdout_pipe endpoints/1 ^timeout_ms 5000))
      (let started ($os/monotonic_ms))
      (let quick (await ($os/exec_async fixture "--exec-fixture" "print")))
      (let responsive (< (- ($os/monotonic_ms) started) 1000))
      endpoints/0/.IoResource:close
      (await endpoints/0/.IoResource:wait_closed)
      (let failed (try (await noisy) false catch Any true))
      (await endpoints/1/.IoResource:wait_closed)
      [quick/status responsive failed]
    """), execScope(getTempDir()))
    check value.print() == "[0 true true]"
    when defined(geneExecTests): check execPendingCounts() == (0, 0)

  test "output wakes a root channel receiver before the child exits":
    let directory = createTempDir("gene-exec-lines-", "")
    defer:
      if fileExists(directory / "result.json"): removeFile(directory / "result.json")
      removeDir(directory)
    let value = run(compileSource("""
      (let lines ($channel ^capacity 1))
      (let child ($os/exec_stream_async fixture "--exec-fixture" "wait" output
        ^stdout_chan lines ^timeout_ms 3000))
      (let first lines/.recv)
      ($fs/write_text output "release")
      (let result (await child))
      [first result/status result/timed_out
       (try lines/.recv false catch ChannelClosed true)]
    """), execScope(directory))
    check value.print() == "[\"ready\" 0 false true]"

  test "a distant timer does not delay exec completion":
    let started = getMonoTime()
    let value = run(compileSource("""
      (let timer (spawn ^lane root ($sleep 5000)))
      (let child ($os/exec_async fixture "--exec-fixture" "sleep" "40"))
      (let result (await child))
      timer/.cancel
      timer/.join
      result/status
    """), execScope(getTempDir()))
    check value.print() == "0"
    check (getMonoTime() - started).inMilliseconds < 1000

  test "immediate exits and submission failures return accounting to idle":
    let value = run(compileSource("""
      (repeat i in 80
        ($assert (== (/status (await ($os/exec_async fixture
          "--exec-fixture" "print"))) 0) "immediate child"))
      (try (await ($os/exec_async "gene-missing-exec-17ac")) false catch Any true)
    """), execScope(getTempDir()))
    check value.print() == "true"
    when defined(geneExecTests): check execPendingCounts() == (0, 0)

  test "queued terminal handoffs can cancel while captured work progresses":
    let value = run(compileSource("""
      (let first ($os/exec_stdio_async fixture "--exec-fixture" "sleep" "1000"))
      (let queued ($os/exec_stdio_async fixture "--exec-fixture" "sleep" "1000"))
      (let started ($os/monotonic_ms))
      queued/.cancel
      (let cancelled (match queued/.join ^!exhaustive
        (when TaskOutcome/cancelled true)))
      (let quick (await ($os/exec_async fixture "--exec-fixture" "print")))
      (let responsive (< (- ($os/monotonic_ms) started) 600))
      [cancelled responsive quick/status (await first)]
    """), execScope(getTempDir()))
    check value.print() == "[true true 0 0]"

  when defined(geneExecTests):
    test "exec-only waits do not wake on a periodic scheduler poll":
      let before = nativeWakeWaitCount()
      let value = run(compileSource("""
        (/status (await ($os/exec_async fixture "--exec-fixture" "sleep" "180")))
      """), execScope(getTempDir()))
      check value.print() == "0"
      check nativeWakeWaitCount() - before < 12
      check execPendingCounts() == (0, 0)

    test "a root channel receive does not repeatedly wake itself":
      let before = nativeWakeWaitCount()
      let value = run(compileSource("""
        (let channel ($channel ^capacity 1))
        (let child ($os/exec_stream_async fixture "--exec-fixture" "late-line"
          ^stdout_chan channel))
        (let line channel/.recv)
        [line (/status (await child))]
      """), execScope(getTempDir()))
      check value.print() == "[\"ready\" 0]"
      check nativeWakeWaitCount() - before < 12
      check execPendingCounts() == (0, 0)

    test "64 live children leave short exec and file work responsive":
      let directory = createTempDir("gene-exec-concurrency-", "")
      writeFile(directory / "small", "small file")
      defer:
        if fileExists(directory / "result.json"): removeFile(directory / "result.json")
        removeFile(directory / "small")
        removeDir(directory)
      let value = run(compileSource("""
        (let children [])
        (repeat i in 64
          (children .push ($os/exec_async fixture "--exec-fixture" "wait" output
            ^timeout_ms 10000)))
        (let started ($os/monotonic_ms))
        (let quick (await ($os/exec_async fixture "--exec-fixture" "print")))
        (let small (await (spawn ^lane root
          ($fs/read_text ($to_str directory "/small")))))
        (let elapsed (- ($os/monotonic_ms) started))
        ($fs/write_text output "release")
        (var successes 0)
        (for child in children
          (if (== (/status (await child)) 0) (set successes (+ successes 1))))
        [successes quick/status small (< elapsed 2000)]
      """), execScope(directory))
      check value.print() == "[64 0 \"small file\" true]"
      let stats = execMonitorStats()
      check stats.peak >= 64
      check stats.threads == 1
      check stats.active == 0
      check execPendingCounts() == (0, 0)
