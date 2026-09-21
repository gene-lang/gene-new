# Durable operation and recovery boundaries

The single writer owns an exclusive filesystem claim and one Gene SQLite
connection. Cognitive payloads remain generic Gene data. The host and local
adapters separately validate identity, storage version, immutable head references,
world fields, inventory, conversation records, and walking checkpoints on open.
A disagreement between an active walk and the authoritative position is a
recovery failure; opening never substitutes a newly created Life.

Records are copied by value. Every successful commit publishes related writes
and a `commit/<id>` receipt in the same database image. The receipt records its
cause and the immutable revision of every written record. An execution interrupted
after commit but before its response can inspect that receipt and the retained
records without replaying its callback. Immutable revisions remain readable
through `store.revision` while retained.

## Grouped writes

`store.commit(callback)` supplies a short-lived transaction handle. Participating
calls stage changes and return prepared IDs; the outer call returns its callback
result only after publication. Reads see a consistent snapshot and staged writes.
Conflicting read revisions reject the whole group without automatically retrying
the callback. A normal conflict does not damage the store connection.

Every participating operation, including calls through helpers, must forward
`tx`. Nested groups and expired handles are errors. Standalone operations commit
before returning, so a process exit between two standalone calls can expose a
partial result. The walking-link test demonstrates inspecting the published job
and repairing its cognitive reference without creating another walk.

Generated source and saved expressions compile through the normal Gene module
loader, using application bindings and no direct I/O namespace grants. Complete
source is compiled before execution. `src/worker/program.gene` generates the lexical binding
wrapper; it does not dispatch or interpret an action language.

The grouped callback enters Gene's existing synchronous native callback contract
through a private in-memory SQLite row visitor. That VM boundary rejects sleep,
task creation, await, and blocking channel operations transitively, including
inside saved helper functions. The private connection holds no Life state.
Local RPC waits within this boundary do not pump the worker's scheduler; the
host remains responsive in its own process. Ordinary calls outside the boundary
can wait and use Gene root tasks, with serialized transport ownership.

Module executions have one-million-step, 64-MiB and two-second budgets, plus a
three-second subprocess deadline. These controls and namespace exposure are
execution boundaries, not a general operating-system security sandbox.

## Failed publication

The SQLite backend keeps a connection-local image and publishes it atomically.
A failed publication could leave that image ahead of the file, so Life marks
the connection as requiring recovery and never uses it for another commit.
The last known committed snapshot remains available for host inspection until
the connection closes. It never becomes a successful write merely because a
later filesystem operation might work.

Dependent dispatch stops, execution handles are cancelled, and the failed
connection closes without writing a clean-shutdown marker. After storage access
is restored, reopening validates and recovers the preceding committed image.
The real-filesystem test removes directory write permission during publication,
compares the database bytes before and after failure, and verifies that neither
the uncommitted state nor the program's following world action occurs. It also
checks that an unaccepted message does not advance the connector cursor.

## Interrupted execution

| Retained work | Recovery |
| --- | --- |
| Published job or schedule invocation that never started | Dispatch under its retained identity after admission checks. |
| Started arbitrary program | Preserve partial effects and mark interrupted; never replay its source automatically. |
| Walking activity | Continue from the joint world/job checkpoint under the same job ID. |
| Ordinary routine without a continuation contract | Suspend the registration and retain the interrupted execution reference. |
| Explicit checkpointed routine | Resume the declared handler with the same delivery input; its library must deduplicate committed intervals/effects. |

Schedules reconcile their status with their retained execution record. A queued
execution remains eligible; an interrupted execution does not leave the schedule
misleadingly marked as still running. Partial outcomes and notes remain linked
to their actual status. Pause invalidates the authority of late model responses;
resume builds fresh context and applies lateness policies to due work.

The tests use separate Gene processes killed without shutdown hooks for these
cases, as well as clean stop/reopen tests. Storage failure, uncommitted work,
and interrupted execution are distinct conditions; no recovery path
infers success from a decision note.
