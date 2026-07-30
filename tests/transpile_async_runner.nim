## Adversarial cancellation checks for the web profile.

import gene/web
import std/[os, osproc, strutils]

let workDir = getTempDir() / "gene-transpile-async"
let outDir = workDir / "out"
createDir(workDir)
createDir(outDir)
let sourcePath = workDir / "async_cancel.gene"
writeFile(sourcePath, """
(mod async_cancel ^profile web)
(js/fn mark [] : Void ^from "./async_host.mjs")
(fn run [] : Int
  (scope
    (let task (spawn 42))
    (task ~ cancel)
    (try
      (await task)
      catch _ 99
      ensure (mark))))
""")
writeFile(workDir / "async_host.mjs", """
export let marks = 0;
export function mark() { marks++; }
""")

discard buildWebModule(sourcePath, outDir)
copyFile(workDir / "async_host.mjs", outDir / "async_host.mjs")
let runnerPath = workDir / "run.mjs"
writeFile(runnerPath, """
import { marks } from "./out/async_host.mjs";
import { GeneCancellation, run } from "./out/async_cancel.mjs";
let cancelled = false;
try {
  await run();
} catch (error) {
  cancelled = error instanceof GeneCancellation;
}
if (!cancelled) throw new Error("ordinary catch swallowed cancellation");
if (marks !== 1) throw new Error(`ensure ran ${marks} times instead of once`);
console.log("transpile cancellation contract passed");
""")
let executed = execCmdEx("node " & quoteShell(runnerPath))
if executed.exitCode != 0 or
    "transpile cancellation contract passed" notin executed.output:
  stderr.write(executed.output)
  quit(1)
echo executed.output.strip()
