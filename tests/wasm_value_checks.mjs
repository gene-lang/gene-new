// Shared semantic and lifetime checks run unchanged under Node and Chromium.
export function runValueCases(host, fixtures) {
  const failures = [];
  for (const fixture of fixtures.cases) {
    let result;
    try { result = host.evaluate(fixture.source); }
    catch (error) {
      failures.push({id: fixture.id, trap: String(error)});
      break; // a trapped guest is not a valid oracle for subsequent cases
    }
    const textMatches = fixture.contains !== undefined
      ? result.text.includes(fixture.contains) : result.text === fixture.text;
    if (result.status !== (fixture.status ?? 0) || !textMatches || result.out !== '') {
      failures.push({id: fixture.id, result, expected: fixture});
    }
  }
  return {cases: fixtures.cases.length, failures};
}

const witnessForm = `(do
  (type WasmKey ^props {^text Str})
  (impl ValueEq for WasmKey
    (message equal [other : WasmKey] : Bool (== self/text other/text)))
  (impl ValueHash for WasmKey (message hash [] : Int ($hash self/text)))
  (impl ValueOrder for WasmKey
    (message compare [other : WasmKey] : Int
      (if (< self/text other/text) -1 (if (> self/text other/text) 1 0))))
  WasmKey)`;

function jsonResult(host, source) {
  const result = host.evaluate(source);
  if (result.status !== 0) throw new Error(JSON.stringify(result));
  return JSON.parse(JSON.parse(result.text));
}

export function runValueLifetime(host, module, fixtures) {
  if (!module._gene_test_heap_bytes || !module._gene_test_result_handles ||
      !module._gene_test_scope_retirement) {
    throw new Error('lifetime qualification requires the geneRcStats test exports');
  }
  const generationSource = `
    (let form (quote ${witnessForm}))
    (fn snapshot []
      ($runtime/test_collect)
      (let s ($runtime/gc_stats))
      ($println ($json/stringify
        {^rc_stats s/rc_stats? ^live s/live_managed ^classes s/managed_classes
         ^roots s/native_roots})))
    (repeat 20 (eval form ^in (env)))
    (snapshot)
    (for batch in [1 100 1000]
      (repeat batch (eval form ^in (env)))
      (snapshot)) nil`;
  const generationResult = host.evaluate(generationSource);
  if (generationResult.status !== 0) throw new Error(JSON.stringify(generationResult));
  const snapshots = generationResult.out.trim().split('\n').map(line => JSON.parse(line));
  const baseline = snapshots[0];
  const generationFlat = baseline.rc_stats === true && baseline.roots === 0 &&
    snapshots.every(s => s.live === baseline.live && s.roots === 0 &&
      JSON.stringify(s.classes) === JSON.stringify(baseline.classes));

  const retainedSource = `
    (let form (quote ${witnessForm}))
    (fn live [] ($runtime/test_collect) (let s ($runtime/gc_stats)) s/live_managed)
    (repeat 20 (eval form ^in (env)))
    (let before (live))
    (var T (eval form ^in (env)))
    (var a #(T ^text "a"))
    (var b #(T ^text "a"))
    (repeat 100 (eval form ^in (env)))
    (let retained_ok (&& (== a b) (== ($hash a) ($hash b))
                        (== ($order/compare a b) 0)))
    (set a nil) (set b nil) (set T nil)
    (let after (live))
    ($json/stringify {^retained_ok retained_ok ^before before ^after after})`;
  const retained = jsonResult(host, retainedSource);

  const scopeRetirement = module._gene_test_scope_retirement() === 1;
  // The high-water registry capacity is warmed before checking steady usage.
  const simultaneous = Array.from({length: 128}, () => host.allocateResult('42'));
  const concurrentHandles = module._gene_test_result_handles() === 128 &&
    simultaneous.every(h => host.readResult(h).text === '42');
  simultaneous.forEach(h => host.release(h));
  const program = `(let T (eval (quote ${witnessForm}) ^in (env)))
    (let a #(T ^text "a")) (== a a)`;
  for (let i = 0; i < 20; i++) host.evaluate(program);
  const heapSamples = [module._gene_test_heap_bytes() >>> 0];
  for (const batch of [1, 100, 1000]) {
    for (let i = 0; i < batch; i++) {
      const result = host.evaluate(program);
      if (result.status !== 0 || result.text !== 'true') throw new Error(JSON.stringify(result));
    }
    heapSamples.push(module._gene_test_heap_bytes() >>> 0);
  }
  // Allocation accounting includes Nim-owned scopes, strings, result records
  // and registry backing storage; linear growth cannot hide behind RC counts.
  const heapFlat = heapSamples[0] > 0 && heapSamples.every(n => n === heapSamples[0]);
  const errorIds = ['equality_reentry', 'hash_reentry', 'index_reentry',
    'pending_activation', 'failed_association_unpublished', 'index_cannot_suspend'];
  const errorCases = errorIds.map(id => {
    const fixture = fixtures.cases.find(f => f.id === id);
    if (!fixture) throw new Error(`missing lifetime fixture: ${id}`);
    return fixture;
  });
  function errorBatch(count) {
    for (let i = 0; i < count; i++) {
      const results = runValueCases(host, {cases: errorCases});
      if (results.failures.length) throw new Error(JSON.stringify(results));
    }
  }
  errorBatch(20);
  const errorHeapSamples = [module._gene_test_heap_bytes() >>> 0];
  for (const batch of [1, 100, 1000]) {
    errorBatch(batch);
    errorHeapSamples.push(module._gene_test_heap_bytes() >>> 0);
  }
  const errorHeapFlat = errorHeapSamples.every(n => n === errorHeapSamples[0]);
  const held = host.allocateResult('42');
  const heldValue = host.readResult(held);
  host.release(held);
  host.release(held);
  const stale = host.readResult(held);
  const newer = host.allocateResult('43');
  const distinct = newer !== held;
  host.release(newer);
  const handles = module._gene_test_result_handles();
  return {ok: scopeRetirement && concurrentHandles && generationFlat && retained.retained_ok === true &&
    retained.before === retained.after && heapFlat && errorHeapFlat && heldValue.text === '42' &&
    stale.status === -1 && distinct && handles === 0,
    scopeRetirement, concurrentHandles, generationFlat, snapshots, retained, heapFlat, heapSamples,
    errorIds, errorHeapFlat, errorHeapSamples,
    handles, stale, distinct};
}
