# DeepSeek Harness, and what a Gene Harness should take from it

Status: proposal; §4 items 1 and 2 are built and runnable in `../src/`.

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
`examples/gene-harness/src/` demonstrates exactly this: run `src/main.gene`
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
(type Plugin  ^props {^id Str ^provides (List Str)
                      ^activate Any ^deactivate Any?})
(type Harness ^props {^seams Any ^plugins Any ^effects Any})
(type HarnessError ^props {^message Str} ^impl [Error])
```

A plugin is a **value**, not a module: an id, the seams it claims, and two entry
points. That is what makes it installable from anywhere — a file loaded at
runtime, a package dependency, or a literal built in memory for a test.

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
(fn install [h : Harness, p : Plugin] : Str
  (var plugins (h/plugins ~ get))
  (if_yes (!= (plugins ~ get p/id) void)
    (fail (HarnessError ^message $"plugin ${p/id} already installed")))
  (try
    ((p/activate) h p/id)
    (plugins ~ put p/id p)
    $"installed ${p/id}"
    catch e
    (unwind h p/id)
    (fail (HarnessError ^message $"activate ${p/id} failed: ${e/message}"))))
```

This is not "reuse `try`". `try` is the local mechanism; the *architecture* is
that the kernel knows what the plugin registered and can reverse it without the
plugin's cooperation. A plugin cannot forget to clean up, because cleanup was
never its job.

Measured, from the prototype — a plugin that registers one seam and then fails:

```
install good  : installed fs_local
resolve Fs    : LOCAL-FS
install combo : installed combo
installed     : ["fs_local" "combo"]
install bad   : refused: activate broken failed: boom during activate
Log rolled back? yes — no provider left behind
installed     : ["fs_local" "combo"]
double install: refused: plugin fs_local already installed
uninstall combo: uninstalled combo
Llm gone?      : yes
Fs still there : LOCAL-FS
installed      : ["fs_local"]
```

Every line is a property the design claims: atomic activation, no partial
registration, one provider per seam, uninstall that removes exactly one
plugin's contributions and leaves its neighbour's intact.

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

### 3.7 Reversible effects — closed by the ledger

An earlier draft listed this as the one language gap, wanting a Gene equivalent
of `ctx.effect()`. Writing the kernel closed it without a language change: the
ledger *is* the reverse path, and because it holds records rather than closures
it needs nothing from the language beyond a map and a list.

What remains is breadth, not mechanism. `reverse_effect` knows one kind today
(`seam`); a real harness adds `tool`, `event-subscription`, `route`, and each is
a new arm in one function the kernel owns. That is the right place for the
knowledge — a plugin that invents an effect the kernel cannot reverse should not
be able to register it.

## 4. Recommendation

Build the harness as a **living application**: it boots from a profile and is
modifiable from then on. Adopt, in this order:

1. **Seams as protocols carrying the authority contract** (§3.2). This is the
   piece that makes every later step safe. **Built** — `src/seams.gene` is the
   three-role seam (definition, two providers, one consumer) and `src/main.gene`
   swaps the provider live and shows the authority change that comes with it.
2. **The kernel as code** (§3.3) — `Plugin` and `Harness` as types, an effect
   ledger the kernel owns, atomic activation, explicit binding. Not a mapping
   onto packages or scoped impls: those distribute and compile code, while this
   is about what happens at runtime. **Built** — `src/kernel.gene`, including
   the `replace` operation §3.3.3 calls for, which moves the ledger entry with
   the binding so uninstalling a seam's *former* owner cannot unbind it.
3. **Model-visible ⟺ logged**, with `request/assemble` bounded so it cannot read
   around the log. A live system that can be recomposed at 3am needs replay more
   than a static one does, not less.
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
   leaks something.

One language gap this design would like closed, not blocking: the
removal-symmetric form of reload that `docs/scoped-impls.md` §6 already
anticipates as module unload — which reclaims a removed plugin's *code*, where
the ledger only reclaims its *contributions*. (`Map` key removal, the other gap
this document originally named, is now implemented; the two runtime defects in
§5 are separate and worth fixing on their own.)

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

  Verified by `plugins/fs_rogue/`, which `src/main.gene` loads and calls; the
  transcript above is its real output. This entry exists because the claim was
  asserted in the design before it was run, and running it changed it.


Recorded because they were found by writing the kernel rather than reasoning
about it, and because two of them shaped the design above.

- **SIGSEGV in the VM, cross-module — and it is a closure-lifetime bug.** The
  first two-file prototype crashed in `acquireSimpleCallScope` /
  `nimIncRefCyclic`, reproducibly (2/2), while the same code in one file ran
  fine. Minimal cases — a closure in a type prop called across modules,
  cross-module `fail`/`try` with an imported error type — did not reproduce it.

  The diagnosis arrived by accident. `src/kernel.gene` and `src/main.gene` are
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
