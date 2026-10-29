// External browser edges for the compiled Gene controller. No application
// behavior is implemented here; actual keyboard/focus also gets browser QA.
import assert from "node:assert/strict";
import {pathToFileURL} from "node:url";
import {webcrypto} from "node:crypto";

class Element extends EventTarget {
  constructor(tag = "div", text = "") {
    super(); this.tag = tag; this.children = []; this.attributes = {};
    this.text = text; this.hidden = false; this.value = ""; this.scrollTop = 0;
    this.classes = new Set();
    this.classList = {toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name)};
  }
  get ownerDocument() { return document; }
  get textContent() { return this.text + this.children.map(x => x.textContent).join(""); }
  set textContent(value) { this.text = value; this.replaceChildren(); }
  get isConnected() { return this === document.body || !!this.parentNode?.isConnected; }
  append(...children) { children.forEach(x => this.appendChild(x)); }
  appendChild(child) {
    if (child.tag === "#fragment") { [...child.children].forEach(x => this.appendChild(x)); return child; }
    child.parentNode?.removeChild(child); this.children.push(child); child.parentNode = this; return child;
  }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
  replaceChildren(...children) { this.children.forEach(x => x.parentNode = null); this.children = []; this.append(...children); }
  setAttribute(key, value) { this.attributes[key] = value; if (key === "hidden") this.hidden = true; }
  getAttribute(key) { return this.attributes[key] ?? null; }
  removeAttribute(key) { delete this.attributes[key]; }
  hasAttribute(key) { return key in this.attributes; }
  focus() { document.activeElement = this; }
  contains(child) { return child === this || this.children.some(x => x.contains(child)); }
  getBoundingClientRect() {
    const index = this.parentNode?.children.indexOf(this) ?? 0;
    const top = this.getAttribute("role") === "option" ? index * 60 - (this.parentNode?.scrollTop ?? 0) : 0;
    return {top, left: 0, width: 640, height: this.getAttribute("role") === "listbox" ? 540 : 60};
  }
  getClientRects() { return this.hidden ? [] : [this.getBoundingClientRect()]; }
  querySelectorAll() { return all(this).filter(x=>["button","input","select","textarea","a"].includes(x.tag)||x.hasAttribute("tabindex")); }
}
function all(root = document.body) { return [root, ...root.children.flatMap(x => all(x))]; }
const workspaceId = 'fixture-workspace';
const harnessDocument = Object.assign(new Element('html'), {dataset: {workspaceId}});
globalThis.document = {
  body: new Element(), activeElement: null,
  createElement: tag => new Element(tag), createTextNode: text => new Element("#text", text),
  createDocumentFragment: () => new Element("#fragment"),
  getElementById: id => id === 'harness_document' ? harnessDocument : all().find(x => x.getAttribute("id") === id),
};
globalThis.HTMLElement = Element;
globalThis.window = new EventTarget();
globalThis.crypto ??= webcrypto;
const storage = new Map();
globalThis.sessionStorage = {
  getItem: key => storage.get(key) ?? null,
  setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key),
};
// Keep timeout publication controllable; no wall-clock waits in state tests.
const timers = [];
globalThis.setTimeout = callback => { timers.push(callback); return timers.length; };
const spotlight = await import(pathToFileURL(process.argv[2]).href);
const commands = await import(pathToFileURL(process.argv[3]).href);
const browserClients = await import(pathToFileURL(process.argv[4]).href);
const overlays = await import(new URL("./overlays.mjs",pathToFileURL(process.argv[4])));
const {workspace_storage_key} = await import(new URL('./workspace_storage.mjs',pathToFileURL(process.argv[4])));
const keyEvent = (code, extra = {}) => ({code, key: code, metaKey:false, altKey:false,
  ctrlKey:false, shiftKey:false, repeat:false, isComposing:false, ...extra});
const options = () => all().filter(x => x.getAttribute("role") === "option");
const selected = () => options().find(x => x.getAttribute("aria-selected") === "true");
const input = () => all().find(x => x.tag === "input");
const result = i => ({id:`conversation:${String(i).padStart(2,"0")}`, session:`s${i}`,
  kind:"conversation", title:`Conversation ${i}`, subtitle:"Conversation", rank:0n, available:true});
function fixture() {
  document.body.replaceChildren();
  const root = new Element(), toolbar = new Element();
  document.body.append(root, toolbar);
  const requests = [], actions = [], releases = [];
  const state = {session:"original", title:"Original", commands:[
    {name:"help",owner:"core_commands",revision:"A",usage:"/help"},
    {name:"theme",owner:"core",revision:"T",usage:"/theme"}], views:[]};
  root.harnessBridge = {
    toolbar, state: () => state,
    claim: (owner, panel, close) => true,
    release: (owner, restore) => { releases.push({owner,restore}); },
    api: (method,path,payload,done) => { requests.push({method,path,payload,done}); },
    navigate: (item,done) => { actions.push({item,done}); },
    command: (session,text,expected,done) => { actions.push({session,text,expected,done}); },
  };
  root.harnessOwner = "fixture:1";
  spotlight.main(root);
  const control = root.harnessController;
  return {root, state, requests, actions, releases, control};
}
let f = fixture();
assert.equal(f.control.key(keyEvent("KeyK",{metaKey:true,isComposing:true})),false);
f.control.key(keyEvent("KeyK",{metaKey:true}));
assert.equal(f.requests.length,1);
f.requests[0].done(200n,{results:Array.from({length:14},(_,i)=>result(i)),partial:false});
assert.equal(options().length,20);
assert.match(selected().textContent,/Conversation 0/);
for(let i=0;i<10;i++) f.control.key(keyEvent("ArrowDown"));
assert.match(selected().textContent,/Conversation 10/);
assert.ok(all().find(x=>x.getAttribute("role")==="listbox").scrollTop>0);
assert.equal(options()[9].children.at(-1).textContent,"");
f.control.key(keyEvent("Digit9",{metaKey:true,altKey:true}));
f.control.key(keyEvent("Enter"));
assert.equal(f.actions.length,1,"activation latch must reject a second dispatch");
assert.equal(f.actions[0].item.session,"s8","digit shortcuts address the original top nine after scrolling");
f.actions[0].done(200n,{});
assert.equal(f.releases.at(-1).restore,false);

// A response from a dismissed opening with the same query must not publish.
f.control.key(keyEvent("KeyK",{metaKey:true}));
const old=f.requests.at(-1);
f.control.key(keyEvent("Escape"));
f.control.key(keyEvent("KeyK",{metaKey:true}));
old.done(200n,{results:[result(99)],partial:false});
assert.equal(options().length,0);
f.requests.at(-1).done(200n,{results:[result(1)],partial:false});
assert.match(options()[0].textContent,/Conversation 1/);
assert.equal(f.control.key(keyEvent("Enter",{isComposing:true})),false);
assert.equal(f.actions.length,1);
f.control.dispose();
assert.equal(f.control.key(keyEvent("KeyK",{metaKey:true})),false);
assert.equal(f.releases.at(-1).restore,true);

// A timed-out source cannot reorder the first displayed numbers when it
// eventually responds. Removed commands keep their original disabled slot.
f=fixture(); f.control.key(keyEvent("KeyK",{metaKey:true}));
const delayed=f.requests.at(-1);
timers.at(-1)();
const initial=options().map(x=>x.textContent);
delayed.done(200n,{results:[result(99)],partial:false});
assert.deepEqual(options().map(x=>x.textContent),initial);
const helpIndex=options().findIndex(x=>x.textContent.startsWith("Help"));
const helpBadge=options()[helpIndex].children.at(-1).textContent;
f.state.commands=f.state.commands.filter(x=>x.name!=="help");
f.control.update({});
assert.equal(options().length,initial.length);
assert.equal(options()[helpIndex].getAttribute("aria-disabled"),"true");
assert.equal(options()[helpIndex].children.at(-1).textContent,helpBadge);
f.control.key(keyEvent(`Digit${helpIndex+1}`,{metaKey:true,altKey:true}));
assert.equal(f.actions.length,0);
f.control.dispose();

// Theme captures target and displayed identity even if the host selection moves.
f=fixture(); f.control.key(keyEvent("KeyK",{metaKey:true}));
f.requests.at(-1).done(200n,{results:[],partial:false});
const theme=options().find(x=>x.textContent.startsWith("Change theme"));
theme.dispatchEvent(new Event("click"));
assert.equal(options().length,2);
input().value="da";
input().dispatchEvent(new Event("input"));
assert.equal(options().length,1);
f.control.key(keyEvent("Escape"));
assert.equal(input().value,"");
assert.match(selected().textContent,/Change theme/);
f.state.session="different";
f.control.key(keyEvent("Enter"));
assert.equal(input().value,"da","choice filter must survive returning to the parent step");
f.control.key(keyEvent("Digit1",{metaKey:true,altKey:true}));
assert.equal(f.actions[0].session,"original");
assert.equal(f.actions[0].expected.revision,"T");
assert.equal(f.actions[0].text,"/theme dark");
f.state.pendingCommand={request_id:"unknown"};
f.actions[0].done(0n,{message:"Unknown acceptance"});
f.control.update({}); // Pending receipt changes availability once.
const unchangedOption=options()[0];
f.control.update({revision:"status-only"});
assert.match(document.body.textContent,/Unknown acceptance/);
assert.equal(options()[0],unchangedOption,"unrelated status pushes must not rebuild results");
f.state.commands=[];
f.control.update({});
assert.match(document.body.textContent,/Unknown acceptance/,"availability updates must preserve action feedback");
input().value="d"; input().dispatchEvent(new Event("input"));
assert.match(document.body.textContent,/Unknown acceptance/,"query edits must not hide a latched unknown outcome");
f.control.key(keyEvent("Enter"));
assert.equal(f.actions.length,1,"uncertain activation must remain latched");
f.state.pendingCommand=null;
f.control.update({});
assert.equal(f.releases.at(-1).restore,true,"recovered admission must dismiss the pending launcher");
f.control.dispose();

// Empty-query actions stay in the top nine, and exact-title actions beat
// same-title conversations even when the workspace has many matches.
f=fixture(); f.control.key(keyEvent("KeyK",{metaKey:true}));
f.requests.at(-1).done(200n,{results:Array.from({length:50},(_,i)=>({...result(i),rank:6n,activity:"2026-10-23"})),partial:false});
assert.equal(options().length,50);
assert.ok(options().slice(0,9).some(x=>x.textContent.startsWith("New conversationAction")));
input().value="New conversation"; input().dispatchEvent(new Event("input"));
f.requests.at(-1).done(200n,{results:Array.from({length:50},(_,i)=>({...result(i),title:"New conversation",rank:0n,activity:"2026-10-23"})),partial:false});
assert.equal(options().length,50);
assert.match(options()[0].textContent,/^New conversationAction/);
f.control.dispose();

// Command identity survives reload and receipt recovery after replacement.
f=fixture(); f.state.session="";
f.control.key(keyEvent("KeyK",{metaKey:true}));
f.requests.at(-1).done(200n,{results:[],partial:false});
options().find(x=>x.textContent.startsWith("Change theme")).dispatchEvent(new Event("click"));
assert.match(document.body.textContent,/New tools conversation on submit/);
assert.equal(f.actions.length,0,"opening a choice step must not create a conversation");
f.control.dispose();

const requests=[];
const api=(method,path,body,done)=>{requests.push({method,path,body,done});};
let client=commands.create_commands(api,()=>{});
commands.configure_commands(client,"workspace");
const expected={name:"help",owner:"core_commands",revision:"A"};
let outcome;
commands.dispatch_command(client,"original","/help",expected,(code,data)=>{outcome=code;},null,true);
assert.match(requests[0].path,/sessions\/original\/commands$/,"command preflight must not fetch a transcript snapshot");
let localRefusal;
commands.dispatch_command(client,"other","/help",expected,(code,data)=>{localRefusal={code,data};});
assert.equal(localRefusal.code,409n);
assert.equal(localRefusal.data.not_sent,true);
requests.shift().done(200n,{nextCommandSeq:"1"});
const post=requests.shift();
assert.equal(post.method,"POST");
assert.equal(post.body.expected_command.revision,"A");
post.done(0n,{message:"Response lost"});
assert.equal(outcome,0n);
assert.ok(client.pending);
assert.ok(storage.size);
requests.shift().done(404n,{message:"Unknown"});
commands.dispatch_command(client,"other","/help",{...expected,revision:"B"},(code)=>{outcome=code;});
assert.equal(outcome,409n);
assert.equal(requests.filter(x=>x.method==="POST").length,0);
requests.shift().done(404n,{});
const settled=[];
client=commands.create_commands(api,()=>{},(envelope,receipt)=>{settled.push({envelope,receipt});});
commands.configure_commands(client,"workspace");
const recovery=requests.shift();
assert.match(recovery.path,/sessions\/original\/requests\/.+kind=command/);
recovery.done(200n,{id:"c1",expectedCommand:expected});
assert.equal(client.pending,null);
assert.equal(storage.size,0);
assert.equal(settled[0].envelope.session,"original");
assert.equal(settled[0].envelope.clear_composer,true);
storage.set(workspace_storage_key(workspaceId,"gene-harness/command-pending/corrupt"),"not JSON");
const corrupt=commands.create_commands(api,()=>{});
commands.configure_commands(corrupt,"corrupt");
assert.equal(corrupt.pending.invalid,true);
commands.dispatch_command(corrupt,"original","/help",expected,code=>{outcome=code;});
assert.equal(outcome,409n);
assert.equal(requests.length,0,"corrupt recovery data must not allow another command");
assert.equal(commands.forget_command(corrupt),true,"explicit inspection acknowledgement must unlock corrupt recovery data");
assert.equal(corrupt.pending,null);
let forgottenReload=commands.create_commands(api,()=>{});
commands.configure_commands(forgottenReload,"corrupt");
assert.equal(forgottenReload.pending,null);
commands.dispatch_command(corrupt,"original","/help",expected,(code,data)=>{localRefusal={code,data};});
assert.equal(commands.forget_command(corrupt),false,"an in-flight dispatch cannot be forgotten");
requests.shift().done(0n,{message:"Preflight lost"});
assert.equal(localRefusal.data.not_sent,true);
assert.equal(corrupt.pending,null,"a failed preparation must not retain a submission");
commands.dispatch_command(corrupt,"original","/help",expected,()=>{});
requests.shift().done(200n,{nextCommandSeq:"1"});
requests.shift().done(0n,{});
assert.equal(commands.forget_command(corrupt),false,"an in-flight receipt lookup cannot be forgotten");
requests.shift().done(404n,{});
assert.ok(corrupt.pending,"a missing receipt must remain unknown until explicit acknowledgement");
assert.equal(commands.forget_command(corrupt),true);
assert.equal(requests.length,0,"forgetting must never replay a POST");
storage.clear();

// Locally refused confirmations can be retried; an uncertain POST remains
// disabled until the operator inspects the host.
document.body.replaceChildren();
const confirmationRoot=new Element(); confirmationRoot.setAttribute("id","harness_root");
const noticeTarget=new Element(); noticeTarget.setAttribute("id","notice");
const confirmationTarget=new Element(); document.body.append(confirmationRoot,noticeTarget,confirmationTarget);
const {create_confirmations,command_confirmation}=await import(new URL("./confirmations.mjs",pathToFileURL(process.argv[4])));
const {create_notices}=await import(new URL("./notices.mjs",pathToFileURL(process.argv[4])));
let confirmationCalls=0;
const confirmClient=commands.create_commands((method,path,body,done)=>{done(0n,{message:"State lookup failed"});},()=>{});
const confirmations=create_confirmations(confirmationTarget,create_notices(),(method,path,body,done)=>{
  confirmationCalls++;
  if(confirmationCalls===1) commands.dispatch_command(confirmClient,"original",body.text,null,done);
  else done(0n,{message:"POST outcome unknown"});
});
command_confirmation(confirmations,"original",{id:"stop-1",name:"stop",error_code:"confirmation_required",display:"Stop?"});
const confirmButton=all(confirmationTarget).find(x=>x.textContent==="Confirm");
const keepButton=all(confirmationTarget).find(x=>x.textContent==="Keep running");
confirmButton.dispatchEvent(new Event("click"));
assert.equal(confirmButton.disabled,false);
assert.equal(keepButton.disabled,false);
confirmButton.dispatchEvent(new Event("click"));
assert.equal(confirmButton.disabled,true);
assert.equal(keepButton.disabled,false);
storage.clear();

// Lifecycle-managed loading invokes the Gene entry once per mount, including
// when the module itself is cached. Disable removes its modal and toolbar UI.
f=fixture();
f.control.dispose();
document.body.replaceChildren();
const hostRoot=new Element(); hostRoot.setAttribute("id","harness_root");
document.body.append(hostRoot);
const bridge=f.root.harnessBridge;
const toolbar=bridge.toolbar; document.body.append(toolbar);
const host=browserClients.create_clients(hostRoot,false,bridge);
const descriptor={name:"spotlight",owner:"spotlight",revision:"one",url:pathToFileURL(process.argv[2]).href,stylesheet:""};
async function settledMount(predicate) {
  for(let i=0;i<1000&&!predicate();i++) await new Promise(setImmediate);
  assert.ok(predicate(),"browser contribution did not settle");
}
browserClients.update_clients(host,[descriptor],{});
browserClients.update_clients(host,[],{});
await new Promise(setImmediate);
assert.equal(toolbar.children.length,0,"a revoked pending mount must not attach UI");
browserClients.update_clients(host,[descriptor],{});
await settledMount(()=>!!host.mounts.spotlight?.root?.harnessController);
assert.equal(toolbar.children.length,1);
browserClients.update_clients(host,[descriptor],{});
assert.equal(toolbar.children.length,1);
browserClients.update_clients(host,[],{});
assert.equal(toolbar.children.length,0);
browserClients.update_clients(host,[{...descriptor,revision:"two"}],{});
await settledMount(()=>!!host.mounts.spotlight?.root?.harnessController);
assert.equal(toolbar.children.length,1);
browserClients.update_clients(host,[],{});
assert.equal(toolbar.children.length,0);
// Cleanup is still host-owned if a plugin fails before publishing a disposer.
const errors=[]; const originalError=console.error;
console.error=message=>{errors.push(message);};
browserClients.update_clients(host,[{...descriptor,revision:"broken",url:pathToFileURL(process.argv[5]).href}],{});
const brokenRoot=host.mounts.spotlight.root;
await settledMount(()=>host.mounts.spotlight?.failed);
assert.equal(toolbar.children.length,0,"failed mount leaked toolbar UI");
assert.equal(brokenRoot.harnessCleanups,1n);
assert.equal(errors.length,1);
browserClients.update_clients(host,[{...descriptor,revision:"broken",url:pathToFileURL(process.argv[5]).href}],{});
await new Promise(setImmediate);
assert.equal(errors.length,1,"failed revision retried itself on a status update");
console.error=originalError;
browserClients.update_clients(host,[],{});
assert.equal(brokenRoot.harnessCleanups,1n,"failed mount must not be disposed a second time");
const safe=browserClients.create_clients(hostRoot,true,bridge);
browserClients.update_clients(safe,[descriptor],{});
assert.deepEqual(Object.keys(safe.mounts),[]);

// Focus return must use a surviving host control when the invoking plugin
// button and its fallback have both been removed during unmount.
document.body.replaceChildren();
const focusRoot=new Element(); focusRoot.setAttribute("id","harness_root");
const picker=new Element("select"); picker.setAttribute("id","ui_view_picker");
const oldButton=new Element("button"), fallback=new Element("button"), panel=new Element();
focusRoot.append(picker,oldButton,fallback);
document.body.append(focusRoot,panel);
for(const id of ["confirmations","notification_center","trigger_drawer","status_drawer"]) {
  const drawer=new Element(); drawer.setAttribute("id",id); drawer.hidden=true; focusRoot.append(drawer);
}
oldButton.focus();
assert.equal(overlays.claim_modal("focus-owner",focusRoot,panel,()=>{},fallback),true);
assert.equal(focusRoot.inert,true);
focusRoot.removeChild(oldButton); focusRoot.removeChild(fallback);
overlays.release_modal("focus-owner",true);
assert.equal(document.activeElement,picker);
assert.equal(focusRoot.inert,false);
picker.hidden=true;
const composer=new Element("textarea"), removed=new Element("button");
focusRoot.append(composer,removed); removed.focus();
assert.equal(overlays.claim_modal("hidden-bar",focusRoot,panel,()=>{},fallback),true);
focusRoot.removeChild(removed);
overlays.release_modal("hidden-bar",true);
assert.equal(document.activeElement,composer,"focus must not return to the hidden host bar");
console.log("Spotlight controller and command recovery checks passed");
