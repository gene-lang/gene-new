import gene/[compiler, printer, types, vm]
import std/[os, strutils, unittest]

when compileOption("threads") and defined(posix):
  suite "I/O TCP streams — worker-backed POSIX adapter":
    test "loopback streams exchange binary Bytes and retire both directions":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let accepting (listener .accept))
        (let client (await ($io/tcp_connect "127.0.0.1"
          (listener .local_port))))
        (let server (await accepting))
        (await (client .AsyncWriter:write ($binary/from_list [97 0 98])))
        (let inbound (await (server .AsyncReader:read 3)))
        (await (server .AsyncWriter:write ($binary/from_list [111 0 107])))
        (let outbound (await (client .AsyncReader:read 3)))
        (client .IoResource:close)
        (let eof (await (server .AsyncReader:read 1)))
        (server .IoResource:close)
        (listener .IoResource:close)
        (await (client .IoResource:wait_closed))
        (await (server .IoResource:wait_closed))
        (await (listener .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [($binary/to_list inbound) ($binary/to_list outbound) eof
         stats/io_open_resources stats/io_cleanup_leases]
      """), newGlobalScope(newApplication(getTempDir())))
      check value.print() == "[[97 0 98] [111 0 107] nil 0 0]"

    test "a waiting accept leaves the worker pool free for a file read":
      let path = getTempDir() / "gene-io-tcp-fast-file.bin"
      writeFile(path, "fast")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let accepting (listener .accept))
        ($sleep 20)
        (let parked ($runtime/gc_stats))
        (let reader (await ($io/open_read path)))
        (let bytes (await (reader .AsyncReader:read 4)))
        (listener .IoResource:close)
        (let cancelled (match (accepting .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (await (listener .IoResource:wait_closed))
        (let after ($runtime/gc_stats))
        [(>= parked/io_waiting_readiness 1) ($binary/to_str bytes)
         cancelled after/io_waiting_readiness after/io_cleanup_leases]
      """), scope)
      check value.print() == "[true \"fast\" true 0 0]"

    test "accept rejects a second pending call and close cancels the first":
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let IoBusy $io/IoBusy)
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let first (listener .accept))
        (let busy (try (listener .accept) false catch IoBusy true))
        (listener .IoResource:close)
        (let cancelled (match (first .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (await (listener .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [busy cancelled stats/io_waiting_readiness
         stats/io_cleanup_leases]
      """), newGlobalScope(newApplication(getTempDir())))
      check value.print() == "[true true 0 0]"

    test "canceling accept retires its ticket and leaves listener reusable":
      let value = run(compileSource("""
        (let IoBusy $io/IoBusy)
        (let IoResource $io/IoResource)
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let first (listener .accept))
        (first .cancel)
        (let cancelled (match (first .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (var second nil)
        (var attempts 0)
        (while (< attempts 400)
          (try (set second (listener .accept)) catch IoBusy nil)
          (if (not ($nil? second)) (then (break)))
          ($sleep 1)
          (set attempts (+ attempts 1)))
        ($assert (not ($nil? second)))
        (let client (await ($io/tcp_connect "127.0.0.1"
          (listener .local_port))))
        (let server (await second))
        (client .IoResource:close)
        (server .IoResource:close)
        (listener .IoResource:close)
        (await (client .IoResource:wait_closed))
        (await (server .IoResource:wait_closed))
        (await (listener .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [cancelled (< attempts 400) stats/io_cleanup_leases]
      """), newGlobalScope(newApplication(getTempDir())))
      check value.print() == "[true true 0]"

    test "canceling a TCP read retires its ticket without closing the stream":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoBusy $io/IoBusy)
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let accepting (listener .accept))
        (let client (await ($io/tcp_connect "127.0.0.1"
          (listener .local_port))))
        (let server (await accepting))
        (let first (client .AsyncReader:read 1))
        (first .cancel)
        (let cancelled (match (first .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (var second nil)
        (var attempts 0)
        (while (< attempts 400)
          (try (set second (client .AsyncReader:read 1))
            catch IoBusy nil)
          (if (not ($nil? second)) (then (break)))
          ($sleep 1)
          (set attempts (+ attempts 1)))
        ($assert (not ($nil? second)))
        (await (server .AsyncWriter:write ($binary/from_str "z")))
        (let data (await second))
        (client .IoResource:close)
        (server .IoResource:close)
        (listener .IoResource:close)
        (await (client .IoResource:wait_closed))
        (await (server .IoResource:wait_closed))
        (await (listener .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [cancelled ($binary/to_str data) (< attempts 400)
         stats/io_cleanup_leases]
      """), newGlobalScope(newApplication(getTempDir())))
      check value.print() == "[true \"z\" true 0]"

    test "two pending socket reads count against the Application byte budget":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let accepting (listener .accept))
        (let client (await ($io/tcp_connect "127.0.0.1"
          (listener .local_port))))
        (let server (await accepting))
        (let first (client .AsyncReader:read 1048576))
        (let second (server .AsyncReader:read 1048576))
        (let during ($runtime/gc_stats))
        (client .IoResource:close)
        (server .IoResource:close)
        (listener .IoResource:close)
        (let cancelled1 (match (first .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (let cancelled2 (match (second .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (await (client .IoResource:wait_closed))
        (await (server .IoResource:wait_closed))
        (await (listener .IoResource:wait_closed))
        (let after ($runtime/gc_stats))
        [during/io_retained_bytes cancelled1 cancelled2
         after/io_retained_bytes after/io_cleanup_leases]
      """), newGlobalScope(newApplication(getTempDir())))
      check value.print() == "[2097152 true true 0 0]"

    test "a slow TCP peer does not block unrelated file work":
      let path = getTempDir() / "gene-io-tcp-slow-peer-file.bin"
      writeFile(path, "fast")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      scope.define("payload", newBytes(repeat('x', 16 * 1024 * 1024)))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let accepting (listener .accept))
        (let client (await ($io/tcp_connect "127.0.0.1"
          (listener .local_port))))
        (let server (await accepting))
        ($io/testing/socket_buffer client "send" 4096)
        ($io/testing/socket_buffer server "receive" 4096)
        (let sending ($io/write_all client payload))
        (var parked false)
        (var attempts 0)
        (while (< attempts 500)
          (let snapshot ($runtime/gc_stats))
          (if (>= snapshot/io_waiting_readiness 1)
            (then (set parked true) (break)))
          ($sleep 1)
          (set attempts (+ attempts 1)))
        (let file (await ($io/open_read path)))
        (let data (await (file .AsyncReader:read 4)))
        (client .IoResource:close)
        (let stopped (match (sending .join) ^exhaustive false
          (when TaskOutcome/cancelled true)
          (when (TaskOutcome/error _) true)))
        (server .IoResource:close)
        (listener .IoResource:close)
        (file .IoResource:close)
        (await (client .IoResource:wait_closed))
        (await (server .IoResource:wait_closed))
        (await (listener .IoResource:wait_closed))
        (await (file .IoResource:wait_closed))
        (let after ($runtime/gc_stats))
        [parked ($binary/to_str data)
         stopped after/io_retained_bytes after/io_cleanup_leases]
      """), scope)
      check value.print() == "[true \"fast\" true 0 0]"

    test "invalid port and refused connection are typed errors":
      let value = run(compileSource("""
        (let IoError $io/IoError)
        (let IoResource $io/IoResource)
        (let badPort (try ($io/tcp_connect "127.0.0.1" 70000)
          false catch IoError true))
        (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
        (let port (listener .local_port))
        (listener .IoResource:close)
        (await (listener .IoResource:wait_closed))
        (let refused (try
          (await ($io/tcp_connect "127.0.0.1" port ^timeout_ms 100))
          false catch IoError true))
        [badPort refused]
      """), newGlobalScope(newApplication(getTempDir())))
      check value.print() == "[true true]"

else:
  suite "I/O TCP streams — unavailable runtime":
    test "connect and listen return failed Tasks":
      let value = run(compileSource("""
        (let IoError $io/IoError)
        [(try (await ($io/tcp_connect "127.0.0.1" 80))
           false catch IoError true)
         (try (await ($io/tcp_listen "127.0.0.1" 0))
           false catch IoError true)]
      """), newGlobalScope())
      check value.print() == "[true true]"
