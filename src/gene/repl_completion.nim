## Completion for editable Gene source, independent of the terminal adapter.

import std/[algorithm, sequtils, strutils, unicode]
import ./[compiler, reader, types, vm]

type
  ReplCompletion* = object
    first*, last*: int         # UTF-8 byte span, exclusive end
    prefix*: string
    member*: bool
    candidates*: seq[string]

  CompletionKind = enum
    ckName, ckMember, ckMessage, ckPathMessage

proc readableSymbol(name: string): bool =
  if name.len == 0 or '/' in name or name.endsWith("...") or
      name.startsWith(".") or name.startsWith("?.") or
      name.startsWith("~") or name.startsWith("?~") or
      qualifiedMessageSplit(name) >= 0 or name.validateUtf8 != -1:
    return false
  for ch in name:
    if ch < ' ' or ch == '\x7f':
      return false
  let lexed = lexEditBuffer(name)
  lexed.stoppedAt < 0 and lexed.tokens.len == 1 and
    lexed.tokens[0].kind == tkSymbol and lexed.tokens[0].lexeme == name

proc datumEnd(tokens: openArray[SpannedToken], start, depth: int): int =
  ## Source erased by #_ stays outside the editor's completion context.
  if start >= tokens.len or depth == 0: return tokens.len + 1
  case tokens[start].kind
  of tkLParen, tkHashLParen, tkLBracket, tkHashLBracket, tkLBrace,
      tkHashLBrace, tkHashMapStart:
    var open = if tokens[start].kind == tkHashMapStart: 2 else: 1
    result = start + 1
    while result < tokens.len and open > 0:
      case tokens[result].kind
      of tkLParen, tkHashLParen, tkLBracket, tkHashLBracket, tkLBrace, tkHashLBrace: inc open
      of tkHashMapStart: inc open, 2
      of tkRParen, tkRBracket, tkRBrace: dec open
      else: discard
      inc result
    if open > 0: result = tokens.len + 1
  of tkLineComment, tkBlockComment, tkComma, tkBacktick, tkPercent,
      tkRef, tkDeref, tkDollar:
    result = datumEnd(tokens, start + 1, depth - 1)
  of tkWrap, tkUnderscore:
    let first = datumEnd(tokens, start + 1, depth - 1)
    result = datumEnd(tokens, first, depth - 1)
  else: result = start + 1

proc completionReceiver(scope: Scope, spelling: string): Value =
  if spelling.len == 0 or spelling.startsWith("/"):
    return MISSING
  let path = if spelling[0] == '$': "gene/" & spelling[1 .. ^1] else: spelling
  let parts = path.split('/')
  if not readableSymbol(parts[0]) or parts[0] in ["true", "false", "nil", "super"]:
    return MISSING
  result = scope.replBinding(parts[0])
  for i in 1 ..< parts.len:
    if result.isMissing:
      break
    let part = parts[i]
    if part.len == 0:
      continue
    if readableSymbol(part):
      result = replStructuralMember(result, newStr(part))
    else:
      let segment = lexEditBuffer(part)
      if segment.tokens.len != 1 or segment.tokens[0].kind != tkInt or
          segment.tokens[0].endByte != part.len:
        return MISSING
      try:
        result = replStructuralMember(result, readAll(part)[0])
      except ReadError:
        return MISSING

proc completeRepl*(scope: Scope, source: string, cursor: int): ReplCompletion =
  result.first = cursor
  result.last = cursor
  if cursor < 0 or cursor > source.len or
      (cursor < source.len and (ord(source[cursor]) and 0xc0) == 0x80):
    return
  let (tokens, stoppedAt) = lexEditBuffer(source)
  if stoppedAt >= 0 and cursor >= stoppedAt:
    return
  var active = -1
  for i, token in tokens:
    if token.startByte > cursor:
      break
    if token.kind == tkUnderscore:
      let next = datumEnd(tokens, i + 1, 64)
      if next > tokens.len or cursor <= tokens[next - 1].endByte:
        return
    if cursor <= token.endByte:
      case token.kind
      of tkLineComment: return
      of tkBlockComment, tkString, tkRegex, tkChar, tkBytes, tkInt, tkFloat,
          tkDate, tkTime, tkDateTime:
        if cursor < token.endByte or active < 0:
          return
      of tkSymbol, tkGeneMember:
        active = i
      else:
        if cursor < token.endByte:
          return

  var kind = ckName
  var receiver = ""
  if active >= 0:
    let token = tokens[active]
    let text = source[token.startByte ..< token.endByte]
    let before = source[token.startByte ..< cursor]
    result.first = token.startByte
    result.last = token.endByte
    if before.startsWith(".") or before.startsWith("?."):
      # For an explicit send, only a simple head `(receiver .` is safe to
      # inspect. Parenthesized calls, literals and computed heads can follow.
      if before.startsWith("..") or active < 2 or
          tokens[active - 2].kind notin {tkLParen, tkHashLParen} or
          tokens[active - 1].kind notin {tkSymbol, tkGeneMember}:
        return
      let head = tokens[active - 1]
      receiver = source[head.startByte ..< head.endByte]
      result.first += (if before.startsWith("?."): 2 else: 1)
      kind = ckMessage
    else:
      let sep = before.rfind('/')
      if sep >= 0:
        receiver = before[0 ..< sep]
        if receiver.len == 0:
          return
        if receiver == "$": receiver = "gene"
        result.first += sep + 1
        let next = text.find('/', sep + 1)
        if next >= 0: result.last = token.startByte + next
        let segment = source[result.first ..< cursor]
        kind = ckMember
        if segment.startsWith(".") or segment.startsWith("?."):
          if segment.startsWith("..") or next >= 0:
            return
          result.first += (if segment.startsWith("?."): 2 else: 1)
          kind = ckPathMessage
        elif segment.startsWith("%"):
          return
      elif before.startsWith("$"):
        receiver = "gene"
        inc result.first
        let next = text.find('/')
        if next >= 0: result.last = token.startByte + next
        kind = ckMember
      else:
        let next = text.find('/')
        if next >= 0: result.last = token.startByte + next
        if active > 0:
          let prev = tokens[active - 1]
          if prev.endByte == token.startByte and prev.kind in
              {tkCaret, tkCaretCaret, tkCaretBang, tkAt, tkAtAt, tkAtBang}:
            return

  result.prefix = source[result.first ..< cursor]
  result.member = kind != ckName
  let prefix = result.prefix
  proc matching(names: seq[string]): seq[string] =
    for name in names:
      if name.startsWith(prefix) and
          (readableSymbol(name) or (kind == ckName and name in ["/", "//"])):
        result.add name
    result.sort()
    result = result.deduplicate(isSorted = true)

  case kind
  of ckName:
    let (local, builtin) = scope.replBindingNames()
    let sessionNames = local & scope.replMacroNames()
    let keywords = @CoreSpecialFormNames & @["true", "false", "nil"]
    # Keep session bindings and syntax ahead of the prelude in a capped menu.
    result.candidates =
      if prefix.len == 0:
        let names = matching(sessionNames)
        let syntax = matching(keywords.filterIt(it notin names))
        names & syntax & matching(builtin.filterIt(it notin names and it notin syntax))
      else:
        matching(sessionNames & keywords & builtin)
  of ckMember:
    result.candidates = matching(scope.completionReceiver(receiver).replMemberNames())
  of ckMessage, ckPathMessage:
    result.candidates = matching(scope.completionReceiver(receiver).
      replMessageNames(kind == ckPathMessage))
