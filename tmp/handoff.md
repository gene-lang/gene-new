# Gene native-app implementation handoff — 2026-09-24

Branch: `gene-world`. This handoff accompanies the implementation checkpoint for the eight proposals: application libraries, value operations, async I/O, network services, package distribution, native extensions, VM reliability, and the Python replacement profile. The code is a working experimental baseline, not a claim that the full native-app profile is supported. Package manifests, locks, and registry configuration use Gene data; TOML support is out of scope.

## Current implementation

| Area | Implemented and exercised | Open gate |
| --- | --- | --- |
| Application libraries | APP-1 POSIX paths, CSV, and synchronous walk. APP-2 streaming CSV. APP-3 temporal arithmetic and packaged IANA 2026d `genex/tzdb`. APP-4 gzip streams and ZIP extraction in `genex/archive`. | APP-2–4 remain experimental; Linux runtime qualification. |
| Value operations | VAL-1–3 sealed native VM witnesses for equality, hash, indexed access, and ordering, with conformance/lifetime cases. | Cross-backend audit and promotion. |
| Async I/O | IO-1–3 lifecycle budgets, structured cleanup, file/pipe/TCP adapters, cancellation and fairness checks. | Linux, sustained-service, and remaining release gates. |
| Network services | NET-1 owned reusable HTTP Client with bounded buffered/streamed traffic. NET-2 streamed request/response server and proxy fixture. NET-3 direct TLS with `genex/tls` and `Server.reload_tls`. | Generic exclusive borrowing for caller-initiated Client reads, rare service heartbeat stall, Linux and sustained qualification. |
| Package distribution | PKG-1 local install. PKG-2 source-built C/shared/static artifacts and native variant checks. PKG-3 signed release index, Ed25519/OpenSSL adapter, bounded curl HTTPS transport, online resolution, offline signature replay, and staged publishing client. | Cross-host native-artifact policy, deployable registry service, Linux runtime. |
| Native extensions | v5 ingress and owned subscription API plus installed `genex/libuv_timer` package with 10,000 create/notify/close lifetimes. | Linux and broader native-extension qualification. |
| VM reliability | VM-0 evidence ledger and counters; VM-1 ownership/error repairs; VM-2 scalar-module `this_mod` retirement after last owner; VM-3 fixed-vocabulary RC batch runner. | Rich Type/protocol/impl module generations still retain about 15 managed Values per release; sustained-service and Linux lifetime evidence. |
| Python replacement profile | Executable five-workload manifest/runner and macOS arm64 audit. | SCRIPT passes locally; CLI, SERVICE, DATA, and LIFETIME are probe passes but cannot be promoted while their stage gates remain experimental/planned. |

The detailed stage ledger is [`docs/profiles/native-app.md`](../docs/profiles/native-app.md). The dated audit is [`docs/profiles/native-app-2026-09-24.md`](../docs/profiles/native-app-2026-09-24.md), and the VM ownership inventory is [`tests/lifetime/LEDGER.md`](../tests/lifetime/LEDGER.md). Individual contracts and source/fixture locations are linked from those files and `docs/spec/README.md`.

## Latest evidence and limits

- `nimble test`, `nimble spec`, `nimble leakcheck`, and `nimble threadcheck` passed after the Protocol boxed-owner and impl Value-edge changes. The full test run ended with all 39 wasm ABI cases passing.
- The latest RC-enabled four-child lifetime run held 881 (eval/failure), 822 (witnesses), 794 (cancelled Tasks), and 820 (scalar module generations) managed Values at warm-up and at 1, 100, 1,000, and 10,000 iterations. Retained module/function/instance controls remained usable. The test-only binary SHA-256 was `08930b55a045b2133e1880f375ee895b1879f5348378bdc022517532d27d44f1`. Run `rtk proxy python3 tests/profiles/native-app/run.py --probe-blocked --workload lifetime` to reproduce.
- A released Type/protocol/impl module still retains about 15 managed Values per generation. A temporary trace (removed from source) accounted for Protocol 4/4, Type 5/5, instance Node 2/2, and impl method Function 2/2 scope-owned boxed edges. An escaped Nim `Scope` reference remains unmodeled. The scalar-only `this_mod` self-edge guard deliberately does not clear that richer graph.
- The full macOS arm64 audit passed SCRIPT and returned probe passes for CLI, SERVICE, DATA, and LIFETIME. Four current release-binary SERVICE runs completed 1,800 HTTPS requests at 30/s with p95 14.57–16.83 ms and maximum heartbeat gaps of 52–63 ms. An earlier repeat had a 336 ms gap against a 250 ms gate, so fairness is not yet qualified. The DATA probe processed 10/100 MiB CSV with a 66,570-byte parser payload peak at both sizes.
- Linux x86_64 runtime qualification was unavailable on this host: Docker daemon was stopped, and there was no Podman or QEMU runner. MacOS results do not promote Linux gates. An installed-app CLI fixture pins `MacOSX26.5.sdk` because the host default SDK could not link its C library with the installed linker.

## Recommended continuation

1. Finish VM-2 mixed module ownership: identify the surviving Nim `Scope`/namespace root in a released Type/protocol/impl generation, preserve retained function and instance behavior, and prove a flat 10,000-generation RC run. Extend VM-3 with partial-selection failure and cancellation, then a single-process sustained-service heap slope.
2. Close NET-1 exclusive borrowing and investigate the intermittent service heartbeat stall without changing the 250 ms gate. Re-run the full profile on the resulting binary.
3. Run the suite and profile on Linux x86_64, including installed `genex/*` packages, hosted registry, TLS, and native v5 ingress. Resolve platform-specific failures, then update stage claims only where evidence meets each proposal's release criteria.
4. Finish cross-host native-artifact policy and a deployable signed registry service for PKG-2/3; audit value operations across supported backends and promote experimental APP/IO/NET/NATIVE stages only after their conformance gates pass.

Use `rtk` for every shell command (`rtk proxy <cmd>` for unfiltered output). Run the executable profile with `rtk proxy python3 tests/profiles/native-app/run.py --gene /path/to/gene --probe-blocked`; reports are written beneath ignored `tmp/native-app-profile/`. `--require-supported` must remain failing until all required stage gates are promoted. Do not infer that a `probe_pass` is a supported workload.

The separate concurrent edits in `docs/proposals/world.md`, `examples/life/**`, and `examples/world/**` are outside this checkpoint and were deliberately left unstaged.
