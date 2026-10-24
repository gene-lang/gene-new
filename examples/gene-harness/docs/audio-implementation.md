# Audio implementation and verification

Implemented from `tmp/harness-audio.md`, including review resolutions R1–R6.
The browser plugin, host engines and hands-free fallback are implemented.
Hardware acoustic qualification and live cloud service qualification remain
explicit limitations, described below.

## Delivered behavior

- Optional `audio_reply` is validated without spoiling a valid textual Outcome,
  survives every deferred completion and reaches durable replies and replay.
  Speech normalization, spoken-text disclosure and explicit replay are shared
  by browser and host synthesis.
- The optional Voice browser plugin supports hold, toggle, review and host
  hands-free modes. Drafts stay separate from the typed composer, pinned to
  their conversation, and commit in capture order. Cancellation, timeout and
  disposal fence late callbacks. An early browser recognition end or refused
  admission keeps the draft for explicit review.
- Core owns literal, attachment-free admission and immutable pending requests.
  Receipt lookup and draft cleanup survive plugin replacement. Unknown requests
  are never silently resubmitted with a fresh identity.
- Live progress/final speech uses FIFO order, deduplication and one bounded
  prefetch. History stays silent until replay. Waiting/failure announcements,
  autoplay errors, claim takeover and reconnect grace have explicit handling.
- An authenticated, origin-checked voice WebSocket carries framed binary PCM.
  Sequence validation, cancellation, per-peer receive serialization and
  consumed-byte playback credit prevent silent drops and unbounded buffering.
  Audio never enters durable event/media storage.
- Reusable capture/player worklets resample to 16 kHz mono s16le, flush a final
  capture frame, expose a level meter and first-sample/consumed-byte callbacks,
  and bound playback with jitter buffering and a barge-in fade.
- Speech registries select independent recognizers/synthesizers. Warm resources
  belong to their exact plugin activation through kernel-owned cleanup leases;
  third-party plugins need no deactivation bookkeeping. Bounded calls, warm
  reuse, segmentation, cancellation and a bounded PCM LRU run outside model
  turns and their composition leases.
- Adapters cover local whisper.cpp, Piper, ElevenLabs streaming PCM and macOS
  SpeechAnalyzer/AVSpeechSynthesizer. Configuration and missing installations
  produce availability reasons. Cloud synthesis requires explicit selection.
- Hands-free VAD uses sustained onset, 600 ms silence, preroll and a capture
  limit below 120 seconds. Default half duplex gates recognition during playback
  and for a 300 ms tail; hold/key capture can interrupt. Headphone mode permits
  voice barge-in. Browser TTS and earcons participate in the playback gate.
- Client and host exchange per-utterance timing summaries without audio. No
  outbound cloud recognizer was selected, so the conditional outbound WebSocket
  addition is unnecessary for these adapters.

## Verification

Completed on the development Mac, 2026-10-23/24:

- **38 native Gene tests** cover Outcome validation, normalization, claims and
  input metadata, WAV/PCM framing and credit, selection/cache/retirement cleanup,
  streaming HTTP ownership, overlapping recognition, VAD, literal admission,
  request-only guidance and browser plugin publication/recovery.
- **Compiled browser fixtures** pass for the real emitted Web Speech boundary,
  worklet DSP, Voice controller, host transport and round client. Cases include
  first-frame/finish races, late permission results, disposal, reconnect,
  session switching, out-of-order finals, durable refusal/recovery, immutable
  input, FIFO prefetch, barge-in and half-duplex playback tails.
- **3 native WebSocket regressions** pass, including 300 ordered frames through
  `ws_try_send`, byte-budget refusal and binary delivery after draining.
- **139 host bindings** pass the TypeScript 5.9.2 DOM oracle. Experimental
  SpeechRecognition is absent from that DOM library and is covered separately
  by its emitted-boundary fixture. The TypeScript transpile fixture suite passes.
- Existing first-submission and history/reply DOM fixtures passed against the
  expanded client. Generated event catalog verification and `git diff --check`
  pass. The release Gene runtime was rebuilt with the native bindings.
- Real Chrome UI inspection verified Voice settings, browser voice selection,
  host replay, progress/final FIFO and a scrollable panel clear of the composer.
  It caught and fixed settings rendering, composer overlap and stale reconnect
  notices. Screenshot: repository `tmp/harness-audio-ui.png`.
- Real local adapters passed: Piper 1.8.0/lessac-medium, whisper.cpp Metal/tiny.en
  and the compiled macOS 26.5 SDK helper. English SpeechAnalyzer assets were
  explicitly installed and streaming recognition exercised with paced PCM.
- Fake-WAV Chrome exercised normal capture processing, real local recognition,
  admission, scripted turns, the voice socket and PCM playback. **20 paired
  requests** completed; input p50/p95 **55/64 ms**, output **68/79 ms**, paired
  added time **17/30 ms**. Separate two-pair checks exercised hands-free VAD
  and macOS streaming recognition. See [method and results](audio-benchmarks.md).

## Practical limits

These measurements use a public speech fixture, fake microphone and muted
output. First-rendered-sample timing is not physical speaker latency. Browser
vendor recognition was tested at its API boundary; its remote service quality
and availability are outside the Harness's control. ElevenLabs has deterministic
streaming HTTP coverage; live credentials were not used.

Acoustic echo cancellation has not been measured with a physical microphone and
speaker. The default half-duplex fallback deliberately does not depend on it.
Full-duplex voice interruption requires the explicit headphone option; test the
specific hardware/browser combination before relying on acoustic cancellation.

No Gene syntax or language semantics changed. Shared native/web collection API
differences (`get`/path indexing and map `size`/`$size`) remain an ecosystem
consistency issue. Invalid raw UTF-8 must be decoded/validated before native
string trimming; optional audio validation now does that.
