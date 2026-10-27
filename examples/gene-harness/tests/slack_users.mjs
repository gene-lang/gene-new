import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor(tag, text = '') { super(); this.tag = tag; this.text = text; this.children = []; this.attributes = {}; }
  append(...nodes) { this.children.push(...nodes); }
  appendChild(node) { this.children.push(node); node.parentNode = this; return node; }
  setAttribute(key, value) { this.attributes[key] = value; }
  get textContent() { return this.text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this.text = value; this.children = []; }
}
Object.assign(globalThis, {HTMLElement: Element, document: {
  createElement: tag => new Element(tag), createTextNode: text => new Element('#text', text),
  createDocumentFragment: () => new Element('#fragment')
}});
const main = pathToFileURL(process.argv[2]);
const {create_user_labels, user_label} = await import(new URL('slack_users.mjs', main));
const {block_view} = await import(new URL('view.mjs', main));
const {answered_view} = await import(new URL('cards.mjs', main));
const pending = [];
const users = create_user_labels((source, done) => { pending.push({source, done}); });
const resolve = (source, target) => user_label(users, source, target);
const source = {account: 'dobi', team: 'T123', author: 'U0A6QLMRSG2', message: '1793120418.410259', text: 'Build it'};
const message = () => block_view({role: 'user', phase: 'turn/request', text: 'Build it',
  input: {kind: 'channel', messages: [source]}}, false, () => {}, false, () => {}, null, null, resolve);
const first = message(), second = message();
assert.equal(pending.length, 1, 'repeated records share an in-flight lookup');
assert.match(first.textContent, /Slack · U0A6QLMRSG2 · 1793120418.410259/);
pending[0].done(200n, {name: 'Guoliang Cao'});
for (const node of [first, second, message()]) {
  assert.match(node.textContent, /Slack · Guoliang Cao\(U0A6QLMRSG2\) · 1793120418.410259/);
}
assert.equal(pending.length, 1, 'resolved names are cached');
const answer = answered_view({batch: {answer_source: {transport: 'slack', ...source}, questions: []}}, () => {}, resolve);
assert.match(answer.textContent, /User · Slack Guoliang Cao\(U0A6QLMRSG2\)/);
const otherTeam = new Element('span', source.author);
user_label(users, {...source, team: 'TOTHER'}, otherTeam);
assert.equal(pending.length, 2, 'teams never share identity cache entries');
pending[1].done(200n, {name: ''});
assert.equal(otherTeam.textContent, source.author);
const unavailable = new Element('span', 'UOTHER');
user_label(users, {...source, author: 'UOTHER'}, unavailable);
pending[2].done(503n, {message: 'Unavailable'});
assert.equal(unavailable.textContent, 'UOTHER');
assert.equal(source.author, 'U0A6QLMRSG2', 'lookup never changes the authoritative identity');
console.log('Slack user labels: old records, cached lookups, question answers, team isolation and fallback passed');
