import std/[os, strutils, tables, tempfiles, unittest]
import gene/[capabilities, compiler, fs_capabilities, gir, gir_codec, printer, types, vm]

template pipelineCheck(source, expected: string) =
  check run(compileSource(source), newGlobalScope()).print() == expected

suite "pipeline — prepared lazy invocation":
  test "every item stage is lazy, including the final stage":
    pipelineCheck """
      (let log [])
      (fn visit [x] (log .push x) (* x 2))
      (let pending ([1 2] => visit))
      (let before ($size log))
      [before (pending -> $into []) log]
    """, "[0 [2 4] [1 2]]"
    pipelineCheck """
      (fn twice [x] (* x 2))
      (let pending ([1 2] => twice => twice))
      (pending -> $into [])
    """, "[4 8]"

  test "fixed symbols capture values and nested lambdas retain live bindings":
    pipelineCheck """
      (var factor 2)
      (var operation +)
      (let fixed ([1 2] => operation factor))
      (let live ([1 2] => (fn [x] (* x factor))))
      (set factor 10)
      (set operation *)
      [(fixed -> $into []) (live -> $into [])]
    """, "[[3 4] [10 20]]"
    pipelineCheck """
      (fn build [factor] ([1 2] => * factor))
      (let first (build 2))
      (let second (build 3))
      [(first -> $into []) (second -> $into [])]
    """, "[[2 4] [3 6]]"

  test "preparation precedes conversion, even for empty and zero demand":
    pipelineCheck """
      (let log [])
      (fn note [x] (log .push x) x)
      (type Rows ^props {}
        (message to_stream [] (note "convert") ($to_stream [])))
      (fn pick [] (note "callee") +)
      (let pending ((Rows) => (pick) (note 10)))
      (pending -> $take 0 -> $into [])
      log
    """, "[\"callee\" 10 \"convert\"]"

  test "all ordinary slot positions and callables work":
    pipelineCheck """
      (fn pair [a b] [a b])
      (fn named [^value] value)
      (fn answer [] 42)
      [( [1 2] => pair 3 _ -> $into [])
       ( [1 2] => named ^value _ -> $into [])
       ( [answer answer] => _ -> $into [])
       ( [{^name "a"} {^name "b"}] => /name -> $into [])]
    """, "[[[3 1] [3 2]] [1 2] [42 42] [\"a\" \"b\"]]"
    pipelineCheck """
      (type Box ^props {^n Int})
      ([1 2] => Box ^n _ -> $into [] => /n -> $into [])
    """, "[1 2]"

  test "spread layout is frozen after all fixed expressions run":
    pipelineCheck """
      (let args [2])
      (fn gather [xs...] xs)
      (let pending ([1 4] => gather args...))
      (args .push 3)
      (pending -> $into [])
    """, "[[1 2] [4 2]]"
    pipelineCheck """
      (let args [2])
      (fn extend [] (args .push 3) 9)
      (fn gather [xs...] xs)
      (let pending ([1] => gather args... (extend)))
      (args .push 4)
      (pending -> $into [])
    """, "[[1 2 3 9]]"
    pipelineCheck """
      (fn named [^n] n)
      (let props {^n 7})
      (let pending ([1 2] => named ^n _ props...))
      (props .put "n" 9)
      (pending -> $into [])
    """, "[7 7]"
    pipelineCheck """
      (fn gather [xs...] xs)
      (let args [2 3])
      (let pending ([1 4] => gather args... _))
      (pending -> $into [])
    """, "[[2 3 1] [2 3 4]]"

  test "spread failures happen without pulling":
    pipelineCheck """
      (fn gather [xs...] xs)
      (let bad 3)
      (try ([] => gather bad...) catch Any $ex/message)
    """, "\"call splice expects a list, map, or node\""

  test "guarded sends prepare once and validate descriptors only on demand":
    pipelineCheck """
      (let log [])
      (fn setup [] (log .push "setup") 3)
      (let pending ([nil nil] => _ ?.missing (setup)))
      [($size log) (pending -> $into []) log]
    """, "[1 [nil nil] [\"setup\"]]"
    pipelineCheck """
      (let descriptor 42)
      ([nil] => _ ?.%descriptor -> $into [])
    """, "[nil]"
    pipelineCheck """
      (let log [])
      (fn setup [] (log .push 1) 3)
      [(nil -> _ ?.missing (setup)) log]
    """, "[nil []]"

  test "dynamic send values are captured while receivers dispatch per item":
    pipelineCheck """
      (type Box ^props {^n Int}
        (message add [x] (+ self/n x))
        (message sub [x] (- self/n x)))
      (var message Self:add)
      (let pending ([(Box ^n 4) (Box ^n 6)] => _ .%message 3))
      (set message Self:sub)
      (pending -> $into [])
    """, "[7 9]"
    pipelineCheck """
      (type A ^props {} (message label [] "a"))
      (type B ^props {} (message label [] "b"))
      ([(A) (B)] => _ .label -> $into [])
    """, "[\"a\" \"b\"]"

  test "whole calls preserve streams and complete before later preparation":
    pipelineCheck """
      (fn pass [value] value)
      (let source ($map ($to_stream [1 2 3]) (fn [x] x)))
      (source .peek)
      (let same (source -> pass -> $to_stream))
      [(same? source same) (source .next) (same .next)]
    """, "[true 1 2]"
    pipelineCheck """
      (fn prepare [source] (source => + 10))
      (let source ($map ($to_stream [1 2 3]) (fn [x] x)))
      (let mapped (prepare source))
      [(source .next) (mapped .next)]
    """, "[1 12]"
    pipelineCheck """
      (let log [])
      (fn parse [x] (log .push x) x)
      (fn summarize [s] ($into s []))
      (fn pick [] (log .push 9) +)
      (let pending ([1 2] => parse -> summarize => (pick) 1))
      [log (pending -> $into [])]
    """, "[[1 2 9] [2 3]]"

  test "void drops, nil stays, and nested values do not flatten":
    pipelineCheck """
      (fn drop [x] (if (== x 1) void (if (== x 2) nil [x])))
      (let seen [])
      (fn record [x] (seen .push x) x)
      [([1 2 3] => drop => record -> $into []) seen]
    """, "[[nil [3]] [nil [3]]]"
    pipelineCheck """
      (let inner ($to_stream [7]))
      (fn wrap [x] inner)
      (let outer ([1] => wrap))
      (same? (outer .next) inner)
    """, "true"
    pipelineCheck """
      (scope
        (let events [])
        (let pending ([1] => (fn [x]
          (spawn ^lane root (do (events .push x) x)))))
        (let task (pending .next))
        (let before ($size events))
        [before (await task) events])
    """, "[0 1 [1]]"

  test "custom sources use one normal conversion contract":
    pipelineCheck """
      (type Rows ^props {}
        (message to_stream [] ($to_stream [1 2])))
      (let rows (Rows))
      [($into ($to_stream rows) [])
       ($into (rows .to_stream) [])
       (rows => + 1 -> $into [])]
    """, "[[1 2] [1 2] [2 3]]"
    pipelineCheck """
      (type Bad ^props {} (message to_stream [] [1]))
      (try ((Bad) => + 1) catch TypeError "bad conversion")
    """, "\"bad conversion\""
    pipelineCheck """
      (try ({^a 1} => + 1) catch Any "pairs required")
    """, "\"pairs required\""

  test "lookahead does not repeat calls or lose the final take item":
    pipelineCheck """
      (let seen [])
      (fn visit [x] (seen .push x) x)
      (let source ([1 2 3] => visit))
      (let bounded ($take source 2))
      [(bounded .has_next) (bounded .peek) (bounded .peek)
       (bounded .next) (bounded .has_next) (bounded .has_next)
       (bounded .next) (bounded .has_next) (source .next) seen]
    """, "[true 1 1 1 true true 2 false 3 [1 2 3]]"

  test "closing zero take before pulling leaves the upstream resumable":
    pipelineCheck """
      (let seen [])
      (fn visit [x] (seen .push x) x)
      (let source ([1 2] => visit))
      (let bounded ($take source 0))
      (bounded .close)
      [($size seen) (source .next) seen]
    """, "[0 1 [1]]"

  test "closing an unstarted map closes its attached upstream":
    pipelineCheck """
      (let source ($to_stream [1 2]))
      (let pending (source => + 1))
      (pending .close)
      [(source .has_next) (pending .has_next)]
    """, "[false false]"

  test "each closes on callback errors and preserves the original error":
    pipelineCheck """
      (let log [])
      (fn rows []
        (try (yield 1) (yield 2)
         ensure (log .push "close")
                (fail (RuntimeError ^message "cleanup"))))
      (fn stop [x] (fail (RuntimeError ^message "callback")))
      (let message (try ((rows) -> $each stop)
        catch RuntimeError $ex/message))
      [message log]
    """, "[\"callback\" [\"close\"]]"

  test "callback EOF is a terminal error, not normal exhaustion":
    pipelineCheck """
      (fn stop [x] (($to_stream []) .next))
      (let pending ([1 2] => stop))
      [(try (pending .has_next) catch EndOfStream "callback EOF")
       (pending .has_next)]
    """, "[\"callback EOF\" false]"

  test "callee defaults run separately for each demanded item":
    pipelineCheck """
      (let counter ($cell 0))
      (fn fresh [] (counter .update (fn [n] (+ n 1))) (counter .get))
      (fn pair [x n = (fresh)] [x n])
      (let pending ([10 20] => pair))
      [(counter .get) (pending -> $into [])]
    """, "[0 [[10 1] [20 2]]]"

  test "user Callable invocations receive independent authored Call envelopes":
    pipelineCheck """
      (let retained [])
      (type Recorder ^props {})
      (impl Callable for Recorder
        (message apply [self call] (retained .push call) call/0))
      (let record (Recorder))
      (let values ([1 2] => record ^label "row" -> $into []))
      [values retained/0/0 retained/1/0 retained/0/named/label
       retained/0/site (same? retained/0 retained/1)]
    """, "[[1 2] 1 2 \"row\" (record ^label \"row\" _) false]"

  test "held application and explicit sends keep their lexical impl scope":
    pipelineCheck """
      (protocol Shown (message show [] : Str))
      (type Box ^props {})
      (fn build []
        (impl Shown for Box (message show [] : Str "local"))
        (let held Shown:show)
        [( [(Box)] => held) ( [(Box)] => _ .%held)])
      (let streams (build))
      [(streams/0 -> $into []) (streams/1 -> $into [])]
    """, "[[\"local\"] [\"local\"]]"

  test "callback suspension resumes the same invocation exactly once":
    pipelineCheck """
      (scope
        (let events [])
        (let channel ($channel ^capacity 1))
        (let producer (spawn ^lane root (channel .send 7)))
        (fn receive [x] (events .push x) (+ x (channel .recv)))
        (let pending ([1] => receive))
        [(pending -> $into []) events (await producer)])
    """, "[[8] [1] nil]"
    pipelineCheck """
      (scope
        (let first (spawn ^lane root 2))
        (let second (spawn ^lane root 3))
        ([first second] => (fn [task] (await task)) -> $into []))
    """, "[2 3]"

  test "typed callback failures happen when items are demanded":
    pipelineCheck """
      (fn integer [x : Int] : Int x)
      (let pending (["bad"] => integer))
      [(try (pending .next) catch TypeError "wrong item")
       (pending .has_next)]
    """, "[\"wrong item\" false]"

  test "a spawned consumer resumes suspended callbacks without losing items":
    pipelineCheck """
      (scope
        (let events [])
        (fn visit [x] (events .push x) ($sleep 1) (* x 2))
        (let pending ([1 2 3] => visit))
        (let consumer (spawn ^lane root (pending -> $into [])))
        [(await consumer) events])
    """, "[[2 4 6] [1 2 3]]"
    pipelineCheck """
      (scope
        (fn visit [x] ($sleep 1) (* x 2))
        (let pending ($map ($to_stream [1 2]) visit))
        (let consumer (spawn ^lane root ($into pending [])))
        (await consumer))
    """, "[2 4]"
    pipelineCheck """
      (scope
        (let events [])
        (fn visit [x] ($sleep 1) (events .push x))
        (let consumer (spawn ^lane root ([1 2] -> $each visit)))
        (await consumer)
        events)
    """, "[1 2]"
    pipelineCheck """
      (scope
        (fn keep [x] ($sleep 1) (> x 1))
        (let pending ($filter ($to_stream [1 2 3]) keep))
        (let consumer (spawn ^lane root ($into pending [])))
        (await consumer))
    """, "[2 3]"

  test "closing a suspended mapping callback unwinds its ensure":
    pipelineCheck """
      (scope
        (let events [])
        (fn visit [x]
          (try (events .push "start") ($sleep 10000) x
           ensure (events .push "cleanup")))
        (let pending ([1] => visit))
        (let consumer (spawn ^lane root (pending -> $into [])))
        (let closer (spawn ^lane root (do ($sleep 1) (pending .close))))
        (closer .join)
        [(match (consumer .join)
           (when TaskOutcome/cancelled true) (else false)) events])
    """, "[true [\"start\" \"cleanup\"]]"

  test "cancelling the consumer cancels its active item callback":
    pipelineCheck """
      (scope
        (let events [])
        (fn visit [x]
          (try (events .push "start") ($sleep 10000) x
           ensure (events .push "cleanup")))
        (let pending ([1] => visit))
        (let consumer (spawn ^lane root (pending -> $into [])))
        (let canceller (spawn ^lane root (do ($sleep 1) (consumer .cancel))))
        (canceller .join)
        [(match (consumer .join)
           (when TaskOutcome/cancelled true) (else false))
         (pending .has_next) events])
    """, "[true false [\"start\" \"cleanup\"]]"

  test "reentrant pulls fail and close the adapter":
    pipelineCheck """
      (var pending nil)
      (set pending ([1] => (fn [x] (pending .next))))
      [(try (pending .next) catch Any $ex/message) (pending .has_next)]
    """, "[\"a Stream cannot be pulled reentrantly\" false]"

  test "take detaches before a downstream failure on the limiting item":
    pipelineCheck """
      (let source ($to_stream [1 2 3]))
      (fn stop [x] (if (== x 2) (fail (RuntimeError ^message "stop")) x))
      (try (source -> $take 2 => stop -> $into []) catch Any nil)
      (source .next)
    """, "3"
    pipelineCheck """
      (let source ($to_stream [1 2 3]))
      (fn stop [x] (fail (RuntimeError ^message "stop")))
      (try (source -> $take 2 => stop -> $into []) catch Any nil)
      (source .has_next)
    """, "false"

  test "prepared calls round-trip through executable GIR":
    let chunk = compileSource("([1 2] => + 3 -> $into [])")
    let artifact = ExecutableGir(entryIdentity: "test/prepared-pipeline",
      modules: @[CompiledModule(identity: "test/prepared-pipeline", chunk: chunk,
        macroExports: initTable[string, MacroDef](), syntaxFnExports: @[],
        compileInterface: CompileNamespaceInterface(
          entries: initTable[string, CompileInterfaceEntry]()))])
    let decoded = decodeExecutableGir(encodeExecutableGir(artifact))
    check run(decoded.modules[0].chunk, newGlobalScope()).print() == "[4 5]"

  test "discarded lazy stages produce migration diagnostics":
    let discarded = compileSource("([1 2] => + 1) nil")
    check discarded.diagnostics.len == 1
    check "unused lazy pipeline" in discarded.diagnostics[0].message
    check compileSource("(let s ([1 2] => + 1)) (s .close)").diagnostics.len == 0
    check compileSource("(fn make [] ([1 2] => + 1))").functions[0].chunk.diagnostics.len == 0
    check compileSource("(fn main [] : Void ([1 2] => + 1))").compilerDiagnostics.len == 1

  test "ordinary source call restrictions survive preparation":
    expect GeneError:
      discard compileSource("([1] => + ^types 1)")
    expect GeneError:
      discard compileSource("([1] => Self:to_str)")

  test "callback errors retain the authored source location":
    try:
      discard run(compileSource("""
        (fn broken [x]
          (fail (RuntimeError ^message "broken")))
        ([1] => broken -> $into [])
      """, "pipeline-location.gene"), newGlobalScope())
      check false
    except GeneError as error:
      check error.loc.sourceName == "pipeline-location.gene"
      check error.loc.line == 2

  test "skip loops retain the consuming caller's execution budget":
    pipelineCheck """
      (fn naturals [] (var n 0) (while true (yield n) (set n (+ n 1))))
      (let pending ((naturals) => (fn [x] void)))
      (let consume ($runtime/bind_call (fn [] (pending .next)) []
                    ^policy {^max_steps 100}))
      [(try (consume) false catch Any true) (pending .has_next)]
    """, "[true false]"

when defined(posix):
  suite "pipeline — retained authority":
    test "both creating and consuming capability ceilings apply":
      let root = createTempDir("gene-pipeline-caps-", "")
      defer: removeDir(root)
      writeFile(root / "data", "pipeline")
      let app = newApplication(root)
      app.setRootCapabilities(newCapabilityContext(
        @[app.filesystemCapabilities.grantReadDir(root)]))
      let scope = newGlobalScope(app)
      scope.define("file", newStr(root / "data"))
      check run(compileSource("""
        (fn read ^capabilities * [x] ($fs/read_text file))
        (let full ([1] => read))
        (let narrow (with_capabilities [] ([1] => read)))
        (let later ([1] => read))
        (fn rows ^capabilities * [] (yield ($fs/read_text file)))
        (let producer (rows))
        (let high_source (rows))
        (let narrow_source (with_capabilities [] (high_source => (fn [x] x))))
        [(full .next)
         (try (narrow .next) false catch MissingCapability true)
         (try (with_capabilities [] (later .next)) false
          catch MissingCapability true)
         (try (with_capabilities [] (producer .next)) false
          catch MissingCapability true)
         (try (narrow_source .next) false catch MissingCapability true)]
      """), scope).print() == "[\"pipeline\" true true true true]"
