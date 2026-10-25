// Execute the compiled Gene history header and turn view with isolated browser edges.
// Run after the development web build:
// node tests/history_start.mjs /path/to/web-build/view.mjs
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

class Element extends EventTarget {
  constructor(tag) { super(); this.tag = tag; this.children = []; this.attributes = {}; this.textContent = ""; }
  append(...children) { for (const child of children) this.appendChild(child); }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  setAttribute(name, value) { this.attributes[name] = value; }
}
Object.assign(globalThis, {
  HTMLElement: Element,
  document: {
    createElement: tag => new Element(tag),
    createTextNode: text => Object.assign(new Element("#text"), {textContent: text}),
    createDocumentFragment: () => new Element("#fragment"),
  },
});
const viewURL = pathToFileURL(process.argv[2]);
const view = await import(viewURL.href);
const state = await import(new URL("./state.mjs", viewURL).href);
const text = element => element.textContent + element.children.map(text).join("");
const descendants = element => [element, ...element.children.flatMap(descendants)];
const prompt = "Initial paragraph.\n\nFull prompt 世界 <script>not HTML</script>";
const session = {title: "Renamed conversation", first_request: prompt, first_request_round: "round-a-1", first_request_speaker: "User"};
const real = {
  id: "session/1", role: "user", phase: "turn/request", round_id: "round-a-1",
  turn: 0n, text: prompt, media: [], durable: true,
};
const later = {...real, id: "session/200", round_id: "round-a-2"};
let loaded = 0;
const header = (metadata, records = [], preview = [], older = true, loading = false) => {
  const target = new Element("section");
  view.append_history_start(target, metadata, records, preview, older, loading, () => {}, () => {loaded++;});
  return target;
};

// The original, not the renameable title, leads the paging gap.
let target = header(session, [later]);
assert.deepEqual(target.children.map(child => child.tag), ["article", "button"]);
assert.equal(target.children[0].attributes.class, "message user");
assert.equal(text(target.children[0]), "User" + prompt);
assert.equal(text(target.children[1]), "Load earlier messages");
assert.equal(descendants(target).some(element => element.tag === "script"), false);
target.children[1].dispatchEvent(new Event("click"));
assert.equal(loaded, 1);

// Paging in the real request removes the fallback; the normal request stays.
target = header(session, [real, later], [], false);
assert.equal(target.children.length, 0);
target.appendChild(view.block_view(real, false, () => {}, false, () => {}));
target.appendChild(view.block_view(later, false, () => {}, false, () => {}));
assert.equal(target.children.filter(child => child.tag === "article").length, 2);
assert.equal(text(target), "User" + prompt + "User" + prompt);
assert.equal(header(session, [], [real]).children.length, 1, "a first-request preview must also suppress the fallback");
assert.equal(header(session, [], [], true, true).children[1].attributes.disabled, "");
assert.equal(header(session, [], [], true, true).children[1].textContent + text(header(session, [], [], true, true).children[1]), "Loading…");

// New conversations have no fabricated prompt; titles are never a source.
assert.equal(header({title: "Do not display as a prompt"}, [], [], false).children.length, 0);
assert.equal(text(header({...session, title: "Renamed again"}, [], [], false)), "User" + prompt);
assert.equal(text(header({title: "beat · time", first_request: "Full trigger\nrequest", first_request_round: "trigger-1"}, [], [], false)), "RequestFull trigger\nrequest");

// Attachment-only submissions retain the ordinary attachment gallery.
const attachment = {id: "image-id", name: "pixel.png", kind: "image"};
target = header({...session, first_request: "Attachment: pixel.png", first_request_media: [attachment]});
assert.equal(target.children[0].tag, "article");
const image = descendants(target).find(element => element.tag === "img");
assert.ok(image, "attachment-only first prompt lost its image");
assert.equal(image.attributes.alt, "pixel.png");
assert.equal(image.attributes.src, "/api/v8/media/image-id");
console.log("history start: saved full text, prompt styling, gap ordering, safe text, rename, identity deduplication, preview, trigger and attachment gallery passed");

// Intermediate replies appear once in the heading, never in expanded turn content.
const code = {id: "code-1", role: "agent", phase: "code", round_id: "round-a-1", turn: 1n,
  text: "(+ 1 2)", durable: true};
const next = {...code, id: "next-1", phase: "turn/request", text: "Continue with the result."};
const progress = {...code, id: "reply-1", phase: "reply", text: "I checked the result.", final: false};
for (const durable of [true, false]) {
  const step = view.step_view([code, next, {...progress, durable}], true, !durable,
    () => {}, () => false, () => {});
  assert.equal(step.attributes.open, "");
  assert.equal(text(step.children[0]), "Turn 1: I checked the result." + (durable ? "" : " · Evaluating code…"));
  const content = step.children[1];
  assert.equal(content.attributes.class, "step_content");
  assert.equal(content.children.length, 2, "expanded turn should contain code and next request only");
  assert.ok(text(content).includes(code.text));
  assert.ok(text(content).includes(next.text));
  assert.equal(text(content).includes(progress.text), false, "progress reply repeated inside the turn");
  assert.equal(text(step).split(progress.text).length - 1, 1);
}

// Final replies have a separate block group; their turn still owns the summary.
const final = {...progress, id: "final-1", text: "Finished successfully.", final: true};
const groups = state.conversation_groups([code, progress, final]);
assert.deepEqual(groups.map(group => group.kind), ["turn", "block"]);
assert.ok(groups[0].blocks.includes(progress));
assert.equal(groups[1].block, final);
target = new Element("section");
target.appendChild(view.step_view(groups[0].blocks, true, false, () => {}, () => false, () => {}));
target.appendChild(view.block_view(groups[1].block, false, () => {}, false, () => {}));
assert.equal(target.children[1].tag, "article");
assert.equal(text(target.children[1]).split(final.text).length - 1, 1);
assert.equal(text(target.children[0].children[1]).includes(final.text), false);
console.log("turn replies: durable and preview progress only in headings; code, next requests and final replies preserved");
