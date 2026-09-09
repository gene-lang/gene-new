import std/[os, strutils, tables, unittest]
import gene/[compiler, gir, gir_codec, printer, types, vm]

suite "explicit generator declarations":
  test "a marked function is lazy even without yield":
    let scope = newGlobalScope()
    let value = run(compileSource("""
      (var calls 0)
      (fn ^^generator empty []
        (set calls (+ calls 1))
        (return))
      (let stream (empty))
      [calls (stream .has_next) calls (stream .has_next)]
    """), scope)
    check value.print == "[0 false 1 false]"

  test "anonymous generators and aliases preserve their execution kind":
    let value = run(compileSource("""
      (fn ^^generator named [] (yield 1))
      (let produce named)
      (let anonymous (fn ^^generator [] (yield 2)))
      [((produce) -> $into []) ((anonymous) -> $into [])]
    """), newGlobalScope())
    check value.print == "[[1] [2]]"

  test "unmarked executable yield requires the declaration flag":
    for source in ["(fn plain [] (yield 1))",
                   "(fn ^^generator outer [] (fn inner [] (yield 1)))",
                   "(fn plain ^generator false [] (yield 1))"]:
      try:
        discard compileSource(source)
        check false
      except GeneError as error:
        check "^^generator" in error.msg

  test "generator flag values are literal booleans":
    expect GeneError:
      discard compileSource("(fn bad ^generator 1 [] 42)")
    check run(compileSource("(fn ordinary* ^generator false [] 42) (ordinary*)"),
      newGlobalScope()).intVal == 42

  test "known incompatible result contracts fail during compilation":
    for annotation in ["Int", "Void", "(List Int)", "(| Int Nil)"]:
      expect GeneError:
        discard compileSource("(fn ^^generator bad [] : " & annotation & " (return))")
    expect GeneError:
      discard compileSource("(alias Count Int) (fn ^^generator bad [] : Count (yield 1))")
    expect GeneError:
      discard compileSource("(type Count ^props {}) (fn ^^generator bad [] : Count (yield 1))")
    check run(compileSource("(fn ^^generator empty [] : (Stream Int Never) (return)) " &
      "((empty) -> $into [])"), newGlobalScope()).print == "[]"

  test "explicit close checks cleanup errors against the Stream row":
    let value = run(compileSource("""
      (type CloseError ^props {^message Str})
      (impl Error for CloseError)
      (fn ^^generator allowed [] : (Stream Int CloseError)
        (try (yield 1) ensure (fail (CloseError ^message "close"))))
      (fn ^^generator denied [] : (Stream Int Never)
        (try (yield 2) ensure (fail (CloseError ^message "denied"))))
      (let a (allowed))
      (let b (denied))
      [(a .next) (try (a .close) catch CloseError $err_msg)
       (b .next) (try (b .close) catch ErrorContractViolation $err/cause/message)
       (a .has_next) (b .has_next) (a .close) (b .close)]
    """), newGlobalScope())
    check value.print == "[1 \"close\" 2 \"denied\" false false nil nil]"

  test "ordinary Stream factories execute setup eagerly":
    let value = run(compileSource("""
      (var calls 0)
      (fn factory [] : (Stream Int Never)
        (set calls (+ calls 1))
        ($to_stream [3]))
      (fn invoke [target] (target))
      (fn ^^generator producer [] (yield 4))
      (let first (invoke factory))
      (let second (invoke producer))
      [calls (first .next) (second .next)]
    """), newGlobalScope())
    check value.print == "[1 3 4]"

  test "quoted yield remains ordinary data":
    let value = run(compileSource("(fn data [] (quote (yield 1))) (data)"),
      newGlobalScope())
    check value.kind == vkNode
    check value.head.kind == vkSymbol
    check value.head.symVal == "yield"

  test "discarded known generator calls warn without changing ordinary factories":
    let chunk = compileSource("""
      (fn ^^generator produce [] (yield 1))
      (let again produce)
      (again)
      ((fn ^^generator [] (yield 2)))
      (fn eager [] ($to_stream []))
      (eager)
      42
    """)
    check chunk.diagnostics.len == 2
    for diagnostic in chunk.diagnostics:
      check "unused generator Stream" in diagnostic.message

  test "a nested declaration's defaults cannot yield into its enclosing generator":
    expect GeneError:
      discard compileSource("(fn ^^generator outer [] (fn inner [x = (yield 1)] x))")

  test "direct generator messages are lazy and inherited with the child receiver":
    let value = run(compileSource("""
      (let seen ($cell 0))
      (type Parent ^props {^n Int}
        (message ^^generator values [] : (Stream Int Never)
          (seen .update (fn [n] (+ n 1)))
          (yield self/n)))
      (type Child : Parent ^props {})
      (let stream ((Child ^n 7) .values))
      [(seen .get) (stream .next) (seen .get) (stream .has_next)]
    """), newGlobalScope())
    check value.print == "[0 7 1 false]"

  test "an inheriting impl retains omitted generator messages":
    let value = run(compileSource("""
      (protocol Items
        (message values [] : (Stream Int Never))
        (message label [] : Str))
      (type Parent ^props {^n Int})
      (type Child : Parent ^props {})
      (impl Items for Parent
        (message ^^generator values [] : (Stream Int Never) (yield self/n))
        (message label [] : Str "parent"))
      (impl Items for Child ^^override (message label [] : Str "child"))
      (let child (Child ^n 8))
      [((child .Items:values) -> $into []) (child .Items:label)]
    """), newGlobalScope())
    check value.print == "[[8] \"child\"]"

  test "protocol defaults preserve generator behavior through protocol and type inheritance":
    let value = run(compileSource("""
      (protocol Items
        (message ^^generator values [] : (Stream Int Never) (yield 9)))
      (protocol More ^inherit [Items] (message label [] : Str "more"))
      (type Parent ^props {})
      (type Child : Parent ^props {})
      (impl More for Parent)
      [(((Child) .Items:values) -> $into []) ((Child) .More:label)]
    """), newGlobalScope())
    check value.print == "[[9] \"more\"]"

  test "overrides declare their own kind and generator super delegation stays lazy":
    let value = run(compileSource("""
      (type Parent ^props {}
        (message ^^generator values [] : (Stream Int Never) (yield 1)))
      (type Child : Parent ^props {}
        (message ^^generator values [] : (Stream Int Never) ^^override
          (for value in (super .values) (yield (+ value 1)))))
      (type Eager : Parent ^props {}
        (message values [] : (Stream Int Never) ^^override ($to_stream [3])))
      [(((Child) .values) -> $into []) (((Eager) .values) -> $into [])]
    """), newGlobalScope())
    check value.print == "[[2] [3]]"
    expect GeneError:
      discard compileSource("""
        (type Parent ^props {} (message ^^generator values [] : (Stream Int Never) (yield 1)))
        (type Child : Parent ^props {} (message values [] : (Stream Int Never) ^^override (yield 2)))
      """)

  test "compiled artifacts retain generator kind even without yield instructions":
    let chunk = compileSource("(fn ^^generator empty [] (return)) (empty)")
    let artifact = ExecutableGir(entryIdentity: "generators",
      modules: @[CompiledModule(identity: "generators", chunk: chunk,
        macroExports: initTable[string, MacroDef](),
        compileInterface: newCompileNamespaceInterface())])
    let decoded = decodeExecutableGir(encodeExecutableGir(artifact)).modules[0].chunk
    check decoded.functions[0].isGenerator
    check decoded.functions[0].taskFrameKind == tfkGenerator
    check decoded.functions[0].aotFrameKind == afkNone
    let stream = run(decoded, newGlobalScope())
    check stream.kind == vkStream
    check not stream.streamHasNext

  test "replacing a dynamic callee preserves both new kind and suspended old state":
    let value = run(compileSource("""
      (fn eager [] : (Stream Int Never) ($to_stream [1]))
      (fn ^^generator lazy [] : (Stream Int Never) (yield 2) (yield 3))
      (var chosen eager)
      (fn invoke [] (chosen))
      (let first (invoke))
      (set chosen lazy)
      (let old (invoke))
      (let checked : (Callable [] (Stream Int Never)) chosen)
      (set chosen eager)
      [(first .next) (old .next) ((invoke) .next) (old .next) ((checked) .next)]
    """), newGlobalScope())
    check value.print == "[1 2 1 3 2]"

  test "expanded yields work in the explicitly declared generator body":
    let value = run(compileSource("""
      (macro emit [value] `(yield %value))
      (fn ^^generator values [] (for n in [1 2] (emit n)))
      ((values) -> $into [])
    """), newGlobalScope())
    check value.print == "[1 2]"

  test "a dynamically supplied result annotation retains runtime checking":
    let value = run(compileSource("""
      (fn factory [Target] (fn ^^generator [] : Target (yield 1)))
      (let good (factory Stream))
      (let bad (factory Int))
      [((good) -> $into []) (try (bad) false catch TypeError true)]
    """), newGlobalScope())
    check value.print == "[[1] true]"

  test "strict checking separates creation defaults from producer cleanup":
    const declarations = """
      (mod staged ^errors_mode strict)
      (type SetupError ^props {^message Str}) (impl Error for SetupError)
      (type ReadError ^props {^message Str}) (impl Error for ReadError)
      (fn ^^generator values [n : Int = (fail (SetupError ^message "setup"))]
        : (Stream Int ReadError) ^errors [SetupError]
        (try (yield n) ensure (fail (ReadError ^message "cleanup"))))
    """
    discard compileSource(declarations & """
      (fn create [] : (Stream Int ReadError) ^errors [SetupError] (values))
      (fn close_values [s : (Stream Int ReadError)] : Nil ^errors [ReadError] (s .close))
    """)
    expect GeneError:
      discard compileSource(declarations & "(fn create [] ^errors [] (values))")
    expect GeneError:
      discard compileSource(declarations & "(fn close_values [s : (Stream Int ReadError)] ^errors [] (s .close))")

  test "ordinary factory return contracts keep their annotation environment until close":
    let value = run(compileSource("""
      (type Cleanup ^props {^message Str}) (impl Error for Cleanup)
      (fn ^^generator raw [] : (Stream Int Any)
        (try (yield 1) ensure (fail (Cleanup ^message "cleanup"))))
      (fn factory [] : (Stream Int Never) (raw))
      (let stream (factory))
      (stream .next)
      (try (stream .close) false catch ErrorContractViolation true)
    """), newGlobalScope())
    check value.boolVal

  test "module reload keeps a suspended generator's code state and cleanup alive":
    let directory = getTempDir() / "gene_generator_reload"
    createDir(directory)
    let path = directory / "source.gene"
    writeFile(path, """
      (var version 1)
      (var closed 0)
      (fn ^^generator values [] : (Stream Int Never) ^errors []
        (var saved version)
        (try (yield saved) (yield (+ saved version))
          ensure (set closed (+ closed 1))))
    """)
    let app = newApplication(directory)
    let original = app.loadFileModule(path)
    let before = original.moduleRootNamespace.nsScope
    let stream = run(compileSource("(values)"), before)
    check stream.streamNext.intVal == 1
    writeFile(path, """
      (var version 10)
      (var closed 0)
      (fn values [] : (Stream Int Never) ^errors [] ($to_stream [9]))
    """)
    let replacement = app.reloadFileModule(path).moduleRootNamespace.nsScope
    let fresh = run(compileSource("(values)"), replacement)
    check fresh.streamNext.intVal == 9
    check stream.streamNext.intVal == 2
    stream.closeStream()
    fresh.closeStream()
    check before.lookup("closed").intVal == 1
    check replacement.lookup("closed").intVal == 0
