import std/[json, os, strutils, tables, unittest]
import gene/[compiler, logging, logging_config, printer, reader, types, vm]

var loggingCaptured {.threadvar.}: seq[string]
var reentrantLogger {.threadvar.}: RuntimeLogger

proc captureLoggingLine(line: string) {.gcsafe.} =
  loggingCaptured.add line

proc failLoggingLine(line: string) {.gcsafe.} =
  discard line
  raise newException(IOError, "intentional sink failure")

proc reenterLoggingLine(line: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    loggingCaptured.add line
    if reentrantLogger != nil:
      reentrantLogger.emit(llWarn, "recursive")

proc installCaptureLogging(level: LogLevel, format = lfJsonl) =
  loggingCaptured.setLen(0)
  var config = defaultLoggingConfig()
  for _, sink in config.sinks: closeLogSink(sink)
  config.sinks = initTable[string, LogSink]()
  config.sinks["capture"] = newCallbackLogSink("capture", captureLoggingLine,
                                                format)
  config.rootTargets = @["capture"]
  config.rootLevel = level
  installLoggingConfig(config)

proc runLoggingSource(source: string): Value =
  let app = newApplication()
  run(compileSource(source), newGlobalScope(app))

proc loggingGeneQuote(text: string): string =
  result = "\""
  for ch in text:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    else: result.add ch
  result.add '"'

suite "structured logging":
  teardown:
    resetLogging()

  test "limits degrade to defaults instead of failing closed":
    # A zero/unset limit must never mean "reject everything": a maxDepth of 0
    # would fail even a depth-1 payload. This is what broke the wasm host sink,
    # whose registry came from a config whose limits were never populated.
    var maxDepth, maxItems, maxStringBytes: int
    loggingLimitValues(maxDepth, maxItems, maxStringBytes)
    check maxDepth > 0
    check maxItems > 0
    check maxStringBytes > 0

    var config = defaultLoggingConfig()
    config.limits = LogLimits()          # all zero, as if never configured
    installLoggingConfig(config)
    loggingLimitValues(maxDepth, maxItems, maxStringBytes)
    check maxDepth == DefaultLogLimits.maxDepth
    check maxItems == DefaultLogLimits.maxItems
    check maxStringBytes == DefaultLogLimits.maxStringBytes

    # A depth-1 payload still logs under those degraded limits.
    loggingCaptured.setLen(0)
    var sinkConfig = defaultLoggingConfig()
    for _, sink in sinkConfig.sinks: closeLogSink(sink)
    sinkConfig.sinks = initTable[string, LogSink]()
    sinkConfig.sinks["cap"] = newCallbackLogSink("cap", captureLoggingLine,
                                                 lfJsonl)
    sinkConfig.rootTargets = @["cap"]
    sinkConfig.rootLevel = llWarn
    sinkConfig.limits = LogLimits()      # zero again, now with a live sink
    installLoggingConfig(sinkConfig)
    let logger = newRuntimeLogger("app/limits")
    logger.emit(llWarn, "payload", %*{"k": 1})
    check loggingCaptured.len == 1
    check "\"k\":1" in loggingCaptured[0]

  test "hierarchical route filtering and JSON fan-out are structured":
    loggingCaptured.setLen(0)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["a"] = newCallbackLogSink("a", captureLoggingLine, lfJsonl)
    config.sinks["b"] = newCallbackLogSink("b", captureLoggingLine, lfJsonl)
    config.rootTargets = @["a"]
    config.rootLevel = llWarn
    config.overrides = @[
      LogRouteOverride(name: "app", hasLevel: true, level: llInfo),
      LogRouteOverride(name: "app/http", hasTargets: true,
                       targets: @["a", "b"])
    ]
    installLoggingConfig(config)
    let logger = newRuntimeLogger("app/http/server")
    check logger.enabled(llInfo)
    check not logger.enabled(llDebug)
    logger.emit(llInfo, "ready", %*{"token": "secret", "port": 8080})
    check loggingCaptured.len == 2
    let event = parseJson(loggingCaptured[0])
    check event["logger"].getStr == "app/http/server"
    check event["level"].getStr == "info"
    check event["payload"]["token"].getStr == "[redacted]"
    check event["payload"]["port"].getInt == 8080
    check loggingCaptured[0] == loggingCaptured[1]

  test "route resolution prefers specificity over declaration order":
    var config = defaultLoggingConfig()
    config.overrides = @[
      LogRouteOverride(name: "app/http", hasLevel: true, level: llDebug),
      LogRouteOverride(name: "app", hasLevel: true, level: llInfo)
    ]
    installLoggingConfig(config)
    let logger = newRuntimeLogger("app/http/server")
    check logger.enabled(llDebug)
    check not logger.enabled(llTrace)

  test "Gene eager methods and lazy macros have distinct evaluation":
    installCaptureLogging(llWarn)
    let result = runLoggingSource("""
(import log [LogLevel new_logger info! debug!])
(var logger (new_logger "app/test" ^payload {^service "spec"}))
(var eager (cell false))
(var lazy (cell false))
(logger ~ info (do (Cell/set eager true) "eager"))
(debug! logger (do (Cell/set lazy true) "lazy"))
(logger ~ warn "warning" ^payload {^token "hidden"})
[(Cell/get eager) (Cell/get lazy) (logger ~ enabled? LogLevel/warn)]
""")
    check result.print == "[true false true]"
    check loggingCaptured.len == 1
    let event = parseJson(loggingCaptured[0])
    check event["message"].getStr == "warning"
    check event["payload"]["service"].getStr == "spec"
    check event["payload"]["token"].getStr == "[redacted]"

  test "off suppresses every level and preserves lazy arguments":
    installCaptureLogging(llOff)
    let logger = newRuntimeLogger("app/off")
    check not logger.enabled(llError)
    logger.emit(llError, "suppressed")
    let result = runLoggingSource("""
(import log [new_logger error!])
(var logger (new_logger "app/off"))
(var touched (cell false))
(error! logger (do (Cell/set touched true) "suppressed"))
(Cell/get touched)
""")
    check result == FALSE
    check loggingCaptured.len == 0

  test "off logger override silences only its subtree":
    loggingCaptured.setLen(0)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["capture"] = newCallbackLogSink(
      "capture", captureLoggingLine, lfJsonl)
    config.rootTargets = @["capture"]
    config.rootLevel = llInfo
    config.overrides = @[
      LogRouteOverride(name: "app/quiet", hasLevel: true, level: llOff)]
    installLoggingConfig(config)
    newRuntimeLogger("app/quiet/child").emit(llError, "hidden")
    newRuntimeLogger("app/loud").emit(llInfo, "visible")
    check loggingCaptured.len == 1
    check parseJson(loggingCaptured[0])["message"].getStr == "visible"

  test "Gene logging records the source call location":
    installCaptureLogging(llInfo)
    let app = newApplication()
    discard run(compileSource(
      "(import log [new_logger info!])\n" &
      "(var logger (new_logger \"app/source\"))\n" &
      "(info! logger \"located\")\n",
      "logging_source.gene"), newGlobalScope(app))
    check loggingCaptured.len == 1
    let event = parseJson(loggingCaptured[0])
    check event["source"]["module"].getStr == "logging_source.gene"
    check event["source"]["line"].getInt == 3

  test "Logger is immutable and Send-safe":
    installCaptureLogging(llOff)
    let result = runLoggingSource("""
(import log [new_logger])
(var logger (new_logger "app/send" ^payload {^x [1 2]}))
(same? logger (await (spawn logger)))
""")
    check result == TRUE

  test "data-only config resolves relative file paths and validates targets":
    let dir = getTempDir() / "gene_logging_config_test"
    createDir(dir)
    let value = read("""
{^level "info"
 ^sinks {^file {^type "file" ^path "events.jsonl" ^format "jsonl"}}
 ^targets ["file"]
 ^loggers {{"app/http" : {^level "debug"}}}}
""")
    let config = parseLoggingConfigValue(value, dir)
    defer:
      for _, sink in config.sinks: closeLogSink(sink)
      if fileExists(dir / "events.jsonl"): removeFile(dir / "events.jsonl")
      if dirExists(dir): removeDir(dir)
    check config.rootLevel == llInfo
    check config.rootTargets == @["file"]
    check config.overrides.len == 1
    check config.overrides[0].name == "app/http"
    check config.sinks["file"].path == absolutePath(dir / "events.jsonl")

  test "invalid config is rejected as a whole":
    expect ValueError:
      discard parseLoggingConfigValue(
        read("{^sinks {^ok {^type \"console\"}} ^targets [\"missing\"]}"),
        getCurrentDir())

  test "sink failure is contained and recursive callback logging is dropped":
    loggingCaptured.setLen(0)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["bad"] = newCallbackLogSink("bad", failLoggingLine)
    config.sinks["good"] = newCallbackLogSink("good", reenterLoggingLine)
    config.rootTargets = @["bad", "good"]
    config.rootLevel = llWarn
    installLoggingConfig(config)
    reentrantLogger = newRuntimeLogger("gene/reentrant")
    var raised = false
    try:
      reentrantLogger.emit(llWarn, "outer")
      reentrantLogger.emit(llWarn, "second")
    except IOError:
      raised = true
    check not raised
    check loggingCaptured.len == 2
    check "outer" in loggingCaptured[0]
    check "second" in loggingCaptured[1]
    reentrantLogger = nil

  test "bounded JSON logging remains one valid record":
    loggingCaptured.setLen(0)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["capture"] = newCallbackLogSink("capture",
      captureLoggingLine, lfJsonl)
    config.rootTargets = @["capture"]
    config.rootLevel = llInfo
    config.limits.maxStringBytes = 32
    config.limits.maxEventBytes = 256
    installLoggingConfig(config)
    let logger = newRuntimeLogger("app/bounded")
    logger.emit(llInfo, repeat("message", 100),
                %*{"value": repeat("payload", 100)})
    check loggingCaptured.len == 1
    let event = parseJson(loggingCaptured[0])
    check event["schema"].getStr == "gene.log.v1"
    check event["logger"].getStr == "app/bounded"

  test "string truncation preserves valid UTF-8 in messages and payloads":
    loggingCaptured.setLen(0)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["capture"] = newCallbackLogSink(
      "capture", captureLoggingLine, lfJsonl)
    config.rootTargets = @["capture"]
    config.rootLevel = llInfo
    config.limits.maxStringBytes = 3
    config.limits.maxEventBytes = 512
    installLoggingConfig(config)
    newRuntimeLogger("app/utf8").emit(
      llInfo, "éé", %*{"value": "🙂x"})
    check loggingCaptured.len == 1
    let event = parseJson(loggingCaptured[0])
    check event["message"].getStr == "é[truncated]"
    check event["payload"]["value"].getStr == "[truncated]"

  test "console color policy is safe for captured and TUI output":
    loggingCaptured.setLen(0)
    setLogHostWriter(captureLoggingLine)
    defer: setLogHostWriter(nil)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["console"] = newConsoleLogSink(
      "console", format = lfText, color = lcAuto)
    config.rootTargets = @["console"]
    config.rootLevel = llWarn
    installLoggingConfig(config)
    newRuntimeLogger("app/tui").emit(llWarn, "plain")
    check loggingCaptured.len == 1
    check "\e[" notin loggingCaptured[0]

    loggingCaptured.setLen(0)
    config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["console"] = newConsoleLogSink(
      "console", format = lfText, color = lcAlways)
    config.rootTargets = @["console"]
    config.rootLevel = llWarn
    installLoggingConfig(config)
    newRuntimeLogger("app/tui").emit(llWarn, "colored")
    check loggingCaptured.len == 1
    check "\e[33m" in loggingCaptured[0]

  test "programmatic file logger requires explicit write authority":
    let dir = getTempDir() / "gene_direct_file_logger"
    createDir(dir)
    let path = dir / "direct.jsonl"
    if fileExists(path): removeFile(path)
    resetLogging()
    discard runLoggingSource(
      "(import log [new_file_logger]) " &
      "(import Fs [WriteDir]) " &
      "(var logger (new_file_logger WriteDir \"app/direct\" " &
        loggingGeneQuote(path) & " ^flush \"close\")) " &
      "(logger ~ info \"direct\" ^payload {^x 1})")
    shutdownLogging()
    check fileExists(path)
    let event = parseJson(readFile(path).strip())
    check event["logger"].getStr == "app/direct"
    check event["payload"]["x"].getInt == 1
    removeFile(path)
    removeDir(dir)

  test "programmatic file logger rejects read-only authority":
    let result = runLoggingSource(
      "(import log [new_file_logger]) " &
      "(import Fs [ReadDir]) " &
      "(try (new_file_logger ReadDir \"app/direct\" \"ignored.jsonl\") " &
      "  false catch _ true)")
    check result == TRUE

  test "reserved envelope keys cannot be smuggled through payload":
    let result = runLoggingSource(
      "(import log [new_logger]) " &
      "(try (new_logger \"app/reserved\" ^payload {^level \"fake\"}) " &
      "  false catch _ true)")
    check result == TRUE
