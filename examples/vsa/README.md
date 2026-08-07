# gene/vsa

Vector Symbolic Architectures as a **derived** cognitive representation.
Design: [`docs/proposals/vsa.md`](../../docs/proposals/vsa.md).

The one commitment everything else follows from:

> The Gene node is canonical. The VSA representation is derived, and never
> authoritative.

Gates **G1–G3** of the proposal's §11: the MAP algebra, a deterministic
codebook, cleanup memory, and the capacity sweep that fills in §9's table.
Nothing here encodes a Gene node yet (G4/G5), and nothing learns (G6/G7).

## Layout

```
package.gene          the manifest; entry is the protocol, not a backend
src/space.gene        the VsaSpace / CleanupMemory protocols, and the guards
src/backends/map.gene MAP over bipolar ±1, the first implementation
src/memory/linear.gene    linear-scan CleanupMemory
tests/algebra.gene    G1 — the algebra, as identities
tests/cleanup.gene    G2 — recovery through binding and bundling
tests/{run,web}_*.gene    the two shells: $println / $console/log
bench/capacity.gene   G3 — §9's table. A measurement, not an assertion.
tools/check.sh        the gate: both suites, both backends, diffed
```

## Running it

```sh
tools/check.sh        # both suites on both backends, diffed — the actual gate
gene run algebra      # one suite on the VM
gene run capacity     # the §9 sweep (~2 min; not part of check.sh)
```

**The two outputs must be byte-identical.** That is the test.

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

## Seven backend differences this package had to work around

Recorded because each one cost a debugging cycle here, and only the first was
already known:

| | |
|---|---|
| `~ len` is `Int` on the VM, `F64` on the web | miclone §D7.12. `$to_float` bridges neither direction; `(+ 0.0 …)` bridges both. `src/space.gene`'s `buffer_len` is the second copy of that wrapper in this repo — a third would be an argument for fixing the primitive. |
| `$println` is not in the portable web stdlib | Hence the two shells. |
| whole-number F64 interpolates as `1.0` / `1` | Non-whole values agree, so this hides until a report is diffed. The spec is float-free for exactly this reason. |
| module-level `var` is rejected by the web profile | The divergence `const` exists for. The spec threads its counters through `report` instead. |
| `push!` returns `Void` on the web, so a `: Nil` body ending in one fails its own return check | Only on that backend. An explicit `nil` tail keeps the two agreeing. |
| the web profile emits one flat output dir keyed by basename | `src/memory/cleanup.gene` and `tests/cleanup.gene` collide. Basenames are unique package-wide. |
| a two-hop path types as `Any` | `self/keys/%i` loses the element type; binding the list to a local first keeps it, and keeps the read monomorphic. |

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
