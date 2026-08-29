## Adversarial cancellation checks for the web profile.
##
## Three shapes, because they fail differently. Within one module the emitted
## `GeneCancellation` is the same class the host imports; across a module
## boundary each module emits its own, so identity is useless and the rethrow
## guard has to be a `Symbol.for` brand. And that brand must not be confusable
## with a Gene error that happens to carry a matching `^kind Str` field.

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
      catch Any 99
      ensure (mark))))
""")
# The producer holds the `scope`/`spawn`; the consumer holds only the Gene
# `catch`. Each emits its own GeneCancellation, so `instanceof` across the pair
# is false and a swallowed cancellation would look like an ordinary result.
let producerPath = workDir / "cancel_producer.gene"
writeFile(producerPath, """
(mod cancel_producer ^profile web)
(fn cancelled_work [] : Int
  (scope
    (let task (spawn 42))
    (task ~ cancel)
    (await task)))
""")
let consumerPath = workDir / "cancel_consumer.gene"
writeFile(consumerPath, """
(mod cancel_consumer ^profile web)
(import [cancelled_work] from "./cancel_producer.gene")
(js/fn mark2 [] : Void ^from "./async_host.mjs")
(fn guarded [] : Int
  (try
    (cancelled_work)
    catch Any 99
    ensure (mark2)))
""")
# A Gene error type may declare its own `^kind Str`. A structural check on that
# field would brand this valid error as a cancellation and make it uncatchable.
let collisionPath = workDir / "cancel_collision.gene"
writeFile(collisionPath, """
(mod cancel_collision ^profile web)
(type AppError ^props {^kind Str})
(impl Error for AppError)
(fn boom [] : Never
  (fail (AppError ^kind "gene_cancellation")))
(fn caught [] : Str
  (try (boom) catch AppError $ex/kind))
""")
writeFile(workDir / "async_host.mjs", """
export let marks = 0;
export function mark() { marks++; }
export let marks2 = 0;
export function mark2() { marks2++; }
""")

discard buildWebModule(sourcePath, outDir)
discard buildWebModule(consumerPath, outDir)
discard buildWebModule(collisionPath, outDir)
copyFile(workDir / "async_host.mjs", outDir / "async_host.mjs")
let runnerPath = workDir / "run.mjs"
writeFile(runnerPath, """
import { marks, marks2 } from "./out/async_host.mjs";
import { GeneCancellation, run } from "./out/async_cancel.mjs";
import { guarded } from "./out/cancel_consumer.mjs";
import { caught } from "./out/cancel_collision.mjs";
const brand = Symbol.for("gene.cancellation");
const cancellation = (error) =>
  typeof error === "object" && error !== null && brand in error;

let cancelled = false;
let sameClass = false;
try {
  await run();
} catch (error) {
  cancelled = cancellation(error);
  sameClass = error instanceof GeneCancellation;
}
if (!cancelled) throw new Error("ordinary catch swallowed cancellation");
if (!sameClass) throw new Error("single-module cancellation lost its class");
if (marks !== 1) throw new Error(`ensure ran ${marks} times instead of once`);

let crossModule = false;
let swallowed;
try {
  swallowed = await guarded();
} catch (error) {
  crossModule = cancellation(error);
}
if (!crossModule) {
  throw new Error(
    `imported cancellation was swallowed by catch Any (returned ${swallowed})`);
}
if (marks2 !== 1) throw new Error(`ensure ran ${marks2} times instead of once`);

const collided = await caught();
if (collided !== "gene_cancellation") {
  throw new Error(
    `a Gene error with ^kind "gene_cancellation" was branded as a cancellation`);
}
console.log("transpile cancellation contract passed");
""")
let executed = execCmdEx("node " & quoteShell(runnerPath))
if executed.exitCode != 0 or
    "transpile cancellation contract passed" notin executed.output:
  stderr.write(executed.output)
  quit(1)
echo executed.output.strip()
