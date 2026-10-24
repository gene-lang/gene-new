import gene/web_backend
import std/[os, osproc, tempfiles, unittest]

suite "web speech boundaries":
  test "emitted bindings preserve asynchronous capture and playback lifecycle":
    let output = createTempDir("gene-web-speech-", "")
    defer: removeDir(output)
    discard buildWebModule("tests/fixtures/web_speech.gene", output)
    let result = execCmdEx("node tests/web_speech.mjs " &
      quoteShell(output / "web_speech.mjs"))
    checkpoint result.output
    check result.exitCode == 0

    let pcm = execCmdEx("node tests/web_audio.mjs " &
      quoteShell(output / "web_speech.mjs"))
    checkpoint pcm.output
    check pcm.exitCode == 0

  test "the plugin controller and host client compile against the real boundary":
    let output = createTempDir("gene-voice-client-", "")
    defer: removeDir(output)
    discard buildWebModule("examples/gene-harness/client/plugins/voice.gene", output)
    discard buildWebModule("examples/gene-harness/client/main.gene", output)
    let result = execCmdEx("node examples/gene-harness/tests/voice_client.mjs " &
      quoteShell(output / "voice.mjs") & " " & quoteShell(output / "round_client.mjs"))
    checkpoint result.output
    check result.exitCode == 0
    let host = execCmdEx("node examples/gene-harness/tests/host_audio.mjs " &
      quoteShell(output / "host_audio.mjs"))
    checkpoint host.output
    check host.exitCode == 0
