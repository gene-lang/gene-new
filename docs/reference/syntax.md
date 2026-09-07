# Values and reader syntax

**Status:** detailed design reference and rationale. The implemented contracts
are [reader](../spec/reader.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 1. The node

### 1.1 Anatomy

```gene
(task ^id 1 ^done false "write retro" @source "import") # plain data node
(Task ^id 1 ^done false "write retro")                  # constructed typed value
```

A lowercase symbolic head such as `task` is ordinary data. A constructed typed value uses the type value as its head, such as `Task`, and so does a literal: `42` projects `Int` as its head (§1.3). Message dispatch is on the receiver's runtime type, which for every shape except a symbol-tagged data node is exactly what `head` holds; a data node dispatches as the concrete `Node` type, not as its tag (§1.2).

A node has four slots:

```text
head   singular identity / dispatch face
props  named side data, keyed by Sym
body   ordered positional data
meta   information about the node, ignored by value semantics
```

Props and body are value anatomy. Meta is worn, not grown.

### 1.2 `Node` anatomy

Every value exposes the four node projections. That is a statement about
**anatomy, not membership**: `Node` itself is a concrete type, not a universal
protocol and not a supertype of everything. The projections are library
functions that accept any value, and they are also messages on the `Node` type,
which is how any node-shaped receiver — a data node or a typed instance —
answers them:

```gene
($head v) ($props v) ($body v) ($meta v)   # any value
(n .head) (n .props) (n .body) (n .meta)   # node receivers
```

A data node's dispatch face is the `Node` type, so `(impl P for Node …)` applies
to `(f 1 2)` and to quasiquoted templates. A typed instance keeps its *own* type
as its dispatch face and reaches the projections because it is structurally a
node — not because it is an instance of `Node`.

The annotation says the same thing, because it is the same rule: `[n : Node]`
accepts a data node and rejects a typed instance, an enum value, and a scalar.
**`Any` is the root type** — it is what accepts every value. Node shape for a
non-node is a *conversion*, not a subtyping relation:

```gene runnable
(type Task ^props {^id Int})

((fn [n : Node] 1) (quote (f 1 2)))   # 1
((fn [x : Any] 1) (Task ^id 1))       # 1
(try ((fn [n : Node] 1) (Task ^id 1))
  catch TypeError $ex/expected)    # "Node" — a Task is not a Node
```

An uppercase head does not make a node typed: `(quote (Declaration ^name "h"))`
is tagged by the *symbol* `Declaration` and is still a data node. Only an actual
type value in `head` makes an instance.

This is homoiconicity as projection, not representation. An `Int`, `Str`, `Fn`, `Stream`, module, and heap node can expose node shape without sharing memory layout.

### 1.3 Pure projections

```gene
42            # bare head / scalar value
[1 2 3]       # pure body / list
{^a 1 ^b 2}   # pure props / PropMap
(t ^a 1 2 3)  # general node
```

`PropMap` is a symbol-keyed map:

```gene
(type PropMap
  : (Map Sym Any))
```

General maps are `(Map K V)`. Literal `{^a 1}` creates a `PropMap`, not an arbitrary-key map.

Every shape the reader produces projects as a node, and its `head` is its type:
`42` reads as `(Int 42)`, `[1 2]` as `(List 1 2)`, `{^a 1}` as `(Map ^a 1)`.
That is the same slot a data node fills with its tag and a typed instance with
its type, so `head` means one thing across every shape.

```gene runnable
($head 42)   # Int
($props 42)  # {}
($body 42)   # [42]
($meta 42)   # {}

($head [1 2])   # List
($body [1 2])   # [1 2]

($head {^a 1})  # Map
($props {^a 1}) # {^a 1}
($body {^a 1})  # []
```

A literal is a fixpoint of `body`, not of `head`: `($body 42)` is `[42]`. A walk
that descends through `body` therefore needs an explicit base case, and `leaf?`
is how a program names it without enumerating kinds:

```gene runnable
($leaf? 42)     # true
($leaf? [1 2])  # false

(fn walk [n]
  (if_not ($leaf? n)
    ((($body n) .to_stream) .each walk)))
```

A `Cell` is a leaf: its canonical body holds the current value, but that
content is state rather than structure, so a structural walk stops at the cell.
A walk that wants cell contents reads `get` explicitly — walking into mutable
state would also let a rebuilder flatten a cell into a plain node.

The projection is total: **every value has a canonical Node representation**.
For the shapes above it is the shape itself, and `head` is the value's runtime
type wherever the runtime defines one. A value whose observable state is a
single Gene value exposes it as its body: a cell `c` holding `v` projects as
`(Cell v)` — `($head c)` is `Cell`, `($body c)` is `[v]`, a snapshot of the
current value. Kinds whose state is not reachable as Gene data — streams,
channels, buffers, tasks, environments — project their type as a head-only
canonical node. A function has no registered type identity, keeps its own
`head`, and matches no node pattern.

`props`, `body`, and `meta` return detached, shallow snapshots. Mutating the
returned map/list never changes the projected node, but values inside the
snapshot retain their ordinary identities: a nested mutable list, map, cell,
or node is still shared until it is explicitly copied or frozen.

### 1.4 Meta

Syntax:

```gene
@name value
@@flag       # sugar for @flag true
```

Rules:

- meta is ignored by equality, hashing, construction validation, and ordinary pattern matching;
- if the core language enforces or consumes it, it is a prop;
- if it is descriptive/tool/user information, it is meta;
- patterns see meta only when the pattern explicitly mentions meta;
- reader/compiler may stamp meta such as `@file`, `@line`, `@col`, `@expanded-from`.

Meta is descriptive but not a safety bypass. Deep `freeze`, `Send` validation,
and structural serialization traverse meta with the same rules used for node
props and body. A non-Send or non-serializable value remains so when reachable
only through meta.

### 1.5 Equality and identity

```gene
(== a b)      # structural equality, meta-blind
(!= a b)      # structural inequality: exactly (! (== a b))
(same? a b)   # scalar value identity, heap/container reference identity
```

`same?` treats immutable scalar-like values such as numbers, booleans, symbols,
characters, strings, `nil`, and `void` by value. Heap/container values such as
lists, maps, nodes, namespaces, cells, streams, functions, types, and protocols
compare by object identity. Hashing follows `==`. Meta never changes hash keys.

### 1.6 `nil`, `void`, and `Never`

```gene
nil  : Nil
void : Void
```

`nil` is an explicit empty value. It is storable everywhere.

`void` is a singleton value meaning no value / delete / skip.

```gene
(var a void)
(== a void) # true
```

Container normalization:

- storing `void` in a prop/map entry removes the entry;
- storing `void` in a list/body position stores `nil`, preserving position;
- yielding `void` into a stream emits no item;
- `map` converts a callback result of `void` to `nil` before storing or emitting it;
- `filter_map` explicitly drops callback results of `void`.

Examples conceptually:

```gene
{^name nil}    # name exists, value is nil
{^name void}   # same as {}; name is removed
```

Selector missing lookup returns `void`, not `nil`. Pattern matching distinguishes present `nil` from missing/`void`.

The two-absence model has first-class prelude predicates. Absence means either
`nil` or `void`; presence means a real value, so `false`, `0`, and `""` are
present:

```gene
($nil? v)      # v is exactly nil
($void? v)     # v is exactly void
($absent? v)   # v is nil or void
($present? v)  # v is neither nil nor void
```

| `v`            | `nil?` | `void?` | `absent?` | `present?` |
| -------------- | ------ | ------- | --------- | ---------- |
| `nil`          | true   | false   | true      | false      |
| `void`         | false  | true    | true      | false      |
| `false`, `0`, `""`, other | false | false | false | true |

The absence-coalescing operator `??` yields its first **present** operand,
else the last, short-circuiting like `||`:

```gene
(?? a b c)         # first present of a, b, c; else c
(?? user/name "?") # the name, or "?" when the key is missing (void) or nil
```

`??` fills both `void` and `nil` (`absent?`), unlike `||`, which stops at the
first truthy operand and therefore replaces a stored `false`. Use `||` for
boolean logic and `??` for defaults over absence.

`Void` is Gene's singleton type of `void`. It is **not** the uninhabited type.

`Never` is the uninhabited type. It has no values. Use it for impossible results/errors, such as `(Stream User Never)`.

Truthiness:

```gene
false nil void # falsy
```

Everything else is truthy.

---

## 2. Lexical surface

```gene
^name v      # prop
@name v      # meta
^^flag       # prop flag = true
@@flag       # meta flag = true
`x           # template / quote
%x           # escape from quoted-like context to lexical value
x...         # spread/gather
'c'          # Char
"s" $"a ${x}" # strings and interpolation
x : T        # annotation
^due T?      # optional prop schema: nil-admitting type => omissible
_            # wildcard / ignore
name!        # reserved fexpr declaration/invocation marker (§3/§11.1)
(a; b; c)    # pipe: pure reader head-folding
(a -> f c)   # sequenced value pipeline; previous value is first argument
(xs => f c)  # per-item stage: prepares once and always returns a lazy Stream
(x .f a)    # message send; see Section 3 and docs/core.md §9
/user/name   # selector literal
x/user/name  # apply selector to x
#[a b]       # shallow immutable list
#{^a v}      # shallow immutable map / PropMap
#(h ^p v x)  # shallow immutable Gene/node value
```

Canonical forms:

```text
^^flag       => ^flag true
@@flag       => @flag true
`x           => (quasiquote x)
%x           => (unquote x)
x...         => (... x)
$"a ${x}"    => ($ "a " x)
(a; b c; d)  => (((a) b c) d)
(x .f a)    # lowers to a canonical send node; printer restores dot syntax
x/.f        # lowers to a canonical zero-argument path-send segment
/user/name   => (select user name)
x/user/name  => (path x user name) # context-neutral; see §2.1
/user/%field => (select user %field)
#[a b]       => (immutable_list a b)
#{^a v}      => (immutable_prop_map ^a v)
#(h ^p v x) => (immutable_node h ^p v x)
```

Reader literal/comment dispatch examples:

```gene
#[1 2 3]                 # shallow immutable List
#{^name "Alice"}         # shallow immutable PropMap
`#(user ^name "Alice")   # quoted shallow immutable Gene/node value
# line comment
#< nested block comment >#
#_ next-node-is-discarded
#! shebang
#"[a-z]+"im                # regular expression
#"""multi-line regex"""i # triple-quoted regular expression
#B#01000001                 # binary Bytes
#B16#4869                   # hexadecimal Bytes
#B64#SGk=                   # base64 Bytes
```

Reader precedence follows the ordered dispatch table in §2.2. In particular,
`#"` begins a regex and `#B#`/`#B16#`/`#B64#` begin byte literals. A `#` begins
a line comment only when followed by whitespace, `!`, or end of line/input;
every other `#` sequence (such as `#a`, `#1`, or `##`) is a read error
reserved for future reader syntax. `#_` followed by EOF is a read error.

### 2.1 Symbols, slash paths, qualified names, and division

`Sym` is an interned simple symbol. Examples: `abc`, `A123`, `+`, `-`, `<=`, `/`.

The reader recognizes glued slash paths as one syntactic family:

```gene
/user/name      # leading selector literal
user/name       # access chain in expression position
users/-1/name   # negative index segment
user/%field     # dynamic simple segment
```

A delimited `/` is an ordinary symbol and remains available as a normal callable, including prefix division. `//` is the remainder operator (§7.4), never a path: a selector needs at least one segment, so `//` reads as the operator symbol, while an interior `//` in a path still collapses (`a//b` is `a/b`):

```gene
(/ a b)
```

A protocol message is qualified with `:` — `Proto:msg` — which is structural only
when glued between two symbol characters, so `x : T`, `open : alias`, `{{a : 1}}`,
and a trailing `^key:` keep their meanings. It reads as a message expression
whose protocol expression is `Proto` and whose message name is `msg`.

Slash is also the reader spelling for qualified names in static contexts such as built-in namespace names, type names, and namespace members. File/string module paths are written in `from "path"` import clauses and are normalized by the module loader:

```gene
(import gene/stream [map, filter])       # built-in / already-loaded namespace path
(import [map : stream_map] from "gene/stream") # module path string
C/Int32
Stream/next
Color/red
$fs/ReadDir
```

Context determines interpretation:

- expression value position: `user/name` desugars to selector application, `((select name) user)`;
- leading slash expression: `/user/name` is a selector literal;
- import namespace position: `gene/stream` is a built-in or already-loaded namespace path;
- type/member declaration contexts: `C/Int32`, `Stream/next`, and `Color/red` are qualified-name resolution, not runtime selector evaluation;
- module path strings in `from "path"` are resolved and normalized by the module loader.

The reader may represent selector paths and qualified names with related path nodes, but the compiler resolves them by context. Static qualified names are resolved during name/type checking and must not require evaluating runtime values named `C`, `Stream`, or `net`.

A slash path is member selection: `a/b` denotes the member `b` of the value the
base `a` denotes. A namespace member is its bound function or value, and a type
member may be data such as the enum variant `Color/red`. Messages are excluded:
`P/m` and `T/m` are errors, because `:` is the message spelling. Native and
standard-library functions hold no special status: they are ordinary members
reached by this same selection, so the language defines **no hard-coded mapping
from particular names or paths to native functions**. `gene/str/join`, a user
`ns/helper`, and `Color/red` use the same member-selection mechanism.

Resolving a path is separate from invoking the result. A function member is
applied in call-head position, `(ns/f x)`; a protocol message is sent with a
dot descriptor,
`(x .P:m)`, which dispatches on the receiver's type (§3, §10). `P:m` on its
own is the first-class message value.

Where the selection is resolved — compile time or runtime — is an implementation
choice constrained by soundness, not part of the semantics. When the base is a
compile-time-known binding that cannot be reassigned or shadowed at the use site
— a reserved stdlib root, or a namespace, protocol, or type declaration in scope
— the compiler resolves the whole path at compile time to a constant member and
MAY emit it directly, including a direct native call in call position. That
mapping is a performance optimization that must be observationally identical to
selecting the member from the base value, and it privileges no specific name.
When the base is a genuinely dynamic value, the path desugars to runtime selector
application, `((select b) a)`. Ordinary lexical shadowing always applies to the
base name: a local binding wins over an ambient stdlib namespace, and the path
then follows the local value. Declaration, type, protocol-message, and
namespace-import contexts always resolve statically.

The printer must preserve token boundaries so slash paths and delimited symbols round-trip exactly. `/` remains available as a normal callable symbol when delimited.

### 2.2 Reader grammar sketch

This EBNF describes the implemented reader surface before semantic resolution.
The compiler later classifies path nodes as selector literals, expression
access chains, or static qualified names according to context. Ordered lexical
dispatch below is part of the grammar: a recognized literal prefix wins before
the more general atom or comment branch.

```ebnf
program        = spacing, { form, spacing }, eof ;

form           = spread_form ;
spread_form    = primary, [ "..." ] ;

primary        = immutable_node
               | immutable_vector
               | immutable_prop_map
               | general_map
               | node
               | vector
               | prop_map
               | quasiquote
               | unquote
               | interpolated_string
               | char
               | regex
               | long_string
               | string
               | bytes
               | datetime
               | date
               | time
               | path_form
               | atom ;

node           = "(", spacing, [ node_sequence ], spacing, ")" ;
immutable_node = "#(", spacing, [ node_sequence ], spacing, ")" ;
node_sequence  = segment, { segment_delimiter, segment } ;
segment        = element, { separator, element } ;
segment_delimiter = spacing, ";", spacing
                  | spacing, "->", spacing
                  | spacing, "=>", spacing ;
vector         = "[", spacing, [ form, { separator, form } ], spacing, "]" ;
immutable_vector = "#[", spacing, [ form, { separator, form } ], spacing, "]" ;
prop_map       = "{", spacing, { map_entry, spacing }, "}" ;
immutable_prop_map = "#{", spacing, { map_entry, spacing }, "}" ;
general_map    = "{{", spacing,
                   { form, spacing, ":", spacing, form, separator },
                 "}}" ;

element        = prop_entry | meta_entry | form ;
prop_entry     = prop_value | prop_flag ;
meta_entry     = meta_value | meta_flag ;
map_entry      = map_value | prop_flag ;
prop_value     = "^", symbol, spacing, form ;
map_value      = "^", symbol, spacing, [ ":", spacing ], form ;
prop_flag      = "^^", symbol ;
meta_value     = "@", symbol, spacing, form ;
meta_flag      = "@@", symbol ;

quasiquote     = "`", form ;
unquote        = "%", spread_form ;

string         = '"', { string_char | escape }, '"' ;
long_string    = '"""', { long_string_char | escape }, '"""' ;
interpolated_string = "$", ( string | long_string ) ;
regex          = "#", ( string | long_string ), { ascii_letter } ;
char           = "'", ( unicode_scalar | char_escape ), "'" ;
bytes          = binary_bytes | hex_bytes | base64_bytes ;
binary_bytes   = "#B#", binary_digit, { binary_digit | byte_continuation } ;
hex_bytes      = "#B16#", hex_digit, { hex_digit | byte_continuation } ;
base64_bytes   = "#B64#", base64_digit, { base64_digit | byte_continuation } ;
byte_continuation = "~", whitespace, { whitespace } ;

date           = digit, digit, digit, digit, "-", digit, digit, "-",
                 digit, digit ;
time           = time_body, [ time_timezone ] ;
datetime       = date, "T", time_body, [ offset_timezone ] ;
time_body      = digit, digit, ":", digit, digit,
                 [ ":", digit, digit ], [ fraction ] ;
fraction       = ".", digit, { digit } ;
time_timezone  = offset_timezone | timezone_name ;
offset_timezone = "Z" | ( ( "+" | "-" ), digit, digit, ":", digit, digit,
                           [ timezone_name ] ) ;
timezone_name  = "[", timezone_name_char, { timezone_name_char }, "]" ;

path_form      = selector_literal | access_or_qualified_path ;
selector_literal = "/", path_segment, { "/", path_segment } ;
access_or_qualified_path = atom, "/", path_segment, { "/", path_segment } ;
path_segment   = symbol | integer | "%", symbol | path_send_segment ;
path_send_segment = [ "?" ], ".", [ "%" ], symbol ;

atom           = float | integer | hex_integer | "true" | "false"
               | "nil" | "void" | symbol ;
hex_integer    = [ "-" ], "0x", hex_digit, { hex_digit } ;
separator      = spacing, [ "," ], spacing ;
spacing        = { whitespace | line_comment | block_comment | datum_comment } ;
line_comment   = "#", ( whitespace | "!" | newline | eof ),
                 { not_newline }, ( newline | eof ) ;
block_comment  = "#<", { block_comment | any_char_but_unmatched_end }, ">#" ;
datum_comment  = "#_", spacing, form ;
```

A `#` not followed by one of the recognized continuations (`(`, `[`, `{`,
`"`, `_`, `<`, `!`, `B`, whitespace, or end of line/input) is a read error:
that lexical space is reserved for future reader syntax such as parser macros
or tagged literals.

Ordered lexical dispatch:

| Prefix | Reader branch |
|---|---|
| `0x` followed by a hex digit | hexadecimal `Int` literal (§7.4), when the run ends the atom |
| `#B#` followed by a binary digit | binary `Bytes` |
| `#B16#` followed by a hex digit | hexadecimal `Bytes` |
| `#B64#` followed by a base64 digit | base64 `Bytes` |
| `#(`, `#[`, `#{` | shallow immutable node, list, or prop map |
| `#"` / `#"""` | regular or triple-quoted regex, followed by optional ASCII flags |
| `#_` | datum comment; discard exactly the next form as spacing |
| `#<` | nested block comment through the matching `>#` |
| `#!` | shebang-style line comment (the same spacing semantics as a line comment) |
| `#` followed by whitespace or end of line/input | line comment through newline or EOF |
| any other `#` | read error; reserved for future reader syntax |
| digit prefix matching `date`, `time`, or `datetime` | temporal literal, before numeric/atom fallback |
| any remaining atom start | number or symbol |

Lexical notes:

- A node sequence uses either `;` head-folding delimiters or `->`/`=>`
  value-pipeline delimiters at one parenthesis depth, never both; `->` and `=>`
  may be mixed with each other. Nested nodes choose independently. Only a whole
  `->` or `=>` atom is a delimiter; `->name` and `a->b` remain symbols.
- The segment before the first `->`/`=>` is a single form; a multi-form
  segment there is a read error.
- `access_or_qualified_path` is intentionally context-neutral at reader time.
- Short slash syntax permits `%name` segments only; complex stages use long `(select ... %(expr) ...)` syntax.
- A delimited `/` token is a `symbol`, not a `path_segment` by itself.
- `//` is the symbol for the remainder operator; `selector_literal` requires at
  least one segment, so `//` is never an empty selector.
- Ordinary `^key` and `@key` entries always require a following form. Only
  `^^key` and `@@key` are flag-only, and both store `true`; the same `^^key`
  rule applies in mutable and immutable prop maps.

### 2.3 Strings and interpolation

A `Char` is one Unicode scalar value, not a grapheme cluster. Strings are UTF-8 atomic values, not arrays of chars. Iteration is explicit with `(chars s)`, `(graphemes s)`, and `(bytes s)`.

Plain strings never interpolate. Interpolation requires `$`:

```gene
$"hello ${name}"
$"sum = $(+ a b)"
```

Long strings use triple quotes and may contain unescaped `"` characters. They
can also be interpolated by prefixing the opening delimiter with `$`:

```gene
"""say "hello" """
$"""hello "${name}\""""
```

Canonical form:

```gene
($ "hello " name)
```

`$` is a pure variadic function that calls `ToStr` and concatenates.

### 2.4 Spread and gather

`...` gathers in binding positions and spreads in value positions.

```gene
(fn f [xs...])
(f xs...)
(match x
  (when (Task title _...)
    ...))
`(div %(children)...)
```

Spread merges anatomy: body into body, props into props, rightmost wins, head is dropped, meta is not merged.

In type schemas, `T...` is a repetition marker rather than value spread:

```gene
^body [Note...] # zero or more Note body elements
```

### 2.5 Templates

Backtick creates a template / quoted node. Quotation depth follows the usual
quasiquote rule: each backtick raises depth, each `%` lowers it, and evaluation
fires at depth zero.

```gene
`(div "hello")
```

A single backtick fires at depth zero, so its `%` holes resolve immediately from
lexical scope:

```gene
(var name "Gene")
`(div %name)          # => (div "Gene")
```

A double backtick defers one level: the inner `%` holes stay unresolved and the
result is a depth-one template you can store, pass, and force later.

```gene
(var t ``(div %name)) # t is the deferred template `(div %name)
```

Force a deferred template with `eval`, naming the environment its holes resolve
against. `eval` always requires an explicit `^in` and never captures caller
locals (§11.1), so the environment is stated: `this_mod` carries the current
module's bindings, and `^bindings` supplies values that are not module-level
(such as function locals).

```gene
(var name "Gene")
(eval t ^in (env ^module this_mod))          # => (div "Gene")   ; module-level name
(eval t ^in (env ^bindings {^name name}))    # => (div "Gene")   ; explicit value
```

### 2.6 Pipes

`;` is pure reader sugar. It folds the previous segment node into head position of the next segment.

```gene
(a; b)        # => ((a) b)
(a; b c; d)   # => (((a) b c) d)
(xs filter p; map f) # => ((xs filter p) map f)
```

The first segment is preserved as read. A plain pipe folds the previous segment
into head position; it does not thread it in as an argument. For a data-flow
chain, compose pipes with dot message sends (Section 3):

```gene
(xs .to_stream; .filter p; .map f; .take 10)
# reader keeps every send: (((( xs .to_stream) .filter p) .map f) .take 10)
```

Each dot descriptor here is a receiver-first message send, **not** a reader
rewrite to a flipped call `(f x)` (§3). A dot send dispatches and only
dispatches: `filter`, `map`,
`take`, and `to_stream` are **generic functions** (§6.2) — one name each,
dispatching on the receiver's runtime type, with no lexical fallback to a plain
function. A generic function's methods are the type-direct messages of the
types that serve it, so `(xs .map f)` and `($map xs f)` are the same dispatch,
and sending a name the receiver's type does not define is still a recoverable
`MessageError`. The eager kinds answer in their own kind — a `List` maps to a
`List` — so `to_stream` is how a pipeline enters the lazy stream tier when it
wants laziness, not a gate the operations hide behind.

`;` has no placeholder or argument-slot mode. An `_` in a later segment remains
that segment's ordinary `_` symbol; the reader never substitutes the preceding
segment for it:

```gene
(a; b _ c)  # => ((a) b _ c), not (b (a) c)
```

This keeps `;` one-purpose syntax: the preceding segment becomes the next
node's head. Sequenced value threading and explicit argument slots are a
separate feature using `->` and `=>`; see `docs/pipelines.md`.

### 2.7 Sequenced value pipelines

`->` separates ordered value-pipeline stages. The reader preserves the initial
expression and every stage as syntax-only `vkPipeline` structure; it does not
rewrite the source directly to nested calls, because ordinary calls evaluate
their callee before their arguments.

```gene
(a -> f c)       # call shape (f a c), but a evaluates before f
(a -> f c _)     # call shape (f c a)
(a -> f ^k _)    # call shape (f ^k a)
(a -> _ c)       # call the value of a with c
(a -> _)         # call the value of a with no arguments
```

With no exact direct `_`, the incoming value becomes the first positional
argument. One exact `_` may instead occupy the stage head, a direct positional
argument, or a direct property value. More than one direct slot is a read
error. Slot detection does not descend into nested forms or containers.

The value in front of the first delimiter is a **single form**, never an
implicitly wrapped segment:

```text
((a b) -> f c)   # the call (a b) enters the pipeline
(a b -> f c)     # ReadError: wrap the call in its own parentheses
```

Every stage obeys this order:

1. evaluate the incoming expression exactly once;
2. retain its value in compiler-owned, user-inaccessible storage;
3. evaluate the stage callee;
4. evaluate named and positional argument expressions by the ordinary call
   contract, loading the retained value at the selected slot;
5. invoke the ordinary call or dot-send machinery.

Pipeline stages associate left-to-right, and the final stage inherits tail
position. A pipeline is executable syntax rather than a nominal runtime data
type: it has no constructor, message surface, serialization, or `Send`
contract. Quote/quasiquote may carry it as inert syntax and `eval` may compile
it later. `#(...)` retains an immutable source/call-site marker and still
executes; only quote makes a pipeline inert. Props and meta belong to their
individual stage and round-trip with it.

`=>` is the per-item delimiter. Its stage runs once for every item of the
incoming value, and the slot rules are the stage's own — the item, not the
collection, lands in the slot:

```gene
(xs => f c)              # per item: (f item c)
(xs => f c _)            # per item: (f c item)
(xs => _ .render)        # per item: (item .render)
```

**Every `=>` returns a new lazy Stream, including the final stage.** A `->`
passes its whole input to one ordinary call and returns that call's actual
result. Neither arrow collects, flattens, awaits, or restores a source kind.

| Stage | Preparation | Result |
| --- | --- | --- |
| `->` | input, then ordinary callee and argument sequencing | ordinary call result |
| `=>` | fixed components once, then normal stream conversion | lazy Stream of per-item results |

```gene
(rows => save)                      # lazy; no save calls before consumption
(rows -> $each save)                # explicit immediate per-row effects
(rows => parse -> $into [])         # explicit collection
(producer => step -> $take 5 -> $into [])   # bounded demand
```

Every `=>` converts through the ordinary `to_stream` operation (§6.2). A Stream
retains its identity and position; a user type joins by declaring a type-direct
conversion returning a Stream. Map inputs require explicit `to_pairs_stream`,
which yields one `[key value]` item with a `Sym` key for a PropMap. An explicit
Map `$each` still visits values. Unsupported scalars and nil fail conversion.

Fixed callees, message-value expressions, and arguments are captured once,
including symbol reads. Spread layout is expanded once after fixed expression
evaluation, preserving shallow element identity. Defaults run per invocation.
Direct guarded item sends still prepare their fixed expressions once; a
lambda provides per-item guarded evaluation when that is wanted.

Preparation precedes conversion and happens even with empty input or a later
`take 0`. Item calls run only when demanded, retaining nil and converting void
to nil;
List, Stream, and Task results remain individual items. A consuming `->` call
completes before the next stage prepares. Errors are terminal on the demand
path, preserve earlier effects, and provide no rollback.

Adapters retain their prepared environment until exhaustion or close, and
closing a mapping adapter closes its attached upstream even before its first
pull. `take` detaches at its limit; `take 0` detaches during construction.
Resource-backed original sources still need lexical ownership when a bound
leaves them resumable. Abandoning an unpulled Stream does not promise
deterministic resource cleanup.

The two delimiters mix freely at one depth. `;` mixes with neither: nest one
form explicitly instead. Each stage owns a separate head, props, meta, body,
slot, and source location, so property names may repeat across stages while
duplicate properties within one stage remain errors. Only a whole `->` or `=>`
atom delimits, so `->name`, `a->b`, and `-->` remain ordinary symbols. The
detailed design and implementation contract is `docs/pipelines.md`.

---
