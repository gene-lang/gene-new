# Safe durable edits

Store durable records using `PluginHost:state` and `PluginHost:update_state`.
Pass `^session` only for genuinely per-conversation state. Render callbacks read
state and return quoted data; they must not write durable state/events and have
a one-second/32 MiB budget.

Declare `^requires ["ui/state_lock"]` on a plugin doing read/check/write saves.
Inside activation resolve it:

```gene
(let with_state_lock (host .PluginHost:resolve "ui/state_lock"))
```

Run each mutation inside `(with_state_lock "your_data_key" (fn [] ...))`.
The runtime owns this gate across plugin activation replacements. The body must
read current records, check the submitted expected revision, validate policy,
increment the record revision, and write updated state. All callers, including
model functions and UI actions, must use the same save path and data key.

Reject mismatched revisions without overwriting the saved record. Give accurate
recovery guidance: host Discard edits loads current values for reconciliation.
Validation errors should also leave drafts available. Distinguish saved-record
readiness from draft checkbox changes, and invalidate reviews when meaningful
content changes according to your product policy.

The project-board example in `experiments/ui/project_board.gene` demonstrates
the complete atomic save. Do not import host implementation modules into a
generated plugin; use the shared API and required seam.
