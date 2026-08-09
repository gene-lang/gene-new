# Candidate protocol: Gene library induction

Status: bounded DSL, exact interpreter, one-round abstraction algorithm, and
toy mechanism smoke specified and passing on 2026-08-09. The experimental
corpus, iterative stopping rule, and donor-library matching procedure remain
unfrozen, so the treatment evaluation is not implementation-ready. See
[`README.md`](README.md).

Implementation:
[`examples/general_intelligence/src/library_induction.gene`](../../../../examples/general_intelligence/src/library_induction.gene).
Mechanism smoke:
[`examples/general_intelligence/tests/library_induction_smoke.gene`](../../../../examples/general_intelligence/tests/library_induction_smoke.gene).

## Hypothesis and claim boundary

Reusable abstractions induced from solved Gene programs improve search on novel
compositions because their bodies capture transferable structure, not merely
because the library is larger or receives a more favorable search position.

A pass supports only exact composition search in the frozen bounded DSL and
task distribution. It does not establish general program synthesis, semantic
understanding, or transfer to arbitrary Gene programs. Every candidate and
abstraction is exact data interpreted by the experiment; no model-authored form
is passed to `eval`.

## Candidate bounded DSL

Programs have the exact grammar:

```text
program       := (program token*)
token         := primitive | (use ^name abstraction_name)
abstraction   := (abstraction ^name abstraction_name
                               ^body (program primitive+))
```

An abstraction body contains primitives only. Nested and recursive
abstractions are invalid, which makes expanded length a local structural check.
The current value type is `(List Int) -> (List Int)`. Inputs contain at most 32
integers, each with absolute value at most 1,000,000. Outputs contain at most 64
integers, and a program expands to at most eight primitive steps.

The 12 primitives and their total deterministic semantics are:

| Gene token | Result |
|---|---|
| `(tail)` | all elements except the first; empty for length zero or one |
| `(init)` | all elements except the last; empty for length zero or one |
| `(reverse)` | elements in reverse order |
| `(rotate_left)` | move the first element to the end; identity below length two |
| `(rotate_right)` | move the last element to the front; identity below length two |
| `(map_add_one)` | add one to each element |
| `(map_sub_one)` | subtract one from each element |
| `(map_double)` | multiply each element by two |
| `(map_negate)` | negate each element |
| `(keep_even)` | retain elements with remainder zero modulo two |
| `(keep_odd)` | retain elements with nonzero remainder modulo two |
| `(duplicate_each)` | emit every element twice in place |

The experimental type and resource bounds may change only before protocol
freeze. Adding a primitive or changing its semantics creates a new experiment
version.

## Exact solution and search rules

A task is an exact Gene node containing input/expected-output cases. A candidate
solves a task only if the interpreter returns the exact expected list for every
case. During evaluation, public examples may guide search but the verifier owns
additional hidden cases; only the hidden-verifier outcome counts as a solution.

The reference enumerator uses iterative deepening by token count. Within one
depth, it enumerates the Cartesian product in declared token order. Library
tokens come first, followed by primitives in the table order. The fixed and
unrelated-library controls receive the same number of first-position library
tokens, so this prior position is not unique to induced content. The first exact
solution wins. Candidate execution is counted before its cases run, and the
declared maximum is a hard counter rather than a wall-clock inference.

Candidate programs are interpreted by `run_program`; they are not compiled or
evaluated as source. `EvalBudget` therefore does not mediate this DSL. An outer
process timeout and memory measurement cover implementation failures, while the
exact candidate counter covers the comparison budget.

## One-round abstraction algorithm and MDL

The implemented round consumes independently verified solution programs. It
enumerates every contiguous primitive subsequence of length two through four in
solution order, start-position order, and increasing length. Support is the
number of distinct solution programs containing the pattern. Replacement count
is the number of left-to-right non-overlapping occurrences across the corpus. A
pattern must have support from at least four programs.

Primitive and abstraction-use tokens each cost one MDL unit. Defining a
length-`L` abstraction costs `L + 1` units: its body plus one name token. If it
has `N` non-overlapping replacements, its corpus gain is therefore:

```text
gain = N * (L - 1) - (L + 1)
```

The first strict maximum wins; a non-positive maximum produces no abstraction.
Accepted occurrences are replaced left-to-right without overlap. Correctness
and MDL are separate gates: compression cannot make an unverified solution
valid, and a correct repeated fragment is not retained without positive gain.

The full experiment still must freeze whether induction repeats this round to a
fixed point or stops after a fixed library size. It must also freeze naming,
duplicate-body handling across rounds, and the total library-description cap.
The toy smoke deliberately proves only one round and cannot select those rules.

## Mechanism smoke

Four exact solved programs share `(tail) (reverse)` and then apply four distinct
mapping primitives. Their inlined corpus costs 12 units. The extracted
two-primitive abstraction occurs in all four solutions; its definition costs
three units and the four compressed programs cost eight, for an induced corpus
cost of 11 and gain of one.

The transfer task additionally duplicates the incremented result. At token
depth three and a 500-candidate ceiling, primitive-only search cannot express
the required four primitive steps and exhausts the budget. With the induced
token first, exact search finds a verified abstraction-using solution after 274
candidates. The smoke also proves that a corpus without a qualifying repeated
pattern is rejected and that a nine-step program violates the expansion bound.

This is deliberately constructed mechanism evidence. Its programs, tasks, and
abstraction are permanently excluded from training, model selection, donor
matching, and evaluation.

On the 2026-08-09 development machine, the debug-build smoke completed in 0.06
seconds with 12,943,360 bytes maximum resident set size. These are observations,
not experimental ceilings; the candidate mechanism-smoke ceilings are one
second and 64 MiB.

## Experimental subject still to freeze

Before evaluation, specify and independently review:

- deterministic generators for eight independently seeded corpora of list
  transformations, including invalid/trivial-task rejection;
- 100 library-learning tasks, 25 model-selection tasks, and 50 held-out novel
  compositions per corpus;
- the primitive-depth and input-shape distributions, with held-out tasks deep
  enough to require composition but within the eight-step interpreter bound;
- exact public/hidden case counts and a structural ambiguity screen that
  rejects tasks solved by an unintended shorter program;
- the iterative induction stopping rule and library-description cap;
- a tolerance and repair procedure for matching the unrelated-library control
  on token count, arity, description length, search position, empirical prior
  mass, and measured branching; and
- fixed candidate ceilings, process timeouts, memory ceilings, and disjoint
  pilot/model-selection/evaluation seeds.

Nothing generated while selecting these rules may enter an evaluation corpus.

## Candidate arms

Compare at equal candidate-execution, model-token, and wall-time ceilings:

1. fixed base library;
2. proposer with the fixed library;
3. proposer plus induced abstractions; and
4. proposer plus abstractions learned on a disjoint donor distribution and
   matched to arm 3 on library and search-shape properties.

Arm 4 is the candidate primary control. Arms 1 and 2 are contextual baselines,
not alternatives selected after model-selection results are observed. Every arm
uses the same exact verifier and receives the same task observations.

## Candidate evaluation design

The candidate primary metric is paired held-out solve-rate improvement of the
induced library over the matched unrelated library at equal budgets. Use the
eight corpus seeds as uncertainty units and report a two-sided seed-stratified
95% interval. Repeat the same comparison after a bijective renaming of every
surface task and primitive label; the interpreter mapping is renamed with it,
so only names change.

Candidate executions, model tokens, wall time, total description length,
abstraction reuse, wrong-abstraction selection, and verifier rejection are
secondary diagnostics.

Candidate pass rule:

- at least a 15-percentage-point held-out solve-rate advantage;
- a confidence interval for that advantage excluding zero;
- the same positive direction and at least a 10-point advantage on renamed
  surfaces; and
- at least three abstractions each occurring in five or more independently
  verified held-out solutions.

Reject this form of library induction if it has no held-out advantage over the
matched unrelated library, gains vanish under renaming, library growth
increases total description length, reuse does not occur, or exact hidden tests
invalidate claimed solutions.

## Candidate pilots, freeze, and cost

The design implies roughly 7,200 in-domain task-arm runs plus 800 donor runs,
with proposer calls likely dominating. After the remaining subject rules are
fixed, use disjoint seeds for a compute pilot that records candidate executions,
tokens, verifier calls, wall time, and peak resident memory. Pilot tasks and
libraries never enter an experimental arm.

After independent review, hash the protocol, interpreter, generators, hidden
verifier, corpus files, model artifact, and exact arm configuration in a dated
freeze manifest before opening any evaluation result. A content change starts a
new experiment version.

Planning estimate: 4–8 person-weeks after the subject is frozen, with roughly
`2x` uncertainty.
