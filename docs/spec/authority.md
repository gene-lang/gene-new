# Authority, evaluation, and sandbox boundaries

**Status:** normative for the implemented VM surface described here. The
[capability proposal](../capabilities.md) records broader design and
deferred work; it is not a claim that every proposed boundary is implemented.

## Separate the layers

| Layer | Responsibility |
| --- | --- |
| `Env` / `CallerEnv` | Supply names and values for evaluation. An `Env` may also retain a separate capability ceiling. |
| Namespace exposure | Controls which APIs a module can name directly. |
| Capability context | Authorizes external operations through trusted providers and adapters. |
| Resource handle | Identifies a resource, whose origin restrictions are checked together with the active context. |
| Execution policy | Bounds VM execution; sandbox loading also restricts declaration admission. |

These layers compose. A visible filesystem API does not grant permission to
read a file. Conversely, hiding a namespace does not remove a function or
resource already supplied through a binding or admitted shared module.
Access to Cells, closures, and caller values can permit ordinary in-memory
effects without granting filesystem, network, process, or native authority.

## Specifications, grants, and roots

Gene capability types and specifications describe requests. For example,
`(fs/ReadFile path)` is inert data; constructing it does not authorize a read.
Sealed grants and contexts are runtime objects, never ordinary Gene values.
Trusted providers own resolution, intersection, validity, and revocation.
Providers and facade descriptors are admitted by the host before the registry
freezes and before module initialization. Gene declarations cannot admit a
provider or mint a root grant.

The native CLI and ordinary host constructors have compatibility defaults:
filesystem access beneath the launch directory and the built-in host-provider
grants. `gene run` is therefore not a deny-by-default sandbox. Pre-entry
`--allow_read_dir`, `--allow_write_dir`, and `--allow_read_write_dir` options
add host grants; they do not remove the defaults. An embedder can replace the
root context through `setRootCapabilities` before entry materialization.
Root grants are frozen after that point. Module discovery paths and filesystem
grant roots are independent.

`main` receives program arguments, not grant values. Strings such as `--grant`
after the entry file are ordinary data. See [modules](modules.md).

## Selection and invocation

`^capabilities [...]` selects from the available context. An empty list
selects none; `*` inherits the available context; `fs/*` projects the filesystem
grants already available. Mandatory selectors fail when unsatisfied. Optional
selectors permit execution without that grant, and operations still enforce
their requirements. `check_capabilities` tests the active context through the
same provider resolution; it does not mint or retain permission.

Open mode is the compatibility default. Strict mode requires declaration rows
where specified by the compiler. Changing mode does not widen runtime authority.
Function and protocol declaration rows select from the context remaining after
module, import-site, and retained ceilings have been applied.

For an ordinary invocation or evaluation:

```text
available = active invoker context ∩ applicable retained ceilings
effective = declaration/call-site selection from available
```

Intersection is provider-defined. It is not a comparison of grant object
identity or a re-resolution against the original host root. A retained context
is a ceiling, never a replacement for a narrower invoker context. Normal return
and exceptional exit restore the caller's dynamic context.

| Boundary | Implemented rule |
| --- | --- |
| Ordinary function/closure | Uses the invoker's context, constrained by its declaration and applicable module/eval ceilings. Creating a plain closure inside `with_capabilities` does not itself capture that temporary context. |
| Imported function/message | Intersects the invoker context with the callee module ceiling and applicable import-site ceiling before applying the declaration row. Module initialization is bounded separately. |
| `runtime/bind_call` | Retains the creating context and optional selection; each invocation intersects that ceiling with its invoker. |
| `eval` | Intersects the evaluator context with retained rows on the target `Env` and its parents. Functions created in that eval retain the resulting ceiling. |
| Generator | Retains execution context across suspension; a pull or close also applies the current consumer's ceiling and restores the consumer's context afterward. |
| Lazy `map` / `filter_map` / `filter` and `=>` | Retain their creation ceiling; demanding an item intersects it with the consumer context before upstream or callback execution. |
| Spawned task | Captures the context active at spawn; task-local narrowing does not mutate the parent. |

Do not infer callback registration semantics from ordinary closure capture.
An API that retains a callback must define its attachment and invocation rule.
Use `runtime/bind_call` when an explicit retained ceiling is needed. Arbitrary
foreign callback entry is not covered by this table.

## Environments and evaluation

Use `^bindings` for ordinary values and a selector list for capability selection:

```gene
(var e
  (env ^bindings {^input "hello"}
       ^capabilities []
       ^policy {^max_steps 10000}))
(eval (quote input) ^in e) # "hello"
```

Runnable examples: [Env ceilings](../../examples/capabilities/07_env.gene)
and [call-site attenuation](../../examples/capabilities/04_with_capabilities.gene).

An ordinary `Env` overlays explicit bindings, parent bindings, imports, and
module bindings on the scope where `eval` executes. It does not hide that
scope's names. A `CallerEnv` explicitly supplies the fexpr caller's bindings;
its named `snapshot` creates a closed capture with no evaluation-site lexical
fallback. Neither mechanism by itself creates external-operation grants.

The current `Env ^capabilities` syntax has two distinct forms:

- A **list** is a selector row, resolved against the creating active context.
  Its retained ceiling, and any parent Env ceilings, apply at every evaluation.
  `Env/extend` and `^parent` cannot remove a parent's capability restrictions.
- A **map** is a legacy name-binding overlay. It creates no grants and adds no
  capability ceiling. New examples should use `^bindings` for these values.

Without a selector row anywhere in the Env chain, evaluation inherits the
evaluator's context. An explicit `[]` restricts it to no external capabilities.
Passing an Env created under broader grants into a narrower context cannot
restore the removed grants:

```gene
(var saved (env ^capabilities [fs/*]))
(with_capabilities []
  (eval (quote ($fs/read_text "data.txt")) ^in saved))
# MissingCapability, even if saved was created with access to data.txt.
```

Eval's execution limits compose with the evaluator's limits and propagate
through calls. Its source-level `import` is rejected; dependencies must be
supplied through the supported Env import/binding path. This does not make
ordinary `eval` the sandbox-generation loader: an Env is not a complete
untrusted-code isolation boundary.

`allow_ffi` and `allow_native_compile` are accepted only as false in Env policy
data; they do not create authority or replace capability checks. The implemented
declaration restrictions of transactional sandbox loading are described below.
Do not treat an Env policy field as proof of general native-code isolation.

## Resources and native boundaries

An effectful resource operation must be authorized by both its origin
restrictions and the current context. Passing a handle into an empty context
does not delegate I/O permission. Origin metadata is internal to the runtime;
it is not a forgeable Gene property. Providers check grant validity at use,
including revocation of retained grants. Resource release/close operations
have their own cleanup rules and do not confer new operating permission.

`$ffi/open` takes a library path and checks active `ffi/Load` authority.
`$ffi/bind`, dynamic FFI invocation, and loaded AOT entries check retained
origin restrictions together with the active context. A library or callable
handle is not a substitute for that check.

Trusted providers, native adapters, and loaded native libraries are part of
the trusted computing base. Once arbitrary native code is admitted, the VM
cannot confine its direct host effects in-process. The web backend relies on
its host/browser environment and has no VM capability-context sandbox.

## Sandboxed module loading and publication

The `grants` strings accepted by `load_sandboxed` and sandbox-generation
preparation are **namespace exposure choices**, not resource capability grants.
For example, `["fs"]` makes filesystem APIs available to name; operation-level
capability checks still apply. `dir`, the shared-module allowlist, namespace
exposure, capability ceilings, and execution limits are distinct controls.

The compatibility `load_sandboxed` path initializes and publishes immediately.
Configuring its module afterward cannot retroactively constrain initialization.
Transactional preparation bounds compilation, macro expansion, initialization,
and escaped entries by its supplied policy. It rejects FFI, native/capability
type, and embedded-web declarations. Prepared module/compile caches, impls,
serde origins, and scopes remain prospective until atomic commit.

Commit checks the live module/impl base before publication. Discard and release
have explicit lifecycle rules. Admitted shared modules retain host identity and
policy, so the shared allowlist is part of the trust decision. A sandbox cannot
invoke the sandbox-management entry points itself; sharing a host wrapper that
performs privileged management still exposes that wrapper's behavior.
See [modules](modules.md) for the transaction lifecycle.

## Verification and limits of the claim

| Contract area | Executable coverage |
| --- | --- |
| Provider algebra, revocation, exact filesystem checks, resource reuse, module/import ceilings, Env intersections and escaped eval code | `tests/test_capabilities.nim` |
| Bound callback creation/invocation ceilings | `tests/test_bound_call.nim` |
| Pipeline creation/consumption and generator consumer ceilings | `tests/test_pipeline.nim` |
| Namespace restrictions, shared modules, escaped calls, prospective activation, and policy limits | `tests/test_modules.nim` |
| Env bindings, snapshots, evaluation policy, and runtime FFI surface | `tests/test_vm.nim`, `tests/spec_runner.nim` |

These tests establish specific implemented behavior. They do not constitute an
audit of every adapter, callback API, native extension, or backend. Stronger
sandbox claims require evidence for those boundaries rather than inference
from a namespace filter, an Env value, or the proposal's acceptance criteria.

A separate existing hang in eval-defined nominal types with methods remains
outside this coverage. The eval retention tests above cover functions and
generators; they do not certify that declaration path.
