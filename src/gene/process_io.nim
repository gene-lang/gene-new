## Nonblocking I/O and cleanup for an owned POSIX child. All managed data stays
## on one owner thread. Both the synchronous caller and the native monitor use
## this pump; it has no VM, Task, or scheduler dependency.
import std/[monotimes, os, posix, times]
import ./process_launch

type
  ProcessChunk* = proc(chunk: string) {.closure.}
  ProcessPump* = ref object
    process*: ProcessHandle
    deadline: MonoTime
    hasDeadline: bool
    stopDeadline: MonoTime
    stopping, killed, exited: bool
    outputDone: array[2, bool]
    sinks: array[2, cint]
    pending: array[2, string]
    offsets: array[2, int]
    source: cint
    input: string
    inputOffset: int
    inputDone: bool
    maxBytes: int
    callbacks: array[2, ProcessChunk]
    output*: array[2, string]
    truncated*: array[2, bool]
    timedOut*, cancelled*, done*: bool
    failure*: string
    status*: int

when defined(geneExecTinyBudget) and not defined(geneExecTests):
  {.error: "geneExecTinyBudget is only available in geneExecTests builds".}
const processIoBudget = when defined(geneExecTinyBudget): 1024 else: 256 * 1024
const processIoChunk = 64 * 1024

proc newProcessPump*(process: ProcessHandle, maxBytes = 1048576,
                     timeoutMs = -1, started = getMonoTime(),
                     inputSource: cint = -1, stdoutSink: cint = -1,
                     stderrSink: cint = -1, stdout: ProcessChunk = nil,
                     stderr: ProcessChunk = nil): ProcessPump =
  result = ProcessPump(process: process, maxBytes: maxBytes,
    hasDeadline: timeoutMs >= 0,
    deadline: started + initDuration(milliseconds = max(0, timeoutMs)),
    source: inputSource, sinks: [stdoutSink, stderrSink],
    callbacks: [stdout, stderr], status: -1)
  for fd in [process.outputHandle, process.errorHandle, process.inputHandle,
             inputSource, stdoutSink, stderrSink]:
    nonblocking(fd)
  result.inputDone = inputSource < 0
  if result.inputDone: process.closeInput()
  result.outputDone = [process.outputHandle < 0, process.errorHandle < 0]

proc fail(p: ProcessPump, message: string) =
  if p.failure.len == 0: p.failure = message

proc finishInput(p: ProcessPump) =
  p.inputDone = true
  p.input.setLen(0)
  p.inputOffset = 0
  p.process.closeInput()

proc beginStop(p: ProcessPump) =
  if p.stopping: return
  p.stopping = true
  p.stopDeadline = getMonoTime() + initDuration(milliseconds = 1000)
  if p.process.hasProcessGroup: p.process.terminateGroup()
  else: p.process.terminate()
  p.finishInput()
  # Neither a closed consumer nor one that stopped reading may prevent cleanup.
  for i in 0..1:
    p.pending[i].setLen(0)
    p.offsets[i] = 0

proc escalate(p: ProcessPump) =
  if p.stopping and not p.killed and
      (p.exited or getMonoTime() >= p.stopDeadline):
    # Keep the leader unreaped until the final signal and registry retirement.
    if p.process.hasProcessGroup: p.process.killGroup()
    if not p.exited: p.process.kill()
    p.killed = true

proc appendOutput(p: ProcessPump, index: int, chunk: string) =
  if p.sinks[index] < 0:
    let available = max(0, p.maxBytes - p.output[index].len)
    if chunk.len > available: p.truncated[index] = true
    if available >= chunk.len: p.output[index].add chunk
    elif available > 0: p.output[index].add chunk[0 ..< available]
  elif not p.stopping:
    p.pending[index] = chunk
    p.offsets[index] = 0
  if p.callbacks[index] != nil: p.callbacks[index](chunk)

proc flushOutput(p: ProcessPump, index: int): bool =
  while p.offsets[index] < p.pending[index].len:
    let n = processWrite(p.sinks[index],
      unsafeAddr p.pending[index][p.offsets[index]],
      csize_t(p.pending[index].len - p.offsets[index]))
    if n > 0: p.offsets[index] += n
    elif n < 0 and errno == EINTR: continue
    elif n < 0 and errno in [EAGAIN, EWOULDBLOCK]: return false
    else:
      p.fail((if index == 0: "stdout" else: "stderr") & " pipe closed during write")
      p.beginStop()
      return false
  p.pending[index].setLen(0)
  p.offsets[index] = 0
  true

proc drainOutput(p: ProcessPump, index: int) =
  if not p.flushOutput(index) or p.outputDone[index]: return
  let fd = if index == 0: p.process.outputHandle else: p.process.errorHandle
  var buffer: array[processIoChunk, char]
  var budget = processIoBudget
  while budget > 0:
    let n = posix.read(fd, addr buffer[0], min(buffer.len, budget))
    if n > 0:
      budget -= n
      var chunk = newString(n)
      copyMem(addr chunk[0], addr buffer[0], n)
      p.appendOutput(index, chunk)
      if not p.flushOutput(index): return
    elif n < 0 and errno == EINTR: continue
    elif n == 0 or (n < 0 and errno in [EAGAIN, EWOULDBLOCK]):
      # On leader exit drain available bytes, without waiting for descendants
      # that inherited a descriptor. Preserve the previous final-sweep boundary.
      if n == 0 or p.exited: p.outputDone[index] = true
      return
    else:
      p.fail((if index == 0: "stdout" else: "stderr") & " pipe read failed")
      p.outputDone[index] = true
      p.beginStop()
      return

proc pumpInput(p: ProcessPump) =
  if p.inputDone: return
  var budget = processIoBudget
  while budget > 0:
    if p.inputOffset >= p.input.len:
      p.input.setLen(processIoChunk)
      let n = posix.read(p.source, addr p.input[0], p.input.len)
      if n > 0:
        p.input.setLen(n)
        p.inputOffset = 0
      elif n < 0 and errno == EINTR: continue
      elif n < 0 and errno in [EAGAIN, EWOULDBLOCK]:
        p.input.setLen(0)
        p.inputOffset = 0
        return
      else:
        if n < 0: p.fail("stdin pipe transfer failed")
        p.finishInput()
        return
    let n = processWrite(p.process.inputHandle,
      unsafeAddr p.input[p.inputOffset], csize_t(p.input.len - p.inputOffset))
    if n > 0:
      p.inputOffset += n
      budget -= n
    elif n < 0 and errno == EINTR: continue
    elif n < 0 and errno in [EAGAIN, EWOULDBLOCK]: return
    else:
      # A child may deliberately finish before consuming all input.
      if n < 0 and errno != EPIPE: p.fail("stdin pipe transfer failed")
      p.finishInput()
      return

proc advance*(p: ProcessPump, cancel = false) =
  if p.done: return
  p.exited = p.process.observeExit()
  if cancel:
    p.cancelled = true
    p.beginStop()
  elif not p.exited and p.hasDeadline and getMonoTime() >= p.deadline and not p.stopping:
    p.timedOut = true
    p.beginStop()
  if p.failure.len > 0: p.beginStop()
  p.escalate()
  if p.exited: p.finishInput()
  else: p.pumpInput()
  p.drainOutput(0)
  p.drainOutput(1)
  # Preserve exit-before-deadline-check precedence for an already completed
  # child. A destination that is still blocked, however, must obey its timeout.
  if not p.stopping and p.exited and p.hasDeadline and
      getMonoTime() >= p.deadline and (p.pending[0].len > 0 or p.pending[1].len > 0):
    p.timedOut = true
    p.beginStop()
    p.escalate()
    p.drainOutput(0)
    p.drainOutput(1)
  if p.exited and p.outputDone[0] and p.outputDone[1] and
      p.pending[0].len == 0 and p.pending[1].len == 0 and
      (not p.stopping or p.killed):
    let status = p.process.reap()
    p.status = if p.stopping: -1 else: status
    p.done = true

proc millisecondsUntil(deadline: MonoTime): int =
  int(max(0'i64, ((deadline - getMonoTime()).inNanoseconds + 999_999) div 1_000_000))

proc waitTimeout*(p: ProcessPump): int =
  result = -1
  # A fairness yield during the final sweep still has immediate work: another
  # read must establish EAGAIN/EOF. Waiting for readiness here could hang on a
  # now-empty descriptor held open by a descendant after an exact-size burst.
  if p.exited:
    for i in 0..1:
      if not p.outputDone[i] and p.pending[i].len == 0: return 0
  if p.hasDeadline and not p.stopping: result = millisecondsUntil(p.deadline)
  if p.stopping and not p.killed: result = millisecondsUntil(p.stopDeadline)
  if not p.exited and not p.process.hasExitNotification:
    result = if result < 0: 5 else: min(result, 5)

proc addInterests*(p: ProcessPump, descriptors: var seq[TPollfd]) =
  template watch(descriptor: cint, interest: cshort) =
    if descriptor >= 0: descriptors.add TPollfd(fd: descriptor, events: interest)
  if not p.exited: watch(p.process.exitHandle, POLLIN)
  for i in 0..1:
    if p.pending[i].len > p.offsets[i]: watch(p.sinks[i], POLLOUT)
    elif not p.outputDone[i]:
      watch((if i == 0: p.process.outputHandle else: p.process.errorHandle), POLLIN)
  if not p.inputDone:
    if p.inputOffset < p.input.len: watch(p.process.inputHandle, POLLOUT)
    else: watch(p.source, POLLIN)

proc waitProcessIo*(descriptors: var seq[TPollfd], timeout: int) =
  let data = if descriptors.len > 0: addr descriptors[0] else: nil
  let rc = posix.poll(data, Tnfds(descriptors.len), cint(timeout))
  if rc < 0 and errno != EINTR: raiseOSError(osLastError())

proc runProcessPump*(p: ProcessPump) =
  var descriptors: seq[TPollfd]
  while not p.done:
    p.advance()
    if p.done: break
    descriptors.setLen(0)
    p.addInterests(descriptors)
    waitProcessIo(descriptors, p.waitTimeout())
