# Second round, 2026-11-12

Evidence for sections 10 to 13 of [the report](../../../docs/reports/boundary-costs.md).
All binaries are release builds on an Apple M4 Pro.

- `kernels/`: `benchmarks/run_kernels.gene` at `c324a6f5`, with the branch as
  the first round left it (`e7f2cc31`) as the baseline and CPython 3.14.3,
  five rounds after one warmup.
- `general/`: `benchmarks/run_general.gene` at 5,000 items, same binaries.
- `pairs/`: paired rounds of `benchmarks/kernels/kernels.gene` from
  `pairn.sh`, which runs every binary once per round in a rotating order.
  Columns are round, label, kernel and milliseconds. `summn.py FILE BASE
  LABEL...` prints the medians and the median per-round ratio against the
  first label, with the rounds each label won.
  - `panics.tsv`: `A` is the source of `e7f2cc31` as built by `config.nims`
    then, `B` the same source with `--panics:on` (section 10). Five rounds.
  - `second-round.tsv`: `P` is `46b80b9d` (panics on), `H` is `4d61de2d`
    (section 11), `B1` adds the store change of `1196a794`, `B2` adds the
    inline store that was not kept, and `B3` adds the field-write change of
    `c324a6f5` on top of `B2`. Seven rounds.
  - `stores-and-writes.tsv`: `H` and `B1` as above, and `C`, which is
    `c324a6f5`. Seven rounds.
- `profiles/`: `sample` call graphs, 3 s each, of the programs beside them,
  and `incl.py`, which prints each symbol's inclusive share once per stack.
  `accessor` and `listparam` are on `46b80b9d`; `fieldw`, `repeat2` and
  `fib` on `4d61de2d`; `closure` and `send` on `B3`.
