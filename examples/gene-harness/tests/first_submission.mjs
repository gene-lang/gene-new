// Exercise the compiled conversation client with delayed browser responses.
// node tests/first_submission.mjs /path/to/web-build/main.mjs
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { webcrypto } from "node:crypto";

class Element extends EventTarget {
  constructor(tag = "div", text = "") {
    super(); this.tag = tag; this.text = text; this.children = []; this.attributes = {};
    this.value = ""; this.open = false; this.scrollTop = 0; this.scrollHeight = 100; this.clientHeight = 100;
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
  setAttribute(name, value) { this.attributes[name] = value; if(name==='open') this.open=true; if(name==='hidden') this.hidden=true; }
  focus() { document.activeElement = this; }
  contains(node) { return node===this || this.children.some(child=>child.contains(node)); }
  hasAttribute(key) { return key==='disabled'?!!this.disabled:Object.hasOwn(this.attributes,key); }
  getAttribute(key) { return this.attributes[key]??null; }
  querySelectorAll() { return this.children.flatMap(child=>[child,...child.querySelectorAll()]).filter(child=>['button','input','select','textarea','a'].includes(child.tag)); }
  getClientRects() { return this.hidden?[]:[{}]; }
  getBoundingClientRect() { return {left:100,top:100,width:220,height:160}; }
}
const elements = new Map();
const stored = new Map();
const requests = [];
const timers=[];
const element = id => {
  if (!elements.has(id)) elements.set(id, new Element());
  return elements.get(id);
};
Object.assign(globalThis, {
  HTMLElement: Element,
  document: {
    body: new Element('body'),
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
  window: Object.assign(new EventTarget(), {innerWidth:1200,innerHeight:800,location: {origin: "http://fixture", search: "", hash: ""}, history: {replaceState() {}}}),
  WebSocket: class extends EventTarget { constructor(url) { super(); this.url = url; } close() {} },
  // The fixture advances responses explicitly; browser reconnect timers stay idle.
  setTimeout: (callback,ms) => {timers.push({callback,ms}); return timers.length;},
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
    needs_attention: [], filter_epoch: 0n, tabs: [], expanded: [],
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
// Replacing reviewed speech must restore ordinary typing, commands and media.
const reviewClient = client();
reviewClient.status={workspace:'review-workspace'};
stored.set('gene-harness/voice-review/review-workspace/s', JSON.stringify({
  text:'review these spoken words', input:{kind:'voice',recognizer:'fixture',audio_ms:500},
}));
assert.equal(harness.reviewed_voice_input(reviewClient,'s','prefix review these spoken words suffix').kind,'voice');
reviewClient.prompt.value='/corrected misrecognized words';
harness.remember_draft(reviewClient);
assert.equal(harness.reviewed_voice_input(reviewClient,'s',reviewClient.prompt.value).kind,'voice',
  'correcting reviewed speech must preserve literal voice input and leave attachments in the draft');
reviewClient.prompt.value='';
harness.remember_draft(reviewClient);
assert.equal(stored.has('gene-harness/voice-review/review-workspace/s'),false);
assert.equal(harness.reviewed_voice_input(reviewClient,'s','/help'),null);
assert.equal(harness.reviewed_voice_input(reviewClient,'s','ordinary text with attachments'),null);
const bubbles = c => descendants(c.transcript).filter(node => node.tag === "article" && node.attributes.class?.includes("user"));
function promptVisible(c, prompt) {
  assert.equal(bubbles(c).length, 1, "prompt must be displayed exactly once");
  assert.equal(bubbles(c)[0].textContent, "User" + prompt);
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
  id: "s", title: "Renamed", revision: "1", first_request: prompt, first_request_round: "round-s-1", first_request_speaker: "User",
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
assert.match(requests[0].path,/sessions\/s\/commands$/);
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

// Command admission clears only the matching submitted command. Transcript
// pagination and changed drafts retain both text and attachment IDs.
for(const draft of ["Keep an unrelated draft","/help","/help changed while preparing"]) {
  c=client(); c.prompt.value=draft;
  c.media.drafts.s=[{key:"attachment-draft",state:"ready",name:"pixel.png",asset}];
  c.command_client=create_commands((method,path,payload,done)=>harness.api(c,method,path,payload,done),noop,
    (envelope,receipt)=>harness.command_settled(c,envelope,receipt));
  const text=draft==="Keep an unrelated draft"?"/view README.md:401":"/help";
  harness.send_command(c,text);
  requests[0].reply(200,{next_command_seq:"1"}); await settled();
  requests[1].reply(202,{id:"c1",status:"running"}); await settled();
  assert.equal(c.prompt.value,draft==="/help"?"":draft);
  assert.deepEqual(media_ids(c.media),[asset.id]);
}

// Uncertain creation requires explicit inspection acknowledgement, and the
// same policy applies to launcher, sidebar, and first-message creation.
c=client(); c.selected="";
let creationResult;
harness.request_session(c,"Plugin tools",(code,data)=>{creationResult={code,data};});
requests[0].reply(502,{message:"Gateway failure"}); await settled();
assert.equal(c.creation_unknown,true);
assert.equal(element("session_creation_recovery").hidden,false);
const beforeBlocked=requests.length;
harness.request_session(c,"New conversation",(code,data)=>{creationResult={code,data};});
assert.equal(creationResult.code,409n);
assert.equal(creationResult.data.not_sent,true);
assert.equal(requests.length,beforeBlocked);
harness.acknowledge_creation(c);
assert.equal(c.creation_unknown,false);
assert.equal(element("session_creation_recovery").hidden,true);
harness.request_session(c,"New conversation",(code,data)=>{creationResult={code,data};});
requests.at(-1).reply(201,{id:"created"}); await settled();
assert.equal(creationResult.code,201n);
assert.equal(c.creation_unknown,false);

// Conversation navigation consumes the snapshot it already fetched instead
// of discarding it and briefly rendering an empty/default target cache.
c=client();
c.ui=create_ui(element("ui_root"),true,c.notices,noop,noop,noop,noop,"light");
let navigationResult;
harness.launcher_navigate(c,{kind:"conversation",session:"target"},(code,data)=>{navigationResult=code;});
const fetched={...snapshot(),session:{id:"target",title:"Fresh target",revision:"4",first_request:""}};
requests[0].reply(200,fetched); await settled();
assert.equal(navigationResult,200n);
assert.equal(c.selected,"target");
assert.equal(c.title.textContent,"Fresh target");
assert.equal(c.tabs.find(tab=>tab.id==="target").cache.session.revision,"4");
assert.equal(requests.filter(request=>request.path==="/api/v8/sessions/target/snapshot").length,1);

// An already-open, connected tab keeps its live cache: frames delivered while
// the navigation GET was in flight must not be replaced by the older snapshot.
c=client();
c.ui=create_ui(element("ui_root"),true,c.notices,noop,noop,noop,noop,"light");
const live=harness.session_tab(c,"target");
live.connected=true;
const liveRecord={id:"target/9",seq:"9",round_id:"round-target-1",turn:1n,
  role:"assistant",phase:"reply",kind:"reply",text:"Arrived during navigation",durable:true,final:false,media:[]};
live.cache={...snapshot(null,[liveRecord]),session:{id:"target",title:"Live target",revision:"7",first_request:""}};
harness.launcher_navigate(c,{kind:"conversation",session:"target"},(code,data)=>{navigationResult=code;});
requests[0].reply(200,{...snapshot(),session:{id:"target",title:"Stale target",revision:"6",first_request:""}});
await settled();
assert.equal(navigationResult,200n);
assert.equal(c.selected,"target");
assert.equal(c.title.textContent,"Live target");
assert.ok(c.records.some(record=>record.id==="target/9"),"a live tab must keep records its stream delivered");

// A reply and console frame arrive after the GET begins, then the real socket
// close handler runs before its response. Reconnecting must keep that cache.
c=client();
c.ui=create_ui(element("ui_root"),true,c.notices,noop,noop,noop,noop,"light");
const interrupted=harness.session_tab(c,"target");
harness.connect_stream(c,interrupted);
interrupted.connected=true;
interrupted.cache={...snapshot(),session:{id:"target",title:"Target",revision:"6",first_request:""}};
const earlier={...snapshot(),session:{id:"target",title:"Target",revision:"6",first_request:""}};
harness.launcher_navigate(c,{kind:"conversation",session:"target"},(code,data)=>{navigationResult=code;});
const arriving=["reply","console"].map((kind,index)=>({
  id:`target/late-${kind}`,seq:String(9+index),round_id:"round-target-1",turn:1n,
  role:"assistant",phase:kind,kind,text:`${kind} arrived after GET began`,durable:false,final:false,media:[],
}));
// Inactive streams append these frames to their tab's preview.
interrupted.cache.preview.push(...arriving);
const closedSocket=interrupted.socket;
closedSocket.dispatchEvent(new Event("close"));
assert.equal(interrupted.connected,false);
requests[0].reply(200,earlier); await settled();
assert.equal(navigationResult,200n);
assert.equal(c.selected,"target");
for(const record of arriving) {
  if(record.kind==='console') {
    assert.equal(c.preview.some(saved=>saved.id===record.id),false,'historical console previews cannot hydrate live output');
  } else {
    assert.ok(c.preview.some(saved=>saved.id===record.id),"disconnect during GET must preserve cached frames");
    assert.ok(interrupted.cache.preview.some(saved=>saved.id===record.id));
  }
}
assert.notEqual(interrupted.socket,closedSocket,"selecting a disconnected tab must still reconnect it");

// Live stdout is a separate overlay, including before ready and during snapshots.
c=client();
const outputModel=await import(new URL('live_output.mjs',mainURL));
const codeBlock={id:'s/code',round_id:'r',turn:1n,role:'assistant',phase:'code',kind:'turn/response',
  text:'($println "printed")',durable:true,media:[]};
c.records=[codeBlock];
harness.render_transcript(c);
let panel=descendants(c.transcript).find(x=>x.attributes.class==='execution live_output');
assert.equal(panel.hidden,true);
const tab=harness.session_tab(c,'s');
const frame=(sequence,id,text,extra={})=>JSON.stringify({protocol:8,epoch:'live-host',sequence:String(sequence),
  type:'console',session:'s',data:{id,round_id:'r',turn:1,text,phase:'console',...extra}});
const beforeTimers=timers.filter(t=>t.ms===40).length;
harness.stream_message(c,tab,frame(1,'s/log1','<script>literal</script>\n'));
harness.stream_message(c,tab,frame(2,'s/log2','continued\n'));
assert.equal(tab.connected,false,'before-ready output must not require a ready snapshot');
assert.equal(timers.filter(t=>t.ms===40).length-beforeTimers,1,'burst updates are coalesced');
timers.filter(t=>t.ms===40).at(-1).callback();
assert.equal(panel.hidden,false); assert.equal(panel.open,false);
assert.match(panel.textContent,/<script>literal<\/script>/);
assert.equal(descendants(panel).some(x=>x.tag==='script'),false);
panel.open=true; panel.dispatchEvent(new Event('toggle'));
const oldConsole={...codeBlock,id:'s/old',phase:'console',text:'historical secret'};
harness.apply_snapshot(c,{...snapshot(),records:[codeBlock,oldConsole],preview:[oldConsole]});
panel=descendants(c.transcript).find(x=>x.attributes.class==='execution live_output');
assert.equal(panel.open,true,'snapshot re-render must preserve an explicitly opened Output');
assert.match(panel.textContent,/continued/); assert.doesNotMatch(panel.textContent,/historical secret/);
assert.ok(!c.records.some(x=>x.phase==='console')); assert.equal(c.preview.length,0);
harness.stream_message(c,tab,frame(3,'s/log1','duplicate'));
harness.stream_message(c,tab,frame(4,'s/late','late\n',{late:true}));
timers.filter(t=>t.ms===40).at(-1).callback();
assert.equal(panel.textContent.split('<script>').length-1,1);
assert.match(panel.textContent,/Late output/);
assert.equal(descendants(c.transcript).filter(x=>x.attributes.class==='step').length,1);
const liveKey=outputModel.turn_output_key('s','r',1n);
assert.ok(outputModel.output_entry(harness.live_store(c),liveKey));
const bg=harness.session_tab(c,'background');
const bgFrame={protocol:8,epoch:'live-host',sequence:'1',type:'console',session:'background',
  data:{id:'bg/log',round_id:'r',turn:1,text:'background output',phase:'console'}};
harness.stream_message(c,bg,JSON.stringify(bgFrame));
assert.equal(outputModel.output_entry(harness.live_store(c),outputModel.turn_output_key('background','r',1n)).text,'background output');
assert.doesNotMatch(panel.textContent,/background output/);
assert.equal(bg.cache.preview.length,0,'background stdout is not a history preview');
c.selected='background'; c.records=[{...codeBlock,id:'background/code'}]; c.preview=[];
harness.render_transcript(c);
assert.match(c.transcript.textContent,/background output/,'navigation attaches its own retained output');
c.selected='s'; harness.apply_snapshot(c,{...snapshot(),records:[codeBlock]});
assert.equal(descendants(c.transcript).find(x=>x.attributes.class==='execution live_output').open,true,
  'same-page navigation retains the user-chosen disclosure state');
harness.close_tab(c,'background');
assert.equal(outputModel.output_entry(harness.live_store(c),outputModel.turn_output_key('background','r',1n)),null);
assert.ok(outputModel.output_entry(harness.live_store(c),liveKey));
const newEpoch={...JSON.parse(frame(5,'s/new-epoch','fresh epoch output')),epoch:'next-host'};
harness.stream_message(c,tab,JSON.stringify(newEpoch));
timers.filter(t=>t.ms===40).at(-1).callback();
panel=descendants(c.transcript).find(x=>x.attributes.class==='execution live_output');
assert.equal(panel.open,false,'a new host epoch starts new Output disclosures collapsed');
assert.match(panel.textContent,/fresh epoch output/); assert.doesNotMatch(panel.textContent,/continued/);
harness.stream_message(c,tab,frame(6,'s/stale','stale old epoch'));
assert.doesNotMatch(outputModel.output_entry(harness.live_store(c),liveKey).text,/stale old epoch/);
harness.live_console(c,'s',{id:'pending-log',round_id:'future',turn:9n,text:'arrived before its code'});
assert.doesNotMatch(c.transcript.textContent,/arrived before its code/);
harness.apply_record(c,{...codeBlock,id:'future-code',round_id:'future',turn:9n,durable:false});
const futureStep=descendants(c.transcript).find(x=>x.attributes.class==='step'&&x.textContent.startsWith('Turn 9'));
assert.match(futureStep.textContent,/arrived before its code/,'pending output attaches when its own turn arrives');
const fresh=client();
harness.apply_snapshot(fresh,{...snapshot(),records:[codeBlock,oldConsole]});
const freshPanel=descendants(fresh.transcript).find(x=>x.attributes.class==='execution live_output');
assert.equal(freshPanel.hidden,true,'a reload cannot reconstruct printed output');
// Command streams and return values share one plain monospace Agent block.
c=client();
const replSource='($println "printed value") (+ 40 2)';
const replInput={id:'s/c2/input',seq:'2',round_id:'',turn:0n,role:'user',phase:'prompt',
  speaker:'REPL input',text:replSource,durable:true};
const replResult={id:'s/c2',seq:'2',round_id:'',turn:0n,role:'assistant',phase:'command',
  command_id:'c2',name:'repl',raw:replSource,mode_instance:'repl-instance',input_id:'repl-input',
  status:'running',text:'',durable:true};
harness.apply_snapshot(c,{...snapshot(null,[replInput,replResult]),cursor:'2'});
assert.equal(descendants(c.transcript).filter(node=>node.tag==='pre'&&node.attributes.class==='command_output').length,1);
assert.equal(descendants(c.transcript).some(node=>node.tag==='details'),false);
harness.live_console(c,'s',{id:'s/c2/console',command_id:'c2',round_id:'',turn:0n,cumulative:true,text:'printed value\n'});
timers.filter(t=>t.ms===40).at(-1).callback();
let commandPre=descendants(c.transcript).find(node=>node.attributes.class==='command_output');
assert.equal(commandPre.textContent,'printed value\n');
const replDone={...replResult,status:'done',text:'42'};
harness.apply_snapshot(c,{...snapshot(null,[replInput,replDone]),cursor:'2'});
let replRun=descendants(c.transcript).find(node=>node.attributes.class==='run');
assert.deepEqual(replRun.children.map(node=>node.tag),['article','article']);
assert.equal(replRun.children[0].textContent,'User'+replSource);
assert.equal(replRun.children[1].textContent,'Agentprinted value\n42');
assert.equal(descendants(replRun).filter(node=>node.tag==='pre').length,1);
const replReload=client();
harness.apply_snapshot(replReload,snapshot(null,[replInput,replDone]));
assert.equal(descendants(replReload.transcript).find(node=>node.attributes.class==='command_output').textContent,'42');
const liveRepl=client();
harness.apply_record(liveRepl,replInput);
harness.apply_command(liveRepl,'s',{id:'c2',name:'repl',raw:replSource,mode_instance:'repl-instance',
  input_id:'repl-input',status:'running',start_seq:2n});
harness.live_console(liveRepl,'s',{id:'s/c2/console',command_id:'c2',round_id:'',turn:0n,cumulative:true,text:'live print\n'});
timers.filter(t=>t.ms===40).at(-1).callback();
harness.apply_command(liveRepl,'s',{id:'c2',name:'repl',raw:replSource,mode_instance:'repl-instance',
  input_id:'repl-input',status:'done',display:'42',start_seq:2n});
replRun=descendants(liveRepl.transcript).find(node=>node.attributes.class==='run');
assert.deepEqual(replRun.children.map(node=>node.tag),['article','article']);
assert.equal(replRun.children[1].textContent,'Agentlive print\n42');
for (const name of ['run','sh']) {
  const execution=client();
  const code=name==='run'?'($println "hello") 42':'printf hello';
  const user={...replInput,text:`/${name} ${code}`};
  const running={...replResult,name,raw:code,mode_instance:null};
  harness.apply_snapshot(execution,{...snapshot(null,[user,running]),cursor:'2'});
  harness.live_console(execution,'s',{id:'s/c2/console',command_id:'c2',round_id:'',turn:0n,cumulative:true,text:'hello\n'});
  timers.filter(t=>t.ms===40).at(-1).callback();
  harness.apply_command(execution,'s',{id:'c2',name,raw:code,status:'done',start_seq:2n,
    display:name==='run'?'42':'hello\n',exit:name==='sh'?0n:null});
  const run=descendants(execution.transcript).find(node=>node.attributes.class==='run');
  const output=descendants(run).find(node=>node.attributes.class==='command_output');
  assert.equal(output.textContent,name==='run'?'hello\n42':'hello\n');
  assert.equal(descendants(run).some(node=>node.tag==='details'),false);
  assert.equal(run.textContent.split(code).length-1,1,'the command appears only in its User message');
}
// A receiving Request has a stable identity but a later source sequence. Live
// replacement and an older in-flight snapshot must retain the newest input.
c=client();
const projectedRound={id:'projection',state:'running',submission_seq:2n,initiator:'user',prompt:''};
const projectedRequest={id:'projection/request-2',seq:'10',round_id:'projection',turn:2n,
  role:'assistant',phase:'turn/request',text:'original prepared input',durable:true};
harness.apply_snapshot(c,{...snapshot(projectedRound,[projectedRequest]),cursor:'10'});
harness.apply_record(c,{...projectedRequest,seq:'11',text:'replacement with answered questions'});
assert.match(c.transcript.textContent,/replacement with answered questions/);
harness.apply_snapshot(c,{...snapshot(projectedRound,[projectedRequest]),cursor:'10'});
assert.match(c.transcript.textContent,/replacement with answered questions/);
assert.doesNotMatch(c.transcript.textContent,/original prepared input/);
const paused={...projectedRound,state:'paused',reason:'turn_limit',continuation:{items_ref:'body'}};
harness.apply_run(c,'s',paused);
const resumeButtons=descendants(c.transcript).filter(node=>node.tag==='button'&&['Continue','Continue until finished'].includes(node.textContent));
assert.equal(resumeButtons.length,2);
resumeButtons[1].dispatchEvent(new Event('click'));
assert.equal(requests.at(-1).path,'/api/v8/sessions/s/rounds/projection/continue');
assert.equal(JSON.parse(requests.at(-1).options.body).mode,'automatic');
assert.equal(descendants(c.transcript).some(node=>node.textContent==='Edit and retry'),false);
harness.apply_run(c,'s',{...projectedRound,id:'successor',submission_seq:3n,continuation_mode:'automatic',task_turns:57n});
harness.apply_run(c,'s',paused);
assert.equal(c.round.id,'successor','an old source receipt must not replace its active successor');
assert.match(c.transcript.textContent,/Continuing automatically · 57 turns/);
harness.apply_snapshot(c,{...snapshot(paused,[projectedRequest]),cursor:'10'});
assert.equal(c.round.id,'successor','an older in-flight snapshot must not replace the successor');
c=client();
c.sessions=[{id:'menu-a',title:'A conversation',kind:'interactive',status:'done',revision:'2',pinned:false},
  {id:'menu-b',title:'Another conversation',kind:'interactive',status:'done',revision:'0',pinned:false}];
harness.render_sessions(c);
const firstRow=c.list.children[0];
assert.equal(firstRow.children[0].tag,'button');
assert.equal(firstRow.children[1].attributes['aria-label'],'Actions for A conversation');
firstRow.children[1].dispatchEvent(new Event('click'));
assert.equal(c.selected,'s','opening row actions must not navigate');
let menu=c.session_menu;
assert.deepEqual(menu.panel.children.filter(node=>node.tag==='button'&&!node.hidden).map(node=>node.textContent),['Rename','Delete','Pin']);
menu.panel.children.find(node=>node.textContent==='Pin').dispatchEvent(new Event('click'));
assert.equal(requests.at(-1).path,'/api/v8/sessions/menu-a');
assert.equal(JSON.parse(requests.at(-1).options.body).revision,'2');
requests.at(-1).reply(200,{...c.sessions[0],pinned:true,revision:'3'});await settled();
assert.equal(c.selected,'s');
assert.equal(c.sessions[0].pinned,true);
assert.equal(c.session_revision,'0','editing another row must not change the selected revision');
assert.equal(document.activeElement,c.list.children[0].children[1]);
harness.render_sessions(c);
assert.equal(document.activeElement,c.list.children[0].children[1],'a list refresh keeps keyboard focus on row actions');
const menuTab=harness.session_tab(c,'menu-a');menuTab.cache.session=c.sessions[0];
c.list.children[0].children[1].dispatchEvent(new Event('click'));
menu.panel.children.find(node=>node.textContent==='Delete').dispatchEvent(new Event('click'));
menu.panel.children.find(node=>node.tag==='button'&&node.textContent==='Delete').dispatchEvent(new Event('click'));
assert.equal(requests.at(-1).options.method,'DELETE');
requests.at(-1).reply(200,{deleted:['menu-a']});await settled();
assert.equal(menuTab.closed,true);assert.equal(c.selected,'s');
assert.equal(c.sessions.some(session=>session.id==='menu-a'),false);
const deletedSelected=client();
deletedSelected.ui=create_ui(element('ui_root'),true,deletedSelected.notices,noop,noop,noop,noop,'light');
harness.session_tab(deletedSelected,'s');harness.session_tab(deletedSelected,'survivor');
deletedSelected.sending=true;deletedSelected.prompt.value='A draft in the deleted conversation';
stored.set('gene-harness/draft/s',deletedSelected.prompt.value);
harness.forget_session(deletedSelected,'s');
assert.equal(deletedSelected.selected,'survivor','deletion must navigate away even during a pending admission');
assert.equal(stored.has('gene-harness/draft/s'),false);
console.log("first submission: immediate prompts, delivery races, live output, receiving-request replacement and continuation controls passed");

// A late share response must preserve a newer, already-linked live snapshot.
c = client();
const shareTab = harness.session_tab(c, 's');
shareTab.cache.session = {id: 's', kind: 'interactive', title: 'Share me', revision: '0', slack_available: true};
harness.update_controls(c);
assert.equal(element('add_to_slack').hidden, false);
assert.equal(element('add_to_slack').disabled, false);
harness.add_session_to_slack(c);
harness.add_session_to_slack(c);
assert.equal(requests.length, 1, 'double clicks send a single share request');
assert.equal(requests[0].path, '/api/v8/sessions/s/slack');
assert.equal(element('add_to_slack').disabled, true);
assert.equal(element('add_to_slack').textContent, 'Adding to Slack…');
shareTab.cache.session = {...shareTab.cache.session, revision: '3', channel: {transport: 'slack', thread: '1.000001'}};
c.session_revision = '3';
requests[0].reply(202, {id: 's', kind: 'interactive', title: 'Share me', revision: '1',
  slack_available: true, slack_share: {id: 'share-s', status: 'pending'}});
await settled();
assert.equal(shareTab.cache.session.channel.thread, '1.000001');
assert.equal(c.session_revision, '3');
assert.equal(element('add_to_slack').hidden, true);
for (const session of [
  {id: 's', kind: 'child', slack_available: true},
  {id: 's', kind: 'interactive', slack_available: false},
]) {
  shareTab.cache.session = session;
  harness.update_controls(c);
  assert.equal(element('add_to_slack').hidden, true);
}
shareTab.cache.session = {id: 's', kind: 'interactive', slack_available: true};
harness.add_session_to_slack(c);
requests[1].reply(503, {message: 'The Slack channel connection is disabled.'});
await settled();
assert.equal(element('add_to_slack').disabled, false, 'a rejected request can be retried');
for (const [status,label] of [['failed','Slack share failed'],['uncertain','Slack share needs attention'],['accepted','Adding to Slack…']]) {
  shareTab.cache.session = {id:'s',kind:'interactive',slack_available:true,slack_share:{status}};
  harness.update_controls(c);
  assert.equal(element('add_to_slack').textContent,label);
  assert.equal(element('add_to_slack').disabled,true,'a durable share must be resolved by the owner');
}
console.log('Slack share button: eligibility, duplicate clicks, late responses and errors passed');

c=client();
c.sessions=[{id:'other',title:'Share another conversation',kind:'interactive',status:'done',revision:'2',slack_available:true}];
harness.render_sessions(c);
c.list.children[0].children[1].dispatchEvent(new Event('click'));
c.session_menu.panel.children.find(node=>node.textContent==='Add to Slack').dispatchEvent(new Event('click'));
assert.equal(c.selected,'s','sharing another row must not navigate away from the current conversation');
assert.equal(requests[0].path,'/api/v8/sessions/other/slack');
assert.deepEqual(JSON.parse(requests[0].options.body),{revision:'2'});
requests[0].reply(202,{...c.sessions[0],revision:'3',slack_share:{status:'pending'}});
await settled();
assert.equal(c.sessions[0].slack_share.status,'pending');
assert.equal(c.session_revision,'0','sharing another row must preserve the selected revision');
assert.equal(c.session_menu.panel.hidden,true);
const newerTab=harness.session_tab(c,'other');
newerTab.cache.session={...c.sessions[0],revision:'5',channel:{transport:'slack',thread:'1.000001'}};
harness.session_edited(c,{...c.sessions[0],revision:'3'});
assert.equal(newerTab.cache.session.channel.thread,'1.000001','late menu responses preserve the newer linked snapshot');
console.log('Slack menu integration: unselected session targeting and late-response protection passed');

const responseClient=client();
harness.apply_snapshot(responseClient,snapshot(null,[codeBlock]));
const responsePanel=()=>descendants(responseClient.transcript).find(node=>node.tag==='details'&&node.children[0]?.textContent==='Response');
const turnPanel=()=>descendants(responseClient.transcript).find(node=>node.attributes.class==='step');
turnPanel().open=true;turnPanel().dispatchEvent(new Event('toggle'));
assert.equal(responsePanel().open,true);
responsePanel().open=false;responsePanel().dispatchEvent(new Event('toggle'));
harness.apply_snapshot(responseClient,snapshot(null,[codeBlock]));
assert.equal(turnPanel().open,true);
assert.equal(responsePanel().open,false,'live snapshots preserve a manually collapsed Response');
turnPanel().open=false;turnPanel().dispatchEvent(new Event('toggle'));
turnPanel().open=true;turnPanel().dispatchEvent(new Event('toggle'));
assert.equal(responsePanel().open,true,'reopening the turn opens its Response again');
console.log('Response disclosure: turn expansion and manual collapse across snapshots passed');

// Feature handlers receive frames only after the common stream guards. One
// page subscription handles selected and background sessions without mixing
// their records, and a failed observer cannot prevent the core projection.
c=client();
const featureBus=await import(new URL('feature_events.mjs',mainURL));
const {create_question_editors}=await import(new URL('question_editors.mjs',mainURL));
const {create_center}=await import(new URL('notification_center.mjs',mainURL));
const {create_producer_inbox}=await import(new URL('producer_inbox.mjs',mainURL));
c.ui=create_ui(element('ui_root'),true,c.notices,noop,noop,noop,noop,'light');
c.questions=create_question_editors(c.notices,noop,noop);
c.center=create_center(c.notices,c.questions,noop,noop);
c.inbox=create_producer_inbox(c.notices,false,noop,noop,noop,noop);
harness.apply_snapshot(c,snapshot());
harness.ensure_feature_host(c);
const selectedTab=harness.session_tab(c,'s');
const backgroundTab=harness.session_tab(c,'feature-background');
const observed=[];
const failingObserver=featureBus.subscribe_feature(c.feature_events,()=>{throw new Error('fixture observer failed');});
const observing=featureBus.subscribe_feature(c.feature_events,(kind,session)=>observed.push([kind,session]));
const featureFrame=(sequence,session,type,data,epoch='features-host')=>JSON.stringify({
  protocol:8,epoch,sequence:String(sequence),session,type,data});
const delegationBlock=(id,revision)=>({id,round_id:'r',turn:1,phase:'delegation/update',
  role:'assistant',seq:'1',text:'',durable:true,delegation:{revision}});
const priorConsoleError=console.error;
console.error=()=>{};
try {
  harness.stream_message(c,selectedTab,featureFrame(1,'s','delegation',delegationBlock('selected-child',2)));
  assert.equal(c.records.find(row=>row.id==='selected-child').delegation.revision,2n);
  assert.equal(selectedTab.cache.records.find(row=>row.id==='selected-child').delegation.revision,2n);
  harness.stream_message(c,backgroundTab,featureFrame(1,'feature-background','delegation',delegationBlock('background-child',3)));
  assert.equal(backgroundTab.cache.records.find(row=>row.id==='background-child').delegation.revision,3n);
  assert.equal(c.records.some(row=>row.id==='background-child'),false);
  harness.stream_message(c,selectedTab,featureFrame(2,'s','extension/custom',{value:'accepted'}));
  assert.deepEqual(observed.at(-1),['extension/custom','s']);
  const beforeRejected=observed.length;
  harness.stream_message(c,selectedTab,featureFrame(3,'s','extension/custom',{},'retired-host'));
  // A genuinely new epoch is accepted once; the former epoch is then stale.
  const afterEpoch=observed.length;
  harness.stream_message(c,selectedTab,featureFrame(4,'s','extension/custom',{},'features-host'));
  assert.equal(observed.length,afterEpoch,'an old epoch reached feature handlers');
  assert.ok(afterEpoch>beforeRejected);
  harness.stream_message(c,selectedTab,featureFrame(8,'s','extension/custom',{}));
  assert.equal(observed.length,afterEpoch,'a sequence gap reached feature handlers');
} finally { console.error=priorConsoleError; failingObserver(); observing(); }
console.log('Feature stream coordination: guards, arbitrary events, failure isolation and selected/background delegation passed');
