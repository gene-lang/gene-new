# Gene web-profile JavaScript ABI

Status: **implemented for the bounded web-profile value set.** Declared JS
externs use `js/fn` with a plain ESM `^from` specifier and optional `^import`
name. Every JS-facing Gene export, imported result, method, and callback is
guarded by generated validators; `.d.ts` is editor information, not a runtime
check.

| Gene | JS representation and boundary rule |
|---|---|
| `Nil` / `Void` | exactly `null` / `undefined` |
| `Bool`, `Str`, `Sym` | `boolean`, `string`, global/local JS `symbol` |
| `Int`, `F64` | exactly `bigint`, `number`; no implicit conversion |
| `(List T)` | Array, recursively validated; identity and shallow frozen state preserved |
| `PropMap` | ordinary non-array object |
| `(Map K V)` | `GeneMap`, recursively validated, structural keys, iterable entries |
| `Node`, `Range` | generated `GeneNode` / `GeneRange` instances |
| nominal type | generated class instance with closed-schema validation |
| enum | frozen tagged discriminated value |
| callback | checked wrapper validates every invocation and result |
| `Stream` | `GeneStream` pull/close contract |
| `Task` | `GeneTask`; cancellation stays a non-error control signal |
| union / optional | each member validator is tried; `T?` admits `null` |
| `Any` | JS `unknown`; validated when it later enters a typed position |

Lossless JSON is a portable Gene operation rather than `JSON.stringify` on
raw profile values: integer tokens parse to `bigint`, and the custom encoder
writes them as JSON integer tokens. Non-finite `F64`, cycles, and non-string map
keys are rejected.

Exceptions from JS retain their JavaScript identity. Gene typed catches match
only their declared patterns. `GeneCancellation` is rethrown before catch
matching, while `ensure`/`finally` always executes.

No object↔map, Promise↔Task, `number`↔`bigint`, or `null`↔`undefined` coercion is
implicit. Method overload sets and complex conditional/mapped TypeScript types
are outside the declared ABI. The DOM generator therefore consumes only its
explicit verified allowlist from pinned `lib.dom.d.ts`; unsupported shapes fail
generation instead of silently widening to `any`.
