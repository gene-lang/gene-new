# Brief: generate 1000 Gene corpus examples

You are generating training-corpus examples for the reversible AI-native
program format study (`docs/proposals/reversible-ai-native-program-format.md`).
Read this whole file before writing any code. Work in
`/Users/gcao/gene-workspace/gene-new`.

## What to produce

**1000 example pairs** under `training/corpus/generated/<family>/`:

```
training/corpus/generated/list_ops/reverse_pairs.gene       a small program
training/corpus/generated/list_ops/reverse_pairs.expected   its exact stdout
```

The `.expected` file holds the program's exact stdout, byte for byte,
including the trailing newline. It is not decoration: `gene test` is
package-level, so a loose corpus file cannot declare tests, and this
deterministic stdout oracle is the *only* thing that makes the study's
semantic gates measurable. An example without a correct `.expected` is worse
than no example, because it will be scored as a model failure later.

## The 15 task families

Use exactly these directory names, roughly 67 examples each:

`list_ops`, `string_ops`, `arithmetic`, `map_ops`, `recursion`,
`higher_order`, `control_flow`, `data_modeling`, `protocols`,
`error_handling`, `streams`, `sorting_searching`, `text_formatting`,
`state_machines`, `parsing`

Families are not cosmetic. The study's train/validation/test split must hold
out whole semantic clusters, not random files, so a family is the unit that
gets held out. Two consequences:

- An example must belong to exactly one family and be *representative* of it.
- Families must not be near-duplicates of each other. If `list_ops` and
  `streams` end up solving the same problems the same way, the holdout stops
  measuring generalization.

## Hard requirements

Every example must pass:

```bash
training/validate_examples.sh training/corpus/generated bin/gene
```

which checks four things per example, in this order:

1. `gene compile` succeeds (macro expansion, name resolution).
2. `gene run` exits 0 and stdout matches `.expected` **exactly**.
3. `gene docpack` succeeds — the durable format v0 must be able to encode it.
4. `gene docunits --decode` reproduces the canonical text exactly.

Check 2 is strictly stronger than check 1 and catches the mistakes that
matter. Do not skip running an example because it "obviously" compiles.

Build the binary first if `bin/gene` is missing or stale:

```bash
nim c -d:release -o:bin/gene src/gene.nim
```

## Size and shape

- **Keep each example small: 10–50 lines.** This is a real constraint, not a
  style preference. The existing corpus's median document is ~4,700 logical
  units, which makes whole-document generation impossible to evaluate. Small
  documents are the point of this batch.
- Self-contained: no imports of other generated files, no filesystem, no
  network, no clock, no randomness. Output must be deterministic.
- Print something. An example that computes silently gives the oracle
  nothing to check.
- Prefer several small `$println` calls over one giant one, so a partial
  failure is visible.

## Value kinds you must avoid

Durable format v0 cannot encode these, so an example containing one is
rejected at check 3:

- regex literals (`#"..."`)
- date, time, datetime, timezone, duration literals
- ranges
- integers outside int64

Everything else is fair game: nil, void, bool, int, float, string, bytes,
char, symbol, node, list, map, hash-map.

## Gene gotchas that will bite you

These are real, and several are things a Lisp/Clojure reflex gets wrong.
`docs/design.md` is the contract; `examples/style_guide.gene` models style.

- **Remainder is `//`, not `%` or `mod`** (design §7.4). `%` is unquote
  sugar, so `(% x 2)` *compiles fine* and fails at runtime with
  "undefined symbol: unquote". This is the single most likely mistake.
- **`~` is the message-send operator and needs spaces**: `(obj ~ method)`.
  Glued to a word (`~size`) it is one ordinary symbol, which is what a path
  send segment like `xs/~size` desugars to.
- **A `%` path stage takes a name, not an expression.** `xs/%i` is fine;
  `xs/%(- i 1)` is a read error — bind the index first.
- **snake_case everywhere.** Never hyphens in a name.
- **Control flow style** (CLAUDE.md is explicit about this):
  - Never write an explicit `nil` arm in `if`. `(if cond value)` already
    yields `nil` on the false path.
  - Use `(if_not cond body...)`, not `(if cond nil ...)`.
  - Use `(if_yes cond body...)` for a multi-expression guard.
  - Reserve `then`/`elif`/`else` for branches that all do real work, and
    never wrap a compact branch in `do`.
- Bind with `(var x 1)`, reassign with `(set x 2)`. Don't redeclare a name
  in a loop; allocate mutable state once and update it.
- Use string interpolation `$"a${x}b"` rather than `($ "a" x "b")`.
- Stdlib is reached with `$`: `$println`, `$str/join`.

When unsure of a form, write a three-line probe and run it. Do not guess and
do not invent syntax that "looks Lisp-ish".

## Diversity

Dedup is by packed-document sha256, so byte-identical files collapse
silently — but *near*-duplicates are the real risk and nothing catches them.
Deliberately vary:

- the constructs used (loops vs recursion vs higher-order functions),
- data shapes (flat lists, nested maps, records, mixed types),
- sizes and edge cases (empty input, single element, duplicates, negatives),
- naming and comment density — some examples with no comments, some with a
  header comment, some with trailing comments on lines.

Comment density matters specifically: comments are what the durable format
exists to preserve, and the corpus needs stratification across it.

## Process

Work in batches of ~50, and do not let errors accumulate:

1. Write ~50 pairs into one family directory.
2. Generate each `.expected` by **running** the program and capturing real
   stdout — never by predicting output by hand.
3. Run the validator on that directory.
4. Fix every failure before starting the next batch. If a whole class of
   example fails, fix the class, not the instances.
5. Keep a running note of families completed.

At the end, run the validator over the whole tree and report:

- total examples, passes, failures,
- per-family counts,
- any construct you wanted to use but could not, and why.

Then build the corpus and confirm it flows through the real pipeline:

```bash
python3 training/build_corpus.py --gene-bin bin/gene \
  --source-dir training/corpus/generated --out training/corpus/gen_out
```

Report the accepted/duplicate/rejected counts from that run too. A large
duplicate count means the diversity requirement was not met.

## What not to do

- Do not edit anything outside `training/corpus/generated/` (and the report
  you write at the end). In particular do not modify `src/`, `tests/`,
  `docs/`, or any other `training/` file — another session owns those.
- Do not commit anything.
- Do not hand-write an `.expected` file.
- Do not lower a requirement to make an example pass. Delete the example
  instead and write a different one.
