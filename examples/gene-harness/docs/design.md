# DeepSeek Harness, and what a Gene Harness should take from it

Status: **all five §4 items are built and runnable in `../src/`.** The design
below is unchanged in its argument; where running it corrected a claim, the
correction is inline and §5 records what changed. Two things remain open and
are named in §4.

DeepSeek open-sourced an agent harness (`dsh`) in 2026 whose organising claim is
**"everything is a plugin"** — the model adapter, the tool registry, the session
log, and the agent loop itself are all replaceable at the configuration layer.
This document records what that architecture actually is, judges which parts fit
Gene, and designs a Gene Harness from the parts that do.

The short version: **the seam idea and the dynamism are both right, and Gene can
express both better than TypeScript can. The "no privileged core" claim is the
part to reject** — Gene has a security boundary that must not be a plugin.

A correction to an earlier draft of this document, which argued for static
composition: that conflated two separate things. **Dynamic install and uninstall
is not the same as letting load order resolve ambiguity.** A harness can be fully
live — plugins arriving, being replaced, and leaving while it runs — and still
refuse to guess when two providers claim one seam, because replacement is an
explicit named operation rather than a layer. Gene already has the primitives for
the live version, and §3 is now built on them.

Sources are listed at the end. Everything attributed to `dsh` below comes from
its own `AGENTS.md` and `docs/architecture.md`.

## 1. What DeepSeek Harness is

`dsh` is a Node/TypeScript agent runtime built on
[Cordis](https://github.com/cordiverse/cordis), a plugin meta-framework in which
"plugins contribute services, typed events, and reversible effects to a shared
context." The harness vendors Cordis and organises itself as
`@deepseek-ai/dsh-*` workspaces: `core/` (session, system-prompt, tools, agent,
agent-loop), `llm/`, `shell/`, `fs/`, `web/`, `workflow/`, `subagent/`,
`session/`, `guard/`, and about eighteen more, each a capability.

### 1.1 The capability seam

The load-bearing idea. A seam is a swappable capability with **three** roles:

- **Service Definition** — the interface;
- **Service Provider** — an implementation;
- **Consumer** — the user of it, commonly a model-facing tool.

> "A capability seam comprises Service Definition / Service Provider / Consumer
> roles. It is complete, never one role."
>
> "A package may combine roles, but one role alone is not a seam; adding a
> capability means designing all three."

The payoff is that one provider swap moves the whole product: replacing the
filesystem or subprocess provider changes Bash, PTY, and LSP tools at once,
without touching any of them.

### 1.2 Registration as reversible effects

> "Every contribution goes through `ctx.effect()` / `ctx.on()`; a registry's
> `register()` returns the disposer."

Mounting a plugin registers services, listeners, and state; unmounting unwinds
them. There is no manual cleanup path, which is what makes runtime recomposition
tractable.

### 1.3 Typed events with waterfall semantics

The agent loop exposes named extension points rather than inviting edits:

| Event | Role | Kind |
|---|---|---|
| `agent/pre-step` | rewrite or reject claimed messages | waterfall |
| `agent/request` | intercept model-request assembly | waterfall |
| `llm/stream` | observe token streaming | waterfall |
| `tools/pre-execute` | validate or gate a tool call | waterfall |
| `tools/execute` | run the tool | waterfall |
| `tools/post-execute` | process the result | waterfall |
| `agent/turn-stopping` | stop the turn | serial |

> "Waterfall listeners MUST call `next()` to delegate; returning without it
> short-circuits the chain."

And the accompanying discipline:

> "Plugins, not loop changes: new behavior goes on documented extension points;
> changing `agent-loop` requires updating docs/architecture.md."

### 1.4 The logging invariant

> "Model-visible ⟺ logged: anything that reaches a model request must be
> reconstructible from the session log."

New model-visible input must extend `SessionEventMap` and render *from* the log.
Replay fidelity is therefore a structural property, not a feature someone
remembered to maintain.

### 1.5 Composition by configuration

A running instance is assembled from ordered layers: **bundle** patches, then
**profile** patch, then home-level patch, then CLI overlays, over `cordis.yml`.
`dsh --profile web --dump-config` prints the result. Supporting rules:
`Config` fields are validated and no plugin hardcodes a deployment-varying
tunable; cross-boundary ids are branded rather than bare strings; `strict: true`
everywhere.

## 2. Assessment

### 2.1 What is genuinely good

**The three-role seam is the best idea here.** Most plugin systems define an
interface and stop, which produces extension points nobody can actually swap
because the consumer was written against a concrete implementation. Requiring
the consumer to be designed as part of the seam is what makes "change the
filesystem provider, and Bash/PTY/LSP all change" true rather than aspirational.

**Registration-as-effects is the right lifecycle primitive.** Unload is where
plugin systems rot; making every contribution a disposer-returning effect makes
the reverse path structural.

**"Model-visible ⟺ logged" is a first-rate invariant** and the one I would steal
verbatim. It converts "can we replay this session?" from a hope into a typing
rule.

**Extension points over loop edits, enforced by documentation policy**, is a
mundane practice that keeps a core small over time.

### 2.2 What does not fit Gene, and should not be copied

**"No privileged core" is wrong for Gene, and the disagreement is not stylistic.**
Gene has a capability system: authority is a declared row checked at a boundary,
and `docs/proposals/capabilities.md` §5.3.1 lets an importer bound a dependency
it does not control. That boundary derives its value from being *unswappable*. A
harness where the guard is a plugin like any other has a guard a plugin can
replace. Gene's harness should say plainly: **the capability boundary is core,
everything above it is a plugin.** That is a smaller claim than DeepSeek's and a
much stronger property.

The flip side is a real advantage, and it is larger than it first looks. `dsh`
plugins are trusted code — `fs/` is described as "filesystem with policy," which
is a plugin choosing to behave. In Gene the *seam definition* carries an
enforceable authority contract: a protocol message may declare `^capabilities`,
and an impl that tries to broaden it fails to compile. A provider is therefore
bounded by the interface it implements, not by its own good manners — see §3.2,
where a provider holding `net/*` and `os/Env` is refused both while satisfying a
seam whose contract is one file read. This is the thing Gene brings that a
TypeScript harness cannot.

**Ordered patch layers conflict with a decision Gene has already made — but
dynamism does not.** `dsh` resolves competing contributions by layering: bundle,
then profile, then home, then CLI. Gene's protocol rule is the opposite and
deliberate — from `docs/spec/protocols.md`:

> "Zero applicable visible impls is missing behavior; multiple applicable impls
> is ambiguity. Import order does not choose a winner."

Adopting profile layering would import "position in a list decides semantics"
into a language that rejected it. Keep the rule, drop the layering: a seam holds
**one** provider, and installing a second is an explicit replacement, not a
stack. That is entirely compatible with swapping providers at runtime, which is
what §3 does — the objection is to *order deciding*, not to *change happening*.

**Waterfall middleware is a weaker tool than Gene's alternatives, for most of
these cases.** A `next()` chain's behaviour depends on who registered first —
again the ordering objection, not a dynamism one. Gene has two better-typed options
already: protocols for *substitution*, and the event bus in
`docs/events.md` for *observation*. Middleware earns its place only
where a listener must genuinely intercept and transform a value in a
chain — realistically `tools/pre-execute` gating and `agent/request` assembly —
and those should be explicitly modelled, not a general mechanism.

**`ctx` as an *ambient, implicitly-injected* registry is the poor match — an
explicit one is not.** Gene resolves names lexically and statically; sends have
no lexical callable fallback, and `gene/genex/geney/genez` are reserved so the
standard library cannot be shadowed. What fights Gene is the ambient part: code
reaching into a global container for whatever happens to be mounted. A registry
that is an ordinary value, passed or held explicitly and asked by name, has none
of that problem and is what §3.3 uses. The distinction is between dependency
*injection* as a language-level ambient mechanism, and a dependency *registry* as
a value — Gene wants the second.

### 2.3 What Gene already has that maps

| `dsh` concept | Gene equivalent | Status |
|---|---|---|
| Service Definition | `protocol` | shipped |
| Service Provider | `impl P for T` | shipped |
| Seam authority contract | `^capabilities` on a protocol message; impls may not broaden it | shipped |
| Provider swap, live | a seam table of values (§3.3) — no reload needed | shipped |
| Changing what an impl *does* | scoped impls, `import_impl`, transactional reload (`docs/scoped-impls.md`) | shipped |
| Runtime plugin install, bounded | `$runtime/load_sandboxed dir entry grants shared` | shipped |
| Plugin distribution | packages, `package.gene`, dependency resolution | shipped (Stage 3) |
| Bounding an untrusted plugin | protocol row + import-site ceilings | shipped |
| Reversible effects | `ensure`, scoped-impl activation/reload | partial |
| Typed events | `docs/events.md` — `gene/event` | shipped (application bus; runtime events deferred) |
| Session log | serde, event logs (`examples/ai_agent/home/events.gene`) | shipped |
| `cordis.yml` | a Gene data manifest seeding the live table | pattern exists |
| Plugin uninstall | provider removal via `Map/delete`; module unload no (`scoped-impls.md` §6) | partial |

More is already shipped than the earlier draft credited. The event bus has
since landed — `gene/event` gives typed events with nominal `^is` matching,
frozen snapshots, and the `EventSink` seam — so the gap list is now: reversible
effects as a registration primitive, module unload, and the harness assembly
itself.

## 3. Design: Gene Harness

### 3.1 Shape

```
harness/
  protocol/        seam definitions only — one protocol per capability
  core/            the unswappable part: capability boundary, session log,
                   provider resolution
  plugin/          providers and consumers, each its own package
  profile/         a Gene data manifest naming the *initial* seam table —
                   a seed for boot, not the configuration of record
```

`core/` is deliberately small. It owns three things a plugin may not replace:
the capability boundary, the session log, and the seam table itself. Everything
else — model adapter, tools, shell, filesystem, the agent loop — is a plugin,
and every one of them can be replaced while the application runs.

The profile seeds the table at boot. It is not the configuration of record,
because the running table is: an operator who swaps a provider at 3am has changed
the system, and a `--dump-config` that printed the file rather than the live
table would be lying.

### 3.2 A seam is a protocol, and the protocol carries the authority contract

This is where Gene does something Cordis cannot, and it is the reason to build
this at all. A protocol message may declare a `^capabilities` row, and **an impl
may not broaden it** — the compiler rejects the attempt:

```
Error: impl HarnessFs for LocalFs message HarnessFs/read_text
       broadens its ^capabilities contract
```

So the Service Definition states the authority envelope once, and every provider
of that seam is bounded by it:

```gene
# harness/protocol/fs.gene — Service Definition, and the authority contract
(protocol HarnessFs
  (message read_text [path : Str] : Str ^capabilities [(fs/ReadFile path)])
  (message list_dir [path : Str] : (List Str) ^capabilities [(fs/ReadDir path)]))
```

```gene
# harness/plugin/fs_local.gene — Service Provider
(type LocalFs ^props {^root Str})

(impl HarnessFs for LocalFs
  (message read_text [self, path : Str] : Str
    ^capabilities [(fs/ReadFile path)]
    ($fs/read_text path))
  (message list_dir [self, path : Str] : (List Str)
    ^capabilities [(fs/ReadDir path)]
    ($fs/list_dir path)))
```

A consumer takes the provider as a value and never names a concrete type:

```gene
# harness/plugin/tool_bash.gene — Consumer
(fn make_bash_tool [fs : HarnessFs, sh : HarnessShell] : Tool …)
```

The seam is incomplete until a consumer exists that could accept a different
provider. That rule is worth keeping verbatim from `dsh`.

**A provider must state its row; omitting it is rejected.** An earlier draft of
this section implied a provider could simply implement the message and inherit
the definition's envelope. Measured, that is not what happens:

| Provider declares | Result |
|---|---|
| the same row as the definition | accepted |
| a narrower row, including `^capabilities []` | accepted |
| nothing | **rejected** — "broadens its `^capabilities` contract" |
| a wider row | rejected |

An absent row means *unchecked* authority, which is wider than any declared
one, so the compiler is right to refuse it. The consequence is better than the
draft assumed: reading a provider tells you its authority without
cross-referencing the protocol, and a test double that needs nothing says
`^capabilities []` where a reviewer can see it.

**The contract is enforced at the call, not only at the impl.** A provider
declaring `(fs/ReadDir "/tmp")` cannot be called without that grant —
`refused: declaration requires fs/ReadDir` — while a `^capabilities []`
provider of the same seam runs anywhere. So swapping the provider changes what
authority the *product* needs, which is `dsh`'s "one provider swap moves the
whole product" with an enforcement story TypeScript has no way to tell.
`examples/gene-harness/src/` demonstrates exactly this: run `src/demo.gene`
with and without `--allow_read_dir /tmp` and only the local provider's line
changes.

One caveat worth knowing before writing a demo: a capability path *inside the
entry's own package* is ambiently granted, so a contract naming a relative path
under the project succeeds without any flag and proves nothing. The example
uses `/tmp` for that reason.

**What this buys, measured rather than asserted.** A provider whose own module
holds `net/*`, `os/Env`, and read-write access to the workspace, implementing a
seam whose contract is only `(fs/ReadFile path)`:

```
env refused: os/get_env requires os/Env | write refused: fs/write_text requires fs/WriteFile
```

and nothing was written. The provider's ambition is irrelevant; the seam's
contract is what holds. Reading `../m.gene` through the same seam is refused at
the declaration, before any body runs, because `(fs/ReadFile path)` is
parameter-dependent.

That is the difference between "filesystem with policy" — a plugin choosing to
behave — and a filesystem seam a plugin *cannot* exceed. It needs no new language
feature: the protocol and impl above run as written today, and the refusals
quoted are real output, not illustrations.

### 3.3 The kernel, written as code

The harness is a **running application, not a configuration**, and the plugin
system is a subsystem with its own types and lifecycle — not a mapping onto
packages, `try`, and scoped impls. Those are how Gene *distributes* and
*compiles* code; a plugin architecture is about what happens at runtime, and it
wants objects of its own.

A working prototype is in `tmp/harness-repro/kernel_prototype.gene`; the
transcript below is its real output. Three types:

```gene
(type Plugin  ^props {^id Str ^provides (List Str) ^requires Any?
                      ^activate Any ^deactivate Any?})
(type Harness ^props {^seams Any ^plugins Any ^status Any ^effects Any
                      ^log Any ^bus Any})
(type HarnessError ^props {^message Str} ^impl [Error])
```

A plugin is a **value**, not a module: an id, the seams it claims, the seams it
needs, and two entry points. That is what makes it installable from anywhere — a
file loaded at runtime, a package dependency, or a literal built in memory for a
test.

`requires` names **seams, not plugins**. A dependency on a capability survives
the provider being swapped, which is the whole reason to have seams at all; a
dependency on a plugin id would reintroduce exactly the coupling the seam was
there to remove. §3.3.5 is what the kernel does with it.

### 3.3.1 The effect ledger

The kernel owns the tables. A plugin never touches them; it contributes through
`provide`, and every contribution is recorded against the plugin id:

```gene
(fn provide [h : Harness, id : Str, seam : Str, value] : Any
  (var seams (h/seams ~ get))
  (if_yes (!= (seams ~ get seam) void)
    (fail (HarnessError ^message $"seam ${seam} already bound; replace it explicitly")))
  (seams ~ put seam value)
  (record_effect h id {^kind "seam" ^seam seam})
  seam)
```

**The ledger holds effect records, not disposer closures.** Cordis returns a
disposer from `ctx.effect()`; this design stores data and keeps one function
that knows how to reverse each kind:

```gene
(fn reverse_effect [h : Harness, e]
  (if (== ($to_str e/kind) "seam")
    ((h/seams ~ get) ~ delete e/seam)))
```

Three reasons to prefer data over closures here, in increasing order of weight:
an effect record is **inspectable**, so `what has this plugin registered?` is a
query rather than an opaque list of functions; it is **serializable**, which
matters because §3.6 wants everything model-visible reconstructible from a log,
and a closure is not; and it does not depend on a captured environment surviving
the frame that created it — which, in this codebase, it did not reliably do (see
§5).

Unwinding is LIFO, mirroring the generator close order in `docs/spec/streams.md`.

### 3.3.2 Activation is all-or-nothing

The property worth building the kernel for: a plugin that fails halfway through
`activate` leaves nothing behind.

```gene
(fn promote [h : Harness, id : Str]
  (var p ((h/plugins ~ get) ~ get id))
  (try
    ((p/activate) h id)
    ((h/status ~ get) ~ put id "ready")
    catch e
    (unwind h id)                                # nothing partial survives
    ((h/status ~ get) ~ put id "error")          # but the plugin itself does
    (log_append h "lifecycle" $"activate ${id} failed: ${e/message}")
    (notify h (PluginFailed ^plugin id ^message ($to_str e/message)))))
```

This is not "reuse `try`". `try` is the local mechanism; the *architecture* is
that the kernel knows what the plugin registered and can reverse it without the
plugin's cooperation. A plugin cannot forget to clean up, because cleanup was
never its job.

**A failure leaves the plugin behind, in `error`.** The rollback is unchanged —
the seam the plugin bound before it raised is gone — but the plugin stays
installed and says why. A failure that erases its own subject is one you cannot
investigate, and at 3am the useful artifact is a plugin sitting there in `error`
next to the log line that explains it. It is not retried: an `activate` that
raised will raise again until something outside it changes, and a kernel that
retried on its own turns one bad plugin into a loop. `retry` is the operator
saying the something changed.

This is also why `install` no longer *raises* on a failed activate. Once
dependencies exist (§3.3.5) one install can promote a whole waiting chain, so
there is no single failure to raise — and the plugin has to survive its own
failure in order to be in `error` at all. `install` returns the resulting
status; `PluginFailed` goes out on the bus for anyone watching.

Measured, from the prototype — a plugin that registers one seam and then fails:

```
install good  : installed fs_local (ready)
resolve Fs    : LOCAL-FS
install combo : installed combo (ready)
installed     : ["fs_local" "combo"]
install bad   : installed broken (error)
Log rolled back? yes — no provider left behind
states        : ["fs_local:ready" "combo:ready" "broken:error"]
double install: refused: plugin fs_local already installed
uninstall combo: uninstalled combo
Llm gone?      : yes
Fs still there : LOCAL-FS
installed      : ["fs_local"]
```

Every line is a property the design claims: atomic activation, no partial
registration, a failure that is a *state* rather than a disappearance, one
provider per seam, and an uninstall that removes exactly one plugin's
contributions and leaves its neighbour's intact.

### 3.3.3 Binding is explicit; there is no last-wins

`provide` **refuses** a seam that is already bound. Replacement is a separate,
named operation rather than a second registration that silently shadows the
first. That is the §2.2 rule — order must not decide — expressed as kernel
behaviour instead of a convention, and it costs one line.

### 3.3.4 Installing a plugin at runtime, bounded

A plugin value can come from anywhere, including a module loaded while the
application runs. `$runtime/load_sandboxed` does that with only the standard-
library namespaces named in its grants, transitively across everything that
module imports:

```gene
(var p ($runtime/load_sandboxed "plugins" "fs_local.gene" ["fs"] []))
(install h (p/plugin))
```

Measured: a plugin loaded with no grants that reaches for the filesystem cannot
find one — a denied namespace is *absent*, not merely refused, and `gene` is a
reserved root it cannot rebind to fetch the real one back. So the kernel decides
what admitted code may reach at the moment it admits it, and `grants` is the
operator-readable record of that decision.

### 3.3.5 Dependencies, and a lifecycle that settles

The kernel is a **state machine, not a sequence**. `install` registers a plugin;
whether it activates is a question about the world, and the answer can change
after the install returns. A plugin is therefore in exactly one of three states:

| state | meaning |
|---|---|
| `pending` | installed, but at least one seam it `requires` is unbound |
| `ready` | activated; its contributions are in the tables |
| `error` | its `activate` raised. Unwound, still installed, not retried |

`settle` drives the table to a fixpoint after anything that could change the
answer — an install, an uninstall, a `retry`. It runs in two phases, and the
order is not arbitrary:

```gene
(fn settle [h : Harness] : Any
  ;; phase 1: demote every ready plugin whose requirements went away
  ;; phase 2: promote every pending plugin whose requirements are now met
```

Demote first, because a demotion **unbinds** seams and can starve a dependent,
which can starve *its* dependents — the cascade needs its own fixpoint. Promote
second, because a promotion only ever **binds** seams: it can satisfy another
plugin but can never starve one, so phase 2 can never send control back to phase
1. That asymmetry is what makes the loop provably terminate. Interleaving the
two would still converge, but it would churn — activating a plugin whose
provider is about to vanish in the same settle, running its `activate` for
nothing.

Three consequences worth stating, because each is a design decision rather than
a fallout:

**Install order stops mattering.** Three plugins installed in reverse dependency
order end up in the same state as three installed in dependency order. This is
the property an ordered profile/bundle-layer scheme (§2.2, "do not adopt") tries
to buy with configuration — and it comes for free here, because unmet
dependencies are a *state* rather than an error at a point in time. Nothing is
ordered, so no ordering can be wrong.

**Withdrawal cascades, and the cascade is reversible.** Removing a provider
returns its dependents to `pending`, not to uninstalled: what went away was
their dependency, not the operator's intent. Put the provider back and the chain
comes back with it. Reversibility is what makes a cascade safe enough to allow
at all — an irreversible one would mean a single uninstall could quietly
dismantle half the system.

**A dependency cycle is `pending`, not a hang and not an error.** Two plugins
each waiting on the other's seam simply never settle, and both say so in
`plugin_states`. That is a better 3am outcome than either alternative: a hang
tells you nothing, and an error implies someone did something wrong when the
truth is that the configuration is merely incomplete. A *self*-dependency is
different — a plugin requiring a seam it provides can never be satisfiable by
anything — so it is refused at install.

Because `requires` names seams, `replace` does not disturb anything: the seam
stays bound across a provider swap, so no dependent is ever deactivated for a
substitution it was never meant to notice.

`activate` gets one guarantee out of all this, and it is the one that matters at
the call site: **every seam in `requires` is bound before it runs.** So a plugin
resolves what it needs without a defensive check —

```gene
(Plugin ^id "indexer" ^provides ["Index"] ^requires ["HarnessFs"]
  ^activate (fn [] (fn [h, id]
    (var fs (resolve h "HarnessFs"))            ;; cannot fail
    (provide h id "Index" (head_tool fs "notes")))))
```

**`deactivate` is advisory; the ledger is not.** A plugin's `deactivate` runs
before its effects are reversed, so the hook still sees the seams its own plugin
provided. If it raises, the failure is logged and the removal proceeds exactly
as planned — the kernel can afford that because it does not *depend* on the
hook. The ledger reverses every registration either way. A `deactivate` is for a
plugin's own private state, a flushed buffer or a closed handle, and losing it
degrades that plugin rather than the harness. That is the same argument as
§3.3.1 arriving at a second door: cleanup was never the plugin's job, so the
plugin failing at cleanup cannot be the harness's problem.

The lifecycle is **observable and recorded**, through machinery that already
existed. `PluginActivated`, `PluginDeactivated`, `PluginFailed`,
`PluginInstalled` and `PluginUninstalled` go out on the ordinary event bus, so a
plugin can watch its own dependencies come and go without the kernel knowing
anything about it — §2.2's division holding up under load: the bus observes, the
seams substitute. And every transition is appended to the session log under
`^kind "lifecycle"`, which is deliberately the *same* log as the model-visible
one: `assemble_request` selects `message` events, so a lifecycle record is
durable and inspectable and structurally incapable of reaching a model request.

One inversion is worth calling out, because it is the kind of thing that is
obvious only after it bites. The bus is configured `event/collect`
(`docs/events.md` §8), so a raising observer cannot abort a publication — a
plugin system whose dependency resolution can be halted by an unrelated observer
is not one you can recompose at 3am. But `collect` returns a `PublishResult`
rather than raising, which means **the kernel has to be the reporter**: it reads
`failed` and logs each error. An observer that fails silently is worse than one
that stops the world, because nothing anywhere records that it happened.

### 3.4 The boundary is core, and plugins are bounded twice

The seam contract of §3.2 bounds a provider through the interface. The import
site bounds the package as a whole, for anything it does outside a seam:

```gene
(import [make_shell] from "gene/harness_shell_pty"
  ^capabilities [(os/Exec)])
```

The effective authority is `caller ∩ module_ceiling ∩ import_ceiling`. The two
mechanisms are complementary: the protocol row is per-message and travels with
the interface, so it holds for providers the harness never saw; the import
ceiling is per-package and bounds initialization and anything the package does
on its own account.

The agent loop is a plugin. The capability check is not.

### 3.5 Extension points

Two mechanisms, chosen by what the extension does:

- **Substitution** — replace behaviour: a seam, resolved as above.
- **Observation** — watch behaviour: the event bus from
  `docs/events.md`. Handlers cannot alter the value, which is the
  point; a tracing plugin should not be able to change a model request.

Interception — genuinely transforming a value in a chain — is restricted to a
named, closed set rather than offered generally:

| Point | Why it must transform |
|---|---|
| `request/assemble` | building the model request from the log |
| `tool/gate` | admitting or refusing a tool call before it runs |

Both are seams with a default provider, not middleware stacks. A gate that wants
to compose with another gate composes *providers* explicitly, so the order is
written down in the profile rather than emerging from registration sequence.

### 3.6 The logging invariant, kept

**Model-visible ⟺ logged.** Anything that reaches a model request must be
reconstructible from the session log. Gene can hold this more cheaply than
TypeScript can, because the log is Gene data: nodes are code and data at once,
serde already exists, and a replay is an ordinary fold over the log rather than
a bespoke deserializer.

Concretely: `request/assemble` may read only the session log and the profile. If
a plugin wants to put something in front of the model, it appends a log event
first. A plugin that reaches around the log is the one bug class this invariant
is designed to make impossible, and it is checkable — the assembler's capability
row need not include anything else.

**Built.** `assemble_request` in `src/kernel.gene` takes the log and nothing
else — not the harness, not the seam table — and declares `^capabilities []`,
which is what makes "reads only the log" enforceable rather than a convention:
an assembler that reached for a file or the environment would be refused at its
own declaration. The log belongs to core, so a plugin appends and reads nothing
else.

The payoff shows up in `src/demo.gene` as two lines. A `trace` event is in the
log and absent from the request, because the request contains only what the log
marks model-visible. And uninstalling the provider that produced a message
leaves the assembled request unchanged — replay is a fold over the log, so it
does not depend on the live system, which is exactly the property a harness
recomposable at 3am needs.

### 3.7 Reversible effects — closed by the ledger

An earlier draft listed this as the one language gap, wanting a Gene equivalent
of `ctx.effect()`. Writing the kernel closed it without a language change: the
ledger *is* the reverse path, and because it holds records rather than closures
it needs nothing from the language beyond a map and a list.

What remains is breadth, not mechanism. `reverse_effect` knows two kinds now —
`seam` and `subscription` — and a real harness adds `tool`, `route`, and the
rest, each a new arm in one function the kernel owns. That is the right place
for the knowledge: a plugin that invents an effect the kernel cannot reverse
should not be able to register it.

`subscription` is worth having as the second kind rather than a placeholder.
An observer plugin contributes no seam at all — it subscribes to the harness
event bus — and uninstalling it cancels the subscription without its
cooperation. A listener outliving its plugin is the classic plugin-system leak,
and the ledger makes it structurally impossible. It also settles the division
in §2.2 by demonstration: the bus is for *observation*, the seams for
*substitution*, and neither is doing the other's job.

### 3.8 Profiles, and why they can be sets

§1.5 is dsh's composition story: bundle patches, then the profile patch, then a
home patch, then CLI overlays, over a base config, with `--dump-config` to print
what you actually got. §2.2 says not to copy it. This is the alternative that
falls out of the rest of the design.

**A profile is a named set of plugin values.** Four files, split so that a
growing set of deployments stays legible:

| file | holds |
|---|---|
| `src/profile.gene` | what a `Profile` is, and `boot` / `boot_reversed` |
| `src/profiles.gene` | the registry — which profiles exist, by name |
| `src/profiles/cli.gene`, `web.gene` | one deployment each |
| `src/profiles/common.gene` | plugins every deployment installs |

The two defined today:

| | `cli` | `web` |
|---|---|---|
| `HarnessFs` | `LocalFs "/tmp"` — declares `(fs/ReadDir "/tmp")` | `MemFs` — declares `^capabilities []` |
| `HarnessRender` | `TextRender` — plain text | `HtmlRender` — escaped HTML |
| consumer | `reporter` | **the same `reporter` value** |

The consumer is not a variant and not a patched copy. It requires two seams,
names no provider, and is the identical plugin in both sets; what changes
between deployments is what it is standing on. Booting is the whole of it:

```gene
(fn boot [p : Profile] : Harness
  (var h (new_harness))
  (for plugin in p/plugins
    (install h plugin))
  h)
```

There is no merge step, no overlay resolution, and nothing to dump — the
profile *is* the configuration, so `--dump-config` has no question to answer.

**That this works at all is a consequence of §3.3.5, not a stylistic choice.**
Ordered layers exist because in a system where activation is a sequence, order
decides which provider wins and which dependency is visible; once order is
load-bearing, composition has to be expressed as an ordered stack, and the stack
has to be printable to be understood. Make unmet dependencies a *state* and the
problem the layers were solving stops existing. `boot_reversed` keeps that claim
honest: booting a profile backwards must reach the same state as booting it
forwards, and when the set is reversed `reporter` is installed first and simply
waits as `pending` until its seams arrive.

**A missing grant costs one plugin, not the process.** Booting `cli` without
`--allow_read_dir /tmp` is the most informative of the three runs:

```
states:     ["fs:ready" "render:ready" "reporter:error"]
report:     <no report: reporter is error>
...
activate reporter failed: declaration requires fs/ReadDir
```

The boot succeeds. Two plugins are `ready`, the one that needed authority it was
not given is in `error`, and the lifecycle log names the capability. This is the
capability system, the seam contract, and the plugin lifecycle arriving at the
same place: authority is declared at the seam, checked at the boundary, and the
failure is reported as plugin state rather than as a dead process.

**A profile is a starting point, not a description of the system for all time.**
Modifying a booted harness is `install`, `uninstall`, and `replace` — named
operations on a live system, not another layer that wins by arriving later.
Uninstalling the `render` plugin parks the reporter; installing the *other*
profile's renderer promotes it again, re-running its activation against the new
provider, and the report changes shape without a reboot and without anything
patching anything.

Two things this deliberately does not provide. There is no "profile B is profile
A plus X" — that is a layer, and it is the thing §2.2 rules out. And there is no
precedence rule between profiles, because two profiles are alternatives rather
than a stack; the two here even reuse the plugin ids `fs` and `render` precisely
so they cannot be layered.

That constraint is exactly the one a growing set of profiles pushes against, so
it is worth saying what replaces it. **Deployments share composition by
importing the same factory, not by patching a base.** `src/profiles/common.gene`
holds `reporter_plugin`, and `cli` and `web` each install it — the same value in
both sets, not a base profile with an overlay on top. Sharing by import is
ordinary Gene code with no patch semantics to reason about, and it scales the
way ordinary code scales: a third deployment imports what it wants and states
the rest. The failure mode of layers is that you cannot tell what a deployment
runs without replaying the merge; the failure mode here is a slightly longer
list, in one file, that you can read.

### 3.9 The agent seam, and a harness that extends itself

Three seams now. `HarnessFs` varies in authority, `HarnessRender` varies in
behaviour, and `HarnessPrompt` is the one a real harness cares about: what turns
a prompt into a response. A production deployment binds a model here; this repo
binds a command interpreter, and the consumers — a terminal loop, a one-shot
command-line prompt, a test — cannot tell which.

**The driver is a plugin, not a flag.** `src/repl.gene` provides a `Driver` seam
whose value is the read-handle-print loop, and `cli` installs it while `web`
does not. So "is this deployment interactive?" is answered by what the profile
bound, and `main.gene` runs whatever is there without knowing which profile
supplied it. The loop itself is thirty lines and knows nothing about what any
prompt means, which is the test of whether the seam is in the right place.

**`HarnessPrompt` deliberately declares no `^capabilities` row.** That looks
inconsistent next to the other two seams until you try the alternative: a
declared row is *transitive*, so a `^capabilities []` function cannot call an
impl that declares `(fs/ReadDir "/tmp")` **even when the process holds the
grant** (§5). A row on a dispatcher would therefore forbid it from delegating to
the very seams it exists to delegate to. Authority still lands somewhere
specific — the narrow operations the agent performs *itself* declare their own
rows at their own definitions, so `build` is bounded to one directory while
`help` and `status` need nothing.

**`build` writes a plugin and loads it into the running system.** The generated
module is plain Gene with no imports; it provides a `Tool:<name>` seam whose
value is a function, and it is loaded through the same `install_sandboxed` path
as any out-of-tree plugin — sandboxed, granted nothing, sharing nothing. Driven
through tmux, the whole loop:

```
harness>
build greet a plugin written from a prompt
installed greet (ready)

harness>
tools
["Tool:greet"]

harness>
tool greet world
greet(world) -> a plugin written from a prompt

harness>
unload greet
uninstalled greet

harness>
tools
[]
```

The last two lines are the ledger doing its job on code that did not exist when
the process started: the tool seam went with the plugin, without the plugin's
cooperation and without anyone writing an unload path for it.

Three things bound self-extension, and only one of them is a grant:

- **The package root.** `load_sandboxed` refuses a sandbox directory that
  escapes it, so a harness cannot load code it wrote to `/tmp`. Generated
  plugins live in `plugins/generated/` because that is the only place they can
  live, not because it is tidy.
- **`grants []` on the generated module.** It cannot name `$fs`, `$net`, or
  `$os`. A harness that writes its own plugins is not thereby writing plugins
  with its own authority.
- **The ledger.** Whatever the new plugin registers is reversible by the kernel,
  which is what makes loading it a decision you can take back.

Notably *not* on that list: a capability grant for the write itself. A path
inside the entry's own package is ambiently authorized, so a package extending
itself is not an authority question — see §5, because the opposite was asserted
here before it was run.

### 3.10 A real model behind the seam

`src/llm.gene` binds OpenRouter to `HarnessPrompt`, and the `chat` profile is
`cli` with that one plugin swapped:

| | `cli` | `chat` |
|---|---|---|
| `HarnessFs`, `HarnessRender`, `Report`, `Driver` | same four plugins | same four plugins |
| `HarnessPrompt` | offline interpreter | `deepseek/deepseek-v4-flash-0731` |

Nothing else is told. The terminal loop still reads a line and prints an answer;
`cli` still works with no network and no key.

**The model's only way to act is to emit a Gene program.** The shape is
`examples/safe_ai_agent`'s, pointed at a different subject — there the evaluated
program's world is a workspace directory, here it is the running harness:

```
prompt -> LLM -> {^status "done"|"in-progress"
                  ^response "one sentence"
                  ^code (do ...)}
       -> print ^response, print ^code, evaluate ^code, print the result
       -> repeat while ^status is "in-progress"   (bounded at 6 turns)
```

There is **no tool list**. An earlier version had one — the model replied
`RUN: <command>` and the harness matched it against ten verbs — and its ceiling
showed the moment the model wanted something the verbs did not name. A harness
whose whole thesis is that it can be recomposed at runtime should not hand a
model a menu of ten recompositions.

What it gets instead is the kernel's own vocabulary as `Env` bindings: `h`
itself, plus `install`, `uninstall`, `retry`, `provide`, `replace`, `resolve`,
`subscribe`, `publish`, `install_sandboxed`, the inspection functions, the
session log, and the types — `Plugin`, the event types, the seams and their
providers. The same names `src/profiles/` uses to compose a deployment, because
there is no reason the model should be working with a smaller language than the
profiles are.

Real sessions, unedited:

```
install a plugin named echo whose Tool:echo seam is a function returning
whatever string it is given, then call it with hi
   Echo plugin installed and tested.
   (do (install h (Plugin ^id "echo" ^provides ["Tool:echo"]
         ^activate (fn [] (fn [hh id] (provide hh id "Tool:echo" (fn [s] s))))))
       ((resolve h "Tool:echo") "hi"))
hi

now remove it and prove the seam is gone
   Uninstalled the plugin and proved Tool:echo is gone.
   (do (uninstall h "echo") (var gp (seam_bound h "Tool:echo")) (plugin_states h))
["fs:ready" "render:ready" "reporter:ready" "agent:ready" "driver:ready"]

swap the HarnessRender provider for the HTML one, then render hello through it
   (do (replace h "fonts" "HarnessRender" (render_provider (HtmlRender)))
       ((resolve h "HarnessRender") ~ (msg HarnessRender render) "hello"))
<p>hello</p>
```

The printed `^code` is the **canonical** form, so `$fs/write_text` appears as
`(path gene fs write_text)` and a protocol send as `(msg HarnessRender render)`.
That is what actually executes, which is the point of showing it.

**Structural authority is total; host authority is narrow.** Every binding above
is an ordinary Gene call needing no grant, so the model may rebuild the harness
freely. What it may reach *outside* the process is the Env's capability row, and
that row is resolved against this module's context when the Env is minted, so it
can never name more than the harness already holds. Measured, from inside a
generated program:

```
($os/get_env "HOME")                      refused: os/get_env needs os/Env
($fs/read_text "/etc/passwd")             refused: fs/read_text needs fs/ReadFile
(head_tool (resolve h "HarnessFs") "n")   refused: capability declaration needs fs/ReadDir
(bound_seams h)                           ["HarnessFs" "HarnessRender"]
(install h (Plugin ...))                  ["HarnessFs" "HarnessRender" "Tool:x"]
```

The third line is the interesting one: the *process* held `fs/ReadDir /tmp`, and
the program was still refused, because the Env's row is a ceiling and does not
include it. A refusal is a **value**, not a crash — it is printed, it goes into
the next turn's history, and the model gets to try something else.

**The Env re-roots relative paths**, the way `safe_ai_agent`'s workspace does.
Its row is `(fs/WriteDir "plugins/generated")`, so a generated
`($fs/write_text "clock.gene" …)` lands there and nowhere else. This is how the
harness grows code that did not exist at boot: write a module with
`plugin_source`, then `install_sandboxed` it — sandboxed, granted nothing.

That re-rooting cost a wrong turn worth recording. The agent originally exposed
`write_plugin_source`, a helper carrying its own
`^capabilities [(fs/WriteDir "plugins/generated")]` row, and calling it from
inside the Env was refused. A declaration row inside a re-rooted context
resolves *against that context*, so the inner row named
`plugins/generated/plugins/generated`. The fix was to stop wrapping: generated
code calls `$fs/write_text` directly, which is `safe_ai_agent`'s rule arrived at
the hard way — **generated code should use the standard library, and the row,
not a bespoke helper, should decide where it lands.**

**Session memory is a deliberate divergence.** `safe_ai_agent` discards history
when a task finishes, which is right for a task runner and wrong for a shell:
the second thing anyone types is "now remove it". Without a carry-over the model
guessed a plugin name out of the system prompt's own example and uninstalled
something that never existed. A bounded window of the last four exchanges rides
along — bounded because a session is open-ended, and this is the one place where
unbounded growth would stay invisible until a context limit became a 400.

**Prompting notes, all of them things a live model got wrong.** The envelope
format has to lead *and* close the system prompt with a filled-in example
between; stating it once in the middle produced a sentence followed by a bare
`(do …)`, which is not readable as an envelope and loses the turn. And the Gene
primer needs four rules beyond the obvious ones, each added after watching it
fail:

- a protocol message must be qualified — `(p ~ HarnessRender:render "hi")`, not
  `(p ~ render "hi")`;
- a map literal is `{^key v}`; `{"key" v}` is a read error that discards the
  *entire* reply, code included;
- a seam holding a function is called `((resolve h "Tool:x") "arg")`, not
  `(f ~ "arg")`;
- `try` takes a `catch` clause, not a nested `(catch …)` form.

Two smaller things the API surfaced:

- **`deepseek-v4-flash-0731` is a reasoning model.** At `max_tokens 60` it spent
  the entire budget thinking and returned the three characters `har`. The client
  sends `reasoning {^enabled false}`.
- **`$os/get_env` raises when unset**; `$os/env?` is the optional read. The first
  version used `get_env` for an optional override and the agent plugin landed in
  `error` at boot with the reason in the lifecycle log — §3.3.5 working against
  a real mistake, with the rest of the harness booting fine.

**What is still unsolved** is what `safe_ai_agent` records too: `^response` is
composed before `^code` runs, so a confident summary can sit directly above a
result that contradicts it. One of the transcripts above had the model announce
nine installed plugins by name before its own program printed the five real
ones. Printing the program between the claim and the result is the mitigation,
not a fix.

## 4. Recommendation

Build the harness as a **living application**: it boots from a profile and is
modifiable from then on. Adopt, in this order:

1. **Seams as protocols carrying the authority contract** (§3.2). This is the
   piece that makes every later step safe. **Built** — `src/seams.gene` is the
   three-role seam (definition, two providers, one consumer) and `src/demo.gene`
   swaps the provider live and shows the authority change that comes with it.
2. **The kernel as code** (§3.3) — `Plugin` and `Harness` as types, an effect
   ledger the kernel owns, atomic activation, explicit binding. Not a mapping
   onto packages or scoped impls: those distribute and compile code, while this
   is about what happens at runtime. **Built** — `src/kernel.gene`, including
   the `replace` operation §3.3.3 calls for, which moves the ledger entry with
   the binding so uninstalling a seam's *former* owner cannot unbind it.
3. **Model-visible ⟺ logged**, with `request/assemble` bounded so it cannot read
   around the log. A live system that can be recomposed at 3am needs replay more
   than a static one does, not less. **Built** — see §3.6.
4. **Runtime plugin install via `$runtime/load_sandboxed`**, with `grants` as the
   operator-readable statement of what the new code may reach. **Built** —
   `install_sandboxed` in `src/kernel.gene`, exercised by `plugins/fs_stub/`
   (granted nothing, implements the seam) and `plugins/fs_rogue/` (reaches for
   `$fs`, and is stopped — see §5 for the caveat on *when*).

   The `shared` argument is what makes a sandboxed plugin able to implement a
   *typed* seam at all. The sandbox covers everything the module imports, so
   without sharing the one file holding the protocol the plugin would compile
   its own copy and its impl would satisfy a different identity than the
   consumer sends to. Sharing a single definition file is narrower than granting
   a namespace, and it is what keeps the seam a seam across the boundary.
5. **Disposers on `provide`** (§3.7), once enough plugins exist that replacement
   leaks something. **Built** in the form §3.7 concluded was right — not
   disposer closures, but a second effect *kind* in the ledger. `subscription`
   is that kind, and an observer plugin demonstrates it.
6. **A dependency lifecycle that settles** (§3.3.5). **Built** — `requires`
   names seams, `settle` drives the table to a fixpoint, and a plugin is
   `pending`, `ready`, or `error`. This is the item that turns the kernel from a
   registry into a living system: install order stops mattering, withdrawal
   cascades reversibly, and every transition is on the bus and in the log.

   It is also where the "living application" claim in §4's opening sentence
   stops being an aspiration. A harness you can only compose at boot is a
   configuration with extra steps; one where removing a provider correctly
   parks its dependents, and putting it back revives them, is a system you can
   actually modify while it runs.
7. **Profiles as sets, not layers** (§3.8). **Built** — `src/profiles/` defines
   `cli` and `web` over shared plugins in `common.gene`, `src/profile.gene` is
   the `Profile` type and `boot`, `src/profiles.gene` is the registry, and
   `src/main.gene` runs either. The ordered
   bundle/profile/home/CLI patch stack of §1.5 is not adopted and is not
   needed: order-independence comes from the lifecycle, so composition needs no
   precedence rules and no `--dump-config`.

Two things remain open:

- **The seam table is keyed by a plain string** and holds `Any`, so the kernel
  itself cannot check that the value bound to `"HarnessFs"` implements
  `HarnessFs`. It does not have to — a protocol works as an annotation, so the
  Service Definition supplies the gate (`fs_provider` in `src/seams.gene`) and a
  non-conforming provider is refused at bind time rather than at first use.
  Holding the protocol in the table would move that check into the kernel and is
  the tidier end state.
- **Module unload**, the removal-symmetric form of reload that
  `docs/scoped-impls.md` §6 anticipates. Uninstall reclaims a plugin's
  *contributions*; its *code* stays resident.

Do not adopt: ordered profile/bundle patch layers, a general waterfall
middleware mechanism, or an *ambient* DI container. The first two make order
decide semantics; the third makes dependencies invisible at the point of use.
None of the three is required for the system to be dynamic, which was the
confusion in the earlier draft of this document.

`examples/ai_agent` is the natural first subject: it already has tools, an event
log, persistence, gateway surfaces, and multiple model backends, assembled
without seams. Re-expressing its model adapter as one seam — and swapping the
provider at runtime, mid-session, with the session log intact across the
swap — would test the design at its narrowest and most interesting point before
anything is committed to.

## 5. Defects found while prototyping this

- **A sandboxed module's denied namespace is refused at first *use*, not at
  load, and the diagnostic does not mention the sandbox.** §3.4 and
  `docs/design.md` §15.10 both say a denied namespace is *absent*, so naming it
  fails — which is true, and the boundary holds. What neither says is *when*.
  A plugin whose only reference to `$fs` sits inside a message body loads
  cleanly, installs, binds its seam, and fails on the first call with:

  ```
  value is not callable: vkVoid
  ```

  because `gene/fs` resolved to nothing and the result was then applied. The
  file is never read, so this is a diagnostic and timing defect rather than a
  hole. But an operator installing a plugin at 3am gets "it installed fine" from
  a plugin that cannot work, and then a message naming neither the sandbox nor
  the namespace. Two things would fix it independently: resolving a sandboxed
  module's free names against its own root at admission, and making an absent
  namespace member fail as "namespace `fs` is not granted here" rather than
  decaying to `void`.

  Verified by `plugins/fs_rogue/`, which `src/demo.gene` loads and calls; the
  transcript above is its real output. This entry exists because the claim was
  asserted in the design before it was run, and running it changed it.


Recorded because they were found by writing the kernel rather than reasoning
about it, and because two of them shaped the design above.

- **SIGSEGV in the VM, cross-module — and it is a closure-lifetime bug.** The
  first two-file prototype crashed in `acquireSimpleCallScope` /
  `nimIncRefCyclic`, reproducibly (2/2), while the same code in one file ran
  fine. Minimal cases — a closure in a type prop called across modules,
  cross-module `fail`/`try` with an imported error type — did not reproduce it.

  The diagnosis arrived by accident. `src/kernel.gene` and `src/demo.gene` are
  the same design split across the same module boundary, and they **do not
  crash** — the one thing that changed is that the ledger stores effect records
  instead of disposer closures. So the trigger is a closure outliving the frame
  that built it and being called across a module boundary, which is also what
  produced the capture failure below. The two entries are almost certainly one
  bug seen from two distances.

  Repro preserved at `tmp/harness-repro/` (`h.gene` + `main.gene` crash;
  `single.gene` does not; `examples/gene-harness/src/` is the closure-free
  version that does not).

- **A closure stored beyond its frame lost its capture.** A disposer built as
  `(fn [] (seams ~ delete seam))` and stored in the ledger saw `seams` as `Nil`
  when it was finally run, while a sibling capture in the same closure resolved.
  Rewriting it to reach through the harness value gave
  `invalid local slot for symbol: h` instead. Simple capture-and-defer works in
  isolation, so this is not "closures do not capture"; it is something narrower
  and unidentified. It is the direct reason §3.3.1 stores effect *records*
  rather than disposer closures — which is a better design anyway, but it was
  chosen under duress and that is worth knowing.

- **An omitted optional prop reads as `void`, not `nil`.** `(!= p/deactivate nil)`
  is therefore true for a plugin that declared no `deactivate`, and the kernel
  called `void`. `($absent? …)` is the test that covers both.

- **A declared `^capabilities` row is transitive, and `[]` means "and nothing
  you call, either".** A function declaring `^capabilities []` cannot call an
  impl that declares `(fs/ReadDir "/tmp")` *even when the process holds the
  grant* — the refusal is `declaration requires fs/ReadDir` and it is identical
  with and without the flag, which makes it easy to misread as a missing grant.
  A row that *matches* the callee's succeeds. This is defensible and arguably
  the point of a ceiling, but the consequence is worth stating plainly:
  **declaring a row on a dispatcher is a mistake**, because it bounds everything
  the dispatcher delegates to for all time. `HarnessPrompt` declares none for
  exactly this reason (§3.9). The distinction that makes it work is that *no row
  at all* inherits the process policy while `[]` grants nothing — two very
  different meanings for what reads like the same "declares nothing".

- **A capability row's relative path resolves against the process working
  directory, not the package root.** `^capabilities [(fs/WriteDir
  "plugins/generated")]` in a module under `examples/gene-harness/src/` names
  `<cwd>/plugins/generated`, so the same source declares different authority
  depending on where it is invoked from — and the harness's `build` command
  works only when run from its own package directory. Nothing in the source says
  so. Resolving a row's relative path against the declaring module's package
  root would make a committed row mean one thing everywhere.

- **`msg` is a reserved compiler form, and using it as a local gives a
  misleading error.** `(var msg (top ~ get "message"))` followed by
  `(msg ~ get "content")` fails with `a message name must be a symbol` — the
  compiler parses `(msg …)` as the dynamic-message form (`compiler.nim:186`,
  and the `isSymbol("msg")` arms around 2740/6645). Nothing says `msg` is taken;
  the diagnostic points at the send rather than at the name. Rejecting the
  binding at `(var msg …)` with "msg is a reserved form" would cost one check
  and save the bisect this took.

- **The documented import form for the HTTP client does not work.**
  `docs/stdlib.md` line 90 shows `(import net/http_client [request stream
  HttpClientError])`; that raises `undefined symbol: net`. `$net/http_client`
  and `gene/net/http_client` both work. This is the same shape as the
  `$event/Event` annotation bug fixed earlier — a lowercase stdlib namespace is
  not a bare root — and the docs were written against the intended surface.

- **Writing inside the entry's own package needs no grant.** The `build` command
  was designed assuming `--allow_write_dir plugins/generated` would be required,
  and said so in a comment before it was run; it is not. A path inside the
  package is ambiently authorized, and the same row pointed at `/tmp` *is*
  refused without a flag. So the package is the fence. This is a coherent model
  — a package may modify itself, and reaching beyond it is authority — but it is
  not what "capabilities" suggests at first reading, and it means a plugin
  system that writes plugins gets that ability for free.

The first two are runtime defects worth fixing independently of the harness. The
third is documented behaviour that is easy to get wrong, and is now in the
skill's pitfalls.

## Sources

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- [deepseek-harness AGENTS.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/AGENTS.md)
- [deepseek-harness docs/architecture.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md)
- [cordiverse/cordis](https://github.com/cordiverse/cordis)
- [DeepSeek open sources an agent harness where everything is a plugin — The New Stack](https://thenewstack.io/deepseek-harness-open-source-plugins/)
- [DeepSeek Harness developer preview](https://deepseek.com/harness/en/)
