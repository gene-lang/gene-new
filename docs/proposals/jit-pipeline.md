# JIT and Native Compilation Pipeline

Status: design proposal. Not implemented. Review comments from 2026-07-29 are
incorporated into the normative design below.

This proposal builds on `native-type.md` for native representations and ABI
contracts, `scoped-impls.md` for specialization validity, and `wasm.md` for a
possible future Gene-to-wasm adapter.

## 1. Goal

JIT compilation is an execution tier for typed Gene code. Its first target is
code where VM dispatch and boxing dominate useful work: fixed-width arithmetic,
loops, direct calls, native fields, and typed FFI calls.

The JIT must not become a second language implementation. A function has one
resolved meaning and one native lowering. AOT and JIT differ only in when and
how that lowering becomes executable:

```text
resolved Gene function
        |
        +------------------------> GIR bytecode ----> VM
        |
        `--> native lowering --> NativePlan
                                  |       |
                                  |       `--> machine backend --> JIT artifact
                                  `----------> C backend --------> AOT artifact
```

`NativePlan` is the seam. It contains the compiler's complete proof that a
function can execute with fixed native representations. It contains no C text,
machine instructions, process addresses, or loader state.

The initial goal is semantic parity and a sound shared pipeline, not a claimed
speedup. Performance targets must come from benchmarks against the same
function running in the VM and through AOT.

### Non-goals

JIT compilation does not change Gene semantics, statically type arbitrary
dynamic code, implicitly box raw pointers, or require every platform to permit
executable memory. Generated C is not an intermediate JIT format. Initial
support excludes on-stack replacement, speculative object shapes, and general
deoptimization.

## 2. User interface

There are three application JIT modes:

| Mode | Behavior |
|---|---|
| `off` | Execute through the VM or preloaded AOT code only. |
| `explicit` | JIT only functions marked `^jit true` or requested through the runtime JIT interface. |
| `auto` | Prioritize explicit requests and also compile functions that become hot. |

`explicit` is the default on supported native hosts. Hosts that cannot or must
not allocate executable memory, including the browser wasm build, use `off`.
`auto` remains opt-in until its counter overhead, compilation pauses, and code
memory growth have benchmark coverage.

The command-line/application setting is `--jit=off|explicit|auto`; it is an
execution mode, not a language semantic option.

### 2.1 Per-function requests

Use one ordinary declaration property:

```gene
(fn sum_to ^jit true [n : I64] : I64
  (var total : I64 0)
  (var i : I64 0)
  (while (< i n)
    (set total (+ total i))
    (set i (+ i 1)))
  total)
```

`^jit true` requests compilation without changing function semantics. The
compiler validates its `NativePlan` with source-located diagnostics; machine
code may be produced lazily after runtime dependencies activate.

An explicit request that cannot form a `NativePlan` produces a clear compiler
diagnostic naming the first unsupported operation or unresolved representation.
The ordinary build may still emit VM code for portability. A build/test option
such as `--jit-required` turns an unsatisfied explicit request into an error;
source code does not need a second "required" marker.

This generalizes the existing `requiresTypedNative` diagnostic/fallback
mechanism into one backend-neutral native-lowering request policy rather than
adding a parallel validator. `^jit true` and typed-native requirements use the
same source-located lowering errors; only `--jit-required` changes whether a
failed JIT request is fatal. Runtime fexprs
(explicit fexprs, including ctor fexpr behavior) are categorically ineligible because
they require unevaluated forms and a caller environment, so their diagnostic
names that category rather than an arbitrary first body operation. Template
macros are expanded before resolved-function lowering; a macro expansion may
therefore produce an ordinary lowerable function, but macro execution is never
a plan operation.

`^jit false` opts a function out of `auto` mode.

`^jit` is independent of `^native_entry`. The former selects an in-process
execution tier; the latter asks the AOT backend to export a dynamic boxed entry
that another process artifact can load.

### 2.2 Runtime requests and observability

The runtime exposes a small `$jit` interface for applications that know their
critical path only after startup:

```gene
(import $jit [compile status])

(compile chosen_fn)
(status chosen_fn)
```

`compile` sends the function through the same `NativePlan` and machine backend
as `^jit true`; it is not an eval-like compiler. It respects `off`. `status`
reports at least the state, backend, and the reason for fallback or rejection.
Tooling should also be able to report all explicit requests that did not reach
`ready`.

Programs must not branch on JIT availability to determine their language-level
result.

## 3. One native lowering for AOT and JIT

The compiler exposes one deep interface:

```text
lower_native(resolved_function, native_contracts)
  -> NativePlan
  -> NativeLoweringError
```

There is no separate `is_jit_eligible` pass. Successfully producing a plan is
the eligibility proof. This prevents an analyzer, C emitter, and JIT emitter
from accepting different subsets or assigning different meanings to the same
operation.

The input may initially be backed by GIR or another resolved compiler form,
after template expansion and resolution, but that is an implementation detail
of the lowering module. Backends consume `NativePlan`; they do not rescan source
nodes or reconstruct types by simulating the VM operand stack.

### 3.1 `NativePlan`

A plan records stable function identity and source locations; typed parameters,
return, locals, and captures; structured control flow as nested blocks, `if`,
`while`, and explicit structured exits; typed expression trees over
SSA-numbered values; typed operations and direct-call targets; exact
specialized-send identities; native/ABI/ownership contracts; FFI targets and
lifetimes; every assumed version; guard or VM-fallback sites; and source maps.

Structured control flow is the semantic contract because the lowerable Gene
subset is structured by construction. It preserves readable C and naturally
extends to `break`, `continue`, and early `return`. A machine adapter may lower
this form privately to a CFG and machine-oriented SSA before instruction
selection. Neither that CFG nor a relooper is imposed on the C adapter. If a
future plan admits irreducible control flow, the proposal must explicitly add
and budget a shared CFG-to-structured strategy rather than making the C emitter
reconstruct structure accidentally.

A plan does not contain runtime addresses. An adapter resolves symbols and call
targets while producing an artifact, retaining anything whose lifetime must
outlive the generated code.

The native-lowering module privately verifies representation consistency,
structured-region yields/exits, ownership balance, borrowed-region lifetimes,
and dependency completeness; `lower_native` returns only a verified
`NativePlan`. Backends exhaustively consume plan operations and may report
unsupported operations, but may not inspect source to re-derive lowerability or
semantics. If plans are ever serialized, their decoder belongs to the same
module and performs the same verification before returning one. This replaces
`aotLoweringGap`-style analyzer/emitter disagreement checks by making such a
disagreement structurally unavailable.

### 3.2 Representations

The representation vocabulary is shared with `typed_native`. The existing
concepts currently named `AotRepr` and `AotLocal` become backend-neutral native
representations and locals.

The initial set is `Bool`, `I64`, fixed-width boundary integers such as `I32`,
`F64`, borrowed `CStr` call edges, and native pointers carrying nullability,
exact nominal Type, and ABI layout.

Call-edge-only representations remain call-edge-only. For example, an `I32`
may widen for arithmetic and must be range-checked when it narrows again.
Ownership operations (`borrow`, `copy`, and `transfer`) are explicit plan
operations rather than conventions known only by an AOT entry emitter.
Address-taking is explicit too: an `^out` argument produces an address-of-local
operation and marks that local as address-taken, forcing storage whose address
is stable and constraining register allocation.

Gene `Int` is arbitrary precision and is not an alias for `I64`. Initial native
arithmetic should require `I64`. Supporting `Int` later requires checked
machine arithmetic followed by promotion or a VM slow path on overflow; plain
wrapping machine arithmetic would be a miscompile.

Consequently, Phase 1 reaches only functions whose relevant values have fully
resolved native representations. That is intentionally narrower than ordinary
Gene numeric code. Broader coverage comes from checked `Int` fast paths, not by
inferring that an `Int` is an `I64` and changing its semantics.

### 3.3 Existing lowering paths

Phase 0 subsumes both C-oriented analyses that exist today:
`isTypedNativeAotExpr`, used for signatures with native representations, and
the older homogeneous-scalar `detectAotExpr` path. Leaving either as a second
C eligibility/emission route would preserve the disagreement this plan exists
to remove.

The VM's `detectNativeCompileOp` fast path remains a VM execution optimization,
not a second AOT/JIT eligibility proof. Its native scalar operation semantics
must stay parity-tested against `NativePlan`, but Phase 0 need not route the VM
through the plan. In `auto` mode, a function with an active VM `nativeOp` is
treated as already tiered and is not queued initially. Explicit JIT requests
may still compile it. Auto-compiling such functions is enabled only after a
dedicated benchmark shows warmed JIT performance against the existing
`nativeOp`, not merely against generic VM dispatch.

### 3.4 Backend support

A backend advertises the plan operations, representations, calling convention,
and target architecture it supports. Compiling a valid plan may therefore
return `unsupported` without making the Gene function invalid.

The lowering decides what an operation means; the backend only says whether it
can implement that already-defined operation. Support differences are expected
in Phase 1: the C backend will initially accept more plan operations than a
machine backend. `lower_native` must not take a backend mask or emit a
target-specific plan to hide that difference. A plan remains a single semantic
artifact, and an unsupported adapter reports the exact missing operation.

## 4. Backend adapters

### 4.1 AOT C adapter

The C backend turns a `NativePlan` into C. It owns C declarations and symbols,
`^native_entry` exports, manifests, build/link integration, and cross-build
load validation.

The AOT adapter must stop owning native eligibility and expression semantics.
It should not walk the original function body independently of the shared
lowering.

### 4.2 JIT machine adapter

The JIT adapter turns the plan into an in-process artifact. It owns instruction
selection, register allocation, relocations and call stubs, executable memory,
instruction-cache synchronization, target unwind/debug data, and retained
runtime/FFI/scope/callee references.

An older HIR or machine emitter may supply algorithms and tests, but no file is
assumed to port verbatim. Value layout, call conventions, error propagation,
runtime ownership, and invalidation contracts must be verified against this
runtime.

The initial machine adapter should be an in-tree baseline method JIT: compile
one function at a time, legalize plan operations, allocate registers with a
simple linear-scan allocator, and emit arm64 or x86_64 through small target
encoders. This keeps compilation latency and dependencies low and fits the
initial fixed-representation subset. LLVM/Cranelift integration and a more
optimizing tier remain possible behind the same adapter seam if measurements
later justify their dependency and runtime cost.

### 4.3 Shared runtime entry seam

VM-to-native conversion is one deep runtime module with one interface:

```text
invoke_native_entry(descriptor, boxed_call, uniform_thunk)
  -> boxed result or Gene error
```

Its private, call-owned `NativeEntryFrame` retains boxed roots, aligned native
argument/result slots, borrowed views, buffer leases, ownership transfers, and
pending write-backs. The module acquires every argument transactionally, calls
the supplied thunk only after acquisition succeeds, then finalizes or rolls
back on every exit. Finalization copies mutable buffers back, boxes the result
or error, and releases every lease.

The C and machine adapters each emit a uniform thunk that only loads verified
native slots, invokes the statically typed body, and stores its native result.
That is a real seam with two adapters. Neither adapter can observe or sequence
acquisition/finalization, open-code conversion, or invent storage lifetimes.
Direct native-to-native calls bypass this boxed-entry module and use the typed
call descriptor. The extra uniform call at a boxed entry seam is measured under
§12; correctness is not traded for duplicated fast paths.

The execution paths are:

```text
VM -> JIT
  validate boxed arguments -> unbox -> native call -> box result/error

JIT -> JIT or compatible AOT body
  native call descriptor -> direct call

JIT -> dynamic Gene
  explicit slow-call descriptor -> box -> VM call -> validate/unbox
```

Phase 1 may reject plans requiring the last path. A later backend may implement
it, but the transition must be explicit in the plan: code generation must not
silently invent allocations or dynamic dispatch.

The internal native call descriptor is shared by AOT and JIT. It describes
representations, ownership/lifetime behavior, write-back obligations, and the
error protocol; it is not the public boxed `GeneCall` entry. This permits direct
JIT-to-AOT calls when the loaded AOT artifact exports a compatible unboxed
entry, while retaining the boxed bridge as a fallback.

That descriptor is a versioned ABI contract. It includes the target triple,
calling-convention version, every parameter and result representation,
ownership and error protocols, and only the nominal contract identities needed
to interpret those call-edge representations. Body-internal dependencies are
artifact requirements, not part of the call interface. A new AOT manifest
section publishes each discoverable unboxed body symbol together with the full
descriptor and its fingerprint. The existing boxed-entry manifest is not
sufficient and remains a separate public surface. A JIT caller invokes an
unboxed AOT body directly only on an exact descriptor match and a valid callee
artifact; otherwise it uses the boxed bridge. Native register assignments
remain adapter details derived from the descriptor and target ABI.

Native Type dependencies reuse the existing full contract fingerprints,
including policy (`^copy`, `^release`, `^wrapper`, `^mutable`, `^lifecycle`, and
handle type), plus measured ABI layout fingerprints. JIT must not define a
narrower fingerprint: both AOT and JIT bake the same policies into calls and
lowering decisions.

### 4.4 Managed values and reclamation

Phase 1 machine code does not keep managed Gene `Value`s in native registers or
stack slots and does not allocate Gene objects. Boxed arguments and results
remain rooted by the VM entry adapter while the native body operates only on
fixed representations. Native pointers retain the ownership and library
lifetime recorded by the plan.

Borrowed views have an explicit region lifetime in the plan. A borrowed `CStr`,
`C/Slice`, or buffer view may flow through direct native calls, but it may not
escape the transitive native call chain rooted at the private
`NativeEntryFrame` that acquired it. It cannot be returned, stored in a
longer-lived location, captured, or passed to a call whose descriptor permits
retention. The verifier checks this rule; it is not inferred from the current
subset happening to lack a store operation.

A later plan operation that allocates, stores, or keeps a managed value across
a VM call or safepoint must supply the runtime's ordinary retain/release or
write operation and an exact native-frame root map. JIT frames must then join
the logical Gene stack and safepoint protocol. The design must not depend on
conservative stack scanning or on managed objects remaining non-moving, even
if the current runtime happens to have those properties.

## 5. Explicit JIT lifecycle

Each compiled specialization has a state such as:

```text
request slot: uncompiled -> queued -> compiling -> ready
                  |            |
                  `------------+-----------------> rejected

artifact:      ready -> invalidated -> retired -> reclaimed
```

The exact synchronization is private to the JIT module. Callers see only a
callable Gene function and optional status information.

Artifacts are immutable generations. Invalidation never mutates an old
artifact back into an uncompiled one; the request slot may start a new
generation while the old artifact remains retired until its last active frame
exits. Rejection is sticky for the request's function/compiler version and
dependency reason.

In `explicit` mode, a `^jit true` function is compiled synchronously on its
first call in Phase 1. This avoids module-definition ordering problems and
ensures all runtime contracts needed by the plan exist. The first call may pay
compilation latency; later work may add module warming or background queues
without changing source syntax.

A compatible, valid AOT body already selected for the function satisfies this
request; the runtime does not produce duplicate JIT code unless a later
profile-guided specialization has a reason to replace it.

Compilation publishes an immutable artifact atomically. Concurrent callers
either execute the existing VM/AOT entry or the complete artifact; no caller
observes partially emitted code. A failed compilation records its reason and
continues through the VM.

An artifact belongs to a function definition plus a specialization key, not to
a raw code pointer field. The key contains the function/compiler version,
target and calling-convention version, parameter/result native
representations, and captured-value representations or immutable identities.
Initial support may simply reject captures.

Mutable facts do not belong in that cache key. The artifact separately retains
the dependency snapshot from §7: exact Type contract fingerprints, impl/callee
generations, and FFI lifetimes. This avoids recompiling for an unrelated global
epoch change while still guarding every assumption the artifact actually uses.
The ownership model must allow later safe specialization without moving code
lifetime onto source metadata.

Dependency revalidation failure is sticky for that artifact. Once an exact
requirement is permanently incompatible, calls stop re-walking the same
requirement set and use the VM or a newly compiled artifact. A new
function/compiler version or a genuinely new specialization gets a fresh
attempt; the broken artifact does not oscillate between ready and invalid on
every call.

## 6. Adaptive runtime JIT — Phase 2

`auto` mode adds tiering; it does not add another lowering or code generator.
Every function begins in the VM unless explicitly requested or already supplied
by AOT.

The VM maintains cheap saturating counters for function entries and, where
useful, loop backedges. Crossing a configurable threshold requests a
`NativePlan` and queues machine compilation. The invocation that crosses the
threshold continues in the VM. Once the artifact is published, subsequent
entries use it.

Functions already executing through a VM `nativeOp` are initially excluded
from automatic requests: they are already tiered, and comparing JIT only with
generic VM dispatch would overstate the gain. Explicit requests still work.
This exclusion may be lifted per operation class when repeated measurements
show a warmed JIT improvement over the corresponding `nativeOp` after counting,
compile latency, and code-memory cost.

Counting loop backedges identifies a hot loop inside a function, but Phase 2
does not jump into machine code in the middle of that invocation. Long-running
single-invocation loops require later on-stack replacement and safepoint state
maps. This distinction must be visible in performance claims.

Explicit requests take priority over automatically discovered work. The JIT
uses a bounded compilation queue and code-memory budget; cold artifacts may be
retired only when no active frame can execute them. Rejection is cached against
the function/compiler version so a permanently unsupported function is not
reanalyzed at every threshold crossing.

Background compilation is an implementation option once thread safety is
proven. A synchronous first implementation is valid, but benchmark results must
include the pause it introduces.

## 7. Assumptions, invalidation, and fallback

The VM is the canonical fallback. A compiled artifact records the dependency
snapshot under which its plan is valid, including as applicable:

- native Type contract fingerprints;
- ABI layout fingerprints;
- exact protocol/message + receiver dependency generation and winning impl;
- module/reload generation;
- direct callee generation and call descriptor;
- captured scope or overlay lifetime/version; and
- FFI symbol and library lifetime.

Dependencies are keyed at the granularity of the fact compiled code uses: a
specific protocol/message + receiver generation, callee generation, Type
contract fingerprint, layout fingerprint, or library lifetime. A global epoch
may be a cheap entry gate indicating that some fact changed, but it is never
the dependency itself and never by itself invalidates unrelated artifacts. On
a gate mismatch the runtime checks only the artifact's exact dependency set,
then refreshes its validated epoch if those facts still match.

Stable assumptions may be checked once at entry. An operation whose answer can
change independently, notably a specialized protocol send in an open runtime,
must have a guard before relying on that answer. On mismatch the runtime
re-resolves and either patches/recompiles the artifact or executes the
equivalent VM path. A permanently incompatible result invalidates the artifact
stickily as described in §5.

Entry-only checking is sound only for a dependency retained or leased so it
cannot change during the native frame. Open-runtime protocol selection is not
such a dependency: its guard runs at the send site, and its slow path applies
that one send with the current winning impl. The runtime never restarts an
entire native function in the VM after native side effects have occurred. A
machine backend that cannot box the fixed receiver/arguments and perform the
guarded slow send reports that plan operation as unsupported; Phase 1 therefore
rejects open-runtime specialized sends until that call-level stub exists.

This rule also closes the current `typed_native` limitation around
cross-module overlays: neither AOT nor JIT may permanently call a canonical
protocol impl in an open runtime without the activation guard. Only a declared
closed-world AOT build may omit it.

Phase 1 should compile only functions that can run to completion once their
entry assumptions pass, plus guarded external operations with a defined slow
path. General mid-frame deoptimization requires safepoints that map native
registers and stack slots back to GIR state and is deferred.

Phase 1 also rejects every function that can suspend or participate in
structured-task control flow: generators/`yield`, `await`, `spawn`, task scopes,
channel waits, timers, and suspending I/O. This is a scheduler invariant, not
merely a missing opcode. A Phase 1 native frame has no heap-frame
representation the M:N scheduler can park, migrate, cancel, or unwind. Widening
that subset requires scheduler-parkable native frames and explicit suspension
state maps in addition to GC root maps and deoptimization safepoints.

Reload or invalidation never frees code that an active frame can still execute.
Artifacts and retained dependencies are reclaimed through reference counting,
epochs, or another proven code-retirement scheme. The scheme must also keep
captured overlays and dynamically loaded FFI libraries alive.

## 8. Errors and fallback policy

- Executing through JIT, AOT, or VM must produce the same value or Gene error.
- Source errors and failed gradual type checks are never converted into a
  JIT rejection.
- A lowering failure, unsupported backend operation, allocation failure, or
  unavailable JIT host leaves the VM path usable.
- Explicit requests expose their failure through diagnostics/status; they do
  not silently appear successful.
- `--jit-required` is a deployment/test assertion about explicit requests, not
  a language semantic mode.
- A machine-code invariant failure is an internal runtime failure, not a reason
  to retry potentially corrupted execution in the VM.

## 9. Executable memory

Code pages follow W^X: emit into writable, non-executable memory, then publish
read-only executable memory. Never leave pages simultaneously writable and
executable. The adapter must flush instruction caches where the platform
requires it and use platform-supported hardened-runtime mechanisms.

The JIT is disabled where those guarantees cannot be met.

Unsupported targets exclude the machine JIT at compile time as well as at
runtime. In particular, `geneWasm`/Emscripten builds do not compile or link
instruction encoders, relocation tables, executable-memory management, JIT
status machinery, or auto-mode counters. A permanently disabled JIT must add
zero tracked wasm payload and no call-path overhead.

## 10. Required changes to AOT and native-type support

This design intentionally changes the current organization:

1. Rename/move `AotRepr`, `AotLocal`, native call descriptors, and resolved
   native Type metadata into a backend-neutral native-contract module.
2. Replace both `isTypedNativeAotExpr` and `detectAotExpr` with native lowering
   from the C emitter. The C emitter consumes `NativePlan` rather than
   reinterpreting stored source expressions. Keep the VM `nativeOp` fast path
   distinct as an execution tier, but share or parity-test its scalar operation
   semantics instead of treating it as JIT eligibility.
3. Make ownership, nullability, field identity/offset, and narrowing checks
   explicit plan operations shared by both backends. Include address-of-local
   and address-taken storage for `^out`.
4. Keep AOT manifests, fingerprints, and `aot/load`, but treat manifests as a
   serialized cross-build form of the same dependency contracts the JIT reads
   live in-process. Add a separately versioned unboxed-entry section containing
   full native call descriptors; reuse existing native Type contract and ABI
   layout fingerprints rather than narrowing them.
5. Put the interpreter's converters behind one `invoke_native_entry` runtime
   interface with a private `NativeEntryFrame`. AOT and JIT supply uniform
   invocation thunks; they do not receive acquire/finalize operations or add
   tier-specific scalar, wrapper, buffer, or borrowed-view conversion rules.
6. Give AOT and JIT the same guarded-direct-call rule for protocols and reload.
   Closed-world AOT is the only mode allowed to erase the guard.
7. Keep `^native_entry` AOT-specific. It must not be used as a proxy for JIT
   eligibility or activation.
8. Separate compiled-artifact ownership from function source/prototype data so
   code pages, libraries, scopes, and active frames have an explicit lifetime.
9. Compile the JIT subsystem out of wasm and other permanently unsupported
   targets, including counters and observability hooks.

These changes deepen the native compilation module: representation and
semantic complexity remain behind one lowering interface, while C and machine
code are two real adapters at the backend seam.

## 11. Delivery phases

### Phase 0 — shared native core

- Define `NativePlan`, native representations, call descriptors, and lowering
  errors.
- Implement resolved-function/GIR-to-structured-region lowering, including
  nested blocks, typed join values, structured exits, and source locations.
  Value identities are SSA-numbered, but CFG construction is private to machine
  adapters and the C adapter receives structured control flow.
- Move both existing AOT proofs (`isTypedNativeAotExpr` and `detectAotExpr`)
  into `lower_native`; no legacy C lowering route remains.
- Make the C backend consume the plan. This is the highest-risk refactor in the
  phase because lowering decisions currently live near C emission; preserve
  behavior and the existing boxed ABI, not byte-for-byte generated C.
- Introduce the deep `invoke_native_entry` runtime module with its private
  `NativeEntryFrame`; migrate generated boxed AOT entries to uniform thunks at
  that interface before JIT stubs depend on it.
- Extend AOT manifests with versioned full descriptors and symbols for
  discoverable unboxed bodies, while retaining boxed entries as a distinct
  surface.
- Differentially test VM and old/new AOT output before adding machine code.

### Phase 1 — explicit JIT

- Implement `off` and `explicit`, `^jit true`/`false`, status reporting, and
  supported-host checks.
- Compile on first call and publish an owned artifact atomically.
- Start with fixed scalar arithmetic, control flow, loops, and direct calls;
  add native fields and typed FFI operations by implementing existing plan
  operations, not new lowering rules.
- Categorically reject fexprs and every suspending or structured-task function;
  verify borrowed-view region lifetimes across direct native call chains.
- Support arm64 and x86_64 through separate machine adapters. Shipping one
  first is allowed, but architecture-specific behavior stays out of the plan.
- Implement entry guards, invalidation, W^X code memory, and safe retirement.
- Compile the entire subsystem out of wasm and other unsupported targets.

### Phase 2 — runtime critical-code selection

- Add `auto`, entry/backedge counters, a bounded compilation queue, and a code
  memory budget.
- Prioritize `^jit true` and runtime `compile` requests over inferred hotness.
- Cache rejection and expose reasons through status/profiling tools.
- Measure counter overhead, warm-up time, compilation pauses, steady-state
  speed, code size, and artifact churn.
- Benchmark the exact counter insertion point in repeated batches before
  enabling `auto`; do not automatically compile existing VM `nativeOp`
  functions until JIT wins against that tier directly.
- Do not claim OSR: newly compiled code begins at a later function entry.

### Later phases

- Background compilation where supported.
- Safepoints, general deoptimization, and on-stack replacement.
- Scheduler-parkable native frames with suspension, cancellation, migration,
  and unwind state maps; this is required before `yield`, `await`, channels,
  timers, or structured-task control enter a plan.
- Checked arbitrary-precision `Int` fast paths with promotion/slow paths.
- Profile-guided specialization of boxed calls and receiver types.
- Debugger breakpoints, single-stepping, and native variable inspection. Phase
  1 still emits source-mapped logical Gene frames for errors and stack traces;
  `^jit false` keeps a function in the VM for interactive debugging.
- Additional code-generation adapters such as Gene-to-wasm when they can
  consume the same plan honestly.

## 12. Verification and performance gates

Required tests include:

- differential VM/AOT/JIT results and errors for every plan operation;
- integer boundary and overflow behavior, including proof that `Int` does not
  silently wrap as `I64`;
- nullable native pointers and borrow/copy/transfer behavior;
- direct-call and protocol-send invalidation after reload/activation;
- cross-module overlays taking effect after a compiled call site exists;
- FFI library and captured-overlay lifetime while code is active;
- concurrent publication, invalidation, and code retirement;
- JIT-disabled and executable-memory-denied fallback;
- explicit-request diagnostics and `--jit-required` enforcement;
- exact AOT/JIT native-call descriptor matching, with boxed fallback on an ABI
  mismatch;
- the `invoke_native_entry` interface across both C and machine thunks,
  including acquisition rollback, `Buffer` copy-back, and roots for borrowed
  `Str`/`C/Slice` storage;
- rejection of borrowed-view escape across direct native call chains;
- managed-value rooting across entry adapters and proof that Phase 1 native
  frames contain no unreported managed roots;
- categorical rejection of fexpr and suspending/structured-task functions;
- proof that a guard mismatch after native side effects falls back only at the
  guarded operation and never restarts the function;
- proof that unsupported builds compile out encoders, executable-memory code,
  counters, and JIT payload; and
- identical behavior before and after an `auto` threshold is crossed.

Benchmarks report at least:

- VM, AOT, and warmed JIT throughput for the same source;
- warmed JIT against the VM `nativeOp` fast path for every operation class that
  `auto` proposes to retier;
- first-call lowering plus compilation latency;
- `auto` counter overhead on cold and non-lowerable functions, measured at the
  exact proposed insertion point before that location ships;
- allocations during lowering, compilation, and steady-state calls;
- generated code size and retained dependency memory; and
- invalidation/recompilation cost.

`nimble perf` must show that disabled/explicit mode does not add avoidable work
to ordinary VM calls, but a single aggregate run is not sufficient evidence.
Native boundary throughput also runs through the focused
`examples/native/bench_fib.sh`-style benchmark, because entry marshalling costs
can disappear inside the general suite. Any claimed mover must reproduce across
multiple interleaved before/after batches and have a mechanism consistent with
the result; report medians and dispersion, not one favorable sample.
Performance regressions are not hidden behind expected future JIT gains.

---

# Incorporated review record (2026-07-29, non-normative)

The normative sections above incorporate the recommendations below. This
record is retained as design rationale and describes the pre-review draft;
quoted wording and section descriptions in it are intentionally historical.
All nine comments were accepted. Their resolutions live in §§2.1, 3.1–3.4,
4.3–4.4, 5–7, 9–12. The only clarification is that template macros may expand
to lowerable ordinary code; runtime fexpr execution itself is ineligible.

Written immediately after hardening the `typed_native` dynamic boundary
(`native-type.md` §6.4, commits `058e054..33edca4`), so §§3–4 and §7 here are
checked against code rather than recalled.

The central decision — one `lower_native`, with a successfully produced plan
*being* the eligibility proof, and no separate `is_jit_eligible` pass — is
right, and it is the most valuable sentence in the document. Every silent
miscompilation the typed_native backend has produced came from analysis and
emission independently re-deriving lowerability and disagreeing. `aotLoweringGap`
(`gir.nim:1428`) exists only to convert such a disagreement into a hard error,
and it caught two real bugs during that work. Under a plan the disagreement
becomes structurally impossible, which is a genuine improvement — but note the
corollary: the safety net disappears with it. Any place a backend re-derives
something from source after Phase 0 loses both the guarantee and the guard.

The comments below are ordered by cost of getting them wrong.

## 1. Putting SSA in the plan forces structured-control-flow reconstruction in the C backend

§3.1 requires the plan to carry "a typed SSA control-flow graph with explicit
join values", and §11 Phase 0 requires the C backend to consume the plan. Those
two together mean the C emitter must rebuild structured control flow from a CFG:
a relooper/Stackifier pass. That is a real algorithm, it is new, it is a
recognized source of subtle bugs, and it makes generated C substantially less
readable — which matters for a backend whose output is currently inspectable and
is inspected in tests.

Nothing in the language requires paying that. The lowerable subset is
*structured by construction*: statement position admits only `let`/`var`, `set`,
`set`, `do`, and `while` (`compiler.nim:2952`), and `if` is a three-arm
expression that lowers to a ternary. `break`, `continue`, `return`, `for` and
`try` all exist in Gene (`compiler.nim:7517`) and none of them is lowerable.
There is no `goto` and no irreducible control flow to represent.

Recommend the plan carry **structured** control flow — nested blocks, `if`,
`while`, typed expression trees over SSA-numbered values — and make CFG/SSA
construction a private detail of the machine adapter, which is the only backend
that wants it. This stays viable as the subset widens: `break`, `continue` and
early `return` are structured-with-exits and emit as labelled breaks in C, so
the structured form does not become a dead end.

If SSA in the plan is kept deliberately, Phase 0 should name the relooper as a
deliverable and budget it, rather than have it emerge as the reason the
"highest-risk refactor" overran.

## 2. There are three lowering analyses today, and the proposal unifies one

`aotExpr` is selected by two mutually exclusive analyses
(`compiler.nim:3336-3378`): `isTypedNativeAotExpr` when the signature carries
native representations, and `detectAotExpr` otherwise — the older,
representation-homogeneous scalar path. A third, independent analysis,
`detectNativeCompileOp` (`compiler.nim:3054`), produces the VM's own `nativeOp`
fast paths (`ncoI64Add`, `ncoF64Mul`, …) consumed at `vm.nim:14873`, with no C
involvement at all.

§10.2 and Phase 0 speak of "the existing typed-native proof" as if there were
one. Two concrete consequences:

- Phase 0 must state whether `lower_native` subsumes the scalar `detectAotExpr`
  path or leaves it standing. Leaving it standing preserves exactly the
  duplicate-subset hazard §3 is designed to remove, and that path has no
  `aotLoweringGap` equivalent.
- `auto` mode needs a stated rule for functions that already have a VM
  `nativeOp`. Those are *already* the small fixed-scalar shapes a baseline JIT
  targets first, so they will trip any hotness counter immediately, and
  compiling them buys the least. Either they are excluded with a reason, or the
  benchmark in §12 must show the JIT beating the existing fast op rather than
  the generic VM path — otherwise `auto`'s first measured win is against a
  strawman.

## 3. Entry adapters are more than validators; per-call marshalling storage needs a home

§4.3 says AOT dynamic entries and JIT entry stubs "reuse the same scalar
validators and managed-wrapper borrow/copy/transfer operations". That
undercounts what an entry adapter now does. Two cases from the current boundary:

- A `Buffer` argument is not borrowed. Every element is unmarshalled into
  storage owned by the call's `AotContext`, the callee writes through it, and
  the bytes are copied back at an explicit `gene_ffi_buffer_finalize` after the
  callee returns. It is a two-phase acquire/finalize protocol with live storage
  in between, not a validator call.
- A `Str` (and a `C/Slice`) yields a pointer *into the boxed argument's own
  storage*. It is valid only because the boxed argument is rooted for the
  duration of the entry.

The generated-C adapter has somewhere to put all of this: it declares locals and
sequences the finalize calls. A machine-code entry stub does not. Two
recommendations:

- The JIT entry stub should not open-code marshalling. Have it call one
  descriptor-driven entry adapter in the runtime, so both tiers share the
  acquire/finalize protocol and the storage's lifetime, not merely the leaf
  validators. This also keeps §10.5 ("do not add JIT-specific conversion rules")
  honest, which the AOT side now satisfies literally — every `gene_ffi_arg_*` /
  `gene_ffi_result_*` helper delegates to the interpreter's own converters.
- Make "a borrowed `CStr` or buffer view may not outlive the entry that produced
  it" an explicit plan-level lifetime rule. Today it holds because the subset
  offers no way to store one. Once a plan permits JIT→JIT direct calls, a
  borrowed pointer can flow through several native frames whose combined
  lifetime is bounded only by the outermost entry, and §4.4's "Phase 1 native
  code keeps no managed values" means no native frame roots the `Str` itself.
  That invariant should be stated where it can be checked, not left implicit in
  what the subset happens to exclude.

## 4. The activation epoch, as it exists, is too coarse to be a per-artifact dependency

§7 lists "protocol implementation activation epoch" among the facts an artifact
records, and §5 correctly insists mutable facts stay out of the specialization
key. But `implEpoch` is a single global counter bumped by *every* impl mutation —
canonical, scoped, overlay, staged activation, `import_impl`, reload
(`vm.nim:7777` and following). With per-function artifacts, "re-validate when
the epoch moves" is O(artifacts x mutations), and any program that installs impls
during startup or per-request invalidates the entire code cache repeatedly.

The native-type work just landed is a working precedent for the mechanism *and*
for the granularity lesson. `nativeTypeEpoch` bumps only when a registered
type's **contract fingerprint** changes, explicitly not when a fresh `Type`
object is minted for an identical declaration — because recompiling the same
source mints a new `Type` every time, so keying on object identity would have
made every module load invalidate every loaded library. Getting that wrong is
not a slowdown; it is a cache that never hits.

Recommend §7 state the granularity requirement directly: guards are keyed to the
specific dependency (protocol + receiver generation, callee generation, type
contract fingerprint), and a global epoch is admissible only as a cheap gate in
front of a finer check, never as the dependency itself. Also worth adopting:
re-validation failure should be **sticky** per artifact
(`ensureAotModuleValid` marks a module permanently invalid), so a
permanently-broken artifact stops re-walking its requirement set on every call.

## 5. The suspension exclusion is load-bearing for the M:N scheduler and is currently incidental

Both lowering paths bail on `checksErrors or sawYield` (`compiler.nim:3161` and
`3357`). That exclusion is what currently makes it safe to run a native frame
the scheduler cannot park, migrate, or unwind — and it reads today as a subset
limitation rather than as the safety property it is.

§4.4 addresses the GC dimension (root maps, safepoints) and defers it well. The
*scheduler* dimension is distinct and unnamed. With VM call/control paths now on
a heap frame stack and an M:N scheduler as the next major arc, a JIT frame that
can suspend is a scheduler problem before it is a GC problem: a native frame has
no representation the scheduler can move between threads or park on a channel.

Recommend §7 promote this to a stated Phase 1 rule with its reason — no function
that can suspend or that participates in structured-task control flow is
lowerable — and §11's later phases list scheduler-parkable native frames beside
safepoints and OSR, since widening the subset without it produces a frame the
scheduler cannot account for.

## 6. Direct JIT-to-AOT calls need manifest data that does not exist yet

§4.3's descriptor matching assumes an AOT manifest publishes enough to validate
an unboxed call. It does not. `gene_aot_module` rows are
`{gene_name, c_symbol, entry_symbol, repr, arity, frame}` where `repr` is only
the *return* representation as a string — there are no per-parameter
representations, no target triple, and no calling-convention version. The
unboxed body (`gene_native_foo(CNode *n)`) is a plain C symbol published
nowhere; only the boxed `^native_entry` wrapper is discoverable.

So §4.3 implies a new manifest section describing unboxed bodies. Worth saying
so explicitly, because it is the difference between "match a fingerprint" and
"design and version a second ABI surface".

The dependency-contract half, by contrast, is already there and closer to §10.4
than the document assumes: `gene_aot_native_types` publishes
`{type_identity, abi_identity, abi_fingerprint, contract_fingerprint}` per
transitively-required type, `gene_aot_abi_layouts` publishes measured
`sizeof`/`alignof`/`offsetof`, `AbiFingerprintVersion` versions the hashing rule,
and `AotTypeRequirement` / `validateAotTypeRequirements` are already the
in-memory form the JIT would read live. The contract fingerprint deliberately
covers policy as well as layout (`^copy`, `^release`, `^wrapper`, `^mutable`,
`^lifecycle`, and the handle's declared type), because compiled code bakes those
in as call targets and lowering decisions — a JIT artifact bakes in exactly the
same things, so it should reuse the same fingerprint rather than define a
narrower one.

## 7. `auto` counters land inside active call-path perf work, and the noise floor is high

Two methodological points for §12, both from repository history rather than
principle.

Counter *placement* is the entire cost. Previous attempts to widen hot VM types
for caching (`Instruction`, `NamedArgs`) were rejected on benchmark evidence,
and the current perf arc is operand-stack registerization — the same code a
per-entry counter has to touch. §12's "counter overhead on cold and
non-lowerable functions" is the right gate; it should also require that the
chosen location be benchmarked before `auto` ships, not after.

And `nimble perf` alone is not sufficient evidence. This repository has a
documented bench noise floor high enough that a mover is only real if it
reproduces across batches *and* has a mechanism. Concretely, during the boundary
hardening I introduced an 11% regression in AOT boundary crossings — an eagerly
formatted error string on the success path, ~275 ns per crossing — and `nimble
perf` did not show it at all; `examples/native/bench_fib.sh` did. §12 should
name the boundary benchmark as a separate required gate and state the
reproduction bar, since "explicit/off mode costs nothing" is exactly the kind of
claim a single run cannot support.

## 8. wasm needs compile-time exclusion, not just a runtime disable

§2 and §9 disable the JIT where W^X cannot be guaranteed, which is a runtime
decision. `web/gene.wasm` is a tracked artifact where size is a user-visible
cost, and two instruction encoders plus executable-memory management that can
never run there should not be linked in at all. The `geneWasm` / `emscripten`
defines already gate other subsystems this way (`vm.nim:25`). One sentence in §9
turns a runtime policy into a build guarantee.

## 9. Smaller, still concrete

- **`^out` address-of-local is missing from §10.3's list** of operations that
  must become explicit plan operations. It matters specifically for the machine
  adapter: taking a local's address forces it to a stack slot and constrains
  register allocation, and that constraint must be visible in the plan rather
  than discovered by the allocator.
- **§2.1's mechanism already exists.** `requiresTypedNative`
  (`compiler.nim:3366`) raises a source-located diagnostic when an explicit
  request cannot lower and otherwise silently falls back to VM code — precisely
  the `^jit true` / `--jit-required` split. Reuse it rather than build a parallel
  one, and keep the two markers' diagnostics phrased alike.
- **Fexprs and macros go unmentioned.** Explicit fexprs and ctor fexprs receive unevaluated
  forms and a snapshot caller-env; they can never form a plan. §2.1 promises a
  diagnostic "naming the first unsupported operation", but for a fexpr the honest
  diagnostic is categorical. Worth one line so the failure is a clear rejection
  rather than a confusing per-operation complaint.
