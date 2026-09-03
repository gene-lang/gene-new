# Candidate protocol: exact-belief active-inference micro-agent

Status: candidate-complete subject, mechanism smoke, disjoint-seed compute
pilot, canonical exporter, sensitivity-complete frozen consumer,
mutation-rejecting freeze, one-shot runner, and preregistered analysis all
implemented and passing excluded-pilot self-tests. No evaluation episode has
been generated or opened. The remaining pre-freeze gate is independent review
of the exact candidate digest.

Implementation:
[`archive/general_intelligence/src/exact_belief.gene`](../../../../archive/general_intelligence/src/exact_belief.gene).
Mechanism smoke:
[`archive/general_intelligence/tests/active_inference_smoke.gene`](../../../../archive/general_intelligence/tests/active_inference_smoke.gene).
Generator/evaluator:
[`archive/general_intelligence/src/active_inference_experiment.gene`](../../../../archive/general_intelligence/src/active_inference_experiment.gene).
Review/freeze tool:
[`archive/tools/prepare_active_inference_freeze.py`](../../../../archive/tools/prepare_active_inference_freeze.py).
Post-freeze runner and preregistered analysis:
[`archive/tools/run_active_inference_evaluation.py`](../../../../archive/tools/run_active_inference_evaluation.py).

## Hypothesis and claim boundary

Explicitly valuing information reduces premature incorrect repairs relative to
reward-only lookahead in this finite hidden-fault subject, without reducing
completion. A pass supports only the declared enumerable repair model and its
prior perturbation. It does not show that information bonuses improve general
tool use, learned world models, or expected utility under the supplied utility
function.

The last limitation matters: exact reward-only lookahead is optimal for its
declared expected-utility objective. The information-seeking arm deliberately
optimizes a second term. Its proposed benefit is fewer incorrect repairs under
a completion constraint, not higher reward-only utility.

## Frozen-candidate subject

One non-starting device has exactly one hidden fault:

| Fault index | Gene name | Base prior | Shifted prior |
|---:|---|---:|---:|
| 0 | `battery` | 0.45 | 0.40 |
| 1 | `fuse` | 0.35 | 0.45 |
| 2 | `sensor` | 0.20 | 0.15 |

The shifted prior is a predeclared rank-swap perturbation: move 0.05 probability
from `battery` and 0.05 from `sensor` to `fuse`. Its total-variation distance
from the base prior is exactly 0.10, and every fault remains above the 0.02
minimum.

Two binary inspections are conditionally independent given the fault. Each may
be used at most once on a policy path:

| Inspection index | Gene name | positive given battery | positive given fuse | positive given sensor |
|---:|---|---:|---:|---:|
| 0 | `voltage_test` | 0.95 | 0.40 | 0.05 |
| 1 | `continuity_test` | 0.20 | 0.85 | 0.30 |

An episode pre-samples the hidden fault and the potential positive/negative
outcome of both inspections. An arm observes an outcome only if its policy uses
that inspection. Pre-sampling makes arms exactly matched without revealing
unused outcomes to a planner.

Terminal actions are `repair` for one of the three faults or `defer`. Utilities
are normalized and include all action cost:

| Event | Utility |
|---|---:|
| correct repair | +0.50 |
| incorrect repair | -0.50 |
| defer without repair | -0.06 |
| each inspection | -0.21 |

At most two inspections and then one terminal action are allowed, so the
maximum horizon is three actions. A policy may terminate earlier. The possible
total utility lies in `[-0.92, 0.50]`, within the declared `[-1, 1]` range. One
inspection costs 0.21 of the 1.00 correct-versus-incorrect repair regret; the
structural admissibility band is `[0.15, 0.25]`.

## Exact belief and policy algorithms

Beliefs are three-element Gene `Float` lists. For inspection `t`, outcome `o`,
and fault `f`, the update is ordinary Bayes conditioning:

```text
p(o | belief, t) = sum_f belief[f] * p(o | f, t)
posterior[f]      = belief[f] * p(o | f, t) / p(o | belief, t)
```

Information gain is in nats. For a contingent policy `pi`, its terminal
posterior is compared with the root prior:

```text
score(pi) = E[normalized_utility | pi]
          + beta * E[KL(terminal_posterior || root_prior) | pi]
```

The primary information-seeking arm fixes `beta = 0.25`. Sensitivity arms use
`{0.10, 0.25, 0.50}`; none may be selected after evaluation.

Policies are exact Gene nodes with this grammar:

```text
policy(S) := (repair ^fault f)
           | (defer)
           | (inspect ^test t
                      ^negative policy(S - {t})
                      ^positive policy(S - {t}))  for t in S
```

where the initial remaining-test set is `{0, 1}`. Enumeration order is repairs
0, 1, 2, then defer, followed by inspections in test-index order and child
policies in their enumeration order. The first maximum wins an exact score tie.

Let `P_k` be the policy count with `k` unused binary inspections. Then
`P_0 = 4`, `P_1 = 4 + 4^2 = 20`, and `P_2 = 4 + 2(20^2) = 804`. Across those
804 policies there are exactly 2,884 terminal observation branches. The smoke
must enumerate both totals and verify, for every policy and every hidden fault,
that its branch probability sums to one within `1e-12`.

## Structural validity gates

These gates are fixed before episode generation. Any failure invalidates the
subject rather than excluding selected episodes:

- base and shifted priors sum to one within `1e-12` and assign every fault at
  least 0.02;
- every likelihood is strictly between zero and one;
- posterior entropy after either outcome of either single inspection is at
  least 0.60 nats under both declared priors;
- inspection-cost/repair-regret ratio is in `[0.15, 0.25]`;
- exact enumeration yields 804 policies and 2,884 terminal branches;
- every policy's observation-branch mass is one for every hidden fault within
  `1e-12`; and
- `beta = 0` and `beta = 0.25` select different policies under both declared
  priors, so the treatment is mechanically distinct.

The 2026-08-09 smoke observed 804 policies, 2,884 branches, minimum one-step
entropy `0.6364032504023012`, and maximum branch-mass error `0.0`.

## Arms

All arms receive the same subject, potential observations, utilities, horizon,
and deterministic tie rule.

1. **Greedy reward:** choose the highest expected-utility terminal action from
   the current belief; never inspect.
2. **Reward-only lookahead:** enumerate the full grammar and maximize the score
   with `beta = 0`.
3. **Random exploration:** at each node choose uniformly from the currently
   legal terminal actions and unused inspections, using its separate declared
   random stream; after two inspections only terminal actions are legal.
4. **Information-seeking:** enumerate the full grammar and maximize the score
   with `beta = 0.25`.

The exact planner is recomputed once per `(prior, beta, preference setting)` and
then executed on matched episodes. It never sees the hidden fault or unused
potential observations.

## Episode generator and seeds

Use the Park-Miller minimal-standard generator, entirely in exact positive
31-bit integers:

```text
state_0 in 1..2147483646
state_(n+1) = (48271 * state_n) mod 2147483647
u_n = state_n / 2147483647.0
```

The multiplication stays within Gene's exact fixnum range. For batch `b` in
`0..9`, the base-prior episode seed is `1000003 + 7919*b`; the shifted-prior
seed is `1104732 + 7919*b`. The random arm uses disjoint seeds
`2000003 + 7919*b` and `2104732 + 7919*b`. A generator consumes exactly three
episode draws in this order: hidden fault, voltage outcome, continuity outcome.
Categorical selection uses half-open cumulative intervals and treats an exact
upper endpoint as belonging to the next interval.

Generate 100 episodes per seed, giving ten fixed matched batches and 1,000
episodes for each prior. Reuse the same episode nodes for every deterministic
arm and every beta/preference replay. Generator source, generated episode
files, and their canonical Gene serialization hashes are frozen before any arm
is executed.

## Metrics and analysis

Primary comparison: information-seeking versus reward-only lookahead under the
base prior.

- Primary metric: incorrect-repair rate over all episodes. `defer` is not an
  incorrect repair; it is captured by completion.
- Constraint: completion rate, the fraction ending in any repair.
- Cost metrics: mean inspections, mean normalized utility, planner wall time,
  evaluator wall time, and peak resident memory.

For each of the ten matched batches, compute the reward-only minus
information-seeking incorrect-repair rate and the information-seeking minus
reward-only completion rate. Report their means and two-sided 95% Student-t
intervals over ten batch differences (`df = 9`, critical value `2.262`). Also
report the pooled relative incorrect-repair reduction:

```text
(reward_error_rate - information_error_rate) / reward_error_rate
```

The candidate passes only if all of these hold:

- pooled relative incorrect-repair reduction is at least 30%;
- the lower confidence bound for absolute incorrect-repair improvement is
  greater than zero;
- the lower confidence bound for completion difference is at least -0.02; and
- incorrect-repair improvement has the same positive direction under the
  shifted prior, every declared beta, and every preference sensitivity replay.

Preference sensitivity varies each of the four nonzero utility/cost fields one
at a time by `-10%` and `+10%`, for eight predeclared replays. These and the beta
replays are diagnostics; the primary `beta = 0.25` result is never replaced.
The frozen base-prior consumer emits the primary result, reuses it as the
`beta = 0.25` replay, evaluates `beta = 0.10` and `0.50`, and evaluates all
eight preference replays. The shifted-prior consumer emits only its required
primary robustness result. Every raw output contains an authoritative canonical
Gene record plus a strict JSON projection used by the frozen analysis.

The 1,000-episode size is conservative for the candidate's 30% relative-effect
threshold at the subject's analytically derivable reward-only error rate. The
ten batches, rather than 1,000 nominally independent rows, are the uncertainty
units so seed-specific variation remains visible.

## Exclusions, failures, and stopping

- No generated episode is excluded.
- A structural-gate, generator, serialization, planner, or evaluator failure
  aborts the run and produces no treatment claim.
- A policy tie uses the declared first-maximum rule; it is not randomized or
  excluded.
- There is no efficacy early stopping. The compute pilot uses disjoint seeds
  and may change only resource ceilings or implementation efficiency, not the
  subject, arms, metrics, or pass rule.
- A sensitivity reversal rejects the robustness clause even if the primary
  comparison passes.

## Resource pilot and freeze procedure

The debug-build mechanism smoke, including a malformed-likelihood rejection,
completed in 0.89 seconds with 12,189,696 bytes maximum resident set size on
the 2026-08-09 development machine. The disjoint 100-episode compute pilot used
episode seed `3000001` and random-arm seed `4000001`; it completed in 0.21
seconds with 12,648,448 bytes maximum resident set size and produced the pinned
final states `264756247` and `2017023388`.
Candidate ceilings are 2 seconds and 64 MiB for either readiness check, and 30
seconds and 128 MiB for each isolated frozen-batch evaluation process. The
runner also records total evaluator wall time and maximum observed RSS.

`EvalBudget` currently enforces `max_steps` only for code compiled inside its
`eval` unit; memory and timeout policy fields are rejected, and calling a
precompiled planner closure from a budgeted unit does not bound the closure's
body. This experiment executes no generated code, so the planner/evaluator is
bounded by an outer process timeout and memory measurement. Do not claim an
in-process memory or timeout limit that the runtime does not implement.

After independent review, record in a separate freeze manifest:

- UTC date and protocol version;
- Git revision and compiler/runtime revision;
- SHA-256 of this protocol, subject/planner, generator, evaluator, and canonical
  episode files;
- exact commands, platform, and resource ceilings; and
- reviewer identity and confirmation that no evaluation output was opened.

The implemented freeze procedure is
[`archive/tools/prepare_active_inference_freeze.py`](../../../../archive/tools/prepare_active_inference_freeze.py).
It hashes this protocol and every subject, planner, generator, evaluator,
exporter, smoke, pilot, and freeze-procedure source. The candidate digest also
binds the Git revision, Gene executable hash, declared seeds, commands,
platform, and resource ceilings. `packet` refuses a dirty worktree unless the
caller explicitly requests a development-only inspection; `freeze` has no such
override. Packet, attestation, and freeze paths are kept outside the worktree so
creating review evidence cannot silently change the candidate it describes.

The reviewer supplies only approval plus free-form notes. `attest` verifies the
reviewed packet against the current candidate and writes a schema-2 record with
exactly these fields:

```json
{
  "schema": 2,
  "experiment": "active_inference_v1",
  "candidate_digest": "the digest printed by packet",
  "reviewer_id": "Git user.name and user.email, recorded automatically",
  "reviewed_at_utc": "automatic ISO-8601 UTC timestamp",
  "approved": true,
  "notes": "review disposition and any non-blocking observations"
}
```

Approval means the reviewer attests independent review and confirms that no
evaluation output was opened; separate checkbox fields are not required. The
repository validates schema and digest binding but cannot self-certify reviewer
independence. Once review is complete, the commands are:

```bash
python3 archive/tools/prepare_active_inference_freeze.py packet \
  --output REVIEW_DIR/review_packet.json
python3 archive/tools/prepare_active_inference_freeze.py attest \
  --packet REVIEW_DIR/review_packet.json \
  --approve --notes "REVIEW_NOTES" \
  --output REVIEW_DIR/review_attestation.json
python3 archive/tools/prepare_active_inference_freeze.py freeze \
  --attestation REVIEW_DIR/review_attestation.json \
  --output-dir FREEZE_DIR
python3 archive/tools/prepare_active_inference_freeze.py verify \
  --freeze-dir FREEZE_DIR
```

The exporter writes potential observations and random-arm draws as canonical
Gene data, but neither it nor the freeze tool executes an evaluation arm or
computes a treatment metric. The freeze manifest explicitly records zero
evaluated batches and zero treatment arms. Its development self-test exports
only a disjoint pilot seed and passes that file through the capability-gated
frozen consumer. The consumer reads the exact frozen file rather than
regenerating its stream.

Only after a legitimate freeze may the treatment runner execute:

```bash
python3 archive/tools/run_active_inference_evaluation.py run \
  --freeze-dir FREEZE_DIR --output-dir RESULT_DIR
python3 archive/tools/run_active_inference_evaluation.py verify \
  --freeze-dir FREEZE_DIR --result-dir RESULT_DIR
```

`run` refuses a dirty candidate or existing/in-tree result directory, verifies
the complete freeze against current source, evaluates each manifest-selected
batch once, hashes every canonical raw result, records time and RSS, and writes
the fixed analysis atomically. `verify` rechecks the freeze and result hashes
and recomputes every pass gate from the raw JSON projections. The runner
self-test uses only excluded pilot seeds plus synthetic known-answer counts; it
exercises passing and robustness-reversal analysis and rejects a one-byte raw
result mutation.

The original 2026-08-09 freeze-tool self-test took 1.90 seconds and 29,540,352
bytes maximum resident set size. After adding all preregistered sensitivity
replays, the 2026-08-11 optimized-build freeze and runner self-tests each took
about four wall-clock seconds on excluded pilot data. These are development
observations, not measurements of the unopened evaluation.

Any content change after that manifest creates a new experiment version. The
estimated implementation and review effort remains 2–4 person-weeks with
roughly `2x` uncertainty; the finite local run itself is expected to be cheap.
