# Gene Harness

A durable, capability-bounded plugin harness for a general-purpose Gene agent.
It can add code while running, stop, and restore the same composition and
plugin state at the last committed turn boundary.

The browser client and terminal share the same agent, commands, plugins, and
durable stores. The browser's state, rendering, and interactions are written in
Gene and compiled to browser modules automatically when the server starts.

`new_cordis_harness` uses isolated registry
drafts, selected-entry dependencies, revision-owned callbacks, and generated
modules loaded through Cordis sandbox generations. The deterministic integration
path exercises the real registration and turn APIs, durable replacement, failed
activation with old tools retained, fresh-process restore, and process death
between desired CAS and live reconciliation. The command-line profile entry
uses `new_harness`; `new_cordis_harness` selects the Cordis implementation.

On the Cordis path, `workspace_status` reports desired and active revisions.
Doctor includes both revisions when reconciliation fails. Post-commit failures
report `recovery_required` with the original cause; they do not attempt to abort
an already published registry transaction or rewrite CURRENT backward.

Entry dependencies are revision-sensitive: removing or replacing the selected
row retires or refreshes dependent activations. For nonunique registries, the
binding selects the same first row as registry lookup. Reactivation restores
registrations; it does not repeat model or tool operations. Dynamic seam
discovery through `PluginHost.resolve` remains separate from declared
activation dependencies.

The implementation follows [docs/design.md](docs/design.md); the normative
design is [`tmp/harness.md`](../../tmp/harness.md).

The local browser client follows [the browser-client design](docs/web-client.md).
The existing `web` profile below is an offline memory/HTML deployment example;
it does not start a web server or provide a browser interface.

## Browser client

Start the agent from the repository root using your existing Codex login:

```sh
bin/gene run --allow_read_dir "${CODEX_HOME:-$HOME/.codex}" \
  examples/gene-harness/src/web/server.gene
```

Write any prompt in the composer. Ordinary text, including a single word such
as `help`, goes to the model. A leading slash selects special functionality:
`/help`, `/status`, `/code`, `/build`, and the other registered commands. Leading
whitespace before a slash is allowed. Unknown slash commands show command help
guidance without contacting the model.

Each model step includes a **Raw LLM response · Step N** disclosure, collapsed
by default. Expand it to inspect or copy the returned reply before Gene parsing,
including invalid replies that triggered another attempt. Its expansion state
survives transcript updates; switching conversations resets disclosures.
The raw reply uses the same durable transcript and display limits as other
output, and is kept separate from the assistant's readable answer.

Open the connection link printed by the server. It binds `127.0.0.1:8095` and
uses a one-use connection token, then an HttpOnly browser cookie. Use
`--port 8096` to choose another port. The link expires after ten minutes; a
connected browser session lasts eight hours. Reloading preserves conversations
and per-session drafts. Closing a tab does not stop a run; use **Stop**.

The browser uses the same provider variables and grants as the `chat` profile.
To use a state home outside the repository with Codex:

```sh
mkdir -p /tmp/harness-web
(
  cd examples/gene-harness
  GENE_HARNESS_HOME=/tmp/harness-web GENE_HARNESS_PROVIDER=codex \
    ../../bin/gene run --allow_read_write_dir /tmp/harness-web \
    --allow_read_dir "${CODEX_HOME:-$HOME/.codex}" \
    --allow_read_dir "$PWD/../../tools/gene-lang-skill" \
    src/web/server.gene
)
```

For OpenRouter, set `GENE_HARNESS_PROVIDER=openrouter` and
`OPENROUTER_API_KEY`; the Codex-directory grant is then unnecessary. Credentials
remain in the native process. `GENE_HARNESS_MODEL` and
`GENE_HARNESS_THINKING_EFFORT` keep their existing meanings.

`--offline` (or `GENE_HARNESS_OFFLINE=1`) deliberately selects a **command-only
demo**, with a visible notice in the browser. It supports `/help`, `/status`,
direct `/code`, and template-based `/build`, and cannot answer general prompts. Omit this
option and unset that environment variable for agent conversations.

The client supports creating/renaming sessions, retained history, Gene code and
result blocks, command suggestions, cancellation, and reconnect. One run is
admitted at a time. A browser and CLI cannot simultaneously own the same session.
Session claims are kernel-released on process exit; leave files under
`<home>/claims` in place. New session/run projections use event-manifest format
2; older homes are readable, but an older Harness binary cannot open a home
after this upgrade.

Use `--home <path>` or `GENE_HARNESS_HOME` to select a workspace. A path outside
the launch directory still needs a matching `--allow_read_write_dir` grant.
Remote access, multi-user hosting, graphical plugin administration, and live
model token streaming are outside this release.

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

The `chat` profile uses a model for both conversation and writing plugins.
It supports Codex OAuth credentials from disk and OpenRouter API keys. With no
OpenRouter key configured, it selects Codex; set `GENE_HARNESS_PROVIDER` to
choose explicitly when both credentials are available.

For Codex, first sign in with ChatGPT and file credential storage:

```bash
codex -c cli_auth_credentials_store='"file"' login
mkdir -p /tmp/harness-chat
(
  cd examples/gene-harness
  GENE_HARNESS_HOME=/tmp/harness-chat GENE_HARNESS_PROVIDER=codex \
    ../../bin/gene run --allow_read_write_dir /tmp/harness-chat \
    --allow_read_dir "${CODEX_HOME:-$HOME/.codex}" \
    --allow_read_dir "$PWD/../../tools/gene-lang-skill" \
    src/main.gene chat
)
```

The client reads `CODEX_AUTH_FILE`, or `auth.json` under `CODEX_HOME` (default
`~/.codex`). The file must contain `tokens.access_token` and `tokens.account_id`;
API-key-only files and OS keychain credentials are not used. For a custom
`CODEX_AUTH_FILE`, grant its containing directory instead. Credentials are
reloaded for each request; Codex owns token refresh, and a 401 asks you to run
`codex login` again. The harness never writes the auth file or stores tokens in
conversation history. See [Codex credential storage](https://developers.openai.com/codex/auth/).

OpenRouter remains available with either existing key spelling:

```bash
mkdir -p /tmp/harness-chat
(
  cd examples/gene-harness
  GENE_HARNESS_HOME=/tmp/harness-chat OPENROUTER_API_KEY=... \
    ../../bin/gene run --allow_read_write_dir /tmp/harness-chat \
    --allow_read_dir "$PWD/../../tools/gene-lang-skill" \
    src/main.gene chat
)
```

Both paths load the checked-in Gene skill for the agent and plugin author.
Run from the package directory: running from the repository root makes the
automatic launch-directory grant overlap the explicit skill grant, and file
reads are refused as ambiguous. The subshells above keep your shell at the
repository root afterward. Use an external state home to avoid overlapping
grants there too; these commands share `/tmp/harness-chat`.

| Environment variable | Behavior |
|---|---|
| `GENE_HARNESS_PROVIDER` | `codex` or `openrouter`. If unset, an OpenRouter key selects OpenRouter; otherwise Codex. |
| `GENE_HARNESS_MODEL` | Model for both chat and plugin generation. Default: `gpt-6-astra` for Codex, `openai/gpt-6-astra` for OpenRouter. Supply the provider's exact model ID. |
| `GENE_HARNESS_THINKING_EFFORT` | Default: `medium`. Accepts `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`; support depends on the chosen model/provider. |
| `CODEX_AUTH_FILE` | Explicit path to the Codex OAuth JSON file; overrides `CODEX_HOME`. |
| `CODEX_HOME` | Codex configuration directory; defaults to `$HOME/.codex`. |
| `OPENROUTER_API_KEY`, `OPENROUTER_KEY` | OpenRouter key; the first nonempty value wins. |
| `OPENROUTER_MODEL` | Existing OpenRouter model override; used when `GENE_HARNESS_MODEL` is unset. |

Empty or whitespace-only settings use their defaults. For example, add
`GENE_HARNESS_MODEL=gpt-6-astra GENE_HARNESS_THINKING_EFFORT=high` to the Codex
command. Astra supports `low`, `medium`, `high`, `xhigh`, and `max` effort.
See [the model reference](https://developers.openai.com/api/docs/models/gpt-6-astra).

Codex requests use its Responses endpoint with `store=false` and streaming.
The client waits for a completed response before returning text to the harness;
failed or interrupted streams cannot execute partial programs. OpenRouter
continues to use Chat Completions. The existing 3,000-token request budget
applies to OpenRouter; Codex does not accept that token-limit parameter. Both
transports retain the 90-second timeout and 2 MB response limit.

## Run Gene code directly

Use `/code` to execute Gene without a model request:

```text
/code (+ 1 2)
/code (plugin_states)
```

The first returns `3`. Multiple forms and multiline code are supported:

```text
/code
# Comments and string spacing are preserved.
(var greeting "hello  world")
($str/byte_size greeting)
```

This returns `12`. All forms are parsed before execution and run together in
one workspace turn. The source appears as a Gene code block and the last value
is returned to the conversation. `/code` without source shows usage.

The command is available in browser, chat, CLI, and offline profiles, and
appears in `/help` and the browser's slash-command picker. It shares the
model executor's harness bindings, capabilities, and transaction handling.
Evaluation is bounded to 25,000 steps, 32 MB, and one second, leaving room in
the command's outer budget for cleanup. Each invocation has a fresh local
scope; use the harness helpers for lasting changes. Syntax and execution
errors are shown as results.
Queued module registrations default to `program/user` provenance with no model
name. Explicit author fields on a registration still take precedence.

For a command-line invocation:

```sh
bin/gene run examples/gene-harness/src/main.gene web /code '(+ 1 2)'
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

`build` does not know how to write a plugin. It resolves the `HarnessCodegen`
seam and registers whatever comes back, so what the command *means* is a
property of the deployment: `web` and `cli` bind a template provider, and `chat`
binds one that asks the model to write the module.

```bash
(
  cd examples/gene-harness
  GENE_HARNESS_HOME=/tmp/harness-chat OPENROUTER_API_KEY=... \
    ../../bin/gene run --allow_read_write_dir /tmp/harness-chat \
    --allow_read_dir "$PWD/../../tools/gene-lang-skill" \
    src/main.gene chat \
    /build wordcount "count the words in the argument and report the total"
)
```

```text
registered wordcount at revision 1 (ready)
```

```text
$ ... web tool wordcount "the quick brown fox jumps over the lazy dog"
word count: 9
```

The `/` prefix selects the command interpreter; every prompt without it goes
to the model as a task. Registration proves the module's shape and that its `init` runs, but
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

## Tools from callable contracts

The `src/agents/reflection.gene` module builds a tool row from an ordinary function
or checked `Callable` view. It derives parameter documentation and an input
schema without evaluating defaults:

```gene
(import * : reflect ^from "./src/agents/reflection")
(fn search [query : Str, ^limit : Int = 10] : Str query)
(contribute h "search_plugin" "tools" (reflect/tool_row "search" search))
(invoke_registry_row h "tools" "search"
  [{^positional ["gene"] ^named {}}])
```

The input is an envelope containing `positional` and `named`. Omitted
arguments reach the target unchanged, so its defaults run at invocation.
The existing registry owner, capability, and execution-budget boundaries
still govern the call. A signature or an external schema does not authorize
execution or replace the target's type checks.

Automatic input schemas cover `Str`, `Int`, `Float`, `Bool`, `Nil`, optional
types, and typed Lists. Other parameter contracts require an explicit
`^input_schema`; unsupported callable shapes are rejected. Gene maps remove
Void entries, so the named input envelope distinguishes omission from nil
but cannot transport a named Void. Use ordinary direct invocation for that
case. See [the reflection contract](../../docs/spec/calls.md#callable-reflection).

## Generated plugin contract

Generated code imports the data-only stable API and returns a descriptor from
capability-empty `init`. Kernel sharing is allowed only for the `PluginHost`
impl identity:

```gene
(mod plugin
  (import [Plugin DescriptorContext PluginContext PluginHost]
    ^from "../../../src/plugin_api")
  (import_impl PluginHost for PluginContext ^from "../../../src/kernel")

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
            (host .PluginHost:contribute "tools"
              {^name "echo" ^doc "echo text" ^run (fn [text] text)}))))))
```

`DescriptorContext` is inert: no discovery, contribution API, or authority.
`PluginContext` is the later unforgeable token-backed host interface, not the
raw harness. It supports discovery, owned registries/contributions, seam
operations, subscriptions, schema-validated event emission, and core-owned
durable state. The context expires on demotion or uninstall.

Generated command and view callbacks receive that retained context, not the
Harness. Model code receives the complete live Harness as `harness` (also `h`),
plus helpers already bound to the current transaction.
Deactivation and registry cleanup receive the still-valid owner context.
Repeated module replacements in one turn coalesce, so only the final committed
descriptor activates.

## Model reply format

Every model reply is exactly one Gene data map, using straight double quotes
and no surrounding prose or Markdown fence:

```gene
{^type "code-with-response"
 ^response "I will count the supplied items."
 ^code (do (var data (get_payload)) data/items/.size)
 ^payload {^items ["a" "b" "c"]}}
```

| `^type` | Required fields | Behavior |
|---|---|---|
| `"code"` | `^code (do ...)` | Executes and sends the result back to the model for another round. |
| `"code-with-response"` | `^code (do ...)` | Executes and returns the execution result directly as the final response. |
| `"response"` | `^response "..."` | Returns the text and finishes without executing code. |

**Both code types may include an optional `^response` string.** It is shown
before execution to explain what is happening. For `code-with-response`, that
explanation accompanies the code; the execution result is still the final
answer. Omitting `^response` is valid for either code type, including:

```gene
{^type "code-with-response" ^code (do (+ 1 2))}
```

`^payload` is optional for all three types and must be a map when supplied.
An omitted payload becomes a fresh `{}` each execution. Payload values are
read as inert data, including embedded Gene nodes. Only a validated `^code`
block is evaluated. Invalid types, malformed fields, extra top-level forms,
and the old `^status` format are rejected and explained to the model for
correction. A `code` reply always continues, even for `(do nil)`; the loop stops
after eight rounds if it never receives a final reply. Execution errors and
capability refusals are execution results, so `code-with-response` returns
those directly too. Session memory retains the final answer rather than the
progress explanation.

The plugin author uses this same envelope with `^type "response"` and an
inert module node in `^payload {^module (mod plugin ...)}`. The `build` consumer
extracts and validates that module through the existing registration path.

## What a model program may reach

| Binding | Value |
|---|---|
| `harness`, `h` | The complete live Harness instance, including its registry, plugin, log, transaction, event-store, and workspace fields. |
| `session` | Current session metadata: `id`, `scope`, the live `history` cell, and the agent's `state_host` PluginContext. |
| `payload` | This reply's payload map. |
| `(get_payload)` | Returns the same payload map. |
| `context` | `harness`, `workspace`, `session`, `payload`, the current user `prompt`, and one-based model `round`. |

For example, code can read `harness/event_stream`, inspect
`(harness/transaction .get)`, read `(session/history .get)`, or bind
`(var data (get_payload))` and use `data/name`. `Harness`, `PluginContext`, and
`PluginHost` are available for typed/protocol operations. The helpers such as
`plugin_states`, `resolve`, and `register_module` remain bound to this Harness
and take no `h` argument. Use those helpers for changes that should be staged
and rolled back by the effect ledger; direct mutation of Harness/session cells
is available but is not automatically transactional.

A reply's `^code` runs in an `Env` minted with the structural harness bindings
and `^capabilities []`. Structural authority is total — every binding is an
ordinary Gene call needing no grant, and the model may rebuild the harness with
them — while host authority is nil: reading a file or the environment comes back
as `refused: ...`, returned directly or sent to the next round according to type.

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

Generated composition entries record explicit supported interface versions,
defined in `src/runtime/interface_policy.gene`. Changes to implementation files alone
do not change those contracts. Incompatible public API changes require a new
version. Entries with unsupported interface versions are refused.

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

`src/` is grouped by responsibility. Start with `main.gene` for terminal boot
or `web/server.gene` for the browser host, then follow imports into these groups:

| Directory | Responsibility |
|---|---|
| `src/agents/` | prompt handling, commands, model transport/replies, plugin generation, callable reflection |
| `src/runtime/` | boot/shutdown, Cordis integration, interface policy, session ownership and run lifecycle |
| `src/storage/` | durable event streams, generated event catalog, workspace composition and module blobs |
| `src/views/` | typed view contract, terminal interaction and recording view |
| `src/profiles/` | profile type/boot, named-profile registry and deployment compositions |
| `src/web/` | HTTP entry point, page styling and the shared browser wire contract |
| `client/` | Gene modules compiled for the browser: interaction, transcript state and rendering |

`kernel.gene`, `plugin_api.gene`, and `seams.gene` stay at the source root.
Persisted generated plugins import these exact paths, and sandbox loading
shares their module identities. Keeping them stable lets existing workspaces
restore their plugins without rewriting stored source or changing its digest.

| Path | Responsibility |
|---|---|
| `src/kernel.gene` | registry, ledger, lifecycle, transaction/diff, PluginContext, output events |
| `src/plugin_api.gene` | stable generated-plugin types/protocol |
| `src/seams.gene` | filesystem, rendering, prompt and code-generation protocols and example providers |
| `src/runtime/cordis_adapter.gene`, `src/runtime/interface_policy.gene` | Cordis lifecycle integration and supported generated-plugin interface versions |
| `src/storage/state.gene` | scoped segmented event store and state projections |
| `src/storage/workspace.gene` | composition CAS, blobs, register/restore, quarantine |
| `src/agents/agent.gene` | command/tool registries and offline prompt provider |
| `src/agents/code_command.gene` | direct `/code` execution using the shared program executor |
| `src/agents/llm.gene` | model agent, plugin author, and registry-rendered prompt |
| `src/agents/model_client.gene` | Codex OAuth / OpenRouter transport and environment configuration |
| `src/agents/model_reply.gene` | shared Gene reply format, inert parsing, and field validation |
| `src/views/repl.gene` | terminal subscriber, one prompt and one line |
| `src/views/view_api.gene`, `src/views/recording_view.gene` | typed view contract and recording view |
| `src/agents/reflection.gene` | callable signatures, input schemas and reflected tool rows |
| `src/profiles/profile.gene`, `src/profiles/registry.gene` | profile type/boot and named-profile lookup; sibling files define deployments |
| `src/main.gene` | durable boot and irreducible recovery surface |
| `events.catalog`, `src/storage/generated_event_catalog.gene` | core persisted-event vocabulary source and generated validators |
| `src/web/server.gene`, `src/web/style.gene` | local HTTP host, authentication, page layout and styling |
| `src/runtime/session_host.gene`, `src/runtime/run_controller.gene` | session navigation, snapshots, durable admission and run lifecycle |
| `src/runtime/bootstrap.gene`, `src/runtime/session_claim.gene` | runtime lifecycle and exclusive session ownership |
| `client/main.gene`, `client/state.gene` | Gene browser UI, connection handling, drafts and bounded transcript state |

The former Harness scenarios have moved to `tmp/gene-harness-tests` in the
repository workspace. They are no longer a package test target.

Human-reviewed promotion into checked-in profiles and cross-workspace blob
sharing remain deferred.
