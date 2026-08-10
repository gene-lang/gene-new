# Draft protocol: verified lifelong skill agent

Status: the local-model qualification gate and an excluded verifier-service
boundary pilot passed on 2026-08-09. The first lifelong-task subject failed its
preregistered difficulty gate after its one allowed revision and is retained as
negative evidence only. A version-2 demonstration-defined subject then failed
at the opposite boundary: the model exhausted its generation budget without
calling a tool on either preregistered arity. A version-3 component-wise interaction then
failed the same way at a preregistered liveness gate, both at the frozen 1,024
generated tokens and at the one declared 2,048-token repair, so it too is
rejected. All three versions are retained as negative evidence. The treatment
comparison remains not implementation-ready, and the binding obstacle is now
the qualified model's per-round generation envelope rather than the subject
design. See [`README.md`](README.md).

## Rejected exact-list subject pilot

The first exact subject is retained in
[`lifelong_task_subject.gene`](../../../../examples/general_intelligence/src/lifelong_task_subject.gene).
It is permanently excluded and must not be used as the experiment-4 treatment
subject. It is a controlled tool-workflow domain, not a claim to cover
open-ended coding.
Authoritative inputs, outputs, programs, traces, replay suites, and evidence are
Gene data. Programs use the same closed 12-operation integer-list interpreter
as experiment 1 (`tail`, `init`, three reorderings, four numeric maps, two
filters, and `duplicate_each`), but no experiment-1 task, motif, seed, learned
library, or outcome is reused.

The model-facing tools for this subject are fixed to three operations:

- `apply_operation(operation, input)` applies one declared primitive and emits
  an exact primitive trace token;
- `invoke_skill(skill_id, input)` runs one independently promoted skill and
  emits a trace token linked to its authenticated receipt; and
- `submit_result(task_id, value, trace)` asks the hidden verifier to accept the
  episode.

The verifier expands every skill trace to primitives and requires byte-exact
agreement with the task's target operation sequence as well as structural
equality of the output. Thus computing or guessing the list in model text is
not success, and an irrelevant skill cannot receive credit merely because the
answer happens to match. All arms see the natural-language operation sequence
and input, so the plain arm can solve every task in principle.

For each subject seed, bounded rejection sampling constructs 30 distinct
three-operation families. A family is accepted only when its behavior on the
fixed 16-input structural bank has no equivalent program of length zero through
two and duplicates no earlier family signature. The completed catalog must use
all 12 primitives. This is finite-bank screen minimality, not a proof of
semantic minimality over every integer list.

Each family has:

- five sequential training variants with fresh effective inputs;
- one verifier-owned replay suite containing the 16 structural cases and eight
  seeded private cases; and
- one fresh retention probe after every five-family block from its introduction
  through the end of the curriculum.

That produces 150 training tasks, 720 replay cases, and 105 retention probes
per seed. The initial pilot used 60 held-out tasks that each composed two
different family programs in an ordered six-operation workflow. The one allowed
difficulty revision composed six different families into an 18-operation
workflow. Tuple order is unique within a seed, and rejection sampling requires
every component program to change the selected example and the final output to
be nonempty. Required family identities, target programs, intermediate values,
expected outputs, and replay cases are verifier data; public goals contain only
the operation descriptions and input.

The generator is deterministic Park-Miller arithmetic with explicit attempt
bounds. All three pilot pairs are permanently excluded: `900501`/`900502` for
the failed adapter run, `900503`/`900504` for the six-operation run, and
`900505`/`900506` for the revised 18-operation run and checked-in smoke. The
following eight pairs were selected arithmetically but never generated. They
are retired with subject version 1 and may not be reassigned to a replacement
subject:

| Pair | Catalog seed | Order/case seed |
|---:|---:|---:|
| 1 | 33000031 | 34000037 |
| 2 | 33100034 | 34100056 |
| 3 | 33200037 | 34200075 |
| 4 | 33300040 | 34300094 |
| 5 | 33400043 | 34400113 |
| 6 | 33500046 | 34500132 |
| 7 | 33600049 | 34600151 |
| 8 | 33700052 | 34700170 |

Do not generate those pairs. A replacement subject requires a new version, new
excluded pilot seeds, and a new unopened schedule selected before its external
review. Any rejected catalog attempt and every final random state remain part
of the version-1 setup artifact.

Skill compatibility is contribution-based, resolving the earlier ontology
ambiguity. A promoted family skill is compatible exactly when its canonical
three-operation program occupies one declared component of the hidden target;
successful use additionally requires that its receipt-bound invocation appear
in the exact expanded trace. Necessity and substitutability remain diagnostics,
not retrieval gates. The initial public ontology is the exact input/output kind
plus `shrink_sequence`, `reorder_sequence`, `numeric_map`,
`predicate_filter`, and `expand_sequence`; these tags may retrieve candidates
but never alter skill semantics or verifier labels.

The complete tool-loop pilot fixed success in the closed interval
`0.25..0.75` as the admissible frontier band. The first run on
`900501`/`900502` failed at the adapter layer: the operation descriptions did
not expose the registered enum tokens, only 9 of 148 calls were schema
conformant, and no task passed. This was not treated as a difficulty result.
Its immutable report is
[`gpt-oss-20b-lifelong-task-difficulty-pilot-2026-08-09.json`](../qualifications/gpt-oss-20b-lifelong-task-difficulty-pilot-2026-08-09.json).

The repaired public wording included each registered operation token while
preserving the same closed semantics. On new excluded seeds `900503`/`900504`,
the model passed 20 of 20 six-operation tasks, with 140 of 140 conformant calls,
so the subject was above the frontier. The report is
[`gpt-oss-20b-lifelong-task-difficulty-pilot-v2-2026-08-09.json`](../qualifications/gpt-oss-20b-lifelong-task-difficulty-pilot-v2-2026-08-09.json).

The single allowed revision increased compositions from two to six families
and the round ceiling from 8 to 20, enough for 18 operations and submission.
On `900505`/`900506`, the model passed 16 of 20 tasks (`0.80`), just outside the
maximum. It emitted 323 schema-conformant calls out of 324, generated 17,536
tokens, and took 540.05 seconds including 63.91 seconds of deterministic subject
export. The immutable report is
[`gpt-oss-20b-lifelong-task-difficulty-pilot-v3-2026-08-09.json`](../qualifications/gpt-oss-20b-lifelong-task-difficulty-pilot-v3-2026-08-09.json).

Version 1 therefore fails its declared subject-validity gate. More importantly,
the public goal reveals the exact primitive tokens, so increasing arity mostly
tests whether the model continues copying a trace; it does not create a strong
reason to retrieve or learn an executable skill. A replacement must make the
latent transformation inferable from public demonstrations or outcomes without
listing its primitive expansion, preserve an exact hidden verifier, and run a
new disjoint difficulty pilot under a newly reviewed protocol. No result from
these pilots may tune the replacement's treatment comparison.

## Rejected version-2 latent-workflow subject

The second subject is retained in
[`latent_workflow_subject.gene`](../../../../examples/general_intelligence/src/latent_workflow_subject.gene).
It is permanently excluded and must not be used unchanged for treatment.
It keeps the closed 12-operation integer-list interpreter but changes the
learning problem. Public tasks never list a target primitive expansion. Each
workflow is instead identified by three input/output demonstrations, and the
agent must infer and execute the latent transformation on a query input.

The finite hypothesis space contains all 1,885 programs of length zero through
three. Their behavior on the 16-input structural bank collapses to 557 distinct
signatures. A family must have minimum finite-bank depth three and must be
uniquely identifiable as a behavior, rather than as one surface program, from
each public demonstration pack. This distinction is necessary because
commuting or cancelling primitives can give multiple programs the same behavior;
demonstrations cannot identify an arbitrary canonical spelling.

Six fixed packs contain three examples each and share no inputs. Packs zero
through four appear one apiece in a family's five training variants. Pack five
is absent from training and is used for retention probes and held-out
compositions. Exactly 426 depth-three behaviors are uniquely identified by all
six packs. For each catalog seed, deterministic selection chooses 30 distinct
behaviors from that pool and first guarantees that their canonical programs
collectively cover all 12 primitives. The five training variants have fresh,
effective query inputs. Replay suites retain 16 structural and eight seeded
private cases per family, and probes retain the same every-five-family schedule
as version 1.

The public task projection contains only a task identifier, ordered workflow
components, their public demonstrations, a query input, and a primitive-step
budget. Expected query output, canonical programs, structural signatures, and
replay cases remain verifier data. The agent receives only:

- `apply_operation(operation)`, which applies one declared primitive to the
  verifier-owned current query value; and
- `submit_result()`, which checks that current value against the hidden expected
  output.

A primitive trace may use any closed-language program within the budget that
produces the exact answer. It is not required to equal the generator's canonical
program because public demonstrations identify behavior rather than syntax.
The verifier rejects direct answer text, unknown operations, and primitive calls
beyond three per component. A later candidate skill is promoted only when its
program matches the family's complete hidden replay suite. Its authenticated
semantic signature, not its surface program order, supplies the compatibility
label. Held-out success never requires invoking a skill; contribution remains a
separate matched intervention as specified below.

Sixty held-out tasks use distinct ordered tuples and pack five to demonstrate
each component. Rejection sampling requires every component to change its
intermediate value and requires the nonempty final output to differ from the
query input. All arms can therefore solve a held-out task using primitive calls
alone, while a verified skill provides a reusable executable representation of
a transformation that was not disclosed as primitive tokens.

The candidate complete-loop pilot is fixed before model exposure. Its first 20
tasks use excluded seeds `910101`/`910102`, compose three workflows (nine
primitive steps), and permit 11 model rounds: nine applications, submission,
and one recovery round. Temperature is zero, model seed is `20260809`, context
is 32,768 tokens, and generation is capped at 1,024 tokens per round. The plain
agent starts a fresh conversation per task and has no cross-task state.

The admissible frontier remains the closed success interval `0.25..0.75`. One
and only one composition-arity revision is permitted on new excluded seeds
`910103`/`910104`: use arity two if the initial result is below `0.25`, or arity
four if it is above `0.75`, with the round ceiling fixed by
`3 * composition_arity + 2`. If the revised result remains outside the interval,
reject version 2. Adapter/schema failures are not difficulty results, but their
reports are immutable and any repair must preserve the public task semantics.
The model harness and Gene exporter must agree exactly on every demonstration
and hidden query output before a model call.

The initial arity-three run accepted 0 of 20 tasks. Every episode consumed the
full 1,024-token generation allowance and ended after its first response with no
tool call. It generated 20,480 tokens in 419.17 seconds, including 9.37 seconds
of deterministic export. The immutable report is
[`gpt-oss-20b-latent-workflow-difficulty-pilot-2026-08-09.json`](../qualifications/gpt-oss-20b-latent-workflow-difficulty-pilot-2026-08-09.json).

The single allowed revision used arity two and new excluded seeds exactly as
specified. It also accepted 0 of 20; again, every episode consumed 1,024 tokens
and returned no tool call. It generated 20,480 tokens in 424.63 seconds,
including 8.69 seconds of deterministic export. Its immutable report is
[`gpt-oss-20b-latent-workflow-difficulty-pilot-v2-2026-08-09.json`](../qualifications/gpt-oss-20b-latent-workflow-difficulty-pilot-v2-2026-08-09.json).

Version 2 therefore fails its declared frontier gate. There were no attempted
tool calls, so this is not evidence about schema conformance or exact verifier
acceptance; it is evidence that whole-task latent inference before the first
action is below the qualified model's capability under the fixed generation
budget. A third version may expose a bounded candidate-checking operation over
the already-public demonstrations so inference can proceed one component at a
time. Such an operation must not query hidden replay cases, reveal a canonical
program, or carry promotion authority. It is a new interaction design, not a
post hoc revision of version 2, and requires new excluded pilot seeds and a new
unopened evaluation schedule after qualification and review.

## Rejected version-3 component-wise workflow subject

Status: rejected on 2026-08-09 by its own preregistered liveness gate, at both
the frozen generation budget and the single declared repair. The design and its
frozen rules are retained below exactly as they stood before model exposure,
followed by both immutable results. The generator, its soundness rule, and its
public/hidden boundary remain sound and reusable; the interaction is not
executable by the qualified model.

Version 3 keeps the version-2 latent-workflow distribution — a workflow is
identified only by three public input/output demonstrations, never by its
primitive expansion — and changes the interaction. The agent no longer has to
infer an entire multi-component workflow before its first action. It identifies
and commits to one component at a time.

Its generator is a new versioned layer over the retained version-2 building
blocks in
[`latent_workflow_subject.gene`](../../../../examples/general_intelligence/src/latent_workflow_subject.gene).
The version-2 catalog, family order, replay suites, training variants, and
retention probes are reused unchanged. The held-out compositions are redrawn
under one additional rejection rule, defined below, and a new public projection
exposes ordered components rather than a whole-task goal string. Version 2's
source, exporter, harness, and immutable reports remain byte-identical negative
evidence. The version-3 files are
[`component_workflow_subject.gene`](../../../../examples/general_intelligence/src/component_workflow_subject.gene),
[`component_workflow_pilot_export.gene`](../../../../examples/general_intelligence/src/component_workflow_pilot_export.gene),
and
[`tools/pilot_component_workflow_agent.py`](../../../../tools/pilot_component_workflow_agent.py).

### Public checker contract

Two typed tools are model-facing during the difficulty pilot:

```text
apply_workflow_candidate(workflow_id: string, operations: [string, string, string])
submit_result()
```

`apply_workflow_candidate` targets exactly one position: the first component
that has not yet been accepted. A request is *well formed* when its arguments
match the declared schema, `workflow_id` equals that component's public
identifier, and `operations` is exactly three tokens drawn from the declared
12-primitive catalog. A well-formed request consumes one candidate attempt; any
other request returns a single generic `invalid_request` status, consumes no
attempt, and changes no state.

A well-formed candidate is checked against **only** that component's three
already-public demonstrations, by executing the candidate on each demonstration
input and comparing with the demonstration output.

| Outcome | Response | Effect |
|---|---|---|
| Candidate reproduces all three public demonstrations | `accepted`, component index, components remaining, and the new current value | The host applies the **model's own candidate** to the current query value and advances exactly one component |
| Candidate misses at least one public demonstration | `inconsistent` and attempts remaining | No state change; per-example results are never returned |
| Attempt budget for the current component is spent | `attempts_exhausted` | The episode ends and is recorded as failed |

`submit_result` takes no arguments, compares the current query value with the
verifier-owned expected output, and is **terminal**: the first submission ends
the episode whether it is accepted or rejected. There is no primitive
`apply_operation` tool in version 3. The only way to move the query value is a
candidate that reproduces the public demonstrations, so a task cannot be solved
by transforming the value without identifying each component's behavior.

### The public checker is a pure function of public data

The response of `apply_workflow_candidate` is computed from the public task
projection and the model's own arguments alone. It reads no verifier-owned
field. Three properties make that exact:

1. acceptance depends only on the three public demonstrations;
2. on acceptance the host applies the candidate the model supplied, not the
   family's hidden canonical program; and
3. the current value returned is therefore a deterministic function of the
   public query input and the model's own accepted candidates.

The model could compute every checker response itself. The tool buys interaction
structure and generation tokens, not information. Consequently the two attempts
per component cannot be an oracle over hidden data: there is no hidden data on
that path to query. The counting bound is also comfortable — two attempts
against `12^3 = 1728` three-operation programs — but the information argument is
the one that holds regardless of budget.

Hidden data is consulted at exactly one place in an episode: the terminal
`submit_result` comparison, which yields one bit, once.

### Generator-enforced public-checker soundness

Applying the model's own candidate is only sound if a demonstration-consistent
candidate cannot diverge from the family's behavior on the value it is applied
to. Version 3 makes that a checked property of the subject rather than an
assumption.

Because a version-2 teachable family is uniquely identified by each
demonstration pack among all 557 finite-bank behaviors, every program of length
zero through three that reproduces a pack has that family's finite-bank
signature. Two programs can share a finite-bank signature and still differ on
some other list, so the generator additionally requires, for every held-out task
and every ordered component:

> every program of length zero through three that reproduces all three of the
> component's public demonstrations must produce the same output as the family's
> canonical program when applied to the exact current value the canonical chain
> reaches at that position.

Composition draws that violate this rule are rejected and redrawn. With the rule
enforced, an accepted candidate always leaves the current value equal to the
canonical intermediate value, so `accepted` is both public-only and
canonical-faithful, and the exported task is solvable exactly when the model
identifies each component's behavior.

The rule is enforced in the Gene generator, revalidated by
`verify_component_workflow_subject`, and independently recomputed by the Python
harness before any model call. Neither the admissible-candidate sets nor the
chain values are ever public.

On the initial excluded pilot seeds `920101` / `920102` the rule rejects nothing:
all 60 compositions and all 180 components satisfy it on the first draw. It is
therefore a proof obligation the distribution already meets, not a filter that
reshapes it. The same run records 80 admissible candidates across the 30
families, between one and six per family, so 20 families admit a spelling other
than the generator's canonical program. Demonstration-consistent behavior, not
canonical syntax, is what advances a component, and the self-test exercises that
path explicitly.

### Authority boundary

| Field | Public | Verifier-owned |
|---|---|---|
| Task identifier, instruction, attempts per component | yes | — |
| Ordered component identifiers and their three demonstrations | yes | — |
| Query input | yes | — |
| Current value after an accepted candidate | yes, derived from public data | — |
| Expected final output | — | yes |
| Canonical component programs and composed target | — | yes |
| Semantic signatures | — | yes |
| Per-component chain values | — | yes |
| Admissible-candidate sets used by the soundness rule | — | yes |
| Replay suites and their case-level results | — | yes |

The public checker has no promotion authority and no path to one. Promotion
remains an authenticated request to the isolated verifier service against a
family's complete hidden replay suite, and `accepted` from the public checker is
not evidence for it. This matters concretely: a candidate can reproduce a pack,
be accepted, advance the task, and still fail hidden replay, because pack
consistency constrains behavior on the finite bank rather than on every list.
Only replay decides whether a proposed durable skill receives the family's
authenticated semantic identity.

### Frozen difficulty-pilot configuration

These values are fixed before the first version-3 model call and are not
adjustable after seeing a trace.

| Item | Value |
|---|---|
| Composition arity | 3 |
| Candidate attempts per component | 2 |
| Round ceiling | `3 * composition_arity + 3` (12 at arity 3) |
| Silent-round cap per episode | 3 |
| Tasks per run | 20 held-out compositions |
| Decoding | temperature `0`, model seed `20260809`, context `32768`, generation `1024` tokens per round |
| Frontier band | closed success interval `0.25..0.75` |
| Initial excluded seeds | `920101` / `920102` |
| Liveness-repair excluded seeds | `920105` / `920106` |
| Difficulty-revision excluded seeds | `920103` / `920104` |

All six seeds are permanently excluded from treatment whether or not they are
used. Every task starts a fresh conversation; the pilot agent has no cross-task
state and no skill tool.

A *silent round* is a model response that returns no tool call. Version 2 ended
the episode on the first such round, so all 40 of its episodes got exactly one
1,024-token response and no second chance. Version 3 instead appends a fixed
deterministic reminder and continues, up to three silent rounds per episode,
after which the episode ends as failed. Silent rounds are recorded per task.

### Liveness gate, then difficulty gate

Liveness is evaluated first and separately, because a run that produces no tool
calls measures the generation budget rather than the subject.

- **Liveness gate.** At least 18 of 20 episodes must emit at least one
  schema-conformant tool call. A run below that is recorded as an
  interaction-liveness failure and is **not** a difficulty result, exactly as
  version 1's adapter failure was not.
- **Declared liveness repair.** At most one is permitted: raise generation from
  1,024 to 2,048 tokens per round, change nothing else, and rerun on the new
  excluded pair `920105` / `920106`. Reusing the failed pair is not allowed. If
  liveness fails again, reject version 3 and record that this interaction is
  beyond the qualified model's per-round generation envelope.
- **Difficulty gate.** Only a liveness-passing run is scored against the
  `0.25..0.75` frontier band.
- **Declared difficulty revision.** At most one, on the new excluded pair
  `920103` / `920104`, at whatever generation budget passed liveness: arity two
  if the result is below `0.25`, arity four if it is above `0.75`, with the
  round ceiling recomputed by the same formula. If the revised result is still
  outside the band, reject version 3.

Adapter or schema failures remain non-difficulty results, their reports remain
immutable, and any repair must preserve public task semantics. The model-facing
candidate stays a flat string array with an enumerated item type, the shape the
pinned model accepted; reopening adapter qualification requires a separate
recorded justification.

### Required self-tests before any model call

The deterministic self-test must prove all of the following without contacting a
model:

1. a behavior-equivalent three-operation array that is not the family's
   canonical spelling still advances one component;
2. an inconsistent array returns only the generic status, consumes exactly one
   attempt, and advances nothing;
3. attempt, round, and silent-round budgets are exact, and a third attempt on
   one component is refused;
4. every checker request and response is reconstructible from the public
   projection and the model's arguments alone, with no verifier-owned field
   present;
5. the hidden expected output is read only by the terminal submission;
6. no tool, status, or field offers promotion, and the model-facing tool set is
   exactly the two declared tools;
7. the Gene projection and the Python harness agree exactly on every
   demonstration, chain value, admissible-candidate set, and expected output;
   and
8. the soundness rule holds for every exported component.

### Pre-execution critique

*Do two public-only attempts make the checker a brute-force oracle?* No. The
checker reads no hidden field, so repeated queries cannot extract hidden
information at any budget; the attempt cap exists to keep candidate proposal a
measure of inference rather than enumeration, and two attempts cover about one
part in nine hundred of the three-operation space.

*Do returned current values leak anything non-public?* No, given the two rules
above: the host applies the model's own candidate, and the soundness rule
guarantees that value equals the canonical intermediate value. Self-test 4
enforces this by reconstruction rather than by inspection.

*Is the round formula sufficient without inviting another no-call failure?* The
formula covers `2 * arity` attempts, one submission, and the three-silent-round
allowance with slack, so budget exhaustion cannot masquerade as refusal to act.
It does not by itself prove the model will act: that is what the liveness gate
measures, with a declared one-step repair, so a second no-call outcome becomes
recorded evidence about the generation envelope instead of an unplanned
redesign.

*What does a verified skill buy if the public checker is free?* Not correctness
on these tasks — the soundness rule makes an accepted candidate canonical on the
chain value. It buys budget and retention: an authenticated skill advances a
component without consuming candidate attempts or inference tokens, and it is
the only artifact whose behavior has been checked against the complete hidden
replay suite. Treatment adds `invoke_skill(skill_id)` for the skill-bearing arms
under matched total budgets; all arms see the identical public checker, so the
checker is part of the environment rather than an advantage of one arm.

*Does removing `apply_operation` change what is measured?* Yes, deliberately.
Version 2 accepted any primitive trace that produced the exact answer. Version 3
requires per-component identification, which is the reusable-skill problem this
experiment exists to test. It also raises difficulty, which the frontier band
and its single declared revision are there to measure.

### First run: interaction-liveness failure

The initial run used the frozen configuration exactly: excluded seeds
`920101` / `920102`, arity three, two attempts per component, a 12-round
ceiling, a silent-round cap of three, and 1,024 generated tokens per round. Its
immutable report is
[`gpt-oss-20b-component-workflow-difficulty-pilot-2026-08-09.json`](../qualifications/gpt-oss-20b-component-workflow-difficulty-pilot-2026-08-09.json).

It failed the liveness gate. Only 4 of 20 episodes emitted a schema-conformant
tool call, a liveness rate of `0.200` against the required `0.90`, so **the 0/20
success rate is not a difficulty result** and the frontier band was not applied.

| Measure | Value |
|---|---:|
| Episodes with at least one conformant call | 4 / 20 |
| Rounds | 85 |
| Silent rounds | 80 |
| Generated tokens | 85,602 |
| Generated tokens per round | ≈ 1,007 |
| Tool calls | 5 |
| Schema-conformant tool calls | 5 |
| Candidate attempts | 5 |
| Components accepted | 5 / 60 |
| Hidden expected-output reads | 0 |
| Total wall seconds | 1,770.66 (25.24 exporting) |

Ninety-four percent of rounds ended with no tool call at essentially the full
1,024-token allowance, so this is the version-2 truncation failure again rather
than a refusal, a schema problem, or an inability to identify a component. Two
details sharpen that reading and neither is a difficulty claim:

- every candidate the model did emit was accepted — 5 attempts, 5 conformant,
  5 components advanced, no `inconsistent` and no `attempts_exhausted`; and
- no episode reached submission, so the hidden expected output was read zero
  times across the whole run.

The five accepted attempts are far too few, and too concentrated in early
components, to say anything about the task distribution's difficulty. They do
rule out the adapter and the checker as the cause: when the model finished
reasoning, the interaction worked exactly as specified. Splitting the task into
one component per round was necessary but not sufficient; the per-round
generation envelope is the binding constraint.

The declared liveness repair therefore applies, once: 2,048 generated tokens per
round, everything else unchanged, on the fresh excluded pair `920105` / `920106`.

### Declared repair: liveness failed again, so version 3 is rejected

The repair ran exactly as declared — 2,048 generated tokens per round, excluded
seeds `920105` / `920106`, arity three, two attempts per component, a 12-round
ceiling, and a silent-round cap of three. Its immutable report is
[`gpt-oss-20b-component-workflow-liveness-repair-2026-08-09.json`](../qualifications/gpt-oss-20b-component-workflow-liveness-repair-2026-08-09.json).

Liveness rose from `0.200` to `0.500` and remained below the required `0.90`.

| Measure | Initial (1,024 tokens) | Repair (2,048 tokens) |
|---|---:|---:|
| Episodes with a conformant call | 4 / 20 | 10 / 20 |
| Liveness rate | 0.200 | 0.500 |
| Rounds | 85 | 98 |
| Silent rounds | 80 | 79 |
| Generated tokens | 85,602 | 181,106 |
| Generated tokens per round | ≈ 1,007 | ≈ 1,848 |
| Tool calls / schema-conformant | 5 / 5 | 19 / 19 |
| Candidate attempts | 5 | 18 |
| Components accepted | 5 / 60 | 14 / 60 |
| Hidden expected-output reads | 0 | 1 |
| Accepted tasks | 0 / 20 | 0 / 20 |
| Total wall seconds | 1,770.66 | 3,684.76 |

By the preregistered rule, a second liveness failure rejects version 3. It is
rejected. The recorded finding is that this interaction is beyond the qualified
model's per-round generation envelope, not that the task distribution is too
hard or too easy: the frontier band was never applied to either run, and no
difficulty revision is permitted, because a difficulty revision is defined only
for a liveness-passing run.

What the two runs show together:

- **The budget is binding and the response is not converging.** Doubling
  generation doubled liveness but barely moved the silent-round count, 80 to 79.
  Whenever the model was silent it again consumed nearly the entire allowance
  (≈1,848 of 2,048 tokens per round). Its reasoning expands to fill whatever
  budget it is given, so a third increase is neither permitted nor well
  motivated — and the repair run already took 61 minutes for 20 tasks.
- **The interaction itself works.** Across both runs the model emitted 23 tool
  calls, all 23 schema-conformant, and 19 of 23 candidate attempts were accepted.
  No attempt budget was ever exhausted. When the model finished reasoning it
  identified components correctly; it simply did not finish often enough.
- **The authority boundary held exactly as specified.** The hidden expected
  output was read zero times in the first run and once in the second — the one
  early submission on task 18, which was rejected. Nothing else in either run
  touched verifier-owned data.

The 19-of-23 component acceptance rate is **not** a difficulty result and must
not be treated as one. It is measured only on the components of episodes that
acted at all, which is half the run at best, and it says nothing about whether a
model that reliably acted would land inside `0.25..0.75`.

### What the rejection implies for a version 4

These are directions, not decisions. Any of them is a new experimental version
requiring new excluded seeds, independent review, and a new unopened schedule.

1. Reduce the per-round inference cost below one three-operation component —
   shorter components, a smaller primitive catalog, or a first action that
   requires no inference at all. Version 3 already shortened the unit of work
   from a whole task to one component, and that was necessary but not enough.
2. Change the model or the decoding regime, which reopens model qualification
   rather than amending this subject. A model with a smaller reasoning-token
   appetite, or explicit reasoning-effort control, is a different qualified
   artifact and a different experiment.
3. Do not respond by weakening the hidden boundary. The checker and the adapter
   were never the failure; making more information public would trade away the
   experiment's validity for a problem it would not fix.

### Qualification gate lesson

The 2026-08-09 qualification gate passed `gpt-oss:20b` at 20 of 20 mock-tool
tasks using 4,308 generated tokens over 69 calls — roughly 62 tokens per call.
That gate measured tool-call mechanics on tasks with negligible inference depth,
and it did not predict that the same model would fall silent on 79 to 80 percent
of rounds once each round required inverting a three-operation program from
three examples.

A future qualification gate should therefore include at least one task whose
per-round inference cost is comparable to the intended subject's, and should
record generated tokens per round rather than only totals. Otherwise a model can
pass qualification and still be liveness-incapable of the experiment it was
qualified for, which is what happened here across two subject versions.

## Candidate model-qualification gate

Qualification runs through
[`tools/qualify_local_model.py`](../../../../tools/qualify_local_model.py), a
standard-library-only harness over Ollama's native `/api/chat` tool interface.
The 2026-08-09 host is a 20-GPU-core Apple M4 Pro with 48 GiB unified memory,
macOS `Mac16,8`, and Ollama `0.32.1`. No model was cached before qualification.

Candidates are tested sequentially in ascending advertised local artifact size:

| Order | Ollama tag | Advertised artifact | Role |
|---:|---|---:|---|
| 1 | `gpt-oss:20b` | 14 GB | selected: first candidate passed |
| 2 | `devstral-small-2:24b` | 15 GB | skipped by the predeclared first-eligible rule |
| 3 | `qwen3-coder:30b` | 19 GB | skipped by the predeclared first-eligible rule |

The first eligible candidate is selected and later candidates are not
downloaded. This is equivalent to selecting the lowest-resource eligible model
without requiring roughly 48 GB of candidates to coexist on a disk that had 32
GiB free at qualification start. If an earlier candidate fails, its dated
report is retained before its local blobs may be removed to make room for the
next candidate.

Each report records the resolved Ollama manifest digest, manifest SHA-256,
every config/layer digest and media type, template SHA-256, parameter family,
quantization, runtime version, decoding, hardware, token counts, and timings.
For a GGUF model, its content-addressed model layer jointly pins weights and
tokenizer data; separate manifest/config digests pin the runtime template and
parameters.

Decoding is fixed at temperature `0`, seed `20260809`, context `32768`, maximum
generation `1024` tokens per round, and at most eight tool rounds per task.
Every task starts a fresh conversation and sees only three deterministic mock
tools: `get_fact`, `run_operation`, and `submit_artifact`. Free-form text never
counts as success; only an exact artifact accepted by the mock verifier does.

The 20 public tasks are fixed in the harness and disjoint from later lifelong
tasks:

| IDs | Count | Coverage |
|---|---:|---|
| `q01`–`q05`, `q14` | 6 | schema-correct fetch/operation/submission calls |
| `q06`–`q10`, `q13`, `q15`, `q18`, `q19` | 9 | two- and three-step retrieval/transform chains |
| `q11`, `q12`, `q16`, `q20` | 4 | recover from missing keys or rejected operations |
| `q17` | 1 | recover from a rejected artifact and resubmit |

Typed-call conformance is the number of returned tool calls whose name,
required arguments, argument types, and additional-property rules match the
declared schema, divided by all returned tool calls. A semantically rejected
but schema-correct call remains conformant; failure to recover still fails its
task.

Eligibility requires at least 12 of 20 accepted artifacts, typed-call
conformance of at least 0.95, no context-limit failure, artifact size no more
than 20 GB, Ollama loaded allocation no more than 36 GiB, total wall time no
more than 60 minutes, per-task p95 wall time no more than 180 seconds, and no
more than 40,000 generated tokens. If no candidate qualifies, block the
experiment before production-verifier work.

### Qualification result

The first candidate passed every gate. The immutable run record is
[`gpt-oss-20b-2026-08-09.json`](../qualifications/gpt-oss-20b-2026-08-09.json).
The selected model is `gpt-oss:20b`, manifest and manifest-file SHA-256
`17052f91a42e97930aa6e28a6c6c06a983e6a58dbb00434885a0cf5313e376f7`,
with model-layer digest
`e7b273f9636059a689e3ddcab3716e4f65abe0143ac978e46673ad0e52d09efb`.
The harness SHA-256 was
`2aca072eb430b1e33ac22fd3161ca25bf172543652c7c25d241dcb23d66c2244`.

It accepted 20 of 20 artifacts and emitted 69 of 69 schema-conformant tool
calls, with zero context failures. It generated 4,308 tokens in 114.60 seconds;
per-task p95 was 11.44 seconds. The local artifact was 13,793,441,244 bytes and
Ollama reported 12,757,436,988 bytes of loaded allocation. Because the first
candidate was eligible, the two fallbacks were not downloaded or evaluated.
These public mock-tool results qualify the model for verifier-pilot work; they
are not evidence that it can solve the later lifelong-task distribution.

## Candidate verifier and records

Package every task family with a deterministic generator and hidden tests owned
by an isolated process or container. Its filesystem and credentials are not
agent capabilities. The agent gets only a typed artifact-submission operation;
the verifier returns a signed or hash-linked result without exposing tests.

Extend the agent with exact records:

- `episode`: goal, observations, actions, outputs, verifier result, and cost;
- `lesson`: failure hypothesis linked to supporting episodes;
- `skill`: typed Gene program or tool composition with preconditions, effects,
  provenance, tests, and version.

Reflection may propose lessons and skills, but only the independent verifier
promotes a skill. Begin with lexical or structural retrieval; approximate
indexes remain optional and cannot change exact skill semantics.

The non-evaluation mechanism pilot now lives in
[`examples/general_intelligence/src/verified_skills.gene`](../../../../examples/general_intelligence/src/verified_skills.gene)
and
[`skill_verifier_pilot.gene`](../../../../examples/general_intelligence/src/skill_verifier_pilot.gene).
It executes a bounded declarative pipeline rather than evaluating arbitrary
model-authored code. A separate verifier process owns four toy cases, promotes
the candidate that passes all four, rejects an incomplete candidate that passes
only one, and returns a candidate-bound, suite-bound, hash-linked receipt. The
record smoke also proves that changing a receipt after sealing invalidates it.

This pilot does not satisfy experimental isolation. Its test cases are checked
in, its stdout can be forged by a caller, and SHA-256 linkage provides integrity
but not verifier authentication. Production design must give the agent only a
typed submission channel to a verifier-owned service or isolated process; the
trusted consumer must receive promotions over that channel rather than trust a
model-supplied receipt. Pilot tasks and skills are permanently excluded from
the future curriculum and evaluation.

The next excluded pilot implements that shape in
[`tools/pilot_skill_verifier_service.py`](../../../../tools/pilot_skill_verifier_service.py)
and
[`skill_verifier_service_kernel.gene`](../../../../examples/general_intelligence/src/skill_verifier_service_kernel.gene).
The private service exclusively owns a suite, 32-byte-or-longer HMAC key,
append-only canonical journal, and Unix socket, all outside the agent worktree
with no group or other permissions. It invokes an exact Gene kernel with only a
named read capability for the suite. Candidate Gene is parsed as data and may
use only the closed, bounded pipeline interpreter; it is never evaluated as
code.

Each journal receipt authenticates the suite, kernel, candidate source,
canonical candidate, exact kernel output, failure-code projection, sequence,
previous receipt, timestamp, wall time, and peak RSS. The model-facing response
contains only `promoted`, `rejected`, or one generic submission error plus
opaque candidate and receipt digests. Test identifiers, counts, paths, kernel
evidence, and receipt authentication data remain on the verifier side. A
trusted consumer revalidates the complete HMAC/hash chain against its current
suite and kernel before reading promoted source; it never consumes a receipt
supplied by the model.

### Verifier-boundary threat model

| Threat | Pilot control | Residual requirement before treatment |
|---|---|---|
| Agent reads tests or signing material through its tool surface | Only the socket is a submitter capability; suite and key paths are not in the request or response; the Gene kernel receives one named read capability. | Run the service under a distinct OS/container identity. Mode bits do not hide files from another process controlled by the same Unix user. |
| Candidate executes arbitrary code or reads verifier state | Parse one bounded Gene form as data and interpret only `trim`, `lowercase`, and bounded literal `replace` steps. | Expand the skill language only with separately reviewed total operations and explicit effect capabilities. |
| Model or caller forges a passing stdout record | The trusted consumer reads the verifier-owned journal and checks HMAC-SHA-256; submitter output has no promotion authority. | Put key storage, rotation, backup, and consumer access under the verifier identity. HMAC is symmetric trust, not a public signature. |
| Candidate, suite, kernel, or evidence is altered after verification | Receipts bind every source/evidence digest; the canonical journal is sequence- and previous-receipt-linked. | Freeze treatment suite and kernel digests before any curriculum task is submitted. |
| Replay, stale writers, or malformed input corrupt the chain | Requests carry the expected journal head; closed schemas, byte limits, timeouts, and per-connection generic errors reject invalid input without appending or exiting. | Use one authoritative writer or transactional storage when moving beyond this sequential pilot. |
| Repeated pass/fail queries reveal hidden cases | Responses omit case-level data and the service has a bounded request lifetime. | Preregister per-task attempt budgets, rate limits, suite rotation, and leakage audits; aggregate status alone is still an oracle. |
| Verifier work consumes the claimed benefit | Every authenticated record carries kernel wall time and peak RSS, capped at 1 second and 64 MiB in this pilot. | Measure whole-service and model costs across the projected curriculum and include them in arm budgets. |

The self-test uses only permanently excluded toy cases. It proves one promotion,
one rejection, continued service after a stale-chain request, zero submitter-
visible case details, safe rejection of invalid Unicode, authenticated journal
replay, mutation/forgery rejection, and enforcement of the outside-worktree
authority rule. It is not evidence that the suite is secret from the
repository's ordinary user and is not a treatment result.

The qualified model was then connected through
[`tools/pilot_verified_skill_agent.py`](../../../../tools/pilot_verified_skill_agent.py)
with only the typed submission capability. The first nested-object schema and a
second flat schema with one enum field per step both failed all six submission
rounds on schema conformance; their immutable reports are
[`nested-schema-failed`](../qualifications/gpt-oss-20b-verified-skill-pilot-nested-schema-failed-2026-08-09.json)
and
[`flat-enum-failed`](../qualifications/gpt-oss-20b-verified-skill-pilot-flat-enum-failed-2026-08-09.json).
This is retained negative evidence about the adapter, not hidden-task outcome
tuning.

The third contract kept metadata scalar and represented the program as a flat
string array. It passed in one round with one conformant submission, 357
generated tokens, 6.96 seconds total wall time, and 4 of 4 verifier cases. The
accepted report is
[`gpt-oss-20b-verified-skill-pilot-2026-08-09.json`](../qualifications/gpt-oss-20b-verified-skill-pilot-2026-08-09.json).
The model had no file or shell capability and received only safe aggregate
verifier output. The accepted receipt digest is
`edaaf1f61e6ea91a120c17785c369f4ca4fe046a47d525319147b80806bb3091`.
This fixes the candidate model-facing adapter shape for the next pilot; it does
not freeze the lifelong-task subject or qualify the checked-in tests as hidden
from the repository's ordinary coding agent.

The unchanged flat-array contract was then rerun through the authenticated
service boundary. Its immutable report is
[`gpt-oss-20b-verified-skill-service-pilot-2026-08-09.json`](../qualifications/gpt-oss-20b-verified-skill-service-pilot-2026-08-09.json).
It again passed in one round with one conformant submission and 357 generated
tokens in 15.01 seconds. The model-facing transcript contains one aggregate
`promoted` status, candidate and receipt digests, and zero test details. After
the model process completed, the trusted consumer authenticated the one-record
journal and matching head against the ephemeral external suite and current
kernel. Kernel execution took 0.0450 seconds and peaked at 11,763,712 RSS bytes,
within the preregistered pilot ceilings of 1 second and 64 MiB. This closes the
adapter-to-service mechanism path only; the ephemeral excluded suite and
same-user host do not satisfy treatment isolation.

## Provisional arms and evaluation

The arm semantics and statistical rules below remain candidates, but every task
count and cost derived from subject version 1 is now illustrative rather than a
frozen treatment design. The replacement subject must justify or revise them
before review.

Present the 30 task families sequentially in the frozen seed order. Every task
starts a fresh model conversation; only the arm's declared durable store crosses
task boundaries. Compare:

| Arm | Cross-task state |
|---|---|
| fresh | none |
| episodic | bounded exact episode records and retrieved lesson text |
| skills | authenticated promoted skills and structural/lexical retrieval |
| combined | the same episodic and skill stores together |

All arms receive identical public tasks, primitive tools, decoding, per-task
round/token ceilings, and total seed-level model/tool/wall budget. The skill
arms may propose at most one candidate after a family's fifth training variant;
verification, replay, retrieval, and skill execution consume their budget.
Non-skill arms receive the same total budget as additional ordinary task
attempts, but no hidden verifier queries or synthetic memory. Episode and
lesson stores use byte/item ceilings fixed by the difficulty pilot. Use the
immutable qualified local model for the strict experiment; provider-model runs
are separately versioned replications.

After family blocks 5, 10, 15, 20, 25, and 30, run the generated fresh probes
for every family introduced so far, then rerun every promoted skill's complete
24-case suite. Probe and replay results cannot enter memory or trigger a new
promotion. This separates retained task performance from skill integrity.

Across the eight candidate subject pairs, evaluate the 60 held-out compositions
that were never available for promotion. The primary comparison is the paired
seed-level held-out success proportion of the combined agent versus episodic
text only. Use the fixed two-sided 95% Student interval over eight paired
differences (`df=7`, critical value `2.364624251`). Retention, replay integrity,
calls, wall time, curriculum progress, retrieval, wrong-skill selection, and
abstention are secondary or safety measures.

Candidate pass rule: mean held-out advantage of at least 15 percentage points
with the interval's lower endpoint above zero; pooled combined-arm retention of
at least 90% over probes whose family initially achieved at least four of five
training successes, with no seed below 80%; and a promoted-skill hidden-replay
failure proportion below 5% whose two-sided 95% Wilson upper bound is also below
5%. Reduced model calls are product evidence rather than a transfer criterion.

Reject the mechanism if verified skills do not improve held-out composition,
old-task success falls materially, promoted skills fail replay, or the
curriculum stops increasing in useful diversity/difficulty. Retrieval-dependent
failure rules apply only if the calibration below becomes a valid gate. A
model-authored success claim without the external verifier is unknown.

## Candidate capability calibration

Sample 200 non-evaluation `(task, skill)` pairs, balanced across exact hidden
component-membership labels and library-size quartiles. For each pair, run
matched deterministic interventions with the skill supplied and with an
interface-compatible no-op, repeating each condition. Operational contribution
requires both supplied runs to invoke the receipt-bound skill and pass while
both masked replays fail exact trace validation. Necessity and alternative-skill
substitutability are reported separately.

Candidate ontology gate: precision and recall of at least `0.85` against these
behavioral labels, with at most two recorded ontology revisions on disjoint
calibration data. If reliable labels cannot be produced, retrieval and
abstention remain diagnostics and tag-dependent failure rules are disabled.

An optional external semantic audit requires two reviewers blinded to the
derived tags and each other, an adjudicator, exclusion of the ontology author,
and candidate Cohen's kappa of at least `0.80`.

## Provisional pilots and cost

Under rejected subject version 1, each seed and arm contains 150 training tasks,
105 retention probes, and 60 held-out compositions: 315 task episodes. The
primary four-arm, eight-seed run is therefore 10,080 task episodes. Each
skills-containing arm may add 720 initial hidden-case executions plus 2,520
block replay-case executions per seed if all 30 skills are promoted. One
calibration is 800 condition executions; three attempts imply a 2,400-execution
worst case.
Include model calls, candidate generation, all verifier cases, retrieval,
storage, and trusted-consumer work in the projected and observed budgets.

The first non-model mechanism pilot promotes a passing skill, rejects a
deliberately failing candidate, and executes the passing skill on distinct toy
variants. The first model-connected pilot additionally records rounds, tokens,
wall time, verifier time, and exact source/output hashes. The service-boundary
pilot adds verifier-owned external storage plus authenticated per-submission
kernel wall time and peak RSS. It does not yet measure full-service memory or
the projected curriculum cost. Pilot tasks and artifacts never enter an
experimental arm or library.

This is a version-1 cost projection, not authorization to run the treatment.
Planning estimate: 4–8 person-months after a local model qualifies, with roughly
`2x` uncertainty. This is the largest near-term engineering programme in the
architecture.
