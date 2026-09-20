# Capability version-1 implementation

The target is [the capability proposal](../proposals/capabilities.md), including
its complete acceptance matrix and implementation gates. This is a migration of
the shared capability system, not an additional authorization path.

## Delivery and evidence

| Work | State | Required evidence |
| --- | --- | --- |
| Restricted literal reader, immutable value builder, source bases and limits | Core, compiler literals, builders and native CLI sources implemented | Literal and startup suites cover syntax, duplicates, optional flags, injection, immutable copies, missing values, bases, precedence and limits. |
| Normalized provider constraints, exact intersections, conservative collective admission | Core and adopted FS/HTTP profiles implemented; remaining workflow providers pending | `test_capability_patterns.nim`, `test_capability_constraints.nim`, and `test_capability_policy.nim` exercise finite models, complete correlations, bounded inclusion, namespaces and collective coverage. |
| Live authority, validity-aware caches, origin contexts and decisions | Exact normalized execution contexts implemented; complete VM adoption pending | Policy tests exercise independent rows, stable domain keys after cache eviction, live resource availability/revocation, optional overlap and shared checks/guards. No admission-result cache is introduced. |
| Filesystem and HTTP profiles and actual adapter guards | Native FS/HTTP paths and provider-failure classification implemented; excluded effect families remain open | HTTP policy and recording-loopback transport tests pass, including queued revocation and alternate grants. Real filesystem read/write/metadata/rename/copy, atomic replacement, retained identity/mode/origin, and descriptor release tests pass. Logging, watcher, lock, database and other effect profiles remain separate rollout work. |
| Callable/block requests, optional overlap and restoration | Core compiler/VM boundaries implemented; adapter/backend audit pending | Boundary tests cover admission before defaults, optional overlap, dynamic bounds, lexical exits and restoration. Deferred tests cover task suspension and eval/generator ceilings. |
| Exact inherited contracts and all invocation forms | Effective contract resolution implemented; broader conformance audit pending | Boundary tests cover B22–B27, type-direct inheritance, protocol dispatch, held/bound/adapted calls, defaults, and revocation. |
| Module-domain prototype and loader migration | Domain/cache/linkage, retained policies, native snapshots, ordinary application admission and native launcher wiring implemented; remaining loader modes and lifecycle migration pending | Tests cover independent declarations, retained ceilings, frozen source revisions, no-follow capture, shared contracts, stable domains, failed generations, approved package dependencies and pinned artifact linkage. Remaining loader modes and lifecycle gates stay open. |
| Task/stream/callback/native ownership and ceilings | Normalized Env/bound-call/pipeline/generator/task paths tested; callback/native/resource audit pending | Deferred tests preserve creation and consumer ceilings, parent Env bounds, escaped eval closures, suspension and cleanup. |
| Startup precedence, approved source acquisition and empty default | Native launcher and embedding entry points use normalized empty authority; remaining workflow/host-control audit pending | CLI tests cover actual effects, aliases, replacement, empty/invalid sources, file bases, source admission, private host controls and verified project execution. Embedding tests cover empty construction, catalog-only extension, legacy/foreign context rejection, direct SDK calls and startup freezing. |
| Complete built-in effect inventory and backend enforcement | Native VM catalog and dispatch enforcement implemented; other backend/host-work audit and workflow providers pending | Explicit inventory covers 453 native identities after removal of six obsolete selector/facade natives. Aliases retain metadata, unknown additions fail the inventory check, unsupported calls reject before implementation, and guarded adapters keep real-operation checks. Other paths and supported application workflows remain rollout gates. |
| Existing documentation, examples and Harness/Cordis migration | Authority/workflow references and capability examples migrated; wider application migration pending | Capability examples run under explicit normalized policies. Remaining evidence: no conflicting public contract or legacy authority fallback; guarded Harness workflow supported under its explicit policy. |
| Full verification | Pending | Critical unit and adapter tests, relevant integration/spec suites, a complete Harness workflow and ordinary-script workflow. |

## Initial code findings

- `src/gene/capabilities.nim` already seals grants, tracks independent revocation,
  and interns contexts. Its selector resolution and grant-pair intersections do
  not implement the proposed row/predicate contract.
- `src/gene/fs_capabilities.nim` has POSIX handle-relative adapters to migrate.
  Its old `ReadDir`/`WriteDir`/`ReadFile` vocabulary and resource normalization
  need replacement by the adopted provider profile.
- `src/gene/host_capabilities.nim` treats HTTP as nominal/exact-argument scope;
  it cannot enforce hostname/method/component policy.
- Compiler/VM metadata admits parameter-dependent selectors, unrestricted
  row-level `*`, module request rows, and contract narrowing. These must migrate.
- The launcher adds built-in root authority and uses `--allow_*_dir` flags.
  Existing output/input and native paths must be inventoried before rollout.

The additional review specifically calls for prototyping module identity before
broad loader migration and completing the supported Harness workflow's provider
contracts rather than weakening the empty default. Both remain required work.

## Working sequence

1. Establish the inert representation and normalization primitives with focused
   tests; connect these to existing compiler, startup and provider seams.
2. Complete concrete provider/API profiles and prototype module domains. Keep
   unimplemented modes explicit; do not infer authority from an old adapter.
3. Migrate shared context/admission/guard evaluation, compiler/runtime boundaries,
   inheritance and deferred execution, then the loader and startup paths.
4. Complete the effect inventory, necessary workflow providers, public API and
   documentation/example migration.
5. Verify the full proposal requirements against implementation and test evidence.

Progress here is not a completion claim. The original objective remains open
until every delivery row has implementation and verification evidence.

## Current implementation and next integration

- `capability_literals.nim` is independent of Gene evaluation and providers.
  Its result is explicitly syntax-only; catalog validation is mandatory.
- `capability_constraints.nim` and `capability_patterns.nim` provide immutable
  predicates, exact retained intersections, and bounded language inclusion.
- `capability_policy.nim`, `capability_admission.nim`, and
  `capability_operations.nim` are included by the existing shared
  `capabilities.nim`. They use its sealed catalog, issued grants and revocation
  tokens rather than establish a second trusted provider registry.
- `capability_contexts.nim` connects the new rows to execution contexts, including
  stable domain identities and live root references. Mixing legacy and normalized
  authority is rejected instead of dropping new ceilings.
- The [filesystem profile](capabilities-filesystem-profile.md) has native guarded
  read/write/list/stat/mkdir/delete/rename/copy paths in `fs_capability_policy.nim`.
  Root acquisition and live availability preserve held resource identities.
  `fs_capability_handles.nim` now supplies opaque, unbuffered retained handles
  with per-chunk current/origin guards, fixed modes and binding/identity checks.
  Ordinary normalized reads/writes and atomic replacement use those handles.
  Atomic staging, publication and directory synchronization are separately
  guarded; abort closes descriptors and unlinks only under live authority.
  Application file logging explicitly rejects normalized execution before opening
  a raw buffered File; its output contract remains separate required work.
- The [HTTP profile](capabilities-http-profile.md) and `http_capabilities.nim`
  implement component normalization, preparation, validation and policy guards.
  The asynchronous native client now prepares actual request data and guards
  submission plus the ready worker's start. Its owner scheduler retains the
  complete context; native threads receive only private copied request data and
  a one-use start decision. The transport fixes request-target bytes, disables
  proxy/authentication/reuse modes, and rejects upgrades before body delivery.
  Pure preparation, operation descriptions, and `send(prepared)` are available.
  Recording loopback tests separately verify exact methods/query bytes, denials,
  redirects, proxy suppression, credential isolation, CA-file read checks,
  unsupported modes, queued revocation, redundant grants and cancellation.
- `capability_domains.nim` is a host-only prototype using the existing sandbox
  loader seam. It establishes owner/revision/authority/source-policy identity,
  preinitialized shared instances, compilation isolation and failure generations.
  Ordinary normalized imports now also use authority-domain cache keys and
  retained initialization ceilings. Host-selected shared instances, generation
  retries, pristine installed templates and portable capability-base linkage
  have dedicated tests; see the [loader integration profile](capabilities-loader-profile.md)
  for the still-required source-policy, concurrency and lifecycle work.
- `capability_source.nim` lowers source rows without name lookup or expression
  evaluation. Callable declarations and `with_capabilities`/`require_capabilities`
  use the shared normalized policy core; duplicate/invalid source forms and
  removed module modes are rejected.
- `capability_api.nim` supplies immutable parse/build/entry/pattern/any values and
  requirement/operation reports. [Authority reference](../spec/authority.md)
  documents the concrete signatures, literal defaults, source bases and limits.
- Callable admission precedes callee-owned defaults; explicit inherited contracts
  must match exactly. Structured loop exits restore capability and ensure frames.
  Declared requirements are rechecked at every entry rather than cached by a
  revocation epoch that cannot observe all resource-state changes.
- Env bounds now accept inert rows or evaluated immutable rows, use attenuation
  at creation, and retain parent/evaluator ceilings. The legacy name-binding map
  has been removed from `Env ^capabilities`; ordinary values use `^bindings`.
- Bound calls accept immutable policy rows. Migrated tests exercise normalized
  grants through bound and adapted calls, lazy pipelines, eval closures,
  generators, and channel-driven task suspension. The tests no longer depend on
  row-level `*`, parameter-dependent selectors, or compatibility root grants.
- Required-boundary failures retain their structured admission report internally;
  literal and dynamic rows expose the same typed failure and stable reason.
  Strict error-proof activation remains inside the entered callee's error
  contract, after capability admission and before defaults.
- Filesystem adapters preserve typed denials and provider failures. Guard errors
  carry safe reason/boundary data and preserve internal provider causes; normal
  I/O errors remain `OsError`, and unsupported modes are typed separately.
- Native execution commands use normalized startup and source admission, and
  embedding construction/entry now uses the same empty authority default.
  Remaining native adapters and old low-level filesystem catalog APIs
  still need migration. Keeping parallel legacy authority paths is not the
  requested final state. Wider application documentation/examples also need
  migration with their actual launch/provider workflow.

The earlier all-green checkpoint passed 1,608 tests before strict source/boundary
migration (`/tmp/gene-capabilities-test-all-domains.log`). The subsequent full run
terminated with 43 failures (`/tmp/gene-capabilities-test-all-boundaries.log`),
mostly old source/API expectations, plus real error-translation and bound-call
validation bugs found and fixed during migration. That run is not a passing
checkpoint. The focused normalized regression runner currently passes 419 cases,
including the general VM, pipeline, callable-adaptation and boundary suites;
20 bound-call cases and 12 Env/deferred cases also pass separately. Compiled-GIR
round trips now preserve literal metadata, dynamic blocks/Env bounds, loop exits,
and typed catches. GIR format 16 rejects older selector artifacts; decoding also
restores owners inside capability blocks and reconstructs the internal catch
binding instead of applying source shorthand to it. The latest full-suite run
finished with 1616 passing cases and 31 failures
(`/tmp/gene-capabilities-test-all-deferred.log`). It included three issues
subsequently fixed and verified in focused suites: a malformed unsupported-effect
fixture, strict error-proof activation outside the callee's error contract, and
the native callback fixture's obsolete grants/syntax. The CLI diagnostic fixture
has also been updated to the new `fs/Read` name. The other 27 failures remain
tracked legacy source/API/module migration work; this is not an all-green full
checkpoint. Current focused suites pass 27 boundary cases, 31 core policy cases,
12 Env/deferred cases, 20 bound-call cases, 20 native callback cases, and 108
error-handling cases. The earlier 419-case general VM/pipeline/callable regression
runner also passed.


On this machine, use this process-local SDK setting for Nim tests (including
test suites that build child executables):

```sh
rtk proxy env SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk nim c -r --path:src --hints:off -o:/tmp/gene-test-all-capabilities-v1 tests/test_all.nim
```

## Implementation limits selected for the pure core

| Limit | Value |
| --- | --- |
| Policy text or checked-builder budget | 65,536 bytes |
| Authored row entries | 256 |
| Positional values per entry | 64 |
| Properties per entry, including optional metadata | 32 |
| Items in a flat property list | 256 |
| String bytes in policy input | 8,192 |
| Block-comment nesting | 8 |
| Normalized row entries / one decomposition expansion | 1,024 |
| Compiled pattern runes | 1,024 |
| Pattern proof work | 65,536 units |
| Concrete operation string bytes | 65,536 |
| Concrete operation body values / named fields | 64 / 32 |
| Independent authority rows in a normalized context | 128 |
| Context domain-key bytes | 1,048,576 |
| Live normalized filesystem root handles per provider | 64 |
| Captured source bytes per file / directory bundle | 8 MiB / 32 MiB |
| Sources / enumerated entries / directory depth per bundle | 1,024 / 16,384 / 64 |
| Retained source bundles / source bytes per application | 64 / 128 MiB |

Literal integers use checked signed 64-bit decimal or hexadecimal values. String
escapes follow Gene's Unicode scalar rules. Builders distinguish literal values,
explicit patterns, and explicit unrestricted values; default/unset scalars are
invalid. Parser bases are absolute and normalized lexically without filesystem
inspection. Public Gene constructors and source lowering enforce these same limits.
Faithful public policy serialization and the full diagnostic/report audit remain
part of the API/runtime gate.

## Module-domain prototype findings

The prototype exposed two existing loader assumptions that cannot survive the
migration: canonical implementations disappeared from a restricted module's
visible chain after publication, and compiler artifacts were reused by source
path across different authority domains. Normalized domains now retain their
own implementation visibility and use separate compiler keys. Recompilation
across domains is deliberate until safe symbolic relinking is implemented;
repeated imports in the same admitted domain reuse their existing instance.

Domain keys also include the source directory, normalized namespace exposure,
shared module instance identities, and execution budget. Removing a shared
dependency cannot reuse a previously broader instance. Module instance IDs are
monotonic runtime identities rather than heap addresses. A failed initialization
is cached for that domain/revision; an explicit new revision creates a new
attempt. Unapproved static dependency sources are rejected before their compiler
headers are read.

Normalized execution explicitly rejects currently unsupported application
printing, stdin, logging, SQLite and filesystem-watcher paths, including through
empty callable/block boundaries. This is an interim enforcement measure, not an
exhaustive effect inventory or completion of the required Harness workflow.

## Native HTTP transport checkpoint

`test_http_capability_transport.nim` passes 11 recording-loopback cases, and
`test_http_capabilities.nim` passes 14 policy/preparation cases. The existing 23-case HTTP
server/client integration runner also passes, including TLS verification,
streaming, output limits and cancellation (`/tmp/gene-http-compat-regressions.log`).
The CLI fixtures in that older runner still use compatibility startup grants;
the new transport suite supplies normalized grants directly. The initial profile
intentionally does not follow redirects or support managed authentication,
proxies, tunnels, upgrades or connection pooling. Each later request is separately
guarded; in-progress requests are not retroactively undone by revocation.

All 11 transport cases also pass with `--mm:atomicArc --threads:on`, including
large bodies without automatic expectation retries.
Both `--threads:off` cases in `test_http_capability_unthreaded.nim` pass. That
build exposed a missing external-operation counter for terminal polling; the
single-threaded runtime now maintains that counter instead of compiling out its
lifecycle functions.
The latter verifies explicit unsupported-backend rejection before CA-file reads,
while pure preparation/checking remains usable. These checks are independent of
the still-unfinished startup, loader, remaining resource/effect-adapter and application
migration; they do not close the overall implementation goal.

## Retained filesystem and atomic-write checkpoint

`test_fs_capability_handles.nim` passes 14 cases in default ORC, atomic ARC with
threads, and `--threads:off` builds. Tests observe real file contents and descriptor
release, including an origin revoked beside a broader caller, surviving origin
alternatives, changed file and parent bindings, denied publication, constrained
cleanup after revocation, symlink-entry replacement, and native rename failure.
The 13 existing filesystem policy/adapter cases pass with the new primitives.
The Gene boundary suite passes 28 cases, including `fs/write_text_atomic` and
rejection of application file logging before resource creation.

The HTTP transport suite now passes 12 cases in both ORC and atomic ARC: the added case combines
normalized HTTP and filesystem grants to read a CA file and perform verified TLS,
while rejecting the same self-signed endpoint without that explicit CA. The 12 deferred-boundary cases also pass, and `nim check tests/test_all.nim`
succeeds with all new suites included; this is a compile check, not a new passing
full runtime checkpoint. This completes the initial
filesystem retained-handle/atomic-write path, not the application logging, watcher,
lock, database, or other excluded effect profiles. The broader migration and the
legacy full-suite failures above remain open.

### Provider-state audit resolution

Filesystem root inspection now distinguishes proved missing/replaced/symlink
bindings from operational inspection failures, retaining native error codes and
causes. Resource/path-local failures combine as entry failures; invalid owned
descriptors and descriptor/memory exhaustion are shared failures. Both actual
operation guards and requirement checks preserve that distinction. Independent
live entries can satisfy local failures, including through finite decomposition.
Optional reports can expose provider failure without adding a mandatory entry
precondition; actual effects remain guarded.

Resolution also revalidates the chosen root. A displaced narrower anchor in a
multi-root grant can no longer be revived merely because a broader root still
covers the logical path. Tests cover both new reads through the live broader
root and denial of stale retained handles.

The focused policy suite passes 35 cases, filesystem policy/adapter suite 15,
retained filesystem suite 14, and Gene boundary suite 29 before the subsequent
loader integration checkpoint.

## Ordinary loader checkpoint

`test_capability_loading.nim` adds ordinary import, generation and compiled-code
linkage cases alongside the existing 10-case domain prototype. It verifies
caller-scoped initialization, distinct declarations, retained ceilings, failed
initialization caching, explicit reload and failed-reload preservation, pristine
compiled templates, verified dependencies without mutable-source fallback, and
relative/inherited capability bases in portable artifacts. The full-suite checkpoint
finished with 1664 passing cases and 29 failures
(`/tmp/gene-capabilities-test-all-loader.log`). Two failures were fixture updates
made afterward: shared-scope report chunks now disable local slots, and the GIR
runtime-state test checks rejection at both encoding and decoding. The other 27
legacy source/API/module fixtures still require migration. This is not an
all-green runtime checkpoint.

The post-checkpoint combined VM/boundary/domain/ordinary-loader regression runner
passes 388 cases (`/tmp/gene-capability-loader-regressions.log`). The module suite
also passes after migrating the prepared-generation sealing fixture to normalized
filesystem grants and typed denials (`/tmp/gene-test-modules-normalized.log`). The
remaining full-suite migration failures are now the 26 legacy cases in
`test_capabilities.nim`; a fresh full runtime checkpoint is still required after
those fixtures and their corresponding obsolete paths are migrated.

## Retained source-policy integration

`test_capability_source_policy.nim` exercises escaped module functions, host-helper
calls, dynamic Env imports, retained Env/eval closures, parent and dynamic Env
bounds before initialization, source-directory intersections before compiler
header discovery, shared-instance pinning/conflicts, sandbox-management rejection,
and relative imports from compiled modules. Calls also consult retained loader
capability ceilings, preserving a prepared generation's later sealing for escaped
dependency functions. CallerEnv snapshots retain both the captured source and
the restricted snapshot creator. Passing a host-created transaction handle does
not let a restricted caller manage source admission through a helper.

The broader VM/module/boundary/domain/deferred/bound-call regression runner passes
536 cases (`/tmp/gene-capability-source-regressions.log`). The subsequent final
snapshot fix passes the 15-case source-policy suite in default ORC and unthreaded
builds, and all 45 boundary/source-policy cases pass in atomic ARC with threads.
The atomic build also exposed and corrected a stale memory-model compile guard
that omitted the already supported `gcAtomicArc` mode. `nim check tests/test_all.nim`
succeeds; this is not a new full-suite runtime checkpoint.

The [loader profile](capabilities-loader-profile.md) records this implemented
subset and the remaining acquisition, concurrency, REPL/native-entry and lifecycle
work. It does not establish a complete source sandbox or authorize empty-default
rollout yet.

## Native source acquisition checkpoint

`module_sources.nim` captures immutable `.gene` bundles with SHA-256 identities
before normalized sandbox compilation. It uses the existing guarded filesystem
adapter under a temporary private read grant, releases every descriptor/grant,
and never changes application authority. Compiler discovery and later imports
read the captured bytes; new files, changed live contents, untraversed symlink
directories and unrelated installed artifacts cannot replace an admitted revision.
One host owner/revision keeps its source bundle across different authority domains.
Intersected origins must agree on source bytes as well as source admission.

The focused capture suite verifies immutable bytes, source filtering, symlink
rejection, private-authority separation, descriptor release and all capture limits.
Source-policy integration tests cover lazy imports after removal/replacement,
revision pinning/conflicts, rejection before compiler headers, installed-artifact
isolation, and normalized transaction graph digests and instance release. The
legacy URL-enable flag now rejects in normalized execution until an authenticated
source profile is implemented.

The broader regression runner passed 544 cases after snapshot integration.
The final source-policy suite passes 23 cases in default ORC, including the URL
profile rejection. Before that final URL guard, all 56 boundary/source/capture
cases passed in atomic ARC with threads, and all 26 source/capture cases passed
with threads disabled. The four capture cases also passed separately in ORC.
The ordinary launcher/package source graph, URL profile,
retired source-bundle lifecycle, REPL/native entries and full migration remain
required work; these snapshots do not complete the overall goal.

## Native effect inventory and entry enforcement

`native_effects.nim` now classifies 453 native implementation identities: 292
capability-free, 19 guarded, 9 private host controls, and 133 unsupported in the
current profile. [The per-API inventory](capabilities-native-inventory.md) records
contracts, evidence locations, and registration sites. The checker runs in
`nimble test` and `nimble verify`; new unclassified registrations or unreviewed
raw/dynamic construction fail it. Unknown host extensions default to rejection.

Immutable effect metadata survives aliases, method dispatch, bound calls and
callable adaptations. The VM rejects unsupported native entries before their
implementations and checks unsupported FFI/native declarations before normalized
run, block and function entry. Same-module optimization cannot skip that check.
Crossing a host scope without a module row preserves the normalized context.
Arithmetic fast paths no longer follow arbitrary host-native display names.
Raw FFI and dynamically loaded AOT entries remain unsupported in this profile.

Native SDK entry now establishes the provided dispatch scope's authority and
retained ceilings for the body and nested calls. Call-aware native adapters also
receive the host-captured invocation context in `NativeCall`, so an adapter need
not reconstruct dynamic authority from a broader application root. Trusted extension constructors
can explicitly select a disposition; guarded adapters use the exported active
context and shared error translation helpers. The native API version is 5 for
the changed native metadata contract and layout; native modules must be rebuilt.

The full-suite checkpoint passed 1,709 cases and retained the same 26 legacy
capability failures (`/tmp/gene-capabilities-test-all-native.log`). The final
captured-invocation-context addition also passes focused native/SDK/callback and
provider checks. The 14-case native-effect suite covers real unsupported API
families, every unsupported disposition's pre-body rejection, name impersonation,
aliases/adapters, direct SDK entry and real guarded-extension reads.

Lazy map/filter/pipeline adapters now retain registration source origins as well
as capability bounds. `take` retains its creation bound over upstream effects.
Native invocation supplies a stable consumer scope to deferred callbacks, and
filesystem adapters use the shared active-context accessor. Added cases verify
that a pre-existing private host callback cannot lose the plugin's source origin
through an escaping stream, and that a stream created under an empty bound cannot
read through a broader upstream adapter. These bring the focused native-effect
suite to 16 cases. The final default-ORC regression runner passes 585 cases, and
the atomic-ARC native/SDK/callback/boundary/HTTP runner passes 101 cases. The
full-suite compile check and the native inventory check also pass. These focused
results do not erase the 26 legacy migration failures in the full runtime
checkpoint above.

## Ordinary application admission checkpoint

`Application.admitApplicationSources` connects startup authority to an explicit
source graph for application execution. Entry-only capture does not admit sibling
files. Added source bundles and artifacts are bounded, privately retained inputs;
runtime imports and compiler headers do not fall back to mutable files or stale
installed artifacts. Artifact resource bases participate in admission and linking.
Program source origins block private host-control calls even through later or
broader invocations, and combined sandbox origins intersect namespace exposure.

The new `test_application_source_admission.nim` exercises entry-only admission,
source bundles, package dependencies, shared contracts, private-control rejection,
failure isolation, artifact copying/revision checks, resource-base linking, domain
identity and reload from frozen sources. The launcher performs discovery and
acquisition under its explicit host policy before installing this graph, as
recorded in the native launcher checkpoint below; the host API does not itself
authorize arbitrary package fetching.

The ordinary application source suite passes 14 cases in ORC and atomic ARC.
The broader VM/module/domain/source/startup/callback regression checkpoint passes
622 cases (`/tmp/gene-application-source-regressions.log`), before the final added
namespace-exposure case. The full-suite compile check and native inventory check
pass. The later launcher checkpoint supersedes the CLI wiring status; legacy
runtime fixtures and unsupported application workflows remain unfinished.

Actor/event registration, application REPL adapters, async filesystem I/O,
stores, logging and server operations that lack their complete adopted contracts
remain explicitly rejected in normalized execution. Migrating the adapters and
providers needed by the full Harness workflow remains required, along with the
ordinary startup/host-control distinction, other backend paths and legacy API
removal. The native inventory is not completion of those broader rollout gates.
The cleanup checkpoint below covers closing suspended callbacks under a narrower
consumer. Retaining all applicable owner execution budgets and the wider
initialization/resource lifecycle audit remain required work.

## Startup selection and initialization

`capability_startup.nim` provides one-shot CLI-source parsing, fixed replacement
precedence, private bounded configuration-file reads, static ceiling intersection
before provider initialization, and live-authority selection for embedding hosts.
Provider initialization/release hooks use the same sealed registry and normalized
policies as runtime guards. Filesystem clipping preserves complete multi-root
entries and common rights; HTTP clipping preserves host/method correlations.
Cleanup revokes issued grants even if a provider's resource release fails and
continues releasing other providers while retaining the original failure cause.

The normalized catalog now excludes explicitly superseded built-in identities
from namespace expansion. This makes `fs/*` and `net/*` usable under the adopted
profiles without silently admitting old filesystem or nominal host contracts.
Legacy constructors remain migration work, not an approved parallel end state.

`Application.configureCapabilityStartup` replaces implicit grants before
compilation/execution and leaves an empty normalized context on failure. Its
one-shot guard prevents a caught configuration error from falling back to old
authority. The [startup profile](capabilities-startup-profile.md) documents source
transport, resource initialization, limits and ownership. The native CLI has
adopted this path; the checkpoint below records its flags, source admission,
empty default and remaining rollout work.

The startup suite passes 24 cases in default ORC and atomic ARC with threads.
The combined startup/constraint/policy/API/boundary/filesystem/HTTP regression
runner passes 133 cases (`/tmp/gene-capability-startup-regressions.log`). The
full-suite compile check and native inventory check also pass. The existing
launcher and 26 legacy runtime fixtures remain migration work; these are not
claims of a completed CLI rollout or an all-green full runtime suite.

## Native launcher checkpoint

`run`, project execution, `eval`, the launcher REPL, test execution and executable
documentation inspection install normalized startup authority and admitted source
inputs. The capability flags/aliases replace the removed `--allow_*` flags. File
mode admits its entry only, with repeated `--source-root` bundles for additional
sources; source admission never grants application file access. Project execution
admits verified packaged artifacts. GIR format 17 carries checked package-relative
source paths so linking does not guess artifact ownership from mutable files.
Compilation uses an empty application policy and privately captured source inputs.

Project startup captures and validates the selected policy before build/package
work, then normalizes that frozen value against the runtime catalog. A changed
capability file cannot change the execution policy between these stages. Test
registration retains both authority and source origins, including pre-existing
callbacks. Host-selected test reporting remains separate from the application's
unsupported output API; application test execution accepts `^report false`.

The focused launcher suite passes 15 cases, all seven capability examples run
under their documented explicit policies, the combined build/startup/source
runner passes 60 cases, and the existing test-runner suite passes 29 cases. Logs:
`/tmp/gene-capability-cli-tests.log`, `/tmp/gene-launcher-capability-checks.log`.

The subsequent full runtime checkpoint completed with **1,697 passing and 95
failing cases** (`/tmp/gene-test-all-launcher.log`). This supersedes the earlier
1,709/26 checkpoint: 26 failures are legacy capability contracts, 46 are existing
CLI fixtures/workflows, and 23 are HTTP server/client end-to-end fixtures. The
CLI failures include removed flags, implicit effects/source access, and macOS
temporary paths traversing `/var`'s symlink. Existing server workflows also need
an adopted guarded contract; HTTP-client permission does not authorize listening.
These failures require migration and verification, not restoring implicit grants.

## Retained stream cleanup checkpoint

New regression cases first reproduced unauthorized reads during adapter-owned
upstream cleanup and during cancellation of suspended mapping callbacks. The
native probe also reproduced private-host calls escaping a plugin's source
policy during both paths. These were real execution-boundary failures, not only
matcher/report differences.

Lazy map/filter/pipeline/take adapters now perform owned upstream cleanup inside
their retained creation and actual consumer boundaries. A suspended callback
retains the closer's capability ceiling throughout cancellation, saved-frame
restoration and cleanup suspension; self-close uses that ceiling before its
ensure body. Continuations also retain execution source origins independently of
lexical scopes. Generator pull/close intersects the actual consumer's source
policy, and scheduler switches install each task's own captured origins.
Neither capability nor source restrictions spill into unrelated scheduled work.

The focused deferred/native/source/pipeline/generator runner passes **111 cases**
in default ORC and **111 cases** with atomic ARC and threads. Cases include
idempotent adapter close, nested saved capability frames, self-close, cleanup
that suspends again, rejected private-host probes, parent-context restoration,
and an independently scheduled task retaining its own authority. The broader
VM/module/domain/startup/bound-call/native-callback/test-runner regression passes
**621 cases**. Logs: `/tmp/gene-cleanup-capability-checks.log`,
`/tmp/gene-cleanup-atomic-checks.log`, `/tmp/gene-cleanup-vm-regressions.log`.
The full-suite compile check and native effect inventory check pass. These results do not supersede the
95 full-suite migration failures recorded above or complete the remaining
owner-budget, initialization-lifecycle, backend and Harness workflow work.


## Source-facing legacy capability removal

Ordinary Gene namespaces no longer export the old filesystem, network, process,
FFI and device capability constructor values. Capability policy values are
inert and cannot be called, even when an embedding host supplies an old
specification value. Authored text and runtime construction use the same
`$capabilities/parse` and checked entry/builder APIs.

The compiler rejects `type ^capability`. The VM's Gene facade registry,
canonicalization callbacks/cache, `CapabilitySpec` protocol special cases,
selector-based `check_capabilities`, and the old `capabilities_of` /
`capability_type_info` natives have been removed. Supplied compiled type metadata
using that removed facade contract rejects before type registration or derive
callbacks. Trusted normalized provider identities and effective callable
contracts remain independent of application name/implementation resolution.

`test_capabilities.nim` now tests the current source/call/check/module contract.
It replaces parameter-slot selectors, strict module modes, overlapping-grant
ambiguity and implicit default expectations with inert rows, dynamic checked
builders, exact inherited contracts, independent alternatives and explicit host
policy. Module fixtures use caller/import bounds; strict-mode fixtures remain
only as explicitly labeled rejection cases. Existing low-level provider and
legacy resource-lifetime tests remain until those host internals are removed.

The executable language specs use policy data rather than removed constructor
values. The authority/stdlib references document this migration. Native inventory
now contains 453 identities: six obsolete selector/facade natives were deleted.
The CLI test fixture root resolves the operating system's temporary directory to
its physical path before creating files, matching the no-follow source profile
without weakening that profile.

Validation for this checkpoint: **41** cases in `test_capabilities.nim`, **1,590**
cases in the broader reader/compiler/provider/VM/protocol/module regression,
**109** focused cases with atomic ARC and threads, **5** executable language-spec
cases, and **8** CLI entry-point/diagnostic cases all pass. The full-suite compile
check and native inventory check pass. Logs: `/tmp/gene-capability-surface-tests.log`,
`/tmp/gene-surface-regressions.log`, `/tmp/gene-surface-atomic.log`,
`/tmp/gene-capability-surface-spec.log`, `/tmp/gene-cli-physical-root.log`.

The source suites that contained the 26 legacy capability failures are now
migrated and passing. This is not a new complete CLI/server/client or Harness
runtime checkpoint; the earlier 95-failure full run is historical evidence,
not a recomputed remaining-failure count. The native host-provider selector APIs,
implicit embedding defaults, workflow providers, remaining backend/lifecycle
gates, and the full application migration still need completion.

## Embedding entry enforcement checkpoint

Application construction no longer adds filesystem or nominal host grants.
Every new application starts with a normalized empty context. The host catalog
configuration callback now admits providers/types only; grant selection and
initialization happen explicitly after catalog freeze. `setRootCapabilities`
rejects legacy and foreign contexts, and `run` rejects invalid execution-context
overrides before any body code. Module initialization, explicit-context execution,
and direct function/native calls all freeze startup selection.

Direct SDK calls establish an execution policy even without an enclosing VM
frame. With no actual caller scope they receive empty authority in the target's
catalog: a held callable cannot lend its application's root grants to the
invoker. Explicit dispatch scopes supply selected authority. Private host calls
still require eligible caller provenance. Scope, eval, module and source ceilings
are intersected at entry, including when a retained Error formatter is invoked.

The new default exposed a typed-call trace regression in the blanket disabling of
same-module optimizations. Safe inherited calls now validate their declarations
before considering the existing optimization; declared rows and retained/origin
transitions still take their full boundary path. Typed native argument adapters
and source traces retain their behavior under normalized authority.

Pure native test extensions now opt into their explicit disposition. Supported
filesystem fixtures use normalized grants and physical temporary paths.
Unsupported async filesystem, raw TCP, database and store entry tests assert
rejection before effects or retained authority are created. This does not claim
those provider families are implemented.

Final focused checks pass **369** capability/provider/loader/reflection cases,
**34** startup/embedding cases with atomic ARC and threads, and **15** capability
CLI cases. Eight affected VM/error-formatter fixtures also pass in the final
broader run. The full-suite compile check
and native inventory check pass. Logs: `/tmp/gene-embedding-contract-checks.log`,
`/tmp/gene-embedding-startup-atomic.log`, `/tmp/gene-embedding-cli.log`,
`/tmp/gene-embedding-fixture-checks.log`, `/tmp/gene-embedding-all-check.log`.

The broader runtime runner (excluding CLI/server/client and terminal integration
suites) finishes with **1,494 passing and 103 failing cases** after these changes
(`/tmp/gene-embedding-regressions-final.log`). Its earlier 1,478/115 run was used
to find the entry/trace issues and migrate the fixtures above. Remaining failures
cover timer/actor/callback and logging/FFI workflows without adopted contracts,
legacy root-setting fixtures, direct stream SDK entry without a consumer scope,
and module/shared-contract/reload expectations from the previous instance model.
They require adapter and fixture migration with relevant integration evidence;
restoring an implicit or legacy application context is not a valid remedy.
The original full CLI/server/client and Harness workflow audit also remains open.
