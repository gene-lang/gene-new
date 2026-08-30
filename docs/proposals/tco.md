# Proper tail calls

A design for Gene. Goal: **every call in tail position runs in constant VM frame
space** — self-recursive, mutually recursive, through function values, through
sends — so that the recursive-walker idiom (`match` over nodes, recursing into
children) is an iteration primitive, not a depth risk.

This is the design answer to the review item *"No tail-call position anywhere …
that's a contract worth one paragraph."* The answer is not "no TCO, use the
loop forms": the machinery for proper TCO already exists in this VM, it is
simply not wired up. This document specifies the language contract and the
mechanism that delivers it.

---

## 1. Current state, measured

Gene already has three partial mechanisms, but none of them adds up to proper
tail calls. Probes (`tmp/probe*.gene`, measured with `/usr/bin/time -l`, Apple
Silicon, 2026-08-29):

| shape | depth | peak RSS | verdict |
|---|---:|---:|---|
| A. self tail call in an `if` arm (`(if (< n 1) 0 (spin (- n 1)))`) | 20M | **10.7 MB** | O(1) — compiler peephole, not general TCO |
| A2. same, called via `(wrap …)` (nested frame) | 20M | 10.7 MB | O(1) — peephole is depth-independent |
| C. mutual recursion through `if` arms | 20M | **12.5 GB** | pushes ≈ 600 B/level |
| D. self tail call in a `match` else arm | 20M | **15.2 GB** | pushes ≈ 760 B/level |
| E. tail call through a function value `(f (- n 1))` | 200k | 321 MB | pushes ≈ 1.5 KB/level |
| F. tail send `(b ~ down)` on a type instance | 200k | 220 MB | pushes ≈ 1 KB/level |
| baseline (no recursion) | — | ~10 MB | |

Three findings:

1. **There is no stack-overflow event at all.** Frames live on the heap
   (`Frame` is an explicit object in a `seq[Frame]`; deep calls never recurse
   through Nim), so deep non-tail recursion just consumes memory until the
   machine gives up. Nothing in the language defines what happens, and nothing
   guarantees iteration-by-recursion is cheap.
2. **The only O(1) shape is a compiler peephole, not a guarantee.**
   `rewriteSelfRecursiveCalls` rewrites direct self-calls to `opRecur1` and —
   when the function has exactly one param, no matches/for/try/subchunks, and
   the arg is `local - const` — fuses them into
   `opRecur1LocalIntSubConst(SameScope)`, which restarts the frame in place
   (`restartRecur1SameScopeFrame`). It fires only when the whole shape matches:
   unary, simple/typed-Int, and the recursive call sitting in the proto's
   *top-level* instruction list. `chunk.matches.len == 0` is a hard
   precondition, so a tail call under `match` — the single most important
   walker shape in this language — never qualifies (probe D).
   `rewriteBareIntReturnAdds` similarly special-cases fib-like bodies.
3. **The VM already contains a real frame-replacement TCO, but it is nearly
   unreachable.** `canReplaceCurrentTailCall` + `enterTailCallFrame`
   (vm.nim, used in the `opCall*` and `opCallLocal*` arms) replaces the current
   frame in place when:
   - the next instruction is literally `opReturn`/`opReturnBareInt` (a *dynamic*
     position check — fails for every `if`/`match` arm, because the arm ends in
     `opJump`, not `opReturn`),
   - `calleeIndex == 0` (the call's operands sit at the bottom of the *entire*
     shared operand stack — only the outermost frame qualifies),
   - the current frame is plain (`fkNormal`, no ensure/for/owned-scope/pending
     state, no error boundary, no return-type adaptation, no capability
     transition), and
     the callee's scope does not capture the caller's call scope.

So the pieces are all present; what is missing is (a) a *static* notion of tail
position, (b) the frame replacement on **every** call path, and (c) the
composition rules that make replacement semantics-exact when the replaced
activation carries return-type adaptation or an `^errors` boundary.

---

## 2. The contract

Gene adopts the Scheme/R7RS contract, phrased for this language:

> **Proper tail calls.** A call in *tail position* must reuse the current
> activation instead of pushing a frame. Self-recursive, mutually recursive,
> and higher-order tail calls — including through `~` sends — run in constant
> VM frame space.

### 2.1 What is a tail position

Tail position flows from the last expression of:

| form | tail position |
|---|---|
| `fn` / `ctor` / message body, `ns` / `mod` body | last expression of the body |
| `(if c (then …) (elif …) (else …))` | last expr of each `then`/`elif`/`else` clause |
| `(if c a b)` compact form | `a` and `b` |
| `(if_yes c body…)` / `(if_not c body…)` | the body tail |
| `(match t (when p body…) (else body…))` | last expr of **every** arm body |
| `(do …)` | last expr |
| `(&& a b tail)` / `(\|\| …)` / `(?? …)` | last operand only |

Plus `(return expr)`: `expr` is in tail position of the enclosing function.
The VM treats it like any marked tail call; the frame-replacement guard
automatically falls back to a normal call when structured cleanup is pending.

### 2.2 What is *not* a tail position (documented exceptions)

- Call arguments, `if`/`match` conditions and patterns, binding initializers
  (`let`/`var`/`const`/`set`).
- Loop bodies (`while`, `for`, `loop`, `repeat`) — the loop's own value, not
  the body's, is the form's result. (Plain iteration stays the job of these
  forms; they already iterate in-place with zero frames.)
- `try`/`catch`/`ensure` bodies, `with_capabilities` bodies, `spawn`/
  supervisor/task-scope bodies: a tail call there **pushes a frame** for that
  level. A `try` must still catch, an `ensure` must still run, a capability
  transition must still restore — all three are pinned to a frame. The cost is
  one frame per enclosing dynamic-context level, not per iteration.
- `new`-construction (opNew) — v1 leaves it a normal call.
- fexpr invocations are syntax, not calls — no tail contract.

Also true and worth stating: **a call whose callee is a native function or a
generator never grows the Gene frame stack** (both return without entering a
body), so tail position is trivially satisfied there; the contract only has to
do work for `Fn` callees that run VM bytecode.

### 2.3 What proper TCO buys, concretely

```gene
(fn walk [node]                    # node-walker idiom: O(1) frames after this design
  (match node
    (when {^children []} (transform node))
    (else (walk (first node/children)))))

(fn even? [n] (if (= n 0) true (odd? (- n 1))))   # mutual: O(1)
(fn odd?  [n] (if (< n 1) false (even? (- n 1)))) # (probe C: 12.5 GB → O(1))

(fn fold [f acc xs]                # tail call through a value
  (match xs [] acc _ (fold f (f acc (first xs)) (rest xs))))

(message down [] : Int             # tail send on a type (probe F)
  (if (< self/n 1) 0 ((Box/new (- self/n 1)) ~ down)))
```

Every one of these grows O(depth) today and becomes O(1). The state machine of
the language — selectors-as-transformation producing recursive walkers — is
exactly the code shape this protects.

---

## 3. Design

The whole mechanism rests on one fact about this VM: **calls already push
explicit heap frames; a tail call is simply *not pushing*.** The current
registers are overwritten with the callee's, `frames.len` stays constant, and
the callee's eventual `opReturn` pops straight to the replaced frame's caller.
Generators already suspend and resume these frames (design §6.1) — frame
replacement is the same machinery, exercised in the forward direction.

Two halves: the compiler must know statically which calls are in tail position
(the dynamic "next instruction is `opReturn`" check in
`canReplaceCurrentTailCall` cannot see through `if`/`match` joins), and the VM
must be able to replace the frame in every call path, not just the two hottest.

### 3.1 Compiler: tail-position analysis

Thread a tail flag through the expression compiler.

```nim
proc compileExpr(c: var Compiler, node: Value, tail = false)
proc compileBody(c: var Compiler, body: openArray[Value], tail = false)
proc compileBodyFrom(c: var Compiler, body: openArray[Value], first: int,
                     tail = false)
```

`tail == true` means "this expression's value is the value of the enclosing
tail position; its evaluation may replace the current frame". Rules:

- `compileBody`/`compileBodyFrom` compile the **last** form with the body's own
  `tail` value, everything else with `false`. (Statement results are popped;
  only the final element can be in tail position.)
- Propagating forms pass `tail` down: `compileIf` (each `then`/`elif`/`else`
  body), `compileIfThen`/`compileIfNot` (bodies), `match` (each clause body),
  `do` (its body), `&&`/`||`/`??` (last operand), `return` (its expression).
- All other descents — conditions, patterns, arguments, initializers, loop
  bodies, try/catch/ensure bodies, `with_capabilities` bodies, quoted
  material, nested `fn` bodies (they open their own tail context) — compile
  with `tail = false`.
- Macro expansion composes for free: expansions are ordinary source lowered
  through the same compiler, so tails inside expansions are marked by the same
  rules.

Call-emit sites stamp the flag:

- `emitPlainCall` / the `opCall0/1/2/opCall/opCallSplice` emission,
- the fast local/outer/parent call ops (`opCallLocal1/N`,
  `opCallParentLocal0/1`, `opCallOuterLocal0/1`, `opCallName0/1/N`),
- the call op emitted at the end of every send lowering (`~` bare sends via
  `opResolveMessage` + call, `opQualifiedSend`, `opSuperSend`, `?~` sends —
  these all funnel into the same call dispatch arms).

**Carrier for the mark.** Add `tail*: bool` to `Instruction`:

```nim
Instruction* = object
  op*: OpCode
  intArg*: int
  depth*: int
  name*: string
  names*: seq[string]
  flag*: bool        # opcode-specific (scopeless int-args known, …)
  tail*: bool        # this call is in tail position (design §3.5)
```

`flag` is already spoken for on the local-call family (it means "args are
known-Int" for the scopeless fast path), so a distinct field it is. Nim packs
both bools into one alignment slot: `sizeof(Instruction)` is 64 before and
after adding `tail` (verified) — gate it with
`static: doAssert sizeof(Instruction) == 64`. If a future field breaks that,
fall back to a chunk-level `seq[uint8]` bitset keyed by instruction index,
mirroring `callSites` — the dispatch sites already index chunk metadata by
`ip - 1`.

`gir_codec` serializes `Instruction`, so the bit joins the round-trip along
with the `MatchProto` field below.

### 3.2 Compiler: match arms in tail position

`opMatch` executes the matched arm as its own frame
(`pushFrame(); enterFrame(cl.body, branchScope, …)`), because arm bodies are
independent chunks with their own slot layouts. A tail call inside the arm
would therefore leave the *parent* function frame resident — one frame per
recursion level even with frame replacement (this is exactly what probe D
measured).

Fix: one flag per match. When the `(match …)` form itself is in tail position,
every arm body is in the function's tail position (arms are mutually exclusive
paths), so:

- gir: `MatchProto` gains `tail: bool`, set at compile time from the tail
  context at the match site; arm bodies compile with `tail = mp.tail`.
- VM: `Frame` gains `deadTail: bool` (padding-absorbed). `opMatch` sets
  `frames[^1].deadTail = mp.tail` after `pushFrame()` and before
  `enterFrame(cl.body, …)` — the bit means *"this frame's continuation after
  receiving its single result is dead by the tail-position proof."*

A nested `match`-in-`match` tail pops one frame per level; see 3.3.

Alternatives considered for match and rejected: compiling arms inline with
jumps (needs cross-chunk slot remapping — invasive); running arms in-frame
without a return address (no mechanism in the dispatch loop). The flag +
pop-loop is minimal and preserves the arm-as-chunk model.

### 3.3 VM: one shared tail path

Promote `enterTailCallFrame` + `canReplaceCurrentTailCall` from the two
fast-path call sites to a shared template used by **every** frame-pushing call
arm:

- `opCall0/1/2/opCall` (plain, named, splice),
- `opCallName0/1/N`, `opCallLocal0/1/N`, `opCallParentLocal0/1`,
  `opCallOuterLocal0/1` (the shared direct-call arm),
- `opResolveMessage` / `opQualifiedSend` / `opResolveQualifiedMessage` /
  `opSuperSend` lowering (these resolve a callee + receiver onto the stack and
  then consume the same call arms; the tail mark rides the final call op),
- the scopeless-call fast path (tail variant: args already sit at the frame
  base after the shift-down; replacement is a pure register/chunk swap).

Structural suggestion: extract the tail end of each arm ("bind → decide →
push") into one `enterFunctionCall(…)` template that internally decides
replace-vs-push, so the guard logic exists once instead of in six arms.

The generalized eligibility test replaces the dynamic
"next op is `opReturn`" check with the compiler's mark, and the `calleeIndex
== 0` gate with region containment:

```nim
template canReplaceCurrentTailCall(calleeScope: Scope): bool =
  curFrameKind == fkNormal and
  # frame is a plain function activation: no ensure/for/task/ns/capability
  # state, no pending cleanup
  curEnsureBody == nil and curForItems.len == 0 and
  curForStream.kind != vkStream and curOwnedScope == nil and
  curPendingError == nil and curPendingPanic == nil and
  curPendingCancel == nil and curPendingReturn == nil and
  # the call's operands occupy exactly this frame's region (statement
  # position): everything below belongs to live callers
  calleeIndex == curStackBase and
  # recycling the caller's pooled scope would free a scope the callee
  # captures (e.g. a closure defined in this frame)
  (not recycleScope or not scopeChainContains(calleeScope, scope))
```

Notes on what changed vs today:

- `ip < len and next op in {opReturn, opReturnBareInt}` is **dropped** — the
  compiler mark is the position proof. (This is what unlocks `if`/`match` arms:
  today's check fails there because `opJump` sits between the call and the
  shared `opReturn`.)
- `calleeIndex == 0` becomes `calleeIndex == curStackBase`: statement position
  inside *any* frame, not just the outermost. (Everything below
  `curStackBase` belongs to callers and is untouched; `strunc(curStackBase)`
  in `enterTailCallFrame` is already the right truncation.)
- `not validateImplRequirements` on the *current* frame can likely be dropped
  (the replaced frame's remaining instructions are dead, so its pending
  obligations are moot; the callee installs its own flag) — land conservatively
  with the check, then remove it behind a benchmark if it ever shows up in a
  profile. Same treatment for `returnType.kind == vkNil`: see §3.5, which
  removes the need to bail on typed returns at all.
- `frames[^1].restoreSlot` frames (the same-scope `recur` restore records) are
  unaffected: the recur machinery restarts or its frame is restored by the
  return path; a tail call never executes with a live `restoreSlot` in the
  *current* registers.

The per-site checks already in place stay:

- callee is `vkFunction` with a `FunctionProto` body — natives return on the
  Nim stack (no Gene frame to replace), generators return a `Stream` without
  entering a body (their call sites fall through to `applyCall` untouched), and
  fexprs never reach here;
- no capability transition introduced by the callee (`nextTransition` equals
  current context/presence) — a transition needs its frame for restore-on-exit,
  so such calls push. This is the same gate the hot paths use today.

### 3.4 VM: dead-subframe pop for match arms

On a tail-marked call, before replacing, pop trailing *dead* subframes:

```nim
template popDeadTailFrames() =
  ## The mark proves every frame between this call and the enclosing function
  ## frame is a sub-expression frame (today: match arms) whose continuation
  ## after receiving the arm value is dead. Pop them; release their scopes.
  while frames.len > 0 and frames[^1].deadTail and
        frames[^1].kind == fkNormal and frames[^1].extra == nil and
        frames[^1].restoreSlot < 0:
    var dead = frames.pop()
    releaseFrameCallScope(dead)
    loadFrameRegs(dead)   # registers become the surviving function frame's
```

Then run the ordinary replacement. `loadFrameRegs` restores the function
frame's own `returnType`/boundary/`recycleScope` state, which the composition
step (§3.5) needs anyway. Pop-then-replace is exactly "the arm's value is the
callee's return value": the arm frame has no record of its own (it *is* the
current registers), the popped record is the parent function frame whose
continuation is dead. If any inspection fails, fall back to a normal push —
correctness before O(1).

Only `match` needs this today (`for` bodies, `try` bodies, capability bodies
are never tail positions; `if`/`do`/`&&` compile inline in the same chunk).

### 3.5 Exact semantics: composing return adaptation and error boundaries

A frame's registers carry two things that must survive a replacement:

1. **Return-type adaptation.** The current frame's `returnType`/
   `returnLabel` adapt *its* result to *its* declared type when it returns.
   Replacing the registers swaps in the callee's adaptation and would silently
   drop the caller's. Non-tail, the value passes through both boundaries:
   adapt to the callee's declared type, then to the caller's.

2. **`^errors` boundaries.** An error raised inside the tail callee unwinds
   through both functions' declared error rows before reaching the outer
   caller. Dropping the replaced frame's boundary changes which diagnostic the
   error carries ("'h' raised an undeclared error" vs "…'g'…") and which rows
   mask it.

Both compose the same way — a two-level *outer* pair applied after the inner
one. On replacement:

- registers become the callee's (`returnType`, `returnLabel`,
  `checksErrors`, `errorTypes`, `fnName`);
- the replaced frame's pair is retained as the *outer* layer;
- `frameReturn` adapts inner-then-outer (`outer.isStatementReturnType` still
  coerces to the unit, after the inner adaptation runs — it must be able to
  raise exactly where non-tail execution would);
- the unwind handler translates inner-then-outer with each level's
  `fnName`, reproducing today's per-frame translation order exactly.

Storage: only *both*-sides-typed or both-`^errors` tails need the outer pair.
That is rare, so put the outer pair in `FrameExtra` (the existing rare-state
overflow record, `nil` on hot frames) rather than widening `Frame`:

```nim
FrameExtra = ref object
  # … existing fields …
  outerReturnType: Value      # tail-call composition: the replaced frame's
  outerReturnLabel: string    #   pending return adaptation, and its
  outerChecksErrors: bool     #   ^errors boundary, applied after the
  outerErrorTypes: seq[Value] #   tail callee's own, inner first
```

`frameReturn` / `frameReturnBareInt` / the unwind handler apply the outer level
when present. The common shapes never populate it:

- untyped callees: `returnType` is `NIL`, single adaptation or none;
- bare-`Int` returns: `returnKnownBareInt` already collapses the frame type to
  `NIL` (`checkedFrameReturnType`), so typed `: Int` recursion — the
  accumulator idiom — stays on the zero-cost path;
- `isStatementReturnType` (declared `Nil`/`Void`) composes as
  inner-then-unit.

If a future shape proves non-composable, the fallback is a frame push —
correctness first, O(1) second.

### 3.6 Diagnostics

- **`tailTraceFrames`** already exists for this: each replacement appends the
  elided frame's name/loc, `trimTailTraceFrames` pops them on return. In a
  20M-iteration tail loop the append/trim balance at the same depth, but the
  seq must be **capped** (e.g. keep the last 64 elided entries, and mark the
  elision in traces: `… (N tail frames elided) …`) so a long tail loop cannot
  accumulate. Trace depth for an error inside a tail chain therefore shows the
  chain head, the capped window, and the throwing frame.
- The existing `appendVmTrace` already merges `tailTraceFrames`; no change
  beyond the cap.
- Recursion that is *not* in tail position keeps growing heap frames with no
  limit (unchanged behavior; a depth cap/diagnostic is a separate, future
  concern).

### 3.7 Interaction inventory

| machinery | interaction |
|---|---|
| fibers / generators | Composes. Replacement keeps `frames.len` constant; `captureContinuation` moves the seq unchanged. Generator *calls* return a `Stream` via `applyCall` without entering a frame — the mark is ignored. Tail calls *inside* generator bodies work (replacement within the fiber's frame seq). |
| `try`/`catch`/`ensure` | Try bodies run as `fkTryBody` frames with a `TryHandler`; the `fkNormal`-only gate means a tail call never replaces a frame that owns a handler. A `try` *around* a tail-recursive helper costs one frame. Catch/ensure bodies are `fkCatch`/`fkEnsure*` kinds — not replaceable. |
| capabilities | `with_capabilities` bodies are `fkCapabilityBody` frames; a callee introducing a capability transition pushes (restore needs the frame). Same-function tails where `nextTransition == current` replace. |
| closures | `scopeChainContains` guard: a callee whose scope chain captures the caller's pooled call scope forces a push. Non-pooled scopes survive by refcount and may replace. |
| scopeless calls | Tail variant mirrors the scopeless push: args already at frame base, no scope, pure register/chunk switch under the same guards. |
| `opRecur1` peepholes | **Stay.** They are faster than the general path (same-scope restart skips even scope acquire; fused Int arithmetic). The general path covers what the peepholes reject — `matches.len > 0`, non-unary, mutual, values, sends — so `canUseRecur1`'s narrowness stops mattering for correctness. |
| dispatch caches | Send sites cache impls keyed by receiver type/epoch; the tail bit is orthogonal (cache hit → resolved callee → same tail decision). |
| AOT / typed-native | Lowered to C; no Gene frames; out of scope for the VM contract. |
| wasm | Pure VM change, no new deps; `nimble wasm` is a required gate. |
| repl/eval, fexpr `eval` | Tail marks are compiler-wide; nested `runLoop` invocations are independent continuations and TCO within themselves. |
| module top level | The module body's last expression is a tail position; the outermost frame is replaced like any other. |

---

## 4. Semantics decisions

1. **Tail calls to generators** are ordinary calls (they return a `Stream`
   immediately — no frame is entered). The contract's "constant frame space"
   is about activations that *run*.
2. **`(return (f x))`** is a tail position, but a function with a pending
   `ensure` pushes: cleanup runs, then the call returns. This matches the
   documented `return` semantics (§9: structured cleanup still runs).
3. **Error-message composition** across a tail chain is defined as: inner
   boundary translates first, then outer — identical to the non-tail unwinding
   order. A test pins the exact message for mutual recursion between two
   `^errors` functions.
4. **`&&`/`||`/`??` short-circuit values** do not break the tail path: on the
   taken-early paths the operand value is kept on the stack and flows to the
   dead join + return as today; only the last operand can be a marked call, and
   at that point its operands are the only live values in the frame region
   (`calleeIndex == curStackBase`).
5. **No new user-facing syntax.** No `recur` form: with proper tail calls it
   would be a performance hint for something the compiler already proves, and
   the review's point stands — the *contract* is what was missing, not syntax.
   `while`/`loop`/`for` remain the iteration primitives for non-call iteration.

---

## 5. Implementation plan

Staged so every step lands green (`nimble test`, `nimble spec`, `nimble perf`,
`nimble wasm`) and independently valuable:

1. **Marks only** — compiler threading (`compileExpr`/`compileBody`/`compileBodyFrom`
   + the eight propagating special-form compilers), stamp `Instruction.tail`
   on all call/send emit sites, `MatchProto.tail`, gir_codec round-trip,
   `sizeof(Instruction)` static assert. No VM change; all gates unchanged.
2. **General frame replacement** — promote `enterTailCallFrame` to a shared
   template; wire the mark into all call dispatch arms (drop the
   `calleeIndex == 0` and next-op gates; keep the boundary/capability/scope
   guards). Closes probes C and E (mutual + value). `bench_core` call paths
   must hold (the tail path is push-minus-Frame-add; strictly equal or faster).
3. **Sends** — marks on the send lowering so `~`/qualified/`super`/`?~` tails
   replace (probe F). Verify the send-side dispatch-cache guard order is
   unaffected.
4. **Match arms** — `MatchProto.tail`, `Frame.deadTail`, the pop loop (probe D).
5. **Composition pairs** — outer return-type and `^errors`-boundary pair in
   `FrameExtra`; typed/generic tail recursion becomes O(1).
6. **Contract + tests + benches** — design.md §3.5/§9 paragraphs (text in §6
   below), spec_runner suite, benchmark additions.

Files and rough size: `compiler.nim` (~250 lines: tail threading + stamps),
`gir.nim`/`gir_codec.nim` (~30), `vm.nim` (~250: shared template, pop loop,
composition, guard generalization), `tests/spec_runner.nim` (~15 cases),
`benchmarks/` (tail loops). No new opcodes, no new dependencies, no
user-facing syntax.

### 5.1 Acceptance probes (re-run as the gate)

Rerun `tmp/probe*.gene` at 20M depth; acceptance is flat RSS (≤ ~50 MB) for
C (mutual), D (match), E (value), F (send), and no regression for A. Probe G
(statement tail, nested) plus a try/ensure-interaction probe pin the guard
fallbacks.

---

## 6. Draft contract text for design.md

§3 addition (after the send rules):

> ### 3.5 Tail calls
>
> Gene guarantees **proper tail calls**. A call in *tail position* reuses the
> current activation instead of pushing a frame: self-recursive, mutually
> recursive, and higher-order tail calls — and tail sends (`~`, qualified,
> `super`) — run in constant VM frame space. A recursive or mutually recursive
> walker in tail position is an iteration primitive:
>
> ```gene
> (fn walk [node]
>   (match node
>     (when {^children []} (transform node))
>     (else (walk (first node/children)))))
> ```
>
> Tail position is the last expression of a `fn`/`ctor`/message body and of
> `ns`/`mod` bodies; it flows through `then`/`elif`/`else` arms, the tails
> of `if_yes`/`if_not`, every `match` arm body, `do` bodies, and the last
> operand of `&&`/`||`/`??`, and through `(return expr)`. It does *not* flow
> through call arguments, conditions, binding initializers, loop bodies
> (`while`/`for`/`loop`/`repeat`), `try`/`catch`/`ensure` bodies, or
> `with_capabilities`/`spawn` bodies — a call there pushes a frame.
>
> A tail call still means full semantics: return-type adaptation and `^errors`
> boundaries of the exited function still apply to the tail-called value and
> to errors raised inside the tail call (applied inner-then-outer), and stack
> traces name the elided frames. A tail call out of a function with a pending
> `ensure` block, an active `try` in the same frame, or a capability
> transition keeps its frame for that level — bounded by the enclosing
> structured context, never by recursion depth.

§9 gets a one-line cross-reference under control flow. `docs/spec/calls.md`
gets the same paragraph; the naming rule is untouched (no new user-facing
names).

---

## 7. Alternatives considered, rejected

- **Keep the status quo and document "use while/for".** Rejected: the walker
  idiom is structural (match-driven descent), not counter-iteration; measured
  cost is 600–760 B *per level* with no diagnostic — a silent 12 GB. Also the
  contract is the point of the review item.
- **Explicit `(recur …)` form (Clojure-style).** Adds a self-tail-only
  special form that proper TCO subsumes; mutual and value-recursion would
  still be unhandled. Not needed once the contract exists; revisit only if
  someone wants an *assertion* that a call is a self-tail.
- **Nim-level trampolining in `applyCall`.** The explicit frame stack *is* the
  trampoline; adding a Nim loop would duplicate it and put non-heap state in
  the way of fibers.
- **CPS/thunkification** (compile everything into closures). Maximally
  general, maximally hostile to every direct-call fast path, scopeless chunks,
  and dispatch caches in this VM.
- **Depth-capped "overflow" error only.** Doesn't fix the idiom; still worth
  adding later as a diagnostic, out of scope here.

## 8. Risks / open questions

1. **`sizeof(Instruction)`** — resolved: the tail bit is padding-neutral (64
   before and after, verified). The static assert in §3.1 guards future
   fields; the chunk-bitset fallback exists if it ever breaks.
2. **Relaxing `not validateImplRequirements`** — argued safe (dead remaining
   instructions), landed conservatively; revisit with a targeted test.
3. **Boundary/return-type pair on `FrameExtra`** — allocates a ref only for
   both-typed tails; if profiling shows that shape is hot (generic
   instantiation with real adaptation), consider a small inline pair instead.
4. **Trace cap size** — 64 is a guess; the spec test pins the *shape*
   (head + window + thrower), not the count.
5. **Perf gate** — the marked sites gain one bool check; unmarked paths gain
   nothing. `nimble perf` before/after on `bench_core` call benchmarks is part
   of every stage's commit message.
