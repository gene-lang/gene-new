# Reader and value contract

**Status:** normative and implemented. Executable coverage:
`tests/spec_runner.nim`, suites “reader surface”, “value spread”, “templates”,
“strings”, “hashable collections”, and “equality and identity”.

- A source unit contains zero or more forms; `readAll` preserves every form.
- Datum comments are spacing and discard exactly the next datum.
- `#` dispatch is closed: `#(`/`#[`/`#{` open immutable literals, `#"` opens a
  regex, `#_` is a datum comment, `#<` opens a block comment, and a line
  comment requires whitespace, `!`, or end of line/input after the `#`. Every
  other `#` sequence (`#a`, `#1`, `##`, …) is a read error reserved for future
  reader syntax.
- Reader prefixes, slash paths, interpolation, props/meta flags, immutable
  literals, and malformed-input behavior follow the reader suites.
- A glued leading slash is a selector literal. A glued non-leading path is a
  context-neutral path classified by the compiler. A delimited `/` is a normal
  symbol.
- Ordinary `^prop` and `@meta` require values; `^^flag` and `@@flag` mean true.
- `;` folds the preceding segment into the next segment's head and never
  substitutes `_`.
- `->` and `=>` preserve a single-form initial expression plus ordered,
  separately owned stages in syntax-only `vkPipeline`. `=>` marks a per-item
  stage: lazy before a later stage, a draining `each` when it is last.
  Parenthesized `#(...)` retains its immutable syntax marker without becoming
  quoted or inert. A multi-form leading segment, an empty stage, duplicate direct `_`
  slots, and same-depth `;`/arrow mixtures are read errors; `->` and `=>` mix,
  and nested forms are independent.
- A `Value` occupies one machine word and zero initialization is `nil`.
- Structural equality and hash ignore meta. `same?` is scalar identity by
  value and heap/container identity by reference.
- `props`, `body`, and `meta` return detached shallow snapshots. Nested values
  retain identity. Deep freeze, Send checks, and serialization traverse meta.

Canonical grammar and rationale remain in `docs/design.md` §§1–2; this file
states which portion is implemented and normative.
