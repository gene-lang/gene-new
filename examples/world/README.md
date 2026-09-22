# Gene World — The Commons

A shared persistent human–AI world: one authoritative world process, browser
players, and AI Lives speaking the same versioned action contracts. The design
is [`docs/proposals/world.md`](../../docs/proposals/world.md) ("Gene World: An
Expandable Human–AI Commons"). This tree is the Commons' source of record,
started by the proposal's Milestone 0 as a copy-and-adapt of the Miclone voxel
engine. It is self-contained, with no dependency on `examples/miclone`.

## Status: Milestone 0

The tree is the **copied starting point**: Miclone's world server, browser
client, portable `core/` modules and their whole test suite, renamed for the
Commons. Two Miclone pieces the design rules out were removed after copying:

- the in-tab singleplayer client, which generated its own world;
- the runtime mod sandbox with manifest `^grants`.

Content is now compiled in, and the server owns the world.

Milestone 1 reshapes the tree into the Commons application:

- the §9 JSON envelope protocol
- server-owned click-to-move
- participant sessions and control fencing
- durable action receipts
- entities with stable ids
- the incremental on-disk store

[`SOURCES.md`](SOURCES.md) has the provenance, the adaptations, the current
storage behavior and its measured limits, the per-part disposition, and the
baseline results.

**Reading copied comments.** Most comments are Miclone's own history. In them:

- `design.md` means **Miclone's** `examples/miclone/docs/design.md` at the
  source commit, not this repository's `docs/design.md`, which is the Gene
  language design.
- Bare `§N` / `§DN` references are Miclone's sections too.
- Milestones `M0`–`M8` are Miclone's, not the Commons'.

Commons references name `docs/proposals/world.md` explicitly.

## Layout

```
core/      portable Gene, VM and web profile: world, mapgen, light, mesh,
           physics, inventory, entities, wire + protocol codecs
client/    the browser client (net_main.gene) and its WebGL2 renderer
server/    world process: $net/http WebSocket loop, SQLite store, block format
mods/      the default content set (commons/default), compiled in by core/mods.gene
probes/    specs and their VM/web runners, network probes, fixtures
tools/     web build, suite runner, smoke and bench harnesses
index.html the player page
```

## Build and run

Build optimized Gene from the repository root. With an unoptimized build,
world generation is about 10× slower and the smoke's 300 s listen budget
trips.

```sh
nimble speedy
export PATH="$(pwd)/bin:$PATH"
```

If linking fails on macOS, point `SDKROOT` at an installed SDK, e.g.
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk nimble speedy`.

Then, from `examples/world/`:

```sh
tools/build_web.sh                # the portable modules and the client, into dist/
gene run server                   # world at /tmp/gene_world_server; GENE_WORLD_ROOT picks another
python3 -m http.server 8000       # then open http://localhost:8000/
```

A fresh world takes about a minute to generate; the server is ready when port
8790 is listening. Its stdout is block-buffered when piped, so don't wait on
the log.

## Test

```sh
tools/check.sh            # everything, ~10 min on an idle machine; non-zero exit on failure
tools/check.sh --fast     # no server: VM + web specs and their diffs, under a minute
```

`check.sh` runs every step below and applies the verdict rule: a Gene runner
exits 0 either way, and its verdict is the last `PASS — …` / `FAIL — …` line.

### Cross-backend specs

Every `core/` module must behave identically on the VM and in the web
profile, so each spec's two reports must be byte-identical:

```sh
tools/build_web.sh --clean        # after adding or removing a module
for s in world wire protocol inventory edit loaded physics light mapgen abm; do
  gene run ${s}_spec | diff - <(node tools/web_spec.mjs web_${s}_spec)
done
gene run divergence | diff - <(node tools/web_spec.mjs web_divergence)
gene run persistence create && gene run persistence verify   # fresh process; /tmp/gene_world_probe
```

### Client smoke: real server, real WebSocket, stubbed DOM

```sh
node tools/net_client_smoke.mjs                          # boots its own server
WORLD_SMOKE_RECOVERY=1 node tools/net_client_smoke.mjs   # partial store: recover missing blocks, keep the edited one
```

The smoke keeps its world at `/tmp/gene_world_smoke` between runs:

- `WORLD_SMOKE_WORLD` moves it.
- `WORLD_SMOKE_FRESH=1` regenerates it.
- A failed run discards it.

It refuses an occupied port 8790, so it never runs against another server's
world.

### Network probes: peers that check the server is right

```sh
node tools/web_spec.mjs web_net_probe       # handshake, transfer, dig, place, a refused lie
node tools/web_spec.mjs web_tick_probe      # digs under sand, then stops talking
node tools/web_spec.mjs web_entity_probe    # hangs an item in mid-air, then stops talking
node tools/web_spec.mjs web_chest_probe     # crafts, places, opens, fills, empties a chest
node tools/web_spec.mjs web_players_probe   # two peers: the only check that needs two
```

Each probe connects to a server that is already running. **Every probe needs
its own fresh world.** A probe digs, crafts and places, and a second probe in
the same world fails for reasons that are not its own. Before each probe:

1. Stop the previous server and wait for port 8790 to close.
2. Start one on an empty directory, or on a copy of a world no client has
   connected to.
3. Wait for the port.

`check.sh` does this for you.

### Budgets and benches

```sh
gene run worldgen                 # generation budget; reading B is a documented expected-fail
gene run wire_bench               # what a block message costs to encode on the VM
node tools/mesh_bench.mjs         # generation + meshing budget per chunk
node tools/world_build.mjs        # what opening a world costs, and a 2-minute walk
```
