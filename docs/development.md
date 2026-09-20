# Development and project status

User documentation starts with [the language guide](language.md). This page
covers contributor workflow, implementation boundaries, and future work.

## Status

The VM implements the language described in [the specification](spec/README.md):
nominal types and protocols, declaration-bound Self, scoped impl visibility,
optional binding, pipelines, template macros, fexprs, evaluation, structured
tasks, and checked external-operation authority.

Packages support format-1 workspaces, solving, locks, immutable source stores,
multiple versions, and git/path/local-registry sources. Pure-Gene builds support
target planning and artifact reuse. The web backend supports an explicitly
checked subset, including embedded web modules.

Known limits worth carrying into design decisions:

Application-scale examples include [Cordis](../examples/cordis/README.md),
[Miclone](../examples/miclone/README.md), and the
[Todo app](../examples/todo_app/src/main.gene).

## Codebase

The core is shared across execution paths. A new backend or fast path must
preserve the contract it accepts, including cleanup and authority restoration.

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
See [AGENTS.md](../AGENTS.md) for workspace-specific contributor instructions.

## Documentation

Keep one main explanation of a feature in the user guides. Use runnable,
self-contained examples where possible; `gene runnable` fences are checked by
the documentation contract. README should show a real program before listing
features. Design should illustrate choices rather than enumerate internal plans.

Exact edge cases belong in `docs/spec/`. The compiler-head inventory in the
call spec is checked against dispatch. Update links and examples when names
move. Do not recreate a second directory of overlapping feature designs.

## Roadmap

Current open areas include hosted registry publication/signing, native/resource
build recipes and application distribution, JIT, production M:N scheduling,
full compile-time function macros/hygiene, static effects and exhaustiveness,
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

Historical proposals and measurements do not override today's implemented
specification or establish current sandbox/performance guarantees.

