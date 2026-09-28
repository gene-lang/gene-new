# Managed extension ABI 6 loader slice — 2026-09-27

The owner-selected opaque extension path now has an additive C layout in
`src/gene/native_api_v6.h` and an initial loader in
`src/gene/native_managed.nim`. The v4/v5 API tables, symbols and versioned
loader are unchanged. The ABI 6 table advertises only the root-lane
`GENE_API_V6_IDENTITY_FEATURE`: opaque-ID retain/release, kind and Int64
construction. All other operation pointers remain null. Attached-lane calls,
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
rejection through the C table. `tests/test_native_managed_v6.nim` covers accepted init,
pre-init feature rejection, copied C failure diagnostics, 100 repeated failed
inits, released library handles and a library without the v6 symbol. Both
normal ORC, disabled AtomicArc and genuine AtomicArc probe pass two cases;
ASAN passes the same two
without a reported memory error. The existing 35-case managed SDK probe also
passes after the domain-table change. Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| ORC | `1e962bf3fb6c65128c866f26b31abe1ab7c85d275e1586e6868c66552f3b23b5` |
| AtomicArc disabled | `a2efaaacdd5ac725a4a7130e4fca052bfb97816b525fa55fa92ab989a212ed90` |
| AtomicArc probe | `cdb5873135501a11ac7bfa2dd24c5854374ee08f1c5129df66e68d2fa1abc0a6` |
| ASAN probe | `dcf62b79b19f376eaf8b27cebfa761e7e6190e7fa5d3984d0897787b5637952a` |

Next are copied text/Bytes, frozen traversal, call/define, attached-lane
admission, callback registration and
physical library/context retirement, then ABI 6 byte-ingress linkage and
package metadata dispatch. The one-feature table does not qualify installed
extensions for AAR-2; v4/v5 raw references remain permanently published.
No runtime profile stage is promoted. Linux and the SERVICE heartbeat remain
deferred by the owner.
