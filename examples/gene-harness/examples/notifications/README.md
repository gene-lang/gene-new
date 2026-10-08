# Review milestone notifications

`review_notifier.gene` is a small plugin authored in a live Harness discovery
test. It owns a usage chapter, contributes concise function metadata, and posts
an edition review milestone through `PluginHost:notify`. Its button drafts a
prompt with the actual publication and entity context; it does not send it.

Copy the source into your workspace as `review_notifier.gene`. In a running
Harness conversation, use `/run` to register it:

```gene
(register_plugin "review_notifier" ($fs/read_text "review_notifier.gene"))
```

Wait for registration to complete, then discover and read its policy:

```gene
(discover "review_notice" ^kind "functions")
(doc "review_notifier/usage")
(review_notice ^revision "saved-edition-revision" ^summary "The saved review has two copy blockers.")
(notification_list)
```

Supply a real saved revision and factual summary in your application. The
acceptance run used the explicit test label `review-handoff-1`; it did not claim
to inspect a real edition. Its server verification confirmed source ownership,
the keyed inbox record, owned documentation, and the draft action. Browser
action behavior is covered separately by the Harness notification checks.

Repeating unchanged content preserves identity and unread state. A meaningful
summary or revision change updates the same message. The plugin contributes no
initial-prompt manual and does not use ordinary plugin state to store messages.
