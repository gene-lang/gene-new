# Gene Serialization (serde) — Design

Status: **designed; not implemented.** Date: 2026-07-08.

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
- **Typed-error precedent**: `json/parse` raises `JsonError` with `^message`;
  `serde` follows the same shape with `SerdeError`.
- **Prior-art gap**: there is no serdes module at all today. The nearest
  facility is `json/stringify`, which handles only JSON-shaped data (maps,
  lists, scalars) and loses Gene-specific kinds (symbols, chars, sets, dates,
  nodes, types).

## 2. Format: versioned Gene text

Serialized output is ordinary Gene source, wrapped in a version envelope:

```gene
(serde/v1
  {^session "tg-42"
   ^items [{^role "user" ^content "hello"} ...]})
```

- One top-level `serde/v1` node; its single child is the payload. Future
  format changes bump the head symbol — readers dispatch on it.
- The payload parses with the ordinary reader; `serde/read` is the reader
  plus a validating walk and reference resolution (§6). A human can read,
  diff, and edit the output; `bin/gene fmt` normalizes it.
- Encoding is UTF-8 text. Binary efficiency is a non-goal (§10); `vkBytes`
  values print in their literal byte-string form.

## 3. Three buckets

Every value falls into exactly one:

1. **Data** — scalars and containers of data. Serialized by value (printed),
   deserialized by construction. No environment needed to read back.
2. **Named definitions** — types, protocols, enums, enum variants, functions
   (`fn`/`fn!`), namespaces, and module-level named values. Serialized as
   **typed references** (§5); deserialization resolves them against loaded
   modules under an explicit policy (§6).
3. **Not serializable** — values that are inherently process-bound. Attempting
   to serialize one raises `SerdeError` naming the offending value and its
   path within the payload (e.g. `"at items/3/handler: functions with
   captured scope do not serialize"`).

Bucket 3 is load-bearing and gene-new-specific in places:

| Value | Why not |
|---|---|
| **Capability values** (`Os/Exec`, `Fs/*`, `Net/Connect`, `Ffi/Load`, ...) | Authority must never round-trip through data. A deserialized payload must not be able to mint capabilities (§6). |
| Closures (fns with captured scope), `fn!` values | Captured scopes reference live scope chains; snapshotting them is the actor-snapshot problem, out of scope here. Top-level named fns serialize as refs (bucket 2). |
| Channels, tasks, actor refs, streams/generators | Live scheduler state. `actor/snapshot` output (a data value) serializes fine; the actor itself does not. |
| Native handles (`db` connections, `CPtr`, FFI libraries, HTTP servers) | Process-bound resources. Types owning them can opt into reconstruction hooks (§7). |
| `Env` values | Binding environments are execution state, not data. |

## 4. Data serdes (`serde/write-data` / `serde/read-data`)

The data bucket accepts:

- scalars: `nil`, `void`, booleans, ints (including big ints), floats, chars,
  immutable strings, symbols, bytes, dates, datetimes, durations;
- containers: lists, maps, sets, and nodes whose head is a symbol or a
  serializable ref — recursively, all contents must be data.

Two deliberate divergences from Send-safety:

- **Mutability does not matter.** Send rejects mutable maps because sharing
  them races; serialization is a snapshot by construction — the text cannot
  alias the original. Mutable containers serialize; reading back produces
  fresh mutable containers. (This directly fixes the awkwardness that forced
  the agent gateway's Telegram outbox to hand-serialize event maps to JSON
  strings before `Channel/send` — `serde/write-data` is the idiomatic form of
  that workaround, and a later `Channel` integration could apply it
  implicitly.)
- **Cells serialize as snapshots**, printed as `(serde/cell v)`. Identity and
  sharing are *not* preserved: two references to one cell deserialize as two
  cells. This is documented snapshot semantics, same as `actor/snapshot`.
  Payloads that need shared mutable state should model it explicitly.

**Cycles are an error** (`SerdeError`, with the cycle path). The MVP does not
emit shared-structure labels; if a real need appears, `(serde/shared N ...)` /
`(serde/ref-shared N)` can be added inside the same envelope version.

`serde/data? : Any -> Bool` reports whether a value is in the data bucket
without serializing it.

## 5. Named definitions: typed references

Definition-like values serialize as reference nodes carrying two coordinates:

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

**Origin tagging.** To emit refs, definition values must know where they came
from. At module load, after a module's top-level forms run, the loader walks
the module scope and stamps each taggable value (types, protocols, enums,
fns, namespaces, and module-level bindings whose value is one of those) with
`(module, path)` origin. Values defined at the REPL, inside function bodies,
or anonymously have no origin and are bucket 3 for reference purposes — a
type created at runtime can still have its *instances* serialized if the type
itself is resolvable, otherwise instance serialization fails with a clear
error. Tagging is once per module load, additive, and does not affect the
value-layout hot path (origin lives on the heap object payloads, not in the
NaN box).

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
  It is the default and covers the primary use cases (§8).
- `serde/read` resolves references **only against already-loaded modules**
  (the module cache) plus built-ins. A ref to an unloaded module raises
  `SerdeError ^unresolved` listing the module, so the caller can import it
  first — in ordinary code, by writing the `import` at the top of the file,
  which is both the policy and the audit trail.
- Optional escape hatch: `(serde/read s ^import [list of module paths])`
  pre-imports an explicit allowlist before resolving. There is no
  "auto-import whatever the payload mentions" mode. If a future deployment
  wants one, it must arrive as a distinct capability value gating module
  loading, not as a flag.
- Deserialized payloads can never contain capability values (§3), so a
  payload cannot smuggle authority regardless of resolver policy.

Resolution failures, arity/shape mismatches, and version-envelope mismatches
are all `SerdeError` with `^message` and, where applicable, `^unresolved` /
`^path` props — the `JsonError`/`UrlError` pattern.

## 7. Instances: direct construction, protocol hooks for the exceptions

An instance of a user type serializes as an **instance node**: the canonical
`(T ...)` form with the head replaced by a ref, props/body recursively
serialized:

```gene
(serde/inst (serde/type-ref ^module "examples/geometry" ^path "Point")
  ^x 10.0 ^y 20.0)
```

Deserialization resolves the head and applies **direct typed-data
construction** — the `(T ...)` path that validates fields and stamps the head
but *does not run `ctor`*. This is exactly the semantics design.md prescribes
for representing "the value that exists, not the process that produced it".
No blind property copying (the old design's fallback): field validation runs,
unknown fields are rejected, and required fields are enforced.

Two protocol hooks cover types whose state is not their fields:

```gene
(protocol Serde
  # Return a data-bucket value representing this instance's persistent state.
  (message serde-state [self : Self] : Any)
  # Reconstruct from that state. Type-direct message: receives the type.
  (message serde-restore [state : Any] : Self))
```

- A type implementing `Serde` serializes as
  `(serde/inst <type-ref> (serde-state self))` and deserializes via
  `serde-restore` — the place to drop transient fields (sockets, caches) and
  re-derive them, mirroring the old design's `.deserialize` hook but typed
  and symmetrical.
- Types not implementing `Serde` get the default field-wise behavior; if any
  field value is bucket-3, serialization fails with the field's path. A
  db-connection-holding type either implements `Serde` or does not serialize.

**Identity vs snapshot**: a module-level named instance (tagged with an
origin, §5) serializes as `serde/value-ref` — identity semantics; reading it
back yields the module's object. Untagged instances serialize as `serde/inst`
snapshots. This matches the old design's split, with tagging as the
discriminator instead of ad-hoc registry lookups.

## 8. API surface

A `serde` namespace in `src/gene/stdlib.nim`, beside `json`:

```gene
(import serde [write-data read-data write read data? SerdeError])

(serde/write-data value)                 ; -> Str (data bucket only)
(serde/read-data text)                   ; -> Any (no resolution, no policy)
(serde/write value)                      ; -> Str (data + refs + instances)
(serde/read text)                        ; -> Any (resolve vs loaded modules)
(serde/read text ^import ["a/b" "c/d"])  ; explicit pre-import allowlist
(serde/data? value)                      ; -> Bool
```

All errors are `SerdeError ^message m` (plus `^path` locating the failure in
the payload, `^unresolved` for module misses). Round-trip guarantee for the
data bucket: `(= v (read-data (write-data v)))` under structural equality,
for every data value — this is the primary spec-test axis.

## 9. Driving use cases (in implementation order)

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

## 10. Non-goals (first version)

- Binary or size-optimized encodings; streaming/incremental serialization.
- Closure/generator/continuation serialization (would require the fiber
  continuation format, which is deliberately private).
- Shared-structure/cycle preservation (error now; labels are a compatible
  later extension inside `serde/v1`).
- Cross-version migration hooks (`serde/v1` envelope reserves the space).
- Preserving capability authority, ever — permanent non-goal, not a staging
  decision.

## 11. Staged plan

1. **`serde` data core.** `write-data`/`read-data`/`data?` + `SerdeError`,
   implemented as a validating walk over the existing printer/reader (no
   forked grammar). Spec tests: round-trip per kind (including symbols,
   chars, sets, dates, bytes, big ints, nested mutable containers, `void`),
   bucket-3 rejection with paths, cycle detection, envelope versioning.
2. **Gateway persistence on top** (proves the API against sqlite; ai-agent
   milestone 11).
3. **Origin tagging + typed refs.** Loader stamps definitions; `write` emits
   refs; `read` resolves against loaded modules; `^import` allowlist. Spec
   tests: ref round-trip for type/protocol/enum/variant/fn/ns, unresolved-
   module error, builtin path-only refs.
4. **Instance nodes + `Serde` protocol.** Direct-construction deserialize,
   `serde-state`/`serde-restore` hooks, identity-vs-snapshot via tagging.
   Spec tests: ctor is *not* run on read-back; transient-field
   reconstruction; validation failures surface as `SerdeError`.

Each stage lands with the repo's usual gates (`nimble test` / `spec` /
`perf` / `wasm`); serialization sits off the dispatch hot path, but stage 3's
origin tagging must show no regression on module-load-heavy benchmarks, and
nothing in any stage may add fields to the NaN-boxed `Value` itself.
