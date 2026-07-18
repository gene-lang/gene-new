## Gene standard library surface (docs/stdlib.md).
##
## This file is `include`d by vm.nim after the core native helpers are
## defined: the stdlib natives use the VM's require*/applyCall/raise* helpers
## and the socket imports from vm.nim's prelude. Everything user-facing here
## is registered by `registerStdlibNamespaces`, which buildBuiltins calls on
## the built-ins root scope; nothing in this file touches VM dispatch state.

type CursesPane = object
  title: string
  output: string
  scroll: int
  focused: bool
  maximized: bool
  terminalId: int

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  var terminalSessions = initTable[int, TerminalSession]()
  var terminalSessionNextId = 1

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  type
    CursesWindow = pointer
    CursesTranscriptRow = object
      text: string
      pair: int
    CursesTranscriptCache = object
      valid: bool
      output: string
      width: int
      rows: seq[CursesTranscriptRow]

  var cursesMainTranscriptCache: CursesTranscriptCache
  var cursesPaneTranscriptCaches: seq[CursesTranscriptCache]
  var cursesTerminalPairs = initTable[(int, int), int]()
  var cursesTerminalNextPair = 5

  proc clearCursesTranscriptCaches() =
    cursesMainTranscriptCache = default(CursesTranscriptCache)
    cursesPaneTranscriptCaches.setLen(0)
    cursesTerminalPairs.clear()
    cursesTerminalNextPair = 5

  proc cInitscr(): CursesWindow {.importc: "initscr", header: "<ncurses.h>".}
  proc cEndwin(): cint {.importc: "endwin", header: "<ncurses.h>".}
  proc raw(): cint {.importc, header: "<ncurses.h>".}
  proc nocbreak(): cint {.importc, header: "<ncurses.h>".}
  proc noecho(): cint {.importc, header: "<ncurses.h>".}
  proc cEcho(): cint {.importc: "echo", header: "<ncurses.h>".}
  proc noraw(): cint {.importc, header: "<ncurses.h>".}
  proc keypad(win: CursesWindow, bf: cint): cint {.importc, header: "<ncurses.h>".}
  proc curs_set(visibility: cint): cint {.importc, header: "<ncurses.h>".}
  proc reset_shell_mode(): cint {.importc, header: "<ncurses.h>".}
  proc werase(win: CursesWindow): cint {.importc, header: "<ncurses.h>".}
  proc refresh(): cint {.importc, header: "<ncurses.h>".}
  proc cMove(y, x: cint): cint {.importc: "move", header: "<ncurses.h>".}
  proc clrtoeol(): cint {.importc, header: "<ncurses.h>".}
  proc addnstr(s: cstring, n: cint): cint {.importc, header: "<ncurses.h>".}
  proc getch(): cint {.importc, header: "<ncurses.h>".}
  proc ungetch(ch: cint): cint {.importc, header: "<ncurses.h>".}
  proc beep(): cint {.importc, header: "<ncurses.h>".}
  proc timeout(delay: cint) {.importc, header: "<ncurses.h>".}
  proc start_color(): cint {.importc, header: "<ncurses.h>".}
  proc use_default_colors(): cint {.importc, header: "<ncurses.h>".}
  proc init_pair(pair, fg, bg: cshort): cint {.importc, header: "<ncurses.h>".}
  proc cAttrOn(attrs: cint): cint {.importc: "attron", header: "<ncurses.h>".}
  proc cAttrOff(attrs: cint): cint {.importc: "attroff", header: "<ncurses.h>".}

  {.emit: """
#include <locale.h>
#include <ncurses.h>
#include <signal.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
static struct termios gene_curses_orig_termios;
static int gene_curses_termios_saved = 0;
static int gene_curses_restore_hooks_installed = 0;
static volatile sig_atomic_t gene_turn_interrupt_pending = 0;
static struct sigaction gene_turn_interrupt_old;
static int gene_turn_interrupt_active = 0;
static int gene_curses_color_pair(short pair) { return COLOR_PAIR(pair); }
static int gene_curses_attr_bold(void) { return A_BOLD; }
static int gene_curses_attr_dim(void) { return A_DIM; }
static int gene_curses_attr_underline(void) { return A_UNDERLINE; }
static int gene_curses_attr_reverse(void) { return A_REVERSE; }
static int gene_curses_attr_blink(void) { return A_BLINK; }
static int gene_curses_attr_italic(void) {
#ifdef A_ITALIC
  return A_ITALIC;
#else
  return 0;
#endif
}
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
       DECSC/DECRC (\0337/\0338); otherwise output after close_input lands at
       the top of the screen and overwrites existing content. */
    const char *seq = "\033[?2004l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1l\033>\033[0m\033[?25h\0337\033[r\0338";
    write(STDOUT_FILENO, seq, sizeof("\033[?2004l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1l\033>\033[0m\033[?25h\0337\033[r\0338") - 1);
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
static void gene_turn_interrupt_handler(int sig) {
  (void)sig;
  gene_turn_interrupt_pending = 1;
}
static int gene_turn_interrupt_begin(void) {
  struct sigaction act;
  if (gene_turn_interrupt_active) {
    gene_turn_interrupt_pending = 0;
    return 0;
  }
  act.sa_handler = gene_turn_interrupt_handler;
  sigemptyset(&act.sa_mask);
  act.sa_flags = 0;
  gene_turn_interrupt_pending = 0;
  if (sigaction(SIGINT, &act, &gene_turn_interrupt_old) != 0) return -1;
  gene_turn_interrupt_active = 1;
  return 0;
}
static int gene_turn_interrupt_take(void) {
  int pending = gene_turn_interrupt_pending != 0;
  gene_turn_interrupt_pending = 0;
  return pending;
}
static void gene_turn_interrupt_end(void) {
  if (!gene_turn_interrupt_active) return;
  sigaction(SIGINT, &gene_turn_interrupt_old, NULL);
  gene_turn_interrupt_active = 0;
  gene_turn_interrupt_pending = 0;
}
""".}
  proc cColorPair(pair: cshort): cint {.importc: "gene_curses_color_pair".}
  proc cAttrBold(): cint {.importc: "gene_curses_attr_bold".}
  proc cAttrDim(): cint {.importc: "gene_curses_attr_dim".}
  proc cAttrUnderline(): cint {.importc: "gene_curses_attr_underline".}
  proc cAttrReverse(): cint {.importc: "gene_curses_attr_reverse".}
  proc cAttrBlink(): cint {.importc: "gene_curses_attr_blink".}
  proc cAttrItalic(): cint {.importc: "gene_curses_attr_italic".}
  proc cSetLocale() {.importc: "gene_curses_setlocale".}
  proc cSaveTermios() {.importc: "gene_curses_save_termios".}
  proc cRestoreTermios() {.importc: "gene_curses_restore_termios".}
  proc cRestoreDisplay() {.importc: "gene_curses_restore_display".}
  proc cInstallRestoreHooks() {.importc: "gene_curses_install_restore_hooks".}
  proc cTurnInterruptBegin(): cint {.importc: "gene_turn_interrupt_begin".}
  proc cTurnInterruptTake(): cint {.importc: "gene_turn_interrupt_take".}
  proc cTurnInterruptEnd() {.importc: "gene_turn_interrupt_end".}

  var stdscr {.importc: "stdscr", header: "<ncurses.h>".}: CursesWindow
  var LINES {.importc: "LINES", header: "<ncurses.h>".}: cint
  var COLS {.importc: "COLS", header: "<ncurses.h>".}: cint
  var COLORS {.importc: "COLORS", header: "<ncurses.h>".}: cint
  var COLOR_PAIRS {.importc: "COLOR_PAIRS", header: "<ncurses.h>".}: cint

  {.emit: "#undef clear".}

  const
    CursesErr = -1
    KeyCtrlPageUp = -2
    KeyCtrlPageDown = -3
    KeyShiftPageUp = -4
    KeyShiftPageDown = -5
    # ncurses with extended xterm names enabled decodes CSI 5;5~/6;5~ before
    # callers can inspect the raw sequence. Keep those common extended codes
    # alongside the raw-sequence fallbacks above.
    KeyCtrlPageUpNcurses = 557
    KeyCtrlPageDownNcurses = 552
    KeyCtrlC = 3
    KeyCtrlD = 4
    KeyCtrlE = 5
    KeyTab = 9
    KeyCtrlR = 18
    KeyEsc = 27
    KeyEnter = 10
    KeyReturn = 13
    KeyBackspace = 263
    KeyDelete = 330
    KeyLeft = 260
    KeyRight = 261
    KeyUp = 259
    KeyDown = 258
    KeyHome = 262
    KeyEnd = 360
    KeyPageDown = 338
    KeyPageUp = 339
    KeyNcursesEnter = 343
    KeyMouse = 409
    KeyResize = 410
    KeyF1 = 265
    KeyF12 = 276
    ColorGreen = 2
    ColorCyan = 6
    ColorWhite = 7
    PairInput = 1
    PairOutput = 2
    PairSeparator = 3
    PairStatus = 4
    PairTerminalFirst = 5

  var cursesInputActive = false
  var cursesColorsReady = false
  var cursesPasteReady = false
  var cursesScreenNextId = 1
  var cursesScreenActiveId = 0
  var cursesEventText = ""
  var cursesEventTextExpected = 0
  var cursesFocusedTerminalRect:
    tuple[valid: bool, top, left, height, width: int]

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

proc biStrByteSize(args: openArray[Value]): Value {.nimcall.} =
  requireOne("str/byte_size", args)
  requireStr("str/byte_size", args[0])
  newInt(args[0].strVal.len)

proc biStrSliceBytes(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "str/slice_bytes expects 3 arguments, got " & $args.len)
  requireStr("str/slice_bytes", args[0])
  let start = int(requireInt64("str/slice_bytes start", args[1]))
  let maxBytes = int(requireInt64("str/slice_bytes max_bytes", args[2]))
  if start < 0 or maxBytes < 0:
    raise newException(GeneError,
      "str/slice_bytes start and max_bytes must be non-negative")
  let value = args[0].strVal
  if start > value.len:
    raise newException(GeneError,
      "str/slice_bytes start exceeds string byte size")
  if start < value.len and (ord(value[start]) and 0xC0) == 0x80:
    raise newException(GeneError,
      "str/slice_bytes start must be a UTF-8 boundary")
  var stop =
    if maxBytes > value.len - start: value.len
    else: start + maxBytes
  while stop > start and stop < value.len and
      (ord(value[stop]) and 0xC0) == 0x80:
    dec stop
  if stop <= start:
    return newStr("")
  newStr(value[start ..< stop])

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
  var props = initPropTable()
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
                       scope: Scope): PropTable =
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
# Host authority is capability-gated exactly like Fs/Net: `os/get_env` needs an
# `Os/Env` value and `os/exec`/`os/exec_stdio` need `Os/Exec`, so a launcher can
# hand out env+file access without shell access. Errors are the typed `OsError`.

proc raiseOsError(message: string, scope: Scope) =
  var props = initPropTable()
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
      "os/get_env expects (Os/Env, name) or (Os/Env, name, default), got " &
      $args.len & " arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsEnv("os/get_env", args[0], scope)
  requireStr("os/get_env name", args[1])
  if existsEnv(args[1].strVal):
    newStr(getEnv(args[1].strVal))
  elif args.len == 3:
    args[2]
  else:
    raiseOsError("os/get_env: environment variable not set: " &
                 args[1].strVal, scope)
    NIL

proc biOsEnvOpt(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "os/env? expects (Os/Env, name)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsEnv("os/env?", args[0], scope)
  requireStr("os/env? name", args[1])
  if existsEnv(args[1].strVal): newStr(getEnv(args[1].strVal)) else: NIL

proc biOsExecutablePath(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError,
      "os/executable_path expects no arguments, got " & $args.len)
  newStr(getAppFilename())

const osExecDefaultOutputCap = 1024 * 1024
const osExecPollMs = 5

proc biOsExec(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Run a subprocess and return {^status ^stdout ^stderr ^timed_out}.
  ## `^cmd` is the program, `^args` a list of Str arguments (no shell parsing
  ## unless the caller passes a shell explicitly), `^timeout_ms` bounds the run,
  ## and captured output is truncated at `^max_bytes`. Never uses a shell to
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
      of "timeout_ms": timeoutMs = int(requireInt64("os/exec ^timeout_ms", v))
      of "max_bytes": maxBytes = int(requireInt64("os/exec ^max_bytes", v))
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
  var props = initPropTable()
  props["status"] = newInt(exitCode)
  props["stdout"] = newStr(outText)
  props["stderr"] = newStr(errText)
  props["stdout_truncated"] = if outTruncated: TRUE else: FALSE
  props["stderr_truncated"] = if errTruncated: TRUE else: FALSE
  props["truncated"] = if outTruncated or errTruncated: TRUE else: FALSE
  props["timed_out"] = if timedOut: TRUE else: FALSE
  newMap(props)

proc biOsExecStream(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Run a subprocess like os/exec, but invoke optional callbacks as output
  ## arrives: ^stdout receives raw chunks and ^stdout_line receives complete
  ## stdout lines without the trailing newline. The final return value keeps the
  ## same captured-output shape as os/exec.
  if args.len != 1:
    raise newException(GeneError,
      "os/exec_stream expects the Os/Exec capability plus named arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsExec("os/exec_stream", args[0], scope)
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
        requireStr("os/exec_stream ^cmd", v)
        cmd = v.strVal
        cmdSet = true
      of "args":
        if v.kind != vkList:
          raiseOsError("os/exec_stream ^args must be a List of Str", scope)
        for item in v.listItems:
          requireStr("os/exec_stream ^args item", item)
          procArgs.add item.strVal
      of "timeout_ms": timeoutMs = int(requireInt64("os/exec_stream ^timeout_ms", v))
      of "max_bytes": maxBytes = int(requireInt64("os/exec_stream ^max_bytes", v))
      of "dir":
        requireStr("os/exec_stream ^dir", v)
        workdir = v.strVal
      of "stdout":
        stdoutCb = v
      of "stdout_line":
        stdoutLineCb = v
      of "stderr":
        stderrCb = v
      else:
        raiseOsError("os/exec_stream got unexpected named argument: " & name, scope)
  if not cmdSet or cmd.len == 0:
    raiseOsError("os/exec_stream requires a non-empty ^cmd", scope)
  if maxBytes <= 0:
    maxBytes = osExecDefaultOutputCap

  var process: Process
  try:
    process = startProcess(cmd, workingDir = workdir, args = procArgs,
                           options = {poUsePath})
  except OSError as e:
    raiseOsError("os/exec_stream could not start '" & cmd & "': " & e.msg, scope)

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
      var props = initPropTable()
      props["status"] = newInt(exitCode)
      props["stdout"] = newStr(outText)
      props["stderr"] = newStr(errText)
      props["stdout_truncated"] = if outTruncated: TRUE else: FALSE
      props["stderr_truncated"] = if errTruncated: TRUE else: FALSE
      props["truncated"] = if outTruncated or errTruncated: TRUE else: FALSE
      props["timed_out"] = if timedOut: TRUE else: FALSE
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
      var props = initPropTable()
      props["status"] = newInt(exitCode)
      props["stdout"] = newStr(outText)
      props["stderr"] = newStr(errText)
      props["stdout_truncated"] = if outTruncated: TRUE else: FALSE
      props["stderr_truncated"] = if errTruncated: TRUE else: FALSE
      props["truncated"] = if outTruncated or errTruncated: TRUE else: FALSE
      props["timed_out"] = if timedOut: TRUE else: FALSE
      return newMap(props)
  except:
    if process.running:
      process.terminate()
    raise
  finally:
    process.close()

when compileOption("threads"):
  # The sync and async inherited-stream variants share one physical terminal
  # and manipulate process-wide SIGINT disposition. Serialize both surfaces.
  var osExecStdioLock: Lock
  initLock(osExecStdioLock)

proc biOsExecStdio(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## Run a subprocess attached to this process's stdin/stdout/stderr and return
  ## its exit status. This is for terminal handoff cases where captured
  ## `os/exec` would break interactive behavior.
  if args.len != 1:
    raise newException(GeneError,
      "os/exec_stdio expects the Os/Exec capability plus named arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireOsExec("os/exec_stdio", args[0], scope)
  var cmd = ""
  var cmdSet = false
  var procArgs: seq[string]
  var workdir = ""
  if call != nil:
    for i, name in call[].namedNames:
      let v = call[].namedValues[i]
      case name
      of "cmd":
        requireStr("os/exec_stdio ^cmd", v)
        cmd = v.strVal
        cmdSet = true
      of "args":
        if v.kind != vkList:
          raiseOsError("os/exec_stdio ^args must be a List of Str", scope)
        for item in v.listItems:
          requireStr("os/exec_stdio ^args item", item)
          procArgs.add item.strVal
      of "dir":
        requireStr("os/exec_stdio ^dir", v)
        workdir = v.strVal
      else:
        raiseOsError("os/exec_stdio got unexpected named argument: " & name, scope)
  if not cmdSet or cmd.len == 0:
    raiseOsError("os/exec_stdio requires a non-empty ^cmd", scope)
  when compileOption("threads"):
    acquire(osExecStdioLock)
  var process: Process
  try:
    process = startProcess(cmd, workingDir = workdir, args = procArgs,
                           options = {poUsePath, poParentStreams})
  except OSError as e:
    when compileOption("threads"):
      release(osExecStdioLock)
    raiseOsError("os/exec_stdio could not start '" & cmd & "': " & e.msg, scope)
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
    when compileOption("threads"):
      release(osExecStdioLock)
    process.close()

# --- os/exec_async + os/exec_stream_async: subprocess on a dedicated thread ---
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
  # So the worker never dereferences task/channel Values and publishes only
  # plain shared-memory buffers; scheduler polling handles cancellation,
  # Gene-value construction, channel delivery, and settlement. Scheduler-only
  # pending refs own Task/Channel values; the worker ctx is plain shared memory.
  type
    SharedExecText = object
      data: pointer
      len: int
    SharedExecLine = object
      next: ptr SharedExecLine
      text: SharedExecText
    SharedExecArg = object
      next: ptr SharedExecArg
      text: SharedExecText
    OsExecAsyncCtx = object
      name: SharedExecText
      cmd: SharedExecText
      procArgs: ptr SharedExecArg
      workdir: SharedExecText
      inheritStdio: bool
      timeoutMs: int
      maxBytes: int
      taskBits: uint64      # external Task (OBJECT_TAG bits), worker-borrowed
      lineChanBits: uint64  # 0, or a Channel (bits) receiving stdout lines
      lineLock: Lock
      lineHead: ptr SharedExecLine
      lineTail: ptr SharedExecLine
      resultStatus: int
      resultStdout: SharedExecText
      resultStderr: SharedExecText
      resultStdoutTruncated: bool
      resultStderrTruncated: bool
      resultTimedOut: bool
      resultFailed: bool
      resultFailure: SharedExecText
      resultCancelled: bool
      cancelRequested: bool
      # The spawner's scheduler, captured at spawn time. NOT the dispatch scope:
      # call scopes are pooled and their .application is nilled on release, so a
      # scope captured here would resolve to no scheduler by the time the worker
      # settles — wakes would be lost and fibers parked on the task/channel
      # would never resume.
      schedulerPtr: pointer
      # Release-stored by the worker loop AFTER its final access to this job;
      # the scheduler frees the ctx (and drops the task/channel refs) only after
      # acquiring it. The scheduler then materializes and publishes the result.
      workerDone: bool
    OsExecPending {.acyclic.} = ref object
      ctx: ptr OsExecAsyncCtx
      taskOwner: Value
      lineChanOwner: Value

  proc sharedExecText(text: string): SharedExecText =
    result.len = text.len
    if text.len > 0:
      result.data = allocShared0(text.len)
      copyMem(result.data, unsafeAddr text[0], text.len)

  proc consumeSharedExecText(text: var SharedExecText): string =
    if text.len > 0:
      result = newString(text.len)
      copyMem(addr result[0], text.data, text.len)
    if text.data != nil:
      deallocShared(text.data)
    text = SharedExecText()

  proc readSharedExecText(text: SharedExecText): string =
    if text.len > 0:
      result = newString(text.len)
      copyMem(addr result[0], text.data, text.len)

  proc freeSharedExecLines(head: ptr SharedExecLine) =
    var current = head
    while current != nil:
      let next = current.next
      if current.text.data != nil:
        deallocShared(current.text.data)
      deallocShared(current)
      current = next

  proc freeOsExecCtx(ctx: ptr OsExecAsyncCtx) =
    if ctx == nil:
      return
    discard consumeSharedExecText(ctx.name)
    discard consumeSharedExecText(ctx.cmd)
    discard consumeSharedExecText(ctx.workdir)
    discard consumeSharedExecText(ctx.resultStdout)
    discard consumeSharedExecText(ctx.resultStderr)
    discard consumeSharedExecText(ctx.resultFailure)
    freeSharedExecLines(ctx.lineHead)
    var arg = ctx.procArgs
    while arg != nil:
      let next = arg.next
      if arg.text.data != nil:
        deallocShared(arg.text.data)
      deallocShared(arg)
      arg = next
    deinitLock(ctx.lineLock)
    deallocShared(ctx)

  # Persistent exec-worker pool. Threads are created on demand up to a cap and
  # kept for later jobs, matching the scheduler's aio lane and avoiding repeated
  # thread startup for long-lived agents. Jobs queue when all workers are busy;
  # the cap is generous because jobs can legitimately be long (60s streaming
  # curl).
  const osExecAsyncMaxWorkers = 32

  var osExecAsyncLock: Lock
  var osExecAsyncCond: Cond
  var osExecAsyncQueue: seq[pointer]   # borrowed OsExecAsyncCtx; registry owns
  var osExecAsyncThreads: seq[ref Thread[void]]
  var osExecAsyncIdle = 0
  # Inherited-terminal children share process-wide signal disposition and one
  # physical terminal. Serialize them even though captured exec jobs may run
  # concurrently on the rest of the worker pool.
  initLock(osExecAsyncLock)
  initCond(osExecAsyncCond)

  # Exec workers never touch this registry. Calls may nevertheless originate
  # from more than one scheduler lane, so the exec lock serializes prune/add.
  # Strong pending refs live only on scheduler lanes; workers borrow raw ctx
  # pointers and never touch the pending Task/Channel Value owners.
  var osExecAsyncPending: seq[OsExecPending]

  proc pollOsExecAsyncCompletions() =
    ## Materialize Gene values and release completed jobs on the scheduler
    ## thread. Worker threads publish only native strings/ints; allocating a
    ## Gene value on a worker and freeing it on another thread corrupts ORC's
    ## thread-local allocator even when its manual refcount is atomic.
    withLock osExecAsyncLock:
      var i = 0
      while i < osExecAsyncPending.len:
        let pending {.cursor.} = osExecAsyncPending[i]
        let ctx = pending.ctx
        var task {.cursor.}: Value
        task.bits = ctx.taskBits
        let taskCancelled = task.taskCancelled
        if taskCancelled:
          atomicStoreN(addr ctx.cancelRequested, true, ATOMIC_RELEASE)
        let cancelling = ctx.resultCancelled or taskCancelled
        var lineHead, lineTail: ptr SharedExecLine
        withLock ctx.lineLock:
          lineHead = ctx.lineHead
          lineTail = ctx.lineTail
          ctx.lineHead = nil
          ctx.lineTail = nil
        var channelBlocked = false
        if cancelling:
          freeSharedExecLines(lineHead)
          lineHead = nil
        elif ctx.lineChanBits != 0:
          var channel {.cursor.}: Value
          channel.bits = ctx.lineChanBits
          while lineHead != nil:
            let line = consumeSharedExecText(lineHead.text)
            let pushed = channel.tryPushChannel(newStr(line))
            if pushed.closed:
              freeSharedExecLines(lineHead)
              lineHead = nil
              break
            if not pushed.pushed:
              lineHead.text = sharedExecText(line)
              channelBlocked = true
              break
            let consumed = lineHead
            lineHead = lineHead.next
            deallocShared(consumed)
            wakeChannelWaitersIn(
              cast[SchedulerState](ctx.schedulerPtr), channel,
              wakeSenders = false)
        if lineHead != nil:
          withLock ctx.lineLock:
            lineTail.next = ctx.lineHead
            ctx.lineHead = lineHead
            if ctx.lineTail == nil:
              ctx.lineTail = lineTail
        let workerDone = atomicLoadN(addr ctx.workerDone, ATOMIC_ACQUIRE)
        if workerDone and not channelBlocked:
          var channel {.cursor.}: Value
          channel.bits = ctx.lineChanBits
          if ctx.lineChanBits != 0:
            closeChannel(channel)
            let scheduler = cast[SchedulerState](ctx.schedulerPtr)
            wakeAllChannelWaitersIn(scheduler, channel, wakeSenders = false)
            wakeAllChannelWaitersIn(scheduler, channel, wakeSenders = true)
          if not ctx.resultCancelled and not task.taskCancelled:
            if ctx.resultFailed:
              let failure = consumeSharedExecText(ctx.resultFailure)
              if tryFailTask(task, failure):
                wakeTaskWaitersIn(cast[SchedulerState](ctx.schedulerPtr), task)
            elif ctx.inheritStdio:
              if tryCompleteTask(task, newInt(ctx.resultStatus)):
                wakeTaskWaitersIn(cast[SchedulerState](ctx.schedulerPtr), task)
            else:
              var props = initPropTable()
              props["status"] = newInt(ctx.resultStatus)
              props["stdout"] = newStr(consumeSharedExecText(ctx.resultStdout))
              props["stderr"] = newStr(consumeSharedExecText(ctx.resultStderr))
              props["stdout_truncated"] = newBool(ctx.resultStdoutTruncated)
              props["stderr_truncated"] = newBool(ctx.resultStderrTruncated)
              props["truncated"] = newBool(ctx.resultStdoutTruncated or
                                             ctx.resultStderrTruncated)
              props["timed_out"] = newBool(ctx.resultTimedOut)
              if tryCompleteTask(task, newMap(props)):
                wakeTaskWaitersIn(cast[SchedulerState](ctx.schedulerPtr), task)
          else:
            discard consumeSharedExecText(ctx.resultStdout)
            discard consumeSharedExecText(ctx.resultStderr)
            discard consumeSharedExecText(ctx.resultFailure)
          endExternalNativeOp()
          pending.ctx = nil
          freeOsExecCtx(ctx)
          let last = osExecAsyncPending.high
          if i != last:
            osExecAsyncPending[i] = move osExecAsyncPending[last]
          osExecAsyncPending.setLen(last)
        else:
          inc i
    pollHttpClientCompletions()
    pollCursesInputCompletions()

  proc runOsExecAsyncJob(jobPtr: pointer) {.gcsafe.} =
    {.cast(gcsafe).}:
      # The worker owns only local Nim data and explicitly shared raw buffers.
      # It never constructs a Gene Value or touches an ORC-managed object from
      # the scheduler heap.
      let ctx = cast[ptr OsExecAsyncCtx](jobPtr)
      let nativeName = readSharedExecText(ctx.name)
      let nativeCmd = readSharedExecText(ctx.cmd)
      let nativeWorkdir = readSharedExecText(ctx.workdir)
      var nativeArgs: seq[string]
      var nativeArg = ctx.procArgs
      while nativeArg != nil:
        nativeArgs.add readSharedExecText(nativeArg.text)
        nativeArg = nativeArg.next
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
        ## Publish native text only. The scheduler turns it into Gene strings.
        block sendBlock:
          if not chanGone:
            let node = cast[ptr SharedExecLine](allocShared0(sizeof(SharedExecLine)))
            node.text = sharedExecText(line)
            withLock ctx.lineLock:
              if ctx.lineTail == nil:
                ctx.lineHead = node
                ctx.lineTail = node
              else:
                ctx.lineTail.next = node
                ctx.lineTail = node

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

      template settleFail(message: string) =
        block:
          ctx.resultFailed = true
          ctx.resultFailure = sharedExecText(message)

      template cancellationRequested(): bool =
        atomicLoadN(addr ctx.cancelRequested, ATOMIC_ACQUIRE)

      if cancellationRequested():
        ctx.resultCancelled = true
        return

      if ctx.inheritStdio:
        # Parent-stream handoff is intentionally a separate path: attempting
        # to inspect output handles from a poParentStreams Process is invalid,
        # and inherited terminal bytes must never be captured or materialized
        # as Gene values on this worker thread.
        acquire(osExecStdioLock)
        try:
          if cancellationRequested():
            ctx.resultCancelled = true
            return
          var process: Process
          try:
            process = startProcess(nativeCmd, workingDir = nativeWorkdir,
                                   args = nativeArgs,
                                   options = {poUsePath, poParentStreams})
          except CatchableError as e:
            settleFail(nativeName & " could not start '" & nativeCmd & "': " &
                       e.msg)
            return
          # system(3) semantics: after the child inherited the current signal
          # handlers, ignore terminal Ctrl-C in the parent until handoff ends.
          # The lock above prevents overlapping handoffs from restoring one
          # another's signal disposition out of order.
          when defined(posix):
            var ignoreInt, oldInt: Sigaction
            ignoreInt.sa_handler = SIG_IGN
            discard sigemptyset(ignoreInt.sa_mask)
            ignoreInt.sa_flags = 0
            let intIgnored = sigaction(SIGINT, ignoreInt, oldInt) == 0
          try:
            while process.running:
              if cancellationRequested():
                cancelled = true
                process.terminate()
                break
              os.sleep(osExecPollMs)
            if cancelled:
              discard process.waitForExit()
              ctx.resultCancelled = true
            else:
              ctx.resultStatus = process.waitForExit()
          except CatchableError as e:
            settleFail(nativeName & " failed: " & e.msg)
          finally:
            when defined(posix):
              if intIgnored:
                discard sigaction(SIGINT, oldInt, nil)
            try:
              process.close()
            except CatchableError:
              discard
        finally:
          release(osExecStdioLock)
        return

      var process: Process
      try:
        process = startProcess(nativeCmd, workingDir = nativeWorkdir,
                               args = nativeArgs, options = {poUsePath})
      except CatchableError as e:
        settleFail(nativeName & " could not start '" & nativeCmd & "': " & e.msg)
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
            ctx.resultCancelled = true
            return
          ctx.resultStatus = exitCode
          ctx.resultStdout = sharedExecText(outText)
          ctx.resultStderr = sharedExecText(errText)
          ctx.resultStdoutTruncated = outTruncated
          ctx.resultStderrTruncated = errTruncated
          ctx.resultTimedOut = timedOut
        except CatchableError as e:
          settleFail(nativeName & " failed: " & e.msg)
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
        let doneCtx = cast[ptr OsExecAsyncCtx](jobPtr)
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

else:
  proc pollOsExecAsyncCompletions() =
    pollHttpClientCompletions()
    pollCursesInputCompletions()

proc biOsExecAsyncImpl(name: string, wantChan: bool,
                       inheritStdio: bool,
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
      of "timeout_ms":
        if inheritStdio:
          raiseOsError(name & " got unexpected named argument: timeout_ms", scope)
        timeoutMs = int(requireInt64(name & " ^timeout_ms", v))
      of "max_bytes":
        if inheritStdio:
          raiseOsError(name & " got unexpected named argument: max_bytes", scope)
        maxBytes = int(requireInt64(name & " ^max_bytes", v))
      of "dir":
        requireStr(name & " ^dir", v)
        workdir = v.strVal
      of "stdout_chan":
        if not wantChan:
          raiseOsError(name & " got unexpected named argument: stdout_chan",
                       scope)
        requireChannel(name & " ^stdout_chan", v)
        lineChan = v
      else:
        raiseOsError(name & " got unexpected named argument: " & argName,
                     scope)
  if not cmdSet or cmd.len == 0:
    raiseOsError(name & " requires a non-empty ^cmd", scope)
  if maxBytes <= 0:
    maxBytes = osExecDefaultOutputCap
  if wantChan and lineChan.kind == vkNil:
    raiseOsError(name & " requires ^stdout_chan (a Channel of stdout lines)",
                 scope)
  when compileOption("threads"):
    if scope == nil or scope.application == nil:
      raiseOsError(name & " requires a scheduler scope", scope)
    pollOsExecAsyncCompletions()
    let task = newExternalTask()
    markSharedValue(task)
    if lineChan.kind != vkNil:
      markSharedValue(lineChan)
    let ctx = cast[ptr OsExecAsyncCtx](allocShared0(sizeof(OsExecAsyncCtx)))
    ctx.name = sharedExecText(name)
    ctx.cmd = sharedExecText(cmd)
    ctx.workdir = sharedExecText(workdir)
    ctx.inheritStdio = inheritStdio
    ctx.timeoutMs = timeoutMs
    ctx.maxBytes = maxBytes
    ctx.taskBits = task.bits
    ctx.lineChanBits = if lineChan.kind == vkNil: 0'u64 else: lineChan.bits
    ctx.schedulerPtr = cast[pointer](schedulerForScope(scope))
    var argTail: ptr SharedExecArg
    for arg in procArgs:
      let argNode = cast[ptr SharedExecArg](allocShared0(sizeof(SharedExecArg)))
      argNode.text = sharedExecText(arg)
      if argTail == nil:
        ctx.procArgs = argNode
      else:
        argTail.next = argNode
      argTail = argNode
    initLock(ctx.lineLock)
    # `dup` is deliberate: task/lineChan are also returned/owned by the caller.
    # A sink into the ctx without the explicit retain would leave two logical
    # owners sharing one ref and completion cleanup would free the caller's
    # live handle.
    let pending = OsExecPending(ctx: ctx)
    pending.taskOwner = retainedCopy(task)
    pending.lineChanOwner = retainedCopy(lineChan)
    # Scheduler-side ownership: the pending ref retains task/channel while the
    # worker borrows their raw bits. The worker ctx itself is shared raw memory.
    withLock osExecAsyncLock:
      osExecAsyncPending.add(pending)
    beginExternalNativeOp()
    try:
      enqueueOsExecAsyncJob(cast[pointer](ctx))
    except CatchableError as e:
      endExternalNativeOp()
      withLock osExecAsyncLock:
        osExecAsyncPending.setLen(osExecAsyncPending.len - 1)
      pending.ctx = nil
      freeOsExecCtx(ctx)
      raiseOsError(name & " could not start a worker thread: " & e.msg, scope)
    task
  else:
    raiseOsError(name & " requires a threaded runtime build", scope)
    NIL

proc biOsExecAsync(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## os/exec contract, but returns a Task settled off-thread: the scheduler
  ## keeps running fibers while the child executes. Await for the result map.
  biOsExecAsyncImpl("os/exec_async", false, false, args, call)

proc biOsExecStreamAsync(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## os/exec_async plus live stdout lines: each complete line (CR stripped) is
  ## sent to ^stdout_chan as it arrives; the channel is closed when the child
  ## exits, then the Task settles with the captured result map.
  biOsExecAsyncImpl("os/exec_stream_async", true, false, args, call)

proc biOsExecStdioAsync(args: openArray[Value],
                        call: ptr NativeCall): Value {.nimcall.} =
  ## Scheduler-friendly terminal handoff. The child inherits this process's
  ## stdin/stdout/stderr while a worker thread waits for it; await the returned
  ## Task for its integer exit status. Cancellation terminates the child.
  biOsExecAsyncImpl("os/exec_stdio_async", false, true, args, call)

# --- net/http_client: native libcurl client ---------------------------------
#
# libcurl owns TLS, certificate verification, redirects, proxies, and HTTP
# framing. The perform call runs on a persistent worker. Its callbacks only
# copy bytes into explicitly shared native buffers; Gene strings/maps/channels
# are created and touched exclusively by pollHttpClientCompletions on the
# scheduler thread.

when defined(macosx):
  const curlLibCandidates = ["libcurl.4.dylib", "/usr/lib/libcurl.4.dylib",
                             "libcurl.dylib"]
elif defined(windows):
  const curlLibCandidates = ["libcurl.dll", "curl.dll"]
else:
  const curlLibCandidates = ["libcurl.so.4", "libcurl.so"]

const
  CurlGlobalDefault = 3.clong
  CurlOk = 0.cint
  CurlWriteError = 23.cint
  CurlOperationTimedOut = 28.cint
  CurlAbortedByCallback = 42.cint
  CurlOptWriteData = 10001.cint
  CurlOptUrl = 10002.cint
  CurlOptWriteFunction = 20011.cint
  CurlOptPostFields = 10015.cint
  CurlOptHttpHeader = 10023.cint
  CurlOptHeaderData = 10029.cint
  CurlOptCustomRequest = 10036.cint
  CurlOptNoProgress = 43.cint
  CurlOptFollowLocation = 52.cint
  CurlOptNoSignal = 99.cint
  CurlOptCaInfo = 10065.cint
  CurlOptAcceptEncoding = 10102.cint
  CurlOptTimeoutMs = 155.cint
  CurlOptHeaderFunction = 20079.cint
  CurlOptXferInfoData = 10057.cint
  CurlOptXferInfoFunction = 20219.cint
  CurlOptPostFieldSizeLarge = 30120.cint
  CurlInfoEffectiveUrl = 0x100001.cint
  CurlInfoResponseCode = 0x200002.cint
  HttpDefaultTimeoutMs = 60_000
  HttpDefaultMaxBytes = 4_000_000
  HttpDefaultPendingBytes = 1_000_000
  HttpHeaderMaxBytes = 256_000
  HttpHardMaxBytes = 64 * 1024 * 1024
  HttpHardPendingBytes = 16 * 1024 * 1024

type
  CurlApi = object
    lib: LibHandle
    globalInit: proc(flags: clong): cint {.cdecl.}
    easyInit: proc(): pointer {.cdecl.}
    easyCleanup: proc(handle: pointer) {.cdecl.}
    easyPerform: proc(handle: pointer): cint {.cdecl.}
    easyStrerror: proc(code: cint): cstring {.cdecl.}
    setoptAddr: pointer
    getinfoAddr: pointer
    slistAppend: proc(list: pointer, value: cstring): pointer {.cdecl.}
    slistFreeAll: proc(list: pointer) {.cdecl.}

var gCurlApi: CurlApi

# AArch64 (notably Apple Silicon) gives variadic arguments a different ABI
# treatment from fixed-signature arguments. Calling curl_easy_setopt/getinfo by
# casting the variadic symbol directly to a fixed Nim proc therefore appears to
# work but passes corrupt values. These tiny C shims make the actual variadic
# call in C while keeping every Nim call site typed by value shape.
{.emit: """
typedef int (*gene_curl_vararg_fn)(void *, int, ...);
static int gene_curl_setopt_str(void *fn, void *h, int o, const char *v) {
  return ((gene_curl_vararg_fn)fn)(h, o, v);
}
static int gene_curl_setopt_long(void *fn, void *h, int o, long v) {
  return ((gene_curl_vararg_fn)fn)(h, o, v);
}
static int gene_curl_setopt_off(void *fn, void *h, int o, long long v) {
  return ((gene_curl_vararg_fn)fn)(h, o, v);
}
static int gene_curl_setopt_ptr(void *fn, void *h, int o, void *v) {
  return ((gene_curl_vararg_fn)fn)(h, o, v);
}
static int gene_curl_getinfo_ptr(void *fn, void *h, int o, void *v) {
  return ((gene_curl_vararg_fn)fn)(h, o, v);
}
""".}

proc cCurlSetoptStr(fn, handle: pointer, option: cint,
                    value: cstring): cint
  {.importc: "gene_curl_setopt_str", nodecl.}
proc cCurlSetoptLong(fn, handle: pointer, option: cint,
                     value: clong): cint
  {.importc: "gene_curl_setopt_long", nodecl.}
proc cCurlSetoptOff(fn, handle: pointer, option: cint,
                    value: int64): cint
  {.importc: "gene_curl_setopt_off", nodecl.}
proc cCurlSetoptPtr(fn, handle: pointer, option: cint,
                    value: pointer): cint
  {.importc: "gene_curl_setopt_ptr", nodecl.}
proc cCurlGetinfoPtr(fn, handle: pointer, option: cint,
                     value: pointer): cint
  {.importc: "gene_curl_getinfo_ptr", nodecl.}

proc raiseHttpClientError(message: string, scope: Scope,
                          kind = "usage") =
  ## `^kind "unavailable"` marks libcurl load/init failures — the only errors
  ## a caller should treat as "fall back to curl(1)". Everything else
  ## (`"usage"`: authority, argument, and option mistakes) must surface so a
  ## typo cannot silently reroute every request to the subprocess transport.
  var props = initPropTable()
  props["message"] = newStr(message)
  props["kind"] = newStr(kind)
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(builtInTypeHead(scope, "HttpClientError"), props = props)
  e.hasErrVal = true
  raise e

proc loadCurlApi(scope: Scope) =
  if gCurlApi.lib != nil:
    return
  when defined(emscripten) or defined(geneWasm):
    raiseHttpClientError("net/http_client is unavailable in WebAssembly; use " &
                         "the host fetch bridge", scope,
                         kind = "unavailable")
  else:
    var lib: LibHandle
    let override = getEnv("GENE_LIBCURL")
    if override.len > 0:
      lib = loadLib(override)
      if lib == nil:
        raiseHttpClientError("could not load GENE_LIBCURL=" & override, scope,
                             kind = "unavailable")
    else:
      for candidate in curlLibCandidates:
        lib = loadLib(candidate)
        if lib != nil:
          break
    if lib == nil:
      raiseHttpClientError("could not load libcurl; set GENE_LIBCURL to its path",
                           scope, kind = "unavailable")
    template sym(name: string): pointer =
      block:
        let address = symAddr(lib, name)
        if address == nil:
          unloadLib(lib)
          raiseHttpClientError("libcurl is missing symbol " & name, scope,
                               kind = "unavailable")
        address
    var api: CurlApi
    api.globalInit = cast[typeof(api.globalInit)](sym"curl_global_init")
    api.easyInit = cast[typeof(api.easyInit)](sym"curl_easy_init")
    api.easyCleanup = cast[typeof(api.easyCleanup)](sym"curl_easy_cleanup")
    api.easyPerform = cast[typeof(api.easyPerform)](sym"curl_easy_perform")
    api.easyStrerror = cast[typeof(api.easyStrerror)](sym"curl_easy_strerror")
    let setoptAddress = sym"curl_easy_setopt"
    api.setoptAddr = setoptAddress
    api.getinfoAddr = sym"curl_easy_getinfo"
    api.slistAppend = cast[typeof(api.slistAppend)](sym"curl_slist_append")
    api.slistFreeAll = cast[typeof(api.slistFreeAll)](sym"curl_slist_free_all")
    if api.globalInit(CurlGlobalDefault) != CurlOk:
      unloadLib(lib)
      raiseHttpClientError("curl_global_init failed", scope,
                           kind = "unavailable")
    api.lib = lib
    gCurlApi = api

when compileOption("threads"):
  type
    SharedHttpBuffer = object
      data: pointer
      len: int
      cap: int
      allocated: int
    HttpClientCtx = object
      httpMethod: SharedExecText
      url: SharedExecText
      body: SharedExecText
      caFile: SharedExecText
      headers: ptr SharedExecArg
      taskBits: uint64
      chunkChanBits: uint64
      schedulerPtr: pointer
      timeoutMs: int
      maxBytes: int
      maxPendingBytes: int
      responseBody: SharedHttpBuffer
      responseHeaders: SharedHttpBuffer
      responseTruncated: bool
      headersTruncated: bool
      responseStatus: int
      effectiveUrl: SharedExecText
      chunkLock: Lock
      chunkHead: ptr SharedExecLine
      chunkTail: ptr SharedExecLine
      queuedBytes: int
      streamGone: bool
      bufferOverflow: bool
      resultFailed: bool
      resultFailure: SharedExecText
      resultCancelled: bool
      resultTimedOut: bool
      cancelRequested: bool
      workerDone: bool
    HttpClientPending {.acyclic.} = ref object
      ctx: ptr HttpClientCtx
      taskOwner: Value
      channelOwner: Value

  const httpClientMaxWorkers = 16
  var httpClientLock: Lock
  var httpClientCond: Cond
  var httpClientQueue: seq[pointer]
  var httpClientThreads: seq[ref Thread[void]]
  var httpClientIdle = 0
  var httpClientStarting = 0
  var httpClientPending: seq[HttpClientPending]
  var httpClientPendingCount = 0
  initLock(httpClientLock)
  initCond(httpClientCond)

  proc freeHttpBuffer(buffer: var SharedHttpBuffer) =
    if buffer.data != nil:
      deallocShared(buffer.data)
    buffer = SharedHttpBuffer()

  proc consumeHttpBuffer(buffer: var SharedHttpBuffer): string =
    if buffer.len > 0:
      result = newString(buffer.len)
      copyMem(addr result[0], buffer.data, buffer.len)
    freeHttpBuffer(buffer)

  proc appendHttpBuffer(buffer: var SharedHttpBuffer, source: pointer,
                        size: int): int {.inline.} =
    if size <= 0 or buffer.len >= buffer.cap:
      return 0
    result = min(size, buffer.cap - buffer.len)
    let needed = buffer.len + result
    if needed > buffer.allocated:
      var nextCapacity = max(16_384, buffer.allocated * 2)
      if nextCapacity < needed:
        nextCapacity = needed
      nextCapacity = min(nextCapacity, buffer.cap)
      buffer.data = reallocShared(buffer.data, nextCapacity)
      buffer.allocated = nextCapacity
    copyMem(cast[pointer](cast[uint](buffer.data) + uint(buffer.len)),
            source, result)
    inc buffer.len, result

  proc httpWriteCallback(data: pointer, size, count: csize_t,
                         userData: pointer): csize_t {.cdecl, gcsafe.} =
    let ctx = cast[ptr HttpClientCtx](userData)
    if size != 0 and count > high(csize_t) div size:
      return 0
    let total = size * count
    if total > csize_t(high(int)):
      return 0
    let copied = appendHttpBuffer(ctx.responseBody, data, int(total))
    if copied < int(total):
      ctx.responseTruncated = true
    if copied > 0 and ctx.chunkChanBits != 0 and
        not atomicLoadN(addr ctx.streamGone, ATOMIC_ACQUIRE):
      let node = cast[ptr SharedExecLine](allocShared0(sizeof(SharedExecLine)))
      node.text.data = allocShared0(copied)
      node.text.len = copied
      copyMem(node.text.data, data, copied)
      withLock ctx.chunkLock:
        if ctx.queuedBytes + copied > ctx.maxPendingBytes:
          if node.text.data != nil:
            deallocShared(node.text.data)
          deallocShared(node)
          ctx.bufferOverflow = true
          return 0
        if ctx.chunkTail == nil:
          ctx.chunkHead = node
          ctx.chunkTail = node
        else:
          ctx.chunkTail.next = node
          ctx.chunkTail = node
        inc ctx.queuedBytes, copied
    total

  proc httpHeaderCallback(data: pointer, size, count: csize_t,
                          userData: pointer): csize_t {.cdecl, gcsafe.} =
    let ctx = cast[ptr HttpClientCtx](userData)
    if size != 0 and count > high(csize_t) div size:
      return 0
    let total = size * count
    if total > csize_t(high(int)):
      return 0
    let copied = appendHttpBuffer(ctx.responseHeaders, data, int(total))
    if copied < int(total):
      ctx.headersTruncated = true
    total

  proc httpProgressCallback(userData: pointer, dlTotal, dlNow, ulTotal,
                            ulNow: int64): cint {.cdecl, gcsafe.} =
    let ctx = cast[ptr HttpClientCtx](userData)
    if atomicLoadN(addr ctx.cancelRequested, ATOMIC_ACQUIRE): 1 else: 0

  proc freeHttpClientCtx(ctx: ptr HttpClientCtx) =
    if ctx == nil:
      return
    discard consumeSharedExecText(ctx.httpMethod)
    discard consumeSharedExecText(ctx.url)
    discard consumeSharedExecText(ctx.body)
    discard consumeSharedExecText(ctx.caFile)
    discard consumeSharedExecText(ctx.effectiveUrl)
    discard consumeSharedExecText(ctx.resultFailure)
    freeHttpBuffer(ctx.responseBody)
    freeHttpBuffer(ctx.responseHeaders)
    freeSharedExecLines(ctx.chunkHead)
    var header = ctx.headers
    while header != nil:
      let next = header.next
      if header.text.data != nil:
        deallocShared(header.text.data)
      deallocShared(header)
      header = next
    deinitLock(ctx.chunkLock)
    deallocShared(ctx)

  proc parseCurlHeaders(raw: string): PropTable =
    result = initPropTable()
    for rawLine in raw.splitLines:
      let line = rawLine.strip(chars = {'\r', ' ', '\t'})
      if line.startsWith("HTTP/"):
        result = initPropTable()
      elif line.len > 0:
        let separator = line.find(':')
        if separator > 0:
          let name = line[0 ..< separator].strip.toLowerAscii
          let value = line[separator + 1 .. ^1].strip
          if result.hasKey(name):
            result[name] = newStr(result[name].strVal & ", " & value)
          else:
            result[name] = newStr(value)

  proc pollHttpClientCompletions() =
    # Every scheduler safepoint reaches this probe through the existing async
    # exec poll. Keep the unused-client path lock-free so ordinary VM workloads
    # do not acquire a new global lock.
    if atomicLoadN(addr httpClientPendingCount, ATOMIC_ACQUIRE) == 0:
      return
    withLock httpClientLock:
      var i = 0
      while i < httpClientPending.len:
        let pending {.cursor.} = httpClientPending[i]
        let ctx = pending.ctx
        var task {.cursor.}: Value
        task.bits = ctx.taskBits
        let cancelled = task.taskCancelled or ctx.resultCancelled
        if task.taskCancelled:
          atomicStoreN(addr ctx.cancelRequested, true, ATOMIC_RELEASE)
        var head, tail: ptr SharedExecLine
        withLock ctx.chunkLock:
          head = ctx.chunkHead
          tail = ctx.chunkTail
          ctx.chunkHead = nil
          ctx.chunkTail = nil
          ctx.queuedBytes = 0
        var channelBlocked = false
        if cancelled:
          freeSharedExecLines(head)
          head = nil
        elif ctx.chunkChanBits != 0:
          var channel {.cursor.}: Value
          channel.bits = ctx.chunkChanBits
          while head != nil:
            let chunk = consumeSharedExecText(head.text)
            let pushed = channel.tryPushChannel(newStr(chunk))
            if pushed.closed:
              atomicStoreN(addr ctx.streamGone, true, ATOMIC_RELEASE)
              freeSharedExecLines(head)
              head = nil
              break
            if not pushed.pushed:
              head.text = sharedExecText(chunk)
              channelBlocked = true
              break
            let consumed = head
            head = head.next
            deallocShared(consumed)
            wakeChannelWaitersIn(cast[SchedulerState](ctx.schedulerPtr), channel,
                                 wakeSenders = false)
        if head != nil:
          var bytes = 0
          var node = head
          while node != nil:
            inc bytes, node.text.len
            node = node.next
          withLock ctx.chunkLock:
            tail.next = ctx.chunkHead
            ctx.chunkHead = head
            if ctx.chunkTail == nil:
              ctx.chunkTail = tail
            inc ctx.queuedBytes, bytes
        let workerDone = atomicLoadN(addr ctx.workerDone, ATOMIC_ACQUIRE)
        if workerDone and not channelBlocked:
          var channel {.cursor.}: Value
          channel.bits = ctx.chunkChanBits
          if ctx.chunkChanBits != 0:
            closeChannel(channel)
            let scheduler = cast[SchedulerState](ctx.schedulerPtr)
            wakeAllChannelWaitersIn(scheduler, channel, wakeSenders = false)
            wakeAllChannelWaitersIn(scheduler, channel, wakeSenders = true)
          if not cancelled and not task.taskCancelled:
            if ctx.resultFailed:
              let failure = consumeSharedExecText(ctx.resultFailure)
              if tryFailTask(task, failure):
                wakeTaskWaitersIn(cast[SchedulerState](ctx.schedulerPtr), task)
            else:
              var response = initPropTable()
              response["status"] = newInt(ctx.responseStatus)
              response["headers"] =
                newMap(parseCurlHeaders(consumeHttpBuffer(ctx.responseHeaders)))
              response["body"] = newStr(consumeHttpBuffer(ctx.responseBody))
              response["effective_url"] =
                newStr(consumeSharedExecText(ctx.effectiveUrl))
              response["truncated"] = newBool(ctx.responseTruncated)
              response["headers_truncated"] = newBool(ctx.headersTruncated)
              if tryCompleteTask(task, newMap(response)):
                wakeTaskWaitersIn(cast[SchedulerState](ctx.schedulerPtr), task)
          endExternalNativeOp()
          pending.ctx = nil
          freeHttpClientCtx(ctx)
          let last = httpClientPending.high
          if i != last:
            httpClientPending[i] = move httpClientPending[last]
          httpClientPending.setLen(last)
          discard atomicFetchSub(addr httpClientPendingCount, 1,
                                 ATOMIC_ACQ_REL)
        else:
          inc i

  proc runHttpClientJob(jobPtr: pointer) {.gcsafe.} =
    {.cast(gcsafe).}:
      let ctx = cast[ptr HttpClientCtx](jobPtr)
      template fail(message: string) =
        ctx.resultFailed = true
        ctx.resultFailure = sharedExecText("net/http_client: " & message)
      if atomicLoadN(addr ctx.cancelRequested, ATOMIC_ACQUIRE):
        ctx.resultCancelled = true
        return
      let httpMethod = readSharedExecText(ctx.httpMethod)
      let url = readSharedExecText(ctx.url)
      let body = readSharedExecText(ctx.body)
      let caFile = readSharedExecText(ctx.caFile)
      let easy = gCurlApi.easyInit()
      if easy == nil:
        fail("curl_easy_init failed")
        return
      var headerList: pointer
      try:
        template setopt(call: untyped, label: string) =
          if call != CurlOk:
            fail("could not set " & label)
            return
        setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptUrl, url.cstring), "URL")
        setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptCustomRequest,
                              httpMethod.cstring),
               "method")
        setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptNoSignal, 1),
               "no-signal")
        setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptFollowLocation, 1),
               "redirects")
        setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptTimeoutMs,
                               ctx.timeoutMs.clong),
               "timeout")
        setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptAcceptEncoding, ""),
               "content decoding")
        if caFile.len > 0:
          setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptCaInfo,
                                caFile.cstring), "CA file")
        setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptWriteFunction,
                              cast[pointer](httpWriteCallback)), "write callback")
        setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptWriteData, ctx),
               "write data")
        setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptHeaderFunction,
                              cast[pointer](httpHeaderCallback)), "header callback")
        setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptHeaderData, ctx),
               "header data")
        setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptNoProgress, 0),
               "progress")
        setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptXferInfoFunction,
                              cast[pointer](httpProgressCallback)),
               "progress callback")
        setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptXferInfoData, ctx),
               "progress data")
        if body.len > 0:
          setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptPostFields,
                                ctx.body.data),
                 "request body")
          setopt(cCurlSetoptOff(gCurlApi.setoptAddr, easy,
                                CurlOptPostFieldSizeLarge, body.len.int64),
                 "request body size")
        var header = ctx.headers
        while header != nil:
          let text = readSharedExecText(header.text)
          let nextList = gCurlApi.slistAppend(headerList, text.cstring)
          if nextList == nil:
            fail("could not allocate request headers")
            return
          headerList = nextList
          header = header.next
        if headerList != nil:
          setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptHttpHeader,
                                headerList),
                 "request headers")
        let code = gCurlApi.easyPerform(easy)
        if code != CurlOk:
          if code == CurlAbortedByCallback and
              atomicLoadN(addr ctx.cancelRequested, ATOMIC_ACQUIRE):
            ctx.resultCancelled = true
          else:
            ctx.resultTimedOut = code == CurlOperationTimedOut
            let detail = if ctx.bufferOverflow:
                "stream buffer exceeded its configured byte cap"
              elif gCurlApi.easyStrerror(code) == nil:
                "libcurl error " & $code
              else:
                $gCurlApi.easyStrerror(code)
            fail(detail)
          return
        var status: clong
        if cCurlGetinfoPtr(gCurlApi.getinfoAddr, easy, CurlInfoResponseCode,
                           addr status) != CurlOk:
          fail("could not read response status")
          return
        ctx.responseStatus = int(status)
        var effective: cstring
        if cCurlGetinfoPtr(gCurlApi.getinfoAddr, easy, CurlInfoEffectiveUrl,
                           addr effective) == CurlOk and
            effective != nil:
          ctx.effectiveUrl = sharedExecText($effective)
        else:
          ctx.effectiveUrl = sharedExecText(url)
      except CatchableError as e:
        fail(e.msg)
      finally:
        if headerList != nil:
          gCurlApi.slistFreeAll(headerList)
        gCurlApi.easyCleanup(easy)

  proc httpClientWorkerMain() {.thread.} =
    {.cast(gcsafe).}:
      while true:
        var jobPtr: pointer
        withLock httpClientLock:
          while httpClientQueue.len == 0:
            inc httpClientIdle
            wait(httpClientCond, httpClientLock)
            dec httpClientIdle
          jobPtr = httpClientQueue[0]
          httpClientQueue.delete(0)
        runHttpClientJob(jobPtr)
        let ctx = cast[ptr HttpClientCtx](jobPtr)
        atomicStoreN(addr ctx.workerDone, true, ATOMIC_RELEASE)

  proc enqueueHttpClientJob(jobPtr: pointer) =
    var needThread = false
    withLock httpClientLock:
      httpClientQueue.add(jobPtr)
      if httpClientIdle == 0 and
          httpClientThreads.len + httpClientStarting < httpClientMaxWorkers:
        needThread = true
        inc httpClientStarting
      else:
        signal(httpClientCond)
    if needThread:
      var thread: ref Thread[void]
      new(thread)
      try:
        createThread(thread[], httpClientWorkerMain)
        withLock httpClientLock:
          dec httpClientStarting
          httpClientThreads.add thread
      except:
        var removed = false
        withLock httpClientLock:
          dec httpClientStarting
          for i in 0 ..< httpClientQueue.len:
            if httpClientQueue[i] == jobPtr:
              httpClientQueue.delete(i)
              removed = true
              break
        if removed:
          raise

else:
  proc pollHttpClientCompletions() =
    discard

proc validHttpMethod(httpMethod: string): bool =
  if httpMethod.len == 0:
    return false
  for ch in httpMethod:
    if not (ch in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}):
      return false
  true

proc biHttpClientStart(name: string, streaming: bool,
                       args: openArray[Value], call: ptr NativeCall): Value =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1 or args[0].kind != vkCapability or
      args[0].capabilityName != "Net/Http":
    raiseHttpClientError(name & " expects Http authority", scope)
  var httpMethod = "GET"
  var url = ""
  var headers: seq[string]
  var body = ""
  var caFile = ""
  var timeoutMs = HttpDefaultTimeoutMs
  var maxBytes = HttpDefaultMaxBytes
  var pendingBytes = HttpDefaultPendingBytes
  var channelCapacity = 256
  if call != nil:
    for i, argName in call[].namedNames:
      let value = call[].namedValues[i]
      case argName
      of "method":
        requireStr(name & " ^method", value)
        httpMethod = value.strVal
      of "url":
        requireStr(name & " ^url", value)
        url = value.strVal
      of "headers":
        case value.kind
        of vkMap:
          for headerName, headerValue in value.mapEntries:
            requireStr(name & " ^headers value", headerValue)
            headers.add headerName & ": " & headerValue.strVal
        of vkList:
          for item in value.listItems:
            requireStr(name & " ^headers item", item)
            headers.add item.strVal
        else:
          raiseHttpClientError(name & " ^headers must be a Map or List of Str",
                               scope)
      of "body":
        requireStr(name & " ^body", value)
        body = value.strVal
      of "ca_file":
        requireStr(name & " ^ca_file", value)
        caFile = value.strVal
      of "timeout_ms":
        timeoutMs = int(requireInt64(name & " ^timeout_ms", value))
      of "max_bytes":
        maxBytes = int(requireInt64(name & " ^max_bytes", value))
      of "max_pending_bytes":
        if not streaming:
          raiseHttpClientError(name & " got unexpected named argument: " & argName,
                               scope)
        pendingBytes = int(requireInt64(name & " ^max_pending_bytes", value))
      of "channel_capacity":
        if not streaming:
          raiseHttpClientError(name & " got unexpected named argument: " & argName,
                               scope)
        channelCapacity = int(requireInt64(name & " ^channel_capacity", value))
      else:
        raiseHttpClientError(name & " got unexpected named argument: " & argName,
                             scope)
  if not validHttpMethod(httpMethod):
    raiseHttpClientError(name & " ^method contains invalid characters", scope)
  if not (url.startsWith("http://") or url.startsWith("https://")):
    raiseHttpClientError(name & " ^url must use http:// or https://", scope)
  if timeoutMs <= 0 or maxBytes <= 0 or pendingBytes <= 0 or channelCapacity <= 0:
    raiseHttpClientError(name & " limits must be positive", scope)
  if timeoutMs > 86_400_000 or maxBytes > HttpHardMaxBytes or
      pendingBytes > HttpHardPendingBytes or channelCapacity > 65_536:
    raiseHttpClientError(name & " limits exceed the native client safety cap",
                         scope)
  if url.len > 16_384 or body.len > HttpHardMaxBytes or caFile.len > 4096:
    raiseHttpClientError(name & " request data exceeds the native client safety cap",
                         scope)
  if headers.len > 256:
    raiseHttpClientError(name & " accepts at most 256 headers", scope)
  for header in headers:
    if header.len > 65_536:
      raiseHttpClientError(name & " header exceeds 65536 bytes", scope)
    if '\r' in header or '\n' in header:
      raiseHttpClientError(name & " rejects newline characters in headers", scope)
  loadCurlApi(scope)
  when compileOption("threads"):
    if scope == nil or scope.application == nil:
      raiseHttpClientError(name & " requires a scheduler scope", scope)
    pollHttpClientCompletions()
    let task = newExternalTask()
    let channel = if streaming: newChannel(channelCapacity) else: NIL
    markSharedValue(task)
    if streaming:
      markSharedValue(channel)
    let ctx = cast[ptr HttpClientCtx](allocShared0(sizeof(HttpClientCtx)))
    ctx.httpMethod = sharedExecText(httpMethod)
    ctx.url = sharedExecText(url)
    ctx.body = sharedExecText(body)
    ctx.caFile = sharedExecText(caFile)
    ctx.taskBits = task.bits
    ctx.chunkChanBits = if streaming: channel.bits else: 0'u64
    ctx.schedulerPtr = cast[pointer](schedulerForScope(scope))
    ctx.timeoutMs = timeoutMs
    ctx.maxBytes = maxBytes
    ctx.maxPendingBytes = pendingBytes
    ctx.responseBody.cap = maxBytes
    ctx.responseHeaders.cap = HttpHeaderMaxBytes
    initLock(ctx.chunkLock)
    var headerTail: ptr SharedExecArg
    for header in headers:
      let node = cast[ptr SharedExecArg](allocShared0(sizeof(SharedExecArg)))
      node.text = sharedExecText(header)
      if headerTail == nil:
        ctx.headers = node
      else:
        headerTail.next = node
      headerTail = node
    let pending = HttpClientPending(ctx: ctx)
    pending.taskOwner = retainedCopy(task)
    pending.channelOwner = retainedCopy(channel)
    withLock httpClientLock:
      httpClientPending.add pending
      discard atomicFetchAdd(addr httpClientPendingCount, 1, ATOMIC_RELEASE)
    beginExternalNativeOp()
    try:
      enqueueHttpClientJob(ctx)
    except CatchableError as e:
      endExternalNativeOp()
      withLock httpClientLock:
        httpClientPending.setLen(httpClientPending.len - 1)
        discard atomicFetchSub(addr httpClientPendingCount, 1,
                               ATOMIC_ACQ_REL)
      pending.ctx = nil
      freeHttpClientCtx(ctx)
      raiseHttpClientError(name & " could not start worker: " & e.msg, scope)
    if streaming:
      var streamResult = initPropTable()
      streamResult["task"] = task
      streamResult["channel"] = channel
      newMap(streamResult)
    else:
      task
  else:
    raiseHttpClientError(name & " requires a threaded runtime build", scope)
    NIL

proc biHttpClientRequest(args: openArray[Value],
                         call: ptr NativeCall): Value {.nimcall.} =
  biHttpClientStart("net/http_client/request", false, args, call)

proc biHttpClientStream(args: openArray[Value],
                        call: ptr NativeCall): Value {.nimcall.} =
  biHttpClientStart("net/http_client/stream", true, args, call)

proc biOsBeginInterrupt(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/begin_interrupt takes no arguments")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if cTurnInterruptBegin() == 0: TRUE else: FALSE
  else:
    FALSE

proc biOsTakeInterrupt(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/take_interrupt takes no arguments")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if cTurnInterruptTake() != 0: TRUE else: FALSE
  else:
    FALSE

proc biOsEndInterrupt(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/end_interrupt takes no arguments")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    cTurnInterruptEnd()
  NIL

proc biOsMonotonicMs(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/monotonic_ms takes no arguments")
  newInt(getMonoTime().ticks div 1_000_000)

proc biOsProcessId(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/process_id takes no arguments")
  newInt(getCurrentProcessId())

proc biOsStdinTty(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "os/stdin_tty? takes no arguments")
  when defined(posix):
    if isatty(STDIN_FILENO) != 0: TRUE else: FALSE
  else:
    FALSE

proc cClearErr(f: File) {.importc: "clearerr", header: "<stdio.h>".}

proc biOsReadLine(args: openArray[Value]): Value {.nimcall.} =
  ## Read one line from stdin; returns nil at EOF. No capability: reading the
  ## program's own stdin is not host authority the way env/exec/files are.
  if args.len != 0:
    raise newException(GeneError, "os/read_line takes no arguments")
  try:
    newStr(stdin.readLine())
  except EOFError:
    when defined(posix):
      if isatty(STDIN_FILENO) != 0:
        cClearErr(stdin)
    NIL

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
    if value.kind != vkNode or value.head.kind != vkType or
        value.head.typeName != "TerminalSession":
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
      var props = initPropTable()
      props["id"] = newInt(id)
      props["closed"] = newCell(FALSE)
      newNode(builtInTypeHead(scope, "TerminalSession"), props = props)
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
  if screen.kind != vkNode or screen.head.kind != vkType or
      screen.head.typeName != "CursesScreen":
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
    var props = initPropTable()
    props["id"] = newInt(id)
    props["closed"] = newCell(FALSE)
    newNode(builtInTypeHead(scope, "CursesScreen"), props = props)
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

# --- repl: reusable interactive evaluator ---

type IncrementalReplSession = ref object
  scope: Scope
  pendingSource: string
  pendingError: string
  closed: bool

var incrementalReplSessions: seq[IncrementalReplSession]

proc incrementalReplId(name: string, value: Value, scope: Scope,
                       requireOpen = true): int =
  if value.kind != vkNode or value.head.kind != vkType or
      value.head.typeName != "ReplSession":
    raise newException(GeneError, name & " expects a repl/Session")
  let id = value.props.getOrDefault("id", VOID)
  let closed = value.props.getOrDefault("closed", VOID)
  if id.kind != vkInt or closed.kind != vkCell or id.intVal <= 0 or
      id.intVal > incrementalReplSessions.len:
    raise newException(GeneError, name & " received an invalid repl/Session")
  result = int(id.intVal) - 1
  let session = incrementalReplSessions[result]
  if session == nil or (requireOpen and
      (session.closed or closed.cellValue.isTruthy)):
    raise newException(GeneError, name & ": Session is closed")

proc replEvalResult(status, text: string): Value =
  var props = initPropTable()
  props["status"] = newStr(status)
  props["text"] = newStr(text)
  newMap(props)

proc biReplOpen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("repl/open", args)
  if args[0].kind != vkEnv:
    raise newException(GeneError, "repl/open expects an Env")
  let dispatchScope = if call == nil: nil else: call[].dispatchScope
  let evalScope = incrementalReplScopeForEnv(args[0])
  let session = IncrementalReplSession(scope: evalScope)
  incrementalReplSessions.add session
  var props = initPropTable()
  props["id"] = newInt(incrementalReplSessions.len)
  props["closed"] = newCell(FALSE)
  newNode(builtInTypeHead(dispatchScope, "ReplSession"), props = props)

proc biReplEval(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "repl/eval_source expects (repl/Session, Str)")
  let dispatchScope = if call == nil: nil else: call[].dispatchScope
  let id = incrementalReplId("repl/eval_source", args[0], dispatchScope)
  requireStr("repl/eval_source source", args[1])
  let session = incrementalReplSessions[id]
  let source =
    if session.pendingSource.len == 0: args[1].strVal
    else: session.pendingSource & "\n" & args[1].strVal
  if source.strip().len == 0:
    return replEvalResult("ok", "")
  try:
    let value = run(compileEvalSource(source, useLocalSlots = false,
                                      sourceName = "<repl-pane>"),
                    session.scope)
    session.pendingSource.setLen(0)
    session.pendingError.setLen(0)
    replEvalResult("ok", value.print())
  except ReadIncompleteError as error:
    session.pendingSource = source
    session.pendingError = error.msg
    replEvalResult("incomplete", error.msg)
  except ReadError as error:
    session.pendingSource.setLen(0)
    session.pendingError.setLen(0)
    replEvalResult("error", formatDiagnostic("Read error", error.msg,
      SourceLoc(sourceName: error.sourceName, line: error.line,
                col: error.col)))
  except GenePanic as error:
    session.pendingSource.setLen(0)
    session.pendingError.setLen(0)
    replEvalResult("panic", "Panic: " & error.msg)
  except GeneError as error:
    session.pendingSource.setLen(0)
    session.pendingError.setLen(0)
    if error.msg == "interrupted":
      replEvalResult("cancelled", "[cancelled]")
    else:
      replEvalResult("error", formatDiagnostic("Error", error.msg, error.loc))

proc biReplClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("repl/close", args)
  let dispatchScope = if call == nil: nil else: call[].dispatchScope
  let id = incrementalReplId("repl/close", args[0], dispatchScope,
                             requireOpen = false)
  let closed = args[0].props["closed"]
  if not closed.cellValue.isTruthy:
    let session = incrementalReplSessions[id]
    if session != nil:
      session.closed = true
      session.scope = nil
      session.pendingSource.setLen(0)
      session.pendingError.setLen(0)
    closed.setCellValue(TRUE)
  NIL

proc biReplDiscardPending(args: openArray[Value],
                          call: ptr NativeCall): Value {.nimcall.} =
  ## Drop a session's buffered incomplete-form source (§C7 Escape rung).
  ## Returns true when pending source existed.
  requireOne("repl/discard_pending", args)
  let dispatchScope = if call == nil: nil else: call[].dispatchScope
  let id = incrementalReplId("repl/discard_pending", args[0], dispatchScope)
  let session = incrementalReplSessions[id]
  result = if session.pendingSource.len > 0: TRUE else: FALSE
  session.pendingSource.setLen(0)
  session.pendingError.setLen(0)

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  # §C7 in-VM cancellation: while a pane REPL eval is in flight the TUI runs
  # in a no-ISIG terminal mode, so Ctrl-C arrives as a dead keystroke once the
  # cooperative scheduler is starved by a non-yielding eval. The guard enables
  # ISIG and routes SIGINT to the VM interrupt flag, which consumeEvalStep
  # polls on the budgeted-dispatch path; eval_guard_end restores both.
  import std/termios as pane_termios
  var paneEvalOldSigint: Sigaction
  var paneEvalOldTermios: pane_termios.Termios
  var paneEvalGuardActive = false
  var paneEvalTermiosChanged = false

  proc paneEvalSigintHandler(sig: cint) {.noconv.} =
    volatileStore(addr gVmInterrupt, true)

  proc biReplEvalGuardBegin(args: openArray[Value],
                            call: ptr NativeCall): Value {.nimcall.} =
    if paneEvalGuardActive:
      return FALSE
    var act: Sigaction
    act.sa_handler = paneEvalSigintHandler
    discard sigemptyset(act.sa_mask)
    act.sa_flags = SA_RESTART
    if sigaction(SIGINT, act, paneEvalOldSigint) != 0:
      return FALSE
    paneEvalGuardActive = true
    volatileStore(addr gVmInterrupt, false)
    paneEvalTermiosChanged = false
    if isatty(STDIN_FILENO) != 0:
      var attrs: pane_termios.Termios
      if pane_termios.tcGetAttr(STDIN_FILENO, addr attrs) == 0:
        paneEvalOldTermios = attrs
        if (attrs.c_lflag.uint64 and pane_termios.ISIG.uint64) == 0'u64:
          attrs.c_lflag = pane_termios.Cflag(
            attrs.c_lflag.uint64 or pane_termios.ISIG.uint64)
          if pane_termios.tcSetAttr(STDIN_FILENO, pane_termios.TCSANOW,
                                    addr attrs) == 0:
            paneEvalTermiosChanged = true
    TRUE

  proc biReplEvalGuardEnd(args: openArray[Value],
                          call: ptr NativeCall): Value {.nimcall.} =
    if not paneEvalGuardActive:
      return FALSE
    if paneEvalTermiosChanged:
      discard pane_termios.tcSetAttr(STDIN_FILENO, pane_termios.TCSANOW,
                                     addr paneEvalOldTermios)
      paneEvalTermiosChanged = false
    discard sigaction(SIGINT, paneEvalOldSigint, nil)
    paneEvalGuardActive = false
    volatileStore(addr gVmInterrupt, false)
    TRUE
else:
  proc biReplEvalGuardBegin(args: openArray[Value],
                            call: ptr NativeCall): Value {.nimcall.} = FALSE
  proc biReplEvalGuardEnd(args: openArray[Value],
                          call: ptr NativeCall): Value {.nimcall.} = FALSE

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
    raise newException(GeneError, "Fs/read_text expects (Fs/ReadDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsReadDir("Fs/read_text", args[0])
  requireStr("Fs/read_text path", args[1])
  try:
    newStr(readFile(args[1].strVal))
  except IOError as e:
    raiseOsError("Fs/read_text: " & e.msg, scope)
    NIL

proc biFsWriteTextSync(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError, "Fs/write_text expects (Fs/WriteDir, path, text)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsWriteDir("Fs/write_text", args[0])
  requireStr("Fs/write_text path", args[1])
  requireStr("Fs/write_text text", args[2])
  try:
    writeFile(args[1].strVal, args[2].strVal)
  except IOError as e:
    raiseOsError("Fs/write_text: " & e.msg, scope)
  NIL

proc biFsExists(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Fs/exists? expects (Fs/ReadDir, path)")
  requireFsReadDir("Fs/exists?", args[0])
  requireStr("Fs/exists? path", args[1])
  let path = args[1].strVal
  newBool(fileExists(path) or dirExists(path) or symlinkExists(path))

proc biFsListDir(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Fs/list_dir expects (Fs/ReadDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsReadDir("Fs/list_dir", args[0])
  requireStr("Fs/list_dir path", args[1])
  if not dirExists(args[1].strVal):
    raiseOsError("Fs/list_dir: not a directory: " & args[1].strVal, scope)
  var names: seq[Value]
  try:
    for kind, path in walkDir(args[1].strVal, relative = true):
      names.add newStr(path)
  except OSError as e:
    raiseOsError("Fs/list_dir: " & e.msg, scope)
  newList(names)

proc biFsMakeDir(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Fs/make_dir expects (Fs/WriteDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsWriteDir("Fs/make_dir", args[0])
  requireStr("Fs/make_dir path", args[1])
  try:
    createDir(args[1].strVal)
  except OSError as e:
    raiseOsError("Fs/make_dir: " & e.msg, scope)
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
    raise newException(GeneError, "Fs/real_path expects (Fs/ReadDir, path)")
  let scope = if call == nil: nil else: call[].dispatchScope
  requireFsReadDir("Fs/real_path", args[0])
  requireStr("Fs/real_path path", args[1])
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
    raiseOsError("Fs/real_path: " & e.msg, scope)
    NIL

# --- json: parse and stringify over Gene value kinds (examples/ai_agent/design.md §5) ---

const jsonMaxDepth = 200

type JsonParser = object
  input: string
  pos: int
  scope: Scope

proc raiseJsonError(p: var JsonParser, message: string) =
  var props = initPropTable()
  props["message"] = newStr("json/parse: " & message & " at offset " & $p.pos)
  var e: ref GeneError
  new(e)
  e.msg = "json/parse: " & message
  e.errVal = newNode(builtInTypeHead(p.scope, "JsonError"), props = props)
  e.hasErrVal = true
  raise e

proc raiseJsonValueError(scope: Scope, message: string) =
  var props = initPropTable()
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
    var entries = initPropTable()
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


# --- log: structured application/runtime diagnostics ------------------------

const LogReservedPayloadKeys = [
  "schema", "time", "level", "logger", "message", "payload", "seq",
  "pid", "thread", "task", "actor", "source"]

proc requireLogger(name: string, value: Value) =
  if value.kind != vkLogger:
    raise newException(GeneError, name & " expects a Logger")

proc requireLogNamed(name: string, call: ptr NativeCall,
                     allowed: openArray[string]) =
  if call == nil: return
  for actual in call[].namedNames:
    if actual notin allowed:
      raise newException(GeneError,
        name & " got unexpected named argument: " & actual)

proc namedLogPayload(call: ptr NativeCall): Value =
  if call == nil: return newMap(immutable = true)
  for i, name in call[].namedNames:
    if name == "payload":
      # NativeCall owns namedValues. Force a retained copy: under ORC, returning
      # an indexed value can otherwise be sink-optimized as though this helper
      # owned the sequence element, leaving the call frame with a dangling box.
      return retainedCopy(call[].namedValues[i])
  newMap(immutable = true)

proc namedLogValue(call: ptr NativeCall, key: string,
                   fallback: Value): Value =
  if call != nil:
    for i, name in call[].namedNames:
      if name == key: return retainedCopy(call[].namedValues[i])
  fallback

proc logLevelFromValue(name: string, value: Value,
                       allowOff = false): LogLevel =
  if value.kind != vkEnumVariant or
      value.enumVariantEnum.typeName != "LogLevel":
    raise newException(GeneError, name & " expects a LogLevel")
  case value.enumVariantName
  of "error": llError
  of "warn": llWarn
  of "info": llInfo
  of "debug": llDebug
  of "trace": llTrace
  of "off":
    if allowOff: llOff
    else: raise newException(GeneError, name & " cannot emit LogLevel/off")
  else:
    raise newException(GeneError, name & " got an unknown LogLevel")

proc normalizeLogValue(value: Value, depth: int, items: var int,
                       active: var HashSet[uint64], maxDepth, maxItems,
                       maxStringBytes: int): tuple[value: Value,
                                                   json: JsonNode]

proc enterLogContainer(value: Value, active: var HashSet[uint64]) =
  if active.contains(value.bits):
    raise newException(GeneError, "log payload contains a cycle")
  active.incl value.bits

proc normalizeLogMap(value: Value, depth: int, items: var int,
                     active: var HashSet[uint64], maxDepth, maxItems,
                     maxStringBytes: int): tuple[value: Value,
                                                 json: JsonNode] =
  if value.kind notin {vkMap, vkHashMap}:
    raise newException(GeneError, "log payload must be a PropMap or HashMap")
  enterLogContainer(value, active)
  defer: active.excl value.bits
  var entries = initPropTable()
  result.json = newJObject()
  template addEntry(key: string, item: Value) =
    if entries.hasKey(key):
      raise newException(GeneError, "duplicate log payload key: " & key)
    if key.toLowerAscii() in LogReservedPayloadKeys:
      raise newException(GeneError, "reserved log payload key: " & key)
    if loggingRedactsKey(key):
      entries[key] = newStr("[redacted]")
      result.json[key] = newJString("[redacted]")
    else:
      let normalized = normalizeLogValue(item, depth + 1, items, active,
        maxDepth, maxItems, maxStringBytes)
      entries[key] = normalized.value
      result.json[key] = normalized.json
  if value.kind == vkMap:
    for key in value.mapEntries.keys:
      addEntry(key, value.mapEntries[key])
  else:
    for entry in value.hashMapEntries:
      let key =
        case entry.key.kind
        of vkString: entry.key.strVal
        of vkSymbol: entry.key.symVal
        else:
          raise newException(GeneError,
            "log payload keys must be strings or symbols")
      addEntry(key, entry.val)
  result.value = newMap(entries, immutable = true)

proc normalizeLogValue(value: Value, depth: int, items: var int,
                       active: var HashSet[uint64], maxDepth, maxItems,
                       maxStringBytes: int): tuple[value: Value,
                                                   json: JsonNode] =
  if depth > maxDepth:
    raise newException(GeneError, "log payload nesting exceeds limit")
  inc items
  if items > maxItems:
    raise newException(GeneError, "log payload item count exceeds limit")
  case value.kind
  of vkNil, vkVoid:
    result = (NIL, newJNull())
  of vkBool:
    result = (value, newJBool(value.boolVal))
  of vkInt:
    result = (value, newJInt(value.intVal))
  of vkFloat:
    let number = value.floatVal
    if number.classify in {fcNan, fcInf, fcNegInf}:
      result = (value, newJString(value.print()))
    else:
      result = (value, newJFloat(number))
  of vkString:
    if value.strVal.len > maxStringBytes:
      raise newException(GeneError, "log payload string exceeds limit")
    result = (value, newJString(value.strVal))
  of vkSymbol:
    if value.symVal.len > maxStringBytes:
      raise newException(GeneError, "log payload symbol exceeds limit")
    result = (value, newJString(value.symVal))
  of vkChar:
    result = (value, newJString($value.charVal))
  of vkBytes, vkRegex, vkRange, vkDate, vkTime, vkDateTime, vkTimezone,
     vkDuration:
    result = (value, newJString(value.print()))
  of vkList:
    enterLogContainer(value, active)
    defer: active.excl value.bits
    var values: seq[Value]
    let json = newJArray()
    for item in value.listItems:
      let normalized = normalizeLogValue(item, depth + 1, items, active,
        maxDepth, maxItems, maxStringBytes)
      values.add normalized.value
      json.add normalized.json
    result = (newList(values, immutable = true), json)
  of vkMap, vkHashMap:
    result = normalizeLogMap(value, depth, items, active,
      maxDepth, maxItems, maxStringBytes)
  of vkSet:
    enterLogContainer(value, active)
    defer: active.excl value.bits
    var values: seq[Value]
    let json = newJArray()
    for item in value.setItems:
      let normalized = normalizeLogValue(item, depth + 1, items, active,
        maxDepth, maxItems, maxStringBytes)
      values.add normalized.value
      json.add normalized.json
    result = (newSet(values), json)
  of vkNode:
    enterLogContainer(value, active)
    defer: active.excl value.bits
    let normalizedHead = normalizeLogValue(value.head, depth + 1, items,
      active, maxDepth, maxItems, maxStringBytes)
    let normalizedProps = normalizeLogMap(newMap(value.props), depth + 1,
      items, active, maxDepth, maxItems, maxStringBytes)
    let normalizedMeta = normalizeLogMap(newMap(value.meta), depth + 1,
      items, active, maxDepth, maxItems, maxStringBytes)
    var body: seq[Value]
    for item in value.body:
      body.add normalizeLogValue(item, depth + 1, items, active,
        maxDepth, maxItems, maxStringBytes).value
    let frozen = newNode(normalizedHead.value,
      props = normalizedProps.value.mapEntries,
      body = body,
      meta = normalizedMeta.value.mapEntries,
      immutable = true)
    result = (frozen, newJString(frozen.print()))
  else:
    raise newException(GeneError,
      "log payload cannot contain " & $value.kind)

proc normalizeLogPayload(value: Value): tuple[value: Value, json: JsonNode] =
  var items = 0
  var active = initHashSet[uint64]()
  var maxDepth, maxItems, maxStringBytes: int
  loggingLimitValues(maxDepth, maxItems, maxStringBytes)
  normalizeLogMap(value, 0, items, active,
    maxDepth, maxItems, maxStringBytes)

proc mergeLogPayload(base, event: Value): Value =
  var entries = initPropTable()
  if base.kind == vkMap:
    for key, value in base.mapEntries: entries[key] = value
  if event.kind == vkMap:
    for key, value in event.mapEntries: entries[key] = value
  newMap(entries, immutable = true)

proc logSource(call: ptr NativeCall): LogSource =
  if call == nil or not call[].loc.hasSourceLoc:
    return LogSource()
  LogSource(module: call[].loc.sourceName, line: call[].loc.line,
            column: call[].loc.col)

proc emitLogger(name: string, logger: Value, level: LogLevel, message: Value,
                payload: Value, call: ptr NativeCall): Value =
  requireLogger(name, logger)
  requireStr(name & " message", message)
  let eventPayload = normalizeLogPayload(payload).value
  let merged = normalizeLogPayload(
    mergeLogPayload(logger.loggerPayload, eventPayload))
  emitLog(logger.loggerRouteId, logger.loggerName, level, message.strVal,
          merged.json, logSource(call))
  NIL

proc biLogNewLogger(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("log/new_logger", args)
  requireLogNamed("log/new_logger", call, ["payload"])
  requireStr("log/new_logger name", args[0])
  let name = args[0].strVal
  if name != "app" and not name.startsWith("app/"):
    raise newException(GeneError,
      "log/new_logger names must be in the app/* namespace")
  if not validLoggerName(name):
    raise newException(GeneError, "log/new_logger invalid name: " & name)
  let normalizedPayload = normalizeLogPayload(namedLogPayload(call))
  let routeId = resolveRouteId(name)
  newLogger(name, routeId, normalizedPayload.value)

proc biLogNewFileLogger(args: openArray[Value],
                        call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "log/new_file_logger expects (Fs/WriteDir, name, path)")
  requireLogNamed("log/new_file_logger", call,
                  ["payload", "format", "flush", "level"])
  requireFsWriteDir("log/new_file_logger", args[0])
  requireStr("log/new_file_logger name", args[1])
  requireStr("log/new_file_logger path", args[2])
  let name = args[1].strVal
  if name != "app" and not name.startsWith("app/"):
    raise newException(GeneError,
      "log/new_file_logger names must be in the app/* namespace")
  if not validLoggerName(name):
    raise newException(GeneError, "log/new_file_logger invalid name: " & name)
  let formatValue = namedLogValue(call, "format", newStr("gene"))
  requireStr("log/new_file_logger ^format", formatValue)
  var format: LogFormat
  if not parseLogFormat(formatValue.strVal, format):
    raise newException(GeneError,
      "log/new_file_logger ^format must be gene, text, json, or jsonl")
  let flushValue = namedLogValue(call, "flush", newStr("error"))
  requireStr("log/new_file_logger ^flush", flushValue)
  var flush: LogFlush
  if not parseLogFlush(flushValue.strVal, flush):
    raise newException(GeneError,
      "log/new_file_logger ^flush must be always, error, or close")
  let levelValue = namedLogValue(call, "level", NIL)
  let level =
    if levelValue.kind == vkNil: llTrace
    else: logLevelFromValue("log/new_file_logger ^level", levelValue,
                            allowOff = true)
  let payload = normalizeLogPayload(namedLogPayload(call)).value
  when defined(geneWasm) or defined(emscripten):
    raise newException(GeneError,
      "log/new_file_logger is unavailable in wasm")
  else:
    try:
      let sink = newFileLogSink("direct:" & name, args[2].strVal,
                                format, flush)
      newLogger(name, newDirectLogRoute(sink, level), payload)
    except CatchableError as e:
      raise newException(GeneError, "log/new_file_logger: " & e.msg)

proc biLoggerChild(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Logger/child expects (Logger, name)")
  requireLogNamed("Logger/child", call, ["payload"])
  requireLogger("Logger/child", args[0])
  requireStr("Logger/child name", args[1])
  let name = args[0].loggerName & "/" & args[1].strVal
  if not validLoggerName(name):
    raise newException(GeneError, "Logger/child invalid name: " & name)
  let payload = normalizeLogPayload(namedLogPayload(call)).value
  newLogger(name, resolveRouteId(name),
    mergeLogPayload(args[0].loggerPayload, payload))

proc biLoggerWith(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Logger/with expects (Logger, payload)")
  requireLogNamed("Logger/with", call, [])
  requireLogger("Logger/with", args[0])
  let payload = normalizeLogPayload(args[1]).value
  newLogger(args[0].loggerName, args[0].loggerRouteId,
    mergeLogPayload(args[0].loggerPayload, payload))

proc biLoggerEnabled(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "Logger/enabled? expects (Logger, LogLevel)")
  requireLogNamed("Logger/enabled?", call, [])
  requireLogger("Logger/enabled?", args[0])
  let level = logLevelFromValue("Logger/enabled?", args[1], allowOff = true)
  newBool(level != llOff and loggerEnabled(args[0].loggerRouteId, level))

proc biLoggerEmit(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "Logger/emit expects (Logger, LogLevel, message)")
  requireLogNamed("Logger/emit", call, ["payload"])
  emitLogger("Logger/emit", args[0], logLevelFromValue("Logger/emit", args[1]),
             args[2], namedLogPayload(call), call)

template defineLoggerLevelProc(procName: untyped, publicName: string,
                               logLevel: LogLevel) =
  proc procName(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 2:
      raise newException(GeneError, publicName & " expects (Logger, message)")
    requireLogNamed(publicName, call, ["payload"])
    emitLogger(publicName, args[0], logLevel, args[1], namedLogPayload(call), call)

defineLoggerLevelProc(biLoggerError, "Logger/error", llError)
defineLoggerLevelProc(biLoggerWarn, "Logger/warn", llWarn)
defineLoggerLevelProc(biLoggerInfo, "Logger/info", llInfo)
defineLoggerLevelProc(biLoggerDebug, "Logger/debug", llDebug)
defineLoggerLevelProc(biLoggerTrace, "Logger/trace", llTrace)


# --- serde: Gene-text serialization, data core -------------------------------
#
# Stage 1 of docs/proposals/serialization.md: write_data / read_data / data?
# over the data bucket, riding the canonical printer/reader. Serialized text is
# a (serde_v1 <payload>) envelope of ordinary Gene source. Control tags are
# underscore-named plain symbols (serde_v1, serde_float, serde_sym, serde_map,
# serde_set, serde_range, serde_timezone, serde_duration, serde_data_node):
# slash tokens read back as (path ...) nodes, so slash-headed tags would not
# survive a print/read cycle. The design doc's serde/* names refer to these.
#
# Round-trip guarantee: (= v (read_data (write_data v))) under structural
# equality for every data-bucket value. Everything that would falsify it is
# either escaped (reserved heads, non-rereadable symbols and map keys, float
# specials) or rejected (cells and other identity/process-bound values).

const serdeReservedPrefix = "serde_"
const serdeDefaultMaxBytes = 10_485_760
const serdeDefaultMaxNodes = 100_000
const serdeDefaultMaxDepth = 1_000
const serdeDefaultMaxSymbols = 10_000

type SerdePolicyLimits = object
  maxBytes: int
  maxNodes: int
  maxDepth: int
  maxSymbols: int
  allowRestore: bool   # serde_hooked serde_restore runs user code; off by default

type SerdeWriter = object
  sb: string
  scope: Scope
  app: Application                  # nil unless allowRefs (origin resolution)
  allowRefs: bool                   # serde/write emits refs; write_data errors
  path: seq[string]
  onPath: HashSet[uint64]           # container identities on the current path
  symCache: Table[string, bool]     # symbol text -> re-reads verbatim
  keyCache: Table[string, bool]     # prop key -> usable as ^key literal

type SerdeReader = object
  scope: Scope
  app: Application                  # nil unless resolveRefs
  resolveRefs: bool                 # serde/read resolves refs; read_data errors
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
  var props = initPropTable()
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
  ## single-entry map. Otherwise the whole container uses the serde_map escape.
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
  scope.materializeMirroredVars()
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
  ## (serde_map <immutable> [k1 v1 k2 v2 ...]) — keys as strings.
  w.sb.add "(serde_map "
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
      w.sb.add "(serde_float \"nan\")"
    elif f == Inf:
      w.sb.add "(serde_float \"+inf\")"
    elif f == NegInf:
      w.sb.add "(serde_float \"-inf\")"
    elif f == 0.0 and 1.0 / f == NegInf:
      w.sb.add "(serde_float \"-0.0\")"
    else:
      w.sb.add print(v)
  of vkSymbol:
    if serdeSymbolRereads(w, v.symVal):
      w.sb.add v.symVal
    else:
      w.sb.add "(serde_sym "
      serdeEmitStrLit(w, v.symVal)
      w.sb.add ')'
  of vkTimezone:
    w.sb.add "(serde_timezone "
    w.sb.add (if v.timezoneHasOffset: "true " else: "false ")
    w.sb.add $v.timezoneOffsetMinutes & " "
    serdeEmitStrLit(w, v.timezoneName)
    w.sb.add ')'
  of vkDuration:
    w.sb.add "(serde_duration " & $v.durationMicroseconds & ")"
  of vkRange:
    w.sb.add "(serde_range " & $v.rangeStart & " " & $v.rangeStop & " " &
             $v.rangeStep & " " &
             (if v.rangeInclusive: "true" else: "false") & ")"
  of vkSet:
    serdeEnterContainer(w, v)
    w.sb.add "(serde_set"
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
      # (serde_data_node <immutable> <head> <props-map> <meta-map> <child>*)
      w.sb.add "(serde_data_node "
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
      serdeEmitDefRef(w, v, "serde_enum_ref", "enum")
    else:
      serdeEmitDefRef(w, v, "serde_type_ref", "type")
  of vkProtocol:
    serdeEmitDefRef(w, v, "serde_protocol_ref", "protocol")
  of vkEnumVariant:
    serdeEmitDefRef(w, v, "serde_variant_ref", "enum variant")
  of vkNamespace:
    serdeEmitDefRef(w, v, "serde_ns_ref", "namespace")
  of vkNativeFn:
    serdeEmitDefRef(w, v, "serde_fn_ref", "native function")
  of vkFunction:
    if w.allowRefs and serdeOriginOf(w, v).found:
      serdeEmitDefRef(w, v, "serde_fn_ref", "function")
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
      # and sharing are not preserved (design §7). read_data still rejects it.
      w.sb.add "(serde_snapshot_cell "
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
  ## A typed instance: (serde_inst <head-ref> <props-serde-map> [body...]).
  ## Read-back uses direct typed-data construction (never ctor), so the head
  ## must be a resolvable type or enum variant.
  ##
  ## A module-level instance of a SerdeRef-marked type serializes by identity
  ## (serde_value_ref); a type with a `serde_state` type-direct message
  ## serializes its state (serde_hooked, ^allow_restore on read); otherwise
  ## fields (design §7).
  if not w.allowRefs:
    raiseSerdeError(w.scope,
      "typed instances are not data (use serde/write)", w.path)
  if v.head.kind == vkType and w.app != nil:
    serdeEnsureOrigins(w.app)
    if w.app.serdeValueOrigins.hasKey(v.bits) and
        serdeTypeIsSerdeRef(w.scope, v.head):
      let o = w.app.serdeValueOrigins[v.bits]
      serdeEmitRef(w, "serde_value_ref", o.module, o.path)
      return
  if v.head.kind == vkType:
    let stateFn = typeDirectMessage(v.head, "serde_state")
    if stateFn.kind != vkNil:
      let state = applyCall(stateFn, [v], NamedArgs(), w.scope)
      w.sb.add "(serde_hooked "
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
  w.sb.add "(serde_inst "
  w.path.add "type"
  serdeEmit(w, v.head)              # emits serde_type_ref / serde_variant_ref
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

proc serdeDataValueP(v: Value): bool

proc selectorIsSerializableData(v: Value): bool =
  if not v.isSelector:
    return true
  for segment in v.body:
    case segment.kind
    of vkInt, vkSymbol, vkString:
      discard
    of vkNode:
      if segment.head.isSymbol("selector_key") and segment.body.len == 1:
        if not serdeDataValueP(segment.body[0]):
          return false
      elif segment.isSelector:
        if not selectorIsSerializableData(segment):
          return false
      else:
        # call_stage and arbitrary node stages execute behavior.
        return false
    else:
      # Callable stages execute behavior and retain runtime authority.
      return false
  true

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
    if v.isSelector and not selectorIsSerializableData(v):
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
  w.sb.add "(serde_v1 "
  serdeEmit(w, v)
  w.sb.add ')'
  w.sb

proc serdeWriteFullText(v: Value, scope: Scope): string =
  var w = SerdeWriter(scope: scope, allowRefs: true,
                      app: application(scope))
  w.sb.add "(serde_v1 "
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
  result.maxBytes = serdePolicyInt(policy, "max_bytes", result.maxBytes, scope)
  result.maxNodes = serdePolicyInt(policy, "max_nodes", result.maxNodes, scope)
  result.maxDepth = serdePolicyInt(policy, "max_depth", result.maxDepth, scope)
  result.maxSymbols = serdePolicyInt(policy, "max_symbols",
                                     result.maxSymbols, scope)
  result.allowRestore = serdePolicyBool(policy, "allow_restore",
                                        result.allowRestore, scope)

proc serdeDecode(r: var SerdeReader, v: Value, depth: int): Value

proc serdeCountValue(r: var SerdeReader, depth: int) =
  inc r.nodes
  if r.nodes > r.limits.maxNodes:
    raiseSerdeError(r.scope, "payload exceeds max_nodes (" &
                    $r.limits.maxNodes & ")", r.path)
  if depth > r.limits.maxDepth:
    raiseSerdeError(r.scope, "payload exceeds max_depth (" &
                    $r.limits.maxDepth & ")", r.path)

proc serdeCountSymbol(r: var SerdeReader, s: string) =
  r.symbols.incl s
  if r.symbols.len > r.limits.maxSymbols:
    raiseSerdeError(r.scope, "payload exceeds max_symbols (" &
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
  # Slots first: on mirrored scopes the vars entry for a slot name may be
  # stale until the next materializeMirroredVars.
  for i in 0 ..< scope.slots.len:
    if i < scope.slotNames.len and scope.slotDefined(i) and
        scope.slotNames[i] == name:
      return (true, scope.slots[i])
  if scope.vars.hasKey(name):
    return (true, scope.vars.getOrDefault(name))
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
      tag & " requires serde/read (serde/read_data accepts pure data only)",
      r.path)
  let coords = serdeRefCoords(r, v, tag)
  let startScope = serdeResolveModuleScope(r, coords.module)
  let resolved = serdeLookupRefPath(r, startScope, coords.module, coords.path)
  let ok =
    case tag
    of "serde_type_ref": resolved.kind == vkType and not resolved.isEnumType
    of "serde_enum_ref": resolved.kind == vkType and resolved.isEnumType
    of "serde_protocol_ref": resolved.kind == vkProtocol
    of "serde_variant_ref": resolved.kind == vkEnumVariant
    of "serde_ns_ref": resolved.kind == vkNamespace
    of "serde_fn_ref": resolved.kind in {vkFunction, vkNativeFn}
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
      "serde_value_ref requires serde/read (serde/read_data accepts pure " &
      "data only)", r.path)
  let coords = serdeRefCoords(r, v, "serde_value_ref")
  let startScope = serdeResolveModuleScope(r, coords.module)
  serdeLookupRefPath(r, startScope, coords.module, coords.path)

proc serdeDecodeControl(r: var SerdeReader, v: Value, tag: string,
                        depth: int): Value =
  case tag
  of "serde_type_ref", "serde_enum_ref", "serde_protocol_ref",
     "serde_variant_ref", "serde_ns_ref", "serde_fn_ref":
    return serdeResolveRef(r, v, tag)
  of "serde_value_ref":
    return serdeResolveValueRef(r, v)
  else: discard
  case tag
  of "serde_float":
    serdeBodyLen(r, v, tag, 1)
    if v.body[0].kind != vkString:
      raiseSerdeError(r.scope, "serde_float expects a Str", r.path)
    case v.body[0].strVal
    of "nan": newFloat(NaN)
    of "+inf": newFloat(Inf)
    of "-inf": newFloat(NegInf)
    of "-0.0": newFloat(-0.0)
    else:
      raiseSerdeError(r.scope, "unknown serde_float value: " &
                      v.body[0].strVal, r.path)
      NIL
  of "serde_sym":
    serdeBodyLen(r, v, tag, 1)
    if v.body[0].kind != vkString:
      raiseSerdeError(r.scope, "serde_sym expects a Str", r.path)
    serdeCountSymbol(r, v.body[0].strVal)
    newSym(v.body[0].strVal)
  of "serde_set":
    if v.props.len > 0 or v.meta.len > 0:
      raiseSerdeError(r.scope, "serde_set expects no props", r.path)
    var items: seq[Value]
    for i, it in v.body:
      r.path.add $i
      let item = serdeDecode(r, it, depth + 1)
      if not isHashStable(item):
        raiseSerdeError(r.scope,
          "serde_set element is not hash-stable", r.path)
      for existing in items:
        if equal(existing, item):
          raiseSerdeError(r.scope,
            "serde_set contains a duplicate element", r.path)
      items.add item
      discard r.path.pop()
    newSet(items)
  of "serde_range":
    serdeBodyLen(r, v, tag, 4)
    for i in 0 .. 2:
      if v.body[i].kind != vkInt:
        raiseSerdeError(r.scope, "serde_range expects Int bounds", r.path)
    if v.body[3].kind != vkBool:
      raiseSerdeError(r.scope, "serde_range expects a Bool inclusive flag",
                      r.path)
    try:
      newRange(v.body[0].intVal, v.body[1].intVal, v.body[2].intVal,
               v.body[3].boolVal)
    except GeneError as e:
      raiseSerdeError(r.scope, "serde_range: " & e.msg, r.path)
      NIL
  of "serde_timezone":
    serdeBodyLen(r, v, tag, 3)
    if v.body[0].kind != vkBool or v.body[1].kind != vkInt or
        v.body[2].kind != vkString:
      raiseSerdeError(r.scope,
        "serde_timezone expects (Bool Int Str)", r.path)
    try:
      newTimezone(v.body[0].boolVal, int(v.body[1].intVal), v.body[2].strVal)
    except GeneError as e:
      raiseSerdeError(r.scope, "serde_timezone: " & e.msg, r.path)
      NIL
  of "serde_duration":
    serdeBodyLen(r, v, tag, 1)
    if v.body[0].kind != vkInt:
      raiseSerdeError(r.scope, "serde_duration expects an Int", r.path)
    newDuration(v.body[0].intVal)
  of "serde_map":
    serdeBodyLen(r, v, tag, 2)
    if v.body[0].kind != vkBool or v.body[1].kind != vkList:
      raiseSerdeError(r.scope,
        "serde_map expects (Bool [k v ...])", r.path)
    let items = v.body[1].listItems
    if items.len mod 2 != 0:
      raiseSerdeError(r.scope, "serde_map expects an even k/v list", r.path)
    var entries = initPropTable()
    var i = 0
    while i < items.len:
      if items[i].kind != vkString:
        raiseSerdeError(r.scope, "serde_map keys must be Str", r.path)
      let key = items[i].strVal
      if entries.hasKey(key):
        raiseSerdeError(r.scope, "serde_map duplicate key: " & key, r.path)
      r.path.add key
      entries[key] = serdeDecode(r, items[i + 1], depth + 1)
      discard r.path.pop()
      inc i, 2
    newMap(entries, immutable = v.body[0].boolVal)
  of "serde_data_node":
    if v.body.len < 4 or v.props.len > 0 or v.meta.len > 0:
      raiseSerdeError(r.scope,
        "serde_data_node expects (Bool head props meta child*)", r.path)
    if v.body[0].kind != vkBool:
      raiseSerdeError(r.scope,
        "serde_data_node expects a Bool immutable flag", r.path)
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
        "serde_data_node props/meta must decode to maps", r.path)
    var children: seq[Value]
    for i in 4 ..< v.body.len:
      r.path.add $(i - 4)
      children.add serdeDecode(r, v.body[i], depth + 1)
      discard r.path.pop()
    var props = initPropTable()
    for k, val in propsVal.mapEntries:
      props[k] = val
    var meta = initPropTable()
    for k, val in metaVal.mapEntries:
      meta[k] = val
    newNode(head, props = props, body = children, meta = meta,
            immutable = v.body[0].boolVal)
  of "serde_inst":
    if not r.resolveRefs:
      raiseSerdeError(r.scope,
        "serde_inst requires serde/read (serde/read_data accepts pure data " &
        "only)", r.path)
    for k, val in v.props:
      if k == "schema_version":
        if val.kind != vkInt:
          raiseSerdeError(r.scope,
            "serde_inst ^schema_version must be an Int", r.path)
      else:
        raiseSerdeError(r.scope,
          "serde_inst has unsupported prop ^" & k, r.path)
    if v.meta.len > 0:
      raiseSerdeError(r.scope, "serde_inst takes no meta", r.path)
    if v.body.len != 3:
      raiseSerdeError(r.scope,
        "serde_inst expects (head-ref props body)", r.path)
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
      raiseSerdeError(r.scope, "serde_inst props must decode to a map", r.path)
    if bodyVal.kind != vkList:
      raiseSerdeError(r.scope, "serde_inst body must decode to a list", r.path)
    if head.kind == vkType:
      var na: NamedArgs
      for k, val in propsVal.mapEntries:
        na.names.add k
        na.values.add val
      try:
        constructTypedInstance(head, bodyVal.listItems, na)
      except GeneError as e:
        raiseSerdeError(r.scope, "serde_inst construct: " & e.msg, r.path)
        NIL
    elif head.kind == vkEnumVariant:
      if propsVal.mapEntries.len > 0:
        raiseSerdeError(r.scope,
          "enum-variant instance must have no props", r.path)
      try:
        applyCall(head, bodyVal.listItems, NamedArgs())
      except GeneError as e:
        raiseSerdeError(r.scope, "serde_inst variant: " & e.msg, r.path)
        NIL
    else:
      raiseSerdeError(r.scope, "serde_inst head resolved to a " &
        $head.kind & ", not a type or variant", r.path)
      NIL
  of "serde_snapshot_cell":
    if not r.resolveRefs:
      raiseSerdeError(r.scope,
        "serde_snapshot_cell requires serde/read (serde/read_data accepts " &
        "pure data only)", r.path)
    serdeBodyLen(r, v, tag, 1)
    r.path.add "cell"
    let inner = serdeDecode(r, v.body[0], depth + 1)
    discard r.path.pop()
    newCell(inner)
  of "serde_hooked":
    if not r.resolveRefs:
      raiseSerdeError(r.scope,
        "serde_hooked requires serde/read (serde/read_data accepts pure " &
        "data only)", r.path)
    if not r.limits.allowRestore:
      raiseSerdeError(r.scope,
        "serde_hooked requires ^policy (SerdePolicy ^allow_restore true) — " &
        "restore hooks execute user code during deserialization", r.path)
    if v.props.len > 0 or v.meta.len > 0 or v.body.len != 2:
      raiseSerdeError(r.scope, "serde_hooked expects (type-ref state)", r.path)
    r.path.add "type"
    let head = serdeDecode(r, v.body[0], depth + 1)
    discard r.path.pop()
    if head.kind != vkType:
      raiseSerdeError(r.scope, "serde_hooked head must be a type", r.path)
    r.path.add "state"
    let state = serdeDecode(r, v.body[1], depth + 1)
    discard r.path.pop()
    let restoreFn = typeDirectMessage(head, "serde_restore")
    if restoreFn.kind == vkNil:
      raiseSerdeError(r.scope, "type " & head.typeName &
        " has a serde_state message but no serde_restore", r.path)
    try:
      applyCall(restoreFn, [state], NamedArgs(), r.scope)
    except GeneError as e:
      raiseSerdeError(r.scope, "serde_restore: " & e.msg, r.path)
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
    var entries = initPropTable()
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
    var props = initPropTable()
    for k, val in v.props:
      r.path.add k
      props[k] = serdeDecode(r, val, depth + 1)
      discard r.path.pop()
    var meta = initPropTable()
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
  requireOne("serde/write_data", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  newStr(serdeWriteDataText(args[0], scope))

proc biSerdeDataP(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("serde/data?", args)
  if serdeDataValueP(args[0]): TRUE else: FALSE

proc serdeReadEnvelope(name, text: string, scope: Scope, policy: Value,
                       resolveRefs: bool): Value =
  let limits = serdeLimitsFrom(policy, scope)
  if text.len > limits.maxBytes:
    raiseSerdeError(scope, "payload exceeds max_bytes (" &
                    $limits.maxBytes & ")")
  var forms: seq[Value]
  try:
    let readerMaxDepth =
      if limits.maxDepth <= 0: 0 else: limits.maxDepth + 1
    forms = readAll(text, "<serde>", ReadOptions(maxDepth: readerMaxDepth))
  except ReadError as e:
    raiseSerdeError(scope, "parse: " & e.msg)
  if forms.len != 1 or forms[0].kind != vkNode:
    raiseSerdeError(scope, "expected a single (serde_v1 ...) envelope")
  let envelope = forms[0]
  if envelope.head.kind != vkSymbol or envelope.head.symVal != "serde_v1":
    if envelope.head.kind == vkSymbol and
        envelope.head.symVal.startsWith(serdeReservedPrefix):
      raiseSerdeError(scope, "unsupported serde envelope version: " &
                      envelope.head.symVal)
    raiseSerdeError(scope, "expected a (serde_v1 ...) envelope")
  if envelope.body.len != 1 or envelope.props.len > 0 or
      envelope.meta.len > 0:
    raiseSerdeError(scope,
      "serde_v1 envelope expects exactly one payload form")
  var r = SerdeReader(scope: scope, limits: limits,
                      resolveRefs: resolveRefs,
                      app: (if resolveRefs: application(scope) else: nil))
  serdeDecode(r, envelope.body[0], 0)

proc biSerdeReadData(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError,
      "serde/read_data expects a Str plus optional ^policy")
  requireStr("serde/read_data", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  var policy = NIL
  if call != nil:
    for i, name in call[].namedNames:
      case name
      of "policy":
        policy = call[].namedValues[i]
      else:
        raiseSerdeError(scope,
          "serde/read_data got unexpected named argument: " & name)
  serdeReadEnvelope("serde/read_data", args[0].strVal, scope, policy,
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
  var props = initPropTable()
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
      var entries = initPropTable()
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
  var props = initPropTable()
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
      var entries = initPropTable()
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
  var props = initPropTable()
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
const storeCheckpointSchema = 1
const storeCheckpointRetain = 3

const sha256RoundConstants: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc sha256RotateRight(value: uint32, amount: int): uint32 {.inline.} =
  (value shr amount) or (value shl (32 - amount))

proc sha256Hex(data: string): string =
  ## Small dependency-free SHA-256 used for checkpoint validation and durable
  ## artifact ids. This is off every VM/reader hot path.
  var bytes = newSeq[byte](data.len)
  for i, c in data:
    bytes[i] = byte(ord(c))
  let bitLen = uint64(bytes.len) * 8'u64
  bytes.add 0x80'u8
  while (bytes.len mod 64) != 56:
    bytes.add 0'u8
  for shift in countdown(56, 0, 8):
    bytes.add byte((bitLen shr shift) and 0xff'u64)

  var state = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32,
               0xa54ff53a'u32, 0x510e527f'u32, 0x9b05688c'u32,
               0x1f83d9ab'u32, 0x5be0cd19'u32]
  var schedule: array[64, uint32]
  var offset = 0
  while offset < bytes.len:
    for i in 0 ..< 16:
      let j = offset + i * 4
      schedule[i] = (uint32(bytes[j]) shl 24) or
                    (uint32(bytes[j + 1]) shl 16) or
                    (uint32(bytes[j + 2]) shl 8) or uint32(bytes[j + 3])
    for i in 16 ..< 64:
      let s0 = sha256RotateRight(schedule[i - 15], 7) xor
               sha256RotateRight(schedule[i - 15], 18) xor
               (schedule[i - 15] shr 3)
      let s1 = sha256RotateRight(schedule[i - 2], 17) xor
               sha256RotateRight(schedule[i - 2], 19) xor
               (schedule[i - 2] shr 10)
      schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1
    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    for i in 0 ..< 64:
      let big1 = sha256RotateRight(e, 6) xor sha256RotateRight(e, 11) xor
                 sha256RotateRight(e, 25)
      let choose = (e and f) xor ((not e) and g)
      let temp1 = h + big1 + choose + sha256RoundConstants[i] + schedule[i]
      let big0 = sha256RotateRight(a, 2) xor sha256RotateRight(a, 13) xor
                 sha256RotateRight(a, 22)
      let majority = (a and b) xor (a and c) xor (b and c)
      let temp2 = big0 + majority
      h = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2
    state[0] += a
    state[1] += b
    state[2] += c
    state[3] += d
    state[4] += e
    state[5] += f
    state[6] += g
    state[7] += h
    offset += 64
  result = ""
  for word in state:
    result.add toHex(word, 8).toLowerAscii()

proc biCryptoSha256(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("crypto/sha256", args)
  requireStr("crypto/sha256", args[0])
  newStr(sha256Hex(args[0].strVal))

proc biCryptoRandomHex(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("crypto/random_hex", args)
  let size = requireInt64("crypto/random_hex", args[0])
  if size < 1 or size > 1024:
    raise newException(GeneError,
      "crypto/random_hex byte count must be between 1 and 1024")
  when not defined(emscripten) and not defined(geneWasm):
    try:
      let bytes = urandom(Natural(size))
      var encoded = newStringOfCap(bytes.len * 2)
      for value in bytes:
        encoded.add toHex(value, 2).toLowerAscii()
      newStr(encoded)
    except OSError as error:
      raise newException(GeneError,
        "crypto/random_hex could not read the operating-system random source: " &
        error.msg)
  else:
    raise newException(GeneError,
      "crypto/random_hex is unavailable on this target")

proc biCryptoSecureEqual(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "crypto/secure_equal? expects 2 arguments, got " & $args.len)
  requireStr("crypto/secure_equal? left", args[0])
  requireStr("crypto/secure_equal? right", args[1])
  let left = args[0].strVal
  let right = args[1].strVal
  var difference = left.len xor right.len
  for i in 0 ..< max(left.len, right.len):
    let a = if i < left.len: ord(left[i]) else: 0
    let b = if i < right.len: ord(right[i]) else: 0
    difference = difference or (a xor b)
  newBool(difference == 0)

proc storeOwnerOnly(path: string, directory = false) =
  try:
    if directory:
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    else:
      setFilePermissions(path, {fpUserRead, fpUserWrite})
  except OSError:
    discard

proc storeFsync(path: string, directory = false) =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let fd = posix.open(path.cstring, O_RDONLY)
    if fd >= 0:
      discard posix.fsync(fd)
      discard posix.close(fd)

proc storeWriteDurable(path, data: string) =
  writeFile(path, data)
  storeOwnerOnly(path)
  storeFsync(path)

when defined(posix):
  proc storeCRename(source, destination: cstring): cint
    {.importc: "rename", header: "<stdio.h>".}

proc storeReplaceFile(source, destination: string) =
  when defined(posix):
    if storeCRename(source.cstring, destination.cstring) != 0:
      raiseOSError(osLastError())
  else:
    if fileExists(destination):
      removeFile(destination)
    moveFile(source, destination)

proc storeGenerationName(generation: int64): string =
  align($generation, 20, '0')

proc storeCheckpointKey(generation: int64, name: string): string =
  "checkpoint/" & storeGenerationName(generation) & "/" & name

proc raiseStoreError(scope: Scope, kind, message: string, key = "") =
  var props = initPropTable()
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
    raiseStoreError(scope, "invalid_key",
      "store ^mode expects data or full")
  if result != "data" and result != "full":
    raiseStoreError(scope, "invalid_key",
      "store ^mode expects data or full, got " & result)

proc storeModeOf(store: Value, scope: Scope): string =
  storeModeText(scope, store.props.getOrDefault("mode", newSym("data")),
                "data")

proc storePolicyOf(store: Value): Value =
  store.props.getOrDefault("policy", NIL)

proc storeValidateKey(scope: Scope, key: string) =
  if key.len == 0:
    raiseStoreError(scope, "invalid_key", "store key must not be empty", key)

proc storeSqlIdent(scope: Scope, ident, label: string): string =
  if ident.len == 0:
    raiseStoreError(scope, "invalid_key", label & " must not be empty")
  if ident[0] notin {'A'..'Z', 'a'..'z', '_'}:
    raiseStoreError(scope, "invalid_key", "invalid SQL identifier for " & label)
  for c in ident:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
      raiseStoreError(scope, "invalid_key",
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
      raiseStoreError(scope, "invalid_key",
        "store/put got unexpected named argument: " & name)

proc storeSqliteDb(store: Value, scope: Scope): pointer =
  let dbVal = store.props.getOrDefault("db", NIL)
  sqliteHandle("Store/sqlite", dbVal, scope)

proc storeSqliteOwnerOnly(store: Value) =
  let dbValue = store.props.getOrDefault("db", VOID)
  if dbValue.kind == vkNode:
    let path = dbValue.props.getOrDefault("path", VOID)
    if path.kind == vkString and path.strVal != ":memory:":
      storeOwnerOnly(path.strVal)
      for suffix in ["-wal", "-shm", "-journal"]:
        if fileExists(path.strVal & suffix):
          storeOwnerOnly(path.strVal & suffix)

proc storeSqliteTable(store: Value): tuple[tableName, keyColumn, dataColumn: string] =
  (store.props["table"].strVal,
   store.props["key_column"].strVal,
   store.props["data_column"].strVal)

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
    (if named.hasArg("key_column"): (requireStr("store/sqlite/open ^key_column",
      named.getArg("key_column")); named.getArg("key_column").strVal)
     else: storeDefaultKeyColumn), "key_column")
  let dataColumn = storeSqlIdent(scope,
    (if named.hasArg("data_column"): (requireStr("store/sqlite/open ^data_column",
      named.getArg("data_column")); named.getArg("data_column").strVal)
     else: storeDefaultDataColumn), "data_column")
  let mode = if named.hasArg("mode"):
      storeModeText(scope, named.getArg("mode"))
    else:
      "data"
  let policy = storeNamedOr(named, "policy", NIL)
  for name in named.names:
    if name notin ["table", "key_column", "data_column", "mode", "policy"]:
      raiseStoreError(scope, "invalid_key",
        "store/sqlite/open got unexpected named argument: " & name)
  storeSqliteEnsureSchema(sqliteHandle("store/sqlite/open", args[0], scope),
                          tableName, keyColumn, dataColumn, scope)
  let databasePath = args[0].props.getOrDefault("path", VOID)
  if databasePath.kind == vkString:
    storeOwnerOnly(databasePath.strVal)
    for suffix in ["-wal", "-shm", "-journal"]:
      if fileExists(databasePath.strVal & suffix):
        storeOwnerOnly(databasePath.strVal & suffix)
  var props = initPropTable()
  props["db"] = args[0]
  props["table"] = newStr(tableName)
  props["key_column"] = newStr(keyColumn)
  props["data_column"] = newStr(dataColumn)
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
    storeSqliteOwnerOnly(args[0])
  else:
    let root = args[0].props["root"].strVal
    let path = root / (urlEncodeComponent(key) & ".gene")
    try:
      let temporary = path & ".tmp-" & $getCurrentProcessId()
      storeWriteDurable(temporary, data)
      storeReplaceFile(temporary, path)
      storeFsync(root, directory = true)
    except IOError as e:
      raiseStoreError(scope, "io", "Store/put: " & e.msg, key)
    except OSError as e:
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
      raiseStoreError(scope, "invalid_key",
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

proc storeCheckpointManifest(scope: Scope, generation: int64,
                             encoded: seq[(string, string)]): string =
  var hashes = initPropTable()
  for (name, data) in encoded:
    hashes[name] = newStr("sha256:" & sha256Hex(data))
  var manifest = initPropTable()
  manifest["schema"] = newInt(storeCheckpointSchema)
  manifest["generation"] = newInt(generation)
  manifest["hashes"] = newMap(hashes)
  storeEncode(scope, "data", newMap(manifest))

proc storeDecodeCheckpoint(scope: Scope, store: Value, generation: int64,
                           manifestText: string,
                           encoded: Table[string, string]): Value =
  let manifest = storeDecode(scope, "data", manifestText, NIL, "manifest")
  if manifest.kind != vkMap or
      manifest.mapEntries.getOrDefault("schema", VOID).kind != vkInt or
      manifest.mapEntries["schema"].intVal != storeCheckpointSchema or
      manifest.mapEntries.getOrDefault("generation", VOID).kind != vkInt or
      manifest.mapEntries["generation"].intVal != generation:
    return VOID
  let hashes = manifest.mapEntries.getOrDefault("hashes", VOID)
  if hashes.kind != vkMap:
    return VOID
  var records = initPropTable()
  let mode = storeModeOf(store, scope)
  let policy = storePolicyOf(store)
  for name, expected in hashes.mapEntries:
    if expected.kind != vkString or name notin encoded:
      return VOID
    let data = encoded[name]
    if expected.strVal != "sha256:" & sha256Hex(data):
      return VOID
    records[name] = storeDecode(scope, mode, data, policy, name)
  var resultProps = initPropTable()
  resultProps["generation"] = newInt(generation)
  resultProps["schema"] = newInt(storeCheckpointSchema)
  resultProps["records"] = newMap(records)
  newMap(resultProps)

proc storeFilesystemCheckpoint(scope: Scope, store: Value, generation: int64,
                               encoded: seq[(string, string)],
                               manifestText: string) =
  let root = store.props["root"].strVal
  let generations = root / "generations"
  createDir(generations)
  storeOwnerOnly(root, directory = true)
  storeOwnerOnly(generations, directory = true)
  let generationName = storeGenerationName(generation)
  let finalDir = generations / generationName
  let tempDir = generations / (".tmp-" & generationName & "-" &
    $getCurrentProcessId())
  if dirExists(tempDir):
    removeDir(tempDir)
  if dirExists(finalDir):
    raiseStoreError(scope, "conflict",
      "checkpoint generation already exists: " & $generation)
  createDir(tempDir)
  storeOwnerOnly(tempDir, directory = true)
  try:
    for (name, data) in encoded:
      storeWriteDurable(tempDir / (urlEncodeComponent(name) & ".gene"), data)
    storeWriteDurable(tempDir / "MANIFEST.gene", manifestText)
    storeFsync(tempDir, directory = true)
    storeReplaceFile(tempDir, finalDir)
    storeFsync(generations, directory = true)
    let currentTemp = root / (".CURRENT-" & $getCurrentProcessId())
    storeWriteDurable(currentTemp, generationName & "\n")
    storeReplaceFile(currentTemp, root / "CURRENT")
    storeFsync(root, directory = true)
  except OSError as e:
    if dirExists(tempDir):
      try: removeDir(tempDir)
      except OSError: discard
    raiseStoreError(scope, "io", "Store/checkpoint: " & e.msg)

  var complete: seq[string]
  for kind, path in walkDir(generations, relative = true):
    if kind == pcDir and not path.startsWith(".tmp-"):
      complete.add path
  complete.sort(SortOrder.Descending)
  if complete.len > storeCheckpointRetain:
    for name in complete[storeCheckpointRetain .. ^1]:
      try: removeDir(generations / name)
      except OSError: discard

proc storeSqliteCheckpoint(scope: Scope, store: Value, generation: int64,
                           encoded: seq[(string, string)],
                           manifestText: string) =
  let db = storeSqliteDb(store, scope)
  let names = storeSqliteTable(store)
  sqliteExecScript(db, "BEGIN IMMEDIATE", "Store/checkpoint", scope)
  try:
    for (name, data) in encoded:
      discard sqliteRunStmt(db, "insert or replace into " & names.tableName &
        "(" & names.keyColumn & ", " & names.dataColumn & ") values (?, ?)",
        [newStr(storeCheckpointKey(generation, "record/" & name)), newStr(data)],
        "Store/checkpoint", scope)
    discard sqliteRunStmt(db, "insert or replace into " & names.tableName &
      "(" & names.keyColumn & ", " & names.dataColumn & ") values (?, ?)",
      [newStr(storeCheckpointKey(generation, "manifest")), newStr(manifestText)],
      "Store/checkpoint", scope)
    discard sqliteRunStmt(db, "insert or replace into " & names.tableName &
      "(" & names.keyColumn & ", " & names.dataColumn & ") values (?, ?)",
      [newStr("checkpoint/CURRENT"), newStr(storeGenerationName(generation))],
      "Store/checkpoint", scope)
    sqliteExecScript(db, "COMMIT", "Store/checkpoint", scope)
    storeSqliteOwnerOnly(store)
  except GeneError, GenePanic:
    try: sqliteExecScript(db, "ROLLBACK", "Store/checkpoint", scope)
    except GeneError: discard
    raise

  let manifests = sqliteRunStmt(db, "select " & names.keyColumn & " from " &
    names.tableName & " where " & names.keyColumn & " like ? order by " &
    names.keyColumn & " desc", [newStr("checkpoint/%/manifest")],
    "Store/checkpoint", scope).rows
  if manifests.len > storeCheckpointRetain:
    for row in manifests[storeCheckpointRetain .. ^1]:
      let manifestKey = row.mapEntries[names.keyColumn].strVal
      let prefix = manifestKey[0 ..< manifestKey.len - "manifest".len]
      discard sqliteRunStmt(db, "delete from " & names.tableName & " where " &
        names.keyColumn & " like ?", [newStr(prefix & "%")],
        "Store/checkpoint", scope)

proc biStoreCheckpoint(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 3:
    raise newException(GeneError,
      "Store/checkpoint expects (store, generation, records)")
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  if args[1].kind != vkInt or args[1].intVal < 1:
    raiseStoreError(scope, "invalid_key",
      "Store/checkpoint generation must be a positive Int")
  if args[2].kind != vkMap:
    raiseStoreError(scope, "invalid_key",
      "Store/checkpoint records must be a Map")
  let generation = args[1].intVal
  let mode = storeModeOf(args[0], scope)
  var encoded: seq[(string, string)]
  for name, value in args[2].mapEntries:
    storeValidateKey(scope, name)
    encoded.add (name, storeEncode(scope, mode, value))
  let manifestText = storeCheckpointManifest(scope, generation, encoded)
  if kind == "SqliteStore":
    storeSqliteCheckpoint(scope, args[0], generation, encoded, manifestText)
  else:
    storeFilesystemCheckpoint(scope, args[0], generation, encoded, manifestText)
  newInt(generation)

proc storeLoadFilesystemCheckpoint(scope: Scope, store: Value): Value =
  let generations = store.props["root"].strVal / "generations"
  if not dirExists(generations):
    return NIL
  var candidates: seq[string]
  for kind, path in walkDir(generations, relative = true):
    if kind == pcDir and not path.startsWith(".tmp-"):
      candidates.add path
  candidates.sort(SortOrder.Descending)
  for name in candidates:
    var generation: int64
    try: generation = parseBiggestInt(name)
    except ValueError: continue
    let dir = generations / name
    let manifestPath = dir / "MANIFEST.gene"
    if not fileExists(manifestPath):
      continue
    try:
      let manifestText = readFile(manifestPath)
      let manifest = storeDecode(scope, "data", manifestText, NIL, "manifest")
      if manifest.kind != vkMap:
        continue
      let hashes = manifest.mapEntries.getOrDefault("hashes", VOID)
      if hashes.kind != vkMap:
        continue
      var encoded = initTable[string, string]()
      var complete = true
      for recordName, _ in hashes.mapEntries:
        let path = dir / (urlEncodeComponent(recordName) & ".gene")
        if not fileExists(path):
          complete = false
          break
        encoded[recordName] = readFile(path)
      if complete:
        let loaded = storeDecodeCheckpoint(scope, store, generation,
                                           manifestText, encoded)
        if loaded.kind != vkVoid:
          return loaded
    except GeneError, IOError, OSError:
      discard
  NIL

proc storeLoadSqliteCheckpoint(scope: Scope, store: Value): Value =
  let db = storeSqliteDb(store, scope)
  let names = storeSqliteTable(store)
  let manifests = sqliteRunStmt(db, "select " & names.keyColumn & ", " &
    names.dataColumn & " from " & names.tableName & " where " &
    names.keyColumn & " like ? order by " & names.keyColumn & " desc",
    [newStr("checkpoint/%/manifest")], "Store/load_checkpoint", scope).rows
  for row in manifests:
    let key = row.mapEntries[names.keyColumn].strVal
    let parts = key.split('/')
    if parts.len != 3:
      continue
    var generation: int64
    try: generation = parseBiggestInt(parts[1])
    except ValueError: continue
    let manifestText = row.mapEntries[names.dataColumn].strVal
    try:
      let manifest = storeDecode(scope, "data", manifestText, NIL, "manifest")
      if manifest.kind != vkMap:
        continue
      let hashes = manifest.mapEntries.getOrDefault("hashes", VOID)
      if hashes.kind != vkMap:
        continue
      var encoded = initTable[string, string]()
      var complete = true
      for recordName, _ in hashes.mapEntries:
        let record = sqliteRunStmt(db, "select " & names.dataColumn & " from " &
          names.tableName & " where " & names.keyColumn & " = ?",
          [newStr(storeCheckpointKey(generation, "record/" & recordName))],
          "Store/load_checkpoint", scope).rows
        if record.len == 0:
          complete = false
          break
        encoded[recordName] = record[0].mapEntries[names.dataColumn].strVal
      if complete:
        let loaded = storeDecodeCheckpoint(scope, store, generation,
                                           manifestText, encoded)
        if loaded.kind != vkVoid:
          return loaded
    except GeneError:
      discard
  NIL

proc biStoreLoadCheckpoint(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("Store/load_checkpoint", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  let kind = storeRequire(scope, args[0])
  if kind == "SqliteStore":
    storeLoadSqliteCheckpoint(scope, args[0])
  else:
    storeLoadFilesystemCheckpoint(scope, args[0])

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
    raiseStoreError(scope, "invalid_key", "store/fs/open requires ^root")
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
      raiseStoreError(scope, "invalid_key",
        "store/fs/open got unexpected named argument: " & name)
  try:
    createDir(root)
    storeOwnerOnly(root, directory = true)
  except OSError as e:
    raiseStoreError(scope, "io", "store/fs/open: " & e.msg)
  var props = initPropTable()
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
  let terminalError = defineErrorType("TerminalError")
  let cursesError = defineErrorType("CursesError")
  let httpClientError = defineErrorType("HttpClientError")
  let jsonError = defineErrorType("JsonError")
  let serdeError = defineErrorType("SerdeError")
  # Structured diagnostic logging (docs/proposals/logging.md). Logger methods
  # are receiver-dispatched through builtinReceiverMessage; lazy `*!` forms
  # are compiler-known macros selected from this same namespace.
  let logLevel = newEnum("LogLevel", @[],
    [(name: "error", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "warn", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "info", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "debug", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "trace", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL),
     (name: "off", payloadTypes: newSeq[Value](),
      hasBacking: false, backing: NIL)],
    NIL, root)
  let logScope = newScope(root)
  logScope.define("LogLevel", logLevel)
  logScope.define("Logger", newSym("Logger"))
  logScope.define("new_logger", newNativeCallFn("log/new_logger",
                                                biLogNewLogger))
  logScope.define("new_file_logger",
    newNativeCallFn("log/new_file_logger", biLogNewFileLogger))
  logScope.define("enabled?", newNativeCallFn("Logger/enabled?",
                                               biLoggerEnabled,
                                               acceptsNamed = false))
  logScope.define("emit", newNativeCallFn("Logger/emit", biLoggerEmit))
  logScope.define("child", newNativeCallFn("Logger/child", biLoggerChild))
  logScope.define("with", newNativeCallFn("Logger/with", biLoggerWith,
                                           acceptsNamed = false))
  logScope.define("error", newNativeCallFn("Logger/error", biLoggerError))
  logScope.define("warn", newNativeCallFn("Logger/warn", biLoggerWarn))
  logScope.define("info", newNativeCallFn("Logger/info", biLoggerInfo))
  logScope.define("debug", newNativeCallFn("Logger/debug", biLoggerDebug))
  logScope.define("trace", newNativeCallFn("Logger/trace", biLoggerTrace))
  root.define("log", newNamespace("log", logScope))
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
  stdParseScope.define("read_all", root.vars["read_all"])
  stdParseScope.define("format", newNativeCallFn("format", biParseFormat,
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
  strScope.define("byte_size", newNativeFn("str/byte_size", biStrByteSize))
  strScope.define("slice_bytes", newNativeFn("str/slice_bytes", biStrSliceBytes))
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
  httpScope.define("actor_pool", newNativeCallFn("http/actor_pool",
                                                 biHttpActorPool))
  httpScope.define("supervisor_policy",
                   newNativeCallFn("http/supervisor_policy",
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
  httpScope.define("ws_accept", newNativeCallFn("http/ws_accept",
                                                biHttpWsAccept))
  httpScope.define("ws_send", newNativeCallFn("http/ws_send", biHttpWsSend,
                                              acceptsNamed = false))
  httpScope.define("ws_close", newNativeCallFn("http/ws_close", biHttpWsClose,
                                               acceptsNamed = false))
  httpScope.define("HttpError", root.vars["HttpError"])
  let httpClientScope = newScope(root)
  httpClientScope.define("Http", newCapability("Net/Http"))
  httpClientScope.define("request",
    newNativeCallFn("net/http_client/request", biHttpClientRequest))
  httpClientScope.define("stream",
    newNativeCallFn("net/http_client/stream", biHttpClientStream))
  httpClientScope.define("HttpClientError", httpClientError)
  let netLowerScope = newScope(root)
  netLowerScope.define("http", newNamespace("net/http", httpScope))
  netLowerScope.define("http_client",
                       newNamespace("net/http_client", httpClientScope))
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
                                            "keys", "clear", "checkpoint",
                                            "load_checkpoint", "close"])
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
      ImplMessage(message: storeMessages["checkpoint"],
                  fn: newNativeCallFn("Store/checkpoint", biStoreCheckpoint,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["load_checkpoint"],
                  fn: newNativeCallFn("Store/load_checkpoint",
                                      biStoreLoadCheckpoint,
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
      ImplMessage(message: storeMessages["checkpoint"],
                  fn: newNativeCallFn("Store/checkpoint", biStoreCheckpoint,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["load_checkpoint"],
                  fn: newNativeCallFn("Store/load_checkpoint",
                                      biStoreLoadCheckpoint,
                                      acceptsNamed = false)),
      ImplMessage(message: storeMessages["close"],
                  fn: newNativeCallFn("Store/close", biStoreClose,
                                      acceptsNamed = false))])
  storeScope.define("sqlite", newNamespace("store/sqlite", storeSqliteScope))
  storeScope.define("fs", newNamespace("store/fs", storeFsScope))
  root.define("store", newNamespace("store", storeScope))

  let cryptoScope = newScope(root)
  cryptoScope.define("sha256", newNativeCallFn("crypto/sha256",
                                               biCryptoSha256,
                                               acceptsNamed = false))
  cryptoScope.define("random_hex", newNativeCallFn("crypto/random_hex",
                                                   biCryptoRandomHex,
                                                   acceptsNamed = false))
  cryptoScope.define("secure_equal?", newNativeCallFn("crypto/secure_equal?",
                                                      biCryptoSecureEqual,
                                                      acceptsNamed = false))
  root.define("crypto", newNamespace("crypto", cryptoScope))

  # os: env, subprocess, line input (examples/ai_agent/design.md §3,§6). Capabilities are
  # ambient values like Net/Connect; a launcher can withhold them.
  let osScope = newScope(root)
  osScope.define("Env", newCapability("Os/Env"))
  osScope.define("Exec", newCapability("Os/Exec"))
  osScope.define("Pty", newCapability("Os/Pty"))
  osScope.define("get_env", newNativeCallFn("os/get_env", biOsGetEnv,
                 acceptsNamed = false))
  osScope.define("env?", newNativeCallFn("os/env?", biOsEnvOpt,
                 acceptsNamed = false))
  osScope.define("executable_path",
                 newNativeFn("os/executable_path", biOsExecutablePath))
  osScope.define("exec", newNativeCallFn("os/exec", biOsExec))
  osScope.define("exec_stream", newNativeCallFn("os/exec_stream", biOsExecStream))
  osScope.define("exec_stdio", newNativeCallFn("os/exec_stdio", biOsExecStdio))
  osScope.define("exec_async", newNativeCallFn("os/exec_async", biOsExecAsync))
  osScope.define("exec_stream_async",
                 newNativeCallFn("os/exec_stream_async", biOsExecStreamAsync))
  osScope.define("exec_stdio_async",
                 newNativeCallFn("os/exec_stdio_async", biOsExecStdioAsync))
  osScope.define("begin_interrupt",
                 newNativeFn("os/begin_interrupt", biOsBeginInterrupt))
  osScope.define("take_interrupt",
                 newNativeFn("os/take_interrupt", biOsTakeInterrupt))
  osScope.define("end_interrupt",
                 newNativeFn("os/end_interrupt", biOsEndInterrupt))
  osScope.define("monotonic_ms",
                 newNativeFn("os/monotonic_ms", biOsMonotonicMs))
  osScope.define("process_id",
                 newNativeFn("os/process_id", biOsProcessId))
  osScope.define("stdin_tty?", newNativeFn("os/stdin_tty?", biOsStdinTty))
  osScope.define("read_line", newNativeFn("os/read_line", biOsReadLine))
  osScope.define("read_input", newNativeCallFn("os/read_input", biOsReadInput))
  osScope.define("refresh_input", newNativeCallFn("os/refresh_input", biOsRefreshInput))
  osScope.define("close_input", newNativeFn("os/close_input", biOsCloseInput))
  osScope.define("OsError", osError)
  root.define("os", newNamespace("os", osScope))

  # Local interactive terminal authority. The Session owns a PTY process and
  # a libvterm state machine; only attributed cells are exposed to curses.
  let terminalSessionType = newType("TerminalSession", NIL,
    @[TypeField(name: "id", optional: false, typeExpr: newSym("Int"),
                scope: root),
      TypeField(name: "closed", optional: false, typeExpr: newSym("Any"),
                scope: root)], @[], root)
  root.define("TerminalSession", terminalSessionType)
  let terminalScope = newScope(root)
  terminalScope.define("Session", terminalSessionType)
  terminalScope.define("TerminalError", terminalError)
  terminalScope.define("open", newNativeCallFn("terminal/open", biTerminalOpen))
  terminalScope.define("pump", newNativeCallFn("terminal/pump", biTerminalPump))
  terminalScope.define("next_update",
    newNativeCallFn("terminal/next_update", biTerminalNextUpdate))
  terminalScope.define("snapshot",
    newNativeCallFn("terminal/snapshot", biTerminalSnapshot,
                    acceptsNamed = false))
  terminalScope.define("capture_text",
    newNativeCallFn("terminal/capture_text", biTerminalCaptureText))
  terminalScope.define("write",
    newNativeCallFn("terminal/write", biTerminalWrite))
  terminalScope.define("key", newNativeCallFn("terminal/key", biTerminalKey))
  terminalScope.define("paste",
    newNativeCallFn("terminal/paste", biTerminalPaste))
  terminalScope.define("focus",
    newNativeCallFn("terminal/focus", biTerminalFocus))
  terminalScope.define("mouse",
    newNativeCallFn("terminal/mouse", biTerminalMouse))
  terminalScope.define("resize",
    newNativeCallFn("terminal/resize", biTerminalResize))
  terminalScope.define("signal",
    newNativeCallFn("terminal/signal", biTerminalSignal))
  terminalScope.define("stop",
    newNativeCallFn("terminal/stop", biTerminalStop,
                    acceptsNamed = false))
  terminalScope.define("request_stop",
    newNativeCallFn("terminal/request_stop", biTerminalRequestStop))
  terminalScope.define("close",
    newNativeCallFn("terminal/close", biTerminalClose,
                    acceptsNamed = false))
  root.define("terminal", newNamespace("terminal", terminalScope))

  # Public owned terminal surface. `os/read_input` remains a compatibility
  # wrapper; new code owns a Screen explicitly and closes it from ensure.
  let cursesScreenType = newType("CursesScreen", NIL,
    @[TypeField(name: "id", optional: false, typeExpr: newSym("Int"),
                scope: root),
      TypeField(name: "closed", optional: false, typeExpr: newSym("Any"),
                scope: root)], @[], root)
  root.define("CursesScreen", cursesScreenType)
  let cursesScope = newScope(root)
  cursesScope.define("Screen", cursesScreenType)
  cursesScope.define("CursesError", cursesError)
  cursesScope.define("open", newNativeCallFn("curses/open", biCursesOpen))
  cursesScope.define("close", newNativeCallFn("curses/close", biCursesClose,
                                               acceptsNamed = false))
  cursesScope.define("dimensions",
    newNativeCallFn("curses/dimensions", biCursesDimensions,
                    acceptsNamed = false))
  cursesScope.define("draw", newNativeCallFn("curses/draw", biCursesDraw))
  cursesScope.define("read_input",
    newNativeCallFn("curses/read_input", biCursesReadInput))
  cursesScope.define("refresh_input",
    newNativeCallFn("curses/refresh_input", biCursesRefreshInput))
  cursesScope.define("escape_pressed?",
    newNativeCallFn("curses/escape_pressed?", biCursesEscapePressed,
                    acceptsNamed = false))
  cursesScope.define("next_event",
    newNativeCallFn("curses/next_event", biCursesNextEvent,
                    acceptsNamed = false))
  root.define("curses", newNamespace("curses", cursesScope))

  # repl: shared declaration-persistent REPL loop used by the CLI wrapper and
  # interactive programs that need a scoped sub-REPL.
  let replSessionType = newType("ReplSession", NIL,
    @[TypeField(name: "id", optional: false, typeExpr: newSym("Int"),
                scope: root),
      TypeField(name: "closed", optional: false, typeExpr: newSym("Any"),
                scope: root)], @[], root)
  root.define("ReplSession", replSessionType)
  let replScope = newScope(root)
  replScope.define("Session", replSessionType)
  replScope.define("open", newNativeCallFn("repl/open", biReplOpen,
                                            acceptsNamed = false))
  replScope.define("eval_source",
    newNativeCallFn("repl/eval_source", biReplEval,
                    acceptsNamed = false))
  replScope.define("discard_pending",
    newNativeCallFn("repl/discard_pending", biReplDiscardPending,
                    acceptsNamed = false))
  replScope.define("eval_guard_begin",
    newNativeCallFn("repl/eval_guard_begin", biReplEvalGuardBegin,
                    acceptsNamed = false))
  replScope.define("eval_guard_end",
    newNativeCallFn("repl/eval_guard_end", biReplEvalGuardEnd,
                    acceptsNamed = false))
  replScope.define("close", newNativeCallFn("repl/close", biReplClose,
                                             acceptsNamed = false))
  replScope.define("run", newNativeCallFn("repl/run", biReplRun))
  root.define("repl", newNamespace("repl", replScope))

  # Extend the existing Fs namespace (built in vm.nim) with sync helpers the
  # agent file tools need.
  let fsNs = root.vars.getOrDefault("Fs", VOID)
  if fsNs.kind == vkNamespace:
    fsNs.nsScope.define("read_text",
      newNativeCallFn("Fs/read_text", biFsReadTextSync, acceptsNamed = false))
    fsNs.nsScope.define("write_text",
      newNativeCallFn("Fs/write_text", biFsWriteTextSync, acceptsNamed = false))
    fsNs.nsScope.define("exists?",
      newNativeCallFn("Fs/exists?", biFsExists, acceptsNamed = false))
    fsNs.nsScope.define("list_dir",
      newNativeCallFn("Fs/list_dir", biFsListDir, acceptsNamed = false))
    fsNs.nsScope.define("make_dir",
      newNativeCallFn("Fs/make_dir", biFsMakeDir, acceptsNamed = false))
    fsNs.nsScope.define("remove",
      newNativeCallFn("Fs/remove", biFsRemove, acceptsNamed = false))
    fsNs.nsScope.define("real_path",
      newNativeCallFn("Fs/real_path", biFsRealPath, acceptsNamed = false))

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
  serdeScope.define("write_data",
    newNativeCallFn("serde/write_data", biSerdeWriteData,
                    acceptsNamed = false))
  serdeScope.define("read_data",
    newNativeCallFn("serde/read_data", biSerdeReadData))
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
                                @[intField("max_bytes"),
                                  intField("max_nodes"),
                                  intField("max_depth"),
                                  intField("max_symbols"),
                                  TypeField(name: "allow_restore",
                                            optional: true,
                                            typeExpr: newSym("Bool"),
                                            scope: root)],
                                @[], root)
  serdeScope.define("SerdePolicy", serdePolicyType)
  root.define("serde", newNamespace("serde", serdeScope))
