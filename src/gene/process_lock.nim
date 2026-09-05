## Crash-recoverable cross-process lock files for package/build publication.

import std/[os, strutils, times]

when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean

type ProcessFileLock* = object
  path*: string

proc processAlive*(processId: int): bool =
  if processId <= 0:
    return false
  when defined(posix):
    if posix.kill(Pid(processId), 0) == 0:
      return true
    osLastError() == OSErrorCode(EPERM)
  elif defined(windows):
    let handle = openProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0,
                             DWORD(processId))
    if handle == 0:
      return false
    var status: int32
    result = getExitCodeProcess(handle, status) != 0 and
             status == STILL_ACTIVE
    discard closeHandle(handle)
  else:
    # Unknown platforms fail closed: an old but well-formed lock is safer than
    # breaking a live publisher's mutual exclusion.
    true

proc removeStaleLock(path: string) =
  if not fileExists(path):
    return
  var owner = 0
  try:
    owner = parseInt(readFile(path).strip())
  except ValueError, IOError:
    # A malformed lock cannot be live under this implementation. Give a
    # concurrent publisher ample time to finish its atomic hard-link step.
    # The live owner may have released the lock between fileExists/readFile
    # and this metadata query. A vanished lock is a retry, not a build error.
    var modified: times.Time
    try:
      modified = getLastModificationTime(path)
    except OSError:
      return
    if (getTime() - modified).inSeconds <= 300:
      return
  if owner > 0 and processAlive(owner):
    return
  try:
    removeFile(path)
  except OSError:
    discard

proc acquireProcessFileLock*(path: string, timeoutMs = 30_000):
                             ProcessFileLock =
  createDir(parentDir(path))
  let token = path & ".candidate-" & $getCurrentProcessId()
  if fileExists(token):
    removeFile(token)
  writeFile(token, $getCurrentProcessId() & "\n")
  defer:
    if fileExists(token):
      removeFile(token)
  let attempts = max(1, timeoutMs div 5)
  for attempt in 0 ..< attempts:
    try:
      createHardlink(token, path)
      return ProcessFileLock(path: path)
    except OSError:
      removeStaleLock(path)
      if attempt < attempts - 1:
        sleep(5)
  raise newException(IOError, "timed out waiting for process lock: " & path)

proc release*(lock: ProcessFileLock) =
  if lock.path.len > 0 and fileExists(lock.path):
    removeFile(lock.path)
