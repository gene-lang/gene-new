## Browser-edge smoke test for the generated node -> DOM lowering.

import gene/web
import std/[json, os, osproc, strutils]

let workDir = getTempDir() / "gene-transpile-dom"
let outDir = workDir / "out"
createDir(workDir)
createDir(outDir)
discard buildWebModule(getCurrentDir() / "examples" / "web_component.gene", outDir)

let modulePath = outDir / "web_component.mjs"
let runnerPath = workDir / "run_dom.mjs"
writeFile(runnerPath, """
class FakeText {
  constructor(text) { this.text = text; }
}
class FakeElement {
  constructor(tag) {
    this.tag = tag;
    this.attributes = new Map();
    this.children = [];
    this.listeners = new Map();
    this.textContent = "";
  }
  append(child) { this.children.push(child); }
  setAttribute(name, value) { this.attributes.set(name, value); }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
}
globalThis.document = {
  createTextNode: text => new FakeText(text),
  createDocumentFragment: () => new FakeElement("#fragment"),
  createElement: tag => new FakeElement(tag),
};
const mod = await import(""" & $(%modulePath) & """ + "?dom-smoke");
const button = mod.view();
if (button.tag !== "button") throw new Error(`wrong tag: ${button.tag}`);
if (button.attributes.get("class") !== "gene-button") throw new Error("class mapping failed");
const click = button.listeners.get("click");
if (typeof click !== "function") throw new Error("Gene click handler was not attached");
click({currentTarget: button});
if (button.textContent !== "Handled by Gene") throw new Error("Gene handler did not mutate the DOM target");
console.log("transpile DOM component passed");
""")
let executed = execCmdEx("node " & quoteShell(runnerPath))
if executed.exitCode != 0:
  stderr.write(executed.output)
  quit(1)
if "transpile DOM component passed" notin executed.output:
  stderr.write(executed.output)
  quit(1)
echo executed.output.strip()

# `ws/connect_protocol` offers one subprotocol: the constructor must receive it
# (the server's `ws_accept ^protocol` selects it) and, like `ws/connect`, the
# socket must be switched to `arraybuffer` before any frame can arrive.
let wsSource = workDir / "ws_protocol_probe.gene"
writeFile(wsSource, """
(mod ws_protocol_probe ^profile web)
(fn open_socket [url : Str] : EventTarget
  ($ws/connect_protocol url "gene.world.v1"))
""")
discard buildWebModule(wsSource, outDir)
let wsRunner = workDir / "run_ws.mjs"
writeFile(wsRunner, """
const made = [];
globalThis.WebSocket = class extends EventTarget {
  constructor(url, protocol) { super(); this.url = url; this.protocol = protocol; this.binaryType = "blob"; made.push(this); }
};
const mod = await import(""" & $(%(outDir / "ws_protocol_probe.mjs")) & """ + "?ws");
const socket = mod.open_socket("ws://127.0.0.1:8096/world/v1");
if (made.length !== 1 || socket !== made[0]) throw new Error("no socket constructed");
if (socket.url !== "ws://127.0.0.1:8096/world/v1") throw new Error(`wrong url: ${socket.url}`);
if (socket.protocol !== "gene.world.v1") throw new Error(`wrong protocol: ${socket.protocol}`);
if (socket.binaryType !== "arraybuffer") throw new Error("binaryType not set");
console.log("transpile ws/connect_protocol passed");
""")
let wsExecuted = execCmdEx("node " & quoteShell(wsRunner))
if wsExecuted.exitCode != 0 or "transpile ws/connect_protocol passed" notin wsExecuted.output:
  stderr.write(wsExecuted.output)
  quit(1)
echo wsExecuted.output.strip()
