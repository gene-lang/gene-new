# Reader and value contract

**Status:** normative and implemented. Executable coverage:
`tests/spec_runner.nim`, suites “reader surface”, “value spread”, “templates”,
“strings”, “hashable collections”, and “equality and identity”.

- A source unit contains zero or more forms; `readAll` preserves every form.
- Datum comments are spacing and discard exactly the next datum.
- `#` dispatch is closed: `#(`/`#[`/`#{` open immutable literals, `#"` opens a
  regex, `#B#` / `#B16#` / `#B64#` introduce byte literals, `#Ref` / `#Deref`
  address module references, `#@` wraps two forms, `#_` is a datum comment,
  `#<` opens a block comment, and a line
  comment requires whitespace, `!`, or end of line/input after the `#`. Every
  other `#` sequence (`#a`, `#1`, `##`, …) is a read error reserved for future
  reader syntax.
- Reader prefixes, slash paths, interpolation, props/meta flags, immutable
  literals, and malformed-input behavior follow the reader suites.
- `%expr` reads as `(unquote expr)` in vectors as well as other expression
  positions; `%items...` reads as `(unquote (... items))`. Quote preserves this
  normalized syntax as data, so `(quote [%x])` contains one unquote node.
  Formatting and reparsing preserve the same structure and quotation depth.
- Interpolation reads as an ordinary `gene/to_str` call: `$"a${b}c"` is
  `($to_str "a" b "c")`. `$to_str` abbreviates `gene/to_str`, whose variadic
  arguments are evaluated eagerly in order and displayed without separators.
  No arguments produce an empty string. A bare `$` has no built-in binding or
  operator behavior.
- A glued leading slash is a Path literal. A glued non-leading path is a
  context-neutral path classified by the compiler. A delimited `/` is a normal
  symbol.
- `/.P:m` reads as a Path with a qualified message segment; `P:m` without the
  leading slash reads as a Message value. A Path containing a literal key that
  begins with `.` uses `$key` in its explicit constructor.
- A path or dot-message token cannot directly follow `)`, `]`, or `}` without
  whitespace. This includes immutable literals and general Maps. Write
  `(/a (g))` or `((g) .size)`, rather than `(g)/a` or `(g).size`. Whitespace
  preserves separate forms: `(g) /a`. Bare `/` and `//` operators and the `...`
  spread are unaffected. Interpolation uses the same rule.
- Ordinary `^prop` and `@meta` require values; `^^flag` and `@@flag` mean true.
- `;` folds the preceding segment into the next segment's head and never
  substitutes `_`.
- `->` and `=>` preserve a single-form initial expression plus ordered,
  separately owned stages in syntax-only `vkPipeline`. `=>` marks a per-item
  stage that prepares once and returns a lazy Stream in every position.
  Consumption is explicit and does not change the reader representation.
  Parenthesized `#(...)` retains its immutable syntax marker without becoming
  quoted or inert. A multi-form leading segment, an empty stage, duplicate direct `_`
  slots, and same-depth `;`/arrow mixtures are read errors; `->` and `=>` mix,
  and nested forms are independent.
- A `Value` occupies one machine word and zero initialization is `nil`.
- Default structural equality and hash ignore meta. A nominal Type with sealed
  `ValueEq`/`ValueHash` witnesses may define different value semantics on the
  native VM. `same?` is scalar identity by
  value and heap/container identity by reference.
- `props`, `body`, and `meta` return detached shallow snapshots. Nested values
  retain identity. Deep freeze, Send checks, and serialization traverse meta.
- `#Ref name value`, `#Deref name`, `$ref`, and `$deref` share a module-owned
  reference namespace distinct from lexical variables. Forward structural
  fixups preserve shared identity. Mutable cell cycles are supported; cycles
  made only of immutable structural containers are rejected. Serde rejects
  cyclic values rather than publishing an incomplete graph.

See the [language guide](../language.md#values-and-bindings) for ordinary syntax
and `tests/test_reader.nim` / module-reference suites for exact reader cases.

## Two-form wrapping prefix

`#@ head argument` reads exactly two complete forms and produces the same
ordinary node as `(head argument)`, including normal reader normalization.
It is valid wherever an expression is expected: call heads/arguments, lists,
map keys/values, property or metadata values, defaults, and interpolation.
Operands use expression parsing even inside a flat list/parameter vector.

Whitespace after the marker is optional; newlines, comments, and comma
separators do not change operand count. Nested prefixes associate naturally:
`#@f #@g x` reads as `(f (g x))`. `#@f x y` leaves `y` for the enclosing
context. The reader never consults callee arity or consumes the rest of a line.

Both operands are required. EOF while waiting for an operand is incomplete
input; an enclosing closer or a property/meta/pipeline separator in its place
is a reader error. Use parentheses for named-property or multi-argument calls.
`# @...` retains its existing line-comment meaning.

Quote keeps the expanded node as data. Compilation, evaluation order, errors,
and return values follow the corresponding ordinary form; the prefix does not
make println value-preserving. No runtime wrapper type or metadata is added.
Source provenance lets the formatter preserve authored `#@` and format its
operands, while canonical value printing uses ordinary node notation.

Coverage: `tests/test_reader_wrap.nim`, source-index/LSP/CLI tests, and shared
`reader_wrap.*` VM/web fixtures.
