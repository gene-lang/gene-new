# Publish and verify a UI plugin

For action failures, inspect `(ui_action_receipts ^view "your_view" ^status "failed")`
when asked. UI Saves have workspace receipts and do not automatically contribute
diagnostics to a conversation. Check the recorded function/view revision before
repairing a plugin that may already have changed.

1. Discover registration functions and read `harness/plugins` before packaging.
   Persist source early. Generated modules have an inert top level: imports,
   functions, types, impls, protocols, aliases and enums. Top-level `const` is
   currently rejected; use a zero-argument function for reusable literal lists.
2. Save a complete `(mod plugin ...)` source and register it. Use `^^replace`
   for an existing ID. Publication is queued until the turn closes. Inspect the
   next turn's plugin status and view feedback before declaring completion.
3. Enable/configure the UI with `ui_configure`, following
   `harness/ui/configuration`. Use `ui_preview` with the actual component name
   and representative scalar states: roster, selected editor, intake, empty
   results and filters. It returns a full validated panel tree or an error.
4. Exercise action functions and policy checks: invalid inputs, review gates,
   stale revisions and replacement preservation. Avoid starting another Harness
   owner for the same workspace. Isolated Gene checks can operate on pure logic.
5. Verify actual browser controls and geometry. Server previews cannot prove
   clicks, field submission, retained drafts, focus, discard, layout, or ordinary
   surrounding-slot behavior. Report this boundary if no browser is available.
6. Try reload, supervised restart and `/ui/default` recovery. Leave the UI usable
   and document outstanding limitations honestly.

Publication outlines are bounded/truncated and cover stateful panels. Their
absence does not imply ordinary slots failed. Explicit preview gives the full
panel tree. Inspect actual dynamic status counts in the browser.

Use Gene build tooling when needed. `gene fmt file.gene` writes canonical source
to stdout; explicitly adopt that output and check second-pass idempotence.
A nested standalone entry can become its own ad-hoc package root; keep isolated
tests at the workspace root or define a suitable package manifest for imports.

Retain stable identities and saved records during a UI replacement. Record what
was verified by actions/previews versus actual browser acceptance. Keep a short
model notes file so interruptions do not erase useful investigation.
