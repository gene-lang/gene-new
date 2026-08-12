# Gene as an agent's sole action surface

Status: direction, not a committed design (2026-08-11)

Give an LLM agent one way to act — emit a Gene program, executed by the
interpreter under an explicit capability grant — and delete the tool-call
surface entirely.

This depends on `capabilities.md` and changes no part of that model. It is
separate because it is a different bet with a different risk profile: the
capability model stands on its own merits, while this proposal is a claim
about how agents should act that the capability model happens to enable.

### The idea

An LLM agent today acts through *tool calls*: a name and typed arguments,
matched against a schema. The proposal here is to delete that surface
entirely and give the agent one way to act — **emit a Gene program, executed
by the interpreter under an explicit capability grant.**

The immediate win is composition. A tool call is a single invocation;
composing several means round-tripping through the model's context (call,
read result, reason, call again). A program expresses control flow,
iteration, composition, and error handling in one emission, so a multi-step
action costs one turn instead of N.

That argument is not specific to Gene — it is the general "code as action"
case, and it applies to a Python sandbox equally. What is specific to Gene
is the *second* half.

### Why capabilities are the load-bearing part

The reason code-as-action is not already the default is authorization
granularity. A tool call is narrow and inspectable: a human or policy engine
can approve `read_file("/etc/hosts")` on its own terms. Arbitrary code is
not reviewable that way, and a coarse sandbox grant ("you may touch the
filesystem") authorizes far more than any individual tool call would. Moving
to programs therefore trades *per-action* authorization for *per-session*
authorization, which is a real loss of control, not a detail of
implementation.

This proposal narrows that gap, within limits that must be stated. `capabilities.md` §11's
`(capabilities_of f)` returns canonical selectors; `capabilities.md` §12 can reject "a call
whose statically known context cannot satisfy a mandatory selector". Together
they support a **pre-execution verifier**: given a candidate program and a
grant, decide whether the program can exercise authority beyond the grant.

**Complete capability enumeration is not available for arbitrary Gene
programs.** `capabilities.md` §12 already concedes that dynamic dispatch, plugins, host policy
and runtime values require runtime checks; add higher-order calls, `eval`,
fexprs, dynamic imports, native extensions, and open protocol
implementations, and static enumeration is undecidable in the general case.
`capabilities.md` §5.0 compounds this: an undeclared function is effect-polymorphic, so its
requirement must be *inferred* transitively rather than read off.

The verifier is therefore sound only on a restricted subset, and its
rejection policy is part of its definition:

- closed-world imports, resolved before verification;
- no `eval`, no dynamic module loading, no native library loading;
- every call target statically resolvable, so every reachable callable has a
  computed capability summary;
- open-protocol dispatch permitted only where the implementation set is
  frozen;
- **anything unresolved is rejected, not assumed capability-free.**

Within that subset the claim holds and is stronger than a tool-call schema,
because a schema constrains the shape of one request while a capability bound
constrains everything the program can reach. Outside it, the honest position
is that the runtime boundary is the enforcement and the verifier is a filter
that refuses to certify what it cannot analyze.

This also depends on `capabilities.md` §5.0's omitted-declaration semantics and on `capabilities.md` §10.1
keeping authority out of values; if proofs became first-class, the verifier
would have to track authority through data flow, not just call structure.

Parameter-dependent selectors matter here more than anywhere else in this
document. `fs/WriteFile` narrowed by an argument is what lets a grant say
"this program may write exactly the file it was given", which is the
tool-call guarantee recovered inside a program.

### What this direction does *not* require

Worth stating plainly, because it was initially conflated with adjacent work:

- **It does not require the reversible native program format**, nor any
  model trained on it. The agent emits ordinary `.gene` *text*. See
  `reversible-ai-native-program-format.md` §"Model-training track status".
- **It does not require training a model at all.** Current frontier models
  write valid, non-trivial Gene by generalizing from other Lisps and reading
  the reference; a curated skill closes most of the remaining gap. A
  fine-tuned small model is strictly worse for this purpose, since it trades
  away the general reasoning that makes an agent useful.
- **It is available now**, ahead of the rest of this proposal, in a reduced
  form: run untrusted programs under a coarse grant, with the verifier added
  as the enforcement layer once `capabilities.md` §12 lands.

### Open problems

These are the reasons "completely replace tool calls" is a goal rather than
a conclusion:

- **Partial execution.** A malformed tool call is rejected whole. A program
  can fail halfway with some effects already applied. Capability bounds
  limit *what* can happen, not *how much of it* happened before the failure.
  Transactional or compensating semantics are an open question.
- **Adaptation.** Tool calls let a model observe a result and change course.
  A program is fire-and-forget unless it can suspend and resume. Gene's
  tasks, channels, and actors make this expressible; the interface an agent
  should see is undesigned.
- **Reviewability.** A capability bound is machine-checkable but not
  human-legible. A person approving an action wants to know what it will do,
  not only what it may reach. Rendering a verified program's intended effects
  back into something reviewable is unsolved.
- **Model competence.** Models are meaningfully weaker at Gene than at
  Python, and pretraining exposure makes that gap durable. The direction pays
  only if verified capability-bounded execution is worth more than that
  competence costs. It probably is — it is a safety property unobtainable
  from a Python sandbox at any model scale — but this is the assumption the
  whole direction rests on and should be stated before building, not after.

### What would make this concrete

In rough dependency order:

1. `capabilities.md` §12 static checking, specifically capability enumeration over a whole
   program rather than a single call boundary.
2. A host entry that accepts a program plus a grant and refuses to execute
   when enumeration exceeds the grant.
3. A capability-free verdict on a known-pure corpus as the verifier's first
   test: `training/corpus/generated/` holds 1002 programs that are pure
   computation by construction, so every one should enumerate to the empty
   set. Anything else is a verifier bug or a genuine surprise.
4. A Gene skill, so the model's output is good enough that verification
   failures are about authority rather than syntax.
