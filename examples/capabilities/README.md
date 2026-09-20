# Capability examples

These programs exercise the [version-1 authority contract](../../docs/spec/authority.md).
Run them from this directory after building `bin/gene`. They use assertions and
exit codes because application printing is unsupported in the initial profile.
A successful example exits with status 0.

```sh
G=../../bin/gene
mkdir -p reports out/public out/plugin
$G run --cap '[]' 01_open_mode.gene
$G run --cap '[(fs/Read ".")]' 02_outside_root.gene README.md
$G run --cap '[(fs/Write ".")]' 03_declared_function.gene
$G run --cap '[(fs/Write ".")]' 04_with_capabilities.gene
$G run --cap '[(fs/Write ".")]' --source-root . 05_import_ceiling.gene
$G run --cap '[]' 06_strict_dependencies.gene
$G run --cap '[(fs/Read ".")]' 07_env.gene
```

The launcher defaults to `[]`. CLI policy replaces environment policy and other
lower sources; it never adds implicit filesystem or network grants. The old
`--allow_*_dir` flags are removed. A capability file contains the same inert row:

```sh
$G run --cap-file permissions.gene program.gene
```

Relative policy roots use the declaring module, capability file, or captured
launch directory as specified by their source. **Operation paths remain relative
to the captured launch directory**: a bound for `out/public` does not make
`"inside.txt"` mean `out/public/inside.txt`.

The initial filesystem profile rejects symlink traversal, including symlinked
roots. On macOS use physical paths such as `/private/tmp` rather than `/tmp`.
Granted directory roots must exist before startup initialization.

The examples cover:

1. Empty authority with an unannotated function.
2. An actual read authorized by an explicit host policy. Running this example
   without its read grant produces `MissingCapability`.
3. A mandatory callable request rejected before its body when the caller is empty.
4. Temporary attenuation, actual-operation denial, and caller restoration.
5. Bounded dependency initialization and retained invocation authority.
6. Required blocks and optional HTTP availability. Its historical filename is
   retained, but strict module modes and module request rows no longer exist.
7. Env bindings, inherited/empty bounds, and escaped eval closure ceilings.

`--source-root` admits a frozen code bundle for imports. It does not grant
application permission to read those files. Example 5 needs it for `plugin.gene`;
entry-only admission deliberately does not include sibling modules.

To inspect a value through the runner's private result display:

```sh
$G eval --cap '[(fs/Read ".")]' '($fs/read_text "README.md")'
```

The [implementation tracker](../../docs/implementation/capabilities-v1.md) records
remaining adapter and application migration work. These examples do not claim
that every legacy facility has an adopted capability contract.
