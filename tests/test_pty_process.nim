import std/[monotimes, os, sequtils, strutils, times, unittest]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import std/posix
  import gene/pty_process

  proc collect(process: PtyProcess, timeoutMs = 3000): string =
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while getMonoTime() < deadline:
      let available = process.readAvailable()
      result.add available.data
      if process.pollExit():
        result.add process.readAvailable().data
        return
      sleep(5)
    raise newException(IOError, "timed out collecting PTY output")

  proc sendAll(process: PtyProcess, text: string) =
    var pending = text
    while pending.len > 0:
      let written = process.writeAvailable(pending)
      if written == 0:
        sleep(1)
      else:
        pending = pending[written .. ^1]

  proc foregroundJob(process: PtyProcess, timeoutMs = 2000): int =
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while getMonoTime() < deadline:
      let identity = process.identity()
      if identity.foregroundProcessGroupId != identity.processGroupId:
        return identity.foregroundProcessGroupId
      discard process.readAvailable()
      sleep(5)
    raise newException(IOError, "timed out waiting for foreground PTY job")

  suite "embedded terminal — PTY process":
    test "helper preserves argv, cwd, selected environment, and exit status":
      let workspace = getCurrentDir()
      let process = spawnPty(
        @["/bin/sh", "-c", "printf '%s|%s|%s' \"$PWD\" \"$MARK\" \"$TERM\""],
        cwd = workspace, rows = 12, cols = 34,
        environment = @["MARK=exact", "TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      check process.collect() == workspace & "|exact|xterm-256color"
      check process.exitStatus == 0

    test "PTY input reaches the child and output remains byte-oriented":
      let process = spawnPty(
        @["/bin/sh", "-c", "IFS= read -r line; printf 'got:%s' \"$line\""],
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      var pending = "hello terminal\n"
      while pending.len > 0:
        let written = process.writeAvailable(pending)
        if written == 0:
          sleep(1)
        else:
          pending = pending[written .. ^1]
      let output = process.collect()
      check "got:hello terminal" in output

    test "resize updates the controlling terminal and delivers SIGWINCH":
      let process = spawnPty(
        @["/bin/sh", "-c",
          "trap 'printf resized:; stty size; exit 0' WINCH; printf ready; while :; do sleep 1; done"],
        rows = 10, cols = 20,
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      var ready = ""
      let deadline = getMonoTime() + initDuration(seconds = 2)
      while "ready" notin ready and getMonoTime() < deadline:
        ready.add process.readAvailable().data
        sleep(5)
      check "ready" in ready
      process.resize(22, 71)
      let output = ready & process.collect()
      check "resized:22 71" in output.replace("\r", "").replace("\n", " ")

    test "helper creates one controlling session and foreground process group":
      let process = spawnPty(
        @["/bin/sh", "-c", "sleep 30"],
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      let identity = process.identity()
      check identity.sessionId == process.pid
      check identity.processGroupId == process.pid
      check identity.foregroundProcessGroupId == process.pid

    test "signals target an interactive shell's foreground job":
      let process = spawnPty(
        @["/bin/sh", "-i"],
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      process.sendAll("sleep 30\n")
      let foreground = process.foregroundJob()
      check foreground != process.pid
      process.signal(ptySignalNumber(ptySignalInt))
      let deadline = getMonoTime() + initDuration(seconds = 2)
      var alive = true
      while alive and getMonoTime() < deadline:
        alive = kill(Pid(foreground), 0) == 0
        if alive:
          sleep(5)
      check not alive
      check not process.pollExit()
      process.sendAll("exit 0\n")
      discard process.collect()
      check process.exitStatus == 0

    test "exec child inherits no helper descriptors":
      let process = spawnPty(
        @["/bin/sh", "-c",
          "for fd in 3 4 5 6 7 8 9; do [ -e /dev/fd/$fd ] && printf '%s ' $fd; done"],
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      check process.collect().strip() == ""

    test "stop terminates and reaps the whole foreground process group":
      let process = spawnPty(
        @["/bin/sh", "-c", "sleep 30 & printf '%s\n' $!; wait"],
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      var announced = ""
      let deadline = getMonoTime() + initDuration(seconds = 2)
      while '\n' notin announced and getMonoTime() < deadline:
        announced.add process.readAvailable().data
        sleep(2)
      let childPid = parseInt(announced.strip())
      process.stop(graceMs = 30)
      check process.exited
      check process.exitStatus != 0
      var childAlive = true
      let goneDeadline = getMonoTime() + initDuration(seconds = 2)
      while childAlive and getMonoTime() < goneDeadline:
        childAlive = kill(Pid(childPid), 0) == 0
        if childAlive:
          sleep(10)
      check not childAlive

    test "stop reaches an interactive shell and its separate foreground job":
      let process = spawnPty(
        @["/bin/sh", "-i"],
        environment = @["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
      defer: process.close()

      process.sendAll("sleep 30\n")
      let foreground = process.foregroundJob()
      process.stop(graceMs = 30)
      check process.exited
      check process.exitStatus != 0
      let deadline = getMonoTime() + initDuration(seconds = 2)
      var alive = true
      while alive and getMonoTime() < deadline:
        alive = kill(Pid(foreground), 0) == 0
        if alive:
          sleep(10)
      check not alive

    test "helper setup and exec failures are reported synchronously":
      expect IOError:
        discard spawnPty(@["/definitely/missing/gene-command"])

    test "default child environment strips agent credentials":
      let old = getEnv("OPENAI_AUTH_TOKEN")
      putEnv("OPENAI_AUTH_TOKEN", "do-not-inherit")
      defer:
        if old.len == 0:
          delEnv("OPENAI_AUTH_TOKEN")
        else:
          putEnv("OPENAI_AUTH_TOKEN", old)
      let environment = sanitizedTerminalEnvironment()
      check environment.allIt(not it.startsWith("OPENAI_AUTH_TOKEN="))
      check environment.anyIt(it == "TERM=xterm-256color")
