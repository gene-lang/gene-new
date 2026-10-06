import gene/[compiler, printer, types, vm]
import std/[algorithm, monotimes, os, strutils, times, unittest]

when compileOption("threads") and defined(posix):
  suite "I/O file reader — worker-backed POSIX adapter":
    test "open, partial reads, EOF, close, and repeatable wait_closed":
      let path = getTempDir() / "gene-io-file-reader-basic.bin"
      writeFile(path, "abcdef")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let reader (await ($io/open_read path)))
        (let opened ($runtime/gc_stats))
        (let first (await (reader .AsyncReader:read 3)))
        (let second (await (reader .AsyncReader:read 3)))
        (let eof (await (reader .AsyncReader:read 3)))
        (let again (await (reader .AsyncReader:read 3)))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (await (reader .IoResource:wait_closed))
        (let closed ($runtime/gc_stats))
        [opened/io_file_open_resources ($binary/to_str first)
         ($binary/to_str second) eof again
         closed/io_file_open_resources closed/io_cleanup_leases]
      """), scope)
      check value.print() == "[1 \"abc\" \"def\" nil nil 0 0]"

    test "failed open is a typed Task error":
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("missing", newStr(getTempDir() / "gene-io-missing-file.bin"))
      let value = run(compileSource("""
        (let IoError $io/IoError)
        (try (await ($io/open_read missing)) nil
          catch IoError [$err/operation ($present? $err/cause)])
      """), scope)
      check value.print() == "[\"open_read\" true]"

    test "close cancels the read Task but retains bytes until worker retirement":
      let path = getTempDir() / "gene-io-file-reader-close.bin"
      writeFile(path, "abcdefgh")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let reader (await ($io/open_read path)))
        (let reading (reader .AsyncReader:read 4))
        (reader .IoResource:close)
        (let before ($runtime/gc_stats))
        (let cancelled (match (reading .join) ^!exhaustive
          (when TaskOutcome/cancelled true)))
        (await (reader .IoResource:wait_closed))
        (let after ($runtime/gc_stats))
        [cancelled before/io_cleanup_leases after/io_cleanup_leases]
      """), scope)
      check value.print() == "[true 2 0]"

    test "cancelled open closes an undelivered descriptor":
      let path = getTempDir() / "gene-io-file-reader-cancel-open.bin"
      writeFile(path, "data")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let opening ($io/open_read path))
        (opening .cancel)
        (var attempts 0)
        (var stats ($runtime/gc_stats))
        (while (< attempts 1000)
          (if (== stats/io_cleanup_leases 0) (then (break)))
          ($sleep 1)
          (set attempts (+ attempts 1))
          (set stats ($runtime/gc_stats)))
        [(match (opening .join) ^!exhaustive (when TaskOutcome/cancelled true))
         stats/io_cleanup_leases stats/io_root_cleanup_tasks
         stats/io_file_open_resources]
      """), scope)
      check value.print() == "[true 0 0 0]"

    test "streamed reads keep native byte reservation bounded":
      let path = getTempDir() / "gene-io-file-reader-large.bin"
      writeFile(path, repeat('x', 2 * 1024 * 1024))
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let reader (await ($io/open_read path)))
        (var total 0)
        (var peak 0)
        (while true
          (let task (reader .AsyncReader:read 65536))
          (let active ($runtime/gc_stats))
          (if (> active/io_retained_bytes peak)
            (set peak active/io_retained_bytes))
          (let chunk (await task))
          (if ($nil? chunk) (then (break)))
          (set total (+ total ($binary/size chunk))))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        [total peak]
      """), scope)
      check value.print() == "[2097152 65536]"

    test "create_new writer, partial-task contract, flush, and close":
      let path = getTempDir() / "gene-io-file-writer-basic.bin"
      if fileExists(path): removeFile(path)
      defer:
        if fileExists(path): removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let writer (await ($io/open_write path)))
        (let empty (await (writer .AsyncWriter:write ($binary/from_str ""))))
        (let count (await ($io/write_all writer ($binary/from_str "abcdef"))))
        (await (writer .AsyncWriter:flush))
        (writer .IoResource:close)
        (await (writer .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [empty count stats/io_cleanup_leases stats/io_file_open_resources]
      """), scope)
      check value.print() == "[0 6 0 0]"
      check readFile(path) == "abcdef"

    test "write modes require explicit replacement and append correctly":
      let path = getTempDir() / "gene-io-file-writer-modes.bin"
      writeFile(path, "old")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoError $io/IoError)
        (let refused (try (await ($io/open_write path)) false
                         catch IoError true))
        (let append (await ($io/open_write path ^mode "append")))
        (await (append .AsyncWriter:write ($binary/from_str "!")))
        (append .IoResource:close)
        (await (append .IoResource:wait_closed))
        (let truncate (await ($io/open_write path ^mode "truncate")))
        (await (truncate .AsyncWriter:write ($binary/from_str "new")))
        (truncate .IoResource:close)
        (await (truncate .IoResource:wait_closed))
        refused
      """), scope)
      check value.boolVal
      check readFile(path) == "new"

    test "closing an active write cancels its Task but retires its bytes":
      let path = getTempDir() / "gene-io-file-writer-close.bin"
      if fileExists(path): removeFile(path)
      defer:
        if fileExists(path): removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoBusy $io/IoBusy)
        (let writer (await ($io/open_write path)))
        (let operation (writer .AsyncWriter:write ($binary/from_str "abc")))
        (let busy (try (writer .AsyncWriter:flush) false catch IoBusy true))
        (writer .IoResource:close)
        (let before ($runtime/gc_stats))
        (let cancelled (match (operation .join) ^!exhaustive
          (when TaskOutcome/cancelled true)))
        (await (writer .IoResource:wait_closed))
        (let after ($runtime/gc_stats))
        [busy cancelled before/io_cleanup_leases after/io_cleanup_leases]
      """), scope)
      check value.print() == "[true true 2 0]"
      check readFile(path) == "abc"

    test "oversized writes reject before retaining native payload":
      let path = getTempDir() / "gene-io-file-writer-backpressure.bin"
      if fileExists(path): removeFile(path)
      defer:
        if fileExists(path): removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      scope.define("large", newBytes(repeat('z', 1_048_577)))
      let value = run(compileSource("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoBackpressure $io/IoBackpressure)
        (let writer (await ($io/open_write path)))
        (let rejected (try (writer .AsyncWriter:write large) false
                           catch IoBackpressure true))
        (let stats ($runtime/gc_stats))
        (writer .IoResource:close)
        (await (writer .IoResource:wait_closed))
        [rejected stats/io_retained_bytes]
      """), scope)
      check value.print() == "[true 0]"

    test "bounded copy streams between real file endpoints":
      let source = getTempDir() / "gene-io-file-copy-source.bin"
      let destination = getTempDir() / "gene-io-file-copy-destination.bin"
      writeFile(source, repeat('q', 2 * 1024 * 1024))
      if fileExists(destination): removeFile(destination)
      defer:
        removeFile(source)
        if fileExists(destination): removeFile(destination)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("source", newStr(source))
      scope.define("destination", newStr(destination))
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let reader (await ($io/open_read source)))
        (let writer (await ($io/open_write destination)))
        (let count (await ($io/copy reader writer
                          ^limit 1048576 ^chunk_bytes 65536)))
        (writer .IoResource:close)
        (reader .IoResource:close)
        (await (writer .IoResource:wait_closed))
        (await (reader .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [count stats/io_cleanup_leases stats/io_peak_retained_bytes]
      """), scope)
      check value.print() == "[1048576 0 65536]"
      check readFile(destination) == repeat('q', 1024 * 1024)

    test "pipe endpoints transfer Bytes, flush, and expose EOF after writer close":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let count (await (writer .AsyncWriter:write ($binary/from_str "abc"))))
        (await (writer .AsyncWriter:flush))
        (writer .IoResource:close)
        (await (writer .IoResource:wait_closed))
        (let data (await (reader .AsyncReader:read 5)))
        (let eof (await (reader .AsyncReader:read 5)))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [count ($binary/to_str data) eof stats/io_cleanup_leases
         stats/io_file_open_resources]
      """), newGlobalScope())
      check value.print() == "[3 \"abc\" nil 0 0]"

    test "closing a blocked pipe read retires without peer progress":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoBusy $io/IoBusy)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let reading (reader .AsyncReader:read 5))
        (let busy (try (reader .AsyncReader:read 1)
                        false catch IoBusy true))
        (reader .IoResource:close)
        (let cancelled (match (reading .join) ^!exhaustive
          (when TaskOutcome/cancelled true)))
        (await (reader .IoResource:wait_closed))
        (writer .IoResource:close)
        (await (writer .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [busy cancelled stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true true 0]"

    test "writing to a closed pipe raises IoError instead of SIGPIPE":
      let value = run(compileSource("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoError $io/IoError)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (let failed (try
          (await (writer .AsyncWriter:write ($binary/from_str "x")))
          false catch IoError true))
        (writer .IoResource:close)
        (await (writer .IoResource:wait_closed))
        failed
      """), newGlobalScope())
      check value.boolVal

    test "a blocked pipe peer does not stop an unrelated file read":
      let path = getTempDir() / "gene-io-pipe-peer-file.bin"
      writeFile(path, "fast")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let pipeReader endpoints/0)
        (let pipeWriter endpoints/1)
        (let blocked (pipeReader .AsyncReader:read 1))
        (let fileReader (await ($io/open_read path)))
        (let fast (await (fileReader .AsyncReader:read 4)))
        (await (pipeWriter .AsyncWriter:write ($binary/from_str "p")))
        (let peer (await blocked))
        (fileReader .IoResource:close)
        (pipeReader .IoResource:close)
        (pipeWriter .IoResource:close)
        (await (fileReader .IoResource:wait_closed))
        (await (pipeReader .IoResource:wait_closed))
        (await (pipeWriter .IoResource:wait_closed))
        [($binary/to_str fast) ($binary/to_str peer)]
      """), scope)
      check value.print() == "[\"fast\" \"p\"]"

    test "a pipe wait parked beside another wait is watched at once":
      # The readiness thread polls a snapshot of the parked waits. A wait
      # parked while it slept went unnoticed until the 100 ms poll timeout:
      # each trial took ~96 ms before the wake pipe, 2-3 ms after. The median
      # of five keeps load noise out.
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (fn trial []
          (let idle ($io/pipe))
          (let busy ($io/pipe))
          (let waiting (idle/0 .AsyncReader:read 1))
          ($sleep 5)
          (let started ($os/monotonic_ms))
          (let pending (busy/0 .AsyncReader:read 1))
          ($sleep 1)
          (await (busy/1 .AsyncWriter:write ($binary/from_str "x")))
          (await pending)
          (let delivered (- ($os/monotonic_ms) started))
          (waiting .cancel)
          (waiting .join)
          (for end in [idle/0 idle/1 busy/0 busy/1]
            (end .IoResource:close)
            (await (end .IoResource:wait_closed)))
          delivered)
        (var delivered [])
        (repeat 5 (delivered .push (trial)))
        delivered
      """), newGlobalScope())
      var sorted: seq[int64]
      for item in value.listItems: sorted.add item.intVal
      sorted.sort()
      checkpoint "delivery times " & $sorted & " ms"
      check sorted.len == 5
      check sorted[2] < 50

    test "canceling a pipe read does not manufacture EOF":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoBusy $io/IoBusy)
        (let pipe ($io/pipe))
        (let first (pipe/0 .AsyncReader:read 1))
        (first .cancel)
        (let cancelled (match (first .join) ^!exhaustive
          (when TaskOutcome/cancelled true)))
        (var second nil)
        (var attempts 0)
        (while (< attempts 400)
          (try (set second (pipe/0 .AsyncReader:read 1))
            catch IoBusy nil)
          (if (not ($nil? second)) (then (break)))
          ($sleep 1)
          (set attempts (+ attempts 1)))
        ($assert (not ($nil? second)))
        (await (pipe/1 .AsyncWriter:write ($binary/from_str "x")))
        (let data (await second))
        (pipe/0 .IoResource:close)
        (pipe/1 .IoResource:close)
        (await (pipe/0 .IoResource:wait_closed))
        (await (pipe/1 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [cancelled ($binary/to_str data) stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true \"x\" 0]"

    test "a full pool of blocked pipe reads cannot starve file work":
      let path = getTempDir() / "gene-io-pipe-worker-fairness.bin"
      writeFile(path, "fast")
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (var endpoints [])
        (var reads [])
        (var i 0)
        (while (< i 16)
          (let pair ($io/pipe))
          (endpoints .push pair)
          (reads .push (pair/0 .AsyncReader:read 1))
          (set i (+ i 1)))
        (var parked false)
        (var attempts 0)
        (while (< attempts 200)
          (let snapshot ($runtime/gc_stats))
          (if (>= snapshot/io_waiting_readiness 16)
            (then (set parked true) (break)))
          ($sleep 1)
          (set attempts (+ attempts 1)))
        (let rescued ($cell false))
        (let fallback (spawn ^lane root
          (do ($sleep 1000)
              (rescued .set true)
              (for pair in endpoints
                (pair/1 .IoResource:close)))))
        (let file (await ($io/open_read path)))
        (let data (await (file .AsyncReader:read 4)))
        (let beforeRescue (not (rescued .get)))
        (fallback .cancel)
        (for pair in endpoints
          (pair/0 .IoResource:close)
          (pair/1 .IoResource:close))
        (for task in reads (task .join))
        (for pair in endpoints
          (await (pair/0 .IoResource:wait_closed))
          (await (pair/1 .IoResource:wait_closed)))
        (file .IoResource:close)
        (await (file .IoResource:wait_closed))
        (let after ($runtime/gc_stats))
        [parked beforeRescue ($binary/to_str data)
         after/io_waiting_readiness]
      """), scope)
      check value.print() == "[true true \"fast\" 0]"

    test "copy stops at a truncated pipe and borrows both endpoints":
      let destination = getTempDir() / "gene-io-pipe-copy-output.bin"
      if fileExists(destination): removeFile(destination)
      defer:
        if fileExists(destination): removeFile(destination)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("destination", newStr(destination))
      let value = run(compileSource("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let pipeWriter endpoints/1)
        (let fileWriter (await ($io/open_write destination)))
        (await (pipeWriter .AsyncWriter:write ($binary/from_str "partial")))
        (pipeWriter .IoResource:close)
        (await (pipeWriter .IoResource:wait_closed))
        (let copied (await ($io/copy reader fileWriter ^limit 100)))
        (fileWriter .IoResource:close)
        (reader .IoResource:close)
        (await (fileWriter .IoResource:wait_closed))
        (await (reader .IoResource:wait_closed))
        copied
      """), scope)
      check value.intVal == 7
      check readFile(destination) == "partial"

    test "async subprocess stdout streams raw Bytes and auto-closes its writer":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let IoClosed $io/IoClosed)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let task ($os/exec_stream_async "sh"
          "-c" "dd if=/dev/zero bs=4096 count=64 2>/dev/null"
          ^stdout_pipe writer))
        (var total 0)
        (while true
          (let part (await (reader .AsyncReader:read 4096)))
          (if ($nil? part) (then (break)))
          (set total (+ total ($binary/size part))))
        (let outcome (await task))
        (await (writer .IoResource:wait_closed))
        (let consumed (try
          (writer .AsyncWriter:write ($binary/from_str "x"))
          false catch IoClosed true))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [total outcome/status outcome/stdout consumed
         stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[262144 0 \"\" true 0]"

    test "canceling async subprocess stdout retires its pipe before EOF":
      let started = getMonoTime()
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let task ($os/exec_stream_async "sh"
          "-c" "sleep 2; printf x" ^stdout_pipe writer))
        (spawn ^lane root (do ($sleep 50) (task .cancel)))
        (let cancelled (match (task .join) ^!exhaustive
          (when TaskOutcome/cancelled true)))
        (let eof (await (reader .AsyncReader:read 16)))
        (await (writer .IoResource:wait_closed))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [cancelled eof stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true nil 0]"
      check getMonoTime() - started < initDuration(milliseconds = 1500)

    test "scope error waits for subprocess stdout's native cleanup":
      let started = getMonoTime()
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let caught (try
          (scope
            ($os/exec_stream_async "sh"
              "-c" "sleep 2; printf x" ^stdout_pipe writer)
            (fail (RuntimeError ^message "stop")))
          catch RuntimeError true))
        (let eof (await (reader .AsyncReader:read 16)))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [caught eof stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true nil 0]"
      check getMonoTime() - started < initDuration(milliseconds = 1500)

    test "a closed subprocess stdout reader fails without SIGPIPE":
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let task ($os/exec_stream_async "sh"
          "-c" "dd if=/dev/zero bs=4096 count=256 2>/dev/null"
          ^stdout_pipe writer))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (let failed (try (await task) false catch Any true))
        (await (writer .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [failed stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true 0]"

    test "subprocess stdout chooses one binary or line destination":
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let lines ($channel ^capacity 1))
        (let rejected (try
          ($os/exec_stream_async "true"
            ^stdout_chan lines ^stdout_pipe writer)
          false catch Any true))
        (writer .IoResource:close)
        (reader .IoResource:close)
        (await (writer .IoResource:wait_closed))
        (await (reader .IoResource:wait_closed))
        rejected
      """), newGlobalScope())
      check value.boolVal

    test "async subprocess stderr preserves binary bytes and closes its writer":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let task ($os/exec_stream_async "sh"
          "-c" "printf 'a\\000b' >&2" ^stderr_pipe writer))
        (let data (await (reader .AsyncReader:read 16)))
        (let eof (await (reader .AsyncReader:read 16)))
        (let result (await task))
        (await (writer .IoResource:wait_closed))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        [($binary/to_list data) eof result/status result/stderr]
      """), newGlobalScope())
      check value.print() == "[[97 0 98] nil 0 \"\"]"

    test "stdout and stderr can stream concurrently past pipe capacity":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (fn count_bytes [reader]
          (var total 0)
          (while true
            (let chunk (await (reader .AsyncReader:read 4096)))
            (if ($nil? chunk) (then (break)))
            (set total (+ total ($binary/size chunk))))
          total)
        (let stdout ($io/pipe))
        (let stderr ($io/pipe))
        (let outTask (spawn ^lane root (count_bytes stdout/0)))
        (let errTask (spawn ^lane root (count_bytes stderr/0)))
        (let process ($os/exec_stream_async "sh"
          "-c" "dd if=/dev/zero bs=4096 count=64 2>/dev/null & dd if=/dev/zero bs=4096 count=64 >&2 2>/dev/null & wait"
          ^stdout_pipe stdout/1 ^stderr_pipe stderr/1))
        (let outCount (await outTask))
        (let errCount (await errTask))
        (let result (await process))
        (await (stdout/1 .IoResource:wait_closed))
        (await (stderr/1 .IoResource:wait_closed))
        (stdout/0 .IoResource:close)
        (stderr/0 .IoResource:close)
        (await (stdout/0 .IoResource:wait_closed))
        (await (stderr/0 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [outCount errCount result/status result/stdout result/stderr
         stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[262144 262144 0 \"\" \"\" 0]"

    test "a rejected second output pipe retires the first borrow":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let endpoints ($io/pipe))
        (let reader endpoints/0)
        (let writer endpoints/1)
        (let rejected (try
          ($os/exec_stream_async "true"
            ^stdout_pipe writer ^stderr_pipe 1)
          false catch TypeError true))
        (await (writer .IoResource:wait_closed))
        (let eof (await (reader .AsyncReader:read 1)))
        (reader .IoResource:close)
        (await (reader .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [rejected eof stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true nil 0]"

    test "legacy stdout lines coexist with binary stderr":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (let stderr ($io/pipe))
        (let lines ($channel ^capacity 2))
        (let task ($os/exec_stream_async "sh"
          "-c" "printf 'line\\n'; printf err >&2"
          ^stdout_chan lines ^stderr_pipe stderr/1))
        (let result (await task))
        (let line (lines .recv))
        (let errorBytes (await (stderr/0 .AsyncReader:read 16)))
        (await (stderr/1 .IoResource:wait_closed))
        (stderr/0 .IoResource:close)
        (await (stderr/0 .IoResource:wait_closed))
        [result/status line ($binary/to_str errorBytes)]
      """), newGlobalScope())
      check value.print() == "[0 \"line\" \"err\"]"

    test "subprocess stdin and stdout round-trip binary Bytes through cat":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let input ($io/pipe))
        (let output ($io/pipe))
        (let process ($os/exec_stream_async "cat"
          ^stdin_pipe input/0 ^stdout_pipe output/1))
        (await (input/1 .AsyncWriter:write ($binary/from_list [97 0 98])))
        (input/1 .IoResource:close)
        (await (input/1 .IoResource:wait_closed))
        (let data (await (output/0 .AsyncReader:read 16)))
        (let eof (await (output/0 .AsyncReader:read 16)))
        (let result (await process))
        (await (input/0 .IoResource:wait_closed))
        (await (output/1 .IoResource:wait_closed))
        (output/0 .IoResource:close)
        (await (output/0 .IoResource:wait_closed))
        [($binary/to_list data) eof result/status]
      """), newGlobalScope())
      check value.print() == "[[97 0 98] nil 0]"

    test "concurrent process stdin and stdout stay bounded past pipe capacity":
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("payload", newBytes(repeat('r', 262144)))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let input ($io/pipe))
        (let output ($io/pipe))
        (let process ($os/exec_stream_async "cat"
          ^stdin_pipe input/0 ^stdout_pipe output/1))
        (let sending (spawn ^lane root
          (do (await ($io/write_all input/1 payload))
              (input/1 .IoResource:close)
              (await (input/1 .IoResource:wait_closed)))))
        (var total 0)
        (while true
          (let part (await (output/0 .AsyncReader:read 4096)))
          (if ($nil? part) (then (break)))
          (set total (+ total ($binary/size part))))
        (await sending)
        (let result (await process))
        (await (input/0 .IoResource:wait_closed))
        (await (output/1 .IoResource:wait_closed))
        (output/0 .IoResource:close)
        (await (output/0 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [total result/status
         (<= stats/io_peak_retained_bytes 1048576)
         stats/io_cleanup_leases]
      """), scope)
      check value.print() == "[262144 0 true 0]"

    test "an early child exit retires its consumed stdin reader":
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let input ($io/pipe))
        (let process ($os/exec_stream_async "true"
          ^stdin_pipe input/0))
        (let result (await process))
        (await (input/0 .IoResource:wait_closed))
        (input/1 .IoResource:close)
        (await (input/1 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [result/status stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[0 0]"

    test "canceling a subprocess retires its consumed stdin reader":
      let started = getMonoTime()
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let input ($io/pipe))
        (let process ($os/exec_stream_async "sleep"
          "2" ^stdin_pipe input/0))
        (spawn ^lane root (do ($sleep 50) (process .cancel)))
        (let cancelled (match (process .join) ^!exhaustive
          (when TaskOutcome/cancelled true)))
        (await (input/0 .IoResource:wait_closed))
        (input/1 .IoResource:close)
        (await (input/1 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [cancelled stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true 0]"
      check getMonoTime() - started < initDuration(milliseconds = 1500)

else:
  suite "I/O file reader — unavailable runtime":
    test "file opens return explicit failed Tasks and pipe rejects synchronously":
      let value = run(compileSource("""
        (let IoError $io/IoError)
        [(try (await ($io/open_read "missing")) false catch IoError true)
         (try (await ($io/open_write "missing")) false catch IoError true)
         (try ($io/pipe) false catch Any true)]
      """), newGlobalScope())
      check value.print() == "[true true true]"
