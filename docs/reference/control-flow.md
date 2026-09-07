# Patterns, control flow, and errors

**Status:** detailed design reference and rationale. The implemented contracts
are [calls](../spec/calls.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 8. Pattern matching and destructuring

Pattern matching and argument matching are independent designs and implementations. They share syntax only where semantics are genuinely similar.

Core pattern forms:

```gene
_                    # wildcard / ignore
name                 # bind new name
%name                # match existing lexical value
literal              # match by ==
x : T                # bind x and require type/shape T
(Task ^id id title)  # node/type shape
Enum/variant         # enum unit variant, matches by identity
(Enum/variant p...)  # enum tuple variant, matches tag then payloads
[^first, rest...]    # list/body destructuring
{^k v}               # PropMap destructuring
(@ {^k v} p)         # meta pattern plus value pattern
p...                 # rest pattern
(| p1 p2)            # either
(& p1 p2)            # both
(not p)              # negative pattern, no new bindings
```

Bare names bind. Use `%name` to compare to an existing lexical value.
Qualified enum unit variants are values and match by identity. Qualified enum
tuple-variant patterns first check the variant identity, then match payload
positions left-to-right; payload arity must match the variant declaration.

Patterns are open over props by default: unmentioned props are allowed. A prop pattern fails if the prop is missing/`void`; it matches if the prop is present with `nil`. Meta is ignored unless a pattern explicitly uses the `(@ meta-pattern value-pattern)` form.

A node-shape pattern reads the target's **projection** (§1.3), not its
representation, so one pattern shape reaches every value:

```gene
(match v
  (when (Int n) n)        # 42 -> binds n
  (when (Str s) s)        # "hi" -> binds s
  (when (List a b) [a b]) # [1 2] -> binds a and b
  (when (Map ^a x) x)     # {^a 1} -> binds x
  (when (Task ^id id) id))
```

The head must still match, so arms stay discriminating: `(Str s)` does not
match `42`. Body arity is the ordinary node rule applied to a body that now
holds the literal — `(Int n)` matches `42` and bare `(Int)` does not, because
`42` projects one body item.

The match is against the target's canonical Node representation (§1.3),
uniformly across every kind that projects one. A cell `c` holding `v` matches
`(Cell p)`, binding `p` to the current value:

```gene
(match ($cell 5)
  (when (Cell v) (* v 2)))   # => 10
```

The bind is read-only — `v` is the value at match time, so setting the cell
afterwards does not move it. Head-only canonical nodes match arity-zero
patterns: `(Stream)` matches a stream, and bare `(Cell)` does not match a
cell, whose body holds one item. A function, with no registered type identity,
matches no node pattern at all.

A scalar arm matches the canonical body in place: no projection is
materialized, so the arm's allocation profile is the ordinary bind's — the
per-arm cost is head resolution and the bind, nothing structural. The
`vm.match_scalar` / `vm.match_bind` pair in `benchmarks/bench_core.nim` guards
this as a same-run delta.

Alternation patterns must bind the same set of names with compatible types in every branch. Negative patterns must not introduce new bindings.

`match` performs structural selection only, and deliberately has no per-arm
`guard`. A value condition that decides between outcomes *within* one matched
shape is a normal `if` inside that arm:

```gene
(match shape
  (when (Circle r) (if (> r 10) "big" "small"))
  (when (Rect w h) "rect"))
```

A guard's unique power — letting a value condition fall through to a
structurally *different* pattern — is rarely needed and is not worth a
dedicated form; write a more specific pattern, or restructure the arms.

To refine a value to a narrower type, use a type pattern rather than an `if`
type check: `(when (c : Cat) ...)` matches the shape, binds `c`, and treats it
as a `Cat` for the arm. This is Gene's narrowing idiom — the bound name carries
the refined type — so a separate flow-sensitive `if` narrowing is unnecessary
in the MVP:

```gene runnable
(fn describe [x : (| Cat Dog)] : Str
  (match x
    (when (c : Cat) (c .say))
    (when (d : Dog) (d .say))))
```

```gene
(match value
  (when <pattern>
    body...)
  (when <pattern>
    body...)
  (else
    body...))
```

Rules:

- cases are tried in order;
- the first structurally matching pattern wins;
- branch bodies are implicit `do` blocks;
- top-level `else` runs only if no pattern matched;
- no match and no `else` raises `MatchError`.

The same pattern engine is used by `var` and `for` destructuring. A `catch`
clause takes an error type, not a pattern (§9).

```gene
(var [x, y] point)
(var (Task ^id id ^title title) task)

(for [k, v] in pairs
  ...)
```

If destructuring fails, Gene raises `MatchError`.

### 8.0.1 Pattern binding scope

Where a pattern introduces a name controls which lexical region the name
lives in:

| Form                         | Bindings live in                       |
| ---------------------------- | -------------------------------------- |
| `(match v (when p body...))`  | the matched branch body                |
| `(for p in xs body...)`       | the loop body, fresh per iteration     |
| `(var p v)`                  | the enclosing lexical scope            |

`match` and `for` bindings are **branch-local**: the runtime slot table for an
arm is a fresh child of the enclosing scope, so a name bound by one arm is
unreachable from a sibling arm and from anything after the form.
`(var pattern value)` binds like any other `var` and extends the current
scope; its names are visible to subsequent expressions as ordinary locals.

A catch body has one implicit branch-local binding, `$ex`, containing the
whole caught error value. It is unavailable in the try body, `ensure`, sibling
catch clauses, and after the `try` form.

```gene
(match x
  (when [a b]
    (+ a b)))                  ; a, b live only inside this arm

(var [a b] x)                  ; a, b are now regular locals
(+ a b)                        ; resolves to the var, not the match
```

Compile-time enforcement of branch isolation is **partial**. Each arm's
pattern names are reserved in a fresh local-slot table, so a same-arm
reference resolves at compile time. A name that resolves to neither
localSlots, parentSlots, nor a known compile-time binding falls through
to a runtime lookup (an `opLoadName`). That lookup finds runtime globals,
real but suspect names from earlier bindings, and runtime `var`-defined
values alike; if nothing in the active scope chain matches, the runtime
raises `undefined symbol: <name>`. Future work may tighten the
compile-time side so genuinely-unbound references fail at compile time;
the guarantee above is the runtime one and the one tests should rely on.

### 8.1 `for`

`for` iterates an iterable value, binds each item with a pattern, and evaluates
its body in a fresh loop-body scope for each item:

```gene
(for pattern in iterable
  body...)
```

The body is an implicit `do` (§8). The pattern engine is shared with `var`,
`match`, and `catch` destructuring, so:

```gene
(for [k, v] in pairs        ; list/PropMap destructuring
  body...)

(for (Task ^id id title) in tasks
  body...)
```

#### Iterable contract

The MVP iterable set is:

- `List`: each list item, in source order;
- `Node`: each positional body item, in source order;
- `Map`, `HashMap`: `[key value]` pair lists; map order is the iteration order
  of the underlying entries;
- `Set`: each set item, in set iteration order;
- `Str`: Unicode scalar `Char` values, left to right;
- `Range`: integer values from `start` toward `stop` per the range's
  `step`/`inclusive?` (§7), yielded lazily;
- `Stream`: pulled lazily, one item per body iteration;
- `nil` and `void`: empty iteration.

`for` is implemented over an internal `iteratorStream` covering exactly the kinds
above; it is a superset of the public `to_stream` (which accepts only `List`,
`Set`, and `Range`). A value whose kind is not in this set raises
`for: cannot iterate <kind>`.

#### Return value and control flow

- The loop evaluates to `nil`, including an empty input and after `break`.
- An item that does not match `pattern` raises `MatchError` (with cleanup).
- `continue` skips the rest of the current body and advances to the next item;
  for `repeat` the remaining count still decrements before the next condition
  check or index increment.
- `break` exits the nearest enclosing loop.
- Both `break` and `continue` are loop-only special forms; using either outside
  `for`, `while`, `loop`, or `repeat` is a compile-time error.

#### Stream lifecycle and errors

A `for` over a `Stream`:

- pulls one item at a time, lazily, on each iteration;
- closes the active stream on normal exhaustion, on `break`, and when an
  uncaught item-pattern or body error unwinds out of the loop;
- propagates producer errors raised by `has_next`/`peek`/`next` directly out of
  the loop; the stream is still closed as part of the unwind;
- does not catch those errors itself — recover them with `try`/`catch`
  (§9) around the `for`.

`continue` does not close the stream; only iteration moves on.

`while` evaluates its condition before each iteration. `loop` is an unconditional
loop:

```gene
(loop
  body...)
```

`repeat` evaluates its count once, then runs its body while the remaining count is
greater than zero:

```gene
(repeat n
  body...)
```

The indexed form binds a zero-based index in the loop body:

```gene
(repeat i in n
  body...)
```

The index starts at `0` and advances through `n - 1`. The count expression is
still evaluated once before the loop begins.

`for`, `while`, `loop`, and `repeat` share the `break`/`continue` rules above.

---

## 9. Control flow and errors

Full `if` form:

```gene
(if cond
  (then
    stmt1
    stmt2)
  (elif cond2
    stmt3)
  (else
    stmt4))
```

Compact expression form:

```gene
(if cond true_expr false_expr)
```

Guard forms treat their whole tail as one implicit `do` branch:

```gene
(if_yes cond body...)  # run body when truthy; otherwise nil
(if_not cond body...)  # run body when falsy; otherwise nil
```

Each condition is evaluated once. An empty taken tail evaluates to `nil`.

Idiomatic code omits an explicit trailing `nil`: write `(if cond value)` for a
single expression, or `(if_yes cond body...)` for a multi-expression guard.
Use `if_not` instead of `(if cond nil value)`. When both branches contain
multiple expressions, use `then`/`elif`/`else` clauses instead of wrapping
compact branches in `do`.

`(return value)` leaves the nearest function after running structured cleanup;
`(return)` returns `void`. In generators only the empty form or
`(return void)` is accepted, and it terminates without yielding an item (§6.1).

Short-circuit boolean operators:

```gene
(&& a b c)   # left to right; stop at the first falsy operand
(|| a b c)   # left to right; stop at the first truthy operand
(?? a b c)   # left to right; stop at the first present (non-nil, non-void) operand
(! x)        # Bool inverse of x's truthiness
```

`&&`, `||`, and `??` yield the last operand evaluated — not a coerced `Bool`.
For a default over absence use `??` (`(?? maybe-missing "default")`), which
fills `nil`/`void` but keeps a stored `false`; `||` stops at the first truthy
operand, so it is boolean logic, not a null-coalescing default (§1.6). With no
operands `(&&)` is `true`, and `(||)` and `(??)` are `nil`. `!` takes exactly
one operand and always yields a `Bool`.

Recoverable errors are typed nodes whose type implements the marker protocol `Error`:

```gene
(protocol Error)

(type ParseError
  ^props {^message Str ^source Str? ^line Int? ^col Int? ^contexts Any?}
  ^impl [Error])

(impl Error for ParseError)
```

Every type listed in `^errors [...]` must implement `Error`. `fail` raises only
`Error` values. What follows `catch` is a type expression; clauses are tried in
order and the first type admitting the error wins. The caught value is `$ex`,
so fields are read as `$ex/message`, `$ex/path`, and so on. Destructuring does
not occur in a catch header.

A VM diagnostic without a more specific domain type is raised as
`RuntimeError`, which implements `Error` and carries `^message`. Therefore
`catch RuntimeError` selects those diagnostics, `catch Error` selects every
value implementing the marker protocol, and `catch Any` is the explicit
recoverable catch-all. `(fail $ex)` re-raises the same value without losing its
type or fields.

Reader diagnostics preserve structured delimiter contexts (opener, expected
closer, source, line, and column) through `ParseError`/`LexError`. When a
dynamic undefined-symbol error originates while executing a source unit's
top-level chunk, its diagnostic also names the containing top-level form and
that form's opening location. This makes a prematurely closed declaration
visible without guessing that otherwise valid top-level syntax was unintended.

`TypeError` is an `Error` when it is produced by an `Any`→typed boundary check, such as untrusted input passed to a typed argument. Internal typed-representation contradictions and VM invariants are panics, not recoverable `TypeError`.

Functions may annotate checked errors:

```gene
(fn load [path : Str] : Config
  ^errors [ParseError FsError]
  ...)
```

Missing `^errors` means dynamic/unchecked errors. `^errors []` means the function claims no recoverable errors.

Static effects/capability rows are not part of MVP. `^effects` is reserved/WIP.

```gene
(try
  body...
catch ParseError
  ($println $ex/line $ex/message)
catch Any
  ($println $ex/message)
ensure
  cleanup...)
```

The `try`, `catch`, and `ensure` bodies accept multiple expressions directly;
they do not need `do` wrappers. Catch types match nominal subtypes and protocol
conformance in order. `Any` catches every recoverable error.
`ensure` runs on success or error; its result is ignored unless it
raises/panics. Unhandled errors propagate.

Built-in error types the runtime raises:

```text
RuntimeError         dynamic VM diagnostic without a more specific type
TypeError            gradual-boundary type failure
├── CallKindError    called a non-callable, or the wrong callable kind
└── MessageError     a .send resolving to no message on the receiver's type
MatchError           pattern/destructuring failure
└── SelectorMissing  a ^strict selector segment missed
CompileError         compile-time failure
├── ParseError
└── LexError
ChannelClosed        send/recv on a closed channel
ActorError           actor-facing failure
├── ActorClosed
└── ReplyAlreadySent
ActorFailure         child failure reported to a supervisor
```

Only `CallKindError` and `MessageError` have a parent; the other roots are
independent nominal types. `catch Error` matches all values implementing the
marker protocol, and `catch Any` is the explicit catch-all.
The `ParseError` shown above as a user declaration is an illustration — the
built-in `ParseError` extends `CompileError`.

`panic` is for violated invariants and unrecoverable bugs. It is not listed in `^errors`.

---
