# Vector Symbolic Architectures as a derived cognitive representation

**Status: implemented as `examples/vsa` (package `gene/vsa`). Gates G1–G5 and
G7 are shipped, G4 is partly answered, G6 is blocked on a protocol that does
not exist in this repo. See §11 for what each gate actually produced, including
where the measurements contradicted the design.**

Gene's node — `head + props + body + meta` — is an unusually general symbolic
representation, and it is exact. Exactness is what makes it good for programs,
data, rules, and queries, and it is also what makes similarity, associative
recall, and superposition awkward: two nodes are equal or they are not, an index
has to be built by hand, and representing "one of these forty things" means
holding forty things.

Vector Symbolic Architectures (VSA / hyperdimensional computing) trade the other
way. Everything is a vector in one high-dimensional space, composition is
algebra — binding makes things dissimilar, bundling makes them similar — and
similarity, partial match, and superposition are primitive. What is lost is
exact recovery.

This proposal takes both, with one commitment that decides everything else:

> **The Gene node is canonical. The VSA representation is derived, and never
> authoritative.**

Nothing here changes Gene node semantics, the value layer, or the compiler. The
first implementation is a Gene-level library and costs zero wasm payload.

---

## 1. What already runs

`tmp/intelligence.md` §4.2 contains a working MAP substrate written in Gene —
role binding, cosine similarity, and a state-update step — verified on the VM
and the web profile. This proposal is written on top of it rather than beside
it, and the shape of §3 and §4 comes from what that code had to do to run on
both backends, not from the VSA literature's usual signatures.

Re-verified while writing this document, at `dim = 8`:

| check | result |
|---|---|
| MAP bind is self-inverse | `sim(a, a) = 1.0`, `sim(a, -a) = -1.0` |
| deterministic atoms agree across backends | VM and emitted JS produce the same vector |
| web profile storage | `Float64Array`, zero `BigInt` |
| emitted inner loop | `out[i] = a[i] * b[i]` |

That prototype has since been superseded by `examples/vsa`, which is what §11's
gates were run against. A learning rule is still unwritten — nothing here
learns.

---

## 2. Responsibilities

```text
Gene node                      VSA vector
---------                      ----------
exact                          approximate
inspectable, editable          opaque, distributed
executable                     associative
versionable                    superposable
arbitrary structure            fixed dimension
```

Use the Gene tree for exact structure, execution, querying, verification,
capabilities, and persistence. Use the VSA representation for associative
recall, similarity, partial match, superposition, and candidate generation.

The pairing that makes this productive is **propose with VSA, verify with
Gene**: approximate retrieval narrows a large space cheaply, and exact Gene code
decides. That is the only mode in which an approximate representation can be
trusted in a system that also has to be correct.

---

## 3. Representation

### 3.1 A hypervector is a `(Buffer F64)`

Not a new `Value` kind. `Value` is NaN-boxed and `sizeof(Value) ==
sizeof(uint64)` is an enforced invariant; a dimension-8192 vector is 64 KB and
is necessarily a handle to a heap object. `Buffer` is already that object, on
both backends, with `~ get`, `~ set!`, and `~ len`, and it needs no value-layer
change — which is why the prototype already runs.

### 3.1.1 Dimension is not in the type, so every public op must check it

`(Buffer F64)` says nothing about length. A space carries its own `dimension`,
and a caller can hand it a buffer of the wrong size.

The two backends now agree about what that does — **an out-of-range write raises
on both, and a negative index counts from the end on both.** They did not when
this document was first written; specifying this library is what surfaced the
divergence, and it was fixed in the web profile rather than papered over here
(`docs/web-profile.md`, "Indexing"; fixtures `index.*`).

What agreement does *not* buy is detection, because the remaining behavior is
the one the VM has always had:

> A read past either end yields `void`. It does not raise.

So a caller who passes a dimension-4096 buffer to a dimension-8192 space gets
`void` for every component past 4096 — on both backends, identically, and
silently. Cosine similarity over that is a number, and it is meaningless. The
failure is quiet, uniform, and produces plausible output, which is the worst
combination available.

`examples/miclone` gets away with an unchecked packed-array discipline because
one module owns both ends of every buffer. Here buffers cross caller boundaries
by design.

**Therefore: every public operation validates `(b ~ len)` against the space's
dimension before touching a component, and raises naming both sizes.** The cost
is one comparison per buffer per op, against 8192 multiplies — unmeasurable. The
check belongs at the public boundary only; internal per-component loops stay
bare.

A `(Vector F64 N)` type carrying its length would make this static, and would be
strictly better. It does not exist, and proposing it is a value-layer change
this document deliberately does not make. If it ever arrives, this check becomes
redundant and should be deleted.

### 3.1.2 What specifying this found, and where it was fixed

Writing §3.1.1 turned up a bug, and it was not VSA's. It was **a `Buffer` and
path indexing divergence between the VM and the web profile, affecting every
Gene program that indexes anything** — `examples/miclone` packs its ABM,
formspec, and mesh state into `(Buffer F32)` and was subject to all of it.

Recorded here because it is the clearest example of why this proposal keeps
insisting on cross-backend fixtures: the divergence sat in the primitive under
every loop in the design, and nothing in the existing suite noticed. What the
profile did, from source the VM accepted:

| identical source | VM | web, before |
|---|---|---|
| `xs/-1` on a 3-element list | `30` | `undefined` |
| `(b ~ set! 3 42.0)` then `(b ~ get -1)` | `42.0` | `NaN` |
| `(b ~ set! -1 9.0)` then `(b ~ get 3)` | `9.0` | `0` — the write vanished |
| `(b ~ set! 9 v)` on a 3-element buffer | raises | silently discarded |

Negative indexing is documented Gene semantics — `design.md` §1/§2 spell
`users/-1/name` as an index segment — and the VM applies it to every container
through `readIndex`/`updateIndex`. JS has no such rule: `a[-1]` reads
`undefined` and *writes* an expando the array never sees. Both sides returned a
plausible number and neither raised.

**Fixed in the web profile**, not worked around here. Both halves of the VM's
rule are now emitted: negative counts from the end, out of range raises with the
same message the VM produces. Five cross-backend fixtures (`index.*`) and two
spec tests pin it.

It was not free. Path indexing cost nothing, but Buffer access is the client's
hot loop, and matching the VM there costs **+22% on miclone's meshing benchmark**
(0.249 → 0.305 ms/chunk, still inside `design.md` §D6.1's 8 ms budget). That was
taken deliberately: a backend-dependent index is the failure this profile exists
to prevent, and the alternative was leaving a silent wrong answer in the
primitive that §3.3's whole calling convention is built on.

### 3.2 Element type is F64, and packed bits are not an option yet

The obvious storage for a bipolar backend is one bit or one byte per component.
In the web profile that is a trap: **`Int` lowers to `bigint`**
(`transpile.md` §4.5), which `examples/miclone/core/exact.gene` measures as
"roughly an order of magnitude slower", and integer-typed buffer reads measured
9–13.5× slower than `F32` in the same profile. VSA vectors are the hot data of
this whole design — the worst place to pay it.

So a bipolar space stores ±1 **as floats**, and integer arithmetic happens
*inside* F64, which is exact below 2^53. The emitted web code is a
`Float64Array` and the inner loop is a plain multiply.

Packed-bit storage can return later as a VM-only optimization behind the same
protocol, gated. It cannot be the reference representation, because a
representation that is fast on one backend and slow on the other reintroduces
exactly the split this design exists to avoid.

`F32` halves the memory and is a reasonable second space once something needs
it. It is not the default only because the prototype and the exactness argument
are both in F64; if measurement prefers `F32`, take it.

### 3.3 Operations write into a caller-owned buffer

**This is the most important API decision and the one most likely to be
reverted by someone reading a VSA paper.** The natural signature is
`bind(a, b) → c`. Gene should not use it on the hot path.

Returning a vector allocates 64 KB per operation. Bundling a thousand
observations would allocate 64 MB of garbage to produce one result. Neither
backend has a cheap intermediate — the web profile's tuple is an object and the
VM's is a heap value — which is the same reason
`examples/miclone/core/raycast.gene` writes into caller-provided buffers rather
than returning records.

So the primitive form is:

```gene
(fn bind_into [a : (Buffer F64) b : (Buffer F64) out : (Buffer F64)] : Nil
  (var i 0.0)
  (while (< i dim)
    (out ~ set! i (* (a ~ get i) (b ~ get i)))
    (set i (+ i 1.0))))
```

A returning convenience layer may exist for scripting and documentation, but
**the buffer-writing form is the semantic reference** and the one every other
part of the library is written against. One word, one mechanism.

Callers that need a temporary pass a scratch buffer. A space should offer a
small pool rather than making every caller invent one.

### 3.3.1 Output aliasing

Every operation takes an `out` buffer, including the ones that look like they
want to mutate in place — `normalize` especially. Uniformity is worth more than
saving a parameter, and the alternative is an API where some operations write
their argument and others do not, which a caller cannot keep straight.

In-place is then not a second signature but an **aliasing rule**:

> For every **elementwise** operation — `bind`, `unbind`, `bundle_into`,
> `normalize` — `out` may alias an input. `(space ~ bind a b a)` is legal and
> writes into `a`.
>
> `permute` is **not** elementwise: it is a cyclic shift, and aliasing `out`
> with its input corrupts the result. It must be given a distinct buffer, and it
> should raise if handed the same one.

This matters directly for `bundle_into`. A caller accumulating a stream keeps
the raw sum, and normalizes into a *separate* buffer when it wants to read the
result — so accumulation can continue afterward. Normalizing the accumulator in
place is still available by aliasing, but it is now a thing the caller chose
rather than something the API did to them. Bundling is addition followed by
optional thresholding to ±1, and thresholding is lossy; which buffer absorbs
that loss is the caller's decision.

---

## 4. The algebra

### 4.1 MAP first

Start with **MAP** (Multiply-Add-Permute) over bipolar ±1 vectors:

- **bind** is elementwise multiplication;
- **bundle** is elementwise addition, optionally re-normalized to ±1;
- **permute** is a cyclic shift;
- **similarity** is cosine.

The decisive property is that **binding is its own inverse** on ±1 vectors:
`a * a = 1` componentwise, so `unbind` *is* `bind`. There is no circular
correlation, no FFT, and no second code path. Verified above:
`sim(a, a) = 1.0` and `sim(a, -a) = -1.0`.

**That claim is about `bind`/`unbind` only, not about the algebra.** `permute`
is a separate operation with a separate inverse (shift by `-k`), it is not
elementwise (§3.3.1), and a composite built with permutation carries shift
bookkeeping that unbinding does not undo for free. The saving over HRR is one
specific one: MAP needs no correlation machinery to invert a binding.

HRR/FHRR is better studied for deep recursive structure and should arrive as a
second backend behind the same protocol, once there is a workload that measures
worse under MAP. FHRR needs complex arithmetic, which is a real numeric-support
question and not one to answer speculatively.

The language must not depend on the choice. That is what §4.2 is for.

### 4.2 Protocols

Message declarations, `self` implicit — it is never in the parameter vector
(`design.md` §10). Sends are `(receiver ~ msg args…)`, or
`(receiver ~ Protocol:msg args…)` when the qualifier is needed.

```gene
(protocol VsaSpace
  (message dimension [] : F64)
  (message atom [key : Str out : (Buffer F64)] : Nil)
  (message bind [a : (Buffer F64) b : (Buffer F64) out : (Buffer F64)] : Nil)
  (message unbind [composite : (Buffer F64) role : (Buffer F64)
                   out : (Buffer F64)] : Nil)
  (message bundle_into [v : (Buffer F64) acc : (Buffer F64)] : Nil)
  (message permute [v : (Buffer F64) shift : F64 out : (Buffer F64)] : Nil)
  (message similarity [a : (Buffer F64) b : (Buffer F64)] : F64)
  (message normalize [v : (Buffer F64) out : (Buffer F64)] : Nil))
```

`bundle_into` accumulates one vector into an accumulator rather than taking a
list, so superposing a stream costs no list and no intermediate.

```gene
(protocol CleanupMemory
  (message put [key : Str v : (Buffer F64)] : Nil)
  (message nearest [v : (Buffer F64) limit : F64 min_similarity : F64] : List))

(protocol VsaCodec
  (message encode [value : Any out : (Buffer F64)] : Nil)
  (message decode [v : (Buffer F64) pattern : Any] : Any))

(protocol VsaScalarEncoder
  (message encode_number [x : F64 out : (Buffer F64)] : Nil)
  (message decode_number [v : (Buffer F64)] : F64))
```

Three protocols, deliberately: the algebra, the memory, and the Gene-semantics
codec are separate concerns with separate implementations.

A protocol send costs on the order of a Gene call. That is irrelevant here
because one send covers a whole vector — 8192 multiplies amortize it — but it
does mean **no protocol send belongs inside a per-component loop.**

---

## 5. Atoms

Every atomic Gene value that participates needs a stable vector. Generate it
from a hash rather than storing a codebook entry per symbol.

Two requirements, and the second is the one usually missed.

**Deterministic across processes.** Hash the symbol's *name*, never its interned
id. Gene interns symbols, and it is tempting to treat the id as a canonical
number — but `PropEntry.keyId` is an `int32` assigned in encounter order within
a process. It is stable within a run and meaningless across runs, machines, and
backends. Hashing it yields a codebook that silently differs between two
processes that agree on every symbol.

**Bit-identical across backends.** If the VM and the web profile are ever to
share a codebook, atom generation must produce the same bits on the interpreter
and on V8. `examples/miclone/core/exact.gene` already carries this discipline:
only operations IEEE-754 requires to be correctly rounded may appear — `+ - *
/`, `sqrt`, comparisons, `floor` — because two conforming runtimes are entitled
to disagree in the last place on `sin`, `cos`, `pow`, `exp`, `log`, and `atan2`.

An atom generator therefore does integer arithmetic inside F64:

```gene
(fn hash_step [h : F64 k : F64] : F64
  (var x (+ (* h 31.0) k))
  (- x (* ($math/floor (/ x 2147483647.0)) 2147483647.0)))

(fn bipolar [seed : F64 i : F64] : F64
  (var h (hash_step (hash_step 2166136261.0 seed) i))
  (if (< (- h (* ($math/floor (/ h 2.0)) 2.0)) 1.0) 1.0 -1.0))
```

Verified identical on the VM and in emitted JS.

**Symbol identity and semantic similarity are different things.** `car` and
`truck` get unrelated vectors. Do not make lexically or semantically related
symbols similar by construction; that is a learned property (§13.3), and baking
it into atom generation makes the codebook untestable.

---

## 6. Encoding Gene values

### 6.1 Normalization

VSA wants a uniform relational structure, where a property name is an ordinary
concept. Gene's props are structurally special, so a codec lowers them:

```gene
(person ^name "Alice" ^age 30)
```

normalizes to

```gene
(person (prop name "Alice") (prop age 30))
```

which preserves the fact that the relation *was* a property, and so is
mechanically reversible. Props stay native to Gene; only the codec sees the
lowered form. A useful accident of the value layer: prop keys are already
interned names, so the key of every lowered `prop` is exactly the kind of atom
§5 generates.

An optimized direct-property codec (binding the key atom to the value atom, with
no `prop` head) is permitted, but the relational codec is the semantic
reference, and a direct codec has to demonstrate equivalent behavior on the
target workload before replacing it. §11's gate G4 states the criterion.

### 6.2 The default codec is reference-plus-summary

**This is the recommendation most likely to be skipped, and it is the one that
keeps the design honest.** For anything large, mutable, or deeper than a couple
of levels, do not encode the structure into the vector. Encode a stable ID and a
shallow semantic summary, and keep the exact node in the Gene store:

```text
exact Gene node  ←→  stable id  ←→  VSA vector
```

Retrieval returns likely IDs; Gene returns the exact node. This is the pattern
that survives contact with real data, and it makes the capacity question (§9)
tractable, because what gets superposed is a bounded summary rather than an
unbounded tree.

### 6.3 Recursive encoding, bounded

Within a level, encode structurally: bind each child to a positional role and
bundle.

```text
E(prop name "Alice")
  = bind(HEAD, E(prop))
  ⊕ bind(POS_0, E(name))
  ⊕ bind(POS_1, E("Alice"))
```

Positions may be explicit role atoms or generated as `permute(POS, i)`. Expose
logical positions in the API; let the backend choose.

**Recursion is bounded by default.** Every nesting level costs signal, so a
codec takes a depth limit and, below it, falls back to §6.2 — embedding a
reference rather than the substructure. **The default is 3**, measured by gate
G3: payload similarity is 71 / 58 / 50 / 44% at depths 1–4, and the decay is
*independent of dimension* (§9), so this is a structural limit rather than one a
bigger space fixes.

Deep navigation by repeated unbinding is not pointer traversal and must not be
presented as such. For deep symbolic access, use the Gene tree.

### 6.4 Metadata

Exclude source and debug metadata by default: it does not participate in
semantic equality and would consume capacity for nothing.

The rule is "exclude source/debug meta", not "exclude meta". In this repo `meta`
also carries annotations that *are* semantic — `@route` drives route discovery —
so a codec takes an explicit include list rather than an all-or-nothing flag.

### 6.5 Numbers and strings

Small categorical integers may use atoms. Continuous values need a scalar
encoder (`VsaScalarEncoder`) — quantized levels, thermometer coding, or residue
encoding — because a locality-preserving representation is the whole point and
atoms destroy it. The node codec delegates rather than inventing numeric
semantics.

Strings have two modes: an opaque atom over the string's bytes (subject to §5's
hashing rules), or a structured encoder for text that should be similar to
related text. The core requires no single answer.

---

## 7. Decoding

Decoding is approximate and returns candidates. It must never be presented as
recovering a value.

**Prefer schema-guided decoding over unrestricted reconstruction.** Given a
pattern, the decoder knows which roles to probe:

```gene
(codec ~ VsaCodec:decode v (quote (prop ?name ?value)))
```

which unbinds `POS_0` and `POS_1`, cleans up each result, and returns a
candidate with a confidence. This fits Gene's existing pattern orientation and
is far more reliable than walking an unknown tree out of a vector.

Results are candidates, plural:

```gene
(cleanup_result
  ^matches [(match ^value name  ^similarity 0.94)
            (match ^value label ^similarity 0.71)])
```

Note the naming: every registered name here is `snake_case`. Gene's convention
covers namespace members, protocol messages, and recognized props, and the guard
is a suite in `tests/spec_runner.nim` that walks the global scope and fails on
any hyphenated registration. Hyphens are legal in user symbols, so nothing
diagnoses `^min-similarity` where you write it — it fails the build later.

---

## 8. Cleanup memory

Unbinding yields a noisy vector; a cleanup memory maps it back to the nearest
known concept. It is not an optimization, it is part of how decoding works at
all, and it is a separate protocol because its implementation (linear scan,
ANN index, learned) is independent of the algebra.

For the reference-plus-summary codec (§6.2) the cleanup memory and the
associative index are the same structure: IDs in, exact Gene values out of the
store.

---

## 9. Capacity

Capacity is where VSA gives real numbers, and it is what picks the dimension.
The current draft picks 8192 because the prototype did; that is not a
justification.

Superposing *m* items into *D* dimensions leaves a similarity signal that falls
roughly as 1/√m, and cleanup accuracy depends jointly on *m*, *D*, and codebook
size. Each recursive unbind compounds the noise. So the dimension follows from a
budget: how many items in a bundle, how deep the nesting, how large the
codebook, what top-1 accuracy is acceptable.

**Gate G3 (§11) fills in this table, and its numbers set the default dimension
and the default codec depth. Neither should be stated as settled before then.**

**Measured** by `examples/vsa/bench/capacity.gene` (gate G3), identical on both
backends. The number is *precision*: the fraction of a bundle's members that
outrank every non-member in a 256-atom codebook, 3 trials.

| items bundled | D = 256 | D = 1024 | D = 4096 |
|---|---|---|---|
| 4 | 100% | 100% | 100% |
| 8 | 96% | 100% | 100% |
| 16 | 81% | 100% | 100% |
| 32 | 26% | 100% | 100% |
| 64 | 8% | 86% | 100% |
| 128 | 13% | 39% | 99% |

**The usable capacity is about D/16.** 256 holds 8–16, 1024 holds 64, 4096 holds
well past 128. Below that line precision is ~100% and above it the collapse is
fast rather than gradual — d=256 goes 81% → 26% between 16 and 32 items — which
is the shape that makes an unmeasured dimension dangerous. (The 8% → 13% wobble
at d=256 is noise: past capacity the ordering is arbitrary, so the number stops
meaning anything.)

Margin — how far the mean member sits above the mean non-member, at D=1024 —
decays as expected and is the earlier warning, since it degrades smoothly where
precision falls off a cliff:

| items | 4 | 8 | 16 | 32 | 64 | 128 |
|---|---|---|---|---|---|---|
| margin | 46% | 33% | 23% | 15% | 10% | 6% |

### Nesting depth does not improve with dimension

Recovered payload similarity after binding `d` levels deep and unbinding back
out, with a sibling superposed at each level (a node with one child loses
nothing, so that case would measure nothing):

| depth | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| D = 1024 | 71% | 58% | 50% | 44% |
| D = 4096 | 70% | 57% | 49% | 44% |

**The two rows are the same, and that is the result.** Interference from a
sibling is a fixed ratio of the signal at each level, so it does not thin out as
the space grows: raising the dimension buys bundle capacity and buys nothing at
all for depth. A design that hits a depth limit cannot spend its way out.

The good news is that the limit is softer than §6.3 assumed. At depth 4 the
payload still returns at 44%, an order of magnitude above the ~3% noise floor at
D=1024, so cleanup can still name it. **The default codec depth is 3**, which
holds 50% with margin to spare; §6.3's guess of 2 was conservative rather than
wrong, and depth is a recall-quality knob rather than a cliff.

### Footprint

**Accuracy is not the only axis, and at G5 it stops being the binding one.** A
vector's footprint is fixed and known, so the memory cost can be tabulated now:

| | per vector (F64) | per vector (F32) | codebook of 10,000 (F64 / F32) |
|---|---|---|---|
| D = 4096 | 32 KiB | 16 KiB | 313 MiB / 156 MiB |
| D = 8192 | 64 KiB | 32 KiB | 625 MiB / 313 MiB |
| D = 16384 | 128 KiB | 64 KiB | 1.22 GiB / 625 MiB |

G5 stores thousands of nodes; a cleanup memory over a large codebook is where
this stops being abstract. **G3 must therefore report accuracy and footprint
together**, because the dimension is chosen against total cost, not top-1 alone
— and at these sizes the `F32` space from §3.2 becomes a real candidate rather
than an aside. If `F32` holds accuracy at a given *D*, it halves the largest
cost in the system.

Diagnostics are exposed, not hidden:

```gene
(vsa/stats v)
# (vsa_stats ^dimension 8192 ^estimated_load 37
#            ^norm 1.02 ^cleanup_margin 0.18)
```

`estimated_load` is only meaningful against the table above, which is another
reason to produce it first.

Known failure modes: too many bundled items, deep recursive binding, correlated
codebook vectors, insufficient dimension, cleanup ambiguity, accumulated
unbinding noise, accidental similarity, and loss of exact ordering. All of them
degrade gracefully and silently, which is what makes diagnostics mandatory
rather than nice to have.

---

## 10. Where this lives

A package, not the stdlib root. `gene`, `genex`, `geney`, and `genez` are
reserved import roots, and landing under `gene/vsa` is a claim to be stdlib that
an experimental library has not earned. Packages exist, with manifests and a
lockfile, and that also gives versioned artifacts (§13.5) almost for free.

```text
src/space.gene        core protocol, guards
src/backends/map.gene bipolar MAP; later hrr/fhrr beside it
src/codec/            atoms, node encoder, normalization, scalar encoders
src/memory/           cleanup memory, associative memory, approximate index
tests/                the cross-backend spec and its two shells
```

Shipped at `examples/vsa` as `gene/vsa`, with `src/space.gene` as the library
entry — the protocol rather than a backend, so an importer depends on the
algebra and never on which family implements it. `src/codec/` and `src/memory/`
are the G4–G6 directories and do not exist yet.

Reserve the `gene/vsa` *import* slot for if and when it earns it.

---

## 11. Staging

Each gate produces a number that the next stage depends on. Gates G1–G3 come
before any integration work, because they decide parameters that later code
would otherwise hard-code.

- **G1 — algebra. ✅ Shipped as `examples/vsa`.** `atom`, `bind`, `unbind`,
  `bundle_into`, `permute`, `similarity`, `normalize` on one MAP backend,
  behind `VsaSpace`, with the shape and alias guards of §3.1.1 and §3.3.1. The
  spec runs from one source on both runtimes and their reports are **byte
  identical**; `tools/check.sh` is that diff.
  Two things this gate produced that were not in the plan:
  - **The codebook needed measuring, not asserting.** Taking an atom's sign
    from bit 0 of a multiplicative hash makes it a *linear* function of the
    component index, and every atom came out as the same vector up to sign —
    worst |sim| between distinct atoms **0.95** where ~0.03 was expected at
    dimension 1024. Nothing about the API showed it; only the number did. The
    fix is a data-dependent multiplier plus a mixed high bit, and the
    orthogonality table now lives in the package README.
  - **Four backend differences had to be worked around** rather than one:
    `~ len` is `Int` on the VM and `F64` on the web (miclone §D7.12, and this
    is the second `(+ 0.0 …)` wrapper in the repo); `$println` is not portable;
    a whole-number F64 interpolates as `1.0` against `1`, which is why the
    report carries no floats; and module-level `var` is rejected by the
    profile. Only the first was already recorded.
  Deferred from this gate: the **scratch pool** (§3.3) — callers still allocate
  their own temporaries, which is correct but leaves the pooling convention
  unwritten until something actually loops.
- **G2 — cleanup.** Recover an atom after binding and bundling, with noise.
  Produces: the accuracy-vs-load curve for a fixed codebook.
- **G3 — capacity. ✅ Shipped as `bench/capacity.gene`.** §9's table is filled
  in, byte-identical on both backends, and it produced two numbers and one
  finding:
  - **usable capacity is ~D/16**, and the collapse past it is fast rather than
    gradual (81% → 26% between 16 and 32 items at D=256);
  - **the default codec depth is 3**, not the 2 §6.3 guessed;
  - **nesting depth does not improve with dimension.** The D=1024 and D=4096
    rows are the same to within a point. Interference from a sibling is a fixed
    ratio of the signal, so a depth limit cannot be bought out with a bigger
    space — which is the opposite of how bundle capacity behaves, and the more
    useful half of what this gate produced.

  Two parts are **not** done and are honestly outstanding: the `F32` sweep
  (§3.2's second space does not exist — the protocol is typed to `(Buffer F64)`,
  and a second element type needs either generics over the buffer element or a
  parallel protocol, which is a real design decision rather than a parameter),
  and **scalar-encoder locality** (§6.5), which cannot be measured until an
  encoder exists.
- **G4 — properties. ✅ Both codecs exist and are accuracy-equivalent.**
  `encode_node` is the direct form (bind the key's role straight to the value);
  `encode_node_relational` materializes `(prop k v)` as §11.1's reference
  semantics do. Both recover 3 of 3 fields, and they produce genuinely
  different vectors rather than the same encoding spelled twice. The **≥2×
  throughput** half of the criterion is not decided: the direct form does two
  atoms and one bind per prop against the relational form's three and two, so
  it is cheaper by construction, but "cheaper" is not "2× measured" and this
  gate asked for a number. The reference codec therefore stays the reference.
- **G5 — associative index. ✅ Shipped, at three records rather than
  thousands.** A 2-of-3 partial query finds its record, so does 1-of-3, and a
  query mixing fields from two records **declines** at a high floor rather than
  returning the least-bad match — the assertion that separates an index from a
  guess. The index is `LinearMemory` keyed by record id, exactly as §8 predicts.
  Scale is the honest gap: §9 says usable capacity is ~D/16 *per bundle*, which
  bounds a summary's field count and not the number of records, but "thousands"
  has not been run and the linear scan is O(n) per query.
- **G6 — Memory adapter. ⛔ Blocked: there is no protocol to implement.** No
  `Memory` protocol exists anywhere in this repo — not in `src/`, not in
  `examples/`, not in `docs/`. The Gene Intelligence work this gate refers to
  lives outside the tree. `CleanupMemory` plus the summary codec already *is*
  an associative memory with the right shape, so the adapter is a thin shim
  once a protocol exists to shim to; writing one against a guessed interface
  would be inventing the contract, not implementing it.
- **G7 — programs. ✅ Partially, and the useful half works.** Gene is
  homoiconic, so a function *is* a node and needed no separate encoder — that
  claim is now tested rather than assumed. Structural similarity survives
  encoding: `(fn add [a b] (+ a b))` and `(fn sub [a b] (- a b))` sit closer to
  each other than either does to `(fn greet [n] (str "hi" n))`, which is what
  makes "find me code like this" possible at all. **Structural recovery and
  analogical matching are not done** — recovery needs the decoder §7
  deliberately does not build, and analogy needs a second encoded corpus to be
  analogous *to*.

Cross-backend fixtures from G1 onward: the same source, the same vectors, VM and
web profile, in the style of `examples/miclone`'s spec diffs. Atom generation is
the part most likely to drift (§5) and the cheapest to pin.

**G1 also carries the two runtime guards this design adds**, and both are
error-message diffs rather than value diffs, since a raise is the whole
behavior:

- the **buffer-shape check** (§3.1.1) — hand each public operation a
  wrong-length buffer and assert both backends raise the *same* diagnostic;
- the **`permute` self-alias raise** (§3.3.1) — pass one buffer as both input
  and `out` and assert it is refused rather than silently corrupting.

Neither guard is about backend disagreement — §3.1.2's divergence is closed, and
`index.*` in `tests/transpile/fixtures.json` keeps it closed. These two catch
the failures that look identical on *both* backends: a mis-sized buffer reads
`void` past its end and a self-aliased `permute` corrupts silently, and in each
case the result is a number that means nothing. Nothing else in the suite would
notice.

Runtime work (SIMD, GPU, packed storage, zero-copy FFI) comes only when a
library prototype demonstrates the need. Any such work is host-only and **must
be `when not defined(geneWasm)`-gated** — an ungated host subsystem cost this
repo +675 KB of wasm payload once, and `nimble test` cannot catch it because
only `nimble wasm` rebuilds.

---

## 12. Non-goals

- **VSA does not replace the Gene VM or compiler.** Exact programs execute
  through the normal pipeline.
- **VSA is not compression.** A fixed-size vector holding a large tree works
  because information becomes distributed and approximate, and recoverability
  falls as structure grows. Never use VSA as the sole persistent representation
  of source, configuration, financial data, or security policy.
- **`=` is not overloaded.** Gene equality stays exact. VSA similarity is
  explicit: `(vsa/similarity a b)`. Structural equality, semantic similarity,
  and VSA similarity are three different things.
- **`query` is unchanged.** An approximate VSA query is a library feature with
  its own spelling, never hidden behavior inside ordinary `query`.
- **No global cognitive workspace is assumed.** A superposed working memory is
  an interesting experiment (§13.4), not an architectural requirement.

---

## 13. Open questions

**13.1 Which backend beyond MAP?** Do not decide at the language level. MAP
first for the reasons in §4.1; add FHRR as a second implementation of the same
protocol when a workload justifies the complex-arithmetic support it needs.

**13.2 Should Gene gain a property-free canonical node form?** Probably not as a
language change. A library normalization (`vsa/normalize`) appears sufficient,
and §6.1 keeps props native. Revisit only if G7 shows that program encoding
wants it.

**13.3 Random atoms or learned?** Begin deterministic. But note that **§13.3 and
multimodal grounding are in tension**: asking a vision encoder to hit a fixed
random `H_car` in 8192-dimensional space is a much harder training problem than
learning an aligned representation, and it is not what the cited
neuro-symbolic work does. The cheap resolution is random atoms *plus a learned
projection head per modality*, trained to align onto the Gene symbol's atom —
the symbol codebook stays the shared anchor, and the learning happens in the
projection. Anything stronger (a learned codebook shared across modalities) gives
up deterministic atoms and needs to say so.

**13.4 Can VSA be a cognitive IR?** Possibly. This should be an experimental
conclusion, not a design assumption. Recent work shows Lisp-like computation can
be represented in VSA; Gene is homoiconic and Lisp-like, so G7 is worth running.
It is not required for anything above it.

**13.5 How do learned artifacts get versioned?** Codebooks, cleanup memories,
role vectors, and learned encoders are all artifacts that can be benchmarked
against the active version. Package versioning covers the mechanism; what needs
deciding is the metric set. Do not assume larger dimension or a different
algebra is automatically better.

**13.6 How do unnamed learned concepts work?** They do not need names. A learned
concept can exist as a vector with an internal id, and a human-readable Gene
symbol can be attached later when it is grounded. Intelligence should not
require every internal concept to have a word.

---

## 14. Research basis

- Denis Kleyko et al., *Vector Symbolic Architectures as a Computing Framework
  for Emerging Hardware*, Proceedings of the IEEE, 2022.
- Michael Hersche et al., *A Neuro-vector-symbolic Architecture for Solving
  Raven's Progressive Matrices*, Nature Machine Intelligence, 2023.
- Eilene Tomkins-Flanagan and Mary A. Kelly, *Hey Pentti, We Did It!: A Fully
  Vector-Symbolic Lisp*, 2025, arXiv:2510.17889.
- Connor Hanley, Eilene Tomkins-Flanagan, and Mary Alexandria Kelly, *Hey
  Pentti, We Did (More of) It!: A Vector-Symbolic Lisp With Residue Arithmetic*,
  2025, arXiv:2511.08767.

These motivate experimentation. They do not establish that VSA is a complete
model of general intelligence, and choosing VSA is itself a strong assumption —
real systems, biological and artificial, are not MAP-style binding. What a
working substrate buys is that the claims become measurable, not that they
become true. Gene should treat the rest as an empirical question.
