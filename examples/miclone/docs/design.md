# Miclone — Design

A voxel game engine with Luanti's architecture, written in Gene, whose mod
language is Gene.

**Status: M0 through M7's API are built and running.** §D8's table says which
milestone owns what and which are done.

## How to read this document

It is two things at once, and keeping them apart is what makes it usable.

**The design is what was decided in advance.** Part I (§D1–§D10) is the
direction: what "clone Luanti" means here, the constraint that shaped
everything, and the phases. Part II (§1–§14) is the system, part by part. Read
§D2 before believing any of the rest, because §D2 is the constraint the rest
answers to. Appendix A maps each part to the upstream source worth reading while
implementing it.

One numbering quirk: **§D7.*n* means item *n* of §D7's backlog list**, not a
subsection — §D7.11 is "the AOT lowerable subset", the eleventh entry. Every
other `§x.y` is a real subsection.

**The results are recorded inline, under the section that predicted them** —
including the ones that came out wrong. §D6.3 predicted worldgen throughput
would be fine and it was off by 1,008x; that failure is under §D6.3, in its own
words, with the number. A design paragraph and its result note may disagree, and
where they do the result note is what happened. The convention is deliberate: a
document that quietly edits its predictions to match its outcomes cannot be used
to judge whether the reasoning was any good.

So a section reads: the design, then *M-something: what was built*, then what it
cost and what it did not do. If a section has no result note, nothing has been
built for it yet and it says so.

**Where to find each milestone's result:** M0's three probes are §D6.1–§D6.3;
M1 is §1 and §2.1; M2 is §3.3–§3.5; M3 is §4.1 and §5; M4 is §11.1; M5 is §1.1,
§4.2, §7.0 and §7.1; M6 is §10.1 and §12.1; M7's API is §9.1. §6.1 and §13.1
cover the renderer and the HUD, which no single milestone owns. §D10.1 scores
the five risks Part I named, and §D7 is a running list of what the *language*
gained along the way — which is the other half of what this project is for.

### What earlier revisions changed

Revision 2 answered a review of revision 1: the same-source claim was narrowed
to *same algorithm, not same bits*, and §D3.1 turned that into an explicit
exact/corrected split; M0 grew from one probe to three (§D6), adding a
cross-backend FP divergence probe and a server worldgen throughput probe;
§D7.2's packed `Buffer` was re-justified against consumers that exist; §7.1
gained the latency policy for player edits under server authority; and §10's
dismissal of WebTransport was corrected — the obstacle is Gene's HTTP/1.1
server, not browser support.

Everything after revision 2 is a result note rather than a revision. The design
has been wrong in places and those places say so where they stand.

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

### D5.1 The sentence above is not true yet, and the reason is not the loader

Measured while starting M7's loader, and it corrects a claim this section has
stated as fact since revision 1.

**"A mod that never receives `$fs/WriteDir` cannot write a file no matter what
it evaluates" is false today**, and no loader can make it true by declining to
pass a capability. Any module may simply ask for one:

```gene
(import $fs [write_text WriteDir])
($fs/write_text $fs/WriteDir "/tmp/anything" "written")
```

That runs, and it writes the file. **And the `import` line is not even
load-bearing** — the same two calls work with it deleted, because `$fs` resolves
straight from the builtins root:

```gene
($fs/write_text $fs/WriteDir "/tmp/anything" "written")   # no import, still writes
```

Capability *values* are real — `fs/write_text` does require a `$fs/WriteDir` and
refuses without one, so the check at the call is genuine — but the value is not
scarce. It is ambient, so requiring it stops an accident and not an adversary.

That second measurement matters because it rules out the cheap fix. A loader
could scan a mod's source for forbidden `import` forms and refuse to load it;
that would be a static check needing no VM change, and it would be worth
nothing, because a mod that never writes `import` reaches the filesystem
anyway.

The mistake was reading `gene run --grant` as a sandbox. It is not one: it
evaluates expressions and passes them to `main` as named arguments, which is a
convenience for an application's *own* entry point and does nothing about what
that application imports.

**So the sandbox is at the import boundary, not the argument list.** Every module
root is `newGlobalScope(app)`, whose parent is `app.builtinsScope()` — the one
shared root holding both the language builtins and the capability namespaces. A
mod loaded into that scope has the filesystem whatever it is handed.

The shape that follows is now the *only* one: **a sandboxed module gets a module
root parented to a restricted builtins scope**, in which each denied capability
namespace is shadowed by an empty one, so a mod naming `$fs` at all fails at
load rather than succeeding quietly. A manifest's grants become the namespaces
*not* shadowed. It is small in concept, and it is unbuilt and unverified against
the VM's scope internals — stated here as the thing to build, not as a design
that has been tested.

The reason it is the only shape: the two alternatives are both measured out. A
loader that withholds capability arguments does nothing, because the mod can
name them; a loader that audits `import` lines does nothing, because the mod
need not write one.

Two consequences worth stating plainly:

- **M7's loader is a security feature, and it is the whole of §D5's advantage
  over Luanti.** Runtime module loading on its own is the easy half; without the
  restricted root it would give miclone Lua's trust model with Gene's syntax,
  which is strictly worse than what exists now — today `mods/default` is
  compiled in and audited by being in this repository.
- **§D5's advantage is a claim about a language feature that does not exist**,
  rather than about one that does. It is still the right bet — capability values
  are real, the boundary is one scope, and nothing about the design is wrong.
  But it is a thing to build, and this document said it was a thing to use.

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

**6. Vector/matrix math (pure Gene). Blocks M0. Landed, and it stayed in the
game rather than becoming a library.**
`$math` has the scalars. `vec3`, `mat4`, AABB, and a ray-vs-voxel traversal are
library code, all `F64` per §D4.

*Landed as `core/vec.gene` and `core/raycast.gene`.* Between them: `mat4`
identity, perspective, view and multiply; `vec3` length; a yaw/pitch forward
vector; and the Amanatides–Woo voxel traversal §7 asks for. The AABB half is not
a module — `core/physics.gene` resolves the player box against the grid per axis
and never needs a general box type.

**It has not been promoted to a Gene library, and that is deliberate rather than
pending.** The matrices are written into a caller-supplied `(Buffer F32)` and
are 4x4 column-major because that is what `uniformMatrix4fv` takes, and the
traversal returns into a caller-supplied `(Buffer F64)` because §7.1 runs it
inside a click handler and a returned record would allocate. Both shapes are
right for this engine and wrong for a general library, which would want values
and returns. Promoting it means designing that trade, and the second consumer
that would pay for it does not exist yet.

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

*M8: **landed, and much smaller than "the same tier as WebGL2".*** Two bindings
rather than dozens: `$audio/tone` (frequency, duration, gain) and
`$audio/noise` (duration, gain). Each builds three Web Audio nodes, ramps the
gain to silence rather than cutting — an oscillator stopped mid-cycle is a click
that sounds like a bug — and discards them.

The estimate was wrong in a useful direction. A game needs a thud when you dig
and a tone when you place, and those are two calls; the *graph* — filters,
panning, scheduled music — is what a mod authoring a soundtrack needs, and it
can be added later without changing these two. `client/sound.gene` is the whole
of the game's audio and is 40 lines, procedural for exactly the reasons
`client/atlas.gene` gives: no asset to fetch, no load event, no file whose
source nobody has.

One browser rule shapes the code: a context created before the user has
interacted with the page is not an error, it is a context stuck in `suspended`
that never plays. So the context is made on the first sound, which by
construction is a click or a keypress.

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

**12. `Buffer/len` answers a different type on each backend. Found by M6.
Small, and open.**

The VM returns an `Int`; the web profile's underlying `.length` is a `number`,
which is `F64`. Arithmetic coerces on both, so using a length as an *operand*
works either way and nothing noticed for four milestones. Using it as a *value*
— passing it to an `F64` parameter — fails on whichever backend you did not
try.

**It is `~ len` specifically, and that is what makes it a defect rather than a
fact of life.** A buffer *read* is `Int` on both backends, so `($to_float (b ~
get i))` is the ordinary conversion and compiles everywhere;
`core/wire.gene` and `core/protocol.gene` use it throughout without comment.
`~ len` is the one operation in the portable surface whose type depends on which
side you are on.

**What makes it worth an entry rather than a shrug is that the obvious fix does
not exist.** `$to_float` is total on numbers on the VM ("Int or Float") and
deliberately partial in the profile, which rejects a value already of the target
kind — its comment says a no-op conversion "would compile here and mean
something else on the VM". So `($to_float (b ~ len))` fails on the *web*, the
bare form fails on the *VM*, and **no single spelling of the conversion
compiles for both**. That is a portability hole in the one operation whose
entire purpose is to be portable.

The workaround is `(+ 0.0 …)`: mixed arithmetic promotes to Float on the VM and
is a no-op on a JavaScript number. `core/wire.gene` wraps it once as `byte_len`
and says why, rather than spreading the idiom.

The fix is for `Buffer/len` to answer the same type on both sides. `F64` is the
right choice and matches §D7.1's reasoning for indices and lengths — an `Int`
length is a `bigint` in the profile — but it is a VM-surface change with
existing callers, so it wants doing deliberately rather than inside a game
milestone.

**13. Named parameters in the web profile. Blocked M7. Landed.**

`^name : T` was a VM-only parameter form: a module function declaring one failed
to transpile. That is a small hole with a large consequence, because `^name` is
where argument ergonomics belong for a *registration* API — `core/registry.gene`
had said so in a comment since M1 — and §9's mod API is nothing but
registrations. Ten positional parameters is a shape only its author can read,
and a definition is read far more often than it is written.

The hole ruled out a shape rather than a spelling, and both ways around it were
worse. A positional mod API would have been no better than the `register` it
wraps, which is most of §9's point. A VM-only one would have been consistent
with §D5 — mods run on the server — but would have retired the in-tab client,
since `client/main.gene` generates its world in the browser and needs the same
content set a mod defines.

*Landed.* The profile takes named parameters on **module functions**, with
`^name local : T` and `^name : T?` as on the VM, and lowers them to ordinary
positional JavaScript slots in declaration order — the profile knows every
callee statically, so a call's props are placed into their slots during
analysis. No options object and no allocation, which matters because this
codebase's hot paths refuse one; and an exported function stays positionally
callable from JavaScript, which is what the `.mjs` harnesses do. Four refusals
fall out of the lowering and each is a source-located diagnostic: no named
parameters on a `message`, `ctor`, extern or callback, since an `(Fn [A ...] R)`
type has nowhere to put a name; no positional parameter after a named one; no
function-with-named-parameters used as a value; and no defaults, since `: T?` is
the spelling for optional.

**It also closed a silent divergence, which is the part worth remembering.**
Props on a call were being *dropped*: `(add 1.0 2.0 ^oops 9.0)` compiled and
threw `^oops` away, while the VM raised `got unexpected named argument` for the
same source. No fixture could see it because the profile emitted working code —
which is the exact failure mode §D3.1's rule exists to prevent, found four
milestones after the rule was written. Nine cases in
`tests/transpile/fixtures.json` hold the contract now, four of them asserting
that both backends refuse the same source. Language `docs/web-profile.md` and
`docs/design.md` §7.11 state the surface.

**14. Neither backend re-exports an imported binding the same way. Found by M7.
Small, and open.**

`core/api.gene` was written to be a mod's only import: it would import the tile
kinds, drawtypes and ore shapes from the engine modules and a mod would import
them from it. That compiles in the web profile and fails on the VM with
`module/namespace has no export`.

The profile allows it because a `let` constant is a literal, so importing one
*copies the value* rather than referencing the other module — and a copied value
is trivially re-exportable. The VM resolves an import against a module's own
exports, and a binding that arrived by import is not one. **A *type* re-exports
on neither**, which is a third behaviour again.

This is §D7.12's shape exactly — one operation in the portable surface whose
meaning depends on which side you are on — and it has the same tell: the code
that hits it looks completely ordinary. The workaround is to import a constant
from the module that defines it, which is what `mods/default` does in three
extra lines, and which has the accidental virtue that every import names where a
number is defined rather than where it was passed through.

The fix wants a decision rather than a patch, because there are two defensible
answers and they differ in kind. Making the **profile refuse** it matches the VM
today and is the safe direction — it turns a silent acceptance into a
diagnostic, which is what item 13 did for props on a call. Making the **VM
re-export** is the more useful language and is how most module systems behave,
but it is a semantics change with a visibility question attached (is every
import re-exported, or only a declared set?). It should not be settled inside a
game milestone.

**15. The web profile cannot iterate a `PropMap`. Found by §2's groups. Small,
and open.**

`(for [k v] in m ...)` over a `PropMap` is rejected: "web for cannot iterate
PropMap". The profile has `get` and `size` on one, so a map can be *read* by a
key already known and cannot be walked.

It costs a spelling rather than a capability. §2 writes a node's groups as
`^groups {^cracky 3 ^falling_node 1}`, which is upstream's shape and the one a
registration site wants; a portable API cannot accept it, so `register_group`
takes one group per call. That is not a bad API — each rating is independently
diagnosable, and it matches `register_tile` and `register_drop_rule` — but it is
a shape chosen by a compiler gap rather than by design, which is the thing worth
recording.

Neither backend is wrong here; the VM iterates a map and the profile does not
yet. The fix is an iteration lowering for `PropMap`, and it is the same class of
work as §D7.13's named parameters — a portable form that exists on one side and
should exist on both.

**16. A tick hook on the HTTP serve loop. Blocked M8. Landed.**
§12's server tick needs to run alongside a blocking `serve`. The loop already
polled with a computed timeout, so this is `^on_tick` plus `^tick_ms`: the tick
deadline joins the ones the timeout is already clamped against, the callback
fires before events so a busy socket cannot starve it, and once per period
rather than once per missed period — a server that fell behind should not run
the world at double speed to catch up. A throwing tick is reported and the loop
continues. `^on_tick` without a positive `^tick_ms` is refused rather than spun
on, and `^tick_ms` without `^on_tick` is refused rather than ignored.

**17. `Callback` was a profile-only synonym for `Fn`, and the gap it was
credited with did not exist. Found by M8's ABMs. Diagnosed wrongly, then
measured. Closed.**

*What this entry said until it was measured:* "The VM rejects a nominal type
inside a `Callback` annotation. `(Callback [Game World F64 F64 F64] Nil)`
compiles for the web profile and fails on the VM with `unsupported type
annotation`." It was recorded as the reason §9's `^action (fn [pos node] …)`
could not be built and the reason §8's entities had no `on_step`, and on that
basis two features were shipped as vocabularies instead of APIs.

**Both halves of the diagnosis were wrong**, and four measurements say so:

| source | VM | profile |
|---|---|---|
| `(Callback [F64] F64)` — no nominal type at all | **raises** | works |
| `(Callback [Box] F64)` | **raises** | works |
| `(Fn [Box] F64)` | works | works |
| `(Fn [Game World F64 F64 F64] Nil)` — §9's exact shape | works | works |

It is not about nominal types: the VM rejects **every** `Callback`, including
one carrying nothing but `F64`. And it does not reject it at the declaration —
the annotation is accepted there and raises at the first call that passes a
function *through* it, which is the latest moment available and the reason the
original diagnosis went to the wrong place. A function type has been in the VM
all along under the name **`Fn`** (`vm.nim`, the `"Fn"` arm of `matchesTypeExpr`)
with variance, generics, named parameters and error rows; `web.nim` accepted
`Callback` *and* `Fn` as spellings of one thing. So the portable spelling
existed, was already implemented on both sides, and the annotation had simply
been written with the profile-only one.

**The fix is that the profile drops `Callback`.** One spelling means one thing
on both backends, which is §D3.1's rule applied to the type surface. It has to
be an explicit refusal rather than a deletion: `parseWebType`'s last case reads
any `(Head …)` as a nominal type, so removing the arm would have made
`(Callback [A] R)` compile as a nominal type *named* `Callback` and emit working
code. `tests/transpile/fixtures.json` holds the refusal, and the profile's own
`typeName` now prints `Fn` so a diagnostic never names a spelling the reader
cannot write.

**What it unblocked, immediately:** §9's `^action` on `register_abm` (§12.2) and
§8's `on_step` and `on_activate` on entity definitions (§8.1) — the two features
this entry was cited as blocking, both built in the same commit as the
measurement, neither needing a VM change.

**The lesson is the one §D5.1 already taught and this project keeps relearning:
a recorded blocker is a claim, and a claim that has never been measured is not
evidence.** This one cost a milestone of API surface. It was a *narrower* claim
than the truth ("a nominal type inside `Callback`") which made it sound
investigated, and the fix was a one-word change in the source it blocked.

## D8. Delivery phases

Each milestone ends in something runnable. No milestone is "infrastructure
only" — that is how a project like this quietly becomes a year of plumbing.

| | milestone | ends with | needs |
|---|---|---|---|
| **M0** | **The three probes (§D6)** | fly through a static voxel world at 60 fps, plus a decided determinism rule and a measured worldgen cost | backlog 1, 6 |
| ~~M1~~ | **World model + registries — done** | §1 and §2, the second completed after M7 (§2.2); 69 + 74 cross-backend checks | — |
| ~~M2~~ | **Mapgen — done** | biomes, caves, and ore, drawn by the M0 renderer; §3 | backlog 5 |
| ~~M3~~ | **Lighting + meshing in `core/` — done** | the M0 renderer drawing a generated *lit* world; §4, §5 | backlog 2 |
| ~~M4~~ | **Persistence — done** | quit and come back to the same world; §11 | backlog 3 (landed), 4 (open, not blocking) |
| ~~M5~~ | **Player: physics, dig, place, inventory — done** | a playable singleplayer creative-ish loop; §1.1, §4.2, §7, §7.1 | — |
| ~~M6~~ | **Client/server split over WebSocket — done** | the same game, client and server as separate processes; §10, §10.1 | backlog 7 (browser half landed) |
| ~~M7~~ | **The mod API — API done, loading not** | the game is `mods/default`, defined through §9's surface and drawn from recipes on the wire; §9.1 | — |
| ~~M8~~ | **Entities, crafting, UI, sound — mostly** | §12's tick, trees, crafting, dropped items, sound, a formspec, and the mod callbacks the rest were written around (§8.2, §12.3); §8.2 names what entities still lack | backlog 9 (landed) |
| M9 | Native shell | the same game outside a browser | backlog 7, 8 |

M7 is the point of the project. Everything before it is the engine a mod API
needs in order to be worth having, and M8's "small but complete game" should be
built entirely through M7's API — if it needs an engine change, the API is
wrong.

M8 shipped in seven slices and is the first milestone that is *partly* done
rather than done or not: §12's tick (§12.2), §3's decorations (§3.6), crafting
(§2.3), dropped items (§8.1), sound (§13.2), a formspec (§13.3), and — last —
the **callbacks** the first six were written around (§8.2, §12.3).

That last slice is the one worth reading the history of. The first six shipped
with entity callbacks and mod-supplied ABM actions recorded as *blocked*, by
§D7.17, in four places. They were not blocked: the annotation had been written
with a spelling only the web profile knew, and the VM has had the capability all
along under another name. Measuring it took twenty minutes and unblocked both
features at once. **The absence in §D8's table was a claim nobody had tested**,
and it is the second time this project has found one of those — §D5.1 was the
first, and it is still open.

What M8 does not have: entity **rendering** and §13's **input**, so no chest and
no furnace; `on_punch` and `on_death`, which would be fields nothing could call
until something can hit an entity. §8.2 and §13.3 say which and why. A player
still cannot see another player, which is the clearest statement of what is
left, and it is now a rendering problem rather than a callback one.

M7 shipped in two halves and only one of them is done (§9.1). The **API** is
built: the game is a mod, registration goes through a surface, definitions are
data, and a client draws mod content from recipes on the wire without running
mod code. The **loading** is not: the mod is compiled in rather than read off
disk, so §D5's capability model — the thing that makes this mod API better than
Luanti's rather than merely different — is still a claim about a loader that
does not exist. Runtime module loading lives inside the VM and is not reachable
from Gene; exposing it, with capabilities attached, is what closes M7.

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

### D10.1 How the five turned out

Through M7's API. One of the five materialised, and it is the one that was named
as the likely ceiling — which is a better record for the *naming* than for the
mitigations.

**The subset constraint held, and the way it held is the finding.** `core/` is
23 modules compiling for both backends, and not one of them needed a
conditional. But it did not hold by being avoided: it held because **Gene grew
every time it did not fit**, and §D7 is the list — seventeen items, of which
nine landed on the way through. Typed buffers, `$to_float` in the portable
stdlib, loop bodies as scopes, integral Floats as indices, a WebSocket client,
`a/~b` in the profile, named parameters: each was a place the subset was about
to fail, and the fix went into the language rather than into a workaround. That
is the project's stated purpose (§D1) doing its job, so the risk converted into
the deliverable.

The mitigation as written — a shared fixture per module from the day it lands —
also worked, and it is what turned most near-misses into a compile error with a
position rather than a divergence found by a screenshot. **Twice it did not**,
and both escapes are the same shape: §D7.12's `Buffer/len` and §D7.14's
re-export are operations whose *type* or *legality* differs by backend while the
source looks ordinary, so a fixture that ran on both sides never exercised the
difference. §D7.13 found a third — props on a call dropped silently in the
profile — four milestones after the rule that forbids it. The lesson the
fixtures did not teach on their own: **a cross-backend fixture proves the code
you wrote agrees, not that the code you could have written would.**

**Meshing was not too slow, but the first attempt was 5.6x too slow and the
reason was not meshing.** 0.084 → 0.468 ms/chunk on M2's registry-driven
rewrite, all of it the `Int`/`bigint` boundary (§D6.1's M2 update), and the fix
was in the source rather than the compiler: float-typed columns and two
registry lookups hoisted per chunk. It now runs at **0.071 ms/chunk**, 16%
faster than the hardcoded five-node version it replaced, over fifteen node
types. The mitigation — "it is exactly what M0 measures, before anything
depends on the answer" — is the reason this was a bad afternoon rather than a
rewrite of M3.

**A sixth risk went unnamed, and it is the one that bit — twice.** §D5 asserted
a security property as a thing to use rather than a thing to build, and §D5.1
found it false four milestones later. The five risks above were all about
whether the engine would *work*; none was about whether a claim in this document
was *true*. The mitigation that would have caught it is the one this project
already applies to everything else — measure it before depending on it — and §D5
was never measured because nothing had to depend on it until M7.

Then it happened again, in the opposite direction and inside a milestone rather
than across four. §D7.17 recorded a **compiler gap that did not exist**: the VM
was said to reject a nominal type inside a `Callback` annotation, and on that
basis §9's `^action` and §8's entity callbacks were both shipped as fixed
vocabularies with paragraphs explaining that the compiler left no choice. The
annotation had been written with a spelling only the web profile knew; the VM
has had function types all along under the name `Fn`. Twenty minutes of
measurement unblocked two features.

**The two failures are the same failure and the pair is what makes it a
pattern.** §D5.1 was an unmeasured claim that something *worked*; §D7.17 was an
unmeasured claim that something *did not*. Both were narrow enough to sound
investigated — "a mod that never receives `$fs/WriteDir`", "a nominal type
inside `Callback`" — and a specific-sounding claim is exactly the kind nobody
re-checks. The rule this project keeps having to relearn: **a blocker written
down is a hypothesis, and the cheapest moment to test it is when you write it.**

**Determinism held exactly, and the exact/corrected split was never tested in
anger.** §D6.2 found **zero differing bits** over 323 samples, and the mapgen
checksums have agreed on both backends at every commit since. The stated failure
mode — mapgen becomes server-only — was never needed. Worth being honest about
what that does and does not prove: both backends run on one machine and one
libm here, so this is evidence the *algorithm* is bit-stable, not that every
future host will be. §D3.1's rule and the fixtures that enforce it stay.

**Server throughput was the ceiling, and it is still the ceiling.** This is the
risk that came true, twice, and worse than written. §D6.3 missed its budget by
**1,008x** and the finding was not that noise is slow — it is that a single
message send is ~500 ns, so the *unit* was wrong; §3.1 changed the generation
unit from an 80³ chunk to a 16³ block in response. Then M6 met the same wall
somewhere new: **17.9 ms to encode one block message on the VM against V8's
0.032 ms, 558x**, which is what makes a world take ~12 s to transfer and is why
§10.1 says the socket was never the bottleneck. The mitigation ladder was
climbed as far as it goes without new engine work — packed `Buffer` landed,
typed functions landed, the noise stack lowers through AOT — and **§D7.11's AOT
path is the rung that is left**. The frame rate, meanwhile, has never been the
problem: 166 fps is the display's refresh rate (§6.1).

**Scope was survivable, and the escape hatch was not used.** M0 through M7's API
are built and every milestone runs. The willingness to stop at M5 turned out to
be the useful part of that mitigation rather than the stopping: M6 and M7 were
each entered knowing they could be the last, which is why M6 shipped a reactive
server rather than a speculative tick loop (§12.1) and M7 shipped an API rather
than a loader (§9.1). What is left of M7 is the half that needs engine work, and
naming it as unfinished is the same discipline.

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

*M1: built as `core/world.gene`, with `probes/world_spec.gene` — 69 checks,
shared between the backends. Block and sector addressing, the three reserved
content ids, the ±31,000 limit, and the packed light byte are all there, and
§1.1 is what M5 did to the client's side of it.*

**One thing designed here did not survive contact: `NodePos`, `BlockPos` and
`Vec3` are not distinct types.** They are `F64` triples passed as three
arguments. The reason for wanting them distinct is real — mixing the three
spaces is the classic bug in this genre — and the reason they are not is
sharper: **the web profile's nominal types are reference objects**, so a
`NodePos` per node visit would allocate three million times over a chunk, on
precisely the path §D6.1 exists to protect.

What replaced the distinction is naming discipline — a function takes `nx ny nz`
or `bx by bz`, never bare `x y z` — plus conversion helpers so the shift never
appears open-coded at a call site. That is weaker, and it cost one bug: the
client's spawn scan sampled a *fractional* node coordinate, which reads as
`undefined` rather than raising (§7.0). A type would have caught it at the
boundary; a two-minute walking property caught it instead, which is §14 layer 1
earning its place rather than a type system's absence being free.

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

### 2.1 M1, M7 — the registry, and the two halves of this section that do not exist

*M1: `core/registry.gene`, the client half, as nine parallel arrays indexed by
content id rather than a map or a list of records — every lookup here is on the
meshing hot path, where `solid?` and `propagates_light?` run per neighbour per
node, and an indexed read into a typed array is the cheapest thing both backends
have. M7 added the appearance columns' source (§9.1) without changing the
shape.*

*The server half is `core/drops.gene`, split off exactly as this section asks,
and M6 is where that split became real rather than notional: the browser client
no longer imports it.*

**Six drawtypes are declared and two are honoured.** `airlike` decides whether
the mesher emits geometry at all, and `liquid` makes a node unpointable to the
raycast and swimmable to the physics. `glasslike`, `allfaces` and `plantlike`
are registered names that no code branches on, so a node declaring one draws as
an ordinary cube — which is invisible today because nothing declares them.
That is worth stating rather than leaving as a surprise for the first mod that
tries: §5's transparent pass is what `glasslike` needs, `allfaces` needs the
same pass plus a rule against culling between two of them, and `plantlike` needs
cross-quad geometry the mesher does not emit. All three are M8's, and the
enumeration existing ahead of them is fine — an id is cheap — as long as nobody
reads it as a promise.

### 2.3 M8 — crafting, and the shape §13 costs

§9's `register_craft`, built once §2.2's items existed — every ingredient is an
*item* id and half of them (a plank, a stick, a lump) are not nodes anyone can
place, so this could not have been written before.

**Shapeless only, and the reason is §13 rather than laziness.** Upstream has
both: a 3x3 grid where position matters, and a shapeless list. A shaped recipe
needs a grid to arrange items in, a grid needs a formspec, and the formspec is
the part of §13 that does not exist (§13.1). A shapeless recipe needs a list of
what you are holding, which the hotbar already is — so what a player can do
today is hold the ingredients and press a key. That is a real loop: chop a tree,
make planks, make sticks, make a pickaxe that digs stone faster than a hand.
The ingredient table is already the shape a 3x3 would index into.

Matching is a multiset test rather than a list comparison — ingredients in any
slots, in any order, mixed with anything else — which is what `total_of` was
already for.

**The ordering that matters is that the output goes in before the ingredients
come out.** `add` reports what did not fit; taking first would let a full
inventory eat the ingredients and hand back nothing. The spec asserts exactly
that case, because it is the one a hand-run never reaches.

On the wire it is `msg_craft`, one byte (protocol v4). §7.1 gives the client no
say in *what* is crafted: a client that named a recipe would be a client the
server had to validate, and validating it means running the match anyway — so
the client asks and the server decides against the inventory it already holds.

Two things this does not have. **There is no furnace**, because a furnace is a
container and a container is §13's formspec; steel is crafted from the lump the
ore drops, which is the honest shortcut until then. And **four ingredients is
the ceiling**, which keeps the table a flat array — a recipe needing five is a
recipe that wants the grid.

### 2.2 Items and groups — the half M1 declared and did not build

Built after M7, and the milestone table's M1 row is only now true. `core/item.gene`
is the parallel registry §2 asks for and `core/groups.gene` is the cross-cutting
mechanism; `probes/inventory_spec.gene` covers both on the two backends.

**Items have their own id space, and that was the decision worth making
deliberately.** The shortcut is to hang item columns off the node registry and
keep one space. It fails on the first item that is not a node — a lump, a
pickaxe — because a node id indexes the arrays the *mesher* reads, and a
pickaxe has no drawtype, tiles or light behaviour. So the spaces are separate
and bridged by two columns: `node_of` for what an item places, `item_of_node`
for what a node yields. Both are single indexed reads, which is what keeps
`place` and the drop table from paying for the split.

`core/inventory.gene`'s header had promised that "the day items get their own
registry, this file changes in one place: what an id means". The promise held —
the change was that paragraph and a per-item `stack_max` lookup, because
everything else in the file was already about an id and a count.

**A slot is three cells now**: item, count, and `^wear`. A tool that cannot wear
out is not a tool, and the field is `u16` because upstream's range is 65,535 and
that makes it exactly two bytes on the wire. `^meta` is still absent — a Map per
stack has no representation in a numeric buffer and nothing before M8's
containers reads one.

**Groups are a flat `(owner, group, rating)` triple list, scanned linearly**, and
that is a considered choice rather than the lazy one: the dense
`max_content x max_groups` alternative is one indexed read and 4,096 x 64 cells
to store a few dozen facts. The scan is affordable because nothing here is on a
hot path — a group is read when a dig starts and when an ABM matches, never per
neighbour per node. A group name is *interned* on first use rather than
declared, because a group has no definition, only a name two mods agree on.

#### A rating is difficulty; `level` is permission

The first `dig_time_ms` used a group's rating as a gate — a tool declared a
level and refused anything rated above it — and a five-line test caught it
before it shipped. It was wrong twice: it made a bare hand unable to dig stone
or grass, regressing the entire existing game, and it collapsed two of
upstream's mechanisms into one.

They are separate here as they are upstream. **A rating is difficulty**:
`cracky 3` is soft and `cracky 1` is hard — lower is harder, which reads
backwards until you notice the numbers rank how many tool tiers can manage it —
and it scales the time. **`level` is permission**, and it is an ordinary group:
a node in `{^level 2}` needs a tool that reaches level 2 and nothing else can
break it at all. Keeping permission in a group rather than a column is what
makes it a mod's to use; nothing in the engine mentions obsidian.

Nothing in `mods/default` declares `level`, so every node in the game stays
diggable by hand exactly as before groups existed. That was the property the
whole change had to preserve, and the spec asserts it directly.

#### What the split immediately bought

`core/api.gene` used to say ores drop themselves because "coal should drop a
lump, and a lump is an item that is not a node, and §2's item registry is not
built". It is built, so coal drops a lump — a thing no one can place, which the
client refuses locally (§7.1 step 1) and the server refuses again by resolving
the item to a node and finding none.

#### `^groups {^cracky 3}` is not the spelling, and the reason is the profile

§2 writes a node's groups as a map. A portable API cannot take one: **the web
profile cannot iterate a `PropMap`**, so `register_group` is one call per fact —
the shape `register_tile` and `register_drop_rule` already have, and one that
makes each rating independently diagnosable. §D7.15 tracks the gap.

#### Still not built

The *inventory image* §2 names: an item that is a node draws as its node's tile,
and an item that is not needs an image §6's 4x4 atlas has no room for. And
**groups and tool capabilities do not cross the wire.** They decide how long a
dig takes and nothing on the client asks yet — a click digs immediately. Sending
a table nothing reads is the schema §11.1 refuses to create; they join
`msg_items` on the day the client predicts a dig time, which is the same day the
HUD can say a node is too hard.

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
| 5 | decorations | **built** — M8, trees; placement is a pure function of the column (§3.6) | `core/decor.gene` |
| 6 | lighting | **built** — M3, and it runs over the whole world rather than per block (§4.1, §4.2) | `core/light.gene` |

Every stage is a registry a mod can add to (§9), which is Luanti's design and
the reason its games look nothing alike. `mods/default` populates them with a
node set, six biomes, and six ores — and M7's claim, that replacing the content
module with a mod moved nothing else, held: the four golden checksums are
unchanged (§9.1).

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

### 3.6 M8 — stage 5, and why a tree may not be generated into a neighbour

The one stage of §3's pipeline that was never built. It arrives with M8 partly
because a world without trees looks unfinished and mostly because wood is the
material that makes crafting worth having.

**Placement is a pure function of the column.** A tree is up to six nodes tall
with leaves overhanging two each way, so it does not fit in the block it is
rooted in, and both obvious approaches are ruled out by §3.5: generating into a
neighbour needs blocks that do not exist yet, and a post-pass over the loaded
world makes generation depend on load order.

So nothing is ever generated *into* anything. `decor_here?` and `decor_height`
answer from the world coordinate and the seed alone, and a region being filled
walks every column that could reach it — its own, plus a two-node skirt —
writing whichever of that tree's nodes land inside. Two adjacent blocks agree
about the tree between them because they compute the same function, not because
they talked. That is stage 4's trick for straddling ore clusters, reused.

Three consequences, each measured rather than assumed:

- **The height lattice is sized for the skirt, not the region.** Stage 5 asks
  for surface heights outside the region, and a lattice sampled only over the
  region reads past its own end there — which is exactly the crash it produced.
  One extra lattice cell each way is cheaper than stage 5 sampling its own
  noise and two stages then disagreeing about where the ground is.
- **The chance test must come before the surface lookup**, and the ordering is
  worth 98% of the stage: `decor_here?` is one hash, the surface is a lattice
  read plus an interpolation, and about one column in fifty has a tree.
  Computing the height for every column and discarding it cost 5 ms a block and
  took §D6.3's reading C from passing to 1.0002x over its budget. Reordered, the
  block is 75.0 ms against a 76.9 ms budget and C passes again.

  *Re-measured at the end of M8, and "passes again" is too strong: **C sits on
  its threshold rather than under it.** Ten runs of `gene run worldgen` on one
  machine spread 74.9–78.8 ms against the 76.92 ms budget, failing more often
  than not — 4 of 4 on a build with none of M8's final commits, 4 of 6 with them,
  which is what rules out a regression and leaves a reading that was always
  marginal. The 75.0 ms above was one sample of a distribution straddling the
  line, recorded as if it were the value. Two things follow: the decoration
  reorder did buy back its 5 ms and that part stands, and **C is no longer a
  check that passing or failing tells you anything about** — a threshold inside
  the run-to-run spread reports noise. It wants either a budget with margin or a
  median over runs, and until it has one, a single red C is not evidence of a
  regression. §D7.11's AOT path is still what would make the question moot.*
- **One golden checksum changed, and only one.** Of §14's four blocks, only
  `(4096,16,-2048)` spans a grass surface; it gained 19 trunk and 147 leaf
  nodes. The other three are byte-identical, which is the evidence that the
  change is decorations rather than a generator drifting.

**§6's atlas gained a row**, as §6 predicted it would "before a seventeenth tile
does" — the tree's three tiles are the seventeenth through nineteenth. 8x8
rather than 4x5 because the mesher divides by the column count and §D3.1 puts
the mesher in the exact half, so a power of two keeps every tile boundary on an
exact binary fraction. The ceiling that predicted this is why it was a one-line
change rather than a debugging session about a tile drawn over another one.

Leaves are also the first node in this game that is **drawn and not opaque**,
which is the case §5's two-question face rule was written for and nothing had
exercised — and exercising it cost more than expected. The world went from
**62,395 faces to 208,608**, 3.3x, because every leaf-to-leaf face is now
emitted: the rule says a face exists when its owner is drawn and its neighbour
is not opaque, and a canopy is a hundred leaves all satisfying both halves
against each other.

That is the rule behaving correctly and the content asking for something
expensive. It stayed within budget — `tools/mesh_bench.mjs` reported a worst
chunk of 1.02 ms against 8 ms — so it shipped measured rather than fixed, and
the fix was named: a node may decline to draw a face against its own kind, one
more registry column, turning a canopy back into a shell.

#### The column, built, and what it was worth

`^merges_same` on `register_node`, one column beside `opaque`. **208,608 faces
back to 117,528** — 91,080 gone, 43.7% of the world's geometry, and nothing
looks different because none of those faces was ever visible. Worst chunk
0.874 ms against 8 ms; a whole-world mesh is 41.2 ms.

It does *not* return the world to 62,395, and it should not: that was the count
before there were trees, and a tree whose canopy costs nothing is a tree that
is not there. What is gone is the interior of every canopy; what remains is its
shell, plus trunks.

Three things about the shape are worth keeping:

- **It is the only question in the mesher that needs both sides of a face.**
  Opacity is a property of the neighbour alone, which is why `face_visible?` had
  only ever taken the neighbour. It takes the owner's id now, passed rather than
  re-read, because the caller already has it and this is the hottest loop in the
  renderer.
- **It is per-id, not per-drawtype.** Two mods' leaves are different ids and
  still draw against each other, which is right — they do not look alike.
- **It goes on the wire** (protocol v6), because the *client* meshes. A cull the
  server knows about and the client does not is a cull that does not happen. The
  registry message gained a ninth byte per entry, and `probes/protocol_spec.gene`
  asserts both that the flag survives the round trip and that the game has at
  least one node using it — a diff of two registries that both lost the column
  reads as agreement.

Upstream reaches the same place from the other direction and pays for it:
`leaves_style = opaque` makes leaves solid, which culls the internal faces *and*
wrongly hides whatever is behind them.

A decoration is a trunk and a leaf ball. Upstream's are schematics — arbitrary
node arrays with rotation and force-placement — and that is the right end state;
it is also a file format, a placement grammar, and a mod-facing way to author
one. §D8's rule applies: when a mod wants a schematic, the schematic is what the
API grew wrong.

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

### 6.1 M0, M3, M7 — what was built, and the three claims above that are wrong

`client/render.gene` is one WebGL2 program, and it is the smallest part of this
project that does the most visible work: 229 chunk meshes and 62,395 faces at
**166 fps in a real tab**, which is the display's refresh rate rather than the
engine's ceiling — over 89 sampled frames the median interval was 6.00 ms and
nothing exceeded 8 ms (§D6.1).

Three claims above did not survive contact, and each is worth more than the
correction.

**The atlas is not generated at build time, and it is not from source tiles.**
It is painted at *startup* into an offscreen canvas by `client/atlas.gene`, and
since M7 the recipes come from a mod (§9.1) — reaching the browser client over
the wire, since a mod runs on the server. Procedural rather than shipped,
because `texImage2D` takes a canvas element directly, which removes a PNG
encoder, an asset to fetch, and a load event; `examples/new_world` needed all
three and writes its own encoder to get them. The build-time version becomes
right when M9 has image files to build from, and §D8's `assets/` is where they
land.

**There is no mipmapping, so the padding question never arrived.** The atlas is
sampled with `NEAREST` and no mip chain, which is the look this genre wants and
also the reason chunk-edge bleeding is not a problem to solve. The paragraph
above is a correct description of a decision nobody has had to make.

**There is no frustum culling.** Every chunk mesh with a face in it is drawn
every frame — all 229 of them, which is the number the HUD reports and the cost
the 166 fps includes. The culling that *is* on is the two kinds §5 and the GPU
give for nothing: a face is never emitted between two solid nodes, and
`cull_face back` drops the far side of every quad that is. Frustum culling has
not been built because it has never been the limit — at this extent the whole
world is 62,395 faces, and §D6.3's finding that the ceiling is the *server*
rather than the frame has held at every measurement since. It is cheap and
obvious and worth doing at the first view distance that hurts; doing it now
would be optimising the half that was never slow.

What *is* built and was designed correctly: the day/night mix as a uniform (the
M3 note above), the two-channel light byte travelling unpacked, distance fog,
and per-face shading. Draw order is not built either, because there is one pass
— §5's transparent pass is where back-to-front sorting arrives, and until water
stops being drawn opaque (§9.1's one compromise) there is nothing to sort.

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
  and per-item stack limits; that registry is a thing mods define, so it belongs
  behind §9's API and M7 did not build it — the game a mod defines today has
  nodes and nothing else to hold. Until then everything a player can hold is a
  node they dug, so an item id *is* a content id and the hotbar hands it
  straight to the edit. The day items get a registry, `core/inventory.gene`
  changes in one place: what an id means.
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

### 8.1 M8 — dropped items, and the half that is deliberately absent

Built: an entity is a stack of items at a continuous position, spawned when a
dig yields more than fits, picked up when a player walks over it, and carried on
the wire by `msg_entity` (protocol v5) — one message for add, move and remove,
because a count of 0 *is* the removal and a second message kind is one more
thing to drop.

**It closes a hole a player could see.** §7.1 has said since M5 that "what is
dropped and does not fit is lost", and `core/inventory.gene` named dropped-item
entities as the fix. Dig with a full hotbar before M8 and the node was gone. The
spec asserts the property rather than the mechanism: what a node yields is
either in the inventory or on the ground, and the two sum to what it yielded.

**`msg_input` stopped being decoded and dropped**, which is the first real use
it has had. §8's pickup needs to know where a player is standing and this server
holds no position of its own (§12.1), so the position travels in the input
message. That is a trust decision and it is a small one: a client that lies
about its position can reach an item it could have walked to anyway, which is a
different thing from lying about its inventory (§7.1). When players become
entities the server will step them and this field becomes a correction rather
than a source.

**What was absent was every callback**, and that paragraph is worth keeping
because of how it was wrong. It read: "§8 asks for `on_activate`, `on_step`,
`on_punch` and `on_death`, and an entity here has none. That is not a stub with
a plan to fill it in: §D7.17 records that the annotation a mod-supplied callback
needs does not compile on the VM." §D7.17 recorded no such thing once it was
measured — the annotation had been written with a profile-only synonym for a
type the VM has always had. See §D7.17 for the four measurements.

#### 8.2 The callbacks, and the two of four that have an engine under them

**`on_step` and `on_activate` are built.** An entity is an instance of a
**definition** — §8's "registry mirroring §2" — and a definition carries the
mod's functions. The server steps every live entity once a tick, notices whether
the step moved or ended it, and broadcasts; the mod supplies what happens.

`"item"` is a reserved definition name, the way §1 reserves `air`: the engine
spawns a dropped item from §7.1's overflow path before any mod has run, so one
exists from construction with callbacks that do nothing. Registering that name
appends a definition that shadows it — lookup finds the newest — which is how a
mod furnishes a reserved kind without the engine needing a mutation path into a
callback list. The web profile has no `set!` on a `(List (Fn …))`, and the
design that constraint forced is the better one: it is also what §9's loader
will want when mods are ordered by `depends` and the later one should win.

**`on_punch` and `on_death` are not built, and would be fields nothing could
call.** Nothing in this engine can hit an entity: §7's raycast selects nodes,
there is no damage, and there is no health column. That is a different kind of
absence from the one above and it is not a compiler gap.

**§8.1's own first named absence is now filled — from the mod.** It said "a
dropped item stays where it was dropped, including in the air if the node under
it is later dug", and guessed the fix would want "the same neighbour-update
machinery §12.2 built for nodes, applied to a continuous position … a second
mechanism rather than a reuse". It needed neither. `mods/default` registers an
`on_step` of eleven lines that reads the node under the item and moves it down,
and **the engine gained no notion of gravity to allow it**. That is §D8's test
for whether the API is right — *if M8's game needs an engine change, the API is
wrong* — and it is the first time the test has been run against a behaviour
rather than a registration.

`tools/entity_probe.mjs` is the check and it asserts the property rather than
the mechanism: it fills a hotbar so a dig drops an entity, digs the node holding
that entity up, **stops talking**, and waits for the item to move on a silent
socket. Measured: y 18.7 → 18.1, one unsolicited message, then still.

Still absent, and each for a stated reason:

- **No client rendering.** The networked client tracks what is on the ground and
  the HUD could say so; drawing an item needs a billboard or a scaled cube,
  which is §6 work and a vertex format this renderer does not have.
- **No static serialization.** §8 says an unloaded block serializes its
  entities into itself. This world never unloads a block (§1.1), so there is
  nowhere for that to happen yet.
- **The player is still not an entity**, which §8 names as a refactor M8 should
  do deliberately. It was not done, because the thing that makes it worth doing
  is a second player seeing the first, and that needs the entity *visuals* above.

*Before M8 this section had no result note at all, and what stood here was the
shape of the absence: `msg_input` was decoded and thrown away, two clients on
one server could dig the same world and not see each other, and a dropped item
that did not fit was lost. The first and third are fixed above. The second is
not, and it is now the clearest statement of what §8 still owes — a player is
visible to another player only once players are entities with visuals, and
neither exists.*

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

*That sketch is the design, and §9.1 is what was built — they differ in three
visible ways and one invisible one. The registrations take a `Game` context, a
mod's entry is `src/default.gene`, `^tiles` names registered tiles rather than
image files, and `register_abm` does not exist because §12's tick loop does not.
§9.1 has the real thing beside a table of what of this section landed.*

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

### 9.1 M7 — the API, built; the loading, not yet

`core/content.gene` is gone. Every node, tile, drop, biome and ore is declared
in `mods/default/src/default.gene`, through `core/api.gene`, and the engine gets
its game from `core/mods.gene`'s `load_mods` — one call, at seven call sites
that each used to import the content module and run four `setup_*` functions in
the right order.

What a registration actually looks like:

```gene
(mod mod_default ^profile web)

(import [Game register_tile register_node register_drop_rule
         register_biome_def register_ore_def]
        from "../../../core/api.gene")
(import [tile_solid tile_overlay] from "../../../core/tiles.gene")
(import [draw_liquid] from "../../../core/registry.gene")

(fn setup_tiles [game : Game] : Nil
  (register_tile game "miclone:grass_top" ^kind tile_solid
                 ^red 96.0 ^green 152.0 ^blue 72.0 ^spread 26.0 ^seed 40.0)
  (register_tile game "miclone:grass_side" ^kind tile_overlay
                 ^red 96.0 ^green 152.0 ^blue 72.0 ^spread 26.0 ^seed 40.0
                 ^base_red 134.0 ^base_green 102.0 ^base_blue 72.0
                 ^base_spread 22.0 ^base_seed 10.0))

(fn setup_nodes [game : Game] : Nil
  (register_node game "miclone:grass"
                 ^tiles ["miclone:grass_top" "miclone:grass_side"
                         "miclone:dirt"])
  (register_node game "miclone:water" ^tiles ["miclone:water"]
                 ^drawtype draw_liquid
                 ^solid false
                 ^propagates_light true))

(fn setup_drops [game : Game] : Nil
  (register_drop_rule game "miclone:grass" ^item "miclone:dirt"))
```

Two differences from §9's sketch are worth naming rather than leaving to a
diff. **The registrations take a `Game`**, because the web profile re-exports an
imported constant but not an imported *type*, so an API that hid five registries
behind five parameters would have made a mod import five type names it never
mentions. It is the better shape anyway — §9's sketch reaches an implicit global
and this is that global, made explicit. And **`^tiles` names registered tiles
rather than image files**, because §6's atlas is generated rather than shipped;
`^tiles ["default_stone.png"]` becomes true when M9 has files to name.

**How much of §9's surface this is:** less than half, and the missing half is
missing because the engine under it is.

| §9 asked for | M7 |
|---|---|
| node registration | **built** — `register_node` |
| tile/appearance registration | **built** — `register_tile`, which §9 did not ask for and a mod cannot do without |
| drop rules | **built** — `register_drop_rule` |
| biome and ore registration | **built** — `register_biome_def`, `register_ore_def` |
| item registration | not built — §2's item registry does not exist; an item id *is* a node id (§7.1) |
| craft registration | not built — needs items |
| entity registration | not built — §8 is M8's |
| ABM and LBM registration | not built — needs §12's tick loop, which does not exist either |
| `get_node`/`set_node`, bulk accessor | not built — no mod runs at a time when a world exists to read |
| inventory manipulation, player methods | not built — same |
| chat commands, privileges, callbacks | not built — needs the loader and a player model |

The pattern in that column is the honest finding: **every unbuilt entry is
blocked by an engine part rather than by API design.** A mod API cannot register
an ABM before there is a tick to run it on, and `set_node` from a mod means
nothing until a mod runs during play rather than only at load. §D8's ordering
holds — the engine before the API that exposes it — and what M7 exposes is
exactly the engine that exists.

**That table is M7's and every row of it moved by the end of M8.** Items,
crafting, entities and ABMs are registered; the tick exists; `get_node` and
`set_node` are what an ABM action calls, and a mod *does* run during play. The
row that is worth returning to is the last-but-two — "`get_node`/`set_node`,
bulk accessor: no mod runs at a time when a world exists to read". That stopped
being true the moment the tick could call a mod's function, which is what §12.3
and §8.2 are about, and the correction it needed was not to the API.

#### 9.2 M8 — the callback surface, and the entry that was blocking it

Two registrations take a mod's own function now, and neither needed an engine
change to allow it:

| §9 asked for | after M8 |
|---|---|
| `register_abm ^action` | **built** (§12.3) — `(Fn [World F64 F64 F64 F64] Nil)`, and the trigger is what stays the engine's |
| entity `on_step`, `on_activate` | **built** (§8.2) — a definition registry mirroring §2, as §8 asked |
| entity `on_punch`, `on_death` | not built — nothing in this engine can hit an entity, so they would be fields nothing calls |
| chat commands, privileges | not built — needs a player model |
| runtime mod loading | not built — and §D5.1 is why it is bigger than it looks |

**Both built rows were recorded as blocked, by §D7.17, and were not.** That
entry claimed the VM could not compile the annotation a mod callback needs; the
measurement is in §D7.17 and the short version is that the annotation had been
spelled with a synonym only the profile knew. The cost of not measuring it was a
milestone in which two features shipped as fixed vocabularies — `^kind
abm_fall`, and an entity with no per-entity code at all — each with a paragraph
explaining that the compiler left no choice.

What that buys, concretely: **`mods/default` fills §8.1's first named absence in
eleven lines of mod code.** A dropped item falls because the mod says how, not
because the engine learned gravity. §D8's test for this API is "if M8's game
needs an engine change, the API is wrong", and this is the first behaviour — as
opposed to registration — the test has been run against.

**The test of the move is that the world did not change**: the four golden
checksums hold, the world is the same 229 chunks and 62,395 faces, and the ten
cross-backend specs diff clean. §14 layer 3 exists for terrain changes and it
earned its keep on a change that was not one.

Four things §9 asked for, and what each turned out to cost:

1. **Definitions read as what they say.** `register_node` takes named arguments
   and applies every default itself, so `(register_node game "miclone:stone"
   ^tiles ["miclone:stone"])` is a solid opaque cube because that is what a node
   is unless it says otherwise — and the two nodes that *are* different, water
   and the lamp, are the two that say anything. That cost a compiler change:
   `^name : T` was a VM-only parameter form and this API compiles for both
   backends, so the web profile learned named parameters (language design.md
   §7.11). Going the other way — a positional API, or a VM-only one — would have
   made the mod-facing surface no better than the `register` it wraps, or retired
   the in-tab client.
2. **A mod defines what its nodes look like.** The atlas was a list of constants
   and a matching list of `paint_*` calls, with the *number* as the contract
   between them; it is now `core/tiles.gene`'s registry, and `client/atlas.gene`
   walks it. A mod that can register a node but not its appearance can only
   rearrange nodes the engine already drew.
3. **And a client draws them without running the mod.** The recipes travel in
   `msg_tiles` (§10, protocol v2), so `client/net_main.gene` paints an atlas for
   a game it never imported. That is §D5's promise made concrete rather than
   asserted: the only thing that crossed the wire is data. A tile is a *kind* and
   eleven small numbers, and the three kinds are the engine's procedural
   generators — a mod that shipped a painter would be code a client has to
   execute.
4. **Ids stay the engine's.** Nothing in the mod compares an id to a literal;
   registration returns one and the API resolves names to ids at registration,
   so a `^drops` naming an unregistered node fails there with a position rather
   than dropping `unknown` at the first dig.

**What is not built is the loading, and that is the half §D5's security claim
lives in — a claim §D5.1 has since found to be false in a way the loader alone
cannot fix.** `mods/default` is imported like any other module and its
`register_all` is called; nothing is sandboxed, because a compiled-in module is
not sandboxed by anything. Runtime module loading exists inside the VM
(`loadFileModule`) and is not reachable from Gene, so exposing it is engine work
with a capability model attached. `core/mods.gene` is the file where "a mod that
never receives `$fs/WriteDir` cannot write a file" will be true or not, and it
says so. Doing the loader first would have been a loader with nothing worth
loading.

*Since written: §D5.1 measured that sentence and it does not hold — any module
can import `$fs` and obtain the capability for itself, so the sandbox has to be
at the import boundary rather than the argument list. That makes M7's remaining
half larger than "expose `loadFileModule`" and makes it a VM change rather than
a game one. It also makes it more clearly worth doing: runtime loading without
the restricted root would be strictly worse than what exists now, since
`mods/default` is compiled in and audited by being in this repository.*

Two smaller findings, both recorded where they bite:

- **Neither backend re-exports an imported binding the same way.** The VM
  refuses it (`module/namespace has no export`) and the web profile silently
  copies the literal. So `core/api.gene` cannot stand in front of the tile
  kinds, drawtypes and ore shapes, and a mod imports those from the modules
  that define them. The API stands in front of *registration*, which is the
  part that matters; three import lines is the portable spelling.
- **A mod's entry is named for the mod**, `src/default.gene` rather than §9's
  `src/main.gene`. The web profile emits one flat output directory keyed by
  basename, so a second `main.gene` collides with the client's.

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

### 10.1 M6 — the codec, and what a world costs on the wire

`core/wire.gene` is a cursor over a `(Buffer U8)`; `core/protocol.gene` is the
eight messages. Both are `core/`, which is the point: the server encodes on the
VM and the client decodes in the browser, and a format with two implementations
is a format two processes can disagree about.

**Everything is bytes, which is narrower than the sentence above.** §10 says
"Gene nodes except block data", and the exception turned out to be the only part
that was ever a choice — `docs/serialization.md` is a VM facility and the web
profile has no reader for it, so a node-encoded message could be written by the
server and not read by the client. That is a real narrowing: a node-encoded
message is self-describing and this is not, so a version skew is a misparse
rather than a missing field. The version byte in `hello` is what stands in, and
the framing is deliberately just a kind byte so that control messages can move
back to nodes per-kind once the profile has a reader.

Measured on §3's real terrain, 12 × 4 × 12 blocks:

| | |
|---|---|
| a block message | **575 bytes mean**, 5,017 worst, 259 of 576 uniform |
| the whole world | **0.32 MB** against 9.0 MB raw — **29x** |
| the registry | 364 bytes for 16 node definitions |
| the tiles (M7) | 406 bytes for 14 tile recipes |
| codec | 32 µs to encode a block, 16 µs to decode |

Run-length encoded on the finding §11 records — a voxel column is a handful of
runs — and the mean lands within 6% of `server/blockfmt.gene`'s 612 bytes for
the same scheme on disk. **No raw fallback, unlike blockfmt**: a stored block
that doubled is a disk cost paid forever, a message that doubles is paid once,
and the socket is the slower half regardless. The alternating worst case is
pinned by the spec at one run per node so the cost is a number rather than a
worry.

**The server encodes a block in 17.9 ms, and V8 does the same work in 0.032 ms
— 558x.** That is not a defect in the codec; it is §D6.3's finding arriving
somewhere new. A message send is ~500 ns on the VM and `(buf ~ get i)` is a
message send, so a block encode is ~16,000 sends before any arithmetic:

| stage | VM | what it does |
|---|---|---|
| `block_size` | 6.4 ms | two counting passes, to size the buffer exactly |
| `encode_block` | 11.5 ms | two writing passes |
| `to_bytes` | 0.0 ms | the socket boundary — 4,096 bytes, and free next to the above |

Measured by `gene run wire_bench`. It is what makes a 576-block world take ~12 s
to transfer rather than the ~0.3 s the 0.32 MB would suggest — **the socket was
never the bottleneck**, which is worth knowing before anyone optimises the
wrong half. A world load is a one-time cost and M6 is about the split working,
so this ships measured rather than fixed.

Two ways out, in the order they are worth trying:

1. **Delete `block_size`'s counting passes**, which is 36% of the cost for a
   modest change: encode into one worst-case buffer reused across blocks
   (13 + 4 × 8,192 = 32,781 bytes, allocated once) and convert only the prefix
   the cursor reached. It needs `Buffer/to_bytes` to take a length, which is a
   small VM-surface addition.
2. **§D7.11's AOT path**, which is the general answer and already lowers the
   noise stack; the codec's inner loops are the same shape.

Three decisions the spec caught rather than the design:

- **Every `encode_*` has a matching `*_size` and the spec asserts the encoder
  writes exactly that.** Three of the six constants were wrong when first
  written — `hello` by two bytes, `registry` by one per entry, and `block` by
  two — and an underestimate is a silent overrun in the web profile.
- **`dig` and `place` needed separate sizes.** One constant for both would
  either waste two bytes on every dig or overrun on every place.
- **Yaw travels as a fraction of a full turn**, not in thousandths of a radian.
  Thousandths was the first version and is worse twice over: it uses 6,283 of
  65,535 values, and its zero point is π — not a whole number of thousandths —
  so encode-then-decode loses up to a thousandth *and cannot be made not to*. A
  turn fraction has no offset to round and resolves 0.0055°.

**Protocol v2 adds `msg_tiles`** (§9.1). A mod defines both a node and what it
looks like, and `registry` carries only the atlas *slot* a node's face points
at — so without it a client that never saw the mod holds tile indices into an
atlas nobody told it how to paint. It is sent in the handshake, before the
registry that indexes into it, and it carries a recipe rather than an image:
twelve bytes and a name per tile, which `client/atlas.gene` runs. Keeping it
data rather than code is what makes §D5's "a client renders without executing
mod code" a property of the wire instead of a promise.

Message groups: handshake and auth; registry sync (§2's client half, sent
once on join); tile sync (§9's atlas recipes, likewise); block add/remove; node
deltas; entity add/remove/update; player input; inventory; chat; HUD.

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

`miclone:lamp` is registered by `mods/default` for this: it is the first
node that emits, nothing in §3 places one, so no terrain and no golden checksum
moved. M5's torch is this node with a placement rule attached.

#### Not built

`players.sqlite` and a per-world `mods/`, and both are still empty for the same
reason: a table nothing writes is a schema to migrate rather than a feature.

*M5 and M7 have since been built and neither claimed them, which is the useful
correction.* **Player state is per-connection and dies with it** — each client
gets a fresh inventory at the spawn the server chose, so quitting and rejoining
resets what you were carrying while the world you dug persists exactly. That is
a real gap rather than a design; it needs §8's player-as-entity refactor to have
somewhere coherent to save *from*, so M8 owns it and `players.sqlite` waits for
it. And **M7's mods are compiled in, not read off disk** (§9.1), so there is
nothing per-world to store: a world does not yet record which mods made it, and
it should, because §11's whole promise is that a stored block still means what
it meant. The `name -> id` mapping already survives a mod being added or
reordered; what it cannot survive is a mod *disappearing*, and recording the mod
set is what turns that from silent corruption into a refusal to load.

Writes are batched (a transaction, so a crash leaves the world as it was rather
than partly saved) but still not asynchronous. That wanted "the scheduler and a
tick to hang a flush off, which is M6" — M6 came and brought no tick (§12.1), so
this waits on §12's loop rather than on a milestone number. It has not hurt:
an edit persists one block inside a click and the measured end-to-end cost is
1.8–3.5 ms.

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

### 12.2 M8 — the loop arrived, and two mechanisms had to exist rather than one

§12.1 said "§12's loop arrives with the first thing that changes without being
asked". That is M8's falling sand, and the loop arrived with it.

It runs on `serve`'s `^on_tick`, which Gene's HTTP server gained for this
(§D7.16): the event loop already slept only as long as nothing needed it, so a
tick is one more deadline to clamp against rather than a thread. A throwing tick
is reported and the loop continues — it would otherwise take every connected
client down with it, and the next tick may well succeed.

**The design mistake worth recording is that sampling cannot do falling.** §12
specifies ABMs as sampled, and the first implementation sampled only. It did not
work, and a probe measured why: 900 positions a pass out of 2.4M nodes is about
six minutes to visit one *particular* node, so a column whose support was just
dug stands there. The tick ran and nothing fell.

So there are two mechanisms, which is what §12's own "run node timers, run due
ABMs" was already saying:

- **A check queue**, targeted. An edit seeds the position above it, the tick
  drains the queue, and a node that falls seeds its own — which is what makes a
  column cascade a node per tick instead of settling one node per minute. This
  is a *neighbour update*, and it is how upstream does falling too.
- **Sampling**, ambient, for the behaviour it was designed for: grass spreading
  onto a block nobody touched.

"Run it on random positions" and "run it where something just happened" look
like the same feature and are not.

### 12.3 The action is the mod's, and the sampled half had never run

Two changes, and the second was found by the first.

**`register_abm` takes `^action (fn [world x y z node] …)`**, which is §9's
shape. It took `^kind abm_fall` until §D7.17 was measured rather than believed —
that entry claimed the annotation a mod callback needs could not compile on the
VM, and what it actually could not compile was a profile-only *synonym*. Nothing
was blocking it. `mods/default` now supplies both behaviours as functions, and
what an ABM declares to the engine is only *when* it is looked at:
`abm_on_change` drains the check queue, `abm_sampled` walks the ambient sample.
Neither declaration names a node — both name a group, so a mod adding its own
falling node still gets the behaviour by joining `falling_node`.

**Then the first sampled ABM did not fire, and the walk was why.** The sample
walk took three strides against one counter — `x = 97t mod nx`, `y = 43t mod ny`,
`z = 61t mod nz` — and its comment said the multipliers were "coprime with the
world extent so the walk does not close into a short cycle". The cycle in `t` is
long; the **image** is not. Three coordinates driven by one counter trace a
one-dimensional curve through a three-dimensional space, and it closes after
`max(nx, ny, nz)` steps. Measured on this engine's own shapes: **192 distinct
positions out of 7,077,888**, and 384 out of 56,623,104. Ambient sampling could
not reach 99.997% of the world, at any rate, ever.

It survived a whole milestone because **the sampled branch ended in a literal
`void`** — the arithmetic ran, the group was tested, and there was nothing at
the end of it that could come out wrong. §12.2 above says "nothing registered
uses it yet" and treats that as a scheduling fact; it was the reason the bug was
invisible. Giving the branch a mod's `^action` is what turned it into an
observable, and the first thing the observable did was not happen.

What replaced it strides the **flat** index by a step near `total × φ`, walked
down until coprime with the node count — which makes the walk a permutation:
every node is visited exactly once per cycle and none is unreachable.
Consecutive samples stay far apart as a consequence rather than a hope (no two
within 113 nodes on any shape this engine builds, no repeat in 500,000
consecutive samples). `probes/abm_spec.gene` asserts the permutation directly on
a 2,048-node world, which is the check that is false for every version of this
code before the fix. The bound worth knowing is stated in `core/abm.gene`: the
products stay exact while `total² < 2^53`, a world of 94M nodes, and past that
the walk silently stops being a permutation.

Measured after the fix, at five passes a second against 200 open-dirt nodes in a
2.4M-node world: **27 conversions in 60 s against 22.9 predicted**. Before it,
zero in 60 s at the same rate.

**The shipped rate is one pass a second, 900 positions** — a full sweep of the
world every 44 minutes. That is what ambient should mean, and it is now a
statable guarantee rather than a hope, because the walk reaches everything.

`tools/tick_probe.mjs` is the check, and it asserts the property rather than the
mechanism: it digs the support out from under a sand column, **stops talking**,
and waits for node deltas to arrive on a silent socket. That is the whole
difference between M6's reactive server and this one.

§12.1's other prediction also came true: per-connection state was a closure, a
closure cannot be iterated, and a change nobody asked for has to reach
everybody — so the server now keeps an enumerable list of connections beside it.

### 12.1 M6 — the server is reactive, and has no loop at all

**`server/main.gene` does not tick.** It accepts a connection, answers a
handshake, and answers messages; between messages it does nothing, and there is
no fixed-step loop anywhere in it.

That is a decision rather than an omission, and the reason is that every item on
the per-tick list above is a thing that does not exist yet. There are no
entities (§8), no ABMs (§9 — `register_abm` is not in M7's API), no node timers,
and no liquids that flow. Every message the server handles is a response to a
client action, so a 20 Hz loop would run empty, and running one anyway would be
a game server costume rather than a game server: it would consume a core, make
every future measurement noisier, and let a reader believe scheduling had been
thought about when it had not.

**§12's loop arrives with the first thing that changes without being asked.**
That is the trigger, and it is a sharper one than a milestone number: liquids
flowing, a node timer firing, or an ABM spreading grass each independently
require it, and none of them can be built without it. Whichever comes first
brings the loop.

Two things the reactive shape already got right and should survive the loop:

- **The client asks and the server answers; the server does not push** (§10.1).
  That is flow control rather than politeness, and it is the reason a 576-block
  world arrives intact. A tick loop does not change it: block transfer stays
  request-driven, and what the loop adds is the *unrequested* traffic — deltas
  from ABMs, entity updates — which is exactly the traffic that needs a rate.
- **Per-connection state is a closure, not a table keyed by connection.** The
  one thing a connection owns — its inventory — lives in the `ws_accept`
  callback's scope, which is what makes each client its own player without a
  registry. A tick loop needs to *iterate* players, which a closure does not
  offer, so this is the shape §12 will have to change. Worth changing at that
  moment rather than pre-emptively: a table nothing enumerates is §11.1's
  argument again. Note that the iteration §12 wants is over more than exists
  today — there is no server-side position or physics state to step (§8), so the
  loop and the player model arrive together or not at all.

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

### 13.3 M8 — the formspec, and the claim it was written to test

§13 said a formspec of Gene data is "composable, inspectable, and validated at
registration" against a string DSL that is none of those, and §13.1 recorded
that as an untested prediction. `core/formspec.gene` is the smallest thing that
tests it, and **the test is not that a panel appears** — it is that a wrong form
fails at registration with the form's name and the numbers, which is the one
adjective a string DSL cannot have. There is nothing in
`size[8,6]label[99,99;x]` that fails until someone looks at the screen.

The vocabulary is closed — label, item, box — and that is the point rather than
a limitation. Upstream's grammar is open, a mod emits whatever text it likes and
the client parses it, and that openness is where the escaping bugs live. Here an
element the client cannot draw is one the registry refuses to hold.

The validation exists twice: `add_element` raises, which is §13's promise, and
`element_fits?` asks the same question without raising — which is what a spec
can assert on both backends and what a tool inspecting a mod's forms would want.
The predicate came from a measurement, not a design: the VM did not match
`catch (Error ^message m)` against a custom error type that implements `Error`,
and rather than debug that inside a game milestone the check became a question.
**That is an open divergence and it is not recorded as a §D7 item because it was
not narrowed down** — the raise happens and is correct on both backends; only
the catch was not verified.

`mods/default` declares a crafting panel and `client/main.gene` renders it: the
client walks a form it has never seen the shape of, and the smoke test asserts
the rendered text contains a word that appears nowhere in the client. That is
the composability claim, checked.

**No input.** A form here is read-only — no button that sends a message, no
field to type into — which covers the crafting panel M8 needs and does not cover
a chest. Input needs a message per element kind and a server that can attribute
one to a form it opened, and it wants the container that would justify it.

### 13.2 M8 — sound

Not §13's subject, but the other half of "UI and sound" and the smaller half.
`client/sound.gene`: a dig is a noise burst, a place is a tone, a craft is two
notes a fifth apart. §D7.9 recorded the estimate as "dozens of bindings, at the
same tier as WebGL2" and the estimate was wrong in a useful direction — two
bindings cover a game, and the graph API is what a mod authoring music will
want.

**In the networked client the sound plays when the server confirms, not when
the click happens.** §7.1 keeps drops and edits off the prediction path, and a
thud on a dig the server refused is the audible version of the flickering
hotbar that rule exists to prevent. The in-tab client plays on the edit, because
in-process the edit and its confirmation are the same call.

`tools/dom_stub.mjs` gained an audio stub, and it had to be a real `EventTarget`
subclass rather than a plain object: a `BaseAudioContext` is one, the profile
checks it at the boundary, and the generated guard rejects a stand-in before any
audio call happens.

### 13.1 M5 — the HUD is built; the formspec is not

**The HUD exists and is DOM**, exactly as designed: four elements in
`index.html` (`hud`, `hotbar`, `aim`, `help`) that the client writes text into
once a second, plus a CSS crosshair. It is worth more than a status line
because of what it turned out to be *for*.

The HUD line is the project's most-used instrument. `60 fps · 229 chunks ·
62395 faces · walking at -1335, 21, 3265` is the frame rate, the draw count, the
geometry, the physics mode and the position in one string — and because it is
one string, both headless smoke tests read it as their only window into a
running client (§14 layer 4). Every check about walking, flying, swimming and
where a player is standing is a regex over that line. It was written to be
looked at and it is mostly parsed.

Two things follow that a redesign should keep: **the numbers stay in one line
with stable labels**, because two harnesses depend on that shape; and the
*mode* word stays a single word from a closed set, since `walking|flying|
swimming|falling` is how a test asserts that physics ran at all.

**The formspec is not built, and nothing needs it yet.** M5's hotbar is eight
slots rendered as text and selected with the number keys or the wheel — that is
the whole of the inventory UI, and it is enough for a game whose only container
is the player's own hands. §13's formspec becomes necessary at the first *second*
container to move things into: a chest, a furnace, a crafting grid. All three
are M8's, and all three need §2's item registry (§9.1) before they need a way to
be drawn.

So the design above stands unchallenged rather than confirmed: nothing has
tested whether Gene nodes are a better formspec than a string DSL, because
nothing has built one. The claim that they are composable, inspectable and
validated at registration is a prediction, and §14's discipline says to mark it
as one.

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

   *M7 is what this layer is for and the reason is worth stating: the change
   that moved every registration out of the engine and into a mod (§9.1) is
   exactly the kind that could alter terrain by accident — one node registered
   in a different order renumbers every id after it. The checksums held
   unchanged, which is the whole claim the milestone makes.*
4. **A headless server + scripted client** for the protocol: join, load blocks,
   dig, place, disconnect, reconnect, and find the world unchanged. It also
   covers §7.1's reconciliation, including the case that only shows up under
   authority: a mod vetoing an edit the client already applied optimistically,
   and the rollback that follows.

   *M6: built, as two harnesses that are not the same test. `tools/net_probe.mjs`
   is a **peer** — it speaks the protocol itself, out of `core/`, and proves the
   server answers correctly, including refusing a node the client does not hold.
   `tools/net_client_smoke.mjs` is a **client** — it boots `gene run server` as
   its own process and runs the 535 lines of `client/net_main.gene` that the
   probe replaces, over the platform's own `WebSocket`. Neither subsumes the
   other: the probe owns "the server is right", the smoke test owns "the client
   uses it right", and `net_main.gene` had no automated test at all until the
   second one existed.*

   *What the client harness stubs is the DOM and nothing else — the transport is
   a real socket to a real process, and the client reaches it through the same
   `$gene_ws_connect` a tab would. It swaps in a `WebSocket` **subclass** that
   tallies frames by kind while delegating everything to the real one, which is
   what lets a failure say which message never arrived rather than "the world did
   not turn up". Twelve checks: the handshake moves the player to the
   server-chosen spawn; a click before the world arrives never reaches the wire;
   576 blocks arrive in nine windows of 64 and mesh to 229 chunks and 62,395
   faces; a dig goes out and the drop comes back **because the server sent an
   inventory**, not because the client predicted one; the delta remeshes the
   chunk around it (62,395 → 62,399 faces) and the place puts it back
   (→ 62,395); placing from an empty slot never becomes a message; a drag turns
   the view without digging.*

   *Still missing from this layer: disconnect and reconnect within one run —
   §11's `probes/run_persistence.gene` covers restart, and the face count above
   covers a within-session round trip, but not a client rejoining — and the mod
   veto. The veto is closer than the paragraph that used to stand here said: it
   claimed "there is nothing for a mod to veto *with*", which was true only
   while §D7.17 was believed. A mod's function runs during play now (§8.2,
   §12.3); what a veto still needs is a callback on the **edit** path rather
   than on the tick.*

5. **Silence, for anything the server does on its own.** §12's tick and §8's
   `on_step` are checked by a harness that drives one action and then **stops
   talking** — `tools/tick_probe.mjs` for nodes, `tools/entity_probe.mjs` for
   entities. What is asserted is that a message arrived on a socket that sent
   nothing, which is a property no request/response harness can express.

   *M8, and the two things this layer taught are both about windows. A wait
   that is too long swallows the evidence: `tick_probe` first waited 600 ms for
   a dig's own answer, the whole cascade landed inside it, and a working tick
   read as a broken one. `entity_probe` hit the same wall from the other side —
   50 ms is now the post-dig wait, under one tick, so the fall cannot happen
   while the client is still notionally talking.*

   *And **a probe that assumes it is the only source of change** breaks the
   moment the engine gains an ambient behaviour. Three harnesses counted deltas
   as running totals, which was a correct reading of "what I caused" only while
   nothing else could cause anything; §12.3's grass ABM made all three fail at
   once. They count at a position, or from a mark, now. The engine was right in
   every case and the fixtures were wrong — which is this codebase's most
   frequent failure by a wide margin.*

   *Two traps it is downstream of. **The server's stdout is block-buffered when
   it is a pipe**, so a harness waiting for "listening on 8790" hangs while the
   server is happily serving; the readiness signal is the port. And a world costs
   64 s to generate and 28 s to load, so the harness keeps its world between runs
   at `/tmp/miclone_smoke_world` — safe because the one edit it makes is a dig
   followed by a place of the same node — and **discards it if the run failed**,
   since a world with a hole in it is how the next run inherits a fixture nobody
   wrote.*

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
    tiles.gene            §2, appearance side (M7)
    api.gene              §9, the surface a mod is written against
    mods.gene             §9's load step — portable while mods are compiled in
    mapgen/               §3
    light.gene            §4
    mesh.gene             §5
    physics.gene          §7
    protocol.gene         §10
  server/                 VM only
    main.gene  storage.gene  blockfmt.gene
  client/                 web profile
    main.gene  net_main.gene  render.gene  atlas.gene
  mods/
    default/              the game, built through §9's API
      package.gene        §9: a mod is a Gene package
      src/default.gene    named for the mod; `main.gene` collides in dist/
  assets/                 source tiles; the atlas is generated
  tests/
    fixtures/  golden/
```
