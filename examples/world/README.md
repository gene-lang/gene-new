# Gene World — The Commons

A shared persistent human–AI world: one authoritative world process, browser
players, and AI Lives speaking the same versioned action contracts. The design
is [`docs/proposals/world.md`](../../docs/proposals/world.md) ("Gene World: An
Expandable Human–AI Commons"). This tree is the Commons' source of record,
started by the proposal's Milestone 0 as a copy-and-adapt of the Miclone voxel
engine. It is self-contained, with no dependency on `examples/miclone`.

## Status: Milestone 2

One world, one or more browser players, and independent Life processes. The
world process owns the neighborhood, its unique watering can, server-owned
walking, local speech, durable receipts, control-generation fencing and an
incremental on-disk store, and serves the player page itself. Gene Lives
(`examples/life`) attach through `genex/websocket` with operator-issued
credentials, each with its own process and private store, and act through the
same operations a person's clicks send. [`MILESTONES.md`](MILESTONES.md) maps
every Milestone 1 and 2 requirement to its implementation and evidence and
lists what carries forward; [`SOURCES.md`](SOURCES.md) is the Milestone 0
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
core/      portable Gene, VM and web profile: the node and tile registries,
           the content API, and the world array, lighting, meshing, pointing
           and texture helpers the browser client draws with
client/    the browser client (main.gene), its WebGL2 renderer and atlas
server/    the world process: the HTTP/WebSocket host and the player page it
           serves, the runtime, navigation, the scene, participants, the
           protocol and the SQLite store
mods/      content, compiled in by core/mods.gene: the neighborhood's nodes and
           tiles
probes/    cross-backend specs for core/, each with a VM and a web runner
tools/     the web build, the suite (check.sh) and the process smokes
```

There is no page file: `server/host.gene` renders the player page and serves
the client compiled from `client/main.gene`. `dist/` (web build output),
`.gene/` and `data/` (the default world directory) are generated and ignored.

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
playing. Click the ground to walk, click the watering can to select it, type
in **Say** to speak to whoever is nearby, drag to orbit, wheel to zoom.
Provisioning needs the world stopped (one writer).

### Attach a Life

A Life is its own process with its own store (`examples/life`), attached over
a WebSocket with a credential the operator issues for its id. It needs the
`genex/websocket` native library (libcurl ≥ 8.11 with WebSocket support):

```sh
# once, from the repository root
python3 src/genex/websocket/tools/build.py --pkg-config-path "$(brew --prefix curl)/lib/pkgconfig"

bin/gene run examples/life/src/main.gene create examples/life/homes/aster --network
#   → {"id":"life-…", …}
(cd examples/world && gene run world life add life-… "Aster" --credential-out /tmp/aster.credential)
bin/gene run examples/life/src/main.gene bind examples/life/homes/aster ws://127.0.0.1:8096/world/v1 /tmp/aster.credential
bin/gene run examples/life/src/main.gene run examples/life/homes/aster
```

A Life's home must be inside the Life package (it runs its programs in
sandboxed directories there); `examples/life/homes/` is the place for one you
keep. The fake brain walks to the garden
and says so when it arrives — a data continuation, not a waiting program —
and acknowledges a person who speaks to it. `bind` copies the credential into
an owner-only file beside the Life's store; delete the one you were handed.

## Test

```sh
tools/check.sh            # everything, a few minutes on an idle machine; non-zero exit on failure
tools/check.sh --fast     # no server: VM + web specs and their diffs, under a minute
```

`check.sh` runs every step below and applies the verdict rule: a Gene runner
exits 0 either way, and its verdict is the last `PASS — …` / `FAIL — …` line.

### Cross-backend specs

Every `core/` module must behave identically on the VM and in the web
profile, so each spec's two reports must be byte-identical:

```sh
tools/build_web.sh --clean        # after adding or removing a module
for s in world light loaded raycast; do
  gene run ${s}_spec | diff - <(node tools/web_spec.mjs web_${s}_spec)
done
```

### The world process

```sh
node tools/commons_smoke.mjs     # protocol, receipts, fencing, kill -9 recovery (41 checks)
tools/build_web.sh && node tools/client_smoke.mjs   # the real client, stubbed DOM (16 checks)
```

Each creates a throwaway world and starts its own `gene run world run` (ports
8097 and 8098), and refuses a port that is already serving.

### Networked Lives (Milestone 2)

```sh
node tools/life_smoke.mjs      # a world, two Life processes and a human (34 checks, ~80 s)
bin/gene test --package-root examples/life examples/life/tests/world_network_spec.gene \
                                           examples/life/tests/delivery_spec.gene   # from the repo root
```

`life_smoke.mjs` (port 8099) runs real processes: native admission, walk-then-
act continuations, speech both ways, a human and two Lives contending for the
can, a Life and then the world killed mid-walk, a request committed while the
world is down, an operator pausing a Life mid-walk, and the missing-library
preflight. The Life specs drive the same
code against an in-memory world that can lose replies, answer `unknown`, replay
and skip sequences.
