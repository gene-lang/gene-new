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

**D5, decided 2026-10-02:** normalize every macro result using this rule:

1. If the result is a `do` node, set its `macro_result` metadata to true.
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

The marker uses existing metadata syntax. Its compiler behavior is a design
target, not a claim about the current runtime. Plain unmarked `do` retains its
existing behavior. The earlier `^^create_scope` idea is not required by this
macro contract; `^^macro_result` is the selected compiler marker.

Determine scope requirements at compile time, accounting for substituted body
arguments and further expansion. Count declarations owned by this block:
`let`, `var`, `const`, destructuring, named declarations, imports that bind
names, and other binding forms already recognized by the compiler. A declaration
in a conditional branch counts if it belongs to this block's ordinary scope.
Bindings inside a nested function or another scoped block belong to that inner
scope. `set` on an existing binding does not create a binding.

Build a fresh result node when adding the marker; preserve other metadata and
source locations without mutating shared template or argument syntax. Reuse
an existing outer `do` rather than add a redundant outer block. Nested marked
blocks retain their own scope decisions.

The effect is that declarations introduced by an expansion never add lexical
names to the caller's surrounding scope. This includes caller-supplied names
and declarations inserted through body arguments. Expression-only expansions
need no additional scope. The scope decision must not depend on which runtime
branch executes.

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
program; different generated work need not have the same cost.

The D5 marked block needs an implementation that preserves indexed access.
When it declares no bindings, its wrapper should be transparent to optimization.
When a scope is needed, compiler binding visibility with distinct slots in the
enclosing runtime frame may suffice. Do not require a new heap scope, closure,
or function call merely because a block has a lexical boundary. Preserve
capture identity, binding lifetime, repeated execution, and Env/reflection
behavior wherever those make the scope observable.

Extra locals and real runtime scopes can still affect current fast paths. For
example, `deriveScopelessChunk` admits parameter-only bodies with a specific
slot layout; an introduced temporary can make a function ineligible, just as
an equivalent handwritten local can. Optimize redundant temporaries when safe,
and test both slot access and fast-path eligibility. Do not promise that every
macro or scoped expansion has zero runtime cost.

### Reader and vector normalization

The reader currently preserves `%` and following forms as flat tokens inside
vectors. Both macro expansion and ordinary quasiquote expect unquote nodes,
which explains B2.

Choose one shared, context-aware normalization boundary for quasiquoted vector
contents. It may be in the reader or in template processing, but must serve
both runtime quasiquote and macro templates. Recognize unquote and splice
operands at the correct quotation depth and preserve their locations.

Do not change ordinary parameter-vector tokenization globally. Defaults, type
annotations, rest patterns, nested vectors, and literal quoted data depend on
that representation. Cover immutable vectors and vectors nested inside maps.
Any change to the observable code-as-data representation needs a compatibility
review even when no new spelling is introduced.

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
section 8. Do not turn these cases into implicit evaluation.

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
| 1. Substitution | B2 and quotation-depth coverage | Vector unquote/splice works in ordinary quasiquote and macros without changing ordinary parameter vectors |
| 2. Expansion scopes and bindings | D5 plus B1, B3, B4 as one binding-resolution effort | Declarations stay inside each expansion; explicit names and body arguments connect locally; private temporaries cannot capture caller references; data labels remain unchanged |
| 3. Ordinary integration | B5, B7, declaration validation and useful diagnostics | Multi-input REPL persistence, same-file qualified calls, and imports behave consistently |
| 4. Call-site lookup contract | L1 and the decided D1 rule | Local and imported macros resolve free helpers at the call site; aliases/re-exports add no hidden definition context; absent dependencies produce useful errors |
| 5. Eval context | B6, after the environment decision | Macro visibility follows the selected evaluation environment while existing control-flow and mutation boundaries remain intact |
| 6. Optimization, tooling, and profile coverage | O1, macro docs, formatting, VM/web fixtures | Equivalent expanded code retains eligible optimizations; tools describe supported macros and the web backend diagnoses unsupported cases explicitly |

Diagnostics may land alongside any stage. Resolve the stricter L3 contract
before enforcing it. Keep definition-before-use, explicit caller names within
expansion scopes, and documented backend limits unless separately changed.
Migrate uses and tests that currently rely on declaration export as part of D5,
and update the public guides/specs and change log in the same implementation
change. Full compile-time function macros are outside these stages.

The web profile already supports top-level templates, but the review found
local macro definitions and macro-generating macros unsupported there (L5).
Do not silently accept different binding semantics for forms admitted by both
backends. For excluded forms, give a profile-specific error; expanding web
coverage can be scheduled separately.

## 7. Regression coverage

Test observable results, binding collisions, and error locations. Asserting
only that a generated name has a prefix is not a hygiene test. For each scope
case, include both an absent caller name and a same-spelled caller binding:
absence catches unresolved names, while collisions catch silent miscompilation.

| Area | Required cases |
| --- | --- |
| B1 body visibility | `with_square` returns `16` with its generated function consumed inside the expansion; direct siblings in fn, branch, loop, for, scope, match, and try bodies; a try handler cannot hide a bad expansion; nested shadowing follows ordinary rules |
| B2 vectors | `pair` returns `[1 2]`; generated parameter and destructuring vectors; ordinary quasiquote; list splices, nested maps/vectors, immutable vectors, and nested quotation depth |
| B3 syntax roles | `rec/key` still returns `7`; `a/a` returns its property; message `size` is unchanged by a local `size`; `(quote x)` stays `x`; quoted match literals retain meaning; vector path roots resolve |
| B4 capture | Caller `x = 10` under generated parameter `x` still gives `11`; caller `i = 99` summed across three iterations gives `297`; `first_or` gives `100`; destructured template binders neither collide nor become caller-visible |
| Repeated and nested expansion | Separate temporary identities per call; outer caller syntax survives inner expansion; template references still bind to their matching declarations |
| D5 scoped declarations | `with_value` returns `84`; its name is absent afterward or leaves a same-named outer binding intact; declarations spliced through body arguments also stay local; nested and repeated expansions are isolated; returned closures retain needed locals; declaration-export examples are rejected outside their expansion |
| Explicit names | Caller-supplied declaration names, parameter lists, and bodies intentionally connect only within their expansion; fixed template temporaries remain inaccessible to caller body syntax |
| B5 and B7 visibility | Separate REPL inputs; failed-input state handling; local-scope isolation; same-file namespace call; selected, wildcard, alias, renamed, private, and re-exported imports |
| L1 call-site context | A caller helper determines the result even when the defining module has a same-named helper; absent caller helpers fail; private helpers are not implicitly exposed; free helper macros require call-site visibility; aliases/re-exports retain these rules |
| B6 evaluation | Env and CallerEnv macro visibility per the chosen policy; isolated environments; locally defined eval macros; caller control-flow targets remain rejected |
| L3 and diagnostics | Missing backtick, unknown unquote name, computed unquote, malformed unused definitions, duplicate parameter binders, pattern/type mismatch, recursion limit, and expansion source chain |
| Existing semantics | Named/rest/default/typed syntax parameters; argument duplication and skipping; reading and assigning existing caller variables; return/break/continue; tail recursion; quoted macro calls; generated macros consumed inside their expansion |
| O1 optimization | Direct and macro-expanded equivalent scoped functions; redundant wrappers; indexed locals and outer references; typed return/native specialization; scopeless-call eligibility; generated temporaries and captures; expansion scopes preserve lexical behavior without mandatory runtime allocation |
| Library consumers | Logging evaluates the logger once and skips disabled message/payload expressions; CSS retains symbolic names; test macros retain closure captures, parameter lists, hooks, and nested groups |

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

D1 and D5 are decided. The remaining choices do not block vector substitution
or introduced-binding fixes. Record each chosen rule here and in the relevant
implemented spec when it lands.

| Decision | Rule or recommendation | Status and implementation concerns |
| --- | --- | --- |
| D1: Free template references | Use ordinary lexical/module lookup at the call site | Decided 2026-10-02. Compile the expansion in a lexical child of the call site (D5); preserve introduced-binding protection and document helper visibility requirements |
| D2: Template-result and unquote grammar | Keep literal-result macros and explicit syntax templates; reject accidental executable bodies and unknown parameter unquotes | Proposed. Preserve or explicitly migrate parameter passthrough and quote/quasiquote constructors; define the allowed active unquote operands and nested-depth validation; do not silently evaluate `%(expr)` |
| D3: Eval compile-time context | Derive visibility from the selected Env or CallerEnv | Proposed. Acquisition through env construction, imports and parents; snapshot semantics; borrowed lifetimes; visibility of later definitions; persistence of eval-local macros |
| D4: Macro/value shadowing | Keep one unambiguous meaning for a visible call-head name, with consistent handling of imports | Proposed. Whether nested ordinary binders may shadow macros; the current local/import inconsistency; what REPL redefinition permits |
| D5: Expansion-local declarations | Every expansion owns a lexical scope, conceptually `(do ^^create_scope ...)`; no declarations enter the caller's surrounding scope | Decided 2026-10-02. Caller-supplied names and body arguments can share bindings inside the expansion; returned values/closures can escape normally; preserve caller control flow and indexed-access optimizations; migrate existing declaration-export uses |

The owner-approved direction is to retain narrow template macros and repair
correctness. These detailed semantic choices must remain explicit during that
work; do not introduce new syntax or silently broaden evaluation semantics to
make an implementation easier.
