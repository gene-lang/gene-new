import {createGeneHost} from '/wasm_host.mjs';
import {runValueCases, runValueLifetime} from '/wasm_value_checks.mjs';

let report;
try {
  const module = await globalThis.GeneModule();
  const host = createGeneHost(module);
  const fixtures = await (await fetch('/fixtures/value_operations.json')).json();
  const cases = {cases: fixtures.cases.length, failures: []};
  for (const fixture of fixtures.cases) {
    await fetch('/progress', {method: 'POST', body: fixture.id});
    cases.failures.push(...runValueCases(host, {cases: [fixture]}).failures);
    if (cases.failures.some(f => f.trap)) break;
  }
  report = {cases};
  await fetch('/progress', {method: 'POST', body: 'lifetime'});
  if (cases.failures.length === 0) report.lifetime = runValueLifetime(host, module, fixtures);
} catch (error) {
  report = {error: String(error)};
}
report.ok = report.cases?.failures.length === 0 && report.lifetime?.ok === true;
document.getElementById('report').textContent = JSON.stringify(report);
document.body.dataset.state = report.ok ? 'passed' : 'failed';
await fetch('/report', {method: 'POST', headers: {'Content-Type': 'application/json'},
  body: JSON.stringify(report)});
