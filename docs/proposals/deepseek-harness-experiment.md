# DeepSeek Harness, and what a Gene Harness should take from it

Status: proposal

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
`docs/proposals/events.md` for *observation*. Middleware earns its place only
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
| Typed events | `docs/proposals/events.md` | proposal |
| Session log | serde, event logs (`examples/ai_agent/home/events.gene`) | shipped |
| `cordis.yml` | a Gene data manifest seeding the live table | pattern exists |
| Plugin uninstall | provider removal yes; module unload no (`scoped-impls.md` §6) | partial |

More is already shipped than the earlier draft credited. The gap list is:
reversible effects as a registration primitive, `Map` key removal, module
unload, the event bus, and the harness assembly itself.

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

### 3.3 The registry: a living seam table

The harness is a **running application, not a configuration**. A seam table is an
ordinary value holding one provider per seam, and installing, replacing, or
removing a provider is an operation on it while the app runs:

```gene
(var registry ($cell {}))

(fn provide [seam : Str, value] ((registry ~ get) ~ put seam value))
(fn resolve [seam : Str]        ((registry ~ get) ~ get seam))
```

A consumer asks the table rather than naming a provider:

```gene
(fn read_via [path : Str] : Str
  ((resolve "HarnessFs") ~ HarnessFs:read_text path))
```

**Swapping is live, and the seam contract survives it.** Measured — three
providers through one table, no reload and no restart:

```
local : ws file
upper : ws file
rogue : rogue refused: os/get_env requires os/Env
escape: refused: declaration requires fs/ReadFile
```

The third line is the point. A provider installed at runtime, whose own module
holds `net/*` and `os/Env`, is still bounded by the protocol's row (§3.2). The
authority contract belongs to the seam, so it holds for providers the harness
had never seen when it started.

This is why the dynamic design needs no impl reload. `docs/scoped-impls.md` does
support transactional reload, but **swapping a provider is a value assignment,
not a recompilation** — the impls stay fixed and the *choice* moves. Reload
remains the tool for changing what an impl does; the registry is the tool for
changing which one answers.

One provider per seam key at a time. Installing a second replaces the first
rather than layering over it, so there is never a stack whose order decides
behaviour — the property §2.2 wanted, kept without giving up dynamism.

### 3.3.1 Installing a plugin at runtime, bounded

`$runtime/load_sandboxed` loads a module *while the application runs*, with only
the standard-library namespaces named in its grants, and the restriction covers
everything that module imports:

```gene
(var p ($runtime/load_sandboxed "plugins" "pure.gene" [] []))
(p/describe)                       ; "pure plugin: computation only"
```

Measured, a plugin loaded with no grants that reaches for the filesystem cannot
find one — a denied namespace is *absent*, not merely refused, and `gene` is a
reserved root it cannot rebind to fetch the real one back.

So plugin installation is already capability-bounded at runtime, which is
precisely when it matters most: the harness admits code it did not compile
against, and decides what that code may reach at the moment it admits it. The
`grants` list is the honest place to put that decision, because it is the thing
an operator can read.

### 3.3.2 Uninstall, and what is missing

Removing a provider is removing it from the table. Two gaps, both real:

- **`Map` has no key removal.** Its message surface is `assoc get put to_stream
  to_pairs_stream`; there is no `delete`. Removing a seam today means rebuilding
  the table without that key. A `Map/delete` (or a persistent `dissoc`) is the
  smallest missing piece for a clean uninstall path.
- **There is no module unload.** `docs/scoped-impls.md` §6 is explicit: "MVP has
  no individual module unload. Loaded modules persist until reload or whole-
  application teardown." So uninstall drops the *provider*, and the plugin's code
  stays resident. For a long-lived harness cycling many plugins that is a leak,
  not a correctness bug — but it is the difference between "uninstall" and
  "stop using".

Neither blocks the design. A harness can install, replace, and stop using
plugins today; reclaiming their code needs the removal-symmetric form of reload
that §6 already anticipates.

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
  `docs/proposals/events.md`. Handlers cannot alter the value, which is the
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

### 3.7 Reversible effects — the remaining gap

`dsh` gets unload correctness from `ctx.effect()` returning a disposer. Gene has
the pieces (`ensure`, scoped-impl transactional activation and reload) but no
single registration primitive that guarantees the reverse path — and with a live
registry this stops being theoretical. A provider that registered a tool, opened
a database handle, and subscribed to an event has three things to undo, and
today each plugin is trusted to remember.

The smallest thing that would close it: `provide` returns a disposer, and the
seam table runs it when that provider is replaced or removed — LIFO within a
plugin, mirroring the generator close semantics already specified in
`docs/spec/streams.md`. This does not need to be a language change; it needs the
registry to be the one door everything registers through, so "did you clean up?"
stops being per-plugin diligence and becomes a property of replacement.

## 4. Recommendation

Build the harness as a **living application**: it boots from a profile and is
modifiable from then on. Adopt, in this order:

1. **Seams as protocols carrying the authority contract** (§3.2). This is the
   piece that makes every later step safe, and it works today.
2. **The seam table as a value** (§3.3) — one provider per seam, replacement
   explicit and singular, swappable at runtime. Dynamism without letting order
   decide.
3. **Model-visible ⟺ logged**, with `request/assemble` bounded so it cannot read
   around the log. A live system that can be recomposed at 3am needs replay more
   than a static one does, not less.
4. **Runtime plugin install via `$runtime/load_sandboxed`**, with `grants` as the
   operator-readable statement of what the new code may reach.
5. **Disposers on `provide`** (§3.7), once enough plugins exist that replacement
   leaks something.

Two small language gaps this design would like closed, neither blocking:
`Map` key removal, and the removal-symmetric form of reload that
`docs/scoped-impls.md` §6 already anticipates as module unload.

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

## Sources

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- [deepseek-harness AGENTS.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/AGENTS.md)
- [deepseek-harness docs/architecture.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md)
- [cordiverse/cordis](https://github.com/cordiverse/cordis)
- [DeepSeek open sources an agent harness where everything is a plugin — The New Stack](https://thenewstack.io/deepseek-harness-open-source-plugins/)
- [DeepSeek Harness developer preview](https://deepseek.com/harness/en/)
