# Gene Life

A persistent individual whose brain returns a short decision note and an
ordinary Gene program. The body, storage, scheduler, worker, APIs, and tests
are written in Gene. This package is independent of Gene Harness and Cordis.

Implementation of [the Life proposal](../../docs/proposals/life.md) is in
progress. Durable continuity, code evolution, and body routines work; remaining milestones
are tracked in [docs/status.md](docs/status.md).

Run these commands from the repository root using the built `bin/gene`:

```sh
bin/gene run examples/life/src/demo.gene
```

The repeatable fake-brain demo remembers a visitor's preference, restarts partway
through a walk, waters the garden, cancels a withdrawn request, and restores a
Gene-defined sleep controller at energy 42 before waking once at 70. It creates
an explicit new Life under `tmp/`, prints its checkpoints, and leaves the retained
experiment available for inspection. An optional path argument chooses a new home.

To run the long-lived body and local chat directly:

```sh
bin/gene run examples/life/src/main.gene create examples/life/tmp/garden
bin/gene run examples/life/src/main.gene run examples/life/tmp/garden
```

In another terminal:

```sh
bin/gene run examples/life/src/main.gene send examples/life/tmp/garden 'I prefer shade.'
bin/gene run examples/life/src/main.gene command examples/life/tmp/garden '{"op":"inspect","prefix":"conversation/"}'
bin/gene run examples/life/src/main.gene command examples/life/tmp/garden '{"op":"pause"}'
bin/gene run examples/life/src/main.gene command examples/life/tmp/garden '{"op":"resume"}'
bin/gene run examples/life/src/main.gene command examples/life/tmp/garden '{"op":"stop"}'
```

`create` never overwrites an existing Life. `run` restores it before invoking
the brain. The fake brain inspects on first start, requests a later wake, and
otherwise considers observations silently. It is a deterministic fixture, not
a conversational model. Explicit operator injection accepts a `decision`
command with `note` and `program` strings. Messages sent through `send` remain
input data and are never evaluated.

For a stopped body, `inspect HOME [PREFIX]` reads raw retained records without
starting inference or changing cognitive state. Use the `inspect` command
through the running body's inbox while its writer claim is held. `run HOME
--manual-clock` advances the world only through `{"op":"tick","ms":1000}`.

An executable decision can publish a walk and its cognitive reference together:

```gene
(store .commit
  (fn [tx]
    (let job (body/world .start_walk "garden" ^tx tx))
    (state .put "activity" {^kind "walking" ^job_id job/id} ^tx tx)
    job/id))
```

Inside a group every participating call must forward `tx`, including calls
inside helpers. The VM's synchronous callback boundary rejects waits, task
creation, and blocking channel operations inside that group. Generated programs
and saved helpers have no direct I/O namespaces. No prepared activity dispatches
until publication. Separate
calls commit separately and may leave partial progress; the host never replays
a failed decision to reconstruct that progress.

The local world uses a one-dimensional logical path between home, garden and
shade. Observation is local within two units; `observe "debug"` is explicit
operator-style full inspection. Walking advances one unit per simulation
second. The world pauses during process downtime. Wall schedules use explicit
lateness policies; cancelled owners invalidate their work.
`scheduler.cron` adds timezone-aware recurrence with explicit missed-run policies,
pinned timezone revisions, and occurrence identities. See
[docs/scheduling.md](docs/scheduling.md) for recurrence, cancellation, and inference budgets.

The host uses Gene's SQLite adapter and an exclusive filesystem claim. It
retains immutable record revisions, context snapshots, accepted notes, programs,
and actual outcomes. Each commit also retains a receipt identifying its exact
write revisions. Local chat delivery and its receipt share a commit. No
external transport or model credentials are needed.

A persistent write failure stops dependent work and makes the current store
connection unusable for further writes. Restore storage access, then reopen the
same Life. A failed final checkpoint is never reported as a clean stop. See
[docs/persistence.md](docs/persistence.md) for the recovery and transaction contracts.

Each complete program is validated and compiled as an ordinary Gene module
function in a fresh supervised Gene process. Functions, loops, and saved
function expressions work. The worker has a step/memory/time policy; its process
also has a three-second deadline. This bounds lifetime leaks and lets the host
receive events and settle pause while generated code loops or waits. The RPC
files transport ordinary application method calls; they do not interpret the
brain's program as a list of action expressions. This is not a general security
sandbox. Saved expressions and immutable module bundles are supported. Module
bundles retain the complete source/import graph, and load through Gene's normal
module loader. The internal transport uses Gene's data-only serializer, so
symbols and quoted Gene data survive without being evaluated.
Ordinary Gene root tasks can make application calls concurrently; the transport
serializes request ownership so replies cannot reach the wrong caller.

An organization can select a saved module that exports `bind(api)` and,
optionally, `context(api, basis)`. These functions supply replacement cognitive
bindings and a bounded context view. The example in
[`src/organizations/visitor_memory.gene`](src/organizations/visitor_memory.gene) replaces the starter memory
and state layouts with a visitor document and a shared working document.

Replacement waits for current affected work to settle, then commits migration
writes, selected code/data roots, and queued-work dispositions together. An
explicitly invalidated late brain response remains inspectable without executing.
See [docs/organization.md](docs/organization.md) for the API, migration contract, and host
repair controls.

Persistent timer and event handlers use the same foreground queue and store.
See [docs/routines.md](docs/routines.md) for registration, recovery, and the optional
energy/rest controller. Its attention policy defers ordinary observations while
sleeping; the host still receives messages and responds to operator controls.

Run the Gene tests:

```sh
bin/gene test examples/life/tests/
```

The tests execute real Gene subprocesses, including fixtures killed with
`SIGKILL`. Temporary Life homes remain under the ignored `tmp/` directory for
inspection. No Python runtime, test runner, or source file is required.
