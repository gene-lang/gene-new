// Acceptance checks for the compiled optional model picker.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';

class Element extends EventTarget {
  constructor(tag = 'div', text = '') {
    super(); this.tag = tag; this.text = text; this.children = []; this.attributes = {};
    this.value = ''; this.hidden = false; this.disabled = false;
    this.classList = {toggle() {}};
  }
  get firstChild() { return this.children[0] ?? null; }
  get textContent() { return this.text + this.children.map(node => node.textContent).join(''); }
  set textContent(value) { this.text = value; this.children = []; }
  append(...children) { children.forEach(node => this.appendChild(node)); }
  replaceChildren(...children) { this.children = []; this.text = ''; this.append(...children); }
  appendChild(node) { this.children.push(node); node.parentNode = this; return node; }
  removeChild(node) { this.children.splice(this.children.indexOf(node), 1); node.parentNode = null; }
  setAttribute(name, value) { this.attributes[name] = value; if (name === 'hidden') this.hidden = true; }
  focus() { document.activeElement = this; }
}
globalThis.HTMLElement = Element;
globalThis.document = {
  createElement: tag => new Element(tag),
  createTextNode: text => new Element('#text', text),
  activeElement: null,
};
const picker = await import(pathToFileURL(process.argv[2]));
const nodes = node => [node, ...node.children.flatMap(nodes)];
const button = (node, title) => nodes(node).find(item => item.tag === 'button' && item.textContent === title);
const click = node => { assert.ok(node, 'expected button'); assert.equal(node.disabled, false); node.dispatchEvent(new Event('click')); };
const root = new Element(), controls = new Element(), triggerControls = new Element();
const catalog = {
  id: 'catalog:1', digest: 'digest:1', default: {},
  providers: {
    plan: {connection: {state: 'ready', label: 'Plan', billing: 'plan'}, models: [
      {id: 'large', label: 'Large', efforts: ['low', 'high'], default_effort: 'high'},
      {id: 'small', label: 'Small', efforts: ['low'], default_effort: 'low'},
      {id: 'hidden', label: 'Hidden', hidden: true},
    ]},
    openrouter: {connection: {state: 'ready', label: 'OpenRouter', billing: 'metered'}, models: [
      {id: 'vendor/remote', label: 'Remote', efforts: ['high'], default_effort: 'high'},
    ]},
    signedout: {connection: {state: 'sign_in_required', label: 'Signed out', billing: 'metered'}, models: [
      {id: 'offline', label: 'Unavailable'},
    ]},
    chatgpt: {connection: {state: 'ready', label: 'ChatGPT', billing: 'plan'}, models: [
      {id: 'gpt-fixture', label: 'ChatGPT fixture', efforts: []},
    ]},
  },
  presets: [{name: 'Unavailable preset', provider: 'signedout', model: 'offline'}],
};
let listener, choice = null, triggerChoice = {}, required = false, loaded = false, requested = true, resumed = 0;
let requestedTrigger = null;
let claims = 0, releases = 0, defer = false, delayed = [], requests = [];
const state = {session: 's', workspace: 'fixture', ready: true, model_settings: null};
root.harness_owner = 'models:1';
root.harness_bridge = {
  composer_actions: controls,
  trigger_model_actions: triggerControls,
  state: () => state,
  claim: () => { claims++; return true; },
  release: () => { releases++; },
  subscribe: callback => { listener = callback; return () => { listener = null; }; },
  capabilities: {models: {
    state: () => ({choice, required, loaded, requested}),
    choose: value => { choice = {value}; },
    trigger_state: () => triggerChoice,
    choose_trigger: value => { triggerChoice = value; listener?.('models/trigger-choice', '', {}); },
    trigger_target: () => requestedTrigger,
    release_trigger: target => { if (target === requestedTrigger) requestedTrigger = null; },
    configure: (nextLoaded, nextRequired) => { loaded = nextLoaded; required = nextRequired; },
    resume: () => { requested = false; resumed++; },
  }},
  api: (method, path, payload, done) => {
    requests.push({method, path, payload});
    const reply = () => {
      if (path.endsWith('/models/preview')) {
        const value = {...catalog.default, ...payload.model_settings};
        const provider = value.provider ?? 'plan', model = value.model ?? 'large';
        const row = catalog.providers[provider].models.find(item => item.id === model);
        const effort = value.effort ?? 'auto';
        done(200n, {model: {provider, model, label: row?.label ?? model, requested_effort: effort,
          unverified_model: !row,
          billing: catalog.providers[provider].connection.billing,
          effective_effort: effort === 'auto' ? row?.default_effort : row?.efforts?.includes(effort) ? effort : row?.efforts?.[0] ?? effort,
          automatic_provider: !value.provider, pins: {}}, model_settings: payload.model_settings});
      } else if (path.endsWith('/models/default')) {
        assert.equal(payload.expected_digest, catalog.digest);
        catalog.default = payload.model_settings; catalog.digest = 'digest:2';
        done(200n, {default: catalog.default, digest: catalog.digest});
      } else done(200n, catalog);
    };
    if (defer) delayed.push(reply); else reply();
  },
};
picker.main(root);
assert.equal(loaded, true);
assert.equal(required, true, 'several automatic connections require a first-run choice');
assert.equal(claims, 1, 'a pending first prompt opens the chooser');
assert.equal(button(root, 'Unavailable preset').disabled, true);
assert.equal(button(root, 'Unavailable'), undefined, 'signed-out models cannot be selected');
assert.equal(button(root, 'Remote'), undefined, 'uncurated OpenRouter models require search');
nodes(root).find(node => node.attributes['aria-label'] === 'Model menu effort').value = 'high';
click(button(root, 'Apply effort'));
assert.equal(catalog.default.model, 'large');
assert.equal(catalog.default.effort, 'high');
assert.equal(choice, null, 'choosing the first default must not pin the session');
assert.equal(required, false);
assert.equal(resumed, 1);

click(button(triggerControls, 'Default · Large'));
click(button(root, 'Small'));
assert.equal(triggerChoice.model, 'small');
assert.equal(choice, null, 'choosing a trigger model must not change the session');
assert.equal(catalog.default.model, 'large', 'choosing a trigger model must not change the shared default');
assert.ok(button(controls, 'Default · Large'));
assert.match(triggerControls.textContent, /Runs unattended · plan/);
click(button(triggerControls, 'Small'));
const menuEffort = nodes(root).find(node => node.attributes['aria-label'] === 'Model menu effort');
menuEffort.value = 'low';
click(button(root, 'Apply effort'));
assert.equal(triggerChoice.effort, 'low');
let editedTrigger;
requestedTrigger = {id: 1n, selection: triggerChoice, button: button(triggerControls, 'Small'), choose: value => { editedTrigger = value; }};
listener('models/trigger', '', {});
click(button(root, 'Follow default'));
assert.deepEqual(editedTrigger, {}, 'editing an existing trigger can clear its pin');
assert.equal(requestedTrigger, null);

click(button(controls, 'Default · Large'));
click(button(root, 'Small'));
assert.equal(choice.value.model, 'small');
assert.equal(button(controls, 'Small').textContent, 'Small');
const effort = nodes(controls).find(node => node.tag === 'select');
effort.value = 'high'; effort.dispatchEvent(new Event('change'));
assert.equal(choice.value.effort, 'high');
assert.match(effort.textContent, /High → Low/, 'the requested effort survives model adjustment');

click(button(controls, 'Small'));
const search = nodes(root).find(node => node.attributes.type === 'search');
search.value = 'remote'; search.dispatchEvent(new Event('input'));
click(button(root, 'Remote'));
assert.equal(choice.value.provider, 'openrouter');
assert.equal(choice.value.model, 'vendor/remote');
click(button(controls, 'Remote'));
const provider = nodes(root).find(node => node.attributes['aria-label'] === 'Provider for model id');
const id = nodes(root).find(node => node.attributes['aria-label'] === 'Model id');
provider.value = 'plan'; id.value = 'new-model';
click(button(root, 'Use a model id'));
assert.equal(choice.value.model, 'new-model');
assert.equal(choice.value.effort, 'high');
assert.equal(button(controls, 'Unverified · new-model').textContent, 'Unverified · new-model');
assert.equal(requests.some(request => 'expected_selection' in (request.payload ?? {})), false,
  'the picker must not introduce a preview admission contract');
click(button(controls, 'Unverified · new-model'));
search.value = 'ChatGPT'; search.dispatchEvent(new Event('input'));
click(button(root, 'ChatGPT fixture'));
const planUsage = nodes(controls).find(node => node.attributes.class === 'models-plan');
assert.equal(planUsage.hidden, false);
assert.match(planUsage.textContent, /Using ChatGPT plan/);
assert.equal(nodes(planUsage).find(node => node.tag === 'a').attributes.href, 'https://chatgpt.com/settings/usage');

defer = true;
root.harnessController.update({catalog_revision: 'catalog:2'});
assert.ok(delayed.length);
root.harnessController.dispose();
assert.equal(listener, null);
assert.equal(controls.children.length, 0);
assert.equal(triggerControls.children.length, 0);
assert.equal(root.children.length, 0);
delayed.forEach(reply => reply());
assert.equal(controls.children.length, 0, 'a late catalog response cannot restore disposed controls');
assert.ok(releases > 0);
console.log('model picker: first-run default, independent trigger/session choices, effort adjustment, signed-out connections, search, typed ids and disposal passed');
