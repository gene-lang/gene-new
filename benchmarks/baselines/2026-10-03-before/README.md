# Before implementation

These are the three original complete core benchmark logs from the reviewed
optimization assessment, preserved before changing the harness/report format.

- Source: `74886ddee13c15dadab8ee6c08cd884618052cd8`.
- Executable SHA-256: `e5e603901fe1c8b776a2fdea718e1ab386a43ab5b0412abebd3b90f2f6309998`.
- Platform: macOS arm64, Nim 2.2.4, Apple clang 21.0.0.
- Command: `nim c -d:release --path:src --hints:off --nimcache:tmp/optimization-evidence/nimcache-core -o:tmp/optimization-evidence/bench_core benchmarks/bench_core.nim`.
- Default ORC, generated C compiled with `-O3`, no native-CPU tuning or unsafe math flags.
- Three sequential runs of one executable; no assessment compiler ran during timing.
- The generated-C fixture used SDKROOT `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` because the installed default SDK did not link with this toolchain.

Each log contains 86 measurements. They are legacy text output, not the new
JSON reporting protocol. Timings are per complete benchmark iteration;
`run` entry/exit and result handling are included. The simple arithmetic
fixture includes a builtin call, so it is not an empty-chunk control.
These runs measure run-to-run variation, not independent-build variation.
Do not derive exact dispatch or annotation costs by subtracting unrelated rows.
