# Gene Application Libraries

**Status:** APP-1 implemented for native POSIX paths, CSV data, and synchronous walking. APP-2 has an experimental AsyncReader-backed CSV adapter on macOS arm64: one-byte boundary, cancellation/ownership, 10 MiB file, and 10/100 MiB data-profile probes pass. Direct parser-payload measurements at EOF and peak are unchanged across those dataset sizes and pass the 8 MiB growth gate; Linux qualification remains open. APP-3 now has experimental standard `$temporal` arithmetic/RFC3339 and an installed `genex/tzdb` package pinned to IANA 2026d. The bounded TZif reader matched an independent oracle at 3,582 offsets across 597 packaged zones, including historical/future times; fold/gap and compiler-free offline installation checks pass on macOS arm64. APP-4 now has experimental gzip AsyncReader/AsyncWriter wrappers and ZIP extraction in a PKG-2 zlib/utf8proc package. Binary streams, concatenated member/trailer checks, flush/finish/abort distinctions, bounded store/deflate and CRC verification, Unicode-normalized path collision rejection, private staging, exclusive publication, capped native workers, cancellation, abandoned-codec retirement, and compiler-free installed execution pass macOS arm64 fixtures. Linux runtime qualification remains open. Baseline design reviewed at `3b2bde9`.

**Stages:** APP-1 (paths/CSV core), APP-2 (streaming CSV), APP-3 (time zones), APP-4 (archives).

**Placement:** Common `gene/*` namespaces; independently locked optional `genex/*` packages.

## Placement and delivery

| Public location | Delivery |
| --- | --- |
| `gene/path`, `gene/csv`, `gene/temporal` | Standard namespaces `$path`, `$csv`, `$temporal`, qualified with the runtime. |
| `gene/fs` | Extend existing `$fs` with walk. |
| `genex/tzdb`, `genex/archive` | Optional package aliases in package.gene, normal locks/imports, independent releases. |

Use the current stdlib registration path for the first standard modules. Implement parser/codec internals in focused modules rather than requiring a new bundled-Gene-source loader first. Optional pure Gene code can use today's package loader. Broaden the genex README's description to include pure optional extensions as these packages are added. There is no gene/app umbrella dependency.

```gene
(import $path [join])
(let output (join "reports" "summary.csv"))
```

An optional timezone dependency uses `(import [to_local] ^from "." ^pkg "tzdb")`, with that alias explicitly bound to genex/tzdb. The date/time constructor names already in the root remain constructors; temporal is a distinct namespace.

## APP-1: paths and traversal

Pure path functions never access disk, resolve symlinks, or make paths absolute implicitly:

| Call | Result/rule |
| --- | --- |
| `($path/join first more ...)` | Variadic join of native-platform components; this call spreads a List named more. Reject an absolute/drive-qualified later component rather than discard the prefix. |
| `($path/normalize p)` | Lexically collapse separators and dot components; preserve meaningful leading .. in a relative path; empty result is ".". |
| `($path/parent p)`, name, extension | Lexical pieces; a leading-dot basename alone has no extension; extension includes its leading dot. |
| `($path/relative target base)` | Relative path for compatible roots, otherwise PathError. No existence check. |

Filesystem APIs resolve relative paths against the application's captured launch directory. This rule applies to actual I/O, not to the pure functions above. Keep `$fs/real_path` as explicit symlink-aware resolution. Native-platform path conventions are supported on each qualified OS; parsing foreign Windows paths on POSIX is outside the initial surface.

`($fs/walk root ^follow_symlinks false ^max_depth 64 ^max_entries_per_dir 10000)` returns a synchronous Stream. Emit children in depth-first preorder, excluding root, sorted lexically per directory; each entry has absolute path, relative_path, kind, and size (nil if unavailable for that kind). Depth 1 means root's immediate children. Do not silently truncate: exceeding either limit raises FsLimitError. Filesystem disappearance/permission errors raise FsError. Following links is opt-in and uses directory identity to detect cycles; it may visit targets outside root and is not a confinement primitive.

Close directory handles on normal exhaustion, early Stream close, and error. Bound one directory's materialized sort list and total traversal stack. Document that a blocking filesystem scan can stall its calling lane; service code uses an explicit worker adapter after IO-2. A synchronous generator does not make OS calls nonblocking.

## APP-1/2: CSV with one incremental parser

Pin the dialect to [RFC 4180](https://www.rfc-editor.org/info/rfc4180/) quoting, accepting CRLF and LF record endings. Default comma delimiter and doubled double-quote escaping. Only one ASCII non-newline delimiter is accepted. Strict UTF-8; consume one UTF-8 BOM only at the start. Preserve whitespace and embedded quoted newlines. Empty input yields zero records; a blank line is one empty field. EOF may terminate the last record without a newline.

- `($csv/parse_rows text ^headers false)` returns a List for inputs up to 16 MiB.
- With headers false, rows are Lists of Str. With headers true, the first row names property-map fields; duplicate/empty headers and mismatched row widths fail. Fields stay strings: no implicit numeric, nil, or void conversion.
- `($csv/encode_row fields)` accepts a List of Str and returns Bytes with CRLF. No invented nil spelling; callers explicitly convert values.
- Limits: `^max_field_bytes` defaults to 1 MiB, `^max_record_bytes` to 8 MiB, `^max_columns` to 4,096, and convenience-call `^max_bytes` to 16 MiB. Allow positive caller overrides within an explicit deployment budget. The incremental reader accepts the same record limits. Errors report byte offset and record/field indices.

The engine consumes bounded Bytes chunks with incremental UTF-8 decoding and retains only the current incomplete record plus unconsumed chunk. Test splitting at every quote, CRLF, and multibyte boundary. It stops parsing when the consumer has no capacity; a feed call cannot accumulate all rows in a large chunk.

APP-2 adds `($csv/reader byte_reader ^headers false ^own_reader false)`. Its concrete `.next` returns a fresh Task yielding one row or nil at EOF; it implements IoResource for close/wait_closed and calls qualified AsyncReader methods internally. One next may be pending. Close cancels its own pending read and closes the upstream only with own_reader true. The caller must give this wrapper exclusive read use until it closes. Existing synchronous Streams remain synchronous; do not await inside a Stream pull. A bounded Str/List convenience API and this adapter share the same parser and row rules.

## APP-3: temporal arithmetic and tzdb

Common `$temporal` functions use existing Date, DateTime, and Duration values: `add_days date n`, `add datetime duration`, `difference left right`, `to_utc datetime`, `parse_rfc3339 text`, and `format_rfc3339 datetime`. Add/difference operate on fixed elapsed microseconds; Date addition uses calendar days. An offset is required for instant conversion/difference. Reject a named-zone-only or local DateTime where an instant is required, overflow, and unsupported leap seconds. Keep wall-clock values separate from `$os/monotonic_ms`.

genex/tzdb supplies `to_local instant zone` and `resolve_local datetime zone ^fold "reject"`. Fold choices are reject/earlier/later; nonexistent local times fail. Returned records contain the resolved DateTime, UTC instant, exact `offset_seconds`, zone, and tzdb release ID, so saved interpretations can be reproduced. Gene DateTime currently stores minute-precision offsets; for historical offsets containing seconds, the record's DateTime has exact local fields without an offset annotation while `instant` and `offset_seconds` retain the exact interpretation. Never consult an unrecorded host zone database. Package zone rules as resources through PKG-1; test folds, gaps, historical transitions, and replacing the data package without changing a pinned run.

## APP-4: archives

Use a declared zlib/native codec package input through PKG-2. First support gzip and ZIP store/deflate, regular files/directories, and UTF-8 names. Reject encryption, links, device files, unsupported methods, and Zip64 in this initial profile.

Gzip readers/writers implement AsyncReader/AsyncWriter and IoResource. Explicit flush drains buffered data but does not finalize gzip. A concrete `(writer .finish)` returns a Task that writes/verifies the final trailer and rejects further writes; the caller awaits it before close when a complete output is required. IoResource:close retains IO-1's abort semantics and never fabricates successful finalization. ZIP extraction takes an absent destination, builds a private sibling staging directory, verifies all entry sizes/checksums, then atomically publishes it with an exclusive destination-creation operation. No overwriting an existing tree, including one created by another process during extraction. Reject absolute/traversing paths, duplicate normalized paths, and symlink components; use safe directory-relative creation, not just a string-prefix check.

Default extraction caps are 10,000 entries, 128 MiB per entry, and 1 GiB total uncompressed data, enforced during decompression. Error/cancellation cleans staging or reports the retained cleanup path; it never reports a complete destination. Streaming codecs use [IO-1/2](async-io.md).

## Implementation seams and exit gates

| Stage | Touchpoints | Done when |
| --- | --- | --- |
| APP-1 | stdlib namespace registration, new path/CSV modules, focused Nim + Gene specs | Path edge cases and traversal limits pass; CSV parser is correct at every chunk boundary; existing FS/JSON behavior passes. |
| APP-2 | IO adapters and streaming CSV tests | 10× CSV input growth has bounded live parser memory; cancellation closes only owned endpoints. |
| APP-3 | temporal value adapters, genex/tzdb, PKG-1 resources | Arithmetic round trips and pinned zone revisions survive installation without checkout. |
| APP-4 | genex/archive, IO-2, PKG-2 | Corrupt/oversized/traversing archives never publish destination; partial writes and late native cleanup are covered. |

Each optional package declares supported platforms and ships conformance tests. The automation/data fixtures in [the profile](python-replacement-profile.md) use these public APIs; they must not add application-specific Nim shims.
