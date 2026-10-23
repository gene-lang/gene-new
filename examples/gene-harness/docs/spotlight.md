# Spotlight

The default `spotlight` plugin adds **Search ⌘K** to the host bar. Cmd+K opens a
compact autocomplete dialog from the conversation or a plugin view. Type to
find workspace conversations, views, Help, Change theme, New conversation, or
Needs attention. Ordinary queries never submit prompts or evaluate code.

| Key | Behavior |
| --- | --- |
| Up / Down | Move the highlighted result without changing the query. |
| Enter | Activate the highlighted result while the input has focus. |
| Cmd+Alt+1–9 | Activate the original first nine displayed results directly. |
| Escape | Return from theme choices to search; otherwise dismiss. |
| Tab / Shift+Tab | Move among the dialog's controls. |

Numbers stay attached to the ranked positions when scrolling. A query change
starts a new search; old responses cannot replace its results. Displayed order
is frozen until editing or Refresh. A replaced command/view stays in its
position with an unavailable reason. Held arrows navigate; repeated activation
keys and composing input do not dispatch actions.

Change theme opens Light/Dark choices in the same dialog. The target conversation
and displayed command revision are retained through that step. With no selected
conversation, explicitly submitting a command creates a tools conversation.
Opening or dismissing Spotlight does not create one. Composer text and
attachment drafts are preserved. There is one unresolved launcher activation
at a time.

The modal suspends background interaction and host view shortcuts. Escape,
Tab, and focus belong to the current surface. Spotlight does not stack above
notifications or a command confirmation. A newly arriving confirmation closes
Spotlight and receives focus. Disabling/replacing the plugin removes its UI,
invalidates requests, and restores normal navigation. Recovery UI omits it.

## Search scope

`GET /api/v8/search/sessions?q=...&limit=50` searches indexed workspace metadata
independently of sidebar filters and the sidebar's 100-row list. Interactive,
automated, and child sessions are included. Conversation matching uses
exact/prefix/word and bounded typo matches in titles, then substring matches in
first-request prefixes. Local entries also match aliases. Results
include IDs, kind/parent, bounded snippets, rank/activity, and an index revision.
No transcripts, attachments, or plugin state are loaded.

Up to nine matching actions, views, and commands retain space in the merged
50-row list. On an empty query they precede recent conversations. Equal-quality
local matches precede conversation activity, so New conversation remains
reachable among conversations with that title. Generic type words such as
"conversation" are not fuzzy aliases attached to every session.

Queries are limited to 256 UTF-8 bytes. Responses contain at most 50 results;
work is bounded by 20,000 records and 150 ms. Titles and first-request text are
searched only within their first 512 and 4096 UTF-8 bytes respectively. This is
the searchable metadata scope; a longer field does not request a retry.
A work limit, changed index during the search,
or failed source produces an explicit incomplete-search notice. A result limit
alone means the best results were selected, not that only 50 sessions were
searched. Refresh starts another query generation.

Cross-workspace search, full transcript/filesystem search, arbitrary plugin
record providers, free-text command forms, and a native global Mac shortcut
remain later features.

## Commands and unknown outcomes

Browser commands use a shared host client independent of Spotlight. Before
posting, it saves the exact session/text, request ID, original sequence, and
expected command identity in per-workspace `sessionStorage`. Lost responses
retain that envelope. **Resolve command** looks up its receipt; reload also
attempts recovery. An unknown/expired receipt is never automatically replayed.
Unreadable recovery data blocks another command until its outcome is inspected.
The host's **Forget unresolved command…** disclosure lets the operator explicitly
acknowledge inspection and forget the saved request, including corrupt data.
This permits new commands; it does not establish that the earlier command did
not run, cancel it, or replay it. An in-flight submission/lookup cannot be
forgotten. A receipt 404 alone never unlocks submission automatically.

Before submission, `GET /api/v8/sessions/<id>/commands` returns only the next
command sequence. It does not load transcript pages or render status components.
Another tab can still win admission first: the host rejects the sequence
conflict, and the browser reports it without silently changing identity or
replaying. A browser refusal before POST is marked as not sent, allowing command
confirmation buttons to be retried. Unknown POST outcomes keep their recovery
policy. Composer text clears only when it equals the admitted command text.

Status command descriptors include name, owner, and an opaque contribution
revision. Spotlight sends that expected identity to command admission. The host
checks duplicates first, then validates new work and selects its handler under
one composition snapshot lease, retained through execution. Replacement cannot
silently redirect the displayed command. A stale selection offers Refresh;
already-admitted receipts remain recoverable after replacement/disable.

Session creation has no request receipt contract. An unknown creation outcome
is reported for inspection; all browser creation paths share this guard. After
inspection, **Unresolved conversation creation → I checked; allow new
conversations** explicitly acknowledges it. Ordinary session-list or snapshot
updates do not silently settle an unknown creation. Nothing is automatically
created or replayed by acknowledgement.

## Compiled Gene browser contributions

`browser_clients` is a unique, ordered registry. A contribution contains a
stable `name`, optional `title` and prepared `style`, and an `asset` produced by
`$web/load`. It cannot supply an arbitrary JavaScript URL. Compilation validates
the Gene import graph and disallows external `js/fn` imports. The host publishes
the entry and dependencies with content-addressed names and sends a descriptor
containing owner, contribution revision, module URL, and optional stylesheet URL.

Prepare the module with `$web/load` and the optional stylesheet node with
`$web/stylesheet` during descriptor construction, before composition staging
captures application state. Reuse those prepared assets during activation;
the registry validates their published identities without compiling inside
activation. The
bundled implementation in [spotlight.gene](../src/builtin/spotlight.gene) is an
example; a client entry must declare `main [root : EventTarget] : Void`.
Preparation errors are retained and raised during activation, so the optional
plugin is quarantined while the host starts. `$web/load` source and compilation
failures are catchable Gene errors.

The host mounts a fresh root and toolbar outlet for each enabled contribution
revision, then loads the module with `$browser/load_module` and calls `main`.
The entry receives its bridge in `root/harness_bridge` and a mount identity in
`root/harness_owner`. It must publish `root/harness_controller` containing:

| Callback | Contract |
| --- | --- |
| `update [status : Any] : Void` | Receive current status without restarting the controller. |
| `key [event : Any] : Bool` | Handle a global key through the host dispatcher; true means handled. |
| `dispose [] : Void` | Invalidate local requests and release owned resources. |

Publish cleanup before attaching UI or other resources that can fail. Use the
mount root and provided toolbar outlet for DOM ownership. The host removes
both even when initialization/cleanup fails. Global keyboard handling belongs
in `key`; listeners on owned DOM disappear with that DOM. Other resources a
client acquires must have explicit cleanup. This is a lifecycle contract for
trusted plugin code, not isolation from arbitrary browser side effects.

The bridge supplies:

| Field | Contract |
| --- | --- |
| `toolbar` | This contribution's host-owned toolbar outlet. |
| `state [] : Any` | Current session/title, command descriptors, view descriptors, readiness and pending command. |
| `api [method path payload done]` | Authenticated API; `done [status : Int result : Any]`. |
| `navigate [result done]` | Conversation/view/common-action routing with explicit success/refusal. |
| `command [session text expected done]` | Shared persistent command dispatch; uses the supplied target/identity. |
| `claim [owner panel close fallback] : Bool` | Acquire modal focus/keyboard ownership, or focus an existing overlay. |
| `release [owner restore]` | Release this owner's modal and optionally restore focus. |

Mount/unmount invalidates old loading callbacks. Replacement revokes the old
revision before mounting its successor. A failed revision does not repeatedly
retry on status updates; replacement or disable/re-enable permits a new mount.
Its resources are disposed once; the retained failed marker has no controller.
Normal host navigation remains available. Shared pending command recovery
survives contribution teardown. No public search-provider framework is needed.
Action refusals and unknown-outcome messages remain visible through status and
availability updates. Results rebuild only when displayed availability changes,
or when a query/step publishes a new result snapshot.

## Verification

- `tests/unit/client/launcher_spec.gene`: matching, deterministic ranking,
  bounded merging, and selection edges.
- `tests/unit/runtime/launcher_search_spec.gene`: more than 100 sessions,
  typo/first-request matches, automated/child metadata, and bounded results.
- `tests/integration/runtime/command_identity_spec.gene`: stale admission,
  request equivalence, recovery after replacement/disable, and handler execution
  across publication under the original lease.
- `tests/integration/web/browser_clients_spec.gene`: published assets,
  descriptor validation, disable/re-enable, and recovery exclusion.
- `tests/integration/web/spotlight_client_spec.gene`: actual compiled Gene
  controllers against external browser-edge fixtures, covering delayed
  responses, numbered scrolling, activation latch, captured targets, persistent
  recovery, lifecycle cleanup, and failed mounts. The JavaScript fixture supplies
  the external DOM/module host; application behavior remains Gene.
- `tests/test_web_modules.nim` and `tools/check_host_bindings.mjs`: browser
  primitive lowering/runtime and DOM interface compatibility.
