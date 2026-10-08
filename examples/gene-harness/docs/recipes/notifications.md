# Notifications

The host Notifications center combines local feedback, pending questions and
session attention with a recent producer inbox. Questions remain owned by their
conversation: Answer and Dismiss all use the existing question workflow. Clear
messages does not handle a question or acknowledge session attention.

Use a producer message for a milestone with useful saved evidence, rather than
copying a question, progress percentage or entire transcript into a second store.
Opening the center acknowledges producer publications through its snapshot's
watermark. Messages arriving afterward remain new until the next open. Clear
applies to an observed revision; a later meaningful occurrence can resurface.

```gene
(notification_post
  {^key "edition-review" ^severity "warning"
   ^title "Two stories need copy review"
   ^summary "The edition review finished; two saved stories have blockers."
   ^actions [{^id "review" ^label "Draft a review"
              ^prompt "Review the saved edition and explain its blockers."}]})
(notification_list)
(notification_detail "n-...")
(notification_clear "n-..." 1)
```

Publishing returns `{^ok true ^id ^revision ^sequence}` or
`{^ok false ^code ^message}`. Inspect `ok`; a failed notification does not undo a
business save. Messages do not automatically enter model history. Discover
`harness/notifications/publishing` for plugin ownership, actions and progress.
