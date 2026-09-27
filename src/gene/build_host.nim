## Environment-dependent native derivations are local to a build installation.
## Keep this identity outside artifact stores, which may be copied/shared.
import std/[os, strutils]
import ./[digest, process_lock]
when defined(posix) and not defined(geneWasm) and not defined(emscripten):
  import std/[nativesockets, sysrand]

proc nativeBuildHostIdentity*(): string =
  when defined(posix) and not defined(geneWasm) and not defined(emscripten):
    let path = getHomeDir() / ".gene" / "native-build-host-id"
    let lock = acquireProcessFileLock(path & ".lock")
    defer: lock.release()
    if symlinkExists(path) or dirExists(path):
      raise newException(IOError, "native build host identity is not a regular file")
    if not fileExists(path):
      let random = urandom(32)
      var bytes = newString(random.len)
      for i, b in random: bytes[i] = char(b)
      let temporary = path & ".tmp-" & $getCurrentProcessId()
      writeFile(temporary, sha256Hex(bytes) & "\n")
      setFilePermissions(temporary, {fpUserRead, fpUserWrite})
      moveFile(temporary, path)
    if getFileInfo(path, followSymlink = false).isSpecial or getFileSize(path) > 65:
      raise newException(IOError, "native build host identity is invalid")
    let identity = readFile(path).strip()
    if identity.len != 64 or not identity.allCharsInSet({'0'..'9', 'a'..'f'}):
      raise newException(IOError, "native build host identity is invalid")
    "sha256:" & sha256Hex("gene-native-build-host-v1\0" & getHostname() &
                          "\0" & identity)
  else:
    raise newException(IOError, "native C builds require a qualified POSIX host")
