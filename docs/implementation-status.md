# Implementation status

**Status date:** 2026-07-28

The current VM implements the reader/value/printer pipeline, callable-first
bytecode execution, runtime fexprs and template macros, selectors and streams,
gradual nominal types, protocols/derivation with scoped impl visibility
(canonical/scoped/overlay, `import_impl`, transactional reload —
`docs/scoped-impls.md`), structured tasks/channels/actors, module/eval
overlays, explicit capability values, native roots/calls, typed FFI
boundaries, `^repr native_wrapper` types (design §16.6),
serialization, the experimental `gene runurl` URL-module entry
(design §15.9), and the AI-agent support libraries exercised by
`examples/ai_agent`.

The normative implemented surface lives in `docs/spec/` and is checked by
`nimble spec`. Unit and integration coverage runs with `nimble test`; broad
runtime verification uses `nimble verify`.

The experimental `typed_native` C backend (`gene compile --target c`,
`docs/proposals/native-type.md` Part II) lowers native-pointer parameters,
field access, and direct typed calls, and its dynamic boundary is now
connected in both directions: `aot/load` opens a compiled library and binds
its `^native_entry` functions and `ffi/fn` wrappers as ordinary callables, so
Gene code can call compiled machine code and managed wrappers cross the seam
with borrow/transfer/copy ownership. The lowerable subset covers field access,
locals, direct/FFI/protocol calls, arithmetic, comparisons, `if`, `while`, and
block statements.

It remains experimental. Direct protocol sends are guarded only within the
compiling module, so a cross-module overlay over an AOT-compiled type is a
known limitation, and there is no `gene build` producing a linked artifact —
that waits on package and dependency support, since what to link against is a
dependency-graph question. `examples/native` drives `cc` from a shell script
meanwhile.

Deferred work is explicitly non-normative. Major deferred areas include package
version resolution/registries, static effect rows, full hygienic compile-time
function macros, partial protocol impl composition, static enum exhaustiveness,
arbitrary escaping foreign callbacks/foreign-thread VM entry, JIT, and AOT
beyond the experimental backend described above.

For the AI agent, typed tools, event tracing, persistence, gateway surfaces,
cancellation, and the embedded terminal are shipped. The next packaging slice
is migrating its current built-in capability reads to explicit named `main`
grants now supported by `gene run` and `GeneCall`.
