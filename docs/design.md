# Gene — Language Design

**Status:** pre-implementation draft, v2 selector-core surface  
**Design:** G. Cao + ChatGPT, June 2026  
**Scope:** core language design for review.

This draft reflects the current direction:

- one node model;
- callable-first evaluation;
- explicit flipped calls with `~`;
- optional lexical `self` sugar;
- slash selectors as the general traversal/transformation abstraction;
- `Stream`/generators for lazy processing;
- stream-based parser design;
- typed recoverable errors with `^errors` and `try/catch/ensure`;
- runtime capability values, but **no static `^effects` system in MVP**;
- protocol-local derivation through `^impl`, `^derive`, and protocol `derive` forms;
- `fn!` runtime fexprs for Env-aware syntax calls, and `macro` for limited compile-time templates;
- direct type construction for canonical data, plus `new`/`ctor` for constructor logic with a pre-created `self` instance;
- basic generics and gradual typed boundaries;
- a stable native extension ABI and typed C FFI designed early;
- explicit `Env`/`eval` support for generated code;
- explicit mutable state, shallow immutable literals, structured concurrency, typed channels, and actors;
- a concrete Application / Package / Module / Namespace loading and execution model.

The standalone `query` feature is removed from the core. Traversal, extraction, filtering, mapping, module introspection, and compile-time discovery are expressed with selectors plus ordinary Gene code.

---

## 0. Thesis

Gene has one syntactic and semantic unit: the **node**. A node can be read as data, code, type/shape, or selector/navigation plan. Gene uses one canonical node representation plus reader sugars. Each sugar desugars to ordinary nodes or first-class values with known heads.

Core consequences:

- every value exposes `head`, `props`, `body`, and `meta` through the `Node` protocol;
- code is data;
- types are nodes, usually instances of `Type`;
- patterns are nodes with binders and holes;
- selectors are first-class callable values;
- runtime fexprs, macro templates, and protocol-local derivation operate on nodes;
- modules are persisted node trees with root namespaces;
- applications create the runtime/module graph and execute an entry module;
- concurrent state is isolated through structured tasks, typed channels, and actors.

---

## 1. The node

### 1.1 Anatomy

```gene
(task ^id 1 ^done false "write retro" @source "import") # plain data node
(Task ^id 1 ^done false "write retro")                  # constructed typed value
```

A lowercase symbolic head such as `task` is ordinary data. A constructed typed value uses the type value as its head, such as `Task`. Message dispatch is usually based on the receiver's runtime type; for constructed instances the head is the type value, while scalars expose type information through the runtime even though their node head is the scalar itself.

A node has four slots:

```text
head   singular identity / dispatch face
props  named side data, keyed by Sym
body   ordered positional data
meta   information about the node, ignored by value semantics
```

Props and body are value anatomy. Meta is worn, not grown.

### 1.2 `Node` protocol

Every value implements `Node`:

```gene
(protocol Node
  (message head  [x : Self] : Any)
  (message props [x : Self] : PropMap)
  (message body  [x : Self] : List)
  (message meta  [x : Self] : PropMap))
```

This is homoiconicity as protocol, not representation. An `Int`, `Str`, `Fn`, `Stream`, module, and heap node can expose node shape without sharing memory layout.

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
  ^is (Map Sym Any))
```

General maps are `(Map K V)`. Literal `{^a 1}` creates a `PropMap`, not an arbitrary-key map.

Scalar values are node fixpoints for `head` and have empty props/body/meta unless explicitly wrapped:

```gene
(head 42)  # 42
(props 42) # {}
(body 42)  # []
(meta 42)  # {}
```

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
- yielding or producing `void` into a stream skips the item.

Examples conceptually:

```gene
{^name nil}    # name exists, value is nil
{^name void}   # same as {}; name is removed
```

Selector missing lookup returns `void`, not `nil`. Pattern matching distinguishes present `nil` from missing/`void`.

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
^due? T      # optional prop schema
_            # wildcard / ignore
name!        # convention for visible syntax behavior (`fn!`, `macro`) and mutation ops (§11/§12)
(a; b; c)    # pipe: pure reader head-folding
(x ~ f a)    # message send; see Section 3 and docs/core.md §9
/user/name   # selector literal
x/user/name  # apply selector to x
#[a b]       # shallow immutable list
#{^a v}      # shallow immutable map / PropMap
#(h ^p v x)  # shallow immutable Gene/node value
```

Canonical forms:

```gene
^^flag       => ^flag true
@@flag       => @flag true
`x           => (quasiquote x)
%x           => (unquote x)
x...         => (... x)
$"a ${x}"    => ($ "a " x)
^due? T      => ^due (? T)
(a; b c; d)  => (((a) b c) d)
(x ~ f a)    # preserved as read; resolved receiver-first at compile/dispatch
             # time (docs/core.md §9) — not a reader rewrite to (f x a)
/user/name   => (select user name)
x/user/name  => (x ~ (select user name))
/user/%field => (select user %field)
#[a b]       => (immutable-list a b)
#{^a v}      => (immutable-prop-map ^a v)
#(h ^p v x) => (immutable-node h ^p v x)
```

Reader forms beginning with `#`:

```gene
#[1 2 3]                 # shallow immutable List
#{^name "Alice"}         # shallow immutable PropMap
#(user ^name "Alice")    # shallow immutable Gene/node value
# line comment
#< nested block comment >#
#_ next-node-is-discarded
#! shebang
```

Reader precedence is determined by the character immediately following `#`: `[`, `{`, and `(` begin immutable literals; `_`, `!`, and `<` begin their dedicated reader forms; other uses begin a line comment. `#_` followed by EOF is a read error.

### 2.1 Symbols, slash paths, qualified names, and division

`Sym` is an interned simple symbol. Examples: `abc`, `A123`, `+`, `-`, `<=`, `/`.

The reader recognizes glued slash paths as one syntactic family:

```gene
/user/name      # leading selector literal
user/name       # access chain in expression position
users/-1/name   # negative index segment
user/%field     # dynamic simple segment
```

A delimited `/` is an ordinary symbol and remains available as a normal callable, including prefix division:

```gene
(/ a b)
```

Slash is also the reader spelling for qualified names in static contexts such as built-in namespace names, type names, protocol messages, and namespace members. File/string module paths are written in `from "path"` import clauses and are normalized by the module loader:

```gene
(import std/stream [map, filter])       # built-in / already-loaded namespace path
(import [map : stream-map] from "std/stream") # module path string
C/Int32
Stream/next
Color/red
Fs/ReadDir
```

Context determines interpretation:

- expression value position: `user/name` desugars to selector application, `((select name) user)`;
- leading slash expression: `/user/name` is a selector literal;
- import namespace position: `std/stream` is a built-in or already-loaded namespace path;
- type/member declaration contexts: `C/Int32`, `Stream/next`, and `Color/red` are qualified-name resolution, not runtime selector evaluation;
- module path strings in `from "path"` are resolved and normalized by the module loader.

The reader may represent selector paths and qualified names with related path nodes, but the compiler resolves them by context. Static qualified names are resolved during name/type checking and must not require evaluating runtime values named `C`, `Stream`, or `net`.

The printer must preserve token boundaries so slash paths and delimited symbols round-trip exactly. The standard library may also expose `(div a b)`, but `/` remains available as a normal callable symbol when delimited.

### 2.2 Reader grammar sketch

This EBNF is the parser starting point. It describes the reader surface before semantic resolution. The compiler later classifies path nodes as selector literals, expression access chains, or static qualified names according to context.

```ebnf
program        = spacing, { form, spacing }, eof ;

form           = spread_form ;
spread_form    = primary, [ "..." ] ;

primary        = immutable_node
               | immutable_vector
               | immutable_map
               | node
               | vector
               | map
               | quasiquote
               | unquote
               | interpolated_string
               | char
               | string
               | path_form
               | atom ;

node           = "(", spacing, { element, spacing }, ")" ;
immutable_node = "#(", spacing, { element, spacing }, ")" ;
vector         = "[", spacing, [ form, { separator, form } ], spacing, "]" ;
immutable_vector = "#[", spacing, [ form, { separator, form } ], spacing, "]" ;
map            = "{", spacing, { prop_entry, spacing }, "}" ;
immutable_map  = "#{", spacing, { prop_entry, spacing }, "}" ;

element        = prop_entry | meta_entry | form ;
prop_entry     = prop_key, spacing, [ form ] ;
meta_entry     = meta_key, spacing, [ form ] ;
prop_key       = "^^", symbol | "^", symbol, [ "?" ] ;
meta_key       = "@@", symbol | "@", symbol ;

quasiquote     = "`", form ;
unquote        = "%", spread_form ;

path_form      = selector_literal | access_or_qualified_path ;
selector_literal = "/", path_segment, { "/", path_segment } ;
access_or_qualified_path = atom, "/", path_segment, { "/", path_segment } ;
path_segment   = symbol | integer | "%", symbol | "~", symbol ;

atom           = number | symbol ;
separator      = spacing, [ "," ], spacing ;
spacing        = { whitespace | line_comment | block_comment | datum_comment } ;
line_comment   = "#", not_one_of("[", "{", "(", "_", "!", "<"), { not_newline }, newline ;
block_comment  = "#<", { block_comment | any_char_but_unmatched_end }, ">#" ;
datum_comment  = "#_", spacing, form ;
```

Lexical notes:

- `#[`, `#{`, and `#(` start shallow immutable literals.
- `#_`, `#!`, and `#<` are dedicated reader forms.
- Other `#...` starts a line comment.
- `access_or_qualified_path` is intentionally context-neutral at reader time.
- Short slash syntax permits `%name` segments only; complex stages use long `(select ... %(expr) ...)` syntax.
- A delimited `/` token is a `symbol`, not a `path_segment` by itself.

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
locals (§11.1), so the environment is stated: `this-mod` carries the current
module's bindings, and `^bindings` supplies values that are not module-level
(such as function locals).

```gene
(var name "Gene")
(eval t ^in (env ^module this-mod))          # => (div "Gene")   ; module-level name
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
chain, compose pipes with `~` message sends (Section 3):

```gene
(xs ~ filter p; ~ map f; ~ take 10)
# reader keeps every send: (((xs ~ filter p) ~ map f) ~ take 10)
```

Each `~` here is a receiver-first message send, **not** a reader rewrite to a
flipped call `(f x)`. The reader preserves the send form and resolution happens
at dispatch time. A `List`/`Stream` defines no `filter`/`map`/`take` message, so
each name resolves through to the plain stdlib function and the chain then
behaves like `(take (map (filter xs p) f) 10)`. Had the receiver's type defined
`filter`, that message would dispatch instead and this reduction would not hold.

A segment containing `_` is a slot form: the folded previous segment lands at
`_` instead of head position.

```gene
(a; b _ c)                  # => (b (a) c)
(x; parse; (|| _ default))  # => (|| ((x) parse) default)
```

The previous segment is still wrapped as a node `(a)`, so a pipe threads a call,
not a bare value: `(a; b _ c)` is `(b (a) c)`, not `(b a c)`.

> **Future direction (non-MVP):** a real left-to-right data-flow pipeline
> operator, spelled `->`, is a likely addition — e.g.
> `(xs -> (filter /odd?) -> times5)`, where each stage receives the previous
> stage's value. It is distinct from `;` (reader-only head-folding) and from `~`
> (message send). `->` is reserved for it and unused today.

---

## 3. Evaluation and callability

Gene has two callability protocols:

1. ordinary value callability, where arguments are evaluated before the callee receives them;
2. syntax callability (`fn!` / fexprs), where the callee receives raw syntax nodes plus the caller environment and decides what to evaluate.

Ordinary calls use a `Call` envelope:

```gene
(type Call
  ^props {^named PropMap ^site? Node}
  ^body  [Any...])

(protocol Callable
  (message apply [callee : Self, call : Call] : Any))
```

Syntax calls use a `SyntaxCall` envelope:

```gene
(type SyntaxCall
  ^props {^named PropMap ^site? Node}
  ^body  [Node...])

(protocol SyntaxCallable
  (message apply_syntax [callee : Self, call : SyntaxCall, caller-env : Env] : Any))
```

`Fn`, `Type`, `Selector`, protocol messages, native functions, and user-defined callable values implement `Callable`. `Fn!` values created by `fn!` implement `SyntaxCallable`.

To evaluate `(h ^p v c1 c2)`:

1. If `h` names a special form, use that special-form rule.
2. If `h` names a compile-time `macro`, expand it before runtime evaluation.
3. Otherwise evaluate `h` to a callee.
4. If the callee implements `SyntaxCallable`, build a `SyntaxCall` from the **unevaluated** prop/body syntax nodes and call `apply_syntax` with the caller `Env`. Ordinary argument evaluation does not happen.
5. Otherwise evaluate props/body into a `Call` envelope.
6. If the callee implements `Callable`, call `apply`.
7. Otherwise it is a call error.

This makes fexprs (`fn!`) a runtime feature, not a compile-time macro feature. A `fn!` can implement control flow, laziness, DSL evaluation, and explicit `eval` under a caller or sandbox `Env`, while ordinary `fn` remains simple and optimizable.

Syntax callability is a runtime property of the callee value, so it has an explicit compilation cost model:

- A call site whose callee is statically known not to implement `SyntaxCallable` — a special form, an expanded macro, a resolved `fn`/native binding, or a callee whose static type excludes `Fn!` — compiles to a direct call. No dispatch check is emitted and the argument syntax nodes are not retained.
- Every other call site compiles to a generic path: evaluate the head, check the callee for `SyntaxCallable`, then either hand over the retained syntax nodes or evaluate the arguments normally. In the MVP interpreter this is cheap because modules are persisted node trees — the argument nodes are alive regardless — so the added cost is one callee check before argument evaluation.
- `Fn!` is a sibling of `Fn` in the type hierarchy (§7.2), not a subtype. A `fn!` value does not satisfy an `Fn [...] ...`-typed parameter; passing one across that boundary is a recoverable `TypeError`. Typed regions compiled AOT therefore never hit the syntax path through function-typed values; an `Any`-typed callee keeps the generic path.

The generic-path check is the price of first-class fexprs. Code that must compile to direct calls should type its callees.

MVP approximation: call sites whose head is a statically tracked fn! name (definitions, direct `var` aliases, and `from "path"` imports) compile to the syntax path, and expression heads compile to the guarded generic path. The remaining arg-first fused call sites (for example a fn! flowing into an untyped function parameter that is then called) reject fn! callees with a recoverable error instead of silently evaluating arguments; full generic-path coverage for those sites is future work.

Normal calls are callable-first:

```gene
(f x y)
```

There is no implicit subject-call rule.

Message sends use `~`:

```gene
(x ~ f a b)   # send f to x: f resolves in x's context, then evaluates as (f x a b)
(x ~ X/f a b) # qualified: X/f resolves lexically, then (X/f x a b)
(~ f a b)     # send to lexical self: (self ~ f a b)
```

For an unqualified send, `f` is resolved receiver-first: the receiver's
type-direct messages (walking `^is`), then protocol messages provided by
impls visible for the receiver's type, then the enclosing lexical scope as a
fallback — so pipeline sends like `(xs ~ filter p)` reach the plain `filter`
function when the receiver defines no such message. A bare call `(f x)`
remains purely lexical, and message names are not bound in the enclosing
scope, so `(f x)` never resolves to a protocol message. Full resolution
rules: `docs/core.md §9`.

If no `self` binding is in scope, `(~ f a b)` is a compile-time error.

MVP core special forms:

```text
var set do if if_then if_not && || ! match for while loop repeat break continue
fn fn! macro type ctor protocol impl derive try fail panic quote quasiquote
select eval mod ns import yield scope supervisor spawn await
```

`&&`, `||`, and `!` are boolean control flow (§9); `while`, `loop`, `repeat`,
`break`, and `continue` are loop control; `supervisor` owns a concurrency scope
(§13.6). Like the rest, they are reserved in head position, so `(&& ...)`,
`(while ...)`, and `(break)` always use the special-form rule and cannot be
shadowed by a binding.

Core special forms are reserved in head position. They are not ordinary bindings that `Env` can shadow. A value named `if` may exist in data or as a qualified member, but `(if ...)` always uses the special-form rule. Clause heads such as `then`, `elif`, `else`, `when`, `catch`, and `ensure` are recognized only inside their owning special form.

`select` is special because selector bodies are quoted-like contexts: bare names become static segments, and `%` escapes to lexical values.

Normative front-end order for one read unit:

```text
read comments/discards
→ tokenize according to the reader EBNF, including slash paths and qualified-name/path tokens
→ build raw nodes
→ pipe folding
→ local reader sugars such as flags, spread markers, and interpolation
→ quasiquote/template expansion with depth tracking
→ macro expansion and special-form analysis
```

`~` is recognized only in call-like forms where it appears as the second token or as a leading send to `self`. Elsewhere it is an ordinary symbol. The reader preserves send forms as read (they round-trip); resolution happens at compile/dispatch time (`docs/core.md §9`).

---

## 4. Parameters and argument matching

Argument matching is separate from pattern matching. A function parameter vector describes call arguments, not arbitrary value shapes.

```gene
(fn draw [shape, ^color : Color = Color/red, ^width : Int = 1]
  ...)

(fn draw [shape, ^color c : Color = Color/red, ^width w : Int = 1]
  ...)
```

Rules:

```gene
name : T = default        # positional parameter
^arg : T = default        # named arg; local name is arg
^arg local : T = default  # named arg with custom local name
x...                      # gather rest positional args
```

`= default` makes the parameter optional. `?` means optional without default:

```gene
^width? : Int # omitted argument binds local width to void
```

Comma is a separator in parameter, binding, and pattern vectors. It is not a general expression separator. Commas are optional where whitespace already separates vector elements, but the formatter should choose one consistent style.

Argument matching is closed and non-backtracking: positional arity is checked, named arguments are checked, defaults are evaluated at call time, typed parameters check dynamic `Any` values at the boundary, and no pattern alternatives are involved.

---

## 5. Selectors

Selectors are the general navigation/transformation abstraction.

```gene
/user/name          # selector literal
user/name           # apply selector to lexical user
(select user name)  # explicit selector construction
```

Inside selector context, bare names are static segments. They are not resolved from lexical scope.

```gene
(select user name) # static path: user -> name
```

Use `%` to insert lexical values or stages:

```gene
(select user %field)
(select users %to_stream %(filter /adult) name)
```

Rules:

```gene
user       # static segment named user
0          # static index segment
-1         # negative index segment
%field     # evaluated lexical value used as dynamic key/index/stage
%(expr)    # evaluated expression used as dynamic key/index/stage; long form only
```

Short slash syntax permits only simple static segments, numeric indices, and `%name`:

```gene
/users/0/name
/users/%i/name
```

Access paths also permit `~message` send segments. A send segment applies the
message to the value produced by the previous path segment:

```gene
users/~size        # (users ~ size)
users/%i/~to_html  # ((users/%i) ~ to_html)
```

Complex selector stages must use long form:

```gene
(select users %to_stream %(filter /adult) name)
```

not:

```gene
/users/%(filter /adult)/name # invalid short syntax
```

`%props`, `%body`, `%meta`, `%declarations`, `%to_stream`, and `%to_pairs_stream` are not magic selector tokens. They are ordinary functions/stages resolved lexically, usually from the standard library.

```gene
x/props                 # static field/key named props
x/%props                # call/use lexical function props as a selector stage
x/%props/%to_pairs_stream
module/%declarations
users/%to_stream/name
```

A selector captures evaluated `%` stages like a closure captures lexical bindings.

Static lookup:

- on `Node`: read prop/body/index-like member according to segment type;
- on `PropMap`/`Map`: read key;
- on `List`: integer segment indexes the list. Computed list behavior such as
  `size`, `empty?`, `first`, and `last` is reached with sends, including path
  send segments like `xs/~size`, not selector property lookup;
- on namespace/module values: read exported binding/member;
- missing lookup returns `void`.

Selectors do not automatically project over `List` elements. Use `%to_stream` or an explicit stream/list mapping stage for element projection:

```gene
users/%to_stream/name # stream of names, skipping void results
users/name            # list member/key lookup; not element projection
```

If a selector stage receives a `Stream`, static lookup is mapped over each yielded item. `void` results are skipped.

If an evaluated `%` segment is callable, it is used as a stage. If it is not callable, it is treated as a dynamic key/index. This means a callable value cannot be used as a dynamic key through bare `%x`. Use explicit map access or an explicit key wrapper if that case is needed:

```gene
(map/get m x)          # unambiguous dynamic key lookup
(select m %(key x))    # optional library wrapper: force key/index use
```

Selector chains propagate `void`:

```gene
user/missing/name # => void
```

`nil` is different: if a key exists and stores `nil`, selector access returns `nil`.

Long-form selectors may opt into explicit missing-value handling:

```gene
((select ^default "unknown" user name) data) # returns default if any segment is missing
((select ^strict true user name) data)       # raises if any segment is missing
```

`^default` is evaluated when the selector is constructed and is returned only
for missing/`void` lookup. Present `nil` is still returned as `nil`. `^strict
true` takes precedence over `^default`.

---

## 6. Streams, generators, and parser streams

A stream is a stateful, pull-based, lazy cursor.

```gene
(Stream item err)
```

`item` is the yielded item type. `err` is the recoverable error type that may occur while producing items.

```gene
(Stream User Never)       # user stream that cannot fail except end-of-stream
(Stream Node ParseError)  # parser stream producing nodes and parse errors
```

`EndOfStream` is not an item. It is a standard read error from `peek`/`next`.
`has_next` returns `false` at exhaustion; it may raise the stream's producer
error `err`, but it does not raise `EndOfStream`.

```gene
(protocol (Stream item err)
  (message has_next [self] : Bool
    ^errors [err])

  (message peek [self] : item
    ^errors [EndOfStream err])

  (message next [self] : item
    ^errors [EndOfStream err])

  (message close [self] : Nil))
```

`Never` contributes no errors. Error rows flatten and deduplicate.

A function containing `yield` is a generator and returns a `Stream`.

```gene
(fn users* [users : (List User)] : (Stream User Never)
  (var i 0)
  (while (< i users/~size)
    (yield users/%i)
    (set i (+ i 1))))
```

Rules:

- each yielded value must type-check as the stream item type;
- yielding `void` skips the item (an iteration produces no value; this is
  not a way to leave the generator — see "Generator semantics" below);
- falling off the end closes the stream;
- no public `EOS` value is yielded;
- `peek` may buffer one item;
- `close` is idempotent, drops buffered state, stops future pulls, and closes
  the upstream stream if one exists.

### 6.1 Generator semantics

Generators are **one-way yield-only** in MVP: a generator function yields
items outward via `yield` and never receives values back. There is no
generator-side counterpart that suspends on input. A function that
needs a producer/consumer pair between two coroutines uses a callback,
channel, or future — not symmetric yield.

```gene
(fn prefix [s : (Stream T Never), n : Int] : (Stream T Never)
  (var taken 0)
  (take s n))                   ; → (Stream T Never), pulls from s lazily

(fn pump [s : (Stream T Never), out : (Channel T)]
  (for x in s                    ; one-way: pull out of s
    (send out x)))
```

`yield void` and an empty `return` are distinct:

- `(yield <value>)` — emits the value as the next item. If the value is
  `void`, this iteration produces no item; execution continues at the
  next `yield` (or the end of the function).
- `(return <value>)` — leaves the generator immediately. A subsequent
  `next`/`peek` reads the return value (or `void`) and the stream is
  closed. Returning early therefore consumes the rest of the generator
  without producing further items.
- `(yield)` with no value is a compile-time error — the generator item
  type requires a value.

`close` semantics:

- `Stream/close` is idempotent. The first call drops buffered state,
  discards generator frames, marks the stream closed, and propagates
  the close to its upstream source (if any). Subsequent calls are
  no-ops.
- A bounded helper like `take` does not close its upstream on natural
  exhaustion — remaining items stay available so a second consumer can
  continue pulling. Explicitly closing the downstream helper **does**
  close upstream.
- `filter`, `map`, and other stream combinators all close their upstream
  source when closed (directly or transitively) — see `Stream/close`
  in the protocol above.
- In the MVP, generator `close` stops future pulls by discarding the
  saved generator state. It does **not** resume or unwind the
  generator to run pending `ensure` blocks; generator `ensure` runs
  only on normal fall-through. This is reserved for the continuation
  model that preserves generator frames and handlers. Future versions
  may switch to running `ensure` on close — when that lands, the
  change should be transparent to streams that don't use `ensure`.

Pull-side error model (`Stream T E`):

- `has_next` may raise `E` (the producer error type), but **never**
  raises `EndOfStream`. At exhaustion `has_next` returns `false`. A
  consumer that wants to detect a producer error against an exhausted
  stream pulls `next` once more and matches on `EndOfStream` vs `E`.
- `peek` and `next` may raise either `EndOfStream` (signalling
  exhaustion — present if buffered or produced by the upstream `E`
  column) or `E`. After `peek`/`next` raises `EndOfStream`, `has_next`
  returns `false` for any subsequent read.
- A consumer that catches `E` and asks "is there more?" gets `false`
  once the producer has finished or signalled exhaustion.

These rules combine into a simple consumer idiom:

```gene
(while true
  (match (try-ok (s ~ Stream/next))
    (when (Ok v)   (yield-handler v))
    (when (Err e)  (if (== e (EndOfStream)) (break) (handle e)))))
```

Standard stream helpers are ordinary functions/stages:

```gene
to_stream        : (List T) -> (Stream T Never)
to_pairs_stream  : (Map K V) -> (Stream [K V] Never)
map              : (Stream A E, Fn [A] B) -> (Stream B E)
filter           : (Stream A E, Fn [A] Bool) -> (Stream A E)
take             : (Stream A E, Int) -> (Stream A E)
into             : (Stream A E, target) -> target
```

The reader/parser pipeline should be stream-shaped:

```text
(Stream Char E)
→ (Stream Token LexError)
→ (Stream Node ParseError)
```

Whitespace, comments, and discarded forms can produce `void`, which stream stages skip.

---

## 7. Types, basic generics, and gradual typing

### 7.1 Type declaration

```gene
(type Task
  ^props {^id Int ^done Bool ^title Str}
  ^body  [Note...]
  ^impl  [ToHtml]
  ^derive [Clone ToJson])
```

Construction stamps the value's head with the type value. Construction schemas are closed by default unless the type explicitly permits rest props.

### 7.1.1 Direct construction, `new`, and `ctor`

Gene separates **direct data construction** from **constructor invocation**.

Direct construction uses the type value as the call head:

```gene
(User ^name "Ada" ^age 37)
(Point ^x 10.0 ^y 20.0)
```

`(T ...)` is the canonical typed-data form. It maps named arguments to props,
positional arguments to body fields, normalizes `void`, checks required fields,
rejects unknown fields, validates field/body types, stamps the head with the
type, and returns the new instance. It **does not** call `ctor`, even when the
type defines one.

This is intentional. Gene values must be printable/serializable back into Gene
data without replaying arbitrary constructor code, side effects, normalization
logic, network calls, clock reads, or validation policies. The printer should
prefer direct construction for typed instances, because it represents the value
that exists, not the process that originally produced it.

A type may additionally define one constructor with `ctor`:

```gene
(type Point
  ^props {^x F64 ^y F64}

  (ctor [x : F64, y : F64]
    (self ~ Node/set-prop! `x x)
    (self ~ Node/set-prop! `y y)))
```

Constructor invocation uses `new`:

```gene
(var p (new Point 10.0 20.0))
```

`new` is the explicit operation for running constructor logic. If the type has
no `ctor`, `(new T ...)` falls back to the same schema mapping as `(T ...)`. If
the type has a `ctor`, the construction sequence is:

```text
evaluate the type expression to a Type
→ allocate a new in-progress instance with that type as head
→ bind that in-progress instance as lexical `self`
→ argument-match the arguments after the type expression against the ctor parameter vector
→ execute the ctor body
→ validate the completed instance against the type schema
→ return `self`
```

There is no `init` special form. The constructor mutates the pre-created `self`
instance using explicit mutable node/type APIs such as `Node/set-prop!`,
`Node/set-body!`, `Node/push-body!`, or future field-specific setters. The ctor
body result is ignored; construction returns the validated `self` instance unless
the ctor raises a recoverable error or panics.

A constructor uses normal function-style argument matching:

```gene
(type User
  ^props {^name Str ^age Int ^active Bool}

  (ctor [name : Str, ^age : Int = 0, ^active : Bool = true]
    (self ~ Node/set-prop! `name name)
    (self ~ Node/set-prop! `age age)
    (self ~ Node/set-prop! `active active)))

(new User "Ada" ^age 37)
(User ^name "Ada" ^age 37 ^active true) # direct data construction
```

Constructors may declare checked errors:

```gene
(type Port
  ^props {^value Int}

  (ctor [n : Int]
    ^errors [ValidationError]
    (if (&& (>= n 0) (<= n 65535))
      (self ~ Node/set-prop! `value n)
      (fail (ValidationError ^message "invalid port")))))

(new Port 8080)
(Port ^value 8080) # direct data construction; no ctor code runs
```

The distinction is semantic, not just syntactic:

```text
(T ...)      canonical typed data construction; replay-safe; no ctor side effects
(new T ...)  constructor invocation; runs ctor when present; may normalize/fail/effect
```

Therefore a `ctor` is an ergonomic and validation entry point, not the only way
to materialize a value of that type. If a library needs stronger invariants, it
should combine `ctor` with future visibility/opaque-field controls, a validation
protocol, or trusted deserialization policy. Schema validation always runs for
both direct construction and `new`, but semantic invariants encoded only in
`ctor` are not automatically enforced by direct construction.

Single inheritance affects schema, not constructor chaining. A child inherits
parent fields and must leave `self` valid for the full inherited schema, but the
parent constructor is not called automatically:

```gene
(type Animal
  ^props {^name Str})

(type Dog
  ^is Animal
  ^props {^breed Str}

  (ctor [name : Str, breed : Str]
    (self ~ Node/set-prop! `name name)
    (self ~ Node/set-prop! `breed breed)))
```

A partially constructed `self` is not `Send` and should not escape to actors,
channels, native roots, globals, or long-lived closures before construction
validates. The MVP runtime may reject obvious escapes; future implementations
may enforce this more precisely with a construction-state marker.

### 7.2 MVP type hierarchy

MVP uses a small nominal type hierarchy:

```text
Any
├── Nil
├── Void
├── Bool
├── Str
├── Number
│   ├── Integer
│   │   ├── Int
│   │   ├── SignedInt
│   │   │   ├── I8
│   │   │   ├── I16
│   │   │   ├── I32
│   │   │   └── I64
│   │   └── UnsignedInt
│   │       ├── U8
│   │       ├── U16
│   │       ├── U32
│   │       └── U64
│   └── Float
│       ├── F32
│       └── F64
├── List
├── Map
├── Gene
├── Fn
├── Fn!      # runtime syntax callable / fexpr
├── Env
├── Task
├── Channel
└── ActorRef

Never <: every type
```

`Any` is the top gradual type in MVP. Unannotated code defaults to `Any`, and `Any` can flow into typed code only through a runtime typed-boundary check.

`Never` is the bottom type because it has no values. A computation with type `Never` never returns normally, so it can appear wherever another type is expected.

`Nil` and `Void` are ordinary singleton types under `Any`:

```gene
nil  : Nil
void : Void
```

They are not bottom types. `nil` is explicit absence. `void` means missing, skipped, deleted, or no produced value. Optional values are explicit:

```gene
T?          = (| T Nil)        # symbol suffix
(? X)       = (| X Nil)        # prefix head, any type expression
(? X Y ...) = (| X Y ... Nil)  # several alternatives, all made optional together
```

`?` is the sole optionality operator: there is no `opt` keyword and no `Option`
wrapper type — absence is the ordinary `nil`. As a symbol suffix (`Int?`,
`User?`) it is read as an ordinary symbol and interpreted only in type position
(annotations, parameter/return types, prop schemas), so predicate names like
`empty?` in value position are unaffected. As a head (`(? (List Int))`) it works
on any type — including compounds a suffix cannot reach.

A typed list or map is not implicitly initialized to `nil`:

```gene
(var xs : (List Int) [])          # empty list
(var ys : (? (List Int)) nil)     # absent list
```

A future static top type such as `Value` may be added later to distinguish “some statically known Gene value” from dynamic unchecked `Any`. It is not part of MVP.

Union types are normal types:

```gene
(| Int Nil)  # an Int or nil
```

A union is a subtype of `Any`; each alternative keeps its own runtime identity.
### 7.2.1 Planned type additions

Status: **Partially implemented**. `Range` and the date/time family now have
native runtime values. The remaining planned items in this subsection are not
part of the MVP type hierarchy above, but they are expected additions as the
language grows toward practical web, database, and application code.

#### `Range`

`Range` is a small native value/object used by loops, stream conversion, and
later slicing/index traversal.

```gene
(range 0 10)      # 0, 1, ..., 9
(range 10 0 -1)   # 10, 9, ..., 1
(range 0 10 2)    # 0, 2, 4, 6, 8
(range 0 4 2 true) # 0, 2, 4
```

The default range should be half-open, `[start, stop)`, because that matches
indexing and repeat-count use cases. A fourth boolean argument marks an
inclusive range. A range has `start`, `stop`, `step`, and `inclusive?`
semantics; zero step is invalid.

#### Date and time values

The date/time family is implemented as small immutable native values:

```gene
Date
Time
DateTime
Timezone
Duration
```

`Date`, `Time`, and `DateTime` support reader literals and canonical printing
for the old Gene ISO-like surface:

```gene
2026-07-04
09:30
09:30:15.123456
2026-07-04T09:30
2026-07-04T09:30Z
2026-07-04T09:30:15.123456-04:00[America/New_York]
09:30[America/New_York]
```

DateTime bracketed IANA names require a preceding `Z` or fixed offset, matching
the old reader. Time literals may use a bracketed name without an offset.

Constructors are available for generated code and host APIs:

```gene
(date 2026 7 4)
(time 9 30 15 123456 -240 "America/New_York")
(datetime 2026 7 4 9 30 15 123456 0 "UTC")
(timezone "+08:00" "Asia/Shanghai")
(duration 1500000) # microseconds
```

Accessor messages live on the corresponding type namespaces and may be sent
unqualified through the receiver-message resolver:

```gene
(d ~ year)
(d ~ Date/year)
(t ~ Time/hour)
(dt ~ DateTime/offset)
(tz ~ Timezone/name)
(dur ~ Duration/seconds)
```

`Duration` is included with the family because date arithmetic is incomplete
without an explicit duration type. Duration is currently constructor/API based;
the old Gene parser reserved number-with-unit support but did not implement
duration literals, so unit suffix forms such as `5ms` or `1h30m` remain future
syntax.

Timezone support starts with `UTC` and fixed-offset zones. Full IANA timezone
database support is deferred until the stdlib has a dependency policy for it.
Comparison and SQLite-friendly round trips beyond canonical text are planned
next steps.

#### Enums (sum types)

Enums are a planned **core language feature** (not a stdlib type): a closed,
named set of variants under one type. One `enum` form unifies simple
enumerations (all variants carry no payload) and tagged sum types / ADTs
(variants carry payloads) — states, message sets, `Option`/`Result`, JSON/AST
nodes. `enum` is a declaration special form parallel to `type`. The MVP gives
tagged-value ergonomics, nominal boundaries, and runtime matching first;
static exhaustiveness checking is the planned follow-on once the checker can
reliably know the scrutinee's enum type.

```gene
(enum Color                 # simple enum — all unit variants
  red green blue)

(enum Shape                 # tuple variants carry positional payloads
  (circle Int)              # radius
  (rect Int Int))           # w, h

(enum Option [T]            # generic sum type (§7 basic generics)
  none
  (some T))

(enum Result [T E]
  (ok T)
  (err E))

(enum Status ^backing Str   # optional backing scalar for storage
  (active "A") (closed "C"))
```

**Members and construction.** Each variant is a qualified member `Enum/variant`
(§2.1). A unit variant *is* a value — an interned singleton (`Color/red`, so
`same?` compares by identity). A payload variant is a constructor:
`(Shape/circle 5)`, `(Option/some x)`. A value's runtime enum identity is the
enum itself (`Color`, `Option`); generic type arguments are erased at runtime
and enforced by static/type-boundary checks. Thus `(Option Int)` is a static
type expression over runtime enum `Option`, and the unit singleton `Option/none`
is shared across instantiations. The variant is a discriminant tag *within* the
enum, not a separate type. Structural `=` compares enum identity, variant
identity, and payloads.

**Enums are types.** `Enum` is a kind of `Type`, so an enum is usable everywhere
a type is — annotations (`^c : Color`), generic application (`(Option Int)`),
unions, and dispatch. An enum body may declare type-direct messages and inline
`impl`s exactly like `type` (§10), and protocol impls may target it, so enums
carry behavior and join the protocol system:

```gene
(enum Direction
  north east south west
  (message degrees [self] : Int
    (* (self ~ ordinal) 90)))   # north 0, east 90, south 180, west 270
```

This `Enum`/`Type` relationship lives at the meta-level of §7.1: `Color` is a
runtime type value, like a declared `type`, while `Color/red` is a value whose
receiver type is `Color`.

**Pattern matching.** Variants match with the ordinary engine (§8) via `when`;
payloads bind positionally (named fields for struct variants, deferred):

```gene
(match r
  (when (Result/ok v)  v)
  (when (Result/err e) (fail e)))
```

When the scrutinee's static type is the enum, `match` is intended to be
**exhaustiveness-checked** — a set of `when` clauses missing a variant, with no
`else`, is a compile error naming the gap; this is the headline benefit of a
closed variant set (static check deferred, see below). A dynamically-typed
scrutinee falls back to a runtime `MatchError`. A fully covered `match` with an
`else` may become an unreachable-branch warning later; it is not part of MVP.

**Reflection and storage** (the web/sqlite path). Every variant has a stable
0-based `ordinal` (declaration order) and a `name` (a `Sym`). The enum type
exposes the variant descriptor set and reverse lookups for (de)serialization:

```gene
(Color ~ variants)           # => [Color/red Color/green Color/blue]
(Color ~ names)              # => [red green blue]
(Color/red ~ name)           # => red
(Color/green ~ ordinal)      # => 1
(Color ~ from_name `red)     # => Color/red  (symbol arg is quoted)
(Color ~ from_name "red")    # Str accepted for codec convenience
```

For unit-only enums, `variants` returns the interned unit values. For mixed or
payload enums, `variants` returns variant descriptors; a payload descriptor such
as `Shape/circle` is a constructor, not an already-constructed enum value.
`from_name` returns the same descriptor/member, so ``(Shape ~ from_name `circle)``
returns the `Shape/circle` constructor descriptor. Unknown `from_name` and
`from_ordinal` inputs return `void`; raising parse helpers can be added later.

An optional `^backing T` gives unit enums a stable scalar independent of
declaration order — the natural DB-column representation. `^backing` is rejected
if any variant carries payload. Every variant must provide a unique backing
value of type `T`, and backing values must be hash-stable:

```gene
(enum Status ^backing Str
  (active "A")
  (closed "C"))
```

`(Status/active ~ backing)` is `"A"`, `(Status ~ from_backing "A")` is
`Status/active`, and unknown `from_backing` inputs return `void`.
Auto-provided enum reflection names — `variants`, `names`, `name`, `ordinal`,
`from_name`, `from_ordinal`, `backing`, and `from_backing` — are reserved on
enum types/variants; declaring a type-direct message with one of those names is
an error.

**Relationship to other forms.** A union `(| A B C)` (§7.2) is *open, structural,
untagged* — "any of these existing types"; an enum is *closed, nominal, tagged*
with named variants, constructors, and exhaustiveness. Optionality stays `nil` /
`T?` / `(? X)`, not `Option`; recoverable errors stay `fail`/`try`/`catch` with
`Error` (§9), not `Result`. `Option`/`Result` remain available as stdlib enums
for code that prefers explicit tags or errors-as-values, but are not the default
idiom.

**Representation.** Unit variants are interned per enum and may be NaN-box-inlined
as `(enum-id, ordinal)` with no allocation; because generic type arguments are
erased, an inline unit variant carries only enum identity and ordinal. Payload
variants are heap values holding the runtime enum identity, variant tag, and
payload, so zero-payload enums stay allocation-free on hot paths.

**MVP vs deferred.** MVP: unit and tuple variants; qualified members; enums as
types (annotations, generics, dispatch, methods, inline/target `impl`s);
recursive payload references to the enclosing enum; `when`-pattern binding;
`ordinal`/`name`/`names`/`variants`/`from_name`/`from_ordinal` reflection.
Deferred: **struct variants** (named payload fields, `(point ^x Int ^y Int)`);
**static exhaustiveness checking** (until the gradual type checker can resolve
the scrutinee's enum type — dynamic matches still `MatchError`); and versioning
rules for adding a variant to a published enum.

#### Additional planned stdlib types

The following are useful for the web/sqlite path and should start as stdlib
types or stdlib APIs unless performance evidence justifies making them core VM
value kinds:

- `Json`: represented by ordinary Gene maps, lists, strings, numbers, booleans,
  and `nil`, with parser/printer APIs.
- `Url` / `Uri`: parsed URL values for web routing, request handling, and
  clients.
- `Uuid`: stable identifier type for database-backed applications.
- `Decimal`: exact base-10 numeric value for money and database precision.
- `File` / `Directory`: capability-scoped resource handles, not ambient global
  filesystem authority.

### 7.3 Single nominal inheritance

Gene supports single nominal inheritance only:

```gene
(type Animal
  ^props {^name Str})

(type Dog
  ^is Animal
  ^props {^breed Str})
```

`^is` declares one nominal parent. Multiple inheritance is not supported in MVP:

```gene
(type X
  ^is [A B]) # invalid
```

Multiple behaviors are expressed through protocols:

```gene
(type Dog
  ^is Animal
  ^impl [Send ToJson Comparable])
```

A child type must be substitutable for its parent:

- the child inherits all parent props/body fields;
- the child may add fields;
- required parent fields remain required;
- inherited fields keep the same type in MVP;
- direct parent construction remains closed to unknown child fields;
- subtype values may contain extra child fields and still pass a parent boundary.

Example:

```gene
(fn print-name [x : Animal]
  (print x/name))

(print-name (Dog ^name "Rex" ^breed "Lab")) # valid
```

Invalid examples:

```gene
(type BadDog
  ^is Animal
  ^props {^name Any}) # invalid: inherited field type changed

(type AlsoBad
  ^is Animal
  ^props {}) # invalid if Animal/name is required
```

Field narrowing, abstract parent types, final/sealed inheritance, layout inheritance, parent-constructor chaining, inherited constructors, and schema-evolution adapters are post-MVP.

### 7.4 Numeric model

MVP numeric types:

```gene
Int     # arbitrary-precision integer at the language level
Fixnum  # implementation-sized immediate integer, optimized subset of Int
F64     # 64-bit IEEE float
F32     # 32-bit IEEE float for typed buffers/native code
Float   # alias for F64 in MVP
```

`Int` has mathematical integer semantics. The MVP VM implements this as a
checked-I64 fast path with heap-bignum promotion on overflow (`intAdd` /
`intSub` / `intMul` / `intDiv` in the runtime: when both operands fit in
int64 and the result fits in int64, arithmetic stays as a NaN-boxed fixnum;
otherwise the runtime promotes to a heap bignum). Overflow of the fixnum
range **never wraps silently** — it either promotes to an exact heap bignum
when promotion is implemented for the operation, or raises a recoverable
error. The language-level contract is mathematical integer semantics; the
MVP contract is "promote to bignum on overflow or raise." Silent wraparound
is forbidden. Typed native code may specialize `Fixnum`, `I64`, `F64`, and
`F32`; using such fixed-width types creates range-checked boundaries (a
fixed-width result out of range raises rather than wrapping).

FFI types such as `C/Int32`, `C/Long`, and `C/Size` are ABI types, not aliases for Gene `Int`. Passing a Gene `Int` to an FFI integer parameter performs an explicit range check and then marshals to the target ABI width.


Generic functions put type parameters on the function name:

```gene
(fn (first item err) [s : (Stream item err)] : item
  ^errors [EndOfStream err]
  (s ~ Stream/next))
```

Call-site inference uses local unification. Given:

```gene
(var users : (Stream User Never) ...)
(first users)
```

The compiler compares `(Stream item err)` with `(Stream User Never)` and infers `item = User`, `err = Never`.

MVP generics include generic declarations, type application, generic functions, and local unification-based call inference. MVP generics do not include variance, higher-kinded types, associated types, complex constraints, or required explicit type application syntax.

Gene remains gradually typed. Unannotated code defaults to `Any`:

```gene
(fn f [x, y]
  ...)
```

means conceptually:

```gene
(fn f [x : Any, y : Any] : Any
  ...)
```

Untyped data can flow freely inside dynamic code. It is checked when it crosses a typed boundary.

Typed boundaries include:

- assignment to a typed variable;
- passing a value to a typed function argument;
- returning from a function with an annotated return type;
- constructing a typed value;
- inserting a value into a typed container;
- adapting a dynamic stream to `(Stream T E)`.

Example:

```gene
(var req : Request raw-req)
(handle raw-req) # if handle expects Request, raw-req is checked at call boundary
```

If a value whose static type is `Any` fails a typed-boundary check, Gene raises a recoverable `TypeError` with blame information. This is the normal defensive boundary for untrusted dynamic input.

If fully typed code violates an already-checked internal representation invariant, that is a compiler/runtime bug or panic, not an ordinary recoverable boundary error.

For generic containers, Gene checks element types. For streams, checking is lazy: each item is checked as it is pulled.

### 7.5 Hashable collections and bytes

These extend the §7.2 hierarchy beyond the original MVP.

**`Set`** — `(Set 1 2 3)`. A hashable-element collection. The first
implementation is immutable and preserves first-insertion order for printing and
iteration; duplicate equal elements collapse to the first occurrence. Elements
must be hash-stable, so mutable structural values are rejected by the §12.4
mutable-key rule. Mutable/frozen set variants may be added later if they pull
their weight.

**General map `{{ … }}`** — an any-key hashed map, distinct from the Sym-keyed
`PropMap` literal `{^k v}`. The literal shape is flat and requires `:` between
each evaluated key and value:

```gene
{{k1 : v1 k2 : v2}}
```

`{{` is tokenized specially; the close is two ordinary `}` tokens, so adjacent
ordinary map closes such as `{^a {^b 1}}` remain unchanged. Keys must be
hash-stable; mutable structural keys raise `TypeError`. Iteration and
`to_pairs_stream` yield `[key value]` pairs in insertion order. Duplicate equal
keys use last-write-wins; a final `void` value deletes the key. `(Map K V)`
accepts both `PropMap` and general maps for compatibility; `PropMap` and
`HashMap` name the precise variants.

**Binary / `Bytes`** — immutable byte strings distinct from the mutable typed
`Buffer` (§16). Three literal notations:

```gene
0!01010101   # bits
0x1f3a       # hex
0#SGVsbG8=   # base64
```

Bytes are currently heap-backed; inlining 1–4 byte values into the NaN-boxed
payload remains an optimization option. `0x` is reserved for bytes rather than
hex integers. Bit literals must contain a multiple of 8 bits. Base64 literals
accept standard padded or unpadded input and print canonically as hex bytes. A
`~` separator may appear between byte groups and may be followed by whitespace,
including newlines:

```gene
0!11111111~ 11111111~ 11111111
0xaaaa~ aaaa
0#SGVs~ bG8=
```

### 7.6 Regular expressions

The universal `/pattern/` literal is unavailable — a leading `/` is a selector
literal (§5) — so regex literals use a `#`-reader form, `#"pattern"`:

```gene
#"\d{4}-\d{2}"        # a Regex value, compiled at read time in native builds
#"hello"i             # trailing flags: i (case), m (^$ multiline), s (dotall), x (verbose)
#"""^\s*(\w+)\s*$"""  # triple-quoted so " needs no escaping
```

Regex literals are **raw**: they preserve backslash escapes literally (`\d`, `\w`,
`\.`) and hand the pattern to the engine unchanged — unlike normal Gene strings,
which reject unknown escapes such as `\d`. So the reader does **not** reuse string
parsing; it scans only enough to terminate the literal: a closing `"` (with `\"`
permitted so a pattern may contain a quote), or the `#"""…"""` triple-quoted form
where nothing needs escaping.

Regex literals produce immutable compiled `Regex` values directly. `Regex` is
also a constructor function and type annotation; the explicit constructor takes
an **ordinary** string, so escapes double: `(Regex "\\d+")` equals `#"\d+"`.
Regex uses PCRE through Nim's `std/re` wrapper. `Regex` is an immutable, opaque
value under `Any` (§7.2), compiled once, printing back as `#"..."`. Because
strings are UTF-8, Unicode matching is the default.

MVP surface:

```gene
#"\d+"
#"""^\s*(\w+)\s*$"""
(Regex "\\d+")
(re ~ match s)            # => a Match, or void if no match
(re ~ find_all s)         # => a (Stream Match Never), lazy (§6)
(re ~ replace s tmpl)     # first match; tmpl backrefs \1, \k<name>
(re ~ replace_all s tmpl) # every match
(re ~ split s)            # => (List Str)
```

`Match` is a **typed node** (§7.1) with specified fields: `^text` (whole match),
`^groups` (numbered captures, `(List Str?)`), `^named` (`(HashMap Str
Str?)`, name→capture), and `^start`/`^end` (half-open byte offsets:
`start <= i < end`). Unmatched optional captures are `nil`. It destructures with
the ordinary pattern engine (§8).

Flags are canonicalized in `i`/`m`/`s`/`x` order. Invalid or duplicate flags are
read/constructor errors. `(Regex ^flags "im" "\\d+")` is equivalent to
`#"\d+"im` after ordinary string escaping.

Replacement templates recognize `\0` for the whole match, `\1` style numbered
captures, `\k<name>` named captures, and `\\` for a literal backslash. Unknown
replacement escapes are errors.

**Deferred until the basic value/API lands** — both overcommit to capture-binding
and template semantics before the core is proven:

- **Regex as a `match` pattern** — `(when #"..." …)` binding named/numbered
  captures branch-locally, with the failed-match and duplicate-group-name rules.
- **`^to` rewrite rules** — a regex carrying its replacement template so
  `(rule ~ apply s)` substitutes without a call-site template.

Implementation note: the first implementation uses Nim's PCRE-backed `std/re`
API in native builds. Wasm builds preserve the `Regex` value shape but report
regex operations as unavailable until PCRE is linked into the wasm artifact.
Named-capture extraction records the common PCRE group declaration forms
`(?<name>...)`, `(?'name'...)`, and `(?P<name>...)`.

---

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

Alternation patterns must bind the same set of names with compatible types in every branch. Negative patterns must not introduce new bindings.

`match` performs structural selection. It does not have `guard`; use normal `if` inside a matched branch.

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

The same pattern engine is used by `var`, `for`, and `catch` destructuring.

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
| `(try ... catch (p body...))` | the catch body                         |
| `(for p in xs body...)`       | the loop body, fresh per iteration     |
| `(var p v)`                  | the enclosing lexical scope            |

`match`, `catch`, and `for` bindings are **branch-local**: the runtime slot
table for an arm is a fresh child of the enclosing scope, so a name bound by
one arm is unreachable from a sibling arm and from anything after the form.
`(var pattern value)` binds like any other `var` and extends the current
scope; its names are visible to subsequent expressions as ordinary locals.

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
(if cond true-expr false-expr)
```

Short-circuit boolean operators:

```gene
(&& a b c)   # left to right; stop at the first falsy operand
(|| a b c)   # left to right; stop at the first truthy operand
(! x)        # Bool inverse of x's truthiness
```

`&&` and `||` yield the last operand evaluated — not a coerced `Bool` — so
`||` doubles as a default-value form over falsy `void`/`nil` results:
`(|| maybe-missing "default")`. With no operands `(&&)` is `true` and `(||)`
is `nil`. `!` takes exactly one operand and always yields a `Bool`.

Recoverable errors are typed nodes whose type implements the marker protocol `Error`:

```gene
(protocol Error)

(type ParseError
  ^props {^line Int ^message Str}
  ^impl [Error])

(impl Error for ParseError)
```

Every type listed in `^errors [...]` must implement `Error`. `fail` raises only `Error` values. `catch` patterns match error values.

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
catch (ParseError ^line line msg)
  recovery...
catch _
  fallback...
ensure
  cleanup...)
```

`catch` patterns match error nodes in order. `ensure` runs on success or error; its result is ignored unless it raises/panics. Unhandled errors propagate.

`panic` is for violated invariants and unrecoverable bugs. It is not listed in `^errors`.

---

## 10. Protocols, messages, and derivation

```gene
(protocol ToHtml
  (message to_html [self : Self] : Node))

(impl ToHtml for MenuItem
  (message to_html [self] : Node
    `(tr (td %self/name))))
```

Message dispatch is on the first argument's head/type. Messages are ordinary callable values, but their names are **not** bound in the enclosing lexical scope — a message is reached with a send, or as a qualified member of its protocol (`docs/core.md §1/§9`):

```gene
(item ~ to_html)          # send: to_html resolves in item's context
(item ~ ToHtml/to_html)   # qualified send: always unambiguous
(ToHtml/to_html item)     # qualified call through the protocol value
```

A type can require manual implementations:

```gene
(type MenuItem
  ^props {^name Str ^price Int}
  ^impl [ToHtml])
```

The compiler checks that an `impl ToHtml for MenuItem` exists.

An implementation may also be written inline in the type body, with the
receiver implied (`docs/core.md §8`):

```gene
(type MenuItem
  ^props {^name Str ^price Int}
  (impl ToHtml
    (message to_html [self] : Node
      `(tr (td %self/name)))))
```

A type can request generated implementations:

```gene
(type MenuItem
  ^props {^name Str ^price Int}
  ^derive [Clone ToJson HasLabel])
```

For each item in `^derive`, the compiler resolves the protocol and invokes that protocol's `derive` form.

Derive items may carry options:

```gene
(type User
  ^props {^name Str ^password Str}
  ^derive [(ToJson ^skip [password])])
```

Protocol-local derive:

```gene
(protocol HasLabel
  (message label [self : Self] : Str)

  (derive [t : Type, req]
    `(impl HasLabel for %t
       (message label [self] : Str
         (to-str self/name)))))
```

`derive` is a protocol-local compile-time special form. It receives the target `Type` value and the request node. It returns one or more declarations, usually an `impl`.

Generated declarations are placed in a compiler-owned overlay. Source modules are not mutated. Generated nodes receive provenance meta such as `@derived-by`, `@derived-for`, and `@derived-from`.

Any module may declare an implementation for any protocol and receiver type; an impl may live anywhere, not only in the type's or protocol's module. **Module implementations are global after successful module activation:** while a module runs, its impls are staged in its module scope. At successful completion the complete batch is conflict-checked and published atomically to the shared application root. A failed or conflicting module publishes none of its staged impls. Once published, they are visible everywhere, including in modules that never imported the impl's defining module. Impls are not value bindings — they cannot be renamed or selectively imported; loading the defining module is what activates them. Coherence is global: at most one impl may exist for a given `(protocol, receiver)` pair; a pair with no active impl is a missing-implementation error at the use site. Generated module implementations follow the same rule, and MVP rejects overlapping generic implementations that could both apply to the same concrete receiver type.

`eval` and Env-backed REPL units are the deliberate exception: their impls stay in the eval overlay and are never promoted to the application registry implicitly. A function or type retaining that overlay can dispatch through its impls, while unrelated scopes cannot. There is no public global-promotion operation in the MVP. Each successful application-level activation advances an impl-registry epoch; native/direct protocol-call optimization must guard that epoch (and deopt/re-resolve on mismatch) before it may cache an impl address across activation.

MVP imposes no orphan restriction — an impl need not accompany its type or protocol, in the spirit of keeping the MVP simple. A future version may add one (for example, requiring a cross-module impl to live in the type's or the protocol's defining module) so that implementations cannot be silently activated by loading an unrelated module.

MVP restrictions:

- protocol-local `derive` may generate `impl` declarations for its own protocol;
- deriving outside the type's defining module is not allowed;
- a manual impl and generated impl for the same `(protocol, type)` pair is an error;
- generated impls are type-checked normally.

Protocol inheritance (`^inherit`), type-direct messages, type/protocol
inheritance interaction, and `~` message-resolution semantics are designed as
an extension of this section in `docs/core.md`.

### 10.1 Implementation visibility and imports

The exact rule for when an impl is visible for protocol-coherence lookup:

```text
An impl batch activates atomically when its defining module finishes loading.
An active impl is visible in every module, regardless of whether
that module imports the defining module (global coherence).
Any import form that loads the defining module — bulk, selected,
or `^as` — activates its impls; impls are not name-selected and
cannot be aliased or renamed.
At most one impl per `(protocol, receiver)` pair may be active; a
second makes the conflicting module activation fail without
publishing any of that module's impls. A pair with no active impl is a missing-implementation
error at the use site.
Impls are not value bindings: they cannot be renamed, selectively
imported, or re-exported. An import that binds no values still
loads the module and so still activates its impls.
```

This fixes the answers to the import-visibility questions: a selected
import and an `^as` import both load the defining module and so activate
impls globally; impl visibility cannot be imported on its own — it rides
on module load; and impls cannot be re-exported because they are not
bindings. Coherence is therefore global, not per-import: the same
`(protocol, receiver)` pair resolves the same way in every module.
Eval overlays are lexical and are not part of this module-global relation.
Future versions may tighten this with `^private`, explicit export lists,
an orphan rule, or finer-grained impl-import controls.

---

### 10.2 Delegation

Delegation is composition-based behavior reuse: an outer value implements a protocol by forwarding one or more messages to an inner value selected by a path.

Manual delegation is just an ordinary `impl`:

```gene
(type LoggedDb
  ^props {^inner Db ^log Logger})

(impl Query for LoggedDb
  (message query [self sql]
    (self/log ~ Logger/info $"query: ${sql}")
    (self/inner ~ query sql)))
```

This is preferred over broad inheritance for wrappers, adapters, caches, logging, authorization, and resource decorators. Inheritance answers “is a”; delegation answers “has a value that does this behavior.”

Delegation should remain explicit. Gene should not use dynamic “method missing” forwarding as a core feature because it hides which protocols a type implements and makes type checking, docs, native compilation, and coherence harder.

A future derive helper may generate forwarding impls:

```gene
(type BufferedReader
  ^props {^source Reader ^buffer Buffer}
  ^derive [(Delegate ^protocol Reader ^to /source)])
```

Such a helper would expand to a normal `impl Reader BufferedReader` whose messages forward to `self/source`. This keeps delegation homoiconic, selector-based, and compatible with the existing protocol/derive system. Delegation is not an MVP special form, and the `Delegate` helper is post-MVP: it generates an `impl` for a protocol other than its own, which requires lifting the §11.4 own-protocol derive restriction first.

## 11. Fexprs, macro templates, and compile-time code

Gene separates runtime syntax behavior from compile-time rewriting.

```text
fn!    runtime fexpr / syntax callable / Env-aware DSL tool
macro  compile-time template expansion
derive protocol-local compile-time declaration generation
```

This split avoids making full Lisp-style macros the default abstraction while still preserving the pieces Gene needs for DSLs, homoiconic code, derivation, and AOT/sealed builds.

### 11.1 `fn!`: runtime fexprs

`fn!` defines a runtime syntax callable. It receives unevaluated syntax nodes and the caller `Env`, then decides what to evaluate.

```gene
(fn! unless! [cond, body...]
  (if (! (eval cond ^in caller-env))
    (eval `(do %body...) ^in caller-env)
    nil))
```

A `fn!` value implements `SyntaxCallable` (§3). Its parameter vector matches the raw syntax nodes in the call envelope. Inside a `fn!` body, the implementation provides read-only bindings:

```text
caller-env  Env         # the caller's evaluation environment
syntax-call SyntaxCall  # the full raw call envelope, including props/site
```

The ordinary parameter bindings such as `cond` and `body` are syntax values, not evaluated results. A `fn!` may call `eval` explicitly, usually with `caller-env` or a restricted child environment.

Like macros, names bound to `fn!` values should keep the `!` suffix by convention (`unless!`); this is not enforced.

`caller-env` is real authority, and it is the deliberate exception to §11.5's rule that evaluated code does not automatically see caller locals. Calling a `fn!` implicitly grants the callee a view of the caller's full evaluation environment:

- `caller-env` resolves the caller's lexical bindings, imports, module namespace, and core built-ins, in §11.5 resolution order.
- `caller-env` is a read-only view for name resolution. Code evaluated `^in caller-env` cannot create, rebind, or `set` bindings in the caller's scope; declarations made by an evaluated unit live in that unit's own overlay. Mutable values reachable through caller bindings — `Cell`, buffers, actors — can still be mutated. The view is read-only, not deep-frozen.
- Because calling an unknown value may hand it your environment, security-sensitive code should treat syntax calls deliberately: type callees to exclude `Fn!`, pass a restricted child or purpose-built `Env` when evaluating untrusted syntax, and rely on evaluation policies (§11.5), which travel with the environment `eval` actually receives.

`fn!` values are runtime values. They may be bound, imported, passed around, stored in maps, and selected like other values. When a call's evaluated callee implements `SyntaxCallable`, the evaluator does not evaluate ordinary arguments; it calls `apply_syntax` with a `SyntaxCall` and `caller-env`. The compilation cost model for this dispatch is specified in §3.

Use `fn!` for:

- custom control flow;
- lazy arguments;
- runtime DSLs;
- test/configuration languages;
- explicit `Env`-bounded evaluation;
- syntax utilities that do not need to create module declarations before type checking.

Because `fn!` runs at runtime, its generated/evaluated code may be checked later than normal code. JIT/eval caching may recover performance, but it does not give the same early declaration graph, tooling, or AOT visibility as compile-time expansion.

### 11.2 `macro`: compile-time templates

`macro` defines a compile-time template expander. A macro receives syntax nodes and returns syntax nodes before name resolution, type checking, native compilation, and ordinary runtime evaluation.

```gene
(macro when! [cond, body...]
  `(if %cond
     (then %body...)
     (else nil)))
```

The `!` suffix marks visible rewriting by convention. It is not enforced: `(macro twice [x] ...)` is legal, but stdlib and examples should keep `!` for visible expansion.

MVP macros are **template macros**, not arbitrary compile-time functions. A macro body contains exactly one syntax-producing expression, normally a quasiquote/template. General compile-time function macros with arbitrary compile-time evaluation are future work.

Macro call arguments are syntax nodes. Macro parameters may destructure those syntax nodes with patterns. Macro parameter annotations, defaults, named parameters, and rest parameters operate on syntax values, not evaluated runtime values. `%` at a macro call site is not a special macro-argument convention; `%` remains the normal unquote/escape operator inside template-like contexts.

A name means the same thing in head position and value position. Macro names therefore share the single namespace with runtime bindings:

- defining or importing a macro whose name matches a visible binding is an error;
- binding a name, including a function parameter, that matches a visible macro is an error;
- using a macro name in value position is an error: “call it in head position.”

Macros are compile-time rewriters, not runtime values. This is stricter than special forms: a value named `if` may exist in data or qualified positions, but a macro name reserves its name within its visibility region.

Macros are module exports selected through top-level `from "path"` import lists and honor selection aliases:

```gene
(import [when! : unless-not!] from "./control")
```

Because expansion happens while the importer compiles, a top-level `from "path"` import pre-loads its module before the importing module's own top level runs. Imported macros are usable but are not re-exported by the importing module. Namespace-path imports such as `(import std/stream [...])` do not carry macros in MVP. Imports inside nested scopes resolve at runtime only, so macros must be imported at top level.

Use `macro` for:

- small compile-time surface rewrites;
- syntax templates that should type-check as ordinary expanded code;
- AOT/sealed-build-visible code generation;
- tooling-visible transformations.

Prefer `fn!` when the transformation is really a runtime DSL or depends on runtime `Env` authority.

### 11.3 Hygiene

Macros are hygienic by default. The target semantic model is expansion marks: symbols introduced by a macro carry fresh expansion identity, so introduced binders do not accidentally capture call-site names and call-site names do not accidentally capture introduced helper names.

MVP implementation may approximate this with generated fresh names for recognized template-introduced binders such as `var`, `fn`, `type`, `protocol`, `ns`, and `macro`. Full mark-set hygiene, explicit capture APIs, macro-generated imports, and hygiene for every binding context are future work.

Intentional capture must be explicit, either by unquoting a caller-provided symbol or by a future low-level hygiene escape. A `gensym`/fresh-symbol API may be exposed for macros that need explicit generated names.

### 11.4 Protocol-local `derive`

Protocol-local `derive` remains a controlled compile-time declaration generator. It receives a target `Type` value and a request node, then returns declarations, usually an `impl` for that same protocol:

```gene
(protocol HasLabel
  (message label [self : Self] : Str)

  (derive [t : Type, req]
    `(impl HasLabel for %t
       (message label [self] : Str
         (to-str self/name)))))
```

`derive` is not a general fexpr. It runs in the compiler's derivation phase and is allowed to add declarations to a compiler-owned overlay. Source modules are not mutated.

MVP restriction: protocol-local `derive` may generate `impl` declarations for its own protocol. Broader declaration generation is future work.

### 11.5 `Env` and dynamic evaluation

`Env` is the first-class name-resolution environment passed to `eval`. A binding is one name/value entry inside an `Env`. `GeneContext` remains an internal VM/FFI execution state containing thread, stack, allocator, GC, and error-state information.

An `Env` is an opaque, garbage-collected value. It may be stored, passed, returned, captured by closures, and retained by compiled/evaluated code.

```gene
(var base
  (env
    ^bindings {^x 10}
    ^imports [std/math]))

(var child
  (base ~ Env/extend {^y 20}))
```

Environments are immutable by default. `Env/extend` creates a child environment whose parent is the original environment; it does not mutate the parent.

Conceptually, an environment contains:

```text
local bindings
parent Env
optional module namespace
explicit imports
explicit capability values
evaluation policy
```

Name resolution inside evaluated code proceeds in this order:

1. lexical bindings and declarations created by the evaluated unit;
2. bindings in the supplied `Env`, following its parent chain;
3. explicitly imported modules;
4. the optional module namespace carried by the `Env`;
5. core built-ins.

Evaluated code does not automatically see arbitrary caller locals. Values must be inserted into the environment or embedded while constructing a template.

```gene
(var secret "hidden")
(var e (env ^bindings {^x 1}))

(eval `secret ^in e) # CompileError: unresolved name

(var e2 (env ^bindings {^secret secret}))
(eval `secret ^in e2) # => "hidden"
```

Shared mutation is explicit. Ordinary environment bindings are read-only, but an environment may contain mutable values such as `Cell`, buffers, actors, or domain-specific state objects.

```gene
(var counter (cell 0))
(var e (env ^bindings {^counter counter}))

(eval
  `(counter ~ Cell/set
     (+ (counter ~ Cell/get) 1))
  ^in e)
```

The core evaluation form is:

```gene
(eval node ^in env)
```

Normal programs must supply `^in`. A REPL may use its current session environment implicitly. `eval` accepts a node, not source text. Parsing remains a separate operation:

```gene
(var node (read-one "(+ 1 2)"))
(eval node ^in e)
```

A convenience `eval-string` function may compose parsing and evaluation, but it is not the primitive operation.

`eval` uses the normal compilation pipeline rather than a second interpreter:

```text
validate node
→ collect declarations
→ expand macro templates
→ run protocol-local derivation
→ resolve names and visible impls
→ type-check typed regions
→ compile bytecode or eligible native code
→ execute
```

The general result type of `eval` is `Any`. Typed callers use the ordinary gradual boundary:

```gene
(var result : Int
  (eval generated-node ^in e))
```

A non-`Int` result causes a recoverable boundary `TypeError` with blame information.

Declarations produced inside `eval` are installed in an isolated, immutable evaluation overlay. They are visible to the evaluated unit but do not mutate the source module or replace existing module bindings.

```gene
(var f
  (eval
    `(do
       (fn add1 [x : Int] : Int (+ x 1))
       add1)
    ^in e))
```

The returned function retains the overlay and any captured environment it needs. The overlay remains alive while reachable functions, types, protocol impls, callbacks, or compiled artifacts refer to it.

`eval` and live code activation are separate operations:

```text
eval      compile and execute code in an isolated overlay
activate  atomically replace live module bindings; designed separately
```

An `Env`, its parent chain, and associated overlays participate in normal tracing garbage collection. They remain alive while referenced by locals, closures, compiled artifacts, other environments, or native roots. Unreachable cycles such as `Env → closure → Env` are collectable. Native code retaining an `Env` or evaluated callable must use the ordinary Gene rooting API.

Compilation failures from evaluated code are recoverable `CompileError` values. Errors raised by the evaluated program propagate normally and are dynamically errorful unless a more specific wrapper constrains them. Boundary `TypeError` values are recoverable errors. Panic, internal VM invariant failures, and native process corruption remain fatal.

An `Env` is also an authority boundary. Evaluated code receives only bindings, imports, and capability values explicitly present in the environment. It receives no ambient filesystem, network, subprocess, FFI-loading, or native-compilation authority.

An evaluation policy may impose execution limits and privileged-feature controls:

```gene
(var policy
  (EvalPolicy
    ^max-steps 1000000
    ^max-memory-mb 128
    ^timeout-ms 5000
    ^allow-ffi false
    ^allow-native-compile false))

(var e
  (env
    ^bindings {^input input}
    ^capabilities {^fs sandbox-fs}
    ^policy policy))
```

Native code cannot be fully sandboxed in-process. Untrusted generated code should therefore run without FFI/native-compilation authority, or in an isolated process.

Compiled eval units may be cached using the semantic node hash, compiler version, imported module/macro versions, visible implementation set, environment-relevant compiler options, and policy. Source-location meta need not invalidate the cache unless consumed by a macro or compiler phase.

---

## 12. Mutability, immutable values, and cells

Gene distinguishes container mutability from binding mutation and from cross-task safety.

Strings are immutable. Plain lists, maps, general nodes, and typed instances may be mutable values:

```gene
[1 2 3]
{^name "Alice"}
(User ^name "Alice")
```

The `#` reader prefix constructs a **shallow immutable** container:

```gene
#[1 2 3]
#{^name "Alice" ^age 30}
#(user ^name "Alice")
```

Shallow immutability means the container's head, props, body, keys, and positions cannot be changed. Values stored inside it are not recursively frozen:

```gene
#[(cell 1)] # immutable list containing a mutable Cell
```

Immutable containers support persistent functional updates with structural sharing where practical:

```gene
(var xs  #[1 2 3])
(var xs2 (xs ~ List/assoc 1 20))

(var user2 (assoc-in user /address/city "Raleigh"))
(var user3 (update-in user /score (fn [x] (+ x 1))))
```

`assoc-in` and `update-in` never mutate their input. They return a new root and preserve the root's mutable/immutable class unless an API explicitly requests another representation. Missing intermediate paths are errors unless the chosen operation explicitly permits construction. Writing `void` into a prop/map removes it; writing `void` into a list/body position stores `nil`.

Mutable containers use explicit mutating operations, conventionally named with `!`:

```gene
(xs ~ List/set! 1 20)
(m ~ Map/put! key value)
(n ~ Node/set-prop! name value)
```

Selectors remain read-only paths; Gene does not overload selector access with hidden mutation.

### 12.1 Binding mutation

```gene
(var x 1)
(set x 2)
```

`set` changes a lexical binding. It does not mutate the value previously stored in that binding.

### 12.2 `Cell`

`Cell` is a first-class mutable reference and may contain any Gene value, including immediate values:

```gene
(var count   (cell 0))
(var enabled (cell true))
(var current (cell nil))

(count ~ Cell/get)
(count ~ Cell/set 10)
(count ~ Cell/swap 20)                 # returns the old value
(count ~ Cell/update (fn [x] (+ x 1)))
```

Typed cells use `(Cell T)`. A native compiler may keep primitive values unboxed inside specialized typed cells, but the semantic model is a mutable reference containing a Gene value.

`Cell` is intended for local mutable state, closure state, and actor-private state. It is not thread-safe and does not implement `Send`.

### 12.3 `AtomicCell`

`AtomicCell` is the explicit shared-memory escape hatch:

```gene
(var state (atomic-cell 0))

(state ~ AtomicCell/load)
(state ~ AtomicCell/store 1)
(state ~ AtomicCell/swap 2)
(state ~ AtomicCell/compare-exchange 2 3)
```

Operations are linearizable. The runtime may use machine atomics for supported immediate types and a lock-backed representation for general Gene values. `AtomicCell T` may implement `Send` when `T` is sendable and the implementation provides the required GC barriers.

Actors and channels are preferred over `AtomicCell` for coordinated application state.

### 12.4 Equality, hashing, and freezing

Mutable containers may use structural equality, but they are not valid structural hash keys because their hash could change. `Cell` and `AtomicCell` use identity equality and are not structurally hashable.

An immutable value is hashable only when every value participating in its structural hash is hash-stable. Thus `#[1 2 3]` is hashable, while `#[(cell 1)]` is not.

Library operations may provide explicit conversion:

```gene
(freeze-shallow value)
(freeze value)       # recursive validation/freezing
(thaw value)         # mutable copy
```

Deep freezing fails when it encounters a value that cannot be safely frozen, such as a raw native handle without a defined immutable representation.

---

## 13. Concurrency: tasks, channels, and actors

Gene uses actors as the preferred abstraction for long-lived stateful concurrent components. Actors are built on a smaller runtime foundation of structured tasks, cancellation, and bounded typed channels. Actors are not the only concurrency mechanism: stream pipelines, parallel computation, I/O, and native/GPU work may use tasks, channels, buffers, and specialized runtimes directly.

### 13.1 Runtime scheduler and `Task`

A task is a garbage-collected asynchronous computation:

```gene
(Task result err)
```

Gene uses an M:N scheduler: many Gene tasks run cooperatively across a runtime worker pool. Waiting on a task, channel, timer, or async I/O suspends the current Gene task rather than blocking an operating-system worker thread.

Structured concurrency uses three core forms:

```gene
(scope
  (var a (spawn (compute-a)))
  (var b (spawn (compute-b)))
  (+ (await a) (await b)))
```

Rules:

- `scope` owns tasks spawned directly inside it;
- `spawn expr` evaluates `expr` in a child task and returns `(Task T E)`;
- `await task` suspends the current task and returns its value or propagates its recoverable error;
- leaving a scope normally waits for its live child tasks;
- leaving because of an error or cancellation cancels remaining children, waits for cleanup, and then propagates;
- cancellation is cooperative and is observed at suspension points and compiler/runtime safepoints;
- `ensure` cleanup runs during cancellation;
- detached lifetime is explicit and is not the default MVP behavior.

The program entry point runs as a root task, so `await` is meaningful without an `async fn` distinction. A function containing `await` is lowered to a resumable task frame as needed. Native compilation may initially route suspension through runtime helpers and later perform dedicated coroutine lowering.

A task may be cancelled explicitly:

```gene
(t ~ Task/cancel)
```

Cancellation is represented separately from ordinary domain errors, but may be caught only by APIs that deliberately expose cancellation handling. Code should normally allow it to propagate. Concretely:

- cancellation is a control signal, not an `Error`; `try/catch` — including a
  wildcard `catch _` — does not catch it, so it propagates through catch clauses;
- `ensure` blocks always run during cancellation cleanup;
- `await` on a cancelled task propagates the cancellation;
- an actor observes cancellation after the current message completes or at its
  next suspension/safepoint (§13.4), never mid-message.

### 13.2 Typed bounded channels

A channel transports values between tasks:

```gene
(Channel T)
```

Channels are bounded by default to provide backpressure:

```gene
(var ch (channel ^capacity 64))

(ch ~ Channel/send value)       # suspends while full
(var value (ch ~ Channel/recv)) # suspends while empty
(ch ~ Channel/close)
```

Conceptual operations:

```gene
send      : [(Channel T), T] -> Nil ^errors [ChannelClosed]
recv      : [(Channel T)] -> T ^errors [ChannelClosed]
try-send  : [(Channel T), T] -> Bool
try-recv  : [(Channel T)] -> (| T Void)
close     : [(Channel T)] -> Nil
```

A dynamic `Any` value is checked against `T` and the `Send` requirement before it enters the channel. Failed dynamic-to-typed checks raise recoverable boundary `TypeError` with blame.

Closing a channel prevents future sends. Buffered values remain receivable before `ChannelClosed` is reported. Multiple producers and consumers are allowed; ordering is FIFO for successful sends as observed by the channel.

### 13.3 The `Send` protocol

Values crossing task/actor concurrency boundaries must be safe to transfer:

```gene
(protocol Send)
```

`Send` is a marker protocol checked statically where possible and dynamically at gradual boundaries.

Built-in sendability rules:

- numbers, booleans, symbols, `nil`, `void`, immutable strings, immutable code artifacts, and actor references are sendable; closures/functions are sendable only when all captured values are sendable;
- `#[...]`, `#{...}`, and `#(...)` are sendable only when every contained value participating in the structure is sendable;
- mutable lists, maps, and nodes are not sendable by default;
- `Cell` is not sendable;
- `AtomicCell T` may be sendable when its implementation is thread-safe and `T` is sendable;
- `Env`, raw FFI pointers, thread-affine handles, and capability values are not sendable unless their concrete type explicitly implements `Send`;
- generic immutable containers derive `Send` conditionally from their element/key/value types.

Shallow immutability alone does not imply sendability:

```gene
#[(cell 1)] # shallow immutable, but not Send
```

A future ownership/move system may permit transferring uniquely owned mutable values. MVP avoids that complexity and requires immutable/sendable messages or explicitly thread-safe handles.

### 13.4 Actors

An actor owns a mailbox, a handler, and private state. Other code interacts with it only through a typed reference:

```gene
(ActorRef Message)
```

Example message types:

```gene
(type Increment
  ^props {^amount Int})

(type Get
  ^props {^reply (ReplyTo Int)})

(type Stop)

# ActorRef may use a union message type directly:
# (ActorRef (| Increment Get Stop))
```

An actor is created with an initialization function and a handler:

```gene
(var counter
  (actor/spawn
    ^mailbox 256
    ^init (fn [] 0)
    ^handle counter-handler))
```

The initialization function runs inside the actor and creates its private state, avoiding mutable aliases held by the spawning task.

A handler processes one message and returns an actor step:

```gene
(fn counter-handler
  [ctx : (ActorContext (| Increment Get Stop)), state : Int, msg : (| Increment Get Stop)]
  : (ActorStep Int)

  (match msg
    (when (Increment ^amount n)
      (actor/continue (+ state n)))

    (when (Get ^reply reply)
      (reply ~ ReplyTo/send state)
      (actor/continue state))

    (when Stop
      (actor/stop))))
```

Core guarantees:

- exactly one message is handled at a time for each actor;
- the next message is not started until the current handler completes;
- awaiting inside a handler suspends that actor without making it reentrant;
- messages from one sender to one actor are processed in send order;
- ordering between different senders is unspecified;
- actor-local state is not directly accessible through `ActorRef`;
- actors may run on different worker threads over their lifetime;
- `ActorRef M` is sendable and enforces the mailbox message type `M`.

A handler commonly returns immutable replacement state. It may also use actor-private mutable objects created by `^init`, because no external mutable aliases exist by construction.

### 13.5 Sending, backpressure, and request/reply

Actor mailboxes are bounded by default.

```gene
(counter ~ actor/send (Increment ^amount 5))
(counter ~ actor/try-send (Increment ^amount 1))
```

Conceptual behavior:

- `actor/send` suspends until mailbox capacity is available and raises `ActorClosed` if the actor has stopped;
- `actor/try-send` returns immediately with `Bool`;
- a value must satisfy both the actor's message type and `Send` before entering the mailbox.

Request/reply uses an explicit one-shot reply capability:

```gene
(var pending
  (counter ~ actor/ask
    (fn [reply]
      (Get ^reply reply))))

(var value (await pending))
```

`actor/ask` returns `(Task R ActorError)`. `ReplyTo R` requires `Send R`; it is sendable, single-use, and may carry timeout/cancellation state. Ask is convenience over normal messages; it does not make actors synchronously callable.

Single-use is enforced: a second `ReplyTo/send` on the same reply raises the
recoverable error `ReplyAlreadySent` (a subtype of `ActorError`). This is a
programming error in the replying handler, not a delivery condition.

### 13.6 Lifetime, scopes, and supervision

Actors are owned by a task scope or supervisor, not merely by the reachability of an `ActorRef`. Actor references are garbage-collected handles; dropping the last reference does not substitute for orderly shutdown.

```gene
(scope
  (var worker
    (actor/spawn
      ^init make-state
      ^handle worker-handler))
  ...)
```

When the owning scope exits, child actors are asked to stop and remaining work is cancelled according to the scope policy.

Long-lived actor trees use supervisors:

```gene
(supervisor
  ^strategy restart
  ^events failures
  ^dead-letter dead
  (actor/spawn
    ^init make-state
    ^handle worker-handler))
```

MVP supervision strategies:

- `restart`: create fresh state with `^init` and resume with the existing mailbox policy;
- `stop`: terminate the actor and close its mailbox;
- `escalate`: report failure to the parent supervisor.

`restart` supervisors accept a restart budget: `^max-restarts N` stops the
actor instead of restarting once N restarts have been consumed, and
`^within-ms W` makes that budget a sliding window — the count resets when W
milliseconds pass since the window opened. Omitted or non-positive values mean
an unlimited budget; `^max-restarts` alone bounds restarts over the actor's
lifetime. Stopping on an exhausted budget behaves exactly like the `stop`
strategy for the failing message.

A recoverable error escaping an actor handler stops that actor and produces a failure event for its supervisor. A panic also terminates the actor/task and is escalated. Native memory corruption or an unsafe foreign crash remains process-fatal.

MVP supervisors may be given `^events failure-channel`. The runtime emits
`ActorFailure` values to that channel on actor handler failure without blocking
the failing actor path. An event includes the actor reference, failed message,
error value, display message, panic flag, and active supervisor strategy. A
supervisor may also be given `^dead-letter channel`; when the primary event
channel is closed, full, or rejects the event, the runtime attempts to write the
same `ActorFailure` to the dead-letter channel. A full sink without an available
fallback queues the failure for retry when channel space is freed. If both
channels are unavailable, the MVP drops the event rather than masking or
blocking failure handling; stronger durable delivery and explicit backpressure
policies are future runtime work.

Restart policy must define whether queued messages are retained, discarded, or moved to a dead-letter channel. The MVP default should discard the message that caused failure and retain later queued messages only for explicitly restartable actors.

### 13.7 Actors, streams, native code, and eval

Actor mailboxes may be implemented using channels, but the raw mailbox stream is not normally exposed to actor code. Actors may publish events through ordinary channels or streams.

Handlers may be bytecode functions, native-compiled typed Gene functions, registered native callables, or functions produced by `eval`. Invocation uses the ordinary `Callable` model. Native handlers can enter the VM through the existing trampoline, and dynamic handlers can call native typed functions through generated adapters.

The scheduler and GC must root task frames, channel buffers, actor mailboxes, actor state, handlers, reply capabilities, and pending errors. Foreign threads may interact with actors only through the runtime's thread-attachment and rooted-send APIs once those APIs are implemented.

### 13.8 Live actor evolution

Actors provide a natural future safe point for self-evolving code:

```text
finish current message
→ pause mailbox
→ validate new handler
→ migrate or replace private state
→ install new handler version
→ resume mailbox
```

The experimental API exposes:

```gene
(actor/upgrade ref new-handler
  ^migrate migrate-state)
```

The MVP may expose an explicit experimental `(actor/snapshot ref)` operation
for migration tooling. It is only valid at an idle actor safe point and returns
the last committed private state plus mailbox/lifecycle metadata; it must not
replace the normal message protocol for application-level state access.

An upgrade never replaces a handler while it is executing. Failure during validation or migration leaves the old handler/state active. Full live migration policy is post-MVP but should constrain actor and module version identity from the beginning.

### 13.9 Concurrency scope

MVP concurrency includes:

- structured `scope`, `spawn`, `await`, and cancellation;
- `(Task T E)`;
- bounded typed `(Channel T)`;
- `Send` boundary checks;
- sequential typed actors with bounded mailboxes;
- `send`, `try-send`, and request/reply;
- actor scope ownership and basic supervision.

Deferred features include distributed actors, transparent remote references, work stealing across processes, selectable channel operations, ownership-transfer typing, transactional memory, reentrant actors, and stronger live-migration policies.

---

## 14. Runtime capability values, no MVP effect checker

MVP has no static `^effects` checker.

However, Gene should still use ordinary runtime capability values for external authority.

Example filesystem capabilities:

```gene
Fs/ReadDir
Fs/WriteDir
Fs/ReadWriteDir
```

APIs require capability values explicitly:

```gene
(fs/read_text config "app.gene")
(fs/write_text logs "run.log" text)
```

There is no ambient filesystem authority in the intended runtime API.

Entry points can receive granted capability values:

```gene
(fn main [^config : Fs/ReadDir, ^logs : Fs/WriteDir] : Nil
  ...)
```

Static `^effects [fs io net]`, capability-row inference, and hidden capability threading are deferred until the core language stabilizes.

---

## 15. Applications, packages, modules, and namespaces

Gene has an explicit runtime/code-loading hierarchy:

```text
Application
  └── Package
        └── Module
              └── Namespace
                    ├── bindings
                    ├── types
                    ├── protocols
                    ├── impls
                    └── nested namespaces
```

For MVP:

- an **Application** is one running Gene program and owns the runtime state;
- a **Package** is a load unit placeholder for future dependency/version management;
- a **Module** is a unit of code loaded from a file, source string, REPL/eval unit, or generated overlay;
- a **Namespace** is a binding scope inside a module.

Package dependency resolution, package versions, lockfiles, publishing, and registries are deferred. Application creation, module identity, namespace binding, import path normalization, top-level execution order, and `main` invocation are MVP semantics.

### 15.1 Program startup

Starting a Gene program creates an `Application`.

Startup sequence for `gene run`:

```text
create Application
→ locate/load entry package
→ locate/load entry module
→ create the entry module's root namespace
→ execute the entry module top to bottom
→ if the entry module has a `main` binding, call it with command-line arguments
```

Example entry point:

```gene
(fn main [args : (List Str)] : Int
  ...)
```

A flexible dynamic entry point is also valid:

```gene
(fn main [args]
  ...)
```

`main` return convention for MVP:

```text
Nil  -> process exit code 0
Int  -> process exit code Int
else -> boundary TypeError for `gene run`
```

Top-level forms still execute in order before `main` is called. A module may intentionally perform all work at top level and omit `main`, but applications intended for `gene run` should normally provide `main`.

### 15.2 Application

`Application` is a runtime object, not a global ambient value automatically visible to all code.

Conceptually, an application owns:

```text
loaded package records
loaded module cache
application root path
module search paths
root capabilities granted by the host/CLI
command-line arguments
environment variables, if granted
scheduler and actor system
eval/cache state
native module registry
```

Ordinary Gene code receives application-level authority only through explicit capability values, explicit function arguments, or an explicitly constructed `Env`.

### 15.3 Package

A package groups modules and may later carry version, dependency, build, native-library, and publishing metadata.

MVP package behavior is intentionally small:

```text
entry package = package containing the entry module
package root  = directory/root used for absolute module path resolution
package cache = map of normalized module paths to loaded modules
```

A package exists so module identity and absolute paths have a stable root even before full dependency management exists.

Deferred package features:

- package version constraints;
- dependency resolver;
- lockfiles;
- remote registry;
- package publishing;
- multi-package workspaces;
- build profiles.

### 15.4 Module

A module is a code unit:

```text
source file
source string passed to `gene eval`
REPL cell/session unit
generated/eval overlay unit
```

A module has:

```text
source identity
normalized module path, when file-backed
root namespace
declaration stream
top-level forms
imports
execution state
metadata/provenance
```

A module can be written explicitly:

```gene
(mod web-demo
  @doc "demo module"
  ...)
```

A file may also have an implicit module wrapper derived from its normalized module path.

`mod` is a top-level declaration/special form:

```gene
(mod name
  body...)
```

Rules:

- `mod` names the module and provides the module body;
- if a file has no explicit `mod`, the loader creates an implicit module from the normalized module path;
- the module body executes in the module's root namespace;
- nested `mod` forms are invalid in MVP;
- duplicate explicit `mod` declarations in one file are invalid.

Each module body receives a compiler-provided lexical binding:

```gene
this-mod : Module
```

`this-mod` is an ordinary read-only binding created by the module loader. It is not selector magic and is not imported from another module. It may be used with ordinary selectors and reflection helpers:

```gene
this-mod/%declarations
(this-mod ~ Module/path)
```

Top-level execution rules:

- top-level forms execute from top to bottom;
- declarations create bindings in the current namespace;
- ordinary expressions execute for side effects and their result is normally discarded by `gene run`;
- imports are resolved before dependent forms need their bindings;
- a module is loaded/executed at most once per application/module graph unless explicitly reloaded or evaluated as a separate overlay.

Module loading must detect import cycles. MVP rejects import cycles. Future versions may admit declaration-only cycles after the compiler has a precise two-phase declaration/execution model.

### 15.5 Namespace

Every module has one root namespace. A namespace contains bindings for values, types, protocols, implementations, macros, and nested namespaces.

MVP visibility is simple: all bindings declared in a namespace are exported/importable unless a future visibility marker says otherwise. Private exports, package-public visibility, and selective export lists are deferred.

Nested namespaces are declared with `ns`:

```gene
(ns html
  (type Node
    ...)

  (fn div [children...]
    ...))
```

Nested access uses qualified names:

```gene
html/Node
html/div
```

`ns` is a declaration/special form:

```gene
(ns name
  body...)
```

Rules:

- creates or opens a child namespace under the current namespace;
- declarations inside bind into that namespace;
- nested namespaces are allowed;
- duplicate binding names in the same namespace are errors unless an explicit replacement/reload operation is used;
- top-level executable forms inside `ns` execute when the module executes;
- namespace values can be imported, passed, reflected on, and inspected through module/namespace APIs.

Nested namespaces are ordinary namespace bindings. If a module exports a nested namespace, another module may import that namespace or selected bindings under it:

```gene
(import html from "./web")              # import exported nested namespace `html`
(import [html/div : div] from "./web")  # import nested binding with alias
```

Qualified names in static contexts such as `html/Node`, `Stream/next`, and `C/Int32` are resolved by the compiler/name resolver, not by runtime selector evaluation.

### 15.6 Imports, exports, and path normalization

`import` supports two source forms:

1. importing from a built-in or already-loaded namespace path;
2. importing from a normalized module path string using `from "path"`.

Built-in / namespace imports:

```gene
(import std/stream [map, filter, into])
(import std/stream [map : stream-map, filter])
(import std/stream ^as stream)
```

Module-path imports:

```gene
(import from "./math" ^as math)          # bind loaded module value as math
(import add from "./math")              # import one exported binding
(import [add, sub] from "./math")       # import selected exported bindings
(import [add : plus, sub : minus] from "./math")
(import Config from "/app/config")
```

Rules:

- `std/stream` in source position is a static namespace path, not a string module path and not runtime selector evaluation;
- `from "path"` is the only MVP form that names a file/string module path;
- `(import from "path" ^as alias)` loads the module at `path` and binds its module value to `alias`;
- selected imports bind exported names from the source namespace/module root into the current namespace;
- `name : alias` binds the imported exported name to a different local name;
- commas inside the import list are optional separators;
- `^as alias` with a namespace source binds that namespace value; `^as alias` with `from "path"` binds the loaded module value;
- wildcard imports are deferred.

MVP export model:

```text
all named namespace bindings are exported/importable by default
```

This includes values, types, protocols, macros, and nested namespaces. Protocol implementation declarations are not ordinary named bindings and are not selected or aliased through `[name]` import lists. Implementation visibility is global and follows §10.1: any import form that loads the defining module — bulk, selected, or `^as` — activates its impls everywhere, and visibility is tracked by the compiler rather than by local value bindings. Future versions may add `^private`, explicit export lists, package-private visibility, re-export controls, and finer-grained implementation-import controls.

Path interpretation for `from "path"`:

```text
"x"     search-path/package-relative module path
"./x"   relative to current module directory
"../x"  parent-relative
"/x"    absolute from root
```

Normalization rules:

- collapse repeated separators;
- remove `.` segments;
- resolve `..` segments;
- reject paths that escape above the package/application root;
- canonicalize the module extension policy;
- produce a stable normalized module identity used for caching.

For MVP, extension handling can be simple:

```text
"x" may resolve to "x.gene" when no extension is present.
```

The loader must use normalized identities so `"./a/../b"` and `"b"` do not create duplicate modules when they refer to the same module under the same root.

Import cycles are rejected in MVP. Future declaration-only cycles require a precise two-phase module initialization design and are not part of the implementation-ready slice.

### 15.7 Module and namespace introspection

A module exposes declarations as a stream:

```gene
this-mod/%declarations
```

`declarations` is an ordinary imported/global function stage:

```gene
declarations : Module -> (Stream Node Never)
```

Users can filter/map declarations with normal stream functions:

```gene
(this-mod/%declarations
  ~ filter routed?
  ; ~ map route-entry
  ; ~ into {})
```

Declaration records are nodes shaped
`(Declaration ^name Str ^kind Str ^value Any)` — `^value` is the bound value
itself. Meta attached to the source declaration form (`@route ...`, `@doc ...`
on a named `fn`) becomes node meta on the record, so `decl/%meta/route` reads
it and declarations without that meta answer `void`. This is the hook for
meta-driven discovery such as route tables built from `@route` annotations.

Namespaces should expose reflection helpers such as:

```gene
Namespace/bindings
Namespace/lookup
Module/root_namespace
Module/name
Module/path
Module/meta
Module/declarations
```

`this-mod` is the module's loader-created binding for the current module value. Symbol resolution inside a module is otherwise explicit. A helper such as `resolve` should be defined as either runtime module/namespace binding lookup or compile-time module lookup; it is not implicit magic.

### 15.8 Eval integration

`gene eval` and `(eval node ^in env)` create module-like evaluation units.

An eval unit has:

```text
source identity or synthetic identity
root namespace
isolated declaration overlay
supplied Env
optional parent module/namespace
```

Evaluated declarations do not mutate the source module. They live in an overlay retained by returned functions, types, protocol impls, callbacks, or compiled artifacts. Impl declarations register only in that overlay: they are visible to code retaining it and do not alter the application-global impl registry.

Thus:

```text
Module = normal persisted code unit
Eval overlay = ephemeral/generated module-like code unit
```

Both use the same reader, compiler, namespace, import, and declaration mechanisms.


## 16. Foreign function interface

FFI is a core architectural constraint, even if some convenience features are implemented after the first interpreter. It affects `Callable`, typed boundaries, memory ownership, garbage collection, modules, threading, and binary layout.

Gene defines three related interop layers:

1. a stable **native extension ABI** for functions and types implemented against the Gene runtime API;
2. a typed **C ABI binding layer** for calling external libraries;
3. higher-level wrappers and native modules that expose safe, idiomatic Gene APIs.

The C ABI is the first foreign target. C++, Rust, Nim, CUDA, and other systems integrate through C-compatible exports or through the native extension ABI.

### 16.1 Native functions

A native function is a first-class `NativeFn` value implementing `Callable`. Gene code calls it exactly like any other callable:

```gene
(strlen text)
(text ~ strlen)
```

The runtime-level native call shape is conceptually:

```text
NativeFn(Context, Call) -> Gene value or Error
```

A C-compatible entry point may use an ABI like:

```c
typedef struct GeneContext GeneContext;
typedef struct GeneCall GeneCall;
typedef struct GeneValue GeneValue;

typedef enum GeneStatus {
  GENE_OK,
  GENE_ERROR,
  GENE_PANIC
} GeneStatus;

typedef GeneStatus (*GeneNativeFn)(
  GeneContext *ctx,
  const GeneCall *call,
  GeneValue *result
);
```

`GeneCall` preserves positional arguments, named arguments, and call-site information. A native function validates or extracts arguments through the runtime API and writes either a result or an error.

The public ABI must not expose Nim object layouts, VM stack addresses, heap object layouts, or collector-specific pointers.

### 16.2 Typed C declarations

FFI declarations are compile-time declarations provided by the `ffi` module. They do not need to be core special forms.

```gene
(ffi/library libc
  ^linux "libc.so.6"
  ^macos "libSystem.B.dylib"
  ^windows "msvcrt.dll")

(ffi/fn strlen
  ^library libc
  ^symbol "strlen"
  ^abi C
  [s : C/CStr] : C/Size)
```

Usage is an ordinary call:

```gene
(var n : C/Size
  (strlen "hello"))
```

The compiler should generate a typed adapter whenever the declaration is statically known. Generated wrappers are the MVP mechanism: they are easier to validate, faster to call, and easier to debug than interpreting arbitrary ABI signatures at runtime.

Runtime signature construction through `libffi` or an equivalent library is optional post-MVP functionality.

An FFI declaration may specify a calling convention when the platform requires it:

```gene
(ffi/fn WindowProc
  ^library user32
  ^calling stdcall
  [...])
```

The default is the platform C calling convention.

### 16.3 Explicit ABI types

Gene types do not imply foreign binary layouts. `Int`, `Bool`, `Str`, and ordinary Gene records must not be used as if they were C types.

The FFI module provides explicit ABI types:

```gene
C/Int8     C/UInt8
C/Int16    C/UInt16
C/Int32    C/UInt32
C/Int64    C/UInt64
C/Float    C/Double
C/Char     C/UChar
C/Short    C/UShort
C/Int      C/UInt
C/Long     C/ULong
C/Size     C/PtrDiff
C/Bool     C/Void
C/CStr

(C/Ptr T)
(C/ConstPtr T)
(C/Array T n)
```

Fixed-width types should be preferred. Platform C aliases such as `C/Long` retain the target platform's ABI width.

Basic generics provide useful checking for pointer and container types:

```gene
(C/Ptr SDL_Window)
(C/ConstPtr C/Char)
(C/Slice C/Float)
```

The type argument describes the pointed-to value; it does not imply that the foreign memory is a normal Gene value.

### 16.4 Gradual typed boundaries and marshalling

Every FFI call is a typed boundary.

If an argument has type `Any`, Gene validates and marshals it according to the declared foreign parameter type before native code begins:

```gene
(strlen dynamic-value)
```

If `dynamic-value` cannot be converted to `C/CStr`, the runtime raises a recoverable boundary `TypeError`. Native code is not entered.

Automatic marshalling is limited to conversions with clear ownership and lifetime:

- checked numeric conversion, such as `Int` to `C/Int32`;
- `Bool` to the declared C boolean representation;
- `Str` to a temporary call-scoped `C/CStr`, rejecting strings with interior NUL unless the declaration explicitly uses a byte-slice form;
- typed `Buffer T` or `C/Slice T` to pointer-plus-length arguments;
- `nil` to a null pointer only when the declared parameter permits null.

Numeric conversion must check range. It must not silently truncate unless the declaration or call explicitly requests truncation.

A temporary C string or temporary marshalled buffer is valid only for the duration of the foreign call. A foreign function that retains a pointer requires an explicit owned, pinned, or copied value.

### 16.5 Pointers, buffers, and ownership

Raw foreign pointers are not ordinary Gene references.

The FFI foundation should provide:

```gene
(C/Ptr T)           # non-null raw pointer by default
(C/NullablePtr T)   # nullable raw pointer
(C/ConstPtr T)      # read-only non-null raw pointer
(C/NullableConstPtr T) # nullable read-only raw pointer
(C/OwnedPtr T)      # foreign pointer plus release operation
(C/Slice T)         # non-owning pointer and element count
(Buffer T)          # Gene-owned contiguous storage
```

A raw `C/Ptr` is non-owning. The programmer or wrapper is responsible for ensuring that its owner remains alive. Pointer arithmetic, arbitrary memory reads/writes, and unchecked casts belong to an explicitly unsafe FFI API, not normal selector or field access.

An owned result may declare its release function:

```gene
(ffi/fn SDL_CreateWindow
  ^library sdl
  ^symbol "SDL_CreateWindow"
  ^release SDL_DestroyWindow
  [...] : (C/OwnedPtr SDL_Window))
```

`C/OwnedPtr` should support deterministic cleanup through `close`. A finalizer may be a fallback, but finalization must not be the primary resource-management mechanism.

A foreign function returning borrowed memory should return `C/Ptr`, `C/ConstPtr`, or `C/Slice`, not `C/OwnedPtr`.

### 16.6 C structs and unions

C-layout records are declared explicitly:

```gene
(ffi/struct Timespec
  ^fields [
    [tv_sec  C/Long]
    [tv_nsec C/Long]
  ])
```

The compiler computes and verifies field offsets, alignment, size, and target ABI layout.

MVP restrictions:

- C layout only;
- no C++ object layout;
- no bitfields;
- no implicit packing;
- structs passed through pointers first;
- by-value struct arguments/results only after ABI conformance tests;
- unions, flexible array members, and variadic functions deferred.

A foreign struct value is not automatically a normal Gene node. Libraries may provide wrappers that implement `Node` or expose selector-friendly fields.

### 16.7 Errors across the boundary

FFI distinguishes three failure classes:

1. **Gene-to-ABI boundary mismatch** — a dynamic/`Any` value that fails an FFI parameter's boundary check raises a **recoverable** `TypeError` *before* the foreign function is called, consistent with the `Any`→typed boundary rule (§9). A fully typed wrapper that violates its own declared ABI contract internally is a **panic**, not a recoverable error.
2. **Expected foreign failure** — the low-level binding returns its C result, status, or `errno`; an ordinary Gene wrapper translates it into a typed Gene error.
3. **Native crash or memory corruption** — process-level failure; Gene cannot promise recovery.

The low-level FFI does not guess whether null, `-1`, a status code, or `errno` means failure. That policy belongs in a wrapper:

```gene
(fn open-file [path : Str] : File
  ^errors [FsError]
  (var p (c_fopen path "rb"))
  (if (null? p)
    (fail (FsError ^path path ^errno (ffi/errno)))
    (File ^handle p)))
```

Only types implementing the `Error` marker protocol may appear in `^errors` or be raised through `fail`.

### 16.8 Rooting and garbage collection

Native code must not retain raw Gene heap pointers.

Values passed into a native call remain valid for that call. A native function that keeps a Gene value beyond the call must create a runtime-managed root:

```text
root = gene_root(ctx, value)
value = gene_root_get(root)
gene_root_release(root)
```

The exact C names are ABI details, but the semantic rules are mandatory:

- an unrooted Gene value must not be retained across calls or VM safepoints;
- native code must use runtime APIs to inspect and construct Gene values;
- native code must not retain interior pointers into movable objects;
- pinned byte/string storage must be explicitly requested and released;
- all roots owned by an extension must be released when no longer needed.

This keeps the extension ABI compatible with a future moving or generational collector.

### 16.9 Native extension modules

A compiled extension module exports one versioned initialization function:

```c
GeneStatus gene_module_init(
  const GeneApi *api,
  GeneModule *module
);
```

The runtime passes a versioned API table. The extension may register:

- native functions;
- constants;
- native opaque types;
- protocol implementations;
- destructors/finalizers;
- module initialization and shutdown hooks.

The API table should include an ABI version and feature-size information. New runtime versions may append functions without changing existing offsets. An incompatible major ABI version must fail module loading cleanly.

Native types should normally expose opaque handles. Their internals belong to the extension, while optional protocol implementations provide `Node`, `Callable`, `Closeable`, or domain-specific behavior.

### 16.10 Dynamic loading and capability values

Loading arbitrary native code is authority. Runtime library loading requires an explicit capability:

```gene
(fn main [^native : Ffi/Load] : Nil
  (var lib (ffi/open native "./plugin.so"))
  ...)
```

The returned library handle grants access only to that loaded library. Symbol lookup requires possession of the handle.

Libraries linked or approved by the build/package manifest do not need runtime path authority. The manifest must record native dependencies and target-specific library names.

Raw pointer manipulation may additionally require an `Ffi/Unsafe` capability in APIs that expose it. This is runtime authority evidence in MVP, not a static `^effects` row.

### 16.11 Callbacks and foreign threads

Callbacks are harder than outbound calls because they may escape and may arrive on foreign threads.

A callback type may be expressed as:

```gene
(C/Callback [C/Int32 (C/Ptr C/Void)] C/Int32)
```

MVP callback support should begin with synchronous, non-escaping callbacks invoked on the current attached VM thread.

Escaping callbacks require an explicit callback handle that roots the Gene closure and is deterministically released. A foreign thread must attach to the runtime or enqueue work onto a Gene scheduler before executing Gene code. It must not enter the VM using an arbitrary unmanaged thread.

Callbacks, foreign-thread attachment, and reentrancy rules are post-core FFI work, but the native ABI must leave room for them.

### 16.12 FFI and GPU/native compute

GPU support should build on the same foundations rather than becoming a second unrelated interop system:

- explicit native modules;
- stable native call ABI;
- typed contiguous `Buffer T` values;
- explicit host/device ownership;
- asynchronous operation handles;
- explicit synchronization and error translation.

A GPU buffer is not a `C/Ptr` and should use a distinct device-specific type. CUDA, HIP, Metal, Vulkan, and accelerator libraries can first be exposed through native extension modules. Kernel syntax and compiler-generated device code are separate later design questions.

MVP native-compute scaffolding exposes `Device/Compute` authority and opaque
`Device/Buffer` handles with backend, element-type, and length metadata only.
They are not `C/Ptr` values, do not expose raw memory access, and are intended
as the stable boundary for later CUDA/HIP/Metal/Vulkan extension modules.

### 16.13 FFI MVP

The first FFI milestone includes:

- `NativeFn` integrated with `Callable`;
- a versioned runtime API table and native module initializer;
- opaque Gene values plus rooting;
- generated C wrappers for fixed-width scalars, `C/CStr`, pointers, and buffers;
- explicit typed C declarations;
- basic opaque handles and `C/OwnedPtr` cleanup;
- target-specific static/dynamic library names;
- runtime `Ffi/Load` capability for arbitrary dynamic loading.

Current implementation status: the interpreter has the native-call foundation,
version-checked native module initializer lookup, root handles, generated
`ffi/fn` C wrappers for supported scalar, `C/CStr`, pointer, `C/Slice`, and
`Buffer` ABI shapes, target-specific `ffi/library` metadata, runtime
`ffi/open`/`ffi/bind`, and deterministic `C/OwnedPtr` cleanup through `C/close`
when a release symbol is supplied. This is still an MVP FFI surface, not a
complete production FFI layer.

Deferred:

- runtime-created arbitrary signatures;
- C variadic functions;
- C++ ABI binding;
- bitfields and complex unions;
- general by-value aggregate ABI support;
- escaping callbacks and arbitrary foreign-thread entry;
- automatic header parsing as part of the language core;
- GPU kernel language/compiler integration.

### 16.14 Native compilation and mixed execution

Gene supports compiling sufficiently typed functions and modules to native machine code while preserving interoperability with bytecode and dynamic Gene code. Native compilation is incremental: a program may contain native-compiled typed functions, bytecode functions, native extension functions, and dynamically dispatched values at the same time.

A typed function such as:

```gene
(fn dot [a : (Buffer F32), b : (Buffer F32)] : F32
  ...)
```

may be compiled to a direct internal native signature using unboxed scalars and typed buffer references. The source-level call syntax does not change.

Gene therefore has two related internal calling conventions:

1. **Dynamic Gene ABI** — uses `GeneValue`, `GeneCall`, named arguments, `Callable`, dynamic dispatch, and recoverable error status.
2. **Typed native ABI** — uses statically selected representations, direct positional arguments, known return/error layouts, and direct calls where possible.

The compiler generates adapters between them. A native-compiled typed function still has a dynamic entry adapter so that ordinary untyped Gene code can call it:

```text
dynamic caller
→ validate typed arguments
→ unbox/adapt
→ typed native function
→ box/adapt result
→ dynamic caller
```

Crossing from `Any` into a typed native function uses the same gradual typed-boundary rule as assignment and typed arguments. Invalid dynamic input raises a recoverable boundary `TypeError` before the typed body begins.

#### Typed-to-typed calls

When caller and callee are both statically known and native-compiled, the compiler emits a direct native call. It may avoid:

- `GeneCall` allocation;
- boxing of primitive values;
- runtime argument matching;
- dynamic protocol lookup;
- repeated typed-boundary checks.

A typed function may still use dynamic operations. Operations involving `Any`, reflective selectors, unrestricted `eval`, dynamic `Callable` values, or unresolved protocol dispatch are emitted as calls to runtime helpers. The surrounding function remains native-compiled.

#### Native-to-bytecode and dynamic calls

Native-compiled Gene code may call any Gene callable, including bytecode functions. The compiler emits a runtime trampoline conceptually equivalent to:

```c
GeneStatus gene_call(
  GeneContext *ctx,
  GeneValue callee,
  const GeneCall *call,
  GeneValue *result
);
```

The mixed call path is:

```text
native typed code
→ box live arguments as GeneValue
→ construct GeneCall
→ enter Callable/apply or bytecode VM
→ receive GeneValue or Gene error
→ validate and unbox the expected typed result
→ resume native code
```

A result that does not satisfy the native caller's expected type raises a recoverable boundary `TypeError` when the value came from dynamic code. Recoverable Gene errors propagate through `GeneStatus` and the caller's checked/dynamic error rules. Panic remains a distinct fatal state.

Before entering the VM, generated native code must root any live Gene values that may survive a safepoint, enter a VM-compatible thread/state, and preserve a logical Gene stack frame. Stack traces should cross native/VM boundaries as one call chain.

#### Generics and specialization

Typed generic functions may initially use selective monomorphization:

```gene
(fn (sum t) [xs : (Buffer t)] : t
  ...)
```

Concrete calls such as `(Buffer I64)` and `(Buffer F64)` may receive separate native versions. The compiler may use a shared boxed implementation when specialization is not profitable or when types remain dynamic. Native compilation therefore does not require every generic instantiation to be monomorphized.

#### Protocol dispatch

If the receiver type and exactly one visible implementation are statically known, a protocol message call may compile to a direct native call. If the receiver or implementation is dynamic, native code invokes the runtime protocol dispatcher. The selected visible implementation is part of the compiled module's dependency information.

#### Data representation

Primitive values, typed buffers, and FFI ABI values can use unboxed native representations. Ordinary open Gene node/type values remain managed references unless the type makes a future explicit stable-layout promise such as `^sealed` or `^repr`. Native compilation must not silently expose VM object layout as a C ABI.

#### Eligibility and fallback

A function is eligible for typed native compilation when its parameter, return, local, and checked-error representations are sufficiently known. Unknown values may remain boxed, and unsupported operations may call runtime helpers. Eligibility is therefore granular rather than all-or-nothing.

The intended progression is:

1. bytecode execution for all code;
2. AOT compilation of selected typed functions;
3. AOT compilation of typed modules;
4. specialization of hot generic functions;
5. optional JIT compilation after the runtime and ABI stabilize.

The first backend may emit C for portability and straightforward integration with Nim and existing toolchains. LLVM or another lower-level backend may be added later for JIT, SIMD, and accelerator-oriented optimization.

---

## 17. Runtime and representation

The v1 VM direction is retained and extended with mixed execution:

- bytecode compiler and stack VM;
- computed-goto dispatch where available;
- `NativeFn` and native extension entry points;
- optional AOT-compiled typed functions/modules;
- generated dynamic/typed ABI adapters;
- a VM-entry trampoline allowing native code to call bytecode or dynamic Gene callables;
- NaN-boxed values for compact dynamic representation;
- heap objects for nodes, strings, streams, closures, applications, packages, modules, namespaces, `Env` values, eval overlays, tasks, channels, actors, mailboxes, and boxed immediates with meta;
- an M:N cooperative task scheduler with GC-aware suspension frames and worker-thread safepoints.

Runtime diagnostics may expose read-only GC/RC counters such as
`Runtime/gc-stats` so optimization and custom-GC work can be tested without
exposing object layouts.

`Any` uses dynamic representation. Type annotations enable optimization later: sealed layouts, unboxed fields, and specialized generic instantiations are post-MVP optimizations.

`^sealed` is reserved for a later optimization promise: a type's instance layout is closed enough for flat representation. It is not required in MVP.

---

## 18. CLI and tooling

MVP CLI:

```text
gene run
gene eval
gene repl
gene parse
gene compile
gene fmt
gene doc
```

`gene run path.gene args...` creates an `Application`, loads the entry package/module, executes the entry module top to bottom, and calls `main` with command-line arguments if present.

`gene eval` creates or reuses an application/runtime context, parses the supplied source as an eval module-like unit, evaluates it in an explicit or CLI-created `Env`, and prints the final result when appropriate.

`gene repl` retains a garbage-collected session environment and evaluation overlays across inputs.

`gene parse` and `gene fmt` operate on modules/source units but do not execute top-level forms.

`gene fmt` uses the printer and must round-trip selector slash spacing, immutable-literal prefixes, prop order, meta order, import forms, namespace forms, and pipe sugar reliably.

Prop print order should be deterministic. MVP recommendation: preserve source order when available; otherwise sort by symbol text for stable generated output.

---

## 19. Implementation order

1. Reader + canonical node model: props, meta, templates, spread, pipe, `~`, slash selectors, qualified-name/path tokens, `/` tokenization, and `#[]`/`#{}`/`#()` literals.
2. Runtime values, `nil`/`void`/`Never`, mutable and shallow-immutable containers, equality, hashing, `Cell`, and `AtomicCell` foundations.
3. Application/module foundation: `Application`, package root placeholder, module identity, root namespaces, `ns`, namespace imports, `from` module paths, normalized module identities, module cache, and top-level execution.
4. Callable-first evaluator: `var`, `set`, `do`, `if`, `fn`, `Call`, `Callable`, and `~`.
5. First-class `Env`: immutable binding maps, parent chains, module/import resolution, capability/policy fields, and tracing-GC integration.
6. Native call foundation: `NativeFn`, opaque runtime API, native registration, rooting contract, and `gene_call`-style VM trampoline.
7. Selectors and functional updates: `/...`, `(select ...)`, `%` stages, missing/`void`, `assoc-in`, and `update-in`.
8. Streams and generators: `(Stream T E)`, `yield`, `next`/`peek`/`has_next`, declaration streams, and parser stream shape.
9. Cooperative task runtime: `(Task T E)`, `scope`, `spawn`, `await`, cancellation, timers, safepoints, and async-I/O suspension hooks.
10. Pattern/destructuring engine: `match`, `var`, `for`, and `catch`.
11. Basic nominal types, single inheritance, direct construction stamping, `new`/`ctor` with pre-created `self`, basic generics, numeric hierarchy, gradual boundary checks, and conditional `Send` checking.
12. Bounded typed channels with suspension, close semantics, and backpressure.
13. Protocols/messages, `Error` and `Send` marker protocols, and visible-implementation coherence.
14. Typed actors: `ActorRef M`, bounded mailboxes, sequential handlers, request/reply, scope ownership, and basic supervision.
15. `fn!` runtime fexprs, templates/quasiquote expansion, and hygienic template macros.
16. Protocol-local `derive` experiment.
17. `try/catch/ensure` checked errors and cancellation propagation.
18. `eval node ^in env`: normal compiler pipeline, isolated overlays, `CompileError`, captured overlay lifetime, policy enforcement, and CLI/REPL environments.
19. Formatter/docs: deterministic printing, module docs, namespace docs, declaration streams, and import normalization reporting.
20. Typed native compilation prototype: direct typed ABI, dynamic adapters, native-to-VM calls, primitive unboxing, and C backend experiment.
21. Generated C FFI wrappers: ABI scalar types, strings, pointers, buffers, opaque handles, and ownership.
22. Versioned native extension modules and runtime `Ffi/Load` capability.
23. Runtime capabilities as library values.
24. Typed-module AOT, selective generic monomorphization, direct protocol calls, mixed native/bytecode stack traces, and native task-frame lowering.
25. FFI structs, callbacks, foreign-thread attachment, rooted actor/channel sends, dynamic signatures, and broader ABI conformance.
26. Actor state snapshots and live handler migration experiments.
27. Optimizations, custom GC, optional JIT/LLVM backend, static effects, distributed concurrency, and GPU/native-compute layers.

---

## 20. Pre-implementation readiness checklist

The design is close enough to start implementation once the following MVP cuts are accepted:

1. **Reader grammar freeze:** implement the reader from the EBNF in Section 2.2, including slash paths, qualified names, `%`, `#[]`, `#{}`, `#()`, comments, strings, interpolation, spread, and pipe folding.
2. **Core value model:** implement `Any`, `Never`, `Nil`, `Void`, scalar heads, mutable versus shallow-immutable containers, equality, hashing, and deterministic printing.
3. **Application/module model:** implement `Application` creation, package-root placeholder, file/eval modules, root namespaces, `ns`, namespace imports, `from` module paths, path normalization, module cache behavior, top-level execution, and `main` invocation.
4. **Minimal type checker:** support nominal types, single inheritance, direct construction, `new`/`ctor`, basic generics, unions, `T?` / `(? T)`, gradual typed-boundary checks, and recoverable boundary `TypeError`.
5. **Callable evaluator:** implement callable-first evaluation, syntax-callable dispatch, special forms, lexical bindings, `Call`, `SyntaxCall`, `Callable`, `SyntaxCallable`, `Fn`, `Fn!`, `NativeFn`, and `~` message sends.
6. **Selectors:** implement selector literals, static and dynamic `%` stages, `void` propagation, strict/default options, list/map/node/module/namespace lookup, and functional update paths.
7. **Streams and parser pipeline:** implement `(Stream T E)`, `yield`, `peek`, `next`, `has_next`, `close`, `Never` error normalization, declaration streams, and stream-shaped reader/parser output.
8. **Errors:** implement `Error` marker protocol, `fail`, `panic`, `try/catch/ensure`, `CompileError`, `MatchError`, `TypeError`, and checked/dynamic `^errors` rules.
9. **Protocols:** implement protocol declarations, messages, visible-implementation coherence, ambiguity errors, `^impl`, and basic `^derive` plumbing. Manual delegation is ordinary forwarding impls and needs no dedicated support; the derive-based delegation helper is deferred.
10. **Env and eval:** implement first-class GC-managed `Env`, explicit `eval node ^in env`, isolated overlays, compile-time/runtime capability separation, and overlay lifetime rules.
11. **Concurrency foundation:** implement structured tasks, cancellation, bounded channels, `Send`, `Cell`, `AtomicCell`, then typed actors with sequential mailboxes.
12. **Native foundation:** implement opaque `GeneValue`, root handles, `NativeFn`, native registration, and the VM trampoline before broader C FFI or native compilation.
13. **Test corpus:** create golden reader/printer tests, module/import path normalization tests, namespace tests, selector tests, type-boundary tests, protocol ambiguity tests, eval isolation tests, stream tests, and actor scheduling tests.

Deferred until after the first implementation slice:

- package dependency resolution, versions, lockfiles, registries, and publishing;
- full FFI struct/union/variadic coverage;
- callbacks and foreign-thread attachment;
- native AOT backend beyond the native-call foundation;
- actor supervision migration and live code replacement;
- generic constraints, variance, higher-kinded types, and specialization policy;
- static effect rows;
- distributed actors and GPU kernel/device-execution policy.

---

## 21. Settled design notes

- Every `gene run` starts an `Application`, loads an entry package/module, executes the entry module top to bottom, and calls `main` when present.
- A module has a root namespace. Nested namespaces use `ns`. Imports can read from built-in namespace paths or from normalized module path strings using `from "path"`; package dependency management is deferred.
- `Any` is the MVP top gradual type. A separate static root such as `Value` is deferred.
- `Never` is the bottom type and has no runtime values. `Nil` and `Void` are singleton types under `Any`, not bottom types.
- `nil` is explicit absence, not the default uninitialized value for typed lists, maps, or variables. Use `T?` or `(? T)` when `nil` is allowed.
- `^is` supports single nominal inheritance only. Children inherit and preserve parent schema in MVP; multiple behaviors use protocols.
- Plain lists, maps, and nodes may be mutable; `#[]`, `#{}`, and `#()` create shallow immutable values. Strings are immutable.
- `Cell T` is local/non-thread-safe mutable state; `AtomicCell T` is the explicit linearizable shared-memory escape hatch.
- Actors are the preferred model for long-lived stateful concurrency, built on structured tasks and bounded typed channels.
- Actor and channel boundaries require `Send`; shallow immutability alone is not sufficient.
- Actors process one message at a time without reentrancy, use bounded mailboxes, and are owned by scopes or supervisors.
- Standard selector-stage names are `props`, `body`, `meta`, `declarations`, `to_stream`, and `to_pairs_stream`. These are ordinary callable stages, not selector magic.
- Streams use `(Stream T E)`. `Never` contributes no errors, and error rows flatten and deduplicate.
- `~` is the message-send operator: `(x ~ f a)` resolves `f` receiver-first (type-direct messages, then protocol impls, then lexical fallback); `(x ~ X/f a)` resolves `X/f` lexically. Message names are not bound in the enclosing scope. See `docs/core.md §9`.
- Leading sends use lexical `self`: `(~ f a)` means `(self ~ f a)` when `self` is in scope.
- `(T ...)` is always direct typed-data construction and never calls `ctor`; it is the canonical printable/serializable form for typed instances. `(new T ...)` invokes `ctor` when present, with a pre-created in-progress `self`, and falls back to direct schema mapping when no `ctor` exists.
- `fn!` defines runtime fexprs / syntax callables that receive raw syntax and `caller-env`. `macro` is reserved for limited compile-time template expansion; full compile-time function macros are future work.
- Delegation is explicit protocol forwarding, written manually as `impl`s in MVP; future derive helpers may generate forwarding impls from selector paths.
- `Any`→typed boundary failures raise recoverable `TypeError` with blame. Internal typed representation contradictions are panics.
- Generic constraints are deferred until needed for generic derived implementations.
- Raw strings and binary literals are useful but not MVP.
- Static `^effects` rows remain deferred. Runtime capability values are explicit library/runtime objects.
- FFI starts with generated, statically checked C wrappers and a stable opaque native ABI. Runtime-created signatures come later.
- Native extensions use opaque `GeneValue`, explicit roots, and a versioned append-only runtime API table; Nim/VM heap layouts are never public ABI.
- Temporary FFI marshalling is call-scoped. Retained foreign memory requires explicit pointer/buffer ownership and deterministic cleanup.
- Escaping callbacks and arbitrary foreign-thread VM entry are deferred until scheduler/rooting rules are implemented.
- GPU/native compute builds on native modules, typed buffers, and opaque device-buffer handles; kernel compilation is a later design.
- Typed functions/modules can be compiled incrementally to native code, with boxed runtime-helper fallback for dynamic operations.
- Native code can call bytecode/dynamic Gene through a rooted `gene_call`-style trampoline; dynamic code calls native typed code through generated boundary adapters.
- The first AOT backend should probably emit portable C. LLVM/JIT can follow after semantics and the native ABI stabilize.
- Generic native code uses selective monomorphization with a boxed shared fallback.
- `eval node ^in env` compiles into an isolated overlay and never mutates or replaces source-module bindings.
- `Env`, captured overlays, and cycles participate in tracing GC; native retention requires normal roots.
- Eval authority is explicit through bindings, imports, capabilities, and policy. Untrusted eval has no ambient FFI/native authority.
