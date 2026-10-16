## Identical instrumentation for old/new VMs. Gene owns the workloads; this
## host supplies only a nanosecond clock without requiring the old CLI to
## expose a clock API it did not yet have.
import std/[monotimes, os, strutils]
import gene/[compiler, types, vm]

proc execClockNs(args: openArray[Value]): Value {.nimcall.} =
  newInt(getMonoTime().ticks)

if paramCount() < 2:
  quit("usage: exec_clock_host WORKLOAD.gene CHILD_EXE [COUNT] [CASE]", 2)
let sourcePath = absolutePath(paramStr(1))
let profilePath = getEnv("GENE_EXEC_PROFILE_PID_FILE")
if profilePath.len > 0: writeFile(profilePath, $getCurrentProcessId())
let scope = newGlobalScope(newApplication(getCurrentDir()))
scope.define("exec_clock_ns", newNativeFn("exec_clock_ns", execClockNs))
scope.define("exec_fixture", newStr(absolutePath(paramStr(2))))
scope.define("exec_iterations", newInt(
  if paramCount() > 2: parseInt(paramStr(3)) else: 100))
scope.define("exec_case", newStr(if paramCount() > 3: paramStr(4) else: "all"))
discard run(compileSource(readFile(sourcePath), sourcePath), scope)
