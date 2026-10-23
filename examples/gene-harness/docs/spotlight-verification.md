# Spotlight verification — 2026-10-23

The three-stage first slice in `tmp/harness-spotlight.md`, including review
decisions S1–S7, is implemented. Operator and contribution author guidance is
in [Spotlight](spotlight.md).

## Review corrections

The follow-up review of `c98c9b1c` identified gaps beyond the initial checks.
The changes below address all 15 findings; the original checks remain recorded
below as historical evidence, not as coverage of those gaps.

| Review | Correction and regression coverage |
| --- | --- |
| 1 | Host-owned, explicit inspected-request discard handles missing/expired receipts and corrupt data. It persists the discard, rejects it during submission/lookup, and never replays. Compiled recovery tests cover reload and unlock. |
| 2 | Pre-POST refusals carry `not_sent`; confirmation buttons can retry those refusals while unknown POST outcomes remain protected. Compiled confirmation tests exercise both outcomes. |
| 3 | All browser creation paths use a shared uncertainty guard with an explicit inspection acknowledgement. Full-client tests cover a 502, blocked creation, acknowledgement, and subsequent success. |
| 4 | The merged list reserves up to nine matching local entries. Local entries win equal-quality ties, and empty-query actions precede recent conversations. Native and compiled tests cover crowded lists and identical New conversation titles. |
| 5–6 | Conversation ranking no longer fuzzily matches generic type aliases. Bounded title/first-request prefixes define the search scope; long fields alone do not mark a completed scan partial. Native tests cover real snippet matches and a long unmatched request. |
| 7, 10 | Module-load rejection uses a hygienic error name and the rejection argument of `then`. Web-runtime tests name the callback `error` and distinguish import rejection from a ready callback throwing. |
| 8 | Shared settlement is the only composer-clearing path for commands and requires matching session/text. Full-client tests cover pagination, changed drafts, matching command text, and retained attachments. |
| 9 | Action feedback persists through status, availability, and query updates while an outcome is unresolved. Unrelated status pushes retain existing DOM rows. Compiled tests check message and node identity. |
| 11 | Failed revision markers retain no disposed root/controller. A fixture publishes cleanup before throwing, and compiled tests assert one cleanup across failure and disable. |
| 12 | A small command-state GET replaces full transcript/status preflight. Navigation consumes its fetched snapshot. HTTP tests verify the minimal response, sequence advancement, explicit conflicting admission, and receipt recovery without replay. |
| 13 | Asset preparation stays before composition staging; preparation errors become quarantined activation failures. `$web/load` now converts native IO/profile errors into catchable Gene errors while preserving panics and cancellation. Tests cover missing/invalid sources, a macro panic, and host startup with the optional plugin failed. |
| 14 | A full ranked list returns unchanged for a candidate below its tail. Native tests check retained identity and bounded merging. |
| 15 | Command parsing uses the leased composition context for lookup and suggestions. Existing admission/lease tests exercise replacement, recovery, and execution under the admitted snapshot. |

Follow-up validation: **22 Harness tests passed** against the rebuilt runtime,
covering commands, admission identity, browser contributions, compiled clients,
HTTP transport, ranking/search, baseline profiles, and UI actions. The compiled
client case also runs the full conversation-client and media fixtures. The
conversation fixture additionally verifies that navigation consumes its fetched
snapshot. The final suite log is `tmp/spotlight-fixes-final-tests.log` at the
repository root.

The follow-up web-runtime suite passed **12 tests**, including catchable source
and compilation errors, preserved macro panics, hygienic module-load failure
callbacks, and distinct ready-callback failures. **125 DOM host bindings** also
passed validation. `git diff --check` is clean. Web-runtime output is recorded
in `tmp/spotlight-fixes-web-tests.log`.

## Requirement audit

| Requirement | Implementation and evidence |
| --- | --- |
| Spotlight is an optional default plugin | `src/builtin/spotlight.gene`, baseline profile; native descriptor/lifecycle test and Chrome disable/re-enable check. |
| Supported Gene browser entry and revisioned assets | `src/ui/browser_clients.gene`, `$web/module_url`, `$browser/load_module`; real HTTP checks fetch both module and stylesheet with 200 responses. |
| Validation and publication before activation | Registry accepts prepared Gene assets and a published stylesheet node. Compilation happens before composition staging; validation creates no asset publication side effects. |
| Mount, unmount, replacement, failed mount, pending load | `client/browser_clients.gene`; compiled tests revoke a pending mount, remount cached code once, remove toolbar/overlay on failure, and suppress automatic retries of a failed revision. |
| Modal ownership and recovery exclusion | `client/overlays.gene`, view router, safe status/push filtering; native recovery descriptors are empty and safe browser clients never mount contributions. |
| Cmd+K/button and autocomplete appearance | Plugin owns input/listbox, styles and result sources; verified in Chrome with light/dark palettes and a 390×800 viewport. |
| Up/Down, Enter, Escape, Cmd+Alt+1–9 | Compiled controller tests and real Chrome checks; digit mapping uses physical codes and original ranked positions. |
| Scrolling, disabled slots, repeat/composition guards | Compiled controller tests use more than nine results, keep a removed command's number disabled, reject a second activation, and guard composing events. Chrome navigated to result 11 in a 20-result list; Cmd+Alt+1 still opened the original first result. A composition check kept the launcher open on Enter. |
| Stable results and stale-response exclusion | Typed IDs and mount/open/query/step generations; timed-out sources cannot reorder a displayed snapshot, and old openings cannot publish after reopen. |
| Parent step and captured target | Theme choices preserve their filter and original session/revision across Escape/re-entry; closing discards transient steps. Compiled tests change the host's selection underneath the step. |
| Tab/focus and removed invoker fallback | Shared focus trap plus visible-control restoration; compiled checks cover removed controls and a hidden host bar. Chrome verified input → Close → Enter and composer focus/draft return. |
| Confirmation handoff | `client/confirmations.gene`; a real host confirmation arriving over Spotlight closed the modal and focused Confirm. Keep running dismissed the test confirmation; the background sleep command was cancelled. |
| Independent workspace metadata search | `src/runtime/launcher_search.gene`, `/api/v8/search/sessions`; native test inspects 162 records and HTTP test searches beyond the sidebar's 100-row bound. |
| Bounded search and useful labels | At most 50 results, 256 query bytes, bounded metadata matching and cooperative work budget; partial searches are labeled. Results include kind, parent, ID, snippet, activity and index revision. |
| Conversations, views and common actions | Host bridge reuses session/view navigation, New conversation, Triggers and Needs attention. Chrome verified creation and return to an existing conversation with its own draft. |
| Help and theme commands | Explicit plugin adapters use normal command admission and receipts. Chrome ran both theme choices through the same command path. |
| Text and attachment drafts | Compiled full conversation-client test calls the Spotlight command bridge with a ready attachment and text draft, then asserts both survive admission. Existing media composer checks cover upload edges, persistence and session transfer. |
| Persisted pending commands and no automatic replay | `client/command_client.gene`; tests lose an acceptance response, reload, recover the original request, reject a fresh command while unknown, and block corrupt recovery data. |
| Recovery independent of plugin lifecycle | Pending state and Resolve command belong to the host client. Native receipt recovery succeeds after command replacement and removal. |
| S7 admission identity and execution lease | `src/runtime/commands.gene`, `command_identity.gene`; tests reject stale/new or conflicting identities and publish a replacement after admission while proving the original handler and snapshot execute. |

## Checks run

- Focused Gene suite: **13 passed**, including existing command regressions,
  command identity, metadata search, HTTP transport, executable contributions,
  and compiled client behavior. The compiled-client case also runs the full
  conversation-client and media composer JavaScript edge fixtures.
- The compiled-client case was rerun after the final argument-step and focus
  refinements: **1 passed**. Local logs are `tmp/spotlight-final-tests.log` and
  `tmp/spotlight-client-final.log` from the repository root.
- `tests/test_web_modules.nim`: **11 passed**, including asynchronous module
  loading and DOM focus primitive lowering/runtime checks.
- `tools/check_host_bindings.mjs`: **125 bindings** checked against DOM types.
- Broader Harness regression selection: **78 passed**, with **3 setup errors**
  in timezone tests because an interval-capable `zdump` was unavailable. These
  tests do not exercise Spotlight.
- `git diff --check`: clean.

Chrome verification used an isolated offline workspace, not a model provider.
Temporary viewport/composition overrides were reset. A real file-chooser upload
was blocked by the Chrome extension's disabled file URL permission; that
permission was left unchanged. Attachment retention is covered by the compiled
full-client and media fixtures rather than that blocked upload attempt.

`tests/fixtures/spotlight_browser.gene` seeds a disposable existing host through
the ordinary authenticated Gene API for repeatable scrolling checks. It reuses
matching fixture conversations when rerun.

## Gene capabilities exercised

The application remains Gene. Reusable module loading and DOM focus operations
were added to the existing web library surface, with compiler/runtime tests.
The browser-edge test fixture is JavaScript because it supplies the external
DOM and ESM runtime; application transitions and dispatch run compiled Gene.

The web profile lacks a generic ordering API shared with native `$order`.
Harness currently compares UTF-8 bytes for deterministic ID/activity ordering,
following its existing registry-ordering pattern. A reusable web ordering API
and Unicode case-folding parity are candidates for separate library work.
This implementation introduces no new Gene syntax or language semantics.
