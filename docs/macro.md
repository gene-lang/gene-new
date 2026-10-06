# Macros: design and implementation guide

**Status:** implemented design and regression guide, updated 2026-10-03.
The numbered choices are decided or explicitly deferred. Backend and lifetime
limits are called out below. No new reader syntax is introduced by these
decisions. Historical findings describe the reviewed baseline, not the repaired
implementation.

**Implementation checkpoint, 2026-10-03:** the working implementation executes
macro bodies through the VM, normalizes result scopes on both backends, carries
macro contexts through Env/CallerEnv and REPL inputs, and preserves shared
definition contexts in GIR artifacts. Focused checks cover caller loop exits
through runtime scopes and cleanup, generator suspension, expression fast
paths, scope confinement, and macro execution budgets. Escaped helpers and Env
values retain their definition context; private compiler applications are
reclaimed on the owner lane once no external references remain. Published
contexts remain conservatively pinned. Local macros now expand against their
live definition environment when execution reaches the call. REPL compiler
state commits after successful compilation, including when execution fails.
Runtime macro invocations inherit ordinary execution budgets. The regression
matrix below records the contract; the web-profile and general mixed-scope
lifetime limitations remain explicit.

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

Keep macro semantics close to ordinary Gene evaluation. A macro body runs to
produce a value that is compiled as code at the call site. Templates are a
convenient way to construct that result, not a required body grammar.

Gene's shared representation of code and data makes templates a natural fit.
Macros let a library express conditional evaluation, scoped binding helpers,
or control-flow wrappers while preserving the surrounding program's lexical
behavior. Each expansion is marked as a macro result; a scope is created when
that result owns bindings or impl visibility, keeping them out of the caller's
surrounding scope (D5/D7). Functions and protocols remain the default for ordinary
computation.

There are existing library consumers. `builtinLogMacro` implements lazy
logging, `builtinCssDeclMacro` preserves declaration names as syntax, and
`builtinTestMacro` generates closures for test groups, examples, and hooks.
These live in [the compiler](../src/gene/compiler.nim); the testing macros are
used throughout the example applications. Preserve these consumers through
the repairs.

| Mechanism | Receives | Evaluates or produces | Appropriate use |
| --- | --- | --- | --- |
| Ordinary function | Evaluated arguments | Runtime values | Computation and reusable behavior |
| Macro | Unevaluated argument syntax | Evaluate its body during expansion; compile the resulting value at the call site | Syntax generation, commonly through templates |
| Fexpr | Unevaluated argument syntax at runtime | Runtime values, possibly through explicit `eval` | Deliberate runtime interpretation |

A macro expansion can refer to caller bindings and use caller control-flow
targets. An fexpr's evaluation copy cannot rebind the original caller's
variables, and it has no caller return or loop targets. Mutable values and
closures retain their ordinary effects. Do not change those boundaries to
make fexprs substitute for macros.

**D2a, decided 2026-10-02:** macro authors may use ordinary Gene code in the
macro body. Do not impose a template-only grammar, a whitelist of body shapes,
or a parameter-only rule for unquote. The compiler and VM should reject invalid
code or operations through their normal rules. Macro bodies now use ordinary
compiled functions, replacing the former template-only evaluator.

**D2b, decided 2026-10-02:** execute the macro body in its definition-side
lexical environment, like an ordinary function. This decision adds no new reader syntax,
automatic hygiene, or public syntax-object API. D5 intentionally removes the
ability to export declarations through expansion. Other existing behavior
needs regression coverage before intentional changes.

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

A macro definition has a name, parameter vector, and a body evaluated during
expansion. Its resulting value is then compiled as code. Backtick and quote
are ordinary tools for producing syntax values; neither is mandatory. Macro
names remain compiler bindings rather than ordinary runtime callable values.
Normal function-body sequencing and result rules are the implementation model;
do not retain the template evaluator's one-result-expression restriction merely
to prohibit ordinary body code.

Preserve existing positional, named, rest, default, and destructuring
parameters. Typed macro patterns constrain the supplied syntax value: `Sym`
means a symbol, for example, not the type of the value obtained by executing
that symbol. Defaults supply syntax and may refer to earlier bound macro
parameters. Integrate defaults with the definition-side invocation environment;
ordinary body evaluation must not silently change supplied arguments from syntax
into caller runtime values.

The initial repair retains definition-before-use for macros. Function forward
references do not imply macro forward references. Local macro definitions
remain local to their lexical compilation scope. Duplicate declarations within
one scope follow ordinary Gene rules, consistently for local definitions and
imports.

**D4, decided 2026-10-02:** macro names participate in ordinary lexical
shadowing. Resolve the nearest visible binding before deciding whether a call
expands a macro or invokes an ordinary value. A parameter or local binding can
hide an outer macro, and leaving that scope exposes the outer binding again.

```gene
(macro twice [x] `(+ %x %x))
(fn call_it [twice] (twice 3))
(call_it (fn [x] (* x 10))) # Target: 30
(twice 3) # 6
```

An inner non-callable value produces the ordinary call error; do not fall back
to the hidden macro. Value positions also refer to the nearest binding. The
existing restriction on using a macro itself as an ordinary runtime value
applies only when the resolved binding is actually a macro. Apply the same
lookup rules to selected, aliased, and wildcard imports. Existing special-form
head rules remain separate; D4 does not redefine compiler-dispatched syntax.

Expansion recursively processes executable macro calls in the resulting
syntax. Quoted data must not trigger macro calls. Nested quasiquotes and their
active unquotes must respect quotation depth; a generic recursive tree walk
is insufficient. Enforce the existing expansion-depth limit and compilation
budgets across nested and imported expansions.

**D8, decided 2026-10-02:** expand calls in expression positions, plus the
already-supported direct pipeline-slot context. A macro call must not stand
in for a structural `else`, `elif`, or `when` clause. Expressions inside those
clauses can still contain macro calls. Reject a call in an unsupported
structural position consistently on the VM and web backend; silently ignoring
it on one backend is not an acceptable alternative.

The review's baseline paths disagreed: the VM gave nil for a macro-generated
else clause and rejected a macro-generated match clause, while the web frontend
expanded both. This was reproduced as `nil`/error versus `2`/`"other"`.
Use the compiler's expression/structural position distinctions for traversal,
including executable defaults within signatures. A recursive walk over every
node is not the contract. Align both backends with D8 when changing result wrapping.

### Evaluation and control flow

Macro arguments are syntax. They are not evaluated when matched or inserted.
Their eventual evaluation follows the expanded program: an argument used
twice can run twice, and an argument in an untaken branch does not run.
The macro body itself runs during expansion and can compute with the syntax
values it receives. Executing body code and executing the generated code are
distinct steps.

```gene
(macro add_one [x] (+ x 1))
(add_one 2) # Target: body evaluation produces 3; the expansion is literal 3.

(macro add_one_at_runtime [x] `(+ %x 1))
(add_one_at_runtime 2) # Produces (+ 2 1), which executes at the call site.
```

The first definition is valid even without a backtick. If its argument supplies
a symbol or node rather than a number, arithmetic in the macro body fails under
the ordinary numeric rules. It must not silently insert the unevaluated body
`(+ x 1)` into the caller instead. An error should identify both the macro
invocation and the failing body expression.

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
This describes the generated code, not execution of the macro body itself.
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
   the block declares bindings or owns an `impl`/`import_impl` registration.
   Otherwise, compile it as ordinary sequencing.

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
`^^macro_result`. It lives in the node's props, not its metadata; a boolean
metadata field would use `@@macro_result`. Keep the selected `^^` spelling.
Plain unmarked `do` retains its existing behavior. The earlier `^^create_scope`
idea is not required by this macro contract.

**Marker policy, decided 2026-10-02:** handwritten `do` forms with `macro_result`
true use the same compiler rule. The marker identifies behavior rather than
proving that the node came from the compiler. This avoids a separate provenance
check or a spelling change. Generated results always set the property to true;
the same handwritten behavior must be documented when implemented.

**Value rule (R6), decided 2026-10-02:** only a literal boolean true enables the marker.
An absent property, false, or a non-boolean value is unmarked. Do not apply
truthiness or evaluate an expression stored in this control property. Generated
results overwrite it with true. Document the handwritten form as a general
conditionally scoped `do` when implemented, without claiming it is the
only scope-producing form in Gene.

Determine scope requirements at compile time, accounting for substituted body
arguments and further expansion. Count declarations owned by this block:
`let`, `var`, `const`, destructuring, named declarations, imports that bind
names, and other binding forms already recognized by the compiler. A declaration
in a conditional branch counts if it belongs to this block's ordinary scope.
Bindings inside a nested function or another scoped block belong to that inner
scope. `set` on an existing binding does not create a binding.
Under D7, block-owned `impl` and `import_impl` visibility also require a scope,
even when no ordinary variable is declared.

Build a fresh result node when adding the marker; preserve other props,
metadata, and source locations without mutating shared template or argument syntax. Reuse
an existing outer `do` rather than add a redundant outer block. Nested marked
blocks retain their own scope decisions.

The effect is that declarations introduced by an expansion never add lexical
names to the caller's surrounding scope. This includes caller-supplied names
and declarations inserted through body arguments. Expansions with neither
block-owned bindings nor impl registrations need no additional scope. The
scope decision must not depend on which runtime branch executes.

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

Use the existing backtick, `%`, and `%items...` spellings. Quasiquote in a macro
body follows ordinary Gene evaluation: active unquote expressions produce
values to insert. A reference may resolve to a macro parameter or another
binding available to that execution; it is not limited to signature names.
Compound unquote expressions are valid when the ordinary evaluator accepts them.
The available lexical/module environment is the macro definition's context (D2b).

List elements, node bodies, and nested containers recognize active unquotes
consistently. These repaired B2 examples are executable:

```gene runnable
(macro pair [a b] `[%a %b])
(pair 1 2) # [1 2]

(macro lam [parameter body] `(fn [%parameter] %body))
((lam n (* n 2)) 4) # 8
```

Splicing follows ordinary quasiquote, including its supported sequence positions.
In a node body, a List contributes its elements, a prop map contributes its
properties, and a node contributes its properties and body while dropping its
head. For body-only insertion, bind `($body part)` to a macro-body local and
splice that list. This supersedes
the old template evaluator's body-only node splice behavior; D2a does not retain
a second macro-specific quasiquote evaluator. A spread written in a macro call's
arguments remains syntax, not an eagerly evaluated argument spread.

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
**D6, deferred by the owner on 2026-10-02:** add neither `^fresh` nor a public
fresh-symbol function such as `gene/gensym` in this work. Revisit freshness only
when a concrete application or library use demonstrates a need. Ordinary
macro-body execution would permit a library helper later, without requiring a
template-wide renaming feature now. There is currently only a compiler-internal
gensym counter. Deferral does not supply a capture guarantee or remove the
existing library-collision audit.

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

**Library migration:** the current logger templates retain their explicit task
scope, receiver evaluation count, and message/payload laziness. Removing automatic
renaming exposes ordinary capture: `generated_logger` in supplied message or
payload syntax denotes the logger local. A same-named receiver expression still
uses its outer binding because it is evaluated before the local declaration.
This behavior is covered in `test_logging.nim` and documented in the logging
guide; D6 remains deferred. No collision-free temporary guarantee is claimed.

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

The final line illustrates the required rejection; the review's baseline leaked
this caller-supplied declaration. Inside the expansion, `%name` and
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
lexical lookup. Expansion inserts code into that lexical context, whether the
macro expands during compilation or at runtime. The timing does not turn free
references into dynamic lookup through a call stack or an `eval` overlay.

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

Helpers referenced only by generated code run at runtime, following that
program's ordinary lookup and initialization rules. Those free references do
not capture the macro definition's helper bindings. The executable macro body,
however, does retain its definition-side lexical context under D2b. Compiler
artifacts must distinguish those two uses and preserve the body context across
imports and re-exports. Discovery alone must not execute module initializers;
arranging the environment needed for body execution is separate implementation
work.

Distinguish a free name in generated syntax from a free name executed in the
macro body. D1 governs the former, D2b the latter. `%helper` is an ordinary
expression evaluated in the macro invocation's lexical environment, not a
separate scope-selection operator. The earlier quotation-depth-based caller/
definition lookup proposal is not part of this decision.

## 4. Modules, REPL, and eval

Macros belong to the compile-time environment. Runtime namespaces and values
alone cannot represent their visibility.

Preserve selected imports, wildcards, aliases, renaming, namespace imports,
re-exports, private declarations, and compile-time cycle diagnostics. B7 must
be fixed so an `ns` macro is reachable by its qualified name later in its own
file, under the same visibility rules used by importing code.

**D7, decided 2026-10-02:** an `impl` or `import_impl` owned by a marked block
requires a scope even when it adds no ordinary variable. Its registration or
imported visibility remains local to that block. Code after the expansion
cannot see it merely because the macro executed. A closure created inside the
block retains the implementation context it needs under ordinary closure rules.

Adding an unrelated `let` must not change whether an implementation escapes.
This extends the binding-only scope predicate. It also confines a top-level
macro-generated impl that is visible after the call today; list that migration
beside the loss of declaration export. Existing validity checks on the impl or
import itself still apply.

Do not silently choose the alternative that impls always affect the enclosing
scope merely because lexical bindings can use compile-time-only scopes. Runtime
allocation is an implementation choice; it must preserve the chosen impl
visibility, dispatch, and closure-lifetime rules. Reuse existing scoped-impl
machinery where applicable. Always-outward impl visibility was considered and
is not accepted by this guide.

For B5, a REPL session needs persistent compile-time state alongside its runtime
scope. A successful definition in one input must be available in the next.
Do not leak local macro definitions out of a function, expansion, or inner scope.
**REPL commit policy, decided 2026-10-03:** compiler state commits when an input
compiles successfully. Failed compilation leaves the previous context intact;
a later runtime failure retains the compiled macro definitions, alongside
runtime effects already performed. Retain duplicate/conflict checks. Keeping a
definition does not suppress normal errors when its body or definition-side
initialization later executes.

**D3, decided 2026-10-02:** `eval` compiles against the macro context available
through its selected Env or borrowed CallerEnv, just as ordinary name lookup
uses that environment's bindings. An ordinary `(env)` makes its visible macro
context available to evaluation. A borrowed `caller_env` supplies the caller's
visible macros, not the fexpr definition's macros.

```gene
(macro twice [x] `(+ %x %x))
(eval (quote (twice 3)) ^in (env)) # Target: 6
```

Explicitly isolated environments see only the macros made available through
their configured context. Do not acquire unrelated macros merely because the
same application loaded their module. Implement parents, imports, module
contexts, snapshots, and borrowed lifetimes consistently with the selected
environment's visibility rules. Evaluation-local declarations follow ordinary
Env/REPL persistence rules; carrying macros does not grant a new way to alter
an enclosing compilation unit.

Once a macro is selected, its body still executes in its own definition-side
lexical environment (D2b). Its generated code is compiled within the evaluation
environment, which serves as that expansion's call site (D1).

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
optimization-dependent loss of local-name visibility. The repair makes syntax
calls retain their caller's slot-name metadata; the paired regressions in
`test_vm.nim` cover parameters and locals with and without `(env)`.

Inspect `chunkNeedsCallScopeSlotNames` and scope pooling in the compiler/VM
alongside `materializeCallerEvalParent`, which copies named slots into the
evaluation environment. Track E1 separately from macro-table visibility B6.
Test caller parameters and locals with and without otherwise irrelevant
scope-materializing operations. Do not make that workaround part of D3's API.
E1 is independent of macro semantics and may be fixed immediately; implementing
stage 5's macro visibility support is not a prerequisite.

## 5. Implementation approach

### Shared expansion and normal compilation

Use one semantic expansion implementation for the VM and web frontend. The
current VM calls `expandMacro` during compilation; `expandSourceUnitMacros`
also uses it while building a frontend artifact for other backends. Sharing
that helper does not by itself guarantee matching traversal, scope, or quote
behavior. Align those rules and cover both paths with common fixtures.

Keep syntax-argument matching, macro-body execution, and compilation of the
result as separate steps. Bind arguments as syntax, evaluate the macro body
using ordinary Gene evaluation, mark its result, and compile that result under
the block rule. Preserve source locations and expansion provenance without
adding origin-based lookup or a separate hygiene pass.

The former `macroTemplateValue` shortcut was not a general body evaluator.
Its fallback returned an arbitrary body unchanged instead of executing it.
Reuse the ordinary compiler/VM rather than growing a second evaluator
that recognizes a whitelist of expression shapes. Implement definition-side
macro invocation environments, compilation-budget accounting, and result/artifact
lifetime consistently with D2b. Module-level macros expand during compilation.
Local definitions capture their live lexical environment, and their calls
invoke the body, compile the returned syntax, and execute it when reached at
runtime. Untaken branches must not execute local macro bodies. Each invocation
gets its own captured environment; portable artifacts store code and definition
identities, never a live invocation's captured values.

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
type analysis, capture planning, and tail-call handling. Module-level macro
calls disappear during compilation. Local macro calls pay for body execution
and compilation at runtime, as required by the approved expansion timing.

The current compiler assigns locals numeric slots through `reserveLocal` and
emits indexed loads through `emitLoadBinding`. Outer references can encode a
scope depth and slot. Parameters are reserved before function-body locals.
`compileMacroCall` expands syntax and calls `compileExpr` in the same compiler
context, carrying tail position through. Expanded declarations can therefore
receive ordinary slots; a macro does not inherently require name-based lookup
or invalidate previously assigned variable positions. Runtime local expansions
also leave the enclosing frame's layout intact: generated references use its
existing lexical bindings, and generated declarations live in the result's
own scope. Calls that can generate mutations prevent stale type, capture, and
native-operation assumptions. The static-macro measurements below do not
measure runtime local expansion cost.

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

In the review's baseline, all three functions emitted `opLoadLocalFast` for
slot 0. Only `direct` received
`opReturnBareInt` and the `int_identity` native specialization; `expanded` and
`grouped` used `opReturn` without that specialization. This was evidence of missed
optimization, not a measured runtime slowdown. Inspect `formsKnownBareInt`,
`exprKnownBareInt`, `detectNativeCompileOp`, and their `buildFunctionProto` call
sites. The same review should cover other analyses that examine source forms.
The repaired compiler's regression checks all three functions for the same
typed return proof, native identity specialization, and scopeless eligibility.

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

Inline block slots carry explicit private-slot metadata through the VM and GIR.
Their internal display names do not participate in ordinary name lookup, so a
symbol constructed with `to_sym` cannot capture one or collide with a caller's
binding. Typed declarations currently use a runtime lexical scope because type
annotations can resolve local type values by name.

The compiler may first model a block boundary and eliminate it when safe, or
determine the required boundary during lowering. This implementation choice
does not replace the owner's conditional-scope rule. Reuse existing block,
loop-body, and match-arm machinery where it preserves control flow and slots;
do not assume an empty runtime scope is universally unobservable. D7 defines
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
  Env behavior, and the decided impl/import_impl rule under D7. Existing
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

**Measurement, 2026-10-03:** [the macro benchmark](../benchmarks/bench_macros.nim)
compares each macro with its equivalent handwritten marked result. It compiles
before timing, alternates execution order, discards a warmup, and reports the
median of six samples. A macOS arm64 release build with Nim 2.2.4/ORC and
`GENE_WORKERS=0` produced:

| Workload | Iterations | Macro, ms | Equivalent expansion, ms | Ratio |
| --- | ---: | ---: | ---: | ---: |
| Arithmetic expression | 500,000 | 59.770 | 60.328 | 0.991 |
| Local binding in the caller's frame | 500,000 | 78.396 | 78.563 | 0.998 |
| Closure requiring a runtime lexical scope | 50,000 | 37.480 | 37.346 | 1.004 |

All checksums matched. Runtime was within 1% of the equivalent expansion in
this run on a shared development machine. This measures those three workloads;
it does not establish zero overhead or remove the cost of a required scope.

### Reader and vector normalization

The baseline reader preserved `%` and following forms as flat tokens inside
vectors. Macro expansion, ordinary quasiquote, and match-pattern pins need
unquote nodes. The third consumer matters: `(when %a ...)` matched an earlier
binding, while `[%a b]` failed to do so inside a vector (C6).

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

L3 is now addressed through ordinary evaluation rather than a body whitelist.
An unquoted body executes; an unresolved name fails in the macro execution
environment; an invalid numeric operation fails normally. Reject malformed
Gene code and values the normal compiler cannot compile as an expansion, but
do not reject a body merely because it is not a literal, quote, or quasiquote.

### D2a: ordinary macro-body evaluation — decided

The owner rejected both the required-backtick proposal and the C10 body-shape
whitelist on 2026-10-02. Macro authors may use ordinary Gene code and are
responsible for distinguishing computation from construction of syntax.

| Macro body | Behavior under ordinary evaluation |
| --- | --- |
| Literal such as `7` | Evaluates to that value, which becomes the expansion |
| Parameter such as `x` | Resolves to its bound syntax value |
| `(quote form)` | Produces the quoted syntax |
| Quasiquote | Constructs syntax by evaluating active unquotes |
| `(+ x 1)` or another ordinary expression | Executes normally during expansion; normal resolution/type/operation errors apply |

The implementation reuses ordinary evaluation rules without macro-specific bans
on expression shapes, local names, or computed unquotes. D2b determines lexical
lookup and expansion timing. A macro body reads its definition environment;
access to caller bindings comes through the syntax it emits.

### D2b: definition-side lexical evaluation — decided

Execute a macro body as if it were an ordinary function defined at the macro
definition site. Its parameters and local bindings form the invocation scope;
free references resolve through the definition's enclosing lexical/module
environment. A same-named caller binding does not replace a body helper.
Imports and re-exports retain the original definition context.

```gene
(fn helper [x] (* x 100))
(macro computed [x] (helper x))
(macro emitted [x] `(helper %x))

(fn caller [helper]
  [(computed 2) (emitted 2)])
(caller (fn [x] (+ x 1))) # Target: [200 3]
```

`computed` invokes the definition's helper during expansion and returns `200`.
`emitted` constructs a call whose `helper` resolves to the caller's parameter
when the generated code executes. Quasiquote's active unquote expressions run
in the macro-body environment; the syntax they produce is compiled under D1.

**Local lexical lookup, clarified 2026-10-02:** if a macro is defined inside
`f`, a free `n` evaluated by its body refers to the enclosing `f`'s `n`.
A bare `n` in returned syntax instead resolves where that syntax is compiled.
For example, `(macro m [] n)` reads the definition-side binding, whereas
``(macro m [] `n)`` emits a caller-side reference. Neither lookup may fall back
to an unrelated same-named module binding when a nearer binding exists.

**Local expansion timing, decided 2026-10-03:** a macro defined inside `f`
expands when `f` runs, not while the surrounding source is statically compiled.
Its body reads the lexical environment of that invocation. Each executed macro
call produces syntax that is compiled and executed in the caller's environment;
an earlier invocation's expansion must not be reused with a different `n`.

```gene
(fn f [n]
  (macro m [] (+ n 1))
  (m))
[(f 2) (f 9)] # Target: [3 10]
```

This is a runtime expansion of a local macro, with the same result-scope and
caller-control-flow contract as other macros. It is not `eval`'s binding-copy
boundary. A template that emits a bare `n` still reads the caller's binding.
Module-level macros retain their separate compile-time definition instances.
The VM implements this through ordinary captured macro-body functions and
runtime compilation of the result. Generated code enters the actual caller
scope without an eval overlay or an additional function boundary.

Because returned syntax may access or mutate any caller binding, a task that
invokes a runtime local macro stays on its owner lane. Its complete capture set
is not known when a worker snapshot would be created. This preserves ordinary
task execution and suspension without claiming that such a call is Send-safe.

A macro body that constructs syntax with quasiquote and one that calls helpers
use the same evaluation and scoping rules. "Template" and "computed" describe
body implementations, not distinct semantic categories. Compilers may cache
compiled bodies and source-context preparation, but must evaluate each
invocation with its own syntax arguments and definition environment; expansion
results and live captured bindings are not cached.

**Phase initialization, approved 2026-10-02:** when expansion needs definition-
side bindings, initialize the defining module on demand in a separate compile-
time instance. Ordinary helpers and computed top-level bindings are available
there. Top-level effects may consequently occur during compilation as well as
in the independent runtime module instance. Discovery alone executes no module
initializers. Reuse the compile-time instance within its compilation context,
preserve definition identity across imports, and diagnose initialization cycles.

Artifact loading preserves portable definition identities and context, while
live invocations retain their environments through ordinary closure ownership.
Do not fall back to the caller's runtime environment when a definition-side
helper is unavailable. Existing mixed parent-scope/closure cycle limits also
apply to saved local macro environments; see the
[development guide](development.md#status).

### Unquote shared with pins and computed paths

The R1 baseline let an unknown active unquote fall through to a plain symbol,
changing a match pin into a binder or a computed path into a static key. The
probes returned `true` instead of `false` and `99` instead of `1`.
Ordinary evaluation and normal unresolved-name errors replace that fallback.

Quotation depth and the consumer of a surviving unquote node still matter.
Local code constructed inside a quasiquote is not executed merely by constructing
it; its names do not automatically become bindings for active unquotes evaluated
while building that syntax. Conversely, macro-body locals may be available to
ordinary unquote evaluation under the macro execution environment.

Preserve `%items...` splicing, inserted argument syntax, and ordinary quote/
quasiquote nesting. Construct a literal unquote for a later pin or computed
path with ordinary quote:

```gene runnable
(var data {^a 1 ^key 99})
(macro pick [k]
  `(do (let key %k) (path data %(quote (unquote key)))))
(pick "a") # 1
```

The active unquote inserts the syntax `(unquote key)` without evaluating `key`.
The generated path then reads its local `key` at the call site. The same
construction works in match patterns, and argument syntax can already contain
pins or computed paths without any additional escaping.

At a single quasiquote depth, `%%a` evaluates `(unquote a)` as ordinary body
code; there is no special residual-unquote escape. Without a callable binding
for `unquote`, it fails normally. The legacy evaluator's partial support for
this spelling is replaced by D2a. Nested quasiquotes still use their ordinary
depth rules, including macro-generating templates. No percent-count-based
scope selection or new syntax is introduced.

Keep formatting round trips valid and make `gene doc` list macro declarations
using compiler metadata. Macros should remain absent from runtime reflection
APIs whose contract is to expose runtime values.

### Source map for implementers

Use symbol names to locate code; line numbers will move during repair.

| File | Relevant implementation |
| --- | --- |
| [compiler.nim](../src/gene/compiler.nim) | `macroParamDef`, `evaluateMacroValue`, `expandMacro`, `markMacroResult`, `compileMacroResult`, `compileMacro`, `expandMacroTree`, `expandSourceUnitMacros` |
| [compiler.nim](../src/gene/compiler.nim) | `patternBindingNames`, `collectPatternBindingNames`, ordinary declaration/body compilers, `compileNs`, `importMacro`, `builtinNamespaceMacros`, `compileQuasiTemplate`, `compileQuasiList` |
| [reader.nim](../src/gene/reader.nim) | `parseForm` handling of `%` with `inList`, vector parsing, quotation and source locations |
| [gir.nim](../src/gene/gir.nim) | `MacroDef`, macro parameters/defaults, portable module artifacts |
| [vm.nim](../src/gene/vm.nim) | `runReplSession`, eval environment materialization, module compilation and macro artifact loading |
| [macro_runtime.nim](../src/gene/macro_runtime.nim) | Separate compile-time Application, on-demand definition module initialization, and macro-body invocation |
| [gir_codec.nim](../src/gene/gir_codec.nim) | Deterministic graph encoding of macro definitions and shared definition contexts; explicit private-slot metadata and structural encoding for constructed symbols without a faithful reader spelling |
| [web.nim](../src/gene/web.nim), [web_backend.nim](../src/gene/web_backend.nim) | Public web compiler initialization, consumption of expanded frontend artifacts, and web-profile validation |

## 6. Repair sequence and acceptance criteria

Each implementation change should include the failing regression that motivates
it and preserve existing working cases. Update current guides/specs when a
target guarantee becomes implemented; this design document alone does not
change the supported language contract.

| Stage | Work | Acceptance |
| --- | --- | --- |
| 1a. Shared syntax normalization | B2, C6/R7, and quotation-depth coverage | Vector unquote/splice and pattern pins work through shared normalization; `%xs...` has the canonical splice shape; unrelated tokens retain their meaning |
| 1b. Macro-body execution | D2a with definition-side lexical lookup (D2b) | Execute ordinary body code with syntax arguments; retain the definition context across imports; compile the result at the call site; use normal resolution/type errors; no unquote-to-symbol fallback |
| 2a. Marked results and binding visibility | D5, D8/R3, and replacement of the partial renaming behind B1, B3, B4 | Preserve pipeline-slot recognition before executable marking; align supported positions across backends; scope-aware duplicate checks and distinct same-frame slots where valid; declarations stay local; audit built-in temporary collisions |
| 2b. Runtime-visible scope state | D7 and R2/R4 capture, Env, and impl requirements | Local impl visibility is independent of unrelated bindings; escaped closures retain required state; return/loop targets and tail calls survive runtime scope management; unsupported cases cannot silently leak |
| 3. Ordinary integration | B5, B7, declaration validation and useful diagnostics | Multi-input REPL persistence, same-file qualified calls, and imports behave consistently |
| 4. Call-site lookup contract | L1 and the decided D1 rule | Local and imported macros resolve free helpers at the call site; aliases/re-exports add no hidden definition context; absent dependencies produce useful errors |
| 5. Eval context | B6 under the decided D3 rule | Env evaluation sees its selected macro context; caller_env uses the caller's context; isolated environments do not gain ambient macros; existing control-flow and mutation boundaries remain intact; account for E1 independently |
| 6. Optimization, tooling, and profile coverage | O1, macro docs, formatting, VM/web fixtures | Equivalent expanded code retains eligible optimizations; tools describe supported macros and the web backend diagnoses unsupported cases explicitly |

Diagnostics may land alongside any stage. Implement L3 according to ordinary
body evaluation, integrating the D2b environment and R1's quotation behavior
before stage 1b.
E1 can be diagnosed and fixed independently at any time. Stages 2a and 2b are
separate implementation workstreams, not permission to ship different scope
semantics for unsupported cases. Keep definition-before-use, explicit caller
names within expansion scopes, and documented backend limits unless separately changed.
Migrate uses and tests that currently rely on declaration export as part of D5,
and update the public guides/specs and change log in the same implementation
change. Ordinary macro-body execution is now part of the work; no separate
macro expression whitelist is required.

The web profile supports module-level macro expansion. Local macro definitions,
including definitions produced by an expansion, require the compiler at runtime
and are outside the web profile (L5). Diagnose these explicitly; do not expand
them statically even when their body appears independent of runtime values.
Do not silently accept different binding semantics for forms admitted by both
backends. For excluded forms, give a profile-specific error; expanding web
coverage can be scheduled separately.

The web emitter currently keeps declarations made inside conditional branches
in JavaScript branch storage. Reading such a declaration later in the enclosing
sequence is outside the web profile. Diagnose that read, including when a
same-named caller binding exists; falling back to that caller binding would
silently change the expanded program. Uses within the declaring branch and the
macro result's confinement remain supported.

## 7. Regression coverage

Verification checkpoint, 2026-10-03: the full regression suite passed 1,630
tests, executable specifications passed 826, shared VM/web fixtures passed
313 cases per backend, and ownership checks passed 86. Subsequent budget and
REPL changes passed the full 386-test VM suite. Worker checks passed 47 tests
across the full and corrected focused runs, including nested runtime-macro
capture handling. The final WebAssembly build passed 46 ABI cases, and emitted
web fixtures passed TypeScript 5.9.2 checking. These checks cover the contracts
below; they do not remove the documented backend and general lifetime limits.

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
| D5/D7 conditional scopes | No declarations or impl registrations means no extra scope; direct, conditional, destructured, imported, and argument-supplied declarations are counted in their owning block; nested scopes own their declarations; set alone adds no scope; impl/import_impl alone requires scope |
| D5 scoped declarations | `with_value` returns `84`; its name is absent afterward or leaves a same-named outer binding intact; declarations spliced through body arguments also stay local; nested and repeated expansions obey ordinary scopes; returned closures retain needed locals; declaration-export examples are rejected outside their expansion |
| D7 impl visibility | Impl-only, impl-plus-local, and import_impl results remain local; dispatch after the expansion cannot use those registrations; a returned closure retains its local impl context; 300,000-deep tail recursion through marked blocks containing locals and containing an impl completes |
| Body access | Caller-supplied names and body references connect normally; fixed template names are accessible to supplied bodies according to ordinary lexical visibility |
| B5 and B7 visibility | Separate REPL inputs; failed-input state handling; local-scope isolation; same-file namespace call; selected, wildcard, alias, renamed, private, and re-exported imports |
| D4 lexical shadowing | Inner parameters/locals hide outer macros in call and value positions; the outer macro is visible again outside that scope; non-callable inner values raise normal errors with no macro fallback; same-scope duplicates and imported names follow ordinary rules |
| L1 call-site context | A caller helper determines the result even when the defining module has a same-named helper; absent caller helpers fail; private helpers are not implicitly exposed; free helper macros require call-site visibility; aliases/re-exports retain these rules |
| B6/D3 evaluation | `(eval (quote (twice 3)) ^in (env))` gives `6` when twice is visible; fexpr eval sees caller macros rather than definition-side macros; isolated environments see only configured macros; selected macros retain D2b body lookup; eval-local declarations follow environment lifetime; caller control-flow targets remain rejected |
| E1 caller locals | Fexpr eval can see caller parameters/locals consistently with and without an unused `(env)`; preserve the existing eval-copy and borrowed-lifetime boundaries |
| D2a/L3 execution and diagnostics | Unquoted `(+ x 1)` succeeds for a numeric syntax argument and fails normally for a nonnumeric one; valid body calls, local bindings, sequencing, and computed unquotes execute; malformed code, invalid operations, unresolved names, signature errors, and recursion/budget failures retain expansion provenance |
| D2b lexical lookup | Definition helper wins over a same-named caller helper when executing the macro body; emitted helper calls use call-site lookup; parameters/body locals follow ordinary shadowing; imports/re-exports and private definition helpers preserve body context |
| D2b local timing | Repeated function invocations read their own captured values; skipped branches execute no macro body; body suspension works; generated mutation/return/loop exits affect the caller; saved Env contexts retain local definitions; pipeline operands are classified after expansion and each result confines its declarations; artifact cloning preserves definition identities |
| R1 unquote overlap | Pin/path examples cannot silently yield `true`/`99`; unquote evaluation uses its defined environment and reports unresolved names normally; supplied syntax retains its unquote nodes; test literal-unquote construction and distinguish current caller-bound `%%a` from renamed locals |
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

## 8. Decision record and implementation follow-ups

D1, D2a, D2b's lexical lookup, D3, D4, D5, D7, and D8, together with ordinary
binding of generated code, are decided. Definition-side execution and ordinary
quotation apply consistently across static and runtime expansion.
D6 is explicitly deferred until a concrete need is demonstrated.
The numbered decisions are settled or explicitly deferred. Local macros expand
when their enclosing function runs; REPL macro definitions commit after
successful compilation, including when execution then fails. E1 remains
independent of these decisions. Record each chosen rule here and in the relevant
implemented spec when it lands.

| Decision | Rule or recommendation | Status and implementation concerns |
| --- | --- | --- |
| D1: Free template references | Use ordinary lexical/module lookup in the expanded code | Decided 2026-10-02. No automatic hygiene or origin-based lookup; ordinary shadowing applies; document dependencies on caller-visible helpers |
| D2a: Macro-body execution | Evaluate ordinary Gene code to produce the expansion; backtick is optional | Decided 2026-10-02. No body-shape whitelist or parameter-only unquote restriction. Invalid code/operations fail normally; the C10 grammar and mandatory-template proposal are withdrawn |
| D2b: Macro execution environment | Use the macro definition's lexical/module environment, like an ordinary function | Decided 2026-10-02; local timing decided 2026-10-03. Module macros use a separate compile-time module instance initialized on demand; discovery remains non-executing. Local macros expand when their call executes, using that definition's live captured environment. Preserve identity/lifetime through imports and artifacts; D1 governs generated-code free names |
| D3: Eval compile-time context | Use the macros available through the selected Env or CallerEnv | Decided 2026-10-02. Ordinary env includes its visible macro context; caller_env supplies caller macros; isolated environments expose only their configured context. Preserve existing eval control-flow, mutation, and lifetime boundaries; E1 is an independent bug |
| D4: Macro/value shadowing | Ordinary lexical lookup: the nearest binding determines macro expansion versus ordinary use | Decided 2026-10-02. Inner bindings may hide macros; no fallback to a hidden macro when an inner value is not callable. Same-scope duplicates, imports, and REPL redefinition follow ordinary binding rules |
| D5: Marked results and local declarations | Wrap a non-do executable result in `(do ^^macro_result <result>)`, or set the boolean property on an existing do; create a scope for bindings or impl registrations | Core and marker policy decided 2026-10-02. Classify position/slots before wrapping. Handwritten forms behave identically; only literal true enables the rule, and absent/false/non-boolean is unmarked. D7 specifies registration visibility |
| D6: Explicit fresh names | Defer both `^fresh` and a public fresh-symbol helper until a concrete need arises | Deferred by the owner 2026-10-02. No new freshness API in this work; ordinary shadowing remains. Revisit if an application/library demonstrates the need; the existing collision audit still applies |
| D7: Scope-sensitive registrations | Block-owned impl/import_impl require local scope even without variables | Decided 2026-10-02. Registrations are visible inside the marked block, not afterward; returned closures retain their implementation context. Adding an unrelated local changes nothing; top-level impl-producing macros require migration |
| D8: Supported expansion positions | Expression positions plus existing direct pipeline-slot substitution; no clause-position macros | Decided 2026-10-02. VM/web must share syntax-role traversal and reject unsupported positions consistently; preserve expression macros inside valid clauses and allow a macro to generate an entire enclosing expression |

The owner-approved direction is ordinary macro-body evaluation followed by
compilation of the result, with explicit expansion-scope rules. Remaining
semantic choices must remain explicit during that
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
| C10 | A proposed template-result whitelist, subsequently rejected by the owner under D2a |
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

These changes compare the review's baseline with the selected contract. The
implementation checkpoint above records the supported behavior; an installed binary
may predate these changes.

| Case | Review baseline | Selected behavior |
| --- | --- | --- |
| Template local with the same name as an argument's variable, e.g. `(swap tmp y)` or `(add_one tmp)` | Protected for `do`-level binders: `[2 1]`, `101` | Ordinary shadowing: `swap` fails or leaves values unswapped, `add_one` gives `2` |
| Macro expanding to `fn`, `type`, or `let` with a caller-supplied name | Name usable after the call | Name confined to the expansion (D5) |
| Macro expanding to an `impl` at top level | Impl visible after the call | Impl confined to the expansion (D7) |
| Macro call in a clause position, e.g. generating `else` or `when` | VM: `nil` or unknown-clause error; web: expands | Rejected on both backends (D8) |
| Inner parameter or local sharing an outer macro's name | Locally defined macros can cause a conflict error; imported macros behave inconsistently | Ordinary lexical shadowing selects the inner binding; the outer macro remains available outside that scope (D4) |
| Quoted data `(quote [%x])` | `[% x]`, two flat tokens | A vector containing an unquote node (stage 1) |
| Macro body without a backtick, such as `(+ x 1)` | Inserted as ordinary caller code | Evaluated during expansion; valid computation succeeds and invalid operations fail normally (D2a) |
| Active unquote such as `%name` or `%(expr)` | Limited template substitution, with a silent fallback for other operands | Ordinary expression evaluation in the definition-side macro invocation environment (D2b); unresolved names and invalid operations fail there; quotation-depth behavior still applies |
| Single-depth `%%name` used to emit a residual pin/path unquote | Partial implicit support in the template evaluator | Ordinary evaluation of `(unquote name)`; use `%(quote (unquote name))` to insert that syntax literally |
| A node spliced into a template's node body | Contributes its body, dropping its head and properties | Ordinary quasiquote contributes its properties and body, dropping its head; explicitly splice `$body` for body-only insertion |
| Log macro argument that mentions `generated_logger` | Caller's binding | Message/payload syntax captures the logger local; receiver syntax keeps its ordinary pre-declaration lookup |
