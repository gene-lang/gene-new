# Agent Operating Notes

Performance is a core requirement for this repository. Treat value layout,
reader hot paths, allocation behavior, and future VM stack/dispatch code as
performance-sensitive by default.

Before every commit, run:

```bash
nimble test
nimble spec
nimble perf
nimble wasm
```

If benchmark output gets worse, do not hide it. Include the before/after
numbers and the reason the regression is acceptable or unavoidable in the
commit message. If the regression is avoidable, fix it before committing.

`nimble wasm` requires the Emscripten SDK (`emcc`) on PATH. If it cannot be run,
state that explicitly before committing.

For broad or risky changes, run the combined command:

```bash
nimble verify
```

`nimble spec` is the executable language-surface contract. It should track
`docs/design.md` and `examples/web_demo.gene`.

`nimble perf` is the baseline performance smoke check. It does not enforce
thresholds yet; compare before/after output and explain regressions. Do not
merge changes that add avoidable allocation, global contention, or extra passes
through source text without benchmark evidence.

Keep dependencies minimal. Do not add new runtime or benchmark dependencies
unless explicitly requested.

When touching the NaN-boxed value layer:

- Keep `sizeof(Value) == sizeof(uint64)`.
- Preserve zero-initialized `Value` as `nil`.
- Keep hot scalar paths allocation-free where possible.
- Do not add heap reads on critical paths without considering the planned
  non-moving arena / reclamation work in `src/gene/types.nim`.

When touching parser/reader code:

- Preserve multi-form source-unit parsing through `readAll`.
- Keep datum comments as spacing.
- Keep selector literals distinct from context-neutral slash paths.
- Add examples to `tests/spec_runner.nim` when behavior comes from the design
  doc or `examples/web_demo.gene`.
