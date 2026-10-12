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

## What a read, a transaction and a commit cost

The host keeps the head of every record in memory, by key, with one list of
keys for each leading path segment (`cycle/`, `event/`, `job/`, …). A commit
writes its records and its receipt to the database and replaces those heads; it
leaves the others alone. Beginning a transaction copies nothing. A cycle
therefore costs what it reads and writes, however much the Life has retained.

A transaction still sees the store as it was when it began. It notes the
store's newest revision at that moment: a head that a later commit replaced is
read back from the database at that revision, and a key first written later is
absent. Its reads are checked at commit as before, and a record that moved
rejects the whole group.

Commit receipts are not held in memory. Every commit writes one and almost
none is read again, so a `commit/<id>` record is read from the database, by key
or under the `commit/` prefix, when it is asked for. Only a commit writes one.

The scans that run on every heartbeat — runnable work, observations not yet
considered, due schedules, active walks, open deliveries — use `count_where`,
`values_where` and `tx_keys_where`. They test records where they are and copy
only the ones that match. `values` and `keys` over a whole prefix remain for
recovery, inspection and tests.

### Cycle time as history grows

`probes/cycle_growth.gene` gives a fake-brain Life one visitor message at a
time. Every cycle runs the same small program (one state write, one memory),
so a change in cycle time comes from what the Life has retained:

```sh
bin/gene run examples/life/probes/cycle_growth.gene 200 file
```

Median milliseconds per cycle, over windows of 20 cycles, before and after the
store stopped copying itself (2026-10-12; macOS 27, Apple M4 Pro, APFS, SQLite
3.54.0, optimized `gene` built from `eed4045`):

| Cycles | Before, `life.sqlite` | Before, `life.db` | After, `life.sqlite` | After, `life.db` |
| --- | ---: | ---: | ---: | ---: |
| 1–20 | 178 | 182 | 90 | 99 |
| 41–60 | 527 | 517 | 99 | 104 |
| 81–100 | 938 | 909 | 108 | 108 |
| 141–160 | 1765 | 1566 | 118 | 112 |
| 181–200 | 2239 | 2141 | 126 | 111 |

Before, each transaction serialized every head twice, and each heartbeat copied
every cycle, observation and execution to find the few still open; both
backends slowed alike, by about 10 ms for every cycle already lived. After,
the incremental store is flat across this run. Over 1,000 cycles on `life.db`
the median goes from 100 ms to 179 ms.

What still grows, and belongs to retention (world.md §12.8):

- `life.sqlite` republishes its whole image on every commit, 8 MB after 200
  cycles here. A Life meant to run for long should be created on `life.db`.
- A conversation is one record holding every message, rewritten for each new
  one. With retained revisions that is the larger part of the 105 MB the
  1,000-cycle store reached.
- A heartbeat scan still tests every retained cycle, observation and
  execution, without copying it. Nothing archives finished ones yet.

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

## Storage backends

A Life's backend is fixed when it is created and recognized afterwards by which
file exists; both behind the same record/commit interface:

| File | Backend | Commit |
| --- | --- | --- |
| `life.sqlite` | `$db/sqlite/open` | Republishes the whole database image atomically. The local default. |
| `life.db` | `$db/sqlite/open_file` | WAL with `synchronous=FULL` and `fullfsync`; only changed pages are written. Networked Lives use it; `LIFE_STORAGE=file` makes it the default for new local Lives. |

Both put records, head moves and the commit receipt in one transaction. The
failed-publication contract below is stated for the image backend; on either
backend a failed commit marks the connection unusable until reopen.

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
