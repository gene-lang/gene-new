# Gene Harness

Gene Harness runs durable conversations in a project workspace. The model
responds with Gene code. The operator sees the code, labeled results, progress
and final replies, questions, and a separate console.

Code uses the standard library and workspace plugin functions directly. File
edits use an apply-patch block. Run the process in an OS sandbox when you want
isolation.

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

## Providers and workspace settings

Settings live in `.gene-harness/config.gene`, using Gene's inert serde data
representation. Non-empty GENE_HARNESS_PROVIDER, GENE_HARNESS_MODEL and
GENE_HARNESS_THINKING_EFFORT environment values override the workspace's
provider, model and effort.

Supported providers are codex, anthropic, claude and openrouter. When unset,
the environment selects OpenRouter when its key is available, Anthropic when
its key is available, or Codex otherwise. An unset model uses that provider's
default.

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

Defaults: ten minutes and 1 GiB per response; 24 turns per user round; five
minutes of running time and 12 turns per trigger round; two concurrent trigger
sessions. Waiting on questions pauses a trigger round's running budget.
Trigger question batches have a 24-hour deadline.

## Browser and CLI

The browser host prints a one-use connection link. Opening it exchanges the
token for an eight-hour cookie and CSRF value. Requests must come from the
host's own origin. Cookies survive process restarts.

The sidebar lists interactive and pinned sessions by default. Kind, status,
trigger, text and time filters query the durable index. Needs attention lists
sessions of every kind. Opening a session acknowledges its attention flag;
another cause can set it again.

Several session tabs can remain open with independent streams. Each turn shows
response code, attachment and patch stubs, next-request items, and replies.
Console output has its own collapsible pane. Questions preselect recommended
choices but submit only when the operator answers. Skip individual questions
or dismiss the batch.

The CLI reads input while a round runs. For questions, enter a numbered choice,
press Enter for the recommendation, enter `-` to skip, or `/dismiss` to
dismiss the batch. Comma-separated numbers answer multiple-choice items.

## Slash commands

Commands run without the model in their own tasks, with per-session ids.

| Command | Behavior |
| --- | --- |
| /help [name] | List commands or show documentation |
| /run code | Evaluate Gene code; display its bounded value, errors and console |
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

## Code responses

```gene
# Inspect the project
# Keep a labeled result for the next turn.
(append_prompt "files" ($fs/list_dir "."))
(Outcome ^prompt "Review the files above." ^reply "I’m inspecting the project.")
```

```gene
# Finish
(Outcome ^done true ^reply "Finished.")
```

The last value steers the loop. Plain values and errors continue as labeled
results or diagnostics. A done Outcome requires a non-empty reply and drops
appended prompt items. Printing reaches the operator's console and never
becomes model history.

Attachments preserve raw bytes:

```text
# Write a file from its attachment
($fs/write_text "report.txt" (attachment "report"))
(Outcome ^done true ^reply "Report written.")
<<<report END
Raw text, including quotes and \d.
END
```

One V4A `*** Begin Patch` / `*** End Patch` block may follow the code.
Preflight computes every edit before writing; the patch applies before code.
A failed anchor writes nothing and skips evaluation. Write failures attempt
to restore originals. A crash can leave a partial multi-file edit; recovery
names the affected files and removes staging siblings.

Outputs have ids such as `[57.tests]`, source lines and form/function labels.
Large bodies become recallable blobs and settled history contains stubs.
`(recall "57.tests")` retrieves a complete stored body after restart.
Compaction retains useful code/comment lines and can summarize old rounds
while preserving the newest request.

## Plugins and triggers

Use register_plugin in response code to register Gene source or attachment
text. Registration and contributions queued during a turn become visible at
its boundary. The next turn binds new functions. Stored interface-v1 plugins
are quarantined with a re-register message.

Plugins import the shared `src/plugin_api.gene` contract and activate through
an ordinary function receiving PluginHost. They can contribute functions,
commands, prompt sections and trigger definitions. Command handlers receive
CommandContext and return CommandResult. Generations receive the full standard
library namespace grants. A turn leases one immutable composition; replacing
a plugin waits for old leases before disposal.

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
../../bin/gene test tests/response_spec.gene
../../bin/gene test --name "Harness trigger recovery"
../../bin/gene run ../../tools/generate_harness_event_catalog.gene --check
```

The suite uses Gene's `$test` `describe`/`it` declarations, assertions and
standard failure reports. `gene test` discovers `tests/**/*_spec.gene`;
`--name` selects examples by their full description. Parsing, provider and
calendar specs run directly. Runtime specs use `tests/support.gene` to run
each example in an independent Application and fresh workspace under `tmp/`,
with the same spec runner in the child. This preserves working-directory,
lock and scheduler isolation. Failure reports include child diagnostics and
the workspace path for inspection. Crash and signal programs live under
`tests/fixtures/` and are excluded from discovery.

The specs cover patches, questions, history, plugins, sessions, commands,
triggers, recovery, live delivery, concurrency and shutdown. Responsiveness
specs measure HTTP and cancellation while CPU loops, native collection
callbacks and synchronous process calls run. New tests should use the same
`*_spec.gene` convention; see [Gene testing](../../docs/testing.md).

Both entry points accept `--script FILE` for canned responses. The browser
also has `--offline` for a simple model-free reply.

See [design](docs/design.md) and [web client](docs/web-client.md).
