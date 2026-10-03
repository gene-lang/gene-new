## Macro compilation and runtime expansion scaling. The Nim host measures the
## compiler directly, as in bench_macros; no Gene timing API is needed here.
## Run: nim c -r -d:release --path:src benchmarks/bench_macro_compile.nim

import gene/[compiler, types, vm]
import std/[monotimes, os, strutils, times]

initModuleContext(getCurrentDir())
discard newGlobalScope()

for functions in [0, 2_000]:
  var declarations = ""
  for i in 0 ..< functions:
    declarations.add "(fn f" & $i & " [x] x)\n"
  for calls in [200, 2_000]:
    for kind in ["template", "helper", "local"]:
      var source = declarations
      case kind
      of "template": source.add "(macro m [x] `(+ %x 1))\n"
      of "helper": source.add "(fn helper [x] `(+ %x 1)) (macro m [x] (helper x))\n"
      else:
        source.add "(fn work [] (macro m [x] `(+ %x 1)) " &
          "(var total 0) (repeat i in " & $calls &
          " (set total (+ total (m i)))) total) (work)"
      if kind != "local":
        source.add "["
        for i in 0 ..< calls:
          source.add "(m " & $i & ") "
        source.add "]"
      let started = getMonoTime()
      let chunk = compileSource(source)
      let compiled = getMonoTime()
      let value = run(chunk, newGlobalScope())
      let finished = getMonoTime()
      if kind == "local":
        doAssert value.intVal == int64(calls) * int64(calls + 1) div 2
      else:
        doAssert value.listItems.len == calls
        doAssert value.listItems[^1].intVal == calls
      echo kind, " functions=", functions, " calls=", calls,
        " compile_ms=", formatFloat(float(inNanoseconds(compiled - started)) / 1e6, ffDecimal, 3),
        " run_ms=", formatFloat(float(inNanoseconds(finished - compiled)) / 1e6, ffDecimal, 3)

for functions in [2_000, 8_000]:
  var source = ""
  for i in 0 ..< functions:
    source.add "(fn f" & $i & " [x] x)\n"
  let started = getMonoTime()
  discard compileSource(source)
  echo "macro_free functions=", functions, " compile_ms=",
    formatFloat(float(inNanoseconds(getMonoTime() - started)) / 1e6, ffDecimal, 3)
