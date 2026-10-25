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
    for fixture in ["first_submission", "history_start", "live_output", "conversation", "session_menu"]:
      let entry = if fixture == "first_submission": "main.mjs" elif fixture == "live_output": "live_output.mjs" elif fixture == "session_menu": "session_menu.mjs" else: "view.mjs"
      let browser = execCmdEx("node examples/gene-harness/tests/" & fixture & ".mjs " &
        quoteShell(output / entry))
      checkpoint browser.output
      check browser.exitCode == 0
