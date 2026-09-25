## E2E tests for the net/http event-loop server (task_per_request dispatch).
##
## Each test starts the gene CLI as a child process running `serve` with
## `^max_requests` for self-termination, then talks to it over raw blocking
## client sockets. The concurrency test is the core contract: a handler parked
## in `sleep` must not stall other requests.

import std/[json, monotimes, net, os, osproc, streams, strutils, times,
            unittest]
when defined(posix):
  import std/[nativesockets, posix]
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

proc sendHttpBounded(s: Socket, payload: string, timeoutMs = 5000) =
  ## A failed child must not strand this suite inside net.Socket.send's retry
  ## loop after its peer has closed the connection.
  when defined(posix):
    if payload.len == 0: return
    let fd = s.getFd()
    when defined(macosx):
      var noSigPipe: cint = 1
      discard posix.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                               addr noSigPipe, SockLen(sizeof(noSigPipe)))
    nativesockets.setBlocking(fd, false)
    defer: nativesockets.setBlocking(fd, true)
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    var offset = 0
    while offset < payload.len:
      let flags: cint = when defined(linux): MSG_NOSIGNAL.cint else: 0
      let count = posix.send(fd, unsafeAddr payload[offset],
                             payload.len - offset, flags)
      if count > 0:
        offset += count
      elif count < 0 and errno in [EAGAIN, EWOULDBLOCK, EINTR]:
        if getMonoTime() >= deadline:
          raise newException(TimeoutError, "HTTP test send timed out")
        sleep(5)
      else:
        raise newException(IOError, "HTTP test peer closed during send")
  else:
    s.send(payload)

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

proc decodeChunkedHttp(response: string): string =
  let body = bodyOf(response)
  var offset = 0
  while offset < body.len:
    let lineEnd = body.find("\r\n", offset)
    if lineEnd < 0:
      raise newException(ValueError, "missing chunk-size terminator")
    let size = parseHexInt(body[offset ..< lineEnd])
    offset = lineEnd + 2
    if size == 0:
      if body[offset .. ^1] != "\r\n":
        raise newException(ValueError, "missing final chunk terminator")
      return
    if offset + size + 2 > body.len or
        body[offset + size ..< offset + size + 2] != "\r\n":
      raise newException(ValueError, "incomplete chunk payload")
    result.add body[offset ..< offset + size]
    offset += size + 2
  raise newException(ValueError, "missing final chunk")

proc geneQuotedPath(path: string): string =
  "\"" & path.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

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

  test "stream mode dispatches after headers and reads bounded body chunks":
    let p = startHttpServer("stream_body.gene", """
(import $net/http [Server StreamRequest serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  ($assert (== ($head req) StreamRequest))
  (var total 0)
  (while true
    (let part (await (req/body .AsyncReader:read 4096)))
    (if ($nil? part) (then (break)))
    (set total (+ total ($binary/size part))))
  (text ($to_str total)))
(serve (Server ^host "127.0.0.1" ^port 8191) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8191)
    defer: s.close()
    sendHttpBounded(s, "POST /upload HTTP/1.1\r\nhost: t\r\n" &
                    "content-length: 16384\r\n\r\n")
    for _ in 0 ..< 16:
      sendHttpBounded(s, repeat('x', 1024))
      sleep(1)
    let response = readAllHttp(s)
    check statusLine(response).contains("200 OK")
    check bodyOf(response) == "16384"

  test "a slow streamed body does not delay an unrelated fast request":
    let p = startHttpServer("stream_concurrent.gene", """
(import $net/http [Server serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  (if (== req/path "/fast")
    (then (text "fast"))
    (else
      (do
        (var total 0)
        (while true
          (let part (await (req/body .AsyncReader:read 4096)))
          (if ($nil? part) (then (break)))
          (set total (+ total ($binary/size part))))
        (text ($to_str total))))))
(serve (Server ^host "127.0.0.1" ^port 8192) handle
  ^body_mode "stream" ^max_requests 2)
""")
    defer: (p.terminate(); p.close())
    let slow = httpConnect(8192)
    defer: slow.close()
    sendHttpBounded(slow, "POST /slow HTTP/1.1\r\nhost: t\r\n" &
                    "content-length: 8192\r\n\r\n" & repeat('x', 1024))
    sleep(50)
    let started = getMonoTime()
    let fast = httpGet(8192, "/fast")
    let fastMs = (getMonoTime() - started).inMilliseconds
    check bodyOf(fast) == "fast"
    check fastMs < 700
    sendHttpBounded(slow, repeat('x', 7168))
    check bodyOf(readAllHttp(slow)) == "8192"

  test "stream backpressure leaves fast requests responsive":
    let p = startHttpServer("stream_backpressure.gene", """
(import $net/http [Server serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  (if (== req/path "/fast")
    (then (text "fast"))
    (else
      (do
        ($sleep 400)
        (var total 0)
        (while true
          (let part (await (req/body .AsyncReader:read 4096)))
          (if ($nil? part) (then (break)))
          (set total (+ total ($binary/size part))))
        (text ($to_str total))))))
(serve (Server ^host "127.0.0.1" ^port 8193) handle
  ^body_mode "stream" ^body_idle_ms 100 ^max_requests 2)
""")
    defer: (p.terminate(); p.close())
    let slow = httpConnect(8193)
    defer: slow.close()
    sendHttpBounded(slow, "POST /slow HTTP/1.1\r\nhost: t\r\n" &
                    "content-length: 262144\r\n\r\n" & repeat('x', 131072))
    sleep(50)
    let started = getMonoTime()
    let fast = httpGet(8193, "/fast")
    let fastMs = (getMonoTime() - started).inMilliseconds
    check bodyOf(fast) == "fast"
    check fastMs < 350
    sendHttpBounded(slow, repeat('x', 131072))
    check bodyOf(readAllHttp(slow)) == "262144"

  test "truncated stream body never appears as successful EOF":
    let p = startHttpServer("stream_truncated.gene", """
(import $net/http [Server serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  (var total 0)
  (while true
    (let part (await (req/body .AsyncReader:read 1024)))
    (if ($nil? part) (then (break)))
    (set total (+ total ($binary/size part))))
  (text ($to_str total)))
(serve (Server ^host "127.0.0.1" ^port 8194) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8194)
    defer: s.close()
    sendHttpBounded(s, "POST /bad HTTP/1.1\r\nhost: t\r\n" &
                       "content-length: 100\r\n\r\nshort")
    discard s.getFd().shutdown(SHUT_WR)
    let response = readAllHttp(s, timeoutMs = 2000)
    check not response.contains("200 OK")

  test "stream mode rejects conflicting framing and oversize before dispatch":
    let p = startHttpServer("stream_rejections.gene", """
(import $net/http [Server serve text])
(fn handle [req] (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8195) handle
  ^body_mode "stream" ^max_body_bytes 1024 ^max_requests 2)
""")
    defer: (p.terminate(); p.close())
    let oversized = httpConnect(8195)
    defer: oversized.close()
    sendHttpBounded(oversized, "POST /large HTTP/1.1\r\nhost: t\r\n" &
                               "content-length: 2048\r\n\r\n")
    check statusLine(readAllHttp(oversized)) == "HTTP/1.1 413 Payload Too Large"
    let conflicting = httpConnect(8195)
    defer: conflicting.close()
    sendHttpBounded(conflicting, "POST /conflict HTTP/1.1\r\nhost: t\r\n" &
                                 "transfer-encoding: chunked\r\n" &
                                 "content-length: 1\r\n\r\n")
    check statusLine(readAllHttp(conflicting)) == "HTTP/1.1 400 Bad Request"

  test "chunked stream frames split across reads yield only decoded Bytes":
    let p = startHttpServer("stream_chunked.gene", """
(import $net/http [Server serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  (var payload "")
  (while true
    (let part (await (req/body .AsyncReader:read 4096)))
    (if ($nil? part) (then (break)))
    (set payload ($ payload ($binary/to_str part))))
  (text payload))
(serve (Server ^host "127.0.0.1" ^port 8198) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8198)
    defer: s.close()
    sendHttpBounded(s, "POST /chunked HTTP/1.1\r\nhost: t\r\n" &
                       "transfer-encoding: chunked\r\n\r\n")
    for piece in ["4;foo=bar\r", "\nWi", "ki\r\n", "5\r\nped", "ia\r\n",
                  "0\r\nX-Trace: yes\r\n\r\n"]:
      sendHttpBounded(s, piece)
      sleep(5)
    check bodyOf(readAllHttp(s)) == "Wikipedia"

  test "chunked stream rejects malformed size and decoded-size overflow":
    let p = startHttpServer("stream_chunked_errors.gene", """
(import $net/http [Server serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  (while true
    (let part (await (req/body .AsyncReader:read 4096)))
    (if ($nil? part) (then (break))))
  (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8199) handle
  ^body_mode "stream" ^max_body_bytes 8 ^max_requests 3)
""")
    defer: (p.terminate(); p.close())
    let malformed = httpConnect(8199)
    defer: malformed.close()
    sendHttpBounded(malformed, "POST /bad HTTP/1.1\r\nhost: t\r\n" &
                               "transfer-encoding: chunked\r\n\r\nZ\r\n")
    check statusLine(readAllHttp(malformed)) == "HTTP/1.1 400 Bad Request"
    let oversized = httpConnect(8199)
    defer: oversized.close()
    sendHttpBounded(oversized, "POST /large HTTP/1.1\r\nhost: t\r\n" &
                               "transfer-encoding: chunked\r\n\r\n9\r\n")
    check statusLine(readAllHttp(oversized)) ==
      "HTTP/1.1 413 Payload Too Large"
    let cumulative = httpConnect(8199)
    defer: cumulative.close()
    sendHttpBounded(cumulative, "POST /cumulative HTTP/1.1\r\nhost: t\r\n" &
                                "transfer-encoding: chunked\r\n\r\n" &
                                "5\r\nabcde\r\n5\r\n")
    check statusLine(readAllHttp(cumulative)) ==
      "HTTP/1.1 413 Payload Too Large"

  test "truncated chunked body never appears as successful EOF":
    let p = startHttpServer("stream_chunked_truncated.gene", """
(import $net/http [Server serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  (while true
    (let part (await (req/body .AsyncReader:read 4096)))
    (if ($nil? part) (then (break))))
  (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8200) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8200)
    defer: s.close()
    sendHttpBounded(s, "POST /bad HTTP/1.1\r\nhost: t\r\n" &
                       "transfer-encoding: chunked\r\n\r\n4\r\nWi")
    discard s.getFd().shutdown(SHUT_WR)
    check not readAllHttp(s, timeoutMs = 2000).contains("200 OK")

  test "stream body idle timeout is monotonic and reports 408":
    let p = startHttpServer("stream_idle.gene", """
(import $net/http [Server serve text])
(let AsyncReader $io/AsyncReader)
(fn handle [req]
  (await (req/body .AsyncReader:read 1))
  (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8201) handle
  ^body_mode "stream" ^body_idle_ms 150
  ^request_timeout_ms 2000 ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8201)
    defer: s.close()
    sendHttpBounded(s, "POST /idle HTTP/1.1\r\nhost: t\r\n" &
                       "content-length: 10\r\n\r\n")
    let started = getMonoTime()
    let response = readAllHttp(s, timeoutMs = 3000)
    let elapsed = (getMonoTime() - started).inMilliseconds
    check statusLine(response) == "HTTP/1.1 408 Request Timeout"
    check elapsed < 1500

  test "handler may close an unfinished stream body and answer early":
    let p = startHttpServer("stream_early_close.gene", """
(import $net/http [Server serve text])
(let IoResource $io/IoResource)
(fn handle [req]
  (req/body .IoResource:close)
  (text "early"))
(serve (Server ^host "127.0.0.1" ^port 8196) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8196)
    defer: s.close()
    sendHttpBounded(s, "POST /early HTTP/1.1\r\nhost: t\r\n" &
                       "content-length: 1048576\r\n\r\n")
    check bodyOf(readAllHttp(s, timeoutMs = 3000)) == "early"

  test "streaming headers stop at the configured header cap":
    let p = startHttpServer("stream_header_limit.gene", """
(import $net/http [Server serve text])
(fn handle [req] (text "unreachable"))
(serve (Server ^host "127.0.0.1" ^port 8197) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8197)
    defer: s.close()
    try:
      sendHttpBounded(s, "GET /x HTTP/1.1\r\nhost: t\r\nx-long: " &
                         repeat('x', 40000))
    except IOError:
      discard # the server may reject before the entire oversized line arrives
    check statusLine(readAllHttp(s)) == "HTTP/1.1 400 Bad Request"

  test "known-length streamed response preserves binary bytes":
    let path = httpTestDir / "stream_response_known.bin"
    writeFile(path, "a\0b")
    defer: removeFile(path)
    let p = startHttpServer("stream_response_known.gene", """
(import $net/http [Server serve stream])
(import $io [open_read])
(fn handle [req]
  (let source (await (open_read """ & geneQuotedPath(path) & """)))
  (stream 200 source ^content_length 3 ^own_reader true))
(serve (Server ^host "127.0.0.1" ^port 8203) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let response = httpGet(8203, "/known")
    check statusLine(response) == "HTTP/1.1 200 OK"
    check response.contains("content-length: 3\r\n")
    check bodyOf(response) == "a\0b"

  test "unknown-length streamed response uses complete chunked framing":
    let path = httpTestDir / "stream_response_chunked.bin"
    let expected = repeat('x', 70000) & "\0"
    writeFile(path, expected)
    defer: removeFile(path)
    let p = startHttpServer("stream_response_chunked.gene", """
(import $net/http [Server serve stream])
(import $io [open_read])
(fn handle [req]
  (let source (await (open_read """ & geneQuotedPath(path) & """)))
  (stream 200 source ^own_reader true))
(serve (Server ^host "127.0.0.1" ^port 8204) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let response = httpGet(8204, "/chunked")
    check statusLine(response) == "HTTP/1.1 200 OK"
    check response.contains("transfer-encoding: chunked\r\n")
    check decodeChunkedHttp(response) == expected

  test "a short stream closes after headers without inventing completion":
    let path = httpTestDir / "stream_response_short.bin"
    writeFile(path, "ab")
    defer: removeFile(path)
    let p = startHttpServer("stream_response_short.gene", """
(import $net/http [Server serve stream])
(import $io [open_read])
(fn handle [req]
  (let source (await (open_read """ & geneQuotedPath(path) & """)))
  (stream 200 source ^content_length 3 ^own_reader true))
(serve (Server ^host "127.0.0.1" ^port 8205) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let response = httpGet(8205, "/short")
    check statusLine(response) == "HTTP/1.1 200 OK"
    check response.contains("content-length: 3\r\n")
    check bodyOf(response) == "ab"

  test "stream byte limit closes without a false final chunk":
    let path = httpTestDir / "stream_response_limit.bin"
    writeFile(path, "abcdef")
    defer: removeFile(path)
    let p = startHttpServer("stream_response_limit.gene", """
(import $net/http [Server serve stream])
(import $io [open_read])
(fn handle [req]
  (let source (await (open_read """ & geneQuotedPath(path) & """)))
  (stream 200 source ^own_reader true ^max_bytes 4))
(serve (Server ^host "127.0.0.1" ^port 8207) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let response = httpGet(8207, "/limited")
    check statusLine(response) == "HTTP/1.1 200 OK"
    check response.contains("transfer-encoding: chunked\r\n")
    check not bodyOf(response).endsWith("0\r\n\r\n")

  test "HEAD streamed response keeps headers and sends no body":
    let path = httpTestDir / "stream_response_head.bin"
    writeFile(path, "abc")
    defer: removeFile(path)
    let p = startHttpServer("stream_response_head.gene", """
(import $net/http [Server serve stream])
(import $io [open_read])
(fn handle [req]
  (let source (await (open_read """ & geneQuotedPath(path) & """)))
  (stream 200 source ^content_length 3 ^own_reader true))
(serve (Server ^host "127.0.0.1" ^port 8208) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8208)
    defer: s.close()
    sendHttpBounded(s, "HEAD /file HTTP/1.1\r\nhost: t\r\n\r\n")
    let response = readAllHttp(s)
    check statusLine(response) == "HTTP/1.1 200 OK"
    check response.contains("content-length: 3\r\n")
    check bodyOf(response) == ""

  test "streamed response accepts a third-party AsyncReader implementation":
    let p = startHttpServer("stream_response_protocol.gene", """
(import $net/http [Server serve stream])
(let AsyncReader $io/AsyncReader)
(type Parts ^props {^chunks List ^index Cell})
(impl AsyncReader for Parts
  (message read [self max_bytes : Int] : (Task Bytes? Error)
    (spawn ^lane root
      (do
        (let index (self/index .get))
        (if (>= index ($size self/chunks))
          nil
          (do
            (self/index .set (+ index 1))
            self/chunks/%index))))))
(fn handle [req]
  (stream 200 (Parts ^chunks [($binary/from_str "a")
                              ($binary/from_list [98 0])]
                     ^index ($cell 0))))
(serve (Server ^host "127.0.0.1" ^port 8209) handle ^max_requests 1)
""")
    defer: (p.terminate(); p.close())
    let response = httpGet(8209, "/parts")
    check statusLine(response) == "HTTP/1.1 200 OK"
    check bodyOf(response).contains("\r\na\r\n")
    check bodyOf(response).contains("\r\nb\0\r\n")
    check bodyOf(response).endsWith("0\r\n\r\n")

  test "streamed response deadline closes an unfinished body":
    let p = startHttpServer("stream_response_timeout.gene", """
(import $net/http [Server serve stream])
(let AsyncReader $io/AsyncReader)
(type SlowReader ^props {})
(impl AsyncReader for SlowReader
  (message read [self max_bytes : Int] : (Task Bytes? Error)
    (spawn ^lane root
      (do ($sleep 1000) ($binary/from_str "late")))))
(fn handle [req] (stream 200 (SlowReader)))
(serve (Server ^host "127.0.0.1" ^port 8210) handle
  ^request_timeout_ms 150 ^max_requests 1)
""")
    defer:
      if p.running: p.terminate()
      p.close()
    let started = getMonoTime()
    let response = httpGet(8210, "/timeout")
    let elapsed = (getMonoTime() - started).inMilliseconds
    check statusLine(response) == "HTTP/1.1 200 OK"
    check not bodyOf(response).endsWith("0\r\n\r\n")
    check elapsed < 1000
    check p.waitForExit(3000) == 0

  test "streamed response can echo an unfinished request body":
    let p = startHttpServer("stream_echo.gene", """
(import $net/http [Server serve stream])
(fn handle [req] (stream 200 req/body))
(serve (Server ^host "127.0.0.1" ^port 8211) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer:
      if p.running: p.terminate()
      p.close()
    let s = httpConnect(8211)
    defer: s.close()
    sendHttpBounded(s, "POST /echo HTTP/1.1\r\nhost: t\r\n" &
                       "content-length: 8\r\n\r\nabcd")
    var first = ""
    let deadline = getMonoTime() + initDuration(seconds = 3)
    while not first.contains("\r\nabcd\r\n") and getMonoTime() < deadline:
      let part = s.recv(1, timeout = 1000)
      if part.len == 0: break
      first.add part
    check first.contains("\r\nabcd\r\n")
    sendHttpBounded(s, "efgh")
    let response = first & readAllHttp(s)
    check statusLine(response) == "HTTP/1.1 200 OK"
    check bodyOf(response).contains("\r\nefgh\r\n")
    check bodyOf(response).endsWith("0\r\n\r\n")
    check p.waitForExit(3000) == 0

  test "chunked upload can be echoed before its final chunk":
    let p = startHttpServer("stream_chunked_echo.gene", """
(import $net/http [Server serve stream])
(fn handle [req] (stream 200 req/body))
(serve (Server ^host "127.0.0.1" ^port 8212) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer:
      if p.running: p.terminate()
      p.close()
    let s = httpConnect(8212)
    defer: s.close()
    sendHttpBounded(s, "POST /echo HTTP/1.1\r\nhost: t\r\n" &
                       "transfer-encoding: chunked\r\n\r\n" &
                       "4\r\nWiki\r\n")
    var first = ""
    let deadline = getMonoTime() + initDuration(seconds = 3)
    while getMonoTime() < deadline:
      let headEnd = first.find("\r\n\r\n")
      if headEnd >= 0:
        let chunkLineEnd = first.find("\r\n", headEnd + 4)
        if chunkLineEnd >= 0 and first.len > chunkLineEnd + 2:
          break
      let part = s.recv(1, timeout = 1000)
      if part.len == 0: break
      first.add part
    check first.endsWith("W")
    sendHttpBounded(s, "5\r\npedia\r\n0\r\n\r\n")
    let response = first & readAllHttp(s)
    check statusLine(response) == "HTTP/1.1 200 OK"
    check decodeChunkedHttp(response) == "Wikipedia"
    check p.waitForExit(3000) == 0

  test "malformed upload during echo closes the partial response":
    let p = startHttpServer("stream_echo_malformed.gene", """
(import $net/http [Server serve stream])
(fn handle [req] (stream 200 req/body))
(serve (Server ^host "127.0.0.1" ^port 8213) handle
  ^body_mode "stream" ^max_requests 1)
""")
    defer:
      if p.running: p.terminate()
      p.close()
    let s = httpConnect(8213)
    defer: s.close()
    sendHttpBounded(s, "POST /echo HTTP/1.1\r\nhost: t\r\n" &
                       "transfer-encoding: chunked\r\n\r\n" &
                       "4\r\nWiki\r\n")
    var first = ""
    let deadline = getMonoTime() + initDuration(seconds = 3)
    while getMonoTime() < deadline:
      let headEnd = first.find("\r\n\r\n")
      if headEnd >= 0:
        let chunkLineEnd = first.find("\r\n", headEnd + 4)
        if chunkLineEnd >= 0 and first.len > chunkLineEnd + 2:
          break
      let part = s.recv(1, timeout = 1000)
      if part.len == 0: break
      first.add part
    check first.endsWith("W")
    sendHttpBounded(s, "Z\r\n")
    let response = first & readAllHttp(s)
    check statusLine(response) == "HTTP/1.1 200 OK"
    check not bodyOf(response).endsWith("0\r\n\r\n")
    check p.waitForExit(3000) == 0

  test "slow response peer does not delay a fast request":
    let path = httpTestDir / "stream_response_slow.bin"
    writeFile(path, repeat('x', 16 * 1024 * 1024))
    defer: removeFile(path)
    let p = startHttpServer("stream_response_slow.gene", """
(import $net/http [Server serve stream text])
(import $io [open_read])
(fn handle [req]
  (if (== req/path "/fast")
    (text "fast")
    (do
      (let source (await (open_read """ & geneQuotedPath(path) & """)))
      (stream 200 source ^own_reader true))))
(serve (Server ^host "127.0.0.1" ^port 8206) handle ^max_requests 2)
""")
    defer:
      if p.running: p.terminate()
      p.close()
    var slow = httpConnect(8206)
    when defined(posix):
      var receiveBuffer: cint = 4096
      discard posix.setsockopt(slow.getFd(), SOL_SOCKET, SO_RCVBUF,
                               addr receiveBuffer,
                               SockLen(sizeof(receiveBuffer)))
    defer:
      if slow != nil: slow.close()
    sendHttpBounded(slow, "GET /slow HTTP/1.1\r\nhost: t\r\n\r\n")
    sleep(50)
    let started = getMonoTime()
    let fast = httpGet(8206, "/fast")
    let fastMs = (getMonoTime() - started).inMilliseconds
    check bodyOf(fast) == "fast"
    check fastMs < 700
    slow.close() # abort the large transfer; it must retire its owned reader
    slow = nil
    check p.waitForExit(3000) == 0

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
  (($map ($filter (this_mod .declarations) routed?) route-entry)
   .into []))
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
(fn on-access [rec] (access-entries .set rec))
(fn on-error-log [rec] (error-entries .set rec))
(fn handle [req]
  (if (== req/path "/boom")
    (nonexistent-fn)
    (do
      (var last (access-entries .get))
      (var last-err (error-entries .get))
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
      (var ev (failures .try_recv))
      (match ev
        (when TryRecv/empty
          (reply .send (text "no-failures")))
        (when (TryRecv/value failure)
          (reply .send (text ($ "saw:" failure/message)))))
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
          (out .push ($binary/get payload i))
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
    (n .set (+ (n .get) 1))
    (if_yes (== (n .get) 2) (boom_in_tick))
    (if_yes (>= (n .get) 6)
      ($println $"ticks=$(n .get)")
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

  test "stop returns a physical-cleanup report after a forced drain":
    let p = startHttpServer("stop-report.gene", """
(import $net/http [listen serve stop text])
(var srv (listen ^host "127.0.0.1" ^port 8222))
(let report (serve srv
  (fn [req]
    (if (== req/path "/hold")
      (do ($sleep 1000) (text 200 "late"))
      (do (stop srv) (text 200 "stopping"))))
  ^body_mode "stream" ^drain_timeout_ms 100))
($println ($json/stringify report))
""")
    defer:
      try: p.terminate()
      except OSError: discard
      p.close()
    let hold = httpConnect(8222)
    defer: hold.close()
    sendHttpBounded(hold, "GET /hold HTTP/1.1\r\nhost: t\r\n\r\n")
    sleep(80)
    let stopped = httpGet(8222, "/stop")
    check statusLine(stopped).startsWith("HTTP/1.1 200")
    check p.waitForExit(5000) == 0
    let output = p.outputStream.readAll()
    check "\"complete\":true" in output
    check "\"graceful\":false" in output
    check "\"forced_connections\":1" in output
    check "\"cleanup_leases\":0" in output
    check "\"pending_cleanup_tasks\":0" in output
    check "\"close_failed\":false" in output

  test "stop reports incomplete cleanup when an owned reader will not close":
    let p = startHttpServer("stop-incomplete.gene", """
(import $net/http [listen serve stop text stream])
(let AsyncReader $io/AsyncReader)
(let IoResource $io/IoResource)
(type NeverClose ^props {})
(impl AsyncReader for NeverClose
  (message read [max_bytes : Int] : (Task Bytes? Error)
    (spawn ^lane root nil)))
(impl IoResource for NeverClose
  (message close [] : Nil nil)
  (message wait_closed [] : (Task Nil Error)
    (spawn ^lane root (do ($sleep 1000) nil))))
(var srv (listen ^host "127.0.0.1" ^port 8223))
(let report (serve srv
  (fn [req]
    (if (== req/path "/stop")
      (do (stop srv) (text 200 "stopping"))
      (stream (NeverClose) ^own_reader true)))
  ^drain_timeout_ms 100))
($println ($json/stringify report))
""")
    defer:
      try: p.terminate()
      except OSError: discard
      p.close()
    let held = httpConnect(8223)
    defer: held.close()
    sendHttpBounded(held, "GET /held HTTP/1.1\r\nhost: t\r\n\r\n")
    sleep(80)
    let stopped = httpGet(8223, "/stop")
    check statusLine(stopped).startsWith("HTTP/1.1 200")
    check p.waitForExit(5000) == 0
    var report = newJNull()
    for line in p.outputStream.readAll().splitLines:
      if line.startsWith("{"):
        report = parseJson(line)
    check report.kind == JObject
    if report.kind == JObject:
      check report["complete"].getBool == false
      check report["graceful"].getBool == false
      check report["pending_cleanup_tasks"].getInt > 0

  test "ws_accept ^subprotocol selects an offered subprotocol; ws_queued reports backlog":
    # A browser that offers a subprotocol fails the handshake unless the
    # answer names it, so the selection has to reach the 101 response. A name
    # the client never offered is refused before any upgrade happens.
    let p = startHttpServer("ws-protocol.gene", """
(import $net/http [Server serve listen ws_accept ws_send ws_queued text])
(serve (listen ^host "127.0.0.1" ^port 8185)
  (fn [req]
    (ws_accept req ^subprotocol "gene.world.v1"
      ^on_open (fn [conn]
        (var idle (ws_queued conn))
        (ws_send conn "first")
        (ws_send conn $"idle=${idle} queued=$(ws_queued conn)")))))
""")
    defer: (p.terminate(); p.close())
    let s = httpConnect(8185)
    defer: s.close()
    s.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
           "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
           "Sec-WebSocket-Protocol: other.v0, gene.world.v1\r\n" &
           "Sec-WebSocket-Version: 13\r\n\r\n")
    var head = ""
    while "\r\n\r\n" notin head:
      var ch: char
      if s.recv(addr ch, 1, 3000) != 1: break
      head.add ch
    check "101" in head.split("\r\n")[0]
    check "Sec-WebSocket-Protocol: gene.world.v1\r\n" in head
    check wsReadFrame(s).payload == "first"
    # Nothing was queued before the first send; afterwards the frame (payload
    # plus its two header bytes) is waiting on the socket.
    check wsReadFrame(s).payload == "idle=0 queued=7"

    let refused = httpConnect(8185)
    defer: refused.close()
    refused.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
                 "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
                 "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
                 "Sec-WebSocket-Protocol: other.v0\r\n" &
                 "Sec-WebSocket-Version: 13\r\n\r\n")
    let answer = readAllHttp(refused, 5000)
    check "101" notin statusLine(answer)

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

  test "status attributes a busy handler to serve-loop work":
    # A handler runs inside a serve-loop iteration, so CPU-bound handler work
    # shows as loop work rather than as a late kernel wakeup. The SERVICE
    # heartbeat relies on that split to attribute a stall.
    let p = startHttpServer("loop-timing.gene", """
(import $net/http [listen serve status text])
(var server (listen ^host "127.0.0.1" ^port 8214))
(fn handle [req]
  (if (== req/path "/spin")
    (do
      (let until_ms (+ ($os/monotonic_ms) 150))
      (var spins 0)
      (while (< ($os/monotonic_ms) until_ms)
        (set spins (+ spins 1)))
      (return (text "spun"))))
  (let s (status server))
  (text ($json/stringify [s/max_loop_work_ms s/loop_work_ms s/loop_work_cpu_ms
                          s/wait_overrun_ms s/max_wait_overrun_ms])))
(serve server ^handler handle ^max_requests 2)
""")
    defer: (p.terminate(); p.close())
    check bodyOf(httpGet(8214, "/spin")) == "spun"
    let fields = parseJson(bodyOf(httpGet(8214, "/status")))
    check fields.len == 5
    # pumpScheduler runs up to 128 instruction-budget slices per iteration,
    # so the 150 ms spin may span iterations; an idle iteration is ~0-2 ms.
    check fields[0].getInt >= 20
    for field in fields:
      check field.getInt >= 0
