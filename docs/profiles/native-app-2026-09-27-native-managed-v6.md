# Managed extension ABI 6 loader slice — 2026-09-27

The owner-selected opaque extension path now has an additive C layout in
`src/gene/native_api_v6.h` and an initial loader in
`src/gene/native_managed.nim`. The v4/v5 API tables, symbols and versioned
loader are unchanged. The ABI 6 table advertises root-lane
`GENE_API_V6_IDENTITY_FEATURE` for opaque-ID retain/release, kind and Int64
construction, and `GENE_API_V6_SCALAR_FEATURE` for copied Bool/Int64/Str/Bytes
reads plus Bool/Str/Bytes constructors. `GENE_API_V6_CALL_DEFINE_FEATURE`
adds root-lane environment lookup, positional call with separate value/error
IDs, and definition with per-binding weak/code Scope tickets. Other
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
defines and looks up scalar and function exports after their input handles
release. `tests/test_native_managed_v6.nim` covers accepted init,
pre-init feature rejection, copied C failure diagnostics, 100 repeated failed
inits, released library handles and a library without the v6 symbol. The C
fixture also rejects an input claiming more than the 64 MiB copy limit before
reading its one-byte source; its source SHA-256 is
`b6ed8608fbaccad18267edce35e8bcd0a61d69fe98d01ddbfaf76cd34cdb7c35`.
Normal ORC, disabled AtomicArc and genuine AtomicArc probe pass two cases;
ASAN passes the same two without a reported memory error. The expanded
37-case managed SDK probe also
passes after the domain-table change. Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| ORC | `f3a36eccc06f63f46f833d71fcf148e6759b7ca7f90fb598e483fc145406a214` |
| AtomicArc disabled | `809cd63c2cc4663e6063bbfbddb339b011edc851480aa27b498e5890e70ad0ae` |
| AtomicArc probe | `eb7f91d5f728e1adba2bb4cc53e009459d7708a4009db194561096799b4846f5` |
| ASAN probe | `efa8195716065399c7943ec4b7341200370850e78149b73afe77e625a7230f2b` |

Next are frozen traversal, attached-lane
admission, callback registration and
physical library/context retirement, then ABI 6 byte-ingress linkage and
package metadata dispatch. The one-feature table does not qualify installed
extensions for AAR-2; v4/v5 raw references remain permanently published.
No runtime profile stage is promoted. Linux and the SERVICE heartbeat remain
deferred by the owner.
