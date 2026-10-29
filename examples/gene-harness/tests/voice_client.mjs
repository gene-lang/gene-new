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
const workspaceId = 'fixture-workspace';
const harnessDocument = Object.assign(new Element('html'), {dataset: {workspaceId}});
let now = 0, cancelled = 0;
const windowTarget = Object.assign(new EventTarget(), {location: {origin: "http://fixture"}});
Object.assign(globalThis, {
  HTMLElement: Element,
  document: {
    getElementById: id => id === 'harness_document' ? harnessDocument : null,
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
const {workspace_storage_key} = await import(new URL('workspace_storage.mjs', pathToFileURL(process.argv[3])));
const scoped = key => workspace_storage_key(workspaceId, key);
const descendants = node => [node, ...node.children.flatMap(descendants)];
const textButton = (node, prefix) => descendants(node).find(x => x.tag === "button" && x.textContent.startsWith(prefix));
const click = node => node.dispatchEvent(new Event("click"));
let listener, claim, currentSession = "a";
const submissions = [], requests = [], reviews = [];
const root = new Element(), toolbar = new Element();
root.harness_bridge = {
  toolbar,
  state: () => ({session: currentSession, workspace: "fixture", client_id: "page"}),
  keyboard_owned: () => false,
  ensure_session: done => { done(200n, {id: currentSession}); },
  subscribe: callback => { listener = callback; return () => { listener = null; }; },
  api: (method, path, payload, done) => {
    requests.push({method, path, payload});
    if (path.endsWith("/latency")) { done(200n, {}); return; }
    if (method === "POST") {
      if (payload.enabled === false) { claim = {enabled: false}; }
      else claim = {enabled: true, owner: "page", token: "token", revision:"revision-a", session: "a"};
      done(200n, claim);
    } else done(200n, {voice: {...claim,token:undefined}, state: "done"});
  },
  capabilities: {voice: {pending: () => false, submit: (session, text, input, done) => {
    submissions.push({session, text, input});
    stored.delete(scoped("gene-harness/voice-draft/fixture/" + session));
    listener("voice/admitted", session, {state: "running"});
    done(202n, {state: "running"});
  },
  review: (session, text, input) => { reviews.push({session, text, input}); return true; }}},
};
plugin.main(root);
assert.equal(root.textContent.includes('[object EventTarget]'), false, 'native controls must be appended as DOM nodes, never rendered as text');
const voiceButton = textButton(toolbar, "Voice");
click(voiceButton);
listener('voice/state','',{enabled:true,owner:'page',revision:'revision-a',session:'a'});
assert.equal(voiceButton.textContent,'Voice on','public ownership broadcasts must not require a private claim token');
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

// A released browser utterance that times out keeps its own partial as held text.
const timeoutRoot = new Element();
currentSession='a';
stored.delete(scoped('gene-harness/voice-draft/fixture/a'));
timeoutRoot.harness_bridge = root.harness_bridge;
plugin.main(timeoutRoot);
click(descendants(toolbar).filter(x => x.tag === 'button' && x.textContent.startsWith('Voice')).at(-1));
textButton(timeoutRoot,'Hold to talk').dispatchEvent(new Event('pointerdown'));
const timedRecognition = recognizers.at(-1);
timedRecognition.onresult({resultIndex:0, results:[Object.assign([{transcript:'recover this partial'}],{isFinal:false})]});
windowTarget.dispatchEvent(new Event('pointerup'));
timers.filter(item => item.ms === 5000).at(-1).callback();
assert.equal(JSON.parse(stored.get(scoped('gene-harness/voice-draft/fixture/a'))).text,'recover this partial');
assert.equal(JSON.parse(stored.get(scoped('gene-harness/voice-draft/fixture/a'))).held,true);
assert.equal(JSON.parse(stored.get(scoped('gene-harness/voice-draft/fixture/a'))).review_required,true);
assert.equal(submissions.length,1, 'a timed-out partial must never auto-submit');
// Pause as soon as the fourth host utterance is pending, before the next VAD frame.
timeoutRoot.harnessController.dispose();
const sharedVoice = await import(new URL('./voice_transitions.mjs',pathToFileURL(process.argv[2])));
const hostVoice = await import(new URL('./host_audio.mjs',pathToFileURL(process.argv[2])));
globalThis.WebSocket=class extends EventTarget {readyState=0; close() {this.readyState=3;}};
const pauseHost=hostVoice.open_host_audio(new AudioContext(),'a','page','csrf','token',false,true,false,()=>{});
const voiceProps={host:pauseHost,pending:{},drafts:sharedVoice.new_voice_drafts(),bridge:{},
  queue:[],seen:{},final_rounds:{}};
for (const field of ['root','button','panel','mic','message','transcript','send_button','discard_button',
  'meter','mode_select','voice_select']) voiceProps[field]=new Element();
for (const field of ['context','capture','unsubscribe','pointer_up','key_down','key_up','page_hide']) voiceProps[field]=null;
for (const field of ['enabled','disposed','claiming','recording','finalizing','submitting','held','output',
  'autosend','progress','manual_capture','speaking']) voiceProps[field]=false;
for (const field of ['mode','voice','language','recognizer','synthesizer','speaking_record','duplex','session',
  'title','workspace','client_id','token','claim_revision','capture_id','round_state','partial','feedback']) voiceProps[field]='';
for (const field of ['release_at','speech_began','capture_started']) voiceProps[field]=0;
for (const field of ['generation','speech_generation']) voiceProps[field]=0n;
const timeoutVoice = new plugin.Voice(voiceProps);
for (let i=0;i<4;i++) {
  const id='held-'+i;
  sharedVoice.start_utterance(timeoutVoice.drafts,id,'a');
  plugin.await_host_final(timeoutVoice,id,1000n);
}
assert.equal(timeoutVoice.host.input_paused,true);
plugin.drop_pending(timeoutVoice,'held-0');
assert.equal(timeoutVoice.host.input_paused,false);
hostVoice.close_host_audio(pauseHost);

const wire = [], notices = [], settled = [];
const api = (method, path, payload, done) => { wire.push({method, path, payload, done}); };
const client = round.create_rounds(api, text => { notices.push(text); }, (envelope, receipt) => { settled.push({envelope, receipt}); });
round.configure_rounds(client, "durable");
stored.set(scoped("gene-harness/voice-draft/durable/original"), JSON.stringify({text: "words more", audio_ms: 200}));
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
assert.equal(JSON.parse(stored.get(scoped("gene-harness/voice-draft/durable/original"))).text, "more",
  "host receipt recovery clears admitted words while preserving a later unsent suffix after plugin disposal");
assert.equal(JSON.parse(stored.get(scoped("gene-harness/voice-draft/durable/original"))).held, false);
stored.set(scoped("gene-harness/voice-draft/durable/refused"), JSON.stringify({text:"inspect me", audio_ms:200}));
round.dispatch_round(client, "refused", "inspect me", {kind:"voice", recognizer:"fixture", audio_ms:200n}, () => {});
wire.shift().done(200n, {next_submission_seq:"1", state:"done"});
wire.shift().done(409n, {code:"sequence_conflict"});
assert.equal(client.pending, null);
assert.equal(JSON.parse(stored.get(scoped("gene-harness/voice-draft/durable/refused"))).held, true,
  "a definite refusal remains held after the optional plugin is replaced or the page reloads");
assert.equal(wire.length, 0, 'a held refusal must not allocate another request identity automatically');
stored.set(scoped('gene-harness/voice-draft/durable/partial-review'),JSON.stringify({
  text:'accepted recovered partial',audio_ms:500,held:true,review_required:true,
}));
client.pending={session:'partial-review',text:'accepted',input:{audio_ms:100n}};
round.admitted(client,{id:'admitted'});
const heldSuffix=JSON.parse(stored.get(scoped('gene-harness/voice-draft/durable/partial-review')));
assert.equal(heldSuffix.text,'recovered partial');
assert.equal(heldSuffix.held,true,'receipt recovery must not auto-release a later partial transcript');
console.log("voice client: pinned input, delayed finals, non-overlap, ordered/deduplicated speech, barge-in, disposal and durable unknown-outcome recovery passed");
