# Models code-review fixes

Runtime findings concerning `36b45a4a`, initially corrected in `4dee3d2e` on
2026-10-31. The findings are described here so this record stays self-contained.
Follow-up corrections from 2026-11-01 are recorded below.

| Finding | Resolution | Regression evidence |
| --- | --- | --- |
| native compilation prevents every normal host from starting | The supervisor retries a normal captured-source host after native build/target failure. Other startup failures still use recovery. ChatGPT reports its own unavailable verifier. Crypto now declares ARM64 Linux as a supported build target; that platform has not been live-qualified here. | A fresh artifact store and deliberately failing compiler still produce a normal host with a ready fake Claude connection. |
| a rotated refresh token is lost on verification failure or caller cancellation | The host owns accepted refresh work and drains it at shutdown. The per-account transaction checkpoints the new pair before fallible validation. Pending identity verification prevents using those credentials; retries verify the pending response instead of spending the old token again. A verified subject mismatch clears the pair. Unverifiable signatures remain quarantined, not authorized. Known cached signing keys have a bounded one-hour stale grace after their five-minute freshness window during key-service failure; unknown keys still fail closed. | Local strict-rotation server covers temporary verification failure, cancelled discovery, malformed metadata, identity mismatch, signature rejection and shutdown during exchange. Cached-key tests cover fresh, stale, unknown and grace-expired cases. Existing cross-process refresh tests also pass. |
| transient failures leave a provider unavailable for 24 hours | A previous ready connection survives transient failures as stale. Positive signed-out/expired reports still replace it. Unavailable/stale providers retry after 30 seconds, doubling to five minutes; healthy providers retain the daily interval. Manual refresh remains immediate. | Cold-start recovery, stale ready metadata, positive sign-out, independent provider schedules and existing account/401 races. |
| optional picker failure blocks browser and voice sends | Submission is blocked only by a loaded picker's positive first-run requirement. Failed mounts bypass that gate. Catalog/preview failure withdraws the requirement and releases an already requested submit; backend admission remains authoritative. | Compiled first-submission/model-draft and picker fixtures cover unloaded state, failed mount markers, failed catalog and failed preview. |
| corrupt account selection prevents repair | Account actions read the old selection tolerantly. Explicit account selection overwrites corrupt `active.json` and publishes the new account normally. | Existing account-switch integration now corrupts the file before choosing the replacement account. |
| a waiting trigger notice never clears | Admission and trigger deletion clear the matching source-owned notice revision. A later blocking incident renews it. Notification failure does not fail an admitted round. | Trigger integration verifies initial notice, no repeated renewal, admission clearing, later renewal and deletion clearing. |
| Continue's model differs from the changed session pin | Continuation semantics stay unchanged. Paused-round controls explicitly name the source model/effort and explain that a fresh picker choice overrides it, while `/model` and `/effort` change new prompts. | Compiled conversation fixture checks the model and override explanation. |

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

The provider-login contribution refactor, unused-wrapper cleanup, duplicated
name lists and generic helper naming are left for a separate change. They do not
need to be mixed into the runtime failure fixes.

Validation uses private credential roots, fake vendor executables and local HTTP
servers. No live provider calls or real credential changes were needed. The full
suite was not rerun; validation targets the changed paths and their integration
contracts.

Validation for `4dee3d2e`:

- **47 focused Gene cases passed**, zero failures, errors or skips: supervisor,
  catalog, credential recovery, payloads, account storage/actions, transport
  identity, triggers and compiled browser contracts.
- **Three native crypto cases passed** through the consumer package's selected
  native recipe on macOS ARM64 with SDK 26.5.
- The compiled `first_submission.mjs`, `models_picker.mjs` and
  `conversation.mjs` fixtures passed directly, including failed picker requests,
  failed-mount state and continuation model disclosure.
- The event catalog check reports current, and `git diff --check` passes.

## Follow-up corrections — 2026-11-01

- **Pre-entry failures:** the supervisor uses a parent-owned main-entry marker,
  rather than matching diagnostic text. Failed package/system-library setup falls
  back to a normal source host; failures after main enters still use recovery.
  Missing `pkg-config` is validated before its executable is hashed, yielding
  `SYSTEM_DEPENDENCY_PROVIDER_UNAVAILABLE` and the missing tool's name.
- **Refresh response recovery:** missing, empty or invalid replacement values
  preserve existing credentials. A valid response can omit its refresh token,
  retaining the previous one as allowed by [OAuth refresh semantics](https://www.rfc-editor.org/rfc/rfc6749#section-6).
  Invalid response bodies still fail validation; they cannot authorize inference.
- **Permanent connection failures:** only explicitly stale, retryable observations
  preserve a previous ready connection. Invalid client configuration, quarantined
  ID tokens and a missing verifier publish unavailable and hold trigger work.
- **Verifier preflight:** a real refresh checks its signature backend before
  exchanging credentials. Tests inject a verifier where they exercise only the
  token transport. A source host without native resources makes no exchange.
- **Restart:** every in-app restart retries packaged startup, allowing a repaired
  native dependency to take effect without stopping the launcher first.
- **Expired pending identity:** an expired ID token discards the unusable pending
  response even when its access token lives longer. The saved refresh token and
  fresh-identity requirement remain, so the next exchange cannot skip validation.
- **Initial picker loading:** the first send waits at most two seconds for the
  preview. A positive chooser requirement remains enforced; timeout or failure
  releases an unchanged draft. Session, text or attachment changes prevent an
  automatic send of different content. The recovery UI bypasses disabled assets.
- **Status and notices:** accounts requiring a fresh identity tell the operator
  to reconnect; refresh-only credentials remain refreshable. Retiring a declaring
  plugin withdraws the trigger's waiting notice, just like admission or deletion.

Startup regressions use fresh artifact stores and an explicit PATH replacement
when hiding tools. Gene's exec `^env PATH` is intentionally a prefix, so that
option alone cannot simulate a missing host tool. No live provider requests or
real credential changes are part of the follow-up checks.

Follow-up validation on the rebuilt macOS ARM64 runtime:

- The **58-case focused set** had 57 passes and one restart-fixture readiness
  deadline. Giving its second start the same 40-second readiness budget as its
  first, and budgeting the process for both starts, made that case pass on an
  isolated rerun. Its packaged-retry and same-port assertions are unchanged.
- **Five system-dependency resolver tests passed**, including missing/empty
  `pkg-config` paths with coded diagnostics.
- **Three native crypto tests passed** with SDK 26.5.
- Compiled first-submission, picker and conversation fixtures passed, including
  initial-load waiting, timeout/failure fallback, disabled assets and preservation
  of session/text/media origin.
- Event catalog and whitespace checks pass. The full suite, live vendor calls
  and Linux qualification were not repeated.
