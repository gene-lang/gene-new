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
