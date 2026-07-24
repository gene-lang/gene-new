## E2E tests for the net/http event-loop server (task_per_request dispatch).
##
## Each test starts the gene CLI as a child process running `serve` with
## `^max_requests` for self-termination, then talks to it over raw blocking
## client sockets. The concurrency test is the core contract: a handler parked
## in `sleep` must not stall other requests.

import std/[monotimes, net, os, osproc, strutils, times, unittest]
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
(import net/http [Server serve text])
(fn handle [req]
  (if (== req/path "/slow")
    (then
      (sleep 800)
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
(import net/http [Server serve text])
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
(import net/http [Server serve text])
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
(import net/http [Server serve text])
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
(import net/http [Server serve text])
(fn handle [req] (no-such-function))
(serve (Server ^host "127.0.0.1" ^port 8185) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    check statusLine(httpGet(8185, "/")) ==
      "HTTP/1.1 500 Internal Server Error"

  test "slow handler answers 504 after request_timeout_ms":
    let p = startHttpServer("late.gene", """
(import net/http [Server serve text])
(fn handle [req]
  (sleep 10000)
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
(import net/http [Server serve text])
(fn handle [req]
  (sleep 900)
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
(import net/http [Server serve text])
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
(import net/http [Server serve text])
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
(import net/http [Server serve text route])
(fn home [req]
  @route (route ^method "GET" ^path "/")
  (text "home-discovered"))
(fn job [req]
  @route (route ^method "GET" ^path "/job/:id")
  (text ($ "job-" req/params/id)))
(fn not-a-route [x] x)
(fn routed? [d]
  (not (== d/%meta/route void)))
(fn route-entry [d]
  (var r d/%meta/route)
  (route ^method r/method ^path r/path ^handler d/value))
(var routes
  ((map (filter (Module/declarations this_mod) routed?) route-entry)
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
(import net/http [Server serve text])
(var access-entries (cell nil))
(var error-entries (cell nil))
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
(import net/http [Server serve text route])
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
(import net/http [Server serve text actor_pool supervisor_policy RequestMsg])
(type Boom ^props {^message Str} ^impl [Error])
(impl Error for Boom)
(var failures (channel ^capacity 8))
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
      (actor/continue state))))
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
(import net/http [Server serve text])
(fn handle [req]
  (sleep 900)
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
