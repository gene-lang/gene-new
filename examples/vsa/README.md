# gene/vsa

Vector Symbolic Architectures as a **derived** cognitive representation.
Design: [`docs/proposals/vsa.md`](../../docs/proposals/vsa.md).

The one commitment everything else follows from:

> The Gene node is canonical. The VSA representation is derived, and never
> authoritative.

Gates **G1–G5 and G7** of the proposal's §11 are shipped; **G4** is half
answered and **G6 is blocked** — no Gene Intelligence `Memory` protocol exists
in this repo to implement against. Nothing here learns.

## Layout

```
package.gene          the manifest; entry is the protocol, not a backend
src/space.gene        the VsaSpace / CleanupMemory protocols, and the guards
src/backends/map.gene MAP over bipolar ±1, the first implementation
src/codebook.gene     §5.1 interned atoms — the cache the codecs read through
src/memory/linear.gene    linear-scan CleanupMemory
src/codec/summary.gene    §6.2 reference-plus-summary — portable
src/codec/scalar.gene     §6.5 thermometer code for continuous values
src/codec/node.gene       §6.1/§6.3 node walking — **VM-only**
tests/algebra.gene    G1 — the algebra, as identities
tests/cleanup.gene    G2 — recovery through binding and bundling
tests/codec.gene      §6.2/§6.5/§7 and G5 — codec and index
tests/node.gene       §6.1/§6.3/§6.4 and G4/G7 — VM-only, no web shell
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

That is a *memory* argument and it does not extend to time. At D=512 a fresh
`($buffer F64 512)` costs 4.5 us and clearing one in a Gene loop costs 267 us,
because the allocator returns zeroed memory and the loop does not. So reuse
pays only when the next writer overwrites every component; `encode_value` in
`src/codec/node.gene` accumulates instead, and is the one function here that
returns a buffer rather than filling a caller's.

**Atoms are interned, and the codecs borrow them** (§5.1). An atom is a pure
function of its name, and generating it was 95% of every encode — the same
eight names regenerated 400 times in the G4 sweep. `atom_ref` hands back the
codebook's own buffer for the callers that only read it, which is all of them;
`atom_into` copies for callers that own an output. Borrowing is the hazard
`verify_intact` exists for, and both spec suites assert it after a round trip.

**Vectors are `(Buffer F64)`, not packed bits** (§3.2). `Int` lowers to `bigint`
in the web profile — roughly an order of magnitude slower — and these are the
hot vectors of the whole design. Integer arithmetic happens *inside* F64, exact
below 2^53.

**The codebook is bit-identical across backends** (§5). Atoms come from the
concept's *name*, never an interned symbol id (which is per-process encounter
order), and the hash uses only operations IEEE-754 requires to be correctly
rounded, following `examples/miclone/core/exact.gene`.

## Backend differences this package had to work around

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
| **the mutable `List` surface is disjoint** | The VM has `set!`/`assoc`/`first`/`last`/`contains?` and no `pop!` or `clear!`; the web profile has `pop!` and `clear!` and no `set!`. **Portably a list can only be pushed to and sized.** `src/codebook.gene`'s slot table is append-only for this reason — neither a slot rewrite nor a remove-and-replace exists on both. |
| a prop cannot be reassigned on the web | `(set self/field v)` is "web set expects a bare binding and value". Combined with the row above, a growable field has to be the last element of a push-only list. |
| a selector index must be a variable there | `xs/%0` is "unresolved web binding: 0"; `(var i 0.0)` then `xs/%i` is fine. Every existing loop indexed by a variable, so this stayed hidden until a table wanted slot zero. |
| **a node's props cannot be enumerated** | `Map` has `get`/`size` and no `keys`/`values`/`entries`/`pairs`; `for` refuses the `Any` a projection types as. §6.1 normalization is therefore VM-only. Note `Map` is also missing `put!`, so it cannot back a memo either. |
| **`match` type patterns are miscompiled** | `(when (s : Str) …)` emits a *node literal* pattern — head `s`, body `[: Str]` — so it matches a 2-element node and otherwise falls silently to `else`. VM says `"str"`, web says `"other"`, no diagnostic either side. This is why the node walk is VM-only. |

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

## What it costs

Per operation at D=1024, and the reason `src/codebook.gene` exists:

| op | ms | | op | ms |
|---|---|---|---|---|
| `atom`, generated | 8.92 | | `bundle_into` | 0.59 |
| `permute` | 1.07 | | `similarity` | 0.53 |
| `bind` | 0.60 | | `normalize` | 0.53 |

`atom` is 15× everything else and was 95% of an encode. Interning it (§5.1)
moved the G4 encode from **56.0 to 4.85 ms**; later VM work took it to
**3.41 ms — 16.4× the original**. Across the same span `gene run codec` went
**7.9 → 1.2 s** and the §9 sweep **130 → 33 s**, the latter also because
`bench/capacity.gene` stopped rebuilding its 256-atom codebook once per load
row instead of once per dimension. Every reported number is byte-identical
throughout; none of this changes what is computed, only how often.

Two things measured as *not* worth changing. Protocol dispatch costs 5%: a
hand-inlined `bind` with no `VsaSpace` send and no `check_len` runs 0.57 ms
against the real one's 0.60, so §4.2's indirection and §3.1.1's guard are both
free. What is left is element access — net of loop overhead, about 273 ns per
`Buffer/set!` and 177 ns per `get`, against 106 ns for a whole function call.
Those were 441/298/160 ns before the VM work; the remaining headroom is still
in the VM rather than in this package, but it is now interpreter dispatch
rather than the refcount and tag-decode traffic that used to dominate it.

Where a whole buffer is being written, none of the above applies — use
`fill!` and `copy_from!`, which are 348× and 150× the equivalent loop because
they check the element type once instead of once per component.
