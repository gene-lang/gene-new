# Browser state, navigation and true discard

View state is browser-owned scalar data, passed as `context/view_state`.
Use string defaults for value controls and Bool defaults for checkboxes.
A selected string can route between roster (`""`), record editor (record ID)
and intake (a reserved value). Query/filter state can remain while moving between
these views. Typing filters is debounced; only the target component rerenders.

Compatible keys retain unsaved field values, focus and selection. Switching
records must use entity-specific editor/field keys; switching back can restore
that record's unsaved draft. Navigation is not discard.

**Use the host Discard edits control to clear retained drafts and reload saved
values.** Its scope is the current view's drafts, not one individual form. Other
views' drafts remain. The current
plugin contract has no per-editor draft-store reset. Alternating keys between
`0` and `1` does not delete drafts: returning to an old key can resurrect one.

Increment `state_version` only when browser-state compatibility changes. This
resets incompatible view state once; it is not a recurring discard operation.
Keep durable state migrations separate and preserve existing record revisions.

If a stale save is rejected, preserve its draft and explain how to load the
current record before reconciliation. Test repeated discard and repeated
navigation in a real browser; `ui_preview` cannot establish draft behavior.
