# Models implementation

Implements [Providers, models and effort](../models.md). The design and all seven
review resolutions were accepted on 2026-10-30. This checklist tracks the full
scope; unchecked work is still required.

Subsequent runtime review fixes and their targeted verification are recorded in
[Models code-review fixes](models-review-fixes.md).

The [requirement audit](models-requirements.md) maps the accepted scope to
implementation evidence and its verification limits. The accepted scope is
implemented, including the owner's simplified admission rule and native
Anthropic API check waiver.

The third review's proposed preview/admission guard was declined by the owner.
The backend uses the current session selection at admission, with no stale-preview
check. This resolves the implementation hold; the round snapshot still applies.

## Work

- [x] Contract and effort: optional connection/models callbacks, built-in lists,
  portable effort resolver, auto defaults, unified precedence, round selection
  with transport identity, context/image metadata, continuations and complete
  delegated-child selections. Update sub-agent documentation.
- [x] Reject incomplete, errored and empty OpenRouter responses before evaluation.
- [x] Discovery: bounded connection probes, API model lists, OpenRouter key
  checks/catalog normalization/search, credential resolver, periodic/manual
  refresh, stale catalog cache, connection state and billing labels, auto ranks.
- [x] Picker/default: composer_actions plugin, submit-time session selection,
  /model and /effort, CLI overrides, first-run chooser, saved defaults, fresh
  status with catalog revision and separate catalog fetch, protocol version.
- [x] Triggers: per-occurrence readiness isolation and visible waiting reasons,
  model_settings validation/warnings, round-scoped selection, update_trigger,
  plugin trigger synchronization, list_models discovery, browser controls,
  trigger documentation.
- [x] Shared models.gene: inert schema, validation/errors, merged overrides,
  hidden models and presets, custom endpoint adapters, live row reactivation,
  bounded cross-process save lock and digest conflicts, Models page.
- [x] Budgets: effort-dependent output reserves informed by recorded usage,
  Anthropic stream-and-buffer, model caps, correct adapter fields and
  complete-response handling. Measurement limits are recorded below.
- [x] Sign-in: OpenRouter PKCE, ChatGPT dynamic registration/loopback/account
  records/plan permission checks/refresh lock, ant credentials, retire Codex
  backend-api only after successful first-party sign-in verification.
- [x] Verification: focused and complete hermetic suites, browser compilation
  and UI verification, event catalog checks, explicit live adapter/sign-in
  checks where authorized, evidence in docs/verification and docs/README.md.

## Implemented foundations

- Public effort/model helpers, offline provider lists, optional provider callback
  contracts and explicit SDK module declarations.
- Saved-first selection for managed and direct launches, provider-scoped model
  defaults and `--provider`/`--model`/`--effort` host pins.
- Durable round selections with requested/effective effort, model metadata and
  transport identity. The turn loop uses the same selection for compaction and
  inference; a changed transport is refused before another call.
- Child selections resolve their own model metadata and inherit requested effort
  and the parent transport. Deliberate continuations re-admit; unattended ones
  refuse a changed connection, including restart resumption.
- Pure vendor catalog normalizers. ChatGPT instruction templates are excluded,
  and OpenRouter's null/mandatory effort cases are covered.
- A transport-only credential resolver and GET probe helper. Real subprocess
  specs verify bounded credential commands and generic errors.
- An inert models.gene schema, entry-level errors, strict adapters/credentials,
  atomic saves, a reusable timed lock helper and cross-process revision checks.
  A two-process spec proves one save succeeds and the stale save is refused.

The optional catalog is now installed in the normal baseline. Claude CLI probes,
authenticated ChatGPT models, Anthropic model pagination, OpenRouter key verification/model lists,
stale metadata, account-scoped caches, refresh and 24-hour polling are wired.
Text providers reject the replaced `available` callback; image/speech contracts
are unchanged. Offline profiles omit automatic catalog discovery. The manager
propagates its resolved root to children, and web hosts accept `--root`.

`list_models` is discoverable and returns ready visible models with paging,
efforts, limits and billing. Status resolves the actual selection on every read,
uses a running round's snapshot, and carries an opaque generation-aware catalog
revision. Protocol 9 separates `GET /models` from status and adds POST refresh;
round and deliberate-continuation routes accept `model_settings`. Busy/refused
admissions do not save their submitted choice.

The requirement audit records the completed checks and their limits. The
design's real ChatGPT sign-in prerequisite is satisfied; its separate live
inference attempt encountered the account's plan-usage limit, recorded below.

## Evidence (2026-10-30)

- Focused effort, snapshot, provider preparation, schema, import-boundary and
  discovery-normalization specs pass. The exact configuration example in the
  design document parses and validates in a contract spec.
- Real round-controller specs hold one selection across multiple model calls
  and refuse a replacement endpoint before contacting it.
- Continuation recovery specs passed, with additional specs distinguishing an
  operator choosing automatic mode from an unattended continuation.
- The existing child follow-up spec now uses parent/child models with different
  effort support, windows, output limits and input types; it passes.
- Credential and two-process shared-file specs pass.
- The initial broad run had 338 passes and three failures: an old precedence
  expectation and missing SDK declarations. Their focused regressions now pass.
  The broad rerun after the fixes passed **354 tests, zero failures/errors**
  (full unit suite plus affected agent, provider, public-library, round,
  continuation, delegation, image-round and trigger integration suites).
- `tools/generate_harness_event_catalog.gene --check` reports current.
- After that run, an additional optional-catalog check passed: removing the
  catalog preserves an existing round's selection but still rejects a changed
  provider endpoint. The focused public/snapshot/import suite (17 cases) and
  round-selection checks (4 cases) passed after this change.

## Next integration

The runtime factory for `models/host` starts the contribution-owned worker on
Cordis's host executor. This fixed a verified activation-deadline failure without
exposing an unbounded background executor to plugin code. The lifetime test now
proves refresh after activation expiry and worker cancellation on removal.
Existing integration fixtures use private roots, fake vendor CLIs and cleared
credentials/selection environment through Gene's subprocess `^env` option.

The service reads the shared file, scopes its model cache to the connection and
merges file/discovery/built-in fields through `models/catalog`. Its snapshot is
cached and never probes. A malformed file blocks implicit fallback but permits
an explicit provider choice. Provider results remain distinct during concurrent
probes; model-list paging normalizes Gene map keys to string provider IDs.
Round receipts retain both the full observed identity and a separate static
provider descriptor digest so optional catalog removal cannot disable endpoint
checks or make the loop depend on that contribution.

## Current verification follow-up

- The wider discovery/protocol run passed **394 tests** and found one shutdown
  failure: one composition lease remained after a session-service test. Its
  focused reproduction passed, so this is still under investigation rather
  than considered resolved. Lease-holder diagnostics now distinguish status,
  render, model-turn and publication readers.
- The complete session-service file passed all **19 tests** with those
  diagnostics; the original intermittent shutdown failure is not yet explained.
- A real fake-CLI login admits and completes a turn with no provider config;
  protected GET probes cover ready, rejected, unavailable and malformed results.
- Fresh status and atomic model-settings admission have a passing integration
  spec, including a default change during an active round and a busy rejection.
- A transport refusal before dispatch preserves pending operator work for a
  deliberate continuation. The replacement endpoint is not called until that
  continuation. A stopped automatic admission can be retried deliberately;
  automatic recovery still leaves it stopped. Explicit continuation picker
  choices persist, while derived continuation settings do not add a session pin.

## Picker and trigger integration

The optional Models plugin now owns model/effort controls in `composer_actions`,
search, presets, typed IDs, connection/billing labels, first-run default choice,
saved defaults and `/model`/`/effort`. CLI sends accept model/effort overrides.
Typed, card, deliberate-continuation and voice payloads retain an explicit local
choice until admission; sends without a new choice use the backend's current
session settings. No preview identity or stale-choice check was added.

Trigger creation and row editing reuse that picker through a page-owned bridge.
Their drafts are separate from session choices. Browser creation, PATCH updates,
`update_trigger` and `triggers update ID FILE` share validation and warnings.
Model edits preserve the schedule; changed plugin declarations synchronize their
model fields. Firings skip session pins, keep their own snapshots, and a blocked
occurrence stays due while healthy work and later tick maintenance continue.
Waiting reasons appear in rows and blocked transitions publish keyed notices.

Verification:

- The affected catalog, selection, profile, trigger/crash-recovery and compiled
  browser suite passed **32 tests, zero failures/errors**. Later trigger-plugin
  synchronization and overlay/bridge/voice additions passed their focused
  regression suites.
- Real CLI processes against a local scripted host verify send flags, commands,
  preview/default routes, digest-conflict HTTP 409, and trigger model updates.
- Compiled DOM fixtures cover first-run choice, search, typed IDs, signed-out
  models, requested/effective effort, independent trigger/session drafts,
  uncertain voice receipts, plugin removal and modal cleanup.
- Chrome acceptance with `tests/fixtures/model_browser.gene` verified connection
  groups, default selection, trigger creation with a separate model, editing its
  row back to Default, and returning focus to the trigger form. Vendor plugins
  were removed before activation and all inference used fixed local responses.
- The retention test exposed a legitimate GC deferral while a background body
  writer held a lease. It now requires collection on subsequent scheduler ticks
  within a bounded wait, without bypassing writer protection. The full affected
  suite passed after this change.

Gene tooling observation: web `$size` on an `Any` holding a serde/JSON property
map currently tries `.size` and fails. The trigger-draft presence check uses a
typed property-map iteration; the web target should gain the native map behavior.

## Shared configuration and adapters

The baseline now activates file-defined endpoints through `model_endpoints` and
an activation-owned file watcher. A host-owned publication worker serializes
the validated replacements; it can safely retire the catalog that requested
the publication. Save acknowledgements read the current catalog after replacement.
Disabled or explicitly overridden endpoint plugins remain under operator control.
Recovery and doctor still do not load this file.

The four adapters have distinct effort and budget fields. Responses and Messages
buffer SSE through a complete terminal response; incomplete, refused, errored or
empty output never reaches the evaluator. Credential commands run only at send
and discovery boundaries, and their time counts toward the operation's limit.

The standalone `/models` page supports connection/account/billing information,
model limits and prices, shared defaults, visibility, metadata and endpoint
editing. All saves use the shared lock and expected digest. A conflict reloads
for review and never replays the write automatically.

Verification includes real localhost requests for all four adapters, command
credential counts/redaction, source immutability, live endpoint replacement,
metadata handoff during a running round and failed-connection publication across
catalog generations. A probe started before a 401 cannot erase the newer expired
state. Kernel publication mutation now shares the composition gate, fixing an
observed bootstrap/replacement race.

Chrome acceptance added two inert local endpoints and a model, saved a default,
and hid a model. Compiled DOM tests cover these writes and conflict review. The
local browser host was stopped; no vendor inference or sign-in was performed.

## Budgets and sign-in progress

Built-in Anthropic now streams and buffers Messages; OpenRouter shares the
complete-response decoder and effort-dependent budget helper. The reserves
are 8,192 for none/minimal/low, 16,384 for medium, 32,768 for high,
65,536 for xhigh, and 128,000 for max/ultra, capped by model metadata. The minimum
comes from the recorded summary peak described below; larger reserves provide
headroom as effective effort increases. Four live DeepSeek measurements verify
the advertised efforts and budget fields. These are engineering defaults with
limited samples, not a claim of production calibration for every model.

`probes/model_budget.gene --live MODELS_FILE PROVIDER MODEL [EFFORT ...]` makes one
inference request per effort. It validates all requested efforts before the first
call, never evaluates output, and prints only timing, budget, byte count and
whitelisted token usage. It refuses inference without `--live`. A real-process
localhost fixture proves the flag, cap, validation and output-isolation rules.

OpenRouter Connect now uses the existing web host's loopback callback, fresh state
and S256 PKCE, and writes a successful key atomically with mode 0600. Protected
owner APIs expose only the authorization URL and bounded attempt status. The
callback itself uses one-shot state and needs no owner cookie. Failed/declined
attempts preserve the saved login, callback replay does not exchange twice, and
a response arriving after cancellation cannot replace credentials. Removing
Models cancels its pending attempt. Environment keys outrank the saved record.

The localhost exchange test, activation-lifetime spec, compiled browser Connect/
Cancel test and real CLI/web consent-decline checks pass. Credential precedence
uses explicit temporary record paths and child auth-home overrides.

The broader run after these adapter, publication, streaming and sign-in changes
passed **360 tests, zero failures/errors**: all unit specs plus affected public
libraries, provider selection/calls, kernel/composition contracts, rounds,
continuations, delegations, session service and compiled browser clients. The
earlier intermittent shutdown-lease failure did not recur; its cause is still
unconfirmed. The added credential-precedence subprocess check passed separately.

Anthropic now uses `ANTHROPIC_API_KEY` first, then `ant` Console OAuth. Discovery
extracts only the documented active profile/workspace from `ant auth status` and
does not treat its exit status as a health check. Send and authenticated model
listing call `ant auth print-credentials --access-token`; Bearer headers remain
inside transport operations. The picker labels the chosen source and API billing.
Claude subscription tokens are still rejected as API keys, and Claude Code's
credential storage is never read. Four routing/redaction specs pass alongside
the adapter and built-in preparation regressions.

Sources checked during implementation: [OpenRouter PKCE](https://openrouter.ai/docs/guides/overview/auth/oauth),
[ant credential export](https://platform.claude.com/docs/en/cli-sdks-libraries/cli/scripting),
[ant status semantics](https://platform.claude.com/docs/en/cli-sdks-libraries/cli/authentication).
ChatGPT registration, ID-token validation, account records and refresh are now
implemented as described below. Real sign-in and account discovery succeeded;
its separate live inference attempt reached the account's usage limit.

## ChatGPT implementation and verification (2026-10-31)

The `chatgpt` provider uses the public Responses endpoint with `store: false`,
`stream: true`, no output budget or sampling fields, and a completed-response
decoder. Its authenticated catalog preserves server order and only advertises
effort metadata returned by that route. Unknown support offers Auto.

Connect uses fresh state, nonce and PKCE, a stable host UUID and the running web
host's loopback callback. New registrations exchange with the issued client ID;
returning registrations retain their client/account binding. A failed new
registration keeps its issued ID for a fresh attempt. Explicitly enabling a
missing plan grant uses the documented `prompt=consent`; ordinary sign-in does
not force consent. Identity-only success stays signed in with inference disabled.

`genex/crypto` adds OpenSSL-backed RS256 verification and OIDC claim validation.
It pins the algorithm and trusted JWKS source, rejects ambiguous signing keys,
checks issuer, client audience, authorized party, subject, time and nonce, and
checks `at_hash` when supplied. Refreshed ID tokens keep the same verified subject.
The implementation uses maintained OpenSSL primitives, not a custom signature
algorithm. The runtime gained the required four-byte-buffer dynamic FFI call
shape, preserving aliases and copyback.

Account/client records, active selection and the host ID are stored separately
with owner-only writes. A per-account cross-process transaction rereads the
record before refreshing and replaces the rotating token set together. Terminal
refresh errors clear unusable tokens; temporary service and client-configuration
errors preserve them. Sign-out retries remote revocation, clears only the chosen
account's tokens and reports when remote revocation was not confirmed.

Account changes publish their connection identity immediately. A delayed probe
cannot restore the prior account or its model list. Transport checks also refuse
a changed known account before inference when another host's catalog is stale.
The optional-catalog path still accepts a typed selection without known metadata.

The Models page now supports separate account selection, reconnection and
sign-out. A first-use plan notice is acknowledged per registration and retained
through reauthorization. The composer identifies ChatGPT plan use and links to
the documented usage-settings URL. Error recovery preserves HTTP status, code,
parameter, response shape and request ID while omitting provider diagnostic text.

Evidence:

- **52 native type/FFI checks passed**, including four buffers, aliases and copyback.
- **Three crypto cases passed**, using independently generated public fixtures:
  binary/base64url, real RSA signatures, and signed identity claims with invalid
  algorithm, signature, issuer, audience, subject, time, nonce and token bindings.
- Real subprocess/local HTTP tests pass for registration identity, declined or
  invalid consent, identity-only permissions, stable host IDs, separate same-email
  registrations, one refresh across two processes, terminal refresh errors,
  revocation retries and preserving another account.
- The provider fixture verifies exact public API parameters, completion buffering,
  credential isolation, model normalization and refusing the next account's call.
  Catalog tests cover both ready and rejected stale probes after an account switch.
- Protected account routes and CLI/model routes pass against the real local host.
  Compiled browser fixtures cover account controls, first-use acknowledgement,
  branding markers, usage links and the unchanged current-session send contract.
- Chrome acceptance with `model_accounts_browser.gene` verified the first-use
  dialog, focus/Tab behavior, switching registrations, signing out only one and
  returning without repeating an acknowledged notice. The fixture had no refresh
  tokens and removed all vendor providers before activation. Its temporary tab
  and host were closed after verification.

Normal supervised hosts now use the packaged application so its declared native
verification resource is selected. Offline, scripted and recovery hosts keep the
captured-source entry. A complete application build passed on macOS arm64 with
OpenSSL 3.6.1. This host's default macOS 27 SDK failed in the linker; the installed
26.5 SDK worked. Linux runtime qualification remains unverified.

The full Harness regression baseline passed **762 tests**, with no failures,
errors or skips. That run began before the nested-error correction and Codex
retirement. After those changes, **54 affected tests passed** on the updated
workspace, including provider preparation, model discovery, shared configuration,
media, round identity and compiled browser contracts. The event catalog check
and `git diff --check` also pass. The final approved per-adapter calls are recorded
below; wider budget calibration remains a follow-up.

The optional numeric `earliest_refresh_at` hint is interpreted as Unix seconds.
The real authorization returned an integer
near the current Unix time and before token expiry, consistent with that
interpretation; unfamiliar formats remain opaque.

The normal launcher also passed a real local prepare/cancel check: the native
verifier loaded, ChatGPT authorization was prepared for the official endpoint,
and the attempt was cancelled without an OpenAI request or permission grant.
The manager test's old assertion that `web --root` is invalid was obsolete; that
flag now selects the shared models root. Its replacement verifies a direct
reopen with `--root` while preserving the saved manager role and passes in 16.6 s.

The response review added a final-phase check: commentary is never executable,
and replayed assistant answers carry `phase: final_answer`. The focused
model-call/adapter suite passed **21 cases** after this change. Endpoint URLs
also reject embedded credentials, query and fragment without echoing values;
the affected schema, shared-save and adapter suite passed **eight cases**.

The owner completed ChatGPT consent manually. The protected account endpoint
reports one active, ready account with plan permission, and authenticated model
discovery returns ten choices. The live credential directories have mode 0700
and the account record has mode 0600. Token values were not printed.

The approved minimal Harness round failed before any output was executed. One
diagnostic retry with the documented minimal Responses body returned HTTP 200,
then an `error` event and `response.failed`, both with
`subscription_sharing_usage_limit_exceeded`. There was no `response.completed`.
Further live requests stopped and credentials are preserved. The documented
retirement prerequisite was a successful real sign-in; that is now verified.
The former Codex `backend-api` transport, credential reader and CLI discovery
have been removed, with no compatibility route. Successful first-party inference
has not been demonstrated: the plan-usage limit remains an observed account
limitation. The design requires a successful real sign-in before retirement;
it does not make that retirement depend on a completed inference.

The existing verification workspace was restarted after retirement. Its protected
catalog contains `chatgpt` and no `codex`; the saved active account and connection
both remain ready, with plan permission. This check made no inference request.

The initial SSE error wraps its code in an `error` object. The decoder now reads
both nested and flat envelopes, preserving the actionable code and safe metadata
without retaining arbitrary provider text. The focused decoder and round-identity
group passed **14 cases** in the workspace. The two direct round cases prove that
billing/account changes stop before another request, while replacement code and
a rotated token from the same source retain the existing round identity.
These cases are included in the final 54-test affected group above.

OpenRouter's live adapter is verified as described below. The final generic Chat
and Responses checks also completed, while the owner skipped further native
Messages checks. No live evidence is inferred from synthetic normalization samples.

Primary references: [registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[account and refresh rules](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions),
[inference contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
[error recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery),
and [UI guidance](https://developers.openai.com/siwc/ui-ux-guidelines).

Hermetic checks use `GENE_USER_PACKAGES=/tmp/gene-harness-models-packages` and
`GENE_ARTIFACT_STORE=/tmp/gene-harness-models-artifacts`. HTTP fixtures require
loopback socket access. The checked-in budget probe requires `--live`; other live
inference checks require operator authorization.

## OpenRouter live verification (2026-10-31)

The owner supplied an existing secret file and requested a working OpenRouter
connection. The key was imported into Harness's protected default credential
record and the running verification host's record. Credential files have mode
0600, and the provider directory has mode 0700. No key value was printed or
written into the repository.

Authenticated `GET /api/v1/key` returned 200. The running host reports OpenRouter
ready with API billing and an account-specific model catalog. One actual Harness
round using `openai/gpt-6-sol`, effort `none`, and a temporary 128-token output
cap completed in one turn and displayed **READY**. The temporary cap was removed;
the normal catalog limit is restored. At the owner's request, the local default
and provider fallback now use `deepseek/deepseek-v4.1-flash-1017`, effort `auto`.
The old verification-session pin was cleared. This model switch made no
inference request.

An unauthenticated public model-list response was captured separately. Four
representative rows are checked in as
[`openrouter_models_20261031.json`](../../tests/fixtures/openrouter_models_20261031.json),
covering mandatory reasoning, optional efforts, missing effort metadata and no
reasoning object, plus limits and prices. None of the 456 public models in that
response had explicit null `supported_efforts`. The spec labels its injected-null
case as a synthetic mutation of the recorded row. The discovery, OpenRouter
response and sign-in-helper group passed **10 tests** with this fixture.

The sign-in audit found a [documented denial difference](https://openrouter.ai/docs/guides/overview/auth/oauth): OpenRouter does not
return its OAuth `state` parameter after access is declined. Harness now includes
its binding in the callback URL under `openrouter_state` as well. The host uses
that fallback only for OpenRouter, and the callback still rejects absent or
conflicting bindings. Five helper/exchange tests and the full owner-API model
client case pass with a denial that omits OAuth `state`. Existing credentials
remain unchanged and a replay cannot exchange a code after the denial. These
checks used local fixtures, with no paid inference requests.

The owner approved a $0.15 cap for four probes using only
`deepseek/deepseek-v4.1-flash-1017`. All four completed with HTTP 200 and
`finish_reason: stop`, using the advertised efforts `none`, `low`, `high` and
`max`. OpenRouter reported **$0.000190145 total**. Each request used provider price
ceilings; there were no retries or model substitutions. Response text was neither
executed nor retained. The [recorded metrics](deepseek-budget-observations-20261031.json)
contain no credentials or account identifiers.

| Effort | Output limit | Input tokens | Output tokens | Reasoning tokens | Reported cost (USD) | Elapsed (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| none | 4,096 | 55 | 523 | 0 | 0.000084005 | 9,527 |
| low | 8,192 | 80 | 187 | 175 | 0.000036130 | 3,678 |
| high | 32,768 | 80 | 210 | 198 | 0.000039580 | 4,115 |
| max | 128,000 | 80 | 149 | 137 | 0.000030430 | 4,058 |

Each effort received the same short arithmetic question. This verifies the
OpenRouter effort/budget fields and completion handling on the selected model;
it does not establish production budgets for substantial code-generation turns
or other providers. The budget values therefore remain provisional. This batch
is complete and its ledger prevents replay; further paid calls are outside the
four-request batch recorded here.

A read-only scan of the existing [spreadsheet experiment](spreadsheet-experiment.md)
also recovered actual coding-workload usage without making model calls. The
[aggregate record](recorded-coding-token-observations-20261031.json) retains only
usage metadata and checkpoint provenance. It contains 68 successful coding turns
and two successful history summaries, all recorded with `gpt-6.1-sol` at high
effort on the retired Codex route. Two failed calls are excluded.

| Historical workload | Samples | P95 output tokens | Maximum output tokens |
| --- | ---: | ---: | ---: |
| Coding turns | 68 | 3,312 | 4,211 |
| History summaries | 2 | 5,694 | 5,694 |

These real responses exceeded the former 3,000-token budget. They provide useful
workload evidence for retaining output headroom, but a historical model at one
effort cannot establish the selected DeepSeek model's production budgets at every
effort or validate other API adapters. The remaining calibration stays explicit.

The measured 5,694-token summary peak also exceeded the initial 4,096-token
minimum default. The minimum for `none` and `minimal` is now 8,192, matching `low`.
Explicit call budgets and lower per-model caps still take precedence. A regression
uses the recorded peak to check the default reserve and both kinds of cap. The
earlier probe table retains its actual 4,096-token limit for the `none` request;
that completed measurement is not rewritten to match the later policy change.
Nine payload tests and three local adapter/probe tests pass after the change.
The verification host was restarted, and its immutable loaded source contains
the new minimum while its selected model remains DeepSeek with Auto effort.
No additional inference requests were made for this correction.

## Native Anthropic Console discovery (2026-10-31)

The installed `ant` CLI reported an active Console OAuth profile and workspace,
but its active-profile line included parenthesized selection provenance. The
strict identifier parser rejected that annotation and incorrectly reported
`sign_in_required`. The parser now accepts the annotated form while retaining
only the validated profile identifier. Arbitrary trailing text and malformed
identifiers remain rejected; diagnostic suffixes and tokens are not retained.

Five credential-routing unit cases pass, and the combined Anthropic
preparation/cache/routing group passes **11 tests**. The corrected native
connection probe is ready and not stale. A separate native Harness host then
verified the [actual catalog](anthropic-console-discovery-20261031.json):
14 models with context/output limits, 12 with effort metadata, and 14 supporting
image input. This used the documented `ant` token-export boundary and read-only
Models API. No credentials were printed or copied into this repository.

The temporary host was stopped successfully. No Messages inference was sent;
native Anthropic inference qualification remains separate from this discovery
check. The main verification host's selected model remains DeepSeek.

The owner approved the native Haiku 5.5 Messages check with a $0.01 cap inside
the same $0.15 overall budget. The initial 128-output-token request was rejected
with HTTP 400. Its probe discarded the diagnostic detail, so one controlled
diagnostic repeat captured the safe error category: insufficient Console API
credits, with `invalid_request_error`. No complete inference or token usage was
returned. The [recorded rejection](anthropic-message-check-20261031.json) preserves
the attempt counts and budget scope without credentials, account IDs or raw
provider text. The two attempts' conservative combined token-cost bound is below
$0.001; actual native charges were not reported and are not asserted.

Native authentication and model discovery remain valid. Further native requests
stopped after the credit rejection; the owner later skipped further native checks.
The adapter
now reports an explicit credit-related recovery message instead of generic HTTP
400, preserves the safe error type/request ID, and omits arbitrary diagnostics.
Fifteen payload/auth unit cases and three local protocol/cache integration cases
pass. Native Messages inference remains unqualified; rejection is not counted as
a successful adapter check.

The checked-in budget probe now emits whitelisted failure metadata: HTTP status,
safe error code, request ID and a fixed failure category. It still omits raw
provider diagnostics and stops after one failed attempt. A local credit-rejection
fixture verifies those fields, redaction and the absence of an automatic retry;
the probe/payload group passes **11 tests**.

The owner subsequently requested skipping further native Console API checks and
using their Anthropic subscription. Native Messages qualification is therefore
recorded as skipped by the owner, not passed or awaiting another funded attempt.

## Claude Code subscription route (2026-10-31)

The installed, unmodified Claude Code reports a first-party `claude.ai` login with
a Pro subscription. This is the [documented end-user CLI route](https://code.claude.com/docs/en/legal-and-compliance);
Harness does not read, export or reuse Claude Code's session tokens for API calls.
The existing CLI provider disables CLI tools, hooks and MCP for these requests.

A small protocol probe returned READY through the signed-in CLI. The local
verification host was then relaunched with the actual Claude Code executable,
and its shared default set to `claude` / `sonnet` / `auto`. An actual Harness
round using that current default completed in one turn and displayed READY,
with its resolved billing recorded as `plan`. The [sanitized verification](claude-subscription-check-20261031.json)
contains no credentials or account identifiers. OpenRouter retains the owner's
DeepSeek fallback. This CLI bridge remains text-only with a 128 KiB prompt limit;
normal subscription usage limits apply.

## Current full regression (2026-10-31)

The current full hermetic run completed with **765 passed, one failed, zero
errors and zero skips**. The failure was the isolated example “preserves progress
revision and Slack timestamp across asymmetric pruning and reopening,” which
hit its existing 120-second process deadline. It reported no assertion failure.
The unchanged example passed a focused rerun in **25,719 ms**. Its channel-review
file and imported specs then passed **43 tests**, with zero failures, errors or
skips; the original example completed in **25,955 ms** in that run. The timeout
was not reproduced, and no production fix is inferred. The original full-run
timeout remains in the [recorded results](models-regression-20261031.json);
neither its deadline nor its assertions changed.

The run cleared provider API-key variables and used private auth/model roots
and fake vendor executables. No paid inference occurred. The event catalog check
and whitespace check pass. The final generic Chat and Responses live checks are
recorded below.

## Final generic adapter checks (2026-10-31)

After explicit approval, the prepared `openai_chat` and `openai_responses`
checks both returned READY through the actual endpoint-provider constructors,
configuration, preparation and send functions. Both used only
`deepseek/deepseek-v4.1-flash-1017` on OpenRouter, with effort `none`, a 128-token
output limit, required parameter support and provider price ceilings. Responses
streamed through the completed-response decoder. Model output was never executed.

Each request used 19 input and three output tokens. OpenRouter reported
**$0.000001988 combined**, within the $0.0013824 batch ceiling and the existing
$0.15 total cap. There were no retries or substitutions. The
[sanitized results](openai-protocol-checks-20261031.json) qualify the generic
protocol paths against a compatible endpoint, without claiming native
OpenAI-vendor qualification. These finish the remaining unwaived adapter checks.
