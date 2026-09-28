# VM Fallback Protocols for Values

**Status:** VAL-1–3 are implemented experimentally in the native VM: sealed witnesses, semantic equality/hash, indexed access, ValueOrder, and stable `gene/order` sorting. Conformance, RC, and threaded checks cover the native implementation; cross-backend qualification and remaining edge-case audit are open. Design baseline `3b2bde9`.

**Stages:** VAL-1 (canonical witnesses), VAL-2 (equality/hash), VAL-3 (indexing/order).

**Depends on:** VM-0/1 lifetime diagnostics and eval ownership. Uses existing protocol syntax; no language reader additions.

## Selected model

Provide `ValueEq`, `ValueHash`, `ValueOrder`, `IndexRead`, and `IndexWrite` in the `gene` root, alongside existing core types/protocols. Built-in operations use their existing fast path where applicable, then consult a nominal Type's selected protocol witness. For typed Nodes the witness is checked before generic Node structural/body behavior. Plain Nodes and nominal Types that do not opt in retain their present behavior. `same?` remains identity.

| Protocol | Required signatures | VM entry points |
| --- | --- | --- |
| ValueEq | `equal [other : Self] : Bool` | ==, !=, recursive collection equality and membership. |
| ValueHash | `hash [] : Int` | hash and Set/general-key Map keys; requires ValueEq. |
| ValueOrder | `compare [other : Self] : Int` | Non-numeric ordering fallback and default sorting; result -1, 0, or 1. |
| IndexRead | `size [] : Int`; `at [index : Int] : Any` | Numeric paths/selectors and generic $size. |
| IndexWrite | `put_at [index : Int value : Any] : Any` | Final numeric set-path segment; requires IndexRead. |

Example proposed application code, after the core protocols exist:

```gene
(type UserId ^props {^text Str})
(impl ValueEq for UserId
  (message equal [other : UserId] : Bool
    (== self/text other/text)))
(impl ValueHash for UserId
  (message hash [] : Int
    ($hash self/text)))
```

These are existing type/impl/message forms. The VM fallback is new. No separate keyed-map family is required.

## VAL-1: canonical selection and lifetime

Ordinary scoped protocols remain scoped. These five reserved core identities additionally require one canonical implementation per concrete Type identity for implicit VM use. Declare the impl in the Type's defining module, or in the same eval generation that creates that Type. Foreign-module, transient function-local, conditional late, and alternate import_impl definitions of these core impls are rejected. import_impl may expose the already selected identity; it cannot replace it.

Reuse the current module/eval impl-assembly validation path. Publish the complete fallback descriptor atomically with that Type's activation. A forward declaration can be pending during assembly, but attempting fallback or exporting the Type before its descriptor is sealed raises ValueProtocolPending. A Type without these declarations is sealed with an explicit empty descriptor; a later module cannot turn an already-used structural key into a semantic key.

Pin selected callables, authored scopes, dependency identities, and error contracts strongly to the descriptor. Caches guard Type identity plus immutable descriptor identity. For version 1, changing a descriptor requires a new Type identity; no in-place witness replacement or automatic rehash migration is supported. Existing collections can continue using old values/code while reachable. Include descriptor/scope cycles in VM-1 lifetime tests.

Same concrete nominal Types may use ValueEq/ValueOrder, including an inherited implementation whose existing declaration-bound Self contract admits those receivers. Different nominal Type identities compare false; ordering them raises OrderError. Reuse an inherited equality/hash pair together. A child replacing equality must supply its own hash too, or become explicitly unhashable; never inherit a hash accidentally incompatible with replacement equality.

ValueEq without ValueHash is allowed for non-key values. ValueHash without ValueEq is a declaration error. When ValueEq exists without ValueHash, user-facing hash and key admission raise ValueNotHashable rather than substitute structural hashing.

## VAL-2: semantic equality and keys

Introduce context-aware VM semantic equality/hash helpers. Keep the pure structural functions in `equality.nim` for compiler syntax, package/module identities, representation checks, and other internal bookkeeping that must never execute user code.

Route all user-facing equality paths through the semantic helper: ordinary calls, held aliases, compiler fast paths, List membership, Set/general-key Map construction/lookup/removal, and recursive equality/hash of nested values. Plain collection structure still compares structurally, but typed children invoke their canonical semantics. Property-map keys remain named keys. A top-level == change alone is incomplete.

Hash admission retains the current recursive immutability/hash-stability rules, including NaN rejection and native-resource exclusions; it is not just a check of one deepFrozen flag. Freezing must preserve the semantic value and Type witness. Thawed mutable Nodes remain ineligible as keys. ValueEq/ValueHash must depend deterministically on the value and immutable selected code, and satisfy equality implies equal hash. Equal hashes do not imply equality. The runtime does not promise stable hash integers across releases/processes, so serialized data stores values rather than hash buckets.

Core fallback callbacks run synchronously on the root lane in version 1. They use normal callable checks, diagnostics, and budgets; they may allocate and raise ordinary errors, but cannot suspend/pump the scheduler. Worker calls that would enter a witness not qualified for worker execution fail with RuntimeLaneError before callback effects. Built-in worker operations retain their existing support. Error analysis must treat custom fallback as a potentially failing call, including through operators.

During a collection key operation, guard that same collection against callback-driven reentry/mutation and raise ValueOperationReentry. Compute key results before publishing insertion/removal; errors leave that library operation unpublished. Arbitrary callback side effects elsewhere are not rolled back. Reentering the same active nominal equality operand pair or hash receiver also raises, rather than infinitely recursing. The law/purity requirements remain author contracts; tests cannot prove them for arbitrary code.

## VAL-3: indexed access

`x/0`, `(/0 x)`, dynamic numeric path segments, and intermediate numeric reads in set share one fallback helper. `($size x)` uses IndexRead:size. Named segments retain current property and schema semantics.

Normalize Int/integral F64 indices to a nonnegative Int using size. Nonintegral/nonfinite Float reads return void; writes raise as with existing List access. Huge/out-of-range reads return void without narrowing overflow; writes raise before invoking put_at. size must be nonnegative. at may return any value, including void for a missing logical slot.

A final set segment uses IndexWrite and returns the actual stored value. If IndexRead exists without IndexWrite, writes fail; they must not fall through and mutate the representation's Node body. An ordinary immutable Node rejects writes before dispatch. Native wrappers use their existing owned-resource mutation rules. Normalize positional void to nil before put_at, matching List/body storage. Validate/adapt before mutation in the implementation; arbitrary Gene method effects are not automatically transactional.

General unqualified sends remain type-direct: `(x .get 0)` requires a direct message, while `(x .IndexRead:at 0)` is explicit protocol dispatch. This proposal grants fallback to listed VM operations only. Existing to_stream, assoc_in/update_in, destructuring, and call spreading keep their present contracts; implementing IndexRead does not implicitly opt into those different lifetimes/representations.

## Ordering and bounded sorting

Numeric operators keep existing numeric/NaN behavior. For non-numeric values of the same nominal Type, ValueOrder supplies the operator fallback. Built-in Str (Unicode scalar order), Date, and Duration may gain explicit VM fast paths. Unrelated types have no implicit order.

Add `($order/compare a b)`, `($order/sort values ^compare f)`, and `($order/sort_by values key_fn ^compare f)`. Omitted comparator uses homogeneous built-in ordering or ValueOrder; default sort comparison rejects NaN and mixed numeric types rather than silently infer a conversion policy. This stricter sort rule does not change existing numeric operators.

Use stable O(n log n) merge sort over a copied finite List. Validate comparator results; evaluate key_fn once per item before sorting. Retain input order for ordering ties, which need not mean ==. Comparator must define a consistent strict weak ordering. A callback error returns no sorted result; captured objects the callback mutated are not restored. Streams must be bounded/collected explicitly.

## Work map and exit tests

| Stage | Seams | Required tests |
| --- | --- | --- |
| VAL-1 | Type metadata in types.nim, protocol assembly/reload/eval in vm.nim | Empty and selected descriptors seal before use; duplicate/late/scoped override rejection; inherited Self; old values survive new Type generation; witnesses release when unreachable. |
| VAL-2 | VM equality/hash and collection operations; preserve internal equality.nim use | Aliased ==/hash, nested typed values, frozen keys across modules, equal/hash law fixtures, collisions, missing hash, callback failure/reentry, compiler fast-path parity. |
| VAL-3 | Selector/staticLookup/set/size seams, ordering natives and new order module | Read-only sequence writes fail, negative/F64/huge indices, void normalization, immutable/native wrappers, sort stability/key-call counts, custom callbacks cannot await. |

Extend existing protocol, spec, mutation, and RC suites. The web/C backends must either implement a listed fallback with shared tests or reject it before execution; an accepted nominal type must not silently fall back to structural equality on another backend. Custom worker fallback is separately qualified later.

## Backend audit — 2026-09-27

The existing native specs and six shared semantic samples pass. A freshly built
wasm VM agrees on those samples (45 total ABI cases), including held/recursive
equality, semantic keys, missing hash, indexed reads/writes and huge/F64 bounds,
ordering, and nominal sorting. The emitted web backend rejects the five tested
canonical witness declaration combinations before emission; typed-native C
rejects the five tested witness-bearing native-wrapper operations before
emission. These boundaries are executable in
`tests/test_value_backend_boundaries.nim`, and VM/wasm samples share
`tests/fixtures/value_operations.json`. Explicit ordinary protocols keep their
existing contracts; they do not opt into these implicit canonical operations.

This is sampled parity/refusal evidence, not full backend promotion. Wasm
error/reentry/activation/lifetime and browser-host qualification, web/C witness
implementation, custom worker support, and native Linux remain separate gates.
See [the consolidated profile evidence](../profiles/native-app.md#distribution-and-value-operations).
