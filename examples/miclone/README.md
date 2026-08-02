# Miclone

A voxel game engine with [Luanti](https://github.com/luanti-org/luanti)'s
architecture, written in Gene, whose mod language is Gene.

**Status: design plus the M0 probes. There is no game yet.** Read
[`docs/design.md`](docs/design.md) first — Part I is the direction and the
decisions, and §D2 is the constraint that shaped the rest.

The reference source is a shallow clone of upstream, not vendored here:

```sh
git clone --depth 1 https://github.com/luanti-org/luanti examples/miclone/luanti
```

---

## The M0 probes

design.md §D6 puts three probes in front of the engine, each able to kill or
reshape it. Two have run.

### §D6.2 — divergence: **PASS**, zero differing bits

Runs the exact `F64` chains mapgen depends on through both backends and
compares decomposed float bits — not printed floats, because the VM prints
`1e-7` as `0.0000001` while agreeing on every bit.

```sh
cd examples/miclone
gene run divergence                                 # the VM

gene build --target web probes/divergence.gene --out-dir dist
node tools/divergence.mjs                           # the web profile, via V8

gene run divergence | diff - <(node tools/divergence.mjs)   # no output
```

323 samples agree exactly, which is what makes §D3.1's *exact half* an
enforceable rule rather than a hope.

### §D6.3 — worldgen throughput: **FAIL by ~750x**

```sh
gene run worldgen
```

Reports per-stage cost extrapolated by exact call counts. The finding is not
that 3D noise is expensive — it is that a single message send is ~500 ns, so
512,000 nodes cannot be *written* inside a 300 ms budget whatever is written.
See design.md §D6.3 for what that changes.

### §D6.1 — render spike: not yet built

Needs the WebGL2 host bindings (design.md §D7.1). The typed-array half of that
item has landed as `(Buffer T)`.

---

## Layout

```
core/       portable Gene — compiles for the VM and the web profile
  exact.gene    exact F64 integer arithmetic and float bit comparison (§D3.1)
  noise.gene    value noise and fractal composition (§D7.5)
  mapgen.gene   terrain generation (§3)
probes/     the M0 probes; `run_*.gene` are their VM shells
tools/      the web-profile shells
docs/       design.md
```

`core/` is written in the intersection of what the VM runs and what the `web`
profile compiles. Printing is not in that intersection — `$println` is a VM
builtin and a browser has no stdout — which is why each probe is a portable
module with a shell per backend rather than one module with a conditional.
