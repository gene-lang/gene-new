## Embedded web modules: the lifecycle, not the internals
## (docs/proposals/transpile.md §4.12 "Acceptance").
##
## These exercise the interfaces an application actually touches — load a
## module, ask the application what it publishes, fetch it by URL — because the
## defects this phase exists to catch are lifecycle defects: an asset base that
## only works at the root, two applications sharing a table, a hash that
## depends on itself, a source map carrying the server.

import gene/[vm, web, types]
import std/[json, os, osproc, strutils]

proc fail(label, message: string) {.noreturn.} =
  stderr.writeLine("embedded web module " & label & ": " & message)
  quit(1)

proc check(label: string, condition: bool, message: string) =
  if not condition: fail(label, message)

let workDir = getTempDir() / "gene-transpile-embed"
removeDir(workDir)
createDir(workDir)

const clientModule = """
(mod embed_host)

(web_module widget
  (fn label [n : Int] : Str
    (if (== n 1) "1 item" "many items"))

  (fn on_click [event : Any] : Void
    (var target event/target)
    (set! target/text_content (label 1))
    void)

  (fn main [root : EventTarget] : Void
    ($dom/add_event_listener root "click" on_click)))

(var page_asset widget)
"""

proc writeModule(dir, name, source: string): string =
  createDir(dir)
  result = dir / (name & ".gene")
  writeFile(result, source)

proc assetOf(app: Application, scopeValue: Value, name: string): WebAsset =
  let binding = scopeValue.moduleRootNamespace.nsScope.lookup(name)
  check("binding", binding.kind == vkNode,
        "web_module " & name & " did not bind a value")
  result = app.webAssetFor(binding)
  check("binding", result != nil, "binding is not a known web asset")

# --- 1. one authored file compiles, publishes, and is content-addressed ------

let hostPath = writeModule(workDir / "host", "app", clientModule)
let app = newApplication(workDir / "host")
let hostModule = app.loadFileModule(hostPath)
let asset = app.assetOf(hostModule, "widget")

check("identity", webAssetIdentity(asset) == hostPath & "#widget",
      "unexpected identity: " & webAssetIdentity(asset))

let routes = webAssetRoutes(asset)
check("routes", routes.len == 2, "expected an entry and a map")
let entryRoute = routes[0]
let mapRoute = routes[1]

# --- 2. hashes are reproducible and not self-referential ---------------------
#
# The entry ends with the map's URL, so hashing "the emitted bytes" would hash
# a name derived from those bytes. Order is map-first, and both hashes must be
# recoverable from the bytes that are actually served.

check("hash", entryRoute.fileName.endsWith(".js"), "entry is not a .js route")
let entryHash = entryRoute.fileName.split('-')[^1].replace(".js", "")
check("hash", entryHash == webContentHash(entryRoute.body),
      "entry hash does not address its own bytes")
let mapHash = mapRoute.fileName.split('-')[^1].replace(".js.map", "")
check("hash", mapHash == webContentHash(mapRoute.body),
      "map hash does not address its own bytes")
check("hash", mapRoute.fileName in entryRoute.body,
      "entry does not reference the hashed map name")
check("hash", entryRoute.fileName notin entryRoute.body,
      "entry references its own content-addressed name (circular hash)")

# Reproducible: the same module compiled again yields byte-identical output,
# so a restarted server serves the URLs the pages it already sent are asking
# for. The identity is deliberately *in* the artifact, so this is a same-path
# claim — two copies at different paths are different modules.
let rebuiltApp = newApplication(workDir / "host")
let rebuiltAsset = rebuiltApp.assetOf(
  rebuiltApp.loadFileModule(hostPath), "widget")
let rebuiltRoutes = webAssetRoutes(rebuiltAsset)
check("hash", rebuiltRoutes[0].fileName == entryRoute.fileName and
      rebuiltRoutes[0].body == entryRoute.body,
      "recompiling the same module produced different entry bytes")
check("hash", rebuiltRoutes[1].fileName == mapRoute.fileName,
      "recompiling the same module produced a different map URL")

# --- 3. the map exposes the embedded block and nothing else ------------------

let map = parseJson(mapRoute.body)
let sourcesContent = map["sourcesContent"][0].getStr()
check("map", "add_event_listener" in sourcesContent,
      "map does not carry the embedded block")
check("map", "web_module widget" in sourcesContent,
      "map does not carry the block's own header")
check("map", "page_asset" notin sourcesContent,
      "map leaks host-module source that follows the block")
check("map", "mod embed_host" notin sourcesContent,
      "map leaks host-module source that precedes the block")
check("map", map["mappings"].getStr().len > 0, "map has no mappings")

# Host line numbers survive: the block starts on line 3 of app.gene, so the
# redacted content must have two blank lines before it.
let contentLines = sourcesContent.split('\n')
check("map", contentLines.len > 3, "redacted source lost its line structure")
check("map", contentLines[0].strip().len == 0 and contentLines[1].strip().len == 0,
      "redacted source did not preserve host line offsets")
check("map", contentLines[2].startsWith("(web_module widget"),
      "block does not start on its authored line: " & contentLines[2])

# --- 4. the asset base is configurable, not a process root -------------------

let defaultUrl = app.webMountScriptUrl(asset, "root")
check("base", defaultUrl.startsWith("/__gene/"),
      "default base is not /__gene: " & defaultUrl)
check("base", app.lookupWebRoute(defaultUrl).found,
      "default-base URL does not resolve")

app.webAssetBase = "/todo/assets/"
let subpathUrl = app.webMountScriptUrl(asset, "root")
check("base", subpathUrl.startsWith("/todo/assets/"),
      "configured base ignored: " & subpathUrl)
check("base", app.lookupWebRoute(subpathUrl).found,
      "subpath URL does not resolve under the configured base")
check("base", not app.lookupWebRoute(defaultUrl).found,
      "old root still answers after the base moved")

# A generated sibling importing a generated sibling uses a relative specifier,
# so relocating the deployment moves the pair together.
let mountRoute = app.lookupWebRoute(subpathUrl).route
check("base", "\"./" & entryRoute.fileName & "\"" in mountRoute.body,
      "mount module does not import its entry relatively")
app.webAssetBase = "/__gene"

# --- 5. two applications cannot read each other's routes ---------------------

let otherPath = writeModule(workDir / "other", "app", clientModule)
let otherApp = newApplication(workDir / "other")
let otherAsset = otherApp.assetOf(otherApp.loadFileModule(otherPath), "widget")
let otherUrl = otherApp.webMountScriptUrl(otherAsset, "root")
check("isolation", not app.lookupWebRoute(otherUrl).found,
      "an application answered another application's generated route")
check("isolation", otherApp.lookupWebRoute(otherUrl).found,
      "the owning application does not answer its own route")

# --- 6. an older generation stays fetchable while a newer one publishes ------
#
# A browser can receive a page naming generation N immediately before the
# server publishes N+1. Content addressing is what makes retention automatic:
# publishing only ever adds keys.

let generationOne = app.webMountScriptUrl(asset, "root")
let generationTwo = app.webMountScriptUrl(asset, "other_root")
check("generations", generationOne != generationTwo,
      "two mounts collapsed onto one URL")
check("generations",
      app.lookupWebRoute(generationOne).found and
      app.lookupWebRoute(generationTwo).found,
      "publishing a new generation invalidated an outstanding one")

# --- 7. source-map exposure is a policy, not a byte-level decision -----------

check("policy", app.lookupWebRoute(app.webAssetUrl(mapRoute.fileName)).found,
      "dev does not publish the redacted map")
app.webSourceMapsEnabled = false
check("policy", not app.lookupWebRoute(app.webAssetUrl(mapRoute.fileName)).found,
      "map route still answers with maps disabled")
check("policy", app.lookupWebRoute(app.webAssetUrl(entryRoute.fileName)).found,
      "disabling maps also withdrew the entry")
app.webSourceMapsEnabled = true

# --- 8. the entry changes an existing server-rendered row -------------------
#
# The point of the whole phase: markup the server sent is enhanced in place,
# not replaced by a freshly rendered subtree.

let entryPath = workDir / entryRoute.fileName
writeFile(entryPath, entryRoute.body)
let domRunnerPath = workDir / "run_embed_dom.mjs"
writeFile(domRunnerPath, """
import { pathToFileURL } from "node:url";

// A server-rendered row, as the todo app sends it.
class FakeElement {
  constructor(tag) {
    this.tag = tag;
    this.listeners = new Map();
    this.textContent = "";
  }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
  removeEventListener(name) { this.listeners.delete(name); }
}
const root = new FakeElement("main");
const existingRow = new FakeElement("li");
existingRow.textContent = "rendered by the server";

const mod = await import(pathToFileURL(""" & $(%entryPath) & """).href);
mod.main(root);
const click = root.listeners.get("click");
if (typeof click !== "function") throw new Error("no delegated click listener");
click({ target: existingRow });
if (existingRow.textContent !== "1 item") {
  throw new Error(`server-rendered row unchanged: ${existingRow.textContent}`);
}

// A non-EventTarget mount must be refused by the checked entry, not silently
// accepted the way an `Any` parameter would.
let rejected = false;
try { mod.main({ notAnEventTarget: true }); } catch { rejected = true; }
if (!rejected) throw new Error("checked entry accepted a non-EventTarget mount");

console.log("embedded dom row change passed");
""")
let domRun = execCmdEx("node " & quoteShell(domRunnerPath))
if "embedded dom row change passed" notin domRun.output:
  stderr.write(domRun.output)
  fail("dom", "the embedded entry did not change an existing rendered row")

# --- 9. rejections land inside the embedded block ---------------------------

proc rejects(label, source, expected: string) =
  let dir = workDir / ("reject_" & label)
  removeDir(dir)
  let path = writeModule(dir, "app", source)
  let rejectApp = newApplication(dir)
  var message = ""
  try:
    discard rejectApp.loadFileModule(path)
  except CatchableError as error:
    message = error.msg
  if message.len == 0:
    fail("reject/" & label, "accepted a source that must be rejected")
  if expected notin message:
    fail("reject/" & label, "wrong diagnostic: " & message)
  # Every rejection must name a position *inside* the block, not merely the
  # declaration: "somewhere in this web_module" is not a usable diagnostic.
  # The position is in the file the author wrote, which is the whole point of
  # keeping the original SourceLocs rather than re-reading printed forms.
  var blockLine = 0
  let sourceLines = source.split('\n')
  for i in 0 ..< sourceLines.len:
    if sourceLines[i].startsWith("(web_module "):
      blockLine = i + 1
      break
  if blockLine == 0:
    fail("reject/" & label, "fixture has no web_module block")
  let anchor = path & ":"
  let at = message.find(anchor)
  if at < 0:
    fail("reject/" & label, "diagnostic names no source position: " & message)
  let tail = message[at + anchor.len .. ^1]
  var digits = ""
  for c in tail:
    if c.isDigit: digits.add c
    else: break
  if digits.len == 0:
    fail("reject/" & label, "diagnostic has no line number: " & message)
  if parseInt(digits) < blockLine:
    fail("reject/" & label,
         "diagnostic points outside the block (line " & digits & " < " &
         $blockLine & "): " & message)

# The scoping rule, which is what stops "one file" from meaning "captures the
# server": the block sees the web prelude and its own declarations, so a
# server-only binding in the enclosing module is simply not in scope.
rejects("capture", """
(mod embed_host)

(var connection "server-only")

(web_module widget
  (fn on_click [event : Any] : Void
    (var target event/target)
    (set! target/text_content connection)
    void)

  (fn main [root : EventTarget] : Void
    ($dom/add_event_listener root "click" on_click)))
""", "connection")

rejects("authored_import", """
(mod embed_host)

(web_module widget
  (import [helper] from "./helper.gene")

  (fn on_click [event : Any] : Void void)

  (fn main [root : EventTarget] : Void
    ($dom/add_event_listener root "click" on_click)))
""", "import is outside an embedded web module")

rejects("host_shim", """
(mod embed_host)

(web_module widget
  (js/fn shim [x : Str] : Str ^from "./shim.mjs")

  (fn on_click [event : Any] : Void void)

  (fn main [root : EventTarget] : Void
    ($dom/add_event_listener root "click" on_click)))
""", "js/fn is outside an embedded web module")

rejects("bad_entry", """
(mod embed_host)

(web_module widget
  (fn main [root : Str] : Void
    void))
""", "must take `EventTarget`")

rejects("no_entry", """
(mod embed_host)

(web_module widget
  (fn helper [] : Void
    void))
""", "has no entry")

# A missing mount is reported by the bootstrap the composition site generated,
# at the moment the page runs, because only the browser knows the document.
let mountRunnerPath = workDir / "run_missing_mount.mjs"
let mountModulePath = workDir / "mount.mjs"
writeFile(mountModulePath,
  webAssetMountModule(asset, "absent_root").body.replace(
    "./" & entryRoute.fileName, "./" & entryRoute.fileName))
writeFile(workDir / entryRoute.fileName, entryRoute.body)
writeFile(mountRunnerPath, """
import { pathToFileURL } from "node:url";
globalThis.document = { getElementById: () => null };
let message = "";
try {
  await import(pathToFileURL(""" & $(%mountModulePath) & """).href);
} catch (error) { message = String(error.message ?? error); }
if (!message.includes("absent_root")) {
  throw new Error(`missing mount was not reported: ${message}`);
}
console.log("missing mount reported");
""")
let mountRun = execCmdEx("node " & quoteShell(mountRunnerPath))
if "missing mount reported" notin mountRun.output:
  stderr.write(mountRun.output)
  fail("mount", "a missing mount element was not reported")

# --- 10. the AJAX path: prevent_default, request, repaint from the response --
#
# The interaction the todo app actually ships. Driven over a stub fetch so the
# assertions are about the *generated code* — that the default action is
# suppressed before the request goes out, that the success callback closes over
# the click site, and that a failed request repaints nothing.

const ajaxModule = """
(mod ajax_host)

(web_module widget
  (fn paint [row : Any, mark : Str] : Void
    (set! row/text_content mark)
    void)

  (fn on_click [event : Any] : Void
    (var target event/target)
    (var target_class : Str target/class_name)
    ($console/log $"click ${target_class}")
    (if_yes (== target_class "toggle")
      ($dom/prevent_default event)
      (var id : Str target/dataset/id)
      ($http/post_form "/api/toggle" $"id=${id}"
        (fn [body : Str] : Void
          ($console/log $"response for ${id}: ${body}")
          (paint target body)
          void)))
    void)

  (fn main [root : EventTarget] : Void
    ($dom/add_event_listener root "click" on_click)))
"""

let ajaxPath = writeModule(workDir / "ajax", "app", ajaxModule)
let ajaxApp = newApplication(workDir / "ajax")
let ajaxAsset = ajaxApp.assetOf(ajaxApp.loadFileModule(ajaxPath), "widget")
let ajaxEntry = webAssetRoutes(ajaxAsset)[0]
let ajaxEntryPath = workDir / ajaxEntry.fileName
writeFile(ajaxEntryPath, ajaxEntry.body)

# The callback closes over `id` from the click site. Without inline callbacks
# that is unwritable, so this doubles as the lambda-capture regression.
check("ajax", "=> {" in ajaxEntry.body,
      "no inline callback was emitted for the response handler")

let ajaxRunnerPath = workDir / "run_embed_ajax.mjs"
writeFile(ajaxRunnerPath, """
import { pathToFileURL } from "node:url";

class El {
  constructor(tag, className = "") {
    this.tag = tag; this.className = className; this.textContent = "";
    this.listeners = new Map(); this.dataset = {};
  }
  addEventListener(t, f) { this.listeners.set(t, f); }
  removeEventListener(t) { this.listeners.delete(t); }
}

let requests = [];
let mode = "ok";
globalThis.fetch = (url, init) => {
  requests.push({ url, method: init.method, body: init.body });
  if (mode === "http_error")
    return Promise.resolve({ ok: false, status: 500, statusText: "Server Error",
                             text: () => Promise.resolve("") });
  if (mode === "network") return Promise.reject(new Error("offline"));
  return Promise.resolve({ ok: true, status: 200, statusText: "OK",
                           text: () => Promise.resolve("done") });
};

const uncaught = [];
process.on("uncaughtException", (error) => uncaught.push(String(error.message)));

const root = new El("main");
const button = new El("button", "toggle");
button.dataset.id = "7";

const mod = await import(pathToFileURL(""" & $(%ajaxEntryPath) & """).href);
mod.main(root);
const click = root.listeners.get("click");

// 1. the default action is suppressed, and suppressed *before* the request:
//    after a navigation starts, nothing the handler does can still matter.
let prevented = false;
click({ target: button, preventDefault() { prevented = true; } });
if (!prevented) throw new Error("prevent_default was not called");
if (requests.length !== 1) throw new Error(`expected 1 request, got ${requests.length}`);
if (requests[0].method !== "POST") throw new Error("wrong method");
if (requests[0].url !== "/api/toggle") throw new Error(`wrong url: ${requests[0].url}`);
if (requests[0].body !== "id=7") throw new Error(`wrong body: ${requests[0].body}`);

await new Promise(r => setTimeout(r, 20));
if (button.textContent !== "done")
  throw new Error(`success callback did not repaint: ${button.textContent}`);

// 2. a click that is not on the toggle sends nothing at all.
click({ target: new El("span", "text"), preventDefault() {} });
if (requests.length !== 1) throw new Error("an unrelated click issued a request");

// 3. a non-2xx must not run the success path, and must not vanish.
mode = "http_error";
button.textContent = "before";
click({ target: button, preventDefault() {} });
await new Promise(r => setTimeout(r, 20));
if (button.textContent !== "before")
  throw new Error("an HTTP error still repainted the row");
if (!uncaught.some(m => m.includes("500")))
  throw new Error(`HTTP error was swallowed: ${JSON.stringify(uncaught)}`);

// 4. same for a transport failure.
mode = "network";
click({ target: button, preventDefault() {} });
await new Promise(r => setTimeout(r, 20));
if (button.textContent !== "before")
  throw new Error("a network failure still repainted the row");
if (!uncaught.some(m => m.includes("offline")))
  throw new Error(`network failure was swallowed: ${JSON.stringify(uncaught)}`);

console.log("embedded ajax handler passed");
""")
let ajaxRun = execCmdEx("node " & quoteShell(ajaxRunnerPath))
if "embedded ajax handler passed" notin ajaxRun.output:
  stderr.write(ajaxRun.output)
  fail("ajax", "the AJAX toggle path did not behave as specified")

# --- 11. `$` matches the VM for every scalar it displays --------------------
#
# `$"n=${count}"` compiling on the server and failing in the browser is the
# silent-divergence class §5 exists to prevent, so the conformance claim is
# tested rather than asserted.

const displayModule = """
(mod display_host)

(web_module widget
  (fn render [] : Str
    (var s "x")
    $"i=${42} f=${1.5} b=${true} s=${s} n=${nil}")

  (fn main [root : EventTarget] : Void
    (set! root/text_content (render))
    void))
"""

let displayPath = writeModule(workDir / "display", "app", displayModule)
let displayApp = newApplication(workDir / "display")
let displayAsset = displayApp.assetOf(
  displayApp.loadFileModule(displayPath), "widget")
let displayEntryPath = workDir / "display_entry.mjs"
writeFile(displayEntryPath, webAssetRoutes(displayAsset)[0].body)
let displayRunnerPath = workDir / "run_embed_display.mjs"
writeFile(displayRunnerPath, """
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(""" & $(%displayEntryPath) & """).href);
const actual = mod.render();
const expected = "i=42 f=1.5 b=true s=x n=nil";
if (actual !== expected)
  throw new Error(`web display diverges from the VM: ${actual} !== ${expected}`);
console.log("embedded display concat passed");
""")
let displayRun = execCmdEx("node " & quoteShell(displayRunnerPath))
if "embedded display concat passed" notin displayRun.output:
  stderr.write(displayRun.output)
  fail("display", "web `$` does not display scalars the way the VM does")

echo "embedded web module lifecycle passed"
