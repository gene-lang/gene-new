import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';

class Element extends EventTarget {
  constructor(tag = 'div', text = '') {
    super(); this.tag = tag; this.text = text; this.children = []; this.attributes = {};
    this.value = ''; this.disabled = false; this.hidden = false; this.checked = false;
    this.classList = {toggle() {}};
  }
  get textContent() { return this.text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this.text = value; this.replaceChildren(); }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  replaceChildren(...children) { this.children = []; this.append(...children); }
  setAttribute(key, value) {
    this.attributes[key] = value;
    if (['disabled', 'hidden', 'checked'].includes(key)) this[key] = true;
  }
  focus() { document.activeElement = this; }
}
const elements = new Map(), pending = [], requested = [];
const element = id => {
  if (!elements.has(id)) elements.set(id, new Element());
  return elements.get(id);
};
globalThis.HTMLElement = Element;
globalThis.document = {activeElement: null, getElementById: element, createElement: tag => new Element(tag), createTextNode: text => new Element('#text', text)};
globalThis.window = {location: {hash: ''}};
globalThis.history = {replaceState() { window.location.hash = ''; }};
globalThis.fetch = (url, options) => new Promise(resolve => {
  const request = {url, options, resolve}; pending.push(request); requested.push(request);
});
const pageModule = await import(pathToFileURL(process.argv[2]));
const descendants = node => [node, ...node.children.flatMap(descendants)];
const buttons = title => descendants(element('models_connections')).filter(node => node.tag === 'button' && node.textContent === title);
const accountButtons = title => descendants(element('chatgpt_accounts')).filter(node => node.tag === 'button' && node.textContent === title);
const submit = node => node.dispatchEvent(new Event('submit', {cancelable: true}));
const click = node => node.dispatchEvent(new Event('click'));
const flush = () => new Promise(resolve => setImmediate(resolve));
async function respond(path, body, status = 200) {
  const request = pending.shift(); assert.ok(request, `expected ${path}`);
  assert.equal(request.url, '/api/v9' + path);
  request.resolve({status, text: async () => JSON.stringify(body)});
  await flush(); return request;
}
let config = {version: 1, default: {provider: 'custom', model: 'large', effort: 'low'}, providers: [], models: [], presets: []};
let digest = 'one';
const accounts = {active: 'account-a', accounts: [
  {id: 'account-a', label: 'Same email · registration A', state: 'ready', signed_out: false, plan_enabled: true},
  {id: 'account-b', label: 'Same email · registration B', state: 'ready', signed_out: false, plan_enabled: true},
]};
const catalog = () => ({id: 'catalog:' + digest, digest, refreshing: false, providers: {
  custom: {connection: {state: 'ready', label: 'Custom', billing: 'local'}, models: [
    {id: 'large', label: 'Large', window: 500000, efforts: ['low', 'high'], pricing: {prompt: 0.00001, completion: '0.00002'}},
    {id: 'small', label: 'Small', efforts: []},
  ]},
  claude: {connection: {state: 'sign_in_required', label: 'Claude Code', billing: 'plan', reason: 'Signed out'}, models: [{id: 'opus'}]},
  openrouter: {connection: {state: 'sign_in_required', label: 'OpenRouter', billing: 'metered'}, models: []},
}});
async function finishLoad() {
  await respond('/status', {csrf: 'csrf', workspace: '/fixture'});
  await respond('/models/settings', {config, digest, errors: [], path: '/fixture/models.gene'});
  await respond('/models', catalog());
  await respond('/models/accounts', accounts);
}
pageModule.main(element('models_page'));
await finishLoad();
assert.match(element('models_connections').textContent, /Input \$0.00001\/token/);
assert.match(element('models_connections').textContent, /Run claude auth login/);
assert.equal(buttons('Set as default').at(-1).disabled, true, 'signed-out models cannot be selected as a default');
const smallForm = buttons('Set as default')[1].parentNode;
submit(smallForm);
let saving = pending[0];
assert.equal(saving.options.headers['x-csrf-token'], 'csrf');
let saved = JSON.parse(saving.options.body);
assert.deepEqual(saved.config.default, {provider: 'custom', model: 'small', effort: 'auto'});
assert.equal(saved.expected_digest, 'one');
config = saved.config; digest = 'two';
await respond('/models/settings', {config, digest, errors: []}); await finishLoad();
assert.equal(element('models_default').textContent, 'custom/small · auto');

click(buttons('Hide from picker')[0]);
saved = JSON.parse(pending[0].options.body);
assert.deepEqual(saved.config.models, [{provider: 'custom', id: 'large', hidden: true}]);
await respond('/models/settings', {code: 'revision_conflict', message: 'changed'}, 409);
config.presets = [{name: 'external', provider: 'custom', model: 'large'}]; digest = 'foreign';
await finishLoad();
assert.match(element('models_notice').textContent, /Review the refreshed settings/);
assert.equal(pending.length, 0, 'a conflict must not automatically resubmit a modified file');

element('endpoint_name').value = 'work'; element('endpoint_adapter').value = 'openai_responses';
element('endpoint_url').value = 'http://127.0.0.1:1234/v1'; element('endpoint_env').value = 'WORK_KEY_NAME';
element('endpoint_model').value = 'typed'; element('endpoint_discover').checked = false;
submit(element('models_endpoint_form'));
saved = JSON.parse(pending[0].options.body);
assert.deepEqual(saved.config.providers[0], {name: 'work', adapter: 'openai_responses', base_url: 'http://127.0.0.1:1234/v1',
  credential: {env: 'WORK_KEY_NAME'}, discover: false, models: [{id: 'typed'}]});
assert.equal(saved.expected_digest, 'foreign');
assert.equal(saved.config.presets[0].name, 'external', 'editing preserves the refreshed external changes');
config = saved.config; digest = 'three';
await respond('/models/settings', {config, digest, errors: []}); await finishLoad();

element('model_provider').value = 'custom'; element('model_id').value = 'new';
element('model_label').value = 'New model'; element('model_window').value = '64000';
element('model_efforts').value = 'low high'; element('model_default_effort').value = 'low';
submit(element('models_model_form'));
saved = JSON.parse(pending[0].options.body);
assert.deepEqual(saved.config.models[0], {provider: 'custom', id: 'new', label: 'New model', window: 64000,
  efforts: ['low', 'high'], default_effort: 'low'});
config = saved.config; digest = 'four';
await respond('/models/settings', {config, digest, errors: []}); await finishLoad();
assert.equal(pending.length, 0);
click(accountButtons('Use account')[0]);
assert.deepEqual(JSON.parse(pending[0].options.body), {id: 'account-b', action: 'select'});
accounts.active = 'account-b';
await respond('/models/accounts', {ok: true}); await finishLoad();
click(accountButtons('Sign out').at(-1));
assert.deepEqual(JSON.parse(pending[0].options.body), {id: 'account-b', action: 'sign_out'});
accounts.accounts[1].signed_out = true; accounts.accounts[1].state = 'sign_in_required';
await respond('/models/accounts', {ok: true, remote_revoked: false, message: 'Remote revocation was not confirmed.'});
await finishLoad();
assert.match(element('models_notice').textContent, /not confirmed/);
assert.equal(accountButtons('Sign out').length, 1, 'signing out affects only the selected registration');
click(accountButtons('Reconnect')[0]);
assert.deepEqual(JSON.parse(pending[0].options.body), {provider: 'chatgpt', account: 'account-a'});
await respond('/models/connect', {id: 'chatgpt-one', provider: 'chatgpt', state: 'pending', url: 'https://auth.openai.com/api/accounts/authorize?state=test'}, 202);
const chatgptLink = descendants(element('models_login')).find(node => node.tag === 'a');
assert.equal(chatgptLink.textContent, 'Continue with ChatGPT');
assert.equal(chatgptLink.attributes['data-oai-siwc-button'], '');
click(descendants(element('models_login')).find(node => node.tag === 'button'));
await respond('/models/login?id=chatgpt-one', {id: 'chatgpt-one', state: 'cancelled'});
click(buttons('Connect OpenRouter')[0]);
assert.deepEqual(JSON.parse(pending[0].options.body), {provider: 'openrouter'});
await respond('/models/connect', {id: 'login-one', state: 'pending', url: 'https://openrouter.ai/auth?state=test'}, 202);
const signInLink = descendants(element('models_login')).find(node => node.tag === 'a');
assert.equal(signInLink.attributes.href, 'https://openrouter.ai/auth?state=test');
assert.equal(signInLink.attributes['data-oai-siwc-button'], undefined);
assert.match(element('models_login').textContent, /OpenRouter credits/);
const cancelSignIn = descendants(element('models_login')).find(node => node.tag === 'button');
click(cancelSignIn);
assert.equal(pending[0].options.method, 'DELETE');
await respond('/models/login?id=login-one', {id: 'login-one', state: 'cancelled'});
assert.match(element('models_login').textContent, /cancelled/);
accounts.accounts[0].welcome_pending = true; accounts.active = 'account-a';
click(accountButtons('Use account')[0]);
await respond('/models/accounts', {ok: true}); await finishLoad();
assert.equal(element('models_welcome').hidden, false);
assert.match(element('models_welcome').textContent, /You're using your ChatGPT plan/);
const acknowledge = descendants(element('models_welcome')).find(node => node.tag === 'button');
assert.equal(document.activeElement, acknowledge);
click(acknowledge);
assert.deepEqual(JSON.parse(pending[0].options.body), {id: 'account-a', action: 'acknowledge'});
accounts.accounts[0].welcome_pending = false;
await respond('/models/accounts', {ok: true}); await finishLoad();
assert.equal(element('models_welcome').hidden, true);
assert.equal(pending.length, 0);
assert.equal(requested.some(request => request.url.includes('/rounds')), false, 'settings and discovery must never invoke inference');
console.log('Models page: connection labels, defaults, metadata, environment references, sign-in and conflict review passed');
