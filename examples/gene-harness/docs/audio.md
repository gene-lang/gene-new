# Voice

The built-in `voice` plugin adds the Voice toolbar button. Enable it for a
conversation, then hold the microphone button or focus it and hold Space.
Release to send. Escape cancels a capture. Voice remains pinned to that
conversation when you navigate elsewhere in the page.

Voice settings can switch to click-to-start/stop, review recognized text before
sending, turn spoken replies or progress replies off, and choose browser or
configured host engines independently. Preferences and unsent voice drafts stay
in this tab's session storage. Reloading leaves voice off and history silent.
The microphone is requested at the first recording gesture, or when explicitly
selecting hands-free mode. Voice is off after a reload.

**Hands-free** requires a configured host recognizer. It starts after sustained
speech and finishes after 600 ms of silence. The default **Half duplex** pauses
recognition while replies play and for a short playback tail. Hold the microphone
button or Space to interrupt. **Headphones** enables interruption by voice;
select it when playback cannot feed back into the microphone. Physical acoustic
echo cancellation has not been qualified. Escape cancels the current utterance.

Spoken prompts are literal requests, including text beginning with `/`. They
send neither typed composer text nor attachments. While a conversation is busy
or waiting for answers, recognized text stays in a separate queued voice draft.
Further captures append in capture order. A definite refusal leaves an unsent
draft for inspection; an uncertain HTTP result keeps its original request
identity in the host's **Resolve voice submission** controls. Disabling the
plugin does not remove those recovery controls. Refused drafts stay held for
review after reloading. If the browser service ends before you release the
button, its recognized text also stays for review.

Live progress and final replies enter a speech queue. **Spoken** reveals the
plain text; **Replay speech** explicitly plays a historical reply. Starting a
capture interrupts speech. The host-wide claim lets the most recently enabled
page own the speaker. The event stream and the audio stream are separate.

## Privacy

The browser recognition service may send microphone audio to its vendor and may
require a network connection. Browser API availability does not guarantee that
permission, the language, or the service works. Typed input remains available.

Harness host engines receive audio or text only when selected. The Harness
keeps microphone PCM and synthesized PCM in bounded memory; neither is an event
or a media attachment. Recognized prompt text, input metadata and optional
`audio_reply` text are durable. Timing summaries are ignorable trace events.
The recovery UI mounts no Voice browser contribution.

## Host engines

Engine selection is profile `voice`, then `GENE_HARNESS_RECOGNIZER` /
`GENE_HARNESS_SYNTHESIZER`, then the workspace's `.gene-harness/config.gene`
`voice` map, then the available row with the lowest `auto` rank. Cloud synthesis
has no automatic rank and requires an explicit selection. Credentials stay in
the host environment.

Add a voice map to the existing configuration using its normal Gene data
encoding (do not replace the serialized configuration with a bare map):

```gene
^voice {^recognizer "whisper_local" ^synthesizer "piper"
        ^language "en" ^rate 1.0}
```

`GET /api/v8/voice/status`, using the normal browser authentication, reports
engine selections and availability reasons. Select **Configured host engine**
in Voice settings to use those choices. Missing models or services produce a
notice and preserve typed input.

- **whisper_local:** set `GENE_WHISPER_URL` to a warm loopback server's
  `/inference` endpoint, for example `http://127.0.0.1:52649/inference`. Start
  whisper.cpp with its model already loaded. Do not enable its ffmpeg
  conversion option: the adapter sends a WAV in memory, and the server's
  conversion option writes a temporary file. The adapter uses multipart HTTP
  and a reused HTTP client. See the [official server implementation](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/server.cpp).
- **piper:** install `piper-tts` in a Python environment, download a voice,
  then set `GENE_PIPER_PYTHON` to that environment's Python and
  `GENE_PIPER_MODEL` to the `.onnx` file. One helper loads the voice and exchanges
  framed PCM with Gene; it does not launch a new model per sentence. The small
  Python file is the [Piper SDK](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/API_PYTHON.md)
  boundary. Lifecycle, segmentation, queueing, caching and pacing remain Gene.
- **macos:** run `gene run examples/gene-harness/src/audio/build_mac.gene` from
  the repository root and set `GENE_MAC_SPEECH_HELPER` to the printed path.
  Requires macOS 26+ and its Swift SDK. `GENE_MAC_SPEECH_SDK` can select an SDK.
  Synthesis uses AVSpeechSynthesizer buffer callbacks; the streaming recognizer
  uses SpeechAnalyzer. Recognizer assets must already be installed; the helper's
  explicit `--install LANGUAGE` command installs them. See [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
  and [speech buffer output](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)).
- **elevenlabs:** explicitly select this synthesizer and set
  `ELEVENLABS_API_KEY` plus `ELEVENLABS_VOICE_ID` (or `voice/voice` in config).
  The adapter requests streaming `pcm_24000` over HTTPS and consumes bytes
  through the owned HTTP client. See the [official streaming API](https://elevenlabs.io/docs/api-reference/text-to-speech/stream).

## Verification status

See [implementation and verification](audio-implementation.md) and the
[browser benchmark](audio-benchmarks.md). Availability or a passing fixture is
not a claim that microphone/echo behavior is qualified on physical hardware.

`probes/audio_engines.gene` runs an opt-in real-engine smoke test and prints
timings while keeping synthesized audio in memory. It accepts `piper`, `macos`,
`macos_stt PATH_TO_16KHZ_MONO_FIXTURE_WAV`, or
`whisper_local PATH_TO_16KHZ_MONO_FIXTURE_WAV`.

## Engine plugins

Plugins contribute `speech_recognizers` and `speech_synthesizers` rows through
`PluginHost:contribute`. Each row supplies `name`, `available`, `open` and
`close`, plus `transcribe` for segmented recognition, `stream` for streaming
recognition, or `synthesize` and a mono s16le `format` for synthesis. Built-in
adapters are examples of the callback signatures. `auto` is optional; leave it
absent for an engine that needs explicit selection.

The kernel owns resources returned by `open` and closes them on activation
retirement, even when an invocation loses its result. The speech service also
closes them on shutdown or selection changes. Keep `close` safe for a resource
whose operation failed partway through. Engines should return actionable
availability reasons and keep persistent readers outside bounded `open` calls;
the service starts a returned `dispatch_message`/`dispatch_error` pair for a
framed worker. Generic PCM/WAV and framed worker I/O live in `genex/audio`.
