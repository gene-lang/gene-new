import std/[monotimes, os, strutils, times, unittest]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import gene/terminal_session

  proc pumpUntilStopped(session: TerminalSession, timeoutMs = 3000) =
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while not session.stopped and getMonoTime() < deadline:
      discard session.pump()
      sleep(2)
    if not session.stopped:
      raise newException(IOError, "timed out waiting for terminal session")

  suite "embedded terminal — combined session":
    test "input, output, and exit advance one owned terminal state":
      let session = openTerminalSession(
        @["/bin/sh", "-c", "IFS= read -r line; printf 'reply:%s' \"$line\""],
        rows = 4, cols = 32,
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: session.close()

      session.sendText("hello\n")
      session.pumpUntilStopped()
      check "reply:hello" in session.captureText(1024).text
      check session.inputBytes >= 6
      check session.outputBytes > 0
      check session.exitStatus == 0

    test "plain-text capture walks the newest bounded tail":
      let session = openTerminalSession(
        @["/bin/sh", "-c",
          "i=0; while [ $i -lt 40 ]; do printf 'line-%02d\\r\\n' $i; i=$((i+1)); done"],
        rows = 3, cols = 16, scrollbackLines = 64,
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: session.close()

      session.pumpUntilStopped()
      let capture = session.captureText(80)
      check capture.text.len <= 80
      check capture.truncated
      check "line-39" in capture.text
      check "line-00" notin capture.text

    test "blank terminal rows do not inflate persisted text":
      let session = openTerminalSession(
        @["/bin/sh", "-c", "printf x"], rows = 20, cols = 80,
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: session.close()

      session.pumpUntilStopped()
      let capture = session.captureText(1024)
      check capture.text == "x"

    test "requested stop advances asynchronously through the pump":
      let session = openTerminalSession(
        @["/bin/sh", "-c",
          "trap '' HUP TERM; while :; do sleep 1; done"],
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: session.close()

      session.requestStop(graceMs = 10)
      check session.stopping
      check not session.stopped
      session.pumpUntilStopped()
      check not session.stopping
      check session.exitStatus != 0

    test "grid and scrollback limits reject hostile allocations":
      expect ValueError:
        discard openTerminalSession(@["/bin/true"], rows = 513, cols = 80)
      expect ValueError:
        discard openTerminalSession(@["/bin/true"], rows = 24, cols = 80,
                                    scrollbackLines = 10001)
