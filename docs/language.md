# The Gene language

This guide covers everyday Gene. Save complete examples in a `.gene` file and
run them with `gene run`. `gene eval` is convenient for individual expressions;
imports belong in a source file. For installation and a first complete program,
start with the [README](../README.md).

Jump to [values](#values-and-bindings), [functions](#functions),
[control flow](#control-flow), [types](#types-and-messages),
[collections](#collections-and-streams), [modules](#modules), or
[advanced features](#tasks-and-channels).

## Values and bindings

Expressions use parentheses: the first item names an operation, followed by its
arguments. Whitespace separates values; commas are optional separators.

```gene runnable
(let name "Ada")
(var visits 0)
(set visits (+ visits 1))
$"Hello, ${name}; visit ${visits}"
# "Hello, Ada; visit 1"
```

`let` binds a name once. `var` permits rebinding with `set`. A let-bound mutable
collection can still be changed; binding immutability does not freeze a value.

Common values:

| Value | Meaning |
| --- | --- |
| `42`, `-7` | Arbitrary-precision Int |
| `3.5` | Floating-point number |
| `true`, `false` | Bool |
| `"hello"`, `$"Hello, ${name}"` | String and interpolated string |
| `[1 2 3]` | List |
| `{^name "Ada" ^active true}` | Property map with named keys |
| `{{"red" : 1 "blue" : 2}}` | General map with explicit keys |
| `#[1 2 3]`, `#{^name "Ada"}` | Shallow immutable collection |
| `nil`, `void` | Stored absence; missing/no-result |

`#` starts a line comment. `#< ... >#` is a block comment. The special `#[...]`
and `#{...}` forms are literals, not comments. `^^active` is shorthand for
`^active true`.

### Paths and selectors

Slash paths read fields and indexed positions. `%` evaluates a dynamic segment.
A leading slash creates a reusable selector:

```gene runnable
(let person {^name "Ada" ^roles ["reader" "writer"]})
(let field "name")
[person/name person/roles/0 person/roles/-1 person/%field (/name person)]
# ["Ada" "reader" "writer" "Ada" "Ada"]
```

A missing property produces void. `??` supplies a fallback for nil or void:

```gene runnable
(let person {^name "Ada"})
[(?? person/nickname "anonymous") ($void? person/nickname)]
# ["anonymous" true]
```

Use `==` for structural equality and `same?` for identity. Metadata does not
participate in structural equality. Mutable list/map identity remains distinct
from equal contents.

### Nodes and quoted data

A node combines a head, named properties, and positional body values. Quote
keeps a form as data instead of calling its head:

```gene runnable
(let task (quote (task ^done false "Write docs")))
[($head task) task/done ($body task)]
# [task false ["Write docs"]]
```

`@source "example"` attaches metadata. `$head`, `$props`, `$body`, and `$meta`
inspect the four projections. Their collection results are detached shallow
snapshots; nested mutable values retain identity.

## Functions

The last expression is the result. `return` exits early. Functions are values,
and anonymous functions use the same parameter syntax:

```gene runnable
(fn square [n : Int] : Int (* n n))
(let add_one (fn [n] (+ n 1)))
[(square 5) (add_one 5)]
# [25 6]
```

Annotations are optional. `: T` checks a parameter, binding, or result against
T. Common type expressions include `Int`, `Str`, `Bool`, `(List Int)`,
`(| Int Str)`, and `Int?`. `Any` is the gradual top type.

### Wrapping an expression with #@

`#@` wraps the next two complete forms as `(head argument)`. It is useful when
temporarily adding a call around an existing expression:

```text
#@$println x       → ($println x)
#@ (x) y           → ((x) y)
#@f #@g x          → (f (g x))
[1 #@f x 3]        → [1 (f x) 3]
```

Whitespace after `#@` is optional, and newlines are ordinary whitespace. The
reader always consumes two forms: `#@f x y` leaves `y` outside the wrapper.
Use parentheses for a call with multiple arguments or named properties.

This is ordinary call syntax, so `$println` still returns nil. To print a value
and keep using it, return it from a helper:

```gene runnable
(fn tap [value]
  ($println value)
  value)
(* 2 #@tap (+ 20 1)) # prints 21; result is 42
```

The prefix also works under quote. `gene fmt` preserves `#@` while normalizing
layout; canonical printing expands it to the ordinary parenthesized form.

### Optional, named, and rest arguments

A fixed parameter admitting nil gets an implicit nil default. An explicit
default takes precedence; an explicitly supplied nil does not select a default.

```gene runnable
(fn age [value : Int? = 18] : Int? value)
[(age) (age nil) (age 25)]
# [18 nil 25]
```

Write `value : Int?` without `= 18` to default to nil. Optional positionals
must follow required positionals and cannot precede a rest parameter. An
explicit positional void fails an `Int?` check.

Named arguments use `^` at both declaration and call:

```gene runnable
(fn greet [name : Str ^ending : Str = "!"] : Str
  $"Hello, ${name}${ending}")
[(greet "Ada") (greet "Ada" ^ending "?")]
# ["Hello, Ada!" "Hello, Ada?"]
```

A rest parameter ends in `...`. At a call site, `value ...` spreads its contents:

```gene runnable
(fn total [values... : Int] : Int
  (var result 0)
  (for n in values (set result (+ result n)))
  result)
(let values [1 2 3])
(total values ...) # 6
```

Defaults run at call time and may refer to earlier parameters. For exact
named-void and callable-shape rules, see [calls](spec/calls.md) and
[optional binding](spec/nil-void.md).

## Control flow

Only false, nil, and void are falsy. Zero and an empty string are truthy.
`if` returns a value; `do` groups expressions and returns the last one.

```gene runnable
(fn sign [n : Int] : Str
  (if (< n 0) "negative" (if (== n 0) "zero" "positive")))
(sign -3) # "negative"
```

Use `if_yes` or `if_not` for a condition followed by several expressions.
`&&` and `||` short-circuit. `??` tests absence, not general truthiness.

Loops support `break` and `continue`:

```gene runnable
(var total 0)
(for n in [1 2 3 4]
  (if (== n 2) (continue))
  (set total (+ total n)))
(while (< total 10) (set total (+ total 1)))
total # 10
```

### Patterns

Patterns bind parts of a value. `_` ignores a position; a final rest binding
collects remaining list elements.

```gene runnable
(fn first_label [values] : Str
  (match values
    (when [] "empty")
    (when [first rest...] $"first=${first}")))
(first_label [10 20 30]) # "first=10"
```

Patterns also work with property maps, nodes, enum variants, and typed values.
A requested property must exist; a missing optional field does not bind nil.

### Errors and cleanup

Use `$assert` to check an assumption. It returns nil on success and raises
`AssertionError` on failure:

```gene runnable
($assert (== (+ 1 1) 2) "addition should work") # nil
```

The [testing guide](testing.md) shows example groups, fixtures, and error checks.

Use typed errors for recoverable failures. `catch` binds the original error as
`$err`; `$err_msg` invokes its `Error:message` method. `ensure` runs cleanup on
success or failure.

```gene runnable
(type InputError ^props {^message Str})
(impl Error for InputError)

(fn positive [n : Int] : Int ^errors [InputError]
  (if (< n 1) (fail (InputError ^message "expected positive")) n))

(try (positive 0)
  catch InputError $err_msg)
# "expected positive"
```

An empty `impl Error` uses the required string `message` property. Types with
another representation provide `message [] : Str ^errors []` in their impl.
`$err/message` is a direct property lookup when you need the stored data.

`^errors [InputError]` permits that error and its subtypes to escape;
`^errors []` permits no ordinary errors, and `^errors [Error]` permits any.
Violating a declared row raises `ErrorContractViolation`, with the original
error in `$err/cause`. Generated type failures and contract violations remain
catchable without being wrapped again. Panic and cancellation bypass catches.

Scripts default to dynamic checking. The gradual checker adds `warn` and
`strict` module policies; see the [error-handling contract](error-handling.md)
and [runnable example](../examples/error_handling.gene).

## Types and messages

A type declares a schema and may define messages. `self` is the receiver.
Direct construction checks data without running constructor code:

```gene runnable
(type Person ^props {^name Str}
  (message greet [] : Str $"Hello, ${self/name}!"))

(let ada (Person ^name "Ada"))
(ada .greet) # "Hello, Ada!"
```

`(greet ada)` calls a lexical function. `(ada .greet)` sends a message.
A message name is not automatically a function binding.

Use a `ctor` and `new` for construction logic:

```gene runnable
(type Counter ^props {^value Int}
  (ctor [start : Int = 0] (set self/value start))
  (message add [amount : Int] : Int
    (set self/value (+ self/value amount))))

(let counter (new Counter))
(counter .add 3) # 3
```

`(Counter ^value 3)` constructs data directly; `(new Counter 3)` runs the
constructor. A constructor validates its pre-created receiver before it can
escape. Ordinary types may have mutable data; native wrappers have stricter
construction and ownership rules.

### Protocols

A protocol names behavior. An impl supplies that behavior for a type:

```gene runnable
(protocol Labelled
  (message label [] : Str))
(type Person ^props {^name Str})
(impl Labelled for Person
  (message label [] : Str self/name))

(let ada (Person ^name "Ada"))
[(ada .Labelled:label) (Labelled:label ada)]
# ["Ada" "Ada"]
```

The qualifier identifies the protocol even when two protocols use the same
message name. Ordinary protocol defaults require an impl. A protocol explicitly
marked universal provides its own fallback-conformance rules.

### Inheritance and Self

A type has at most one nominal parent, written `: Parent`. An inherited
signature keeps its declaring type. A direct replacement requires `^^override`:

```gene runnable
(type Animal ^props {^name Str}
  (message speak [] : Str self/name))
(type Dog : Animal ^props {}
  (message speak [] : Str ^^override $"${self/name}: woof"))
((Dog ^name "Rex") .speak) # "Rex: woof"
```

For protocol impls, `^^override` belongs on the impl. It reuses applicable
ancestor bodies for omitted messages. Without the flag, the impl must cover
the protocol using its own bodies and protocol defaults. Replacement signatures
preserve inherited contracts and cannot use contextual Self; body-local Self
still means the new declaring receiver. See the runnable
[protocol demo](../examples/protocol_demo.gene) for complete examples.

## Collections and streams

The standard-library root is `gene`, abbreviated `$`. You can call an operation
directly or import its name:

```gene runnable
(import $str [join])
(join ["Ada" "Grace"] ", ") # "Ada, Grace"
```

`map`, `filter`, and `filter_map` operate on eager collections and lazy streams.
A selector can be the callback:

```gene runnable
(let people [{^name "Ada"} {^name "Grace"}])
($map people /name) # ["Ada" "Grace"]
```

`map` converts a callback's void result to nil. `filter_map` drops only void,
preserving nil, false, zero, and empty strings:

```gene runnable
(fn keep_positive [n] (if (> n 0) n void))
[($map [-1 2] keep_positive) ($filter_map [-1 2] keep_positive)]
# [[nil 2] [2]]
```

### Pipelines and generators

`->` puts the incoming value in the next call's first argument slot. One `_`
can place it elsewhere. `=>` prepares a lazy per-item stage:

```gene runnable
[(2 -> + 3 -> * 4)
 (10 -> / 100 _)
 ([1 2 3] => * 2 -> $into [])]
# [20 10 [2 4 6]]
```

`=>` is lazy even when it is the final stage. `$into` collects, `$take` bounds
consumption, and `$each` runs per-item effects. `;` is different: it folds calls
into the next head and has no pipeline slot behavior.

A function containing `yield` returns a Stream:

```gene runnable
(fn naturals []
  (var n 0)
  (while true (yield n) (set n (+ n 1))))
((naturals) => * 2 -> $take 4 -> $into [])
# [0 2 4 6]
```

Raw `yield void` emits nothing. Stream consumers and `close` manage upstream
cleanup; an early close runs suspended `ensure` blocks. Do not assume a lazy
pipeline has executed because it was constructed.

## Modules

Each source file is a module. An import selects bindings from that file's
root namespace. For example, put these two files in the same directory:

```gene
# stats.gene
(fn twice [n] (* n 2))
```

```gene
# main.gene
(import [twice] from "./stats.gene")
($println (twice 3)) # 6
```

Run `gene run main.gene`. No `ns` wrapper is needed in `stats.gene`.
File imports initialize a module once. Package dependency aliases identify
external libraries; [workflows](workflows.md#packages) shows the project layout.

### Namespaces

`ns` groups definitions inside a module. It does not create a file:

```gene runnable
(ns helpers
  (fn twice [n] (* n 2)))
(helpers/twice 3) # 6
```

Here `twice` belongs to `helpers`. Wrapping the first example in `(ns stats ...)`
would export the `stats` namespace, so `(import [twice] ...)` would no longer
select a top-level binding.

## Tasks and channels

`scope` owns child tasks. `await` returns a task result or propagates its failure.
Channels provide bounded FIFO communication:

```gene runnable
(scope
  (let messages ($channel ^capacity 1))
  (spawn (messages .send 42))
  (messages .recv))
# 42
```

Actors process messages sequentially and support request/reply. Channel and
actor messages must satisfy Send. Use Cells for local shared mutable state;
AtomicCells are the explicit shared-thread primitive. See the
[concurrency example](../examples/concurrency.gene) and
[concurrency contract](spec/concurrency.md) for lifetime details.

## Macros, fexprs, and eval

Quasiquote uses a backtick; `%` inserts a value into the template. A macro
produces syntax at compile time:

```gene runnable
(macro unless [condition body...]
  `(if_not %condition %body...))
(var value 0)
(unless false (set value 1))
value # 1
```

A named `fn name!` is an fexpr: its arguments are unevaluated syntax. It can
interpret them at runtime through a borrowed `caller_env`. This does not give
it caller return/loop targets or direct rebinding of caller variables. The
[fexpr demo](../examples/fexpr_demo.gene) makes the differences explicit.

`eval` compiles a syntax value with an Env:

```gene runnable
(let e (env ^bindings {^value 20} ^capabilities []))
(eval (quote (+ value 2)) ^in e) # 22
```

An ordinary Env overlays the evaluation-site lexical scope; it does not hide
those names. An omitted capability row inherits the current context, while
`[]` selects no external capabilities. Retained ceilings cannot restore removed
permissions. Read [authority](spec/authority.md) before using eval with
untrusted code.

For exact edge cases, use [the specification](spec/README.md). Keep the
[design overview](design.md) nearby for the reasoning behind these rules.
