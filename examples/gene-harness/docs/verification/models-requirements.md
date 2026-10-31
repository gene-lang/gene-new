# Models requirement audit — 2026-10-31

Scope: the accepted `docs/models.md` design, including its seven accepted review
resolutions and the owner's decision to omit the preview/admission guard. This
audit does not redefine completion around the currently implemented subset.

`Verified` below means the named hermetic evidence exercises the invariant.
It does not claim a vendor inference or consent check. Real authorization is
reported separately below. The current full run finished with **765 passed,
one timed-out example, no errors and no skips**. The unchanged timed-out
channel-retention example passed its focused rerun in 25.7 seconds, then passed
again in the **43-test channel-review group**, which had no failures, errors or
skips. Its deadline and assertions are unchanged. The timeout was not reproduced;
no production fix is inferred. The earlier 762-test baseline
and 54-test follow-up retain their revision scopes in the implementation record.
The final two approved live protocol checks also completed successfully, as
recorded below. The accepted implementation scope is complete with the owner's
native Anthropic API waiver and the stated verification limits.

| Requirement | Current implementation/evidence | Audit result |
| --- | --- | --- |
| One inert manager-root file for models, endpoints, defaults and presets | `public/models_file.gene`; exact design example parsed in `unit/public/models_file_spec.gene` | Verified |
| Resolved `--root` propagated to managed hosts | workspace manager/settings and endpoint integration specs | Verified |
| Strict credentials and schema, no literal key fields | `models_file` validation, `provider.resolve_credential`; malformed and credential-command specs | Verified |
| Reject credential-bearing base URLs | URL-userinfo/query/fragment validation; eight affected cases pass | Verified |
| Cross-host lock and digest conflict | native file lock around read/check/write; two independent save processes, exactly one success | Verified |
| Broken data doesn't stop host or recovery | endpoint activation/recovery tests, entry-level errors; doctor has no models-file read | Verified for malformed data |
| Name conflicts don't abort startup | reserved provider validation and per-entry errors | Verified |
| Overrides beat discovery, which beats small fallback lists | catalog merge/ownership tests, hidden false and nested copies | Verified |
| File-defined rows publish through plugin lifecycle | endpoint publisher/watch integration under real turn leases | Verified |
| Optional catalog/picker; typed model still works | optional-catalog and endpoint-without-picker tests | Verified |
| Connection/models callbacks are outside the turn-selection path | cached selection readers; snapshot call-count and bounded worker tests | Verified |
| Five-second discovery, startup/manual/24h refresh, no inference probe | bounded callback/HTTP fixtures and catalog polling implementation | Verified hermetically |
| Probe result table: ready, missing credential, 401/403, 404/405, malformed/network failure, discover false | real localhost adapter/discovery fixtures | Verified |
| Cache is stale-aware, atomic, account/transport scoped and excludes credentials/account records | catalog cache tests and exact canonical field whitelist | Verified |
| Source change and older probe cannot overwrite current connection | expiry-generation and account-switch race tests | Verified |
| Existing Claude login uses unmodified binary only, text/128KiB limitations visible | real Pro login, direct CLI probe and full Sonnet Harness round returned READY with plan billing; no token export; limits displayed | Verified live |
| API key outranks ant Console OAuth; bearer export and metered label | routing tests plus real Console OAuth discovery; native check rejected for insufficient credits, then owner requested the CLI subscription route | Discovery verified live; further native inference skipped by owner |
| Codex discovery/keyring diagnosis in initial stage | implemented in the first stage, then removed with the legacy route after real ChatGPT sign-in succeeded | Superseded by first-party sign-in |
| OpenRouter key validated separately from its public list | real authenticated `/key` returned 200; the running backend reports ready with API billing | Verified live |
| OpenRouter null/mandatory/no-reasoning fields, limits and prices | recorded public fixture covers current real fields; explicit-null behavior uses a marked synthetic mutation because no captured model had null efforts | Verified with recorded data and explicit edge-case mutation |
| OpenRouter curated menu/current/search and prices | compiled picker fixture and standalone page | Verified |
| Saved-first precedence everywhere, host/profile pins, no silent fallback | selection tests and native CLI/HTTP model flow | Verified |
| Multiple ready connections require first default choice | compiled first-run picker test and browser acceptance | Verified |
| Session choice at accepted admission, no preview identity | session gate and refused/busy admission test; current-session/current-default race cases; browser asserts no expected_selection | Verified |
| Picker, /model, /effort, typed IDs and CLI send flags | native CLI/HTTP and compiled client contracts | Verified |
| Ordinary/card/voice/continue payloads retain explicit drafts | page-owned ModelDrafts, pending envelope and browser fixtures | Verified |
| Unknown typed IDs marked unverified; no entitlement claim | model-settings/CLI/picker checks | Verified |
| One resolved round selection for model, effort, context, images and compaction | multi-call round snapshot and model-call specs | Verified |
| Endpoint/credential-source changes stop before replacement call | actual endpoint replacement and deliberate/automatic continuation integration | Verified |
| Billing/account change stops an already running round | direct multi-call integration verifies only one request and a connection_changed failure for either change | Verified |
| Code replacement and rotating value within same source continue | direct three-call test observes old code/token1, new code/token1, new code/token2 with unchanged transport identity | Verified |
| Complete child metadata on model override | real delegated child has smaller window/output and text-only input; inherited requested effort resolves independently | Verified |
| Deliberate continuation can accept changed transport; automatic/restart cannot | continuation and recovery tests | Verified |
| Triggers use own fields/default and skip creating/continuing session pin | per-firing integration with continuing session, pin/edit/clear and plugin sync | Verified |
| Unknown fields/provider rejected, signed-out/unlisted accepted with warnings | trigger model schema and warning tests | Verified |
| One blocked occurrence doesn't stop healthy work/maintenance | trigger isolation and renewed keyed notification test | Verified |
| Trigger browser controls are independent of composer selection | compiled bridge/draft tests and Chrome acceptance | Verified |
| Portable effort ladder/defaults/round-down/native extras | table tests; unknown extras rejected; no-effort models omit parameters | Verified |
| Per-model thinking-off exceptions, including beyond fallback list | separate documented Anthropic exception table; nineteen affected cases pass | Verified hermetically; further native API checks skipped by owner |
| Per-model window/output/input data, optional workspace cap | resolver, child and image admission specs | Verified |
| Distinct Chat/OpenRouter/Responses/Messages effort and budget fields | pure payload table plus real localhost wire fixtures | Verified hermetically |
| Stream and buffer before evaluation; reject truncation/error/refusal/empty output | complete decoders, early/late error cases and HTTP fixtures | Verified hermetically |
| Preserve bytes/EOF and exclude commentary from executable output | public Responses raw-byte/phase cases and model-call regression | Verified |
| Derive output budgets from effort with actual measurements | four approved DeepSeek probes plus 68 historical coding turns and two summaries; measured 5,694-token peak informs the 8,192-token minimum, larger reserves grow with effective effort, and explicit/model caps are tested | Implemented with recorded measurements; sample limits and provisional higher-effort reserves are disclosed |
| OpenRouter PKCE and protected key record; env wins | local exchange/replay/cancel/lifetime/source-precedence tests plus denial without OAuth state through helper and owner-API routes | Verified with local exchange and denial checks; live inference uses the owner's supplied key, without claiming successful live OAuth consent |
| ChatGPT dynamic registration, loopback, state/nonce/PKCE and issued-client binding | local OAuth integration and retry/reconsent tests | Verified hermetically |
| Validate signature/issuer/audience/time/nonce and plan scopes | OpenSSL-backed crypto suite with signed negative fixtures; identity-only path blocks inference | Verified hermetically |
| Stable host ID and separate client/account records, 0600 and rotating refresh lock | independent-process host/refresh tests and separate-registration tests | Verified |
| Account selection, first-use plan acknowledgement, usage link and sign-out/revocation | browser DOM/Chrome checks and local revocation retry tests | Verified hermetically |
| Public Responses-only ChatGPT route with stream true/store false and no forbidden sampling/budget fields | native provider wire fixture and packaged prepare/cancel smoke | Verified hermetically |
| First-party sign-in succeeds in reality before relying on it | owner completed consent; protected API reports ready with plan permission; account-specific model discovery returns ten choices | Sign-in verified; inference gated by subscription_sharing_usage_limit_exceeded |
| Retire Codex backend-api without a compatibility shim after successful real sign-in | removed legacy transport, credential reader, CLI probes and reserved provider; baseline asserts no compatibility route; restarted existing workspace exposes chatgpt and no codex with saved account ready | Verified |
| Real inference per adapter | OpenRouter HTTP and Claude Code CLI completed live checks; approved openai_chat and openai_responses checks both returned READY using DeepSeek on OpenRouter; native Anthropic returned a credit-related HTTP 400 and was then skipped by owner | All unwaived adapter checks verified live; native Messages skipped by owner |
| Full hermetic suite and event catalog | current full run: 765 passed and one channel-retention timeout; unchanged case passed alone and in the 43-test affected-file group; event catalog current; core/crypto checks passed | Coverage verified across full run and focused reruns; original timeout disclosed in models-regression-20261031.json |

The final `openai_chat` and `openai_responses` checks were explicitly approved
and each returned READY using the selected DeepSeek model on OpenRouter. Their
reported combined cost was **$0.000001988**, below the prepared $0.0013824 ceiling
and within the existing $0.15 cap. Neither response was executed; there were no
retries or model substitutions. The [recorded results](openai-protocol-checks-20261031.json)
contain only protocol/usage metadata. The design defines these as adapters for
custom endpoints, including compatible servers. These results qualify that
protocol path, without claiming native OpenAI-vendor inference.

The approved minimal Harness round failed before output was executed. A single
diagnostic retry using the documented minimal Responses body identified the exact
code: `subscription_sharing_usage_limit_exceeded`. Both the initial nested
`error` event and the following `response.failed` carried that code. No completed
response was received. Further live requests were stopped; credentials are
preserved and no alternate billing route was used. The nested error decoder fix
and direct identity audit cases pass fourteen checks in the workspace, following
the same successful isolated staging run. Those cases are included in the final
54-test affected group. The 762-test regression baseline began before the decoder
correction and Codex retirement; its result is separate evidence.

The owner skipped further native Anthropic Console API checks; no positive
Messages qualification is claimed. Claude Code's Pro subscription route works
through a real Harness round. The ChatGPT account's inference limit remains an
observed limitation. Its successful sign-in satisfies the design's explicit
retirement prerequisite; a completed ChatGPT inference is not an additional
prerequisite in that design.

The four-request DeepSeek batch and historical coding observations provide
actual measurements for the implemented output policy. They do not establish
production budgets across all models and workloads. The design specifies
effort-dependent budgets with measurements, rather than universal per-model
production certification; wider calibration is follow-up work. All required
unwaived implementation and verification items have evidence above. No synthetic
result is treated as live evidence.
