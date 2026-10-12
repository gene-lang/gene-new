# Gene Representation: Immutable Binary Data Documents

**Status:** Design proposal and experiment plan. No format, API, or runtime support described here is assumed to exist.

**Scope:** Persist Gene data in a portable binary document, inspect selected parts through explicit immutable views, and materialize ordinary values when needed.

**Working names:** **Binary Gene**, **BinaryDocument**, and **DataView**; `.gnb` remains a provisional extension. Names, tag assignments, and layouts are experimental until the consumer and benchmarks justify a stable format.

## 1. Direction

**Explore whether an application can keep a large Gene document in its stored representation and operate on only the parts it needs.** Avoiding unnecessary value construction, decoding, and traversal is the main opportunity.

Gene's logical data model can support multiple physical representations: ordinary heap values and immutable bytes with structural accessors. This proposal tests that idea through a data-storage consumer. The first implementation is an explicit document/view library; it does not require every VM operation to recognize another representation of Node, List, or Map.

The first experiment is **retrieving one history page from a large archived Harness session**. Establish the existing cost and access requirements before designing the format around it. If an improvement to the existing segmented text path delivers the same benefit with less complexity, prefer that result.

### Included

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

The important change in this proposal is a named consumer and a selective-access experiment. A faster decoder without an application that uses it is insufficient justification for maintaining another format.

### Source startup and editing have their own paths

Earlier scratch measurements reported about 0.30 ms of reading within a 7.3 ms fresh-process launch of a 328-line script. The probe was not checked in and has not been reproduced for this revision. That suggests limited benefit for that case, not a universal parser-cost ceiling or a conclusion about import-heavy applications.

Source startup is therefore excluded from the acceptance criteria here. Gene already has a derivation-based executable GIR cache in [build.nim](../../src/gene/build.nim) and [gir_codec.nim](../../src/gene/gir_codec.nim). A binary source representation would additionally have to preserve `SourceUnit` locations, identity-keyed syntax tables, and exact source slices; a value tree is insufficient. See [reader.nim](../../src/gene/reader.nim).

Structural editing can build on the existing [source index](../../src/tools/source_index.nim), which derives children from token ranges and preserves comments, duplicate properties, and byte positions. It does not require a binary document format.

## 3. First consumer and baseline

The candidate operation is: **open an archived Harness session and return one history page with the same records, ordering, cursor, and `has_older` result as the existing API**.

Relevant paths are [event storage](../../examples/gene-harness/src/storage/state.gene) and [session service](../../examples/gene-harness/src/web/session_service.gene). Event storage already uses segments and projections. Its `current_events` path loads a stream's segments into a collection; the session service constructs and orders records before selecting a page. These are observations about the current implementation, not proof that decoding dominates it.

Before writing the codec:

1. Capture a reproducible large-session fixture using the existing APIs. Record sizes, segment counts, record types, projection data, and the exact operation being timed.
2. Separate file I/O, serde decoding, event validation, projection/reconstruction, sorting, copying, and page selection. Determine which work the requested page actually requires.
3. Compare the current path with a bounded page reader or index over the existing segments. Binary bytes do not by themselves remove a full-history sort or replay requirement.
4. Define a result-equivalence check, including cursor behavior and records that must remain together on a page.
5. Set a practical latency or allocation target from that baseline before choosing the format's complexity.

If the operation necessarily consumes the whole history, or decoding/allocation is insignificant, stop this experiment or name a better consumer. Do not substitute a synthetic 100 MB file as proof of application value. Synthetic files remain useful for controlled scaling tests.

## 4. Data profile and fidelity

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

Prototype the slot-based design first. Retain the proposed **8-byte record header and keys-then-values ordering**. Its appeal is direct collection indexing and compact references, not compatibility with native heap pointers. Compare its measured size and decoding cost with the retired codec or a minimal tagged-length encoding before stabilizing an ABI; two production codecs are not a deliverable.

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

## 9. Experiment sequence and decision gates

### A. Consumer and semantic profile

Measure the archived-session page operation and its credible text/index alternative. Publish the fixture, requested result, cost breakdown, type inventory, fidelity rules, limits and success target. Inspect the retired packed-format tests for reusable cases.

**Gate:** there is avoidable work that a selective representation could remove, and the admitted profile covers the consumer without semantic coercion.

### B. Reference codec

Implement deterministic encoding and full materialization for that profile, using the slot layout as the leading candidate. Include ordinary data Nodes with metadata, numeric boundaries, flags, shared references, unsupported-value errors, golden bytes and malformed-input tests. Use complete validation and an owned buffer initially.

**Gate:** materialized results agree with data-only serde for admitted values, and invalid inputs fail within resource limits without executing code.

### C. Explicit view and application path

Add structural access and subtree materialization without making views ordinary VM collection values. Connect the archived-page experiment through an explicit storage adapter or read path. Preserve the existing fallback until compatibility and performance are established. If paging still reconstructs all records, address that algorithm before crediting the format with a selective-access gain.

**Gate:** the real operation returns the same page/cursor and constructs or traverses materially less data, with an end-to-end or memory benefit worth the added storage contract.

### D. Decide from the measurements

Keep the smallest design that meets the target. Consider mapping, per-record validation, property indexes or shared key vectors only for measured remaining costs. If a simpler text index wins, record the result and stop the binary experiment. Stabilizing the wire format and broad Store integration require an explicit follow-up decision.

Implement orchestration, fixture generation and benchmarks in Gene where practical. Reusable data APIs belong under `gene/`; heavier or platform-specific mapping support may belong under `genex/`. No new language syntax is required.

## 10. Measurements and acceptance

Compare the same data and requested results across:

1. The existing serde/Store and Harness path.
2. A credible bounded/indexed reader over existing text segments.
3. Binary full validation and materialization.
4. Binary document views with selective materialization.

Report p50/p95 and sample spread, total latency, phase costs, allocations, peak memory, storage bytes read, records validated, values materialized, encoded size and writer cost. Distinguish cold storage, warmed filesystem cache and repeated access to an already-open document. Include all required validation and ownership setup; verify result checksums, identity/flag behavior where relevant, and which path was used.

Use increasing real-session sizes plus controlled small and large documents. Exercise first-page reads, repeated pages, individual fields, sequential traversal, subtree materialization, view-handle copies and whole-file saves. Full traversal is an important counterexample: when an operation needs every value, selective representation may not help. Avoid claims based on differences within measurement uncertainty.

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
- The application result matches the current history-page contract, and measured benefit survives comparison with the indexed text alternative.

The deliverable is a measured decision about **selective access to Gene data**. A binary codec, an attractive byte layout, or a fast synthetic field lookup alone is not completion.
