# Types, messages, and protocols

This chapter declares record types, gives them behavior with messages,
shares behavior across types with protocols, and covers inheritance, enums,
and the type expressions used in annotations.

## Declaring a type

`type` declares a record: a name, which starts uppercase, and the fields it
holds, each with a type. Calling the type with named arguments constructs a
value:

```gene runnable
(type Person ^props {^name Str ^nickname Str?})
(let ada (Person ^name "Ada"))
[ada/name ada/nickname]
# ["Ada" nil]
```

Construction checks the data against the type:

- A missing field fails with `missing required field 'name' for Person`,
  unless the field's type admits `nil`, as `Str?` does.
- A field the type does not declare fails with `Person has no field 'nmae'`.
- A value of the wrong type fails with
  `field 'name' for Person expected Str, got Int`.

Fields can be changed with `set`, and the same check applies:

```gene runnable
(type Person ^props {^name Str})
(let p (Person ^name "Ada"))
(set p/name "Grace")
p/name
# "Grace"
```

> **Watch out:** a field name cannot end in `?`. Optionality belongs to the
> field's type: write `^nickname Str?`, not `^nickname? Str`.

## Messages

A `message` inside a type gives it behavior. `self` is the receiver, and a
dot sends the message:

```gene runnable
(type Person ^props {^name Str}
  (message greet [] : Str
    $"Hello, ${self/name}!")
  (message greet_with [greeting : Str] : Str
    $"${greeting}, ${self/name}!"))
(let ada (Person ^name "Ada"))
[(ada .greet) ada/.greet (ada .greet_with "Hi")]
# ["Hello, Ada!" "Hello, Ada!" "Hi, Ada!"]
```

`ada/.greet` is the short form of a send with no arguments. A send with
arguments keeps its parentheses.

> **Watch out:** a send only finds messages. `(ada .shout)` fails with
> `no message 'shout' on Person` even when a function named `shout` is in
> scope; call a function as `(shout ada)`.

## Constructors

Direct construction fills in the fields and runs no code. For setup logic,
declare a `ctor` and construct with `new`:

```gene runnable
(type Counter ^props {^value Int}
  (ctor [start : Int = 0]
    (set self/value start))
  (message add [amount : Int] : Int
    (set self/value (+ self/value amount))))
(let counter (new Counter 5))
(counter .add 3)
# 8
```

> **Watch out:** `(Counter ^value 3)` never runs the `ctor`, and `new` is the
> only way to run it. Neither is a fallback for the other.

## Protocols

A protocol names a set of messages. An `impl` supplies them for a type, and
a qualified send, `.Protocol:message`, calls them:

```gene runnable
(protocol Labelled
  (message label [] : Str)
  (message shout [] : Str
    ($str/upper (self .Labelled:label))))
(type Person ^props {^name Str})
(impl Labelled for Person
  (message label [] : Str self/name))
(let ada (Person ^name "Ada"))
[(ada .Labelled:label) (Labelled:label ada) (ada .Labelled:shout)]
# ["Ada" "Ada" "ADA"]
```

- A message with a body in the protocol, such as `shout`, is a default that
  each impl gets unless it supplies its own.
- `Labelled:label` is also a callable value, which takes the receiver as its
  first argument.
- The qualifier keeps two protocols that use the same message name apart.

> **Watch out:** a protocol message needs its qualifier. A bare
> `(ada .label)` fails with `no message 'label' on Person; protocol messages
> visible here: Labelled:label — use a qualified send`.

A protocol with no messages is a marker. `^impl [Audited]` on a type
declares it, and a pattern can test for it:

```gene runnable
(protocol Audited)
(type Payment ^props {^cents Int} ^impl [Audited])
(match (Payment ^cents 250)
  when (p : Audited) "audited"
  else "plain")
# "audited"
```

A protocol whose impl lives in another module is brought in with
`import_impl` ([Modules and packages](modules.md)).

## Inheritance

A type may have one parent, written `: Parent` after its name. It inherits
the parent's fields and messages. Replacing an inherited message requires
`^^override`, and `super` sends to the parent's version:

```gene runnable
(type Animal ^props {^name Str}
  (message speak [] : Str self/name))
(type Dog : Animal ^props {^breed Str}
  (message speak [] : Str ^^override
    $"$(super .speak): woof"))
(let rex (Dog ^name "Rex" ^breed "lab"))
[(rex .speak) rex/breed]
# ["Rex: woof" "lab"]
```

> **Watch out:** without `^^override`, the replacement fails with
> `type message Dog/speak requires ^^override`. The flag makes every
> replacement deliberate.

`Self` in a signature names the type that declared the message, and an
inherited message keeps it. Here a `Pup` compares itself with any `Dog`:

```gene runnable
(type Dog ^props {^name Str}
  (message same_name [other : Self] : Bool
    (== self/name other/name)))
(type Pup : Dog ^props {})
((Pup ^name "Rex") .same_name (Dog ^name "Rex"))
# true
```

## Enums

`enum` declares a type with a fixed set of variants. A plain variant is a
value, and a variant with types in parentheses carries a payload:

```gene runnable
(enum Color red green blue)
(enum Shape (circle Int) (rect Int Int))
(fn area [s : Shape] : Int
  (match s
    when (Shape/circle r) (* 3 r r)
    when (Shape/rect w h) (* w h)
    else 0))
[Color/red (Color/green .ordinal) (Color .names) (area (Shape/rect 2 3))]
# [Color/red 1 [red green blue] 6]
```

## Type expressions

| Expression | Accepts |
| --- | --- |
| `Int`, `F64`, `Str`, `Bool`, `Sym`, `Char` | that kind of value |
| `(List Str)`, `(Map Str Int)` | a collection of those items |
| `(Stream Int Never)` | a Stream of Ints whose production raises nothing; the second type is the error type |
| `(| Int Str)` | either type |
| `Str?` | a `Str` or `nil` |
| `Present` | any value except `nil` |
| `Any` | any value |
| `Nil` | only `nil`; as a result type, "returns nothing" |
| `Self` | the declaring type, in a message signature |

`(alias Name Str)` gives a type expression a name. A record or enum's name is
itself a type expression.

Annotations are checked when a value crosses them, including the items of a
collection: `(Person ^tags [1])` against `^tags (List Str)` fails with
`expected (List Str), got (List Int)`.

> **Why:** Gene has no `cast`. A value whose type is not known yet, such as
> one typed `Any`, is checked when it reaches an annotation, so
> `(let n : Int x)` is already a checked narrowing: it either gives an Int or
> raises `var 'n' expected Int, got Str`.
