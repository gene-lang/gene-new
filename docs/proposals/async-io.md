# Async I/O and Resource Lifetime

**Status:** Proposed design; existing `scope`, Task, synchronous Stream, and individual async adapters remain the current contract.  
**Purpose:** Make files, sockets, HTTP bodies, and subprocess pipes compose under one bounded, cancellable I/O model.  
**Syntax:** Ordinary Gene calls and messages; no `async fn` form or async generator is introduced.

## Decision

Define two library protocols, `AsyncReader` and `AsyncWriter`, implemented by owned resource objects. Their operations return Gene Tasks and use `Bytes`; existing synchronous Streams stay synchronous pull cursors. An operation Task belongs to the caller's active `scope`, or the Application root when there is no scope. A resource is explicitly closed, normally from `ensure`. The enclosing `scope` waits/cancels its Tasks as it does today, while closing the resource cancels its still-pending I/O. This separates task lifetime from a resource handle without pretending that a synchronous Stream can await.

| Operation | Contract |
| --- | --- |
| `(reader .read max_bytes)` | Return a Task yielding a nonempty Bytes chunk of at most `max_bytes`, or nil at EOF. Require `max_bytes > 0` and a configured upper bound. |
| `(writer .write bytes)` | Return a Task yielding the number of bytes accepted; zero for an empty input. Partial writes are permitted. `$io/write_all` loops until complete. |
| `(reader .close)` / `(writer .close)` | Synchronous, idempotent close request. Reject new operations; settle pending ones by completion or cancellation. It does not block the root lane waiting for an OS operation. |
| `$io/copy reader writer ^limit n` | Return a Task; transfer in bounded chunks, stop at EOF/limit, propagate error/cancellation, and leave resource closing to its owner. |

One read and one write may be pending simultaneously on a duplex resource. A second read or second write is rejected with a typed busy error, avoiding unspecified interleaving. Close is legal during a pending operation. A Task's result/error remains subject to existing one-time `await` rules; the resource does not consume that result on behalf of callers. `nil` means EOF; an empty Bytes value is not an EOF sentinel. Errors use typed I/O failures with operation, resource, and cause. Panic and cancellation keep their existing classifications.

Illustrative use with current Gene syntax after the library exists:

```gene
(scope
  (let reader ($io/open_read "input.bin"))
  (try
    (let chunk (await (reader .read 65536)))
    (if ($nil? chunk) 0 1)
    ensure (reader .close)))
```

`$io/open_read` is proposed. The `scope`, `await`, `try`, `ensure`, and message forms already exist.

## Backpressure and cancellation

Each adapter has a bounded byte queue and an admission limit. A producer whose queue is full returns a pending Task or an explicit backpressure error according to that adapter's documented policy; it never retains unbounded Bytes. Cancellation removes queued work and requests cancellation of active OS work. If an OS operation cannot be interrupted, its Task remains unsettled until the worker finishes or a bounded shutdown policy reports that limitation; the root scheduler continues serving other tasks. `close` returns nil immediately but the owned wrapper remains pinned until those native operations settle. A late native result after close is discarded without reopening the resource.

Callbacks and generated code run on the owning Gene lane. Worker threads may own immutable byte buffers and native handles under the existing Send rules; they do not manipulate arbitrary Gene scopes or mutable values. A resource cannot be sent to another lane unless its adapter explicitly implements a safe transfer contract. No operation holds a Gene transaction or server loop while awaiting bytes.

## Adapter order

1. Implement protocol conformance and a fake bounded reader/writer in Gene tests. Prove result, EOF, partial write, cancellation, close, and error rules before connecting OS handles.
2. Adapt regular files and subprocess pipes, using the existing async worker path where necessary. Retain current `fs/read_text_async` and `os/exec_*_async` as compatibility helpers.
3. Adapt TCP byte streams and HTTP request/response bodies. Buffered HTTP calls become bounded consumers of the same body reader; the server keeps its admission limits.
4. Measure root-lane responsiveness and memory under one slow peer plus many fast peers. Optimize scheduler/worker implementation only after the contract passes.

**Acceptance:** a task can copy a large file through an HTTP upload or subprocess pipe with bounded memory, cancel halfway, close every handle, and leave unrelated request/task latency within the declared workload budget. The same test runs after a failure at every I/O boundary.
