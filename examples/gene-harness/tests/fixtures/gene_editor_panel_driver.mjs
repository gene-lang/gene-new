// Run the Harness editor panel scenarios under Node.
//
// Usage: node gene_editor_panel_driver.mjs <build-directory>
//
// The build directory is the output of
//   gene build --target web --out-dir <dir> gene_editor_panel_scenarios.gene
// This installs the small DOM, creates the panel elements the host page owns,
// and reports the scenario result object.

import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { installDom } from './gene_editor_dom.mjs';

const directory = process.argv[2];
if (!directory) {
  console.error('usage: node gene_editor_panel_driver.mjs <build-directory>');
  process.exit(2);
}

const dom = installDom();
const { document } = dom;
const add = (tag, id, setup) => {
  const node = document.createElement(tag);
  if (id) node.setAttribute('id', id);
  if (setup) setup(node);
  document.body.appendChild(node);
  return node;
};

// The page identity workspace_storage scopes drafts by.
const identity = add('html', 'harness_document');
identity.dataset.workspaceId = 'workspace-panel-scenario';
add('aside', 'editor_panel', node => {
  node.hidden = true;
});
add('strong', 'editor_title');
add('span', 'editor_status');
add('button', 'editor_tab_source');
add('button', 'editor_tab_logs');
add('button', 'editor_attach_log');
add('div', 'editor_source_view');
add('div', 'gene_log_root', node => { node.hidden = true; });
add('input', 'editor_path');
add('button', 'editor_open');
add('button', 'editor_attach');
add('button', 'editor_attach_draft');
add('button', 'editor_close');
add('div', 'gene_editor_root');

const modulePath = pathToFileURL(
  join(directory, 'gene_editor_panel_scenarios.mjs'),
).href;
const scenarios = await import(modulePath);

let payload;
try {
  payload = scenarios.run();
} catch (error) {
  console.error('panel scenario run failed:', error);
  process.exit(1);
}

let result;
try {
  result = JSON.parse(payload);
} catch (error) {
  console.error(`panel scenario result was not JSON: ${payload}`);
  process.exit(1);
}

console.log(`PANEL ${payload}`);
const failures = result.failures ?? [];
if (failures.length > 0) {
  console.error(`${failures.length} panel scenario failure(s):`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log('all Harness editor panel scenarios passed');
