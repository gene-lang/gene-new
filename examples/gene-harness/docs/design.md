# Gene Harness design

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
console state, viewers and its idle timestamp. Idle sessions with no running
round or viewer unload after the configured timeout, flushing first. Waiting
questions can remain durable while unloaded.
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

A response contains zero or more Gene forms followed by raw blocks. Named
attachments use a column-one opener and an exact closing marker:

```text
<<<name END
body preserved byte for byte
END
```

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

Patch failure skips code. Otherwise the forms execute in an Env containing
the full standard library, leased plugin functions, workspace_root,
register_plugin, trigger functions, doc, attachment, recall and append_prompt.
Located reading preserves source lines and columns through evaluation.
Imported Harness modules are outside the response evaluation site's lexical
bindings.

| Last value | Effect |
| --- | --- |
| Outcome done + non-empty reply | Finish the round and display the reply |
| Outcome prompt | Continue with the prompt and appended outputs |
| Outcome questions | Persist the batch and wait |
| Plain value | Continue with a labeled result |
| Reader/runtime/patch error | Continue with a labeled diagnostic |

Done rejects prompt/questions and drops appended prompt items with a console
note. A continuing Outcome needs a prompt or appended output. Progress replies
do not finish a round. Console printing is never a model request item.

Outputs carry turn-qualified ids, source lines, original form text and plugin
function names. Repeated labels receive suffixes. Questions allow choices,
recommended values, multiple selections and custom interaction validators.
Partial answers and dismissal produce unanswered values. Answers are
idempotent and conflicting re-answers fail.

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

## Transcript and history

The transcript is the complete durable record shown to the operator: requests,
response code/stubs, patch results, replies, questions, commands and console.
History is the model-facing view, with console excluded.

Output bodies larger than 16 KiB retain bounded head/tail text. Request items
share a 64 KiB aggregate limit. Bodies over 2 KiB settle to labeled stubs after
their first full context. Assistant attachments and patches are elided once.
Recall maps ids to verified content-addressed blobs and survives restart.
Loaded history is cached in the session. Older full request bodies are replaced
by their settled form in storage. Periodic idle blob collection retains the
latest references and the event store's fallback generations.

Settlement changes the latest previously full request while older message
content remains stable. Anthropic transport currently places cache checkpoints
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
