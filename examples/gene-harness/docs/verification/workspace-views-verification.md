# Workspace views verification

Implementation and verification date: 2026-10-09. Protocol: **8**.
Status: **implemented and verified**. The final suite, browser acceptance
matrix, source audit, and isolated-host cleanup are complete.

## Automated evidence

| Check | Current evidence |
| --- | --- |
| Complete Harness suite | **177 passed, 0 failed, 0 errors, 0 skipped**, including workspace-reference and crash-durability cases. |
| Cordis | 21 passed, including inherited-deadline supervision. |
| Input modes | 7 passed after the cleanup fix. |
| Web compiler | 10 passed, including capture listeners, keyboard fields, focus and history bindings. |
| DOM binding compatibility | 109 bindings checked against TypeScript's DOM declarations. |
| Workspace actions | Generation rotation/retention, interrupted recovery, immutable execution arguments, context isolation, event scope, cancellation, and conversation deletion covered by the UI integration specs. |
| Action HTTP transport | Owner auth/CSRF, session-free admission, old-route removal, duplicate identity and lookup after restart passed. |
| Abrupt exit | A completed receipt retains its saved domain data without normal shutdown; an action that writes an external effect then exits is interrupted and never replayed. |
| Browser build | Native Gene compiles the complete browser module graph successfully. |

The first full run exposed REPL deadline recovery leaving its evaluator busy.
The fix gives Cordis's supervised invocation task a native structured scope, so
an expired caller cannot skip task retirement by exhausting its Gene cleanup.
The targeted regression, all input-mode cases, and Cordis suite passed afterward.
No Gene syntax or budget limits were relaxed.

Restart checking also exposed a missing flush between domain event writes and
the separate action receipt checkpoint. Actions now flush workspace events
before recording a terminal receipt; persistence failure reports interruption.
The abrupt-exit test verifies both the saved record and receipt after restart.

## Acceptance matrix

Numbers refer to `tmp/ui-experiment3.md` §10. Browser observations use isolated
workspaces; the owner's existing host on port 18110 was not changed.

| # | Requirement and evidence |
| --- | --- |
| 1 | An empty workspace on 18114 displayed Classic Harness with only its picker option, ordinary controls and composer. |
| 2 | Picker navigation, Ctrl+Shift+1/3, view buttons, and mobile controls exercised on the project board/overview and Harbor Desk. |
| 3 | Show/Hide chat and Develop in Harness switched full/docked presentation; two tabs retained independent presentations. |
| 4 | Unsaved domain and composer drafts survived switches/reload. Back restored Harbor Desk's draft; Forward restored overview. |
| 5 | Independent tabs used full/docked layouts. A Save in B refreshed A's saved row without moving A or changing its draft. |
| 6 | Failed an admitted POST's 202 response, switched to overview and reloaded. Network trace showed one POST followed by GET of the original identity. A separate slow Save finished without clearing a different view's draft. |
| 7 | Held render responses and delivered the newer one first; releasing the old response preserved the newer filter. Repeated across two views: old board content could not replace Harbor Desk. |
| 8 | Published a board improvement through Classic `/run`; the new text appeared with the domain draft intact. A hidden view's state-version change showed an explicit reset notice and retained its version-1 draft separately. |
| 9 | A forbidden-script renderer displayed Retry and host controls. Recovery mode issued zero `/ui/render` requests. Repairing and returning worked. Disable fell back to Classic; re-enable did not navigate automatically. |
| 10 | Answered a background question while Harbor Desk remained full screen with its draft intact; its round completed. A guarded stop confirmation appeared in the host strip and Keep running dismissed it without stopping the host. |
| 11 | A prompt button offered Replace/Append/Keep when a composer draft existed; Keep preserved the original. No round was submitted by navigation. |
| 12 | Legacy panel validation/defaults and existing view integration cases pass. Harbor Desk's editor and Save work in the new renderer. Repeated Discard restored saved values without resurrection and preserved a different view's draft. |
| 13 | Cross-tab Save updated clean display and preserved dirty fields/revision. A conversation-free notification opened HD-103 in Harbor Desk with `session=` still empty; shared layout settings stayed unchanged. |
| 14 | Board revision-check integration permits one winner for competing edits. Browser stale Save was rejected while its draft remained editable. Deletion is not added to either domain fixture. |
| 15 | Reload/reconnect and explicit out-of-order response delivery exercised; instance/sequence/publication checks remain in the client. |
| 16 | Injected foreign-workspace state/pending keys were ignored. Simulated quota failure preserved a draft through unmount/remount and sent zero action POSTs. Restoring storage allowed a deliberate Save and reload. |
| 17 | During a board Save, another view remained editable but its Save was disabled; host controls named the board as origin. After completion, the other draft remained and its Save re-enabled. |
| 18 | Browser Saves before any command left the session list empty. Runtime tests verify no inherited session or failure attachments, receipts after conversation deletion, and model-readable diagnostics. HTTP and crash tests cover restart. |
| 19 | Log and action tests cover retained request equality, mutated caller/receipt copies, duplicate identity, durable admission, interruption and cancellation. |
| 20 | 512 admissions rotate the floor, preserve an old nonterminal identity, and refuse expired/future/retagged requests. Duplicate lookup does not re-admit; completed old records can be compacted. |
| 21 | Receipt-only completion leaves the UI data revision unchanged. Domain state/events invalidate views, and emitted action events use workspace scope. |
| 22 | An injected old pending shape showed unknown-before-upgrade with Dismiss. Network trace contained no action lookup/cancel/retry; dismissal only removed the obsolete browser record. |

## Browser fixtures and artifacts

The tracked project board now provides two views. A workspace-only adaptation
of experiment 2's Harbor Desk uses the canonical view slot and navigation
buttons; the original experiment-2 workspace was left intact. Its six-story
roster and focused editor rendered at desktop and 390×844, and saving advanced
the selected story revision without creating a conversation.

Local evidence under ignored `tmp/` includes `ui3-harness-verified.log`,
`ui3-cordis-final.log`, `ui3-web-modules.log`, `ui3-action-crash.log`,
`ui3-transport-tests.log`, `ui3-workspace-reference.log`, and
`ui3-assets/harbor-mobile.jpg`, `ui3-assets/harbor-full.jpg`, and
`ui3-assets/harbor-docked.jpg`. The docked screenshot includes a prepared,
unsent development prompt; this verification does not claim a live-model
authoring run. The development loop was exercised through Classic's actual
command composer and ordinary plugin publication.

All isolated test hosts and owned browser tabs were closed, viewport overrides
were reset, and interception/storage fault injections were removed. The user's
original host and browser tabs were left untouched.
