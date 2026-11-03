## Select an installed SDK the native C compiler/linker can use on macOS.
## This runs before native derivation planning, so SDKROOT is included in both
## compiler and system-library evidence and inherited by compiler subprocesses.
import std/[algorithm, os, strutils]
when defined(macosx):
  import std/[options, streams, tempfiles]
  import ./process_launch

type SdkLinkProbe* = proc (sdk: string): bool {.closure.}

proc sdkVersion(path: string): seq[int] =
  let name = extractFilename(path)
  if not name.startsWith("MacOSX") or not name.endsWith(".sdk"):
    return @[]
  let version = name[6 ..< name.len - 4]
  if version.len == 0: return @[]
  for part in version.split('.'):
    if part.len == 0 or not part.allCharsInSet({'0'..'9'}): return @[]
    try: result.add parseInt(part)
    except ValueError: return @[]

proc compatibleMacSdk*(explicitSdk, defaultSdk: string,
                       candidates: openArray[string], links: SdkLinkProbe): string =
  ## An explicit SDK is never changed or probed. An empty result means to keep
  ## the working toolchain default, or that no compatible fallback was found.
  if explicitSdk.len > 0: return explicitSdk
  if defaultSdk.len == 0 or links(defaultSdk): return ""
  var ordered: seq[tuple[version: seq[int], path: string]]
  for path in candidates:
    let version = sdkVersion(path)
    if version.len > 0: ordered.add (version, path)
  ordered.sort(proc(a, b: tuple[version: seq[int], path: string]): int =
    for i in 0 ..< max(a.version.len, b.version.len):
      let left = if i < a.version.len: a.version[i] else: 0
      let right = if i < b.version.len: b.version[i] else: 0
      result = cmp(right, left)
      if result != 0: return
    return cmp(a.path, b.path))
  for candidate in ordered:
    if candidate.path != defaultSdk and links(candidate.path):
      return candidate.path

when defined(macosx):
  proc probeStatus(executable: string, args: seq[string],
                   environment = none(seq[string])): tuple[status: int, output: string] =
    # Probe diagnostics stay off the terminal. A stuck compiler cannot stall
    # package planning indefinitely; only the real build reports its errors.
    let process = launchProcess(executable, args, environment = environment,
                                mergeStderr = true, ownGroup = true)
    try:
      result.status = process.waitForExit(5_000)
      if result.status == -1:
        process.killGroup()
        discard process.waitForExit()
      else:
        result.output = process.outputStream.readAll()
    finally:
      process.close()

proc ensureCompatibleMacSdk*(compiler: string) =
  when defined(macosx):
    if getEnv("SDKROOT").len > 0 or compiler.len == 0 or not fileExists(compiler):
      return
    try:
      let discovered = probeStatus("/usr/bin/xcrun", @["--show-sdk-path"])
      if discovered.status != 0: return
      let defaultSdk = discovered.output.strip()
      if defaultSdk.len == 0 or not dirExists(defaultSdk): return
      var candidates: seq[string]
      for kind, path in walkDir(parentDir(defaultSdk)):
        if kind in {pcDir, pcLinkToDir}: candidates.add path
      let scratch = createTempDir("gene-c-sdk-", "")
      defer: removeDir(scratch)
      let source = scratch / "probe.c"
      let output = scratch / "probe"
      writeFile(source, "int main(void) { return 0; }\n")
      let links: SdkLinkProbe = proc(sdk: string): bool =
        var environment: seq[string]
        for key, value in envPairs():
          if key != "SDKROOT": environment.add key & "=" & value
        environment.add "SDKROOT=" & sdk
        probeStatus(compiler, @[source, "-o", output], some(environment)).status == 0
      let selected = compatibleMacSdk("", defaultSdk, candidates, links)
      if selected.len > 0:
        putEnv("SDKROOT", selected)
        stderr.writeLine("Using compatible macOS SDK for native builds: " & selected)
    except OSError, IOError:
      # Preserve the ordinary build/fallback path if discovery is unavailable.
      discard
  else:
    discard
