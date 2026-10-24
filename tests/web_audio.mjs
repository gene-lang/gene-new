import assert from 'node:assert/strict';
import {readFileSync, readdirSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {pathToFileURL} from 'node:url';
import vm from 'node:vm';

const modulePath = process.argv[2];
const directory = dirname(modulePath);
const worklet = readdirSync(directory).find(name => /^gene-audio-[a-f0-9]{32}\.js$/.test(name));
assert.ok(worklet, 'standalone builds must publish the content-addressed worklet');
const processors = new Map();
class Port {
  messages = [];
  postMessage(data) { this.messages.push(data); }
  close() { this.closed = true; }
  send(data) { this.onmessage?.({data}); }
}
const sandbox = vm.createContext({
  AudioWorkletProcessor: class { port = new Port(); },
  sampleRate: 48000,
  registerProcessor: (name, constructor) => processors.set(name, constructor),
});
vm.runInContext(readFileSync(join(directory, worklet), 'utf8'), sandbox);
const Capture = processors.get('gene-capture');
const capture = new Capture({processorOptions: {rate: 16000, frameMs: 20}});
for (let i = 0; i < 375; i++) capture.process([[new Float32Array(128).fill(0.5)]]);
const captured = capture.port.messages.filter(x => x.type === 'frame');
assert.equal(captured.length, 50, 'one second at 48 kHz must produce 50 complete 20 ms frames');
assert.ok(captured.every(x => x.bytes.byteLength === 640));
assert.equal(new DataView(captured[0].bytes).getInt16(0, true), 16384);
assert.ok(capture.port.messages.filter(x => x.type === 'level').length >= 19);
capture.process([[new Float32Array(128).fill(-1)]]);
capture.port.send('finish');
assert.equal(capture.port.messages.at(-1).type, 'closed');
assert.ok(capture.port.messages.at(-2).bytes.byteLength < 640, 'release flushes the partial frame before closed');
assert.equal(capture.process([[]]), false);

const Player = processors.get('gene-player');
const player = new Player({processorOptions: {rate: 24000}});
const samples = new ArrayBuffer(4800);
for (let i = 0; i < 2400; i++) new DataView(samples).setInt16(i * 2, 8192, true);
player.port.send({type: 'push', bytes: samples});
let heard = 0;
for (let i = 0; i < 80; i++) {
  const output = new Float32Array(128);
  player.process([], [[output]]);
  heard += output.filter(x => x > 0.2).length;
}
assert.equal(heard, 4800, '24 kHz PCM is resampled to the 48 kHz output without loss');
assert.equal(player.port.messages.filter(x => x.type === 'started').length, 1);
assert.equal(player.port.messages.find(x => x.type === 'drained').played, 4800);
assert.equal(player.queued, 0);
player.port.send({type: 'push', bytes: new ArrayBuffer(24000 * 6)});
assert.equal(player.port.messages.at(-1).type, 'error', 'paused playback must remain bounded');
player.port.send({type: 'push', bytes: samples});
player.port.send({type: 'stop'});
let first, last;
for (let i = 0; i < 4; i++) {
  const output = new Float32Array(128);
  player.process([], [[output]]);
  first ??= output[0]; last = output[95];
}
assert.ok(first > last, 'barge-in fades the waveform rather than cutting it');
assert.equal(player.closed, true);

for (const bytes of [0, 2, 100]) {
  const stopped = new Player({processorOptions: {rate: 24000}});
  if (bytes) stopped.port.send({type: 'push', bytes: new ArrayBuffer(bytes)});
  stopped.port.send({type: 'stop'});
  let active = true;
  for (let i=0; i<8 && active; i++) active = stopped.process([], [[new Float32Array(128)]]);
  assert.equal(active, false, `stop must retire an empty or short (${bytes} byte) processor`);
  assert.equal(stopped.closed, true);
  assert.equal(stopped.port.messages.filter(x => x.type === 'stopped').length, 1);
  assert.equal(stopped.process([], [[new Float32Array(128)]]), false);
}

// The emitted browser boundary handles permission arriving after disposal and
// counts bytes posted to the worklet as queued until actual playback reports.
const module = await import(pathToFileURL(modulePath).href);
let grant, requestedConstraints;
let stopped = 0;
const stream = {getTracks: () => [{stop: () => stopped++}]};
Object.defineProperty(globalThis, 'navigator', {configurable: true, value: {
  mediaDevices: {getUserMedia: constraints => { requestedConstraints = constraints; return new Promise(resolve => { grant = resolve; }); }},
}});
const nodes = [];
globalThis.AudioWorkletNode = class extends EventTarget {
  constructor(context, name, options) { super(); this.port = new Port(); this.name = name; nodes.push(this); }
  connect() {} disconnect() { this.disconnected = true; }
};
const urls = [];
const context = new EventTarget();
context.audioWorklet = {addModule: async url => { urls.push(url); }};
context.createMediaStreamSource = () => ({connect() {}, disconnect() {}});
context.destination = {};
const errors = [];
const abandoned = module.pcm_capture(context, () => {}, () => {}, value => { errors.push(value); });
module.pcm_abort(abandoned); grant(stream);
await new Promise(resolve => setImmediate(resolve));
assert.equal(stopped, 1, 'a late microphone permission result must stop its tracks');
const frames = [];
const active = module.pcm_capture(context, value => { frames.push(value); }, () => {}, value => { errors.push(value); });
assert.equal(requestedConstraints.audio.echoCancellation, true);
assert.equal(requestedConstraints.audio.noiseSuppression, true);
grant(stream); await new Promise(resolve => setImmediate(resolve));
assert.equal(nodes.at(-1).name, 'gene-capture');
assert.equal(urls[0].protocol, 'file:', 'the loader uses a module-relative URL, never a blob URL');
let finished = false;
module.pcm_finish(active, () => { finished = true; });
assert.equal(finished, false);
const node = nodes.at(-1);
node.port.send({type: 'frame', bytes: new Uint8Array([0, 128]).buffer});
node.port.send({type: 'closed'});
assert.equal(finished, true); assert.equal(frames.length, 1); assert.equal(stopped, 2);
const rawCapture = module.pcm_capture_raw(context, () => {}, () => {}, () => {});
assert.equal(requestedConstraints.audio.echoCancellation, false);
assert.equal(requestedConstraints.audio.noiseSuppression, false);
assert.equal(requestedConstraints.audio.autoGainControl, false);
module.pcm_abort(rawCapture); grant(stream);
await new Promise(resolve => setImmediate(resolve));
assert.equal(stopped, 3);
const playback = module.pcm_player(context, value => { errors.push(value); });
module.pcm_push(playback, new Uint8Array(4800));
assert.equal(module.pcm_queued(playback), 100);
await new Promise(resolve => setImmediate(resolve));
const playerNode = nodes.at(-1);
let starts = 0, drains = 0;
module.pcm_started(playback, () => { starts++; }); module.pcm_drained(playback, () => { drains++; });
playerNode.port.send({type: 'started', played: 0});
playerNode.port.send({type: 'drained', played: 4800});
assert.equal(starts, 1); assert.equal(drains, 1); assert.equal(module.pcm_queued(playback), 0);
assert.equal(module.pcm_played(playback), 4800);
module.pcm_stop(playback);
playerNode.port.send({type: 'started', played: 0});
assert.equal(starts, 1, 'late playback callbacks cannot revive a disposed player');
assert.deepEqual(errors, []);
console.log('PCM worklet and emitted boundary fixtures passed.');
