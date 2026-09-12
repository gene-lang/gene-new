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
- File imports use a literal string property: `(import x ^from "x.gene")`.
  Selections and `source : alias` remain positional; `^from` may appear before
  or after them. The old positional `from "path"` clause is rejected.
  Namespace imports retain `(import source [names])` and `(import source : alias)`.
- `^pkg` on the `^from` form selects a package; `"."` names that package's
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
- Before publishing a prepared generation, a host can call
  `$runtime/configure_module` under its selected capability context to seal
  that ceiling across the generation's owned module closure. The numeric
  policy must match preparation. Once sealed, configuration is immutable
  (an identical configuration is idempotent). Escaped functions and typed
  methods retain the ceiling even after module capability materialization.
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
  Gene error, panic, and cancellation status and must obey lane and Send rules.

## Synchronous native callbacks

The first supported C callback mode is a call-scoped callback on its owning
Application's root lane. Native bindings provide a typed C entrypoint and a
library-specific abort result. `ffi/callback` declarations still describe ABI
metadata; this release does not provide a general runtime callback-pointer
factory, retained subscriptions, or foreign-thread notification queues.
The wasm target rejects native C callback creation; the transpiled web profile
does not expose this native interface.

`gene/native_api` exports these native-only runtime helpers:

1. `newNativeSyncCallback(callee, scope, signature)` validates and roots the
   callable, optionally wrapping it in an enforced `Callable` signature, and
   captures the creating capability ceiling. No target/default code runs.
2. `beginNativeCallbackCall(context)` opens the single foreign-call window.
3. The C entrypoint initializes its ABI-valid abort result and uses
   `withNativeSyncCallback(context)` around all Gene allocation, argument
   conversion, and `invokeNativeSyncCallback`. The gate checks the owner before
   touching managed state. A foreign-lane attempt only records an atomic
   rejection and returns the binding's abort result.
4. After the foreign call returns, `finishNativeCallbackCall(context)` closes
   admission, releases target/scope roots, and rethrows any saved failure at
   the safe Gene boundary. Use it in cleanup too; finishing a closed context
   is idempotent, while finishing an executing callback is an error.

The native caller retains the context until the library guarantees that every
callback has returned and no further entry is possible. The library must not
retain its callback/context after the enclosing call. The C entrypoint itself
may be static code; its context is borrowed. A late call can be rejected only
while that context's storage still exists. Stale native pointers after release
remain a violation of the native binding contract.

The first escaping failure is retained. Gene errors keep their original typed
payload, cause, private classification, and Error witness; panic and cancellation
remain control outcomes. No such exception unwinds a C frame. Unexpected Nim
catchable failures become ordinary runtime errors, and Nim defects become
panics at the callback boundary. Fatal native faults and process termination
remain outside this mechanism's guarantees. An inner rejected native entry
also forces the enclosing callback to return its abort result.

Callback invocation intersects its captured ceiling with current authority
and uses the normal callable/module boundary and enclosing execution budget.
Synchronous callbacks cannot await unfinished tasks, join unfinished tasks,
block on channels or mailboxes, sleep/yield to the scheduler, or pump task
execution. Task/actor creation and native callback re-entry are rejected in
this first mode. Completed-task reads and nonblocking channel operations remain
available. Actor sends may enqueue work but do not drive handlers while the
callback is active. Blocking foreign code is not made interruptible by these
rules.

The Nim-facing `GeneApi` version is **4**. `GeneStatus` adds `gsCancelled`, and
`geneCall` transports cancellation instead of letting it escape the native
boundary. Rooted `geneCallCallback` handles require attachment, their owning
thread, and the synchronous callback rules. Non-function targets require an
explicit `GeneCall.dispatchScope`. Release from another lane or during an
invocation is rejected. Thread attachment is bookkeeping, not permission to
enter another lane or transfer non-Send values. Version-3 extensions must
rebuild and handle the cancellation status.

Executable coverage: `tests/test_native_callbacks.nim` calls a real C visitor
in `tests/fixtures/native_callback_fixture.c`, including foreign-thread and
reentrant entry attempts. The SQLite `visit_text_rows` binding is the first
real library consumer. Native API compatibility coverage remains in
`tests/test_native_api.nim`.
