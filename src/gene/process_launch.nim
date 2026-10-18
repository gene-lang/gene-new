## Private POSIX process layer shared by the VM and build tools.
## Handles have one owning thread. Observation never reaps; signalling
## authority is retired before the owner consumes the child's status.
import std/[monotimes, options, os, posix, streams, strutils, times]

when not defined(posix) or defined(emscripten) or defined(geneWasm):
  {.error: "process_launch requires a native POSIX host".}

const processHeader = currentSourcePath().parentDir / "process_launch.h"
{.compile: "process_launch.c".}
when defined(geneExecTests):
  {.passC: "-DGENE_EXEC_TESTS".}
when defined(geneExecForceFork):
  when not defined(geneExecTests):
    {.error: "geneExecForceFork is only available in geneExecTests builds".}
  {.passC: "-DGENE_EXEC_FORCE_FORK".}

proc nativeSpawn(path: cstring, args, environment: cstringArray,
                 directory: cstring, inheritStdio, mergeStderr, ownGroup: cint,
                 pid: ptr cint, fds: ptr array[3, cint]): cint
  {.importc: "gene_process_spawn", header: processHeader.}
proc nativeSpawnDetached(path: cstring, args, environment: cstringArray,
                         directory, output: cstring, pid: ptr cint): cint
  {.importc: "gene_process_spawn_detached", header: processHeader.}
proc nativeObserve(pid: cint, status: ptr cint): cint
  {.importc: "gene_process_observe", header: processHeader.}
proc nativeReap(pid: cint, status: ptr cint): cint
  {.importc: "gene_process_reap", header: processHeader.}
proc nativeExitFd(pid, forcePoll: cint): cint
  {.importc: "gene_process_exit_fd", header: processHeader.}
proc nativeRegisterGroup(pid: cint): cint
  {.importc: "gene_process_group_register", header: processHeader.}
proc nativeRetireGroup(slot: cint)
  {.importc: "gene_process_group_retire", header: processHeader.}
proc nativeSignal(pid, group, signal: cint): cint
  {.importc: "gene_process_signal", header: processHeader.}
proc nativeSpawnBegin(): cint
  {.importc: "gene_process_spawn_begin", header: processHeader.}
proc nativeSpawnEnd()
  {.importc: "gene_process_spawn_end", header: processHeader.}
proc nativeDefaultPath(): cstring
  {.importc: "gene_process_default_path", header: processHeader.}
proc processWrite*(fd: cint, data: pointer, size: csize_t): cint
  {.importc: "gene_process_write", header: processHeader.}
proc processPipe*(fds: ptr array[2, cint]): cint
  {.importc: "gene_process_cloexec_pipe", header: processHeader.}
proc initProcessShutdown()
  {.importc: "gene_process_init", header: processHeader.}

# Register before any async submission can race with process exit. Signal
# dispositions remain unchanged until the first captured group is launched.
initProcessShutdown()

when defined(geneExecTests):
  proc testRegisterGroup*(pid: cint): cint
    {.importc: "gene_process_group_register", header: processHeader.}
  proc testRetireGroup*(slot: cint)
    {.importc: "gene_process_group_retire", header: processHeader, gcsafe.}
  proc testPinGroup*(slot: cint): cint
    {.importc: "gene_process_test_pin", header: processHeader.}
  proc testUnpinGroup*(slot: cint)
    {.importc: "gene_process_test_unpin", header: processHeader.}
  proc testGroupPid*(slot: cint): cint
    {.importc: "gene_process_test_group_pid", header: processHeader.}
  proc testSignalCalls*(): cint
    {.importc: "gene_process_test_signals", header: processHeader.}
  proc testUnsafeReaps*(): cint
    {.importc: "gene_process_test_unsafe_reaps", header: processHeader.}
  proc testHoldSpawn*(hold: cint)
    {.importc: "gene_process_test_hold_spawn", header: processHeader, gcsafe.}
  proc testSpawnWaiting*(): cint
    {.importc: "gene_process_test_spawn_waiting", header: processHeader.}

type
  ProcessHandleObj = object
    pid: cint
    fds: array[3, cint]
    exitFd: cint
    groupSlot: cint
    ownGroup: bool
    observed, reaped, closed: bool
    status: cint
    outStream: Stream
  ProcessHandle* = ref ProcessHandleObj

proc closeData(p: var ProcessHandleObj)
proc `=destroy`(p: var ProcessHandleObj) =
  try: closeData(p)
  except Exception: discard
  `=destroy`(p.outStream)

when defined(geneExecTests) and defined(linux):
  let forcedExitPolling = block:
    let selected = getEnv("GENE_TEST_EXEC_EXIT_BACKEND", "auto")
    if selected notin ["auto", "poll"]:
      raise newException(ValueError, "GENE_TEST_EXEC_EXIT_BACKEND expects auto or poll")
    selected == "poll"
else:
  const forcedExitPolling = false

proc processID*(p: ProcessHandle): int = int(p.pid)
proc inputHandle*(p: ProcessHandle): cint = p.fds[0]
proc outputHandle*(p: ProcessHandle): cint = p.fds[1]
proc errorHandle*(p: ProcessHandle): cint = p.fds[2]
proc exitHandle*(p: ProcessHandle): cint = p.exitFd
proc hasExitNotification*(p: ProcessHandle): bool = p.exitFd >= 0
proc hasProcessGroup*(p: ProcessHandle): bool = p.ownGroup

proc observeExit*(p: ProcessHandle): bool =
  if p.observed: return true
  let resultCode = nativeObserve(p.pid, addr p.status)
  if resultCode < 0: raiseOSError(OSErrorCode(-resultCode))
  p.observed = resultCode > 0
  p.observed

proc running*(p: ProcessHandle): bool =
  p != nil and not p.closed and not p.observeExit()

proc exitStatus*(p: ProcessHandle): int =
  if p.observed: int(p.status) else: -1

proc signal*(p: ProcessHandle, signal: cint, group = false) =
  if p == nil or p.closed or p.reaped: return
  let code = nativeSignal(p.pid, cint(group and p.ownGroup), signal)
  when defined(macosx):
    # Darwin can return EPERM for a zombie-only process group (getpgid also
    # fails), although the leader is still waitable. Preserve the identity
    # until reap, but do not turn successful TERM cleanup into a launch error.
    if group and code == EPERM and p.observeExit(): return
  if code != 0 and code != ESRCH: raiseOSError(OSErrorCode(code))

proc terminate*(p: ProcessHandle) = p.signal(SIGTERM)
proc kill*(p: ProcessHandle) = p.signal(SIGKILL)
proc terminateGroup*(p: ProcessHandle) = p.signal(SIGTERM, true)
proc killGroup*(p: ProcessHandle) = p.signal(SIGKILL, true)

proc waitExit*(p: ProcessHandle, timeout = -1): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = max(0, timeout))
  while not p.observeExit():
    var delay = if timeout < 0: -1 else:
      int(max(0'i64, ((deadline - getMonoTime()).inNanoseconds + 999_999) div 1_000_000))
    if timeout >= 0 and delay == 0: return false
    if p.exitFd < 0: delay = if delay < 0: 5 else: min(delay, 5)
    var descriptor = TPollfd(fd: p.exitFd, events: POLLIN)
    let ready = posix.poll(addr descriptor, Tnfds(1), cint(delay))
    if ready < 0 and errno != EINTR: raiseOSError(osLastError())
  true

proc reap*(p: ProcessHandle): int =
  if p.reaped: return int(p.status)
  if not p.observeExit():
    raise newException(IOError, "cannot reap a running process")
  nativeRetireGroup(p.groupSlot)
  p.groupSlot = -1
  # A failed reap (for example an unexpected competing reaper) must not
  # leave this handle authorized to signal a possibly recycled numeric PID.
  p.reaped = true
  let code = nativeReap(p.pid, addr p.status)
  if p.exitFd >= 0:
    discard posix.close(p.exitFd)
    p.exitFd = -1
  if code != 0: raiseOSError(OSErrorCode(code))
  int(p.status)

proc waitForExit*(p: ProcessHandle, timeout = -1): int =
  if not p.waitExit(timeout): return -1
  p.reap()

proc closeInput*(p: ProcessHandle) =
  if p.fds[0] >= 0:
    discard posix.close(p.fds[0])
    p.fds[0] = -1

proc nonblocking*(fd: cint) =
  if fd >= 0 and fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) or O_NONBLOCK) < 0:
    raiseOSError(osLastError())

proc closeData(p: var ProcessHandleObj) =
  if p.closed or p.pid <= 0: return
  p.closed = true
  if p.pid > 0 and not p.reaped:
    # Error/abandonment backstop; ordinary cancellation performs TERM and its
    # grace period before closing, outside this destructor.
    var status: cint
    let observed = nativeObserve(p.pid, addr status)
    if observed == 0:
      discard nativeSignal(p.pid, cint(p.ownGroup), SIGKILL)
      discard nativeSignal(p.pid, 0, SIGKILL)
    nativeRetireGroup(p.groupSlot)
    p.groupSlot = -1
    if observed >= 0:
      if nativeReap(p.pid, addr status) == 0: p.status = status
    # Closed handles never consult a numeric PID again, including an abandoned
    # handle whose destructor had to kill/reap it.
    p.observed = true
    p.reaped = true
  if p.outStream != nil: p.outStream.close()
  if p.exitFd >= 0: discard posix.close(p.exitFd)
  p.exitFd = -1
  for fd in p.fds.mitems:
    if fd >= 0: discard posix.close(fd)
    fd = -1

proc close*(p: ProcessHandle) =
  if p != nil: closeData(p[])

proc outputStream*(p: ProcessHandle): Stream =
  if p.outStream == nil:
    let fd = posix.dup(p.outputHandle)
    if fd < 0: raiseOSError(osLastError())
    var file: File
    if not open(file, FileHandle(fd), fmRead):
      discard posix.close(fd)
      raise newException(IOError, "could not open process output stream")
    p.outStream = newFileStream(file)
  p.outStream

proc defaultProcessPath*(): string = $nativeDefaultPath()

proc resolveProcessDirectory*(directory: string): string =
  if directory.len == 0 or directory.isAbsolute: directory
  else: getCurrentDir() & "/" & directory

proc processCandidates(program: string, arguments: openArray[string],
                       directory: string, environment: Option[seq[string]]):
                       tuple[workdir: string, candidates: seq[string]] =
  if program.len == 0 or '\0' in program or '\0' in directory:
    raise newException(ValueError, "invalid process program or directory")
  for argument in arguments:
    if '\0' in argument: raise newException(ValueError, "NUL in process argument")
  # Keep dot components for the kernel: collapsing link/.. changes symlink
  # traversal and can turn an invalid missing/.. directory into a valid one.
  result.workdir = resolveProcessDirectory(directory)
  var searchPath = getEnv("PATH", defaultProcessPath())
  if environment.isSome:
    searchPath = defaultProcessPath()
    for entry in environment.get:
      if '\0' in entry: raise newException(ValueError, "NUL in process environment")
      if entry.startsWith("PATH="): searchPath = entry[5 .. ^1]
  var baseDirectory = result.workdir
  template inChildDirectory(path: string): string =
    block:
      if path.isAbsolute: path
      else:
        if baseDirectory.len == 0: baseDirectory = getCurrentDir()
        baseDirectory & "/" & path
  if program.contains(DirSep):
    result.candidates.add inChildDirectory(program)
  else:
    for entry in searchPath.split(PathSep):
      result.candidates.add inChildDirectory(if entry.len == 0: program else: entry & "/" & program)

proc launchDetached*(program: string, arguments: openArray[string] = [],
                     directory = "", environment = none(seq[string]),
                     output: string): int =
  if output.len == 0 or '\0' in output:
    raise newException(ValueError, "detached output must be a non-empty path")
  let (workdir, candidates) = processCandidates(program, arguments, directory, environment)
  let argv = allocCStringArray(@[program] & @arguments)
  defer: deallocCStringArray(argv)
  var envp: cstringArray
  if environment.isSome: envp = allocCStringArray(environment.get)
  defer:
    if envp != nil: deallocCStringArray(envp)
  var pid: cint
  var denied = false
  var code = cint(ENOENT)
  for candidate in candidates:
    code = nativeSpawnDetached(candidate.cstring, argv, envp, workdir.cstring,
                                output.cstring, addr pid)
    if code == 0: return int(pid)
    if code == EACCES: denied = true
    elif code notin [ENOENT, ENOTDIR]: break
  if denied and code in [ENOENT, ENOTDIR, EACCES]: code = EACCES
  raiseOSError(OSErrorCode(code), program)

proc launchProcess*(program: string, arguments: openArray[string] = [],
                    directory = "", environment = none(seq[string]),
                    inheritStdio = false, mergeStderr = false,
                    ownGroup = false): ProcessHandle =
  let (workdir, candidates) = processCandidates(program, arguments, directory, environment)
  let argv = allocCStringArray(@[program] & @arguments)
  defer: deallocCStringArray(argv)
  var envp: cstringArray
  if environment.isSome: envp = allocCStringArray(environment.get)
  defer:
    if envp != nil: deallocCStringArray(envp)
  if ownGroup:
    let code = nativeSpawnBegin()
    if code != 0:
      nativeSpawnEnd()
      raiseOSError(OSErrorCode(code), "process launch during shutdown")
  defer:
    if ownGroup: nativeSpawnEnd()
  var pid: cint
  var fds: array[3, cint]
  var denied = false
  var lastCode = cint(ENOENT)
  for candidate in candidates:
    lastCode = nativeSpawn(candidate.cstring, argv, envp, workdir.cstring,
                           cint(inheritStdio), cint(mergeStderr), cint(ownGroup),
                           addr pid, addr fds)
    if lastCode == 0: break
    if lastCode == EACCES: denied = true
    elif lastCode notin [ENOENT, ENOTDIR]: break
  if lastCode != 0:
    if denied and lastCode in [ENOENT, ENOTDIR, EACCES]: lastCode = EACCES
    raiseOSError(OSErrorCode(lastCode), program)
  result = ProcessHandle(pid: pid, fds: fds, exitFd: -1, groupSlot: -1,
                         ownGroup: ownGroup, status: -1)
  if ownGroup:
    result.groupSlot = nativeRegisterGroup(pid)
    if result.groupSlot < 0:
      result.killGroup()
      if result.running: result.kill()
      discard result.waitForExit()
      result.close()
      raiseOSError(OSErrorCode(EAGAIN), "too many captured subprocesses")
  result.exitFd = nativeExitFd(pid, cint(forcedExitPolling))
