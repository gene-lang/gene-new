# Bundled Gene-source libraries

**Status:** design proposal; gates the code moves in `tmp/cleanup-plan.md`

**Scope:** how a library written in Gene ships with the runtime, how
`genex/*` resolves to it, where the sources live at build and run time, and what
capabilities a bundled library gets. `genex/spec` is the first consumer.

**Related:** `package.md` owns *user* package resolution and stores — this
proposal adds no package kind and changes no manifest. `capabilities.md` §14
owns grants; §5 below states that bundled ≠ privileged.

**Revision date:** 2026-08-13

---

## 0. Why this exists

`tmp/cleanup-plan.md` proposes moving functionality out of the core "as a gene
or genex library". Today that is not possible:

- `genex` is registered as a real root (`vm.nim:7023`) and reserved against
  rebinding (`compiler.nim:224`), but **nothing is registered under it** —
  `grep genex src/gene/stdlib.nim` returns zero hits.
- **No `.gene` source library ships with the runtime.** Every `.gene` file in
  the tree is an example, a test fixture, a benchmark input, or training corpus.
- `package.nim` has `userStoreDir()`, `applicationStoreDir()` and
  `GENE_USER_PACKAGES`, but no builtin/bundled package origin.

So "move it to a genex library" currently degrades to "move the Nim file to a
different folder". This proposal supplies the missing mechanism. Until it lands,
every other cleanup step is refoldering.

---

## 1. The finding that determines the design

**There are two import paths in the compiler, and only one of them can carry
macros from Gene source.**

`(import genex/spec [describe it])` parses to `nsSegments = ["genex", "spec"]`
with `fromModule = false` (`compiler.nim:4393`). At runtime it resolves through
`vm.nim:12715-12727`: look up the root, then walk `exportedBinding` per segment.
At **compile** time it resolves through `builtinNamespaceMacros`
(`compiler.nim:5750`) — which is a hardcoded `if/elif` chain:

```nim
proc builtinNamespaceMacros(segments: openArray[string]):
    Table[string, MacroDef] =
  result = initTable[string, MacroDef]()
  if (segments.len == 1 and segments[0] == "log") or ...
    for level in ["error", "warn", "info", "debug", "trace"]:
      result["log_" & level] = builtinLogMacro(level)
  elif (segments.len == 1 and segments[0] == "css") or ...
    result["decl"] = builtinCssDeclMacro()
```

Exactly two namespaces, both with **Nim-constructed** `MacroDef`s. Registering
a Gene-source library on this path means writing its macros in Nim — which is
the thing this whole effort is trying to stop doing.

The module path already does the right thing. `(import [x] from "path")` sets
`fromModule = true`, and the module loader compiles the dependency first and
harvests its macro exports (`vm.nim:23835-23840`):

```nim
if needsMacroArtifact:
  if dependency == nil:
    dependency = compileModuleArtifact(app, depPath)
    ...
  importedMacros[raw] = dependency.macroExports
```

which `compileFormsWithMacros` then feeds to the importing module
(`vm.nim:23860`, consumed at `compiler.nim:2347`). Interfaces, wildcard imports,
syntax-fn exports and re-export all ride the same path.

**Therefore: a bundled library must resolve as a module, not as a builtin
namespace.** This is not a preference — it is the only path on which a Gene
library can export a macro, and `genex/spec` wants `describe`/`it`/`expect` to
be macros (§6).

---

## 2. Design

### 2.1 Surface stays what users expect

Users write a namespace-path import. No new syntax:

```gene
(import genex/spec [describe it expect])
```

### 2.2 Resolution rewrites it to a module reference

One pre-pass in `parseImportSpec` (`compiler.nim:4325`), after `nsSegments` is
computed: if `nsSegments[0]` is a bundled-library root **and** the remaining
segments name a bundled module, rewrite the spec in place —

```
fromModule  = true
modulePath  = "genex:spec"        # scheme-prefixed synthetic identity
selections  = (unchanged)
```

Everything downstream — `importKey`, dependency compilation, macro harvesting,
compile interfaces, the module cache — then works with no further change. Three
touch points total:

| Touch point | Change |
|---|---|
| `compiler.nim` `parseImportSpec` | the rewrite above |
| `vm.nim` `resolveModuleRef` (7564) | recognize the `genex:` scheme, return the identity unchanged, skip the package-root containment check |
| `vm.nim` module source read | when the identity carries the scheme, read from the bundle instead of the filesystem |

The package-boundary check at the end of `resolveModuleRef` must be skipped for
bundled identities — a bundled module is in no package and would otherwise trip
`pecBoundary`.

### 2.3 A bundled module is not shadowable

`genex` is in `reservedStdlibRoots`, so `validateBindingName` already refuses to
let a program bind it (`compiler.nim:284`). That property is what makes the
rewrite safe: `genex/spec` cannot be captured by a local named `genex`, unlike
the ordinary namespace path which deliberately prefers an initialized local
(`vm.nim:12715`).

Roots eligible for bundled libraries: `gene`, `genex`, `geney`, `genez` — the
existing reserved set. Nothing else is rewritten.

---

## 3. Where `lib/` lives

Three options, and the choice is forced by a constraint the repo has already
paid for once.

| | Embedded (`staticRead`) | Filesystem next to binary | Both |
|---|---|---|---|
| single-file distribution | ✅ | ❌ | ✅ |
| works under wasm | ✅ | ❌ **no filesystem** | ✅ |
| hermetic tests | ✅ | ❌ | ✅ |
| edit without rebuild | ❌ | ✅ | ✅ |
| payload cost | every build | none | every build |

**Recommendation: embed, with a development override.**

- Sources are embedded at compile time via `staticRead` into a
  `Table[string, string]` keyed by bundled identity.
- `GENE_BUNDLED_LIB_DIR` overrides the embedded copy with a filesystem
  directory, for iterating on a library without rebuilding the compiler.
  Development-only; not part of the distribution contract.

The deciding constraint is **wasm**. The web profile has no filesystem, so a
filesystem-only design creates an immediate two-profile divergence in what
`genex/*` means. This repo has been bitten by exactly that class of split
before, and the rule in `AGENTS.md` — host-only subsystems must be
`when not defined(geneWasm)`-gated — exists because of it.

Hermeticity is the second reason: `GENE_USER_PACKAGES` exists precisely because
filesystem lookup made tests depend on machine state. Do not reintroduce that
for the library path.

### 3.1 Payload is a gate, not a footnote

Embedding puts every bundled library's source into **every** build, wasm
included. Two rules:

1. **Host-dependent bundled libraries are excluded from the wasm bundle** with
   `when not defined(geneWasm)`, exactly as host subsystems are today. A library
   that cannot run in the browser must not cost browser payload.
2. **`nimble wasm` output size is recorded before and after** the first bundled
   library lands, and in any change that adds one. `genex/spec` is pure Gene
   text measured in single-digit KB, which is affordable; the discipline matters
   more than this first number, because payload is the wasm target's headline
   cost and `nimble test` cannot see it.

---

## 4. Loading is lazy, and the cache already handles it

Compilation of a bundled module happens when a module importing it is compiled —
not at startup. That falls out of routing through the module path: nothing
touches `genex/spec` unless someone imports it.

`app.moduleCache` (`vm.nim:23973`) already dedupes per run, so N importers cost
one compile. Two things to verify rather than assume:

- **`nimble perf` before/after** on a program that imports nothing bundled — it
  must be unchanged, because nothing should have become eager.
- **First-import cost** of `genex/spec` measured once and recorded. If it is
  material, precompiled GIR for bundled libraries is the escape hatch
  (`gir_codec.nim` already exists), but do not build that until a measurement
  asks for it.

---

## 5. Bundled is not privileged

**A bundled library receives no capability it was not granted.** "Ships with the
runtime" describes distribution, not trust.

This is worth stating explicitly because the opposite is a natural assumption
and would be a real hole: `vm.nim:7263-7283` withholds `gene` and `genex` from
restricted scopes and does *not* rebind them, so a sandboxed module cannot name
its way back to the standard library. If bundled libraries were auto-privileged,
a restricted module that could reach any bundled library would have a path to
host authority through it.

Consequences:

- `genex/spec` (§6) needs **no** capabilities. Keep it that way: it is pure
  computation over values, so it runs under wasm and inside restricted scopes.
- A future bundled library needing host access declares it and is granted it
  like any other module. Moving `logging` or `http_server` to `genex` later
  (the cleanup plan's §3.6 ambition) does **not** get to skip the grant surface.
- The `naming convention` suite in `tests/spec_runner.nim` walks the global
  scope and fails on hyphenated registrations. A bundled library's exports land
  in that walk — so `snake_case` is enforced for free, and that is intended.

---

## 6. First consumer: `genex/spec`

An rspec-like testing library for **user** code. Explicitly *not* a replacement
for `tests/spec_runner.nim`, which is the Nim executable contract for the
language surface per `AGENTS.md` and stays as it is.

```gene
(import genex/spec [describe context it expect before_each])

(describe "List/map"
  (it "applies f to each element"
    (expect ([1 2 3] .map (fn [x] (* x 2))) .to_eq [2 4 6]))

  (context "on an empty list"
    (it "returns empty"
      (expect ([] .map identity) .to_eq []))))
```

### 6.1 Why it is the right first consumer

- New code, so no back-compat surface to preserve while the loader settles.
- Pure Gene with no host access — it exercises the loader without also
  exercising capability plumbing (§5).
- **It needs macros**, so it exercises the one thing §1 identified as the
  hard constraint. A first consumer that only exported functions would leave
  the load-bearing part of the design untested.

### 6.2 Design points to settle during implementation

- **`expect` must see the unevaluated expression** to report
  `expected [2 4 6], got [2 4 4] — from ([1 2 3] .map ...)`. That is what makes
  it a macro rather than a function, and it is the reason §1 matters. Decide
  between a `macro` template and a named fexpr (design §11.1/§11.2); prefer
  `macro`, since the expansion is static and fexprs carry a caller-env cost.
- **`describe`/`it` build a value tree**, not a registry mutated at load time.
  A tree is inspectable, testable, and matches the language's data-first
  posture; a global registry makes ordering and isolation implicit.
- **Failure output needs source locations.** The reader already attaches them
  (`sourceLocs`, `hasStableSourceIdentity` in `compiler.nim:203`); confirm they
  survive macro expansion before designing the report format around them.
- **No host capabilities in v1** — including no file I/O for test discovery. A
  runner that walks the filesystem is a *tool* (`gene-spec`), separable and
  later.

---

## 7. What this unlocks

Once bundled libraries exist, the cleanup plan's remaining ambitions become
actually achievable rather than aspirational:

| Candidate | Today | After |
|---|---|---|
| `format` builtin (dropped in cleanup step 4) | deleted, no home | can return as `genex/fmt` |
| `repl_curses` (deleted, step 6) | rewritten as a loose `.gene` file | `genex/repl_curses`, shipped |
| terminal / curses natives | Nim in `ext/term/` | Gene wrapper over a narrowed native surface |
| `logging` | Nim in `ext/` | `genex/log` over the `vkLogger` value seam, which is already clean |

None of these are commitments. They are the reason to build the loader before
the moves, not after: each one changes where a module's *final* home is, and
the moves should land code once.

---

## 8. Phases

| # | Phase | Gate |
|---|---|---|
| 1 | Bundle table + `staticRead` embedding + `GENE_BUNDLED_LIB_DIR` override | unit test: identity → source |
| 2 | `parseImportSpec` rewrite + `resolveModuleRef` scheme + bundled source read | `(import genex/x [f])` resolves for a trivial fixture library |
| 3 | Macro export across the bundled boundary | fixture library exporting a macro; assert it expands in the importer |
| 4 | `lib/genex/spec.gene` v1 | its own suite, written in itself |
| 5 | wasm payload + perf measurement recorded | `nimble wasm` size delta; `nimble perf` unchanged for non-importers |

Phases 1–3 are the mechanism and are independently testable with a throwaway
fixture library — do not wait on `genex/spec`'s design to validate the loader.

---

## 9. Required acceptance tests

1. `(import genex/spec [it])` resolves with no filesystem access and no package
   context — including from a module in a package, and from `gene eval`.
2. A bundled library's **macro** expands correctly in an importing module,
   proving the §1 path.
3. A bundled library is **not** reachable from a restricted scope that was
   denied `genex`, and gains no capability by being bundled (§5).
4. A program that imports nothing bundled compiles and runs with **no** measured
   change — the loader is lazy.
5. `GENE_BUNDLED_LIB_DIR` overrides the embedded source, and its absence falls
   back to embedded — with tests hermetic in both directions.
6. The wasm build excludes host-gated bundled libraries, and `web/gene.wasm`
   grows only by the payload of libraries that genuinely run there.
7. A user module may not bind `genex`, and may not shadow a bundled library with
   a local of the same name.

---

## 10. Settled and deferred

**Settled 2026-08-13:**

- **`genex` only in v1.** The `gene` root is not open to bundled libraries.
  Adding to it would change the standard library's public surface and interact
  with `staysBare` (`compiler.nim:252`); `genex` is already documented as the
  experimental root, which is exactly what a first bundled library is. Phase 2's
  rewrite therefore recognizes `genex` alone, even though `reservedStdlibRoots`
  contains four names — widening later is additive and cheap, narrowing is not.

**Deferred:**

- **Versioning.** A bundled library's version is the runtime's version; there is
  no independent resolution, so a bundled library cannot be upgraded without
  upgrading the runtime. Accepted for now and to be revisited — leanness of the
  core is the immediate goal, and this constraint does not block it. It does not
  become harder to change later: nothing in §2's resolution design assumes a
  single version, and adding one would be a change to identity, not to the
  import path.
- **Precompiled GIR for bundled libraries** — until §4's measurement asks for it.
