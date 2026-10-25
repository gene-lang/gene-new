import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor(tag='div',text=''){super();this.tag=tag;this.text=text;this.children=[];this.attributes={};this.hidden=false;this.disabled=false;this.value='';}
  append(...nodes){nodes.forEach(node=>this.appendChild(node));}
  appendChild(node){if(node.parentNode)node.parentNode.removeChild(node);this.children.push(node);node.parentNode=this;return node;}
  removeChild(node){this.children.splice(this.children.indexOf(node),1);node.parentNode=null;}
  replaceChildren(){for(const child of this.children)child.parentNode=null;this.children=[];this.text='';}
  get textContent(){return this.text+this.children.map(child=>child.textContent).join('');}
  set textContent(value){this.replaceChildren();this.text=value;}
  setAttribute(key,value){this.attributes[key]=value;if(key==='hidden')this.hidden=true;if(key==='disabled')this.disabled=true;}
  focus(){document.activeElement=this;}
}
const elements=new Map(),stored=new Map(),requests=[],timers=[];
const element=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
Object.assign(globalThis,{HTMLElement:Element,document:{body:new Element('body'),getElementById:element,
  createElement:tag=>new Element(tag),createTextNode:text=>new Element('#text',text),
  createDocumentFragment:()=>new Element('#fragment')},
  sessionStorage:{getItem:key=>stored.get(key)??null,setItem:(key,value)=>{stored.set(key,value);},removeItem:key=>{stored.delete(key);}},
  setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length;}});
const base=pathToFileURL(process.argv[2]);
const notices=await import(new URL('notices.mjs',base));
const centers=await import(new URL('notification_center.mjs',base));
const producers=await import(new URL('producer_inbox.mjs',base));
const {create_question_editors}=await import(new URL('question_editors.mjs',base));
const api=(method,path,data,done)=>{requests.push({method,path,data,done});};
const local=notices.create_notices();
const questions=create_question_editors(local,api,()=>{});
const center=centers.create_center(local,questions,api,()=>{});
const inbox=producers.create_producer_inbox(local,false,api,count=>{center.new_messages=count;centers.update_center_count(center);},()=>{},()=>{});
const click=node=>node.dispatchEvent(new Event('click'));
const descendants=node=>[node,...node.children.flatMap(descendants)];
const dismiss=node=>descendants(node).find(child=>child.attributes['aria-label']==='Dismiss message');
const add=(key,action=null)=>notices.put_notice(local,element('notice'),'view','','error-'+key,
  "function 'add_task' expects 1..1 argument(s), got 0",'error',true,{component:'task_tool'},action);
add('one');add('two');
assert.equal(element('notice').children.length,2);
assert.equal(element('notification_local').children.length,2);
assert.equal(element('clear_messages').disabled,false,'local feedback is clearable while disconnected');
click(dismiss(element('notice').children[0]));
assert.equal(element('notice').children.length,1);
assert.equal(element('notification_local').children.length,1,'inline dismissal updates the popup');
click(dismiss(element('notification_local').children[0]));
assert.equal(element('notice').children.length,0,'popup dismissal updates the inline banner');
assert.equal(element('clear_messages').disabled,true);
assert.match(element('notifications_count').textContent,/^0 need attention/);
let actions=0;
add('one');add('two',()=>{actions++;});
inbox.pending.original={request:{request_id:'original'}};
click(element('clear_messages'));
assert.equal(element('notice').children.length,0);
assert.equal(element('notification_local').children.length,0);
assert.equal(requests.length,0,'clearing local-only errors must not post an empty server request');
assert.equal(actions,0,'dismissal must not invoke the original action');
assert.ok(inbox.pending.original,'message clearing must not discard receipt recovery');
inbox.pending.original=undefined;
centers.center_sessions(center,[{id:'waiting',title:'Pending question',status:'waiting'}],[]);
const workflow=element('notification_workflows').children[0];
add('workflow-feedback');click(element('clear_messages'));
assert.equal(workflow.hidden,false,'clearing messages must not hide pending questions');
const message=(revision=1n)=>({id:'published',revision,title:'Published message',summary:'Details',source:'test',severity:'info',actions:[],origin:{}});
const snapshot=(revision,messages)=>({epoch:'host',revision,watermark:'1',opened:'0',messages,new_messages:BigInt(messages.length)});
inbox.ready=true;
producers.producer_event(inbox,'notifications/state','host',snapshot('1',[message()]));
assert.equal(element('notification_message_section').hidden,false);
add('mixed');click(element('clear_messages'));
assert.equal(element('notification_local').children.length,0);
assert.equal(requests.at(-1).path,'/api/v8/notifications/clear');
assert.deepEqual(requests.at(-1).data.messages,[{id:'published',revision:1n}]);
assert.equal(element('clear_messages').disabled,true);
assert.equal(element('clear_messages').textContent,'Clearing messages…');
const clearing=requests.at(-1);
producers.producer_event(inbox,'notifications/state','host',snapshot('2',[message(2n)]));
clearing.done(200n,{});
assert.equal(requests.at(-1).method,'GET');
requests.at(-1).done(200n,snapshot('2',[message(2n)]));
assert.equal(element('notification_messages').children[0].hidden,false,'a newer message revision survives clearing the old one');
click(element('clear_messages'));requests.at(-1).done(200n,{});
requests.at(-1).done(200n,snapshot('3',[]));
assert.equal(element('notification_messages').children[0].hidden,true);
assert.equal(element('notification_message_section').hidden,true);
assert.equal(element('clear_messages').disabled,true);
assert.equal(workflow.hidden,false);
assert.match(element('notifications_count').textContent,/^1 need attention/);
producers.producer_event(inbox,'notifications/state','host',snapshot('4',[message(3n)]));
click(element('clear_messages'));requests.at(-1).done(500n,{});
assert.equal(inbox.clearing,false);
assert.match(element('notice').textContent,/Clearing was not confirmed/);
assert.equal(element('clear_messages').disabled,false);
console.log('notifications: synchronized dismissal, local/mixed clearing, recovery and question preservation, revision races and failure feedback passed');
