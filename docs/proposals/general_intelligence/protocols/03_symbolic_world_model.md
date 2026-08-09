# Draft protocol: learned symbolic world model plus search

Status: deferred, not frozen, and not implementation-ready. See
[`README.md`](README.md).

## Candidate mechanism

Create a bounded tool world whose authoritative state and transitions are Gene
nodes. Train an action-conditioned external model to predict next symbolic
state, termination, reward, policy, and value. Use MCTS over predicted futures;
retain the exact simulator as an oracle and upper-bound planner.

The numerical learner is a versioned local worker behind a narrow JSONL or
loopback-HTTP interface. Record its dependency lock, environment, checkpoint
hash, seeds, and transport version. Do not add a tensor dependency to the Gene
runtime unless later transport measurements justify a native adapter.

## Candidate evaluation design

Use procedurally generated worlds with held-out layouts and goals. Compare a
reactive policy or LLM, the learned policy without search, learned-model MCTS at
several search budgets, and MCTS with the exact simulator. All learned arms
receive the same transitions.

The current candidate design uses ten training seeds, 500 held-out worlds per
checkpoint, and learned-model search budgets of 16, 64, and 256 simulations.
The candidate primary comparison is 64-simulation learned-model search versus
the same learned policy without search. One-step exact-state accuracy,
reward/termination accuracy, performance by rollout depth, search-budget curves,
and distance to exact-model planning are diagnostics.

Candidate pass rule: at least a 15-percentage-point success advantage at 64
simulations, uncertainty intervals excluding zero at world and seed levels, and
no supported degradation beyond 64 simulations.

Reject the mechanism if search has no advantage, additional search worsens
results, or model error compounds enough with horizon to destroy planning
benefit. Do not hide rollout failure behind aggregate reward.

## Candidate cost and boundary

The current design implies ten training runs and at least 30,000 held-out
planner/world evaluations. One seed must first establish accelerator time,
checkpoint size, transport overhead, and projected total cost. Scheduling the
full experiment requires a separate compute decision.

Planning estimate: 3–6 person-months with roughly `2x` uncertainty. This is a
separate ML-training workstream, not a component to drop directly into the
current repository.
