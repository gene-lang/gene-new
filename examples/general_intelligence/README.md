# General-intelligence experiments

This package holds executable mechanisms for the falsifiable experiments in
[`docs/proposals/general_intelligence/architecture.md`](../../docs/proposals/general_intelligence/architecture.md).
It is research scaffolding, not an AGI claim and not a new runtime dependency.

The library-induction slice for experiment 1 is in
`src/library_induction.gene`. It interprets a closed 12-primitive list DSL,
extracts only repeated subprograms with positive corpus MDL, and performs exact
iterative-deepening search under a candidate counter. Its constructed smoke
shows a reusable abstraction extending search reach at an equal ceiling; it is
mechanism evidence, not a treatment result.

The same module now owns a deterministic candidate corpus generator. It creates
100 library-learning, 25 model-selection, and 50 held-out four-step tasks per
seed, embeds four reusable latent motifs, and rejects every target that one of
the 1,885 programs of depth zero through three can match on the fixed 16-input
structural bank. The verifier record includes that whole bank plus eight seeded
hidden cases. Target programs and hidden cases remain verifier-owned data.

Run it with:

```bash
bin/gene run examples/general_intelligence/tests/library_induction_smoke.gene
bin/gene run examples/general_intelligence/tests/library_induction_corpus_smoke.gene
bin/gene run examples/general_intelligence/tests/library_induction_corpus_pilot.gene
bin/gene run examples/general_intelligence/tests/library_induction_control_pilot.gene
bin/gene run examples/general_intelligence/tests/library_induction_evaluation_pilot.gene
```

The corpus smoke proves deterministic reproduction and independent structural
validation on pilot seeds. The full-size pilot uses permanently excluded seed
`900101`; it generates all 175 tasks and confirms that one-round induction
recovers a latent motif. Four capped positive-MDL rounds recover all four latent
motifs, and an independent expansion check proves that every compressed program
still denotes its original primitive sequence. The control pilot learns from a
disjoint donor seed and accepts only an exact search-shape match with no shared
primitive body. These commands write or open no evaluation data, and all pilot
seeds are permanently excluded from treatment. The evaluation pilot keeps four
public cases on the search side and 24 cases on the hidden-verifier side. It
records and rejects public-only false positives while comparing complete
depth-three primitive-only, induced, and matched-unrelated enumeration.

`tools/prepare_library_induction_freeze.py` turns experiment 1's remaining
independent-review gate into an exact workflow. `packet` hashes the protocol,
implementation, runtime, arithmetically selected eight-target seed schedule,
resource ceilings, and analysis. `freeze` accepts only an external attestation
for that digest, then writes canonical target-corpus/induced-library/matched-
donor setup artifacts outside the worktree without executing any held-out
search. `verify` detects source, manifest, attestation, schedule, and setup
mutation. Its self-test uses only the permanently excluded evaluation-pilot
seeds and reproduces the known 44-versus-12 result through
`src/library_induction_frozen_evaluation.gene`.

After a legitimate freeze, `tools/run_library_induction_evaluation.py run` is
the only intended treatment runner. It verifies the freeze, evaluates each
setup once through the read-capability-limited frozen consumer, records wall
time and peak RSS, hashes every detailed result, and applies the preregistered
paired eight-seed Student interval and per-corpus abstraction-reuse gate. Its
`self-test` uses synthetic counts and opens no corpus.

The first implemented slice is experiment 2's exact-belief repair lab. Its
module interface is intentionally narrow:

- `default_subject` returns the candidate environment as an exact Gene node;
- `update_belief` performs one explicit Bayesian update;
- `plan` enumerates and scores every admissible contingent policy; and
- `verify_subject` returns exact evidence that the subject and enumeration meet
  the protocol's structural gates.

`active_inference_experiment.gene` adds the protocol's exact Park-Miller episode
generator, matched potential observations, four arm executors, and accounting.
Its checked-in pilot uses seeds disjoint from the still-unopened evaluation
streams and prints no arm outcomes.

Run the mechanism smoke from the repository root:

```bash
bin/gene run examples/general_intelligence/tests/active_inference_smoke.gene
bin/gene run examples/general_intelligence/tests/active_inference_pilot.gene
```

The smoke uses no generated evaluation episodes and does not decide the
hypothesis. It exists to freeze the finite state/action grammar and prove exact
enumeration before the treatment comparison is run.

`tools/prepare_active_inference_freeze.py` makes the independent-review gate
mechanical. Its self-test uses only the disjoint pilot stream. On a clean
revision, `packet` emits the exact candidate digest for a reviewer; `freeze`
refuses to generate the 20 evaluation batches unless an attestation approves
that digest, and `verify` rechecks source, manifest, and episode hashes. The
tool never executes a treatment arm.

After a legitimate freeze, `src/active_inference_frozen_batch.gene` is the
trusted consumer: it reads a manifest-selected canonical batch under an
explicit `Fs/ReadDir` capability and evaluates that batch without regenerating
its random stream. The tooling self-test exercises this path only on the pilot
seed.

The second implemented slice is experiment 4's verifier mechanism pilot:

- `verified_skills.gene` defines exact episode, lesson, and skill records plus
  a bounded declarative string-pipeline skill language;
- candidate artifacts and verifier receipts are SHA-256-addressed Gene data;
- `skill_verifier_pilot.gene` is a separate process entry point that owns four
  toy tests, promotes a fully passing artifact, and rejects a subtly incomplete
  artifact; and
- receipt validation rejects mutation and links every result to the previous
  receipt digest.

Run its structural smoke with:

```bash
bin/gene run examples/general_intelligence/tests/verified_skill_records_smoke.gene
```

`tests/test_cli.nim` launches the verifier entry point in separate processes for
the passing and failing candidates. This is a mechanism pilot, not the future
experiment's isolation boundary: its toy tests are checked in, stdout is not an
authenticated transport, and a digest chain proves record integrity rather
than verifier identity. No pilot task, candidate, or promoted skill may enter an
experimental arm.

`tools/pilot_verified_skill_agent.py` connects the qualified local model to
that entry point with one `submit_skill` tool and no file or shell capability.
Its accepted run and the two rejected adapter designs are retained under
`docs/proposals/general_intelligence/qualifications/`. The passing model-facing
contract is deliberately flat: exact skill steps cross as a string array and
the host constructs the canonical Gene node before verification.

`tools/pilot_skill_verifier_service.py` is the next, still-excluded boundary
pilot. A private Unix-socket service owns an external mode-`0600` test suite,
HMAC key, and append-only journal. It runs
`src/skill_verifier_service_kernel.gene` with one named suite-read capability;
the kernel parses candidate Gene as data and executes only the bounded pipeline
interpreter. The submitter sees aggregate status and opaque digests. A trusted
consumer authenticates the journal directly before exposing promoted source.
Every receipt binds the exact suite, kernel, candidate, evidence, chain head,
wall time, and peak RSS.

Run the excluded adversarial self-test with:

```bash
python3 tools/pilot_skill_verifier_service.py self-test
```

It exercises promotion, rejection, safe recovery from a stale request,
safe rejection of invalid Unicode, candidate mutation, receipt forgery, suite
mutation, and rejection of verifier authorities inside the worktree. This
demonstrates the intended capability flow, not secrecy between processes
controlled by one Unix user. A treatment deployment must use a distinct
OS/container identity, frozen hidden suites, and a preregistered
submission/query budget.

The qualified-model boundary rerun is retained in
`docs/proposals/general_intelligence/qualifications/gpt-oss-20b-verified-skill-service-pilot-2026-08-09.json`.
The operator-side command was:

```bash
python3 tools/pilot_skill_verifier_service.py model-pilot \
  --model gpt-oss:20b \
  --output docs/proposals/general_intelligence/qualifications/gpt-oss-20b-verified-skill-service-pilot-2026-08-09.json
```

It passed in one tool round and appended a trusted-consumer audit projection
only after authenticating the private journal. The fixed model adapter received
no suite, key, journal, filesystem, shell, or case-level capability.

`src/lifelong_task_subject.gene` is the retained, rejected version-1 subject
generator from the experiment-4 difficulty gate. It reuses the exact
12-operation list interpreter but
none of experiment 1's tasks, seeds, motifs, libraries, or outcomes. For each
seed it builds 30 distinct screen-minimal workflow families, five training
variants per family, 24 verifier replay cases per family, old-family probes
after each five-family block, and 60 held-out ordered compositions. The final
revision composes six families (18 primitive operations) per held-out task. The
verifier projection owns exact programs, outputs, required family identities,
and replay cases; public tasks expose only operation descriptions and inputs.

Run the permanently excluded full-size smoke with:

```bash
bin/gene run examples/general_intelligence/tests/lifelong_task_subject_smoke.gene
```

The smoke uses catalog/order seeds `900505` and `900506` with the faster
two-family composition shape. It still recomputes the full 30-family catalog,
operation coverage, 720 replay outputs, 150 training results, 105 probes, and 60
ordered composition programs, including the rule that both component skills
materially change each held-out example. The immutable final report pins the
six-family source and records its full deterministic verification separately.

The model passed 16 of 20 final pilot tasks, above the declared maximum of 15,
after the only allowed arity change. This subject and its eight never-generated
evaluation pairs are permanently retired. The source, exporter, harness, three
immutable run reports, and smoke remain checked in as reproducible negative
evidence; they are not a treatment-ready task distribution.

`src/latent_workflow_subject.gene` is the retained, rejected version-2 subject.
Public prompts show three input/output demonstrations per workflow instead of
the primitive sequence. The exact generator enumerates 1,885 programs of length
zero through three, reduces them to 557 structural behaviors, and retains 426
depth-three behaviors that are uniquely identified by every one of six disjoint
demonstration packs. It selects 30 families with complete 12-primitive coverage
and builds the same full-size training, replay, probe, and composition records.

Run the excluded deterministic smoke and the model-harness cross-check with:

```bash
bin/gene run examples/general_intelligence/tests/latent_workflow_subject_smoke.gene
python3 tools/pilot_latent_workflow_agent.py --self-test
```

The first five demonstration packs are used by training variants; the sixth is
held out for probes and compositions. Exact expected outputs, canonical
programs, semantic signatures, and replay cases stay in the verifier projection.
The arity-three pilot on excluded seeds `910101`/`910102` and its one allowed
arity-two revision on `910103`/`910104` both scored 0/20. Every task used the
full 1,024 generated-token allowance and returned no tool call. The exact
generator remains useful negative evidence, but this whole-task inference
interaction is not treatment-ready.

`src/component_workflow_subject.gene` is the version-3 subject built from that
negative result. It reuses the version-2 catalog, family order, replay suites,
training variants, and retention probes unchanged, and changes only the held-out
compositions and their public projection. The agent now advances one ordered
component at a time through a checker that reads nothing but that component's
three already-public demonstrations:

```text
apply_workflow_candidate(workflow_id, operations: [string, string, string])
submit_result()
```

On acceptance the host applies the model's own three operations, so every
checker response is a deterministic function of public data and the model's own
arguments. What makes that faithful rather than merely public is a generator
rule: a composition draw is rejected unless every program of length zero through
three that reproduces a component's public demonstrations also agrees with the
family's canonical program on the exact chain value that component receives. The
rule is enforced during generation, rechecked by
`verify_component_workflow_subject`, and independently recomputed in Python
before any model call. On the excluded pilot seeds it rejects nothing, so it
constrains the export without reshaping the distribution.

Run the excluded deterministic smoke and the model-harness self-test with:

```bash
bin/gene run examples/general_intelligence/tests/component_workflow_subject_smoke.gene
python3 tools/pilot_component_workflow_agent.py --self-test
```

The self-test proves that a behavior-equivalent non-canonical candidate still
advances a component, that an inconsistent candidate returns only a generic
status and consumes exactly one attempt, that malformed or out-of-order requests
consume none, that the public projection and every tool response carry no
verifier-owned field, that the hidden expected output is read exactly once and
only by the terminal submission, that the model-facing surface offers no
promotion path, and that the Gene and Python projections agree exactly on every
demonstration, chain value, and admissible-candidate count.

The pilot's frozen configuration, liveness gate, and single declared revisions
are in
[`protocols/04_lifelong_skill_agent.md`](../../docs/proposals/general_intelligence/protocols/04_lifelong_skill_agent.md).
No version-3 evaluation schedule exists, and none may be selected before the
subject qualifies and its protocol is independently reviewed.

Version 3 was rejected on 2026-08-09 by that liveness gate, twice. On excluded
seeds `920101`/`920102` at 1,024 generated tokens per round, 4 of 20 episodes
emitted a tool call. The single declared repair — 2,048 tokens, fresh excluded
seeds `920105`/`920106`, nothing else changed — reached 10 of 20, still under the
required 18. Because liveness is evaluated before the frontier band, neither
0/20 success rate is a difficulty result and no arity revision was permitted.

Doubling the budget doubled liveness but barely moved the silent-round count, 80
to 79: whenever the model went silent it consumed nearly the whole allowance, so
its reasoning simply expands to fill the budget. The interaction itself worked —
across both runs all 23 tool calls were schema-conformant, 19 of 23 candidate
attempts were accepted, no attempt budget was ever exhausted, and the hidden
expected output was read zero times in the first run and once in the second. The
obstacle is the qualified model's per-round generation envelope, not the checker,
the adapter, or the task distribution.

The generator, its soundness rule, and its public/hidden boundary remain sound
and reusable. The interaction is not executable by `gpt-oss:20b` at this
envelope. Both reports are retained under
`docs/proposals/general_intelligence/qualifications/`.

`tools/qualify_inference_depth.py` is the stage-two model-qualification gate
that failure produced. The 2026-08-09 stage-one gate measured tool-call
mechanics at roughly 62 generated tokens per call and did not predict any of
this. Stage two isolates exactly one version-3 round: twelve fixed,
permanently excluded tasks, each showing three demonstrations of a hidden
three-operation program, one `submit_program` tool, two attempts, and a
public-only consistency check. It gates on liveness at `0.90` and solve rate at
`0.50`, and it records generated tokens **per round** rather than only totals.

```bash
python3 tools/qualify_inference_depth.py --self-test
```

Run against the incumbent on 2026-08-10 it fails the model on liveness
(`0.667`) while passing it on solve rate (`0.667`) — the discrimination the
first gate could not make. Isolating one component raised liveness from `0.200`
on the full subject to `0.667`, so per-round inference depth is the mechanism
rather than prompt size; but `0.667` is still far under `0.90`, and mean tokens
per round of 948.5 with p95 and maximum both at 1,024 show the model saturating
the allowance. Every call it did emit was schema-conformant and accepted on the
first attempt, so the constraint is finishing in budget, not capability. Five of
the eight successes arrived only after at least one silent round, which is
direct evidence for continuing past a silent round instead of ending the
episode. Any candidate model must pass this stage before a subject pilot.

Both qualification harnesses now accept `--think low|medium`, and both omit the
field entirely at default effort so a default-effort request stays
byte-identical to the run it reproduces. `gpt-oss:20b` already exposes
reasoning-effort control, so the next candidate needed no download: at low
effort it passes stage two with liveness `1.000` and solve `0.583`, and passes
stage one as eligible with 19 of 20 tasks and `0.986` conformance. Low effort
converts "never acts" into "acts, sometimes wrong" — no task produced zero
attempts, but per-attempt accuracy fell from 8 of 8 to 7 of 15. Both stages are
also faster and cheaper at low effort.

**`gpt-oss:20b` at low reasoning effort is a qualified configuration for subject
pilots; at default effort it is not.** Version 3 itself stays rejected — its one
permitted repair was used.

Version 4 reran the version-3 interaction unchanged, at arity two on the
qualified low-effort configuration with fresh excluded seeds `930101`/`930102`.
Its report is
`gpt-oss-20b-component-workflow-v4-low-effort-2026-08-10.json`.

Liveness reached **1.000** — all 20 episodes emitted a schema-conformant call,
against 4 and 10 of 20 for version 3. The stage-two gate's prediction about
itself held exactly, which is the qualification methodology working. But success
was 0/20, below the `0.25` floor, and arity two is the generator's minimum, so
version 4 is rejected with no revision available.

Two findings worth carrying:

- **The gate predicts liveness, not accuracy.** It estimated `0.34` at arity two
  from a `0.583` per-component solve rate; the subject's actual per-component
  rate is `0.125`. The obvious explanation — shallower hand-picked gate
  programs — was tested and is false: 11 of 12 gate programs have minimum
  finite-bank depth three, same as the screened families. What differs is
  episode context: a gate round shows one component, a subject round shows two
  plus ordering, a query input, and an accumulating transcript. A stage-three
  gate must measure a component inside a full episode.
- **These runs are not exactly reproducible.** An earlier attempt at this same
  configuration aborted on a transient Ollama `HTTP 500` after 18 tasks; the
  rerun with identical seeds did not reproduce those episodes. Ollama with a
  fixed seed is not bit-reproducible across sessions. The decision was unaffected
  (1/18 and 0/20, both far below the floor), but a gate decision landing near a
  threshold must not be treated as exact.

Experiment 4 now faces a reasoning-effort squeeze rather than a subject problem:
at default effort the model is accurate but acts on a fifth to a half of rounds;
at low effort it always acts but solves an eighth of components.

A characterisation run settled the remaining question. `think: "medium"` returns
the default-effort numbers to every recorded digit — every per-task outcome,
round count, silent count, attempt count, and per-round token count is identical,
both runs generating exactly 30,352 tokens. The model exposes **two** effective
settings, not three, so there is no interior to the trade-off and no version-5
pilot worth running. This task family sits outside `gpt-oss:20b`'s frontier at
every available effort.

The next steps are a different candidate model chosen for reasoning-effort
control, and a stage-three gate that measures a component embedded in a full
episode rather than in isolation. Do not rewrite the subject: four versions have
been rejected and the last two rejections were about the model, not the task.
