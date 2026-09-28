# Managed extension ABI 6 loader slice — 2026-09-27

The owner-selected opaque extension path now has an additive C layout in
`src/gene/native_api_v6.h` and an initial loader in
`src/gene/native_managed.nim`. The v4/v5 API tables, symbols and versioned
loader are unchanged. The ABI 6 table advertises root-lane
`GENE_API_V6_IDENTITY_FEATURE` for opaque-ID retain/release, kind and Int64
construction, and `GENE_API_V6_SCALAR_FEATURE` for copied Bool/Int64/Str/Bytes
reads plus Bool/Str/Bytes constructors. Other operation pointers remain null.
Attached-lane calls, callbacks and ingress are not qualified.

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
UTF-8 rejection. `tests/test_native_managed_v6.nim` covers accepted init,
pre-init feature rejection, copied C failure diagnostics, 100 repeated failed
inits, released library handles and a library without the v6 symbol. The C
fixture also rejects an input claiming more than the 64 MiB copy limit before
reading its one-byte source; its source SHA-256 is
`45d3a84fb6688c95b611a97c928165d1e58f146c22fd15fb91d4150135ca7c62`.
Normal ORC, disabled AtomicArc and genuine AtomicArc probe pass two cases;
ASAN passes the same two without a reported memory error. The existing
35-case managed SDK probe also
passes after the domain-table change. Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| ORC | `f70770a75e87111b1c301824cddb8fd0ad7ed601641497fdf22caa8ea8e951c0` |
| AtomicArc disabled | `968ef0c4a4366cccc0d5f4441c2a55a14cee3647ed7027cfc29e7fefabead7fc` |
| AtomicArc probe | `03a4417c025b57aab33e21a72b7a18992406e8f792299320b968bd0bc5790815` |
| ASAN probe | `5e14cd06f3f19f3fb06a77e3787286443fcfad19af9ba66969da2b5e11b3fdcb` |

Next are frozen traversal, call/define, attached-lane
admission, callback registration and
physical library/context retirement, then ABI 6 byte-ingress linkage and
package metadata dispatch. The one-feature table does not qualify installed
extensions for AAR-2; v4/v5 raw references remain permanently published.
No runtime profile stage is promoted. Linux and the SERVICE heartbeat remain
deferred by the owner.
