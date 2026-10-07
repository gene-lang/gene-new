# Start a workflow UI

Use ordinary Gene plugins to customize the Harness. Begin with a small working
workflow, persist its source, publish it, and then expand. No separate server or
repository implementation imports are needed.

## Choose the next reference

| Need | Load |
| --- | --- |
| Enable a panel, choose layout or theme | `(doc "harness/ui/configuration")` |
| Forms, named fields, labels and actions | `(doc "harness/ui/forms")` |
| Browser filters, selection and drafts | `(doc "harness/ui/drafts")` |
| Durable records and safe concurrent edits | `(doc "harness/ui/revisions")` |
| Publish, preview, test and recover | `(doc "harness/ui/publication")` |
| Plugin construction and discovery metadata | `(doc "harness/plugins")` |
| Complete element/slot contract | `(doc "harness/web_components")` |

Load the relevant recipe when you reach that step. Discover available functions
with `(discover "ui" ^kind "functions")`; they are already callable. Read
`gene/overview` before authoring Gene; probe uncertain constructs. In particular,
use `if_yes` for a multi-step guard, bind computed values before path access,
and bind lists/labels before interpolating them into quoted views.

## Organize the product

Keep workflow policy in action functions and durable plugin state. Keep browser
query, filter and selected record in scalar view state. A focused editor can
replace the roster when a record is selected; do not stack every workflow screen
above the common action. Readiness text should identify whether it describes
saved state or unsaved input.

The panel is one selected component beside the Harness conversation. Surrounding
slots are sidebar, toolbar, composer, status, welcome and status_summary; the last
two replace their built-in views. Ordinary slots support command/prompt buttons;
stateful panel forms invoke declared functions. Themes and layout are bounded.

Browser selection is not automatically in the model's conversation context.
Include an explicit saved record ID/headline in a contextual prompt button.
Prompt buttons fill the composer; the user chooses when to send.

Make your own plugin discoverable too: short function descriptions, tags and
chapter references; detailed workflow instructions in owned docs rows. Do not
inject the full manual through prompt contributions.
