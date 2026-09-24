## Bounded, explicit HTTPS transport for PKG-3 registry objects. The host
## declares an absolute curl executable; no shell or user curl configuration
## participates. Curl 8.4+ is required because older --max-filesize did not
## enforce the limit during unknown-length transfers. A separate signed-index
## check authenticates downloaded release bytes after TLS transport.

import std/[os, osproc, streams, strutils, tempfiles]
import ./digest

const
  MaxRegistryResponseBytes* = 8 * 1024 * 1024
  MaxRegistryObjectBytes* = 1024 * 1024 * 1024
  DefaultRegistryTimeoutSeconds* = 30

type
  RegistryHttpsError* = object of CatchableError

  RegistryHttpsTransport* = ref object
    baseUrl*: string
    curlPath*: string
    caFile*: string
    timeoutSeconds*: int

proc transportError(message: string) {.noreturn.} =
  raise newException(RegistryHttpsError, message)

proc registryRelativePath(path: string): bool

proc curlVersion(curlPath: string): tuple[major, minor: int] =
  let process = startProcess(curlPath, args = ["--version"],
                             options = {poStdErrToStdOut})
  var output: string
  var status: int
  try:
    output = process.outputStream.readAll()
    status = process.waitForExit()
  finally:
    process.close()
  if status != 0:
    transportError("configured curl executable failed --version")
  if output.len == 0:
    transportError("configured curl executable printed no version")
  let words = output.splitLines()[0].splitWhitespace()
  if words.len < 2 or words[0] != "curl":
    transportError("configured transport is not curl")
  let components = words[1].split('.')
  if components.len < 2:
    transportError("curl version cannot be parsed")
  try:
    result.major = parseInt(components[0])
    result.minor = parseInt(components[1])
  except ValueError:
    transportError("curl version cannot be parsed")

proc newRegistryHttpsTransport*(baseUrl, curlPath: string,
                                caFile = "",
                                timeoutSeconds = DefaultRegistryTimeoutSeconds):
                                RegistryHttpsTransport =
  if not baseUrl.startsWith("https://") or
      baseUrl.len <= "https://".len or
      baseUrl.contains({'\r', '\n', '\0', '?', '#'}) or
      baseUrl.contains('@') or baseUrl.endsWith("//"):
    transportError("registry transport requires a plain HTTPS base URL")
  let authority = baseUrl["https://".len .. ^1].split('/')[0]
  if authority.len == 0 or authority.startsWith(':') or
      authority.contains({' ', '\t'}):
    transportError("registry HTTPS authority is invalid")
  for ch in authority:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-', ':', '[', ']'}:
      transportError("registry HTTPS authority has invalid characters")
  let suffix = baseUrl["https://".len + authority.len .. ^1]
  if suffix.len > 0 and suffix != "/" and
      (suffix.contains("//") or not registryRelativePath(
        if suffix.endsWith("/"): suffix[0 ..< suffix.high]
        else: suffix)):
    transportError("registry HTTPS base path is not canonical")
  if not curlPath.isAbsolute or not fileExists(curlPath):
    transportError("registry curl executable must be an absolute file path")
  if caFile.len > 0 and
      (not caFile.isAbsolute or not fileExists(caFile)):
    transportError("registry CA file must be an absolute existing path")
  if timeoutSeconds < 1 or timeoutSeconds > 300:
    transportError("registry timeout must be between 1 and 300 seconds")
  let version = curlVersion(curlPath)
  if version.major < 8 or (version.major == 8 and version.minor < 4):
    transportError("registry transport requires curl 8.4 or newer")
  RegistryHttpsTransport(baseUrl: baseUrl.strip(chars = {'/'}),
    curlPath: curlPath, caFile: caFile,
    timeoutSeconds: timeoutSeconds)

proc registryRelativePath(path: string): bool =
  if path.len < 2 or path[0] != '/' or
      path.contains({'\r', '\n', '\0', '?', '#', '\\'}):
    return false
  for segment in path[1 .. ^1].split('/'):
    if segment.len == 0 or segment in [".", ".."]:
      return false
    for ch in segment:
      if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.', '~', '+'}:
        return false
  true

proc downloadGet(transport: RegistryHttpsTransport, path, tempPath: string,
                 maxBytes, expectedStatus: int): int64 =
  if transport == nil or not registryRelativePath(path):
    transportError("registry GET path is not canonical")
  if maxBytes < 0 or maxBytes > MaxRegistryObjectBytes:
    transportError("registry GET size limit is invalid")
  var args = @["--disable", "--silent", "--show-error", "--globoff",
    "--proto", "=https", "--proxy", "", "--noproxy", "*",
    "--tlsv1.2",
    "--connect-timeout", $min(10, transport.timeoutSeconds),
    "--max-time", $transport.timeoutSeconds,
    "--max-filesize", $(maxBytes + 1),
    "--max-redirs", "0", "--request", "GET",
    "--output", tempPath, "--write-out", "%{http_code}"]
  if transport.caFile.len > 0:
    args.add @["--cacert", transport.caFile]
  args.add @["--url", transport.baseUrl & path]
  let process = startProcess(transport.curlPath, args = args,
                             options = {poStdErrToStdOut})
  var output: string
  var status: int
  try:
    output = process.outputStream.readAll()
    status = process.waitForExit()
  finally:
    process.close()
  if status != 0:
    transportError("registry HTTPS GET failed with curl status " & $status)
  if output.strip() != $expectedStatus:
    transportError("registry HTTPS GET returned status " & output.strip())
  result = getFileSize(tempPath)
  if result < 0 or result > maxBytes:
    transportError("registry HTTPS GET exceeded the byte limit")

proc fetchRegistryBytes*(transport: RegistryHttpsTransport,
                         path: string, maxBytes: int,
                         expectedStatus = 200): string =
  if maxBytes < 1 or maxBytes > MaxRegistryResponseBytes:
    transportError("registry GET metadata limit is invalid")
  let (file, tempPath) = createTempFile("gene-registry-", ".download")
  file.close()
  defer:
    if fileExists(tempPath): removeFile(tempPath)
  discard downloadGet(transport, path, tempPath, maxBytes, expectedStatus)
  readFile(tempPath)

proc fetchRegistryObject*(transport: RegistryHttpsTransport,
                          path, digest: string, size: int64,
                          stagingDir: string): string =
  ## Return a verified private file in stagingDir. The caller owns and must
  ## publish or remove it; no unverified bytes are returned to package code.
  if size < 0 or size > MaxRegistryObjectBytes or
      digest.len != 71 or not digest.startsWith("sha256:"):
    transportError("registry object metadata is invalid")
  for ch in digest[7 .. ^1]:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      transportError("registry object digest is not lowercase SHA-256")
  if not stagingDir.isAbsolute or not dirExists(stagingDir):
    transportError("registry object staging directory must exist")
  let (file, tempPath) = createTempFile("gene-registry-object-", ".tmp",
                                       stagingDir)
  file.close()
  try:
    let received = downloadGet(transport, path, tempPath, int(size), 200)
    if received != size or "sha256:" & sha256File(tempPath) != digest:
      transportError("registry object size or digest does not match")
    result = tempPath
  except CatchableError:
    if fileExists(tempPath): removeFile(tempPath)
    raise

proc uploadRegistryFile*(transport: RegistryHttpsTransport,
                         httpMethod, path, source, bearerToken: string): int =
  ## The token crosses the child stdin as a one-line curl config, never argv
  ## or a persistent temporary file. The source is a regular on-disk file so
  ## large uploads do not get buffered in Gene or curl stdin.
  if transport == nil or httpMethod notin ["PUT", "POST"] or
      not registryRelativePath(path):
    transportError("registry upload method or path is invalid")
  if not source.isAbsolute or not fileExists(source) or
      symlinkExists(source) or
      getFileInfo(source, followSymlink = false).isSpecial or
      getFileSize(source) > MaxRegistryObjectBytes:
    transportError("registry upload source must be a bounded regular file")
  if bearerToken.len < 1 or bearerToken.len > 4096:
    transportError("registry publish bearer token is invalid")
  for ch in bearerToken:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '_', '~',
                 '+', '/', '='}:
      transportError("registry publish bearer token has invalid characters")
  let (responseFile, responsePath) = createTempFile("gene-registry-upload-",
                                                   ".response")
  responseFile.close()
  defer:
    if fileExists(responsePath): removeFile(responsePath)
  var args = @["--disable", "--silent", "--show-error", "--globoff",
    "--proto", "=https", "--proxy", "", "--noproxy", "*",
    "--tlsv1.2", "--connect-timeout", $min(10, transport.timeoutSeconds),
    "--max-time", $transport.timeoutSeconds, "--max-filesize", "4097",
    "--max-redirs", "0", "--request", httpMethod,
    "--header", "Content-Type: application/octet-stream",
    "--output", responsePath, "--write-out", "%{http_code}",
    "--config", "-"]
  if httpMethod == "PUT":
    args.add @["--upload-file", source]
  else:
    args.add @["--data-binary", "@" & source]
  if transport.caFile.len > 0:
    args.add @["--cacert", transport.caFile]
  args.add @["--url", transport.baseUrl & path]
  let process = startProcess(transport.curlPath, args = args,
                             options = {poStdErrToStdOut})
  var output: string
  var status: int
  try:
    process.inputStream.write("header = \"Authorization: Bearer " &
      bearerToken & "\"\n")
    process.inputStream.close()
    output = process.outputStream.readAll()
    status = process.waitForExit()
  finally:
    process.close()
  if status != 0:
    transportError("registry HTTPS upload failed with curl status " & $status)
  let code = output.strip()
  if code.len != 3 or not code.allCharsInSet({'0' .. '9'}):
    transportError("registry HTTPS upload returned malformed status")
  if getFileSize(responsePath) > 4096:
    transportError("registry HTTPS upload response exceeded byte limit")
  parseInt(code)
