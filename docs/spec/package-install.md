# Local package resource and install contract

**Status:** PKG-1 is implemented on the qualified macOS arm64 POSIX host; Linux remains a separate platform gate. `native_binary` and source-built `c_library` are experimental PKG-2 recipes. A macOS arm64 package fixture passes for the existing genex WebSocket binding; cross-host reuse and hosted publication remain open. Executable coverage: CLI package build/resource/install/uninstall tests in `tests/test_cli.nim`, `tests/test_genex_package.py`, and the native-app CLI profile probe.

The package manifest remains format 1. A selected target may use a `resources` build recipe containing exact canonical, selected regular files. The artifact metadata records each resource's size and SHA-256 digest. `this_pkg` identifies the owning package; `$pkg/read_bytes` and `$pkg/read_text` resolve that ID within the current Application's selected artifact index and verify bytes at read time. Reading another declared direct dependency uses `$pkg/dependency` to obtain its Package value; arbitrary root strings do not select a resource.

`gene install [target] --prefix DIR [--package-root DIR]` requires an existing lock and materializes it offline. The initial mode copies local and path package sources into a layout that preserves their relative dependency paths and vendors immutable remote objects. It bundles the exact Gene executable, preflights an offline build, writes an install manifest, and atomically selects a content-addressed generation under `DIR/apps/<owner_name>-<target>`. The stable `DIR/bin/<target>` launcher is owned by that package/target. An attempted name collision fails before switching an existing current pointer.

A running launcher resolves its generation once and writes a per-process lease before invoking Gene. Updating `current` does not redirect that run. Source and runtime digests are checked when an existing generation is selected again. A failed build/update leaves the prior current pointer intact; confirmed successful output is reported only after the launcher exists. The install uses source snapshots and a compiled artifact cache, so it is an installed VM application rather than a static binary.

`gene uninstall owner/name:target --prefix DIR` removes the owned launcher and current pointer, then deletes generations without live leases. Active leases keep their generation; repeating uninstall after those processes exit reclaims it. Other files under the prefix and user application data are outside the uninstall set. This first installer is qualified on macOS arm64; Linux POSIX qualification remains a separate platform gate. Installation synchronizes staged files and directories, the generation parent after publication, and the current/launcher parents after rename. Process-crash behavior is tested; an actual power-loss test has not been run.

The experimental `(native_binary "alias" ^variants [...])` recipe selects
exactly one variant for the build target. Each variant declares `target`,
`file`, SHA-256 `digest`, `abi_kind`, `abi_version`, optional
`runtime_identity`, and optional `system` dependency aliases. Accepted ABI
kinds are `c_abi` version 1, `gene_api` versions 4 or 5, and `gene_generated`
version 1. The latter two require the exact Gene runtime identity used for
the build. The selected file must be a regular file admitted by `^files`;
its digest is checked before compilation and again when materialized.
System aliases resolve through the configured dependency resolver, and
their evidence enters the derivation ID. The selected variant is stored in
artifact metadata and installed with the locked source closure.

`($pkg/native_binary this_pkg "alias")` returns a `MaterializedResource`
lease. Its `.path` can be passed to `ffi/open` or an extension loader; close
the lease after closing the library. Runtime selection rejects a target
different from the running CPU/OS before loading. The CLI regression builds
and loads a real C shared library under a suffix-free filename, then runs
the installed launcher with the original source checkout hidden. That CLI
regression alone does not qualify host-independent native artifacts or a
genex library.

`($pkg/native_module this_pkg "alias")` requires selected `gene_api` metadata,
opens the verified binary, invokes the managed initializer, and returns an
owned `NativeModule` IoResource. Its library and materialized lease retire
only after registered C callbacks and native owners finish. The installed
source-built and prebuilt fixture is specified in
[native module ownership](native-module.md).

`(c_library "alias" ^sources ["native/bridge.c"] ^linkage shared
^targets ["arm64-macosx"] ...)` compiles selected C sources from the
authenticated source snapshot. `^include_dirs`, `^system`, `^cflags`, and
`^ldflags` are literal argument Lists; compiler and archiver processes receive
argv directly, without a shell. The build captures the C compiler binary
digest plus SDK environment inputs as environment-dependent evidence and
resolves declared system dependencies before the derivation is selected.
An environment-dependent C derivation also includes a build-host identity:
the hostname and a random per-user build-installation token outside artifact
stores (`~/.gene/native-build-host-id`). Copying or sharing an artifact store
therefore cannot authorize C reuse on another build installation. Reusing
that identity file on another host is outside this policy. Missing unpinned
SDK/default-header/linker inputs still make this environment-dependent, not
a hermetic derivation. Same-host cache reuse retains the current input checks;
there is no cross-host C derivation promotion in this format.
Shared output is a loadable library; static output is an archive of pure C
objects. Static recipes currently reject link flags and system-library
aliases because there is no downstream native link step to consume them.
`^abi_kind gene_api` marks a shared `c_library` as a managed GeneApi module;
the build records the supported numeric ABI version and current runtime
identity. Static GeneApi libraries are rejected because the loader opens a
shared image.

Compiler output is a digest-checked sidecar of the GIR artifact. Warm cache
hits verify both GIR and the sidecar; `--verify-reproducible` rebuilds both.
`gene install` copies the exact artifact closure into its generation and
preflights that closure with `cc` unavailable. The launcher requires the
bundled derivation indexes, so an ambient cache cannot silently replace a
missing or corrupt installed artifact.

Imported compiler evidence authorizes only replay from a required, verified
installed artifact source. It cannot select an optional/ambient C cache or
authorize a rebuild. Installed bundles carry exact artifact bytes, target/ABI,
runtime identity, and declared system evidence; this does not establish their
compatibility with an unqualified destination host. Publisher-supplied
`native_binary` variants remain explicit target/ABI/system contracts, verified
as package bytes, rather than a claim that a C recipe was reproduced elsewhere.
Tests simulate distinct build-host identities against one shared cache and
retain compiler-free replay of the required installed closure.

A CLI regression loads a compiled C
library through `ffi/open` after hiding the source checkout, emptying the
user artifact cache, and removing compiler availability. The install manifest
records each selected native alias, target, ABI, digest, and system-dependency
evidence. Installed build views live in the user artifact cache rather than
mutating the generation's source tree. Linux runtime and cross-host reuse
qualification remain open. The genex WebSocket fixture builds
its existing generated FFI adapter, records it as a `gene_generated` variant
bound to the exact bundled Gene runtime, and selects Homebrew libcurl through
an explicit `GENE_PKG_CONFIG_PATH`. The installed launcher retains that
declared provider path and the selected `SDKROOT` used for system-library
evidence. With source, user caches, and compiler unavailable,
the installed app loads the adapter and receives a binary WebSocket frame
from a local peer. This proves the local artifact route, not cross-host
artifact reuse or hosted publication.

Executable GIR format 19 encodes `ffi/fn` declaration placeholders as
explicit inert stubs. It reconstructs only stubs with no native implementation
or effect metadata; an active native function remains forbidden in an
artifact. This lets genex packages carry their FFI declaration module
without serializing a live function pointer.
