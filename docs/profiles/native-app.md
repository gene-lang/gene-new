# Native application profile status

**Status:** PROFILE-0 exists; the overall native-app profile remains incomplete. This is a support ledger, not a release claim. The [manifest](../../tests/profiles/native-app/profile.gene) and [runner](../../tests/profiles/native-app/run.py) provide executable evidence; a planned stage never counts as passed.

The [2026-09-24 macOS arm64 audit](native-app-2026-09-24.md) records all five
workloads and four current-code 60-second service repeats. The
[2026-09-25 Linux x86_64 run](native-app-2026-09-25-linux.md) passed the same
five workloads and the full test suites in an Ubuntu 24.04 container under
Rosetta. Timing gates still need native x86_64 hardware, and the incomplete
stage gates remain open.

The [mixed-cancellation continuation](native-app-2026-09-26-cancellation.md)
records the stable-capture repair, the server Fiber-cancellation repair, and
the ten-child ORC lifetime profile. Multi-hour SERVICE evidence is pending.

The native VM currently supplies functions, modules, packages and locks, tasks, synchronous streams, JSON, files, HTTP, databases, and tests. Their existing specs cover those individual contracts. VAL-1–3 value witnesses, semantic equality/hash, indexed access, and stable sorting are experimental with native conformance and lifetime checks; cross-backend qualification remains open. The end-to-end Python replacement workloads have not yet passed their full release gates.

| Workload | Current status | Required next stages |
| --- | --- | --- |
| Script | APP-1 implemented; passing macOS arm64 fixture and typed fault checks | Native x86_64 Linux qualification and the full profile gates |
| Installed CLI | PKG-1 local install and experimental PKG-2 source-built C binding pass the macOS arm64 offline probe; a separate installed genex WebSocket fixture passes | Native x86_64 Linux qualification (deferred) and destination-host compatibility |
| Service | macOS arm64 60-second HTTPS proxy/stream/SQLite probes pass functionally at 30 requests/s; one earlier repeat missed the 250 ms heartbeat gate, and ten repeats after the serve-loop idle fix passed with 53–73 ms maximum gaps | Investigate the rare host-loop stall, native x86_64 Linux timing, and VM-3 lifetime gate |
| Data transformation | Experimental 10/100 MiB macOS arm64 probe passes, including typed group/record limit faults; parser payload is 13 bytes at EOF and peaks at 66,570 bytes for both sizes | Native x86_64 Linux qualification and remaining VAL/IO release gates |
| Long-lived VM | VM-0/1 experimental; VM-2 retirement of released, discarded, and failed sandbox generations is implemented; RC-enabled macOS arm64 probes hold identical managed-class counts through 10,000 fixed-vocabulary eval/closure/cell/failure lifetimes and 10,000 scalar, Type/protocol/impl, and discarded/failed generations | Other mixed-cycle classes, cancellation/service gates, AtomicArc, and native x86_64 Linux qualification |

Optional capabilities remain visible separately: experimental genex/tzdb (APP-3), experimental genex/archive (APP-4), direct TLS (NET-3), hosted publication (PKG-3), and experimental retained native notifications (NATIVE-3). Browser/C backend and AtomicArc worker support require their own qualification.

NET-3 has an experimental direct HTTPS listener and Task-valued certificate
reload through the installed OpenSSL adapter. The macOS arm64 installed probe
covers HTTPS dispatch, plaintext and untrusted-server rejection, failed
reload, and rotation; the C fixture covers required client authentication and
live old sessions. The TLS adapter and installed package tests also pass on
Linux x86_64 under Rosetta. Sustained service and native x86_64 Linux remain
unqualified.

PKG-3 has an experimental macOS arm64 client and CLI path for signed hosted
releases. A local TLS registry fixture covers version-page commitments,
registry and delegated-owner signatures, bounded object download, online
resolution and install, authenticated staged publication, idempotent repeat,
version conflict, and offline cache/vendor signature replay. It rejects wrong
keys, corrupted signatures, malformed responses, and fresh selection of
yanked versions. The fixture also passes on Linux x86_64 under Rosetta. The
persistent registry service now has a real Caddy/CLI fixture, complete-tree
admission, durable version selection, bounded staging, and offline key provisioning.
Sustained registry operation and native x86_64 Linux qualification remain open;
this fixture does not promote the native-app core profile.

APP-4 has a packaged zlib codec, gzip AsyncReader/AsyncWriter wrappers, and a
ZIP extractor. The macOS arm64 installed probe verifies gzip binary streams,
concatenated members, corrupt/truncated/trailing data rejection, flush versus
finish, abortive close, blocked-read/write cancellation, ZIP store/deflate and
CRC rejection, absent-destination publication, and normal CLI exit with an
unawaited cleanup obligation. A focused RC probe and the installed package
test verify abandoned codec stream retirement. Unicode-normalized path
collision rejection passes C and installed package fixtures. The installed
package and ZIP tests also pass on Linux x86_64 under Rosetta, given a
utf8proc whose pkg-config version is at least 3.1.0. Native x86_64
qualification remains open.

APP-3's standard `$temporal` arithmetic/RFC3339 and optional IANA 2026d
`genex/tzdb` package pass a macOS arm64 installed-app test with source and
compiler unavailable. The TZif reader matches an independent offset oracle
for all 597 packaged zones at six historical/current/future instants each;
New York fold/gap and historical second-offset cases pass. The installed-app
test also passes on Linux x86_64 under Rosetta; native x86_64 qualification
remains open.

The `genex/libuv_timer` package now passes a macOS arm64 installed-app probe
with 10,000 create/notify/close lifetimes, repeated wait_closed calls, a hidden
source checkout, and no compiler at launch. The package pins libuv 1.52.x and
uses the v5 ingress queue. Live native contexts/handles return to zero after
each close, 20,000 handle close callbacks are recorded, and native roots and
materialized leases return to baseline. The installed-app test also passes on
Linux x86_64 under Rosetta at its default 100 lifetimes, with libuv 1.52.1
built from source (Ubuntu 24.04 ships 1.48). Native x86_64 qualification
remains open.

The VM-3 lifetime batch probe builds a separate ORC `geneRcStats` binary and
uses a test-only collection safepoint. On macOS arm64, the fixed-vocabulary
eval/closure/cell/self-cycle/impl-failure/compile-failure workload held 881
managed values after warm-up and batches of 1, 100, 1,000, and 10,000. All
seven managed-class counts matched exactly, native roots and I/O leases
remained zero, and the retained closure still executed. A second child
process held 822 managed values and identical per-class counts while releasing
10,000 selected
ValueEq/Hash/Order Types; its retained Type still executed. The runner records
binary and compiler identity, RSS, counters, and the last progress marker on
timeout. A third child cancelled parked Tasks after each had created a Type
and ValueEq impl; it held 794 managed values and zero root Tasks at every
batch checkpoint. Mixed ownership graphs, module generations, cancellation
during selection, and sustained service remain outside that narrow probe. On
Linux x86_64 under Rosetta, all eight children held the same counts as on
macOS. Three generation children commit and release a scalar module
and a Type/protocol/impl module, and discard a prepared generation after
failing a second one, 10,000 times each. VM-2 retirement tears down each
module root once nothing outside its graph reaches it. The children hold 820,
820, and 822 managed values at every checkpoint, with no generation-record,
module-cache, compile-artifact, or impl growth. Before retirement the
Type/protocol/impl module grew 15 managed values per release and each
discard-plus-failure iteration grew 30. Retained module, function-only, and
instance/Type controls still execute after release. Retirement runs only at
release, discard, failed preparation, and the test collection point, and is
off under AtomicArc.
Two more children cover VM-3 gaps. A selection child cancels a Task parked
between two impls of one eval unit and fails units after a partial selection;
it holds 891 managed values with no open impl assemblies. An in-process
service child serves and drives 10,000 HTTP request pairs through the native
Client in one RC process and holds 866 values with no open I/O or requests.
A cancellation service child cancels a held GET and aborts a streamed upload
each iteration, so the server cancels that handler mid-body; it holds 968
values through 10,000 iterations with no open I/O, Client, or in-flight
requests (see the [lifetime ledger](../../tests/lifetime/LEDGER.md)).

The CLI probe now builds a selected `c_library`, calls its C ABI function,
and repeats that call after installing the application with the source
checkout hidden, an empty artifact cache, and no C compiler. It also checks
the locked dependency/resource, update generation, and failed-update
rollback. On macOS arm64 the fixture pins the available 26.5 SDK in
`tests/profiles/native-app/cli-toolchain.lock.json`; the host's current
default 27 SDK cannot link this C library with the installed linker. This
pin is recorded in the audit rather than silently changing the gate.

`gene/io` now exposes experimental qualified `AsyncReader`, `AsyncWriter`, and
`IoResource` contracts plus `write_all` and bounded `copy`. Third-party Gene
fakes exercise partial writes, EOF, repeatable wait_closed Tasks, and structured
scope settlement. The admission/retirement core has bounded byte budgets and
threaded tests; separate cleanup Tasks now survive user Task cancellation and
nested-scope unwind. `gene/io/testing` exercises the native admission and
late-completion path deterministically. Worker-backed POSIX file readers and
writers and `io/pipe` pairs now pass bounded read/write/copy, blocked-peer,
full-worker-pool fairness, EOF, and close tests on macOS. Blocked `io/pipe`
adapter operations park in a kernel `poll(2)` watcher while waiting for
readiness; `io_waiting_readiness` counts parked jobs across the process. Async
subprocess stdout and stderr now stream Bytes into consumed `io/pipe` writers, and stdin
reads Bytes from a consumed `io/pipe` reader. Borrowed endpoints auto-close
after worker completion. Experimental TCP streams/listeners now pass loopback,
slow-peer, cancellation, and byte-budget tests on macOS and on Linux x86_64
under Rosetta; native x86_64 qualification remains open. The HTTP server's experimental stream mode now
delivers bounded Content-Length and chunked request bodies as an `AsyncReader`;
slow-body, backpressure, truncation, framing-error, and buffered-mode parity
tests pass. Experimental `http/stream` responses pass binary, chunked,
known-length, reader failure, slow-peer, and same-socket upload echo tests.
The pinned Caddy 2.11.2 fixture now terminates HTTPS, overwrites incoming
forwarding headers, and proxies to a loopback Gene streaming service. A
60-second macOS arm64 probes completed 1,800 requests at about 30 requests/s,
with p95 between 14.57 and 16.83 ms in four current release-binary repeats
and zero tracked I/O leases/resources after graceful stop. Their maximum
host-loop heartbeat gaps were 52–63 ms. An earlier repeat observed a 336 ms
gap against the 250 ms target; that miss remains a qualification gap rather
than a relaxed budget. The probe
exercises streamed
upload/response, SQLite file writes, eight concurrent clients, and repeated
slow requests. The fixture is a probe because IO-3/NET-1/NET-2 remain
experimental and VM-3 and native x86_64 Linux timing remain open. Under
Rosetta on Linux x86_64 it passed with p95 11.73 ms and a 60 ms maximum
heartbeat gap. The
experimental owned Client
reuses HTTP/1.1 connections on one Application transport and supports
buffered/streamed responses, bounded AsyncReader uploads, and controlled
GET/HEAD redirects. Local tests cover duplicate headers, binary POST,
known-length and chunked uploads, upload cancellation, cross-origin credential
stripping, TLS trust, captured proxy settings, per-origin caps, queue
deadlines, and byte-budget retirement under ORC, AtomicArc, and ASAN. An
upload's exclusive read borrow covers native and Gene-defined AsyncReaders,
including held/dynamic sends, pipelines, inherited reads, pending-read admission,
failed-admission rollback, and cancellation through ensure cleanup. Native
backend aliases retain their lifecycle enforcement; custom convenience APIs
need their own backend policy. Full platform qualification remains open.

The experimental CSV reader now uses those qualified I/O contracts. Focused
tests cover one-byte UTF-8/quote/CRLF boundaries, malformed headers, pending
read cancellation, owned and unowned close, and a 10 MiB file. The DATA profile
fixture passed deterministic 10 MiB and 100 MiB inputs with 32 groups on macOS
arm64, plus typed failures for group and record limits. At matching EOF
checkpoints the parser retained 13 payload bytes for either input and its
per-reader peak was 66,570 bytes for either input, below the 8 MiB growth
budget. Upstream I/O retained zero bytes at EOF and peaked at 65,536 bytes.
The sampled process RSS peak was also unchanged in the latest run. Parser
payload counters exclude allocator capacity and object overhead, so the RSS
sample remains complementary evidence. This is a macOS probe, not a
cross-platform release result.

Run `python3 tests/profiles/native-app/run.py` for a machine-readable audit. `--probe-blocked` runs existing fixture code even when prerequisites are planned and records a probe result; it does not promote a workload. `--require-supported` fails unless every required workload has authoritative passing evidence. Reports go under `tmp/native-app-profile/` and record the Gene binary, platform, revision, stage state, and workload result. APP-1's path, walk, and CSV spec cases pass, and the script fixture exercises normal and three failed inputs. `nimble spec` passes after the catch-scope fix and the proposal-aware documentation lint. A future stage promotion must add conformance evidence and update both this ledger and the manifest.

Implementation order and the release gates are in [the profile proposal](../proposals/python-replacement-profile.md#recommended-implementation-order).

The [2026-09-26 reader-borrowing audit](native-app-2026-09-26-reader-borrowing.md)
records the generic protocol admission and final four-gate/full-profile results.
SCRIPT passes; CLI/SERVICE/DATA/LIFETIME remain probe passes. The 60-second
SERVICE result has a 54 ms maximum heartbeat gap, managed growth 0, and clean
shutdown; it does not substitute for the independent sustained-service gate.

PKG-2 environment-dependent C derivations now carry a per-build-installation
host identity outside artifact stores. A shared/copied store cannot authorize
reuse on another build installation; imported compiler evidence can only replay
a required verified installed closure. This conservative policy does not claim
hermetic C builds or compatibility with an unqualified destination. PKG-3
deployment and recovery are specified in [registry-service.md](../spec/registry-service.md).
Linux work is deferred at the user's request; profile stages remain unchanged.

The [2026-09-27 distribution audit](native-app-2026-09-27-distribution.md) records
the native cache policy, persistent registry, and sampled value-backend outcomes.
Six native/wasm semantic samples agree; unsupported web/C witness probes refuse
execution. Full VAL backend/worker/lifetime qualification remains open.
