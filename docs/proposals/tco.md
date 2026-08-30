# Proper tail calls

A design for Gene.

The goal is to make tail-recursive functions and messages a reliable iteration
tool without changing return adaptation, checked-error, scope, construction, or
cleanup semantics. The compiler identifies tail position; the VM routes every
bytecode call through one call-entry module that either replaces the current
activation or preserves it when observable work remains.

The guarantee is intentionally precise:

> A chain of calls in tail position runs in constant VM frame space when every
> exited activation is **tail-elidable**. An activation is tail-elidable when it
> has no observable post-call continuation: no return adaptation, checked-error
> boundary, implementation validation, structured completion, capability
> restoration, or caller-owned pooled scope captured by the callee.

Calls that do not meet that condition remain correct normal calls. The proposal
does not hide an arbitrary continuation chain in `FrameExtra` and call that
constant space.

This keeps the useful direction of the original design—static tail marks,
general frame replacement, match-arm support, sends, and bounded diagnostics—
while matching the continuation and scope ownership that the VM actually has.

---

## 1. Current state, measured

Gene already has three partial mechanisms, but they do not add up to a language
contract. Exploratory probes (`tmp/probe*.gene`, measured with
`/usr/bin/time -l`, Apple Silicon, 2026-08-29) produced:

| shape | depth | peak RSS | verdict |
|---|---:|---:|---|
| self tail call in an `if` arm | 20M | **10.7 MB** | O(1), through a narrow compiler peephole |
| the same function called through a wrapper | 20M | 10.7 MB | O(1), still the same peephole |
| mutual recursion through `if` arms | 20M | **12.5 GB** | pushes about 600 B per level |
| self tail call in a `match` arm | 20M | **15.2 GB** | pushes about 760 B per level |
| tail call through a function value | 200k | 321 MB | pushes about 1.5 KB per level |
| tail send on a type instance | 200k | 220 MB | pushes about 1 KB per level |
| baseline without recursion | — | about 10 MB | — |

Three implementation facts explain the measurements:

1. **Gene call frames are explicit heap records.** Deep non-tail recursion does
   not normally overflow the Nim stack; `frames: seq[Frame]` grows until memory
   pressure ends the process. The failure mode is therefore large silent memory
   consumption rather than a prompt stack-overflow diagnostic.
2. **The one constant-space shape is a compiler peephole.**
   `rewriteSelfRecursiveCalls` emits `opRecur1` and, for a still narrower unary
   integer shape, a fused same-scope restart. The rewrite excludes chunks with
   matches, loops, try regions, and other subchunks. It cannot cover mutual
   recursion, function values, or sends.
3. **A real replacement path already exists but is nearly unreachable.**
   `canReplaceCurrentTailCall` and `enterTailCallFrame` can overwrite the active
   registers with a bytecode callee. Current call sites require the next opcode
   to be a literal return, require operands at the bottom of the shared stack,
   and reject activations with return/error/finalization state. A call in an
   `if` or `match` arm normally fails the dynamic next-op test even when the
   compiler can prove it is in tail position.

The missing pieces are a static position proof, one call-entry seam shared by
all bytecode call paths, and an exact treatment of expression subframes such as
`match` arms.

The measurements above are motivation, not durable acceptance tests. Section 6
replaces RSS-only probes with direct frame and allocation instrumentation.

---

## 2. Language contract

### 2.1 Terms

This proposal uses four distinct terms:

- **Tail position** is a compiler property: the expression's value is returned
  directly by its enclosing function or message.
- A **post-call continuation** is observable work the activation must perform
  after the callee finishes: adapting a return value, checking `^errors`,
  validating required implementations, running cleanup, restoring authority,
  constructing a namespace, or validating a constructed instance.
- A **tail-elidable activation** is a normal function/message activation with
  no post-call continuation and no pooled scope that the callee still needs.
- A **proper tail transfer** is the VM operation that replaces a
  tail-elidable activation with its bytecode callee instead of pushing a frame.

The compiler mark is necessary but not sufficient. Runtime call resolution and
active-frame state determine whether the marked call becomes a proper tail
transfer. The fallback is an ordinary call with unchanged semantics.

### 2.2 Tail positions

Tail position begins at the last expression of a `fn` or message body and
flows through forms whose selected result is also the enclosing result:

| form | positions receiving the enclosing tail context |
|---|---|
| `(if c (then ...) (elif ...) (else ...))` | last expression of every real branch |
| `(if c a b)` | `a` and `b` |
| `(if_yes c body...)` / `(if_not c body...)` | last body expression |
| `(match target (when pattern body...) (else body...))` | last expression of every arm body |
| `(do body...)` | last body expression |
| `(&& a b ...)`, `(\|\| a b ...)`, `(?? a b ...)` | last operand only |
| `(return expr)` | `expr`, subject to the same runtime eligibility rules |

For a multi-form body, only the last form inherits the body's tail context.
Earlier forms are statement position and their results are discarded.

A nested `fn`, message, or fexpr opens a new compiler context; it does not
inherit tail position from the declaration site.

### 2.3 Positions deliberately excluded in v1

There are two reasons a position is excluded.

Some expressions are not the enclosing callable's result position:

- call arguments, conditions, match targets/patterns, and binding or assignment
  initializers;
- loop bodies (`while`, `for`, `loop`, `repeat`), because the loop form owns
  iteration and result semantics;
- `ctor`, `ns`, and `mod` bodies;
- `new` construction and fexpr invocation.

Constructor, namespace, and module completion are observably different from
returning the raw last body value:

- A namespace body completes as `fkNamespaceBody`: its raw body value is
  ignored, a namespace is created and defined, and that namespace is returned.
- A constructor body result is ignored; `new` must validate and publish the
  pre-created `self` after the constructor returns.
- Module/scope completion may validate required protocol implementations and
  publish state.

Other positions are excluded in v1 because their current frames own structured
runtime state:

- `try`, `catch`, and `ensure` bodies;
- `with_capabilities`, task-scope, supervisor, and `spawn` bodies.

Those frames own handlers, cleanup, authority, or child lifetime that must
survive the call. A later design may make one of these positions tail-elidable
by representing its finalizer as a specific bounded continuation. It must not
do so by silently dropping the work or by accumulating an unbounded finalizer
chain.

The dynamic-context cost must also be stated accurately. A helper called once
from inside a `try` may recurse in constant space after one protected frame. A
function that enters a `try` on every recursive iteration still grows one frame
per iteration:

```gene
(fn loop [n]
  (try
    (if (== n 0) 0 (loop (- n 1)))
    catch SomeException ($println $ex/message)))
```

Here `catch` is followed by an exception type, and the caught exception is
available through `$ex`.

### 2.4 Runtime eligibility and exact fallback

After resolving and binding a marked bytecode call, the VM may replace the
current activation only when all of these facts hold:

- the active activation is a plain `fkNormal` function/message frame;
- it has no pending cleanup, handler, loop, task, namespace, construction, or
  capability-restoration state;
- `validateImplRequirements` is false;
- `returnType` is `NIL`, `returnLabel` is empty, and `checksErrors` is false;
- `returnDepth == frames.len`, so the current normal activation owns this
  physical frame depth;
- the call operands are the only live values in the current expression-frame
  stack region;
- the callee introduces no capability transition that must later be restored;
- replacing a recyclable call scope cannot invalidate a scope captured by the
  callee.

The callee may install its own return, error, or implementation-validation
state. That state belongs to the callee and is preserved normally. It may make
the callee ineligible for a subsequent replacement.

This gives exact, bounded behavior:

- an untyped mutual-recursive chain can remain at one physical frame;
- a compiler-proven bare-`Int` return can remain eligible because
  `checkedFrameReturnType` already removes the redundant dynamic boundary;
- a genuinely adapting return type, `^errors` boundary, or required-impl check
  keeps one frame per invocation rather than losing semantics or building an
  equivalent heap list elsewhere.

The current redundant-boundary proof is much narrower than the typed Gene
surface: it recognizes compiler-proven bare `Int` results. A corpus scan of
`examples/` and `tests/` found declared return types on about 52% of `fn`
definitions and 49% of message definitions, while only about 7% of declared
returns are `Int`. Generalizing safe result-shape proofs is therefore a
first-class implementation stage, not an optional polish item. Section 3.6
defines the limit: remove only a boundary proven to be behaviorally redundant.

The fallback is not an error and does not need language syntax. It is visible
to tests through counters and to developers through an opt-in
`--report_tail_fallbacks` diagnostic. The diagnostic reports each marked call
site at most once, with a reason such as `return_type`, `checked_errors`,
`impl_validation`, `structured_frame`, `capability_restore`, `captured_scope`,
or `operand_region`; it is disabled by default so ordinary call paths pay no
diagnostic bookkeeping cost.

### 2.5 Call kinds covered

The proper-transfer path covers every user call that resolves to an ordinary
bytecode `Fn` while executing a call opcode:

- direct, local, outer, parent, name, value, and splice calls;
- bare, qualified, optional, and `super` sends after message resolution;
- application of a bound protocol message;
- a user-defined `Callable`, after resolving `Callable/apply` and building its
  `Call` envelope.

Native functions, FFI callables, selectors, enum variants, direct typed-data
construction, and generators return without pushing a Gene bytecode frame.
They already have constant Gene-frame cost for the call itself; a tail mark does
not turn external Nim callbacks into part of the Gene continuation contract.

### 2.6 Executable examples

The examples use the current Gene surface and are intended to become spec
fixtures.

```gene
(fn is_even [n]
  (if (== n 0) true (is_odd (- n 1))))

(fn is_odd [n]
  (if (== n 0) false (is_even (- n 1))))
```

The final calls are mutual proper tail transfers when the functions are plain.

```gene
(fn fold [f acc xs]
  (match xs
    (when [] acc)
    (when [head tail...] (fold f (f acc head) tail))))
```

The call through `f` is an argument and is not in tail position. The recursive
`fold` call is in the selected match arm's tail position.

```gene
(type Box ^props {^n Int}
  (ctor [n] (self ~ set_prop `n n))
  (message down []
    (if (== self/n 0)
      0
      ((new Box (- self/n 1)) ~ down))))
```

`new` is ordinary construction; the final `down` send is a tail send. The
message is intentionally unannotated so that the example demonstrates the v1
constant-frame guarantee rather than the typed-return fallback.

---

## 3. Design

The VM already uses an explicit frame stack, so no CPS conversion or new
trampoline is required. The design adds one compiler proof and deepens the
existing call-entry module: call opcodes resolve and bind their targets, then a
single internal interface owns the replace-versus-push decision.

### 3.1 Compiler: tail-position analysis

Thread a tail flag through expression and body compilation:

```nim
proc compileExpr(c: var Compiler, node: Value, tail = false)
proc compileBody(c: var Compiler, body: openArray[Value], tail = false)
proc compileBodyFrom(c: var Compiler, body: openArray[Value], first: int,
                     tail = false)
```

Rules:

- `compileBody` and `compileBodyFrom` pass their `tail` value only to the last
  form; every earlier form receives `false`.
- `if`, `if_yes`, `if_not`, `match`, `do`, and the last operand of
  `&&`/`||`/`??` propagate the flag according to section 2.2.
- `return` passes the flag to its expression only when it is compiling a direct
  function return, not a return whose structured cleanup owns a continuation.
- conditions, patterns, arguments, initializers, loops, structured bodies,
  constructors, namespaces, modules, and quoted material pass `false`.
- nested callables begin their own tail context at their body tail.
- macro expansions go through the same compiler and require no separate rule.

Every call-emitting post-pass must preserve the mark. In particular,
`rewriteSelfRecursiveCalls`, direct-call specialization, bare-return rewrites,
and scopeless-call specialization may replace an instruction only by copying
its tail property or by emitting a stronger in-place recur opcode.

### 3.2 GIR: carry the proof without assuming one host layout

Add a distinct `tail` bit to call instructions. The existing `flag` field is
opcode-specific and cannot be reused.

```nim
Instruction* = object
  op*: OpCode
  intArg*: int
  depth*: int
  name*: string
  names*: seq[string]
  flag*: bool
  tail*: bool
```

On arm64 the additional bit is padding-neutral: `Instruction` remains 64 bytes
because the bit occupies padding after `flag`. The size rule is nevertheless
target-relative, not `sizeof(Instruction) == 64` everywhere. Tests define a
mirror of the pre-tail layout and assert on every supported target that adding
the bit does not increase `sizeof(Instruction)`; native and wasm builds both run
the check. V1 has one representation of the proof. If a supported target fails
the layout check, stop and revisit the field layout before merge rather than
adding a second chunk-side representation.

`MatchProto` gains `tailResult: bool`, which records that the selected arm's
result is the enclosing activation's result.

Both fields change serialized GIR. Increment `GirArtifactFormat` from 2 to 3;
format-2 artifacts fail closed rather than relying on an absent JSON field to
default correctly. Round-trip tests cover marked/unmarked calls and matches.

The mark belongs on the opcode that actually invokes the resolved callee.
Message resolver/cache opcodes are not themselves tail calls.

### 3.3 VM seam: one deep bytecode-call entry module

All paths that have resolved and bound an ordinary bytecode function use one
internal interface, conceptually:

```nim
type BoundBytecodeCall = object
  # stack-local description produced by existing specialized binders
  proto: FunctionProto
  scope: Scope
  recycleScope: bool
  validateImpls: bool
  returnType: Value
  returnLabel: string
  checksErrors: bool
  errorTypes: seq[Value]
  fnName: string
  capabilityTransition: CapabilityTransition

template enterBytecodeCall(call: sink BoundBytecodeCall,
                           operandBase: int,
                           tailMarked: bool)
```

This is an implementation interface, not a required allocation. It should be a
stack object/template that lets the current simple, Int, scopeless, and named
binders keep their allocation behavior. The interface earns its depth by
hiding all of the following from opcode arms:

- compiler-mark validation and operand-region assertions;
- transparent expression-frame collapse;
- capability and scope-capture checks;
- current-activation replacement;
- ordinary frame push fallback;
- installation of the callee's return/error/validation state;
- bounded tail-trace recording.

Opcode arms retain only call-kind resolution and their specialized argument
binding. No call arm independently reimplements the replacement guard.

The required opcode inventory is explicit:

- `opCall0/1/2/opCall/opCallSplice`;
- `opCallName0/1/N`, local, parent-local, and outer-local families;
- scopeless/direct fast paths;
- final call operations emitted by bare, optional, qualified, and `super`
  sends;
- bound protocol-message application and user `Callable/apply` resolution.

Each adapter documents its operand region. Direct/name ops that do not place a
callee value on the stack still pass the first argument/operand index as
`operandBase`. For a marked call, `operandBase == curStackBase` is a
release-build guard evaluated before any truncation or transparent-frame
collapse. Failure takes the ordinary push path and can report
`operand_region`; it never truncates speculatively. Debug builds additionally
assert the opcode-specific stack shape so an adapter bug fails near its source.
Stage 2 also runs marked-versus-unmarked differential tests across all opcode
families, because an adapter can still compute a plausible but wrong base.

### 3.4 Replacement eligibility

After arguments have been bound into a callee scope, the call-entry module may
discard the operand region. Binding must happen first: match-arm collapse also
truncates that region.

The centralized predicate is conservative:

```nim
template currentActivationIsTailElidable(calleeScope: Scope,
                                         transition: CapabilityTransition): bool =
  curFrameKind == fkNormal and
  returnDepth == frames.len and
  not validateImplRequirements and
  returnType.kind == vkNil and returnLabel.len == 0 and
  not curChecksErrors and
  curEnsureBody == nil and curForItems.len == 0 and
  curForStream.kind != vkStream and curOwnedScope == nil and
  curPendingError == nil and curPendingPanic == nil and
  curPendingCancel == nil and curPendingReturn == nil and
  transition.context == capabilityContext and
  transition.presence == capabilityPresence and
  (not recycleScope or not scopeChainContains(calleeScope, scope))
```

The actual implementation also checks the marked opcode's operand layout and
the transparent-frame chain described below.

What changes from the current gate:

- the compiler mark replaces the dynamic “next opcode is return” test;
- `operandBase == curStackBase` replaces the outermost-stack-only check;
- `returnDepth == frames.len` makes the physical-activation identity explicit;
- required-implementation validation remains a hard gate;
- return adaptation and `^errors` remain hard gates in v1;
- capability restoration and pooled-scope capture remain hard gates;
- the callee's own state is installed after the old activation is released.

This consolidation is also slightly stricter than the current template.
`returnLabel.len == 0` is a defensive invariant even when `returnType` is
`NIL`, and capability-transition equality moves an existing call-site guard
inside the shared module so no adapter can omit it.

`enterTailCallFrame` then keeps the current physical caller depth, appends one
bounded diagnostic record, releases the current call scope, truncates to
`curStackBase`, and installs the bound callee registers. The callee returns
directly to the replaced activation's caller.

### 3.5 Match arms: transparent current activations, not dead saved parents

`opMatch` pushes the parent activation and runs the selected arm as the current
register-owned activation. Therefore a flag on `frames[^1]` describes the saved
parent, not the arm. Releasing that saved frame and then loading it would
recycle the parent's scope rather than release the arm's scope.

Use a dedicated current-frame kind instead:

```nim
FrameKind = enum
  fkNormal
  fkTailMatchBody
  # existing structured kinds...
```

When `MatchProto.tailResult` is true, `opMatch` enters the selected arm as
`fkTailMatchBody`. This kind means: “if the arm ends in a marked call, the
arm-to-owner result handoff is transparent.” It is stored automatically when a
nested match pushes the current arm into `frames`, so nested tail-position
matches form a chain without another `Frame` field. This relies explicitly on
`Frame.kind` round-tripping through `pushFrame` and `loadFrameRegs`; any future
frame save/restore refactor must preserve that interface.

Transparent match bodies are expression frames. They inherit their enclosing
function's `returnDepth` and never assign a new one. That is why restoring each
saved owner through `loadFrameRegs` eventually re-establishes
`returnDepth == frames.len` for the owning normal activation.

After the callee is resolved and its arguments are bound, the call-entry module
performs a release-build preflight over the entire transparent chain. It checks
the frame kinds, saved-owner availability, empty operand regions, inherited
`returnDepth`, and scope-capture safety before releasing anything. Failure
takes the ordinary call path from the still-current arm.

The current `opMatch` implementation creates every arm with `newScope(scope)`,
so arm scopes are not pooled and `recycleScope` is false. If arm pooling is
introduced later, preflight must apply the capture check to every arm scope;
no recyclable arm may be collapsed when the bound callee scope contains it.

After successful preflight, collapse proceeds in ownership order:

```nim
template collapseTailExpressionFrames(calleeScope: Scope) =
  while curFrameKind == fkTailMatchBody:
    # The arm is current; release/drop it before restoring its saved owner.
    doAssert not recycleScope or
      not scopeChainContains(calleeScope, scope)
    releaseCurrentCallScope()
    strunc(curStackBase)
    doAssert frames.len > 0
    var owner = frames.pop()
    loadFrameRegs(owner)
```

For today's non-pooled branch scope, replacing the current `scope` reference
drops the arm's ownership normally and `releaseCurrentCallScope()` is a no-op.
The saved owner's scope is never released by this loop. If a future pooled arm
passes preflight, `releaseCurrentCallScope()` may recycle it only after the
per-arm capture check succeeds.

`loadFrameRegs` moves managed fields out of `owner`; the loop must discard that
local immediately and must not inspect it after the load. This is part of the
ORC ownership contract, not merely a pseudocode detail. The ownership suite
runs this path under ORC with nested arms and early scope release.

After collapse:

- if the restored function activation is tail-elidable, replace it;
- otherwise push the bound callee normally from the restored function.

The second case is important. It removes expression-only match frames while
retaining a function frame that must still adapt the value, check an error row,
or validate implementations when the callee returns.

If an arm completes without a bytecode tail call—for example, it returns a
literal or calls a native—`fkTailMatchBody` performs the ordinary arm-to-owner
value handoff in `finishFrameReturn`.

### 3.6 Return adaptation, checked errors, and completion finalizers

V1 does not compose caller boundaries into an “outer pair.” One pair is not
enough for:

```text
f ->tail g ->tail h
```

Exact non-tail behavior may require `h`, then `g`, then `f` return adaptations
and checked-error translations. A linked representation preserves the order
but grows with call depth. It would merely move the leak from `frames` into a
different heap structure.

The rule is therefore simple:

- a caller with dynamic return adaptation or `^errors` is not tail-elidable;
- a caller with pending required-implementation validation is not
  tail-elidable;
- namespace, module, constructor, cleanup, and restoration continuations are
  excluded or gated;
- a compiler-proven redundant result boundary may be removed before runtime,
  as `returnKnownBareInt` already does, after which the activation is plain.

The proof should be generalized before expanding to the less common dispatch
shapes. Refactor `formsKnownBareInt` into a result-shape analysis that can prove
additional exact result kinds such as `F64`, `Bool`, and `Str`. `Any` may be
treated as redundant only after tests pin that its adaptation is identity.
`Nil` and `Void` are not generally identity boundaries—they coerce/discard the
body result—so they are removable only when the final result is already proven
to be the exact declared unit. Higher-order or adapting results remain
conservative fallbacks. The implementation reports typed tail-site coverage
before and after each new proof rather than inferring reach from a handful of
deep probes.

This preserves current error labels, adaptation order, statement return types,
and validation timing exactly. A future extension may elide two boundaries
only if it proves a bounded, lossless composition—for example, a formally
idempotent identical policy. It must not allocate an unbounded continuation
list.

No new boundary fields belong in `FrameExtra` for v1. Active activation state
lives in register locals and is copied to `Frame`/`Fiber` on suspension; adding
rare current state only to `FrameExtra` would not be a complete storage design.

`returnDepth` remains the identity of the physical function activation. A
proper transfer preserves `frames.len`, so it deliberately preserves
`returnDepth`. Transparent match frames inherit that depth; their collapse may
change `frames.len` only while restoring saved expression owners, and the final
`loadFrameRegs` restores the normal owner whose `returnDepth` equals the new
depth. A non-local `return` from a closure into an activation that has been
replaced therefore lands at the same physical depth and exits the tail callee
to the same caller. This is semantics-equivalent precisely because the elided
activation had no post-call continuation. A deterministic test pins this case.

### 3.7 Custom `Callable`

Ordinary VM call opcodes currently send non-built-in callable nodes through
`applyCall`, which resolves `Callable/apply`, builds a `Call` envelope, and then
invokes the implementation. A tail mark would be lost if that whole path stayed
opaque.

At a VM call site, marked or unmarked:

1. test `valueImplementsCallable` as today;
2. resolve the `Callable/apply` implementation in the dispatch scope;
3. build the same `Call` envelope and argument pair `[callee, envelope]`;
4. if the implementation is an ordinary bytecode function, bind it and enter
   through `enterBytecodeCall` with the call opcode's original tail mark;
5. otherwise use `applyCall` and its immediate-result behavior.

The envelope allocation is already part of custom `Callable` semantics. The
ordinary `vkFunction` fast paths do not pay for it. Tests compare the envelope,
site, named arguments, error location, and protocol dispatch behavior between
marked and unmarked calls.

### 3.8 Diagnostics

Elided frames cannot all be retained while memory remains bounded. Diagnostics
are explicitly lossy:

- keep a fixed recent window of tail-transfer locations per physical frame;
- keep a saturating count of additional elided calls;
- render the retained entries plus `... (N tail calls elided) ...`;
- trim/reset the window when its physical frame returns;
- store the window and count in fiber continuation state so suspension and
  resumption preserve them.

The existing `tailTraceFrames` machinery supplies locations and physical frame
depth. Its storage changes from an unbounded append-only sequence at one depth
to a bounded per-physical-frame window (64 entries is an initial diagnostic
policy, not a semantic number). The window is keyed by the same
`returnDepth == frames.len` activation invariant as non-local return; trimming
on return and after transparent-frame collapse must not invent a separate
notion of depth.

An error trace can name the throwing frame and retained tail frames; it cannot
promise to name every elided activation.

The opt-in `--report_tail_fallbacks` developer diagnostic is separate from
stack traces. When enabled, the call-entry module records the first fallback at
each marked source call site and prints the source location plus its stable
reason code. Tests cover de-duplication and every reason; the disabled path does
not allocate a warning set or increment diagnostic counters.

### 3.9 Interaction inventory

| machinery | v1 interaction |
|---|---|
| fibers | Current registers, frame stack, match-frame kind, and bounded trace state are captured and restored together. |
| generators | Calling a generator returns a `Stream` without entering its body. Tail calls inside a running generator use the fiber's normal call-entry module. |
| `try`/`catch`/`ensure` | Their bodies do not receive tail context. Handler and cleanup owners are never replaced. |
| capabilities | A body/transition that must restore capability state keeps its frame. An ordinary call with no transition can replace a plain activation. |
| closures | A callee that captures a recyclable caller scope forces fallback. Non-pooled scopes may survive by reference count. |
| match | Tail arms are transparent expression frames and collapse current-first before the function decision. |
| scopeless calls | Specialized binders still use the same entry interface; replacement is a register/chunk switch after operand binding. |
| custom `Callable` | `Callable/apply` bytecode implementations join the same path after envelope construction. |
| recur peepholes | Stay. Same-scope restart and fused arithmetic remain faster specializations of cases the general contract also covers. |
| dispatch caches | Resolution/cache lookup remains before call entry; the final call carries the tail mark. |
| namespace/module top level | Not a v1 tail context because completion and validation are observable. |
| AOT/typed-native | No Gene VM frame is entered; outside this VM-frame contract. |
| wasm | Same semantics and layout checks; `nimble wasm` is a required implementation gate. |

---

## 4. Semantic decisions

1. **No new language syntax.** There is no `recur` form. The compiler proves
   position; existing recur opcodes remain implementation specializations. The
   opt-in fallback report is a development CLI diagnostic, not Gene syntax.
2. **Exact fallback beats nominal coverage.** A syntactically tail call may
   push when the current activation owns observable continuation work. This is
   part of the contract, not a temporary silent failure.
3. **Typed and checked-error recursion is conservative.** It becomes constant
   frame space only when compilation proves the relevant boundary redundant.
   Otherwise each invocation retains its frame.
4. **Required implementation validation always runs.** Dead bytecode after a
   call does not make scope-completion validation dead.
5. **Constructors and namespaces return their defined result.** A constructor's
   body value remains ignored in favor of the validated instance; a namespace
   body's value remains ignored in favor of the Namespace object.
6. **Custom callables are user calls.** If their `Callable/apply`
   implementation is bytecode, a tail-marked application participates in the
   same replacement mechanism.
7. **Tail traces are bounded summaries.** Exact values/errors are preserved;
   a diagnostic history of arbitrarily many elided activations is not.
8. **Non-tail recursion is unchanged.** A separate depth diagnostic may be
   desirable but is outside this proposal.

---

## 5. Implementation plan

Every stage lands with `nimble test`, `nimble spec`, `nimble perf`, and
`nimble wasm`. `nimble verify` runs for the call-entry and match stages because
they are broad VM changes.

### Stage 0: durable baseline and instrumentation

- Move the essential exploratory probes into `tests/` and `benchmarks/`.
- Add test-only counters for current/max physical frame count, proper tail
  transfers, transparent expression frames collapsed, and fallback reason.
- Re-run the motivating programs with the new frame/allocation counters and
  replace the RSS-only table in section 1 with the durable baseline. Record
  call/send benchmark numbers before changing dispatch.
- Add the opt-in `--report_tail_fallbacks` plumbing with no allocation or
  counter work while disabled.

### Stage 1: compiler proof and GIR v3

- Thread the tail context through expression/body compilation.
- Mark every call opcode and preserve marks through compiler rewrites.
- Add `MatchProto.tailResult`.
- Bump `GirArtifactFormat` to 3 and add round-trip/rejection tests.
- Add target-relative `Instruction` layout checks in native and wasm builds.
- No VM behavior changes yet.

### Stage 2: deepen bytecode call entry

- Introduce `BoundBytecodeCall`/`enterBytecodeCall` as the one
  replace-versus-push seam.
- Route plain, name, local, outer, parent, value, splice, and scopeless call
  paths through it without adding hot-path allocation.
- Replace the dynamic next-op check with the compiler mark and frame-relative
  operand proof.
- Keep operand-region equality and `returnDepth == frames.len` as release-build
  fallback guards, with debug assertions before replacement.
- In debug builds, wherever the old immediate-return shape applies, assert that
  the compiler mark agrees with the old next-op detector. Branch/match shapes
  that end in jumps are outside this cross-check. Keep this assertion through
  Stages 3–6 rather than deleting it as soon as Stage 2 passes.
- Run differential/fuzz fixtures with tail marks honored versus forcibly
  ignored across every call opcode family.
- Keep all semantic gates from section 3.4.
- Close the mutual-recursion and function-value probes for plain functions.

### Stage 3: generalize redundant return-policy proofs

- Refactor the bare-`Int` body-result proof into a result-shape analysis shared
  by functions and messages.
- Add proven-exact `F64`, `Bool`, and `Str` results; add `Any`, `Nil`, or `Void`
  only under the identity/exact-unit rules in section 3.6.
- Keep unknown, generic, union, or adapting boundaries as exact fallbacks.
- Report the percentage of tail-marked sites in `examples/` and `tests/` whose
  only blocker is a return policy, before and after this stage, and include that
  coverage in acceptance alongside the deep probes.

### Stage 4: sends and protocol/custom dispatch

- Carry the mark through bare, optional, qualified, and `super` sends to their
  final bytecode call.
- Route bound protocol messages through the shared entry seam.
- Resolve VM user `Callable` applications to `Callable/apply` before the
  fallback to `applyCall`, preserving the opcode's marked/unmarked state.
- Verify cache hit/miss and capability-transition behavior.

### Stage 5: transparent match arms

- Enter tail-result arms as `fkTailMatchBody`.
- Implement current-first transparent-frame preflight and collapse.
- Add normal-return handling for the new frame kind.
- Cover nested matches, non-pooled arm scopes, hypothetical pooled-scope
  preflight, captured closures, ORC move ownership, and fallback after collapse
  to a typed/error/validation owner.

### Stage 6: bounded traces, diagnostics, contract, and performance gates

- Replace unbounded same-depth trace accumulation with a fixed window and
  saturating elision count carried by fibers.
- Complete and document `--report_tail_fallbacks`, including once-per-site
  de-duplication and stable reason codes.
- Add the contract text only for the call kinds whose stages are complete.
- Add deterministic spec tests and deep benchmark/stress cases.
- Compare before/after call, send, custom-callable, and recur-peephole results;
  investigate regressions rather than promising that every marked shallow call
  is strictly faster.

No stage adds a dependency or opcode solely for user-facing syntax.

---

## 6. Verification and acceptance

### 6.1 Deterministic semantic tests

Positive constant-frame tests:

- self and mutual recursion through compact and clause `if` forms;
- recursion through a function value;
- direct/name/local/outer/parent and splice calls;
- bare, qualified, optional, and `super` sends;
- bound protocol-message application;
- a user-defined `Callable/apply` bytecode implementation;
- one and multiple nested tail-position `match` arms;
- `do`, `if_yes`, `if_not`, `&&`, `||`, `??`, and direct `return` propagation;
- compiler-proven redundant `Int`, `F64`, `Bool`, and `Str` return policies;
- a non-local `return` from a closure after its target activation has been
  replaced by a tail callee at the same physical depth;
- execution inside a suspended/resumed fiber.

Exact fallback tests:

- adapting return types and statement return types;
- declared `^errors`, including the exact existing function-specific message;
- required implementation validation at scope/module completion;
- `try ... catch SomeException ...`, `ensure`, capability restoration, task
  scope, supervisor, constructor, namespace, and module completion;
- a closure whose callee scope captures a recyclable caller scope;
- a custom `Callable` whose implementation is native;
- malformed or old GIR artifacts.

Ownership tests:

- nested match arms with branch-local bindings;
- pooled call scopes and non-pooled branch scopes;
- closures capturing an arm binding;
- frame/fiber capture and restoration after match collapse;
- no release of the saved owner's scope during transparent-frame collapse;
- per-arm capture preflight before any future pooled scope can be recycled;
- `loadFrameRegs` move/discard behavior under ORC with nested collapsed arms.

Every positive case asserts maximum live physical frames, not only its returned
value. At least one non-tail recursive negative control must show a rising frame
counter so the instrumentation proves it can detect growth.

### 6.2 Stress and performance tests

- Run plain mutual, value, match, and send chains at increasing depths and
  assert a flat frame count.
- Track allocations/live continuation metadata in addition to peak RSS.
- Keep RSS as a secondary end-to-end smoke measure; allocator retention makes
  it unsuitable as the sole assertion.
- Verify the bounded tail-trace window and saturating count at millions of
  transfers.
- Run every call family differentially with tail marks enabled and forcibly
  ignored, including randomized argument/splice/named-call shapes.
- Exercise a deliberately invalid operand region and assert release builds take
  the ordinary push path without truncating live stack values.
- Report typed tail-site coverage before and after result-shape proof
  generalization; deep untyped probes alone are not sufficient acceptance.
- Verify `--report_tail_fallbacks` emits one stable reason per marked source
  site and performs no bookkeeping when disabled.
- Benchmark unmarked calls, marked shallow calls, deep tail calls, sends,
  custom callables, and existing `opRecur1` fast paths.

Acceptance requires no avoidable regression in unmarked/hot scalar paths and a
large improvement for the deep tail cases. Any measured regression is reported
with before/after numbers and addressed under the repository performance rules.

### 6.3 Build gates

Every implementation commit runs:

```bash
nimble test
nimble spec
nimble perf
nimble wasm
```

Broad call-entry/match changes also run:

```bash
nimble verify
```

The wasm gate verifies both behavior and the target-relative instruction/frame
layout assumptions.

---

## 7. Draft contract text for `docs/design.md`

> ### Tail calls
>
> Gene recognizes calls in tail position. Tail position begins at the last
> expression of a function or message body and flows through selected `if`
> branches, `if_yes`/`if_not` bodies, `match` arm bodies, `do` bodies, the last
> operand of `&&`/`||`/`??`, and a direct `return` expression.
>
> A tail call reuses the current VM activation when that activation has no
> observable work left after the call. Self-recursive, mutually recursive,
> higher-order, message-send, protocol-message, and user-`Callable` chains made
> entirely of such activations run in constant VM frame space.
>
> A call keeps the current activation when it must still adapt a declared
> return type, check a declared `^errors` row, validate required protocol
> implementations, run cleanup, restore capabilities, complete construction or
> namespace/module publication, or preserve a pooled scope captured by the
> callee. Keeping the activation preserves the same value, error, validation,
> and cleanup behavior as an ordinary call.
>
> Tail position does not flow through call arguments, conditions, patterns,
> binding initializers, loop bodies, `try`/`catch`/`ensure`, capability/task/
> supervisor bodies, constructors, namespace/module bodies, `new`, or fexpr
> invocation. Native and generator calls do not add a Gene bytecode frame.
>
> Stack traces retain a bounded recent window of elided tail calls and report
> how many additional calls were omitted.
>
> Development runs can enable `--report_tail_fallbacks` to report, once per
> source call site, why a marked call kept its activation.

The control-flow section gets a short cross-reference. Executable examples and
the full call-kind matrix belong in `docs/spec/calls.md` and
`tests/spec_runner.nim` rather than being duplicated as drifting pseudocode.

---

## 8. Alternatives considered

### Keep the current peepholes and tell users to write loops

Rejected. Match-driven tail recursion is a natural structural walker, mutual
state machines are not always clearer as mutable loops, and the measured
failure mode is unbounded heap growth without a useful diagnostic.

### Promise Scheme-style replacement for every syntactic tail call

Rejected for v1 because Gene functions may own runtime return adaptation,
checked-error translation, required-implementation validation, and other
observable finalizers. Preserving an arbitrary ordered chain requires
unbounded metadata; dropping it changes semantics. The proposal exposes the
real condition instead.

### Store one outer return/error pair in `FrameExtra`

Rejected. It works for one replacement and fails for `f ->tail g ->tail h`.
Turning the pair into a list preserves semantics but not bounded space, and
`FrameExtra` is not the storage for the current register-owned activation
anyway.

### Mark saved match parents as dead

Rejected. The current arm owns the scope that must be released; the saved
record is the parent that will be restored. `fkTailMatchBody` places
transparency on the activation that actually owns it.

### Compile match arms inline

Viable but too invasive for this feature. It requires cross-chunk slot and
source-location remapping. Transparent expression frames preserve the existing
arm-chunk module and concentrate the complexity in call entry.

### Add an explicit `recur` form

Rejected. It covers only a subset of mutual, value, and send recursion and adds
surface syntax for a property the compiler can prove. Existing recur opcodes
remain valuable internal fast paths.

### Trampoline through Nim or compile all calls in CPS

Rejected. The explicit Gene frame stack is already the trampoline and is the
state fibers capture. A second trampoline or wholesale CPS conversion would
duplicate continuation machinery and disrupt direct/scopeless call paths.

---

## 9. Risks and follow-up opportunities

1. **Compiler propagation coverage.** `compileExpr` is central and compiler
   rewrites are numerous. The implementation must inventory every call emitter
   and test that specialization preserves the mark. During rollout, applicable
   straight-line shapes are cross-checked against the old next-op detector.
2. **Operand layouts.** Tail position does not by itself prove every opcode's
   operand base. Each call adapter needs a documented layout, a release-build
   equality guard before mutation, debug assertions, and marked/unmarked
   differential coverage.
3. **Physical activation identity.** Non-local return and tail-trace trimming
   both depend on `returnDepth == frames.len` for the normal activation being
   replaced. The shared seam guards and asserts it, transparent frames may only
   inherit it, and collapse must restore owners through `loadFrameRegs`.
4. **Typed-call reach.** About half of callable definitions in the measured
   corpus declare a return type, while the existing redundant proof mainly
   helps `Int`. Result-shape proof coverage is measured and developed before
   expanding to less common call kinds.
5. **Scope capture.** Falling back for a captured pooled scope is correct but
   limits some higher-order recursive programs. A future design could promote
   a pooled scope to durable ownership, provided it does not add hot-path heap
   reads or invalidate closure references. Match collapse separately preflights
   every expression scope before recycling can occur.
6. **Custom `Callable` dispatch.** Resolving `Callable/apply` inside the VM call
   path must remain behavior-identical to `applyUserCallable`, including named
   envelopes, source sites, and errors.
7. **Trace policy.** A fixed window is deliberately lossy. Its data structure
   must be bounded per physical frame and must trim correctly across nested
   physical call depths and fiber suspension.
8. **Target layout.** The extra instruction bit is padding-neutral on arm64,
   but that does not establish wasm layout. Instruction and frame-size
   assumptions require per-target checks before merge; failure reopens the
   field layout rather than creating a second tail-mark representation.
9. **Possible bounded boundary equivalence.** Identical/idempotent return or
   error policies may eventually admit safe elision, but only after their
   composition law and diagnostics are specified and tested. It is not needed
   for the v1 guarantee.
