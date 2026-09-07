# Tasks, channels, and actors

**Status:** detailed design reference and rationale. The implemented contracts
are [concurrency](../spec/concurrency.md), [streams](../spec/streams.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 13. Concurrency: tasks, channels, and actors

Gene uses actors as the preferred abstraction for long-lived stateful concurrent components. Actors are built on a smaller runtime foundation of structured tasks, cancellation, and bounded typed channels. Actors are not the only concurrency mechanism: stream pipelines, parallel computation, I/O, and native/GPU work may use tasks, channels, buffers, and specialized runtimes directly.

### 13.1 Runtime scheduler and `Task`

A task is a garbage-collected asynchronous computation:

```gene
(Task result err)
```

Gene uses an M:N scheduler: many Gene tasks run cooperatively across a runtime worker pool. Waiting on a task, channel, timer, or async I/O suspends the current Gene task rather than blocking an operating-system worker thread.

Structured concurrency uses three core forms:

```gene
(scope
  (var a (spawn (compute_a)))
  (var b (spawn (compute_b)))
  (+ (await a) (await b)))
```

Rules:

- `scope` owns tasks spawned directly inside it;
- `spawn expr` evaluates `expr` in a child task and returns `(Task T E)`;
- `await task` suspends the current task and returns its value or propagates its recoverable error;
- `task/.join` suspends without propagating or consuming the task payload and
  returns repeatable `TaskOutcome/ok`, `error`, `panic`, or `cancelled` data;
- leaving a scope normally waits for its live child tasks;
- leaving because of an error or cancellation cancels remaining children, waits for cleanup, and then propagates;
- cancellation is cooperative and is observed at suspension points and compiler/runtime safepoints;
- `ensure` cleanup runs during cancellation;
- detached lifetime is explicit and is not the default MVP behavior.

Placement-sensitive code can require the owning scheduler's root lane:

```gene
(spawn ^lane root
  (drive_terminal_ui))
```

Use this for UI frameworks and other thread-affine native APIs. It disables
worker-candidate placement and capture snapshotting even when static analysis
would otherwise consider the body worker-safe. `root` is currently the only
explicit `^lane` value; omitting `^lane` retains automatic placement.
Root-lane spawn enqueues the child and returns its `Task` before the child body
can begin. Lane-owned modules assert their call site with
`$runtime/require_root_lane`, which raises `RuntimeLaneError` off the scheduler
root lane without exposing thread or scheduler ids.

Task placement has two paths. A root-lane cooperative task may retain local,
non-`Send` captures such as `Cell`; it never migrates. A worker-candidate task
is selected only after its complete captured graph passes the worker-safe
`Send` check, and receives a detached capture snapshot before enqueueing.
Worker results and recoverable/panic payloads are checked again before they are
published back to the owning lane; a non-`Send` payload becomes a task boundary
error. This final check is necessary for dynamic code whose result cannot be
proven before execution. Worker-safe actor turns apply the same rule to the
handler closure, current state, inbound message, reply capability, replacement
state, and failure payload. An actor that fails the pre-enqueue graph check
stays on the root lane.

The program entry point runs as a root task, so `await` is meaningful without an `async fn` distinction. A function containing `await` is lowered to a resumable task frame as needed. Native compilation may initially route suspension through runtime helpers and later perform dedicated coroutine lowering.

A task may be cancelled explicitly:

```gene
(t .cancel)
```

Lifetime owners that must observe every child use `(t .join)`. Unlike `await`,
`join` converts the target's terminal state to immutable `TaskOutcome` data,
may be repeated, and leaves a successful/error payload available to a later
`await`. Cancelling the joining task still propagates cancellation normally and
does not cancel an otherwise independent target task. Panic summaries are
bounded to 4096 UTF-8 bytes.

Cancellation is represented separately from ordinary domain errors, but may be caught only by APIs that deliberately expose cancellation handling. Code should normally allow it to propagate. Concretely:

- cancellation is a control signal, not an `Error`; `try/catch` — including
  `catch Any` — does not catch it, so it propagates through catch clauses;
- `ensure` blocks always run during cancellation cleanup;
- `await` on a cancelled task propagates the cancellation;
- an actor observes cancellation after the current message completes or at its
  next suspension/safepoint (§13.4), never mid-message.

### 13.2 Typed bounded channels

A channel transports values between tasks:

```gene
(Channel T)
```

Channels are bounded by default to provide backpressure:

```gene
(var ch ($channel ^capacity 64))

(ch .send value)       # suspends while full
(var value (ch .recv)) # suspends while empty
(ch .close)
```

Conceptual operations:

```text
send      : [(Channel T), T] -> Nil ^errors [ChannelClosed]
recv      : [(Channel T)] -> T ^errors [ChannelClosed]
try_send  : [(Channel T), T] -> Bool
try_recv  : [(Channel T)] -> (TryRecv T)
close     : [(Channel T)] -> Nil
```

`TryRecv` is a tagged result with variants `TryRecv/empty` and
`(TryRecv/value payload)`. Empty state is therefore distinct from receiving a
stored `void`, `nil`, or any ordinary `T` value; all four cases remain
pattern-matchable without a sentinel convention.

```gene
(enum TryRecv [T] empty (value T))
```

A dynamic `Any` value is checked against `T` and the `Send` requirement before it enters the channel. Failed dynamic-to-typed checks raise recoverable boundary `TypeError` with blame.

Closing a channel prevents future sends. Buffered values remain receivable before `ChannelClosed` is reported. Multiple producers and consumers are allowed; ordering is FIFO for successful sends as observed by the channel.

### 13.3 The `Send` protocol

Values crossing task/actor concurrency boundaries must be safe to transfer:

```gene
(protocol Send)
```

`Send` is a marker protocol checked statically where possible and dynamically at gradual boundaries.

Built-in sendability rules:

- numbers, booleans, symbols, `nil`, `void`, immutable strings, immutable code artifacts, and actor references are sendable; closures/functions are sendable only when all captured values are sendable;
- `#[...]`, `#{...}`, and `#(...)` are sendable only when every contained value participating in the structure is sendable;
- mutable lists, maps, and nodes are not sendable by default;
- `Cell` is not sendable;
- `AtomicCell T` may be sendable when its implementation is thread-safe and `T` is sendable;
- `Env`, raw FFI pointers, thread-affine handles, and capability descriptors are
  not sendable unless their concrete type explicitly implements `Send`;
  sealed capability grants are never Gene values;
- generic immutable containers derive `Send` conditionally from their element/key/value types.

Shallow immutability alone does not imply sendability:

```gene
#[($cell 1)] # shallow immutable, but not Send
```

A future ownership/move system may permit transferring uniquely owned mutable values. MVP avoids that complexity and requires immutable/sendable messages or explicitly thread-safe handles.

### 13.4 Actors

An actor owns a mailbox, a handler, and private state. Other code interacts with it only through a typed reference:

```gene
(ActorRef Message)
```

Example message types:

```gene
(type Increment
  ^props {^amount Int})

(type Get
  ^props {^reply (ReplyTo Int)})

(type Stop)

# ActorRef may use a union message type directly:
# (ActorRef (| Increment Get Stop))
```

An actor is created with an initialization function and a handler:

```gene
(var counter
  ($actor/spawn
    ^mailbox 256
    ^init (fn [] 0)
    ^handle counter_handler))
```

The initialization function runs inside the actor and creates its private state, avoiding mutable aliases held by the spawning task.

A handler processes one message and returns an actor step:

```gene
(fn counter_handler
  [ctx : (ActorContext (| Increment Get Stop)), state : Int, msg : (| Increment Get Stop)]
  : (ActorStep Int)

  (match msg
    (when (Increment ^amount n)
      ($actor/continue (+ state n)))

    (when (Get ^reply reply)
      (reply .send state)
      ($actor/continue state))

    (when Stop
      ($actor/stop))))
```

Core guarantees:

- exactly one message is handled at a time for each actor;
- the next message is not started until the current handler completes;
- awaiting inside a handler suspends that actor without making it reentrant;
- messages from one sender to one actor are processed in send order;
- ordering between different senders is unspecified;
- actor-local state is not directly accessible through `ActorRef`;
- actors may run on different worker threads over their lifetime;
- `ActorRef M` is sendable and enforces the mailbox message type `M`.

`actor/spawn ^type M` is authoritative when supplied. Without `^type`, the
runtime uses the third handler parameter's annotation when it is present;
otherwise it stores `Any`. Actor reflection and `(ActorRef M)` type inference
use that resolved message type. `Send` is enforced independently for every
mailbox value even when `M` is `Any`.

A handler commonly returns immutable replacement state. It may also use actor-private mutable objects created by `^init`, because no external mutable aliases exist by construction.

### 13.5 Sending, backpressure, and request/reply

Actor mailboxes are bounded by default.

```gene
(counter .send (Increment ^amount 5))
(counter .try_send (Increment ^amount 1))
```

Conceptual behavior:

- `actor/send` suspends until mailbox capacity is available and raises `ActorClosed` if the actor has stopped;
- `actor/try_send` returns immediately with `Bool`;
- a value must satisfy both the actor's message type and `Send` before entering the mailbox.

Request/reply uses an explicit one-shot reply capability:

```gene
(var pending
  (counter .ask
    (fn [reply]
      (Get ^reply reply))))

(var value (await pending))
```

`actor/ask` returns `(Task R ActorError)`. `ReplyTo R` requires `Send R`; it is sendable, single-use, and may carry timeout/cancellation state. Ask is convenience over normal messages; it does not make actors synchronously callable.

Single-use is enforced: a second `ReplyTo/send` on the same reply raises the
recoverable error `ReplyAlreadySent` (a subtype of `ActorError`). This is a
programming error in the replying handler, not a delivery condition.

### 13.6 Lifetime, scopes, and supervision

Actors are owned by a task scope or supervisor, not merely by the reachability of an `ActorRef`. Actor references are garbage-collected handles; dropping the last reference does not substitute for orderly shutdown.

```gene
(scope
  (var worker
    ($actor/spawn
      ^init make_state
      ^handle worker_handler))
  ...)
```

When the owning scope exits, child actors are asked to stop and remaining work is cancelled according to the scope policy.

Long-lived actor trees use supervisors:

```gene
(supervisor
  ^strategy restart
  ^events failures
  ^dead_letter dead
  ($actor/spawn
    ^init make_state
    ^handle worker_handler))
```

MVP supervision strategies:

- `restart`: create fresh state with `^init` and resume with the existing mailbox policy;
- `stop`: terminate the actor and close its mailbox;
- `escalate`: report failure to the parent supervisor.

`restart` supervisors accept a restart budget: `^max_restarts N` stops the
actor instead of restarting once N restarts have been consumed, and
`^within_ms W` makes that budget a sliding window — the count resets when W
milliseconds pass since the window opened. Omitted or non-positive values mean
an unlimited budget; `^max_restarts` alone bounds restarts over the actor's
lifetime. Stopping on an exhausted budget behaves exactly like the `stop`
strategy for the failing message.

A recoverable error escaping an actor handler stops that actor and produces a failure event for its supervisor. A panic also terminates the actor/task and is escalated. Native memory corruption or an unsafe foreign crash remains process-fatal.

MVP supervisors may be given `^events failure_channel`. The runtime emits
`ActorFailure` values to that channel on actor handler failure without blocking
the failing actor path. An event includes the actor reference, failed message,
error value, display message, panic flag, and active supervisor strategy. A
supervisor may also be given `^dead_letter channel`; when the primary event
channel is closed, full, or rejects the event, the runtime attempts to write the
same `ActorFailure` to the dead-letter channel. A full sink without an available
fallback queues the failure in one application-owned FIFO with capacity 64 and
retries when a channel receive frees space. The queue allocates no task or fiber
per notification. On overflow the newest notification is dropped; a
closed/rejected queued sink is also dropped. `$runtime/gc_stats` exposes
`supervisor_retry_pending`, `supervisor_retry_capacity`,
`supervisor_retry_high_water`, and `supervisor_retry_drops`. Failure handling
and the original actor error remain independent of notification delivery.

Restart policy must define whether queued messages are retained, discarded, or moved to a dead-letter channel. The MVP default should discard the message that caused failure and retain later queued messages only for explicitly restartable actors.

### 13.7 Actors, streams, native code, and eval

Actor mailboxes may be implemented using channels, but the raw mailbox stream is not normally exposed to actor code. Actors may publish events through ordinary channels or streams.

Handlers may be bytecode functions, native-compiled typed Gene functions, registered native callables, or functions produced by `eval`. Invocation uses the ordinary `Callable` model. Native handlers can enter the VM through the existing trampoline, and dynamic handlers can call native typed functions through generated adapters.

The scheduler and GC must root task frames, channel buffers, actor mailboxes, actor state, handlers, reply capabilities, and pending errors. Foreign threads may interact with actors only through the runtime's thread-attachment and rooted-send APIs once those APIs are implemented.

### 13.8 Live actor evolution

Actors provide a natural future safe point for self-evolving code:

```text
finish current message
→ pause mailbox
→ validate new handler
→ migrate or replace private state
→ install new handler version
→ resume mailbox
```

The experimental API exposes:

```gene
(ref .upgrade new_handler
  ^migrate migrate_state)
```

The MVP may expose an explicit experimental `(ref .snapshot)` operation
for migration tooling. It is only valid at an idle actor safe point and returns
the last committed private state plus mailbox/lifecycle metadata; it must not
replace the normal message protocol for application-level state access.

An upgrade never replaces a handler while it is executing. Failure during validation or migration leaves the old handler/state active. Full live migration policy is post-MVP but should constrain actor and module version identity from the beginning.

### 13.9 Concurrency scope

MVP concurrency includes:

- structured `scope`, `spawn`, `await`, and cancellation;
- `(Task T E)`;
- bounded typed `(Channel T)`;
- `Send` boundary checks;
- sequential typed actors with bounded mailboxes;
- `send`, `try_send`, and request/reply;
- actor scope ownership and basic supervision.

Deferred features include distributed actors, transparent remote references, work stealing across processes, selectable channel operations, ownership-transfer typing, transactional memory, reentrant actors, and stronger live-migration policies.

---
