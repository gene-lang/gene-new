# Candidate protocol: Gene library induction

Status: bounded DSL, exact interpreter, deterministic corpus generator,
structural ambiguity screen, capped iterative abstraction algorithm, and
mechanism pilots specified and passing on 2026-08-09. The evaluation seed
schedule and model-proposer prior-mass matching procedure remain unfrozen, so
the treatment evaluation is not implementation-ready. See
[`README.md`](README.md).

Implementation:
[`examples/general_intelligence/src/library_induction.gene`](../../../../examples/general_intelligence/src/library_induction.gene).
Mechanism smoke:
[`examples/general_intelligence/tests/library_induction_smoke.gene`](../../../../examples/general_intelligence/tests/library_induction_smoke.gene).
Corpus smoke and full-size pilot:
[`library_induction_corpus_smoke.gene`](../../../../examples/general_intelligence/tests/library_induction_corpus_smoke.gene)
and
[`library_induction_corpus_pilot.gene`](../../../../examples/general_intelligence/tests/library_induction_corpus_pilot.gene).
Unrelated-control pilot:
[`library_induction_control_pilot.gene`](../../../../examples/general_intelligence/tests/library_induction_control_pilot.gene).

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

`induce_library_iterative` repeats that selection against the currently
compressed corpus. Candidate bodies are always enumerated from the original
primitive-only solutions, while marginal occurrences are counted only where
the primitive sequence remains uncompressed. Consequently definitions remain
flat and cannot capture across an existing abstraction token. Already selected
bodies are skipped. Each accepted round must have strictly positive marginal
gain and strictly lower total corpus MDL.

Names are the exact strings `induced_0` through `induced_3` in acceptance
order. Induction stops at the first round with no positive marginal candidate
or after four definitions. The four definitions may cost at most 20 MDL units
in total. `verify_iterative_induction` expands every compressed program through
the resulting library and checks exact equality with its original primitive
program, monotone MDL improvement, unique bodies, and both caps. The toy smoke
reaches the no-positive-gain stop after one definition; the full corpus pilot
reaches the four-item cap.

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

## Candidate deterministic corpus generator

`generate_corpus` uses the Park-Miller recurrence
`state = (48271 * state) mod 2147483647`; valid seeds are the integers 1 through
2,147,483,646. A corpus has exactly 100 library-learning tasks, 25
model-selection tasks, and 50 held-out tasks. Every target is a four-primitive
program. Four out of each five task positions contain one of four seeded,
two-primitive latent motifs; motif identity and its position zero through two
rotate arithmetically, while the remaining primitive positions are sampled.
Every fifth task is an independently sampled background composition. Exact
target semantics must be unique across all three partitions.

A two-primitive motif is eligible only if it is itself structurally depth two
and has at least 24 distinct depth-four semantic extensions at each of the
three possible motif positions. The capacity check enumerates all 144 ordered
pairs of filler primitives per position and applies the same shorter-program
screen. This excludes absorbing motifs that are minimal in isolation but make
one required target slot impossible to generate.

The generator rejects a target unless it differs from every program of depth
zero through three on this fixed 16-input structural bank:

```text
[] [0] [1] [-1]
[0 1] [1 0] [-1 2] [2 -1]
[0 1 2] [2 1 0] [-2 0 2] [1 -1 1]
[2 2 -1] [-3 1 0] [1 2 -3 0] [0 -1 2 -3]
```

The screen enumerates exactly `1 + 12 + 12^2 + 12^3 = 1,885` shorter
programs. Each accepted task exposes four seeded public cases. Its
verifier-owned record contains all 16 structural cases plus eight additional
seeded cases, for exactly 24 hidden cases. Seeded case inputs contain one to
four integers sampled uniformly from `-5..5`. Including the complete screen
bank means no shorter program can pass the hidden cases; this is a finite
structural guarantee, not a claim of semantic equivalence over every input
allowed by the interpreter.

Target programs and hidden cases reside under the verifier record and must not
cross the future arm-facing interface. Library-learning programs become arm
inputs only after independent exact verification marks them solved.
`verify_generated_corpus` reconstructs the shorter-program index and checks
partition counts, exact public and hidden case counts, target execution,
minimum depth, semantic uniqueness, motif placement, and all three declared
motif extension capacities.

Pilot seed `900101` produced all 175 tasks, of which 140 were motif-bearing.
Generation rejected 244 shorter-equivalent candidates and 73 semantic
duplicates. One-round induction recovered the latent motif
`(map_double) (map_negate)` with support and occurrence count 21 and MDL gain
18. Iterative induction recovered all four latent motifs, used 12 definition
units, and reduced corpus MDL from 400 to 331 for a gain of 69. The successive
round gains were 18, 17, 17, and 17, after which the four-item cap stopped
induction. This pilot corpus and its seed are permanently excluded from model
selection and evaluation.

On the 2026-08-09 development machine, generation, independent validation, and
four-round induction completed in 12.31 seconds with 17,694,720 bytes maximum
resident set size. These are observations, not treatment ceilings. The
candidate full-corpus generation-and-induction ceiling is 20 seconds and 64
MiB; final ceilings still require an independently reviewed compute pilot on
the frozen implementation.

## Candidate unrelated-library matcher

`library_search_shape` records library item count, the abstraction-body length
at every search position, total definition MDL, total token count, the exact
first and past library-token positions, search depth, untruncated candidate
space, enforced candidate ceiling, and input/output arity. With four two-step
abstractions, both libraries have four items, body lengths `[2 2 2 2]`, 12
definition units, 16 total tokens, candidate space 4,369 through depth three,
and the 500-candidate execution ceiling.

`build_unrelated_library_control` accepts at most eight predeclared donor seeds
and never examines model-selection or held-out tasks. In seed order, it rejects
the target seed, generates and independently validates 100 donor-learning
tasks, performs the same capped induction, and accepts the first library whose
search shape matches exactly and whose primitive bodies are all disjoint from
the target library. It records every rejected seed and reason. Equal shape
makes branching, uniform enumerator mass, type arity, and library-token search
positions exact rather than tolerance-based.

The disjoint pilot targeted seed `900101`. Donor seed `900201` was rejected for
one overlapping body; seed `900202` was accepted on the second attempt with an
exact shape match and no shared body. The pilot completed in 32.49 seconds with
18,219,008 bytes maximum resident set size. Both donor seeds and every artifact
generated from them are permanently excluded from evaluation. The candidate
three-seed matching ceiling is 60 seconds and 64 MiB; a frozen experiment must
either retain that list size or justify and re-pilot a different ceiling.

This exact match covers the implemented enumerator. A future learned proposer
can assign different probability to equal-shaped tokens, so its empirical
prior-mass tolerance and repair rule remain a separate freeze requirement.

## Experimental subject still to freeze

Before evaluation, specify and independently review:

- the eight evaluation seeds, disjoint donor seeds, and disjoint
  model-selection seed domain, selected without opening any generated result;
- independent review of the candidate motif mixture, four-step target depth,
  input distribution, and 16-case finite ambiguity screen;
- independent review of the candidate four-item, 20-description-unit greedy
  induction cap;
- a tolerance and repair procedure for matching empirical token prior mass
  under the selected learned proposer; the exact enumerator shape is already
  matched mechanically;
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
