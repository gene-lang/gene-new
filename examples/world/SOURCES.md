# SOURCES — provenance for the Commons' copied source

This is the provenance record required by `docs/proposals/world.md` §1.4 and
Milestone 0 (§17). It is provenance only, not a dependency manifest. It covers:

- original paths and the source commit, with local destinations;
- what was selected and why, and each part's disposition;
- notices and adaptations;
- the storage-publication finding, with measured limits;
- baseline results.

The design being implemented is `docs/proposals/world.md` ("Gene World: An
Expandable Human–AI Commons", Revision 5). The copy policy is §1.4's
copy-and-adapt table:

- Selectively copy Miclone sources as ordinary Commons-owned code.
- Rename and simplify freely.
- Keep lightweight provenance.
- Port fixes manually.
- Extract no shared engine.

This tree lives at `examples/world/`, which fills §16.1's `world/`
responsibilities, beside its copy source and `examples/life`.

> **Milestone 1 update.** The copied voxel server (`server/main.gene`,
> `storage.gene`, `blockfmt.gene`), its byte-protocol browser client
> (`client/net_main.gene`, `index.html`) and the probes and smokes that targeted
> it were replaced by the Commons world process and player — see
> [`MILESTONES.md`](MILESTONES.md). The "Disposition" table below is the
> Milestone 0 view; its client/server/storage rows are now done.

## Source and commits

- **Copy source:** `examples/miclone` (the Miclone voxel engine), left unchanged.
- **Recorded source commit** (proposal §20, [R1]): `228d3304b872927aa1d82b5a46934e8ec8c479fe`.
- **Materialization commit**, where the copy was taken from:
  `50e931478632bea7e72396dc0bccbcb0aff7c6b4` (the `gene-world` branch base).
- `examples/miclone` is **byte-identical** between those two commits
  (`git diff 228d3304… 50e9314… -- examples/miclone` is empty), so the copy is
  exactly from the proposal's recorded source commit.
- **The copy with its renames** landed in `479fc7c`. It is reproducible as one
  tree-to-tree diff: 33 files, +266/−271, all renames plus the stale imports
  below.

  ```sh
  git diff 228d3304:examples/miclone 479fc7c:examples/world \
    -- ':!README.md' ':!SOURCES.md' ':!docs' ':!native' ':!tools/run_native.py'
  ```

  Later adaptations (the removals, the persist order, the comments) are
  ordinary history in this tree.

## What was selected, and why

§1.4 asks for "the necessary dependency closure, not the entire project by
default". Most of Miclone *is* that closure. The world process
(`server/main.gene`) and the browser client (`client/net_main.gene`) together
import **all 35** `core/` modules:

- the server imports 30 of them;
- the client imports 22;
- 13 are server-only: generation, content, ABMs, containers, crafting;
- 5 are client-only: shaders, texture, `seen`, `client_world`, `vec`.

So `core/` is copied whole. The rest of the selection follows from those two
entry points and the tests that cover them.

Two parts of Miclone are outside that closure or contradict the design. Both
were copied at first and **removed after the copy**:

| Removed | Why |
| --- | --- |
| `client/main.gene`, Miclone's `index.html`, `tools/client_smoke.mjs` | The in-tab singleplayer client and its smoke. It generates its own world and simulates its own physics with no server. That is the authority model §1.4 says to replace ("client-simulated player motion"), and it sits outside the Commons topology (§4.1: one world process, browser players). |
| `server/mods_runtime.gene`, `probes/run_loader.gene`, `probes/badmod/` | Runtime mod loading into a `$runtime/load_sandboxed` sandbox governed by manifest `^grants`, plus its escape fixture. §1.2 says the design requires no grants, §1.4 row 4 says not to import the mod framework as a prerequisite, and §13.1 asks for "a selected module manifest and normal Gene loading". The server now loads content through `core/mods.gene`'s compiled-in `load_mods`, the same list every probe uses. `loader` had verified that both paths build the identical game, node for node, so the switch changes no content. |

## Copy map and disposition

Original paths are relative to `examples/miclone/`, local paths to
`examples/world/`. The **disposition** column says what happens to each part:

- **keep:** ordinary Commons source, adapted as needed.
- **adapt (M1):** Milestone 1 reshapes it.
- **replace (M1–M2):** superseded by new Commons work behind the same interface.

| Original | Local | Copied for (§1.4 row) | Disposition |
| --- | --- | --- | --- |
| `core/*.gene` (35 modules) | `core/` | portable geometry, inventory, entity, content helpers; renderer/mesher helpers; codec helpers | keep; reshape toward §5.1 entities/components. The voxel representation is not preserved for its own sake. |
| `client/net_main.gene` | `client/net_main.gene` | browser shell, camera, picking, input | adapt (M1): server-owned click-to-move replaces client-simulated walking; §9 envelope and participant binding |
| `client/render.gene`, `client/atlas.gene`, `client/sound.gene` | `client/` | WebGL2 renderer and the appearance/audio helpers | keep; presentation evolves with the neighborhood (M5) |
| `server/main.gene` | `server/main.gene` | `$net/http` WebSocket integration, `serve` tick loop | adapt (M1): sessions/Origin, control fencing, receipts, persistent participants, server-owned motion, pages served by the world process |
| `server/storage.gene`, `server/blockfmt.gene` | `server/` | SQLite world integration and batched publication | replace (M1–M2): incremental on-disk store behind the `WorldStore` interface (see the storage finding) |
| `mods/default/` | `mods/default/` | server-selected content and recipe-driven presentation | keep as content; `^grants` dropped; Commons content arrives in M5 |
| `probes/` (specs, runners, web shells, fixtures) | `probes/` | relevant tests and fixtures | keep; §16.1's `tests/` reshape is M1+ |
| `tools/build_web.sh`, `tools/{web_spec,dom_stub,net_client_smoke,world_build,mesh_bench}.mjs` | `tools/` | web build and test/bench harnesses | keep; `tools/check.sh` added |
| `net.html` | `index.html` | the player page | keep; the world process serves it in M1 |
| `package.gene` | `package.gene` | package manifest (renamed) | keep |

**Not copied:**

- `luanti/`: the upstream Luanti reference clone. It was read-only source
  material for Miclone's design and never a build input.
- `native/`, `tools/run_native.py`: the SDL native shell and native WebSocket
  client. The Commons' Life side connects through `src/genex/websocket` +
  libcurl ≥ 8.11 directly (§1.4 row 6), not through Miclone's native client
  or launcher.
- `docs/`: Miclone's own design doc. Comments in the copies cite
  `design.md §N` / `§D…`, and M0–M8. These are retained provenance and refer
  to **Miclone's design doc at the source commit**. README.md says so, since
  this repository's `docs/design.md` is the Gene language design. The
  Commons' design is `docs/proposals/world.md`.
- `README.md`, `package.gene.lock`: rewritten or regenerated for this package.
- `dist/`, `.gene/`: generated output, ignored here as in the source.
- `client/badmod/`: an empty directory in the source tree.

**Notices: none to retain.** Miclone's design.md §D9 ("Copying upstream
code") is to read Luanti and write its own code; its textures are generated
rather than copied. No license headers or `docs/licenses/` entries
existed at the source commit. Nothing third-party came along with the copy.

## Adaptations

`examples/miclone` itself is unchanged.

1. **Package/entrypoint names** (M0's mandate): `^name "gene/miclone"` →
   `"gene/world"`; the description now names the Commons.
2. **Content namespace** `miclone:` → `commons:`. This covers every
   registration, lookup, wire fixture and test literal (`commons:stone`,
   `commons:crafting`, the `make_commons:…` craft ids, …). The mod package
   `miclone/default` becomes `commons/default`. The two prefixes have the same
   length, so no byte-size fixture changed.
3. **Environment and config names:**
   - Environment: `GENE_MICLONE_WORLD` → `GENE_WORLD_ROOT`; harness variables
     `MICLONE_SMOKE_*` → `WORLD_SMOKE_*`.
   - Temp paths now carry a `gene_world_` prefix:
     - `/tmp/miclone_server_world` → `/tmp/gene_world_server`
     - `/tmp/miclone_world` → `/tmp/gene_world_probe`
     - `/tmp/miclone_smoke_world` → `/tmp/gene_world_smoke`
   - The stored world name `"miclone"` → `"commons"`; the log prefix
     `miclone server:` → `world server:`; the page title → `Gene World`.
4. **Stale type imports dropped.** Three imports named platform types that no
   longer exist: `$fs [WriteDir]` in the loader probe, and `$os [Env]` in
   `server/main.gene` and the mod runtime. Each was imported but unused.
   `examples/miclone` fails to load its loader probe at the source commit with
   the identical `module/namespace has no export` error. This is pre-existing
   platform drift, not copy damage.
5. **Content is compiled in**, and the runtime mod sandbox is gone (see "What
   was selected"). The server calls `core/mods.gene`'s `load_mods`; the
   recovery fixture does too. `mods/default/package.gene` keeps its identity
   but no `^grants`.
6. **The in-tab client is gone.** The networked page became `index.html`, and
   `client/net_main.gene` is the only client.
7. **A dig or place is persisted before anything is queued to a client.**
   Miclone queued the node delta and inventory, then wrote the block. `ws_send`
   only queues and the loop flushes after the handler returns, so on success
   the order was invisible. But `$net/http` logs a handler error and carries
   on, so a failed write still sent a delta confirming an edit that never
   reached the disk. §6.1 requires commit before confirming. What is written
   is unchanged: nothing between the edit and the old write position touched
   the block.
8. **Comments that described removed or wrong behavior were corrected:**
   - `server/storage.gene`: batching versus whole-image publication.
   - `core/mods.gene`, `mods/default/package.gene`: the loading model.
   - `client/net_main.gene`, `tools/dom_stub.mjs`, `tools/net_client_smoke.mjs`,
     `tools/world_build.mjs`, `probes/web_chest_probe.gene`: the removed
     client and loader.
   - `server/main.gene` gained a Commons preface.

   Other comments that narrate Miclone's history were left as provenance.

No import, asset fetch, script, fixture, or launched process in this tree
references `examples/miclone`.

## Storage-publication finding (M0 deliverable)

### The platform layer: `$db/sqlite` is whole-image

Established from `src/gene/stdlib.nim` (`biSqliteOpen`, `sqlitePersist`,
`fsWriteAtomic`), on the copied path `server/storage.gene` → `$db/sqlite`
`open`/`Db`:

- **`sqlite/open` loads the file into memory.** It normalizes the path, reads
  any existing file bytes, opens `":memory:"`, and loads the file with
  `sqlite3_deserialize` (`FREE_ON_CLOSE|RESIZABLE`). The database always lives
  in memory.
- **Every commit rewrites the whole file.** After each mutating statement that
  lands in autocommit, `sqlitePersist` serializes the **entire** database
  (`sqlite3_serialize`), copies it into a Nim string, and replaces the file
  atomically (`fsWriteAtomic`: temp file, `fsync`, `rename`, owner-only).
  An explicit `begin`…`commit` batches this into one publication.
  `Db/close` deliberately does not publish, because commits already did.
- **Pragmas cannot change this.** WAL/synchronous settings act on SQLite's
  pager, which is not what persists this database; the filesystem rename is.
  Accepting a pragma is not a backend change.
- **Durability covers a process crash, not power loss.** The rename is atomic
  and the temp file is `fsync`ed. But macOS `fsync` does not reach stable
  storage (that needs `F_FULLFSYNC`), and the parent directory is not synced
  after the rename.

### The application layer: what the copied server publishes, and when

| State | Where it lives | When it reaches disk |
| --- | --- | --- |
| Terrain at first start | `map.sqlite` `blocks`, one row per 16³ block | one batch after generation, before the port listens (`main.gene:763`) |
| Blocks missing on reopen (an interrupted first start) | same | the same batch, holes only |
| A dug or placed node | memory `World` + its block's row | per edit, in autocommit: one whole-image write, **before** any frame is queued (`main.gene:1014`, `:1094`) |
| ABM node changes (falling sand, spreading grass, …) | memory `World` | **never directly**; sent at once (`main.gene:581–587`) |
| Player inventory | the connection's closure (`main.gene:819`) | never; lost on disconnect |
| Container (chest) contents | memory `ContainerStore` | never |
| Dropped items and player entities | memory `EntityRegistry` | never |
| Player position | reported by the client in `msg_input`, mirrored into its entity (`main.gene:1104–1125`) | never |
| Simulation step | memory `step` cell (`main.gene:802`) | never |
| World metadata (seed, name, format) | `world.gene`, via `$fs/write_text` | once at creation, before generation; a separate file, not part of any `map.sqlite` transaction |

ABM changes reach disk only by accident. `persist_block` re-extracts the whole
16³ block from memory, so an ABM change is saved only if a later dig or place
happens in the same block. What survives a crash therefore depends on
unrelated later edits, not on a consistent frontier. §6.1's action-boundary
commits plus periodic checkpoints, and its "flush all pending logical world
changes into the same frontier", are Milestone 1 work. So is making inventory
durable: a pickup cannot survive a server crash today because inventory is
never stored.

### Measured cost: the whole-image fixture's limit

§12.8 allows "a tiny whole-image fixture … for milestone-1 browser work … with
a recorded small-data/load limit". This is that record.

The measurement: autocommit `insert or replace` of one block row, the
statement `persist_block` issues, repeated and averaged. Setup: `bin/gene`
below, macOS 27, APFS, SQLite 3.54.0. The larger databases add a 1 MiB-blob
filler table to the smoke world.

| Database size | Per-edit commit |
| --- | --- |
| 0.6 MB (the smoke world: 576 blocks) | 0.3 ms |
| 11 MB | 2.5 ms |
| 106 MB | 39 ms |

Each commit briefly holds about 3× the database size in memory: the resident
image, `sqlite3_serialize`'s buffer, and the string copy. Cost is linear in
database size. So the copied path is fine for Milestone 1's small scene. The
append-only operation, receipt and event collections of §12.1 will push it
past ~10 MB, so the incremental store must land before those collections
grow. §12.8 selects the incremental path by Milestone 2.

### The narrow on-disk integration to implement (Milestones 1–3, §12.8)

Open the **real file** as a transactional SQLite database, and drop the
per-commit serialize + `fsWriteAtomic` publication. Keep it at most as an
explicit export/snapshot tool. SQLite's own pager then provides incremental,
transactional, crash-safe writes at the action boundary. Existing `map.sqlite`
files are ordinary SQLite images, so they open as-is. The
`Db`/`WorldStore` call surface is kept (`exec`/`query`/`execute`,
`begin_batch`/`commit_batch`), so the change is confined to opening and
publication. Decisions it must make and record (§12.8, "Incremental
connection and publication contract"):

- **Where:** a stdlib `$db/sqlite` **opt-in** (e.g. `open_file`, or a mode on
  `open`), not a Commons-side binding. Life already uses `$db/sqlite`
  (`examples/life/src/host/persistence.gene`). §16.1 and §12.8 have both
  applications share the low-level binding. §12.8 also keeps existing
  callers on the whole-image path until they opt in explicitly ("backend
  selection/migration, not silent replacement").
- **Opening:** use `sqlite3_open_v2` with explicit
  `READWRITE|CREATE` (or no `CREATE` for an existing world) rather than
  `sqlite3_open`, so a mistyped root fails instead of creating an empty
  world. Bind `sqlite3_busy_timeout`, which `SqliteApi` lacks today. Readers
  such as `run_saved_blocks.gene` and operator tools will contend for locks.
- **Permissions:** today's file is owner-only (0600). SQLite creates the
  database and its `-wal`/`-shm`/`-journal` sidecars with its default mode,
  0644 on a typical build. §12.1 puts player sessions in this store, so keep
  0600: pre-create the file or set the umask.
- **Durability settings:**
  - `journal_mode` (WAL expected) and `synchronous`
  - `PRAGMA fullfsync` on macOS
  - the WAL checkpoint policy
  - `Db/close` with an open transaction (roll back)
  - sidecar files included in backups (§16.2)
  - whether power-loss durability is a goal or an explicit non-goal
- **Measurement:** commit latency and event-loop stalls on the actual serve
  loop (§12.8), against the table above.

## Disposition: what Milestone 1 inherits

Behavior the copy carries that the design replaces. None of it is a Commons
contract:

| Carried from Miclone | Where | Design |
| --- | --- | --- |
| The client simulates walking and reports its position; the server trusts it | `client/net_main.gene`; `server/main.gene:1104–1125` | §1.4 row 7, §6.5: server-owned motion |
| Inventory is per connection and lost on disconnect | `server/main.gene:819` | §4.4, §12.1: persistent participants |
| Any request is upgraded to a WebSocket: no session, Origin or control fencing | `server/main.gene:844` | §9.4 |
| Pages come from a separate static server; the client dials `ws://127.0.0.1:8790/` cross-origin | `client/net_main.gene:361` | §1, §16.3: the world process serves pages and assets |
| Byte protocol with no envelope, receipts or replay | `core/protocol.gene`, `core/wire.gene` | §9, §10, §11 |
| `ws_send` drops the oldest frames beyond a 256-frame per-connection queue; only block transfer reads the drop count, and node deltas have no sequence or replay | `$net/http`; `server/main.gene` `send_*` | §11.4–11.5: explicit gaps and resync |
| Whole-image storage, per-edit publication, most state unpersisted | see the storage finding | §6.1, §12.8 |
| Port 8790, the same as Miclone, so the two cannot run side by side | `server/main.gene:132`, `net_main.gene:361`, `tools/*` | §16.3 uses 8096 for the player URL; move when the world serves its pages |

## Baseline results (2026-09-22)

Revisions:

- **Gene:** `src/` at `27b51dd`, unchanged through `50e9314` and this
  branch. `bin/gene` was built with
  `nim c -d:release --mm:orc --opt:speed --passC:"-march=native -O3"`
  (the `nimble speedy` flags) and
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, because
  the default SDK link fails on this machine. An unoptimized binary made
  generation about 10.5× slower and tripped the smoke's 300 s listen budget.
- **Tools:** Node.js v25.9.0; SQLite 3.54.0 (as loaded by `$db/sqlite`);
  macOS 27.0.

`tools/check.sh` on this tree: **43 passed, 0 failed** (`--fast`: 34 passed, 0 failed, in 47 s). That covers:

- VM:
  - the 10 cross-backend specs (`world`, `wire`, `protocol`, `inventory`,
    `edit`, `loaded`, `physics`, `light`, `mapgen`, `abm`)
  - `persistence create` → `verify` in a fresh process
  - `divergence`
- Web:
  - `build_web.sh --clean`: 67 modules
  - all 10 `web_*_spec`, each byte-identical to its VM report
  - `web_divergence`, byte-identical to the VM checksums
- Budgets:
  - `worldgen`: PASS. Reading B is its documented expected-fail: the 80³
    node-rate implication, closed by Miclone §D7.11's AOT path.
  - `wire_bench` runs.
- Client smoke: `net_client_smoke.mjs` on a fresh world, then with
  `WORLD_SMOKE_RECOVERY=1`.
- Network probes, each on its own copy of a pristine world: `web_net_probe`,
  `web_tick_probe`, `web_entity_probe`, `web_chest_probe`, `web_players_probe`.

Timing on an idle machine:

- a fresh world generates and the server listens in about 68 s;
- a copied world loads in 17–25 s;
- 576 blocks reach the client and are meshed in about 13 s.

Under unrelated load (load average 14–22), one generation took about 10
minutes. `check.sh`'s server budget is therefore wall-clock (`START_BUDGET`,
default 600 s).

## Independence verification (§18.1 F24)

First run, on `479fc7c`: `examples/miclone` was **moved out of the repository
entirely** (no source, no `dist/`, no caches). From `examples/world/`, on the
same platform:

1. `tools/build_web.sh --clean` built 68 modules.
2. `gene run wire_spec` and `gene run loader` both PASSed.
3. `node tools/client_smoke.mjs` PASSed.
4. `node tools/net_client_smoke.mjs` PASSed (576 blocks meshed in 11.7 s).

Re-run after the removals, with `examples/miclone` again moved out of the
repository:

- `tools/check.sh --fast`: 34 passed, 0 failed. That is 67 modules built,
  every VM and web spec passing, and every VM/web pair identical.
- `node tools/net_client_smoke.mjs` on a fresh world: PASS (576 blocks meshed
  in 12.8 s).

In both runs `examples/miclone` was restored unchanged afterwards. A clean
Commons checkout plus the declared platform dependencies (optimized
`bin/gene`, Node.js) builds the browser and server, runs its own tests, and
supports browser/world interaction without Miclone present. That is the §1.4
acceptance criterion.

## Cross-check against the original

§17 M0 says an original Miclone build can help diagnose a copy, so failures
seen during the copy were checked against `examples/miclone` at the source
commit. The `WriteDir`/`Env` load errors and the slow-binary `worldgen`
budget failure reproduce there identically. With the optimized binary and the
import fix, the copy's suite is green and its `worldgen` readings match the
original's.

## Deferred to before Milestone 2

§17 M0 says these are not prerequisites for the browser-only milestone, but
they must run before Milestone 2:

- pin the actual Life checkout and run its local demo/mailbox regressions;
- run the independent native WebSocket peer test (`src/genex/websocket`,
  libcurl ≥ 8.11).
