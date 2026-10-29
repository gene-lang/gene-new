import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor(){super();this.children=[];this.value='';this.hidden=false;this.disabled=false;this.attributes={};}
  append(...nodes){for(const node of nodes)this.appendChild(node);}
  appendChild(node){if(node.parentNode)node.parentNode.removeChild(node);node.parentNode=this;this.children.push(node);return node;}
  removeChild(node){this.children.splice(this.children.indexOf(node),1);}
  setAttribute(key,value){this.attributes[key]=value;}
  set textContent(value){this.text=value;}
}
const elements=new Map(),stored=new Map(),timers=[];
const workspaceId='fixture-workspace';
const element=id=>{
  if(!elements.has(id)){
    const value=new Element();
    if(id==='harness_document')value.dataset={workspaceId};
    elements.set(id,value);
  }
  return elements.get(id);
};
Object.assign(globalThis,{HTMLElement:Element,document:{getElementById:element,
  createElement:()=>new Element(),createTextNode:text=>Object.assign(new Element(),{text})},
  sessionStorage:{getItem:key=>stored.get(key)??null,setItem:(key,value)=>stored.set(key,value),removeItem:key=>stored.delete(key)},
  setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length;}});
const base=pathToFileURL(process.argv[2]);
const model=await import(new URL('model.mjs',base));
const controller=await import(new URL('controller.mjs',base));
const {Sidebar}=await import(new URL('sidebar.mjs',base));
const {create_notices}=await import(new URL('notices.mjs',base));
const {workspace_storage_key}=await import(new URL('workspace_storage.mjs',base));
const scoped=key=>workspace_storage_key(workspaceId,key);
const noop=()=>{};
function setup(){
  stored.clear();elements.clear();timers.length=0;
  const requests=[],root=new Element();
  const sidebar=new Sidebar({root,desktop_open:true,mobile_open:false,full_view:false,available:true,safe:false,
    signature:'',widgets:{},target:root,pool:root,buttons:[]});
  const navigation=new model.UiNavigation({workspace:'test',active:'workspaces',last_view:'',presentation:'full',
    remembered:{},versions:{},snapshots:{},views:[],side:'left',width:50n,bar_hidden:false,focus:'name',scroll:0,
    focus_pending:false,action_generation:1n,action_revision:'',sidebar,restore:noop,refresh:noop});
  const ui=new model.UiClient({root,target:root,safe:false,ready:true,session:'',workspace:'test',epoch:'host',
    metadata_revision:'1',rendered_revision:'r1',descriptor:{name:'workspaces',revision:'r1',data_revision:'d1',functions:{save:'f1'}},
    settings:{},instance:'instance',version:'2',notices:create_notices(),state:{selected:'create'},
    drafts:{name:{name:'name',form:'create',value:'calculator'}},forms:{create:{named:{operation:'create'},positional:[]}},
    nodes:{},generation:0n,sequence:0n,debounce:0n,last_data:'d1',loading:false,render_error:false,pending:null,
    resolving:false,navigation,navigate:noop,api:(method,path,data,done)=>{requests.push({method,path,data,done});},
    select:noop,command:noop,prompt:noop,appearance:'light'});
  const form=new model.UiNode({key:'create',tag:'form',element:root,
    props:{action:'save',args:{operation:'create'},'success-state':{selected:''}},form:'',seen:0n});
  const input=new Element();input.value='calculator';
  ui.nodes={create:form,name:new model.UiNode({key:'name',tag:'input',element:input,props:{field:'name'},form:'create',seen:0n})};
  controller.submit_action(ui,form);
  assert.deepEqual(ui.pending.success_state,{selected:''},'submission captures its form success patch');
  const pending=ui.pending;
  const finish=(status='done')=>controller.accept_receipt(ui,{id:'command',input_id:pending.request.input_id,status,display:'Name exists.'});
  return {ui,requests,pending,finish};
}
const progress=()=>{
  const ready=timers.filter(timer=>timer.ms===500);
  for(const timer of ready){timers.splice(timers.indexOf(timer),1);timer.fn();}
};
const notices=ui=>Object.values(ui.notices.items);
{
  const {ui,requests,finish}=setup();finish();
  assert.equal(ui.state.selected,'');
  assert.equal(ui.drafts.name,undefined);
  assert.equal(ui.forms.create,undefined);
  assert.equal(requests.at(-1).data.state.selected,'','the next render closes the creation form');
  assert.equal(JSON.parse(stored.get(scoped(model.state_key(ui)))).state.selected,'','reload must not reopen it');
  progress();
  assert.equal(notices(ui).length,0,'fast successes stay quiet even after their delayed timers run');
}
{
  const {ui,finish}=setup();finish('failed');
  assert.equal(ui.state.selected,'create','failure keeps the creation form open');
  assert.equal(ui.drafts.name.value,'calculator','failure preserves submitted text');
  progress();
  assert.equal(notices(ui).length,1);
  assert.equal(notices(ui)[0].text,'Name exists.','a delayed timer cannot overwrite a failure');
  assert.equal(notices(ui)[0].sticky,true);
}
{
  const {ui,finish}=setup();ui.drafts.name.value='another-name';finish();
  assert.equal(ui.state.selected,'create','success must not close newer edits');
  assert.equal(ui.drafts.name.value,'another-name');
}
{
  const {ui,finish}=setup();ui.state.selected='edit/other';finish();
  assert.equal(ui.state.selected,'edit/other','an older receipt must not overwrite newer navigation');
}
{
  const {ui,pending,finish}=setup();
  ui.forms.create={named:{operation:'create',revision:'new'},positional:[]};finish();
  assert.equal(ui.state.selected,'create','a newer form context must be preserved');
  assert.equal(ui.drafts.name.value,pending.request.named.name);
}
{
  const {ui,pending,requests}=setup();
  ui.pending=model.copy_map(pending);
  controller.resolve_action(ui,false);
  assert.equal(requests.at(-1).method,'GET');
  requests.at(-1).done(200n,{id:'command',input_id:pending.request.input_id,status:'done'});
  assert.equal(ui.state.selected,'','recovered receipts also close a successful form');
}
{
  const {ui,finish}=setup();model.persist_view(ui);
  const original=model.state_key(ui);
  ui.descriptor={name:'another',revision:'r2',data_revision:'d2'};ui.version='1';ui.state={selected:'other'};
  finish();
  assert.equal(ui.state.selected,'other');
  assert.equal(JSON.parse(stored.get(scoped(original))).state.selected,'','recovery updates the saved originating view');
}
{
  const {ui,pending,finish}=setup();
  assert.equal(notices(ui).length,0,'new actions do not immediately show progress');
  controller.accept_receipt(ui,{id:'command',input_id:pending.request.input_id,status:'accepted'});
  controller.accept_receipt(ui,{id:'command',input_id:pending.request.input_id,status:'running'});
  progress();
  assert.equal(notices(ui).length,1,'multiple receipts update one progress notice');
  assert.equal(notices(ui)[0].text,'Working…');
  finish();
  assert.equal(notices(ui).length,0,'success removes its progress notice');
  assert.equal(element('ui_action_status').children.length,0);
  progress();assert.equal(notices(ui).length,0);
}
{
  const {ui,requests,pending,finish}=setup();
  requests[0].done(500n,{});
  const warning=notices(ui)[0];
  const warningText=warning.text;
  assert.equal(warning.severity,'error');assert.equal(warning.sticky,true);
  assert.equal(typeof warning.action,'function','unknown outcomes retain recovery');
  assert.equal(ui.pending.request.input_id,pending.request.input_id);
  progress();
  assert.equal(notices(ui)[0].text,warningText,'uncertain outcomes keep their warning after 500 ms');
  controller.resolve_action(ui,false);
  requests.at(-1).done(200n,{id:'command',input_id:pending.request.input_id,status:'running'});
  assert.equal(ui.pending.uncertain,false,'an authoritative receipt resolves transport uncertainty');
  progress();assert.equal(notices(ui)[0].text,'Working…');
  finish();assert.equal(notices(ui).length,0);
}
{
  const {ui,pending,finish}=setup();finish('failed');
  const first=notices(ui)[0];
  ui.loading=false;
  controller.submit_action(ui,ui.nodes.create);
  const next=ui.pending;
  assert.notEqual(next.request.input_id,pending.request.input_id);
  progress();
  assert.equal(notices(ui).length,2,'new progress does not replace a previous failure');
  assert.equal(first.text,'Name exists.','an older timer must not rewrite a previous failure');
  assert.ok(notices(ui).some(item=>item.origin.action_id===next.request.input_id&&item.text==='Working…'));
  controller.accept_receipt(ui,{id:'next-command',input_id:next.request.input_id,status:'done'});
  assert.equal(notices(ui).length,1);
  assert.equal(notices(ui)[0],first,'success clears only its own notice');
}
{
  const {ui,requests,pending}=setup();
  controller.accept_receipt(ui,{id:'command',input_id:pending.request.input_id,status:'running'});
  controller.resolve_action(ui,false);
  requests.at(-1).done(404n,{});
  const warning=notices(ui)[0].text;
  progress();
  assert.equal(notices(ui)[0].text,warning,'a missing receipt keeps its recovery warning');
}
{
  const {ui,finish}=setup();finish();
  const button=new model.UiNode({key:'digit',tag:'button',element:new Element(),props:{action:'save',args:{digit:'2'}},form:'',seen:0n});
  for(let i=0;i<20;i++){
    ui.loading=false;
    controller.submit_action(ui,button);
    controller.accept_receipt(ui,{id:'key-'+i,input_id:ui.pending.request.input_id,status:'done'});
  }
  progress();
  assert.equal(notices(ui).length,0,'repeated keypad actions produce no success stack or stale progress');
}
console.log('UI forms/actions: success closure, draft preservation, recovery, quiet rapid actions, delayed progress and error isolation passed');
