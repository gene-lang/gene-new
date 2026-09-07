# Web numeric representation spike

Status: **P0.5 measurement complete; P2 selects option B (`Int` → `bigint`).**
Benchmark source:
`benchmarks/transpile_numbers.mjs`; fixed payload:
`benchmarks/data/transpile_numbers.json`.

The benchmark models the browser boundary rather than isolated arithmetic. It
parses a 1.3 KB commerce/API payload, adapts schema-known Gene `Int` fields to
`bigint`, computes an order total, and adapts `bigint` back to tagged decimal
objects for JSON. JavaScript's native `JSON.stringify(1n)` throws `TypeError`.

Baseline run on 2026-07-29, Node v25.9.0, Apple host, 20,000 iterations:

| operation | number | bigint profile | ratio |
|---|---:|---:|---:|
| JSON parse / parse+schema adaptation | 2,456 ns | 8,097 ns | 3.30× |
| fixed-payload arithmetic | 55.8 ns | 93.1 ns | 1.67× |
| JSON stringify / stringify+adapter | 764 ns | 7,018 ns | 9.19× |
| compact output bytes | 1,088 | 1,744 | 1.60× |

These are smoke numbers, not thresholds. Re-run with `nimble transpile_perf`
and report before/after values for backend changes. The repository pins CI's
Node line in `.node-version`; this exploratory run used the locally available
v25.9.0 and therefore does not establish cross-version absolute timing.

The result makes option B's boundary tax concrete and it is accepted for the
initial profile because it preserves arbitrary precision and kind identity.
C′ cannot soundly expose the current public `Int` functions as JavaScript
`number`: a JS caller supplies a runtime value whose safe range is not statically
provable. It also rejects the shared numeric fixture, whose exact result exceeds
`Number.MAX_SAFE_INTEGER`, for an admitted-code rate of **0/1 numeric fixtures**.
That is too small to serve the proposed vertical slice.

The ABI therefore requires `bigint` and rejects JS `number`, even when integral.
JSON adaptation remains explicit and outside the pure profile; the measured
3.30× parse/adapt, 9.19× stringify/adapt, and 1.60× payload costs are why no
implicit adapter is emitted. A future separately named safe-number type can
revisit C′ without weakening `Int`.
