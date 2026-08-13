## Local terminal authority: PTY sessions, the libvterm state machine, and the
## owned curses screen (docs/stdlib.md `terminal` and `curses`).
##
## `include`d by stdlib.nim late -- it depends on `nativeReceiverIs` and the
## `os` natives defined earlier there. Its declarations live in
## stdlib_term_decls.nim, included near the top of stdlib.nim. As with
## http_server.nim, this file may use the VM's require*/raise*/newNativeWrapper
## helpers directly: it is a separate file to make the boundary visible, not to
## change linkage. Converting it to an `import` would break the single
## translation unit the hot paths rely on.
##
## The `terminal` and `curses` namespace registration stays in stdlib.nim's
## registerStdlibNamespaces, which owns the locals it needs.

# --- terminal: local PTY + VT/xterm session --------------------------------

proc raiseTerminalError(message: string, scope: Scope) =
  var props = initPropTable()
  props["message"] = newStr(message)
  var error: ref GeneError
  new(error)
  error.msg = message
  error.errVal = newNode(builtInTypeHead(scope, "TerminalError"), props = props)
  error.hasErrVal = true
  raise error

proc requireOsPty(name: string, value: Value, scope: Scope) =
  if value.kind != vkCapability or value.capabilityName != "Os/Pty":
    raiseTerminalError(name & " expects Os/Pty authority", scope)

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  type TerminalUpdatePending {.acyclic.} = ref object
    taskOwner: Value
    sessionOwner: Value
    schedulerPtr: pointer
    sessionId: int
    maxBytes: int

  var terminalUpdatePending: seq[TerminalUpdatePending]

  proc terminalHandleId(name: string, value: Value, scope: Scope,
                        requireOpen = true): int =
    if not nativeReceiverIs(scope, value, "TerminalSession"):
      raiseTerminalError(name & " expects a terminal/Session", scope)
    let id = value.props.getOrDefault("id", VOID)
    let closed = value.props.getOrDefault("closed", VOID)
    if id.kind != vkInt or closed.kind != vkCell:
      raiseTerminalError(name & " received an invalid terminal/Session", scope)
    if requireOpen and closed.cellValue.isTruthy:
      raiseTerminalError(name & ": terminal session is closed", scope)
    let nativeId = int(id.intVal)
    if requireOpen and not terminalSessions.hasKey(nativeId):
      raiseTerminalError(name & ": terminal session is unavailable", scope)
    nativeId

  proc terminalSession(name: string, value: Value,
                       scope: Scope): TerminalSession =
    terminalSessions[terminalHandleId(name, value, scope)]

  proc terminalEnvironment(overrides: Value, name: string,
                           scope: Scope): seq[string] =
    var values = initOrderedTable[string, string]()
    for item in sanitizedTerminalEnvironment():
      let separator = item.find('=')
      if separator > 0:
        values[item[0 ..< separator]] = item[separator + 1 .. ^1]
    if overrides.kind != vkVoid:
      requirePropMap(name & " ^environment", overrides)
      for key, value in overrides.mapEntries:
        requireStr(name & " ^environment ^" & key, value)
        values[key] = value.strVal
    for key, value in values:
      result.add key & "=" & value

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

  proc terminalSnapshotValue(session: TerminalSession,
                             includeLines = true): Value =
    let state = session.snapshot()
    var props = initPropTable()
    props["generation"] = newInt(int64(state.generation))
    props["rows"] = newInt(state.rows)
    props["cols"] = newInt(state.cols)
    props["cursor_row"] = newInt(state.cursorRow)
    props["cursor_col"] = newInt(state.cursorCol)
    props["cursor_visible"] = newBool(state.cursorVisible)
    props["altscreen"] = newBool(state.altscreen)
    props["mouse_mode"] = newInt(state.mouseMode)
    props["focus_reporting"] = newBool(state.focusReporting)
    props["title"] = newStr(state.title)
    props["working_directory_uri"] = newStr(state.workingDirectoryUri)
    props["scrollback_lines"] = newInt(state.scrollbackLines)
    props["scrollback_dropped"] = newInt(int64(state.scrollbackDropped))
    props["output_bytes"] = newInt(int64(session.outputBytes))
    props["input_bytes"] = newInt(int64(session.inputBytes))
    props["stopped"] = newBool(session.stopped)
    props["stopping"] = newBool(session.stopping)
    props["exit_status"] =
      if session.stopped: newInt(session.exitStatus) else: NIL
    if includeLines:
      var lines = newSeq[Value](state.rows)
      for row in 0 ..< state.rows:
        lines[row] = newStr(terminalLine(session, row))
      props["lines"] = newList(lines)
    newMap(props)

  proc terminalCaptureTextValue(session: TerminalSession,
                                maxBytes: int): Value =
    let capture = session.captureText(maxBytes)
    var props = initPropTable()
    props["text"] = newStr(capture.text)
    props["truncated"] = newBool(capture.truncated)
    newMap(props)

  proc terminalUpdateValue(session: TerminalSession, changed: bool): Value =
    var props = initPropTable()
    props["changed"] = newBool(changed)
    # The UI renderer reads attributed cells from the native session by id.
    # A pump notification therefore carries only generation/lifecycle
    # metadata; explicit snapshot/checkpoint calls materialize bounded lines.
    props["snapshot"] = terminalSnapshotValue(session, includeLines = false)
    newMap(props)

  proc pollTerminalUpdateCompletions() =
    var i = 0
    while i < terminalUpdatePending.len:
      let pending {.cursor.} = terminalUpdatePending[i]
      let task = pending.taskOwner
      var remove = false
      if task.taskCancelled:
        remove = true
      elif not terminalSessions.hasKey(pending.sessionId):
        if tryFailTask(task, "terminal/next_update: session is closed"):
          wakeTaskWaitersIn(cast[SchedulerState](pending.schedulerPtr), task)
        remove = true
      else:
        try:
          let session = terminalSessions[pending.sessionId]
          let changed = session.pump(pending.maxBytes)
          if changed:
            if tryCompleteTask(task, terminalUpdateValue(session, true)):
              wakeTaskWaitersIn(cast[SchedulerState](pending.schedulerPtr), task)
            remove = true
        except CatchableError as error:
          if tryFailTask(task, "terminal/next_update: " & error.msg):
            wakeTaskWaitersIn(cast[SchedulerState](pending.schedulerPtr), task)
          remove = true
      if remove:
        endExternalNativeOp()
        terminalUpdatePending.delete(i)
      else:
        inc i

  proc biTerminalNextUpdate(args: openArray[Value],
                            call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/next_update", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    if scope == nil or scope.application == nil:
      raiseTerminalError("terminal/next_update requires a scheduler scope",
                         scope)
    let id = terminalHandleId("terminal/next_update", args[0], scope)
    var maxBytes = defaultTerminalPumpBytes
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "max_bytes":
          maxBytes = int(requireInt64("terminal/next_update ^max_bytes",
                                      call[].namedValues[i]))
        else:
          raiseTerminalError(
            "terminal/next_update got unexpected named argument: " & argName,
            scope)
    if maxBytes <= 0 or maxBytes > 1024 * 1024:
      raiseTerminalError(
        "terminal/next_update ^max_bytes must be between 1 and 1048576",
        scope)
    for pending in terminalUpdatePending:
      if pending.sessionId == id and not pending.taskOwner.taskDone:
        raiseTerminalError(
          "terminal/next_update already has a waiter for this session", scope)
    let task = newExternalTask()
    let pending = TerminalUpdatePending(sessionId: id, maxBytes: maxBytes)
    pending.taskOwner = retainedCopy(task)
    pending.sessionOwner = retainedCopy(args[0])
    pending.schedulerPtr = cast[pointer](schedulerForScope(scope))
    terminalUpdatePending.add pending
    beginExternalNativeOp()
    pollTerminalUpdateCompletions()
    task

  proc biTerminalOpen(args: openArray[Value],
                      call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1:
      raise newException(GeneError,
        "terminal/open expects the Os/Pty capability plus named arguments")
    let scope = if call == nil: nil else: call[].dispatchScope
    requireOsPty("terminal/open", args[0], scope)
    var command = getEnv("SHELL")
    if command.len == 0:
      command = "/bin/sh"
    var commandArgs: seq[string]
    var cwd = getCurrentDir()
    var rows = 24
    var cols = 80
    var scrollbackLines = 2000
    var environment = VOID
    if call != nil:
      for i, argName in call[].namedNames:
        let value = call[].namedValues[i]
        case argName
        of "cmd":
          requireStr("terminal/open ^cmd", value)
          command = value.strVal
        of "args":
          requireList("terminal/open ^args", value)
          for item in value.listItems:
            requireStr("terminal/open ^args item", item)
            commandArgs.add item.strVal
        of "dir":
          requireStr("terminal/open ^dir", value)
          cwd = value.strVal
        of "rows": rows = int(requireInt64("terminal/open ^rows", value))
        of "cols": cols = int(requireInt64("terminal/open ^cols", value))
        of "scrollback_lines":
          scrollbackLines = int(requireInt64(
            "terminal/open ^scrollback_lines", value))
        of "environment": environment = value
        else:
          raiseTerminalError(
            "terminal/open got unexpected named argument: " & argName, scope)
    if command.len == 0:
      raiseTerminalError("terminal/open requires a non-empty ^cmd", scope)
    try:
      let session = openTerminalSession(
        @[command] & commandArgs, cwd = cwd, rows = rows, cols = cols,
        environment = terminalEnvironment(environment, "terminal/open", scope),
        scrollbackLines = scrollbackLines)
      let id = terminalSessionNextId
      inc terminalSessionNextId
      terminalSessions[id] = session
      newNativeWrapper(builtInTypeHead(scope, "TerminalSession"),
        {"id": newInt(id), "closed": newCell(FALSE)})
    except GeneError:
      raise
    except CatchableError as error:
      raiseTerminalError("terminal/open: " & error.msg, scope)
      NIL

  proc biTerminalPump(args: openArray[Value],
                      call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/pump", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/pump", args[0], scope)
    var maxBytes = defaultTerminalPumpBytes
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "max_bytes":
          maxBytes = int(requireInt64("terminal/pump ^max_bytes",
                                      call[].namedValues[i]))
        else:
          raiseTerminalError(
            "terminal/pump got unexpected named argument: " & argName, scope)
    try:
      if maxBytes <= 0 or maxBytes > 1024 * 1024:
        raiseTerminalError(
          "terminal/pump ^max_bytes must be between 1 and 1048576", scope)
      var props = initPropTable()
      props["changed"] = newBool(session.pump(maxBytes))
      props["snapshot"] = terminalSnapshotValue(session)
      newMap(props)
    except CatchableError as error:
      raiseTerminalError("terminal/pump: " & error.msg, scope)
      NIL

  proc biTerminalSnapshot(args: openArray[Value],
                          call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/snapshot", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    terminalSnapshotValue(terminalSession("terminal/snapshot", args[0], scope))

  proc biTerminalCaptureText(args: openArray[Value],
                             call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/capture_text", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/capture_text", args[0], scope)
    var maxBytes = 64 * 1024
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "max_bytes":
          maxBytes = int(requireInt64("terminal/capture_text ^max_bytes",
                                      call[].namedValues[i]))
        else:
          raiseTerminalError(
            "terminal/capture_text got unexpected named argument: " & argName,
            scope)
    if maxBytes <= 0 or maxBytes > 1024 * 1024:
      raiseTerminalError(
        "terminal/capture_text ^max_bytes must be between 1 and 1048576",
        scope)
    try:
      terminalCaptureTextValue(session, maxBytes)
    except CatchableError as error:
      raiseTerminalError("terminal/capture_text: " & error.msg, scope)
      NIL

  proc biTerminalWrite(args: openArray[Value],
                       call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/write", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/write", args[0], scope)
    var bytes = ""
    var set = false
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "bytes":
          requireStr("terminal/write ^bytes", call[].namedValues[i])
          bytes = call[].namedValues[i].strVal
          set = true
        else:
          raiseTerminalError(
            "terminal/write got unexpected named argument: " & argName, scope)
    if not set:
      raiseTerminalError("terminal/write requires ^bytes", scope)
    try:
      session.sendBytes(bytes)
      newInt(bytes.len)
    except CatchableError as error:
      raiseTerminalError("terminal/write: " & error.msg, scope)
      NIL

  proc terminalKey(name: string, scope: Scope): TerminalKey =
    case name
    of "enter": vtkEnter
    of "tab": vtkTab
    of "backspace": vtkBackspace
    of "escape": vtkEscape
    of "up": vtkUp
    of "down": vtkDown
    of "left": vtkLeft
    of "right": vtkRight
    of "insert": vtkInsert
    of "delete": vtkDelete
    of "home": vtkHome
    of "end": vtkEnd
    of "page_up": vtkPageUp
    of "page_down": vtkPageDown
    of "f1": vtkF1
    of "f2": vtkF2
    of "f3": vtkF3
    of "f4": vtkF4
    of "f5": vtkF5
    of "f6": vtkF6
    of "f7": vtkF7
    of "f8": vtkF8
    of "f9": vtkF9
    of "f10": vtkF10
    of "f11": vtkF11
    of "f12": vtkF12
    else:
      raiseTerminalError("terminal/key: unknown key " & name, scope)
      vtkNone

  proc biTerminalKey(args: openArray[Value],
                     call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/key", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/key", args[0], scope)
    var key = ""
    var sequence = ""
    var controlCode = 0
    var modifiers = terminalModNone
    if call != nil:
      for i, argName in call[].namedNames:
        let value = call[].namedValues[i]
        case argName
        of "key":
          requireStr("terminal/key ^key", value)
          key = value.strVal
        of "sequence":
          requireStr("terminal/key ^sequence", value)
          sequence = value.strVal
        of "code":
          controlCode = int(requireInt64("terminal/key ^code", value))
        of "shift", "alt", "ctrl":
          if value.kind != vkBool:
            raiseTerminalError("terminal/key ^" & argName & " must be Bool",
                               scope)
          if value.boolVal:
            modifiers = modifiers or
              (case argName
               of "shift": terminalModShift
               of "alt": terminalModAlt
               else: terminalModCtrl)
        else:
          raiseTerminalError(
            "terminal/key got unexpected named argument: " & argName, scope)
    if key.len == 0:
      raiseTerminalError("terminal/key requires ^key", scope)
    try:
      # These editor events are control bytes, not VT named keys. Keep their
      # byte spelling here so the Gene TUI never has to manufacture strings
      # containing source-level control characters.
      case key
      of "interrupt": session.sendBytes($char(3))
      of "eof": session.sendBytes($char(4))
      of "edit": session.sendBytes($char(5))
      of "reverse_search": session.sendBytes($char(18))
      of "control":
        if controlCode < 1 or controlCode > 31:
          raiseTerminalError(
            "terminal/key ^code must be between 1 and 31 for ^key control",
            scope)
        session.sendBytes($char(controlCode))
      of "escape_sequence": session.sendBytes($char(27) & sequence)
      else: session.sendKey(terminalKey(key, scope), modifiers)
      NIL
    except CatchableError as error:
      raiseTerminalError("terminal/key: " & error.msg, scope)
      NIL

  proc biTerminalPaste(args: openArray[Value],
                       call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/paste", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/paste", args[0], scope)
    var active = false
    var set = false
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "active":
          let value = call[].namedValues[i]
          if value.kind != vkBool:
            raiseTerminalError("terminal/paste ^active must be Bool", scope)
          active = value.boolVal
          set = true
        else:
          raiseTerminalError(
            "terminal/paste got unexpected named argument: " & argName, scope)
    if not set:
      raiseTerminalError("terminal/paste requires ^active", scope)
    if active: session.startPaste() else: session.endPaste()
    NIL

  proc biTerminalFocus(args: openArray[Value],
                       call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/focus", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/focus", args[0], scope)
    var active = false
    var set = false
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "active":
          let value = call[].namedValues[i]
          if value.kind != vkBool:
            raiseTerminalError("terminal/focus ^active must be Bool", scope)
          active = value.boolVal
          set = true
        else:
          raiseTerminalError(
            "terminal/focus got unexpected named argument: " & argName,
            scope)
    if not set:
      raiseTerminalError("terminal/focus requires ^active", scope)
    try:
      session.focus(active)
      NIL
    except CatchableError as error:
      raiseTerminalError("terminal/focus: " & error.msg, scope)
      NIL

  proc biTerminalMouse(args: openArray[Value],
                       call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/mouse", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/mouse", args[0], scope)
    var row = 0
    var col = 0
    var direction = 0
    var modifiers = terminalModNone
    if call != nil:
      for i, argName in call[].namedNames:
        let value = call[].namedValues[i]
        case argName
        of "row": row = int(requireInt64("terminal/mouse ^row", value))
        of "col": col = int(requireInt64("terminal/mouse ^col", value))
        of "direction":
          direction = int(requireInt64("terminal/mouse ^direction", value))
        of "shift", "alt", "ctrl":
          if value.kind != vkBool:
            raiseTerminalError("terminal/mouse ^" & argName & " must be Bool",
                               scope)
          if value.boolVal:
            modifiers = modifiers or
              (case argName
               of "shift": terminalModShift
               of "alt": terminalModAlt
               else: terminalModCtrl)
        else:
          raiseTerminalError(
            "terminal/mouse got unexpected named argument: " & argName, scope)
    if direction notin [-1, 1]:
      raiseTerminalError("terminal/mouse ^direction must be -1 or 1", scope)
    try:
      session.sendMouseWheel(row, col, direction, modifiers)
      NIL
    except CatchableError as error:
      raiseTerminalError("terminal/mouse: " & error.msg, scope)
      NIL

  proc biTerminalResize(args: openArray[Value],
                        call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/resize", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/resize", args[0], scope)
    var rows = 0
    var cols = 0
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "rows": rows = int(requireInt64("terminal/resize ^rows",
                                            call[].namedValues[i]))
        of "cols": cols = int(requireInt64("terminal/resize ^cols",
                                            call[].namedValues[i]))
        else:
          raiseTerminalError(
            "terminal/resize got unexpected named argument: " & argName,
            scope)
    try:
      session.resize(rows, cols)
      NIL
    except CatchableError as error:
      raiseTerminalError("terminal/resize: " & error.msg, scope)
      NIL

  proc biTerminalSignal(args: openArray[Value],
                        call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/signal", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/signal", args[0], scope)
    var signalName = ""
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "name":
          requireStr("terminal/signal ^name", call[].namedValues[i])
          signalName = call[].namedValues[i].strVal.toUpperAscii()
        else:
          raiseTerminalError(
            "terminal/signal got unexpected named argument: " & argName,
            scope)
    let signalNumber =
      case signalName
      of "HUP": ptySignalNumber(ptySignalHup)
      of "INT": ptySignalNumber(ptySignalInt)
      of "TERM": ptySignalNumber(ptySignalTerm)
      of "WINCH": ptySignalNumber(ptySignalWinch)
      of "KILL": ptySignalNumber(ptySignalKill)
      else:
        raiseTerminalError("terminal/signal: unsupported signal " & signalName,
                           scope)
        0
    session.signal(signalNumber)
    NIL

  proc biTerminalStop(args: openArray[Value],
                      call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/stop", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/stop", args[0], scope)
    try:
      session.stop()
      terminalSnapshotValue(session)
    except CatchableError as error:
      raiseTerminalError("terminal/stop: " & error.msg, scope)
      NIL

  proc biTerminalRequestStop(args: openArray[Value],
                             call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/request_stop", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let session = terminalSession("terminal/request_stop", args[0], scope)
    var graceMs = 200
    if call != nil:
      for i, argName in call[].namedNames:
        case argName
        of "grace_ms":
          graceMs = int(requireInt64("terminal/request_stop ^grace_ms",
                                     call[].namedValues[i]))
        else:
          raiseTerminalError(
            "terminal/request_stop got unexpected named argument: " & argName,
            scope)
    if graceMs <= 0 or graceMs > 5000:
      raiseTerminalError(
        "terminal/request_stop ^grace_ms must be between 1 and 5000", scope)
    try:
      session.requestStop(graceMs)
      terminalSnapshotValue(session)
    except CatchableError as error:
      raiseTerminalError("terminal/request_stop: " & error.msg, scope)
      NIL

  proc biTerminalClose(args: openArray[Value],
                       call: ptr NativeCall): Value {.nimcall.} =
    requireOne("terminal/close", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let id = terminalHandleId("terminal/close", args[0], scope,
                              requireOpen = false)
    let closed = args[0].props["closed"]
    if closed.cellValue.isTruthy:
      return NIL
    if terminalSessions.hasKey(id):
      terminalSessions[id].close()
      terminalSessions.del(id)
    var i = 0
    while i < terminalUpdatePending.len:
      let pending {.cursor.} = terminalUpdatePending[i]
      if pending.sessionId == id:
        let task = pending.taskOwner
        if tryFailTask(task, "terminal/next_update: session is closed"):
          wakeTaskWaitersIn(cast[SchedulerState](pending.schedulerPtr), task)
        endExternalNativeOp()
        terminalUpdatePending.delete(i)
      else:
        inc i
    closed.setCellValue(TRUE)
    NIL
else:
  proc pollTerminalUpdateCompletions() = discard

  proc biTerminalOpen(args: openArray[Value],
                      call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    raiseTerminalError("terminal/open is unavailable on this platform", scope)
    NIL

  template unavailableTerminalNative(name: untyped) =
    proc name(args: openArray[Value],
              call: ptr NativeCall): Value {.nimcall.} =
      let scope = if call == nil: nil else: call[].dispatchScope
      raiseTerminalError("terminal sessions are unavailable on this platform",
                         scope)
      NIL

  unavailableTerminalNative(biTerminalPump)
  unavailableTerminalNative(biTerminalNextUpdate)
  unavailableTerminalNative(biTerminalSnapshot)
  unavailableTerminalNative(biTerminalCaptureText)
  unavailableTerminalNative(biTerminalWrite)
  unavailableTerminalNative(biTerminalKey)
  unavailableTerminalNative(biTerminalPaste)
  unavailableTerminalNative(biTerminalFocus)
  unavailableTerminalNative(biTerminalMouse)
  unavailableTerminalNative(biTerminalResize)
  unavailableTerminalNative(biTerminalSignal)
  unavailableTerminalNative(biTerminalStop)
  unavailableTerminalNative(biTerminalRequestStop)
  unavailableTerminalNative(biTerminalClose)

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc openCursesInput() =
    if not cursesInputActive:
      clearCursesTranscriptCaches()
      cInstallRestoreHooks()
      cSaveTermios()
      cSetLocale()
      if cInitscr() == nil:
        raise newException(GeneError, "os/read_input could not initialize ncurses")
      cursesInputActive = true
      setConsoleLogSuppressed(true)
      cursesColorsReady = false
      cursesPasteReady = false
    # Deliver Ctrl-C as an editor key. Running turns still arm the explicit
    # SIGINT handler, so externally delivered interrupts retain cancellation
    # semantics while terminal Ctrl-C can clear the current draft.
    discard raw()
    discard noecho()
    discard keypad(stdscr, 1)
    discard tui_terminal.enableMouse()
    discard curs_set(1)
    if not cursesPasteReady:
      stdout.write("\e[?2004h")
      stdout.flushFile()
      cursesPasteReady = true
    if not cursesColorsReady and start_color() != CursesErr:
      discard use_default_colors()
      discard init_pair(PairInput.cshort, ColorCyan.cshort, (-1).cshort)
      discard init_pair(PairOutput.cshort, ColorGreen.cshort, (-1).cshort)
      discard init_pair(PairSeparator.cshort, ColorWhite.cshort, (-1).cshort)
      discard init_pair(PairStatus.cshort, ColorWhite.cshort, (-1).cshort)
      cursesColorsReady = true

  proc closeCursesInput() =
    if cursesInputActive:
      if cursesPasteReady:
        stdout.write("\e[?2004l")
        stdout.flushFile()
        cursesPasteReady = false
      timeout(-1)
      tui_terminal.disableMouse()
      discard keypad(stdscr, 0)
      discard cEcho()
      discard nocbreak()
      discard noraw()
      discard curs_set(1)
      discard cEndwin()
      discard reset_shell_mode()
      cursesInputActive = false
      setConsoleLogSuppressed(false)
      cursesColorsReady = false
      cursesPasteReady = false
      clearCursesTranscriptCaches()
    cRestoreTermios()
    cRestoreDisplay()

  proc utf8CharLenAt(text: string, i: int): int =
    let b = text[i].ord
    if b < 0x80: 1
    elif b < 0xE0: 2
    elif b < 0xF0: 3
    else: 4

  proc clipUtf8Chars(text: string, maxChars: int): string =
    if maxChars <= 0:
      return ""
    var i = 0
    var chars = 0
    while i < text.len and chars < maxChars:
      let step = min(utf8CharLenAt(text, i), text.len - i)
      result.add text.substr(i, i + step - 1)
      inc i, step
      inc chars

  proc addCursesText(text: string, maxWidth: int) =
    if maxWidth <= 0:
      return
    let clipped =
      if text.len > maxWidth: clipUtf8Chars(text, maxWidth)
      else: text
    discard addnstr(clipped.cstring, clipped.len.cint)

  proc withCursesColor(pair: int, body: proc()) =
    if cursesColorsReady:
      let attr = cColorPair(pair.cshort)
      discard cAttrOn(attr)
      try:
        body()
      finally:
        discard cAttrOff(attr)
    else:
      body()

  proc terminalColorIndex(color: TerminalColor): int =
    if color.isDefault:
      return -1
    if COLORS <= 8:
      let bright = int(color.red) + int(color.green) + int(color.blue)
      if bright < 96:
        return 0
      let dominant = max(int(color.red), max(int(color.green), int(color.blue)))
      var index = 0
      if int(color.red) * 2 >= dominant: index = index or 1
      if int(color.green) * 2 >= dominant: index = index or 2
      if int(color.blue) * 2 >= dominant: index = index or 4
      return index

    proc cubeLevel(value: uint8): int =
      if value < 48: 0
      elif value < 115: 1
      else: min(5, (int(value) - 35) div 40)
    proc cubeValue(level: int): int =
      if level == 0: 0 else: 55 + level * 40
    proc distance(r1, g1, b1, r2, g2, b2: int): int =
      let dr = r1 - r2
      let dg = g1 - g2
      let db = b1 - b2
      dr * dr + dg * dg + db * db

    let red = int(color.red)
    let green = int(color.green)
    let blue = int(color.blue)
    let r = cubeLevel(color.red)
    let g = cubeLevel(color.green)
    let b = cubeLevel(color.blue)
    let cube = 16 + 36 * r + 6 * g + b
    let cubeDistance = distance(red, green, blue,
                                cubeValue(r), cubeValue(g), cubeValue(b))
    let average = (red + green + blue) div 3
    let grayLevel = min(23, max(0, (average - 8 + 5) div 10))
    let grayValue = 8 + grayLevel * 10
    let grayDistance = distance(red, green, blue,
                                grayValue, grayValue, grayValue)
    if grayDistance < cubeDistance: 232 + grayLevel else: cube

  proc terminalColorPair(cell: TerminalCell): int =
    if not cursesColorsReady:
      return 0
    let foreground = terminalColorIndex(cell.foreground)
    let background = terminalColorIndex(cell.background)
    let key = (foreground, background)
    if cursesTerminalPairs.hasKey(key):
      return cursesTerminalPairs[key]
    if cursesTerminalNextPair >= int(COLOR_PAIRS):
      return PairOutput
    let pair = cursesTerminalNextPair
    if init_pair(pair.cshort, foreground.cshort, background.cshort) == CursesErr:
      return PairOutput
    inc cursesTerminalNextPair
    cursesTerminalPairs[key] = pair
    pair

  proc terminalAttrs(cell: TerminalCell): cint =
    if cell.bold: result = result or cAttrBold()
    if cell.dim: result = result or cAttrDim()
    if cell.italic: result = result or cAttrItalic()
    if cell.underline > 0: result = result or cAttrUnderline()
    if cell.reverse: result = result or cAttrReverse()
    if cell.blink: result = result or cAttrBlink()
    if cell.conceal: result = result or cAttrDim()
    # ncurses has no portable strike attribute. Underline is the bounded,
    # capability-safe fallback; the VT cell still retains strike separately.
    if cell.strike: result = result or cAttrUnderline()

  proc drawTerminalCell(cell: TerminalCell, row, col, maxWidth: int) =
    if cell.continuation or maxWidth <= 0:
      return
    discard cMove(row.cint, col.cint)
    let pair = terminalColorPair(cell)
    let attrs = terminalAttrs(cell)
    if pair > 0:
      discard cAttrOn(cColorPair(pair.cshort))
    if attrs != 0:
      discard cAttrOn(attrs)
    let text =
      if cell.conceal or cell.text.len == 0: " "
      else: cell.text
    # A cell's text may contain a base scalar plus combining marks, so byte or
    # scalar clipping corrupts it. Clip by the emulator-provided display width
    # and pass the complete UTF-8 cluster only when it fits the pane edge.
    if max(1, cell.width) <= maxWidth:
      discard addnstr(text.cstring, text.len.cint)
    if attrs != 0:
      discard cAttrOff(attrs)
    if pair > 0:
      discard cAttrOff(cColorPair(pair.cshort))

  proc terminalMaxScroll(session: TerminalSession, height: int): int =
    let state = session.snapshot()
    if state.altscreen:
      0
    else:
      max(0, state.scrollbackLines + state.rows - max(0, height))

  proc drawCursesTerminal(session: TerminalSession, top, left, height, width,
                          requestedScroll: int):
                          tuple[cursorVisible: bool, cursorRow, cursorCol: int] =
    if height <= 0 or width <= 0:
      return
    var state = session.snapshot()
    if not session.stopped and (state.rows != height or state.cols != width):
      try:
        session.resize(height, width)
        state = session.snapshot()
      except CatchableError:
        discard
    let history = if state.altscreen: 0 else: state.scrollbackLines
    let total = history + state.rows
    let scroll = min(max(0, requestedScroll), max(0, total - height))
    let first = max(0, total - height - scroll)
    for visibleRow in 0 ..< height:
      let line = first + visibleRow
      if line >= total:
        continue
      let columns =
        if line < history: min(width, session.scrollbackCols(line))
        else: min(width, state.cols)
      for col in 0 ..< columns:
        let item =
          if line < history: session.scrollbackCell(line, col)
          else: session.cell(line - history, col)
        drawTerminalCell(item, top + visibleRow, left + col, width - col)
    let cursorLine = history + state.cursorRow
    if scroll == 0 and state.cursorVisible and cursorLine >= first and
        cursorLine < first + height and state.cursorCol < width:
      result = (true, top + cursorLine - first, left + state.cursorCol)

  proc lineStart(input: string, cursor: int): int =
    result = 0
    let last = min(cursor, input.len)
    for i in 0 ..< last:
      if input[i] == '\n':
        result = i + 1

  proc cursorRowCol(input: string, cursor: int): tuple[row, col: int] =
    var row = 0
    var col = 0
    let last = min(cursor, input.len)
    for i in 0 ..< last:
      if input[i] == '\n':
        inc row
        col = 0
      else:
        inc col
    (row, col)

  proc splitCursesLines(text: string): seq[string] =
    var start = 0
    for i, ch in text:
      if ch == '\n':
        if i > start:
          result.add text.substr(start, i - 1)
        else:
          result.add ""
        start = i + 1
    if start < text.len:
      result.add text.substr(start)
    elif text.len == 0 or (text.len > 0 and text[^1] == '\n'):
      result.add ""

  proc isSeparatorLine(line: string): bool =
    if line.len == 0 or (line.len mod 3) != 0:
      return false
    var i = 0
    while i < line.len:
      if line[i].ord != 0xE2 or line[i + 1].ord != 0x94 or
          line[i + 2].ord != 0x80:
        return false
      inc i, 3
    true

  proc displayTranscriptLine(line: string, currentPair: var int): tuple[text: string, pair: int] =
    if line.startsWith("user|"):
      currentPair = PairInput
      (line.substr(5), PairInput)
    elif line.startsWith("assistant|"):
      currentPair = PairOutput
      (line.substr(10), PairOutput)
    elif line.startsWith("sep|"):
      currentPair = PairInput
      (repeat("─", max(1, line.substr(4).parseInt())), PairSeparator)
    elif isSeparatorLine(line):
      currentPair = PairInput
      (line, PairSeparator)
    elif line.startsWith("agent>") or line.startsWith("  · tool") or
        line.startsWith("Gene AI agent"):
      currentPair = PairOutput
      (line, PairOutput)
    else:
      (line, currentPair)

  proc wrapCursesText(text: string, width: int): seq[string] =
    ## Wrap at the last ASCII whitespace that fits, falling back to a UTF-8
    ## character boundary for long words. Newlines have already been split.
    let maxChars = max(1, width)
    if text.len == 0:
      result.add ""
      return
    var start = 0
    while start < text.len:
      var i = start
      var chars = 0
      var lastBreak = -1
      while i < text.len and chars < maxChars:
        if text[i] == ' ' or text[i] == '\t':
          lastBreak = i
        let step = min(utf8CharLenAt(text, i), text.len - i)
        inc i, step
        inc chars
      if i >= text.len:
        result.add text.substr(start)
        break
      var stop = i
      var next = i
      if lastBreak > start:
        stop = lastBreak
        next = lastBreak + 1
        while next < text.len and
            (text[next] == ' ' or text[next] == '\t'):
          inc next
      result.add text.substr(start, stop - 1)
      start = next

  proc transcriptRows(output: string, width: int): seq[CursesTranscriptRow] =
    var currentPair = PairOutput
    for line in splitCursesLines(output):
      let rendered = displayTranscriptLine(line, currentPair)
      if rendered.pair == PairSeparator:
        result.add CursesTranscriptRow(
          text: repeat("─", max(1, width)), pair: rendered.pair)
      else:
        for visualLine in wrapCursesText(rendered.text, width):
          result.add CursesTranscriptRow(text: visualLine,
                                         pair: rendered.pair)

  proc cachedTranscriptRows(cache: var CursesTranscriptCache,
                            output: string,
                            width: int): seq[CursesTranscriptRow] =
    ## Input editing redraws far more often than transcript content changes.
    ## Retain the parsed/wrapped rows for the active screen so a keypress only
    ## repaints terminal cells instead of re-splitting all retained output.
    if not cache.valid or cache.width != width or cache.output != output:
      cache.valid = true
      cache.output = output
      cache.width = width
      cache.rows = transcriptRows(output, width)
    cache.rows

  proc drawSeparator(row, width: int) =
    discard cMove(row.cint, 0)
    withCursesColor(PairSeparator,
      proc() =
        addCursesText(repeat("─", width), width))
    discard clrtoeol()

  proc cursesOutputRows(input: string, height: int): int =
    if height < 4:
      return 0
    let inputTotal = max(1, splitCursesLines(input).len)
    let inputRows = min(inputTotal, max(1, height - 3))
    max(0, height - inputRows - 3)

  proc cursesMainOutputWidth(width, paneCount: int): int =
    if paneCount == 0 or width < 48:
      width
    else:
      width - max(18, width div 3) - 1

  proc maxCursesOutputScroll(output, input: string,
                             height, width, paneCount: int): int =
    let outputWidth = cursesMainOutputWidth(width, paneCount)
    max(0, transcriptRows(output, outputWidth).len -
           cursesOutputRows(input, height))

  proc drawCursesTranscript(outputLines: openArray[CursesTranscriptRow],
                            top, left, height, width, outputScroll: int) =
    if height <= 0 or width <= 0:
      return
    let effectiveScroll = min(max(0, outputScroll),
                              max(0, outputLines.len - height))
    let firstOutput =
      if outputLines.len > height:
        max(0, outputLines.len - height - effectiveScroll)
      else:
        0
    for row in 0 ..< height:
      let idx = firstOutput + row
      if idx < outputLines.len:
        let line = outputLines[idx]
        discard cMove((top + row).cint, left.cint)
        withCursesColor(line.pair,
          proc() =
            addCursesText(line.text, width))

  proc drawCursesPanes(panes: openArray[CursesPane], outputRows, width: int):
                       tuple[cursorVisible: bool, cursorRow, cursorCol: int] =
    if panes.len == 0 or outputRows <= 0 or width < 48:
      if panes.len == 0:
        cursesPaneTranscriptCaches.setLen(0)
      return
    cursesPaneTranscriptCaches.setLen(panes.len)
    let mainWidth = cursesMainOutputWidth(width, panes.len)
    let divider = mainWidth
    let paneWidth = width - divider - 1
    for row in 0 ..< outputRows:
      discard cMove(row.cint, divider.cint)
      withCursesColor(PairSeparator,
        proc() = addCursesText("│", 1))
    var firstPane = 0
    var paneCount = panes.len
    var denseHeader = ""
    if outputRows < panes.len * 7:
      paneCount = 1
      for i, pane in panes:
        if pane.focused:
          firstPane = i
          break
      var labels: seq[string]
      for i, pane in panes:
        if i != firstPane:
          labels.add pane.title
      if labels.len > 0:
        denseHeader = " | hidden: " & labels.join(" ")
    for slot in 0 ..< paneCount:
      let i = firstPane + slot
      let pane = panes[i]
      let paneOutput = pane.output
      let paneTop = (outputRows * slot) div paneCount
      let paneBottom = (outputRows * (slot + 1)) div paneCount
      let paneHeight = paneBottom - paneTop
      if paneHeight <= 0:
        continue
      let bodyHeight = max(0, paneHeight - 1)
      let terminal =
        if pane.terminalId > 0 and terminalSessions.hasKey(pane.terminalId):
          terminalSessions[pane.terminalId]
        else:
          nil
      var rows: seq[CursesTranscriptRow]
      let effectiveScroll =
        if terminal != nil:
          min(max(0, pane.scroll), terminalMaxScroll(terminal, bodyHeight))
        else:
          rows = cachedTranscriptRows(cursesPaneTranscriptCaches[i],
                                      paneOutput, paneWidth)
          min(max(0, pane.scroll), max(0, rows.len - bodyHeight))
      let paneTitle =
        if effectiveScroll > 0:
          pane.title & " [SCROLL +" & $effectiveScroll & "]" & denseHeader
        else:
          pane.title & denseHeader
      discard cMove(paneTop.cint, divider.cint)
      withCursesColor(PairSeparator,
        proc() =
          addCursesText(if i == 0: "│" else: "├", 1)
          let prefix = if i == 0: " " else: "─ "
          addCursesText(prefix & paneTitle, paneWidth))
      if bodyHeight > 0:
        if terminal != nil:
          if pane.focused:
            cursesFocusedTerminalRect =
              (valid: true, top: paneTop + 1, left: divider + 1,
               height: bodyHeight, width: paneWidth)
          let cursor = drawCursesTerminal(
            terminal, paneTop + 1, divider + 1, bodyHeight, paneWidth,
            effectiveScroll)
          if pane.focused and cursor.cursorVisible:
            result = cursor
        else:
          let first = max(0, rows.len - bodyHeight - effectiveScroll)
          for bodyRow in 0 ..< bodyHeight:
            let idx = first + bodyRow
            if idx < rows.len:
              discard cMove((paneTop + 1 + bodyRow).cint,
                            (divider + 1).cint)
              withCursesColor(rows[idx].pair,
                proc() = addCursesText(rows[idx].text, paneWidth))

  proc drawCursesInput(prompt, status, output, input: string, cursor: int,
                       outputScroll = 0,
                       panes: openArray[CursesPane] = [],
                       terminalDirect = false,
                       overlay: openArray[string] = [],
                       overlaySelected = 0, overlayTitle = "") =
    # wclear also sets clearok, forcing ncurses to clear and repaint the
    # physical terminal on every keypress. Erase only the virtual window so
    # refresh can emit the small cell diff and avoid visible flashing.
    discard werase(stdscr)
    let height = max(1, int(LINES))
    let width = max(1, int(COLS))
    cursesFocusedTerminalRect.valid = false
    if height < 4:
      discard cMove(0, 0)
      let lines = splitCursesLines(input)
      let line =
        if lines.len == 0: ""
        else: lines[min(lines.high, cursorRowCol(input, cursor).row)]
      withCursesColor(PairInput,
        proc() =
          addCursesText(line, width))
      discard clrtoeol()
      discard cMove(0, min(width - 1, cursorRowCol(input, cursor).col).cint)
      discard refresh()
      return

    let pos = cursorRowCol(input, cursor)
    let inputLines = splitCursesLines(input)
    let inputTotal = max(1, inputLines.len)
    let maxInputRows = max(1, height - 3)
    let inputRows = min(inputTotal, maxInputRows)
    let cursorLine = min(pos.row, inputTotal - 1)
    let firstInputLine = min(max(0, cursorLine - inputRows + 1),
                             max(0, inputTotal - inputRows))
    let statusRow = height - 1
    let bottomSepRow = statusRow - 1
    let inputTop = bottomSepRow - inputRows
    let topSepRow = inputTop - 1
    let outputRows = max(0, topSepRow)

    var fullPane = -1
    for i, pane in panes:
      if pane.maximized:
        fullPane = i
        break
    if fullPane < 0 and width < 48:
      for i, pane in panes:
        if pane.focused:
          fullPane = i
          break
    let mainOutputWidth =
      if fullPane >= 0: width
      else: cursesMainOutputWidth(width, panes.len)
    var terminalCursor:
      tuple[cursorVisible: bool, cursorRow, cursorCol: int]
    var effectiveScroll = 0
    let fullTerminal =
      if fullPane >= 0 and panes[fullPane].terminalId > 0 and
          terminalSessions.hasKey(panes[fullPane].terminalId):
        terminalSessions[panes[fullPane].terminalId]
      else:
        nil
    if fullTerminal != nil:
      cursesFocusedTerminalRect =
        (valid: true, top: 0, left: 0,
         height: outputRows, width: mainOutputWidth)
      effectiveScroll = min(max(0, panes[fullPane].scroll),
                            terminalMaxScroll(fullTerminal, outputRows))
      terminalCursor = drawCursesTerminal(
        fullTerminal, 0, 0, outputRows, mainOutputWidth, effectiveScroll)
    else:
      let visibleOutput =
        if fullPane >= 0: panes[fullPane].output
        else: output
      let requestedScroll =
        if fullPane >= 0: panes[fullPane].scroll
        else: outputScroll
      let outputLines = cachedTranscriptRows(cursesMainTranscriptCache,
                                             visibleOutput, mainOutputWidth)
      effectiveScroll = min(max(0, requestedScroll),
                            max(0, outputLines.len - outputRows))
      drawCursesTranscript(outputLines, 0, 0, outputRows, mainOutputWidth,
                           effectiveScroll)
    if fullPane < 0:
      terminalCursor = drawCursesPanes(panes, outputRows, width)

    # One transient list primitive backs completion, reverse search, and the
    # command palette. It is drawn last over the bottom of the output region,
    # bounded by available rows and terminal cell width.
    if overlay.len > 0 and outputRows > 0:
      let titleRows = if overlayTitle.len > 0: 1 else: 0
      let shown = min(overlay.len, max(1, outputRows - titleRows))
      let overlayRows = min(outputRows, shown + titleRows)
      let first = max(0, min(overlaySelected, overlay.len - 1) - shown + 1)
      let top = outputRows - overlayRows
      if titleRows > 0:
        discard cMove(top.cint, 0)
        withCursesColor(PairSeparator,
          proc() = addCursesText("─ " & overlayTitle, width))
        discard clrtoeol()
      for row in 0 ..< shown:
        let index = first + row
        let overlayText =
          (if index == overlaySelected: "› " else: "  ") & overlay[index]
        discard cMove((top + titleRows + row).cint, 0)
        withCursesColor(if index == overlaySelected: PairInput else: PairStatus,
          proc() = addCursesText(overlayText, width))
        discard clrtoeol()

    drawSeparator(topSepRow, width)
    for row in 0 ..< inputRows:
      discard cMove((inputTop + row).cint, 0)
      let idx = firstInputLine + row
      if idx < inputLines.len:
        withCursesColor(PairInput,
          proc() =
            addCursesText(inputLines[idx], width))
      else:
        discard
      discard clrtoeol()
    drawSeparator(bottomSepRow, width)
    discard cMove(statusRow.cint, 0)
    let visibleStatus =
      if effectiveScroll > 0:
        "[SCROLL +" & $effectiveScroll & "] " & status
      else:
        status
    withCursesColor(PairStatus,
      proc() =
        addCursesText(visibleStatus, width))
    discard clrtoeol()

    if terminalDirect:
      if terminalCursor.cursorVisible:
        discard curs_set(1)
        discard cMove(terminalCursor.cursorRow.cint,
                      terminalCursor.cursorCol.cint)
      else:
        discard curs_set(0)
    else:
      discard curs_set(1)
      let cursorVisibleRow = cursorLine - firstInputLine
      let y = min(bottomSepRow - 1, inputTop + max(0, cursorVisibleRow))
      let x = min(width - 1, pos.col)
      discard cMove(y.cint, x.cint)
    discard refresh()

  proc defaultInputStatus(multiline: bool): string =
    if multiline:
      "↑/↓ history | Mouse wheel or PgUp/PgDn scroll | Enter sends | Paste/Shift+Enter keeps newlines | Ctrl-C clears | Ctrl-D cancels"
    else:
      "↑/↓ history | Mouse wheel or PgUp/PgDn scroll | Enter sends | Ctrl-C clears | Ctrl-D cancels"

  proc isEscFinalByte(ch: char): bool =
    let code = ch.ord
    code >= 0x40 and code <= 0x7E

  proc readEscSequence(): string =
    timeout(60)
    try:
      let first = getch()
      if first == CursesErr:
        return
      if first < 0 or first > 255:
        return
      result.add char(first)
      if result[0] == '[' or result[0] == 'O':
        while true:
          let ch = getch()
          if ch == CursesErr:
            break
          if ch < 0 or ch > 255:
            break
          let c = char(ch)
          result.add c
          if isEscFinalByte(c):
            break
    finally:
      timeout(-1)

  proc isShiftEnterSequence(seq: string): bool =
    seq == "\n" or seq == "\r" or seq == "[13;2u" or seq == "[13;2~" or
      seq == "[27;2;13~"

  proc isPasteStartSequence(seq: string): bool =
    seq == "[200~"

  proc isPasteEndSequence(seq: string): bool =
    seq == "[201~"

  proc navigationKeyFromEsc(seq: string): cint =
    ## Some terminals deliver navigation keys as raw CSI/SS3 sequences even
    ## with keypad mode enabled. Normalize those sequences to ncurses keys so
    ## the editor has one set of navigation semantics.
    case seq
    of "[A", "OA": KeyUp
    of "[B", "OB": KeyDown
    of "[5~": KeyPageUp
    of "[6~": KeyPageDown
    of "[5;2~": KeyShiftPageUp
    of "[6;2~": KeyShiftPageDown
    of "[5;5~": KeyCtrlPageUp
    of "[6;5~": KeyCtrlPageDown
    else: CursesErr

  proc mouseScrollFromEsc(seq: string): int =
    ## SGR mouse reports use button 64/65 for wheel up/down. This path is used
    ## where ncurses' mouse protocol cannot represent the fifth button.
    tui_terminal.mouseScrollFromEscape(seq)

  proc cursesEscapePressed(): bool =
    ## Scan currently queued input for a standalone Escape without stealing
    ## ordinary typing. Escape-prefixed terminal sequences (mouse, navigation,
    ## Alt-key input) have another byte within the short disambiguation window
    ## and are restored intact for the editor.
    var buffered: seq[cint]
    # Disable keypad decoding while polling so ncurses does not hold a lone
    # Escape for its much longer built-in sequence timeout. Restored bytes are
    # decoded normally when the editor later reads them with keypad enabled.
    discard keypad(stdscr, 0)
    timeout(0)
    try:
      while buffered.len < 256:
        let ch = getch()
        if ch == CursesErr:
          break
        if ch == KeyEsc:
          timeout(25)
          let next = getch()
          timeout(0)
          if next == CursesErr:
            return true
          buffered.add ch
          buffered.add next
        else:
          buffered.add ch
    finally:
      if buffered.len > 0:
        for i in countdown(buffered.high, 0):
          discard ungetch(buffered[i])
      timeout(-1)
      discard keypad(stdscr, 1)

  proc insertTextAt(input: var string, cursor: var int, text: string) =
    if text.len == 0:
      return
    input.insert(text, cursor)
    inc cursor, text.len

  proc insertCharAt(input: var string, cursor: var int, ch: char) =
    input.insert($ch, cursor)
    inc cursor

  proc browseInputHistory(history: openArray[string], direction: int,
                          historyIndex: var int, draft, input: var string,
                          cursor: var int): bool =
    if direction < 0 and historyIndex > 0:
      if historyIndex == history.len:
        draft = input
      dec historyIndex
      input = history[historyIndex]
    elif direction > 0 and historyIndex < history.len:
      inc historyIndex
      input =
        if historyIndex == history.len: draft
        else: history[historyIndex]
    else:
      return false
    cursor = input.len
    true

  proc readCursesInput(prompt, status, output: string,
                       multiline, persistent: bool,
                       history: openArray[string],
                       panes: openArray[CursesPane]): Value =
    openCursesInput()
    try:
      let statusText =
        if status.len > 0: status
        else: defaultInputStatus(multiline)
      var input = ""
      var cursor = 0
      var pasteMode = false
      var outputScroll = 0
      var historyIndex = history.len
      var draft = ""
      while true:
        drawCursesInput(prompt, statusText, output, input, cursor, outputScroll,
                        panes)
        let ch = getch()
        if pasteMode:
          if ch == KeyEsc:
            let seq = readEscSequence()
            if isPasteEndSequence(seq):
              pasteMode = false
            else:
              insertCharAt(input, cursor, char(KeyEsc))
              insertTextAt(input, cursor, seq)
          elif ch == KeyReturn or ch == KeyEnter or ch == KeyNcursesEnter:
            insertCharAt(input, cursor, '\n')
          elif ch >= 0 and ch <= 255:
            insertCharAt(input, cursor, char(ch))
          else:
            discard
        else:
          case ch
          of KeyCtrlC:
            input.setLen(0)
            cursor = 0
            historyIndex = history.len
            draft.setLen(0)
          of KeyCtrlD:
            return NIL
          of KeyEnter, KeyReturn, KeyNcursesEnter:
            return newStr(input)
          of KeyResize:
            outputScroll = min(outputScroll,
              maxCursesOutputScroll(output, input, max(1, int(LINES)),
                                    max(1, int(COLS)), panes.len))
          of KeyMouse:
            let direction = tui_terminal.takeMouseScroll()
            if direction > 0:
              outputScroll = min(
                maxCursesOutputScroll(output, input, max(1, int(LINES)),
                                      max(1, int(COLS)), panes.len),
                outputScroll + 3)
            elif direction < 0:
              outputScroll = max(0, outputScroll - 3)
          of KeyPageUp:
            let page = max(1,
              cursesOutputRows(input, max(1, int(LINES))) - 1)
            outputScroll = min(
              maxCursesOutputScroll(output, input, max(1, int(LINES)),
                                    max(1, int(COLS)), panes.len),
              outputScroll + page)
          of KeyPageDown:
            let page = max(1,
              cursesOutputRows(input, max(1, int(LINES))) - 1)
            outputScroll = max(0, outputScroll - page)
          of KeyUp:
            if not browseInputHistory(history, -1, historyIndex, draft,
                                      input, cursor):
              discard beep()
          of KeyDown:
            if not browseInputHistory(history, 1, historyIndex, draft,
                                      input, cursor):
              discard beep()
          of KeyBackspace, 127, 8:
            if cursor > 0:
              input.delete(cursor - 1 .. cursor - 1)
              dec cursor
            else:
              discard beep()
          of KeyDelete:
            if cursor < input.len:
              input.delete(cursor .. cursor)
            else:
              discard beep()
          of KeyLeft:
            if cursor > 0: dec cursor else: discard beep()
          of KeyRight:
            if cursor < input.len: inc cursor else: discard beep()
          of KeyHome:
            cursor = lineStart(input, cursor)
          of KeyEnd:
            let nl = input.find('\n', cursor)
            cursor = if nl >= 0: nl else: input.len
          of KeyEsc:
            let seq = readEscSequence()
            let mouseDirection = mouseScrollFromEsc(seq)
            let navigationKey = navigationKeyFromEsc(seq)
            if seq.len == 1 and seq[0] notin {'[', 'O'}:
              # A scheduler-delayed standalone Escape can be dequeued only
              # after ordinary typing has arrived. Do not consume that first
              # byte as an unsupported Alt sequence.
              discard ungetch(cint(seq[0].ord))
              discard beep()
            elif mouseDirection > 0:
              outputScroll = min(
                maxCursesOutputScroll(output, input, max(1, int(LINES)),
                                      max(1, int(COLS)), panes.len),
                outputScroll + 3)
            elif mouseDirection < 0:
              outputScroll = max(0, outputScroll - 3)
            elif navigationKey == KeyPageUp:
              let page = max(1,
                cursesOutputRows(input, max(1, int(LINES))) - 1)
              outputScroll = min(
                maxCursesOutputScroll(output, input, max(1, int(LINES)),
                                      max(1, int(COLS)), panes.len),
                outputScroll + page)
            elif navigationKey == KeyPageDown:
              let page = max(1,
                cursesOutputRows(input, max(1, int(LINES))) - 1)
              outputScroll = max(0, outputScroll - page)
            elif navigationKey == KeyUp:
              if not browseInputHistory(history, -1, historyIndex, draft,
                                        input, cursor):
                discard beep()
            elif navigationKey == KeyDown:
              if not browseInputHistory(history, 1, historyIndex, draft,
                                        input, cursor):
                discard beep()
            elif isPasteStartSequence(seq):
              pasteMode = true
            elif multiline and isShiftEnterSequence(seq):
              insertCharAt(input, cursor, '\n')
            else:
              discard beep()
          else:
            if ch >= 32 and ch <= 255:
              insertCharAt(input, cursor, char(ch))
            else:
              discard beep()
    finally:
      if not persistent:
        closeCursesInput()

proc parseCursesPanes(name: string, value: Value): seq[CursesPane] =
  requireList(name & " ^panes", value)
  for item in value.listItems:
    requirePropMap(name & " ^panes item", item)
    let title = item.mapEntries.getOrDefault("title", VOID)
    let output = item.mapEntries.getOrDefault("output", VOID)
    let scrollValue = item.mapEntries.getOrDefault("scroll", VOID)
    let focusedValue = item.mapEntries.getOrDefault("focused", VOID)
    let maximizedValue = item.mapEntries.getOrDefault("maximized", VOID)
    let terminalIdValue = item.mapEntries.getOrDefault("terminal_id", VOID)
    requireStr(name & " ^panes item ^title", title)
    requireStr(name & " ^panes item ^output", output)
    let scroll =
      if scrollValue.kind == vkVoid: 0
      else: int(requireInt64(name & " ^panes item ^scroll", scrollValue))
    if scroll < 0:
      raise newException(GeneError,
        name & " ^panes item ^scroll must be non-negative")
    if focusedValue.kind notin {vkVoid, vkBool}:
      raise newException(GeneError,
        name & " ^panes item ^focused must be Bool")
    if maximizedValue.kind notin {vkVoid, vkBool}:
      raise newException(GeneError,
        name & " ^panes item ^maximized must be Bool")
    let terminalId =
      if terminalIdValue.kind == vkVoid: 0
      else: int(requireInt64(name & " ^panes item ^terminal_id",
                             terminalIdValue))
    if terminalId < 0:
      raise newException(GeneError,
        name & " ^panes item ^terminal_id must be non-negative")
    result.add CursesPane(
      title: title.strVal, output: output.strVal, scroll: scroll,
      focused: focusedValue.kind == vkBool and focusedValue.boolVal,
      maximized: maximizedValue.kind == vkBool and maximizedValue.boolVal,
      terminalId: terminalId)

proc readInputNative(name: string, call: ptr NativeCall,
                     persistentDefault, persistentFixed: bool): Value =
  var prompt = ""
  var status = ""
  var output = ""
  var multiline = true
  var persistent = persistentDefault
  var history: seq[string]
  var panes: seq[CursesPane]
  if call != nil:
    for i, argName in call[].namedNames:
      let v = call[].namedValues[i]
      case argName
      of "prompt":
        requireStr(name & " ^prompt", v)
        prompt = v.strVal
      of "status":
        requireStr(name & " ^status", v)
        status = v.strVal
      of "output":
        requireStr(name & " ^output", v)
        output = v.strVal
      of "multiline":
        if v.kind != vkBool:
          raise newException(GeneError, name & " ^multiline must be Bool")
        multiline = v.boolVal
      of "history":
        requireList(name & " ^history", v)
        for item in v.listItems:
          requireStr(name & " ^history item", item)
          history.add item.strVal
      of "panes":
        panes = parseCursesPanes(name, v)
      of "persistent":
        if persistentFixed:
          raise newException(GeneError,
            name & " owns its Screen and does not accept ^persistent")
        if v.kind != vkBool:
          raise newException(GeneError, name & " ^persistent must be Bool")
        persistent = v.boolVal
      else:
        raise newException(GeneError,
          name & " got unexpected named argument: " & argName)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if isatty(STDIN_FILENO) != 0:
      return readCursesInput(prompt, status, output, multiline, persistent,
                             history, panes)
  if prompt.len > 0:
    stdout.write(prompt)
    stdout.flushFile()
  biOsReadLine([])

proc biOsReadInput(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Compatibility wrapper for the public curses/read_input editor.
  if args.len != 0:
    raise newException(GeneError, "os/read_input expects named arguments only")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if cursesScreenActiveId != 0:
      raise newException(GeneError,
        "os/read_input cannot borrow an owned curses/Screen")
  readInputNative("os/read_input", call, false, false)

proc refreshInputNative(name: string, call: ptr NativeCall): Value =
  var prompt = ""
  var status = ""
  var output = ""
  var panes: seq[CursesPane]
  if call != nil:
    for i, argName in call[].namedNames:
      let v = call[].namedValues[i]
      case argName
      of "prompt":
        requireStr(name & " ^prompt", v)
        prompt = v.strVal
      of "status":
        requireStr(name & " ^status", v)
        status = v.strVal
      of "output":
        requireStr(name & " ^output", v)
        output = v.strVal
      of "panes":
        panes = parseCursesPanes(name, v)
      else:
        raise newException(GeneError,
          name & " got unexpected named argument: " & argName)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if isatty(STDIN_FILENO) != 0:
      openCursesInput()
      let statusText =
        if status.len > 0: status
        else: defaultInputStatus(true)
      drawCursesInput(prompt, statusText, output, "", 0, panes = panes)
  NIL

proc biOsRefreshInput(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Compatibility wrapper for curses/refresh_input.
  if args.len != 0:
    raise newException(GeneError, "os/refresh_input expects named arguments only")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if cursesScreenActiveId != 0:
      raise newException(GeneError,
        "os/refresh_input cannot borrow an owned curses/Screen")
  refreshInputNative("os/refresh_input", call)

proc biOsCloseInput(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/close_input takes no arguments")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if cursesScreenActiveId != 0:
      raise newException(GeneError,
        "os/close_input cannot close an owned curses/Screen")
    closeCursesInput()
  NIL

# --- curses: public owned terminal surface ----------------------------------

proc raiseCursesError(message: string, scope: Scope) =
  var props = initPropTable()
  props["message"] = newStr(message)
  var error: ref GeneError
  new(error)
  error.msg = message
  error.errVal = newNode(builtInTypeHead(scope, "CursesError"), props = props)
  error.hasErrVal = true
  raise error

proc cursesScreenId(name: string, screen: Value, scope: Scope,
                    requireOpen = true): int =
  if not nativeReceiverIs(scope, screen, "CursesScreen"):
    raiseCursesError(name & " expects a curses/Screen", scope)
  let id = screen.props.getOrDefault("id", VOID)
  let closed = screen.props.getOrDefault("closed", VOID)
  if id.kind != vkInt or closed.kind != vkCell:
    raiseCursesError(name & " received an invalid curses/Screen", scope)
  if requireOpen and closed.cellValue.isTruthy:
    raiseCursesError(name & ": Screen is closed", scope)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if requireOpen and
        (cursesScreenActiveId != int(id.intVal) or not cursesInputActive):
      raiseCursesError(name & ": Screen does not own the active terminal",
                       scope)
  int(id.intVal)

proc biCursesOpen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 0 or (call != nil and call[].namedNames.len != 0):
    raise newException(GeneError, "curses/open takes no arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if isatty(STDIN_FILENO) == 0:
      raiseCursesError("curses/open requires a TTY", scope)
    if cursesScreenActiveId != 0:
      raiseCursesError("curses/open: a Screen is already open", scope)
    try:
      openCursesInput()
    except GeneError as error:
      raiseCursesError("curses/open: " & error.msg, scope)
    let id = cursesScreenNextId
    inc cursesScreenNextId
    cursesScreenActiveId = id
    newNativeWrapper(builtInTypeHead(scope, "CursesScreen"),
      {"id": newInt(id), "closed": newCell(FALSE)})
  else:
    raiseCursesError("curses is unavailable on this platform", scope)
    NIL

proc biCursesClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("curses/close", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  let id = cursesScreenId("curses/close", args[0], scope, requireOpen = false)
  let closed = args[0].props["closed"]
  if closed.cellValue.isTruthy:
    return NIL
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if cursesScreenActiveId != id:
      raiseCursesError("curses/close: Screen does not own the active terminal",
                       scope)
    closeCursesInput()
    cursesScreenActiveId = 0
    cursesEventText.setLen(0)
    cursesEventTextExpected = 0
  closed.setCellValue(TRUE)
  NIL

proc biCursesDimensions(args: openArray[Value],
                        call: ptr NativeCall): Value {.nimcall.} =
  requireOne("curses/dimensions", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  discard cursesScreenId("curses/dimensions", args[0], scope)
  var props = initPropTable()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    props["rows"] = newInt(max(1, int(LINES)))
    props["cols"] = newInt(max(1, int(COLS)))
  else:
    props["rows"] = newInt(0)
    props["cols"] = newInt(0)
  newMap(props)

proc biCursesDraw(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("curses/draw", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  discard cursesScreenId("curses/draw", args[0], scope)
  var prompt = ""
  var status = ""
  var output = ""
  var input = ""
  var cursor = -1
  var outputScroll = 0
  var panes: seq[CursesPane]
  var terminalDirect = false
  var overlay: seq[string]
  var overlaySelected = 0
  var overlayTitle = ""
  if call != nil:
    for i, name in call[].namedNames:
      let value = call[].namedValues[i]
      case name
      of "prompt":
        requireStr("curses/draw ^prompt", value)
        prompt = value.strVal
      of "status":
        requireStr("curses/draw ^status", value)
        status = value.strVal
      of "output":
        requireStr("curses/draw ^output", value)
        output = value.strVal
      of "input":
        requireStr("curses/draw ^input", value)
        input = value.strVal
      of "cursor":
        cursor = int(requireInt64("curses/draw ^cursor", value))
      of "output_scroll":
        outputScroll = int(requireInt64("curses/draw ^output_scroll", value))
        if outputScroll < 0:
          raiseCursesError("curses/draw ^output_scroll must be non-negative",
                           scope)
      of "panes":
        panes = parseCursesPanes("curses/draw", value)
      of "terminal_direct":
        if value.kind != vkBool:
          raiseCursesError("curses/draw ^terminal_direct must be Bool", scope)
        terminalDirect = value.boolVal
      of "overlay":
        requireList("curses/draw ^overlay", value)
        for item in value.listItems:
          requireStr("curses/draw ^overlay item", item)
          overlay.add item.strVal
      of "overlay_selected":
        overlaySelected = int(requireInt64(
          "curses/draw ^overlay_selected", value))
        if overlaySelected < 0:
          raiseCursesError(
            "curses/draw ^overlay_selected must be non-negative", scope)
      of "overlay_title":
        requireStr("curses/draw ^overlay_title", value)
        overlayTitle = value.strVal
      else:
        raiseCursesError("curses/draw got unexpected named argument: " & name,
                         scope)
  if cursor < 0:
    cursor = input.len
  cursor = min(cursor, input.len)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    drawCursesInput(prompt, status, output, input, cursor, outputScroll,
                    panes, terminalDirect, overlay, overlaySelected,
                    overlayTitle)
  NIL

proc biCursesReadInput(args: openArray[Value],
                       call: ptr NativeCall): Value {.nimcall.} =
  requireOne("curses/read_input", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  discard cursesScreenId("curses/read_input", args[0], scope)
  readInputNative("curses/read_input", call, true, true)

proc biCursesRefreshInput(args: openArray[Value],
                          call: ptr NativeCall): Value {.nimcall.} =
  requireOne("curses/refresh_input", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  discard cursesScreenId("curses/refresh_input", args[0], scope)
  refreshInputNative("curses/refresh_input", call)

proc biCursesEscapePressed(args: openArray[Value],
                           call: ptr NativeCall): Value {.nimcall.} =
  requireOne("curses/escape_pressed?", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  discard cursesScreenId("curses/escape_pressed?", args[0], scope)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    newBool(cursesEscapePressed())
  else:
    FALSE

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  type CursesEventPending {.acyclic.} = ref object
    taskOwner: Value
    screenOwner: Value
    schedulerPtr: pointer
    screenId: int

  var cursesEventPending: seq[CursesEventPending]

  proc cursesMouseEvent(mouse: tui_terminal.TuiMouseEvent): Value =
    var props = initPropTable()
    props["code"] = newInt(KeyMouse)
    props["rows"] = newInt(max(1, int(LINES)))
    props["cols"] = newInt(max(1, int(COLS)))
    props["type"] = newStr(
      if mouse.direction > 0: "scroll_up"
      elif mouse.direction < 0: "scroll_down"
      else: "mouse")
    let rect = cursesFocusedTerminalRect
    let inside = rect.valid and mouse.row >= rect.top and
      mouse.row < rect.top + rect.height and mouse.col >= rect.left and
      mouse.col < rect.left + rect.width
    props["inside_terminal"] = newBool(inside)
    props["row"] = newInt(if inside: mouse.row - rect.top else: mouse.row)
    props["col"] = newInt(if inside: mouse.col - rect.left else: mouse.col)
    props["direction"] = newInt(mouse.direction)
    props["shift"] = newBool(mouse.shift)
    props["alt"] = newBool(mouse.alt)
    props["ctrl"] = newBool(mouse.ctrl)
    newMap(props)

  proc cursesEvent(ch: int, text = ""): Value =
    var props = initPropTable()
    props["code"] = newInt(ch)
    props["rows"] = newInt(max(1, int(LINES)))
    props["cols"] = newInt(max(1, int(COLS)))
    if text.len > 0:
      props["type"] = newStr("text")
      props["text"] = newStr(text)
      return newMap(props)
    case ch
    of KeyResize: props["type"] = newStr("resize")
    of KeyCtrlC: props["type"] = newStr("interrupt")
    of KeyCtrlD: props["type"] = newStr("eof")
    of KeyCtrlE: props["type"] = newStr("edit")
    of KeyCtrlR: props["type"] = newStr("reverse_search")
    of KeyTab: props["type"] = newStr("complete")
    of KeyEnter, KeyReturn, KeyNcursesEnter: props["type"] = newStr("enter")
    of KeyBackspace, 127, 8: props["type"] = newStr("backspace")
    of KeyDelete: props["type"] = newStr("delete")
    of KeyLeft: props["type"] = newStr("left")
    of KeyRight: props["type"] = newStr("right")
    of KeyUp: props["type"] = newStr("up")
    of KeyDown: props["type"] = newStr("down")
    of KeyPageUp: props["type"] = newStr("page_up")
    of KeyPageDown: props["type"] = newStr("page_down")
    of KeyShiftPageUp: props["type"] = newStr("scroll_page_up")
    of KeyShiftPageDown: props["type"] = newStr("scroll_page_down")
    of KeyCtrlPageUp, KeyCtrlPageUpNcurses:
      props["type"] = newStr("pane_previous")
    of KeyCtrlPageDown, KeyCtrlPageDownNcurses:
      props["type"] = newStr("pane_next")
    of KeyHome: props["type"] = newStr("home")
    of KeyEnd: props["type"] = newStr("end")
    of KeyMouse:
      return cursesMouseEvent(tui_terminal.takeMouseEvent())
    of KeyEsc: props["type"] = newStr("escape")
    else:
      if ch >= KeyF1 and ch <= KeyF12:
        props["type"] = newStr("function")
        props["key"] = newStr("f" & $(ch - KeyF1 + 1))
      elif ch >= 0 and ch <= 255:
        props["type"] = newStr("text")
        props["text"] = newStr($char(ch))
      else:
        props["type"] = newStr("unknown")
    newMap(props)

  proc cursesEscapeEvent(seq: string): Value =
    let mouse = tui_terminal.mouseEventFromEscape(seq)
    let mouseDirection = mouse.direction
    let navigationKey = navigationKeyFromEsc(seq)
    if mouseDirection > 0:
      return cursesMouseEvent(mouse)
    if mouseDirection < 0:
      return cursesMouseEvent(mouse)
    if navigationKey != CursesErr:
      return cursesEvent(navigationKey)
    var props = initPropTable()
    props["code"] = newInt(KeyEsc)
    props["rows"] = newInt(max(1, int(LINES)))
    props["cols"] = newInt(max(1, int(COLS)))
    if seq == "[I":
      props["type"] = newStr("focus_in")
    elif seq == "[O":
      props["type"] = newStr("focus_out")
    elif isPasteStartSequence(seq):
      props["type"] = newStr("paste_start")
    elif isPasteEndSequence(seq):
      props["type"] = newStr("paste_end")
    elif isShiftEnterSequence(seq):
      props["type"] = newStr("newline")
    elif seq.len == 0:
      props["type"] = newStr("escape")
    else:
      props["type"] = newStr("escape_sequence")
      props["sequence"] = newStr(seq)
    newMap(props)

  proc pollCursesInputCompletions() =
    pollTerminalUpdateCompletions()
    if cursesEventPending.len == 0:
      return
    var i = 0
    while i < cursesEventPending.len:
      let pending {.cursor.} = cursesEventPending[i]
      let task = pending.taskOwner
      var remove = false
      var consumedInput = false
      if task.taskCancelled:
        remove = true
      elif cursesScreenActiveId != pending.screenId or not cursesInputActive:
        if tryFailTask(task, "curses/next_event: Screen is closed"):
          wakeTaskWaitersIn(cast[SchedulerState](pending.schedulerPtr), task)
        remove = true
      else:
        timeout(0)
        let ch = getch()
        timeout(-1)
        if ch != CursesErr:
          consumedInput = true
          var event = NIL
          if ch == KeyEsc:
            cursesEventText.setLen(0)
            cursesEventTextExpected = 0
            let seq = readEscSequence()
            if seq.len == 1 and seq[0] notin {'[', 'O'}:
              # Preserve typing that arrived after a standalone Escape but
              # before this scheduler poll. The next pending read receives
              # the pushed-back byte.
              discard ungetch(cint(seq[0].ord))
              event = cursesEscapeEvent("")
            else:
              event = cursesEscapeEvent(seq)
          elif ch == KeyCtrlC or ch == KeyCtrlD or ch == KeyCtrlE or
               ch == KeyCtrlR or ch == KeyTab or ch == KeyEnter or
               ch == KeyReturn or ch == KeyNcursesEnter or
               ch == KeyBackspace or ch == 127 or ch == 8:
            cursesEventText.setLen(0)
            cursesEventTextExpected = 0
            event = cursesEvent(ch)
          elif ch >= 0 and ch <= 255:
            let byte = char(ch)
            if cursesEventText.len > 0:
              cursesEventText.add byte
              if cursesEventText.len >= cursesEventTextExpected:
                event = cursesEvent(ch, cursesEventText)
                cursesEventText.setLen(0)
                cursesEventTextExpected = 0
            else:
              let expected =
                if ch < 0x80: 1
                elif ch < 0xE0: 2
                elif ch < 0xF0: 3
                else: 4
              if expected == 1:
                event = cursesEvent(ch, $byte)
              else:
                cursesEventText = $byte
                cursesEventTextExpected = expected
          else:
            cursesEventText.setLen(0)
            cursesEventTextExpected = 0
            event = cursesEvent(ch)
          if event.kind != vkNil:
            if tryCompleteTask(task, event):
              wakeTaskWaitersIn(cast[SchedulerState](pending.schedulerPtr), task)
            remove = true
      if remove:
        endExternalNativeOp()
        cursesEventPending.delete(i)
      else:
        inc i
      # Preserve request ordering and keep a partial UTF-8 sequence attached
      # to the oldest pending reader.
      if consumedInput:
        return

  proc biCursesNextEvent(args: openArray[Value],
                         call: ptr NativeCall): Value {.nimcall.} =
    requireOne("curses/next_event", args)
    let scope = if call == nil: nil else: call[].dispatchScope
    let id = cursesScreenId("curses/next_event", args[0], scope)
    if scope == nil or scope.application == nil:
      raiseCursesError("curses/next_event requires a scheduler scope", scope)
    let task = newExternalTask()
    let pending = CursesEventPending(screenId: id)
    pending.taskOwner = retainedCopy(task)
    pending.screenOwner = retainedCopy(args[0])
    pending.schedulerPtr = cast[pointer](schedulerForScope(scope))
    cursesEventPending.add pending
    beginExternalNativeOp()
    # getch() may have pulled a whole terminal burst into ncurses' private
    # queue while completing the preceding one-event task. In that case the
    # OS fd is no longer readable, so waiting for another scheduler I/O tick
    # would strand the buffered suffix until the user typed again. Probe the
    # queue as each successor task is registered; a ready task is safe to
    # await, and an empty queue remains registered for normal polling.
    pollCursesInputCompletions()
    task
else:
  proc pollCursesInputCompletions() =
    discard

  proc biCursesNextEvent(args: openArray[Value],
                         call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    raiseCursesError("curses/next_event is unavailable on this platform", scope)
    NIL
