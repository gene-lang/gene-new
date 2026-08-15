# safe_ai_agent — Gene as an agent's sole action surface

An LLM agent with one way to act: emit a Gene program, executed by the
interpreter under an explicit capability grant. There is no tool-call surface.

This example exists to make one argument concrete — that the *capability
ceiling*, not a convention and not a prompt, is what stops generated code from
writing files. Everything below is either that argument or something building
it taught us.

It depends on `docs/proposals/capabilities.md` and changes no part of that
model.

## Running it

```bash
nimble build                     # produces bin/gene
cd examples/safe_ai_agent
GENE_AGENT_STUB=1 ../../bin/gene run src/main.gene
```

`GENE_AGENT_STUB=1` returns canned replies, so the example runs and is testable
with no API key. Four prompts show the four things worth seeing:

| prompt | what the model emits | outcome |
| --- | --- | --- |
| `write a file` | `($fs/write_text "scratch.txt" …)` | refused — needs `fs/WriteFile` |
| `read the notes` | `(list_notes)`, `(read_note "notes.txt")` | both succeed |
| `escape the sandbox` | `(read_note "../package.gene")` | refused at the declaration |
| anything else | `(+ 1 2)` | `3` — no authority needed |

The whole session, end to end:

```
> write a file
   Saving that to the workspace.
   refused: fs/write_text requires fs/WriteFile
> read the notes
   Reading the workspace.
   ["notes.txt"]
   hello from the workspace
> escape the sandbox
   Peeking outside the workspace.
   refused: capability declaration needs fs/ReadFile
> say hi
   No tools needed for that.
   3
> /quit
```

Live mode uses OpenRouter, with the key in `OPENAI_AUTH_TOKEN` and the model
overridable via `GENE_AGENT_MODEL`. A stale shell `OPENAI_API_KEY` export beats
`OPENAI_AUTH_TOKEN` and yields 401 — set `OPENAI_AUTH_TOKEN`.

## The shape

The model is asked to reply with Gene data and nothing else:

```gene
{^status "done"|"in-progress" ^code [form1 form2 ...] ^response "..."}
```

`^code` holds forms to evaluate; `^status "in-progress"` means the model wants
to see their results before continuing, so the loop feeds the rendered results
back as history and asks again (bounded at six turns). This envelope is a demo
shape, not a commitment — it is the smallest thing that exercises emit,
evaluate, observe, retry.

The immediate win over tool calls is composition. A tool call is a single
invocation; composing several means round-tripping through the model's context
(call, read result, reason, call again). A program expresses control flow,
iteration, composition, and error handling in one emission, so a multi-step
action costs one turn instead of N.

That argument is not specific to Gene — it is the general "code as action" case,
and it applies to a Python sandbox equally. What is specific to Gene is the
second half.

## Why capabilities are the load-bearing part

The reason code-as-action is not already the default is authorization
granularity. A tool call is narrow and inspectable: a human or policy engine can
approve `read_file("/etc/hosts")` on its own terms. Arbitrary code is not
reviewable that way, and a coarse sandbox grant ("you may touch the filesystem")
authorizes far more than any individual tool call would. Moving to programs
therefore trades *per-action* authorization for *per-session* authorization,
which is a real loss of control, not a detail of implementation.

Capabilities narrow that gap, within limits that must be stated.
`capabilities.md` §11's `(capabilities_of f)` returns canonical selectors; §12
can reject "a call whose statically known context cannot satisfy a mandatory
selector". Together they support a **pre-execution verifier**: given a candidate
program and a grant, decide whether the program can exercise authority beyond
the grant.

**Complete capability enumeration is not available for arbitrary Gene
programs.** §12 already concedes that dynamic dispatch, plugins, host policy and
runtime values require runtime checks; add higher-order calls, `eval`, fexprs,
dynamic imports, native extensions, and open protocol implementations, and
static enumeration is undecidable in the general case. §5.0 compounds this: an
undeclared function is effect-polymorphic, so its requirement must be *inferred*
transitively rather than read off.

A verifier is therefore sound only on a restricted subset, and its rejection
policy is part of its definition:

- closed-world imports, resolved before verification;
- no `eval`, no dynamic module loading, no native library loading;
- every call target statically resolvable, so every reachable callable has a
  computed capability summary;
- open-protocol dispatch permitted only where the implementation set is frozen;
- **anything unresolved is rejected, not assumed capability-free.**

Within that subset the claim holds and is stronger than a tool-call schema,
because a schema constrains the shape of one request while a capability bound
constrains everything the program can reach. Outside it, the honest position is
that the runtime boundary is the enforcement and the verifier is a filter that
refuses to certify what it cannot analyze.

Note the tension this example sits inside: **this agent is squarely outside that
subset**, because evaluating model-emitted forms *is* `eval`. It is the reduced
form §"What this direction does not require" describes — runtime enforcement
now, verifier later. Nothing here is statically certified.

This also depends on §5.0's omitted-declaration semantics and on §10.1 keeping
authority out of values; if proofs became first-class, a verifier would have to
track authority through data flow, not just call structure.

Parameter-dependent selectors matter here more than anywhere else.
`fs/WriteFile` narrowed by an argument is what lets a grant say "this program
may write exactly the file it was given", which is the tool-call guarantee
recovered inside a program. `read_note` in this example is precisely that, and
§"What the example enforces" shows it holding.

## What the example enforces

Three layers, in the order they stop things.

**1. The module ceiling.** `src/main.gene` declares:

```gene
(mod safe_ai_agent
  ^capabilities [net/* os/Env (fs/ReadDir "workspace")])
```

The agent may talk to the model, read its API key, and read `workspace/`. It
holds no write authority anywhere, so no bug in the loop below can write a file
— not because the loop is careful, but because the authority is absent.

This row also re-roots the module's filesystem authority: inside it, a relative
path resolves against `workspace/`, not the launch directory. That is why the
tool rows say `"."` and generated code says `"notes.txt"`. It is the single most
surprising rule in the capability system (`capabilities.md` §7.5), and it is the
same rule `examples/capabilities/README.md` calls rule 2.

**2. Model-emitted code holds nothing.** Forms are evaluated with:

```gene
(eval form ^in (env ^module this_mod ^capabilities (agent_tools)))
```

Evaluated code gets **no ambient authority at all**. A raw `($fs/read_text …)`
in generated code is refused even though the enclosing module *does* hold read
authority over `workspace/`. Pure computation is all that works by default.

Despite its name, `env ^capabilities` is not an authority row — the runtime
requires a **map** and installs it as a *binding overlay*, deciding which names
the evaluated code can see. It is the object-capability half of the design: the
agent hands over specific callables rather than widening a context. (This is a
divergence from the spec; see Open problems.)

**3. Each handed tool carries its own row.** The overlay supplies two names:

```gene
(fn list_notes [] : Any
  ^capabilities [(fs/ReadDir ".")]
  ($fs/list_dir "."))

(fn read_note [name : Str] : Str
  ^capabilities [(fs/ReadFile name)]
  ($fs/read_text name))
```

`read_note` forwards its argument to the filesystem without inspecting it, and
still cannot be walked out of `workspace/`. `(fs/ReadFile name)` is a
parameter-dependent row, so the check resolves `name` against the module root
and refuses `../package.gene` *at the declaration*, before the body runs. The
refusal reads `capability declaration needs fs/ReadFile`.

That is the property worth dwelling on: **the tool is not written defensively
and does not need to be.** There is no path validation in `read_note`. A
reviewer checking whether this agent can read `/etc/passwd` reads one row, not
the body, and not every caller of the body.

Two further observations from building it:

- `with_capabilities []` around the `eval` revokes even the handed tools — the
  tools' authority is `ambient ∩ declared`, so emptying the ambient context
  empties them. There is a working "revoke everything" lever.
- Evaluated code can locally shadow a tool name (`(var read_note 1)`). This
  costs it access and grants it nothing; binding overlays are not authority.

**A denial is a value, not a crash.** `render_form` catches the refusal and
renders it into the results, so the model sees `refused: …` in the next turn's
history and can try something else. An agent that dies on its first denial
cannot adapt, and adaptation is most of what makes the loop worth running.

## What this direction does not require

Worth stating plainly, because it was initially conflated with adjacent work:

- **It does not require the reversible native program format**, nor any model
  trained on it. The agent emits ordinary `.gene` *text*. See
  `docs/proposals/reversible-ai-native-program-format.md`
  §"Model-training track status".
- **It does not require training a model at all.** Current frontier models write
  valid, non-trivial Gene by generalizing from other Lisps and reading the
  reference; a curated skill closes most of the remaining gap. A fine-tuned
  small model is strictly worse for this purpose, since it trades away the
  general reasoning that makes an agent useful.
- **It is available now**, ahead of the rest of the direction, in the reduced
  form this example demonstrates: run untrusted programs under a coarse grant,
  with a verifier added as the enforcement layer once `capabilities.md` §12
  lands.

## Open problems

These are the reasons "completely replace tool calls" is a goal rather than a
conclusion. The first two were found by building this example; the rest are
inherited from the original proposal.

- **`env ^capabilities` diverges from `capabilities.md` §14.** The spec says the
  value "must be a validated `CapabilityContext` or a selector list resolved
  against the creator's current context", and that evaluated code runs under
  "an explicit capability context no broader than the evaluator's active
  context", defaulting to **the intersection of those contexts**. The
  implementation instead requires a map, treats it as a lexical binding overlay,
  and gives evaluated code an **empty** ambient context. A selector list is
  rejected outright (`env ^capabilities must be a map`).

  The empty default is the safe direction to diverge in, and the overlay is a
  legitimate object-capability mechanism — this example is built on it — but the
  two are not the same feature, and there is currently no way to hand evaluated
  code a *narrowed ambient context*. Either the spec or the implementation
  should move.

- **Denials are inconsistently typed.** A denial raised at a declared row
  arrives as a typed `MissingCapability` carrying `^capability` and
  `^operation`, and destructures cleanly:

  ```gene
  catch (MissingCapability ^capability wanted ^operation operation)
  ```

  A denial raised by a raw native operation *inside* an evaluated form arrives
  untyped, with the capability name only in its message text, and must be caught
  by a bare `catch e`. Both are refusals and both are recoverable, but only one
  is machine-readable — so an agent that wants to reason about *which* authority
  it lacked cannot do so uniformly. `render_form` carries both arms for this
  reason.

- **Partial execution.** A malformed tool call is rejected whole. A program can
  fail halfway with some effects already applied. Capability bounds limit *what*
  can happen, not *how much of it* happened before the failure. Transactional or
  compensating semantics are an open question. This example dodges the problem
  by granting no write authority at all — there is nothing to half-apply.

- **Adaptation.** Tool calls let a model observe a result and change course. A
  program is fire-and-forget unless it can suspend and resume. The
  `^status "in-progress"` envelope here is the crudest possible answer: re-emit
  a whole new program with the previous results as history. Gene's tasks,
  channels, and actors make real suspension expressible; the interface an agent
  should see is undesigned.

- **Reviewability.** A capability bound is machine-checkable but not
  human-legible. A person approving an action wants to know what it will do, not
  only what it may reach. Rendering a verified program's intended effects back
  into something reviewable is unsolved.

- **Model competence.** Models are meaningfully weaker at Gene than at Python,
  and pretraining exposure makes that gap durable. The direction pays only if
  verified capability-bounded execution is worth more than that competence
  costs. It probably is — it is a safety property unobtainable from a Python
  sandbox at any model scale — but this is the assumption the whole direction
  rests on and should be stated before building, not after.

## What would make this concrete

In rough dependency order:

1. `capabilities.md` §12 static checking, specifically capability enumeration
   over a whole program rather than a single call boundary.
2. A host entry that accepts a program plus a grant and refuses to execute when
   enumeration exceeds the grant.
3. A capability-free verdict on a known-pure corpus as the verifier's first
   test: `training/corpus/generated/` holds 1002 programs that are pure
   computation by construction, so every one should enumerate to the empty set.
   Anything else is a verifier bug or a genuine surprise.
4. Reconciling `env ^capabilities` with §14, so that "evaluate this under a
   narrower ambient context" is expressible at all.
5. A Gene skill, so the model's output is good enough that verification failures
   are about authority rather than syntax.

## Where to read more

- `docs/proposals/capabilities.md` §5.0 (omitted declarations), §5.6 (call-site
  attenuation), §7.5 (path confinement), §11 (reflection), §12 (static
  checking), §14 (environments and evaluation).
- `examples/capabilities/README.md` — six smaller programs covering the
  capability model on its own, each showing a denial as well as a success.
