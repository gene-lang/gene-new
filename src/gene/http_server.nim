# --- net/http event-loop server (docs/proposals/async-http-server.md) ---
#
# Included by stdlib.nim (which is included by vm.nim), so this file may use
# VM internals directly: fibers, the non-sleeping scheduler probes, actor
# mailboxes, and ReplyTo. Dispatch models:
#
#   task-per-request (default) — each parsed request runs the handler as a
#     scheduler fiber settling a pending Task; a handler that sleeps/awaits
#     parks without stalling other connections.
#   actor-pool (explicit)      — requests become RequestMsg values dispatched
#     round-robin to a fixed pool of worker actors with bounded mailboxes and
#     native-created ReplyTo; full mailboxes answer 503.

const httpMaxBodyBytes = 10 * 1024 * 1024
const httpMaxHeaderLines = 128
const httpMaxHeaderBytes = 32 * 1024
const httpRecvTimeoutMs = 10_000
const httpReadChunkBytes = 8 * 1024
const httpDefaultRequestTimeoutMs = 30_000
const httpDefaultMaxConnections = 1024
const httpDefaultMaxInFlight = 256
const httpDefaultDrainTimeoutMs = 5_000
const httpDefaultPoolWorkers = 4
const httpDefaultPoolMailbox = 64

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
  of 408: "Request Timeout"
  of 413: "Payload Too Large"
  of 500: "Internal Server Error"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
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

proc parseHttpRequestBuffer(buf: string, maxBodyBytes: int, scope: Scope):
    tuple[status: HttpParseStatus, value: Value] =
  ## Incremental HTTP/1.1 request parser over a connection's accumulated
  ## bytes. Same validation rules as the previous blocking socket parser:
  ## bounded header lines/bytes, bounded content-length body, malformed
  ## requests answer 400. Strict `\r\n` line endings (what real clients send).
  let headerEnd = buf.find("\r\n\r\n")
  if headerEnd < 0:
    if buf.len > httpMaxHeaderBytes:
      return (hpsBad, VOID)
    return (hpsNeedMore, VOID)
  if headerEnd > httpMaxHeaderBytes:
    return (hpsBad, VOID)
  let lines = buf[0 ..< headerEnd].split("\r\n")
  if lines.len == 0 or lines.len - 1 > httpMaxHeaderLines:
    return (hpsBad, VOID)
  let lineParts = lines[0].split(' ')
  if lineParts.len != 3 or not lineParts[2].startsWith("HTTP/"):
    return (hpsBad, VOID)
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
  for i in 1 ..< lines.len:
    let line = lines[i]
    let colon = line.find(':')
    if colon <= 0:
      return (hpsBad, VOID)
    let key = line[0 ..< colon].strip().toLowerAscii()
    let val = line[colon + 1 .. ^1].strip()
    headers[key] = newStr(val)
    if key == "content-length":
      try:
        contentLength = parseInt(val)
      except ValueError:
        return (hpsBad, VOID)
      if contentLength < 0:
        return (hpsBad, VOID)
      if maxBodyBytes >= 0 and contentLength > maxBodyBytes:
        return (hpsTooLarge, VOID)   # 413 per async-http-server proposal §9
  let bodyStart = headerEnd + 4
  if buf.len < bodyStart + contentLength:
    return (hpsNeedMore, VOID)
  let body = buf[bodyStart ..< bodyStart + contentLength]
  var params: OrderedTable[string, Value]
  try:
    params = parseQueryEntries(query, scope)
  except GeneError:
    return (hpsBad, VOID)   # malformed percent escape is the client's fault
  var props = initOrderedTable[string, Value]()
  props["method"] = newStr(httpMethod)
  props["path"] = newStr(path)
  props["query"] = newStr(query)
  props["params"] = newMap(params)
  props["headers"] = newMap(headers)
  props["body"] = newStr(body)
  let head = httpNamespaceBinding(scope, "Request")
  (hpsDone, newNode(if head.kind == vkType: head else: newSym("Request"),
                    props = props))

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

# --- server runtime registry: listen / stop / status -----------------------
#
# A Server value carries a `^listener Int` handle into this registry so that
# handlers (which receive no server reference of their own) can reach the
# running server through the same Server node the application holds.

type
  HttpServerRuntime = ref object
    id: int
    host: string
    port: int
    listener: Socket
    listening: bool         # listener socket is live
    serving: bool           # event loop currently running
    stopRequested: bool
    workers: int            # actor-pool size (0 for task-per-request)
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

var gHttpServerRegistry = initTable[int, HttpServerRuntime]()
var gHttpServerNextId = 0

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
                         listening: bool): HttpServerRuntime =
  inc gHttpServerNextId
  result = HttpServerRuntime(id: gHttpServerNextId, host: host, port: port,
                             listener: listener, listening: listening)
  gHttpServerRegistry[result.id] = result

proc dropHttpRuntime(rt: HttpServerRuntime) =
  if rt == nil:
    return
  if rt.listening:
    rt.listener.close()
    rt.listening = false
  gHttpServerRegistry.del(rt.id)

proc biHttpListen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (listen ^host "0.0.0.0" ^port 8080) or (listen server) — bind a listener
  ## now and return a Server value carrying the runtime handle. The returned
  ## value works with serve/stop/status; binding eagerly makes the listener a
  ## value the application explicitly owns (the capability-shaped surface).
  if args.len > 1:
    raise newException(GeneError,
      "http/listen expects at most one Server argument")
  let scope = if call == nil: nil else: call[].dispatchScope
  if call != nil:
    for name in call[].namedNames:
      if name notin ["host", "port"]:
        raise newException(GeneError,
          "http/listen got unexpected named argument: " & name)
  let (host, port) = httpServerHostPort(args, call, "http/listen", scope)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let listener = httpBindListener(host, port, scope)
    let rt = registerHttpRuntime(host, port, listener, listening = true)
    var props = initOrderedTable[string, Value]()
    props["host"] = newStr(host)
    props["port"] = newInt(port)
    props["listener"] = newInt(rt.id)
    let head = httpNamespaceBinding(scope, "Server")
    newNode(if head.kind == vkType: head else: newSym("Server"),
            props = props)
  else:
    raiseHttpError("http/listen requires a native posix build", scope)
    NIL

proc biHttpStop(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (stop server) — request a graceful stop: the serve loop stops accepting,
  ## drains in-flight requests up to ^drain-timeout-ms, then returns. Valid on
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
  var props = initOrderedTable[string, Value]()
  props["host"] = newStr(rt.host)
  props["port"] = newInt(rt.port)
  props["serving"] = newBool(rt.serving)
  props["stopping"] = newBool(rt.stopRequested)
  props["workers"] = newInt(rt.workers)
  props["active_connections"] = newInt(rt.activeConnections)
  props["in_flight_requests"] = newInt(rt.inFlight)
  props["accepted_connections"] = newInt(rt.acceptedConnections)
  props["completed_requests"] = newInt(rt.completedRequests)
  props["failed_requests"] = newInt(rt.failedRequests)
  props["overloaded_requests"] = newInt(rt.overloadedRequests)
  props["timeouts"] = newInt(rt.timeouts)
  props["bad_requests"] = newInt(rt.badRequests)
  props["bytes_read"] = newInt(rt.bytesRead)
  props["bytes_written"] = newInt(rt.bytesWritten)
  newNode(newSym("Status"), props = props)

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
  var props = initOrderedTable[string, Value]()
  props["method"] = methodVal
  props["path"] = pathVal
  props["handler"] = handlerVal
  newNode(newSym("Route"), props = props)

proc biHttpActorPool(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (actor-pool ^workers 8 ^mailbox 64 ^init make-state ^handle worker-fn)
  ## — dispatch-mode configuration for serve's ^dispatch.
  if args.len != 0:
    raise newException(GeneError,
      "http/actor-pool expects named arguments only")
  var workers = httpDefaultPoolWorkers
  var mailbox = httpDefaultPoolMailbox
  var initFn = NIL
  var handleFn = NIL
  if call != nil:
    for name in call[].namedNames:
      if name notin ["workers", "mailbox", "init", "handle"]:
        raise newException(GeneError,
          "http/actor-pool got unexpected named argument: " & name)
    let wIndex = nativeNamedIndex(call, "workers")
    if wIndex >= 0:
      workers = int(requireInt64("http/actor-pool workers",
                                 call[].namedValues[wIndex]))
    let mIndex = nativeNamedIndex(call, "mailbox")
    if mIndex >= 0:
      mailbox = int(requireInt64("http/actor-pool mailbox",
                                 call[].namedValues[mIndex]))
    let iIndex = nativeNamedIndex(call, "init")
    if iIndex >= 0:
      initFn = call[].namedValues[iIndex]
    let hIndex = nativeNamedIndex(call, "handle")
    if hIndex >= 0:
      handleFn = call[].namedValues[hIndex]
  if workers < 1:
    raise newException(GeneError, "http/actor-pool workers must be >= 1")
  if mailbox < 1:
    raise newException(GeneError, "http/actor-pool mailbox must be >= 1")
  if initFn.kind == vkNil or handleFn.kind == vkNil:
    raise newException(GeneError,
      "http/actor-pool requires ^init and ^handle")
  var props = initOrderedTable[string, Value]()
  props["workers"] = newInt(workers)
  props["mailbox"] = newInt(mailbox)
  props["init"] = initFn
  props["handle"] = handleFn
  newNode(newSym("ActorPool"), props = props)

type
  HttpRouteEntry = object
    methodS: string          # "*" matches any method
    path: string
    handler: Value

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
      result.add HttpRouteEntry(methodS: m,
                                path: entry.props["path"].strVal,
                                handler: entry.props["handler"])
    elif entry.kind == vkList and entry.listItems.len == 3:
      requireStr("route method", entry.listItems[0])
      requireStr("route path", entry.listItems[1])
      result.add HttpRouteEntry(methodS: entry.listItems[0].strVal,
                                path: entry.listItems[1].strVal,
                                handler: entry.listItems[2])
    else:
      raiseHttpError("route entries must be (route ^method ^path ^handler) " &
                     "nodes or [method path handler] lists", scope)

proc httpMatchRoute(entries: seq[HttpRouteEntry],
                    request: Value): tuple[found: bool, handler: Value] =
  ## Exact path match; method "*" is a wildcard. Path patterns are deferred.
  let props = request.props
  let methodS = props["method"].strVal
  let path = props["path"].strVal
  for entry in entries:
    if entry.path == path and (entry.methodS == "*" or
        entry.methodS == methodS):
      return (true, entry.handler)
  (false, NIL)

# --- request dispatch --------------------------------------------------------

type
  HttpActorPool = ref object
    workers: seq[Value]     # ActorRef values, round-robin
    cursor: int

proc dispatchHttpHandler(handler, request: Value, scope: Scope): Value =
  ## Run the handler for one request, task-per-request style. A plain Gene
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

proc dispatchHttpToPool(pool: HttpActorPool, request: Value,
                        scope: Scope): tuple[task: Value, overloaded: bool] =
  ## Wrap the request in a RequestMsg with a native-created ReplyTo and
  ## try-send it round-robin across the pool. Every worker full => overload.
  ##
  ## The message intentionally bypasses checkedActorMessage's Send validation:
  ## Request values carry (mutable) header/param maps, and this native edge is
  ## the single producer handing each request to exactly one consumer. The
  ## worker lane still re-verifies sendability before moving any fiber off the
  ## scheduler thread (actorFiberWorkerSafe), so unsendable messages simply
  ## stay on the cooperative lane.
  let task = newPendingTask()
  let reply = newReplyTo(task = task)
  var props = initOrderedTable[string, Value]()
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

proc httpSpawnPool(config: Value, scope: Scope): HttpActorPool =
  ## Spawn the worker actors for an actor-pool dispatch config. Workers use
  ## restart supervision: a failed handler produces a failure event path via
  ## the actor runtime and the worker state is rebuilt with ^init.
  let props = config.props
  let workers = int(requireInt64("actor-pool workers", props["workers"]))
  let mailbox = int(requireInt64("actor-pool mailbox", props["mailbox"]))
  let initFn = props["init"]
  let handleFn = props["handle"]
  result = HttpActorPool()
  for _ in 0 ..< workers:
    let state = applyCall(initFn, [], NamedArgs(), scope)
    result.workers.add newActorRef(mailbox, state, handleFn, NIL,
                                   restartInit = initFn,
                                   failureStrategy = afsRestart)

proc closeHttpPool(pool: HttpActorPool) =
  if pool == nil:
    return
  for worker in pool.workers:
    closeActorAndCancelMailbox(worker)

proc httpErrorFallbackNode(task: Value): Value =
  ## Error value for the ^on-error mapper: the task's error value when the
  ## handler failed with one, else an (Error ^message ...) node — the same
  ## shape catch clauses see for message-only errors.
  if task.taskHasErrorValue:
    return task.taskErrorValue
  var props = initOrderedTable[string, Value]()
  props["message"] = newStr(task.taskErrorMsg)
  newNode(newSym("Error"), props = props)

# --- the event loop ----------------------------------------------------------

type
  HttpConnPhase = enum
    hcpReading      # accumulating request bytes
    hcpDispatched   # handler task in flight; response not yet started
    hcpWriting      # flushing response bytes

  HttpConn = ref object
    sock: Socket
    fd: int
    phase: HttpConnPhase
    buf: string             # accumulated request bytes
    task: Value             # pending handler task; NIL after 504 orphaning
    readDeadline: MonoTime  # header/body arrival deadline (slowloris guard)
    taskDeadline: MonoTime  # handler completion deadline
    hasTaskDeadline: bool
    writeBuf: string
    writePos: int

proc biHttpServe(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  ## (serve server handler) / (serve server ^handler h) /
  ## (serve server ^routes [...]) — run the event loop on this task until
  ## ^max-requests is reached or (stop server) drains it.
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
  var requestTimeoutMs = httpDefaultRequestTimeoutMs
  var drainTimeoutMs = httpDefaultDrainTimeoutMs
  var handler = if args.len == 2: args[1] else: NIL
  var routes: Value = NIL
  var onError: Value = NIL
  var dispatchConfig: Value = NIL
  var overloadResponse: Value = NIL
  if call != nil:
    for name in call[].namedNames:
      if name notin ["max-requests", "max-connections", "max-in-flight",
                     "max-body-bytes", "request-timeout-ms",
                     "drain-timeout-ms", "handler", "routes", "on-error",
                     "dispatch", "overload-response"]:
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
    namedInt("max-requests", maxRequests)
    namedInt("max-connections", maxConnections)
    namedInt("max-in-flight", maxInFlight)
    namedInt("max-body-bytes", maxBodyBytes)
    namedInt("request-timeout-ms", requestTimeoutMs)
    namedInt("drain-timeout-ms", drainTimeoutMs)
    namedVal("handler", handler)
    namedVal("routes", routes)
    namedVal("on-error", onError)
    namedVal("dispatch", dispatchConfig)
    namedVal("overload-response", overloadResponse)
  var poolConfig: Value = NIL
  if dispatchConfig.kind != vkNil:
    if dispatchConfig.kind == vkNode and
        dispatchConfig.props.hasKey("workers") and
        dispatchConfig.props.hasKey("handle"):
      poolConfig = dispatchConfig
    elif dispatchConfig.kind == vkSymbol and
        dispatchConfig.symVal == "task-per-request":
      discard   # the default
    else:
      raiseHttpError("http/serve ^dispatch expects task-per-request or an " &
                     "(actor-pool ...) value", scope)
  var routeEntries: seq[HttpRouteEntry]
  let usingRoutes = routes.kind != vkNil
  if usingRoutes:
    if handler.kind != vkNil:
      raiseHttpError("http/serve takes either a handler or ^routes, not both",
                     scope)
    if poolConfig.kind != vkNil:
      raiseHttpError("http/serve ^dispatch actor-pool replaces the handler; " &
                     "route inside the pool's ^handle", scope)
    routeEntries = httpParseRouteEntries(routes, scope)
  elif handler.kind == vkNil and poolConfig.kind == vkNil:
    raiseHttpError("http/serve requires a handler, ^routes, or an " &
                   "actor-pool ^dispatch", scope)
  # ^overload-response customizes what 503 paths answer (proposal §9). Render
  # the wire bytes once up front: overload handling must stay allocation-light
  # and a bad response value should fail serve, not the overloaded request.
  var overloadWire = simpleHttpWirePayload(503, "Service Unavailable")
  if overloadResponse.kind != vkNil:
    let wire = responseWireParts(overloadResponse, scope)
    overloadWire = httpWirePayload(wire.status, wire.body, wire.headers)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    # Resolve the server runtime: reuse a listen-created listener, or bind
    # here. Either way the runtime is registered while serving so handlers
    # can reach stop/status through the Server value.
    var rt = httpRuntimeFor(args[0])
    var ownRegistration = false
    if rt == nil:
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
      pool = httpSpawnPool(poolConfig, scope)
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

    proc unregisterConn(conn: HttpConn) =
      try:
        selector.unregister(conn.fd)
      except OSError, IOSelectorsException:
        discard
      except CatchableError:
        discard

    proc closeConn(conn: HttpConn) =
      unregisterConn(conn)
      conns.del(conn.fd)
      conn.sock.close()
      rt.activeConnections = conns.len

    proc finishServed(conn: HttpConn) =
      ## A connection that produced a response (any status) consumes one
      ## request slot, matching the old per-connection `served` counting.
      inc served
      closeConn(conn)

    proc tryFlush(conn: HttpConn): bool =
      ## Flush as much of the response as the socket accepts. True when the
      ## payload is fully written or the connection is beyond saving.
      while conn.writePos < conn.writeBuf.len:
        let remaining = conn.writeBuf.len - conn.writePos
        let n = send(SocketHandle(conn.fd),
                     addr conn.writeBuf[conn.writePos],
                     remaining.cint, sendFlags)
        if n > 0:
          conn.writePos += n
          rt.bytesWritten += n
        elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
          return false
        elif n < 0 and errno == EINTR:
          continue
        else:
          return true    # client went away mid-response; keep serving
      true

    proc startWrite(conn: HttpConn, payload: string) =
      conn.writeBuf = payload
      conn.writePos = 0
      conn.phase = hcpWriting
      conn.task = NIL
      if tryFlush(conn):
        finishServed(conn)
      else:
        try:
          selector.updateHandle(conn.fd, {Event.Write})
        except CatchableError:
          finishServed(conn)

    proc respondCounted(conn: HttpConn, status: int, body: string) =
      case status
      of 400, 413: inc rt.badRequests
      of 408, 504: inc rt.timeouts
      of 503: inc rt.overloadedRequests
      of 500: inc rt.failedRequests
      else: discard
      startWrite(conn, simpleHttpWirePayload(status, body))

    proc respondOverloaded(conn: HttpConn) =
      ## Admission-limit answer: the (possibly customized) overload response.
      inc rt.overloadedRequests
      startWrite(conn, overloadWire)

    proc httpTaskResponsePayload(conn: HttpConn): string =
      ## Wire payload for a settled handler task. Failed tasks go through the
      ## ^on-error mapper when one is configured; panics and cancellation stay
      ## generic 500s (stderr diagnostics preserved from the old server).
      let task = conn.task
      if task.taskHasPanic:
        stderr.writeLine "http/serve handler panic: " & task.taskPanicMsg
        inc rt.failedRequests
        return simpleHttpWirePayload(500, "Internal Server Error")
      if task.taskCancelled:
        stderr.writeLine "http/serve handler cancelled"
        inc rt.failedRequests
        return simpleHttpWirePayload(500, "Internal Server Error")
      if task.taskHasError:
        if onError.kind != vkNil:
          try:
            let mapped = applyCall(onError, [httpErrorFallbackNode(task)],
                                   NamedArgs(), scope)
            let wire = responseWireParts(mapped, scope)
            inc rt.completedRequests
            return httpWirePayload(wire.status, wire.body, wire.headers)
          except GeneError as e:
            stderr.writeLine "http/serve on-error mapper error: " & e.msg
          except GenePanic as e:
            stderr.writeLine "http/serve on-error mapper panic: " & e.msg
        stderr.writeLine "http/serve handler error: " & task.taskErrorMsg
        inc rt.failedRequests
        return simpleHttpWirePayload(500, "Internal Server Error")
      try:
        let wire = responseWireParts(task.taskResult, scope)
        inc rt.completedRequests
        httpWirePayload(wire.status, wire.body, wire.headers)
      except GeneError as e:
        stderr.writeLine "http/serve handler error: " & e.msg
        inc rt.failedRequests
        simpleHttpWirePayload(500, "Internal Server Error")

    proc dispatchConn(conn: HttpConn, request: Value) =
      if maxInFlight > 0 and rt.inFlight >= maxInFlight:
        respondOverloaded(conn)
        return
      var routed = handler
      if usingRoutes:
        let match = httpMatchRoute(routeEntries, request)
        if not match.found:
          inc rt.completedRequests
          startWrite(conn, simpleHttpWirePayload(404, "Not Found"))
          return
        routed = match.handler
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
      except GeneError as e:
        stderr.writeLine "http/serve handler error: " & e.msg
        respondCounted(conn, 500, "Internal Server Error")
      except GenePanic as e:
        stderr.writeLine "http/serve handler panic: " & e.msg
        respondCounted(conn, 500, "Internal Server Error")

    proc handleReadable(conn: HttpConn) =
      var chunk = newString(httpReadChunkBytes)
      while true:
        let n = recv(SocketHandle(conn.fd), addr chunk[0],
                     httpReadChunkBytes.cint, 0)
        if n > 0:
          let start = conn.buf.len
          conn.buf.setLen(start + n)
          copyMem(addr conn.buf[start], addr chunk[0], n)
          rt.bytesRead += n
          if n < httpReadChunkBytes:
            break
        elif n == 0:
          closeConn(conn)      # EOF before a complete request
          return
        elif errno == EAGAIN or errno == EWOULDBLOCK:
          break
        elif errno == EINTR:
          continue
        else:
          closeConn(conn)
          return
      let parsed = parseHttpRequestBuffer(conn.buf, maxBodyBytes, scope)
      case parsed.status
      of hpsNeedMore:
        discard
      of hpsBad:
        respondCounted(conn, 400, "Bad Request")
      of hpsTooLarge:
        respondCounted(conn, 413, "Payload Too Large")
      of hpsDone:
        dispatchConn(conn, parsed.value)

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
        let conn = HttpConn(sock: client, fd: fd, phase: hcpReading,
                            task: NIL,
                            readDeadline: timerDeadline(httpRecvTimeoutMs))
        conns[fd] = conn
        rt.activeConnections = conns.len
        try:
          selector.registerHandle(SocketHandle(fd), {Event.Read}, 0)
        except CatchableError:
          conns.del(fd)
          rt.activeConnections = conns.len
          client.close()

    proc selectTimeoutMs(): int =
      ## Sleep in the kernel only as long as nothing else needs the loop:
      ## runnable fibers => 0; otherwise bounded by the nearest scheduler
      ## timer and the nearest connection/drain deadline.
      if hasRunnableFiber():
        return 0
      var timeout = 50
      let now = getMonoTime()
      template clampTo(deadline: MonoTime) =
        block:
          let ms = (deadline - now).inMilliseconds
          timeout = min(timeout, max(int(ms), 0))
      let nextTimer = nextTimerDeadline()
      if nextTimer.has:
        clampTo(nextTimer.deadline)
      if draining:
        clampTo(drainDeadline)
      for conn in conns.values:
        case conn.phase
        of hcpReading: clampTo(conn.readDeadline)
        of hcpDispatched:
          if conn.hasTaskDeadline: clampTo(conn.taskDeadline)
        of hcpWriting: discard
      timeout

    proc pumpScheduler() =
      ## Run ready fibers without letting schedulerRunOne sleep on timers —
      ## socket readiness must stay responsive while handlers are parked.
      discard wakeExpiredTimers()
      var budget = 128
      while budget > 0 and hasRunnableFiber():
        discard schedulerRunOne()
        dec budget

    proc harvest() =
      ## Settle finished handler tasks into responses; time out overdue ones.
      let now = getMonoTime()
      var settled: seq[HttpConn]
      var expiredReads: seq[HttpConn]
      for conn in conns.values:
        case conn.phase
        of hcpDispatched:
          if conn.task.kind == vkTask and conn.task.taskDone:
            settled.add conn
          elif conn.hasTaskDeadline and now > conn.taskDeadline:
            settled.add conn
        of hcpReading:
          if now > conn.readDeadline:
            expiredReads.add conn
        of hcpWriting:
          discard
      for conn in settled:
        dec rt.inFlight
        if conn.task.kind == vkTask and conn.task.taskDone:
          startWrite(conn, httpTaskResponsePayload(conn))
        else:
          # Orphan the still-running task; its fiber settles into a task no
          # one reads. The client gets a definitive timeout answer.
          respondCounted(conn, 504, "Gateway Timeout")
      for conn in expiredReads:
        respondCounted(conn, 408, "Request Timeout")

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
        if conn.phase == hcpReading:
          idle.add conn
      for conn in idle:
        closeConn(conn)

    try:
      withScopedScheduler(scope):
        while maxRequests < 0 or served < maxRequests:
          if rt.stopRequested and not draining:
            beginDrain()
          if draining and (conns.len == 0 or getMonoTime() > drainDeadline):
            break
          let events = selector.select(selectTimeoutMs())
          for ev in events:
            if ev.fd == listenerFd:
              if Event.Read in ev.events:
                acceptClients()
              continue
            if ev.fd notin conns:
              continue    # closed earlier in this same event batch
            let conn = conns[ev.fd]
            if Event.Error in ev.events:
              closeConn(conn)
              continue
            case conn.phase
            of hcpReading:
              if Event.Read in ev.events:
                handleReadable(conn)
            of hcpWriting:
              if Event.Write in ev.events:
                if tryFlush(conn):
                  finishServed(conn)
            of hcpDispatched:
              discard    # not watching; response path re-arms the fd
          pumpScheduler()
          harvest()
    finally:
      var leftover: seq[HttpConn]
      for conn in conns.values:
        leftover.add conn
      for conn in leftover:
        closeConn(conn)
      try:
        selector.close()
      except CatchableError:
        discard
      closeHttpPool(pool)
      rt.serving = false
      dropHttpRuntime(rt)
      if ownRegistration:
        args[0].setNodeProp("listener", VOID)   # void deletes the prop
    NIL
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
  var props = initOrderedTable[string, Value]()
  props["status"] = newInt(status)
  var headers = initOrderedTable[string, Value]()
  headers["location"] = location
  props["headers"] = newMap(headers)
  let head = httpNamespaceBinding(scope, "Response")
  newNode(if head.kind == vkType: head else: newSym("Response"),
          props = props, body = @[newStr("")])
