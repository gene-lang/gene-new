# Protocol and message experiment (Document Lens)

Executes `tmp/protocol-message-exp.md`: a bounded, deterministic CLI application
(no network, model, database or browser) that exercises Gene's protocols, held
messages and scoped implementations, with the matched function baseline, the
boundary fixtures, a capped Cordis contrast and the H6 timing harness. Results
and verdicts are in [reports/findings.md](reports/findings.md).

Native VM only. Run everything from the repository root with a release `bin/gene`
(`gene --version` must say `release`).

## Layout

| Path | Purpose |
| --- | --- |
| `src/model.gene`, `contracts.gene` | Frozen core: Section, Article, Figure; `Render [each]` contract. |
| `src/policies/` | Third-party scoped `Render` impls: `plain` and `compact`. |
| `src/extensions/` | Late types (Chart, Table), their per-policy pairs, the late canonical `Outline` operation, the scoped `Weight` operation. |
| `src/roots/` | Composition roots. Pair imports live here, never in consumers. `*_late` roots are the late-extension diff. |
| `src/consumers/` | Generic preview, export and outline-report consumers: no protocol, type or impl imports. |
| `src/baseline/` | Variant F: explicit dispatcher with per-type entries. |
| `src/variants/` | P-closure, P-typed and N (named canonical policy protocols). |
| `tests/boundaries/` | B1-B4 and placement fixtures; `run.gene` runs each in a fresh process against `expected.txt`. |
| `tests/integration/` | Matched outputs for P / P-closure / P-typed / F / N. |
| `bench/h6/` | The frozen 1,000-node H6 fixture and the five timed variants. |
| `bench/matrix/` | Dispatch matrix (transport x layout x monomorphic/alternating/uncached). |
| `ports/cordis/` | One C control and one minimal P attempt (isolated copies of Cordis). |
| `tools/` | `freeze.gene` (hash the frozen core), `count.gene` (composition counts). |
| `reports/` | `findings.md` and `evidence/` (before/after outputs, raw measurements). |

## Commands

```sh
bin/gene test examples/protocol-message-exp/tests            # integration + boundaries + freeze
bin/gene run examples/protocol-message-exp/tests/boundaries/run.gene [ID]
bin/gene run --package-root examples/protocol-message-exp examples/protocol-message-exp/src/main.gene
bin/gene run examples/protocol-message-exp/tools/freeze.gene check
bin/gene run examples/protocol-message-exp/tools/count.gene OUT.json

# H6 (fresh worker per sample, rotating order; GENE_BENCH_SAMPLES >= 5)
GENE_BENCH_SAMPLES=7 bin/gene run --package-root examples/protocol-message-exp \
  examples/protocol-message-exp/bench/run_h6.gene OUT_DIR 200 bin/gene [OTHER_GENE ...]
GENE_BENCH_SAMPLES=7 bin/gene run --package-root examples/protocol-message-exp \
  examples/protocol-message-exp/bench/run_matrix.gene OUT_DIR 200000 bin/gene
```

Run timings only on an idle machine (load average below 5; macOS contacts and
calendar daemons can drive it to 100+ and invalidate a batch).

`bench/matrix/entry_worker.gene` is generated: after editing `rows.gene`, run
`bin/gene run examples/protocol-message-exp/bench/matrix/generate_entry.gene`.

## Changes outside this package

The experiment produced runtime changes, each with regressions:

- `import_impl` placement follows `import` (owner decision 2026-11-05, replacing
  the 2026-11-01 module-level-only rule; findings section 13): it is accepted
  wherever `import` is, and the pair is visible where an `import` at the same
  position binds its names. At module level it joins the module; in a `fn`,
  lambda, `message`, `ctor`, `spawn` or loop body, or a macro-marked block, it
  belongs to that activation and the closures created there. Impls never shadow.
- Conflict diagnostics name both origins; hidden-impl advice ignores `import_impl`
  copies and spells its suggested path relative to the checking module.
- A relative `import` path that executes after module initialization (inside a
  function) resolves against the module that wrote it.
- `benchmarks/bench_core.nim` gains held, view, dynamic and closure rows.
