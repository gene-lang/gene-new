# Candidate protocol: Gene library induction

Status: bounded DSL, exact interpreter, deterministic corpus generator,
structural ambiguity screen, capped iterative abstraction algorithm, and
mechanism and exact-enumerator evaluation pilots specified and passing on
2026-08-09. The eight-corpus seed schedule, canonical setup exporter, frozen
consumer, resource-metered runner, analysis, and mutation-rejecting freeze
workflow are now candidate-complete and pass their excluded-pilot self-tests.
Independent protocol review and its content-hash attestation remain external
and incomplete, so the treatment evaluation is not authorized. See
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
Public-search/hidden-verifier pilot:
[`library_induction_evaluation_pilot.gene`](../../../../examples/general_intelligence/tests/library_induction_evaluation_pilot.gene).
Review/freeze tool:
[`tools/prepare_library_induction_freeze.py`](../../../../tools/prepare_library_induction_freeze.py).
Post-freeze runner and preregistered analysis:
[`tools/run_library_induction_evaluation.py`](../../../../tools/run_library_induction_evaluation.py).

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
depth, it enumerates the Cartesian product in declared token order. It computes
each program directly from its ordinal instead of allocating the full Cartesian
product. Library tokens come first, followed by primitives in the table order.
The induced and unrelated-library controls receive the same four first-position
library tokens. The candidate ceiling is 4,369, exactly
`1 + 16 + 16^2 + 16^3`, so both matched libraries exhaust every program through
depth three instead of receiving a rank-dependent prefix. The primitive-only
contextual arm has only `1 + 12 + 12^2 + 12^3 = 1,885` candidates and exhausts
that complete space under the same ceiling.

Candidate execution is counted before its public cases run. A public-case match
causes one verifier call against all 24 hidden cases. Hidden failure increments
the verifier-rejection count and search continues; hidden data never enters the
enumerator. The first hidden-verified solution wins. A candidate that violates
the expansion or output bound is an invalid candidate, not a process-aborting
error.

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

The transfer task additionally duplicates the incremented result. Complete
primitive-only search through token depth three cannot express the required
four primitive steps and exhausts all 1,885 programs. With the induced token
first, exact search finds a verified abstraction-using solution after 274
candidates. The smoke also proves that a corpus without a qualifying repeated
pattern is rejected, a nine-step program violates the expansion bound, and an
otherwise valid candidate whose output grows beyond 64 items is rejected
without aborting search.

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
and the 4,369-candidate execution ceiling.

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
exact shape match and no shared body. Under the complete-depth search
configuration, the pilot completed in 35.62 seconds with 18,677,760 bytes
maximum resident set size. Both donor seeds and every artifact generated from
them are permanently excluded from evaluation. The candidate three-seed
matching ceiling is 60 seconds and 64 MiB; a frozen experiment must either
retain that list size or justify and re-pilot a different ceiling.

## Exact-enumerator evaluation pilot

`search_corpus_task` exposes only a task's four public cases to search. Every
public match crosses the internal verifier boundary; only a match on all 24
hidden cases is accepted. `evaluate_exact_enumerator` runs the primitive-only,
induced-library, and matched-unrelated-library arms on the same held-out tasks
and records candidate executions, verifier calls and rejections, exhausted
tasks, exact programs, and abstraction-using solutions.

Pilot corpus seed `900301` and donor seed `900401` are permanently excluded from
model selection and evaluation. At the earlier partial 500-candidate ceiling,
the primitive-only, induced, and unrelated arms solved 0, 6, and 0 of 50 tasks;
the 12-point induced advantage was confounded by admitting only 227 of 4,096
depth-three library programs. That result is retained as failed design evidence.

The structurally derived 4,369 ceiling then exhausted depth three. The three
arms solved 0, 44, and 12 tasks respectively, for a 64-point pilot advantage of
induced over unrelated content. All 44 induced solutions and all 12 unrelated
solutions used their respective libraries. The primitive-only, induced, and
unrelated arms made 226, 420, and 884 hidden-verifier rejections respectively,
demonstrating that public matches were not treated as success. Total candidate
executions were 94,250, 98,408, and 185,634. Generation, matching, induction,
and evaluation completed in 56.53 seconds with 19,349,504 bytes maximum
resident set size. The candidate per-corpus setup-and-evaluation ceiling is 75
seconds and 64 MiB.

These are pilot outcomes, not a treatment result, and they do not contribute to
the pass rule or interval. The ceiling changed for a structural reason—the
cardinality of the declared search space—not to optimize the observed effect.

## Candidate seed schedule and remaining review gate

The schedule below was chosen arithmetically without generating any of its
corpora. Every seed is disjoint from the mechanism and compute pilots. A target
has exactly three donor attempts in the displayed order; inability to obtain an
exact shape/content match aborts the freeze rather than substituting a seed.

| Corpus | Target seed | Donor seeds, in order |
|---:|---:|---|
| 0 | 31000019 | 41000021, 41000118, 41000214 |
| 1 | 31010026 | 41010030, 41010127, 41010223 |
| 2 | 31020033 | 41020039, 41020136, 41020232 |
| 3 | 31030040 | 41030048, 41030145, 41030241 |
| 4 | 31040047 | 41040057, 41040154, 41040250 |
| 5 | 31050054 | 41050066, 41050163, 41050259 |
| 6 | 31060061 | 41060075, 41060172, 41060268 |
| 7 | 31070068 | 41070084, 41070181, 41070277 |

Before evaluation, an independent reviewer must approve:

- this unopened eight-target and 24-donor schedule, including the rule that a
  failed three-donor match aborts candidate version 1;
- the candidate motif mixture, four-step target depth, input distribution, and
  16-case finite ambiguity screen;
- the candidate four-item, 20-description-unit greedy induction cap;
- the complete-depth candidate ceiling, process timeout, and memory ceiling;
  and
- the exact Student interval and per-corpus reuse gate below.

Nothing generated while selecting these rules may enter an evaluation corpus.
The reviewer supplies only approval plus free-form notes. The tooling binds
that decision to the candidate digest and records the Git reviewer identity and
UTC timestamp. Approval means the reviewer attests independent review,
unopened evaluation output, and result-free seed selection; separate checkbox
fields for those conditions are not required. A changed byte invalidates that
attestation.

## Candidate arms

The primary reproducible comparison uses the exact enumerator at equal
candidate and wall-time ceilings:

1. primitive-only enumeration as a contextual reach baseline;
2. enumeration with the induced library; and
3. enumeration with abstractions learned on a disjoint donor distribution and
   matched exactly to arm 2 on library and search-shape properties.

Arm 3 is the primary control. Every arm uses the same hidden verifier and
receives the same public observations. Model-token use is zero. A learned
proposer may be studied later as a separately frozen secondary experiment, but
its token prior and stochastic sampling cannot affect this experiment's pass
decision.

## Candidate evaluation design

The candidate primary metric is paired held-out solve-rate improvement of the
induced library over the matched unrelated library at equal budgets. Use the
eight corpus seeds as uncertainty units and report a two-sided seed-stratified
95% Student interval over the eight paired seed-level solve-rate differences
(`df = 7`, two-sided critical value `2.364624251`). The exact enumerator
consumes the declared token list by ordinal and dispatches primitive semantics
by closed node pattern; task identifiers and abstraction names do not affect
candidate order, execution, or scoring. This makes a surface-label renaming
repeat redundant for the primary experiment. A future learned-proposer
secondary experiment must preregister the bijective renaming control because
its token prior can observe those labels.

Candidate executions, wall time, total description length, abstraction reuse,
wrong-abstraction selection, and verifier rejection are secondary diagnostics.
Model-token use is identically zero.

Candidate pass rule:

- at least a 15-percentage-point held-out solve-rate advantage;
- a confidence interval for that advantage excluding zero;
- in every corpus, at least three of its four induced abstractions each occur
  in five or more independently verified held-out solutions.

Reject this form of library induction if it has no held-out advantage over the
matched unrelated library, library growth increases total description length,
reuse does not occur, or exact hidden tests invalidate claimed solutions.

## Candidate pilots, freeze, and cost

The design implies 1,200 primary held-out task-arm runs across eight corpora,
plus at least 800 donor-learning tasks (and more only when an earlier
predeclared donor fails the exact matching rule). There are no model calls. The
frozen run records candidate executions, verifier calls and rejections, wall
time, and peak resident memory. Pilot tasks and libraries never enter an
experimental arm.

After independent review, hash the protocol, interpreter, generators, hidden
verifier, setup exporter, frozen consumer, runner, runtime binary, seed
schedule, and exact arm configuration in a dated freeze manifest before opening
any evaluation result. `prepare_library_induction_freeze.py packet` writes the
review candidate outside the worktree. `attest` accepts only `--approve` and
`--notes` as reviewer decisions, checks the reviewed packet against the current
candidate, and automatically writes the digest-bound schema-2 record outside
the worktree. `freeze` refuses a dirty revision, an in-tree attestation or
output, an invalid or stale attestation, a setup over 60 seconds or 64 MiB, an
unmatched donor, and any setup payload containing an arm result. It records
hashes and observed resources for all eight canonical setup files while
executing zero held-out searches. `verify` rechecks current source, the
attestation, manifest, schedule, setup shapes, sizes, and hashes.

Only after that freeze may `run_library_induction_evaluation.py run` evaluate
the eight manifest-selected files. It enforces 75 seconds and 64 MiB per
corpus, retains the complete canonical task results and a JSON projection,
hashes them in a result manifest, and computes the fixed paired analysis. Its
output directory must also be outside the worktree and previously absent. A
content change starts a new experiment version.

The freeze self-test uses excluded target seed `900301` and donor candidates
`900401..900403`. It reproduces the 44-versus-12 pilot result through the frozen
consumer and proves that a one-byte setup mutation is rejected. It does not
generate or open any seed in the table above. The analysis self-test uses only
synthetic counts.

Planning estimate: 1–3 person-weeks after the subject is frozen, with roughly
`2x` uncertainty.
