# Native-app qualification audit — 2026-09-24

This is a macOS arm64 probe report, not a native-app release claim. The audit
ran on a dirty worktree at HEAD `b19bec51291b6f181d218a002a4f94b4dfea3e61`.
The release Gene binary SHA-256 was
`d2eec8b1338fd972b19d55f0c3f01d036886c083a926b0e7e15b699965b9405a`.
Run the same fixture with:

```sh
rtk proxy python3 tests/profiles/native-app/run.py \
  --gene /path/to/current/gene --probe-blocked
```

| Workload | Result | Evidence | Required stages still incomplete |
| --- | --- | --- | --- |
| SCRIPT | pass | Golden JSON/CSV/tree/process/API result; bad CSV, API error, and child failure produced typed errors without publishing output. | Linux platform gate. |
| CLI | probe pass | Source-built C binding and locked resource ran after offline install from another cwd; update changed generation and a failed update retained the previous one. Pinned macOS SDK: `MacOSX26.5.sdk`. | PKG-2 promotion, Linux and cross-host native-artifact policy. |
| SERVICE | probe pass | 1,800 HTTPS requests at 30/s; streamed upload/response, SQLite, slow-peer fairness, trust/forwarded-header checks, graceful stop with zero tracked I/O resources and leases. | IO-3, NET-1/2, VM-3, Linux. |
| DATA | probe pass | 10/100 MiB CSV produced identical 32-group results; typed group and record faults. Parser peak was 66,570 bytes at both sizes and retained 13 bytes at EOF; upstream retained zero bytes at EOF. | APP-2, VAL-3, IO-2 promotion and Linux. |
| LIFETIME | probe pass | Test-only ORC/RC binary held 857 managed values after warm-up and every 1/100/1,000/10,000 eval/closure/cell/failure batch; all seven managed-class counts matched exactly, with zero native roots and I/O leases. A later witness child held 822 values across the same batches while releasing selected ValueEq/Hash/Order Types. | Other mixed ownership, module generations, cancellation, sustained-service retention, VM-3, Linux. |

The full audit's SERVICE run had p95 14.83 ms, p99 47.92 ms, a 59 ms maximum
host-loop heartbeat gap, and 19,628,032 bytes sampled peak RSS. Three other
quiet-host repeats of the same current release binary also passed:

| Repeat | p95 ms | p99 ms | Max heartbeat gap ms | Peak RSS bytes |
| --- | ---: | ---: | ---: | ---: |
| 1 | 15.69 | 49.99 | 54 | 19,628,032 |
| 2 | 16.83 | 50.97 | 63 | 19,628,032 |
| 3 | 14.57 | 49.10 | 52 | 19,628,032 |
| Full audit | 14.83 | 47.92 | 59 | 19,628,032 |

An earlier service repeat observed a 336 ms heartbeat gap against the 250 ms
gate. These passing repeats do not erase that miss or prove a flat retained
heap within one sustained service process. The lifetime probe covers a fixed,
bounded eval/closure/cell/self-cycle/failure vocabulary; `cycle_candidates`
remains unavailable and no broader cycle-collector claim follows from its
flat counts. The instrumented Nim 2.2.4 binary used `-d:geneRcStats --mm:orc`
with the pinned SDK and had SHA-256
`30d2ae64d55784c1deaefbd1487f9501d60c8d8ca08692740ed2eed463b04ffa`.
The separate witness child was added after the initial full audit; its
instrumented binary hash was the same and its 1/100/1,000/10,000 checkpoints
all held 822 managed values. Its retained Type still executed after the final
batch. The eval/closure/cell fixture was then expanded with a failed
ValueEq impl and a whole-form compile failure; its warm and all four later
checkpoints held 881 managed values with identical per-class counts. Neither
process tests every Type/witness ownership graph. A third child subsequently
cancelled parked Tasks after Type/ValueEq impl creation; its warm and
1/100/1,000/10,000 checkpoints all held 794 managed values, identical
per-class counts, and zero root Tasks. Cancellation during partially prepared
selection remains untested.
After a guarded module self-edge repair, a fourth child committed and released
a fixed scalar-only sandbox module in the same 1/100/1,000/10,000 batches.
Every checkpoint held 820 managed values; generation records, module cache,
compile artifact, and impl counts were flat. A retained function that reads
`this_mod` after release still executed. Later function-only and instance/Type
controls passed without retaining the Module value. The corresponding Type/protocol/impl
module remains a known gap, retaining about 15 managed values per release.
The instrumented binary for this later run had SHA-256
`b0e12f9e617beca3cede5e80571d7c56cb4c2733826b3e0638288e6b6449aa14`.
The final profile-runner repeat after widening the scalar guard to strings
again held 820 values at every checkpoint. Its instrumented binary SHA-256
was `af736accb6dd03290c0ef601bc22be4fb10b98f360943b0f7ca02d8e90382aa2`.
After the final slot-edge guard, the four-child lifetime harness passed again:
warm/final counts were 881 (eval/failure), 822 (witnesses), 794 (cancelled
Tasks), and 820 (scalar modules). The retained-module control passed. That
instrumented binary SHA-256 was
`1a31f290a26142888fe6a6ed1a3f1f1f8a91aa6390e5386ca38fda46556106b5`.
After adding Protocol boxed-owner accounting and the missing impl Value edges,
the same four-child harness passed with those same counts. Its instrumented
binary SHA-256 was
`08930b55a045b2133e1880f375ee895b1879f5348378bdc022517532d27d44f1`.
The richer Type/protocol/impl generation still retains about 15 values per
release. A test-only edge trace accounted for its Protocol 4/4, Type 5/5,
instance Node 2/2, and method Function 2/2 boxed owners; the remaining
unmodeled edge is a possible escaped Nim Scope reference, so VM-2 stays open.
A later checkpoint trace of a released generation observed `Item` Type at
6 boxed owners with only 4 reachable from the root Scope, and the `item`
instance Node at 3 owners with 2 root-owned. This is a different quiescent
point from the earlier edge trace and leaves extra boxed owners to locate;
the Nim Scope edge is still only a hypothesis. The temporary trace code was
removed after recording these counts.
After expanding the Scope Value-edge inventory, the four-child lifetime
runner again returned `probe_pass` with the same warm/final counts: 881,
822, 794, and 820. All retained module/function/instance controls passed.
The updated instrumented binary SHA-256 was
`dc089ad9bbdd0ba5bb40a07b6be4cb7d7a6293ee10a62f24f0dc112678ef8f26`.
This does not qualify the richer generation.

`nimble test`, `nimble spec`, and `nimble leakcheck` passed. Linux x86_64
runtime qualification was unavailable on this host: the Docker daemon was
not running, and no Podman or QEMU runner was installed. The native-app
profile remains incomplete; the stage ledger in
[native-app.md](native-app.md) and the executable
[profile.gene](../../tests/profiles/native-app/profile.gene) retain the
experimental and planned statuses.
