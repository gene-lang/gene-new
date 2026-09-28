# Single native C ABI qualification — 2026-09-28

The project now has one public native C layout in
[`src/gene/native_api.h`](../../src/gene/native_api.h) and one module entry
symbol, `gene_module_init`. Its numeric `version` remains 6 to identify the
qualified opaque layout; no version suffix appears in public C names.
The former v4 Nim function table, v5 C ingress table, versioned loaders, and
their headers have been removed. In-repo direct Nim helpers remain.

`native/ingress/open` passes an ingress-only view of that layout to a typed
registration shim. The `genex/libuv_timer` shim copies the table, queues bytes
without touching Gene objects on its libuv thread, and retains its existing
physical unregister protocol. The managed loader passes the same layout with
mediated feature bits and a stable per-domain table. General callback slots
remain unadvertised.

Validation on macOS arm64:

- The installed timer app passed 10,000 create/notify/close lifetimes with its
  source tree hidden and compiler unavailable. Each close left zero live C
  contexts and libuv handles; 20,000 handle close callbacks were counted;
  native roots and materialized leases returned to baseline.
- The C managed ABI fixture passed under default ORC and threaded AtomicArc.
  The C ingress fixture and threaded native API suite passed under AtomicArc.
- The broad `tests/test_all.nim` suite passed after the ingress and C ABI
  migration. After removing the obsolete Nim function table, its focused
  native API suite passed and the full suite passed `nim check`.
- A nonstandard ORC-with-threads run crashes in the concurrent Task join test
  after all ingress tests pass. An unchanged `538764d` worktree reproduces the
  same failure at the same test, so it is not a regression of this migration.

The ingress subscription still roots a raw Gene handler and Scope until
physical retirement. Moving those references to mediated handles, implementing
general retained C callbacks, and retaining a managed module's library across
those registrations are the next ownership tasks. Linux and the two-hour
SERVICE heartbeat remain deferred by the owner.
