## Browser file boundaries and callback behavior without a live browser.
import gene/web
import std/[os, osproc]

let root = getTempDir() / "gene-transpile-files"
createDir(root)
let source = root / "files_fixture.gene"
writeFile(source, """
(mod files_fixture ^profile web)
(fn selected [input : EventTarget] : (List Any) ($files/from_input input))
(fn dropped [event : Any] : (List Any) ($files/from_event event))
(fn name [file : Any] : Str ($files/name file))
(fn mime [file : Any] : Str ($files/mime file))
(fn size [file : Any] : Int ($files/size file))
(fn read [file : Any, maximum : Int, yes : (Fn [Str] Void), no : (Fn [Str] Void)] : EventTarget
  ($files/read_base64 file maximum yes no))
(fn cancel [reader : EventTarget] : Void ($files/cancel reader))
(fn noop [] : Int (var callback (fn [] : Void nil)) (callback) 1)
""")
let output = root / "out"
createDir(output)
discard buildWebModule(source, output)
let runner = root / "run.mjs"
writeFile(runner, """
import assert from 'node:assert/strict';
class File extends Blob { constructor(parts, name, options) { super(parts, options); this.name = name; } }
class HTMLInputElement extends EventTarget { type = 'file'; files = []; }
let reads = 0;
class FileReader extends EventTarget {
  readyState = 0; result = null;
  readAsDataURL(file) {
    reads++; this.readyState = 1;
    queueMicrotask(async () => {
      if (this.readyState !== 1) return;
      if (file.fail) { this.readyState = 2; this.onerror?.({target:this}); return; }
      const bytes = Buffer.from(await file.arrayBuffer());
      if (this.readyState !== 1) return;
      this.result = `data:${file.type};base64,${bytes.toString('base64')}`;
      this.readyState = 2; this.onload?.({target:this});
    });
  }
  abort() { if (this.readyState === 1) { this.readyState = 2; this.onabort?.({target:this}); } }
}
Object.assign(globalThis, {File, HTMLInputElement, FileReader});
const api = await import('./out/files_fixture.mjs');
const file = new File([new Uint8Array([255,0,128,42])], 'résumé.png', {type:'image/png'});
const input = new HTMLInputElement(); input.files = [file];
assert.deepEqual(api.selected(input), [file]);
assert.deepEqual(api.dropped({dataTransfer:{files:[file]}}), [file]);
assert.deepEqual(api.dropped({clipboardData:{files:[file]}}), [file]);
assert.deepEqual(api.dropped({}), []);
assert.equal(api.name(file), 'résumé.png');
assert.equal(api.mime(file), 'image/png');
assert.equal(api.size(file), 4n);
assert.equal(api.noop(), 1n);
assert.throws(() => api.selected(new EventTarget()), /file input/);
assert.throws(() => api.name({name:'spoof'}), /File/);
assert.throws(() => api.read(file, 67108865n, () => {}, () => {}), /limit/);
const success = await new Promise((resolve,reject) => api.read(file, 4n, value => {resolve(value);}, error => {reject(Error(error));}));
assert.equal(success, '/wCAKg==');
const before = reads;
const oversized = await new Promise(resolve => api.read(file, 3n, () => {throw Error('oversized read');}, error => {resolve(error);}));
assert.match(oversized, /size limit/); assert.equal(reads, before);
const broken = new File([], 'broken.txt', {type:'text/plain'}); broken.fail = true;
const failed = await new Promise(resolve => api.read(broken, 4n, () => {throw Error('broken read');}, error => {resolve(error);}));
assert.match(failed, /could not be read/);
const cancelled = await new Promise(resolve => {
  const reader = api.read(file, 4n, () => {throw Error('read after cancellation');}, error => {resolve(error);});
  api.cancel(reader);
});
assert.match(cancelled, /cancelled/);
console.log('transpile files: picker, drop, paste, binary fidelity, bounds, errors, cancellation and Void callbacks passed');
""")
let checked = execCmdEx("node_modules/.bin/tsc --noEmit --strict --target ES2022 --module ESNext --moduleResolution bundler --lib ES2022,DOM " &
  quoteShell(output / "files_fixture.ts"))
if checked.exitCode != 0:
  stderr.write(checked.output)
  quit(1)
let executed = execCmdEx("node " & quoteShell(runner))
stdout.write(executed.output)
if executed.exitCode != 0: quit(executed.exitCode)
let composerOut = root / "composer"
createDir(composerOut)
discard buildWebModule(getCurrentDir() / "examples/gene-harness/client/media.gene", composerOut)
let composer = execCmdEx("node examples/gene-harness/tests/media_composer.mjs " &
  quoteShell(composerOut / "media.mjs"))
stdout.write(composer.output)
quit(composer.exitCode)
