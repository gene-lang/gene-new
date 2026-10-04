## Shared, untimed reporting for native performance harnesses.
import std/[compilesettings, json, os, strutils]
import gene/build_info

let benchmarkJson* = "--json" in commandLineParams()
const benchmarkBuildCommand = querySetting(SingleValueSetting.commandLine)
const benchmarkCOptions = querySetting(SingleValueSetting.compileOptions)

proc beginBenchmarkReport*() =
  if benchmarkJson:
    echo $(%*{"kind": "build", "format": 1, "build": geneBuildInfo(),
      "clock": "monotonic-wall", "unit": "nanoseconds",
      "allocation_stats": defined(nimAllocStats),
      "nim_command": benchmarkBuildCommand, "c_options": benchmarkCOptions})
  else:
    echo "build: ", geneBuildInfo()
    echo "measurement: wall monotonic; per iteration includes result handling"

proc reportBenchmark*(name: string, iterations: int, nanos, checksum: int64,
                      retainedBytes = 0, allocations = -1) =
  if benchmarkJson:
    echo $(%*{"kind": "measurement", "name": name,
      "iterations": iterations, "nanoseconds": nanos, "checksum": checksum,
      "retained_nim_bytes_delta": retainedBytes, "allocations": allocations})
  else:
    let rate = float(iterations) * 1e9 / float(max(1'i64, nanos))
    echo name, ": ", iterations, " ops in ",
      formatFloat(float(nanos) / 1e6, ffDecimal, 2), " ms (",
      formatFloat(rate, ffDecimal, 0), " ops/s, checksum=", checksum, ")"

proc reportBenchmarkSkip*(name, reason: string) =
  if benchmarkJson:
    echo $(%*{"kind": "skip", "name": name, "reason": reason})
  else:
    echo name, ": skipped (", reason, ")"

proc allocationCount*(stats: AllocStats): int =
  when defined(nimAllocStats):
    for name, value in fieldPairs(stats):
      when name == "allocCount": return value
  else:
    return -1
