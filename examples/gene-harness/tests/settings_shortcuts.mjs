globalThis.getComputedStyle ??= () => ({getPropertyValue: name => name === "--shell-narrow" ? "0" : ""});
// Compiled-browser checks for Settings shortcut recording and platform chord display.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';

const doc = {activeElement: null};
class Element extends EventTarget {
  constructor(tag = 'div') {
    super(); this.tagName = tag; this.childNodes = []; this.parentNode = null; this.attributes = {};
    this.value = ''; this.checked = false; this.hidden = false; this.disabled = false; this.text = '';
    this.ownerDocument = doc;
  }
  get isConnected() { let node = this; while (node.parentNode) node = node.parentNode; return node === root; }
  get children() { return this.childNodes; }
  contains(node) { for (let at = node; at; at = at.parentNode) if (at === this) return true; return false; }
  insertBefore(node, before) {
    if (node.parentNode) node.parentNode.removeChild(node);
    const index = before ? this.childNodes.indexOf(before) : -1;
    if (index < 0) this.childNodes.push(node); else this.childNodes.splice(index, 0, node);
    node.parentNode = this; return node;
  }
  appendChild(node) { return this.insertBefore(node, null); }
  append(...nodes) { for (const node of nodes) this.appendChild(node); }
  removeChild(node) { this.childNodes.splice(this.childNodes.indexOf(node), 1); node.parentNode = null; }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  removeAttribute(key) { delete this.attributes[key]; }
  set textContent(value) { this.text = value; this.childNodes = []; }
  get textContent() { return this.text; }
  focus() { doc.activeElement = this; this.dispatchEvent(new Event('focus')); }
  blur() { if (doc.activeElement === this) doc.activeElement = null; }
}
const root = new Element('body');
const elements = new Map();
const element = id => {
  if (!elements.has(id)) { const value = new Element(); root.appendChild(value); elements.set(id, value); }
  return elements.get(id);
};
Object.assign(doc, {getElementById: element, body: root,
  createElement: tag => new Element(tag), createTextNode: text => Object.assign(new Element('#text'), {text})});
Object.assign(globalThis, {HTMLElement: Element, document: doc,
  sessionStorage: {getItem: () => null, setItem: () => {}, removeItem: () => {}}, setTimeout: () => 0});
Object.defineProperty(globalThis, 'navigator', {value: {platform: 'MacIntel'}, configurable: true});

const base = pathToFileURL(process.argv[2]);
const chords = await import(new URL('chords.mjs', base));
const model = await import(new URL('model.mjs', base));
const tree = await import(new URL('tree.mjs', base));
const overlays = await import(new URL('overlays.mjs', base));
const {Sidebar} = await import(new URL('sidebar.mjs', base));
const {create_notices} = await import(new URL('notices.mjs', base));

// Display follows the platform without changing the stored chord.
assert.equal(chords.format_chord('Ctrl+Shift+KeyK', 'MacIntel'), '⌃⇧K');
assert.equal(chords.format_chord('Meta+Digit1', 'macOS'), '⌘1');
assert.equal(chords.format_chord('Ctrl+Shift+KeyK', 'Win32'), 'Ctrl+Shift+K');
assert.equal(chords.format_chord('Ctrl+Shift+Space', 'Linux x86_64'), 'Ctrl+Shift+Space');
assert.equal(chords.format_chord('Escape', 'Win32'), 'Esc');
assert.equal(chords.format_chord('', 'MacIntel'), 'Unbound');
const key = (code, mods = {}) => Object.assign(new Event('keydown', {cancelable: true}),
  {code, key: code, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, isComposing: false, repeat: false}, mods);
assert.equal(chords.event_chord(key('KeyK', {ctrlKey: true, metaKey: true, shiftKey: true})), 'Ctrl+Shift+Meta+KeyK');
assert.equal(chords.event_chord(key('NumpadEnter')), 'Enter');
assert.equal(chords.modifier_code$q('ShiftLeft'), true);
assert.equal(chords.modifier_code$q('KeyK'), false);

// A recorder field takes the chord, suspends shortcuts while focused, and keeps Tab.
const target = new Element();
root.appendChild(target);
const noop = () => {};
const sidebar = new Sidebar({root: target, desktop_open: true, mobile_open: false, full_view: false, available: true,
  safe: false, signature: '', widgets: {}, target, pool: target, buttons: []});
const navigation = new model.UiNavigation({workspace: 'test', active: 'settings', last_view: '', presentation: 'full',
  remembered: {}, versions: {}, snapshots: {}, views: [], side: 'left', width: 50n, bar_hidden: false, focus: '',
  scroll: 0, focus_pending: false, action_generation: 1n, action_revision: '', sidebar, restore: noop, refresh: noop});
const ui = new model.UiClient({browser_appearance: null, applied_tokens: [],keyboard: {}, root: target, target, safe: false, ready: true, session: '', workspace: 'test',
  epoch: 'host', metadata_revision: '1', rendered_revision: 'r1',
  descriptor: {name: 'settings', revision: 'r1', data_revision: 'd1', functions: {settings_key: 'f1'}},
  settings: {}, instance: 'instance', version: '1', notices: create_notices(), state: {recording: 'view/toggle'}, drafts: {}, forms: {},
  nodes: {}, generation: 0n, sequence: 0n, debounce: 0n, last_data: 'd1', loading: false, render_error: false,
  pending: null, resolving: false, navigation, navigate: noop, api: noop, select: noop, command: noop, prompt: noop,
  appearance: 'light'});
const changes = [];
const view = {tag: 'section', props: {key: 'settings'}, children: [
  {tag: 'code', props: {key: 'shown', 'data-chord': 'Ctrl+Shift+Digit1'}, children: []},
  {tag: 'form', props: {key: 'record/view/toggle', action: 'settings_key', args: {operation: 'bind', id: 'view/toggle'}}, children: [
    {tag: 'input', props: {key: 'chord/view/toggle', field: 'chord', 'data-record-chord': '', value: 'Ctrl+Shift+Space'}, children: []}]}]};
tree.apply_tree(ui, view, node => { changes.push(node.key); }, noop);
const shown = ui.nodes['shown'].element;
assert.equal(shown.textContent, '⌃⇧1', 'a chord element shows the macOS notation');
const recorder = ui.nodes['chord/view/toggle'].element;
assert.equal(recorder.value, 'Ctrl+Shift+Space');
assert.equal(overlays.chord_recording$q(), false, 'nothing records before the field has focus');
recorder.focus();
assert.equal(overlays.chord_recording$q(), true, 'a focused recorder owns the keyboard');
const modifier = key('ShiftLeft', {shiftKey: true});
recorder.dispatchEvent(modifier);
assert.equal(recorder.value, 'Ctrl+Shift+Space', 'a lone modifier waits for the key');
const tab = key('Tab');
recorder.dispatchEvent(tab);
assert.equal(tab.defaultPrevented, false, 'Tab still moves focus');
const pressed = key('KeyK', {ctrlKey: true, altKey: true});
recorder.dispatchEvent(pressed);
assert.equal(pressed.defaultPrevented, true, 'a recorded chord does not type or reach other handlers');
assert.equal(recorder.value, 'Ctrl+Alt+KeyK');
assert.deepEqual(changes, ['chord/view/toggle'], 'the recorded chord becomes the form draft');
recorder.blur();
assert.equal(overlays.chord_recording$q(), false, 'blur ends recording');
recorder.focus();
tree.apply_tree(ui, {tag: 'section', props: {key: 'settings'}, children: []}, noop, noop);
assert.equal(overlays.chord_recording$q(), false, 'a removed recorder never keeps shortcuts suspended');

Object.defineProperty(globalThis, 'navigator', {value: {platform: 'Win32'}, configurable: true});
tree.apply_tree(ui, view, noop, noop);
assert.equal(ui.nodes['shown'].element.textContent, 'Ctrl+Shift+1', 'other platforms spell the modifiers');
console.log('settings shortcuts: platform chords, recorder capture, Tab, modifiers and recording ownership');
