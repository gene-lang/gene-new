# SOURCES — provenance for the Commons' copied source

This is the provenance record required by `docs/proposals/world.md` §1.4 and
Milestone 0 (§17): original paths, source commit, local destinations, notices,
adaptations, the storage-publication finding, and baseline results. It is
provenance only — not a dependency manifest.

The design being implemented is `docs/proposals/world.md` ("Gene World: An
Expandable Human–AI Commons", Revision 5). The copy policy is §1.4's
copy-and-adapt table: selectively copy Miclone sources as ordinary Commons-owned
code, rename and simplify freely, keep lightweight provenance, port fixes
manually, extract no shared engine. This tree lives at `examples/world/`
(§16.1's `world/` responsibilities), sibling to its copy source and to
`examples/life`.

## Source and commits

- **Copy source:** `examples/miclone` (the Miclone voxel engine), left unchanged.
- **Recorded source commit** (proposal §20, [R1]): `228d3304b872927aa1d82b5a46934e8ec8c479fe`.
- **Materialization commit** (where this copy was taken from):
  `50e931478632bea7e72396dc0bccbcb0aff7c6b4` (branch `gene-world` base).
- `examples/miclone` is **byte-identical** between those two commits
  (`git diff 228d3304… 50e9314… -- examples/miclone` is empty), so the copy is
  exactly from the proposal's recorded source commit.

## Copy map

Original paths are relative to `examples/miclone/`; local paths to
`examples/world/`. The tree keeps each file's current responsibility (§1.4
independence rules); the §16.1 reshape into `protocol.gene`/`server.gene`/
`modules/`/`content/` is Milestone 1+ work.

| Original | Local | Copied for (proposal §1.4 row) |
| --- | --- | --- |
| `core/*.gene` (33 modules) | `core/` | portable geometry, inventory, entity, content helpers; renderer/mesher helpers; codec helpers where they fit |
| `client/main.gene` | `client/main.gene` | browser shell, WebGL2 renderer, camera, picking, input |
| `client/net_main.gene` | `client/net_main.gene` | the networked browser shell |
| `client/render.gene` | `client/render.gene` | WebGL2 renderer |
| `client/atlas.gene`, `client/sound.gene` | `client/` | appearance/audio helpers the shells need |
| `server/main.gene` | `server/main.gene` | `$net/http` WebSocket integration, `serve` tick loop |
| `server/storage.gene`, `server/blockfmt.gene` | `server/` | SQLite world integration and batched publication (interfaces and fixtures) |
| `server/mods_runtime.gene` | `server/mods_runtime.gene` | content loading (`$runtime/load_sandboxed` manifest-grants sandbox — kept platform-side per the capabilities removal) |
| `mods/default/` | `mods/default/` | server-selected content and recipe-driven presentation |
| `probes/` (specs, runners, web shells, fixtures) | `probes/` | relevant tests and fixtures |
| `tools/build_web.sh` | `tools/build_web.sh` | web-profile build steps |
| `tools/{web_spec,dom_stub,client_smoke,net_client_smoke,world_build,mesh_bench}.mjs` | `tools/` | test/bench harnesses |
| `index.html`, `net.html` | `.` | browser pages for the two shells |
| `package.gene` | `package.gene` | package manifest (renamed, see below) |

**Not copied:**

- `luanti/` — the upstream Luanti reference clone. Read-only source material for
  Miclone's design; never a build input.
- `native/`, `tools/run_native.py` — the SDL native shell and native WebSocket
  client. The Commons' Life side connects through `src/genex/websocket` +
  libcurl ≥ 8.11 directly (§1.4 row 6), not through Miclone's native client or
  launcher.
- `docs/` — Miclone's own design doc. Executable comments in the copies that
  cite `design.md §N` / `§D…` are retained provenance referring to **Miclone's
  design doc at the source commit**; the Commons' design is
  `docs/proposals/world.md`.
- `README.md`, `package.gene.lock` — rewritten / regenerated for this package.
- `dist/`, `.gene/` — generated output; ignored here as in the source.
- `client/badmod/` — empty directory in the source tree (the real fixture is
  `probes/badmod/`, copied with `probes/`).

## Adaptations

Applied across the copy; `examples/miclone` itself is unchanged.

1. **Package/entrypoint names** (M0's mandate): `^name "gene/miclone"` →
   `"gene/world"`; description now names the Commons. Application names and
   entry paths are unchanged (`server`, `world_spec`, `persistence`, …).
2. **Content namespace** `miclone:` → `commons:` — every registration, lookup,
   wire fixture and test literal (`commons:stone`, `commons:crafting`, the
   `make_commons:…` craft ids, …). Mod package `miclone/default` →
   `commons/default`; the sandbox fixture `miclone/badmod` → `world/badmod`.
3. **Environment/config names:** `GENE_MICLONE_WORLD` → `GENE_WORLD_ROOT`,
   `GENE_MICLONE_MODS` → `GENE_WORLD_MODS`; harness vars `MICLONE_SMOKE_*` →
   `WORLD_SMOKE_*`. Temp paths: `/tmp/miclone_server_world` →
   `/tmp/world_server_world`, `/tmp/miclone_world` → `/tmp/world_probe`,
   `/tmp/miclone_smoke_world` → `/tmp/world_smoke_world`,
   `/tmp/miclone_sandbox_escape` → `/tmp/world_sandbox_escape`.
   Stored world name `"miclone"` → `"commons"`; log prefix `miclone server:` →
   `world server:`; page titles → `Gene World`.
4. **Stale type imports dropped** — three imports of platform type names that no
   longer exist: `$fs [WriteDir]` in `probes/run_loader.gene`, `$os [Env]` in
   `server/main.gene` and `server/mods_runtime.gene`. Each symbol was imported
   but unused. `examples/miclone` fails to load `probes/run_loader.gene` at the
   source commit with the identical `module/namespace has no export` error, so
   this is pre-existing platform drift, not copy damage; the copy runs, the
   original still does not. (`$runtime/load_sandboxed` itself is alive in
   `src/gene/vm.nim` and kept on purpose through the capabilities removal.)

No import, asset fetch, script, fixture, or launched process in this tree
references `examples/miclone` (see the independence run below).

## Storage-publication finding (M0 deliverable)

Established from `src/gene/stdlib.nim` (`$db/sqlite`), on the copied storage
path (`server/storage.gene` → `$db/sqlite` `open`/`Db`):

- **`sqlite/open` is whole-image.** It normalizes the path, reads any existing
  file bytes, opens `":memory:"`, and loads the file with `sqlite3_deserialize`
  (`FREE_ON_CLOSE|RESIZABLE`). The database always lives in memory.
- **Every commit rewrites the whole file.** After each mutated statement that
  lands in autocommit, `sqlitePersist` serializes the **entire** database
  (`sqlite3_serialize`) and replaces the file atomically (`fsWriteAtomic`,
  owner-only). `Db/transaction` batches this to one publish per COMMIT;
  `Db/close` deliberately does not publish (commits already did).
- **Pragmas cannot change this.** WAL/synchronous settings act on SQLite's
  pager, which is not what persists this database — publication is the
  filesystem-provider rename. Accepting a pragma is not a backend change.

This is the write amplification [R3]/[D2] flagged and §12.8 rules out for
milestones 1–3: cost is O(database size) per committed transaction, with no
incremental journal and no crash window inside SQLite itself (the replace is
atomic, but a large world pays a full image write per action-boundary commit).

**The narrow direct on-disk SQLite integration to implement** (planned for
milestones 1–3, §12.8): open the **real file** with `sqlite3_open` instead of
`:memory:` + `sqlite3_deserialize` — the call is already bound in stdlib's
`SqliteApi` record — and drop the per-commit `sqlite3_serialize` +
`fsWriteAtomic` publication (retaining it at most as an explicit export/snapshot
tool). SQLite's own pager then provides incremental, transactional, crash-safe
writes (rollback journal or WAL) at the action boundary. The `Db`/`WorldStore`
call surface (`exec`/`query`/`execute`, `begin_batch`/`commit_batch`) is kept,
so the change is confined to the open/publication pair — a small `$db/sqlite`
open mode (e.g. `open_file`) or an equally narrow Commons-side binding.

## Baseline results (2026-09-22)

Platform: `bin/gene` built `nim c -d:release --mm:orc --opt:speed
--passC:"-march=native -O3"` with
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` (the default
SDK link fails on this machine; `nimble speedy` runs the same compile). Node.js
for the harnesses. An earlier non-optimized binary made generation ~10.5×
slower and tripped the smoke's 300 s listen budget; all numbers below are on
the optimized build.

VM applications (`gene run <name>`), all PASS:

- `world_spec`, `wire_spec`, `protocol_spec`, `inventory_spec`, `edit_spec`,
  `loaded_spec`, `physics_spec`, `light_spec`, `mapgen_spec`, `abm_spec`,
  `loader`, `worldgen` (reading B is its documented expected-fail — the 80³
  node-rate implication, closed by §D7.11's AOT path), `persistence create` →
  `persistence verify` in a fresh process.
- `wire_bench` runs (reporting numbers); `divergence` dumps its golden
  checksums.

Web (`tools/build_web.sh --clean` → `dist/`):

- 68 modules built.
- `node tools/web_spec.mjs <module>` PASS for `web_world_spec`, `web_wire_spec`,
  `web_protocol_spec`, `web_inventory_spec`, `web_edit_spec`,
  `web_loaded_spec`, `web_physics_spec`, `web_light_spec`,
  `web_mapgen_spec`, `web_abm_spec`.
- `web_divergence` output is **byte-identical** to the VM `divergence` dump.

Wiring smokes:

- `node tools/client_smoke.mjs` PASS (stubbed DOM: HUD, walking, flying, dig →
  hotbar, place, slot select, drag, mod-declared crafting form).
- `node tools/net_client_smoke.mjs` PASS — boots `gene run server` as a real
  process, connects through a real WebSocket: 576 blocks received and meshed in
  11.8 s, entity messages, formspec built from the wire, server-confirmed
  movement.

## Independence verification (F24)

With `examples/miclone` **moved out of the repository entirely** (no source, no
`dist/`, no caches), from `examples/world/` on the same platform:

1. `tools/build_web.sh --clean` → 68 modules built.
2. `gene run wire_spec` PASS, `gene run loader` PASS.
3. `node tools/client_smoke.mjs` PASS.
4. `node tools/net_client_smoke.mjs` PASS (576 blocks meshed in 11.7 s).

Then `examples/miclone` was restored, unchanged. A clean Commons checkout plus
the declared platform dependencies (optimized `bin/gene`, Node.js) builds the
browser and server, runs its own tests, and supports browser/world interaction
without Miclone present — the §1.4 acceptance criterion.

## Cross-check against the original

Per §17 M0 ("An original Miclone build can help diagnose a copy"), failures seen
during the copy were diagnosed against `examples/miclone` at the source commit:
the `WriteDir`/`Env` load errors and the slow-binary `worldgen` budget failure
reproduce there identically; with the optimized binary and the import fix, the
copy's suite is green and `worldgen` readings match the original's.
