# Authority, evaluation, and capability boundaries

This is the version-1 authority contract. The [proposal](../proposals/capabilities.md)
contains the complete semantics and acceptance cases; the
[implementation tracker](../implementation/capabilities-v1.md) distinguishes
implemented paths from outstanding integration. Native execution commands now
use the empty startup default and explicit source admission. Embedding applications
also start with normalized empty authority. Remaining adapters, legacy internals
and full application workflows are still being migrated.

## Separate the layers

| Layer | Responsibility |
| --- | --- |
| `Env` / `CallerEnv` | Supply names and values for evaluation; an Env can also retain a separate authority ceiling. |
| Namespace exposure | Controls which APIs code can name directly. |
| Capability context | Authorizes external operations through trusted providers and adapters. |
| Resource handle | Identifies a resource with retained origin, identity, and mode restrictions. |
| Execution policy | Bounds execution time, steps, and memory; loader policy also controls admitted sources and declarations. |

A visible filesystem API grants no permission to read. Hiding a namespace does
not revoke a callable or resource already supplied through a binding. Ordinary
in-memory mutation remains possible without external-operation authority.

## Inert policies and trusted grants

A capability row describes constraints; constructing one never grants authority.
Only the host establishes root grants using the frozen provider catalog. Source
name resolution, application types, and scoped implementations cannot replace a
provider or its authorization behavior.

```gene
[(fs/Read "/srv/app/data")
 (net/Http ^hosts ["api.example.com"] ^methods ["GET"] ^^optional)]
```

The row is inert. Heads are catalog identifiers and values are restricted data,
not expressions or variable references. Duplicate properties, unknown schemas,
reader extensions, and malformed optional entries are errors. `fs/*` expands the
admitted namespace at normalization; there is no row-level `*` inheritance form.

Entries are independent alternatives. A grant must match a complete operation;
fields from unrelated grants cannot be combined. Separate authority rows
intersect. Mandatory admission can collectively cover provider-defined request
alternatives while preserving every entry's field correlations and live-grant
provenance. A bounded proof can report that coverage cannot be established.

Capability identifiers exist in the trusted catalog, not as callable values in
ordinary Gene namespaces. Use `$capabilities/parse` for authored policy text or
`$capabilities/entry` with `$capabilities/build` for runtime values. Calling a
policy value is an error. `type ^capability`, Gene `CapabilitySpec` canonicalizers,
the old constructor exports, and the selector-based `check_capabilities` API
have been removed. The old `capabilities_of` and `capability_type_info` reflection
functions are also removed; their selector representations do not describe the
new contract. Callable contracts remain in compiler/runtime metadata, including
inherited mandatory/optional obligations and the absent-versus-empty distinction.

Use `$capabilities/check_requirements` with an immutable row to ask about
mandatory admission, or `$capabilities/check_operation` with provider-prepared
facts to ask about one concrete operation. An empty requirement row is valid.
Neither check reserves permission, and overlapping complete live grants are
alternatives rather than an ambiguity error. Dynamic resource names belong in
the checked builder, not in static declaration literals.

`fs/Read`, `fs/Write`, and `fs/ReadWrite` replace the old file/directory capability
names. Filesystem roots are literal tree selectors, not string prefixes or glob
patterns. Relative declaration roots use the declaring source file's directory;
ordinary relative filesystem operations use the provider's captured launch
working directory. Narrowing a policy does not change where relative I/O resolves.
The [filesystem profile](../implementation/capabilities-filesystem-profile.md)
defines descriptor-based resolution and rejected operations.

Filesystem reads and writes use guarded, unbuffered descriptors. Retained native
handles preserve their original binding, identity, mode and authority; later use
cannot borrow a broader caller's grants to replace a revoked origin. Atomic
writes guard staging and publication separately. Denial before publication leaves
the destination unchanged. Cleanup closes owned descriptors, but removing a
staging entry still needs live write authority, so a failed write can leave a
temporary entry. A durability error after publication can leave the complete
replacement in place. The profile defines these failure and cleanup cases.

## Requests and upper bounds

| Form | Entry rule | Execution authority |
| --- | --- | --- |
| Omitted callable declaration, without an inherited contract | No additional request boundary. | Actual caller intersected with all applicable retained/loader ceilings. |
| `^capabilities []` | Admission succeeds. | No selected external-operation authority. |
| Callable request row | Every mandatory entry must be covered; optional entries do not block entry. | Available authority intersected with the complete request row. |
| `with_capabilities row` | No full-coverage requirement. | Available authority intersected with the bound. |
| `require_capabilities row` | Mandatory admission before the block body. | Available authority intersected with the request. |

```gene
(fn fetch [] ^capabilities [(net/Http ^^optional)]
  # Enter even without HTTP; any attempted request still needs its real guard.
  42)

(with_capabilities [] (untrusted_callback input))
(require_capabilities [(fs/Read "/srv/app/data")] (read_index))
```

Optional entries select their exact available overlap, possibly none. They do
not disable guards or promise that all operations in a family are available.
Invalid metadata remains an error. Optional entries can report an inspection
failure without adding an entry precondition; they do not relabel it as ordinary
unavailable authority or authorize an operation through a failed provider.
Pure bounds reject optional metadata, including explicit false.

The callee's boundary is installed before its default arguments and body run.
Explicit argument expressions follow the caller's ordinary evaluation schedule;
wrap the whole call to restrict those expressions too. Return, loop exits,
exceptions, suspension, and cleanup restore the enclosing execution context.

Protocol implementations and method overrides inherit one effective contract.
An omitted replacement annotation inherits it; an explicit row must match the
normalized inherited contract, including mandatory/optional obligations and
absent-versus-empty distinctions. Relative paths retain their original base.
Direct, held, bound, adapted, and protocol calls enforce the same target contract.
Wrappers add restrictions and never replace the target's requirements.
Module request annotations, open/strict capability modes, parameter-dependent
selectors, and `require_strict_dependencies` are removed.

## Dynamic policy values and checks

The public constructors return immutable values:

```gene
(var from_text
  ($capabilities/parse "[(fs/Read \"data\")]"
    ^base "/srv/app" ^source "application settings"))

(var entry
  ($capabilities/entry "net/Http" []
    [["hosts" [($capabilities/pattern "*.example.com")]]
     ["methods" ["GET"]]]))
(var bound ($capabilities/build [entry]))
(with_capabilities bound (work))
```

`entry` takes a capability name, positional-value list, and property-pair list.
Its optional fourth Boolean supplies request optionality. Pairs preserve duplicate
names for validation. Runtime strings are literal by default; `pattern` marks
an explicit pattern and the zero-argument `$capabilities/any` constructor marks
an unrestricted value. The provider must support the selected constraint kind.
`build` copies and validates entries; later changes to the input lists do not
alter a row. Neither constructor executes capability heads.

`parse` and `build` accept `^base` and `^source`. A supplied base is absolute;
relative resource selectors require a base. Without relative resource values,
the base can be omitted. A dynamic boundary operand is evaluated once and must
produce a checked `CapabilitySpecRow`, not an ordinary list or map.

```gene
(var report ($capabilities/check_requirements bound))
report/admitted

(var prepared ($net/http_client/prepare "GET" "https://api.example.com/status"))
(var description ($net/http_client/describe_operation prepared))
(var decision ($capabilities/check_operation description))
decision/allowed
```

A requirement report preserves mandatory versus optional results. An operation
decision concerns one validated concrete operation. Both use the active context,
return read-only data, and neither performs the effect nor reserves permission.
Requirement entries distinguish `provider_failure` from unmatched coverage and
incomplete proofs, with a safe `failure_scope` of `entry` or `shared`. A complete
independent proof can satisfy an entry-local failure; a shared failure prevents
that requirement from matching. Admission still depends only on mandatory
entries. Required boundaries raise `CapabilityProviderError` when a mandatory
provider failure remains, preserving its internal cause.
HTTP preparation is pure. `await ($net/http_client/send prepared)` sends the
prepared request under the actual caller's authority. `request` and `stream`
prepare their named arguments through the same validation and guard path.
The native worker obtains a fresh live-authority decision when it is ready to
start; a queued request cannot rely on its earlier successful check. Redirects
are returned to the caller, and following one requires another guarded request.
The initial transport rejects proxies, target/framing overrides, CONNECT and
protocol upgrades, and does not retain cookies or managed authentication.
Trusted adapters independently derive and guard the operation they actually
perform, including redirects and retained-resource reuse.

Guard denials are recoverable `MissingCapability` errors with the capability,
operation, and stable `reason`; available decisions also identify `authority_row`.
Provider evaluation failures use `CapabilityProviderError`, and invalid operation
facts use `CapabilityTypeError`. Internal exception chains preserve provider
causes without exposing credentials or live authority objects. Unsupported
operations use `UnsupportedCapability`; ordinary filesystem failures remain
`OsError`. Optionality does not suppress any of these failures.

## Retained and deferred execution

| Boundary | Authority rule |
| --- | --- |
| Plain closure | Invocation uses the actual caller and applicable declaration/loader/eval ceilings. Creation inside a temporary block alone captures no extra ceiling. |
| `runtime/bind_call` | Captures its creation ceiling and intersects each invoker. Optional `^capabilities` accepts an immutable policy row, as an additional bound. |
| Callable adaptation | Preserves target contracts and retained restrictions. |
| Env / eval | A supplied Env row captures creation authority; evaluation also intersects every parent Env ceiling and the evaluator's context. Escaped eval functions retain that result. |
| Generator and lazy pipeline | Retain creation/execution ceilings; pull and close also apply the consumer's ceiling. |
| Spawned task | Captures the effective spawn context, preserving it across suspension and resumption. |
| Callback-retaining API | Captures registration context even for an existing function; dispatch intersects registration, callable origin, and dispatcher ceilings. Each adapter requires coverage. |
| Resource handle | Every data operation requires current and origin authority plus resource identity and mode restrictions. |

Env name bindings use `^bindings`; `^capabilities` accepts an inert bound or an
immutable policy value. The legacy capability-map name overlay is rejected.

```gene
(var saved (env ^bindings {^input "hello"}
                ^capabilities ($capabilities/parse "[]")
                ^policy {^max_steps 10000}))
(eval (quote input) ^in saved) # "hello"
```

Omitting the Env bound adds no ceiling; an explicit empty row remains empty.
`Env/extend` and `^parent` cannot remove parent ceilings. An Env controls neither
all accessible names nor arbitrary mutable references. It is not a complete
untrusted-code isolation boundary. Eval imports remain restricted to its
supported dependency/binding path, and execution budgets compose separately.

Release-only cleanup may close an owned resource after revocation. It may not
flush buffered application writes or perform unrelated effects using host
privileges. A previously obtained handle does not authorize later I/O by itself.

## Modules, startup, and rollout

Ordinary initialization executes under caller authority intersected with admitted
loader/origin policy. Its instance domain includes owner, source/catalog revision,
loader policy, and a canonical authority-domain key. Independently initialized
domains own distinct nominal types and protocols. Explicitly shared, preinitialized
contract instances provide shared identity. Compile-time and runtime bindings
must select the same domain; equivalent fresh context objects do not create new
identities. Ordinary normalized imports retain their initialization ceilings and
use authority-specific instances. Native sandbox directories now capture immutable
source bundles through no-follow filesystem reads, and source policies survive
calls and Env values. Other acquisition modes, concurrency and initialization
cleanup remain part of the [loader integration gate](../implementation/capabilities-loader-profile.md).

The target startup precedence is an explicit CLI row or CLI-selected capability
file, then `GENE_CAPABILITIES`, host configuration defaults, and finally the
built-in empty policy. Multiple CLI policy sources are rejected. Each selected source replaces lower-priority
sources; independent administrator ceilings still intersect it. Invalid selected
sources fail without fallback. Private source/configuration acquisition and
runner diagnostics do not lend authority to application code.

Before switching a backend to the empty default, every effectful API, alias,
native path, and retained operation must be classified as guarded, private host,
explicitly capability-free, or unsupported. The initial filesystem/HTTP profile
does not implicitly exempt application output, live environment access, stdin,
clocks, entropy, databases, subprocesses, or arbitrary native code. Unsupported
families must reject operations until their contracts and adapters are adopted.
See proposal section 10.10 and the implementation tracker for rollout gates.

## Native callable admission

The [native inventory](../implementation/capabilities-native-inventory.md) assigns
every registered native implementation an explicit disposition. That immutable
metadata is attached by trusted constructors; a display name, alias, bound call
or callable adaptation cannot supply or erase it. Unclassified extensions and
unsupported operations reject before the native implementation runs. Guarded
adapters still check the actual operation and live authority at the effect site.

For host extensions, `newNativeFn`, `newNativeCallFn` and the explicit overloads
of `geneModuleDefineNative` / `geneModuleDefineNativeCall` accept `effectKind`.
The default is `nekUnclassified`. Use `nekCapabilityFree` only for an audited
in-memory operation, or `nekGuarded` for an adapter that performs its own effect
guard. This is a trusted host declaration, not a proof that arbitrary native
code is safe. Arithmetic fast paths are reserved for admitted builtin
implementations; naming an extension `+` does not select one.

A guarded Nim adapter obtains the effective context with
`activeCapabilitiesForCall(call)` and passes that context to the admitted provider.
It must not substitute `app.rootCapabilities`. `raiseCapabilityOperationError`
translates provider failures and denials into the shared safe Gene errors.
Call-aware native adapters receive an opaque captured context in `NativeCall`;
that context is still intersected with any active caller and retained ceilings.
Direct SDK calls with a dispatch scope establish that scope's current and retained
ceilings for the native body and its nested calls, then restore the caller.

The native API version is 5. The older registration overloads keep their argument
shapes but create unclassified callables; older native binaries must be rebuilt.
The ordinary startup policy, callback adapters currently rejected by the initial
profile, and private host admission still need their remaining rollout work.

## Verification scope

Core reader, algebra, provider, and domain tests are separate from actual-adapter
and execution-boundary tests. The focused suites include
`test_capability_boundaries.nim`, `test_capability_deferred.nim`,
`test_bound_call.nim`, `test_pipeline.nim`, and `test_unify_callable.nim` for
invocation, evaluation, suspension, and retained ceilings. Filesystem tests
observe real effects; HTTP policy tests alone do not establish transport safety.
Passing these tests is not completion of the loader, startup, effect-inventory,
callback-adapter, or Harness migration.
