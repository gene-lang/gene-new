# genex/documents

Reusable, bounded inspection of document/image inputs. This package never
evaluates an uploaded document as Gene code.

`inspect_bytes name data` accepts Bytes and returns display name, detected MIME,
kind and byte size. It recognizes PNG, JPEG, WebP, PDF, DOCX and UTF-8 text/code
documents. Binary signatures determine image/PDF types; text inputs require an
allowed filename extension, strict UTF-8, and no NUL bytes. Inspection identifies
formats; downstream extraction/decoding must still validate document structure.

`display_name name` removes directory components and rejects empty, dot and
control-character filenames. Its output is metadata, never a storage path.

Import `extract_document` and `extract_pdf_page` from `./extract` in this package.
`extract_document scratch_root name bytes` returns text, truncation information,
and (for PDFs) total page count and the first two rendered page images. The
`^preview_pages` option accepts 0..4. `extract_pdf_page scratch_root name bytes
page` renders an explicitly requested one-based PDF page. Graphics-only PDFs
still return images even when extraction finds no text.

Converters receive literal argument arrays, never shell commands. PDF support
requires Poppler (`pdfinfo`, `pdftotext`, `pdftoppm`). DOCX currently requires
macOS `textutil` plus `unzip`; CRC validation does not extract filesystem paths.
Missing tools, encrypted/corrupt documents and timeouts raise `DocumentError`.
Limits are 10 MiB input, 20 seconds per process, 128 KiB UTF-8 text, 10000 PDF
pages and a 1600-pixel rendered long edge. Truncated text ends at a UTF-8 boundary.
Scratch directories are private and cleaned on success, failure and cancellation.
DOCX returns text only; embedded images are not extracted. Converters run as the
host user, so deploy them in an OS sandbox when accepting hostile documents.
