# Corpus generation report

Generated per `training/GENERATION_BRIEF.md`. All examples live under
`training/corpus/generated/<family>/` as `.gene`/`.expected` pairs.

## Final validation

```
training/validate_examples.sh training/corpus/generated bin/gene
---
examples: 1002  passed: 1002  failed: 0
```

Every example passes all four checks: `gene compile`, `gene run` with exact
stdout match, `gene docpack`, and `gene docunits --decode` round-trip.

## Per-family counts

| Family | Examples |
| --- | --- |
| arithmetic | 67 |
| control_flow | 67 |
| data_modeling | 66 |
| error_handling | 67 |
| higher_order | 66 |
| list_ops | 67 |
| map_ops | 67 |
| parsing | 67 |
| protocols | 67 |
| recursion | 67 |
| sorting_searching | 67 |
| state_machines | 66 |
| streams | 67 |
| string_ops | 67 |
| text_formatting | 67 |
| **Total** | **1002** |

Three families (`data_modeling`, `higher_order`, `state_machines`) landed at
66 rather than 67 — one planned example in each turned out to duplicate
another example's construct closely enough that it was dropped rather than
padded back to 67 with a near-duplicate.

## Corpus pipeline run

```
python3 training/build_corpus.py --gene-bin <abs-path-to>/bin/gene \
  --source-dir training/corpus/generated --out training/corpus/gen_out

accepted:   1002  (train=802 validation=67 test=133)
duplicates: 0
rejected:   0
```

Zero duplicates and zero rejections confirm the diversity requirement was
met and every accepted example is durable-format v0 encodable.

(Note: `build_corpus.py`'s `--gene-bin` must be an absolute path — a
relative path like `bin/gene` fails with `FileNotFoundError` because the
script's subprocess calls do not consistently run from the invocation
directory. This is a pre-existing script quirk, not something this task
was authorized to fix, since the brief restricts edits to
`training/corpus/generated/` and this report.)

## Constructs I wanted to use but could not

- **Regex literals (`#"..."`), date/time/duration literals, range literals,
  and integers outside int64** — all explicitly banned by durable-format
  v0 (`gene docpack` check 3). No workaround needed since the brief
  anticipated this; every family that would naturally reach for one of
  these (parsing, arithmetic) used manual string scanning or bounded
  loops instead.
- **Built-in `sort`/`reduce`/`fold`/`str/upper`/`str/replace`/`str/reverse`**
  — none exist in the current stdlib. Every `sorting_searching` example
  implements a real algorithm (bubble/selection/insertion/merge/quicksort/
  binary search) manually via `List/set`+`List/get`-by-selector, and every
  `higher_order` example implementing "reduce" builds its own accumulator
  loop or small recursive helper.
- **Lexicographic string comparison via `<`/`>`/`<=`/`>=`** — these
  operators reject `Str`/`Char` operands outright ("expects numbers, got
  vkString"). String-sorting/binary-search examples had to carry a
  hand-written `char_code`/`str_lt?` helper (byte-by-byte comparison via
  `$str/to_utf8`) instead.
- **Bare protocol message sends** (`(x ~ message)` for a `protocol`
  message) — contrary to `docs/design.md` §10's examples, the current
  binary requires the qualified form `(x ~ Protocol:message)` even with a
  single unambiguous `impl`. All 67 `protocols` examples use the qualified
  form throughout.
- **`push!`/`set!`/`put!`-style bang-suffixed mutators** — the repo's `src/`
  changed mid-session (commit `c8af3c3`, "Redesign syntax calls as
  explicit fexprs") while this corpus was being generated, reserving
  trailing `!` exclusively for fexpr declarations and renaming every
  mutator without the bang (`push`, `set`, `put`, `set_prop`, `set_body`,
  `push_body`). All examples use the post-redesign bangless names; none
  define a custom fexpr since this corpus had no reason to.
- **`$chars`/`$graphemes` feeding straight into `$str/join`** — `$str/join`
  requires `Str` items and rejects `Char`, so per-character string work
  goes through `$str/slice_bytes` instead of `$chars`.

## Other correctness notes

Several `.gene` programs initially computed a subtly *wrong* answer while
still running cleanly and producing *some* output — since `.expected` is
captured from a real run, a validator pass alone cannot catch this class of
bug; it was caught only by manually re-deriving the expected numeric
answer for each example. The most common cause was confusing `//`
(remainder) with `/` (truncating integer division) — Gene's `//` is *not*
Python's floor-division. Every discovered instance (binary-search
midpoints, a "how many 5000-mile intervals" check, an RGB brightness
average, and one outright-nonsense evenness check in a `list_ops` example)
was corrected and re-verified against hand-computed expected values before
being counted as passing.
