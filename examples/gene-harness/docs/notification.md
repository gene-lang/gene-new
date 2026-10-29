# Gene Harness notifications

Notifications help the operator notice work, inspect evidence and take an
explicit next step. The host-owned center is available independently of the
experimental workspace UI.

For model-facing usage, see the [overview](recipes/notifications.md),
[publishing recipe](recipes/notification-publishing.md) and
[review notifier example](../examples/notifications/README.md).
The [verification record](verification/notification-verification.md) contains
dated implementation evidence and browser checks.

## Sources and ownership

| Source | Authority | Lifetime |
| --- | --- | --- |
| Local feedback | Browser interaction, such as Copy | Keyed transient notice |
| Workflow projection | Original question, receipt, pending submission or session attention | Relevant while its owning workflow says so |
| Producer message | Source-owned publication in the dedicated inbox | Retained message with revision-checked acknowledgment and clearing |

Questions, attention and unknown saves are projections of their existing
owners. They do not acquire a second stored notification state. Producer
messages summarize milestones and reference their evidence; posting text that
sounds like a question does not create an answerable workflow.

Origin is captured at admission: session, round, command, component and entity
where relevant. A delayed result retains that origin through tab switches and
awaits. It never adopts the conversation currently selected when it arrives.

An uncertain mutation requires both the browser's original pending identity
and the server receipt path. A missing receipt does not establish failure or
permit replay under a fresh identity. Resolve and retry preserve the original
submission, payload and instance.

## Local feedback and decisions

Notice keys combine source, scope and logical condition. Progress and repeated
reconnect attempts update one item. Independent failures retain separate keys;
success in one action cannot remove another action's error.

Successful workspace UI actions are quiet: the updated view confirms success,
and the progress notice is removed. Pending indicators appear immediately;
an action still pending after 500 ms shows one keyed Working notice. A late
timer cannot revive completed work or replace an uncertain-outcome warning.

Ordinary feedback may expire. Errors, unknown outcomes and decisions retain
their recovery controls. Confirmations have a separate controller until the
operator makes a choice, so unrelated notices cannot replace their buttons.
Inline notices and the center share presentation and dismissal state.

## Center, attention and questions

Opening or closing the center preserves the selected conversation, composer
draft, panel selection and question drafts. Expanding details changes the
view, rather than completing work. Needs attention derives from current
workflow state; New messages derives from producer publications beyond the
opened watermark. Projected questions do not create another unread count.

Background questions can be answered in place. Editors and pending replies are
keyed by `(session_id, batch_id)`. The selected conversation and center share
the same editor state for a batch. Two batches keep independent drafts and
uncertain submissions, including across reload and reconnect.

The center fetches missing question content from the original session on
demand. It does not fetch every transcript when opened. A session-list event
invalidates cached background question data even when the metadata status did
not change. Expanded cards refresh; collapsed cards can wait until used.
Fetch generations and process epochs prevent an older response from restoring
a handled question. Invalidation preserves drafts and uncertain replies until
their original workflow confirms the result.

Pending question cards have no generic Clear, X or timeout action. The
workflow's Answer, Skip, Dismiss all or Cancel determines their lifetime.
Dismiss all records unanswered responses; closing the drawer does not.
Batch identity, validation and idempotency reject stale or conflicting answers.
Unavailable details retain an Open conversation recovery path.

## Producer publications

The inbox is a separate checkpointed store under `.gene-harness/notifications`.
Publishers do not write notifications into ordinary plugin state or the model
transcript. Publication, progress, acknowledgment and clearing have their own
revision path and do not invalidate unrelated workspace views.

The host stamps identity and source. A producer supplies declarative content:

| Fields | Meaning |
| --- | --- |
| `key` | Optional source-local key for updating one logical publication |
| `scope`, `origin` | Workspace/session scope and original evidence references |
| `severity`, `title`, `summary` | Compact operator-facing content |
| `detail`, `actions` | Optional frozen read-only detail and declared actions |
| `expires_at`, `renew` | Optional expiry and explicit renewal of a keyed publication |

Stored records also contain `id`, `revision`, `sequence`, host timestamps and
`cleared_revision`. They have no producer-owned `kind`, `dismissible`,
`response` or workflow `state`. A session-scoped message requires an originating
session. Sources may use the same local key independently.

Details use the bounded quoted component vocabulary. Scripts, editable forms,
hidden callbacks and dynamic render functions are refused. A publication must
fit in 32 KiB and may declare at most eight actions. Plain summaries and host
controls remain usable when custom rich content is omitted by the recovery UI.

Frequent progress is transient. Persist meaningful milestones or the job's
necessary checkpoints, rather than a notification on every percentage tick.
Headless producers can publish without a browser; a later operator hydrates
the retained inbox.

## Acknowledgment and clearing

The single operator has one opened-through sequence. Opening the center
acknowledges through the observed snapshot watermark, including offscreen
messages. New meaningful publications beyond it remain new until acknowledged.
Progress ticks and cosmetic detail changes do not renew the count.

Clear removes only the observed message revision. A meaningful later
publication can resurface; an old snapshot cannot restore the cleared revision.
Clear messages clears local feedback and observed producer revisions. It never
answers a question, cancels a task or discards an uncertain receipt identity.
Opening the originating conversation uses its existing attention acknowledgment.

## Actions

Every producer action declares exactly one behavior:

| Behavior | Effect |
| --- | --- |
| `reference` | Open a conversation, receipt, artifact or workspace-view entity |
| `prompt` | Draft contextual text; the operator chooses whether to send it |
| `function` | Invoke a registered function with declared arguments and a command receipt |
| `command` | Submit an operator command through normal admission |

Actions require an explicit click. Arrival never changes panel selection.
A reference may apply a validated scalar view-state patch on navigation.
Function, command, component and publisher revision identities are frozen at
publication. Replacement or retirement refuses stale actions rather than
silently rebinding a button to new code. Original references remain useful as
evidence after the publisher retires.

Execution uses normal sequences, request digests, receipts and cancellation.
Unknown outcomes resolve the same request. Clearing a message neither confirms
nor cancels its work. Publishing failure after a successful business save is
reported separately and cannot change that save's receipt into failure.

## Plugin and model APIs

`PluginHost` exposes source-owned publishing:

| Message | Result |
| --- | --- |
| `notify [message]` | Publication result; inspect `ok` |
| `notifications []` | This source's messages |
| `notification_update [id changes]` | Update this source's keyed message |
| `notification_clear [id revision]` | Clear this source's observed revision |

The separate `NotificationHost` at `notifications/host` supports operator-owned
writes and whole-inbox reads. Its messages are `post [message]`,
`update [id changes]`, `list []`, `detail [id]` and `clear [id revision]`.
Plugins receive opaque handles and immutable replies, without the store or
runtime. The `notifications` built-in contributes `notification_post`,
`notification_update`, `notification_list`, `notification_detail` and
`notification_clear` using that contract. It can be replaced by a stored plugin.

```gene
(notification_post
  {^key "edition-review" ^scope "workspace" ^severity "warning"
   ^title "Two stories need copy review"
   ^summary "Review is complete; two saved stories still have blockers."
   ^actions [{^id "review" ^label "Draft an edition review"
              ^prompt "Review the saved stories and explain their blockers."}]})
```

Discovery provides concise API metadata and focused recipes. Notification
manuals do not enter initial prompts, and notification events never enter model
history automatically. Render callbacks remain read-only.

## Browser and CLI delivery

Web protocol 8 carries workspace notification snapshots and progress through
the ordinary authenticated connection. Browser clients merge by identity,
revision and epoch. Reconnect hydrates producer messages and workflow
projections from their separate authoritative snapshots; it does not replay
old transient toasts.

The CLI uses the same inbox service:

```text
gene-harness notifications list
gene-harness notifications show ID
gene-harness notifications clear ID --revision N
gene-harness notifications clear --all
gene-harness notifications ack
gene-harness notifications watch
```

The presenter emits concise identity/source/severity summaries. Publishers do
not print as a side effect of posting. CLI question answering remains on its
existing question path. OS push, sound, email, per-user routing and dynamic
per-message rendering are outside this contract.
