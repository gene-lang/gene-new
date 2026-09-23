# Milestones — what each one delivered, and the evidence

The plan is `docs/proposals/world.md` §17. Milestone 0 (the copy-and-adapt
starting point) is recorded in [`SOURCES.md`](SOURCES.md).

## Milestone 1: one browser player and the world (2026-09-22)

One Commons world process and one browser player, with no Miclone process,
Life process or model provider. Run it:

```sh
gene run world create                       # once
gene run world player add ada "Ada"         # prints a one-time login code
gene run world run                          # http://127.0.0.1:8096/
```

### What §17 asked for, and where it is

| Requirement | Implementation |
| --- | --- |
| Independent Commons application from its own source | `server/` (world process), `client/main.gene` (player), `mods/neighborhood` (content); the Miclone byte-protocol server, client and probes are gone |
| Commons-owned renderer and socket host | the copied WebGL2 renderer, mesher, lighting and raycast drive `client/main.gene`; `server/host.gene` serves the page, its content-addressed client (`$web/load`) and `/world/v1` from the world process itself |
| Server-owned click-to-move | the client names a cell; `server/navigation.gene` plans a route on the 1 m grid and the world advances the walk in 100 ms steps (§6.2, §6.5); one walk per avatar, a second is `busy` |
| A small scene | `server/scene.gene`: two homes, a hall, a workshop, a garden and pond, paths, trees — generated once and stored with its own name table (§5.3) |
| One unique object | the watering can: exactly one location — on the ground or held (§5.2); `object.pick_up` / `object.put_down` |
| Participant binding | `server/participants.gene`: operator-provisioned player → participant → avatar; the socket's participant comes from the session, never from a message (§4.4) |
| Minimum session/Origin checks | one-time login code (SHA-256 stored) → HttpOnly SameSite=Strict session cookie; Host, Origin and the `gene.world.v1` subprotocol checked before upgrade (§9.4) |
| Control-generation fencing | a durable generation per attach; a second tab gets `controlled_elsewhere` until it explicitly takes over; stale-generation commands are refused; an old socket closing cannot detach the new controller (§4.4) |
| Durable action receipts | `(participant, operation_id)` records with canonical semantic payloads: resend → retained receipt; changed payload → `operation_id_conflict`; cancel-first → tombstone (§10.2, §10.5) |
| Owner current-action queries | `actions.current`, `operation.status` (found / not_found / unknown), `receipts.page` with coverage (§10.7, §10.8) |
| Initial full snapshot + bounded live updates | `welcome` → `sync_begin` → (replay) → `snapshot` → `sync_end` → `ready`; durable per-participant `event` stream; replaceable `telemetry` skipped for a peer that is behind (§9.4, §11) |
| `WorldStore` transaction boundary; incremental on-disk store | `server/persistence.gene` on the new `$db/sqlite/open_file`: every frontier is one transaction; WAL, synchronous FULL, fullfsync; single-writer lock (§12.8) |
| Action-boundary commits and periodic checkpoints | `commit_frontier` flushes every pending change with each admitted operation, arrival, suspension or generation change, and every 1 s of simulation time while anything moved; an idle world writes nothing (§6.1) |
| Provisional motion shown separately | telemetry marks samples ahead of the checkpoint; the page draws a marker at the last saved position and says "provisional" (§6.1, §15.3) |
| Refresh / fence / recover without IndexedDB | the page keeps pending commands in memory only; a same-page reconnect resumes after its last event and resends unanswered commands under the same ids; a refresh recovers from the snapshot's actions and receipts (§10.7) |
| A confirmed pickup survives a crash; the motion tail is corrected honestly | `tools/commons_smoke.mjs` kills the world with SIGKILL mid-walk: the pickup is there after restart, the avatar is at its last checkpoint, and the walk is suspended until resumed; `tools/client_smoke.mjs` shows the page reconnecting and telling the player how far the unsaved tail moved |

### Platform changes this milestone needed (outside `examples/world`)

- `$db/sqlite/open_file` — incremental, disk-backed SQLite (owner-only files, `^create`, `^busy_timeout_ms`); `SqliteDb` gained an optional `storage` field.
- `$net/http` `ws_accept ^subprotocol` (RFC 6455 selection) and `ws_queued` (bytes a peer has not accepted).
- Web profile `$ws/connect_protocol url protocol`.
- `$json/parse ^strict true ^max_depth N` (duplicate keys rejected).
- `$os/wall_ms` (Unix epoch ms, for session expiry that survives restarts).

Tests: `tests/spec_runner.nim` ("sqlite open_file …", "json/parse ^strict …"),
`tests/test_http_server.nim` ("ws_accept ^subprotocol …"),
`tests/transpile_dom_runner.nim` (`ws/connect_protocol`),
`tools/check_host_bindings.mjs`; documented in `docs/stdlib.md`.

### Evidence (macOS 27, APFS, Node v25.9.0, SQLite 3.54.0, optimized `bin/gene`)

- `tools/check.sh`: VM and web specs with byte-identical VM/web reports,
  `commons_smoke` 37 checks, `client_smoke` 13 checks — all passing.
- Commit latency on the incremental store, from the world's own counters
  (`/health`) across a smoke run: 29 commits, maximum 4 ms, with WAL,
  `synchronous=FULL` and `fullfsync=ON`.

### Carried into Milestone 2

- **Replay** exists (events after a client cursor, paged, with `history_gap`
  when retention cannot satisfy it) but nothing prunes events yet; retention
  and archival are §12.8 / Milestone 3 work.
- **Life attachment**: native Life hello, credentials and the network adapter
  (§8, §9.7) — the protocol and receipts are shared, the adapter is not built.
- **Liveness** uses a 45 s heartbeat expiry plus the server's WebSocket ping;
  §11.5's reconnect jitter and per-participant byte budgets are simple.
- **Views** are not yet filtered by perception (§7.1): the first region is
  small and everything in it is visible to everyone in it.
- **Provisioning** needs the world stopped (single-writer store); an operator
  channel for adding players to a running world is later work.
- **Receipt latency** end to end (§7.5's 250 ms p95 target) is not yet
  measured under load; §12.8's calibration is Milestone 3.

## Milestone 2: attach one Life, then two, using the existing connector (2026-09-22)

The world plus independent fake-brain Lives, each its own process with its own
store, attached through `genex/websocket`, beside a browser player. Run it:

```sh
gene run world create
gene run world player add ada "Ada"
bin/gene run examples/life/src/main.gene create examples/life/tmp/aster --network   # → its id
gene run world life add <id> "Aster" --credential-out /tmp/aster.credential
bin/gene run examples/life/src/main.gene bind examples/life/tmp/aster ws://127.0.0.1:8096/world/v1 /tmp/aster.credential
gene run world run &
bin/gene run examples/life/src/main.gene run examples/life/tmp/aster
```

(`gene run world …` from `examples/world`, `bin/gene run examples/life/…` from
the repository root.)

### What §17 asked for, and where it is

| Requirement | Implementation |
| --- | --- |
| Keep the local world/demo intact | The profile is chosen at creation; `local` is the default and unchanged. The 110 pre-existing Life tests pass, and `examples/life/src/demo.gene` runs as before |
| Complete the incremental world store; confirmed effects and receipt lookup against the real file | Life requests, receipts and recipient events go through the same `open_file` WAL store; `operation.status` answers `found` / `not_found` / `unknown` from it; format 1 → 2 is an explicit migration (`world_life_credentials`); `gene run world inspect participants\|entity\|operation\|events` reads the stopped world's file, and `life_smoke` asserts against it |
| Add the network adapter; generalize connector delivery rather than rewrite it | `examples/life/src/body/delivery.gene` is the transport-independent kernel lifted out of the HTTP connector (restart → uncertain, attempt, uncertainty, authoritative absence, owner withdrawal, alternating send/receipt lanes, history gaps). `connector.gene` now uses it (its 25 tests unchanged) and so does the world profile; `delivery_spec` runs one table over both record shapes |
| One fake-brain Life in its own process/store through `genex/websocket` | `world_wire.gene` (native client, `gene.world.v1` offered and required), `world_network.gene` (the polled connection). `life create --network`, `life bind`; world `life add`. A native upgrade has no `Origin` and is nobody until its `hello` presents the Life id and operator-issued credential (SHA-256 stored); failures are one answer, bounded in number and time |
| Durable outbox | `world_op/<id>` commits in the brain program's own group; it is sent only after publication, one exchange at a time, in outbox order, below the world's rate limit. A socket failure leaves every unconfirmed attempt `needs_reconciliation` — never a new ID |
| `found` / `not_found` / `unknown` | Reconciliation queries `operation.status`: `found` settles, `not_found` returns the same ID and bytes to the send lane (or ends a withdrawn request), `unknown` stays uncertain and is asked again at most once a second |
| Recipient cursor, snapshot/replay | `world_cursor` per stream: `hello` resumes after the receipt cursor; events install in bounded batches, one commit each, then an `ack`; a duplicate is dropped by sequence and a skipped sequence blocks and resynchronizes; `snapshot` installs the committed view (the Life asks for a structured view, no render data, no telemetry) |
| One standing result dispatcher | `world_dispatcher`: bounded passes of 32 over the events after the dispatcher cursor plus receipt/query routing markers; no routine registration per operation |
| A second Life; human and Life requests contend through the same handler | `life_smoke`: Aster, Brin and Ada go for the one watering can; exactly one holds it, every other attempt gets `held_by_someone_else` from the same `object.pick_up` handler |
| The same narrow database binding behind Life's persistence | `persistence.gene` backends: `life.sqlite` (image, local default) and `life.db` (`open_file`, WAL, FULL); networked Lives use the file backend. The whole local suite with `LIFE_STORAGE=file`: all 104 behavioral tests pass; the 6 that byte-compare `life.sqlite` apply only to the image backend |
| Walk-then-act as a continuation data record, committed with the outbox request | `body/world .on_result ref revision inputs ^tx tx` stores `world_cont/<op>` (saved code + explicit inputs + ownership) in the same group as the walk; no `await_result`, no waiting worker |
| Both orderings; receipts, query results and events normalized into one outcome | `world_records/normalize` keeps one canonical result per operation; terminal states never revert and a different terminal report is a recorded conflict, not a second trigger. Registration readies a continuation whose result is already terminal in its own commit; routing does the same later; the ready execution's identity is derived from the continuation |
| Scoped cursors instead of `seen_events` | The world path keeps sequence cursors per stream (receipt and dispatcher cursors apart); routine event subscriptions are untouched |
| Route bounded batches, then execute separately | A ready continuation is an ordinary queued execution (`execution/cont-<op>`) for the existing foreground executor; ownership and organization are checked at admission, and a retired owner's continuation is visibly invalidated |
| More than 64 outstanding continuations, one registration, several 32-event batches | `world_network_spec`: 70 continuations waiting at once, one dispatcher and no routines, an over-limit group rejected whole; 69 outcome events routed in ≥ 3 passes plus 70 receipt markers; one continuation fails, 69 complete, each ran once |
| All network code outside short brain programs | The connection and the dispatcher run from the body's heartbeat; generated programs and continuations only reach the local record operations |

Local speech (§2.4's next slice) came with it: `conversation.say`, heard by the
speaker and everyone attached within 12 m when it commits; a Life hears it as a
`world` conversation and answers through its outbox; the page has a **Say** box
and shows messages once, as inert text. Walks accept `place_id` (named places)
or `object_id` as well as a cell, and movement events carry the committed
position.

### Platform changes this milestone needed (outside `examples/world`)

- `$fs/write_text_atomic ^owner_only true` — the credential file.
- `$json/parse ^strict true` rejects text that is not valid UTF-8, so a native
  client's binary frames and a browser's text frames meet one decoder (F23).
- `genex/websocket` `connect_protocol`: offers one subprotocol and fails
  unless the server selects it (the 101's headers are `CURLH_1XX`); its
  independent peer test covers selection, a server that ignores the offer and
  an invalid name.
- `examples/life` declares its `genex/websocket` dependency, so its tests run
  as `bin/gene test --package-root examples/life examples/life/tests/`.

Tests: `tests/spec_runner.nim` ("filesystem atomic text ^owner_only …",
"json/parse ^strict rejects text that is not valid UTF-8"),
`src/genex/websocket/tests/echo.mjs`, `examples/life/tests/world_network_spec.gene`
(13), `examples/life/tests/delivery_spec.gene` (2), `tools/life_smoke.mjs`.

### Evidence (macOS 27, APFS, Node v25.9.0, Homebrew curl 8.19.0, optimized `bin/gene`)

- `tools/check.sh`: 39 steps, all passing (3 min 21 s): the VM/web specs,
  `commons_smoke` 37, `client_smoke` 16, the Life network specs 15, and
  `life_smoke` 29 checks (~80 s, three processes plus a browser-shaped peer).
- Life suite: 125 passed (110 prior + 13 + 2), ~59 s.
- `life_smoke`'s restarted world: 24 commits, maximum 11 ms, on its incremental
  store. This is one small run, not the §12.8 calibration.

### Carried into Milestone 3

- **Lost world reply with real processes.** The in-memory peer drops a
  committed receipt deterministically; `life_smoke` kills a Life before send
  and the world mid-walk, but not between the world's commit and the Life's
  receipt. §17's Milestone 3 test list names it.
- **Retention.** Received events, canonical results and continuation records
  are kept; nothing archives them yet, and Life's store still copies its
  record map per transaction — the §12.8 growth benchmark will show the cost.
- **Pause** does not yet ask the world to suspend the Life's activity (§12.4).
- **Views** are still not filtered by perception (§7.1); a Life's view is
  updated from its own events and snapshots, and other avatars' movement only
  by `refresh`.
- **`movement.resume`**'s own receipt stays non-terminal: the walk's outcome
  belongs to the original operation.
- **Registration race.** A group that registers a continuation for an
  already-sent request fails whole with a revision conflict if that request's
  result lands while the group is open — correct serialization, but it is not
  retried for the program.
- **Organization changes** invalidate a ready continuation at admission;
  waiting records are not migrated (Milestone 6).
- **Receipt latency** end to end (§7.5) is still not measured under load.
