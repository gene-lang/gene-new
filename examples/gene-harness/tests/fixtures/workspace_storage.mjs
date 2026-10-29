import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const directory = process.argv[2];
const identity = name => {
  const html = readFileSync(join(directory, name), 'utf8');
  const id = html.match(/data-workspace-id="([^"]+)"/)?.[1];
  assert.ok(id, `Missing workspace identity in ${name}`);
  return id;
};
const first = identity('a.html');
const second = identity('b.html');
assert.notEqual(first, second);
assert.equal(first, identity('plugins.html'));

let workspaceId = first;
let documentPresent = true;
globalThis.document = {
  getElementById: id => documentPresent && id === 'harness_document'
    ? { dataset: { workspaceId } }
    : null,
};
const saved = new Map();
let quotaExceeded = false;
globalThis.sessionStorage = {
  getItem: key => saved.get(key) ?? null,
  setItem: (key, value) => {
    if (quotaExceeded) throw new Error('Storage quota exceeded');
    saved.set(key, value);
  },
  removeItem: key => saved.delete(key),
};
const storage = await import(pathToFileURL(join(directory, 'workspace_storage.mjs')));
const keys = [
  'gene-harness/question-drafts',
  'gene-harness/question-replies',
  'gene-harness/confirmations',
  'gene-harness/notification-actions',
  'gene-harness/media-draft/default',
  'gene-harness/pending',
];
for (const key of keys) {
  saved.set(key, 'unscoped old state');
  workspaceId = first;
  assert.equal(storage.storage_get(key), '');
  assert.equal(storage.storage_set(key, 'first workspace'), true);
  workspaceId = second;
  assert.equal(storage.storage_get(key), '');
  assert.equal(storage.storage_set(key, 'second workspace'), true);
  workspaceId = first;
  assert.equal(storage.storage_get(key), 'first workspace');
  storage.storage_remove(key);
  assert.equal(storage.storage_get(key), '');
  workspaceId = second;
  assert.equal(storage.storage_get(key), 'second workspace');
}
quotaExceeded = true;
assert.equal(storage.storage_set('gene-harness/pending', 'cannot save'), false);
quotaExceeded = false;
workspaceId = '';
const before = saved.size;
assert.equal(storage.storage_set('gene-harness/pending', 'no workspace'), false);
assert.equal(storage.storage_get('gene-harness/pending'), '');
storage.storage_remove('gene-harness/pending');
assert.equal(saved.size, before);
workspaceId = first;
documentPresent = false;
assert.equal(storage.storage_set('gene-harness/pending', 'no document identity'), false);
assert.equal(storage.storage_get('gene-harness/pending'), '');
storage.storage_remove('gene-harness/pending');
assert.equal(saved.size, before);
console.log('workspace storage: generated page identities, six isolated state families, quota and missing-identity handling passed');
