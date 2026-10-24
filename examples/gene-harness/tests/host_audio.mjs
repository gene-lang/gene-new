// Compiled Gene transport: cookie-bearing browser socket, CSRF hello, PCM,
// consumed-byte credits, per-stream fencing and disposal.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const sockets = [], nodes = [], timers = [], events = [];
let now = 1000;
Object.defineProperty(globalThis, 'performance', {configurable:true, value:{now:() => now}});
Object.assign(globalThis, {
  window: {location: {origin: 'http://fixture'}},
  setTimeout: (callback, ms) => { timers.push({callback, ms}); return timers.length; },
  WebSocket: class extends EventTarget {
    static OPEN = 1;
    readyState = 0; bufferedAmount = 0; sent = [];
    constructor(url, protocol) { super(); this.url = url; this.protocol = protocol; sockets.push(this); }
    send(value) { this.sent.push(value); }
    close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
    open() { this.readyState = 1; this.dispatchEvent(new Event('open')); }
    text(value) { this.dispatchEvent(new MessageEvent('message', {data: JSON.stringify(value)})); }
    bytes(value) { this.dispatchEvent(new MessageEvent('message', {data: value.buffer})); }
  },
  AudioWorkletNode: class extends EventTarget {
    constructor(context, name, options) {
      super(); this.name = name; this.options = options; nodes.push(this);
      this.port = {messages: [], postMessage(value) { this.messages.push(value); }, close() {}};
    }
    connect() {} disconnect() { this.disconnected = true; }
    event(value) { this.port.onmessage?.({data: value}); }
  },
});
let grant, stopped = 0;
Object.defineProperty(globalThis, 'navigator', {configurable: true, value: {
  mediaDevices: {getUserMedia: () => new Promise(resolve => { grant = resolve; })},
}});
const context = Object.assign(new EventTarget(), {
  audioWorklet: {addModule: async () => {}}, destination: {},
  createMediaStreamSource: () => ({connect() {}, disconnect() {}}),
});
const module = await import(pathToFileURL(process.argv[2]).href);
const host = module.open_host_audio(context, 'session-a', 'page', 'csrf', 'claim-token', true, true, true,
  (kind, data) => { events.push({kind, data}); });
const socket = sockets[0];
assert.equal(socket.protocol, 'gene-harness-voice.1');
assert.equal(socket.url, 'ws://fixture/api/v8/voice');
socket.open();
const hello = JSON.parse(socket.sent[0]);
assert.deepEqual(hello, {type: 'hello', csrf: 'csrf', client_id: 'page', formats: ['s16le']});
socket.text({type: 'ready'});
assert.equal(JSON.parse(socket.sent.at(-1)).token, 'claim-token');
socket.text({type: 'claimed'});
assert.equal(host.ready, true);
assert.equal(module.start_host_capture(host, 'utterance-a', () => {}), true);
const start = JSON.parse(socket.sent.at(-1));
grant({getTracks: () => [{stop: () => stopped++}]});
await new Promise(resolve => setImmediate(resolve));
const capture = nodes.at(-1);
capture.event({type: 'frame', bytes: new Uint8Array([255, 127]).buffer});
const mic = socket.sent.at(-1);
assert.equal(mic[0], 1);
assert.equal(new DataView(mic.buffer).getUint32(1, true), start.stream);
module.finish_host_capture(host);
assert.equal(host.capturing, true, 'end must follow the final flushed PCM frame');
capture.event({type: 'frame', bytes: new Uint8Array([0, 128]).buffer});
capture.event({type: 'closed'});
assert.equal(host.capturing, false); assert.equal(stopped, 1);
assert.equal(JSON.parse(socket.sent.at(-1)).type, 'capture/end');
assert.equal(module.start_host_capture(host, 'utterance-b', () => {}), true,
  'a second host capture can start before A is transcribed');
socket.text({type: 'transcript/final', id: 'utterance-a', text: 'first'});
assert.equal(events.at(-1).data.id, 'utterance-a');
module.cancel_input(host);
grant({getTracks: () => [{stop: () => stopped++}]});
await new Promise(resolve => setImmediate(resolve));
assert.equal(stopped, 2);
assert.equal(module.speak_host_reply(host, 'session-a/7'), true);
const speak = JSON.parse(socket.sent.at(-1));
assert.equal(speak.reply, 'session-a/7', 'the host owns the spoken text lookup');
socket.text({type: 'speak/start', id: speak.id, stream: speak.stream,
  format: {rate: 24000, channels: 1, encoding: 's16le'}});
await new Promise(resolve => setImmediate(resolve));
const player = nodes.at(-1);
assert.equal(player.options.processorOptions.rate, 24000, 'backlog playback must preserve the native PCM rate and pitch');
const frame = new Uint8Array(4809), view = new DataView(frame.buffer);
frame[0] = 2; view.setUint32(1, speak.stream, true); view.setUint32(5, 0, true);
socket.bytes(frame);
module.player_credit(host);
assert.equal(JSON.parse(socket.sent.at(-1)).played_bytes, 0, 'received PCM is still charged');
assert.equal(module.prefetch_host_reply(host, 'session-a/9'), true);
const prefetched = JSON.parse(socket.sent.at(-1));
socket.text({type:'speak/start', id:prefetched.id, stream:prefetched.stream,
  format:{rate:24000, channels:1, encoding:'s16le'}});
const nodeCountBeforePrefetch = nodes.length;
const aheadFrame = new Uint8Array(frame);
new DataView(aheadFrame.buffer).setUint32(1, prefetched.stream, true);
socket.bytes(aheadFrame);
module.player_credit(host);
assert.deepEqual(JSON.parse(socket.sent.at(-1)),{type:'player',id:prefetched.id,played_bytes:0,waiting:true},
  'queued speech needs a heartbeat that preserves its zero playback credit');
socket.text({type:'speak/end', id:prefetched.id, bytes:4800});
assert.equal(nodes.length, nodeCountBeforePrefetch, 'prefetched PCM must not play before the earlier reply');
socket.text({type: 'speak/end', id: speak.id, bytes: 4800});
assert.notEqual(host.speak_id, '', 'synthesis ending does not mean playback ended');
player.event({type: 'started', played: 0});
assert.equal(events.at(-1).kind, 'speak/started');
player.event({type: 'drained', played: 4800});
assert.equal(events.at(-1).kind, 'speak/end');
assert.equal(host.speak_id, '');
const requestsBeforeActivation = socket.sent.filter(x => typeof x === 'string' && JSON.parse(x).type === 'speak').length;
assert.equal(module.speak_host_reply(host, 'session-a/9'), true);
await new Promise(resolve => setImmediate(resolve));
assert.equal(socket.sent.filter(x => typeof x === 'string' && JSON.parse(x).type === 'speak').length,
  requestsBeforeActivation, 'the next FIFO reply consumes its prefetched stream without requesting it again');
const prefetchedPlayer = nodes.at(-1);
const activationAck=socket.sent.filter(x=>typeof x==='string').map(x=>JSON.parse(x)).filter(x=>x.type==='player'&&x.id===prefetched.id).at(-1);
assert.notEqual(activationAck.waiting,true,'activation must restore normal playback-progress deadlines');
prefetchedPlayer.event({type:'started', played:0});
prefetchedPlayer.event({type:'drained', played:4800});
assert.equal(host.speak_id, '');
assert.equal(module.speak_host_reply(host, 'session-a/8'), true);
const another = JSON.parse(socket.sent.at(-1));
socket.text({type: 'speak/start', id: another.id, stream: another.stream,
  format: {rate: 24000, channels: 1, encoding: 's16le'}});
await new Promise(resolve => setImmediate(resolve));
view.setUint32(1, another.stream, true); view.setUint32(5, 1, true);
socket.bytes(frame);
assert.equal(host.closed, true, 'a sequence gap stops the stream instead of playing corrupted audio');
assert.equal(events.at(-1).kind, 'error');
const count = events.length;
socket.text({type: 'transcript/final', id: 'utterance-b', text: 'late'});
assert.equal(events.length, count, 'disposed transport cannot revive input');
console.log('Compiled host audio socket, flush, overlap, playback credit and disposal fixtures passed.');

const vadEvents = [];
let handsfree;
handsfree = module.open_host_audio(context, 'session-a', 'page', 'csrf', 'token', true, true, true,
  (kind, data) => { vadEvents.push({kind, data}); if (kind === 'vad/start') module.cancel_output(handsfree); });
const live = sockets.at(-1); live.open(); live.text({type:'ready'}); live.text({type:'claimed'});
assert.equal(module.start_handsfree(handsfree, 'half', () => {}), true);
grant({getTracks: () => [{stop: () => stopped++}]});
await new Promise(resolve => setImmediate(resolve));
const monitor = nodes.at(-1);
const audioFrame = () => monitor.event({type:'frame', bytes:new Uint8Array(640).buffer});
const level = value => monitor.event({type:'level', value});
module.speak_host_reply(handsfree, 'session-a/1');
level(0.8); for (let i=0; i<20; i++) audioFrame();
assert.equal(vadEvents.filter(x => x.kind === 'vad/start').length, 0, 'half duplex must reject speaker echo');
module.cancel_output(handsfree);
handsfree.external_playback = true;
for (let i=0; i<10; i++) audioFrame();
assert.equal(vadEvents.filter(x => x.kind === 'vad/start').length, 0, 'browser TTS is gated too');
handsfree.external_playback = false;
level(0.8); for (let i=0; i<5; i++) audioFrame();
assert.equal(vadEvents.filter(x => x.kind === 'vad/start').length, 0, 'half duplex keeps a guard for the audible playback tail');
now += 400;
level(0.1); for (let i=0; i<4; i++) audioFrame();
assert.equal(vadEvents.filter(x => x.kind === 'vad/start').length, 1);
assert.equal(handsfree.capturing, true);
for (let i=0; i<10; i++) audioFrame();
level(0.001); for (let i=0; i<29; i++) audioFrame();
assert.equal(handsfree.capturing, true);
audioFrame();
assert.equal(handsfree.capturing, false);
assert.equal(vadEvents.at(-1).kind, 'vad/end');
assert.equal(vadEvents.at(-1).data.audio_ms, 880n, 'the transcript duration includes pre-roll and the silence tail');
assert.ok(handsfree.monitor, 'ending an utterance keeps the hands-free monitor open');
const nodeCount = nodes.length;
module.start_host_capture(handsfree, 'manual-interrupt', () => {});
audioFrame(); module.finish_host_capture(handsfree);
assert.equal(nodes.length, nodeCount, 'manual interruption reuses the microphone worklet');
module.start_handsfree(handsfree, 'headphones', () => {});
module.speak_host_reply(handsfree, 'session-a/2');
level(0.1); for (let i=0; i<4; i++) audioFrame();
assert.equal(vadEvents.filter(x => x.kind === 'vad/start').length, 2, 'headphone mode allows voice barge-in');
assert.equal(handsfree.speak_id, '', 'the voice callback cancels the interrupted speech');
module.close_host_audio(handsfree);
const endedEvents = vadEvents.length;
level(0.8); audioFrame();
assert.equal(vadEvents.length, endedEvents, 'disposed monitors cannot start a new utterance');

const reconnectEvents = [];
const reconnect = module.open_host_audio(context, 'session-a', 'page', 'csrf', 'same-token', true, true, true,
  (kind, data) => { reconnectEvents.push({kind, data}); });
const before = sockets.at(-1); before.open(); before.text({type:'ready'}); before.text({type:'claimed'});
reconnect.output = false;
before.close(); assert.equal(reconnect.ready, false);
assert.equal(reconnectEvents.at(-1).kind, 'host/reconnecting');
timers.filter(item => item.ms === 2000).at(-1).callback();
const after = sockets.at(-1); after.open(); after.text({type:'ready'});
const refreshed = JSON.parse(after.sent.at(-1));
assert.equal(refreshed.token, 'same-token'); assert.equal(refreshed.output, false);
after.text({type:'claimed'}); assert.equal(reconnect.ready, true);
const observed = reconnectEvents.length;
before.text({type:'transcript/final', id:'stale', text:'must not revive'});
assert.equal(reconnectEvents.length, observed);
after.text({type:'engines/changed', message:'fixture replacement'});
assert.equal(reconnect.closed, true);
assert.equal(reconnectEvents.at(-1).kind, 'engines/changed');
module.close_host_audio(reconnect);
console.log('Compiled hands-free VAD, half-duplex/browser-TTS gating, headphone barge-in and reconnect fixtures passed.');
