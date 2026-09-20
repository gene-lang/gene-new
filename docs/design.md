# Why Gene looks this way

Gene aims to make ordinary application code concise while keeping data,
behavior, and evaluation explicit. Its central idea is one node representation
that can be used as a value or interpreted as code. This page explains the
choices through examples; the [language guide](language.md) teaches the syntax.

## Data has a simple shape

Lists hold positions; property maps hold named fields. A node combines a head,
properties, and a body:

```gene runnable
(let person {^name "Ada" ^roles ["reader" "writer"]})
[person/name person/roles/0]
# ["Ada" "reader"]
```

The same shape can represent syntax. Quoting a form keeps it as data:

```gene runnable
(let form (quote (+ 1 2)))
[($head form) ($body form)]
# [+ [1 2]]
```

Every value has `head`, `props`, `body`, and `meta` projections. Metadata carries
information such as source locations without changing structural equality.
This lets parsers, templates, and application data use common tools.

## Functions stay familiar

Calls evaluate their arguments. The last expression is the result, and type
annotations can be added where they make a contract useful:

```gene runnable
(fn double [n : Int] : Int (* n 2))
(double 21) # 42
```

Dynamic code can coexist with typed code. A value entering an annotated
parameter or result is checked; an annotation is more than editor information.

## Data and behavior compose

A type describes a data schema. A protocol describes behavior that unrelated
types can provide:

```gene runnable
(protocol Labelled
  (message label [] : Str))

(type Person ^props {^name Str})
(impl Labelled for Person
  (message label [] : Str self/name))

((Person ^name "Ada") .Labelled:label)
# "Ada"
```

Direct messages belong to the type; qualified messages identify a protocol.
Nominal inheritance preserves existing contracts. `Self` in an inherited
signature keeps the type where that contract was declared:

```gene runnable
(type Dog ^props {^name Str}
  (message same_name [other : Self] : Bool
    (== self/name other/name)))
(type Pup : Dog ^props {})

((Pup ^name "Rex") .same_name (Dog ^name "Rex"))
# true: the inherited argument contract is still Dog
```

Replacing inherited behavior requires explicit override intent. This makes
changes to a type family visible at the declaration.

## Absence has two meanings

`nil` is a stored absence value. `void` reports missing data or no result.
Optional arguments get defaults; a field lookup reports what is actually there:

```gene runnable
(fn age_label [age : Int?] : Str
  (if ($nil? age) "unknown" $"${age}"))

(type Person ^props {^age Int?})
(let person (Person))
[(age_label) ($void? person/age) (?? person/age nil)]
# ["unknown" true nil]
```

`T?` means `T | Nil`. It does not include Void. The
[absence contract](spec/nil-void.md) states the boundary rules.

## Pipelines make data flow readable

`->` passes a whole value to the next operation. `=>` maps a stage lazily;
an explicit consumer decides how much work happens:

```gene runnable
([1 2 3 4]
  -> $filter (fn [n] (> n 2))
  => * 10
  -> $into [])
# [30 40]
```

`map` preserves a result for each input, converting void to nil.
`filter_map` explicitly drops void. Streams have close and cleanup rules,
so partial consumption has a defined lifetime.

## Tasks have a lifetime

A scope owns its child tasks. Normal exit waits; failure or cancellation
cancels the remaining children and waits for cleanup:

```gene runnable
(scope
  (let left (spawn (+ 10 20)))
  (let right (spawn (+ 30 40)))
  (+ (await left) (await right)))
# 100
```

Tasks are concurrent without promising that every task runs on a separate OS
thread. Channels and actors add explicit communication and state ownership.

## Syntax extension has two tools

A template macro expands into ordinary lexical code:

```gene runnable
(macro unless [condition body...]
  `(if_not %condition %body...))

(var count 0)
(unless false (set count 1))
count # 1
```

A named fexpr receives syntax at runtime:

```gene runnable
(fn quote_it! [form] form)
(quote_it! (+ 1 2)) # (+ 1 2), unevaluated syntax
```

An fexpr can evaluate selected syntax through a borrowed caller environment,
but that evaluation cannot target the caller's `return`, `break`, or `continue`.
Use a macro when the expansion needs ordinary lexical control flow.

## Trusted scripts and sandboxes

Gene has no ambient permission system. An ordinary CLI run is intended for
trusted scripts: evaluated code, an Env, or a namespace filter alone is not a
sandbox, and code that can name `$fs` or `$os` can use it. What bounds untrusted
code is the sandbox loader, which loads a module with only the namespaces it is
granted, together with execution budgets on steps, memory, and time. See
[the miclone design](../examples/miclone/docs/design.md) (§D5) for the loader.

## One language, explicit backend limits

The VM is the general execution path. The browser backend checks a supported
subset and rejects other forms. Experimental native compilation uses explicit
representations and ownership adapters. Shared tests check the behavior each
backend accepts; [workflows](workflows.md) explains how to use them.
