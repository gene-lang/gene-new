// Deterministic DOM/API acceptance of the compiled plugin and durable host client.
import assert from "node:assert/strict";
import {pathToFileURL} from "node:url";
import {webcrypto} from "node:crypto";
class Element extends EventTarget {
  constructor(tag = "div", text = "") {
    super(); this.tag = tag; this.text = text; this.children = []; this.attributes = {};
    this.value = ""; this.disabled = false; this.hidden = false;
    this.classList = {toggle() {}}; this.style = {setProperty() {}};
  }
  get firstChild() { return this.children[0] ?? null; }
  get childNodes() { return this.children; }
  get textContent() { return this.text + this.children.map(x => x.textContent).join(""); }
  set textContent(value) { this.text = value; this.children = []; }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  replaceChildren(...children) { this.children = []; this.text = ''; this.append(...children); }
  setAttribute(name, value) {
    this.attributes[name] = value;
    if (name === "checked") this.checked = true;
    if (name === "hidden") this.hidden = true;
  }
  removeAttribute(name) { delete this.attributes[name]; }
  focus() { document.activeElement = this; }
}
const stored = new Map(), timers = [], recognizers = [], spoken = [];
let now = 0, cancelled = 0;
const windowTarget = Object.assign(new EventTarget(), {location: {origin: "http://fixture"}});
Object.assign(globalThis, {
  HTMLElement: Element,
  document: {
    createElement: tag => new Element(tag),
    createTextNode: text => new Element("#text", text),
    createDocumentFragment: () => new Element("#fragment"),
    activeElement: null,
  },
  window: windowTarget,
  setTimeout: (callback, ms) => { timers.push({callback, ms}); return timers.length; },
  sessionStorage: {
    getItem: key => stored.get(key) ?? null,
    setItem: (key, value) => { stored.set(key, value); },
    removeItem: key => { stored.delete(key); },
  },
  AudioContext: class extends EventTarget {
    currentTime = 0; destination = {};
    async resume() { this.resumed = true; }
    async close() { this.closed = true; }
    createOscillator() { return {frequency: {}, connect() {}, start() {}, stop() {}}; }
    createGain() { return {gain: {setValueAtTime() {}, exponentialRampToValueAtTime() {}}, connect() {}}; }
  },
  SpeechRecognition: class {
    constructor() { recognizers.push(this); }
    start() { this.started = true; }
    stop() { this.stopped = true; }
    abort() { this.aborted = true; }
  },
  SpeechSynthesisUtterance: class { constructor(text) { this.text = text; } },
  speechSynthesis: {
    getVoices: () => [],
    speak: value => { spoken.push(value); },
    cancel: () => { cancelled++; },
  },
});
Object.defineProperty(globalThis, "performance", {value: {now: () => now}, configurable: true});
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const plugin = await import(pathToFileURL(process.argv[2]).href);
const round = await import(pathToFileURL(process.argv[3]).href);
const descendants = node => [node, ...node.children.flatMap(descendants)];
const textButton = (node, prefix) => descendants(node).find(x => x.tag === "button" && x.textContent.startsWith(prefix));
const click = node => node.dispatchEvent(new Event("click"));
let listener, claim, currentSession = "a";
const submissions = [], requests = [], reviews = [];
const root = new Element(), toolbar = new Element();
root.harness_bridge = {
  toolbar,
  state: () => ({session: currentSession, workspace: "fixture", client_id: "page", voice_pending: false}),
  keyboard_owned: () => false,
  ensure_session: done => { done(200n, {id: currentSession}); },
  subscribe: callback => { listener = callback; return () => { listener = null; }; },
  api: (method, path, payload, done) => {
    requests.push({method, path, payload});
    if (path.endsWith("/latency")) { done(200n, {}); return; }
    if (method === "POST") {
      if (payload.enabled === false) { claim = {enabled: false}; }
      else claim = {enabled: true, owner: "page", token: "token", session: "a"};
      done(200n, claim);
    } else done(200n, {voice: claim, state: "done"});
  },
  voice_submit: (session, text, input, done) => {
    submissions.push({session, text, input});
    stored.delete("gene-harness/voice-draft/fixture/" + session);
    listener("voice/admitted", session, {state: "running"});
    done(202n, {state: "running"});
  },
  voice_review: (session, text, input) => { reviews.push({session, text, input}); return true; },
};
plugin.main(root);
assert.equal(root.textContent.includes('[object EventTarget]'), false, 'native controls must be appended as DOM nodes, never rendered as text');
const voiceButton = textButton(toolbar, "Voice");
click(voiceButton);
assert.equal(recognizers.length, 0, "enabling voice must not request the microphone");
const mic = textButton(root, "Hold to talk");
const transcript = descendants(root).find(x => x.tag === "textarea");
mic.dispatchEvent(new Event("pointerdown"));
assert.equal(recognizers.length, 1, JSON.stringify({requests, text: root.textContent, button: voiceButton.textContent, disabled: mic.disabled}));
const recognition = recognizers[0];
const speechResult = value => Object.assign([{transcript: value}], {isFinal: true});
recognition.onresult({resultIndex: 0, results: [speechResult("a literal /help prompt")]});
assert.equal(transcript.value, "a literal /help prompt");
currentSession = "b"; listener("session/change", "b", null);
now = 4200;
windowTarget.dispatchEvent(new Event("pointerup"));
assert.equal(recognition.stopped, true);
assert.equal(submissions.length, 0, "release must wait for recognition finalization");
mic.dispatchEvent(new Event("pointerdown"));
assert.equal(recognizers.length, 1, "a single-recognizer engine visibly refuses another capture while finalizing");
assert.match(root.textContent, /previous recording is finishing/, 'the refused capture must have visible feedback');
recognition.onend();
assert.equal(submissions.length, 1);
assert.equal(submissions[0].session, "a", "navigation must not retarget capture");
assert.equal(submissions[0].text, "a literal /help prompt");
assert.equal(submissions[0].input.audio_ms, 4200n);
listener("reply", "a", {id: "r1", round_id: "round", text: "Progress", speech: "Checking files.", final: false});
listener("reply", "a", {id: "r1", round_id: "round", text: "Progress", speech: "Checking files.", final: false});
assert.equal(spoken.length, 1, "live duplicates cannot speak twice");
listener("reply", "a", {id: "r2", round_id: "round", text: "Final", speech: "Ready.", final: true});
assert.equal(spoken.length, 1, "speech order must wait for playback completion");
spoken[0].onend();
assert.equal(spoken.length, 2);
assert.equal(spoken[1].text, "Ready.");
const outputLabel = descendants(root).find(x => x.tag === "label" && x.textContent.includes("Speak replies"));
const outputToggle = outputLabel.children.find(x => x.tag === "input");
outputToggle.checked = false;
outputToggle.dispatchEvent(new Event("change"));
listener("voice/replay", "a", {id: "r2", text: "Final", speech: "Ready.", final: true});
assert.equal(spoken.length, 3, "explicit replay works even when automatic speech is off");
assert.equal(spoken[2].text, "Ready.");
mic.dispatchEvent(new Event("pointerdown"));
const premature = recognizers.at(-1);
premature.onresult({resultIndex:0, results:[speechResult("review these words")]});
premature.onend();
assert.equal(submissions.length, 1, 'a recognizer ending before release must preserve text for review instead of submitting it');
assert.match(root.textContent, /stopped before release/);
mic.dispatchEvent(new Event("pointerdown"));
assert.ok(cancelled > 0, "barge-in cancels speech");
const pending = recognizers.at(-1), late = pending.onresult, lateEnd = pending.onend;
root.harnessController.dispose();
assert.equal(pending.aborted, true);
assert.equal(listener, null);
late({resultIndex: 0, results: [speechResult("late private words")]});
lateEnd();
assert.equal(submissions.length, 1, "disposed capture must never submit");
spoken[2].onend();
assert.equal(spoken.length, 3, "disposed speech callback cannot resume the queue");

const wire = [], notices = [], settled = [];
const api = (method, path, payload, done) => { wire.push({method, path, payload, done}); };
const client = round.create_rounds(api, text => { notices.push(text); }, (envelope, receipt) => { settled.push({envelope, receipt}); });
round.configure_rounds(client, "durable");
stored.set("gene-harness/voice-draft/durable/original", JSON.stringify({text: "words more", audio_ms: 200}));
let outcome;
const inputMetadata = {kind: "voice", recognizer: "fixture", audio_ms: 200n};
round.dispatch_round(client, "original", "words", inputMetadata,
  (code, data) => { outcome = {code, data}; });
inputMetadata.audio_ms = 999n;
wire.shift().done(200n, {next_submission_seq: "4", state: "done"});
const post = wire.shift();
assert.equal(post.payload.literal, true);
assert.equal(post.payload.session, "original");
assert.equal(post.payload.submission_seq, "4");
assert.equal(post.payload.input.audio_ms, 200n, 'caller mutations must not change the pending voice envelope');
assert.equal(post.payload.media, undefined, "voice must not pick up attachment drafts");
post.done(0n, {});
assert.equal(outcome.code, 0n);
const lookup = wire.shift();
assert.equal(lookup.method, "GET");
assert.match(lookup.path, /original\/requests\/.*\?kind=round$/);
lookup.done(404n, {});
assert.ok(client.pending, "a missing receipt must retain the original identity");
assert.equal(wire.length, 0, "unknown admissions must never be automatically reposted");
const id = client.pending.request_id;
round.recover_round(client);
wire.shift().done(200n, {id: "round", request_id: id, state: "done"});
assert.equal(client.pending, null);
assert.equal(settled.length, 1);
assert.equal(JSON.parse(stored.get("gene-harness/voice-draft/durable/original")).text, "more",
  "host receipt recovery clears admitted words while preserving a later unsent suffix after plugin disposal");
assert.equal(JSON.parse(stored.get("gene-harness/voice-draft/durable/original")).held, false);
stored.set("gene-harness/voice-draft/durable/refused", JSON.stringify({text:"inspect me", audio_ms:200}));
round.dispatch_round(client, "refused", "inspect me", {kind:"voice", recognizer:"fixture", audio_ms:200n}, () => {});
wire.shift().done(200n, {next_submission_seq:"1", state:"done"});
wire.shift().done(409n, {code:"sequence_conflict"});
assert.equal(client.pending, null);
assert.equal(JSON.parse(stored.get("gene-harness/voice-draft/durable/refused")).held, true,
  "a definite refusal remains held after the optional plugin is replaced or the page reloads");
assert.equal(wire.length, 0, 'a held refusal must not allocate another request identity automatically');
console.log("voice client: pinned input, delayed finals, non-overlap, ordered/deduplicated speech, barge-in, disposal and durable unknown-outcome recovery passed");
