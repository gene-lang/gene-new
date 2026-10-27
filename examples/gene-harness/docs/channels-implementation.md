# Channel implementation and verification

Status: local and live qualification passed, 2026-10-27. Objective: implement [channels.md](channels.md), including
both milestones and live Slack qualification using the operator-provided
credential file. Credential values are never stored in this record or source.

## Current evidence

- Base revision: `6f1f0849`.
- `genex/websocket` already provided a native libcurl adapter. The proposal's
  earlier claim that no native client existed was incorrect. It now supports
  cooperative connection setup, text sends, limits, flush status and strict
  upgrade validation, preserving its synchronous/binary APIs.
- The Harness already has durable sessions, idempotent round receipts, a
  shared session admission gate and operator continuation policy.
- The manager authenticates to workspace hosts using `cli/client` owner
  exchange, cookie and CSRF credentials.
- The supplied credentials identify a human operator and bot in the same Slack
  team. The bot is a member of the configured channel. The app token's Socket
  Mode hello matches the bot's application, with one active connection. The
  initial read-only probe posted no messages and acknowledged no application
  events. A subsequent explicitly approved conversation test passed native
  intake, Gene execution and threaded bot delivery.

## Completion requirements

Each row remains incomplete until its implementation and verification evidence
are recorded. Passing a transport check does not establish channel completion.

| Requirement | Evidence required | Status |
| --- | --- | --- |
| Native WebSocket client | Independent peers verify text/binary frames, TLS verification, upgrade refusal, limits, fragmentation, ping/pong, close, cancellation and cleanup | Passed; commands below |
| Slack connection owner | Socket Mode hello/events/ack, reconnect/refresh, one owner per app and resource retirement | Live hello, setup and human event passed; durable-ack ordering, multi-team app ownership, refresh and retirement tested |
| Account and workspace configuration | Optional account/channel binding, operator pairing, credentials through host references, manager/local tooling | Production account/route setup passed with supplied credentials; CLI/HTTP path tested with fake account references |
| Authorization | One revisioned owner policy; per-binding identity checks, revocation, fail-closed authority loss, authenticated handoffs and route validation | Domain, authenticated two-host handoffs, revocation and crash checks passed |
| Session mapping | Root included, one durable session per thread, multiple roots isolated, follow-ups, restart and deletion tombstones | Domain/service tests, separate model histories, browser follow-ups and process recovery passed |
| Operator round policy | Channel input validation/provenance, operator budgets and continuation, staged browser attachments/cards preserved | Seven admission tests and existing voice/continuation regressions passed |
| Queue batching | Ordered per-author parts, amendment coalescing, oversize holds, request identity, browser/drain races and admission recovery | Both forced admission orderings, late arrivals, complete oversize holds and saved-admission recovery passed |
| Queue holds | Durable reasons/revisions survive unrelated browser completion and restart; explicit resume and stale-control rejection | Domain/process tests, revisioned review/discard, paused replacement, superseded automatic tasks and newer-Stop preservation passed |
| Questions and controls | Answers, Stop, task continuation, automatic continuation, queue resume and status use existing round semantics | Text controls, browser/shared answers, per-author provenance and continuation/control process recovery passed |
| Slack rendering | Markdown/mrkdwn, escaping, bounded ordered splits, media-ID transcript fallback and reachable/unreachable URLs | Two rendering tests passed; live mrkdwn reply preserved bullets, code and escaped literal notification syntax |
| Outgoing delivery | Workspace intent/owner result handoff, stable IDs, partial delivery, uncertain sends, recovery without model replay | Domain and both-host crash matrices passed; persistent per-app/team backoffs tested; live progress update and final reply delivered |
| Browser continuity | Source/author metadata with User/Agent roles, sharing disclosure, browser messages/replies published to bound thread | Chrome verification passed for notice placement, shared messages/answers, two-author batches, restart and reload |
| Plugin lifecycle | Slack behavior is a plugin; owned background tasks/resources retire and restart correctly | Active plugin withdrawal/replacement, refresh and resource retirement passed; queue holds survived withdrawal |
| Live qualification | Credential identities verified; real Socket Mode connection and usable configured workspace flow verified | Passed: approved human mention, native intake, one Gene execution, confirmed threaded reply and clean retirement |

DM routing, arbitrary existing-thread imports and file uploads remain later
flows as specified in the proposal.

## Verification log

- `gene run src/genex/websocket/tools/build.gene`: passed, including automatic
  selection of a compatible installed macOS SDK. No Python build driver needed.
- `node src/genex/websocket/tests/echo.mjs`: passed existing binary, masking,
  fragmentation/PONG and subprotocol checks against an independent peer.
- `node src/genex/websocket/tests/qualification.mjs`: passed text/UTF-8/empty
  frames, backpressured 2 MiB sends, limits, invalid upgrades/accept/redirects,
  timeouts, peer close, TLS CA/hostname validation and cancellation/cleanup.
- `python3 tests/test_genex_package.py GenexPackageTests.test_generated_websocket_binding_survives_offline_install`:
  passed (41.8 seconds), retaining installed/offline generated-FFI compatibility.
- `gene run examples/gene-harness/tests/integration/channels/slack_api_spec.gene`:
  3 passed, covering credential parsing/redaction, separate bot/operator identity
  calls, correct GET parameters, rate limits and uncertain delivery failures.
- `gene run examples/gene-harness/probes/slack.gene CREDENTIAL_FILE NATIVE_LIBRARY`:
  passed against the supplied credentials. Output consists only of qualification
  booleans and the active connection count; the brief connection was closed.
- `gene run examples/gene-harness/probes/slack_setup.gene CREDENTIAL_FILE NATIVE_LIBRARY ISOLATED_DIRECTORY`:
  passed using the supplied credentials. The production setup code verified and
  locally registered the account, operator and route, bound the isolated
  workspace, retained only credential references, and closed the native socket.
  This probe does not start a transport plugin or a live Harness host, post
  messages, or acknowledge application events.
- `channels/authority_spec.gene`: 3 passed; `channels/queue_spec.gene`: 8 passed;
  `channels/admission_spec.gene`: 7 passed. These cover policy revocation,
  per-author inputs, batch recovery, durable holds, oversize refusal, Gene
  execution, browser attachment separation, continuations and tombstones.
- `channels/handoff_spec.gene`: 6 passed after body-digest metadata
  strengthening. Covers lost acknowledgments, partial/unknown
  sends, progress revisions, rate limits and read-only remote reconciliation.
- `channels/render_spec.gene`: 2 passed; both rendering surfaces, literal
  controls, historical media URLs, Unicode splitting and balanced fences.
- `channels/service_spec.gene`: 9 passed including paused replacement and answer provenance;
  root sessions, shared authors, duplicate subscriptions, browser publication,
  Stop/revisioned resume, stale controls and questions.
- `channels/transport_spec.gene`: 6 passed; wrong-app/competing-receiver
  refusal, durable-before-ack intake, multi-team app ownership, refresh reconnect,
  active plugin replacement/withdrawal, socket/client cleanup and persisted
  read/write cooldowns across channels and newer progress revisions.
- `channels/recovery_spec.gene`: 8 passed across 22 deliberate process
  termination scenarios. Covers intake/binding/admission checkpoints, effects,
  partial/unknown posts, answer and continuation resumption, replacement,
  interrupted holds and a crash between core supersession and queue observation.
- `channels/recovery_http_spec.gene`: passed all 11 scenarios terminating only
  the owner or workspace at an input/output handoff boundary while the other
  real HTTP host remained alive. Model calls and remote posts were not replayed.
- `channels/http_spec.gene`: 1 passed against two real loopback hosts;
  authenticated policy/input handoffs, missing-cookie/CSRF refusal, mismatched
  routes, revocation, owner credential reset, CLI status and one executed Gene
  round. Fake credential references prevent Slack traffic in this test.
  The final rerun also passed queue review, explicit discard, preserved holds,
  CLI resumption and renderer settings through the actual HTTP/CLI paths.
- Existing `runtime/voice_spec.gene`: 3 passed; existing
  `runtime/continuation_spec.gene`: 10 passed after core integration.
- Existing `runtime/questions_spec.gene`: 2 passed;
  `runtime/round_controller_spec.gene`: 9 passed;
  `storage/state_spec.gene`: 2 passed.
- `gene run --snapshot examples/gene-harness/tools/verify_channels.gene`:
  final review-fix run passed 13/13 suites, 75 cases, with exit status 0 on 2026-10-27.
  This includes all qualification, settings and queued-ingress checks. The
  gate uses fake Slack credentials and peers, real loopback HTTP, and isolated
  process termination; it never posts to Slack.
- Chrome: verified the sharing notice before input, User/Agent roles, both
  authors in a coalesced batch, browser follow-up delivery, a browser question
  answer delivered to the fake Slack thread, and history/notice persistence
  across host restart and page reload. Evidence:
  `/private/tmp/harness-channel-browser.jpg`.
- `probes/slack_permissions.gene`: read-only preflight confirmed bot posting
  scope and channel `#team-dobi`; the supplied human user token has no posting
  scope. No token values were printed.
  The connected Slack installation was subsequently checked: its workspace,
  current user and `#team-dobi` channel match the supplied credential route.
  After explicit approval it posted the single human test root used below.
- `channels/qualification_spec.gene`: 4 passed without network access. The
  live qualifier rejects unrelated roots, wrong operators and other threads;
  permits transport controls and bot replies; requires confirmed final delivery
  rather than a temporarily empty outbox; disables only its temporary account;
  and closes the runtime even if saving retirement configuration fails.
- `probes/slack_live.gene`: passed against the supplied credentials on
  2026-10-27, exiting 0. The connected operator posted one approved mention in
  `#team-dobi`. Native Socket Mode admitted it under operator policy with no
  trigger deadline. A deterministic qualification provider was called once;
  its Gene response wrote `slack-live-proof.txt` and produced the final reply.
  Production Slack API delivery updated the progress message and posted the
  final response into that root's thread. A subsequent read confirmed the
  operator root and two bot messages, with bullets and literal `<!here>`
  safely escaped. This isolates transport/runtime qualification from external
  model availability; it is not a model-quality evaluation.
  [Live test thread](https://rtai2025.slack.com/archives/C0ANE5N5N31/p1793104202822949).
  Retained workspace:
  `/private/tmp/gene-slack-live-qualification/slack-live-cc85331f266f`;
  session `s-7360eb24499743ff969b8fad`.
  The probe asserted zero remaining native sockets after closing the service.
  Reopening its configuration confirmed the qualification account and route
  disabled, so reviewing the retained workspace cannot restart the receiver.

All `channels/*_spec.gene` paths above are relative to
`examples/gene-harness/tests/integration/` and run with `gene run`.

## Completion and boundaries

Both milestones are implemented and qualified. The approved live conversation
passed through real Slack intake and delivery; local suites cover the larger
authorization, batching, control and crash matrices. No task-owned live
receiver remains running. The test thread and local transcript are retained.

DMs, existing-thread imports, file uploads, richer Slack surfaces and additional
transports remain the proposal's later flows. The default live check used
mrkdwn; native Markdown blocks are covered by local rendering tests.

Crash checks also caught two lifecycle details: a superseded or failed automatic
continuation must release only its own temporary blocker, and a Stop already
recorded before a crash must not replay cancellation against newer browser
work. Both now have focused regression coverage.

The peer caught that libcurl 8.19 does not itself validate the upgrade accept
hash. The adapter now checks the RFC 6455 nonce/hash, required upgrade headers
and unsolicited protocol/extensions. A cooperative deadline also bounds a peer
that connects but never finishes the HTTP upgrade.

## Review corrections (2026-10-27)

The review of `defdb6a8` exposed gaps beyond the original qualification matrix.

- Channel storage now writes immutable records and bounded index buckets before
  publishing a small checkpoint manifest. Hot mutations detach selected records;
  reads select before copying. Legacy checkpoints migrate on mutation, explicit
  nil values survive, corrupt leaves fail closed, and each record is checked
  against serde limits before publication. Maintenance retains seven days of
  terminal transport evidence and reclaims unreachable blobs across retained
  generations; pending work and uncertain effects do not expire. The standard
  library's filesystem and SQLite stores no longer silently roll back a valid
  committed checkpoint after a decode failure.
- Dirty session sets replace scans of every historical conversation. Projection
  cursors skip unchanged histories, idle sessions and event streams can unload,
  and channel-free browser rounds skip channel persistence. A scratch check with
  both 5 and 40 completed sessions measured 20 idle ticks below the monotonic
  timer's 1 ms resolution, with zero reloaded sessions.
- Known delivery results are queried with backoff instead of resubmitting their
  payloads. A live send remains in progress; a lost result stays uncertain.
  Authenticated `resolve-delivery` and `resolve-batch` commands allow explicit,
  revisioned owner decisions. Composer notices expose unresolved deliveries and
  pruned admission receipts. An absent thread search never triggers a resend.
- Slack entities and URL tokens are normalized before prompt/control parsing.
  Early thread replies wait for their root, and a failed handoff cannot allow a
  later reply to overtake it. Claims recover after a browser uses their reserved
  sequence when a retained receipt proves that ownership.
  Replies to known ignored roots now terminate immediately. Missing-root and
  failed handoffs use persisted per-record backoff with ordering barriers; a
  root can bypass and wake its waiting replies.
- Delivered progress records compact their rendered bodies while preserving
  revisions, digests, destination identity and Slack timestamps on both hosts.
  Workspace pruning also preserves any newer saved intent not yet queued into
  the outbox, closing the progress-checkpoint recovery gap.
- Native PINGs, control-frame receive timestamps, TCP keepalive and a receive
  deadline cover silent connection loss. Inline code survives mrkdwn conversion;
  native Markdown code uses its original characters. The latter is covered by
  renderer checks, without posting to an additional live Slack surface.

`channels/review_spec.gene` adds 17 regression cases covering aggregate storage
limits, preflight rejection, decode refusal, migration/integrity, early replies,
Slack input, admission recovery, idle unloading, explicit effect resolution,
browser status, retention, asymmetric progress compaction, deferred input
ordering and wakeup, liveness and code rendering. The independent native
peer also verifies a masked client PING and PONG activity. Existing round
controller (9 cases) and event storage (2 cases) checks passed again; a separate
SQLite probe confirmed decode-policy refusal without rollback.
The complete 13-suite gate passed after these corrections, including all 22
process-termination scenarios and 11 separate owner/workspace HTTP crash cases.
The independent native WebSocket/TLS qualification and existing binary peer
passed. Crash-fixture cleanup now preserves startup errors and does not await
an already reaped peer a second time.

## Language friction

The standalone probe `(let path "/tmp/a") (path .starts_with? "/")` fails
with `undefined symbol: ~`, while the same call through a receiver named
`value` succeeds. The reader/compiler's internal `path` form conflicts with
this explicit receiver spelling. The credential path helper currently uses
`filename`. Resolving the language ambiguity needs a separate compiler/design
review; the channel implementation changes no Gene syntax.

The same receiver conflict prevented the first HTTP handler, whose argument
was named `path`, from reaching channel routes. Using `endpoint` unblocked the
two-host test.

An unmatched optional regex capture returned the input's first character
instead of nil during control parsing. The parser now takes its argument tail
from the matched command's byte length. Add a focused runtime regression and
investigate unset capture bounds separately; no syntax change is needed.
