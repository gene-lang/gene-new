## Build provenance shared by the CLI and performance harnesses.
import std/strutils

const GeneVersion* = block:
  var version = ""
  for line in staticRead("../../gene.nimble").splitLines():
    if line.startsWith("version "):
      version = line.split('"')[1]
      break
  doAssert version.len > 0, "gene.nimble must declare its package version"
  version

const GeneBuildMode* =
  when defined(danger): "danger"
  elif defined(release): "release"
  else: "debug"

const GeneMemoryManager* =
  when defined(gcAtomicArc): "atomicArc"
  elif defined(gcOrc): "orc"
  elif defined(gcArc): "arc"
  else: "unknown"

const GeneOptimization* =
  when compileOption("opt", "speed"): "speed"
  elif compileOption("opt", "size"): "size"
  else: "none"

proc geneBuildInfo*(): string =
  "Gene " & GeneVersion & " (" & GeneBuildMode & "; " & hostOS & "/" &
    hostCPU & "; Nim " & NimVersion & "; mm=" & GeneMemoryManager &
    "; nim-opt=" & GeneOptimization &
    "; bounds=" & $compileOption("boundChecks") &
    "; overflow=" & $compileOption("overflowChecks") & ")"
