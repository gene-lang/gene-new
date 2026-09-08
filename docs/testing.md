# Assertions and unit testing

Gene provides a standalone `$assert` function and RSpec-style example groups
under `$test`. Both are implemented in the native VM. Try the complete
[testing demo](../examples/testing_demo.gene):

```sh
gene test examples/testing_demo.gene
```

## 1. Standalone assertions

```gene runnable
(let count 3)
($assert (== (+ 1 1) 2))
($assert (> count 0) "count must be positive")
#@$assert (== (+ 1 1) 2) # nil
```

`gene/assert`, available as `$assert`, has this callable contract:

```gene
# Signature; implementation omitted.
(fn assert [condition : Any message : Str?] : Nil
  ^errors [AssertionError]
  ...)
```

- Assertions use ordinary Gene truthiness: `false`, `nil`, and `void` fail; other
  values, including zero and empty collections, pass. Use an explicit comparison
  when testing for exactly `true`.
- An assertion returns `nil` on success. On failure, it raises `AssertionError`, a built-in nominal
  type implementing `Error`. An omitted or nil message means `"assertion failed"`.
- This is an ordinary eager function. Arguments run once, in normal call
  order; the optional message expression also runs on success. Errors raised
  while evaluating either argument propagate unchanged.
- Assertions remain enabled in every build mode and work without `$test`.
  They follow ordinary checked-error rules: a function with an explicit error
  row must admit `AssertionError` if it can escape.
- Failures carry the assertion call's source location and normal stack information
  when available. The function receives values, not the original condition's
  syntax. Calling through an alias behaves normally.

`#@` remains reader sugar: the third example expands to an ordinary `$assert`
call. An assertion does not return its input for use in a value pipeline.

## 2. Writing examples

Use familiar grouping and example names, with Gene parameter lists for the
deferred bodies:

```gene
# tests/list_spec.gene
(import $test [describe context it before_each assert_equal run])

(describe "a list"
  (before_each [t]
    (set t/items []))

  (it "starts empty" [t]
    ($assert (== t/items [])))

  (context "after adding an item"
    (before_each [t]
      (t/items .push 7))

    (it "contains that item" [t]
      (assert_equal t/items [7]))))

(fn main [args] : Int
  (let result (run))
  result/exit_code)
```

`describe` and `context` have identical grouping behavior; `context` makes
scenario descriptions read naturally. `it` declares one example. Its parameter
list is either `[]` or `[name]`, where `name` receives the fixture context.
Hooks use the same parameter-list convention.

These declaration forms are template macros expanding into ordinary registration
calls and closures. Group bodies execute during registration; example and hook
bodies execute only during the run. Expansion preserves authored locations and
uses ordinary lexical closures rather than runtime evaluation of caller syntax.

The closures retain normal lexical bindings and implementation visibility.
`return` inside an example returns from that example's closure; `break` and
`continue` require a loop inside that closure. A hook's local declarations are
local to its invocation; use `t` to share fixture values between hooks and an
example. No implicit receiver, injected variables, or special meaning for `let`.

## 3. Fixtures and execution order

The runner creates a fresh mutable property map `t` for each selected example,
passes that map to its inherited hooks and body, and releases it after cleanup.
Captured module/group variables are still shared; the runner does not clone
closures, reset modules, or undo external effects.

For each example:

1. Enter its groups from outermost to innermost. Run each group's `before_each`
   hooks in declaration order.
2. Run the example body if setup succeeded.
3. Run `after_each` hooks from innermost entered group to outermost, reversing
   declaration order within each group.

A group is entered immediately before its first setup hook, or before proceeding
into its child/body if it has no setup hooks. If setup raises a recoverable error,
skip the remaining setup and body, then clean up every entered group, including
the failing group. Cleanup must tolerate partially initialized fixtures.

An assertion or other recoverable error stops its current hook/body. A failing
cleanup hook does not prevent the remaining cleanup hooks from running; record
all failures with their phase and source locations. Continue with later examples.
Panic and cancellation retain Gene's unwinding and `ensure` behavior and abort
the run; ordinary error catching must not turn them into a passing example.

Run examples serially in declaration order, traversing nested groups where they
appear. An example passes when setup, body, and cleanup finish without an error.
Its returned value is ignored: returning `false` is not an assertion. Tasks must
be explicitly awaited/joined and Streams explicitly consumed; tests own their
task and resource cleanup. There is no implicit draining of returned values.

## 4. Assertion helpers

Two helpers in `$test` also work outside a running suite:

```gene runnable
(import $test [assert_equal assert_raises])

(assert_equal (+ 1 1) 2)
(assert_equal [1 2] [1 2] "items should match")
(let error (assert_raises (fn [] ($assert false)) AssertionError))
error/message # "assertion failed"
```

| Helper | Contract |
| --- | --- |
| `assert_equal actual expected message?` | Compare with the existing `==` semantics. Return nil on success; otherwise raise AssertionError carrying labeled actual and expected values. |
| `assert_raises thunk error_type message?` | Invoke an ordinary zero-argument callable once. Match an escaping error with the same type rules as `catch`; return the matching error for further checks. |

Both evaluate their arguments eagerly, once. `assert_raises` runs the thunk only
after its arguments have been evaluated and checked. Normal return, including
returning an error value without raising it, fails with `AssertionError`. An
unexpected recoverable error propagates unchanged so the runner reports its
actual cause. Panic and cancellation are not matched or suppressed.

These APIs use the same `AssertionError` type. `assert_equal` errors carry
`has_comparison`, `actual`, and `expected` properties, plus `actual_present` and
`expected_present` flags. These distinguish a captured `void` (whose property
can be removed by normal property rules) from unavailable details; `nil` remains distinct.
Reports render values without re-evaluating expressions, bound large output,
and show `<cycle>` for cyclic references.

## 5. Registration, runner, and reporting

The registry belongs to the Application. Loading a spec module registers its
groups and examples once under normal module-cache rules. Registration outside
an active group is invalid for `it` and hooks. Registration during a run is an
error. Group names and example descriptions are strings. Source locations and
the full nested description distinguish duplicate names.

`($test/run)` snapshots the registered tree, prints a readable report, and returns
a `TestResult` with `passed`, `failed`, `errors`, `skipped`, and `exit_code` fields
plus per-example results and run-level diagnostics. It does not exit the process.
A second run uses the same declarations with fresh fixtures; it does not reload
modules. `^name "text"` selects a substring of the full description;
`^report false` returns results without printing.

`examples` is a list of records with `name`, `status`, `location`, `diagnostics`,
and an optional skip `reason`. A diagnostic records `error_type`, `message`,
`phase`, `location`, and `assertion`. Available `actual`, `expected`, and `trace`
fields are bounded display strings captured when the failure occurs, before
cleanup can mutate the values. Results do not retain arbitrary fixture graphs.
The error raised by an assertion still carries the original comparison values.

- `failed`: an example had only assertion failures.
- `errors`: an example had an unexpected recoverable error, including a hook
  error. If it also had assertion failures, it counts once here while retaining all
  diagnostics.
- `skipped`: an explicitly skipped example; its hooks and body do not run.
  Use `(it "description" [] ^skip "reason" ...)`, with a nonempty literal reason.
- Per-example `status` is `passed`, `failed`, `error`, or `skipped`.
- A successful selection has exit code `0`. Any failed/errored example or module
  load/registration error gives `1`. Invalid CLI usage or an empty selection
  gives `2`. Show skipped counts even when the exit code is zero.

The report includes the nested example name, assertion/error location, message,
and available expected/actual values. Module load or registration failure aborts
collection and prevents execution of a partial suite. Panic/cancellation aborts
also produce a nonzero CLI exit.

`gene test` uses the normal package/module loader:

```sh
gene test                         # discover tests/**/*_spec.gene
gene test tests/list_spec.gene     # explicit file
gene test tests/ --name "a list"  # substring of full example description
```

Paths resolve from the launch directory. Files are canonicalized, deduplicated,
and sorted. Directory inputs select `*_spec.gene`; explicit file inputs accept
any `.gene` file. All selected modules load before filtering examples, without
invoking their `main` functions. Calling `run` at module top level during this
collection is an error. `gene run tests/list_spec.gene` invokes `main` and remains
useful for the single-file example above.

The application package is selected from the launch directory, or an explicit
`--package-root`. Discovery and imports obey existing capabilities and package
boundaries. The filesystem grant options from `gene run` are also accepted.

The older manifest-based test build workflow is available as
`gene test --package [selector]`. It builds each selected `^tests` entry and
invokes its `main`, preserving that workflow separately from spec discovery.

## 6. Scope and contributor coverage

The runner executes serially on the scheduler's root lane. It provides explicit
fixtures and assertions; parallel runs, random ordering, timeouts, mocks,
snapshot testing, shared examples, lazy fixtures, suite-wide hooks, fluent
matchers, and machine-readable reporters are future work. The web backend
rejects these native testing APIs; assertions cannot be lowered into a C native
entry. Ordinary VM functions continue to execute them normally.

[`tests/test_testing.nim`](../tests/test_testing.nim) covers assertions, lexical
capture, hook order, failures, diagnostic snapshots, and backend admission.
[`tests/test_cli.nim`](../tests/test_cli.nim) covers discovery, imports, load
errors, reports, and exit status. These complement the existing compiler/runtime
conformance tests.
