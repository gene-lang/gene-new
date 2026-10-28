// Exercise the emitted event bus and browser-contribution lifecycle together.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor() { super(); this.children=[]; this.attributes={}; }
  appendChild(child) { this.children.push(child); child.parentNode=this; return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child),1); child.parentNode=null; }
  setAttribute(key,value) { this.attributes[key]=value; }
}
const body=new Element();
const elements=new Map();
Object.assign(globalThis,{HTMLElement:Element,window:new EventTarget(),document:{body,
  getElementById:id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);},
  createElement:()=>new Element(),createTextNode:()=>new Element()}});
const base=pathToFileURL(process.argv[2]);
const {create_feature_events,subscribe_feature,emit_feature_event}=await import(new URL('feature_events.mjs',base));
const {create_clients,update_clients}=await import(new URL('browser_clients.mjs',base));
const events=create_feature_events();
const received=[];
const errors=[];
const originalError=console.error;
console.error=(...args)=>errors.push(args);
try {
  const revoke=subscribe_feature(events,(kind,session,data)=>{
    received.push([kind,session,data.value]); data.value='mutated';
  },'test');
  const original={value:'original'};
  emit_feature_event(events,'custom/event','background',original);
  assert.equal(original.value,'original');
  assert.deepEqual(received,[['custom/event','background','original']]);
  revoke(); revoke();
  emit_feature_event(events,'custom/event','background',original);
  assert.equal(received.length,1);
  const broken=subscribe_feature(events,()=>{throw new Error('listener failed');});
  const healthy=subscribe_feature(events,()=>{received.push('healthy');});
  emit_feature_event(events,'arbitrary/extension','',{});
  assert.equal(received.at(-1),'healthy');
  broken(); healthy();

  globalThis.featureEventCalls=[];
  globalThis.retainedFeatureBridges=[];
  const module=(version,fail=false)=>'data:text/javascript;base64,'+Buffer.from(`
    export function main(mount) {
      globalThis.retainedFeatureBridges.push(mount.harnessBridge);
      mount.harnessBridge.subscribe((kind,session)=>{
        globalThis.featureEventCalls.push([${version},kind,session]);
      });
      ${fail?'throw new Error("mount failed after subscription");':''}
      mount.harnessController={update(){},dispose(){throw new Error('cleanup failed');}};
    }`).toString('base64');
  const toolbar=new Element();
  const host=create_clients(body,false,{toolbar,
    capabilities_for:name=>name==='voice'?{voice:{pending:()=>true}}:{},
    subscribe:callback=>subscribe_feature(events,callback),
    subscribe_owned:(owner,callback)=>subscribe_feature(events,callback,owner)});
  const descriptor=(version,fail=false)=>({name:'example',revision:String(version),url:module(version,fail),stylesheet:''});
  const until=async predicate=>{
    for(let i=0;i<100;i++){if(predicate())return;await new Promise(r=>setTimeout(r,1));}
    assert.fail('browser contribution did not settle');
  };
  update_clients(host,[descriptor(1)],{});
  await until(()=>retainedFeatureBridges.length===1);
  assert.equal(events.listeners.length,1,JSON.stringify(errors));
  emit_feature_event(events,'new/point','session-a',{});
  assert.deepEqual(featureEventCalls,[[1,'new/point','session-a']]);
  update_clients(host,[descriptor(2)],{});
  await until(()=>retainedFeatureBridges.length===2);
  assert.equal(events.listeners.length,1,'replacement left its predecessor subscribed');
  retainedFeatureBridges[0].subscribe(()=>{throw new Error('stale bridge subscribed');})();
  assert.equal(events.listeners.length,1,'a disposed bridge accepted a new subscription');
  emit_feature_event(events,'another/point','session-b',{});
  assert.deepEqual(featureEventCalls.at(-1),[2,'another/point','session-b']);
  update_clients(host,[descriptor(3,true)],{});
  await until(()=>host.mounts.example?.failed===true);
  assert.equal(events.listeners.length,0,'failed mount retained its subscription');
  retainedFeatureBridges.at(-1).subscribe(()=>{throw new Error('failed bridge subscribed');})();
  assert.equal(events.listeners.length,0,'a failed bridge accepted a later subscription');
  update_clients(host,[],{});
  assert.equal(events.listeners.length,0);
  update_clients(host,[{...descriptor(4),name:'voice'},descriptor(5)],{});
  await until(()=>retainedFeatureBridges.length===5);
  const voiceBridge=retainedFeatureBridges.find(bridge=>bridge.capabilities?.voice);
  const ordinaryBridge=retainedFeatureBridges.at(-1);
  assert.equal(voiceBridge.capabilities.voice.pending(),true);
  assert.equal(voiceBridge.capabilities_for,null,'a contribution received the private capability factory');
  assert.equal(voiceBridge.voice_submit,undefined,'voice methods remain on the generic bridge');
  assert.equal(ordinaryBridge.capabilities.voice,undefined,'another client received voice capabilities');
  update_clients(host,[],{});
} finally { console.error=originalError; }
console.log('feature events: arbitrary validated events, isolated payloads/failures, replacement, stale bridges and failed-mount cleanup passed');
