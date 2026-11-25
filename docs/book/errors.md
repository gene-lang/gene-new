# Errors

This chapter raises and handles errors, separates recoverable errors from
defects, declares which errors a function may raise, and chooses how strictly
that is checked.

## Raising an error

An error is a value of a type whose parent is `Error`. `fail` raises it, and
`^_msg` gives it a message:

```gene runnable
(type InputError : Error ^props {^field Str})
(fn check_age [age : Int] : Int
  (if (< age 0)
    (fail (InputError ^field "age" ^_msg "age must not be negative"))
    else age))
(try (check_age -1)
  catch InputError [$err/field $err/.message])
# ["age" "age must not be negative"]
```

`fail` takes only an error value. `(fail "x")` is itself a mistake, and it
raises a `TypeFault`.

## Catching errors

`try` runs its body, and a `catch` clause names the type it handles. The
caught value is bound as `$err`, and `$err/.message` reads its message.
Clauses are tried in order, and the first one whose type covers the error
handles it:

```gene runnable
(type NotFound : Error)
(type Denied : Error)
(fn lookup [key : Str]
  (if (== key "secret") (fail (Denied ^_msg "no access"))
    elif (== key "") (fail (NotFound ^_msg "empty key"))
    else $"value of ${key}"))
(fn safe_lookup [key : Str]
  (try (lookup key)
    catch NotFound "missing"
    catch Denied $"refused: ${$err/.message}"))
[(safe_lookup "a") (safe_lookup "") (safe_lookup "secret")]
# ["value of a" "missing" "refused: no access"]
```

A `try` is an expression: it gives the body's value when nothing fails, or
the handling clause's value. `catch Error` handles every ordinary error, and
`(fail $err)` inside a clause raises the caught error again, unchanged.

## Errors and faults

Every raised value is a `Throwable`, and it belongs to one of two branches:

- **`Error`** is for failures a correct program can meet: a missing file,
  bad input, a refused connection. `IoError`, `JsonError`, `HttpError`, and
  your own types sit here.
- **`Fault`** is for defects: a wrong type (`TypeFault`), a misspelled field
  or a missing message (`MessageFault`), an unmatched `match`
  (`MatchFault`), a failed assertion (`AssertionFault`), and `Panic`.

`catch Error` does not catch a Fault. `catch Fault`, `catch Throwable`, or a
specific fault type does:

```gene runnable
(fn attempt [thunk]
  (try (thunk)
    catch Error "error"
    catch Fault "fault"))
[(attempt (fn [] (fail (Error ^_msg "x")))) (attempt (fn [] ($to_int "x")))]
# ["error" "fault"]
```

> **Why:** a defect means the program is wrong, so recovering from it as if it
> were bad input would hide the bug. Keeping faults out of `catch Error` lets a
> handler recover from real failures while defects still surface.

## Declaring errors

`^errors [T …]` declares the errors a function may let escape. An error that
the row does not cover raises a `ContractViolation` at the function, with
the original error as its cause:

```gene runnable
(type ParseError : Error)
(fn quiet [] ^errors []
  (fail (ParseError ^_msg "bad input")))
(try (quiet)
  catch ContractViolation [$err/.message $err/_cause/.message])
# ["function 'quiet' raised an undeclared error" "bad input"]
```

- `^errors []` lets no ordinary error escape.
- `^errors [ParseError]` lets `ParseError` and its subtypes escape.
- `^errors [Error]` lets any ordinary error escape.

Faults are never checked by rows, so they pass through every row.

## Cleanup

`ensure` runs on the way out of a `try` whether the body succeeded or failed.
`unwind` runs only when the `try` is left by a failure. They come after the
`catch` clauses, `unwind` first:

```gene runnable
(type E : Error)
(var log [])
(try
  (try (fail (E ^_msg "boom"))
    unwind (log .push "undo partial work")
    ensure (log .push "release"))
  catch E (log .push $"handled ${$err/.message}"))
log
# ["undo partial work" "release" "handled boom"]
```

## Causes and messages

`^_cause` keeps the error that led to this one, so a boundary can report its
own error without losing the original:

```gene runnable
(type ConfigError : Error)
(type FileMissing : Error)
(try
  (try (fail (FileMissing ^_msg "settings.json not found"))
    catch FileMissing
      (fail (ConfigError ^_msg "cannot load config" ^_cause $err)))
  catch ConfigError [$err/.message $err/_cause/.message])
# ["cannot load config" "settings.json not found"]
```

A type can compute its message by overriding `message`, with exactly the
signature `[] : Str ^errors []`:

```gene runnable
(type StatusError : Error ^props {^status Int}
  (message message [] : Str ^errors [] ^^override
    $"request failed with status ${self/status}"))
(try (fail (StatusError ^status 404))
  catch StatusError $err/.message)
# "request failed with status 404"
```

An error without a message has the message `""`. A handler holding an error
of unknown type can probe a field, such as `$err/code`, and gets `nil` when
it is not there.

## Panics and assertions

`(panic value)` raises a `Panic` carrying the value. It is a Fault, for a
state the program cannot continue from:

```gene runnable
(try (panic 42)
  catch Panic $err/value)
# 42
```

`$assert` checks an assumption. It returns `nil` when the condition holds,
and otherwise raises an `AssertionFault` with the message:

```gene runnable
($assert (== (+ 1 1) 2) "addition works")
# nil
```

## How strictly errors are checked

By default, error rows are checked at run time, and nothing is required
ahead of time. A module can ask for more with `^errors_mode`:

| Mode | What the compiler does |
| --- | --- |
| `dynamic` (default) | nothing new; rows are still checked at run time |
| `warn` | reports unhandled errors and violated rows, and runs anyway |
| `strict` | rejects them before the program runs |

```gene
(mod app ^errors_mode strict)
```

`gene run --errors-mode strict file.gene` applies a mode to one run. Under
`strict`, a function that calls `parse_age` without handling its
`ParseError` is rejected before it runs:

```text
error checking: 'main' declares [] but may raise [ParseError]. Catch the
escaping errors or add them to ^errors. Origin: main -> parse_age -> fail ParseError
```

In a strict module, exported functions must declare an `^errors` row, and
private helpers have theirs inferred. A loose module can call a strict one,
and the reverse, without either taking on the other's mode.
