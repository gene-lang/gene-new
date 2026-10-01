# Gene Harness web client

## Start and connect

```text
bin/gene run examples/gene-harness/src/web/server.gene --workspace /path/to/project --port 8095
```

The host owns the workspace lock. It cannot run alongside a CLI owner of that
workspace. It prints a one-use bootstrap link, valid for ten minutes.

The page exchanges the token for an eight-hour HttpOnly, SameSite cookie and
CSRF value. The cookie name includes the port. The secret and browser-session
records persist beneath .gene-harness, so a supervised restart does not require
a new bootstrap link. Cookie expiry still requires reconnection through a new
link.

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
Opening a session acknowledges attention; a later failure, interruption,
expired question batch or explicit Outcome can set it again.

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

## Wire protocol 4

The native host and Gene web-profile client share web/contract.gene.
The current version is 4. A version mismatch stops interaction and asks for a
reload.

Every WebSocket frame has protocol, epoch, decimal-text sequence, type,
session and data. Sequence is per connection. An empty session denotes a
workspace message. A session-specific frame goes only to peers viewing that
session.

| Message | Data |
| --- | --- |
| status | Workspace, provider/model, command list and current activity |
| session/list | Default session records and attention records |
| attention | Sessions requiring attention |
| snapshot | Session metadata, records, current/history receipts, questions and next submission sequence |
| round/state | Admission, waiting or terminal receipt |
| turn | Response code, request items or patch result record |
| reply | Progress or final reply record |
| questions | Durable question batch |
| console | Session console record, including its late flag |
| command | Streaming chunk or final command record |
| ready | Initial state delivery is complete |
| stopped | Process stopped, or is restarting under supervision |
| restarted | Reconnected process completed a supervised restart |
| error | Structured code and message |

Session records contain durable ids, round_id and session-wide turn numbers.
Live records merge by id with the next snapshot. A final snapshot supersedes
provisional command output without dropping the command's console.

### HTTP endpoints

All API paths use /api/v4.

| Method and path | Purpose |
| --- | --- |
| POST /auth/exchange | Exchange one-use bootstrap token |
| GET /status | Authentication check, CSRF value and host status |
| GET /events?session=ID | Upgrade to the session's ordered stream |
| GET /sessions | Query index filters |
| POST /sessions | Create an interactive session |
| PATCH /sessions/ID | Rename/pin with metadata revision |
| POST /sessions/ID/open | Acknowledge attention when activating an open tab |
| GET /sessions/ID/snapshot | Fetch transcript state |
| POST /sessions/ID/rounds | Admit a user prompt with request id and submission sequence |
| GET /sessions/ID/rounds/ROUND | Retrieve an idempotent receipt |
| POST /sessions/ID/answers | Answer/dismiss a question batch |
| POST /sessions/ID/cancel | Cancel a round |
| POST /sessions/ID/commands | Submit a slash command |
| GET /triggers | List definitions |
| POST /triggers | Create a definition |
| DELETE /triggers/ID | Disable/delete a definition |
| GET /triggers/ID/occurrences | List occurrence state |

Session query parameters are kind, status, attention, q, trigger, since and
until, plus an after cursor for paging. Index queries do not load transcript
streams. Decimal sequence and
revision values are sent as text where the contract requires them.

Input errors preserve structured diagnostics: unknown command, busy session,
submission/revision conflict, unknown session or invalid answer. They do not
become model requests.

## Commands and submission recovery

A registered initial /name is a command; its raw argument string is preserved.
Unknown names report a closest match. Initial // escapes a literal slash.
The web command picker uses server-provided usage/documentation.

Run, shell and view commands remain available while a round runs. Their
attachments wait for the next user prompt; they never appear in a running
round's intermediate context. New/list-session commands are CLI-only because
the browser has session navigation.

A pending prompt retains its request id and submission sequence in browser
storage until admission is known. Reconnection checks receipts and retries
that same identity. A newer terminal stream receipt must not be overwritten
by a late admission response. Drafts are stored per session.

A sequence gap, dropped frame or disconnected socket invalidates that stream
and requires a fresh snapshot. Each tab reconnects independently. There is no
periodic HTTP polling while streams remain connected; status checks are used
for disconnection and cookie-expiry recovery.

Stop/restart may return confirmation_required when other sessions are running.
The dialog names those sessions and offers confirmation or keeping them
running. A stopped browser cannot start the process; it directs the operator
to a terminal. A supervised restart keeps reconnection enabled, retains the
cookie, changes the process epoch and delivers a restarted notice.

## Implementation and specs

client/main.gene handles navigation, drafts, commands, answers, sockets and
record caches. client/state.gene contains merge/grouping helpers.
client/view.gene renders turns and values; highlight and markdown helpers
provide safe display. The server assembles static HTML and the compiled
web-profile assets.

web/session_service.gene connects the UI to the shared SessionManager and
RoundController. web/push.gene routes ordered frames and viewer lifetimes.
The same runtime runs CLI and browser rounds; there is no per-session plugin
activation or browser-only model loop.

The package's `gene test` specs cover protocol-4 service delivery, live
records before completion, console routing, custom question validation,
metadata revisions/attention, command execution, restart authentication,
concurrent sessions and shutdown. Responsiveness specs run CPU loops,
native callback loops and synchronous processes while another session,
a heartbeat and HTTP work continue.
