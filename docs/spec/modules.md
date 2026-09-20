# Applications, modules, reflection, and native boundaries

**Status:** normative and implemented. Executable coverage: module, macro,
entrypoint, serde, native API, and CLI suites.

The sandbox and evaluation boundaries define the
shared security contract. Namespace exposure, resource permissions, and
execution policy are separate controls.

## Synchronous native callbacks

The first supported C callback mode is a call-scoped callback on its owning
Application's root lane. Native bindings provide a typed C entrypoint and a
library-specific abort result. `ffi/callback` declarations still describe ABI
metadata; this release does not provide a general runtime callback-pointer
factory, retained subscriptions, or foreign-thread notification queues.
The wasm target rejects native C callback creation; the transpiled web profile
does not expose this native interface.

`gene/native_api` exports these native-only runtime helpers:

The native caller retains the context until the library guarantees that every
callback has returned and no further entry is possible. The library must not
retain its callback/context after the enclosing call. The C entrypoint itself
may be static code; its context is borrowed. A late call can be rejected only
while that context's storage still exists. Stale native pointers after release
remain a violation of the native binding contract.

The first escaping failure is retained. Gene errors keep their original typed
payload, cause, private classification, and Error witness; panic and cancellation
remain control outcomes. No such exception unwinds a C frame. Unexpected Nim
catchable failures become ordinary runtime errors, and Nim defects become
panics at the callback boundary. Fatal native faults and process termination
remain outside this mechanism's guarantees. An inner rejected native entry
also forces the enclosing callback to return its abort result.

Callback invocation intersects its captured ceiling with current authority
and uses the normal callable/module boundary and enclosing execution budget.
Synchronous callbacks cannot await unfinished tasks, join unfinished tasks,
block on channels or mailboxes, sleep/yield to the scheduler, or pump task
execution. Task/actor creation and native callback re-entry are rejected in
this first mode. Completed-task reads and nonblocking channel operations remain
available. Actor sends may enqueue work but do not drive handlers while the
callback is active. Blocking foreign code is not made interruptible by these
rules.

The Nim-facing `GeneApi` version is **4**. `GeneStatus` adds `gsCancelled`, and
`geneCall` transports cancellation instead of letting it escape the native
boundary. Rooted `geneCallCallback` handles require attachment, their owning
thread, and the synchronous callback rules. Non-function targets require an
explicit `GeneCall.dispatchScope`. Release from another lane or during an
invocation is rejected. Thread attachment is bookkeeping, not permission to
enter another lane or transfer non-Send values. Version-3 extensions must
rebuild and handle the cancellation status.

Executable coverage: `tests/test_native_callbacks.nim` calls a real C visitor
in `tests/fixtures/native_callback_fixture.c`, including foreign-thread and
reentrant entry attempts. The SQLite `visit_text_rows` binding is the first
real library consumer. Native API compatibility coverage remains in
`tests/test_native_api.nim`.

