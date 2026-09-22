# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# macOS: link against an SDK the installed linker can read.
#
# The Command Line Tools' default SDK (`MacOSX.sdk`) can be newer than the
# linker beside it: MacOSX27.0.sdk's `.tbd` stubs list `arm64e.x1-macos`, which
# ld-1266 rejects as an unknown architecture, so every link of `bin/gene` (and of
# each test binary) fails. When `SDKROOT` is not set and the default SDK does not
# link a trivial program, pick the newest installed SDK that does. An explicit
# `SDKROOT` always wins, and nothing changes on a toolchain where the default
# works. Probe results are cached per SDK and compiler version.
when defined(macosx) and not defined(emscripten):
  import std/[algorithm, os, strutils]

  proc sdkVersion(name: string): seq[int] =
    # "MacOSX26.5.sdk" -> @[26, 5]; anything else -> @[]
    if not (name.startsWith("MacOSX") and name.endsWith(".sdk")): return @[]
    let digits = name[6 ..< name.len - 4]
    if digits.len == 0: return @[]
    for part in digits.split('.'):
      try: result.add parseInt(part)
      except ValueError: return @[]

  proc sdkLinks(sdk, compiler: string): bool =
    let probe = "printf 'int main(void){return 0;}\\n' | SDKROOT=" &
      quoteShell(sdk) & " clang -x c - -o /dev/null 2>/dev/null"
    gorgeEx(probe, "", "gene-sdk-probe|" & sdk & "|" & compiler).exitCode == 0

  if getEnv("SDKROOT") == "":
    let compiler = gorgeEx("clang --version 2>/dev/null | head -1").output
    let default = gorgeEx("xcrun --show-sdk-path 2>/dev/null").output.strip()
    if default.len > 0 and not sdkLinks(default, compiler):
      var candidates: seq[(seq[int], string)]
      for dir in listDirs(parentDir(default)):
        let version = sdkVersion(extractFilename(dir))
        if version.len > 0:
          candidates.add((version, dir))
      proc newer(a, b: (seq[int], string)): int =
        # Descending by version, compared part by part.
        for i in 0 ..< max(a[0].len, b[0].len):
          let x = if i < a[0].len: a[0][i] else: 0
          let y = if i < b[0].len: b[0][i] else: 0
          if x != y: return y - x
        0
      candidates.sort(newer)
      for (version, dir) in candidates:
        if sdkLinks(dir, compiler):
          putEnv("SDKROOT", dir)
          break
