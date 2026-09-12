# Miclone

A voxel game engine with [Luanti](https://github.com/luanti-org/luanti)'s
architecture, written in Gene, whose mod language is Gene.

**A generated, lit world you can walk around in, dig, carry, craft with, store
things in, and build with** — running as two processes, defined by a mod,
changing on its own, and shared with other players who can see you.

The server owns the world and answers a WebSocket; each client is handed
it and plays it, sharing every rule through `core/`. The game itself is
`mods/default`, read off disk through a capability sandbox that grants it exactly
the namespaces its manifest declares — which is none — while a client draws its
content from recipes on the wire without ever running mod code.

Read [`docs/design.md`](docs/design.md) for the why. Part I is the direction and
the decisions; §D2 is the platform constraint that shaped everything else.

M0 through M9 are implemented. The native shell uses SDL2/OpenGL and a native
WebSocket client through compiled Gene bindings (design.md §D7.8).
See the current verification results under Checks.

## Running it

Build optimized Gene from the repository root with `nimble speedy`, then use
`export PATH="$(pwd)/bin:$PATH"` before changing directories. The absolute PATH
entry keeps these commands on this checkout's compiler instead of another Gene
installation. `tools/build_web.sh` selects the checkout's `bin/gene` by default;
set `GENE_EXE` to override it. A failed module build prints its diagnostics.

The reference source is a shallow clone of upstream, not vendored here, and only
needed if you want to read it:

```sh
git clone --depth 1 https://github.com/luanti-org/luanti examples/miclone/luanti
```

### Singleplayer, in a tab

```sh
cd examples/miclone
tools/build_web.sh               # every portable module, into dist/
python3 -m http.server 8000      # then open http://localhost:8000/
```

Drag to look, WASD to move, space/shift for up and down, number keys or the
wheel to pick a hotbar slot, **E** for the crafting panel. Left-click digs,
right-click places — or opens, if you are pointing at a chest.

`tools/build_web.sh --clean` after adding or removing a `core/` module. The
module list lives in the script rather than here: the profile emits one flat
output directory keyed by basename, so the list is the whole graph rather than a
set of entry points. `--clean` matters for the other half of that — a deleted
module leaves its `dist/*.mjs` behind, and a harness importing it keeps passing
off the stale artifact.

### Client and server as separate processes

```sh
gene build --target web client/net_main.gene --out-dir dist
mkdir -p /tmp/miclone_server_world
gene run --allow_read_write_dir /tmp/miclone_server_world server
                                 # opens or generates the world, listens on 8790
                                 # a custom GENE_MICLONE_WORLD needs its own grant
python3 -m http.server 8000      # then open http://localhost:8000/net.html
```

The browser client renders a world it was **handed** rather than one it
generated, and a click goes to the server, is applied there, and comes back as a
node delta with the drop in the hotbar. Same physics, mesher, raycast and hotbar
as the in-tab client, because all of them are `core/` and neither side has its
own copy.

Chop a tree, press **E**, click *make* down the chain — plank, chest — place it
and right-click it.

### Native desktop client

On macOS, install the desktop dependencies once:

```sh
brew install sdl2 sdl2_ttf curl pkg-config
cd examples/miclone
python3 tools/run_native.py
```

The launcher builds the libraries in `src/genex`, resolves the separate native package,
starts a local server when needed, and opens the SDL window. The controls match
the browser client. `--no-build` reuses compiled libraries; `--font PATH`
selects a font, `--world PATH` selects a local world, and `--url ws://HOST:PORT/`
connects to an existing server. The launcher stops servers it started when the
client exits. A first launch can take several minutes to generate, transfer and
mesh the world in the VM; the window shows loading progress.

To build just the libraries, run `nimble genex` from the repository root.

Linux needs the corresponding development libraries, a libcurl build with
WebSockets, and an installed TrueType/OpenType font. Pass `--pkg-config-path`
for SDKs outside pkg-config's default search path. The native package is
separate so browser/server use does not acquire desktop SDK dependencies.

```sh
python3 tools/run_native.py --smoke
```

The smoke owns a temporary world and server, requires a free port 8790, drives
SDL input, checks server-confirmed edits, crafting, chest actions and multiplayer
entities, and requires at least 60 steady frames per second. It writes real
framebuffer captures to `native/.gene/native-smoke.png` and
`native/.gene/native-smoke.form.png`.

## Layout

```
core/       portable Gene — compiles for the VM and the web profile
  exact.gene    exact F64 integer arithmetic and float bit comparison (§D3.1)
  noise.gene    value noise and fractal composition (§D7.5)
  field.gene    coarse-lattice 2D noise fields (§3.2)
  world.gene    blocks, coordinates, light packing (§1)
  loaded.gene   the client's loaded world: one array, one shell (§1.1)
  registry.gene the node registry, client half (§2)
  item.gene     the item registry: an item id is not a content id (§2.2)
  groups.gene   cross-cutting groups, and what a tool digs (§2.2)
  tiles.gene    the atlas recipes a mod registers (§2)
  drops.gene    what digging a node yields — §2's server half
  biome.gene    the biome registry (§3 stage 2)
  cave.gene     Bézier-worm carving (§3 stage 3)
  ore.gene      the ore registry: scatter, sheet, blob (§3 stage 4)
  decor.gene    trees, placed by a pure function of the column (§3.6)
  mapgen.gene   the staged pipeline (§3)
  light.gene    sunlight and light sources, packed into param1 (§4)
  mesh.gene     face-culled meshing (§5)
  vec.gene      mat4, vec3 (§D7.6)
  physics.gene  the player box against the voxel grid (§7)
  raycast.gene  Amanatides-Woo node selection (§7)
  edit.gene     one node changes, and what that invalidates (§7.1)
  inventory.gene  stacks, in a buffer of (item, count, wear) triples (§7.1)
  craft.gene    shapeless recipes (§2.3)
  entity.gene   dropped items and players, and the mod's on_step (§8)
  seen.gene     §8's client half: what a client has been told is there
  api.gene      §9's mod API — the only surface a mod registers through
  mods.gene     §9's load step for the compiled-in path
  abm.gene      §12's check queue and ambient sampling
  wire.gene     the byte codec both backends encode messages through (§10)
  protocol.gene the messages, encoded as bytes (§10)
  formspec.gene §13's UI as data, validated at registration
  container.gene §13's node inventories: a chest's contents
  client_world.gene received blocks, node deltas and hotbar labels
  shaders.gene  shared GLSL shader bodies for WebGL2 and desktop OpenGL
  texture.gene  shared procedural atlas painter
mods/       the game, as mods (§9)
  default/    every node, tile, drop, biome, ore, recipe and callback
server/     VM only: the block format, the SQLite world store (§11),
            the sandboxed mod loader (§9.3), and main.gene (§10, §12)
client/     the browser shell: WebGL2 renderer, atlas, sound, camera
              main.gene generates the world; net_main.gene is handed it
native/     the SDL2/OpenGL shell, using genex/sdl2 and genex/websocket
probes/     cross-backend specs and network probes. `run_*.gene` are the VM
            shells and `web_*.gene` the web-profile ones — the same shell
            twice, differing only in `$println` vs `$console/log`
tools/      the harnesses that cannot be Gene: a DOM stub, and the smokes that
            boot a server and poll a port. `web_spec.mjs` is the one line the
            profile requires — a web module exports an entry and the host calls
            it
docs/       design.md
```

`core/` is written in the intersection of what the VM runs and what the `web`
profile compiles. Printing is not in that intersection — `$println` is a VM
builtin and a browser has no stdout — which is why each probe is a portable
module with a shell per backend rather than one module with a conditional.

## Checks

Rechecked on 2026-09-12: a clean build of all 68 web modules, the eleven
VM/web output comparisons, the singleplayer client smoke test, and the meshing
budget check pass. The real-network smoke also checks that all 576 blocks are
on disk **before the first edit**, which could otherwise hide a missing startup
commit. It can exercise recovery from interrupted initialization as well as
fresh creation and cached loading.

The native smoke passes on macOS with OpenGL 4.1: 576 received blocks,
117,528 initial faces, SDL movement and dig/place, crafting planks and a chest,
chest put/take actions, and another player appearing and leaving. The final
five-second steady-rendering sample measured **171 fps** at 2560×1440 with
vsync disabled. This excludes loading, edits and framebuffer capture. The GPU
pixel/font/audio probe and independent WebSocket peer test also pass. Linux's
build path is provided but has not been verified on a Linux host.

### Cross-backend specs

Each must produce byte-identical output on the VM and through the web profile.

```sh
gene run world_spec     | diff - <(node tools/web_spec.mjs web_world_spec)      # §1, §2
gene run mapgen_spec    | diff - <(node tools/web_spec.mjs web_mapgen_spec)     # §3, §5, §14
gene run light_spec     | diff - <(node tools/web_spec.mjs web_light_spec)      # §4
gene run loaded_spec    | diff - <(node tools/web_spec.mjs web_loaded_spec)     # §1.1, §4.2
gene run physics_spec   | diff - <(node tools/web_spec.mjs web_physics_spec)    # §7
gene run edit_spec      | diff - <(node tools/web_spec.mjs web_edit_spec)       # §7, §7.1
gene run inventory_spec | diff - <(node tools/web_spec.mjs web_inventory_spec)  # §2, §7.1
gene run wire_spec      | diff - <(node tools/web_spec.mjs web_wire_spec)       # §10
gene run protocol_spec  | diff - <(node tools/web_spec.mjs web_protocol_spec)   # §10
gene run abm_spec       | diff - <(node tools/web_spec.mjs web_abm_spec)        # §8, §9, §12
gene run divergence     | diff - <(node tools/web_spec.mjs web_divergence)      # §D6.2
```

### Headless harnesses

```sh
node tools/mesh_bench.mjs        # generation + meshing budget (§D6.1)
node tools/world_build.mjs       # what opening a world costs, and a 2-minute walk
node tools/client_smoke.mjs      # the in-tab client's wiring, DOM stubbed
node tools/net_client_smoke.mjs  # boots its own server and plays it, ~40 s
MICLONE_SMOKE_RECOVERY=1 node tools/net_client_smoke.mjs # resets its fixture, then recovers missing blocks

gene run worldgen                # §D6.3's three budget readings
gene run wire_bench              # what a block message costs to encode
gene run loader                  # the mod, read off disk and sandboxed (§9.3)
mkdir -p /tmp/miclone_world
gene run --allow_read_write_dir /tmp/miclone_world persistence create
gene run --allow_read_write_dir /tmp/miclone_world persistence verify  # §11
```

### Network probes

Each speaks §10 itself, as a **peer** rather than a client, which is what makes
it able to say the server is right.

```sh
node tools/web_spec.mjs web_net_probe      # handshake, transfer, dig, place, a refused lie
node tools/web_spec.mjs web_tick_probe     # digs under sand, then stops talking (§12)
node tools/web_spec.mjs web_entity_probe   # hangs an item in mid-air, then stops talking (§8)
node tools/web_spec.mjs web_chest_probe    # crafts, places, opens, fills, empties one (§13)
node tools/web_spec.mjs web_players_probe  # two peers — the only check that needs two
```

**Every probe wants a fresh world, and "fresh" means the previous server is dead
— not that the port answers.** A probe digs, crafts and places; run a second one
against the same world and it plays in the wreckage of the first, which reads as
failing checks in the probe rather than as a dirty fixture. Waiting for
`nc -z 127.0.0.1 8790` does not establish this: it succeeds *instantly* against a
server that outlived its runner, and a genuinely fresh one takes about 75 s to
generate.

```sh
lsof -tnP -iTCP:8790 -sTCP:LISTEN | xargs -r kill   # and wait for it to go
rm -rf /tmp/miclone_play_world
mkdir -p /tmp/miclone_play_world
( cd examples/miclone && GENE_MICLONE_WORLD=/tmp/miclone_play_world gene run --allow_read_write_dir /tmp/miclone_play_world server & )
```

**Wait on the port, not the log.** The server's stdout is block-buffered when it
is a pipe, so "listening on 8790" can sit unflushed for the whole run.
`script -q <logfile> gene run server` gives it a pty if you need the output.

`tools/net_client_smoke.mjs` is the exception: it boots its own server and keeps
its world at `/tmp/miclone_smoke_world` between runs, because the one edit it
makes is a dig followed by a place of the same node. It discards that world if
the run failed. `MICLONE_SMOKE_FRESH=1` forces a new one.
`MICLONE_SMOKE_RECOVERY=1` also resets this test world, but leaves metadata and
one edited block before startup. It checks that recovery saves the missing
blocks and preserves the edited block byte for byte. The harness refuses an
occupied port 8790 so it never runs against another server's world.

**Two traps when measuring frame rate in a browser.** A backgrounded tab
throttles `requestAnimationFrame` to nothing — measured at 6 fps against 166 for
the same build a second later — and macOS marks an *occluded* window hidden too,
so Chrome being frontmost is not enough; `document.hidden` and the rAF count are
the only reliable signals. And `python3 -m http.server` sends no `Cache-Control`,
so a plain reload can silently re-run the previous build.

## Measured

| | |
|---|---:|
| frame rate, either browser client | **166 fps** — the display's ceiling, not the engine's |
| native steady frame rate, macOS | **171 fps** at 2560×1440, vsync off; loading and edits excluded |
| drawn | 229 chunk meshes, 62,395 faces, no frustum culling |
| chunk: generate + light + mesh (V8) | **0.22 ms**, worst chunk 0.91 against an 8 ms budget |
| opening a 12×4×12 world (V8) | **114 ms** — 55 generate, 24.7 light 2.48M nodes, 32.8 mesh |
| block: generate + light (VM) | **58.1 ms** against a 300 ms budget |
| a physics step | 1.6 µs |
| an edit, end to end in a tab | 1.8–3.5 ms, naming 9.2 chunks to remesh on average |
| a block on the wire | **575 bytes mean** — 0.32 MB for a whole world, 29× |
| a block on disk | **612 bytes mean** against 24,576 raw, 40× |
| encoding a block message | **17.9 ms** on the VM against V8's 0.032 ms |
| leaf face culling | 208,608 faces → **117,528**, 43.7% of the world's geometry |
| mod off disk vs compiled in | identical — 20 nodes, 23 items, 2 forms, same ids |
| cross-backend float divergence | **zero differing bits** over 323 samples |

**The ceiling is the server, and it always has been.** A message send is ~500 ns
on the VM, so a block encode is ~16,000 buffer reads before any arithmetic —
that, not the socket, is why a world takes ~12 s to transfer. The frame rate has
never been the problem. design.md §D6.3, §10.1 and §D7.11 are the thread.

## Not built

- **`on_punch` and `on_death`.** Nothing in this engine can hit an entity, so
  they would be fields nothing could call (§8.2).
- **Player state does not persist.** Each connection gets a fresh inventory at
  the server-chosen spawn, so quitting resets what you were carrying while the
  world you dug persists exactly (§11.1).
- **Blocks never unload**, so static entity serialization has nowhere to happen
  (§8) and the loaded extent is fixed at construction (§1.1).
- **Three drawtypes are declared and not honoured** — `glasslike`, `allfaces`
  and `plantlike` draw as ordinary cubes, which is invisible only because
  nothing declares them (§2.1).
- **No text field in a formspec**, which covers a chest and does not cover a
  sign (§13.4).
- **Groups and tool capabilities do not cross the wire**, so a click digs
  immediately rather than at a predicted rate (§2.2).
- **Deflate.** Run-length encoding ships; deflate is worth another 5.8× on top
  and the format's flags byte is where it lands (§D7.4).
