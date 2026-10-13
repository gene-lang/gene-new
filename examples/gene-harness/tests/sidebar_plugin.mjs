// Exercise the compiled Gene sidebar with browser-owned DOM controls.
// node tests/sidebar_plugin.mjs /path/to/web-build/sidebar.mjs
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

class Element extends EventTarget {
  constructor(tag = "div", text = "") {
    super(); this.tag = tag; this.text = text; this.children = [];
    this.attributes = {}; this.hidden = false; this.value = "";
    this.classes = new Set();
    this.classList = {toggle: (name, enabled) => enabled ? this.classes.add(name) : this.classes.delete(name)};
  }
  get firstChild() { return this.children[0] ?? null; }
  get textContent() { return this.text + this.children.map(child => child.textContent).join(""); }
  set textContent(value) { this.text = value; this.replaceChildren(); }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    this.children.push(child); child.parentNode = this; return child;
  }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
  replaceChildren(...children) {
    for (const child of this.children) child.parentNode = null;
    this.children = []; children.forEach(child => this.appendChild(child));
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  focus() { document.activeElement = this; }
}
let elements = new Map();
const element = id => {
  if (!elements.has(id)) elements.set(id, new Element());
  return elements.get(id);
};
Object.assign(globalThis, {
  HTMLElement: Element,
  document: {
    activeElement: null,
    getElementById: element,
    createElement: tag => new Element(tag),
    createTextNode: text => new Element("#text", text),
    createDocumentFragment: () => new Element("#fragment"),
  },
  window: Object.assign(new EventTarget(), {innerWidth: 1200}),
  sessionStorage: {getItem: () => null, setItem() {}},
});
const sidebar = await import(pathToFileURL(process.argv[2]).href);
const names = ["brand", "new_conversation", "filters", "attention", "extensions", "conversations", "workspace_tools"];
const ids = ["sidebar_brand", "create_session", "sidebar_filters", "attention_section", "web_sidebar", "sessions", "sidebar_tools"];
function fixture(safe = false) {
  elements = new Map(); document.activeElement = null;
  const pool = element("sidebar_storage"); pool.hidden = true;
  ids.forEach(id => pool.appendChild(element(id)));
  element("sidebar_filters").appendChild(element("session_filter"));
  return sidebar.create_sidebar(element("harness_root"), safe);
}
const node = (tag, props = {}, children = []) => ({tag, props, children});
const layout = (widgets, extra = []) => ({
  name: "conversation_sidebar", slot: "conversation_sidebar",
  view: node("div", {class: "sidebar_content"}, [
    ...widgets.map(name => node("host_widget", {name})), ...extra,
  ]),
});
const commands = [];
const update = (state, components, enabled = true) => sidebar.update_sidebar(state, components,
  text => { commands.push(text); }, () => {}, () => {}, enabled);

const state = fixture();
assert.equal(element("menu").hidden, true, "no sidebar is mounted before composition arrives");
const defaultLayout = layout(names, [node("button", {command: "/help"}, ["Help"])]);
update(state, [defaultLayout]);
assert.equal(element("menu").hidden, false);
assert.equal(element("classic_sidebar").hidden, false);
const mounted = element("sidebar_view").firstChild;
const search = element("session_filter");
search.value = "unfinished filter"; search.focus();
let creates = 0;
element("create_session").addEventListener("click", () => creates++);
const help = mounted.children.at(-1);
help.dispatchEvent(new Event("click"));
assert.deepEqual(commands, ["/help"]);

update(state, [defaultLayout], false);
assert.equal(element("sidebar_view").firstChild, mounted, "unchanged status must retain its DOM");
assert.equal(document.activeElement, search);
assert.equal(help.disabled, true, "custom commands track connection availability");

update(state, [layout(["conversations", "new_conversation"])]);
assert.equal(element("sidebar_filters").parentNode, element("sidebar_storage"));
assert.equal(search.value, "unfinished filter");
element("create_session").dispatchEvent(new Event("click"));
assert.equal(creates, 1, "moving a host widget must retain its one handler");
update(state, [defaultLayout]);
assert.equal(element("session_filter"), search);
assert.equal(search.value, "unfinished filter");

update(state, []);
assert.equal(element("classic_sidebar").hidden, true);
assert.equal(element("menu").hidden, true);
assert.equal(element("sessions").parentNode, element("sidebar_storage"));
update(state, [defaultLayout]);
assert.equal(element("classic_sidebar").hidden, false);
sidebar.sidebar_layout(state, true);
assert.equal(element("classic_sidebar").hidden, true);
sidebar.sidebar_layout(state, false);
assert.equal(element("classic_sidebar").hidden, false);

update(state, [{name: "conversation_sidebar", slot: "conversation_sidebar", error: "invalid widget"}]);
assert.match(element("sidebar_view").textContent, /Recovery UI/);
assert.equal(element("menu").hidden, false);

const recovery = fixture(true);
const recoveryList = element("sessions");
assert.equal(recoveryList.parentNode, element("sidebar_view"));
update(recovery, [layout([], [node("p", {}, ["untrusted replacement"])])]);
assert.equal(recoveryList.parentNode, element("sidebar_view"));
assert.doesNotMatch(element("sidebar_view").textContent, /untrusted replacement/);
assert.equal(element("menu").hidden, false);
console.log("sidebar plugin: composition, live replacement, retained controls, withdrawal, errors and recovery passed");
