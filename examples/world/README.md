# Gene World — The Commons

A shared persistent human–AI world: one authoritative world process, browser
players, and AI Lives speaking the same versioned action contracts. The design
is [`docs/proposals/world.md`](../../docs/proposals/world.md) ("Gene World: An
Expandable Human–AI Commons"). This tree is the Commons' source of record,
started by the proposal's Milestone 0 as a copy-and-adapt of the Miclone voxel
engine. It is self-contained, with no dependency on `examples/miclone`.

## Status: Milestone 1

One browser player and the world: a Commons world process that owns the
neighborhood, its unique watering can, server-owned click-to-move, durable
receipts, control-generation fencing, and an incremental on-disk store; and a
browser player page it serves itself. [`MILESTONES.md`](MILESTONES.md) maps
every Milestone 1 requirement to its implementation and evidence and lists what
carries into Milestone 2; [`SOURCES.md`](SOURCES.md) is the Milestone 0
provenance record.

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
gene run world create                     # once; --root DIR (default data/world)
gene run world player add ada "Ada"       # prints a one-time login code
gene run world run                        # http://127.0.0.1:8096/ — sign in with that code
```

The world process serves the page, its compiled client and the
`/world/v1` WebSocket; there is no separate static server or build step for
playing. Click the ground to walk, click the watering can to select it, drag
to orbit, wheel to zoom. Provisioning needs the world stopped (one writer).

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

### The world process

```sh
node tools/commons_smoke.mjs     # protocol, receipts, fencing, kill -9 recovery (37 checks)
tools/build_web.sh && node tools/client_smoke.mjs   # the real client, stubbed DOM (13 checks)
```

Each creates a throwaway world and starts its own `gene run world run` (ports
8097 and 8098), and refuses a port that is already serving.

### Budgets and benches

```sh
gene run worldgen                 # generation budget; reading B is a documented expected-fail
gene run wire_bench               # what a block message costs to encode on the VM
node tools/mesh_bench.mjs         # generation + meshing budget per chunk
node tools/world_build.mjs        # what opening a world costs, and a 2-minute walk
```
