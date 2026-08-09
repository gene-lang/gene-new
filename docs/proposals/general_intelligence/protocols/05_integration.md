# Draft protocol: scoped architecture integration

Status: not frozen and not implementation-ready. See [`README.md`](README.md).

## Subject still to specify

Define the independent mixed-task generator and verifier. Every task must
require both a previously learnable operation and a declared inspect-vs-act
decision with a small enumerable hidden state, observations,
action-conditioned likelihoods, transitions, preferences, and horizon.

Open validity question: freeze structural non-triviality bounds so neither the
skill nor planning component wins by generator construction. In particular,
the information action must be useful without being decisive/free, and the
reusable operation must be necessary without reproducing a training task.

## Candidate 2-by-2 ablation

Run after experiments 1, 2, and 4 with their libraries, verifier, model, and
planning interface frozen:

| Arm | Durable verified skills | Belief-aware planner |
|---|---:|---:|
| plain agent | no | no |
| skill only | yes | no |
| planner only | no | yes |
| composed | yes | yes |

The planner owns only each declared enumerable decision; the base agent owns
all other tool choices. The generator supplies the bounded generative submodel,
while experiment 2 supplies belief update and policy scoring. Arms without the
planner choose directly from the same inspect/act actions.

All arms use the same immutable model, tools, observations, actions, and total
model/tool/wall-time budget. Charge library construction, promotion,
verification, retrieval, and planning to the applicable arms; controls may use
the corresponding budget for additional attempts.

## Candidate evaluation design

The current design uses 400 independently generated mixed tasks across eight
seeds, or 1,600 arm-task episodes. The candidate primary comparison is verified
held-out success of the composed system versus the plain agent, with the two
single-module arms as mandatory ablations. Cost per verified success and the
skill/planner interaction are diagnostics.

Candidate pass rule: at least a 10-percentage-point composed-system advantage
with an interval excluding zero. Keep a component only if removing it reduces
success by at least five points; otherwise simplify to the smaller passing
system.

If the composed system misses the primary comparison or its own overhead
consumes the gain, return to the plain LLM tool agent. The result is scoped to
structured mixed-tool domains with declared enumerable belief subproblems; it
does not establish general planning.

If experiment 3 later supplies a learned planner, use a new independently
frozen integration protocol and expanded domain. It cannot inherit this result.

Planning estimate: 4–8 person-weeks after experiments 1, 2, and 4 are frozen,
with roughly `2x` uncertainty.
