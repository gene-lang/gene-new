// Execute the compiled Gene component, with browser edges replaced by fixtures.
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { webcrypto } from "node:crypto";

class Element extends EventTarget {
  constructor(tag) { super(); this.tag = tag; this.children = []; this.attributes = {}; this.textContent = ""; }
  append(...children) { for (const child of children) this.appendChild(child); }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  replaceChildren(...children) { this.children = []; this.append(...children); }
  setAttribute(name, value) { this.attributes[name] = value; }
}
class HTMLInputElement extends Element {
  constructor() { super("input"); this.type = "file"; this.files = []; this.value = ""; }
}
class File extends Blob { constructor(parts, name, options = {}) { super(parts, options); this.name = name; } }
class FileReader extends EventTarget {
  readyState = 0;
  readAsDataURL(file) {
    this.readyState = 1;
    queueMicrotask(async () => {
      if (file.pause) await file.pause;
      const bytes = Buffer.from(await file.arrayBuffer());
      if (this.readyState !== 1) return;
      this.result = `data:${file.type || "application/octet-stream"};base64,${bytes.toString("base64")}`;
      this.readyState = 2;
      this.onload?.({target: this});
    });
  }
  abort() { if (this.readyState === 1) { this.readyState = 2; this.onabort?.({target: this}); } }
}
const storage = new Map();
const elements = new Map();
function freshDOM() {
  elements.clear();
  for (const id of ["media_drafts", "media_status", "composer", "prompt"]) elements.set(id, new Element("div"));
  elements.set("media_files", new HTMLInputElement());
}
Object.assign(globalThis, {
  File, FileReader, HTMLInputElement, HTMLElement: Element,
  document: {
    getElementById: id => elements.get(id),
    createElement: tag => new Element(tag),
    createTextNode: text => Object.assign(new Element("#text"), {textContent: text}),
    createDocumentFragment: () => new Element("#fragment"),
  },
  sessionStorage: {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value),
    removeItem: key => storage.delete(key),
  },
});
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const media = await import(pathToFileURL(process.argv[2]).href);
let sequence = 0;
const posts = [];
const post = (name, data, done) => {
  posts.push({name, data});
  queueMicrotask(() => {
    if (name === "reject.txt") { done(400n, {message: "Rejected by fixture"}); return; }
    const id = (++sequence).toString(16).padStart(32, "0");
    done(201n, {id, name, kind: name.endsWith(".png") ? "image" : "text", mime: "text/plain", size: 4n, url: `/api/v8/media/${id}`});
  });
};
async function settled(composer) {
  for (let i = 0; i < 50 && composer.working; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(composer.working, false, "upload queue did not finish");
}
function create(session = "") {
  freshDOM();
  const composer = media.create_media(session, post, () => {});
  media.media_controls(composer, true);
  return composer;
}
function eventFiles(target, name, field, files) {
  const event = new Event(name, {cancelable: true});
  Object.defineProperty(event, field, {value: {files}});
  target.dispatchEvent(event);
  return event;
}

let composer = create();
const first = new File([new Uint8Array([255, 0, 128, 42])], "binary.png", {type: "image/png"});
const second = new File(["notes"], "notes.txt", {type: "text/plain"});
elements.get("media_files").files = [first, second];
elements.get("media_files").dispatchEvent(new Event("change"));
assert.equal(media.media_blocked(composer), true);
await settled(composer);
assert.equal(media.media_ids(composer).length, 2);
assert.equal(posts[0].data, "/wCAKg==");
assert.deepEqual(posts.slice(0, 2).map(p => p.name), ["binary.png", "notes.txt"]);
assert.equal(elements.get("media_files").value, "");
const saved = JSON.parse(storage.get("gene-harness/media-draft/new"));
assert.equal(saved.length, 2);
assert.equal("file" in saved[0], false);
assert.equal("data" in saved[0], false);
media.media_move(composer, "", "session-a");
media.media_select(composer, "session-a");
const ids = media.media_ids(composer);
media.media_select(composer, "session-b");
assert.equal(media.media_has(composer), false);
media.media_select(composer, "session-a");
assert.deepEqual(media.media_ids(composer), ids);
composer = create("session-a");
assert.deepEqual(media.media_ids(composer), ids, "ready drafts survive reload");
media.media_admitted(composer, "session-a", [ids[0]]);
assert.deepEqual(media.media_ids(composer), [ids[1]], "admission clears only submitted attachments");
media.remove_media(composer, media.items_for(composer, "session-a")[0].key);
assert.equal(media.media_has(composer), false);

const drop = eventFiles(elements.get("composer"), "drop", "dataTransfer", [second]);
assert.equal(drop.defaultPrevented, true);
await settled(composer);
const paste = eventFiles(elements.get("prompt"), "paste", "clipboardData", [first]);
assert.equal(paste.defaultPrevented, true);
await settled(composer);
assert.equal(media.media_ids(composer).length, 2);
const textPaste = eventFiles(elements.get("prompt"), "paste", "clipboardData", []);
assert.equal(textPaste.defaultPrevented, false, "ordinary text paste remains intact");

composer = create("errors");
media.add_files(composer, [new File(["x"], "reject.txt")]);
await settled(composer);
assert.equal(media.media_blocked(composer), true);
assert.equal(media.items_for(composer, "errors")[0].error, "Rejected by fixture");
media.remove_media(composer, media.items_for(composer, "errors")[0].key);
const oversized = new File([], "large.png");
Object.defineProperty(oversized, "size", {value: 10485761});
const before = posts.length;
media.add_files(composer, [oversized]);
assert.equal(media.media_blocked(composer), true);
assert.equal(posts.length, before, "oversized files never reach the server");
media.remove_media(composer, media.items_for(composer, "errors")[0].key);

let release;
const slow = new File(["slow"], "cancel.txt"); slow.pause = new Promise(resolve => {release = resolve;});
media.add_files(composer, [slow]);
const key = media.items_for(composer, "errors")[0].key;
media.remove_media(composer, key);
release(); await settled(composer);
assert.equal(posts.length, before, "removed in-flight reads must not upload");
assert.equal(media.media_has(composer), false);

composer = create("move-source");
let resume;
const moving = new File(["move"], "move.txt"); moving.pause = new Promise(resolve => {resume = resolve;});
media.add_files(composer, [moving]);
media.media_move(composer, "move-source", "move-target");
media.media_select(composer, "move-target");
resume(); await settled(composer);
assert.equal(media.media_ids(composer).length, 1);
assert.equal(JSON.parse(storage.get("gene-harness/media-draft/move-source")).length, 0);
assert.equal(JSON.parse(storage.get("gene-harness/media-draft/move-target"))[0].state, "ready");
console.log("media composer: picker/drop/paste, ordered uploads, drafts, removal, limits, errors, cancellation and session transfer passed");
