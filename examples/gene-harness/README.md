# gene-harness

A living plugin harness: seams, an effect ledger, and atomic activation.

```bash
# an interactive harness. `help` lists the commands; `quit`, `exit` or Ctrl-D
# leaves. Run it from the package directory so a capability row naming
# `plugins/generated` means this one.
cd examples/gene-harness
gene run --allow_read_dir /tmp src/main.gene cli

# the same shell with a real model behind the prompt (OpenRouter)
OPENROUTER_KEY=$(cat ~/.secrets/openrouter) \
  gene run --allow_read_dir /tmp src/main.gene chat

# one-shot: anything after the profile name is a prompt
gene run src/main.gene web status

# boot a deployment and print what came up
gene run src/main.gene web
gene run src/main.gene cli            # same profile, no grant

# the tour: every line it prints is a claimed property
gene run src/demo.gene
gene run --allow_read_dir /tmp src/demo.gene
```

Run the entry point three ways. `web` and `cli` differ in their providers; the
third command boots `cli` without the authority it needs, and the interesting
thing is what happens: the boot succeeds, two plugins are `ready`, and the one
that wanted the grant sits in `error` with `declaration requires fs/ReadDir` in
the log. A missing grant costs one plugin, not the process.

Run the tour both ways too. The only lines that change — four of them — are the
ones where the local filesystem provider is asked to do its job, which is the
point.

The design and the argument behind it are in [`docs/design.md`](docs/design.md),
which also compares this to DeepSeek's `dsh` and says which of its ideas are
worth taking.

## What it is

A plugin architecture written as a subsystem — `Plugin` and `Harness` are types,
not a mapping onto packages and scoped impls. Those distribute and compile code;
this is about what happens at runtime.

| File | Role |
|---|---|
| `src/kernel.gene` | The kernel: lifecycle, the effect ledger, seam binding, replacement |
| `src/seams.gene` | One seam, all three roles: a protocol with an authority contract, two providers, a consumer |
| `src/main.gene` | The entry point: boot a named profile, then modify the running harness |
| `src/profile.gene` | What a `Profile` is, and how to boot one |
| `src/profiles.gene` | The registry: which profiles exist, by name |
| `src/profiles/cli.gene`, `web.gene` | One deployment each — sets of plugins, not layers |
| `src/profiles/common.gene` | Plugins every deployment installs |
| `src/agent.gene` | The offline `HarnessPrompt` provider: what a prompt means |
| `src/llm.gene` | The other one: OpenRouter, `deepseek/deepseek-v4-flash-0731` |
| `src/repl.gene` | The terminal driver, bound as a `Driver` seam by `cli` |
| `plugins/generated/` | Plugins the harness writes for itself, at runtime |
| `src/demo.gene` | A runnable tour; every line it prints is a claimed property |
| `plugins/fs_stub/` | An out-of-tree plugin loaded at runtime, granted nothing |
| `plugins/fs_rogue/` | The same, but reaching for `$fs` — kept honest by being run |
| `docs/design.md` | Why it is shaped this way, and what is still missing |

## The ideas

**A plugin is a value.** An id, the seams it claims, the seams it needs, and two
entry points — not a module. So it can come from a runtime-loaded file, a
package dependency, or a literal built in memory for a test.

**The kernel owns an effect ledger.** Plugins never touch the tables; they
contribute through `provide`, and every contribution is recorded against the
plugin id. The ledger holds *records*, not disposer closures, which makes "what
has this plugin registered?" a query and the ledger serializable.

**Activation is all-or-nothing, and a failure is a state.** A plugin that fails
part-way through `activate` leaves nothing behind, because the kernel knows what
it registered and reverses it without the plugin's cooperation. A plugin cannot
forget to clean up, because cleanup was never its job. What it does leave behind
is *itself*, in `error`, next to the log line explaining why — a failure that
erases its own subject is one you cannot investigate. Nothing retries it on its
own, because an `activate` that raised will raise again until something outside
it changes; `retry` is the operator saying it did.

The mirror image: `deactivate` is advisory. If it raises, the failure is logged
and the removal proceeds as planned, because the kernel does not depend on the
hook — the ledger reverses every registration either way.

Binding is explicit: a seam already bound is refused rather than shadowed, so no
registration order decides behaviour. Changing a provider is `replace` — a named
operation an operator asked for, not a layer that wins by arriving later. The
ledger entry moves with the binding, so uninstalling a seam's former owner
cannot unbind a seam it no longer provides.

**A seam is a protocol, and the protocol carries the authority contract.** This
is the part TypeScript cannot copy. `HarnessFs` declares
`^capabilities [(fs/ReadDir "/tmp")]` once; a provider may restate it or declare
less, and the compiler rejects an impl that declares more — or that declares
nothing, since an absent row means unchecked authority. So a provider is bounded
by the interface it implements rather than by its own good manners, and the
in-memory test double advertises `^capabilities []` where a reviewer can see it.

The consumer names only the protocol. Swapping the provider therefore changes
what the consumer does *and* what authority the whole product needs, without the
consumer being touched — which is why the two commands above differ on exactly
one line.

**A plugin can arrive at runtime, bounded by grants.** `install_sandboxed` loads
a module from outside `src/` with `$runtime/load_sandboxed`. `grants` is the
operator-readable statement of reach — `[]` means the code cannot name `$fs`,
`$net`, or `$os` at all — and `shared` names the one file holding the seam
protocol, so the plugin implements *this* `HarnessFs` rather than a recompiled
copy of it. The same binding rules apply to code that arrived late: a bound seam
is refused, not shadowed.

`plugins/fs_rogue/` exists to keep that claim honest, and running it corrected
it. The boundary holds — the file is never read — but the plugin *loads* and
fails at the first call with `value is not callable: vkVoid`, because a denied
namespace is absent and the name fails where it is used. Timing and diagnostic,
recorded in [`docs/design.md`](docs/design.md) §5.

**The ledger reverses more than seams.** An observer plugin contributes no seam
— it subscribes to the harness event bus — and uninstalling it cancels the
subscription without its cooperation. A listener outliving its plugin is the
classic plugin-system leak; here it cannot happen, because registering the
subscription *is* recording it. The bus is for observation and the seams are
for substitution, and neither does the other's job.

**A plugin declares what it needs, and the kernel settles.** `requires` names
*seams*, never plugin ids, so a dependency survives the provider being swapped —
which is the whole reason to have seams. From there the kernel is a state
machine rather than a sequence: a plugin is `pending` until the seams it needs
are bound, then `ready`. `settle` runs after every change and drives the table
to a fixpoint, demoting before promoting so a cascade cannot churn.

Three things fall out. **Install order stops mattering** — three plugins
installed in reverse dependency order settle exactly as three installed in
order, which is what an ordered bundle-layer scheme tries to buy with
configuration. **Withdrawal cascades reversibly** — remove a provider and its
dependents return to `pending`, not to uninstalled, because what went away was
their dependency and not the operator's intent; put it back and the chain comes
back. **A dependency cycle is `pending`**, not a hang and not an error: neither
plugin can go first, so neither does, and both say so.

`activate` gets the one guarantee that matters at the call site — every seam in
`requires` is bound before it runs — so plugin code resolves what it needs
without a defensive check. Every transition goes out on the event bus
(`PluginActivated`, `PluginDeactivated`, `PluginFailed`, …) and into the session
log under `^kind "lifecycle"`, so a plugin can watch its own dependencies come
and go and the kernel need know nothing about it.

**A profile is a set, not a stack of patches.** `cli` and `web` name the plugins
a deployment starts with: `cli` binds a real filesystem provider that declares
`(fs/ReadDir "/tmp")` and renders plain text, `web` binds an in-memory provider
that declares `^capabilities []` and renders escaped HTML. The consumer is *the
same plugin value* in both — it requires two seams and names no provider, so
what differs between deployments is only what it stands on.

Booting is a loop over the set. There is no merge step, no precedence rule, and
nothing to `--dump-config`, because the profile *is* the configuration.

Deployments share composition by **importing the same factory, not by patching a
base**: `profiles/common.gene` holds the plugins both install. There is no
"web = cli plus X", because that is a layer. The failure mode of layers is that
you cannot tell what a deployment runs without replaying the merge; the failure
mode here is a slightly longer list, in one file, that you can read. That is
possible only because the kernel settles: `boot_reversed` boots the same profile
backwards and must reach the same state, which is the claim being tested rather
than asserted. Ordered layer schemes exist to control an ordering that here has
no effect.

Modifying a booted harness is `install`, `uninstall`, and `replace` — named
operations on a live system, not a layer that wins by arriving later. Swap the
`render` plugin for the other profile's and the reporter re-derives itself
against the new provider, report and all, without a reboot.

**A prompt is a seam, and the harness can extend itself through it.** `cli` is an
interactive shell: it reads a line, hands it to whatever is bound to
`HarnessPrompt`, and prints the answer. The loop is thirty lines and knows
nothing about what any prompt means — a real deployment binds a model there;
this repo binds a command interpreter. The driver is itself a plugin providing a
`Driver` seam, so "is this deployment interactive?" is a binding rather than a
flag: `web` installs the same agent and no driver.

The interesting command is `build`, which writes a new plugin and loads it into
the running process:

```
harness>
build greet a plugin written from a prompt
installed greet (ready)

harness>
tool greet world
greet(world) -> a plugin written from a prompt

harness>
unload greet

harness>
tools
[]
```

The last part is the ledger doing its job on code that did not exist when the
process started. Three things bound this and only one is a grant: the generated
plugin must live inside the package (`load_sandboxed` refuses a sandbox
directory that escapes the package root), it is loaded with `grants []` so it
cannot name `$fs`, `$net`, or `$os`, and everything it registers is reversible
by the kernel. Writing inside the package needs no flag — a package may modify
itself; reaching outside it is authority.

**And a real model is one plugin away — with no tool list.** The `chat` profile
is `cli` with the offline interpreter swapped for an OpenRouter client. The
model's only way to act is to emit a Gene program, in the shape
`examples/safe_ai_agent` uses:

```
{^status "done"|"in-progress" ^response "one sentence" ^code (do ...)}
```

`^code` is evaluated against the **running harness**. The bindings are the
kernel's own vocabulary — `h` itself, `install`, `uninstall`, `provide`,
`replace`, `resolve`, `subscribe`, `install_sandboxed`, the `Plugin` type, the
seams and their providers — the same names `src/profiles/` uses to compose a
deployment. So there is nothing to select from:

```
install a plugin named echo whose Tool:echo seam is a function returning
whatever string it is given, then call it with hi
   Echo plugin installed and tested.
   (do (install h (Plugin ^id "echo" ^provides ["Tool:echo"]
         ^activate (fn [] (fn [hh id] (provide hh id "Tool:echo" (fn [s] s))))))
       ((resolve h "Tool:echo") "hi"))
hi

now remove it and prove the seam is gone
   (do (uninstall h "echo") (var gp (seam_bound h "Tool:echo")) (plugin_states h))
["fs:ready" "render:ready" "reporter:ready" "agent:ready" "driver:ready"]
```

**Structural authority is total; host authority is narrow.** Rebuilding the
harness needs no grant — that is what the model is for. Reaching outside the
process is the Env's capability row, which is resolved against this module's
context and can never name more than the harness already holds:

```
($os/get_env "HOME")            refused: os/get_env needs os/Env
($fs/read_text "/etc/passwd")   refused: fs/read_text needs fs/ReadFile
(install h (Plugin ...))        ["HarnessFs" "HarnessRender" "Tool:x"]
```

A refusal is a *value*, so the model sees it and tries something else. The row
also re-roots relative paths at `plugins/generated/`, which is how the harness
writes and loads code that did not exist at boot.

**Model-visible ⟺ logged.** The invariant worth taking verbatim from `dsh`.
Anything that reaches a model request must be reconstructible from the session
log, and `assemble_request` makes that structural: it takes the log and nothing
else, and declares `^capabilities []`, so an assembler that reached for a file
or the environment would be refused at its own declaration. Replay is a fold
over the log — uninstall the provider that produced a message and the assembled
request is unchanged.

## Not done yet

The seam *table* is keyed by a plain string and holds `Any`, so the kernel
itself cannot check conformance. It does not need to: a protocol works as an
annotation, so the seam definition supplies its own gate (`fs_provider`) and a
non-conforming provider is refused where it is bound. Making the table hold the
protocol instead would move that check into the kernel and is the tidier end
state.

Module unload is deferred: uninstall removes a plugin's contributions, and its
code stays resident (`docs/scoped-impls.md` §6).
