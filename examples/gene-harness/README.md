# Gene Harness

A durable, capability-bounded plugin harness for a general-purpose Gene agent.
It can add code while running, stop, and restore the same composition and
plugin state at the last committed turn boundary.

The implementation follows [docs/design.md](docs/design.md); the normative
design is [`tmp/harness.md`](../../tmp/harness.md).

## Quick start

From the repository root:

```bash
bin/gene run examples/gene-harness/src/main.gene web status
```

The default state home is `examples/gene-harness/tmp/workspace` and is ignored
by git. Choose another existing directory with `GENE_HARNESS_HOME`; an external
home needs an explicit host grant:

```bash
mkdir -p /tmp/my-gene-harness
GENE_HARNESS_HOME=/tmp/my-gene-harness \
  bin/gene run --allow_read_write_dir /tmp/my-gene-harness \
  examples/gene-harness/src/main.gene web status
```

The `cli` profile installs the terminal view:

```bash
bin/gene run examples/gene-harness/src/main.gene cli
```

The `chat` profile swaps in the OpenRouter model provider, and with it the
provider that writes plugins:

```bash
OPENROUTER_API_KEY=... \
  bin/gene run --allow_read_dir "$PWD/tools/gene-lang-skill" \
  examples/gene-harness/src/main.gene chat
```

The grant is for the checked-in Gene skill, which both the agent and the plugin
author send to the model. Note that a home inside the repository is covered by
two grants at once and is refused as ambiguous; give `chat` a home outside it.

## Durable self-extension

The offline command provider demonstrates the complete path:

```bash
GENE_HARNESS_HOME=examples/gene-harness/tmp/demo \
  bin/gene run examples/gene-harness/src/main.gene web \
  build greet "hello from a generated plugin"
```

This returns a committed revision and activates the plugin once:

```text
registered greet at revision 1 (ready)
```

`build` does not know how to write a plugin. It resolves the `HarnessCodegen`
seam and registers whatever comes back, so what the command *means* is a
property of the deployment: `web` and `cli` bind a template provider, and `chat`
binds one that asks the model to write the module.

```bash
GENE_HARNESS_HOME=/tmp/harness-chat OPENROUTER_API_KEY=... \
  bin/gene run --allow_read_write_dir /tmp/harness-chat \
  --allow_read_dir "$PWD/tools/gene-lang-skill" \
  examples/gene-harness/src/main.gene chat \
  /build wordcount "count the words in the argument and report the total"
```

```text
registered wordcount at revision 1 (ready)
```

```text
$ ... web tool wordcount "the quick brown fox jumps over the lazy dog"
word count: 9
```

The `/` prefix forces the command interpreter; without it a sentence goes to the
model as a task, which is the same distinction `bare_query?` draws everywhere
else. Registration proves the module's shape and that its `init` runs, but
nothing exercises `run` until it is invoked — so `build` calls the new tool twice,
with its own name and with the request text, and appends what it raised:

```text
registered shout at revision 7 (ready; first call raised: undefined symbol: and)
```

Those calls are safe to make because a generated tool holds `^capabilities []`
and runs under the module ceiling, and advisory because the arguments are
guesses. Two rather than one because a short probe proves less than it looks
like it does: a `shorten` tool passed on its own name and failed on anything
over twenty bytes, so the branch the request was about had never run.

Building the same name again replaces the entry at the next revision rather
than refusing it. There is no verb that releases a durable name — `disable`
takes an entry out of desired state and the name stays taken — so create-only
made iterating on a generated tool mean inventing a new name per attempt. The
old blob stays in the store and the change is recorded as `replaced`, so a
revision is still the unit you read back.

```text
$ ... web build greet "hello again"
registered greet at revision 2 (ready)
```

Each committed entry names its author. `build` asks the `HarnessCodegen`
provider who it is — provenance is provider knowledge, not something the
command can guess — and records it beside the module digest:

```gene
^by "codegen/model" ^model "anthropic/claude-sonnet-4.6" ^at "2026-08-26T11:05:45+04:00"
```

The template provider answers `^by "template" ^model ""`, which is the honest
answer for a module no model wrote.

Run a separate process with the same home:

```bash
GENE_HARNESS_HOME=examples/gene-harness/tmp/demo \
  bin/gene run examples/gene-harness/src/main.gene web tool greet world
```

```text
greet(world) -> hello from a generated plugin
```

The source was never assembled by string concatenation. A provider returns a
quoted AST — the template builds one with quasiquote, the model provider parses
its reply with `read_all` and never evaluates text — and `register_module`
validates and canonicalizes it, writes a SHA-256 module blob with atomic
replacement, commits a composition generation by an exclusive revision claim,
and only then activates it. Every check that made the template safe applies
unchanged to a model: a `(mod plugin ...)` root, an inert top level, a defined
`init`, imports inside the declared closure, and capability-empty `init` run
under the module ceiling. An author is untrusted by construction.

## What is durable

```text
<GENE_HARNESS_HOME>/
  composition/   desired-state generations and CURRENT
  modules/       immutable module Store records
  events/        scoped event segments, projections and CURRENT

plugins/generated/
  <workspace-sha256>/<module-sha256>.gene  verified loader cache (git-ignored)
```

Composition, code, and history are separate stores. Past programs are never
replayed. Session-scoped plugins restore from that session's event stream;
workspace-scoped plugins use the shared workspace stream.

Live fibers, tasks, sockets, subprocesses, and partial model responses are not
serialized. A cold recovery appends an interrupted boundary and resumes from
the last flushed commit. `CURRENT` is authoritative; even a complete generation
above it is unpublished crash debris and is never selected by restore.
The retained core log and the LLM provider's bounded conversation window are
both restored before activation; a completed `ask` flushes them together.

## Extension model

Everything dynamic is a registry row:

- seams (`HarnessFs`, `HarnessRender`, `HarnessPrompt`, `HarnessCodegen`)
- commands
- tools
- prompt sections
- views
- event types
- subscriptions

Rows have immutable IDs and owners. The ledger removes an owner's rows in
reverse acquisition order, invoking registry-specific cleanup. Plugin-created
registries are owned too; unloading their owner cascades through their rows.

`provide`, `replace`, and `resolve` remain readable seam helpers, but they now
operate on the `seams` registry. Commands and tools do not use hard-coded branch
chains or `Tool:*` prefixes. Help and model introspection render from the same
rows the dispatcher uses. `transaction_diff` (and `diff` within an active turn)
shows staged registry and composition changes before commit.

## Generated plugin contract

Generated code imports the data-only stable API and returns a descriptor from
capability-empty `init`. Kernel sharing is allowed only for the `PluginHost`
impl identity:

```gene
(mod plugin
  (import [Plugin DescriptorContext PluginContext PluginHost]
    from "../../../src/plugin_api")
  (import_impl PluginHost for PluginContext from "../../../src/kernel")

  (fn init [ctx : DescriptorContext] : Plugin
    ^capabilities []
    (Plugin
      ^id "echo"
      ^provides [["tools" "echo"]]
      ^requires []
      ^contextual true
      ^activate
        (fn []
          (fn [host]
            (host ~ PluginHost:contribute "tools"
              {^name "echo" ^doc "echo text" ^run (fn [text] text)}))))))
```

`DescriptorContext` is inert: no discovery, contribution API, or authority.
`PluginContext` is the later unforgeable token-backed host interface, not the
raw harness. It supports discovery, owned registries/contributions, seam
operations, subscriptions, schema-validated event emission, and core-owned
durable state. The context expires on demotion or uninstall.

Generated command and view callbacks receive that retained context, not the
Harness. Model code likewise receives Harness operations already bound to the
current transaction and has no mutable `h` record to edit around the ledger.
Deactivation and registry cleanup receive the still-valid owner context.
Repeated module replacements in one turn coalesce, so only the final committed
descriptor activates.

## What a model program may reach

A reply's `^code` runs in an `Env` minted with the structural harness bindings
and `^capabilities []`. Structural authority is total — every binding is an
ordinary Gene call needing no grant, and the model may rebuild the harness with
them — while host authority is nil: reading a file or the environment comes back
as `refused: ...`, a value the next round is shown.

`register_module` is the one operation that needs both. A grant only ever
attenuates, so a program can never recover the authority a registration wants
(hashing source, writing a blob, loading the module, running `init`); calling
straight through refused at `fs/exists?` and the whole turn was lost. The
binding therefore *queues* the module. The harness drains the queue after the
program returns, still inside the same turn but back under its own authority,
and commits and activates from there:

```text
(do (register_module "probe" (plugin_source "probe" "probe text")))
-- Result  --
queued probe; the harness registers it when this turn ends
registered probe at revision 1
```

The consequence is the one thing worth knowing before writing a program: a tool
registered this way is callable from the *next* program, not the one that
queued it. A registration that fails to load raises like any other error in the
turn body, so it never becomes a revision.

## Capability selectors

Composition stores inert selector data. It never stores or restores grants:

```gene
{^type "fs/ReadDir" ^root "workspace" ^path "docs"}
{^type "fs/ReadWriteDir" ^root "state" ^path "cache"}
```

`workspace` and `state` are fixed host-provided roots. Absolute paths and `..`
are rejected. Activation expands selectors and runs under `with_capabilities`,
resolved only by attenuation from the host ceiling. A namespace exposed in the
module sandbox is still not authority; native adapters check the active exact
grant.

Plugin `init`, activation, schemas, and cleanup run under transitive step,
timeout, and memory limits. The recovery boundary converts plugin panic into a
quarantine error. The policy is attached immutably to the sandbox module, so
escaped functions and direct typed protocol methods retain the same capability
ceiling and fresh execution budget. FFI and native compilation remain disabled.

A view row is called twice per *turn*, never once per session. `HarnessView`
has two messages — render the prompt, then handle the line — and `nil` from
either means "call me again". `main.gene` owns the loop, re-reads
`views/active` between turns (which is the whole of view replacement), and owns
the blocking read that sits between the two calls under no budget at all:
reading the process's own stdin is host authority, not a plugin's work.

Both halves of that mattered. A view that owned its loop spent a single
`^timeout_ms` on the entire conversation; a view that owned the read spent it
on the human's thinking time and expired at the keyboard. Neither message can
block on a person now, so bounding both is honest.

Workspace-scoped plugins have one live replica per Harness process and one
shared durable projection. They are not implicit cross-process singletons; a
globally singular resource must come from a provider offering an explicit
lease. Disjoint event streams merge on stale flush, while same-stream writes
raise a typed conflict instead of guessing at sequence order.

## Recovery commands

These commands belong to core and remain available even when command/view/model
plugins are broken:

```bash
bin/gene run examples/gene-harness/src/main.gene web doctor
bin/gene run examples/gene-harness/src/main.gene web disable <id>
bin/gene run examples/gene-harness/src/main.gene web enable <id>
```

A bad entry is quarantined with its reason; healthy siblings still activate.
Failure never silently rewrites desired state to disabled.

Generated descriptors and their event schemas are bounded-loaded before any
effectful baseline profile plugin activates. `disable`/`enable` run even earlier
and never activate the target on their recovery invocation. Cold turn repair
occurs only after catalog validation succeeds. Shutdown reverses live plugins
before stores are flushed and closed.

## Files

| Path | Responsibility |
|---|---|
| `src/kernel.gene` | registry, ledger, lifecycle, transaction/diff, PluginContext, output events |
| `src/plugin_api.gene` | stable generated-plugin types/protocol |
| `src/state.gene` | scoped segmented event store and state projections |
| `src/workspace.gene` | composition CAS, blobs, register/restore, quarantine |
| `src/agent.gene` | command/tool registries and offline prompt provider |
| `src/llm.gene` | OpenRouter provider and registry-rendered prompt |
| `src/repl.gene` | terminal subscriber, one prompt and one line |
| `src/view_api.gene`, `src/recording_view.gene` | typed view contract and recording view |
| `src/profile.gene`, `src/profiles/` | checked-in baseline profiles |
| `src/main.gene` | durable boot and irreducible recovery surface |
| `events.catalog` | core persisted-event vocabulary source |
| `tests/` | public-seam smoke programs |

## Verification

Harness tests are part of `tests/test_cli.nim`. They cover registry ownership,
transaction diff/commit/abort, event retention/catalog/concurrency/cold repair,
cross-process Store publication, content-addressed registration, dependency
closure and cache repair, quarantine, named-root attenuation, callback and
typed-provider supervision, plugin events, provenance, active views/output,
prompt-skill loading, and session/workspace state conflicts.

Run the focused programs directly while developing, then the repository gates:

```bash
python3 tools/generate_harness_event_catalog.py --check
nimble test
nimble spec
nimble perf
nimble wasm
```

Human-reviewed promotion into checked-in profiles, protocol migrations beyond
fingerprint refusal, and cross-workspace blob sharing remain deferred.
