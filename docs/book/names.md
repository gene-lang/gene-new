# Names, bindings, and paths

This chapter binds values to names, follows Gene's naming rules, reaches the
standard library, and reads through data with paths.

## Bindings

`let` binds a name once. `var` makes a binding that `set` can change.
`const` declares a constant at module or namespace level. Any of them can
carry a type annotation before the value:

```gene runnable
(let name "Ada")
(var visits : Int 0)
(set visits (+ visits 1))
(const limit : Int 100)
[name visits limit]
# ["Ada" 1 100]
```

- A binding takes at most one value, and a binding declared without one
  holds `nil`.
- An annotated `var` checks every `set`: `(set visits "x")` fails with
  `set 'visits' expected Int, got Str`.
- `let` fixes the binding, not the value. A List bound with `let` can still
  change; `$freeze` makes a value immutable.

> **Watch out:** `set` on a `let` binding fails with
> `cannot set 'name': let, const, and named declarations … are fixed
> bindings`. Declare the name with `var` if it must change.

> **Watch out:** `const` belongs at module or namespace level. Inside a
> function it fails with `const is a module-level declaration and cannot
> appear inside a function`; use `let`.

## Naming

- **snake_case** is used for every name a program writes: functions,
  bindings, fields, and namespaces, as in `unfinished_titles` or
  `^due_date`.
- **Types and protocols start with an uppercase letter.** `(type thing …)`
  fails with `type 'thing' must start uppercase`, because lowercase names
  are for namespaces and functions.
- **A trailing `?`** marks a predicate, as in `$present?` or `contains?`. A
  record field cannot end in `?`: optionality belongs to the field's type,
  written `^nickname Str?`.
- **A trailing `!`** makes a function an fexpr. An fexpr receives its
  arguments as unevaluated syntax:

```gene runnable
(fn quote_it! [form] form)
(quote_it! (+ 1 2))
# (+ 1 2)
```

Because the name says so, a reader can tell at the call site that the
arguments are not evaluated. Mutation methods therefore use plain names,
such as `push` and `put`, not a `!` suffix.

## The standard library

The standard library lives in the global namespace `gene`, and `$x` is short
for `gene/x`. Root functions such as `$println` and `$map` sit directly
under it, and libraries such as `$str` and `$json` are namespaces inside it:

```gene runnable
[($str/upper "ada") (gene/str/upper "ada")]
# ["ADA" "ADA"]
```

`import` binds names from a namespace into the current module, so they can
be called without the prefix:

```gene runnable
(import $str [join split])
(join (split "a,b,c" ",") " ")
# "a b c"
```

> **Watch out:** a standard name without `$` or an import is undefined. A
> bare `(println "hi")` fails with `undefined symbol: println`; write
> `($println "hi")`.

The library reference lists every standard name, one entry per name
(`lib/gene/str/join` for `$str/join`).

## Paths

A path reads through data with `/`:

- a name segment reads a property;
- an Int segment reads a position, and negative positions count from the
  end;
- `%` evaluates a segment;
- `.x` sends a zero-argument message.

```gene runnable
(let person {^name "Ada" ^roles ["reader" "writer"]})
(let field "name")
[person/name person/roles/0 person/roles/-1 person/%field person/roles/.size]
# ["Ada" "reader" "writer" "Ada" 2]
```

A send with arguments keeps its parentheses: `(person/roles .get 1)`.

> **Watch out:** a path cannot be glued to a closing bracket.
> `(get_person)/name` and `[1 2]/.size` are read errors,
> `a path cannot follow ')' without whitespace`. Write a Path call,
> `(/name (get_person))`, or a send, `([1 2] .size)`, or bind the value
> first.

> **Watch out:** `(xs/.push 3)` is not `(xs .push 3)`. It sends `push` with
> no arguments and then calls the result, so it fails with
> `List/push expects 2 arguments, got 1`. The `/.` shortcut takes no
> arguments.

## Missing and wrong reads

A path step that finds nothing reads `nil`: a missing key, a position past
the end, an optional field left out, or a name or index read through `nil`.
A missing lookup ends a plain path. A message stage dispatches on a stored
`nil` like a parenthesized send. Use `?.` to skip dispatch on a `nil`
receiver. A step that
cannot be right raises a `Fault` instead:

- a name that the value's type does not declare;
- a name segment through a value with no fields, such as an Int, a Str, or
  a List;
- an Int segment on a Map, which has no positions;
- any segment on a Stream.

```gene runnable
(type P ^props {^name Str ^age Int?})
(let p (P ^name "Ada"))
[p/age
 ($has_key? p "nmae")
 (try p/nmae catch Fault "raised")
 (try (let n 6) n/b catch Fault "raised")]
# [nil false "raised" "raised"]
```

The two failures above read `P has no field 'nmae'` and
`Int has no fields, so 'b' cannot be read through a path`. `$has_key?` tests
for a key without raising. A Map's keys are read by message, as in
`(m .get k)`.

> **Why:** a misspelled field that read as `nil` would fail later, wherever
> the `nil` was used. Raising at the read points at the typo. A `Fault` marks
> a defect, so `catch Error` does not catch it.

## Paths as values

A path with a leading slash is a `Path` value. It is callable, and it works
anywhere a function does:

```gene runnable
(let data {^a {^b [10 20 30]}})
(let people [{^name "Ada"} {^name "Grace"}])
[(/a/b/1 data) ((Path "a" "b" 1) data) ($map people /name)]
# [20 20 ["Ada" "Grace"]]
```

`(Path "a" "b" 1)` builds the same Path from its segments.

## Namespaces

`ns` groups definitions inside a module, and a path reaches them:

```gene runnable
(ns helpers
  (fn twice [n] (* n 2)))
(helpers/twice 3)
# 6
```

A namespace belongs to its module. Another module reaches it through an
import ([Modules and packages](modules.md)).
