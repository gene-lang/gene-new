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
tests/     the suite: core on both backends (checks/ holds the shared
           web-profile halves) and the world with real processes
tools/     the web build (build_web.gene) and the Node players the process
           tests start
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

The suite is Gene tests, run from `examples/world/`:

```sh
gene test                        # everything, about three minutes on an idle machine
gene test tests/core_spec.gene   # no server: the shared core on both backends, a few seconds
```

### The shared core, on both backends

Every `core/` module must behave identically on the VM and in the web
profile. The web profile has no `$test`, so the checks live in web-profile
modules that build a report (`tests/checks/*_checks.gene`), and
`tests/core_spec.gene` asserts two things about each: the report holds on the
VM, and the web build of the same module prints exactly that report under
node.

```sh
gene run build_web --clean       # the web build alone, after adding or removing a module
```

### The world process, and networked Lives

`tests/process_spec.gene` starts real processes: a throwaway world
(`gene run world run`, ports 8097–8099) and whoever plays it. The players are
Node scripts, each of which can also be run alone:

```sh
node tools/commons_smoke.mjs     # protocol, receipts, fencing, kill -9 recovery (41 checks)
gene run build_web && node tools/client_smoke.mjs   # the real client, stubbed DOM (16 checks)
node tools/life_smoke.mjs        # a world, two Life processes and a human (34 checks, ~80 s)
```

`life_smoke.mjs` covers native admission, walk-then-act continuations, speech
both ways, a human and two Lives contending for the can, a Life and then the
world killed mid-walk, a request committed while the world is down, an
operator pausing a Life mid-walk, and the missing-library preflight. Each
script refuses a port that is already serving. They stay in Node because a
browser-shaped peer needs a WebSocket client that sends a cookie and an
Origin, the compiled client needs a DOM, and a crash test needs to kill a
process outright.

The Life package has its own suite, which drives the same network code
against an in-memory world that can lose replies, answer `unknown`, replay
and skip sequences (from the repository root):

```sh
bin/gene test --package-root examples/life examples/life/tests/
```
