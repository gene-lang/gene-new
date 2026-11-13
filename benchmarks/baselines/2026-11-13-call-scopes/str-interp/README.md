Why `str_interp_500k` ran 7% slower at the branch head than at `3d499e85`
(2026-11-13). Default builds, Apple M4 Pro. The slowdown is not in the
interpreter: the kernel is sensitive to which allocator cells its strings
land in, and the head leaves the heap in a different state before it runs.

`make_variants.py KERNELS_GENE OUT_DIR` writes every kernel-file variant used
below. `B` = `3d499e85`, `P` = `9c929dac` (pool), `H` = `3c3a62d0` (head),
`E1` = `H` with opStoreArg folded into opNoop's arm.

| Step | Measurement | Result |
| --- | --- | --- |
| 1 | `kernels-by-step.tsv`: 7 paired rounds, str_interp against `B` | `P` 1.01, `H` 1.07, `E1` 1.10: the new arm is not the cause |
| 2 | The kernel alone, 5 M iterations, 9 rounds | `H` 1.016 of `B`'s cycles, same instructions |
| 3 | `kNN.gene`: NN extra Str constants in the file, 5 rounds | `H` 81, 80 ms with 0 and 1; 76-78 ms with 2 to 12. `B` 75-76 ms (79 at 6) |
| 4 | Instructions for the whole file, `H`, 0 against 2 constants | 66,229 M against 66,223-66,233 M: the same |
| 5 | Gap against n, `H`, 0 against 2 constants, 7 paired rounds | +4 ms at 500 k, +19 at 2 M, +79 at 8 M: per iteration, about 6% |
| 6 | ORC's pending roots after each kernel (probe build) | 311 throughout: no cycle collection runs |
| 7 | Addresses of the loop's two string buffers (probe build) | slow layouts: two different allocator chunks; fast layouts: one chunk |
| 8 | `holes.gene` against `solid.gene`: holes within one chunk | `B` 304 against 311 ms, `H` 304 against 312: not slower, and `B` = `H` |
| 9 | `lonehole.gene` against `control.gene`: one free 32-byte cell in an otherwise full chunk | `B` 336 against 308 ms (+9.1%, 7 of 7); `H` 326 against 309 (+7.8%, 7 of 7) |
| 10 | Instructions, `B`, lone hole against control (2 M iterations) | +15 M, 7.5 per iteration, for about +55 cycles per iteration |

So: each iteration allocates one string and frees the last, and the buffers
(32-byte size class) alternate between two cells. When one of them is the
only free cell of a full chunk, Nim 2.2.12's allocator lends it to the active
chunk's free list and the loop alternates between two chunks. That costs a
few instructions and about 55 cycles per iteration. Step 9 produces it on
`B`, and without it the two builds take the same time.

Not established: which hardware effect the 55 cycles are (the instructions
are nearly the same; telling cache-set conflicts between chunk headers from
memory-ordering flushes needs performance counters). Inferred, not measured:
why the head starts the kernel with such a cell. The only change in the
kernel file is that the `inc` message no longer takes a pooled call scope,
whose two-slot buffer is in the same 32-byte class.

Ruled out on the way: the opStoreArg arm (step 1), cycle collection (step 6),
and the allocator returning an emptied chunk (that path is disabled in
2.2.12's `alloc.nim`).
