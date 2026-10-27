# Audio benchmarks

Measured on the development Mac, 2026-10-24, at implementation `6d86c973`.
These are local fixture results,
not claims about remote services, other machines or physical speaker latency.

## Browser path

Chrome for Testing 156.0.8078.47 captured a known public speech WAV through its
fake microphone. Normal capture processing was enabled, and the actual capture
worklet, authenticated voice socket, warm whisper.cpp recognizer, host admission,
scripted model, warm Piper synthesizer and playback worklet ran end to end.
Every voice request was paired with the same recognized text submitted as typed
input. Output was muted; its first-rendered-sample callback still ran.

The 20-pair run completed all 40 rounds:

| Measurement | Samples | p50 | p95 |
| --- | ---: | ---: | ---: |
| Release → round admitted | 20 | 55 ms | 64 ms |
| Reply received → first rendered sample | 40 | 68 ms | 79 ms |
| Admission start → reply received, voice | 20 | 113 ms | 123 ms |
| Admission start → reply received, typed | 20 | 109 ms | 113 ms |
| Paired added round time | 20 | 17 ms | 30 ms |

The first output sample took 123 ms; the table includes that cold request.
Pair differences include scheduling and admission/event delivery noise. They
do not establish precisely zero turn-loop overhead. Raw samples and correlated
identities are in `tmp/harness-audio-api-full-final/audio-bench-results.json`.

Two-pair smoke runs also exercised macOS streaming recognition (input 96/179 ms)
and hands-free VAD (release-to-admission 43/45 ms). Those small samples are smoke
checks, not useful percentile estimates. Hands-free additionally waits for the
600 ms silence detector; release-to-admission excludes that wait. Per-utterance
traces include the estimated end-of-speech point so it can be examined separately.

## Reproduce

Set the normal engine environment from [audio.md](../audio.md), with a warm
whisper.cpp `/inference` server and Piper model. From `examples/gene-harness`:

```sh
../../bin/gene run --snapshot probes/audio_bench.gene \
  /absolute/path/to/a/new/disposable/workspace \
  /absolute/path/to/chrome \
  /absolute/path/to/16khz-mono-fixture.wav full whisper_local
```

The Gene driver launches a separate host and disposable headless Chrome profile,
waits for completion, writes a JSON report and stops both. `processed` runs two
pairs, `smoke` uses raw unprocessed capture, `handsfree` exercises VAD (give it a
fixture with trailing silence), and `macos` selects SpeechAnalyzer recognition.
The fixture calls compiled library APIs; ordinary UI checks are separate.

On macOS, Chrome's sandboxed audio utility may be unable to read the supplied
WAV. The test-only `GENE_AUDIO_BENCH_FILE_ACCESS=1` opt-in adds
`--disable-features=AudioServiceSandbox` to this disposable fixture browser.
It leaves browser/renderer sandboxes enabled and changes no ordinary profile.
The benchmark used this opt-in. See Chromium's [fake audio switches](https://chromium.googlesource.com/chromium/src/+/HEAD/media/base/media_switches.cc)
for the fake-file and `%noloop` behavior.

## Adapter checks

- Piper 1.8.0/`en_US-lessac-medium`: model open 1,013 ms; first PCM 151 ms,
  then 31 ms with the same loaded voice.
- AVSpeechSynthesizer helper: open 11 ms; first PCM 593 ms, then 89 ms.
- whisper.cpp revision `231638a0717b7822784297e5980965ffcec05810`, Metal,
  `tiny.en`: client open 10 ms, 11-second public JFK fixture transcribed in
  614 ms; a three-second excerpt took 79 ms.
- SpeechAnalyzer: the macOS 26.5 helper compiled and, after explicit English
  asset installation, transcribed the 11-second fixture with real-time input
  pacing in 11,736 ms total. This total includes speech duration.

These adapter samples are separate from the paired browser measurements.
Live ElevenLabs credentials and physical acoustic echo tests were not used.
The paired fixture uses short replies. Prefetch contention, cancellation and
player retirement are covered by the subsequent deterministic regression suite;
the table above is not a measurement of those cases.

After the review fixes, a separate normal-processing Chrome smoke run completed
two pairs/four rounds with real whisper/Piper engines. Input samples were
37/50 ms and output samples ranged from 50 to 147 ms. Its report is in
`tmp/harness-audio-cr-fixes/audio-bench-results.json`; this small run does not
establish percentiles. Direct framed-helper probes also passed: Piper first PCM
67 ms then 27 ms warm, macOS 657 ms then 56 ms warm.
