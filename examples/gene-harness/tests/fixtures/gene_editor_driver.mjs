// Run the compiled editor scenarios under Node.
//
// Usage: node gene_editor_driver.mjs <build-directory>
//
// The build directory is the output of
//   gene build --target web --out-dir <dir> gene_editor_scenarios.gene
// and must contain gene_editor_scenarios.mjs. The driver installs the fake
// DOM before importing it, runs the synchronous scenarios, waits past the
// typing debounce so the timer step can observe its analysis request, then
// reports both phases and exits nonzero on any failure.

import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { installDom } from './gene_editor_dom.mjs';

const directory = process.argv[2];
if (!directory) {
  console.error('usage: node gene_editor_driver.mjs <build-directory>');
  process.exit(2);
}

installDom();

const modulePath = pathToFileURL(join(directory, 'gene_editor_scenarios.mjs')).href;
const scenarios = await import(modulePath);

const failures = [];
const report = (label, payload) => {
  console.log(`${label} ${payload}`);
  let parsed;
  try {
    parsed = JSON.parse(payload);
  } catch (error) {
    failures.push(`${label}: result was not JSON (${error.message})`);
    return;
  }
  for (const failure of parsed.failures ?? []) failures.push(`${label}: ${failure}`);
};

let handle;
try {
  handle = scenarios.run();
} catch (error) {
  console.error('scenario run failed:', error);
  process.exit(1);
}
report('SYNC', handle.sync);

await new Promise(resolve => setTimeout(resolve, 350));

try {
  report('TIMERS', handle.finish());
} catch (error) {
  console.error('timer phase failed:', error);
  process.exit(1);
}

if (failures.length > 0) {
  console.error(`\n${failures.length} scenario failure(s):`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log('\nall editor scenarios passed');
