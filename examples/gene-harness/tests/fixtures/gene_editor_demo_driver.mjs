// Mount the compiled demo client under Node and check its initial wiring.
//
// Usage: node gene_editor_demo_driver.mjs <build-directory>
//
// The demo page's own routes are exercised against the running server by hand
// (see the demo README); this checks the browser half: it fetches the fixture
// list, opens the first document, creates the editor surface, and renders the
// picker — the part a server test cannot see.

import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { installDom, findByClass, findByTag, findAll } from './gene_editor_dom.mjs';

const directory = process.argv[2];
if (!directory) {
  console.error('usage: node gene_editor_demo_driver.mjs <build-directory>');
  process.exit(2);
}

const dom = installDom();
const { document } = dom;
const listNode = document.createElement('div');
listNode.setAttribute('id', 'demo_docs');
const statusNode = document.createElement('span');
statusNode.setAttribute('id', 'demo_status');
const root = document.createElement('div');
root.setAttribute('id', 'editor_root');
document.body.appendChild(listNode);
document.body.appendChild(statusNode);
document.body.appendChild(root);

const source = '# demo fixture\n(mod demo)\n\n(fn greet [name] name)\n';
const documentPayload = {
  ok: true,
  document: {
    id: 'demo.gene',
    name: 'demo.gene',
    path: 'demo.gene',
    kind: 'source',
    text: source,
    revision: 'rev-1',
    line_endings: 'lf',
    bom: false,
    readonly: false,
    reason: '',
  },
};
const documents = {
  ok: true,
  documents: [
    { id: 'demo.gene', name: 'demo.gene', readonly: false, reason: '', line_endings: 'lf', bom: false },
    { id: 'notes.gene', name: 'notes.gene', readonly: false, reason: '', line_endings: 'lf', bom: false },
    { id: 'mixed.gene', name: 'mixed.gene', readonly: true, reason: 'mixed line endings', line_endings: 'mixed', bom: false },
  ],
};

const requests = [];
globalThis.fetch = async (url, init = {}) => {
  requests.push({ url: String(url), method: init.method ?? 'GET' });
  const target = String(url);
  let body = '{}';
  if (target.includes('/api/documents')) body = JSON.stringify(documents);
  else if (target.includes('/api/document')) body = JSON.stringify(documentPayload);
  else if (target.includes('/api/log')) body = JSON.stringify({ ok: true, lines: [], cursor: '0', gap: '', reset: false });
  else if (target.includes('/api/analyze')) {
    // A minimal, correctly shaped analysis reply so the editor reaches its
    // "current" state rather than degrading.
    const request = JSON.parse(init.body ?? '{}');
    body = JSON.stringify({
      ok: true,
      parsed: true,
      partial: false,
      version: request.version,
      outline: [],
      tree: { children: [] },
      selected: { found: false },
      diagnostics: [],
    });
  } else body = JSON.stringify({ ok: true, text: source, version: 1 });
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    text: async () => body,
    json: async () => JSON.parse(body),
  };
};

const failures = [];
const expect = (name, condition) => {
  if (!condition) failures.push(name);
};

const modulePath = pathToFileURL(join(directory, 'client.mjs')).href;
const client = await import(modulePath);
client.main(root);
// The first listing and document are fetch promises; give the microtask queue
// and the timer queue room to settle them.
await new Promise(resolve => setTimeout(resolve, 150));

expect('the document list was requested',
  requests.some(request => request.url.includes('/api/documents')));
expect('the first document was requested',
  requests.some(request => request.url.includes('/api/document?id=demo.gene')));
const buttons = findAll(listNode, node => node.nodeType === 1 && node.tagName === 'BUTTON');
expect('the picker renders one button per document plus Logs', buttons.length === 4);
expect('the picker marks the opened document',
  buttons.some(button => button.textContent === 'demo.gene' && button.classList.contains('active')));
expect('the read-only fixture is labelled',
  buttons.some(button => button.textContent.startsWith('mixed.gene')));
expect('the status line names the opened document',
  statusNode.textContent.includes('demo.gene'));
const editor = findByClass(root, 'gene-editor');
expect('the editor surface mounted', editor !== null);
const textarea = editor ? findByTag(editor, 'textarea') : null;
expect('the editor has a textarea', textarea !== null);
expect('the textarea holds the document text', textarea?.value === source);
expect('the editor rendered its toolbar', editor ? findByClass(editor, 'ge-toolbar') !== null : false);
expect('the outline panel rendered', editor ? findByClass(editor, 'ge-outline') !== null : false);
expect('the structure panel rendered', editor ? findByClass(editor, 'ge-tree') !== null : false);
const analysis = requests.filter(request => request.url.includes('/api/analyze'));
expect('the editor asked for analysis', analysis.length > 0);

if (failures.length > 0) {
  console.error(`${failures.length} demo mount failure(s):`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log('demo client mounted, listed documents, and opened the first one');
