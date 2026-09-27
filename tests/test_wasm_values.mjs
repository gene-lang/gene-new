import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {createGeneHost} from './wasm_host.mjs';
import {runValueCases, runValueLifetime} from './wasm_value_checks.mjs';

if (!process.env.GENE_WASM_MODULE) throw new Error('GENE_WASM_MODULE is required');
const {default: factory} = await import(pathToFileURL(resolve(process.env.GENE_WASM_MODULE)).href);
const module = await factory();
const host = createGeneHost(module);
const fixtures = JSON.parse(readFileSync(new URL('./fixtures/value_operations.json', import.meta.url)));
const cases = runValueCases(host, fixtures);
const report = {cases};
if (cases.failures.length === 0) {
  try { report.lifetime = runValueLifetime(host, module, fixtures); }
  catch (error) { report.lifetime = {ok: false, error: String(error)}; }
}
if (process.env.GENE_WASM_REPORT) writeFileSync(process.env.GENE_WASM_REPORT, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
process.exit(cases.failures.length === 0 && report.lifetime?.ok ? 0 : 1);
