// Exercise the compiled conversation client with delayed browser responses.
// node tests/first_submission.mjs /path/to/web-build/main.mjs
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { webcrypto } from "node:crypto";

class Element extends EventTarget {
  constructor(tag = "div", text = "") {
    super(); this.tag = tag; this.text = text; this.children = []; this.attributes = {};
    this.value = ""; this.scrollTop = 0; this.scrollHeight = 100; this.clientHeight = 100;
    this.classList = {toggle() {}};
    this.style = {setProperty() {}};
  }
  get firstChild() { return this.children[0] ?? null; }
  get childNodes() { return this.children; }
  get textContent() { return this.text + this.children.map(child => child.textContent).join(""); }
  set textContent(text) { this.text = text; this.children = []; }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  replaceChildren(...children) { this.children = []; this.text = ""; this.append(...children); }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
  setAttribute(name, value) { this.attributes[name] = value; }
  focus() {}
}
const elements = new Map();
const stored = new Map();
const requests = [];
const element = id => {
  if (!elements.has(id)) elements.set(id, new Element());
  return elements.get(id);
};
Object.assign(globalThis, {
  HTMLElement: Element,
  document: {
    getElementById: element,
    createElement: tag => new Element(tag),
    createTextNode: text => new Element("#text", text),
    createDocumentFragment: () => new Element("#fragment"),
  },
  sessionStorage: {
    getItem: key => stored.get(key) ?? null,
    setItem: (key, value) => stored.set(key, value),
    removeItem: key => stored.delete(key),
  },
  fetch: (path, options) => new Promise(resolve => requests.push({
    path, options, reply: (status, data) => resolve({status, text: async () => JSON.stringify(data)}),
  })),
  window: Object.assign(new EventTarget(), {location: {origin: "http://fixture", search: "", hash: ""}, history: {replaceState() {}}}),
  WebSocket: class extends EventTarget { constructor(url) { super(); this.url = url; } close() {} },
  // The fixture advances responses explicitly; browser reconnect timers stay idle.
  setTimeout: () => 0,
});
if (!globalThis.crypto) globalThis.crypto = webcrypto;
globalThis.history = window.history;
const mainURL = pathToFileURL(process.argv[2]);
const harness = await import(mainURL.href);
const {create_media} = await import(new URL("media.mjs", mainURL));
const {media_ids} = await import(new URL("media.mjs", mainURL));
const {create_commands} = await import(new URL("command_client.mjs", mainURL));
const {create_notices} = await import(new URL("notices.mjs", mainURL));
const {create: create_ui} = await import(new URL("controller.mjs", mainURL));
const noop = () => {};
function client() {
  elements.clear(); stored.clear(); requests.length = 0;
  return new harness.Client({
    selected: "s", csrf: "csrf", cursor: "", next_seq: "1", epoch: "process",
    ready: true, connected: true, server_busy: false, awaiting: "", awaiting_session: "",
    queued_prompt: "", queued_submit: false, message_sequence: 0n, sending: false,
    busy: false, autoscroll: true, has_older: false, loading_older: false, socket_epoch: 0n,
    viewing_history: false, generation: 1n, records: [], preview: [], sessions: [],
    needs_attention: [], filter_epoch: 0n, trigger_selected: "", tabs: [], expanded: [],
    rounds: [], input_id: "", answering: false, round: null, mode: null, mode_pending: null,
    action_cooldown: false, was_executing: false, pending: null, status: null,
    status_epoch: "", status_revision: "", status_generation: 0n, components: [],
    component_buttons: {}, socket: null, session_revision: "0", ui: null,
    media: create_media("s", noop, noop), notices: create_notices(), confirmations: null,
    questions: null, center: null, inbox: null, safe_ui: false, root: element("root"),
    list: element("sessions"), transcript: element("transcript"), prompt: element("prompt"),
    notice: element("notice"), title: element("conversation_title"),
    appearance: "light", style_signature: "", cards: null, browser_clients: null, command_client: null,
  });
}
const descendants = node => [node, ...node.children.flatMap(descendants)];
const bubbles = c => descendants(c.transcript).filter(node => node.tag === "article" && node.attributes.class?.includes("user"));
function promptVisible(c, prompt) {
  assert.equal(bubbles(c).length, 1, "prompt must be displayed exactly once");
  assert.equal(bubbles(c)[0].textContent, "You" + prompt);
  assert.equal(c.transcript.textContent.includes("What would you like to work on?"), false);
}
const snapshot = (round = null, records = []) => ({
  session: {id: "s", title: "New conversation", revision: "0", first_request: ""},
  records, preview: [], has_older: false, rounds: round ? [round] : [], round,
  cursor: "0", next_submission_seq: round ? "2" : "1", mode: null,
});
const admitted = c => ({id: "round-s-1", request_id: c.pending.request_id,
  submission_seq: 1n, state: "running", initiator: "user", prompt: c.pending.text});
const real = round => ({id: "s/3", seq: "3", round_id: round.id, turn: 0n,
  role: "user", phase: "turn/request", text: round.prompt, durable: true, media: []});
const settled = () => new Promise(resolve => setImmediate(resolve));

// The first prompt is visible immediately, survives an empty initial snapshot,
// and is replaced by the real record when it arrives after POST admission.
let c = client();
const prompt = "First paragraph.\n\nFull prompt 世界 <script>plain text</script>";
c.prompt.value = prompt;
harness.render_transcript(c);
assert.ok(c.transcript.textContent.includes("What would you like to work on?"));
harness.stage_submission(c, prompt);
promptVisible(c, prompt);
const round = admitted(c);
harness.apply_snapshot(c, snapshot());
promptVisible(c, prompt);
requests[0].reply(202, {...round, submission_seq: 1});
await settled();
assert.equal(c.pending, null);
assert.equal(c.prompt.value, "");
promptVisible(c, prompt);
harness.apply_snapshot(c, snapshot());
promptVisible(c, prompt);
harness.apply_record(c, real(round));
promptVisible(c, prompt);
harness.apply_snapshot(c, snapshot(round, [real(round)]));
promptVisible(c, prompt);
assert.equal(descendants(c.transcript).some(node => node.tag === "script"), false);
assert.equal(c.records.length, 1, "display fallback must not enter durable history");

// A live completion can precede POST admission; a late accepted response must
// neither regress its state nor duplicate its user bubble.
c = client(); c.prompt.value = "Quick request";
harness.stage_submission(c, c.prompt.value);
const fast = {...admitted(c), state: "done", reply: "Done"};
harness.apply_run(c, "s", fast);
harness.apply_record(c, real(fast));
requests[0].reply(202, {...fast, state: "running", submission_seq: 1});
await settled();
assert.equal(c.round.state, "done");
promptVisible(c, "Quick request");

// A definite rejection removes only the unadmitted bubble and preserves the
// composer draft. An uncertain response retains the recoverable submission.
c = client(); c.prompt.value = "Rejected request";
harness.stage_submission(c, c.prompt.value);
requests[0].reply(400, {code: "invalid_input", message: "Rejected"});
await settled();
assert.equal(c.pending, null);
assert.equal(c.prompt.value, "Rejected request");
assert.equal(bubbles(c).length, 0);
c = client(); c.prompt.value = "Uncertain request";
harness.stage_submission(c, c.prompt.value);
requests[0].reply(503, {code: "temporarily_unavailable", message: "Try again"});
await settled();
assert.ok(c.pending);
assert.ok(stored.has("gene-harness/pending"));
promptVisible(c, "Uncertain request");

// Entering a prompt before any session exists stages it immediately after
// creation, even while the new session's socket is still connecting.
c = client(); c.selected = "";
c.ui = create_ui(element("ui_root"), true, c.notices, noop, noop, noop, noop, "light");
c.prompt.value = "Start a new project";
harness.send(c);
assert.equal(requests[0].path, "/api/v8/sessions");
requests[0].reply(201, {id: "new-session"});
await settled();
assert.equal(c.selected, "new-session");
assert.equal(c.connected, false);
assert.equal(c.pending.text, "Start a new project");
promptVisible(c, "Start a new project");
assert.equal(requests.some(request => request.path.endsWith("/rounds")), false,
  "submission waits for the session stream to connect");

// Equal prompt text in an older round cannot suppress the new submission.
c = client();
const old = {id: "round-s-1", request_id: "old", submission_seq: 1n,
  state: "done", initiator: "user", prompt: "Same prompt"};
c.round = old; c.rounds = [old]; c.records = [real(old)]; c.next_seq = "2";
c.prompt.value = "Same prompt";
harness.stage_submission(c, c.prompt.value);
assert.equal(bubbles(c).length, 2);
const newer = {...admitted(c), id: "round-s-2", submission_seq: 2n};
requests[0].reply(202, {...newer, submission_seq: 2});
await settled();
assert.equal(bubbles(c).length, 2);
harness.apply_record(c, {...real(newer), id: "s/10", seq: "10"});
assert.equal(bubbles(c).length, 2);

// Attachment-only admission retains its media gallery after the composer
// draft is cleared, even if the first transcript record is still delayed.
c = client();
const asset = {id: "image-id", kind: "image", name: "pixel.png"};
c.media.drafts.s = [{key: "upload", state: "ready", name: asset.name, asset}];
harness.stage_submission(c, "");
promptVisible(c, "Attachments");
const attached = {...admitted(c), media: [asset]};
requests[0].reply(202, {...attached, submission_seq: 1});
await settled();
promptVisible(c, "Attachment: pixel.pngpixel.png");
assert.ok(descendants(c.transcript).some(node => node.tag === "img" && node.attributes.alt === "pixel.png"));

// Saved first-prompt metadata can precede every transcript record. It must
// replace welcome content even without a currently loaded round.
c = client();
harness.apply_snapshot(c, {...snapshot(), session: {
  id: "s", title: "Renamed", revision: "1", first_request: prompt, first_request_round: "round-s-1",
}});
promptVisible(c, prompt);

// Spotlight commands use the shared dispatcher without consuming text or
// attachment drafts, unlike sending a model round.
c = client();
c.prompt.value = "Keep this draft";
c.media.drafts.s = [{key:"attachment-draft",state:"ready",name:"pixel.png",asset}];
c.command_client = create_commands((method,path,payload,done) => harness.api(c,method,path,payload,done),noop);
let commandOutcome;
harness.launcher_command(c,"s","/help",{name:"help",owner:"core_commands",revision:"displayed"},
  (code,data)=>{commandOutcome=code;});
assert.match(requests[0].path,/sessions\/s\/snapshot$/);
requests[0].reply(200,{next_command_seq:"1"});
await settled();
assert.match(requests[1].path,/sessions\/s\/commands$/);
assert.equal(JSON.parse(requests[1].options.body).expected_command.revision,"displayed");
requests[1].reply(202,{id:"c1",status:"running"});
await settled();
assert.equal(commandOutcome,202n);
assert.equal(c.prompt.value,"Keep this draft");
assert.deepEqual(media_ids(c.media),[asset.id]);
assert.equal(c.sending,false);
console.log("first submission: immediate prompt, delayed snapshots/admission, durable replacement, late completion, rejection/uncertainty, session creation, equal prompts, attachments, and saved prompt passed");
