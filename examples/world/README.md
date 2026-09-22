# Gene World — The Commons

A shared persistent human–AI world: one authoritative world process, browser
players, and AI Lives speaking the same versioned action contracts. This tree is
the Commons' source of record, started by Milestone 0 of
[`docs/proposals/world.md`](../../docs/proposals/world.md) ("Gene World: An
Expandable Human–AI Commons") as a copy-and-adapt of the Miclone reference —
self-contained, with no dependency on `examples/miclone`.

It currently carries the copied browser/server starting point (voxel-era
machinery included) and its whole test suite. Milestone 1 reshapes it into the
Commons application: the §9 JSON envelope protocol, server-owned click-to-move,
entities with stable ids and named components, receipts and operation identity,
and incremental on-disk storage (see `SOURCES.md` for the storage finding and
the identified integration). Provenance, adaptations and baseline results live
in [`SOURCES.md`](SOURCES.md).

## Layout

```
core/      portable Gene — VM and web profile
client/    browser shells (in-tab and networked) and the WebGL2 renderer
server/    world process: $net/http WebSocket loop, storage, content loading
mods/      the default content set (commons/default)
probes/    specs, runners, web spec shells, fixtures
tools/     web build script and test/bench harnesses
```

## Build and run

Build optimized Gene first (repo root):

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
nimble speedy
export PATH="$(pwd)/bin:$PATH"
```

In-browser singleplayer (client generates its own world):

```sh
tools/build_web.sh               # every portable module, into dist/
python3 -m http.server 8000      # then open http://localhost:8000/
```

Client and server as separate processes:

```sh
tools/build_web.sh
mkdir -p /tmp/world_server_world
gene run server                  # GENE_WORLD_ROOT picks another world directory
python3 -m http.server 8000      # then open http://localhost:8000/net.html
```

## Test

```sh
for app in world_spec wire_spec protocol_spec inventory_spec edit_spec \
           loaded_spec physics_spec light_spec mapgen_spec abm_spec \
           loader worldgen; do gene run $app; done
gene run persistence create && gene run persistence verify   # fresh process

tools/build_web.sh --clean
for s in web_world_spec web_wire_spec web_protocol_spec web_inventory_spec \
         web_edit_spec web_loaded_spec web_physics_spec web_light_spec \
         web_mapgen_spec web_abm_spec; do node tools/web_spec.mjs $s; done

node tools/client_smoke.mjs       # browser wiring, stubbed DOM
node tools/net_client_smoke.mjs   # real server + real WebSocket smoke
```

`worldgen`'s reading B is a documented expected-fail (see its output).
`net_client_smoke.mjs` owns a throwaway world at `/tmp/world_smoke_world`
(`WORLD_SMOKE_WORLD` to override; `WORLD_SMOKE_FRESH=1` regenerates).
