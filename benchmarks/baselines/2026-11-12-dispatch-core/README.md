# Dispatch core, 2026-11-12

Evidence for [the dispatch-core proposal](../../../docs/proposals/vm-dispatch-core.md).
All binaries are release builds on an Apple M4 Pro. `pairs/` files come from
`../2026-11-12-panics/pairs/pairn.sh` (round, label, kernel, milliseconds; every
binary once per round in a rotating order) over `benchmarks/kernels/kernels.gene`
and `scripts/callcost.gene`, 7 rounds each, and are summarized with
`../2026-11-12-panics/pairs/summn.py FILE BASE LABEL...`.

Builds, by label:

| Label | Source | Build |
| --- | --- | --- |
| `H` | `b25adf33` | default (`nim c src/gene.nim`) |
| `D` | `b25adf33` with the return paths shared, as committed in `908bb4e0` | default |
| `N` | `b25adf33` | `-d:release --opt:speed --passC:"-march=native -O3"`, no profile |
| `HP` | `b25adf33` | `scripts/pgo-build.sh`, the `nimble speedy_pgo` recipe |
| `DP` | `908bb4e0` | PGO |
| `D2P` | `908bb4e0` plus every call entry shared | PGO |
| `D3P` | `908bb4e0` plus call entry shared except a plain non-tail call | PGO |
| `D4P` | `908bb4e0` plus the call-budget guard, with the policy flag still set at the two production install points; `113c9fa9` moved it behind the field's setter, which changes no code path in a call | PGO |
| `R2P` | `43d52531` | PGO |
| `D1Q`, `R2Q1`, `R2Q2` | `908bb4e0`, `43d52531`, `43d52531` | PGO with `scripts/train-quick.sh` |

The PGO builds above the last row train with `tools/pgo/train.sh` from their
own tree after `dd124778` (the two training programs fixed); the Harness specs
in the training pass 401 or 402 of 412 each time. Those counts depend on timing
and dominate the profile, so these builds vary by up to 3% between trainings.
The quick-trained builds leave the specs out and repeat to within 0.003%.

- `pairs/default-returns.tsv`: `H`, `D`.
- `pairs/pgo-returns.tsv`: `N`, `H`, `HP`, `DP`.
- `pairs/pgo-shared-calls.tsv`: `HP`, `DP`, `D2P`.
- `pairs/pgo-hybrid-calls.tsv`: `DP`, `D3P`, `HP`.
- `pairs/pgo-call-budget.tsv`: `DP`, `D4P`.
- `pairs/quick-call-budget.tsv`: `D1Q`, `R2Q` (`R2Q1`).
- `kernels-pgo/`, `kernels-quick/`: `benchmarks/run_kernels.gene` with `R2P`
  and `R2Q1` as `gene`, CPython 3.14.3 as `python` and `H` as `baseline`.
- `instructions.txt`: instructions retired (`/usr/bin/time -l`) for
  `scripts/while-long.gene` (20 M iterations of the `while` kernel) and
  `scripts/scoped-calls.gene` (5 M calls of a function with a local). Counts
  repeat to within 0.1% between runs, so they separate a change in the code
  from a change in the machine's load.

`scripts/`: `pgo-build.sh`; `cfunc.py` and `ccases.py`, which size `runLoop`'s
body and each dispatch case in the generated C; `findtab.py`, `jtab.py` and
`jtab32.py`, which locate the dispatch jump table in a disassembly and map each
opcode to its handler's address.
