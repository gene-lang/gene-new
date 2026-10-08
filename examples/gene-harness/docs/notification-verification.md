# Notification verification

Verification date: 2026-10-08. All acceptance and regression gates passed.

Completed checks: 167 Harness tests, 389 native VM tests, 19 native bound-call
tests, 20 Cordis tests, eight focused notification/client tests, and seven
input-mode tests. All reported zero failures. The browser build and whitespace
checks pass. Browser and live-model evidence is mapped below.

## Acceptance evidence

| Contract | Evidence |
| --- | --- |
| 1A.1, 1A.4 — independent feedback and confirmations | Browser: a simulated draft-storage failure and Copied appeared together; Confirm/Keep running remained. Reload restored the decision; Keep running handled it explicitly. |
| 1A.2–3 — original save context and recovery | Browser: dropped a panel save request, switched entity and conversation, then resolved. The original entity saved once; the new entity draft and selected conversation remained intact. |
| 1A.5–6 — reload, authentication and recovery UI | Browser: default-UI navigation restored an uncertain panel save and delivered its final receipt. Existing owner/authentication integration tests remain part of the full suite. |
| 1B.1, 1B.4 — lazy background answering | Browser: expanded a metadata-only background card and answered without changing the foreground composer draft. Collapsed cards did not request their transcripts. |
| 1B.2–3 — independent pending replies | Browser: two batches held distinct drafts and payloads after simulated transport failures. Reload resolved both original sessions; one did not erase the other's payload. Native question tests verify batch idempotency. |
| 1B.5–6 — workflow-owned lifetime | Browser: Clear messages left the question and Needs response indicator; Dismiss all and Cancel round handled their owning workflows. Closing/reopening preserved drafts. The round regression test rejects a late reply after cancellation. |
| 1B.7 — shared editor | Browser: changing the active-conversation form updated the center's corresponding field without replacing its editor. |
| 1B.8 — focus, announcements and narrow view | Browser: inspected at 390 × 844, used Escape to close and return focus, preserved a long draft, and kept focused Saved feedback visible beyond its six-second expiry. Dark-theme question fields measured 15.36:1 text contrast. Host tokens and polite status regions are used. |
| 1B.9 — default UI | Browser: host question controls and save recovery remained usable; plugin message detail was suppressed. |
| 1B.10–11 — invalidation and delayed responses | Browser: closed the background subscription, answered through CLI, and observed removal through session/list. Held an older snapshot response until after CLI resolution; releasing it did not restore the old question. Pure freshness tests also reject older generations/epochs. |
| 2.1–3 — ownership, keyed updates and acknowledgment | Inbox and publisher integration tests cover same keys from different sources, stable identities, cosmetic updates, meaningful resurfacing, old clears, monotonic opened watermark and restart. Browser verified cross-tab clear and undisturbed typing on arrival. |
| 2.4 — isolation and progress | Integration tests verify unchanged board data revision, dedicated delivery and no durable progress writes. Browser observed zero ui/render requests for a direct publication while a board draft remained unchanged. |
| 2.5 — frozen actions and recovery | Integration tests cover prompt context, function/command receipts, deduplication, cancellation, reference validation, replacement/disable refusal and storage failure. Browser opened an artifact, original command receipt and selected board entity. It also dropped a response after admission, cleared the message and recovered the original command; the counter stayed at one. Cosmetic updates preserved the focused button and expanded detail. |
| 2.6 — CLI and headless use | Transport test posts with no browser, lists/shows/acknowledges/clears via CLI, and checks a watch presenter emits one line for an unchanged publication. |
| 2.7 — progressive discovery | Live configured-model run discovered the notification chapters, authored and registered review_notifier, called its function and checked the inbox. The example contributes owned docs and concise metadata, with no initial-prompt manual. |

The live authoring run used an isolated workspace and a test edition revision.
It verified notification publication and discovery, not the existence or quality
of a real edition review. The reusable source is in
[the example directory](../examples/notifications/README.md).

## Reproduce the automated checks

From `examples/gene-harness`:

```sh
../../bin/gene test
../../bin/gene test tests/integration/notifications tests/unit/client
```

From the repository root:

```sh
bin/gene build --target web --out-dir tmp/notification-web examples/gene-harness/client/main.gene
nim c -r -d:release --path:src tests/test_bound_call.nim
nim c -r -d:release --path:src tests/test_vm.nim
```

Run the shared lifecycle checks from `examples/cordis` with `../../bin/gene test`.

The regression work exposed an inherited-budget REPL cleanup bug. Its native
test failed before the fix and passes afterward; prior declarations remain
usable after budget failure. Snapshot construction is skipped when no publisher
or session subscriber can receive it, avoiding unobservable background work.
The plugin lifecycle regression also exposed cancellation between invocation
admission and cleanup registration. Cordis now uses keyed admissions with
cleanup installed first; concurrent cancellation and REPL replacement tests
verify that retired instances can finish disposing.

OS delivery, sound, accounts/per-user routing and dynamic notification render
callbacks remain outside this contract.
