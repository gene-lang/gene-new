# Packaged managed native modules

A selected GeneApi binary is opened with `($pkg/native_module package "alias")`.
The function accepts a `Package` and one selected recipe alias. It rejects an
ordinary `c_abi` binary, an unsupported GeneApi version, or an unselected
alias before loading library code. Selection and materialization keep the
existing target, digest, runtime-identity and system-dependency checks from
[package distribution](../proposals/package-distribution.md). A source-built
`c_library` opts in with `^abi_kind gene_api`; the build records the sole
supported numeric `GeneApi` version and runtime identity. A prebuilt
`native_binary` variant declares those fields explicitly.
As with `pkg/native_binary`, the package target must name the recipe in
`^uses` before runtime lookup is available.
At opening, the selected runtime identity must also match the exact running
Gene executable, so a verified artifact cannot be replayed under a different
runtime image.

`pkg/native_module` returns a non-Send `NativeModule` resource. Its `.module`
message returns the Gene Module value produced by `gene_module_init` while the
owner is active. It implements `IoResource:close` and
`IoResource:wait_closed`, and `.status` reports active, closing, or closed
plus managed root/registration/producer counts, copied-result queue count and
bytes, and a terminal category. The queue fields are `copied_queued`, `copied_bytes`,
`copied_reserved`, and `copied_reserved_bytes`; the reservation fields count
concurrent submissions that have not yet reached the queue. Package Gene code
retains the owner for as long as it exposes native functions:

```gene
(import $io [IoResource])
(let owner ($pkg/native_module this_pkg "native"))
(let exports (owner .module))
(let answer (exports/increment 41))
(owner .IoResource:close)
(await (owner .IoResource:wait_closed))
```

The Gene CLI installs the managed loader adapter at startup. Nim embedders
using `vm` directly must import `native_managed` to install the same adapter.

The owner holds the materialized artifact lease, an open `ffi/Library`, a
managed domain and its stable API table, and the Module's owning ID. A module
initializer may register synchronous C callbacks; each registration retains
its C context and an independent library borrow. `close` first denies new
callback invocations and consumes remaining registration tokens into
runtime-owned close Tasks. It does not block inside a callback. The root
scheduler waits for every callback frame, C retirement function, attached
native lane and producer owner to finish before sealing the domain. It then
releases managed IDs, closes the library, closes the artifact lease, and
settles user waiters. Cancelling a waiter does not cancel physical retirement.
A dropped `NativeModule` handle requests the same cleanup on the root
completion pass.

After close, an already escaped Module value may still be held by Gene code.
Its former C callables refuse invocation before reaching unloaded library
code. `.module` on the closed owner also fails. `wait_closed` remains
repeatable and returns a fresh Task for each call. Initializer failure rolls
back registrations and all IDs created during initialization, then closes
the library and lease without publishing a module handle.

This does not add Gene syntax or a second C ABI. C callback registration is
currently admitted during `gene_module_init`; late registration remains a
separate design. A registered callback may create and return a Task using
`new_task`, which returns an owning Task ID and an opaque producer token. The
token holds an independent library borrow until `task_complete`, `task_fail`,
or `task_retire`; `task_cancel` only cancels the user Task. Module close waits
for that physical token even after the callback registration retires or the
user Task is cancelled. See the
[C ABI producer contract](../proposals/native-managed-extension-abi.md#native-callback-registration).
The current attached-lane completion takes `nil` or an already-rooted,
deep-frozen payload ID. A worker can instead use the
[copied-result handoff](../proposals/native-task-result-handoff.md) to submit
Nil, Bool, Int, Text or Bytes. The root lane constructs the Gene value and
settles the Task; `task_submit_copy` reports queue admission, not whether the
user Task accepted the eventual result.
The installed macOS arm64 fixture
in `tests/test_genex_native_module.py` checks source-built and prebuilt selected
`gene_api` images, compiler-free launch, ABI-kind refusal, initializer rollback,
re-entrant close from an active C callback, repeated physical close,
abandoned-handle cleanup, safe refusal from an
escaped Module value, and materialized/native root baselines. Native Linux
timing remains deferred by the owner.
The source-built module registers two C callbacks; close and initializer
rollback each prove that both contexts retire before the image is released.
`$runtime/gc_stats` reports `native_module_records`; it returns to zero after
closed owner handles are released, including the abandoned-handle control.
