# Remainder reductions

Gene's `//` is a truncated remainder. A floored reduction can be replaced
without changing these application results only after checking the operands:
finite, non-negative integral F64 dividends below 2^53, positive integral
divisors, and bounded intermediates. General F64 floor formulas are not
equivalent to `fmod`; random agreement does not establish an input contract.

## Migrated operations

| Operation | Caller and input bounds |
| --- | --- |
| `abm/gcd` | `walk_stride` supplies floored integral strides and the world's integral node count. The server's 12×4×12 blocks contain 2,359,296 nodes; the probe uses 2,048. The Euclidean loop executes only while its divisor is positive, and each remainder decreases it. The zero-divisor probe exits before performing a reduction. |
| `protocol/input_flag?` | `decode_input` reads unsigned bytes (0–255); the flags are 1, 2, and 4, so divisors are 2, 4, and 8. The protocol probe also covers all byte values. |
| `texture/tile_col` | `paint` walks integral registry slots 0–63. `add_tile` enforces `max_tiles = 64`; the divisor is the constant 8. |
| `world/index_x`, `world/index_y` | The world probe enumerates all block coordinates 0–15, yielding indices 0–4,095. Divisors are the constants 16 and 256. |
| `server/answer_blocks` (two reductions) | `decode_request_blocks` supplies unsigned 16-bit integers. The loop bounds its index below the fixed 576-block total, so executed indices are 0–575. Division by `span_x = 12` yields integral `rest` in 0–47; `span_y = 4`. Both constants convert exactly to F64. Out-of-range starting indices execute no reductions. |

These seven sites use `//`. The scalar values and intermediate integer
products stay exactly representable within the audited domains.

## Retained formulas

The two `sample_index` reductions and the reductions in `sample_x` and
`sample_y` stay together as the existing sampling pipeline. The server adds
900 to its `step` Cell every tick without resetting or bounding it. Although
the module bounds `total²` for its intended permutation, that does not bound
the incoming step or independently prove the old pipeline's outputs for all
counter values. Changing this pipeline needs a separate counter/input contract;
its passing finite probe is not a proof of that contract.

`exact/wrap32` accepts negative inputs intentionally and remains in the
AOT-lowerable kernel set. It retains its power-of-two floor formula because
`//` has different negative-input behavior and does not currently lower to C.
`field/lattice_origin` rounds down to a multiple, and the mesh expressions
extract a fractional part or divide down; they are not remainder migrations.

## Verification

Use the [cross-backend specs and headless harnesses](../README.md#cross-backend-specs)
to compare VM and web results and compare both with captured pre-change output.
The native numeric specs additionally compare F64 bits over 10,000 deterministic
integral pairs plus boundary cases. Terrain composition summaries must stay
unchanged, and worldgen timing comparisons use the same optimized compiler on
an idle machine. Timing and qualification evidence are recorded separately
from this input-domain audit.
