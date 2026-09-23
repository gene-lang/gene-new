# Gene Application Libraries

**Status:** Proposed design; additions below are not implemented unless identified as existing.  
**Purpose:** Ship a coherent application library set so common Python scripts and data jobs do not each reinvent basic I/O and interchange.  
**Form:** Common libraries in the existing `gene` namespace; optional libraries as individual `genex/*` packages. No new language syntax.

## Placement decision

Use `gene/*` for small, broadly useful libraries shipped and qualified with the runtime. They appear as ordinary root namespaces such as `$path` and `$csv`, following `$str`, `$json`, and `$fs`; an application imports names explicitly but does not add a package dependency for them. Use separately versioned `genex/*` packages for less common facilities, large data sets, or native codecs. Applications declare and lock each optional package they use. Do not create a `gene/app` umbrella package or make a CSV user acquire an archive codec.

`genex` currently contains native packages. Under this proposal it means optional Gene extensions; a pure-Gene optional package may also live there. Update its repository documentation when the first such package is added. If a `gene/*` library is implemented in Gene source rather than Nim, bundled-source delivery must make it available with the runtime before the namespace is advertised as built in. Each public location declares VM/platform support and runs the relevant `native-app` fixtures from [the profile](python-replacement-profile.md).

Existing `$fs` read/write/watch/lock, `$os` subprocess/environment, regex, Date/Time/DateTime/Duration values, `$json`, and databases remain the base. The proposed modules fill workflows those primitives do not yet cover.

## First supported modules

| Public location | Contract for first release |
| --- | --- |
| `gene/path` (`$path`) | Pure `join`, `parent`, `name`, `extension`, `normalize`, and `relative` over platform paths. `normalize` is lexical; `real_path` remains the explicit filesystem/symlink operation. No implicit current-directory change. |
| `gene/fs` (`$fs/walk`) | Add lazy recursive traversal to the existing filesystem namespace, yielding path, kind, and size metadata. Stable lexical order within each directory; explicit symlink-follow policy, cycle detection, and optional depth bound. Close releases directory resources. |
| `gene/csv` (`$csv`) | RFC 4180-style reader/writer over UTF-8 text with explicit header mode, delimiter, quoting, newline, and malformed-row policy. Preserve empty field versus absent header. Bound field and record bytes before allocation. |
| `genex/toml` | Optional TOML reader/writer for application configuration. Preserve the distinction between absent and explicit values when mapping into Gene data. Reject duplicate keys and invalid encoding. JSON remains `$json`. |
| `genex/archive` | Optional gzip byte streams and ZIP read/write with explicit extraction root, path validation, total uncompressed-byte limit, and bounded per-entry reads. A native compression adapter may implement the codec. |
| `gene/temporal` (`$temporal`) and `genex/tzdb` | Keep common UTC/fixed-offset instant and duration arithmetic in `gene/temporal`; ship IANA zone rules and conversion as an optional, versioned `genex/tzdb` data package. A named zone is a real conversion rule, not only a label. Ambiguous local times require an explicit earlier/later choice; nonexistent local times fail. Monotonic time remains for elapsed-time measurement. The existing `datetime` constructor keeps its name. |

The current synchronous file functions continue to serve small inputs. Streamed file, gzip, and network data use the resource contract in [async I/O](async-io.md); no module should read an unbounded file merely to implement a lazy-looking interface. `fs_walk` may begin as a synchronous generator because directory iteration does not itself require asynchronous suspension. CSV can consume a synchronous Stream first and gain an async adapter later without changing row meaning.

Illustrative imports use current syntax once these libraries are available:

```gene
(import $path [join])
(let output (join "reports" "summary.csv"))
```

An optional package uses the existing dependency alias form, for example `(import [parse] ^from "." ^pkg "toml")` after `package.gene` declares `toml` as an alias for `genex/toml`. Neither import adds new syntax.

## Semantics shared by the modules

- APIs accepting a path take a Str and resolve relative paths against the captured application launch directory unless explicitly passed an absolute path; they never change the process working directory.
- Text decoding defaults to strict UTF-8. Alternative encodings require an explicit codec name and a defined error policy. Binary bytes are never silently coerced to text.
- File/resource operations have typed recoverable errors, close on success/failure/cancellation, and avoid arbitrary code execution while parsing data.
- Serialization output is deterministic for the same inputs and options. Parsing reports source offsets or row/column positions where possible.
- Working memory is bounded by documented per-record limits; whole-document convenience functions are separate and explicit.

## Implementation stages and tests

1. Add `gene/path`, `$fs/walk`, and `gene/csv` through the current root namespace registration or bundled Gene source. Test cross-platform path fixtures, symlink loops, CSV quoted newlines, empty fields, malformed input, and size limits.
2. Add `genex/toml` as an independently locked package. Test a clean offline install alongside the parser/writer cases.
3. Add `gene/temporal` arithmetic and `genex/tzdb` conversion. Record the tzdb package revision with conversions; test DST folds/gaps and a zone-rule change.
4. Add `genex/archive` with a package-owned native adapter if needed. Test ZIP traversal attempts, decompression limits, early close, and corrupt input.
5. Run the automation and data fixtures in the `native-app` profile using these libraries from an installed artifact.

**Acceptance:** the automation fixture can walk, parse, transform, and atomically publish data using documented bundled APIs, with bounded memory and portable errors. No application-specific Nim shim is required.
