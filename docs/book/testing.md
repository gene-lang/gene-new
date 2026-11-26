# Testing

This chapter checks assumptions with assertions, writes test examples
grouped with `describe` and `it`, shares setup through fixtures, and runs
tests with `gene test`.

## Assertions

`$assert` checks a condition. It returns `nil` when the condition holds, and
otherwise raises an `AssertionFault` with the message, or with
`assertion failed` when there is none:

```gene runnable
(let count 3)
($assert (== (+ 1 1) 2))
($assert (> count 0) "count must be positive")
# nil
```

The condition uses ordinary truthiness, so `0` and `[]` pass. Compare
explicitly when a value must be exactly `true`. Assertions are always
enabled.

`$test` adds two helpers that work anywhere:

```gene runnable
(import $test/[assert_equal assert_raises])
(assert_equal (+ 1 1) 2)
(let error (assert_raises (fn [] ($assert false)) AssertionFault))
error/.message
# "assertion failed"
```

- `assert_equal actual expected` compares with `==`. A failure reports both
  values.
- `assert_raises thunk Type` calls the function once and returns the error it
  raises, for further checks. It fails if nothing is raised, and lets an
  error of another type through unchanged.

## Writing examples

A spec file groups examples with `describe` and declares each one with `it`.
Its name ends in `_spec.gene`, and it usually lives under `tests/`:

```gene
# tests/list_spec.gene
(import $test/[assert_equal assert_raises before_each context describe it])

(describe "a list"
  (before_each [t]
    (set t/items []))

  (it "starts empty" [t]
    ($assert t/items/.empty?))

  (context "after adding an item"
    (before_each [t]
      (t/items .push 7))

    (it "contains that item" [t]
      (assert_equal t/items [7]))

    (it "is skipped for now" [t] ^skip "waiting on sort"
      (assert_equal t/items [0]))))
```

- `context` groups exactly as `describe` does. It reads better for a
  scenario.
- An example's parameter list is `[]`, or `[t]` to receive the fixture.
  Hooks take the same list.
- `^skip "reason"` skips an example, with a reason that is required.
- An example passes when it finishes without raising. Its value is ignored,
  so returning `false` is not a failure; assert instead.

## Fixtures

Each example gets a fresh, empty property map, `t`, which its hooks and body
share. For each example, the runner:

1. runs each enclosing group's `before_each` hooks, outermost group first;
2. runs the example's body, if setup succeeded;
3. runs the `after_each` hooks, innermost group first, even when setup or the
   body failed.

Values captured from the module or a group are shared between examples. The
runner does not reset them, so put per-example state in `t`.

## Running tests

`gene test` finds every `tests/**/*_spec.gene`, loads the files, and runs
their examples in declaration order:

```sh
gene test                          # every spec under tests/
gene test tests/list_spec.gene     # one file
gene test --name "adding an item"  # examples whose full name contains the text
```

```text
[passed] a list starts empty
[passed] a list after adding an item contains that item
[skipped] a list after adding an item is skipped for now (waiting on sort)
2 passed, 0 failed, 0 errors, 1 skipped
```

A failing `assert_equal` reports where it failed and both values:

```text
[failed] math adds
    example: values are not equal
      at tests/fail_spec.gene:4:5
      expected: 3
        actual: 2
```

- An example whose assertion failed counts as `failed`. One that raised
  anything else, such as an error from a hook, counts under `errors`.
- The exit code is `0` when everything passed, `1` when any example failed
  or a file failed to load, and `2` for bad usage or when nothing was
  selected.
- `gene test` does not call a file's `main`. `($test/run)` runs the
  registered examples from code and returns a `TestResult` with `passed`,
  `failed`, `errors`, `skipped`, and `exit_code`.

## Testing what documentation shows

A ` ```gene runnable ` block in the project's Markdown runs as part of the
project's test suite, so an example in the docs cannot quietly stop working.
Use it for examples that run on their own. Leave a fragment, or code with
side effects such as writing files, as a plain ` ```gene ` block.
