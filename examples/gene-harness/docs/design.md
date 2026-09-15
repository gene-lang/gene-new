# Gene Harness — implemented design

Status: the durable plugin runtime and conversational tool workflow are
implemented and verified through browser and CLI operation. See
[plugin-workflow.md](plugin-workflow.md) for the verification record.
Human-reviewed promotion into checked-in profiles remains deferred.

This tracked document is authoritative for Gene Harness. It supersedes the
historical `tmp/harness.md`, including that document's retired reply protocol.
The decision for model authority is explicit: read-only snapshots and named
operations, with no mutable Harness records. [web-client.md](web-client.md)
extends this design for the browser transport.

## 1. Purpose and resume boundary

The harness is a substrate for a general-purpose agent. It converges the useful
parts of the archived `ai_agent` and `safe_ai_agent` examples and the earlier
in-memory harness prototype.

Resume means the last flushed, committed turn boundary. It does not serialize
or resume fibers, tasks, sockets, subprocesses, or partial model responses. An
interrupted turn is an event-log fact; live resources are reconstructed from
configuration and durable plugin state.

After event-catalog validation, `hydrate_harness_log` folds retained text events
into the core session log before plugins activate. The real LLM provider restores its bounded conversation
window through `PluginHost:state`, persists it with `update_state`, and `ask`
flushes the completed exchange. Resume is therefore exercised by the actual
agent path, not only by a synthetic state fixture.

Three stores have distinct jobs:

| Store | Contents | Implementation |
|---|---|---|
| composition generations | desired plugin entries and config | `src/storage/workspace.gene`, atomic `Store/checkpoint` generations |
| module blobs | canonical generated Gene modules | owner-only atomic Store records, materialized under a workspace-keyed loader cache |
| event streams | history and full plugin state | `src/storage/state.gene`, scoped segmented streams and projection checkpoints |

No past program is replayed.

## 2. Registry kernel

`src/kernel.gene` has one extension mechanism: named registries. The built-in
registries are:

- `seams`
- `commands`
- `tools`
- `interactions`
- `prompt`
- `views`
- `event_types`
- `subscriptions`

Each registry defines uniqueness, deterministic ordering, row validation, and
optional cleanup. Every contribution receives an immutable `row_id`; the
ledger indexes owner to row IDs. Unloading an owner removes rows in reverse
acquisition order through the registry's cleanup hook. If a plugin owns a
registry, unloading it first removes every row in that registry and then the
registry itself.

```gene
(registry h "routes" ^owner "router" ^unique true
  ^schema validate_route ^on_remove close_route)

(contribute h "api" "routes"
  {^name "status" ^run status_handler}
  ^priority 10 ^config_order 0)

(rows h "routes")
(row h "routes" "status")
(remove_owner h "api")
```

Ordered registries sort by `(priority, config_order, owner, row_id)`, not
activation timing. Explicit replacement permanently supersedes the prior row;
unloading the replacement does not reveal an older provider.

The compatibility functions `provide`, `replace`, `resolve`, and
`bound_seams` are thin operations over the `seams` registry. Subscriptions are
ordinary owned rows whose cleanup cancels the subscription. There is no second
effect-kind table.

## 3. Plugins and the capability-safe host context

The stable generated-plugin contract is in `src/plugin_api.gene`:

```gene
(type Plugin
  ^props {^id Str ^provides Any ^requires Any?
          ^activate Any ^deactivate Any? ^contextual Any? ^events Any?})
```

Requirements and provisions may use the seam shorthand or an explicit
registry/key pair:

```gene
^requires ["HarnessFs" ["tools" "search"]]
^provides [["commands" "status"] ["prompt" "status_help"]]
```

Lifecycle states remain `pending`, `ready`, and `error`, and are reported by a
Cordis composition. Installing a plugin records it with its entry policy and
reconciles. As with upstream Cordis `Entry.update`, reconciles are per entry: a
plugin whose value and policy are unchanged keeps its live instance, a changed
one is disposed and reinstalled, and a removed one is disposed. The activation
revision is the unit of publication; it contributes directly to the live
registries. Dependencies may arrive in any profile order; missing ones leave a
plugin `pending`. A failed activation affects only its own plugin: it is
recorded as `error`, the plugin's last active revision, if any, is reactivated,
and it is retried only by an explicit operator action. Every contribution and callback belongs to the exact
activation revision that made it, and one deferred cleanup per revision removes
its rows and expires its callbacks.

Generated `init` receives an inert `DescriptorContext` containing stable module
and core-interface identity only. It cannot discover registries, contribute
rows, or carry authority, so descriptor preflight is deterministic.

Only activation and later callbacks receive `PluginContext`, containing an
unforgeable Cell-identity token. The token maps to
host state in a private kernel table and supports only `PluginHost` messages:

- registry-name/key discovery;
- seam resolve/provide/replace;
- owned registry creation, contribution/replacement, and subscription;
- schema-validated, core-stamped plugin event emission;
- scoped durable state read/update.

The context remains valid for the plugin lifetime so contributed callbacks can
use state later. Demotion or uninstall expires it. A fabricated or expired
token is rejected.

Generated contextual command, tool and view callbacks receive their retained
PluginContext; checked-in adapters may receive the Harness. Model programs see
immutable session/registry summaries and inert payload data. Concrete providers,
raw runtime cells and live plugin contexts do not cross into model code.

Seam rows may be host-private. PluginHost resolution and public docs do not
expose private provider values; the agent and author use this for internal
state. Generated prompt providers receive PluginContext rather than raw Harness.

PluginHost supports tool description and deferred `request_tool` composition.
A plugin declares each external tool dependency in `requires`. Its callback
returns a ToolRequest with an optional continuation. The host validates the
owner context and dependency, executes the callee after the caller's restricted
scope ends, and invokes the continuation under the caller's policy. No caller
can manufacture a different plugin's context. Delegation is bounded.

Deactivation and registry cleanup receive the still-valid owner context; it is
expired only after reverse-order cleanup completes.

## 4. Turn transactions

The turn boundary is deliberately limited, not a claim
that arbitrary I/O can be rolled back.

- registry and composition changes are made in cloned staging state;
- lifecycle logs and bus notifications are held until commit;
- abort cleans newly acquired rows and leaves committed rows untouched;
- plugin/status/policy tables stage too, committed-plugin deactivation is
  deferred, and repeated composition writes to one id coalesce to the final
  descriptor;
- replacement defers old-row cleanup until commit;
- cleanup failure produces `recovery_required`;
- panic/cancellation reaches an `ensure` path that removes the staging overlay.
- `transaction_diff` and the `diff` command expose staged registry and
  composition changes before commit.

Publishing composition `CURRENT` is the durable linearization point. Generated
plugin rows appear during post-commit reconciliation; activation failure leaves
the desired entry committed in `error`. Committed and aborted turn boundaries
are structured durable events, and a flush occurs before the next turn may be
claimed.

## 5. Event streams and plugin state

`src/storage/state.gene` stores version-2 recovery-self-describing event envelopes:

```gene
{^format 2 ^origin "core" ^owner "core" ^projection "todo"
 ^scope "session" ^stream "s1" ^seq 7
 ^type "plugin/state" ^version 1 ^ignorable false ^payload {...}}
```

There is one workspace stream and one stream per session. An entry's `^scope`
chooses its instance and state ownership:

| Scope | Instance | Durable state |
|---|---|---|
| `workspace` | one live replica per Harness, one shared durable projection | workspace stream |
| `session` | one instance per Harness/session | that session's stream |

`PluginHost:update_state` updates the in-memory projection and appends the
versioned full-state record in one core operation. Plugins do not coordinate a
private file with memory themselves. Disjoint streams from stale processes merge
and retry; a stale write to the same ordered stream restores the winner and
raises `HarnessStateConflict` at the outer callback boundary.

Flush partitions each stream into bounded content-addressed segments, retains a
configured segment window, persists projection checkpoints, and publishes the
manifest with `Store/checkpoint`. The current manifest retains references needed
by the newest fallback generations before garbage-collecting older segment
records. Event and state byte caps reject oversized records.

Core event vocabulary comes from `events.catalog` and the generated
`src/storage/generated_event_catalog.gene`. CI checks it with:

```bash
python3 tools/generate_harness_event_catalog.py --check
```

Plugin descriptors may add event schemas. During restore, unknown required
plugin events quarantine only that plugin projection; unknown required core
events refuse reconstruction. Ignorable records may be skipped. Cold recovery
runs only after catalog validation and appends a synthetic
`turn/end {^reason "interrupted" ^synthetic true}` for every unmatched start.
Core event keys and the `core`/`descriptor:` owner ids are reserved.
`event_types` replacement is owner-checked. Core records submitted messages
and outcomes; plugins emit only validated plugin-owned events. Model programs
cannot mutate the live core log.

## 6. Desired composition and CAS

`src/storage/workspace.gene` opens the composition Store and exposes revision-CAS
writes:

- one Gene lane serializes in-process writes;
- filesystem publication takes a short-lived crash-recoverable process lock;
- SQLite publication claims inside `BEGIN IMMEDIATE`;
- two processes racing from revision `N` both attempt generation `N+1`, and
  exactly one complete generation is published;
- the loser refreshes rather than overwriting the winner.

`CURRENT` is authoritative. A complete directory above it is unpublished crash
debris, never selected by load, and is reclaimed under the next publication
lock. Corrupt published generations fall back without crossing `CURRENT`.

Composition readers require format 1, and event readers reject unsupported
envelope formats. Corruption remains a separate error.

## 7. Durable generated modules

`register_module` accepts a quoted module AST:

```gene
(register_module workspace h "echo"
  (quote
    (mod plugin
      (import [Plugin DescriptorContext PluginContext PluginHost]
        ^from "../../../src/plugin_api")
      (import_impl PluginHost for PluginContext ^from "../../../src/kernel")
      (fn init [ctx : DescriptorContext] : Plugin
        ^capabilities []
        ...)))
  ^scope "session"
  ^selectors []
  ^dependencies [])
```

The registration sequence is:

1. validate a filename-safe ID and an inert quoted `mod` node;
2. unless `^replace` is set, refuse an ID the effective entry list already
   claims — the staged entries of an active transaction, otherwise the
   committed ones;
3. reject executable top-level forms and source over 256 KiB;
4. canonicalize source and compute SHA-256;
5. validate every relative import against a supplied dependency blob;
6. atomically materialize unreferenced validation cache files;
7. sandbox-load with only namespaces implied by selectors and an entry-policy
   isolation key;
8. attach the immutable module capability/budget policy, then execute
   capability-empty `init` under step/time/memory budgets and panic
   containment;
9. validate the returned descriptor without installing it;
10. atomically persist the validated root/dependency blobs;
11. commit the new composition generation by CAS;
12. register descriptor event vocabulary and activate once, after commit.

Step 2 is early because the entry list is the only thing that can answer it and
nothing before it is written. The same refusal still guards the entry list at
step 11, but reaching it there meant a name collision had already materialized
every dependency blob and the module itself, leaving cache files no entry
references and no way to tell them from ones a live entry needs. So an
unreferenced cache file now only ever comes from a preflight failure.

Dependencies are also quoted modules. `module_digest` lets a caller construct a
relative digest import, and `^dependencies` supplies the exact closure. Shared
imports are restricted to declared contract modules. Ordinary generated
code imports `plugin_api`; kernel sharing is accepted only for
`import_impl PluginHost for PluginContext`, so untrusted code cannot bind the
recovery kernel as a utility module. Restore checks every digest and supported
interface version before loading. A missing loader-cache file is rematerialized from
the authoritative blob Store and verified.

Activation failure does not roll desired state backward. The entry remains
committed and appears in `doctor` as quarantined.

### 7.1 Authoring and using plugins

The built-in commands plugin contributes `plugins.build`, `plugins.inspect`,
`plugins.disable` and `plugins.enable` as ordinary tool rows. `/build` is a
command adapter over the same builder. It resolves the `HarnessCodegen` provider,
which returns an inert module or a plan with `module`, `scope`, `selectors`, and
`dependencies`. Registration remains the same validated durable core operation.

The model-backed author receives current tool descriptions and the shared plugin
module contract. Tools can accept structured data, use PluginHost state, compose
other declared tools, or request supported filesystem selectors. It must report
missing authority instead of replacing an operation with a simulation. The
builder returns installed tool contracts and lifecycle status. It does not run
guessed test inputs: callers verify behavior with explicit tool calls.

### 7.2 Agent steps and host-owned execution

The validated model reply union is:

- `code`: evaluate one `(do ...)`, then return the observed result to the agent;
- `code-with-response`: evaluate and return its result directly;
- `tool`: `tool` name plus structured `input`, executed by the host;
- `input`: persist a `request` and release the execution task while waiting;
- `response`: finish with readable response text.

Code is capability-empty. `harness`/`h` are immutable summaries of session,
plugins, tools and seams. `session` carries id, scope and a history list;
`context` carries session, payload, prompt and round. Helpers expose live
registry descriptions, docs and explicit lifecycle operations. They never return
raw runtime records or concrete tool implementations.

`register_module` queues inert source and the host drains that queue after the
restricted evaluator returns. Operational tools instead use `runtime/tools.gene`:
the host validates the current owned row and input schema, executes the callback
under its plugin policy, and produces `{ok, value}` or `{ok, error}`. Tool calls
and results are durable output blocks. Registered I/O tools therefore work from
the agent without granting host authority to arbitrary model code.

The built-in filesystem, subprocess and HTTP adapters are plugins. Process
execution uses the launcher's os/Exec authority and an explicit argument list;
the selected working directory is not an OS sandbox. HTTP uses net/Http. Both
operations are asynchronous, cancellable and bounded in wall time and output.
ToolError preserves domain failure codes and details in the shared result shape.

The same tool runner is used by `/tool`, `/read`, the model's tool reply, and
deferred plugin-to-plugin calls. Existing reflected callable rows retain their
positional/named input envelopes. Generic object schemas and contextual tool
callbacks are supported alongside older single-value rows. Long asynchronous
operations return ToolTask; the host awaits it after the bounded callback has
returned, cancels it with the run, and supervises any continuation under its
owner. Spawned custom and trusted tasks retain their execution budgets.

## 8. Execution supervision and attenuation

Gene `Env ^policy` now enforces:

- transitive maximum steps across calls into module-defined functions;
- wall-clock timeout;
- incremental process-memory ceiling;
- disabled FFI and native compilation.

`runtime/guard_call` is the explicit supervision boundary that turns a Gene
panic into a data failure for the recovery kernel. Cancellation remains a
control signal. The loader also installs an immutable execution policy on the
sandbox module root. Every later external entry creates a fresh budget and
intersects the caller with that module ceiling, including escaped functions and
direct typed protocol methods that never pass through a registry wrapper.

Capability selectors stored in composition are inert maps:

```gene
{^type "fs/ReadDir" ^root "workspace" ^path "docs"}
{^type "fs/ReadWriteDir" ^root "state" ^path "cache"}
```

The named roots are `workspace` (the selected project, defaulting to the Harness
package) and `state` (harness state). The launcher selects the project with
`GENE_HARNESS_PROJECT`; the web server also accepts `--project`. Relative traversal and absolute paths are rejected. At
activation the harness expands the map to an ordinary absolute capability
selector and evaluates the activation under `with_capabilities`. Resolution is
against the application's immutable host ceiling and therefore fails rather
than widens. Namespace visibility in the module sandbox is not authority; the
active capability context remains the native enforcement boundary.

A profile may carry `^limits`, applied to every plugin it installs with the
capability context left inherited. The default budget suits a callback doing
local computation; a deployment whose author is a remote model has commands
that legitimately block on a network round trip, and there the default is not a
guard against runaway code but a guarantee that the deployment cannot work.
Trusted browser/chat callbacks allow one million steps for model transport,
author validation and module registration, with a 120-second deadline. Custom
plugins retain their own default 100,000-step/2-second policy. Pure model code
has a separate 100,000-step/2-second evaluator budget; the outer registration
transaction has room to perform host work after that evaluator returns.

Generic command/tool/seam callbacks, interaction validators, cleanup hooks, subscribers, and
views additionally pass through owner-aware wrappers. The core boundary flushes
state only after the attenuated callback scope unwinds, so opaque retained Store
authority is never lent to plugin code.

A budget bounds a unit of work, so the unit has to be chosen where the work is,
and it must not contain a wait. `HarnessView` therefore has two messages —
render the prompt, handle the line — each returning `nil` to be called again,
and the owner-aware wrapper enters each once, so both draw a fresh deadline and
a fresh step/memory allowance. The caller owns the loop and the blocking read
that sits between them; the read is under no budget, because reading the
process's own stdin is host authority rather than plugin work.

Both properties were learned the same way. A view that owned its loop drew one
budget for the whole conversation and an interactive shell died two minutes in.
Moving the loop out but leaving the read inside only moved the failure: the
turn that printed the prompt was the one that expired, and the diagnostic
surfaced at the first budget check after the keystroke — a line with nothing to
do with the cause.

## 9. Phased boot and recovery

Boot is ordered to break the event-schema/state cycle:

1. read the composition generation using core formats;
2. bounded-load every descriptor without activation;
3. register event schemas from valid descriptors;
4. validate/fold event streams and state projections, then repair interrupted
   turns;
5. quarantine missing or incompatible plugin projections;
6. settle and activate the remaining descriptors.

One entry cannot refuse the workspace. Missing blobs, digest/interface
mismatches, invalid descriptors, exhausted limits, and panics become attached
quarantine reasons. Dependents remain `pending`.

The irreducible core recovery surface is independent of plugins:

- `doctor`
- `enable <id>`
- `disable <id>`
- safe shutdown/flush

`disable` and `enable` run before descriptor or profile activation. `doctor`
bounded-loads descriptors and validates their event vocabulary without
activating them. Normal boot performs the same read-only preparation before any
effectful baseline profile plugin. A recovery shell is not implicitly granted,
and shutdown reverses plugins before closing stores.

## 10. Commands, tools, prompt, and views

The command interpreter no longer contains a command-name branch chain.
`command_plugin` contributes command rows with `name`, `doc`, and `run`;
`dispatch` looks up the row. Help is rendered from those same rows.

Rows may opt into `^raw_input true`: dispatch then passes the unchanged source
after the command name instead of a word list. The `code_command` plugin uses
this for `/code`, preserving string whitespace and line comments. It parses
all forms before invoking the same workspace executor as model programs, and
returns the last value or a readable error without calling the model. Its
inner evaluation budget leaves room for transaction cleanup inside the command
callback's outer budget. Queued modules default to `program/user` provenance.

Generated tools contribute `tools` rows rather than `Tool:*` seams. A durable
build therefore extends `tools`, help/introspection, and behavior without core
knowing the tool name — or, under `chat`, without anyone having written the
tool: `build` resolves `HarnessCodegen` (§7.1) and the row comes from whatever
that provider authored.

Prompt sections are ordered `prompt` rows. `render_prompt` combines pushed rows
with live registry key introspection; `doc` returns pull-only rows from the same
registry. The checked-in `tools/gene-lang-skill/SKILL.md` is pushed and its
reference chapters are pull-only. The old handwritten Gene primer is gone.

Views replace the one `views/active` row. The loop over a view's turns belongs
to `main.gene`, which re-reads that row between turns — which is the whole of
handoff: a replacement committed during a turn takes effect at the next prompt,
an absent row ends the session, and no view has to check for its own successor.

User-visible agent output is a typed durable core event; terminal and recording
views consume the same feed. A recording view plus the command-agent stub
provides deterministic tests with no terminal or network.

## 11. Durable mid-turn interaction

A question ends the current step without keeping a task, fiber, bounded callback,
or network request waiting on a human. The model's `input` reply carries a text,
select, or confirm request. The `interactions` registry supplies plugin-owned
request/reply validators; the built-in provider supplies these three kinds.

Core persists `input/request` and `input/reply` as versioned full-state events in
the session's interaction projection. A pending record contains the validated
public request, stable request ID, original run ID, and inert continuation data.
The run receipt becomes `waiting_input`. Cold recovery preserves this state.
An explicit reply is validated and persisted with renewed run admission before
the agent resumes in a fresh task. It keeps its original run ID and continues
its transcript block sequence. Repeated matching replies are idempotent;
a conflicting answer is rejected. Cancel ends the waiting run without replay.

The browser uses `POST /api/v1/sessions/{id}/input` with `input_id`, `value`, and
`cancelled`; WebSocket snapshots and run pushes carry the question. The client
renders text, single/multiple selection and confirm controls. Custom interaction
kinds use text fallback in the standard clients and must validate text replies. Unconfirmed
submitted answers are retained for idempotent reconnect recovery.

The CLI uses the same run controller and receipts. It prints the pending
question before the next unbounded stdin read; numeric choices and yes/no are
parsed by the interaction plugin. `/cancel` cancels a pending question. No plugin
callback blocks on terminal input.

Custom tools return `PluginInputRequest` through `PluginHost:request_input`.
The host validates context ownership and an owned resume tool, then persists
only its request and inert continuation data, plus a fingerprint of the plugin entry (source, selectors, limits and metadata).
On reply, that tool receives `{input, reply}`; a changed owner or entry fingerprint
is rejected. Function continuations cannot cross a question boundary. The same
mechanism works from `/tool`, the model agent, and CLI. Matching reply retries
remain reads even while a resumed run or another session is active.

Defaults are suggestions, never implicit replies. Input cannot enlarge the
launcher's capability ceiling. Secret input is refused; credentials belong in
launcher configuration. Continuations contain data, not live resources.

## 12. Entry point and filesystem layout

`main.gene` uses `GENE_HARNESS_HOME`, defaulting to
`examples/gene-harness/tmp/workspace`, and creates:

```text
<home>/
  composition/   Store generations and CURRENT
  modules/       immutable content-addressed module Store records
  events/        event segments, projections, generations and CURRENT

plugins/generated/
  <workspace-sha256>/
    <module-sha256>.gene  verified loader cache (ignored by git)
```

An external home must be granted by the launcher with
`--allow_read_write_dir`. The environment variable chooses a path; it does not
mint filesystem authority.

Core first prepares authored descriptors and validates their event schemas.
Baseline profiles then install checked-in provider/agent/view plugins, and the
prepared desired entries activate. On exit, core reverses plugins, flushes
events, and closes all three stores.

## 13. Implementation map

The [source directory guide](../README.md#files) groups modules into agents,
runtime, storage, views, profiles, and web hosting. The source-root
`kernel.gene`, `plugin_api.gene`, and `seams.gene` paths are stable imports
embedded in persisted generated modules and shared by the sandbox loader.

| File | Responsibility |
|---|---|
| `src/kernel.gene` | registry, ledger, transactions/diff, lifecycle, PluginContext, prompt/output events |
| `src/plugin_api.gene` | stable generated-plugin types and protocol |
| `src/storage/state.gene` | scoped durable event segments and full-state projections |
| `src/storage/workspace.gene` | composition CAS, blobs, register/restore, quarantine |
| `src/agents/agent.gene` | registry-backed commands, tools, offline prompt provider |
| `src/agents/llm.gene` | model provider; prompt rendered from registries |
| `src/agents/model_reply.gene` | shared reply envelope validation and format instructions |
| `src/runtime/prompt.gene`, `src/runtime/cli_driver.gene` | channel-independent execution and CLI run admission |
| `src/runtime/tools.gene`, `src/runtime/interactions.gene` | supervised tool requests and durable question/resume state |
| `plugins/builtin/` | filesystem, subprocess, HTTP and interaction-kind plugins |
| `src/views/repl.gene` | terminal view plugin |
| `src/views/view_api.gene`, `src/views/recording_view.gene` | typed view contract and deterministic recording view |
| `src/profiles/profile.gene`, `src/profiles/` | checked-in baseline composition |
| `src/main.gene` | durable boot, recovery nucleus, view/one-shot dispatch |

Runtime support used by the harness lives in `src/gene/vm.nim` (transitive and
module-entry budgets, immutable module ceilings, panic guard),
`src/gene/stdlib.nim` (exclusive Store generations and atomic text writes), and
`src/gene/fs_capabilities.nim`
(missing intermediate path is a false existence result, while symlinks still
fail closed).

## 14. Archived scenarios and deferred work

The former public-seam scenarios are archived locally under
`tmp/gene-harness-tests`. They are no longer a package test target. App
development currently uses builds and direct operation, as requested by the
user. The scenario coverage remains useful design history, but no automated
suite result is claimed for the browser implementation.

Still deferred:

- human-reviewed promotion into a checked-in profile;
- cross-workspace sharing/GC of module blobs;
- restoration of live in-flight resources (explicitly outside the resume
  boundary);
- a standardized richer output vocabulary. The mechanism is already here —
  `events.catalog` carries a schema per event and marks each one `required` or
  `ignorable`, so a view that does not understand a new output kind skips it —
  and only the vocabulary is missing. Every added kind is `ignorable` and
  carries a text fallback, or an old view breaks on a new one.

## 15. Browser client

[The browser-client design](web-client.md) specifies a local, single-operator
chat and session client backed by the native Harness. The existing `web`
profile remains the offline memory/HTML example; the `browser` profile
uses the model-backed providers without the terminal driver.

The client is authored in Gene's web profile. A native HTTP host serves it and
owns session admission, run receipts, cancellation, and safe snapshots. HTTP
provides commands and history reads; WebSockets push transcript and run-state
updates directly, with snapshots restoring state on reconnect. Codex output
text can appear as a provisional raw preview before the complete response is
validated for execution.
One active runtime and one run at a time preserve current session isolation.
Status and protocol metadata expose no model credentials, live Harness
objects, or raw plugin state. Requested tool output is rendered as untrusted data.

The new design distinguishes a submitted **run** from its internal composition
**turns**. It requires durable submission deduplication, stable transcript IDs,
explicit provisional output, and reconnect/recovery semantics before building
the UI. It also adds a shared session-writer claim to browser and CLI boot;
event-store CAS by itself cannot prevent duplicate external effects.

The detailed scope, module ownership, interface, UI behavior, compatibility
changes, and acceptance cases live in the linked design. Launch instructions
are in the package README. The browser state and rendering modules, page markup,
and styling are all authored in Gene.
