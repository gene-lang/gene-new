import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor() { super(); this.attrs = {}; this.value = ''; this.children = []; this.writes = 0; this.styles = {}; this.style = {setProperty: (key,value) => { this.styles[key] = value; }}; }
  setAttribute(key, value) { this.attrs[key] = value; this.writes++; }
  appendChild(child) { this.children.push(child); child.parentNode = this; }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  removeChild(child) { this.children = this.children.filter(value => value !== child); child.parentNode = null; }
  replaceChildren(...children) { this.children = children; }
  set textContent(value) { this.text = value; this.children = []; }
}
const elements = new Map();
const element = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
globalThis.HTMLElement = Element;
globalThis.document = {visibilityState: 'visible', getElementById: element, createElement: () => new Element(), createTextNode: text => Object.assign(new Element(), {text})};
globalThis.window = new EventTarget();
const appearance = await import(pathToFileURL(process.argv[2]));
const pending = [], applied = [];
const request = (method, path, fields, done) => { pending.push({method, path, fields, done}); };
const answer = (mode, saved = {}) => ({saved, rendered: {theme:'default', mode, density:'comfortable', text_size:'default', content_width:'default', stylesheet:'/theme.css'}, themes:[{name:'default', title:'Default'}]});
const state = appearance.start_appearance(request, value => { applied.push(value); }, false);
assert.equal(pending[0].method, 'GET');
appearance.refresh_appearance(state);
pending[1].done(200n, answer('dark'));
pending[0].done(200n, answer('light'));
assert.equal(element('harness_document').attrs['data-mode'], 'dark', 'an old GET must not restore stale appearance');
const writes = element('harness_theme').writes;
window.dispatchEvent(new Event('focus'));
pending[2].done(200n, answer('dark'));
assert.equal(element('harness_theme').writes, writes, 'identical reads must not replace the stylesheet');
document.visibilityState = 'hidden';
window.dispatchEvent(new Event('visibilitychange'));
assert.equal(pending.length, 3);
document.visibilityState = 'visible';
window.dispatchEvent(new Event('visibilitychange'));
assert.equal(pending[3].method, 'GET');
appearance.change_appearance(state, {density:'compact'});
assert.deepEqual(pending[4].fields, {density:'compact'}, 'writes carry only the changed fields');
assert.equal(pending[4].method, 'POST');
pending[4].done(200n, answer('light'));
assert.equal(pending[5].method, 'GET', 'write completion rereads the new cookie');
pending[5].done(200n, answer('light', {theme:'paper', mode:'light'}));
const picker = new Element();
appearance.appearance_control(state, picker, 'theme');
assert.equal(picker.value, 'paper', 'Settings must show saved theme instead of rendered fallback');
assert.match(picker.children.at(-1).children[0].text, /not installed/);
assert.equal(pending.filter(item => item.method === 'POST').length, 1, 'reads and pushes do not write');
const safe = appearance.start_appearance(request, () => {}, true);
assert.equal(pending.at(-1).path, '/api/v9/appearance?ui=default');
const start = pending.length;
appearance.change_appearance(state, {theme:'minimal'});
appearance.change_appearance(state, {mode:'dark'});
appearance.change_appearance(state, {density:'compact', text_size:'larger'});
assert.equal(pending.length, start + 1, 'a document serializes cookie writes');
pending[start].done(200n, answer('light'));
assert.equal(pending[start+1].method, 'POST');
assert.deepEqual(pending[start+1].fields, {mode:'dark', density:'compact', text_size:'larger'});
pending[start+1].done(200n, answer('dark'));
assert.equal(pending[start+2].method, 'GET');
pending[start+2].done(200n, answer('dark'));
const colors = await import(new URL('contrast.mjs', pathToFileURL(process.argv[2])));
assert.equal(colors.ratio([1,1,1,1], [0,0,0,1]), 21);
assert.equal(colors.decimal('1'), 1);
globalThis.getComputedStyle = () => ({getPropertyValue: () => 'color(srgb 1 0 0 / 0.5)'});
assert.deepEqual(colors.computed_color(new Element(), 'var(--ink)'), [1,0,0,0.5]);
assert.deepEqual(colors.blend([1,0,0,0.5], [0,0,1,1]), [0.5,0,0.5,1]);
console.log('Appearance cookie synchronization, stale reads, focus, visibility and saved choices passed');
