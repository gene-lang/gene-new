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

# --- os: environment, subprocess, and line input (docs/ai-agent.md §3,§6) ---
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
# §12.9 gap-1 problem in docs/ai-agent.md. These variants run the child on a
# dedicated OS thread and settle an external Task, following the proven
# foreign-thread pattern (tests/test_native_api_threads.nim, the aio worker's
# runAsyncIoRequest): every value crossing threads is markSharedValue'd so its
# refcount is atomic, handoff goes through the lock-protected channel/task
# paths, and the worker never runs Gene code.

when compileOption("threads"):
  # Job records cross the scheduler->worker thread boundary, so they must be
  # RC-hygienic on the default orc build: {.acyclic.} keeps them out of the
  # thread-local cycle-collector registry, Values carry their own (atomic,
  # once markSharedValue'd) refcounts, and the scheduler is a raw pointer —
  # the Application keeps it alive for the process lifetime, and workers only
  # borrow it through {.cursor.} casts so its non-atomic Nim refcount is
  # never touched off-thread.
  type OsExecAsyncCtx {.acyclic.} = ref object
    name: string          # native name, for error messages
    cmd: string
    procArgs: seq[string]
    workdir: string
    timeoutMs: int
    maxBytes: int
    task: Value           # external Task; marked shared by the spawner
    lineChan: Value       # NIL, or a Channel receiving stdout lines
    # The spawner's scheduler, captured at spawn time. NOT the dispatch scope:
    # call scopes are pooled and their .application is nilled on release, so a
    # scope captured here would resolve to no scheduler by the time the worker
    # settles — wakes would be lost and fibers parked on the task/channel
    # would never resume.
    schedulerPtr: pointer

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
  var osExecAsyncQueue: seq[OsExecAsyncCtx]
  var osExecAsyncThreads: seq[ref Thread[void]]
  var osExecAsyncIdle = 0
  initLock(osExecAsyncLock)
  initCond(osExecAsyncCond)

  proc runOsExecAsyncJob(ctx: OsExecAsyncCtx) {.gcsafe.} =
    {.cast(gcsafe).}:
      # Borrow the spawner's scheduler without touching its refcount; all
      # wakes below go through the explicit *In variants.
      let sched {.cursor.} = cast[SchedulerState](ctx.schedulerPtr)
      defer:
        endExternalNativeOp()
      var outText = ""
      var errText = ""
      var outTruncated = false
      var errTruncated = false
      var timedOut = false
      var lineBuf = ""
      var exitCode = 0
      var chanGone = ctx.lineChan.kind == vkNil
      let deadline =
        if ctx.timeoutMs >= 0:
          getMonoTime() + initDuration(milliseconds = ctx.timeoutMs)
        else:
          getMonoTime()

      proc appendCapped(into: var string, truncated: var bool, chunk: string) =
        if into.len >= ctx.maxBytes:
          if chunk.len > 0:
            truncated = true
          return
        if into.len + chunk.len <= ctx.maxBytes:
          into.add chunk
        else:
          truncated = true
          into.add chunk.substr(0, ctx.maxBytes - into.len - 1)

      proc sendLine(line: string) =
        ## Push one stdout line with bounded backpressure: retry while the
        ## channel is full, give up (but keep capturing) once it is closed or
        ## the exec deadline passes. The value is marked shared before it
        ## becomes visible cross-thread, so its refcount ops are atomic.
        if chanGone:
          return
        while true:
          let item = newStr(line)
          markSharedValue(item)
          let pushed = ctx.lineChan.tryPushChannel(item)
          if pushed.pushed:
            wakeChannelWaitersIn(sched, ctx.lineChan, wakeSenders = false)
            return
          if pushed.closed:
            chanGone = true
            return
          if ctx.timeoutMs >= 0 and getMonoTime() >= deadline:
            return
          os.sleep(1)

      proc handleStdoutChunk(chunk: string) =
        appendCapped(outText, outTruncated, chunk)
        if chanGone:
          return
        for ch in chunk:
          if ch == '\n':
            if lineBuf.len > 0 and lineBuf[^1] == '\r':
              lineBuf.setLen(lineBuf.len - 1)
            sendLine(lineBuf)
            lineBuf.setLen(0)
          else:
            lineBuf.add ch

      proc closeLineChan() =
        if ctx.lineChan.kind != vkNil:
          closeChannel(ctx.lineChan)
          wakeAllChannelWaitersIn(sched, ctx.lineChan, wakeSenders = false)
          wakeAllChannelWaitersIn(sched, ctx.lineChan, wakeSenders = true)

      proc settle(value: Value) =
        markSharedValue(value)
        closeLineChan()
        if tryCompleteTask(ctx.task, value):
          wakeTaskWaitersIn(sched, ctx.task)

      proc settleFail(message: string) =
        closeLineChan()
        if tryFailTask(ctx.task, message):
          wakeTaskWaitersIn(sched, ctx.task)

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
            proc drainAvailable(fd: cint, isOut: bool) =
              while true:
                let n = read(fd, addr buf[0], buf.len)
                if n > 0:
                  var chunk = newString(n)
                  copyMem(addr chunk[0], addr buf[0], n)
                  if isOut:
                    handleStdoutChunk(chunk)
                  else:
                    appendCapped(errText, errTruncated, chunk)
                else:
                  break
            while process.running:
              drainAvailable(outFd, true)
              drainAvailable(errFd, false)
              if ctx.timeoutMs >= 0 and getMonoTime() >= deadline:
                timedOut = true
                process.terminate()
                break
              os.sleep(osExecPollMs)
            exitCode = if timedOut: (discard process.waitForExit(); -1)
                       else: process.waitForExit()
            drainAvailable(outFd, true)
            drainAvailable(errFd, false)
          else:
            exitCode = process.waitForExit(
              if ctx.timeoutMs >= 0: ctx.timeoutMs else: -1)
            if process.running:
              timedOut = true
              process.terminate()
              exitCode = -1
            handleStdoutChunk(process.outputStream.readAll())
            appendCapped(errText, errTruncated, process.errorStream.readAll())
          if lineBuf.len > 0:
            sendLine(lineBuf)
            lineBuf.setLen(0)
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
        var job: OsExecAsyncCtx = nil
        withLock osExecAsyncLock:
          while osExecAsyncQueue.len == 0:
            inc osExecAsyncIdle
            wait(osExecAsyncCond, osExecAsyncLock)
            dec osExecAsyncIdle
          job = osExecAsyncQueue[0]
          osExecAsyncQueue.delete(0)
        runOsExecAsyncJob(job)

  proc enqueueOsExecAsyncJob(ctx: OsExecAsyncCtx) =
    var needThread = false
    withLock osExecAsyncLock:
      osExecAsyncQueue.add ctx
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
    let task = newExternalTask()
    markSharedValue(task)
    if lineChan.kind != vkNil:
      markSharedValue(lineChan)
    let ctx = OsExecAsyncCtx(name: name, cmd: cmd, procArgs: procArgs,
                             workdir: workdir, timeoutMs: timeoutMs,
                             maxBytes: maxBytes, task: task,
                             lineChan: lineChan,
                             schedulerPtr: cast[pointer](
                               schedulerForScope(scope)))
    beginExternalNativeOp()
    try:
      enqueueOsExecAsyncJob(ctx)
    except CatchableError as e:
      endExternalNativeOp()
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

# --- fs: synchronous read + directory listing (docs/ai-agent.md §6) ---

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

# --- json: parse and stringify over Gene value kinds (docs/ai-agent.md §5) ---

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

  # os: env, subprocess, line input (docs/ai-agent.md §3,§6). Capabilities are
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

  # json: parse/stringify over Gene value kinds (docs/ai-agent.md §5).
  let jsonScope = newScope(root)
  jsonScope.define("parse", newNativeCallFn("json/parse", biJsonParse,
                                            acceptsNamed = false))
  jsonScope.define("stringify", newNativeCallFn("json/stringify",
                                                biJsonStringify,
                                                acceptsNamed = false))
  jsonScope.define("JsonError", jsonError)
  root.define("json", newNamespace("json", jsonScope))
