# Gene Harness web client

## Start and connect

```text
bin/gene run examples/gene-harness/src/main.gene web --workspace /path/to/project
# In another terminal:
bin/gene run examples/gene-harness/src/main.gene --workspace /path/to/project link
```

The web host owns the workspace lock and is the only production profile.
Multiple browser and CLI clients share it. The host runs independently of its
clients; closing a client leaves admitted rounds and operator commands running.

The owner retrieves a reusable connection link with `link`. Its token is stored
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
client has full owner permissions. Startup diagnostics omit the connection token.

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
slash commands clear both the composer and its hint row.

Each open session tab retains its own socket, frame sequence, snapshot,
records, round state and reconnect state. Switching tabs preserves the draft
and cached transcript. Background streams continue updating their tabs.
Closing a tab releases its viewer, allowing later idle unloading.

A session can be renamed and pinned or unpinned. Metadata edits carry the last
seen revision; a stale edit fails rather than overwriting a newer one.

Each turn has a disclosure containing response code, attachment/patch stubs,
patch results, next-request items, and progress replies. A final reply appears
once at the conversation level, outside its turn disclosure. Completed status
shows the status label without repeating reply text. Response code is
highlighted when expanded. The console is a separate collapsible pane;
late output is labeled. Command blocks stream while the command runs and
retain their final value or exit status.

Question batches show recommended choices preselected. Nothing is submitted
automatically. Free text, multiple selections, per-question skipping and
dismiss-all are supported. A submission is final for the batch. Saved answers
can be retried with the same identity; conflicting re-answers are rejected.

The Triggers view creates heartbeat, one-shot and cron definitions, with
missed/overlap policies, continuation and retention. A trigger's occurrence
view shows due, started, finished and skipped entries; admitted occurrences
open their session.
Occurrence listings retain the configured recent terminal window; due/started
and pinned/attention entries remain available. Historical occurrence events
remain in the durable workspace transcript.

## Workspace panels and recovery

Ordinary plugin components occupy the named slots described in
[web components](web-components.md). The opt-in
[workspace UI experiment](../experiments/ui/README.md) adds one selected panel
with keyed forms, configurable width/side and a small set of theme tokens.
Layout settings are shared by the workspace. Each browser tab retains its own
panel state and drafts in session storage, independently of its chat tabs.

Stateful descriptors in status and snapshot messages contain no rendered tree.
The panel requests its view with the current filter/selection and rejects
responses from an older instance, request sequence, view revision or data
revision. DOM reconciliation retains keyed inputs and dirty values. A new
state version resets saved state; a compatible plugin replacement keeps it.

Save calls a registered function through a command task. The panel tracks the
receipt under the session selected at submission, even after switching to
another conversation. Failures appear in the panel and attach once to that
original session's next user request. Successful action blocks stay out of the
chat transcript. Resolve action looks up the receipt before any explicit retry.

Render failures retain the last tree with actions disabled. Retry view keeps
drafts; Discard edits intentionally reloads current field values. The shared
HTTP helper aborts requests after 30 seconds. `/ui/default` enters the host's
recovery page, retaining the selected conversation and omitting plugin views,
render callbacks and theme overrides. Its requests carry `ui=default`.
Return to workspace UI leaves recovery without changing shared settings.

## Wire protocol 6

The native host and Gene web-profile client share web/contract.gene.
The current version is 6. A version mismatch stops interaction and asks for a
reload.

Every WebSocket frame has protocol, epoch, decimal-text sequence, type,
session and data. Sequence is per connection. An empty session denotes a
workspace message. A session-specific frame goes only to peers viewing that
session.

| Message | Data |
| --- | --- |
| status | Workspace, provider/model, commands, ordinary components, session context and render freshness |
| session/list | Default session records and attention records |
| attention | Sessions requiring attention |
| snapshot | Session metadata, records, current/history receipts, questions and next submission sequence |
| round/state | Admission, waiting or terminal receipt |
| turn | Response code, request items or patch result record |
| reply | Progress or final reply record |
| questions | Durable question batch |
| console | Session console record, including its late flag |
| command | Streaming chunk or final command record |
| mode/state | Current input mode or nil; the frame also carries a change reason |
| ui/state | Layout, theme and stateful-view descriptors; also invalidates ordinary component status across the workspace |
| ui/action | Workspace-delivered action receipt carrying its submitting session; displayed in the panel |
| ready | Initial state delivery is complete |
| stopped | Process stopped, or is restarting under supervision |
| restarted | Reconnected process completed a supervised restart |
| error | Structured code and message |

Session records contain durable ids, round_id and session-wide turn numbers.
Live records merge by id with the next snapshot. A final snapshot supersedes
provisional command output without dropping the command's console.

### HTTP endpoints

All API paths use /api/v6.

| Method and path | Purpose |
| --- | --- |
| GET /connection | Public endpoint/workspace/protocol/instance metadata for local discovery; no credentials or conversation records |
| POST /auth/exchange | Exchange the reusable owner token for a cookie and CSRF value |
| POST /auth/reset | Replace the owner token and revoke all client credentials and streams |
| POST /control | Stop/restart with optional submitting session and confirmation |
| GET /status?session=ID | Authentication check, CSRF value and host status with ordinary components rendered for that session; omit ID for an unselected conversation |
| GET /events?session=ID | Upgrade to the session's ordered stream |
| GET /sessions | Query index filters |
| POST /sessions | Create an interactive session |
| PATCH /sessions/ID | Rename/pin with metadata revision |
| POST /sessions/ID/open | Acknowledge attention when activating an open tab |
| GET /sessions/ID/snapshot | Fetch transcript state |
| POST /sessions/ID/rounds | Admit input with request id and submission sequence; `literal: true` submits prompt text without slash-command parsing |
| GET /sessions/ID/rounds/ROUND | Retrieve an idempotent receipt |
| POST /sessions/ID/answers | Answer/dismiss a question batch |
| POST /sessions/ID/cancel | Cancel a round |
| POST /sessions/ID/commands | Submit a slash command; optional request id plus submission sequence enables deduplication |
| GET /sessions/ID/commands/COMMAND | Retrieve an operator-command receipt |
| POST /sessions/ID/commands/COMMAND/cancel | Cancel an operator command |
| GET /sessions/ID/requests/REQUEST?kind=round\|command | Look up a retained receipt by client request id |
| POST /sessions/ID/mode/input | Submit `{instance, input_id, text}` to the current input mode |
| POST /sessions/ID/mode/leave | Close the named mode instance through the host |
| POST /ui/render | Render one experimental component with its instance, revision, request sequence and view state |
| POST /ui/settings | Explicitly enable or configure the experimental workspace layout |
| POST /sessions/ID/ui/actions | Submit a registered function as a UI command with structured arguments and an input identity |
| GET /sessions/ID/ui/actions/INPUT | Look up the original action receipt without executing it |
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

Run, shell and view commands remain available while a round runs. Their
attachments wait for the next user prompt; they never appear in a running
round's intermediate context. Both clients create and list sessions through
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

The package's `gene test` specs cover protocol-6 service delivery, live
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

The server compiles and publishes these assets at startup; this command is a
development check. The web builder currently requires unique source basenames
across imported modules. See the [design notes](design.md#development-constraints).
