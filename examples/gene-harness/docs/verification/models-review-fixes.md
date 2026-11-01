# Models code-review fixes

Review: `tmp/cr-comments.md`, concerning `36b45a4a`. Checked 2026-10-31.

| Finding | Resolution | Regression evidence |
| --- | --- | --- |
| A: native compilation prevents every normal host from starting | The supervisor retries a normal captured-source host after native build/target failure. Other startup failures still use recovery. ChatGPT reports its own unavailable verifier. Crypto now declares ARM64 Linux as a supported build target; that platform has not been live-qualified here. | A fresh artifact store and deliberately failing compiler still produce a normal host with a ready fake Claude connection. |
| B: a rotated refresh token is lost on verification failure or caller cancellation | The host owns accepted refresh work and drains it at shutdown. The per-account transaction checkpoints the new pair before fallible validation. Pending identity verification prevents using those credentials; retries verify the pending response instead of spending the old token again. A verified subject mismatch clears the pair. Unverifiable signatures remain quarantined, not authorized. Known cached signing keys have a bounded one-hour stale grace after their five-minute freshness window during key-service failure; unknown keys still fail closed. | Local strict-rotation server covers temporary verification failure, cancelled discovery, malformed metadata, identity mismatch, signature rejection and shutdown during exchange. Cached-key tests cover fresh, stale, unknown and grace-expired cases. Existing cross-process refresh tests also pass. |
| C: transient failures leave a provider unavailable for 24 hours | A previous ready connection survives transient failures as stale. Positive signed-out/expired reports still replace it. Unavailable/stale providers retry after 30 seconds, doubling to five minutes; healthy providers retain the daily interval. Manual refresh remains immediate. | Cold-start recovery, stale ready metadata, positive sign-out, independent provider schedules and existing account/401 races. |
| D: optional picker failure blocks browser and voice sends | Submission is blocked only by a loaded picker's positive first-run requirement. Failed mounts bypass that gate. Catalog/preview failure withdraws the requirement and releases an already requested submit; backend admission remains authoritative. | Compiled first-submission/model-draft and picker fixtures cover unloaded state, failed mount markers, failed catalog and failed preview. |
| E: corrupt account selection prevents repair | Account actions read the old selection tolerantly. Explicit account selection overwrites corrupt `active.json` and publishes the new account normally. | Existing account-switch integration now corrupts the file before choosing the replacement account. |
| F: a waiting trigger notice never clears | Admission and trigger deletion clear the matching source-owned notice revision. A later blocking incident renews it. Notification failure does not fail an admitted round. | Trigger integration verifies initial notice, no repeated renewal, admission clearing, later renewal and deletion clearing. |
| G: Continue's model differs from the changed session pin | Continuation semantics stay unchanged. Paused-round controls explicitly name the source model/effort and explain that a fresh picker choice overrides it, while `/model` and `/effort` change new prompts. | Compiled conversation fixture checks the model and override explanation. |

Additional behavior fixes: malformed vendor model rows are skipped without losing
valid rows, while an entirely malformed list remains a failed refresh; an
unfamiliar Anthropic model cannot infer a thinking-off mode and is rejected before
HTTP; picker headings no longer append an opaque account hash.

Refresh expiry remains anchored to response receipt time. If an expired or
malformed pending response needs another exchange, a previously unverified
identity still requires a fresh ID token; omission cannot bypass verification.
Bounded callers without a host executor refuse rotation before making a request.

The Claude CLI `none` observation was not a defect: `claude_request` already sends
`alwaysThinkingEnabled: false` through `--settings`. Its test now asserts that
setting explicitly.

The provider-login contribution refactor (H), unused-wrapper cleanup, duplicated
name lists and generic helper naming are left for a separate change. They do not
need to be mixed into the runtime failure fixes.

Validation uses private credential roots, fake vendor executables and local HTTP
servers. No live provider calls or real credential changes were needed. The full
suite was not rerun; validation targets the changed paths and their integration
contracts.

Final validation:

- **47 focused Gene cases passed**, zero failures, errors or skips: supervisor,
  catalog, credential recovery, payloads, account storage/actions, transport
  identity, triggers and compiled browser contracts.
- **Three native crypto cases passed** through the consumer package's selected
  native recipe on macOS ARM64 with SDK 26.5.
- The compiled `first_submission.mjs`, `models_picker.mjs` and
  `conversation.mjs` fixtures passed directly, including failed picker requests,
  failed-mount state and continuation model disclosure.
- The event catalog check reports current, and `git diff --check` passes.
