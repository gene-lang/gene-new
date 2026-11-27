## Scrollback-preserving POSIX editor for the interactive Gene REPL.

import std/[os, posix, strutils, tempfiles, terminal, unicode]
import posix/termios
import ./[editor, tui]
import ../../repl_completion

type
  Draft = object
    text: string
    cursor: int

  ReplTerminal* = ref object
    input, output, errors: File
    savedMode: Termios
    raw: bool
    pushedByte: int
    screenRow: int
    rendered: bool
    prompt: string
    history: seq[string]
    complete: proc(source: string, cursor: int): ReplCompletion {.closure.}

  HistorySearch = object
    active: bool
    query: string
    match: int

  WidthLocale {.importc: "locale_t", header: "<locale.h>".} = pointer

var lcCtypeMask {.importc: "LC_CTYPE_MASK", header: "<locale.h>".}: cint
proc newLocale(mask: cint, name: cstring, base: WidthLocale): WidthLocale
    {.importc: "newlocale", header: "<locale.h>".}
proc useLocale(locale: WidthLocale): WidthLocale {.importc: "uselocale", header: "<locale.h>".}
proc freeLocale(locale: WidthLocale) {.importc: "freelocale", header: "<locale.h>".}

const
  continuationPrompt = "....> "
  historyLimit = 1000
  displayLimit = 40
  completionRows = 6
  pasteEnd = "\e[201~"

proc emit(terminal: ReplTerminal, text: string) =
  terminal.output.write(text)
  terminal.output.flushFile()

proc rawMode(terminal: ReplTerminal): bool =
  let fd = terminal.input.getFileHandle
  if tcGetAttr(fd, addr terminal.savedMode) != 0:
    return false
  var mode = terminal.savedMode
  # Leave output processing in place. Ctrl-C is an editing key in this mode.
  mode.c_lflag = mode.c_lflag and not (ICANON or ECHO or ISIG or IEXTEN)
  mode.c_iflag = mode.c_iflag and not (IXON or IXOFF or ICRNL or INLCR or IGNCR or ISTRIP)
  mode.c_cc[VMIN] = '\x01'
  mode.c_cc[VTIME] = '\x00'
  terminal.raw = tcSetAttr(fd, TCSANOW, addr mode) == 0
  result = terminal.raw
  if result:
    terminal.emit("\e[?2004h")

proc restoreMode(terminal: ReplTerminal) =
  if terminal.raw:
    discard tcSetAttr(terminal.input.getFileHandle, TCSANOW, addr terminal.savedMode)
    terminal.raw = false
    terminal.emit("\e[?2004l")

proc close*(terminal: ReplTerminal) =
  terminal.restoreMode()

proc newReplTerminal*(input, output, errors: File, prompt: string,
                      complete: proc(source: string, cursor: int): ReplCompletion {.closure.}): ReplTerminal =
  if not isatty(input) or not isatty(output) or getEnv("TERM") == "dumb":
    return nil
  var mode: Termios
  if tcGetAttr(input.getFileHandle, addr mode) != 0:
    return nil
  ReplTerminal(input: input, output: output, errors: errors, prompt: prompt,
               pushedByte: -1, complete: complete)

proc record*(terminal: ReplTerminal, source: string) =
  if terminal.history.len == historyLimit:
    terminal.history.delete(0)
  terminal.history.add source

proc readByte(terminal: ReplTerminal, timeout = -1): int =
  if terminal.pushedByte >= 0:
    result = terminal.pushedByte
    terminal.pushedByte = -1
    return
  let fd = terminal.input.getFileHandle
  if timeout >= 0:
    var waiting = TPollfd(fd: fd, events: POLLIN)
    if poll(addr waiting, 1, cint(timeout)) <= 0:
      return -1
  var byteValue: uint8
  while true:
    let count = posix.read(fd, addr byteValue, 1)
    if count == 1: return int(byteValue)
    if count == 0 or osLastError() != OSErrorCode(EINTR): return -1

proc readEscape(terminal: ReplTerminal): string =
  let first = terminal.readByte(50)
  if first < 0:
    return ""
  if char(first) notin {'[', 'O'}:
    terminal.pushedByte = first
    return ""
  result.add char(first)
  while result.len < 32:
    let next = terminal.readByte(50)
    if next < 0: break
    result.add char(next)
    if next in 0x40 .. 0x7e: break

proc readPaste(terminal: ReplTerminal): string =
  while true:
    let next = terminal.readByte()
    if next < 0: return ""
    result.add char(next)
    if char(next) == '~' and result.endsWith(pasteEnd):
      result.setLen(result.len - pasteEnd.len)
      return result.replace("\r\n", "\n").replace("\r", "\n")

proc previousRune(text: string, cursor: int): int =
  result = max(0, cursor - 1)
  while result > 0 and (ord(text[result]) and 0xc0) == 0x80:
    dec result

proc nextRune(text: string, cursor: int): int =
  if cursor < text.len: min(text.len, cursor + text.runeLenAt(cursor)) else: cursor

proc readRune(terminal: ReplTerminal, first: char): string =
  result = $first
  let size = result.runeLenAt(0)
  for _ in 1 ..< size:
    let next = terminal.readByte(50)
    if next < 0: return ""
    if (next and 0xc0) != 0x80:
      terminal.pushedByte = next
      return ""
    result.add char(next)
  if result.validateUtf8 != -1:
    return ""

proc replace(draft: var Draft, first, last: int, text: string) =
  draft.text = draft.text[0 ..< first] & text & draft.text[last .. ^1]
  draft.cursor = first + text.len

proc beginLine(draft: Draft): int =
  if draft.cursor == 0: 0 else: draft.text.rfind('\n', last = draft.cursor - 1) + 1

proc endLine(draft: Draft): int =
  let next = draft.text.find('\n', draft.cursor)
  if next < 0: draft.text.len else: next

proc moveVertical(draft: var Draft, direction: int): bool =
  let first = draft.beginLine()
  let last = draft.endLine()
  var targetFirst, targetLast: int
  if direction < 0 and first > 0:
    targetLast = first - 1
    targetFirst = if targetLast == 0: 0 else: draft.text.rfind('\n', last = targetLast - 1) + 1
  elif direction > 0 and last < draft.text.len:
    targetFirst = last + 1
    let next = draft.text.find('\n', targetFirst)
    targetLast = if next < 0: draft.text.len else: next
  else:
    return false
  let column = textWidth(draft.text[first ..< draft.cursor])
  draft.cursor = targetFirst
  var used = 0
  while draft.cursor < targetLast:
    let next = nextRune(draft.text, draft.cursor)
    used += textWidth(draft.text[draft.cursor ..< next])
    if used > column: break
    draft.cursor = next
  true

proc clearDisplay(terminal: ReplTerminal) =
  if terminal.rendered:
    var erase = "\r"
    if terminal.screenRow > 0:
      erase.add "\e[" & $terminal.screenRow & "A"
    erase.add "\e[J"
    terminal.emit(erase)
    terminal.rendered = false

proc render(terminal: ReplTerminal, draft: Draft, search: HistorySearch,
            choices = ReplCompletion(), selected = -1) =
  terminal.clearDisplay()
  let fd = int(terminal.output.getFileHandle)
  let columns = terminalWidthIoctl([fd])
  let rows = terminalHeightIoctl([fd])
  # Reserve the last column so the terminal's deferred autowrap is irrelevant.
  let width = if columns > 2: columns - 1 else: 79
  let height = if rows > 1: rows - 1 else: 23
  var lines = @[""]
  var column = 0
  var cursorRow, cursorColumn: int
  var completionColumn = 0
  proc put(text: string) =
    for rune in text.runes:
      let raw = rune.toUTF8
      let n = int(rune)
      let shown =
        if n == 9: "  "
        elif n < 32 or n in 127 .. 159: "?"
        else: raw
      let cells = textWidth(shown)
      if column + cells > width:
        lines.add ""
        column = 0
      lines[^1].add shown
      column += cells

  if search.active:
    put(if search.match >= 0 or search.query.len == 0: "(reverse search) " else: "(no match) ")
    put(search.query)
    put("> ")
    if search.match >= 0:
      put(terminal.history[search.match].replace("\n", " ↵ "))
    cursorRow = lines.high
    cursorColumn = column
  else:
    put(terminal.prompt)
    var offset = 0
    while offset < draft.text.len:
      if offset == choices.first:
        completionColumn = column
      if offset == draft.cursor:
        cursorRow = lines.high
        cursorColumn = column
      if draft.text[offset] == '\n':
        lines.add ""
        column = 0
        put(continuationPrompt)
        inc offset
      else:
        let next = nextRune(draft.text, offset)
        put(draft.text[offset ..< next])
        offset = next
    if draft.cursor == draft.text.len:
      cursorRow = lines.high
      cursorColumn = column
    if choices.first == draft.text.len:
      completionColumn = column

  let rowsBelowCursor = lines.high - cursorRow
  let menuRows = min(choices.candidates.len,
                     min(completionRows, height - 1 - rowsBelowCursor))
  if menuRows > 0:
    let firstChoice = max(0, selected - menuRows + 1)
    var menuWidth = 0
    for i in firstChoice ..< firstChoice + menuRows:
      menuWidth = max(menuWidth, textWidth(choices.candidates[i]))
    menuWidth = min(menuWidth + 2, width)
    let left = min(completionColumn, width - menuWidth)
    for i in firstChoice ..< firstChoice + menuRows:
      let style = if i == selected: "\e[7m" else: "\e[2m"
      let label = fitCells(" " & choices.candidates[i], menuWidth)
      lines.add repeat(' ', left) & style & label & "\e[0m"

  let last = if menuRows > 0: lines.high else: min(lines.high, max(cursorRow, height - 1))
  let first = max(0, last - height + 1)
  var output = lines[first .. last].join("\r\n") & "\r"
  if last > cursorRow: output.add "\e[" & $(last - cursorRow) & "A"
  if cursorColumn > 0: output.add "\e[" & $cursorColumn & "C"
  terminal.emit(output)
  terminal.screenRow = cursorRow - first
  terminal.rendered = true

proc commonPrefix(names: openArray[string]): string =
  result = names[0]
  for i in 1 ..< names.len:
    var sameBytes = 0
    while sameBytes < min(result.len, names[i].len) and
        result[sameBytes] == names[i][sameBytes]:
      inc sameBytes
    while sameBytes < result.len and (ord(result[sameBytes]) and 0xc0) == 0x80:
      dec sameBytes
    result.setLen(sameBytes)

proc listCompletions(terminal: ReplTerminal, choices: ReplCompletion) =
  terminal.clearDisplay()
  let size = min(choices.candidates.len, displayLimit)
  var list = choices.candidates[0 ..< size].join("  ")
  if size < choices.candidates.len:
    list.add "  (" & $(choices.candidates.len - size) & " more)"
  terminal.emit(list & "\r\n")

proc liveCompletions(terminal: ReplTerminal, draft: Draft): ReplCompletion =
  if draft.cursor == 0 or draft.text[draft.cursor - 1] in
      {' ', '\t', '\r', '\n', '(', ')', '[', ']', '{', '}', ',', ';'}:
    return
  result = terminal.complete(draft.text, draft.cursor)
  if (result.prefix.len == 0 and not result.member) or
      (result.candidates.len == 1 and
       result.candidates[0] == draft.text[result.first ..< result.last]):
    result.candidates.setLen(0)

proc cycleChoice(current, count, direction: int): int =
  if current < 0:
    if direction > 0: 0 else: count - 1
  else:
    (current + count + direction) mod count

proc editExternally(terminal: ReplTerminal, draft: var Draft) =
  terminal.clearDisplay()
  terminal.restoreMode()
  var path = ""
  try:
    let command = resolveEditor()
    let (file, name) = createTempFile("gene-repl-", ".gene")
    path = name
    try:
      file.write(draft.text)
    finally:
      file.close()
    let position = draft.text[0 ..< draft.cursor]
    let line = position.count('\n') + 1
    let column = position.len - position.rfind('\n')
    let status = launchEditor(command, path, line, column)
    if status != 0:
      raise newException(IOError, "editor exited with status " & $status)
    let revised = readFile(path)
    draft = Draft(text: revised, cursor: revised.len)
  except CatchableError as error:
    terminal.errors.writeLine("Could not edit draft: " & error.msg)
    terminal.errors.flushFile()
  finally:
    if path.len > 0:
      discard tryRemoveFile(path)

proc findMatch(search: var HistorySearch, history: seq[string], start: int) =
  search.match = -1
  for i in countdown(start, 0):
    if search.query in history[i]:
      search.match = i
      break

proc finishDraft*(terminal: ReplTerminal) =
  terminal.restoreMode()
  terminal.emit("\r\n")
  terminal.rendered = false

proc readDraft*(terminal: ReplTerminal, source: var string, continued: bool): bool =
  # wcwidth follows the C locale. Select the terminal's locale on this thread
  # only, leaving the running Gene application and other lanes untouched.
  let locale = newLocale(lcCtypeMask, "", nil)
  let priorLocale = if locale != nil: useLocale(locale) else: nil
  defer:
    if locale != nil:
      if priorLocale != nil: discard useLocale(priorLocale)
      freeLocale(locale)
  var draft = Draft(text: source, cursor: source.len)
  if continued:
    draft.text.add '\n'
    inc draft.cursor
  if not terminal.raw and not terminal.rawMode():
    raise newException(IOError, "could not set REPL terminal mode")
  var submitted = false
  defer:
    if not submitted:
      terminal.restoreMode()
  var historyIndex = terminal.history.len
  var unsaved: Draft
  var search: HistorySearch
  var selected = -1
  var dismissed = false

  template navigate(direction: int) =
    if not draft.moveVertical(direction):
      let next = historyIndex + direction
      if next in 0 .. terminal.history.len:
        if historyIndex == terminal.history.len:
          unsaved = draft
        historyIndex = next
        if next == terminal.history.len:
          draft = unsaved
        else:
          let text = terminal.history[next]
          draft = Draft(text: text, cursor: text.len)

  while true:
    let choices =
      if not search.active and not dismissed: terminal.liveCompletions(draft)
      else: ReplCompletion()
    if selected >= choices.candidates.len:
      selected = -1
    terminal.render(draft, search, choices, selected)
    let byteValue = terminal.readByte()
    if byteValue < 0:
      terminal.clearDisplay()
      return false
    let key = char(byteValue)
    let previousSelection = selected
    selected = -1
    dismissed = false
    if key == '\x03':
      terminal.clearDisplay()
      terminal.emit("^C\r\n")
      search.active = false
      draft = Draft()
      historyIndex = terminal.history.len
      continue
    if search.active:
      case key
      of '\x12':
        if search.match > 0:
          let previous = search.match
          search.findMatch(terminal.history, search.match - 1)
          if search.match < 0: search.match = previous
      of '\r', '\n':
        if search.match >= 0:
          let text = terminal.history[search.match]
          draft = Draft(text: text, cursor: text.len)
          historyIndex = terminal.history.len
        search.active = false
      of '\e':
        if terminal.readEscape() == "[200~":
          search.query.add terminal.readPaste()
          search.findMatch(terminal.history, terminal.history.high)
        else:
          search.active = false
      of '\x07': search.active = false
      of '\x08', '\x7f':
        search.query.setLen(previousRune(search.query, search.query.len))
        search.findMatch(terminal.history, terminal.history.high)
      of ' ' .. '~', '\x80' .. '\xff':
        search.query.add terminal.readRune(key)
        search.findMatch(terminal.history, terminal.history.high)
      else: discard
      continue
    case key
    of '\r', '\n':
      if previousSelection >= 0:
        draft.replace(choices.first, choices.last, choices.candidates[previousSelection])
        dismissed = true
        continue
      draft.cursor = draft.text.len
      terminal.render(draft, search)
      source = move(draft.text)
      submitted = true
      return true
    of '\t':
      let matches =
        if choices.candidates.len > 0: choices
        else: terminal.complete(draft.text, draft.cursor)
      if matches.candidates.len == 0:
        continue
      if matches.prefix.len == 0:
        terminal.listCompletions(matches)
      else:
        let prefix = commonPrefix(matches.candidates)
        if prefix.len > matches.prefix.len or matches.candidates.len == 1:
          draft.replace(matches.first, matches.last, prefix)
        else:
          selected = cycleChoice(previousSelection, matches.candidates.len, 1)
    of '\x01': draft.cursor = draft.beginLine()
    of '\x04':
      if draft.text.len == 0:
        terminal.finishDraft()
        return false
      draft.replace(draft.cursor, nextRune(draft.text, draft.cursor), "")
    of '\x05':
      terminal.editExternally(draft)
      if not terminal.rawMode():
        raise newException(IOError, "could not restore REPL terminal mode")
    of '\x08', '\x7f':
      draft.replace(previousRune(draft.text, draft.cursor), draft.cursor, "")
    of '\x0e': navigate(1)
    of '\x10': navigate(-1)
    of '\x12':
      search = HistorySearch(active: true, match: terminal.history.high)
    of '\e':
      case terminal.readEscape()
      of "[A", "OA":
        if previousSelection >= 0:
          selected = cycleChoice(previousSelection, choices.candidates.len, -1)
        else:
          navigate(-1)
      of "[B", "OB":
        if previousSelection >= 0:
          selected = cycleChoice(previousSelection, choices.candidates.len, 1)
        else:
          navigate(1)
      of "[Z":
        if choices.candidates.len > 1:
          selected = cycleChoice(previousSelection, choices.candidates.len, -1)
      of "[C", "OC": draft.cursor = nextRune(draft.text, draft.cursor)
      of "[D", "OD": draft.cursor = previousRune(draft.text, draft.cursor)
      of "[H", "OH", "[1~", "[7~": draft.cursor = draft.beginLine()
      of "[F", "OF", "[4~", "[8~": draft.cursor = draft.endLine()
      of "[3~": draft.replace(draft.cursor, nextRune(draft.text, draft.cursor), "")
      of "[200~": draft.replace(draft.cursor, draft.cursor, terminal.readPaste())
      of "": dismissed = true
      else: discard
    of ' ' .. '~', '\x80' .. '\xff':
      draft.replace(draft.cursor, draft.cursor, terminal.readRune(key))
    else: discard
