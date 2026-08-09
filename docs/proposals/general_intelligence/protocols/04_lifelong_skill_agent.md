# Draft protocol: verified lifelong skill agent

Status: the local-model qualification gate passed on 2026-08-09; the
lifelong-task subject remains not frozen and not implementation-ready. See
[`README.md`](README.md).

## Subject still to specify

Define the task families, deterministic generators, hidden tests, initial
capability ontology, validity/novelty/difficulty rules, frontier-curriculum
rule, qualified local model, inference runtime, and held-out compositions.
Held-out tasks should require capabilities learned in different families rather
than surface variants of one training task.

Open validity question: necessity-based skill compatibility can degrade as a
library gains redundant ways to solve the same subproblem. Decide whether the
frozen protocol measures necessity, contribution, substitutability, or all
three before making retrieval metrics gates.

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

## Candidate arms and evaluation

The current design presents 30 task families sequentially, five variants per
family, with old-family probes after every fifth family. Compare a fresh agent,
episodic text only, verified skills only, and both at matched model, tool, and
wall-time budgets. Use an immutable local model for strict experiments;
provider-model runs are separately versioned replications.

Across eight candidate family-order seeds, evaluate held-out compositions that
were never available for promotion. The candidate primary comparison is
zero-shot held-out-composition success of the combined agent versus episodic
text only. Retention, replay integrity, calls, wall time, curriculum progress,
retrieval, wrong-skill selection, and abstention are secondary or safety
measures.

Candidate pass rule: at least a 15-percentage-point held-out advantage with an
interval excluding zero, at least 90% retention of earlier-family success, and
less than 5% hidden-replay failure among promoted skills. Reduced model calls
are product evidence rather than a transfer criterion.

Reject the mechanism if verified skills do not improve held-out composition,
old-task success falls materially, promoted skills fail replay, or the
curriculum stops increasing in useful diversity/difficulty. Retrieval-dependent
failure rules apply only if the calibration below becomes a valid gate. A
model-authored success claim without the external verifier is unknown.

## Candidate capability calibration

The current draft samples 200 non-evaluation `(task, skill)` pairs across
derived compatibility labels and library-size quartiles. For each pair, run
matched deterministic interventions with the skill supplied and with an
interface-compatible no-op, repeating each condition. Operational compatibility
currently requires both supplied runs to invoke the skill and pass while both
masked replays fail.

Candidate ontology gate: precision and recall of at least `0.85` against these
behavioral labels, with at most two recorded ontology revisions on disjoint
calibration data. If reliable labels cannot be produced, retrieval and
abstention remain diagnostics and tag-dependent failure rules are disabled.

An optional external semantic audit requires two reviewers blinded to the
derived tags and each other, an adjudicator, exclusion of the ontology author,
and candidate Cohen's kappa of at least `0.80`.

## Candidate pilots and cost

The sequential curriculum alone is 4,800 task-arm episodes before holdouts and
probes. One calibration is 800 condition executions; three attempts imply a
2,400-execution worst case. Include those, holdouts, and probes in projection.

The first non-model mechanism pilot promotes a passing skill, rejects a
deliberately failing candidate, and executes the passing skill on distinct toy
variants. The first model-connected pilot additionally records rounds, tokens,
wall time, verifier time, and exact source/output hashes, but it does not yet
measure peak memory or full projected curriculum cost. The production-boundary
pilot must add those measurements and verifier-owned hidden storage. Pilot
tasks and artifacts never enter an experimental arm or library.

Planning estimate: 4–8 person-months after a local model qualifies, with roughly
`2x` uncertainty. This is the largest near-term engineering programme in the
architecture.
