// Exercise the host-side view outlet manager without a browser.
//
// Usage: node gene_editor_outlet_driver.mjs <build-directory>
//
// The build directory is `gene build --target web` output for
// client/browser_clients.gene. A tiny module fixture plays the browser
// contribution; this checks persistent mount, update, key, revision
// replacement, view/workspace changes, disablement, and load cancellation.

import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { installDom } from './gene_editor_dom.mjs';

const directory = process.argv[2];
if (!directory) {
  console.error('usage: node gene_editor_outlet_driver.mjs <build-directory>');
  process.exit(2);
}

const { document, window } = installDom();
const harnessRoot = document.createElement('div');
harnessRoot.setAttribute('id', 'harness_root');
document.body.appendChild(harnessRoot);
const moduleURL = pathToFileURL(join(directory, 'browser_clients.mjs')).href;
const clients = await import(moduleURL);

const failures = [];
const checks = [];
const check = (name, condition, detail = '') => {
  checks.push(name);
  if (!condition) failures.push(detail ? `${name}: ${detail}` : name);
};
const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
const fixture = name => pathToFileURL(join(import.meta.dirname, name)).href;

const toolbar = document.createElement('span');
const composer = document.createElement('span');
document.body.appendChild(toolbar);
document.body.appendChild(composer);
const bridge = {
  toolbar,
  composer_actions: composer,
  state: () => ({ ready: true }),
  api: (method, path, payload, done) => done(200, {}),
  subscribe_owned: () => () => {},
};
const host = clients.create_clients(document.body, false, bridge);
const element = document.createElement('div');
document.body.appendChild(element);
// A real view tree iterates PropMap keys, which are Syms. A symbol key
// exercises the text boundary the host record runs through.
const outlet = { name: 'probe', element, key: Symbol.for('probe_outlet') };
const saves = [];
const status = { ready: true, plugins: [{ id: 'probe', state: 'ready' }] };
const context = {
  workspace: 'ws-one',
  view_name: 'probe_view',
  view: { name: 'probe_view', title: 'Probe view', presentation: 'docked', state_version: '1' },
  view_state: { path: 'initial.gene' },
  save: changes => saves.push(changes),
  status,
};
const descriptor = revision => ({
  name: 'probe',
  revision,
  url: fixture('outlet_probe.mjs'),
  stylesheet: '',
  scope: 'view',
});

clients.update_clients(host, [descriptor('r1')], status);
clients.update_outlets(host, [outlet], context);
await tick(20);
check('mounts the contribution in the outlet', element.dataset.mounted === '1');
check('passes view identity and state', element.dataset.view === 'probe_view' && element.dataset.path === 'initial.gene', JSON.stringify(element.dataset));
check('delivers save_view_state', saves.length > 0 && saves[0].path === 'chosen.gene', JSON.stringify(saves));
check('publishes a controller', Boolean(element.harness_controller));

// A view-tree update with the same element and revision keeps the mount.
clients.update_outlets(host, [{ ...outlet, key: 'renamed_key' }], context);
await tick(5);
check('keeps the mount across a view-tree update', element.dataset.mounted === '1');
check('updates the controller', Number(element.dataset.updates) >= 1);

// The contribution key handler participates in the host dispatcher.
window.dispatchEvent({ type: 'keydown', key: 'k', code: 'KeyK', ctrlKey: false, metaKey: false, shiftKey: false, altKey: false, composing: false, preventDefault() {}, stopPropagation() {} });
check('routes keys from the view outlet', element.dataset.key === '1');

// A new contribution revision replaces the mount.
clients.update_clients(host, [descriptor('r2')], status);
clients.update_outlets(host, [outlet], { ...context, view_state: { path: 'second.gene' } });
await tick(20);
check('remounts on a contribution revision', element.dataset.mounted === '1' && element.dataset.path === 'second.gene');
check('disposed the previous controller', element.dataset.disposed === '1');
delete element.dataset.disposed;

// A different view name disposes the outlet.
clients.update_outlets(host, [], { ...context, view_name: 'other_view' });
check('disposes when the view changes', element.dataset.disposed === '1');
delete element.dataset.disposed;

// The outlet mounts again, then a workspace change disposes it.
clients.update_outlets(host, [outlet], context);
await tick(20);
check('remounts in the original workspace', element.dataset.mounted === '1');
clients.update_outlets(host, [outlet], { ...context, workspace: 'ws-two' });
check('disposes when the workspace changes', element.dataset.disposed === '1');
delete element.dataset.disposed;

// Re-mount, then disable the contribution.
clients.update_clients(host, [descriptor('r3')], status);
clients.update_outlets(host, [outlet], context);
await tick(20);
check('remounts after disposal', element.dataset.mounted === '1');
clients.update_clients(host, [], status);
clients.update_outlets(host, [outlet], context);
check('disposes when the contribution is disabled', element.dataset.disposed === '1');
check('labels a disabled outlet', element.textContent.includes('unavailable'));

// Removing the outlet while the module is still loading must not mount it.
const slowElement = document.createElement('div');
document.body.appendChild(slowElement);
clients.update_clients(host, [{ ...descriptor('r4'), url: fixture('outlet_slow.mjs') }], status);
clients.update_outlets(host, [{ name: 'probe', element: slowElement, key: 'slow' }], context);
clients.update_outlets(host, [], context);
await tick(120);
check('cancels a mount that finished after the outlet disappeared', slowElement.dataset.mounted === undefined, JSON.stringify(slowElement.dataset));

console.log(`OUTLET ${JSON.stringify({ checks: checks.length, failures })}`);
if (failures.length > 0) {
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log('all view outlet scenarios passed');
