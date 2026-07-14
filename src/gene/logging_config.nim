## Data-only logging configuration loader (docs/proposals/logging.md §7).

import std/[algorithm, os, sets, strutils, tables]
import ./[logging, reader, types]

proc configError(message: string): ref ValueError =
  newException(ValueError, "logging config: " & message)

proc requireMap(value: Value, context: string): lent PropTable =
  if value.kind != vkMap:
    raise configError(context & " must be a PropMap")
  value.mapEntries

proc requireString(value: Value, context: string): string =
  case value.kind
  of vkString: value.strVal
  of vkSymbol: value.symVal
  else: raise configError(context & " must be a string or symbol")

proc optionalString(entries: PropTable, key, fallback: string): string =
  if not entries.hasKey(key): return fallback
  requireString(entries[key], "^" & key)

proc rejectUnknown(entries: PropTable, allowed: openArray[string],
                   context: string) =
  var names = initHashSet[string]()
  for name in allowed: names.incl name
  for key, _ in entries:
    if key notin names:
      raise configError(context & " has unknown key ^" & key)

proc parseStringList(value: Value, context: string): seq[string] =
  if value.kind != vkList:
    raise configError(context & " must be a list of strings")
  var seen = initHashSet[string]()
  for item in value.listItems:
    let name = requireString(item, context & " item")
    if name notin seen:
      seen.incl name
      result.add name

proc parseLevel(value: Value, context: string): LogLevel =
  let name = requireString(value, context)
  if not parseLogLevel(name, result):
    raise configError(context & " has invalid level '" & name & "'")

proc parseFormat(value: Value, context: string): LogFormat =
  let name = requireString(value, context)
  if not parseLogFormat(name, result):
    raise configError(context & " has invalid format '" & name & "'")

proc parseFlush(value: Value, context: string): LogFlush =
  let name = requireString(value, context)
  if not parseLogFlush(name, result):
    raise configError(context & " has invalid flush policy '" & name & "'")

proc parseColor(value: Value, context: string): LogColor =
  let name = requireString(value, context).toLowerAscii()
  case name
  of "auto": lcAuto
  of "always": lcAlways
  of "never": lcNever
  else: raise configError(context & " has invalid color policy '" & name & "'")

proc parsePositiveInt(entries: PropTable, key: string,
                      fallback: int): int =
  if not entries.hasKey(key): return fallback
  let value = entries[key]
  if value.kind != vkInt or value.intVal <= 0 or value.intVal > high(int):
    raise configError("^" & key & " must be a positive Int")
  int(value.intVal)

proc loggerEntries(value: Value): seq[(string, Value)] =
  case value.kind
  of vkHashMap:
    for entry in value.hashMapEntries:
      result.add (requireString(entry.key, "logger name"), entry.val)
  of vkMap:
    for key, item in value.mapEntries:
      result.add (key, item)
  else:
    raise configError("^loggers must be a general map")

proc parseLoggingConfigValue*(value: Value, configDir: string): LoggingConfig =
  result = defaultLoggingConfig()
  var completed = false
  defer:
    if not completed:
      for _, sink in result.sinks:
        closeLogSink(sink)
  let root = requireMap(value, "root")
  rejectUnknown(root,
    ["level", "sinks", "targets", "loggers", "redact_keys", "limits"],
    "root")

  if root.hasKey("level"):
    result.rootLevel = parseLevel(root["level"], "^level")

  if root.hasKey("sinks"):
    let sinkDefs = requireMap(root["sinks"], "^sinks")
    for _, sink in result.sinks:
      closeLogSink(sink)
    result.sinks = initTable[string, LogSink]()
    for sinkName, sinkValue in sinkDefs:
      if sinkName.len == 0:
        raise configError("sink name must not be empty")
      let sink = requireMap(sinkValue, "sink '" & sinkName & "'")
      if not sink.hasKey("type"):
        raise configError("sink '" & sinkName & "' requires ^type")
      let sinkType = requireString(sink["type"],
                                   "sink '" & sinkName & "' ^type").toLowerAscii()
      let format =
        if sink.hasKey("format"):
          parseFormat(sink["format"], "sink '" & sinkName & "' ^format")
        else: lfGene
      case sinkType
      of "console":
        rejectUnknown(sink, ["type", "stream", "format", "color"],
                      "console sink '" & sinkName & "'")
        let stream = optionalString(sink, "stream", "stderr").toLowerAscii()
        if stream notin ["stderr", "stdout"]:
          raise configError("sink '" & sinkName &
                            "' ^stream must be stderr or stdout")
        let color =
          if sink.hasKey("color"):
            parseColor(sink["color"], "sink '" & sinkName & "' ^color")
          else: lcAuto
        result.sinks[sinkName] = newConsoleLogSink(sinkName,
          stderrStream = stream == "stderr", format = format, color = color)
      of "file":
        rejectUnknown(sink, ["type", "path", "format", "flush"],
                      "file sink '" & sinkName & "'")
        when defined(geneWasm) or defined(emscripten):
          raise configError("file sinks are unavailable in wasm")
        else:
          if not sink.hasKey("path"):
            raise configError("file sink '" & sinkName & "' requires ^path")
          let configured = requireString(sink["path"],
            "file sink '" & sinkName & "' ^path")
          if configured.len == 0:
            raise configError("file sink '" & sinkName & "' path is empty")
          let path =
            if configured.isAbsolute: configured
            else: configDir / configured
          let flush =
            if sink.hasKey("flush"):
              parseFlush(sink["flush"], "file sink '" & sinkName & "' ^flush")
            else: lflError
          result.sinks[sinkName] = newFileLogSink(sinkName, path, format, flush)
      else:
        raise configError("sink '" & sinkName & "' has unsupported type '" &
                          sinkType & "'")

  if root.hasKey("targets"):
    result.rootTargets = parseStringList(root["targets"], "^targets")
  elif result.sinks.hasKey("stderr"):
    result.rootTargets = @["stderr"]
  else:
    result.rootTargets = @[]
    for name in result.sinks.keys: result.rootTargets.add name
    result.rootTargets.sort()
  for target in result.rootTargets:
    if not result.sinks.hasKey(target):
      raise configError("root references unknown sink '" & target & "'")

  result.overrides = @[]
  if root.hasKey("loggers"):
    for loggerEntry in loggerEntries(root["loggers"]):
      let (name, loggerValue) = loggerEntry
      if not validLoggerName(name):
        raise configError("invalid logger name '" & name & "'")
      let entries = requireMap(loggerValue, "logger '" & name & "'")
      rejectUnknown(entries, ["level", "targets"], "logger '" & name & "'")
      var override = LogRouteOverride(name: name)
      if entries.hasKey("level"):
        override.hasLevel = true
        override.level = parseLevel(entries["level"],
                                    "logger '" & name & "' ^level")
      if entries.hasKey("targets"):
        override.hasTargets = true
        override.targets = parseStringList(entries["targets"],
                                           "logger '" & name & "' ^targets")
        for target in override.targets:
          if not result.sinks.hasKey(target):
            raise configError("logger '" & name &
                              "' references unknown sink '" & target & "'")
      if not override.hasLevel and not override.hasTargets:
        raise configError("logger '" & name & "' override is empty")
      result.overrides.add override

  if root.hasKey("redact_keys"):
    result.redactKeys = initHashSet[string]()
    for key in parseStringList(root["redact_keys"], "^redact_keys"):
      result.redactKeys.incl key.toLowerAscii()

  if root.hasKey("limits"):
    let limits = requireMap(root["limits"], "^limits")
    rejectUnknown(limits,
      ["max_depth", "max_items", "max_string_bytes", "max_event_bytes"],
      "^limits")
    result.limits.maxDepth =
      parsePositiveInt(limits, "max_depth", result.limits.maxDepth)
    result.limits.maxItems =
      parsePositiveInt(limits, "max_items", result.limits.maxItems)
    result.limits.maxStringBytes = parsePositiveInt(
      limits, "max_string_bytes", result.limits.maxStringBytes)
    result.limits.maxEventBytes = parsePositiveInt(
      limits, "max_event_bytes", result.limits.maxEventBytes)
    if result.limits.maxEventBytes < 256:
      raise configError("^max_event_bytes must be at least 256")
  completed = true

proc loadLoggingConfig*(path: string): LoggingConfig =
  if path.len == 0:
    raise configError("path must not be empty")
  let absolute = absolutePath(path)
  if not fileExists(absolute):
    raise configError("file not found: " & absolute)
  let forms = readAll(readFile(absolute), absolute)
  if forms.len != 1:
    raise configError("file must contain exactly one data map")
  parseLoggingConfigValue(forms[0], parentDir(absolute))

proc configureLoggingFromFile*(path: string) =
  installLoggingConfig(loadLoggingConfig(path))
