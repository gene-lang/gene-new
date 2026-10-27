# Messaging channels

Status: milestones 0 and 1 implemented and qualified, 2026-10-27. Slack provides
another way to use a Harness workspace's durable conversations. See the
[implementation and verification record](channels-implementation.md).

The recommended default is **one Slack channel per Gene workspace, with one
Slack thread per Harness session**. A top-level request starts a conversation;
replies in that thread continue it.

Hermes documents thread-keyed Slack sessions. OpenClaw supports isolated thread
sessions alongside channel-level routing and configurable reply placement.
Harness can begin with a consistent thread rule and expand after that workflow
works reliably. See [Hermes session behavior](https://hermes-agent.nousresearch.com/docs/reference/faq)
and [OpenClaw Slack sessions](https://docs.openclaw.ai/channels/slack/threads-and-sessions).

## Accounts, workspaces and conversations

Distinguish a Slack connection from a conversation and from a Gene workspace.
Here, an account means an installed Slack app/bot connection in a Slack team.

| Slack concept | Harness mapping |
| --- | --- |
| Installed app/bot in a Slack team | Account/connection |
| Configured channel, such as `#gene-calculator` | Gene workspace |
| Thread identified by its root message | Session/conversation |
| Human follow-up in that thread | Another request/round in the session |

A Gene workspace optionally selects one Slack account and one channel. An
account can serve several Gene workspaces through different channels. Separate
bots remain an option for distinct names, permissions or ownership.

For example:

```text
Slack account: work
  #gene-calculator → Gene workspace: calculator
    “Build a calculator” thread → session A
    “Investigate startup” thread → session B
  #gene-website → Gene workspace: website
    “Update the landing page” thread → session C
```

Each configured account/team/channel route selects one Gene workspace. The
transport uses IDs for routing; display names can change. Future transports
can have their own optional account bindings on the same workspace.

In the browser, Slack messages show `Slack · Name(USER_ID) · message_timestamp`.
Names are resolved separately from transcript loading with Slack's
[`users.info`](https://docs.slack.dev/reference/methods/users.info/) API, so saved
messages also gain names without rewriting history. The full name is preferred,
then the display name or username. Lookups use the connection owner's bot token
with `users:read`, cache results for an hour, and fall back to the user ID when
unavailable. Authorization always uses the original IDs.

The browser's sharing notice shows `Shared with Slack channel #name (CHANNEL_ID)`.
Channel names use the same bounded lookup cache, with
[`conversations.info`](https://docs.slack.dev/reference/methods/conversations.info/)
through the connection owner. If the name is unavailable, the notice keeps the
channel ID visible. User-profile lookup failures do not block channel-name lookup.

Slack session titles open the thread at its newest known conversation message
in a new tab. The destination is resolved when the title is clicked, so an open
browser does not keep a stale target as the conversation continues. Received
messages and confirmed permanent replies update a durable `last_message` on
the binding. Temporary progress messages and unsent parts are excluded. Older
bindings can use retained message and delivery records; the parent is the fallback.
The connection owner resolves and caches the target permalink using
[`chat.getPermalink`](https://docs.slack.dev/reference/methods/chat.getPermalink/).
The parent timestamp remains the `thread_ts` context. Other sessions keep plain
titles. The redirect requires Harness authentication and reports an unavailable
link if Slack lookup fails.

Threads isolate conversation history. Sessions in the same Gene workspace
still share files, plugins and workspace memory. Concurrent work needs the
same coordination as concurrent browser sessions. Separate workspaces provide
separate project state when that is required.

## Operator trust

Approving a Slack participant grants the ability to ask the agent to execute
Gene code with the Harness host account's file and process access. Harness
currently gives response code the whole standard library; isolation requires
an OS sandbox. See the [implemented trust model](design.md#principles).

The first version uses an explicit allowlist for each workspace binding,
keyed by account, Slack team and Slack user ID. Setup pairs the Harness
operator's Slack identity and initially allows only that identity. Installing
the Slack app or belonging to its channel does not grant execution access.
Additional participants, including guests and Slack Connect users, require
explicit approval by the Harness operator.

The **connection owner** holds the single authoritative allowlist in its
durable configuration store, with a policy revision. The Harness operator
edits it through authenticated manager settings or local owner tooling.
Workspaces query that authority for execution decisions; they do not maintain
independently editable copies. Read-only snapshots can support display, but an
unavailable authority holds queued work instead of authorizing from an old
snapshot. In standalone operation, the connection owner and workspace use the
same store in the same process.

Apply authorization before session creation, request admission, question
answers and controls. Unapproved messages in a bound thread are ignored and
excluded from automatic model context. Future thread-history imports must
apply the same rule; quoting third-party material as task data requires an
explicit supported workflow.

Authorize using identities from Slack's authenticated payload. Intake checks
and pre-admission checks use the same authority; record the decision and policy
revision with each input disposition or admission. Recheck every queued part
when forming a batch, including input previously allowed at intake. Revocation
blocks subsequent authorization decisions; work whose admission was already
authorized requires an explicit Stop to cancel it.

Disabling mention requirements does not change the allowlist. The browser's
sharing notice must state both where messages are published and that approved
Slack participants can trigger code execution on the host.

## Slack session lifecycle

Browser-only interactive conversations have an **Add to Slack** button to the
left of Rename, and the same action in the conversation's menu, when their
workspace has a configured Slack destination. Once
the Agent finishes its current request, the button creates a channel message
with the session title and copies the user prompts and final Agent replies,
in order, into its thread. Long history is split into bounded replies. Code,
console output and generated follow-up requests stay in Harness; images use
the existing transcript references.

The session retains its ID and browser history. Its title becomes a Slack
thread link, and later browser and Slack messages share the same conversation.
The copy records a history boundary so concurrent browser messages are sent
once, after the copied history. A durable delivery ID makes retries and restarts
reuse the same parent message. Unknown sends require reconciliation rather
than blindly posting again. Deletion waits for pending sharing to finish or
be resolved.

1. **Start.** A top-level `@Agent build a calculator` message in a configured
   channel creates a Harness session and binds the root message to it. Include
   that original request in the session before starting the model. The bot's
   response goes into the root's thread.
2. **Continue.** Subsequent replies in an established thread use the same
   session. They can omit the mention. Preserve the author of every incoming
   message; approved participants share the conversation rather than receiving
   separate sessions within the same thread.
3. **Finish a round.** An Agent final response completes that request. The
   session remains usable. A reply tomorrow continues the same conversation.
4. **Start fresh.** A new top-level request creates a new session. An idle
   timeout may unload a session from memory while its durable identity and
   history remain available.
5. **Receive while busy.** Queue follow-ups in durable arrival order. After
   normal completion, coalesce the eligible waiting messages into one request
   only when the queue is enabled. Waiting for an answer temporarily blocks
   draining; a manual turn-limit pause or Stop creates a durable operator hold.
6. **Restart.** Restore bindings, pending inputs and delivery state. Reconcile
   admitted requests before deciding which queued inputs still need submission.

Mention gating is a channel setting. Shared channels require a mention to
start a conversation by default. A dedicated workspace channel can opt into
accepting every eligible top-level human message. Once a thread is active,
approved participants can continue it without another mention.

Persist the external binding separately from the internal session ID:

```text
(account_id, slack_team_id, channel_id, root_message_ts) → session_id
```

Use the root message's `ts` when starting a thread and a reply's `thread_ts`
when continuing it. Keep Slack timestamp identifiers as strings. Slack's
posting API expects the parent timestamp when sending thread replies.
See [chat.postMessage](https://docs.slack.dev/reference/methods/chat.postMessage/).

Creation of a binding must be atomic so concurrent or repeated deliveries
cannot create two sessions for the same thread. A deleted session leaves a
binding tombstone: a reply explains that a new thread is needed instead of
silently starting an unrelated conversation under old messages.

Slack-created sessions retain the `interactive` kind. Origin metadata records
the transport, external conversation, message and sender identities.

### Round admission policy

Slack requests are operator-controlled work. They use the operator turn budget
and retain that policy across questions, delegation resumes and continuations,
without acquiring trigger deadlines.

The [`operator_round?`](../src/runtime/round_policy.gene) predicate classifies
ordinary user rounds, validated operator continuations and authenticated
channel admissions. Channel rounds use the distinct initiator
`channel:slack/<account>`. The host assigns and validates this origin.

Keep browser-only behavior separate from operator policy. Slack admission
must leave staged browser command attachments untouched and must not send or
replay browser cards. Derive a new Slack session's title from its root request
at session creation, independently of the browser's fresh-prompt title hook.

Round `input` metadata passes through
[`normalize_round_input`](../src/runtime/input_metadata.gene), preserving voice
validation and validating channel origin, account, team, author, channel,
thread and message identities. This metadata participates in request identity
checks and survives continuation and recovery. Question answers retain their
own input source, including the individual Slack author or Harness operator.

Keep **User** and **Agent** as the primary transcript roles. Slack author and
source details are secondary metadata, also available to the model so multiple
approved participants remain distinguishable. For a batch, retain those
identities separately for every constituent message.

### Queue batching and admission races

At drain time, take a finite snapshot of the eligible pending messages for the
session and combine them into one model request, preserving their order,
authors and external message identities. For example, `also add X`, `and Y`,
then `actually, skip X` should reach the model together instead of starting
three separate rounds that perform superseded work. Later arrivals remain
pending for the next drain. Batching does not interrupt or undo work already
executing.

Recheck authorization for each part against the connection owner's authority.
Rejected parts receive terminal dispositions and are excluded from the request
and its model context. Explicit controls and question answers use their own
admission paths rather than being coalesced with ordinary prompts. If no
eligible parts remain, finish the drain without starting a round.

Persist a batch record containing its ordered queue-entry IDs, per-part
provenance, authorization decisions, rendered request, request identity and
submission sequence. The transcript retains the individual human inputs and
their authors; it must not invent a single Slack message as their source.
Validate the complete request against Harness's admission size limit. An
oversized batch stays held for operator review rather than being truncated or
silently split into rounds that may execute an amendment before its correction.

Choose the batch and claim its admission under the same per-session gate used
by browser submissions and continuation controls. Recheck the durable queue
holds and current work blockers under that gate before claiming. Whichever
eligible admission obtains the gate first and is accepted starts the round:

- If a browser submission wins, the drain leaves its inputs pending and runs
  again when both the session and queue become eligible. Browser completion
  does not clear an existing operator hold.
- If the drain wins, a racing browser submission receives the normal busy
  refusal and keeps its unsent draft for review and retry.

The batch's membership, request identity and content become fixed for an
admission attempt. A definite refusal such as busy leaves the entries pending
and can release the claim. An uncertain result keeps the batch intact until
its existing request identity is resolved. Record the admission receipt before
marking the members consumed. A retry that discovers an already admitted batch
uses that receipt rather than submitting its messages again. Stopping or
failing an admitted round does not automatically requeue consumed inputs.

## Browser and Slack continuity

Slack sessions appear in the Harness browser alongside other conversations,
with their source and shared destination visible. Browser continuations in a
Slack-bound session publish to that same Slack thread, including the human
message and Agent reply. Before accepting input, the browser must clearly mark
the shared destination and explain the Slack participants' host execution access.

Publishing an existing browser conversation into Slack is an explicit sharing
action. Its treatment of prior history needs a separate choice. An Open in
Harness link is useful when the deployment has a URL reachable by the Slack
user; a loopback URL only works on the machine running Harness.

## Replies, questions and controls

Show a compact working status, questions, final responses and failures in
Slack. Update one progress message per active round, with bounded update
frequency. Preserve each round's final response as a normal thread reply with
`Agent:` on its own line above the response. Browser messages mirrored into the
thread use `User (Harness browser):` above the user's text.
When a round finishes, remove its working-status message instead of retaining
an `Agent: done.` message before the final reply. A status that has not reached
Slack is dropped without posting it. Status removal preserves delivery pacing
and can safely resume after a restart.
Honor Slack's server-provided retry intervals across the app/team, including
after restart or a newer progress revision. Pace posts per channel and
reconciliation reads separately; see [Slack rate limits](https://docs.slack.dev/apis/web-api/rate-limits/).
Requested diagnostics can be delivered as text or files; Gene response code
and console output belong in the detailed Harness transcript by default.
The first version uses text and transcript references for content that needs
file delivery.

Questions use Harness's existing answer lifecycle. Buttons or a clearly marked
text-answer prompt identify the pending question. Distinguish answering that
question from queuing a new request. Question and control actions carry the
session, round and revision they address, so an old button cannot affect a
later round.

Persist queue holds independently of the latest round, with their kind,
reason, source round/task or batch, and queue revision. Temporary blockers
cover active work, waiting for answers and automatic-continuation rollover;
remove each only when its own cause ends. Keep the queue blocked across
automatic rollovers until that task finishes or requires an operator decision.

Operator holds cover Stop, failed or interrupted work, a manual turn-limit
pause and an oversized batch. They survive restart and unrelated browser
rounds, including successful ones. Clearing a temporary blocker never clears
an operator hold. Draining requires both an enabled queue and eligible session
state; it cannot be inferred from the latest round's successful completion.
Hold changes and drain claims share the session gate, so transitioning to an
operator hold cannot briefly make the queue eligible between rounds.

Offer distinct controls for the paused task and for queued requests:

| Session state | Queue and control behavior |
| --- | --- |
| Running | Queue follow-ups; Stop targets the active round and adds an operator hold. |
| Waiting for answers | Temporarily block draining; answers use the existing question lifecycle and preserve any operator hold. |
| Manually paused at the turn limit | Add an operator hold; offer Continue current work and Continue until finished. |
| Stopped, failed or interrupted | Preserve the operator hold; recover uncertain work before explicitly resuming queued requests. |
| Normally completed | Clear only the completed work's temporary blockers; coalesce and admit a batch only if no operator hold remains. |

**Continue current work** uses the existing manual continuation operation.
**Continue until finished** uses its automatic continuation mode. These task
controls preserve operator holds on the queue, even after the resumed task
finishes. Automatic continuation keeps its temporary blocker across turn-limit
rollovers; finishing the task releases that blocker only.

**Resume queued requests** explicitly clears operator holds under the session
gate after validating authorization and the queue revision. It does not resume
a cancelled round, clear active-work blockers, or supersede an unresolved
manual pause. Outstanding pause choices and an oversized batch need resolution
before queued work can be admitted. Explicitly choosing to replace a paused
task with the queued batch also authorizes queue resumption, using the same
queue revision check. A newer Stop or hold invalidates stale resume controls.

A queued follow-up must not automatically supersede an unclaimed turn-limit
pause. The operator can explicitly choose to use the queued batch instead of
continuing that task. Perform supersession and continuation claims under the
existing session gate, validating the source round and current revision. Queue
resumption must not implicitly make that choice.

Status and explicit text commands such as `!stop` provide alternatives inside
threads. Give task continuation and queue resumption different command names.
Slack custom slash commands cannot be invoked in message threads; see
[Slack's command restrictions](https://docs.slack.dev/interactivity/implementing-slash-commands/).

Ordinary message text enters Harness as a literal request. The Slack adapter
recognizes only its documented controls before normal request admission.
Configured channels and approved senders determine who can start work or use
controls. Ignore the bot's own output to prevent reply loops.

### Slack rendering

Render replies for the selected Slack surface. Apps using Slack's platform AI
features can use native [Markdown blocks](https://docs.slack.dev/reference/block-kit/blocks/markdown-block/),
which support standard links, headings, tables and code blocks. Other surfaces
need a conversion to Slack's [mrkdwn](https://docs.slack.dev/messaging/formatting-message-text/),
with readable fallbacks for unsupported constructs. Escape literal Slack
control syntax rather than accidentally turning model text into notifications.

Split long responses within the selected message/block limits, preserving
ordering, links and code-fence boundaries. Track every delivered part under
the same logical output so reconnects can reconcile partial delivery. Rich
blocks also need meaningful fallback text.

Embedded Harness media requires explicit handling even while file attachments
are deferred. Recognize `/api/v<N>/media/<id>` references by media ID rather
than forwarding the saved URL. A relative authenticated media URL is not a
Slack-readable image. Native Markdown blocks translate image syntax into
hyperlinks rather than uploading or embedding the bytes.

For the first version, replace these image references with the alt text and a
clear note that the image is available in the Harness transcript. Include a
transcript link when its configured URL is reachable; otherwise identify the
session without presenting a broken media link. Preserve the surrounding
answer text. Later file delivery can upload authorized media through the
connection owner using Slack's [file upload API](https://docs.slack.dev/reference/methods/files.getUploadURLExternal/)
and its `files:write` scope.

## Plugin and runtime boundaries

Implement Slack as a plugin over a small transport-neutral Harness service.

| Component | Responsibility |
| --- | --- |
| Workspace channel service | External identities, thread/session bindings, per-session input queues, batching, admission receipts and outgoing delivery intents |
| Slack plugin | Slack event normalization, mention rules, thread targeting, message formatting and interactive controls |
| Connection owner | Credentials, authoritative sender policy, Socket Mode lifecycle, durable ingress, routing decisions, workspace handoffs and Slack API delivery results |
| Existing session/round runtime | Conversation history, model execution, questions, cancellation and continuation |

Harness already has durable sessions and request receipts. Its current round
admission rejects busy sessions, so external follow-ups use a durable queue.
Browser and channel admissions share the existing session gate and the race
policy above.

Keep account credentials behind host-owned references. Workspace plugins use
the configured connection service. Use Gene for the adapter and lifecycle;
reusable HTTP/WebSocket capabilities exposed by implementation belong in the
Gene ecosystem.

### Connection ownership

Use Socket Mode for the first local installation. It receives events over an
outbound WebSocket connection and avoids requiring a public callback URL.

The manager, or a dedicated gateway, owns connections for the configured Slack
app and routes events by account/team/channel to workspace hosts. Standalone
operation can own the connection when it is the sole receiver for that app.
Connection ownership must be explicit when several workspaces share an account.

Slack may send a payload to any active Socket Mode connection for an app.
Independent workspace processes therefore cannot each open a socket and expect
to receive only their own channel's messages. Multiple connections require
coordinated receivers with shared routing and admission state. See
[Socket Mode connection behavior](https://docs.slack.dev/apis/events-api/using-socket-mode/).

If a workspace host is stopped, the connection owner retains accepted input
and exposes the stopped/queued state. Automatic workspace startup can be an
explicit deployment policy.

### Authenticated host handoff

For the first version, cross-process handoffs use loopback HTTP through the
existing Harness host authentication. The manager already uses
[`cli/client`](../src/cli/client.gene) to discover and authenticate to managed
workspace hosts: exchange the owner secret for a session cookie, then send
mutations with that cookie, its CSRF token and the expected origin. Put channel
handoff routes beneath the same owner-authentication and request checks in
[`web/server`](../src/web/server.gene).

Use this authenticated path for connection-owner-to-workspace input and result
delivery, and for workspace-to-owner policy decisions, outbox handoffs and
delivery lookups. The connection owner can run in the manager's Harness host;
a dedicated gateway must provide the same authenticated contract. Standalone
operation can call the same service directly in-process.

Loopback reachability alone does not authorize a caller to assert a Slack
operator identity. The workspace trusts forwarded identities only on the
authenticated host handoff, validates the configured connection owner and
account/team/channel/workspace route, then obtains an authoritative policy
decision. Host owner credentials carry the existing owner trust level; Slack
credentials remain with the connection owner. Authentication failures refuse
the operation and preserve pending work. A lost mutation response is resolved
by its stable identity or receipt before retrying.

### Incoming record ownership and handoff

The connection owner and workspace have separate durable responsibilities:

1. The **connection owner** authorizes intake and persists an eligible raw
   Slack event, its external delivery identity, destination workspace and
   routing decision. This is the point at which it acknowledges Slack. It then
   retries delivery to that workspace until the workspace acknowledges the
   handoff.
2. The **workspace channel service** checks current authorization through the
   same policy authority and durably records the logical message's disposition
   before acknowledging the authenticated handoff. Accepted input also gets a
   thread binding and queue entry. Repeated delivery returns the recorded result.
   Rejected or ignored input receives a terminal disposition rather than being
   retried forever, and creates neither a session nor queued work.
3. The **workspace channel service** owns queue order, batching and Harness
   admission. It stores per-part provenance and policy decisions, the batch's
   request identity and the eventual admission receipt. It resolves uncertain
   admission using that identity before attempting another start.

Events rejected by the connection owner are acknowledged to Slack without being
forwarded or entering model context. Acknowledging an event does not mean that
workspace work was accepted.

Slack acknowledgment and workspace handoff acknowledgment are different
boundaries. Neither waits for model execution. A crash before the handoff is
acknowledged causes a retry; a crash after it was recorded is handled by the
workspace's duplicate check. The original routing decision survives retries.
See Slack's [Events API guidance](https://docs.slack.dev/apis/events-api/).

Track both delivery identity and logical message identity. Retried events
must not repeat work; subscriptions such as message and app-mention events
may describe the same Slack message under different event IDs. Use the
account/team/channel/message identity to prevent duplicate requests.

Replies to a root already recorded as ignored or denied receive a terminal
disposition immediately. A reply whose root has not arrived waits for up to
five minutes, with persisted backoff between handoff attempts. Deferred records
keep later replies in their thread ordered, while allowing the root through.
Observing that root wakes its waiting replies without waiting for the backoff.

### Outgoing record ownership and handoff

The **workspace** records each logical delivery intent in its outbox: stable
delivery ID, originating session/round, rendered parts, destination thread and
any progress revision. It sends that intent to the connection owner and
retries the handoff using the same ID until acceptance is recorded.

The **connection owner** durably accepts the intent, verifies its route, and
performs `chat.postMessage` and subsequent Slack updates using its credentials.
Repeated IDs with the same content resolve to the existing operation; the same
ID with different content is rejected. The owner records each returned Slack
message ID and delivery outcome before exposing the result to the workspace.
Accepting an intent is distinct from successfully delivering it to Slack.

The **workspace** records or reconciles the owner's durable result by delivery
ID. Losing either handoff acknowledgment causes a lookup or idempotent retry,
not a new model run or a new delivery identity. Progress revisions prevent an
older update from overwriting a later final state.

A timeout after a Slack API request may leave the remote result unknown. Keep
that operation explicitly uncertain and reconcile it before another send.
This handoff design does not promise exactly-once remote posting; recovery
must preserve the distinction between known failure and unknown success.

The owner can explicitly resolve a failed or uncertain part after reviewing
the thread. An empty history scan alone never authorizes another post.
Workspace outboxes poll accepted results with backoff rather than handing the
same payload over repeatedly. Failed and uncertain delivery is visible beside
the browser composer, with its delivery ID.

Message edits and deletions do not automatically rerun or undo admitted work.
An explicit follow-up requests a change to work already started.

## Local setup

The native transport and channel/thread workflow have passed local and live
Slack qualification; see the [verification record](channels-implementation.md).
Setup uses authenticated local owner tooling. The connection owner's host can
be the manager, a gateway, or the workspace itself in standalone operation.

Enable Socket Mode for the Slack app and create an app token with
`connections:write`. The bot needs `chat:write`, `app_mentions:read`,
`channels:read`, `channels:history` and `users:read`; add `groups:read` and
`groups:history` for private channels. Subscribe to `app_mention` and the
appropriate channel message events (`message.channels` / `message.groups`).
Invite the bot into its configured channel. See Slack's
[Socket Mode setup](https://docs.slack.dev/apis/events-api/using-socket-mode/)
and [event subscriptions](https://docs.slack.dev/apis/events-api/).

Keep bot, app and initial operator user tokens in a local credential file;
the file parser accepts the operator-provided `~/.secrets/slack-dobi` format.
Configuration stores file references and verified public identities. Build
the native adapter using the [WebSocket package instructions](../../../src/genex/websocket/README.md).
Create an inert account definition, for example:

```gene
{^secret_file "~/.secrets/slack-dobi"
 ^library "/absolute/path/to/libgene_websocket.dylib"}
```

With the owner host running, register it using
`gene-harness --workspace OWNER channels account dobi --file ACCOUNT_FILE`.
Pairing verifies bot/operator/team identity, channel membership and that the
app token's hello belongs to the same Slack application.

A route file specifies `channel` (its Slack ID), `workspace` (an absolute Gene
workspace directory), optional `approved` user IDs, and optional
`require_mention` / `enabled` booleans. Run
`gene-harness --workspace OWNER channels route dobi --file ROUTE_FILE`.
Only the paired operator is approved by default. Editing an existing route's
`approved` list changes the authoritative policy without re-pairing.

For a different workspace host, start it, create a binding file containing
`{^owner_root "/absolute/owner/directory"}`, then run
`gene-harness --workspace WORKSPACE channels bind ROUTE_ID --file BINDING_FILE`.
A route to the owner's own workspace binds in-process automatically. One app
has one connection owner even when it serves several workspace hosts.

Use `channels status` on either host to inspect its configuration and health;
credential references and values are excluded. `channels queue --session ID`
reports holds and their revision. An owner can explicitly resume using
`channels resume --session ID --revision N`. Slack participants use `!status`,
`!stop [ROUND_ID]`, `!continue [ROUND_ID]`,
`!continue-until-finished [ROUND_ID]`, and `!resume-queue QUEUE_REVISION`.
Questions display the exact `!answer BATCH_ID {JSON}` reply to send. Continuing
the task preserves existing queue holds.
Controls tolerate the trailing “Sent using” attribution added by Slack
integrations, including when Slack flattens it onto the command line. Literal
requests and answer JSON retain their content.

`!resume-queue` never replaces an unresolved paused task. To explicitly choose
the queued requests instead, inspect `!status` and send
`!replace-paused ROUND_ID QUEUE_REVISION`. The durable choice abandons that
manual pause and authorizes queue resumption; it cannot target a later round or
an automatic-continuation rollover.

For an oversized batch, `channels queue --session ID` includes the pending
parts, authors and message IDs. After reviewing them, an owner can discard
selected pending input with `channels discard --session ID --revision N
--file FILE`, using an inert map with `ids` and a nonempty `reason`. This is a
revisioned content decision and preserves the hold. Inspect the new revision
and explicitly resume separately when the remaining batch is ready.

`channels settings --file FILE` on the workspace accepts `surface` (`mrkdwn`
by default, or `markdown` for an eligible Slack AI surface) and optional
`public_url`. Supply a browser URL reachable by the Slack participants, with
no credentials, query or fragment. Without one, image references identify the
Harness session instead of publishing broken media links.

Use `channels delivery ID` on the connection owner to inspect a stuck output.
Then `channels resolve-delivery ID --file FILE` accepts an inert definition:

```gene
{^revision 0 ^review_revision 0 ^part 0 ^decision "retry"
 ^reason "Checked the Slack thread; this part was not posted."}
```

Copy `revision` and `review_revision` from the current delivery (a missing
review revision is zero). Choose `sent` with its actual Slack `ts`, `retry`, or
`failed` to abandon the output. Retry is an explicit owner decision and can
duplicate a message if its earlier success was overlooked. Resolution cannot
replace a request still actively being sent. Other requests in the thread can
proceed after the uncertain output is resolved.

A claimed batch normally recovers automatically, even if a browser request
used its reserved sequence. If that sequence's receipt has been pruned, the
queue stays held. Inspect `channels queue --session ID`, then use
`channels resolve-batch --session ID --revision N --file FILE` with
`{^batch "BATCH_ID" ^decision "discard" ^reason "Reviewed the prior work."}`.
The other choice, `requeue`, explicitly accepts possible replay. This resolves
the claim and preserves the hold; review and resume separately.

Channel storage checkpoints a small manifest over immutable individual records
and hash buckets. Existing channel checkpoints migrate on the next mutation.
Terminal transport records retain seven days of deduplication evidence;
transcript history remains in the event store. Unresolved effects and pending
inputs never expire. Delivered progress slots retain compact revision, digest,
destination and Slack message-ID records after their rendered bodies expire,
so later updates keep editing the same message even if the owner and workspace
run maintenance at different times. Maintenance reclaims records unreachable from all retained
checkpoint generations. Idle sessions are processed only after relevant changes
and can unload normally. Socket Mode sends periodic PINGs and reconnects after
90 seconds without a received frame, including control frames.

## Milestones

### 0. Native outbound WebSocket client

Socket Mode depends on a qualified native outbound `wss://` client. The existing
[genex/websocket](../../../src/genex/websocket/README.md) package supplies a
libcurl-backed client with TLS, fragmentation and polling. Reuse and extend it
for this milestone, including text sends and cancellable connection setup.
The browser's `ws/connect` is a separate API, and the native HTTP client keeps
its documented rejection of protocol upgrades; see the
[standard library](../../../docs/stdlib.md).

The client needs verified TLS, the WebSocket handshake, bounded text/binary
frames and fragmentation, ping/pong, close handling, cancellation and resource
cleanup. Test invalid upgrades, TLS failures, frame limits, peer closure and
cancellation as well as successful exchanges. The Slack connection owner owns
reconnection policy, backoff and obtaining refreshed Socket Mode URLs.

This capability can also support other outbound streaming integrations, such
as cloud speech recognition. Slack-specific event and session policy stays in
the plugin.

### 1. Slack channel and thread workflow

Deliver the channel/thread workflow with:

- An optional Slack account and channel binding per Gene workspace.
- Explicit operator pairing, one authoritative sender policy and host execution disclosure.
- Mention-to-start behavior and natural follow-ups in established threads.
- Durable thread/session mapping, duplicate suppression, batching and persistent queue holds.
- Operator round policy and validated channel input metadata.
- Final replies, visible failures, questions, task continuation and queue controls.
- Slack rendering, bounded response splitting and transcript references for images.
- Browser visibility and clearly marked sharing for Slack-bound conversations.
- Authenticated, acknowledged handoffs and restart recovery for inputs and outgoing delivery.

Verify that separate roots create separate sessions, the root request is
included, multiple participants continue the same thread, a completed round
can be followed up, and retries/restarts preserve queued work without duplicate
model runs. Also verify stale controls, deleted-session bindings, and uncertain
outgoing delivery. Cover crashes on either side of every handoff, duplicate
logical messages arriving under different event IDs, and partially delivered
multi-part replies.

Verify that queued amendments and corrections reach the model in one ordered
batch with individual authors. Cover denied parts, new arrivals during a drain,
an oversized batch held for review, and recovery between batch claim, admission
and consumption. Force both orderings of the browser-versus-drain race and
verify that exactly one round starts, with the losing input preserved.

Stop with pending Slack messages, then complete an unrelated browser round and
verify that the queue remains held until an explicit resume. Repeat after
restart and for failure, interruption, manual-pause and oversized-batch holds.
Answering a question, finishing a continued task, or completing an automatic
rollover must not clear an existing operator hold. Verify that a newer hold
rejects a stale Resume queued requests control.

Verify that unapproved users cannot start work, add context, answer questions
or operate controls; include guest and Slack Connect identities. Check operator
budgets and continuation deadlines, preservation of staged browser attachments,
and rejection of browser card input on Slack admission. A queued follow-up must
stay held at a manual turn-limit pause until the operator explicitly chooses a
path, and must not supersede an automatic continuation during rollover.
Rendering checks include Markdown/mrkdwn output, split code blocks, historical
API-version media references, and installations without a reachable browser URL.

Exercise intake and execution checks against the same policy store. Revoke a
participant while their message is queued and verify that the next admission
decision excludes it; an unavailable policy authority must hold the queue.
Reject unauthenticated handoffs even when they assert an approved Slack author,
as well as missing CSRF credentials and mismatched routes. Repeat handoff
recovery after host credential reset without replaying an already admitted
mutation.

### Later flows

DMs need an explicit workspace default or selector when one bot serves several
Gene workspaces. Joining pre-existing human threads needs bounded history import,
permission handling and duplicate-aware context seeding; Slack provides
[conversations.replies](https://docs.slack.dev/reference/methods/conversations.replies/)
for retrieving thread history. Those flows, attachments, richer Slack surfaces
and additional messaging transports can follow the basic channel/thread workflow.
