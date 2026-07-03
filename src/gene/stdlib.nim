## Gene standard library surface (docs/stdlib.md).
##
## This file is `include`d by vm.nim after the core native helpers are
## defined: the stdlib natives use the VM's require*/applyCall/raise* helpers
## and the socket imports from vm.nim's prelude. Everything user-facing here
## is registered by `registerStdlibNamespaces`, which buildBuiltins calls on
## the built-ins root scope; nothing in this file touches VM dispatch state.

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


# --- net/http blocking server MVP (docs/stdlib.md phase 3) ---

const httpMaxBodyBytes = 10 * 1024 * 1024
const httpMaxHeaderLines = 128
const httpRecvTimeoutMs = 10_000

proc httpNamespaceBinding(scope: Scope, name: string): Value =
  let root =
    if scope != nil: scope.application().builtinsScope()
    else: builtinsScope()
  let netNs = root.vars.getOrDefault("net", VOID)
  if netNs.kind != vkNamespace:
    return VOID
  let httpNs = netNs.nsScope.vars.getOrDefault("http", VOID)
  if httpNs.kind != vkNamespace:
    return VOID
  httpNs.nsScope.vars.getOrDefault(name, VOID)

proc raiseHttpError(message: string, scope: Scope) =
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(message)
  var e: ref GeneError
  new(e)
  e.msg = message
  e.errVal = newNode(builtInTypeHead(scope, "HttpError"), props = props)
  e.hasErrVal = true
  raise e

proc httpStatusText(code: int): string =
  case code
  of 200: "OK"
  of 201: "Created"
  of 204: "No Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 303: "See Other"
  of 400: "Bad Request"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 500: "Internal Server Error"
  else: "Status " & $code

proc newHttpResponseValue(scope: Scope, status: int, body: string,
                          contentType: string): Value =
  var props = initOrderedTable[string, Value]()
  props["status"] = newInt(status)
  var headers = initOrderedTable[string, Value]()
  headers["content-type"] = newStr(contentType)
  props["headers"] = newMap(headers)
  let head = httpNamespaceBinding(scope, "Response")
  newNode(if head.kind == vkType: head else: newSym("Response"),
          props = props, body = @[newStr(body)])

proc sendHttpResponse(client: Socket, status: int, body: string,
                      headers: OrderedTable[string, string]) =
  var payload = "HTTP/1.1 " & $status & " " & httpStatusText(status) & "\r\n"
  var hasContentType = false
  for key, val in headers:
    if key.contains({'\r', '\n'}) or val.contains({'\r', '\n'}):
      continue   # never let handler data split the response
    if key.toLowerAscii() == "content-type":
      hasContentType = true
    payload.add key & ": " & val & "\r\n"
  if not hasContentType:
    payload.add "content-type: text/html; charset=utf-8\r\n"
  payload.add "content-length: " & $body.len & "\r\n"
  payload.add "connection: close\r\n\r\n"
  payload.add body
  client.send(payload)

proc sendSimpleHttpResponse(client: Socket, status: int, body: string) =
  sendHttpResponse(client, status, body,
                   initOrderedTable[string, string]())

proc parseHttpRequest(client: Socket, scope: Scope): Value =
  ## Read one HTTP/1.1 request and build a Request node. Returns VOID when the
  ## request is malformed (caller answers 400) or the connection is dead.
  let requestLine = client.recvLine(timeout = httpRecvTimeoutMs)
  if requestLine.len == 0 or requestLine == "\r\n":
    return VOID
  let lineParts = requestLine.split(' ')
  if lineParts.len != 3 or not lineParts[2].startsWith("HTTP/"):
    return VOID
  let httpMethod = lineParts[0]
  let target = lineParts[1]
  var path = target
  var query = ""
  let qMark = target.find('?')
  if qMark >= 0:
    path = target[0 ..< qMark]
    query = target[qMark + 1 .. ^1]
  var headers = initOrderedTable[string, Value]()
  var contentLength = 0
  var headerLines = 0
  while true:
    inc headerLines
    if headerLines > httpMaxHeaderLines:
      return VOID
    let line = client.recvLine(timeout = httpRecvTimeoutMs)
    if line.len == 0 or line == "\r\n":
      break
    let colon = line.find(':')
    if colon <= 0:
      return VOID
    let key = line[0 ..< colon].strip().toLowerAscii()
    let val = line[colon + 1 .. ^1].strip()
    headers[key] = newStr(val)
    if key == "content-length":
      try:
        contentLength = parseInt(val)
      except ValueError:
        return VOID
      if contentLength < 0 or contentLength > httpMaxBodyBytes:
        return VOID
  var body = ""
  if contentLength > 0:
    body = client.recv(contentLength, timeout = httpRecvTimeoutMs)
    if body.len < contentLength:
      return VOID
  var params: OrderedTable[string, Value]
  try:
    params = parseQueryEntries(query, scope)
  except GeneError:
    return VOID   # malformed percent escape in the query is the client's fault
  var props = initOrderedTable[string, Value]()
  props["method"] = newStr(httpMethod)
  props["path"] = newStr(path)
  props["query"] = newStr(query)
  props["params"] = newMap(params)
  props["headers"] = newMap(headers)
  props["body"] = newStr(body)
  let head = httpNamespaceBinding(scope, "Request")
  newNode(if head.kind == vkType: head else: newSym("Request"),
          props = props)

proc responseWireParts(resp: Value, scope: Scope):
    tuple[status: int, body: string, headers: OrderedTable[string, string]] =
  result.status = 200
  if resp.kind == vkString:
    result.body = resp.strVal
    return
  if resp.kind != vkNode:
    raiseHttpError("http handler must return a Response or Str, got " &
                   $resp.kind, scope)
  let props = resp.props
  if props.hasKey("status"):
    result.status = int(requireInt64("Response status", props["status"]))
  if props.hasKey("headers"):
    let headerMap = props["headers"]
    if headerMap.kind != vkMap:
      raiseHttpError("Response headers must be a Map", scope)
    for key, val in headerMap.mapEntries:
      requireStr("Response header value", val)
      result.headers[key] = val.strVal
  if props.hasKey("body"):
    requireStr("Response body", props["body"])
    result.body.add props["body"].strVal
  for item in resp.body:
    requireStr("Response body item", item)
    result.body.add item.strVal

proc biHttpServe(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError,
      "http/serve expects (Server, handler), got " & $args.len & " arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  if args[0].kind != vkNode or not args[0].props.hasKey("port"):
    raiseHttpError("http/serve expects a Server value with ^host and ^port",
                   scope)
  let serverProps = args[0].props
  let host =
    if serverProps.hasKey("host"):
      requireStr("Server host", serverProps["host"])
      serverProps["host"].strVal
    else:
      "127.0.0.1"
  let port = int(requireInt64("Server port", serverProps["port"]))
  if port < 0 or port > 65535:
    raiseHttpError("Server port out of range: " & $port, scope)
  var maxRequests = -1
  if call != nil:
    for name in call[].namedNames:
      if name != "max-requests":
        raise newException(GeneError,
          "http/serve got unexpected named argument: " & name)
    let index = nativeNamedIndex(call, "max-requests")
    if index >= 0:
      maxRequests = int(requireInt64("http/serve max-requests",
                                     call[].namedValues[index]))
  var server = newSocket()
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(port), host)
    server.listen()
  except OSError as e:
    server.close()
    raiseHttpError("http/serve failed to listen on " & host & ":" & $port &
                   ": " & e.msg, scope)
  var served = 0
  try:
    while maxRequests < 0 or served < maxRequests:
      var client: Socket
      try:
        server.accept(client)
      except OSError:
        break
      try:
        var requestValue = VOID
        try:
          requestValue = parseHttpRequest(client, scope)
        except TimeoutError, OSError:
          discard
        if requestValue.kind == vkVoid:
          sendSimpleHttpResponse(client, 400, "Bad Request")
        else:
          try:
            var handlerArgs = [requestValue]
            let resp = applyCall(args[1], handlerArgs, NamedArgs(), scope)
            let wire = responseWireParts(resp, scope)
            sendHttpResponse(client, wire.status, wire.body, wire.headers)
          except GeneError as e:
            stderr.writeLine "http/serve handler error: " & e.msg
            sendSimpleHttpResponse(client, 500, "Internal Server Error")
          except GenePanic as e:
            stderr.writeLine "http/serve handler panic: " & e.msg
            sendSimpleHttpResponse(client, 500, "Internal Server Error")
      except OSError:
        discard   # client went away mid-response; keep serving
      finally:
        client.close()
      inc served
  finally:
    server.close()
  NIL

proc biHttpText(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("http/text", args)
  requireStr("http/text", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  newHttpResponseValue(scope, 200, args[0].strVal,
                       "text/plain; charset=utf-8")

proc biHttpHtml(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("http/html", args)
  requireStr("http/html", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  newHttpResponseValue(scope, 200, args[0].strVal,
                       "text/html; charset=utf-8")

proc biHttpJson(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("http/json", args)
  requireStr("http/json", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  newHttpResponseValue(scope, 200, args[0].strVal, "application/json")

proc biHttpNotFound(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  let body =
    if args.len >= 1:
      requireStr("http/not_found", args[0])
      args[0].strVal
    else:
      "Not Found"
  newHttpResponseValue(scope, 404, body, "text/html; charset=utf-8")

proc biHttpRedirect(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  requireOne("http/redirect", args)
  requireStr("http/redirect", args[0])
  let scope = if call == nil: nil else: call[].dispatchScope
  var props = initOrderedTable[string, Value]()
  props["status"] = newInt(302)
  var headers = initOrderedTable[string, Value]()
  headers["location"] = args[0]
  props["headers"] = newMap(headers)
  let head = httpNamespaceBinding(scope, "Response")
  newNode(if head.kind == vkType: head else: newSym("Response"),
          props = props, body = @[newStr("")])


# --- os: environment, subprocess, and line input (docs/ai-agent.md §3,§6) ---
#
# Host authority is capability-gated exactly like Fs/Net: `os/get-env` needs an
# `Os/Env` value and `os/exec` needs `Os/Exec`, so a launcher can hand out
# env+file access without shell access. Errors are the typed `OsError`.

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

proc biOsReadLine(args: openArray[Value]): Value {.nimcall.} =
  ## Read one line from stdin; returns nil at EOF. No capability: reading the
  ## program's own stdin is not host authority the way env/exec/files are.
  if args.len != 0:
    raise newException(GeneError, "os/read-line takes no arguments")
  try:
    newStr(stdin.readLine())
  except EOFError:
    NIL

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
  httpScope.define("serve", newNativeCallFn("http/serve", biHttpServe))
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
  osScope.define("read-line", newNativeFn("os/read-line", biOsReadLine))
  osScope.define("OsError", osError)
  root.define("os", newNamespace("os", osScope))

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
