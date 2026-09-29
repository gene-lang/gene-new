## Runtime leak tests for closures, scopes, and eval overlays.
##
## Managed heap values (strings, lists, maps, nodes, functions, native fns) are
## manually refcounted; `Scope` is an ORC ref. Scope-owned functions are stored
## with weak captured-scope back-edges, and values escaping a run/eval boundary
## are strengthened before returning. These tests pin the retain/release behavior
## around the old `Scope -> Value(fn) -> Scope` leak class.
##
## Build with: nim c -r -d:geneRcStats --path:src tests/test_rc.nim

when defined(geneRcStats):
  import gene/[compiler, native_api, pending_exception, printer, types, vm]
  import std/[os, unittest]

  # A container's generated destructor can release its elements with the
  # pending-exception flag still set; each element's destructor must finish.
  type UnwindProbe = object
    id: uint64
  var unwindProbeSlots = [1, 2, 3]
  var unwindProbeTrail: seq[string]
  proc unwindProbeSlot(i: int): int = unwindProbeSlots[i] # can raise
  proc `=destroy`(probe: var UnwindProbe) =
    withoutPendingException:
      if probe.id != 0:
        unwindProbeTrail.add "enter"
        discard unwindProbeSlot(1)
        unwindProbeTrail.add "finished"
  proc `=copy`(dest: var UnwindProbe, src: UnwindProbe) = dest.id = src.id
  proc newUnwindProbe(): UnwindProbe = UnwindProbe(id: 1)
  proc raiseUnwindProbe() = raise newException(IOError, "unwind")
  proc unwindLiteralProbes() =
    var probes = @[newUnwindProbe(), newUnwindProbe()]
    raiseUnwindProbe()
    echo probes.len
  proc unwindAddedProbes() =
    var probes: seq[UnwindProbe]
    probes.add newUnwindProbe()
    probes.add newUnwindProbe()
    raiseUnwindProbe()
    echo probes.len

  var ffiAutoLibraryCloses, ffiAutoPointerReleases: int
  proc closeAutoLibrary(handle: pointer) {.nimcall.} =
    discard handle
    inc ffiAutoLibraryCloses
  proc releaseAutoPointer(address: pointer) {.cdecl.} =
    discard address
    inc ffiAutoPointerReleases

  proc leakedManaged(src: string, useLocalSlots = true): int =
    ## Managed heap objects surviving one run of `src` after the program scope is
    ## dropped. The shared built-ins root is primed once below, so it cancels out.
    GC_fullCollect()
    let before = liveManaged
    block:
      var scope = newGlobalScope()
      discard run(compileSource(src, useLocalSlots = useLocalSlots), scope)
      scope = nil
    GC_fullCollect()
    result = liveManaged - before

  initModuleContext(getCurrentDir())
  discard newGlobalScope()   # build the built-ins root into the baseline
  GC_fullCollect()

  suite "rc — closures and scopes (geneRcStats)":
    test "a directly stored Path releases its held-message scope":
      for slots in [true, false]:
        check leakedManaged("(Path \".Self:head\")",
          useLocalSlots = slots) == 0
        check leakedManaged("(let p (Path \".Self:head\")) p",
          useLocalSlots = slots) == 0

    test "a returned child-scope Path exposes the existing parent cycle limit":
      for slots in [true, false]:
        let closureLeak = leakedManaged("""
          (fn make_fn [] (scope (let x 1) (fn [] x)))
          (let f (make_fn)) (f)
        """, useLocalSlots = slots)
        let pathLeak = leakedManaged("""
          (fn make_path []
            (scope
              (let p (Path ".Self:head"))
              p))
          (let p (make_path))
          ($assert (== (p (quote (payload))) (quote payload)))
        """, useLocalSlots = slots)
        # The unresolved cross-scope cycle retains one function plus its
        # captured child/root scopes in the control, or one Path and its held
        # Message plus the same scopes here. If the control retires, this Path
        # must retire too; do not silently promote one without the other.
        if closureLeak == 0:
          check pathLeak == 0
        else:
          check pathLeak == closureLeak + 1

    test "abandoned owned pointers retire before their borrowed FFI image":
      ffiAutoLibraryCloses = 0
      ffiAutoPointerReleases = 0
      var library = newFfiLibrary(cast[pointer](1), "auto-fixture",
                                  closeAutoLibrary)
      var owned = newCForeignOwnedPtr(cast[pointer](2),
        cast[pointer](releaseAutoPointer), library = library)
      expect GeneError:
        library.closeFfiLibrary()
      owned = NIL
      GC_fullCollect()
      check ffiAutoPointerReleases == 1
      library.closeFfiLibrary()
      check ffiAutoLibraryCloses == 1
      library = NIL
      GC_fullCollect()
      check ffiAutoLibraryCloses == 1
      var abandoned = newFfiLibrary(cast[pointer](3), "abandoned-fixture",
                                    closeAutoLibrary)
      abandoned = NIL
      GC_fullCollect()
      check ffiAutoLibraryCloses == 2

    test "returned local types retain and release their declaration scopes":
      for slots in [true, false]:
        check leakedManaged("""
          (type A ^props {} (message m [] : Str "A"))
          (type B ^props {} (message m [] : Str "B"))
          (fn make [p label]
            (type C : p ^props {}
              (message up [] : Str ($ label (super .m)))
              (message own_type [] C))
            C)
          (var C1 (make A "first:"))
          (var C2 (make B "second:"))
          ($assert (== ((C1) .up) "first:A"))
          ($assert (== ((C2) .up) "second:B"))
          ($assert (== ((C1) .own_type) C1))
          (set C1 nil)
          (set C2 nil)
        """, useLocalSlots = slots) == 0

      GC_fullCollect()
      let before = liveManaged
      var saved = NIL
      block:
        var scope = newGlobalScope()
        saved = run(compileSource("""
          (fn make [label]
            (type Local ^props {} (message value [] label))
            Local)
          (make "retained")
        """), scope)
        scope = nil
      GC_fullCollect()
      block:
        let scope = newGlobalScope()
        scope.define("Saved", saved)
        check run(compileSource("((Saved) .value)"), scope).strVal == "retained"
      saved = NIL
      GC_fullCollect()
      check liveManaged == before

    test "Self contracts and declaration assemblies release their receiver identities":
      check leakedManaged("""
        (type A ^props {^next Self?}
          (message copy [] : Self self)
          (message checker [] (fn [x : Self] : Bool true)))
        (type B : A ^props {})
        (let b (B ^next nil))
        (var checker (b .checker))
        (checker (A ^next nil))
        (set checker nil)
        (A .fields)
      """) == 0
      check leakedManaged("""
        (type A ^props {} (message check [x : Later] : Bool true))
        (alias Later Self)
        ((A) .check (A))
      """) == 0
      check leakedManaged("""
        (fn test []
          (type Boom ^props {} (message raise [] : Int ^errors [Self] (fail self)))
          (impl Error for Boom
            (message message [] : Str ^errors [] "boom"))
          (try ((Boom) .raise) catch Boom nil))
        (test)
      """) == 0

    test "scalar program leaks nothing (measurement sanity)":
      check leakedManaged("(+ 1 2)") == 0

    test "strict message proof signatures do not retain their owning scope":
      check leakedManaged("""
        (mod checked ^errors_mode strict)
        (type Item ^props {}
          (message copy [] : Self ^errors [] self)
          (message value [] : Int ^errors [] 7))
        (fn read [item : Item] : Int ^errors [] ((item .copy) .value))
        (read (Item))
      """) == 0

    test "inferred returned-callable proofs release their source scopes":
      check leakedManaged("""
        (mod checked ^errors_mode strict)
        (fn source ^private true [] 1)
        (fn factory ^private true [] (fn [] (source)))
        (fn client [] ^errors [] ((factory)))
        (client)
      """) == 0
      GC_fullCollect()
      let before = liveManaged
      var saved = NIL
      block:
        var scope = newGlobalScope()
        saved = run(compileSource("""
          (mod checked ^errors_mode strict)
          (fn factory ^private true []
            (fn callback [] ^errors [] 1)
            callback)
          (factory)
        """), scope)
        scope = nil
      GC_fullCollect()
      check saved.call().intVal == 1
      saved = NIL
      GC_fullCollect()
      check liveManaged == before

    test "returned protocol messages retain and release their binding scope":
      GC_fullCollect()
      let before = liveManaged
      var saved = NIL
      block:
        var scope = newGlobalScope()
        # A canonical impl intentionally remains an application root. Use an
        # overlay so the escaped message is the only owner after this block.
        scope.implOverlayRoot = true
        saved = run(compileSource("""
          (mod checked ^errors_mode strict)
          (protocol P (message value [] : Int ^errors []))
          (type Item ^props {})
          (impl P for Item (message value [] : Int ^errors [] 7))
          (fn factory ^private true [unused : Int] P:value)
          [(factory 1) (Item)]
        """), scope)
        scope = nil
      GC_fullCollect()
      check saved.listItems[0].call(@[saved.listItems[1]]).intVal == 7
      saved = NIL
      GC_fullCollect()
      check liveManaged == before

    test "selected core witnesses keep escaped code and release it with the Type":
      GC_fullCollect()
      let before = liveManaged
      var saved = NIL
      block:
        var scope = newGlobalScope()
        scope.implOverlayRoot = true
        saved = run(compileSource("""
          (type WitnessKey ^props {^text Str})
          (impl ValueEq for WitnessKey
            (message equal [other : WitnessKey] : Bool
              (== self/text other/text)))
          (impl ValueHash for WitnessKey
            (message hash [] : Int ($hash self/text)))
          (impl ValueOrder for WitnessKey
            (message compare [other : WitnessKey] : Int
              (if (< self/text other/text) -1
                (if (> self/text other/text) 1 0))))
          WitnessKey
        """), scope)
        scope = nil
      GC_fullCollect()
      check saved.typeCoreWitness(cvEqual).kind == vkFunction
      check saved.typeCoreWitness(cvHash).kind == vkFunction
      check saved.typeCoreWitness(cvCompare).kind == vkFunction
      block:
        let scope = newGlobalScope()
        scope.define("Saved", saved)
        check run(compileSource(
          "(== (Saved ^text \"x\") (Saved ^text \"x\"))"),
          scope).boolVal
        check run(compileSource("($hash #(Saved ^text \"x\"))"),
          scope).kind == vkInt
        let sorted = run(compileSource(
          "($order/sort [(Saved ^text \"b\") (Saved ^text \"a\")])"),
          scope)
        check sorted.listItems[0].props["text"].strVal == "a"
      saved = NIL
      GC_fullCollect()
      check liveManaged == before

    test "io helper Tasks release protocol captures after structured settlement":
      let scope = newGlobalScope()
      discard run(compileSource("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (type Sink ^props {})
        (impl AsyncWriter for Sink
          (message write [data : Bytes] : (Task Int Error)
            (spawn ^lane root ($binary/size data)))
          (message flush [] : (Task Nil Error)
            (spawn ^lane root nil)))
        (impl IoResource for Sink
          (message close [] : Nil nil)
          (message wait_closed [] : (Task Nil Error)
            (spawn ^lane root nil)))
      """), scope)
      let body = compileSource("""
        (scope
          (let sink (Sink))
          (await ($io/write_all sink ($binary/from_str "abc")))
          (sink .IoResource:close)
          (await (sink .IoResource:wait_closed)))
      """)
      GC_fullCollect()
      let before = liveManaged
      for _ in 0 ..< 10:
        discard run(body, scope)
      GC_fullCollect()
      check liveManaged == before

    test "closed native test I/O resources release their Task and handle roots":
      check leakedManaged("""
        (let AsyncWriter $io/AsyncWriter)
        (let IoResource $io/IoResource)
        (var resource ($io/testing/new))
        (let operation (resource .AsyncWriter:write ($binary/from_str "abc")))
        (resource .IoResource:close)
        ($io/testing/complete_write resource 2)
        (await (resource .IoResource:wait_closed))
        (set resource nil)
      """) == 0

    when compileOption("threads") and defined(posix):
      test "closed worker-backed file readers release handles and Tasks":
        let path = "tmp/gene-io-rc-reader.bin"
        createDir(path.parentDir)   # tmp/ is ignored, so a fresh checkout lacks it
        writeFile(path, "abc")
        defer: removeFile(path)
        check leakedManaged("""
          (let AsyncReader $io/AsyncReader)
          (let IoResource $io/IoResource)
          (var reader (await ($io/open_read "tmp/gene-io-rc-reader.bin")))
          (await (reader .AsyncReader:read 3))
          (reader .IoResource:close)
          (await (reader .IoResource:wait_closed))
          (set reader nil)
          ($runtime/gc_stats)
        """) == 0

      test "closed worker-backed file writers release copied buffers":
        let path = "tmp/gene-io-rc-writer.bin"
        createDir(path.parentDir)   # tmp/ is ignored, so a fresh checkout lacks it
        if fileExists(path): removeFile(path)
        defer:
          if fileExists(path): removeFile(path)
        check leakedManaged("""
          (let AsyncWriter $io/AsyncWriter)
          (let IoResource $io/IoResource)
          (var writer (await ($io/open_write "tmp/gene-io-rc-writer.bin")))
          (await (writer .AsyncWriter:write ($binary/from_str "abc")))
          (writer .IoResource:close)
          (await (writer .IoResource:wait_closed))
          (set writer nil)
          ($runtime/gc_stats)
        """) == 0

      test "closed pipe endpoints release both descriptor handles":
        check leakedManaged("""
          (let AsyncReader $io/AsyncReader)
          (let AsyncWriter $io/AsyncWriter)
          (let IoResource $io/IoResource)
          (let endpoints ($io/pipe))
          (let reader endpoints/0)
          (let writer endpoints/1)
          (await (writer .AsyncWriter:write ($binary/from_str "x")))
          (writer .IoResource:close)
          (await (writer .IoResource:wait_closed))
          (await (reader .AsyncReader:read 2))
          (await (reader .AsyncReader:read 2))
          (reader .IoResource:close)
          (await (reader .IoResource:wait_closed))
          ($runtime/gc_stats)
        """) == 0

      test "subprocess stdout releases its duplicated pipe descriptor":
        check leakedManaged("""
          (let AsyncReader $io/AsyncReader)
          (let IoResource $io/IoResource)
          (let endpoints ($io/pipe))
          (let reader endpoints/0)
          (let writer endpoints/1)
          (let task ($os/exec_stream_async ^cmd "printf"
            ^args ["abc"] ^stdout_pipe writer))
          (await task)
          (await (reader .AsyncReader:read 3))
          (await (reader .AsyncReader:read 3))
          (await (writer .IoResource:wait_closed))
          (reader .IoResource:close)
          (await (reader .IoResource:wait_closed))
          ($runtime/gc_stats)
        """) == 0

      test "subprocess stdout and stderr release both duplicated writers":
        check leakedManaged("""
          (let AsyncReader $io/AsyncReader)
          (let IoResource $io/IoResource)
          (let stdout ($io/pipe))
          (let stderr ($io/pipe))
          (let task ($os/exec_stream_async ^cmd "sh"
            ^args ["-c" "printf o; printf e >&2"]
            ^stdout_pipe stdout/1 ^stderr_pipe stderr/1))
          (await task)
          (await (stdout/0 .AsyncReader:read 1))
          (await (stderr/0 .AsyncReader:read 1))
          (await (stdout/0 .AsyncReader:read 1))
          (await (stderr/0 .AsyncReader:read 1))
          (await (stdout/1 .IoResource:wait_closed))
          (await (stderr/1 .IoResource:wait_closed))
          (stdout/0 .IoResource:close)
          (stderr/0 .IoResource:close)
          (await (stdout/0 .IoResource:wait_closed))
          (await (stderr/0 .IoResource:wait_closed))
          ($runtime/gc_stats)
        """) == 0

      test "subprocess stdin and stdout release borrowed pipe endpoints":
        check leakedManaged("""
          (let AsyncReader $io/AsyncReader)
          (let AsyncWriter $io/AsyncWriter)
          (let IoResource $io/IoResource)
          (let input ($io/pipe))
          (let output ($io/pipe))
          (let task ($os/exec_stream_async ^cmd "cat"
            ^stdin_pipe input/0 ^stdout_pipe output/1))
          (await (input/1 .AsyncWriter:write ($binary/from_str "abc")))
          (input/1 .IoResource:close)
          (await (input/1 .IoResource:wait_closed))
          (await task)
          (await (output/0 .AsyncReader:read 3))
          (await (output/0 .AsyncReader:read 3))
          (await (input/0 .IoResource:wait_closed))
          (await (output/1 .IoResource:wait_closed))
          (output/0 .IoResource:close)
          (await (output/0 .IoResource:wait_closed))
          ($runtime/gc_stats)
        """) == 0

      test "CSV reader releases its source and parser state after close":
        check leakedManaged("""
          (let IoResource $io/IoResource)
          (let pipe ($io/pipe))
          (let rows ($csv/reader pipe/0 ^own_reader true))
          (await ($io/write_all pipe/1 ($binary/from_str "a,b\n")))
          (pipe/1 .IoResource:close)
          (await (pipe/1 .IoResource:wait_closed))
          (await (rows .next))
          (await (rows .next))
          (rows .IoResource:close)
          (await (rows .IoResource:wait_closed))
        """) == 0

      test "TCP listener and duplex streams release native handles":
        check leakedManaged("""
          (let IoResource $io/IoResource)
          (let listener (await ($io/tcp_listen "127.0.0.1" 0)))
          (let accepting (listener .accept))
          (let client (await ($io/tcp_connect "127.0.0.1"
            (listener .local_port))))
          (let server (await accepting))
          (client .IoResource:close)
          (server .IoResource:close)
          (listener .IoResource:close)
          (await (client .IoResource:wait_closed))
          (await (server .IoResource:wait_closed))
          (await (listener .IoResource:wait_closed))
          ($runtime/gc_stats)
        """) == 0

      test "owned HTTP Client retires its multi service after close":
        check leakedManaged("""
          (let IoResource $io/IoResource)
          (let client (await ($net/http_client/open)))
          (client .IoResource:close)
          (await (client .IoResource:wait_closed))
          (await (client .IoResource:wait_closed))
          ($runtime/gc_stats)
        """) == 0

    test "completed custom AsyncReader calls release their admission roots":
      let source = """
        (let AsyncReader $io/AsyncReader)
        (fn one []
          (scope
            (type Reader ^props {})
            (impl AsyncReader for Reader
              (message read [max_bytes : Int] : (Task Bytes? Error)
                (spawn ^lane root nil)))
            (let reader (Reader))
            (await (reader .AsyncReader:read 16))
            (let stats ($runtime/gc_stats))
            ($assert (== stats/io_read_guards 0))))
        (repeat 40 (one))
        ($runtime/test_collect)
      """
      check leakedManaged(source) == 0

    test "released error witnesses reclaim their formatter environments":
      check leakedManaged("""
        (fn raise_local []
          (type Local ^props {^message Str})
          (impl Error for Local
            (message message [] : Str ^errors [] self/message))
          (let original (Local ^message "local"))
          (fail original))
        (repeat 10 (try (raise_local) catch Error $err_msg))
      """) == 0
      check leakedManaged("""
        (scope
          (type Local ^props {^message Str}
            (impl Error (message message [] : Str ^errors [] self/message)))
          (var original (Local ^message "named"))
          (try (fail original) catch Error $err_msg))
      """, useLocalSlots = false) == 0
      check leakedManaged("""
        (fn error_factory []
          (type Local ^props {^message Str})
          (impl Error for Local)
          (try (fail (Local ^message "saved")) catch Error
            (fn [] $err_msg)))
        (var display (error_factory))
        (display)
        (set display nil)
      """) == 0

    test "$runtime/gc_stats exposes live managed count":
      let scope = newGlobalScope()
      let stats = run(compileSource("($runtime/gc_stats)"), scope)
      check stats.kind == vkMap
      check stats.mapEntries["rc_stats?"].boolVal
      check stats.mapEntries["live_managed"].kind == vkInt
      check stats.mapEntries["live_managed"].intVal >= 0
      let classes = stats.mapEntries["managed_classes"]
      check classes.kind == vkMap
      var classTotal = 0'i64
      for _, count in classes.mapEntries:
        check count.kind == vkInt
        check count.intVal >= 0
        classTotal += count.intVal
      check classTotal == stats.mapEntries["live_managed"].intVal
      check stats.mapEntries["native_roots"].kind == vkInt
      let initialRoots = nativeRootCount()
      let nativeRoot = geneRoot(newStr("retained"))
      check nativeRootCount() == initialRoots + 1
      geneRootRelease(nativeRoot)
      geneRootRelease(nativeRoot)
      check nativeRootCount() == initialRoots
      check stats.mapEntries["cleanup_leases"].kind == vkNil
      check stats.mapEntries["io_root_tasks"].kind == vkInt
      check stats.mapEntries["io_root_cleanup_tasks"].kind == vkInt
      check stats.mapEntries["io_retained_bytes"].kind == vkInt
      check stats.mapEntries["io_peak_retained_bytes"].kind == vkInt
      check stats.mapEntries["io_cleanup_leases"].kind == vkInt
      check stats.mapEntries["io_open_resources"].kind == vkInt
      check stats.mapEntries["io_file_open_resources"].kind == vkInt
      check stats.mapEntries["cycle_candidates"].kind == vkNil

    test "test-only collection runs at the root-lane safe point":
      let scope = newGlobalScope()
      check run(compileSource("($runtime/test_collect)"), scope).kind == vkNil
      expect GeneError:
        discard run(compileSource("($runtime/test_collect 1)"), scope)

    test "transient anonymous closures are reclaimed":
      check leakedManaged("((fn [] (fn [] 1)))") == 0
      check leakedManaged("((fn [n] (* n n)) 5)") == 0

    test "scope-owned named functions are reclaimed":
      check leakedManaged("(fn f [] 1)") == 0
      check leakedManaged("(fn make [] (var x 1) (fn [] x)) (make)") == 0
      check leakedManaged("(fn fac [n] (if (== n 0) 1 (* n (fac (- n 1))))) (fac 5)") == 0

    test "escaped named functions release their scope once only it holds them":
      # A returned container also kept in a local, and a named function stored
      # into a local cell, must not keep their defining call scope in a cycle.
      check leakedManaged("(fn make [] (fn local [] 1) (var box {^f local}) box) " &
                          "(repeat 50 (make))") == 0
      check leakedManaged("(fn run [] (fn local [] 1) (var c ($cell nil)) " &
                          "(c .set local) nil) (repeat 50 (run))") == 0
      check leakedManaged("(type Box ^props {^f Any}) " &
                          "(fn make [] (fn local [] 1) (var box (Box ^f local)) box) " &
                          "(repeat 50 (make))") == 0

    test "released bound calls reclaim captures arguments and policy metadata":
      check leakedManaged("(fn target [x] (+ x 1)) " &
        "(var bound ($runtime/bind_call target [2] ^policy {^max_steps 100})) " &
        "(bound) (set bound nil)") == 0
      check leakedManaged("(fn make [x] " &
        " ($runtime/bind_call (fn [y] (+ x y)) [2])) " &
        "((make 40))") == 0
      check leakedManaged("(fn target [] 1) " &
        "(repeat 100 (var bound ($runtime/bind_call target [])) " &
        " (try (bound) ensure (set bound nil)))") == 0
      # Model an invocation adapter that owns a durable binding only until the
      # call settles. Ordinary factory closures also need their local cycle
      # broken; GC of arbitrary mixed scope/Value cycles is not implemented.
      check leakedManaged("(fn target [] (fail \"expected\")) " &
        "(fn invoke [] (var bound ($runtime/bind_call target [])) " &
        " (try (bound) catch Any nil ensure (set bound nil))) " &
        "(repeat 100 (invoke))") == 0

    test "checked callable views reclaim targets and invocation scopes":
      check leakedManaged("(let f : (Callable [Int] Int) (fn [x] (+ x 1))) (f 2)") == 0
      check leakedManaged("(fn make [n] : (Callable [Int] Int) (fn [x] (+ n x))) " &
        "(repeat 100 ((make 3) 2))") == 0
      check leakedManaged("(fn use [f : (Callable [Int] Int)] (f 1)) " &
        "(repeat 100 (use (fn [x] x)))") == 0
      check leakedManaged("(fn bad [x] (fail \"expected\")) " &
        "(fn use [f : (Callable [Int] Int)] (try (f 1) catch Any nil)) " &
        "(repeat 100 (use bad))") == 0
      check leakedManaged("(let f : (Callable [] Any ^errors []) " &
        "(fn [] ($assert false))) (try (f) catch ErrorContractViolation nil)") == 0

    test "prepared pipeline captures are released on close and exhaustion":
      check leakedManaged("(let s ([1 2] => + 3)) (s .close)") == 0
      check leakedManaged("([1 2] => + 3 -> $into [])") == 0
      check leakedManaged("(fn make [n] ([1 2] => + n)) " &
        "(repeat 100 (let s (make 3)) (s .close))") == 0
      check leakedManaged("(let args [2 3]) " &
        "(fn collect [items...] items) " &
        "(let s ([1] => collect args...)) (s .close)") == 0
      check leakedManaged("(fn broken [x] (fail \"expected\")) " &
        "(let s ([1] => broken)) (try (s .next) catch Any nil)") == 0

    test "filesystem walk releases retained frames after early close":
      let dir = getTempDir() / "gene-walk-rc-spec"
      if dirExists(dir): removeDir(dir)
      createDir(dir)
      writeFile(dir / "one.txt", "one")
      let literal = newStr(dir).print()
      check leakedManaged("(let s ($fs/walk " & literal & ")) " &
                          "(s .next) (s .close)") == 0
      check leakedManaged("(($fs/walk " & literal & ") -> $into [])") == 0

    test "packed and generic buffer backing values are reclaimed":
      check leakedManaged("(repeat 100 (var b ($buffer U8 65536)) (b .fill 7))") == 0
      check leakedManaged("(var b ($buffer [(fn [] 7)])) " &
        "((b .get 0)) (set b nil)") == 0

    test "proper tail transfers reclaim frames scopes and trace windows":
      check leakedManaged(
        "(fn is_even [n] (if (== n 0) true (is_odd (- n 1)))) " &
        "(fn is_odd [n] (if (== n 0) false (is_even (- n 1)))) " &
        "(is_even 10000)") == 0
      check leakedManaged(
        "(fn consume [xs n] " &
        "  (match xs " &
        "    (when [] (if (== n 0) 0 (consume [n] (- n 1)))) " &
        "    (else (consume [] n)))) " &
        "(consume [] 5000)") == 0

    test "tail fallback retains no more than the equivalent non-tail closure":
      let nonTailLeak = leakedManaged(
        "(var saved nil) " &
        "(fn retain [f] (set saved f) 0) " &
        "(fn outer [x] (var inner (fn [] x)) (+ 0 (retain inner))) " &
        "(outer 7) (saved)")
      let tailLeak = leakedManaged(
        "(var saved nil) " &
        "(fn retain [f] (set saved f) 0) " &
        "(fn outer [x] (var inner (fn [] x)) (retain inner)) " &
        "(outer 7) (saved)")
      check tailLeak == nonTailLeak

    test "module reference targets and structural fixups are reclaimed":
      check leakedManaged("#Ref shared [1 2] ($deref shared)") == 0
      check leakedManaged(
        "(var before #Deref shared) #Ref shared [1] " &
        "(same? before ($deref shared))") == 0
      check leakedManaged("#Ref callable (fn [] 1) (($deref callable))") == 0
      check leakedManaged("#Ref cycle ($cell #Deref cycle) " &
                          "(same? (($deref cycle) .get) ($deref cycle))") == 0

    test "self-referential closures stored in their scope are reclaimed":
      check leakedManaged("(var f nil) (set f (fn [] f))") == 0

    test "eval overlays without escaping functions are reclaimed":
      check leakedManaged("(eval (quote (+ 1 2)) ^in (env))") == 0
      check leakedManaged("(eval (quote cap) " &
                          "^in (env ^bindings {^cap [1]}))") == 0
      check leakedManaged("(eval (quote (do " &
                          "  (protocol P (message value [self] : Int)) " &
                          "  (type T ^props {}) " &
                          "  (impl P for T (message value [self] : Int 1)))) " &
                          "^in (env))") == 0

    test "protocol-typed cells do not retain their annotation scope":
      check leakedManaged(
        "(fn make [] " &
        "  (protocol Tagged) " &
        "  (type Item ^props {}) " &
        "  (impl Tagged for Item) " &
        "  (var cell : (Cell Tagged) ($cell (Item)))) " &
        "(repeat 500 (make))") == 0

    test "eval named functions are reclaimed when the result does not escape":
      check leakedManaged("(eval (quote (fn f [] f)) ^in (env))") == 0

    proc sandboxOptions(entry: string): string =
      let directory = getCurrentDir() /
        "tests/profiles/native-app/lifetime/plugin"
      "{^dir " & newStr(directory).print() & " ^entry \"" & entry & "\" " &
        "^grants [] ^shared [] ^label \"rc\" " &
        "^policy {^max_steps 1000 ^max_memory_mb 16 ^timeout_ms 1000}}"

    # Retirement is off where Gene worker lanes exist (AtomicArc).
    when not defined(gcAtomicArc):
      test "this toolchain supports released-generation retirement":
        # Fails after a Nim upgrade that changes the ORC header layout, rather
        # than letting retirement switch itself off and leak generations.
        check generationRetirementAvailable()

      test "compiling numeric and dynamic paths releases partial spelling lists":
        # The Value counters cannot see leaked Nim seq/string allocations.
        # Exercise successful compilation independently of runtime failures.
        const source = "(let xs [1]) (let i 0) [xs/0 xs/%i]"
        proc compileOnce() =
          discard compileSource(source)
        for i in 0 ..< 20:
          compileOnce()
        GC_fullCollect()
        let before = getOccupiedMem()
        for i in 0 ..< 100:
          compileOnce()
        GC_fullCollect()
        let after = getOccupiedMem()
        check after == before

      const isolatedWitnessSource = """
        (let T (eval (quote (do
          (type Key ^props {^n Int})
          (impl ValueEq for Key
            (message equal [other : Key] : Bool (== self/n other/n)))
          (impl ValueHash for Key (message hash [] : Int self/n))
          Key)) ^in (env)))
        T
      """

      proc isolatedWitnessEvaluation() =
        let scope = newGlobalScope()
        scope.implOverlayRoot = true
        scope.moduleRoot = false
        scope.moduleStatic = false
        var chunk = compileSource(isolatedWitnessSource)
        block:
          let value = run(chunk, scope)
          check value.kind == vkType
        chunk = nil
        check retireEvaluationScope(scope) > 0

      test "isolated host retirement discovers nested eval Type cycles":
        isolatedWitnessEvaluation()
        GC_fullCollect()
        let before = liveManaged
        for i in 0 ..< 30:
          isolatedWitnessEvaluation()
        GC_fullCollect()
        check liveManaged == before

      test "isolated host retirement preserves externally held Types":
        GC_fullCollect()
        let before = liveManaged
        block:
          let scope = newGlobalScope()
          scope.implOverlayRoot = true
          scope.moduleRoot = false
          scope.moduleStatic = false
          var chunk = compileSource(isolatedWitnessSource)
          var retained = run(chunk, scope)
          chunk = nil
          check retireEvaluationScope(scope) == 0
          block:
            let consumer = newGlobalScope()
            consumer.define("Saved", retained)
            check run(compileSource("(== (Saved ^n 7) (Saved ^n 7))"), consumer) == TRUE
          retained = NIL
          check retireEvaluationScope(scope) > 0
        GC_fullCollect()
        check liveManaged == before

      proc reloadFixture(name: string): (Application, string) =
        let dir = getTempDir() / name
        createDir(dir)
        let path = dir / "reloaded.gene"
        writeFile(path, "(protocol Local (message value [] : Int)) " &
          "(type Item ^props {^n Int} (message direct [] : Int self/n)) " &
          "(impl Local for Item (message value [] : Int self/n)) " &
          "(var item (Item ^n 7))")
        (newApplication(dir), path)

      proc reloadAndCollect(app: Application, path: string, times: int) =
        for i in 0 ..< times:
          discard app.reloadFileModule(path)
        GC_fullCollect()

      test "reloaded module roots retire once nothing reaches them":
        # Each reload drains the roots earlier reloads queued, so an app that
        # only reloads keeps at most one pending root.
        let (app, path) = reloadFixture("gene-rc-reload")
        discard app.loadFileModule(path)
        app.reloadAndCollect(path, 2)
        let before = liveManaged
        app.reloadAndCollect(path, 5)
        check liveManaged == before

      proc runInt(scope: Scope, src: string): int =
        run(compileSource(src), scope).intVal

      proc retainedReloadLeak(): int =
        ## Managed values left after an item retained across reloads is used
        ## and dropped.
        let (app, path) = reloadFixture("gene-rc-reload-retained")
        let scope = newGlobalScope(app)
        scope.define("item", NIL)
        discard app.loadFileModule(path)
        app.reloadAndCollect(path, 2)
        let before = liveManaged
        block:
          # Nim keeps call temporaries to the end of the enclosing scope (hence
          # also runInt). The module Value this lookup goes through must not
          # outlive it, or it keeps the whole generation alive, not just item.
          scope.assign("item",
            app.loadFileModule(path).moduleRootNamespace.nsScope.lookup("item"))
        app.reloadAndCollect(path, 3)
        if scope.runInt("(item .direct)") != 7:
          return -1
        scope.assign("item", NIL)
        app.reloadAndCollect(path, 2)
        liveManaged - before

      test "a value retained from a reloaded module keeps it usable until dropped":
        check retainedReloadLeak() == 0

      test "a function escaping eval into its caller is reclaimed":
        # The escaped function captures the eval scope, whose chain reaches the
        # calling scope that binds it: a cycle only returned-call retirement
        # breaks.
        check leakedManaged("""
          (fn body [] (let f (eval (quote (fn [] 2)) ^in (env))) (f))
          (var i 0)
          (while (< i 50) (body) (set i (+ i 1)))
          ($runtime/test_collect)
        """) == 0

      test "an escaped eval function the caller keeps stays callable":
        # Batches retire around it while it is owned from outside.
        let scope = newGlobalScope()
        check run(compileSource("""
          (fn body [] (let f (eval (quote (fn [] 2)) ^in (env))) f)
          (var kept (body))
          (var i 0)
          (while (< i 80) (body) (set i (+ i 1)))
          ($runtime/test_collect)
          (kept)
        """), scope).intVal == 2

      proc repeatedBodyLeak(defs: string): int =
        ## Managed values left after `(body)` from `defs` runs 30 times.
        leakedManaged(defs & """
          (var i 0)
          (while (< i 30) (body) (set i (+ i 1)))
          ($runtime/test_collect)
        """)

      test "mutable captures that later hold their closure retire with the activation":
        # A stable binding can still name a mutable object. Copying it into a
        # detached capture scope hides the cycle from activation retirement.
        for body in [
          "(let c ($cell nil)) (c .set (fn [] c))",
          "(let xs []) (xs .push (fn [] xs))",
          "(let m {^held nil}) (m .put \"held\" (fn [] m))",
          "(let n ($thaw (quote #(record ^held nil)))) (set n/held (fn [] n))",
          "(let c ($cell nil)) (let xs ($freeze_shallow [c])) " &
            "(c .set (fn [] xs))",
          "(let c ($cell nil)) (let get_c (fn [] c)) " &
            "(c .set (fn [] get_c))",
          "(let xs []) (let m {^held nil}) " &
            "(let n ($thaw (quote #(record ^held nil)))) (let c ($cell nil)) " &
            "(xs .push m) (m .put \"held\" n) (set n/held c) " &
            "(c .set (fn [] xs))"
        ]:
          checkpoint body
          check repeatedBodyLeak("(fn body [] " & body & " nil)") == 0

      test "retained mutable captures keep their object identity and remain callable":
        let scope = newGlobalScope()
        check print(run(compileSource("""
          (fn make []
            (let c ($cell nil))
            (c .set (fn [] c))
            c)
          (var kept (make))
          (repeat 30 (make))
          ($runtime/test_collect)
          (let get_self (kept .get))
          (same? (get_self) kept)
        """), scope)) == "true"

      test "child-scope closure cycles retire when their activation ends":
        # A closure capturing a loop or match scope, stored in the enclosing
        # scope's binding or in a container it binds, closes
        # scope -> value -> closure -> child scope -> scope.
        # Tail calls, including into the closure itself.
        check repeatedBodyLeak(
          "(fn body [] (var f nil) (for x in [2] (set f (fn [] x))) (f))") == 0
        check repeatedBodyLeak("(fn body [] (var hs []) " &
          "(for x in [1 2 3] (hs .push (fn [] x))) (hs/0))") == 0
        check repeatedBodyLeak("(fn body [] (var f nil) " &
          "(match [3] (when [x] (set f (fn [] x)))) (f))") == 0
        check repeatedBodyLeak("(fn other [a] (var b a) b) " &
          "(fn body [] (var f nil) (for x in [2] (set f (fn [] x))) (other 1))") == 0
        # The Int fast return, an explicit return from inside the loop, and an
        # error unwinding past the scope.
        check repeatedBodyLeak(
          "(fn body [] (var f nil) (for x in [2] (set f (fn [] x))) 5)") == 0
        check repeatedBodyLeak("(fn body [] (var f nil) " &
          "(for x in [2] (set f (fn [] x)) (return 1)) nil)") == 0
        check repeatedBodyLeak("(fn inner [] (var f nil) " &
          "(for x in [2] (set f (fn [] x))) (fail \"boom\")) " &
          "(fn body [] (try (inner) catch Any nil) nil)") == 0
        # A function a native calls back, and a spawned task body.
        check repeatedBodyLeak("(fn body [] ([1] .map (fn [e] (var f nil) " &
          "(for y in [1] (set f (fn [] y))) 1)) nil)") == 0
        check repeatedBodyLeak("(fn body [] (scope (spawn (do (var f nil) " &
          "(for x in [1] (set f (fn [] x))) (f))) 1) nil)") == 0
        # Loop iterations whose own scope closes the cycle, and closures over
        # the scope itself inside a container or Cell it binds.
        check repeatedBodyLeak("(fn body [] (for x in [1 2] (var f nil) " &
          "(for y in [2] (set f (fn [] y))) (if (== x 1) (continue) (break))) nil)") == 0
        check repeatedBodyLeak(
          "(fn body [] (for x in [1] (var hs [(fn [] x)])) nil)") == 0
        check repeatedBodyLeak("(fn body [] (var hs [(fn [] 1)]) nil)") == 0
        check repeatedBodyLeak(
          "(fn body [] (var c ($cell nil)) (for x in [1] (c .set (fn [] x))) nil)") == 0

      test "a pooled call scope a closure came to hold retires like an unpooled one":
        # `x` is unbound when the closure is made, so it captures the pooled
        # call scope by reference, and a list the scope binds closes the
        # cycle. That activation ends unpooled, through the VM, a native
        # callback, and a tail call.
        check repeatedBodyLeak(
          "(fn body [] (if false (var x 1) nil) (var hs [(fn [] x)]) nil)") == 0
        check repeatedBodyLeak("(fn mk [c] (if c (var x 1) nil) " &
          "(var hs [(fn [] x)]) nil) (fn body [] (mk false))") == 0
        check repeatedBodyLeak("(fn body [] ([0 1] .map (fn [n] " &
          "(if (== n 0) (var x 1) nil) (var hs [(fn [] x)]) nil)) nil)") == 0
        check repeatedBodyLeak("(fn other [a] a) (fn body [] " &
          "(if false (var x 1) nil) (var hs [(fn [] x)]) (other 1))") == 0

      test "a returned value closing a closure cycle retires once released":
        # The return check cannot retire a scope whose cycle the returned value
        # still reaches; it watches the value until the caller lets it go.
        check repeatedBodyLeak(
          "(fn body [] (var f nil) (for x in [2] (set f (fn [] x))) f)") == 0
        check repeatedBodyLeak("(fn body [] (var hs []) " &
          "(for x in [1 2 3] (hs .push (fn [] x))) hs)") == 0
        check repeatedBodyLeak(
          "(fn body [] (let hs ([1 2 3] .map (fn [x] (fn [] x)))) hs)") == 0
        check repeatedBodyLeak(
          "(fn body [] (var f nil) (for x in [2] (set f (fn [] x))) (fn [] f))") == 0
        check repeatedBodyLeak("(fn body [] (var hs [(fn [] 1)]) hs)") == 0
        check repeatedBodyLeak(
          "(fn body [] (var c ($cell nil)) (for x in [1] (c .set (fn [] x))) c)") == 0
        check repeatedBodyLeak("(fn body [] (scope (let t (spawn (do (var hs []) " &
          "(for x in [1 2] (hs .push (fn [] x))) hs))) (await t)) nil)") == 0

      test "values kept from retiring closure cycles stay callable":
        let scope = newGlobalScope()
        check print(run(compileSource("""
          (fn make [] (var hs []) (for x in [1 2 3] (hs .push (fn [] x))) hs)
          (fn pick [] (var h (make)) (var g h/2) g)
          (fn counter [] (var f nil) (var n 0)
            (for x in [1] (set f (fn [] (set n (+ n 1)) n))) f)
          (var kept (make))
          (var third (pick))
          (var count (counter))
          (count)
          (var i 0)
          (while (< i 40) (make) (pick) ((counter)) (set i (+ i 1)))
          ($runtime/test_collect)
          [(kept/0) (kept/1) (kept/2) (third) (count)]
        """), scope)) == "[1 2 3 3 2]"

      test "deep tail recursion binding loop closures stays flat":
        # Each level's scope retires at its tail transfer; the final call into
        # the closure keeps its frame so the last scope is checked on return.
        check leakedManaged("(fn walk [n] (var f nil) " &
          "(for x in [n] (set f (fn [] x))) (if (== n 0) (f) (walk (- n 1)))) " &
          "(walk 2000)") == 0

      test "released sandbox generations retire their module cycles":
        # Scalar exports, a Type/protocol/impl graph, a type-direct method, and a
        # function capturing this_mod all close Module -> Namespace -> Scope.
        # stateful.gene adds a `#Ref` table, a cell closure, and a suspended
        # generator whose Fiber holds a call scope below the root.
        for entry in ["simple.gene", "plugin.gene", "retained_item.gene",
                      "self.gene", "stateful.gene"]:
          let source = "(var tx ($runtime/sandbox_transaction)) " &
            "(var generation (tx .prepare " & sandboxOptions(entry) & ")) " &
            "(tx .commit) (generation .release)"
          discard leakedManaged(source) # prime the one grant-set builtins root
          check leakedManaged(source) == 0

      test "discarded and failed sandbox preparations retire their module cycles":
        let source = "(var tx ($runtime/sandbox_transaction)) " &
          "(var generation (tx .prepare " & sandboxOptions("plugin.gene") & ")) " &
          "(tx .discard) " &
          "(var failed ($runtime/sandbox_transaction)) " &
          "($assert (try (failed .prepare " & sandboxOptions("failing.gene") &
          ") false catch Any true)) " &
          "(failed .discard)"
        discard leakedManaged(source)
        check leakedManaged(source) == 0

      test "a retained generator keeps yielding after its generation is released":
        let source = "(var tx ($runtime/sandbox_transaction)) " &
          "(var generation (tx .prepare " & sandboxOptions("stateful.gene") &
          ")) " &
          "(var m (generation .module)) " &
          "(var stream m/stream) " &
          "(set m nil) " &
          "(tx .commit) (generation .release) " &
          "(var next_tx ($runtime/sandbox_transaction)) " &
          "(var next (next_tx .prepare " & sandboxOptions("plugin.gene") & ")) " &
          "(next_tx .commit) (next .release) " &
          "($assert (== (stream .next) 8)) " &
          "($assert (== (stream .next) 9)) " &
          "(set stream nil) " &
          "($runtime/test_collect)"
        discard leakedManaged(source)
        check leakedManaged(source) == 0

      test "a retained value keeps its released generation usable until dropped":
        # Retirement runs at the second release while `item` still reaches the
        # first generation; the instance's Type-direct method must still work.
        let source = "(var tx ($runtime/sandbox_transaction)) " &
          "(var generation (tx .prepare " & sandboxOptions("retained_item.gene") &
          ")) " &
          "(var m (generation .module)) " &
          "(var item m/item) " &
          "(set m nil) " &
          "(tx .commit) (generation .release) " &
          "(var next_tx ($runtime/sandbox_transaction)) " &
          "(var next (next_tx .prepare " & sandboxOptions("plugin.gene") & ")) " &
          "(next_tx .commit) (next .release) " &
          "($assert (== (item .direct) 7)) " &
          "(set item nil) " &
          "($runtime/test_collect)"
        discard leakedManaged(source)
        check leakedManaged(source) == 0

    test "container elements finish their destructors while an exception unwinds":
      for (label, body) in [("literal", unwindLiteralProbes),
                            ("added", unwindAddedProbes)]:
        unwindProbeTrail.setLen(0)
        try:
          body()
        except IOError:
          discard
        check unwindProbeTrail == @["enter", "finished", "enter", "finished"]

    test "a value destroyed while an exception unwinds is fully released":
      # Nim destroys a raising call's assigned result temporary with the
      # pending-exception flag still set; the release must still complete. A
      # Type's release calls out before its GC_unref, so it used to leak the
      # Type and its method.
      proc raisingAfterResult(scope: Scope): Value =
        result = run(compileSource(
          "(type T ^props {} (message m [] : Int 1)) T"), scope)
        raise newException(GeneError, "after result")
      GC_fullCollect()
      let before = liveManaged
      block:
        var scope = newGlobalScope()
        var held = NIL
        for i in 0 ..< 10:
          try:
            held = raisingAfterResult(scope)
          except GeneError:
            discard
        check held.kind == vkNil
        scope = nil
      GC_fullCollect()
      check liveManaged == before

    test "borrowed caller environments and snapshots are reclaimed":
      check leakedManaged(
        "(fn inspect! [] (eval (quote 1) ^in caller_env)) (inspect!)") == 0
      check leakedManaged(
        "(fn reject! [] (try [caller_env] catch Any nil)) (reject!)") == 0
      check leakedManaged(
        "(var x 1) " &
        "(fn snapshot! [] (caller_env .snapshot [\"x\"])) " &
        "(snapshot!)") == 0

    test "namespace and stream values are reclaimed when they do not capture functions":
      check leakedManaged("(ns m (var x 1))") == 0
      check leakedManaged("(var s ($read_all \"(a) (b)\")) (s .next)") == 0
      check leakedManaged("(var s ($to_stream [1 2 3])) (s .next)") == 0
      check leakedManaged("(var s ($map ($to_stream [1]) (fn [x] x)))") == 0
      check leakedManaged("(var s ($filter ($to_stream [1]) (fn [x] true)))") == 0
      # Regression: a transient stream whose callable captures an inner scope
      # that has already returned must keep that scope alive while pulling
      # (no use-after-free) and leave nothing behind once consumed.
      check leakedManaged("(fn mk [] (fn [x] (> x 1))) " &
                          "($into ($filter ($to_stream [1 2 3]) (mk)) [])") == 0
      check leakedManaged("(var items [1 2 3]) " &
                          "(fn mk [k] (match k (else (fn [x] true)))) " &
                          "(fn go [k] ($into ($filter ($to_stream items) (mk k)) [])) " &
                          "(go \"a\")") == 0
      check leakedManaged("($freeze [1 {^a [2]}])") == 0
      check leakedManaged("(fn ^^generator gen [] (yield 1)) " &
                          "(var s (gen)) " &
                          "(s .next) " &
                          "(s .close)") == 0
      check leakedManaged("(scope (var t (spawn (fn [] 1))) (await t))") == 0
      check leakedManaged("(scope " &
                          "  (var t : (Task Int Never) (spawn 1)) " &
                          "  (await t))") == 0
      check leakedManaged("(scope " &
                          "  (fn use [t : (Task Int Never)] " &
                          "    (try (await t) catch TypeError nil)) " &
                          "  (use (spawn \"bad\")))") == 0
      check leakedManaged("(var ch ($channel)) " &
                          "(ch .send 1) " &
                          "(ch .recv)") == 0
      check leakedManaged("(var ch : (Channel Int) ($channel))") == 0
      check leakedManaged("(var a ($actor/spawn ^init (fn [] 0) " &
                          "  ^handle (fn [ctx state msg] " &
                          "    ($actor/continue state))))") == 0
      check leakedManaged("(scope " &
                          "  ($actor/spawn ^init (fn [] 0) " &
                          "    ^handle (fn [ctx state msg] " &
                          "      ($actor/continue state))))") == 0
      check leakedManaged("(supervisor ^strategy restart " &
                          "  (var a ($actor/spawn ^init (fn [] 0) " &
                          "    ^handle (fn [ctx state msg] 99))) " &
                          "  (a .send 1))") == 0
      # A top-level `impl Send for Get` belongs in the global-retention test
      # below. Eval impls, tested above, remain reclaimable overlays.

    test "impls are globally retained, not reclaimed with their scope (design §10)":
      # A protocol impl registers on the shared application root and lives for the
      # app's lifetime, so a program that defines one retains the impl and its
      # receiver type. Eval/Env REPL impls are overlay-local and do not take this
      # path.
      check leakedManaged("(type Get ^props {^reply (ReplyTo Int)}) " &
                          "(impl Send for Get)") > 0                       # manual impl
      check leakedManaged("(protocol HasLabel " &
                          "  (message label [self] : Str) " &
                          "  (derive [t : Type, req] " &
                          "    `(impl HasLabel for %t " &
                          "       (message label [self] : Str self/name)))) " &
                          "(type User ^props {^name Str} " &
                          "  ^impl [HasLabel] " &
                          "  ^derive [HasLabel]) " &
                          "((User ^name \"Ada\") .HasLabel:label)") > 0 # generated impl
      # Control: the same type without an impl reclaims fully.
      check leakedManaged("(type User ^props {^name Str}) (User ^name \"Ada\")") == 0

    test "returned named functions keep their defining scope alive":
      var f = NIL
      block:
        var scope = newGlobalScope()
        f = run(compileSource("(var x 41) (fn f [] (+ x 1)) f"), scope)
        scope = nil
      GC_fullCollect()
      check f.call().intVal == 42
      f = NIL

    test "returned containers strengthen contained functions":
      var functions = NIL
      block:
        var scope = newGlobalScope()
        functions = run(compileSource("(var x 40) (fn f [] (+ x 2)) [f]"), scope)
        scope = nil
      GC_fullCollect()
      check functions.listItems[0].call().intVal == 42
      functions = NIL

    test "returned buffers strengthen contained functions":
      var functions = NIL
      block:
        var scope = newGlobalScope()
        functions = run(compileSource(
          "(var x 40) (fn f [] (+ x 2)) ($buffer [f])"), scope)
        scope = nil
      GC_fullCollect()
      check functions.bufferItem(0).call().intVal == 42
      functions = NIL

    test "returned Env values strengthen contained functions":
      var env = NIL
      block:
        var scope = newGlobalScope()
        env = run(compileSource(
          "(var x 41) (env ^bindings {^f (fn [] (+ x 1))})"), scope)
        scope = nil
      GC_fullCollect()
      block:
        var scope = newGlobalScope()
        scope.define("e", env)
        check run(compileSource("(eval (quote (f)) ^in e)"), scope).intVal == 42
      env = NIL

    test "returned lazy streams keep mapper scopes alive":
      var stream = NIL
      block:
        var scope = newGlobalScope()
        stream = run(compileSource("(var x 41) " &
          "($map ($to_stream [1]) (fn [n] (+ x n)))"), scope)
        scope = nil
      GC_fullCollect()
      check stream.streamNext.intVal == 42
      stream = NIL

    test "returned typed lazy streams keep wrapped mapper scopes alive":
      var stream = NIL
      block:
        var scope = newGlobalScope()
        stream = run(compileSource(
          "(fn make [] : (Stream Int Never) " &
          "  (var x 41) " &
          "  ($map ($to_stream [1]) (fn [n] (+ x n)))) " &
          "(make)"), scope)
        scope = nil
      GC_fullCollect()
      check stream.streamNext.intVal == 42
      stream = NIL

    test "returned generator streams keep their defining scope alive":
      var stream = NIL
      block:
        var scope = newGlobalScope()
        stream = run(compileSource(
          "(var x 41) " &
          "(fn ^^generator gen [] : (Stream Int Never) (yield (+ x 1))) " &
          "(gen)"), scope)
        scope = nil
      GC_fullCollect()
      check stream.streamNext.intVal == 42
      stream = NIL

    test "returned completed tasks keep result scopes alive":
      var task = NIL
      block:
        var scope = newGlobalScope()
        task = run(compileSource(
          "(var x 41) " &
          "(scope (spawn (fn [] (+ x 1))))"), scope)
        scope = nil
      GC_fullCollect()
      check task.taskResult.call().intVal == 42
      task = NIL

    test "returned channels keep buffered values alive":
      var channel = NIL
      block:
        var scope = newGlobalScope()
        channel = run(compileSource(
          "(var ch ($channel)) " &
          "(ch .send #[1 2]) " &
          "ch"), scope)
        scope = nil
      GC_fullCollect()
      let buffered = channel.popChannel()
      check buffered.listImmutable
      check buffered.listItems[0].intVal == 1
      check buffered.listItems[1].intVal == 2
      channel = NIL

    test "returned actors keep handler scopes alive":
      var actor = NIL
      block:
        var scope = newGlobalScope()
        actor = run(compileSource(
          "($actor/spawn ^init (fn [] 0) " &
          "  ^handle (fn [ctx state msg] ($actor/stop)))"), scope)
        scope = nil
      GC_fullCollect()
      block:
        var scope = newGlobalScope()
        scope.define("a", actor)
        discard run(compileSource("(a .send 1)"), scope)
      check actor.actorClosed
      actor = NIL

  # --------------------------------------------------------------------------
  # Cycles involving Cell/Env objects reached through a Value are reclaimed either
  # by conservative trial deletion (direct value edges) or weak Env-bound closure
  # captures. `liveManaged` only counts manually-RC'd objects, so these cases
  # measure occupied heap growth instead.
  proc heapGrowth(src: string, iters: int): int =
    GC_fullCollect()
    let before = getOccupiedMem()
    for _ in 0 ..< iters:
      block:
        var scope = newGlobalScope()
        discard run(compileSource(src), scope)
        scope = nil
      GC_fullCollect()
    GC_fullCollect()
    result = getOccupiedMem() - before

  suite "rc — mutable-object cycles (geneRcStats)":
    const N = 30000

    test "control: acyclic cell mutation does not grow the heap":
      check heapGrowth("(var c ($cell 0)) (c .set 5)", N) < 100_000

    test "a self-referential cell is reclaimed":
      check heapGrowth("(var c ($cell 0)) (c .set c)", N) < 100_000

    test "a two-cell cycle is reclaimed":
      check heapGrowth(
        "(var a ($cell 0)) (var b ($cell 0)) (a .set b) (b .set a)",
        N) < 100_000

    test "an Env binding closure cycle is reclaimed":
      check heapGrowth(
        "(var e nil) (set e (env ^bindings {^f (fn [] e)}))",
        N) < 100_000

    test "an Env extend binding closure cycle is reclaimed":
      check heapGrowth(
        "(var e (env)) (set e (e .extend {^f (fn [] e)}))",
        N) < 100_000
else:
  echo "test_rc: compile with -d:geneRcStats to run leak assertions; skipping."
