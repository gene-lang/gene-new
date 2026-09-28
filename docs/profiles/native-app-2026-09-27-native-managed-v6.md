# Managed extension ABI 6 loader slice — 2026-09-27

The owner-selected opaque extension path now has an additive C layout in
`src/gene/native_api_v6.h` and an initial loader in
`src/gene/native_managed.nim`. The v4/v5 API tables, symbols and versioned
loader are unchanged. The ABI 6 table advertises **zero feature bits** and
all operation pointers are null; this checkpoint qualifies layout and
initialization negotiation, not handle operations or native callbacks.

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
environment ID. `tests/test_native_managed_v6.nim` covers accepted init,
pre-init feature rejection, copied C failure diagnostics, 100 repeated failed
inits, released library handles and a library without the v6 symbol. Both
normal ORC and genuine AtomicArc probe pass two cases; ASAN passes the same two
without a reported memory error. Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| ORC | `ce555e04bf4f66ed09499ad7afef18311d14993af78c928ca8362b8e7709e0cd` |
| AtomicArc probe | `5497b17ead76929973d102893d41715b8aa2b966aabd977147581b5ffe989624` |
| ASAN probe | `5a3973dc87ba9cb6e5f6639a43e206da78c97aa37d93fbff456caca9d3e776c5` |

Next are the registry-backed C handle operations, callback registration and
physical library/context retirement, then ABI 6 byte-ingress linkage and
package metadata dispatch. The zero-feature table does not qualify installed
extensions for AAR-2; v4/v5 raw references remain permanently published.
No runtime profile stage is promoted. Linux and the SERVICE heartbeat remain
deferred by the owner.
