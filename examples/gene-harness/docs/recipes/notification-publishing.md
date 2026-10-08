# Publishing notifications from plugins

Keep notification policy in the plugin's own usage chapter. Register concise
function descriptions, tags and chapter references; do not add a manual to the
initial prompt. A plugin publishes through its captured `PluginHost`:

```gene
(host .PluginHost:notify
  {^key "edition-review" ^scope "workspace" ^severity "success"
   ^title "Edition review finished" ^summary "Two stories still need copy review."
   ^origin {^entity "edition-42" ^revision "8"}
   ^detail `(section (p "See the saved review before publishing."))
   ^actions [{^id "review" ^label "Draft a review"
              ^prompt "Review edition-42 at revision 8; explain blockers."}]})
host/.PluginHost:notifications
(host .PluginHost:notification_update "n-..." {^summary "One blocker remains."})
(host .PluginHost:notification_clear "n-..." 2)
```

The host stamps source, identity, timestamps and the current session origin.
Publishers can update/clear only their own messages. Keys are local to a source.
Use a nonempty key for updates; an unkeyed post is a new occurrence. Titles are
limited to 256 UTF-8 bytes, summaries to 4096, keys to 128, and actions to eight.
Severity is info, success, warning or error. Scope is workspace or session;
session scope requires an originating session.
The complete publication, including detail and actions, is bounded to 32 KiB.

A changed title, summary, severity, origin, scope or action is a meaningful
publication. `^^renew` explicitly publishes a repeated occurrence. Detail-only
changes do not renew the unread count or resurface a cleared message. The inbox
retains up to 256 messages, with a default expiry of 30 days. `expires_at` accepts
future epoch milliseconds. Pending questions and client recovery records are
outside these retention rules.
Updating detail also preserves the original origin and frozen action handles.
Supply a new actions list explicitly to publish reviewed replacement actions.

Use `{^key "review-progress" ^^progress ^summary "Checking saved stories"}` for
transient progress when no existing job/receipt already exposes it. The host
coalesces updates within 100 ms, delivers them live, and writes no checkpoint.
Reconnecting does not replay progress or local success notices.

Actions run only on an explicit operator click:

- `^reference {^session "s-..." ^round "round-..."}` opens original work. Optional
  command, artifact and entity fields identify evidence. A component and scalar
  view_state patch can open a specific validated panel view.
  Round/command references show their original receipts in the center; artifact
  references use workspace-relative file paths and the bounded `/view` reader.
- `^prompt "..."` drafts text with the notification id, revision, source and origin;
  the operator decides whether to send it.
- `^function "registered_name" ^args [...] ^named {...}` admits an ordinary
  budgeted command with a receipt and cancellation.
- `^command "/run (+ 1 2)"` uses registered operator command semantics.

Function, command, component and publisher identities are frozen at publication.
Replacement, disable or process restart can make an old action stale; re-publish
after reviewing the original work. Retained command requests remain recoverable
by their original identity even after retirement. Never retry an unknown mutation
with a fresh identity.

Details use bounded quoted UI, including text, lists, tables, links and progress.
They are read-only: no forms, scripts, callbacks or action buttons inside detail.
Declare buttons in actions. `/ui/default` keeps host summaries and recovery while
suppressing plugin detail. Render callbacks cannot publish or change messages.

After a successful business mutation, inspect the publication result separately:
return the successful save receipt with any notification failure as a warning.
Do not turn an already committed save into a reported save failure.
