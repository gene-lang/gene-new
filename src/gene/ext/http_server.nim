# --- net/http event-loop server (docs/stdlib.md) ---
#
# Included by stdlib.nim (which is included by vm.nim), so this file may use
# VM internals directly: fibers, the non-sleeping scheduler probes, actor
# mailboxes, and ReplyTo. Dispatch models:
#
#   task_per_request (default) — each parsed request runs the handler as a
#     scheduler fiber settling a pending Task; a handler that sleeps/awaits
#     parks without stalling other connections.
#   actor_pool (explicit)      — requests become RequestMsg values dispatched
#     round-robin to a fixed pool of worker actors with bounded mailboxes and
#     native-created ReplyTo; full mailboxes answer 503.

const httpMaxBodyBytes = 10 * 1024 * 1024
const httpStreamBodyMaxBytes = 64 * 1024 * 1024
const httpMaxHeaderLines = 128
const httpMaxHeaderBytes = 32 * 1024
const httpRecvTimeoutMs = 10_000
const httpReadChunkBytes = 8 * 1024
const httpMaxChunkLineBytes = 4096
const httpDefaultRequestTimeoutMs = 30_000
const httpDefaultMaxConnections = 1024
const httpDefaultMaxInFlight = 256
const httpDefaultDrainTimeoutMs = 5_000
const httpDefaultPoolWorkers = 4
const httpDefaultPoolMailbox = 64
const wsAcceptGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
const wsMaxClientFrameBytes = 1024 * 1024
const wsOutboundQueueFrames = 256    # per-connection; ws_send drops oldest
const wsPingIntervalMs = 30_000
const wsPongGraceMs = 45_000

let HttpRuntimeLogger = newRuntimeLogger("gene/http")

proc httpNamespaceBinding(scope: Scope, name: string): Value =
  let app = if scope != nil: scope.application() else: currentApplication()
  let source = if app.stdlib != nil: app.stdlib else: app.builtinsScope()
  let netNs = source.vars.getOrDefault("net", VOID)
  if netNs.kind != vkNamespace:
    return VOID
  let httpNs = netNs.nsScope.vars.getOrDefault("http", VOID)
  if httpNs.kind != vkNamespace:
    return VOID
  httpNs.nsScope.vars.getOrDefault(name, VOID)

proc raiseHttpError(message: string, scope: Scope) =
  var props = initPropTable()
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
  of 408: "Request Timeout"
  of 413: "Payload Too Large"
  of 500: "Internal Server Error"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  else: "Status " & $code

proc newHttpResponseValue(scope: Scope, status: int, body: string,
                          contentType: string): Value =
  var props = initPropTable()
  props["status"] = newInt(status)
  var headers = initPropTable()
  headers["content-type"] = newStr(contentType)
  props["headers"] = newMap(headers)
  let head = httpNamespaceBinding(scope, "Response")
  newNode(if head.kind == vkType: head else: newSym("Response"),
          props = props, body = @[newStr(body)])

proc httpWirePayload(status: int, body: string,
                     headers: OrderedTable[string, string]): string =
  ## Serialize one HTTP/1.1 response. Always `connection: close` in this MVP.
  result = "HTTP/1.1 " & $status & " " & httpStatusText(status) & "\r\n"
  var hasContentType = false
  for key, val in headers:
    if key.contains({'\r', '\n'}) or val.contains({'\r', '\n'}):
      continue   # never let handler data split the response
    if key.toLowerAscii() == "content-type":
      hasContentType = true
    result.add key & ": " & val & "\r\n"
  if not hasContentType:
    result.add "content-type: text/html; charset=utf-8\r\n"
  result.add "content-length: " & $body.len & "\r\n"
  result.add "connection: close\r\n\r\n"
  result.add body

proc simpleHttpWirePayload(status: int, body: string): string =
  httpWirePayload(status, body, initOrderedTable[string, string]())

type
  HttpParseStatus = enum
    hpsNeedMore   # incomplete request; keep reading
    hpsDone       # request parsed into a Request node
    hpsBad        # malformed request; caller answers 400 and closes
    hpsTooLarge   # declared body exceeds the limit; caller answers 413

  HttpParseResult = tuple[status: HttpParseStatus, value: Value,
                          bodyStart, contentLength: int, chunked: bool]

proc parseHttpRequestBuffer(buf: string, maxBodyBytes: int, scope: Scope,
                            headersOnly = false): HttpParseResult =
  ## Incremental HTTP/1.1 request parser over a connection's accumulated
  ## bytes. Same validation rules as the previous blocking socket parser:
  ## bounded header lines/bytes, bounded content-length body, malformed
  ## requests answer 400. Strict `\r\n` line endings (what real clients send).
  let headerEnd = buf.find("\r\n\r\n")
  if headerEnd < 0:
    if buf.len > httpMaxHeaderBytes:
      return (hpsBad, VOID, 0, 0, false)
    return (hpsNeedMore, VOID, 0, 0, false)
  if headerEnd > httpMaxHeaderBytes:
    return (hpsBad, VOID, 0, 0, false)
  let lines = buf[0 ..< headerEnd].split("\r\n")
  if lines.len == 0 or lines.len - 1 > httpMaxHeaderLines:
    return (hpsBad, VOID, 0, 0, false)
  let lineParts = lines[0].split(' ')
  if lineParts.len != 3 or not lineParts[2].startsWith("HTTP/"):
    return (hpsBad, VOID, 0, 0, false)
  let httpMethod = lineParts[0]
  let target = lineParts[1]
  var path = target
  var query = ""
  let qMark = target.find('?')
  if qMark >= 0:
    path = target[0 ..< qMark]
    query = target[qMark + 1 .. ^1]
  var headers = initPropTable()
  var contentLength = 0
  var transferEncoding = ""
  for i in 1 ..< lines.len:
    let line = lines[i]
    let colon = line.find(':')
    if colon <= 0:
      return (hpsBad, VOID, 0, 0, false)
    let key = line[0 ..< colon].strip().toLowerAscii()
    let val = line[colon + 1 .. ^1].strip()
    if key == "transfer-encoding":
      if headers.hasKey(key):
        return (hpsBad, VOID, 0, 0, false)
      transferEncoding = val.toLowerAscii()
    if key == "content-length" and headers.hasKey(key):
      return (hpsBad, VOID, 0, 0, false)
    headers[key] = newStr(val)
    if key == "content-length":
      try:
        contentLength = parseInt(val)
      except ValueError:
        return (hpsBad, VOID, 0, 0, false)
      if contentLength < 0:
        return (hpsBad, VOID, 0, 0, false)
  let chunked = transferEncoding == "chunked"
  if transferEncoding.len > 0 and
      (not headersOnly or not chunked or headers.hasKey("content-length")):
    return (hpsBad, VOID, 0, 0, false)
  if maxBodyBytes >= 0 and contentLength > maxBodyBytes:
    return (hpsTooLarge, VOID, 0, 0, false)
  let bodyStart = headerEnd + 4
  if not headersOnly and buf.len < bodyStart + contentLength:
    return (hpsNeedMore, VOID, 0, 0, false)
  let body = if headersOnly: "" else: buf[bodyStart ..< bodyStart + contentLength]
  var params: PropTable
  try:
    params = parseQueryEntries(query, scope)
  except GeneError:
    return (hpsBad, VOID, 0, 0, false)
  var props = initPropTable()
  props["method"] = newStr(httpMethod)
  props["path"] = newStr(path)
  props["query"] = newStr(query)
  props["params"] = newMap(params)
  props["headers"] = newMap(headers)
  props["body"] = newStr(body)
  let head = httpNamespaceBinding(scope,
    if headersOnly: "StreamRequest" else: "Request")
  (hpsDone, newNode(if head.kind == vkType: head
                    else: newSym(if headersOnly: "StreamRequest" else: "Request"),
                    props = props), bodyStart, contentLength, chunked)

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

type HttpStreamWire = object
  status: int
  headers: string
  reader: Value
  knownLength: int
  maxBytes: int
  ownReader: bool

proc streamResponseWire(resp: Value, scope: Scope): HttpStreamWire =
  if resp.kind != vkNode or resp.head.bits !=
      httpNamespaceBinding(scope, "StreamResponse").bits:
    raiseHttpError("stream response must be a StreamResponse", scope)
  let props = resp.props
  if not props.hasKey("status") or not props.hasKey("headers") or
      not props.hasKey("body") or not props.hasKey("max_bytes") or
      not props.hasKey("own_reader"):
    raiseHttpError("StreamResponse is missing required fields", scope)
  result.status = int(requireInt64("StreamResponse status", props["status"]))
  if result.status < 200 or result.status > 599 or
      result.status in [204, 205, 304]:
    raiseHttpError("StreamResponse status must permit a body", scope)
  result.reader = props["body"]
  let ioScope = scope.application().stdlib.vars["io"].nsScope
  if not scope.typeImplementsProtocol(projectHead(result.reader),
                                      ioScope.vars["AsyncReader"]):
    raiseHttpError("StreamResponse body must implement AsyncReader", scope)
  result.maxBytes = int(requireInt64("StreamResponse max_bytes",
                                     props["max_bytes"]))
  result.knownLength = -1
  if props.hasKey("content_length"):
    result.knownLength = int(requireInt64("StreamResponse content_length",
                                             props["content_length"]))
  if result.maxBytes < 1 or result.maxBytes > 1_073_741_824 or
      result.knownLength < -1 or result.knownLength > result.maxBytes:
    raiseHttpError("StreamResponse byte limits are invalid", scope)
  if props["own_reader"].kind != vkBool:
    raiseHttpError("StreamResponse own_reader must be Bool", scope)
  result.ownReader = props["own_reader"].boolVal
  if result.ownReader and not scope.typeImplementsProtocol(
      projectHead(result.reader), ioScope.vars["IoResource"]):
    raiseHttpError("owned StreamResponse body must implement IoResource", scope)
  let headers = props["headers"]
  if headers.kind != vkMap or headers.mapEntries.len > 256:
    raiseHttpError("StreamResponse headers must be a bounded Map", scope)
  result.headers = "HTTP/1.1 " & $result.status & " " &
    httpStatusText(result.status) & "\r\n"
  var hasContentType = false
  for key, value in headers.mapEntries:
    if value.kind != vkString:
      raiseHttpError("StreamResponse header values must be Str", scope)
    let lower = key.toLowerAscii()
    if lower in ["content-length", "transfer-encoding", "connection"] or
        key.len == 0 or key.contains({'\r', '\n'}) or
        value.strVal.contains({'\r', '\n'}):
      raiseHttpError("StreamResponse header is invalid or reserved", scope)
    for ch in key:
      if not (ch in {'A'..'Z', 'a'..'z', '0'..'9'} or
              ch in "!#$%&'*+-.^_`|~"):
        raiseHttpError("StreamResponse header name is invalid", scope)
    for ch in value.strVal:
      if ch == '\x7f' or (ch < ' ' and ch != '\t'):
        raiseHttpError("StreamResponse header value is invalid", scope)
    if lower == "content-type": hasContentType = true
    result.headers.add key & ": " & value.strVal & "\r\n"
    if result.headers.len > 256 * 1024:
      raiseHttpError("StreamResponse headers exceed 256 KiB", scope)
  if not hasContentType:
    result.headers.add "content-type: application/octet-stream\r\n"
  if result.knownLength >= 0:
    result.headers.add "content-length: " & $result.knownLength & "\r\n"
  else:
    result.headers.add "transfer-encoding: chunked\r\n"
  result.headers.add "connection: close\r\n\r\n"
  if result.headers.len > 256 * 1024:
    raiseHttpError("StreamResponse headers exceed 256 KiB", scope)

# --- server runtime registry: listen / stop / status -----------------------
#
# A Server value carries a `^listener Int` handle into this registry so that
# handlers (which receive no server reference of their own) can reach the
# running server through the same Server node the application holds.

type
  HttpTlsAbiProc = proc(): cint {.cdecl.}
  HttpTlsServerOpenProc = proc(cert, key, clientCa: cstring,
                               requireClient: cint): pointer {.cdecl.}
  HttpTlsServerCloseProc = proc(server: pointer) {.cdecl.}
  HttpTlsConnOpenProc = proc(server: pointer, fd: cint): pointer {.cdecl.}
  HttpTlsHandshakeProc = proc(connection: pointer): cint {.cdecl.}
  HttpTlsReadProc = proc(connection, output: pointer, capacity: csize_t,
                          produced: ptr csize_t): cint {.cdecl.}
  HttpTlsPendingProc = proc(connection: pointer): cint {.cdecl.}
  HttpTlsWriteProc = proc(connection, input: pointer, length: csize_t,
                           consumed: ptr csize_t): cint {.cdecl.}
  HttpTlsConnCloseProc = proc(connection: pointer) {.cdecl.}
  HttpTlsLastErrorProc = proc(): cstring {.cdecl.}
  HttpTlsReloadStartProc = proc(server: pointer, cert, key, clientCa: cstring,
                                requireClient: cint): pointer {.cdecl.}
  HttpTlsReloadPollProc = proc(job: pointer): cint {.cdecl.}
  HttpTlsReloadCancelProc = proc(job: pointer) {.cdecl.}
  HttpTlsReloadErrorProc = proc(job: pointer): cstring {.cdecl.}
  HttpTlsReloadReleaseProc = proc(job: pointer) {.cdecl.}

  HttpTlsNative = ref object
    image: LibHandle
    lease: Value
    openServer: HttpTlsServerOpenProc
    closeServer: HttpTlsServerCloseProc
    openConnection: HttpTlsConnOpenProc
    handshake: HttpTlsHandshakeProc
    read: HttpTlsReadProc
    pending: HttpTlsPendingProc
    hasPending: HttpTlsPendingProc
    write: HttpTlsWriteProc
    closeConnection: HttpTlsConnCloseProc
    lastError: HttpTlsLastErrorProc
    reloadStart: HttpTlsReloadStartProc
    reloadPoll: HttpTlsReloadPollProc
    reloadCancel: HttpTlsReloadCancelProc
    reloadError: HttpTlsReloadErrorProc
    reloadRelease: HttpTlsReloadReleaseProc

  HttpTlsReloadPending = ref object
    native: HttpTlsNative
    job: pointer
    task: Value
    scheduler: SchedulerState

  HttpServerRuntime = ref object
    id: int
    host: string
    port: int
    listener: Socket
    tls: HttpTlsNative
    tlsServer: pointer
    listening: bool         # listener socket is live
    serving: bool           # event loop currently running
    stopRequested: bool
    workers: int            # actor_pool size (0 for task_per_request)
    # status counters
    acceptedConnections: int
    completedRequests: int  # responses produced from handler results
    failedRequests: int     # 500 responses (handler error/panic)
    overloadedRequests: int # 503 responses
    timeouts: int           # 504 and 408 responses
    badRequests: int        # 400 responses
    activeConnections: int
    inFlight: int
    bytesRead: int
    bytesWritten: int
    # Serve-loop timing, to attribute a late tick. Work runs from one select's
    # return to the next select (wall time and root-thread CPU time); overrun
    # is how far a select returned past its requested timeout. The loop keeps
    # the latest iteration's values and the maxima.
    loopWorkMs: int
    loopWorkCpuMs: int
    waitOverrunMs: int
    pendingCleanupTasks: int # close tasks the serve loop has not pruned yet
    maxLoopWorkMs: int
    maxWaitOverrunMs: int
    # RFC 6455 delivery (slice C9). ws_send runs outside the serve closure,
    # so open sockets and their bounded outbound frame queues live on the
    # registered runtime; the loop drains the queues between event batches.
    wsOpen: Table[int, bool]
    wsOutbound: Table[int, seq[string]]
    wsCloseRequested: Table[int, bool]
    # Bytes already moved onto a socket's write buffer and not yet accepted by
    # the kernel. With the frames still in `wsOutbound`, this is what
    # `ws_queued` reports: how far a peer has fallen behind.
    wsPending: Table[int, int]

var gHttpServerRegistry = initTable[int, HttpServerRuntime]()
var gHttpServerNextId = 0
var gHttpTlsImages: seq[LibHandle] # release shims remain mapped through exit
var gHttpTlsReloadPending: seq[HttpTlsReloadPending]
var gHttpTlsReloadLock: Lock
initLock(gHttpTlsReloadLock)

proc httpTlsPath(scope: Scope, path: string): string =
  if isAbsolute(path): normalizedPath(path)
  else: normalizedPath(scope.application().launchDir / path)

proc httpTlsConfig(value: Value, scope: Scope):
    tuple[cert, key, clientCa: string, required: bool] =
  if value.kind != vkMap:
    raiseHttpError("listen ^tls requires a Map", scope)
  let fields = value.mapEntries
  for name in fields.keys:
    if name notin ["cert_file", "key_file", "client_ca_file", "client_auth"]:
      raiseHttpError("listen ^tls has unexpected field: " & name, scope)
  if not fields.hasKey("cert_file") or not fields.hasKey("key_file") or
      fields["cert_file"].kind != vkString or
      fields["key_file"].kind != vkString or
      fields["cert_file"].strVal.len == 0 or
      fields["key_file"].strVal.len == 0:
    raiseHttpError("listen ^tls needs cert_file and key_file Str", scope)
  result.cert = httpTlsPath(scope, fields["cert_file"].strVal)
  result.key = httpTlsPath(scope, fields["key_file"].strVal)
  if fields.hasKey("client_ca_file") and fields["client_ca_file"].kind != vkNil:
    if fields["client_ca_file"].kind != vkString or
        fields["client_ca_file"].strVal.len == 0:
      raiseHttpError("listen ^tls client_ca_file must be a path Str", scope)
    result.clientCa = httpTlsPath(scope, fields["client_ca_file"].strVal)
  if fields.hasKey("client_auth"):
    if fields["client_auth"].kind != vkString or
        fields["client_auth"].strVal notin ["none", "required"]:
      raiseHttpError("listen ^tls client_auth must be none or required", scope)
    result.required = fields["client_auth"].strVal == "required"
  if result.required and result.clientCa.len == 0:
    raiseHttpError("listen ^tls required client_auth needs client_ca_file", scope)

proc loadHttpTls(scope: Scope): HttpTlsNative =
  var owner: Value
  if scope == nil or not scope.lookupOptional("this_pkg", owner):
    raiseHttpError("direct TLS requires a package with genex/tls dependency alias tls",
                   scope)
  var nativeCall = NativeCall(dispatchScope: scope)
  var dependency, lease: Value
  try:
    dependency = biPkgDependency([owner, newStr("tls")], addr nativeCall)
    lease = biPkgNativeBinary([dependency, newStr("native")], addr nativeCall)
    let path = biMaterializedPath([lease], addr nativeCall).strVal
    let image = loadLib(path)
    if image == nil:
      raiseHttpError("cannot load declared TLS native binary", scope)
    result = HttpTlsNative(image: image, lease: lease,
      openServer: cast[HttpTlsServerOpenProc](symAddr(image,
        "gene_tls_server_open")),
      closeServer: cast[HttpTlsServerCloseProc](symAddr(image,
        "gene_tls_server_close")),
      openConnection: cast[HttpTlsConnOpenProc](symAddr(image,
        "gene_tls_connection_open")),
      handshake: cast[HttpTlsHandshakeProc](symAddr(image,
        "gene_tls_connection_handshake")),
      read: cast[HttpTlsReadProc](symAddr(image,
        "gene_tls_connection_read")),
      pending: cast[HttpTlsPendingProc](symAddr(image,
        "gene_tls_connection_pending")),
      hasPending: cast[HttpTlsPendingProc](symAddr(image,
        "gene_tls_connection_has_pending")),
      write: cast[HttpTlsWriteProc](symAddr(image,
        "gene_tls_connection_write")),
      closeConnection: cast[HttpTlsConnCloseProc](symAddr(image,
        "gene_tls_connection_close")),
      lastError: cast[HttpTlsLastErrorProc](symAddr(image,
        "gene_tls_last_error")),
      reloadStart: cast[HttpTlsReloadStartProc](symAddr(image,
        "gene_tls_reload_start")),
      reloadPoll: cast[HttpTlsReloadPollProc](symAddr(image,
        "gene_tls_reload_poll")),
      reloadCancel: cast[HttpTlsReloadCancelProc](symAddr(image,
        "gene_tls_reload_cancel")),
      reloadError: cast[HttpTlsReloadErrorProc](symAddr(image,
        "gene_tls_reload_error")),
      reloadRelease: cast[HttpTlsReloadReleaseProc](symAddr(image,
        "gene_tls_reload_release")))
    let abi = cast[HttpTlsAbiProc](symAddr(image, "gene_tls_abi"))
    if abi == nil or abi() != 1 or result.openServer == nil or
        result.closeServer == nil or result.openConnection == nil or
        result.handshake == nil or result.read == nil or result.pending == nil or
        result.hasPending == nil or
        result.write == nil or
        result.closeConnection == nil or result.lastError == nil or
        result.reloadStart == nil or result.reloadPoll == nil or
        result.reloadCancel == nil or result.reloadError == nil or
        result.reloadRelease == nil:
      unloadLib(image)
      raiseHttpError("TLS native adapter ABI is missing or incompatible", scope)
    gHttpTlsImages.add image
  except CatchableError as error:
    raiseHttpError("direct TLS needs declared genex/tls native recipe: " &
                   error.msg, scope)

proc httpRuntimeFor(serverVal: Value): HttpServerRuntime =
  ## The registered runtime behind a Server value, or nil.
  if serverVal.kind != vkNode:
    return nil
  let props = serverVal.props
  if not props.hasKey("listener"):
    return nil
  let idVal = props["listener"]
  if idVal.kind != vkInt:
    return nil
  gHttpServerRegistry.getOrDefault(int(idVal.intVal), nil)

proc httpServerHostPort(args: openArray[Value], call: ptr NativeCall,
                        where: string, scope: Scope):
    tuple[host: string, port: int] =
  ## host/port from a Server node argument or from ^host/^port named args.
  result.host = "127.0.0.1"
  result.port = -1
  if args.len >= 1:
    if args[0].kind != vkNode or not args[0].props.hasKey("port"):
      raiseHttpError(where & " expects a Server value with ^host and ^port",
                     scope)
    let props = args[0].props
    if props.hasKey("host"):
      requireStr("Server host", props["host"])
      result.host = props["host"].strVal
    result.port = int(requireInt64("Server port", props["port"]))
  else:
    let hostIndex = nativeNamedIndex(call, "host")
    if hostIndex >= 0:
      requireStr(where & " host", call[].namedValues[hostIndex])
      result.host = call[].namedValues[hostIndex].strVal
    let portIndex = nativeNamedIndex(call, "port")
    if portIndex < 0:
      raiseHttpError(where & " requires ^port", scope)
    result.port = int(requireInt64(where & " port",
                                   call[].namedValues[portIndex]))
  if result.port < 0 or result.port > 65535:
    raiseHttpError("Server port out of range: " & $result.port, scope)

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc httpSetNonBlocking(fd: cint) =
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  proc httpBindListener(host: string, port: int, scope: Scope): Socket =
    result = newSocket()
    try:
      result.setSockOpt(OptReuseAddr, true)
      result.bindAddr(Port(port), host)
      result.listen()
    except OSError as e:
      result.close()
      raiseHttpError("failed to listen on " & host & ":" & $port & ": " &
                     e.msg, scope)
    # Non-blocking listener: the event loop must never park in the kernel
    # while handler fibers are runnable or timers are due.
    httpSetNonBlocking(result.getFd().cint)

proc registerHttpRuntime(host: string, port: int, listener: Socket,
                         listening: bool, tls: HttpTlsNative = nil,
                         tlsServer: pointer = nil): HttpServerRuntime =
  inc gHttpServerNextId
  result = HttpServerRuntime(id: gHttpServerNextId, host: host, port: port,
                             listener: listener, listening: listening,
                             tls: tls, tlsServer: tlsServer)
  gHttpServerRegistry[result.id] = result

proc dropHttpRuntime(rt: HttpServerRuntime) =
  if rt == nil:
    return
  if rt.listening:
    rt.listener.close()
    rt.listening = false
  if rt.tlsServer != nil:
    rt.tls.closeServer(rt.tlsServer)
    rt.tlsServer = nil
  rt.tls = nil
  gHttpServerRegistry.del(rt.id)

proc biHttpListen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (listen ^host "0.0.0.0" ^port 8080) or (listen server) — bind a listener
  ## now and return a Server value carrying the runtime handle. The returned
  ## value works with serve/stop/status; binding eagerly makes the listener a
  ## value the application explicitly owns.
  if args.len > 1:
    raise newException(GeneError,
      "http/listen expects at most one Server argument")
  let scope = if call == nil: nil else: call[].dispatchScope
  if call != nil:
    for name in call[].namedNames:
      if name notin ["host", "port", "tls"]:
        raise newException(GeneError,
          "http/listen got unexpected named argument: " & name)
  let (host, port) = httpServerHostPort(args, call, "http/listen", scope)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var tlsConfig: Value = NIL
    if args.len == 1 and args[0].props.hasKey("tls"):
      tlsConfig = args[0].props["tls"]
    let tlsIndex = nativeNamedIndex(call, "tls")
    if tlsIndex >= 0:
      if tlsConfig.kind != vkNil:
        raiseHttpError("listen ^tls is specified twice", scope)
      tlsConfig = call[].namedValues[tlsIndex]
    var tls: HttpTlsNative
    var tlsServer: pointer
    if tlsConfig.kind != vkNil:
      let config = httpTlsConfig(tlsConfig, scope)
      tls = loadHttpTls(scope)
      tlsServer = tls.openServer(config.cert.cstring, config.key.cstring,
        if config.clientCa.len == 0: nil else: config.clientCa.cstring,
        if config.required: 1 else: 0)
      if tlsServer == nil:
        raiseHttpError("TLS material validation failed: " &
          $tls.lastError(), scope)
    var listener: Socket
    try:
      listener = httpBindListener(host, port, scope)
    except CatchableError:
      if tlsServer != nil: tls.closeServer(tlsServer)
      raise
    let rt = registerHttpRuntime(host, port, listener, listening = true,
                                 tls = tls, tlsServer = tlsServer)
    var props = initPropTable()
    props["host"] = newStr(host)
    props["port"] = newInt(port)
    props["listener"] = newInt(rt.id)
    let head = httpNamespaceBinding(scope, "Server")
    let server = newNode(if head.kind == vkType: head else: newSym("Server"),
                         props = props)
    server
  else:
    raiseHttpError("http/listen requires a native posix build", scope)
    NIL

proc biHttpStop(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (stop server) — request a graceful stop: the serve loop stops accepting,
  ## drains in-flight requests up to ^drain_timeout_ms, then returns. Valid on
  ## a Server value produced by listen (before or during serve).
  requireOne("http/stop", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  let rt = httpRuntimeFor(args[0])
  if rt == nil:
    raiseHttpError("http/stop expects a Server value from http/listen", scope)
  rt.stopRequested = true
  if not rt.serving:
    dropHttpRuntime(rt)
  NIL

proc biHttpStatus(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (status server) — diagnostics snapshot of a listening/serving server.
  requireOne("http/status", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  let rt = httpRuntimeFor(args[0])
  if rt == nil:
    raiseHttpError("http/status expects a Server value from http/listen",
                   scope)
  var props = initPropTable()
  props["host"] = newStr(rt.host)
  props["port"] = newInt(rt.port)
  props["serving"] = newBool(rt.serving)
  props["stopping"] = newBool(rt.stopRequested)
  props["workers"] = newInt(rt.workers)
  props["active_connections"] = newInt(rt.activeConnections)
  props["in_flight_requests"] = newInt(rt.inFlight)
  props["pending_cleanup_tasks"] = newInt(rt.pendingCleanupTasks)
  props["accepted_connections"] = newInt(rt.acceptedConnections)
  props["completed_requests"] = newInt(rt.completedRequests)
  props["failed_requests"] = newInt(rt.failedRequests)
  props["overloaded_requests"] = newInt(rt.overloadedRequests)
  props["timeouts"] = newInt(rt.timeouts)
  props["bad_requests"] = newInt(rt.badRequests)
  props["bytes_read"] = newInt(rt.bytesRead)
  props["bytes_written"] = newInt(rt.bytesWritten)
  props["loop_work_ms"] = newInt(rt.loopWorkMs)
  props["loop_work_cpu_ms"] = newInt(rt.loopWorkCpuMs)
  props["wait_overrun_ms"] = newInt(rt.waitOverrunMs)
  props["max_loop_work_ms"] = newInt(rt.maxLoopWorkMs)
  props["max_wait_overrun_ms"] = newInt(rt.maxWaitOverrunMs)
  newNode(newSym("Status"), props = props)

proc pollHttpTlsReloadCompletions() =
  withLock gHttpTlsReloadLock:
    var i = 0
    while i < gHttpTlsReloadPending.len:
      let pending = gHttpTlsReloadPending[i]
      if pending.scheduler != currentScheduler():
        inc i
        continue
      if pending.task.taskCancelled or pending.task.taskCancelRequested:
        pending.native.reloadCancel(pending.job)
      let status = pending.native.reloadPoll(pending.job)
      if status == 0:
        inc i
        continue
      if not pending.task.taskCancelled:
        if status == 1:
          if tryCompleteTask(pending.task, NIL):
            wakeTaskWaitersIn(pending.scheduler, pending.task)
        else:
          let message = $pending.native.reloadError(pending.job)
          if tryFailTask(pending.task,
              if message.len > 0: "TLS reload failed: " & message
              else: "TLS reload failed"):
            wakeTaskWaitersIn(pending.scheduler, pending.task)
      pending.native.reloadRelease(pending.job)
      gHttpTlsReloadPending.delete(i)

proc biHttpReloadTls(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 2:
    raiseHttpError("Server.reload_tls expects a TLS config Map", scope)
  let rt = httpRuntimeFor(args[0])
  if rt == nil or rt.tlsServer == nil or rt.stopRequested:
    raiseHttpError("Server.reload_tls requires a live TLS listener", scope)
  let config = httpTlsConfig(args[1], scope)
  let job = rt.tls.reloadStart(rt.tlsServer, config.cert.cstring,
    config.key.cstring,
    if config.clientCa.len == 0: nil else: config.clientCa.cstring,
    if config.required: 1 else: 0)
  if job == nil:
    raiseHttpError("TLS reload worker is unavailable", scope)
  let task = newExternalTask()
  let pending = HttpTlsReloadPending(native: rt.tls, job: job,
    task: retainedCopy(task), scheduler: schedulerForScope(scope))
  withLock gHttpTlsReloadLock:
    gHttpTlsReloadPending.add pending
  task

# --- routes and dispatch configuration --------------------------------------

proc biHttpRoute(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (route ^method "GET" ^path "/" ^handler home) — canonical route entry.
  if args.len != 0:
    raise newException(GeneError,
      "http/route expects named arguments only (^method ^path ^handler)")
  var methodVal = newStr("GET")
  var pathVal = NIL
  var handlerVal = NIL
  if call != nil:
    for name in call[].namedNames:
      if name notin ["method", "path", "handler"]:
        raise newException(GeneError,
          "http/route got unexpected named argument: " & name)
    let mIndex = nativeNamedIndex(call, "method")
    if mIndex >= 0:
      requireStr("http/route method", call[].namedValues[mIndex])
      methodVal = call[].namedValues[mIndex]
    let pIndex = nativeNamedIndex(call, "path")
    if pIndex >= 0:
      requireStr("http/route path", call[].namedValues[pIndex])
      pathVal = call[].namedValues[pIndex]
    let hIndex = nativeNamedIndex(call, "handler")
    if hIndex >= 0:
      handlerVal = call[].namedValues[hIndex]
  if pathVal.kind == vkNil or handlerVal.kind == vkNil:
    raise newException(GeneError, "http/route requires ^path and ^handler")
  var props = initPropTable()
  props["method"] = methodVal
  props["path"] = pathVal
  props["handler"] = handlerVal
  newNode(newSym("Route"), props = props)

proc biHttpActorPool(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (actor_pool ^workers 8 ^mailbox 64 ^init make-state ^handle worker-fn)
  ## — dispatch-mode configuration for serve's ^dispatch.
  if args.len != 0:
    raise newException(GeneError,
      "http/actor_pool expects named arguments only")
  var workers = httpDefaultPoolWorkers
  var mailbox = httpDefaultPoolMailbox
  var initFn = NIL
  var handleFn = NIL
  if call != nil:
    for name in call[].namedNames:
      if name notin ["workers", "mailbox", "init", "handle"]:
        raise newException(GeneError,
          "http/actor_pool got unexpected named argument: " & name)
    let wIndex = nativeNamedIndex(call, "workers")
    if wIndex >= 0:
      workers = int(requireInt64("http/actor_pool workers",
                                 call[].namedValues[wIndex]))
    let mIndex = nativeNamedIndex(call, "mailbox")
    if mIndex >= 0:
      mailbox = int(requireInt64("http/actor_pool mailbox",
                                 call[].namedValues[mIndex]))
    let iIndex = nativeNamedIndex(call, "init")
    if iIndex >= 0:
      initFn = call[].namedValues[iIndex]
    let hIndex = nativeNamedIndex(call, "handle")
    if hIndex >= 0:
      handleFn = call[].namedValues[hIndex]
  if workers < 1:
    raise newException(GeneError, "http/actor_pool workers must be >= 1")
  if mailbox < 1:
    raise newException(GeneError, "http/actor_pool mailbox must be >= 1")
  if initFn.kind == vkNil or handleFn.kind == vkNil:
    raise newException(GeneError,
      "http/actor_pool requires ^init and ^handle")
  var props = initPropTable()
  props["workers"] = newInt(workers)
  props["mailbox"] = newInt(mailbox)
  props["init"] = initFn
  props["handle"] = handleFn
  newNode(newSym("ActorPool"), props = props)

proc biHttpSupervisorPolicy(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (supervisor_policy ^strategy `restart ^max_restarts 10 ^within_ms 60000
  ##  ^events failures ^dead_letter dead) — worker-pool supervision
  ## configuration for serve's ^supervision (proposal §12). The server owns
  ## the supervision; this value only carries the policy.
  if args.len != 0:
    raise newException(GeneError,
      "http/supervisor_policy expects named arguments only")
  var strategy = "restart"
  var maxRestarts = 0
  var withinMs = 0
  var events = NIL
  var deadLetter = NIL
  if call != nil:
    for name in call[].namedNames:
      if name notin ["strategy", "max_restarts", "within_ms", "events",
                     "dead_letter"]:
        raise newException(GeneError,
          "http/supervisor_policy got unexpected named argument: " & name)
    let sIndex = nativeNamedIndex(call, "strategy")
    if sIndex >= 0:
      let sVal = call[].namedValues[sIndex]
      if sVal.kind == vkSymbol:
        strategy = sVal.symVal
      elif sVal.kind == vkString:
        strategy = sVal.strVal
      else:
        raise newException(GeneError,
          "http/supervisor_policy ^strategy must be a name")
    let mIndex = nativeNamedIndex(call, "max_restarts")
    if mIndex >= 0:
      maxRestarts = int(requireInt64("http/supervisor_policy max_restarts",
                                     call[].namedValues[mIndex]))
    let wIndex = nativeNamedIndex(call, "within_ms")
    if wIndex >= 0:
      withinMs = int(requireInt64("http/supervisor_policy within_ms",
                                  call[].namedValues[wIndex]))
    let eIndex = nativeNamedIndex(call, "events")
    if eIndex >= 0:
      events = call[].namedValues[eIndex]
      requireChannel("http/supervisor_policy ^events", events)
    let dIndex = nativeNamedIndex(call, "dead_letter")
    if dIndex >= 0:
      deadLetter = call[].namedValues[dIndex]
      requireChannel("http/supervisor_policy ^dead_letter", deadLetter)
  if strategy notin ["restart", "stop"]:
    raise newException(GeneError,
      "http/supervisor_policy ^strategy must be restart or stop")
  var props = initPropTable()
  props["strategy"] = newStr(strategy)
  props["max_restarts"] = newInt(maxRestarts)
  props["within_ms"] = newInt(withinMs)
  props["events"] = events
  props["dead_letter"] = deadLetter
  newNode(newSym("SupervisorPolicy"), props = props)

type
  HttpRouteSegment = object
    isParam: bool
    text: string             # literal segment text, or the capture name

  HttpRouteEntry = object
    methodS: string          # "*" matches any method
    path: string
    segments: seq[HttpRouteSegment]
    hasParams: bool          # ":name" segments present; else exact match
    handler: Value

proc httpCompileRoutePath(path: string): tuple[segments: seq[HttpRouteSegment],
                                               hasParams: bool] =
  ## Split a route path into segments; ":name" segments capture into
  ## req/params (proposal §6.1 route params). "/job/:id" has segments
  ## ["job", :id].
  for raw in path.split('/'):
    if raw.len == 0:
      continue   # leading slash / double slashes collapse
    if raw[0] == ':' and raw.len > 1:
      result.segments.add HttpRouteSegment(isParam: true, text: raw[1 .. ^1])
      result.hasParams = true
    else:
      result.segments.add HttpRouteSegment(isParam: false, text: raw)

proc httpAddRouteEntry(entries: var seq[HttpRouteEntry],
                       methodS, path: string, handler: Value) =
  let compiled = httpCompileRoutePath(path)
  entries.add HttpRouteEntry(methodS: methodS, path: path,
                             segments: compiled.segments,
                             hasParams: compiled.hasParams,
                             handler: handler)

proc httpParseRouteEntries(routes: Value, scope: Scope): seq[HttpRouteEntry] =
  if routes.kind != vkList:
    raiseHttpError("http/serve ^routes expects a List of route entries", scope)
  for entry in routes.listItems:
    if entry.kind == vkNode and entry.props.hasKey("path") and
        entry.props.hasKey("handler"):
      let m =
        if entry.props.hasKey("method"):
          requireStr("route method", entry.props["method"])
          entry.props["method"].strVal
        else:
          "*"
      requireStr("route path", entry.props["path"])
      httpAddRouteEntry(result, m, entry.props["path"].strVal,
                        entry.props["handler"])
    elif entry.kind == vkList and entry.listItems.len == 3:
      requireStr("route method", entry.listItems[0])
      requireStr("route path", entry.listItems[1])
      httpAddRouteEntry(result, entry.listItems[0].strVal,
                        entry.listItems[1].strVal, entry.listItems[2])
    else:
      raiseHttpError("route entries must be (route ^method ^path ^handler) " &
                     "nodes or [method path handler] lists", scope)

proc httpMatchRoute(entries: seq[HttpRouteEntry], request: Value):
    tuple[found: bool, handler: Value,
          params: seq[tuple[name, value: string]]] =
  ## First matching route wins; method "*" is a wildcard. Paths without
  ## ":name" segments match exactly; pattern paths match per segment and
  ## capture ":name" values for req/params.
  let props = request.props
  let methodS = props["method"].strVal
  let path = props["path"].strVal
  var pathSegments: seq[string]
  var split = false
  for entry in entries:
    if entry.methodS != "*" and entry.methodS != methodS:
      continue
    if not entry.hasParams:
      if entry.path == path:
        return (true, entry.handler, @[])
      continue
    if not split:
      for raw in path.split('/'):
        if raw.len != 0:
          pathSegments.add raw
      split = true
    if pathSegments.len != entry.segments.len:
      continue
    var ok = true
    var captured: seq[tuple[name, value: string]]
    for i, segment in entry.segments:
      if segment.isParam:
        captured.add (segment.text, pathSegments[i])
      elif segment.text != pathSegments[i]:
        ok = false
        break
    if ok:
      return (true, entry.handler, captured)
  (false, NIL, @[])

# --- request dispatch --------------------------------------------------------

type
  HttpActorPool = ref object
    workers: seq[Value]     # ActorRef values, round-robin
    cursor: int

proc dispatchHttpHandler(handler, request: Value, scope: Scope): Value =
  ## Run the handler for one request, task_per_request style. A plain Gene
  ## function becomes a scheduler fiber settling a pending Task (mirrors
  ## makeActorFiber/spawnFiber), so a handler that awaits/sleeps parks without
  ## stalling the server loop. Other callables (natives, generators) fall back
  ## to an inline call wrapped in a completed Task.
  if handler.kind == vkFunction and handler.fnCode != nil and
      handler.fnCode of FunctionProto:
    let proto = FunctionProto(handler.fnCode)
    if not proto.isGenerator:
      let bound = bindCallScope(handler, proto, [request], NamedArgs())
      let task = newPendingTask()
      enqueueRunnable(Fiber(chunk: proto.chunk, scope: bound.scope,
                            recycleScope: proto.poolCallScope,
                            task: task, actorOwner: NIL, started: false))
      return task
  newCompletedTask(applyCall(handler, [request], NamedArgs(), scope))

proc dispatchWsHandler(handler: Value, args: openArray[Value],
                       scope: Scope): Value =
  ## dispatchHttpHandler generalized to the WebSocket callback arities
  ## (on_open/on_close take the conn; on_message takes conn + text). The
  ## returned task is deliberately never read — delivery callbacks are
  ## fire-and-forget.
  if handler.kind == vkFunction and handler.fnCode != nil and
      handler.fnCode of FunctionProto:
    let proto = FunctionProto(handler.fnCode)
    if not proto.isGenerator:
      let bound = bindCallScope(handler, proto, args, NamedArgs())
      let task = newPendingTask()
      enqueueRunnable(Fiber(chunk: proto.chunk, scope: bound.scope,
                            recycleScope: proto.poolCallScope,
                            task: task, actorOwner: NIL, started: false))
      return task
  newCompletedTask(applyCall(handler, args, NamedArgs(), scope))

proc dispatchHttpToPool(pool: HttpActorPool, request: Value,
                        scope: Scope): tuple[task: Value, overloaded: bool] =
  ## Wrap the request in a RequestMsg with a native-created ReplyTo and
  ## try_send it round-robin across the pool. Every worker full => overload.
  ##
  ## The message intentionally bypasses checkedActorMessage's Send validation:
  ## Request values carry (mutable) header/param maps, and this native edge is
  ## the single producer handing each request to exactly one consumer. The
  ## worker lane still re-verifies sendability before moving any fiber off the
  ## scheduler thread (actorFiberWorkerSafe), so unsendable messages simply
  ## stay on the cooperative lane.
  let task = newPendingTask()
  # relaxedSend: Response values carry (mutable) header maps, so the reply
  # skips Send validation on this native single-producer edge — same
  # rationale as the request direction below.
  let reply = newReplyTo(task = task, relaxedSend = true)
  var props = initPropTable()
  props["req"] = request
  props["reply"] = reply
  let head = httpNamespaceBinding(scope, "RequestMsg")
  let msg = newNode(if head.kind == vkType: head else: newSym("RequestMsg"),
                    props = props)
  for _ in 0 ..< pool.workers.len:
    let worker = pool.workers[pool.cursor]
    pool.cursor = (pool.cursor + 1) mod pool.workers.len
    let pushed = tryPushActorMessage(worker, msg, reply)
    if pushed.pushed:
      scheduleActor(worker, scope)
      return (task, false)
  (NIL, true)

proc httpSpawnPool(config, policy: Value, scope: Scope): HttpActorPool =
  ## Spawn the worker actors for an actor_pool dispatch config. Workers
  ## default to restart supervision: a failed handler produces a failure
  ## event path via the actor runtime and the worker state is rebuilt with
  ## ^init. A ^supervision (supervisor_policy ...) value overrides the
  ## strategy and adds restart budget and failure-event/dead_letter channels
  ## (proposal §12).
  let props = config.props
  let workers = int(requireInt64("actor_pool workers", props["workers"]))
  let mailbox = int(requireInt64("actor_pool mailbox", props["mailbox"]))
  let initFn = props["init"]
  let handleFn = props["handle"]
  var failureStrategy = afsRestart
  var maxRestarts = 0
  var withinMs = 0
  var events = NIL
  var deadLetters = NIL
  if policy.kind != vkNil:
    let p = policy.props
    if p.hasKey("strategy") and p["strategy"].strVal == "stop":
      failureStrategy = afsStop
    if p.hasKey("max_restarts"):
      maxRestarts = int(p["max_restarts"].intVal)
    if p.hasKey("within_ms"):
      withinMs = int(p["within_ms"].intVal)
    if p.hasKey("events"):
      events = p["events"]
    if p.hasKey("dead_letter"):
      deadLetters = p["dead_letter"]
  let restartInit =
    if failureStrategy == afsRestart: initFn else: NIL
  result = HttpActorPool()
  for _ in 0 ..< workers:
    let state = applyCall(initFn, [], NamedArgs(), scope)
    result.workers.add newActorRef(mailbox, state, handleFn, NIL,
                                   restartInit = restartInit,
                                   failureStrategy = failureStrategy,
                                   failureEvents = events,
                                   failureDeadLetters = deadLetters,
                                   maxRestarts = maxRestarts,
                                   restartWindowMs = withinMs)

proc closeHttpPool(pool: HttpActorPool) =
  if pool == nil:
    return
  for worker in pool.workers:
    closeActorAndCancelMailbox(worker)

proc httpErrorFallbackNode(task: Value): Value =
  ## Error value for the ^on_error mapper: the task's error value when the
  ## handler failed with one, else an (Error ^message ...) node — the same
  ## shape catch clauses see for message-only errors.
  if task.taskHasErrorValue:
    return task.taskErrorValue
  var props = initPropTable()
  props["message"] = newStr(task.taskErrorMsg)
  newNode(newSym("Error"), props = props)

# --- the event loop ----------------------------------------------------------

type
  HttpConnPhase = enum
    hcpTlsHandshake  # TLS trust before any HTTP byte reaches the parser
    hcpReading      # accumulating request bytes
    hcpDispatched   # handler task in flight; response not yet started
    hcpWriting      # flushing response bytes
    hcpStreamingResponse # bounded AsyncReader response in progress
    hcpWebSocket    # upgraded; frames in both directions until close

  HttpChunkState = enum
    hcsSize, hcsData, hcsDataCr, hcsDataLf, hcsTrailer, hcsDone

  HttpBodyDecodeStatus = enum
    hbdNeedMore, hbdData, hbdDone, hbdBad, hbdTooLarge

  HttpConn = ref object
    sock: Socket
    fd: int
    tlsConnection: pointer
    tlsReadWantWrite, tlsWriteWantRead, tlsHandshakeWantWrite: bool
    tlsReadNeedsSocket: bool
    tlsPendingWriteLength: int
    phase: HttpConnPhase
    buf: string             # accumulated request bytes
    task: Value             # pending handler task; NIL after 504 orphaning
    inFlightCounted: bool
    streamingBody: bool
    bodyReader, bodyWriter, bodyWriteTask: Value
    bodyChunk: string
    bodyWriteOffset: int
    bodyRemaining: int
    bodyDone: bool
    bodyWaitingForSocket: bool
    bodyChunked: bool
    bodyRaw: string
    bodyRawPos: int
    chunkState: HttpChunkState
    chunkRemaining: int
    chunkLine: string
    chunkTrailerBytes: int
    chunkTrailerLines: int
    decodedBodyBytes: int
    readDeadline: MonoTime  # header/body arrival deadline (slowloris guard)
    taskDeadline: MonoTime  # handler completion deadline
    hasTaskDeadline: bool
    writeBuf: string
    writePos: int
    writeFailed: bool
    responseReader, responseReadTask, responseCloseTask: Value
    responseOwnReader: bool
    responseFromRequestBody: bool
    responseChunked: bool
    responseKnownLength, responseMaxBytes, responseSent: int
    responseFinalQueued: bool
    started: MonoTime       # accept time, for access_log latency
    reqMethod: string       # parsed request line, for logging ("" until
    reqPath: string         #   a request parses)
    reqHeaders: Value       # parsed headers map, for redacted logging
    # WebSocket state (set when an accepted upgrade finishes flushing)
    wsUpgrading: bool       # 101 handshake queued; enter WS mode after flush
    wsValue: Value          # Gene-visible WsConn node
    wsOnMessage: Value
    wsOnClose: Value
    wsOnOpen: Value
    wsCloseAfterFlush: bool # close frame queued; drop the socket once sent
    wsPingDeadline: MonoTime
    wsAwaitingPong: bool
    wsPongDeadline: MonoTime

proc decodeHttpBody(conn: HttpConn, maxBodyBytes: int): HttpBodyDecodeStatus =
  ## Consume only one decoded chunk at a time. The socket read buffer is at
  ## most httpReadChunkBytes; bodyChunk is handed to the bounded pipe before
  ## more network bytes are admitted.
  while true:
    if not conn.bodyChunked:
      if conn.bodyRemaining == 0:
        return hbdDone
      if conn.bodyRawPos >= conn.bodyRaw.len:
        conn.bodyRaw = ""
        conn.bodyRawPos = 0
        return hbdNeedMore
      let count = min(conn.bodyRemaining,
                      conn.bodyRaw.len - conn.bodyRawPos)
      conn.bodyChunk = conn.bodyRaw[conn.bodyRawPos ..<
                                     conn.bodyRawPos + count]
      conn.bodyRawPos += count
      conn.bodyRemaining -= count
      if conn.bodyRawPos == conn.bodyRaw.len:
        conn.bodyRaw = ""
        conn.bodyRawPos = 0
      return hbdData

    if conn.chunkState == hcsDone:
      return hbdDone
    if conn.bodyRawPos >= conn.bodyRaw.len:
      conn.bodyRaw = ""
      conn.bodyRawPos = 0
      return hbdNeedMore

    case conn.chunkState
    of hcsSize, hcsTrailer:
      let ch = conn.bodyRaw[conn.bodyRawPos]
      inc conn.bodyRawPos
      conn.chunkLine.add ch
      if conn.chunkLine.len > httpMaxChunkLineBytes or
          (ch < ' ' and ch notin {'\r', '\n', '\t'}):
        return hbdBad
      if ch == '\n':
        if conn.chunkLine.len < 2 or conn.chunkLine[^2] != '\r':
          return hbdBad
        let line = conn.chunkLine[0 ..< conn.chunkLine.len - 2]
        conn.chunkLine = ""
        if '\r' in line or '\n' in line:
          return hbdBad
        if conn.chunkState == hcsTrailer:
          conn.chunkTrailerBytes += line.len + 2
          inc conn.chunkTrailerLines
          if conn.chunkTrailerBytes > httpMaxHeaderBytes or
              conn.chunkTrailerLines > httpMaxHeaderLines:
            return hbdBad
          if line.len == 0:
            conn.chunkState = hcsDone
            return hbdDone
          if line.find(':') <= 0:
            return hbdBad
        else:
          let semicolon = line.find(';')
          let digits = (if semicolon < 0: line
                        else: line[0 ..< semicolon]).strip()
          if digits.len == 0 or digits.len > 16:
            return hbdBad
          var size = 0
          for digitChar in digits:
            let digit =
              if digitChar in {'0'..'9'}: ord(digitChar) - ord('0')
              elif digitChar in {'a'..'f'}: ord(digitChar) - ord('a') + 10
              elif digitChar in {'A'..'F'}: ord(digitChar) - ord('A') + 10
              else: return hbdBad
            if size > (high(int) - digit) div 16:
              return hbdBad
            size = size * 16 + digit
          if size > maxBodyBytes - conn.decodedBodyBytes:
            return hbdTooLarge
          conn.chunkRemaining = size
          conn.chunkState = if size == 0: hcsTrailer else: hcsData
    of hcsData:
      let count = min(conn.chunkRemaining,
                      conn.bodyRaw.len - conn.bodyRawPos)
      conn.bodyChunk = conn.bodyRaw[conn.bodyRawPos ..<
                                     conn.bodyRawPos + count]
      conn.bodyRawPos += count
      conn.chunkRemaining -= count
      conn.decodedBodyBytes += count
      if conn.chunkRemaining == 0:
        conn.chunkState = hcsDataCr
      if conn.bodyRawPos == conn.bodyRaw.len:
        conn.bodyRaw = ""
        conn.bodyRawPos = 0
      return hbdData
    of hcsDataCr:
      if conn.bodyRaw[conn.bodyRawPos] != '\r': return hbdBad
      inc conn.bodyRawPos
      conn.chunkState = hcsDataLf
    of hcsDataLf:
      if conn.bodyRaw[conn.bodyRawPos] != '\n': return hbdBad
      inc conn.bodyRawPos
      conn.chunkState = hcsSize
    of hcsDone:
      return hbdDone

# --- RFC 6455 WebSocket support (slice C9) -----------------------------------
#
# Delivery-only by design: the gateway pushes events/presence over frames;
# every mutation stays on the HTTP routes. A handler accepts an upgrade by
# returning (ws_accept req ^on_open f ...); the serve loop performs the
# handshake, keeps the socket, and drains per-connection bounded outbound
# queues (ws_send drops oldest frames and reports the drop count so the
# caller can surface a gap on that client's own stream only).
#
# **Text and binary, both directions.** `ws_send` takes a `Str` or a `Bytes`
# and picks the opcode from which it got; an inbound text frame reaches
# `on_message` as a `Str` and a binary one as `Bytes`. The frame codec below was
# always opcode-agnostic — `wsEncodeFrame` takes an opcode and
# `wsParseClientFrame` reports one — so this is a widening of the Gene-facing
# surface rather than of the protocol implementation.
#
# It was text-only until a caller needed otherwise, and the caller is
# `examples/miclone`: its §10 sends a 16 KB block of voxels per message and its
# §D7.3 is explicit that "16 KB of nodes should not become a node tree". Base64
# through a text frame would cost a third more bytes and two copies per message
# on the path that carries the most traffic in the system.
#
# One asymmetry worth knowing: a *browser* receives binary as an `ArrayBuffer`
# and text as a `string`, so the two are already distinguishable there. Here the
# distinction is the Gene value's kind, which is the same information carried
# the same way.

proc wsSha1Digest(data: string): array[20, byte] =
  ## Compact dependency-free SHA-1 for the handshake accept key only —
  ## RFC 6455 mandates it; nothing else in Gene uses SHA-1.
  var h: array[5, uint32] = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32,
                             0x10325476'u32, 0xC3D2E1F0'u32]
  var message = data
  let bitLen = uint64(data.len) * 8
  message.add char(0x80)
  while message.len mod 64 != 56:
    message.add char(0)
  for shift in countdown(7, 0):
    message.add char((bitLen shr (uint(shift) * 8)) and 0xFF)
  template rotl(value: uint32, amount: int): uint32 =
    (value shl amount) or (value shr (32 - amount))
  var w: array[80, uint32]
  var offset = 0
  while offset < message.len:
    for i in 0 ..< 16:
      w[i] = (uint32(message[offset + i * 4].ord) shl 24) or
             (uint32(message[offset + i * 4 + 1].ord) shl 16) or
             (uint32(message[offset + i * 4 + 2].ord) shl 8) or
             uint32(message[offset + i * 4 + 3].ord)
    for i in 16 ..< 80:
      w[i] = rotl(w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16], 1)
    var a = h[0]
    var b = h[1]
    var c = h[2]
    var d = h[3]
    var e = h[4]
    for i in 0 ..< 80:
      let (f, k) =
        if i < 20: ((b and c) or ((not b) and d), 0x5A827999'u32)
        elif i < 40: (b xor c xor d, 0x6ED9EBA1'u32)
        elif i < 60: ((b and c) or (b and d) or (c and d), 0x8F1BBCDC'u32)
        else: (b xor c xor d, 0xCA62C1D6'u32)
      let temp = rotl(a, 5) + f + e + k + w[i]
      e = d
      d = c
      c = rotl(b, 30)
      b = a
      a = temp
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    offset += 64
  for i in 0 ..< 5:
    result[i * 4] = byte((h[i] shr 24) and 0xFF)
    result[i * 4 + 1] = byte((h[i] shr 16) and 0xFF)
    result[i * 4 + 2] = byte((h[i] shr 8) and 0xFF)
    result[i * 4 + 3] = byte(h[i] and 0xFF)

proc wsAcceptKey(clientKey: string): string =
  let digest = wsSha1Digest(clientKey & wsAcceptGuid)
  var raw = newString(20)
  for i in 0 ..< 20:
    raw[i] = char(digest[i])
  base64.encode(raw)

proc wsEncodeFrame(opcode: byte, payload: string): string =
  ## Server frames are unmasked (RFC 6455 §5.1).
  result = newStringOfCap(payload.len + 10)
  result.add char(0x80'u8 or opcode)
  if payload.len < 126:
    result.add char(payload.len)
  elif payload.len < 65536:
    result.add char(126)
    result.add char((payload.len shr 8) and 0xFF)
    result.add char(payload.len and 0xFF)
  else:
    result.add char(127)
    for shift in countdown(7, 0):
      result.add char((uint64(payload.len) shr (uint(shift) * 8)) and 0xFF)
  result.add payload

type WsFrameParse = object
  needMore: bool
  invalid: bool
  opcode: byte
  fin: bool
  payload: string
  consumed: int

proc wsParseClientFrame(buf: string): WsFrameParse =
  ## One client frame from the head of buf. Client frames must be masked.
  if buf.len < 2:
    result.needMore = true
    return
  let b0 = byte(buf[0])
  let b1 = byte(buf[1])
  result.fin = (b0 and 0x80) != 0
  result.opcode = b0 and 0x0F
  if (b1 and 0x80) == 0:
    result.invalid = true
    return
  var payloadLen = int(b1 and 0x7F)
  var headerLen = 2
  if payloadLen == 126:
    if buf.len < 4:
      result.needMore = true
      return
    payloadLen = (int(byte(buf[2])) shl 8) or int(byte(buf[3]))
    headerLen = 4
  elif payloadLen == 127:
    if buf.len < 10:
      result.needMore = true
      return
    var wide: uint64 = 0
    for i in 0 ..< 8:
      wide = (wide shl 8) or uint64(byte(buf[2 + i]))
    if wide > uint64(wsMaxClientFrameBytes):
      result.invalid = true
      return
    payloadLen = int(wide)
    headerLen = 10
  if payloadLen > wsMaxClientFrameBytes:
    result.invalid = true
    return
  let total = headerLen + 4 + payloadLen
  if buf.len < total:
    result.needMore = true
    return
  let maskStart = headerLen
  result.payload = newString(payloadLen)
  for i in 0 ..< payloadLen:
    result.payload[i] = char(byte(buf[maskStart + 4 + i]) xor
                             byte(buf[maskStart + (i mod 4)]))
  result.consumed = total

proc wsRuntimeForConnValue(connVal: Value): tuple[rt: HttpServerRuntime,
                                                  fd: int] =
  if connVal.kind != vkNode or not connVal.props.hasKey("server_id") or
      not connVal.props.hasKey("fd"):
    return (nil, -1)
  let rt = gHttpServerRegistry.getOrDefault(
    int(connVal.props["server_id"].intVal), nil)
  (rt, int(connVal.props["fd"].intVal))

proc biHttpWsAccept(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (ws_accept req ^on_open f ^on_message g ^on_close h) — returned from a
  ## handler to upgrade this request. Handlers are optional; delivery-only
  ## endpoints pass just ^on_open.
  requireOne("http/ws_accept", args)
  let scope = if call == nil: nil else: call[].dispatchScope
  let req = args[0]
  if req.kind != vkNode or not req.props.hasKey("headers"):
    raiseHttpError("ws_accept expects a request value", scope)
  let headers = req.props["headers"]
  if headers.kind != vkMap:
    raiseHttpError("ws_accept expects a request value", scope)
  let upgrade = headers.mapEntries.getOrDefault("upgrade", VOID)
  if upgrade.kind != vkString or
      upgrade.strVal.toLowerAscii() != "websocket":
    raiseHttpError("ws_accept: request is not a websocket upgrade", scope)
  let key = headers.mapEntries.getOrDefault("sec-websocket-key", VOID)
  if key.kind != vkString or key.strVal.len == 0:
    raiseHttpError("ws_accept: missing Sec-WebSocket-Key", scope)
  var props = initPropTable()
  props["ws_accept"] = newStr(wsAcceptKey(key.strVal))
  if call != nil:
    for name in call[].namedNames:
      if name notin ["on_open", "on_message", "on_close", "subprotocol"]:
        raise newException(GeneError,
          "ws_accept got unexpected named argument: " & name)
    template named(name: string) =
      block:
        let index = nativeNamedIndex(call, name)
        if index >= 0:
          props[name] = call[].namedValues[index]
    named("on_open")
    named("on_message")
    named("on_close")
    # ^subprotocol selects one the client offered (RFC 6455 §4.2.2). (Not
    # `^protocol`: that name is call metadata for direct protocol dispatch.)
    # A browser that offered protocols fails the handshake when the answer
    # names none, and one it did not offer is a protocol error, so selecting
    # an unoffered name is refused here rather than on the wire.
    let protocolIndex = nativeNamedIndex(call, "subprotocol")
    if protocolIndex >= 0:
      let protocol = call[].namedValues[protocolIndex]
      if protocol.kind != vkString or protocol.strVal.len == 0:
        raiseHttpError("ws_accept ^subprotocol expects a non-empty Str", scope)
      var offered = false
      let header = headers.mapEntries.getOrDefault("sec-websocket-protocol",
                                                   VOID)
      if header.kind == vkString:
        for item in header.strVal.split(','):
          if item.strip() == protocol.strVal:
            offered = true
      if not offered:
        raiseHttpError("ws_accept: the client did not offer subprotocol " &
                       protocol.strVal, scope)
      props["protocol"] = protocol
  newNode(newSym("WsUpgrade"), props = props)

proc biHttpWsSend(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (ws_send conn text-or-bytes) -> Int: oldest frames dropped to fit the
  ## bounded queue (0 = clean enqueue), or -1 when the connection is closed. The
  ## caller owns gap semantics on its own stream.
  ##
  ## A `Str` goes out as a text frame and `Bytes` as a binary one. The payload
  ## kind picks the opcode rather than a flag, because a caller that has bytes
  ## in hand never wants them sent as text — RFC 6455 requires a text frame to
  ## be valid UTF-8, so passing a byte string through one is not merely
  ## wasteful, it is a protocol violation the peer is entitled to close on.
  if args.len != 2:
    raise newException(GeneError, "ws_send expects (conn, text or bytes)")
  let payload = args[1]
  if payload.kind notin {vkString, vkBytes}:
    raise newException(GeneError,
      "ws_send payload must be Str or Bytes, got " & $payload.kind)
  let (rt, fd) = wsRuntimeForConnValue(args[0])
  if rt == nil or not rt.wsOpen.getOrDefault(fd, false):
    return newInt(-1)
  var queue = rt.wsOutbound.getOrDefault(fd, @[])
  if payload.kind == vkBytes:
    queue.add wsEncodeFrame(0x2, payload.bytesVal)
  else:
    queue.add wsEncodeFrame(0x1, payload.strVal)
  var dropped = 0
  while queue.len > wsOutboundQueueFrames:
    queue.delete(0)
    inc dropped
  rt.wsOutbound[fd] = queue
  newInt(dropped)

proc biHttpWsQueued(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (ws_queued conn) -> Int: bytes handed to ws_send that the peer has not
  ## yet accepted — frames still queued plus frames on the socket's write
  ## buffer — or -1 when the connection is closed. A sender uses it to stop
  ## producing replaceable data (telemetry) before the queue's drop-oldest
  ## bound can reach data that must not be dropped.
  requireOne("http/ws_queued", args)
  let (rt, fd) = wsRuntimeForConnValue(args[0])
  if rt == nil or not rt.wsOpen.getOrDefault(fd, false):
    return newInt(-1)
  var total = rt.wsPending.getOrDefault(fd, 0)
  for frame in rt.wsOutbound.getOrDefault(fd, @[]):
    total += frame.len
  newInt(total)

proc biHttpWsClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (ws_close conn) — queue a close frame; the loop drops the socket after
  ## flushing it.
  requireOne("http/ws_close", args)
  let (rt, fd) = wsRuntimeForConnValue(args[0])
  if rt == nil or not rt.wsOpen.getOrDefault(fd, false):
    return FALSE
  rt.wsCloseRequested[fd] = true
  TRUE

proc biHttpServe(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (serve server handler) / (serve server ^handler h) /
  ## (serve server ^routes [...]) — run the event loop on this task until
  ## ^max_requests is reached or (stop server) drains it.
  if args.len notin [1, 2]:
    raise newException(GeneError,
      "http/serve expects (Server, handler), got " & $args.len & " arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  if args[0].kind != vkNode or not args[0].props.hasKey("port"):
    raiseHttpError("http/serve expects a Server value with ^host and ^port",
                   scope)
  let (host, port) = httpServerHostPort(args, call, "http/serve", scope)
  var maxRequests = -1
  var maxConnections = httpDefaultMaxConnections
  var maxInFlight = httpDefaultMaxInFlight
  var maxBodyBytes = httpMaxBodyBytes
  var bodyMode = "buffered"
  var bodyIdleMs = httpRecvTimeoutMs
  var bodyIdleSet = false
  var requestTimeoutMs = httpDefaultRequestTimeoutMs
  var drainTimeoutMs = httpDefaultDrainTimeoutMs
  var handler = if args.len == 2: args[1] else: NIL
  var routes: Value = NIL
  var onError: Value = NIL
  # A periodic callback on the serve loop. The loop already sleeps in the kernel
  # only as long as nothing needs it (`selectTimeoutMs`), so a tick is one more
  # deadline to clamp against rather than a thread or a timer subsystem.
  var onTick: Value = NIL
  var tickMs = 0
  var dispatchConfig: Value = NIL
  var overloadResponse: Value = NIL
  var supervisionPolicy: Value = NIL
  var accessLog: Value = NIL
  var errorLog: Value = NIL
  var redactHeaders: Value = NIL
  if call != nil:
    for name in call[].namedNames:
      if name notin ["max_requests", "max_connections", "max_in_flight",
                     "max_body_bytes", "body_mode", "body_idle_ms",
                     "request_timeout_ms",
                     "drain_timeout_ms", "handler", "routes", "on_error",
                     "dispatch", "overload_response", "supervision",
                     "access_log", "error_log", "redact_headers",
                     "on_tick", "tick_ms"]:
        raise newException(GeneError,
          "http/serve got unexpected named argument: " & name)
    template namedInt(name: string, target: var int) =
      block:
        let index = nativeNamedIndex(call, name)
        if index >= 0:
          target = int(requireInt64("http/serve " & name,
                                    call[].namedValues[index]))
    template namedVal(name: string, target: var Value) =
      block:
        let index = nativeNamedIndex(call, name)
        if index >= 0:
          target = call[].namedValues[index]
    namedInt("max_requests", maxRequests)
    namedInt("max_connections", maxConnections)
    namedInt("max_in_flight", maxInFlight)
    namedInt("max_body_bytes", maxBodyBytes)
    let bodyModeIndex = nativeNamedIndex(call, "body_mode")
    if bodyModeIndex >= 0:
      requireStr("http/serve ^body_mode", call[].namedValues[bodyModeIndex])
      bodyMode = call[].namedValues[bodyModeIndex].strVal
    let bodyIdleIndex = nativeNamedIndex(call, "body_idle_ms")
    if bodyIdleIndex >= 0:
      bodyIdleMs = int(requireInt64("http/serve ^body_idle_ms",
                                    call[].namedValues[bodyIdleIndex]))
      bodyIdleSet = true
    namedInt("request_timeout_ms", requestTimeoutMs)
    namedInt("drain_timeout_ms", drainTimeoutMs)
    namedVal("handler", handler)
    namedVal("routes", routes)
    namedVal("on_error", onError)
    namedVal("on_tick", onTick)
    namedInt("tick_ms", tickMs)
    namedVal("dispatch", dispatchConfig)
    namedVal("overload_response", overloadResponse)
    namedVal("supervision", supervisionPolicy)
    namedVal("access_log", accessLog)
    namedVal("error_log", errorLog)
    namedVal("redact_headers", redactHeaders)
  if bodyMode notin ["buffered", "stream"]:
    raiseHttpError("http/serve ^body_mode must be buffered or stream", scope)
  if bodyMode == "stream" and
      (maxBodyBytes < 0 or maxBodyBytes > httpStreamBodyMaxBytes):
    raiseHttpError("http/serve stream ^max_body_bytes must be 0..67108864",
                   scope)
  if bodyIdleMs < 1 or bodyIdleMs > 300000:
    raiseHttpError("http/serve ^body_idle_ms must be within 1..300000", scope)
  if bodyIdleSet and bodyMode != "stream":
    raiseHttpError("http/serve ^body_idle_ms requires stream mode", scope)
  when not compileOption("threads"):
    if bodyMode == "stream":
      raiseHttpError("http/serve stream bodies require a threaded runtime", scope)
  # A tick with no period would spin the loop; a period with no tick is a
  # silently ignored argument. Both are mistakes worth a diagnostic.
  if onTick.kind != vkNil and tickMs <= 0:
    raiseHttpError("http/serve ^on_tick requires a positive ^tick_ms", scope)
  if onTick.kind == vkNil and tickMs > 0:
    raiseHttpError("http/serve ^tick_ms has no effect without ^on_tick", scope)
  var poolConfig: Value = NIL
  if dispatchConfig.kind != vkNil:
    if dispatchConfig.kind == vkNode and
        dispatchConfig.props.hasKey("workers") and
        dispatchConfig.props.hasKey("handle"):
      poolConfig = dispatchConfig
    elif dispatchConfig.kind == vkSymbol and
        dispatchConfig.symVal == "task_per_request":
      discard   # the default
    else:
      raiseHttpError("http/serve ^dispatch expects task_per_request or an " &
                     "(actor_pool ...) value", scope)
  var routeEntries: seq[HttpRouteEntry]
  let usingRoutes = routes.kind != vkNil
  if usingRoutes:
    if handler.kind != vkNil:
      raiseHttpError("http/serve takes either a handler or ^routes, not both",
                     scope)
    if poolConfig.kind != vkNil:
      raiseHttpError("http/serve ^dispatch actor_pool replaces the handler; " &
                     "route inside the pool's ^handle", scope)
    routeEntries = httpParseRouteEntries(routes, scope)
  elif handler.kind == vkNil and poolConfig.kind == vkNil:
    raiseHttpError("http/serve requires a handler, ^routes, or an " &
                   "actor_pool ^dispatch", scope)
  if bodyMode == "stream" and poolConfig.kind != vkNil:
    raiseHttpError("http/serve stream bodies require task_per_request dispatch",
                   scope)
  if supervisionPolicy.kind != vkNil:
    if poolConfig.kind == vkNil:
      raiseHttpError("http/serve ^supervision requires an actor_pool " &
                     "^dispatch; task_per_request failures go through " &
                     "^on_error", scope)
    if supervisionPolicy.kind != vkNode or
        not supervisionPolicy.props.hasKey("strategy"):
      raiseHttpError("http/serve ^supervision expects a " &
                     "(supervisor_policy ...) value", scope)
  # ^overload_response customizes what 503 paths answer (proposal §9). Render
  # the wire bytes once up front: overload handling must stay allocation-light
  # and a bad response value should fail serve, not the overloaded request.
  var overloadWire = simpleHttpWirePayload(503, "Service Unavailable")
  var overloadStatus = 503
  if overloadResponse.kind != vkNil:
    let wire = responseWireParts(overloadResponse, scope)
    overloadStatus = wire.status
    overloadWire = httpWirePayload(wire.status, wire.body, wire.headers)
  # §17 logging: ^redact_headers names whose values never reach access_log
  # records. Defaults per the proposal.
  var redactedHeaderNames = @["authorization", "cookie", "set-cookie"]
  if redactHeaders.kind != vkNil:
    if redactHeaders.kind != vkList:
      raiseHttpError("http/serve ^redact_headers expects a List of Str", scope)
    redactedHeaderNames = @[]
    for item in redactHeaders.listItems:
      requireStr("http/serve redact_headers entry", item)
      redactedHeaderNames.add item.strVal.toLowerAscii()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    # Resolve the server runtime: reuse a listen-created listener, or bind
    # here. Either way the runtime is registered while serving so handlers
    # can reach stop/status through the Server value.
    var rt = httpRuntimeFor(args[0])
    var ownRegistration = false
    if rt == nil:
      if args[0].props.hasKey("tls"):
        raiseHttpError("direct TLS needs http/listen ^tls before http/serve",
                       scope)
      let listener = httpBindListener(host, port, scope)
      rt = registerHttpRuntime(host, port, listener, listening = true)
      ownRegistration = true
      # Stamp the handle onto the caller's Server node so handlers holding
      # this same value can call stop/status on it.
      args[0].setNodeProp("listener", newInt(rt.id))
    elif rt.serving:
      raiseHttpError("this Server is already serving", scope)
    elif not rt.listening:
      raiseHttpError("this Server has been stopped", scope)
    rt.serving = true
    var pool: HttpActorPool = nil
    if poolConfig.kind != vkNil:
      pool = httpSpawnPool(poolConfig, supervisionPolicy, scope)
      rt.workers = pool.workers.len

    let server = rt.listener
    let sendFlags: cint =
      when defined(linux): MSG_NOSIGNAL.cint
      else: 0
    let listenerFd = server.getFd().int
    var selector = newSelector[int]()
    selector.registerHandle(server.getFd(), {Event.Read}, -1)
    var conns = initTable[int, HttpConn]()
    var served = 0
    var draining = false
    var drainDeadline: MonoTime
    let app = scope.application()
    let initialCleanupLeases = app.ioBudget.ioBudgetSnapshot().cleanupLeases
    let initialFileResources = app.ioFileOpenCount()
    var forcedConnections = 0
    var remainingCleanupLeases = 0
    var remainingFileResources = 0
    var cleanupTasks: seq[Value]
    var cleanupTaskFailed = false
    template trackCleanupTask(task: Value) =
      cleanupTasks.add task
      rt.pendingCleanupTasks = cleanupTasks.len
    # `on_tick` fires on a fixed period. `tickMs` of 0 with a handler present is
    # a mistake worth naming rather than a busy loop, so it is rejected at
    # `serve` rather than spun on here.
    let ticking = onTick.kind != vkNil
    var nextTick = if ticking: timerDeadline(tickMs) else: MonoTime()

    # WebSocket callbacks run as fibers, and `dispatchWsHandler` hands back a
    # task nobody was reading — so an exception inside `on_open`, `on_message`,
    # or `on_close` used to vanish completely. Not "logged somewhere quiet":
    # gone. A handler with a typo in it did nothing, reported nothing, and left
    # the socket open and idle, which is indistinguishable from a client that
    # sent no message.
    #
    # These are still fire-and-forget — nothing waits on the result and a
    # failure has no reply to turn into a 500 — but a failure is now *said*.
    # The list is drained every loop pass, so it holds only callbacks still in
    # flight.
    var wsPending: seq[tuple[label: string, task: Value]] = @[]

    proc wsWatch(label: string, task: Value) =
      if task.kind == vkTask:
        wsPending.add (label, task)

    proc wsReapPending() =
      if wsPending.len == 0:
        return
      var stillRunning: seq[tuple[label: string, task: Value]] = @[]
      for entry in wsPending:
        if not entry.task.taskDone:
          stillRunning.add entry
        elif entry.task.taskHasPanic:
          HttpRuntimeLogger.emit(llError,
            "ws " & entry.label & " panic: " & entry.task.taskPanicMsg)
        elif entry.task.taskHasError:
          HttpRuntimeLogger.emit(llError,
            "ws " & entry.label & " error: " & entry.task.taskErrorMsg)
      wsPending = stillRunning

    proc unregisterConn(conn: HttpConn) =
      try:
        selector.unregister(conn.fd)
      except OSError, IOSelectorsException:
        discard
      except CatchableError:
        discard

    proc refreshStreamInterests(conn: HttpConn) =
      var events: set[Event] = {}
      if conn.phase in {hcpDispatched, hcpStreamingResponse} and
          conn.streamingBody and conn.bodyWaitingForSocket:
        events.incl (if conn.tlsReadWantWrite: Event.Write else: Event.Read)
      if conn.phase == hcpStreamingResponse and
          conn.writePos < conn.writeBuf.len:
        events.incl (if conn.tlsWriteWantRead: Event.Read else: Event.Write)
      selector.updateHandle(conn.fd, events)

    proc closeBodyResources(conn: HttpConn) =
      if conn.bodyWriter.kind == vkNode or conn.bodyReader.kind == vkNode:
        var nativeCall = NativeCall(dispatchScope: scope)
        if conn.bodyWriter.kind == vkNode:
          try:
            discard biIoFileClose([conn.bodyWriter], addr nativeCall)
            trackCleanupTask biIoFileWaitClosed([conn.bodyWriter], addr nativeCall)
          except CatchableError:
            cleanupTaskFailed = true
        if conn.bodyReader.kind == vkNode:
          try:
            discard biIoFileClose([conn.bodyReader], addr nativeCall)
            trackCleanupTask biIoFileWaitClosed([conn.bodyReader], addr nativeCall)
          except CatchableError:
            cleanupTaskFailed = true
      conn.bodyWriter = NIL
      conn.bodyReader = NIL
      conn.bodyWriteTask = NIL
      conn.bodyChunk = ""
      conn.bodyRaw = ""
      conn.chunkLine = ""
      conn.streamingBody = false
      conn.bodyWaitingForSocket = false

    proc closeResponseResources(conn: HttpConn) =
      if conn.responseReadTask.kind == vkTask and
          not conn.responseReadTask.taskDone:
        discard nativeTaskCancel(conn.responseReadTask, scope)
      if conn.responseOwnReader and conn.responseReader.kind != vkNil:
        try:
          let ioScope = scope.application().stdlib.vars["io"].nsScope
          let message = ioScope.vars["IoResource"].protocolMessages["close"]
          let closer = resolveProtocolMessage(scope, message,
                                              conn.responseReader)
          discard applyCall(closer, [conn.responseReader], NamedArgs(), scope)
          let waiterMessage = ioScope.vars["IoResource"].protocolMessages[
            "wait_closed"]
          let waiter = resolveProtocolMessage(scope, waiterMessage,
                                              conn.responseReader)
          let closeTask = applyCall(waiter, [conn.responseReader],
                                    NamedArgs(), scope)
          if closeTask.kind == vkTask: trackCleanupTask closeTask
          else: cleanupTaskFailed = true
        except CatchableError:
          cleanupTaskFailed = true
      conn.responseReadTask = NIL
      conn.responseCloseTask = NIL
      conn.responseReader = NIL

    proc pruneCleanupTasks() =
      var index = 0
      while index < cleanupTasks.len:
        let task = cleanupTasks[index]
        if task.kind != vkTask:
          cleanupTaskFailed = true
          cleanupTasks.delete(index)
        elif task.taskDone:
          if task.taskHasError or task.taskHasPanic or task.taskCancelled:
            cleanupTaskFailed = true
          cleanupTasks.delete(index)
        else:
          inc index
      rt.pendingCleanupTasks = cleanupTasks.len

    proc closeConn(conn: HttpConn) =
      closeBodyResources(conn)
      closeResponseResources(conn)
      if conn.inFlightCounted:
        if conn.task.kind == vkTask and not conn.task.taskDone:
          discard nativeTaskCancel(conn.task, scope)
        dec rt.inFlight
        conn.inFlightCounted = false
      if conn.phase == hcpWebSocket:
        rt.wsOpen.del(conn.fd)
        rt.wsOutbound.del(conn.fd)
        rt.wsCloseRequested.del(conn.fd)
        rt.wsPending.del(conn.fd)
        if conn.wsOnClose.kind != vkNil:
          try:
            wsWatch("on_close", dispatchWsHandler(conn.wsOnClose,
                                               [conn.wsValue], scope))
          except GeneError as e:
            HttpRuntimeLogger.emit(llError, "ws on_close error: " & e.msg)
          except GenePanic as e:
            HttpRuntimeLogger.emit(llError, "ws on_close panic: " & e.msg)
      unregisterConn(conn)
      conns.del(conn.fd)
      if conn.tlsConnection != nil:
        rt.tls.closeConnection(conn.tlsConnection)
        conn.tlsConnection = nil
      conn.sock.close()
      rt.activeConnections = conns.len

    proc finishServed(conn: HttpConn) =
      ## A connection that produced a response (any status) consumes one
      ## request slot, matching the old per-connection `served` counting.
      inc served
      closeConn(conn)

    proc wsEnterWebSocket(conn: HttpConn) =
      ## The 101 handshake flushed; the socket becomes a frame stream.
      inc served
      conn.wsUpgrading = false
      conn.phase = hcpWebSocket
      conn.buf.setLen(0)
      conn.writeBuf = ""
      conn.writePos = 0
      conn.wsPingDeadline = timerDeadline(wsPingIntervalMs)
      conn.wsAwaitingPong = false
      rt.wsOpen[conn.fd] = true
      try:
        selector.updateHandle(conn.fd,
          {if conn.tlsReadWantWrite: Event.Write else: Event.Read})
      except CatchableError:
        closeConn(conn)
        return
      if conn.wsOnOpen.kind != vkNil:
        try:
          wsWatch("on_open", dispatchWsHandler(conn.wsOnOpen,
                                               [conn.wsValue], scope))
        except GeneError as e:
          HttpRuntimeLogger.emit(llError, "ws on_open error: " & e.msg)
        except GenePanic as e:
          HttpRuntimeLogger.emit(llError, "ws on_open panic: " & e.msg)

    proc completeWrite(conn: HttpConn) =
      ## A fully flushed response either finishes the request or, for an
      ## accepted upgrade, hands the socket to WebSocket mode. tryFlush also
      ## reports true for dead sockets — those never enter WS mode.
      if conn.wsUpgrading and conn.writePos >= conn.writeBuf.len:
        wsEnterWebSocket(conn)
      else:
        finishServed(conn)

    proc logAccess(conn: HttpConn, status: int) =
      ## §17 access log: one AccessLog record per chosen response. Runs the
      ## log fn inline on the loop; a failing log fn goes to stderr and never
      ## breaks serving.
      if accessLog.kind == vkNil:
        return
      var props = initPropTable()
      props["method"] = newStr(conn.reqMethod)
      props["path"] = newStr(conn.reqPath)
      props["status"] = newInt(status)
      props["ms"] = newInt(int((getMonoTime() - conn.started).inMilliseconds))
      if conn.reqHeaders.kind == vkMap:
        var redacted = initPropTable()
        for key, val in conn.reqHeaders.mapEntries:
          if key in redactedHeaderNames:
            redacted[key] = newStr("[redacted]")
          else:
            redacted[key] = val
        props["headers"] = newMap(redacted)
      let record = newNode(newSym("AccessLog"), props = props)
      try:
        discard applyCall(accessLog, [record], NamedArgs(), scope)
      except GeneError as e:
        HttpRuntimeLogger.emit(llError, "access_log error: " & e.msg)
      except GenePanic as e:
        HttpRuntimeLogger.emit(llError, "access_log panic: " & e.msg)

    proc logError(conn: HttpConn, message: string, panic: bool) =
      ## §17 error log: handler errors/panics as ErrorLog records; same
      ## never-break-serving contract as the access log.
      if errorLog.kind == vkNil:
        return
      var props = initPropTable()
      props["method"] = newStr(conn.reqMethod)
      props["path"] = newStr(conn.reqPath)
      props["message"] = newStr(message)
      props["panic"] = newBool(panic)
      let record = newNode(newSym("ErrorLog"), props = props)
      try:
        discard applyCall(errorLog, [record], NamedArgs(), scope)
      except GeneError as e:
        HttpRuntimeLogger.emit(llError, "error_log error: " & e.msg)
      except GenePanic as e:
        HttpRuntimeLogger.emit(llError, "error_log panic: " & e.msg)

    proc recvConn(conn: HttpConn, buffer: pointer, size: int): int =
      if conn.tlsConnection == nil:
        return recv(SocketHandle(conn.fd), buffer, size.cint, 0).int
      var produced: csize_t
      let status = rt.tls.read(conn.tlsConnection, buffer, csize_t(size),
                               addr produced)
      case status
      of 1:
        conn.tlsReadWantWrite = false
        conn.tlsReadNeedsSocket = false
        int(produced)
      of 3: 0
      of 0:
        conn.tlsReadWantWrite = false
        conn.tlsReadNeedsSocket = true
        -2
      of 2:
        conn.tlsReadWantWrite = true
        conn.tlsReadNeedsSocket = true
        -3
      else: -1

    proc sendConn(conn: HttpConn, buffer: pointer, size: int): int =
      if conn.tlsConnection == nil:
        return send(SocketHandle(conn.fd), buffer, size.cint, sendFlags).int
      var consumed: csize_t
      let attempted = if conn.tlsPendingWriteLength > 0:
                        conn.tlsPendingWriteLength
                      else: min(size, 65536)
      let status = rt.tls.write(conn.tlsConnection, buffer,
        csize_t(attempted), addr consumed)
      case status
      of 1:
        conn.tlsWriteWantRead = false
        conn.tlsPendingWriteLength = 0
        int(consumed)
      of 0:
        conn.tlsWriteWantRead = true
        conn.tlsPendingWriteLength = attempted
        -2
      of 2:
        conn.tlsWriteWantRead = false
        conn.tlsPendingWriteLength = attempted
        -3
      else: -1

    proc tryFlush(conn: HttpConn): bool =
      ## Flush as much of the response as the socket accepts. True when the
      ## payload is fully written or the connection is beyond saving.
      while conn.writePos < conn.writeBuf.len:
        let remaining = conn.writeBuf.len - conn.writePos
        let n = sendConn(conn, addr conn.writeBuf[conn.writePos], remaining)
        if n > 0:
          conn.writePos += n
          rt.bytesWritten += n
        elif n in [-2, -3] or (conn.tlsConnection == nil and n < 0 and
            (errno == EAGAIN or errno == EWOULDBLOCK)):
          return false
        elif conn.tlsConnection == nil and n < 0 and errno == EINTR:
          continue
        else:
          conn.writeFailed = true
          return true    # client went away mid-response; keep serving
      true

    proc startWrite(conn: HttpConn, payload: string) =
      closeBodyResources(conn)
      conn.writeBuf = payload
      conn.writePos = 0
      conn.writeFailed = false
      conn.phase = hcpWriting
      conn.task = NIL
      if tryFlush(conn):
        completeWrite(conn)
      else:
        try:
          selector.updateHandle(conn.fd,
            {if conn.tlsWriteWantRead: Event.Read else: Event.Write})
        except CatchableError:
          finishServed(conn)

    proc respondCounted(conn: HttpConn, status: int, body: string) =
      case status
      of 400, 413: inc rt.badRequests
      of 408, 504: inc rt.timeouts
      of 503: inc rt.overloadedRequests
      of 500: inc rt.failedRequests
      else: discard
      logAccess(conn, status)
      startWrite(conn, simpleHttpWirePayload(status, body))

    proc respondOverloaded(conn: HttpConn) =
      ## Admission-limit answer: the (possibly customized) overload response.
      inc rt.overloadedRequests
      logAccess(conn, overloadStatus)
      startWrite(conn, overloadWire)

    proc httpTaskResponsePayload(conn: HttpConn):
        tuple[payload: string, status: int] =
      ## Wire payload for a settled handler task. Failed tasks go through the
      ## ^on_error mapper when one is configured; panics and cancellation stay
      ## generic 500s (stderr diagnostics preserved from the old server).
      let task = conn.task
      if task.taskHasPanic:
        HttpRuntimeLogger.emit(llError, "handler panic: " & task.taskPanicMsg)
        logError(conn, task.taskPanicMsg, panic = true)
        inc rt.failedRequests
        return (simpleHttpWirePayload(500, "Internal Server Error"), 500)
      if task.taskCancelled:
        HttpRuntimeLogger.emit(llWarn, "handler cancelled")
        logError(conn, "handler cancelled", panic = false)
        inc rt.failedRequests
        return (simpleHttpWirePayload(500, "Internal Server Error"), 500)
      if task.taskHasError:
        logError(conn, task.taskErrorMsg, panic = false)
        if onError.kind != vkNil:
          try:
            let mapped = applyCall(onError, [httpErrorFallbackNode(task)],
                                   NamedArgs(), scope)
            let wire = responseWireParts(mapped, scope)
            inc rt.completedRequests
            return (httpWirePayload(wire.status, wire.body, wire.headers),
                    wire.status)
          except GeneError as e:
            HttpRuntimeLogger.emit(llError, "on_error mapper error: " & e.msg)
          except GenePanic as e:
            HttpRuntimeLogger.emit(llError, "on_error mapper panic: " & e.msg)
        HttpRuntimeLogger.emit(llError, "handler error: " & task.taskErrorMsg)
        inc rt.failedRequests
        return (simpleHttpWirePayload(500, "Internal Server Error"), 500)
      try:
        let wire = responseWireParts(task.taskResult, scope)
        inc rt.completedRequests
        (httpWirePayload(wire.status, wire.body, wire.headers), wire.status)
      except GeneError as e:
        HttpRuntimeLogger.emit(llError, "handler error: " & e.msg)
        logError(conn, e.msg, panic = false)
        inc rt.failedRequests
        (simpleHttpWirePayload(500, "Internal Server Error"), 500)

    proc failStreamResponse(conn: HttpConn, message: string) =
      HttpRuntimeLogger.emit(llError, "stream response error: " & message)
      logError(conn, message, panic = false)
      inc rt.failedRequests
      finishServed(conn) # headers may already be on the wire; no replacement

    proc requestOwnedResponseClose(conn: HttpConn) =
      if not conn.responseOwnReader or conn.responseCloseTask.kind == vkTask:
        return
      let ioScope = scope.application().stdlib.vars["io"].nsScope
      let protocol = ioScope.vars["IoResource"]
      let closer = resolveProtocolMessage(scope,
        protocol.protocolMessages["close"], conn.responseReader)
      discard applyCall(closer, [conn.responseReader], NamedArgs(), scope)
      let waiter = resolveProtocolMessage(scope,
        protocol.protocolMessages["wait_closed"], conn.responseReader)
      conn.responseCloseTask = applyCall(waiter, [conn.responseReader],
                                         NamedArgs(), scope)
      if conn.responseCloseTask.kind != vkTask:
        raise newException(GeneError,
          "stream response wait_closed did not return a Task")

    proc pumpStreamResponse(conn: HttpConn) =
      var budget = 16 # immediate readers cannot monopolize the server lane
      while budget > 0 and conn.phase == hcpStreamingResponse and
          conn.fd in conns:
        dec budget
        if conn.writePos < conn.writeBuf.len:
          if not tryFlush(conn):
            try: refreshStreamInterests(conn)
            except CatchableError: closeConn(conn)
            return
          if conn.writeFailed:
            failStreamResponse(conn, "client closed during streamed write")
            return
          conn.writeBuf = ""
          conn.writePos = 0
        if conn.responseFinalQueued:
          if conn.responseCloseTask.kind == vkTask:
            if not conn.responseCloseTask.taskDone:
              try: refreshStreamInterests(conn)
              except CatchableError: closeConn(conn)
              return
            if conn.responseCloseTask.taskHasError or
                conn.responseCloseTask.taskHasPanic or
                conn.responseCloseTask.taskCancelled:
              failStreamResponse(conn,
                "owned stream reader failed to close")
              return
          finishServed(conn)
          return
        if conn.responseReadTask.kind == vkTask:
          if not conn.responseReadTask.taskDone:
            try: refreshStreamInterests(conn)
            except CatchableError: closeConn(conn)
            return
          let readTask = conn.responseReadTask
          conn.responseReadTask = NIL
          if readTask.taskHasError or readTask.taskHasPanic or
              readTask.taskCancelled:
            failStreamResponse(conn, "stream reader failed")
            return
          let part = readTask.taskResult
          if part.kind == vkNil:
            if conn.responseKnownLength >= 0 and
                conn.responseSent != conn.responseKnownLength:
              failStreamResponse(conn, "stream ended before Content-Length")
              return
            try:
              requestOwnedResponseClose(conn)
            except CatchableError as error:
              failStreamResponse(conn, "stream close failed: " & error.msg)
              return
            conn.responseFinalQueued = true
            if conn.responseChunked:
              conn.writeBuf = "0\r\n\r\n"
              conn.writePos = 0
            continue
          if part.kind != vkBytes or part.bytesVal.len == 0:
            failStreamResponse(conn, "reader returned non-Bytes or empty Bytes")
            return
          let size = part.bytesVal.len
          if size > conn.responseMaxBytes - conn.responseSent or
              (conn.responseKnownLength >= 0 and
               size > conn.responseKnownLength - conn.responseSent):
            failStreamResponse(conn, "stream exceeded its declared byte limit")
            return
          conn.responseSent += size
          conn.writeBuf =
            if conn.responseChunked:
              toHex(size) & "\r\n" & part.bytesVal & "\r\n"
            else: part.bytesVal
          conn.writePos = 0
          continue
        let requested =
          if conn.responseKnownLength < 0: 65536
          elif conn.responseSent < conn.responseKnownLength:
            min(65536, conn.responseKnownLength - conn.responseSent)
          else: 1 # known length still requires EOF confirmation
        try:
          let ioScope = scope.application().stdlib.vars["io"].nsScope
          let message = ioScope.vars["AsyncReader"].protocolMessages["read"]
          let reader = resolveProtocolMessage(scope, message,
                                              conn.responseReader)
          conn.responseReadTask = applyCall(reader,
            [conn.responseReader, newInt(requested)], NamedArgs(), scope)
          if conn.responseReadTask.kind != vkTask:
            raise newException(GeneError,
              "stream response read did not return a Task")
        except CatchableError as error:
          failStreamResponse(conn, "stream read failed: " & error.msg)
          return
        if not conn.responseReadTask.taskDone:
          try: refreshStreamInterests(conn)
          except CatchableError: closeConn(conn)
          return
      if conn.phase == hcpStreamingResponse and conn.fd in conns:
        try: refreshStreamInterests(conn)
        except CatchableError: closeConn(conn)

    proc startStreamResponse(conn: HttpConn, response: Value) =
      let wire = streamResponseWire(response, scope)
      conn.responseFromRequestBody = conn.bodyReader.kind == vkNode and
        wire.reader.bits == conn.bodyReader.bits
      if not conn.responseFromRequestBody:
        closeBodyResources(conn)
      conn.phase = hcpStreamingResponse
      conn.responseReader = wire.reader
      conn.responseOwnReader = wire.ownReader
      conn.responseChunked = wire.knownLength < 0
      conn.responseKnownLength = wire.knownLength
      conn.responseMaxBytes = wire.maxBytes
      conn.responseSent = 0
      conn.responseFinalQueued = false
      conn.writeBuf = wire.headers
      conn.writePos = 0
      conn.writeFailed = false
      if conn.reqMethod == "HEAD":
        requestOwnedResponseClose(conn)
        conn.responseFinalQueued = true
      inc rt.completedRequests
      logAccess(conn, wire.status)
      pumpStreamResponse(conn)

    proc failStreamingBody(conn: HttpConn, status: int) =
      if conn.phase == hcpStreamingResponse:
        failStreamResponse(conn,
          if status == 413: "request body exceeded byte limit"
          else: "request body framing failed")
        return
      if conn.inFlightCounted:
        if conn.task.kind == vkTask and not conn.task.taskDone:
          discard nativeTaskCancel(conn.task, scope)
        dec rt.inFlight
        conn.inFlightCounted = false
      respondCounted(conn, status,
        if status == 413: "Payload Too Large" else: "Bad Request")

    proc pumpStreamingBody(conn: HttpConn) =
      if not conn.streamingBody or conn.fd notin conns or
          conn.phase notin {hcpDispatched, hcpStreamingResponse}:
        return
      if conn.bodyWriteTask.kind == vkTask:
        if not conn.bodyWriteTask.taskDone:
          return
        let completed = conn.bodyWriteTask
        conn.bodyWriteTask = NIL
        if completed.taskCancelled or completed.taskHasError or
            completed.taskHasPanic or completed.taskResult.kind != vkInt or
            completed.taskResult.intVal <= 0:
          if conn.phase == hcpStreamingResponse:
            failStreamResponse(conn, "request body pipe write failed")
            return
          closeBodyResources(conn)
          try: refreshStreamInterests(conn)
          except CatchableError: closeConn(conn)
          return
        conn.bodyWriteOffset += int(completed.taskResult.intVal)
      if conn.bodyWriteOffset >= conn.bodyChunk.len:
        conn.bodyChunk = ""
        conn.bodyWriteOffset = 0
        case decodeHttpBody(conn, maxBodyBytes)
        of hbdData: discard
        of hbdNeedMore:
          if not conn.bodyWaitingForSocket:
            conn.readDeadline = timerDeadline(bodyIdleMs)
            conn.bodyWaitingForSocket = true
          try: refreshStreamInterests(conn)
          except CatchableError: closeConn(conn)
          return
        of hbdBad:
          failStreamingBody(conn, 400)
          return
        of hbdTooLarge:
          failStreamingBody(conn, 413)
          return
        of hbdDone:
          if conn.bodyWriter.kind == vkNode:
            var nativeCall = NativeCall(dispatchScope: scope)
            try: discard biIoFileClose([conn.bodyWriter], addr nativeCall)
            except CatchableError: discard
            conn.bodyWriter = NIL
          conn.bodyDone = true
          conn.streamingBody = false
          conn.bodyWaitingForSocket = false
          try: refreshStreamInterests(conn)
          except CatchableError: closeConn(conn)
          return
      if conn.bodyWriteOffset < conn.bodyChunk.len:
        conn.bodyWaitingForSocket = false
        var nativeCall = NativeCall(dispatchScope: scope)
        try:
          conn.bodyWriteTask = biIoFileWrite(
            [conn.bodyWriter,
             newBytes(conn.bodyChunk[conn.bodyWriteOffset .. ^1])],
            addr nativeCall)
          refreshStreamInterests(conn)
        except CatchableError:
          if conn.phase == hcpStreamingResponse:
            failStreamResponse(conn, "request body pipe write failed")
            return
          closeBodyResources(conn)
          try: refreshStreamInterests(conn)
          except CatchableError: closeConn(conn)
        return

    proc dispatchConn(conn: HttpConn, request: Value) =
      # Generated assets are answered before the application's own routing, by
      # every server this application starts (transpile.md §4.12). They are
      # already-compiled bytes in a table, so this never enters the in-flight
      # accounting or the handler dispatch path at all.
      block generatedAssets:
        let requestMethod = request.props["method"].strVal
        if requestMethod notin ["GET", "HEAD"]:
          break generatedAssets
        let found = scope.application().lookupWebRoute(
          request.props["path"].strVal)
        if not found.found:
          break generatedAssets
        var headers = initOrderedTable[string, string]()
        headers["content-type"] = found.route.contentType
        # The URL contains a hash of exactly these bytes, so a changed asset
        # is a changed URL and this response can never go stale.
        headers["cache-control"] = "public, max-age=31536000, immutable"
        headers["x-content-type-options"] = "nosniff"
        var payload = httpWirePayload(200, found.route.body, headers)
        if requestMethod == "HEAD":
          # Identical headers to the GET — including its content-length — with
          # the body dropped. Building the full payload and truncating is what
          # keeps the two in agreement; recomputing headers for an empty body
          # would report `content-length: 0`.
          let headerEnd = payload.find("\r\n\r\n")
          if headerEnd >= 0:
            payload.setLen(headerEnd + 4)
        inc rt.completedRequests
        logAccess(conn, 200)
        startWrite(conn, payload)
        return
      if maxInFlight > 0 and rt.inFlight >= maxInFlight:
        respondOverloaded(conn)
        return
      var routed = handler
      if usingRoutes:
        let match = httpMatchRoute(routeEntries, request)
        if not match.found:
          inc rt.completedRequests
          logAccess(conn, 404)
          startWrite(conn, simpleHttpWirePayload(404, "Not Found"))
          return
        routed = match.handler
        if match.params.len != 0:
          # ":name" captures join query params in req/params; a path capture
          # wins over a same-named query key.
          var merged = initPropTable()
          let existing = request.props["params"]
          if existing.kind == vkMap:
            for key, val in existing.mapEntries:
              merged[key] = val
          for (name, value) in match.params:
            merged[name] = newStr(value)
          request.setNodeProp("params", newMap(merged))
      conn.phase = hcpDispatched
      try:
        selector.updateHandle(conn.fd, {})
      except CatchableError:
        closeConn(conn)
        return
      if requestTimeoutMs > 0:
        conn.taskDeadline = timerDeadline(requestTimeoutMs)
        conn.hasTaskDeadline = true
      try:
        if pool != nil:
          let (task, overloaded) = dispatchHttpToPool(pool, request, scope)
          if overloaded:
            respondOverloaded(conn)
            return
          conn.task = task
        else:
          conn.task = dispatchHttpHandler(routed, request, scope)
        inc rt.inFlight
        conn.inFlightCounted = true
      except GeneError as e:
        HttpRuntimeLogger.emit(llError, "handler error: " & e.msg)
        respondCounted(conn, 500, "Internal Server Error")
      except GenePanic as e:
        HttpRuntimeLogger.emit(llError, "handler panic: " & e.msg)
        respondCounted(conn, 500, "Internal Server Error")

    proc handleStreamingReadable(conn: HttpConn) =
      if not conn.streamingBody or conn.bodyWriteTask.kind == vkTask or
          conn.bodyChunk.len > 0 or conn.bodyRawPos < conn.bodyRaw.len:
        return
      let amount = if conn.bodyChunked: httpReadChunkBytes
                   else: min(httpReadChunkBytes, conn.bodyRemaining)
      if amount <= 0:
        pumpStreamingBody(conn)
        return
      var chunk = newString(amount)
      let n = recvConn(conn, addr chunk[0], amount)
      if n > 0:
        chunk.setLen(n)
        conn.bodyRaw = move chunk
        conn.bodyRawPos = 0
        conn.bodyWaitingForSocket = false
        conn.readDeadline = timerDeadline(bodyIdleMs)
        rt.bytesRead += n
        pumpStreamingBody(conn)
      elif n == 0:
        if conn.phase == hcpStreamingResponse:
          failStreamResponse(conn, "request body ended before framing completed")
        else:
          closeConn(conn) # truncated body cannot become a successful EOF
      elif n notin [-2, -3] and (conn.tlsConnection != nil or
          (errno != EAGAIN and errno != EWOULDBLOCK and errno != EINTR)):
        if conn.phase == hcpStreamingResponse:
          failStreamResponse(conn, "request body socket read failed")
        else:
          closeConn(conn)

    proc handleReadable(conn: HttpConn) =
      var chunk = newString(httpReadChunkBytes)
      while true:
        let n = recvConn(conn, addr chunk[0], httpReadChunkBytes)
        if n > 0:
          let start = conn.buf.len
          conn.buf.setLen(start + n)
          copyMem(addr conn.buf[start], addr chunk[0], n)
          rt.bytesRead += n
          if bodyMode == "stream" and
              (conn.buf.find("\r\n\r\n") >= 0 or
               conn.buf.len > httpMaxHeaderBytes):
            break
          if n < httpReadChunkBytes and conn.tlsConnection == nil:
            break
        elif n == 0:
          closeConn(conn)      # EOF before a complete request
          return
        elif n in [-2, -3] or (conn.tlsConnection == nil and
            (errno == EAGAIN or errno == EWOULDBLOCK)):
          break
        elif conn.tlsConnection == nil and errno == EINTR:
          continue
        else:
          closeConn(conn)
          return
      let parsed = parseHttpRequestBuffer(conn.buf, maxBodyBytes, scope,
                                         headersOnly = bodyMode == "stream")
      case parsed.status
      of hpsNeedMore:
        discard
      of hpsBad:
        respondCounted(conn, 400, "Bad Request")
      of hpsTooLarge:
        respondCounted(conn, 413, "Payload Too Large")
      of hpsDone:
        let reqProps = parsed.value.props
        conn.reqMethod = reqProps["method"].strVal
        conn.reqPath = reqProps["path"].strVal
        conn.reqHeaders = reqProps["headers"]
        if bodyMode == "stream":
          try:
            var nativeCall = NativeCall(dispatchScope: scope)
            let pair = biIoPipe([], addr nativeCall)
            conn.bodyReader = pair.listItems[0]
            conn.bodyWriter = pair.listItems[1]
            let available = max(0, conn.buf.len - parsed.bodyStart)
            let initial = if parsed.chunked: available
                          else: min(parsed.contentLength, available)
            conn.bodyRaw =
              if initial > 0:
                conn.buf[parsed.bodyStart ..< parsed.bodyStart + initial]
              else: ""
            conn.buf = ""
            conn.bodyRawPos = 0
            conn.bodyChunk = ""
            conn.bodyWriteOffset = 0
            conn.bodyRemaining = parsed.contentLength
            conn.bodyChunked = parsed.chunked
            conn.chunkState = hcsSize
            conn.bodyWaitingForSocket = false
            conn.readDeadline = timerDeadline(bodyIdleMs)
            conn.streamingBody = true
            parsed.value.setNodeProp("body", conn.bodyReader)
            dispatchConn(conn, parsed.value)
            if conn.fd in conns and conn.phase == hcpDispatched:
              pumpStreamingBody(conn)
          except CatchableError as error:
            HttpRuntimeLogger.emit(llError,
              "stream body setup failed: " & error.msg)
            respondCounted(conn, 500, "Internal Server Error")
        else:
          dispatchConn(conn, parsed.value)

    proc wsFlushConn(conn: HttpConn) =
      if tryFlush(conn):
        rt.wsPending[conn.fd] = max(0, conn.writeBuf.len - conn.writePos)
        if conn.writePos >= conn.writeBuf.len:
          conn.writeBuf = ""
          conn.writePos = 0
          if conn.wsCloseAfterFlush:
            closeConn(conn)
            return
          try:
            selector.updateHandle(conn.fd,
              {if conn.tlsReadWantWrite: Event.Write else: Event.Read})
          except CatchableError:
            closeConn(conn)
        else:
          closeConn(conn)    # dead socket mid-frame
      else:
        try:
          selector.updateHandle(conn.fd,
            {if conn.tlsReadWantWrite: Event.Write else: Event.Read,
             if conn.tlsWriteWantRead: Event.Read else: Event.Write})
        except CatchableError:
          closeConn(conn)

    proc wsAppendFrame(conn: HttpConn, frame: string) =
      # Compact flushed bytes before growing the buffer.
      if conn.writePos > 0:
        conn.writeBuf = conn.writeBuf[conn.writePos .. ^1]
        conn.writePos = 0
      conn.writeBuf.add frame
      if conn.phase == hcpWebSocket:
        rt.wsPending[conn.fd] = conn.writeBuf.len

    proc handleWsReadable(conn: HttpConn) =
      var chunk = newString(httpReadChunkBytes)
      while true:
        let n = recvConn(conn, addr chunk[0], httpReadChunkBytes)
        if n > 0:
          let start = conn.buf.len
          conn.buf.setLen(start + n)
          copyMem(addr conn.buf[start], addr chunk[0], n)
          rt.bytesRead += n
          if n < httpReadChunkBytes and conn.tlsConnection == nil:
            break
        elif n == 0:
          closeConn(conn)
          return
        elif n in [-2, -3] or (conn.tlsConnection == nil and
            (errno == EAGAIN or errno == EWOULDBLOCK)):
          break
        elif conn.tlsConnection == nil and errno == EINTR:
          continue
        else:
          closeConn(conn)
          return
      while true:
        let frame = wsParseClientFrame(conn.buf)
        if frame.needMore:
          break
        if frame.invalid or not frame.fin:
          closeConn(conn)    # no fragmentation support; protocol error
          return
        conn.buf = conn.buf[frame.consumed .. ^1]
        case frame.opcode
        of 0x1, 0x2:
          # Delivery-only surface: an inbound data frame reaches the optional
          # on_message callback; mutations stay on the HTTP routes.
          #
          # The payload arrives as a `Str` for a text frame (0x1) and `Bytes`
          # for a binary one (0x2), so a handler tells them apart the way it
          # tells any two Gene values apart. Binary used to fall through this
          # `case` with no branch at all — silently dropped, which is the worst
          # of the three possible behaviours: a peer sending a binary frame got
          # no delivery, no error, and no close.
          if conn.wsOnMessage.kind != vkNil:
            let payload = if frame.opcode == 0x2: newBytes(frame.payload)
                          else: newStr(frame.payload)
            try:
              wsWatch("on_message",
                      dispatchWsHandler(conn.wsOnMessage,
                                        [conn.wsValue, payload], scope))
            except GeneError as e:
              HttpRuntimeLogger.emit(llError, "ws on_message error: " & e.msg)
            except GenePanic as e:
              HttpRuntimeLogger.emit(llError, "ws on_message panic: " & e.msg)
        of 0x8:
          if not conn.wsCloseAfterFlush:
            wsAppendFrame(conn, wsEncodeFrame(0x8, frame.payload))
            conn.wsCloseAfterFlush = true
          wsFlushConn(conn)
          return
        of 0x9:
          wsAppendFrame(conn, wsEncodeFrame(0xA, frame.payload))
        of 0xA:
          conn.wsAwaitingPong = false
        else:
          closeConn(conn)
          return
      if conn.writeBuf.len > conn.writePos:
        wsFlushConn(conn)

    proc drainWsOutbound() =
      ## Move frames queued by ws_send (and requested closes) onto their
      ## connections and flush.
      if rt.wsOutbound.len == 0 and rt.wsCloseRequested.len == 0:
        return
      var pending: seq[HttpConn]
      for conn in conns.values:
        if conn.phase == hcpWebSocket:
          pending.add conn
      for conn in pending:
        if conn.fd notin conns:
          continue
        var queued = rt.wsOutbound.getOrDefault(conn.fd, @[])
        if queued.len > 0:
          rt.wsOutbound.del(conn.fd)
          for frame in queued:
            wsAppendFrame(conn, frame)
        if rt.wsCloseRequested.getOrDefault(conn.fd, false) and
            not conn.wsCloseAfterFlush:
          rt.wsCloseRequested.del(conn.fd)
          wsAppendFrame(conn, wsEncodeFrame(0x8, ""))
          conn.wsCloseAfterFlush = true
        if conn.writeBuf.len > conn.writePos:
          wsFlushConn(conn)

    proc acceptClients() =
      while true:
        var client: Socket
        try:
          server.accept(client)
        except OSError:
          break    # EAGAIN ("no client yet") or fatal: stop this batch
        if maxConnections > 0 and conns.len >= maxConnections:
          client.close()    # shed load beyond the connection cap
          continue
        inc rt.acceptedConnections
        let fd = client.getFd().int
        httpSetNonBlocking(fd.cint)
        when defined(macosx):
          # Suppress SIGPIPE on writes to a half-closed socket (linux uses
          # MSG_NOSIGNAL per send instead).
          var noSigPipe: cint = 1
          discard setsockopt(SocketHandle(fd), SOL_SOCKET, SO_NOSIGPIPE,
                             addr noSigPipe, SockLen(sizeof(noSigPipe)))
        let conn = HttpConn(sock: client, fd: fd,
                            phase: if rt.tlsServer != nil: hcpTlsHandshake
                                   else: hcpReading,
                            task: NIL, started: getMonoTime(),
                            reqHeaders: NIL,
                            readDeadline: timerDeadline(httpRecvTimeoutMs))
        if rt.tlsServer != nil:
          conn.tlsConnection = rt.tls.openConnection(rt.tlsServer, fd.cint)
          if conn.tlsConnection == nil:
            client.close()
            continue
        conns[fd] = conn
        rt.activeConnections = conns.len
        try:
          selector.registerHandle(SocketHandle(fd), {Event.Read}, 0)
        except CatchableError:
          conns.del(fd)
          rt.activeConnections = conns.len
          if conn.tlsConnection != nil:
            rt.tls.closeConnection(conn.tlsConnection)
          client.close()

    proc advanceTlsHandshake(conn: HttpConn) =
      let status = rt.tls.handshake(conn.tlsConnection)
      case status
      of 1:
        conn.phase = hcpReading
        conn.tlsHandshakeWantWrite = false
        conn.readDeadline = timerDeadline(httpRecvTimeoutMs)
        try:
          selector.updateHandle(conn.fd, {Event.Read})
        except CatchableError:
          closeConn(conn)
      of 0, 2:
        conn.tlsHandshakeWantWrite = status == 2
        try:
          selector.updateHandle(conn.fd,
            {if conn.tlsHandshakeWantWrite: Event.Write else: Event.Read})
        except CatchableError:
          closeConn(conn)
      else:
        closeConn(conn)

    proc selectTimeoutMs(): int =
      ## Sleep in the kernel only as long as nothing else needs the loop:
      ## runnable fibers => 0; otherwise bounded by the nearest scheduler
      ## timer and the nearest connection/drain deadline.
      if hasRunnableFiber():
        return 0
      # A native worker (HTTP client, file I/O) settles its Task off-lane and
      # wakes the awaiting fiber without touching any socket here. Poll at the
      # scheduler's own 1 ms boundary while such work is in flight, or a
      # handler or root-lane task awaiting it stalls for the full idle wait.
      var timeout = if externalNativeOpsPending(): 1 else: 50
      let now = getMonoTime()
      template clampTo(deadline: MonoTime) =
        block:
          let ms = (deadline - now).inMilliseconds
          timeout = min(timeout, max(int(ms), 0))
      let nextTimer = nextTimerDeadline()
      if nextTimer.has:
        clampTo(nextTimer.deadline)
      if ticking:
        clampTo(nextTick)
      if draining:
        clampTo(drainDeadline)
      for conn in conns.values:
        case conn.phase
        of hcpTlsHandshake, hcpReading: clampTo(conn.readDeadline)
        of hcpDispatched:
          if conn.hasTaskDeadline: clampTo(conn.taskDeadline)
          if conn.streamingBody and conn.bodyWaitingForSocket:
            clampTo(conn.readDeadline)
            if conn.tlsConnection != nil and
                not conn.tlsReadNeedsSocket and
                rt.tls.hasPending(conn.tlsConnection) > 0:
              timeout = 0
        of hcpWriting: discard
        of hcpStreamingResponse:
          if conn.hasTaskDeadline: clampTo(conn.taskDeadline)
          if conn.streamingBody and conn.bodyWaitingForSocket:
            clampTo(conn.readDeadline)
            if conn.tlsConnection != nil and
                not conn.tlsReadNeedsSocket and
                rt.tls.hasPending(conn.tlsConnection) > 0:
              timeout = 0
          if conn.writePos >= conn.writeBuf.len and
              (conn.responseReadTask.kind != vkTask or
               conn.responseReadTask.taskDone) and
              (conn.responseCloseTask.kind != vkTask or
               conn.responseCloseTask.taskDone):
            timeout = 0
        of hcpWebSocket:
          clampTo(conn.wsPingDeadline)
          if conn.wsAwaitingPong: clampTo(conn.wsPongDeadline)
      timeout

    proc pumpScheduler() =
      ## Run ready fibers without letting schedulerRunOne sleep on timers —
      ## socket readiness must stay responsive while handlers are parked.
      # Async subprocess workers publish native results for this scheduler
      # lane to materialize. Poll before testing the run queue so a completed
      # curl can wake its channel receiver even when no socket event did.
      pollOsExecAsyncCompletions()
      discard wakeExpiredTimers()
      var budget = 128
      while budget > 0 and hasRunnableFiber():
        discard schedulerRunOne()
        dec budget

    proc wsBeginUpgrade(conn: HttpConn, marker: Value) =
      ## A handler returned (ws_accept req ...): write the 101 handshake;
      ## completeWrite hands the flushed socket to WebSocket mode.
      inc rt.completedRequests
      logAccess(conn, 101)
      conn.wsUpgrading = true
      conn.wsOnOpen = marker.props.getOrDefault("on_open", NIL)
      conn.wsOnMessage = marker.props.getOrDefault("on_message", NIL)
      conn.wsOnClose = marker.props.getOrDefault("on_close", NIL)
      var props = initPropTable()
      props["server_id"] = newInt(rt.id)
      props["fd"] = newInt(conn.fd)
      conn.wsValue = newNode(newSym("WsConn"), props = props)
      let protocol = marker.props.getOrDefault("protocol", NIL)
      let protocolLine =
        if protocol.kind == vkString:
          "Sec-WebSocket-Protocol: " & protocol.strVal & "\r\n"
        else: ""
      startWrite(conn,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" &
        "Connection: Upgrade\r\nSec-WebSocket-Accept: " &
        marker.props["ws_accept"].strVal & "\r\n" & protocolLine & "\r\n")

    proc harvest() =
      ## Settle finished handler tasks into responses; time out overdue ones.
      let now = getMonoTime()
      var settled: seq[HttpConn]
      var expiredReads: seq[HttpConn]
      var expiredStreams: seq[HttpConn]
      var wsPing: seq[HttpConn]
      var wsDead: seq[HttpConn]
      for conn in conns.values:
        case conn.phase
        of hcpDispatched:
          if conn.streamingBody and conn.bodyWaitingForSocket and
              now > conn.readDeadline:
            expiredReads.add conn
          elif conn.task.kind == vkTask and conn.task.taskDone:
            settled.add conn
          elif conn.hasTaskDeadline and now > conn.taskDeadline:
            settled.add conn
        of hcpTlsHandshake:
          if now > conn.readDeadline:
            expiredReads.add conn
        of hcpReading:
          if now > conn.readDeadline:
            expiredReads.add conn
        of hcpWriting:
          discard
        of hcpStreamingResponse:
          if (conn.hasTaskDeadline and now > conn.taskDeadline) or
              (conn.streamingBody and conn.bodyWaitingForSocket and
               now > conn.readDeadline):
            expiredStreams.add conn
        of hcpWebSocket:
          if conn.wsAwaitingPong and now > conn.wsPongDeadline:
            wsDead.add conn
          elif now > conn.wsPingDeadline:
            wsPing.add conn
      for conn in settled:
        if conn.inFlightCounted:
          dec rt.inFlight
          conn.inFlightCounted = false
        if conn.task.kind == vkTask and conn.task.taskDone:
          let task = conn.task
          if not (task.taskHasPanic or task.taskCancelled or
                  task.taskHasError) and
              task.taskResult.kind == vkNode and
              task.taskResult.props.hasKey("ws_accept"):
            wsBeginUpgrade(conn, task.taskResult)
          elif not (task.taskHasPanic or task.taskCancelled or
                    task.taskHasError) and
              task.taskResult.kind == vkNode and
              task.taskResult.head.bits ==
                httpNamespaceBinding(scope, "StreamResponse").bits:
            try:
              startStreamResponse(conn, task.taskResult)
            except CatchableError as error:
              HttpRuntimeLogger.emit(llError,
                "stream response setup failed: " & error.msg)
              closeResponseResources(conn)
              respondCounted(conn, 500, "Internal Server Error")
          else:
            let response = httpTaskResponsePayload(conn)
            logAccess(conn, response.status)
            startWrite(conn, response.payload)
        else:
          # Orphan the still-running task; its fiber settles into a task no
          # one reads. The client gets a definitive timeout answer.
          respondCounted(conn, 504, "Gateway Timeout")
      for conn in expiredReads:
        if conn.phase == hcpTlsHandshake:
          closeConn(conn)
          continue
        if conn.inFlightCounted:
          if conn.task.kind == vkTask and not conn.task.taskDone:
            discard nativeTaskCancel(conn.task, scope)
          dec rt.inFlight
          conn.inFlightCounted = false
        respondCounted(conn, 408, "Request Timeout")
      for conn in expiredStreams:
        if conn.fd in conns:
          inc rt.timeouts
          failStreamResponse(conn,
            if conn.streamingBody and conn.bodyWaitingForSocket and
                now > conn.readDeadline:
              "request body exceeded idle deadline"
            else: "stream response exceeded request deadline")
      for conn in wsDead:
        closeConn(conn)
      for conn in wsPing:
        wsAppendFrame(conn, wsEncodeFrame(0x9, ""))
        conn.wsPingDeadline = timerDeadline(wsPingIntervalMs)
        conn.wsAwaitingPong = true
        conn.wsPongDeadline = timerDeadline(wsPongGraceMs)
        wsFlushConn(conn)

    proc beginDrain() =
      ## Graceful stop: close the listener, drop connections that have not
      ## completed a request, and let in-flight work finish up to the drain
      ## deadline.
      draining = true
      drainDeadline = timerDeadline(drainTimeoutMs)
      try:
        selector.unregister(listenerFd)
      except CatchableError:
        discard
      server.close()
      rt.listening = false
      var idle: seq[HttpConn]
      for conn in conns.values:
        # WebSocket streams never block a drain: delivery has no response to
        # finish, so drop them with the idle readers.
        if conn.phase in [hcpTlsHandshake, hcpReading, hcpWebSocket]:
          idle.add conn
      for conn in idle:
        closeConn(conn)

    proc threadCpuNs(): int64 =
      var ts: Timespec
      discard clock_gettime(ClockId(CLOCK_THREAD_CPUTIME_ID), ts)
      int64(ts.tv_sec) * 1_000_000_000 + int64(ts.tv_nsec)

    try:
      withScopedScheduler(scope):
        var woke = getMonoTime()
        var wokeCpuNs = threadCpuNs()
        while maxRequests < 0 or served < maxRequests:
          if rt.stopRequested and not draining:
            beginDrain()
          if draining and (conns.len == 0 or getMonoTime() > drainDeadline):
            break
          let timeoutMs = selectTimeoutMs()
          let waitStart = getMonoTime()
          rt.loopWorkMs = int((waitStart - woke).inMilliseconds)
          rt.loopWorkCpuMs = int((threadCpuNs() - wokeCpuNs) div 1_000_000)
          rt.maxLoopWorkMs = max(rt.maxLoopWorkMs, rt.loopWorkMs)
          let events = selector.select(timeoutMs)
          woke = getMonoTime()
          wokeCpuNs = threadCpuNs()
          rt.waitOverrunMs =
            max(0, int((woke - waitStart).inMilliseconds) - timeoutMs)
          rt.maxWaitOverrunMs = max(rt.maxWaitOverrunMs, rt.waitOverrunMs)
          # Before the events, so a busy socket cannot starve the tick — and
          # once per period rather than once per missed period, because a
          # server that fell behind should not then run the world at double
          # speed to catch up.
          if ticking and getMonoTime() >= nextTick:
            nextTick = timerDeadline(tickMs)
            try:
              discard applyCall(onTick, [], NamedArgs(), scope)
            except CatchableError as e:
              # A throwing tick must not kill the server: it would take every
              # connected client with it, and the next tick may well succeed.
              stderr.writeLine("http/serve on_tick raised: " & e.msg)
          for ev in events:
            if ev.fd == listenerFd:
              if Event.Read in ev.events:
                acceptClients()
              continue
            if ev.fd notin conns:
              continue    # closed earlier in this same event batch
            let conn = conns[ev.fd]
            if Event.Error in ev.events:
              if conn.phase == hcpStreamingResponse:
                failStreamResponse(conn, "client closed during streamed response")
              else:
                closeConn(conn)
              continue
            case conn.phase
            of hcpTlsHandshake:
              if (conn.tlsHandshakeWantWrite and Event.Write in ev.events) or
                  (not conn.tlsHandshakeWantWrite and Event.Read in ev.events):
                advanceTlsHandshake(conn)
            of hcpReading:
              if (conn.tlsReadWantWrite and Event.Write in ev.events) or
                  (not conn.tlsReadWantWrite and Event.Read in ev.events):
                conn.tlsReadNeedsSocket = false
                handleReadable(conn)
                if conn.fd in conns and conn.phase == hcpReading:
                  selector.updateHandle(conn.fd,
                    {if conn.tlsReadWantWrite: Event.Write else: Event.Read})
            of hcpWriting:
              if (conn.tlsWriteWantRead and Event.Read in ev.events) or
                  (not conn.tlsWriteWantRead and Event.Write in ev.events):
                if tryFlush(conn):
                  completeWrite(conn)
                elif conn.fd in conns:
                  selector.updateHandle(conn.fd,
                    {if conn.tlsWriteWantRead: Event.Read else: Event.Write})
            of hcpStreamingResponse:
              if (conn.tlsReadWantWrite and Event.Write in ev.events) or
                  (not conn.tlsReadWantWrite and Event.Read in ev.events):
                conn.tlsReadNeedsSocket = false
                handleStreamingReadable(conn)
              if ((conn.tlsWriteWantRead and Event.Read in ev.events) or
                  (not conn.tlsWriteWantRead and Event.Write in ev.events)) and
                  conn.fd in conns and
                  conn.phase == hcpStreamingResponse:
                pumpStreamResponse(conn)
              if conn.fd in conns and conn.phase == hcpStreamingResponse:
                refreshStreamInterests(conn)
            of hcpWebSocket:
              if (conn.tlsWriteWantRead and Event.Read in ev.events) or
                  (not conn.tlsWriteWantRead and Event.Write in ev.events):
                wsFlushConn(conn)
              if conn.fd in conns and
                  ((conn.tlsReadWantWrite and Event.Write in ev.events) or
                   (not conn.tlsReadWantWrite and Event.Read in ev.events)):
                conn.tlsReadNeedsSocket = false
                handleWsReadable(conn)
              if conn.fd in conns and conn.phase == hcpWebSocket:
                var interests = {if conn.tlsReadWantWrite: Event.Write
                                 else: Event.Read}
                if conn.writePos < conn.writeBuf.len:
                  interests.incl (if conn.tlsWriteWantRead: Event.Read
                                  else: Event.Write)
                selector.updateHandle(conn.fd, interests)
            of hcpDispatched:
              if conn.streamingBody and
                  ((conn.tlsReadWantWrite and Event.Write in ev.events) or
                   (not conn.tlsReadWantWrite and Event.Read in ev.events)):
                conn.tlsReadNeedsSocket = false
                handleStreamingReadable(conn)
              if conn.fd in conns and conn.phase == hcpDispatched and
                  conn.streamingBody:
                refreshStreamInterests(conn)
          pumpScheduler()
          var bodyConns: seq[HttpConn]
          for conn in conns.values:
            if conn.streamingBody and
                conn.phase in {hcpDispatched, hcpStreamingResponse}:
              bodyConns.add conn
          for conn in bodyConns:
            if conn.fd in conns:
              pumpStreamingBody(conn)
              if conn.fd in conns and conn.streamingBody and
                  conn.bodyWaitingForSocket and conn.tlsConnection != nil and
                  not conn.tlsReadNeedsSocket and
                  rt.tls.hasPending(conn.tlsConnection) > 0:
                handleStreamingReadable(conn)
          var responseConns: seq[HttpConn]
          for conn in conns.values:
            if conn.phase == hcpStreamingResponse:
              responseConns.add conn
          for conn in responseConns:
            if conn.fd in conns:
              pumpStreamResponse(conn)
          wsReapPending()
          drainWsOutbound()
          harvest()
          pruneCleanupTasks()
    finally:
      var leftover: seq[HttpConn]
      for conn in conns.values:
        leftover.add conn
      forcedConnections = leftover.len
      for conn in leftover:
        closeConn(conn)
      try:
        selector.close()
      except CatchableError:
        discard
      closeHttpPool(pool)
      let cleanupDeadline =
        if draining: drainDeadline else: timerDeadline(drainTimeoutMs)
      while true:
        withScopedScheduler(scope):
          pumpScheduler()
        pruneCleanupTasks()
        let snapshot = app.ioBudget.ioBudgetSnapshot()
        remainingCleanupLeases = max(0, snapshot.cleanupLeases -
          initialCleanupLeases)
        remainingFileResources = max(0,
          app.ioFileOpenCount() - initialFileResources)
        if remainingCleanupLeases == 0 and remainingFileResources == 0 and
            cleanupTasks.len == 0 or
            getMonoTime() >= cleanupDeadline:
          break
        sleep(1)
      rt.serving = false
      dropHttpRuntime(rt)
      if ownRegistration:
        args[0].setNodeProp("listener", VOID)   # void deletes the prop
    var shutdown = initPropTable()
    shutdown["complete"] = newBool(remainingCleanupLeases == 0 and
      remainingFileResources == 0 and cleanupTasks.len == 0 and
      not cleanupTaskFailed)
    shutdown["graceful"] = newBool(forcedConnections == 0)
    shutdown["forced_connections"] = newInt(forcedConnections)
    shutdown["cleanup_leases"] = newInt(remainingCleanupLeases)
    shutdown["open_io_resources"] = newInt(remainingFileResources)
    shutdown["pending_cleanup_tasks"] = newInt(cleanupTasks.len)
    shutdown["close_failed"] = newBool(cleanupTaskFailed)
    shutdown["served_requests"] = newInt(served)
    newMap(shutdown)
  else:
    raiseHttpError("http/serve requires a native posix build", scope)
    NIL

# --- response helpers --------------------------------------------------------
#
# 1-arg forms keep their original implicit statuses (spec-locked); 2-arg forms
# are status-first per the async-http-server proposal's compatibility rule.

proc httpHelperParts(name: string, args: openArray[Value],
                     defaultStatus: int): tuple[status: int, body: string] =
  if args.len == 1:
    requireStr(name, args[0])
    return (defaultStatus, args[0].strVal)
  if args.len == 2:
    let status = int(requireInt64(name & " status", args[0]))
    requireStr(name, args[1])
    return (status, args[1].strVal)
  raise newException(GeneError,
    name & " expects (body) or (status, body), got " & $args.len &
    " arguments")

proc biHttpText(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  let (status, body) = httpHelperParts("http/text", args, 200)
  newHttpResponseValue(scope, status, body, "text/plain; charset=utf-8")

proc biHttpHtml(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  let (status, body) = httpHelperParts("http/html", args, 200)
  newHttpResponseValue(scope, status, body, "text/html; charset=utf-8")

proc biHttpJson(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  let (status, body) = httpHelperParts("http/json", args, 200)
  newHttpResponseValue(scope, status, body, "application/json")

proc biHttpBytes(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (bytes status bytes-or-str) — binary response body
  ## (application/octet-stream unless a header overrides it).
  if args.len != 2:
    raise newException(GeneError,
      "http/bytes expects (status, bytes), got " & $args.len & " arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  let status = int(requireInt64("http/bytes status", args[0]))
  let body =
    if args[1].kind == vkBytes: args[1].bytesVal
    elif args[1].kind == vkString: args[1].strVal
    else:
      raise newException(GeneError, "http/bytes expects a Bytes or Str body")
  newHttpResponseValue(scope, status, body, "application/octet-stream")

proc biHttpStream(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if scope == nil or args.len notin [1, 2]:
    raiseHttpError("http/stream expects (reader) or (status, reader)", scope)
  let status = if args.len == 1: 200
               else: int(requireInt64("http/stream status", args[0]))
  if status < 200 or status > 599 or status in [204, 205, 304]:
    raiseHttpError("http/stream status must permit a body", scope)
  let reader = args[^1]
  let ioScope = scope.application().stdlib.vars["io"].nsScope
  if not scope.typeImplementsProtocol(projectHead(reader),
                                      ioScope.vars["AsyncReader"]):
    raiseHttpError("http/stream body must implement AsyncReader", scope)
  var contentType = "application/octet-stream"
  var extraHeaders = NIL
  var knownLength = -1
  var maxBytes = 64 * 1024 * 1024
  var ownReader = false
  var seen = initHashSet[string]()
  if call != nil:
    for i, name in call[].namedNames:
      if name in seen:
        raiseHttpError("http/stream got duplicate named argument: " & name,
                       scope)
      seen.incl name
      let value = call[].namedValues[i]
      case name
      of "content_type":
        requireStr("http/stream ^content_type", value)
        contentType = value.strVal
      of "headers":
        if value.kind != vkMap:
          raiseHttpError("http/stream ^headers must be a Map", scope)
        extraHeaders = value
      of "content_length":
        knownLength = int(requireInt64("http/stream ^content_length", value))
      of "max_bytes":
        maxBytes = int(requireInt64("http/stream ^max_bytes", value))
      of "own_reader":
        if value.kind != vkBool:
          raiseHttpError("http/stream ^own_reader must be Bool", scope)
        ownReader = value.boolVal
      else:
        raiseHttpError("http/stream got unexpected named argument: " & name,
                       scope)
  if maxBytes < 1 or maxBytes > 1_073_741_824 or
      knownLength < -1 or knownLength > maxBytes:
    raiseHttpError("http/stream byte limits are invalid", scope)
  if ownReader and not scope.typeImplementsProtocol(projectHead(reader),
                                                     ioScope.vars["IoResource"]):
    raiseHttpError("owned stream body must implement IoResource", scope)
  var headers = initPropTable()
  headers["content-type"] = newStr(contentType)
  var headerBytes = 0
  if extraHeaders.kind == vkMap:
    if extraHeaders.mapEntries.len > 256:
      raiseHttpError("http/stream accepts at most 256 headers", scope)
    for key, value in extraHeaders.mapEntries:
      if value.kind != vkString:
        raiseHttpError("http/stream header values must be Str", scope)
      let lower = key.toLowerAscii()
      if key.len == 0 or lower in
          ["content-length", "transfer-encoding", "connection"]:
        raiseHttpError("http/stream header name is reserved or empty", scope)
      for ch in key:
        if not (ch in {'A'..'Z', 'a'..'z', '0'..'9'} or
                ch in "!#$%&'*+-.^_`|~"):
          raiseHttpError("http/stream header name is invalid", scope)
      for ch in value.strVal:
        if ch == '\r' or ch == '\n' or ch == '\x7f' or
            (ch < ' ' and ch != '\t'):
          raiseHttpError("http/stream header value is invalid", scope)
      headerBytes += key.len + value.strVal.len + 4
      if headerBytes > 256 * 1024:
        raiseHttpError("http/stream headers exceed 256 KiB", scope)
      headers[lower] = value
  for ch in contentType:
    if ch == '\r' or ch == '\n' or ch == '\x7f' or
        (ch < ' ' and ch != '\t'):
      raiseHttpError("http/stream content type is invalid", scope)
  if contentType.len + headerBytes > 256 * 1024:
    raiseHttpError("http/stream headers exceed 256 KiB", scope)
  var props = initPropTable()
  props["status"] = newInt(status)
  props["headers"] = newMap(headers)
  props["body"] = reader
  if knownLength >= 0: props["content_length"] = newInt(knownLength)
  props["max_bytes"] = newInt(maxBytes)
  props["own_reader"] = newBool(ownReader)
  newNode(httpNamespaceBinding(scope, "StreamResponse"),
          props = props, immutable = true)

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
  let scope = if call == nil: nil else: call[].dispatchScope
  var status = 302
  var location: Value
  if args.len == 1:
    requireStr("http/redirect", args[0])
    location = args[0]
  elif args.len == 2:
    status = int(requireInt64("http/redirect status", args[0]))
    requireStr("http/redirect", args[1])
    location = args[1]
  else:
    raise newException(GeneError,
      "http/redirect expects (location) or (status, location), got " &
      $args.len & " arguments")
  var props = initPropTable()
  props["status"] = newInt(status)
  var headers = initPropTable()
  headers["location"] = location
  props["headers"] = newMap(headers)
  let head = httpNamespaceBinding(scope, "Response")
  newNode(if head.kind == vkType: head else: newSym("Response"),
          props = props, body = @[newStr("")])
