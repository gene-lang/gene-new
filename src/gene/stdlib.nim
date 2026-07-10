## Gene standard library surface (docs/stdlib.md).
##
## This file is `include`d by vm.nim after the core native helpers are
## defined: the stdlib natives use the VM's require*/applyCall/raise* helpers
## and the socket imports from vm.nim's prelude. Everything user-facing here
## is registered by `registerStdlibNamespaces`, which buildBuiltins calls on
## the built-ins root scope; nothing in this file touches VM dispatch state.

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  {.passL: "-lncurses".}

  type CursesWindow = pointer

  proc cInitscr(): CursesWindow {.importc: "initscr", header: "<ncurses.h>".}
  proc cEndwin(): cint {.importc: "endwin", header: "<ncurses.h>".}
  proc cbreak(): cint {.importc, header: "<ncurses.h>".}
  proc nocbreak(): cint {.importc, header: "<ncurses.h>".}
  proc noecho(): cint {.importc, header: "<ncurses.h>".}
  proc cEcho(): cint {.importc: "echo", header: "<ncurses.h>".}
  proc noraw(): cint {.importc, header: "<ncurses.h>".}
  proc keypad(win: CursesWindow, bf: cint): cint {.importc, header: "<ncurses.h>".}
  proc curs_set(visibility: cint): cint {.importc, header: "<ncurses.h>".}
  proc reset_shell_mode(): cint {.importc, header: "<ncurses.h>".}
  proc wclear(win: CursesWindow): cint {.importc, header: "<ncurses.h>".}
  proc refresh(): cint {.importc, header: "<ncurses.h>".}
  proc cMove(y, x: cint): cint {.importc: "move", header: "<ncurses.h>".}
  proc clrtoeol(): cint {.importc, header: "<ncurses.h>".}
  proc addnstr(s: cstring, n: cint): cint {.importc, header: "<ncurses.h>".}
  proc getch(): cint {.importc, header: "<ncurses.h>".}
  proc beep(): cint {.importc, header: "<ncurses.h>".}
  proc timeout(delay: cint) {.importc, header: "<ncurses.h>".}
  proc start_color(): cint {.importc, header: "<ncurses.h>".}
  proc use_default_colors(): cint {.importc, header: "<ncurses.h>".}
  proc init_pair(pair, fg, bg: cshort): cint {.importc, header: "<ncurses.h>".}
  proc cAttrOn(attrs: cint): cint {.importc: "attron", header: "<ncurses.h>".}
  proc cAttrOff(attrs: cint): cint {.importc: "attroff", header: "<ncurses.h>".}

  {.emit: """
#include <locale.h>
#include <signal.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
static struct termios gene_curses_orig_termios;
static int gene_curses_termios_saved = 0;
static int gene_curses_restore_hooks_installed = 0;
static int gene_curses_color_pair(short pair) { return COLOR_PAIR(pair); }
static void gene_curses_setlocale(void) { setlocale(LC_ALL, ""); }
static void gene_curses_save_termios(void) {
  if (!gene_curses_termios_saved && isatty(STDIN_FILENO)) {
    if (tcgetattr(STDIN_FILENO, &gene_curses_orig_termios) == 0) {
      gene_curses_termios_saved = 1;
    }
  }
}
static void gene_curses_restore_termios(void) {
  struct termios mode;
  if (gene_curses_termios_saved) {
    tcsetattr(STDIN_FILENO, TCSANOW, &gene_curses_orig_termios);
    gene_curses_termios_saved = 0;
  }
  if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &mode) == 0) {
    mode.c_iflag |= ICRNL;
    mode.c_oflag |= OPOST;
#ifdef ONLCR
    mode.c_oflag |= ONLCR;
#endif
    mode.c_lflag |= ICANON | ECHO | ISIG | IEXTEN;
    tcsetattr(STDIN_FILENO, TCSANOW, &mode);
  }
}
static void gene_curses_restore_display(void) {
  if (isatty(STDOUT_FILENO)) {
    /* DECSTBM (\033[r) homes the cursor as a side effect, so wrap it in
       DECSC/DECRC (\0337/\0338); otherwise output after close-input lands at
       the top of the screen and overwrites existing content. */
    const char *seq = "\033[?2004l\033[?1l\033>\033[0m\033[?25h\0337\033[r\0338";
    write(STDOUT_FILENO, seq, sizeof("\033[?2004l\033[?1l\033>\033[0m\033[?25h\0337\033[r\0338") - 1);
  }
}
static void gene_curses_restore_for_exit(void) {
  gene_curses_restore_termios();
  gene_curses_restore_display();
}
static void gene_curses_signal_restore(int sig) {
  gene_curses_restore_for_exit();
  if (isatty(STDOUT_FILENO)) {
    const char nl = '\n';
    write(STDOUT_FILENO, &nl, 1);
  }
  _exit(128 + sig);
}
static void gene_curses_install_restore_hooks(void) {
  if (gene_curses_restore_hooks_installed) return;
  gene_curses_restore_hooks_installed = 1;
  atexit(gene_curses_restore_for_exit);
  signal(SIGINT, gene_curses_signal_restore);
  signal(SIGTERM, gene_curses_signal_restore);
  signal(SIGHUP, gene_curses_signal_restore);
}
""".}
  proc cColorPair(pair: cshort): cint {.importc: "gene_curses_color_pair".}
  proc cSetLocale() {.importc: "gene_curses_setlocale".}
  proc cSaveTermios() {.importc: "gene_curses_save_termios".}
  proc cRestoreTermios() {.importc: "gene_curses_restore_termios".}
  proc cRestoreDisplay() {.importc: "gene_curses_restore_display".}
  proc cInstallRestoreHooks() {.importc: "gene_curses_install_restore_hooks".}

  var stdscr {.importc: "stdscr", header: "<ncurses.h>".}: CursesWindow
  var LINES {.importc: "LINES", header: "<ncurses.h>".}: cint
  var COLS {.importc: "COLS", header: "<ncurses.h>".}: cint

  {.emit: "#undef clear".}

  const
    CursesErr = -1
    KeyCtrlD = 4
    KeyEsc = 27
    KeyEnter = 10
    KeyReturn = 13
    KeyBackspace = 263
    KeyDelete = 330
    KeyLeft = 260
    KeyRight = 261
    KeyHome = 262
    KeyEnd = 360
    KeyNcursesEnter = 343
    KeyShiftEnter = 410
    ColorGreen = 2
    ColorCyan = 6
    ColorWhite = 7
    PairInput = 1
    PairOutput = 2
    PairSeparator = 3
    PairStatus = 4

  var cursesInputActive = false
  var cursesColorsReady = false
  var cursesPasteReady = false

proc biStrJoin(args: openArray[Value]): Value {.nimcall.} =
  if args.len notin 1..2:
    raise newException(GeneError, "str/join expects 1..2 arguments, got " & $args.len)
  if args[0].kind != vkList:
    raise newException(GeneError, "str/join expects a List")
  let sep =
    if args.len == 2:
      requireStr("str/join separator", args[1])
      args[1].strVal
    else:
      ""
  var parts: seq[string]
  for item in args[0].listItems:
    requireStr("str/join item", item)
    parts.add item.strVal
  newStr(parts.join(sep))

proc biStrSplit(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "str/split expects 2 arguments, got " & $args.len)
  requireStr("str/split", args[0])
  requireStr("str/split separator", args[1])
  if args[1].strVal.len == 0:
    raise newException(GeneError, "str/split separator must not be empty")
  var items: seq[Value]
  for part in args[0].strVal.split(args[1].strVal):
    items.add newStr(part)
  newList(items)

proc biStrTrim(args: openArray[Value]): Value {.nimcall.} =
  requireOne("str/trim", args)
  requireStr("str/trim", args[0])
  newStr(args[0].strVal.strip())

proc biStrLower(args: openArray[Value]): Value {.nimcall.} =
  requireOne("str/lower", args)
  requireStr("str/lower", args[0])
  newStr(args[0].strVal.toLowerAscii())

proc biStrStartsWith(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "str/starts_with? expects 2 arguments, got " & $args.len)
  requireStr("str/starts_with?", args[0])
  requireStr("str/starts_with? prefix", args[1])
  if args[0].strVal.startsWith(args[1].strVal): TRUE else: FALSE

proc biStrEndsWith(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "str/ends_with? expects 2 arguments, got " & $args.len)
  requireStr("str/ends_with?", args[0])
  requireStr("str/ends_with? suffix", args[1])
  if args[0].strVal.endsWith(args[1].strVal): TRUE else: FALSE

proc biStrContains(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "str/contains? expects 2 arguments, got " & $args.len)
  requireStr("str/contains?", args[0])
  requireStr("str/contains? needle", args[1])
  if args[0].strVal.contains(args[1].strVal): TRUE else: FALSE

proc biParseInt(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("parse_int", args)
  let scope = if call == nil: nil else: call.dispatchScope
  if args[0].kind != vkString:
    raiseReaderError("parse_int", "expects a Str", "ParseError", scope)
  let s = args[0].strVal.strip()
  try:
    newInt(parseBiggestInt(s))
  except ValueError:
    raiseReaderError("parse_int", "invalid integer: " & args[0].strVal,
                     "ParseError", scope)
    NIL

proc biHtmlEscape(args: openArray[Value]): Value {.nimcall.} =
  requireOne("html/escape", args)
  requireStr("html/escape", args[0])
  var escaped = newStringOfCap(args[0].strVal.len)
  for c in args[0].strVal:
    case c
    of '&': escaped.add "&amp;"
    of '<': escaped.add "&lt;"
    of '>': escaped.add "&gt;"
    of '"': escaped.add "&quot;"
    of '\'': escaped.add "&#39;"
    else: escaped.add c
  newStr(escaped)

const urlUnreserved = {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'}

proc urlEncodeComponent(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c in urlUnreserved:
      result.add c
    else:
      result.add '%'
      result.add toHex(ord(c), 2)

proc raiseUrlError(message: string, scope: Scope) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(builtInTypeHead(scope, "UrlError"), props = props)
  e.hasErrVal = true
  raise e

proc urlDecodeComponent(s: string, plusIsSpace: bool, scope: Scope): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '%':
      if i + 2 > s.high:
        raiseUrlError("url/decode_component: truncated percent escape", scope)
      let hi = s[i + 1]
      let lo = s[i + 2]
      if hi notin HexDigits or lo notin HexDigits:
        raiseUrlError("url/decode_component: invalid percent escape: %" &
                      hi & lo, scope)
      result.add chr(fromHex[int]("" & hi & lo))
      i += 3
    elif plusIsSpace and c == '+':
      result.add ' '
      inc i
    else:
      result.add c
      inc i

proc biUrlEncodeComponent(args: openArray[Value]): Value {.nimcall.} =
  requireOne("url/encode_component", args)
  requireStr("url/encode_component", args[0])
  newStr(urlEncodeComponent(args[0].strVal))

proc biUrlDecodeComponent(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("url/decode_component", args)
  requireStr("url/decode_component", args[0])
  let scope = if call == nil: nil else: call.dispatchScope
  newStr(urlDecodeComponent(args[0].strVal, plusIsSpace = false, scope))

proc parseQueryEntries(query: string,
                       scope: Scope): OrderedTable[string, Value] =
  if query.len == 0:
    return
  for pair in query.split('&'):
    if pair.len == 0:
      continue
    let eq = pair.find('=')
    if eq < 0:
      result[urlDecodeComponent(pair, plusIsSpace = true, scope)] = newStr("")
    else:
      let key = urlDecodeComponent(pair[0 ..< eq], plusIsSpace = true, scope)
      let val = urlDecodeComponent(pair[eq + 1 .. ^1], plusIsSpace = true,
                                   scope)
      result[key] = newStr(val)

proc biUrlParseQuery(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("url/parse_query", args)
  requireStr("url/parse_query", args[0])
  let scope = if call == nil: nil else: call.dispatchScope
  newMap(parseQueryEntries(args[0].strVal, scope))

proc biUrlFormatQuery(args: openArray[Value]): Value {.nimcall.} =
  requireOne("url/format_query", args)
  if args[0].kind != vkMap:
    raise newException(GeneError, "url/format_query expects a Map")
  var parts: seq[string]
  for key, val in args[0].mapEntries:
    requireStr("url/format_query value", val)
    parts.add urlEncodeComponent(key) & "=" & urlEncodeComponent(val.strVal)
  newStr(parts.join("&"))

proc biStreamEach(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "each expects 2 arguments, got " & $args.len)
  requireStream("each", args[0])
  while args[0].streamHasNext:
    var callArgs = [checkedStreamNext(args[0], "each item")]
    discard applyCall(args[1], callArgs, NamedArgs())
  NIL


# net/http server implementation (event loop, dispatch, helpers).
include ./http_server

# --- os: environment, subprocess, and line input (examples/ai_agent/design.md §3,§6) ---
#
# Host authority is capability-gated exactly like Fs/Net: `os/get-env` needs an
# `Os/Env` value and `os/exec`/`os/exec-stdio` need `Os/Exec`, so a launcher can
# hand out env+file access without shell access. Errors are the typed `OsError`.

proc raiseOsError(message: string, scope: Scope) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(builtInTypeHead(scope, "OsError"), props = props)
  e.hasErrVal = true
  raise e

proc requireOsEnv(name: string, value: Value, scope: Scope) =
  if value.kind != vkCapability or value.capabilityName != "Os/Env":
    raiseOsError(name & " expects Os/Env authority", scope)

proc requireOsExec(name: string, value: Value, scope: Scope) =
  if value.kind != vkCapability or value.capabilityName != "Os/Exec":
    raiseOsError(name & " expects Os/Exec authority", scope)

proc biOsGetEnv(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len notin 2..3:
    raise newException(GeneError,
      "os/get-env expects (Os/Env, name) or (Os/Env, name, default), got " &
      $args.len & " arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsEnv("os/get-env", args[0], scope)
  requireStr("os/get-env name", args[1])
  if existsEnv(args[1].strVal):
    newStr(getEnv(args[1].strVal))
  elif args.len == 3:
    args[2]
  else:
    raiseOsError("os/get-env: environment variable not set: " &
                 args[1].strVal, scope)
    NIL

proc biOsEnvOpt(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "os/env? expects (Os/Env, name)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsEnv("os/env?", args[0], scope)
  requireStr("os/env? name", args[1])
  if existsEnv(args[1].strVal): newStr(getEnv(args[1].strVal)) else: NIL

const osExecDefaultOutputCap = 1024 * 1024
const osExecPollMs = 5

proc biOsExec(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Run a subprocess and return {^status ^stdout ^stderr ^timed-out}.
  ## `^cmd` is the program, `^args` a list of Str arguments (no shell parsing
  ## unless the caller passes a shell explicitly), `^timeout-ms` bounds the run,
  ## and captured output is truncated at `^max-bytes`. Never uses a shell to
  ## split the command, so injection through argument values is not possible.
  if args.len != 1:
    raise newException(GeneError,
      "os/exec expects the Os/Exec capability plus named arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsExec("os/exec", args[0], scope)
  var cmd = ""
  var cmdSet = false
  var procArgs: seq[string]
  var timeoutMs = -1
  var maxBytes = osExecDefaultOutputCap
  var workdir = ""
  if call != nil:
    for i, name in call[].namedNames:
      let v = call[].namedValues[i]
      case name
      of "cmd":
        requireStr("os/exec ^cmd", v)
        cmd = v.strVal
        cmdSet = true
      of "args":
        if v.kind != vkList:
          raiseOsError("os/exec ^args must be a List of Str", scope)
        for item in v.listItems:
          requireStr("os/exec ^args item", item)
          procArgs.add item.strVal
      of "timeout-ms": timeoutMs = int(requireInt64("os/exec ^timeout-ms", v))
      of "max-bytes": maxBytes = int(requireInt64("os/exec ^max-bytes", v))
      of "dir":
        requireStr("os/exec ^dir", v)
        workdir = v.strVal
      else:
        raiseOsError("os/exec got unexpected named argument: " & name, scope)
  if not cmdSet or cmd.len == 0:
    raiseOsError("os/exec requires a non-empty ^cmd", scope)
  if maxBytes <= 0:
    maxBytes = osExecDefaultOutputCap
  var process: Process
  try:
    process = startProcess(cmd, workingDir = workdir, args = procArgs,
                           options = {poUsePath})
  except OSError as e:
    raiseOsError("os/exec could not start '" & cmd & "': " & e.msg, scope)
  var outText = ""
  var errText = ""
  var outTruncated = false
  var errTruncated = false
  var timedOut = false
  let deadline =
    if timeoutMs >= 0: getMonoTime() + initDuration(milliseconds = timeoutMs)
    else: getMonoTime()

  proc appendCapped(into: var string, truncated: var bool, chunk: string) =
    if into.len >= maxBytes:
      if chunk.len > 0:
        truncated = true
      return
    if into.len + chunk.len <= maxBytes:
      into.add chunk
    else:
      truncated = true
      into.add chunk.substr(0, maxBytes - into.len - 1)

  # POSIX: drain the child's stdout/stderr *concurrently* with waiting, using
  # non-blocking reads. Reading as the child writes keeps the OS pipe buffer
  # from filling — otherwise a child emitting more than the ~64 KB pipe buffer
  # (a large API response) blocks on write, never exits, and hits the timeout
  # with its output lost. Non-blocking reads also let the wall-clock timeout
  # fire on a child that produces no output (the `sleep` case).
  when defined(posix):
    let outFd = process.outputHandle.cint
    let errFd = process.errorHandle.cint
    discard fcntl(outFd, F_SETFL, fcntl(outFd, F_GETFL, 0) or O_NONBLOCK)
    discard fcntl(errFd, F_SETFL, fcntl(errFd, F_GETFL, 0) or O_NONBLOCK)
    var buf: array[4096, char]
    proc drainAvailable(fd: cint, into: var string, truncated: var bool) =
      while true:
        let n = read(fd, addr buf[0], buf.len)
        if n > 0:
          var chunk = newString(n)
          copyMem(addr chunk[0], addr buf[0], n)
          appendCapped(into, truncated, chunk)
        else:
          break                       # EAGAIN, EOF, or error: nothing right now
    while process.running:
      drainAvailable(outFd, outText, outTruncated)
      drainAvailable(errFd, errText, errTruncated)
      if timeoutMs >= 0 and getMonoTime() >= deadline:
        timedOut = true
        process.terminate()
        break
      os.sleep(osExecPollMs)
    var exitCode = 0
    try:
      exitCode = if timedOut: (discard process.waitForExit(); -1)
                 else: process.waitForExit()
      drainAvailable(outFd, outText, outTruncated) # final sweep after exit
      drainAvailable(errFd, errText, errTruncated)
    finally:
      process.close()
  else:
    # Non-POSIX fallback: enforce the timeout via waitForExit, then read to EOF.
    # (Windows is a documented non-goal for the agent; this keeps exec usable.)
    var exitCode = process.waitForExit(if timeoutMs >= 0: timeoutMs else: -1)
    if process.running:
      timedOut = true
      process.terminate()
      exitCode = -1
    appendCapped(outText, outTruncated, process.outputStream.readAll())
    appendCapped(errText, errTruncated, process.errorStream.readAll())
    process.close()
  var props = initOrderedTable[string, Value]()
  props["status"] = newInt(exitCode)
  props["stdout"] = newStr(outText)
  props["stderr"] = newStr(errText)
  props["stdout-truncated"] = if outTruncated: TRUE else: FALSE
  props["stderr-truncated"] = if errTruncated: TRUE else: FALSE
  props["truncated"] = if outTruncated or errTruncated: TRUE else: FALSE
  props["timed-out"] = if timedOut: TRUE else: FALSE
  newMap(props)

proc biOsExecStream(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Run a subprocess like os/exec, but invoke optional callbacks as output
  ## arrives: ^stdout receives raw chunks and ^stdout-line receives complete
  ## stdout lines without the trailing newline. The final return value keeps the
  ## same captured-output shape as os/exec.
  if args.len != 1:
    raise newException(GeneError,
      "os/exec-stream expects the Os/Exec capability plus named arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsExec("os/exec-stream", args[0], scope)
  var cmd = ""
  var cmdSet = false
  var procArgs: seq[string]
  var timeoutMs = -1
  var maxBytes = osExecDefaultOutputCap
  var workdir = ""
  var stdoutCb = NIL
  var stdoutLineCb = NIL
  var stderrCb = NIL
  if call != nil:
    for i, name in call[].namedNames:
      let v = call[].namedValues[i]
      case name
      of "cmd":
        requireStr("os/exec-stream ^cmd", v)
        cmd = v.strVal
        cmdSet = true
      of "args":
        if v.kind != vkList:
          raiseOsError("os/exec-stream ^args must be a List of Str", scope)
        for item in v.listItems:
          requireStr("os/exec-stream ^args item", item)
          procArgs.add item.strVal
      of "timeout-ms": timeoutMs = int(requireInt64("os/exec-stream ^timeout-ms", v))
      of "max-bytes": maxBytes = int(requireInt64("os/exec-stream ^max-bytes", v))
      of "dir":
        requireStr("os/exec-stream ^dir", v)
        workdir = v.strVal
      of "stdout":
        stdoutCb = v
      of "stdout-line":
        stdoutLineCb = v
      of "stderr":
        stderrCb = v
      else:
        raiseOsError("os/exec-stream got unexpected named argument: " & name, scope)
  if not cmdSet or cmd.len == 0:
    raiseOsError("os/exec-stream requires a non-empty ^cmd", scope)
  if maxBytes <= 0:
    maxBytes = osExecDefaultOutputCap

  var process: Process
  try:
    process = startProcess(cmd, workingDir = workdir, args = procArgs,
                           options = {poUsePath})
  except OSError as e:
    raiseOsError("os/exec-stream could not start '" & cmd & "': " & e.msg, scope)

  var outText = ""
  var errText = ""
  var outTruncated = false
  var errTruncated = false
  var timedOut = false
  var stdoutLineBuf = ""
  let deadline =
    if timeoutMs >= 0: getMonoTime() + initDuration(milliseconds = timeoutMs)
    else: getMonoTime()

  proc appendCapped(into: var string, truncated: var bool, chunk: string) =
    if into.len >= maxBytes:
      if chunk.len > 0:
        truncated = true
      return
    if into.len + chunk.len <= maxBytes:
      into.add chunk
    else:
      truncated = true
      into.add chunk.substr(0, maxBytes - into.len - 1)

  proc callChunk(cb: Value, chunk: string) =
    if cb.kind != vkNil:
      discard applyCall(cb, [newStr(chunk)], NamedArgs(), scope)

  proc callStdoutLines(chunk: string) =
    if stdoutLineCb.kind == vkNil:
      return
    for ch in chunk:
      if ch == '\n':
        if stdoutLineBuf.len > 0 and stdoutLineBuf[^1] == '\r':
          stdoutLineBuf.setLen(stdoutLineBuf.len - 1)
        discard applyCall(stdoutLineCb, [newStr(stdoutLineBuf)], NamedArgs(), scope)
        stdoutLineBuf.setLen(0)
      else:
        stdoutLineBuf.add ch

  proc finishStdoutLine() =
    if stdoutLineCb.kind != vkNil and stdoutLineBuf.len > 0:
      discard applyCall(stdoutLineCb, [newStr(stdoutLineBuf)], NamedArgs(), scope)
      stdoutLineBuf.setLen(0)

  proc handleStdoutChunk(chunk: string) =
    callChunk(stdoutCb, chunk)
    callStdoutLines(chunk)
    appendCapped(outText, outTruncated, chunk)

  proc handleStderrChunk(chunk: string) =
    callChunk(stderrCb, chunk)
    appendCapped(errText, errTruncated, chunk)

  try:
    when defined(posix):
      let outFd = process.outputHandle.cint
      let errFd = process.errorHandle.cint
      discard fcntl(outFd, F_SETFL, fcntl(outFd, F_GETFL, 0) or O_NONBLOCK)
      discard fcntl(errFd, F_SETFL, fcntl(errFd, F_GETFL, 0) or O_NONBLOCK)
      var buf: array[4096, char]
      proc drainAvailable(fd: cint, handle: proc(chunk: string)) =
        while true:
          let n = read(fd, addr buf[0], buf.len)
          if n > 0:
            var chunk = newString(n)
            copyMem(addr chunk[0], addr buf[0], n)
            handle(chunk)
          else:
            break
      while process.running:
        drainAvailable(outFd, handleStdoutChunk)
        drainAvailable(errFd, handleStderrChunk)
        if timeoutMs >= 0 and getMonoTime() >= deadline:
          timedOut = true
          process.terminate()
          break
        os.sleep(osExecPollMs)
      var exitCode = 0
      exitCode = if timedOut: (discard process.waitForExit(); -1)
                 else: process.waitForExit()
      drainAvailable(outFd, handleStdoutChunk)
      drainAvailable(errFd, handleStderrChunk)
      finishStdoutLine()
      var props = initOrderedTable[string, Value]()
      props["status"] = newInt(exitCode)
      props["stdout"] = newStr(outText)
      props["stderr"] = newStr(errText)
      props["stdout-truncated"] = if outTruncated: TRUE else: FALSE
      props["stderr-truncated"] = if errTruncated: TRUE else: FALSE
      props["truncated"] = if outTruncated or errTruncated: TRUE else: FALSE
      props["timed-out"] = if timedOut: TRUE else: FALSE
      return newMap(props)
    else:
      var exitCode = process.waitForExit(if timeoutMs >= 0: timeoutMs else: -1)
      if process.running:
        timedOut = true
        process.terminate()
        exitCode = -1
      let allOut = process.outputStream.readAll()
      let allErr = process.errorStream.readAll()
      handleStdoutChunk(allOut)
      handleStderrChunk(allErr)
      finishStdoutLine()
      var props = initOrderedTable[string, Value]()
      props["status"] = newInt(exitCode)
      props["stdout"] = newStr(outText)
      props["stderr"] = newStr(errText)
      props["stdout-truncated"] = if outTruncated: TRUE else: FALSE
      props["stderr-truncated"] = if errTruncated: TRUE else: FALSE
      props["truncated"] = if outTruncated or errTruncated: TRUE else: FALSE
      props["timed-out"] = if timedOut: TRUE else: FALSE
      return newMap(props)
  except:
    if process.running:
      process.terminate()
    raise
  finally:
    process.close()

proc biOsExecStdio(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Run a subprocess attached to this process's stdin/stdout/stderr and return
  ## its exit status. This is for terminal handoff cases where captured
  ## `os/exec` would break interactive behavior.
  if args.len != 1:
    raise newException(GeneError,
      "os/exec-stdio expects the Os/Exec capability plus named arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsExec("os/exec-stdio", args[0], scope)
  var cmd = ""
  var cmdSet = false
  var procArgs: seq[string]
  var workdir = ""
  if call != nil:
    for i, name in call[].namedNames:
      let v = call[].namedValues[i]
      case name
      of "cmd":
        requireStr("os/exec-stdio ^cmd", v)
        cmd = v.strVal
        cmdSet = true
      of "args":
        if v.kind != vkList:
          raiseOsError("os/exec-stdio ^args must be a List of Str", scope)
        for item in v.listItems:
          requireStr("os/exec-stdio ^args item", item)
          procArgs.add item.strVal
      of "dir":
        requireStr("os/exec-stdio ^dir", v)
        workdir = v.strVal
      else:
        raiseOsError("os/exec-stdio got unexpected named argument: " & name, scope)
  if not cmdSet or cmd.len == 0:
    raiseOsError("os/exec-stdio requires a non-empty ^cmd", scope)
  var process: Process
  try:
    process = startProcess(cmd, workingDir = workdir, args = procArgs,
                           options = {poUsePath, poParentStreams})
  except OSError as e:
    raiseOsError("os/exec-stdio could not start '" & cmd & "': " & e.msg, scope)
  # system(3) semantics: the child owns the terminal, so Ctrl-C must reach the
  # child (and whatever it runs), not kill this process while it waits.
  when defined(posix):
    var ignoreInt, oldInt: Sigaction
    ignoreInt.sa_handler = SIG_IGN
    discard sigemptyset(ignoreInt.sa_mask)
    ignoreInt.sa_flags = 0
    let intIgnored = sigaction(SIGINT, ignoreInt, oldInt) == 0
  try:
    newInt(process.waitForExit())
  finally:
    when defined(posix):
      if intIgnored:
        discard sigaction(SIGINT, oldInt, nil)
    process.close()

# --- os/exec-async + os/exec-stream-async: subprocess on a dedicated thread ---
#
# The synchronous exec natives block the scheduler thread, freezing every
# fiber (and the net/http event loop) for the duration of the child — the
# §12.9 gap-1 problem in examples/ai_agent/design.md. These variants run the child on a
# dedicated OS thread and settle an external Task, following the proven
# foreign-thread pattern (tests/test_native_api_threads.nim, the aio worker's
# runAsyncIoRequest): every value crossing threads is markSharedValue'd so its
# refcount is atomic, handoff goes through the lock-protected channel/task
# paths, and the worker never runs Gene code.

when compileOption("threads"):
  # Job records cross the scheduler->worker thread boundary. On the default
  # orc build the only rc-safe discipline is: the worker performs ZERO
  # refcount operations on anything the scheduler thread can also touch.
  # Gene's manual-rc payloads (strings, lists, maps) are atomic once
  # markSharedValue'd, but OBJECT_TAG payloads — Task and Channel, exactly
  # what an exec job must hold — retain/release through plain GC_ref/GC_unref:
  # non-atomic ORC ops whose cycle bookkeeping also mutates a global buffer.
  # A worker-side retain or release of those races the scheduler and corrupts
  # the heap (crashes surface later in unrelated Value ops or allocations).
  # So the ctx stores task/channel as raw bits (never Value fields), the
  # worker borrows them through {.cursor.} locals (no hooks), the helper
  # routines are templates (a closure env would copy captured refs on the
  # worker thread), and ownership lives in osExecAsyncPending — a scheduler-
  # thread-only registry that retains the task/channel/ctx at spawn and
  # releases them at the next spawn's prune, always on the scheduler thread.
  type OsExecAsyncCtx {.acyclic.} = ref object
    name: string          # native name, for error messages
    cmd: string
    procArgs: seq[string]
    workdir: string
    timeoutMs: int
    maxBytes: int
    taskBits: uint64      # external Task (OBJECT_TAG bits); osExecAsyncPending owns the ref
    lineChanBits: uint64  # 0, or a Channel (bits) receiving stdout lines
    # The spawner's scheduler, captured at spawn time. NOT the dispatch scope:
    # call scopes are pooled and their .application is nilled on release, so a
    # scope captured here would resolve to no scheduler by the time the worker
    # settles — wakes would be lost and fibers parked on the task/channel
    # would never resume.
    schedulerPtr: pointer
    # Release-stored by the worker loop AFTER its final access to this job;
    # the scheduler frees the ctx (and drops the task/channel refs) only after
    # acquiring it. taskDone alone is NOT sufficient: the worker still calls
    # wakeTaskWaitersIn after completing the task.
    workerDone: bool

  # Persistent exec-worker pool. Threads are created on demand up to a cap and
  # NEVER exit: values a job creates (stdout strings, the result map) live on
  # the creating thread's heap arena, and Nim tears that arena down at thread
  # exit — so a thread-per-exec design corrupts the allocator as soon as a
  # result outlives its thread. Long-lived workers are the same discipline as
  # the scheduler's aio lane. Jobs queue when all workers are busy; the cap is
  # generous because jobs can legitimately be long (60s streaming curl).
  const osExecAsyncMaxWorkers = 32

  var osExecAsyncLock: Lock
  var osExecAsyncCond: Cond
  var osExecAsyncQueue: seq[pointer]   # borrowed OsExecAsyncCtx; registry owns
  var osExecAsyncThreads: seq[ref Thread[void]]
  var osExecAsyncIdle = 0
  initLock(osExecAsyncLock)
  initCond(osExecAsyncCond)

  # Exec workers never touch this registry. Calls may nevertheless originate
  # from more than one scheduler lane, so the exec lock serializes prune/add and
  # keeps destructor-bearing Value entries from racing each other. Entries keep
  # the Task, stdout Channel, and ctx alive for the worker's whole run.
  var osExecAsyncPending: seq[tuple[task: Value, chan: Value, ctxPtr: pointer]]

  proc pruneOsExecAsyncPending() =
    ## Free finished jobs' task/channel/ctx references — on this (scheduler)
    ## thread, which is the whole point. Called before each new spawn, so the
    ## registry is bounded by the number of jobs since the last spawn.
    withLock osExecAsyncLock:
      var i = 0
      while i < osExecAsyncPending.len:
        let ctx {.cursor.} = cast[OsExecAsyncCtx](osExecAsyncPending[i].ctxPtr)
        if atomicLoadN(addr ctx.workerDone, ATOMIC_ACQUIRE):
          GC_unref(cast[OsExecAsyncCtx](osExecAsyncPending[i].ctxPtr))
          # `seq.delete` shifts every following tuple through destructor-bearing
          # Value fields. Under ORC that has intermittently double-released a
          # moved Task/Channel entry. Swap-remove performs one explicit move and
          # keeps registry order irrelevant.
          let last = osExecAsyncPending.high
          if i != last:
            osExecAsyncPending[i] = move osExecAsyncPending[last]
          osExecAsyncPending.setLen(last)
        else:
          inc i

  proc runOsExecAsyncJob(jobPtr: pointer) {.gcsafe.} =
    {.cast(gcsafe).}:
      # Borrow everything without touching refcounts: the ctx via a cursor
      # cast (the registry owns it), the scheduler via its raw pointer, and
      # the task/channel as cursor Values built from raw bits. All wakes go
      # through the explicit *In variants. The helpers below are templates on
      # purpose: nested procs would capture these refs into a closure env,
      # and creating/destroying that env on this thread is exactly the
      # non-atomic GC_ref/GC_unref race this design exists to prevent.
      let ctx {.cursor.} = cast[OsExecAsyncCtx](jobPtr)
      let sched {.cursor.} = cast[SchedulerState](ctx.schedulerPtr)
      # Cursor var + raw field assignment, NOT `let v {.cursor.} = Value(bits:
      # ...)`: cursor does not suppress the destroy of a construction
      # temporary, so that form still runs =destroy at scope exit — an
      # unretained rcRelease of the task/channel on this worker thread.
      var taskView {.cursor.}: Value
      taskView.bits = ctx.taskBits
      var lineChanView {.cursor.}: Value
      lineChanView.bits = ctx.lineChanBits
      defer:
        endExternalNativeOp()
      var outText = ""
      var errText = ""
      var outTruncated = false
      var errTruncated = false
      var timedOut = false
      var cancelled = false
      var lineBuf = ""
      var exitCode = 0
      var chanGone = ctx.lineChanBits == 0
      let deadline =
        if ctx.timeoutMs >= 0:
          getMonoTime() + initDuration(milliseconds = ctx.timeoutMs)
        else:
          getMonoTime()

      template appendCapped(into: var string, truncated: var bool,
                            chunk: string) =
        block:
          if into.len >= ctx.maxBytes:
            if chunk.len > 0:
              truncated = true
          elif into.len + chunk.len <= ctx.maxBytes:
            into.add chunk
          else:
            truncated = true
            into.add chunk.substr(0, ctx.maxBytes - into.len - 1)

      template sendLine(line: string) =
        ## Push one stdout line with bounded backpressure: retry while the
        ## channel is full, give up (but keep capturing) once it is closed or
        ## the exec deadline passes. The value is created on this thread and
        ## marked shared before it becomes visible cross-thread, so its
        ## refcount ops are atomic from then on.
        block sendBlock:
          if not chanGone:
            while true:
              let item = newStr(line)
              markSharedValue(item)
              let pushed = lineChanView.tryPushChannel(item)
              if pushed.pushed:
                wakeChannelWaitersIn(sched, lineChanView, wakeSenders = false)
                break sendBlock
              if pushed.closed:
                chanGone = true
                break sendBlock
              if taskView.taskCancelled:
                # The consumer may have unwound without draining the bounded
                # channel. Stop applying backpressure so the outer process
                # loop can observe cancellation and terminate the child.
                cancelled = true
                chanGone = true
                break sendBlock
              if ctx.timeoutMs >= 0 and getMonoTime() >= deadline:
                break sendBlock
              os.sleep(1)

      template handleStdoutChunk(chunk: string) =
        block:
          appendCapped(outText, outTruncated, chunk)
          if not chanGone:
            for ch in chunk:
              if ch == '\n':
                if lineBuf.len > 0 and lineBuf[^1] == '\r':
                  lineBuf.setLen(lineBuf.len - 1)
                sendLine(lineBuf)
                lineBuf.setLen(0)
              else:
                lineBuf.add ch

      template closeLineChan() =
        if ctx.lineChanBits != 0:
          closeChannel(lineChanView)
          wakeAllChannelWaitersIn(sched, lineChanView, wakeSenders = false)
          wakeAllChannelWaitersIn(sched, lineChanView, wakeSenders = true)

      template settle(value: Value) =
        block:
          # Bind once: template arguments re-evaluate at each mention.
          let settled = value
          markSharedValue(settled)
          closeLineChan()
          if tryCompleteTask(taskView, settled):
            wakeTaskWaitersIn(sched, taskView)

      template settleFail(message: string) =
        block:
          let failMsg = message
          closeLineChan()
          if tryFailTask(taskView, failMsg):
            wakeTaskWaitersIn(sched, taskView)

      template cancellationRequested(): bool =
        ## External Tasks settle as cancelled on the scheduler thread before
        ## this worker observes the request. Poll the terminal state so task
        ## cancellation also stops the owned subprocess instead of merely
        ## discarding its eventual result.
        taskView.taskCancelled

      if cancellationRequested():
        closeLineChan()
        return

      var process: Process
      try:
        process = startProcess(ctx.cmd, workingDir = ctx.workdir,
                               args = ctx.procArgs, options = {poUsePath})
      except CatchableError as e:
        settleFail(ctx.name & " could not start '" & ctx.cmd & "': " & e.msg)
        return
      try:
        try:
          when defined(posix):
            let outFd = process.outputHandle.cint
            let errFd = process.errorHandle.cint
            discard fcntl(outFd, F_SETFL,
                          fcntl(outFd, F_GETFL, 0) or O_NONBLOCK)
            discard fcntl(errFd, F_SETFL,
                          fcntl(errFd, F_GETFL, 0) or O_NONBLOCK)
            var buf: array[4096, char]
            # Template, not a nested proc: a proc would capture the cursor
            # views through the expanded helpers into a closure env.
            template drainAvailable(fd: cint, isOut: bool) =
              while true:
                let n = read(fd, addr buf[0], buf.len)
                if n > 0:
                  var chunk = newString(n)
                  copyMem(addr chunk[0], addr buf[0], n)
                  when isOut:
                    handleStdoutChunk(chunk)
                  else:
                    appendCapped(errText, errTruncated, chunk)
                else:
                  break
            while process.running:
              drainAvailable(outFd, true)
              drainAvailable(errFd, false)
              if cancellationRequested():
                cancelled = true
                process.terminate()
                break
              if ctx.timeoutMs >= 0 and getMonoTime() >= deadline:
                timedOut = true
                process.terminate()
                break
              os.sleep(osExecPollMs)
            exitCode = if timedOut or cancelled:
                         (discard process.waitForExit(); -1)
                       else:
                         process.waitForExit()
            drainAvailable(outFd, true)
            drainAvailable(errFd, false)
          else:
            while process.running:
              if cancellationRequested():
                cancelled = true
                process.terminate()
                break
              if ctx.timeoutMs >= 0 and getMonoTime() >= deadline:
                timedOut = true
                process.terminate()
                break
              os.sleep(osExecPollMs)
            exitCode = if timedOut or cancelled:
                         (discard process.waitForExit(); -1)
                       else:
                         process.waitForExit()
            handleStdoutChunk(process.outputStream.readAll())
            appendCapped(errText, errTruncated, process.errorStream.readAll())
          if lineBuf.len > 0:
            sendLine(lineBuf)
            lineBuf.setLen(0)
          if cancelled:
            # Task/cancel already settled and woke its waiters. Only the
            # worker-owned channel still needs closing; do not race it with a
            # second task settlement or manufacture an exec result.
            closeLineChan()
            return
          var props = initOrderedTable[string, Value]()
          props["status"] = newInt(exitCode)
          props["stdout"] = newStr(outText)
          props["stderr"] = newStr(errText)
          props["stdout-truncated"] = if outTruncated: TRUE else: FALSE
          props["stderr-truncated"] = if errTruncated: TRUE else: FALSE
          props["truncated"] = if outTruncated or errTruncated: TRUE else: FALSE
          props["timed-out"] = if timedOut: TRUE else: FALSE
          settle(newMap(props))
        except CatchableError as e:
          settleFail(ctx.name & " failed: " & e.msg)
      finally:
        try:
          process.close()
        except CatchableError:
          discard

when compileOption("threads"):
  proc osExecAsyncWorkerMain() {.thread.} =
    {.cast(gcsafe).}:
      while true:
        var jobPtr: pointer = nil
        withLock osExecAsyncLock:
          while osExecAsyncQueue.len == 0:
            inc osExecAsyncIdle
            wait(osExecAsyncCond, osExecAsyncLock)
            dec osExecAsyncIdle
          jobPtr = osExecAsyncQueue[0]
          osExecAsyncQueue.delete(0)
        runOsExecAsyncJob(jobPtr)
        # Must be this worker's final access to the job: once the scheduler
        # acquires the flag it frees the ctx and drops the task/channel refs.
        let doneCtx {.cursor.} = cast[OsExecAsyncCtx](jobPtr)
        atomicStoreN(addr doneCtx.workerDone, true, ATOMIC_RELEASE)

  proc enqueueOsExecAsyncJob(jobPtr: pointer) =
    var needThread = false
    withLock osExecAsyncLock:
      osExecAsyncQueue.add jobPtr
      if osExecAsyncIdle == 0 and
          osExecAsyncThreads.len < osExecAsyncMaxWorkers:
        needThread = true
      else:
        signal(osExecAsyncCond)
    if needThread:
      var tr: ref Thread[void]
      new(tr)
      createThread(tr[], osExecAsyncWorkerMain)
      withLock osExecAsyncLock:
        osExecAsyncThreads.add tr

proc biOsExecAsyncImpl(name: string, wantChan: bool,
                       args: openArray[Value],
                       call: ptr NativeCall): Value =
  if args.len != 1:
    raise newException(GeneError,
      name & " expects the Os/Exec capability plus named arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsExec(name, args[0], scope)
  var cmd = ""
  var cmdSet = false
  var procArgs: seq[string]
  var timeoutMs = -1
  var maxBytes = osExecDefaultOutputCap
  var workdir = ""
  var lineChan = NIL
  if call != nil:
    for i, argName in call[].namedNames:
      let v = call[].namedValues[i]
      case argName
      of "cmd":
        requireStr(name & " ^cmd", v)
        cmd = v.strVal
        cmdSet = true
      of "args":
        if v.kind != vkList:
          raiseOsError(name & " ^args must be a List of Str", scope)
        for item in v.listItems:
          requireStr(name & " ^args item", item)
          procArgs.add item.strVal
      of "timeout-ms":
        timeoutMs = int(requireInt64(name & " ^timeout-ms", v))
      of "max-bytes":
        maxBytes = int(requireInt64(name & " ^max-bytes", v))
      of "dir":
        requireStr(name & " ^dir", v)
        workdir = v.strVal
      of "stdout-chan":
        if not wantChan:
          raiseOsError(name & " got unexpected named argument: stdout-chan",
                       scope)
        requireChannel(name & " ^stdout-chan", v)
        lineChan = v
      else:
        raiseOsError(name & " got unexpected named argument: " & argName,
                     scope)
  if not cmdSet or cmd.len == 0:
    raiseOsError(name & " requires a non-empty ^cmd", scope)
  if maxBytes <= 0:
    maxBytes = osExecDefaultOutputCap
  if wantChan and lineChan.kind == vkNil:
    raiseOsError(name & " requires ^stdout-chan (a Channel of stdout lines)",
                 scope)
  when compileOption("threads"):
    if scope == nil or scope.application == nil:
      raiseOsError(name & " requires a scheduler scope", scope)
    pruneOsExecAsyncPending()
    let task = newExternalTask()
    markSharedValue(task)
    if lineChan.kind != vkNil:
      markSharedValue(lineChan)
    let ctx = OsExecAsyncCtx(name: name, cmd: cmd, procArgs: procArgs,
                             workdir: workdir, timeoutMs: timeoutMs,
                             maxBytes: maxBytes, taskBits: task.bits,
                             lineChanBits: (if lineChan.kind == vkNil: 0'u64
                                            else: lineChan.bits),
                             schedulerPtr: cast[pointer](
                               schedulerForScope(scope)))
    # Scheduler-side ownership: the registry retains the task/channel (Value
    # copies) and the ctx (GC_ref) so the worker can borrow raw bits and a raw
    # pointer with zero refcount traffic. Released in pruneOsExecAsyncPending,
    # on this thread, after the worker's release-store of workerDone. The
    # entry is built with explicit field assignments so each Value goes
    # through =copy — a tuple constructor may sink the locals instead.
    GC_ref(ctx)
    var pendingEntry: tuple[task: Value, chan: Value, ctxPtr: pointer]
    pendingEntry.task = task
    pendingEntry.chan = lineChan
    pendingEntry.ctxPtr = cast[pointer](ctx)
    withLock osExecAsyncLock:
      osExecAsyncPending.add(move pendingEntry)
    beginExternalNativeOp()
    try:
      enqueueOsExecAsyncJob(cast[pointer](ctx))
    except CatchableError as e:
      endExternalNativeOp()
      GC_unref(ctx)
      withLock osExecAsyncLock:
        osExecAsyncPending.setLen(osExecAsyncPending.len - 1)
      raiseOsError(name & " could not start a worker thread: " & e.msg, scope)
    task
  else:
    raiseOsError(name & " requires a threaded runtime build", scope)
    NIL

proc biOsExecAsync(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## os/exec contract, but returns a Task settled off-thread: the scheduler
  ## keeps running fibers while the child executes. Await for the result map.
  biOsExecAsyncImpl("os/exec-async", false, args, call)

proc biOsExecStreamAsync(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## os/exec-async plus live stdout lines: each complete line (CR stripped) is
  ## sent to ^stdout-chan as it arrives; the channel is closed when the child
  ## exits, then the Task settles with the captured result map.
  biOsExecAsyncImpl("os/exec-stream-async", true, args, call)

proc biOsStdinTty(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/stdin-tty? takes no arguments")
  when defined(posix):
    if isatty(STDIN_FILENO) != 0: TRUE else: FALSE
  else:
    FALSE

proc cClearErr(f: File) {.importc: "clearerr", header: "<stdio.h>".}

proc biOsReadLine(args: openArray[Value]): Value {.nimcall.} =
  ## Read one line from stdin; returns nil at EOF. No capability: reading the
  ## program's own stdin is not host authority the way env/exec/files are.
  if args.len != 0:
    raise newException(GeneError, "os/read-line takes no arguments")
  try:
    newStr(stdin.readLine())
  except EOFError:
    when defined(posix):
      if isatty(STDIN_FILENO) != 0:
        cClearErr(stdin)
    NIL

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc openCursesInput() =
    if not cursesInputActive:
      cInstallRestoreHooks()
      cSaveTermios()
      cSetLocale()
      if cInitscr() == nil:
        raise newException(GeneError, "os/read-input could not initialize ncurses")
      cursesInputActive = true
      cursesColorsReady = false
      cursesPasteReady = false
    discard cbreak()
    discard noecho()
    discard keypad(stdscr, 1)
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
      discard keypad(stdscr, 0)
      discard cEcho()
      discard nocbreak()
      discard noraw()
      discard curs_set(1)
      discard cEndwin()
      discard reset_shell_mode()
      cursesInputActive = false
      cursesColorsReady = false
      cursesPasteReady = false
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

  proc drawSeparator(row, width: int) =
    discard cMove(row.cint, 0)
    withCursesColor(PairSeparator,
      proc() =
        addCursesText(repeat("─", width), width))
    discard clrtoeol()

  proc drawCursesInput(prompt, status, output, input: string, cursor: int) =
    discard wclear(stdscr)
    let height = max(1, int(LINES))
    let width = max(1, int(COLS))
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

    let outputLines = splitCursesLines(output)
    let firstOutput =
      if outputLines.len > outputRows:
        outputLines.len - outputRows
      else:
        0
    var transcriptPair = PairOutput
    for idx in 0 ..< firstOutput:
      discard displayTranscriptLine(outputLines[idx], transcriptPair)
    for row in 0 ..< outputRows:
      discard cMove(row.cint, 0)
      let idx = firstOutput + row
      if idx < outputLines.len:
        let rendered = displayTranscriptLine(outputLines[idx], transcriptPair)
        withCursesColor(rendered.pair,
          proc() =
            addCursesText(rendered.text, width))
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
    withCursesColor(PairStatus,
      proc() =
        addCursesText(status, width))
    discard clrtoeol()

    let cursorVisibleRow = cursorLine - firstInputLine
    let y = min(bottomSepRow - 1, inputTop + max(0, cursorVisibleRow))
    let x = min(width - 1, pos.col)
    discard cMove(y.cint, x.cint)
    discard refresh()

  proc defaultInputStatus(multiline: bool): string =
    if multiline:
      "Enter sends | Paste, Shift+Enter, or Alt+Enter keeps newlines | Ctrl-D cancels"
    else:
      "Enter sends | Ctrl-D cancels"

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

  proc insertTextAt(input: var string, cursor: var int, text: string) =
    if text.len == 0:
      return
    input.insert(text, cursor)
    inc cursor, text.len

  proc insertCharAt(input: var string, cursor: var int, ch: char) =
    input.insert($ch, cursor)
    inc cursor

  proc readCursesInput(prompt, status, output: string,
                       multiline, persistent: bool): Value =
    openCursesInput()
    try:
      let statusText =
        if status.len > 0: status
        else: defaultInputStatus(multiline)
      var input = ""
      var cursor = 0
      var pasteMode = false
      while true:
        drawCursesInput(prompt, statusText, output, input, cursor)
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
          of KeyCtrlD:
            return NIL
          of KeyEnter, KeyReturn, KeyNcursesEnter:
            return newStr(input)
          of KeyShiftEnter:
            if multiline:
              insertCharAt(input, cursor, '\n')
            else:
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
            if isPasteStartSequence(seq):
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

proc biOsReadInput(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Read one submitted input string. On a TTY this uses a small ncurses editor;
  ## in pipes it falls back to read-line so scripts and tests stay deterministic.
  if args.len != 0:
    raise newException(GeneError, "os/read-input expects named arguments only")
  var prompt = ""
  var status = ""
  var output = ""
  var multiline = true
  var persistent = false
  if call != nil:
    for i, name in call[].namedNames:
      let v = call[].namedValues[i]
      case name
      of "prompt":
        requireStr("os/read-input ^prompt", v)
        prompt = v.strVal
      of "status":
        requireStr("os/read-input ^status", v)
        status = v.strVal
      of "output":
        requireStr("os/read-input ^output", v)
        output = v.strVal
      of "multiline":
        if v.kind != vkBool:
          raise newException(GeneError, "os/read-input ^multiline must be Bool")
        multiline = v.boolVal
      of "persistent":
        if v.kind != vkBool:
          raise newException(GeneError, "os/read-input ^persistent must be Bool")
        persistent = v.boolVal
      else:
        raise newException(GeneError,
          "os/read-input got unexpected named argument: " & name)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if isatty(STDIN_FILENO) != 0:
      return readCursesInput(prompt, status, output, multiline, persistent)
  if prompt.len > 0:
    stdout.write(prompt)
    stdout.flushFile()
  biOsReadLine([])

proc biOsRefreshInput(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Redraw the ncurses input surface without reading. This lets a program using
  ## persistent os/read-input repaint streamed output between prompts.
  if args.len != 0:
    raise newException(GeneError, "os/refresh-input expects named arguments only")
  var prompt = ""
  var status = ""
  var output = ""
  if call != nil:
    for i, name in call[].namedNames:
      let v = call[].namedValues[i]
      case name
      of "prompt":
        requireStr("os/refresh-input ^prompt", v)
        prompt = v.strVal
      of "status":
        requireStr("os/refresh-input ^status", v)
        status = v.strVal
      of "output":
        requireStr("os/refresh-input ^output", v)
        output = v.strVal
      else:
        raise newException(GeneError,
          "os/refresh-input got unexpected named argument: " & name)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if isatty(STDIN_FILENO) != 0:
      openCursesInput()
      let statusText =
        if status.len > 0: status
        else: defaultInputStatus(true)
      drawCursesInput(prompt, statusText, output, "", 0)
  NIL

proc biOsCloseInput(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/close-input takes no arguments")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    closeCursesInput()
  NIL

# --- repl: reusable interactive evaluator ---

proc biReplRun(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "repl/run expects one Env argument")
  if args[0].kind != vkEnv:
    raise newException(GeneError, "repl/run expects an Env")
  var prompt = "gene> "
  var interactive =
    when defined(posix):
      isatty(STDIN_FILENO) != 0
    else:
      false
  if call != nil:
    for i, name in call[].namedNames:
      let v = call[].namedValues[i]
      case name
      of "prompt":
        requireStr("repl/run ^prompt", v)
        prompt = v.strVal
      of "interactive":
        if v.kind != vkBool:
          raise newException(GeneError, "repl/run ^interactive must be Bool")
        interactive = v.boolVal
      else:
        raise newException(GeneError,
          "repl/run got unexpected named argument: " & name)
  let reader = proc(line: var string): bool =
    result = stdin.readLine(line)
    when defined(posix):
      if not result and isatty(STDIN_FILENO) != 0:
        cClearErr(stdin)
  let writeOut = proc(text: string) =
    stdout.write(text)
    stdout.flushFile()
  let writeErr = proc(text: string) =
    stderr.write(text)
    stderr.flushFile()
  newInt(runReplSessionForEnv(args[0], reader, writeOut, writeErr,
                              ReplOptions(interactive: interactive,
                                          prompt: prompt)))

# --- fs: synchronous read + directory listing (examples/ai_agent/design.md §6) ---

proc biFsReadTextSync(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Fs/read-text expects (Fs/ReadDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsReadDir("Fs/read-text", args[0])
  requireStr("Fs/read-text path", args[1])
  try:
    newStr(readFile(args[1].strVal))
  except IOError as e:
    raiseOsError("Fs/read-text: " & e.msg, scope)
    NIL

proc biFsWriteTextSync(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "Fs/write-text expects (Fs/WriteDir, path, text)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsWriteDir("Fs/write-text", args[0])
  requireStr("Fs/write-text path", args[1])
  requireStr("Fs/write-text text", args[2])
  try:
    writeFile(args[1].strVal, args[2].strVal)
  except IOError as e:
    raiseOsError("Fs/write-text: " & e.msg, scope)
  NIL

proc biFsListDir(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Fs/list-dir expects (Fs/ReadDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsReadDir("Fs/list-dir", args[0])
  requireStr("Fs/list-dir path", args[1])
  if not dirExists(args[1].strVal):
    raiseOsError("Fs/list-dir: not a directory: " & args[1].strVal, scope)
  var names: seq[Value]
  try:
    for kind, path in walkDir(args[1].strVal, relative = true):
      names.add newStr(path)
  except OSError as e:
    raiseOsError("Fs/list-dir: " & e.msg, scope)
  newList(names)

proc biFsMakeDir(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Fs/make-dir expects (Fs/WriteDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsWriteDir("Fs/make-dir", args[0])
  requireStr("Fs/make-dir path", args[1])
  try:
    createDir(args[1].strVal)
  except OSError as e:
    raiseOsError("Fs/make-dir: " & e.msg, scope)
  NIL

proc biFsRemove(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Fs/remove expects (Fs/WriteDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsWriteDir("Fs/remove", args[0])
  requireStr("Fs/remove path", args[1])
  try:
    if fileExists(args[1].strVal):
      removeFile(args[1].strVal)
  except OSError as e:
    raiseOsError("Fs/remove: " & e.msg, scope)
  NIL

proc biFsRealPath(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Absolute, symlink-resolved form of a path (examples/ai_agent/design.md §8.5:
  ## protected-root checks must run on real paths). A path that does not exist
  ## yet resolves its longest existing ancestor and reattaches the remaining
  ## suffix, so a to-be-created file still confines correctly. A final symlink
  ## is followed even when its target does not exist yet — a dangling symlink
  ## must resolve to (and be checked against) where it would actually write,
  ## not treated as an ordinary in-workspace name.
  if args.len != 2:
    raise newException(GeneError, "Fs/real-path expects (Fs/ReadDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsReadDir("Fs/real-path", args[0])
  requireStr("Fs/real-path path", args[1])
  var p = if args[1].strVal.len > 0: args[1].strVal else: "."
  try:
    # Follow a chain of final symlinks whose target may not exist (a dangling
    # link fails fileExists/dirExists but symlinkExists still sees it), so the
    # returned path reflects the real destination. Bounded against loops.
    var hops = 0
    while symlinkExists(p) and not (fileExists(p) or dirExists(p)):
      var target = expandSymlink(p)
      if not isAbsolute(target):
        target = parentDir(absolutePath(p)) / target
      p = target
      inc hops
      if hops > 64:
        break
    if fileExists(p) or dirExists(p):
      return newStr(expandFilename(p))
    var base = normalizedPath(absolutePath(p))
    var tail: seq[string]
    while base.len > 0 and not dirExists(base):
      let (head, name) = splitPath(base)
      if head == base or head.len == 0:
        break
      tail.add name
      base = head
    var resolved = if dirExists(base): expandFilename(base) else: base
    for i in countdown(tail.high, 0):
      resolved = resolved / tail[i]
    newStr(normalizedPath(resolved))
  except OSError as e:
    raiseOsError("Fs/real-path: " & e.msg, scope)
    NIL

# --- json: parse and stringify over Gene value kinds (examples/ai_agent/design.md §5) ---

const jsonMaxDepth = 200

type JsonParser = object
  input: string
  pos: int
  scope: Scope

proc raiseJsonError(p: var JsonParser, message: string) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr("json/parse: " & message & " at offset " & $p.pos)
  var e: ref GeneError
  new(e)
  e.msg = "json/parse: " & message
  e.errVal = newNode(builtInTypeHead(p.scope, "JsonError"), props = props)
  e.hasErrVal = true
  raise e

proc raiseJsonValueError(scope: Scope, message: string) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(builtInTypeHead(scope, "JsonError"), props = props)
  e.hasErrVal = true
  raise e

proc jsonSkipWs(p: var JsonParser) =
  while p.pos < p.input.len and p.input[p.pos] in {' ', '\t', '\n', '\r'}:
    inc p.pos

proc parseJsonValue(p: var JsonParser, depth: int): Value

proc parseJsonString(p: var JsonParser): string =
  inc p.pos                             # opening quote
  var s = ""
  while true:
    if p.pos >= p.input.len:
      raiseJsonError(p, "unterminated string")
    let c = p.input[p.pos]
    if c == '"':
      inc p.pos
      return s
    elif c == '\\':
      inc p.pos
      if p.pos >= p.input.len:
        raiseJsonError(p, "unterminated escape")
      let e = p.input[p.pos]
      case e
      of '"': s.add '"'
      of '\\': s.add '\\'
      of '/': s.add '/'
      of 'b': s.add '\b'
      of 'f': s.add '\f'
      of 'n': s.add '\n'
      of 'r': s.add '\r'
      of 't': s.add '\t'
      of 'u':
        if p.pos + 4 >= p.input.len:
          raiseJsonError(p, "truncated \\u escape")
        let hex = p.input[p.pos + 1 .. p.pos + 4]
        var code = 0
        try:
          code = fromHex[int](hex)
        except ValueError:
          raiseJsonError(p, "invalid \\u escape")
        s.add toUTF8(Rune(code))
        p.pos += 4
      else:
        raiseJsonError(p, "invalid escape \\" & e)
      inc p.pos
    elif c < ' ':
      raiseJsonError(p, "control character in string")
    else:
      s.add c
      inc p.pos

proc parseJsonNumber(p: var JsonParser): Value =
  let start = p.pos
  var isFloat = false
  if p.pos < p.input.len and p.input[p.pos] == '-':
    inc p.pos
  while p.pos < p.input.len:
    let c = p.input[p.pos]
    if c in {'0'..'9'}:
      inc p.pos
    elif c in {'.', 'e', 'E', '+', '-'}:
      isFloat = true
      inc p.pos
    else:
      break
  let text = p.input[start ..< p.pos]
  if isFloat:
    try: newFloat(parseFloat(text))
    except ValueError: (raiseJsonError(p, "invalid number"); NIL)
  else:
    try: newInt(parseBiggestInt(text))
    except ValueError:
      try: newFloat(parseFloat(text))
      except ValueError: (raiseJsonError(p, "invalid number"); NIL)

proc jsonLiteral(p: var JsonParser, word: string, value: Value): Value =
  if p.pos + word.len <= p.input.len and
      p.input[p.pos ..< p.pos + word.len] == word:
    p.pos += word.len
    value
  else:
    raiseJsonError(p, "invalid literal")
    NIL

proc parseJsonValue(p: var JsonParser, depth: int): Value =
  if depth > jsonMaxDepth:
    raiseJsonError(p, "nesting too deep")
  jsonSkipWs(p)
  if p.pos >= p.input.len:
    raiseJsonError(p, "unexpected end of input")
  let c = p.input[p.pos]
  case c
  of '{':
    inc p.pos
    var entries = initOrderedTable[string, Value]()
    jsonSkipWs(p)
    if p.pos < p.input.len and p.input[p.pos] == '}':
      inc p.pos
      return newMap(entries)
    while true:
      jsonSkipWs(p)
      if p.pos >= p.input.len or p.input[p.pos] != '"':
        raiseJsonError(p, "expected object key string")
      let key = parseJsonString(p)
      jsonSkipWs(p)
      if p.pos >= p.input.len or p.input[p.pos] != ':':
        raiseJsonError(p, "expected ':' after object key")
      inc p.pos
      entries[key] = parseJsonValue(p, depth + 1)
      jsonSkipWs(p)
      if p.pos >= p.input.len:
        raiseJsonError(p, "unterminated object")
      if p.input[p.pos] == ',':
        inc p.pos
      elif p.input[p.pos] == '}':
        inc p.pos
        break
      else:
        raiseJsonError(p, "expected ',' or '}' in object")
    newMap(entries)
  of '[':
    inc p.pos
    var items: seq[Value]
    jsonSkipWs(p)
    if p.pos < p.input.len and p.input[p.pos] == ']':
      inc p.pos
      return newList(items)
    while true:
      items.add parseJsonValue(p, depth + 1)
      jsonSkipWs(p)
      if p.pos >= p.input.len:
        raiseJsonError(p, "unterminated array")
      if p.input[p.pos] == ',':
        inc p.pos
      elif p.input[p.pos] == ']':
        inc p.pos
        break
      else:
        raiseJsonError(p, "expected ',' or ']' in array")
    newList(items)
  of '"':
    newStr(parseJsonString(p))
  of '-', '0'..'9':
    parseJsonNumber(p)
  of 't':
    jsonLiteral(p, "true", TRUE)
  of 'f':
    jsonLiteral(p, "false", FALSE)
  of 'n':
    jsonLiteral(p, "null", NIL)
  else:
    raiseJsonError(p, "unexpected character '" & c & "'")
    NIL

proc biJsonParse(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("json/parse", args)
  requireStr("json/parse", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  var p = JsonParser(input: args[0].strVal, pos: 0, scope: scope)
  result = parseJsonValue(p, 0)
  jsonSkipWs(p)
  if p.pos != p.input.len:
    raiseJsonError(p, "trailing characters after JSON value")

proc jsonEscapeInto(s: string, into: var string) =
  into.add '"'
  for c in s:
    case c
    of '"': into.add "\\\""
    of '\\': into.add "\\\\"
    of '\b': into.add "\\b"
    of '\f': into.add "\\f"
    of '\n': into.add "\\n"
    of '\r': into.add "\\r"
    of '\t': into.add "\\t"
    else:
      if c < ' ':
        into.add "\\u"
        into.add toHex(ord(c), 4).toLowerAscii()
      else:
        into.add c
  into.add '"'

proc jsonStringifyInto(value: Value, into: var string, scope: Scope,
                       depth: int) =
  if depth > jsonMaxDepth:
    raiseJsonValueError(scope, "json/stringify: nesting too deep")
  case value.kind
  of vkNil, vkVoid: into.add "null"
  of vkBool: into.add (if value.boolVal: "true" else: "false")
  of vkInt: into.add $value.intVal
  of vkFloat: into.add $value.floatVal
  of vkString: jsonEscapeInto(value.strVal, into)
  of vkSymbol: jsonEscapeInto(value.symVal, into)
  of vkList:
    into.add '['
    var first = true
    for item in value.listItems:
      if not first: into.add ','
      first = false
      jsonStringifyInto(item, into, scope, depth + 1)
    into.add ']'
  of vkMap:
    into.add '{'
    var first = true
    for key, item in value.mapEntries:
      if not first: into.add ','
      first = false
      jsonEscapeInto(key, into)
      into.add ':'
      jsonStringifyInto(item, into, scope, depth + 1)
    into.add '}'
  else:
    raiseJsonValueError(scope, "json/stringify: cannot serialize a " &
                        $value.kind)

proc biJsonStringify(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("json/stringify", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  var buffer = ""
  jsonStringifyInto(args[0], buffer, scope, 0)
  newStr(buffer)


# --- serde: Gene-text serialization, data core -------------------------------
#
# Stage 1 of docs/proposals/serialization.md: write-data / read-data / data?
# over the data bucket, riding the canonical printer/reader. Serialized text is
# a (serde-v1 <payload>) envelope of ordinary Gene source. Control tags are
# dash-named plain symbols (serde-v1, serde-float, serde-sym, serde-map,
# serde-set, serde-range, serde-timezone, serde-duration, serde-data-node):
# slash tokens read back as (path ...) nodes, so slash-headed tags would not
# survive a print/read cycle. The design doc's serde/* names refer to these.
#
# Round-trip guarantee: (= v (read-data (write-data v))) under structural
# equality for every data-bucket value. Everything that would falsify it is
# either escaped (reserved heads, non-rereadable symbols and map keys, float
# specials) or rejected (cells and other identity/process-bound values).

const serdeReservedPrefix = "serde-"
const serdeDefaultMaxBytes = 10_485_760
const serdeDefaultMaxNodes = 100_000
const serdeDefaultMaxDepth = 1_000
const serdeDefaultMaxSymbols = 10_000

type SerdePolicyLimits = object
  maxBytes: int
  maxNodes: int
  maxDepth: int
  maxSymbols: int
  allowRestore: bool   # serde-hooked serde-restore runs user code; off by default

type SerdeWriter = object
  sb: string
  scope: Scope
  app: Application                  # nil unless allowRefs (origin resolution)
  allowRefs: bool                   # serde/write emits refs; write-data errors
  path: seq[string]
  onPath: HashSet[uint64]           # container identities on the current path
  symCache: Table[string, bool]     # symbol text -> re-reads verbatim
  keyCache: Table[string, bool]     # prop key -> usable as ^key literal

type SerdeReader = object
  scope: Scope
  app: Application                  # nil unless resolveRefs
  resolveRefs: bool                 # serde/read resolves refs; read-data errors
  limits: SerdePolicyLimits
  nodes: int
  symbols: HashSet[string]
  path: seq[string]

proc serdePathText(path: seq[string]): string =
  if path.len == 0: "payload" else: path.join("/")

proc raiseSerdeError(scope: Scope, message: string, path: seq[string] = @[]) =
  var full = message
  if path.len > 0:
    full = "at " & serdePathText(path) & ": " & message
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(full)
  props["path"] = newStr(serdePathText(path))
  var e: ref GeneError
  new(e)
  e.msg = full
  e.errVal = newNode(builtInTypeHead(scope, "SerdeError"), props = props)
  e.hasErrVal = true
  raise e

proc serdeFastBareName(s: string): bool =
  ## Common identifiers and property keys can be accepted without probing the
  ## reader. Unusual spellings still use the authoritative read-back check.
  if s.len == 0 or s in ["true", "false", "nil", "void"] or
      s.startsWith(serdeReservedPrefix) or s.endsWith("..."):
    return false
  if s[0] notin {'A'..'Z', 'a'..'z', '_'}:
    return false
  for c in s:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '-', '?', '!', '*'}:
      return false
  true

proc serdeSymbolRereads(w: var SerdeWriter, s: string): bool =
  ## A symbol is emitted verbatim only when its text reads back as the same
  ## symbol. Probing the real reader is authoritative — no second grammar.
  if s in w.symCache:
    return w.symCache[s]
  if serdeFastBareName(s):
    w.symCache[s] = true
    return true
  var ok = false
  if s.len > 0:
    try:
      let forms = readAll(s)
      ok = forms.len == 1 and forms[0].kind == vkSymbol and
           forms[0].symVal == s
    except CatchableError:
      ok = false
  w.symCache[s] = ok
  ok

proc serdePropKeyUsable(w: var SerdeWriter, k: string): bool =
  ## A prop key is emitted as `^key` only if that text reads back to the same
  ## single-entry map. Otherwise the whole container uses the serde-map escape.
  if k in w.keyCache:
    return w.keyCache[k]
  if serdeFastBareName(k):
    w.keyCache[k] = true
    return true
  var ok = false
  if k.len > 0:
    try:
      let forms = readAll("{^" & k & " 1}")
      if forms.len == 1 and forms[0].kind == vkMap:
        var count = 0
        var hit = false
        for key, val in forms[0].mapEntries:
          inc count
          if key == k and val.kind == vkInt and val.intVal == 1:
            hit = true
        ok = count == 1 and hit
    except CatchableError:
      ok = false
  w.keyCache[k] = ok
  ok

proc serdeEmitStrLit(w: var SerdeWriter, s: string) =
  w.sb.add print(newStr(s))

# --- origin index (stage 3): definition value -> (module, internal path) -----

proc serdeModuleRelPath(app: Application, absPath: string): string =
  ## Package-root-relative module identity without extension, '/'-separated.
  ## Matches what resolveModulePath accepts as a bare path, so refs resolve the
  ## same on any machine.
  let root = normalizedPath(absolutePath(app.packageRoot))
  var rel = absPath
  let prefix = (if root.len > 0 and root[^1] == DirSep: root else: root & $DirSep)
  if absPath.startsWith(prefix):
    rel = absPath[prefix.len .. ^1]
  if rel.endsWith(".gene"):
    rel = rel[0 ..< rel.len - ".gene".len]
  when DirSep != '/':
    rel = rel.replace($DirSep, "/")
  rel

proc serdeRecordOrigin(app: Application, v: Value, module, path: string) =
  ## First name wins for a given value, so a stable path is chosen across
  ## re-scans and alias bindings. The index keys by value bits and assumes
  ## module definitions stay rooted for the Application lifetime; collectible
  ## modules must invalidate these tables before value bits can be reused.
  if not app.serdeOrigins.hasKey(v.bits):
    app.serdeOrigins[v.bits] = (module: module, path: path)

proc serdeIndexScope(app: Application, scope: Scope, module: string,
                     prefix: string, visited: var HashSet[pointer])

proc serdeIndexBinding(app: Application, name: string, val: Value,
                       module, prefix: string, visited: var HashSet[pointer]) =
  let internal = if prefix.len == 0: name else: prefix & "/" & name
  case val.kind
  of vkType:
    serdeRecordOrigin(app, val, module, internal)
    if val.isEnumType:
      for variant in val.enumVariants:
        serdeRecordOrigin(app, variant, module,
                          internal & "/" & variant.enumVariantName)
  of vkProtocol, vkFunction, vkNativeFn:
    serdeRecordOrigin(app, val, module, internal)
  of vkNamespace:
    serdeRecordOrigin(app, val, module, internal)
    serdeIndexScope(app, val.nsScope, module, internal, visited)
  of vkNode:
    # A module-level typed instance is a candidate for a SerdeRef value ref.
    # Only nodes (heap objects, unique bits) are recorded — scalars would
    # collide with unrelated equal values.
    if val.head.kind == vkType and not app.serdeValueOrigins.hasKey(val.bits):
      app.serdeValueOrigins[val.bits] = (module: module, path: internal)
  else:
    discard

proc serdeIndexScope(app: Application, scope: Scope, module: string,
                     prefix: string, visited: var HashSet[pointer]) =
  if scope == nil:
    return
  let key = cast[pointer](scope)
  if key in visited:
    return
  visited.incl key
  for name, val in scope.vars:
    serdeIndexBinding(app, name, val, module, prefix, visited)
  for i in 0 ..< scope.slots.len:
    if i < scope.slotNames.len and scope.slotDefined(i):
      serdeIndexBinding(app, scope.slotNames[i], scope.slots[i],
                        module, prefix, visited)

proc serdeEnsureOrigins(app: Application) =
  ## Build the reverse index lazily: builtins once, plus any module cached
  ## since the last call. Cheap re-scan (skips already-indexed modules).
  if app == nil:
    return
  var visited = initHashSet[pointer]()
  if not app.serdeOriginBuiltinsDone:
    serdeIndexScope(app, app.builtinsScope(), "", "", visited)
    app.serdeOriginBuiltinsDone = true
  for absPath, modVal in app.moduleCache:
    if absPath in app.serdeOriginModules:
      continue
    app.serdeOriginModules.incl absPath
    if modVal.kind == vkModule:
      let rootNs = modVal.moduleRootNamespace
      if rootNs.kind == vkNamespace:
        serdeIndexScope(app, rootNs.nsScope,
                        serdeModuleRelPath(app, absPath), "", visited)

proc serdeOriginOf(w: var SerdeWriter, v: Value):
    tuple[found: bool, module, path: string] =
  if w.app == nil:
    return (false, "", "")
  serdeEnsureOrigins(w.app)
  if w.app.serdeOrigins.hasKey(v.bits):
    let o = w.app.serdeOrigins[v.bits]
    (true, o.module, o.path)
  else:
    (false, "", "")

proc serdeEmit(w: var SerdeWriter, v: Value)
proc serdeEmitInst(w: var SerdeWriter, v: Value)

proc serdeEmitRef(w: var SerdeWriter, tag, module, path: string) =
  w.sb.add "(" & tag
  if module.len > 0:
    w.sb.add " ^module "
    serdeEmitStrLit(w, module)
  w.sb.add " ^path "
  serdeEmitStrLit(w, path)
  w.sb.add ')'

proc serdeEmitDefRef(w: var SerdeWriter, v: Value, tag, kindLabel: string) =
  if not w.allowRefs:
    raiseSerdeError(w.scope,
      kindLabel & " values are not data (use serde/write to emit a reference)",
      w.path)
  let o = serdeOriginOf(w, v)
  if not o.found:
    raiseSerdeError(w.scope,
      kindLabel & " has no module origin and cannot be referenced " &
      "(defined at runtime, in a function body, or anonymously)", w.path)
  serdeEmitRef(w, tag, o.module, o.path)

proc serdeEnterContainer(w: var SerdeWriter, v: Value) =
  if v.bits in w.onPath:
    raiseSerdeError(w.scope, "cycle detected", w.path)
  w.onPath.incl v.bits

proc serdeLeaveContainer(w: var SerdeWriter, v: Value) =
  w.onPath.excl v.bits

proc serdeEmitMapBody(w: var SerdeWriter, entries: PropTable) =
  ## Emit `^k v` pairs; caller guarantees every key is usable.
  var first = true
  for k, val in entries:
    if not first: w.sb.add ' '
    first = false
    w.sb.add "^" & k & " "
    w.path.add k
    serdeEmit(w, val)
    discard w.path.pop()

proc serdeMapKeysUsable(w: var SerdeWriter, entries: PropTable): bool =
  for k, _ in entries:
    if not serdePropKeyUsable(w, k):
      return false
  true

proc serdeEmitEscapedMap(w: var SerdeWriter, entries: PropTable,
                         immutable: bool) =
  ## (serde-map <immutable> [k1 v1 k2 v2 ...]) — keys as strings.
  w.sb.add "(serde-map "
  w.sb.add (if immutable: "true" else: "false")
  w.sb.add " ["
  var first = true
  for k, val in entries:
    if not first: w.sb.add ' '
    first = false
    serdeEmitStrLit(w, k)
    w.sb.add ' '
    w.path.add k
    serdeEmit(w, val)
    discard w.path.pop()
  w.sb.add "])"

proc serdeEmitMapValue(w: var SerdeWriter, entries: PropTable,
                       immutable: bool) =
  if serdeMapKeysUsable(w, entries):
    w.sb.add (if immutable: "#{" else: "{")
    serdeEmitMapBody(w, entries)
    w.sb.add '}'
  else:
    serdeEmitEscapedMap(w, entries, immutable)

proc serdeNodeNeedsEscape(w: var SerdeWriter, v: Value): bool =
  if v.head.kind == vkSymbol and v.head.symVal.startsWith(serdeReservedPrefix):
    return true
  for k, _ in v.props:
    if not serdePropKeyUsable(w, k):
      return true
  for k, _ in v.meta:
    if not serdePropKeyUsable(w, k):
      return true
  false

proc serdeEmit(w: var SerdeWriter, v: Value) =
  if v.isNil:
    w.sb.add "nil"
    return
  case v.kind
  of vkNil, vkVoid, vkBool, vkInt, vkString, vkBytes, vkChar,
     vkDate, vkTime, vkDateTime, vkRegex:
    w.sb.add print(v)
  of vkFloat:
    let f = v.floatVal
    if f != f:
      w.sb.add "(serde-float \"nan\")"
    elif f == Inf:
      w.sb.add "(serde-float \"+inf\")"
    elif f == NegInf:
      w.sb.add "(serde-float \"-inf\")"
    elif f == 0.0 and 1.0 / f == NegInf:
      w.sb.add "(serde-float \"-0.0\")"
    else:
      w.sb.add print(v)
  of vkSymbol:
    if serdeSymbolRereads(w, v.symVal):
      w.sb.add v.symVal
    else:
      w.sb.add "(serde-sym "
      serdeEmitStrLit(w, v.symVal)
      w.sb.add ')'
  of vkTimezone:
    w.sb.add "(serde-timezone "
    w.sb.add (if v.timezoneHasOffset: "true " else: "false ")
    w.sb.add $v.timezoneOffsetMinutes & " "
    serdeEmitStrLit(w, v.timezoneName)
    w.sb.add ')'
  of vkDuration:
    w.sb.add "(serde-duration " & $v.durationMicroseconds & ")"
  of vkRange:
    w.sb.add "(serde-range " & $v.rangeStart & " " & $v.rangeStop & " " &
             $v.rangeStep & " " &
             (if v.rangeInclusive: "true" else: "false") & ")"
  of vkSet:
    serdeEnterContainer(w, v)
    w.sb.add "(serde-set"
    for i, it in v.setItems:
      w.sb.add ' '
      w.path.add $i
      serdeEmit(w, it)
      discard w.path.pop()
    w.sb.add ')'
    serdeLeaveContainer(w, v)
  of vkList:
    serdeEnterContainer(w, v)
    w.sb.add (if v.listImmutable: "#[" else: "[")
    for i, it in v.listItems:
      if i > 0: w.sb.add ' '
      w.path.add $i
      serdeEmit(w, it)
      discard w.path.pop()
    w.sb.add ']'
    serdeLeaveContainer(w, v)
  of vkMap:
    serdeEnterContainer(w, v)
    serdeEmitMapValue(w, v.mapEntries, v.mapImmutable)
    serdeLeaveContainer(w, v)
  of vkHashMap:
    serdeEnterContainer(w, v)
    w.sb.add "{{"
    var first = true
    for entry in v.hashMapEntries:
      if not first: w.sb.add ' '
      first = false
      w.path.add "key"
      serdeEmit(w, entry.key)
      discard w.path.pop()
      w.sb.add " : "
      w.path.add "val"
      serdeEmit(w, entry.val)
      discard w.path.pop()
    w.sb.add "}}"
    serdeLeaveContainer(w, v)
  of vkNode:
    serdeEnterContainer(w, v)
    if v.head.kind == vkType or v.head.kind == vkEnumVariant:
      serdeEmitInst(w, v)
      serdeLeaveContainer(w, v)
      return
    if serdeNodeNeedsEscape(w, v):
      # (serde-data-node <immutable> <head> <props-map> <meta-map> <child>*)
      w.sb.add "(serde-data-node "
      w.sb.add (if v.nodeImmutable: "true " else: "false ")
      w.path.add "head"
      serdeEmit(w, v.head)
      discard w.path.pop()
      w.sb.add ' '
      serdeEmitEscapedMap(w, v.props, false)
      w.sb.add ' '
      serdeEmitEscapedMap(w, v.meta, false)
      for i, it in v.body:
        w.sb.add ' '
        w.path.add $i
        serdeEmit(w, it)
        discard w.path.pop()
      w.sb.add ')'
    else:
      w.sb.add (if v.nodeImmutable: "#(" else: "(")
      w.path.add "head"
      serdeEmit(w, v.head)
      discard w.path.pop()
      if v.meta.len > 0:
        w.sb.add ' '
        var first = true
        for k, val in v.meta:
          if not first: w.sb.add ' '
          first = false
          w.sb.add "@" & k & " "
          w.path.add k
          serdeEmit(w, val)
          discard w.path.pop()
      if v.props.len > 0:
        w.sb.add ' '
        serdeEmitMapBody(w, v.props)
      for i, it in v.body:
        w.sb.add ' '
        w.path.add $i
        serdeEmit(w, it)
        discard w.path.pop()
      w.sb.add ')'
    serdeLeaveContainer(w, v)
  of vkType:
    if v.isEnumType:
      serdeEmitDefRef(w, v, "serde-enum-ref", "enum")
    else:
      serdeEmitDefRef(w, v, "serde-type-ref", "type")
  of vkProtocol:
    serdeEmitDefRef(w, v, "serde-protocol-ref", "protocol")
  of vkEnumVariant:
    serdeEmitDefRef(w, v, "serde-variant-ref", "enum variant")
  of vkNamespace:
    serdeEmitDefRef(w, v, "serde-ns-ref", "namespace")
  of vkNativeFn:
    serdeEmitDefRef(w, v, "serde-fn-ref", "native function")
  of vkFunction:
    if w.allowRefs and serdeOriginOf(w, v).found:
      serdeEmitDefRef(w, v, "serde-fn-ref", "function")
    elif w.allowRefs:
      raiseSerdeError(w.scope,
        "functions with captured scope do not serialize (only module-level " &
        "named functions can be referenced)", w.path)
    else:
      raiseSerdeError(w.scope,
        "functions are not data (use serde/write to reference a module-level " &
        "function)", w.path)
  of vkCell:
    if w.allowRefs:
      # Snapshot only, and OUTSIDE the round-trip equality guarantee: identity
      # and sharing are not preserved (design §7). read-data still rejects it.
      w.sb.add "(serde-snapshot-cell "
      w.path.add "cell"
      serdeEmit(w, cellValue(v))
      discard w.path.pop()
      w.sb.add ')'
    else:
      raiseSerdeError(w.scope,
        "cells are not data (identity equality; serialize the contents via " &
        "Cell/get, or use serde/write for a snapshot)", w.path)
  of vkAtomicCell:
    raiseSerdeError(w.scope,
      "atomic cells do not serialize (shared-memory escape hatch; serialize " &
      "a loaded snapshot instead)", w.path)
  of vkCapability:
    raiseSerdeError(w.scope,
      "capability values never serialize (authority does not round-trip " &
      "through data)", w.path)
  else:
    raiseSerdeError(w.scope,
      $v.kind & " values do not serialize (process-bound)", w.path)

proc serdeTypeIsSerdeRef(scope: Scope, typ: Value): bool =
  if scope == nil or typ.kind != vkType:
    return false
  var proto: Value
  if not scope.lookupOptional("SerdeRef", proto) or proto.kind != vkProtocol:
    return false
  typeImplementsProtocol(scope, typ, proto)

proc serdeEmitInst(w: var SerdeWriter, v: Value) =
  ## A typed instance: (serde-inst <head-ref> <props-serde-map> [body...]).
  ## Read-back uses direct typed-data construction (never ctor), so the head
  ## must be a resolvable type or enum variant.
  ##
  ## A module-level instance of a SerdeRef-marked type serializes by identity
  ## (serde-value-ref); a type with a `serde-state` type-direct message
  ## serializes its state (serde-hooked, ^allow-restore on read); otherwise
  ## fields (design §7).
  if not w.allowRefs:
    raiseSerdeError(w.scope,
      "typed instances are not data (use serde/write)", w.path)
  if v.head.kind == vkType and w.app != nil:
    serdeEnsureOrigins(w.app)
    if w.app.serdeValueOrigins.hasKey(v.bits) and
        serdeTypeIsSerdeRef(w.scope, v.head):
      let o = w.app.serdeValueOrigins[v.bits]
      serdeEmitRef(w, "serde-value-ref", o.module, o.path)
      return
  if v.head.kind == vkType:
    let stateFn = typeDirectMessage(v.head, "serde-state")
    if stateFn.kind != vkNil:
      let state = applyCall(stateFn, [v], NamedArgs(), w.scope)
      w.sb.add "(serde-hooked "
      w.path.add "type"
      serdeEmit(w, v.head)
      discard w.path.pop()
      w.sb.add ' '
      w.path.add "state"
      serdeEmit(w, state)
      discard w.path.pop()
      w.sb.add ')'
      return
  if v.head.kind == vkEnumVariant and v.props.len > 0:
    raiseSerdeError(w.scope,
      "enum-variant value unexpectedly carries props", w.path)
  w.sb.add "(serde-inst "
  w.path.add "type"
  serdeEmit(w, v.head)              # emits serde-type-ref / serde-variant-ref
  discard w.path.pop()
  w.sb.add ' '
  serdeEmitEscapedMap(w, v.props, false)
  w.sb.add " ["
  for i, it in v.body:
    if i > 0: w.sb.add ' '
    w.path.add $i
    serdeEmit(w, it)
    discard w.path.pop()
  w.sb.add "])"

proc serdeDataValueP(v: Value, onPath: var HashSet[uint64]): bool =
  if v.isNil:
    return true
  case v.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkBytes, vkChar,
     vkDate, vkTime, vkDateTime, vkRegex, vkSymbol, vkTimezone, vkDuration,
     vkRange:
    true
  of vkList:
    if v.bits in onPath:
      return false
    onPath.incl v.bits
    for it in v.listItems:
      if not serdeDataValueP(it, onPath):
        onPath.excl v.bits
        return false
    onPath.excl v.bits
    true
  of vkMap:
    if v.bits in onPath:
      return false
    onPath.incl v.bits
    for _, val in v.mapEntries:
      if not serdeDataValueP(val, onPath):
        onPath.excl v.bits
        return false
    onPath.excl v.bits
    true
  of vkSet:
    if v.bits in onPath:
      return false
    onPath.incl v.bits
    for it in v.setItems:
      if not serdeDataValueP(it, onPath):
        onPath.excl v.bits
        return false
    onPath.excl v.bits
    true
  of vkHashMap:
    if v.bits in onPath:
      return false
    onPath.incl v.bits
    for entry in v.hashMapEntries:
      if not serdeDataValueP(entry.key, onPath) or
          not serdeDataValueP(entry.val, onPath):
        onPath.excl v.bits
        return false
    onPath.excl v.bits
    true
  of vkNode:
    if v.head.kind in {vkType, vkEnumVariant}:
      return false
    if v.bits in onPath:
      return false
    onPath.incl v.bits
    if not serdeDataValueP(v.head, onPath):
      onPath.excl v.bits
      return false
    for _, val in v.props:
      if not serdeDataValueP(val, onPath):
        onPath.excl v.bits
        return false
    for _, val in v.meta:
      if not serdeDataValueP(val, onPath):
        onPath.excl v.bits
        return false
    for it in v.body:
      if not serdeDataValueP(it, onPath):
        onPath.excl v.bits
        return false
    onPath.excl v.bits
    true
  else:
    false

proc serdeDataValueP(v: Value): bool =
  var onPath = initHashSet[uint64]()
  serdeDataValueP(v, onPath)

proc serdeWriteDataText(v: Value, scope: Scope): string =
  var w = SerdeWriter(scope: scope)
  w.sb.add "(serde-v1 "
  serdeEmit(w, v)
  w.sb.add ')'
  w.sb

proc serdeWriteFullText(v: Value, scope: Scope): string =
  var w = SerdeWriter(scope: scope, allowRefs: true,
                      app: application(scope))
  w.sb.add "(serde-v1 "
  serdeEmit(w, v)
  w.sb.add ')'
  w.sb

proc serdePolicyInt(policy: Value, key: string, fallback: int,
                    scope: Scope): int =
  let entries =
    if policy.kind == vkNode: policy.props
    elif policy.kind == vkMap: policy.mapEntries
    else:
      raiseSerdeError(scope, "^policy expects a SerdePolicy or Map")
      return fallback
  let v = entries.getOrDefault(key, VOID)
  if v.kind == vkVoid:
    return fallback
  if v.kind != vkInt:
    raiseSerdeError(scope, "^policy " & key & " must be an Int")
  int(v.intVal)

proc serdePolicyBool(policy: Value, key: string, fallback: bool,
                     scope: Scope): bool =
  let entries =
    if policy.kind == vkNode: policy.props
    elif policy.kind == vkMap: policy.mapEntries
    else: return fallback
  let v = entries.getOrDefault(key, VOID)
  if v.kind == vkVoid:
    return fallback
  if v.kind != vkBool:
    raiseSerdeError(scope, "^policy " & key & " must be a Bool")
  v.boolVal

proc serdeLimitsFrom(policy: Value, scope: Scope): SerdePolicyLimits =
  result = SerdePolicyLimits(maxBytes: serdeDefaultMaxBytes,
                             maxNodes: serdeDefaultMaxNodes,
                             maxDepth: serdeDefaultMaxDepth,
                             maxSymbols: serdeDefaultMaxSymbols,
                             allowRestore: false)
  if policy.kind == vkNil or policy.kind == vkVoid:
    return
  result.maxBytes = serdePolicyInt(policy, "max-bytes", result.maxBytes, scope)
  result.maxNodes = serdePolicyInt(policy, "max-nodes", result.maxNodes, scope)
  result.maxDepth = serdePolicyInt(policy, "max-depth", result.maxDepth, scope)
  result.maxSymbols = serdePolicyInt(policy, "max-symbols",
                                     result.maxSymbols, scope)
  result.allowRestore = serdePolicyBool(policy, "allow-restore",
                                        result.allowRestore, scope)

proc serdeDecode(r: var SerdeReader, v: Value, depth: int): Value

proc serdeCountValue(r: var SerdeReader, depth: int) =
  inc r.nodes
  if r.nodes > r.limits.maxNodes:
    raiseSerdeError(r.scope, "payload exceeds max-nodes (" &
                    $r.limits.maxNodes & ")", r.path)
  if depth > r.limits.maxDepth:
    raiseSerdeError(r.scope, "payload exceeds max-depth (" &
                    $r.limits.maxDepth & ")", r.path)

proc serdeCountSymbol(r: var SerdeReader, s: string) =
  r.symbols.incl s
  if r.symbols.len > r.limits.maxSymbols:
    raiseSerdeError(r.scope, "payload exceeds max-symbols (" &
                    $r.limits.maxSymbols & ")", r.path)

proc serdeBodyLen(r: var SerdeReader, v: Value, tag: string, n: int) =
  if v.body.len != n or v.props.len > 0 or v.meta.len > 0:
    raiseSerdeError(r.scope, tag & " expects exactly " & $n &
                    " children and no props", r.path)

# --- reference resolution (stage 3): (module, path) -> definition value ------

proc serdeRefCoords(r: var SerdeReader, v: Value, tag: string):
    tuple[module, path: string] =
  ## Extract ^module (optional) + ^path (required) from a ref node. Any other
  ## prop — notably the reserved ^package/^version — is an error, so old
  ## readers reject payloads that start using them (design §5).
  if v.body.len > 0 or v.meta.len > 0:
    raiseSerdeError(r.scope, tag & " takes only ^module/^path props", r.path)
  var module = ""
  var path = ""
  var havePath = false
  for k, val in v.props:
    case k
    of "module":
      if val.kind != vkString:
        raiseSerdeError(r.scope, tag & " ^module must be a Str", r.path)
      module = val.strVal
    of "path":
      if val.kind != vkString:
        raiseSerdeError(r.scope, tag & " ^path must be a Str", r.path)
      path = val.strVal
      havePath = true
    else:
      raiseSerdeError(r.scope,
        tag & " has unsupported ref feature ^" & k &
        " (^package/^version are reserved for a later version)", r.path)
  if not havePath or path.len == 0:
    raiseSerdeError(r.scope, tag & " requires a non-empty ^path", r.path)
  (module, path)

proc serdeScopeLookupOwn(scope: Scope, name: string):
    tuple[found: bool, value: Value] =
  ## Look up a name in a scope's OWN bindings only (never parents), so module
  ## resolution cannot leak into builtins and vice versa.
  if scope == nil:
    return (false, NIL)
  if scope.vars.hasKey(name):
    return (true, scope.vars.getOrDefault(name))
  for i in 0 ..< scope.slots.len:
    if i < scope.slotNames.len and scope.slotDefined(i) and
        scope.slotNames[i] == name:
      return (true, scope.slots[i])
  (false, NIL)

proc serdeResolveModuleScope(r: var SerdeReader, module: string): Scope =
  ## The scope to resolve a ref path against. Builtins for module=="". For a
  ## named module, the module must already be loaded — resolution NEVER loads
  ## it (loading executes top-level code; design §6). Missing -> unresolved.
  if module.len == 0:
    return r.app.builtinsScope()
  var absPath: string
  try:
    absPath = r.app.resolveModulePath(module)
  except CatchableError as e:
    raiseSerdeError(r.scope, "cannot resolve module '" & module & "': " &
                    e.msg, r.path)
  if not r.app.moduleCache.hasKey(absPath):
    raiseSerdeError(r.scope, "module not loaded: " & module &
      " (import it before deserializing references to it)", r.path)
  let modVal = r.app.moduleCache.getOrDefault(absPath)
  if modVal.kind != vkModule:
    raiseSerdeError(r.scope, "module '" & module & "' is not a module", r.path)
  let rootNs = modVal.moduleRootNamespace
  if rootNs.kind != vkNamespace:
    raiseSerdeError(r.scope, "module '" & module & "' has no root namespace",
                    r.path)
  rootNs.nsScope

proc serdeLookupRefPath(r: var SerdeReader, startScope: Scope,
                        module, path: string): Value =
  let segs = path.split('/')
  var lookupIn = serdeScopeLookupOwn(startScope, segs[0])
  if not lookupIn.found:
    raiseSerdeError(r.scope, "unresolved reference: '" & path &
      "' in " & (if module.len == 0: "builtins" else: module), r.path)
  var cur = lookupIn.value
  for i in 1 ..< segs.len:
    let seg = segs[i]
    if cur.kind == vkNamespace:
      let nxt = serdeScopeLookupOwn(cur.nsScope, seg)
      if not nxt.found:
        raiseSerdeError(r.scope, "unresolved reference: '" & path & "'", r.path)
      cur = nxt.value
    elif cur.kind == vkType and cur.isEnumType and i == segs.len - 1:
      let variant = enumVariantDescriptor(cur, seg)
      if variant.kind == vkVoid:
        raiseSerdeError(r.scope, "unresolved enum variant: '" & path & "'",
                        r.path)
      cur = variant
    else:
      raiseSerdeError(r.scope, "unresolved reference: '" & path &
        "' (cannot descend into " & $cur.kind & ")", r.path)
  cur

proc serdeResolveRef(r: var SerdeReader, v: Value, tag: string): Value =
  if not r.resolveRefs:
    raiseSerdeError(r.scope,
      tag & " requires serde/read (serde/read-data accepts pure data only)",
      r.path)
  let coords = serdeRefCoords(r, v, tag)
  let startScope = serdeResolveModuleScope(r, coords.module)
  let resolved = serdeLookupRefPath(r, startScope, coords.module, coords.path)
  let ok =
    case tag
    of "serde-type-ref": resolved.kind == vkType and not resolved.isEnumType
    of "serde-enum-ref": resolved.kind == vkType and resolved.isEnumType
    of "serde-protocol-ref": resolved.kind == vkProtocol
    of "serde-variant-ref": resolved.kind == vkEnumVariant
    of "serde-ns-ref": resolved.kind == vkNamespace
    of "serde-fn-ref": resolved.kind in {vkFunction, vkNativeFn}
    else: false
  if not ok:
    raiseSerdeError(r.scope, tag & " resolved to a " & $resolved.kind &
      ", not the expected kind, at '" & coords.path & "'", r.path)
  resolved

proc serdeResolveValueRef(r: var SerdeReader, v: Value): Value =
  ## Resolve a module-level binding by identity — no kind check: it returns the
  ## module's own object (design §7 identity semantics).
  if not r.resolveRefs:
    raiseSerdeError(r.scope,
      "serde-value-ref requires serde/read (serde/read-data accepts pure " &
      "data only)", r.path)
  let coords = serdeRefCoords(r, v, "serde-value-ref")
  let startScope = serdeResolveModuleScope(r, coords.module)
  serdeLookupRefPath(r, startScope, coords.module, coords.path)

proc serdeDecodeControl(r: var SerdeReader, v: Value, tag: string,
                        depth: int): Value =
  case tag
  of "serde-type-ref", "serde-enum-ref", "serde-protocol-ref",
     "serde-variant-ref", "serde-ns-ref", "serde-fn-ref":
    return serdeResolveRef(r, v, tag)
  of "serde-value-ref":
    return serdeResolveValueRef(r, v)
  else: discard
  case tag
  of "serde-float":
    serdeBodyLen(r, v, tag, 1)
    if v.body[0].kind != vkString:
      raiseSerdeError(r.scope, "serde-float expects a Str", r.path)
    case v.body[0].strVal
    of "nan": newFloat(NaN)
    of "+inf": newFloat(Inf)
    of "-inf": newFloat(NegInf)
    of "-0.0": newFloat(-0.0)
    else:
      raiseSerdeError(r.scope, "unknown serde-float value: " &
                      v.body[0].strVal, r.path)
      NIL
  of "serde-sym":
    serdeBodyLen(r, v, tag, 1)
    if v.body[0].kind != vkString:
      raiseSerdeError(r.scope, "serde-sym expects a Str", r.path)
    serdeCountSymbol(r, v.body[0].strVal)
    newSym(v.body[0].strVal)
  of "serde-set":
    if v.props.len > 0 or v.meta.len > 0:
      raiseSerdeError(r.scope, "serde-set expects no props", r.path)
    var items: seq[Value]
    for i, it in v.body:
      r.path.add $i
      let item = serdeDecode(r, it, depth + 1)
      if not isHashStable(item):
        raiseSerdeError(r.scope,
          "serde-set element is not hash-stable", r.path)
      for existing in items:
        if equal(existing, item):
          raiseSerdeError(r.scope,
            "serde-set contains a duplicate element", r.path)
      items.add item
      discard r.path.pop()
    newSet(items)
  of "serde-range":
    serdeBodyLen(r, v, tag, 4)
    for i in 0 .. 2:
      if v.body[i].kind != vkInt:
        raiseSerdeError(r.scope, "serde-range expects Int bounds", r.path)
    if v.body[3].kind != vkBool:
      raiseSerdeError(r.scope, "serde-range expects a Bool inclusive flag",
                      r.path)
    try:
      newRange(v.body[0].intVal, v.body[1].intVal, v.body[2].intVal,
               v.body[3].boolVal)
    except GeneError as e:
      raiseSerdeError(r.scope, "serde-range: " & e.msg, r.path)
      NIL
  of "serde-timezone":
    serdeBodyLen(r, v, tag, 3)
    if v.body[0].kind != vkBool or v.body[1].kind != vkInt or
        v.body[2].kind != vkString:
      raiseSerdeError(r.scope,
        "serde-timezone expects (Bool Int Str)", r.path)
    try:
      newTimezone(v.body[0].boolVal, int(v.body[1].intVal), v.body[2].strVal)
    except GeneError as e:
      raiseSerdeError(r.scope, "serde-timezone: " & e.msg, r.path)
      NIL
  of "serde-duration":
    serdeBodyLen(r, v, tag, 1)
    if v.body[0].kind != vkInt:
      raiseSerdeError(r.scope, "serde-duration expects an Int", r.path)
    newDuration(v.body[0].intVal)
  of "serde-map":
    serdeBodyLen(r, v, tag, 2)
    if v.body[0].kind != vkBool or v.body[1].kind != vkList:
      raiseSerdeError(r.scope,
        "serde-map expects (Bool [k v ...])", r.path)
    let items = v.body[1].listItems
    if items.len mod 2 != 0:
      raiseSerdeError(r.scope, "serde-map expects an even k/v list", r.path)
    var entries = initOrderedTable[string, Value]()
    var i = 0
    while i < items.len:
      if items[i].kind != vkString:
        raiseSerdeError(r.scope, "serde-map keys must be Str", r.path)
      let key = items[i].strVal
      if entries.hasKey(key):
        raiseSerdeError(r.scope, "serde-map duplicate key: " & key, r.path)
      r.path.add key
      entries[key] = serdeDecode(r, items[i + 1], depth + 1)
      discard r.path.pop()
      inc i, 2
    newMap(entries, immutable = v.body[0].boolVal)
  of "serde-data-node":
    if v.body.len < 4 or v.props.len > 0 or v.meta.len > 0:
      raiseSerdeError(r.scope,
        "serde-data-node expects (Bool head props meta child*)", r.path)
    if v.body[0].kind != vkBool:
      raiseSerdeError(r.scope,
        "serde-data-node expects a Bool immutable flag", r.path)
    r.path.add "head"
    let head = serdeDecode(r, v.body[1], depth + 1)
    discard r.path.pop()
    r.path.add "props"
    let propsVal = serdeDecode(r, v.body[2], depth + 1)
    discard r.path.pop()
    r.path.add "meta"
    let metaVal = serdeDecode(r, v.body[3], depth + 1)
    discard r.path.pop()
    if propsVal.kind != vkMap or metaVal.kind != vkMap:
      raiseSerdeError(r.scope,
        "serde-data-node props/meta must decode to maps", r.path)
    var children: seq[Value]
    for i in 4 ..< v.body.len:
      r.path.add $(i - 4)
      children.add serdeDecode(r, v.body[i], depth + 1)
      discard r.path.pop()
    var props = initOrderedTable[string, Value]()
    for k, val in propsVal.mapEntries:
      props[k] = val
    var meta = initOrderedTable[string, Value]()
    for k, val in metaVal.mapEntries:
      meta[k] = val
    newNode(head, props = props, body = children, meta = meta,
            immutable = v.body[0].boolVal)
  of "serde-inst":
    if not r.resolveRefs:
      raiseSerdeError(r.scope,
        "serde-inst requires serde/read (serde/read-data accepts pure data " &
        "only)", r.path)
    for k, val in v.props:
      if k == "schema-version":
        if val.kind != vkInt:
          raiseSerdeError(r.scope,
            "serde-inst ^schema-version must be an Int", r.path)
      else:
        raiseSerdeError(r.scope,
          "serde-inst has unsupported prop ^" & k, r.path)
    if v.meta.len > 0:
      raiseSerdeError(r.scope, "serde-inst takes no meta", r.path)
    if v.body.len != 3:
      raiseSerdeError(r.scope,
        "serde-inst expects (head-ref props body)", r.path)
    r.path.add "type"
    let head = serdeDecode(r, v.body[0], depth + 1)
    discard r.path.pop()
    r.path.add "props"
    let propsVal = serdeDecode(r, v.body[1], depth + 1)
    discard r.path.pop()
    r.path.add "body"
    let bodyVal = serdeDecode(r, v.body[2], depth + 1)
    discard r.path.pop()
    if propsVal.kind != vkMap:
      raiseSerdeError(r.scope, "serde-inst props must decode to a map", r.path)
    if bodyVal.kind != vkList:
      raiseSerdeError(r.scope, "serde-inst body must decode to a list", r.path)
    if head.kind == vkType:
      var na: NamedArgs
      for k, val in propsVal.mapEntries:
        na.names.add k
        na.values.add val
      try:
        constructTypedInstance(head, bodyVal.listItems, na)
      except GeneError as e:
        raiseSerdeError(r.scope, "serde-inst construct: " & e.msg, r.path)
        NIL
    elif head.kind == vkEnumVariant:
      if propsVal.mapEntries.len > 0:
        raiseSerdeError(r.scope,
          "enum-variant instance must have no props", r.path)
      try:
        applyCall(head, bodyVal.listItems, NamedArgs())
      except GeneError as e:
        raiseSerdeError(r.scope, "serde-inst variant: " & e.msg, r.path)
        NIL
    else:
      raiseSerdeError(r.scope, "serde-inst head resolved to a " &
        $head.kind & ", not a type or variant", r.path)
      NIL
  of "serde-snapshot-cell":
    if not r.resolveRefs:
      raiseSerdeError(r.scope,
        "serde-snapshot-cell requires serde/read (serde/read-data accepts " &
        "pure data only)", r.path)
    serdeBodyLen(r, v, tag, 1)
    r.path.add "cell"
    let inner = serdeDecode(r, v.body[0], depth + 1)
    discard r.path.pop()
    newCell(inner)
  of "serde-hooked":
    if not r.resolveRefs:
      raiseSerdeError(r.scope,
        "serde-hooked requires serde/read (serde/read-data accepts pure " &
        "data only)", r.path)
    if not r.limits.allowRestore:
      raiseSerdeError(r.scope,
        "serde-hooked requires ^policy (SerdePolicy ^allow-restore true) — " &
        "restore hooks execute user code during deserialization", r.path)
    if v.props.len > 0 or v.meta.len > 0 or v.body.len != 2:
      raiseSerdeError(r.scope, "serde-hooked expects (type-ref state)", r.path)
    r.path.add "type"
    let head = serdeDecode(r, v.body[0], depth + 1)
    discard r.path.pop()
    if head.kind != vkType:
      raiseSerdeError(r.scope, "serde-hooked head must be a type", r.path)
    r.path.add "state"
    let state = serdeDecode(r, v.body[1], depth + 1)
    discard r.path.pop()
    let restoreFn = typeDirectMessage(head, "serde-restore")
    if restoreFn.kind == vkNil:
      raiseSerdeError(r.scope, "type " & head.typeName &
        " has a serde-state message but no serde-restore", r.path)
    try:
      applyCall(restoreFn, [state], NamedArgs(), r.scope)
    except GeneError as e:
      raiseSerdeError(r.scope, "serde-restore: " & e.msg, r.path)
      NIL
  else:
    raiseSerdeError(r.scope, "unknown serde control tag: " & tag, r.path)
    NIL

proc serdeDecode(r: var SerdeReader, v: Value, depth: int): Value =
  serdeCountValue(r, depth)
  case v.kind
  of vkNil, vkVoid, vkBool, vkInt, vkFloat, vkString, vkBytes, vkChar,
     vkDate, vkTime, vkDateTime, vkRegex:
    v
  of vkSymbol:
    serdeCountSymbol(r, v.symVal)
    v
  of vkList:
    var items: seq[Value]
    for i, it in v.listItems:
      r.path.add $i
      items.add serdeDecode(r, it, depth + 1)
      discard r.path.pop()
    newList(items, immutable = v.listImmutable)
  of vkMap:
    var entries = initOrderedTable[string, Value]()
    for k, val in v.mapEntries:
      r.path.add k
      entries[k] = serdeDecode(r, val, depth + 1)
      discard r.path.pop()
    newMap(entries, immutable = v.mapImmutable)
  of vkHashMap:
    var entries: seq[HashMapEntry]
    for entry in v.hashMapEntries:
      r.path.add "key"
      let k = serdeDecode(r, entry.key, depth + 1)
      discard r.path.pop()
      r.path.add "val"
      let value = serdeDecode(r, entry.val, depth + 1)
      discard r.path.pop()
      entries.add HashMapEntry(key: k, val: value)
    newHashMap(entries)
  of vkNode:
    if v.head.kind == vkSymbol and
        v.head.symVal.startsWith(serdeReservedPrefix):
      return serdeDecodeControl(r, v, v.head.symVal, depth)
    r.path.add "head"
    let head = serdeDecode(r, v.head, depth + 1)
    discard r.path.pop()
    var props = initOrderedTable[string, Value]()
    for k, val in v.props:
      r.path.add k
      props[k] = serdeDecode(r, val, depth + 1)
      discard r.path.pop()
    var meta = initOrderedTable[string, Value]()
    for k, val in v.meta:
      r.path.add k
      meta[k] = serdeDecode(r, val, depth + 1)
      discard r.path.pop()
    var children: seq[Value]
    for i, it in v.body:
      r.path.add $i
      children.add serdeDecode(r, it, depth + 1)
      discard r.path.pop()
    newNode(head, props = props, body = children, meta = meta,
            immutable = v.nodeImmutable)
  else:
    raiseSerdeError(r.scope,
      "unsupported value kind in payload: " & $v.kind, r.path)
    NIL

proc biSerdeWriteData(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("serde/write-data", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  newStr(serdeWriteDataText(args[0], scope))

proc biSerdeDataP(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("serde/data?", args)
  if serdeDataValueP(args[0]): TRUE else: FALSE

proc serdeReadEnvelope(name, text: string, scope: Scope, policy: Value,
                       resolveRefs: bool): Value =
  let limits = serdeLimitsFrom(policy, scope)
  if text.len > limits.maxBytes:
    raiseSerdeError(scope, "payload exceeds max-bytes (" &
                    $limits.maxBytes & ")")
  var forms: seq[Value]
  try:
    let readerMaxDepth =
      if limits.maxDepth <= 0: 0 else: limits.maxDepth + 1
    forms = readAll(text, "<serde>", ReadOptions(maxDepth: readerMaxDepth))
  except ReadError as e:
    raiseSerdeError(scope, "parse: " & e.msg)
  if forms.len != 1 or forms[0].kind != vkNode:
    raiseSerdeError(scope, "expected a single (serde-v1 ...) envelope")
  let envelope = forms[0]
  if envelope.head.kind != vkSymbol or envelope.head.symVal != "serde-v1":
    if envelope.head.kind == vkSymbol and
        envelope.head.symVal.startsWith(serdeReservedPrefix):
      raiseSerdeError(scope, "unsupported serde envelope version: " &
                      envelope.head.symVal)
    raiseSerdeError(scope, "expected a (serde-v1 ...) envelope")
  if envelope.body.len != 1 or envelope.props.len > 0 or
      envelope.meta.len > 0:
    raiseSerdeError(scope,
      "serde-v1 envelope expects exactly one payload form")
  var r = SerdeReader(scope: scope, limits: limits,
                      resolveRefs: resolveRefs,
                      app: (if resolveRefs: application(scope) else: nil))
  serdeDecode(r, envelope.body[0], 0)

proc biSerdeReadData(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError,
      "serde/read-data expects a Str plus optional ^policy")
  requireStr("serde/read-data", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  var policy = NIL
  if call != nil:
    for i, name in call[].namedNames:
      case name
      of "policy":
        policy = call[].namedValues[i]
      else:
        raiseSerdeError(scope,
          "serde/read-data got unexpected named argument: " & name)
  serdeReadEnvelope("serde/read-data", args[0].strVal, scope, policy,
                    resolveRefs = false)

proc biSerdeWrite(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("serde/write", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  newStr(serdeWriteFullText(args[0], scope))

proc biSerdeRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError,
      "serde/read expects a Str plus optional ^policy")
  requireStr("serde/read", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  var policy = NIL
  if call != nil:
    for i, name in call[].namedNames:
      case name
      of "policy":
        policy = call[].namedValues[i]
      else:
        raiseSerdeError(scope,
          "serde/read got unexpected named argument: " & name)
  serdeReadEnvelope("serde/read", args[0].strVal, scope, policy,
                    resolveRefs = true)


# --- db backends: sqlite and postgres behind the shared Db protocol ---
#
# Both backends load their C client library at runtime through std/dynlib, so
# neither adds a link-time dependency; `open` raises DbError when the library
# is not present. Connections are nodes (`SqliteDb`/`PostgresDb`) whose
# ^handle prop is an owned C pointer wired to the library's close function,
# so dropping a connection eventually releases it and `close`/`closed?` are
# backend-agnostic.

proc raiseDbError(message: string, scope: Scope) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(builtInTypeHead(scope, "DbError"), props = props)
  e.hasErrVal = true
  raise e

proc dbConnHandleValue(name: string, conn: Value, expectedType: string,
                       scope: Scope): Value =
  if conn.kind != vkNode or conn.head.kind != vkType or
      conn.head.typeName != expectedType:
    raiseDbError(name & " expects a " & expectedType & " connection", scope)
  let handle = conn.props.getOrDefault("handle", VOID)
  if handle.kind != vkCPtr:
    raiseDbError(name & ": connection has no native handle", scope)
  handle

proc dbConnHandle(name: string, conn: Value, expectedType: string,
                  scope: Scope): pointer =
  let handle = dbConnHandleValue(name, conn, expectedType, scope)
  if handle.cPtrClosed or handle.cPtrIsNull:
    raiseDbError(name & ": connection is closed", scope)
  handle.cPtrAddress

proc dbParamText(name: string, param: Value, scope: Scope): string =
  case param.kind
  of vkString: param.strVal
  of vkInt: $param.intVal
  of vkFloat: $param.floatVal
  of vkBool: (if param.boolVal: "true" else: "false")
  else:
    raiseDbError(name & ": unsupported parameter type " & $param.kind, scope)
    ""

# -- sqlite ------------------------------------------------------------------

when defined(macosx):
  const sqliteLibCandidates = ["libsqlite3.dylib", "/usr/lib/libsqlite3.dylib"]
elif defined(windows):
  const sqliteLibCandidates = ["sqlite3.dll"]
else:
  const sqliteLibCandidates = ["libsqlite3.so.0", "libsqlite3.so"]

const SQLITE_OK = 0
const SQLITE_ROW = 100
const SQLITE_DONE = 101
let SQLITE_TRANSIENT = cast[pointer](-1)

type SqliteApi = object
  lib: LibHandle
  closeAddr: pointer      # sqlite3_close_v2, used as the owned-ptr release
  open: proc(filename: cstring, db: ptr pointer): cint {.cdecl.}
  errmsg: proc(db: pointer): cstring {.cdecl.}
  prepare: proc(db: pointer, sql: cstring, nBytes: cint, stmt: ptr pointer,
                tail: ptr cstring): cint {.cdecl.}
  step: proc(stmt: pointer): cint {.cdecl.}
  finalize: proc(stmt: pointer): cint {.cdecl.}
  changes: proc(db: pointer): cint {.cdecl.}
  bindParameterCount: proc(stmt: pointer): cint {.cdecl.}
  bindInt64: proc(stmt: pointer, idx: cint, v: int64): cint {.cdecl.}
  bindDouble: proc(stmt: pointer, idx: cint, v: cdouble): cint {.cdecl.}
  bindText: proc(stmt: pointer, idx: cint, s: cstring, n: cint,
                 destructor: pointer): cint {.cdecl.}
  bindNull: proc(stmt: pointer, idx: cint): cint {.cdecl.}
  columnCount: proc(stmt: pointer): cint {.cdecl.}
  columnType: proc(stmt: pointer, i: cint): cint {.cdecl.}
  columnInt64: proc(stmt: pointer, i: cint): int64 {.cdecl.}
  columnDouble: proc(stmt: pointer, i: cint): cdouble {.cdecl.}
  columnText: proc(stmt: pointer, i: cint): cstring {.cdecl.}
  columnName: proc(stmt: pointer, i: cint): cstring {.cdecl.}

var gSqliteApi: SqliteApi

proc loadSqliteApi(scope: Scope) =
  if gSqliteApi.lib != nil:
    return
  var lib: LibHandle
  for candidate in sqliteLibCandidates:
    lib = loadLib(candidate)
    if lib != nil:
      break
  if lib == nil:
    raiseDbError("sqlite/open: could not load the sqlite3 library", scope)
  template sym(name: string): pointer =
    block:
      let address = symAddr(lib, name)
      if address == nil:
        unloadLib(lib)
        raiseDbError("sqlite/open: missing symbol " & name, scope)
      address
  var api: SqliteApi
  api.open = cast[typeof(api.open)](sym"sqlite3_open")
  api.closeAddr = sym"sqlite3_close_v2"
  api.errmsg = cast[typeof(api.errmsg)](sym"sqlite3_errmsg")
  api.prepare = cast[typeof(api.prepare)](sym"sqlite3_prepare_v2")
  api.step = cast[typeof(api.step)](sym"sqlite3_step")
  api.finalize = cast[typeof(api.finalize)](sym"sqlite3_finalize")
  api.changes = cast[typeof(api.changes)](sym"sqlite3_changes")
  api.bindParameterCount =
    cast[typeof(api.bindParameterCount)](sym"sqlite3_bind_parameter_count")
  api.bindInt64 = cast[typeof(api.bindInt64)](sym"sqlite3_bind_int64")
  api.bindDouble = cast[typeof(api.bindDouble)](sym"sqlite3_bind_double")
  api.bindText = cast[typeof(api.bindText)](sym"sqlite3_bind_text")
  api.bindNull = cast[typeof(api.bindNull)](sym"sqlite3_bind_null")
  api.columnCount = cast[typeof(api.columnCount)](sym"sqlite3_column_count")
  api.columnType = cast[typeof(api.columnType)](sym"sqlite3_column_type")
  api.columnInt64 = cast[typeof(api.columnInt64)](sym"sqlite3_column_int64")
  api.columnDouble = cast[typeof(api.columnDouble)](sym"sqlite3_column_double")
  api.columnText = cast[typeof(api.columnText)](sym"sqlite3_column_text")
  api.columnName = cast[typeof(api.columnName)](sym"sqlite3_column_name")
  api.lib = lib
  gSqliteApi = api

proc sqliteHandle(name: string, conn: Value, scope: Scope): pointer =
  dbConnHandle(name, conn, "SqliteDb", scope)

proc sqliteError(db: pointer, where: string, scope: Scope) =
  let msg = if db == nil: "unknown sqlite error" else: $gSqliteApi.errmsg(db)
  raiseDbError(where & ": " & msg, scope)

proc sqliteColumnValue(stmt: pointer, i: cint): Value =
  case gSqliteApi.columnType(stmt, i)
  of 1: newInt(gSqliteApi.columnInt64(stmt, i))
  of 2: newFloat(gSqliteApi.columnDouble(stmt, i))
  of 5: NIL
  else:
    let text = gSqliteApi.columnText(stmt, i)
    if text == nil: newStr("") else: newStr($text)

proc sqliteRunStmt(db: pointer, sql: string, params: openArray[Value],
                   where: string, scope: Scope):
    tuple[rows: seq[Value], changes: int] =
  var stmt: pointer
  var tail: cstring
  if gSqliteApi.prepare(db, sql.cstring, cint(sql.len), addr stmt,
                        addr tail) != SQLITE_OK:
    sqliteError(db, where, scope)
  if stmt == nil:
    raiseDbError(where & ": empty SQL statement", scope)
  defer: discard gSqliteApi.finalize(stmt)
  if tail != nil and ($tail).strip().len > 0:
    raiseDbError(where & " runs a single statement; use exec for scripts",
                 scope)
  let expected = int(gSqliteApi.bindParameterCount(stmt))
  if params.len != expected:
    raiseDbError(where & " expects " & $expected & " parameter(s), got " &
                 $params.len, scope)
  for i, param in params:
    let idx = cint(i + 1)
    let rc =
      case param.kind
      of vkNil: gSqliteApi.bindNull(stmt, idx)
      of vkBool: gSqliteApi.bindInt64(stmt, idx, if param.boolVal: 1 else: 0)
      of vkInt: gSqliteApi.bindInt64(stmt, idx, param.intVal)
      of vkFloat: gSqliteApi.bindDouble(stmt, idx, param.floatVal)
      of vkString:
        gSqliteApi.bindText(stmt, idx, param.strVal.cstring,
                            cint(param.strVal.len), SQLITE_TRANSIENT)
      else:
        raiseDbError(where & ": unsupported parameter type " & $param.kind,
                     scope)
        SQLITE_OK
    if rc != SQLITE_OK:
      sqliteError(db, where, scope)
  while true:
    let rc = gSqliteApi.step(stmt)
    if rc == SQLITE_ROW:
      var entries = initOrderedTable[string, Value]()
      for i in 0 ..< gSqliteApi.columnCount(stmt):
        entries[$gSqliteApi.columnName(stmt, i)] = sqliteColumnValue(stmt, i)
      result.rows.add newMap(entries)
    elif rc == SQLITE_DONE:
      break
    else:
      sqliteError(db, where, scope)
  result.changes = int(gSqliteApi.changes(db))

proc sqliteExecScript(db: pointer, sql: string, where: string, scope: Scope) =
  ## Run a possibly multi-statement SQL script without parameters.
  var remaining = sql
  while remaining.strip().len > 0:
    var stmt: pointer
    var tail: cstring
    if gSqliteApi.prepare(db, remaining.cstring, cint(remaining.len),
                          addr stmt, addr tail) != SQLITE_OK:
      sqliteError(db, where, scope)
    let rest = if tail == nil: "" else: $tail
    if stmt != nil:
      while true:
        let rc = gSqliteApi.step(stmt)
        if rc == SQLITE_ROW:
          continue
        discard gSqliteApi.finalize(stmt)
        if rc != SQLITE_DONE:
          sqliteError(db, where, scope)
        break
    remaining = rest

proc biSqliteOpen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("sqlite/open", args)
  requireStr("sqlite/open path", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  loadSqliteApi(scope)
  var db: pointer
  if gSqliteApi.open(args[0].strVal.cstring, addr db) != SQLITE_OK:
    let msg = if db == nil: "unknown sqlite error" else: $gSqliteApi.errmsg(db)
    if db != nil:
      type CloseProc = proc(p: pointer): cint {.cdecl.}
      discard cast[CloseProc](gSqliteApi.closeAddr)(db)
    raiseDbError("sqlite/open: " & msg, scope)
  var props = initOrderedTable[string, Value]()
  props["handle"] = newCForeignOwnedPtr(db, gSqliteApi.closeAddr)
  props["backend"] = newStr("sqlite")
  props["path"] = args[0]
  let head = builtInTypeHead(scope, "SqliteDb")
  newNode(head, props = props)

proc biSqliteExec(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Db/exec expects (conn, sql), got " & $args.len)
  requireStr("Db/exec sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  let db = sqliteHandle("Db/exec", args[0], scope)
  sqliteExecScript(db, args[1].strVal, "Db/exec", scope)
  NIL

proc biSqliteQuery(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len < 2:
    raise newException(GeneError, "Db/query expects (conn, sql, params...)")
  requireStr("Db/query sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  let db = sqliteHandle("Db/query", args[0], scope)
  newList(sqliteRunStmt(db, args[1].strVal, args[2..^1], "Db/query",
                        scope).rows)

proc biSqliteQueryOne(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len < 2:
    raise newException(GeneError, "Db/query_one expects (conn, sql, params...)")
  requireStr("Db/query_one sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  let db = sqliteHandle("Db/query_one", args[0], scope)
  let rows = sqliteRunStmt(db, args[1].strVal, args[2..^1], "Db/query_one",
                           scope).rows
  if rows.len == 0: NIL else: rows[0]

proc biSqliteExecute(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len < 2:
    raise newException(GeneError, "Db/execute expects (conn, sql, params...)")
  requireStr("Db/execute sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  let db = sqliteHandle("Db/execute", args[0], scope)
  newInt(sqliteRunStmt(db, args[1].strVal, args[2..^1], "Db/execute",
                       scope).changes)

proc biDbClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Db/close", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  if args[0].kind != vkNode or args[0].head.kind != vkType:
    raiseDbError("Db/close expects a database connection", scope)
  let handle = args[0].props.getOrDefault("handle", VOID)
  if handle.kind != vkCPtr:
    raiseDbError("Db/close: connection has no native handle", scope)
  if not handle.cPtrClosed:
    closeCPtr(handle)
  NIL

proc biDbClosed(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Db/closed?", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  if args[0].kind != vkNode or args[0].head.kind != vkType:
    raiseDbError("Db/closed? expects a database connection", scope)
  let handle = args[0].props.getOrDefault("handle", VOID)
  if handle.kind != vkCPtr:
    raiseDbError("Db/closed?: connection has no native handle", scope)
  if handle.cPtrClosed: TRUE else: FALSE

proc dbRunTransaction(conn, callable: Value, scope: Scope,
                      execFn: proc(conn: Value, sql: string,
                                   scope: Scope)): Value =
  execFn(conn, "BEGIN", scope)
  try:
    var callArgs = [conn]
    result = applyCall(callable, callArgs, NamedArgs(), scope)
  except GeneError, GenePanic:
    try:
      execFn(conn, "ROLLBACK", scope)
    except GeneError:
      discard   # surface the original failure, not the rollback's
    raise
  execFn(conn, "COMMIT", scope)

proc biSqliteTransaction(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Db/transaction expects (conn, fn)")
  let scope = if call == nil: nil else: call[].dispatchScope
  dbRunTransaction(args[0], args[1], scope,
    proc(conn: Value, sql: string, scope: Scope) =
      sqliteExecScript(sqliteHandle("Db/transaction", conn, scope), sql,
                       "Db/transaction", scope))

# -- postgres ----------------------------------------------------------------

when defined(macosx):
  const pgLibCandidates = ["libpq.dylib", "libpq.5.dylib",
                           "/opt/homebrew/opt/libpq/lib/libpq.5.dylib",
                           "/usr/local/opt/libpq/lib/libpq.5.dylib",
                           "/opt/homebrew/opt/postgresql@17/lib/libpq.5.dylib",
                           "/opt/homebrew/opt/postgresql@16/lib/libpq.5.dylib",
                           "/opt/homebrew/opt/postgresql@15/lib/libpq.5.dylib",
                           "/opt/homebrew/opt/postgresql@14/lib/libpq.5.dylib"]
elif defined(windows):
  const pgLibCandidates = ["libpq.dll"]
else:
  const pgLibCandidates = ["libpq.so.5", "libpq.so"]

const CONNECTION_OK = 0
const PGRES_COMMAND_OK = 1
const PGRES_TUPLES_OK = 2

type PgApi = object
  lib: LibHandle
  finishAddr: pointer     # PQfinish, used as the owned-ptr release
  connectdb: proc(conninfo: cstring): pointer {.cdecl.}
  status: proc(conn: pointer): cint {.cdecl.}
  errorMessage: proc(conn: pointer): cstring {.cdecl.}
  execParams: proc(conn: pointer, command: cstring, nParams: cint,
                   paramTypes: pointer, paramValues: ptr cstring,
                   paramLengths: pointer, paramFormats: pointer,
                   resultFormat: cint): pointer {.cdecl.}
  resultStatus: proc(res: pointer): cint {.cdecl.}
  resultErrorMessage: proc(res: pointer): cstring {.cdecl.}
  ntuples: proc(res: pointer): cint {.cdecl.}
  nfields: proc(res: pointer): cint {.cdecl.}
  fname: proc(res: pointer, i: cint): cstring {.cdecl.}
  ftype: proc(res: pointer, i: cint): cuint {.cdecl.}
  getisnull: proc(res: pointer, r, c: cint): cint {.cdecl.}
  getvalue: proc(res: pointer, r, c: cint): cstring {.cdecl.}
  cmdTuples: proc(res: pointer): cstring {.cdecl.}
  clear: proc(res: pointer) {.cdecl.}

var gPgApi: PgApi

proc loadPgApi(scope: Scope) =
  if gPgApi.lib != nil:
    return
  var lib: LibHandle
  let override = getEnv("GENE_LIBPQ")
  if override.len > 0:
    lib = loadLib(override)
    if lib == nil:
      raiseDbError("postgres/open: could not load GENE_LIBPQ=" & override,
                   scope)
  else:
    for candidate in pgLibCandidates:
      lib = loadLib(candidate)
      if lib != nil:
        break
  if lib == nil:
    raiseDbError("postgres/open: could not load the libpq library; set " &
                 "GENE_LIBPQ to its path", scope)
  template sym(name: string): pointer =
    block:
      let address = symAddr(lib, name)
      if address == nil:
        unloadLib(lib)
        raiseDbError("postgres/open: missing symbol " & name, scope)
      address
  var api: PgApi
  api.connectdb = cast[typeof(api.connectdb)](sym"PQconnectdb")
  api.finishAddr = sym"PQfinish"
  api.status = cast[typeof(api.status)](sym"PQstatus")
  api.errorMessage = cast[typeof(api.errorMessage)](sym"PQerrorMessage")
  api.execParams = cast[typeof(api.execParams)](sym"PQexecParams")
  api.resultStatus = cast[typeof(api.resultStatus)](sym"PQresultStatus")
  api.resultErrorMessage =
    cast[typeof(api.resultErrorMessage)](sym"PQresultErrorMessage")
  api.ntuples = cast[typeof(api.ntuples)](sym"PQntuples")
  api.nfields = cast[typeof(api.nfields)](sym"PQnfields")
  api.fname = cast[typeof(api.fname)](sym"PQfname")
  api.ftype = cast[typeof(api.ftype)](sym"PQftype")
  api.getisnull = cast[typeof(api.getisnull)](sym"PQgetisnull")
  api.getvalue = cast[typeof(api.getvalue)](sym"PQgetvalue")
  api.cmdTuples = cast[typeof(api.cmdTuples)](sym"PQcmdTuples")
  api.clear = cast[typeof(api.clear)](sym"PQclear")
  api.lib = lib
  gPgApi = api

proc pgHandle(name: string, conn: Value, scope: Scope): pointer =
  dbConnHandle(name, conn, "PostgresDb", scope)

proc pgCellValue(res: pointer, row, col: cint): Value =
  if gPgApi.getisnull(res, row, col) != 0:
    return NIL
  let raw = $gPgApi.getvalue(res, row, col)
  case gPgApi.ftype(res, col)
  of 16'u32:                                    # bool
    if raw == "t": TRUE else: FALSE
  of 20'u32, 21'u32, 23'u32, 26'u32:            # int8/int2/int4/oid
    try: newInt(parseBiggestInt(raw))
    except ValueError: newStr(raw)
  of 700'u32, 701'u32, 1700'u32:                # float4/float8/numeric
    try: newFloat(parseFloat(raw))
    except ValueError: newStr(raw)
  else:
    newStr(raw)

proc pgRun(conn: Value, sql: string, params: openArray[Value], where: string,
           scope: Scope): tuple[rows: seq[Value], changes: int] =
  let db = pgHandle(where, conn, scope)
  var backing = newSeq[string](params.len)
  var values = newSeq[cstring](params.len)
  for i, param in params:
    if param.kind == vkNil:
      values[i] = nil
    else:
      backing[i] = dbParamText(where, param, scope)
      values[i] = backing[i].cstring
  let res = gPgApi.execParams(db, sql.cstring, cint(params.len), nil,
                              (if params.len == 0: nil
                               else: addr values[0]),
                              nil, nil, 0)
  if res == nil:
    raiseDbError(where & ": " & $gPgApi.errorMessage(db), scope)
  defer: gPgApi.clear(res)
  case gPgApi.resultStatus(res)
  of PGRES_TUPLES_OK:
    for r in 0 ..< gPgApi.ntuples(res):
      var entries = initOrderedTable[string, Value]()
      for c in 0 ..< gPgApi.nfields(res):
        entries[$gPgApi.fname(res, c)] = pgCellValue(res, r, c)
      result.rows.add newMap(entries)
  of PGRES_COMMAND_OK:
    let affected = $gPgApi.cmdTuples(res)
    result.changes = if affected.len == 0: 0 else: parseInt(affected)
  else:
    raiseDbError(where & ": " & ($gPgApi.resultErrorMessage(res)).strip(),
                 scope)

proc biPostgresOpen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("postgres/open", args)
  requireStr("postgres/open conninfo", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  loadPgApi(scope)
  let db = gPgApi.connectdb(args[0].strVal.cstring)
  if db == nil:
    raiseDbError("postgres/open: connection allocation failed", scope)
  if gPgApi.status(db) != CONNECTION_OK:
    let msg = ($gPgApi.errorMessage(db)).strip()
    type FinishProc = proc(p: pointer) {.cdecl.}
    cast[FinishProc](gPgApi.finishAddr)(db)
    raiseDbError("postgres/open: " & msg, scope)
  var props = initOrderedTable[string, Value]()
  props["handle"] = newCForeignOwnedPtr(db, gPgApi.finishAddr)
  props["backend"] = newStr("postgres")
  let head = builtInTypeHead(scope, "PostgresDb")
  newNode(head, props = props)

proc biPostgresExec(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Db/exec expects (conn, sql), got " & $args.len)
  requireStr("Db/exec sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  discard pgRun(args[0], args[1].strVal, [], "Db/exec", scope)
  NIL

proc biPostgresQuery(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len < 2:
    raise newException(GeneError, "Db/query expects (conn, sql, params...)")
  requireStr("Db/query sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  newList(pgRun(args[0], args[1].strVal, args[2..^1], "Db/query", scope).rows)

proc biPostgresQueryOne(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len < 2:
    raise newException(GeneError, "Db/query_one expects (conn, sql, params...)")
  requireStr("Db/query_one sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  let rows = pgRun(args[0], args[1].strVal, args[2..^1], "Db/query_one",
                   scope).rows
  if rows.len == 0: NIL else: rows[0]

proc biPostgresExecute(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len < 2:
    raise newException(GeneError, "Db/execute expects (conn, sql, params...)")
  requireStr("Db/execute sql", args[1])
  let scope = if call == nil: nil else: call[].dispatchScope
  newInt(pgRun(args[0], args[1].strVal, args[2..^1], "Db/execute",
               scope).changes)

proc biPostgresTransaction(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Db/transaction expects (conn, fn)")
  let scope = if call == nil: nil else: call[].dispatchScope
  dbRunTransaction(args[0], args[1], scope,
    proc(conn: Value, sql: string, scope: Scope) =
      discard pgRun(conn, sql, [], "Db/transaction", scope))

# --- store: durable key -> serde text over sqlite or filesystem --------------

const storeDefaultTable = "store_records"
const storeDefaultKeyColumn = "key"
const storeDefaultDataColumn = "data"

proc raiseStoreError(scope: Scope, kind, message: string, key = "") =
  var props = initOrderedTable[string, Value]()
  props["kind"] = newSym(kind)
  props["message"] = newStr(message)
  if key.len > 0:
    props["key"] = newStr(key)
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(builtInTypeHead(scope, "StoreError"), props = props)
  e.hasErrVal = true
  raise e

proc storeNamed(call: ptr NativeCall): NamedArgs =
  if call == nil:
    NamedArgs()
  else:
    NamedArgs(names: call[].namedNames, values: call[].namedValues)

proc storeNamedOr(named: NamedArgs, name: string, fallback: Value): Value =
  if named.hasArg(name): named.getArg(name) else: fallback

proc storeModeText(scope: Scope, value: Value, fallback = "data"): string =
  if value.kind == vkNil or value.kind == vkVoid:
    return fallback
  case value.kind
  of vkSymbol: result = value.symVal
  of vkString: result = value.strVal
  else:
    raiseStoreError(scope, "invalid-key",
      "store ^mode expects data or full")
  if result != "data" and result != "full":
    raiseStoreError(scope, "invalid-key",
      "store ^mode expects data or full, got " & result)

proc storeModeOf(store: Value, scope: Scope): string =
  storeModeText(scope, store.props.getOrDefault("mode", newSym("data")),
                "data")

proc storePolicyOf(store: Value): Value =
  store.props.getOrDefault("policy", NIL)

proc storeValidateKey(scope: Scope, key: string) =
  if key.len == 0:
    raiseStoreError(scope, "invalid-key", "store key must not be empty", key)

proc storeSqlIdent(scope: Scope, ident, label: string): string =
  if ident.len == 0:
    raiseStoreError(scope, "invalid-key", label & " must not be empty")
  if ident[0] notin {'A'..'Z', 'a'..'z', '_'}:
    raiseStoreError(scope, "invalid-key", "invalid SQL identifier for " & label)
  for c in ident:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
      raiseStoreError(scope, "invalid-key",
        "invalid SQL identifier for " & label)
  ident

proc storeRequire(scope: Scope, value: Value): string =
  if value.kind != vkNode or value.head.kind != vkType:
    raiseStoreError(scope, "closed", "Store operation expects a Store")
  let name = value.head.typeName
  if name != "SqliteStore" and name != "FsStore":
    raiseStoreError(scope, "closed", "Store operation expects a Store")
  let closed = value.props.getOrDefault("closed", NIL)
  if closed.kind == vkCell and closed.cellValue.isTruthy:
    raiseStoreError(scope, "closed", "store is closed")
  name

proc storeClose(store: Value) =
  let closed = store.props.getOrDefault("closed", NIL)
  if closed.kind == vkCell:
    closed.setCellValue(TRUE)

proc storeEncode(scope: Scope, mode: string, value: Value): string =
  try:
    if mode == "full":
      result = serdeWriteFullText(value, scope)
    else:
      result = serdeWriteDataText(value, scope)
  except GeneError as e:
    raiseStoreError(scope, "serde", "store encode: " & e.msg)

proc storeDecode(scope: Scope, mode, text: string, policy: Value,
                 key: string): Value =
  try:
    result = serdeReadEnvelope("store/get", text, scope, policy,
                               resolveRefs = mode == "full")
  except GeneError as e:
    raiseStoreError(scope, "corrupt", "store decode for key '" & key &
      "': " & e.msg, key)

proc storeReadModePolicy(store: Value, call: ptr NativeCall, scope: Scope):
    tuple[mode: string, policy: Value] =
  let named = storeNamed(call)
  result.mode = storeModeOf(store, scope)
  if named.hasArg("mode"):
    result.mode = storeModeText(scope, named.getArg("mode"), result.mode)
  result.policy = storePolicyOf(store)
  if named.hasArg("policy"):
    result.policy = named.getArg("policy")

proc storeWriteMode(store: Value, call: ptr NativeCall, scope: Scope): string =
  result = storeModeOf(store, scope)
  let named = storeNamed(call)
  if named.hasArg("mode"):
    result = storeModeText(scope, named.getArg("mode"), result)
  for name in named.names:
    if name != "mode":
      raiseStoreError(scope, "invalid-key",
        "store/put got unexpected named argument: " & name)

proc storeSqliteDb(store: Value, scope: Scope): pointer =
  let dbVal = store.props.getOrDefault("db", NIL)
  sqliteHandle("Store/sqlite", dbVal, scope)

proc storeSqliteTable(store: Value): tuple[tableName, keyColumn, dataColumn: string] =
  (store.props["table"].strVal,
   store.props["key-column"].strVal,
   store.props["data-column"].strVal)

proc storeSqliteEnsureSchema(db: pointer, tableName, keyColumn,
                             dataColumn: string, scope: Scope) =
  sqliteExecScript(db, "create table if not exists " & tableName &
    " (" & keyColumn & " text primary key, " & dataColumn & " text not null)",
    "store/sqlite/open", scope)

proc biStoreSqliteOpen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("store/sqlite/open", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  discard sqliteHandle("store/sqlite/open", args[0], scope)
  let named = storeNamed(call)
  let tableName = storeSqlIdent(scope,
    (if named.hasArg("table"): (requireStr("store/sqlite/open ^table",
      named.getArg("table")); named.getArg("table").strVal) else: storeDefaultTable),
    "table")
  let keyColumn = storeSqlIdent(scope,
    (if named.hasArg("key-column"): (requireStr("store/sqlite/open ^key-column",
      named.getArg("key-column")); named.getArg("key-column").strVal)
     else: storeDefaultKeyColumn), "key-column")
  let dataColumn = storeSqlIdent(scope,
    (if named.hasArg("data-column"): (requireStr("store/sqlite/open ^data-column",
      named.getArg("data-column")); named.getArg("data-column").strVal)
     else: storeDefaultDataColumn), "data-column")
  let mode = if named.hasArg("mode"):
      storeModeText(scope, named.getArg("mode"))
    else:
      "data"
  let policy = storeNamedOr(named, "policy", NIL)
  for name in named.names:
    if name notin ["table", "key-column", "data-column", "mode", "policy"]:
      raiseStoreError(scope, "invalid-key",
        "store/sqlite/open got unexpected named argument: " & name)
  storeSqliteEnsureSchema(sqliteHandle("store/sqlite/open", args[0], scope),
                          tableName, keyColumn, dataColumn, scope)
  var props = initOrderedTable[string, Value]()
  props["db"] = args[0]
  props["table"] = newStr(tableName)
  props["key-column"] = newStr(keyColumn)
  props["data-column"] = newStr(dataColumn)
  props["mode"] = newSym(mode)
  props["policy"] = policy
  props["closed"] = newCell(FALSE)
  newNode(builtInTypeHead(scope, "SqliteStore"), props = props)

proc biStorePut(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "Store/put expects (store, key, value)")
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  requireStr("Store/put key", args[1])
  let key = args[1].strVal
  storeValidateKey(scope, key)
  let mode = storeWriteMode(args[0], call, scope)
  let data = storeEncode(scope, mode, args[2])
  if kind == "SqliteStore":
    let db = storeSqliteDb(args[0], scope)
    let names = storeSqliteTable(args[0])
    discard sqliteRunStmt(db, "insert or replace into " & names.tableName &
      "(" & names.keyColumn & ", " & names.dataColumn & ") values (?, ?)",
      [newStr(key), newStr(data)], "Store/put", scope)
  else:
    let root = args[0].props["root"].strVal
    let path = root / (urlEncodeComponent(key) & ".gene")
    try:
      writeFile(path, data)
    except IOError as e:
      raiseStoreError(scope, "io", "Store/put: " & e.msg, key)
  NIL

proc biStoreGet(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Store/get expects (store, key)")
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  requireStr("Store/get key", args[1])
  let key = args[1].strVal
  storeValidateKey(scope, key)
  let named = storeNamed(call)
  for name in named.names:
    if name notin ["mode", "policy", "default"]:
      raiseStoreError(scope, "invalid-key",
        "Store/get got unexpected named argument: " & name, key)
  let opts = storeReadModePolicy(args[0], call, scope)
  var text = ""
  var found = false
  if kind == "SqliteStore":
    let db = storeSqliteDb(args[0], scope)
    let names = storeSqliteTable(args[0])
    let row = sqliteRunStmt(db, "select " & names.dataColumn & " from " &
      names.tableName & " where " & names.keyColumn & " = ?",
      [newStr(key)], "Store/get", scope).rows
    if row.len > 0:
      text = row[0].mapEntries[names.dataColumn].strVal
      found = true
  else:
    let root = args[0].props["root"].strVal
    let path = root / (urlEncodeComponent(key) & ".gene")
    if fileExists(path):
      try:
        text = readFile(path)
        found = true
      except IOError as e:
        raiseStoreError(scope, "io", "Store/get: " & e.msg, key)
  if not found:
    if named.hasArg("default"):
      return named.getArg("default")
    raiseStoreError(scope, "missing", "store key not found: " & key, key)
  storeDecode(scope, opts.mode, text, opts.policy, key)

proc biStoreHas(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Store/has? expects (store, key)")
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  requireStr("Store/has? key", args[1])
  let key = args[1].strVal
  storeValidateKey(scope, key)
  if kind == "SqliteStore":
    let db = storeSqliteDb(args[0], scope)
    let names = storeSqliteTable(args[0])
    let row = sqliteRunStmt(db, "select 1 as found from " & names.tableName &
      " where " & names.keyColumn & " = ?", [newStr(key)], "Store/has?",
      scope).rows
    if row.len > 0: TRUE else: FALSE
  else:
    let path = args[0].props["root"].strVal / (urlEncodeComponent(key) & ".gene")
    if fileExists(path): TRUE else: FALSE

proc biStoreDelete(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Store/delete expects (store, key)")
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  requireStr("Store/delete key", args[1])
  let key = args[1].strVal
  storeValidateKey(scope, key)
  if kind == "SqliteStore":
    let db = storeSqliteDb(args[0], scope)
    let names = storeSqliteTable(args[0])
    discard sqliteRunStmt(db, "delete from " & names.tableName & " where " &
      names.keyColumn & " = ?", [newStr(key)], "Store/delete", scope)
  else:
    let path = args[0].props["root"].strVal / (urlEncodeComponent(key) & ".gene")
    try:
      if fileExists(path):
        removeFile(path)
    except OSError as e:
      raiseStoreError(scope, "io", "Store/delete: " & e.msg, key)
  NIL

proc storeKeyFromFsName(scope: Scope, name: string): tuple[ok: bool, key: string] =
  if not name.endsWith(".gene") or name.len <= ".gene".len:
    return (false, "")
  let encoded = name[0 ..< name.len - ".gene".len]
  try:
    let key = urlDecodeComponent(encoded, plusIsSpace = false, scope)
    if key.len == 0 or urlEncodeComponent(key) != encoded:
      return (false, "")
    (true, key)
  except GeneError:
    (false, "")

proc biStoreKeys(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Store/keys", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  var keys: seq[Value]
  if kind == "SqliteStore":
    let db = storeSqliteDb(args[0], scope)
    let names = storeSqliteTable(args[0])
    let rows = sqliteRunStmt(db, "select " & names.keyColumn & " from " &
      names.tableName & " order by " & names.keyColumn, [], "Store/keys",
      scope).rows
    for row in rows:
      keys.add row.mapEntries[names.keyColumn]
  else:
    let root = args[0].props["root"].strVal
    try:
      for kind, path in walkDir(root, relative = true):
        if kind == pcFile:
          let decoded = storeKeyFromFsName(scope, path)
          if decoded.ok:
            keys.add newStr(decoded.key)
    except OSError as e:
      raiseStoreError(scope, "io", "Store/keys: " & e.msg)
  newList(keys)

proc biStoreClear(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Store/clear", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  if kind == "SqliteStore":
    let db = storeSqliteDb(args[0], scope)
    let names = storeSqliteTable(args[0])
    discard sqliteRunStmt(db, "delete from " & names.tableName, [],
                          "Store/clear", scope)
  else:
    let root = args[0].props["root"].strVal
    try:
      for kind, path in walkDir(root, relative = true):
        if kind == pcFile:
          let decoded = storeKeyFromFsName(scope, path)
          if decoded.ok:
            removeFile(root / path)
    except OSError as e:
      raiseStoreError(scope, "io", "Store/clear: " & e.msg)
  NIL

proc biStoreClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Store/close", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  discard storeRequire(scope, args[0])
  storeClose(args[0])
  NIL

proc biStoreFsOpen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("store/fs/open", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsReadDir("store/fs/open", args[0])
  requireFsWriteDir("store/fs/open", args[0])
  let named = storeNamed(call)
  if not named.hasArg("root"):
    raiseStoreError(scope, "invalid-key", "store/fs/open requires ^root")
  let rootVal = named.getArg("root")
  requireStr("store/fs/open ^root", rootVal)
  let root = rootVal.strVal
  let mode = if named.hasArg("mode"):
      storeModeText(scope, named.getArg("mode"))
    else:
      "data"
  let policy = storeNamedOr(named, "policy", NIL)
  for name in named.names:
    if name notin ["root", "mode", "policy"]:
      raiseStoreError(scope, "invalid-key",
        "store/fs/open got unexpected named argument: " & name)
  try:
    createDir(root)
  except OSError as e:
    raiseStoreError(scope, "io", "store/fs/open: " & e.msg)
  var props = initOrderedTable[string, Value]()
  props["fs"] = args[0]
  props["root"] = newStr(root)
  props["mode"] = newSym(mode)
  props["policy"] = policy
  props["closed"] = newCell(FALSE)
  newNode(builtInTypeHead(scope, "FsStore"), props = props)

proc registerStdlibNamespaces(root: Scope) =
  ## Define the importable stdlib namespaces (std/*, str, html, url, net/http,
  ## db, db/sqlite, db/postgres) and their error types on the built-ins root
  ## scope.
  let errorProtocol = root.vars["Error"]
  let urlError = newType("UrlError", NIL,
                         @[TypeField(name: "message", optional: false,
                                     typeExpr: newSym("Str"), scope: root)],
                         @[errorProtocol], root)
  root.define("UrlError", urlError)
  root.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: urlError)
  let httpError = newType("HttpError", NIL,
                          @[TypeField(name: "message", optional: false,
                                      typeExpr: newSym("Str"), scope: root)],
                          @[errorProtocol], root)
  root.define("HttpError", httpError)
  root.impls.add ProtocolImpl(protocol: errorProtocol,
                                receiver: httpError)
  proc defineErrorType(name: string): Value =
    result = newType(name, NIL,
                     @[TypeField(name: "message", optional: false,
                                 typeExpr: newSym("Str"), scope: root)],
                     @[errorProtocol], root)
    root.define(name, result)
    root.impls.add ProtocolImpl(protocol: errorProtocol, receiver: result)
  let osError = defineErrorType("OsError")
  let jsonError = defineErrorType("JsonError")
  let serdeError = defineErrorType("SerdeError")
  # Importable stdlib namespaces (docs/stdlib.md): mostly re-exports of the
  # built-ins above under stable module paths, so source programs can write
  # `(import std/stream [map])` / `(import str [join])` today and swap in
  # file-backed modules later without changing call sites.
  let stdStreamScope = newScope(root)
  stdStreamScope.define("to_stream", newNativeFn("to_stream", biToStream))
  stdStreamScope.define("to_pairs_stream",
                        newNativeFn("to_pairs_stream", biToPairsStream))
  stdStreamScope.define("map", newNativeFn("map", biStreamMap))
  stdStreamScope.define("filter", newNativeFn("filter", biStreamFilter))
  stdStreamScope.define("take", newNativeFn("take", biStreamTake))
  stdStreamScope.define("into", newNativeFn("into", biStreamInto))
  stdStreamScope.define("each", newNativeFn("each", biStreamEach))
  let stdNodeScope = newScope(root)
  stdNodeScope.define("head", newNativeFn("head", biHead))
  stdNodeScope.define("props", newNativeFn("props", biProps))
  stdNodeScope.define("body", newNativeFn("body", biBody))
  stdNodeScope.define("meta", newNativeFn("meta", biMeta))
  stdNodeScope.define("declarations",
                      newNativeFn("declarations", biDeclarations))
  let stdParseScope = newScope(root)
  stdParseScope.define("parse_int", newNativeCallFn("parse_int", biParseInt,
                                                    acceptsNamed = false))
  stdParseScope.define("ParseError", root.vars["ParseError"])
  let stdScope = newScope(root)
  stdScope.define("stream", newNamespace("std/stream", stdStreamScope))
  stdScope.define("node", newNamespace("std/node", stdNodeScope))
  stdScope.define("parse", newNamespace("std/parse", stdParseScope))
  root.define("std", newNamespace("std", stdScope))
  let strScope = newScope(root)
  strScope.define("join", newNativeFn("str/join", biStrJoin))
  strScope.define("split", newNativeFn("str/split", biStrSplit))
  strScope.define("trim", newNativeFn("str/trim", biStrTrim))
  strScope.define("lower", newNativeFn("str/lower", biStrLower))
  strScope.define("starts_with?", newNativeFn("str/starts_with?",
                                              biStrStartsWith))
  strScope.define("ends_with?", newNativeFn("str/ends_with?", biStrEndsWith))
  strScope.define("contains?", newNativeFn("str/contains?", biStrContains))
  root.define("str", newNamespace("str", strScope))
  let htmlScope = newScope(root)
  htmlScope.define("escape", newNativeFn("html/escape", biHtmlEscape))
  htmlScope.define("attr_escape", newNativeFn("html/attr_escape", biHtmlEscape))
  root.define("html", newNamespace("html", htmlScope))
  let urlScope = newScope(root)
  urlScope.define("encode_component",
                  newNativeFn("url/encode_component", biUrlEncodeComponent))
  urlScope.define("decode_component",
                  newNativeCallFn("url/decode_component", biUrlDecodeComponent,
                                  acceptsNamed = false))
  urlScope.define("parse_query",
                  newNativeCallFn("url/parse_query", biUrlParseQuery,
                                  acceptsNamed = false))
  urlScope.define("format_query",
                  newNativeFn("url/format_query", biUrlFormatQuery))
  urlScope.define("UrlError", root.vars["UrlError"])
  root.define("url", newNamespace("url", urlScope))
  let httpScope = newScope(root)
  let strField = proc (name: string): TypeField =
    TypeField(name: name, optional: false, typeExpr: newSym("Str"),
              scope: root)
  let requestType = newType("Request", NIL,
                            @[strField("method"), strField("path"),
                              strField("query"),
                              TypeField(name: "params", optional: false,
                                        typeExpr: newSym("Map"), scope: root),
                              TypeField(name: "headers", optional: false,
                                        typeExpr: newSym("Map"), scope: root),
                              strField("body")],
                            @[], root)
  httpScope.define("Request", requestType)
  let responseType = newType("Response", NIL,
                             @[TypeField(name: "status", optional: false,
                                         typeExpr: newSym("Int"),
                                         scope: root),
                               TypeField(name: "headers", optional: true,
                                         typeExpr: newSym("Map"),
                                         scope: root),
                               TypeField(name: "body", optional: true,
                                         typeExpr: newSym("Str"),
                                         scope: root)],
                             @[], root)
  httpScope.define("Response", responseType)
  let serverType = newType("Server", NIL,
                           @[TypeField(name: "host", optional: true,
                                       typeExpr: newSym("Str"), scope: root),
                             TypeField(name: "port", optional: false,
                                       typeExpr: newSym("Int"), scope: root)],
                           @[], root)
  httpScope.define("Server", serverType)
  let requestMsgType = newType("RequestMsg", NIL,
                               @[TypeField(name: "req", optional: false,
                                           typeExpr: newSym("Any"),
                                           scope: root),
                                 TypeField(name: "reply", optional: false,
                                           typeExpr: newSym("Any"),
                                           scope: root)],
                               @[], root)
  httpScope.define("RequestMsg", requestMsgType)
  httpScope.define("serve", newNativeCallFn("http/serve", biHttpServe))
  httpScope.define("listen", newNativeCallFn("http/listen", biHttpListen))
  httpScope.define("stop", newNativeCallFn("http/stop", biHttpStop))
  httpScope.define("status", newNativeCallFn("http/status", biHttpStatus))
  httpScope.define("route", newNativeCallFn("http/route", biHttpRoute))
  httpScope.define("actor-pool", newNativeCallFn("http/actor-pool",
                                                 biHttpActorPool))
  httpScope.define("supervisor-policy",
                   newNativeCallFn("http/supervisor-policy",
                                   biHttpSupervisorPolicy))
  httpScope.define("bytes", newNativeCallFn("http/bytes", biHttpBytes,
                                            acceptsNamed = false))
  httpScope.define("text", newNativeCallFn("http/text", biHttpText,
                                           acceptsNamed = false))
  httpScope.define("html", newNativeCallFn("http/html", biHttpHtml,
                                           acceptsNamed = false))
  httpScope.define("json", newNativeCallFn("http/json", biHttpJson,
                                           acceptsNamed = false))
  httpScope.define("redirect", newNativeCallFn("http/redirect", biHttpRedirect,
                                               acceptsNamed = false))
  httpScope.define("not_found", newNativeCallFn("http/not_found",
                                                biHttpNotFound,
                                                acceptsNamed = false))
  httpScope.define("HttpError", root.vars["HttpError"])
  let netLowerScope = newScope(root)
  netLowerScope.define("http", newNamespace("net/http", httpScope))
  root.define("net", newNamespace("net", netLowerScope))

  # db: shared protocol + error type; sqlite/postgres backends implement it.
  # DbError lives at the root so native raise sites resolve the type head and
  # `catch (DbError ^message m)` matches; the backend impls live on their
  # namespace scopes so only importing programs pay protocol-dispatch cost.
  let dbError = newType("DbError", NIL,
                        @[TypeField(name: "message", optional: false,
                                    typeExpr: newSym("Str"), scope: root)],
                        @[errorProtocol], root)
  root.define("DbError", dbError)
  root.impls.add ProtocolImpl(protocol: errorProtocol, receiver: dbError)
  let dbProtocol = newProtocol("Db", ["exec", "query", "query_one", "execute",
                                      "transaction", "close", "closed?"])
  let dbMessages = dbProtocol.protocolMessages
  let dbScope = newScope(root)
  dbScope.define("Db", dbProtocol)
  dbScope.define("DbError", dbError)
  let sqliteDbType = newType("SqliteDb", NIL, @[], @[dbProtocol], root)
  root.define("SqliteDb", sqliteDbType)
  let postgresDbType = newType("PostgresDb", NIL, @[], @[dbProtocol], root)
  root.define("PostgresDb", postgresDbType)
  let dbSqliteScope = newScope(root)
  dbSqliteScope.define("open", newNativeCallFn("sqlite/open", biSqliteOpen,
                                               acceptsNamed = false))
  dbSqliteScope.define("SqliteDb", sqliteDbType)
  dbSqliteScope.define("Db", dbProtocol)
  dbSqliteScope.define("DbError", dbError)
  dbSqliteScope.impls.add ProtocolImpl(
    protocol: dbProtocol, receiver: sqliteDbType,
    messages: @[
      ImplMessage(message: dbMessages["exec"],
                  fn: newNativeCallFn("Db/exec", biSqliteExec,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["query"],
                  fn: newNativeCallFn("Db/query", biSqliteQuery,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["query_one"],
                  fn: newNativeCallFn("Db/query_one", biSqliteQueryOne,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["execute"],
                  fn: newNativeCallFn("Db/execute", biSqliteExecute,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["transaction"],
                  fn: newNativeCallFn("Db/transaction", biSqliteTransaction,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["close"],
                  fn: newNativeCallFn("Db/close", biDbClose,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["closed?"],
                  fn: newNativeCallFn("Db/closed?", biDbClosed,
                                      acceptsNamed = false))])
  let dbPostgresScope = newScope(root)
  dbPostgresScope.define("open", newNativeCallFn("postgres/open",
                                                 biPostgresOpen,
                                                 acceptsNamed = false))
  dbPostgresScope.define("PostgresDb", postgresDbType)
  dbPostgresScope.define("Db", dbProtocol)
  dbPostgresScope.define("DbError", dbError)
  dbPostgresScope.impls.add ProtocolImpl(
    protocol: dbProtocol, receiver: postgresDbType,
    messages: @[
      ImplMessage(message: dbMessages["exec"],
                  fn: newNativeCallFn("Db/exec", biPostgresExec,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["query"],
                  fn: newNativeCallFn("Db/query", biPostgresQuery,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["query_one"],
                  fn: newNativeCallFn("Db/query_one", biPostgresQueryOne,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["execute"],
                  fn: newNativeCallFn("Db/execute", biPostgresExecute,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["transaction"],
                  fn: newNativeCallFn("Db/transaction", biPostgresTransaction,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["close"],
                  fn: newNativeCallFn("Db/close", biDbClose,
                                      acceptsNamed = false)),
      ImplMessage(message: dbMessages["closed?"],
                  fn: newNativeCallFn("Db/closed?", biDbClosed,
                                      acceptsNamed = false))])
  dbScope.define("sqlite", newNamespace("db/sqlite", dbSqliteScope))
  dbScope.define("postgres", newNamespace("db/postgres", dbPostgresScope))
  root.define("db", newNamespace("db", dbScope))

  # store: durable key -> serde text over interchangeable backends
  # (docs/proposals/persistence.md). Backend namespaces mirror db/sqlite.
  let storeError = newType("StoreError", NIL,
                           @[TypeField(name: "kind", optional: false,
                                       typeExpr: newSym("Sym"), scope: root),
                             TypeField(name: "message", optional: false,
                                       typeExpr: newSym("Str"), scope: root),
                             TypeField(name: "key", optional: true,
                                       typeExpr: newSym("Str"), scope: root)],
                           @[errorProtocol], root)
  root.define("StoreError", storeError)
  root.impls.add ProtocolImpl(protocol: errorProtocol, receiver: storeError)
  let storeProtocol = newProtocol("Store", ["put", "get", "has?", "delete",
                                            "keys", "clear", "close"])
  let storeMessages = storeProtocol.protocolMessages
  let sqliteStoreType = newType("SqliteStore", NIL, @[], @[storeProtocol], root)
  let fsStoreType = newType("FsStore", NIL, @[], @[storeProtocol], root)
  root.define("SqliteStore", sqliteStoreType)
  root.define("FsStore", fsStoreType)
  let storeScope = newScope(root)
  storeScope.define("Store", storeProtocol)
  storeScope.define("StoreError", storeError)
  let storeSqliteScope = newScope(root)
  storeSqliteScope.define("open", newNativeCallFn("store/sqlite/open",
                                                  biStoreSqliteOpen))
  storeSqliteScope.define("Store", storeProtocol)
  storeSqliteScope.define("StoreError", storeError)
  storeSqliteScope.define("SqliteStore", sqliteStoreType)
  storeSqliteScope.impls.add ProtocolImpl(
    protocol: storeProtocol, receiver: sqliteStoreType,
    messages: @[
      ImplMessage(message: storeMessages["put"],
                  fn: newNativeCallFn("Store/put", biStorePut)),
      ImplMessage(message: storeMessages["get"],
                  fn: newNativeCallFn("Store/get", biStoreGet)),
      ImplMessage(message: storeMessages["has?"],
                  fn: newNativeCallFn("Store/has?", biStoreHas,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["delete"],
                  fn: newNativeCallFn("Store/delete", biStoreDelete,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["keys"],
                  fn: newNativeCallFn("Store/keys", biStoreKeys,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["clear"],
                  fn: newNativeCallFn("Store/clear", biStoreClear,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["close"],
                  fn: newNativeCallFn("Store/close", biStoreClose,
                                      acceptsNamed = false))])
  let storeFsScope = newScope(root)
  storeFsScope.define("open", newNativeCallFn("store/fs/open", biStoreFsOpen))
  storeFsScope.define("Store", storeProtocol)
  storeFsScope.define("StoreError", storeError)
  storeFsScope.define("FsStore", fsStoreType)
  storeFsScope.impls.add ProtocolImpl(
    protocol: storeProtocol, receiver: fsStoreType,
    messages: @[
      ImplMessage(message: storeMessages["put"],
                  fn: newNativeCallFn("Store/put", biStorePut)),
      ImplMessage(message: storeMessages["get"],
                  fn: newNativeCallFn("Store/get", biStoreGet)),
      ImplMessage(message: storeMessages["has?"],
                  fn: newNativeCallFn("Store/has?", biStoreHas,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["delete"],
                  fn: newNativeCallFn("Store/delete", biStoreDelete,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["keys"],
                  fn: newNativeCallFn("Store/keys", biStoreKeys,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["clear"],
                  fn: newNativeCallFn("Store/clear", biStoreClear,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["close"],
                  fn: newNativeCallFn("Store/close", biStoreClose,
                                      acceptsNamed = false))])
  storeScope.define("sqlite", newNamespace("store/sqlite", storeSqliteScope))
  storeScope.define("fs", newNamespace("store/fs", storeFsScope))
  root.define("store", newNamespace("store", storeScope))

  # os: env, subprocess, line input (examples/ai_agent/design.md §3,§6). Capabilities are
  # ambient values like Net/Connect; a launcher can withhold them.
  let osScope = newScope(root)
  osScope.define("Env", newCapability("Os/Env"))
  osScope.define("Exec", newCapability("Os/Exec"))
  osScope.define("get-env", newNativeCallFn("os/get-env", biOsGetEnv,
                 acceptsNamed = false))
  osScope.define("env?", newNativeCallFn("os/env?", biOsEnvOpt,
                 acceptsNamed = false))
  osScope.define("exec", newNativeCallFn("os/exec", biOsExec))
  osScope.define("exec-stream", newNativeCallFn("os/exec-stream", biOsExecStream))
  osScope.define("exec-stdio", newNativeCallFn("os/exec-stdio", biOsExecStdio))
  osScope.define("exec-async", newNativeCallFn("os/exec-async", biOsExecAsync))
  osScope.define("exec-stream-async",
                 newNativeCallFn("os/exec-stream-async", biOsExecStreamAsync))
  osScope.define("stdin-tty?", newNativeFn("os/stdin-tty?", biOsStdinTty))
  osScope.define("read-line", newNativeFn("os/read-line", biOsReadLine))
  osScope.define("read-input", newNativeCallFn("os/read-input", biOsReadInput))
  osScope.define("refresh-input", newNativeCallFn("os/refresh-input", biOsRefreshInput))
  osScope.define("close-input", newNativeFn("os/close-input", biOsCloseInput))
  osScope.define("OsError", osError)
  root.define("os", newNamespace("os", osScope))

  # repl: shared declaration-persistent REPL loop used by the CLI wrapper and
  # interactive programs that need a scoped sub-REPL.
  let replScope = newScope(root)
  replScope.define("run", newNativeCallFn("repl/run", biReplRun))
  root.define("repl", newNamespace("repl", replScope))

  # Extend the existing Fs namespace (built in vm.nim) with sync helpers the
  # agent file tools need.
  let fsNs = root.vars.getOrDefault("Fs", VOID)
  if fsNs.kind == vkNamespace:
    fsNs.nsScope.define("read-text",
      newNativeCallFn("Fs/read-text", biFsReadTextSync, acceptsNamed = false))
    fsNs.nsScope.define("write-text",
      newNativeCallFn("Fs/write-text", biFsWriteTextSync, acceptsNamed = false))
    fsNs.nsScope.define("list-dir",
      newNativeCallFn("Fs/list-dir", biFsListDir, acceptsNamed = false))
    fsNs.nsScope.define("make-dir",
      newNativeCallFn("Fs/make-dir", biFsMakeDir, acceptsNamed = false))
    fsNs.nsScope.define("remove",
      newNativeCallFn("Fs/remove", biFsRemove, acceptsNamed = false))
    fsNs.nsScope.define("real-path",
      newNativeCallFn("Fs/real-path", biFsRealPath, acceptsNamed = false))

  # json: parse/stringify over Gene value kinds (examples/ai_agent/design.md §5).
  let jsonScope = newScope(root)
  jsonScope.define("parse", newNativeCallFn("json/parse", biJsonParse,
                                            acceptsNamed = false))
  jsonScope.define("stringify", newNativeCallFn("json/stringify",
                                                biJsonStringify,
                                                acceptsNamed = false))
  jsonScope.define("JsonError", jsonError)
  root.define("json", newNamespace("json", jsonScope))

  # serde: Gene-text serialization data core (docs/proposals/serialization.md
  # stage 1).
  let serdeScope = newScope(root)
  serdeScope.define("write-data",
    newNativeCallFn("serde/write-data", biSerdeWriteData,
                    acceptsNamed = false))
  serdeScope.define("read-data",
    newNativeCallFn("serde/read-data", biSerdeReadData))
  serdeScope.define("write",
    newNativeCallFn("serde/write", biSerdeWrite, acceptsNamed = false))
  serdeScope.define("read",
    newNativeCallFn("serde/read", biSerdeRead))
  serdeScope.define("data?",
    newNativeCallFn("serde/data?", biSerdeDataP, acceptsNamed = false))
  serdeScope.define("SerdeError", serdeError)
  serdeScope.define("SerdeRef", root.vars["SerdeRef"])
  let intField = proc (name: string): TypeField =
    TypeField(name: name, optional: true, typeExpr: newSym("Int"),
              scope: root)
  let serdePolicyType = newType("SerdePolicy", NIL,
                                @[intField("max-bytes"),
                                  intField("max-nodes"),
                                  intField("max-depth"),
                                  intField("max-symbols"),
                                  TypeField(name: "allow-restore",
                                            optional: true,
                                            typeExpr: newSym("Bool"),
                                            scope: root)],
                                @[], root)
  serdeScope.define("SerdePolicy", serdePolicyType)
  root.define("serde", newNamespace("serde", serdeScope))
