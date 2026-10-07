# Workspace UI experiment results

Implemented and exercised on 2026-10-06. The experiment remains opt-in and its
API is provisional.

## Recommendation

Keep the narrow experiment. A workspace plugin can supply a useful board,
edit its data through ordinary functions, and change its presentation without
editing the host UI. Server previews provide a useful model repair loop.
The existing conversation remains usable beside the board.

Continue evaluating server-rendered forms before adding compiled browser
plugins, a general layout framework or a live API catalog. The first measured
loopback interaction was responsive, but it is not a large-data benchmark.

## Observed behavior

| Requirement | Evidence |
| --- | --- |
| Opt-in panel, layout and theme | Gene installer registers the board and enables it explicitly; ordinary startup stays in chat layout. Browser Hide/Show and theme configuration work through the public API. |
| Stateful views render on request | Integration tests verify descriptors contain no tree and an unrelated render callback is not invoked by a targeted request. |
| Keyed drafts and focus | A delayed `/run (board_save ...)` changed task data while the Title field was focused. The unsaved value and caret at position 21 were preserved. |
| Invalidation from another caller | The `/run` edit updated the row and clean fields while preserving the current filter and dirty Title. |
| Stale edits | Saving that dirty form with its original task revision failed; Discard edits restored current values. |
| Overlapping edits | An integration test pauses between the revision check and write, then submits from two conversations. The runtime-owned state gate allows one commit and rejects the other stale edit. |
| Session-bound receipt recovery | A Save response was dropped after HTTP 202. The browser switched from session A to B and reloaded; it fetched the receipt from A. One POST occurred and the task revision advanced once, from 3 to 4. |
| Hidden action blocks | Saves remained in durable command history and were absent from live and restored conversation command blocks. Status and errors appeared in the panel. |
| Failure feedback | The stale Save's diagnostic appeared in A's next model request. Tests verify successful actions attach nothing and a failure is consumed once. |
| Model repair without a browser | A scripted model sequence published a failing view, received its error beside publication feedback, repaired it, called a failing Save function, and repaired that function. The round completed with the verified result. |
| Stale render responses | Browser interception held responses for two filters. Delivering the newer response first and then the older one left the newer filter and row intact. |
| Plugin-only presentation change | Re-registering a source variant changed the heading to “Workspace task board” while retaining the filter. No host edit was involved. |
| Broken-view recovery | A source variant returned a forbidden script element. The old tree remained visible with Save disabled. `/ui/default` preserved the selected session, hid the panel and issued no targeted render request. The plugin was repaired from that page. |
| Existing workflows | Browser checks exercised questions, answering, REPL entry/exit, cancelling a spinning REPL input while retaining a binding, and cancelling a chat round. |

Render callbacks reject durable Harness state/event writes. The experimental
form validator rejects missing/duplicate keys, unowned/duplicate fields and
nested forms before display.

## Timing and verification

An eight-character filter-typing burst produced one targeted render request
after the 150 ms debounce. The observed request-to-response interval was
77.8 ms on a two-task board. This is one local sample; larger boards and
sustained typing remain useful follow-up measurements.

- Initial complete Harness run: 141 passed before the final three added cases.
- Final complete run: 143 passed; the existing responsiveness case failed when
  one HTTP listing took 104 ms against its 100 ms bound. Running that case
  alone passed all CPU, native-callback and process scenarios. The bound was
  not relaxed. A further overlapping-edit regression passed after adding the
  shared state gate. All 145 current cases have passed across the full and
  targeted runs; the final full run was not entirely green.
- Web module compiler tests: 8 passed, including function-field callee
  evaluation before argument effects and rejection of a wrong argument type.
- DOM host binding check: 100 bindings checked against TypeScript's DOM types.
- The final browser client compiled successfully, and the diff whitespace
  check passed.

The new Gene web operations are `dom/insert_at`, `dom/remove`,
`dom/remove_attribute` and `dom/set_style`. The web compiler also now accepts
calls through statically typed function fields. These reuse existing Gene
syntax and belong to the web runtime rather than the board implementation.

Detailed logs are in the repository-root `tmp/harness-ui-*.log` files. The
browser screenshot is `tmp/harness-ui.png`.

## Costs and limits

View-state changes use a loopback round trip. Dirty form state is retained by
stable keys; incompatible state versions reset it. Workspace changes currently
invalidate experimental views conservatively, without a dependency graph.

Actions retain the existing 128-command history window. The exercised sequence
did not require separate action retention, but frequent explicit Saves can
eventually displace older command receipts. The browser does not automatically
replay an uncertain action whose receipt is unavailable.

The implementation stays in an optional panel controller and small view/action
runtime modules, with integrations into existing publication, command and
stream delivery. This is enough for the board; expanding the abstraction should
depend on further plugin examples. The timing gate's sensitivity under full-suite
load also deserves continued observation.
