# Applications, modules, reflection, and native boundaries

**Status:** normative and implemented. Executable coverage: module, macro,
entrypoint, serde, native API, and CLI suites.

[Authority, evaluation, and sandbox boundaries](authority.md) defines the
shared security contract. Namespace exposure, resource permissions, and
execution policy are separate controls.

- Each run owns an Application, one selected application package, a load-once
  module cache keyed by `<package_identity>::<module_path>`, and a root
  namespace. Compile-time macro artifacts and runtime module initialization
  have separate caches/cycle diagnostics.
- The application package is the nearest ancestor `package.gene` — searched
  from the entry file's directory for file commands and from the launch working
  directory for file-less entries — or a synthesized ad-hoc package when there
  is none. `--package-root` replaces the start directory; nothing changes the
  process working directory.
- `($os/launch_dir)` returns the application's captured absolute launch
  directory as a Str and requires `os/Process`, like `os/executable_path`.
  It differs from `this_pkg/root`, which may name an authenticated build
  snapshot. A host can use it to select its launch-directory filesystem grant
  before resolving relative data paths when it also holds other grants.
- A format-1 manifest is exactly one map datum read as data, never executed.
  `^name` is `<owner>/<name>` in lowercase `snake_case`; unknown fields are
  rejected, and dependency forms have the literal head `dep`.
- Explicit package operations resolve dependency constraints into a workspace
  lock, preserving valid locked edges until updated. Source identity includes
  origin and digest, so multiple versions can coexist through separate aliases.
  Sync materializes immutable source objects. A matching vendor object takes
  precedence over the user cache; a corrupt candidate is not silently bypassed.
- `^pkg` on the `from` form selects a package; `"."` names that package's
  `main_module`. A regular package may import only itself and its declared
  direct dependencies. No resolved module path may leave its package root after
  canonicalization. Runtime imports use the materialized graph and never run
  the solver or acquire dependencies. Explicit package acquisition follows its
  configured source and offline policy.
- Modules link to their owning Package, exposed as the lexical `this_pkg`
  binding beside `this_mod`.
- Runtime imports initialize a dependency once. Compile-time macro discovery
  does not execute dependency top-level forms or grant host runtime authority.
- `$runtime/sandbox_transaction` creates a root-lane-owned prospective module
  transaction. `prepare` may add several isolated `SandboxGeneration` roots;
  compilation, macro expansion, initialization, and escaped calls obey the
  supplied step, memory, and timeout policy. Prepared caches, compile artifacts,
  protocol impls, serde origins, and module scopes are invisible to the live
  application until the transaction commits.
- Preparation pauses worker module readers and restricts scheduler pumping to
  candidate-owned tasks. FFI, native/capability type, and embedded web-module
  declarations are rejected.
- Transaction commit publishes every prepared generation in one non-yielding
  turn and rejects a changed module/impl base. Discard releases all prospective
  roots. A committed generation is removed explicitly with `release`; both
  discard and release are idempotent in their valid lifecycle state.
- `SandboxGeneration/graph` is a deeply frozen, deterministically ordered
  snapshot with normalized module identities and paths, authenticated source
  and compile-interface digests, runtime/compile dependency phases, and
  `^owned false` reference nodes for admitted shared modules.
- `$runtime/load_sandboxed` remains the non-transactional compatibility path.
  Its `grants` strings select namespace exposure; they do not mint resource
  capabilities. The active context still authorizes operations.
  Sandboxed code cannot create or manage either kind of sandbox load, even when
  the `runtime` namespace was granted accidentally.
- Runtime `declarations` exposes only bindings with real runtime `^value`;
  macros/derives remain compiler artifacts.
- `gene run [--allow_read_dir dir] [--allow_write_dir dir]
  [--allow_read_write_dir dir] file [--] [args...]` executes top level, then
  calls `main`. Pre-entry directory options mint host grants without evaluating
  Gene code. Positional strings form the first argument; `--grant` after the
  entry file is ordinary program data, not an authority channel. Embedders
  establish the root capability context through the host API.
- `main` returns `Nil` for exit 0 or an in-range `Int` exit code; other values
  are boundary errors.
- Native code retains values only through roots. Borrowed CallerEnv and
  in-progress construction values cannot be rooted. Foreign calls preserve
  Gene error/panic status and must obey thread attachment and Send rules.
