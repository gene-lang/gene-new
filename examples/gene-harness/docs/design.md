# Gene Harness design

Harness is a workspace host for code-driven model work. This document describes
its principles, owners and lifetimes. The [protocol](protocol.md) specifies
response grammar, evaluation bindings and durable records. The [README](../README.md)
covers operation; [plugins](plugins.md) defines the contribution contract.

The [memory proposal](proposals/memory.md) is planned work. Dated implementation
evidence belongs under [verification](README.md#implementation-and-verification).

## Principles

- The model acts by writing Gene code. An apply-patch block is its file-edit
  operation. The final value, an `Outcome`, steers the loop.
- Printing goes to the operator's console. Only explicit request items enter
  model context.
- There is no authority code. Plugins and response code receive the standard
  library. Process isolation belongs to an OS sandbox. Opaque plugin receivers
  enforce contracts and lifetimes, rather than a security boundary.
- A workspace is a project directory with exactly one owning host process.
  Its sessions load on demand and may run concurrently.
- First-party features use public contribution points wherever those points
  fit. The Harness owns the loop until a real second driver warrants a
  replaceable one.
- Each mutable subsystem has one owner. Dependencies are supplied at
  construction; consumers read the owner's state rather than mirrored fields.
- Durable receipts establish admission and uncertainty. Recovery reconciles
  recorded work; it never blindly repeats arbitrary plugin effects.
- History stays small and cache-friendly through settlement, recall and
  compaction. Stable older content remains byte-identical between calls.
- The project is greenfield. Retired interfaces and state formats are refused
  or discarded, without compatibility aliases or migration execution paths.

## Terms

| Term | Meaning |
| --- | --- |
| Workspace | Project directory and its `.gene-harness/` state, owned by one host |
| Session | Durable conversation, including transcript, history and metadata |
| Round | One admitted request through completion, suspension or interruption |
| Turn | One model exchange, response evaluation and terminal record |
| Request | Input to a turn: initiating text, prior outputs or answers |
| Response | Raw model text containing Gene forms and optional raw blocks |
| Outcome | The response's value, interpreted by the loop and owned extensions |
| Reply | Operator-facing progress or final text |
| Request item | Labeled output explicitly admitted to the next model input |
| Transcript | Complete durable operator record |
| History | Model-facing messages, after settlement and compaction |
| Recall | Retrieval of a verified content-addressed body behind a stub |
| Composition | Desired plugin entries and the currently published registry revision |
| Lease | A reader's claim on one published composition snapshot |
| Contribution | An activation-owned registry row, seam, hook or subscription |
| Command | An operator action executed without a model call |
| Input mode | Transient session input handling, such as the persistent REPL |
| UI view | A plugin component tree with optional browser-owned view state |
| UI action | Explicit function execution with a durable workspace receipt |

## Ownership layers

| Layer | Owns | Acceptance test |
| --- | --- | --- |
| Recovery kernel | Workspace lock, event store, session index, composition, registries and supervision | Doctor runs without plugin activation, loop construction or feature hosts |
| Loop | Round admission, turn pipeline, protocol records, response grammar, patch order, core Outcome, questions and operator control | Its records are complete whatever contributions are mounted |
| Contributions | Commands, functions, prompts, documentation, providers, components, triggers and turn participants | A built-in can be removed, replaced and restored like a stored plugin |

Service layer and startup mode are separate axes. Normal startup opens kernel,
loop and feature services. Offline doctor opens kernel services with no
execution configuration or plugin activation. Metadata recovery is narrower:
it opens composition metadata without the event store, sessions, configuration
or execution hosts, so corrupt application data cannot strand repair.

`HostServices` is the static composition root. Its dependency table controls
construction, quiescence and reverse-order destruction. Its value index is the
primary place to find runtime services. Borrowed dependencies are references to
an existing owner; closing a nested graph never closes them or clears another
owner's index entries.

The runtime constructs one round controller. Command admission, delegation
and trigger hosts receive their controller dependencies at construction.
Loop lifecycle and resumption live in `runtime/loop_services`; browser observer
lifetimes live in `web/observers`.

`Harness` owns registry dispatch and composition mechanisms. Product services
such as appearance, readiness, inbox state, UI action logs and workspace-manager
state belong to the runtime graph. The kernel's private activation delegate
receives callbacks for durable plugin operations; it does not import the
notification publisher or application-state implementation.

## Workspace and process lifetime

The owning process uses the workspace as its working directory. Selection is
`--workspace DIR`, then nonempty `GENE_HARNESS_WORKSPACE`, then the launch
directory. Relative paths resolve from the launch directory before ownership.

State lives beneath `.gene-harness/`:

| State | Owner |
| --- | --- |
| `lock`, `owner` | Workspace ownership and process identity |
| `config.gene`, `workspace.gene` | Execution settings and workspace metadata |
| `composition/`, `modules/`, `composition/ACTIVE` | Desired composition, source archive and accepted revision |
| `events/`, `sessions/` | Durable workspace/session streams and listing projection |
| `blobs/` | Content-addressed history, recall and receipt bodies |
| `notifications/` | Producer inbox and operator opened watermark |
| `triggers/` | Durable trigger definitions and occurrences |
| `appearance.gene` | Saved light/dark choice, readable during metadata recovery |
| `web_secret`, `web_sessions` | Reusable owner token and generation-bound browser credentials |
| `connection`, `link`, `cli_cookie` | Live endpoint discovery and client connection state |

The lock has a permanent path. A process must hold ownership before mutating
workspace state. Connection metadata is published only when the host is ready.
It includes the canonical workspace, protocol, endpoint and host instance.
The [workspace manager](manager.md) discovers and controls child workspaces
under the same ownership rule.

On normal or doctor startup, catalog validation precedes every repair write,
including validation of cold streams. Receipt-based session repair runs next,
preserving cancellation and recorded question actions. An all-session sweep
then closes interrupted calls, including operator image work outside running
rounds. Durable image reconstruction uses storage operations and does not
construct an image feature host.

Stop closes admission for rounds, commands and triggers before draining work.
Cancellation receipts and the shutdown marker become durable before cleanup.
Services remain alive while dependent tasks and plugin retirements finish.
All cleanup slots are attempted; cleanup uncertainty remains an error.
A five-second watchdog handles uncooperative shutdown.

The launcher treats exit 75 as restart and retains the listening port. Other
statuses end supervision. Owner credentials survive ordinary restarts. A port
fallback changes the origin, so the current connection link restores access;
browser drafts remain scoped to their workspace and origin.

## Sessions, rounds and turns

Session metadata is a durable listing projection. The round receipt is the
authority for admission, cancellation and restart recovery. A stale listing
does not turn a completed receipt into interrupted work or hide a running one.
Sessions unload only when an injected command-owned policy permits it; that
policy includes admitted commands whose task has not yet been installed.

Round admission records request identity, sequence and digest before work can
start. A retained matching retry returns the receipt. Changed content and
expired sequences fail before execution. The controller owns one per-session
frame containing its task, watcher and completion state.

Each turn leases its composition and owns evaluation in a Gene task scope.
Cancellation joins ordinary spawned work before the turn ends and its lease
is released. A detached reference holds no lease. Turn-local helpers reject
use after closure; late printing remains operator output.

Operator rounds pause at their turn budget and retain unsent input. Continue
admits a linked round with a fresh budget. Automatic continuation links further
rounds while retaining cumulative task turns. Trigger and child work retain
their own completion policies; see [triggers](triggers.md) and
[sub-agents](sub-agent.md).

The loop owns core `Outcome` grammar. Voice and delegation own their extension
schemas and participants. A leased constructor translates declared short
spellings to owned keys. Checked suspension is admitted before core
continuation validation, and its owning participant handles it. Feature data
does not add fields to the core type. See [turn participants](turn-participants.md).

One next-request operation owns bounded output, receipt request references,
history admission and the `turn/request` record for ordinary turns, question
resumption and delegation resumption. The [protocol](protocol.md) specifies
their field and ordering rules.

## Composition and plugin lifetimes

Profiles supply built-in defaults. The composition store holds at most one
entry per id: no override selects the default; a disabled default removes it;
an enabled stored entry replaces it; a disabled stored entry leaves it inactive.
Replacing a taken id is explicit. Restore default and historical reversion
are different operations.

The desired revision, accepted revision and readiness observation are distinct.
`ACTIVE` advances after reconciliation accepts the desired set. Pending plugins
may wait for dependencies. Offline repair changes desired state without
claiming runtime readiness. A normal observation checks requested revisions,
quarantine, profile requirements and configured-provider readiness.

Registration preflights an inert descriptor and stores content-addressed source.
Inside a response it queues publication at the turn boundary. A queued result
is not an installation receipt. The next request receives active, pending or
quarantined publication results, and a turn producing new context cannot
prematurely finish with `done`.

Every built-in and stored activation receives the same opaque `PluginHost`
receiver and public callback projections. The profile host flag controls budget
ceilings and mandatory participants. Direct kernel contributions retain kernel
contexts. Public helpers and contracts live in the declared SDK; see
[plugins](plugins.md).

The registry ledger owns contributions and cleanup slots. Cordis owns instance
activation and retirement. Immutable snapshots own selection and reader leases.
The composer's bridge state tracks reconciliation and the last published set.
Cordis's current set can advance before a retirement error is reported, so it
is distinct from the last published registry snapshot.

Replaced instances retire after their final reader releases its lease.
Publication observers subscribe independently and cancel only their own
subscriptions. Retained code may outlive publication; revocable receivers and
service handles enforce the owning activation's lifetime.

Plugin state updates append immediately. There is no turn-wide transaction
that rolls back arbitrary external effects. Features doing external work own
durable intent/result receipts and reconcile uncertainty on recovery.

Documentation is also a contribution. Registered chapters stay with their
owner so removing that plugin removes its docs. Human-facing design and
protocol documents link to these chapters rather than copying their APIs.

## History and durable records

The transcript records operator-visible requests, code, patches, replies,
questions and commands. History contains only model-facing material. Printing
never becomes a model request item implicitly.

Large bodies live in a content-addressed store. The latest request and
assistant response retain full and settled representations; older messages
store their settled content once. Recall resolves verified bodies. Only
compaction rewrites older history, and protected rounds retain their content.

The stable-prefix invariant compares serialized provider message-content bytes.
Older settled messages remain unchanged through the previous assistant
response; its following request is the first content that may settle.
Provider cache-control metadata has its own placement policy.

Body writers hold leases through admission and receipt publication. Collection
stops new writers and runs at an idle opportunity, preserving all reachable
references and event-store fallback generations. Required core records are
validated against the generated catalog; see [protocol](protocol.md#transcript-and-history).

## Browser and operator presentation

The web service owns transport subscriptions, delivery sequences, snapshot
jobs and browser projection caches. It reads sessions, events and execution
state from runtime owners. Slack's server formatting and browser interaction
remain separate responsibilities within the [channel pipeline](channels.md).

The server owns durable domain state, revision identity and receipt admission.
The browser owns drafts, view selection, optimistic submissions and transient
console output. Background tabs keep updating. A page-only console disclosure
cannot be reconstructed from a server snapshot after reload.

Session storage is prefixed by a stable workspace identity supplied by normal
and recovery pages. Missing identity disables persistence. State for one
workspace cannot be reused merely because another workspace later uses its
port in the same tab.

Plugin views render bounded, read-only data under a composition lease. Browser
view state stays distinct from shared settings and domain records. `panel` is
a docked presentation feature with its own defaults, not an alias of `view`.
Actions explicitly invoke declared functions and use durable receipts.

Render errors retain drafts and disable unsafe actions until recovery. The
default/recovery UI omits plugin renders and theme overrides. Appearance is
host-owned, so it remains available when plugins or application data fail.
See [components](web-components.md), [workspace views](workspace-views.md),
[theming](theming.md), [UI recipes](recipes/ui.md) and [browser client](web-client.md).

Notifications have their own inbox and revision stream. Local notices,
questions, producer messages and task attention retain their respective owners.
Publishing a notification does not rerender unrelated views or enter model
history. See [notifications](notification.md).

Wire identifiers and shared bounds belong to `web/contract.gene`. Storage
formats, browser pending-state formats and per-view state versions have
different owners. See [browser wire protocol](web-client.md#wire-protocol-8).

## Development

Source ownership and testing constraints are in [CONTRIBUTING](../CONTRIBUTING.md).
Changes that expose missing language or library capabilities should improve
Gene's reusable tooling rather than silently add application workarounds.
Syntax and larger semantic decisions remain the project owner's decisions.
