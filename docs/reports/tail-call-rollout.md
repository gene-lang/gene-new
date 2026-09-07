# Tail-call rollout record

**Status:** historical verification notes from 2026-08-31. These checkboxes and
old failure reports describe that rollout, not the current repository state.
Current semantics are in [proper tail calls](../tail-calls.md) and the
[call contract](../spec/calls.md).

> **Implementation status (2026-08-31): In progress**
>
> - [x] Stage 0 — durable baseline, counters, and fallback diagnostics (focused tests pass)
> - [x] Stage 1 — compiler tail proof and GIR v3 (focused tests pass)
> - [x] Stage 2 — shared bytecode call entry (focused tests pass)
> - [x] Stage 3 — redundant return-policy proofs (focused tests pass)
> - [x] Stage 4 — sends, protocol messages, and custom `Callable` (focused tests pass)
> - [x] Stage 5 — transparent match arms (focused and release/ORC probes pass)
> - [ ] Stage 6 — final verification
>   - [x] bounded trace window and elision diagnostics
>   - [x] normative design/spec documentation
>   - [ ] repository-wide `test` and `verify` gates
>
> A box is checked only after its implementation and stage-specific tests pass.
> The final status becomes **Complete** only after the repository's required
> `test`, `spec`, `perf`, `wasm`, and broad `verify` gates pass.
>
> Current evidence: focused ORC and atomic-ARC TCO suites, GIR round-trip,
> `nimble spec`, `nimble perf`, and final `nimble wasm` pass. The repository-wide
> `test`/`verify` status remains open because unrelated, previously documented
> AI-agent state-store tests fail when the store backend is unavailable;
> the same test fails identically on pre-TCO commit `7faa2f4` in an isolated
> clean temp directory. The
> threaded async-filesystem capability and one legacy RC wildcard fixture also
> fail independently of TCO.

