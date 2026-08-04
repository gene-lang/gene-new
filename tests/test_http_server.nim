## E2E tests for the net/http event-loop server (task_per_request dispatch).
##
## Each test starts the gene CLI as a child process running `serve` with
## `^max_requests` for self-termination, then talks to it over raw blocking
## client sockets. The concurrency test is the core contract: a handler parked
## in `sleep` must not stall other requests.

import std/[monotimes, net, os, osproc, streams, strutils, times, unittest]
import gene/[repl, vm]

let httpTestDir = getTempDir() / "gene_http_tests"
let httpGeneExe = httpTestDir / "gene-http-test-bin"
var httpGeneBuilt = false

proc buildHttpGene() =
  if httpGeneBuilt:
    return
  createDir(httpTestDir)
  let build = execCmdEx("nim c --path:src --hints:off -o:" & httpGeneExe &
                        " src/gene.nim")
  if build.exitCode != 0:
    checkpoint build.output
  check build.exitCode == 0
  httpGeneBuilt = true

proc startHttpServer(name, src: string): Process =
  buildHttpGene()
  let path = httpTestDir / name
  writeFile(path, src)
  startProcess(httpGeneExe, args = ["run", path],
               options = {poUsePath, poStdErrToStdOut})

proc httpConnect(port: int): Socket =
  ## Connect with retries while the child server starts up.
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while true:
    var s = newSocket()
    try:
      s.connect("127.0.0.1", Port(port), timeout = 500)
      return s
    except OSError, TimeoutError:
      s.close()
      if getMonoTime() > deadline:
        raise
      sleep(50)

proc readAllHttp(s: Socket, timeoutMs = 15000): string =
  ## Read until the server closes the connection (connection: close model).
  result = ""
  while true:
    var chunk: string
    try:
      chunk = s.recv(4096, timeout = timeoutMs)
    except TimeoutError:
      break
    if chunk.len == 0:
      break
    result.add chunk

proc httpGet(port: int, target: string): string =
  let s = httpConnect(port)
  defer: s.close()
  s.send("GET " & target & " HTTP/1.1\r\nhost: t\r\n\r\n")
  readAllHttp(s)

proc statusLine(response: string): string =
  response.split("\r\n")[0]

proc bodyOf(response: string): string =
  let sep = response.find("\r\n\r\n")
  if sep < 0: "" else: response[sep + 4 .. ^1]

suite "net/http server e2e":
  setup:
    createDir(httpTestDir)

  test "handler parked in sleep does not stall other requests":
    let p = startHttpServer("concurrent.gene", """
(import $net/http [Server serve text])
(fn handle [req]
  (if (== req/path "/slow")
    (then
      ($sleep 800)
      (text "slow-done"))
    (else (text "fast-done"))))
(serve (Server ^host "127.0.0.1" ^port 8181) handle ^max_requests 2)
""")
    defer: (p.terminate(); p.close())
    let slow = httpConnect(8181)
    defer: slow.close()
    slow.send("GET /slow HTTP/1.1\r\nhost: t\r\n\r\n")
    sleep(100)   # let the slow request dispatch and park first
    let t0 = getMonoTime()
    let fast = httpGet(8181, "/fast")
    let fastMs = (getMonoTime() - t0).inMilliseconds
    check bodyOf(fast) == "fast-done"
    # The fast response arrived while the slow handler was still parked.
    check fastMs < 700
    let slowResp = readAllHttp(slow)
    check bodyOf(slowResp) == "slow-done"

  test "request bytes may arrive in dribbles":
    let p = startHttpServer("dribble.gene", """
(import $net/http [Server serve text])
(fn handle [req]
  (text req/params/a))
(serve (Server ^host "127.0.0.1" ^port 8182) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8182)
    defer: s.close()
    for piece in ["GET /x?a=", "chunked HT", "TP/1.1\r\nhost:", " t\r\n\r\n"]:
      s.send(piece)
      sleep(60)
    let resp = readAllHttp(s)
    check statusLine(resp) == "HTTP/1.1 200 OK"
    check bodyOf(resp) == "chunked"

  test "POST body and query params reach the handler":
    let p = startHttpServer("post.gene", """
(import $net/http [Server serve text])
(fn handle [req]
  (text ($ req/method ":" req/params/k ":" req/body)))
(serve (Server ^host "127.0.0.1" ^port 8183) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8183)
    defer: s.close()
    let body = "hello body"
    s.send("POST /submit?k=v HTTP/1.1\r\nhost: t\r\ncontent-length: " &
           $body.len & "\r\n\r\n" & body)
    check bodyOf(readAllHttp(s)) == "POST:v:hello body"

  test "malformed request answers 400":
    let p = startHttpServer("bad.gene", """
(import $net/http [Server serve text])
(fn handle [req] (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8184) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8184)
    defer: s.close()
    s.send("GARBAGE\r\n\r\n")
    check statusLine(readAllHttp(s)) == "HTTP/1.1 400 Bad Request"

  test "handler errors answer 500":
    let p = startHttpServer("boom.gene", """
(import $net/http [Server serve text])
(fn handle [req] (no-such-function))
(serve (Server ^host "127.0.0.1" ^port 8185) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    check statusLine(httpGet(8185, "/")) ==
      "HTTP/1.1 500 Internal Server Error"

  test "slow handler answers 504 after request_timeout_ms":
    let p = startHttpServer("late.gene", """
(import $net/http [Server serve text])
(fn handle [req]
  ($sleep 10000)
  (text "late"))
(serve (Server ^host "127.0.0.1" ^port 8186) handle
  ^max_requests 1 ^request_timeout_ms 300)
""")
    defer: (p.terminate(); p.close())
    let t0 = getMonoTime()
    let resp = httpGet(8186, "/")
    check statusLine(resp) == "HTTP/1.1 504 Gateway Timeout"
    check (getMonoTime() - t0).inMilliseconds < 5000

  test "requests beyond max_in_flight answer 503":
    let p = startHttpServer("busy.gene", """
(import $net/http [Server serve text])
(fn handle [req]
  ($sleep 900)
  (text "done"))
(serve (Server ^host "127.0.0.1" ^port 8187) handle
  ^max_requests 2 ^max_in_flight 1)
""")
    defer: (p.terminate(); p.close())
    let slow = httpConnect(8187)
    defer: slow.close()
    slow.send("GET /a HTTP/1.1\r\nhost: t\r\n\r\n")
    sleep(150)   # ensure the first request is dispatched
    let overflow = httpGet(8187, "/b")
    check statusLine(overflow) == "HTTP/1.1 503 Service Unavailable"
    check bodyOf(readAllHttp(slow)) == "done"

  test "oversized headers answer 400":
    let p = startHttpServer("bighead.gene", """
(import $net/http [Server serve text])
(fn handle [req] (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8188) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8188)
    defer: s.close()
    s.send("GET / HTTP/1.1\r\nx-pad: " & repeat('a', 40 * 1024) & "\r\n\r\n")
    check statusLine(readAllHttp(s)) == "HTTP/1.1 400 Bad Request"

  test "declared body beyond max_body_bytes answers 413":
    let p = startHttpServer("bigbody.gene", """
(import $net/http [Server serve text])
(fn handle [req] (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8189) handle
  ^max_requests 1 ^max_body_bytes 16)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8189)
    defer: s.close()
    let body = repeat('x', 64)
    s.send("POST / HTTP/1.1\r\nhost: t\r\ncontent-length: " & $body.len &
           "\r\n\r\n" & body)
    check statusLine(readAllHttp(s)) == "HTTP/1.1 413 Payload Too Large"

  test "meta-based route discovery serves @route-annotated handlers":
    let p = startHttpServer("discover.gene", """
(import $net/http [Server serve text route])
(fn home [req]
  @route (route ^method "GET" ^path "/")
  (text "home-discovered"))
(fn job [req]
  @route (route ^method "GET" ^path "/job/:id")
  (text ($ "job-" req/params/id)))
(fn not-a-route [x] x)
(fn routed? [d]
  (not (== d/%$meta/route void)))
(fn route-entry [d]
  (var r d/%$meta/route)
  (route ^method r/method ^path r/path ^handler d/value))
(var routes
  (($map ($filter (this_mod ~ declarations) routed?) route-entry)
   ~ into []))
(serve (Server ^host "127.0.0.1" ^port 8194)
  ^max_requests 2
  ^routes routes)
""")
    defer: (p.terminate(); p.close())
    check bodyOf(httpGet(8194, "/")) == "home-discovered"
    check bodyOf(httpGet(8194, "/job/j7")) == "job-j7"

  test "access_log records responses with redacted headers; error_log records failures":
    let p = startHttpServer("logs.gene", """
(import $net/http [Server serve text])
(var access-entries ($cell nil))
(var error-entries ($cell nil))
(fn on-access [rec] (access-entries ~ set rec))
(fn on-error-log [rec] (error-entries ~ set rec))
(fn handle [req]
  (if (== req/path "/boom")
    (nonexistent-fn)
    (do
      (var last (access-entries ~ get))
      (var last-err (error-entries ~ get))
      (if (== last nil)
        (text "no-log")
        (text ($ "logged:" last/method ":" last/path ":" last/status
                 ":auth=" last/headers/authorization
                 ":err=" (if (== last-err nil) "none" last-err/message)))))))
(serve (Server ^host "127.0.0.1" ^port 8193) handle
  ^max_requests 3
  ^access_log on-access
  ^error_log on-error-log)
""")
    defer: (p.terminate(); p.close())
    # Request 1 carries a secret header; request 2 reads its access record.
    block:
      let s = httpConnect(8193)
      defer: s.close()
      s.send("GET /hello HTTP/1.1\r\nhost: t\r\n" &
             "authorization: Bearer secret123\r\n\r\n")
      check statusLine(readAllHttp(s)) == "HTTP/1.1 200 OK"
    check bodyOf(httpGet(8193, "/report")) ==
      "logged:GET:/hello:200:auth=[redacted]:err=none"
    # A failing handler reaches the error log (visible to a later request
    # inside the same server process via the cells above).
    check statusLine(httpGet(8193, "/boom")) ==
      "HTTP/1.1 500 Internal Server Error"

  test "route table matches :param patterns into req/params":
    let p = startHttpServer("routes.gene", """
(import $net/http [Server serve text route])
(fn job-handler [req]
  (text ($ "job:" req/params/id ":verbose=" req/params/verbose)))
(fn home [req] (text "home"))
(serve (Server ^host "127.0.0.1" ^port 8192)
  ^max_requests 3
  ^routes [
    (route ^method "GET" ^path "/" ^handler home)
    (route ^method "GET" ^path "/job/:id" ^handler job-handler)
  ])
""")
    defer: (p.terminate(); p.close())
    check bodyOf(httpGet(8192, "/")) == "home"
    # ":id" captures the segment; query params still populate req/params.
    check bodyOf(httpGet(8192, "/job/j-42?verbose=1")) == "job:j-42:verbose=1"
    check statusLine(httpGet(8192, "/nope")) == "HTTP/1.1 404 Not Found"

  test "actor_pool ^supervision restarts workers and emits failure events":
    let p = startHttpServer("pool.gene", """
(import $net/http [Server serve text actor_pool supervisor_policy RequestMsg])
(type Boom ^props {^message Str} ^impl [Error])
(impl Error for Boom)
(var failures ($channel ^capacity 8))
(fn worker-init [] 0)
(fn worker-handle [ctx state msg]
  (var (RequestMsg ^req req ^reply reply) msg)
  (if (== req/path "/boom")
    (fail (Boom ^message "worker boom"))
    (do
      (var ev (failures ~ try_recv))
      (match ev
        (when TryRecv/empty
          (reply ~ send (text "no-failures")))
        (when (TryRecv/value failure)
          (reply ~ send (text ($ "saw:" failure/message)))))
      ($actor/continue state))))
(serve (Server ^host "127.0.0.1" ^port 8191)
  ^max_requests 2
  ^dispatch (actor_pool ^workers 1 ^mailbox 4
             ^init worker-init ^handle worker-handle)
  ^supervision (supervisor_policy ^strategy `restart
                ^max_restarts 5 ^within_ms 60000
                ^events failures))
""")
    defer: (p.terminate(); p.close())
    # Worker failure answers 500 and emits an ActorFailure to ^events; the
    # restarted worker serves the follow-up request and reads the event.
    check statusLine(httpGet(8191, "/boom")) ==
      "HTTP/1.1 500 Internal Server Error"
    let follow = httpGet(8191, "/check")
    check statusLine(follow) == "HTTP/1.1 200 OK"
    check bodyOf(follow).startsWith("saw:")

  test "custom overload_response answers admission overflow":
    let p = startHttpServer("busy-custom.gene", """
(import $net/http [Server serve text])
(fn handle [req]
  ($sleep 900)
  (text "done"))
(serve (Server ^host "127.0.0.1" ^port 8190) handle
  ^max_requests 2 ^max_in_flight 1
  ^overload_response (text 503 "busy"))
""")
    defer: (p.terminate(); p.close())
    let slow = httpConnect(8190)
    defer: slow.close()
    slow.send("GET /a HTTP/1.1\r\nhost: t\r\n\r\n")
    sleep(150)   # ensure the first request is dispatched
    let overflow = httpGet(8190, "/b")
    check statusLine(overflow) == "HTTP/1.1 503 Service Unavailable"
    check bodyOf(overflow) == "busy"
    check bodyOf(readAllHttp(slow)) == "done"

  # --- WebSocket frames -------------------------------------------------------
  #
  # `ws_send` takes a `Str` or `Bytes` and picks the opcode from which it got;
  # an inbound text frame reaches `on_message` as a `Str` and a binary one as
  # `Bytes`. Binary used to fall through the inbound `case` with no branch —
  # delivered nowhere, with no error and no close — and `ws_send` could only
  # ever emit text.
  #
  # The consumer is `examples/miclone` §10, which moves 16 KB of voxels per
  # message and whose §D7.3 says "16 KB of nodes should not become a node tree".

  proc wsHandshake(port: int, path = "/"): Socket =
    ## Connect and complete the RFC 6455 upgrade, leaving a frame stream.
    let s = httpConnect(port)
    s.send("GET " & path & " HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
           "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
           "Sec-WebSocket-Version: 13\r\n\r\n")
    var head = ""
    while "\r\n\r\n" notin head:
      var ch: char
      if s.recv(addr ch, 1, 3000) != 1: break
      head.add ch
    check "101" in head.split("\r\n")[0]
    s

  proc wsClientFrame(opcode: byte, payload: string): string =
    ## A masked client frame — RFC 6455 §5.1 requires the mask, and the server
    ## rejects an unmasked one as a protocol error.
    result = newStringOfCap(payload.len + 14)
    result.add char(0x80'u8 or opcode)
    let mask = [byte(0x12), byte(0x34), byte(0x56), byte(0x78)]
    if payload.len < 126:
      result.add char(0x80'u8 or byte(payload.len))
    elif payload.len < 65536:
      result.add char(0x80'u8 or 126'u8)
      result.add char((payload.len shr 8) and 0xFF)
      result.add char(payload.len and 0xFF)
    else:
      result.add char(0x80'u8 or 127'u8)
      for shift in countdown(7, 0):
        result.add char((uint64(payload.len) shr (uint(shift) * 8)) and 0xFF)
    for b in mask:
      result.add char(b)
    for i, c in payload:
      result.add char(byte(c) xor mask[i mod 4])

  proc wsReadFrame(s: Socket, timeoutMs = 5000):
      tuple[opcode: byte, payload: string] =
    ## One unmasked server frame. Server frames are never masked.
    var head = newString(2)
    if s.recv(addr head[0], 2, timeoutMs) != 2:
      return (0'u8, "")
    result.opcode = byte(head[0]) and 0x0F
    var length = int(byte(head[1]) and 0x7F)
    if length == 126:
      var ext = newString(2)
      discard s.recv(addr ext[0], 2, timeoutMs)
      length = (int(byte(ext[0])) shl 8) or int(byte(ext[1]))
    elif length == 127:
      var ext = newString(8)
      discard s.recv(addr ext[0], 8, timeoutMs)
      var wide: uint64 = 0
      for i in 0 ..< 8:
        wide = (wide shl 8) or uint64(byte(ext[i]))
      length = int(wide)
    result.payload = newString(length)
    var got = 0
    while got < length:
      let n = s.recv(addr result.payload[got], length - got, timeoutMs)
      if n <= 0: break
      got += n

  test "ws_send emits binary for Bytes and text for Str":
    let p = startHttpServer("ws-kinds.gene", """
(import $net/http [Server serve listen ws_accept ws_send])
(serve (listen ^host "127.0.0.1" ^port 8188)
  (fn [req]
    (ws_accept req
      ^on_open (fn [conn] (ws_send conn "text-hello"))
      ^on_message (fn [conn payload] (ws_send conn payload)))))
""")
    defer: (p.terminate(); p.close())
    let s = wsHandshake(8188)
    defer: s.close()

    # on_open sent a Str, so the frame is opcode 1.
    let hello = wsReadFrame(s)
    check hello.opcode == 1
    check hello.payload == "text-hello"

    # A text frame echoes back as text: the handler received a Str, and
    # `ws_send` chose the opcode from the value it got.
    s.send(wsClientFrame(1, "ping"))
    let echoText = wsReadFrame(s)
    check echoText.opcode == 1
    check echoText.payload == "ping"

    # A binary frame echoes back as binary. Before this landed the inbound
    # frame reached no handler at all, so nothing came back and the test would
    # hang rather than fail on the opcode.
    let raw = "\xff\x00\xfe\x41\x80"    # not valid UTF-8, so text cannot carry it
    s.send(wsClientFrame(2, raw))
    let echoBin = wsReadFrame(s)
    check echoBin.opcode == 2
    check echoBin.payload == raw

  test "a binary frame reaches on_message as Bytes":
    # Echoing proves delivery but not the value's kind — a payload passed
    # through untouched would look the same whatever it was. Reversing it can
    # only be done to a real `Bytes`.
    let p = startHttpServer("ws-bytes.gene", """
(import $net/http [Server serve listen ws_accept ws_send])
(serve (listen ^host "127.0.0.1" ^port 8187)
  (fn [req]
    (ws_accept req
      ^on_message (fn [conn payload]
        (var out [])
        (var i (- ($binary/size payload) 1))
        (while (>= i 0)
          (out ~ push! ($binary/get payload i))
          (set i (- i 1)))
        (ws_send conn ($binary/from_list out))))))
""")
    defer: (p.terminate(); p.close())
    let s = wsHandshake(8187)
    defer: s.close()

    s.send(wsClientFrame(2, "\x01\x02\x03\xfe\xff"))
    let reversed = wsReadFrame(s)
    check reversed.opcode == 2
    check reversed.payload == "\xff\xfe\x03\x02\x01"

    # 16 KB — the size §10 actually moves, and past both frame-header size
    # classes (126 and 65535), which is where a length field gets truncated.
    var big = newString(16384)
    for i in 0 ..< big.len:
      big[i] = char((i * 7) and 0xFF)
    s.send(wsClientFrame(2, big))
    let bigEcho = wsReadFrame(s, timeoutMs = 10000)
    check bigEcho.opcode == 2
    check bigEcho.payload.len == big.len
    var intact = true
    for i in 0 ..< big.len:
      if bigEcho.payload[i] != big[big.len - 1 - i]:
        intact = false
        break
    check intact

  test "on_tick fires on a period and survives a throwing tick":
    # §12's server tick. The serve loop already sleeps only as long as nothing
    # needs it, so a tick is one more deadline to clamp against rather than a
    # thread — and a throwing tick must not take every connected client down
    # with it, since the next one may well succeed.
    let p = startHttpServer("tick.gene", """
(import $net/http [serve listen stop text])
(var n ($cell 0))
(var srv (listen ^host "127.0.0.1" ^port 8187))
(serve srv
  ^tick_ms 60
  ^on_tick (fn []
    (n ~ set (+ (n ~ get) 1))
    (if_yes (== (n ~ get) 2) (boom_in_tick))
    (if_yes (>= (n ~ get) 6)
      ($println $"ticks=$(n ~ get)")
      (stop srv)))
  (fn [req] (text "ok")))
($println "stopped")
""")
    defer: (p.terminate(); p.close())
    sleep(1200)
    p.terminate()
    let output = p.outputStream.readAll()
    # It kept ticking past the one that raised, and drained cleanly afterwards.
    check "ticks=6" in output
    check "stopped" in output
    check "on_tick raised" in output
    check "boom_in_tick" in output

  test "a failing ws handler is reported rather than swallowed":
    # WebSocket callbacks run as fibers and nothing waits on the result, so an
    # exception inside one used to vanish completely: no delivery, no error,
    # no close — indistinguishable from a client that never sent anything.
    let p = startHttpServer("ws-throw.gene", """
(import $net/http [Server serve listen ws_accept ws_send])
(serve (listen ^host "127.0.0.1" ^port 8186)
  (fn [req]
    (ws_accept req
      ^on_message (fn [conn payload]
        (undefined_function_in_handler payload)
        (ws_send conn "never-reached")))))
""")
    defer: (p.terminate(); p.close())
    let s = wsHandshake(8186)
    s.send(wsClientFrame(1, "trigger"))
    sleep(700)
    s.close()
    p.terminate()
    let output = p.outputStream.readAll()   # streams.readAll
    check "ws on_message error" in output
    check "undefined_function_in_handler" in output
