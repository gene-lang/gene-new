# Copied results for native Task producers

**Status:** implemented in the single `GeneApi` table. The earlier Task
producer family still supports direct completion with `nil` or an ID created
on the root lane. Its `new_text` and `new_bytes` constructors remain root-lane
operations: a short-lived attached thread must not allocate a Nim string,
Bytes object, or managed root that the runtime may release later on the root
lane. The copied submission path below handles fresh worker-computed values
without crossing that allocator boundary.

The added entry transfers
plain C bytes to a bounded runtime queue; the root lane constructs the Gene
value and settles the existing Task. There is no Gene syntax change, new
module loader, or second C ABI. Arbitrary Gene graphs still use the existing
byte-ingress handler on the root lane, where Gene code may decode a copied
payload and call `task_complete` with an owning ID.

## C surface

The optional entry follows `task_retire` in the one `GeneApi` table.
Numeric `GENE_API_VERSION = 6` remains unchanged; callers require both
`struct_size` and the new
`GENE_API_TASK_COPY_FEATURE = 256` bit before calling it. The feature depends
on the existing callback and Task producer bits.

```c
#define GENE_COPY_NIL   UINT32_C(0)
#define GENE_COPY_BOOL  UINT32_C(1)
#define GENE_COPY_I64   UINT32_C(2)
#define GENE_COPY_TEXT  UINT32_C(3)
#define GENE_COPY_BYTES UINT32_C(4)

typedef struct GeneCopiedResult {
  uint32_t kind;
  int64_t scalar;         /* Bool is 0 or 1; Int is signed 64-bit. */
  const uint8_t *data;   /* Only Text and Bytes use this span. */
  size_t length;
} GeneCopiedResult;

uint32_t (*task_submit_copy)(void *runtime_context, GeneProducer producer,
                             const GeneCopiedResult *source,
                             GeneOutBytes *diagnostic);
```

`GENE_API_OK` means the runtime copied and queued the result, **not** that the
user Task accepted it. The call consumes the producer token only after full
validation, capacity reservation, and copying succeed. An invalid kind,
scalar/length combination, null nonempty span, oversized result, full queue,
or allocation failure returns `GENE_API_ERROR` with a copied diagnostic and
leaves the token usable for retry or `task_retire`. The C input span need only
remain valid for the call. `task_submit_copy` may be called on the root lane
or an attached lane, including while the domain is closing and the token is
live. It never calls Gene, blocks on root-lane progress, or runs a C callback.

Nil, Bool, and Int require `data == NULL` and `length == 0`; Nil also requires
`scalar == 0`, and Bool requires `scalar` to be 0 or 1. Text and Bytes require
`scalar == 0`; a zero-length span may have `data == NULL`. The maximum span
is `GENE_API_MAX_COPY_BYTES` (64 MiB). Text is validated as UTF-8 on the
root lane. Invalid UTF-8 after successful submission settles the Task with a
typed ordinary error and still retires the producer. The C worker can choose
Bytes when byte validity is not known. Failure messages already have the
copied `task_fail` entry; this addition is for successful values.

## Queue, ownership, and scheduling

Each C producer is allocated on the root lane at `new_task` and doubles as
its queue node. An attached thread reserves queue count/bytes under the
domain lock, copies a Text/Bytes span into `malloc`-owned memory, then fills
the preallocated producer and links it into
the domain's FIFO. It allocates no Nim object or sequence on the attached
lane. The queue admits at most 256 submissions and 64 MiB of copied payload
per domain; admission reserves both budgets atomically. A failed reservation
does not consume the token. A successful submission removes the token from
the callable-token table but keeps the existing physical Task producer owner,
environment ID, runtime pin, and library borrow until root-lane settlement.
User cancellation does not remove the queued item.

The root lane drains at most 32 entries or 1 MiB of copied payload per poll;
it must process one oversized head entry to guarantee progress. It builds the
Gene Value, invokes the existing managed Task completion, frees the copied C
buffer, and releases producer/environment/library owners in a `finally` path.
If the user Task was already cancelled, the copied value is discarded after
the completion reports `accepted = false`; physical ownership still retires.
The callback registration may have retired before this drain. Module close
waits for queued and in-flight producer counts before unloading the image.

The installed `NativeModule` owner already has a scheduler poll and active
hook. That poll calls `geneManagedPoll(domain)` before advancing module close;
the active hook keeps an awaited external Task from being classified as
deadlocked while a producer or copied result is live. Direct Nim embedders
call `geneManagedPoll(domain)` in their own root event loop. Each C producer
holds one reference to the existing native wake pipe. An attached submitter
writes its nonblocking wake byte while holding the domain lock, before the
root can drain and release the final producer. Direct foreign completion,
retirement and cancellation signal the same pipe, so they do not inherit its
100 ms fallback wait. The wake wait observes producer interest as well as
ingress subscriptions. The package record owns its domain;
a direct embedder owns the domain it created. No global domain registry or
second scheduler queue is needed. Foreign submitters touch only their
domain's preallocated producer and lock, so no Nim container storage crosses
an exiting thread's allocator boundary. No C callback, Gene constructor,
last-owner drop, or `ffi/Library` release runs under a registry lock.

## Acceptance

1. The C fixture submits fresh Int, Text, and Bytes after its callback returns;
   the root poll yields exact values. The installed AtomicArc package awaits a
   worker-produced Bytes Task without manual polling. The text test includes
   non-ASCII UTF-8 and an invalid-UTF-8 error. Existing `task_complete`
   continues to accept already-rooted deep-frozen payload IDs.
2. Cancellation before submission and after enqueue discards the result but
   keeps the physical producer/library owner through root drain. Module close
   waits for that drain. A stale token and a second submission fail.
3. Queue count/byte limits and forced copy-allocation failure reject without
   consuming the token. Retry or retirement succeeds. Every C span may be
   overwritten immediately after the submission call without changing the
   eventual result.
4. The installed source-built GeneApi package launches without source or a
   compiler, awaits a worker-produced Bytes result, and returns all native
   roots, producers, attachments, queue bytes, library borrows, and artifact
   leases to baseline. Focused ORC and threaded AtomicArc tests exercise
   worker exit before root drain. The queue control reaches 10,280 lifetimes
   in one domain by setting `GENE_NATIVE_TASK_COPY_ROUNDS=40` for the C
   callback suite. The focused suite passes under ASAN and TSAN, including
   root polling concurrent with attached submission after domain close.

The implementation is in `src/gene/native_managed.nim`, the public layout in
`src/gene/native_api.h` and `src/gene/native_api.nim`, and native wake sharing
in `src/gene/native_api.nim`. The two checked-in C header copies remain
byte-identical with the canonical header. The existing C ABI fixture and
installed native-module fixture cover the new entry; there is no second
loader or test-only runtime path. Test-only allocation and byte-budget probes
are compiled only for their qualification runs.
