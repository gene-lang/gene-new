# New World — Design

**Status:** Part II (§0–§14) is **deferred**. It is a killer-app design, and the
current priority is a proof. Part I records the 2026-07-31 direction and is the
part that is live.

---

# Part I — Direction

## D1. Proof before killer app

**Build a fun, beautiful, novel game in Gene.** Gene is the implementation
language, not the subject. The "killer app for Gene" framing (§14) is retired as
a *goal*; if it ends up true, it will be true because the game is good.

And before the game, prove the thing can be built at all. This ordering is the
whole of D1, because a proof and a killer app have opposite success criteria:

| | Proof | Killer app |
|---|---|---|
| Succeeds when | it is finished, polished, and the source is worth showing | people show up and stay |
| Novelty | irrelevant — actively a distraction | essential |
| Scope | the smallest thing that is still really a game | as large as the market demands |
| Economy, accounts, moderation | none | all of it |
| Risk | technical only | technical + design + market |
| Fails as | "we never finished it" | "nobody came" |

Part II oscillates between these two columns, and that is the source of most of
its unresolved tension: every economic rule serves the right-hand column and
every `Env`-boundary argument serves the left. Naming which one is being built
settles most of them without further debate.

**The proof's deliverable is the game plus an honest list of everything that had
to be fought.** The second half matters more. If the game ships full of escape
hatches, the proof has demonstrated the opposite of its claim — quietly, and
only to us. That list is also better roadmap input than any design document,
because it is evidence rather than anticipation.

## D2. The game

A **simplified Minecraft-like, in the browser**. Get to playable, then change
things.

The reason is that it fills the hole Part II cannot: footfall is the economy,
but without player scripting a build is a static arrangement of tiles, and
"make a pretty room and hope people pass through" is not a loop. In a
Minecraft-like, **the building is the content**, and the loop is fun solo, on day
one, with nobody else online. That removes the cold-start dependency the
footfall economy could not escape, and it makes "playable" a question that
answers itself in weeks instead of after an economy is calibrated.

Be honest about what it costs: this re-scopes **up** on engine and **down** on
design. Part II chose a 2D tile world specifically to avoid chunk streaming,
world generation, meshing, gravity, and block-delta multiplayer sync. Those come
back. That is an acceptable trade — engine work is *known* work, where the §4.8
economy parameters were unknown work — but it is not a simplification and should
not be budgeted as one.

**Perspective is open, and it is the decision that sets the timeline.**
Recommendation is **side-view 2D** (Terraria-shaped): it is what "simplified
Minecraft" actually means, it keeps mining, gravity, verticality, and building,
it costs a fraction of 3D voxel work, and high-quality 2D sprite art is
achievable with one artist where "voxel art that does not look like Minecraft"
is a much harder brief. Isometric is the alternative if the 2.5D look matters
more than the timeline; full 3D voxel is ruled out for v1.

"Beautiful" is now a stated goal rather than an aspiration, which means the art
direction needs an owner earlier than Part II's §5.1 assumed.

**Novelty is deferred, and that is the risk to watch.** Starting from the most
cloned concept in games means distinctiveness arrives later or not at all —
usually not at all, because by then the codebase is shaped like the thing it
copied. The defusal is cheap and must happen now rather than later: **the
divergence target is §1's thesis** — land as a platform, income from footfall
rather than acreage. A voxel world whose economics natively reward making a
place worth visiting is a real combination nobody has shipped; every Minecraft
server economy is bolted on through plugins. Treat the Minecraft-like phase as
scaffolding with a scheduled demolition date, and write that date down.

## D3. Gene on both sides

**Backend:** Gene on the VM.

**Frontend:** Gene compiled to TypeScript through the **`web` profile** in
`docs/proposals/transpile.md`, which is implemented through P5 with a 57-case
conformance suite gated against the VM. Markup and CSS come from Tier 0
(`gene/html`, `gene/css`) as node data with real printers.

So the claim is *one language, both sides* — demonstrated rather than asserted.

**Not the wasm VM, and this is a deliberate departure.** `transpile.md` §2 gives
a rule of thumb that sends canvas apps to the wasm VM for fidelity. That rule
weighs total semantic fidelity against payload, and it assumes a wasm host
bridge that does not exist:

- `src/gene_wasm.nim` is `gene_eval(text) → text` plus alloc/free and result
  accessors. There are **no host calls**, so Gene in the page cannot reach a
  canvas at all.
- `newGlobalScope()` runs on **every** eval, so no state survives between calls
  — there is no game loop to hold.
- Every frame would re-parse and re-compile source text.
- 4.4 MB payload, opaque values in devtools, no breakpoints in Gene.

Choosing wasm means building a host-call bridge, persistent VM state, and a
canvas binding before drawing a single pixel. And the fidelity that would
justify that cost buys fexprs, `eval`, actors, and FFI — **none of which a game
client needs**. The argument for the wasm path is exactly the argument that does
not apply here. Transpiling gives direct canvas access with no per-call boundary
crossing, payload proportional to the code, real stack frames and source maps,
and npm interop. For a 60 fps loop, devtools alone probably decides it.

## D4. The hazard that decides the idiom

`transpile.md` §4.5's implemented decision is **`Int` → `bigint`, `F64` →
`number`**. That is right for data and validation code and it is aimed straight
at a game's hot path: bigint arithmetic is roughly an order of magnitude slower,
it throws when mixed with `number`, it does not survive `JSON.stringify`, and
every canvas call takes a `number`, so each coordinate crossing the boundary
needs a coercion.

**Mitigation, adopted on day one rather than retrofitted: all hot-path math is
`F64`.** Positions, velocities, camera, and physics are float math anyway. Block
and chunk indices are the awkward case and the ones that hurt at volume.

This is not a reason to abandon the path. It is the reason not to design a game
before measuring it.

## D5. First milestone — the spike

Before any game design, answer the one question that invalidates everything
downstream.

**Roughly 200 lines of Gene, transpiled to TypeScript, animating 10,000 moving
sprites on a canvas at 60 fps.** Canvas externs, a `requestAnimationFrame` loop,
`F64` math, no game design at all.

- **Passes when** the frame budget holds at 10k sprites and no bigint appears on
  the hot path in a profile.
- **Fails usefully when** it does not — the failure names either the numeric
  idiom or the interop shape, and both are worth knowing in days rather than
  months.

Canvas is the only genuinely missing piece: the generated DOM subset in
`web/gene_dom_bindings.json` is document-shaped (`create_element`,
`append_child`, `set_attribute`, `add_event_listener`) with no canvas and no
`requestAnimationFrame`. Tier 2's mechanism for that is declared JS externs with
checked interop, already in the tree and deliberately proven early — so this is
extern declarations, not compiler work.

The spike is a contribution regardless of outcome: canvas externs and a measured
perf baseline are things the web profile wants anyway.

### D5.1 Result — **PASS**

Built in `examples/new_world/spike/`, its own nested package: `src/sprites.gene`
(the sim), `canvas.mjs`
(externs), `bench.mjs` (node harness with a hand-written JS baseline),
`index.html` (browser). Node v25.9.0, 600 frames, structure-of-arrays, all `F64`.

| | ms/frame | fps | 60 fps budget |
|---|---:|---:|---:|
| hand-written JS | 0.017 | 59,165 | 0.1% |
| Gene, loop only (one boundary call) | 0.659 | 1,517 | 4.0% |
| Gene, `advance` per frame | 0.749 | 1,336 | **4.5%** |

**10,000 sprites cost 4.5% of a frame.** Headroom is ~220,000 sprites at 60 fps,
and scaling is linear (1k → 0.077 ms, 10k → 0.76, 50k → 3.93, 200k → 15.4).

Both stated criteria hold:

- **No bigint on the hot path.** Zero occurrences of `BigInt` or a bigint
  literal in the emitted sim. `F64` discipline (D4) is sufficient and is now a
  demonstrated idiom rather than a hope.
- **The frame budget holds**, with roughly 20× more room than a 2D game needs.

Two numbers to keep in view. Gene is **39–44× slower than hand-written JS** on
this loop — irrelevant at this workload, but it is the multiplier that decides
where the ceiling actually is, and §D5.2 says why it is that large. And the
exported boundary costs **0.09 ms/frame** for four 10k arrays, because it
revalidates every element on every call.

The harness checksums both sims and asserts they agree, so the timings compare
two programs that provably compute the same thing rather than two that merely
look alike.

### D5.2 What the spike found

This is the awkwardness log D1 asked for, and it is the spike's real output.

**A miscompilation, found and fixed.** `if`, `while`, and `!` lowered their
condition through a truthiness helper that interpolates its operand **twice**,
so `(if (f) …)` and `(while (f) …)` called `f` twice per test. `&&` and `||`
were already correct — they bind a temp first — so the fix was to give the other
three the same treatment (`src/gene/web.nim`). Two regression fixtures were
added to `tests/transpile/fixtures.json` and verified to fail against the
unfixed compiler; all five transpile suites pass. The 57-case conformance suite
had no case for a side-effecting condition, which is why this survived. For a
game it is exactly the bug that matters most: an input-polling loop would have
dropped every other event.

**The 40× had a named cause, and the read half is now fixed.** Field access
emitted `$gene_get(s, "x")` — a six-branch generic helper — *even when the
receiver's static type was a declared web `type` and the key was a literal field
name*. `directRead` in `src/gene/web.nim` now emits the property read directly
when the analysis has proved the hop, so V8 sees a monomorphic access instead of
a megamorphic call:

| | before | after |
|---|---|---|
| `s/x` on a declared type | `$gene_get(s, "x")` | `s.x` |
| `xs/%i`, `i : F64` | `$gene_get(xs, i)` | `xs[i]` |
| `xs/%i`, `i : Int` | `$gene_get(xs, i)` | `xs[Number(i)]` |
| `xs/0` | `$gene_get(xs, "0")` | `xs[0]` |

Every guard inside the helper is provably dead for those shapes: a generated
class carries no `$gene_node` so it is never a node, `T?` is a union rather than
a nominal so a nominal is never nil, the constructor's `Object.assign` stores
field names unmangled so the snake→camel fallback cannot fire, and a plain array
carries no `$gene_body`. Only a **single** hop qualifies — `analyzeExpr` types a
one-segment path and falls back to `Any` beyond that, so a longer path has no
proven intermediate type. Numeric keys on a nominal are excluded because those
mean body slots rather than properties.

**Measured effect on the spike: 0.749 → 0.559 ms/frame (−25%), 42× → 32× versus
hand-written JS, headroom 223k → 298k sprites.** Checksums still agree and all
five transpile suites, `nimble test`, and `nimble spec` pass.

**The write half is deliberately left alone, and this is the next optimization.**
`$gene_set` is not symmetric with `$gene_get`: it re-runs `$gene_validate()`
with rollback on failure, and every generated class always has a validator — so
a class field write can never become `s.x = v` without dropping validation. The
list case *is* reducible (a plain array has no validator), but only under three
conditions: a numeric index, an element type that makes `next === undefined`
impossible, and a frozen-array check, since `#[]` literals are `Object.freeze`d
and the helper raises a specific "cannot mutate a frozen value" error that a
bare assignment would replace with V8's own message. Preserving that needs the
base, index, and value bound to temps first — which is precisely the
double-evaluation trap fixed above, so it wants doing carefully rather than
quickly. Writes are now the dominant remaining cost in the loop.

**The exported boundary is O(n) per call.** `$gene_check_list_f64` iterates
every element on every exported call. Passing four 10k arrays across it each
frame costs 0.09 ms. Keeping hot state behind one entry point avoids it; the
profile offers no way to mark a boundary already-validated.

**Profile restrictions a game runs into immediately:**

- **Top-level `var` is rejected**, so a module holds no mutable state. Game
  state must be threaded through parameters or owned by JS. This is the
  restriction most likely to shape the architecture.
- **`List` has no `push`, `at`, or `len`** in the profile — only `size`, which
  returns a bigint. Collections must be built and sized outside Gene.
- **`set` yields the assigned value**, so a write in tail position needed
  `(var ignored (set …))` and every `: Void` body ended in a bookkeeping
  `void`. **Fixed** — `docs/design.md` §7.7 makes `Nil` and `Void` *statement*
  signatures on both backends: the body's trailing value is discarded, the
  frame yields the declared unit, and `(return)` needs no argument. `src/world.gene`
  lost eight trailing `void`s and the `poke` helper's throwaway binding; the
  spike lost four more. This is the awkwardness log working as intended — a
  friction the game hit repeatedly became a language change rather than a
  convention everyone copies.
- **An empty list literal needs an expected type** (`(var a : (List S) [])`).

**There was no math library.** `floor`, `ceil`, `sqrt`, `sin`, `cos`, `abs`,
`round`, and `pow` were absent from the stdlib entirely, on both backends —
which is why `world.gene` declared `floor`, `abs`, and `sin` as *JavaScript
externs*: not because a game wants them from the host, but because Gene could
not supply them. **Fixed** — `docs/design.md` §7.8 adds `gene/math` on the VM
and the web profile, lowering to `Math.*` in the browser with guards only where
the VM raises, and `tests/transpile/fixtures.json` pins the two backends
together. The game dropped three of its seven `js/fn` declarations and its
hand-rolled `clamp`; only the four canvas externs remain, which are the real
boundary. The screenshot is byte-identical across the change.

Adding it also surfaced a gap in the conformance harness: the web runner
rendered a whole `F64` as `"4"` where the VM prints `"4.0"`, so *any* integral
float result would have looked like a backend divergence. Fixed in
`tests/transpile_web_runner.nim` — a rendering artifact that would have masked
the real divergences the suite exists to catch.

**Binary output was out of reach**, which is what pinned the two PNG tools in
JavaScript. **Fixed** — `docs/design.md` §7.9 adds `gene/bit` (bitwise ops over
Int, with a *logical* `shr` so a checksum's high byte survives), `gene/binary`
(Bytes built from a List of Int, plus size/get/concat/slice/from_str/to_str),
and `fs/write_bytes`. `src/png.gene` is the proof: CRC32, Adler-32, a zlib
stream, and PNG chunk layout, all in Gene, producing a file whose every CRC
validates and whose stream decompresses.

Writing it turned up four Gene gotchas worth knowing, none of them documented
where a newcomer would look:

- **`0x…` is a `Bytes` literal, not a hex Int** (§7.5). `0xFFFFFFFF` as a mask
  silently becomes a four-byte value; the constants have to be decimal.
- **`%` is the unquote prefix, so the remainder operator is `//`** (§2.1).
  `(% a b)` fails with "undefined symbol: unquote".
- **`while` shares one scope across iterations** on the VM, unlike `for`, so a
  `var` in the body is a duplicate binding on the second pass. Loop temporaries
  must be hoisted and assigned.
- **An empty `[]` has no element type to infer**, so an accumulator passed to a
  `(List Int)` parameter needs `(var acc : (List Int) [])`.

**A syntax trap worth a diagnostic.** `xs/i` is a *static* path — the member
named `"i"` — and lowers to `$gene_get(xs, "i")`, which returns `undefined` at
runtime with no compile-time complaint. The dynamic index is `xs/%i`. The
profile knows `xs : (List F64)` has no member `i` and could say so.

**One ergonomic bug.** A `js/fn` `^from` path is emitted verbatim, so it
resolves relative to the *output* directory rather than the source file;
`canvas.mjs` has to be copied into `dist/` for the module to load. The path
should be rewritten relative to `--out-dir`.

## D5.3 The game — first playable slice

`examples/new_world/`, alongside this doc — see the [README](../README.md) to
build and run it. It is a Gene package (`gene/new_world`), so all Gene source
lives under `src/`. Side-view, per D2. `gene run build` runs the whole
pipeline: assets, then `gene build --target web`, then the page. It is a
declared application target rather than a shell script, and it asks for the
two authorities it needs — a write directory and process execution — instead
of inheriting ambient access to either.

**In Gene**, through two different paths:

- `src/world.gene` and `src/shell.gene` compile to TypeScript/ESM through the
  **`web` profile**: value-noise terrain with three octaves, biome layering, caves,
  depth-banded ores, trees, AABB collision with sub-stepping, walking and
  jumping, mining and placing with a reach check, and the visible-window render
  walk.
- `src/page.gene` runs on the **VM at build time** and emits `index.html` —
  `gene/css` for the stylesheet and `gene/html` for the markup, both ordinary
  node data until one `render` edge. This is Tier 0 of `transpile.md`: no
  compiler backend involved, just the stdlib. Being a normal module rather than
  a profile one, it can hold top-level `var`, which is how the palette lives in
  named bindings instead of being repeated as hex literals.

**In JavaScript**: only what the profile cannot reach — the canvas boundary
(`js/fn` binds to a real JS module, and the generated DOM subset has no canvas)
and the DOM wiring that owns the keyboard, `localStorage`, and the frame
callback. Camera, spawn, save encoding, and the hotbar started in JavaScript
and moved to `src/shell.gene` once it was clear none of them had a reason not
to be Gene; the save *format* is now decided in Gene rather than in the shell
that stores it. `src/world.gene` holds no state at all,
because the profile rejects top-level `var` — the world is a flat `(List F64)`
the host owns and hands back each frame.

So the split is not "Gene for logic, HTML by hand". Markup, styling, and
simulation are all Gene; JavaScript is the host boundary and nothing else.
`index.html` and `dist/` are build outputs and are gitignored.

| | |
|---|---|
| world | 512 × 192 = 98,304 tiles, generated in **14 ms** |
| composition | 46.5% stone, 48.1% air, ores 0.7 / 0.5 / 0.1% coal / iron / gold |
| checks | 41/41 in `tools/test.mjs` — headless, no browser |

`tools/test.mjs` asserts the properties that actually matter rather than pixel output:
generation is deterministic for a seed (or a save that stores only a seed is
worthless), the surface never steps more than 3 tiles (or the world is
unwalkable however good it looks), ore rarity is ordered, the player lands and
comes to rest without drifting, a jump leaves the ground and returns, and you
cannot mine out of reach or seal yourself inside a wall.

**Assets are generated, not drawn.** `src/atlas.gene` writes
`assets/tiles.png` from a named palette and a seeded hash, through the
`src/png.gene` encoder — so the palette D2 calls the visual identity is
re-tunable by editing numbers rather than by repainting a file nobody has the
source for. `src/preview.gene` emits an 8× review blow-up, and
`src/screenshot.gene` composites a real viewport to PNG through the same atlas
and the same `src/world.gene`, so the world can be reviewed and regressions
caught from a terminal with no browser running.

All three were JavaScript until the §D5.2 blockers were fixed. Porting them
kept every committed asset byte-for-byte: the atlas hash depends on JavaScript
`Number` semantics — a constant that does not survive as a float64, and a sum
whose left-to-right association decides a tenth of the pixels — so the Gene
version reproduces the float64 arithmetic deliberately rather than computing
the "same" hash in exact integers.

Three things that review caught, in order of how much they mattered:

- **Caves showed the sky through them.** Air draws nothing, so every cavern read
  as a hole punched in the world. Sub-surface air now gets a backdrop that
  darkens with depth — the single biggest visual fix, and invisible in any test
  that checks tile ids.
- **Stone tiled visibly**, one 16px stamp repeated across a whole cliff. The
  renderer now picks among three stone stamps and two dirt stamps by position
  hash, while the *stored* id stays `t_stone` so mining and inventory stay
  simple. Gameplay id and drawn id are deliberately different things.
- **Inserting those variants mid-array renumbered `plank`**, so stone rendered
  as dirt. The atlas order is load-bearing and is now pinned by a comment at
  both ends.

Not yet built: crafting, mobs, day/night, water flow, multiplayer, and every
part of §4. The next real question is D2's — whether this is fun for twenty
minutes — and it is now answerable by playing it.

## D6. What this changes in Part II

- **§5.5 leaves the critical path.** `max_memory_mb` and `timeout_ms` existed to
  contain hostile *player* code. Player scripting is deferred, and admins are
  trusted principals, so the largest blocker in Part II is no longer blocking
  anything.
- **§9 shrinks to an admin REPL.** Admin work is inherently ad hoc — "find every
  parcel affected by that bug and refund them" is not a screen anyone can design
  in advance — so a REPL is the correct shape for it rather than a compromise
  that saves building an admin UI. The cost is that it is a total-authority eval
  endpoint, which makes §10's per-parcel rollback *more* important, not less:
  the most likely destructive actor becomes an admin with a typo. It needs
  strong authentication and every evaluation journalled.
- **§8's GUI-parity machinery survives in reduced form.** With no player REPL
  there is no second surface to keep parity with, so the `^ui` startup check
  collapses to a simpler rule: an operation is either player-facing and needs an
  affordance, or admin-only and marked so. The echo (§8.3) and the
  clicking-to-authoring ladder (§8.4) go with player scripting.
- **§4's economy is deferred entirely**, and §1's thesis is preserved as the
  divergence target named in D2.
- **§14 is retired as a goal.** Kept for the record.

---

# Part II — the deferred killer-app design

Inherits the worker model, operation-table contract, event journal, checkpoint
persistence, and core/surface/gateway split from
`examples/ai_agent/docs/design.md`.

---

## 0. What this is

**A live 2D world that players buy, build, and program — where the way to get
rich is to make a place other people want to be.**

You arrive with starter resources next to whoever invited you. You buy a
parcel. You build on it: place tiles visually, then give them behavior by
writing Gene. Other players walk through in real time, and when they build on
*your* land you take a cut of what their build earns. Income comes from
footfall, not from acreage — so hoarding empty land earns nothing, and the most
valuable land is the busiest district, not the biggest estate.

The programmable part is not a side feature. Every build can carry code, that
code runs when strangers walk into it, and it is safe to run because the
sandbox is a property of the language rather than a bespoke VM someone had to
write.

It is also not a *requirement*. You can play the entire game with a mouse —
every operation in the world has a button (§8.1), and most builds never carry a
line of code. The REPL is the advanced player's instrument: it grants no
authority the buttons do not, only composition, and the GUI teaches it by
showing you the call each of your clicks just made (§8.3). The reward for
learning to program here is the same reward everyone else is chasing — you get
better at making a place people want to walk into.

---

## 1. The design thesis

One idea decides everything else:

> **Land is a platform, not a fence.**

The conventional land game rewards enclosure: buy, fence, hold, sell to the
next buyer. It produces empty maps owned by speculators.

New World inverts the incentive with one rule — **you earn when other people
build on your land, and you earn from visitors, not from ownership**. The
consequences cascade:

- A landlord's interest is to *let people in*, set a low build fee, and make
  their parcel worth visiting. Fencing your land is how you go broke.
- The best neighborhoods are collaborative by construction, because a district
  gets valuable only when many people build in it.
- Inviting people pays, but only indirectly: they spawn next to you and build
  out your district, which raises the value of the land you already hold. You
  never collect dividend from someone you invited (§4.6), so an invite is a bet
  on your neighborhood rather than a way to farm yourself.
- Speculation self-defeats. An empty parcel produces no footfall, so it pays
  nothing every period it is held, while its resale price is set by a district
  number the holder is not contributing to.

Everything below is in service of that rule. Any feature that does not
strengthen it was cut.

---

## 2. The world

### 2.1 Shape

A single shared 2D tile world. One coordinate space, no instances, no shards,
no private copies.

```text
tile     1×1  the unit of building — floor, wall, prop, or empty
parcel   16×16 tiles  the unit of ownership and trade
district 8×8 parcels  the unit of pricing and discovery (emergent, not owned)
```

Parcels are bought. Tiles are built. Districts are named by whoever develops
them first and exist only for pricing, search, and the map view.

### 2.2 Avatars and presence

Every player has a persistent avatar with a position in the world. You see
other avatars move in real time when they are near you. Guests get **ghost
avatars** — visible, walking, unable to touch anything. A busy district looks
busy, which is the point: footfall is the economy, so footfall has to be
visible.

Movement is server-authoritative: the client sends intent, the server validates
it against collision and parcel access, and broadcasts the result. There is no
combat, no physics, and no twitch action anywhere in this design (§12).

**The collision model**, since builds are programmable and collision is
therefore a game mechanic rather than a rendering detail:

- An avatar is a point occupying exactly one tile.
- Avatars do not collide with each other — any number may stand on a tile, so a
  crowd is possible and nobody can block a doorway.
- Builds may be **solid** (impassable) or **floor** (walk-on). Only a floor tile
  can carry `on_enter`, which is what makes "walking into a shop" a well-defined
  event rather than an ambiguity about whether you are inside it.
- Parcel access is checked at the boundary: a closed parcel is impassable to
  everyone but its owner.

### 2.3 The frontier

Unclaimed parcels adjacent to developed ones are on the **frontier** and can be
bought from the system. Parcels far from any development cannot — the world
grows outward from what exists rather than sprouting disconnected islands. This
is what makes the map one place instead of a scatter plot.

---

## 3. Three levels of user

Roles are **capability sets**, not new `^audience` values. Per
`examples/ai_agent/docs/design.md` lines 1561-1570, audience is the caller
class — which channel a call arrived on — and authorization is
`audience ∩ capabilities`. A role is what the server assigns to a principal at
authentication.

| capability | guest | player | admin |
|---|:-:|:-:|:-:|
| `world.view` — see the map, avatars, and builds | ✓ | ✓ | ✓ |
| `world.walk` — move a (ghost) avatar | ✓ | ✓ | ✓ |
| `world.read_source` — read any build's code | ✓ | ✓ | ✓ |
| `repl.eval_pure` — evaluate expressions over a read-only snapshot | ✓ | ✓ | ✓ |
| `land.buy` / `land.sell` | | ✓ | ✓ |
| `build.place` — build on own or permitted land | | ✓ | ✓ |
| `build.script` — attach Gene behavior to a build | | ✓ | ✓ |
| `repl.eval_session` — a persistent REPL that may call operations (§9) | | ✓ | ✓ |
| `script.own` — save, publish, and mount scripts (§9.5) | | ✓ | ✓ |
| `econ.trade` — market, transfers, royalty settings | | ✓ | ✓ |
| `npc.own` — place and fund an AI NPC | | ✓ | ✓ |
| `invite.send` | | ✓ | ✓ |
| `admin.revoke` — remove a build, parcel, or NPC | | | ✓ |
| `admin.rollback` — restore a parcel to an earlier version | | | ✓ |
| `admin.freeze` — suspend a principal | | | ✓ |
| `admin.grant` — change a role, adjust grants | | | ✓ |

Enforcement lives in the operation declaration, never in the client. A guest
who opens a WebSocket by hand and sends `build.place` is refused by the same
check that greys out the button.

The table is deliberately flat: **there is no capability a programmer holds and
a clicker does not.** `repl.eval_session` is the right to *compose* the
operations a player already has, never to reach past them (§9.2), and it is why
§8.1 makes GUI coverage a startup check rather than an intention.

**A guest's REPL is a real REPL** — it evaluates pure expressions against an
immutable world snapshot with no capabilities. Guests can read every build's
source, query the map, and compute over it. That is the on-ramp: a guest is
already writing Gene against the real world before they have an account, and
the way they get an account is to ask a player for an invite — which pays that
player (§4.4).

It is also, stated plainly, **an unauthenticated remote `eval` endpoint on the
game server**, and it must be built as one:

- a fresh `Env` per submission, no stateful bindings carried between them, so
  one guest cannot leave anything behind for the next;
- a step budget an order of magnitude below a player's;
- per-connection and per-IP rate limiting on submissions;
- the §5.5 prerequisite applies here **first**, not last. Until `EvalPolicy`
  bounds memory and wall-clock time, an anonymous visitor can allocate until
  the server dies, and a step budget does not stop it. Ship the guest REPL
  behind an account until those land, or ship it against a whitelisted query
  surface rather than general evaluation.

The on-ramp is worth building. It is not worth building before the sandbox can
hold an anonymous adversary.

---

## 4. The economy

Two currencies, each with one job.

- **Matter** — consumed by building. Comes from system drops and from the
  market. Cannot be converted back to Coin except by selling it to a player.
- **Coin** — buys land, buys Matter, funds NPCs, receives royalties.

### 4.1 The faucet is footfall, and it is a fixed pool

**Coin enters the world in exactly one way**, and the mechanism is a fixed pool
rather than a per-visitor rate:

> Each settlement period the system mints a **fixed amount of Coin** and
> divides it among parcel owners by their **share of that period's total
> dividend-eligible footfall** — never by land held.

The fixed pool is what makes the economy closed. Total Coin in circulation is
bounded by `pool_rate × periods − sinks` no matter how many players join, so a
growing player base cannot inflate the currency. A per-visitor rate would have
been more intuitive and would have made supply track the population, which is
precisely the runaway nobody notices until it is a year old.

It also has a second effect worth having: because the pool is fixed, your
dividend depends on your **share** of world footfall. Districts compete for
visitors rather than farming them in isolation, which is the thesis again at
the level of the whole map.

The only other Coin faucet is the one-time **starter grant** — enough for one
small parcel and a first build. Invitations grant Matter, never Coin (§4.4).

### 4.2 Sinks

| Sink | Burns | Why it exists |
|---|---|---|
| Buying an unclaimed parcel from the system | Coin | Primary Coin sink; prices the frontier |
| Placing a tile or prop | Matter | Primary Matter sink |
| NPC upkeep (§6) | Coin | Backed by real model-inference cost |
| Market fee on player-to-player trades | Coin | Small; damps churn |

Player-to-player payments (build fees, royalties, market trades) move Coin
without minting or burning it. The system only mints from footfall and only
burns through the table above.

### 4.3 Royalties: the rule that makes land social

An owner sets two numbers on each parcel:

```gene
(type ParcelTerms ^props
  {^open Bool          # may others build here at all
   ^build_fee Int      # Coin, paid once when a build is placed
   ^royalty Int})      # percent of that build's footfall dividend, capped
```

When another player builds on your parcel they pay `build_fee` up front, and
thereafter you take `royalty` percent of the footfall dividend that *their*
build generates. They keep the rest.

Both sides now want the same thing — more visitors — and neither can get it
alone. A landlord with a 90% royalty and a high fee gets no tenants; one with
generous terms and a well-placed parcel gets a district.

### 4.4 Invitations

Signup is **invitation-only**. An invite costs the inviter nothing but is
rate-limited per period.

- Both inviter and invitee receive a one-time **Matter** grant — never Coin.
- The invitee **spawns adjacent to the inviter's holdings** if the frontier
  there has room, otherwise at the nearest available frontier parcel to them.

**Why the grant is Matter and not Coin.** A Coin grant on invite would be a
second faucet running parallel to §4.1 and governed by the invite rate rather
than by any economic activity: invite, collect, repeat, and the invite chain
prints money that later players' land purchases ultimately fund. Matter is a
*build* input — it converts to Coin only by building something someone visits,
or by selling it to a player who will. So the grant still gives a newcomer a
real head start, and it still rewards the inviter, but both have to pass through
footfall to become income. The faucet stays singular.

Clustering is the rest of the reward, and it is the larger one. Friend groups
build neighborhoods, neighborhoods generate footfall, footfall raises district
land prices, and the founders hold the land whose value they created.

Invitation-only signup is also the anti-abuse backbone (§4.6).

### 4.5 Drops

The system scatters Matter nodes across the world each period. Anyone with
`world.walk` may collect them, including on land they do not own — guests
included, since Matter is the thing you need before you can build and collecting
it is how a guest earns their way toward wanting an account.

Drops are a **fixed pool per period**, distributed by the same measure that
pays dividends: a parcel's share of **dividend-eligible footfall** (§4.6). One
measure drives both, which is deliberate. Weighting drops by raw presence would
have made guests worth farming for Matter even though they are worth nothing for
Coin, re-opening through the drop channel exactly the hole rule 1 closes on the
dividend channel.

A fixed pool also bounds Matter supply the way §4.1 bounds Coin, so builds stay
scarce enough to be worth making.

Drops still follow people. That gives landowners a second reason to want
visitors, gives visitors a reason to explore busy districts, and gives new
players a way to earn Matter before they own anything.

### 4.6 Anti-abuse

The obvious attack is alt accounts farming footfall for their owner. Five rules
close it without any heuristics:

1. **Guests generate no dividend.** They are audience, not income. This removes
   the zero-cost farm entirely, and §4.5 extends the same measure to drops so it
   cannot be re-opened through the Matter channel.
2. **Every account costs a real invite** from a real player, and invites are
   rate-limited.
3. **A visitor only generates dividend once they have built something.** Skin in
   the game — and it doubles as the tutorial's completion condition.
4. **Per-visitor contribution to any one owner is capped per period.** Your
   best friend visiting all day is worth one good visit.
5. **You never earn dividend from an account you invited.** Their visits pay
   everyone else, never you.

Rule 5 is the one that actually kills alt farming, and rules 1-4 alone do not.
Without it the loop is: spend an invite, have the alt place one cheap tile to
satisfy rule 3, walk it onto your own land, and collect up to the cap — a
guaranteed return bounded only by the invite rate. Rule 5 severs the path from
an invite back to the inviter's own dividend, so the only way an invitee makes
you money is indirectly: by building near you, raising your district's value,
and paying your build fees out of Coin they had to earn from *other people's*
footfall.

That is also why the invitation grant is Matter (§4.4). With rule 5 in place and
no Coin grant, an alt account has no path to its creator's balance at all.

**Rule 4 is a calibrated parameter, not a proof.** Set it too high and marginal
farming is profitable anyway; set it too low and a visitor who builds something
genuinely popular on your land is worth the same as one who walked past. It is
listed with the other tuning parameters in §4.8, and it is the one that most
needs real play to settle.

### 4.7 Land pricing and reclamation

The system prices an unclaimed frontier parcel from the recent footfall of its
surrounding district. Central land is expensive; frontier land is cheap. No
oracle, no auction house, no valuation model — the same number that pays
dividends sets the price.

A parcel with **no builds and no footfall for `idle_periods`** returns to the
market, refunding a fraction of its purchase price.

Be clear about what this does and does not do. It reclaims land whose owner has
*stopped playing*. It does not stop a speculator who logs in once a period to
place a tile and walk on it — that bypass is trivial and no reclamation rule
can close it. Speculation is defeated economically rather than procedurally:
under §4.1 a parcel held for resale earns nothing while it is held, and its
resale value is set by a district footfall number the speculator is not
contributing to. Reclamation is a groundskeeping rule, not the anti-hoarding
mechanism. There is no land tax, because the fixed pool already makes idle land
a losing position.

---

### 4.8 The economy is a shape until these numbers exist

Everything above fixes the *structure* — one Coin faucet, one Matter faucet,
both fixed pools, four named sinks, transfers that neither mint nor burn. That
structure is closed by construction: no growth in the player base can inflate
either currency.

It is not yet *stable*, because stability is a property of the numbers, and
these are unset:

| Parameter | What it decides | Starting position |
|---|---|---|
| `coin_pool_per_period` | Absolute Coin supply; every price is relative to it | Set so a median active parcel earns one small parcel's price per week |
| `matter_pool_per_period` | Build volume across the world | Set so the world's tile count grows a few percent per period |
| `visitor_cap` | Whether marginal alt farming pays (§4.6 rule 4) | Low — one good visit, not a day's loitering |
| `invite_rate` | Population growth and the alt supply | 2-3 per player per period at launch |
| `invite_matter_grant` | New-player head start | One modest build |
| `starter_grant` | Time-to-first-parcel | One frontier parcel plus one build |
| `royalty_cap` | Ceiling on landlord extraction (§4.3) | 50%, so a tenant always keeps the majority |
| `idle_periods` | How long abandoned land sits (§4.7) | Weeks, not days — forgiving |
| `base_parcel_price` | The floor under frontier land | One period of median dividend |

Two of these are load-bearing rather than cosmetic. `visitor_cap` decides
whether §4.6 holds at the margin. `coin_pool_per_period` versus
`base_parcel_price` decides whether a new player can ever buy in — if the pool
is thin and prices are footfall-driven, early districts become permanently
unaffordable and the map stops growing.

**These are Phase 5 work and they need real play to settle.** The honest
statement is that the economy is closed but uncalibrated, and no amount of
desk analysis substitutes for watching a hundred people try to break it. What
the structure buys is that miscalibration is *recoverable* — the pools are
dials, not architecture.

---

## 5. Building

### 5.1 Two layers, one artifact

**Visual layer.** Place tiles and props from a fixed palette, in a browser, by
clicking. Costs Matter. This is how everyone starts, and most builds never go
further.

**Behavior layer.** Attach Gene code to a build. This is what makes a place do
something instead of just look like something. Most players reach it through a
configured template rather than an empty editor — §8.4 is the ladder between the
two, and it matters that the template's form fields are a view of its source
rather than a substitute for it.

```gene
(type Build ^props
  {^id Str ^parcel Parcel ^footprint [Tile]
   ^author Str
   ^behavior Behavior?
   ^version Int})

(type Behavior ^props
  {^on_enter Node?      # visitor -> [Effect]     someone steps on it
   ^on_interact Node?   # visitor, verb -> [Effect]
   ^on_tick Node?})     # -> [Effect]     rate-limited, opt-in, costs Matter
```

No uploaded assets — no image files, no audio. A fixed palette removes an asset
pipeline, an asset moderation problem, and the "my browser downloaded 400 MB of
someone's textures" failure mode in one decision.

The consequence is worth stating up front: **the palette is the product's visual
identity, and it is effectively unchangeable after launch**, because every build
in the world is composed of it and a changed tile silently redecorates work that
belongs to someone else. It is the highest-leverage aesthetic decision in the
design and the one with the least room for iteration — it wants a real artist
before Phase 4, not a placeholder that becomes load-bearing.

### 5.2 The sandbox

Behavior code runs in an `Env` carrying **only**:

- the visiting player's public projection (display name, id — never their
  session or balances);
- a curated read-only world surface;
- constructors for the effects it may propose;
- an `EvalPolicy` with a step budget.

It carries **no capability values**, so per `docs/design.md:3198` the code has
no ambient filesystem, network, subprocess, or FFI authority. `allow_ffi` and
`allow_native_compile` cannot be enabled from a policy at all.

```gene
(var build_env
  (env ^bindings {^visitor (public_projection visitor)
                  ^here (build_view build)
                  ^say say ^show show ^give give ^charge charge ^move move}
       ^policy (EvalPolicy ^max_steps build_step_budget)))
```

### 5.3 Behavior proposes, the world disposes

Behavior code never mutates anything. It **returns effects**, which the world
validates against the visitor's capabilities, the build's authority, and the
owner's balances before applying any of them.

An effect a build is not entitled to produce — moving a visitor across the
world, granting Coin it has not got, writing another parcel — is dropped and
journalled as a rejection. **A hostile build cannot corrupt the world; it can
only propose garbage and be refused.** That is what makes it safe to walk into
a stranger's shop.

`charge` is the one effect that moves value, and it is always confirmed by the
visitor's client, never silent.

### 5.4 Source is public

Anyone, including guests, can read any build's code. This is both the culture
(you learn by reading the shop you just walked into) and a safety mechanism
(a griefing build is visible before it is reported).

### 5.5 The prerequisite this is blocked on

`env ^policy ^max_steps` is implemented and enforced (`vm.nim:3821-3831`, spec
at `spec_runner.nim:6671-6689`). **`^max_memory_mb` and `^timeout_ms` are not**
— both are currently rejected as "not supported yet" (`vm.nim:3804-3808`).

A step budget does not bound memory: one step can allocate a large structure,
so hostile behavior code can exhaust process memory while staying far under its
step count. In a shared real-time world that is a denial of service against
every player, not just its author.

**Memory and wall-clock limits on `EvalPolicy` are a prerequisite for §5.2 and
§3's guest REPL, not a detail of either.**

They are also not a small feature, and the design should not pretend otherwise.
Bounding memory in a GC'd runtime means either an allocation-time budget check
(which puts a branch on the hottest path in a repository that treats allocation
behavior as a core requirement), a counting allocator integrated with the GC, or
an out-of-process evaluator that gives up most of what makes this design
interesting. Whichever is chosen needs its own proposal and its own benchmark
evidence — this document should be read as stating the requirement, not as
having solved it.

Until they land, the fallback is real but costly: Phase 6 ships behavior as a
closed expression language over the effect constructors rather than general
Gene. That is a working game. It is not the thing §14 claims, and the difference
should be visible in the roadmap rather than glossed. The same gate applies to
the full player REPL (§9.7), which is authenticated general evaluation on the
same shared server — so §5.5 blocks both of the features this design is
distinguished by, not one.

---

## 6. AI NPCs are property

An NPC is not a system feature. It is something a player **owns, places,
funds, and profits from**.

```gene
(type Npc ^props
  {^id Str ^parcel Parcel ^owner Str
   ^name Str ^persona Str          # the model's brief
   ^behavior Behavior?             # sandboxed, same rules as a build
   ^budget Int                     # Coin, each model call debits it
   ^spend_cap Int                  # per period, owner-set
   ^inventory [Item]
   ^dormant Bool})
```

- The NPC talks to visitors using a model. **Each call debits the owner's
  budget**, and when the budget hits zero the NPC goes dormant until refunded.
- **Inference runs server-side.** The browser is a renderer (§8) and the WASM
  build has no model transport, so the gateway owns the model connection and
  the NPC's Gene behavior runs beside it. This also puts the metering where the
  money is: the server debits the budget because the server pays the bill.
- The NPC can hold inventory and trade, act as a guide, run a shop, or give out
  quests its owner wrote.
- Its Gene behavior runs in the same sandbox as any build (§5.2), so an NPC can
  be *scripted* around the model instead of being pure prompt.

This solves the problem that kills most AI-game designs — who pays for
inference — by making it a game resource. The owner pays, in Coin they earned
from footfall, and the NPC's job is to increase footfall. A good NPC pays for
itself; a bad one quietly goes dormant. No moderation policy needed to stop AI
spam: it is expensive by construction.

All NPC dialogue is journalled, because moderation needs it.

**Later: an autonomous agent as a player.** The full agent from
`examples/ai_agent` can hold a `player` account — it authenticates, buys land
under the same prices, builds under the same sandbox, and is revocable and
rollback-able by the same admin operations. That is the right way to add AI
authorship: not as an engine, as a citizen.

---

## 7. Real-time architecture

**What is real-time:** avatar movement, chat, drops appearing, builds appearing,
NPC speech.

**What is not:** every transaction. Buying land, placing a build, trading, and
settling dividends are transactional operations through the world actor, not
tick state.

That split maps cleanly onto two delivery paths, and the existing server already
has the right semantics for both:

| Path | Carries | Delivery |
|---|---|---|
| Broadcast | positions, presence, ambient events | WebSocket, ~10 Hz, **lossy** |
| Transaction | buy, build, trade, script, admin | request/response, **reliable, journalled** |

`ws_send` already drops oldest frames on a full per-connection queue and reports
the drop count (`http_server.nim:27, 965-970`). For position broadcast that is
*correct* — a stale position is worthless and dropping it is what you want.
Transactions must never use that path, and this is the reason.

**Interest management.** A client receives broadcast only for the 3×3 parcel
neighborhood around its avatar. World size then costs nothing per client;
district *density* is the only load variable, which is also the thing worth
optimizing for a game about crowds.

**Server-authoritative movement.** Client sends intent; server validates
collision and parcel access; server broadcasts the accepted position. No client
prediction in v1 — the world is walking speed, not twitch, and rubber-banding a
strolling avatar is not worth the complexity.

The cost of that choice is that the avatar does not move until the server
answers, so latency is felt directly. Budget: under 200 ms round-trip feels
immediate, 500 ms is noticeable but playable, and above that the client should
show a connection-quality indicator rather than silently feeling broken. If
real players outside the server's region make that untenable, the fix is
prediction for *your own* avatar only — never for other players, whose
positions are the authoritative thing being broadcast.

---

## 8. The client

Browser, 2D top-down canvas, WebSocket. Camera follows the avatar. Parcel
boundaries and ownership are always visible — you should never be unsure whose
land you are standing on, because that is the thing the whole economy is about.

**Gene runs on the server.** The current WASM ABI is text-in/text-out
`gene_eval` plus alloc/free and result accessors (`gene_wasm.nim:56-97`) — no
callbacks into JS, no module loading — and host subsystems are `geneWasm`-gated
out of that build by design. So the browser is a renderer and an input device;
JS owns the socket and the canvas. A shared authoritative world needs a server
regardless, so this costs the design nothing.

### 8.1 Two surfaces, one operation table

> **Everything you can do, you can do by clicking. The REPL grants no
> authority — it grants composition.**

Both halves matter and they are one rule, not two.

If the GUI were incomplete, programming ability would convert directly into
powers a non-programmer cannot buy at any price, and a world with one shared
economy would have two classes of citizen in it. If the REPL granted authority
the GUI does not, §3's capability table would be decoration — the real
permission model would be "can you open a socket."

So the GUI is the *complete* surface and the REPL is the *fast* one.

This is structural rather than a matter of discipline. Per
`examples/ai_agent/docs/design.md` §7.2, an operation declaration is one value
from which validation, dispatch, routing, audit policy, and documentation are
all derived. New World adds one more orthogonal policy to that declaration —
**`^ui`: where this operation appears to a person**.

```gene
(type BuyArgs ^props {^parcel Coord ^max_price Int})

(Operation
  ^name "land.buy"
  ^args BuyArgs ^result Parcel ^errors [NotForSale InsufficientCoin]
  ^effects ["world_write"]
  ^audience ["remote_user"]        # caller class, per §3 — never the role
  ^caps ["land.buy"]               # the capability the principal must hold
  ^admission "session_serialized"
  ^audit "full"
  ^ui {^panel "map"
       ^affordance "parcel_menu"    # menu | form | palette | inspector | none
       ^label "Buy this parcel"
       ^confirm "spend"             # show cost and resulting balance, require accept
       ^enabled_when parcel_is_buyable}
  ^handler land_buy)
```

Two fields extend the inherited vocabulary and should be recognized as
extensions rather than assumed: **`^caps`** is what keeps §3's promise that a
role is a capability set and not an audience value — authorization stays
`audience ∩ capabilities`, with `^audience` naming the channel the call arrived
on and `^caps` naming what the principal must hold. **`world_write`** is a new
effect class beside the inherited `observe | session_write | model_call |
host_read | host_write`, because mutating shared world state is a distinct kind
of authority from mutating a session and is the one every economic operation
declares.

`^ui` is **not optional, and omission is not a silent default**. An operation
declared without one fails a startup check, the same way the naming-convention
suite in `tests/spec_runner.nim` fails a hyphenated registration. Shipping a
feature reachable only by typing code is therefore a build error rather than an
oversight nobody noticed.

Three honest qualifications:

- **`^affordance "none"` exists**, for operations that are not features —
  settlement steps, the period tick, things no principal calls. It requires a
  reason string, and the startup check counts them so the count can be watched.
- **Some arguments are code, and no widget writes code.** `build.script`'s
  affordance is an editor plus a template gallery (§8.4). That is a GUI
  affordance for a code-shaped argument, not an exemption from parity.
- **Generated is not the same as good.** The descriptor guarantees an
  affordance *exists* and says where it lives; a well-designed panel may still
  hand-build the interaction on top of it. Parity is the floor, not the
  ceiling.

### 8.2 The panels

| Panel | What it is | Operations it surfaces |
|---|---|---|
| **World** | the canvas — avatars, builds, drops, chat, proximity | walk, collect, interact, inspect, `chat.say` |
| **Build** | palette, placement, stamp, erase, undo, live Matter cost | `build.place`, `build.remove`, `build.script`, `parcel.set_terms` |
| **Map** | district view, footfall heat, prices, for-sale overlay, search | `land.buy`, `land.sell`, `land.list`, district naming |
| **Ledger** | balances, income by parcel and by build, dividend and royalty history, journal query | `econ.transfer`, market orders, and the read side of §10 |
| **People** | who is here, invites remaining, your invitee tree, block and report | `invite.send`, `moderation.report` |
| **REPL** | §9 | all of the above, composed |

The invitee tree is in the GUI because §4.6 rule 5 makes it economically
load-bearing: a player has to be able to see, without asking, which of the
people walking through their land can never pay them a dividend.

Three rules the panels obey:

1. **Cost before commit.** Every spending operation shows the amount and the
   resulting balance and requires an explicit accept. This is §5.3's rule for a
   build's `charge` effect, applied to the client's own buttons: nothing in this
   world takes your money while you are looking somewhere else.
2. **Ownership is never ambiguous.** Boundaries, owner, and parcel terms are
   legible from the world panel without opening a dialog.
3. **Every action is a journal entry you can find.** A ledger row links to the
   event that produced it (§10). "What did that button actually do" is
   answerable by query, always, rather than by asking someone.

### 8.3 The echo — how the GUI teaches the REPL

Every GUI action is a call to a named operation, so the client can simply show
it:

```text
› [ you placed 4 tiles ]                                 show as code ▾
  (build/place ^parcel [12 -3] ^tile "oak_floor" ^at [3 3])
  (build/place ^parcel [12 -3] ^tile "oak_floor" ^at [4 3])
  …
```

The REPL panel keeps a dimmed transcript of the calls your clicks just made,
and any line can be lifted into the prompt with one click.

This is the highest-value feature in §8 and §9 combined, because it is the
mechanism by which someone who has never programmed discovers that they already
have been. It is also nearly free: the calls exist either way, since both
surfaces go through the same table. The client is not generating a tutorial —
it is showing its own outgoing messages.

The corollary is a real constraint on naming. **Operation names and argument
names are the first Gene most players will ever read**, so they are named for
what a player would call the thing, not for what the implementation calls it.

### 8.4 The ladder from clicking to authoring

Build behavior (§5) is the deep end, and nobody should arrive there in one
step. Four rungs, each visible from the one below:

1. **Place tiles.** No code. Most builds stop here, and that is a success, not
   a failure.
2. **Attach a template.** A gallery of behaviors — door, sign, shop counter,
   toll gate, jukebox, guestbook, teleport pad — configured through a form. No
   code written.
3. **Read the template.** The form's fields *are* the template's parameters,
   and "show source" reveals the Gene the form was filling in. The form is a
   view of the code, not a wrapper hiding it.
4. **Edit it.** The source becomes yours, in the editor, rehearsed against a
   snapshot before anyone can walk into it (§9.4).

Rung 3 is the load-bearing one, and it is why templates ship as **readable Gene
source rather than engine primitives**. An opaque template teaches nothing and
leaves a missing rung in the middle of the ladder. Every template in the gallery
must be a build a player could have written.

### 8.5 Feel

Server-authoritative movement (§7) means the avatar does not move until the
server answers. Building is transactional, so a placed tile can be drawn
optimistically as a ghost and then confirmed or withdrawn — a rejected placement
removes the ghost and says why. That is safe precisely because §5.3 makes the
server the only thing that ever decides.

Waypoint walking — click a spot on the map, the avatar walks there — is a
**client** feature built from repeated movement intent, not a server-side path
command. Movement's authority model is unchanged, and the convenience that §9.2
declines to give a script is given to a person instead.

### 8.6 Visual style

Style follows from the palette decision (§5.1): a small, coherent, hand-made
tileset, procedurally recolored per district. Constraint is the aesthetic —
every place in the world is built from the same 200 tiles, so districts are
distinguishable by *composition*, which is what makes a player's build
recognizably theirs.

---

## 9. The REPL

The REPL is the advanced player's instrument. It is deliberately *not* the way
the game is played, and equally deliberately the way the game is played well.

### 9.1 What it is for

> The GUI is where you do a thing. The REPL is where you do a thing three
> hundred times, or work out which thing to do.

Four powers, none of which is extra permission:

- **Composition** — loops, functions, and conditions over the same operations
  §8 exposes as buttons.
- **Query** — arbitrary predicates over the read-only world surface and your own
  journal. The map panel's filters are the ones somebody anticipated; yours are
  the ones you actually need.
- **Authoring** — write a build's behavior and rehearse it before a stranger
  walks into it.
- **Tooling** — name a script, keep it, run it again, publish it, mount it.

### 9.2 Parity, and the one line it does not cross

The REPL calls the same operations through the same table, under the same
capability check (§3), the same validation, and — the part that is easy to get
wrong — **the same rate limits, which live on the operation rather than on the
surface**. A script calling `land.buy` a hundred times meets exactly the limit a
hundred clicks would meet. Per-surface limiting would make the REPL a bypass and
the parity claim false.

One class of operation is excluded, and it deserves a rule of its own:

> **The REPL acts on your property. It does not act as your presence.**

`world.move`, `chat.say`, emotes — anything that makes another player believe a
person is there — are not callable from the REPL. They require an interactive
session with a real input event behind them.

The reason is that footfall is the entire economy (§4.1). A scriptable
`world.move` is a Matter-drop vacuum (§4.5), a footfall generator, and a solvent
for every rule in §4.6, each of which assumes the thing walking around is
somebody's attention. Scripted chat is the same problem aimed at people instead
of at the ledger — and the design already has a sanctioned way to put words in a
machine's mouth: an NPC, which costs Coin by construction (§6).

**What this rule does not do is stop botting.** Anyone can drive a browser with
an automation harness, and no client-side rule survives that. What it does is
keep automated presence *outside the sanctioned surface*, which turns it from a
supported feature into a detectable, journalled, bannable act. That is the same
distinction §4.7 draws about reclamation: a rule that makes abuse require
deliberate circumvention is worth having even though it is not a proof.

The cost is real and should be named: no patrol scripts, no scripted tour guide,
no "walk me home" macro. §8.5 returns the convenience as a client feature
without opening the API.

### 9.3 Sessions, state, and budgets

| | guest REPL (§3) | player REPL |
|---|---|---|
| `Env` | fresh per submission | persistent per session |
| bindings | nothing carries over | your definitions persist |
| operations | none — pure evaluation only | everything your capabilities allow |
| step budget | an order of magnitude below a player's | high, still bounded |
| rate limit | per connection and per IP | per principal |

A player's session `Env` is an **overlay** over the world module: definitions
land in the overlay, are invisible to anyone else's evaluation, and never mutate
the world module. That is the same property §14 claims for authoring generally —
a live server accepts new code without a restart because `eval` has somewhere to
put it that is not the running program.

Operations called from the REPL are submitted to the world actor exactly as the
GUI submits them, return a result value, and cannot bypass validation. **The
journal records which surface a call arrived on** (`^via "repl"` / `^via
"gui"`) — not because they are authorized differently, they are not, but because
a moderator asking "was that a person or a program" should not have to infer it
from timestamps.

### 9.4 What the leverage looks like

```gene
# Parametric building. The palette places one tile. This places a colonnade.
(for x in (range 0 16 4)
  (build/place ^parcel my_parcel ^tile "pillar" ^at [x 0]))
```

```gene
# A market scan the map panel's filters cannot express.
(fn cheap_and_busy [district : Str] : (List Parcel)
  ((world/for_sale district)
    .to_stream
    ; .filter (fn [p] (< p/price (* 4 (world/footfall p/coord ^periods 4))))
    ; .into []))
```

```gene
# Return on investment, parcel by parcel, out of your own journal.
(for p in (world/my_parcels)
  (var coin
    ((ledger/events ^type "dividend" ^parcel p/coord ^periods 8)
      .to_stream
      ; .map (fn [e] e/coin)
      ; .into []))
  ($println p/coord " earned " (sum coin) " over 8 periods"))
```

```gene
# Rehearsal: run a behavior before a stranger can.
(var greet (fn [visitor] [(say "welcome back, " visitor/name)]))
(rehearse ^build my_shop ^on "enter" ^visitor (fake_visitor ^name "ada") greet)
```

**Rehearsal** is worth calling out as a feature rather than a convenience.
`rehearse` evaluates a behavior in exactly the `Env` §5.2 would give it, against
an immutable world snapshot, and returns the effects it *would have proposed*
together with the validator's verdict on each one. Because §5.3 already makes
behavior a pure function from a visitor to a list of effects, a faithful dry run
is not a simulation of the real thing — it *is* the real thing, minus the apply
step. Debugging a shop by making strangers walk into the broken version is the
alternative, and it is a bad one.

### 9.5 Scripts are property

A saved script is an owned object: named, versioned, private by default. Two
things can be done with one:

- **Publish it.** It becomes readable and forkable, exactly as build source is
  (§5.4). The culture §5.4 describes — you learn by reading the shop you just
  walked into — extends to tools.
- **Mount it on a build.** A mounted script runs for whoever walks in, under the
  build sandbox (§5.2) and the build's authority, never your session's. This is
  the **tool shop**: a parcel whose product is a script other people want to
  run — a district map, a price analyzer, a build generator, a guestbook.

The tool shop is where the programmer's advantage rejoins the economy everyone
else is in. A script only you run earns nothing. A script strangers walk in to
use earns footfall, and footfall is the only faucet there is (§4.1).

> **Programming ability is not a separate income stream. It is a better way to
> make a place worth visiting.**

That sentence is what keeps §1's thesis intact in the presence of a REPL. A
world where programmers earn through a private channel and everyone else earns
through footfall is two games wearing one map.

### 9.6 What the REPL must not become

- **Not a second implementation of the game.** If an operation is genuinely
  pleasant only from the REPL, that is a defect in its §8.1 descriptor, filed
  against the GUI.
- **Not a chat channel** (§9.2).
- **Not an admin backdoor.** Admin operations are capability-gated identically
  on both surfaces; `admin.grant` from the REPL is the same call producing the
  same journal entry.
- **Not unbounded.** It is authenticated general `eval` on a shared server,
  which puts it behind §5.5 exactly as build behavior is.

### 9.7 When it ships

The REPL splits along the §5.5 fault line:

- **The query REPL** — read-only evaluation over the world surface and your own
  journal, no operation calls, no persistent definitions — needs only
  `max_steps` and ships with the ledger in Phase 5.
- **The full REPL** — operation calls, persistent definitions, saved scripts,
  rehearsal, mounted scripts — is authenticated general evaluation and is gated
  on `max_memory_mb` and `timeout_ms` exactly as build behavior is. It ships
  with Phase 6.
- **The guest REPL** (§3) is the most exposed of the three and ships last, or
  behind an account, as §3 already says.

It is worth being blunt that this ordering makes §5.5 the gate on **both** of
this design's distinguishing features. That is an argument for doing that work
early, not for pretending it is smaller than it is.

---

## 10. Persistence, moderation, and the journal

**Parcel-granular storage.** The world is not one value. A parcel is a record;
buying, building, and settling write one parcel. Reading a district does not
load the world.

**Per-parcel version chains**, in addition to world checkpoint generations
(`examples/ai_agent/docs/design.md` §3, §9.5). Reverting one griefed parcel by
rolling the whole world back to yesterday punishes every other player, so
`admin.rollback` restores one parcel to one version and touches nothing else.

**Every state change is a typed event** — and the journal is simultaneously the
world's history, the activity feed, the economic audit trail, and the moderation
record:

```gene
{^v 1 ^type "parcel_bought"  ^parcel [12 -3] ^by "mira" ^price 240}
{^v 2 ^type "build_placed"   ^build "b8801" ^parcel [12 -3] ^by "mira" ^matter 60}
{^v 3 ^type "terms_set"      ^parcel [12 -3] ^open true ^build_fee 5 ^royalty 10}
{^v 4 ^type "build_placed"   ^build "b8802" ^parcel [12 -3] ^by "tomas" ^fee 5}
{^v 5 ^type "dividend"       ^period 41 ^parcel [12 -3] ^to "mira" ^coin 63
      ^visitors 18 ^royalty_from ["b8802"]}
{^v 6 ^type "effect_rejected" ^build "b8802" ^kind "move" ^reason "out of parcel"}
{^v 7 ^type "budget_exceeded" ^build "b8802" ^limit "max_steps"}
{^v 8 ^type "npc_spoke"      ^npc "n55" ^to "tomas" ^cost 2 ^budget_left 118}
{^v 9 ^type "invited"        ^by "mira" ^who "ada" ^grant {^matter 200}}
{^v 10 ^type "reclaimed"     ^parcel [40 19] ^from "absent" ^refund 90}
{^v 11 ^type "revoked"       ^build "b9001" ^by "admin:kay" ^reason "harassment"}
{^v 12 ^type "build_placed"  ^build "b8803" ^parcel [12 -3] ^by "ada"
      ^matter 12 ^via "repl" ^script "ada/colonnade@3"}
```

The `invited` grant carries Matter and no Coin, per §4.4 — the invite channel is
not a second Coin faucet, and the journal has to show that it isn't.

Every principal-initiated event carries **`^via`** — `"gui"`, `"repl"`, or
`"agent"` — per §9.3. It changes no authorization and grants no exemption; it
exists so a moderator can distinguish a person from a program without inferring
it from timing. When a call came from a saved script, the script's id and
version ride along with it, which is what makes a griefing script traceable to
one artifact rather than to one afternoon.

Economic events carry enough to reconstruct every balance from the journal
alone. That is not a nice-to-have: the first time a player says "I was robbed,"
the answer has to be a query.

---

## 11. Delivery phases

Ordered so that each phase is playable by real people at the end of it.

### Phase 1 — the world, server-side

Parcels and tiles, avatar positions, the collision model (§2.2), server-
authoritative movement, ~10 Hz broadcast, interest management. Driven by a
script client, not a browser. No economy, no ownership, no scripting.
**Ships when:** two scripted clients move around a shared world and each sees
only the other's in-range positions.

### Phase 2 — the browser client

Canvas renderer, tile drawing, camera, WebSocket transport with reconnection,
the world and map panels, and the panel shell §8.2 will fill in. This is a
from-scratch 2D game client and it is a separate project from 0a, not the last
mile of it — the existing web surface is a chat UI and shares nothing with it
but the socket.
**Ships when:** two people in two browsers see each other walk.

### Phase 3 — identity

Per-principal accounts, sessions bound to a principal rather than a connection,
and capability sets assigned at authentication. **The gateway today has one
shared bearer token for the whole server** (`gateway_adapter.gene:38, 792-806`),
which is a door key, not an identity; nothing in Phase 4 or later can be built
on it. Start with admin-created accounts and hardcoded role sets — no signup, no
credential recovery, no OAuth — which is the smallest thing that makes §3 real.
**Ships when:** two named principals hold different capability sets and the
journal attributes actions to them.

### Phase 4 — ownership and building

Buying frontier parcels, placing tiles from the palette, Matter and Coin,
starter grants, parcel terms, the three roles enforced at the operation table.

This is also where the two-surface contract becomes structural, because it is
the phase where operations stop being a handful: the `^ui` descriptor on the
operation declaration, panel affordances generated from it, the startup parity
check, and the §8.3 echo. The echo is cheap here and expensive later — it is a
transcript of messages the client is already sending, and retrofitting it after
a hand-built panel layer means unpicking one.
**Ships when:** a player buys a parcel, builds a room, a guest is refused
`build.place` over a raw socket — not just in the UI — and an operation added
without a `^ui` descriptor fails the build.

### Phase 5 — the economy

Footfall settlement, dividends, royalties, build fees, invitations and spawn
clustering, drops, the market, land pricing, reclamation, the ledger panel — and
the §4.8 parameters, which cannot be settled before there is play to calibrate
against.

The **query REPL** (§9.7) ships here rather than with Phase 6, because it is
read-only evaluation bounded by `max_steps` alone and because an economy nobody
can interrogate is an economy nobody trusts. Its first real job is letting
players check the §4.8 numbers against their own ledgers while those numbers are
still being tuned.
**Ships when:** a landlord earns more from a tenant's build than from their own,
and can see exactly why in the journal — from the ledger panel *and* from a
query they wrote themselves.

### Phase 6 — programmable builds

*Blocked on `EvalPolicy` gaining `max_memory_mb` and `timeout_ms` (§5.5), which
is its own proposal with its own performance evidence, not a checkbox.* Ships
as
a closed expression language until then — a working game, but not the one §14
describes. The roadmap should show which of the two shipped.

Behavior on builds, the sandboxed `Env`, effect proposal and validation, public
source, per-visit step budgets, `budget_exceeded` and `effect_rejected` events.

The full REPL lands with it and for the same reason (§9.7): persistent session
overlays, operation calls, saved scripts, rehearsal, mounted scripts, and the
template gallery that makes §8.4's ladder climbable. Behavior authoring without
rehearsal means debugging a shop by letting strangers walk into the broken
version, so the two are one phase rather than two.
**Ships when:** a stranger's shop charges you for something and the transaction
is confirmed, journalled, and refundable; a build with an infinite loop is cut
off without anyone else noticing; and a player who has never written code opens
a template, reads it, changes one line, and ships it.
**This is the phase where the app becomes uniquely Gene.**

### Phase 7 — AI NPCs

Owned NPCs, personas, budgets and dormancy, NPC trade, dialogue journalling,
owner spend caps.
**Ships when:** an NPC shop turns a profit for its owner across a week.

### Phase 8 — scale and stewardship

Moderation tooling at volume, district discovery and search, admin dashboards,
economic telemetry, the autonomous agent as a player (§6).

---

## 12. Non-goals

- **Combat, physics, twitch action.** Nothing in this design needs them, and
  they would force client prediction, lag compensation, and cheat detection —
  three hard problems bought for no gain.
- **Player-uploaded assets** (images, audio, models). Fixed palette (§5.1).
- **Instances, shards, or private worlds.** One world, or the whole thesis fails.
- **A fully in-browser world with no server** (§8).
- **In-browser local models.**
- **Crafting trees, skills, levels, character progression.** The progression is
  your land and what you built on it.
- **A REPL-only feature set.** Anything reachable only by typing is a build
  error, not a power user's reward (§8.1).
- **A GUI-only feature set either.** The inverse failure — an operation the
  panels can drive but the table cannot express — means the GUI has grown a
  private path, and §3's authorization stops being the whole story.
- **Scripted avatars, patrol scripts, bot play.** The REPL acts on property, not
  presence (§9.2).
- **A visual node-based programming language.** §8.4's ladder runs from a form
  straight to the Gene the form was filling in. A second, weaker language in the
  middle is a maintenance burden that teaches nothing transferable and gives the
  ladder a rung that leads nowhere.
- **Real money buying Coin, Matter, or land.** See §13.
- **Open signup.** Invitation-only is a design feature (§4.4, §4.6), not a
  launch limitation.
- **Balance guarantees between builds.** Builds are made by strangers with
  different taste and skill; moderation and the market are the answer, not a
  rules engine.

---

## 13. The one decision I did not make

**Does real money ever enter?**

Idea #9 on the input list was "money to buy additional resources." I have read
that as *in-game* Coin buying Matter, which §4 implements. If real money can
buy Coin, then real money buys land and builds, the footfall faucet stops being
the thing that decides who prospers, and §1's thesis is dead — the map goes
back to being owned by whoever spent the most.

**Recommendation:** real money, if it ever enters, buys **cosmetics and account
services only** — avatar appearance, district naming rights, extra invite
capacity — and can never be converted into Coin, Matter, or land. That keeps a
revenue path open without touching the incentive that makes the world worth
visiting.

This is the one place where the wrong call quietly ruins everything downstream,
so it needs a deliberate answer rather than a default.

---

## 14. Why this is a killer app for Gene

| Property | What demonstrates it |
|---|---|
| **`Env` as an authority boundary** | Strangers' code runs when you walk into their shop. It cannot reach the filesystem, the network, or another parcel — because the *language* decides what an evaluation can reach. Every comparable platform had to build a bespoke sandbox VM; this one is a language feature. |
| **Homoiconicity** | A build is data. Its tiles, its terms, and its behavior are values a guest can read, a player can fork, and an admin can diff between versions. "View source on this place" is one operation. |
| **`eval` with an isolated overlay** | Authoring is evaluation. Declarations land in an overlay and never mutate the world module, so a live server accepts new code from a stranger without a restart. |
| **Worker model** | World, parcel, player, NPC, and REPL are one abstraction with one typed operation contract. Three roles are capability sets over one table, so authorization is not re-implemented per surface. |
| **One declaration, two surfaces** | The GUI is generated from the same operation declarations the REPL calls, so "everything is clickable" and "everything is scriptable" are one statement checked at startup (§8.1) rather than two feature sets maintained by hand. The echo (§8.3) then makes the GUI a transcript of the language — the client teaches Gene by showing what it already sent. |
| **Bounded, typed event journal** | History, activity feed, economic audit, and moderation record are the same log. |
| **Agent-native** | An AI can hold an account and be revoked under identical rules. |

The claim worth defending is narrow and true:

> **No other runtime lets untrusted users extend a live shared program in the
> runtime's own language, with the sandbox supplied by the language rather than
> bolted on.**

§5.5 is the one thing standing between that sentence and a demo.
