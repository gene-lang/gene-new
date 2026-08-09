# Experimentally grounded directions for a Gene learning agent

Research note, revised 2026-08-09. This is an architecture shortlist, not a
claim that any listed system is AGI.

## Conclusion

There is no established single mechanism for general intelligence. The former
`examples/vsa` experiment clarified what associative representation can and
cannot provide, and was removed from this repository in `96fa200`. It is
historical evidence, not a dependency of this plan. Retrieval technology should
be selected later against measured library size, precision, latency, and
abstention requirements.

The missing mechanism is a loop that makes an agent improve from consequences:
a learned proposal or prediction process, an objective, deliberate search,
independent evaluation, a curriculum, and retention across tasks.

The most promising Gene-specific hypothesis is a **hybrid learning
architecture**:

1. exact Gene nodes remain canonical state, actions, tasks, programs, and
   evidence;
2. an LLM or small learned model proposes programs, abstractions, or futures;
3. Gene executes and verifies proposals in a confined environment;
4. a planner chooses among predicted futures;
5. successful exact programs and failure records accumulate into a reusable
   library; and
6. independently generated holdout tasks measure transfer and forgetting.

Gene's strongest role is therefore the durable knowledge and verification
layer: homoiconic, executable, and inspectable. Approximate retrieval may later
serve as a replaceable index over exact skills, but it should not become part of
their semantics.

## What the main research families add

| Family | Contribution | Limitation | Gene fit |
|---|---|---|---|
| Predictive representations and world models | Learn features and dynamics by predicting observations or latent targets. ([I-JEPA](https://arxiv.org/abs/2301.08243), [DreamerV3](https://arxiv.org/abs/2301.04104)) | Prediction is not automatically causal; rollout error compounds. | Keep observations, actions, and evidence as Gene nodes; put numerical learning behind a narrow external interface. |
| Model-based RL and planning | Add objectives and explicit lookahead over learned dynamics. ([MuZero](https://arxiv.org/abs/1911.08265)) | Needs many transitions and a well-defined reward; learned state need not be interpretable. | Represent search state, actions, predictions, and proof traces exactly even when estimates are learned. |
| Program synthesis and neuro-symbolic induction | Produce executable hypotheses and reusable abstractions. ([DreamCoder](https://arxiv.org/abs/2006.08381)) | Search explodes without a bounded language and task distribution. | Strongest native match: Gene programs are already data, so candidates and learned libraries need no second symbolic representation. |
| Active inference | Makes belief, preference, and information-gathering explicit. ([Kaplan & Friston](https://pmc.ncbi.nlm.nih.gov/articles/PMC6060791/), [discrete-state synthesis](https://pmc.ncbi.nlm.nih.gov/articles/PMC7732703/)) | A normative framework whose result depends on its supplied model and priors. | Exact discrete belief updates provide a cheap test of belief-aware exploration before neural training. |
| Continual learning and open-endedness | Retain old capabilities and generate new challenges. ([EWC](https://doi.org/10.1073/PNAS.1611835114), [POET](https://arxiv.org/abs/1901.01753)) | Capacity remains finite; generated novelty can become trivial or evaluator-driven. | Exact skills plus replay tests can reduce forgetting; generated tasks still need independent validity gates. |
| LLM tool agents with memory | Combine reasoning, action, reflection, curricula, and skill libraries. ([ReAct](https://arxiv.org/abs/2210.03629), [Reflexion](https://arxiv.org/abs/2303.11366), [Voyager](https://arxiv.org/abs/2305.16291)) | Fluent reflection is not learning evidence, and self-verification is not independent. | [`examples/ai_agent`](../../../examples/ai_agent/README.md) already supplies much of the loop; its missing architectural component is an independent promotion verifier. |

## Research discipline and document boundary

No experiment below is implementation-ready. This note owns the hypotheses,
component boundaries, falsifiers, scoped integration claim, and sequencing. The
linked [draft protocols](protocols/README.md) own candidate environments,
algorithms, controls, thresholds, sample sizes, statistics, pilots, costs, and
open validity questions.

Before evaluation, each protocol must be completed, dated, content-hashed, and
frozen with its generator, evaluator or verifier, and implementation revision.
Freeze the environment and its structural validity checks before comparing
arms; do not use pilot or evaluation outcomes to tune the treatment effect. A
changed protocol starts a new experiment.

## Four falsifiable experiments

### 1. Gene library induction

**Hypothesis.** Reusable abstractions induced from solved Gene programs improve
search on novel compositions because their content captures transferable
structure, not merely because the library is larger.

**Mechanism.** In a bounded Gene DSL, enumerate or propose candidate programs,
accept them only through exact execution, extract recurring subtrees into named
functions, and use those functions in later search. Compare the induced library
with a fixed library, a proposer without learning, and an unrelated learned
library matched on size and search shape. Renamed task surfaces test whether
apparent reuse is only name memorization.

**Falsifier.** Reject this form of induction if the learned library does not
improve held-out composition over the matched unrelated library, if gains vanish
under renaming, if exact tests invalidate solutions, or if abstraction growth
adds description without reusable behavior.

Protocol: [`protocols/01_library_induction.md`](protocols/01_library_induction.md)

### 2. Exact-belief active-inference micro-agent

**Hypothesis.** Explicitly valuing information can reduce premature harmful
actions relative to reward-only lookahead when hidden state matters.

**Mechanism.** Build a small repair domain with hidden faults, noisy inspection,
costly actions, exact Gene belief nodes, and completely enumerable short
policies. Compare greedy action, reward-only lookahead, random exploration, and
a policy score that combines utility with expected information gain.

**Falsifier.** Reject this formulation if information-seeking does not reduce
incorrect repairs without sacrificing completion, if modest prior or preference
changes reverse the result, or if the intended policy space cannot be enumerated
exactly within a small local resource budget.

Protocol: [`protocols/02_active_inference.md`](protocols/02_active_inference.md)

### 3. Learned symbolic world model plus search

**Hypothesis.** Search over a learned action-conditioned symbolic model improves
held-out decisions beyond the same learned policy without search.

**Mechanism.** Keep authoritative world state and transitions as Gene nodes,
train a versioned external worker to predict next state, reward, termination,
policy, and value, then use MCTS over predicted futures. Retain the exact
simulator as an oracle and upper-bound planner; do not add a tensor stack to the
Gene runtime merely for this experiment.

**Falsifier.** Reject the mechanism if search provides no held-out advantage,
more search makes outcomes worse, or model error compounds with horizon enough
to erase planning value.

Protocol: [`protocols/03_symbolic_world_model.md`](protocols/03_symbolic_world_model.md)

### 4. Verified lifelong skill agent

**Hypothesis.** A library of independently verified executable skills improves
transfer and retention beyond episodic text memory under matched total budgets.

**Mechanism.** Extend the existing agent with exact episode, lesson, and skill
records. Only an isolated verifier with hidden tests may promote a skill. Use a
reproducible local model, generate tasks near the capability frontier, probe old
families throughout learning, and keep retrieval replaceable rather than part of
skill semantics.

**Falsifier.** Reject the skill-layer design if promoted skills do not improve
unseen task compositions, if old capabilities or hidden replay degrade, if the
curriculum stops producing meaningful progress, or if verification and
retrieval overhead consume the benefit. Model-authored success without the
external verifier remains unknown.

Protocol: [`protocols/04_lifelong_skill_agent.md`](protocols/04_lifelong_skill_agent.md)

## Scoped integration test

Component successes do not establish that the hybrid is worth its overhead.
After experiments 1, 2, and 4, run an independently generated 2-by-2 ablation:

| Arm | Durable verified skills | Belief-aware planner |
|---|---:|---:|
| plain agent | no | no |
| skill only | yes | no |
| planner only | no | yes |
| composed | yes | yes |

The planner axis is deliberately narrower than general planning over open-ended
tool work. Each mixed task contains a declared inspect-vs-act subproblem with a
small enumerable hidden state and supplied generative model. Experiment 2
provides the belief/planning interface; the base agent owns all other tool
choices. Each task also requires reuse of a previously learnable operation.

All arms receive the same model, tools, observations, actions, and total budget.
The accounting includes library construction, promotion, verification,
retrieval, and planning, so infrastructure cost cannot disappear from the
comparison. The composed system must beat the plain agent, and removing either
module must cause a meaningful loss; otherwise simplify to the smaller passing
system or return to the plain LLM tool agent.

Any positive claim is limited to structured mixed-tool domains with declared
enumerable belief subproblems. If experiment 3 later supplies a learned planner,
it must pass a new independently frozen integration test on an expanded domain
before the claim broadens.

Protocol: [`protocols/05_integration.md`](protocols/05_integration.md)

## Recommended order

Experiment 2's candidate repair domain is now specified and its mechanism smoke
verifies exact enumeration; its disjoint-seed compute pilot also passes. Its
protocol still needs independent review and a content-hash freeze before
evaluation. Experiment 1 now has a closed 12-primitive interpreter and a
positive-MDL one-round induction smoke: the induced abstraction solves a
constructed transfer task that the primitive-only search cannot reach at the
same candidate ceiling. Its generated corpus, iterative stopping rule, and
matched donor-library procedure still need to be frozen before treatment work.
Experiment 4's local-model gate passed on 2026-08-09: the selected
`gpt-oss:20b` artifact accepted all 20 exact mock-tool tasks under the recorded
resource envelope. The immutable qualification report is
[`qualifications/gpt-oss-20b-2026-08-09.json`](qualifications/gpt-oss-20b-2026-08-09.json).
The next product-first readiness task is therefore the independent promotion
verifier and exact skill records. Its first mechanism pilot now promotes and
rejects bounded toy skills in a separate process with hash-linked exact
receipts, but deliberately does not claim hidden-test secrecy or authenticated
transport. The qualified local model also completes the proposal-to-verifier
path in one tool round after the model-facing program was reduced to a flat
string-array schema; two more structured adapter shapes are retained as failed
evidence. The next verifier step is a verifier-owned service or isolated process
whose tests and promotion channel are outside agent capabilities; no
mechanism-pilot task or skill may contribute to the later experiment.
Experiment 1 additionally needs its DSL, search, abstraction, and scoring
design frozen before implementation.

**Default research order — fastest trustworthy signal:**

1. **Experiment 2:** cheapest exact test of the belief/planning interface.
2. **Experiment 1:** strongest Gene-native test of abstraction and reuse.
3. **Experiment 4:** product-facing transfer test after model qualification and
   independent verification exist.
4. **Experiment 3:** separate numerical-training workstream, attempted only
   after simpler systems establish baselines it must beat.
5. **Scoped integration:** accept the composition only if its modules survive
   ablation under a budget that includes their own overhead.

Experiments 1 and 4 test the same durable-skill idea at different levels. If 1
fails and 4 succeeds, attribute the gain to the LLM proposer, caching, or tool
scaffolding rather than abstraction induction. If 1 succeeds and 4 fails,
induction works in a controlled DSL but not open-ended tool work. If both pass,
that supports the durable-induction hypothesis; if both fail, reject this
skill-layer design. A failure of 1 pauses the expensive skill portion of 4 until
its induction mechanism changes.

**Product-first order — direct leverage, not a short project:** qualify the
local model, then build experiment 4's verifier and skill loop, followed by 1,
2, and 3. Hosted-model dogfooding is useful product evidence but not the strict
reproducible experiment.

The architecture worth testing is **exact symbolic knowledge + learned
proposal/prediction + deliberate search + independent verification + continual
skill accumulation**. Its initial planning claim is limited to declared,
enumerable belief subproblems. Every module earns its place only through the
linked frozen protocol and the final ablation.
