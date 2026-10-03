# Development and project status

User documentation starts with [the language guide](language.md). This page
covers contributor workflow, implementation boundaries, and future work.

## Status

The VM implements the language described in [the specification](spec/README.md):
nominal types and protocols, declaration-bound Self, scoped impl visibility,
optional binding, pipelines, template macros, fexprs, evaluation, and structured
tasks.

Packages support format-1 workspaces, solving, locks, immutable source stores,
multiple versions, and git/path/local-registry sources. Pure-Gene builds support
target planning and artifact reuse. Selected resource recipes and local POSIX
installation are available; native artifact recipes and hosted publication are
still open. The web backend supports an explicitly
checked subset, including embedded web modules.

Known limits worth carrying into design decisions:

- Native C compilation and worker-thread execution remain experimental.
  AOT protocol overlay guards are module-local; cross-module overlays are a
  known limitation. Loaded AOT libraries remain pinned for process lifetime.
- A closure over bindings that are never reassigned copies them and holds no
  activation scope, so it forms no scope cycle. One that reads a reassigned
  binding captures by reference; if its scope's bindings hold it, the cycle is
  reclaimed when that activation ends or once a returned value that reaches it
  is released, and a cycle whose last outside owner is anything else (a global
  registry, a host holding a kept closure) is not revisited. See the
  [lifetime ledger](../tests/lifetime/LEDGER.md). Other mixed scope/closure
  cycles may remain. AtomicArc has no ORC cycle collection. Do not infer
  complete lifetime safety from passing one suite.
- An existing hang can occur with eval-defined nominal types and methods;
  lifetime coverage currently uses functions and generators.
- Arbitrary native code is trusted after admission; nothing confines its direct
  host effects in-process.
- Web backend exclusions are explicit. It does not provide the full native
  runtime.

Application-scale examples include [Cordis](../examples/cordis/README.md),
[Miclone](../examples/miclone/README.md), and the
[Todo app](../examples/todo_app/src/main.gene).

### Paused native-app and AtomicArc work (2026-09-28)

The current checkpoint is `a7702fa` (root-owned bounded foreign C handle
registry). The single numeric Gene C ABI is version 6. It supports managed
native callbacks and Task producers, copied Nil/Bool/Int/Float/Text/Bytes Task
results, and root-reserved slots for owning C IDs created on attached threads.
The registry lets those numeric IDs survive worker exit under the default
AtomicArc allocator; capacity and pending releases are observable. The
[native-app qualification ledger](profiles/native-app.md) and
[foreign-handle decision](proposals/native-foreign-handle-allocation.md) give
the contracts and limits.

At this checkpoint, `nimble test`, `nimble spec`, `nimble leakcheck`, and
`nimble threadcheck` pass. The managed qualification runner reports 1 disabled,
41 opt-in probe, 41 ASAN, and 12 targeted TSAN cases passing. Focused default-
allocator ASAN tests transfer 10,000 C IDs; four-worker ASAN/TSAN tests transfer
2,048. These results qualify the tested C numeric-ID path, not arbitrary Nim
reference transfer or production AtomicArc cycle collection.

The next ownership boundary, if this work resumes, is a `GeneManagedRoot` Nim
wrapper allocated on an attached thread and held after that thread exits. It
can still outlive its creating allocator. The proposed narrow contract is to
create new Nim wrappers only on the root lane while retaining attached-lane
borrowing and C numeric IDs for ownership transfer. This changes the public
Nim SDK contract and needs owner design review before implementation; see the
[AAR-1 plan](proposals/atomic-arc-retirement.md) and
[managed-borrow design](proposals/native-managed-borrows.md). Then rerun the
AAR-1 ownership/sanitizer matrix before considering opt-in AAR-2 shared graph
reclamation. Production collection remains disabled. Native Linux
qualification and the two-hour SERVICE heartbeat failure remain deferred.

## Codebase

| Location | Responsibility |
| --- | --- |
| `src/gene/reader.nim`, `printer.nim`, `types.nim` | Syntax and runtime values |
| `src/gene/compiler.nim`, `gir.nim`, `vm.nim` | Compilation and execution |
| `src/gene/package.nim`, `build.nim` | Source graphs and artifact builds |
| `src/gene/web.nim` | Public web compiler entry point, including macro execution |
| `src/gene/web_backend.nim` | Web-profile analysis and emission |
| `src/gene/stdlib.nim`, `src/gene/ext/` | Libraries and native adapters |
| `src/gene/native_api.nim`, `aot_runtime.nim` | Native boundaries |
| `tests/`, `examples/`, `benchmarks/` | Contracts, usage, and measurements |

The core is shared across execution paths. A new backend or fast path must
preserve the contract it accepts, including cleanup and budget restoration.

## Build and test

```sh
nimble build
nimble test
nimble spec
```

Gene application tests use [`gene test`](testing.md). The Nim suites remain
the compiler/runtime conformance and implementation tests.

Additional checks depend on the change:

| Task | Coverage |
| --- | --- |
| `nimble transpile_spec` | Shared VM/web cases, async, DOM, and embedded modules |
| `nimble transpile_typecheck` | Emitted TypeScript and declarations |
| `nimble perf`, `nimble transpile_perf` | Runtime/compiler measurements |
| `nimble leakcheck` | Reference-count/lifetime cases |
| `nimble threadcheck` | AtomicArc behavior and retention |
| `nimble wasm` | Emscripten build and wasm host-ABI checks |
| `nimble verify` | Broad verification tasks |

The full verification surface has platform/toolchain prerequisites. Report
which checks ran and distinguish a known baseline failure from a regression.

`tools/linux-x86_64/run.sh OUT_DIR [COMMAND]` runs a command (default
`nimble test`) against the tracked tree in a fresh linux/amd64 Docker
container and writes `OUT_DIR/run.log`. Its Dockerfile lists the Linux build
and runtime packages (ncurses headers, PCRE, libcurl, SQLite, OpenSSL, libuv,
zlib). On Apple silicon the container runs under Rosetta, so timing results
include emulation, and the PTY descriptor test skips there.
See [AGENTS.md](../AGENTS.md) for workspace-specific contributor instructions.

## Documentation

Keep one main explanation of a feature in the user guides. Use runnable,
self-contained examples where possible; `gene runnable` fences are checked by
the documentation contract. README should show a real program before listing
features. Design should illustrate choices rather than enumerate internal plans.

Exact edge cases belong in `docs/spec/`. The compiler-head inventory in the
call spec is checked against dispatch. Update links and examples when names
move. Do not recreate a second directory of overlapping feature designs.

## Surface changes

The supported surface is what [the language guide](language.md),
[the specification](spec/README.md), and [the library guide](stdlib.md)
document without an experimental label. Changing reader syntax, special
forms, `gene` root names, or documented semantics requires:

1. Owner approval before implementation.
2. Migration of every in-repository use (examples, tests, docs, and tools)
   in the same change.
3. For a removed or renamed form, a diagnostic naming the replacement, as
   `from` does: `import: from was removed; use ^from "path"`.
4. Updated guides and specs, plus an entry in the change log below.

Gene is greenfield and all Gene code lives in this repository, so compatibility
shims and a general migration tool are not required. The version in
`gene.nimble` identifies the implementation; neither it nor the native ABI
version is a language compatibility promise.

### Change log

| Date | Change | Migration |
| --- | --- | --- |
| 2026-10-03 | Local macros expand when execution reaches their call, using their captured definition environment. Module macros retain compile-time expansion. | Each invocation observes its own enclosing values. Returned syntax still uses caller bindings and control-flow targets. Runtime local expansion has compilation cost; it leaves existing caller slots intact. |
| 2026-10-03 | REPL macro definitions commit after successful compilation. | A runtime error retains those definitions and any runtime effects already performed. A compile error leaves the previous macro context intact. |
| 2026-10-02 | Macro bodies execute ordinary Gene code during expansion; active unquotes use that body's environment. | Use quote/quasiquote to construct code. Quasiquote node splices now include properties; splice a list from `$body` for body-only insertion. Construct residual pins/paths with `%(quote (unquote name))`. See [macro execution](macro.md#d2b-definition-side-lexical-evaluation--decided). |
| 2026-10-02 | Macro results use conditional lexical scopes and ordinary shadowing, without automatic renaming. | Declarations and owned impl imports stay inside the expansion. Pass dependent code as body arguments or bind a returned value. Avoid temporary-name collisions, including `generated_logger` in log message/payload syntax. |
| 2026-10-02 | Vector unquotes normalize to unquote nodes; macros expand in expression and direct pipeline-slot positions on both backends. | Quoted `[%x]` now contains `(unquote x)`. A macro cannot provide an `else` or `when` clause; generate the whole surrounding expression instead. |
| 2026-09-29 | A visible binding sharing an executable special-form head now causes a compile error at that head. | Rename the binding or alias its import; values remain usable outside call-head position. Intrinsic Path, Message, and quasiquote forms retain their syntax meaning. |
| 2026-09-29 | Paths are callable `Path` values; their constructor uses ordered string, message, and index segments. Receiver paths evaluate the base before dynamic segments. | Replace `Selector` annotations and `(select …)` construction with `Path` and `(Path …)`; use quoted strings for literal property names. Rename catches of `SelectorMissing` to `PathMissing`. |
| 2026-09-29 | Non-callable errors name the authored call head and missing namespace segment. | Ordinary missing reads still return void; update any checks of the old generic diagnostic text. |
| 2026-09-29 | Paths and messages glued after compound forms are read errors. | Replace `(g)/a` with `(/a (g))` and `(g).size` with `((g) .size)`, or bind the result first. Whitespace-separated forms and spreads remain valid. |
| 2026-09-29 | Added native VM `reverse`, `drop`, and `has_key?`. | Use the root functions or their List/Stream/Map messages. Map key presence stays separate from `contains?`; the web profile rejects the new helpers. |
| 2026-09-29 | Web `$str/lower` now follows the VM's ASCII-only behavior; `$str/upper` uses the same rule. | Do not rely on these functions to case-map non-ASCII characters. |
| 2026-09-29 | Binding declarations reject extra values and unknown props. | Keep one initializer after an optional annotation; use `do` for a compound initializer. Only the existing `^private` prop is accepted. |
| 2026-09-01 (`304a8e0`) | Dot descriptors replace tilde sends. | Write `(x .method arg)` instead of `(x ~method arg)`; use `?.` for guarded sends. |
| 2026-09-12 (`6f6b173`) | Imports use `^from`. | Replace `from "path"` with `^from "path"` in `import` and `import_impl`. |
| 2026-09-20 (`ef7e399`) | The Capabilities system was removed. | Remove capability declarations, grants, wrappers, and CLI options. Ordinary native calls are ungated; use the sandbox loader and execution budgets for its supported isolation contract. See [trusted scripts and sandboxes](design.md#trusted-scripts-and-sandboxes). |

## Roadmap

Current open areas include hosted registry publication/signing, native
build recipes and broader application distribution, JIT, production M:N scheduling,
static effects and exhaustiveness,
general foreign callback factories and retained/queued callback modes, and
optional runtime event instrumentation. Call-scoped synchronous native callbacks
on the owning root lane are implemented, with SQLite text-row visitation as
their first library consumer; see the [native callback contract](spec/modules.md#synchronous-native-callbacks).

The application EventBus is implemented; VM-wide event production is not.
Bundled Gene-source library delivery and general-intelligence experiments are
research directions, not supported language APIs.

## Design history

Earlier detailed designs, rollout checklists, retired experiments, and dated
benchmark ledgers remain in Git history. They were removed from the current
manual to keep one usable reading path. The expanded documentation tree is
available at commit `a1387aa`:

```sh
git ls-tree -r --name-only a1387aa docs
```

Historical proposals and measurements do not override today's implemented
specification or establish current sandbox/performance guarantees.
