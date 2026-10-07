# Gene Harness

Gene Harness runs durable conversations in a project workspace. The model
responds with Gene code. The operator sees the code, labeled results, progress
and final replies, questions, and a separate console.

Code uses the standard library and workspace plugin functions directly. File
edits use an apply-patch block. Run the process in an OS sandbox when you want
isolation.

## Documentation

| Need | Guide |
| --- | --- |
| Architecture, lifetimes and module responsibilities | [Design](docs/design.md) |
| Author a workspace plugin | [Plugins](docs/plugins.md) |
| Run and verify a function plugin without a model | [Project audit example](website/examples/project_audit/README.md) |
| Browser workflow, transport and recovery | [Web client](docs/web-client.md) |
| Add UI components or forms | [Web components](docs/web-components.md) |
| Try the editable project board | [Workspace UI experiment](experiments/ui/README.md) |
| Follow an end-to-end application build | [Todo replay](docs/todo-replay.md) |
| Configure Claude transports | [Claude providers](docs/claude.md) |

## Start

From the Gene repository:

```text
bin/gene run examples/gene-harness/src/main.gene --workspace /path/to/project chat
bin/gene run examples/gene-harness/src/web/server.gene --workspace /path/to/project --port 8095
```

The default workspace is the current directory. The process changes its working
directory to the workspace and stores state in `.gene-harness/`. That
directory has its own `.gitignore`.

Both entry points own the workspace. One process holds a kernel lock for its
lifetime; another fails with the owner's PID and entry point. The kernel
releases the lock after a crash. Restart in the same workspace to recover
sessions.

For restart supervision, put Gene on PATH or set GENE_BINARY and use:

```text
examples/gene-harness/bin/gene-harness --workspace /path/to/project chat
examples/gene-harness/bin/gene-harness web --workspace /path/to/project --port 8095
```

The supervisor is written in Gene and starts the same entry and arguments again
after exit status 75.

See [the todo-app replay guide](docs/todo-replay.md) for a complete web workflow
using Codex OAuth, including continuation, verification and recovery.

### CLI reference

| Command | Effect |
| --- | --- |
| `chat` | Default. Read prompts and slash commands from the terminal. |
| `chat words…` | Run one prompt or slash command, print the result, then exit. |
| `triggers [list]` | List trigger definitions. |
| `triggers create FILE` | Create a trigger from an inert Gene map or serde file. |
| `triggers delete ID` | Disable and delete a trigger. |
| `triggers occurrences [ID]` | List occurrence states. |
| `doctor` | Report composition and plugin problems without activating plugins. |
| `enable ID`, `disable ID` | Enable or disable a stored or built-in plugin id. |
| `restore ID` | Remove a stored override and restore the profile's built-in plugin. |

`--workspace DIR` selects the workspace, `--session ID` selects the CLI session
(default `default`), and `--script FILE` selects a scripted profile whose
provider plugin owns the canned responses. `doctor`, `enable`, `disable` and
`restore` are recovery commands: they open the workspace without activating
plugins, so a broken plugin cannot block them. `doctor` leaves the composition
generation unchanged; the other commands report the action or that no change
was needed, along with the revision.

## Providers and workspace settings

Settings live in `.gene-harness/config.gene`, using Gene's inert serde data
representation. A profile may pin a provider. Otherwise a non-empty
GENE_HARNESS_PROVIDER selects one, then `config.gene`'s `provider`, then the
available provider row with the lowest automatic rank: OpenRouter,
Anthropic, Codex. An explicit missing or unavailable provider makes the
profile `not_ready`; it does not silently fall back. Model and effort use
their environment values, then `config.gene`, then the selected row's default.
The loop selects once per turn from its leased plugin composition and uses
that row for both a compaction summary and the main call.

Each provider is a plugin row with `available`, `configure`, `prepare` and
`send` callbacks. `prepare` returns the complete model-visible input without
credentials. `send` adds authentication and makes one transport attempt; the
loop retries one reported HTTP timeout. The scripted and offline profiles
pin their own model-free provider plugins.

Every provider invocation, including a compaction summary, writes a
`model/request` with the exact prepared input before transport and a
`model/result` for each attempt. Timeout, failure and unknown outcomes are
recorded with wall-clock and elapsed timing. Content-addressed blobs share
unchanged history across requests; literal blob-marker maps are escaped;
transport credentials are excluded. A successful main result is linked from
the turn transcript.

| Provider | Host credentials |
| --- | --- |
| codex | CODEX_AUTH_FILE, or auth.json beneath CODEX_HOME / the user's .codex directory |
| anthropic | ANTHROPIC_API_KEY |
| claude | Claude Code's own login; optionally GENE_HARNESS_CLAUDE_COMMAND |
| openrouter | OPENROUTER_API_KEY or OPENROUTER_KEY |

Credentials remain in the host transport and are excluded from prompts and
durable transcripts. The Claude transport disables its tools, hooks and MCP
connections. Only complete provider responses are evaluated.
Transports preserve response bytes. Block terminators can end at EOF, and
CRLF delimiters are accepted while attachment bodies retain their line endings.

| Setting | Default | Meaning |
| --- | --- | --- |
| `provider`, `model` | `""` | Empty uses the profile/environment/configuration/automatic selection described above |
| `effort` | `"medium"` | none, minimal, low, medium, high, xhigh or max |
| `provider_timeout_ms` | `600000` | Timeout per provider attempt; one retry when `send` reports a timeout |
| `response_budget` | `{^timeout_ms 600000 ^max_memory_mb 1024}` | Runaway limit for each response evaluation and command |
| `turn_limit` | `24` | Turns per user round; reaching it fails the round |
| `trigger_turn_limit` | `12` | Turns per trigger round |
| `trigger_timeout_ms` | `300000` | Running time per trigger round |
| `trigger_concurrency` | `2` | Unfinished trigger rounds across the workspace |
| `question_timeout_ms` | `86400000` | Deadline for a trigger round's question batch |
| `context_window` | `128000` | Model window in tokens, used by compaction |
| `trigger_occurrence_keep` | `256` | Recent terminal occurrences kept per trigger |
| `body_gc_interval_ms` | `60000` | Interval for idle collection of unreferenced blobs |

Budgets are runaway protection. Responsiveness comes from the VM's execution
quantum, so a long evaluation does not stall other sessions. Waiting on
questions pauses a trigger round's running budget.

## Browser and CLI

The browser host prints a one-use connection link. Opening it exchanges the
token for an eight-hour cookie and CSRF value. Requests must come from the
host's own origin. Cookies survive process restarts.

The sidebar lists interactive and pinned sessions by default. Kind, status,
trigger, text and time filters query the durable index. Needs attention lists
sessions of every kind. Opening a session or starting a new user round acknowledges its attention flag;
another cause can set it again.

Several session tabs can remain open with independent streams. Each turn shows
response code, attachment and patch stubs, next-request items, and replies.
Console output has its own collapsible pane. Questions preselect recommended
choices but submit only when the operator answers. Skip individual questions
or dismiss the batch.

The CLI reads input while a round runs. For questions, enter a numbered choice,
press Enter for the recommendation, enter `-` to skip, or `/dismiss` to
dismiss the batch. Comma-separated numbers answer multiple-choice items.

## Workspace UI

Plugins can contribute quoted Gene views to named slots in the browser.
An opt-in [workspace UI experiment](experiments/ui/README.md) also adds a
stateful panel with keyed forms, layout choices and theme tokens. Its project
board fixture is installed separately; the interface remains experimental.

The same registered functions serve the model, `/run`, the persistent REPL
and panel actions. The browser keeps filters, selections and unsaved drafts
while server data changes. Actions use command tasks, cancellation and durable
receipts. Failed actions attach one diagnostic to the submitting session's
next user request; successful actions stay out of model input and the chat
transcript.

The baseline profile exposes `ui_configure` and `ui_preview`, with rendering
and actions disabled until explicitly enabled. Model turns receive compact
previews of views owned by successfully published plugins, including in CLI
sessions. Use `ui_preview` for the full validated tree or a different view
state. Previewing checks the server representation; browser layout and
interaction still need verification.

`/ui/default` opens the host's recovery interface without plugin views or
themes. It preserves the selected conversation and offers a link back to the
workspace UI. See the [component contract](docs/web-components.md) for
authoring, limits and recovery behavior.

## Slash commands

Commands run without the model in their own tasks, with per-session ids.

| Command | Behavior |
| --- | --- |
| /help [name] | List commands or show documentation |
| /run code | Evaluate Gene code; display its bounded value, errors and console |
| /repl | Open a persistent Gene REPL for this session |
| /sh command | Run a shell command, stream output and show exit status |
| /view path[:from-to] | View a file/range, list a directory, or inspect binary metadata |
| /cancel | Cancel this session's current round or pending questions |
| /stop | Stop admission, cancel running work, flush and exit |
| /restart | Stop and restart under the launcher |
| /new [title] | CLI: create and switch to an interactive session |
| /sessions | CLI: list sessions |

/run, /sh and /view can run during a round. Their results attach to the next
user-initiated request after the current round; /view attaches a pointer.
Other commands remain operator-only. Unknown commands report a closest match.
`//text` sends the literal `/text` to the model.

Multi-line /run input in the CLI continues until the reader has a complete
form. Outcome and append_prompt are response-only bindings. Shell commands
have empty stdin and no terminal. Stored output is capped at 1 MiB and can be
recalled. File views use 400-line pages.

Stop and restart require confirmation when other sessions have running rounds.
Shutdown gives cancellation a five-second grace period; an uncooperative
cleanup cannot hold the process indefinitely. Cancelled receipts and pending
questions survive the next start. Direct gene run treats /restart as stop and
tells the operator to start it again from a terminal.

## Persistent operator REPL

`/repl` opens a persistent Gene environment in the current session. Variables,
functions, types, imports and macros remain available to subsequent inputs.
While it is open, every submitted line is Gene code, including text beginning
with `/`. Enter `exit`, `quit`, `:exit` or `:quit` to return to chat. The browser
also provides a Leave control. Incomplete forms keep their draft; the CLI
collects continuation lines with `... `.

REPL inputs use the command execution budget and appear in the transcript,
with streamed console output and reader-syntax values. They do not attach to
the next model request. Plugin functions follow the composition leased by
each input; saved function references see replacements on the next input.

The browser action button reads Eval while idle and Stop while an input runs.
Stop cancels that input and retains earlier bindings. In the CLI, Ctrl-C
cancels an input or discards continuation lines; outside the REPL it ends the
process. Only one input may run per session.

REPL state lives in memory. It closes on exit, session unload/deletion,
plugin disable/replacement or process shutdown. The last browser viewer
leaving starts a 60-second grace period, so ordinary reconnects preserve
bindings. Restarting the process closes every REPL. Unknown browser input
outcomes are resolved through recorded input ids and are never automatically
re-evaluated. The `repl` built-in plugin can be disabled independently of
`core_commands`.

## Code responses

### Discover as you work

The initial model prompt contains execution rules and brief orientation. Gene
and plugin manuals and callable signatures are loaded when needed:

```gene
(discover "ui forms" ^kind "docs")
(doc "harness/ui/forms")
(discover "register" ^kind "functions")
```

Discovery searches active contribution names, descriptions and tags. Results
include owners, signatures/usage and chapter references; default pages contain
12 matches, with next_offset for continuation. `doc` loads one chapter. Both
helpers use the current composition lease and also work in `/run` and the REPL.

Every plugin should follow this practice: concise descriptions, searchable tags
and chapter references, with detailed instructions/examples in owned docs rows.
Keep prompt contributions to essential orientation. New plugin contributions
are discovered automatically, and disabling one withdraws its owned docs too.
See [discovery](docs/discovery.md), [plugin authoring](docs/plugins.md), and the
[focused UI recipes](docs/recipes/ui.md).

### Return Gene code

```gene
# Inspect the project
# Keep a labeled result for the next turn.
(append_prompt "files" ($fs/list_dir "."))
(Outcome ^prompt "Review the files above." ^reply "I’m inspecting the project.")
```

```gene
# Finish
(Outcome ^^done ^reply "Finished.")
```

The last value steers the loop:

| Last value | Effect |
| --- | --- |
| `(Outcome ^^done ^reply r)` | Finish the round and show `r` |
| `(Outcome ^prompt p)` | Take another turn; an optional `^reply` is progress text |
| `(Outcome ^questions [...])` | Ask the operator, then continue with the answers |
| any other value | Continue, with the value as `[N.result]` |
| error, timeout or read error | Continue, with the diagnostic as `[N.error]` |

A done Outcome requires a non-empty reply and drops appended prompt items.
`^^attention` flags the session for the operator. Printing reaches the
operator's console and never becomes model history.

The next request lists its items in a fixed order: patch result, append_prompt
items in call order, the Outcome's prompt, errors, then answers. Each item has
a header that ties it back to the code:

```text
[57.patch] applied: src/report.gene +40 -0 (new)
[57.smoke] line 7: (append_prompt "smoke" (run_smoke "fixtures/orders.csv"))
ok 12 records
[57.result] line 9: Outcome ^prompt
report written; smoke output above
```

Labels are literal strings matching `[a-z0-9_]+`; a repeated label becomes
`smoke#2`. A plugin function's items read `fn name` instead of a line.

Questions take up to eight items. Choices are optional, `^^multi` allows
several, and `^kind "confirm"` asks yes or no:

```gene
# Ask before choosing storage
(Outcome ^questions
  [{^id "db" ^prompt "Which database?"
    ^choices ["sqlite" "postgres"] ^recommended "sqlite"}
   {^id "wipe" ^prompt "Delete the old data?" ^kind "confirm"}])
```

The operator may answer some questions and skip others. The next request
carries `[58.answers]` followed by the frozen answer map,
`#{^db "postgres" ^wipe unanswered}`.

Attachments preserve raw bytes:

```text
# Write a file from its attachment
($fs/write_text "report.txt" (attachment "report"))
(Outcome ^^done ^reply "Report written.")
<<<report END
Raw text, including quotes and \d.
END
```

One V4A `*** Begin Patch` / `*** End Patch` block may follow the code.
Preflight computes every edit before writing; the patch applies before code.
A failed anchor writes nothing and skips evaluation. Write failures attempt
to restore originals. A crash can leave a partial multi-file edit; recovery
names the affected files and removes staging siblings.

An item over 16 KiB keeps its first and last 6 KiB, and a request is capped at
64 KiB. One turn later, items over 16 KiB settle to a stub in history.
The initiating task stays intact during its active round. The latest assistant
response, including attachments and failed patches, stays full for the next
turn; older attachment and patch bodies settle to recall stubs. The transcript
uses compact summaries throughout. The model receives its remaining round
budget in each request; reaching the limit produces continuation instructions.
`(recall "57.tests")` returns a complete stored body, also after a restart.
Compaction retains comments, append_prompt and Outcome lines, and can
summarize old rounds while preserving the newest request.

## Plugins and triggers

The model extends itself by writing plugins. A plugin contributes functions,
which later turns call directly; there are no tools. This response registers
one from an attachment:

```text
# Register a line counter for later turns
(append_prompt "plugin" (register_plugin "line_counter" (attachment "plugin")))
(Outcome ^prompt "Count the lines in notes.txt.")
<<<plugin END
(mod plugin
  (import ^from "src/plugin_api.gene" [Plugin PluginHost])
  (fn count_lines [path : Str] : Int
    (let lines ($str/split ($fs/read_text path) "\n"))
    ($size (lines .filter (fn [line] (!= ($str/trim line) "")))))
  (fn init [descriptor]
    (Plugin ^id "line_counter" ^provides [["functions" "count_lines"]]
      ^activate (fn [host]
        (host .PluginHost:contribute "functions"
          {^name "count_lines" ^doc "Count non-empty lines in a file."
           ^tags ["files" "lines"] ^docs ["line_counter/usage"] ^fn count_lines})
        (host .PluginHost:contribute "docs"
          {^name "line_counter/usage" ^summary "Counting nonempty workspace file lines."
           ^tags ["files" "lines"]
           ^text "Call count_lines with a workspace-relative path; the file is read without modification."})))))
END
```

The next turn can call `(count_lines "notes.txt")`. `register_plugin` returns
`queued` during this turn. The boundary result reports the committed revision
and whether activation was active, pending or quarantined; `queued` alone is
not a success receipt. A turn that queues a plugin change continues to show
that result before it can finish. The plugin belongs to the workspace and
loads after restart, so other sessions can use it. `plugin_states`,
`inspect_plugin`, `enable_plugin`, `disable_plugin` and `restore_plugin` are
contributed by `plugin_admin`; the CLI's `doctor`, `enable`, `disable` and
`restore` handle recovery. Stored interface-v1 plugins are quarantined with
a re-register message.

Plugins import the shared `src/plugin_api.gene` contract and activate through
an ordinary function receiving PluginHost. They can contribute functions,
commands, prompt sections, docs chapters, model providers, trigger definitions
and web components. Web plugins
add panels to named slots or replace the welcome/status summary through
[the web component API](docs/web-components.md). Command handlers receive
CommandContext and return CommandResult. Generations receive the full standard
library namespace grants. A turn leases one immutable composition; replacing
a plugin waits for old leases before disposal.

Plugins can shape request items through the ordered `request/prepare` hook or
choose compaction thresholds through `history/compact`. The loop records the
resulting protocol facts itself. A plugin observes appended facts by
subscribing to `DurableRecord` and checking its `name`; subscriptions unwind
with the plugin. See [the plugin chapter](docs/plugins.md) for row shapes,
hook behavior and restart recovery.

```gene
(create_trigger
  {^id "nightly-audit" ^kind "cron" ^cron "0 3 * * *"
   ^timezone "Europe/Berlin" ^request "Audit the project."
   ^missed "once" ^overlap "queue_one" ^retention {^keep 30}})
```

Heartbeat uses every_ms; a one-shot schedule uses at (UTC text or epoch
milliseconds); cron uses five fields and an IANA timezone. Definitions can
also be created in the browser's Triggers view or through the CLI:

```text
bin/gene run examples/gene-harness/src/main.gene --workspace /path/to/project triggers
bin/gene run examples/gene-harness/src/main.gene --workspace /path/to/project triggers create trigger.gene
bin/gene run examples/gene-harness/src/main.gene --workspace /path/to/project triggers occurrences nightly-audit
```

The definition file accepts a plain inert Gene map or serde data. Trigger
administration commands inspect or edit definitions without starting due work.
Every due occurrence starts
eventually. An admitted round is never replayed after a crash. Missed work is
skipped or coalesced once; overlap is skipped or queued once. Retention prefers
empty heartbeats and preserves pinned and attention sessions.
`trigger_occurrence_keep` defaults to 256 recent terminal occurrences per
trigger; due/started occurrences and pinned/attention records remain retained.
Durable high-water marks prevent collected occurrence ids from replaying.
`body_gc_interval_ms` defaults to 60000. Idle collection removes superseded
history blobs while preserving live recall bodies and checkpoint fallbacks.

## Model-free specs

From this package directory:

```sh
../../bin/gene test
../../bin/gene test tests/unit
../../bin/gene test tests/integration
../../bin/gene test tests/unit/agents/response_spec.gene
../../bin/gene test tests/integration/ui
../../bin/gene test --name "Harness trigger recovery"
../../bin/gene run ../../tools/generate_harness_event_catalog.gene --check
```

The suite uses Gene's `$test` `describe`/`it` declarations, assertions and
standard failure reports. `gene test` discovers `tests/**/*_spec.gene`;
`--name` selects examples by their full description. `tests/unit/` contains
focused parsing, provider, calendar, composition and API tests.
`tests/integration/` covers runtime composition, persistence, subprocesses,
HTTP and service delivery. Both directories mirror `src/`, with one spec per
targeted source file in each suite; keep related regression cases in that file.
The captured-process lifecycle spec covers the Gene runtime dependency.
Unit specs run directly. Integration specs use `tests/support.gene` for
examples that need an independent Application and fresh workspace under
`tmp/`, with the same spec runner in the child. This preserves working-directory,
lock and scheduler isolation. Failure reports include child diagnostics and
the workspace path for inspection. Crash and signal programs live under
`tests/fixtures/` and are excluded from discovery.

The specs cover patches, questions, history, plugins, sessions, commands,
triggers, recovery, live delivery, concurrency and shutdown. Responsiveness
tests in `tests/integration/runtime/call_supervision_spec.gene` measure HTTP
and cancellation while CPU loops, native collection callbacks and synchronous
process calls run. New tests should use the same
`*_spec.gene` convention; see [Gene testing](../../docs/testing.md).
Use a release binary for the responsiveness tests' 100 ms latency bounds;
build it with `nimble speedy` from the repository root. Debug builds can
exceed those bounds during cleanup.

Both entry points accept `--script FILE` for canned responses. The browser
also has `--offline` for a simple model-free reply.

## Code organization

| Location | Responsibility |
| --- | --- |
| `src/plugin_api.gene`, `src/kernel.gene`, `src/seams.gene` | Plugin contract, registries, activation and host events |
| `src/agents/` | Model requests, response evaluation, instructions and history |
| `src/runtime/` | Workspace ownership, sessions, commands, REPL, rounds, scheduling and composition lifetimes |
| `src/storage/` | Durable events and stored plugin generations |
| `src/ui/` | Component validation, UI settings/descriptors, leased rendering, publication outlines and function actions; shared by CLI and web hosts |
| `src/web/` | Browser service, HTTP/WebSocket transport, authentication, page shell and styles |
| `src/builtin/`, `src/profiles/`, `src/views/` | Built-in plugins, entry-point composition and operator views |
| `client/` | Gene web-profile conversation client and display helpers |
| `client/ui/` | Panel model/storage, keyed DOM reconciliation and request/action controller |
| `src/website/`, `client/website.gene`, `website/` | Informational site and its runnable examples |
| `experiments/ui/` | Optional board plugin, installer and evaluation record |
| `tests/unit/`, `tests/integration/` | Specs mirroring the native source modules |

The plugin import contract stays `src/plugin_api.gene`; plugins do not import
implementation modules from these directories. The browser controller consumes
`src/web/contract.gene`, while `src/ui/` owns the component and action rules.
See the [implementation map](docs/design.md#implementation-map) for individual
modules and development constraints.
