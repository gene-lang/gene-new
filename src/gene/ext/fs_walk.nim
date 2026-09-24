## Bounded, lazy directory traversal for gene/fs. Included by stdlib.nim.
## Directory handles live only during fsListDir; no OS handle spans a yield.

const
  fsWalkDefaultDepth = 64
  fsWalkDefaultPerDir = 10_000
  fsWalkDefaultTotal = 1_000_000

proc raiseFsWalkError(scope: Scope, kind, message: string) {.noreturn.} =
  var props = initPropTable()
  props["message"] = newStr(message)
  var error: ref GeneError
  new(error)
  error.msg = message
  error.errVal = newNode(builtInTypeHead(scope, kind), props = props)
  error.hasErrVal = true
  raise error

proc walkListNames(path: string, maximum: int, scope: Scope): Value =
  var names: seq[string]
  try:
    names = fsListDir(path)
  except CatchableError as error:
    raiseFsWalkError(scope, "FsError", "fs/walk: " & path & ": " & error.msg)
  if names.len > maximum:
    raiseFsWalkError(scope, "FsLimitError", "fs/walk directory entry limit: " & path)
  var values: seq[Value]
  for name in names: values.add newStr(name)
  result = newList(values)

proc walkFrame(path, relative, canonical: string, depth: int,
               maximum: int, scope: Scope): Value =
  var props = initPropTable()
  props["path"] = newStr(path)
  props["relative"] = newStr(relative)
  props["canonical"] = newStr(canonical)
  props["depth"] = newInt(depth)
  props["index"] = newInt(0)
  props["names"] = walkListNames(path, maximum, scope)
  result = newMap(props)

proc walkStateValue(stream: Value): Value =
  let source = stream.streamSource
  result = source.cellValue

proc walkClose(stream: Value) {.nimcall.} =
  let source = stream.streamSource
  source.setCellValue(NIL)

proc walkPull(stream: Value): StreamPullResult {.nimcall.} =
  let state = walkStateValue(stream)
  if state.kind == vkNil: return
  let scope = stream.streamItemScope
  while true:
    let frames = state.mapEntries.getOrDefault("frames", VOID)
    if frames.kind != vkList or frames.listItems.len == 0:
      return
    let top = frames.listItems[^1]
    let names = top.mapEntries["names"]
    let index = int(top.mapEntries["index"].intVal)
    if index >= names.listItems.len:
      var rest: seq[Value]
      for i in 0 ..< frames.listItems.len - 1: rest.add frames.listItems[i]
      state.putMapEntry("frames", newList(rest))
      continue
    top.putMapEntry("index", newInt(index + 1))
    let name = names.listItems[index].strVal
    let parent = top.mapEntries["path"].strVal
    let absolute = parent / name
    let oldRelative = top.mapEntries["relative"].strVal
    let relative = if oldRelative.len == 0: name else: oldRelative & "/" & name
    let depth = int(top.mapEntries["depth"].intVal) + 1
    var kind: string
    var size = NIL
    var traverse = false
    try:
      if symlinkExists(absolute):
        kind = "symlink"
        traverse = state.mapEntries["follow_symlinks"].boolVal and dirExists(absolute)
      elif dirExists(absolute):
        kind = "directory"
        traverse = true
      elif fileExists(absolute):
        kind = "file"
        size = newInt(getFileSize(absolute))
      else:
        raiseFsWalkError(scope, "FsError", "fs/walk entry disappeared: " & absolute)
    except OSError as error:
      raiseFsWalkError(scope, "FsError", "fs/walk: " & absolute & ": " & error.msg)
    let total = int(state.mapEntries["total"].intVal)
    let maxTotal = int(state.mapEntries["max_total"].intVal)
    if total >= maxTotal:
      raiseFsWalkError(scope, "FsLimitError", "fs/walk total entry limit exceeded")
    state.putMapEntry("total", newInt(total + 1))
    if traverse and depth < int(state.mapEntries["max_depth"].intVal):
      var canonical: string
      try:
        canonical = expandFilename(absolute)
      except OSError as error:
        raiseFsWalkError(scope, "FsError", "fs/walk: " & absolute & ": " & error.msg)
      for ancestor in frames.listItems:
        if ancestor.mapEntries["canonical"].strVal == canonical:
          raiseFsWalkError(scope, "FsError", "fs/walk symlink cycle: " & absolute)
      let maxPerDir = int(state.mapEntries["max_per_dir"].intVal)
      let child = walkFrame(absolute, relative, canonical, depth, maxPerDir, scope)
      var pushed: seq[Value]
      for frame in frames.listItems: pushed.add frame
      pushed.add child
      state.putMapEntry("frames", newList(pushed))
    var fields = initPropTable()
    fields["path"] = newStr(absolute)
    fields["relative_path"] = newStr(relative)
    fields["kind"] = newStr(kind)
    fields["size"] = size
    return StreamPullResult(has: true, item: newMap(fields))

proc biFsWalk(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if scope == nil or args.len != 1 or args[0].kind != vkString:
    raiseFsWalkError(scope, "FsError", "fs/walk expects one Str root")
  var maxDepth = fsWalkDefaultDepth
  var maxPerDir = fsWalkDefaultPerDir
  var maxTotal = fsWalkDefaultTotal
  var followSymlinks = false
  if call != nil:
    for i, key in call[].namedNames:
      let value = call[].namedValues[i]
      case key
      of "follow_symlinks":
        if value.kind != vkBool:
          raiseFsWalkError(scope, "FsError", "fs/walk ^follow_symlinks must be Bool")
        followSymlinks = value.boolVal
      of "max_depth", "max_entries_per_dir", "max_entries_total":
        if value.kind != vkInt or not value.intFitsInt64 or value.intVal < 1 or
            value.intVal > 1_000_000:
          raiseFsWalkError(scope, "FsError", "fs/walk limits must be positive bounded Int")
        case key
        of "max_depth": maxDepth = int(value.intVal)
        of "max_entries_per_dir": maxPerDir = int(value.intVal)
        else: maxTotal = int(value.intVal)
      else:
        raiseFsWalkError(scope, "FsError", "fs/walk unknown option: " & key)
  let root = if isAbsolute(args[0].strVal): args[0].strVal
             else: absolutePath(args[0].strVal, scope.application().launchDir)
  if not dirExists(root):
    raiseFsWalkError(scope, "FsError", "fs/walk root is not a directory: " & root)
  var canonical: string
  try:
    canonical = expandFilename(root)
  except OSError as error:
    raiseFsWalkError(scope, "FsError", "fs/walk: " & root & ": " & error.msg)
  let frame = walkFrame(root, "", canonical, 0, maxPerDir, scope)
  var props = initPropTable()
  props["frames"] = newList(@[frame])
  props["total"] = newInt(0)
  props["max_depth"] = newInt(maxDepth)
  props["max_per_dir"] = newInt(maxPerDir)
  props["max_total"] = newInt(maxTotal)
  props["follow_symlinks"] = newBool(followSymlinks)
  let source = newCell(newMap(props))
  result = newLazyStream(source, walkPull, itemScope = scope, close = walkClose)
