# Managed extension ABI 6 qualification — 2026-09-28

The owner-selected opaque extension path now has an additive C layout in
`src/gene/native_api_v6.h` and an initial loader in
`src/gene/native_managed.nim`. The v4/v5 API tables, symbols and versioned
loader are unchanged. The ABI 6 table advertises root-lane
`GENE_API_V6_IDENTITY_FEATURE` for opaque-ID retain/release, kind and Int64
construction, and `GENE_API_V6_SCALAR_FEATURE` for copied Bool/Int64/Str/Bytes
reads plus Bool/Str/Bytes constructors. `GENE_API_V6_CALL_DEFINE_FEATURE`
adds root-lane environment lookup, positional call with separate value/error
IDs, and definition with per-binding weak/code Scope tickets.
`GENE_API_V6_FROZEN_FEATURE` adds length, copied keys and owning child handles
for deeply frozen List/Map/Node values. Threaded AtomicArc also advertises
`GENE_API_V6_ATTACHED_FEATURE`: an attached C lane can retain/release IDs and
use copied reads and frozen traversal. Constructors, lookup, calls and
definitions stay on the root lane. Other operation pointers remain null;
callbacks and ingress are not qualified.

`geneManagedLoadModuleV6` requires a live managed library and environment on
the root lane. It rejects unavailable required feature bits before invoking C,
looks up only `gene_module_init_v6`, passes a nonzero opaque environment ID,
and copies a bounded initializer diagnostic. A successful load returns an
owning opaque Module handle. The initializer's temporary environment handle
expires on return. Repeated failed loads leave the managed registry root count
and, under `geneRcStats`, the manual Value count at baseline. The Module Scope
is not registered as a permanent base scope in this slice.

`tests/fixtures/native_managed_v6_fixture.c` compiles against the public C
header and checks the exact version, structure size, runtime context and
environment ID. It exercises Int64 creation, kind, retain, release and stale-ID
rejection through the C table. It also checks copied scalar reads, embedded-NUL
UTF-8 text, arbitrary binary octets, two-call output length probing and invalid
UTF-8 rejection. It also calls a Gene function, observes a typed error ID,
defines and looks up scalar and function exports after their input handles
release. Frozen traversal covers List entries, Map keys/values, Node head/body/
properties, a child handle surviving its parent, out-of-bounds and stale
handles, and rejection of a mutable List.
The AtomicArc fixture checks before-attach and after-detach read rejection,
foreign copied reads/retain/release, wrong-lane detach, close while attached,
release/detach after close, the 256-token bound and monotonic token IDs.
It also reads an indexed frozen Map key from C while the root lane interns
10,000 new symbols. `propKeyAtCopy` copies under the symbol-table lock, so
attached key reads do not borrow the reallocated intern table.
`tests/test_native_managed_v6.nim` covers accepted init,
pre-init feature rejection, copied C failure diagnostics, 100 repeated failed
inits, released library handles and a library without the v6 symbol. The C
fixture also rejects an input claiming more than the 64 MiB copy limit before
reading its one-byte source; its source SHA-256 is
`cbb9658076f1063c6aa25fa69fcd14d22a61c2789606e3dc366b428fcfe13f65`.
ORC passes two cases and skips the attached-lane control. Disabled AtomicArc,
opt-in probe, ASAN and TSAN pass all three cases. Both the Nim executable and
the C fixture were instrumented in the ASAN and TSAN runs. The existing
39-case managed SDK probe also passes after the domain-table change. Binary
SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| ORC | `c41d410132b8e7fb1202dbdb03ae24b857b44ac8f2f987aef450bceb7d5da34a` |
| AtomicArc disabled | `33f7a860b101710decf2ff940a7ac8e3c268da23ea58229335d7d45df4288d16` |
| AtomicArc probe | `ef4d80197cfd6adad5fc4ffa68fa6f999db85f309c584a8393ae2f5d20f57315` |
| ASAN probe | `d9db35e1b9ccfa01af67c85a74ce961afc547102f92cc567b54f76e1ca307ae8` |
| TSAN probe | `3ab341b1d0bfa3eaf4fd7513f484c89d028cc8ec523741436d04ae9737695ecd` |

Next are callback registration and physical library/context retirement, then
ABI 6 byte-ingress linkage and package metadata dispatch. The current
read/ownership features do not qualify installed extensions for AAR-2; v4/v5
raw references remain permanently published.
No runtime profile stage is promoted. Linux and the SERVICE heartbeat remain
deferred by the owner.
