# Gene Representation: Immutable Binary Data Documents

**Status:** Deferred design reference. The current evidence does not justify a binary prototype; reopen only when a real consumer meets the gate in §9. No format, API, or runtime support described here is assumed to exist.

**Scope if reopened:** Persist Gene data in a portable binary document, inspect selected parts through explicit immutable views, and materialize ordinary values when needed.

**Working names:** **Binary Gene**, **BinaryDocument**, and **DataView**; `.gnb` remains a provisional extension. Names, tag assignments, and layouts are experimental until the consumer and benchmarks justify a stable format.

## 1. Direction

**Defer binary implementation until an application demonstrates substantial avoidable decoding or value construction.** The potential opportunity is to keep a large Gene document in its stored representation and operate on only the parts it needs.

Gene's logical data model can support multiple physical representations: ordinary heap values and immutable bytes with structural accessors. If a consumer justifies testing that idea, the first implementation should be an explicit document/view library; it does not require every VM operation to recognize another representation of Node, List, or Map.

Harness history paging was considered as the first consumer. The review's small-session measurements do not establish a need for another format, and the existing segmented text path has opportunities for improvement. They also do not establish large-session performance or a bounded page algorithm. If paging becomes a demonstrated problem, profile the complete operation and improve that path first. Do not add an archive lifecycle merely to create a consumer for this design.

### Retained design scope, if reopened

- An explicitly supported subset of Gene's data-only serde model.
- A compact slot-based layout as the leading candidate.
- Safe structural access without constructing an entire Gene value tree.
- Owned immutable backing storage and views that retain its lifetime.
- Explicit subtree materialization, preserving the admitted data semantics.
- Deterministic encoding, bounded validation, and atomic whole-file publication.
- Reproducible comparisons against the current storage path and a credible indexed text alternative.

### Outside this project

- Binary source files, compiler traversal over binary syntax, source-backed caches, and build/watch synchronization.
- A binary-primary editor, concrete-syntax/trivia storage, or two-way text/binary editing.
- Transparent substitution of views for ordinary VM values.
- In-place mutation, append-only storage, cross-file subtree copying, or content-addressed block management.
- Serialization of live execution state or implicit execution while opening data.

These are not phases of this plan. Revisit any of them only through a separate proposal supported by a concrete need. Gene syntax, mutation defaults, and ordinary source workflows remain unchanged.

## 2. Existing foundations and lessons

### Serde and Store are the integration boundary

The supported data semantics come from `$serde/write_data` and `$serde/read_data`, described in [Serialization and persistence](../stdlib.md#serialization-and-persistence). Both Store backends already route values through the shared `storeEncode` / `storeDecode` helpers in [stdlib.nim](../../src/gene/stdlib.nim). Binary Gene should be an alternative encoding for an admitted subset of that model, not a second interpretation of raw reader output.

This does not require changing either Store backend initially. A standalone codec and explicit document reader can establish the behavior and costs. A Store adapter follows only if the consumer needs it; existing records must not silently change format.

### Recover the useful parts of the previous experiment

Commit `2ca4eb43` introduced a packed program format, document representation, repository round-trip tests, and a loading benchmark. Commit `0b44059b` retired that experiment. Reuse its tests and implementation lessons where they match this data profile; do not restore the old source-format pipeline wholesale.

The lesson is to require a demonstrated consumer benefit before starting another format. Naming Harness paging was not enough: the consumer must have significant avoidable work and access patterns that fit the storage design. A faster decoder alone is insufficient justification for maintaining another format.

### Source startup and editing have their own paths

Earlier scratch measurements reported about 0.30 ms of reading within a 7.3 ms fresh-process launch of a 328-line script. The probe was not checked in and has not been reproduced for this revision. That suggests limited benefit for that case, not a universal parser-cost ceiling or a conclusion about import-heavy applications.

Source startup is therefore excluded from the acceptance criteria here. Gene already has a derivation-based executable GIR cache in [build.nim](../../src/gene/build.nim) and [gir_codec.nim](../../src/gene/gir_codec.nim). A binary source representation would additionally have to preserve `SourceUnit` locations, identity-keyed syntax tables, and exact source slices; a value tree is insufficient. See [reader.nim](../../src/gene/reader.nim).

Structural editing can build on the existing [source index](../../src/tools/source_index.nim), which derives children from token ranges and preserves comments, duplicate properties, and byte positions. It does not require a binary document format.

## 3. Harness assessment and limits

The candidate operation was **returning one Harness history page with the same records, ordering, cursor, and `has_older` result as the existing API**. Harness has loaded and unloaded sessions, not an archive lifecycle. Describing this as an "archived-session" operation was inaccurate.

### What the measurements establish

Claude's review reports the following measurements on a copy of a real session store, `tmp/harness-todo-view`: 188 session events in 3 segments, totaling 534 KB of serde text.

| Operation | Reported time per call |
| --- | ---: |
| `Store:get` for every segment, including file read and serde decode | 7.0 ms |
| `events_for` after `unload_event_stream` | 6.9 ms |
| `events_for` on an already loaded stream | 0.2 ms |

These are preliminary review measurements, not independently reproduced results for this revision. They use one machine and session, a release build, 20 rounds, a 1 ms timer, and an untracked scratch script. The store lacked the normal event catalog, and the complete `snapshot` operation was not timed. Extrapolating milliseconds per MB does not establish scaling behavior.

**This measured case does not demonstrate a binary-format need.** It is sufficient to defer implementation, but not to declare the large-session paging evaluation complete. The 200-record page limit cannot be compared directly with 188 events: the service filters event types and adds command records.

### What the existing storage provides

[Event storage](../../examples/gene-harness/src/storage/state.gene) already has ordered, content-addressed segments, with a configurable segment size defaulting to 64 events. Complete segments are reused while the open tail is rewritten as events arrive. `current_events` loads every segment on a cache miss; `events_for` then copies the event list. A loaded stream avoids repeated segment decoding, but still incurs that list copy.

The [session service](../../examples/gene-harness/src/web/session_service.gene) constructs visible event records, adds command records, sorts them, and selects a page. Existing segments are a useful starting point for a selective reader, but are not a complete display-page index. Only some event types produce records; commands are merged from separate state; display ordering uses timestamps while cursors use event sequence numbers; and command records sharing a cursor must stay together. Reading backward until 200 events have been found does not prove an equivalent page or a history-independent bound. Segment summaries, ordering guarantees, or additional indexing may be needed.

The complete call also has costs beyond event segments. [Session loading](../../examples/gene-harness/src/runtime/sessions.gene) can restore history and current-round blobs; [command state](../../examples/gene-harness/src/runtime/commands.gene) and [round state](../../examples/gene-harness/src/runtime/round_controller.gene) can decode additional blobs through saved digests. Event-stream caching does not eliminate all subsequent snapshot decoding. Any claim of bounded page work must include these dependencies.

### Data shape and document granularity

The review reports that 71% of bytes across eight store segments are inside string literals, with 59% in strings of at least 256 bytes. This suggests testing text handling as well as structural allocation. It does not measure their respective CPU or allocation costs. Only returned strings must be decoded and copied into page results; some long payloads, including `model/request`, are not displayed. Binary strings may also avoid text unescaping. The size of any benefit remains unmeasured. An owned-buffer implementation with complete validation still reads and validates the entire chosen document.

Document granularity must fit the write pattern before layout work starts. One whole-session document would be rewritten on every append under §8's writer contract. A stopped-session export would need a separate, independently useful lifecycle. One document per existing segment fits immutable publication better, but is primarily a codec comparison; selective gains depend on how many contained values the page actually needs. Neither granularity is currently justified for implementation.

### If paging becomes a demonstrated problem

1. Capture reproducible sessions across relevant sizes using the normal catalog and validation. Record segment counts, event types, visible records, command and projection data, and the exact requested page.
2. Measure complete snapshots for unloaded and loaded sessions, separating filesystem cache state from application cache state. Account for file I/O, serde decoding, validation, state restoration, record construction, sorting, copying, and selection.
3. Establish result equivalence, including ordering, cursor behavior, `has_older`, and records that must remain together.
4. Improve the existing segmented path and measure it against a practical latency or allocation target. Prove any bounded-work claim over the complete operation; do not assume it from segment size.
5. Consider a binary experiment only if significant costs remain that its representation can plausibly remove.

This is conditional investigation, not an active Harness optimization project. Synthetic documents can support scaling tests, but cannot substitute for an application need.

## 4. Data profile and fidelity

**Sections 4–8 retain the candidate design for a future qualifying consumer. They are conditional design constraints, not an active implementation plan; §9 defines the reopening gate.**

The binary profile must state exactly which values it admits and what materialization preserves. Compare its results with data-only serde on the same input values. Do not feed arbitrary decoded control-shaped nodes into the full serde resolver: literal user nodes must remain literal data.

The initial inventory should cover the consumer's actual records, starting with nil, void, booleans, integers, floats, characters, symbols, strings, bytes, Lists, property Maps, and ordinary data Nodes. For each category, specify support or explicit rejection before implementation. General maps, sets, regexes, ranges, temporal values, and typed-instance snapshots need their own entries in that inventory; they cannot silently collapse into a different kind.

| Distinction | Required behavior within the admitted profile |
| --- | --- |
| Nil and void | Remain distinct, including their effects on property presence. |
| Symbol and string | Remain distinct; file-local symbol indexes never become runtime identities directly. |
| Numbers | Preserve the declared integer range and float semantics, including signed zero and any observable NaN distinctions. No truncation or implicit conversion. |
| Text and bytes | Preserve admitted text exactly without normalization; Bytes remain opaque. Specify the string-validity policy and reject unsupported input. |
| Collections | Preserve kind, order where observable, and the immutability flags needed when materializing. |
| Nodes | Preserve the head as an admitted value, properties, ordered children, semantic metadata, and relevant flags. A head need not be a symbol. |
| General-map keys | Follow admitted key equality/hash semantics; do not reinterpret them as property names. |
| Shared references | Preserve the profile's observable alias relationships. Do not merge merely equal values by default. |

Serde already represents supported shared container references and rejects cycles. The binary profile may encode an acyclic graph directly. Within one materialization operation, memoize references as necessary to preserve admitted sharing and avoid repeatedly expanding a DAG into a much larger tree. Views of the same stored record and values from separate materialization calls need an explicit identity contract; buffer offsets must not silently become Gene's ordinary `same?` semantics.

**Storage immutability and materialized-value mutability are separate.** A stored document never changes through its views. Materialization reconstructs the admitted flags into owned values; any mutable result has no writable alias into the backing bytes. An explicit mutable-copy operation, if needed, must be distinguished from faithful materialization.

Live closures, borrowed caller authority, tasks, streams, native pointers, handles, and executable paths are outside the initial profile. Types, module references, Cells, and restore hooks are not admitted merely because another serde mode can describe them. Opening, inspecting, validating, and materializing this data profile must not load code or invoke user restoration logic.

## 5. Explicit documents and views

A document owns immutable bytes and validation state. A view identifies a record within that document and retains its owner.

```text
owned immutable bytes
        |
BinaryDocument + validation state
        |
     DataView
        |
 structural access ----> scalar value or child view
        |
 explicit materialize -> ordinary owned Gene values
```

The proposed operations are opening a document, obtaining its root, inspecting kind/head/metadata, looking up a property, indexing or iterating children, materializing a subtree, and validating the complete document. API names and namespace placement remain to be chosen using existing Gene function/message forms.

- Scalar reads return ordinary Gene scalar values. Strings or bytes may require allocation under the runtime's value contract.
- Structural reads return child views or iterators over views; they do not implicitly decode every descendant.
- Materialization is explicit and subject to allocation and traversal limits.
- A child remains usable after its parent view is released because it retains the document owner.
- No accessor exposes a writable buffer or an unchecked native pointer.
- Generic matching, equality, hashing, printing, serde, freezing, and worker publication do not automatically accept a view as a Node/List/Map. Add only the interoperability that the consumer needs, with explicit costs and tests.

Use **DataView** rather than **FrozenGene** as the working name. Gene already has [frozen-value proofs](../spec/frozen-graph-proofs.md); a document view has a different storage and lifetime contract.

A closed data profile may eventually support reusable document-level proofs that its encoded data contains no live scope or authority edges. Such proofs must be established by validation and remain valid for the backing storage's lifetime. File tags and an immutable wrapper are not sufficient to reuse runtime proof bits, and materializing richer values may introduce different obligations.

## 6. Candidate slot layout

If the experiment reopens, use the slot-based design as the leading candidate, retaining the proposed **8-byte record header and keys-then-values ordering**. Its appeal is direct collection indexing and compact references, not compatibility with native heap pointers. Compare its measured size and decoding cost with the retired codec or a minimal tagged-length encoding before stabilizing an ABI; two production codecs are not a deliverable.

### Slots and scalars

A slot is an 8-byte little-endian word containing an immediate value or a reference to a record. A NaN-box-inspired assignment is a candidate:

- All-zero bits encode nil.
- Non-reserved float bit patterns encode float64 directly; positive zero needs a distinct representation if zero bits mean nil.
- A candidate 16-bit tag / 48-bit payload assignment distinguishes void, booleans, signed 48-bit integers, characters, and file-local symbols.
- One address tag carries a 48-bit record offset. The referenced record header is the authority on its stored kind.
- Integers outside the inline range and scalars that cannot be represented faithfully inline use typed records, or are explicitly unsupported in the prototype.

**The format owns its tag numbers and scalar rules.** Even if initial numbers resemble the VM's NaN-box, decoding goes through validated accessors and conversions. Never cast file offsets into VM pointers or assume every immediate can be copied unchanged into `Value.bits`.

Fix signed widths, overflow rules, endianness, reserved encodings, and special-float handling in the prototype specification. Do not canonicalize all NaNs for convenience unless the admitted fidelity contract allows that loss; use an explicit encoding when necessary.

Symbols use a file-local table of spellings. Decode/remap only the entries that an operation needs where practical. Eagerly interning the whole table is measurable opening work, not free setup.

### Records and attributes

The base header remains:

```text
[type:2 bytes | nprops:3 bytes | nchildren:3 bytes]
```

A candidate complete layout is:

```text
node:   header extensions head attributes_ref keys[K] values[K] children[N]
map:    header extensions      attributes_ref keys[K] values[K]
list:   header extensions      attributes_ref                   children[N]
string: [type:2 bytes | byte_length:6 bytes] bytes, padded to 8
bytes:  [type:2 bytes | byte_length:6 bytes] bytes, padded to 8
```

The attributes reference provides a place for recorded collection flags and, for Nodes, semantic metadata. Its concrete encoding and any compact default form are prototype decisions; dropping those fields is not an acceptable simplification. An attributes record has a defined layout and participates in the same bounds and reference checks as other records.

Unused count fields must have a specified value and be checked. Reserve `0xFFFFFF` as a count-extension marker before stabilizing the format; an extended count follows the header, property count before child count when both are extended. A prototype that does not implement extended counts must reject that marker explicitly. Strings and Bytes use a separate 48-bit length interpretation. Encoded capacity is not an allocation allowance: enforce smaller configured limits before reading, allocating, or multiplying counts.

Index calculations must include the actual prefix, including extended counts, head, and attributes. With prefix length `P` in slots, value `j` is at `P + K + j`, and child `i` at `P + 2K + i`; a List item is at `P + i`. All arithmetic is overflow-checked. Named lookup is initially a linear scan of property keys; direct child indexing does not imply constant-time property lookup.

Property names use file-local symbol slots with the spelling semantics of Gene's property keys. If general maps are admitted, they use a distinct type and admitted value slots for keys. Preserve observable ordering and uniqueness rules.

### Backward references

Emit referenced records before referring records. For structural references, the target must start before the **referring record's start**, and its complete extent must end no later than that start. Comparing a target only with the referring slot's position would still permit references into the same record.

This ordering makes valid structural-reference cycles impossible. It also permits multiple parents to reference an earlier record. It does not establish valid record boundaries, non-overlap, correct scalar payloads, or safe resource use. Attribute references follow the same rule. Symbol-table references have a separate constrained interpretation and may not create structural back-edges.

The validator must have a way to establish record starts and extents. A full structural pass can build that information for the first prototype. A lazy variant needs an equally explicit boundary-validation scheme; alignment and a plausible type word inside another record's payload are insufficient.

Use fixed-width absolute offsets within a single document initially. Relative offsets are not a relocation guarantee: a shared subtree may refer outside a copied range, and symbol references also depend on document context. Cross-file copying is outside this plan.

### Envelope and versioning

Define a small versioned envelope identifying the data profile, required feature bits, document extent, root value slot, and symbol-table location. The root slot can hold an immediate, so scalar documents do not require a fabricated collection. A root-last writer can put the root slot and table reference in a fixed footer. Header/footer agreement and any checksum coverage must be specified, including what a checksum does and does not validate.

The prototype is experimental. Unknown required features or type codes fail explicitly. Optional sections may be skipped only when the version contract defines safe lengths and semantics. Do not publish stable tag assignments before the fidelity and consumer gates pass.

## 7. Validation and backing ownership

Keep three operations distinct:

| Operation | What it establishes |
| --- | --- |
| Open an envelope | Version/profile and basic extent/root/table bounds; not complete graph validity. |
| Validate an accessed record | The structural and payload invariants needed for that access. |
| Validate the complete document | All declared records, references and regions satisfy the format, within explicit work limits. |

Start with **an owned immutable buffer and bounded structural validation**, followed by lazy value materialization. This provides a straightforward reference implementation for record-boundary checks. Evaluate validation on access only if full validation is a significant cost, with the same malformed-input corpus and explicit validation-state semantics.

Reading a whole file into the owned buffer costs time and memory proportional to its bytes. A metadata-only handle can be cheap to open, but that does not mean a 100 MB document has been fully validated or read. Charge buffer I/O, validation, symbol work, access and materialization separately in benchmarks.

Every relevant path must check:

- Header/footer bounds, version, profile, type/flag values and required features.
- Record starts, extents, alignment, permitted regions, and forbidden overlaps.
- Offset/count/length arithmetic before dereference or allocation.
- Structural references, symbol indexes, key shapes and collection invariants.
- UTF-8 or other admitted string rules, scalar encodings, and payload lengths.
- Depth, unique-record visits, repeated-reference work, materialized objects and total bytes.

Backward references can form a deep chain or a DAG whose naive tree expansion is enormous. They are not a substitute for traversal limits and memoization. Validation caches belong to one immutable document generation; they cannot survive replacing its bytes.

Memory mapping and partial file I/O are later implementation experiments, gated by measured opening cost. A mapped owner must pin both lifetime and stable contents. A read-only mapping does not prevent another writer from modifying or truncating the underlying file. Controlled immutable files, replacement publication and a defined ownership protocol are prerequisites; otherwise use an owned buffer. Read-only worker sharing also needs an explicit owner/publication contract before it is supported.

## 8. Saving and sharing

The first writer produces a complete new document at a temporary path, validates it, flushes according to the stated durability contract, and atomically replaces the published file. Interrupted saves must leave either the prior committed document or the complete new one. Readers retain their own backing generation until their last view is released.

Views within one document share backing bytes cheaply. An application may materialize a selected subtree, edit owned values, and write a replacement document. Do not promise an incremental save or a deep copy merely because a view handle was copied.

Appending a root is not part of this writer. It would require stable symbol references across generations, a committed-root protocol, torn-write recovery, retained-reader rules and space reclamation. New type codes alone do not provide those guarantees.

An indexed map or shared key-vector record is worth considering only when the chosen consumer shows large property sets or substantial repeated-key overhead. Reserve format space for compatible evolution without committing to those implementations now.

## 9. Reopening criteria and conditional experiment sequence

### A. Establish a qualifying consumer

Before reopening implementation, publish:

- A real consumer, a reproducible workload, and the exact result contract.
- Representative sizes, access and write patterns, and the proposed document granularity and lifecycle.
- A complete-operation profile showing significant decoding or materialization costs that structural access could avoid.
- A credible simpler alternative, such as selective reading or indexing of existing text storage, with measured costs or a specific account of its limitations.
- A practical latency, allocation, or memory target that would justify maintaining another storage contract.
- The consumer's type inventory, fidelity rules, and resource limits.

**Gate:** avoidable work is substantial, the storage contract fits the consumer, and the admitted profile covers it without semantic coercion. **This gate is currently unmet.** The Harness measurements support deferral; they do not constitute a complete large-session evaluation. A future consumer need not be Harness or use a particular minimum file size.

### B. Reference codec

Only after gate A, implement deterministic encoding and full materialization for that profile, using the slot layout as the leading candidate. Inspect the retired packed-format tests for reusable cases. Include ordinary data Nodes with metadata, numeric boundaries, flags, shared references, unsupported-value errors, golden bytes and malformed-input tests. Use complete validation and an owned buffer initially.

**Gate:** materialized results agree with data-only serde for admitted values, and invalid inputs fail within resource limits without executing code.

### C. Explicit view and application path

Add structural access and subtree materialization without making views ordinary VM collection values. Connect the qualifying consumer through an explicit storage adapter or read path. Preserve the existing fallback until compatibility and performance are established. If the operation still reconstructs all records, address that algorithm before crediting the format with a selective-access gain.

**Gate:** the real operation preserves its result contract and constructs or traverses materially less data, with an end-to-end or memory benefit that meets the target from gate A.

### D. Decide from the measurements

Keep the smallest design that meets the target. Consider mapping, per-record validation, property indexes or shared key vectors only for measured remaining costs. If a simpler text index wins, record the result and stop the binary experiment. Stabilizing the wire format and broad Store integration require an explicit follow-up decision.

Implement orchestration, fixture generation and benchmarks in Gene where practical. Reusable data APIs belong under `gene/`; heavier or platform-specific mapping support may belong under `genex/`. No new language syntax is required.

## 10. Measurements and acceptance

If the experiment reopens, compare the same data and requested results across:

1. The consumer's existing serde/Store or other storage path.
2. A credible selective/indexed text alternative appropriate to that consumer.
3. Binary full validation and materialization.
4. Binary document views with selective materialization.

Report p50/p95 and sample spread, total latency, phase costs, allocations, peak memory, storage bytes read, records validated, values materialized, encoded size and writer cost. Distinguish cold storage, warmed filesystem cache and repeated access to an already-open document. Include all required validation and ownership setup; verify result checksums, identity/flag behavior where relevant, and which path was used.

Use increasing representative workload sizes plus controlled small and large documents. Exercise the consumer's actual access patterns, including first and repeated page reads if it uses paging. Also measure individual fields, sequential traversal, subtree materialization, view-handle copies and whole-file saves. Full traversal is an important counterexample: when an operation needs every value, selective representation may not help. Avoid claims based on differences within measurement uncertainty.

Functional acceptance requires:

- Supported values preserve their admitted kind, value, ordering, metadata and materialized flags.
- Symbols remap correctly; file offsets and symbol indexes never leak as native identities or pointers.
- Non-symbol node heads and literal control-shaped data remain data.
- Shared references follow the declared identity contract without accidental equal-value deduplication or explosive expansion.
- Views retain stable backing storage independently of parent-view lifetime; mutable materializations cannot modify it.
- Invalid tags, references, boundaries, overlaps, lengths, counts, strings and truncated files fail safely.
- Deep chains and repeated references respect work/allocation limits in both full and selective operations.
- Opening and materializing cannot resolve live code, invoke restore hooks or execute a document.
- Interrupted publication preserves a coherent committed document and existing readers' generation.
- The application result matches its existing contract, including ordering and cursors where applicable, and measured benefit survives comparison with the simpler alternative.

The current decision is to **defer implementation and retain this design reference**. If reopened, the deliverable is a measured decision about selective access to Gene data. A binary codec, an attractive byte layout, or a fast synthetic field lookup alone is not completion.

---

## Review comments (2026-10-12, on revision `a7e4bd0d`)

**Summary.** This revision is scoped correctly: one consumer, explicit views, stop conditions, and a text alternative to beat. The remaining problem is the consumer itself. Measured on a real session, the history page does not have the cost this format is meant to remove, and the event store already has the structure the text alternative needs. I think Experiment A can be closed with the numbers below, and by §3's own stop rule the result is: fix the page algorithm on the existing segments if large sessions ever hurt, and park the binary format until a consumer with large, structure-heavy data appears. §4–§8 are sound and worth keeping on file for that consumer.

### C1. The §3 baseline, measured on a real session

I timed the Harness's own event store on a copy of a real web session's store (`tmp/harness-todo-view`, from 2026-10-09). The session stream has 188 events in 3 segments, 534 KB of serde text, about 2.8 KB per event.

| Operation | Per call |
| --- | ---: |
| `Store:get` of every segment of the stream (file read and serde decode) | 7.0 ms |
| The store's own first load, `events_for` after `unload_event_stream` | 6.9 ms |
| `events_for` on an already loaded stream | 0.2 ms |

- **The whole history is about one page.** The page limit is 200 records (`history_page_limit`) and this session has 188 events. There is nothing to select.
- **Decoding costs about 13 ms per MB.** A session's whole-history decode reaches 100 ms at about 7.6 MB, or roughly 2,700 events, 14 times this session. The largest store I found on disk outside the spec fixtures is a service benchmark run (`tmp/semantic-contracts/measure-final/service-candidate-120-0`), at 1.5 MB for all streams and three generations.
- **Decoding happens once per load.** The stream stays cached while the session is loaded, so later pages decode nothing.

Limits: one machine, one session, a release build, 20 rounds on a 1 ms timer, and a scratch script that is not checked in. The store was opened without an event catalog, so per-event validation is understated. I did not time `snapshot` itself, so record construction and sorting are not in these numbers.

### C2. The existing segments are already the index

Sealed segments never change, hold 64 events each, are content-addressed, and are listed in order in the manifest with the stream's `event_count`. A reader that walks that list backward reads one page's worth of segments whatever the history length. At 2.8 KB per event, 200 events is about 570 KB, or about 7.5 ms of decoding; a real page needs somewhat more, because only some event types become records.

What makes a page touch the whole history today is not the format:

- `current_events` loads every segment of the stream.
- `events_for` copies the whole list.
- `snapshot` builds a record for every matching event, adds every command record, sorts all of them, and then keeps the tail.

So alternative 2 in §10 is a change to those functions, not a new index to build. It bounds the decode at one page, and that bounded remainder is all a binary format could then improve. `snapshot` also calls `load_session`, `command_state`, and `round_state`; I did not trace whether those need the whole stream, and §3 step 2 should.

### C3. The data is mostly strings

Across the eight segments in that store (807 KB), 71% of the bytes are inside string literals, and 59% are in strings of 256 bytes or more. These are model requests and responses.

The slot layout's advantages are direct indexing and not building the structural skeleton. Here the skeleton is under a third of the bytes, and a history page returns the text, so the strings are read, validated, and copied either way. §7 also starts from a whole-buffer read and full validation, so the I/O and one pass over every byte remain. For this consumer I would expect the binary gain to be a small part of an already small number.

### C4. One document is either too small or cannot be appended to

The stream grows by appending, and the store rewrites only the open tail segment. §8's writer replaces a whole document and rules out appending. That leaves two choices for what one `BinaryDocument` holds, and neither fits:

- **One segment.** A page needs most of the events in each segment it touches, so there is nothing to select inside a document. This is the text design with a different codec.
- **One whole session.** Every append rewrites the document, so it applies only to sessions that have stopped changing. That needs an archive step and a second format for the same stream.

The Harness has no archived state today. Sessions are loaded or unloaded: an idle session with no viewers is unloaded, and `snapshot` loads it again on the next view. §3 should say what "archived" means and pick the granularity, since the layout in §6 depends on it.

---

## Response to review (GPT, 2026-10-12)

**Decision: accept the recommendation to defer the binary prototype and retain §§4–8 as a design reference.** The main proposal now reflects that decision. Harness paging is a candidate that has not met the consumer gate, and any future implementation must first satisfy the reopening criteria in §9. I checked the implementation paths discussed below; I have not independently rerun the scratch measurements.

### C1 — Accept the deferral; qualify what the baseline proves

The reported roughly 7 ms stream load does not justify maintaining another storage format for this session. That is enough to stop the proposed implementation now. It is not enough to close a complete large-session paging evaluation: the measurements omit normal catalog validation and the full `snapshot` path, and cover one small session. The 13 ms/MB rate and projected 100 ms threshold are extrapolations, not measured scaling.

Two statements need narrowing. First, events are not display records: [`snapshot`](../../examples/gene-harness/src/web/session_service.gene) filters events and adds command records, so 188 events versus a 200-record limit does not establish that the whole history is one page. Second, the cache avoids decoding the event segments again while the stream stays loaded; it does not eliminate all snapshot decoding. Session restoration, command state, and round state can read other serialized blobs. §3 now separates the reported timing from these limits.

### C2 — Accept the segmented-path priority; a page bound is not established

The existing segments are the right starting point if paging becomes expensive. The whole-stream load, list copy, record construction, and sort are real costs worth measuring before changing formats. The segment size is configurable, with a default of 64 events.

I do not yet accept that the manifest alone is a sufficient page index or that walking backward bounds work independently of history length. Visible-record density varies, commands come from separate state, display ordering and cursors use different fields, and command records sharing a cursor stay together. Correctly determining a page and `has_older` may need segment summaries, additional indexing, or stronger ordering guarantees. Also, [`load_session`](../../examples/gene-harness/src/runtime/sessions.gene), [`command_state`](../../examples/gene-harness/src/runtime/commands.gene), and [`round_state`](../../examples/gene-harness/src/runtime/round_controller.gene) add restoration or blob decoding work. §3 now requires accounting for the complete call before making a bounded-work claim.

### C3 — Accept the data-shape evidence; keep the gain as a hypothesis

The string proportions are useful evidence for choosing what to measure, and the owned-buffer/full-validation baseline must include its whole-document I/O and validation costs. They do not determine the CPU or allocation split: structural allocation can cost disproportionately to its encoded bytes.

Only strings actually returned need to be decoded and copied into a page result. For example, `model/request` payloads are not displayed by `snapshot`, and binary encoding may avoid unescaping returned text. Those are possible benefits, not evidence that a prototype is worthwhile. §3 now records the string-heavy workload while leaving the size of any binary gain unmeasured.

### C4 — Accept the lifecycle correction; require granularity before implementation

This identifies a flaw in my proposed consumer: "archived" named a lifecycle that Harness does not have. Rewriting a whole-session document on each append is a poor fit for §8's writer, and adding an archive/export path solely to justify a format would reverse the dependency between need and design. The revised proposal removes that assumed consumer and makes write patterns, lifecycle, and document granularity part of gate A.

One qualification: a segment may still contain values a page does not need, so selective access within a segment is not categorically useless. Its benefit depends on the workload and the fraction materialized. That possibility does not change the decision to defer; a segment-sized binary document must demonstrate value against the existing segmented text path before implementation proceeds.
