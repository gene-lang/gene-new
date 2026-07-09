# Gene Serialization (serde) — Design

Status: **stages 1–6 implemented** (all in `src/gene/stdlib.nim`, spec- and
e2e-tested; gateway persistence in `examples/agent_gateway.gene`). Revision 2
(incorporates review: reserved-head escaping, cells out of the data bucket,
policy-gated hooks and resource limits, narrowed value refs, reserved
version/package slots). Date: 2026-07-09.

**Implementation deltas from the prose below** (the prose is the design;
these are the shipped specifics):
- `serde-state`/`serde-restore` are **type-direct messages**, not a `Serde`
  protocol — dispatch works both ways and needs no protocol/impl ceremony.
  `SerdeRef` (§7) is a real empty marker protocol.
- Stage-3+ references resolve against **loaded modules only** and never load
  a module named by a payload (no-code-execution, verified). The entry
  module currently executing has no origin yet (it is mid-load, not cached),
  so refs cover imported dependencies and builtins — the design-intended
  path.
- Value refs (§7) are emitted **only** for module-level instances of a
  `SerdeRef`-marked type. The "immutable/hash-stable auto-qualifies" option
  is intentionally not implemented: for immutable data, by-value and by-ref
  are observationally identical, and auto-ref'ing every module constant would
  be surprising.

Implementation note: control tags are **dash-named plain symbols**
(`serde-v1`, `serde-float`, `serde-sym`, `serde-map`, `serde-set`,
`serde-range`, `serde-timezone`, `serde-duration`, `serde-data-node`) rather
than the `serde/*` spellings used in prose below — slash tokens read back as
`(path ...)` nodes, so slash-headed tags would not survive a print/read
cycle. The reserved namespace is "symbols starting with `serde-`", and the
prose's `serde/x` names denote `serde-x`. Namespaced *function* names
(`serde/write-data` etc.) are unaffected — those are ordinary imports.

Serialization converts runtime values to a storable/transmittable text form
and back. This design adapts the prior Gene implementation's serdes proposal
(`gene/docs/proposals/future/serialization_design.md` in the old repo) to this
runtime: NaN-boxed values, types/protocols instead of classes, file-path
modules, Send-safety for channels, and — most importantly — the capability
model, which turns deserialization policy into a security surface the old
design did not have to consider.

## 1. What this repo already provides

The design leans on machinery that exists and is spec-tested today:

- **The canonical printer/reader round trip.** `print()` emits canonical Gene
  text and `readAll` parses multi-form source; the spec suite already asserts
  round trips. Gene is homoiconic: for pure data, *serialization is printing*.
  There is no separate wire grammar to invent, version, or keep in sync.
- **Direct typed-data construction.** `(T ^prop val ...)` constructs an
  instance without running `ctor` — design.md states this exists so values are
  "printable/serializable back into Gene data without replaying arbitrary
  constructor code." Instance deserialization gets its semantics from this
  form, not from constructors.
- **Send-safety** (`isSendableValue`): the runtime already classifies values
  safe to cross thread boundaries. Serde's *data* bucket is a close cousin
  (§4) with one deliberate difference around mutability.
- **Module identity**: modules are cached by absolute path and confined to a
  package root (`resolveModulePath` rejects escapes). Package-root-relative
  paths are the stable module identity refs need.
- **Typed-error precedent**: `json/parse` raises `JsonError` with `^message`
  and enforces a depth cap against malicious input; `serde` follows the same
  shape with `SerdeError` and generalizes the caps into a policy (§8).
- **Prior-art gap**: there is no serdes module at all today. The nearest
  facility is `json/stringify`, which handles only JSON-shaped data and loses
  Gene-specific kinds (symbols, chars, sets, dates, nodes, types).

## 2. Format: versioned Gene text, with reserved-head escaping

Serialized output is ordinary Gene source, wrapped in a version envelope:

```gene
(serde/v1
  {^session "tg-42"
   ^items [{^role "user" ^content "hello"} ...]})
```

- One top-level `serde/v1` node; its single child is the payload. Future
  format changes bump the head symbol — readers dispatch on it.
- The payload parses with the ordinary reader; `serde/read*` is the reader
  plus a validating walk and (for `read`) reference resolution. A human can
  read, diff, and edit the output; `bin/gene fmt` normalizes it.
- Encoding is UTF-8 text. Binary efficiency is a non-goal (§11).

**Reserved heads and the escape rule.** Inside a `serde/v1` envelope, every
node head in the `serde/*` symbol namespace is a control tag. Ordinary user
data may legitimately contain nodes with such heads — `(serde/inst 1 2)` is a
perfectly valid Gene node — so without an escape rule, arbitrary nodes would
not round-trip. The rule:

> When serializing, any *user data node* whose head symbol is in `serde/*` is
> emitted in escaped form:
>
> ```gene
> (serde/data-node ^head serde/inst ^props {...} child1 child2 ...)
> ```
>
> applied recursively — a user node whose head is `serde/data-node` escapes
> the same way. When deserializing, `serde/data-node` reconstructs the
> original node; any *other* unescaped `serde/*` head is either a control tag
> defined by this spec or a `SerdeError` ("unknown serde control tag").

This makes the round-trip guarantee (§4) true for *all* data-bucket values,
not just the ones that avoid a reserved prefix. Escaping ships in stage 1
(§12) because the guarantee is false without it.

**Float special values.** The data round trip must cover the full `F64`
domain, so the format defines canonical forms for the values plain decimal
text cannot express:

```gene
(serde/float "nan")
(serde/float "+inf")
(serde/float "-inf")
(serde/float "-0.0")
```

(If the reader later grows literals for these, the serializer can switch to
them inside a new envelope version; `serde/float` remains readable.)

## 3. Three buckets

Every value falls into exactly one:

1. **Data** — scalars and containers of data. Serialized by value (printed),
   deserialized by construction. No environment needed to read back.
2. **Named definitions** — types, protocols, enums, enum variants, functions
   (`fn`/`fn!`), namespaces, and (narrowly, §7) module-level named constants.
   Serialized as **typed references** (§5); resolution is policy-controlled
   (§6). Typed *instances* (§7) also live here: they need their type ref
   resolved.
3. **Not serializable** — process-bound values. Attempting to serialize one
   raises `SerdeError` naming the offending value and its path within the
   payload (e.g. `"at items/3/handler: functions with captured scope do not
   serialize"`).

Bucket 3, some entries gene-new-specific:

| Value | Why not |
|---|---|
| **Capability values** (`Os/Exec`, `Fs/*`, `Net/Connect`, `Ffi/Load`, ...) | Authority must never round-trip through data. A deserialized payload must not be able to mint capabilities (§6). |
| **Cells and atomic cells** | Identity-equality values (`equality.nim` compares them by identity); a reconstructed cell is a *different* cell, which would silently break the round-trip guarantee and aliasing expectations. Serialize the *contents* explicitly (`(Cell/get c)`); see §7 for the opt-in snapshot wrapper in full `write`. |
| Closures (fns with captured scope), `fn!` values | Captured scopes reference live scope chains; snapshotting them is the fiber-continuation problem, out of scope. Top-level named fns serialize as refs (bucket 2). |
| Channels, tasks, actor refs, streams/generators | Live scheduler state. `actor/snapshot` output (a data value) serializes fine; the actor itself does not. |
| `Env` values | Binding environments are execution state, not data. |
| Native handles (`db` connections, `CPtr`/`CSlice`, buffers, FFI libraries, HTTP servers) | Process-bound resources. Types owning them can opt into reconstruction hooks (§7). |
| Unmarked module-level mutable state | Not referenceable (§7's narrowing) and not meaningfully snapshottable without owner cooperation. |

## 4. Data serdes (`serde/write-data` / `serde/read-data`)

The data bucket accepts:

- scalars: `nil`, `void`, booleans, ints (including big ints), floats
  (including specials via `serde/float`), chars, immutable strings, symbols,
  bytes;
- time values: dates, times, datetimes, timezones, durations;
- ranges;
- **regexes as source + flags** — the runtime's regex is a compiled PCRE
  value, but its identity is the pattern and canonical flag string; read-back
  recompiles (a target that cannot, raises `SerdeError` at read time);
- containers: lists, prop maps, hash maps, sets, and nodes with symbol heads
  — recursively, all contents must be data, with reserved heads escaped (§2);
- reserved for future kinds (`Uuid`, `Decimal`, ...) — added to this list as
  they land, inside the same envelope version when their text form is purely
  additive.

Notes and deliberate decisions:

- **Mutability does not matter.** Send rejects mutable maps because sharing
  them races; serialization is a snapshot by construction — the text cannot
  alias the original. Mutable containers serialize; reading back produces
  fresh mutable containers. (This directly fixes the awkwardness that forced
  the agent gateway's Telegram outbox to hand-serialize event maps to JSON
  strings before `Channel/send`.)
- **Cells are not data** (§3). This keeps the round-trip guarantee honest:

  ```gene
  (= v (read-data (write-data v)))   ; structural equality, ALL data values
  ```

  holds for every bucket-1 value with no exceptions — the guarantee is the
  primary spec-test axis, and identity-equality values would falsify it.
- **`read-data` resolves nothing and constructs nothing typed.** It accepts
  exactly the data subset; every unescaped `serde/*` control tag other than
  the envelope, `serde/float`, and `serde/data-node` — all refs, `serde/inst`,
  `serde/snapshot-cell` — is a `SerdeError`. Mechanically: `read-data` is the
  reader, the escape decoder, and a whitelist walk.
- **Cycles are an error** (`SerdeError`, with the cycle path). The MVP does
  not emit shared-structure labels; if a real need appears,
  `(serde/shared N ...)` / `(serde/ref-shared N)` can be added inside the
  same envelope version.

`serde/data? : Any -> Bool` reports whether a value is in the data bucket
without serializing it.

## 5. Named definitions: typed references

Definition-like values serialize as reference nodes carrying two coordinates
(plus reserved slots for future package identity):

```gene
(serde/type-ref     ^module "examples/geometry" ^path "Point")
(serde/protocol-ref ^module "examples/geometry" ^path "Drawable")
(serde/fn-ref       ^module "examples/geometry" ^path "area")
(serde/enum-ref     ^module "examples/agent"    ^path "SseEventKind")
(serde/variant-ref  ^module "examples/agent"    ^path "SseEventKind/completed")
(serde/ns-ref       ^module "examples/stdweb"   ^path "routes")
(serde/value-ref    ^module "examples/config"   ^path "DEFAULT-LIMITS")
```

- `^module` is the **package-root-relative source path** without extension —
  the same identity `resolveModulePath` enforces. It is stable across
  machines and absent for built-ins:

  ```gene
  (serde/type-ref ^path "Str")            ; builtin — always resolvable
  (serde/fn-ref   ^path "str/join")
  ```

- `^path` is the namespace path inside the module (nested namespaces join
  with `/`).
- References **reserve** optional `^package` and `^version` props for a
  future package registry story — two packages can legitimately contain the
  same relative module path. MVP emits neither and treats their presence as
  an error ("unsupported ref feature"), which keeps old readers honest when
  the props start appearing.

**Origin tagging.** To emit refs, definition values must know where they came
from. At module load, after a module's top-level forms run, the loader walks
the module scope and stamps each taggable value (types, protocols, enums,
fns, namespaces, and qualifying module-level bindings) with `(module, path)`
origin. Values defined at the REPL, inside function bodies, or anonymously
have no origin and cannot be referenced — a type created at runtime can still
have its *instances* serialized if the type itself is resolvable, otherwise
instance serialization fails with a clear error. Tagging is once per module
load, additive, lives on heap object payloads (never in the NaN box), and
must show no regression on module-load benchmarks.

Enum **variants** are first-class values here (unlike the old design's enum
members): `(serde/variant-ref ^path "Kind/completed")` resolves through the
enum, and enum *payload-carrying* values — `(Result/ok 42)` style nodes —
serialize as instance nodes (§7) whose head is a variant ref.

## 6. Deserialization policy: resolution is a capability decision

The old design auto-imported missing modules during deserialization. In this
runtime that is unacceptable as a default: **loading a module executes its
top-level code**, so deserializing untrusted bytes would be arbitrary code
execution, and even trusted payloads should not exercise ambient authority.
The rule that "every new host power is a capability value" applies:

- `serde/read-data` never resolves references — pure data in, pure data out.
  It is the default and covers the primary use cases (§10).
- `serde/read` resolves references **only against already-loaded modules**
  (the module cache) plus built-ins. A ref to an unloaded module raises
  `SerdeError ^unresolved` listing the module, so the caller can import it
  first — in ordinary code, by writing the `import` at the top of the file,
  which is both the policy and the audit trail.
- **MVP has no import escape hatch at all.** A post-MVP
  `(serde/read s ^import [...])` allowlist may be added, but because module
  loading is authority, it must be gated by an explicit module-loading
  capability value (e.g. `Module/Load`), not by a bare flag:

  ```gene
  (serde/read text ^load module-load-cap ^import ["a/b"])   ; post-MVP shape
  ```

  There is no "auto-import whatever the payload mentions" mode, ever.
- **Restore hooks are policy-gated** (§7): plain `serde/read` performs only
  reference resolution and direct typed-data construction — it executes no
  user code. `^allow-restore` opts trusted callers into `serde-restore`.
- Deserialized payloads can never contain capability values (§3), so a
  payload cannot smuggle authority regardless of resolver policy.

Resolution failures, arity/shape mismatches, unknown control tags, policy
violations, and version-envelope mismatches are all `SerdeError` with
`^message` and, where applicable, `^unresolved` / `^path` props — the
`JsonError`/`UrlError` pattern.

## 7. Instances: direct construction; hooks and value refs are opt-in

An instance of a user type serializes as an **instance node**: the canonical
`(T ...)` form with the head replaced by a ref, props/body recursively
serialized, and a reserved schema-version slot:

```gene
(serde/inst (serde/type-ref ^module "examples/geometry" ^path "Point")
  ^x 10.0 ^y 20.0)

(serde/inst ^schema-version 2 <type-ref> ...)   ; reserved; absent means 1
```

Deserialization resolves the head and applies **direct typed-data
construction** — the `(T ...)` path that validates fields and stamps the head
but *does not run `ctor`* (and never `new`). This is exactly the semantics
design.md prescribes for representing "the value that exists, not the process
that produced it". No blind property copying: field validation runs, unknown
fields are rejected, required fields are enforced. Schema migration is a
non-goal for v1; the `^schema-version` slot plus a named future hook
(`SerdeMigrate`, dispatched before construction) reserve the space so old
payloads remain diagnosable rather than silently mis-read.

**Hooks, for types whose state is not their fields.** Protocol dispatch here
is receiver-first, so the restore message dispatches on the *type object*:

```gene
(protocol Serde
  # Return a data-bucket value representing this instance's persistent state.
  (message serde-state [self : Self] : Any)
  # Reconstruct from that state. Dispatches on the type value, not an
  # instance: (SomeType ~ serde-restore state).
  (message serde-restore [t : Type, state : Any] : Any))
```

- A type implementing `Serde` serializes as
  `(serde/inst <type-ref> (serde-state self))` and deserializes via
  `(T ~ serde-restore state)` — the place to drop transient fields (sockets,
  caches) and re-derive them.
- **`serde-restore` executes user code, so it is off by default.** Plain
  `serde/read` raises `SerdeError` on an instance whose type demands a
  restore hook; `^policy (SerdePolicy ^allow-restore true)` enables it for
  trusted persisted state. Untrusted input should never enable it — direct
  field construction is the safe path.
- Types not implementing `Serde` get the default field-wise behavior; if any
  field value is bucket-3, serialization fails with the field's path.

**Cell snapshots (full `write` only).** `serde/write` may emit
`(serde/snapshot-cell v)` for a cell it encounters, and `serde/read`
reconstructs a fresh cell around the deserialized contents. This is
explicitly *outside* the equality guarantee (identity is not preserved, and
sharing is not preserved — two references to one cell become two cells) and
is rejected by `read-data`. Payload authors who care should model state as
data instead.

**Named-value references, narrowed.** `serde/value-ref` (identity semantics:
read-back yields the module's own object) is *not* emitted for arbitrary
module-level bindings — a module global may be mutable state, a native
handle, or a cache, and a broad ref mechanism would smuggle identity and
state through data. A binding qualifies only if **all** of:

- it has origin metadata (module-level, tagged at load);
- it is immutable and hash-stable, **or** its type implements the empty
  marker protocol `SerdeRef` (the owner's explicit opt-in);
- it is not a capability, native handle, or otherwise bucket-3 value.

Anything else serializes as a snapshot if its type allows (§7 instance path)
or fails with a clear error. Value refs land in the final stage (§12).

## 8. Resource limits (`SerdePolicy`)

`read-data` on a network payload is an attack surface even with no code
execution: interned symbols persist for the process lifetime (a payload
minting millions of unique symbols is a memory DoS), and big ints, byte
literals, deep nesting, and giant containers all cost resources at parse
time. Both readers take a policy with conservative-by-default screws, the
generalization of `json/parse`'s existing depth cap:

```gene
(serde/read-data text ^policy (SerdePolicy
  ^max-bytes   10485760    ; input size
  ^max-nodes   100000      ; total values constructed
  ^max-depth   1000        ; nesting
  ^max-symbols 10000))     ; distinct symbols interned per read

(serde/read text ^policy (SerdePolicy
  ...as above...
  ^allow-restore false))   ; §7; module loading is a capability, not a flag (§6)
```

Defaults are generous enough that trusted local use (config files, the
gateway's own sqlite rows) never notices them; network-facing callers tighten
them. Exceeding any limit is a `SerdeError` naming the limit.

## 9. API surface

A `serde` namespace in `src/gene/stdlib.nim`, beside `json`:

```gene
(import serde [write-data read-data write read data? SerdeError SerdePolicy])

(serde/write-data value)                 ; -> Str (data bucket only)
(serde/read-data text)                   ; -> Any (no resolution, no hooks)
(serde/read-data text ^policy p)
(serde/write value)                      ; -> Str (data + refs + instances
                                         ;         + snapshot-cells)
(serde/read text)                        ; -> Any (resolve vs loaded modules;
                                         ;         no user code executed)
(serde/read text ^policy p)              ; may enable ^allow-restore
(serde/data? value)                      ; -> Bool
```

Round-trip guarantee: `(= v (read-data (write-data v)))` under structural
equality for **every** data-bucket value — no exceptions, which is exactly
why cells are not in the bucket and reserved heads are escaped.

## 10. Driving use cases (in implementation order)

1. **Gateway persistence (ai-agent §12 milestone 11).** Session transcripts
   and event logs are pure data (maps/lists/strings/ints). `write-data` into
   a sqlite TEXT column via the existing `db/sqlite` backend; `read-data` on
   gateway restart. Needs only §4 — this is why data serdes ships first.
2. **Send-safe messaging.** Replace the gateway's JSON-string channel
   workaround; any mutable-map payload crosses channels/actors as
   `(write-data v)`.
3. **Actor state snapshots.** `actor/snapshot` already exposes state as a
   value; `write-data` makes it durable, enabling stop/restore across
   process restarts for actors whose state is data.
4. **Typed instances and refs** (§5–§7) as the config/document story: read a
   `.gene` data file whose nodes reconstruct as typed instances with
   validation but without executing arbitrary code.
5. **Application persistence & resume.** The durable-store and crash-resume
   layer above this format — `serde/write`/`read` are its encode/decode, the
   §7 `serde-state`/`serde-restore` hooks are its per-type resume primitive.
   Designed in docs/proposals/persistence.md.

## 11. Non-goals (first version)

- Binary or size-optimized encodings; streaming/incremental serialization.
- Closure/generator/continuation serialization (would require the fiber
  continuation format, which is deliberately private).
- Shared-structure/cycle preservation (error now; labels are a compatible
  later extension inside `serde/v1`).
- Schema migration hooks (`^schema-version` and `SerdeMigrate` reserve the
  space).
- Package/version identity in refs (`^package`/`^version` reserved).
- Module loading during `read` (post-MVP, and only behind a module-load
  capability).
- Preserving capability authority, ever — permanent non-goal, not a staging
  decision.

## 12. Staged plan

1. **`serde` data core, complete.** `write-data`/`read-data`/`data?` +
   `SerdeError` + `SerdePolicy` limits, implemented as a validating walk over
   the existing printer/reader (no forked grammar). Includes from day one:
   reserved-head escaping (`serde/data-node`), float specials
   (`serde/float`), cycle detection, and mechanical rejection of all other
   control tags. Spec tests: round-trip per kind (symbols, chars, sets,
   dates/times/timezones/durations, ranges, regex source+flags, bytes, big
   ints, nested mutable containers, `void`, float specials, **nodes with
   `serde/*` heads**), bucket-3 rejection with paths (cells included), cycle
   detection, every policy limit, envelope versioning.
2. **Gateway persistence on top** (proves the API against sqlite; ai-agent
   milestone 11).
3. **Origin tagging + typed refs.** Loader stamps definitions; `write` emits
   type/protocol/enum/variant/fn/ns refs; `read` resolves against loaded
   modules only. Spec tests: ref round-trip per kind, unresolved-module
   error, builtin path-only refs, unknown-ref-prop rejection
   (`^package`/`^version` reserved), no-code-execution property.
4. **Typed instances via direct construction.** No hooks. Spec tests: ctor
   is *not* run on read-back; field validation failures surface as
   `SerdeError`; `^schema-version` accepted and exposed.
5. **`Serde` hooks behind policy.** `serde-state`/`serde-restore`
   (type-receiver dispatch), `^allow-restore` gating, `serde/snapshot-cell`
   in full write. Spec tests: hooks refused without policy; transient-field
   reconstruction; snapshot-cell excluded from `read-data`.
6. **Narrowed value refs.** `SerdeRef` marker protocol + qualification rules
   (§7). Spec tests: mutable/unmarked globals refuse to ref; identity
   semantics for qualified constants.

Each stage lands with the repo's usual gates (`nimble test` / `spec` /
`perf` / `wasm`); serialization sits off the dispatch hot path, but stage 3's
origin tagging must show no regression on module-load-heavy benchmarks, and
nothing in any stage may add fields to the NaN-boxed `Value` itself.
