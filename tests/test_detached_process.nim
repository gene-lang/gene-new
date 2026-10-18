## Detached children outlive a real launcher process, including its native
## captured-process shutdown hooks. All children have a finite fixture lifetime.
import std/[json, monotimes, options, os, posix, streams, strutils, tempfiles, times, unittest]
import gene/[process_launch, process_lock]

if paramCount() > 0 and paramStr(1) == "child":
  let directory = paramStr(2)
  let state = %*{"pid": getCurrentProcessId(), "session": int(getsid(0)),
    "directory": getCurrentDir(), "env": getEnv("GENE_DETACHED_VALUE"),
    "arguments": commandLineParams()[2 .. ^1], "stdin_eof": stdin.endOfFile()}
  stdout.writeLine("stdout")
  stdout.flushFile()
  stderr.writeLine("stderr")
  stderr.flushFile()
  writeFile(directory / "ready", $state)
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not fileExists(directory / "release") and getMonoTime() < deadline: sleep(10)
  writeFile(directory / "done", "done")
  quit(0)

if paramCount() > 0 and paramStr(1) == "launcher":
  let directory = paramStr(2)
  let pid = launchDetached("./fixture", ["child", directory, "", "two words", "a | b"],
    directory, some(@["PATH=.", "GENE_DETACHED_VALUE=literal $HOME"]), "output.log")
  echo pid
  quit(0)

proc waitFile(path: string) =
  let deadline = getMonoTime() + initDuration(seconds = 6)
  while not fileExists(path) and getMonoTime() < deadline: sleep(10)
  doAssert fileExists(path), "fixture did not write " & path

suite "detached process launch":
  test "survives launcher exit with a new session, EOF and independent output":
    let directory = createTempDir("gene-detached-", "")
    createSymlink(getAppFilename(), directory / "fixture")
    defer:
      writeFile(directory / "release", "")
      waitFile(directory / "done")
      removeDir(directory)
    let launcher = launchProcess(getAppFilename(), ["launcher", directory], ownGroup = true)
    launcher.closeInput()
    let pid = parseInt(launcher.outputStream.readAll().strip())
    check launcher.waitForExit() == 0
    launcher.close()
    waitFile(directory / "ready")
    let state = parseFile(directory / "ready")
    check state["pid"].getInt == pid
    check state["session"].getInt == pid
    check state["directory"].getStr == expandFilename(directory)
    check state["env"].getStr == "literal $HOME"
    check state["arguments"] == %*["", "two words", "a | b"]
    check state["stdin_eof"].getBool
    check processAlive(pid)
    check readFile(directory / "output.log") == "stdout\nstderr\n"
    check getFilePermissions(directory / "output.log") == {fpUserRead, fpUserWrite}

  test "reports executable, output and directory failures before returning a PID":
    let directory = createTempDir("gene-detached-errors-", "")
    defer: removeDir(directory)
    expect OSError:
      discard launchDetached("gene-not-an-executable-8214", output = directory / "output")
    expect OSError:
      discard launchDetached(getAppFilename(), output = directory / "missing" / "output")
    expect OSError:
      discard launchDetached(getAppFilename(), directory = directory / "missing",
                             output = directory / "output")
    writeFile(directory / "no-shebang", "exit 0\n")
    setFilePermissions(directory / "no-shebang", {fpUserRead, fpUserWrite, fpUserExec})
    expect OSError:
      discard launchDetached(directory / "no-shebang", output = directory / "output")
    check processAlive(getCurrentProcessId())
    check not processAlive(0)
