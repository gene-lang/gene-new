# Harness computer/media verification

Status: **verified on macOS with Cua Driver 0.34.0**. Scope is computer use, image understanding/screenshots,
and document/image uploads. Image generation/editing is excluded by the user.

Evidence below was checked against the worktree and test logs on 2026-10-11.
Logs and synthetic browser artifacts are under `tmp/harness-computer-media/`.

| Requirement | Evidence | Result |
| --- | --- | --- |
| Reusable adapter and discoverable computer skill | `src/genex/computer`, baseline `builtin/computer.gene`, `docs/computer.md`; plugin loads in Harness integration tests | Implemented |
| Browser/native observation and actions | `live-computer.log`: exact browser tab, type, click, screenshot and reread; `live-native.log`: native AX Reload click verified against the page reset | Verified with real driver |
| Target ownership, stale observations, no blind replay | `computer-tests.log`: five specs cover owner/ref isolation, screenshot coordinate scale, consumed observations, durable receipts and cancellation; real replay kept count at1 | Verified |
| Cleanup and bounded calls | argv,30-second/16MiB bounds; local-only grant and repeated-close tests; real adapter scripts close their sessions; Harness `/computer close` returned active:false | Verified |
| Real driver integration | Official0.34.0 checksum/signature verified; user enabled both permissions and restarted on default socket; real native/browser scripts and live Harness model completed | Verified |
| Native model image content | `provider-media-tests.log`: three provider tests; `media-input-tests.log`: two admission/restart tests; live Codex OAuth identifies synthetic red square | Verified |
| Upload UI and draft behavior | Compiled picker/drop/paste tests; real Chrome paste/drafts/reload/removal; real file-input selection uploaded notes.txt+red.png, showed Ready, then model answered4172 red | Verified; drop specifically covered by compiled browser-component tests |
| Authenticated upload/download and limits | `media-http-tests.log`: real loopback authentication, CSRF, exact binary response, MIME/disposition and admission; four storage specs | Verified |
| PDF, scanned PDF, DOCX and UTF-8 documents | `document-tests.log`: three specs use real Poppler/textutil/unzip, check page images, per-page rendering, prepared model input, caching, corruption, cleanup and UTF-8 truncation; text admission test | Verified on macOS; DOCX converter is currently macOS-only |
| Tool images reach model and transcript | Two media-function specs; live media_show; live computer model used computer_observe/act, received real screenshots, verified HarnessBot/count1, and rendered screenshot previews | Verified |
| Authenticated image previews | Live UI states in `final-upload-state.json` and `harness-ui-state.json`, screenshot `media-skill-ui.jpg`, exact-byte HTTP tests; same-origin media URLs from IDs | Verified for uploads and real computer screenshots |
| Compaction/reference retention | `media-history-tests.log`: repeated lossy summaries preserve catalog, deduplicate IDs and survive restart; original history suite passes | Verified |
| Regression coverage | History3, model-call11, turn-evaluation4, harness-turn1, native data13, browser binding/composer scripts, strict TypeScript check,118 host binding checks; gene-final release built and document smoke3 passed | Passing |
| Documentation and recovery | README guides and package docs cover dependencies, exact native/browser selection, foreground opt-in, snapshots, receipts and cleanup | Verified against actual driver behavior |

The live vision check used a synthetic64×64 red PNG named `clipboard.png`, with
no color clue in its filename. Codex returned “Red; square.” A second live round
discovered `media_show`, called it, received the image in the following model
request, and answered correctly. This proves the existing Codex OAuth transport's
image path; it does not establish another provider/model's visual accuracy.

The user enabled Accessibility and Screen Recording. No permission bypass was
used. Live tests exposed and fixed two real integration issues: the CLI returns
plain JSON with separately saved screenshots, and Chromium needs a browser tab
snapshot to capture page contents reliably. Browser grants now bind one exact
authorized tab, preserve semantic refs and apply the screenshot coordinate scale.

The full model loop in session `s-738891349e357675d6a1b543` used only Harness's
computer tools to type HarnessBot, click Add one once and verify count1. The
subsequent UI upload selected two real files and produced the correct marker and
image-color answer,4172 red. The earlier extension file-URL setting was not
needed for this separate, user-authorized Cua Driver browser profile.

Evidence includes `harness-computer-result.png`, `full-harness-verification.png` (cleanup),
`live-model-result.log`, `live-transcript.json`, `live-computer.log` and
`live-native.log`. The existing Go workspace in `tmp/harness1011` was untouched.
