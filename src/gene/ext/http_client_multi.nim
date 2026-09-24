## Application-owned libcurl multi transport. Included by stdlib.nim after the
## legacy one-shot client, so both APIs share dynamic curl loading but not
## handles or public return shapes.

when compileOption("threads") and not defined(geneWasm) and
    not defined(emscripten):
  import std/uri
  type
    MultiCaLoadJob = object
      path, data, failure: SharedExecText
      done: bool

    OwnedHttpTransfer = object
      httpMethod, url, requestTarget, body: SharedExecText
      caData, proxy, noProxy: SharedExecText
      headers: ptr SharedExecArg
      admittedAt: MonoTime
      timeoutMs, connectTimeoutMs, maxBytes: int
      maxIdleMs: int
      easy, headerList: pointer # worker-owned
      responseBody, responseHeaders: SharedHttpBuffer
      responseStatus: int
      headerStatus: int
      redirectRemaining: int
      redirectEligible, redirectLocationSeen, redirectResponse: bool
      effectiveUrl, failure: SharedExecText
      resultCode: cint
      bodyProvided: bool
      uploading: bool
      uploadLock: Lock
      uploadBuffer: SharedHttpBuffer
      uploadExpected, uploadMaxBytes, uploadReadBytes, uploadSentBytes: int
      uploadEof, uploadNeedData, uploadPaused, uploadResumeRequested: bool
      streaming: bool
      streamLock: Lock
      streamReceivedBytes: int
      streamPaused: bool
      resumeRequested, headersReady: bool
      responseOverflow, headerOverflow: bool
      cancelRequested, workerDone: bool

    OwnedMultiService = ref object
      applicationPtr: pointer # weak identity; workers never touch Application
      schedulerPtr: pointer
      lock: Lock
      multi: pointer         # worker-owned; root may only call multi_wakeup
      caJobs: seq[pointer]
      requestJobs: seq[pointer]
      maxTotal, maxPerHost: int
      configurePending: bool
      clientCount: int
      stopRequested: bool
      ready, failed, stopped: bool
      cleanupCode: cint
      thread: ref Thread[OwnedMultiService]

    OwnedClientPhase = enum
      ocOpening, ocOpen, ocClosing, ocClosed

    OwnedHttpClientRecord = ref object
      application: Application
      ownerLane: int
      id: uint64
      service: OwnedMultiService
      phase: OwnedClientPhase
      openScope: Scope
      openTask, openLease: Value
      openNativeActive: bool
      caPath, caData: string
      caJob: ptr MultiCaLoadJob
      handleGone: bool
      handleDelivered: bool
      abandoned: bool
      closeLease: Value
      closeNativeActive: bool
      closeError: string
      waiters: seq[Value]
      maxConnections, maxPerOrigin, maxPendingRequests: int
      maxIdleMs, connectTimeoutMs, timeoutMs: int
      maxBufferedBodyBytes, maxStreamBodyBytes: int
      redirects: int
      proxy: string
      environmentHttpProxy, environmentHttpsProxy, environmentNoProxy: string
      activeCount: int
      runningCount: int
      runningByOrigin: Table[string, int]

    OwnedHttpPending = ref object
      transfer: ptr OwnedHttpTransfer
      client: OwnedHttpClientRecord
      task, lease: Value
      scope: Scope
      budgetReserved: int
      nativeActive: bool
      origin: string
      serviceQueued: bool
      streaming, headersDelivered: bool
      bodyRecord: OwnedHttpBodyRecord
      uploadReader, uploadReadTask: Value
      uploadBorrowKey: uint64
      uploadError: string

    OwnedHttpBodyRecord = ref object
      application: Application
      ownerLane: int
      id: uint64
      client: OwnedHttpClientRecord
      transfer: ptr OwnedHttpTransfer # owned by OwnedHttpPending until retired
      readTask: Value
      readAmount: int
      lease: Value
      waiters: seq[Value]
      closing, closed, handleGone: bool
      failure: string

  var ownedMultiLock: Lock
  var ownedMultiServices = initTable[pointer, OwnedMultiService]()
  var ownedHttpClients = initTable[uint64, OwnedHttpClientRecord]()
  var ownedHttpBodies = initTable[uint64, OwnedHttpBodyRecord]()
  var ownedUploadBorrows = initHashSet[uint64]()
  var ownedHttpPending: seq[OwnedHttpPending]
  const OwnedHttpApplicationPendingLimit = 4096
  initLock(ownedMultiLock)

  proc ownedHttpClientOpenCount(app: Application): int =
    withLock ownedMultiLock:
      for _, record in ownedHttpClients:
        if record.application == app and record.phase != ocClosed:
          inc result

  proc ownedHttpClientPendingCount(app: Application): int =
    withLock ownedMultiLock:
      for pending in ownedHttpPending:
        if pending.client.application == app:
          inc result

  proc ownedHttpWrite(data: pointer, size, count: csize_t,
                       userData: pointer): csize_t {.cdecl, gcsafe.} =
    let transfer = cast[ptr OwnedHttpTransfer](userData)
    if size != 0 and count > high(csize_t) div size:
      return 0
    let total = size * count
    if transfer.redirectResponse:
      return total # followed hop body is not exposed or retained
    if total > csize_t(high(int)):
      transfer.responseOverflow = true
      return 0
    if transfer.streaming:
      withLock transfer.streamLock:
        if int(total) > transfer.maxBytes - transfer.streamReceivedBytes:
          transfer.responseOverflow = true
          return 0
        if int(total) > transfer.responseBody.cap -
            transfer.responseBody.len:
          if int(total) > transfer.responseBody.cap:
            transfer.responseOverflow = true
            return 0
          transfer.streamPaused = true
          return CurlWritePause
        if appendHttpBuffer(transfer.responseBody, data,
                            int(total)) != int(total):
          transfer.responseOverflow = true
          return 0
        transfer.streamReceivedBytes += int(total)
      return total
    if int(total) > transfer.maxBytes - transfer.responseBody.len:
      transfer.responseOverflow = true
      return 0
    if appendHttpBuffer(transfer.responseBody, data, int(total)) != int(total):
      transfer.responseOverflow = true
      return 0
    total

  proc ownedHttpHeader(data: pointer, size, count: csize_t,
                        userData: pointer): csize_t {.cdecl, gcsafe.} =
    let transfer = cast[ptr OwnedHttpTransfer](userData)
    if size != 0 and count > high(csize_t) div size:
      return 0
    let total = size * count
    if total > csize_t(high(int)):
      transfer.headerOverflow = true
      return 0
    if transfer.streaming:
      if atomicLoadN(addr transfer.headersReady, ATOMIC_ACQUIRE):
        return total # trailers are not part of final response headers
    if transfer.streaming or transfer.redirectEligible:
      var line = newString(int(total))
      if line.len > 0: copyMem(addr line[0], data, line.len)
      if line.startsWith("HTTP/"):
        let parts = strutils.splitWhitespace(line)
        transfer.headerStatus =
          if parts.len >= 2:
            try: parseInt(parts[1])
            except ValueError: 0
          else: 0
        transfer.redirectLocationSeen = false
        transfer.redirectResponse = false
      elif transfer.redirectEligible and transfer.redirectRemaining > 0 and
          line.toLowerAscii().startsWith("location:") and
          line[9 .. ^1].strip().len > 0:
        transfer.redirectLocationSeen = true
    if appendHttpBuffer(transfer.responseHeaders, data,
                         int(total)) != int(total):
      transfer.headerOverflow = true
      return 0
    if transfer.streaming and total == 2 and
        cast[ptr array[2, char]](data)[] == ['\r', '\n'] and
        transfer.headerStatus >= 200 and
        transfer.headerStatus != 101:
      transfer.responseStatus = transfer.headerStatus
      transfer.redirectResponse = transfer.redirectEligible and
        transfer.redirectRemaining > 0 and transfer.redirectLocationSeen and
        transfer.headerStatus in [301, 302, 303, 307, 308]
      atomicStoreN(addr transfer.headersReady, true, ATOMIC_RELEASE)
    elif not transfer.streaming and total == 2 and
        cast[ptr array[2, char]](data)[] == ['\r', '\n']:
      transfer.redirectResponse = transfer.redirectEligible and
        transfer.redirectRemaining > 0 and transfer.redirectLocationSeen and
        transfer.headerStatus in [301, 302, 303, 307, 308]
    total

  proc ownedHttpProgress(userData: pointer, dlTotal, dlNow, ulTotal,
                          ulNow: int64): cint {.cdecl, gcsafe.} =
    let transfer = cast[ptr OwnedHttpTransfer](userData)
    if atomicLoadN(addr transfer.cancelRequested, ATOMIC_ACQUIRE): 1 else: 0

  proc ownedHttpRead(data: pointer, size, count: csize_t,
                      userData: pointer): csize_t {.cdecl, gcsafe.} =
    let transfer = cast[ptr OwnedHttpTransfer](userData)
    if size != 0 and count > high(csize_t) div size:
      return CurlReadAbort
    let total = size * count
    if total > csize_t(high(int)) or
        atomicLoadN(addr transfer.cancelRequested, ATOMIC_ACQUIRE):
      return CurlReadAbort
    withLock transfer.uploadLock:
      if transfer.uploadBuffer.len > 0:
        let amount = min(int(total), transfer.uploadBuffer.len)
        if amount > 0:
          copyMem(data, transfer.uploadBuffer.data, amount)
          let remaining = transfer.uploadBuffer.len - amount
          if remaining > 0:
            moveMem(transfer.uploadBuffer.data,
              cast[pointer](cast[uint](transfer.uploadBuffer.data) + uint(amount)),
              remaining)
          transfer.uploadBuffer.len = remaining
          transfer.uploadSentBytes += amount
        return csize_t(amount)
      if transfer.uploadEof:
        return 0
      transfer.uploadPaused = true
      transfer.uploadNeedData = true
      return CurlReadPause

  proc ownedTransferFailure(transfer: ptr OwnedHttpTransfer, message: string) =
    if transfer.failure.len == 0:
      transfer.failure = sharedExecText(message)

  proc cleanupOwnedEasy(transfer: ptr OwnedHttpTransfer) =
    if transfer.headerList != nil:
      gCurlApi.slistFreeAll(transfer.headerList)
      transfer.headerList = nil
    if transfer.easy != nil:
      gCurlApi.easyCleanup(transfer.easy)
      transfer.easy = nil

  proc freeOwnedTransfer(transfer: ptr OwnedHttpTransfer) =
    if transfer == nil: return
    discard consumeSharedExecText(transfer.httpMethod)
    discard consumeSharedExecText(transfer.url)
    discard consumeSharedExecText(transfer.requestTarget)
    discard consumeSharedExecText(transfer.body)
    discard consumeSharedExecText(transfer.caData)
    discard consumeSharedExecText(transfer.proxy)
    discard consumeSharedExecText(transfer.noProxy)
    discard consumeSharedExecText(transfer.effectiveUrl)
    discard consumeSharedExecText(transfer.failure)
    freeHttpBuffer(transfer.responseBody)
    freeHttpBuffer(transfer.responseHeaders)
    if transfer.uploading:
      freeHttpBuffer(transfer.uploadBuffer)
      deinitLock(transfer.uploadLock)
    if transfer.streaming: deinitLock(transfer.streamLock)
    var header = transfer.headers
    while header != nil:
      let next = header.next
      discard consumeSharedExecText(header.text)
      deallocShared(header)
      header = next
    deallocShared(transfer)

  proc configureOwnedEasy(transfer: ptr OwnedHttpTransfer): bool =
    template setopt(call: untyped, label: string) =
      if call != CurlOk:
        transfer.ownedTransferFailure("could not set " & label)
        return false
    transfer.easy = gCurlApi.easyInit()
    if transfer.easy == nil:
      transfer.ownedTransferFailure("curl_easy_init failed")
      return false
    let easy = transfer.easy
    let elapsed = int((getMonoTime() - transfer.admittedAt).inMilliseconds)
    let remaining = transfer.timeoutMs - elapsed
    if remaining <= 0:
      transfer.ownedTransferFailure("request deadline expired in queue")
      return false
    let url = readSharedExecText(transfer.url)
    let target = readSharedExecText(transfer.requestTarget)
    let httpMethod = readSharedExecText(transfer.httpMethod)
    let proxy = readSharedExecText(transfer.proxy)
    let noProxy = readSharedExecText(transfer.noProxy)
    setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptUrl,
                          url.cstring), "URL")
    if proxy.len == 0:
      setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy,
                            CurlOptRequestTarget, target.cstring),
             "request target")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptPathAsIs, 1),
           "path preservation")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptHttpVersion, 2),
           "HTTP/1.1")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptProtocols, 3),
           "HTTP/HTTPS protocols")
    setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptProxy,
                          proxy.cstring), "proxy")
    setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptPreProxy,
                          "".cstring), "pre-proxy")
    setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy, CurlOptNoProxy,
                          noProxy.cstring), "no-proxy policy")
    for option in [CurlOptHttpProxyTunnel, CurlOptNetrc, CurlOptHttpAuth,
                   CurlOptProxyAuth]:
      setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, option, 0),
             "managed authentication")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                            CurlOptSslVerifyPeer, 1), "TLS verification")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                            CurlOptSslVerifyHost, 2), "TLS hostname")
    setopt(cCurlSetoptStr(gCurlApi.setoptAddr, easy,
                          CurlOptCustomRequest, httpMethod.cstring), "method")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptNoSignal, 1),
           "no-signal")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                            CurlOptFollowLocation, 0), "redirect policy")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                            CurlOptSuppressConnectHeaders, 1),
           "proxy CONNECT header suppression")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptTimeoutMs,
                            clong(remaining)), "total timeout")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                            CurlOptConnectTimeoutMs,
                            clong(min(transfer.connectTimeoutMs, remaining))),
           "connect timeout")
    if transfer.maxIdleMs == 0:
      setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                              CurlOptFreshConnect, 1), "no idle reuse")
      setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                              CurlOptForbidReuse, 1), "no idle retention")
    else:
      setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy,
                              CurlOptMaxAgeConn,
                              clong((transfer.maxIdleMs + 999) div 1000)),
             "max idle age")
    setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptWriteFunction,
                          cast[pointer](ownedHttpWrite)), "write callback")
    setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptWriteData,
                          transfer), "write data")
    setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptHeaderFunction,
                          cast[pointer](ownedHttpHeader)), "header callback")
    setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptHeaderData,
                          transfer), "header data")
    setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptNoProgress, 0),
           "progress")
    setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy,
                          CurlOptXferInfoFunction,
                          cast[pointer](ownedHttpProgress)),
           "progress callback")
    setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptXferInfoData,
                          transfer), "progress data")
    if transfer.caData.len > 0:
      var caBlob = CurlBlob(data: transfer.caData.data,
                            len: csize_t(transfer.caData.len), flags: 1)
      setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptCaInfoBlob,
                            addr caBlob), "CA data")
    if transfer.uploading:
      setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptReadFunction,
                            cast[pointer](ownedHttpRead)), "upload read callback")
      setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptReadData,
                            transfer), "upload read data")
      setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptUpload, 1),
             "streaming upload")
      setopt(cCurlSetoptOff(gCurlApi.setoptAddr, easy,
                            CurlOptInfileSizeLarge,
                            int64(transfer.uploadExpected)),
             "upload Content-Length")
    elif transfer.bodyProvided:
      let bodyPtr = if transfer.body.len > 0: transfer.body.data
                    else: cast[pointer]("".cstring)
      setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptPostFields,
                            bodyPtr), "request body")
      setopt(cCurlSetoptOff(gCurlApi.setoptAddr, easy,
                            CurlOptPostFieldSizeLarge,
                            int64(transfer.body.len)), "request body size")
    if httpMethod == "HEAD":
      setopt(cCurlSetoptLong(gCurlApi.setoptAddr, easy, CurlOptNoBody, 1),
             "HEAD response")
    transfer.headerList = gCurlApi.slistAppend(nil, "Expect:")
    if transfer.headerList == nil:
      transfer.ownedTransferFailure("could not disable Expect handshake")
      return false
    var header = transfer.headers
    while header != nil:
      let text = readSharedExecText(header.text)
      let next = gCurlApi.slistAppend(transfer.headerList, text.cstring)
      if next == nil:
        transfer.ownedTransferFailure("could not allocate request headers")
        return false
      transfer.headerList = next
      header = header.next
    setopt(cCurlSetoptPtr(gCurlApi.setoptAddr, easy, CurlOptHttpHeader,
                          transfer.headerList), "request headers")
    true

  proc ownedMultiWake(service: OwnedMultiService) =
    withLock service.lock:
      if service.multi != nil:
        discard gCurlMultiApi.wakeup(service.multi)

  proc ownedMultiWorker(service: OwnedMultiService) {.thread.} =
    {.cast(gcsafe).}:
      let multi = gCurlMultiApi.init()
      if multi == nil:
        atomicStoreN(addr service.failed, true, ATOMIC_RELEASE)
        atomicStoreN(addr service.ready, true, ATOMIC_RELEASE)
        atomicStoreN(addr service.stopped, true, ATOMIC_RELEASE)
        return
      var initialTotal, initialHost: int
      withLock service.lock:
        initialTotal = service.maxTotal
        initialHost = service.maxPerHost
      let configured =
        cCurlMultiSetoptLong(gCurlMultiApi.setoptAddr, multi,
          CurlMultiOptMaxTotalConnections, clong(initialTotal)) ==
            CurlMultiOk and
        cCurlMultiSetoptLong(gCurlMultiApi.setoptAddr, multi,
          CurlMultiOptMaxHostConnections, clong(initialHost)) ==
            CurlMultiOk and
        cCurlMultiSetoptLong(gCurlMultiApi.setoptAddr, multi,
          CurlMultiOptMaxConnects, clong(initialTotal)) == CurlMultiOk
      if not configured:
        discard gCurlMultiApi.cleanup(multi)
        atomicStoreN(addr service.failed, true, ATOMIC_RELEASE)
        atomicStoreN(addr service.ready, true, ATOMIC_RELEASE)
        atomicStoreN(addr service.stopped, true, ATOMIC_RELEASE)
        return
      withLock service.lock:
        service.multi = multi
      atomicStoreN(addr service.ready, true, ATOMIC_RELEASE)
      var active: seq[ptr OwnedHttpTransfer]
      while true:
        var jobs: seq[pointer]
        var requests: seq[pointer]
        var stopping = false
        var configure = false
        var maxTotal, maxHost: int
        withLock service.lock:
          jobs = move service.caJobs
          service.caJobs = @[]
          requests = move service.requestJobs
          service.requestJobs = @[]
          stopping = service.stopRequested
          configure = service.configurePending
          service.configurePending = false
          maxTotal = service.maxTotal
          maxHost = service.maxPerHost
        if configure:
          if cCurlMultiSetoptLong(gCurlMultiApi.setoptAddr, multi,
              CurlMultiOptMaxTotalConnections, clong(maxTotal)) != CurlMultiOk or
              cCurlMultiSetoptLong(gCurlMultiApi.setoptAddr, multi,
              CurlMultiOptMaxHostConnections, clong(maxHost)) != CurlMultiOk or
              cCurlMultiSetoptLong(gCurlMultiApi.setoptAddr, multi,
              CurlMultiOptMaxConnects, clong(maxTotal)) != CurlMultiOk:
            atomicStoreN(addr service.failed, true, ATOMIC_RELEASE)
        for jobPtr in jobs:
          let job = cast[ptr MultiCaLoadJob](jobPtr)
          try:
            let data = readFile(readSharedExecText(job.path))
            if data.len > 8 * 1024 * 1024:
              job.failure = sharedExecText("CA file exceeds 8 MiB")
            else:
              job.data = sharedExecText(data)
          except CatchableError as error:
            job.failure = sharedExecText(error.msg)
          atomicStoreN(addr job.done, true, ATOMIC_RELEASE)
        for requestPtr in requests:
          let transfer = cast[ptr OwnedHttpTransfer](requestPtr)
          if stopping or
              atomicLoadN(addr transfer.cancelRequested, ATOMIC_ACQUIRE):
            atomicStoreN(addr transfer.workerDone, true, ATOMIC_RELEASE)
            continue
          if not configureOwnedEasy(transfer):
            cleanupOwnedEasy(transfer)
            atomicStoreN(addr transfer.workerDone, true, ATOMIC_RELEASE)
            continue
          if gCurlMultiApi.addHandle(multi, transfer.easy) != CurlMultiOk:
            transfer.ownedTransferFailure("curl_multi_add_handle failed")
            cleanupOwnedEasy(transfer)
            atomicStoreN(addr transfer.workerDone, true, ATOMIC_RELEASE)
            continue
          active.add transfer
        var i = 0
        while i < active.len:
          let transfer = active[i]
          if transfer.streaming and
              atomicLoadN(addr transfer.resumeRequested, ATOMIC_ACQUIRE):
            atomicStoreN(addr transfer.resumeRequested, false,
                          ATOMIC_RELEASE)
            withLock transfer.streamLock:
              transfer.streamPaused = false
            if gCurlMultiApi.easyPause(transfer.easy, 0) != CurlOk:
              transfer.ownedTransferFailure("could not resume response body")
              atomicStoreN(addr transfer.cancelRequested, true,
                            ATOMIC_RELEASE)
          if transfer.uploading and
              atomicLoadN(addr transfer.uploadResumeRequested, ATOMIC_ACQUIRE):
            atomicStoreN(addr transfer.uploadResumeRequested, false,
                          ATOMIC_RELEASE)
            withLock transfer.uploadLock:
              transfer.uploadPaused = false
            if gCurlMultiApi.easyPause(transfer.easy, 0) != CurlOk:
              transfer.ownedTransferFailure("could not resume upload")
              atomicStoreN(addr transfer.cancelRequested, true,
                            ATOMIC_RELEASE)
          if stopping or
              atomicLoadN(addr transfer.cancelRequested, ATOMIC_ACQUIRE):
            discard gCurlMultiApi.removeHandle(multi, transfer.easy)
            cleanupOwnedEasy(transfer)
            active.delete(i)
            atomicStoreN(addr transfer.workerDone, true, ATOMIC_RELEASE)
          else:
            inc i
        if active.len > 0:
          var running: cint
          if gCurlMultiApi.perform(multi, addr running) != CurlMultiOk:
            atomicStoreN(addr service.failed, true, ATOMIC_RELEASE)
            for transfer in active:
              transfer.ownedTransferFailure("curl_multi_perform failed")
              discard gCurlMultiApi.removeHandle(multi, transfer.easy)
              cleanupOwnedEasy(transfer)
              atomicStoreN(addr transfer.workerDone, true, ATOMIC_RELEASE)
            active.setLen(0)
          var messagesLeft: cint
          while true:
            let message = gCurlMultiApi.infoRead(multi, addr messagesLeft)
            if message == nil: break
            if message.kind != CurlMultiDone: continue
            for index in 0 ..< active.len:
              let transfer = active[index]
              if transfer.easy != message.easy: continue
              transfer.resultCode = message.resultCode
              if transfer.resultCode == CurlOk:
                var status: clong
                if cCurlGetinfoPtr(gCurlApi.getinfoAddr, transfer.easy,
                    CurlInfoResponseCode, addr status) != CurlOk:
                  transfer.ownedTransferFailure("could not read HTTP status")
                else:
                  transfer.responseStatus = int(status)
                var effective: cstring
                if cCurlGetinfoPtr(gCurlApi.getinfoAddr, transfer.easy,
                    CurlInfoEffectiveUrl, addr effective) == CurlOk and
                    effective != nil:
                  transfer.effectiveUrl = sharedExecText($effective)
              discard gCurlMultiApi.removeHandle(multi, transfer.easy)
              cleanupOwnedEasy(transfer)
              active.delete(index)
              atomicStoreN(addr transfer.workerDone, true, ATOMIC_RELEASE)
              break
        if stopping and active.len == 0:
          break
        if gCurlMultiApi.poll(multi, nil, 0, 1000, nil) != CurlMultiOk:
          atomicStoreN(addr service.failed, true, ATOMIC_RELEASE)
          for transfer in active:
            transfer.ownedTransferFailure("curl_multi_poll failed")
            discard gCurlMultiApi.removeHandle(multi, transfer.easy)
            cleanupOwnedEasy(transfer)
            atomicStoreN(addr transfer.workerDone, true, ATOMIC_RELEASE)
          active.setLen(0)
          break
      withLock service.lock:
        service.multi = nil
      service.cleanupCode = gCurlMultiApi.cleanup(multi)
      atomicStoreN(addr service.stopped, true, ATOMIC_RELEASE)

  proc ensureOwnedMultiService(app: Application, total, perHost: int):
      OwnedMultiService =
    let key = cast[pointer](app)
    var created = false
    withLock ownedMultiLock:
      result = ownedMultiServices.getOrDefault(key)
      if result == nil or result.stopRequested:
        result = OwnedMultiService(applicationPtr: key,
          schedulerPtr: cast[pointer](schedulerForScope(app.builtinsScope())),
          maxTotal: total, maxPerHost: perHost)
        initLock(result.lock)
        ownedMultiServices[key] = result
        created = true
      withLock result.lock:
        inc result.clientCount
        if total > result.maxTotal or perHost > result.maxPerHost:
          result.maxTotal = max(result.maxTotal, total)
          result.maxPerHost = max(result.maxPerHost, perHost)
          result.configurePending = true
    if created:
      try:
        var thread: ref Thread[OwnedMultiService]
        new(thread)
        createThread(thread[], ownedMultiWorker, result)
        result.thread = thread
      except CatchableError:
        atomicStoreN(addr result.failed, true, ATOMIC_RELEASE)
        atomicStoreN(addr result.ready, true, ATOMIC_RELEASE)
        atomicStoreN(addr result.stopped, true, ATOMIC_RELEASE)
    else:
      result.ownedMultiWake()

  proc releaseOwnedMultiClient(service: OwnedMultiService) =
    withLock service.lock:
      if service.clientCount > 0:
        dec service.clientCount
      if service.clientCount == 0:
        service.stopRequested = true
        if service.multi != nil:
          discard gCurlMultiApi.wakeup(service.multi)

  proc ownedClientError(scope: Scope, message: string): Value =
    try:
      raiseHttpClientError(message, scope, kind = "transport")
    except GeneError as error:
      result = error.errVal

  proc settleOwnedClientClosed(record: OwnedHttpClientRecord) =
    if record.phase == ocClosed:
      return
    let scope = record.application.builtinsScope()
    record.phase = ocClosed
    var lastClient = false
    withLock record.service.lock:
      lastClient = record.service.clientCount == 0
    if lastClient and
        (record.service.cleanupCode != CurlMultiOk or
         atomicLoadN(addr record.service.failed, ATOMIC_ACQUIRE)):
      record.closeError = "owned HTTP transport retired with an error"
    if record.closeLease.kind == vkTask:
      discard nativeRetireIoCleanupLease(record.closeLease, scope)
      record.closeLease = NIL
    for waiter in record.waiters:
      if record.closeError.len == 0:
        discard nativeTaskComplete(waiter, NIL, scope)
      else:
        discard nativeTaskFail(waiter, record.closeError,
          ownedClientError(scope, record.closeError),
          hasValue = true, scope = scope)
    record.waiters.setLen(0)
    if record.closeNativeActive:
      endExternalNativeOp()
      record.closeNativeActive = false
    if record.handleGone or not record.handleDelivered:
      withLock ownedMultiLock:
        ownedHttpClients.del(record.id)

  proc closeOwnedClient(record: OwnedHttpClientRecord, scope: Scope) =
    if record.phase in {ocClosing, ocClosed}:
      return
    record.phase = ocClosing
    record.closeLease = nativeNewIoCleanupLease(scope)
    beginExternalNativeOp()
    record.closeNativeActive = true
    var requests: seq[OwnedHttpPending]
    withLock ownedMultiLock:
      for pending in ownedHttpPending:
        if pending.client == record:
          requests.add pending
    for pending in requests:
      atomicStoreN(addr pending.transfer.cancelRequested, true,
                    ATOMIC_RELEASE)
      if pending.uploadReadTask.kind == vkTask and
          not pending.uploadReadTask.taskDone:
        discard nativeTaskCancel(pending.uploadReadTask, scope)
      if pending.bodyRecord != nil:
        pending.bodyRecord.closing = true
        if pending.bodyRecord.readTask.kind == vkTask and
            not pending.bodyRecord.readTask.taskDone:
          discard nativeTaskCancel(pending.bodyRecord.readTask, scope)
      if pending.task.kind == vkTask and not pending.task.taskDone:
        discard nativeTaskCancel(pending.task, scope)
    record.service.releaseOwnedMultiClient()
    record.service.ownedMultiWake()

  proc scheduleOwnedRequests(client: OwnedHttpClientRecord) =
    if client.phase != ocOpen or client.runningCount >=
        client.maxConnections:
      return
    var candidates: seq[OwnedHttpPending]
    withLock ownedMultiLock:
      for pending in ownedHttpPending:
        if pending.client == client and not pending.serviceQueued:
          candidates.add pending
    for pending in candidates:
      if client.runningCount >= client.maxConnections:
        break
      if pending.task.taskCancelled or
          int((getMonoTime() - pending.transfer.admittedAt).inMilliseconds) >=
            pending.transfer.timeoutMs:
        continue # poll retires canceled/expired queued admissions
      let running = client.runningByOrigin.getOrDefault(pending.origin)
      if running >= client.maxPerOrigin:
        continue
      pending.serviceQueued = true
      inc client.runningCount
      client.runningByOrigin[pending.origin] = running + 1
      withLock client.service.lock:
        client.service.requestJobs.add cast[pointer](pending.transfer)
        if client.service.multi != nil:
          discard gCurlMultiApi.wakeup(client.service.multi)

  proc orderedHttpHeaders(raw: string): Value =
    var pairs: seq[Value]
    for line in raw.split("\r\n"):
      if line.startsWith("HTTP/"):
        pairs.setLen(0) # final header block wins after interim 1xx
        continue
      if line.len == 0: continue
      let colon = line.find(':')
      if colon <= 0: continue
      pairs.add newList(@[newStr(line[0 ..< colon]),
                          newStr(line[colon + 1 .. ^1].strip())])
    newList(pairs)

  proc retireOwnedPending(pending: OwnedHttpPending) =
    let client = pending.client
    let scope = client.application.builtinsScope()
    if pending.lease.kind == vkTask:
      discard nativeRetireIoCleanupLease(pending.lease, scope)
    if pending.uploadReadTask.kind == vkTask and
        not pending.uploadReadTask.taskDone:
      discard nativeTaskCancel(pending.uploadReadTask, scope)
    if pending.uploadBorrowKey != 0:
      withLock ownedMultiLock:
        ownedUploadBorrows.excl(pending.uploadBorrowKey)
      pending.uploadBorrowKey = 0
    client.application.ioBudget.releaseIoBudgetBytes(pending.budgetReserved)
    if client.activeCount > 0: dec client.activeCount
    if pending.serviceQueued:
      if client.runningCount > 0: dec client.runningCount
      let running = client.runningByOrigin.getOrDefault(pending.origin)
      if running <= 1: client.runningByOrigin.del(pending.origin)
      else: client.runningByOrigin[pending.origin] = running - 1
    freeOwnedTransfer(pending.transfer)
    pending.transfer = nil
    if pending.nativeActive:
      endExternalNativeOp()
      pending.nativeActive = false
    client.scheduleOwnedRequests()

  proc ownedStreamFailure(transfer: ptr OwnedHttpTransfer): string =
    result = readSharedExecText(transfer.failure)
    if result.len == 0:
      if transfer.responseOverflow:
        result = "streamed response exceeds max_bytes"
      elif transfer.headerOverflow:
        result = "response headers exceed 256 KiB"
      elif transfer.resultCode != CurlOk:
        let detail = gCurlApi.easyStrerror(transfer.resultCode)
        result = if detail == nil: "libcurl error " & $transfer.resultCode
                 else: $detail
      elif transfer.responseStatus == 0:
        result = "HTTP response has no status"

  proc failOwnedUpload(pending: OwnedHttpPending, reason: string) =
    if pending.uploadError.len > 0:
      return
    pending.uploadError = reason
    atomicStoreN(addr pending.transfer.cancelRequested, true, ATOMIC_RELEASE)
    pending.client.service.ownedMultiWake()
    if pending.uploadReadTask.kind == vkTask and
        not pending.uploadReadTask.taskDone:
      discard nativeTaskCancel(pending.uploadReadTask,
        pending.client.application.builtinsScope())

  proc pumpOwnedUpload(pending: OwnedHttpPending) =
    let transfer = pending.transfer
    if not transfer.uploading or pending.uploadError.len > 0:
      return
    let scope = pending.client.application.builtinsScope()
    if pending.task.taskCancelled or pending.client.phase != ocOpen:
      pending.failOwnedUpload("upload was cancelled")
      return
    if not pending.serviceQueued:
      return
    if pending.uploadReadTask.kind == vkTask:
      if not pending.uploadReadTask.taskDone:
        return
      let readTask = pending.uploadReadTask
      pending.uploadReadTask = NIL
      if readTask.taskHasError or readTask.taskHasPanic or
          readTask.taskCancelled:
        pending.failOwnedUpload("AsyncReader upload read failed")
        return
      let part = readTask.taskResult
      var failure = ""
      var resume = false
      withLock transfer.uploadLock:
        if part.kind == vkNil:
          if transfer.uploadExpected >= 0 and
              transfer.uploadReadBytes != transfer.uploadExpected:
            failure = "upload ended before Content-Length"
          else:
            transfer.uploadEof = true
            resume = transfer.uploadPaused
        elif part.kind != vkBytes or part.bytesVal.len == 0:
          failure = "upload reader returned non-Bytes or empty Bytes"
        elif part.bytesVal.len > transfer.uploadBuffer.cap -
            transfer.uploadBuffer.len or
            part.bytesVal.len > transfer.uploadMaxBytes -
              transfer.uploadReadBytes or
            (transfer.uploadExpected >= 0 and
             part.bytesVal.len > transfer.uploadExpected -
               transfer.uploadReadBytes):
          failure = "upload exceeds queue, byte limit, or Content-Length"
        else:
          let size = part.bytesVal.len
          if appendHttpBuffer(transfer.uploadBuffer,
              unsafeAddr part.bytesVal[0], size) != size:
            failure = "upload queue allocation failed"
          else:
            transfer.uploadReadBytes += size
            resume = transfer.uploadPaused
      if failure.len > 0:
        pending.failOwnedUpload(failure)
        return
      if resume:
        atomicStoreN(addr transfer.uploadResumeRequested, true,
          ATOMIC_RELEASE)
        pending.client.service.ownedMultiWake()
    let workerDone = atomicLoadN(addr transfer.workerDone, ATOMIC_ACQUIRE)
    if workerDone and (transfer.resultCode != CurlOk or
        readSharedExecText(transfer.failure).len > 0):
      return
    var requested = 0
    withLock transfer.uploadLock:
      if not transfer.uploadEof:
        if transfer.uploadExpected >= 0 and
            transfer.uploadReadBytes == transfer.uploadExpected:
          requested = 1 # verify actual EOF beyond declared length
        elif transfer.uploadNeedData and not workerDone:
          requested = min(65536, transfer.uploadBuffer.cap -
            transfer.uploadBuffer.len)
          if transfer.uploadExpected >= 0:
            requested = min(requested,
              transfer.uploadExpected - transfer.uploadReadBytes)
          transfer.uploadNeedData = false
    if requested <= 0:
      return
    try:
      let ioScope = scope.application().stdlib.vars["io"].nsScope
      let message = ioScope.vars["AsyncReader"].protocolMessages["read"]
      let reader = resolveProtocolMessage(scope, message,
                                          pending.uploadReader)
      let readTask = applyCall(reader,
        [pending.uploadReader, newInt(requested)], NamedArgs(), scope)
      if readTask.kind != vkTask:
        pending.failOwnedUpload("upload reader did not return a Task")
      else:
        pending.uploadReadTask = readTask
    except CatchableError as error:
      pending.failOwnedUpload("upload read failed: " & error.msg)

  proc ownedUploadReady(pending: OwnedHttpPending): bool =
    let transfer = pending.transfer
    if not transfer.uploading or
        not atomicLoadN(addr transfer.workerDone, ATOMIC_ACQUIRE):
      return true
    if pending.uploadError.len > 0 or transfer.resultCode != CurlOk or
        readSharedExecText(transfer.failure).len > 0 or
        pending.task.taskCancelled:
      return true
    withLock transfer.uploadLock:
      if transfer.uploadEof:
        if transfer.uploadExpected >= 0 and
            transfer.uploadSentBytes != transfer.uploadExpected:
          pending.uploadError = "upload sent fewer bytes than Content-Length"
        return true
      if transfer.uploadExpected < 0 or
          transfer.uploadReadBytes != transfer.uploadExpected or
          transfer.uploadSentBytes != transfer.uploadExpected:
        pending.uploadError = "server finished before upload completed"
        return true
    if int((getMonoTime() - transfer.admittedAt).inMilliseconds) >=
        transfer.timeoutMs:
      pending.failOwnedUpload("upload EOF verification deadline expired")
      return true
    false

  proc finishOwnedBody(record: OwnedHttpBodyRecord) =
    if record.closed:
      return
    withLock ownedMultiLock:
      record.closed = true
      if atomicLoadN(addr record.handleGone, ATOMIC_ACQUIRE):
        ownedHttpBodies.del(record.id)
    let scope = record.application.builtinsScope()
    if record.lease.kind == vkTask:
      discard nativeRetireIoCleanupLease(record.lease, scope)
      record.lease = NIL
    for waiter in record.waiters:
      discard nativeTaskComplete(waiter, NIL, scope)
    record.waiters.setLen(0)

  proc drainOwnedBody(record: OwnedHttpBodyRecord): bool =
    ## Returns true once the transfer can be retired. Only the root lane calls
    ## this; the service thread touches the queue under streamLock.
    let transfer = record.transfer
    if transfer == nil:
      return true
    let scope = record.application.builtinsScope()
    let done = atomicLoadN(addr transfer.workerDone, ATOMIC_ACQUIRE)
    if record.closing or
        atomicLoadN(addr record.handleGone, ATOMIC_ACQUIRE):
      atomicStoreN(addr transfer.cancelRequested, true, ATOMIC_RELEASE)
      record.client.service.ownedMultiWake()
      if record.readTask.kind == vkTask and not record.readTask.taskDone:
        discard nativeTaskCancel(record.readTask, scope)
      if done:
        record.finishOwnedBody()
        return true
      return false
    if record.readTask.kind == vkTask and record.readTask.taskCancelled:
      record.readTask = NIL
      record.readAmount = 0
    if record.readTask.kind == vkTask and not record.readTask.taskDone:
      var chunk = ""
      var resume = false
      withLock transfer.streamLock:
        let amount = min(record.readAmount, transfer.responseBody.len)
        if amount > 0:
          chunk = newString(amount)
          copyMem(addr chunk[0], transfer.responseBody.data, amount)
          let remaining = transfer.responseBody.len - amount
          if remaining > 0:
            moveMem(transfer.responseBody.data,
              cast[pointer](cast[uint](transfer.responseBody.data) + uint(amount)),
              remaining)
          transfer.responseBody.len = remaining
          if transfer.streamPaused and
              remaining <= transfer.responseBody.cap div 2:
            resume = true
      if resume:
        atomicStoreN(addr transfer.resumeRequested, true, ATOMIC_RELEASE)
        record.client.service.ownedMultiWake()
      if chunk.len > 0:
        discard nativeTaskComplete(record.readTask, newBytes(chunk), scope)
        record.readTask = NIL
        record.readAmount = 0
      elif done:
        record.failure = transfer.ownedStreamFailure()
        if record.failure.len > 0:
          let message = "net/http_client Client stream failed: " & record.failure
          discard nativeTaskFail(record.readTask, message,
            ownedClientError(scope, message), hasValue = true, scope = scope)
        else:
          discard nativeTaskComplete(record.readTask, NIL, scope)
        record.readTask = NIL
        record.readAmount = 0
        record.finishOwnedBody()
    if done:
      var empty = false
      withLock transfer.streamLock:
        empty = transfer.responseBody.len == 0
      if empty:
        record.failure = transfer.ownedStreamFailure()
        record.finishOwnedBody()
        return true
    false

  proc deliverOwnedStreamHeaders(pending: OwnedHttpPending) =
    let transfer = pending.transfer
    let client = pending.client
    let scope = client.application.builtinsScope()
    if pending.task.taskCancelled or client.phase != ocOpen:
      atomicStoreN(addr transfer.cancelRequested, true, ATOMIC_RELEASE)
      client.service.ownedMultiWake()
      return
    var record: OwnedHttpBodyRecord
    var handle = NIL
    try:
      record = OwnedHttpBodyRecord(application: client.application,
        ownerLane: client.ownerLane, id: nextRuntimeResourceId(),
        client: client, transfer: transfer)
      record.lease = nativeNewIoCleanupLease(scope)
      withLock ownedMultiLock:
        ownedHttpBodies[record.id] = record
      handle = newRuntimeResourceHandle(scope, "OwnedHttpBody", record.id)
      var response = initPropTable()
      response["status"] = newInt(transfer.responseStatus)
      response["headers"] = orderedHttpHeaders(
        consumeHttpBuffer(transfer.responseHeaders))
      response["body"] = handle
      response["effective_url"] = newStr(readSharedExecText(transfer.url))
      if nativeTaskComplete(pending.task, newMap(response), scope):
        pending.headersDelivered = true
        pending.bodyRecord = record
        discard nativeRetireIoCleanupLease(pending.lease, scope)
        pending.lease = NIL
      else:
        discard handle.takeNodeResourceId()
        atomicStoreN(addr record.handleGone, true, ATOMIC_RELEASE)
        record.finishOwnedBody()
        atomicStoreN(addr transfer.cancelRequested, true, ATOMIC_RELEASE)
        client.service.ownedMultiWake()
    except CatchableError as error:
      let message = "net/http_client Client stream result failed: " & error.msg
      discard nativeTaskFail(pending.task, message,
        ownedClientError(scope, message), hasValue = true, scope = scope)
      if handle.kind == vkNode: discard handle.takeNodeResourceId()
      if record != nil:
        atomicStoreN(addr record.handleGone, true, ATOMIC_RELEASE)
        record.finishOwnedBody()
      atomicStoreN(addr transfer.cancelRequested, true, ATOMIC_RELEASE)
      client.service.ownedMultiWake()

  proc settleOwnedTransfer(pending: OwnedHttpPending) =
    let transfer = pending.transfer
    let client = pending.client
    let scope = client.application.builtinsScope()
    try:
      if not pending.task.taskCancelled:
        var failure = pending.uploadError
        let nativeFailure = consumeSharedExecText(transfer.failure)
        if failure.len == 0: failure = nativeFailure
        if failure.len == 0:
          if transfer.responseOverflow:
            failure = "buffered response exceeds max_bytes"
          elif transfer.headerOverflow:
            failure = "response headers exceed 256 KiB"
          elif transfer.resultCode != CurlOk:
            let detail = gCurlApi.easyStrerror(transfer.resultCode)
            failure = if detail == nil: "libcurl error " & $transfer.resultCode
                      else: $detail
          elif transfer.responseStatus == 0:
            failure = "HTTP response has no status"
        if failure.len > 0:
          let message = "net/http_client Client request failed: " & failure
          discard nativeTaskFail(pending.task, message,
            ownedClientError(scope, message), hasValue = true, scope = scope)
        else:
          var response = initPropTable()
          response["status"] = newInt(transfer.responseStatus)
          response["headers"] = orderedHttpHeaders(
            consumeHttpBuffer(transfer.responseHeaders))
          response["body"] = newBytes(consumeHttpBuffer(transfer.responseBody))
          let effective = consumeSharedExecText(transfer.effectiveUrl)
          response["effective_url"] = newStr(
            if effective.len > 0: effective else: readSharedExecText(transfer.url))
          discard nativeTaskComplete(pending.task, newMap(response), scope)
    finally:
      retireOwnedPending(pending)

  proc ownedHttpOrigin(url: string, scope: Scope): string

  proc ownedRedirectLocation(raw: string, scope: Scope): string =
    var count = 0
    for line in raw.split("\r\n"):
      if line.startsWith("HTTP/"):
        result = ""
        count = 0
        continue
      let colon = line.find(':')
      if colon > 0 and line[0 ..< colon].toLowerAscii() == "location":
        inc count
        result = line[colon + 1 .. ^1].strip()
    if count != 1 or result.len == 0:
      raiseHttpClientError("redirect has missing or ambiguous Location", scope)

  proc ownedRedirectUrl(base, location: string, scope: Scope): string =
    if location.len > 16_384:
      raiseHttpClientError("redirect Location exceeds URL limit", scope)
    for ch in location:
      if ch <= ' ' or ch == '\x7f':
        raiseHttpClientError("redirect Location contains a control or space",
          scope)
    try:
      var combined = uri.combine(uri.parseUri(base), uri.parseUri(location))
      combined.anchor = "" # fragments are not part of the request target
      if combined.scheme notin ["http", "https"] or
          combined.hostname.len == 0 or
          combined.username.len > 0 or combined.password.len > 0:
        raiseHttpClientError("redirect target must be an HTTP(S) URL " &
          "without embedded credentials", scope)
      result = $combined
      if result.len > 16_384:
        raiseHttpClientError("redirect target exceeds URL limit", scope)
      discard ownedHttpOrigin(result, scope)
    except ValueError:
      raiseHttpClientError("redirect Location is invalid", scope)

  proc followOwnedRedirect(pending: OwnedHttpPending): bool =
    let previous = pending.transfer
    let client = pending.client
    let scope = client.application.builtinsScope()
    var next: ptr OwnedHttpTransfer
    try:
      if previous.resultCode != CurlOk or
          previous.responseOverflow or previous.headerOverflow or
          readSharedExecText(previous.failure).len > 0:
        raiseHttpClientError("redirect hop failed in transport", scope)
      let oldUrl = readSharedExecText(previous.url)
      let rawHeaders = consumeHttpBuffer(previous.responseHeaders)
      let location = ownedRedirectLocation(rawHeaders, scope)
      let nextUrl = ownedRedirectUrl(oldUrl, location, scope)
      if oldUrl.startsWith("https://") and nextUrl.startsWith("http://"):
        raiseHttpClientError("redirect from HTTPS to HTTP is forbidden", scope)
      let nextOrigin = ownedHttpOrigin(nextUrl, scope)
      let crossOrigin = pending.origin != nextOrigin
      next = cast[ptr OwnedHttpTransfer](allocShared0(sizeof(OwnedHttpTransfer)))
      next.httpMethod = sharedExecText(readSharedExecText(previous.httpMethod))
      next.url = sharedExecText(nextUrl)
      next.requestTarget = sharedExecText(httpRequestTarget(nextUrl))
      next.caData = sharedExecText(readSharedExecText(previous.caData))
      next.proxy = sharedExecText(
        if client.proxy == "environment":
          if nextUrl.startsWith("https://"): client.environmentHttpsProxy
          else: client.environmentHttpProxy
        else: client.proxy)
      next.noProxy = sharedExecText(readSharedExecText(previous.noProxy))
      next.timeoutMs = previous.timeoutMs
      next.connectTimeoutMs = previous.connectTimeoutMs
      next.maxIdleMs = previous.maxIdleMs
      next.maxBytes = previous.maxBytes
      next.admittedAt = previous.admittedAt
      next.streaming = previous.streaming
      if next.streaming: initLock(next.streamLock)
      next.responseBody.cap = previous.responseBody.cap
      next.responseHeaders.cap = 256 * 1024
      next.redirectRemaining = previous.redirectRemaining - 1
      next.redirectEligible = true
      var headerTail: ptr SharedExecArg
      var header = previous.headers
      while header != nil:
        let value = readSharedExecText(header.text)
        let colon = value.find(':')
        let name = if colon > 0: value[0 ..< colon].toLowerAscii() else: ""
        if name != "host" and
            (not crossOrigin or name notin ["authorization", "cookie"]):
          let node = cast[ptr SharedExecArg](allocShared0(sizeof(SharedExecArg)))
          node.text = sharedExecText(value)
          if headerTail == nil: next.headers = node
          else: headerTail.next = node
          headerTail = node
        header = header.next
      if client.runningCount > 0: dec client.runningCount
      let oldRunning = client.runningByOrigin.getOrDefault(pending.origin)
      if oldRunning <= 1: client.runningByOrigin.del(pending.origin)
      else: client.runningByOrigin[pending.origin] = oldRunning - 1
      pending.serviceQueued = false
      pending.origin = nextOrigin
      pending.transfer = next
      next = nil
      freeOwnedTransfer(previous)
      client.scheduleOwnedRequests()
      result = true
    except CatchableError as error:
      if next != nil: freeOwnedTransfer(next)
      if not pending.task.taskCancelled:
        let message = "net/http_client Client redirect failed: " & error.msg
        discard nativeTaskFail(pending.task, message,
          ownedClientError(scope, message), hasValue = true, scope = scope)

  proc retireOwnedClientOpen(record: OwnedHttpClientRecord, scope: Scope) =
    if record.openLease.kind == vkTask:
      discard nativeRetireIoCleanupLease(record.openLease, scope)
    record.openLease = NIL
    record.openTask = NIL
    record.openScope = nil
    if record.openNativeActive:
      endExternalNativeOp()
      record.openNativeActive = false

  proc pollOwnedHttpClientCompletions() =
    var uploads: seq[OwnedHttpPending]
    withLock ownedMultiLock:
      for pending in ownedHttpPending:
        if pending.transfer.uploading and
            pending.client.service.schedulerPtr ==
              cast[pointer](currentScheduler()):
          uploads.add pending
    for pending in uploads:
      pending.pumpOwnedUpload()
    var completed: seq[OwnedHttpPending]
    var queuedDone: seq[OwnedHttpPending]
    var streams: seq[OwnedHttpPending]
    var redirects: seq[OwnedHttpPending]
    withLock ownedMultiLock:
      var index = 0
      while index < ownedHttpPending.len:
        let pending = ownedHttpPending[index]
        if pending.client.service.schedulerPtr ==
            cast[pointer](currentScheduler()):
          if pending.streaming and pending.serviceQueued:
            streams.add pending
            inc index
            continue
          if pending.serviceQueued and
              atomicLoadN(addr pending.transfer.workerDone, ATOMIC_ACQUIRE):
            if not pending.ownedUploadReady():
              inc index
              continue
            if pending.transfer.redirectResponse and
                not pending.task.taskCancelled and
                pending.client.phase == ocOpen:
              redirects.add pending
              inc index
              continue
            completed.add pending
            ownedHttpPending.delete(index)
            continue
          if not pending.serviceQueued and
              (pending.task.taskCancelled or pending.client.phase != ocOpen or
               int((getMonoTime() -
                    pending.transfer.admittedAt).inMilliseconds) >=
                 pending.transfer.timeoutMs):
            queuedDone.add pending
            ownedHttpPending.delete(index)
            continue
          inc index
        else:
          inc index
    for pending in queuedDone:
      let scope = pending.client.application.builtinsScope()
      if not pending.task.taskCancelled:
        let message = "HTTP request expired while waiting for admission"
        discard nativeTaskFail(pending.task, message,
          ownedClientError(scope, message), hasValue = true, scope = scope)
      retireOwnedPending(pending)
    for pending in completed:
      settleOwnedTransfer(pending)
    for pending in redirects:
      if not followOwnedRedirect(pending):
        withLock ownedMultiLock:
          for index in 0 ..< ownedHttpPending.len:
            if ownedHttpPending[index] == pending:
              ownedHttpPending.delete(index)
              break
        retireOwnedPending(pending)
    for pending in streams:
      let transfer = pending.transfer
      if transfer.redirectResponse and not pending.headersDelivered:
        if atomicLoadN(addr transfer.workerDone, ATOMIC_ACQUIRE):
          if pending.client.phase == ocOpen and
              not pending.task.taskCancelled and
              followOwnedRedirect(pending):
            continue
          withLock ownedMultiLock:
            for index in 0 ..< ownedHttpPending.len:
              if ownedHttpPending[index] == pending:
                ownedHttpPending.delete(index)
                break
          retireOwnedPending(pending)
        elif pending.task.taskCancelled:
          atomicStoreN(addr transfer.cancelRequested, true, ATOMIC_RELEASE)
          pending.client.service.ownedMultiWake()
        continue
      if not pending.headersDelivered and
          atomicLoadN(addr transfer.headersReady, ATOMIC_ACQUIRE):
        deliverOwnedStreamHeaders(pending)
      if atomicLoadN(addr transfer.workerDone, ATOMIC_ACQUIRE) and
          not pending.ownedUploadReady():
        continue
      if pending.uploadError.len > 0 and
          atomicLoadN(addr transfer.workerDone, ATOMIC_ACQUIRE) and
          readSharedExecText(transfer.failure).len == 0:
        transfer.failure = sharedExecText(pending.uploadError)
      var retire = false
      if pending.headersDelivered:
        retire = pending.bodyRecord.drainOwnedBody()
      elif atomicLoadN(addr transfer.workerDone, ATOMIC_ACQUIRE):
        if not pending.task.taskCancelled:
          let reason = transfer.ownedStreamFailure()
          let message = "net/http_client Client stream failed before headers: " &
            (if reason.len > 0: reason else: "no final HTTP headers")
          let scope = pending.client.application.builtinsScope()
          discard nativeTaskFail(pending.task, message,
            ownedClientError(scope, message), hasValue = true, scope = scope)
        retire = true
      elif pending.task.taskCancelled:
        atomicStoreN(addr transfer.cancelRequested, true, ATOMIC_RELEASE)
        pending.client.service.ownedMultiWake()
      if retire:
        if pending.bodyRecord != nil:
          pending.bodyRecord.transfer = nil
        withLock ownedMultiLock:
          for index in 0 ..< ownedHttpPending.len:
            if ownedHttpPending[index] == pending:
              ownedHttpPending.delete(index)
              break
        retireOwnedPending(pending)
    var records: seq[OwnedHttpClientRecord]
    withLock ownedMultiLock:
      for _, record in ownedHttpClients:
        if record.service.schedulerPtr == cast[pointer](currentScheduler()):
          records.add record
    for record in records:
      let scope = record.application.builtinsScope()
      let service = record.service
      if record.phase == ocOpening and
          atomicLoadN(addr service.ready, ATOMIC_ACQUIRE):
        if record.openTask.taskCancelled or
            atomicLoadN(addr service.failed, ATOMIC_ACQUIRE):
          if not record.openTask.taskCancelled:
            let message = "net/http_client/open transport setup failed"
            discard nativeTaskFail(record.openTask, message,
              ownedClientError(scope, message), hasValue = true, scope = scope)
          if record.caJob == nil or
              atomicLoadN(addr record.caJob.done, ATOMIC_ACQUIRE):
            if record.caJob != nil:
              discard consumeSharedExecText(record.caJob.path)
              discard consumeSharedExecText(record.caJob.data)
              discard consumeSharedExecText(record.caJob.failure)
              deallocShared(record.caJob)
              record.caJob = nil
            record.retireOwnedClientOpen(scope)
            record.closeOwnedClient(scope)
        elif record.caPath.len > 0 and record.caJob == nil:
          record.caJob = cast[ptr MultiCaLoadJob](allocShared0(sizeof(MultiCaLoadJob)))
          record.caJob.path = sharedExecText(record.caPath)
          withLock service.lock:
            service.caJobs.add cast[pointer](record.caJob)
            if service.multi != nil:
              discard gCurlMultiApi.wakeup(service.multi)
        elif record.caJob != nil and
            not atomicLoadN(addr record.caJob.done, ATOMIC_ACQUIRE):
          discard
        else:
          var caFailure = ""
          if record.caJob != nil:
            caFailure = consumeSharedExecText(record.caJob.failure)
            record.caData = consumeSharedExecText(record.caJob.data)
            discard consumeSharedExecText(record.caJob.path)
            deallocShared(record.caJob)
            record.caJob = nil
          if caFailure.len > 0:
            let message = "net/http_client/open ^ca_file: " & caFailure
            discard nativeTaskFail(record.openTask, message,
              ownedClientError(scope, message), hasValue = true, scope = scope)
            record.retireOwnedClientOpen(scope)
            record.closeOwnedClient(scope)
          else:
            var handle = NIL
            var delivered = false
            try:
              handle = newRuntimeResourceHandle(scope,
                "OwnedHttpClient", record.id)
              delivered = nativeTaskComplete(record.openTask, handle, scope)
            except CatchableError as error:
              let message = "net/http_client/open result failed: " & error.msg
              discard nativeTaskFail(record.openTask, message,
                ownedClientError(scope, message), hasValue = true, scope = scope)
            if delivered:
              record.phase = ocOpen
              record.handleDelivered = true
            else:
              if handle.kind == vkNode:
                discard handle.takeNodeResourceId()
              record.closeOwnedClient(scope)
            record.retireOwnedClientOpen(scope)
      if record.phase == ocOpen and record.abandoned:
        record.closeOwnedClient(scope)
      if record.phase == ocClosing and
          record.activeCount == 0 and
          atomicLoadN(addr service.stopped, ATOMIC_ACQUIRE):
        if service.thread != nil:
          joinThread(service.thread[])
          service.thread = nil
        withLock ownedMultiLock:
          let current = ownedMultiServices.getOrDefault(
            cast[pointer](record.application))
          if current == service:
            ownedMultiServices.del(cast[pointer](record.application))
        record.settleOwnedClientClosed()
      elif record.phase == ocClosing and record.activeCount == 0:
        var others = 0
        withLock service.lock:
          others = service.clientCount
        if others > 0:
          record.settleOwnedClientClosed()
      if record.phase == ocClosed and record.handleGone:
        withLock ownedMultiLock:
          ownedHttpClients.del(record.id)

  proc ownedClientRecord(value: Value, scope: Scope,
                         operation: string): OwnedHttpClientRecord =
    let namespace = scope.application().stdlib.vars["net"].nsScope.vars[
      "http_client"].nsScope
    let expected = namespace.vars["Client"]
    if value.kind != vkNode or value.head.bits != expected.bits:
      raiseTypeError("http_client " & operation, "Client", value, scope)
    withLock ownedMultiLock:
      result = ownedHttpClients.getOrDefault(value.nodeResourceId)
    if result == nil or result.application != scope.application():
      raiseHttpClientError("HTTP Client is unavailable", scope)
    if result.ownerLane != currentEventLane():
      raiseValueSemanticError("RuntimeLaneError",
        "HTTP Client belongs to another lane")

  proc ownedBodyRecord(value: Value, scope: Scope,
                       operation: string): OwnedHttpBodyRecord =
    let namespace = scope.application().stdlib.vars["net"].nsScope.vars[
      "http_client"].nsScope
    let expected = namespace.vars["BodyReader"]
    if value.kind != vkNode or value.head.bits != expected.bits:
      raiseTypeError("http_client " & operation, "BodyReader", value, scope)
    withLock ownedMultiLock:
      result = ownedHttpBodies.getOrDefault(value.nodeResourceId)
    if result == nil or result.application != scope.application():
      raiseHttpClientError("HTTP body reader is unavailable", scope)
    if result.ownerLane != currentEventLane():
      raiseValueSemanticError("RuntimeLaneError",
        "HTTP body reader belongs to another lane")

  proc biOwnedHttpBodyRead(args: openArray[Value],
                           call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if args.len != 2:
      raiseHttpClientError("BodyReader.read expects max_bytes", scope)
    let record = ownedBodyRecord(args[0], scope, "read")
    let amount = requireInt64("BodyReader.read max_bytes", args[1])
    if amount < 1 or amount > 1_048_576:
      raiseHttpClientError("read max_bytes must be within 1..1048576", scope)
    if record.closing:
      raiseIoTestingError(scope, "IoClosed", "read", record.id,
        "HTTP body reader is closing")
    if record.closed:
      if record.failure.len > 0:
        let message = "net/http_client Client stream failed: " & record.failure
        return newFailedTask(message, ownedClientError(scope, message),
          hasValue = true)
      return newCompletedTask(NIL)
    if record.readTask.kind == vkTask and not record.readTask.taskDone:
      raiseIoTestingError(scope, "IoBusy", "read", record.id,
        "HTTP body reader already has a pending read")
    result = newExternalTask()
    scope.registerIoTask(result)
    record.readTask = result
    record.readAmount = int(amount)
    discard record.drainOwnedBody()

  proc biOwnedHttpBodyClose(args: openArray[Value],
                            call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if args.len != 1:
      raiseHttpClientError("BodyReader.close expects one receiver", scope)
    let record = ownedBodyRecord(args[0], scope, "close")
    if not record.closed and not record.closing:
      record.closing = true
      if record.readTask.kind == vkTask and not record.readTask.taskDone:
        discard nativeTaskCancel(record.readTask, scope)
      if record.transfer != nil:
        atomicStoreN(addr record.transfer.cancelRequested, true,
          ATOMIC_RELEASE)
        record.client.service.ownedMultiWake()
    NIL

  proc biOwnedHttpBodyWaitClosed(args: openArray[Value],
                                 call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if args.len != 1:
      raiseHttpClientError("BodyReader.wait_closed expects one receiver", scope)
    let record = ownedBodyRecord(args[0], scope, "wait_closed")
    if record.closed:
      return newCompletedTask(NIL)
    result = newExternalTask()
    scope.registerIoTask(result)
    record.waiters.add result

  proc biOwnedHttpClientOpen(args: openArray[Value],
                             call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if scope == nil or args.len != 0:
      raiseHttpClientError("net/http_client/open expects named options only",
                           scope)
    if currentEventLane() != schedulerForScope(scope).rootLane:
      raiseValueSemanticError("RuntimeLaneError",
        "HTTP Client open requires the root lane")
    var record = OwnedHttpClientRecord(application: scope.application(),
      ownerLane: currentEventLane(), id: nextRuntimeResourceId(),
      phase: ocOpening, openScope: scope,
      runningByOrigin: initTable[string, int](),
      maxConnections: 16, maxPerOrigin: 8, maxPendingRequests: 64,
      maxIdleMs: 30000, connectTimeoutMs: 10000, timeoutMs: 30000,
      maxBufferedBodyBytes: 8 * 1024 * 1024,
      maxStreamBodyBytes: 64 * 1024 * 1024)
    var seen = initHashSet[string]()
    for i, name in call[].namedNames:
      if name in seen:
        raiseHttpClientError("duplicate open option: " & name, scope)
      seen.incl name
      let value = call[].namedValues[i]
      case name
      of "max_connections":
        record.maxConnections = int(requireInt64(name, value))
      of "max_connections_per_origin":
        record.maxPerOrigin = int(requireInt64(name, value))
      of "max_pending_requests":
        record.maxPendingRequests = int(requireInt64(name, value))
      of "max_idle_ms":
        record.maxIdleMs = int(requireInt64(name, value))
      of "connect_timeout_ms":
        record.connectTimeoutMs = int(requireInt64(name, value))
      of "timeout_ms":
        record.timeoutMs = int(requireInt64(name, value))
      of "max_buffered_body_bytes":
        record.maxBufferedBodyBytes = int(requireInt64(name, value))
      of "max_stream_body_bytes":
        record.maxStreamBodyBytes = int(requireInt64(name, value))
      of "redirects":
        record.redirects = int(requireInt64(name, value))
      of "proxy":
        if value.kind != vkNil:
          requireStr("http_client/open ^proxy", value)
          record.proxy = value.strVal
          if record.proxy != "environment" and
              not (record.proxy.startsWith("http://") or
                   record.proxy.startsWith("https://")):
            raiseHttpClientError("proxy must be nil, an HTTP(S) URL, or " &
              "environment", scope)
          if record.proxy == "environment":
            record.environmentHttpProxy = getEnv("http_proxy",
              getEnv("HTTP_PROXY"))
            record.environmentHttpsProxy = getEnv("https_proxy",
              getEnv("HTTPS_PROXY"))
            record.environmentNoProxy = getEnv("no_proxy",
              getEnv("NO_PROXY"))
      of "ca_file":
        if value.kind != vkNil:
          requireStr("http_client/open ^ca_file", value)
          record.caPath = value.strVal
          if record.caPath.len == 0 or record.caPath.len > 4096 or
              '\0' in record.caPath:
            raiseHttpClientError("ca_file path is invalid", scope)
      else:
        raiseHttpClientError("unexpected open option: " & name, scope)
    if record.maxConnections < 1 or record.maxConnections > 128 or
        record.maxPerOrigin < 1 or
        record.maxPerOrigin > record.maxConnections or
        record.maxPendingRequests < 1 or record.maxPendingRequests > 1024 or
        record.maxIdleMs < 0 or record.maxIdleMs > 300000 or
        record.connectTimeoutMs < 1 or record.connectTimeoutMs > 300000 or
        record.timeoutMs < 1 or record.timeoutMs > 86400000 or
        record.maxBufferedBodyBytes < 1 or
        record.maxBufferedBodyBytes > 64 * 1024 * 1024 or
        record.maxStreamBodyBytes < 1 or
        record.maxStreamBodyBytes > 1024 * 1024 * 1024 or
        record.redirects < 0 or record.redirects > 20:
      raiseHttpClientError("HTTP Client open limits are invalid", scope)
    if record.caPath.len > 0 and not isAbsolute(record.caPath):
      record.caPath = absolutePath(record.caPath,
                                   scope.application().launchDir)
    loadCurlMultiApi(scope)
    let operation = nativeNewIoOperation(scope)
    record.openTask = operation.task
    record.openLease = operation.cleanupLease
    beginExternalNativeOp()
    record.openNativeActive = true
    record.service = ensureOwnedMultiService(record.application,
      record.maxConnections, record.maxPerOrigin)
    withLock ownedMultiLock:
      ownedHttpClients[record.id] = record
    operation.task

  proc ownedHttpOrigin(url: string, scope: Scope): string =
    try:
      let parsed = uri.parseUri(url)
      if parsed.hostname.len == 0:
        raiseHttpClientError("request URL has no host", scope)
      if parsed.username.len > 0 or parsed.password.len > 0:
        raiseHttpClientError("request URL embeds credentials", scope)
      var port = if parsed.scheme == "https": 443 else: 80
      if parsed.port.len > 0:
        port = parseInt(parsed.port)
      if port < 1 or port > 65535:
        raiseHttpClientError("request URL port is invalid", scope)
      result = parsed.scheme.toLowerAscii() & "://" &
        parsed.hostname.toLowerAscii() & ":" & $port
    except ValueError:
      raiseHttpClientError("request URL authority is invalid", scope)

  proc startOwnedHttpClientRequest(args: openArray[Value],
                                   call: ptr NativeCall,
                                   streaming: bool): Value =
    let scope = if call == nil: nil else: call[].dispatchScope
    if scope == nil or args.len != 1:
      raiseHttpClientError("Client.request expects named options", scope)
    let client = ownedClientRecord(args[0], scope, "request")
    if client.phase != ocOpen or
        atomicLoadN(addr client.service.failed, ATOMIC_ACQUIRE) or
        atomicLoadN(addr client.service.stopped, ATOMIC_ACQUIRE):
      raiseHttpClientError("HTTP Client is closed or its transport failed",
                           scope)
    if client.activeCount >= client.maxPendingRequests:
      raiseHttpClientError("HTTP Client pending request limit reached", scope)
    var applicationPending = 0
    withLock ownedMultiLock:
      for pending in ownedHttpPending:
        if pending.client.application == client.application:
          inc applicationPending
    if applicationPending >= OwnedHttpApplicationPendingLimit:
      raiseIoTestingError(scope, "IoBackpressure", "http_client/request",
        client.id, "Application HTTP request queue is full")
    var url = ""
    var httpMethod = "GET"
    var headers: seq[string]
    var body = ""
    var bodyProvided = false
    var uploadReader = NIL
    var contentLength = -1
    var timeoutMs = client.timeoutMs
    var maxBytes = if streaming: client.maxStreamBodyBytes
                   else: client.maxBufferedBodyBytes
    var seen = initHashSet[string]()
    for i, name in call[].namedNames:
      if name in seen:
        raiseHttpClientError("duplicate request option: " & name, scope)
      seen.incl name
      let value = call[].namedValues[i]
      case name
      of "method":
        requireStr("Client.request ^method", value)
        httpMethod = value.strVal
      of "url":
        requireStr("Client.request ^url", value)
        url = value.strVal
      of "headers":
        case value.kind
        of vkMap:
          for key, item in value.mapEntries:
            if item.kind != vkString:
              raiseHttpClientError("header values must be Str", scope)
            headers.add key & ": " & item.strVal
        of vkList:
          for pair in value.listItems:
            if pair.kind != vkList or pair.listItems.len != 2 or
                pair.listItems[0].kind != vkString or
                pair.listItems[1].kind != vkString:
              raiseHttpClientError("headers must be [name value] pairs",
                                   scope)
            headers.add pair.listItems[0].strVal & ": " &
                        pair.listItems[1].strVal
        else:
          raiseHttpClientError("headers must be a Map or pair List", scope)
      of "body":
        case value.kind
        of vkNil: discard
        of vkString:
          body = value.strVal
          bodyProvided = true
        of vkBytes:
          body = value.bytesVal
          bodyProvided = true
        else:
          let ioScope = scope.application().stdlib.vars["io"].nsScope
          if not scope.typeImplementsProtocol(projectHead(value),
                                              ioScope.vars["AsyncReader"]):
            raiseHttpClientError("body must be nil, Str, Bytes, or " &
              "AsyncReader", scope)
          uploadReader = value
          bodyProvided = true
      of "content_length":
        contentLength = int(requireInt64("Client.request ^content_length",
                                         value))
      of "timeout_ms":
        timeoutMs = int(requireInt64("Client.request ^timeout_ms", value))
      of "max_bytes":
        maxBytes = int(requireInt64("Client.request ^max_bytes", value))
      else:
        raiseHttpClientError("unexpected request option: " & name, scope)
    if not validHttpMethod(httpMethod) or
        not (url.startsWith("http://") or url.startsWith("https://")) or
        url.len > 16_384 or '\0' in url or '\r' in url or '\n' in url:
      raiseHttpClientError("request method or URL is invalid", scope)
    if timeoutMs < 1 or timeoutMs > client.timeoutMs or
        maxBytes < 1 or maxBytes >
          (if streaming: client.maxStreamBodyBytes
           else: client.maxBufferedBodyBytes) or
        body.len > client.maxBufferedBodyBytes or
        (uploadReader.kind != vkNil and
          (httpMethod == "HEAD" or
           contentLength > client.maxStreamBodyBytes)) or
        contentLength < -1 or
        (uploadReader.kind == vkNil and contentLength >= 0 and
          contentLength != body.len):
      raiseHttpClientError("request byte limits or Content-Length are invalid",
                           scope)
    if headers.len > 256:
      raiseHttpClientError("request accepts at most 256 headers", scope)
    var headerBytes = 0
    for header in headers:
      let colon = header.find(':')
      if colon <= 0:
        raiseHttpClientError("request header name is invalid", scope)
      let name = header[0 ..< colon]
      if name.toLowerAscii() in
          ["content-length", "transfer-encoding", "connection", "expect",
           "proxy-authorization"]:
        raiseHttpClientError("request framing header is reserved", scope)
      for ch in name:
        if not (ch in {'A'..'Z', 'a'..'z', '0'..'9'} or
                ch in "!#$%&'*+-.^_`|~"):
          raiseHttpClientError("request header name is invalid", scope)
      for ch in header[colon + 1 .. ^1]:
        if ch == '\r' or ch == '\n' or ch == '\x7f' or
            (ch < ' ' and ch != '\t'):
          raiseHttpClientError("request header value is invalid", scope)
      headerBytes += header.len + 2
      if headerBytes > 256 * 1024:
        raiseHttpClientError("request headers exceed 256 KiB", scope)
    let queueBytes = if streaming: min(maxBytes, 1024 * 1024) else: maxBytes
    let uploadQueueBytes = if uploadReader.kind != vkNil: 64 * 1024 else: 0
    let reserveBytes = queueBytes + uploadQueueBytes + body.len +
      client.caData.len
    let origin = ownedHttpOrigin(url, scope)
    if uploadReader.kind != vkNil:
      withLock ownedMultiLock:
        if uploadReader.bits in ownedUploadBorrows:
          raiseIoTestingError(scope, "IoBusy", "http_client/upload",
            client.id, "AsyncReader already belongs to an owned upload")
    if not client.application.ioBudget.reserveIoBudgetBytes(reserveBytes):
      raiseIoTestingError(scope, "IoBackpressure", "http_client/request",
        client.id, "Application I/O byte budget is full")
    let operation = nativeNewIoOperation(scope)
    let transfer = cast[ptr OwnedHttpTransfer](
      allocShared0(sizeof(OwnedHttpTransfer)))
    transfer.httpMethod = sharedExecText(httpMethod)
    transfer.url = sharedExecText(url)
    transfer.requestTarget = sharedExecText(httpRequestTarget(url))
    transfer.body = sharedExecText(body)
    transfer.bodyProvided = bodyProvided
    transfer.uploading = uploadReader.kind != vkNil
    if transfer.uploading:
      initLock(transfer.uploadLock)
      transfer.uploadBuffer.cap = uploadQueueBytes
      transfer.uploadExpected = contentLength
      transfer.uploadMaxBytes = client.maxStreamBodyBytes
    transfer.caData = sharedExecText(client.caData)
    let proxy =
      if client.proxy == "environment":
        if url.startsWith("https://"): client.environmentHttpsProxy
        else: client.environmentHttpProxy
      else: client.proxy
    transfer.proxy = sharedExecText(proxy)
    transfer.noProxy = sharedExecText(
      if client.proxy == "environment": client.environmentNoProxy else: "")
    transfer.timeoutMs = timeoutMs
    transfer.connectTimeoutMs = client.connectTimeoutMs
    transfer.maxIdleMs = client.maxIdleMs
    transfer.maxBytes = maxBytes
    transfer.redirectRemaining = client.redirects
    transfer.redirectEligible = httpMethod in ["GET", "HEAD"] and
      not bodyProvided
    transfer.streaming = streaming
    if streaming: initLock(transfer.streamLock)
    transfer.admittedAt = getMonoTime()
    transfer.responseBody.cap = queueBytes
    transfer.responseHeaders.cap = 256 * 1024
    var headerTail: ptr SharedExecArg
    for header in headers:
      let node = cast[ptr SharedExecArg](allocShared0(sizeof(SharedExecArg)))
      node.text = sharedExecText(header)
      if headerTail == nil:
        transfer.headers = node
      else:
        headerTail.next = node
      headerTail = node
    let pending = OwnedHttpPending(transfer: transfer, client: client,
      task: operation.task, lease: operation.cleanupLease,
      scope: scope, budgetReserved: reserveBytes, origin: origin,
      streaming: streaming, uploadReader: uploadReader,
      uploadBorrowKey: (if uploadReader.kind != vkNil:
        uploadReader.bits else: 0'u64))
    beginExternalNativeOp()
    pending.nativeActive = true
    inc client.activeCount
    withLock ownedMultiLock:
      if pending.uploadBorrowKey != 0:
        ownedUploadBorrows.incl(pending.uploadBorrowKey)
      ownedHttpPending.add pending
    client.scheduleOwnedRequests()
    operation.task

  proc biOwnedHttpClientRequest(args: openArray[Value],
                                call: ptr NativeCall): Value {.nimcall.} =
    startOwnedHttpClientRequest(args, call, false)

  proc biOwnedHttpClientStream(args: openArray[Value],
                               call: ptr NativeCall): Value {.nimcall.} =
    startOwnedHttpClientRequest(args, call, true)

  proc biOwnedHttpClientClose(args: openArray[Value],
                              call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if args.len != 1:
      raiseHttpClientError("Client close expects one receiver", scope)
    let record = ownedClientRecord(args[0], scope, "close")
    record.closeOwnedClient(scope)
    NIL

  proc biOwnedHttpClientWaitClosed(args: openArray[Value],
                                   call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if args.len != 1:
      raiseHttpClientError("Client wait_closed expects one receiver", scope)
    let record = ownedClientRecord(args[0], scope, "wait_closed")
    if record.phase == ocClosed:
      if record.closeError.len == 0:
        return newCompletedTask(NIL)
      return newFailedTask(record.closeError,
        ownedClientError(scope, record.closeError), hasValue = true)
    result = newExternalTask()
    scope.registerIoTask(result)
    record.waiters.add result

  proc releaseOwnedHttpClientRecord(id: uint64) {.raises: [].} =
    var retired: OwnedHttpClientRecord
    withLock ownedMultiLock:
      let record = ownedHttpClients.getOrDefault(id)
      if record != nil:
        record.handleGone = true
        if record.phase == ocClosed:
          discard ownedHttpClients.pop(id, retired)
        else:
          record.abandoned = true
    reset(retired)

  proc releaseOwnedHttpBodyRecord(id: uint64) {.raises: [].} =
    var retired: OwnedHttpBodyRecord
    withLock ownedMultiLock:
      let record = ownedHttpBodies.getOrDefault(id)
      if record != nil:
        atomicStoreN(addr record.handleGone, true, ATOMIC_RELEASE)
        if record.closed:
          discard ownedHttpBodies.pop(id, retired)
    reset(retired)

else:
  proc pollOwnedHttpClientCompletions() = discard
  proc releaseOwnedHttpClientRecord(id: uint64) {.raises: [].} = discard
  proc releaseOwnedHttpBodyRecord(id: uint64) {.raises: [].} = discard
  proc ownedHttpClientOpenCount(app: Application): int = 0
  proc ownedHttpClientPendingCount(app: Application): int = 0

  proc biOwnedHttpClientOpen(args: openArray[Value],
                             call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    try:
      raiseHttpClientError("owned HTTP Client requires a threaded native VM",
                           scope, kind = "unavailable")
    except GeneError as error:
      return newFailedTask(error.msg, error.errVal, hasValue = true)

  proc biOwnedHttpClientClose(args: openArray[Value],
                              call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "HTTP Client is unavailable")

  proc biOwnedHttpClientWaitClosed(args: openArray[Value],
                                   call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "HTTP Client is unavailable")
  proc biOwnedHttpClientRequest(args: openArray[Value],
                                call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "HTTP Client is unavailable")
  proc biOwnedHttpClientStream(args: openArray[Value],
                               call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "HTTP Client is unavailable")
  proc biOwnedHttpBodyRead(args: openArray[Value],
                           call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "HTTP body reader is unavailable")
  proc biOwnedHttpBodyClose(args: openArray[Value],
                            call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "HTTP body reader is unavailable")
  proc biOwnedHttpBodyWaitClosed(args: openArray[Value],
                                 call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "HTTP body reader is unavailable")
