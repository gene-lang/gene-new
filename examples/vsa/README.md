# gene/vsa

Vector Symbolic Architectures as a **derived** cognitive representation.
Design: [`docs/proposals/vsa.md`](../../docs/proposals/vsa.md).

The one commitment everything else follows from:

> The Gene node is canonical. The VSA representation is derived, and never
> authoritative.

This is gate **G1** of the proposal's §11 — the MAP algebra, a deterministic
codebook, and the cross-backend fixture that keeps both honest. Nothing here
encodes a Gene node yet (that is G4/G5), and nothing learns (G6/G7).

## Layout

```
package.gene          the manifest; entry is the protocol, not a backend
src/space.gene        the VsaSpace / CleanupMemory protocols, and the guards
src/backends/map.gene MAP over bipolar ±1, the first implementation
tests/algebra.gene    the cross-backend spec — builds a report, prints nothing
tests/run_algebra.gene    VM shell:  $println
tests/web_algebra.gene    web shell: $console/log
```

## Running it

```sh
gene run algebra                                     # the VM

gene build --target web tests/web_algebra.gene --out-dir dist
node -e "import('./dist/web_algebra.mjs').then(m => m.main())"
```

**The two outputs must be byte-identical.** That is the actual test:

```sh
diff <(gene run algebra) \
     <(node -e "import('./dist/web_algebra.mjs').then(m => m.main())")
```

The shared module returns a report string and neither prints, so any difference
between the two runs is a difference between the runtimes rather than between
two harnesses.

## What the design forces, and why

Three shapes here are not the conventional ones, and each is load-bearing.

**Operations write into a caller-owned `out` and return `Nil`** (§3.3). A
dimension-8192 vector is 64 KB; a returning `bind(a, b) -> c` would allocate
64 MB to bundle a thousand observations. `out` may alias an input for the
elementwise operations and may not for `permute`, which reads an index it has
not written yet.

**Vectors are `(Buffer F64)`, not packed bits** (§3.2). `Int` lowers to `bigint`
in the web profile — roughly an order of magnitude slower — and these are the
hot vectors of the whole design. Integer arithmetic happens *inside* F64, exact
below 2^53.

**The codebook is bit-identical across backends** (§5). Atoms come from the
concept's *name*, never an interned symbol id (which is per-process encounter
order), and the hash uses only operations IEEE-754 requires to be correctly
rounded, following `examples/miclone/core/exact.gene`.

## Four backend differences this package had to work around

Recorded because each one cost a debugging cycle here, and the first two are
already known:

| | |
|---|---|
| `~ len` is `Int` on the VM, `F64` on the web | miclone §D7.12. `$to_float` bridges neither direction; `(+ 0.0 …)` bridges both. `src/space.gene`'s `buffer_len` is the second copy of that wrapper in this repo — a third would be an argument for fixing the primitive. |
| `$println` is not in the portable web stdlib | Hence the two shells. |
| whole-number F64 interpolates as `1.0` / `1` | Non-whole values agree, so this hides until a report is diffed. The spec is float-free for exactly this reason. |
| module-level `var` is rejected by the web profile | The divergence `const` exists for. The spec threads its counters through `report` instead. |

## What is measured, not asserted

The codebook's quality is a number, and a wrong one is silent — atoms that are
secretly correlated still produce plausible similarities. The first version of
`component` took the sign from bit 0 of a multiplicative hash, which is a
*linear* function of the index, and every atom came out as the same vector up to
sign: worst |similarity| between distinct atoms **0.95**, where ~0.03 was
expected at dimension 1024.

The fix was a data-dependent multiplier (an affine chain cannot decorrelate its
own index) and taking the sign from bit 16. Current behaviour, over 153 atom
pairs:

| dimension | worst \|sim\| | mean \|sim\| | expected σ = 1/√d |
|---|---|---|---|
| 256 | 0.227 | 0.048 | 0.063 |
| 1024 | 0.102 | 0.025 | 0.031 |
| 8192 | 0.054 | 0.009 | 0.011 |

The mean tracks 1/√d, which is what near-orthogonal random ±1 vectors do.
`tests/algebra.gene` asserts the property at dimension 1024 with a wide margin;
this table is the thing that would catch a slow degradation, and filling in
§9's capacity table (gate G3) is where it becomes a standing measurement.
