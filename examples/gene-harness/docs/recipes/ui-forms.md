# Keyed forms and action fields

A stateful panel declares `view_state`, `state_version`, an `actions` list of
registered function names, and a read-only `render` callback. The following is a
fragment inside that callback; `selected` is a saved record with id, revision,
title and review flags. The declared action has matching named arguments.

```gene
`(form ^key %$"edit-${selected/id}" ^action "desk_save"
   ^args %{^id selected/id ^revision selected/revision}
   (button ^type "submit" "Save job")
   (label "Job title"
     (input ^key %$"title-${selected/id}" ^field "title"
       ^value %selected/title ^^required))
   (label
     (input ^key %$"checked-${selected/id}" ^type "checkbox"
       ^field "safety_checked" ^checked %selected/safety_checked)
     "Safety review complete"))
```

Fields and static `args` become named function arguments. Text/number inputs
produce strings; checkbox fields produce Bool. Parse numbers in the action.
Preserve the exact field names, including underscores; friendly labels can differ.
Use actual saved revisions, not fixed illustrative values, in form arguments.

For a textarea, set `^value` explicitly or use plain text children as the initial
value. The validator normalizes text children into value for the keyed draft
adapter; an explicit value wins. For example:

```gene
`(textarea ^key %$"notes-${selected/id}" ^field "notes"
   ^rows "3" ^value %selected/notes)
```

Preview the normalized value and verify an unchanged textarea survives Save.

Keys must be nonempty and unique across the view. Forms, draft fields, state
controls and action controls require keys. Include the entity ID in editor keys;
retain compatible keys to preserve drafts. Fields must belong to a form and be
unique within it. Nested forms are rejected. A field must not also control view
state. Use `state` for browser query/filter/selection and `field` for submitted
draft values.

Build options by computing labels and binding lists first, then splice quoted
nodes with `%options...`. Do not interpolate an unbound call and assume it will
be evaluated as label text. Preview actual staff/stage labels, not only tags.

Use `harness/ui/drafts` for reset/navigation semantics, `harness/ui/revisions`
for durable saves, and `harness/web_components` for all supported elements,
attributes and bounds.
