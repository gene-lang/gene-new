## Load-speed comparison: `readAll` (lex + parse `.gene` text) vs
## `decodePacked` (decode the reversible-format packed binary) --
## docs/proposals/reversible-ai-native-program-format.md, "Runtime benchmark"
## and "Benchmark corpus and calculation".
##
## This is a quick, provisional measurement over the repository's own
## `.gene` corpus, not the full manifest-gated benchmark corpus the proposal
## specifies (committed manifest, >=20 generated+repository cases per class
## with comment-density stratification, a dependency-graph class, 5
## warmups/30 measured reps). It exists to give the load-speed claim a first,
## honest, reproducible number before investing in that fuller harness --
## every number below is measured, not assumed.
##
## Files are bucketed by canonical `.gene` byte size into the proposal's
## single-unit classes (the dependency-graph class needs real multi-module
## resolution and is out of scope here). `encodePacked` is setup cost, timed
## once and excluded, matching the proposal's framing that packing is a
## producer-side cost, not part of the "load" a consumer pays every time.
##
## Run:
##   nimble native_format_perf

import gene/[packed_format, program_document, reader]
import std/[algorithm, math, monotimes, os, strformat, strutils, tables, times]

const warmups = 3
const reps = 10

type Case = object
  path: string
  src: string
  packed: string

proc classOf(bytes: int): string =
  if bytes <= 1024: "tiny (<=1 KiB)"
  elif bytes <= 16 * 1024: "small (<=16 KiB)"
  elif bytes <= 256 * 1024: "medium (<=256 KiB)"
  elif bytes <= 4 * 1024 * 1024: "large (<=4 MiB)"
  else: "huge (>4 MiB)"

proc medianNanos(run: proc()): float =
  var samples: seq[float]
  for _ in 0 ..< warmups: run()
  for _ in 0 ..< reps:
    let start = getMonoTime()
    run()
    let elapsed = (getMonoTime() - start).inNanoseconds.float
    samples.add elapsed
  samples.sort()
  samples[samples.len div 2]

proc geoMean(xs: seq[float]): float =
  if xs.len == 0: return 0.0
  var logSum = 0.0
  for x in xs: logSum += ln(max(x, 1e-9))
  exp(logSum / xs.len.float)

var cases: seq[Case]
for dir in ["examples", "tests"]:
  if not dirExists(dir): continue
  for path in walkDirRec(dir):
    if not path.endsWith(".gene"): continue
    let src =
      try: readFile(path)
      except CatchableError: continue
    let packed =
      try: encodePacked(readDocument(src, path))
      except CatchableError: ""  # unsupported v0 value kind, or a doc-model
                                   # mismatch this module rejects -- excluded
                                   # from the packed side rather than faked.
    if packed.len == 0: continue
    cases.add Case(path: path, src: src, packed: packed)

echo &"corpus: {cases.len} files packed successfully out of files scanned under examples/ and tests/"
echo &"reps per file: {reps} (+{warmups} warmups), release build, median of the {reps} timed runs"
echo ""

var byClass: Table[string, seq[float]]
var overall: seq[float]

for c in cases:
  let cls = classOf(c.src.len)
  let readNanos = medianNanos(proc() =
    discard readAll(c.src, c.path))
  let decodeNanos = medianNanos(proc() =
    discard decodePacked(c.packed))
  let speedup = readNanos / max(decodeNanos, 1.0)
  byClass.mgetOrPut(cls, @[]).add speedup
  overall.add speedup

let classOrder = ["tiny (<=1 KiB)", "small (<=16 KiB)", "medium (<=256 KiB)",
                   "large (<=4 MiB)", "huge (>4 MiB)"]
echo "class                 n    geomean(readAll / decodePacked)"
for cls in classOrder:
  if byClass.hasKey(cls):
    let scores = byClass[cls]
    echo &"{cls:<22}{scores.len:>3}    {geoMean(scores):.2f}x"

echo ""
echo &"overall geometric-mean speedup: {geoMean(overall):.2f}x  (n={overall.len})"
echo ""
echo "Provisional acceptance bar in the proposal: >=2x overall geometric-mean" &
  " speedup, every class score >=0.95x. This run does not include file I/O," &
  " allocation counts, or the full manifest-gated corpus -- see the module" &
  " doc comment above."
