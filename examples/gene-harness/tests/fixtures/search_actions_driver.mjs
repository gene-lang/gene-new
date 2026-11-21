// Exercise the search host actions and the trigger panel without a browser.
//
// Usage: node search_actions_driver.mjs <web-build-directory>
//
// The build directory holds `spotlight.mjs` and `triggers.mjs`. The scenario
// checks that the trigger toolbar button is gone, that search opens the
// trigger panel, that Plugins navigates, and that Restart needs a second
// selection before it posts a confirmed control request.

import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { installDom, findByClass, findAll } from './gene_editor_dom.mjs';

const directory = process.argv[2];
if (!directory) {
  console.error('usage: node search_actions_driver.mjs <build-directory>');
  process.exit(2);
}

const { document, window } = installDom();
const failures = [];
const checks = [];
const check = (name, condition, detail = '') => {
  checks.push(name);
  if (!condition) failures.push(detail ? `${name}: ${detail}` : name);
};
const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));

// --- triggers: no toolbar button; search opens the panel -------------------
const triggerRoot = document.createElement('div');
document.body.appendChild(triggerRoot);
const triggerToolbar = document.createElement('span');
document.body.appendChild(triggerToolbar);
const shared = {};
const triggerRequests = [];
const triggerBridge = {
  shared,
  toolbar: triggerToolbar,
  api(method, path, payload, done) {
    triggerRequests.push({ method, path, payload });
    if (method === 'GET') done(200n, { triggers: [] });
    else done(201n, {});
  },
};
triggerRoot.harness_bridge = triggerBridge;
const triggers = await import(pathToFileURL(join(directory, 'triggers.mjs')).href);
triggers.main(triggerRoot);
check('no trigger button in the toolbar', findByClass(triggerToolbar, 'triggers-launcher') === null);
check('publishes the trigger opener on the shared bridge', typeof shared.openTriggers === 'function');
shared.openTriggers();
await tick(10);
const panels = findAll(triggerRoot, node => node.classList?.contains('triggers-panel'));
const panel = panels[0];
check('opens the trigger panel', Boolean(panel) && panel.hidden === false);
check('presents the panel as a fixed overlay',
  panel?.style?.getPropertyValue('position') === 'fixed',
  panel ? JSON.stringify([...panel.style?._styles ?? []]) : 'missing panel');
check('loads trigger definitions',
  triggerRequests.some(request => request.method === 'GET' && String(request.path).endsWith('/p/triggers')),
  JSON.stringify(triggerRequests));
const close = findAll(panel ?? triggerRoot, node => node.tagName === 'BUTTON' && node.textContent === 'Close')[0];
check('renders a close button', Boolean(close));
if (close) close.click();
check('closes the trigger panel', panel.hidden === true);
const triggerController = triggerRoot.harnessController ?? triggerRoot.harness_controller;
check('publishes a controller', Boolean(triggerController));

// --- spotlight: local host actions ----------------------------------------
const spotRoot = document.createElement('div');
document.body.appendChild(spotRoot);
const spotToolbar = document.createElement('span');
document.body.appendChild(spotToolbar);
const controlCalls = [];
const navigations = [];
const spotBridge = {
  shared,
  toolbar: spotToolbar,
  owner: 'spotlight',
  claim: () => true,
  release: () => {},
  state: () => ({ session: '', title: '', commands: [], views: [], pending_command: null }),
  api(method, path, payload, done) {
    if (String(path).includes('/control')) {
      controlCalls.push({ method, path, payload });
      done(200n, { message: 'Stopped.' });
      return;
    }
    if (String(path).includes('/search/sessions')) {
      done(200n, { results: [] });
      return;
    }
    done(200n, {});
  },
  navigate(item, done) { navigations.push(item); done(200n, {}); },
  command(session, text, expected, done) { done(200n, {}); },
};
spotRoot.harness_bridge = spotBridge;
spotRoot.harness_owner = 'spotlight';
const spotlight = await import(pathToFileURL(join(directory, 'spotlight.mjs')).href);
spotlight.main(spotRoot);
const launcher = findByClass(spotToolbar, 'spotlight-launcher');
check('has a search launcher', Boolean(launcher));
launcher.click();
await tick(10);
const options = () => findAll(spotRoot, node => node.classList?.contains('spotlight-option'));
const pick = title => options().find(option => option.textContent.includes(title));
for (const title of ['Triggers', 'Plugins', 'Restart Harness', 'Stop Harness']) {
  check(`lists ${title}`, options().some(option => option.textContent.includes(title)),
    options().map(option => option.textContent).join(' | '));
}
const triggerOption = pick('Triggers');
check('selects the trigger action', Boolean(triggerOption));
if (triggerOption) triggerOption.click();
await tick(0);
check('opens triggers from search', panel.hidden === false);

launcher.click();
await tick(10);
const restartOnce = pick('Restart Harness');
if (restartOnce) restartOnce.click();
await tick(0);
check('restart needs a second selection', controlCalls.length === 0);
check('asks before restarting', (spotRoot.textContent ?? '').includes('Select Restart Harness again'));
const restartTwice = pick('Restart Harness');
if (restartTwice) restartTwice.click();
await tick(0);
const payload = controlCalls[0]?.payload;
const action = payload?.action ?? payload?.get?.('action');
const confirm = payload?.confirm ?? payload?.get?.('confirm');
check('posts a confirmed restart',
  controlCalls.length === 1 && action === 'restart' && confirm === true,
  JSON.stringify(controlCalls));

launcher.click();
await tick(10);
const pluginsOption = pick('Plugins');
if (pluginsOption) pluginsOption.click();
await tick(0);
check('navigates to the plugin page', String(window.location.href).endsWith('/plugins'), window.location.href);

if (triggerController) triggerController.dispose();
check('clears the trigger opener on dispose', shared.openTriggers == null);

console.log(`SEARCH ${JSON.stringify({ checks: checks.length, failures })}`);
if (failures.length > 0) {
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log('all search action scenarios passed');
process.exit(0);
