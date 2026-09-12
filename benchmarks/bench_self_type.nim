## Protocol aggregate checks in the declaration's scope and across a module call.
## Run with -d:release -d:nimAllocStats to include allocator counts.
import std/[monotimes, os, sequtils, strutils, tempfiles, times]
import gene/[compiler, types, vm]

proc benchSelfTypeContracts*() =
  let directory = createTempDir("gene_self_contract_bench_", "")
  let providerPath = directory / "provider.gene"
  let consumerPath = directory / "consumer.gene"
  writeFile(providerPath, """
    (protocol Tagged)
    (type Item ^props {})
    (impl Tagged for Item)
    (fn check [items : (List Tagged)] : Int ($size items))
  """)
  writeFile(consumerPath, "(import [check] ^from \"./provider.gene\")")
  defer:
    removeFile(providerPath)
    removeFile(consumerPath)
    removeDir(directory)
  let app = newApplication(directory)
  let provider = app.loadFileModule(providerPath).moduleRootNamespace.nsScope
  let consumer = app.loadFileModule(consumerPath).moduleRootNamespace.nsScope
  let item = run(compileSource("(Item)"), provider)
  let call = compileSource("(check items)")
  for size in [1, 32, 512]:
    let items = newList(newSeqWith(size, item))
    for pair in [("same_module", provider), ("cross_module", consumer)]:
      pair[1].redefine("items", items)
      discard run(call, pair[1]) # exclude initialization and cache warmup
      let allocations = getAllocStats()
      let started = getMonoTime()
      var checksum = 0'i64
      for i in 0 ..< 2_000:
        checksum += run(call, pair[1]).intVal
      let elapsed = float(inNanoseconds(getMonoTime() - started)) / 1_000_000.0
      let delta = getAllocStats() - allocations
      echo "vm.protocol_list.", pair[0], ".", size, ": 2000 ops in ",
        formatFloat(elapsed, ffDecimal, 2), " ms; checksum=", checksum
      when defined(nimAllocStats):
        echo "  allocations: ", delta
      else:
        discard delta

when isMainModule:
  benchSelfTypeContracts()
