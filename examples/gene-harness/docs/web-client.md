# Gene Harness web client

## Start and connect

```text
bin/gene run examples/gene-harness/src/main.gene web --workspace /path/to/project
# Open the Browser URL printed at startup.
```

The web host owns the workspace lock and is the only production profile.
Multiple browser and CLI clients share it. The host runs independently of its
clients; closing a client leaves admitted rounds and operator commands running.

Interactive startup prints the reusable connection link; `link` retrieves it
again later or for a host whose stdout is redirected. Its token is stored
in an owner-only file and stays valid across restart until explicit reset. The
page exchanges it for an HttpOnly, SameSite cookie and CSRF value, then removes
the token from the URL. Cookies have a one-year browser lifetime; the host keeps
credentials valid until reset. Reopen the same link if the browser discards its
cookie. Different browsers can use the same link at different times.
Opening the link in an already authenticated browser reuses its cookie and
CSRF value, keeping other tabs' pending requests valid.

The first start chooses a free loopback port and remembers it. Later fresh
starts reuse it or announce a fallback if occupied. Fixed-port starts and
supervised restarts fail if their selected port is unavailable. Keeping the
port preserves the Origin, cookie name and bookmarks. If the address changes,
retrieve the current link; browser-local state from the old Origin is not
automatically migrated.

`auth reset` replaces the token, invalidates all client credentials and closes
authenticated streams. Admitted work continues. The CLI uses the same exchange,
cookie and CSRF checks, with an owner-only local cookie cache. Every authenticated
client has full owner permissions. Captured or redirected startup diagnostics
omit the connection token.

The host binds to 127.0.0.1. It checks Host and Origin, and mutations require
the current CSRF value. Responses have no-store and restrictive content
security headers. The informational /about/ page is independent of session
records and model calls.

Use --offline for a simple canned reply, or --script FILE for a list of
scripted responses. Both are useful for model-free testing.

## Sessions and operator workflow

Interactive and pinned sessions appear by default. Kind, status, trigger,
search and activity-date controls query the workspace's session index. Search
covers title and first request. Needs attention lists every kind of session.
Opening a session or admitting a new user round acknowledges attention; a later failure, interruption,
expired question batch or explicit Outcome can set it again.
The first sentence of the first user request supplies a short title when the session still has its
default name. Custom titles are preserved. The workspace header and status
drawer show the provider, model and configured reasoning effort.
Provider failures appear in their turn disclosure with a timestamp and error
detail, including when generation never produced response code. Accepted
slash commands clear both the composer and its hint row. Their input appears
as a “You” message in the same right-aligned blue box as a prompt, with
left-aligned text. Execution results appear separately under Gene. Both
entries survive reload and remain together when paging through history.

Each open session tab retains its own socket, frame sequence, snapshot,
records, round state and reconnect state. Switching tabs preserves the draft
and cached transcript. Background streams continue updating their tabs.
Closing a tab releases its viewer, allowing later idle unloading.

The plugin manager's development-session links open `/?session=ID&view=harness`
in the same browser tab. This overrides a remembered full-screen plugin view
and restores the selected session's prompt draft. Drafts use browser
`sessionStorage`: switching A → B → A or reloading that tab preserves each
session's text; separate browser tabs do not synchronize their drafts.

The hamburger button at the start of the conversation tab bar toggles the left
conversation menu. On desktop, hiding it gives the space to the conversation
and any docked plugin view; the choice is remembered in the current browser
tab. On narrow screens it opens a drawer, which closes after selecting a
conversation, using Close menu, or pressing Escape.

The layout comes from the optional [sidebar plugin](sidebar.md). Disabling
that plugin removes the panel and hamburger, while existing conversation tabs
and work remain available. Recovery UI provides host-owned navigation even
when the plugin is missing or broken.

A session can be renamed and pinned or unpinned. Metadata edits carry the last
seen revision; a stale edit fails rather than overwriting a newer one.

A submitted prompt appears immediately as a “You” message and replaces the
welcome content, including while a newly created session connects. Pending
submissions and admitted receipts keep it visible through delayed snapshots
and request preparation. The real request record replaces this display
fallback by round identity. A definite rejection removes the unadmitted
message and preserves the composer draft; an uncertain outcome keeps the
recoverable submission visible.

History opens on its latest bounded page. The saved `first_request` is always
shown as the first “You” prompt, above “Load earlier messages” when earlier
history is omitted. It is the full submitted prompt text, not the conversation
title; rename does not change it. Attachment-only submissions save an
“Attachment: <name>” label and their media descriptors, and trigger sessions save
the trigger's request. When the sequence-1 request record is loaded, it replaces
the fallback rather than appearing twice. Identical later prompts remain visible.

Each turn groups the **Request** it receives, the Gene **Response** returned by
the model, and its live **Output**, in that order. The initial message is labeled
**User** (or Trigger/Card action/Parent agent for other sources) and is not
repeated inside its first turn. A generated continuation belongs to the next
turn. Turn headings and their Request, Response, and Output disclosures start
collapsed. Cards, media, questions, and errors stay inside their producing turn.
Pending turns have a blank summary; a host-extracted literal reply hint may fill
it when code arrives, and the evaluated reply is authoritative. A concise reply
appears only in its own heading as `Turn N: <reply>`. The full final reply appears
once under **Agent**, outside the last turn. Completed status
shows the status label without repeating reply text. Response code is
highlighted when expanded. Printed text appears in an **Output · live** disclosure
inside its owning turn, collapsed by default. Late output stays with its original
turn and is labeled. Output is held only in page memory: snapshots, pagination,
reloads and new browser tabs never restore it. Same-page conversation switching
and temporary reconnects retain received chunks; a host restart clears them.
Command printing has a separate live disclosure under its command. Returned
command results, help text, interactive shell output and exit status keep their
normal presentation. Diagnostic console events and CLI transcript access remain
available independently of the browser's temporary display.

At an operator turn limit, the receipt ends **paused** and the unsent Request
stays hidden. **Continue** admits a linked round with another normal turn budget;
**Continue until finished** automatically continues across later round budgets,
stopping for completion, input, failure, or Stop. Automatic status shows the
cumulative task turns. Both actions retain the logical input, refresh transient
voice/budget guidance, and replace its trailing model-history message rather
than duplicating it. A continuation round has no new User bubble: its first turn
shows the retained Request. New user input supersedes an unclaimed pause.

The final reply should embed its selected generated image using the returned
media descriptor URL: `![Description](/api/v8/media/ID)`. The renderer treats
historical `/api/v<N>/media/ID` paths as media-ID references and resolves them
through the current route. Other image URLs remain literal text on all Markdown
surfaces, including `/view` and plugin docs. Image markup is omitted from turn
summaries and fallback speech; saved reply text and explicit speech stay intact.

Question batches show recommended choices preselected. Nothing is submitted
automatically. Free text, multiple selections, per-question skipping and
dismiss-all are supported. A submission is final for the batch. Saved answers
can be retried with the same identity, even after the session has moved on;
conflicting re-answers are rejected. A question with a `^view` shows that view
instead of its default controls; its answer buttons select draft values and
**Answer** still submits the batch. Once answered, the view stays in the
transcript, read-only, with the saved answers marked.

Conversation cards ([cards](cards.md)) appear inline at the turn that made
them. A page enables a card only when it sees the card defined live; after a
reload, cards with code or command buttons show **Enable**. While the round
that owns a card runs, the card shows "Updating…" and refuses clicks.

The Triggers view creates heartbeat, one-shot and cron definitions, with
missed/overlap policies, continuation and retention. A trigger's occurrence
view shows due, started, finished and skipped entries; admitted occurrences
open their session.
Occurrence listings retain the configured recent terminal window; due/started
and pinned/attention entries remain available. Historical occurrence events
remain in the durable workspace transcript.

## Workspace views and recovery

Ordinary plugin components occupy the named slots described in
[web components](web-components.md). The opt-in
[workspace UI experiment](../experiments/ui/README.md) supports one selected
plugin view, either full screen or docked beside Classic Harness. View choice,
presentation, dock side/width, and drafts belong to each browser tab. Shared
workspace settings supply defaults only. See [workspace views](workspace-views.md)
for shortcuts, navigation buttons, storage, and simultaneous-tab behavior.

Stateful descriptors in status and snapshot messages contain no rendered tree.
The panel requests its view with the current filter/selection and rejects
responses from an older instance, request sequence, view revision or data
revision. DOM reconciliation retains keyed inputs and dirty values. A new
state version resets saved state; a compatible plugin replacement keeps it.

Save calls a declared function through a workspace action task. No conversation
is created or implicitly supplied. The independent action log owns its receipt;
failures stay in the UI and are available through `ui_action_receipts` when
requested. Resolve action checks the original identity and generation before
an explicit retry. It never invents a replacement identity for an unknown result.

Render failures retain the last tree with actions disabled. Retry view keeps
drafts; Discard edits intentionally reloads current field values. The shared
HTTP helper aborts requests after 30 seconds. `/ui/default` enters the host's
recovery page, retaining the selected conversation and omitting plugin views,
render callbacks and theme overrides. Its requests carry `ui=default`.
Return to workspace UI leaves recovery without changing shared settings.

## Wire protocol 8

The native host and Gene web-profile client share web/contract.gene.
The current version is 7. A version mismatch stops interaction and asks for a
reload.

Every WebSocket frame has protocol, epoch, decimal-text sequence, type,
session and data. Sequence is per connection. An empty session denotes a
workspace message. A session-specific frame goes only to peers viewing that
session.

| Message | Data |
| --- | --- |
| status | Workspace, provider/model, light/dark appearance, commands, ordinary components, session context and render freshness |
| appearance | The workspace's new light/dark mode; sent to every peer, including `/ui/default` |
| session/list | Default session records and attention records |
| attention | Sessions requiring attention |
| snapshot | Session metadata, records, current/history receipts, questions and next submission sequence |
| round/state | Admission, waiting or terminal receipt |
| turn | Response code, request items or patch result record |
| reply | Progress or final reply record |
| questions | Durable question batch |
| card | A card's public record and the change: `defined`, `updated`, `enabled`, `stale` or live `progress` |
| console | Live printed output with its turn or command owner and late flag; not replayed into the browser from snapshots |
| command | Streaming chunk or final command record |
| mode/state | Current input mode or nil; the frame also carries a change reason |
| ui/state | Layout, theme and stateful-view descriptors; also invalidates ordinary component status across the workspace |
| ui/action | Workspace action receipt and current admission-generation metadata; no submitting conversation |
| notifications/state | Isolated inbox revision, publication watermark, opened watermark and visible producer messages |
| notifications/progress | Transient source/key progress with original work context; never replayed on reconnect |
| ready | Initial state delivery is complete |
| stopped | Process stopped, or is restarting under supervision |
| restarted | Reconnected process completed a supervised restart |
| error | Structured code and message |

Session records contain durable ids, round_id and session-wide turn numbers.
Live records merge by id with the next snapshot. A final snapshot supersedes
provisional command output without dropping the command's live output.

### HTTP endpoints

All API paths use /api/v8.

| Method and path | Purpose |
| --- | --- |
| GET /connection | Public endpoint/workspace/protocol/instance metadata for local discovery; no credentials or conversation records |
| POST /auth/exchange | Exchange the reusable owner token for a cookie and CSRF value |
| POST /auth/reset | Replace the owner token and revoke all client credentials and streams |
| POST /control | Stop/restart with optional submitting session and confirmation |
| GET /status?session=ID | Authentication check, CSRF value and host status with ordinary components rendered for that session; omit ID for an unselected conversation |
| GET /events?session=ID | Upgrade to the session's ordered stream |
| GET /notifications | Producer snapshot; independent of workflow question/attention state |
| GET /notifications/ID | Retained message detail, including cleared revisions |
| POST /notifications | Publish an operator-owned message |
| POST /notifications/ack | Advance opened-through watermark using `through` |
| POST /notifications/clear | Clear observed `{id, revision}` entries in `messages` |
| POST /notifications/action | Resolve a declared action; mutations carry original session/request id/command sequence |
| GET /sessions | Query index filters |
| POST /sessions | Create an interactive session |
| PATCH /sessions/ID | Rename/pin with metadata revision |
| POST /sessions/ID/open | Acknowledge attention when activating an open tab |
| GET /sessions/ID/snapshot | Fetch transcript state |
| POST /sessions/ID/rounds | Admit input with request id and submission sequence; `literal: true` submits prompt text without slash-command parsing; `card` sends a card's state with the text |
| GET /sessions/ID/rounds/ROUND | Retrieve an idempotent receipt |
| POST /sessions/ID/answers | Answer/dismiss a question batch |
| POST /sessions/ID/cards/CARD/actions | Run a card `update` or `enable` with input id and the definition and card revisions shown |
| GET /sessions/ID/card-actions/INPUT | Look up a card action receipt without running it |
| POST /sessions/ID/cancel | Cancel a round |
| POST /sessions/ID/commands | Submit a slash command; optional request id plus submission sequence enables deduplication; `card` names the card revisions behind a card's command button |
| GET /sessions/ID/commands/COMMAND | Retrieve an operator-command receipt |
| POST /sessions/ID/commands/COMMAND/cancel | Cancel an operator command |
| GET /sessions/ID/requests/REQUEST?kind=round\|command | Look up a retained receipt by client request id |
| POST /sessions/ID/mode/input | Submit `{instance, input_id, text}` to the current input mode |
| POST /sessions/ID/mode/leave | Close the named mode instance through the host |
| POST /ui/render | Render one experimental component with its instance, revision, request sequence and view state |
| POST /ui/settings | Explicitly enable or configure the experimental workspace layout |
| POST /ui/actions | Submit a workspace function action with generation-bound input identity, publication revisions, and structured arguments |
| GET /ui/actions/INPUT | Look up its workspace receipt without executing it |
| POST /ui/actions/INPUT/cancel | Request cancellation by the original workspace action identity |
| GET /triggers | List definitions |
| POST /triggers | Create a definition |
| DELETE /triggers/ID | Disable/delete a definition |
| GET /triggers/ID/occurrences | List occurrence state |
| GET /trigger-occurrences | List retained occurrences across triggers |

Snapshots include both `next_submission_seq` for rounds and `next_command_seq`
for operator commands. CLI mutations are never automatically replayed after a
lost response. Matching retained command identities return the existing receipt;
conflicting content or stale sequences fail. Commands interrupted by a previous
host become terminal `interrupted` receipts when recovered.

Session query parameters are kind, status, attention, q, trigger, since and
until, plus an after cursor for paging. Index queries do not load transcript
streams. Decimal sequence and
revision values are sent as text where the contract requires them.

Status includes `status_session`, `status_revision` (composition/workspace data),
and `status_sequence` (render-start order), scoped to its process `epoch`.
These are captured before component callbacks run. The active conversation
coalesces workspace invalidations into a status request and rejects responses
from older revisions, prior processes, other sessions or earlier renders.
Selecting a cached tab refreshes its status without reusing stale component
content. Stateful panels keep their own keyed drafts and view state.

Input errors preserve structured diagnostics: unknown command, busy session,
submission/revision conflict, unknown session or invalid answer. They do not
become model requests.

## Commands and submission recovery

`/repl` enters a persistent Gene input mode. Its label, hint and Eval button
come from the plugin row. While it is open, all composer input is code and
the command picker is hidden. Exit/quit or the Leave control returns to chat.
The action button becomes Stop during a REPL input and cancels that command;
it becomes Stop during a chat round and cancels that round. Enter still sends
slash commands during a chat round. A short guard after completion prevents
a late Stop click from submitting a draft.

`/sh <command>` runs once; bare `/sh` enters Shell mode with a Run button.
Subsequent input is shell code rather than a model prompt. Cwd, variables and
exports persist in the session's shell until `exit`, `quit`, or Leave. Stop
cancels the running input and resets the shell process. The same input identity
and receipt recovery rules apply to both Shell and REPL modes.

Snapshots include `mode` with its instance and running command id. Input and
leave requests name that instance; `mode_open` and `mode_closed` return 409
with the current state when the browser and server disagree. Mode input ids
are persisted with command records. An unknown outcome keeps its id in browser
storage and is resolved from snapshots or a manual resubmission of the same
id; it is never retried automatically. Incomplete input retains its draft.
Reload/reconnect within the 60-second viewer grace retains bindings and lets
Stop cancel an input already running. Process restart reports no mode.

A registered initial /name is a command; its raw argument string is preserved.
Unknown names report a closest match. Initial // escapes a literal slash.
The web command picker uses server-provided usage/documentation.

Run, shell and view commands remain available while a round runs. Run, shell
and REPL output stays in the operator transcript. View pointers wait for the
next user prompt and never appear in a running round's intermediate context.
Both clients create and list sessions through
the session service; CLI uses `sessions`, and `/new` and `/sessions` are retired.

A pending prompt retains its request id and submission sequence in browser
storage until admission is known. Reconnection checks receipts and retries
that same identity. A newer terminal stream receipt must not be overwritten
by a late admission response. Drafts are stored per session.

A sequence gap, dropped frame or disconnected socket invalidates that stream
and requires a fresh snapshot. Each tab reconnects independently. There is no
periodic HTTP polling while streams remain connected. Connection recovery and
event-driven component refreshes use status requests.

Stop/restart may return confirmation_required when other sessions are running.
The dialog names those sessions and offers confirmation or keeping them
running. A stopped browser cannot start the process; it directs the operator
to a terminal. A supervised restart keeps reconnection enabled, retains the
cookie, changes the process epoch and delivers a restarted notice.

## Implementation and specs

| Module | Responsibility |
| --- | --- |
| `client/main.gene` | Conversation navigation, commands, questions, streams and cached records |
| `client/state.gene` | Transcript merge and grouping helpers |
| `client/view.gene`, `client/markdown.gene`, `client/highlight.gene` | Turn and value display |
| `client/components.gene` | Ordinary slot components |
| `client/ui/model.gene` | Panel types, browser storage, draft bookkeeping and control availability |
| `client/ui/tree.gene` | Keyed DOM patching with edit/submit handlers supplied by the controller |
| `client/ui/controller.gene` | Panel render requests, actions, receipt recovery and layout |
| `src/ui/` | Native component validation, descriptors, rendering, outlines and action admission |
| `src/web/page.gene`, `src/web/style.gene` | Host page shell, compiled client entry and styling |
| `src/web/server.gene`, `src/web/connection.gene` | HTTP routing, remembered ports, ready descriptors and server lifecycle |
| `src/web/auth.gene`, `src/cli/` | Shared owner exchange, credential reset, CLI operations and receipt polling |

web/session_service.gene connects the UI to the shared SessionManager and
RoundController. web/push.gene routes ordered frames and viewer lifetimes.
The web host runs all rounds, including prompts submitted by the CLI; there is
no per-session plugin activation or second CLI runtime.

The package's `gene test` specs cover protocol-8 service delivery, live
records before completion, console routing, custom question validation,
metadata revisions/attention, command execution, restart authentication,
concurrent sessions and shutdown. Responsiveness specs run CPU loops,
native callback loops and synchronous processes while another session,
a heartbeat and HTTP work continue.

UI specs live in `tests/unit/ui/` and `tests/integration/ui/`; they cover
component validation, render isolation, publication outlines, revision
conflicts, cross-session actions and receipt recovery. The scripted model
repair sequence lives in `tests/integration/agents/harness_turn_spec.gene`.
CLI-submitted prompts can use the same UI previews without a browser connected.

To verify the browser import graph from the repository root:

```text
bin/gene build --target web --out-dir tmp/harness-web-client examples/gene-harness/client/main.gene
```

The compiled initial-prompt rendering regression can then be run from the
repository root with:

```text
node examples/gene-harness/tests/history_start.mjs tmp/harness-web-client/view.mjs
node examples/gene-harness/tests/first_submission.mjs tmp/harness-web-client/main.mjs
```

It checks
prompt styling and ordering above the history gap, identity-based duplicate
suppression, safe full text, rename independence, triggers and attachments.
It also checks heading-only intermediate replies in expanded turns and unchanged
conversation-level final reply rendering.
The submission check delays admission and snapshots, covers prompt replacement,
late completion, rejection and uncertain recovery, session creation, identical
prompts in different rounds, and attachment-only input.
This DOM-fixture check is not a live-browser acceptance check.

The server compiles and publishes these assets at startup; this command is a
development check. The web builder currently requires unique source basenames
across imported modules. See the [design notes](design.md#development-constraints).
