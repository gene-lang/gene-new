## E2E coverage for the scheduler-friendly native libcurl client. Plain HTTP
## loopback tests validate request/response, streaming, bounds, and cancellation
## without external network access; TLS coverage below uses a local certificate.

proc runHttpClient(name, source: string): tuple[output: string, exitCode: int] =
  buildHttpGene()
  let path = httpTestDir / name
  writeFile(path, source)
  let run = execCmdEx(httpGeneExe & " run " & quoteShell(path))
  (run.output.strip, run.exitCode)

suite "net/http_client e2e":
  setup:
    createDir(httpTestDir)

  test "request runs off-thread and returns status headers and body":
    let server = startHttpServer("client-request-server.gene", """
(import $net/http [Server serve Response])
(fn handle [req]
  (Response ^status 201 ^headers {^x-test "yes"} ^body req/body))
(serve (Server ^host "127.0.0.1" ^port 8201) handle ^max_requests 2)
""")
    defer: (server.terminate(); server.close())
    let ready = httpConnect(8201)
    ready.close()
    let client = runHttpClient("client-request.gene", """
(import $net/http_client [Http request])
(var r (await (request Http ^method "POST" ^url "http://127.0.0.1:8201/echo"
                       ^headers {^content-type "text/plain"} ^body "hello")))
($println [r/status r/body r/truncated r/headers/x-test])
""")
    check client.exitCode == 0
    check client.output == "[201 \"hello\" false \"yes\"]"

  test "stream sends bounded raw chunks and closes before task settlement":
    let server = startHttpServer("client-stream-server.gene", """
(import $net/http [Server serve Response])
(fn handle [req]
  (Response ^status 200 ^body "alpha\nbeta\n"))
(serve (Server ^host "127.0.0.1" ^port 8202) handle ^max_requests 2)
""")
    defer: (server.terminate(); server.close())
    let ready = httpConnect(8202)
    ready.close()
    let client = runHttpClient("client-stream.gene", """
(import $net/http_client [Http stream])
(var transfer (stream Http ^url "http://127.0.0.1:8202/events"
                      ^channel_capacity 2 ^max_pending_bytes 4096))
(var seen ($cell ""))
(try
  (loop
    (var chunk (transfer/channel ~ recv))
    (seen ~ set $"${(seen ~ get)}${chunk}"))
 catch (ChannelClosed) nil)
(var r (await transfer/task))
($println [r/status r/body (seen ~ get)])
""")
    check client.exitCode == 0
    check client.output == "[200 \"alpha\\nbeta\\n\" \"alpha\\nbeta\\n\"]"

  test "output cap truncates without turning HTTP status into an error":
    let server = startHttpServer("client-cap-server.gene", """
(import $net/http [Server serve Response])
(fn handle [req] (Response ^status 418 ^body "abcdefghij"))
(serve (Server ^host "127.0.0.1" ^port 8203) handle ^max_requests 2)
""")
    defer: (server.terminate(); server.close())
    let ready = httpConnect(8203)
    ready.close()
    let client = runHttpClient("client-cap.gene", """
(import $net/http_client [Http request])
(var r (await (request Http ^url "http://127.0.0.1:8203/cap" ^max_bytes 4)))
($println [r/status r/body r/truncated])
""")
    check client.exitCode == 0
    check client.output == "[418 \"abcd\" true]"

  test "Task cancellation aborts a live native transfer promptly":
    let server = startHttpServer("client-cancel-server.gene", """
(import $net/http [Server serve Response])
(fn handle [req] ($sleep 5000) (Response ^status 200 ^body "late"))
(serve (Server ^host "127.0.0.1" ^port 8204) handle ^max_requests 2)
""")
    defer: (server.terminate(); server.close())
    let ready = httpConnect(8204)
    ready.close()
    let started = getMonoTime()
    let client = runHttpClient("client-cancel.gene", """
(import $net/http_client [Http request])
(var t (request Http ^url "http://127.0.0.1:8204/slow"))
($sleep 100)
(t ~ cancel)
($println "cancelled")
""")
    let elapsed = (getMonoTime() - started).inMilliseconds
    check client.exitCode == 0
    check client.output == "cancelled"
    check elapsed < 2000

  test "HTTPS verifies a loopback certificate through an explicit CA file":
    if findExe("openssl").len == 0:
      skip()
    else:
      let cert = httpTestDir / "http-client-cert.pem"
      let key = httpTestDir / "http-client-key.pem"
      let generated = execCmdEx(
        "openssl req -x509 -newkey rsa:2048 -nodes -days 1 " &
        "-keyout " & quoteShell(key) & " -out " & quoteShell(cert) &
        " -subj /CN=localhost -addext " &
        quoteShell("subjectAltName=IP:127.0.0.1,DNS:localhost"))
      if generated.exitCode != 0:
        checkpoint generated.output
      check generated.exitCode == 0
      let server = startProcess("openssl",
        args = ["s_server", "-quiet", "-accept", "8205", "-cert", cert,
                "-key", key, "-www"],
        options = {poUsePath, poStdErrToStdOut})
      defer: (server.terminate(); server.close())
      let ready = httpConnect(8205)
      ready.close()
      let untrusted = runHttpClient("client-tls-untrusted.gene", """
(import $net/http_client [Http request])
(await (request Http ^url "https://127.0.0.1:8205/" ^timeout_ms 5000))
""")
      check untrusted.exitCode != 0
      let client = runHttpClient("client-tls.gene", """
(import $net/http_client [Http request])
(import $str [starts_with?])
(var r (await (request Http ^url "https://127.0.0.1:8205/"
                       ^ca_file "/CERT_PATH/" ^timeout_ms 5000)))
($println [r/status (starts_with? r/effective_url "https://") r/truncated])
""".replace("/CERT_PATH/", cert))
      check client.exitCode == 0
      check client.output == "[200 true false]"
