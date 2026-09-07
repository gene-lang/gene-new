# Self type implementation verification

Implemented on 2026-09-07 against [the approved design](../self-type.md).

The compiler retains override intent and source annotation provenance. The VM
resolves declaration and conformance contracts, tracks forward dependencies,
and recomposes inherited bodies when visibility changes. Web protocol defaults
compile in their defining module and receive immutable conformance validators.
Both backends use `src/gene/type_contracts.nim` for callable compatibility.

This verification recorded GIR format **8**; subsequent nil/void work moved
the current format to **9**. Older artifacts must be rebuilt; the decoder
rejects runtime-only Self bindings and declaration state in serialized code.

## Semantic coverage

| Contract | Evidence |
| --- | --- |
| Declaration-bound and inherited Self, direct override intent, both impl modes | `tests/test_self_type.nim`, shared `self.*` fixtures |
| Per-protocol bindings, diamonds, defaults, new child messages | Focused Self suite and shared mixed-default fixtures |
| Body-local Self, escaping closures, lexical defaults, imported name collisions | Focused Self suite and shared default/closure fixtures |
| Expanded aliases, forward annotations, errors, exact callable shape | Focused Self suite and `tests/test_protocols.nim` |
| Readiness, prospective duplicates, eval and skipped registrations | Focused Self suite and `tests/test_modules.nim` |
| Reused lexical/super context, source recomposition, reload rollback | Focused Self suite and module reload tests |
| Universal defaults, explicit universal impls, held message values | Focused Self suite and shared universal fixtures |
| Captured task context and receiver lifetime | Focused Self suite under atomicArc; ORC reference-count tests |
| Native annotation compatibility and artifact state | Native executable specs and `tests/test_vm.nim` |

## Checks

- Full suite: **1,226 passed**. Later native-label compatibility cases passed in
  the focused suite and executable specs.
- Executable language specs: **712 passed**.
- Focused Self suite: **43 passed**.
- Shared VM/web fixtures: **216 passed on each backend**.
- Module tests: **96 passed**; VM/artifact tests: **331 passed**.
- ORC reference-count tests: **34 passed**.
- Web async, DOM, embedded-module, and host-binding checks passed.
- Generated TypeScript and declarations passed strict **TypeScript 5.9.2** checks,
  including all eligible Self fixtures and their imported modules.
- Threaded value, VM, native API, and worker checks passed. The 38 focused cases
  present at that checkpoint also passed under atomicArc, including spawned Self.

The atomicArc reference-count suite remains red on existing scope/cycle cleanup
checks. An isolated unchanged-HEAD build reproduced all **15** pre-existing
failing groups. The new Self cleanup group is also affected by those existing
root-scope cycles. A new owning-scope impl backedge was removed: the repeated
500-iteration conformance case retains six objects on both unchanged HEAD and
the implementation, rather than retaining one additional record per iteration.
Default ORC cleanup passes. This is not a claim that `nimble threadcheck` is green.

## Performance

The release core benchmark run completed successfully. Its inherited-method
fixture now includes the required direct override flag. Protocol-list
checks at sizes 1, 32, and 512 are covered by `benchmarks/bench_self_type.nim`,
which is also invoked by the core benchmark. Run it with `-d:nimAllocStats` to
report allocator counts alongside elapsed time. These are informational
measurements; no before/after performance claim is made without a paired baseline.

The allocation-instrumented release run completed 2,000 calls per case:

| List size | Same module | Cross module | Allocations / deallocations per case |
| --- | ---: | ---: | ---: |
| 1 | 4.94 ms | 5.00 ms | 38,000 / 38,000 |
| 32 | 27.97 ms | 28.93 ms | 38,000 / 38,000 |
| 512 | 400.00 ms | 391.46 ms | 38,000 / 38,000 |

These counts cover the whole call path, including type checks; they are not
attributed exclusively to protocol lookup. Temporary fixture directories are
unique per run so concurrent benchmark runs do not share module files.
