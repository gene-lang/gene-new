# Native-app profile: Linux x86_64 run, 2026-09-25

This is the first Linux x86_64 run of the test suites and the
[native-app profile](native-app.md). It complements the
[2026-09-24 macOS arm64 audit](native-app-2026-09-24.md). It is probe-level
evidence. It does not change any stage claim, and `--require-supported` still
fails while stages remain planned.

## Environment

The run used an Ubuntu 24.04 `linux/amd64` container from
[`tools/linux-x86_64`](../../tools/linux-x86_64/Dockerfile), started through
`tools/linux-x86_64/run.sh`. The runner copies the tracked tree into a fresh
container. The host was Apple silicon, so Docker Desktop ran the image under
Rosetta (`/proc/cpuinfo` reports `VirtualApple`). Timing results therefore
include emulation, and a native x86_64 host is still needed to qualify the
timing gates.

| Component | Version |
| --- | --- |
| Nim | 2.2.4 (official `linux_x64` tarball) |
| C compiler | gcc 13.3.0 |
| Runtime libraries | libcurl 8.5.0, SQLite 3.45, OpenSSL 3.0.13, PCRE 8.39 (distribution packages) |
| Built from source | libuv 1.52.1, utf8proc 2.11.3 (pkg-config 3.2.3), curl 8.19.0 in `/opt/curl` |
| Proxy | caddy v2.11.2, matching `service/proxy.lock.json` |

## Results

| Check | Result |
| --- | --- |
| `nimble test` | 1,538 passed and every Python and wasm step passed; one Rosetta-only skip (below). The macOS-only case-insensitive-filesystem skip runs and passes here. |
| `nimble spec` | 775 passed |
| `nimble leakcheck` | 64 passed, including the retirement ORC-header layout probe |
| `nimble threadcheck` (AtomicArc) | 521 passed |
| `genex/websocket` installed package | Passed against curl 8.19.0 through `GENE_PKG_CONFIG_PATH=/opt/curl/lib/pkgconfig` and `LD_LIBRARY_PATH=/opt/curl/lib`. Without them it skips, as it does on macOS without Homebrew curl. |
| Profile: SCRIPT | pass |
| Profile: CLI | probe pass: offline install from another directory, update changed generation, failed update kept the current one |
| Profile: SERVICE | probe pass: 1,800 HTTPS requests at 30/s through the proxy, p50 7.25 ms, p95 11.73 ms, p99 15.98 ms, 60 ms maximum heartbeat gap (a 10 ms kernel wait overrun, 0 ms loop work), slowest SQLite call 8 ms, graceful stop with zero I/O resources and leases |
| Profile: DATA | probe pass: 10 and 100 MiB inputs, typed group and record limit faults, zero parser-peak and EOF-retention growth between sizes |
| SERVICE with an RC build | A `-d:release -d:geneRcStats` binary held 995 managed values at all 13 heap samples (zero growth), 60 ms maximum heartbeat gap |
| Profile: LIFETIME | probe pass: all eight children held 881, 822, 794, 891, 866, 824, 824, and 826 managed values at warm-up and after 1/100/1,000/10,000 lifetimes, the same counts as macOS; retained module, function, and instance controls ran |

## Defects found and fixed

- **Linux startup crash.** `nim.cfg` passed the macOS linker flag
  `-Wl,-export_dynamic` to every non-wasm target. GNU ld reads it as
  `-e xport_dynamic`, a nonexistent entry symbol, so the binary started at
  the beginning of `.text` and segfaulted. ELF targets now use
  `--export-dynamic`.
- **Use-after-free while checking a module graph.** `collect` in
  `checkModuleErrorGraph` saved `currentModuleDir` and `currentPackage` with
  `let` inside a closure, and ORC inferred non-owning cursors. Reassigning the
  fields freed what the cursors pointed at, and the restore read reused memory:
  7 `test_error_handling` cases failed on glibc with garbage module paths
  ("The specified root is not absolute: 3…"). With `--cursorinference:off` all
  108 passed. `--expandArc` showed cursors only at this closure and at
  `compileTree`'s `savedPackage`, and every flat save site copied. Both now
  use `ownedCopy`.
- **Streamed request through a redirect could end empty.** The HTTP client's
  service loop read `redirectResponse` before acquiring `headersReady`, and
  `headersReady` before `workerDone`. The worker publishes them in the
  opposite order. A stale read either delivered the redirect's own headers and
  empty body as the final response, or reported a finished redirect as a
  transfer without headers. The loop now takes one snapshot per pass, in
  reverse publication order. The redirect stream test failed 12 of 20 runs
  before, 9 of 20 with only the first read reordered, and 0 of 20 after.
- **System libraries named by pkg-config.** The system-dependency resolver
  searched only `-L` roots, so libuv's `-lpthread -ldl -lrt -lm` could not
  resolve. glibc 2.34+ keeps only empty archives for those, in directories
  pkg-config never emits. On Linux the resolver now also searches pkg-config's
  `pc_system_libdirs` and accepts an archive there, as the linker does. This
  mirrors the existing macOS SDK fallback.
- **Two-part library versions.** zlib reports `1.3`, which the strict
  semantic-version parser rejected as an invalid manifest. The resolver now
  compares a purely numeric one- or two-part version as `x.y.0` and records it
  as reported.
- **Fixture and runner assumptions.** Two `test_rc` file tests and the profile
  runner wrote under the ignored `tmp/` directory without creating it. An FFI
  test still passed the removed `native` capability to `$ffi/open` on the
  Linux-only `libm` branch. The runner reported an empty revision and a clean
  tree when git was unavailable; it now reports both as unknown.

## Platform notes

- Building needs ncurses headers for the terminal UI. The runtime loads PCRE1
  (`libpcre3`, deprecated in Ubuntu) at startup for Nim's `std/re`.
- Ubuntu 24.04's packages are older than three genex pins: libuv 1.48
  (`genex/libuv_timer` pins 1.52.x), utf8proc 2.9 (`genex/archive` needs
  pkg-config version ≥3.1.0), and libcurl 8.5 (`genex/websocket` needs 8.11+
  for WebSocket). A deployment on that release has to supply those libraries.
- utf8proc's pkg-config version depends on its build system. The Makefile,
  which distributions use, reports the library SO version (3.2.3 for release
  2.11.3). The CMake build reports the release number (2.11.3). A
  CMake-built utf8proc therefore fails `genex/archive`'s `>=3.1.0` pin even
  when it is new enough.
- Rosetta for Linux gives every translated process descriptors 3–5 (the
  binary twice and the interpreter). The PTY test "exec child inherits no
  helper descriptors" skips when it detects Rosetta through its own descriptor
  links. On a native `linux/arm64` container on the same host, with Nim 2.2.4
  built from source, it runs and passes, so the helper does close its
  descriptors on Linux.

## Remaining

- Timing gates on native x86_64 hardware.
- Stage promotion follows each proposal's own release gates.
