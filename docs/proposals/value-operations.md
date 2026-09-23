# VM Fallback Protocols for Values

**Status:** Proposed design; none of the fallback rules below is implemented.  
**Purpose:** Let nominal Gene values define equality, hashing, ordering, and list-like access through protocols while preserving built-in behavior.  
**Syntax:** Ordinary `protocol` and `impl` declarations. The VM gains dispatch rules; Gene gains no new reader form or operator syntax.

## Decision

Define five core protocols: `ValueEq`, `ValueHash`, `ValueOrder`, `IndexRead`, and `IndexWrite`. For a nominal value with a canonical implementation, the VM uses that implementation when an existing generic operation reaches the value. Built-in scalars and collections keep their current fast paths. A nominal value with no implementation keeps today's structural Node equality/hash and body indexing. `same?` always remains identity and never calls a protocol.

This replaces the separate `$keyed/map` scheme in the earlier draft. Ordinary Set and general-key Map must use the same equality and hash semantics as `==` and `hash`; otherwise a value could compare equal but be impossible to find as a key.

| Protocol | Required messages | VM use |
| --- | --- | --- |
| `ValueEq` | `equal [other : Self] : Bool` | `==`, `!=`, and recursive equality inside List, Set, general-key Map, and Node values. |
| `ValueHash` | `hash [] : Int` | `hash` and Set/general-key Map key operations. Requires a canonical `ValueEq` implementation. |
| `ValueOrder` | `compare [other : Self] : Int` | Ordering operators and default stable sorting. Result must be exactly `-1`, `0`, or `1`. |
| `IndexRead` | `size [] : Int`; `at [index : Int] : Any` | Numeric slash-path/selector reads and generic `$size`. An absent item returns void. |
| `IndexWrite` | `put_at [index : Int value : Any] : Any` | Final numeric segment of `(set value/0 new_value)`. Requires `IndexRead`. Return the value actually stored. |

These are ordinary Gene message signatures. This declaration and explicit protocol call already fit the syntax; only the proposed VM fallback is new:

```gene
(protocol ValueEq
  (message equal [other : Self] : Bool))
(type UserId ^props {^text Str})
(impl ValueEq for UserId
  (message equal [other : UserId] : Bool
    (== self/text other/text)))
((UserId ^text "a") .ValueEq:equal (UserId ^text "a"))
```

The actual core protocols will be provided by `gene`, so applications will not redeclare them. An implementation of `ValueHash` for this type can return `(hash self/text)`. The example's final explicit call works under today's protocol rules; the proposed `==` fallback would call the same selected implementation.

## Canonical implementation rule

Ordinary Gene protocol implementations can be scoped and imported. Implicit VM operations cannot use an implementation that changes with the caller's lexical scope: a key inserted into a map in one module must still be findable from another. Therefore these five core protocols have a narrower rule for VM fallback: one canonical implementation per nominal Type identity, declared in the Type's defining module or selected with that Type in the same eval generation. Module/eval activation checks the complete set and pins its code revision to the Type identity. A second, different implementation for the same Type/core protocol is rejected; `import_impl` cannot change a VM fallback. Applications needing a different equivalence use a wrapper type or an explicit comparison/key function.

Existing ordinary protocols keep their scoped visibility and qualified-send behavior. Core protocols remain callable explicitly with `ValueEq:equal` or the corresponding qualifier; no arbitrary unqualified message send gains protocol fallback. Reloading cannot silently change a pinned equality/hash pair for values already held as keys. A replacement creates a new Type identity or requires an explicit migration of affected keyed collections.

`ValueEq` is used only when both operands have the same concrete nominal Type identity. Different nominal types compare false, matching today's structural-head distinction. A type may provide `ValueEq` without `ValueHash`, but then `hash` and key insertion fail for that type rather than silently using structural hash. `ValueHash` cannot be selected without `ValueEq`. An inherited pair may be reused together; replacing equality requires selecting a compatible hash implementation in the same activation before the type is hashable again.

## Equality and hash across containers

Keep a raw structural comparison/hash path inside the reader, compiler, and module-identity machinery. Add VM semantic equality/hash functions for user-facing `==`, `hash`, List/Set/general-key Map comparison and membership, and recursive values. For a typed Node, consult its canonical witness before generic structural Node traversal; for plain Nodes and existing built-ins, keep current behavior. Recursive container comparison invokes the same semantic rule on nested typed values. General-key Map and Set key operations use that same rule. Freezing preserves semantic equality and hash; thawed mutable values remain ineligible as keys. Property-map keys remain their existing named keys.

Hash keys still must be hash-stable: retain the existing deep-frozen-key check for nominal Nodes and nested containers. `ValueEq`/`ValueHash` methods must be deterministic over the frozen reachable value and obey `a == b` implies `hash(a) == hash(b)`. The VM cannot prove purity, so violations are a user contract with conformance tests. Method errors propagate as ordinary Gene errors. A Set/Map mutation computes and validates the required hash/equality results before publishing a new entry; failure leaves that operation's collection unchanged. Generated runtime failures, panic, and cancellation retain their existing classifications.

## List-like access

Numeric slash-path reads such as `value/0`, selector application, and intermediate numeric segments of `set` use `IndexRead` for a nominal value with a canonical implementation. The final numeric `set` segment uses `IndexWrite` when present. Named property segments keep their existing property/schema meaning and precedence. Existing List and Node-body path behavior remains the fast path unless a nominal Type explicitly selects the protocol fallback. Buffer's existing direct `get`/`set` messages remain available; this proposal does not claim Buffer currently supports slash-path indexing.

The VM accepts Int and integral F64 indices as it does for List, normalizes a negative index using `IndexRead:size`, and passes a nonnegative Int to `at`/`put_at`. A nonintegral Float read returns void; a nonintegral Float write raises. A read past the end returns void; a write past the end raises the same index-range category as a List write before calling `put_at`. `size` must return a nonnegative Int. `put_at` performs its own type validation and must not publish a partial mutation on an ordinary recoverable error. The VM rejects writes to an immutable ordinary Node; a native-wrapper implementation applies its existing owned-resource mutation rules. Direct `(value .get 0)` still requires a type-direct message or an explicit qualified protocol call, preserving Gene's no-implicit-protocol rule for general sends.

Existing `to_stream` remains the generic iteration entry. An indexed type can provide that type-direct conversion; `IndexRead` alone does not silently make a potentially changing resource into a Stream. Functional `assoc_in`/`update_in` also keep their current contract until a separate persistent-update protocol is designed.

## Ordering and sorting

`ValueOrder:compare` applies to two values of the same concrete nominal Type and supplies `<`, `<=`, `>`, and `>=` after the existing numeric fast path. The VM validates the three result values. The method must define a stable total order. Built-in Str, Date, and Duration ordering can be added through VM fast paths without changing the syntax; Str uses Unicode scalar order, independent of locale. NaN is unordered and raises `OrderError` when compared through default ordering. No implicit order exists between unrelated types.

Add `($order/sort values ^compare comparator)` and `($order/sort_by values key_fn ^compare comparator)` as stable, non-mutating List operations. When `^compare` is omitted, use built-in ordering or `ValueOrder`. A comparator is an ordinary Gene function returning exactly `-1`, `0`, or `1`; `sort_by` evaluates `key_fn` once per item. Sorting copies the input before invoking callbacks. Streaming callers must collect a finite List explicitly.

## Implementation sequence and acceptance

1. Introduce core protocol identities and canonical selection/validation on nominal Types. Test module imports, duplicate impls, inheritance, reload, and eval generation lifetime before switching operators.
2. Route `==`/`!=` and `hash` through VM semantic functions, then update Set and general-key Map construction, lookup, removal, and recursive container equality/hash. Keep internal structural helpers separate. Test frozen keys across modules, nested values, missing `ValueHash`, an equality/hash law violation fixture, and errors before mutation.
3. Route numeric path reads, selectors, `$size`, and numeric `set` through `IndexRead`/`IndexWrite`. Test negative/integral-F64 indices, missing reads, out-of-range writes, immutable values, nested paths, and native wrappers.
4. Add `ValueOrder` fallback and stable sorting. Test comparator failures, stability, cross-type rejection, and unchanged numeric operators. Qualify the web backend separately; until it matches, reject these fallback-dependent programs in its checked profile.

**Acceptance:** a user-defined nominal value can be compared, hashed as a frozen Set/Map key, ordered, and indexed through existing Gene operators and paths with the same result across module boundaries. Built-in and unadapted nominal values retain their current behavior, and internal syntax/module identity never depends on user protocol code.
