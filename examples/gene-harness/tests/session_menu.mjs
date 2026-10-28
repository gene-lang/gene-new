import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor(tag='div',text='') {super();this.tag=tag;this.text=text;this.children=[];this.attributes={};
    this.hidden=false;this.disabled=false;this.value='';this.style={setProperty:(key,value)=>this.attributes[key]=value};}
  append(...nodes){nodes.forEach(node=>this.appendChild(node));}
  appendChild(node){if(node.parentNode)node.parentNode.removeChild(node);this.children.push(node);node.parentNode=this;return node;}
  removeChild(node){this.children.splice(this.children.indexOf(node),1);node.parentNode=null;}
  replaceChildren(){for(const child of this.children)child.parentNode=null;this.children=[];this.text='';}
  get textContent(){return this.text+this.children.map(child=>child.textContent).join('');}
  set textContent(value){this.replaceChildren();this.text=value;}
  setAttribute(key,value){this.attributes[key]=value;if(key==='hidden')this.hidden=true;if(key==='disabled')this.disabled=true;}
  getAttribute(key){return this.attributes[key]??null;}
  hasAttribute(key){return key==='disabled'?this.disabled:Object.hasOwn(this.attributes,key);}
  contains(node){return node===this||this.children.some(child=>child.contains(node));}
  querySelectorAll(){return this.children.flatMap(child=>[child,...child.querySelectorAll()]).filter(child=>['button','input','select','textarea','a'].includes(child.tag));}
  getClientRects(){return this.hidden?[]:[{}];}
  getBoundingClientRect(){return {left:100,top:100,width:this.tag==='button'?30:220,height:this.tag==='button'?30:180};}
  focus(){document.activeElement=this;}
}
const body=new Element('body');
Object.assign(globalThis,{HTMLElement:Element,document:{body,activeElement:body,
  createElement:tag=>new Element(tag),createTextNode:text=>new Element('#text',text),
  createDocumentFragment:()=>new Element('#fragment')},window:Object.assign(new EventTarget(),{innerWidth:1000,innerHeight:800})});
const mod=await import(pathToFileURL(process.argv[2]));
const requests=[],updates=[],deleted=[];
const menu=mod.create_session_menu((method,path,data,done)=>{requests.push({method,path,data,done});},
  data=>{updates.push(data);},ids=>{deleted.push(ids);});
const buttons=()=>menu.panel.querySelectorAll().filter(node=>node.tag==='button'&&!node.hidden);
const choose=label=>buttons().find(node=>node.textContent===label).dispatchEvent(new Event('click'));
const anchor=new Element('button');body.append(anchor);
const session={id:'a',title:'First',revision:'2',pinned:false};
mod.open_session_menu(menu,anchor,session);
assert.deepEqual(buttons().map(node=>node.textContent),['Rename','Delete','Pin']);
assert.equal(anchor.attributes['aria-expanded'],'true');
choose('Rename');
const input=menu.panel.querySelectorAll().find(node=>node.tag==='input');
assert.equal(input.value,'First');input.value='My renamed conversation';
const replacementAnchor=new Element('button');body.append(replacementAnchor);
mod.bind_session_menu(menu,replacementAnchor,{...session,revision:'3'});
mod.finish_session_menu_render(menu);
assert.equal(input.value,'My renamed conversation','a list refresh must retain the rename draft');
menu.panel.children.find(node=>node.tag==='form').dispatchEvent(new Event('submit'));
assert.equal(requests[0].path,'/api/v8/sessions/a');
assert.equal(requests[0].method,'PATCH');
assert.deepEqual(requests[0].data,{title:'My renamed conversation',revision:'3'});
requests[0].done(409n,{message:'Conversation changed.'});
assert.match(menu.panel.textContent,/Conversation changed/);
assert.equal(input.disabled,false,'failed requests leave the form usable');
menu.panel.children.find(node=>node.tag==='form').dispatchEvent(new Event('submit'));
requests[1].done(200n,{...session,title:input.value,revision:'4'});
assert.equal(updates[0].title,'My renamed conversation');
assert.equal(menu.panel.hidden,true);
assert.equal(document.activeElement,replacementAnchor);
mod.open_session_menu(menu,anchor,session);choose('Pin');
assert.equal(requests.at(-1).data.pinned,true);
requests.at(-1).done(200n,{...session,pinned:true,revision:'3'});
mod.open_session_menu(menu,anchor,{...session,pinned:true});
assert.ok(buttons().some(node=>node.textContent==='Unpin'));
choose('Delete');
const before=requests.length;
assert.match(menu.panel.textContent,/permanently deletes/);
choose('Cancel');assert.equal(requests.length,before);
mod.open_session_menu(menu,anchor,session);choose('Delete');choose('Delete');
assert.equal(requests.at(-1).method,'DELETE');
requests.at(-1).done(200n,{deleted:['a','child']});
assert.deepEqual(deleted,[['a','child']]);
mod.open_session_menu(menu,anchor,session);
const down=Object.assign(new Event('keydown'),{key:'ArrowDown'});window.dispatchEvent(down);
assert.equal(document.activeElement.textContent,'Delete');
window.dispatchEvent(Object.assign(new Event('keydown'),{key:'Escape'}));
assert.equal(menu.panel.hidden,true);assert.equal(document.activeElement,anchor);
mod.open_session_menu(menu,anchor,session);window.dispatchEvent(new Event('click'));
assert.equal(menu.panel.hidden,true);
for (const revision of [0n,2n,'0','2',undefined]) {
  mod.open_session_menu(menu,anchor,{...session,revision});choose('Rename');
  const title=menu.panel.querySelectorAll().find(node=>node.tag==='input');title.value='Numeric revision rename';
  menu.panel.children.find(node=>node.tag==='form').dispatchEvent(new Event('submit'));
  const request=requests.at(-1);
  assert.equal(request.data.revision,revision===undefined?'0':String(revision));
  assert.equal(request.data.title,'Numeric revision rename');
  request.done(200n,{...session,title:title.value,revision:'3'});
  assert.equal(menu.pending,false);
  assert.equal(menu.panel.hidden,true);
}
console.log('session menu: rename drafts, revisions, errors, pin toggling, delete confirmation and keyboard/outside dismissal passed');

const browserSession={...session,id:'browser a&b',kind:'interactive',status:'done',slack_available:true};
mod.open_session_menu(menu,anchor,browserSession);
assert.deepEqual(buttons().map(node=>node.textContent),['Add to Slack','Rename','Delete','Pin']);
assert.equal(document.activeElement.textContent,'Add to Slack');
choose('Add to Slack');
const shareRequest=requests.at(-1);
assert.equal(shareRequest.method,'POST');
assert.equal(shareRequest.path,'/api/v8/sessions/browser%20a%26b/slack');
assert.deepEqual(shareRequest.data,{revision:'2'});
assert.equal(menu.pending,true);
choose('Add to Slack');
assert.equal(requests.at(-1),shareRequest,'duplicate clicks cannot create another request');
shareRequest.done(503n,{message:'Slack is unavailable.'});
assert.equal(menu.pending,false);
assert.equal(buttons()[0].disabled,false);
assert.match(menu.panel.textContent,/Slack is unavailable/);
choose('Add to Slack');
requests.at(-1).done(202n,{...browserSession,revision:'3',slack_share:{status:'pending'}});
assert.equal(menu.panel.hidden,true);
assert.equal(updates.at(-1).id,browserSession.id);
mod.open_session_menu(menu,anchor,{...browserSession,slack_share:{status:'accepted'}});
assert.equal(buttons()[0].textContent,'Adding to Slack…');
assert.equal(buttons()[0].disabled,true);
for (const [status,label] of [['failed','Slack share failed'],['uncertain','Slack share needs attention'],['pending','Adding to Slack…']]) {
  mod.bind_session_menu(menu,anchor,{...browserSession,slack_share:{status}});
  assert.equal(buttons()[0].textContent,label);
  assert.equal(buttons()[0].disabled,true,'durable shares require owner reconciliation before retry');
}
mod.bind_session_menu(menu,anchor,{...browserSession,channel:{transport:'slack'}});
assert.deepEqual(buttons().map(node=>node.textContent),['Rename','Delete','Pin']);
mod.close_session_menu(menu);
for (const changes of [{slack_available:false},{kind:'child'},{channel:{transport:'slack'}},{parent:{session:'parent'}}]) {
  mod.open_session_menu(menu,anchor,{...browserSession,...changes});
  assert.equal(buttons().some(button=>button.textContent==='Add to Slack'),false);
  mod.close_session_menu(menu);
}
for (const status of ['running','waiting']) {
  mod.open_session_menu(menu,anchor,{...browserSession,status});
  assert.equal(buttons()[0].textContent,'Add to Slack');
  assert.equal(buttons()[0].disabled,true);
  mod.close_session_menu(menu);
}
console.log('Slack menu action: eligibility, target session, retries, duplicate clicks and live refresh passed');
