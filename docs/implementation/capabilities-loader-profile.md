# Capability module-domain integration

This records the implemented loader rules and remaining integration work for
proposal sections 14.4 and 14.10. The ordinary normalized path now uses domain
instances; the complete source-admission and backend rollout gate remains open.

## Instance and code identity

An application owns its ordinary module cache. A normalized cache key combines
the resolved package/module identity, canonical effective authority-domain key,
and an explicit instance generation. Sandbox admission additionally supplies its
owner/revision, directory, namespace-exposure and shared-instance identity key.
Compiler and runtime caches use the corresponding domain key. Context-object
addresses and diagnostic locations are not identity inputs.

Retained source-origin keys also participate in the instance/cache domain. Each
origin identifies the admitted directory, owner/revision and namespace key,
initializing authority, execution limits, and exact shared module instance IDs.
Origins are deduplicated and ordered independently of context allocation.

Initialization uses the actual importing context intersected with the active
loader ceiling. The initialized module retains that context. Application-wide
materialization never replaces it with a broader root. Ordinary imports made
under equivalent normalized bounds reuse their initialized declarations;
different domains initialize separate nominal types and protocols.

An ordinary import's capability annotation selects an initialization bound and
therefore its instance domain. It does not install a path-global restriction on
other instances. Shared-instance imports preserve their admitted identity;
additional import annotations on those instances are rejected. Use retained
bound callable values for additional invocation restrictions on shared code.

## Shared contracts and generations

Host file/compiled entry loading records the initialized module selected by the
host. Explicit sandbox sharing snapshots those concrete instances before loading
the consumer. A shared lookup returns the initialized value and cannot trigger
lazy initialization with startup authority. Its runtime instance ID participates
in the consumer's admission key, and compile-time imports use its corresponding
artifact. Existing references retain the earlier shared instance if the host
later publishes another one.

Initialization failures are cached for the selected domain and generation.
Changing the source file does not automatically rerun failed initialization.
An explicit normalized reload attempts a fresh generation. Success publishes its
new declarations while earlier values retain their previous identities and
behavior. Failure leaves the previous published generation selected; another
explicit reload is a new attempt. Earlier external effects are not rolled back.

## Artifact linkage

Compiler templates remain inert. Each initialized domain receives a fresh code
copy for runtime invocation metadata and declaration linking. Serialization and
cloning reject live scopes, capability contexts, runtime values, bound execution
policies and cached invocation state. Nested function, default, type, protocol,
implementation and capability-block bodies are covered by declaration rejection.

Verified installed module artifacts have separate pristine templates. A new
authority domain instantiates those templates rather than rereading mutable or
missing dependency source. Bundle validation completes before any template is
installed.

Portable package source names are symbolic identities, not filesystem bases.
Static capability literals belonging to a module are linked to that admitted
module's directory before initialization. The original compiler template is not
changed. An inherited contract subsequently retains the declaring module's linked
base rather than acquiring the implementation module's directory.

## Retained source policies

Normalized sandbox admission captures its source policy before compiler discovery
or initialization. Defined scopes retain the originating directory, shared-instance
snapshot, execution policy, and defining module's resolution base. Calls combine
the callee's source origins with the actual caller's origins, including calls to
pre-existing host helpers. A later broader caller cannot remove those origins.
Source acquisition must satisfy every retained origin; a shared lookup requires
the exact same instance to be admitted by all of them. An allowed ordinary source
path cannot substitute for another origin's explicit shared-instance admission.

Dynamic Env imports use the creator's current authority intersected with the Env
bound, parent Env bounds, and loader ceilings before imported code initializes.
Env values, extensions, snapshots, and eval-created functions retain their source
origins. Ordinary eval resolves relative imports from the retained Env/module
base and also applies the evaluator's restrictions. Runtime imports and dynamic
Env imports use the same loader path. Compiler dependency discovery receives the
intersected directory/shared policy before it reads dependency headers.

Lazy map/filter/pipeline adapters also retain their registering source origins;
`take` carries both its source origins and creation authority into upstream pulls.
A broader consumer cannot use a pre-existing callback to erase those restrictions.
Normalized deferred callbacks require an admitted consumer scope, including when
entered through the native SDK.

Explicit shared instances remain usable after their source file is removed, and
an existing consumer keeps its admitted instance when the host publishes a new
generation. Shared import annotations cannot silently select a different domain;
use bound callable values for additional restrictions. Sandbox-management calls
also reject retained restricted callers routed through host helpers.

Module resolution and loading currently require the root lane in normalized
execution. Worker lanes reject before changing shared resolver state; concurrent
initialization coordination remains an open loader gate.

## Native directory source acquisition

Native normalized sandbox admission captures a bounded, immutable bundle of
`.gene` sources beneath its host-selected directory before compilation or
initialization. Enumeration and regular-file reads use the filesystem provider's
descriptor-relative no-follow operations under a private loader read grant. The
grant and all descriptors are released after capture; they are never installed
as application authority. Symlinked directories are not traversed, symlinked or
nonregular `.gene` entries are rejected, and non-source regular files are excluded.

The captured bundle, not later filesystem contents, is the source revision used
by imports and compiler headers. It has a SHA-256 identity over sorted relative
paths and exact bytes. Capture is a sequential collection of bytes, not a claim
of an atomic filesystem transaction or source trust. A host owner/revision key
reuses its original bundle across authority contexts; choosing a new revision
captures a new bundle. Intersected source policies must agree on the captured
bytes for a requested source. No live-file or unrelated installed-artifact
fallback is permitted for an admitted source bundle.

Initial limits are 8 MiB per source, 32 MiB per bundle, 1,024 sources, 16,384
enumerated entries, and 64 directory levels. An application retains at most 64
bundles and 128 MiB of source bytes. Failed capture publishes no bundle. Source
capture uses one temporary filesystem root slot and releases it before execution.
Transaction graphs use captured source records, and normalized generations track
their actual instance keys for publication and release.

This profile is for explicitly admitted native sandbox directories. The legacy
URL-enable flag is rejected in normalized execution, including before cached URL
source reuse; it does not establish an authenticated source policy.

## Ordinary application source admission

`Application.admitApplicationSources` installs a one-shot, host-selected source
graph after startup capability configuration. It accepts immutable source
snapshots, exact compiled artifacts, and explicitly shared initialized instances.
It is a host API and rejects entry from application execution. A failed attempt
leaves a rejecting source policy rather than restoring raw file loading.

`captureModuleSourceFile` captures only the approved entry file; it does not
enumerate or admit neighboring files. Hosts add directory snapshots or individual
files deliberately. The package graph still controls name/alias resolution, and
the source policy independently decides which resolved paths may be acquired.
An explicitly supplied resolved dependency package can therefore be used without
granting general filesystem access or accepting arbitrary new paths.

Ordinary program scopes retain this source origin and cannot invoke private host
control natives. The restriction follows calls, Env values and lazy adapters.
When several sandbox origins apply, their namespace exposures intersect too.
Compilation and runtime loading use the same admitted bytes and instance-domain
key. Reload creates a new declaration generation from the admitted revision;
editing a live source file does not change that revision.

Resumable continuations also retain execution source origins independently of
their lexical scopes. Generator pull/close intersects those origins with the
actual consumer. Closing a suspended mapping callback retains the closer's
origins for its remaining cleanup, including later suspension and saved-frame
restoration. Adapter-owned upstream cleanup executes inside the adapter's
creation/consumer boundary. Switching to an unrelated scheduled task installs
that task's captured origins and restores the previous continuation on return.

Compiled admission validates and privately copies each complete artifact. Its
identity must match the declared package/module path. The source graph records
its SHA-256 content identity and an explicit resource normalization base (the
admitted path's parent by default). Later installed templates cannot replace the
selected artifact. Direct compiled-entry loading verifies that its chunk agrees
with the admitted artifact/source. Text and compiled admissions cannot silently
substitute for one another, and conflicting paths or module identities reject.

An application admission contains at most 1,024 paths and 128 MiB of captured
source/artifact data. Shared instances must already be fully initialized under
the same application owner; their exact runtime identities are retained. A shared
dependency cannot also be admitted as an ordinary source or as the program entry.

## Launcher and packaged artifacts

The native launcher supplies entry snapshots, explicit `--source-root` bundles,
or a verified project build graph through ordinary application admission.
Project compilation uses normalized empty authority and admitted snapshots and
dependency artifacts. Package-relative source paths travel in GIR format 17;
absolute or non-normalized serialized paths reject. This avoids guessing whether
a module name came from a package root or its library directory. Colliding module
identities also reject during bundle compilation.

## Remaining gate

Authenticated URL acquisition remains unsupported until its profile exists.
The project resolver/build path is a host operation over the selected package
graph; it must not become an application-callable arbitrary fetch/read service.

Also finish concurrent-import coordination, cleanup of initialization-owned
tasks/resources, serialization/reference lookup across domains, and integration
with transactional sandbox publication, including graphs containing several
authority instances of one source path and retired source-bundle ownership.
Incremental/interactive REPL Env entry
and the remaining native evaluation adapters also need the retained-policy audit.
Those paths must not fall back to a path-only cache or publish partial exports.
The broader lifecycle and application migration remains required despite native
CLI startup now using the empty default.
