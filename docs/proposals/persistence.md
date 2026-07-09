# Gene Persistence & Reload — Design

Status: **controlled-stop MVP implemented** (stages 1-4: `Store` protocol,
`store/sqlite`, gateway migration, `Fs/make-dir`/`Fs/remove`, and `store/fs`).
Crash/power-loss hardening remains deferred to §7 / stage 5. Date:
2026-07-09.

Goal: let a Gene application **save its durable state to a store and reload it
on the next run**, so a controlled stop-and-restart resumes where it left off.
The application decides *when* to save (explicit save points, not automatic
checkpointing) and, at startup, decides *whether* to load existing state (a
resume flag) or start fresh.

**Scope, deliberately narrowed.** This is *controlled stop and reload*, not
crash recovery. Surviving an arbitrary kill or power loss with zero corruption
— atomic writes, `fsync` discipline, write-ahead logging, stale-temp recovery
— is a real but separable problem, deferred to §7. Starting from the
controlled case keeps the first public `store` contract small and lets the
durable-state model prove out before the crash-hardening machinery.

This design sits *above* serialization: `serde`
(docs/proposals/serialization.md, stages 1–6 shipped) is the format;
persistence adds a durable key→value store and a reload protocol over it.

## 1. The one lesson from the prior implementation

The older Gene repo built **tree-serdes** — `write_tree`/`read_tree` exploding
values into directory trees with reserved marker files — then **removed it**
because it created a *second public serialization model.* The replacement kept
the good ideas (opaque ids, path-escape/cycle rejection, atomic writes) but
collapsed to one wire format. The directive here follows: **do not invent a
second serialization format.** `serde` is the format; persistence is file/db
I/O plus a store convention over serde text, nothing more.

## 2. What "durable state" is here

There is no "freeze the running VM," and pursuing one is the trap. This
runtime is shared-nothing and actor-based; its live state — scheduler fibers,
channels, tasks, actor refs, sockets, DB connections, native handles — is
exactly `serde`'s **bucket 3 (not serializable).** That is the *correct*
boundary, not a limitation: the serde bucket classification already answers
"what can be saved."

| Live thing (not saved) | Its durable projection (saved) | Reload action |
|---|---|---|
| Actor ref + mailbox + handler fiber | actor **state** (`actor/snapshot` → data) | re-`actor/spawn` from saved state |
| DB connection / socket / server handle | its **config** (path, host, port) | reopen from config |
| Channels, tasks, in-flight work | — (transient) | start fresh |
| Cell (identity) | its **contents** | new cell around loaded value |
| Capability value | **never saved** (authority) | re-granted by the launcher |

So a program's saveable state is exactly the set of values it can hand to
`serde` — which the write path already enforces, raising `SerdeError` with a
path on anything process-bound. Persistence inherits serde's security posture
wholesale: no capability round-trips, `serde/read` never loads a module named
by a payload, restore hooks stay off unless explicitly enabled.

**`serde-state`/`serde-restore` (stage 5) are the per-type reload primitive.**
A type owning a transient resource implements them to save only its durable
fields and re-derive the resource on load — the canonical "drop the socket,
keep the host, reconnect on load." Persistence is their motivating use case.
(Reload runs `serde-restore`, i.e. user code, so it is gated — see §3.)

## 3. The `Store` — a durable key→value log over serde

One capability-gated abstraction, shaped like the existing `Db` protocol
(`db/sqlite`/`db/postgres` behind one `Db`), so filesystem now and database
later are the **same interface with interchangeable backends**. Backends are
their own namespaces, mirroring `db/sqlite/open` (review: no ambiguous
`(open fs …)` selector-vs-capability form):

```gene
(import store/sqlite [open : store-open])
(var s (store-open db))                     ; layered over an existing Db conn

;; or, filesystem:
(import store/fs [open : store-open])
(var s (store-open fs ^root ".state"))      ; fs : Fs/ReadWriteDir capability

(s ~ put key value)          ; ^mode data|full (default data)
(s ~ get key)                ; raises StoreError ^kind missing on absence
(s ~ get key ^default v)     ; returns v when the key is absent
(s ~ has? key)               ; -> Bool
(s ~ delete key)
(s ~ keys)                   ; -> [Str]
(s ~ clear)                  ; drop all records (for a "start fresh" init)
(s ~ close)
```

Decisions, several from review:

- **Records are independent.** A store is a flat map of `Str` key → one
  serialized value. There is no global snapshot to rewrite wholesale (the
  prior repo's fatal `_genearray`-rewrite-per-turn cost). Each `put` writes
  one record; a reload reads the records it wants. `keys` + `get`-all is **not**
  a transactionally consistent snapshot (§6 shows the cross-record pattern).
- **`get` on a missing key raises `StoreError ^kind missing`**, never returns
  `void`. `void` and `nil` are both serializable values a program may store,
  so a sentinel return would be lossy. Use `has?` when absence is expected, or
  `^default` to supply a fallback.
- **`^mode data|full`, on the store, overridable per call** — the store's own
  option, *not* an overload of `SerdePolicy` (shipped serde has read-policies
  only; `write` takes none, and there is no `data-only` policy field):
  - `data` (default) → `serde/write-data` / `serde/read-data`. Pure data,
    no reference resolution, no code execution. This is the safe default and
    what the gateway needs.
  - `full` → `serde/write` / `serde/read`. Allows typed refs and instances;
    the application must have loaded the defining modules first (§5).
- **Restore hooks are off by default, even in `full` mode.** `serde-restore`
  executes user code; making that the default for every `get` would turn a
  tampered state file or db row into an implicit execution trigger. Opt in
  explicitly with `(s ~ get key ^policy (SerdePolicy ^allow-restore true))`,
  or set a trusted-state policy at `open` — for the app's own state directory
  it controls, never for a store fed external input.
- **Read `^policy` (a `SerdePolicy`) passes through to `serde/read*`** for
  resource limits and `^allow-restore`. Writes take no policy (serde has no
  write policy); `^mode` is the only write knob.
- **`StoreError ^kind ^key ^message`** with a stable kind so callers branch
  without parsing messages: `missing`, `serde` (encode/decode failed), `io`
  (backend failure), `closed`, `invalid-key`, `corrupt` (record unreadable).
- **Backends** implement the `Store` protocol:
  - `store/sqlite` — a table `(key text primary key, data text)` over an
    existing `db/sqlite` connection (review: take a `Db`, not a path — keeps
    the store layered and avoids a second sqlite authority story). **Works
    today with no new runtime**; the gateway is the proof. Ships first.
  - `store/fs` — a directory of records (§4). Needs the small Fs surface in
    §4.1.
  - `store/postgres` later, free, over `db/postgres`.

Both backends store the *same* serde text under the *same* key API, so a store
written by one reloads through the other — "filesystem now, db later" is a
backend swap, not a rewrite. That is the payoff of one format.

## 4. Filesystem backend (controlled-stop MVP)

A store is a directory; each record is one file holding one `serde-v1`
envelope. Flat, **not** a directory tree (the prior repo's removed model):

```
.state/
  session%3Atg-42.gene      # url-encoded key -> one serde envelope
  config.gene
```

- **Key → filename** via `url/encode_component` (in stdlib), reversibly, so
  keys may contain `/`, `:`, spaces, unicode without escaping the directory,
  and `keys` is `Fs/list-dir` + url-decode. Empty keys are rejected
  (`StoreError ^kind invalid-key`) — an empty key would produce a bare
  `.gene` file.
- **No reserved names, no marker files** — a record is just a file. (The prior
  model's permanent `_genetype`-key-collision gap cannot occur.)
- **Tolerant `keys`** (review #6): only names that url-decode to a valid key
  with a `.gene` extension are returned. Anything else in the directory
  (editor backups, files from other tools, future temp files) is ignored, not
  an error — a store directory is not assumed pristine. A separate
  `store/fs/audit` for surfacing unrecognized files can follow.
- **Reads/writes** are `Fs/read-text`/`Fs/write-text` + `serde`. **MVP uses a
  plain write** — acceptable because a controlled stop lets the `put`
  complete before exit. Atomic replace (temp+rename+fsync) is the §7
  crash-hardening upgrade, not required here.

### 4.1 Runtime gap (small, for the fs backend)

Today `Fs/*` is only `read-text`/`write-text`/`list-dir` (+ async). The
controlled-stop fs store needs two new `Fs/WriteDir`-gated natives beside
them in `src/gene/stdlib.nim`:

| New native | For |
|---|---|
| `Fs/make-dir` (mkdir -p) | create the store directory on `open` |
| `Fs/remove` | `delete` / `clear` a record |

`Fs/exists?` is convenient but optional (a failed `read-text` already signals
absence). The shipped `Fs/make-dir`/`Fs/remove` follow the existing broad
`Fs/*` path semantics; `store/fs` keeps record paths confined by composing the
caller-chosen root with a URL-encoded key that contains no path separators.
`Fs/rename` and the atomic-write native belong to §7. The **sqlite backend
needs none of this** — another reason it ships first.

## 5. Stop-and-reload model

Reload is an application pattern with three obligations; there is no magic
"restore the process":

1. **Save at chosen points.** The application calls `put` when *it* decides —
   after a meaningful unit of work, on a `/save` command, on graceful
   shutdown. There is no automatic checkpoint-on-every-mutation; save
   granularity and timing are the app's call. (The gateway's natural point is
   `turn_done`.)
2. **Choose load-or-fresh at init, via a flag.** On startup the application
   reads a resume flag (an env var / config / CLI flag it owns). If set, it
   `keys` + `get`s the records it needs and reconstructs. If not, it starts
   fresh — either ignoring existing records or calling `(s ~ clear)` for a
   clean slate. The store provides both paths; the *decision* is the app's.
3. **Reconstruct + re-wire, having loaded modules first.** For each loaded
   record, rebuild the data, then re-`actor/spawn` from saved state, reopen
   connections from saved config, rebuild routes. **In `full` mode the app
   must import every module that defines a persisted type before `get`**
   (review #7): `serde/read` resolves refs only against already-loaded modules
   and will *not* load a module named by a payload — that is the
   no-code-execution guarantee, and the store must never undermine it by
   auto-loading. Reconstruction is app code because only the app knows how its
   live graph maps to its data; the gateway's restore (re-spawn the session
   actor, reattach the Telegram sender hook, resume the id sequence) is the
   worked example.

**Save-state shape.** `serde-state` (stage 5) should return a **data-bucket**
value (review #9): keeping hook state pure data makes reload simpler, safer,
and easier to migrate, and avoids identity-ref/module-order surprises inside
restore state. Types that genuinely need refs in their state use `full` mode
records directly rather than a hook.

## 6. Cross-record consistency is the app's job

Records are independent; `keys` + `get`-all is a set of point reads, not a
consistent snapshot. When two records must agree, the application orders its
saves and tolerates the in-between state on reload. Example — a session plus
an "unprocessed input" marker, so a stop between accepting input and finishing
its turn reloads sensibly:

```gene
(s ~ put (str "pending:" id) input)        ; 1. record the accepted input
;; ... process the turn ...
(s ~ put (str "session:" id) new-state)    ; 2. record the result
(s ~ delete (str "pending:" id))           ; 3. clear the marker
```

On reload: a `pending:*` with no matching completed state means a stop
happened mid-turn — the app re-runs it from `input`. This is an app-level
write-ahead pattern, shown so future readers do not assume the store gives
cross-record atomicity. (Multi-record `store ~ transaction` — trivial on
sqlite, harder on fs — is a later addition.)

## 7. Deferred: crash & power-loss hardening

Everything needed to survive an arbitrary kill or power loss, explicitly out
of the controlled-stop MVP and gathered here for when it is built:

- **Atomic fs writes**: unique temp file *in the target directory* → write →
  `fsync` temp → `rename` over target → `fsync` the parent directory. Without
  the directory `fsync` the rename may not be durable across power loss; the
  unique temp name avoids concurrent writers clobbering one staging file.
  New natives: `Fs/write-text-atomic`, `Fs/rename` (same-directory-confined
  when used for commit).
- **Delete durability**: unlink + `fsync` the parent directory.
- **Stale-temp recovery**: `open`/`keys` ignore recognized temp files; an
  optional sweep removes them.
- **Write-ahead** for at-most-one-lost instead of at-least-committed: the §6
  `pending:*` pattern generalized, or a store-level WAL.
- **Corruption detection**: a record that fails to parse raises
  `StoreError ^kind corrupt` rather than crashing the reload; the app decides
  to skip, default, or abort.
- **A real crash/power-loss test harness** (kill mid-write, assert last
  committed record intact) or a clearly documented simulation limit.

sqlite already gives per-`put` atomicity via transactions, so the sqlite
backend is crash-safe for a single `put` without any of the above — fs is the
one that needs this work.

## 8. Migrating the gateway (the first consumer)

`examples/agent_gateway.gene` milestone 11 already persists sessions to sqlite
by hand (`write-data`/`read-data` + `insert or replace`). It becomes the
reference `Store` consumer:

- `GENE_GATEWAY_DB=path` → `store/sqlite/open` over the `db/sqlite`
  connection; a later `GENE_GATEWAY_STATE=dir` → `store/fs/open`. Same session
  code, chosen backend.
- The resume flag (§5.2) surfaces as e.g. `GENE_GATEWAY_RESUME` — default on
  when a store is configured; off starts fresh.
- **Migration uses `data` mode first** (review #10) — the gateway stores pure
  session maps, so `data` keeps existing rows loading and avoids pulling
  typed-ref/module-order behavior into the gateway before the store API is
  proven. `full` mode is available later if a session ever holds typed
  instances.

No serialized-format change (both already store serde-shaped data), so
existing databases keep loading, and bespoke persistence code retires.

## 9. Non-goals (first version)

- Crash / power-loss durability (§7, deferred) — the MVP is controlled stop.
- Serializing live scheduler state (fibers, channels, tasks) — impossible and
  unnecessary (§2/§5).
- A global consistent snapshot / cross-record transactions — records are
  independent (§6); `store ~ transaction` is later.
- Automatic checkpoint-on-mutation — save timing is the app's call (§5.1).
- Concurrent multi-process access, file locking, replication.
- Schema migration of persisted records (serde's `^schema-version` reserves
  the space; a store-level migration hook can follow).
- Encryption at rest.

## 10. Staged plan

1. **`store` protocol + `store/sqlite`.** The `Store` protocol
   (`put`/`get`/`delete`/`keys`/`has?`/`clear`/`close`), `StoreError` with
   `^kind`, `^mode` and read `^policy` pass-through, over an existing
   `db/sqlite` connection. **No new runtime.** Spec/e2e: record round-trip in
   both modes, `get` missing→raises and `^default`, `has?`, `delete`/`clear`,
   reopen-after-close, restore-off-by-default.
2. **Migrate the gateway** onto `store/sqlite` in `data` mode (§8) — proves
   the interface, keeps existing DBs loading, adds the resume flag.
3. **Fs primitives.** `Fs/make-dir` + `Fs/remove` (+ optional `Fs/exists?`),
   `Fs/WriteDir`-gated, path-confined (§4.1). Spec tests incl. path-escape
   rejection.
4. **`store/fs`.** The directory backend: url-encoded keys, plain writes,
   tolerant `keys`. Spec/e2e: the *same* suite as sqlite (interface parity)
   plus fs-specifics (invalid/empty keys, junk-file tolerance, path escape).
   Gateway gains `GENE_GATEWAY_STATE` for fully file-backed operation.
5. **Crash hardening (§7), when needed.** Atomic writes, `Fs/rename` +
   `Fs/write-text-atomic`, directory `fsync`, stale-temp recovery, corruption
   detection, a kill/power-loss test harness. Independent of stages 1–4.

Each stage lands with the repo's gates (`nimble test`/`spec`/`perf`/`wasm`);
persistence is off the dispatch hot path, and no stage adds fields to the
NaN-boxed `Value`. The design reduces to: **serde is the format, the Store is
a KV log over it, the app chooses when to save and whether to reload, and
reload rebuilds the live layer from the durable layer — one model, mined from
the prior repo's two.**
