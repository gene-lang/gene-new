# Async I/O and Resource Lifetime

**Status:** IO-1 contracts and lifecycle are experimental in the native VM. IO-2 has worker-backed POSIX files and `io/pipe` endpoints with bounded bytes, root-lane completion, cleanup leases, and typed broken-pipe errors. Blocked pipe operations park in a `poll(2)` readiness watcher instead of timed worker requeues. A wake pipe interrupts the watcher's poll whenever a wait parks or a parked wait is cancelled; before it, a wait parked beside another sat out the rest of the watcher's 100 ms poll (96 ms per pipe read, which also made each aborted streamed upload in the lifetime cancellation child wait ~50 ms). `os/exec_stream_async` accepts consumed `^stdin_pipe` readers and `^stdout_pipe`/`^stderr_pipe` writers for raw Bytes. IO-3 has experimental duplex TCP streams/listeners and HTTP server request/response body adapters using the same lifecycle/readiness path; binary exchange, slow-peer fairness, cancellation, and byte budgets pass on macOS. The owned HTTP Client has experimental buffered/streamed responses and AsyncReader uploads; Linux runtime qualification remains open. macOS ORC/AtomicArc tests pass. Design baseline `3b2bde9`.

**Stages:** IO-1 (contracts), IO-2 (files/pipes), IO-3 (sockets/integration).

**Depends on:** VM-0 diagnostics from [VM reliability](vm-reliability.md). No dependency on value-operator fallback, a new scheduler, or retained native callbacks.

## Baseline and decision

The VM has structured Tasks, one-consuming `await`, repeatable `Task:join`, and synchronous Streams. Existing filesystem, subprocess, and HTTP adapters return Tasks or Task/channel records. Preserve those public return shapes. Their native worker/completion paths are implementation inputs, not evidence that every external Task is already attached to a structured scope.

Add `AsyncReader`, `AsyncWriter`, and `IoResource` protocols under `gene/io`. Invoke them with qualified messages; Gene does not route an arbitrary `.read` or `.close` to a protocol. Concrete adapters may expose direct convenience messages, but generic algorithms use protocol identities. Existing Stream pulls never suspend for I/O.

The VM admits at most one pending `AsyncReader:read` per receiver identity,
including Gene implementations and inherited protocol messages. A read returns
its Task at admission; asynchronous work and cleanup belong to that Task.
Owned Client uploads hold an exclusive borrow that also refuses caller reads
through this protocol. A parent implementation invoked through `super` continues
the admitted read. Completed admission records are released on the scheduler's
root lane. This adds no syntax or protocol methods. Native adapters additionally
track physical worker retirement in their I/O lifecycle; custom convenience
methods and separate values aliasing the same backend must enforce backend
exclusion themselves.

## Public surface

The proposed declarations use current Gene syntax:

```gene
(protocol AsyncReader
  (message read [max_bytes : Int] : (Task Bytes? Error)))
(protocol AsyncWriter
  (message write [data : Bytes] : (Task Int Error))
  (message flush [] : (Task Nil Error)))
(protocol IoResource
  (message close [] : Nil)
  (message wait_closed [] : (Task Nil Error)))
```

All adapters implement `IoResource` and one or both I/O protocols. These declarations will be library exports, not definitions repeated in applications.

| Operation | Required behavior |
| --- | --- |
| `(reader .AsyncReader:read n)` | Fresh Task yielding 1 through n bytes, or nil at EOF. n must be 1..1,048,576. Empty Bytes is never an EOF/result placeholder. |
| `(writer .AsyncWriter:write bytes)` | Fresh Task yielding accepted byte count. A nonempty write returns at least 1 on success; partial writes are legal. Empty input completes with 0. |
| `(writer .AsyncWriter:flush)` | Task completes when adapter buffers have reached the underlying destination. It does not promise filesystem durability or peer application receipt. |
| `(resource .IoResource:close)` | Synchronous idempotent abort/close request returning nil. Stops admission and initiates cancellation/retirement. It does not promise handles are already released. |
| `(resource .IoResource:wait_closed)` | Fresh Task on every call; completes with nil after physical retirement, or raises the retained close error. Repetition never awaits the same consumed Task. |
| `($io/write_all writer bytes)` | Task returning total accepted bytes; loops on partial writes. |
| `($io/copy reader writer ^limit n ^chunk_bytes 65536)` | Task returning transferred bytes; stops at EOF or finite nonnegative n. The limit is required. Borrows endpoints and does not close them. |
| `($io/open_read path)` | Task yielding a file reader. Opening a file may block, so it uses the adapter worker path too. |
| `($io/open_write path ^mode "create_new")` | Task yielding a writer. Modes are create_new, truncate, append; destructive replacement requires explicit truncate. |

Example after implementation:

```gene
(import $io [AsyncReader IoResource open_read])
(scope
  (let reader (await (open_read "input.bin")))
  (try
    (let chunk (await (reader .AsyncReader:read 65536)))
    (if ($nil? chunk) 0 1)
    ensure (reader .IoResource:close)))
```

`ensure` requests close. The cleanup lease described below keeps scope settlement from reporting completion while the requested native cleanup is still active. A caller needing the close result explicitly awaits a fresh `wait_closed` Task.

## Ownership, completion, and cancellation

I/O objects belong to one Application/root lane and are non-Send initially. Read/write/flush Tasks register with the active scope, or the Application root when called outside a scope. Normal scope exit still waits without raising unconsumed task failures; callers must await outcomes they need. New adapters must implement this registration, not assume `newExternalTask` already supplies it.

Open operations follow the same Task ownership rule. If cancellation wins before delivery of an opened resource, the adapter closes that native handle before releasing its cleanup lease. A successfully delivered open result remains explicitly owned until close; merely exiting the creating scope does not implicitly close a resource intentionally retained elsewhere. The Application tracks open resources for shutdown and leak diagnostics. Awaiting open and closing the returned resource is the ordinary application contract.

A resource permits one outstanding read and one outstanding write. Flush occupies the write slot. A second operation in the same direction raises `IoBusy` before admission. State is `open → closing → closed`; a close error is retained alongside closed state. Close never reopens a resource, double-frees an OS handle, or discards a native completion's cleanup obligation.

Cancellation may settle a user Task as cancelled before an uninterruptible OS call returns. Keep the native request, buffers, and handle pinned until that call retires. The owning scope/Application holds a cleanup lease until retirement; closing during ensure attaches the same obligation even if the operation Task was already consumed. A shutdown deadline may report `cleanup_pending` and let the embedding host terminate its process; it must not report a clean shutdown or free live native storage. No hard interruption of arbitrary C is promised.

Errors use `IoError` with operation, resource ID, cause, and known `bytes_transferred` when applicable. Invalid options fail synchronously; failures after admission settle the Task. A cancelled/failed write can have an external prefix already written. Neither `write_all` nor copy automatically replays that prefix or rolls it back. Subsequent reads after EOF return fresh completed nil Tasks; after close, new I/O raises `IoClosed`.

## Bounds and adapter model

Use 64 KiB chunks and at most 1 MiB of retained native payload per resource by default, with a 64 MiB Application-wide I/O queue budget. Count queued and active payloads, not only queue entries. A read reserves its buffer before admission; a write exceeding available byte admission raises `IoBackpressure` before retaining input. Accepted work waits for OS readiness without growing the queue. Copy retains at most one read chunk plus the remaining write slice.

Native workers own copied bytes/native handles; completion is marshalled to the root lane before creating arbitrary Gene values or invoking code. Worker completion must be pumped by every supported host loop, including the HTTP server, while inference or unrelated tasks wait. Resource IDs include a generation to reject stale completion delivery; IDs do not permit freeing a context still used by a worker.

Text decoding is a separate incremental UTF-8 codec. Protocols carry Bytes. File adapters preserve offsets across short reads; pipe adapters define one reader/writer per descriptor. TCP full-close is supported first; half-close is a later explicit API.

## Implementation and acceptance

| Stage | Work and seams | Required tests |
| --- | --- | --- |
| IO-1 | Add protocols, state machine, scope cleanup leases, error types, and fake adapters in `vm.nim`/`stdlib.nim` and focused new I/O modules. | One-consuming await, repeatable wait_closed, scope exit, busy direction, close/cancel races, late completion, partial writes, admission bounds. |
| IO-2 | Adapt file and subprocess worker/completion paths; preserve existing FS/OS wrappers. | Large streamed copy with fixed memory, EOF, failed open, truncated pipe, close during blocking work, handles released after retirement. |
| IO-3 | Add TCP readers/writers and support HTTP body adapters from [network services](network-services.md). | Slow peer beside fast tasks, cancellation at every boundary, no root-lane wait on a socket, byte-budget accounting across resources. |

The conformance suite must include a third-party Gene type implementing only the qualified protocols, with no direct read/close messages. Run existing task, FS, subprocess, HTTP, and native ownership tests alongside it. IO-1 does not wait for IO-3 or a production M:N scheduler.
