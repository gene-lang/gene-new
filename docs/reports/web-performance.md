# Web-profile size and performance baseline

Status: **P2–P5 baseline measured on 2026-07-29.** Run
`nimble transpile_perf` to reproduce the numeric experiment and the backend
measurements. Inputs live in `benchmarks/data/`; the pinned dependency-free
`gene-line-minifier-v1` strips generated comments/indentation and gzip uses
Node zlib level 9.

Latest local run: Apple host, Node v25.9.0. CI is pinned to Node 22.17.0, so
compare timings only on the same host/tool version.

| isolated fixture | readable ESM | minified | gzip |
|---|---:|---:|---:|
| scalar checked export (core) | 632 B | 448 B | 215 B |
| recursive `(List Int)` validation | 835 B | 639 B | 278 B |
| structural list equality | 1,469 B | 1,223 B | 442 B |
| checked callback round trip | 1,387 B | 1,159 B | 384 B |
| structural `Map` | 2,512 B | 2,207 B | 793 B |
| protocol + nominal dispatch | 4,019 B | 3,697 B | 1,152 B |
| closed-schema nominal type | 1,786 B | 1,529 B | 595 B |
| stream wrapper | 1,971 B | 1,671 B | 602 B |
| structured task/cancellation | 1,975 B | 1,697 B | 617 B |
| node→DOM edge | 1,938 B | 1,703 B | 738 B |

These are isolated totals, not byte subtraction. Helper families are emitted
only when analysis proves they are needed. In particular, map/object equality
branches do not appear in a list-of-Int equality module, and stream,
cancellation, protocol, schema, and DOM helpers contribute zero bytes to the
core fixture.

The fixed exported `work(Int): Int` probe measured **7.72 ns/call** and **0
retained heap bytes/call** over one million warm calls. Rebuilding its one
module graph in a warm loop measured **3.58 ms median** over 25 compiler
processes. Retained bytes are measured after GC and do not claim zero transient
V8 allocation.

Compared with the P2.5 baseline, core and recursive-list totals are unchanged;
runtime improved from 8.07 to 7.72 ns/call and the compile median moved from
3.99 to 3.58 ms on this host. Structural-list equality grew from 1,307 to 1,469
readable bytes (396 to 442 gzip) because the admitted `Sym` kind requires the
recursive equality helper to preserve symbol value semantics. Against the
previous P5 run, immutable-map construction plus the public `has` operation
saved 68 readable bytes, while
protocol boundary conformance and immutable typed-node construction added 1,134,
ordered-body schema validation and immutable construction added 352, and
immutable raw-node construction added 128. Structured task cleanup saved
71 readable bytes. These costs are isolated to their feature fixtures; the
core, list, equality, callback, and stream artifacts did not grow.
