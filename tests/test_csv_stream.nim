import gene/[compiler, printer, types, vm]
import std/[os, strutils, unittest]

when compileOption("threads") and defined(posix):
  suite "CSV incremental AsyncReader adapter":
    test "pipe rows, headers, BOM, and owned close":
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("payload", newBytes(
        "\xEF\xBB\xBFname,count\r\n\"a\nb\",2\r\nz,3\n"))
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let pipe ($io/pipe))
        (let rows ($csv/reader pipe/0 ^headers true ^own_reader true))
        (await ($io/write_all pipe/1 payload))
        (pipe/1 .IoResource:close)
        (await (pipe/1 .IoResource:wait_closed))
        (let first (await (rows .next)))
        (let second (await (rows .next)))
        (let eof (await (rows .next)))
        (let again (await (rows .next)))
        (let open ($runtime/gc_stats))
        (rows .IoResource:close)
        (await (rows .IoResource:wait_closed))
        (await (rows .IoResource:wait_closed))
        (await (pipe/0 .IoResource:wait_closed))
        (let closed ($runtime/gc_stats))
        [first second eof again
         open/io_csv_open_resources closed/io_csv_open_resources
         (<= open/csv_parser_peak_resource_bytes 70000)
         closed/csv_parser_retained_bytes]
      """), scope)
      check value.print() == "[{^name \"a\\nb\" ^count \"2\"} " &
        "{^name \"z\" ^count \"3\"} nil nil 1 0 true 0]"

    test "one-byte chunks preserve quotes, CRLF, BOM, and UTF-8":
      let scope = newGlobalScope(newApplication(getTempDir()))
      var chunks: seq[Value]
      for ch in "\xEF\xBB\xBF\"a\"\"b\",é\r\n":
        chunks.add newBytes($ch)
      scope.define("chunks", newList(chunks))
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let IoResource $io/IoResource)
        (type ChunkReader ^props {^chunks List ^offset Cell})
        (impl AsyncReader for ChunkReader
          (message read [self max_bytes : Int] : (Task Bytes? Error)
            (spawn ^lane root
              (do
                (let index (self/offset .get))
                (if (>= index ($size self/chunks))
                  nil
                  (do
                    (self/offset .set (+ index 1))
                    self/chunks/%index))))))
        (let source (ChunkReader ^chunks chunks ^offset ($cell 0)))
        (let rows ($csv/reader source))
        (let row (await (rows .next)))
        (let eof (await (rows .next)))
        (rows .IoResource:close)
        (await (rows .IoResource:wait_closed))
        [row eof]
      """), scope)
      check value.print() == "[[\"a\\\"b\" \"é\"] nil]"

    test "malformed headers fail with CsvError and retain no pending read":
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let pipe ($io/pipe))
        (let rows ($csv/reader pipe/0 ^headers true))
        (await ($io/write_all pipe/1 ($binary/from_str "a,a\n1,2\n")))
        (pipe/1 .IoResource:close)
        (let failed (try (await (rows .next)) false catch CsvError true))
        (rows .IoResource:close)
        (await (rows .IoResource:wait_closed))
        (pipe/0 .IoResource:close)
        (await (pipe/0 .IoResource:wait_closed))
        (await (pipe/1 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [failed stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true 0]"

    test "closing an unowned reader cancels next without closing its source":
      let value = run(compileSource("""
        (let AsyncReader $io/AsyncReader)
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (let pipe ($io/pipe))
        (let rows ($csv/reader pipe/0))
        (let pending (rows .next))
        (let busy (try (rows .next) false catch CsvError true))
        (rows .IoResource:close)
        (let cancelled (match (pending .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (await (rows .IoResource:wait_closed))
        (await (pipe/1 .AsyncWriter:write ($binary/from_str "x")))
        (pipe/0 .IoResource:close)
        (pipe/1 .IoResource:close)
        (await (pipe/0 .IoResource:wait_closed))
        (await (pipe/1 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [busy cancelled stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true true 0]"

    test "closing an owned reader retires a pending upstream read":
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let pipe ($io/pipe))
        (let rows ($csv/reader pipe/0 ^own_reader true))
        (let pending (rows .next))
        (let waiting (rows .IoResource:wait_closed))
        (rows .IoResource:close)
        (let cancelled (match (pending .join) ^exhaustive false
          (when TaskOutcome/cancelled true)))
        (await waiting)
        (await (rows .IoResource:wait_closed))
        (await (pipe/0 .IoResource:wait_closed))
        (pipe/1 .IoResource:close)
        (await (pipe/1 .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [cancelled stats/io_cleanup_leases]
      """), newGlobalScope())
      check value.print() == "[true 0]"

    test "ten-megabyte file streams with bounded I/O retention":
      let path = getTempDir() / "gene-csv-stream-large.csv"
      let record = "group," & repeat('x', 4089) & "\n"
      writeFile(path, repeat(record, 2560))
      defer: removeFile(path)
      let scope = newGlobalScope(newApplication(getTempDir()))
      scope.define("path", newStr(path))
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let source (await ($io/open_read path)))
        (let rows ($csv/reader source ^own_reader true))
        (var count 0)
        (while true
          (let row (await (rows .next)))
          (if ($nil? row) (then (break)))
          (set count (+ count 1)))
        (rows .IoResource:close)
        (await (rows .IoResource:wait_closed))
        (let stats ($runtime/gc_stats))
        [count (<= stats/io_peak_retained_bytes 1048576)
         (<= stats/csv_parser_peak_resource_bytes 73728)
         stats/csv_parser_retained_bytes stats/io_cleanup_leases]
      """), scope)
      check value.print() == "[2560 true true 0 0]"

    test "owned upstream close failure is repeatable through wait_closed":
      let value = run(compileSource("""
        (let IoResource $io/IoResource)
        (let source ($io/testing/new))
        ($io/testing/fail_close source "broken")
        (let rows ($csv/reader source ^own_reader true))
        (rows .IoResource:close)
        [(try (await (rows .IoResource:wait_closed)) false catch IoError true)
         (try (await (rows .IoResource:wait_closed)) false catch IoError true)]
      """), newGlobalScope())
      check value.print() == "[true true]"
