# Gene WebAssembly — Design

Status: **Target A ABI v0 implemented and validated; Targets B/C planned.**
Date: 2026-07-03.

Implemented: the §A.4 host ABI (`src/gene_wasm.nim`), a `nimble wasm` Emscripten
build, and `tests/test_wasm.mjs` which evaluates Gene source under node — arithmetic,
the pure stdlib (`str`, `json`), booleans, and both error paths all pass. Key
finding: the full VM compiles to wasm with **no host-subsystem gating required**
(Emscripten stubs the socket/dlopen/fork symbols); the only real portability bug
was init ordering (§A.3). Also implemented: a minimal browser playground
(`web/index.html`) over the same ABI. Not yet built: the fetch async bridge
(§A.5), and Targets B (wasm-in-Gene) and C (Gene-to-wasm).

"WebAssembly support" is ambiguous, and the three things it can mean have almost
nothing in common in terms of work. This doc names all three, recommends an
order, and grounds each against the real runtime — the Nim→C bytecode VM, the
NaN-boxed `Value` layout in `src/gene/types.nim`, the GIR application image from
`docs/proposals/distribution.md`, and the native-codegen plan in
`docs/proposals/jit-pipeline.md`.

## 0. Three meanings of "wasm support"

| | Target | One line | Recommended |
|---|---|---|---|
| **A** | **VM-to-wasm** | Compile the Nim VM itself to wasm so Gene programs run in a browser / WASI host. | **First** — highest value, moderate work |
| **B** | **wasm-in-Gene** | Load and run `.wasm` modules *from* Gene as sandboxed, capability-gated plugins. | Second — fits the existing dynlib-backend pattern |
| **C** | **Gene-to-wasm** | Emit standalone `.wasm` modules *from* typed Gene functions (a codegen backend). | Defer — largest, overlaps the JIT pipeline |

They are independent: A is a *build target* for the existing interpreter, B is a
*native namespace* like `db/sqlite`, C is a *compiler backend* like the planned
JIT. A ships a browser playground; B ships a plugin sandbox; C ships an
ahead-of-time compiler. Do not conflate them in planning or estimation.

---

## Target A — Run the Gene VM in wasm (recommended first)

The Gene VM is Nim compiled through the C backend (`nim c`, see `gene.nimble`).
Nim's C output compiles to wasm with Emscripten (browser) or the wasi-sdk
(server/edge), so "run Gene in the browser" is fundamentally a *build profile*
of the existing interpreter, not a rewrite. The work is almost entirely in
**severing the host dependencies the VM currently hard-imports**.

### A.1 What a wasm host cannot actually do

`src/gene/vm.nim` imports the modules behind Gene's host authority. These
*compile and link* under Emscripten (it stubs the underlying syscalls, so the VM
builds — §A.2), but the capabilities they represent have no backing in a wasm
sandbox, so the corresponding builtins cannot *function* there:

```
import std/[algorithm, dynlib, locks, math, monotimes, net, os, osproc, sets,
            strutils, tables, times, unicode]
when compileOption("threads") and defined(gcAtomicArc): import std/cpuinfo
when defined(posix): import std/posix
else:                import std/streams
```

Mapping each hostile dependency to its wasm reality:

| Dependency | Used for | Browser (Emscripten) | WASI preview 1 |
|---|---|---|---|
| `dynlib` | FFI (`ffi/open`), db/curl/curses backends | **none** — no dynamic loading | **none** |
| `net` | `Net/tcp-*-async`, `net/http` server | no BSD sockets (fetch/WebSocket only) | no listening sockets; limited connect |
| `osproc`, `posix` | `os/exec` (agent `run_shell`) | **none** — no subprocess | **none** |
| `os` (env, fs) | `os/get_env`, `Fs/*` | virtual FS + bridged env | real files + env |
| `locks`, `cpuinfo`, threads | atomicArc worker lane | needs COOP/COEP + special flags | no threads (preview 1) |
| `monotimes`, `times` | scheduler timers | ok (bridged clock) | ok |

The conclusion: a wasm build is a **reduced-capability profile** at runtime — the
parser, compiler, GIR, VM core, and pure stdlib (`str`, `json`, `html`, `url`,
`std/stream`, `std/parse`) all work; the host-authority builtins (`os`, `net`,
`db/*`, `ffi`, and the curses/curl work in `examples/ai_agent/design.md`) are present but
non-functional. Whether to physically *remove* them (smaller binary, cleaner
errors) or leave them stubbed is the optional gating decision in §A.2 — either
way the language core runs.

### A.2 Feature-gating is optional, not a prerequisite

**Empirical finding (implemented and validated): the full VM — including the
`dynlib`, `net`, and `osproc` imports — compiles to wasm through Emscripten and
runs, evaluating Gene source, with no host-subsystem gating at all.** Emscripten
provides libc-level stubs for `dlopen`/socket/`fork`, so the generated C links
into a wasm module cleanly; the host-authority builtins simply fail at runtime
if a program actually calls them (there is no socket/subprocess underneath). The
`nimble wasm` task builds exactly this, unmodified VM plus the §A.4 ABI, and
`tests/test_wasm.mjs` evaluates arithmetic, the pure stdlib, and JSON in it under
node.

So a `-d:geneWasm` define exists (it selects the ABI's output-capture path,
§A.4), but gating out `dynlib`/`net`/`osproc` is an **optional size/clarity
optimization** — smaller binary, no dead host code, cleaner "not available"
errors — *not* a requirement to get a working build. If pursued, the mechanism is
the one already in the tree (the worker lane compiles only `when
compileOption("threads") and defined(gcAtomicArc)`): gate the hostile imports and
their namespace registrations behind `when not defined(geneWasm)`. The scheduler
worker-lane / async-I/O code is already thread-gated, so a non-threaded wasm
build (`--mm:orc --threads:off`) runs the single-threaded cooperative root lane
automatically.

### A.3 The real gotcha is init ordering, not the `Value` layout

The NaN-box layout holds up under wasm32 exactly as predicted: `Value` is a
NaN-boxed `uint64` with a 48-bit `PAYLOAD_MASK` (`src/gene/types.nim`); wasm32
pointers are 32-bit and fit the payload; `sizeof(Value) == 8` and
zero-initialized `Value == nil` both hold (`CLAUDE.md`). Integers, floats, and
heap values round-trip through the wasm build correctly with no layout change.
(wasm64 / memory64 stays a non-goal.)

The bug that *actually* bit during implementation was subtler and is worth
recording because any wasm embedding will hit it: **Nim's global `let`
initializers run in `NimMain`, and Emscripten does not run `NimMain` unless
`main` executes.** The `TRUE`/`FALSE`/`VOID` singletons are `let` globals; if the
host calls an exported `gene_eval` before `main` has run, those singletons are
still zero — and a zero `Value` reads as `nil`. The symptom is precise and
misleading: integers and floats (constructed at runtime) work, but `true`,
`false`, and `void` all render as `nil` and `(if true …)` takes the else branch,
while `nil` itself (bits 0) looks fine. The fix is to **export `_main` and let
Emscripten's default `INVOKE_RUN` call it at instantiation** (the `wasm` nimble
task does this). Any Target-A or Target-B embedding must guarantee `NimMain` runs
before the first export call; there is no separate `gene_init` escape hatch.

Manual reference counting and the planned non-moving arena work unchanged — wasm
linear memory is a flat byte array, exactly what the current allocator assumes;
there is no moving GC to fight.

### A.4 Host ABI v0 (normative for the MVP)

The MVP boundary is **text-only and synchronous**: source string in;
stdout/stderr and a result string out. **No raw `Value` ever crosses the wasm
boundary** — results are referenced through opaque `i32` handles with explicit
lifetime, and all strings are UTF-8 (pointer, length) pairs in guest linear
memory. Exports (C symbols, compiled in only under the wasm profile):

```c
// memory management for host-owned inputs
i32  gene_alloc(i32 len);              // guest buffer the host writes into
void gene_free(i32 ptr);

// evaluation: one source unit in, one opaque result handle out
i32  gene_eval(i32 src_ptr, i32 src_len);      // -> result handle, 0 on invalid ABI input

// result accessors (valid until gene_result_free)
i32  gene_result_status(i32 handle);           // 0 ok | 1 runtime error | 2 panic | 3 parse/compile error
i32  gene_result_text_ptr(i32 handle);         // rendered value or error text
i32  gene_result_text_len(i32 handle);
i32  gene_result_out_ptr(i32 handle);          // captured print/println output
i32  gene_result_out_len(i32 handle);
void gene_result_free(i32 handle);
```

Handles index a guest-side registry that **roots** the underlying result string
until `gene_result_free`, so the host copies text out on its own schedule; the
registry is the lifetime rule, not host discipline. `print`/`println` are
captured into the per-eval output buffer (surfaced via `gene_result_out_*`)
rather than routed to a host import — one less import to wire, and the
playground wants the transcript anyway. A later ABI v1 can add streaming stdout
and persistent-session handles (`gene_session_new`/`gene_session_eval`) without
breaking v0. Async is **out of v0 entirely** (§A.5).

Because the ABI is text buffers plus `i32` handles, it is *identical* across the
two host profiles below — only the ambient namespaces differ, not the eval
contract.

#### A.4.1 Two profiles: browser vs. WASI

"Target A" is really two capability profiles with different host contracts.
Conflating them is a planning trap; they get separate defines and separate
acceptance tests. Both share the same reduced *language* core (parser, compiler,
GIR, VM, pure stdlib) and the §A.4 ABI; they differ only in which host-backed
namespaces register.

| | `geneWasmBrowser` (Emscripten) | `geneWasmWasi` (wasi-sdk / WASI runtime) |
|---|---|---|
| Host | JS in a browser or node | a WASI runtime (wasmtime, node WASI) |
| stdio | captured into `gene_result_out_*` | same, plus fd 1/2 if desired |
| filesystem | **none by default** — only if the JS loader mounts one (MEMFS) | real files via WASI preopened dirs |
| env vars | **none by default** — loader may inject | WASI `environ_get` |
| clock / random | JS imports | WASI `clock_time_get` / `random_get` |
| async | Promise via §A.5 completion ABI | **none** (preview 1 has no event loop) |

Correcting the blanket "keep `Fs/*` / `os/get_env`" in the source map below:
**the browser MVP excludes filesystem and env** unless the JS loader explicitly
provides them, so `Fs/*` and `os/get_env` register only in `geneWasmWasi`. The
browser profile is pure language + the §A.4 eval ABI, nothing that touches a
disk or an environment it does not have.

### A.5 Async bridge (post-MVP; mechanics required before building)

The browser is a single-threaded event loop; the Gene scheduler's cooperative
root lane is a single-threaded run/wait queue — they fit. But
`geneTaskComplete`/`geneTaskFail` (`src/gene/native_api.nim`) are *native
embedding* APIs today, not a wasm host ABI; JavaScript cannot hold a `Value` or
a `GeneRoot`. The bridge therefore needs its own exported surface, specified
here so nobody assumes the native one maps over:

- **Handle-based settlement exports.** When Gene code awaits a host operation,
  the guest creates an external-pending task, roots it in the same registry as
  §A.4, and passes the *handle* (an `i32`, never a `Value`/`GeneRoot`) out
  through a host import (`env.gene_host_call(op_ptr, op_len, task_handle)`). The
  JS side performs the operation (e.g. `fetch`) and, from the Promise callback,
  calls back in through exports: `gene_task_complete(task_handle, text_ptr,
  text_len)` / `gene_task_fail(task_handle, msg_ptr, msg_len)`. Inside the guest
  these look up the rooted task, copy the bytes into a Gene value, and settle it
  (the same effect `geneTaskComplete`/`geneTaskFail` have natively, but reached
  through the integer handle, not a `GeneRoot`).
- **Settlement does not run Gene code; a separate pump does.** The completion
  export only marks the task ready and returns immediately, because a Promise
  callback must not re-enter a long computation. JS then calls an exported
  `gene_pump()` that drains the scheduler's ready queue until it empties or every
  fiber is parked again, running the fibers the settlement unblocked. Output
  produced during the pump is read through the same `gene_result_out_*` buffers
  as §A.4. Keeping settle and pump separate matches the browser's turn model: a
  microtask settles, the next tick pumps.
- **No stack switching required for v0-style eval.** Because `gene_eval` runs to
  completion synchronously and async work happens across *separate* JS turns
  (call → park → return to JS → settle → pump), the guest never has to suspend a
  C call stack mid-import. This sidesteps Emscripten Asyncify/JSPI for the common
  case; those are only needed if a *synchronous-looking* Gene call must block on
  a Promise, which this design deliberately avoids by parking the fiber and
  returning control to JS instead.
- **WASI has no event loop**, so this whole section is browser-only; the WASI
  profile stays synchronous (§A.4 exports only). A host that wants async under
  WASI must supply it out of band (preview 2 / the component model — an open
  question).

### A.6 Deliverable

A `gene.wasm` + small JS/WASI loader that evaluates Gene source and returns
output. First proof: run `examples/web_demo.gene`'s pure-data/render portions
(it already avoids sockets until `serve`) and the `spec_runner` pure-language
subset in the browser. This is the "Gene playground" most people mean by "wasm
support," and it dogfoods the GIR image concept from
`docs/proposals/distribution.md` (ship the compiled GIR alongside the wasm VM
instead of re-parsing source each load).

---

## Target B — Run wasm modules from Gene (sandboxed plugins)

The inverse: let a Gene program load a `.wasm` module and call its exports, as a
**safe, sandboxed alternative to native FFI**. Where `ffi/open` loads arbitrary
native code with full process authority, a wasm module runs in a memory-sandboxed
guest that can touch only the imports Gene chooses to grant — a much better
capability story.

### B.1 It is a native namespace, like `db/sqlite`

This needs no new runtime architecture. Embed a wasm engine (wasmtime's C API,
or the smaller wasm3 / WAMR) via the **exact dynlib-backed native-namespace
pattern** already used by `db/sqlite`/`db/postgres` in `src/gene/stdlib.nim`:
own the `LibHandle`, cache resolved symbols in a Nim `object`, wrap the engine /
module / instance handles as **owned C pointers** wired to the engine's free
functions, and raise a typed `WasmError`. `GENE_WASMTIME` overrides the library
path, exactly like `GENE_LIBPQ`.

### B.2 Surface and capability

```gene
(import wasm [open instantiate call Run WasmError])
(var mod (open run "add.wasm"))        ; run : Wasm/Run capability
(var inst (instantiate mod))
(call inst "add" 2 3)                   ; -> 5
```

- new capability `Wasm/Run` (ambient value like `Net/Connect`), gating module
  execution — a launcher can withhold it;
- value marshaling limited to the wasm core numeric types first: `i32`/`i64` ↔
  `Int`, `f32`/`f64` ↔ `Float`. Strings/buffers cross through guest linear
  memory with explicit copy helpers (like the db byte-buffer marshaling),
  deferred to a second pass;
- host functions the guest may import are Gene `fn`s the embedder registers —
  and each is itself capability-gated, so a wasm plugin gets *strictly less*
  authority than the Gene program that hosts it.

### B.3 Why B is attractive

It gives Gene a plugin system whose blast radius is a sandbox, not the process —
the security inverse of native FFI. Combined with Target A, the same wasm module
could run both in a native Gene host and in a Gene-compiled-to-wasm host,
though nested wasm-in-wasm is an explicit non-goal for now (§ non-goals).

---

## Target C — Compile Gene to wasm (defer)

Emit standalone `.wasm` from typed Gene functions: a codegen backend parallel to
`docs/proposals/jit-pipeline.md`, which already targets arm64 + x86_64 native
code for numeric/recursive workloads. wasm is a natural *fourth* target for the
same typed-function pipeline — same eligibility analysis (monomorphic, unboxed
numeric), same GIR input, different emitter.

Reasons to defer:

- it is the largest of the three (a full backend), and
- it overlaps unbuilt work (the JIT pipeline is itself a design doc, not yet
  implemented), and
- Targets A and B deliver the two things users actually ask for first — "run
  Gene in the browser" (A) and "run wasm plugins from Gene" (B) — without a
  compiler backend.

When it happens, it should reuse the JIT pipeline's typed-function selection and
GIR lowering, swapping the machine-code emitter for a wasm-bytecode emitter, and
target `wasm32` with the same unboxed-numeric value representation the JIT uses
internally (not the NaN-boxed `Value` — codegen'd hot paths already unbox).

---

## Source map — Target A

Implemented:

- `src/gene_wasm.nim` (new) — the §A.4 host ABI entry module: `gene_alloc`/
  `gene_free`/`gene_eval`/`gene_result_*` `{.exportc.}` procs over a rooted result
  registry, plus exported `_main` so `NimMain` runs (§A.3).
- `src/gene/vm.nim` — the only VM change was a `when defined(geneWasm)` hook in
  `biPrint`/`biPrintln` that appends to a per-eval capture buffer instead of
  `stdout`, surfaced through `gene_result_out_*`. No host code was gated (§A.2).
- `gene.nimble` — the `wasm` task (validated recipe below).
- `tests/test_wasm.mjs` — the node validation harness.
- `web/index.html` — the browser playground over the same text-only ABI.

Optional, for the size/clarity optimization only (not required, §A.2):

- gate `dynlib`/`net`/`osproc` imports and their namespace registrations behind
  `when not defined(geneWasm)`; register `os/get_env` and `Fs/*` only under a
  WASI profile, not the browser profile (§A.4.1).
- new `src/gene/wasm.nim` (Target B only) — the wasmtime dynlib backend,
  `include`d by vm.nim beside the db/os/json code, same as `stdlib.nim`.

## Build

`nimble wasm` runs the exact validated recipe (Nim's C output compiled directly
by `emcc`, one invocation — Nim drives the C compile and link). It was run in
this repo with Emscripten 5.0.5 and Nim 2.2.4, producing `web/gene.wasm`
(~2.6 MB) + `web/gene.js`; `node tests/test_wasm.mjs` then passes all ABI cases:

```bash
nim c --os:linux --cpu:wasm32 -d:emscripten -d:geneWasm --mm:orc -d:release \
  --threads:off --cc:clang --clang.exe:emcc --clang.linkerexe:emcc --path:src \
  --passL:"-s EXPORTED_FUNCTIONS=['_main','_gene_alloc','_gene_free',\
'_gene_eval','_gene_result_status','_gene_result_text_ptr','_gene_result_text_len',\
'_gene_result_out_ptr','_gene_result_out_len','_gene_result_free','_malloc','_free']" \
  --passL:"-s EXPORTED_RUNTIME_METHODS=['HEAPU8']" \
  --passL:"-s ALLOW_MEMORY_GROWTH=1" \
  --passL:"-s MODULARIZE=1 -s EXPORT_NAME=GeneModule" \
  -o:web/gene.js src/gene_wasm.nim
```

Load-bearing details this recipe encodes:

- `--mm:orc --threads:off` — single-threaded profile (§A.4.1); orc gives
  deterministic non-threaded reclamation, no atomics/pthread setup.
- **`_main` in `EXPORTED_FUNCTIONS`** — so Emscripten runs `main`/`NimMain` at
  instantiation and the `TRUE`/`FALSE`/`VOID` globals initialize *before* the
  exports are callable (§A.3). Dropping it silently breaks booleans.
- `_malloc`/`_free` exported so the host can also allocate; `HEAPU8` runtime
  method so JS can read result byte ranges; `ALLOW_MEMORY_GROWTH` because eval
  workloads vary; `MODULARIZE` for a clean `await GeneModule()` factory.

The WASI profile substitutes the wasi-sdk clang for `emcc` and drops the
JS-specific flags. Async (§A.5) additionally needs `-s ASYNCIFY`/JSPI **only** if
a future synchronous-blocking import is added — the v0 park-and-return design
does not, and none of the above uses it.

## Staged plan

1. **Host ABI v0 + build (Target A core).** ✅ **Done.** `src/gene_wasm.nim`, the
   `nimble wasm` task, and `tests/test_wasm.mjs`; the full VM builds to wasm with no
   gating and evaluates Gene source (arithmetic, pure stdlib, JSON, error paths)
   under node. Optional follow-up: the `-d:geneWasm` size-gating of host code
   (§A.2) and the browser-vs-WASI namespace split (§A.4.1).
2. **Playground loader.** ✅ **Minimal version done.** `web/index.html` feeds
   source in and renders `gene_result_out_*` into a transcript. Follow-ups: run
   `examples/web_demo.gene`'s render path, add REPL/session handles, and ship the
   GIR image so load does not re-parse.
3. **fetch bridge (Target A optional).** `net/fetch` over a host Promise import,
   settled through external-pending tasks — the browser analogue of
   `Fs/*-async`. Lets a wasm-hosted agent (`examples/ai_agent/design.md`) talk to an API
   without sockets.
4. **wasm-in-Gene (Target B).** `wasm` namespace over an embedded engine via the
   dynlib pattern; `Wasm/Run` capability; numeric marshaling; spec tests with a
   tiny checked-in `.wasm` fixture. Then linear-memory string/buffer marshaling.
5. **Gene-to-wasm (Target C).** Only after the JIT pipeline exists; reuse its
   typed-function selection with a wasm emitter.

Each stage follows the repo rule set (`nimble test`/`spec`/`perf` before commit;
Target B natives in `src/gene/stdlib.nim`/`wasm.nim`; every new host power a
capability value) and preserves the NaN-box invariants in `CLAUDE.md`.

## Non-goals (first version)

- **Full runtime in the browser.** The wasm profile is intentionally reduced —
  no raw sockets, subprocess, native FFI, or dynamic library loading. Programs
  needing those run natively.
- **Threads in wasm.** The wasm profile is single-threaded cooperative;
  shared-memory wasm threads (COOP/COEP, atomics) are out of scope until the M:N
  worker lane itself stabilizes natively.
- **wasm64 / memory64.** Target wasm32; the value layout assumes ≤48-bit
  pointers.
- **Nested sandboxing** (running Target B's wasm-in-Gene inside a Target A
  Gene-in-wasm host).
- **A DOM / canvas binding.** The host bridge is stdio + optional fetch; UI
  frameworks are a separate effort.

## Open questions

- WASI preview 1 vs. the component model / preview 2 for the server profile —
  preview 1 is the pragmatic near-term target; the component model is where the
  ecosystem is heading and may change the host-import story.
- Which engine for Target B — wasmtime (full-featured, larger) vs. wasm3 / WAMR
  (tiny, interpreter-only) — trades binary size against speed and features.
- Whether the browser profile should ship the interpreter (Target A, re-run
  GIR each call) or eventually Target C (compile the user's Gene to wasm once) —
  they are complementary, not either/or.
