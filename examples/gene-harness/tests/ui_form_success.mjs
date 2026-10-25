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
const elements=new Map(),stored=new Map();
const element=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
Object.assign(globalThis,{HTMLElement:Element,document:{getElementById:element,
  createElement:()=>new Element(),createTextNode:text=>Object.assign(new Element(),{text})},
  sessionStorage:{getItem:key=>stored.get(key)??null,setItem:(key,value)=>stored.set(key,value),removeItem:key=>stored.delete(key)},
  setTimeout:()=>0});
const base=pathToFileURL(process.argv[2]);
const model=await import(new URL('model.mjs',base));
const controller=await import(new URL('controller.mjs',base));
const {Sidebar}=await import(new URL('sidebar.mjs',base));
const {create_notices}=await import(new URL('notices.mjs',base));
const noop=()=>{};
function setup(){
  stored.clear();
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
{
  const {ui,requests,finish}=setup();finish();
  assert.equal(ui.state.selected,'');
  assert.equal(ui.drafts.name,undefined);
  assert.equal(ui.forms.create,undefined);
  assert.equal(requests.at(-1).data.state.selected,'','the next render closes the creation form');
  assert.equal(JSON.parse(stored.get(model.state_key(ui))).state.selected,'','reload must not reopen it');
}
{
  const {ui,finish}=setup();finish('failed');
  assert.equal(ui.state.selected,'create','failure keeps the creation form open');
  assert.equal(ui.drafts.name.value,'calculator','failure preserves submitted text');
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
  assert.equal(JSON.parse(stored.get(original)).state.selected,'','recovery updates the saved originating view');
}
console.log('UI forms: success closure, failure preservation, newer edits/navigation and receipt recovery passed');
