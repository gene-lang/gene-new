// Runs the actual emitted boundary against deterministic asynchronous browser APIs.
import assert from "node:assert/strict";
import {pathToFileURL} from "node:url";
const module = await import(pathToFileURL(process.argv[2]).href);
assert.equal(module.recognition_available(), false);
assert.equal(module.synthesis_available(), false);
let recognizer;
class Recognition {
  constructor() { recognizer = this; }
  start() { this.started = true; }
  stop() { this.stopped = true; }
  abort() { this.aborted = true; }
}
globalThis.webkitSpeechRecognition = Recognition;
assert.equal(module.recognition_available(), true);
const partials = [], finals = [], ends = [];
const capture = module.recognize(x => { partials.push(x); }, x => { finals.push(x); }, x => { ends.push(x); });
assert.equal(recognizer.lang, "en-US");
assert.equal(recognizer.continuous, true);
const result = (value, final) => Object.assign([{transcript: value}], {isFinal: final});
recognizer.onresult({resultIndex: 0, results: [result("hello", true), result("wor", false)]});
assert.deepEqual(partials, ["hello wor"]);
module.finish(capture);
assert.equal(recognizer.stopped, true);
assert.deepEqual(finals, [], "release must wait for the recognizer's final callback");
recognizer.onresult({resultIndex: 1, results: [result("hello", true), result("world", true)]});
recognizer.onend();
recognizer.onend();
assert.deepEqual(finals, ["hello world"]);
assert.deepEqual(ends, [""]);
const cancelled = module.recognize(x => { partials.push(x); }, x => { finals.push(x); }, x => { ends.push(x); });
const late = recognizer.onresult, lateEnd = recognizer.onend;
module.abort(cancelled);
assert.equal(recognizer.aborted, true);
late({resultIndex: 0, results: [result("late", true)]});
lateEnd();
assert.deepEqual(finals, ["hello world"], "aborted capture cannot revive a transcript");
module.recognize(() => {}, x => { finals.push(x); }, x => { ends.push(x); });
recognizer.onerror({error: "not-allowed"});
recognizer.onend();
assert.deepEqual(ends, ["", "not-allowed"]);
assert.deepEqual(finals, ["hello world"]);
let utterance, cancelledSpeech = false;
globalThis.SpeechSynthesisUtterance = class {
  constructor(text) { this.text = text; }
};
globalThis.speechSynthesis = {
  getVoices: () => [{name: "Test", voiceURI: "test", lang: "en-US", localService: true}],
  speak: value => { utterance = value; },
  cancel: () => { cancelledSpeech = true; },
};
assert.equal(module.synthesis_available(), true);
assert.deepEqual(module.voices(), [{name: "Test", uri: "test", language: "en-US", local: true}]);
let starts = 0; const spokenEnds = [];
module.speak("Hello.", () => { starts++; }, error => { spokenEnds.push(error); });
assert.equal(utterance.text, "Hello.");
assert.equal(utterance.voice.voiceURI, "test");
utterance.onstart();
utterance.onend();
utterance.onend();
assert.equal(starts, 1);
assert.deepEqual(spokenEnds, [""]);
module.cancel();
assert.equal(cancelledSpeech, true);
globalThis.AudioContext = class extends EventTarget {
  async resume() { this.resumed = true; }
  async close() { this.closed = true; }
};
const context = module.context();
module.resume(context); module.close(context);
assert.equal(context.resumed, true);
assert.equal(context.closed, true);
console.log("web speech: partial/final ordering, release, cancellation, permission errors, synthesis and context lifecycle passed");
