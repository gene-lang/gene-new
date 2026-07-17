## Safe Unix PTY process launch and process-group lifecycle.
##
## The long-running process never forks. It openpty()s and posix_spawn()s a
## fresh copy of the current executable in a private helper mode; that fresh,
## single-threaded process performs setsid/TIOCSCTTY/execvp.

import std/[monotimes, os, tables, times]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  const moduleDir = currentSourcePath.parentDir
  {.passC: "-I" & moduleDir.}
  when defined(linux):
    {.passL: "-lutil".}
  {.compile: moduleDir / "pty_bridge.c".}

  type CPtySpawnResult {.importc: "GenePtySpawnResult",
                         header: "pty_bridge.h", bycopy.} = object
    masterFd {.importc: "master_fd".}: cint
    pid: cint

  proc cSpawn(helperPath, cwd: cstring, childArgv, childEnv: ptr cstring,
              rows, cols: cint, result: ptr CPtySpawnResult,
              error: cstring, errorSize: csize_t): cint
    {.importc: "gene_pty_spawn", header: "pty_bridge.h".}
  proc cHelperExec(cwd: cstring, childArgv: ptr cstring)
    {.importc: "gene_pty_helper_exec", header: "pty_bridge.h", noreturn.}
  proc cRead(masterFd: cint, buffer: pointer, size: csize_t,
             eof: ptr cint): clong
    {.importc: "gene_pty_read", header: "pty_bridge.h".}
  proc cWrite(masterFd: cint, buffer: pointer, size: csize_t): clong
    {.importc: "gene_pty_write", header: "pty_bridge.h".}
  proc cResize(masterFd: cint, rows, cols: cint): cint
    {.importc: "gene_pty_resize", header: "pty_bridge.h".}
  proc cSignal(masterFd, pid, signalNumber: cint): cint
    {.importc: "gene_pty_signal", header: "pty_bridge.h".}
  proc cSignalSession(masterFd, pid, signalNumber: cint): cint
    {.importc: "gene_pty_signal_session", header: "pty_bridge.h".}
  proc cProcessIdentity(masterFd, pid: cint, sessionId, processGroupId,
                        foregroundProcessGroupId: ptr cint): cint
    {.importc: "gene_pty_process_identity", header: "pty_bridge.h".}
  proc cSignalNumber(signalKind: cint): cint
    {.importc: "gene_pty_signal_number", header: "pty_bridge.h".}
  proc cPollExit(pid: cint, status, exited: ptr cint): cint
    {.importc: "gene_pty_poll_exit", header: "pty_bridge.h".}
  proc cWaitExit(pid: cint, status: ptr cint): cint
    {.importc: "gene_pty_wait_exit", header: "pty_bridge.h".}
  proc cCloseFd(fd: cint)
    {.importc: "gene_pty_close_fd", header: "pty_bridge.h".}

type
  PtySignal* = enum
    ptySignalHup = 1,
    ptySignalInt,
    ptySignalTerm,
    ptySignalWinch,
    ptySignalKill

  PtyRead* = object
    data*: string
    eof*: bool

  PtyProcessIdentity* = object
    sessionId*: int
    processGroupId*: int
    foregroundProcessGroupId*: int

  PtyProcessObj = object
    masterFd: int
    pid*: int
    exited*: bool
    exitStatus*: int
    closed: bool
  PtyProcess* = ref PtyProcessObj

const agentEnvironmentKeys = [
  "OPENAI_AUTH_TOKEN", "CODEX_ACCESS_TOKEN", "OPENAI_API_KEY",
  "GENE_GATEWAY_TOKEN", "GENE_AGENT_STATE", "GENE_AGENT_HOME"
]

proc ptySignalNumber*(signal: PtySignal): int =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    int(cSignalNumber(cint(ord(signal))))
  else:
    0

proc sanitizedTerminalEnvironment*(): seq[string] =
  var values = initOrderedTable[string, string]()
  for key, value in envPairs():
    if key notin agentEnvironmentKeys:
      values[key] = value
  values["TERM"] = "xterm-256color"
  values["TERM_PROGRAM"] = "Gene"
  if getEnv("COLORTERM").len > 0:
    values["COLORTERM"] = getEnv("COLORTERM")
  for key, value in values:
    result.add key & "=" & value

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc cstrings(values: seq[string]): tuple[storage: seq[string],
                                             pointers: seq[cstring]] =
    result.storage = values
    result.pointers = newSeq[cstring](values.len + 1)
    for i in 0 ..< values.len:
      result.pointers[i] = result.storage[i].cstring

  proc runInternalPtyHelper() =
    if paramCount() < 3:
      quit(127)
    let cwd = paramStr(2)
    var child: seq[string]
    for i in 3 .. paramCount():
      child.add paramStr(i)
    let argv = cstrings(child)
    cHelperExec(cwd.cstring, unsafeAddr argv.pointers[0])

  # Every executable importing this module is version-matched helper-capable.
  # posix_spawn starts a fresh image, so this runs single-threaded before its
  # normal command/test entry point.
  if paramCount() >= 1 and paramStr(1) == "--gene-internal-pty-helper":
    runInternalPtyHelper()

proc `=destroy`(process: var PtyProcessObj) =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if not process.closed:
      if not process.exited and process.pid > 0:
        discard cSignalSession(cint(process.masterFd), cint(process.pid),
                        cSignalNumber(cint(ord(ptySignalHup))))
      if process.masterFd >= 0:
        cCloseFd(cint(process.masterFd))
        process.masterFd = -1
      process.closed = true

proc spawnPty*(argv: seq[string], cwd = "", rows = 24, cols = 80,
               environment: seq[string] = @[]): PtyProcess =
  if argv.len == 0 or argv[0].len == 0:
    raise newException(ValueError, "PTY command must not be empty")
  if rows <= 0 or cols <= 0:
    raise newException(ValueError, "PTY dimensions must be positive")
  let launchCwd = if cwd.len == 0: getCurrentDir() else: cwd
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let args = cstrings(argv)
    let env = cstrings(if environment.len == 0:
                         sanitizedTerminalEnvironment()
                       else:
                         environment)
    var native: CPtySpawnResult
    var error: array[512, char]
    let code = cSpawn(getAppFilename().cstring, launchCwd.cstring,
                      unsafeAddr args.pointers[0],
                      unsafeAddr env.pointers[0], cint(rows), cint(cols),
                      addr native, cast[cstring](addr error[0]),
                      csize_t(error.len))
    if code != 0:
      raise newException(IOError, $cast[cstring](addr error[0]))
    new(result)
    result.masterFd = int(native.masterFd)
    result.pid = int(native.pid)
    result.exitStatus = -1
  else:
    raise newException(IOError, "PTY processes are unavailable")

proc requireOpen(process: PtyProcess) =
  if process == nil or process.closed:
    raise newException(IOError, "PTY process is closed")

proc requireMaster(process: PtyProcess) =
  process.requireOpen()
  if process.masterFd < 0:
    raise newException(IOError, "PTY master is disconnected")

proc disconnect*(process: PtyProcess) =
  ## Hang up the controlling terminal without discarding the child identity;
  ## waitpid still owns the session leader after the master is gone.
  process.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if process.masterFd >= 0:
      cCloseFd(cint(process.masterFd))
      process.masterFd = -1

proc readAvailable*(process: PtyProcess, maxBytes = 65536): PtyRead =
  process.requireOpen()
  if maxBytes <= 0:
    raise newException(ValueError, "PTY read limit must be positive")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if process.masterFd < 0:
      result.eof = true
      return
    var chunk = newString(min(maxBytes, 4096))
    while result.data.len < maxBytes:
      let wanted = min(chunk.len, maxBytes - result.data.len)
      var eof: cint
      let count = int(cRead(cint(process.masterFd), addr chunk[0],
                            csize_t(wanted), addr eof))
      if count < 0:
        raise newException(IOError, "reading PTY failed with errno " & $(-count))
      if count == 0:
        result.eof = eof != 0
        break
      result.data.add chunk[0 ..< count]

proc writeAvailable*(process: PtyProcess, data: string): int =
  process.requireMaster()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if data.len == 0:
      return 0
    let count = int(cWrite(cint(process.masterFd), unsafeAddr data[0],
                           csize_t(data.len)))
    if count < 0:
      raise newException(IOError, "writing PTY failed with errno " & $(-count))
    count

proc resize*(process: PtyProcess, rows, cols: int) =
  process.requireMaster()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let code = cResize(cint(process.masterFd), cint(rows), cint(cols))
    if code != 0:
      raise newException(IOError, "resizing PTY failed with errno " & $code)

proc signal*(process: PtyProcess, signalNumber: int) =
  process.requireMaster()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let code = cSignal(cint(process.masterFd), cint(process.pid),
                       cint(signalNumber))
    if code != 0 and code != 3: # ESRCH means it exited between poll and signal.
      raise newException(IOError, "signalling PTY failed with errno " & $code)

proc signalSession*(process: PtyProcess, signalNumber: int) =
  ## Reach both the current foreground job and the terminal's session-leader
  ## group. Interactive shells put jobs such as vim in a distinct foreground
  ## process group, so signalling the original shell group alone can leak the
  ## program that the user is actually looking at.
  process.requireOpen()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let code = cSignalSession(cint(process.masterFd), cint(process.pid),
                              cint(signalNumber))
    if code != 0 and code != 3:
      raise newException(IOError,
        "signalling PTY session failed with errno " & $code)

proc identity*(process: PtyProcess): PtyProcessIdentity =
  process.requireMaster()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var sessionId, processGroupId, foregroundProcessGroupId: cint
    let code = cProcessIdentity(cint(process.masterFd), cint(process.pid),
                                addr sessionId, addr processGroupId,
                                addr foregroundProcessGroupId)
    if code != 0:
      raise newException(IOError,
        "inspecting PTY process identity failed with errno " & $code)
    result = PtyProcessIdentity(
      sessionId: int(sessionId), processGroupId: int(processGroupId),
      foregroundProcessGroupId: int(foregroundProcessGroupId))

proc pollExit*(process: PtyProcess): bool =
  process.requireOpen()
  if process.exited:
    return true
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var status, exited: cint
    let code = cPollExit(cint(process.pid), addr status, addr exited)
    if code != 0:
      raise newException(IOError, "polling PTY exit failed with errno " & $code)
    if exited != 0:
      process.exited = true
      process.exitStatus = int(status)
    process.exited

proc waitForExit*(process: PtyProcess): int =
  process.requireOpen()
  if process.exited:
    return process.exitStatus
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var status: cint
    let code = cWaitExit(cint(process.pid), addr status)
    if code != 0:
      raise newException(IOError, "waiting for PTY exit failed with errno " & $code)
    process.exited = true
    process.exitStatus = int(status)
    process.exitStatus

proc stop*(process: PtyProcess, graceMs = 200) =
  process.requireOpen()
  if process.pollExit():
    return
  process.signalSession(ptySignalNumber(ptySignalHup))
  let hupDeadline = getMonoTime() + initDuration(milliseconds = graceMs)
  while getMonoTime() < hupDeadline and not process.pollExit():
    sleep(5)
  if process.exited:
    return
  process.signalSession(ptySignalNumber(ptySignalTerm))
  let termDeadline = getMonoTime() + initDuration(milliseconds = graceMs)
  while getMonoTime() < termDeadline and not process.pollExit():
    sleep(5)
  if not process.exited:
    process.signalSession(ptySignalNumber(ptySignalKill))
    # On macOS an exiting controlling-session leader can remain in kernel
    # teardown while the PTY master is open. Disconnect before the blocking
    # reap; the VT layer has already drained every currently available byte.
    process.disconnect()
    discard process.waitForExit()

proc close*(process: PtyProcess) =
  if process == nil or process.closed:
    return
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if not process.exited:
      process.stop()
    if process.masterFd >= 0:
      cCloseFd(cint(process.masterFd))
      process.masterFd = -1
  process.closed = true
