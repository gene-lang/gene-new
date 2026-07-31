## Web-backend half of tests/transpile/fixtures.json.

import gene/web
import std/[json, os, osproc, strutils]

proc fail(id, message: string) {.noreturn.} =
  stderr.writeLine("transpile web fixture " & id & ": " & message)
  quit(1)

let manifest = parseFile(getCurrentDir() / "tests" / "transpile" / "fixtures.json")
let workDir = getTempDir() / "gene-transpile-web-fixtures"
createDir(workDir)
var count = 0

for fixture in manifest["cases"]:
  inc count
  let id = fixture["id"].getStr()
  let source = fixture{"web_source"}.getStr()
  if source.len == 0:
    fail(id, "web_source is required for every fixture")
  let safeId = id.replace(".", "_")
  let caseDir = workDir / safeId
  createDir(caseDir)
  let sourcePath = caseDir / (safeId & ".gene")
  let outDir = caseDir / "out"
  writeFile(sourcePath, source)
  let extraFiles = fixture{"web_files"}
  if extraFiles != nil and extraFiles.kind == JObject:
    for name, contents in extraFiles:
      if name.len == 0 or name != extractFilename(name):
        fail(id, "web_files keys must be simple file names")
      writeFile(caseDir / name, contents.getStr())
  createDir(outDir)
  let status = fixture["profile"]["status"].getStr()
  if status == "rejected":
    var rejected = false
    try:
      discard buildWebModule(sourcePath, outDir)
    except WebProfileError as error:
      rejected = true
      let diagnostic = fixture["profile"]{"diagnostic"}.getStr()
      if diagnostic.len == 0 or diagnostic notin error.msg:
        fail(id, "wrong rejection diagnostic: " & error.msg)
    if not rejected:
      fail(id, "web backend accepted a rejected fixture")
    continue

  let exportName = fixture{"web_export"}.getStr()
  if exportName.len == 0:
    fail(id, "eligible fixture requires web_export")
  try:
    discard buildWebModule(sourcePath, outDir)
  except CatchableError as error:
    fail(id, "web build failed: " & error.msg)
  let modulePath = outDir / (safeId & ".mjs")
  let runnerPath = caseDir / (safeId & "_run.mjs")
  let runner = """
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(""" & $(%modulePath) & """).href);
function envelope(value) {
  if (value === null) return {kind: "nil"};
  if (value === undefined) return {kind: "void"};
  if (typeof value === "boolean") return {kind: "bool", value};
  if (typeof value === "string") return {kind: "str", value};
  if (typeof value === "bigint") return {kind: "int", value: value.toString()};
  // Gene's float printer renders a whole F64 as "4.0"; JS String(4) is "4".
  // Without this the two backends disagree on every integral float result,
  // which is a rendering artifact of the harness rather than a real
  // divergence — and it would mask the divergences this suite exists to catch.
  if (typeof value === "number") return {kind: "f64", value: Number.isInteger(value) && Number.isFinite(value) ? value.toFixed(1) : String(value)};
  if (typeof value === "symbol") return {kind: "sym", value: Symbol.keyFor(value) ?? value.description};
  if (Array.isArray(value)) return {kind: "list", items: value.map(envelope)};
  if (value instanceof Map || value?.constructor?.name === "GeneMap") return {kind: "map", entries: [...value].map(([key, item]) => ({key: envelope(key), value: envelope(item)}))};
  if (value && typeof value.head === "symbol" && value.props && Array.isArray(value.body)) return {kind: "node", head: envelope(value.head), props: Object.entries(value.props).map(([key, item]) => ({key, value: envelope(item)})), body: value.body.map(envelope)};
  if (value && value.constructor === Object) return {kind: "prop_map", entries: Object.entries(value).map(([key, item]) => ({key, value: envelope(item)}))};
  throw new TypeError(`unsupported fixture result: ${typeof value}`);
}
console.log(JSON.stringify(envelope(await mod[""" & $(%exportName) & """]())));
"""
  writeFile(runnerPath, runner)
  let executed = execCmdEx("node " & quoteShell(runnerPath))
  if executed.exitCode != 0:
    fail(id, "Node execution failed: " & executed.output)
  var actual: JsonNode
  try:
    actual = parseJson(executed.output.strip())
  except CatchableError as error:
    fail(id, "invalid Node envelope: " & error.msg & "\n" & executed.output)
  if actual != fixture["expected_value"]:
    fail(id, "result mismatch\nexpected: " & $fixture["expected_value"] &
      "\nactual:   " & $actual)

echo "transpile fixtures: " & $count & " web cases passed"
