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
const pending = [], applied = [], errors = [], reports = [];
const request = (method, path, fields, done) => { pending.push({method, path, fields, done}); };
const answer = (mode, saved = {}, revision = 'themes:1') => ({saved, rendered: {theme:'default', mode, density:'comfortable', text_size:'default', content_width:'default', stylesheet:'/theme.css', theme_revision:revision}, themes:[{name:'default', title:'Default'}]});
function respond(method, body, status = 200n) {
  const next = pending.shift(); assert.ok(next, `expected ${method}`);
  assert.equal(next.method, method); next.done(status, body); return next;
}
const state = appearance.start_appearance(request, value => { applied.push(value); }, false, value => { errors.push(value); }, value => { reports.push(value); });
assert.equal(pending.length, 1);
appearance.refresh_appearance(state);
appearance.refresh_appearance(state);
assert.equal(pending.length, 1, 'overlapping reads coalesce');
respond('GET', answer('light'));
assert.equal(applied.length, 0, 'a superseded read is not applied');
respond('GET', answer('dark'));
assert.equal(element('harness_document').attrs['data-mode'], 'dark');
const writes = element('harness_theme').writes;
window.dispatchEvent(new Event('focus'));
respond('GET', answer('dark'));
assert.equal(element('harness_theme').writes, writes);
assert.equal(applied.length, 1, 'unchanged reads do not rebuild layout or controls');
assert.equal(reports.length, 1, 'unchanged reads do not resend the browser report');
document.visibilityState = 'hidden'; window.dispatchEvent(new Event('visibilitychange'));
assert.equal(pending.length, 0);
document.visibilityState = 'visible'; window.dispatchEvent(new Event('visibilitychange'));
respond('GET', answer('dark'));
for (let i=0; i<5; i++) appearance.appearance_event(state, 'appearance_changed', {}, false);
appearance.appearance_event(state, 'ui/state', {data_revision:'plugin-write'}, true);
appearance.appearance_event(state, 'ui/state', {theme_revision:'themes:1'}, true);
assert.equal(pending.length, 0, 'background sockets and ordinary UI state do not fetch appearance');
appearance.appearance_event(state, 'ui/state', {theme_revision:'themes:2'}, true);
appearance.appearance_event(state, 'ui/state', {theme_revision:'themes:2'}, true);
assert.equal(pending.length, 1, 'one theme publication triggers one page read');
respond('GET', answer('dark', {}, 'themes:2'));
const beforeReconnect = applied.length;
appearance.appearance_event(state, 'ready', {}, true);
respond('GET', answer('dark', {}, 'themes:2'));
assert.equal(applied.length, beforeReconnect, 'reconnect reports without rerendering unchanged state');
assert.equal(reports.length, 3);
appearance.change_appearance(state, {theme:'paper'});
appearance.change_appearance(state, {mode:'light'});
appearance.change_appearance(state, {density:'compact'});
assert.equal(pending.length, 1, 'cookie writes are serialized');
assert.deepEqual(pending[0].fields, {theme:'paper'});
respond('POST', answer('dark'));
assert.deepEqual(pending[0].fields, {mode:'light', density:'compact'});
respond('POST', {message:'Refresh this page before making a change.'}, 403n);
assert.equal(errors.length, 1);
assert.match(errors[0].message, /Refresh this page/);
assert.equal(applied.length, beforeReconnect+1, 'a failed write immediately restores known saved controls');
respond('GET', answer('dark', {}, 'themes:2'));
assert.equal(applied.length, beforeReconnect+1, 'a failed write reconciles unchanged saved controls');
appearance.change_appearance(state, {mode:'light'});
appearance.refresh_appearance(state);
respond('POST', answer('light'));
respond('GET', answer('dark', {}, 'themes:2'));
respond('GET', answer('light', {theme:'paper'}, 'themes:2'));
const picker = new Element();
appearance.appearance_control(state, picker, 'theme');
assert.equal(picker.value, 'paper');
assert.match(picker.children.at(-1).children[0].text, /not installed/);
let loaded = 0;
assert.equal(appearance.load_preview(state, 'default', () => { loaded++; }), false);
assert.equal(appearance.load_preview(state, 'default', () => { loaded++; }), false);
assert.equal(pending.length, 1, 'preview assets load only on demand, once per theme');
assert.match(pending[0].path, /appearance\/preview\?theme=default$/);
respond('GET', {theme:'default',revision:'themes:2',stylesheet:'/preview.css'});
const link = element('theme_preview_styles').children.at(-1);
assert.equal(link.attrs.href, '/preview.css');
link.dispatchEvent(new Event('load'));
assert.equal(loaded, 1);
assert.equal(appearance.load_preview(state, 'default', () => { loaded++; }), true);
appearance.refresh_appearance(state);
respond('GET', answer('light', {theme:'paper'}, 'themes:3'));
assert.equal(element('theme_preview_styles').children.length, 0, 'a theme revision retires old preview styles');
appearance.load_preview(state, 'default', () => { loaded++; });
const stale = pending.shift();
appearance.refresh_appearance(state);
respond('GET', answer('light', {theme:'paper'}, 'themes:4'));
stale.done(200n, {revision:'themes:3',stylesheet:'/stale.css'});
assert.equal(element('theme_preview_styles').children.length, 0, 'late preview replies cannot restore an old catalog');
const safe = appearance.start_appearance(request, () => {}, true);
assert.equal(pending[0].path, '/api/v9/appearance?ui=default');
respond('GET', answer('light'));
appearance.load_preview(safe, 'default', () => {});
assert.match(pending[0].path, /&ui=default$/);
respond('GET', {revision:'themes:1',stylesheet:'/safe-preview.css'});
const colors = await import(new URL('contrast.mjs', pathToFileURL(process.argv[2])));
assert.equal(colors.ratio([1,1,1,1], [0,0,0,1]), 21);
assert.equal(colors.decimal('1'), 1);
globalThis.getComputedStyle = () => ({getPropertyValue: () => 'color(srgb 1 0 0 / 0.5)'});
assert.deepEqual(colors.computed_color(new Element(), 'var(--ink)'), [1,0,0,0.5]);
assert.deepEqual(colors.blend([1,0,0,0.5], [0,0,1,1]), [0.5,0,0.5,1]);
console.log('Appearance coalescing, socket ownership, failures, reconnect reports and lazy previews passed');
