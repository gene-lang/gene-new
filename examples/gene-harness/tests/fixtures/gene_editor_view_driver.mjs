// Mount the dockable editor browser client under Node.
//
// Usage: node gene_editor_view_driver.mjs <build-directory>
//   gene build --target web --out-dir <dir> client/editor_view.gene
//
// The host page supplies a bridge; this checks source open and analysis,
// Source/Logs tab switching with independent mounts, scoped view-state saves,
// availability changes, and controller disposal.

import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { installDom } from './gene_editor_dom.mjs';

const directory = process.argv[2];
if (!directory) {
  console.error('usage: node gene_editor_view_driver.mjs <build-directory>');
  process.exit(2);
}

const { document } = installDom();
const identity = document.createElement('html');
identity.setAttribute('id', 'harness_document');
identity.dataset.workspaceId = 'view-workspace';
document.body.appendChild(identity);

const failures = [];
const checks = [];
const check = (name, condition, detail = '') => {
  checks.push(name);
  if (!condition) failures.push(detail ? `${name}: ${detail}` : name);
};
const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
const all = node => [node, ...node.childNodes.flatMap(child => all(child))];
const byText = (root, text) => all(root).find(node =>
  String(node.tagName).toLowerCase() === 'button' && node.textContent.trim() === text);

const requests = [];
const saves = [];
const attachments = [];
const analysisTree = {
  children: [
    { id: 0n, label: 'a', summary: '', path: '1', kind: 'node', closed: true,
      startByte: 0n, endByte: 10n, startUtf16: 0n, endUtf16: 10n, children: [], more: 0n },
  ],
};
const api = (method, path, payload, done) => {
  requests.push({ method, path });
  if (path.includes('/document')) {
    done(200n, { ok: true, document: {
      id: 'demo.gene', name: 'demo.gene', path: 'demo.gene', kind: 'source',
      text: '(mod demo)\n(fn a [] 1)\n', revision: 'rev-1',
      line_endings: 'lf', bom: false, readonly: false, reason: '',
    } });
    return;
  }
  if (path.includes('/analyze')) {
    done(200n, { ok: true, parsed: true, partial: false, version: payload.version,
      outline: [], tree: analysisTree, selected: { found: false }, diagnostics: [] });
    return;
  }
  if (path.includes('/save')) {
    done(200n, { ok: true, revision: 'rev-2', line_endings: 'lf', bom: false });
    return;
  }
  if (path.includes('/log')) {
    done(200n, { ok: true, state: 'ok', cursor: 'cursor-1', lines: ['boot', 'ready'], gap: '' });
    return;
  }
  done(200n, { ok: true });
};

const root = document.createElement('div');
document.body.appendChild(root);
const bridge = {
  view: { name: 'editor_view', title: 'Gene editor', presentation: 'docked',
    state_version: '1', view_state: { path: 'demo.gene', tab: 'source', log_cursor: '' } },
  state: () => ({ plugins: [{ id: 'editor', state: 'ready' }] }),
  api,
  save_view_state: changes => { saves.push(changes); },
  attach: text => { attachments.push(text); return true; },
  subscribe_owned: () => () => {},
};
root.harness_bridge = bridge;

const moduleURL = pathToFileURL(join(directory, 'editor_view.mjs')).href;
const viewModule = await import(moduleURL);
viewModule.main(root);

check('mounts the wrapper header', root.textContent.includes('Gene editor'));
check('requests the saved view path', requests.some(request => request.path.includes('/document')));
check('analyzes the opened buffer', requests.some(request => request.path.includes('/analyze')));
const controller = root.harness_controller ?? root.harnessController;
check('publishes a controller', Boolean(controller));
check('persists the opened path', saves.some(changes => changes.path === 'demo.gene'), JSON.stringify(saves));

// Source and Logs are independent mounts.

const logsTab = byText(root, 'Logs');
check('exposes a Logs tab', Boolean(logsTab));
logsTab.dispatchEvent({ type: 'click', preventDefault() {} });
await tick(10);
check('requests a log increment', requests.some(request => request.path.includes('/log')));
check('renders the returned log lines', root.textContent.includes('boot') && root.textContent.includes('ready'));
check('switches the saved tab', saves.some(changes => changes.tab === 'logs'), JSON.stringify(saves));
const sourceTab = byText(root, 'Source');
sourceTab.dispatchEvent({ type: 'click', preventDefault() {} });
await tick(5);
check('switches back to source', saves.some(changes => changes.tab === 'source'));

// Disabling the plugin keeps the mount and reports the state.
controller.update({ plugins: [{ id: 'editor', state: 'pending' }] });
check('reports plugin disablement', root.textContent.includes('unavailable'));

// The host disposes the controller when the outlet disappears.
const textarea = all(root).find(node => String(node.tagName).toLowerCase() === 'textarea');
check('mounted the source textarea', Boolean(textarea));
textarea.value = '(mod demo)\n(fn draft [] 42)\n';
textarea.dispatchEvent({ type: 'input' });
await tick(10);
controller.dispose();
check('disposes the mounted editors', !textarea || !textarea.isConnected);

// A view switch disposes the outlet. Remounting the module with the same
// workspace and view state must restore the scoped draft.
const secondRoot = document.createElement('div');
document.body.appendChild(secondRoot);
const secondBridge = { ...bridge };
secondBridge.view = { ...bridge.view, view_state: { path: 'demo.gene', tab: 'source', log_cursor: '' } };
secondRoot.harness_bridge = secondBridge;
viewModule.main(secondRoot);
await tick(10);
const restored = all(secondRoot).find(node => String(node.tagName).toLowerCase() === 'textarea');
check('restores the draft after a view switch',
  Boolean(restored) && restored.value.includes('(fn draft [] 42)'),
  restored ? restored.value.slice(0, 80) : 'no textarea');
const secondController = secondRoot.harness_controller ?? secondRoot.harnessController;
secondController.dispose();

console.log(`VIEW ${JSON.stringify({ checks: checks.length, failures })}`);
if (failures.length > 0) {
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log('all dockable editor view scenarios passed');
