# Miclone — Design

A voxel game engine with Luanti's architecture, written in Gene, whose mod
language is Gene.

**Status: proposal, revision 2. Nothing here is implemented.** This document
exists to be reviewed and argued with before any code is written. Part I is the
direction and the decisions — read it first, and read §D2 before believing any
of the rest, because §D2 is the constraint that shaped everything else. Part II
is the system design. Appendix A maps each part to the upstream source that
should be read while implementing it.

Revision 2 answers a review of revision 1. What changed: the same-source claim
is narrowed to *same algorithm, not same bits*, and §D3.1 turns that into an
explicit exact/corrected split; M0 grows from one probe to three (§D6), adding a
cross-backend FP divergence probe and a server worldgen throughput probe;
§D7.2's packed `Buffer` is re-justified against consumers that exist; §7.1 now
states the latency policy for player edits under server authority; and §10's
dismissal of WebTransport is corrected — the obstacle is Gene's HTTP/1.1 server,
not browser support.

Reference source: `examples/miclone/luanti/`, a shallow clone of
<https://github.com/luanti-org/luanti> at the tip of `master`. It is not
vendored into this repository (see `examples/miclone/.gitignore`).

Upstream is LGPL-2.1-or-later (engine) with CC-BY-SA assets. **We read it; we do
not copy from it.** See §D9.

---

# Part I — Direction

## D1. What "clone Luanti" means here

Luanti, measured in the clone:

| | lines |
|---|---:|
| `src/**` C++ (`.cpp` + `.h`), including 13K of tests | 210,214 |
| `irr/**` — the vendored Irrlicht fork | 87,035 |
| `builtin/**` — engine Lua | 22,621 |
| `doc/lua_api.md` — the mod API reference | 12,777 |

Roughly 320,000 lines of C++ and 22,000 of Lua. A line-for-line port is not the
goal, would take years, and would mostly be a port of Irrlicht — a 2008-era
scene graph we have no reason to reproduce.

**What we build instead:** a voxel engine that inherits Luanti's *architecture
and data model* and replaces its *implementation and mod language*. Luanti has
had fifteen years to find out which decisions survive contact with real worlds
and real mods. Those decisions are the valuable part, and they are free.

Deliberately inherited:

1. **The node/block data model** — a 16³ block of 4-byte nodes, content id plus
   two parameter bytes, with all semantics in a registry keyed by content id
   (§1, §2). Fifteen years of games fit through this, and its size and shape
   are what make map storage and network delta encoding tractable.
2. **The authoritative-server/thin-client split**, with singleplayer running an
   in-process server (§10). It is why "singleplayer" and "multiplayer" are not
   two codebases.
3. **The registry + callback mod API shape** — `register_node`, `register_abm`,
   `on_punch`, and friends (§9). Not the Lua syntax; the shape.

Deliberately not inherited:

- **Irrlicht.** We target a modern programmable pipeline directly.
- **The reliable-UDP transport** (`src/network/mtp/`). Gene has no socket API
  at all (§D2), and the first client is a browser, which cannot open a UDP
  socket regardless. §10 designs the transport we can actually build.
- **Formspec's string DSL.** Gene is homoiconic; a UI described as a string
  that a mod concatenates is a step backwards from describing it as data (§13).

## D2. The honest constraint: Gene cannot draw a triangle today

This is the finding that decides the project, so it comes before the design
rather than after it. Everything below was checked against the tree at
`ffd883d`, not recalled.

**Dynamic FFI cannot express the graphics API.** `ffi/open` + `ffi/bind` load a
library and bind a symbol at runtime, but `isSupportedDynamicFfiSignature`
(`src/gene/vm.nim:5262`) accepts only a hand-enumerated table of **0-to-3
argument** shapes. The functions a renderer needs are all wider than that:

| function | arity |
|---|---:|
| `SDL_CreateWindow` | 6 |
| `glVertexAttribPointer` | 6 |
| `glTexImage2D` | 9 |
| `glDrawElements` | 4 |
| `glUniformMatrix4fv` | 4 |

Not "slow" or "awkward" — `ffi/bind` raises `unsupported dynamic FFI signature`
and there is no workaround short of a C shim per call.

**Static FFI is not an escape hatch yet.** `ffi/fn` declarations have no
interpreter implementation (`native function 'c_sqrt' has no implementation`,
reproduced against a `libSystem` `sqrt` binding). They lower through the
experimental `typed_native` C backend, and `docs/implementation-status.md` is
explicit that there is no `gene build` producing a linked artifact —
`examples/native/build.sh` drives `cc` by hand.

**The web profile has no 3D.** `tools/check_host_bindings.mjs` is 210 lines
covering canvas 2D, `document`, events, and DOM construction. No WebGL, no
`Float32Array`, no typed arrays of any kind.

**There is no socket API.** `net/tcp_read_text_async` and
`net/tcp_write_text_async` are one-shot connect-transfer-close text helpers, not
sockets. The only persistent bidirectional transport Gene code can hold is the
RFC 6455 **WebSocket server** in `src/gene/http_server.nim` — server side only,
no client.

**Two smaller gaps** that matter later: `fs` has `write_bytes` but **no
`read_bytes`**, and `Buffer` is a `seq[Value]` (`src/gene/types.nim:3758`) —
boxed, 8 bytes per element whatever the declared element type.

The conclusion is not that this is impossible. It is that **the platform edge
is the project's real content**, and a design that treats rendering as a detail
to be sorted out later is a design that will stall in month two. §D7 turns this
list into an ordered backlog, and §D6 puts a gate in front of everything.

## D3. Architecture — one core, two shells

```
        ┌─────────────────────────────────────────────┐
        │  core/  — portable Gene, no platform deps   │
        │                                             │
        │  world model · node & item registries ·     │
        │  mapgen · lighting · meshing · physics ·    │
        │  inventory · crafting · protocol codec      │
        └─────────────────────────────────────────────┘
              ▲                              ▲
    compiled for VM                compiled for web profile
              │                              │
   ┌──────────┴──────────┐        ┌──────────┴──────────┐
   │  server/  (VM)      │        │  client/  (browser) │
   │                     │  ws    │                     │
   │  mods · worldgen    │◄──────►│  WebGL2 · input ·   │
   │  threads · storage  │        │  HUD · prediction   │
   │  authority          │        │                     │
   └─────────────────────┘        └─────────────────────┘
```

`core/` is written in the **intersection** of what the VM runs and what the
`web` profile compiles — no fexprs, no runtime `eval`, no actors or channels,
no FFI, no capabilities, no threads. Both sides get the same world model, the
same meshing, and the same physics, which removes the usual source of the worst
bugs in this genre: two implementations of one rule, drifting apart.

**What that buys, precisely: the same algorithm, not the same bits.** The client
is V8 and the server is the interpreter — two runtimes, two libm
implementations, one source. This distinction is load-bearing and §D3.1 turns
it into a rule:

- IEEE-754 requires `+ − × ÷` and `√` to be correctly rounded. Two conforming
  runtimes agree on them **exactly**, forever.
- It requires nothing of `sin`, `cos`, `pow`, `exp`, or `log`. Two runtimes may
  differ in the last ULP, and are entitled to.

So bit-identical agreement is available, but only for code that stays inside
the first list. That is a constraint we can meet where it matters and should
not pretend to meet everywhere.

This is not a new mechanism. It is what `nimble transpile_spec` already exists
to guarantee — shared fixtures run against both backends and must agree — and
this project is a much larger customer for it than the current fixtures are.

The core is where most of the work is, and it is the part that is unambiguously
"everything in Gene". The shells are thin and platform-shaped.

### D3.1 The determinism rule

`core/` splits in two, and the split is a design rule rather than an
observation.

**Exact half — bit-identical agreement is required and enforced.** Mapgen and
everything feeding it. A disagreement here is not a glitch: the client and the
server generate *different worlds*, and the failure surfaces as terrain that
changes when you walk away and come back. It is also the half where the
constraint is easy to hold, because value/Perlin noise is already nothing but
integer hashing, lerp, and a smoothstep polynomial — `+ − × ÷` and comparisons,
no transcendentals. Luanti's `src/noise.cpp` is built the same way.

The rule for this half: **no `sin`, `cos`, `pow`, `exp`, `log`, or `atan2`**.
Where a transcendental seems necessary, use a polynomial approximation defined
in `core/` — computed identically on both sides *because we wrote it* — rather
than the host's. Cross-backend fixtures assert bit-identical output, and CI
fails on a single differing bit.

**Corrected half — agreement is expected, divergence is tolerated and
repaired.** Physics, prediction, entity motion. The server is authoritative and
the client reconciles, which is what every multiplayer engine does and what the
protocol has to support regardless of how close the two runtimes are. A 1-ULP
difference in a player's velocity is a normal property of two runtimes, not a
bug to be hunted. Fixtures here assert agreement to a tolerance and track the
observed divergence over time, so a *growing* gap is still a signal.

Stating it this way costs one paragraph and removes the project's single
largest hidden assumption. §D6 measures the real divergence before M1 depends
on the answer.

## D4. The browser shell goes first

Four reasons, in order of weight.

**1. It is reachable; the native shell is not, yet.** §D2. Adding WebGL2 to the
web profile is extending a binding table and its `lib.dom.d.ts` oracle —
mechanical, verifiable, and the same kind of work that put canvas there. Making
the native shell reachable means either a general N-argument FFI trampoline
(libffi, or hand-written per-ABI assembly) or a C extension module. Both are
real projects. Neither should be on the critical path to seeing a voxel.

**2. There is a precedent in this tree that already worked.**
`examples/new_world` is a playable side-view voxel game whose world generation,
physics, collision, and mining are Gene compiled through the web profile. Its
spike (`examples/new_world/docs/design.md` §D5.1) is a measured pass, and it
found and fixed a real compiler miscompilation on the way. Miclone is that
argument in 3D.

**3. Measured: the transpiled path is the faster one.** On this machine
(`nimble speedy`, Darwin arm64), the VM does:

| workload | time | rate |
|---|---:|---:|
| 1e6 iterations of `(set s (+ s (* k 3)))` | 91 ms | ~11M iter/s |
| 409,600 `Buffer/set!` sends | 216 ms | ~1.9M/s |
| 200k `List/push!` sends | 53 ms | ~3.8M/s |

A message send costs roughly 500 ns, which matches the D1-dispatch work
recorded in the repo. The new_world spike, on the transpiled path, ran 10,000
sprites of structure-of-arrays float math in **0.749 ms/frame** — an
order-of-magnitude more arithmetic per second than the VM manages, because V8
JITs it and the VM interprets it.

These are different workloads and the comparison is indicative, not rigorous —
§D6 re-measures on the workload that actually matters. But the direction is
clear and it is the opposite of the intuition that "native must be faster":
**for the hot loops in this engine, Gene-on-V8 beats Gene-on-the-VM.** Meshing
belongs on the client anyway, which is where the faster runtime is.

**This argument is narrower than it first looks, and the narrowing matters.**
It says meshing lands on the fast runtime. It does not say the engine's hot
work does — because the server owns hot, client-independent workloads that
*cannot* move to V8 and are pinned to the interpreter by the same measurement:

- mapgen, over 512,000-node chunks (§3);
- ABM scanning across every loaded block, every tick (§12);
- node timers, liquid flow, entity steps, and light.

So the honest summary is: **the fastest runtime does the work that can move,
and the authoritative workload is stuck on the slowest one.** Browser-first
still wins on reasons 1, 2, and 4, which carry it without reason 3 at all. But
this inverts where the throughput ceiling sits — it is the server, not the
frame budget — and §D6 therefore gates on server worldgen throughput as well as
frame rate. That measurement should happen before M2, not after.

**4. The browser supplies, free, four things we would otherwise build:** PNG
decoding (`$image/load`), a frame clock (`$frame/request`), input events, and
audio. Building a PNG decoder in Gene to see a textured cube would be a bad
trade.

**What it costs.** The web profile is a deliberately bounded subset with no
runtime `eval`, so **client-side mods are out of scope for the browser shell**
(§D5). And `core/` must stay inside the subset — a real constraint on the whole
project, accepted knowingly, and one the shared fixtures will enforce rather
than leave to discipline.

## D5. Mods run on the server, and they are sandboxed properly

A mod is code loaded at runtime. Runtime module loading is a VM capability that
the web profile deliberately does not have. So mods run server-side, and
Luanti's client-side modding (`doc/client_lua_api.md`, ~1,000 lines) is out of
scope until a native or wasm client exists.

This is a smaller loss than it looks, and it comes with a genuine gain. Luanti's
mod security is a known weak spot: mods are Lua with `insecure_environments`, a
global trust setting, and a documented history of "don't install mods you don't
trust". Gene's capability values (`docs/design.md` §14, §15.2) are the thing
Lua never had — a mod is handed exactly the authorities its manifest declares,
and a mod that never receives `$fs/WriteDir` cannot write a file no matter what
it evaluates. `gene run --grant` already works this way for applications.

**A mod API where "this mod cannot touch your filesystem" is enforced rather
than promised is a better mod API than Luanti's**, and it is a reason to do
this project in Gene specifically. §9 designs it.

## D6. Milestone 0 — the probes, and what they are allowed to kill

Before any game design, answer the questions that invalidate everything
downstream. Same discipline as new_world's D5, which is in the tree and worked.

M0 has **three** parts, because the review of the first draft of this document
found two assumptions hiding behind the rendering one. Each is cheap, each can
kill or reshape the design, and none of them gets cheaper by being discovered
in M3.

### D6.1 The render spike

A fly-through of a static voxel world. 16³ chunks, one texture atlas,
face-culled meshing, WebGL2, a mouse-look camera, no game logic, no server, no
networking, no mods.

**Passes when**, at 1280×720 on a mid-range laptop:

- a 12×4×12 chunk view (576 chunks, ~2.4M nodes) holds **60 fps** steady;
- **meshing one 16³ chunk stays under 8 ms**, so a chunk can be remeshed inside
  a frame without a visible hitch;
- no `bigint` appears anywhere on the meshing or render hot path in a profile
  (the `F64` discipline of new_world's D4, adopted here on day one);
- the WebGL2 bindings pass `tools/check_host_bindings.mjs` against
  `lib.dom.d.ts` like every other binding in the profile.

| failure | what it means | fallback |
|---|---|---|
| meshing too slow, rendering fine | the core's hot loop is the problem | move meshing behind a Web Worker; if still short, the meshing inner loop becomes the first customer for a typed/packed `Buffer` (§D7.2) |
| render calls too slow | per-call boundary cost | batch through typed arrays; fewer, larger draws |
| the profile can't express it at all | the subset is too narrow for 3D | escalate to the wasm host-bridge path, which new_world's D3 costed and rejected for a 2D game and which a 3D game may justify |

#### Result — **PASS**. 121 fps, worst chunk 0.44 ms against an 8 ms budget

Built as `core/mesh.gene` (face-culled meshing over an 18³ padded
neighbourhood), `core/vec.gene`, `client/render.gene`, `client/atlas.gene`, and
`client/main.gene`, with `tools/mesh_bench.mjs` as the headless harness.

| | ms/chunk | ms/non-empty chunk |
|---|---:|---:|
| generate (16³ block, column-filled) | 0.087 | 0.094 |
| mesh | 0.084 | 0.112 |
| **total** | **0.172** | **0.206** |

Worst single chunk **0.398 ms** against the 8 ms budget, over a 8×4×8 volume;
90 of 256 chunks produce geometry, averaging 258 faces. The first version of
this harness sampled only y 0–15 and reported 60 of 64 chunks empty — a chunk
fully below the surface legitimately meshes to nothing, so a run confined to
one slab measures almost nothing and reports a budget it never tested.

Two things worth carrying forward:

- **§D4's inversion, confirmed from the other side.** The same column-based
  generator that projects to hundreds of milliseconds on the VM (§D6.3) runs in
  **0.094 ms** on V8. Generation and meshing cost about the same on the client;
  on the server, generation is three orders of magnitude worse.
- **The 16³ block and run-free column fill are what made it fit**, which is
  §D6.3's conclusion applied rather than restated.

**One rendering bug, and the shape of it is the lesson.** The first build drew
pale rectangles scattered over the terrain. They were not mis-shaded geometry
but *holes*: the two Z faces were wound backwards, so `cull_face "back"`
discarded them and the fog showed through. A backwards quad is not drawn
inside-out — it is not drawn at all, nothing errors, and `getError` stays
clean, so the only signal is pixels that are not there.

Three hypotheses were tested and killed against data before the real cause
turned up by computing the winding: that the pale faces were sand (the world
contains none at that depth), that they were stone washed out by fog (100% of
side faces are grass), and that the atlas had unpainted tiles being sampled
(all five tiles read back correctly). Guessing from a screenshot was the slow
path; the cross product answered it in one step.

`tools/mesh_bench.mjs` now checks the invariant directly — for every quad, the
normal implied by its winding must point from the solid node that owns the face
into the transparent node it faces. Reintroducing the bug makes it report 12
inverted quads. "All six directions appear" would have been the wrong test: a
heightfield legitimately emits no downward faces.

**Frame rate: 121 fps** at a 1290×846 backing store, drawing 186 chunk meshes
and 51,387 faces — twice the 60 fps criterion, and the median frame of 8.3 ms
is the display's refresh interval rather than the renderer's cost, so the
budget is not the binding constraint at this view distance.

*M2 note.* The spike now draws 231 meshes and 62,580 faces — 22% more geometry
through an unchanged render path (`client/render.gene` is untouched) — and it
stands at world (-1440, 3168) rather than the origin. §3 gives biomes a
~555-node scale, this view is 192 nodes across, so wherever it stands it sees
one or two biomes; at the origin it stands in the cold quadrant and is uniformly
snow. The site was found by scanning for the view with the most distinct biomes
and a coastline in it, and nothing in the generator is tuned for it. **The fps
figure was not re-taken**: the browser-automation tab reports `document.hidden`,
where Chrome throttles `requestAnimationFrame` to about 5 fps, and a screen
capture of a visible window needs a permission this environment does not have.
The meshing budget, which is the criterion this probe exists for, was re-taken
and is in §5.

Two measurement traps worth recording, because both produced numbers that
looked like results:

- **A backgrounded tab throttles `requestAnimationFrame` to nothing.** The
  first reading was "1 fps" with a 14.6 s frame — not the world build, just
  Chrome pausing the loop. Any fps figure has to be taken with the tab
  focused.
- **`python3 -m http.server` sends no `Cache-Control`,** so Chrome caches the
  ES modules heuristically and a plain reload silently re-runs the *old*
  build. A rebuild that changes nothing on screen is this until proven
  otherwise; `fetch(url, {cache: "reload"})` per module forces the refresh.

#### The bigint criterion is not met, and the fix was reverted

§D6.1 requires no `bigint` on the meshing hot path. There is one: a
`(Buffer U16)` read emits `BigInt(arr[i])`, because §D7.1 types integer-buffer
elements as `Int` to match the VM. Measured at **6.4x** against a raw typed-array
scan, and it happens once per neighbour test — roughly 28,000 times per chunk.

The chosen fix was to elide the conversion in the compiler rather than diverge
the two backends: mark `Int` values that are already exact JS numbers and let a
comparison between two of them skip the conversion. That was implemented —
buffer reads, local bindings, function returns, and parameters, propagated to a
fixpoint over the call graph — and **reverted**, because it was not sound.

Two failures, both from the numeric form escaping into a context expecting a
bigint:

- a parameter proven numeric at every call site was compared against a
  module-level `let` constant, which is still emitted as `0n`. In JavaScript
  `0 === 0n` is false, so `opaque?` answered "solid" for every node and the
  mesher emitted **zero faces for every chunk**;
- an exported function whose result was numeric returned a number into
  `$gene_check_int`, which requires a bigint and throws.

Both were caught immediately — the benchmark reports face counts, and mixing
the two representations is loud in JavaScript rather than silent. That is the
one encouraging part of the episode, and it is why the pass was attempted in
that shape.

The lesson is that this is a **representation change, not a use-site elision**:
making a value numeric changes what its storage holds, so every consumer — every
return site, call argument, binding, and validator — has to agree. The option
was scoped as "conservative analysis" and is really "audit every emit site".
It is worth doing and it is not worth doing half-way, so it is recorded in
§D7.10 rather than shipped. Nothing is blocked meanwhile: meshing passes with
20x margin *including* the conversion.

#### M2 update — the criterion is met, from the source side

The paragraph above is right about the compiler and wrong about the conclusion
it drew from it. "Representation change, not use-site elision" is exactly
correct — and a representation change is something the *source* can make.

M2 declared node content `F32` rather than `U16` and content ids `F64` rather
than `Int`, everywhere: `Block`'s three columns (§1), the node registry's
columns (§2), the biome and ore registries' node references, and the buffers
mapgen writes and the mesher reads. Measured over 5,832 elements in the web
profile:

| | `Int`-typed buffer | `F32`-typed buffer |
|---|---:|---:|
| scan | 60.4 µs | 6.8 µs |
| scan and use the value as an index | 93.0 µs | 6.9 µs |

9x and 13.5x, because an `Int` read emits `BigInt(arr[i])` — an allocation — and
indexing with it emits `Number(...)` to undo it. §5's mesher does exactly that
seven times per node.

This is sound where the compiler pass was not, and for the reason the compiler
pass failed: it changes what the storage holds, so there is no second
representation for a comparison, a return site, or a validator to disagree with.
`0 === 0n` cannot arise because no `0n` is produced. It costs 2 bytes per node
in the client's memory and nothing on the VM, whose `Buffer` is a boxed
`seq[Value]` either way (§D7.2). `F32` represents every integer below 2^24
exactly and §2 caps content at 4,096 ids, so no id is ever rounded and the two
backends cannot disagree about one.

§1's "content is a `u16`" is unchanged and still means what it said — it is the
width for the wire (§10) and the disk (§11), which is where a width buys
anything.

**§D7.10's numeric-elision pass is still worth doing** and is still the general
answer; this is the specific one, available because an engine gets to choose its
own storage types. What it does not cover is `Int` arithmetic that is genuinely
integer — the pass would still earn its keep there.

### D6.2 The divergence probe

The cheapest of the three and the one that de-risks the most. Run the exact
`F64` chains mapgen and physics will depend on — value/Perlin noise with
octaves, the smoothstep and lerp kernels, Amanatides–Woo traversal, one physics
step — on **both** backends over a few million seeded inputs, and report the
actual divergence: max ULP difference, and count of inputs that differ at all.

This does not pass or fail. It **decides §D3.1** with data instead of
reasoning:

- **Zero differing bits in the exact half** (the expected result, since that
  half is `+ − × ÷` only) confirms the rule and it becomes an enforced CI gate.
- **Nonzero** means something in the chain reaches a host transcendental. Find
  it and replace it with a polynomial defined in `core/`, or move that
  computation out of the exact half.
- **Nonzero and unfixable** collapses the exact half into the corrected half:
  mapgen becomes server-authoritative-only, the client never generates terrain
  speculatively, and §11 stores what the server generated. Survivable, but it
  changes §3 and it is much cheaper to know now.

#### Result — **PASS, zero differing bits**

Built as `probes/divergence.gene` (portable) with `probes/run_divergence.gene`
and `tools/divergence.mjs` as the two shells. 323 samples, covering `wrap32`,
`mix32`, `smoothstep`, `lerp`, the 32-bit hash and its unit form, 2D and 3D
lattice noise, `fbm2`/`fbm3`/`ridged2` at terrain frequencies, and three
4,096-sample column checksums.

```
gene run divergence | diff - <(node tools/divergence.mjs)   # no output
```

Every sample agrees **bit for bit** between the Nim VM and V8 — including the
accumulated checksums, which sum 4,096 fractal values each and would surface a
single differing ULP anywhere in the chain.

So §D3.1 is confirmed rather than assumed, and the exact half becomes an
enforced CI gate rather than an aspiration. Three things made it work, and they
are the rules to keep:

- **The hash is integer arithmetic done inside F64** (`core/exact.gene`), never
  `frac(sin(x) * 43758.5453)`. `examples/new_world` uses the `sin` form and is
  right to — it generates its world in one place. Here it would have split the
  world silently.
- **Every intermediate stays under 2^53**, enforced by one rule: wrap to 32 bits
  before multiplying, and multiply only by constants under 2^21.
- **Comparison is on decomposed bits, not printed floats.** The two backends
  print the same value as `0.0000001` and `1e-7`, so a text diff would have
  reported a difference that does not exist — and could have hidden one that
  did.

The probe stays in the tree as the regression test for all three.

### D6.3 The worldgen throughput probe

§D4's inversion, measured. Generate one 80³ mapgen chunk (512,000 nodes) on the
VM and time it.

The arithmetic that motivates this: at ~11M interpreted iterations per second,
512,000 nodes leaves roughly **21 operations per node** in a one-second budget.
3D noise with several octaves is comfortably more than that, so the naive
implementation plausibly lands in the **seconds per chunk** range — and
demand-driven generation in front of a walking player would stall visibly.

**Passes when** a chunk generates in **under 300 ms** on one worker lane, which
with parallel lanes keeps generation ahead of a player moving at normal speed.

If it does not, the mitigations in rough order of preference: fewer octaves and
2D-dominant terrain (cheap, costs terrain character); generate at reduced
resolution and interpolate (cheap, costs detail); pre-generate a bounded world
at world-creation time rather than on demand (changes §3's contract, and is
what some games do); make mapgen the first customer for typed functions and a
packed `Buffer` (§D7.2, expensive but the most valuable to Gene).

Worker lanes are not a mitigation on their own — they multiply throughput by
core count but do nothing for the per-chunk latency a player feels at the edge
of the loaded region.

#### Result — **FAIL by ~1000x**, and the reason is not the noise

Measured on the VM (`nimble speedy`, Darwin arm64) by `gene run worldgen`.
Per-call costs at reduced sample counts, extrapolated by exact call counts —
the first version of this probe generated a whole chunk and ran **forty
minutes without reaching its first `println`**, which is why it now samples.

| stage | per call | calls/chunk | ms/chunk |
|---|---:|---:|---:|
| `cave?` — fbm3, 3 octaves | 583.5 µs | 512,000 | **298,752** |
| `surface_height` — fbm2, 5 octaves | 398.5 µs | 6,400 | 2,550 |
| `material` — comparisons only | 1.27 µs | 512,000 | 650 |
| buffer writes | 0.61 µs | 512,000 | 312 |
| allocate `(Buffer U16 512000)` | — | — | 8 |
| **projected total** | | | **302,273** |

**1,008x over a 300 ms budget.** Per-node 3D noise is not slow, it is
unavailable: one `fbm3` call per node is 298 seconds on its own.

The ladder's first two rungs handle that — but the table says something the
ladder did not anticipate, and it is the more important half:

**Even with no noise at all, per-node work does not fit.** `material` plus one
buffer write is 1.88 µs per node, or **962 ms/chunk** — already 3x over budget
for a generator that computes nothing. A single `(chunk ~ set! i id)` costs
0.61 µs, which is the VM's message-send cost (~500 ns, matching the repo's own
`bench_core` figures) and is therefore a floor: 512,000 nodes cannot be
*written* in 300 ms, whatever is written.

So the constraint is not "3D noise is too expensive". It is:

> **On the VM, a mapgen chunk cannot exceed roughly 300,000 node-visits within
> a 300 ms budget, and every visit buys about one message send.**

That is a statement about chunk *granularity* and about the VM's call cost, not
about terrain quality, and §3 and §D8 are revised against it rather than
against the ladder alone. Two consequences, both real:

- **An 80³ mapgen chunk is the wrong unit for this engine.** 512,000 node
  visits is past the floor before any generation happens. A 32³ chunk (32,768
  visits, ~62 ms) fits; a 16³ block (4,096 visits, ~8 ms) fits comfortably.
- **Run-length column filling, not per-node writes.** A column is a handful of
  runs — air, then a surface node, then dirt, then stone — so a generator that
  writes runs touches thousands of nodes per chunk instead of hundreds of
  thousands. This is a change in how the generator is written, not in what it
  produces.

Caves become sparse carving rather than a per-node threshold, for the same
reason. (The probe also shows the current cave parameters produce a **0.0**
cave fraction — the threshold of 0.82 against normalized fbm3 is almost never
exceeded — so that stage needed retuning regardless of its cost.)

The VM's ~500 ns message send is now the single most valuable Gene-side
optimisation this project could ask for, and it is recorded as §D7.10 rather
than acted on here: it is a large piece of work, it benefits every Gene
program, and the engine has a shape that fits within today's costs.

**M2 acted on this and §3.3 carries the result.** The 16³ block is the
generation unit, the stages are position-derived rather than chunk-derived, and
a block with biomes, caves, and ore generates in 31.8 ms. This probe stays as it
is — it is the record of an 80³ chunk, which is a thing this engine no longer
generates — and `gene run worldgen` now measures the unit that replaced it.

**All three are contributions regardless of outcome.** WebGL2 bindings and
typed arrays are things the web profile wants anyway; a measured 3D baseline
for the transpiled path does not exist today; and a cross-backend FP divergence
report is something the repo has never had and would want for any dual-backend
program.

Nothing in Part II should be built before D6.1 passes and D6.2 has been
decided.

## D7. What Gene gains — the missing-feature backlog

This is the "add missing features and libraries along the way" list, ordered by
when it blocks. Each item is a contribution to Gene, not to the game, and each
should land with the spec coverage the repo already requires (`nimble spec`,
`nimble transpile_spec`).

**1. WebGL2 host bindings + typed arrays (web profile). Blocks M0.**
The binding table in `src/gene/compiler.nim` / `src/gene/web.nim` plus entries
in `tools/check_host_bindings.mjs`. Scope: context creation, buffers, shaders,
programs, uniforms, VAOs, textures, draw calls, depth/cull state — on the order
of 60–80 entries, plus typed arrays as first class values the profile can
allocate, fill, and hand to a binding.

*Typed arrays: **landed**.* Not as a new web-only type but as `(Buffer T)` —
the same buffer the VM has and the same one FFI §16.5 names — so `core/`
meshing code is one module on both backends rather than two. `(Buffer F32)`
lowers to `Float32Array`, `(Buffer U16)` to `Uint16Array`, and `(b ~ get i)` /
`(b ~ set! i v)` compile to plain `a[i]` indexed access. Element vocabulary is
`I8 I16 I32 U8 U16 U32 F32 F64`; `I64`/`U64` are deliberately excluded because
`BigInt64Array` elements are `bigint`. Indices and lengths are `F64` on both
backends — the VM's `Buffer/get`/`set!` were widened to accept an integral
Float — because an `Int` index is a `bigint` in the profile and would allocate
one per element write in the meshing loop. Three supporting fixes went with it:
`$to_int`/`$to_float` reached the portable web stdlib, `($buffer T n)` gained a
sized zero-filled form (the list form cannot express 512,000 elements without
building a 512,000-element list first), and `(Buffer T)` as an *annotation* was
fixed — it had never matched any buffer, because the annotation carries the
symbol `F32` while the value stores the evaluated type and comparison is
structural. Covered by six new cases in `tests/transpile/fixtures.json`, which
run on both backends and must agree.

*WebGL2 bindings: **landed**.* 39 bindings covering context, buffers, shaders,
programs, attributes, uniforms, vertex arrays, textures, state, and draw calls.
`Gl` is its own type; the six handle types (`Gl/Buffer`, `Gl/Shader`,
`Gl/Program`, `Gl/Texture`, `Gl/VertexArray`, `Gl/UniformLocation`) share one
kind carrying a name, so a shader still cannot be bound where a buffer is
expected.

Enum arguments are **compile-time-checked strings** — `($gl/bind_buffer gl
"array" vbo)`. Gene has no keyword literal (`:foo` reads as two tokens, since
`:` is the annotation separator), so the earlier sketch in this document using
`:array` was not valid Gene. Each enum must be a literal from a fixed table and
is resolved to its WebGL constant during analysis, so a typo is a compile error
naming the argument rather than an `INVALID_ENUM` on a frame that renders
nothing.

All 39 are verified against `lib.dom.d.ts` (48 → 87 bindings checked), and the
emitted TypeScript typechecks under `--strict` — which caught two things the
binding checker could not: `WebGLVertexArray` is not a DOM type
(`WebGLVertexArrayObject` is), and every `create*` returns `X | null`, now
routed through a helper that throws where the failure happens.

**§D6.1 is now unblocked**: the remaining work is the spike itself — a mesher,
a camera, and a shader — not language support.

**2. Packed typed `Buffer` (VM). Blocks M4. No longer M2's escape hatch —
M2 did not need one.**
`Buffer` is `seq[Value]` today: 8 bytes per element and a boxed write per
`set!`. A 16³ block is 4,096 nodes; at 4 bytes per node that is 16 KB packed
and 32 KB boxed for content ids alone, before the two parameter arrays.

The consumers are all server-side, and none of them is meshing — meshing is a
client concern that feeds WebGL typed arrays (§5), and the server never builds
a mesh until the native shell exists in M9:

- **holding loaded blocks in memory.** A server with a few thousand blocks
  resident pays the 2× in footprint and again in cache behavior on every scan
  — and §12's ABM pass scans loaded blocks every tick.
- **light.** The server computes light during mapgen (§3, §4) and stores it in
  `param1`; lit blocks live in this representation for as long as they are
  loaded.
- **storage and protocol codecs.** §11 writes blocks to SQLite and §10 sends
  them to clients. Both want a packed byte run, and both currently pay an
  element-by-element pack and unpack.

Wanted: unboxed storage for `U8 U16 I32 F32 F64`, with `Buffer/get`/`set!`
compiling to a direct indexed access on the known-element-type path. This is
the item most likely to need care — it touches the NaN-boxed value layer, and
`AGENTS.md`'s rules about `sizeof(Value)`, zero initialization, and
allocation-free hot paths all apply.

It is also the heavy mitigation if §D6.3's worldgen probe fails, which is why
it may get pulled forward ahead of its listed milestone.

*M2 update: not pulled forward, and the reason is worth recording.* §D6.3 did
fail, and the ladder's cheap rungs plus the granularity change were enough —
31.8 ms against a 300 ms budget (§3.3). What M2 did discover is that on the
**web** side the element type is not a footprint question at all but a
representation one: an `Int`-typed buffer allocates a `BigInt` per read, and
declaring the same data `F32` is 9x faster (§D6.1's M2 update). That is a source
change, not a VM change, and it leaves this item where it was: the VM's `Buffer`
is still `seq[Value]`, still 8 bytes and a boxed write per element, and the
consumers listed above still want it packed.

**3. `fs/read_bytes` + binary integer/float codecs. Blocked M4. Landed.**
`fs/write_bytes` existed and `fs/read_bytes` did not, which was enough on its
own. `$binary` could slice and concatenate but could not read a `u16` LE or
write an `f32`; every binary format in Gene rebuilt that from `$bit`.

*Landed as `fs/read_bytes` plus twelve codecs — `get_u16/u32/i32/f32/f64` and
`put_u8/u16/u32/i32/f32/f64` — little-endian at a **byte** offset, so a record
with a `u8` tag followed by a `u32` can name the second field, which no
per-element index can. Out of range **raises** rather than wrapping: a silently
truncated node id is a corrupt world that reads back cleanly, which is the worst
shape a storage bug takes. Reading past the end raises for the same reason
rather than assembling a value from whatever follows.*

*`db/sqlite` blob support went with it, and was not on this list because nobody
had checked: `Db/execute` rejected `Bytes` outright and blob columns came back
through `columnText`, truncated at the first NUL. §11.1 has the detail.*

**4. Deflate/inflate. Wanted by M4, not blocking it. Open, now with a number.**
Luanti stores blocks zlib-compressed. Options: implement inflate in Gene (a few
hundred lines, portable, and the decode side is the one we need first), or bind
zlib once the FFI question is settled. Note that `examples/new_world/src/atlas.gene`
already writes a valid PNG from Gene, so the neighbourhood is not unexplored.

*M4 shipped run-length encoding instead and measured the gap rather than
guessing at it: RLE takes a block from 24,576 bytes to a mean of 612 (40x), and
on the busiest block zlib on the raw arrays reaches 228 where RLE reaches 1,320.
**Deflate is worth another 5.8x on top of RLE**, so this item survives the
milestone that was supposed to force it — it is now a size optimisation with a
measured payoff rather than a blocker, and the format's flags byte is where it
lands.*

**5. Deterministic noise library (pure Gene). Blocks M2. Landed.**
`core/noise.gene` and `core/exact.gene`, confirmed bit-identical across backends
by §D6.2 and used by all of §3. `core/field.gene` sits on top of it and is the
part §D6.3 forced: the library is exact, and sampling it once per node is
unaffordable, so the field is sampled on a coarse world-anchored lattice and
interpolated (§3.2).

Value/Perlin/simplex plus fractal octaves, matching the shape of Luanti's
`src/noise.cpp` and its `NoiseParams`. No VM change; it is a library. It sits in
§D3.1's exact half — bit-identical across the VM and the web profile, or the
server and client generate different worlds — which constrains it to `+ − × ÷`
and integer hashing, and makes it the best cross-backend fixture in the project.
Simplex noise needs care here: the usual formulations use a gradient table and
`floor`, which are fine, but any variant reaching for a transcendental is
disqualified.

**6. Vector/matrix math (pure Gene). Blocks M0.**
`$math` has the scalars. `vec3`, `mat4`, AABB, and a ray-vs-voxel traversal are
library code, all `F64` per §D4.

**7. WebSocket *client*, or a real socket API. Blocked M6. Landed for the
browser; still open for the native shell.**
The server side of RFC 6455 exists; nothing on the **VM** can open a
connection, and a native client still needs either the client half or a general
socket API. That half remains deferred — it gates only the native shell (§D7.8).

What M6 needed, and did not have, was the **browser** half plus binary frames on
both ends. §10 says messages are Gene nodes "except block data, which uses a
packed binary encoding because 16 KB of nodes should not become a node tree" —
and neither end could carry a byte. Trap: *the namespace existed and the
capability did not*, which is exactly what §11's `db/sqlite` did to M4.

Three gaps, all now closed:

- **`ws_send` was text-only.** `wsEncodeFrame(0x1, …)` with a `requireStr` in
  front of it. It now takes a `Str` or `Bytes` and picks the opcode from the
  value's kind — not from a flag, because a caller holding bytes never wants
  them sent as text: RFC 6455 requires a text frame to be valid UTF-8, so that
  is a protocol violation rather than merely wasteful.
- **An inbound binary frame was dropped silently.** Opcode `0x2` fell through
  the delivery `case` with no branch: no callback, no error, no close. The worst
  of the three possible behaviours, and invisible from the peer's side. Text
  now arrives as `Str` and binary as `Bytes`. The frame codec needed no change
  at all — `wsEncodeFrame` always took an opcode and `wsParseClientFrame` always
  reported one, so this was a widening of the Gene-facing surface, not of the
  protocol.
- **The web profile had no WebSocket binding whatsoever.** Ten now:
  `ws/connect`, `on_open`, `on_text`, `on_bytes`, `on_close`, `send`,
  `send_bytes`, `close`, `open?`, `buffered`. A socket travels as an
  `EventTarget` — which it is — so no new handle type was needed; the emitted
  helpers cast, as `dom/rect_*` already does. Six entries in
  `tools/check_host_bindings.mjs` check them against `lib.dom.d.ts`.

Two decisions inside that worth stating:

- **`binaryType` is set to `"arraybuffer"` on connect.** The default is `Blob`,
  whose bytes are reachable only through a promise, so a handler reading a
  message synchronously finds `event.data` is not a buffer — at runtime, with no
  error, on the first binary frame.
- **Text and binary arrive on separate callbacks** rather than one `on_message`
  taking a union. Not a preference: the profile does not narrow a union on a
  truthiness test (see `dom/element`), so a handler typed `Str | (Buffer U8)`
  could not tell which it had.

**And a defect this hunt exposed, which was worth more than the feature.** A
WebSocket callback runs as a fiber, and `dispatchWsHandler` returned a task
nobody read — so an exception inside `on_open`, `on_message`, or `on_close`
*vanished*. Not logged quietly: gone. A handler with a typo did nothing,
reported nothing, and left the socket open and idle, which is indistinguishable
from a client that sent no message. It cost three build cycles here before the
cause was instrumented, and it would cost a mod author far more (§9). Handler
tasks are now reaped each loop pass and a failure is logged with its message.
They remain fire-and-forget — nothing waits on the result — but a failure is now
*said*.

Covered by three e2e tests in `tests/test_http_server.nim`, over raw sockets
with hand-masked client frames: both opcodes in both directions, a 16 KB payload
(past both frame-header size classes, where a length field gets truncated), a
reversal that can only be computed from a real `Bytes`, and a deliberately
broken handler whose error must appear.

Two things noted and deliberately not fixed here:

- **`(Buffer U8)` elements are `Int`**, so a byte literal is `255` and not
  `255.0` — M2's bigint finding, surfacing at the I/O boundary. Harmless: a
  message payload is not a hot loop, and it is why this is the one buffer in the
  tree that is not float-typed.
- **A `Void` callback lowers to `: undefined`**, and `tsc` rejects a body whose
  value is `void` (`console.log(…)`). Pre-existing and profile-wide —
  `dom/add_event_listener` and `frame/request` produce the identical error — so
  it is the profile's `Void` lowering rather than anything the sockets do.

**8. General N-argument FFI. Blocks the native shell.**
The §D2 finding. Either libffi (a new runtime dependency, which `AGENTS.md`
says to avoid without an explicit request — so this needs a decision, not an
assumption) or generated per-ABI trampolines. Large, strategically valuable to
Gene far beyond this project, and correctly sequenced *after* there is a
running game that justifies it.

**9. Audio.** Browser `AudioContext` bindings, at the same tier as WebGL2.
Deferred to M8.

**10. The VM's call and message-send cost. Blocks nothing; raises every
ceiling.** §D6.3 measured a `(buf ~ set! i v)` at **0.61 µs** and the repo's own
`bench_core` puts a trivial call at ~480 ns — roughly 1,500 cycles, where a
tuned bytecode interpreter spends 50–150. That single number is what makes
512,000 node visits impossible in 300 ms and what forced §3's chunk granularity
and run-length rewrite.

Nothing here is blocked on it. But it is the highest-leverage work available to
Gene — it would widen every budget in this document at once, and unlike the
other nine items it is not specific to a voxel engine.

*First pass: **landed**, and it found two things rather than one.*

**The typed boundary, not the call, was the cost.** A one-argument function
measured 183 ns/call untyped and **557 ns** as `[x : F64] : F64` — the
annotations cost twice the call they annotated. Two causes, both on the hot
path of every typed call:

- `adaptBoundary` was handed `"parameter '" & name & "'"`, so a **heap
  allocation per typed parameter per call** built an error label that is only
  read when the check fails;
- `matchesTypeExpr` reached its answer through roughly ten string comparisons
  before the check itself.

`Int` already had a fast path around this, open-coded at a dozen call sites.
Generalizing it — `bareScalarSatisfied`, dispatching on interned symbol ids
over the exact-kind scalars — took `[x : F64] : F64` to **330 ns**, and the
per-parameter cost to ~12 ns above untyped. The list is deliberately a subset
of `matchesBuiltinType`: refinement types carry range checks and containers can
convert, so they stay on the general path, and a name omitted merely takes the
slow path. On the §D6.3 workload: `cave?` 583 → 438 µs, `surface_height`
398 → 293 µs, **projected chunk 302 s → 227 s (−25%)**.

**`Buffer/get` was O(n).** `bufferItems` returned the backing `seq` **by
value**, so every element read copied the whole buffer — 4 MB per read on a
512,000-element chunk, and any scan was O(n²). This is why the first version of
the §D6.3 probe never finished. Returning `lent` fixed it: a 200,000-element
scan went from *not completing* to 61 ms. Guarded now by
`vm.buffer_scan_4096` in `bench_core`.

*What it does not do.* 227 s against a 300 ms budget is still **757x**. That
was the expected shape — an incremental VM pass cannot close three orders of
magnitude. `vm.typed_f64_call` and `vm.typed_f64_call7` now guard the win,
because every pre-existing typed benchmark annotates `Int` and so could not
have seen this regress.

**11. The AOT lowerable subset. Landed, and it is the answer §D7.10 is not.**

The interpreter was the wrong thing to optimise. `core/exact.gene` and
`core/noise.gene` are fully annotated `F64` with no dynamism at all — the exact
case ahead-of-time compilation exists for, and one where a JIT would have
nothing to speculate about. `gene compile --target c` and `aot/load` already
existed; what did not was a lowerable subset wide enough to accept the code.

Measured before: of all of `exact.gene`, exactly one function (`f64_sign`)
lowered. The subset was straight-line arithmetic over `+ - *`, `if`, and calls
whose arguments were bare bindings — and functions that failed it were
**silently omitted** rather than reported. Six changes:

| | why it blocked the kernels |
|---|---|
| scalar functions get the statement lowering | locals and `while` were reachable only through `hasNativeRepr`, so a pointer in the signature bought loops that pure numeric code could not have |
| local type inference | `(var i : F64 0.0)` was required, which no Gene is written like |
| `/` by a provably non-zero divisor | `wrap32` divides by 2^32 |
| `$math/floor`/`ceil`/`trunc`/`abs` | every lattice-noise function floors |
| module `let` constants, inlined | a kernel names its magic numbers |
| nested calls as call arguments | `(mix32 (wrap32 seed))` — i.e. composition |

Now the whole hash and lattice-noise stack lowers. **`value3`: 1,088 µs
interpreted → 1.99 µs compiled, 547x.** `hash_unit3`: 55x. The remaining ~2 µs
is the dynamic entry adapter, not the arithmetic — the boundary is now the cost,
which is a much better problem to have.

**A correctness finding came with it, and it matters more than the speed.**
The first compiled build disagreed with the interpreter on **405 of 4,000**
values. The cause was not a lowering bug: Clang defaults to
`-ffp-contract=on` and had contracted `a*b + c` into a fused multiply-add,
rounding once where Gene rounds twice. More accurate, and a different number —
which for §D3.1's exact half means a compiled server and an interpreted client
generate different worlds. The backend now emits `#pragma STDC FP_CONTRACT OFF`
itself, so faithfulness does not depend on the caller passing a flag, and the
same 4,000 comparisons come back **zero**.

*Still open, and both are now the binding constraints rather than the subset:*

- **Cross-module AOT calls.** `localAotFunction` sees only the current
  compilation unit, so `noise.gene` calling `exact.gene` does not lower —
  the kernels must share a module until the callee manifest
  `jit-pipeline.md` §6 describes exists.
- **`(/ sum norm)` by a computed divisor**, which is what `fbm2`/`fbm3` end in,
  so those stay interpreted while everything they call is compiled. Lowering
  them needs a way for compiled code to raise, which is the runtime ABI.

Projected against §D6.3: `cave?` at 3 compiled `value3` calls is ~7 µs against
438 µs, so a 16³ block (4,096 nodes) generates in ~29 ms and a 32³ chunk in
~230 ms. **The chunk-granularity conclusion above still holds — an 80³ chunk
does not fit — but the margin is now comfortable rather than absent, and it is
AOT that bought it, not the interpreter work.**

## D8. Delivery phases

Each milestone ends in something runnable. No milestone is "infrastructure
only" — that is how a project like this quietly becomes a year of plumbing.

| | milestone | ends with | needs |
|---|---|---|---|
| **M0** | **The three probes (§D6)** | fly through a static voxel world at 60 fps, plus a decided determinism rule and a measured worldgen cost | backlog 1, 6 |
| ~~M1~~ | **World model + registries — done** | 63 cross-backend checks; §1 and §2 | — |
| ~~M2~~ | **Mapgen — done** | biomes, caves, and ore, drawn by the M0 renderer; §3 | backlog 5 |
| ~~M3~~ | **Lighting + meshing in `core/` — done** | the M0 renderer drawing a generated *lit* world; §4, §5 | backlog 2 |
| ~~M4~~ | **Persistence — done** | quit and come back to the same world; §11 | backlog 3 (landed), 4 (open, not blocking) |
| ~~M5~~ | **Player: physics, dig, place, inventory — done** | a playable singleplayer creative-ish loop; §1.1, §4.2, §7, §7.1 | — |
| M6 | Client/server split over WebSocket | the same game, client and server as separate processes | — |
| M7 | The mod API | a `default`-equivalent game defined as a Gene mod, not built in | — |
| M8 | Entities, crafting, UI, sound | a small but complete game | backlog 9 |
| M9 | Native shell | the same game outside a browser | backlog 7, 8 |

M7 is the point of the project. Everything before it is the engine a mod API
needs in order to be worth having, and M8's "small but complete game" should be
built entirely through M7's API — if it needs an engine change, the API is
wrong.

## D9. Non-goals

- **Wire compatibility with Luanti.** Not a client for Luanti servers, not a
  server for Luanti clients. The transport differs by necessity (§D2), and
  chasing compatibility would import the protocol's accumulated history for no
  benefit to a from-scratch engine.
- **Running Luanti's Lua mods.** Mods are Gene. Porting Minetest Game is not on
  the roadmap.
- **Copying upstream code.** Upstream is LGPL-2.1-or-later. We read it to
  understand algorithms and formats — which is what it is for, and what
  `doc/world_format.md` and `doc/lua_api.md` document deliberately — and write
  our own. Assets are not copied; textures are generated, as
  `examples/new_world/src/atlas.gene` generates its atlas. Any file that ever
  does derive from upstream carries its license header, and `docs/licenses/`
  gets the entry.
- **Loading Luanti worlds** — plausible later (the format is documented and
  SQLite-backed, and Gene has `db/sqlite`), attractive as a validation
  milestone, and explicitly not in M0–M9.
- **Matching Luanti's feature set.** Fifteen years of features. §D1.

## D10. Risks

**The subset constraint is load-bearing and untested at this size.** `core/`
must compile for both backends. new_world proved this at ~2,000 lines of
2D game logic; miclone is a different order of magnitude, and the first thing
that does not fit the profile will be discovered halfway through M3, not at the
start. *Mitigation:* every `core/` module gets a shared fixture from the day it
lands, so drift fails a build instead of accumulating.

**Meshing may be too slow in the profile, and it is the one loop that cannot be
moved.** *Mitigation:* it is exactly what M0 measures, before anything depends
on the answer.

**Determinism between backends.** Two runtimes and two libm implementations
compile from one source, so "same algorithm" is guaranteed and "same bits" is
not (§D3, §D3.1). Terrain must agree exactly; physics need only agree closely.
*Mitigation:* the exact/corrected split is a stated rule with a ban on host
transcendentals in the exact half, §D6.2 measures the real divergence before M1
depends on it, and mapgen fixtures fail CI on one differing bit. The failure
mode if the rule cannot hold is known and survivable — mapgen becomes
server-only — which is what makes this a managed risk rather than the hidden
assumption it was in the first draft of this document.

**Server throughput, not frame rate, is the likely ceiling.** §D4's measurement
puts the authoritative workload — mapgen, ABMs, timers, entities, light — on the
slower of the two runtimes, and none of it can move to the faster one.
*Mitigation:* §D6.3 measures an 80³ chunk before M2 designs around it, with a
mitigation ladder from cheap (fewer octaves) to expensive (packed `Buffer` and
typed functions). §14's standing gate keeps server tick time under measurement
from M6 on.

**Scope.** This is the largest thing anyone has built in Gene, by a wide margin.
*Mitigation:* §D8's rule that every milestone runs, and a willingness to stop at
M5 with a good singleplayer voxel game if M6+ stops paying for itself.

---

# Part II — The system

Part II is the design as it stands *before* M0. The spike is allowed to
invalidate any of it; §1 and §2 are the parts least likely to move, because
they are inherited (§D1).

## 1. Coordinates and the world model

**Node.** 4 bytes, exactly Luanti's `MapNode`:

| field | width | meaning |
|---|---|---|
| `content` | `u16` | index into the node registry (§2) |
| `param1` | `u8` | light: day in the high nibble, night in the low |
| `param2` | `u8` | per-drawtype: facedir, level, liquid depth, color index |

**M2: `u16` is the storage width, not the in-memory representation.** The
widths above are what a node costs on the wire (§10) and on disk (§11), and they
are unchanged. In memory the three columns are `F32` and a content id is an
`F64`, because `Int` lowers to `bigint` in the web profile and §5 reads node
content seven times per node — 9x to 13.5x, measured, in §D6.1's M2 update.
`F32` holds every integer below 2^24 exactly and §2 caps content at 4,096 ids,
so the round trip through the narrower wire format is lossless.

Content ids are **per-world and assigned at load**, never hardcoded; the
`name → id` mapping is stored with the world so that a saved block still means
what it meant. Three ids are reserved with Luanti's meanings: `unknown` (a
node whose definition is missing — drawn, walkable, not deleted), `air`, and
`ignore` (not generated yet; never sent to a client, never walkable).

**Block.** 16×16×16 nodes, indexed `x + 16y + 256z` — upstream's order
(`ystride = 16`, `zstride = 256` in `src/mapblock.h`), inherited so that the
serialized block layout and the loop order of any algorithm read from upstream
agree with ours instead of being silently transposed. X varies fastest, which
is also the inner loop meshing wants.

**Sector/column.** Blocks sharing an `(x, z)`, for column-oriented mapgen and
loading.

**Coordinates.** Three spaces, and mixing them up is the classic bug in this
genre, so they are distinct types rather than three `[Int Int Int]`:

- `NodePos` — integer node coordinates, world space
- `BlockPos` — integer block coordinates (`NodePos >> 4`)
- `Vec3` — `F64` continuous position, for entities and the camera

Luanti's `BS = 10.0` scale factor is **not** inherited; it exists because
Irrlicht wanted larger numbers. One node is 1.0.

**World limit.** ±31,000 nodes, as upstream. It is not arbitrary — it is what
keeps a node coordinate in an `s16` and a block coordinate comfortably inside
one.

### 1.1 M5 — a block is the unit of generation, not of client memory

Through M4 the client never kept the world. It generated an 18³ padded
neighbourhood per chunk, meshed it, uploaded the mesh, and dropped the nodes,
which is exactly right for a fly-through and rests on §3's claim that "for a
deterministic generator, generating the margin and asking the neighbour for it
are the same answer, and generating it is cheaper".

**M5 is where that stops being true.** The moment a player digs, a regenerated
margin describes the world as it was created rather than as it is. Every design
that keeps padded copies per chunk then has to write an edited node into each of
the up to eight copies containing it and keep them agreeing forever, and a stale
copy is a face that should not be there — §4's "invisible in tests and obvious on
screen", one subsystem over.

So `core/loaded.gene` stores the nodes once: a rectangular box of blocks as
**one node array**, with a parallel array for §4's `param1`. A block remains the
unit of generation (§3), of the wire (§10), and of disk (§11). It is not the unit
of client memory.

What follows from that, and is the reason it is worth the churn:

- **Reads are an index.** Physics and node selection (§7) do thousands per
  second and each is three subtractions and one array read, with no block lookup
  in front of it.
- **Meshing needs no gather** (§5).
- **Light crosses blocks** (§4.2), which closes the limitation M3 recorded.

**The array is one node larger than the world on every side**, and that shell is
not decoration: it is what lets §5's mesher read a chunk's neighbours and §4's
flood test its bounds without either of them bounds-checking. Five faces hold
`ignore` — opaque, so no face is drawn against it, and non-propagating, so no
light leaks out. **The sixth, the ceiling, holds `air`**, because sunlight enters
through it; a shell of `ignore` over the world would stop the sun at the ceiling
and leave everything under it black. Reads outside the array answer `ignore` too,
so "the edge of the loaded world stops you" falls out of an existing reserved id
rather than a special case.

The extent is fixed at construction and does not stream, which is what M5 needs
and no more. M6 splits client from server and blocks start arriving and leaving;
the shape that wants is this box sliding over the world, which is a change to who
fills it rather than to what it is.

For a 12 × 4 × 12 world that is 194 × 66 × 194 nodes: 9.5 MB of content and 9.5
of light, against 8.1 MB of uploaded geometry.

## 2. Node and item definitions

A definition is a Gene node — data, not a string DSL and not a closure-laden
object. It is registered, validated against a declared type, and frozen.

```gene
(register_node "default:stone"
  ^description "Stone"
  ^tiles       ["default_stone.png"]
  ^drawtype    :normal
  ^groups      {^cracky 3}
  ^drops       "default:cobble"
  ^sounds      (sounds/stone))
```

The registry splits into two halves on purpose, because they have different
audiences and different lifetimes:

- **the client half** — drawtype, tiles, transparency, light propagation, light
  source, collision box, selection box. Serialized to the client on join.
  *M2: built, less the collision and selection boxes, which M5 needs and M2 does
  not. Tiles are three columns — top, side, bottom — because grass needs three,
  and §5 reads them per face instead of carrying its own table.* Pure
  data; no code crosses the wire. The two light fields are here for prediction,
  not for authority — the client needs them to relight around its own edits
  (§4, §7.1), never to derive a received block's light from scratch.
- **the server half** — `on_punch`, `on_dig`, `on_timer`, `after_place`, drops,
  ABM registrations. Never leaves the server.

That split is what lets the client mesh and predict without executing mod code,
and it is why §D5's "no client-side mods" costs less than it sounds.

**Drawtypes for M0–M5:** `normal`, `airlike`, `glasslike`, `allfaces`,
`plantlike`, `liquid`. Luanti has 18 (`src/nodedef.h`); `nodebox` and `mesh` are
the expensive ones and they wait for M8.

**Items** are a parallel registry: name, description, inventory image, stack
max, tool capabilities. A node is automatically an item unless it says
otherwise. `ItemStack` is `{^name Str ^count Int ^wear Int ^meta Map}`.

**Groups** are Luanti's cross-cutting mechanism and they are worth inheriting
wholesale: a node is `{^cracky 3 ^falling_node 1}` and tools declare which
groups they dig and how fast. It is how mods interoperate without knowing about
each other.

## 3. Mapgen

**Revised by M2 against §D6.3's measurement.** The first draft of this section
specified generation in a **chunk** of 5×5×5 blocks (80³ nodes), Luanti's unit,
"generated as a whole so that caves, ore, and structures can cross block
borders". §D6.3 measured that unit at 302 s and concluded the unit was wrong,
not the terrain. What follows is what was built.

### 3.1 The generation unit is a block

Generation happens in one **16³ block** — §1's storage unit — and the same
staged pipeline fills either shape: a bare 16³ block for the server to store,
or the 18³ padded neighbourhood the client meshes from (§5).

**The chunk existed to make cross-border features possible, and it is not the
only way to get them.** Upstream carves a cave into a chunk-sized voxel
manipulator because its cave generator works from chunk-local state. Ours does
not: every stage is derived from *world* position — the height lattice is
anchored to world coordinates, cave worms come from world regions, ore clusters
from world cells — so each asks "which features reach this buffer" rather than
"which features start inside it". Two adjacent blocks generated a week apart on
different machines see the same worm and carve the two halves of one tunnel.

That is an argument, so it is also an assertion: `probes/mapgen_spec.gene`
generates a bare block and the padded neighbourhood of the block beside it and
requires the 256 nodes they share to be identical, and requires a block to equal
its own padded neighbourhood over all 4,096. If the granularity change were
unsound, those are the checks that would say so.

### 3.2 The pipeline

| | stage | shape | module |
|---|---|---|---|
| 1 | base terrain | 2D height, heat, humidity on a coarse world-anchored lattice | `core/field.gene` |
| 2 | biomes | nearest point in (heat, humidity), then run-length column fill | `core/biome.gene` |
| 3 | caves | carved along hashed Bézier worms | `core/cave.gene` |
| 4 | ore | placed from hashed world cells, scatter / sheet / blob | `core/ore.gene` |
| 5 | decorations | *not built* — the next milestone's | |
| 6 | lighting | *not built* — M3's, §4 | |

Every stage is a registry a mod can add to (§9), which is Luanti's design and
the reason its games look nothing alike. `core/content.gene` populates them with
a provisional node set, six biomes, and six ores; M7 replaces that file with a
mod and nothing else should have to move.

**Every stage obeys one rule, and it is §D6.3 restated: cost scales with output,
not with volume.** That rule is what rewrote stage 3. A per-node `fbm3` threshold
— the first draft's design — costs one noise evaluation per node by
construction, which is 1.8 s for a 16³ block on the VM. Carving costs what it
removes. The same rule put stage 1 on a lattice coarser than the node grid
(§D6.3's mitigation ladder, rung 2) and stage 4 on cells that are cheap to
reject.

### 3.3 What it costs

Measured by `gene run worldgen` on the VM (`nimble speedy`, Darwin arm64), by
generating whole blocks rather than extrapolating from samples:

| stage | ms per 16³ block |
|---|---:|
| 1 + 2 terrain, biomes, run fill | 22.3 |
| 3 caves | 4.2 |
| 4 ore | 6.1 |
| **one 16³ block (4,096 nodes)** | **32.6** |
| one 18³ padded neighbourhood (5,832 nodes) | 44.2 |

Medians of three consecutive runs on an otherwise idle machine, which spread by
about 4%. An earlier reading taken while `nimble perf` was running reported the
bare block at 61 ms and the *padded* block — half again as many nodes — at 49,
which is impossible and is the tell: on a loaded machine these numbers are
contention, not cost.

For comparison, the M0 generator — no biomes, no caves, no ore — took **103.8 ms**
for the padded block, of which 92.3 ms was 324 direct `fbm2` calls. Three more
stages at 43% of the cost.

**§D6.3's budget, read three ways**, because shrinking the unit by 125× and
keeping the same 300 ms would weaken the requirement by 125× while appearing to
pass:

| | reading | result |
|---|---|---|
| A | 300 ms per generation unit, §D6.3 as written | **PASS** — 32.6 ms, 9.2× margin |
| B | the node rate the 80³ unit implied, 1,706,667 nodes/s | **FAIL** — 125,644 nodes/s, 13.6× under |
| C | one lane ahead of a 4 node/s player at §D6.1's view | **PASS** — 32.6 ms against 76.9 ms |

B fails and is expected to. It is reported rather than dropped because it is the
strict reading and the granularity change is exactly what makes it easier;
hiding it would make the milestone look like it closed a gap it did not. C
replaces it, and C is the only one of the three derived from the game rather
than from an arbitrary volume: a player crossing a block boundary every four
seconds pulls in a slab of 13 blocks per second at the spike's view distance,
and one lane sustains that with 2.4× to spare. §D7.11's AOT path is what would
close B.

### 3.4 What it produces

A generator that is fast because it emits one id is not a passing probe, so
`gene run worldgen` reports composition next to timing:

- **surface** y 9 to 44, median 25, with the sea at 20 — **16.5%** of columns
  under water. The sea level was chosen from that measured distribution; the
  first value, 20 nodes lower, flooded 1.4% of the world and gave it puddles
  instead of a coastline.
- **biomes** tundra 15.0%, taiga 15.0%, rainforest 21.2%, savanna 12.5%,
  desert 23.4%, grassland 13.0%.
- **caves** 1.5% of rock below the lowest surface, linear in the worm count
  (0 worms 0.00%, 2 → 0.82%, 3 → 1.47%, 6 → 3.05%).
- **ore** coal 0.072%, iron 0.033%, gold 0.006% of a y 0..47 volume, plus
  gravel blobs and sandstone sheets.

**Two mistakes worth recording, because both were silent and both were found by
measuring rather than by looking.**

*The first: a biome nobody could visit.* `fbm2` normalises to [0, 1), so the
obvious thing is to place biome points across 0..100. But value noise is a mean
of lattice hashes, and its realised distribution is a bell around the middle:
heat comes out over 11..80 and humidity over 17..85. Desert was placed at
(94, 6) — outside anything the field generates — so **desert covered 0% of the
world** and nothing said so. The six points now sit on a circle of radius 13
about (48, 48), inside the range the field actually produces.

*The second: a cave density that read the same at every worm count.* Measured
over y 0..15, the air fraction is ~1.4% whether the generator makes two worms or
six, because at that height most of the air is the sky above a low column and
the caves are lost in it. The number only means something measured below every
surface in the world.

### 3.5 Determinism

**A hard requirement.** One `(seed, block_pos)` produces one block, on either
backend, forever. Mapgen is §D3.1's exact half, so this is enforceable rather
than hoped for: the whole pipeline stays inside `+ − × ÷`, comparisons, and
integer hashing, with no host transcendental anywhere in it — including the
lattice interpolation, whose step is a power of two so the fraction is exact.

`probes/mapgen_spec.gene` is §14 layers 2 and 3: **82 checks** that run on the
VM and through the web profile and must produce byte-identical output, including
the two seam assertions above and four golden block checksums. It passes, as
does `probes/world_spec.gene`'s 69.

Generation runs on the server. `spawn` places worldgen tasks on worker lanes,
which requires the captured graph to pass the `Send` check
(`docs/spec/concurrency.md`) — worldgen input is a seed, a position, and frozen
registries, so it is a natural fit, but the registries must be genuinely frozen
and that is a design constraint on §2, not an implementation detail.

## 4. Lighting

Luanti's model, unchanged because it is cheap and looks right: two 4-bit
channels, day and night, packed into `param1`, interpolated at render time by
the time of day. Sunlight propagates straight down at full strength through
nodes that admit it and spreads sideways with falloff; light sources flood-fill
from their node.

Updates are incremental — a dig or place enqueues the affected node and its
neighbours and the flood is bounded to the touched region. The naive version
(relight the block) is visibly slow at 16³ and should not be written even as a
placeholder.

**Light is authoritative on the server, and it travels baked.** The server
computes it during mapgen (§3, step 6) and maintains it on every edit; a block
crosses the wire with its light already in `param1`, and the client renders
what it was sent. The client runs the same propagation code for exactly one
purpose: relighting locally around an edit it is predicting (§7.1), so a torch
placed in a dark room lights up on the same frame instead of after a round
trip. That prediction is discarded when the server's delta arrives, on the same
path as the node itself.

The client therefore **never derives a received block's light from scratch**.
Saying so explicitly is worth the sentence: the alternative reading — both
sides computing light independently from node data — is a standing invitation
to the divergence class that §1's distinct coordinate types and §D3.1's
determinism rule both exist to prevent, and it would be invisible until a
player noticed one dark wall.

Lighting is the first thing to get wrong in a way that is invisible in tests and
obvious on screen, so it ships with a fixture set of known small worlds and
their expected light values.

### 4.1 M3 — what was built

`core/light.gene`, and the model above is unchanged: two 4-bit channels in
`param1`, day carrying sunlight *and* sources, night carrying sources only,
mixed by the time of day in §6's shader rather than baked into the mesh — which
is what makes a day/night cycle one uniform moving instead of a world remesh.

**The channels are flooded in place, not in scratch buffers.** The obvious
implementation floods two `dim³` buffers and packs them at the end; this reads
and writes a nibble with three arithmetic operations on a value the message send
already loaded. It is the difference between allocating 46 KB per block and
allocating nothing, which at the spike's 576 chunks is the whole of §D6.3's rule
applied to a stage that did not exist when the rule was written.

**Sunlight is a boundary condition the caller owns.** `light_region` is handed a
`dim × dim` `sky` buffer — the sunlight entering the top of each column — and
knows nothing about terrain. `fill_region` fills it while generating, because it
computes the surface height per column anyway. Deriving it inside the lighting
pass instead cost **5.5 ms a block** re-sampling a height lattice generation had
already sampled.

*A `light_filled_region` that derived the sky itself, for "a block whose nodes
came from somewhere else", was written and then deleted: the design has no such
block. §11 stores both parameter arrays alongside the content, and §4 above is
explicit that a client renders the light it was sent. Light travels baked, so
the only thing that ever computes it is the thing that generated the nodes —
which is the same sentence this section already used to rule out the divergence
class, applied to an API instead of to a client.*

#### Cost

| | ms per 16³ block, VM | ms per chunk, V8 |
|---|---:|---:|
| stages 1–4, nodes | 33.2 | 0.128 |
| **stage 6, light** | **24.8** | **0.018** |
| meshing | — | 0.076 |

Medians of three runs on an idle machine. The block a server stores is
**58.1 ms** of nodes and light together, against §D6.3's 300 ms and against the
76.9 ms one lane needs to stay ahead of a walking player (§3.3) — so lighting
spends about a third of the margin M2 had, and the budget still holds. The
client's figure is not the question: a chunk generates, lights, and meshes in
**0.22 ms**, worst chunk 0.91 ms against §D6.1's 8 ms.

**Getting there took one real optimisation, and the shape of it is the lesson.**
The first version pushed every node the sunlight column walk lit — thousands of
nodes per block whose six neighbours are all already at full sunlight, each
costing a push, a pop, and six neighbour tests to discover it has nothing to
give. A sunlit node can only brighten something if a neighbour is *darker*, and
under open sky the only darker neighbours are sideways: above is lit by the same
run, and below the run is the solid node that stopped it. Seeding only the
columns whose horizontal neighbours are still dark — the vertical faces of every
shadow, and nothing in the open — took a block from **38.9 ms to 15.1 ms**.

*A second optimisation was tried and reverted.* Dropping the queue's count for
the classic one-empty-slot ring is three message sends a pop instead of five,
and it made **no measurable difference** (15.1 vs 15.5 ms, inside the noise).
The queue is not what lighting costs; the six neighbour tests per popped node
are. Recorded in the file so the next reader does not spend the same hour.

#### Two measurement traps, both of which produced a number that looked real

- **`light_region` was measured at 164 ms** against a block that the probe's own
  `carve` and `place_all` timing loops had already run over sixteen times at
  sixteen origins. What they leave is not terrain — it is mostly air, and
  lighting mostly-air is a flood over the whole volume. A stage that reads a
  buffer has to be timed against a buffer something plausible produced.
- The light buffer is **reused across chunks in the client**, and the flood only
  ever *raises* a value, so a stale bright node from the previous chunk would
  never be corrected. A fresh block is zeroed by construction (§1); a reused one
  is not, and the zeroing is the caller's job.

#### What it did not do yet, and what M5 did about it

M3 shipped with **light not propagating between blocks**. Each region's flood
stopped at its own edge. For a heightfield that is exact — the caller knows from
the surface height whether a column's sky is open — and it was what the client
needed to draw a lit world.

Where it showed was **a cave that breaks the surface**: the block containing the
breach was lit down its shaft, and the block below started dark again. Upstream
lights a whole 5×5×5 chunk at once for exactly this reason. The fix was recorded
here as top-down column lighting across loaded blocks, wanting §11's block store
first, rather than worked around — because the workaround would be to relight
from scratch on the client and §4 is explicit that the client must never do
that.

### 4.2 M5 — the region stopped being a block

The fix turned out to be smaller than the description of it. Nothing about the
flood was wrong; the *region* was. `light_region` took one `dim` and was called
once per block, so a block edge was the only boundary it could have.

M5 gives it three dimensions instead of one, and the client keeps its whole
loaded world in one array (§1.1). One call then lights 12 × 4 × 12 blocks as a
single 194 × 66 × 194 box, and the boundary the flood stops at is the edge of
what is loaded. A shaft is lit to its floor; a torch lights across a block
border. **No line of the propagation changed** — the day and night floods, the
sunlight walk, the shadow-wall seeding, and the unspread/spread pair are all
what M3 wrote — and `probes/light_spec.gene`'s output is byte-identical before
and after, because its fixture worlds are cubes and a cube is the case where one
dimension and three agree.

`probes/loaded_spec.gene` asserts the new behaviour as a property rather than a
value: a one-node shaft through a two-block-tall world is full daylight at every
node of its depth, including sixteen nodes below the block boundary. Per-block
lighting cannot produce that, because the lower block's sky is not open — so the
number the old behaviour returns is 0, not "slightly different".

Two things this cost, both worth stating:

- **`dx × dz` is not the z stride.** In a cube the sky plane and the stride
  between z slices are the same number and were the same variable. In a box they
  are `dx*dz` and `dx*dy`, and confusing them transposes the sky.
- **A per-node registry call over a block is nothing; over a world it is
  everything.** `seed_sources_night` and `seed_sources_day` each scan the region
  calling `light_source_of` per node. At 4,096 nodes that is invisible. At 2.5M
  it is 5M cross-module calls to answer "no" 5M times, and the content set has a
  lamp registered so `any_light_source?` does not skip them. Hoisting the
  emission column — the same thing `flood` already did with `propagates` — took
  the per-chunk lighting figure in `tools/mesh_bench.mjs` from **0.076–0.081 ms
  to 0.031–0.032 ms**, reproducibly, across three runs each.

A world of 576 blocks opens in **114 ms** on V8: 55 ms to generate,
**24.7 ms to light all 2.48M nodes in one call**, 32.8 ms to mesh. See
`tools/world_build.mjs`, which is also where the two invariants are checked.

The lighting queue is sized to §4's contract — the region plus the ring's header
— which is 9.5 MB for that world. Measured, the initial flood never holds more
than **40,019 entries, 1.61% of the region**. The contract is kept rather than
the measurement, because an overflow raises and a raise at world open is worse
than 9 MB; the number is recorded so a future memory squeeze has somewhere to
start.

#### The incremental path, and how it is tested

§4's "should not be written even as a placeholder" is met: `relight_node` is the
two-pass unspread/spread pair, plus a third case neither pass covers. Sunlight
is a boundary condition rather than something a neighbour hands over, so a dug
hole would be lit to 14 by the open air beside it where a full relight sends 15
all the way down — `resunlight_column` restores it.

`probes/light_spec.gene` checks the floods against hand-derived values in six
small worlds, but it checks the incremental path against a *property*:
**relighting after an edit produces exactly what lighting the edited world from
scratch produces**, node for node, for a lamp placed, a lamp removed, a lit
floor dug through, and stone placed in open air.

That property found three bugs a value fixture would not have:

- the node was zeroed *before* the unspread pass read it, so `here` was always 0
  and the pass silently did nothing — the whole dimming half was dead code;
- unspreading past a torch put the torch out, because a node that emits light
  was treated as light derived from somewhere else;
- placing a node in open air left a lit column under it and cast no shadow, because
  full sunlight travels down *without* falling off, so the node below an
  unspread full-sun node holds an equal value rather than a dimmer one and did
  not look derived.

Each was wrong only in a case a hand-written fixture would have had to think to
include. The equivalence needed no such foresight.

## 5. Meshing

Per block, for the six faces of each non-air node, emit a quad when the
neighbour is transparent or absent. Neighbouring blocks must be loaded to mesh
correctly at the seams — a block meshes with a 18³ neighbourhood copy, not its
own 16³.

*M5: the neighbourhood is no longer a copy.* The mesher takes the array index of
the chunk's own `(0,0,0)` and the array's two strides, so it can read a chunk out
of any node array that has one node of readable shell around it. `chunk_base 1 1
1 18 324` is M3's padded neighbourhood expressed in that form, and
`tools/mesh_bench.mjs` still makes exactly that call. What the general form is
for is §1.1: the client keeps one array and meshes chunks straight out of it.

The reason it had to change is in §1.1 — a regenerated margin describes the
world as it was created, not as it is after a dig — and the change paid for
itself anyway: addressing the owner once and reaching its neighbours by `±1`,
`±sy`, `±sz` removed six index computations per node, and per-chunk meshing in
`tools/mesh_bench.mjs` went from **0.072–0.075 ms to 0.055–0.065 ms**.

Output is one vertex buffer per material (opaque, alpha-tested, transparent) as
typed arrays, ready to hand to WebGL without a conversion pass. Position,
normal, UV, and a per-vertex light value; **no per-vertex color** — light is a
single byte and the shader interpolates day/night.

*M3: built, at seven floats per vertex — position, UV, the packed light byte,
and the face's shading factor. The normal is not sent, because the only thing
§6's shader did with one is the directional shading, and that is one float
rather than three.*

*The light is the **neighbour's**, not the node's: a face shows how lit the air
in front of it is, and the node behind the face is solid and therefore dark, so
reading its own `param1` would draw every surface black. That neighbour is the
node `face_visible?` already tested, so the value is free. Flat per face rather
than smooth per vertex — smooth lighting averages the four nodes around each
corner, which is four more reads per vertex and a visible-but-not-structural
improvement, so the same logic that keeps greedy meshing out of M0 keeps it out
here.*

*The per-face shading factor stays, and is now a factor **on** §4's light rather
than a substitute for it. Upstream shades faces the same way and for the same
reason: with one light value per node and no normals in the shader, a cube lit
uniformly on all six faces reads as a flat silhouette.*

Transparent geometry sorts back-to-front per block; within a block it is not
sorted, which is what Luanti does and is fine for glass and water.

Greedy meshing (merging coplanar quads) is **not** in M0. It is a large constant
factor on the vertex count and a real complication for texture atlasing and
per-vertex light. M0 measures without it; if M0 passes, it stays out until
something needs it.

Meshing is the hot loop of the whole engine (§D6, §D10).

**M2: the mesher asks the registry rather than carrying a table.** §D6.1's
spike hardcoded "opaque unless id 0 or 5" and a five-entry tile table, which was
right for the four nodes it generated and wrong for anything a mod registers —
ids are assigned at load and mean nothing to a mesher (§2). It now reads
drawtype, opacity, and the three tiles out of the registry's columns.

Two questions, not one: **a face exists when its owner is *drawn* and its
neighbour is not *opaque*.** Collapsing them into one predicate was survivable
while no node was both drawn and transparent; it is what would make glass either
invisible or solid-looking the moment one exists.

That cost 5.6x on the first attempt — 0.084 to 0.468 ms/chunk — and the whole of
it was the `Int`/`bigint` boundary described in §D6.1's M2 update, plus a
cross-module call per lookup. With content typed `F32`/`F64` and the two columns
the loop needs hoisted out of the registry once per chunk, meshing is **0.071
ms/chunk** (median of three; 0.069–0.071): 16% *faster* than the hardcoded
version it replaced, over fifteen node types instead of five.

The full §D6.1 harness, on the same terrain M0 measured at the origin:

| | M0 | M2 |
|---|---:|---:|
| generate | 0.087 | 0.125 |
| mesh | 0.084 | 0.071 |
| **total per chunk** | **0.172** | **0.196** |
| worst chunk | 0.398 | 0.85 |

Generation costs 44% more for three stages M0 did not have, meshing costs less,
and the worst chunk is 0.85 ms against §D6.1's 8 ms budget.

## 6. Rendering

WebGL2, one program for terrain:

- vertex: model-view-projection, pass through UV, light, and face shading
- fragment: sample the atlas, multiply by interpolated day/night light, apply
  distance fog

*M3: the two channels are unpacked in the fragment shader, not in the mesher.
Mixing them by the time of day is a per-frame decision, so baking it into the
vertex buffer would mean remeshing the world at every sunrise; the byte travels
as-is and a `u_time_of_day` uniform does the mixing. A day/night cycle is
therefore one number moving. There is also a floor of ambient light under the
mix, because a 0 channel is pitch black and a voxel world with nothing visible
in shadow is unreadable rather than moody.*

One texture atlas, generated at build time from source tiles — the same
approach as `examples/new_world/src/atlas.gene`, which generates and writes a
PNG entirely in Gene. Mipmapping needs padding in the atlas or bleeding at
chunk edges; the padding is decided at atlas-build time, not worked around in
the shader.

Frustum culling per block. No occlusion culling in M0. Draw order is
front-to-back for opaque, back-to-front for transparent.

The camera is a standard first-person fly camera in M0 and gains collision in
M5.

## 7. Physics and collision

Axis-aligned boxes against the voxel grid, resolved per axis in order, which is
what makes stepping up a single node and sliding along a wall fall out for
free rather than needing special cases.

Player: gravity, jump, step height 0.6 (upstream's `PLAYER_DEFAULT_STEPHEIGHT`,
which is tuned and worth taking), and a swimming mode in liquid.

**The physics step runs on both sides** — the client predicts, the server is
authoritative and corrects. This is the §D3 payoff: one source, so a divergence
is a bug in one shared function rather than a mismatch between two
implementations of one rule. It is *not* a promise of identical bits — physics
is §D3.1's corrected half, and the server corrects because two runtimes are
entitled to disagree in the last place, not only because packets are lost. The
step is a pure function of `(state, input, world) → state`, which makes it
directly testable and directly fixture-able across backends.

Node selection is a voxel ray traversal (Amanatides–Woo), not a stepped
sample — stepping misses thin nodes at grazing angles and produces the
"can't click the block I'm looking at" complaint.

### 7.0 M5 — what was built, and one thing that was not

`core/physics.gene`, `probes/physics_spec.gene`, and the client walking on the
world instead of flying through it. Gravity, jump, sneak, a fly toggle,
swimming, and the world's edge as a wall.

**The resolver searches rather than solving.** The exact form computes the node
boundary the leading face crosses, which is four cases per axis and is where
this kind of code goes wrong. Instead: the position before a move is known
clear and the position after is known blocked, so twelve halvings find the
furthest clear fraction to within a quarter of a millimetre. No case analysis,
and the invariant it maintains is one sentence — *the player is never at a
blocked position* — which is what the spec asserts on every frame of every
fixture. A step costs 1.6 µs.

**The box is inset at its far edge and not at its near one.** Inset at both and
a player resting exactly on a floor can always move down by another `eps`, so
the resolver hands back a fraction of a node per frame and the player sinks
through the world at walking pace. That was a real bug, and the spec now stands
five seconds of standing still against it.

**There is no auto-step, and `PLAYER_DEFAULT_STEPHEIGHT` is why.** §7 above asks
for 0.6 and calls stepping up a single node something that falls out of per-axis
resolution. Both are right and they are about different things:

- 0.6 is under a node, so it climbs a slab or a stair and **cannot climb a whole
  node — in upstream either.** Walking into a one-node ledge in Luanti and
  having to jump is not a bug, it is this constant.
- What per-axis resolution does give for free is the jump: Y resolves before X,
  so a player who has cleared the ledge moves forward into open air and lands on
  it, with no code that knows what a ledge is.

An auto-step mechanism was written and then deleted, because §2's content set is
full cubes only: every ledge is exactly one node, 0.6 can never reach one, and
the code was unreachable and therefore untestable — M3's reason for deleting
`light_filled_region`, again. It comes back with M8's `nodebox` drawtype, which
is what makes a 0.6 step exist to be taken. **Raising the constant over 1.0 would
make walking the heightfield smoother and is a change to §7 rather than an
implementation of it, so it is not made here.**

A second consequence of upstream's constants, worth stating because it is the
number a player feels most directly: 6.5 m/s against 9.81 m/s² peaks at 2.15
nodes, so **a two-node ledge is inside a jump and a three-node one is not.** The
spec asserts both, so the height cannot drift unnoticed.

**`ignore` blocks movement, which §1 does not say.** §1 gives it as "never
walkable", which upstream implements as *not solid* — you fall through, because
upstream will have loaded the block by the time you get there. §1.1's loaded
world has a fixed extent and no such block coming, so the alternative to a wall
is falling out of the world forever. The wall sits one node outside the world,
where nothing can see it.

**Node coordinates are whole numbers and `core/loaded.gene` does not check.** A
fractional coordinate produces a fractional index, which a `(Buffer T)` reads as
`undefined` in the web profile: no error, no zero, a value that compares unequal
to everything and propagates. The client's spawn scan did exactly this — it
sampled the column at `x + 0.5` — and it *looked* fine, because the scan then
failed to find the surface and the player fell to it under gravity anyway.
`tools/world_build.mjs` caught it by walking the real generated world, which is
the thing a fixture spec cannot do: 7,200 frames across §3's terrain, its cave
mouths, its shoreline, and 576 block seams, asserting the same invariant.

### 7.1 Player edits under authority

Digging is the signature interaction of this genre and the one that feels worst
with a round trip in front of it. Node edits are server-authoritative and mod
code can change their outcome (protection vetoes a dig, `on_dig` replaces the
node with something else, stone drops cobble), so "just apply it locally" is
not available. The policy, stated rather than left implicit:

**Reject locally, apply optimistically, reconcile authoritatively.**

1. **Client-side rejection, no round trip.** Out of range, no target under the
   crosshair, unknown node, wrong tool for an undiggable node — the client
   already has the registry's client half (§2) and the raycast (§7), so it
   answers these itself, instantly. Most "nothing happened" cases never reach
   the network.
2. **Optimistic application of the visual result.** The client applies node →
   `air` for a dig, or node → placed for a place, immediately: remesh, particles,
   sound. This is right nearly always, because the *node* outcome is
   predictable even when the *drop* is not.
3. **Inventory waits.** Drops, wear, and stack changes are never predicted —
   they are exactly what mod code varies, and a hotbar that flickers the wrong
   item is worse than one that updates 80 ms late.
4. **Reconciliation on the server's delta.** Every edit carries a client
   sequence number and the server's node delta echoes it. On agreement the
   prediction is retired silently; on disagreement the server's value wins and
   the block remeshes. A delta whose sequence is older than a live prediction
   never overwrites it.

**In-process singleplayer collapses this to nothing.** The server call is
synchronous over the in-memory channel (§10), so the "prediction" is the real
edit and step 4 always agrees on the same frame. That is a second reason the
in-process server is the right structure and not just a code-sharing
convenience — the latency-sensitive path has zero latency in the mode most
players use.

Upstream's answer here is effectively "no prediction; the server sends the
result", which is a legitimate choice and simpler. We take the harder one
because M6 is a WebSocket away from the player rather than a LAN UDP socket,
and because rollback is bounded to one node and one block remesh.

#### M5 — what was built

`core/raycast.gene`, `core/edit.gene`, `probes/edit_spec.gene`, and the client
digging and building. M5 is in-process singleplayer, so the three-step dance
collapses exactly as this section predicted: there is no round trip to hide,
the edit *is* the prediction, and reconciliation agrees on the same frame. What
survives is **step 1** — the questions a client answers by itself: is there
anything there, may I build here, is it in reach, and would I be placing a node
inside myself.

**"rollback is bounded to one node and one block remesh" is the one sentence
above that M5 has to correct.** One node, yes. One block, no: changing a node
changes the *light*, and light is not local. Digging through a ceiling sends
daylight down a shaft and out sideways at every depth of it; a lamp lights a
ball fourteen nodes across. Whatever the caller has already turned into
geometry over that whole volume is now wrong, and a chunk it fails to rebuild
is a hole in the world that nothing reports.

So `apply_node` returns the region it could have invalidated. `relight_node`
does not report what it touched and should not start: the flood also runs at
world build over 2.5M nodes (§4.2), and a coordinate decode per changed node
belongs in neither. The region is **over-approximated from what the edit could
reach**, for seven reads and no work in the flood:

- light travels at most `light_max` from where it starts, so the box is the
  edited node grown by the brightest light *already next to it* — 0 in unlit
  rock, 15 at the surface;
- except downward, where sunlight does not fall off (§4), so the box first
  follows the column of nodes light can pass through and *then* grows.

Exact where that is cheap, generous where it is not, and never wrong. Measured
on §3's terrain: a twelve-node shaft dug down from the surface and a lamp
placed at the bottom cost **0.60 ms for thirteen edits, worst 0.40 ms**, and
name **9.2 chunks per edit on average, worst 12** — about 1.3 ms of remeshing,
inside a frame.

Two smaller decisions worth recording:

- **Liquids are not pointable, glass is.** §5's question — is this drawn — and
  §7's question — may this be pointed at — are different, and collapsing them
  either lets a player dig the sea or makes glass unclickable. Upstream leaves
  liquids unpointable for the same reason.
- **Looking and acting share a mouse button**, because the web profile has no
  pointer-lock binding. A drag turns the view; a click that travelled under
  four pixels digs or places. This is a shell limitation and not a design
  position — a pointer-lock binding (§D7) would remove it.

**Inventory and drops** are `core/inventory.gene` and `core/drops.gene`, plus
an eight-slot hotbar in the client. Three things about them are decisions
rather than code:

- **Items are node ids.** §2 gives items their own registry with tools, wear,
  and per-item stack limits; that registry is M7's, because it is a thing mods
  define. Until then everything a player can hold is a node they dug, so an item
  id *is* a content id and the hotbar hands it straight to the edit. The day
  items get a registry, `core/inventory.gene` changes in one place: what an id
  means.
- **A node drops itself unless the table says otherwise.** §2 puts drops on the
  server side, and the table holds *exceptions*. A default of "nothing" would
  mean a node whose drop nobody registered vanishes when dug, silently — which
  is the likeliest failure of a placeholder content set and the hardest to
  notice, because disappearing is half of what a dig looks like. The provisional
  set has exactly one exception, grass dropping dirt, and that one line is what
  makes the table worth having.
- **`core/drops.gene` is the server half sitting in `core/`, and says so.**
  In-process singleplayer *is* the server, so the process holding the client
  holds both halves. It is its own module rather than a column on §2's registry
  precisely so that M6 moving it is a matter of who imports it.

What is dropped and does not fit is lost. Dropped-item entities are §8's and
therefore M8's; a full inventory silently eating a dug node is the honest
placeholder, and it is the behaviour to revisit when entities exist.

`probes/edit_spec.gene` is 45 checks, and three of them are the file:

1. **The traversal never skips.** Over 312 rays fanned across a fixture, every
   hit is one step from the node the ray was in when it struck, on exactly one
   axis, with the first pointable and the second not. §7 rejects a stepped
   sample because it "misses thin nodes at grazing angles"; a stepped sample
   passes a head-on fixture and fails this.
2. **An edit's relight equals a full relight**, node for node, over seven edits
   including a lamp lit and unlit in a sealed cavern. M3's property, reused.
3. **The reported region contains every node that changed** — checked by
   copying both arrays before the edit and comparing all 32,768 nodes after,
   rather than by reasoning about the flood.

`tools/world_build.mjs` asks 2 and 3 again of §3's real terrain, and casts and
digs five nodes through the client's own path with the DOM removed.

And `tools/client_smoke.mjs` covers the part no module spec can see: that
`client/main.gene` connects them. It stubs the twenty host calls the client
makes and drives the real `main()` with synthetic events — a keypress reaching
the physics step, a click reaching the raycast and the edit, a dug node arriving
in the hotbar and a placed one leaving it, and a *drag* not digging, since
looking and acting share a button.

It exists because the browser kept being unavailable — a backgrounded tab
throttles `requestAnimationFrame` to nothing, `screencapture` returns black
without a recording permission, and the automation extension disconnected
partway through M5 and did not come back. It earned its place immediately: the
spawn scan walked down to the first *drawn* node, water is drawn, this site was
chosen for its coastline and is 23% sea, and the player was spawning afloat
about a quarter of the time. The scan now stops at the first node that blocks
and steps east until the column is dry.

#### And then the browser came back

Reinstalling the extension made a real tab available again, and everything the
stub asserts holds there too: a click digs, the drop that arrives is **dirt from
grass** — the drop table's one exception, live — a right-click spends it, a drag
turns the view without digging, and the reach limit stops a downward shaft after
five or six nodes because the sixth is past 5 nodes of arm.

Three things a real tab added that the stub could not:

- **166 fps**, drawing 229 meshes and 62,417 faces with physics running — and
  that is the display's ceiling, not the engine's: median frame interval 6.00 ms
  over 89 samples (166.7 Hz, vsync), slowest 7.6 ms, **none over 8 ms**. M0
  measured 121 fps over 186 meshes and 51,387 faces with no player in the world.
- **An edit costs 1.8–3.5 ms end to end** — relight, remesh, and GPU upload —
  against the 0.40 ms `tools/world_build.mjs` reports for the relight alone. A
  surface dig in daylight names **27 chunks**, more than the 12 the headless
  worst case found, because that run's later digs were already in shadow. Still
  a third of a 60 Hz frame at worst, but it is the number to watch if the region
  ever grows.
- **Cave mouths breaking the surface, lit** — from the air, the openings into
  the cave system are visibly continuous with the daylight above them. That is
  the exact case §4.1 recorded as broken (lit in one block, dark in the next)
  and §4.2 fixed, and it is the one form of confirmation the numeric properties
  cannot give.

**The recorded trap "fps cannot be measured through an automation tab" is too
strong and is corrected here.** A backgrounded tab does throttle to 6 fps, and a
screenshot forces a render so sampling the HUD right after one reports a burst —
both real. But activating the window first (`osascript -e 'tell application
"Google Chrome" to activate'`) makes `document.hidden` false, and the reading is
then stable and honest.

## 8. Entities

Server-authoritative active objects with a registry mirroring §2: an entity
definition has a visual, a collision box, and callbacks (`on_activate`,
`on_step`, `on_punch`, `on_death`).

Entities are transmitted to clients as add/remove/update messages within a
radius. Client-side interpolation between updates; no client-side entity logic.

Static (unloaded) entities serialize into the block they occupy, as upstream —
it is what makes an entity survive the block unloading under it.

M8. The player is not an entity in M5; making it one is a refactor M8 should do
deliberately.

## 9. The mod API

The point of the project (§D8).

A mod is **a Gene package** — `package.gene`, a `mods/<name>/` directory, real
imports, real modules. Not a directory of scripts sharing a global table.

```gene
# mods/default/src/main.gene
(mod default)

(import miclone/api [register_node register_craft register_abm])

(register_node "default:stone"
  ^description "Stone"
  ^tiles       ["default_stone.png"]
  ^groups      {^cracky 3}
  ^drops       "default:cobble")

(register_abm
  ^label     "Grass spread"
  ^nodenames ["default:dirt"]
  ^neighbors ["default:grass"]
  ^interval  6.0
  ^chance    50
  ^action    (fn [pos node]
    (if_yes (light_above_at_least pos 13)
      (set_node pos {^name "default:grass"}))))
```

Four things this gets that Luanti's Lua API does not:

1. **Capabilities instead of trust** (§D5). A mod declares the authorities it
   needs; the engine grants exactly those. A mod without `$fs/WriteDir` cannot
   write a file. Enforced by the runtime, not by review.
2. **Real modules and real imports.** Namespaced, with a dependency graph the
   package manager already resolves, instead of `dofile` and a shared global.
3. **Definitions as data.** A definition is a Gene node — inspectable,
   diffable, serializable, printable. `doc/lua_api.md` spends much of its
   12,777 lines describing table shapes; here the shape is a declared type and
   a wrong definition fails at registration with a position, not at the first
   dig.
4. **Formspec as data** (§13).

The API surface for M7 is the load-bearing subset of upstream's `core`
namespace: node/item/craft/entity/ABM/LBM registration, `get_node`/`set_node`,
the `VoxelManip`-equivalent bulk accessor, inventory manipulation, player
methods, chat commands, privileges, and the callback registry. Explicitly
deferred: HTTP, `core.request_insecure_environment` (which the capability model
replaces outright), and mod channels.

**Mod load order** follows `depends`/`optional_depends`, as upstream. Registration
happens at load; the registries freeze before the world starts, so §3's worker
lanes can capture them.

## 10. Protocol and networking

**WebSocket**, because it is the only persistent bidirectional transport Gene
can hold (§D2) and the only one a browser client can use.

The consequence is that everything is reliable and ordered, whereas Luanti's
transport offers unreliable channels for exactly the traffic that wants them —
player position updates, where the newest value makes older ones worthless.
Over TCP, a dropped packet head-of-line-blocks the fresh one behind it. The
mitigations are the ordinary ones: send position at a fixed low rate, make
every position message a full state rather than a delta so a late one is
merely stale, and keep block transfer on its own logical channel so a burst of
terrain does not delay movement.

This is a real regression from upstream and it is accepted on the browser-first
path.

**WebTransport is the answer, and the obstacle is on our side rather than the
browser's.** It gives exactly what the regression needs — unreliable,
multiplexed datagrams — and it has shipped across evergreen browsers for some
time now (Chromium since 2022, Firefox and Safari since). What it requires is an
**HTTP/3 server**, and Gene's is HTTP/1.1 (`src/gene/http_server.nim` answers
`HTTP/1.1 101 Switching Protocols` to upgrade a WebSocket). QUIC plus HTTP/3 in
Gene is a far larger item than the WebSocket server was — comfortably the
biggest thing in §D7 that isn't the FFI work.

So this is scheduled, not dismissed: **re-evaluate after M6**, once there is a
networked game whose measured jitter says how much the regression actually
costs. If it lands, §10's mitigations get simpler and the native shell (§D7.7)
inherits a transport it can share instead of needing its own.

Messages are Gene nodes encoded with the existing serialization layer
(`docs/serialization.md`) for everything except block data, which uses a packed
binary encoding (§D7.3) because 16 KB of nodes should not become a node tree.

*M6 note: this sentence needed transport that did not exist.* Neither end could
carry a byte — `ws_send` was text-only and an inbound binary frame was dropped
with no callback, no error and no close, and the web profile had no WebSocket
binding at all. All three are closed; see §D7.7, which also records the silent
handler-failure defect the work exposed.

Message groups: handshake and auth; registry sync (§2's client half, sent
once on join); block add/remove; node deltas; entity add/remove/update; player
input; inventory; chat; HUD.

**Singleplayer runs a server in-process** and connects to it over an in-memory
channel that presents the same interface as the socket. Upstream's decision, and
it is why there is one code path instead of two — and per §7.1, it is also why
the mode most players use has no round trip in front of a dig at all.

## 11. Persistence

A world is a directory:

```
world/
  world.gene        world metadata, seed, mapgen params, enabled mods
  map.sqlite        blocks, keyed by (x, y, z)
  players.sqlite    player state
  mods/             per-mod storage
```

SQLite because Gene already has `db/sqlite` and because upstream proved the
shape works. Block payloads are compressed (§D7.4).

The block format is ours, not upstream's, and it is versioned from the first
commit — a saved world outliving a format change is the normal case, not the
exception. It stores the content array, both parameter arrays, the per-block
`name → id` mapping (so a world survives mods being added, removed, or
reordered), node metadata, node timers, and static entities.

Writes are batched and asynchronous. A block is written when it is modified and
unloaded, or on a periodic flush.

### 11.1 M4 — what was built

`server/blockfmt.gene` (the format), `server/storage.gene` (the store), and
`probes/persistence.gene`, which is run **twice** — `create` then `verify` — in
two processes, because "quit and come back" is a claim about a process boundary
and a single process that writes and reads back cannot test it.

#### SQLite could not store a block, and now it can

§11 chose SQLite "because Gene already has `db/sqlite`". It did, and it could
not hold a block: `Db/execute` rejected `Bytes` with *unsupported parameter
type*, and a blob column was read back through `sqlite3_column_text`, which
stops at the first NUL and re-interprets the rest as UTF-8. Every block payload
would have come back truncated — silently, since nothing raised.

Blob binding and reading landed in `db/sqlite` for this. Three symbols and two
branches; the fiddly part is that a NULL data pointer binds SQL NULL whatever
the length says, so an empty blob needs a non-NULL pointer with zero length or
it reads back as `nil` rather than as empty `Bytes`.

That is the second time this milestone that a stated dependency turned out to be
half-present: §D7.3's `fs/write_bytes` existed and `fs/read_bytes` did not.

#### The format

Versioned from the first commit, as §11 asks. Magic, version, block dimension,
a flags byte, then a **per-block name table**, then the payload.

**The name table is the point of the header.** A block stores *names* for the
ids it uses, not the ids themselves, because §1 and §2 assign content ids at
load — add a mod and every id shifts. Without it, a saved world turns to stone
the first time the mod list changes. With it, loading re-resolves each name
through the current registry, and a name that is gone becomes `unknown`, which
§1 defines as drawn, walkable, and never deleted precisely so this case leaves
placeholders rather than holes.

It is per block rather than per world so a block is self-describing, which is
what lets §10 send one over the wire without a separate mapping to keep in step.

#### Size, and the compression question answered with numbers

| | bytes |
|---|---:|
| raw, three `u16` arrays | 24,576 |
| **run-length encoded** | **612 mean, 31 min, 4,669 max** |

A 40x reduction for about thirty lines, measured over 80 blocks spanning sky,
surface, shallow, and deep.

**Runs do not replace deflate, and assuming they would was wrong.** On the
busiest kind of block — at the surface, where terrain, water, and light all
vary — RLE gives 1,320 bytes and zlib on the same raw arrays gives **228**. So
§D7.4 is worth another **5.8x** on top of this, and §11 was right to specify
compression. RLE ships now because it is thirty lines against several hundred
for a Huffman coder, and because the flags byte is exactly how a versioned
format takes the better scheme later.

#### What the probe proves, and what it took to make it prove anything

`verify` regenerates every block from the seed and compares it against what came
off disk — a stronger check than a checksum, because it says *which* node
differs. The edits are what make it a persistence test rather than a determinism
test: terrain regenerates from a seed, so a world that only stored generated
blocks would verify identical whether the store worked or not.

Two versions of the edit failed to test anything, and both failures are worth
recording because each looked like a pass:

- the first dug **one node deep underground**, where the light was already 0. It
  differed by exactly one node and `param1` was never exercised — a store that
  dropped the light array entirely would have passed;
- the second added a lamp but placed it **in solid rock**, where it correctly
  lights nothing but itself, because §4's flood only enters a node that
  propagates light. A lamp needs somewhere for its light to go.

What ships digs a 3×3×3 pocket one node at a time, relighting after each exactly
as §7.1's dig would, and puts a lamp in the middle. `verify` requires 27 changed
nodes, the lamp back at 14, and its neighbour at 13 — the last being the check
that a *neighbourhood* of light survived rather than one value the lamp would
re-derive from its own definition on load.

`miclone:lamp` is registered in `core/content.gene` for this: it is the first
node that emits, nothing in §3 places one, so no terrain and no golden checksum
moved. M5's torch is this node with a placement rule attached.

#### Not built

`players.sqlite` and `mods/` — M5 and M7 own them, and a table nothing writes is
a schema to migrate rather than a feature. Writes are batched (a transaction, so
a crash leaves the world as it was rather than partly saved) but not
asynchronous; that wants the scheduler and a tick to hang a flush off, which is
M6.

## 12. Time, tick, and the server loop

Server tick at a fixed rate (upstream defaults to ~10 Hz for environment steps,
with the client interpolating). Per tick: run node timers, run due ABMs on
loaded blocks, step entities, apply queued player input, propagate liquids,
flush lighting updates, send deltas.

ABMs are sampled, not exhaustive — a block picks a random subset of positions
per interval. This is upstream's approach and it is what keeps "grass spreads"
from being O(loaded world) every tick.

Client renders at display rate and interpolates; it does not tick the server
model.

## 13. UI

Luanti's formspec is a string DSL:

```
size[8,9]list[current_player;main;0,4.85;8,3;]
```

Mods build it by concatenating strings, which is why escaping bugs and layout
bugs are common, and why it cannot be inspected or composed.

Ours is Gene nodes:

```gene
(formspec ^size [8 9]
  (inventory_list ^location :current_player ^name "main"
                  ^pos [0 4.85] ^size [8 3])
  (button ^pos [3 8] ^size [2 1] ^name "close" ^label "Close"))
```

Composable, inspectable, and validated at registration. Rendered by the client
as DOM overlaying the canvas — which is a thing the browser shell makes easy and
a native shell will have to reimplement (a cost §D8's M9 owns).

The HUD (hotbar, health, breath, crosshair) is DOM as well, except the
crosshair.

## 14. Testing and verification

Four layers, and the second is the one that matters most here.

1. **Unit fixtures** for pure core functions — lighting propagation, meshing
   output, physics steps, ray traversal, the codec. Table-driven, in the
   repository's existing style.

   *M3: `probes/light_spec.gene`, 34 checks over six hand-derived worlds. Its
   most useful assertions are not values but an equivalence — incremental
   relight must equal a full relight, node for node — which found three bugs
   that a fixture of expected numbers would have had to anticipate to catch
   (§4.1).*
2. **Cross-backend fixtures.** Every `core/` module runs the same inputs on the
   VM and through the web profile. This is the mechanism that keeps §D3 honest,
   and it is why the shared-fixture harness is a dependency of the project
   rather than a nice-to-have. The assertion differs by half, per §D3.1:
   - **exact half** (mapgen, noise, and everything feeding terrain) asserts
     **bit-identical** output. One differing bit fails CI.
   - **corrected half** (physics, prediction, entity motion) asserts agreement
     to a stated tolerance *and records the observed max divergence*, so a gap
     that grows is still a signal even while every run passes.

   A fixture that cannot say which half it is in is a fixture whose author has
   not decided, and that is the failure this layer exists to catch.
3. **Golden worlds.** A seed and a chunk position produce a known checksum. A
   mapgen change that alters terrain has to change the golden value
   deliberately, in the same commit, with a reason.

   *M2: built, in `probes/mapgen_spec.gene`. Four blocks — one spanning the
   surface, one deep enough to be all rock and cave, one far from the origin so
   the hash is not only asked about small coordinates, and one on a second seed
   so that the seed is demonstrably not decorative. The checksum is a 32-bit
   rolling hash in `core/exact.gene`'s discipline, so it is order-sensitive and
   both backends compute it identically by the standard rather than by luck.*
4. **A headless server + scripted client** for the protocol: join, load blocks,
   dig, place, disconnect, reconnect, and find the world unchanged. It also
   covers §7.1's reconciliation, including the case that only shows up under
   authority: a mod vetoing an edit the client already applied optimistically,
   and the rollback that follows.

Performance is a standing gate, per `AGENTS.md`: meshing time per chunk,
mapgen time per chunk, frame time at a fixed view distance, and server tick
time at a fixed player count. **Mapgen time per chunk and server tick time are
the two to watch** — §D4 and §D6.3 both say the ceiling is there rather than in
the frame budget. Regressions are reported with numbers, not hidden.

---

# Appendix A — Upstream source map

What to read while implementing each part. Paths are relative to
`examples/miclone/luanti/`.

| this design | upstream |
|---|---|
| §1 world model | `src/mapnode.h`, `src/mapblock.h`, `src/map.cpp`, `src/constants.h` |
| §2 registries | `src/nodedef.{h,cpp}`, `src/itemdef.{h,cpp}`, `doc/lua_api.md` "Nodes", "Items", "Groups" |
| §3 mapgen | `src/mapgen/` (`mapgen_v7.cpp` is the one to read), `src/noise.cpp`, `src/emerge.cpp` |
| §4 lighting | `src/voxelalgorithms.cpp`, `src/light.cpp`, `src/reflowscan.cpp` |
| §5 meshing | `src/client/content_mapblock.cpp`, `src/client/mapblock_mesh.cpp` |
| §6 rendering | `src/client/clientmap.cpp`, `src/client/shader.cpp` |
| §7 physics | `src/collision.cpp`, `src/localplayer.cpp`, `src/raycast.cpp` |
| §8 entities | `src/serverenvironment.cpp`, `src/content_sao.cpp`, `src/client/content_cao.cpp` |
| §9 mod API | `doc/lua_api.md` (all 12,777 lines), `src/script/`, `builtin/` |
| §10 protocol | `doc/protocol.txt`, `src/network/networkprotocol.h`, `src/network/{server,client}packethandler.cpp` |
| §11 persistence | `doc/world_format.md`, `src/database/`, `src/serialization.cpp` |
| §12 server loop | `src/server.cpp`, `src/serverenvironment.cpp` |
| §13 UI | `doc/lua_api.md` "Formspec", `src/gui/guiFormSpecMenu.cpp` |

# Appendix B — Repository layout

```
examples/miclone/
  package.gene            library + applications, as examples/new_world
  docs/design.md          this file
  luanti/                 reference clone (gitignored)
  core/                   portable Gene — VM and web profile
    world.gene            §1
    registry.gene         §2
    mapgen/               §3
    light.gene            §4
    mesh.gene             §5
    physics.gene          §7
    protocol.gene         §10
  server/                 VM only
    main.gene  storage.gene  env.gene  mods.gene
  client/                 web profile
    main.gene  render.gene  input.gene  hud.gene
  mods/
    default/              the game, built through §9's API
  assets/                 source tiles; the atlas is generated
  tests/
    fixtures/  golden/
```
