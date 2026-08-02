# New World

A side-view Minecraft-like — dig, build, explore — where the world generation,
physics, collision, mining, **and the HTML page itself** are written in Gene.
JavaScript is the host boundary and nothing else: canvas calls, the keyboard,
and the arrays Gene writes into.

![the world at seed 1](assets/screenshot_seed1.png)

Design and direction live in [`docs/design.md`](docs/design.md). Read Part I
first — it records what is being built and why. Part II (§0–§14) is a deferred
design for a much larger game and is **not** what this code is.

---

## Build and run

Requires a built `bin/gene` and a static server. Node is only needed to run
`tools/test.mjs`; nothing in the build uses it any more.

```sh
cd <repo root>
nimble build                       # once, produces bin/gene

cd examples/new_world
gene run build --grant out=$fs/WriteDir --grant exec=$os/Exec
python3 -m http.server 8000        # any static server will do
```

The build writes files and shells out to the compiler for the web modules, so
it asks for exactly those two authorities and gets nothing else — no ambient
filesystem or process access (`docs/design.md` §15.2).

Then open <http://localhost:8000/>. It must be served over HTTP — the page uses
ES modules, which `file://` will not load.

### Controls

| | |
|---|---|
| <kbd>A</kbd> <kbd>D</kbd> or arrows | move |
| <kbd>Space</kbd> / <kbd>W</kbd> | jump |
| left-click | mine |
| right-click | place |
| <kbd>1</kbd>–<kbd>9</kbd> or scroll | select block |
| <kbd>N</kbd> | new world (random seed) |
| <kbd>S</kbd> / <kbd>L</kbd> | save / load (`localStorage`) |

You can only place what you have mined. Coal is shallow, iron is deeper, gold
is deeper still.

### Checks

```sh
node tools/test.mjs                # 41 logic checks, no browser needed
node tools/test_input.mjs          # input wiring and the frame loop

# composite a real viewport to a PNG
gene run screenshot --grant out_dir=$fs/WriteDir -- [seed] [cam_x] [cam_y]
```

`tools/test.mjs` asserts the properties that matter rather than pixel output:
generation is deterministic for a seed, the surface never steps more than three
tiles (or the world is unwalkable however good it looks), ore rarity is ordered,
the player lands and comes to rest without drifting, a jump leaves the ground
and returns, and you cannot mine out of reach or seal yourself inside a wall.
For `src/shell.gene` it round-trips all 98,304 tiles through the save encoder,
because a wrong pair count would silently truncate somebody's world.

`src/screenshot.gene` renders through the same atlas and the same
`src/world.gene` the browser runs, so the world can be reviewed — and
regressions caught — from a terminal with no browser open. It is how the
cave-backdrop and tile-repetition problems were found.

---

## What is written in what

Gene reaches the browser by **two different routes**, and the difference matters:

| File | Runs | How |
|---|---|---|
| `src/world.gene` | **VM and browser** | terrain, physics, mining — no host calls at all |
| `src/render.gene` | in the browser | drawing, straight onto `CanvasRenderingContext2D` |
| `src/shell.gene` | in the browser | camera, spawn, save encoding, hotbar |
| `src/main.gene` | in the browser | state, input, save/load, the frame loop |
| `src/page.gene` | at build time | on the **VM**, emitting `index.html` |
| `boot.mjs` | in the browser | three lines: a `<script src>` entry that calls `boot()` |

**The game is Gene.** There are no `js/fn` externs and no JavaScript game code:
the canvas, the keyboard, `localStorage`, `requestAnimationFrame`, and image
loading are all reached through the web profile's own host surface
(`$canvas/*`, `$dom/*`, `$event/*`, `$frame/*`, `$storage/*`, `$image/*`).
`boot.mjs` exists only because a browser needs an entry point it can
`<script src>` — an ES module's export is not self-executing.

Every one of those host operations is verified against the pinned
`lib.dom.d.ts` by `tools/check_host_bindings.mjs`, which runs in
`nimble transpile_spec`. The compiler is the source of truth for what Gene can
call; TypeScript is the oracle for whether those calls are real.

`src/world.gene` makes **no host calls at all**, which is what lets it run on
the Gene VM as well as compile to JavaScript. That is the property worth
having: a disagreement between the two backends is a compiler bug, and there is
one source to find it with.

### Everything hot is `F64`

[`transpile.md`](../../docs/proposals/transpile.md) §4.5 lowers Gene's `Int` to JavaScript **`bigint`** and `F64` to
`number`. BigInt arithmetic is roughly an order of magnitude slower, throws when
mixed with `number`, and cannot cross into a canvas call — so **every hot value
in `src/world.gene` is `F64`**, including loop counters and tile ids.

This is the single most important thing to know before editing the Gene. An
innocuous `(var i 0)` instead of `(var i 0.0)` puts a bigint on the hot path.

---

## Layout

This is a Gene package (`gene/new_world`), so all Gene source lives under
`src/` and `package.gene` is the manifest. Everything else is host-side
JavaScript, tooling, or build output.

```
package.gene          manifest: name, version, library and application targets
src/world.gene        terrain, physics, collision, mining — runs on VM too
src/render.gene       drawing, direct to canvas
src/shell.gene        camera, spawn, save encoding, hotbar
src/page.gene         the HTML page, as gene/html + gene/css node data
src/main.gene         state, input, save/load, the frame loop
src/png.gene          a PNG encoder in Gene: CRC32, LZ77 + Huffman, chunks
src/atlas.gene        the tile atlas: palette, seeded hash, tile drawing
src/build.gene        the build: atlas, then web modules, then index.html
src/preview.gene      an 8x blow-up of the atlas, for reviewing the art
src/screenshot.gene   composites a viewport to PNG, headless
boot.mjs              three-line browser entry point
tools/test.mjs        41 logic checks
tools/test_input.mjs  input wiring: listener targets, movement, frame loop
spike/                the D5 performance spike — its own nested package
assets/               generated atlas + screenshots
dist/                 generated JS/TS — gitignored, never edit
index.html            generated — gitignored, never edit
```

Only `boot.mjs` and the generated `dist/` modules ship to the browser;
everything under `tools/` is test-time.

`package.gene` declares four application targets, so each build step is a
named thing you can run rather than a line in a script:

| | |
|---|---|
| `gene run build` | the whole pipeline — atlas, web modules, page |
| `gene run page` | prints `index.html` to stdout |
| `gene run preview` | `assets/tiles_preview.png`, an 8x review blow-up |
| `gene run screenshot` | `assets/screenshot_seed<N>.png` |

`preview` and `screenshot` are separate from `build` because both encode
images far larger than the atlas and the art only needs reviewing when it
changes.

**Nothing in the build is JavaScript any more.** Both original blockers were
fixed, and then the tools that existed because of them were ported:

- *No math library* — `gene/math` (design.md §7.8) now provides floor, sqrt,
  sin and the rest on both backends. `src/world.gene` dropped three of its
  seven `js/fn` externs; the four that remain are canvas calls, the genuine
  boundary.
- *No binary output* — `gene/bit`, `gene/binary`, and `fs/write_bytes`
  (§7.9) make a PNG writable in Gene. `src/png.gene` is the worked encoder:
  CRC32, Adler-32, LZ77 with fixed Huffman codes, chunk layout, no host help.

`build.sh` is gone with them. The two steps that needed a shell were the two
the ports removed: the atlas needed `node`, and writing `index.html` needed `>`
redirection. `src/build.gene` does both directly, and `src/screenshot.gene`
runs `world.gene` and `render.gene` on the VM rather than through their
transpiled output — so a screenshot no longer needs `dist/` to exist and can
never drift from the source the browser is given.

The ports are byte-exact: `tiles.png`, `tiles_preview.png`, and both committed
screenshots decode to exactly the pixels the JavaScript produced. That
mattered more than it sounds, because the atlas hash leans on JavaScript
float64 semantics — see the comments in `src/atlas.gene`.

Both blockers are recorded as resolved in [`docs/design.md`](docs/design.md)
§D5.2, along with four Gene gotchas that writing the encoder turned up — `0x…`
is a Bytes literal rather than a hex Int, `//` is the remainder because `%` is
unquote, `while` shares one scope across iterations, and an empty `[]` needs a
type annotation.

`gene pkg tree` reports the resolved manifest. The library entry is
`src/world.gene` because that is the substantive module — the one a dependent
importing `from "."` would want — even though it is not any of the things you
`gene run`.

The spike carries its own `package.gene` (`gene/new_world_spike`) rather than
living in this package's `src/`. It is a measurement rig, not part of the game,
and a nested manifest is a real package boundary: discovery stops at the
nearest one, so `gene build` on a spike file selects the spike package from any
working directory.

### Assets are generated, not drawn

`src/atlas.gene` writes `assets/tiles.png` from a named palette and a seeded
hash, through `src/png.gene` — no image editor and no binary blob whose source
nobody has. Re-tune the art by editing numbers and re-running `gene run build`.

Two things about the atlas are load-bearing:

- **Tile order is the ABI.** `src/world.gene`'s `t_*` functions index into it
  positionally. Inserting a tile mid-array silently renumbers everything after
  it — that bug shipped once and rendered stone as dirt.
- **Ids 12–14 are render-only variants.** The world stores stone as `t_stone`
  so mining and inventory stay simple; `render_variant` picks among three stone
  and two dirt stamps by position hash, so a cliff face is not one 16px stamp
  repeated three hundred times.

---

## The performance spike

`spike/` answers the question that gated this whole project: can a Gene program
compiled by the [`web` profile](../../docs/proposals/transpile.md) hold 60 fps?

```sh
cd spike
../../../bin/gene build --target web src/sprites.gene --out-dir dist
cp canvas.mjs dist/
node tools/bench.mjs [sprites] [frames]
```

**Result: 10,000 moving sprites cost 4.5% of a 60 fps frame**, with headroom
around 300,000. Zero bigint on the hot path. The harness checksums the
transpiled sim against a hand-written JS one and asserts they agree, so the
timings compare two programs that provably compute the same thing.

Gene is ~32× slower than hand-written JS on that loop, which is irrelevant at
this workload but is the number that decides where the ceiling is.
`docs/design.md` §D5.2 records what the spike found in the compiler, including a
miscompilation it turned up (`if`/`while` evaluated their condition twice) and
the field-access optimisation it motivated.

---

## Known gaps

No crafting, mobs, day/night, water flow, or multiplayer. Water is decorative —
it does not spread and you cannot swim in it, only fall through it. The world is
a fixed 512×192 and does not stream, so it all generates up front (14 ms) and
lives in memory.

The open question is the one in `docs/design.md` D2: **is this fun for twenty
minutes?** Nothing downstream is worth building until that has an answer, and
the only way to get one is to play it.
