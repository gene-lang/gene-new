# Applications, modules, reflection, and native boundaries

**Status:** normative and implemented. Executable coverage: module, macro,
entrypoint, serde, native API, and CLI suites.

- Each run owns an Application, normalized package root, load-once module
  cache, and root namespace. Compile-time macro artifacts and runtime module
  initialization have separate caches/cycle diagnostics.
- Runtime imports initialize a dependency once. Compile-time macro discovery
  does not execute dependency top-level forms or grant host runtime authority.
- Runtime `declarations` exposes only bindings with real runtime `^value`;
  macros/derives remain compiler artifacts.
- `gene run file [--grant name=expr] [--] [args...]` executes top level, then
  calls `main`. Positional strings form the first argument; explicit grants are
  named arguments. Missing named capabilities fail before the body. Embedders
  use the same `GeneCall` named envelope.
- `main` returns `Nil` for exit 0 or an in-range `Int` exit code; other values
  are boundary errors.
- Native code retains values only through roots. Borrowed CallerEnv and
  in-progress construction values cannot be rooted. Foreign calls preserve
  Gene error/panic status and must obey thread attachment and Send rules.
