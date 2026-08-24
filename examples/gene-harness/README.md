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

The `chat` profile swaps in the OpenRouter model provider:

```bash
OPENROUTER_API_KEY=... \
  bin/gene run examples/gene-harness/src/main.gene chat
```

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

Run a separate process with the same home:

```bash
GENE_HARNESS_HOME=examples/gene-harness/tmp/demo \
  bin/gene run examples/gene-harness/src/main.gene web tool greet world
```

```text
greet(world) -> hello from a generated plugin
```

The source was never assembled by string concatenation. `plugin_source`
produces a quoted AST; `register_module` validates and canonicalizes it, writes
a SHA-256 module blob with atomic replacement, commits a composition generation
by an exclusive revision claim, and only then activates it.

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

- seams
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
| `src/repl.gene` | terminal subscriber and active-view handoff |
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
