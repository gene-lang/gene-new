# genex/archive (experimental)

The format-1 package builds a target-checked C codec against declared zlib and
utf8proc system dependencies. Its fixed native ABI has bounded 64 KiB stream
steps for gzip and raw DEFLATE modes. The codec distinguishes ordinary
progress, need for more input, and verified stream completion; `Z_SYNC_FLUSH` does not finish
a gzip stream, while `Z_FINISH` must reach stream end to prove a trailer.

The Gene `codec_abi` probe verifies PKG-2 loading. `inspect_zip path` checks
the ZIP central/local records, supported store/deflate methods, UTF-8 paths,
size caps, duplicates, and link/device/encryption/ZIP64 rejection. It returns
the number of accepted entries or raises `ArchiveError`. Inspection also
checks local header and data-descriptor consistency, bounds individual and
total declared sizes, and rejects overlapping local records. It does not
verify decompressed checksums or publish a destination.

`extract_zip_sync archive_path destination_path` is the first ZIP extraction
surface. It requires an absent destination under a symlink-free parent path,
extracts into a private sibling directory using directory-relative creation,
verifies actual sizes and CRC32 before an exclusive rename, and removes the
staging directory on failure (or reports its retained name if cleanup fails).
The call blocks its Gene lane while work runs. The bounded native-worker Task
form below should be used by services.

`extract_zip archive_path destination_path` is the worker-backed Task form.
Cancellation requests native stop, waits cooperatively for staging cleanup,
and retires the worker before releasing the native library. A normal CLI
return also waits for this cleanup obligation if the Task was not awaited.
The Task returns the verified entry count; if cancellation arrives after the
exclusive rename, the complete destination and success result win.

`gzip_reader source ^!own_reader` and `gzip_writer sink ^!own_writer`
implement the standard qualified I/O protocols. The reader accepts multiple
gzip members and verifies end-of-stream; the writer distinguishes `.flush`
from `.finish`, and `IoResource:close` aborts without producing a false
trailer. Explicit close and repeated wait_closed Tasks retire codec and owned
upstream/downstream resources. Abandoned wrappers release their C codec and
FFI library without an explicit close. Unicode-normalized ZIP entry and parent
path collisions are rejected before extraction. Linux runtime qualification
remains open.
