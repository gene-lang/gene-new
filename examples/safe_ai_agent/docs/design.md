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

# with the Gene skill loaded
../../bin/gene run --allow_read_dir ../../tools/gene-lang-skill src/main.gene
```

`GENE_AGENT_STUB=1` returns canned replies, so the example runs and is testable
with no API key. Five prompts show the five things worth seeing:

| prompt | what the model emits | outcome |
| --- | --- | --- |
| `read the notes` | `($fs/list_dir ".")`, `($fs/read_text "notes.txt")` | both succeed |
| `write something` | `($fs/write_text "todo.txt" …)`, then reads it back | succeeds — the grant is real |
| `raw effect` | `($os/get_env "HOME")` | refused — needs `os/Env` |
| `escape the sandbox` | `($fs/read_text "../package.gene")` | refused |
| anything else | defines `xs`, sums it, returns `6` | a program, not a statement list |

The whole session, end to end:

```
> read the notes
   Reading the workspace.
   hello from the workspace
> write something
   Saving that to the workspace.
   buy milk
> raw effect
   Reading an environment variable.
   refused: os/get_env needs os/Env
> escape the sandbox
   Peeking outside the workspace.
   refused: fs/read_text needs fs/ReadFile
> say hi
   Defining and using in one program.
   6
> /quit
```

The third row is the one to look at twice. Generated code calls the ordinary
standard library, and the module *does* hold `os/Env` — it needs it to read the
API key. The call is still refused, because that authority is not in the row the
evaluated program was granted. What the module holds and what the model may use
are separate questions.

Live mode uses OpenRouter, with the key in `OPENAI_AUTH_TOKEN` and the model
overridable via `GENE_AGENT_MODEL`. A stale shell `OPENAI_API_KEY` export beats
`OPENAI_AUTH_TOKEN` and yields 401 — set `OPENAI_AUTH_TOKEN`.

## The shape

The model is asked to reply with Gene data and nothing else:

```gene
{^status "done"|"in-progress" ^code [form1 form2 ...] ^response "..."}
```

`^code` holds the forms of **one program**: they are spliced into a single
`(do …)` and evaluated together, so a form may use what an earlier form defined.
Evaluating them separately — which this example did originally — gives each form
a fresh environment and silently discards every binding, which makes "define a
function, then call it" impossible and is exactly the shape a model reaches for
first. The cost of the fix is that one bad form abandons the rest of the reply,
and only the last value comes back; generated code that wants to say more can
call `($println …)`.

`^status "in-progress"` means the model wants to see the result before
continuing, so the loop feeds the emitted program *and* its result back as
history and asks again (bounded at six turns). Feeding back results alone leaves
the model unable to tell which form drew which complaint. This envelope is a
demo shape, not a commitment — it is the smallest thing that exercises emit,
evaluate, observe, retry.

Bindings do not outlive a reply, so anything the model wants to keep goes into
the workspace with `($fs/write_text …)`. The filesystem is the agent's memory, and
`(run_note …)` lets it execute what it saved — a write/run/fix loop inside the
same sealed environment, adding no authority.

## Skills are a grant, not a setting

A skill is a directory of Markdown: `SKILL.md` is the entry page, and the files
it points at are read on demand. That shape is what makes it fit an agent whose
context is the scarce resource — the whole skill never has to sit in the prompt,
only the page that says what the rest holds.

Here the skill directory is a **second filesystem root**, read-only, alongside
the writable workspace:

```gene
(mod safe_ai_agent
  ^capabilities [net/* os/Env
                 (fs/ReadWriteDir "workspace")
                 (fs/ReadDir "../../tools/gene-lang-skill" ^^optional)])
```

It sits outside this package, and a module row may narrow within what the
launcher granted but never widen past it — so without `--allow_read_dir` the
row admits nothing. `^^optional` is what lets the agent start anyway:
`skills_available` goes false, `read_skill` says so, and the built-in primer
carries the load alone. **Which skills an agent has is therefore a property of
how it was launched, not of a config file it could rewrite.**

Two roots make a *relative* path ambiguous — `"notes.txt"` could name either
root, which is two different host targets, so the runtime refuses to guess
(`capabilities.md` §6.3). That is why only the writable root is ambient, and the
skill is reached through one narrowing reader:

```gene
(fn read_skill [name : Str] : Str
  (with_capabilities [(fs/ReadDir SKILL_ROOT)]
    (read_file_at name)))
```

The narrowing selector is written `../workspace`, not `workspace`: a selector
path resolves *inside* the active root, so the bare name would mean
`workspace/workspace`. The `../` form canonicalizes back onto the root itself
from any root that could be active, which is what makes it unambiguous. A `fn`
declaration row is stricter still — it admits only literals, parameters, or
`this`, so a `const` cannot appear there and the path is spelled out.

The narrowing confines *rights*, not just location. The skill root carries
`fs/ReadDir` only, so a write attempted under it is refused even though the
module holds write authority over the other root.

A live model with the skill loaded found `reference/pitfalls.md`, read it, and
answered a question about `//` being remainder rather than floor division — a
fact that appears nowhere in its prompt, only in the file it chose to open.

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
recovered inside a program. The workspace row in this example is precisely that,
and §"What the example enforces" shows it holding.

## What the example enforces

Three layers, in the order they stop things.

**1. The module ceiling.** `src/main.gene` declares:

```gene
(mod safe_ai_agent
  ^capabilities [net/* os/Env (fs/ReadWriteDir "workspace")])
```

The agent may talk to the model, read its API key, and read and write
`workspace/`. It holds no authority of any kind outside that directory, so no
bug in the loop below can touch a file elsewhere — not because the loop is
careful, but because the authority is absent.

This row also re-roots the module's filesystem authority: inside it, a relative
path resolves against `workspace/`, not the launch directory. That is why the
tool rows say `"."` and generated code says `"notes.txt"`. It is the single most
surprising rule in the capability system (`capabilities.md` §7.5), and it is the
same rule `examples/capabilities/README.md` calls rule 2.

**2. Model-emitted code holds exactly one directory.** The program is evaluated
with:

```gene
(env ^bindings (agent_tools)
     ^capabilities [(fs/ReadWriteDir WORKSPACE)])
```

`^capabilities` is the **ambient authority row** (`capabilities.md` §14): a
selector list, resolved against *this* module's context at the moment the Env is
minted, so it can never name more than the module already holds. `^bindings`
carries the name overlay. An Env with no row grants nothing at all, which stays
the default everywhere else in the runtime.

That is what lets generated code call the **ordinary standard library** —
`($fs/read_text "notes.txt")`, `($fs/write_text "todo.gene" src)` — instead of a
bespoke tool surface someone has to invent, document, and keep in sync. There is
no `read_note`. The confinement is the row, not the wrapper.

The boundary is still sharp. `($os/get_env "HOME")` from generated code is
refused with `os/get_env needs os/Env` even though the enclosing module holds
`os/Env` to reach the API key, because that authority is not in the row. So is
any path outside the workspace.

Note what is *absent* from that call: `^module`. Adding it would also publish
every module-level `fn` to the evaluated code, which is a privilege leak rather
than a convenience — see Open problems.

Only the writable root is ambient. Two ambient roots would make a relative name
like `"todo.gene"` mean two different host targets, which §6.3 rightly refuses
to resolve, so the read-only skill directory is reached through a single
narrowing reader instead.

**3. Paths are confined by the row, not by the caller.** The workspace root is
re-rooted, so `"todo.gene"` from generated code means `workspace/todo.gene`, and
`"../package.gene"` is refused rather than escaping. A live model asked to write
`../../ESCAPED.txt` gets a refusal with nothing written.

The property worth dwelling on is that **nothing here is written defensively**.
There is no path validation anywhere in this file — no prefix check, no
`realpath` comparison, no allow-list. A reviewer asking whether this agent can
read `/etc/passwd` reads one row and stops; they do not have to audit a tool
body, or every caller of it, or trust that a future edit keeps the check.

The one function still handed over by name is `run_note`, and it is not a
filesystem primitive — it evaluates a saved note through the same
`run_program`, in an Env minted with the same row, so it adds no authority. It
refuses to nest, because it is reachable *from* generated code and a note that
ran itself would recurse until the stack goes. Its own row keeps the whole
workspace rather than one file, because the Env it mints is resolved against
whatever context is active at that point; narrowing to a single file first would
leave nothing for the evaluated program to run under.

Two further observations from building it:

- `with_capabilities []` around the `eval` revokes everything — authority is
  `ambient ∩ declared`, so emptying the ambient context empties the row too.
  There is a working "revoke everything" lever.
- Evaluated code can locally shadow a handed name (`(var run_note 1)`). This
  costs it access and grants it nothing; binding overlays are not authority.

**A denial is a value, not a crash.** `run_program` catches the refusal and
renders it into the result, so the model sees `refused: …` in the next turn's
history and can try something else. An agent that dies on its first denial
cannot adapt, and adaptation is most of what makes the loop worth running.

**A refusal and a mistake are different words.** An earlier version rendered
every failure as `refused: …`, so `undefined symbol: def` was indistinguishable
from a capability denial. That is bad for the model, which cannot tell "you lack
authority, try another approach" from "you made a typo, fix it" — and worse for
this example, whose whole argument is that a denial is a distinct, legible
thing. Ordinary errors now render as `error: …`, and only denials say
`refused:`.

**Model competence is a real cost, and a primer is most of the remedy.** Asked
to write a todo app with no syntax guidance, a current model produced `(def …)`,
`todos.push(t)`, and chained sends with no `;` continuation — none of which are
Gene. `system_prompt` now carries a short primer, and every rule in it is one an
actual model got wrong on an actual turn. With it, and with `(run_note …)` to
execute what it saved, the same model wrote a working todo app, ran it, hit
`error: no message 'get' on List`, diagnosed it, and rewrote that function as a
stream transformation — a self-correcting loop that produced a file which parses
and runs standalone.

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

- **`env ^capabilities` now implements §14** (was an open problem; kept here
  because the shape is worth knowing). The spec says the value is "a validated
  `CapabilityContext` or a selector list resolved against the creator's current
  context". A **list** is now exactly that: the row is resolved when the Env is
  minted, against the creating context, so an Env can never carry more than its
  creator held, and evaluating it later under a wider context cannot widen it. A
  **map** keeps its older meaning as a lexical binding overlay — one decides
  which names exist, the other what they may do — and `^bindings` remains the
  plainer spelling for the former.

  The default did not move: an Env with no row grants evaluated code nothing,
  and that emptiness is now installed *explicitly* rather than inherited.
  Getting there also exposed a second bug worth stating, because it made the
  first one invisible: `eval` rooted its overlay in `currentApplication()`
  rather than the creating scope's application, and when those differ every
  grant reaching evaluated code is minted by one application's provider and
  checked against another's. `isOwnedBy` then fails and the authority silently
  evaporates. Nothing noticed while evaluated code held no authority at all.

- **`env ^module` is a hole, and the fix is to omit it.** An env built as
  `(env ^module this_mod ^capabilities tools)` resolves the overlay names *and
  every module-level `fn`*. Generated code could therefore call any function in
  this file — including ones never handed to it, which then run under the module
  ceiling rather than a tool row, so a helper with no declared row hands out the
  module's whole authority. It was reachable here: a probe module with an
  `os/Env` ceiling and a rowless `read_the_key` helper had that helper called
  successfully from evaluated code.

  Omitting `^module` closes it — evaluated code then sees the overlay plus the
  `$` stdlib and nothing else — and that is what `run_program` now does. It is
  listed as an open problem rather than a fixed bug because the safe
  construction is the non-obvious one: `^module` reads like "which module is
  this code part of", not "publish every binding in that module to it".

- **A bounded destructive tool is still a destructive tool.** Adding
  write authority gave the agent the power to remove anything in the workspace,
  and while testing, the word `clear` — typed at the running agent by mistake —
  was read as a task and deleted the workspace fixture. The capability model
  did exactly its job: the deletion could not have landed anywhere else. But
  *where* is the only question it answers, and "should this happen at all" is
  the Reviewability problem above, arriving in practice rather than in theory.
  An agent holding delete authority wants a confirmation step or a trash
  directory, and neither is a capability question.

- **Partial execution.** A malformed tool call is rejected whole. A program can
  fail halfway with some effects already applied. Capability bounds limit *what*
  can happen, not *how much of it* happened before the failure. Transactional or
  compensating semantics are an open question, and this example now has real
  exposure to it: writing is a granted effect, and a program that writes
  two notes and fails between them leaves the first one written. Evaluating
  `^code` as a single `do` makes this sharper, not softer — the abandoned
  remainder is larger.

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

  Measured here, the gap is narrower than it first looks but does not close on
  its own: a prompt primer plus the ability to run what it wrote took the same
  model from "emits `def` and `.push`" to a working, self-corrected program. The
  remaining errors were the shapes with no analogue in another language — the
  `; ~` chain continuation above all. That suggests the durable part of the gap
  is Gene's *distinctive* syntax rather than its unfamiliarity in general, which
  is the part a primer can address and pretraining cannot.

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
Two items that were on this list are done: `env ^capabilities` now implements
§14, so "evaluate this under a narrower ambient context" is expressible; and a
Gene skill is loadable, which moved the model's failures from syntax to
substance.

## Where to read more

- `docs/proposals/capabilities.md` §5.0 (omitted declarations), §5.6 (call-site
  attenuation), §7.5 (path confinement), §11 (reflection), §12 (static
  checking), §14 (environments and evaluation).
- `examples/capabilities/README.md` — six smaller programs covering the
  capability model on its own, each showing a denial as well as a success.
