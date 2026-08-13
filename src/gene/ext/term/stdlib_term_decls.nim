## Terminal and curses declarations: the C shim, the ncurses FFI surface,
## key/colour constants, and module-level session state.
##
## Split from stdlib_term.nim (the implementation) purely for ordering: the
## `gene_turn_interrupt_*` helpers in the {.emit.} block below back the
## `os/begin_interrupt` family, which stdlib.nim defines well before the
## terminal natives -- so these declarations must be included early while the
## implementation is included late. Both are `include`d by stdlib.nim, which is
## `include`d by vm.nim; neither is an importable module.
##
## Gated on posix && !emscripten && !geneWasm throughout.

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
