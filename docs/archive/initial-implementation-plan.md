# Initial implementation plan and design notes

**Status:** historical; superseded by the [implementation status](../implementation-status.md)
and [implemented specification](../spec/README.md). This preserves former
design chapters 19–21, including outdated deferrals, for historical references.

## 19. Implementation order

1. Reader + canonical node model: props, meta, templates, spread, pipe, dot sends, slash selectors, qualified-name/path tokens, `/` tokenization, and `#[]`/`#{}`/`#()` literals.
2. Runtime values, `nil`/`void`/`Never`, mutable and shallow-immutable containers, equality, hashing, `Cell`, and `AtomicCell` foundations.
3. Application/module foundation: `Application`, package discovery and manifests, module identity, root namespaces, `ns`, namespace imports, `from` module paths, normalized module identities, module cache, and top-level execution.
4. Callable-first evaluator: `var`, `set`, `do`, `if`, `fn`, `Call`, `Callable`, and dot sends.
5. First-class `Env`: immutable binding maps, parent chains, module/import resolution, capability/policy fields, and tracing-GC integration.
6. Native call foundation: `NativeFn`, opaque runtime API, native registration, rooting contract, and `gene_call`-style VM trampoline.
7. Selectors and functional updates: `/...`, `(select ...)`, `%` stages, missing/`void`, `assoc_in`, and `update_in`.
8. Streams and generators: `(Stream T E)`, `yield`, `next`/`peek`/`has_next`, declaration streams, and parser stream shape.
9. Cooperative task runtime: `(Task T E)`, `scope`, `spawn`, `await`, cancellation, timers, safepoints, and async-I/O suspension hooks.
10. Pattern/destructuring engine: `match`, `var`, `for`, and `catch`.
11. Basic nominal types, single inheritance, direct construction stamping, `new`/`ctor` with pre-created `self`, basic generics, numeric hierarchy, gradual boundary checks, and conditional `Send` checking.
12. Bounded typed channels with suspension, close semantics, and backpressure.
13. Protocols/messages, `Error` and `Send` marker protocols, and visible-implementation coherence.
14. Typed actors: `ActorRef M`, bounded mailboxes, sequential handlers, request/reply, scope ownership, and basic supervision.
15. explicit named fexprs, templates/quasiquote expansion, and hygienic template macros.
16. Protocol-local `derive` experiment.
17. `try/catch/ensure` checked errors and cancellation propagation.
18. `eval node ^in env`: normal compiler pipeline, isolated overlays, `CompileError`, captured overlay lifetime, policy enforcement, and CLI/REPL environments.
19. Formatter/docs: deterministic printing, module docs, namespace docs, declaration streams, and import normalization reporting.
20. Typed native compilation prototype: direct typed ABI, dynamic adapters, native-to-VM calls, primitive unboxing, and C backend experiment.
21. Generated C FFI wrappers: ABI scalar types, strings, pointers, buffers, opaque handles, and ownership.
22. Versioned native extension modules and runtime `$ffi/Load` capability.
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
5. **Callable evaluator:** implement callable-first evaluation, explicit fexpr dispatch, special forms, lexical bindings, `Call`, `SyntaxCall`, `Callable`, `Fn`, `Fexpr`, `NativeFn`, and dot message sends.
6. **Selectors:** implement selector literals, static and dynamic `%` stages, `void` propagation, strict/default options, list/map/node/module/namespace lookup, and functional update paths.
7. **Streams and parser pipeline:** implement `(Stream T E)`, `yield`, `peek`, `next`, `has_next`, `close`, `Never` error normalization, declaration streams, and stream-shaped reader/parser output.
8. **Errors:** implement `Error` marker protocol, `fail`, `panic`, `try/catch/ensure`, `CompileError`, `MatchError`, `TypeError`, `CallKindError`, and checked/dynamic `^errors` rules.
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
- typed rest parameter declarations, `NativeFn` signature types, and `Fn`-type
  parameter/result variance beyond usable-as arity admission;
- static effect rows;
- distributed actors and GPU kernel/device-execution policy.

---

## 21. Settled design notes

- Every `gene run` starts an `Application`, loads an entry package/module, executes the entry module top to bottom, and calls `main` when present.
- A module has a root namespace. Nested namespaces use `ns`. Imports can read from built-in namespace paths or from normalized module path strings using `from "path"`; package dependency management is deferred.
- `Any` is the MVP top gradual type. A separate static root such as `Value` is deferred.
- `Never` is the bottom type and has no runtime values. `Nil` and `Void` are singleton types under `Any`, not bottom types.
- `nil` is explicit absence, not the default uninitialized value for typed lists, maps, or variables. Use `T?` or `(? T)` when `nil` is allowed.
- Every value has a canonical Node representation: `head` is its runtime type and `body` its observable content — a cell `c` holding `v` projects `(Cell v)` — and the pattern engine matches that representation uniformly. A cell's pattern bind is a read-only snapshot, and `leaf?` stops walks at cells.
- A `: Parent` type header supports single nominal inheritance only. Children inherit and preserve parent schema in MVP; multiple behaviors use protocols.
- Plain lists, maps, and nodes may be mutable; `#[]`, `#{}`, and `#()` create shallow immutable values. Strings are immutable.
- `Cell T` is local/non-thread-safe mutable state; `AtomicCell T` is the explicit linearizable shared-memory escape hatch.
- Actors are the preferred model for long-lived stateful concurrency, built on structured tasks and bounded typed channels.
- Actor and channel boundaries require `Send`; shallow immutability alone is not sufficient.
- Actors process one message at a time without reentrancy, use bounded mailboxes, and are owned by scopes or supervisors.
- Standard selector-stage names are `props`, `body`, `meta`, `declarations`, `to_stream`, and `to_pairs_stream`. These are ordinary callable stages, not selector magic.
- The collection operations — `map`, `filter_map`, `filter`, `take`, `to_stream`, `to_pairs_stream`, `into`, `each` — are generic functions (§6.2): one message identity per operation shared by the types that serve it, with the `$name` function spelling under the `gene` root. A bare send and the `$` call are the same receiver-first dispatch; there is no lexical fallback.
- Streams use `(Stream T E)`. `Never` contributes no errors, and error rows flatten and deduplicate.
- Dot message sends dispatch only — no lexical fallback. `(x .f a)` resolves `f` against `x`'s **type-direct** messages, walking nominal parents; a protocol impl is never reached by a bare name, and an unresolved name is a recoverable `MessageError`. `(x .P:f a)` names protocol `P`'s message `f`; type-direct message values use `Self:f`, not `T:f`. `(x .%m a)` sends a held message value; a dynamic callee that is not a message value is a `CallKindError`, so a dot send never invokes an arbitrary function. Message names are not bound in the enclosing scope, so a dot descriptor and a bare call `(f x)` never mix. See `docs/core.md §9`.
- Leading sends use lexical `self`: `(.f a)` means `(self .f a)` when `self` is in scope. `(super .f a)` delegates to the implementation above the enclosing type on the parent chain.
- `(T ...)` is always direct typed-data construction and never calls `ctor`; it is the canonical printable/serializable form for typed instances. `(new T ...)` invokes the nearest `ctor` in the type's ancestry with a pre-created in-progress `self`, and fails when the hierarchy has no constructor.
- `(fn name! ...)` defines a named runtime fexpr that receives raw syntax and a borrowed `CallerEnv`; only `(name! ...)` invokes it. Durable authority requires explicit named `snapshot` (on `CallerEnv`). `macro` is reserved for limited compile-time template expansion; full compile-time function macros are future work.
- Delegation is explicit protocol forwarding, written manually as `impl`s in MVP; future derive helpers may generate forwarding impls from selector paths.
- `Any`→typed boundary failures raise recoverable `TypeError` with blame. Internal typed representation contradictions are panics.
- Generic constraints are deferred until needed for generic derived implementations.
- Raw strings and binary literals are useful but not MVP.
- Static `^effects` rows remain deferred. Runtime authority lives in inherited
  capability contexts; Gene-visible capability specifications are inert requests.
- FFI starts with generated, statically checked C wrappers and a stable opaque native ABI. Runtime-created signatures come later.
- Native extensions use opaque `GeneValue`, explicit roots, and a versioned append-only runtime API table; Nim/VM heap layouts are never public ABI.
- Temporary FFI marshalling is call-scoped. Retained foreign memory requires explicit pointer/buffer ownership and deterministic cleanup.
- Escaping callbacks and arbitrary foreign-thread VM entry are deferred until scheduler/rooting rules are implemented.
- GPU/native compute builds on native modules, typed buffers, and opaque device-buffer handles; kernel compilation is a later design.
- Typed functions/modules can be compiled incrementally to native code, with boxed runtime-helper fallback for dynamic operations.
- Native code can call bytecode/dynamic Gene through a rooted `gene_call`-style trampoline; dynamic code calls native typed code through generated boundary adapters.
- The first AOT backend should probably emit portable C. LLVM/JIT can follow after semantics and the native ABI stabilize.
- Generic native code uses selective monomorphization with a boxed shared fallback.
- `eval node ^in env` compiles declarations into a separate overlay. Ordinary
  Env evaluation still has evaluation-site lexical fallback; name access and
  assignment follow that scope. A CallerEnv uses copies of caller bindings.
- `Env`, captured overlays, and cycles participate in tracing GC; native retention requires normal roots.
- Eval name resolution, capability ceilings, and execution policy are separate.
  An omitted selector row inherits the evaluator context; `[]` selects none.
  Retained Env/parent ceilings intersect with the evaluator and survive escaped
  eval calls. The implemented security contract is `docs/spec/authority.md`.
