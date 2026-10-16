import std/[monotimes, os, posix, strutils, times, unittest]
import gene/[process_launch, process_io]

if paramCount() >= 2 and paramStr(1) == "--io-fixture":
  case paramStr(2)
  of "done": stdout.write("final")
  of "both":
    let chunk = repeat('x', 8192)
    for i in 0..<128:
      stdout.write(chunk)
      stderr.write(chunk)
    stdout.write("final")
  of "input": stdout.write(stdin.readAll())
  of "ignore":
    var action: Sigaction
    action.sa_handler = SIG_IGN
    discard sigemptyset(action.sa_mask)
    discard sigaction(SIGTERM, action, nil)
    stdout.writeLine("ready")
    stdout.flushFile()
    sleep(10000)
  of "descendant", "buffered-descendant":
    let child = fork()
    if child < 0: quit(4)
    if child == 0:
      sleep(500)
      exitnow(0)
    stdout.write(if paramStr(2) == "descendant": "parent" else: repeat('x', 8192))
  of "stubborn-descendant":
    var ready: array[2, cint]
    if processPipe(addr ready) != 0: quit(3)
    let child = fork()
    if child < 0: quit(4)
    if child == 0:
      discard posix.close(ready[0])
      var action: Sigaction
      action.sa_handler = SIG_IGN
      discard sigemptyset(action.sa_mask)
      discard sigaction(SIGTERM, action, nil)
      var byte = 'r'
      discard posix.write(ready[1], addr byte, 1)
      discard posix.close(ready[1])
      sleep(2000) # Bounded even if the regression under test breaks cleanup.
      exitnow(0)
    discard posix.close(ready[1])
    var byte: char
    discard posix.read(ready[0], addr byte, 1)
    discard posix.close(ready[0])
    stdout.writeLine($child)
    stdout.flushFile()
    sleep(5000)
  else: quit(2)
  quit(0)

proc child(mode: string, group = true): ProcessHandle =
  launchProcess(getAppFilename(), ["--io-fixture", mode], ownGroup = group)

suite "POSIX process I/O":
  test "an exit observed before pumping keeps its status and final output":
    let process = child("done")
    defer: process.close()
    check process.waitExit(5000)
    let pump = newProcessPump(process, timeoutMs = 0)
    pump.runProcessPump()
    check pump.status == 0
    check not pump.timedOut
    check pump.output[0] == "final"

  test "simultaneous output and the final bytes are captured exactly":
    let process = child("both")
    defer: process.close()
    let pump = newProcessPump(process, 2 * 1024 * 1024, 5000)
    pump.runProcessPump()
    check pump.status == 0
    check pump.output[0] == repeat('x', 1048576) & "final"
    check pump.output[1] == repeat('x', 1048576)
    check not pump.truncated[0]
    check pump.failure == ""

  test "capture limits keep draining both streams":
    let process = child("both")
    defer: process.close()
    let pump = newProcessPump(process, 17, 5000)
    pump.runProcessPump()
    check pump.status == 0
    check pump.output == [repeat('x', 17), repeat('x', 17)]
    check pump.truncated == [true, true]

  test "stdin EOF is forwarded after the last bytes":
    var pipe: array[2, cint]
    check processPipe(addr pipe) == 0
    defer: discard posix.close(pipe[0])
    let input = "hello\x00binary\n"
    check posix.write(pipe[1], unsafeAddr input[0], input.len) == input.len
    discard posix.close(pipe[1])
    let process = child("input")
    defer: process.close()
    let pump = newProcessPump(process, timeoutMs = 5000, inputSource = pipe[0])
    pump.runProcessPump()
    check pump.status == 0
    check pump.output[0] == input

  test "a blocked output consumer cannot prevent timeout and escalation":
    var pipe: array[2, cint]
    check processPipe(addr pipe) == 0
    defer:
      discard posix.close(pipe[0])
      discard posix.close(pipe[1])
    let process = child("both")
    defer: process.close()
    let pump = newProcessPump(process, timeoutMs = 100, stdoutSink = pipe[1])
    let started = getMonoTime()
    pump.runProcessPump()
    check pump.timedOut
    check pump.status == -1
    check (getMonoTime() - started).inMilliseconds < 3000

  test "a closed consumer is an error and leaves no waitable child":
    var pipe: array[2, cint]
    check processPipe(addr pipe) == 0
    discard posix.close(pipe[0])
    defer: discard posix.close(pipe[1])
    let process = child("both")
    defer: process.close()
    let pump = newProcessPump(process, timeoutMs = 5000, stdoutSink = pipe[1])
    pump.runProcessPump()
    check pump.failure == "stdout pipe closed during write"
    var status: cint
    check waitpid(Pid(process.processID), status, WNOHANG) == -1
    check errno == ECHILD

  test "cancellation escalates when TERM is ignored":
    let process = child("ignore")
    defer: process.close()
    var ready = false
    let pump = newProcessPump(process, stdout = proc(chunk: string) = ready = true)
    var descriptors: seq[TPollfd]
    let started = getMonoTime()
    while not pump.done:
      pump.advance(ready)
      if ready and not pump.done: pump.advance(true)
      if pump.done: break
      descriptors.setLen(0)
      pump.addInterests(descriptors)
      waitProcessIo(descriptors, pump.waitTimeout())
    check ready
    check pump.cancelled
    check pump.status == -1
    check (getMonoTime() - started).inMilliseconds < 3000

  test "normal leader exit does not wait for descendant-held pipe EOF":
    let process = child("descendant")
    defer: process.close()
    let pump = newProcessPump(process, timeoutMs = 5000)
    let started = getMonoTime()
    pump.runProcessPump()
    check pump.status == 0
    check pump.output[0] == "parent"
    check (getMonoTime() - started).inMilliseconds < 400

  test "a final burst crossing the fairness budget does not wait for descendant EOF":
    let process = child("buffered-descendant")
    defer: process.close()
    check process.waitExit(5000)
    let pump = newProcessPump(process, timeoutMs = 5000)
    let started = getMonoTime()
    pump.runProcessPump()
    check pump.status == 0
    check pump.output[0] == repeat('x', 8192)
    check (getMonoTime() - started).inMilliseconds < 400

  test "group cleanup kills a TERM-ignoring descendant after the leader exits":
    let process = child("stubborn-descendant")
    defer: process.close()
    var output = ""
    let pump = newProcessPump(process, stdout = proc(chunk: string) = output.add chunk)
    var descriptors: seq[TPollfd]
    while not pump.done:
      pump.advance('\n' in output)
      if '\n' in output and not pump.done: pump.advance(true)
      if pump.done: break
      descriptors.setLen(0)
      pump.addInterests(descriptors)
      waitProcessIo(descriptors, pump.waitTimeout())
    check pump.cancelled
    let descendant = Pid(parseInt(output.strip()))
    require descendant > 0
    # A zombie can remain visible briefly under an external reaper; getpgid
    # fails on Darwin zombies. Linux additionally exposes state in /proc.
    var alive = true
    for attempt in 0..<30:
      when defined(linux):
        let path = "/proc/" & $descendant & "/stat"
        try: alive = ") Z " notin readFile(path)
        except IOError, OSError: alive = false
      else:
        alive = getpgid(descendant) >= 0
      if not alive: break
      sleep(10)
    check not alive
    when defined(geneExecTests): check testUnsafeReaps() == 0
