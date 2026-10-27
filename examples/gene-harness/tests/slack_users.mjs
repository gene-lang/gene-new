import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
class Element extends EventTarget {
  constructor(tag, text = '') { super(); this.tag = tag; this.text = text; this.children = []; this.attributes = {}; }
  append(...nodes) { this.children.push(...nodes); }
  appendChild(node) { this.children.push(node); node.parentNode = this; return node; }
  replaceChildren() { this.children = []; this.text = ''; }
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

const {create_channel_notice, update_channel_notice} = await import(new URL('slack_channels.mjs', main));
const noticeTarget = new Element('p');
const channelRequests = [];
const notice = create_channel_notice(noticeTarget, (data, done) => { channelRequests.push({data, done}); });
const sharing = {account: 'dobi', team: 'T123', channel: 'C0ANE5N5N31'};
update_channel_notice(notice, sharing);
assert.match(noticeTarget.textContent, /^Shared with Slack channel C0ANE5N5N31\./);
assert.equal(noticeTarget.hidden, false);
channelRequests[0].done(200n, {name: 'team-dobi'});
assert.match(noticeTarget.textContent, /^Shared with Slack channel #team-dobi \(C0ANE5N5N31\)\./);
update_channel_notice(notice, sharing);
assert.equal(channelRequests.length, 1, 'repeated snapshots reuse the name lookup');
update_channel_notice(notice, {...sharing, channel: 'COTHER'});
update_channel_notice(notice, sharing);
channelRequests[1].done(200n, {name: 'another-channel'});
assert.match(noticeTarget.textContent, /^Shared with Slack channel #team-dobi \(C0ANE5N5N31\)\./);
update_channel_notice(notice, {...sharing, channel: 'CMISSING'});
channelRequests[2].done(503n, {});
assert.match(noticeTarget.textContent, /^Shared with Slack channel CMISSING\./);
update_channel_notice(notice, null);
assert.equal(noticeTarget.hidden, true);
console.log('Slack channel sharing: channel names, cached lookup, fallback and stale-response protection passed');

const {create_session_title, update_session_title} = await import(new URL('slack_session_title.mjs', main));
const titleTarget = new Element('h1');
const titleState = create_session_title(titleTarget);
const titleSharing = {...sharing, transport: 'slack', thread: '1793119946.024039'};
update_session_title(titleState, 'Regular conversation', null, 'regular');
assert.equal(titleTarget.textContent, 'Regular conversation');
assert.equal(titleTarget.children.length, 0);
update_session_title(titleState, 'Slack conversation', titleSharing, 'session a&b');
update_session_title(titleState, 'Renamed conversation', titleSharing, 'session a&b');
const threadLink = '/api/v8/sessions/session%20a%26b/slack-thread';
let titleLink = titleTarget.children.find(node => node.tag === 'a');
assert.equal(titleLink.textContent, 'Renamed conversation');
assert.equal(titleLink.attributes.href, threadLink);
assert.equal(titleLink.attributes.target, '_blank');
assert.equal(titleLink.attributes.rel, 'noopener noreferrer');
update_session_title(titleState, 'Renamed conversation', titleSharing, 'session a&b');
assert.equal(titleTarget.children.find(node => node.tag === 'a'), titleLink, 'unchanged snapshots preserve link focus');
update_session_title(titleState, 'Renamed again', titleSharing, 'session a&b');
assert.equal(titleTarget.children.find(node => node.tag === 'a').textContent, 'Renamed again');
update_session_title(titleState, 'Other Slack thread', {...titleSharing, thread: '2.000001'}, 'other');
assert.equal(titleTarget.children.find(node => node.tag === 'a').attributes.href, '/api/v8/sessions/other/slack-thread');
update_session_title(titleState, 'Regular again', null, 'regular');
assert.equal(titleTarget.textContent, 'Regular again');
assert.equal(titleTarget.children.length, 0);
console.log('Slack session titles: Slack-only links, click-time resolution, new tabs, focus and rename updates passed');
