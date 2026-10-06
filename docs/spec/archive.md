# Experimental `genex/archive`

`genex/archive` is an optional format-1 package with target-checked zlib and
utf8proc system dependencies in its `c_library` recipe. `inspect_zip path`
returns the accepted entry count after
checking metadata without creating output. `extract_zip_sync archive_path
destination_path` performs the same extraction synchronously for CLI use.
`extract_zip archive_path destination_path` returns a root-lane Task whose
native worker performs extraction; at most 16 worker jobs are retained. The
Task returns the verified entry count or raises `ArchiveError`.

The initial ZIP profile accepts stored and DEFLATE regular files/directories
with valid UTF-8 names. It rejects encryption, links/devices, unsupported
methods/flags, ZIP64, unsafe path segments, duplicate NFC/case-folded names
and directory prefixes,
conflicting local/central records, and overlapping data regions. Limits are
10,000 entries, 128 MiB declared and actual output per entry, 1 GiB total
declared output, 64 MiB central-directory metadata, and 100,000 directory
prefixes within 64 MiB of normalized-prefix metadata. Actual extraction
checks uncompressed size and CRC32. Other ZIP metadata is not applied to the
filesystem.

The destination must be absent and its parent path must contain no symlink
components. Extraction uses a private sibling staging directory, safe
directory-relative creation, 0600 files, and an exclusive final rename.
Corrupt data and pre-commit cancellation remove staging before the Task
settles; a cleanup failure reports the retained stage name and destination
context. Immediate cancellation starts no native job. The exclusive rename is
the commit point: cancellation after it returns the verified success result
and leaves the complete destination. Normal CLI return waits for registered
I/O cleanup Tasks before process exit. A competing destination is never
replaced.

`gzip_reader source ^!own_reader` implements `AsyncReader` and
`IoResource`; `gzip_writer sink ^!own_writer` implements `AsyncWriter` and
`IoResource`. Both use bounded 64 KiB zlib steps and reject overlapping
operations. The reader accepts concatenated gzip members, verifies the trailer,
and rejects truncation and trailing junk. Writer `flush` drains a sync marker
and the downstream writer without finalizing the stream. Its concrete
`.finish` writes the final trailer, flushes downstream, and rejects later
writes; `IoResource:close` aborts and never claims a successful finish. Owned
upstream/downstream resources close only when their ownership option is true.
Every `wait_closed` call returns a fresh Task for physical cleanup.

Owned C codec pointers retain their FFI library until native release. Explicit
close and abandoned-wrapper reclamation retire the codec first; an unreachable
FFI library is then closed. The installed macOS probe checks that dropped gzip
reader/writer wrappers leave zero live codec streams.

Unicode normalization uses the declared utf8proc provider and is checked
before extraction; filesystem-exclusive creation remains a second defense.
Linux compile-only checks pass, but Linux runtime qualification remains open.
