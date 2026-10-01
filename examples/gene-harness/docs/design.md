# Gene Harness design

## Principles

- The model acts only by writing Gene code. The only non-code action is a file
  edit, written as an apply-patch block.
- The value the code returns, an `Outcome`, steers the loop. `$println`
  output goes to the operator's console, never to the model.
- There is no authority code. Plugins and response code get the whole
  standard library. Run the process in an OS sandbox for isolation.
- A workspace is the project directory. It holds all Harness state and is
  owned by exactly one process.
- A workspace runs many sessions, loaded on demand and running in parallel.
  Heartbeats, schedules and crons start sessions of their own.
- History stays small and cache-friendly through elision, recall and
  compaction.

## Terms

| Term | Meaning |
| --- | --- |
| Workspace | The project directory; holds `.gene-harness/`; owned by one process |
| Session | A durable conversation: transcript plus history. Kind is interactive, heartbeat, scheduled or cron |
| Trigger | A durable definition that starts sessions without a user |
| Round | A request through its reply: one or more turns, started by a user or a trigger |
| Turn | One exchange: context, response, patch and evaluation, outcome. Numbered across the session |
| Request | What starts a turn: the prompt, the previous turn's outputs, or answers |
| Context | What the provider receives: instructions, history and the request |
| Response | The model's raw text for one turn: code plus raw blocks |
| Attachment, Patch | The raw blocks: named text, and one apply-patch edit |
| Outcome | The value the response code returns |
| Reply | Operator-facing text, progress or final |
| Output | A labeled item in the next request, such as `[57.tests]` |
| Transcript | The complete durable record shown to the operator |
| History | The transcript's model-facing view, after elision and compaction |
| Stub, Recall | The placeholder for elided content, and how to fetch it back |
| Console | `$print`/`$println` output; the operator sees it, the model never does |
| Plugin, Function | A durable extension, and the callables it gives response code |
| Command | An operator slash command that runs without the model |

## Workspace ownership

A workspace is the project directory. The process makes it its working
directory and stores all Harness state beneath `.gene-harness/`.

```text
.gene-harness/
  .gitignore              ignores the directory's own contents
  lock                    permanent flock target
  owner                   PID, entry and startup time
  config.gene             provider/model settings and budgets
  composition/            plugin generations and atomic CURRENT publication
  modules/                content-addressed plugin modules
  blobs/                  content-addressed recall, history and receipt bodies
  events/                 workspace and session streams
  sessions/index          session metadata projection
  triggers/               durable trigger definitions
  web_secret              persisted browser-session secret
  web_sessions            cookie records and expiries
  restart_notice          supervised restart handoff
  shutdown.gene           active rounds cancelled by process shutdown
```

Bootstrap acquires the workspace lock before opening state or activating
plugins. It writes owner atomically after acquiring the lock. A second process
fails with the owner details; a crash releases the kernel lock. The target
itself is not deleted. Shutdown flushes state and releases ownership last.

The CLI and web entry points are owners. There is one event store, Harness
runtime, composition and scheduler per workspace. Event publication is
serialized within that process. CURRENT publication remains atomic for crash
safety. There is no multi-writer merge, stream claim or publication lock.

## Sessions, rounds and turns

A session is a durable conversation with kind interactive, heartbeat, scheduled
or cron. Its index record contains id, title, kind, latest status, creation and
activity times, pinned/attention flags, trigger/occurrence identity, first
request and total turn count.

Listing filters and searches this projection without loading session streams.
Opening, submitting, answering and trigger admission load sessions on demand.
A loaded SessionState holds history, the current round, recall outputs,
console state, viewers and its idle timestamp. Sessions with no running round
or viewer unload after ten idle minutes, flushing first. Waiting questions can
remain durable while unloaded.
Per-session gates cover loading and round admission across parking I/O.
Concurrent retry answers resume once, and completion claims publish one
terminal receipt for each execution.

A round starts from a user or trigger request and contains one or more turns.
Its states are running, waiting, done, failed, cancelled and interrupted.
One session admits one round at a time; a busy submission fails. Different
sessions execute concurrently as root-lane fiber tasks.

Receipts retain request identity, submission sequence and digest. Retrying the
same submission returns its receipt; reusing an identity with different
content fails. The retained receipt window is bounded. A turn is numbered
across the session, rather than restarting the number at each round.

Crash recovery closes open turns synthetically. A running round becomes
interrupted and is never replayed. Waiting rounds retain their question
batches. A shutdown marker distinguishes admitted work deliberately cancelled
by stop from work interrupted by a crash.

## Code response pipeline

A turn builds instructions and history, invokes the provider, reads the raw
response, applies its patch, evaluates code, and interprets the final value.

Instructions contain response grammar and examples, Gene reference material,
workspace/session information, leased function signatures and documentation,
then plugin prompt sections. Pull-only reference material is available through
doc. Credentials are private transport inputs.

A response contains zero or more Gene forms followed by raw blocks:

```text
response   := code? block*
code       := Gene forms; the value of the last form is the outcome
block      := attachment | patch
attachment := "<<<" name SP terminator NL line* terminator (NL | EOF)
patch      := "*** Begin Patch" NL ... "*** End Patch" (NL | EOF)   at most one
name       := [A-Za-z0-9_.-]+, unique within the response
terminator := a token without whitespace, never a whole line of the body
```

```text
<<<name END
body preserved byte for byte
END
```

A block starts only at the beginning of a line. The code is the text before
the first block-start line whose preceding text reads as complete Gene forms,
so `<<<` inside a Gene string does not start a block. Only blank lines may
separate blocks. An unterminated block, a duplicate attachment name, a second
patch, other text after the blocks, or unreadable code is a read error, which
the next request reports. Line 1 is the first line of the response, so a
reported line maps directly to the model's own text. A response without code
takes the patch result as its outcome.

Code accesses the body through attachment. A response may contain one V4A
apply-patch block. Edits are workspace-relative. Preflight resolves all anchors
and computes all new bodies before any write. Matching tries exact, trailing
whitespace-insensitive, then leading/trailing whitespace-insensitive context,
requiring a unique anchor.
EOF can terminate the final block. CRLF structure is accepted without changing
attachment bytes. Patch hunks accept blank context lines, an implicit first
hunk, and insertion after an anchor without removed lines.

Temporary siblings are staged, then renamed in order; deletes and moves
follow. A write failure attempts restoration from the in-memory originals.
Updates and rollback preserve file permissions; symlink updates replace the
target's content while retaining the link. Physical destination aliases are
checked before staging.
Restoration failure reports partial application and attention. Before staging,
turn/response durably records the affected file list. Recovery reports possible
partial application and removes leftover staging siblings. File edits in
different sessions use anchor failure as their conflict signal.

Patch failure skips code. Otherwise the forms execute in an Env whose bindings
are exactly:

| Group | Names |
| --- | --- |
| Loop | `Outcome`, `append_prompt` (rewritten to `append_prompt_at`), `attachment`, `recall` |
| Context | `session_id`, `workspace_root`, `doc` |
| Plugins | `register_plugin`, `plugin_states`, `inspect_plugin`, `enable_plugin`, `disable_plugin` |
| Triggers | `create_trigger`, `list_triggers`, `delete_trigger` |
| Functions | every row of the leased `functions` registry, by name |

The whole standard library is reachable through `$`. Relative paths resolve
against the workspace root, which is the process's working directory.
Evaluation happens in `agents/eval_site`, a module that defines and imports
nothing else, so a response that defines `h` cannot collide with Harness
internals. Located reading preserves source lines and columns through
evaluation, so errors report `line L`.

Before evaluation, each `(append_prompt "label" value)` call site is rewritten
to record its line and its original form. The label must be a literal string
matching `[a-z0-9_]+`. `(attachment "name")` returns the attachment's exact
text, and `(recall "57.smoke")` returns the full body of an elided item from
this session. Unknown names and ids are errors.

| Last value | Effect |
| --- | --- |
| Outcome done + non-empty reply | Finish the round and display the reply |
| Outcome prompt | Continue with the prompt and appended outputs |
| Outcome questions | Persist the batch and wait |
| Plain value | Continue with a labeled result |
| Reader/runtime/patch error | Continue with a labeled diagnostic |

Done rejects prompt/questions and drops appended prompt items with a console
note. A continuing Outcome needs a prompt or appended output. Progress replies
do not finish a round.

Console printing is never a model request item. `$print` and `$println` in
response code, in the plugin functions it calls, and in tasks they spawn write
to the session's console sink through the task context. The CLI prints it
dimmed, prefixed with the session title when several rounds run. The browser
receives `console` messages, and the transcript records ignorable `console`
events capped at 256 KiB per turn with a truncation marker.

```gene
(type Outcome ^props {^done Bool? ^prompt Any? ^reply Str? ^questions Any?
                       ^attention Bool?})
```

`^attention true` flags the session for the operator. A round may take 24
turns, or 12 in a trigger session; reaching the limit fails the round and shows
the last request.

### Next request

A request is text with one item per output, in this order: patch result,
append_prompt items in call order, the Outcome's prompt, errors, answers.

```text
[57.patch] applied: src/report.gene +40 -0 (new)
[57.smoke] line 7: (append_prompt "smoke" (run_smoke "fixtures/orders.csv"))
ok 12 records
[57.result] line 9: Outcome ^prompt
report written; smoke output above
```

- Ids are `<turn>.<label>`. A repeated label gets a suffix, `smoke#2`.
- A header from code reads `line L: <form>`, with the form printed and cut to
  100 characters. An item appended by a plugin function reads `fn <name>`.
  An error header shows the failing line when it is known.
- A Str value is sent verbatim; any other value is printed as Gene data.

A round's first request is the user's prompt, preceded by the items of slash
commands attached since the previous user request, such as
`[c3.sh] /sh git status (exit 0)`. A trigger round's first request is the
trigger's request text prefixed with `[trigger <id> occurrence <occurrence>]`.

### Questions

A batch holds one to eight questions. Each has a unique `^id` and a non-empty
`^prompt`. `^choices` is optional; without it the answer is free text.
`^multi true` allows several choices, `^kind "confirm"` asks yes or no, and
`^recommended` must be one of the choices. Plugins add question kinds as rows
of the `interactions` registry, which validate both the question and its
answer.

The operator may answer any subset or dismiss the batch. Submission is final;
the round resumes with a new turn whose request carries
`[58.answers]` and the frozen answer map, such as
`#{^db "postgres" ^wipe unanswered}`.
Re-sending the same answers is accepted, and conflicting ones are rejected.
Batches are durable (`question/asked`, `question/answered`) and survive
restart. Cancelling the round cancels its questions.

## Execution lifetime and composition

The execution quantum makes ordinary CPU loops and native higher-order
callbacks cooperative. Fiber-aware process/HTTP/file operations park the
calling task. The HTTP host bounds a scheduler batch by elapsed time before
returning to socket polling. Budgets provide runaway protection.

Each turn owns its evaluation task in a Gene scope. Evaluation owns ordinary
tasks spawned by its code. Cancellation joins that work before ending the turn
and releasing its composition lease. A detached task holds no lease. Its
context is closed when the turn ends: append_prompt raises TurnClosed, while
printing remains visible as late console output. After session unload, late
output goes to the workspace event log.

A CompositionSnapshot contains immutable registries and live instances.
Every turn and command leases one snapshot; function bindings and PluginHost
lookups read that revision throughout its lifetime. Composition mutations
queued during a turn are published at its boundary. Publication persists the
new generation, reconciles Cordis into a candidate, publishes the snapshot,
then records composition/changed.

Replaced instances enter retirement. Cordis gives the host a retirement ticket;
the host retires the old generation only after its last snapshot lease ends.
Detached references can retain old callable code, but a disposed plugin
resource reports its own closed-resource error. Plugin state updates append
immediately; there are no turn transactions or staged state commits.

Plugins use the shared plugin_api contract. Other Harness modules are not
shared. Generated modules receive every standard-library namespace grant and
keep Cordis generations for module-graph reclamation. init is bounded and
failed entries are quarantined. Interface-v1 stored plugins require
re-registration. Plugins contribute functions, commands, prompt sections,
interaction kinds and triggers through an ordinary activation function.

## Plugin contract

A plugin is a Gene `mod` whose `init` receives an inert DescriptorContext and
returns a Plugin. `^activate` is the activation function itself and receives
the host; a plugin keeps the host for later callbacks.

```gene
(mod plugin
  (import ^from "src/plugin_api.gene" [Plugin PluginHost])
  (fn init [descriptor]
    (Plugin ^id "line_counter" ^provides [["functions" "count_lines"]]
      ^activate (fn [host]
        (host .PluginHost:contribute "functions"
          {^name "count_lines" ^doc "Count non-empty lines in a file."
           ^fn (fn [path : Str] : Int ...)})))))
```

| PluginHost message | Purpose |
| --- | --- |
| `registry_names`, `row_keys` | Inspect the leased registries |
| `create_registry`, `contribute`, `replace_contribution` | Add registries and rows |
| `resolve`, `provide`, `replace` | Seams |
| `subscribe`, `emit_event` | Observe the event bus; emit the plugin's own event types |
| `state`, `update_state` | Workspace state, or per-session state with `^session` |

The registries are `functions`, `commands`, `prompt`, `views`,
`interactions`, `event_types`, `subscriptions`, `seams` and `triggers`. A
`functions` row is `{^name ^fn ^doc}`. Names are unique across the workspace,
and the instructions list each with its `$runtime/signature` and doc. The core
reserves its built-in command names. `plugin_api` also exports
`append_prompt`, which forwards to the current turn and labels the item
`fn <name>`. Outside an open turn it raises TurnClosed.

`(register_plugin id source ^dependencies [...] ^replace false)` takes a quoted
`mod` form, or text such as an attachment that reads as one form. It
validates the source, preflights `init` under its bounded budget, stores
content-addressed module blobs, and queues the composition change for the turn
boundary. A failing `init` makes the call fail and stores nothing. An entry
whose activation fails, or a stored entry that no longer loads at boot, is
quarantined; `doctor`, `enable` and `disable` repair it.

Long-lived background work belongs in a plugin's activation effect scope,
not in a detached task from response code. Its console output goes to the
workspace log, and it cannot append to a turn.

## Transcript and history

The transcript is the complete durable record shown to the operator: requests,
response code/stubs, patch results, replies, questions, commands and console.
History is the model-facing view, with console excluded.

| Event | Kind | Records |
| --- | --- | --- |
| `round/state` | required | Receipt: id, initiator (`user` or `trigger:<id>`), state, turn range |
| `turn/start`, `turn/end` | required | Session turn number and round; end reason (`done`, `continue`, `questions`, `error`, `interrupted`, `cancelled`) |
| `turn/response` | required | Response text with large attachments and patch bodies stubbed; blob refs; patch file list |
| `turn/patch` | required | Patch result |
| `turn/request` | required | The next request in full and settled forms |
| `question/asked`, `question/answered` | required | Batch and answers |
| `reply` | required | Text and final flag |
| `command` | required | Slash command record, output summary and attachment state |
| `session/state`, `composition/changed`, `plugin/state`, `lifecycle` | required | Session index records, composition generations, plugin state, lifecycle notes |
| `trigger/state`, `trigger/occurrence` | required | Trigger definitions and occurrence states |
| `history/summary` | required | A compaction summary |
| `console`, `trace` | ignorable | Bounded console text; diagnostics |

`events.catalog` is generated by the repository's
`tools/generate_harness_event_catalog.gene`; `--check` verifies it.

Output bodies larger than 16 KiB retain bounded head/tail text. Request items
share a 64 KiB aggregate limit. Bodies over 16 KiB settle to labeled stubs after
their first full context. The active round's initiating request is preserved,
including when its older intermediate messages are compacted. The latest
assistant response stays full through its following request, including failed
patches; older attachments and patches settle to stubs. Transcript events
always use the compact rendering.
Recall maps ids to verified content-addressed blobs and survives restart.
Loaded history is cached in the session. Older full request bodies are replaced
by their settled form in storage. Periodic idle blob collection retains the
latest references and the event store's fallback generations.

Settlement can change the previous full request and the assistant body from
the preceding turn; older message content remains stable. A wire-only budget
advisory changes the newest user message without rewriting stored history or
the system prefix. Anthropic transport currently places cache checkpoints
on the last two assistant messages. Compaction is the exceptional operation
that rewrites old history.
The stable-prefix invariant compares serialized message-content bytes from
actual provider requests, excluding cache-control metadata. Moving those
checkpoints can change older wire JSON while preserving the content boundary:
all messages through the previous assistant response remain byte-identical,
and its following full request is the first content message that settles.

Tokens are estimated from bytes when no provider count is available. Above
75% of the configured window, compaction first keeps comments, append_prompt
and Outcome lines with stubs. If more reduction is required, one provider call
summarizes old whole rounds into a durable history/summary message. The newest
request is preserved; the target is below 55%.

Session collection removes its index entry and stream. Blob writers lease
the store through admission and receipt publication. Collection closes new
body-writer admission and runs at an idle opportunity, preserving every body
reachable from remaining workspace/session projections.

## Triggers

Heartbeat, one-shot and cron definitions are durable workspace records, also
mirrored beneath triggers/. Cron uses five fields and retained IANA timezone
rules; nonexistent civil minutes are skipped and a repeated minute selects
its earlier instant.

An occurrence id combines trigger id and scheduled epoch time. A new session id
is derived from that identity. The occurrence state machine is:

```text
due -> started -> finished
   `-> skipped
```

Due is durable before session creation. Started is published after admission
and before executing response work. Recovery detects an admission receipt even
if a crash preceded the started event. Existing due work is admitted in time
order when capacity and overlap permit. Admitted work is never re-executed.

Missed policy skips downtime or coalesces it into one due occurrence.
Overlap policy skips or retains one queued occurrence; further occurrences
are coalesced as skipped. The workspace trigger-session cap defaults to two.
The cap bounds unfinished trigger rounds, including waiting rounds. Waiting
questions therefore retain a slot until answered or expired.
continue_session reuses a previous occurrence's session when appropriate.

Trigger rounds have their own turn/running-time budgets. Waiting questions
default to a 24-hour deadline; expiry resumes with unanswered values and sets
attention. Failures, interruption and explicit Outcome attention also set
attention. User continuation of a trigger session uses user-round budgets.

Hourly retention applies each trigger's keep-count or age policy. Empty
heartbeats are collected first. Pinned, attention, running, waiting and viewed
sessions are preserved.
The scheduler indexes pending occurrences separately from terminal history.
It retains a configurable recent terminal window (default 256 per trigger)
and durable no-replay watermarks. Administrative CLI commands open this state
without executing a scheduler boot tick.

## Operator commands and shutdown

Slash commands are registered rows with name, usage, documentation, run and
raw_input. The core reserves its built-in names. Unknown commands report a
closest match; a doubled initial slash escapes a literal user prompt.

CommandContext carries session, raw arguments, command id and output sink.
CommandResult carries display value, status and attachment behavior. Command
tasks use the workspace directory, console routing and execution budgets.
Their results attach only to the next user request, never to an intermediate
turn or a trigger request. File views attach a pointer.

Stop disables new rounds, commands and trigger starts, cancels running rounds,
and preserves pending questions/due occurrences. Cancellation receipts and a
shutdown marker become durable before cleanup. A five-second watchdog ends
uncooperative cleanup. Normal completion flushes and releases ownership.

The launcher restarts on exit 75; other exit statuses end supervision. Direct
gene run maps restart to stop. Browser cookies and the secret persist for
eight hours. Restart clients reconnect and receive a restarted notice.

## Gene runtime support

The Harness relies on general runtime features, documented in
[docs/stdlib.md](../../../docs/stdlib.md) with spec coverage:

| Feature | Harness use |
| --- | --- |
| `$runtime/with_context`, `$runtime/context`; spawned tasks inherit the context | Current turn and session for plugin append_prompt and lookups |
| Task-context `^output` sink for `$print`/`$println` | Per-session console routing, including late output |
| `$parse/read_all ^locs true`, `$node/rebuild` | Response lines for headers and error locations |
| `$os/set_cwd` | The workspace becomes the working directory |
| Execution quantum, including callbacks run by native higher-order builtins | Parallel sessions stay responsive during CPU-bound code |
| Fiber-aware `$os/exec`, `$fs/read_text`, `$fs/write_text` | Blocking calls park the fiber instead of the lane |
| `$fs/try_lock` | Workspace ownership; the kernel releases it on exit |
| `$fs/rename`, `$fs/info` | Patch commits and file views |
| `$os/read_line_async`, `$io/flush_stdout` | A CLI that stays responsive while rounds run |
| Process groups for captured subprocesses | `/sh` cancellation stops the whole pipeline |
| `$os/exit` | The shutdown watchdog and supervised restart status |
| `$runtime/sandbox_namespaces` | The complete namespace grant for plugin generations |

## Implementation map

| Responsibility | Module |
| --- | --- |
| Workspace boot and lock | runtime/bootstrap, runtime/workspace_lock |
| Session index/load/unload/recovery | runtime/sessions |
| Round admission/receipts/cancellation | runtime/round_controller |
| Response grammar and evaluation | agents/response, agents/turn_eval |
| Outcomes and labeled items | agents/outcome |
| Turn loop and instructions | agents/turn_loop, agents/instructions |
| Elision/recall/compaction | agents/history |
| Composition snapshots and retirement | runtime/composition, runtime/cordis_adapter |
| Plugin contract and activation | plugin_api, kernel, storage/workspace |
| Patch preflight/commit/recovery | runtime/patch |
| Commands, triggers and supervisor | runtime/commands, runtime/triggers, runtime/supervisor |
| Durable streams and catalog | storage/state, events.catalog |
| Browser service/transport/UI | web/session_service, web/push, web/server, client/ |
