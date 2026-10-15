# Harness computer use and uploaded media

Status: implemented and verified on macOS; see [verification evidence](harness-computer-media-verification.md).

User goal: implement computer use and image processing, including document and
image uploads in the Harness UI. The user clarified that image processing means
image understanding and screenshots only; image editing and generation are out
of scope.

## Completion requirements

- [x] Reusable Gene computer-driver adapter and a discoverable Harness plugin.
- [x] Browser and native-app observation/actions, scoped target ownership,
      timeouts, cleanup, and durable action outcomes without blind replay.
- [x] Real driver integration verified against an explicitly selected test
      surface; mocked tests alone are not completion evidence.
- [x] Images/screenshots become image content in model requests, not merely
      paths or base64 text. Provider capability failures are explicit.
- [x] Authenticated UI file picker, drag/drop and image paste; pending attachment
      previews, removal before sending, upload errors and bounded upload sizes.
- [x] Documents/images can accompany a message, including an attachment-only
      message; admitted attachments survive reconnect, replay and restart.
- [x] Uploaded documents produce usable model context. Initial supported types:
      PDF, DOCX and ordinary UTF-8 text/code documents. Scanned PDF page images
      must remain usable rather than silently producing empty text.
- [x] Uploaded images and computer screenshots have authenticated previews and
      downloads in the transcript; filenames never choose storage paths.
- [x] History/compaction and provider preparation preserve image/document
      references and do not duplicate large binary payloads into text history.
- [x] Automated storage, admission, provider, transport, driver and frontend
      regressions; actual browser upload and model-vision verification.
- [x] Documentation, dependency diagnostics, recovery instructions, and final
      requirement-by-requirement verification evidence.

## Architecture

Keep model output as Gene code and use existing plugin `functions` / `docs`
registries. Computer-use guidance is a discoverable document, with a concise
prompt orientation. The host owns driver lifetime and records action results.
Platform-specific transport belongs under `genex/computer`; reusable document
inspection/extraction belongs under `genex/documents` when needed.

Use a workspace media store outside the text-history blob collector. Immutable
binary objects have content digests; attachment records have opaque identities,
validated metadata and extraction/preview references. Public descriptors omit
host filesystem paths. Upload, round admission, transcript and model input all
refer to the same records. Retry identity includes the attachment list.

Keep message text compatible with existing history and add typed media parts.
Provider adapters turn these into their actual image/document representations;
text-only providers must not silently drop visual input. Extraction limits and
truncation are visible to the model and operator. The public Responses API
documentation is a schema reference, not proof that the existing Codex OAuth
transport accepts every public API feature; verify that transport separately.

Start with a published driver interface, not workspace-specific AppleScript.
Driver commands are argument arrays, not shell strings. Owned targets and
observations have explicit identities; action records distinguish successful,
failed and unknown effects. A plugin policy is not an OS sandbox: existing
general process authority remains a separate deployment boundary.

## Current-state findings

- Existing provider preparation is text-oriented; response attachments are
  generated source text, not user-uploaded binary assets.
- Harness already has durable round/command receipts, authenticated routes,
  same-origin/CSRF checks, plugin docs/discovery, and a content-addressed history
  store to build on.
- The browser compiler currently needs investigation for file/paste APIs;
  broadly useful missing bindings should be added as reusable host APIs.
- Existing unrelated edits in `src/gene/*.nim` must be preserved.
- The running Go workspace in `tmp/harness1011` must remain intact. Use separate
  workspaces for implementation tests and browser verification.

## References

- https://cua.ai/docs/cua-driver
- https://developers.openai.com/api/docs/guides/images-vision
- https://developers.openai.com/api/docs/guides/file-inputs

Read on 2026-10-11. Validation results will be recorded as implementation lands.

## Implementation checkpoint 1

Implemented and tested the binary media store, format inspection, strict UTF-8
decoding, native image content in three provider adapters, explicit unsupported
image errors in Claude CLI, attachment-aware round identity/history, and
authenticated upload/download routes. Image-only messages and text attachments
reach prepared model input and survive a session-service restart. These are
backend capabilities; the browser composer has not been connected yet.

Checks passed using the private build in `tmp/harness-computer-media/`:

- 4 media storage specs (reopen, exact binary data, quotas/deduplication,
  invalid input and integrity checks).
- 3 provider image-content specs, including actual provider preparation.
- 2 attachment model-input specs (retry identity, restart, text extraction and
  slash-command handling).
- 1 real local HTTP transport spec (authentication, CSRF, binary download,
  safe content disposition, malformed input and attachment-only admission).
- 12 native data-boundary tests, including 2 new UTF-8 decoding regressions.

Still required: browser file/paste/drop APIs and composer UI, transcript media
rendering, PDF/DOCX extraction and PDF page images, compaction preservation of
media references, media/screenshot model functions, the real computer driver
adapter/plugin and scope/lifetime handling, and full browser/live-vision
qualification. `media_input.gene` intentionally reports PDF/DOCX extraction as
unavailable until it is implemented; do not treat format detection as extraction.

The new `$binary/decode_utf8` API preserves the old raw `$binary/to_str` behavior.
It also rejects overlong, surrogate and out-of-range encodings accepted by Nim's
structural UTF-8 validator. The existing JSON decoder was not changed by this
work. The unrelated runtime optimization edits remain outside this goal's changes.

## Browser, documents and computer adapter checkpoint

The browser composer now supports file selection, drop and image paste, sequential
bounded uploads, previews/removal, per-conversation drafts, and attachment-only
submission. Ready drafts survive reload. New `$files/*` web bindings keep this
logic in Gene. Strict TypeScript checking exposed a Void callback emitter issue;
the emitter now produces a statement body for those callbacks without changing
Gene semantics. Real Chrome verification passed for image paste, reload, sending,
transcript display, draft isolation, removal, and process restart.

Codex OAuth / gpt-6.1-sol correctly identified a synthetic red square from the
uploaded image. A second live round discovered and invoked `media_show`, received
the stored image again, and answered correctly. Screenshot evidence is in
`tmp/harness-computer-media/media-skill-ui.jpg`. The file chooser automation still
requires the browser extension's “Allow access to file URLs” setting; the native
CUA fallback was unavailable. The file/paste/drop bindings and composer are also
covered by compiled-JavaScript runtime tests.

`genex/documents` now extracts PDF text and renders bounded page images with
Poppler, including PDFs without a text layer. It exposes individual-page access.
DOCX text extraction uses macOS textutil after ZIP CRC checking with unzip.
Both use argument arrays, process deadlines, bounded output and private scratch
directories. Extraction is cached; page pixels use the same media store as other
images. `media_list`, `media_show`, `media_import` and `media_page` are discoverable
Harness functions. A done reply is deferred when it has queued new media.
Compaction preserves deterministic, deduplicated attachment catalogs, independent
of summary prose, and budgets extracted text/images before provider preparation.

`genex/computer` and the baseline `computer` plugin implement explicit per-session
window grants, observation IDs, screenshot/AX reads, scoped click/type/key/scroll,
durable request identities and completed/failed/unknown action receipts. Native
windows include browser windows; a separate DOM/browser-target adapter is not
implemented. Cancellation leaves an unknown receipt and retires the CLI process;
repeating that request never dispatches again. `/computer close` and plugin
shutdown release driver sessions. The host attaches to an operator-started daemon
and does not stop a shared daemon. Driver responses still need live qualification.

The signed official Cua Driver 0.34.0 test bundle was downloaded, checksum-checked
and signature-verified. The user explicitly authorized starting it and operating
a disposable browser window. It is running on the dedicated test socket, but
macOS reports `permissions_pending`; the user has been asked to enable CuaDriver's
Accessibility and Screen Recording permissions. No real driver UI action has run.
This requirement remains open; mock tests do not complete it.

Additional checks passed: 3 document tests (including actual PDF/DOCX converters
and prepared model input), 1 repeated-compaction/restart test, 1 media-function
round/transcript test, 2 computer scope/replay/cancellation tests, 13 native data
tests, existing history (3), model-call (11), turn-evaluation (4) and harness-turn
(1) specs. Storage/provider/HTTP regressions also pass. Client compilation and
strict TypeScript checking pass; 118 browser host bindings match lib.dom.d.ts.

Language/tooling findings: scratch cleanup needed the reusable `$fs/remove_dir`
API, which removes only empty directories. Named application builds select native
package recipes, while raw `gene run path.gene` does not; importing archive from a
source-launched Harness therefore did not select its codec. Document conversion
uses platform tools directly and this broader source-run/native-resource gap
remains recorded rather than changing package semantics in this feature.

The subsequent audit fixed unused computer grants triggering unnecessary remote
cleanup. Only contacted driver sessions now need `end_session`, and repeated
close is a local no-op. `computer_receipt` reads a durable outcome by request ID
without requiring the original call arguments. Three driver regressions pass.
The media-function suite now also proves queued images survive a question pause,
host restart and answer resumption. Both media-function specs pass. Live driver
qualification still awaits the same macOS permission gate.

## Final live qualification

The user enabled both macOS permissions and restarted CuaDriver on its default
socket. Real testing found and fixed the CLI plain-JSON/separate-screenshot
contract, then added exact browser tab bindings because native Chromium capture
could omit page contents. Both native AX and typed browser actions now passed
against a disposable browser. The browser test typed GeneBot, clicked once,
verified count1 and replayed the receipt without another effect. Native Reload
reset the page and was verified through a fresh browser observation.

The live Harness model then used only computer_observe/computer_act to type
HarnessBot, click Add one once and verify the actual screenshot/count1. The
authenticated UI displayed those screenshots. A real file-input upload of a
text document and PNG showed Ready, sent both attachments and produced the
correct model answer,4172 red. Earlier paste and compiled drop tests cover the
other input routes. The test conversation's driver session was closed and the
temporary fixture server stopped; the user's daemon and Go workspace were left
intact. Detailed evidence and current platform limits are in the verification
report. Historical checkpoints above describe intermediate states, not current
blockers.
