# Implementation status

**Status date:** 2026-07-10

The current VM implements the reader/value/printer pipeline, callable-first
bytecode execution, runtime fexprs and template macros, selectors and streams,
gradual nominal types, protocols/derivation, structured tasks/channels/actors,
module/eval overlays, explicit capability values, native roots/calls, typed FFI
boundaries, serialization, and the AI-agent support libraries exercised by
`examples/ai_agent`.

The normative implemented surface lives in `docs/spec/` and is checked by
`nimble spec`. Unit and integration coverage runs with `nimble test`; broad
runtime verification uses `nimble verify`.

Deferred work is explicitly non-normative. Major deferred areas include package
version resolution/registries, static effect rows, full hygienic compile-time
function macros, partial protocol impl composition, static enum exhaustiveness,
arbitrary escaping foreign callbacks/foreign-thread VM entry, and production
AOT/JIT backends beyond the existing prototypes.

For the AI agent, typed tools, event tracing, persistence, gateway surfaces,
cancellation, and the embedded terminal are shipped. The next packaging slice
is migrating its current built-in capability reads to explicit named `main`
grants now supported by `gene run` and `GeneCall`.
