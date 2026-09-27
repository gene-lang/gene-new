## A bounded, single-writer registry behind a TLS reverse proxy. It deliberately
## binds loopback only and has no Gene evaluator or online private signing key.
import std/[base64, monotimes, nativesockets, net, os, strutils, sysrand,
            tables, tempfiles, times]
import gene/[package, printer, registry_store, release_crypto]
when defined(posix): import std/posix

var stopping {.volatile.} = false
proc requestStop(signal: cint) {.noconv.} = stopping = true

proc reject(status: int, message: string) {.noreturn.} =
  var error = newException(RegistryServiceError, message)
  error.status = status
  raise error

proc remaining(deadline: MonoTime): int =
  result = int((deadline - getMonoTime()).inMilliseconds)
  if result <= 0: reject(408, "request deadline exceeded")

proc sendBytes(socket: Socket, bytes: string, deadline: MonoTime) =
  var written = 0
  while written < bytes.len:
    let milliseconds = remaining(deadline)
    when defined(posix):
      var timeout = Timeval(tv_sec: posix.Time(milliseconds div 1000),
        tv_usec: Suseconds((milliseconds mod 1000) * 1000))
      if posix.setsockopt(socket.getFd(), SOL_SOCKET, SO_SNDTIMEO,
          addr timeout, SockLen(sizeof(timeout))) != 0: raiseOSError(osLastError())
    let sent = socket.send(unsafeAddr bytes[written], bytes.len - written)
    if sent <= 0: raise newException(IOError, "registry connection write failed")
    written += sent

proc reply(socket: Socket, response: RegistryReply, deadline: MonoTime) =
  let length = if response.file.len > 0: getFileSize(response.file)
               else: int64(response.body.len)
  let reason = case response.status
    of 200: "OK"
    of 201: "Created"
    of 400: "Bad Request"
    of 403: "Forbidden"
    of 404: "Not Found"
    of 408: "Request Timeout"
    of 409: "Conflict"
    of 411: "Length Required"
    of 413: "Content Too Large"
    of 417: "Expectation Failed"
    of 429: "Too Many Requests"
    of 507: "Insufficient Storage"
    else: "Internal Server Error"
  socket.sendBytes("HTTP/1.1 " & $response.status & " " & reason & "\r\n" &
    "Content-Length: " & $length & "\r\nContent-Type: application/octet-stream\r\n" &
    "Connection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n", deadline)
  if response.file.len == 0:
    socket.sendBytes(response.body, deadline)
  else:
    let file = open(response.file, fmRead)
    defer: file.close()
    var buffer = newString(65536)
    while true:
      let count = file.readBuffer(addr buffer[0], buffer.len)
      if count == 0: break
      socket.sendBytes(buffer[0..<count], deadline)

proc serveConnection(store: RegistryStore, socket: Socket) =
  let deadline = getMonoTime() + initDuration(milliseconds = store.requestTimeoutMs)
  var replied = false
  var temporary = ""
  defer:
    socket.close()
    if temporary.len > 0 and fileExists(temporary): removeFile(temporary)
  try:
    let request = socket.recvLine(remaining(deadline), maxLength = 4096).split(' ')
    if request.len != 3 or request[0] notin ["GET", "PUT", "POST"] or
        request[2] notin ["HTTP/1.0", "HTTP/1.1"]:
      reject(400, "invalid request line")
    var headers = initTable[string, string]()
    var headerBytes = 0
    while true:
      let line = socket.recvLine(remaining(deadline), maxLength = 4096)
      if line.len == 0: reject(400, "incomplete headers")
      if line == "\r\n": break
      headerBytes += line.len
      if line.len > 4096 or headerBytes > 16384 or headers.len >= 64:
        reject(413, "headers exceed limits")
      let colon = line.find(':')
      if colon <= 0: reject(400, "invalid header")
      let name = line[0..<colon].toLowerAscii()
      if not name.allCharsInSet({'a'..'z','0'..'9','-'}): reject(400, "invalid header name")
      if headers.hasKey(name): reject(400, "duplicate header")
      headers[name] = line[colon+1..^1].strip()
    if headers.hasKey("transfer-encoding"): reject(400, "transfer encoding is unsupported")
    let limit = store.requestBodyLimit(request[0], request[1],
                                      headers.getOrDefault("authorization"))
    var length = 0'i64
    if headers.hasKey("content-length"):
      let number = headers["content-length"]
      if number.len == 0 or number.len > 10 or not number.allCharsInSet({'0'..'9'}):
        reject(400, "invalid content length")
      length = parseBiggestInt(number)
    elif request[0] != "GET": reject(411, "content length required")
    if length > limit: reject(413, "body exceeds endpoint limit")
    if request[0] != "GET": store.checkUploadCapacity(length)
    if headers.hasKey("expect"):
      if headers["expect"].toLowerAscii() != "100-continue": reject(417, "unsupported expectation")
      socket.sendBytes("HTTP/1.1 100 Continue\r\n\r\n", deadline)
    if request[0] != "GET":
      let (file, path) = createTempFile("request-", "", store.root / "tmp")
      temporary = path
      try:
        var left = length
        while left > 0:
          let chunk = socket.recv(int(min(left, 65536)), remaining(deadline))
          if chunk.len == 0: reject(400, "truncated body")
          file.write(chunk)
          left -= chunk.len
      finally: file.close()
    let response = store.handleRegistryRequest(request[0], request[1],
      headers.getOrDefault("authorization"), temporary)
    replied = true
    socket.reply(response, deadline)
  except CatchableError as error:
    if not replied:
      let status =
        if error of RegistryServiceError: cast[ref RegistryServiceError](error).status
        elif error of PackageError or error of ValueError: 400
        elif error of TimeoutError: 408
        else: 500
      if status == 500: stderr.writeLine("registry request failed: " & error.msg)
      try:
        socket.reply(RegistryReply(status: status, body: $status & "\n"),
          getMonoTime() + initDuration(milliseconds = 1000))
      except CatchableError: discard

proc privateOutput(directory: string) =
  if not directory.isAbsolute or dirExists(directory) or fileExists(directory) or symlinkExists(directory):
    raise newException(ValueError, "key output requires a new absolute directory")
  createDir(directory)
  setFilePermissions(directory, {fpUserRead, fpUserWrite, fpUserExec})

proc privateFile(path, bytes: string) =
  writeFile(path, bytes)
  setFilePermissions(path, {fpUserRead, fpUserWrite})

proc rawKey(path: string): string =
  if not path.isAbsolute or not fileExists(path) or symlinkExists(path) or
      getFileInfo(path, followSymlink = false).isSpecial or getFileSize(path) != 32:
    raise newException(ValueError, "key requires an absolute regular raw 32-byte file")
  readFile(path)

proc randomBytes(): string =
  let bytes = urandom(32)
  result = newString(bytes.len)
  for i, b in bytes: result[i] = char(b)

proc provision(): bool =
  if paramCount() == 5 and paramStr(1) == "keygen" and
      paramStr(2) == "--crypto" and paramStr(4) == "--out":
    let crypto = loadReleaseCrypto(paramStr(3))
    defer: crypto.close()
    let seed = randomBytes()
    let publicKey = crypto.ed25519PublicKey(seed)
    let directory = paramStr(5)
    privateOutput(directory)
    privateFile(directory / "private.seed", seed)
    privateFile(directory / "public.key", publicKey)
    privateFile(directory / "public-key.base64", base64.encode(publicKey) & "\n")
    privateFile(directory / "publish.token", base64.encode(randomBytes()) & "\n")
    stdout.writeLine("public key: " & base64.encode(publicKey))
    return true
  if paramCount() == 11 and paramStr(1) == "delegate" and
      paramStr(2) == "--crypto" and paramStr(4) == "--registry-key" and
      paramStr(6) == "--owner" and paramStr(8) == "--owner-key" and paramStr(10) == "--out":
    let crypto = loadReleaseCrypto(paramStr(3))
    defer: crypto.close()
    let seed = rawKey(paramStr(5))
    let record = ownerKeyRecord(paramStr(7), rawKey(paramStr(9)))
    let signature = crypto.ed25519Sign(seed, ownerKeySignaturePayload(record))
    let directory = paramStr(11)
    privateOutput(directory)
    privateFile(directory / "owner-record.gene", print(record) & "\n")
    privateFile(directory / "owner-record.sig", signature)
    stdout.writeLine("registry key: " & base64.encode(crypto.ed25519PublicKey(seed)))
    return true

proc main() =
  when not defined(posix):
    quit("gene-registry currently requires a POSIX host", 2)
  if provision(): return
  if paramCount() != 2 or paramStr(1) != "--config":
    quit("usage: gene-registry --config /absolute/service.gene", 2)
  let path = paramStr(2)
  if not path.isAbsolute: quit("service config must be absolute", 2)
  let store = openRegistryStore(path)
  defer: store.close()
  when defined(posix): posix.signal(SIGPIPE, SIG_IGN)
  when defined(posix):
    posix.signal(SIGTERM, requestStop)
    posix.signal(SIGINT, requestStop)
  let server = newSocket(buffered = false)
  defer: server.close()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(store.port), "127.0.0.1")
  server.listen(32)
  stdout.writeLine("registry listening 127.0.0.1:" & $server.getLocalAddr()[1])
  stdout.flushFile()
  while not stopping:
    var readable = @[server.getFd()]
    try:
      if selectRead(readable, 250) <= 0: continue
    except OSError:
      if stopping: break
      raise
    var client: owned(Socket)
    server.accept(client)
    serveConnection(store, client)

when isMainModule:
  try: main()
  except CatchableError as error:
    stderr.writeLine("registry startup failed: " & error.msg)
    quit(2)
