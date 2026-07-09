# Gene Persistence & Resume — Design

Status: **designed; not implemented.** Date: 2026-07-09.

Goal: persist a Gene application's durable state to the filesystem (later a
database) and **resume after the process is stopped or killed**, with no
corruption from a mid-write kill. This design is the layer *above*
serialization: `serde` (docs/proposals/serialization.md, stages 1–6 shipped)
already turns values into text and back; persistence adds durable storage, a
crash-safe write discipline, and a resume model.

## 1. The one lesson from the prior implementation

The older Gene repo built a **tree-serdes** filesystem model — `write_tree`/
`read_tree` exploding nested values into directory trees (`_genetype.gene`,
`_geneprops/`, `_genearray.gene` manifests, per-key files) with a lazy-load
overlay. It was fully implemented and tested for two months, then
**deliberately removed** (`replace-tree-serdes-with-file-refs`, 2026-05) for
one stated reason: *it created a second public serialization model.* The
replacement kept the good ideas (opaque child ids, lazy caching, path-escape
and cycle rejection, atomic temp-file-then-rename writes) but collapsed back
to **one** wire format — plain serialized text plus a couple of file-ref
forms — instead of a bespoke reserved-directory convention.

The directive for this design follows directly: **do not invent a second
serialization format.** `serde` is the format. Persistence is file I/O plus a
key→value store plus a resume protocol, all riding `serde/write`/`serde/read`
unchanged. Every idea below that looks like "custom encoding" is instead a
thin store convention over serde text.

## 2. What "application state" actually is here

There is no "freeze the whole VM" operation, and pursuing one is the trap.
This runtime is shared-nothing and actor-based; its live state — scheduler
fibers, channels, tasks, actor refs, open sockets, DB connections, native
handles — is exactly `serde`'s **bucket 3 (not serializable)**. That is not a
limitation to work around; it is the correct boundary. The **serde bucket
classification already answers "what persists":**

| Live thing (does NOT persist) | Its durable projection (DOES persist) | Resume action |
|---|---|---|
| Actor ref + mailbox + handler fiber | Actor **state** (`actor/snapshot` → data) | re-`actor/spawn` from saved state |
| DB connection / socket / HTTP server | Its **config** (path, host, port) | reopen/reconnect from config |
| Channels, tasks, in-flight turns | — (transient by design) | start fresh; re-drive from data |
| Cell (identity) | Its **contents** (`serde/write` snapshot) | new cell around restored value |
| Capability value | **never persists** (authority) | re-granted by the launcher (§8 of ai-agent) |

So "resume" is precisely: **reload the durable projection (data + typed
instances + refs), then re-establish live wiring from it.** An application's
persistable state is the set of values it can hand to `serde/write` — which
`serde/data?` and the write path already enforce, raising `SerdeError` with a
path on anything process-bound. Persistence inherits serde's security posture
wholesale: no capability round-trips, `serde/read` never loads a module named
by a payload, restore hooks are `^allow-restore`-gated.

**`serde-state`/`serde-restore` (stage 5) are the per-type resume primitive.**
A type that owns a transient resource implements them to save only its
durable fields and re-derive the resource on restore — the canonical
"drop the socket, keep the host, reconnect on read-back." Persistence is the
motivating use case for those hooks, now made concrete.

## 3. The `Store` — a durable key→value log over serde

One capability-gated abstraction, shaped like the existing `Db` protocol
(`db/sqlite`/`db/postgres` behind one `Db`), so the filesystem story today and
the database story later are the **same interface with interchangeable
backends**:

```gene
(import store [open put get delete keys has? close StoreError Store])

(var s (open fs ^root ".state"))          ; fs : Fs/ReadWriteDir capability
(s ~ put "session:tg-42" {^items [...] ^events [...]})   ; value -> serde text
(var v (s ~ get "session:tg-42"))         ; serde text -> value, or void
(s ~ keys)                                ; -> [Str]  (all record keys)
(s ~ has? "session:tg-42")                ; -> Bool
(s ~ delete "session:tg-42")
(s ~ close)
```

- **Records are independent.** A store is a flat map of `Str` key → one
  serialized value. There is no global snapshot to rewrite wholesale — the
  old repo's fatal `_genearray.gene`-rewrite-per-turn cost. Each `put` writes
  one record; recovery loads all. This is exactly what the gateway already
  does by hand with sqlite (`sessions(id, data)`), generalized.
- **Values cross the boundary as serde text.** `put` runs `serde/write` (full
  mode — trusted local persistence, refs allowed); `get` runs `serde/read`.
  Both accept `^policy` (a `SerdePolicy`) so a caller can restrict to the data
  bucket (`^data-only true` ⇒ `serde/write-data`/`read-data`), cap resources,
  or enable `^allow-restore`. Default policy for a local app store enables
  restore (its own data is trusted); a store fed untrusted input tightens it.
- **`StoreError`** (typed, `^message`/`^key`) follows the
  `SerdeError`/`DbError` pattern.
- **Backends** implement the `Store` protocol:
  - `store/fs` — a directory (§4). Ships first; needs the small Fs surface in
    §4.1.
  - `store/sqlite` — a table `(key text primary key, data text)` over the
    existing `db/sqlite` backend. **Works today** with no new runtime — the
    gateway is the proof; §6 migrates it onto this interface.
  - `store/postgres` later, free, since `db/postgres` already exists.

Because both backends store the *same* serde text under the *same* key API, a
store dumped by `store/fs` reloads through `store/sqlite` and vice versa —
"filesystem now, db later" is a backend swap, not a rewrite. That
interchangeability is the entire payoff of refusing a second format.

## 4. Filesystem backend

A store is a directory; each record is one file holding one `serde-v1`
envelope. Learning from the prior repo, **flat, not a directory tree**:

```
.state/
  session%3Atg-42.gene      # url-encoded key -> one serde envelope
  session%3As1.gene
  config.gene
```

- **Key → filename** via `url/encode_component` (already in stdlib), so keys
  can contain `/`, `:`, spaces, unicode without escaping the directory or
  colliding — and reversibly, so `keys` is `Fs/list-dir` + url-decode. This is
  the prior repo's filesystem-safe-key trick, minus the tree.
- **No reserved names, no marker files.** A record is just a file; the store
  directory holds only `<key>.gene` files. (The prior model's one permanent
  v1 gap — a real map key named `_genetype` colliding with a decoder marker —
  cannot occur here because there are no markers.)
- **Reads** are `Fs/read-text` + `serde/read`. `keys` lists the directory.
  Optional lazy reads (open a record only when `get` is called, memoized) are
  a read-side refinement, not a format change — the prior repo proved that
  overlay works; it can follow.

### 4.1 Crash safety — the load-bearing requirement

A kill mid-`put` must never corrupt a record or the store. Each `put` is an
**atomic replace**: write `<key>.gene.tmp`, fsync, `rename` over
`<key>.gene`. POSIX rename is atomic, so a record is always either its
previous committed version or the new one — never torn. This is the same
temp-then-rename discipline the prior repo used and the property its crash
reviews demanded.

**Runtime gap (gap 1, load-bearing for the fs backend).** Today `Fs/*` is only
`read-text` / `write-text` / `list-dir` (+ async), and `write-text` calls
Nim's `writeFile` directly — **not atomic**, no rename, no delete, no mkdir.
The fs store needs a small set of new `Fs/WriteDir`-gated natives beside the
existing ones in `src/gene/stdlib.nim`:

| New native | For |
|---|---|
| `Fs/write-text-atomic` (temp + fsync + rename) | crash-safe `put` |
| `Fs/rename` | the atomic-commit primitive (also usable directly) |
| `Fs/remove` | `delete` a record |
| `Fs/make-dir` (mkdir -p) | create the store directory |
| `Fs/exists?` | store/record probing |

These are ordinary capability-gated file ops — the same shape as
`Fs/write-text`, no new authority beyond `Fs/WriteDir`/`Fs/ReadDir`. The
sqlite backend needs **none** of this (transactions give atomicity), which is
why it can ship first while the fs natives land.

## 5. Resume model

Resume is a *pattern* with minimal runtime support, not a magic operation.
Three obligations on a resumable application:

1. **Checkpoint on change.** After each state-changing step, `put` the
   affected record. Granularity is per logical unit (per session, per actor),
   never a whole-state dump — bounded write cost, and a kill loses at most the
   one in-flight operation. The gateway already does this
   (`persist-session` on `turn_done`).
2. **Reconstruct on startup.** On boot, `open` the store, `keys`, `get` each
   record → the durable data comes back (typed instances via direct
   construction, refs resolved, `serde-restore` re-deriving transient fields
   under policy).
3. **Re-establish live wiring.** For each restored record, re-`actor/spawn`
   from its saved state, reopen connections from saved config, rebuild
   channels/routes. This is application code — an `on-resume` hook per record
   kind — because only the app knows how its live graph maps to its data. The
   gateway's restore path (re-spawn the session actor, reattach the Telegram
   sender hook, resume the id sequence) is the worked example.

**Crash semantics, stated plainly.** With commit-on-completion + atomic
records, a kill leaves the store at its **last completed checkpoint**. An
operation in flight when killed (a half-processed turn) is lost — its record
was never committed — and resume restarts from the prior committed state. This
is the right default (simple, no partial-state replay). An application needing
at-most-one-lost instead of at-least-committed can **write-ahead** the request
before processing (a second record kind), a documented refinement, not MVP.

There is deliberately **no** "serialize the running VM." Live fibers/channels/
tasks are not serializable (§2), and a design that pretended otherwise would
be lying. Resume rebuilds the live layer from the durable layer — which is
faster, portable across code changes, and the only honest option in an
actor runtime.

## 6. Migrating the gateway (the first consumer)

`examples/agent_gateway.gene` milestone 11 already persists sessions to
sqlite via hand-rolled `write-data`/`read-data` + `insert or replace`. It
becomes the reference `Store` consumer:

- `GENE_GATEWAY_DB=path` → `(open sqlite ^path ...)`; a new
  `GENE_GATEWAY_STATE=dir` → `(open fs ^root dir)`. Same session code, chosen
  backend.
- `persist-session` → `(store ~ put (str "session:" id) snapshot)`.
- Startup restore → `(store ~ keys)` filtered to `session:*`, `get` each.

No serialized-format change (both already store the same serde-shaped data),
so existing sqlite databases keep loading. This proves the interface against a
real app and retires bespoke persistence code.

## 7. Non-goals (first version)

- Serializing live scheduler state (fibers, channels, in-flight tasks) —
  structurally impossible and unnecessary (§2/§5).
- A global consistent snapshot across records / cross-record transactions —
  records are independent; multi-record atomicity is a later `store ~
  transaction` (trivial on sqlite, harder on fs; deferred).
- Concurrent multi-process access to one store, file locking, replication.
- Schema migration of persisted records (serde's `^schema-version` reserves
  the space; a `store`-level migration hook can follow).
- Compaction / GC of deleted fs records beyond `Fs/remove`.
- Encryption at rest.

## 8. Staged plan

1. **`store` protocol + `store/sqlite`.** The `Store` protocol
   (`put`/`get`/`delete`/`keys`/`has?`/`close`), `StoreError`, `SerdePolicy`
   pass-through, and the sqlite backend over the existing `db/sqlite`. Needs
   **no** new runtime. Spec/e2e tests: round-trip records, policy modes,
   delete/keys, reopen-after-close.
2. **Migrate the gateway** onto `store/sqlite` (§6) — proves the interface,
   keeps existing DBs loading.
3. **Fs primitives (gap 1).** `Fs/write-text-atomic`/`rename`/`remove`/
   `make-dir`/`exists?` in `src/gene/stdlib.nim`, `Fs/WriteDir`-gated. Spec
   tests incl. the crash property (interrupted write leaves the old record
   intact — simulated by writing to `.tmp` and asserting the target is
   untouched until rename).
4. **`store/fs`.** The directory backend on those primitives; url-encoded
   keys, atomic `put`. Spec/e2e: same suite as sqlite (interface parity) plus
   fs-specific path-escape rejection and atomic-replace-under-kill.
5. **Resume hardening.** Document + example the `on-resume` pattern; optional
   write-ahead record kind; optional lazy fs reads. The gateway gains a
   `GENE_GATEWAY_STATE` fs option so a user can run fully file-backed with no
   database.

Each stage lands with the repo's gates (`nimble test`/`spec`/`perf`/`wasm`);
persistence is off the dispatch hot path, and no stage adds fields to the
NaN-boxed `Value`. The whole design reduces to: **serde is the format, the
Store is a crash-safe KV log over it, and resume rebuilds the live layer from
the durable layer — one model, mined from the prior repo's two.**
