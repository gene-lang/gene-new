// The actual emitted Markdown, grouping, and turn-view modules share these fixtures.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor(tag,text=''){super();this.tag=tag;this.text=text;this.children=[];this.attributes={};this.open=false;}
  append(...nodes){nodes.forEach(node=>this.appendChild(node));}
  appendChild(node){this.children.push(node);node.parentNode=this;return node;}
  setAttribute(key,value){this.attributes[key]=value;if(key==='open')this.open=true;}
  get textContent(){return this.text+this.children.map(node=>node.textContent).join('');}
  set textContent(value){this.text=value;this.children=[];}
}
Object.assign(globalThis,{HTMLElement:Element,document:{createElement:tag=>new Element(tag),
  createTextNode:text=>new Element('#text',text),createDocumentFragment:()=>new Element('#fragment')}});
const main=pathToFileURL(process.argv[2]);
const {markdown_view,reply_summary}=await import(new URL('markdown.mjs',main));
const {conversation_groups,bounded_blocks,merge_blocks}=await import(new URL('state.mjs',main));
const {step_view,block_view,run_status_view}=await import(new URL('view.mjs',main));
const descendants=node=>[node,...node.children.flatMap(descendants)];
for(const version of ['1','7','8','999']){
  const source=`![Generated logo](/api/v${version}/media/asset_123)`;
  const rendered=markdown_view(source);
  const nodes=descendants(rendered);
  assert.equal(nodes.find(node=>node.tag==='img').attributes.src,'/api/v8/media/asset_123');
  assert.equal(nodes.find(node=>node.tag==='img').attributes.alt,'Generated logo');
  assert.ok(nodes.some(node=>node.attributes.href==='/api/v8/media/asset_123?download=1'));
  assert.equal(reply_summary(source+'\nThe logo is ready.'),'The logo is ready.');
  assert.equal(reply_summary(source),'');
  assert.equal(reply_summary('Done. '+source),'Done.');
}
// These are Markdown files/plugin docs as well as assistant replies: never fetch
// arbitrary images or reinterpret their inner links as clickable fallbacks.
for(const destination of ['https://example.com/logo.png','//example.com/a','data:image/png;base64,abc',
  '/files/logo.png','/api/v7/media/../secret','/api/v7/media/id?redirect=elsewhere']){
  const source=`![Logo](${destination})`;
  const rendered=markdown_view(source);
  assert.equal(rendered.textContent,source);
  assert.equal(descendants(rendered).filter(node=>['img','a'].includes(node.tag)).length,0);
  const block=block_view({role:'assistant',phase:'command',text:source,view:{kind:'markdown'}},false,()=>{},false,()=>{});
  assert.equal(descendants(block).some(node=>node.tag==='img'),false);
}
const block=(phase,turn,text='',extra={})=>({id:`${phase}-${turn}`,round_id:'r',turn:BigInt(turn),
  role:'assistant',phase,text,durable:true,...extra});
const records=[block('turn/start',1),block('code',1,'(+ 1 2)'),block('card',1),
  block('reply',1,'', {media:[{id:'asset_123',kind:'image'}]}),block('turn/end',1,'',{reason:'continue'}),
  block('turn/request',2,'Read this result.'),block('turn/start',2)];
let groups=conversation_groups(records);
assert.equal(groups.length,2);
assert.equal(groups[0].blocks.length,5);
assert.equal(groups[1].blocks.length,2);
let view=step_view(groups[1].blocks,false,true,()=>{},()=>false,()=>{});
assert.equal(view.children[0].textContent,'Turn 2 · Generating response…');
assert.equal(view.open,false);
assert.ok(view.textContent.includes('Request'));
groups=conversation_groups([...records,block('code',2,'(Outcome ^^done ^reply "Ready.")',{reply_hint:'![logo](/api/v7/media/asset_123)\nReady.'}),
  block('reply',2,'Ready.',{final:true}),block('turn/end',2,'',{reason:'done'})]);
assert.equal(groups.filter(group=>group.kind==='turn').length,2);
view=step_view(groups[1].blocks,false,false,()=>{},()=>false,()=>{});
assert.equal(view.children[0].textContent,'Turn 2: Ready.');
const final=block_view(groups[2].block,false,()=>{},false,()=>{});
assert.equal(final.textContent,'AgentReady.');
const failed=step_view([block('code',3,'invalid',{reply_hint:'Unverified success'}),block('turn/end',3,'',{reason:'error'})],false,false,()=>{},()=>false,()=>{});
assert.equal(failed.children[0].textContent,'Turn 3 · Code error');
for (const source of ['![a](', 'x ![a](b']) assert.equal(reply_summary(source),source);
let status=run_status_view({state:'paused',resumable:false,continuation_stop:'failed',
  continued_by:'reserved',continuation_error:'History is unavailable.'},'',()=>{}, ()=>{});
assert.match(status.textContent,/History is unavailable/);
assert.match(status.textContent,/Send a new message/);
assert.equal(descendants(status).filter(node=>node.tag==='button').length,0);
status=run_status_view({state:'paused',resumable:false,continuation_stop:'superseded'},'',()=>{});
assert.doesNotMatch(status.textContent,/Send a new message/);
const other=block('code',1,'other',{id:'other',round_id:'another'});
groups=conversation_groups([records[0],other,records[1]]);
assert.deepEqual(groups.filter(group=>group.kind==='turn').map(group=>group.key),['r/turn-1','another/turn-1']);
assert.deepEqual(groups[0].blocks,[records[0],records[1]]);
const replacement={...records[1],text:'updated'};
assert.deepEqual(merge_blocks([records[0],records[1]],[replacement,other]),[records[0],replacement,other]);
const history=[];
for(let turn=1;turn<=605;turn++) history.push(block('turn/start',turn),block('code',turn,'(+ 1 2)'),block('turn/end',turn,'',{reason:'continue'}));
for(const latest of [true,false]){
  const retained=bounded_blocks(history,latest);
  const content=retained.filter(item=>item.phase==='code');
  assert.equal(content.length,600,'structural context must not consume visible history slots');
  assert.equal(content[0].turn,latest?6n:1n);
  assert.equal(retained.length,1800,'each retained turn keeps its start/end context');
}
console.log('conversation: receiving groups, pending headings, hints, final replies, historical media URLs and literal unsupported embeds passed');
