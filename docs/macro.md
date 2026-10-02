# Template macros: design and implementation guide

**Status:** design direction and repair plan, updated 2026-10-02. Gene already has
template macros; the guarantees below describe the intended reliable subset,
not a claim that every guarantee is implemented. Sections marked **proposed**
identify semantic decisions to settle before their implementation. No new
reader syntax is proposed.

The starting evidence is the [macro feature review](../tmp/macro-comments.md),
which tested a build from `47a8942` and assigned the B1–B7 and L1–L5 issue IDs
used below. That review's results are a baseline, not verification of later
changes. This guide restates the important findings so implementation does
not depend on retaining the temporary report.

For the current public explanation, see [the language guide](language.md#macros-fexprs-and-eval)
and [the design rationale](design.md#syntax-extension-has-two-tools).
The [call contract](spec/calls.md#fexpr-evaluation-boundaries) defines the
existing boundaries between lexical code, fexprs, and `eval`.

## 1. Purpose and scope

Keep a small template macro facility for reusable syntax that expands into
ordinary lexical code. Make binding and substitution dependable before adding
more expansion capabilities.

Gene's shared representation of code and data makes templates a natural fit.
Macros let a library express conditional evaluation, scoped binding helpers,
or control-flow wrappers while preserving the surrounding program's lexical
behavior. Each expansion is marked as a macro result; a scope is created when
that result declares bindings, keeping them out of the caller's surrounding
scope (D5). Functions and protocols remain the default for ordinary computation.
Scope-sensitive registrations such as `impl` also need an explicit visibility
rule; the proposed extension under D7 must be settled before runtime scope lowering.

There are existing library consumers. `builtinLogMacro` implements lazy
logging, `builtinCssDeclMacro` preserves declaration names as syntax, and
`builtinTestMacro` generates closures for test groups, examples, and hooks.
These live in [the compiler](../src/gene/compiler.nim); the testing macros are
used throughout the example applications. Preserve these consumers through
the repairs.

| Mechanism | Receives | Evaluates or produces | Appropriate use |
| --- | --- | --- | --- |
| Ordinary function | Evaluated arguments | Runtime values | Computation and reusable behavior |
| Template macro | Unevaluated argument syntax | Syntax compiled in the expansion position | Small lexical syntax abstractions |
| Fexpr | Unevaluated argument syntax at runtime | Runtime values, possibly through explicit `eval` | Deliberate runtime interpretation |

A macro expansion can refer to caller bindings and use caller control-flow
targets. An fexpr's evaluation copy cannot rebind the original caller's
variables, and it has no caller return or loop targets. Mutable values and
closures retain their ordinary effects. Do not change those boundaries to
make fexprs substitute for macros.

The repair project does not add arbitrary compile-time Gene execution,
compile-time I/O, procedural transformer APIs, reader extensions, automatic
hygiene, or a public syntax-object API. Macro-generating macros
already work in some VM cases, but extending their capabilities or promising
full web support is deferred. D5 intentionally removes the ability to export
declarations through expansion. Other existing working behavior needs
regression coverage before any intentional restriction or removal.

## 2. Expansion contract

### Definitions and invocation

Keep the existing surface:

```gene runnable
(macro unless [condition body...]
  `(if_not %condition %body...))

(var count 0)
(unless false (set count 1))
count # 1
```

A macro definition has a name, parameter vector, and exactly one result
expression. Its result is syntax, not the result of running an ordinary
function body at compile time. Macro names are compiler bindings; a macro
cannot be obtained as an ordinary runtime value or called through an arbitrary
runtime expression.

Preserve existing positional, named, rest, default, and destructuring
parameters. Typed macro patterns constrain the supplied syntax value: `Sym`
means a symbol, for example, not the type of the value obtained by executing
that symbol. Defaults supply syntax and may refer to earlier bound macro
parameters; they do not run arbitrary Gene expressions during expansion.

The initial repair retains definition-before-use for macros. Function forward
references do not imply macro forward references. Local macro definitions
remain local to their lexical compilation scope. Duplicate definitions and
macro/value conflicts must be diagnosed consistently for local definitions
and imports. The exact nested-scope shadowing policy is a decision in section 8.

Expansion recursively processes executable macro calls in the resulting
syntax. Quoted data must not trigger macro calls. Nested quasiquotes and their
active unquotes must respect quotation depth; a generic recursive tree walk
is insufficient. Enforce the existing expansion-depth limit and compilation
budgets across nested and imported expansions.

**D8, proposed after R3:** expand calls in expression positions, plus the
already-supported direct pipeline-slot context. A macro call must not stand
in for a structural `else`, `elif`, or `when` clause. Expressions inside those
clauses can still contain macro calls. Reject a call in an unsupported
structural position consistently on the VM and web backend; silently ignoring
it on one backend is not an acceptable alternative.

The current paths disagree: the VM gives nil for a macro-generated else clause
and rejects a macro-generated match clause, while the web frontend expands
both. This was independently reproduced as `nil`/error versus `2`/`"other"`.
Use the compiler's expression/structural position distinctions for traversal,
including executable defaults within signatures. A recursive walk over every
node is not the contract. Settle D8 before changing result wrapping.

### Evaluation and control flow

Macro arguments are syntax. They are not evaluated when matched or inserted.
Their eventual evaluation follows the expanded program: an argument used
twice can run twice, and an argument in an untaken branch does not run.

```gene runnable
(macro twice [value] `(+ %value %value))
(var calls 0)
(twice (do (set calls (+ calls 1)) calls)) # 3
calls # 2
```

A template that reuses an argument but promises one evaluation should bind it
once and reuse the binding. That local obeys ordinary shadowing rules; expansion
does not automatically rename it or preserve caller-origin binding identities.

The expansion adds no implicit function, loop, task scope, or eval boundary.
The resulting forms determine cleanup, return targets, loop targets, and tail
position. For example, `return` inserted into a caller function returns from
that function unless the template explicitly places it inside a new function.
Preserve tail calls and ordinary error propagation through expansions. Reading
or assigning an existing caller binding still follows ordinary lexical rules.

The expansion's result is the result of its final expression. Values, including
closures that retain expansion-local bindings, can be returned normally. A
caller that wants a persistent name can bind that returned value itself.

### Marking the result and creating a scope

**D5, decided 2026-10-02:** after validating expansion position and recognizing
context-sensitive syntax such as a direct pipeline slot, normalize every
executable macro result using this rule:

1. If the result is a `do` node, set its `macro_result` property to true.
2. Otherwise, wrap the result in `(do ^^macro_result <result>)`.
3. When compiling a `do` with `macro_result` true, create a lexical scope if
   the block declares bindings. Otherwise, compile it as ordinary sequencing.

For example:

```gene
# Expression result, before and after marking:
(helper 2)
(do ^^macro_result (helper 2))

# Block result, before and after marking:
(do (let answer 42) (+ answer 1))
(do ^^macro_result (let answer 42) (+ answer 1))
```

The marker uses existing boolean-property syntax: `^^macro_result` means
`^macro_result true`. It lives in the node's props, not its metadata; a boolean
metadata field would use `@@macro_result`. Keep the selected `^^` spelling.
Its compiler behavior is a design target, not a claim about the current runtime.
Plain unmarked `do` retains its existing behavior. The earlier `^^create_scope`
idea is not required by this macro contract.

**Proposed marker policy:** handwritten `do` forms with `macro_result` true
should use the same compiler rule. The marker identifies behavior rather than
proving that the node came from the compiler. This avoids a separate provenance
check or a spelling change. Generated results always set the property to true;
the treatment of a handwritten marker must be documented when implemented.

**Proposed value rule (R6):** only a literal boolean true enables the marker.
An absent property, false, or a non-boolean value is unmarked. Do not apply
truthiness or evaluate an expression stored in this control property. Generated
results overwrite it with true. Document the handwritten form as a general
conditionally scoped `do` when this policy lands, without claiming it is the
only scope-producing form in Gene.

Determine scope requirements at compile time, accounting for substituted body
arguments and further expansion. Count declarations owned by this block:
`let`, `var`, `const`, destructuring, named declarations, imports that bind
names, and other binding forms already recognized by the compiler. A declaration
in a conditional branch counts if it belongs to this block's ordinary scope.
Bindings inside a nested function or another scoped block belong to that inner
scope. `set` on an existing binding does not create a binding.

Build a fresh result node when adding the marker; preserve other props,
metadata, and source locations without mutating shared template or argument syntax. Reuse
an existing outer `do` rather than add a redundant outer block. Nested marked
blocks retain their own scope decisions.

The effect is that declarations introduced by an expansion never add lexical
names to the caller's surrounding scope. This includes caller-supplied names
and declarations inserted through body arguments. Expression-only expansions
need no additional scope. The scope decision must not depend on which runtime
branch executes.

### Context-sensitive results: pipeline slots

Preserve the existing ability for an expansion to supply a direct pipeline
slot. Classify the raw expanded result in its surrounding syntax context
before a sequencing wrapper can hide that role. Pipeline lowering consumes
the slot and supplies the pipeline input; do not compile an unresolved `_`
inside the wrapper. Apply result marking to the executable expansion.

```gene runnable
(fn pair [a b] [a b])
(macro slot [] `_)
(1 -> pair 0 (slot)) # [0 1]
```

Keep the multiple-direct-slot diagnostic, source provenance, and the distinction
between a direct slot and an underscore inside ordinary nested code. This does
not make arbitrary handwritten `do` bodies transparent to slot recognition.
The VM and web frontend must use the same ordering.

Do not exempt every non-node value from result marking. Lists, maps, and other
compound syntax can contain executable declarations even though their outer
representation is not a call node. For example, `[(let answer 42) answer]`
creates a binding when evaluated today; a macro returning that syntax must
still confine the declaration. Scalar wrappers can be eliminated during normal
lowering when they have no observable effect.

### Quasiquote and splicing

Use the existing backtick, `%`, and `%items...` spellings. Macro unquote
inserts syntax from the template-expansion environment. Ordinary runtime
quasiquote evaluates its active unquote expressions to obtain inserted values.
The shared notation does not make template expansion an arbitrary evaluator.

List elements, node bodies, and nested containers must recognize active
unquotes consistently. In particular, these are target regression cases,
currently broken by B2:

```gene
(macro pair [a b] `[%a %b])
(pair 1 2) # Target: [1 2]

(macro lam [parameter body] `(fn [%parameter] %body))
((lam n (* n 2)) 4) # Target: 8
```

Splicing applies only in supported sequence positions. Preserve the current
macro body-splice behavior: a List contributes its elements; a node contributes
its body and drops its head. Do not assume this also merges node properties;
ordinary call spreads have a separate contract. A spread written in a macro
call's arguments is syntax, not an eagerly evaluated argument spread.

Keep nested quotation depth, immutability markers, and source positions intact.
Unsupported splice positions should produce a diagnostic rather than silently
drop syntax. Broadening splice behavior is outside the correctness repair.

## 3. Ordinary binding after substitution

After substitution, the result follows ordinary Gene lexical binding rules.
There is no automatic hygiene or distinction between a reference authored in
the template and one supplied in an argument. The result scope contains new
declarations; it does not prevent those declarations from shadowing names in
inserted code.

```gene
(macro add_one [value]
  `(do
    (let tmp 1)
    (+ tmp %value)))

(let tmp 100)
(add_one tmp) # Target: 2, under ordinary substitution and shadowing.
tmp # Target: 100; the expansion does not redefine the outer binding.
```

There is no guaranteed collision-free temporary in this core design. A `swap`
template using `tmp` can fail or silently leave values unswapped when an operand
also names `tmp`; a long prefix reduces collisions but does not prevent them.
The explicit `^fresh` proposal from C1 is deferred as D6, not an implicit part
of removing automatic hygiene.

Before disabling the current rename pass, audit built-in templates that rely
on it, especially `builtinLogMacro` and its `generated_logger` local. Add probes
where logger, message, and payload syntax use that name. Any adjustment must
preserve the intended evaluation count and laziness, or document the deliberate
behavior change. Do not claim unchanged library behavior from literal-argument
tests alone.

The existing logger template uses `scope`, which owns tasks as well as local
bindings. After D5, replacing it with a marked result block is a possible
simplification, but it changes more than allocation: caller `break`/`continue`
and the ownership/lifetime of tasks spawned by logger, message, or payload code
must be checked. Treat timing improvements as a hypothesis until measured for
the revised implementation. A compiler-only temporary name is another candidate
for the built-in implementation, not a proven solution or a public D6 API.
`validateBindingName` accepting a spelling is insufficient: syntax can also be
constructed through `to_sym`, and artifacts, printers, eval, and both backends
must preserve any reserved-name or internal-identity invariant.

This deliberately replaces the earlier automatic-capture-protection proposal.
The implementation should remove the partial rename machinery behind B1, B3,
and B4, rather than extend it to every syntax form. Reuse ordinary compiler
binding analysis and the marked-block scope rule. Function parameters, loop
variables, match binders, destructuring, recursion, and initializer visibility
then have their usual meanings in the expanded code.

Do not rewrite property names, message names, or quoted symbols. Preserve
normal path parsing, including path roots represented as flat symbols inside
vectors. Template substitution still applies in `` `(quote %name) ``; a
literal `` `(quote x) `` keeps the symbol `x`. Existing CSS and testing macros
depend on that distinction. Macro calls inside quoted data remain data.

### Scoped bindings and caller-supplied bodies

When caller code needs a binding created by the macro, pass that code as a body
argument. A caller-supplied binding name makes the connection explicit:

```gene
(macro with_value [name value body...]
  `(do
    (let %name %value)
    %body...))

(with_value answer (+ 20 22)
  (* answer 2)) # Target: 84

answer # Target: undefined outside the expansion.
```

The final line illustrates the intended rejection; the current implementation
still leaks this caller-supplied declaration. Inside the expansion, `%name` and
the caller's references in `%body...` deliberately share the local binding.
Callers write ordinary code and need no `%answer` marker at the call site.
Outside the expansion, a same-named outer binding retains its original meaning.

A body can also refer to a fixed name created by the template if ordinary
lexical lookup makes it visible. There is no special capture escape syntax.
Macro authors must account for shadowing when introducing temporary names.
Caller-supplied parameter lists and matching bodies continue to work, as the
test macros already require.

This restriction covers declarations supplied by the caller as well as those
authored in the template: a `(let ...)` inserted through `%body...` stays inside
the expansion. Function, type, namespace, and macro declarations likewise
cannot introduce lexical names in the caller's surrounding scope. There is no
declaration-export or unscoped-expansion escape hatch in this design.

Existing declaration-producing macros must move their consumers into a body
argument or return a value for the caller to bind explicitly. A returned closure
may retain an expansion-local value; lexical confinement must not invalidate
that value or prematurely end its required lifetime.

```gene
(macro make_square [] `(fn [x] (let y (* x x)) y))
(let sq (make_square))
(sq 4) # Target: 16; the caller explicitly declares sq.
```

This also retains the B1 regression for direct function-body declarations.
The review's original `defsq` followed by a separate call through its exported
name is no longer a target success case.

### Call-site free references — decided

**D1, 2026-10-02:** retain ordinary call-site lexical/module lookup for free
names written in a template. This replaces the earlier proposal to capture the
definition's binding context. The L1 behavior identified by the review is an
intentional rule to document and test, rather than a lookup bug to reverse.

A free reference is a name used by the template without a template-introduced
binding for it. It behaves as if that reference had been written at the macro
call site:

```gene runnable
(macro scaled [value] `(helper %value))

(fn helper [x] (* x 100))
(scaled 2) # 200

(fn run_scaled [helper] (scaled 2))
(run_scaled (fn [x] (+ x 1))) # 3
```

The macro does not retain a connection to the first `helper`. The second
expansion resolves `helper` to `run_scaled`'s parameter through ordinary
lexical lookup. This is compile-time insertion into lexical code, not a new
dynamic-scoping mechanism or runtime `eval`.

The same rule applies across modules and to free helper-macro calls. Importing
a macro does not automatically import its author's helper functions or helper
macros. If a required name is absent at the call site, report the ordinary
unresolved-name error with macro expansion provenance; do not fall back to the
definition's environment. Aliases and re-exports preserve the template rather
than attach a different free-name lookup context.

Library macros should document their call-site dependencies. A qualified
public path can make a dependency explicit, but its root still follows normal
call-site lookup and must be available there. A macro can also accept a helper
as a syntax argument. Neither approach grants access to a private helper in the
defining module; private helpers require an ordinary public API when callers
need to reach them through expanded code.

Runtime helpers still run at runtime, and their lifetime and module
initialization follow the expanded program's ordinary rules. Compiler artifacts
need template data and source provenance, without capturing definition-site
runtime environments or private helper binding identities for free references.
Compile-time discovery must continue to avoid executing module initializers.

The earlier `%helper` definition-reference and quotation-depth-based `%`/`%%`
lookup ideas are outside the selected simple-substitution core. If revisited,
they need an explicit decision under D2; do not infer them from ordinary
quasiquote processing.

## 4. Modules, REPL, and eval

Macros belong to the compile-time environment. Runtime namespaces and values
alone cannot represent their visibility.

Preserve selected imports, wildcards, aliases, renaming, namespace imports,
re-exports, private declarations, and compile-time cycle diagnostics. B7 must
be fixed so an `ns` macro is reachable by its qualified name later in its own
file, under the same visibility rules used by importing code.

**D7, proposed after C4:** an `impl` or `import_impl` owned by a marked block
should count as scope-affecting even when it adds no ordinary variable. Its
registration should remain local to that block. Adding an unrelated `let`
must not change whether an implementation escapes. This is an extension of
the binding-only scope predicate and needs an explicit decision before stage 2b.
It would also confine a top-level macro-generated impl that is visible after
the call today; list that migration beside the loss of declaration export.

Do not silently choose the alternative that impls always affect the enclosing
scope merely because lexical bindings can use compile-time-only scopes. Runtime
allocation is an implementation choice; it must preserve the chosen impl
visibility, dispatch, and closure-lifetime rules. Reuse existing scoped-impl
machinery where applicable. Always-outward impl visibility was considered and
is not accepted by this guide.

For B5, a REPL session needs persistent compile-time state alongside its runtime
scope. A successful definition in one input must be available in the next.
Do not leak local macro definitions out of a function, expansion, or inner scope.
Decide and test when an input commits compiler state: failed compilation must not
leave partial definitions, and behavior after runtime failure must agree with
the REPL's declaration-persistence policy. Retain duplicate/conflict checks.

**Proposed for B6:** `eval` should compile against the macro context associated
with its selected Env or borrowed CallerEnv. It must not acquire an unrelated
ambient macro table merely because the same application loaded that module.
Specify how `(env)`, explicit parents/imports/modules, snapshots, and borrowed
caller environments obtain or restrict that compile-time context before
implementation. Do not assume every Env inherits the enclosing source unit.

Even if an eval environment can see a macro, its expansion is compiled inside
the evaluation boundary. It cannot recover caller `return`, `break`, or
`continue` targets, and it cannot bypass the existing binding-copy semantics.
Macro definitions inside evaluated syntax must follow the selected persistence
policy rather than accidentally changing the enclosing unit.

Keep compiler artifacts portable data, with no captured host closure or
borrowed runtime frame. Define lifetime and serialization handling for any
new context references; persistent REPL state must not retain dead activations.

**E1: caller-local visibility regression, confirmed 2026-10-02 (C8).** The
review's `(fn f [x] (show! (+ x 1)))` fails to find `x`. Adding an otherwise
unused `(env)` in `f` makes the same call return `6` for `x = 5`. This is not
evidence of an intentional top-level-only CallerEnv contract. It suggests an
optimization-dependent loss of local-name visibility; the precise cause still
needs diagnosis.

Inspect `chunkNeedsCallScopeSlotNames` and scope pooling in the compiler/VM
alongside `materializeCallerEvalParent`, which copies named slots into the
evaluation environment. Track E1 separately from macro-table visibility B6.
Test caller parameters and locals with and without otherwise irrelevant
scope-materializing operations. Do not make that workaround part of D3's API.
E1 is independent of macro semantics and may be fixed immediately; neither
stage 5 nor the D3 decision is a prerequisite.

## 5. Implementation approach

### Shared expansion and normal compilation

Use one semantic expansion implementation for the VM and web frontend. The
current VM calls `expandMacro` during compilation; `expandSourceUnitMacros`
also uses it while building a frontend artifact for other backends. Sharing
that helper does not by itself guarantee matching traversal, scope, or quote
behavior. Align those rules and cover both paths with common fixtures.

Keep template parameter matching and substitution separate from ordinary
binding resolution. Substitute arguments, mark the result, and compile the
result under the block rule. Preserve source locations and expansion provenance
for diagnostics without adding origin-based lookup or a separate hygiene pass.

Share declaration and pattern analysis with ordinary compilation.
`patternBindingNames` and related functions are useful starting points for
finding declarations owned by a block. Respect existing nested scope boundaries
and sequential visibility; do not make a second macro-specific set of binding
rules. Preserve Gene's public node representation, printing, and equality.

The VM currently expands through `compileExpr`, while `expandMacroTree` walks
the source tree more broadly. Share the supported-position rules (D8), not just
the substitution helper. Validate structural positions before expansion and
marking can turn clause data into a `do` expression. Preserve pipeline-slot
classification as an explicit existing context and test both backends.

### Optimization and variable slots

Macro expansion must remain compatible with ordinary local-slot allocation,
type analysis, capture planning, and tail-call handling. A macro call itself
is a compile-time operation; it must not become a runtime interpreter call.

The current compiler assigns locals numeric slots through `reserveLocal` and
emits indexed loads through `emitLoadBinding`. Outer references can encode a
scope depth and slot. Parameters are reserved before function-body locals.
`compileMacroCall` expands syntax and calls `compileExpr` in the same compiler
context, carrying tail position through. Expanded declarations can therefore
receive ordinary slots; a macro does not inherently require name-based lookup
or invalidate previously assigned variable positions.

**O1: observed optimization gap, 2026-10-02.** Some optimizations inspect the
original function-body syntax rather than the expanded code. This probe with
`bin/gene compile` demonstrates the difference:

```gene runnable
(macro identity_macro [value] `%value)
(fn direct [value : Int] : Int value)
(fn expanded [value : Int] : Int (identity_macro value))
(fn grouped [value : Int] : Int (do value))
[(direct 7) (expanded 7) (grouped 7)] # [7 7 7]
```

All three functions emit `opLoadLocalFast` for slot 0. Only `direct` receives
`opReturnBareInt` and the `int_identity` native specialization; `expanded` and
`grouped` use `opReturn` without that specialization. This is evidence of missed
optimization, not a measured runtime slowdown. Inspect `formsKnownBareInt`,
`exprKnownBareInt`, `detectNativeCompileOp`, and their `buildFunctionProto` call
sites. The same review should cover other analyses that examine source forms.

Make optimization analyses consume the resolved expansion or suitable lowered
code. Preserve macro provenance separately for diagnostics. Normalize ordinary
sequencing wrappers where semantically valid, so a redundant `do` does not hide
an otherwise eligible expression. Compare a macro with its equivalent expanded
program including the marked block and its required scope. The unwrapped
template alone is not the comparison program: for example, a declaration in
`unless` stays inside the macro result even though a handwritten unmarked
`if_not` can leave the same declaration visible afterward. Different generated
work need not have the same cost.

The D5 marked block needs an implementation that preserves indexed access.
When it declares no bindings and introduces no observable scope-sensitive
behavior, its wrapper should be transparent to optimization.
When a scope is needed, compiler binding visibility with distinct slots in the
enclosing runtime frame may suffice. Do not require a new heap scope, closure,
or function call merely because a block has a lexical boundary. Preserve
capture identity, binding lifetime, repeated execution, and Env/reflection
behavior wherever those make the scope observable.

The compiler may first model a block boundary and eliminate it when safe, or
determine the required boundary during lowering. This implementation choice
does not replace the owner's conditional-scope rule. Reuse existing block,
loop-body, and match-arm machinery where it preserves control flow and slots;
do not assume an empty runtime scope is universally unobservable. D7 must define
impl visibility independently of the allocation strategy.

R2 identifies new compiler work, not an existing optimization to switch on.
Current ordinary for bodies and match arms use separate chunks, local tables,
and outer-local loads. Split scoped-result implementation into two parts:

- **Binding visibility and slots:** add block-local visibility within an
  enclosing chunk where valid. Save and restore name/type/mutability mappings,
  make duplicate checks relative to the lexical block, and give distinct
  declarations distinct slots. Two expansions may each declare `tmp` without
  colliding or changing the caller's slot mapping.
- **Runtime-visible scope state:** preserve capture and activation lifetimes,
  Env behavior, and the impl/import_impl rule selected under D7. Existing
  nested-chunk and impl-overlay machinery provides a baseline, but using it
  indiscriminately changes local loads to outer-local loads and can lose fast
  paths. Escaping mutable captures may need runtime storage even in a block
  with no impl; the split is not a promise that every binding-only block is
  allocation-free.

These parts can be developed separately with explicit supported cases. Do not
ship unsupported cases by letting declarations or impls escape. The loop
timings recorded under R2 in section 9 motivate measurement, but they include
pattern/task machinery and
do not isolate a universal scope-allocation cost. Acceptance should check
generated code and semantics, then measure representative equivalent workloads.

Extra locals and real runtime scopes can still affect current fast paths. For
example, `deriveScopelessChunk` admits parameter-only bodies with a specific
slot layout; an introduced temporary can make a function ineligible, just as
an equivalent handwritten local can. Optimize redundant temporaries when safe,
and test both slot access and fast-path eligibility. Do not promise that every
macro or scoped expansion has zero runtime cost.

### Reader and vector normalization

The reader currently preserves `%` and following forms as flat tokens inside
vectors. Macro expansion, ordinary quasiquote, and match-pattern pins expect
unquote nodes. The third consumer matters: `(when %a ...)` can match an earlier
binding, while `[%a b]` currently fails to do so inside a vector (C6).

Prefer normalizing `%form` into an unquote node in the reader for vectors too,
with correct operand parsing and source locations. A fix limited to template
processing would miss match patterns. Quasiquote depth still controls when a
consumer performs substitution; reader normalization must not evaluate syntax.

Keep unrelated parameter-vector tokens such as `:`, `=`, `^`, and commas under
their existing rules. A standalone `xs...` in a parameter/pattern vector retains
its flat rest-token handling. In contrast, `%xs...` should read as
`(unquote (... xs))`, matching a node-body splice so existing splice consumers
recognize it. Cover unquote/splice, immutable vectors,
nested vectors/maps, function parameter templates, and pinned match patterns.
The quoted data shape of `(quote [% x])` changes under this approach; verify
printing, formatting, and code-as-data consumers and record that compatibility
change even though no new spelling is introduced.

R1 exposes an interaction to settle alongside this normalization: match pins
and computed path segments use the same `unquote` representation as template
substitution. Normalizing the reader does not decide which consumer owns an
active occurrence. Use the D2 rule below consistently and test for silent loss
of pin/dynamic-path structure. The review found no affected `.gene` vector
spellings, but inspect tests, quoted data, and generated syntax too before
claiming no migration is needed.

### Diagnostics and tooling

Validate declaration shape when registering a macro, rather than waiting for
its first call. Report malformed bodies, invalid names, duplicate parameter
binders, invalid patterns or annotations, and reserved-head conflicts at the
definition. Preserve ordinary pattern rules where repeated names already have
defined meaning; do not invent a separate matcher policy accidentally.

Call errors should name the macro, failing parameter or pattern, expected
syntax kind or arity, and call location. Expansion errors should retain both
definition and invocation locations, including a nested expansion chain.
Preserve caller locations for inserted syntax and authored names in diagnostics.

L3 needs a defined template-result grammar before additional rejection rules.
Currently, a misspelled unquote can fall through as ordinary caller code, an
unquoted body can be inserted unchanged, and `%(expression)` is not an
arbitrary compile-time computation. The recommended stricter contract is in
the proposed D2 grammar below. Do not turn these cases into implicit evaluation.

### Proposed D2 grammar

Use C10 as a concrete proposal, pending the semantic decision:

| Macro result expression | Proposed treatment |
| --- | --- |
| Literal result | Insert it as syntax; retain forms such as `(macro seven [] 7)` |
| Bare macro parameter name | Insert its bound syntax; retain `(macro id [x] x)` |
| `(quote form)` | Return the quoted syntax |
| Quasiquote | Substitute the declared macro parameters at the active depth |
| Other call node or non-parameter bare symbol | Reject at definition time rather than silently insert an accidental body |

At an active unquote, `%name` must refer to a name bound by the macro signature,
including destructured, named, rest, or defaulted parameters. Preserve
`%items...` as the supported splice form. Reject arbitrary `%(expression)`;
definition-site `%helper` lookup is not implicitly enabled.

Validate at the owning quotation depth. Deferred nested templates are not
active unquotes of the current macro, and generated macro definitions need
their own signature validation. Check the existing nested-template and
macro-generating cases before enforcing the grammar. Exact literal/container
classification and migration of any rejected existing forms belong in the D2
implementation review; this proposal is not a claim of current validation.

### Unquote shared with pins and computed paths — proposed D2 limit

At the active template level, `%name` is template substitution. It must not
silently turn an unknown name into a plain symbol, because that can change a
match pin into a new binder or a computed path into a static property lookup.
The R1 examples currently return `true` instead of `false` and `99` instead
of `1`; both were independently reproduced.

The recommended small-core rule is to reject these non-parameter unquotes and
defer a literal-unquote escape. For a runtime comparison, use ordinary equality
and control flow; for a runtime map key, use an ordinary lookup such as
`(data .get key)`. Already-formed syntax supplied as
a macro argument remains syntax to insert; do not reinterpret its unquotes as
parameters of the receiving macro. Do not add a context-sensitive fallback that
guesses the author's intent from a name's spelling.

There is a qualification to R1's current-behavior claim: `%%a` already preserves
an unquote node in some cases. With caller-bound `a`, the pin works; with a
template-introduced `a`, current renaming breaks the link. This is not a reliable
escape contract to adopt accidentally. A future explicit literal-unquote escape
would be syntax construction, distinct from the earlier quotation-depth-based
caller/definition lookup proposal. Both remain outside this D2 proposal.

Keep formatting round trips valid and make `gene doc` list macro declarations
using compiler metadata. Macros should remain absent from runtime reflection
APIs whose contract is to expose runtime values.

### Source map for implementers

Use symbol names to locate code; line numbers will move during repair.

| File | Relevant implementation |
| --- | --- |
| [compiler.nim](../src/gene/compiler.nim) | `macroParamDef`, `macroTemplateValue`, `expandMacroQuasi`, `expandMacroDoNode`, `introducedBinderName`, `expandMacro`, `compileMacro`, `expandMacroTree`, `expandSourceUnitMacros` |
| [compiler.nim](../src/gene/compiler.nim) | `patternBindingNames`, `collectPatternBindingNames`, ordinary declaration/body compilers, `compileNs`, `importMacro`, `builtinNamespaceMacros`, `compileQuasiTemplate`, `compileQuasiList` |
| [reader.nim](../src/gene/reader.nim) | `parseForm` handling of `%` with `inList`, vector parsing, quotation and source locations |
| [gir.nim](../src/gene/gir.nim) | `MacroDef`, macro parameters/defaults, portable module artifacts |
| [vm.nim](../src/gene/vm.nim) | `runReplSession`, eval environment materialization, module compilation and macro artifact loading |
| [web.nim](../src/gene/web.nim) | Consumption of expanded frontend artifacts and web-profile validation |

## 6. Repair sequence and acceptance criteria

Each implementation change should include the failing regression that motivates
it and preserve existing working cases. Update current guides/specs when a
target guarantee becomes implemented; this design document alone does not
change the supported language contract.

| Stage | Work | Acceptance |
| --- | --- | --- |
| 1. Substitution | B2, C6/R7, and the D2/R1 active-unquote policy | Vector unquote/splice and pattern pins work through shared normalization; `%xs...` has the canonical splice shape; unrelated tokens retain their meaning; template pins/paths cannot silently change meaning |
| 2a. Marked results and binding visibility | D5, D8/R3, and replacement of the partial renaming behind B1, B3, B4 | Preserve pipeline-slot recognition before executable marking; align supported positions across backends; scope-aware duplicate checks and distinct same-frame slots where valid; declarations stay local; audit built-in temporary collisions |
| 2b. Runtime-visible scope state | D7 and R2/R4 capture, Env, and impl requirements | Local impl visibility is independent of unrelated bindings; escaped closures retain required state; return/loop targets and tail calls survive runtime scope management; unsupported cases cannot silently leak |
| 3. Ordinary integration | B5, B7, declaration validation and useful diagnostics | Multi-input REPL persistence, same-file qualified calls, and imports behave consistently |
| 4. Call-site lookup contract | L1 and the decided D1 rule | Local and imported macros resolve free helpers at the call site; aliases/re-exports add no hidden definition context; absent dependencies produce useful errors |
| 5. Eval context | B6, after the D3 environment decision | Macro visibility follows the selected evaluation environment; existing control-flow and mutation boundaries remain intact; account for the independently tracked E1 fix |
| 6. Optimization, tooling, and profile coverage | O1, macro docs, formatting, VM/web fixtures | Equivalent expanded code retains eligible optimizations; tools describe supported macros and the web backend diagnoses unsupported cases explicitly |

Diagnostics may land alongside any stage. Resolve the stricter L3 contract
and R1's unquote overlap before shipping the combined stage 1/D2 change.
E1 can be diagnosed and fixed independently at any time. Stages 2a and 2b are
separate implementation workstreams, not permission to ship different scope
semantics for unsupported cases. Keep definition-before-use, explicit caller
names within expansion scopes, and documented backend limits unless separately changed.
Migrate uses and tests that currently rely on declaration export as part of D5,
and update the public guides/specs and change log in the same implementation
change. Full compile-time function macros are outside these stages.

The web profile already supports top-level templates, but the review found
local macro definitions and macro-generating macros unsupported there (L5).
Do not silently accept different binding semantics for forms admitted by both
backends. For excluded forms, give a profile-specific error; expanding web
coverage can be scheduled separately.

## 7. Regression coverage

Test observable results, shadowing, declaration confinement, and error locations.
The original review assumed automatic hygiene; update those expectations to the
selected ordinary-binding model rather than blindly copying the old expected
values. Include absent and same-spelled caller names to distinguish leakage,
ordinary shadowing, and inconsistent compiler behavior.
Rename the existing "avoid introduced ... capture" tests to describe the
confinement or lookup they actually exercise. Add collision operands rather than
relying only on literal arguments.

| Area | Required cases |
| --- | --- |
| B1 body visibility | `make_square` returns a function that computes `16` for `4`; direct siblings in fn, branch, loop, for, scope, match, and try bodies resolve consistently; a try handler cannot hide a bad expansion |
| B2/C6 vectors | `pair` returns `[1 2]`; generated parameter and destructuring vectors; ordinary quasiquote; list splices, nested maps/vectors, immutable vectors, nested quotation depth; `(let a 1) (match [1 2] (when [%a b] b) (when _ "no"))` returns `2`; quoted vector shape is documented |
| B3 syntax roles | `rec/key` still returns `7`; `a/a` returns its property; message `size` is unchanged by a local `size`; `(quote x)` stays `x`; quoted match literals retain meaning; vector path roots resolve |
| Ordinary shadowing, replacing B4 hygiene expectations | The review's generated parameter example gives `6`, its loop example gives `6`, and `first_or` gives `1`; `add_one tmp` gives `2`; outer bindings retain their values after the expansion; destructured names remain local |
| Result marking | A non-do executable result gets one marked outer do; an existing do gets its boolean property set; preserve other props and metadata; leave quoted inner do data unchanged; do not mutate shared templates or arguments; test absent/true/false/non-boolean handwritten markers under the selected policy |
| R3 expansion positions | VM/web agree on expression calls inside clauses, defaults, and nested bodies; clause-generating calls are consistently rejected under D8; unknown clauses are not silently discarded; quoted data and direct pipeline slots retain their contracts |
| C3 pipeline slots | The direct-slot macro still gives `[0 1]`; multiple slots still fail; ordinary nested underscores remain nested; lists/maps containing declarations remain confined |
| D5 conditional scopes | No declarations or scope-sensitive registrations means no extra scope; direct, conditional, destructured, imported, and argument-supplied declarations are counted in their owning block; nested functions/scoped blocks own their declarations; set alone adds no scope; D7 determines registration handling |
| D5 scoped declarations | `with_value` returns `84`; its name is absent afterward or leaves a same-named outer binding intact; declarations spliced through body arguments also stay local; nested and repeated expansions obey ordinary scopes; returned closures retain needed locals; declaration-export examples are rejected outside their expansion |
| D7 impl visibility | Test impl-only and impl-plus-local results, import_impl, and a returned closure using the impl; visibility follows the chosen rule rather than allocation; 300,000-deep tail recursion through marked blocks containing locals and containing an impl completes |
| Body access | Caller-supplied names and body references connect normally; fixed template names are accessible to supplied bodies according to ordinary lexical visibility |
| B5 and B7 visibility | Separate REPL inputs; failed-input state handling; local-scope isolation; same-file namespace call; selected, wildcard, alias, renamed, private, and re-exported imports |
| L1 call-site context | A caller helper determines the result even when the defining module has a same-named helper; absent caller helpers fail; private helpers are not implicitly exposed; free helper macros require call-site visibility; aliases/re-exports retain these rules |
| B6 evaluation | Env and CallerEnv macro visibility per the chosen policy; isolated environments; locally defined eval macros; caller control-flow targets remain rejected |
| E1 caller locals | Fexpr eval can see caller parameters/locals consistently with and without an unused `(env)`; preserve the existing eval-copy and borrowed-lifetime boundaries |
| L3 and diagnostics | Missing backtick, unknown unquote name, computed unquote, malformed unused definitions, duplicate parameter binders, pattern/type mismatch, recursion limit, and expansion source chain |
| R1 unquote overlap | Pin/path examples cannot silently yield `true`/`99`; under proposed D2, unknown active unquotes fail with a useful alternative; supplied syntax retains its unquote nodes; distinguish currently working caller-bound `%%a` from broken renamed locals when documenting migration |
| Existing semantics | Named/rest/default/typed syntax parameters; argument duplication and skipping; reading and assigning existing caller variables; return/break/continue; tail recursion; quoted macro calls; generated macros consumed inside their expansion |
| O1/R2 optimization | Direct and macro-expanded equivalent functions; transparent wrappers; repeated expansions reuse spellings without slot collisions; caller-local loads stay direct where valid; typed return/native specialization and scopeless eligibility; captures and both local/impl deep-tail cases remain correct |
| C1/R5 and library consumers | Pin swap collisions under plain substitution; audit logger/message/payload uses of `generated_logger`; preserve or explicitly migrate logger evaluation count, laziness, caller control flow, and spawned-task ownership if removing scope; validate any compiler-private temporary across generated syntax/artifacts/backends; CSS and test macros retain their contracts |

Put language cases in [spec_runner.nim](../tests/spec_runner.nim), focused
execution cases in [test_vm.nim](../tests/test_vm.nim), import cases in
[test_modules.nim](../tests/test_modules.nim), and REPL/diagnostic/tooling cases
in [test_cli.nim](../tests/test_cli.nim). Put common VM/web cases in
[transpile fixtures](../tests/transpile/fixtures.json). Include runtime
quasiquote tests for B2, so a macro-only fix cannot appear complete.

Run the relevant focused suites during development, then `nimble spec` and
`nimble test` for compiler/runtime integration. Changes affecting shared
expansion also need `nimble transpile_spec`; emitted TypeScript changes need
`nimble transpile_typecheck`. Run lifetime coverage when persistent environment
or artifact ownership changes. Distinguish existing failures from regressions.

Examples above marked `gene runnable` exercise existing behavior. Unmarked
examples with target results describe required fixes and must not be advertised
as currently passing. Promote them to executable documentation when repaired.

## 8. Decision record and remaining semantic choices

D1 and the core D5 rule, together with ordinary binding after substitution,
are decided. Coordinate the D2/R1 unquote policy with reader normalization.
Settle D8 before changing expansion traversal, D7 before runtime scope lowering,
and the marker-value policy before exposing its compiler behavior. E1 remains
independent of these decisions. Record each chosen rule here and in the relevant
implemented spec when it lands.

| Decision | Rule or recommendation | Status and implementation concerns |
| --- | --- | --- |
| D1: Free template references | Use ordinary lexical/module lookup in the expanded code | Decided 2026-10-02. No automatic hygiene or origin-based lookup; ordinary shadowing applies; document dependencies on caller-visible helpers |
| D2: Template-result and unquote grammar | Proposed C10 grammar plus R1: active unquotes perform parameter substitution; no literal-unquote escape in this repair | Proposed in section 5. Reject accidental bodies and unknown active unquotes, including residual pin/path attempts; preserve nesting and supplied syntax; definition-site lookup and arbitrary compile-time execution remain deferred |
| D3: Eval compile-time context | Derive visibility from the selected Env or CallerEnv | Proposed. Acquisition through env construction, imports and parents; snapshots and borrowed lifetimes; later definitions and eval-local macros; investigate E1 without treating it as an intended CallerEnv restriction |
| D4: Macro/value shadowing | Keep one unambiguous meaning for a visible call-head name, with consistent handling of imports | Proposed. Whether nested ordinary binders may shadow macros; the current local/import inconsistency; what REPL redefinition permits |
| D5: Marked results and local declarations | Wrap a non-do executable result in `(do ^^macro_result <result>)`, or set the boolean property on an existing do; create a scope when it declares bindings | Core decided 2026-10-02. Classify position/slots before wrapping. Proposed handwritten policy: same behavior, enabled only by literal true; absent/false/non-boolean is unmarked. D7 covers registrations |
| D6: Explicit fresh names | Defer `^fresh`; keep ordinary substitution without a capture guarantee | C1 identifies a real limitation and required library audit. An explicit freshness API would need separate rules for inserted arguments, quote depth, and symbol roles; it is not approved as part of this repair |
| D7: Scope-sensitive registrations | Proposed: treat block-owned impl/import_impl as requiring local scope even without variables | Open semantic decision before stage 2b. Adding an unrelated local must not alter whether impls escape; scope allocation cannot determine language semantics; top-level impl-producing macros require migration |
| D8: Supported expansion positions | Proposed: expression positions plus existing direct pipeline-slot substitution; no clause-position macros | Settle before stage 2a. VM/web must share syntax-role traversal and reject unsupported positions consistently; preserve expression macros inside valid clauses |

The owner-approved direction is to retain narrow template macros and repair
correctness. These detailed semantic choices must remain explicit during that
work; do not introduce new syntax or silently broaden evaluation semantics to
make an implementation easier.

## 9. Reference: finding IDs and behavior changes

Sections 1–8 cite findings by ID. This key makes those references resolvable
without the temporary reports; the full probes and the two review threads are
archived in [the macro feature review](../tmp/macro-comments.md). D1–D8 are
defined in section 8, E1 in section 4, and O1 in section 5.

### Finding IDs

| ID | Finding |
| --- | --- |
| B1 | A template-introduced `var`/`let`/`fn` resolves only directly under `do`; in fn, branch, loop, for, scope, and match bodies its uses become undefined symbols |
| B2 | `%x` inside `[...]` is not substituted, in macro templates or runtime quasiquote |
| B3 | Renaming by symbol name rewrites path segments, message names, and quoted symbols, and misses path roots inside vectors |
| B4 | Function parameters, `for` variables, match binders, and destructuring binders are not renamed, so they capture caller code and can leak |
| B5 | The REPL drops macro definitions between inputs |
| B6 | `eval` and fexprs cannot see the enclosing unit's macros |
| B7 | An `ns` macro cannot be called by its qualified name in its own file |
| L1 | Free names in a template resolve at the call site |
| L2 | A template cannot introduce a fixed name that code after the call can use |
| L3 | A missing backtick, a misspelled `%name`, and `%(expr)` are inserted as ordinary code without a diagnostic |
| L4 | Macros require definition before use, and a macro name blocks later bindings of that name in the file |
| L5 | The web profile rejects local macro definitions and macro-generating macros |
| C1 | Without renaming there is no collision-free temporary; `swap` fails or silently does nothing when an operand is named like the template's local |
| C2 | `^^macro_result` is a property, not metadata, and can be written by hand |
| C3 | Wrapping a result hides a macro-produced direct pipeline slot |
| C4 | Whether a macro-generated `impl` escapes depends on how the result scope is implemented |
| C5 | A macro differs from its unmarked handwritten expansion: declarations stay inside the marked block |
| C6 | A match pin works as `(when %a …)` and fails inside a vector pattern `[%a b]` |
| C7 | Declaration export through expansion is removed; no in-repository use was found |
| C8 | A fexpr inside a function cannot read that function's locals through `caller_env` (tracked as E1) |
| C9 | The existing "avoid … capture" spec tests pass literal arguments and do not exercise capture |
| C10 | A concrete template-result grammar (the D2 proposal) |
| R1 | A non-parameter `%name` in a template silently turns a match pin into a binder and a computed path segment into a static one |
| R2 | `for` bodies and match arms compile as nested chunks; same-frame block visibility is new compiler work |
| R3 | The VM expands macro calls only in expression positions, while the web frontend expands them anywhere in the tree |
| R4 | Existing scoped blocks confine an `impl`, keep it for closures created inside, and preserve deep tail recursion |
| R5 | The built-in log macro wraps its body in a task `scope`, which D5 could make unnecessary |
| R6 | Only a literal true enables the marker |
| R7 | A vector splice `%xs...` should read as `(unquote (... xs))`; E1 is independent of the macro stages |

R2 timing, 2,000,000 loop iterations on the 2026-10-01 build (user seconds):
plain `do` with a declaration 0.26; match arm without a declaration 0.89; match
arm with a declaration 1.06; task `scope` with a declaration 0.71. The match
rows include pattern dispatch.

### Behavior changes to record in the change log

These follow from the decided and proposed rules. Rows that depend on a
proposal apply only if that proposal is adopted.

| Case | Today | After the repair |
| --- | --- | --- |
| Template local with the same name as an argument's variable, e.g. `(swap tmp y)` or `(add_one tmp)` | Protected for `do`-level binders: `[2 1]`, `101` | Ordinary shadowing: `swap` fails or leaves values unswapped, `add_one` gives `2` |
| Macro expanding to `fn`, `type`, or `let` with a caller-supplied name | Name usable after the call | Name confined to the expansion (D5) |
| Macro expanding to an `impl` at top level | Impl visible after the call | Impl confined to the expansion (D7) |
| Macro call in a clause position, e.g. generating `else` or `when` | VM: `nil` or unknown-clause error; web: expands | Rejected on both backends (D8) |
| Quoted data `(quote [%x])` | `[% x]`, two flat tokens | A vector containing an unquote node (stage 1) |
| Macro body without a backtick, unknown `%name`, `%(expr)`, including the `%%a` pin spelling | Inserted as ordinary code | Rejected at definition (D2) |
| Log macro argument that mentions `generated_logger` | Caller's binding | Collides unless the built-in template is changed |
