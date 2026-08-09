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
