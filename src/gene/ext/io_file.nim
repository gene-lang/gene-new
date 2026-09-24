## Worker-backed POSIX file reader. Workers own only shared native buffers and
## file descriptors. The root lane owns Gene Tasks, lifecycle tickets, and
## Type values, and polls completions through pollOsExecAsyncCompletions.

when compileOption("threads") and defined(posix) and
    not defined(geneWasm) and not defined(emscripten):
  import std/nativesockets
  {.emit: """
#include <signal.h>
#include <pthread.h>
static void gene_io_file_block_sigpipe(void) {
  sigset_t blocked;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &blocked, NULL);
}
""".}
  proc blockIoFileSigpipe() {.importc: "gene_io_file_block_sigpipe", nodecl.}

  type
    IoFileJobKind = enum
      ifjOpenRead, ifjOpenWrite, ifjRead, ifjWrite, ifjFlush,
      ifjTcpConnect, ifjTcpListen, ifjTcpAccept,
      ifjClose, ifjDiscardOpen

    IoFileJob = object
      kind: IoFileJobKind
      fd: cint
      path: pointer
      buffer: pointer
      requested: int
      openFlags: cint
      connectPort: int
      connectTimeoutMs: int
      listenBacklog: int
      pipeEndpoint: bool
      cancelRequested: bool
      resultFd: cint
      resultPort: int
      resultCount: int
      errorCode: cint
      workerDone: bool

    IoFileRecord = ref object
      application: Application
      ownerLane: int
      lifecycle: IoLifecycle
      fd: cint
      writer: bool
      duplex: bool
      listener: bool
      localPort: int
      pipeEndpoint: bool
      eof: bool
      handleGone: bool
      closeQueued: bool
      readTicket: IoTicket
      readTask, readLease, closeLease: Value
      readJob: ptr IoFileJob
      writeTicket: IoTicket
      writeTask, writeLease: Value
      writeJob: ptr IoFileJob
      waiters: seq[Value]
      closeError: string
      closeErrorCode: cint

    IoFilePending = ref object
      job: ptr IoFileJob
      record: IoFileRecord
      task, lease: Value
      ticket: IoTicket
      ownerLane: int

  const
    IoFileMaxWorkers = 16
    IoFileMaxQueued = 1024

  var ioFileLock: Lock
  var ioFileCond: Cond
  var ioFileReadyCond: Cond
  var ioFileQueue: seq[pointer]
  var ioFileWaitQueue: seq[pointer] # nonblocking pipe jobs parked in poll(2)
  var ioFilePending: seq[IoFilePending]
  var ioFileThreads: seq[ref Thread[void]]
  var ioFileReadinessThread: ref Thread[void]
  var ioFileReadinessStarted = false
  var ioFileIdle = 0
  var ioFileRecords = initTable[uint64, IoFileRecord]()
  initLock(ioFileLock)
  initCond(ioFileCond)
  initCond(ioFileReadyCond)

  proc ioFileWaitingCount(): int =
    withLock ioFileLock:
      result = ioFileWaitQueue.len

  proc ioFileOpenCount(app: Application): int =
    withLock ioFileLock:
      for _, record in ioFileRecords:
        if record.application == app and
            record.lifecycle.ioSnapshot().phase != iopClosed:
          inc result

  proc newIoFileJob(kind: IoFileJobKind): ptr IoFileJob =
    result = cast[ptr IoFileJob](allocShared0(sizeof(IoFileJob)))
    result.kind = kind
    result.fd = -1
    result.resultFd = -1

  proc freeIoFileJob(job: ptr IoFileJob) =
    if job == nil: return
    if job.path != nil: deallocShared(job.path)
    if job.buffer != nil: deallocShared(job.buffer)
    deallocShared(job)

  proc runIoFileJob(job: ptr IoFileJob) {.gcsafe.} =
    {.cast(gcsafe).}:
      case job.kind
      of ifjOpenRead:
        let fd = posix.open(cast[cstring](job.path), O_RDONLY or O_CLOEXEC, 0)
        if fd < 0: job.errorCode = errno
        else: job.resultFd = fd
      of ifjOpenWrite:
        let fd = posix.open(cast[cstring](job.path), job.openFlags, 0o600)
        if fd < 0: job.errorCode = errno
        else: job.resultFd = fd
      of ifjRead:
        let count = posix.read(job.fd, job.buffer, job.requested)
        if count < 0: job.errorCode = errno
        else: job.resultCount = count
      of ifjWrite:
        let count = posix.write(job.fd, job.buffer, job.requested)
        if count < 0: job.errorCode = errno
        else: job.resultCount = count
      of ifjFlush:
        if fsync(job.fd) != 0:
          job.errorCode = errno
      of ifjTcpConnect:
        let host = $cast[cstring](job.path)
        let first = if ':' in host: nativesockets.AF_INET6
                    else: nativesockets.AF_INET
        let second = if first == nativesockets.AF_INET:
                       nativesockets.AF_INET6
                     else: nativesockets.AF_INET
        let deadline = getMonoTime() +
          initDuration(milliseconds = job.connectTimeoutMs)
        var lastFailure = EHOSTUNREACH
        for domain in [first, second]:
          let remaining = int((deadline - getMonoTime()).inMilliseconds)
          if remaining <= 0:
            lastFailure = ETIMEDOUT
            break
          var socket: Socket
          try:
            socket = newSocket(domain = domain)
            socket.connect(host, Port(job.connectPort), remaining)
            let duplicated = posix.dup(socket.getFd().cint)
            if duplicated < 0:
              lastFailure = errno
              continue
            if fcntl(duplicated, F_SETFD, FD_CLOEXEC) < 0 or
                fcntl(duplicated, F_SETFL,
                      fcntl(duplicated, F_GETFL, 0) or O_NONBLOCK) < 0:
              lastFailure = errno
              discard posix.close(duplicated)
              continue
            job.resultFd = duplicated
            lastFailure = 0
            break
          except TimeoutError:
            lastFailure = ETIMEDOUT
          except OSError as error:
            lastFailure = cint(error.errorCode)
          finally:
            if socket != nil: socket.close()
        job.errorCode = lastFailure
      of ifjTcpListen:
        let host = $cast[cstring](job.path)
        let domain = if ':' in host: nativesockets.AF_INET6
                     else: nativesockets.AF_INET
        var socket: Socket
        try:
          socket = newSocket(domain = domain)
          socket.setSockOpt(OptReuseAddr, true)
          socket.bindAddr(Port(job.connectPort), host)
          socket.listen(cint(job.listenBacklog))
          job.resultPort = int(uint16(socket.getLocalAddr()[1]))
          let duplicated = posix.dup(socket.getFd().cint)
          if duplicated < 0:
            job.errorCode = errno
          elif fcntl(duplicated, F_SETFD, FD_CLOEXEC) < 0 or
              fcntl(duplicated, F_SETFL,
                    fcntl(duplicated, F_GETFL, 0) or O_NONBLOCK) < 0:
            job.errorCode = errno
            discard posix.close(duplicated)
          else:
            job.resultFd = duplicated
        except OSError as error:
          job.errorCode = cint(error.errorCode)
        finally:
          if socket != nil: socket.close()
      of ifjTcpAccept:
        let accepted = posix.accept(SocketHandle(job.fd), nil, nil)
        if cint(accepted) < 0:
          job.errorCode = errno
        elif fcntl(accepted, F_SETFD, FD_CLOEXEC) < 0 or
            fcntl(accepted, F_SETFL,
                  fcntl(accepted, F_GETFL, 0) or O_NONBLOCK) < 0:
          job.errorCode = errno
          discard posix.close(accepted)
        else:
          job.resultFd = cint(accepted)
      of ifjClose, ifjDiscardOpen:
        if posix.close(job.fd) != 0:
          job.errorCode = errno

  proc ioFileReadinessMain() {.thread.} =
    {.cast(gcsafe).}:
      while true:
        var snapshot: seq[pointer]
        withLock ioFileLock:
          while ioFileWaitQueue.len == 0:
            wait(ioFileReadyCond, ioFileLock)
          # Copy pointer values: workers may append while poll is asleep.
          for job in ioFileWaitQueue:
            snapshot.add job
        var descriptors = newSeq[TPollfd](snapshot.len)
        for i, jobPtr in snapshot:
          let job = cast[ptr IoFileJob](jobPtr)
          descriptors[i] = TPollfd(fd: job.fd,
            events: if job.kind in {ifjRead, ifjTcpAccept}: POLLIN
                    else: POLLOUT)
        let ready = posix.poll(addr descriptors[0], Tnfds(descriptors.len), 100)
        let pollFailure = if ready < 0: errno else: 0
        withLock ioFileLock:
          for i, jobPtr in snapshot:
            let job = cast[ptr IoFileJob](jobPtr)
            if not atomicLoadN(addr job.cancelRequested, ATOMIC_ACQUIRE) and
                not (ready > 0 and descriptors[i].revents != 0) and
                not (ready < 0 and pollFailure != EINTR):
              continue
            for waiting in 0 ..< ioFileWaitQueue.len:
              if ioFileWaitQueue[waiting] == jobPtr:
                ioFileWaitQueue.delete(waiting)
                ioFileQueue.add jobPtr
                signal(ioFileCond)
                break

  proc parkIoFileForReadiness(jobPtr: pointer) =
    var startWatcher = false
    withLock ioFileLock:
      ioFileWaitQueue.add jobPtr
      if not ioFileReadinessStarted:
        ioFileReadinessStarted = true
        startWatcher = true
      signal(ioFileReadyCond)
    if startWatcher:
      try:
        var thread: ref Thread[void]
        new(thread)
        createThread(thread[], ioFileReadinessMain)
        withLock ioFileLock:
          ioFileReadinessThread = thread
      except CatchableError:
        # A failed watcher start must fail parked operations, not strand their
        # native cleanup leases indefinitely.
        withLock ioFileLock:
          for waiting in ioFileWaitQueue:
            let job = cast[ptr IoFileJob](waiting)
            job.errorCode = EIO
            atomicStoreN(addr job.workerDone, true, ATOMIC_RELEASE)
          ioFileWaitQueue.setLen(0)
          ioFileReadinessStarted = false

  proc ioFileWorkerMain() {.thread.} =
    {.cast(gcsafe).}:
      blockIoFileSigpipe()
      while true:
        var ptrJob: pointer
        withLock ioFileLock:
          while ioFileQueue.len == 0:
            inc ioFileIdle
            wait(ioFileCond, ioFileLock)
            dec ioFileIdle
          ptrJob = ioFileQueue[0]
          ioFileQueue.delete(0)
        let job = cast[ptr IoFileJob](ptrJob)
        if not atomicLoadN(addr job.cancelRequested, ATOMIC_ACQUIRE):
          runIoFileJob(job)
        if job.pipeEndpoint and
            (job.errorCode == EAGAIN or job.errorCode == EWOULDBLOCK) and
            not atomicLoadN(addr job.cancelRequested, ATOMIC_ACQUIRE):
          job.errorCode = 0
          parkIoFileForReadiness(ptrJob)
          continue
        # The root frees the job only after this release-store; no worker
        # access follows it.
        atomicStoreN(addr job.workerDone, true, ATOMIC_RELEASE)

  proc enqueueIoFile(pending: IoFilePending, force = false): bool =
    var needWorker = false
    withLock ioFileLock:
      if not force and ioFileQueue.len >= IoFileMaxQueued:
        return false
      beginExternalNativeOp()
      ioFilePending.add pending
      ioFileQueue.add cast[pointer](pending.job)
      if ioFileIdle == 0 and ioFileThreads.len < IoFileMaxWorkers:
        needWorker = true
      else:
        signal(ioFileCond)
    if needWorker:
      var thread: ref Thread[void]
      new(thread)
      createThread(thread[], ioFileWorkerMain)
      withLock ioFileLock:
        ioFileThreads.add thread
        signal(ioFileCond)
    true

  proc fileErrorText(code: cint): string =
    if code == 0: ""
    else: osErrorMsg(OSErrorCode(code))

  proc ioFileRecord(value: Value, call: ptr NativeCall,
                    operation: string): IoFileRecord =
    let scope = if call == nil: nil else: call[].dispatchScope
    let app = if scope == nil: currentApplication() else: scope.application()
    let readerType = builtinBinding(scope, "IoFileReader")
    let writerType = builtinBinding(scope, "IoFileWriter")
    let pipeReaderType = builtinBinding(scope, "IoPipeReader")
    let pipeWriterType = builtinBinding(scope, "IoPipeWriter")
    let ioScope = scope.application().stdlib.vars["io"].nsScope
    let tcpStreamType = ioScope.vars["TcpStream"]
    let tcpListenerType = ioScope.vars["TcpListener"]
    if value.kind != vkNode or
        (value.head.bits != readerType.bits and
         value.head.bits != writerType.bits and
         value.head.bits != pipeReaderType.bits and
         value.head.bits != pipeWriterType.bits and
         value.head.bits != tcpStreamType.bits and
         value.head.bits != tcpListenerType.bits):
      raiseTypeError("io/file " & operation, "I/O reader or writer",
                     value, scope)
    let id = value.nodeResourceId
    withLock ioFileLock:
      result = ioFileRecords.getOrDefault(id)
    if result == nil or result.application != app:
      raiseIoTestingError(scope, "IoClosed", operation, id,
        "file reader is unavailable")
    if result.ownerLane != currentEventLane():
      raiseValueSemanticError("RuntimeLaneError",
        "file reader belongs to another lane")

  proc settleFileClose(record: IoFileRecord, code: cint) =
    let scope = record.application.builtinsScope()
    let message = fileErrorText(code)
    record.closeError = message
    record.closeErrorCode = code
    record.fd = -1
    discard record.lifecycle.retireIoClose(message)
    if record.closeLease.kind == vkTask:
      discard nativeRetireIoCleanupLease(record.closeLease, scope)
      record.closeLease = NIL
    for waiter in record.waiters:
      if message.len == 0:
        discard nativeTaskComplete(waiter, NIL, scope)
      else:
        let error = ioTestingErrorValue(scope, "IoError", "close",
          record.lifecycle.ioResourceId(), message,
          cause = newInt(code))
        discard nativeTaskFail(waiter, message, error,
                               hasValue = true, scope = scope)
    record.waiters.setLen(0)
    if record.handleGone:
      withLock ioFileLock:
        ioFileRecords.del(record.lifecycle.ioResourceId())

  proc enqueueFileClose(record: IoFileRecord) =
    if record.closeQueued or record.fd < 0:
      return
    record.closeQueued = true
    let job = newIoFileJob(ifjClose)
    job.fd = record.fd
    let pending = IoFilePending(job: job, record: record,
      ownerLane: record.ownerLane)
    discard enqueueIoFile(pending, force = true)

  proc beginIoPipeOutputBorrow(writer: Value, scope: Scope,
                               task: Value, operation: string): IoPipeBorrow =
    var call = NativeCall(dispatchScope: scope)
    let record = ioFileRecord(writer, addr call, operation)
    let pipeWriterType = builtinBinding(scope, "IoPipeWriter")
    if writer.head.bits != pipeWriterType.bits or not record.pipeEndpoint:
      raiseTypeError("os/exec_stream_async ^" & operation, "PipeWriter",
                     writer, scope)
    let admission = record.lifecycle.admitIoOperation(iodWrite, 4096)
    if not admission.accepted:
      let kind = case admission.failure
        of iaBusy: "IoBusy"
        of iaClosed: "IoClosed"
        of iaBackpressure: "IoBackpressure"
        else: "IoError"
      raiseIoTestingError(scope, kind, operation,
        record.lifecycle.ioResourceId(), operation & " admission failed")
    let duplicated = posix.dup(record.fd)
    if duplicated < 0 or fcntl(duplicated, F_SETFD, FD_CLOEXEC) < 0:
      let failure = errno
      if duplicated >= 0: discard posix.close(duplicated)
      discard record.lifecycle.finishIoOperation(admission.ticket)
      raiseIoTestingError(scope, "IoError", operation,
        record.lifecycle.ioResourceId(),
        "could not duplicate output pipe: " & fileErrorText(failure))
    let lease = nativeNewIoCleanupLease(scope)
    scope.registerIoTask(task)
    record.writeTask = task
    record.writeLease = lease
    record.writeTicket = admission.ticket
    # The subprocess owns this writer from admission onward. Keep its close
    # lease in the caller's structured scope, but do not cancel the process
    # Task: the worker's duplicate remains live until stdout finishes.
    discard record.lifecycle.requestIoClose()
    record.closeLease = nativeNewIoCleanupLease(scope)
    IoPipeBorrow(fd: duplicated, resourceId: record.lifecycle.ioResourceId(),
      ticket: admission.ticket, cleanupLease: lease)

  proc finishIoPipeOutputBorrow(borrow: IoPipeBorrow, scope: Scope) =
    if borrow.resourceId == 0:
      return
    var record: IoFileRecord
    withLock ioFileLock:
      record = ioFileRecords.getOrDefault(borrow.resourceId)
    if record == nil:
      discard nativeRetireIoCleanupLease(borrow.cleanupLease, scope)
      return
    let finished = record.lifecycle.finishIoOperation(borrow.ticket)
    if finished.accepted:
      record.writeTask = NIL
      record.writeLease = NIL
      record.writeTicket = IoTicket()
      discard nativeRetireIoCleanupLease(borrow.cleanupLease, scope)
      if finished.retireReady:
        enqueueFileClose(record)

  proc beginIoPipeInputBorrow(reader: Value, scope: Scope,
                              task: Value): IoPipeBorrow =
    var call = NativeCall(dispatchScope: scope)
    let record = ioFileRecord(reader, addr call, "stdin_pipe")
    let pipeReaderType = builtinBinding(scope, "IoPipeReader")
    if reader.head.bits != pipeReaderType.bits or not record.pipeEndpoint:
      raiseTypeError("os/exec_stream_async ^stdin_pipe", "PipeReader",
                     reader, scope)
    let admission = record.lifecycle.admitIoOperation(iodRead, 4096)
    if not admission.accepted:
      let kind = case admission.failure
        of iaBusy: "IoBusy"
        of iaClosed: "IoClosed"
        of iaBackpressure: "IoBackpressure"
        else: "IoError"
      raiseIoTestingError(scope, kind, "stdin_pipe",
        record.lifecycle.ioResourceId(), "stdin_pipe admission failed")
    let duplicated = posix.dup(record.fd)
    if duplicated < 0 or fcntl(duplicated, F_SETFD, FD_CLOEXEC) < 0:
      let failure = errno
      if duplicated >= 0: discard posix.close(duplicated)
      discard record.lifecycle.finishIoOperation(admission.ticket)
      raiseIoTestingError(scope, "IoError", "stdin_pipe",
        record.lifecycle.ioResourceId(),
        "could not duplicate input pipe: " & fileErrorText(failure))
    let lease = nativeNewIoCleanupLease(scope)
    scope.registerIoTask(task)
    record.readTask = task
    record.readLease = lease
    record.readTicket = admission.ticket
    discard record.lifecycle.requestIoClose()
    record.closeLease = nativeNewIoCleanupLease(scope)
    IoPipeBorrow(fd: duplicated, resourceId: record.lifecycle.ioResourceId(),
      ticket: admission.ticket, cleanupLease: lease)

  proc finishIoPipeInputBorrow(borrow: IoPipeBorrow, scope: Scope) =
    if borrow.resourceId == 0:
      return
    var record: IoFileRecord
    withLock ioFileLock:
      record = ioFileRecords.getOrDefault(borrow.resourceId)
    if record == nil:
      discard nativeRetireIoCleanupLease(borrow.cleanupLease, scope)
      return
    let finished = record.lifecycle.finishIoOperation(borrow.ticket)
    if finished.accepted:
      record.readTask = NIL
      record.readLease = NIL
      record.readTicket = IoTicket()
      discard nativeRetireIoCleanupLease(borrow.cleanupLease, scope)
      if finished.retireReady:
        enqueueFileClose(record)

  proc settleIoFilePending(pending: IoFilePending) =
    let job = pending.job
    let record = pending.record
    let scope = record.application.builtinsScope()
    case job.kind
    of ifjOpenRead, ifjOpenWrite, ifjTcpConnect, ifjTcpListen:
      let openName = case job.kind
        of ifjOpenRead: "open_read"
        of ifjOpenWrite: "open_write"
        of ifjTcpConnect: "tcp_connect"
        else: "tcp_listen"
      if job.errorCode != 0:
        discard record.lifecycle.finishIoOperation(pending.ticket)
        let message = "io/" & openName & " failed: " & fileErrorText(job.errorCode)
        let error = ioTestingErrorValue(scope, "IoError", openName,
          record.lifecycle.ioResourceId(), message,
          cause = newInt(job.errorCode))
        discard nativeTaskFail(pending.task, message, error,
                               hasValue = true, scope = scope)
        discard nativeRetireIoCleanupLease(pending.lease, scope)
      elif pending.task.taskDone:
        record.fd = job.resultFd
        discard record.lifecycle.requestIoClose()
        let discardJob = newIoFileJob(ifjDiscardOpen)
        discardJob.fd = record.fd
        discard enqueueIoFile(IoFilePending(job: discardJob, record: record,
          task: pending.task, lease: pending.lease, ticket: pending.ticket,
          ownerLane: record.ownerLane), force = true)
      else:
        record.fd = job.resultFd
        record.localPort = job.resultPort
        let id = record.lifecycle.ioResourceId()
        var handle = NIL
        var delivered = false
        try:
          handle = newRuntimeResourceHandle(scope,
            if record.listener: "IoTcpListener"
            elif record.duplex: "IoTcpStream"
            elif record.writer: "IoFileWriter"
            else: "IoFileReader", id)
          withLock ioFileLock:
            ioFileRecords[id] = record
          delivered = nativeTaskComplete(pending.task, handle, scope)
        except CatchableError as error:
          let message = "io/" & openName & " result failed: " & error.msg
          let ioError = ioTestingErrorValue(scope, "IoError", openName,
            id, message)
          discard nativeTaskFail(pending.task, message, ioError,
                                 hasValue = true, scope = scope)
        if delivered:
          discard record.lifecycle.finishIoOperation(pending.ticket)
          discard nativeRetireIoCleanupLease(pending.lease, scope)
        else:
          if handle.kind == vkNode:
            discard handle.takeNodeResourceId()
          withLock ioFileLock:
            ioFileRecords.del(id)
          discard record.lifecycle.requestIoClose()
          let discardJob = newIoFileJob(ifjDiscardOpen)
          discardJob.fd = record.fd
          discard enqueueIoFile(IoFilePending(job: discardJob, record: record,
            task: pending.task, lease: pending.lease, ticket: pending.ticket,
            ownerLane: record.ownerLane), force = true)
    of ifjDiscardOpen:
      discard record.lifecycle.finishIoOperation(pending.ticket)
      discard record.lifecycle.retireIoClose(fileErrorText(job.errorCode))
      discard nativeRetireIoCleanupLease(pending.lease, scope)
      record.fd = -1
    of ifjTcpAccept:
      let finished = record.lifecycle.finishIoOperation(pending.ticket)
      if finished.accepted:
        if job.errorCode != 0:
          let message = "TCP accept failed: " & fileErrorText(job.errorCode)
          let error = ioTestingErrorValue(scope, "IoError", "tcp_accept",
            record.lifecycle.ioResourceId(), message,
            cause = newInt(job.errorCode))
          discard nativeTaskFail(pending.task, message, error,
                                 hasValue = true, scope = scope)
        elif pending.task.taskDone:
          if job.resultFd >= 0: discard posix.close(job.resultFd)
        else:
          let acceptedLife = nativeNewIoLifecycle(scope)
          let acceptedId = acceptedLife.ioResourceId()
          let accepted = IoFileRecord(application: record.application,
            ownerLane: record.ownerLane, lifecycle: acceptedLife,
            fd: job.resultFd, duplex: true, pipeEndpoint: true)
          var handle = NIL
          var delivered = false
          try:
            handle = newRuntimeResourceHandle(scope, "IoTcpStream", acceptedId)
            withLock ioFileLock:
              ioFileRecords[acceptedId] = accepted
            delivered = nativeTaskComplete(pending.task, handle, scope)
          except CatchableError as error:
            let message = "TCP accept result failed: " & error.msg
            let ioError = ioTestingErrorValue(scope, "IoError", "tcp_accept",
              acceptedId, message)
            discard nativeTaskFail(pending.task, message, ioError,
                                   hasValue = true, scope = scope)
          if not delivered:
            if handle.kind == vkNode: discard handle.takeNodeResourceId()
            withLock ioFileLock:
              ioFileRecords.del(acceptedId)
            discard posix.close(job.resultFd)
        discard nativeRetireIoCleanupLease(pending.lease, scope)
        record.readTask = NIL
        record.readLease = NIL
        record.readTicket = IoTicket()
        record.readJob = nil
        if finished.retireReady:
          enqueueFileClose(record)
    of ifjRead:
      let finished = record.lifecycle.finishIoOperation(pending.ticket)
      if finished.accepted:
        if pending.task.taskCancelled:
          discard # A skipped native read must not turn into a false EOF.
        elif job.errorCode != 0:
          let message = "file read failed: " & fileErrorText(job.errorCode)
          let error = ioTestingErrorValue(scope, "IoError", "read",
            record.lifecycle.ioResourceId(), message,
            cause = newInt(job.errorCode))
          discard nativeTaskFail(pending.task, message, error,
                                 hasValue = true, scope = scope)
        elif job.resultCount == 0:
          record.eof = true
          discard nativeTaskComplete(pending.task, NIL, scope)
        else:
          var bytes = newString(job.resultCount)
          copyMem(addr bytes[0], job.buffer, job.resultCount)
          discard nativeTaskComplete(pending.task, newBytes(bytes), scope)
        discard nativeRetireIoCleanupLease(pending.lease, scope)
        record.readTask = NIL
        record.readLease = NIL
        record.readTicket = IoTicket()
        record.readJob = nil
        if finished.retireReady:
          enqueueFileClose(record)
    of ifjWrite, ifjFlush:
      let finished = record.lifecycle.finishIoOperation(pending.ticket)
      if finished.accepted:
        if pending.task.taskCancelled:
          discard
        elif job.errorCode != 0:
          let operation = if job.kind == ifjFlush: "flush" else: "write"
          let message = "file " & operation & " failed: " &
                        fileErrorText(job.errorCode)
          let error = ioTestingErrorValue(scope, "IoError", operation,
            record.lifecycle.ioResourceId(), message, 0,
            newInt(job.errorCode))
          discard nativeTaskFail(pending.task, message, error,
                                 hasValue = true, scope = scope)
        elif job.kind == ifjFlush:
          discard nativeTaskComplete(pending.task, NIL, scope)
        elif job.resultCount > 0:
          discard nativeTaskComplete(pending.task,
                                     newInt(job.resultCount), scope)
        else:
          let message = "file writer made no progress"
          let error = ioTestingErrorValue(scope, "IoError", "write",
            record.lifecycle.ioResourceId(), message, 0)
          discard nativeTaskFail(pending.task, message, error,
                                 hasValue = true, scope = scope)
        discard nativeRetireIoCleanupLease(pending.lease, scope)
        record.writeTask = NIL
        record.writeLease = NIL
        record.writeTicket = IoTicket()
        record.writeJob = nil
        if finished.retireReady:
          enqueueFileClose(record)
    of ifjClose:
      settleFileClose(record, job.errorCode)

  proc pollIoFileCompletions() =
    var completed: seq[IoFilePending]
    withLock ioFileLock:
      var i = 0
      while i < ioFilePending.len:
        let pending = ioFilePending[i]
        if pending.job.kind in {ifjRead, ifjWrite, ifjTcpAccept} and
            pending.task.kind == vkTask and pending.task.taskCancelled:
          atomicStoreN(addr pending.job.cancelRequested, true, ATOMIC_RELEASE)
        if pending.ownerLane == currentEventLane() and
            atomicLoadN(addr pending.job.workerDone, ATOMIC_ACQUIRE):
          completed.add pending
          ioFilePending.delete(i)
        else:
          inc i
    for pending in completed:
      try:
        settleIoFilePending(pending)
      finally:
        freeIoFileJob(pending.job)
        endExternalNativeOp()

  proc releaseIoFileResourceRecord(id: uint64) {.raises: [].} =
    var record: IoFileRecord
    withLock ioFileLock:
      record = ioFileRecords.getOrDefault(id)
      if record != nil:
        record.handleGone = true
        if record.lifecycle.ioSnapshot().phase == iopClosed:
          ioFileRecords.del(id)
          return
    if record == nil:
      return
    try:
      let ready = record.lifecycle.requestIoClose()
      if record.readTask.kind == vkTask:
        discard nativeTaskCancel(record.readTask,
                                 record.application.builtinsScope())
      if record.readJob != nil:
        atomicStoreN(addr record.readJob.cancelRequested, true, ATOMIC_RELEASE)
      if record.writeTask.kind == vkTask:
        discard nativeTaskCancel(record.writeTask,
                                 record.application.builtinsScope())
      if record.writeJob != nil:
        atomicStoreN(addr record.writeJob.cancelRequested, true, ATOMIC_RELEASE)
      if ready:
        # Last-resort GC close has no user-facing handle to await. Closing an
        # idle descriptor here prevents an abandoned resource from pinning the
        # Application indefinitely; active reads still retire on the worker.
        let code = if posix.close(record.fd) == 0: 0.cint else: errno
        settleFileClose(record, code)
    except Exception:
      discard # keep the record visible as cleanup-pending

  proc beginIoFileOpen(scope: Scope, rawPath: string, kind: IoFileJobKind,
                       flags: cint, writer: bool, operationName: string): Value =
    if scope == nil:
      raise newException(GeneError, "io/" & operationName & " requires a call scope")
    if currentEventLane() != schedulerForScope(scope).rootLane:
      raiseValueSemanticError("RuntimeLaneError",
        "io/" & operationName & " requires the root lane")
    for ch in rawPath:
      if ch == '\0':
        raise newException(GeneError,
          "io/" & operationName & " rejects interior NUL")
    let path = if isAbsolute(rawPath): rawPath
               else: absolutePath(rawPath, scope.application().launchDir)
    let lifecycle = nativeNewIoLifecycle(scope)
    let admission = lifecycle.admitIoOperation(iodFlush, 0) # open lease
    if not admission.accepted:
      raiseIoTestingError(scope, "IoBackpressure", operationName,
        lifecycle.ioResourceId(), "I/O open admission failed")
    let operation = nativeNewIoOperation(scope)
    let record = IoFileRecord(application: scope.application(),
      ownerLane: currentEventLane(), lifecycle: lifecycle, fd: -1,
      writer: writer)
    let job = newIoFileJob(kind)
    job.openFlags = flags
    job.path = allocShared0(path.len + 1)
    if path.len > 0: copyMem(job.path, unsafeAddr path[0], path.len)
    let pending = IoFilePending(job: job, record: record,
      task: operation.task, lease: operation.cleanupLease,
      ticket: admission.ticket, ownerLane: record.ownerLane)
    if not enqueueIoFile(pending):
      freeIoFileJob(job)
      discard lifecycle.finishIoOperation(admission.ticket)
      discard nativeRetireIoCleanupLease(operation.cleanupLease, scope)
      raiseIoTestingError(scope, "IoBackpressure", operationName,
        lifecycle.ioResourceId(), "I/O worker queue is full")
    operation.task

  proc biIoOpenRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1 or args[0].kind != vkString:
      raise newException(GeneError, "io/open_read expects one Str path")
    beginIoFileOpen(if call == nil: nil else: call[].dispatchScope,
      args[0].strVal, ifjOpenRead, 0, false, "open_read")

  proc biIoOpenWrite(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1 or args[0].kind != vkString:
      raise newException(GeneError, "io/open_write expects one Str path")
    var mode = "create_new"
    if call != nil:
      var seen = false
      for i, name in call[].namedNames:
        if name != "mode" or seen or call[].namedValues[i].kind != vkString:
          raise newException(GeneError,
            "io/open_write accepts one Str ^mode option")
        seen = true
        mode = call[].namedValues[i].strVal
    let flags =
      case mode
      of "create_new": O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC
      of "truncate": O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC
      of "append": O_WRONLY or O_CREAT or O_APPEND or O_CLOEXEC
      else:
        raise newException(GeneError,
          "io/open_write ^mode must be create_new, truncate, or append")
    beginIoFileOpen(if call == nil: nil else: call[].dispatchScope,
      args[0].strVal, ifjOpenWrite, flags, true, "open_write")

  proc biIoTcpConnect(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if scope == nil or args.len != 2 or args[0].kind != vkString or
        args[1].kind != vkInt:
      raise newException(GeneError,
        "io/tcp_connect expects host Str and port Int")
    if currentEventLane() != schedulerForScope(scope).rootLane:
      raiseValueSemanticError("RuntimeLaneError",
        "io/tcp_connect requires the root lane")
    let host = args[0].strVal
    if host.len == 0 or host.len > 253 or '\0' in host:
      raiseIoTestingError(scope, "IoError", "tcp_connect", 0,
        "host must be a nonempty bounded Str without NUL")
    let port = requireInt64("io/tcp_connect port", args[1])
    if port < 1 or port > 65535:
      raiseIoTestingError(scope, "IoError", "tcp_connect", 0,
        "port must be within 1..65535")
    var timeoutMs = 10000
    if call != nil:
      var seen = false
      for i, name in call[].namedNames:
        if name != "timeout_ms" or seen or
            call[].namedValues[i].kind != vkInt:
          raiseIoTestingError(scope, "IoError", "tcp_connect", 0,
            "tcp_connect accepts one Int ^timeout_ms option")
        seen = true
        let amount = requireInt64("io/tcp_connect timeout_ms",
                                  call[].namedValues[i])
        if amount < 1 or amount > 300000:
          raiseIoTestingError(scope, "IoError", "tcp_connect", 0,
            "timeout_ms must be within 1..300000")
        timeoutMs = int(amount)
    let lifecycle = nativeNewIoLifecycle(scope)
    let admission = lifecycle.admitIoOperation(iodFlush, 0)
    if not admission.accepted:
      raiseIoTestingError(scope, "IoBackpressure", "tcp_connect",
        lifecycle.ioResourceId(), "TCP open admission failed")
    let operation = nativeNewIoOperation(scope)
    let record = IoFileRecord(application: scope.application(),
      ownerLane: currentEventLane(), lifecycle: lifecycle, fd: -1,
      duplex: true, pipeEndpoint: true)
    let job = newIoFileJob(ifjTcpConnect)
    job.connectPort = int(port)
    job.connectTimeoutMs = timeoutMs
    job.path = allocShared0(host.len + 1)
    copyMem(job.path, unsafeAddr host[0], host.len)
    let pending = IoFilePending(job: job, record: record,
      task: operation.task, lease: operation.cleanupLease,
      ticket: admission.ticket, ownerLane: record.ownerLane)
    if not enqueueIoFile(pending):
      freeIoFileJob(job)
      discard lifecycle.finishIoOperation(admission.ticket)
      discard nativeRetireIoCleanupLease(operation.cleanupLease, scope)
      raiseIoTestingError(scope, "IoBackpressure", "tcp_connect",
        lifecycle.ioResourceId(), "I/O worker queue is full")
    operation.task

  proc biIoTcpListen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if scope == nil or args.len != 2 or args[0].kind != vkString or
        args[1].kind != vkInt:
      raise newException(GeneError,
        "io/tcp_listen expects host Str and port Int")
    if currentEventLane() != schedulerForScope(scope).rootLane:
      raiseValueSemanticError("RuntimeLaneError",
        "io/tcp_listen requires the root lane")
    let host = args[0].strVal
    if host.len == 0 or host.len > 253 or '\0' in host:
      raiseIoTestingError(scope, "IoError", "tcp_listen", 0,
        "host must be a nonempty bounded Str without NUL")
    let port = requireInt64("io/tcp_listen port", args[1])
    if port < 0 or port > 65535:
      raiseIoTestingError(scope, "IoError", "tcp_listen", 0,
        "port must be within 0..65535")
    var backlog = 128
    if call != nil:
      var seen = false
      for i, name in call[].namedNames:
        if name != "backlog" or seen or
            call[].namedValues[i].kind != vkInt:
          raiseIoTestingError(scope, "IoError", "tcp_listen", 0,
            "tcp_listen accepts one Int ^backlog option")
        seen = true
        let amount = requireInt64("io/tcp_listen backlog",
                                  call[].namedValues[i])
        if amount < 1 or amount > 1024:
          raiseIoTestingError(scope, "IoError", "tcp_listen", 0,
            "backlog must be within 1..1024")
        backlog = int(amount)
    let lifecycle = nativeNewIoLifecycle(scope)
    let admission = lifecycle.admitIoOperation(iodFlush, 0)
    if not admission.accepted:
      raiseIoTestingError(scope, "IoBackpressure", "tcp_listen",
        lifecycle.ioResourceId(), "TCP listen admission failed")
    let operation = nativeNewIoOperation(scope)
    let record = IoFileRecord(application: scope.application(),
      ownerLane: currentEventLane(), lifecycle: lifecycle, fd: -1,
      listener: true, pipeEndpoint: true)
    let job = newIoFileJob(ifjTcpListen)
    job.connectPort = int(port)
    job.listenBacklog = backlog
    job.path = allocShared0(host.len + 1)
    copyMem(job.path, unsafeAddr host[0], host.len)
    let pending = IoFilePending(job: job, record: record,
      task: operation.task, lease: operation.cleanupLease,
      ticket: admission.ticket, ownerLane: record.ownerLane)
    if not enqueueIoFile(pending):
      freeIoFileJob(job)
      discard lifecycle.finishIoOperation(admission.ticket)
      discard nativeRetireIoCleanupLease(operation.cleanupLease, scope)
      raiseIoTestingError(scope, "IoBackpressure", "tcp_listen",
        lifecycle.ioResourceId(), "I/O worker queue is full")
    operation.task

  proc biIoTcpAccept(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1:
      raise newException(GeneError, "TcpListener/accept expects no arguments")
    let scope = if call == nil: nil else: call[].dispatchScope
    let record = ioFileRecord(args[0], call, "tcp_accept")
    if not record.listener:
      raiseTypeError("TcpListener/accept", "TcpListener", args[0], scope)
    let admission = record.lifecycle.admitIoOperation(iodRead, 1)
    if not admission.accepted:
      let kind = case admission.failure
        of iaBusy: "IoBusy"
        of iaClosed: "IoClosed"
        of iaBackpressure: "IoBackpressure"
        else: "IoError"
      raiseIoTestingError(scope, kind, "tcp_accept",
        record.lifecycle.ioResourceId(), "TCP accept admission failed")
    let operation = nativeNewIoOperation(scope)
    let job = newIoFileJob(ifjTcpAccept)
    job.fd = record.fd
    job.pipeEndpoint = true
    record.readTask = operation.task
    record.readLease = operation.cleanupLease
    record.readTicket = admission.ticket
    record.readJob = job
    let pending = IoFilePending(job: job, record: record,
      task: operation.task, lease: operation.cleanupLease,
      ticket: admission.ticket, ownerLane: record.ownerLane)
    if not enqueueIoFile(pending):
      record.readTask = NIL
      record.readLease = NIL
      record.readTicket = IoTicket()
      record.readJob = nil
      freeIoFileJob(job)
      discard record.lifecycle.finishIoOperation(admission.ticket)
      discard nativeRetireIoCleanupLease(operation.cleanupLease, scope)
      raiseIoTestingError(scope, "IoBackpressure", "tcp_accept",
        record.lifecycle.ioResourceId(), "I/O worker queue is full")
    operation.task

  proc biIoTcpLocalPort(args: openArray[Value],
                         call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1:
      raise newException(GeneError, "TcpListener/local_port expects no arguments")
    let scope = if call == nil: nil else: call[].dispatchScope
    let record = ioFileRecord(args[0], call, "tcp_local_port")
    if not record.listener:
      raiseTypeError("TcpListener/local_port", "TcpListener", args[0], scope)
    newInt(record.localPort)

  proc biIoTestingSocketBuffer(args: openArray[Value],
                               call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    if args.len != 3 or args[1].kind != vkString or args[2].kind != vkInt:
      raise newException(GeneError,
        "io/testing/socket_buffer expects TcpStream, direction, and bytes")
    let record = ioFileRecord(args[0], call, "socket_buffer")
    if not record.duplex:
      raiseTypeError("io/testing/socket_buffer", "TcpStream", args[0], scope)
    let amount = requireInt64("io/testing/socket_buffer bytes", args[2])
    if amount < 1024 or amount > 1048576:
      raiseIoTestingError(scope, "IoError", "socket_buffer",
        record.lifecycle.ioResourceId(), "buffer bytes must be 1024..1048576")
    let option = case args[1].strVal
      of "send": SO_SNDBUF
      of "receive": SO_RCVBUF
      else:
        raiseIoTestingError(scope, "IoError", "socket_buffer",
          record.lifecycle.ioResourceId(), "direction must be send or receive")
    var size = cint(amount)
    if posix.setsockopt(SocketHandle(record.fd), SOL_SOCKET, option,
                        addr size, SockLen(sizeof(size))) != 0:
      raiseIoTestingError(scope, "IoError", "socket_buffer",
        record.lifecycle.ioResourceId(),
        "setsockopt failed: " & fileErrorText(errno))
    NIL

  proc biIoPipe(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 0:
      raise newException(GeneError, "io/pipe expects no arguments")
    let scope = if call == nil: nil else: call[].dispatchScope
    if scope == nil:
      raise newException(GeneError, "io/pipe requires a call scope")
    if currentEventLane() != schedulerForScope(scope).rootLane:
      raiseValueSemanticError("RuntimeLaneError", "io/pipe requires the root lane")
    var fds: array[2, cint]
    if posix.pipe(fds) != 0:
      raiseIoTestingError(scope, "IoError", "pipe", 0,
        "io/pipe failed: " & fileErrorText(errno))
    if fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 or
        fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0 or
        fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) or O_NONBLOCK) < 0 or
        fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL, 0) or O_NONBLOCK) < 0:
      let failure = errno
      discard posix.close(fds[0])
      discard posix.close(fds[1])
      raiseIoTestingError(scope, "IoError", "pipe", 0,
        "io/pipe could not set close-on-exec: " & fileErrorText(failure))
    var readHandle = NIL
    var writeHandle = NIL
    var readId, writeId: uint64
    try:
      let readerLife = nativeNewIoLifecycle(scope)
      let writerLife = nativeNewIoLifecycle(scope)
      readId = readerLife.ioResourceId()
      writeId = writerLife.ioResourceId()
      let reader = IoFileRecord(application: scope.application(),
        ownerLane: currentEventLane(), lifecycle: readerLife, fd: fds[0],
        pipeEndpoint: true)
      let writer = IoFileRecord(application: scope.application(),
        ownerLane: currentEventLane(), lifecycle: writerLife, fd: fds[1],
        writer: true, pipeEndpoint: true)
      withLock ioFileLock:
        ioFileRecords[readId] = reader
        ioFileRecords[writeId] = writer
      readHandle = newRuntimeResourceHandle(scope, "IoPipeReader", readId)
      writeHandle = newRuntimeResourceHandle(scope, "IoPipeWriter", writeId)
      newList(@[readHandle, writeHandle])
    except CatchableError:
      if readHandle.kind == vkNode: discard readHandle.takeNodeResourceId()
      if writeHandle.kind == vkNode: discard writeHandle.takeNodeResourceId()
      withLock ioFileLock:
        if readId != 0: ioFileRecords.del(readId)
        if writeId != 0: ioFileRecords.del(writeId)
      discard posix.close(fds[0])
      discard posix.close(fds[1])
      raise

  proc biIoFileRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 2 or args[1].kind != vkInt:
      raise newException(GeneError, "AsyncReader:read expects an Int max_bytes")
    let scope = if call == nil: nil else: call[].dispatchScope
    let record = ioFileRecord(args[0], call, "read")
    if record.writer and not record.duplex:
      raiseTypeError("AsyncReader:read", "FileReader", args[0], scope)
    let amount = requireInt64("AsyncReader:read max_bytes", args[1])
    if amount < 1 or amount > DefaultIoResourceBytes:
      raiseIoTestingError(scope, "IoError", "read", record.lifecycle.ioResourceId(),
        "read max_bytes must be within 1..1048576")
    if record.lifecycle.ioSnapshot().phase != iopOpen:
      raiseIoTestingError(scope, "IoClosed", "read", record.lifecycle.ioResourceId(),
        "file reader is closing or closed")
    if record.eof:
      return newCompletedTask(NIL)
    let admission = record.lifecycle.admitIoOperation(iodRead, int(amount))
    if not admission.accepted:
      let kind = case admission.failure
        of iaBusy: "IoBusy"
        of iaClosed: "IoClosed"
        of iaBackpressure: "IoBackpressure"
        else: "IoError"
      raiseIoTestingError(scope, kind, "read", record.lifecycle.ioResourceId(),
        "file read admission failed")
    let operation = nativeNewIoOperation(scope)
    let job = newIoFileJob(ifjRead)
    job.fd = record.fd
    job.requested = int(amount)
    job.pipeEndpoint = record.pipeEndpoint
    job.buffer = allocShared0(int(amount))
    record.readTask = operation.task
    record.readLease = operation.cleanupLease
    record.readTicket = admission.ticket
    record.readJob = job
    let pending = IoFilePending(job: job, record: record,
      task: operation.task, lease: operation.cleanupLease,
      ticket: admission.ticket, ownerLane: record.ownerLane)
    if not enqueueIoFile(pending):
      record.readTask = NIL
      record.readLease = NIL
      record.readTicket = IoTicket()
      record.readJob = nil
      freeIoFileJob(job)
      discard record.lifecycle.finishIoOperation(admission.ticket)
      discard nativeRetireIoCleanupLease(operation.cleanupLease, scope)
      raiseIoTestingError(scope, "IoBackpressure", "read",
        record.lifecycle.ioResourceId(), "I/O worker queue is full")
    operation.task

  proc biIoFileWrite(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 2 or args[1].kind != vkBytes:
      raise newException(GeneError, "AsyncWriter:write expects Bytes")
    let scope = if call == nil: nil else: call[].dispatchScope
    let record = ioFileRecord(args[0], call, "write")
    if not record.writer and not record.duplex:
      raiseTypeError("AsyncWriter:write", "FileWriter", args[0], scope)
    let payload = args[1].bytesVal
    let admission = record.lifecycle.admitIoOperation(iodWrite, payload.len)
    if not admission.accepted:
      let kind = case admission.failure
        of iaBusy: "IoBusy"
        of iaClosed: "IoClosed"
        of iaBackpressure: "IoBackpressure"
        else: "IoError"
      raiseIoTestingError(scope, kind, "write", record.lifecycle.ioResourceId(),
        "file write admission failed")
    if admission.immediate:
      return newCompletedTask(newInt(0))
    let operation = nativeNewIoOperation(scope)
    let job = newIoFileJob(ifjWrite)
    job.fd = record.fd
    job.requested = payload.len
    job.pipeEndpoint = record.pipeEndpoint
    job.buffer = allocShared0(payload.len)
    copyMem(job.buffer, unsafeAddr payload[0], payload.len)
    record.writeTask = operation.task
    record.writeLease = operation.cleanupLease
    record.writeTicket = admission.ticket
    record.writeJob = job
    let pending = IoFilePending(job: job, record: record,
      task: operation.task, lease: operation.cleanupLease,
      ticket: admission.ticket, ownerLane: record.ownerLane)
    if not enqueueIoFile(pending):
      record.writeTask = NIL
      record.writeLease = NIL
      record.writeTicket = IoTicket()
      record.writeJob = nil
      freeIoFileJob(job)
      discard record.lifecycle.finishIoOperation(admission.ticket)
      discard nativeRetireIoCleanupLease(operation.cleanupLease, scope)
      raiseIoTestingError(scope, "IoBackpressure", "write",
        record.lifecycle.ioResourceId(), "I/O worker queue is full")
    operation.task

  proc biIoFileFlush(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1:
      raise newException(GeneError, "AsyncWriter:flush expects a FileWriter")
    let scope = if call == nil: nil else: call[].dispatchScope
    let record = ioFileRecord(args[0], call, "flush")
    if not record.writer and not record.duplex:
      raiseTypeError("AsyncWriter:flush", "FileWriter", args[0], scope)
    let admission = record.lifecycle.admitIoOperation(iodFlush, 0)
    if not admission.accepted:
      let kind = case admission.failure
        of iaBusy: "IoBusy"
        of iaClosed: "IoClosed"
        else: "IoError"
      raiseIoTestingError(scope, kind, "flush", record.lifecycle.ioResourceId(),
        "file flush admission failed")
    if record.pipeEndpoint:
      discard record.lifecycle.finishIoOperation(admission.ticket)
      return newCompletedTask(NIL)
    let operation = nativeNewIoOperation(scope)
    let job = newIoFileJob(ifjFlush)
    job.fd = record.fd
    record.writeTask = operation.task
    record.writeLease = operation.cleanupLease
    record.writeTicket = admission.ticket
    let pending = IoFilePending(job: job, record: record,
      task: operation.task, lease: operation.cleanupLease,
      ticket: admission.ticket, ownerLane: record.ownerLane)
    if not enqueueIoFile(pending):
      record.writeTask = NIL
      record.writeLease = NIL
      record.writeTicket = IoTicket()
      freeIoFileJob(job)
      discard record.lifecycle.finishIoOperation(admission.ticket)
      discard nativeRetireIoCleanupLease(operation.cleanupLease, scope)
      raiseIoTestingError(scope, "IoBackpressure", "flush",
        record.lifecycle.ioResourceId(), "I/O worker queue is full")
    operation.task

  proc biIoFileClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1:
      raise newException(GeneError, "IoResource:close expects a file reader")
    let scope = if call == nil: nil else: call[].dispatchScope
    let record = ioFileRecord(args[0], call, "close")
    if record.lifecycle.ioSnapshot().phase != iopOpen:
      return NIL
    let ready = record.lifecycle.requestIoClose()
    record.closeLease = nativeNewIoCleanupLease(scope)
    if record.readTask.kind == vkTask:
      discard nativeTaskCancel(record.readTask, scope)
    if record.readJob != nil:
      atomicStoreN(addr record.readJob.cancelRequested, true, ATOMIC_RELEASE)
    if record.writeTask.kind == vkTask:
      discard nativeTaskCancel(record.writeTask, scope)
    if record.writeJob != nil:
      atomicStoreN(addr record.writeJob.cancelRequested, true, ATOMIC_RELEASE)
    if ready:
      enqueueFileClose(record)
    NIL

  proc biIoFileWaitClosed(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1:
      raise newException(GeneError, "IoResource:wait_closed expects a file reader")
    let scope = if call == nil: nil else: call[].dispatchScope
    let record = ioFileRecord(args[0], call, "wait_closed")
    if record.lifecycle.ioSnapshot().phase == iopClosed:
      if record.closeError.len == 0:
        return newCompletedTask(NIL)
      let error = ioTestingErrorValue(scope, "IoError", "close",
        record.lifecycle.ioResourceId(), record.closeError,
        cause = newInt(record.closeErrorCode))
      return newFailedTask(record.closeError, error, hasValue = true)
    result = newExternalTask()
    scope.registerIoTask(result)
    record.waiters.add result

  proc ioFileReadLifecycle*(value: Value): IoLifecycle =
    ## The lifecycle behind a file, pipe, or TCP reader Value, or nil.
    if value.kind != vkNode or value.nodeResourceId == 0:
      return nil
    withLock ioFileLock:
      let record = ioFileRecords.getOrDefault(value.nodeResourceId)
      if record != nil:
        result = record.lifecycle

else:
  proc pollIoFileCompletions() = discard
  proc ioFileReadLifecycle*(value: Value): IoLifecycle = nil
  proc releaseIoFileResourceRecord(id: uint64) {.raises: [].} = discard
  proc ioFileOpenCount(app: Application): int = 0
  proc ioFileWaitingCount(): int = 0
  proc beginIoPipeOutputBorrow(writer: Value, scope: Scope,
                               task: Value, operation: string): IoPipeBorrow =
    raise newException(GeneError,
      "stdout pipe streaming requires a threaded POSIX runtime")
  proc finishIoPipeOutputBorrow(borrow: IoPipeBorrow, scope: Scope) = discard
  proc beginIoPipeInputBorrow(reader: Value, scope: Scope,
                              task: Value): IoPipeBorrow =
    raise newException(GeneError,
      "stdin pipe streaming requires a threaded POSIX runtime")
  proc finishIoPipeInputBorrow(borrow: IoPipeBorrow, scope: Scope) = discard

  proc biIoOpenRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1 or args[0].kind != vkString:
      raise newException(GeneError, "io/open_read expects one Str path")
    let scope = if call == nil: nil else: call[].dispatchScope
    let message = "io/open_read requires a threaded POSIX runtime"
    let error = ioTestingErrorValue(scope, "IoError", "open_read", 0, message)
    newFailedTask(message, error, hasValue = true)

  proc biIoOpenWrite(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    if args.len != 1 or args[0].kind != vkString:
      raise newException(GeneError, "io/open_write expects one Str path")
    let scope = if call == nil: nil else: call[].dispatchScope
    let message = "io/open_write requires a threaded POSIX runtime"
    let error = ioTestingErrorValue(scope, "IoError", "open_write", 0, message)
    newFailedTask(message, error, hasValue = true)

  proc biIoPipe(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "io/pipe requires a threaded POSIX runtime")

  proc biIoTcpConnect(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    let message = "io/tcp_connect requires a threaded POSIX runtime"
    let error = ioTestingErrorValue(scope, "IoError", "tcp_connect", 0, message)
    newFailedTask(message, error, hasValue = true)

  proc biIoTcpListen(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    let scope = if call == nil: nil else: call[].dispatchScope
    let message = "io/tcp_listen requires a threaded POSIX runtime"
    let error = ioTestingErrorValue(scope, "IoError", "tcp_listen", 0, message)
    newFailedTask(message, error, hasValue = true)
  proc biIoTcpAccept(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "TCP listeners require a threaded POSIX runtime")
  proc biIoTcpLocalPort(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "TCP listeners require a threaded POSIX runtime")
  proc biIoTestingSocketBuffer(args: openArray[Value],
                               call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "TCP testing requires a threaded POSIX runtime")

  proc biIoFileRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "file readers require a threaded POSIX runtime")
  proc biIoFileWrite(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "file writers require a threaded POSIX runtime")
  proc biIoFileFlush(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "file writers require a threaded POSIX runtime")
  proc biIoFileClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "file readers require a threaded POSIX runtime")
  proc biIoFileWaitClosed(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
    raise newException(GeneError, "file readers require a threaded POSIX runtime")
