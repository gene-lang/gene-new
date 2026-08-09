# General-intelligence experiment protocols

These files hold implementation and evaluation details for the experiments
motivated by [`../architecture.md`](../architecture.md). None of the treatment
comparisons is frozen or ready to run. Experiment 2 has an executable mechanism
and compute pilot; experiment 1 has a bounded exact interpreter, deterministic
screened corpus generator, full-size corpus and control pilots, and a complete
candidate review/freeze/evaluate toolchain whose treatment gate still awaits an
independent attestation; experiment 4 has a qualified local model plus a bounded
verifier pilot, while its first exact-list task subject is rejected after
failing the preregistered frontier gate. Its demonstration-defined replacement
also failed after the qualified model exhausted its generation budget without a
tool call at both preregistered arities. A third interaction design has not been
qualified or independently reviewed.
Those readiness artifacts do not pre-register any treatment comparison.
Candidate thresholds and sample sizes migrated here preserve design work
without making the architecture note an experimental manual.

Before an experiment begins, its protocol must specify the complete subject,
generator or environment, algorithm, controls, evaluator, resource limits,
analysis, exclusions, seeds, software revisions, and costs. Freeze the
environment and structural validity checks before comparing arms. Then freeze a
dated protocol, implementation revision, generator, and verifier by content hash
before generating or opening evaluation data. Pilots use disjoint data and may
not tune the primary treatment effect.

## Drafts

- [`01_library_induction.md`](01_library_induction.md)
- [`02_active_inference.md`](02_active_inference.md)
- [`03_symbolic_world_model.md`](03_symbolic_world_model.md)
- [`04_lifelong_skill_agent.md`](04_lifelong_skill_agent.md)
- [`05_integration.md`](05_integration.md)

## Cross-cutting open questions

- Which candidate thresholds survive power analysis and the frozen subject
  design?
- Which mechanism and compute pilots are sufficient without leaking evaluation
  information?
- Which experiments execute generated code inside `eval` and therefore can use
  its implemented `max_steps` budget? `max_memory_mb` and `timeout_ms` are not
  implemented, and a budgeted unit does not bound a precompiled closure it
  calls; protocols must use outer process limits rather than claim otherwise.
- Which deployment boundary can keep experiment 4's tests, state, and promotion
  channel outside the qualified agent's capabilities while retaining exact
  auditable receipts?
- What staffing and hardware are actually available? Current effort estimates
  have roughly `2x` uncertainty.

The protocol files, once frozen, are authoritative for experiment execution.
The architecture note remains authoritative only for the hypotheses, component
boundaries, scoped integration claim, and sequencing rationale.
