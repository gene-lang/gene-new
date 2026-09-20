# Gene Harness

A durable, capability-bounded plugin harness for a general-purpose Gene agent.
It can add code while running, stop, and restore the same composition and
plugin state at the last committed turn boundary.

The browser client and terminal share the same agent, commands, plugins, and
durable stores. The browser's state, rendering, and interactions are written in
Gene and compiled to browser modules automatically when the server starts.

Plugin lifecycle is a Cordis composition (`examples/cordis`). Reconciles work
per plugin: an unchanged plugin stays live, a changed one restarts, and a failed
activation returns only that plugin to its last active revision. Activations
contribute directly to the live registries, with selected-entry dependencies,
revision-owned callbacks, and generated modules loaded through Cordis sandbox
generations. Profiles stage all of their plugins and reconcile once. The profile's `^limits` is the Cordis ceiling that every
plugin's limits narrow from.

`workspace_status` reports desired and active revisions.
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
design is [docs/design.md](docs/design.md); `tmp/harness.md` is historical.

The local browser client follows [the browser-client design](docs/web-client.md).
The existing `web` profile below is an offline memory/HTML deployment example;
it does not start a web server or provide a browser interface.

## Browser client

Start the agent from the repository root using your existing Codex login:

Write any prompt in the composer. Ordinary text, including a single word such
as `help`, goes to the model. A leading slash selects special functionality:
`/help`, `/status`, `/code`, `/build`, and the other registered commands. Leading
whitespace before a slash is allowed. Unknown slash commands show command help
guidance without contacting the model.

Each model step includes a **Raw LLM response · Step N** disclosure, collapsed
by default inside a compact **Step N** group with its code and result. Expand
the step and raw response to inspect or copy the returned reply before Gene parsing,
including invalid replies that triggered another attempt. Its expansion state
survives transcript updates; switching conversations resets disclosures.
Gene source and raw replies receive syntax colors when opened. Assistant
Markdown fences labelled `gene` use the same highlighting. Copy preserves the
original source, including whitespace and Unicode; incomplete replies remain
readable while streaming. Large blocks fall back to plain text without losing
content.
The raw reply uses the same durable transcript and display limits as other
output, and is kept separate from the assistant's readable answer.

File tool results show a source preview with the filename, real line breaks,
and a Copy code/Copy text button. `.gene` files and `/code` messages receive
syntax colors. The step still exposes the original serialized tool response
under Raw tool data; copying the source preserves its exact text and escapes.

Assistant answers render headings, lists, tables, links, and fenced code.
Each retained run keeps its completed, stopped, or failed outcome in the
conversation. Code errors offer **Edit and retry**, which restores the original
input without submitting it. Typing `/co` filters the picker to `/code`;
entering arguments or pressing Escape dismisses it. Utility commands such as
`/help` leave the title provisional until the first ordinary prompt supplies a
short title. Manual titles are preserved.

Open the connection link printed by the server. It binds `127.0.0.1:8095` and
uses a one-use connection token, then an HttpOnly browser cookie. Use
`--port 8096` to choose another port. The link expires after ten minutes; a
connected browser session lasts eight hours. Reloading preserves conversations
and per-session drafts. Closing a tab does not stop a run; use **Stop**.

The browser uses the same provider variables and grants as the `chat` profile.
To use a state home outside the repository with Codex:

For OpenRouter, set `GENE_HARNESS_PROVIDER=openrouter` and
`OPENROUTER_API_KEY`; the Codex-directory grant is then unnecessary. Credentials
remain in the native process. `GENE_HARNESS_MODEL` and
`GENE_HARNESS_THINKING_EFFORT` keep their existing meanings.

For Claude, use `GENE_HARNESS_PROVIDER=claude` with an authenticated local
Claude Code CLI, or `GENE_HARNESS_PROVIDER=anthropic` with `ANTHROPIC_API_KEY`.
Both support chat and plugin generation. See [Claude setup and subscription
details](docs/claude.md); the CLI owns its login, and the Harness does not read
Claude OAuth credentials.

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

Codex output text is streamed into the provisional **Raw LLM response** panel.
The completed reply replaces that preview using the same block ID. Gene code
executes only after the complete response and envelope have been validated.
OpenRouter currently delivers complete response blocks. Remote access,
multi-user hosting, and graphical plugin administration remain outside this release.

## Website

The Harness includes a product website written entirely in Gene: quoted node
markup, structured `$css` rules, and a web-profile enhancement module. The
browser host serves it at `/about/`, linked from the sidebar. The page needs no
connection link, and it reads no workspace records and makes no model call.

The same source can be exported for a static host:

```sh
bin/gene run examples/gene-harness/src/website/export.gene
bin/gene run examples/gene-harness/src/website/export.gene \
  --out examples/gene-harness/tmp/website-prefix/harness --base /harness/
```

The worked example is a recording of a real session. Its request, the formatted
model-authored plugin, the fixture project, and the expected outputs live in
`website/examples/project_audit/`. The page reads them when it renders, and a
model-free check re-verifies them against the Harness, including that the
formatted plugin canonicalizes to the recorded module digest:

```sh
bin/gene run examples/gene-harness/website/examples/project_audit/check.gene
```

## Quick start

From the repository root:

```bash
bin/gene run examples/gene-harness/src/main.gene web status
```

The default state home is `examples/gene-harness/tmp/workspace` and is ignored
by git. Choose another existing directory with `GENE_HARNESS_HOME`; an external
home needs an explicit host grant:

The `cli` profile installs the terminal view:

```bash
bin/gene run examples/gene-harness/src/main.gene cli
```

The `chat` profile uses a model for both conversation and writing plugins.
It supports Codex OAuth credentials from disk and OpenRouter API keys. With no
OpenRouter key configured, it selects Codex; set `GENE_HARNESS_PROVIDER` to
choose explicitly when both credentials are available.

For Codex, first sign in with ChatGPT and file credential storage:

The client reads `CODEX_AUTH_FILE`, or `auth.json` under `CODEX_HOME` (default
`~/.codex`). The file must contain `tokens.access_token` and `tokens.account_id`;
API-key-only files and OS keychain credentials are not used. For a custom
`CODEX_AUTH_FILE`, grant its containing directory instead. Credentials are
reloaded for each request; Codex owns token refresh, and a 401 asks you to run
`codex login` again. The harness never writes the auth file or stores tokens in
conversation history. See [Codex credential storage](https://developers.openai.com/codex/auth/).

OpenRouter remains available with either existing key spelling:

All model-backed profiles load the checked-in Gene skill for the agent and plugin author.
Run from the package directory: running from the repository root makes the
automatic launch-directory grant overlap the explicit skill grant, and file
reads are refused as ambiguous. The subshells above keep your shell at the
repository root afterward. Use an external state home to avoid overlapping
grants there too; these commands share `/tmp/harness-chat`.

| Environment variable | Behavior |
|---|---|
| `GENE_HARNESS_PROVIDER` | `codex`, `openrouter`, `claude` (local CLI), or `anthropic` (API). If unset, an OpenRouter key wins, then an Anthropic key, then Codex. CLI use is explicit. |
| `GENE_HARNESS_MODEL` | Model for chat and plugin generation. Defaults: `gpt-6-astra` (Codex), `openai/gpt-6-astra` (OpenRouter), `sonnet` (Claude CLI), `claude-sonnet-5` (Anthropic API). CLI aliases are resolved by Claude Code. |
| `GENE_HARNESS_THINKING_EFFORT` | Default: `medium`. Accepts `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`; model/provider support varies. Claude maps `minimal` to `low`; `none` disables thinking. |
| `GENE_HARNESS_CLAUDE_COMMAND` | Claude Code executable or path; defaults to `claude`. No shell parsing. |
| `ANTHROPIC_API_KEY` | API key for the native Anthropic provider; separate from Claude subscription authentication. |
| `CODEX_AUTH_FILE` | Explicit path to the Codex OAuth JSON file; overrides `CODEX_HOME`. |
| `CODEX_HOME` | Codex configuration directory; defaults to `$HOME/.codex`. |
| `OPENROUTER_API_KEY`, `OPENROUTER_KEY` | OpenRouter key; the first nonempty value wins. |
| `OPENROUTER_MODEL` | Existing OpenRouter model override; used when `GENE_HARNESS_MODEL` is unset. |

Empty or whitespace-only settings use their defaults. For example, add
`GENE_HARNESS_MODEL=gpt-6-astra GENE_HARNESS_THINKING_EFFORT=high` to the Codex
command. Astra supports `low`, `medium`, `high`, `xhigh`, and `max` effort.
See [the model reference](https://developers.openai.com/api/docs/models/gpt-6-astra).

Codex requests use its Responses endpoint with `store=false` and streaming.
The client forwards output-text deltas as provisional previews and waits for a
completed response before returning executable text to the harness; failed or
interrupted streams cannot execute partial programs. OpenRouter
continues to use Chat Completions. Normal request budgets are 3,000 tokens for
OpenRouter and 8,192 for Anthropic; plugin authoring requests 16,384 tokens.
Codex does not accept that token-limit parameter, and Claude Code manages its
own token budget. Provider requests retain a 180-second timeout and 2 MB response
limit. Claude CLI and Anthropic currently deliver completed replies rather than
token previews.

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
one workspace turn. The source appears inside a Gene step and the last value
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

Ask for the capability you need in the browser or model-backed CLI, for example:

> Build a workspace-scoped `line_count` plugin that accepts a filename and
> counts non-empty lines by composing `fs.read`. Inspect its contract and test it
> against `colors.txt` before reporting success.

The built-in `plugins.build` tool resolves `HarnessCodegen`, validates its inert
module plan, registers the requested scope/selectors/dependencies, and returns
its revision, lifecycle status and installed tool descriptions. `/build` is a
command adapter over that same operation:

```text
/build wordcount Count words in an input object with a text field.
/tool plugins.inspect {"name":"wordcount"}
/tool wordcount {"text":"the quick brown fox"}
```

The author can create several tools, plugin state, and dependencies. It can use
supported filesystem selectors or delegate I/O through existing tools. Missing
authority is reported explicitly. Installation never runs guessed test inputs;
the agent must make real tool calls to verify the requested behavior.

Author responses are captured in expandable raw-response blocks. Malformed
syntax and mixed conditional styles receive up to three bounded author repair
attempts before the build fails. Repairs receive the parser's diagnostic.
Model-backed profiles allow ten minutes for checked-in callbacks, covering
three requests of up to 180 seconds and registration. Generated plugin callbacks
retain their separate two-second default limit. Validation is inert and does
not run tools.

Building the same plugin name replaces its durable entry at the next revision.
`plugins.inspect` returns the source and metadata for revision work.
`plugins.disable` and `plugins.enable` change durable desired state; `/unload`
removes a plugin only for the current runtime. Old module blobs remain available
under the existing retention rules. Session-scoped plugins restore in their
session; workspace-scoped plugins are available in other sessions too.

Every entry records its author, model, timestamp, scope and module/dependency
digests. Source is parsed as inert Gene data, validated, content-addressed, and
committed before activation. A failed activation remains inspectable instead of
silently removing the desired entry.

The explicit offline `web` and `cli` profiles retain a template code generator
for demonstrations. Normal browser sessions and the default `chat` CLI profile
use the model-backed author.

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

Stored events are frozen deep copies and `PluginHost:state` returns a detached
copy, so plugin state changes only through `update_state`. Inside a turn, updates
are staged: reads see the latest staged value, commit publishes it, and abort
discards it. A flush during the turn cannot publish these pending state changes.
Outside a turn, updates immediately append to the event store.

Transcript blocks retain at most 64 KiB of UTF-8 text, reduced further when
serialization would exceed the event limit. Truncated blocks include a visible
marker and the original byte count. Tool execution and model-reply parsing
receive the full input; tool results also remain complete for their callers.

Several processes can share one home: a flush holds `events/publish.lock` while
it writes segments, publishes a generation, and sweeps unreferenced segments.

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

Tool registration validates and snapshots `input_schema`, including nested
schemas. Unsupported keywords and malformed constraints are rejected before the
row is published. The [supported input-schema subset](docs/design.md#tool-input-schemas)
includes types, alternatives, enums, object properties, arrays, string lengths
and numeric bounds. It does not implement all of JSON Schema. `output_schema`
is descriptive metadata; the tool runner does not validate returned values against it.

## Generated plugin contract

Generated code imports the data-only stable API and returns a descriptor from
capability-empty `init`. Kernel sharing is allowed only for the `PluginHost`
impl identity:

`DescriptorContext` is inert: no discovery, contribution API, or authority.
`PluginContext` is the later unforgeable token-backed host interface, not the
raw harness. It supports discovery, owned registries/contributions, seam
operations, subscriptions, schema-validated event emission, and core-owned
durable state. The context expires on demotion or uninstall.

Generated contextual command, tool, prompt and view callbacks receive that
retained context. Model code receives immutable inspection snapshots and named
operations. Private control providers are not exposed by PluginHost:resolve or
by docs; their internal state stays in the host.
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
| `"tool"` | `^tool "name"`, `^input value` | Host executes the registered plugin and returns the result for another step. |
| `"input"` | `^request {^kind ... ^prompt ...}` | Persists a question and resumes when the user explicitly answers. |

**Both code types may include an optional `^response` string.** It is shown
before execution to explain what is happening. For `code-with-response`, that
explanation accompanies the code; the execution result is still the final
answer. Omitting `^response` is valid for either code type, including:

```gene
{^type "code-with-response" ^code (do (+ 1 2))}
```

`^payload` is optional for all reply types and must be a map when supplied.
An omitted payload becomes a fresh `{}` each execution. Payload values are
read as inert data, including embedded Gene nodes. Only a validated `^code`
block is evaluated. Invalid types, malformed fields, extra top-level forms,
and the old `^status` format are rejected and explained to the model for
correction. A `code` reply always continues, even for `(do nil)`; the loop stops
after sixteen rounds if it never receives a final reply. Execution errors and
capability refusals are execution results, so `code-with-response` returns
those directly too. Session memory retains the final answer rather than the
progress explanation.

The plugin author uses this same envelope with `^type "response"` and an
inert module plan in `^payload {^module (mod plugin ...) ^scope "session"
^selectors [] ^dependencies []}`. The `build` consumer
extracts and validates that module through the existing registration path.

## What a model program may reach

Model code sees read-only data and named operations. `harness`/`h` summarize
session, plugins, tools and seams. `session` has id, scope and a history list;
`context` has session, payload, prompt and round. Runtime cells and concrete
provider implementations are private.

Use `(tools)`, `(describe_tool name)`, `(row_keys registry)`, `(plugin_states)`,
and `(doc name)` to inspect the current system. Pure code has no host authority.
For real work, request an installed tool:

```gene
{^type "tool" ^tool "fs.read" ^input {^path "README.md"}}
```

The host runs the plugin under its permitted policy and returns a structured
result to the next model step. A custom plugin can compose another tool using
`PluginHost:request_tool` and an optional continuation, with that tool declared
in its `requires` list. Every callback remains bounded.

`register_module` remains a transaction-aware core operation for inert quoted
modules. The host validates and registers queued modules after evaluation ends;
their tools become available in the next step. For conversational authoring,
`plugins.build` and `/build` expose the same durable builder.

## Real tools and pending questions

Built-in plugins provide `fs.read`, `fs.list`, `fs.write`, `fs.edit`, `fs.search`
(single-file literal search), `fs.mkdir`, `process.run`, and `http.request`, plus
plugin build/inspect/enable/disable tools. `/tool` accepts JSON or Gene data, preserving argument whitespace:

```text
/tool fs.read {"path":"README.md"}
/tool fs.write {"root":"state","path":"note.txt","text":"hello"}
```

Set `GENE_HARNESS_PROJECT` for the target project, independently of
`GENE_HARNESS_HOME`. The web server also accepts `--project <directory>`. Grant
that directory with the launcher's existing read/write flags; selecting a path
does not grant access. The default project is the Harness package. `process.run` uses an executable
plus an argument list, with bounded output and timeout; its working directory
is not a subprocess filesystem sandbox. It uses the launcher's `os/Exec`
authority. HTTP uses `net/Http`; nonzero process exits and HTTP errors retain
structured details. Custom plugins can delegate to these installed tools.
Generated callbacks can import `fail_tool` from `../../../src/plugin_api` to
raise structured tool errors with code, message, and optional `^data` details.
The helper admits the error in its defining module before it crosses the
sandbox boundary.

The agent can ask a text, select, or confirm question. The web client displays
answer controls; the CLI prints options and accepts an answer or `/cancel`.
Pending questions survive restart and resume the same run. Custom plugins can
request input through `PluginHost:request_input`, naming an owned resume tool
and inert continuation data. A changed plugin entry cannot resume an old
question. CLI raw model responses are retained but printed only when
`GENE_HARNESS_RAW=1`. An answer cannot
grant new host authority. Configure credentials outside the conversation.

The default CLI profile is now the model-backed `chat` profile. The explicitly
named `cli` and `web` profiles remain command-only demonstrations.

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
| `src/website/` | product website: copy and example data, page markup, structured styles and static export |
| `client/` | Gene modules compiled for the browser: interaction, transcript state and rendering |
| `website/examples/` | recorded website example fixtures and their model-free check |

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
| `src/agents/model_client.gene`, `src/agents/claude.gene` | provider configuration and Codex, OpenRouter, Claude CLI, and Anthropic transports |
| `src/agents/model_reply.gene` | shared Gene reply format, inert parsing, and field validation |
| `src/views/repl.gene` | terminal subscriber, one prompt and one line |
| `src/views/view_api.gene`, `src/views/recording_view.gene` | typed view contract and recording view |
| `src/agents/reflection.gene` | callable signatures, input schemas and reflected tool rows |
| `src/profiles/profile.gene`, `src/profiles/registry.gene` | profile type/boot and named-profile lookup; sibling files define deployments |
| `src/main.gene` | durable boot and irreducible recovery surface |
| `events.catalog`, `src/storage/generated_event_catalog.gene` | core persisted-event vocabulary source and generated validators |
| `src/web/server.gene`, `src/web/style.gene` | local HTTP host, authentication, page layout and styling |
| `src/web/push.gene` | ordered WebSocket messages, initial/recovery snapshots and connection lifetime |
| `src/runtime/session_host.gene`, `src/runtime/run_controller.gene` | session navigation, snapshots, durable admission and run lifecycle |
| `src/runtime/prompt.gene`, `src/runtime/cli_driver.gene` | shared prompt outcomes and CLI run admission |
| `src/runtime/tools.gene`, `src/runtime/interactions.gene` | host-owned tool execution, composition and durable input |
| `plugins/builtin/` | real filesystem, process, HTTP and interaction plugins |
| `src/runtime/bootstrap.gene`, `src/runtime/session_claim.gene` | runtime lifecycle and exclusive session ownership |
| `client/main.gene`, `client/state.gene` | Gene browser UI, connection handling, drafts and bounded transcript state |
| `client/view.gene`, `client/markdown.gene` | grouped steps, per-run outcomes, and restricted Markdown rendering |
| `client/highlight.gene` | safe, bounded Gene syntax highlighting for code and raw replies |
| `src/website/content.gene`, `src/website/page.gene`, `src/website/style.gene` | website copy, fixture-backed example data, Gene markup and scoped `$css` rules |
| `src/website/export.gene`, `client/website.gene` | static export through `$web/published_routes`; tabs, copy, highlighting and mobile menu |
| `website/examples/project_audit/` | recorded request, formatted plugin, fixture project, expected outputs and `check.gene` |
The former Harness scenarios have moved to `tmp/gene-harness-tests` in the
repository workspace. They are no longer a package test target.

Human-reviewed promotion into checked-in profiles and cross-workspace blob
sharing remain deferred.

