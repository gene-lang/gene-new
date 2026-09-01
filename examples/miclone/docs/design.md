# Miclone — Design

A voxel game engine with Luanti's architecture, written in Gene, whose mod
language is Gene.

**Status: M0 through M8 are built and running.** §D8 says which milestone owns
what; M9, the native shell, is the only one left.

## How to read this document

**Part I (§D1–§D10) is the direction** — what "clone Luanti" means here, the
platform constraint that shaped everything else, and the phases. Read §D2 first:
it is the constraint the rest of the document answers to.

**Part II (§1–§14) is the system**, part by part. Each section states the
problem, the design, what it costs as measured today, and what is deliberately
not built. Appendix A maps each part to the upstream source worth reading while
working on it.

One numbering quirk: **§D7.*n* means item *n* of §D7's backlog list**, not a
subsection — §D7.11 is "the AOT lowerable subset", the eleventh entry. Every
other `§x.y` is a real subsection.

Section numbers are a stable reference. Roughly a thousand comments across the
source cite them, so a number means the same thing for the life of the project
even when the text under it is rewritten.

Reference source: `examples/miclone/luanti/`, a shallow clone of
<https://github.com/luanti-org/luanti> at the tip of `master`. It is not vendored
into this repository (see `examples/miclone/.gitignore`). Upstream is
LGPL-2.1-or-later (engine) with CC-BY-SA assets. **We read it; we do not copy
from it.** See §D9.

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

## D2. The constraint: Gene cannot draw a triangle

This is the finding that decides the project, so it comes before the design
rather than after it.

**Dynamic FFI cannot express the graphics API.** `ffi/open` + `ffi/bind` load a
library and bind a symbol at runtime, but `isSupportedDynamicFfiSignature`
accepts only a hand-enumerated table of **0-to-3 argument** shapes. The
functions a renderer needs are all wider than that:

| function | arity |
|---|---:|
| `SDL_CreateWindow` | 6 |
| `glVertexAttribPointer` | 6 |
| `glTexImage2D` | 9 |
| `glDrawElements` | 4 |
| `glUniformMatrix4fv` | 4 |

Not "slow" or "awkward" — `ffi/bind` raises `unsupported dynamic FFI signature`
and there is no workaround short of a C shim per call.

**Static FFI is not an escape hatch.** `ffi/fn` declarations have no interpreter
implementation. They lower through the experimental `typed_native` C backend,
and there is no `gene build` producing a linked artifact.

**The web profile has no 3D**, and had no typed arrays of any kind.

**There is no socket API.** `net/tcp_read_text_async` and its write counterpart
are one-shot connect-transfer-close text helpers. The only persistent
bidirectional transport Gene code can hold is the RFC 6455 **WebSocket server**
in `src/gene/http_server.nim` — server side only, no client.

**Two smaller gaps** that matter later: `fs` has `write_bytes` but no
`read_bytes`, and `Buffer` is a `seq[Value]` — boxed, 8 bytes per element
whatever the declared element type.

The conclusion is not that this is impossible. It is that **the platform edge is
the project's real content**, and a design that treats rendering as a detail to
be sorted out later is a design that will stall in month two. §D7 turns this list
into an ordered backlog, and §D6 puts a gate in front of everything.

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
`web` profile compiles — no fexprs, no runtime `eval`, no actors or channels, no
FFI, no capabilities, no threads. Both sides get the same world model, the same
meshing, and the same physics, which removes the usual source of the worst bugs
in this genre: two implementations of one rule, drifting apart.

**What that buys, precisely: the same algorithm, not the same bits.** The client
is V8 and the server is the interpreter — two runtimes, two libm
implementations, one source:

- IEEE-754 requires `+ − × ÷` and `√` to be correctly rounded. Two conforming
  runtimes agree on them **exactly**, forever.
- It requires nothing of `sin`, `cos`, `pow`, `exp`, or `log`. Two runtimes may
  differ in the last ULP, and are entitled to.

So bit-identical agreement is available, but only for code that stays inside the
first list. That is a constraint we can meet where it matters and should not
pretend to meet everywhere. §D3.1 turns it into a rule.

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
than the host's. Cross-backend fixtures assert bit-identical output, and a
single differing bit fails the build.

**Corrected half — agreement is expected, divergence is tolerated and
repaired.** Physics, prediction, entity motion. The server is authoritative and
the client reconciles, which is what every multiplayer engine does and what the
protocol has to support regardless of how close the two runtimes are. A 1-ULP
difference in a player's velocity is a normal property of two runtimes, not a
bug to be hunted. Fixtures here assert agreement to a tolerance and track the
observed divergence, so a *growing* gap is still a signal.

A fixture that cannot say which half it is in is a fixture whose author has not
decided.

## D4. The browser shell goes first

**1. It is reachable; the native shell is not.** §D2. Adding WebGL2 to the web
profile is extending a binding table and its `lib.dom.d.ts` oracle — mechanical,
verifiable, and the same kind of work that put canvas there. Making the native
shell reachable means either a general N-argument FFI trampoline or a C
extension module. Both are real projects. Neither should be on the critical path
to seeing a voxel.

**2. There is a precedent in this tree.** `examples/new_world` is a playable
side-view voxel game whose world generation, physics, collision, and mining are
Gene compiled through the web profile. Miclone is that argument in 3D.

**3. The transpiled path is the faster one.** A message send costs roughly
500 ns on the VM. On the transpiled path, V8 JITs the same source. For the hot
loops in this engine, Gene-on-V8 beats Gene-on-the-VM by orders of magnitude, and
meshing belongs on the client anyway.

**That argument is narrower than it looks, and the narrowing matters.** It says
meshing lands on the fast runtime. It does not say the engine's hot work does —
the server owns hot, client-independent workloads that *cannot* move to V8:

- mapgen, over whole blocks (§3);
- ABM scanning across every loaded block, every tick (§12);
- node timers, liquid flow, entity steps, and light.

So: **the fastest runtime does the work that can move, and the authoritative
workload is stuck on the slowest one.** The throughput ceiling is the server, not
the frame budget, which is why §D6 gates on server worldgen throughput as well as
frame rate — and why that has remained the binding constraint at every
measurement since.

**4. The browser supplies, free, four things we would otherwise build:** PNG
decoding (`$image/load`), a frame clock (`$frame/request`), input events, and
audio.

**What it costs.** The web profile is a deliberately bounded subset with no
runtime `eval`, so **client-side mods are out of scope for the browser shell**
(§D5). And `core/` must stay inside the subset — a real constraint on the whole
project, enforced by shared fixtures rather than left to discipline.

## D5. Mods run on the server, and they are sandboxed

A mod is code loaded at runtime. Runtime module loading is a VM capability that
the web profile deliberately does not have. So mods run server-side, and Luanti's
client-side modding is out of scope until a native or wasm client exists.

This is a smaller loss than it looks, and it comes with a genuine gain. Luanti's
mod security is a known weak spot: mods are Lua with `insecure_environments`, a
global trust setting, and a documented history of "don't install mods you don't
trust". **A mod API where "this mod cannot touch your filesystem" is enforced
rather than promised is a better mod API than Luanti's**, and it is a reason to
do this project in Gene specifically.

That property is built and enforced (§D5.2, §9.3). Getting there required
understanding why the obvious mechanism does not provide it.

### D5.1 Why namespace filtering alone is not a sandbox

Gene's capability names construct inert specifications; they do not mint
authority. A filesystem operation succeeds only when the active context
contains a matching sealed grant. Merely naming the builtin is insufficient:

```gene
($fs/write_text "/tmp/anything" "written")
```

That call is denied in an empty context even though `$fs` resolves from the
builtins root.

That rules out the two cheap fixes:

- **Withholding namespace imports is not the authority boundary.** The active
  capability context is; `--grant` is not a launcher authority channel.
- **Auditing a mod's `import` lines does nothing**, because the mod need not
  write one.

**The security boundary is the module's capability ceiling.** Namespace
filtering remains useful defense in depth and produces clearer “API absent”
errors, but it is not what protects the filesystem. A sandboxed module gets a
restricted builtins scope *and* a sealed context ceiling; nested imports and
later re-entry intersect with that ceiling, so neither a visible builtin nor a
broader caller can restore removed authority.

### D5.2 The restricted root (surface filtering)

The design turns on one property of the VM: **`gene` is resolved at runtime, not
baked in at compile time.**

```
$fs/write_text  ->  0: opLoadName name=gene
                    1: opPushConst const=0     # (select fs write_text)
                    2: opApplySelectorTop
```

`opLoadName` is a **scope-chain lookup**. So a module root whose parent binds a
different `gene` gets a different standard library, and every `$x` in that module
goes through it. Two pre-existing properties make it a boundary rather than a
suggestion: `gene` is in the compiler's `reservedStdlibRoots`, so a mod cannot
rebind it to fetch the real one back; and `$` is *only* sugar for `gene/`, so
there is no second spelling to close.

**`($runtime/load_sandboxed dir entry grants shared)` is the surface.**

- **`grants`** is a list of standard-library namespace names — `["fs"]`, or `[]`
  for a module that gets computation and nothing else. A denied namespace is
  **absent** from that module's `gene` rather than empty, because a missing
  namespace cannot be called where an empty one might grow a member.
- **`dir`** is the sandbox boundary, and it is **supplied by the host**, never
  derived from anything the mod writes. `entry` is what the manifest names and is
  resolved *inside* `dir`; an entry that climbs out is refused.
- **`shared`** is the list of modules outside `dir` that the mod may import,
  named by the host. Everything else in the package is refused at the import.

**The boundary is the mod's directory.** A mod's own files compile under the
restriction; everything outside is the host's engine. That is required rather
than conceded: a recompiled `core/api.gene` brings its own type identities, so
the mod's `Game` would stop being the host's `Game` and `register_all` could not
be called at all. Deciding by *path* makes it deterministic instead of dependent
on what the host happened to load first.

**Why `dir` and `shared` are host parameters is the load-bearing part of the
design.** Both were originally inferred — the boundary from the manifest's
`^entry`, the shared set from a rule about where files may live — and both
inferences were walked through by a mod that simply restated them. A manifest
picks its own entry, so a mod placing its entry two directories down moves the
boundary out from under its own files; and the mod writes its own import paths,
so "a host must not put reachable code where a mod can reach it" is a rule about
the whole package root. The general form: **derive a boundary from something with
no valid empty case and no input the subject controls.** An obligation the
subject can restate at will is not a boundary.

**The module cache is keyed by the grant set.** Without that it is a hole in both
directions: a module the engine already loaded with full authority handed to a
mod that must not have it, and a module first loaded *under* a sandbox coming
back stripped for trusted code. One module compiled twice is the price of the two
meaning different things. The key is the grant set itself and not whether it is
empty — a mod granted *nothing* has an empty grant list, and keying off emptiness
makes the strictest sandbox the leakiest.

Two refusals, each because the alternative is worse than an error:

- **A sandbox cannot load another sandbox.** Nesting would let a mod choose its
  own grants, and the grants a mod gets are the manifest's to decide.
- **An unknown grant is refused rather than ignored.** A manifest asking for
  `"filesystem"` instead of `"fs"` would otherwise load with *less* authority
  than it declared and fail somewhere unrelated.

**Thirteen tests in `tests/test_modules.nim`** cover the properties, including
the ones a well-behaved mod never exercises: a mod that names `$fs` with no
grants is refused; a module the sandboxed one *imports* is also restricted; a
function called back *into* a sandbox later is still restricted, because the
restriction is on the scope rather than on the load; trusted code loading a file a
sandbox also loaded keeps full authority; and a mod shipping its own
`package.gene` cannot author its own grants.

**What this does not do.** It does not restrict what a *host* passes in: a
sandboxed mod handed a `Game` can call anything reachable through it, which is
why `core/api.gene` is the surface §D5 cares about. It does not sandbox the web
profile, which has no runtime module loading at all. And it is a namespace
boundary, not a resource one — a granted `fs` is all of `fs`, not a directory.

One diagnostic is worse than it should be: a call into a withheld namespace reads
`value is not callable: vkVoid`, which names neither the namespace nor the
withheld authority. It is a diagnostic, not a hole.

## D6. Milestone 0 — the probes

Before any game design, answer the questions that invalidate everything
downstream. Three probes, each cheap, each able to kill or reshape the design,
and none of them cheaper by being discovered in M3.

### D6.1 The render spike

A fly-through of a static voxel world. 16³ chunks, one texture atlas,
face-culled meshing, WebGL2, a mouse-look camera, no game logic, no server, no
networking, no mods.

**Passes when**, at 1280×720 on a mid-range laptop: a 12×4×12 chunk view holds
60 fps steady; meshing one 16³ chunk stays under 8 ms, so a chunk can be
remeshed inside a frame without a visible hitch; no `bigint` appears on the
meshing or render hot path; and the WebGL2 bindings check against
`lib.dom.d.ts` like every other binding in the profile.

| failure | what it means | fallback |
|---|---|---|
| meshing too slow, rendering fine | the core's hot loop is the problem | move meshing behind a Web Worker; then a typed/packed `Buffer` (§D7.2) |
| render calls too slow | per-call boundary cost | batch through typed arrays; fewer, larger draws |
| the profile can't express it at all | the subset is too narrow for 3D | escalate to the wasm host-bridge path |

**It passes, with a wide margin.** `core/mesh.gene` (face-culled meshing over an
18³ padded neighbourhood), `core/vec.gene`, `client/render.gene`,
`client/atlas.gene` and `client/main.gene`, with `tools/mesh_bench.mjs` as the
headless harness. A chunk generates, lights and meshes in **0.22 ms**, worst
chunk 0.91 ms against the 8 ms budget. In a real tab the client draws 229 chunk
meshes and 62,417 faces at **166 fps** while running physics — and that is the
display's refresh ceiling, not the engine's: over 89 sampled frames the median
interval was 6.00 ms and nothing exceeded 8 ms.

**The bigint criterion is met from the source side rather than the compiler
side.** A `(Buffer U16)` read emits `BigInt(arr[i])`, because §D7.1 types
integer-buffer elements as `Int` to match the VM — measured at 6.4x against a raw
typed-array scan, once per neighbour test, roughly 28,000 times per chunk. The
answer is that node columns are declared `F32` and content ids `F64`: `F32` holds
every integer below 2²⁴ exactly and §2 caps content at 4,096 ids, so nothing is
lost and no conversion is emitted. Eliding the conversion in the compiler instead
was tried and reverted — it made the two backends disagree about what an `Int`
is, which is the divergence class §D3.1 exists to prevent.

Two traps when re-measuring frame rate, both of which produce numbers that look
real:

- **A backgrounded tab throttles `requestAnimationFrame`** — measured at 6 fps
  against 166 for the same build a second later. macOS also marks an *occluded*
  window hidden, so Chrome being frontmost is not enough. `document.hidden` and
  the rAF count are the only reliable signals, and a screenshot *forces* a
  render, so sampling right after one reports a burst rather than a rate.
- **`python3 -m http.server` sends no `Cache-Control`**, so a plain reload can
  silently re-run the previous build.

The spike stands at world (-1440, 3168) rather than the origin: §3 gives biomes a
~555-node scale and this view is 192 nodes across, so wherever it stands it sees
one or two biomes, and at the origin it stands in the cold quadrant and is
uniformly snow. The site was found by scanning for the view with the most
distinct biomes and a coastline; nothing in the generator is tuned for it.

### D6.2 The divergence probe

Runs the exact `F64` chains mapgen depends on through both backends and compares
decomposed float bits — not printed floats, because the VM prints `1e-7` as
`0.0000001` while agreeing on every bit.

**Zero differing bits over 323 samples**, which is what makes §D3.1's exact half
an enforceable rule rather than a hope. Worth being precise about what that
proves: both backends run on one machine and one libm here, so this is evidence
the *algorithm* is bit-stable, not that every future host will be. §D3.1's rule
and the fixtures that enforce it stay.

### D6.3 The worldgen throughput probe

The server generates terrain on the interpreter and cannot move that work to V8
(§D4), so the question is whether it keeps up with a walking player.

**The generation unit is a 16³ block, and this probe is why.** Generating an 80³
chunk — Luanti's unit, and this design's first choice — measures at 302 s against
a 300 ms budget. The finding is not that 3D noise is expensive: a single message
send is ~500 ns and `(buf .get i)` is a message send, so 512,000 nodes cannot be
*written* inside 300 ms whatever is written. **The unit was wrong, not the
terrain.** §3.1 is the consequence.

`gene run worldgen` measures whole blocks rather than extrapolating, and reports
the budget three ways, because shrinking the unit by 125× and keeping the same
300 ms would weaken the requirement by 125× while appearing to pass:

| | reading | result |
|---|---|---|
| A | 300 ms per generation unit | **passes** — 32.6 ms, 9.2× margin |
| B | the node rate the 80³ unit implied, 1,706,667 nodes/s | **fails** — 125,644 nodes/s, 13.6× under |
| C | one lane ahead of a 4 node/s player at §D6.1's view | **straddles** its 76.92 ms threshold |

B fails and is expected to. It is reported rather than dropped because it is the
strict reading, and hiding it would make the milestone look like it closed a gap
it did not. C is the only one of the three derived from the game rather than from
an arbitrary volume — a player crossing a block boundary every four seconds pulls
in a slab of 13 blocks per second at the spike's view distance.

**C is currently inside the run-to-run spread and so is not a check that passing
or failing tells you much about.** Ten runs on one machine spread 74.9–78.8 ms
against a 76.92 ms threshold. It wants either a budget with margin or a median
over runs; until it has one, a single red C is not evidence of a regression.
§D7.11's AOT path is what would make the question moot.

## D7. What Gene gains — the missing-feature backlog

This is the "add missing features and libraries along the way" list, ordered by
when it blocks. Each item is a contribution to Gene rather than to the game, and
each lands with the spec coverage the repo requires (`nimble spec`,
`nimble transpile_spec`).

**1. WebGL2 host bindings + typed arrays (web profile). Blocked M0. Landed.**

Typed arrays landed not as a new web-only type but as **`(Buffer T)`** — the same
buffer the VM has — so `core/` meshing code is one module on both backends rather
than two. `(Buffer F32)` lowers to `Float32Array`, and `(b .get i)` /
`(b .set i v)` compile to plain indexed access. Element vocabulary is
`I8 I16 I32 U8 U16 U32 F32 F64`; `I64`/`U64` are excluded because
`BigInt64Array` elements are `bigint`. **Indices and lengths are `F64` on both
backends** — the VM's `Buffer/get`/`set` were widened to accept an integral
Float — because an `Int` index is a `bigint` in the profile and would allocate one
per element write in the meshing loop.

WebGL2 is 39 bindings covering context, buffers, shaders, programs, attributes,
uniforms, vertex arrays, textures, state, and draw calls. `Gl` is its own type,
and the six handle types share one kind carrying a name, so a shader cannot be
bound where a buffer is expected. Enum arguments are **compile-time-checked
strings** — `($gl/bind_buffer gl "array" vbo)` — resolved to their WebGL constants
during analysis, so a typo is a compile error naming the argument rather than an
`INVALID_ENUM` on a frame that renders nothing.

**2. Packed typed `Buffer` (VM). Open.**

`Buffer` is `seq[Value]`: 8 bytes per element and a boxed write per `set`. A 16³
block is 4,096 nodes; at 4 bytes per node that is 16 KB packed and 32 KB boxed for
content ids alone, before the two parameter arrays. The consumers are all
server-side — holding loaded blocks resident, light, and the storage and protocol
codecs, which both want a packed byte run and both pay an element-by-element pack
and unpack today.

Wanted: unboxed storage for `U8 U16 I32 F32 F64`, with `Buffer/get`/`set`
compiling to a direct indexed access on the known-element-type path. This is the
item most likely to need care — it touches the NaN-boxed value layer, and
`AGENTS.md`'s rules about `sizeof(Value)`, zero initialization, and
allocation-free hot paths all apply.

It was listed as §D6.3's escape hatch and was not needed: the granularity change
plus the cheap rungs of the mitigation ladder were enough. On the *web* side the
element type turned out not to be a footprint question at all but a
representation one (§D6.1), which is a source change rather than a VM change and
leaves this item where it was.

**3. `fs/read_bytes` + binary integer/float codecs. Blocked M4. Landed.**

`fs/write_bytes` existed and `fs/read_bytes` did not. `$binary` could slice and
concatenate but could not read a `u16` LE or write an `f32`, so every binary
format in Gene rebuilt that from `$bit`.

Landed as `fs/read_bytes` plus twelve codecs — `get_u16/u32/i32/f32/f64` and
`put_u8/u16/u32/i32/f32/f64` — little-endian at a **byte** offset, so a record
with a `u8` tag followed by a `u32` can name the second field, which no
per-element index can. Out of range **raises** rather than wrapping: a silently
truncated node id is a corrupt world that reads back cleanly, which is the worst
shape a storage bug takes.

`db/sqlite` blob support went with it: `Db/execute` rejected `Bytes` outright and
blob columns came back through `columnText`, truncated at the first NUL (§11.1).

**4. Deflate/inflate. Open, with a measured payoff.**

Luanti stores blocks zlib-compressed. §11 ships run-length encoding instead and
measured the gap: RLE takes a block from 24,576 bytes to a mean of 612 (40x), and
on the busiest block zlib on the raw arrays reaches 228 where RLE reaches 1,320.
**Deflate is worth another 5.8x on top of RLE**, so this is a size optimisation
with a number rather than a blocker, and the format's flags byte is where it
lands.

**5. Deterministic noise library (pure Gene). Blocked M2. Landed.**

`core/noise.gene` and `core/exact.gene`, confirmed bit-identical across backends
by §D6.2 and used by all of §3. Value/Perlin/simplex plus fractal octaves,
matching the shape of Luanti's `src/noise.cpp`. It sits in §D3.1's exact half, so
it is constrained to `+ − × ÷` and integer hashing, which makes it the best
cross-backend fixture in the project. `core/field.gene` sits on top: the library
is exact, and sampling it once per node is unaffordable, so the field is sampled
on a coarse world-anchored lattice and interpolated (§3.2).

**6. Vector/matrix math (pure Gene). Blocked M0. Landed.**

`core/vec.gene` and `core/raycast.gene`: `mat4` identity, perspective, view and
multiply; `vec3` length; a yaw/pitch forward vector; and the Amanatides–Woo voxel
traversal §7 asks for. The AABB half is not a module — `core/physics.gene`
resolves the player box against the grid per axis and never needs a general box
type.

**It has not been promoted to a Gene library, and that is deliberate.** The
matrices are written into a caller-supplied `(Buffer F32)` and are 4x4
column-major because that is what `uniformMatrix4fv` takes, and the traversal
returns into a caller-supplied `(Buffer F64)` because §7.1 runs it inside a click
handler and a returned record would allocate. Both shapes are right for this
engine and wrong for a general library, which would want values and returns.
Promoting it means designing that trade, and the second consumer that would pay
for it does not exist.

**7. WebSocket *client*, or a real socket API. Blocked M6. Landed for the
browser; open for the native shell.**

The server side of RFC 6455 exists; nothing on the **VM** can open a connection,
so a native client still needs either the client half or a general socket API.

What M6 needed was the **browser** half plus binary frames on both ends, and
neither end could carry a byte. Three gaps, all closed:

- **`ws_send` was text-only.** It now takes a `Str` or `Bytes` and picks the
  opcode from the value's kind — not from a flag, because RFC 6455 requires a
  text frame to be valid UTF-8, so sending bytes as text is a protocol violation
  rather than merely wasteful.
- **An inbound binary frame was dropped silently.** Opcode `0x2` fell through the
  delivery `case` with no branch: no callback, no error, no close. Text now
  arrives as `Str` and binary as `Bytes`.
- **The web profile had no WebSocket binding.** Ten now: `ws/connect`, `on_open`,
  `on_text`, `on_bytes`, `on_close`, `send`, `send_bytes`, `close`, `open?`,
  `buffered`. A socket travels as an `EventTarget` — which it is — so no new
  handle type was needed.

Two decisions inside that: **`binaryType` is set to `"arraybuffer"` on connect**,
because the default is `Blob`, whose bytes are reachable only through a promise,
so a handler reading a message synchronously finds `event.data` is not a buffer —
at runtime, with no error, on the first binary frame. And **text and binary
arrive on separate callbacks** rather than one `on_message` taking a union,
because the profile does not narrow a union on a truthiness test, so a handler
typed `Str | (Buffer U8)` could not tell which it had.

**A defect this exposed was worth more than the feature.** A WebSocket callback
runs as a fiber, and `dispatchWsHandler` returned a task nobody read — so an
exception inside `on_open`, `on_message` or `on_close` *vanished*. A handler with
a typo did nothing, reported nothing, and left the socket open and idle, which is
indistinguishable from a client that sent no message. Handler tasks are reaped
each loop pass and a failure is logged. They remain fire-and-forget, but a
failure is now *said*.

**8. General N-argument FFI. Blocks the native shell.**

The §D2 finding. Either libffi (a new runtime dependency, which `AGENTS.md` says
to avoid without an explicit request — so this needs a decision, not an
assumption) or generated per-ABI trampolines. Large, strategically valuable to
Gene far beyond this project, and correctly sequenced *after* there is a running
game that justifies it.

**9. Audio. Landed, and much smaller than expected.**

Two bindings rather than dozens: `$audio/tone` (frequency, duration, gain) and
`$audio/noise` (duration, gain). Each builds three Web Audio nodes, ramps the
gain to silence rather than cutting — an oscillator stopped mid-cycle is a click
that sounds like a bug — and discards them. A game needs a thud when you dig and
a tone when you place; the *graph* is what a mod authoring a soundtrack needs and
can be added later without changing these two.

One browser rule shapes the code: a context created before the user has
interacted with the page is not an error, it is a context stuck in `suspended`
that never plays. So the context is made on the first sound, which by
construction is a click or a keypress.

**10. The VM's call and message-send cost. Blocks nothing; raises every
ceiling.**

A `(buf .set i v)` costs ~0.61 µs and a trivial call ~480 ns — roughly 1,500
cycles, where a tuned bytecode interpreter spends 50–150. That single number is
what makes 512,000 node visits impossible in 300 ms and what forced §3's
granularity.

A first pass landed and found two things. **The typed boundary, not the call, was
the cost:** a one-argument function measured 183 ns/call untyped and 557 ns as
`[x : F64] : F64`, because `adaptBoundary` allocated an error label per typed
parameter per call and `matchesTypeExpr` reached its answer through ~ten string
comparisons. `bareScalarSatisfied`, dispatching on interned symbol ids over the
exact-kind scalars, took it to 330 ns. And **`Buffer/get` was O(n)** —
`bufferItems` returned the backing `seq` by value, so every element read copied
the whole buffer and any scan was O(n²). Returning `lent` fixed it.

That is worth ~25% on the §D6.3 workload and does not change its shape: an
incremental interpreter pass cannot close three orders of magnitude.

**11. The AOT lowerable subset. Landed, and it is the answer item 10 is not.**

The interpreter was the wrong thing to optimise. `core/exact.gene` and
`core/noise.gene` are fully annotated `F64` with no dynamism — the exact case
ahead-of-time compilation exists for, and one where a JIT would have nothing to
speculate about. `gene compile --target c` and `aot/load` already existed; what
did not was a lowerable subset wide enough to accept the code. Of all of
`exact.gene`, exactly one function lowered, and functions that failed were
**silently omitted** rather than reported. Six changes fixed it:

| | why it blocked the kernels |
|---|---|
| scalar functions get the statement lowering | locals and `while` were reachable only through `hasNativeRepr` |
| local type inference | `(var i : F64 0.0)` was required, which no Gene is written like |
| `/` by a provably non-zero divisor | `wrap32` divides by 2^32 |
| `$math/floor`/`ceil`/`trunc`/`abs` | every lattice-noise function floors |
| module `let` constants, inlined | a kernel names its magic numbers |
| nested calls as call arguments | `(mix32 (wrap32 seed))` — composition |

The whole hash and lattice-noise stack lowers now. **`value3`: 1,088 µs
interpreted → 1.99 µs compiled, 547x.** The remaining ~2 µs is the dynamic entry
adapter rather than the arithmetic.

**A correctness finding came with it and matters more than the speed.** The first
compiled build disagreed with the interpreter on 405 of 4,000 values — not a
lowering bug: Clang defaults to `-ffp-contract=on` and had contracted `a*b + c`
into a fused multiply-add, rounding once where Gene rounds twice. More accurate,
and a *different number*, which for §D3.1's exact half means a compiled server and
an interpreted client generate different worlds. The backend now emits
`#pragma STDC FP_CONTRACT OFF` itself, so faithfulness does not depend on the
caller passing a flag.

Two constraints remain, and they are now binding rather than the subset:
**cross-module AOT calls** (`localAotFunction` sees only the current compilation
unit, so `noise.gene` calling `exact.gene` does not lower), and **`(/ sum norm)`
by a computed divisor**, which is what `fbm2`/`fbm3` end in — lowering them needs
a way for compiled code to raise.

**12. `Buffer/len` answers a different type on each backend. Open.**

The VM returns an `Int`; the web profile's underlying `.length` is a `number`,
which is `F64`. Arithmetic coerces on both, so using a length as an *operand*
works either way and nothing noticed for four milestones. Using it as a *value*
fails on whichever backend you did not try.

**It is `.len` specifically.** A buffer *read* is `Int` on both backends, so
`($to_float (b .get i))` is the ordinary conversion and compiles everywhere.
`.len` is the one operation in the portable surface whose type depends on which
side you are on — and **the obvious fix does not exist**: `$to_float` is total on
numbers on the VM and deliberately partial in the profile, which rejects a value
already of the target kind. So `($to_float (b .len))` fails on the web, the bare
form fails on the VM, and no single spelling compiles for both.

The workaround is `(+ 0.0 …)`: mixed arithmetic promotes to Float on the VM and is
a no-op on a JavaScript number. `core/wire.gene` wraps it once as `byte_len`
rather than spreading the idiom. The fix is for `Buffer/len` to answer `F64` on
both sides, matching item 1's reasoning — but it is a VM-surface change with
existing callers, so it wants doing deliberately rather than inside a game
milestone.

**13. Named parameters in the web profile. Blocked M7. Landed.**

`^name : T` was a VM-only parameter form: a module function declaring one failed
to transpile. That is a small hole with a large consequence, because `^name` is
where argument ergonomics belong for a *registration* API, and §9's mod API is
nothing but registrations. Ten positional parameters is a shape only its author
can read, and a definition is read far more often than written.

The profile takes named parameters on **module functions**, with `^name local : T`
and `^name : T?` as on the VM, and lowers them to positional JavaScript slots in
declaration order — the profile knows every callee statically, so a call's props
are placed into their slots during analysis. No options object and no allocation,
and an exported function stays positionally callable from JavaScript. Four
refusals fall out of the lowering, each source-located: no named parameters on a
`message`, `ctor`, extern or callback, since an `(Fn [A …] R)` type has nowhere to
put a name; no positional parameter after a named one; no
function-with-named-parameters used as a value; and no defaults, since `: T?` is
the spelling for optional.

**It also closed a silent divergence.** Props on a call were being *dropped*:
`(add 1.0 2.0 ^oops 9.0)` compiled and threw `^oops` away, while the VM raised
`got unexpected named argument` for the same source. No fixture could see it
because the profile emitted working code — the exact failure mode §D3.1's rule
exists to prevent. Nine cases now hold the contract, four of them asserting that
both backends refuse the same source.

**14. Neither backend re-exports an imported binding the same way. Open.**

`core/api.gene` was written to be a mod's only import: it would import the tile
kinds, drawtypes and ore shapes from the engine modules and a mod would import
them from it. That compiles in the web profile and fails on the VM with
`module/namespace has no export`.

The profile allows it because a `let` constant is a literal, so importing one
*copies the value* rather than referencing the other module — and a copied value
is trivially re-exportable. The VM resolves an import against a module's own
exports, and a binding that arrived by import is not one. **A *type* re-exports on
neither**, which is a third behaviour again, and it is why §D5.2's shared list is
six modules rather than one.

This is item 12's shape exactly — one operation in the portable surface whose
meaning depends on which side you are on — with the same tell: the code that hits
it looks completely ordinary. The workaround is to import a constant from the
module that defines it, which has the accidental virtue that every import names
where a number is defined rather than where it was passed through.

The fix wants a decision rather than a patch. Making the **profile refuse** it
matches the VM and is the safe direction; making the **VM re-export** is the more
useful language and is how most module systems behave, but it is a semantics
change with a visibility question attached (is every import re-exported, or only a
declared set?).

**15. The web profile cannot iterate a `PropMap`. Open.**

`(for [k v] in m …)` over a `PropMap` is rejected. The profile has `get` and
`size`, so a map can be *read* by a key already known and cannot be walked.

It costs a spelling rather than a capability. §2 writes a node's groups as
`^groups {^cracky 3 ^falling_node 1}`, which is upstream's shape and the one a
registration site wants; a portable API cannot accept it, so `register_group`
takes one group per call. That is not a bad API — each rating is independently
diagnosable, and it matches `register_tile` and `register_drop_rule` — but it is a
shape chosen by a compiler gap rather than by design.

**16. A tick hook on the HTTP serve loop. Blocked M8. Landed.**

§12's server tick needs to run alongside a blocking `serve`. The loop already
polled with a computed timeout, so this is `^on_tick` plus `^tick_ms`: the tick
deadline joins the ones the timeout is already clamped against, the callback
fires before events so a busy socket cannot starve it, and once per period rather
than once per missed period — a server that fell behind should not run the world
at double speed to catch up. A throwing tick is reported and the loop continues.
`^on_tick` without a positive `^tick_ms` is refused rather than spun on, and
`^tick_ms` without `^on_tick` is refused rather than ignored.

**17. `Callback` was a profile-only synonym for `Fn`. Closed.**

The VM rejects **every** `Callback` annotation, including one carrying nothing
but `F64`, and it does not reject it at the declaration — the annotation is
accepted there and raises at the first call that passes a function *through* it.
A function type has been in the VM all along under the name **`Fn`**, with
variance, generics, named parameters and error rows; `web.nim` accepted
`Callback` *and* `Fn` as spellings of one thing.

**The fix is that the profile drops `Callback`.** One spelling means one thing on
both backends, which is §D3.1's rule applied to the type surface. It has to be an
explicit refusal rather than a deletion: `parseWebType`'s last case reads any
`(Head …)` as a nominal type, so removing the arm would have made
`(Callback [A] R)` compile as a nominal type *named* `Callback` and emit working
code. The profile's `typeName` now prints `Fn`, so a diagnostic never names a
spelling the reader cannot write.

This is what `^action` on `register_abm` (§12.3) and `on_step`/`on_activate` on
entity definitions (§8.2) are written against.

## D8. Delivery phases

Each milestone ends in something runnable. No milestone is "infrastructure only"
— that is how a project like this quietly becomes a year of plumbing.

| | milestone | ends with | needs |
|---|---|---|---|
| ~~M0~~ | **The three probes (§D6)** — done | fly through a static voxel world at 60 fps, a decided determinism rule, a measured worldgen cost | backlog 1, 6 |
| ~~M1~~ | **World model + registries** — done | §1 and §2; 69 + 74 cross-backend checks | — |
| ~~M2~~ | **Mapgen** — done | biomes, caves and ore, drawn by the M0 renderer; §3 | backlog 5 |
| ~~M3~~ | **Lighting + meshing in `core/`** — done | the M0 renderer drawing a generated *lit* world; §4, §5 | backlog 2 |
| ~~M4~~ | **Persistence** — done | quit and come back to the same world; §11 | backlog 3 |
| ~~M5~~ | **Player: physics, dig, place, inventory** — done | a playable singleplayer loop; §1.1, §4.2, §7, §7.1 | — |
| ~~M6~~ | **Client/server split over WebSocket** — done | the same game, client and server as separate processes; §10, §10.1 | backlog 7 |
| ~~M7~~ | **The mod API + the sandboxed runtime loader** — done | the game is `mods/default`, read off disk through §D5's capability boundary; §9.1, §9.3, §D5.2 | — |
| ~~M8~~ | **Entities, crafting, UI, sound** — done | §12's tick, trees, crafting, dropped items, sound, formspecs, mod callbacks, a chest, players as entities | backlog 9 |
| M9 | Native shell | the same game outside a browser | backlog 7, 8 |

**M7 is the point of the project.** Everything before it is the engine a mod API
needs in order to be worth having, and M8's small-but-complete game is built
entirely through M7's API — if it needs an engine change, the API is wrong.

What M8 does **not** have is `on_punch` and `on_death`, and those stay unbuilt
because nothing in this engine can hit an entity (§8.2): they would be fields
nothing could call.

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
  our own. Assets are not copied; textures are generated. Any file that ever does
  derive from upstream carries its license header, and `docs/licenses/` gets the
  entry.
- **Loading Luanti worlds** — plausible later (the format is documented and
  SQLite-backed) and attractive as a validation milestone, but not in M0–M9.
- **Matching Luanti's feature set.** Fifteen years of features. §D1.

## D10. Risks

**The subset constraint is load-bearing.** `core/` must compile for both
backends, and the first thing that does not fit the profile is discovered
mid-milestone rather than at the start. *Mitigation:* every `core/` module gets a
shared fixture from the day it lands, so drift fails a build instead of
accumulating.

It has held — `core/` is 23 modules compiling for both backends and not one needs
a conditional — but **not by being avoided**. It held because Gene grew every
time it did not fit; §D7 is that list. The limit of the mitigation is worth
naming: items 12, 13 and 14 are all operations whose *type* or *legality* differs
by backend while the source looks ordinary, so a fixture that ran on both sides
never exercised the difference. **A cross-backend fixture proves the code you
wrote agrees, not that the code you could have written would.**

**Meshing may be too slow, and it is the one loop that cannot be moved.**
*Mitigation:* it is exactly what §D6.1 measures, before anything depends on the
answer. It is not too slow — 0.071 ms/chunk against an 8 ms budget, over fifteen
node types.

**Determinism between backends.** Two runtimes and two libm implementations
compile from one source, so "same algorithm" is guaranteed and "same bits" is not
(§D3, §D3.1). Terrain must agree exactly; physics need only agree closely.
*Mitigation:* the exact/corrected split is a stated rule with a ban on host
transcendentals in the exact half, §D6.2 measures the real divergence, and mapgen
fixtures fail on one differing bit. The failure mode if the rule cannot hold is
known and survivable — mapgen becomes server-only — which is what makes this a
managed risk rather than a hidden assumption.

**Server throughput, not frame rate, is the ceiling.** §D4 puts the
authoritative workload — mapgen, ABMs, timers, entities, light — on the slower of
the two runtimes, and none of it can move to the faster one. *Mitigation:* §D6.3
measures before §3 designs around it, with a ladder from cheap (fewer octaves) to
expensive (packed `Buffer`, typed functions, AOT).

**This is the risk that came true, and it is still the live one.** §D6.3 missed
its original budget by 1,008x and forced the generation unit to change; §10.1 met
the same wall again at 17.9 ms to encode one block message against V8's 0.032 ms.
The ladder has been climbed as far as it goes without new engine work, and
**§D7.11's AOT path is the rung that is left**. The frame rate has never been the
problem.

**Scope.** This is the largest thing anyone has built in Gene, by a wide margin.
*Mitigation:* §D8's rule that every milestone runs, and a willingness to stop at
M5 with a good singleplayer voxel game if M6+ stops paying for itself. The
willingness turned out to be the useful part rather than the stopping: M6 and M7
were each entered knowing they could be the last, which is why M6 shipped a
reactive server rather than a speculative tick loop (§12.1) and M7 shipped the API
before the loader (§9.1).

---

# Part II — The system

## 1. Coordinates and the world model

**Node.** 4 bytes on the wire (§10) and on disk (§11), exactly Luanti's
`MapNode`:

| field | width | meaning |
|---|---|---|
| `content` | `u16` | index into the node registry (§2) |
| `param1` | `u8` | light: day in the high nibble, night in the low |
| `param2` | `u8` | per-drawtype: facedir, level, liquid depth, color index |

**Those widths are storage, not the in-memory representation.** In memory the
three columns are `F32` and a content id is an `F64`, because `Int` lowers to
`bigint` in the web profile and §5 reads node content seven times per node —
9x to 13.5x, measured (§D6.1). `F32` holds every integer below 2²⁴ exactly and
§2 caps content at 4,096 ids, so the round trip through the narrower wire format
is lossless.

Content ids are **per-world and assigned at load**, never hardcoded; the
`name → id` mapping is stored with the world so that a saved block still means
what it meant. Three ids are reserved with Luanti's meanings: `unknown` (a node
whose definition is missing — drawn, walkable, not deleted), `air`, and `ignore`
(not generated yet; never sent to a client, never walkable).

**Block.** 16×16×16 nodes, indexed `x + 16y + 256z` — upstream's order,
inherited so that the serialized block layout and the loop order of any algorithm
read from upstream agree with ours instead of being silently transposed. X varies
fastest, which is also the inner loop meshing wants.

**Sector/column.** Blocks sharing an `(x, z)`, for column-oriented mapgen and
loading.

**Coordinates.** Three spaces — node coordinates, block coordinates, and
continuous `F64` positions for entities and the camera. Mixing them up is the
classic bug in this genre, and the design wanted three distinct types to prevent
it. **They are `F64` triples passed as three arguments instead**, because the web
profile's nominal types are reference objects: a `NodePos` per node visit would
allocate three million times over a chunk, on precisely the path §D6.1 exists to
protect.

What stands in for the distinction is naming discipline — a function takes
`nx ny nz` or `bx by bz`, never bare `x y z` — plus conversion helpers so the
shift never appears open-coded at a call site. That is weaker, and it has cost a
bug: a fractional node coordinate produces a fractional index, which a
`(Buffer T)` reads as `undefined` in the web profile rather than raising (§7).

Luanti's `BS = 10.0` scale factor is **not** inherited; it exists because
Irrlicht wanted larger numbers. One node is 1.0. **World limit** is ±31,000
nodes, as upstream — it is what keeps a node coordinate in an `s16`.

`core/world.gene`, with `probes/world_spec.gene` — 69 checks shared between the
backends.

### 1.1 A block is the unit of generation, not of client memory

A block remains the unit of generation (§3), of the wire (§10), and of disk
(§11). It is **not** the unit of client memory: `core/loaded.gene` stores the
nodes once, as a rectangular box of blocks in **one node array**, with a parallel
array for §4's `param1`.

The alternative — a padded 18³ neighbourhood copy per chunk — is exactly right
for a fly-through, and rests on §3's property that for a deterministic generator,
generating the margin and asking the neighbour for it are the same answer.
**That stops being true the moment a player digs.** A regenerated margin
describes the world as it was created rather than as it is, and any design
keeping padded copies then has to write an edited node into each of the up to
eight copies containing it and keep them agreeing forever. A stale copy is a face
that should not be there.

What follows from one array, and is why it is worth the churn:

- **Reads are an index.** Physics and node selection (§7) do thousands per second
  and each is three subtractions and one array read, with no block lookup in
  front of it.
- **Meshing needs no gather** (§5).
- **Light crosses blocks** (§4.2).

**The array is one node larger than the world on every side**, and that shell is
not decoration: it is what lets §5's mesher read a chunk's neighbours and §4's
flood test its bounds without either of them bounds-checking. Five faces hold
`ignore` — opaque, so no face is drawn against it, and non-propagating, so no
light leaks out. **The sixth, the ceiling, holds `air`**, because sunlight enters
through it; a shell of `ignore` over the world would stop the sun and leave
everything under it black. Reads outside the array answer `ignore` too, so "the
edge of the loaded world stops you" falls out of an existing reserved id rather
than a special case.

The extent is fixed at construction and does not stream. A world that streams
wants this box sliding over the world, which is a change to who fills it rather
than to what it is.

For a 12 × 4 × 12 world that is 194 × 66 × 194 nodes: 9.5 MB of content and 9.5
of light, against 8.1 MB of uploaded geometry.

## 2. Node and item definitions

A definition is a Gene node — data, not a string DSL and not a closure-laden
object. It is registered, validated against a declared type, and frozen.

The registry splits in two, because the halves have different audiences and
different lifetimes:

- **The client half** — drawtype, tiles, transparency, light propagation, light
  source, and the two flags §5 needs. Serialized to the client on join. Pure
  data; no code crosses the wire. The two light fields are here for *prediction*,
  not for authority — the client needs them to relight around its own edits (§4,
  §7.1), never to derive a received block's light from scratch.
- **The server half** — `on_dig`, drops, ABM registrations. Never leaves the
  server, and lives in `core/drops.gene` and the mod.

That split is what lets the client mesh and predict without executing mod code,
and it is why §D5's "no client-side mods" costs less than it sounds.

**Items** are a parallel registry: name, description, stack max, tool
capabilities. **Groups** are Luanti's cross-cutting mechanism, worth inheriting
wholesale: a node is `{^cracky 3 ^falling_node 1}` and tools declare which groups
they dig and how fast. It is how mods interoperate without knowing about each
other.

### 2.1 The node registry

`core/registry.gene` is the client half, as **nine parallel arrays indexed by
content id** rather than a map or a list of records. Every lookup here is on the
meshing hot path, where `solid?` and `propagates_light?` run per neighbour per
node, and an indexed read into a typed array is the cheapest thing both backends
have.

**Six drawtypes are declared and three are honoured.** `airlike` decides whether
the mesher emits geometry at all, `liquid` makes a node unpointable to the
raycast and swimmable to the physics, and `normal` is everything else.
`glasslike`, `allfaces` and `plantlike` are registered names that no code
branches on, so a node declaring one draws as an ordinary cube. That is invisible
today because nothing declares them, and it is worth stating rather than leaving
as a surprise for the first mod that tries: §5's transparent pass is what
`glasslike` needs, `allfaces` needs the same pass plus a rule against culling
between two of them, and `plantlike` needs cross-quad geometry the mesher does
not emit. An id is cheap, and the enumeration existing ahead of the behaviour is
fine as long as nobody reads it as a promise.

### 2.2 Items and groups

**Items have their own id space**, and that is the decision worth making
deliberately. The shortcut is to hang item columns off the node registry and keep
one space. It fails on the first item that is not a node — a lump, a pickaxe —
because a node id indexes the arrays the *mesher* reads, and a pickaxe has no
drawtype, tiles or light behaviour. So the spaces are separate and bridged by two
columns: `node_of` for what an item places, `item_of_node` for what a node
yields. Both are single indexed reads, which keeps `place` and the drop table from
paying for the split.

**A slot is three cells**: item, count, and wear. A tool that cannot wear out is
not a tool, and wear is `u16` because upstream's range is 65,535 and that makes
it exactly two bytes on the wire. Stack metadata is absent — a Map per stack has
no representation in a numeric buffer.

**Groups are a flat `(owner, group, rating)` triple list, scanned linearly**, and
that is considered rather than lazy: the dense `max_content × max_groups`
alternative is one indexed read and 4,096 × 64 cells to store a few dozen facts.
The scan is affordable because nothing here is on a hot path — a group is read
when a dig starts and when an ABM matches, never per neighbour per node. A group
name is *interned* on first use rather than declared, because a group has no
definition, only a name two mods agree on.

**A rating is difficulty; `level` is permission.** They are separate here as they
are upstream, and collapsing them is a mistake worth naming because it regresses
the whole game silently: `cracky 3` is soft and `cracky 1` is hard — lower is
harder, which reads backwards until you notice the numbers rank how many tool
tiers can manage it — and it scales the *time*. **`level` is permission**, and it
is an ordinary group: a node in `{^level 2}` needs a tool that reaches level 2
and nothing else can break it at all. Keeping permission in a group rather than a
column is what makes it a mod's to use; nothing in the engine mentions obsidian.
Nothing in `mods/default` declares `level`, so every node stays diggable by hand,
and the spec asserts that directly.

**`^groups {^cracky 3}` is not the spelling.** §2 writes a node's groups as a
map, which is upstream's shape and the one a registration site wants. A portable
API cannot take one — the web profile cannot iterate a `PropMap` (§D7.15) — so
`register_group` is one call per fact. That matches `register_tile` and
`register_drop_rule` and makes each rating independently diagnosable, but it is a
shape chosen by a compiler gap rather than by design.

**Not built:** the inventory image. An item that is a node draws as its node's
tile; an item that is not needs an image §6's atlas has no room for. And
**groups and tool capabilities do not cross the wire** — they decide how long a
dig takes and nothing on the client asks yet, since a click digs immediately.
They join `msg_items` on the day the client predicts a dig time, which is the
same day the HUD can say a node is too hard.

### 2.3 Crafting

`register_craft`, built on §2.2's items — every ingredient is an *item* id and
half of them (a plank, a stick, a lump) are not nodes anyone can place.

**Shapeless only, and the reason is §13 rather than laziness.** Upstream has
both: a 3×3 grid where position matters, and a shapeless list. A shaped recipe
needs a grid to arrange items in, a grid needs a formspec, and the ingredient
table is already the shape a 3×3 would index into. A shapeless recipe needs a
list of what you are holding, which the hotbar already is.

Matching is a multiset test rather than a list comparison — ingredients in any
slots, in any order, mixed with anything else.

**The ordering that matters is that the output goes in before the ingredients
come out.** `add` reports what did not fit; taking first would let a full
inventory eat the ingredients and hand back nothing. The spec asserts exactly
that case, because it is the one a hand-run never reaches.

On the wire it is `msg_craft`: a kind byte and **a recipe byte**, with `255`
meaning "the first one I can". The recipe byte is not optional ergonomics. With
four recipes, "make whatever I can" was fine; the chest made a fifth that
`first_craftable` could never reach, because sticks matched first and spent the
planks — so a player could not make a chest at all. Validating a named recipe is
strictly *less* work than searching for one, and §7.1's authority is unchanged:
the server checks the named recipe against the inventory it holds, and a client
naming one it cannot afford gets nothing.

**Four ingredients is the ceiling**, which keeps the table a flat array — a
recipe needing five is a recipe that wants the grid. There is no furnace, because
a furnace is a container; steel is crafted from the lump the ore drops.

## 3. Mapgen

### 3.1 The generation unit is a block

Generation happens in one **16³ block** — §1's storage unit — and the same staged
pipeline fills either shape: a bare 16³ block for the server to store, or the 18³
padded neighbourhood the client meshes from (§5). §D6.3 is why: an 80³ chunk
cannot be *written* inside its budget whatever is written into it.

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
its own padded neighbourhood over all 4,096.

### 3.2 The pipeline

| | stage | shape | module |
|---|---|---|---|
| 1 | base terrain | 2D height, heat, humidity on a coarse world-anchored lattice | `core/field.gene` |
| 2 | biomes | nearest point in (heat, humidity), then run-length column fill | `core/biome.gene` |
| 3 | caves | carved along hashed Bézier worms | `core/cave.gene` |
| 4 | ore | placed from hashed world cells, scatter / sheet / blob | `core/ore.gene` |
| 5 | decorations | trees, placed by a pure function of the column (§3.6) | `core/decor.gene` |
| 6 | lighting | over the whole loaded world rather than per block (§4.2) | `core/light.gene` |

Every stage is a registry a mod can add to (§9), which is Luanti's design and the
reason its games look nothing alike. `mods/default` populates them with a node
set, six biomes, and six ores.

**Every stage obeys one rule: cost scales with output, not with volume.** That
rule is what shapes stage 3 — a per-node `fbm3` threshold costs one noise
evaluation per node by construction, which is 1.8 s for a 16³ block on the VM,
where carving costs what it removes. The same rule puts stage 1 on a lattice
coarser than the node grid and stage 4 on cells that are cheap to reject.

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
about 4%. **On a loaded machine these numbers are contention, not cost** — a
reading taken while `nimble perf` ran reported the bare block at 61 ms and the
*padded* block, half again as many nodes, at 49, which is impossible and is the
tell.

Against §D6.3's three readings: A passes with 9.2× margin, B fails as expected,
and C straddles its threshold. See §D6.3.

### 3.4 What it produces

A generator that is fast because it emits one id is not a passing probe, so
`gene run worldgen` reports composition next to timing:

- **surface** y 9 to 44, median 25, with the sea at 20 — **16.5%** of columns
  under water. The sea level was chosen from that measured distribution; a value
  20 nodes lower floods 1.4% of the world and gives it puddles instead of a
  coastline.
- **biomes** tundra 15.0%, taiga 15.0%, rainforest 21.2%, savanna 12.5%,
  desert 23.4%, grassland 13.0%.
- **caves** 1.5% of rock below the lowest surface, linear in the worm count.
- **ore** coal 0.072%, iron 0.033%, gold 0.006% of a y 0..47 volume, plus gravel
  blobs and sandstone sheets.

Two constraints on how those numbers are read, both of which have produced a
figure that looked real:

- **Biome points must sit inside the range the field actually produces.** `fbm2`
  normalises to [0, 1), so the obvious thing is to place biome points across
  0..100 — but value noise is a mean of lattice hashes, and its realised
  distribution is a bell around the middle: heat comes out over 11..80 and
  humidity over 17..85. A point outside that is a biome covering 0% of the world,
  and nothing says so. The six points sit on a circle of radius 13 about
  (48, 48).
- **Cave density means nothing measured above the surface.** Over y 0..15 the air
  fraction reads ~1.4% whether the generator makes two worms or six, because at
  that height most of the air is the sky above a low column.

### 3.5 Determinism

**A hard requirement.** One `(seed, block_pos)` produces one block, on either
backend, forever. Mapgen is §D3.1's exact half, so this is enforceable rather
than hoped for: the whole pipeline stays inside `+ − × ÷`, comparisons, and
integer hashing, with no host transcendental anywhere in it — including the
lattice interpolation, whose step is a power of two so the fraction is exact.

`probes/mapgen_spec.gene` is §14 layers 2 and 3: **82 checks** that run on the VM
and through the web profile and must produce byte-identical output, including the
two seam assertions above and four golden block checksums.

Generation runs on the server. `spawn` places worldgen tasks on worker lanes,
which requires the captured graph to pass the `Send` check — worldgen input is a
seed, a position, and frozen registries, so it is a natural fit, but the
registries must be genuinely frozen and that is a design constraint on §2.

### 3.6 Decorations

**Placement is a pure function of the column.** A tree is up to six nodes tall
with leaves overhanging two each way, so it does not fit in the block it is
rooted in, and both obvious approaches are ruled out by §3.5: generating into a
neighbour needs blocks that do not exist yet, and a post-pass over the loaded
world makes generation depend on load order.

So nothing is ever generated *into* anything. `decor_here?` and `decor_height`
answer from the world coordinate and the seed alone, and a region being filled
walks every column that could reach it — its own, plus a two-node skirt — writing
whichever of that tree's nodes land inside. Two adjacent blocks agree about the
tree between them because they compute the same function, not because they
talked. That is stage 4's trick for straddling ore clusters, reused.

Two consequences worth stating:

- **The height lattice is sized for the skirt, not the region.** Stage 5 asks for
  surface heights outside the region, and a lattice sampled only over the region
  reads past its own end there. One extra lattice cell each way is cheaper than
  stage 5 sampling its own noise and two stages then disagreeing about where the
  ground is.
- **The chance test comes before the surface lookup**, and the ordering is worth
  98% of the stage: `decor_here?` is one hash, the surface is a lattice read plus
  an interpolation, and about one column in fifty has a tree.

**Leaves are the first node in this game that is drawn and not opaque**, which is
the case §5's two-question face rule was written for. Exercising it cost 3.3× the
world's geometry — 62,395 faces to 208,608 — because every leaf-to-leaf face is
emitted: the rule says a face exists when its owner is drawn and its neighbour is
not opaque, and a canopy is a hundred leaves all satisfying both halves against
each other.

**`^merges_same` is the answer**: one registry column beside `opaque`, letting a
node decline to draw a face against another node of its own kind. **208,608 faces
back to 117,528** — 43.7% of the world's geometry, and nothing looks different
because none of those faces was ever visible. It does not return the world to
62,395, and should not: that was the count before there were trees, and a tree
whose canopy costs nothing is a tree that is not there. What is gone is the
interior of every canopy; what remains is its shell, plus trunks.

Three things about the shape:

- **It is the only question in the mesher that needs both sides of a face.**
  Opacity is a property of the neighbour alone, which is why `face_visible?` had
  only ever taken the neighbour. It takes the owner's id too now, passed rather
  than re-read, because the caller already has it and this is the hottest loop in
  the renderer.
- **It is per-id, not per-drawtype.** Two mods' leaves are different ids and
  still draw against each other, which is right — they do not look alike.
- **It goes on the wire**, because the *client* meshes. A cull the server knows
  about and the client does not is a cull that does not happen.
  `probes/protocol_spec.gene` asserts both that the flag survives the round trip
  and that the game has at least one node using it — a diff of two registries
  that both lost the column reads as agreement.

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
channels, day and night, packed into `param1`, interpolated at render time by the
time of day. Sunlight propagates straight down at full strength through nodes
that admit it and spreads sideways with falloff; light sources flood-fill from
their node.

Updates are incremental — a dig or place enqueues the affected node and its
neighbours and the flood is bounded to the touched region. The naive version
(relight the block) is visibly slow at 16³ and should not be written even as a
placeholder.

**Light is authoritative on the server, and it travels baked.** The server
computes it during mapgen and maintains it on every edit; a block crosses the
wire with its light already in `param1`, and the client renders what it was sent.
The client runs the same propagation code for exactly one purpose: relighting
locally around an edit it is predicting (§7.1), so a torch placed in a dark room
lights up on the same frame instead of after a round trip. That prediction is
discarded when the server's delta arrives.

The client therefore **never derives a received block's light from scratch**. The
alternative reading — both sides computing light independently from node data —
is a standing invitation to the divergence class §D3.1 exists to prevent, and it
would be invisible until a player noticed one dark wall.

Lighting is the first thing to get wrong in a way that is invisible in tests and
obvious on screen.

### 4.1 The model, built

`core/light.gene`: two 4-bit channels in `param1`, day carrying sunlight *and*
sources, night carrying sources only, mixed by the time of day in §6's shader
rather than baked into the mesh — which is what makes a day/night cycle one
uniform moving instead of a world remesh.

**The channels are flooded in place, not in scratch buffers.** The obvious
implementation floods two `dim³` buffers and packs them at the end; this reads
and writes a nibble with three arithmetic operations on a value the message send
already loaded. It is the difference between allocating 46 KB per block and
allocating nothing.

**Sunlight is a boundary condition the caller owns.** `light_region` is handed a
`sky` buffer — the sunlight entering the top of each column — and knows nothing
about terrain. `fill_region` fills it while generating, because it computes the
surface height per column anyway. Deriving it inside the lighting pass instead
costs **5.5 ms a block** re-sampling a height lattice generation had already
sampled.

| | ms per 16³ block, VM | ms per chunk, V8 |
|---|---:|---:|
| stages 1–4, nodes | 33.2 | 0.128 |
| **stage 6, light** | **24.8** | **0.018** |
| meshing | — | 0.076 |

The block a server stores is **58.1 ms** of nodes and light together, against
§D6.3's 300 ms and against the 76.9 ms one lane needs to stay ahead of a walking
player. The client's figure is not the question: a chunk generates, lights and
meshes in **0.22 ms**, worst chunk 0.91 ms against §D6.1's 8 ms.

**One optimisation is load-bearing and the shape of it is the point.** Seeding
the flood from every node the sunlight column walk lit costs a push, a pop and
six neighbour tests per node to discover it has nothing to give. A sunlit node
can only brighten something if a neighbour is *darker*, and under open sky the
only darker neighbours are sideways: above is lit by the same run, and below the
run is the solid node that stopped it. Seeding only the columns whose horizontal
neighbours are still dark — the vertical faces of every shadow, and nothing in
the open — takes a block from **38.9 ms to 15.1 ms**.

Two measurement constraints, both of which have produced a number that looked
real:

- **A lighting stage has to be timed against a buffer something plausible
  produced.** `light_region` measured 164 ms against a block the probe's own
  timing loops had already run over sixteen times; what they leave is mostly air,
  and lighting mostly-air is a flood over the whole volume.
- **The light buffer is reused across chunks in the client**, and the flood only
  ever *raises* a value, so a stale bright node from a previous chunk would never
  be corrected. A fresh block is zeroed by construction; a reused one is not, and
  the zeroing is the caller's job.

### 4.2 The region is the loaded world, not a block

`light_region` takes three dimensions rather than one, and the client keeps its
whole loaded world in one array (§1.1). One call lights 12 × 4 × 12 blocks as a
single 194 × 66 × 194 box, and the boundary the flood stops at is the edge of
what is loaded.

**That is what makes a cave that breaks the surface work.** Per-block lighting
lights the block containing the breach down its shaft and starts the block below
it dark again — upstream lights a whole 5×5×5 chunk at once for exactly this
reason. The alternative, relighting from scratch on the client, is what §4 rules
out.

No line of the propagation changed to get this: the day and night floods, the
sunlight walk, the shadow-wall seeding and the unspread/spread pair are all the
per-block versions. `probes/loaded_spec.gene` asserts the behaviour as a property
rather than a value — a one-node shaft through a two-block-tall world is full
daylight at every node of its depth, including sixteen nodes below the block
boundary. Per-block lighting cannot produce that, because the lower block's sky
is not open, so the number the old behaviour returns is 0 rather than "slightly
different".

Two things a box costs that a cube does not:

- **`dx × dz` is not the z stride.** In a cube the sky plane and the stride
  between z slices are the same number; in a box they are `dx*dz` and `dx*dy`,
  and confusing them transposes the sky.
- **A per-node registry call over a block is nothing; over a world it is
  everything.** Seeding sources scans the region calling `light_source_of` per
  node. At 4,096 nodes that is invisible; at 2.5M it is 5M cross-module calls to
  answer "no" 5M times. Hoisting the emission column takes per-chunk lighting from
  **0.076–0.081 ms to 0.031–0.032 ms**.

A world of 576 blocks opens in **114 ms** on V8: 55 ms to generate, **24.7 ms to
light all 2.48M nodes in one call**, 32.8 ms to mesh.

The lighting queue is sized to §4's contract — the region plus the ring's header
— which is 9.5 MB for that world. The initial flood never holds more than
**40,019 entries, 1.61% of the region**. The contract is kept rather than the
measurement, because an overflow raises and a raise at world open is worse than
9 MB; the number is recorded so a future memory squeeze has somewhere to start.

**The incremental path** is `relight_node`: the two-pass unspread/spread pair,
plus a third case neither pass covers. Sunlight is a boundary condition rather
than something a neighbour hands over, so a dug hole would be lit to 14 by the
open air beside it where a full relight sends 15 all the way down —
`resunlight_column` restores it.

`probes/light_spec.gene` checks the floods against hand-derived values in six
small worlds, and checks the incremental path against a **property**: relighting
after an edit produces exactly what lighting the edited world from scratch
produces, node for node. That property is worth more than the value fixtures. It
catches three classes a fixture of expected numbers would have had to anticipate:
a node zeroed before the unspread pass reads it (so the whole dimming half is
dead code), unspreading past a torch putting the torch out, and a node placed in
open air leaving a lit column under it because full sunlight travels down without
falling off.

## 5. Meshing

Per block, for the six faces of each non-air node, emit a quad when the neighbour
is transparent or absent. Neighbouring nodes must be readable to mesh correctly at
the seams.

**The mesher takes an array index and two strides**, not a copy: the index of the
chunk's own `(0,0,0)` plus the array's `sy` and `sz`, so it can read a chunk out
of any node array that has one node of readable shell around it. A padded 18³
neighbourhood is `chunk_base 1 1 1 18 324` expressed in that form; §1.1's single
loaded array is the general case. Addressing the owner once and reaching its
neighbours by `±1`, `±sy`, `±sz` removes six index computations per node, worth
**0.072–0.075 ms to 0.055–0.065 ms** per chunk.

**Two questions, not one: a face exists when its owner is *drawn* and its
neighbour is not *opaque*.** Collapsing them into one predicate is survivable
while no node is both drawn and transparent; it is what would make glass either
invisible or solid-looking the moment one exists. §3.6's `^merges_same` is the
third question, and the only one that needs both sides.

**The mesher asks the registry rather than carrying a table.** Ids are assigned
at load and mean nothing to a mesher (§2), so drawtype, opacity and the three
tiles are read out of the registry's columns. Doing that naively costs 5.6× —
0.084 to 0.468 ms/chunk — and the whole of it is the `Int`/`bigint` boundary plus
a cross-module call per lookup. With content typed `F32`/`F64` and the two columns
the loop needs hoisted out of the registry once per chunk, meshing is **0.071
ms/chunk**: 16% *faster* than a hardcoded five-node version, over fifteen node
types.

Output is one vertex buffer per material as typed arrays, ready to hand to WebGL
without a conversion pass — seven floats per vertex: position, UV, the packed
light byte, and the face's shading factor. **The normal is not sent**, because the
only thing the shader does with one is directional shading, and that is one float
rather than three.

**The light is the *neighbour's*, not the node's.** A face shows how lit the air
in front of it is, and the node behind the face is solid and therefore dark, so
reading its own `param1` would draw every surface black. That neighbour is the
node `face_visible?` already tested, so the value is free. Flat per face rather
than smooth per vertex — smooth lighting averages the four nodes around each
corner, which is four more reads per vertex and a visible-but-not-structural
improvement.

**The per-face shading factor is a factor *on* §4's light rather than a
substitute for it.** Upstream shades faces the same way and for the same reason:
with one light value per node and no normals in the shader, a cube lit uniformly
on all six faces reads as a flat silhouette.

Transparent geometry sorts back-to-front per block; within a block it is not
sorted, which is what Luanti does and is fine for glass and water.

Greedy meshing (merging coplanar quads) is **not** built. It is a large constant
factor on the vertex count and a real complication for texture atlasing and
per-vertex light, and nothing has needed it — meshing has never been the limit
(§D10).

Meshing is the hot loop of the whole engine.

## 6. Rendering

WebGL2, one program for terrain:

- vertex: model-view-projection, pass through UV, light, and face shading
- fragment: sample the atlas, multiply by interpolated day/night light, apply
  distance fog

**The two channels are unpacked in the fragment shader, not in the mesher.**
Mixing them by the time of day is a per-frame decision, so baking it into the
vertex buffer would mean remeshing the world at every sunrise; the byte travels
as-is and a `u_time_of_day` uniform does the mixing. A day/night cycle is
therefore one number moving. There is a floor of ambient light under the mix,
because a 0 channel is pitch black and a voxel world with nothing visible in
shadow is unreadable rather than moody.

The camera is a first-person fly camera that gains collision in §7.

### 6.1 What is built

`client/render.gene` is one WebGL2 program, and it is the smallest part of this
project that does the most visible work: 229 chunk meshes and 62,395 faces at
**166 fps in a real tab**, which is the display's refresh rate rather than the
engine's ceiling.

Three things a renderer is normally assumed to need are absent, each for a
reason:

- **The atlas is painted at startup, not generated at build time, and not from
  source tiles.** `client/atlas.gene` paints it into an offscreen canvas from
  recipes a mod registered (§9.1) — reaching the browser client over the wire,
  since a mod runs on the server. Procedural rather than shipped, because
  `texImage2D` takes a canvas element directly, which removes a PNG encoder, an
  asset to fetch, and a load event. A build-time atlas becomes right when M9 has
  image files to build from.
- **There is no mipmapping**, so the atlas-padding question never arrives. The
  atlas is sampled with `NEAREST` and no mip chain, which is the look this genre
  wants and also the reason chunk-edge bleeding is not a problem to solve.
- **There is no frustum culling.** Every chunk mesh with a face in it is drawn
  every frame — all 229, which is the cost the 166 fps includes. The culling that
  *is* on is the two kinds §5 and the GPU give for nothing: a face is never
  emitted between two solid nodes, and `cull_face back` drops the far side of
  every quad that is. Frustum culling is cheap and obvious and worth doing at the
  first view distance that hurts; doing it now would be optimising the half that
  was never slow.

The atlas is 8×8 rather than 4×5 because the mesher divides by the column count
and §D3.1 puts the mesher in the exact half, so a power of two keeps every tile
boundary on an exact binary fraction.

Draw order is not built either, because there is one pass — §5's transparent pass
is where back-to-front sorting arrives, and until water stops being drawn opaque
there is nothing to sort.

## 7. Physics and collision

Axis-aligned boxes against the voxel grid, resolved per axis in order, which is
what makes stepping up a single node and sliding along a wall fall out for free
rather than needing special cases.

Player: gravity, jump, step height 0.6 (upstream's `PLAYER_DEFAULT_STEPHEIGHT`,
which is tuned and worth taking), sneak, a fly toggle, and swimming in liquid.

**The physics step runs on both sides** — the client predicts, the server is
authoritative and corrects. This is the §D3 payoff: one source, so a divergence
is a bug in one shared function rather than a mismatch between two
implementations of one rule. It is *not* a promise of identical bits — physics is
§D3.1's corrected half, and the server corrects because two runtimes are entitled
to disagree in the last place, not only because packets are lost. The step is a
pure function of `(state, input, world) → state`, which makes it directly
testable and directly fixture-able across backends.

Node selection is a voxel ray traversal (Amanatides–Woo), not a stepped sample —
stepping misses thin nodes at grazing angles and produces the "can't click the
block I'm looking at" complaint.

**The resolver searches rather than solving.** The exact form computes the node
boundary the leading face crosses, which is four cases per axis and is where this
kind of code goes wrong. Instead: the position before a move is known clear and
the position after is known blocked, so twelve halvings find the furthest clear
fraction to within a quarter of a millimetre. No case analysis, and the invariant
it maintains is one sentence — *the player is never at a blocked position* —
which is what the spec asserts on every frame of every fixture. A step costs
1.6 µs.

Four constraints that are easy to get wrong and are each asserted:

- **The box is inset at its far edge and not at its near one.** Inset at both and
  a player resting exactly on a floor can always move down by another `eps`, so
  the resolver hands back a fraction of a node per frame and the player sinks
  through the world at walking pace. The spec stands five seconds of standing
  still against it.
- **There is no auto-step, and 0.6 is why.** 0.6 is under a node, so it climbs a
  slab or a stair and **cannot climb a whole node — in upstream either**. Walking
  into a one-node ledge in Luanti and having to jump is not a bug, it is this
  constant. What per-axis resolution does give for free is the jump: Y resolves
  before X, so a player who has cleared the ledge moves forward into open air and
  lands on it, with no code that knows what a ledge is. An auto-step mechanism is
  unreachable while §2's content set is full cubes only — every ledge is exactly
  one node — and it becomes real with a `nodebox` drawtype. **Raising the constant
  over 1.0 would make walking the heightfield smoother and is a change to this
  section rather than an implementation of it.**
- **A two-node ledge is inside a jump and a three-node one is not.** 6.5 m/s
  against 9.81 m/s² peaks at 2.15 nodes. The spec asserts both, so the height
  cannot drift unnoticed.
- **`ignore` blocks movement**, which §1 does not say. §1 gives it as "never
  walkable", which upstream implements as *not solid* — you fall through, because
  upstream will have loaded the block by the time you get there. §1.1's loaded
  world has a fixed extent and no such block coming, so the alternative to a wall
  is falling out of the world forever. The wall sits one node outside the world,
  where nothing can see it.

**Node coordinates are whole numbers and `core/loaded.gene` does not check.** A
fractional coordinate produces a fractional index, which a `(Buffer T)` reads as
`undefined` in the web profile: no error, no zero, a value that compares unequal
to everything and propagates. Checking inside every read would be three `floor`s
on the physics hot path to defend against a mistake that belongs at the call
site, so callers holding a continuous position floor before they ask. This is the
class of bug §1's distinct coordinate types would have caught, and what catches
it instead is `tools/world_build.mjs` walking the real generated world — 7,200
frames across §3's terrain, its cave mouths, its shoreline, and 576 block seams,
asserting the same invariant on every frame.

### 7.1 Player edits under authority

Digging is the signature interaction of this genre and the one that feels worst
with a round trip in front of it. Node edits are server-authoritative and mod code
can change their outcome (protection vetoes a dig, `on_dig` replaces the node with
something else, stone drops cobble), so "just apply it locally" is not available.
The policy:

**Reject locally, apply optimistically, reconcile authoritatively.**

1. **Client-side rejection, no round trip.** Out of range, no target under the
   crosshair, unknown node, wrong tool for an undiggable node — the client
   already has the registry's client half (§2) and the raycast, so it answers
   these itself, instantly. Most "nothing happened" cases never reach the network.
2. **Optimistic application of the visual result.** The client applies node →
   `air` for a dig, or node → placed for a place, immediately: remesh, particles,
   sound. This is right nearly always, because the *node* outcome is predictable
   even when the *drop* is not.
3. **Inventory waits.** Drops, wear, and stack changes are never predicted — they
   are exactly what mod code varies, and a hotbar that flickers the wrong item is
   worse than one that updates 80 ms late.
4. **Reconciliation on the server's delta.** On agreement the prediction is
   retired silently; on disagreement the server's value wins and the block
   remeshes.

**In-process singleplayer collapses this to nothing.** The server call is
synchronous over the in-memory channel (§10), so the "prediction" is the real edit
and step 4 always agrees on the same frame. That is a second reason the in-process
server is the right structure and not just a code-sharing convenience — the
latency-sensitive path has zero latency in the mode most players use.

Upstream's answer here is effectively "no prediction; the server sends the
result", which is legitimate and simpler. We take the harder one because a
WebSocket sits between the player and the server rather than a LAN UDP socket.

**Rollback is bounded to one node and *not* to one block.** Changing a node
changes the *light*, and light is not local: digging through a ceiling sends
daylight down a shaft and out sideways at every depth of it, and a lamp lights a
ball fourteen nodes across. Whatever the caller has already turned into geometry
over that whole volume is now wrong, and a chunk it fails to rebuild is a hole in
the world that nothing reports.

So `apply_node` returns the region it could have invalidated. `relight_node` does
not report what it touched and should not start: the flood also runs at world
build over 2.5M nodes (§4.2), and a coordinate decode per changed node belongs in
neither. The region is **over-approximated from what the edit could reach**, for
seven reads and no work in the flood:

- light travels at most `light_max` from where it starts, so the box is the edited
  node grown by the brightest light *already next to it* — 0 in unlit rock, 15 at
  the surface;
- except downward, where sunlight does not fall off (§4), so the box first follows
  the column of nodes light can pass through and *then* grows.

Exact where that is cheap, generous where it is not, and never wrong. Measured on
§3's terrain: a twelve-node shaft dug down from the surface with a lamp at the
bottom costs **0.60 ms for thirteen edits, worst 0.40 ms**, and names **9.2 chunks
per edit on average, worst 12** — about 1.3 ms of remeshing, inside a frame. End
to end in a real tab, including the GPU upload, an edit is **1.8–3.5 ms**, and a
surface dig in daylight can name 27 chunks.

Two smaller decisions:

- **Liquids are not pointable, glass is.** §5's question — is this drawn — and
  this section's question — may this be pointed at — are different, and collapsing
  them either lets a player dig the sea or makes glass unclickable. Upstream
  leaves liquids unpointable for the same reason.
- **Looking and acting share a mouse button**, because the web profile has no
  pointer-lock binding. A drag turns the view; a click that travelled under four
  pixels digs or places. This is a shell limitation rather than a design position.

**Inventory and drops** are `core/inventory.gene` and `core/drops.gene`, plus an
eight-slot hotbar in the client. Two decisions rather than code:

- **A node drops itself unless the table says otherwise.** §2 puts drops on the
  server side, and the table holds *exceptions*. A default of "nothing" would mean
  a node whose drop nobody registered vanishes when dug, silently — the likeliest
  failure of a content set and the hardest to notice, because disappearing is half
  of what a dig looks like. `mods/default` has exactly one exception, grass
  dropping dirt, and that one line is what makes the table worth having.
- **`core/drops.gene` is the server half sitting in `core/`, and says so.**
  In-process singleplayer *is* the server, so the process holding the client holds
  both halves. It is its own module rather than a column on §2's registry
  precisely so that splitting client from server is a matter of who imports it —
  and the browser client no longer does.

What is dropped and does not fit becomes an entity on the ground (§8.1).

`probes/edit_spec.gene` is 45 checks, and three of them are the file:

1. **The traversal never skips.** Over 312 rays fanned across a fixture, every hit
   is one step from the node the ray was in when it struck, on exactly one axis,
   with the first pointable and the second not. A stepped sample passes a head-on
   fixture and fails this.
2. **An edit's relight equals a full relight**, node for node, over seven edits
   including a lamp lit and unlit in a sealed cavern.
3. **The reported region contains every node that changed** — checked by copying
   both arrays before the edit and comparing all 32,768 nodes after, rather than
   by reasoning about the flood.

`tools/world_build.mjs` asks 2 and 3 again of §3's real terrain, and
`tools/client_smoke.mjs` covers the part no module spec can see: that
`client/main.gene` connects them (§14).

## 8. Entities

Server-authoritative active objects with a registry mirroring §2: an entity
definition has a visual, a collision box, and callbacks. Entities are transmitted
to clients as add/remove/update messages. Client-side interpolation between
updates; **no client-side entity logic**.

Static (unloaded) entities serialize into the block they occupy, as upstream —
it is what makes an entity survive the block unloading under it. **Not built:**
this world never unloads a block (§1.1), so there is nowhere for that to happen.

### 8.1 Dropped items

An entity is a stack of items at a continuous position, spawned when a dig yields
more than fits, picked up when a player walks over it, and carried on the wire by
`msg_entity` — **one message for add, move and remove**, because a count of 0 *is*
the removal and a second message kind is one more thing to drop.

It closes a hole a player could see: dig with a full hotbar and before this the
node was simply gone. The spec asserts the property rather than the mechanism —
what a node yields is either in the inventory or on the ground, and the two sum
to what it yielded.

**The player's position travels in `msg_input`, and that is a trust decision.**
Pickup needs to know where a player is standing and this server holds no position
of its own (§12.1). A client that lies about its position can reach an item it
could have walked to anyway, which is a different and much smaller thing than
lying about its inventory (§7.1). When the server steps players itself this field
becomes a correction rather than a source; that wants §7's physics on the server,
which is M9's.

### 8.2 The callbacks

**`on_step` and `on_activate` are built.** An entity is an instance of a
**definition** — §8's registry mirroring §2 — and a definition carries the mod's
functions. The server steps every live entity once a tick, notices whether the
step moved or ended it, and broadcasts; the mod supplies what happens.

`"item"` is a reserved definition name, the way §1 reserves `air`: the engine
spawns a dropped item from §7.1's overflow path before any mod has run, so one
exists from construction with callbacks that do nothing. Registering that name
**appends a definition that shadows it** — lookup finds the newest — which is how
a mod furnishes a reserved kind without the engine needing a mutation path into a
callback list. The web profile has no `set` on a `(List (Fn …))`, and the design
that constraint forced is the better one: it is also what §9's loader wants when
mods are ordered by `depends` and the later one should win.

**`on_punch` and `on_death` are not built, and would be fields nothing could
call.** Nothing in this engine can hit an entity: §7's raycast selects nodes,
there is no damage, and there is no health column. That is a different kind of
absence from a stub with a plan to fill it in.

**Entity physics is the mod's, and the engine gained no notion of gravity.**
`mods/default` registers an `on_step` of eleven lines that reads the node under
the item and moves it down. That is §D8's test for whether the API is right — *if
the game needs an engine change, the API is wrong* — run against a behaviour
rather than a registration.

`probes/web_entity_probe.gene` asserts the property rather than the mechanism: it
fills a hotbar so a dig drops an entity, digs the node holding that entity up,
**stops talking**, and waits for the item to move on a silent socket.

### 8.3 Client rendering

Drawing a dropped item is often assumed to need a new vertex format. A
**billboard** would: it has to face the camera, so it needs the view vector in
the shader or a per-frame rebuild that knows where the player is looking. A
**scaled cube** needs exactly the format that exists — position, atlas
coordinate, light, shade — so it reuses `put_quad`, the chunk shader and the
chunk draw call unchanged. `core/mesh.gene` gained `put_cube` and nothing in §6
changed at all.

A cube is also the better *look*. Upstream draws a dropped item as a flat sprite;
a quarter-size cube in the node's own texture reads as "the block you just dug,
lying there", which is what it is.

`core/seen.gene` is the client's half and is deliberately **not** a subset of
`core/entity.gene`, for the reason §2 splits a node definition in two: a server
entity has a definition, callbacks and a reusable slot; a client entity is a
position and a picture that exists between the message announcing it and the
message removing it. One shared type would put `on_step` in a browser, which is
what §D5 says must not happen.

Three details:

- **Add, move and remove are one call**, because §10 made them one message.
  `apply_entity` answers whether anything actually changed, so a re-announcement
  of a position the client already holds does not cost a mesh rebuild.
- **The tile is the item's node's tile.** §2.2 keeps items and nodes in separate
  spaces and `item_node` is the bridge. An item with no node behind it — a stick,
  a pickaxe — is skipped rather than given a placeholder: §6's atlas has no icon
  for a tool, and a wrong picture is worse than no picture.
- **One buffer for all of them, rebuilt on change.** A chunk mesh is uploaded once
  and redrawn while nothing in it changes; entities move every tick, so a buffer
  each would be an upload per item per fall.

The check counts **draw calls**: an entity message produces one more
`drawElements` of exactly 36 indices — six faces, one cube — and a count of 0
takes both the item and its draw call away. Counting draws rather than reading a
number the client printed is the difference between "the client knows about an
item" and "the client drew one".

### 8.4 The player is an entity

A player is an **entity kind**, not a system. `entity_player` sits beside
`entity_item` in the same table, with the same id, the same position columns and
the same `msg_entity` on the wire. Three things differ and no more:

- **It is drawn bigger** — 0.8 of a node against a dropped stack's 0.28, lifted
  to standing height — which is one comparison in the client against a `kind`
  byte the message carries. Inferring it from the item instead would be a client
  deciding what a thing *is* from what it *looks like*.
- **It is never picked up.** One clause on the pickup scan.
- **Nobody is sent their own.** A cube at your own eye position is a cube in
  front of your camera, so a player entity broadcasts to every connection except
  its own — the first thing in this server that is not sent to everybody.

**The skip is by slot rather than by connection**, which lets one function serve
both kinds: a dropped stack has no owner, so nothing is skipped for it, and a
player has exactly one. That matters because there are two paths that move a
player — its own input, and the *tick* — and a rule applied to only one of them
mails you your own avatar whenever the server moves you. The client then draws a
0.8-node cube locked to its own camera, forever, because it *is* the camera.

**A join tells you about everyone already here.** Without it a second player sees
the first only once the first *moves*, so standing still is invisibility. The
server sends the existing players to a joining client and broadcasts the new one
to everyone else, and `on_close` sends the count-0 removal — a disconnected
player standing in the world forever is §8 failing in the other direction.

**The avatar is a node the mod registered.** `mods/default` declares
`miclone:player`, and the client's existing item → node → tile path (§8.3) draws
it with no new vertex format, no new message and no engine notion of an avatar.
It stays an *item* — the default — because that path starts at an item; nobody
can obtain one, since it is not generated, dropped or in a recipe. A second
lookup path in the renderer for one kind of entity would be the larger oddity.

`probes/web_players_probe.gene` is the only check in the tree that needs two
peers to mean anything: a second client joining is visible to the first, the
first is visible to the second who arrived later, neither is sent their own,
walking moves the avatar, leaving takes it away, and the server moving you does
not send you yourself.

## 9. The mod API

The point of the project (§D8).

A mod is **a Gene package** — `package.gene`, a `mods/<name>/` directory, real
imports, real modules. Not a directory of scripts sharing a global table.

Four things this gets that Luanti's Lua API does not:

1. **Capabilities instead of trust** (§D5). A mod declares the authorities it
   needs; the engine grants exactly those. A mod without `$fs/WriteDir` cannot
   write a file. Enforced by the runtime, not by review.
2. **Real modules and real imports.** Namespaced, with a dependency graph the
   package manager already resolves, instead of `dofile` and a shared global.
3. **Definitions as data.** A definition is a Gene node — inspectable, diffable,
   serializable, printable. `doc/lua_api.md` spends much of its 12,777 lines
   describing table shapes; here the shape is a declared type and a wrong
   definition fails at registration with a position, not at the first dig.
4. **Formspec as data** (§13).

**Mod load order** follows `depends`/`optional_depends`, as upstream.
Registration happens at load; the registries freeze before the world starts, so
§3's worker lanes can capture them.

Explicitly deferred from upstream's `core` namespace: HTTP,
`core.request_insecure_environment` (which the capability model replaces
outright), and mod channels.

### 9.1 The API

Every node, tile, drop, biome and ore is declared in
`mods/default/src/default.gene`, through `core/api.gene`. There is no engine
content module; the engine gets its game from `load_mods` (compiled in) or
`load_mods_from_disk` (§9.3).

```gene
(mod mod_default ^profile web)

(import [Game register_tile register_node register_drop_rule
         register_biome_def register_ore_def]
        from "../../../core/api.gene")
(import [tile_solid tile_overlay] from "../../../core/tiles.gene")
(import [draw_liquid] from "../../../core/registry.gene")

(fn setup_tiles [game : Game] : Nil
  (register_tile game "miclone:grass_top" ^kind tile_solid
                 ^red 96.0 ^green 152.0 ^blue 72.0 ^spread 26.0 ^seed 40.0))

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

Four properties, and what each cost:

1. **Definitions read as what they say.** `register_node` takes named arguments
   and applies every default itself, so a node with only `^tiles` is a solid
   opaque cube because that is what a node is unless it says otherwise — and the
   two nodes that *are* different, water and the lamp, are the two that say
   anything. That cost a compiler change: `^name : T` was a VM-only parameter form
   and this API compiles for both backends, so the web profile learned named
   parameters (§D7.13). A positional API would have made the mod-facing surface no
   better than the `register` it wraps; a VM-only one would have retired the
   in-tab client, which generates its world in the browser and needs the same
   content set.
2. **A mod defines what its nodes look like.** The atlas was a list of constants
   and a matching list of `paint_*` calls with the *number* as the contract
   between them; it is `core/tiles.gene`'s registry, and `client/atlas.gene` walks
   it. A mod that can register a node but not its appearance can only rearrange
   nodes the engine already drew.
3. **And a client draws them without running the mod.** The recipes travel in
   `msg_tiles` (§10), so `client/net_main.gene` paints an atlas for a game it
   never imported. That is §D5's promise made concrete rather than asserted: the
   only thing that crossed the wire is data. A tile is a *kind* and eleven small
   numbers, and the three kinds are the engine's procedural generators — a mod
   that shipped a painter would be code a client has to execute.
4. **Ids stay the engine's.** Nothing in a mod compares an id to a literal;
   registration returns one and the API resolves names to ids at registration, so
   a `^drops` naming an unregistered node fails there with a position rather than
   dropping `unknown` at the first dig.

Two shapes that differ from the obvious one, and why:

- **The registrations take a `Game`.** The web profile re-exports an imported
  constant but not an imported *type* (§D7.14), so an API that hid five registries
  behind five parameters would make a mod import five type names it never
  mentions. It is the better shape anyway: the alternative reaches an implicit
  global, and this is that global, made explicit.
- **`^tiles` names registered tiles rather than image files**, because §6's atlas
  is generated rather than shipped. Image filenames become right when M9 has files
  to name.

A mod's entry is named for the mod — `src/default.gene` rather than
`src/main.gene` — because the web profile emits one flat output directory keyed
by basename, so a second `main.gene` collides with the client's.

### 9.2 The callback surface

Two registrations take a mod's own function:

| | |
|---|---|
| `register_abm ^action` | `(Fn [World F64 F64 F64 F64] Nil)` (§12.3) — the *trigger* stays the engine's |
| entity `on_step`, `on_activate` | a definition registry mirroring §2 (§8.2) |

Not built, each for a stated reason: entity `on_punch`/`on_death`, because
nothing can hit an entity; chat commands and privileges, because there is no
player model.

**What an ABM declares to the engine is only *when* it is looked at.**
`abm_on_change` drains the check queue, `abm_sampled` walks the ambient sample.
Neither declaration names a node — both name a **group**, so a mod adding its own
falling node gets the behaviour by joining `falling_node`.

A mod's function receives `queue_node` rather than the lighting scratch, which is
the general shape: §D5.2 is a namespace boundary, and what a host *passes in* is
the surface that decides what a sandboxed mod can reach.

### 9.3 The runtime loader

`server/mods_runtime.gene` reads a mod's `package.gene`, takes its `^grants`, and
loads its entry through `$runtime/load_sandboxed` (§D5.2). `mods/default`
declares `^grants []` — every line in it is registration and arithmetic, and a
mod that registers content has no business opening a socket.

**`server/main.gene` loads its game this way**, not through the compiled-in path.
A boundary nothing loads through protects nothing. `probes/run_loader.gene`
checks the claim two ways, because either alone is weak: the mod loaded off disk
registers the **identical content set** the compiled-in path gets — 20 nodes, 23
items, 2 forms, every node at the same id — and `probes/badmod/`, a mod written to
be refused because it names `$fs` with no grants, is refused. The equivalence is
what makes the switch safe rather than a leap.

The in-tab client keeps the compiled-in path and must: the web profile has no
runtime module loading, which is the reason §D5 puts mods on the server and hands
a client data. The new failure mode is stated rather than left to be discovered —
the server needs `mods/` under its package root at startup and stops if it is
missing.

**An `Application` owns the module cache, and the builtin takes it from its call
site.** `gene run` builds its own app and never touches the process-global
default, so a builtin reaching for that global finds nil — and minting a fresh one
loads every module the mod imports into a second, empty cache. The mod's
`core/api.gene` is then not the host's, and `register_all` cannot be called at
all. `$runtime/load_sandboxed` takes the app from `call.dispatchScope` and refuses
rather than defaulting when there is no call site to take it from.

**Why this is a security feature and not a convenience.** Runtime module loading
on its own is the easy half; without the restricted root it would give miclone
Lua's trust model with Gene's syntax, which is strictly worse than a compiled-in
mod audited by being in this repository. §D5.2 is the half that makes §D5's
advantage over Luanti real rather than claimed.

## 10. Protocol and networking

**WebSocket**, because it is the only persistent bidirectional transport Gene can
hold (§D2) and the only one a browser client can use.

The consequence is that everything is reliable and ordered, whereas Luanti's
transport offers unreliable channels for exactly the traffic that wants them —
player position updates, where the newest value makes older ones worthless. Over
TCP, a dropped packet head-of-line-blocks the fresh one behind it. The mitigations
are the ordinary ones: send position at a fixed low rate, make every position
message a full state rather than a delta so a late one is merely stale, and keep
block transfer on its own logical channel so a burst of terrain does not delay
movement.

This is a real regression from upstream and it is accepted on the browser-first
path.

**WebTransport is the answer, and the obstacle is on our side rather than the
browser's.** It gives exactly what the regression needs — unreliable, multiplexed
datagrams — and has shipped across evergreen browsers. What it requires is an
**HTTP/3 server**, and Gene's is HTTP/1.1. QUIC plus HTTP/3 in Gene is comfortably
the biggest thing in §D7 that is not the FFI work, so this is scheduled rather
than dismissed: re-evaluate once measured jitter says how much the regression
actually costs.

Message groups: handshake; registry sync (§2's client half, once on join); tile
sync (§9's atlas recipes, likewise); item sync; form sync (§13); block transfer;
node deltas; entity add/remove/update; player input; inventory; craft; form
actions.

**Singleplayer runs a server in-process** and connects to it over an in-memory
channel that presents the same interface as the socket. Upstream's decision, and
it is why there is one code path instead of two — and per §7.1, it is also why the
mode most players use has no round trip in front of a dig at all.

### 10.1 The codec

`core/wire.gene` is a cursor over a `(Buffer U8)`; `core/protocol.gene` is the
messages. Both are `core/`, which is the point: the server encodes on the VM and
the client decodes in the browser, and a format with two implementations is a
format two processes can disagree about.

**Everything is bytes.** The design said "Gene nodes except block data", and the
exception turned out to be the only part that was ever a choice —
`docs/serialization.md` is a VM facility and the web profile has no reader for it,
so a node-encoded message could be written by the server and not read by the
client. That is a real narrowing: a node-encoded message is self-describing and
this is not, so a version skew is a misparse rather than a missing field. **The
version byte in `hello` is what stands in**, and the framing is deliberately just
a kind byte so that control messages can move back to nodes per-kind once the
profile has a reader.

Server-to-client kinds are 1..63 and client-to-server are 64..127. The split is
not cosmetic: a decoder that can tell "this is not for me" from "I do not know
this" gives a better diagnostic than a single unknown-kind error.

Measured on §3's real terrain, 12 × 4 × 12 blocks:

| | |
|---|---|
| a block message | **575 bytes mean**, 5,017 worst, 259 of 576 uniform |
| the whole world | **0.32 MB** against 9.0 MB raw — **29x** |
| the registry | 364 bytes for 16 node definitions |
| the tiles | 406 bytes for 14 tile recipes |
| codec | 32 µs to encode a block, 16 µs to decode |

Run-length encoded on §11's finding that a voxel column is a handful of runs.
**No raw fallback, unlike the disk format**: a stored block that doubled is a disk
cost paid forever, a message that doubles is paid once, and the socket is the
slower half regardless. The alternating worst case is pinned by the spec at one
run per node so the cost is a number rather than a worry.

**The client asks for terrain; the server does not push it.** That is flow control
and it is not optional: the WebSocket server's outbound queue holds 256 frames per
connection and drops the *oldest* on overflow, so a server pushing all 576 blocks
in a loop delivers about 70% of them and reports success — a world with holes in
it rather than an error. The client requests a window it can absorb and asks for
the next when the previous arrives, so a request cannot outrun its own answers.
Blocks are addressed by **linear index** over the extent the client knows from
`hello`, which makes "the blocks I do not have yet" a range rather than a set of
coordinates.

**The server encodes a block in 17.9 ms and V8 does the same work in 0.032 ms —
558x.** That is not a defect in the codec; it is §D6.3's finding arriving
somewhere new. A message send is ~500 ns on the VM and `(buf .get i)` is a
message send, so a block encode is ~16,000 sends before any arithmetic. It is what
makes a 576-block world take ~12 s to transfer rather than the ~0.3 s the 0.32 MB
would suggest — **the socket was never the bottleneck**, which is worth knowing
before anyone optimises the wrong half.

Two ways out, in the order they are worth trying: **delete the two counting
passes** that size the buffer exactly (36% of the cost, needing `Buffer/to_bytes`
to take a length), and **§D7.11's AOT path**, which is the general answer.

Three constraints the spec caught rather than the design:

- **Every `encode_*` has a matching `*_size` and the spec asserts the encoder
  writes exactly that.** Three of the six constants were wrong when first written,
  and an underestimate is a silent overrun in the web profile.
- **`dig` and `place` need separate sizes.** One constant for both would either
  waste two bytes on every dig or overrun on every place.
- **Yaw travels as a fraction of a full turn**, not in thousandths of a radian.
  Thousandths is worse twice over: it uses 6,283 of 65,535 values, and its zero
  point is π — not a whole number of thousandths — so encode-then-decode loses up
  to a thousandth *and cannot be made not to*. A turn fraction has no offset to
  round and resolves 0.0055°.

**A place carries two positions.** A right-click means both "put this here" and
"use that", and only the client knows which node the ray hit — the server holds no
camera (§12.1). Sending only the placement position makes "use" unexpressible:
§13's chest is *pointed at*, and the position that would reach the server is the
empty node beside it. So the message says what was aimed at and where that would
put a block, and the server decides which of the two a right-click meant. That is
also the right division under §7.1: the client reports what it saw and the server
decides what happened.

## 11. Persistence

A world is a directory: `world.gene` for metadata and seed, `map.sqlite` for
blocks keyed by `(x, y, z)`, and — designed but not built — `players.sqlite` and a
per-mod storage directory.

SQLite because Gene already has `db/sqlite` and because upstream proved the shape
works. Writes are batched and asynchronous; a block is written when it is modified
and unloaded, or on a periodic flush.

### 11.1 The block format and the store

`server/blockfmt.gene` (the format) and `server/storage.gene` (the store), with
`probes/persistence.gene` run **twice** — `create` then `verify` — in two
processes, because "quit and come back" is a claim about a process boundary and a
single process that writes and reads back cannot test it.

**SQLite could not hold a block, and that is what the dependency was worth
checking.** `Db/execute` rejected `Bytes` with *unsupported parameter type*, and a
blob column was read back through `sqlite3_column_text`, which stops at the first
NUL and re-interprets the rest as UTF-8 — so every block payload would have come
back truncated, silently. Blob binding and reading landed in `db/sqlite` for this;
the fiddly part is that a NULL data pointer binds SQL NULL whatever the length
says, so an empty blob needs a non-NULL pointer with zero length or it reads back
as `nil` rather than as empty `Bytes`.

**The format is versioned from the first commit**, because a saved world
outliving a format change is the normal case. Magic, version, block dimension, a
flags byte, then a **per-block name table**, then the payload.

**The name table is the point of the header.** A block stores *names* for the ids
it uses, not the ids themselves, because §1 and §2 assign content ids at load —
add a mod and every id shifts. Without it, a saved world turns to stone the first
time the mod list changes. With it, loading re-resolves each name through the
current registry, and a name that is gone becomes `unknown`, which §1 defines as
drawn, walkable and never deleted precisely so this case leaves placeholders
rather than holes. It is per block rather than per world so a block is
self-describing, which is what lets §10 send one over the wire without a separate
mapping to keep in step.

| | bytes |
|---|---:|
| raw, three `u16` arrays | 24,576 |
| **run-length encoded** | **612 mean, 31 min, 4,669 max** |

A 40× reduction for about thirty lines, measured over 80 blocks spanning sky,
surface, shallow and deep. **Runs do not replace deflate**: on the busiest kind of
block — at the surface, where terrain, water and light all vary — RLE gives 1,320
bytes and zlib on the same raw arrays gives 228, so §D7.4 is worth another 5.8×
on top. RLE ships because it is thirty lines against several hundred for a Huffman
coder, and the flags byte is how a versioned format takes the better scheme later.

**`verify` regenerates every block from the seed and compares it against what came
off disk** — a stronger check than a checksum, because it says *which* node
differs. The edits are what make it a persistence test rather than a determinism
test: terrain regenerates from a seed, so a world that only stored generated
blocks would verify identical whether the store worked or not.

Two properties the edit has to have, each of which a simpler edit fails to test:

- **It must exercise `param1`.** An edit one node deep underground, where the
  light is already 0, differs by exactly one node — a store that dropped the light
  array entirely would pass.
- **A lamp needs somewhere for its light to go.** A lamp placed in solid rock
  correctly lights nothing but itself, because §4's flood only enters a node that
  propagates light.

What ships digs a 3×3×3 pocket one node at a time, relighting after each exactly
as §7.1's dig would, and puts a lamp in the middle. `verify` requires 27 changed
nodes, the lamp back at 14, and its neighbour at 13 — the last being the check
that a *neighbourhood* of light survived rather than one value the lamp would
re-derive from its own definition on load.

**Not built, and each for a stated reason.** `players.sqlite`: **player state is
per-connection and dies with it**, so quitting and rejoining resets what you were
carrying while the world you dug persists exactly. That is a real gap rather than
a design, and it needs somewhere coherent to save *from*. A per-world mod record:
a world does not record which mods made it, and it should — the `name → id`
mapping already survives a mod being added or reordered, and what it cannot
survive is a mod *disappearing*, which recording the mod set turns from silent
corruption into a refusal to load.

Writes are batched (a transaction, so a crash leaves the world as it was rather
than partly saved) but still not asynchronous. It has not hurt: an edit persists
one block inside a click, and the measured end-to-end cost is 1.8–3.5 ms.

## 12. Time, tick, and the server loop

Server tick at a fixed rate. Per tick: run node timers, run due ABMs on loaded
blocks, step entities, apply queued player input, propagate liquids, flush
lighting updates, send deltas.

Client renders at display rate and interpolates; it does not tick the server
model.

### 12.1 The reactive half

**Most of what the server does is a response.** It accepts a connection, answers a
handshake, and answers messages: block requests, digs, places, crafts, form
actions. That half is request-driven and stays so — a tick loop adds the
*unrequested* traffic (deltas from ABMs, entity updates), which is exactly the
traffic that needs a rate, and block transfer stays request-driven for §10.1's
flow-control reason.

Two consequences of that shape that the rest of the design leans on:

- **The server holds no player position of its own.** There is no server-side
  physics state to step, so a pickup (§8.1) and an avatar (§8.4) both read the
  position out of `msg_input`. Stepping players server-side wants §7's physics on
  the server, which arrives with the native shell.
- **Per-connection state is a list, not a closure.** The one thing a connection
  owns — its inventory — naturally lives in the `ws_accept` callback's scope,
  which is what makes each client its own player without a registry. But a change
  nobody asked for has to reach *everybody*, and a closure cannot be iterated, so
  the server keeps an enumerable list of connections beside it.

### 12.2 The tick

The tick runs on `serve`'s `^on_tick` (§D7.16): the event loop already slept only
as long as nothing needed it, so a tick is one more deadline to clamp against
rather than a thread. A throwing tick is reported and the loop continues — it
would otherwise take every connected client down with it, and the next tick may
well succeed.

**Sampling cannot do falling, and that is why there are two mechanisms rather
than one.** §12 specifies ABMs as sampled, which is upstream's approach and what
keeps "grass spreads" from being O(loaded world) every tick. Sampling 900
positions a pass out of 2.4M nodes is about six minutes to reach one *particular*
node, so a column whose support was just dug stands there. The two mechanisms are
what §12's own "run node timers, run due ABMs" was already saying:

- **A check queue**, targeted. An edit seeds the position above it, the tick
  drains the queue, and a node that falls seeds its own — which is what makes a
  column cascade a node per tick instead of settling one node per minute. This is
  a *neighbour update*, and it is how upstream does falling too.
- **Sampling**, ambient, for the behaviour it was designed for: grass spreading
  onto a block nobody touched.

"Run it on random positions" and "run it where something just happened" look like
the same feature and are not.

### 12.3 ABMs, and the sampling walk

`register_abm` takes `^action (fn [world x y z node] …)`, which is §9's shape.
`mods/default` supplies both behaviours as functions; what an ABM declares to the
engine is only when it is looked at (§9.2).

**The sampling walk must be a permutation, and the obvious construction is not
one.** Striding three coordinates against one counter — `x = 97t mod nx`,
`y = 43t mod ny`, `z = 61t mod nz` — has a long cycle in `t` and a tiny *image*:
three coordinates driven by one counter trace a one-dimensional curve through a
three-dimensional space, and it closes after `max(nx, ny, nz)` steps. Measured on
this engine's own shapes, that is **192 distinct positions out of 7,077,888**.
Ambient sampling could not reach 99.997% of the world, at any rate, ever.

What replaced it strides the **flat** index by a step near `total × φ`, walked
down until coprime with the node count — which makes the walk a permutation: every
node is visited exactly once per cycle and none is unreachable. Consecutive
samples stay far apart as a consequence rather than a hope (no two within 113
nodes on any shape this engine builds, no repeat in 500,000 consecutive samples).
`probes/abm_spec.gene` asserts the permutation directly on a 2,048-node world.
The bound worth knowing is stated in `core/abm.gene`: the products stay exact
while `total² < 2^53`, a world of 94M nodes, and past that the walk silently stops
being a permutation.

Measured at five passes a second against 200 open-dirt nodes in a 2.4M-node
world: **27 conversions in 60 s against 22.9 predicted**. **The shipped rate is
one pass a second, 900 positions** — a full sweep of the world every 44 minutes.
That is what ambient should mean, and it is a statable guarantee rather than a
hope because the walk reaches everything.

`probes/web_tick_probe.gene` asserts the property rather than the mechanism: it
digs the support out from under a sand column, **stops talking**, and waits for
node deltas to arrive on a silent socket.

## 13. UI

Luanti's formspec is a string DSL:

```
size[8,9]list[current_player;main;0,4.85;8,3;]
```

Mods build it by concatenating strings, which is why escaping bugs and layout
bugs are common, and why it cannot be inspected or composed.

**Ours is Gene data, validated at registration.** That is the claim, and the test
of it is not that a panel appears — it is that a wrong form fails at registration
with the form's name and the numbers. There is nothing in `size[8,6]label[99,99;x]`
that fails until someone looks at the screen.

The client renders forms and the HUD as DOM overlaying the canvas — a thing the
browser shell makes easy and a native shell will have to reimplement.

### 13.1 The HUD

Four DOM elements the client writes text into once a second, plus a CSS
crosshair. It is worth more than a status line because of what it turned out to
be *for*: the HUD line is the project's most-used instrument.

```
60 fps · 229 chunks · 62395 faces · walking at -1335, 21, 3265
```

That is the frame rate, the draw count, the geometry, the physics mode and the
position in one string — and because it is one string, both headless smoke tests
read it as their only window into a running client (§14). Every check about
walking, flying, swimming and where a player is standing is a regex over that
line.

Two things follow that a redesign must keep: **the numbers stay in one line with
stable labels**, because two harnesses depend on that shape; and **the mode stays
a single word from a closed set**, since `walking|flying|swimming|falling` is how
a test asserts that physics ran at all.

The hotbar is eight slots rendered as text and selected with the number keys or
the wheel.

### 13.2 Sound

`client/sound.gene` is the whole of the game's audio and is 40 lines: a dig is a
noise burst, a place is a tone, a craft is two notes a fifth apart. Procedural for
the same reasons the atlas is — no asset to fetch, no load event, no file whose
source nobody has.

**In the networked client the sound plays when the server confirms, not when the
click happens.** §7.1 keeps drops and edits off the prediction path, and a thud on
a dig the server refused is the audible version of the flickering hotbar that rule
exists to prevent. The in-tab client plays on the edit, because in-process the
edit and its confirmation are the same call.

### 13.3 Formspecs

**The vocabulary is closed** — label, item, box, button — and that is the point
rather than a limitation. Upstream's grammar is open, a mod emits whatever text it
likes and the client parses it, and that openness is where the escaping bugs live.
Here an element the client cannot draw is one the registry refuses to hold.

The validation exists twice: `add_element` raises, which is §13's promise, and
`element_fits?` asks the same question without raising — which is what a spec can
assert on both backends and what a tool inspecting a mod's forms would want.

A mod declares a form and the client walks one it has never seen the shape of;
the smoke test asserts the rendered text contains a word that appears nowhere in
the client. That is the composability claim, checked.

Catch headers name an error type and the body reads the value through `$ex`.
`catch Error` matches custom error types implementing the marker protocol on
both backends.

### 13.4 Input, and the chest

**A button carries an action** — a string the mod chooses, handed back verbatim
and never interpreted by the engine. That is the whole contract, and it is what
keeps the element vocabulary closed while leaving the *meaning* open: a mod adds a
control by naming an action, not by teaching the client a new kind of element. A
button with no action is refused at registration.

**Three messages, and they divide the way §13 already divided.** The layout
travels once at join; the contents travel per open, carrying the node, because one
form serves every chest and the position is the only thing that says *which*; a
press travels back. The client rebuilds the registry through
`add_form`/`add_element` rather than by writing columns, so **a form that survives
the wire is one that would have registered** — a mangled form is caught by the
form's own rules rather than by the renderer drawing something strange.

**The attribution is four checks and none of them trusts the message**: this
player has something open, it is the named form at the named node, that form
*declares* this action, and the slot is inside the container. §7.1's rule — the
client reports, the server decides — reaching UI.

**A form with no container is a panel, not a place.** Three of those four checks
are about *where* you are standing, and a crafting panel is nowhere, so what
authorises it is that the form declares the action and that the inventory can pay
— which is what `msg_craft` already enforced. The panel's rows are **controls**
rather than a list, so §2.3's recipe naming reaches a finger: the button carries
`make_<item>`, the server resolves it by asking which recipe makes that item, and
`apply_craft` refuses one you cannot afford. The engine still reads no action
string.

**`core/container.gene` is a node's *state*, which is a third kind of thing.** §2
splits a node definition into a client half and a server half; a chest's contents
are neither. Everything before it was a definition (the same for every node of a
type) or a world column (one number per position). Upstream gives every node a
string-keyed metadata table; this gives a position an inventory and nothing else,
for the same reason the element vocabulary is closed. It is **not persisted and
not dropped when the node is dug**, and both are stated in the module rather than
discovered by a player.

**`container_row` is the question; `container_at` is the command.** `container_at`
allocates a row when there is none, so asking it "is this a container?" answers
yes for every coordinate *and* mints a chest at whatever position was asked about.
A pair of functions where the query is spelled like the mutation is a trap worth
naming, and this design has two of them — `broadcast_entity` beside
`broadcast_entity_except` is the other, where the unconditional spelling reads as
the default.

**Derive state from something with no valid empty case.** "Nothing open" as `-1`
in the x cell of the open position reads as closed for every chest in a world that
sits at x = -1437. A coordinate has no spare value in its own range; the form's
*name* does, and empty is the closed state. This is the same rule §D5.2 states for
the sandbox boundary, one layer up.

**Still absent.** No text field — a form takes presses and not typing, which
covers a chest and does not cover a sign. And there is an asymmetry worth naming:
server-opened forms answer to the server, client-opened forms answer to the
client, because a form the client opens has no `open_at` to attribute a press to.
That is a real seam and the next thing §13 owes.

## 14. Testing and verification

Five layers, and the second is the one that matters most here.

1. **Unit fixtures** for pure core functions — lighting propagation, meshing
   output, physics steps, ray traversal, the codec. Table-driven.

   The most useful assertions in this layer are not values but **equivalences**:
   incremental relight must equal a full relight, node for node (§4.2). That
   catches classes of bug a fixture of expected numbers would have had to
   anticipate.

2. **Cross-backend fixtures.** Every `core/` module runs the same inputs on the
   VM and through the web profile. This is the mechanism that keeps §D3 honest.
   The assertion differs by half, per §D3.1:
   - **exact half** (mapgen, noise, and everything feeding terrain) asserts
     **bit-identical** output. One differing bit fails the build.
   - **corrected half** (physics, prediction, entity motion) asserts agreement to
     a stated tolerance *and records the observed max divergence*, so a gap that
     grows is still a signal even while every run passes.

   A fixture that cannot say which half it is in is a fixture whose author has not
   decided. **And a cross-backend fixture proves the code you wrote agrees, not
   that the code you could have written would** — §D7.12, §D7.13 and §D7.14 are
   all operations whose type or legality differs by backend while the source looks
   ordinary, and no fixture that ran on both sides exercised them.

3. **Golden worlds.** A seed and a block position produce a known checksum. A
   mapgen change that alters terrain has to change the golden value deliberately,
   in the same commit, with a reason.

   Four blocks: one spanning the surface, one deep enough to be all rock and cave,
   one far from the origin so the hash is not only asked about small coordinates,
   and one on a second seed so that the seed is demonstrably not decorative. The
   checksum is a 32-bit rolling hash in `core/exact.gene`'s discipline, so it is
   order-sensitive and both backends compute it identically by the standard rather
   than by luck.

   This layer earns its keep on changes that are *not* meant to alter terrain —
   moving every registration out of the engine and into a mod is exactly the kind
   that could, since one node registered in a different order renumbers every id
   after it.

4. **A headless server + scripted client** for the protocol, as two harnesses that
   are not the same test.

   **`probes/web_net_probe.gene` is a peer** — it speaks the protocol itself, out
   of `core/`, and proves the server answers correctly, including refusing a node
   the client does not hold. **`tools/net_client_smoke.mjs` is a client** — it
   boots `gene run server` as its own process and runs `client/net_main.gene` over
   the platform's own `WebSocket`. Neither subsumes the other: the probe owns "the
   server is right", the smoke test owns "the client uses it right".

   What the client harness stubs is the DOM and nothing else — the transport is a
   real socket to a real process. It swaps in a `WebSocket` **subclass** that
   tallies frames by kind while delegating to the real one, which is what lets a
   failure say which message never arrived rather than "the world did not turn
   up".

   **The peers are Gene and the host harnesses are JavaScript, deliberately.** A
   peer speaks `core/protocol.gene` by source, which is the format under test. A
   host harness installs `document`/`window`/WebGL on `globalThis`, spawns a
   process and polls a port — things the web profile cannot express — and there is
   a second reason to keep it out: **a harness compiled by the compiler under test
   can hide a miscompile in the subject.**

   *Still missing:* disconnect and reconnect within one run, and the mod veto —
   which needs a callback on the **edit** path rather than on the tick.

5. **Silence, for anything the server does on its own.** §12's tick and §8's
   `on_step` are checked by a harness that drives one action and then **stops
   talking**. What is asserted is that a message arrived on a socket that sent
   nothing, which is a property no request/response harness can express.

   Three constraints this layer taught, all about what a harness assumes:

   - **A wait that is too long swallows the evidence.** Waiting 600 ms for a dig's
     own answer lets the whole cascade land inside it, and a working tick reads as
     a broken one. The post-dig wait is 50 ms, under one tick, so the effect cannot
     happen while the client is still notionally talking.
   - **A probe that assumes it is the only source of change breaks the moment the
     engine gains an ambient behaviour.** Counting deltas as a running total is a
     correct reading of "what I caused" only while nothing else can cause anything.
     They count at a position, or from a mark.
   - **A fixed sleep is not "wait for arrival".** Guessing an interval per block
     window gets a fraction of the blocks and reads as a broken server. Poll the
     condition.

   Two environment traps it is downstream of. **The server's stdout is
   block-buffered when it is a pipe**, so a harness waiting for a log line hangs
   while the server is happily serving; the readiness signal is the port. And **a
   port that answers is not a fresh server** — a server that outlived its runner
   keeps the port, and every probe then plays in one accumulated world. A genuinely
   fresh world costs about 75 s to generate.

Performance is a standing gate, per `AGENTS.md`: meshing time per chunk, mapgen
time per chunk, frame time at a fixed view distance, and server tick time at a
fixed player count. **Mapgen time per chunk and server tick time are the two to
watch** — §D4 and §D6.3 both say the ceiling is there rather than in the frame
budget. Regressions are reported with numbers, not hidden.

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
  package.gene            library + applications
  docs/design.md          this file
  luanti/                 reference clone (gitignored)
  core/                   portable Gene — VM and web profile
    exact.gene noise.gene field.gene    §D3.1's exact half
    world.gene loaded.gene              §1, §1.1
    registry.gene tiles.gene item.gene groups.gene   §2
    biome.gene cave.gene ore.gene decor.gene mapgen.gene   §3
    light.gene                          §4
    mesh.gene vec.gene                  §5
    physics.gene raycast.gene edit.gene §7
    inventory.gene drops.gene craft.gene §2.2, §2.3, §7.1
    entity.gene seen.gene               §8
    api.gene mods.gene abm.gene         §9, §12.3
    wire.gene protocol.gene             §10
    formspec.gene container.gene        §13
  mods/
    default/              the game, built through §9's API
      package.gene        a mod is a Gene package
      src/default.gene    named for the mod; main.gene collides in dist/
  server/                 VM only
    main.gene storage.gene blockfmt.gene mods_runtime.gene
  client/                 web profile
    main.gene net_main.gene render.gene atlas.gene sound.gene
  probes/                 cross-backend specs and network probes
    *_spec.gene           portable; run_*.gene and web_*.gene are the shells
    web_*_probe.gene      network peers (§14 layer 4, 5)
  tools/                  harnesses that cannot be Gene — a DOM stub, the
                          process-booting smokes, and web_spec.mjs
```
