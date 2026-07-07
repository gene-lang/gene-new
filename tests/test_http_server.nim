## E2E tests for the net/http event-loop server (task-per-request dispatch).
##
## Each test starts the gene CLI as a child process running `serve` with
## `^max-requests` for self-termination, then talks to it over raw blocking
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
  (if (= req/path "/slow")
    (then
      (sleep 800)
      (text "slow-done"))
    (else (text "fast-done"))))
(serve (Server ^host "127.0.0.1" ^port 8181) handle ^max-requests 2)
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
(serve (Server ^host "127.0.0.1" ^port 8182) handle ^max-requests 1)
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
(serve (Server ^host "127.0.0.1" ^port 8183) handle ^max-requests 1)
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
(serve (Server ^host "127.0.0.1" ^port 8184) handle ^max-requests 1)
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
(serve (Server ^host "127.0.0.1" ^port 8185) handle ^max-requests 1)
""")
    defer: (p.terminate(); p.close())
    check statusLine(httpGet(8185, "/")) ==
      "HTTP/1.1 500 Internal Server Error"

  test "slow handler answers 504 after request-timeout-ms":
    let p = startHttpServer("late.gene", """
(import net/http [Server serve text])
(fn handle [req]
  (sleep 10000)
  (text "late"))
(serve (Server ^host "127.0.0.1" ^port 8186) handle
  ^max-requests 1 ^request-timeout-ms 300)
""")
    defer: (p.terminate(); p.close())
    let t0 = getMonoTime()
    let resp = httpGet(8186, "/")
    check statusLine(resp) == "HTTP/1.1 504 Gateway Timeout"
    check (getMonoTime() - t0).inMilliseconds < 5000

  test "requests beyond max-in-flight answer 503":
    let p = startHttpServer("busy.gene", """
(import net/http [Server serve text])
(fn handle [req]
  (sleep 900)
  (text "done"))
(serve (Server ^host "127.0.0.1" ^port 8187) handle
  ^max-requests 2 ^max-in-flight 1)
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
(serve (Server ^host "127.0.0.1" ^port 8188) handle ^max-requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8188)
    defer: s.close()
    s.send("GET / HTTP/1.1\r\nx-pad: " & repeat('a', 40 * 1024) & "\r\n\r\n")
    check statusLine(readAllHttp(s)) == "HTTP/1.1 400 Bad Request"
