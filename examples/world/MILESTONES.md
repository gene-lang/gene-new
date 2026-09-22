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
