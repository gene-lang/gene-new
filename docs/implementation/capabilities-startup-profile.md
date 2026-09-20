# Startup policy selection and initialization

This implements proposal section 9's host-side policy pipeline in
`capability_startup.nim`. Native execution commands now use it before application
initialization and default to `[]`. Application construction for embedding uses
the same normalized empty default. Other adapter and application migration work
remains tracked separately.

`Application.configureCapabilityStartup` installs this pipeline for embedding
hosts. It is one-shot and must precede compilation or execution. It first resets
the application to empty authority, leaving that normalized context on any selection,
validation or initialization failure. A failed attempt cannot be retried as an
automatic fallback on the same application. On success the application retains
the returned startup authority; its host closes owned state when finished.

`newApplication` never adds launch-directory, network, environment, FFI or other
implicit grants. `newApplicationConfigured` only extends the trusted catalog:
its callback receives the registry and built-in providers and returns no grants.
The registry freezes after the callback. The host then selects policy through
`configureCapabilityStartup`, or installs explicitly owned normalized live
authority with `setRootCapabilities` before execution. Root installation rejects
legacy contexts and contexts from another catalog without changing the root.

Direct `run` context overrides also require normalized authority from the
application's catalog. Direct function and native SDK calls establish the same
execution context before dispatch and freeze startup selection. A native call
without a bytecode caller cannot use an absent context to bypass effect metadata.
An unscoped call receives empty authority in the target's catalog; holding the
callable does not lend its application's root grants to the invoker. Embedders
pass an explicit dispatch scope to invoke with selected authority, and private
host-control calls require an eligible caller scope.
Scope and loader/eval ceilings intersect the selected context at entry.

## Source selection

`CapabilityStartupOptions` accepts exactly one CLI source through
`setCapabilityOption` or `consumeCapabilityOption`. Both `--flag value` and
`--flag=value` are supported for `--capabilities`, `--cap`,
`--capabilities-file` and `--cap-file`. Duplicate or mixed sources reject; values
remain single literal strings, with no shell expansion or interpolation.

`selectCapabilityStartup` selects CLI, then a present `GENE_CAPABILITIES` value,
then a host-supplied default, and finally `[]`. A present empty environment value
is invalid policy text, not absence. Selection does not read or validate overridden
inputs. Failure of the selected source never triggers fallback. The result keeps
the selected origin, distinguishing omission from explicit empty policy.

The caller supplies an absolute captured launch directory. CLI/environment roots
use that base; a selected file uses its own absolute parent directory. A host
configuration wrapper passes its extracted literal text, source name and base
through `hostCapabilityDefault`; the capability core does not discover or trust
application-authored configuration files itself.

`startupCapabilityPolicy` reads and normalizes the selected row for grant use.
The native file reader uses a temporary private `fs/Read` grant, no-follow regular
file acquisition, and the same 65,536-byte input limit as the literal parser.
It closes the file and releases the grant before returning. No application context
receives that acquisition authority. Symlinked files/parent traversal are rejected
under the filesystem profile. All optional metadata is invalid in grant input.

## Bounds before initialization

`startupCapabilityPolicies` validates every selected and ceiling row first, then
intersects complete entries. Each result must be proved contained in both input
entries by the shared comparison engine. Constraints from different alternatives
are never mixed. The intersection budget is shared across the complete startup
calculation; at most 128 ceiling rows and 1,024 resulting entries are supported.

Providers own cross-identity intersection. The default implementation handles a
single identity; unsupported cross-identity cases reject. Filesystem intersection
computes common rights and exact overlapping tree roots. It preserves a complete
root union in one entry, so it neither invents nor drops compound rename rights.
HTTP intersections retain complete component conjunctions and correlations.

`initializeStartupCapabilities` initializes only those resulting policies through
the provider hooks. An empty result initializes no provider state. Partial failure
revokes and releases previously issued grants. Cleanup continues across provider
failures, preserving both the original initialization cause and a cleanup failure.
`CapabilityStartupAuthority.close` is idempotent and invalidates held contexts by
revoking its owned grants before resource release.

For an embedding host that already owns live authority,
`selectStartupCapabilities` instead attenuates that context. It creates no new
grants or resource state and preserves all original grant references, independent
rows and revocation dependencies. It does not turn a snapshot of live authority
into newly issued permission.

## Catalog migration and integration

The normalized catalog view excludes explicitly superseded built-in identities.
`fs/*` selects `fs/Read`, `fs/Write` and `fs/ReadWrite`; `net/*` currently selects
the implemented `net/Http` profile. Exact legacy identities reject in normalized
policy input. Custom admitted providers participate by default and must implement
their normalized contract; unsupported schemas are not silently skipped.

This view is an interim migration measure. The launcher no longer accepts the old
directory grant flags. Old low-level provider grant constructors still require
removal, but their contexts cannot be installed as application roots or passed
as direct execution overrides. This profile does not approve a permanent
parallel legacy authorization path.

## Native launcher adoption

`run`, `eval`, `repl`, test execution and executable documentation inspection use
normalized startup policy. `run`/project test policy is captured and validated
before preparing a build, so later file/environment changes cannot change the
selected authority. Startup failures exit without opening a privileged fallback
REPL. A runtime-error REPL retains its application's policy.

File execution admits the entry only. Repeated `--source-root` options authorize
bounded immutable code bundles for imports; they do not add resource grants.
Source-file mode discovers package metadata but does not automatically fetch its
dependencies. Project execution is an explicit host build request: the package
resolver selects its graph, the builder authenticates immutable inputs, and the
runtime admits the resulting exact artifacts. Compilation runs without ordinary
external authority. Additional source roots add uncompiled sources; compiled
paths retain the verified artifact instead of falling back to live bytes.

The runner displays eval/REPL results and test reports as private host output.
Application output remains unsupported until its output contract is adopted.
Test callbacks capture registration authority and source origins, including for
pre-existing functions; diagnostic formatting stays under that callback boundary.
Application `test/run` can run without reporting, but cannot borrow runner output.

`test_capability_startup.nim` covers precedence and aliases, invalid selected
sources, stable bases, private file acquisition, namespace migration, root/right
narrowing, complete HTTP correlations and filesystem compound demands, rollback,
cleanup failures, expansion limits, and retained live embedding ceilings.
