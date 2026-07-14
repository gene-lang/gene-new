## Structured diagnostic logging shared by the runtime and Gene's `log`
## namespace (docs/proposals/logging.md).
##
## The disabled RuntimeLogger path is intentionally just a cached threshold
## comparison. Configuration is installed before entry-module execution; route
## creation is synchronized. RuntimeLogger caches an immutable route so its
## disabled path remains lock-free; route-id lookups used by Gene handles take
## the route lock because the route table may grow at runtime.

import std/[json, locks, os, sets, strutils, tables, terminal, times]
when compileOption("threads"):
  import std/atomics

type
  LogLevel* = enum
    llError
    llWarn
    llInfo
    llDebug
    llTrace
    llOff

  LogFormat* = enum
    lfGene
    lfText
    lfJsonl

  LogFlush* = enum
    lflAlways
    lflError
    lflClose

  LogColor* = enum
    lcAuto
    lcAlways
    lcNever

  LogSinkKind* = enum
    lskConsole
    lskFile
    lskCallback

  LogWriteCallback* = proc(line: string) {.gcsafe.}

  LogSink* = ref object
    name*: string
    format*: LogFormat
    flush*: LogFlush
    lock: Lock
    unhealthy: bool
    failureReported: bool
    case kind*: LogSinkKind
    of lskConsole:
      stderrStream*: bool
      color*: LogColor
    of lskFile:
      path*: string
      file*: File
    of lskCallback:
      callback*: LogWriteCallback

  LogRoute* = ref object
    level*: LogLevel
    sinks*: seq[LogSink]

  LogRouteOverride* = object
    name*: string
    hasLevel*: bool
    level*: LogLevel
    hasTargets*: bool
    targets*: seq[string]

  LogLimits* = object
    maxDepth*: int
    maxItems*: int
    maxStringBytes*: int
    maxEventBytes*: int

  LoggingConfig* = object
    rootLevel*: LogLevel
    rootTargets*: seq[string]
    sinks*: Table[string, LogSink]
    overrides*: seq[LogRouteOverride]
    redactKeys*: HashSet[string]
    limits*: LogLimits

  LoggingRegistry = ref object
    config: LoggingConfig
    routeLock: Lock
    routeIds: Table[string, int]
    routes: seq[LogRoute]
    ownedSinks: seq[LogSink]

  RuntimeLogger* = ref object
    name*: string
    route: LogRoute

  LogSource* = object
    module*: string
    line*: int
    column*: int

  LogEvent = object
    timestamp: DateTime
    level: LogLevel
    logger: string
    message: string
    payload: JsonNode
    sequence: uint64
    processId: int
    threadId: int
    source: LogSource

const
  DefaultLogLimits* = LogLimits(maxDepth: 8, maxItems: 256,
    maxStringBytes: 8192, maxEventBytes: 65536)
  DefaultRedactKeys = [
    "authorization", "cookie", "set-cookie", "api_key", "token"]

var registryLock: Lock
initLock(registryLock)
var activeRegistry: LoggingRegistry
var registeredRuntimeLoggers: seq[RuntimeLogger]
var hostWriter: LogWriteCallback
var inLogWrite {.threadvar.}: bool
when compileOption("threads"):
  var nextSequence: Atomic[uint64]
  var consoleSinkSuppressed: Atomic[bool]
else:
  var nextSequence: uint64
  var consoleSinkSuppressed: bool

proc setConsoleLogSuppressed*(suppressed: bool) =
  ## A full-screen terminal owner cannot safely share stdout/stderr with a
  ## console sink: an out-of-band newline invalidates ncurses' physical-screen
  ## model and corrupts the user's input row. File/callback sinks remain live.
  when compileOption("threads"):
    consoleSinkSuppressed.store(suppressed, moRelease)
  else:
    consoleSinkSuppressed = suppressed

proc consoleLogSuppressed(): bool {.inline.} =
  when compileOption("threads"):
    consoleSinkSuppressed.load(moAcquire)
  else:
    consoleSinkSuppressed

proc pinRegistry(registry: LoggingRegistry) {.inline.} =
  ## Emscripten's ORC lowering does not keep this module-global ref alive
  ## reliably across exported calls. The registry is process-wide state, so
  ## explicitly root it for exactly as long as it is installed.
  when defined(geneWasm) or defined(emscripten):
    if registry != nil: GC_ref(registry)

proc unpinRegistry(registry: LoggingRegistry) {.inline.} =
  when defined(geneWasm) or defined(emscripten):
    if registry != nil: GC_unref(registry)

proc levelName*(level: LogLevel): string =
  case level
  of llError: "error"
  of llWarn: "warn"
  of llInfo: "info"
  of llDebug: "debug"
  of llTrace: "trace"
  of llOff: "off"

proc parseLogLevel*(text: string, level: var LogLevel): bool =
  case text.toLowerAscii()
  of "error": level = llError
  of "warn", "warning": level = llWarn
  of "info": level = llInfo
  of "debug": level = llDebug
  of "trace": level = llTrace
  of "off": level = llOff
  else: return false
  true

proc parseLogFormat*(text: string, format: var LogFormat): bool =
  case text.toLowerAscii()
  of "gene": format = lfGene
  of "text": format = lfText
  of "json", "jsonl": format = lfJsonl
  else: return false
  true

proc parseLogFlush*(text: string, flush: var LogFlush): bool =
  case text.toLowerAscii()
  of "always": flush = lflAlways
  of "error": flush = lflError
  of "close": flush = lflClose
  else: return false
  true

proc validLoggerName*(name: string): bool =
  if name.len == 0 or name.len > 256 or name[0] == '/' or name[^1] == '/':
    return false
  var segmentLen = 0
  for ch in name:
    if ch == '/':
      if segmentLen == 0: return false
      segmentLen = 0
    elif ch < ' ' or ch == '\x7f':
      return false
    else:
      inc segmentLen
  if segmentLen == 0: return false
  for part in name.split('/'):
    if part in [".", ".."]: return false
  true

proc routeMatches(prefix, name: string): bool {.inline.} =
  name == prefix or
    (name.len > prefix.len and name.startsWith(prefix) and
     name[prefix.len] == '/')

proc defaultLoggingConfig*(): LoggingConfig

proc setLogHostWriter*(writer: LogWriteCallback) =
  hostWriter = writer

proc emergencyWrite(message: string) =
  let line = "gene logging: " & message
  if hostWriter != nil:
    try: hostWriter(line & "\n")
    except CatchableError: discard
  else:
    when not defined(geneWasm):
      try:
        stderr.writeLine(line)
        stderr.flushFile()
      except CatchableError:
        discard

proc newConsoleLogSink*(name: string, stderrStream = true,
                        format = lfGene, color = lcAuto): LogSink =
  result = LogSink(name: name, format: format, flush: lflAlways,
    kind: lskConsole, stderrStream: stderrStream, color: color)
  initLock(result.lock)

proc newCallbackLogSink*(name: string, callback: LogWriteCallback,
                         format = lfGene): LogSink =
  result = LogSink(name: name, format: format, flush: lflAlways,
    kind: lskCallback, callback: callback)
  initLock(result.lock)

proc newFileLogSink*(name, path: string, format = lfGene,
                     flush = lflError): LogSink =
  when defined(geneWasm) or defined(emscripten):
    raise newException(IOError, "file log sinks are unavailable in wasm")
  else:
    let absolute = absolutePath(path)
    let parent = parentDir(absolute)
    if parent.len > 0:
      createDir(parent)
    var handle: File
    if not open(handle, absolute, fmAppend):
      raise newException(IOError, "cannot open log file: " & absolute)
    result = LogSink(name: name, format: format, flush: flush,
      kind: lskFile, path: absolute, file: handle)
    initLock(result.lock)

proc closeLogSink*(sink: LogSink) =
  if sink == nil: return
  when compileOption("threads"):
    acquire(sink.lock)
    defer: release(sink.lock)
  if sink.kind == lskFile and sink.file != nil:
    try:
      sink.file.flushFile()
      sink.file.close()
    except CatchableError:
      discard
    sink.file = nil

proc defaultLoggingConfig*(): LoggingConfig =
  result.rootLevel = llWarn
  result.rootTargets = @["stderr"]
  result.sinks = initTable[string, LogSink]()
  result.sinks["stderr"] = newConsoleLogSink("stderr")
  result.overrides = @[]
  result.redactKeys = initHashSet[string]()
  for key in DefaultRedactKeys:
    result.redactKeys.incl key
  result.limits.maxDepth = 8
  result.limits.maxItems = 256
  result.limits.maxStringBytes = 8192
  result.limits.maxEventBytes = 65536

proc routeFor(registry: LoggingRegistry, name: string): LogRoute =
  var level = registry.config.rootLevel
  var levelDepth = -1
  var targetsDepth = -1
  var targetsOverride = -1
  var i = 0
  while i < registry.config.overrides.len:
    let override = addr registry.config.overrides[i]
    if routeMatches(override[].name, name):
      let depth = override[].name.count('/')
      if override[].hasLevel and depth >= levelDepth:
        level = override[].level
        levelDepth = depth
      if override[].hasTargets and depth >= targetsDepth:
        targetsOverride = i
        targetsDepth = depth
    inc i
  result = LogRoute(level: level)
  if targetsOverride >= 0:
    for target in registry.config.overrides[targetsOverride].targets:
      if registry.config.sinks.hasKey(target):
        result.sinks.add registry.config.sinks[target]
  else:
    for target in registry.config.rootTargets:
      if registry.config.sinks.hasKey(target):
        result.sinks.add registry.config.sinks[target]

proc newRegistry(config: LoggingConfig): LoggingRegistry =
  result = LoggingRegistry(config: config,
    routeIds: initTable[string, int](), routes: @[], ownedSinks: @[])
  initLock(result.routeLock)

proc ensureRegistry(): LoggingRegistry =
  when compileOption("threads"):
    acquire(registryLock)
    defer: release(registryLock)
  if activeRegistry == nil:
    let config = defaultLoggingConfig()
    activeRegistry = newRegistry(config)
    pinRegistry(activeRegistry)
  activeRegistry

proc resolveRoute(name: string): tuple[id: int, route: LogRoute] =
  if not validLoggerName(name):
    raise newException(ValueError, "invalid logger name: " & name)
  let registry = ensureRegistry()
  when compileOption("threads"):
    acquire(registry.routeLock)
    defer: release(registry.routeLock)
  if registry.routeIds.hasKey(name):
    result.id = registry.routeIds[name]
    result.route = registry.routes[result.id]
    return
  result.id = registry.routes.len
  result.route = routeFor(registry, name)
  registry.routes.add result.route
  registry.routeIds[name] = result.id

proc resolveRouteId*(name: string): int =
  resolveRoute(name).id

proc newDirectLogRoute*(sink: LogSink, level = llTrace): int =
  ## Capability-gated Gene constructors use a direct one-sink route without
  ## mutating hierarchical configuration or affecting other loggers.
  if sink == nil:
    raise newException(ValueError, "direct log route requires a sink")
  let registry = ensureRegistry()
  when compileOption("threads"):
    acquire(registry.routeLock)
    defer: release(registry.routeLock)
  result = registry.routes.len
  registry.routes.add LogRoute(level: level, sinks: @[sink])
  registry.ownedSinks.add sink

proc routeById(routeId: int): LogRoute =
  let registry = activeRegistry
  if registry == nil or routeId < 0:
    return
  when compileOption("threads"):
    acquire(registry.routeLock)
    try:
      if routeId < registry.routes.len:
        result = registry.routes[routeId]
    finally:
      release(registry.routeLock)
  else:
    if routeId < registry.routes.len:
      result = registry.routes[routeId]

proc newRuntimeLogger*(name: string): RuntimeLogger =
  if not validLoggerName(name):
    raise newException(ValueError, "invalid runtime logger name: " & name)
  result = RuntimeLogger(name: name, route: resolveRoute(name).route)
  when compileOption("threads"):
    acquire(registryLock)
    defer: release(registryLock)
  registeredRuntimeLoggers.add result

proc bindRuntimeLogger(logger: RuntimeLogger) =
  if logger != nil:
    logger.route = resolveRoute(logger.name).route

proc installLoggingConfig*(config: LoggingConfig) =
  let next = newRegistry(config)
  pinRegistry(next)
  var previous: LoggingRegistry
  when compileOption("threads"):
    acquire(registryLock)
    try:
      previous = activeRegistry
      activeRegistry = next
    finally:
      release(registryLock)
  else:
    previous = activeRegistry
    activeRegistry = next
  try:
    for logger in registeredRuntimeLoggers:
      bindRuntimeLogger(logger)
    if previous != nil:
      for _, sink in previous.config.sinks:
        var reused = false
        for _, current in config.sinks:
          if current == sink: reused = true
        if not reused: closeLogSink(sink)
      for sink in previous.ownedSinks:
        closeLogSink(sink)
  finally:
    unpinRegistry(previous)

proc resetLogging*() =
  installLoggingConfig(defaultLoggingConfig())

proc shutdownLogging*() =
  let registry = activeRegistry
  if registry == nil: return
  for _, sink in registry.config.sinks:
    closeLogSink(sink)
  for sink in registry.ownedSinks:
    closeLogSink(sink)

proc routeEnabled(route: LogRoute, level: LogLevel): bool {.inline.} =
  route != nil and route.level != llOff and level != llOff and
    level <= route.level and route.sinks.len > 0

proc loggerEnabled*(routeId: int, level: LogLevel): bool =
  routeEnabled(routeById(routeId), level)

proc loggingRedactsKey*(key: string): bool =
  let normalized = key.toLowerAscii()
  let registry = activeRegistry
  if registry == nil:
    normalized in DefaultRedactKeys
  else:
    normalized in registry.config.redactKeys

proc effectiveLimit(value, fallback: int): int {.inline.} =
  ## A zero/negative limit means "unset", never "reject everything": a maxDepth
  ## of 0 would fail a depth-1 payload, so limits degrade to the documented
  ## defaults rather than fail closed.
  if value > 0: value else: fallback

proc effectiveLimits*(limits: LogLimits): LogLimits =
  LogLimits(
    maxDepth: effectiveLimit(limits.maxDepth, DefaultLogLimits.maxDepth),
    maxItems: effectiveLimit(limits.maxItems, DefaultLogLimits.maxItems),
    maxStringBytes: effectiveLimit(limits.maxStringBytes,
                                   DefaultLogLimits.maxStringBytes),
    maxEventBytes: effectiveLimit(limits.maxEventBytes,
                                  DefaultLogLimits.maxEventBytes))

proc loggingLimitValues*(maxDepth, maxItems, maxStringBytes: var int) =
  let limits = ensureRegistry().config.limits.effectiveLimits
  maxDepth = limits.maxDepth
  maxItems = limits.maxItems
  maxStringBytes = limits.maxStringBytes

proc enabled*(logger: RuntimeLogger, level: LogLevel): bool {.inline.} =
  if logger == nil: return false
  if logger.route == nil:
    bindRuntimeLogger(logger)
  routeEnabled(logger.route, level)

proc nextLogSequence(): uint64 {.inline.} =
  when compileOption("threads"):
    nextSequence.fetchAdd(1'u64, moRelaxed) + 1'u64
  else:
    inc nextSequence
    nextSequence

proc utf8Prefix(text: string, maxBytes: int): string =
  ## Return at most maxBytes without cutting through a UTF-8 continuation.
  if maxBytes <= 0: return ""
  if text.len <= maxBytes: return text
  var cut = maxBytes
  while cut > 0 and (ord(text[cut]) and 0xc0) == 0x80:
    dec cut
  text[0 ..< cut]

proc copyAndRedact(node: JsonNode, redactKeys: HashSet[string], depth: int,
                   itemCount: var int, maxDepth, maxItems, maxStringBytes: int,
                   truncated: var bool): JsonNode =
  if node == nil: return newJNull()
  if depth > maxDepth or itemCount >= maxItems:
    truncated = true
    return newJString("[truncated]")
  inc itemCount
  case node.kind
  of JObject:
    result = newJObject()
    for key, value in node:
      if key.toLowerAscii() in redactKeys:
        result[key] = newJString("[redacted]")
      else:
        result[key] = copyAndRedact(value, redactKeys, depth + 1,
          itemCount, maxDepth, maxItems, maxStringBytes, truncated)
  of JArray:
    result = newJArray()
    for value in node:
      result.add copyAndRedact(value, redactKeys, depth + 1,
        itemCount, maxDepth, maxItems, maxStringBytes, truncated)
  of JString:
    let value = node.getStr()
    if value.len > maxStringBytes:
      truncated = true
      result = newJString(utf8Prefix(value, maxStringBytes) &
                          "[truncated]")
    else:
      result = newJString(value)
  of JInt: result = newJInt(node.getBiggestInt())
  of JFloat: result = newJFloat(node.getFloat())
  of JBool: result = newJBool(node.getBool())
  of JNull: result = newJNull()

proc timestampText(timestamp: DateTime): string =
  timestamp.utc.format("yyyy-MM-dd'T'HH:mm:ss'.'ffffff'Z'")

proc geneString(text: string): string =
  ## Gene strings intentionally share JSON's common escapes, but not \b/\f.
  ## Escape every other ASCII control byte as a fixed Unicode escape so the
  ## rendered record always reads back through Gene's real reader.
  result = "\""
  for ch in text:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\0': result.add "\\0"
    else:
      let code = ord(ch)
      if code < 0x20 or code == 0x7f:
        result.add "\\u" & toHex(code, 4)
      else:
        result.add ch
  result.add '"'

proc plainPropKey(key: string): bool =
  ## True when `^key` re-reads through the reader as a prop whose key is
  ## exactly this text: a symbol of letters/digits/`_`/`-` that starts with a
  ## letter or `_`, so it can never lex as a number or a delimiter. Any other
  ## key keeps the object in a general map so the record still round-trips.
  if key.len == 0 or key[0] notin {'a'..'z', 'A'..'Z', '_'}:
    return false
  for ch in key:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      return false
  true

proc renderGeneValue(node: JsonNode): string =
  if node == nil: return "nil"
  case node.kind
  of JObject:
    # Default to a regular prop map `{^key value}`; only arbitrary keys that
    # cannot be bare symbols fall back to a general map `{{"key" : value}}`.
    var plainKeys = true
    for key, _ in node:
      if not plainPropKey(key):
        plainKeys = false
        break
    if plainKeys:
      result = "{"
      var first = true
      for key, value in node:
        if not first: result.add ' '
        first = false
        result.add '^'
        result.add key
        result.add ' '
        result.add renderGeneValue(value)
      result.add '}'
    else:
      result = "{{"
      var first = true
      for key, value in node:
        if not first: result.add ' '
        first = false
        result.add geneString(key)
        result.add " : "
        result.add renderGeneValue(value)
      result.add "}}"
  of JArray:
    result = "["
    var first = true
    for value in node:
      if not first: result.add ' '
      first = false
      result.add renderGeneValue(value)
    result.add ']'
  of JString:
    result = geneString(node.getStr())
  of JInt:
    result = $node.getBiggestInt()
  of JFloat:
    result = $node.getFloat()
    if '.' notin result and 'e' notin result and
        'n' notin result and 'i' notin result:
      result.add ".0"
  of JBool:
    result = if node.getBool(): "true" else: "false"
  of JNull:
    result = "nil"

proc renderGene(event: LogEvent): string =
  result = "{^schema \"gene.log.v1\" ^time " &
    geneString(timestampText(event.timestamp)) &
    " ^level " & geneString(levelName(event.level)) &
    " ^logger " & geneString(event.logger) &
    " ^message " & geneString(event.message) &
    " ^payload " & renderGeneValue(
      if event.payload == nil: newJObject() else: event.payload) &
    " ^seq " & $event.sequence &
    " ^pid " & $event.processId &
    " ^thread " & $event.threadId
  if event.source.module.len > 0:
    result.add " ^source {^module " & geneString(event.source.module) &
      " ^line " & $event.source.line &
      " ^column " & $event.source.column & "}"
  result.add '}'

proc renderText(event: LogEvent): string =
  result = timestampText(event.timestamp) & " " &
    levelName(event.level).toUpperAscii() & " " & event.logger & " " &
    event.message.replace("\n", "\\n").replace("\r", "\\r")
  if event.payload != nil and event.payload.kind == JObject and
      event.payload.len > 0:
    result.add " payload=" & renderGeneValue(event.payload)

proc renderJsonl(event: LogEvent): string =
  var node = newJObject()
  node["schema"] = newJString("gene.log.v1")
  node["time"] = newJString(timestampText(event.timestamp))
  node["level"] = newJString(levelName(event.level))
  node["logger"] = newJString(event.logger)
  node["message"] = newJString(event.message)
  node["payload"] = if event.payload == nil: newJObject() else: event.payload
  node["seq"] = newJInt(BiggestInt(event.sequence))
  node["pid"] = newJInt(event.processId)
  node["thread"] = newJInt(event.threadId)
  if event.source.module.len > 0:
    var source = newJObject()
    source["module"] = newJString(event.source.module)
    source["line"] = newJInt(event.source.line)
    source["column"] = newJInt(event.source.column)
    node["source"] = source
  $node

proc boundedRender(sink: LogSink, event: LogEvent, maxBytes: int): string =
  result =
    case sink.format
    of lfGene: renderGene(event)
    of lfText: renderText(event)
    of lfJsonl: renderJsonl(event)
  if result.len <= maxBytes:
    return
  if sink.format == lfText:
    result = utf8Prefix(result, maxBytes - "[truncated]".len) & "[truncated]"
    return
  var reduced = event
  reduced.message =
    if event.message.len > 64:
      utf8Prefix(event.message, 64) & "[truncated]"
    else: event.message
  reduced.payload = %*{"truncated": true}
  reduced.source = LogSource()
  result =
    if sink.format == lfGene: renderGene(reduced)
    else: renderJsonl(reduced)
  if result.len > maxBytes:
    # Config validation keeps maxBytes large enough for either valid fallback.
    if sink.format == lfGene:
      result = "{^schema \"gene.log.v1\" ^level " &
        geneString(levelName(event.level)) & " ^logger " &
        geneString(event.logger) &
        " ^message \"[event truncated]\" ^^truncated}"
    else:
      var minimal = newJObject()
      minimal["schema"] = newJString("gene.log.v1")
      minimal["level"] = newJString(levelName(event.level))
      minimal["logger"] = newJString(event.logger)
      minimal["message"] = newJString("[event truncated]")
      minimal["truncated"] = newJBool(true)
      result = $minimal

proc colorPrefix(level: LogLevel): string =
  case level
  of llError: "\e[31m"
  of llWarn: "\e[33m"
  of llInfo: "\e[32m"
  of llDebug: "\e[36m"
  of llTrace: "\e[90m"
  of llOff: ""

proc sinkWrite(sink: LogSink, event: LogEvent, rendered: string) =
  if sink == nil or sink.unhealthy: return
  if sink.kind == lskConsole and consoleLogSuppressed(): return
  when compileOption("threads"):
    acquire(sink.lock)
    defer: release(sink.lock)
  try:
    if sink.unhealthy: return
    case sink.kind
    of lskConsole:
      var line = rendered
      let colorEnabled =
        case sink.color
        of lcAlways: true
        of lcNever: false
        of lcAuto:
          # A host writer owns the output (wasm/embedders): it is never a TTY,
          # and probing process stdio here is not merely useless but unsafe —
          # under Emscripten there is no stdio handle to interrogate. Check it
          # before touching the environment or isatty.
          if hostWriter != nil:
            false
          elif existsEnv("NO_COLOR") or
              getEnv("TERM", "").toLowerAscii() == "dumb":
            false
          elif sink.stderrStream:
            isatty(stderr)
          else:
            isatty(stdout)
      if colorEnabled:
        line = colorPrefix(event.level) & line & "\e[0m"
      if hostWriter != nil:
        hostWriter(line & "\n")
      elif sink.stderrStream:
        stderr.writeLine(line)
        stderr.flushFile()
      else:
        stdout.writeLine(line)
        stdout.flushFile()
    of lskFile:
      if sink.file != nil:
        sink.file.writeLine(rendered)
        if sink.flush == lflAlways or
            (sink.flush == lflError and event.level == llError):
          sink.file.flushFile()
    of lskCallback:
      if sink.callback != nil: sink.callback(rendered)
  except CatchableError as e:
    sink.unhealthy = true
    if not sink.failureReported:
      sink.failureReported = true
      emergencyWrite("sink '" & sink.name & "' failed: " & e.msg)

proc emitRoute(route: LogRoute, loggerName: string, level: LogLevel,
               message: string, payload: JsonNode, source: LogSource) =
  if not routeEnabled(route, level):
    return
  if inLogWrite:
    return
  inLogWrite = true
  try:
    let registry = activeRegistry
    let limits = registry.config.limits.effectiveLimits
    let maxDepth = limits.maxDepth
    let maxItems = limits.maxItems
    let maxStringBytes = limits.maxStringBytes
    let maxEventBytes = limits.maxEventBytes
    var itemCount = 0
    var truncated = false
    let safePayload = copyAndRedact(
      if payload == nil: newJObject() else: payload,
      registry.config.redactKeys, 0, itemCount,
      maxDepth, maxItems, maxStringBytes, truncated)
    if truncated and safePayload.kind == JObject:
      safePayload["truncated"] = newJBool(true)
    let safeMessage =
      if message.len > maxStringBytes:
        utf8Prefix(message, maxStringBytes) &
          "[truncated]"
      else: message
    when defined(geneWasm) or defined(emscripten):
      let processId = 0
      let threadId = 0
    else:
      let processId = getCurrentProcessId()
      let threadId = getThreadId()
    when defined(geneWasm) or defined(emscripten):
      # Emscripten's getTime path is not reliable in the minimal host ABI;
      # now() is the already-tested clock bridge for wasm.
      let timestamp = now()
    else:
      let timestamp = getTime().utc
    let event = LogEvent(timestamp: timestamp, level: level, logger: loggerName,
      message: safeMessage, payload: safePayload, sequence: nextLogSequence(),
      processId: processId, threadId: threadId, source: source)
    var geneReady = false
    var textReady = false
    var jsonReady = false
    var geneLine, textLine, jsonLine: string
    for sink in route.sinks:
      let rendered =
        case sink.format
        of lfGene:
          if not geneReady:
            geneLine = boundedRender(sink, event,
                                     maxEventBytes)
            geneReady = true
          geneLine
        of lfText:
          if not textReady:
            textLine = boundedRender(sink, event,
                                     maxEventBytes)
            textReady = true
          textLine
        of lfJsonl:
          if not jsonReady:
            jsonLine = boundedRender(sink, event,
                                     maxEventBytes)
            jsonReady = true
          jsonLine
      sinkWrite(sink, event, rendered)
  finally:
    inLogWrite = false

proc emitLog*(routeId: int, loggerName: string, level: LogLevel,
              message: string, payload: JsonNode = nil,
              source = LogSource()) =
  emitRoute(routeById(routeId), loggerName, level, message, payload, source)

proc emit*(logger: RuntimeLogger, level: LogLevel, message: string,
           payload: JsonNode = nil, source = LogSource()) =
  if logger == nil: return
  if logger.route == nil: bindRuntimeLogger(logger)
  emitRoute(logger.route, logger.name, level, message, payload, source)
