## Shared Gene/web-profile conformance fixture runner.
##
## The JSON manifest is deliberately backend-neutral. This runner supplies the
## VM half of the comparison; the web backend runner consumes the same cases
## once P2 emits its first module (docs/proposals/transpile.md §5).

import gene/[compiler, printer, types, vm]
import std/[json, os, strutils]

proc envelope(value: Value): JsonNode =
  result = newJObject()
  case value.kind
  of vkNil:
    result["kind"] = %"nil"
  of vkVoid:
    result["kind"] = %"void"
  of vkBool:
    result["kind"] = %"bool"
    result["value"] = %value.boolVal
  of vkInt:
    result["kind"] = %"int"
    result["value"] = %value.intToString
  of vkFloat:
    result["kind"] = %"f64"
    result["value"] = %value.print()
  of vkString:
    result["kind"] = %"str"
    result["value"] = %value.strVal
  of vkSymbol:
    result["kind"] = %"sym"
    result["value"] = %value.symVal
  of vkList:
    result["kind"] = %"list"
    result["items"] = newJArray()
    for item in value.listItems:
      result["items"].add envelope(item)
  of vkMap:
    result["kind"] = %"prop_map"
    result["entries"] = newJArray()
    for key, item in value.mapEntries:
      result["entries"].add %*{
        "key": key,
        "value": envelope(item)
      }
  of vkHashMap:
    result["kind"] = %"map"
    result["entries"] = newJArray()
    for entry in value.hashMapEntries:
      result["entries"].add %*{
        "key": envelope(entry.key),
        "value": envelope(entry.val)
      }
  of vkNode:
    result["kind"] = %"node"
    result["head"] = envelope(value.head)
    result["props"] = newJArray()
    for key, item in value.props:
      result["props"].add %*{
        "key": key,
        "value": envelope(item)
      }
    result["body"] = newJArray()
    for item in value.body:
      result["body"].add envelope(item)
  else:
    raise newException(ValueError,
      "fixture envelope does not support " & $value.kind)

proc fail(id, message: string) {.noreturn.} =
  stderr.writeLine("transpile fixture " & id & ": " & message)
  quit(1)

let manifestPath = getCurrentDir() / "tests" / "transpile" / "fixtures.json"
let manifest = parseFile(manifestPath)
if manifest{"version"}.getInt(0) != 1:
  fail("<manifest>", "unsupported or missing version")

var count = 0
for fixture in manifest["cases"]:
  inc count
  let id = fixture["id"].getStr()
  let source = fixture["source"].getStr()
  let profile = fixture["profile"]
  let status = profile{"status"}.getStr()
  if status notin ["eligible", "rejected"]:
    fail(id, "profile.status must be eligible or rejected")
  if status == "rejected" and profile{"reason"}.getStr().len == 0:
    fail(id, "a rejected case must name its reason")
  if not fixture.hasKey("expected_stdout"):
    fail(id, "expected_stdout is required")
  if fixture["expected_stdout"].getStr().len != 0:
    fail(id, "stdout capture is not admitted by the seed profile")

  let expectedError = fixture{"expected_error"}
  try:
    let actual = envelope(run(compileSource(source), newGlobalScope()))
    if expectedError.kind != JNull:
      fail(id, "expected VM error containing: " & expectedError.getStr())
    if not fixture.hasKey("expected_value") or
        actual != fixture["expected_value"]:
      fail(id, "result mismatch\nexpected: " &
        $fixture{"expected_value"} & "\nactual:   " & $actual)
  except CatchableError as error:
    if expectedError.kind == JNull or
        expectedError.getStr() notin error.msg:
      fail(id, "unexpected VM error: " & error.msg)

if count == 0:
  fail("<manifest>", "contains no cases")
echo "transpile fixtures: " & $count & " VM cases passed"
