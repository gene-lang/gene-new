# Managed extension ABI 6 loader slice — 2026-09-27

The owner-selected opaque extension path now has an additive C layout in
`src/gene/native_api_v6.h` and an initial loader in
`src/gene/native_managed.nim`. The v4/v5 API tables, symbols and versioned
loader are unchanged. The ABI 6 table advertises root-lane
`GENE_API_V6_IDENTITY_FEATURE` for opaque-ID retain/release, kind and Int64
construction, and `GENE_API_V6_SCALAR_FEATURE` for copied Bool/Int64/Str/Bytes
reads plus Bool/Str/Bytes constructors. `GENE_API_V6_CALL_DEFINE_FEATURE`
adds root-lane environment lookup, positional call with separate value/error
IDs, and definition of values without external Scope/code provenance. Other
operation pointers remain null. Attached-lane calls, callbacks and ingress
are not qualified.

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
defines and looks up a scalar export, and rejects an attempted function binding
whose defining Scope lacks a per-binding ticket. `tests/test_native_managed_v6.nim` covers accepted init,
pre-init feature rejection, copied C failure diagnostics, 100 repeated failed
inits, released library handles and a library without the v6 symbol. The C
fixture also rejects an input claiming more than the 64 MiB copy limit before
reading its one-byte source; its source SHA-256 is
`66b4e65a54bb49fb61911bfba0b11dfc9d1ed7def2c1521f7756a4f90770a651`.
Normal ORC, disabled AtomicArc and genuine AtomicArc probe pass two cases;
ASAN passes the same two without a reported memory error. The existing
35-case managed SDK probe also
passes after the domain-table change. Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| ORC | `291cf661ec159be6f8b8525c1daa5201b0ebe2934df40644a66f2f7eb7794c55` |
| AtomicArc disabled | `4796ed12d0539548ce2a5ec11163a7136f7759f3c7c8af58f6f71b75dce35f2c` |
| AtomicArc probe | `2fd125a6e6dc4a350f9650ce48622b2866a8e462bf40b0c36ad7e9045ae63884` |
| ASAN probe | `ce36e7d1c8f6dc9e86b4768fa50dc1bc86bf6a5249143776660f98da60ea00f8` |

Next are per-binding tickets for Scope-bearing definitions, frozen traversal,
attached-lane
admission, callback registration and
physical library/context retirement, then ABI 6 byte-ingress linkage and
package metadata dispatch. The one-feature table does not qualify installed
extensions for AAR-2; v4/v5 raw references remain permanently published.
No runtime profile stage is promoted. Linux and the SERVICE heartbeat remain
deferred by the owner.
