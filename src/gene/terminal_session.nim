## One embedded interactive terminal: PTY process + VT state + bounded input.

import std/[algorithm, monotimes, strutils, times, unicode]
import ./[pty_process, vterm]

type
  TerminalSessionObj = object
    process*: PtyProcess
    emulator*: VTermEmulator
    pendingInput: string
    maxPendingInput: int
    outputBytes*: uint64
    inputBytes*: uint64
    stopped*: bool
    exitStatus*: int
    eof: bool
    stopPhase: int
    stopDeadline: MonoTime
    stopGraceMs: int
  TerminalSession* = ref TerminalSessionObj

  TerminalTextCapture* = object
    text*: string
    truncated*: bool

const
  defaultTerminalInputCap* = 1024 * 1024
  defaultTerminalPumpBytes* = 64 * 1024

proc `=destroy`(session: var TerminalSessionObj) =
  if session.process != nil:
    try:
      session.process.close()
    except CatchableError:
      discard
  if session.emulator != nil:
    session.emulator.close()

proc openTerminalSession*(argv: seq[string], cwd = "", rows = 24, cols = 80,
                          environment: seq[string] = @[],
                          scrollbackLines = 2000,
                          maxPendingInput = defaultTerminalInputCap):
                          TerminalSession =
  if maxPendingInput <= 0:
    raise newException(ValueError, "terminal input cap must be positive")
  let emulator = openVTerm(rows, cols, scrollbackLines)
  try:
    let process = spawnPty(argv, cwd, rows, cols, environment)
    new(result)
    result.process = process
    result.emulator = emulator
    result.maxPendingInput = maxPendingInput
    result.exitStatus = -1
  except:
    emulator.close()
    raise

proc requireRunning(session: TerminalSession) =
  if session == nil or session.process == nil or session.emulator == nil:
    raise newException(IOError, "terminal session is closed")
  if session.stopped:
    raise newException(IOError, "terminal session is stopped")
  if session.stopPhase > 0:
    raise newException(IOError, "terminal session is stopping")

proc stopping*(session: TerminalSession): bool =
  session != nil and not session.stopped and session.stopPhase > 0

proc enqueue(session: TerminalSession, bytes: string) =
  if bytes.len == 0:
    return
  if session.pendingInput.len + bytes.len > session.maxPendingInput:
    raise newException(IOError, "terminal input queue limit exceeded")
  session.pendingInput.add bytes

proc collectEmulatorOutput(session: TerminalSession) =
  session.enqueue(session.emulator.drainOutput())

proc flushInput(session: TerminalSession) =
  while session.pendingInput.len > 0:
    let written = session.process.writeAvailable(session.pendingInput)
    if written <= 0:
      break
    session.inputBytes += uint64(written)
    if written == session.pendingInput.len:
      session.pendingInput.setLen(0)
    else:
      session.pendingInput = session.pendingInput[written .. ^1]

proc pump*(session: TerminalSession,
           maxBytes = defaultTerminalPumpBytes): bool =
  ## Consume a bounded output burst, advance VT state, send emulator replies,
  ## and observe process exit. Returns true when visible/lifecycle state moved.
  if session == nil or session.process == nil or session.emulator == nil:
    return false
  if session.stopped:
    return false
  if maxBytes <= 0:
    raise newException(ValueError, "terminal pump limit must be positive")

  session.flushInput()
  let before = session.emulator.snapshot().generation
  let available = session.process.readAvailable(maxBytes)
  if available.data.len > 0:
    session.outputBytes += uint64(available.data.len)
    session.emulator.feed(available.data)
    session.collectEmulatorOutput()
    session.flushInput()
  session.eof = session.eof or available.eof
  var lifecycleChanged = false
  if session.process.pollExit():
    # Drain bytes written immediately before exit. A nonblocking read after
    # waitpid is safe and prevents the last prompt/result from disappearing.
    let final = session.process.readAvailable(maxBytes)
    if final.data.len > 0:
      session.outputBytes += uint64(final.data.len)
      session.emulator.feed(final.data)
      session.collectEmulatorOutput()
      session.flushInput()
    session.stopped = true
    session.exitStatus = session.process.exitStatus
    # The emulator remains available for a stopped pane, but the PTY master
    # is no longer useful after the final drain. Release the host descriptor
    # immediately instead of retaining one per stopped worker snapshot.
    session.process.close()
    lifecycleChanged = true
  elif session.stopPhase > 0 and getMonoTime() >= session.stopDeadline:
    case session.stopPhase
    of 1:
      session.process.signalSession(ptySignalNumber(ptySignalTerm))
      session.stopPhase = 2
      session.stopDeadline = getMonoTime() +
        initDuration(milliseconds = session.stopGraceMs)
      lifecycleChanged = true
    of 2:
      session.process.signalSession(ptySignalNumber(ptySignalKill))
      session.process.disconnect()
      session.pendingInput.setLen(0)
      session.stopPhase = 3
      lifecycleChanged = true
    else:
      discard
  result = available.data.len > 0 or session.stopped or
           lifecycleChanged or session.emulator.snapshot().generation != before

proc sendBytes*(session: TerminalSession, bytes: string) =
  session.requireRunning()
  session.enqueue(bytes)
  session.flushInput()

proc sendText*(session: TerminalSession, text: string) =
  ## Printable UTF-8 is already the PTY wire representation. Special keys use
  ## sendKey so application-cursor/keypad modes are respected by libvterm.
  session.sendBytes(text)

proc sendKey*(session: TerminalSession, key: TerminalKey,
              modifiers = terminalModNone) =
  session.requireRunning()
  session.emulator.sendKey(key, modifiers)
  session.collectEmulatorOutput()
  session.flushInput()

proc sendRune*(session: TerminalSession, codepoint: Rune,
               modifiers = terminalModNone) =
  session.requireRunning()
  session.emulator.sendRune(codepoint, modifiers)
  session.collectEmulatorOutput()
  session.flushInput()

proc sendMouseWheel*(session: TerminalSession, row, col, direction: int,
                     modifiers = terminalModNone) =
  session.requireRunning()
  if direction == 0:
    return
  session.emulator.sendMouseMove(max(0, row), max(0, col), modifiers)
  session.emulator.sendMouseButton(if direction > 0: 4 else: 5, true,
                                   modifiers)
  session.collectEmulatorOutput()
  session.flushInput()

proc startPaste*(session: TerminalSession) =
  session.requireRunning()
  session.emulator.startPaste()
  session.collectEmulatorOutput()
  session.flushInput()

proc endPaste*(session: TerminalSession) =
  session.requireRunning()
  session.emulator.endPaste()
  session.collectEmulatorOutput()
  session.flushInput()

proc focus*(session: TerminalSession, active: bool) =
  session.requireRunning()
  if active:
    session.emulator.focusIn()
  else:
    session.emulator.focusOut()
  session.collectEmulatorOutput()
  session.flushInput()

proc resize*(session: TerminalSession, rows, cols: int) =
  session.requireRunning()
  session.emulator.resize(rows, cols)
  session.process.resize(rows, cols)

proc signal*(session: TerminalSession, signalNumber: int) =
  session.requireRunning()
  session.process.signal(signalNumber)

proc snapshot*(session: TerminalSession): TerminalSnapshot =
  if session == nil or session.emulator == nil:
    raise newException(IOError, "terminal session is closed")
  session.emulator.snapshot()

proc cell*(session: TerminalSession, row, col: int): TerminalCell =
  if session == nil or session.emulator == nil:
    raise newException(IOError, "terminal session is closed")
  session.emulator.cell(row, col)

proc scrollbackCell*(session: TerminalSession, line, col: int): TerminalCell =
  if session == nil or session.emulator == nil:
    raise newException(IOError, "terminal session is closed")
  session.emulator.scrollbackCell(line, col)

proc scrollbackCols*(session: TerminalSession, line: int): int =
  if session == nil or session.emulator == nil:
    raise newException(IOError, "terminal session is closed")
  session.emulator.scrollbackCols(line)

proc terminalLine(session: TerminalSession, row: int): string =
  let state = session.snapshot()
  for col in 0 ..< state.cols:
    let item = session.cell(row, col)
    if item.continuation:
      continue
    if item.text.len == 0:
      result.add ' '
    else:
      result.add item.text
  while result.len > 0 and result[^1] in {' ', '\t', '\r'}:
    result.setLen(result.len - 1)

proc terminalScrollbackLine(session: TerminalSession, line: int): string =
  let cols = session.scrollbackCols(line)
  for col in 0 ..< cols:
    let item = session.scrollbackCell(line, col)
    if item.continuation:
      continue
    if item.text.len == 0:
      result.add ' '
    else:
      result.add item.text
  while result.len > 0 and result[^1] in {' ', '\t', '\r'}:
    result.setLen(result.len - 1)

proc utf8Suffix(text: string, maxBytes: int): string =
  if maxBytes <= 0:
    return ""
  if text.len <= maxBytes:
    return text
  var first = text.len - maxBytes
  while first < text.len and (text[first].ord and 0xC0) == 0x80:
    inc first
  if first < text.len:
    result = text[first .. ^1]

proc captureText*(session: TerminalSession, maxBytes: int): TerminalTextCapture =
  ## Materialize only the newest bounded plain-text projection. Walking from
  ## the tail avoids rebuilding the complete scrollback ring at each agent
  ## checkpoint while keeping redaction in the Gene layer.
  if session == nil or session.emulator == nil:
    raise newException(IOError, "terminal session is closed")
  if maxBytes <= 0:
    raise newException(ValueError, "terminal capture limit must be positive")

  let state = session.snapshot()
  var screenLines = newSeq[string](state.rows)
  var lastScreenLine = -1
  for row in 0 ..< state.rows:
    screenLines[row] = session.terminalLine(row)
    if screenLines[row].len > 0:
      lastScreenLine = row

  var newestFirst: seq[string]
  var used = 0
  var exhausted = false
  var truncated = state.scrollbackDropped > 0
  proc addNewest(line: string): bool =
    let separator = if newestFirst.len == 0: 0 else: 1
    let remaining = maxBytes - used - separator
    if remaining <= 0:
      truncated = true
      return false
    if line.len > remaining:
      newestFirst.add utf8Suffix(line, remaining)
      used = maxBytes
      truncated = true
      return false
    newestFirst.add line
    used += separator + line.len
    true

  if lastScreenLine >= 0:
    for row in countdown(lastScreenLine, 0):
      if not addNewest(screenLines[row]):
        exhausted = true
        break
  if not exhausted and state.scrollbackLines > 0:
    for line in countdown(state.scrollbackLines - 1, 0):
      if not addNewest(session.terminalScrollbackLine(line)):
        exhausted = true
        break
  newestFirst.reverse()
  result.text = newestFirst.join("\n")
  result.truncated = truncated

proc stop*(session: TerminalSession, graceMs = 200) =
  if session == nil or session.process == nil or session.stopped:
    return
  session.process.stop(graceMs)
  discard session.pump()
  session.stopped = true
  session.exitStatus = session.process.exitStatus

proc requestStop*(session: TerminalSession, graceMs = 200) =
  ## Begin bounded process-group shutdown without waiting on the UI thread.
  ## Subsequent pump calls advance HUP -> TERM -> KILL and reap the child.
  if session == nil or session.process == nil or session.stopped or
      session.stopPhase > 0:
    return
  if session.process.pollExit():
    discard session.pump()
    return
  session.stopGraceMs = max(1, graceMs)
  session.process.signalSession(ptySignalNumber(ptySignalHup))
  session.stopPhase = 1
  session.stopDeadline = getMonoTime() +
    initDuration(milliseconds = session.stopGraceMs)

proc close*(session: TerminalSession) =
  if session == nil:
    return
  if session.process != nil:
    session.process.close()
    session.process = nil
  if session.emulator != nil:
    session.emulator.close()
    session.emulator = nil
  session.stopped = true
