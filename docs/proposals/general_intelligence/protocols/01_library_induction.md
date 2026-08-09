# Draft protocol: Gene library induction

Status: not frozen and not implementation-ready. See [`README.md`](README.md).

## Subject still to specify

- the 12 primitives, type rules, and hidden target-composition depth
  distribution;
- enumeration/proposal strategy and the recurring-subtree abstraction
  algorithm;
- exact MDL formula and its relationship to correctness;
- numeric candidate-execution budget, enforced through Gene's `EvalBudget`;
- a tolerance and repair procedure for matching the unrelated-library control
  on primitive count, arity, description length, prior mass, and measured search
  branching.

## Candidate mechanism and arms

Use a bounded Gene DSL. Candidate programs are proposed or enumerated, then
accepted only by exact execution and hidden tests. Solved programs feed a
recurring-subtree abstraction step; accepted abstractions become named Gene
functions with provenance and regression tests.

Candidate design: eight independently seeded corpora of deterministic list/tree
transformations composed from 12 primitives. Each corpus has 100
library-learning tasks, 25 model-selection tasks, and 50 held-out novel
compositions. Evaluate renamed-surface copies to detect memorized-name
shortcuts.

Compare at equal candidate-execution budget:

1. fixed base library;
2. proposer with the fixed library;
3. proposer plus induced abstractions;
4. proposer plus abstractions learned on a disjoint donor distribution and
   matched to arm 3 on library and search-shape properties.

Arm 4 is the candidate primary control. Arms 1 and 2 are contextual baselines,
not alternatives selected after model-selection results are observed.

## Candidate evaluation design

The candidate primary metric is paired held-out solve-rate improvement of the
induced library over the matched unrelated library at equal execution budget.
Use a seed-stratified confidence interval. Repeat the same comparison on renamed
surfaces as a robustness gate. Candidate executions, wall time, description
length, and abstraction reuse are secondary diagnostics.

Candidate pass rule: at least a 15-percentage-point held-out advantage, an
interval excluding zero, and survival of the renamed-surface test. As a
mechanism check, at least three abstractions should each occur in five or more
independently verified held-out solutions.

Reject this form of library induction if it has no held-out advantage over the
matched unrelated library, gains vanish under renaming, abstraction growth
increases total description length, reuse does not occur, or exact hidden tests
invalidate claimed solutions.

## Candidate pilots and cost

The current design implies roughly 7,200 in-domain task-arm runs plus 800 donor
runs, with proposer calls likely dominating. A disjoint compute pilot should
measure candidate executions, tokens, wall time, and projected full cost.

Before that, a toy mechanism smoke should check that the actual abstraction
algorithm extracts a non-trivial repeated subprogram, reuses it in later exact
solutions, and improves MDL relative to inlining. Nothing from either pilot may
enter an experimental library or corpus.

Planning estimate: 4–8 person-weeks after the subject is frozen, with roughly
`2x` uncertainty.
