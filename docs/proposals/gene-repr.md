# Gene Representation: Text, Binary, and Frozen Views

**Status:** Design proposal; no binary format, editor integration, or runtime support is assumed to exist.  
**Scope:** A binary representation of Gene code and data, fast structural loading and traversal, immutable/zero-copy views, and eventual editing in a structure-aware editor.  
**Working name:** **Binary Gene**; `.gnb` is a provisional file extension. All APIs and byte layouts below are proposals, not existing Gene features.

## 1. Motivation and central idea

Gene has a distinctive advantage: code and data can use the same structured node model. Today, a typical text-based workflow reads UTF-8 source, tokenizes and parses it, allocates a Gene syntax/value tree, and then either interprets the data or compiles the code. For large files, the work of scanning text, interpreting syntax, allocating objects, and copying subtrees can be significant.

The proposal is to make **text and binary two native representations of the same Gene structure**, with an editor able to display and modify code or data while saving a structured binary file.

```text
Text Gene (.gene)                         Binary Gene (.gnb)
       |                                         |
       v                                         v
   Text reader                           Binary validator
       |                                         |
       v                                         v
   Gene structure <------ equivalent ----> FrozenGene view
       |                                         |
       +--------------+--------------------------+
                      |
            data APIs or code compiler
                      |
                execution / use
```

A binary format alone reduces *parsing overhead*. Its most ambitious payoff comes when consumers can **access a validated byte-backed representation without materializing an entire object tree**. This distinction drives the design.

### Goals

1. **Semantic fidelity:** represent the supported Gene data and source structures without losing distinctions important to reading, compilation, macros, or evaluation.
2. **Fast startup and loading:** skip text tokenization and much of tree construction when loading binary files.
3. **Lazy, low-allocation access:** read fields, children, and subtrees directly from stable binary buffers when possible.
4. **Efficient sharing and copying:** allow immutable views and unchanged subtrees to be shared rather than duplicated.
5. **Editor friendliness:** support both text editing and structural editing, with optional lossless source presentation metadata.
6. **Portable persistence:** specify stable, versioned bytes independent of VM pointers, NaN-boxed values, native alignment, operating system, or machine endianness.
7. **Practical implementation:** begin with a straightforward codec and benchmark before committing to sophisticated storage or UI infrastructure.
8. **Convenient development workflow:** generate binary representations from ordinary `.gene` files on demand or automatically with a watch command, without requiring developers to maintain two sources of truth.

### Non-goals for the initial version

- Replacing readable `.gene` source or requiring developers to write binary files.
- Requiring a dedicated editor before Binary Gene is usable; existing editors should be able to work on `.gene` while a watcher maintains the derived representation.
- Making Binary Gene a compiled-bytecode format or skipping macro expansion, name resolution, and compilation.
- Serializing arbitrary live VM objects (closures, tasks, streams, sockets, file handles, native pointers, or mutable runtime graphs).
- Treating memory mapping as permission to trust unchecked file offsets or cast file bytes directly into native objects.
- Designing a whole database engine, content-addressed filesystem, Git replacement, or universal collaborative editor at the outset.
- Changing Gene source syntax to simplify the binary format. Any such proposal is a separate language decision.

## 2. A representation shared by code and data

Example Gene source:

```gene
(Person
  ^name "Alice"
  ^age 30
  (Address ^city "Raleigh" ^state "NC"))
```

A semantic representation is conceptually:

```text
Node
  head       = Symbol("Person")
  properties = [name: "Alice", age: 30]
  children   = [Node(head=Symbol("Address"), ...)]
```

The example illustrates structure rather than prescribing how Gene currently stores nodes internally. In particular, **do not assume every node head is necessarily a symbol**: its stored representation must follow the actual reader/runtime contract.

A binary codec must distinguish at least the supported categories:

| Category | Requirement |
| --- | --- |
| Symbol / identifier | Distinct from a UTF-8 string; preserve identity/qualified spelling as required by Gene semantics. |
| String | Preserve exact Unicode scalar sequence/UTF-8 bytes under the source/value contract; do not silently normalize. |
| Boolean, nil, numeric values | Preserve type, value, and required numeric semantics, including IEEE-754 special values when admitted. |
| Bytes | Opaque length-delimited payload; do not reinterpret as UTF-8. |
| List / vector | Preserve type and child order. |
| Map / property collections | Preserve the semantics of keys, values, order where observable, and duplicate handling required by the Gene reader. |
| Gene node | Preserve head, named properties, ordered children, and semantic metadata/flags where applicable. |
| Source-only constructs | Preserve any reader-visible distinction needed by quote, quasiquote, unquote, interpolation, macros, or other syntax forms. |

The final supported tag inventory must be derived from **the actual Gene reader and value/syntax model**, rather than extrapolated from these examples. Unknown tags are errors until a format version defines their meaning.

### Code versus data is a use-site distinction

The same structural encoding can support both. However, **loading a binary file never executes it implicitly**.

- **Data mode:** return a Gene value or `FrozenGene` view.
- **Source mode:** pass the structure through Gene's ordinary source compilation pipeline, preserving syntax objects and source metadata that the compiler needs.

A header field or explicit loader entry point identifies the intended root profile. Merely opening a file or inspecting it cannot cause code execution.

For example:

```text
Binary source -> syntax structure -> macro expansion -> compiler -> bytecode -> VM
Binary data   -> FrozenGene view or materialized Gene values -> application
```

Binary Gene is **not** a bytecode cache. A separate versioned compilation cache might further improve startup but has distinct dependencies, invalidation, and safety rules.

## 3. Three related layers

Keep three notions separate:

### 3.1 Semantic representation

The canonical underlying Gene data/syntax structure: typed values, heads, properties, children, and all semantically significant syntax metadata. This is the minimum needed for semantic round-trips.

### 3.2 Binary storage representation

A versioned, platform-independent encoding of that structure. Readers may produce ordinary heap-allocated values or expose an immutable byte-backed view. The two access paths must have the same observable semantics for supported operations.

### 3.3 Optional editing/presentation representation

Comments, whitespace, original tokens, literal spellings, optional source spans, syntactic sugar, and formatting preferences. This layer supports lossless or high-fidelity editing without forcing the compiler and data readers to process it.

A semantic round-trip does **not** automatically guarantee a byte-for-byte text round-trip:

```text
Text -> semantic tree -> text
```

may change whitespace, comment placement, and spelling. To support an editor promising faithful source reconstruction, save the necessary **concrete-syntax/trivia information** separately and associate it with stable syntax node identities. Do not claim that an AST alone preserves it.

## 4. Candidate binary architecture

Prefer a **flat, indexed representation with explicit offsets and lengths** as the first serious candidate. Compare it against a simpler tagged-length-value (TLV) codec before freezing the on-disk format.

```text
+----------------------------------------------------------+
| Header                                                   |
|   magic, version, profile, flags, section directory      |
+----------------------------------------------------------+
| Symbol table                                             |
|   identifier spellings / indexes                         |
+----------------------------------------------------------+
| Value table                                              |
|   compact tagged records: scalar or reference            |
+----------------------------------------------------------+
| Node / property / child tables                           |
|   head references; ranges of properties and children     |
+----------------------------------------------------------+
| Payload pool                                             |
|   strings, bytes, extended numerics                       |
+----------------------------------------------------------+
| Optional editing / diagnostics sections                  |
|   source spans, comments, token layout, source map       |
+----------------------------------------------------------+
```

The physical order is an implementation decision. The header should identify the root reference(s), and every section should have explicit byte offset and length. Readers must not depend on file sections appearing in one fixed order unless the format specifies that invariant.

### 4.1 Illustrative value record

For performance experiments, a fixed-size tagged value slot is attractive. One **illustrative 16-byte record** is:

```c
// Illustration only; not a stable wire ABI.
struct ValueEntry {
    uint8_t  tag;
    uint8_t  flags;
    uint16_t aux;
    uint32_t index_or_length;
    uint64_t payload;
};
```

Possible interpretations:

- Nil or boolean: represented inline.
- Small integer: represented inline with an agreed signed-width encoding.
- Floating point: raw IEEE-754 payload bits, when the type is supported.
- Symbol: index into a file-local symbol table.
- String / bytes: length plus byte offset into the payload section.
- List / map / node: index or offset into their respective structural tables.
- Large integer or other extended scalar: reference to a typed payload whose exact encoding is versioned.

This is **not** the VM's NaN-boxed value layout. On-disk slots are validated and decoded through accessors; they are not native pointers.

A fixed record simplifies random access but may make small documents larger than a varint/TLV format. Whether fixed 16-byte entries beat a denser representation is a benchmark question, not a design axiom.

### 4.2 Node and collection records

A conceptual node record contains:

```text
NodeEntry:
    head_value_ref
    properties_start, properties_count
    children_start, children_count
    metadata_ref_or_none
```

A property entry contains a property-name reference and value reference. A child range contains ordered value references. Node metadata and flags must preserve the existing Gene semantics without conflating them with editor-only trivia.

Direct indexing permits constant-time access to the *i*-th child **after** the node record is found. Named-property lookup is not automatically constant-time: a small linear scan may be fastest for small property sets; optional sorted keys, hash indexes, or offset directories can be evaluated for large nodes.

### 4.3 Symbols and sharing

Symbols and repeated identifiers benefit from a file-local symbol table. Interning reduces repeated bytes, but stable global runtime symbol IDs must not leak into the file format. The reader maps file-local entries to appropriate runtime values or lazy symbol views.

Repeated immutable subtrees can potentially share references inside one file. Version 1 should allow a **tree or validated acyclic DAG**, never a cyclic on-disk object graph. Identity and aliasing semantics must be explicitly defined: value-equivalent repeated subtrees may not be merged if the application can observe identity.

### 4.4 Numeric, text, and portability rules

Before implementation, fix these rules in a versioned specification:

- Endianness for all multibyte fields (proposed: little-endian).
- Width and overflow behavior of indices, counts, offsets, and encoded integer types.
- UTF-8 validity and handling of invalid sequences (reject or preserve only in byte values).
- Encoding of signed numbers, larger-than-machine integers, IEEE floating point, NaNs and signed zero when semantically observable.
- Required alignment; alignment padding is never exposed as a pointer guarantee.
- Canonicalization rules, if any; preserve user-visible semantics before optimizing encoded size.
- Root count, file profile, required/optional extensions, checksums if adopted, and schema version compatibility.

For a first prototype, cap file/section sizes and structure depth explicitly; reject unsupported or excessive inputs rather than silently truncating them.

## 5. FrozenGene: a byte-backed immutable view

The main runtime experiment is a **`FrozenGene`** abstraction that retains a validated buffer and a reference to a structural entry within it.

```text
Binary bytes / memory-mapped file
             |
      validated index
             |
      FrozenGene view
       /    |      \
     head  props  children
       \    |      /
   lazy decode / materialize when required
```

Illustrative interface (names subject to design):

```gene
(let root (gene/binary.load "people.gnb" ^mode "view"))
root/head
root/name
root/children

(let owned (gene/binary.materialize root))
```

This code is **proposed API syntax**, not a claim that `gene/binary` exists.

### Guarantees and limits

- **Immutable:** view APIs do not mutate the backing bytes. Other code cannot alter an active mapped buffer through an exposed writable alias.
- **Lifetime-safe:** all child views retain an owner/reference that keeps the backing data alive until they are released.
- **Bounded access:** all offsets, lengths, tags, and references are validated before dereference. A view never casts unchecked bytes into the runtime object graph.
- **Lazy:** loading does not require materializing every string, collection, or node. String decoding and runtime-object wrapping may still allocate when accessed.
- **Semantically consistent:** a materialized value must behave like the equivalent value read from text for the supported value type.

For large files, a memory mapping can avoid an explicit full-file copy and let the operating system page content on demand. For browser clients or platforms without mapping, a read-only buffered representation should offer the same API. Memory mapping does **not** imply zero CPU work or guaranteed speed for every access pattern.

### Zero-copy versus zero-allocation

These are not equivalent:

```text
Copying a view handle:       cheap; retains one buffer reference
Reading a scalar:            bounds check + decode, often no allocation
Reading a string:            may need decode / runtime string allocation
Materializing a subtree:     allocates values for the selected subtree
Exporting a changed file:    may require rewriting or relocating bytes
```

A shared view is analogous to `FrozenGene(buffer, ref)`; copying the handle is not a deep copy of the structure.

## 6. Copying, mutation, and incremental saves

### 6.1 Copy-on-write editing

An edit need not duplicate every unchanged descendant in memory:

```text
            Original immutable tree
              /       |       \
          unchanged  changed  unchanged
                       |
                new edited branch
```

A practical editor can represent edits as a persistent tree or overlay that reuses old immutable parts. Materialize only affected paths and any values that need mutable runtime behavior.

### 6.2 Reusing bytes across binary files is harder

A subtree's bytes may refer to a file-local symbol table, payload pool, and other absolute offsets. Therefore `memcpy(subtree)` into a different `.gnb` file is **not generally valid**.

Candidate future solutions:

- **Relocation:** copy data and rewrite cross-section references.
- **Chunk-local indexes:** make immutable subtrees independently relocatable by constraining references to a self-contained chunk.
- **Shared immutable segments:** retain multiple blocks with an index/manifest, publishing a new root without rewriting old segments.
- **Content-addressed blocks:** optional later deduplication, with explicit identity and retention semantics.

Version 1 should prioritize **cheap in-memory sharing** and correctness. True cross-file byte-copy, chunking, and append-only editing require performance evidence before being built.

### 6.3 Atomic saving

The first writer can serialize a complete new file to a temporary path, flush it as required, and atomically replace the old file using platform-appropriate primitives. A failed save must not leave an apparently valid truncated document. Editing snapshots must pin their backing bytes until readers are finished, including across replacement.

For very large frequently edited files, later designs can switch to immutable segments and a small root manifest. This is distinct from inventing an append-only storage system in the first iteration.

## 7. Editor: textual and structural views

The envisioned editor permits either ordinary code editing or direct structural manipulation. Both operate on the **same document model**, not independently maintained interpretations that can silently drift apart.

```text
Text/code view  <-- synchronized document model --> Structure/tree view
      |                                             |
 token edits                                 node/prop edits
      +-------------------+-------------------------+
                          |
                 Binary Gene writer
```

### Text/code view

- Familiar typing, selections, syntax highlighting, completion, and diagnostics.
- Incremental text parsing in the editor, avoiding full reparse on each keystroke where feasible.
- Optional preservation of exact original spelling, comments, whitespace, and formatting.

### Structure view

- Navigate head, properties, children, and nested values directly.
- Add, delete, reorder, and replace nodes with structure-aware operations.
- Apply syntax/schema-aware validation when available; do not require a global schema for Gene data.

### Lossless editing information

If an editor must reopen a `.gnb` and reconstruct the exact text (or faithfully preserve unchanged regions), save a concrete syntax layer: tokens/trivia, comments, source spans, textual representations of literals, and stable links to semantic nodes. The editor must define how a structural change affects nearby trivia. **Lossless round-trip requires tests; AST pretty-printing is not lossless.**

A simpler first editor can intentionally pretty-print canonical Gene source and preserve only semantic structure. The UI must label that as a formatting-normalizing path, not promise exact reproduction.

### Incremental work

An eventual editor can parse only modified text ranges, reuse unchanged syntax/semantic nodes, and serialize only affected segments if the storage format supports it. The **initial codec and view experiments do not require an editor**; editor architecture should follow what the benchmarks and source-fidelity tests establish.

## 8. Keeping `.gene` and binary in sync: build and watch

**For normal development, `.gene` is the authoritative source and `.gnb` is a disposable, derived artifact.** A separate binary-primary data/editor workflow may be supported later; do not try to synchronize edits in both directions in the first version. This avoids two competing sources of truth and lets existing text editors, version control, and code review continue to work unchanged.

```text
Developer edits .gene in any editor
              |
              v
       File change detection
              |
              v
      Gene text reader/parser
              |
              v
      Binary Gene serializer
              |
              v
  Atomic publish of derived .gnb
              |
              v
   Loader validates freshness
              |
       +------+------+
       |             |
     fresh         stale/missing/invalid
       |             |
  load binary       read .gene normally
```

### 8.1 Proposed commands

The command spelling is illustrative and should follow Gene's existing CLI conventions when implemented:

```text
# One file, one-time conversion:
gene repr build src/example.gene --output build/repr/example.gnb

# Build all matching source files, then watch for changes:
gene repr watch src/ --out-dir build/repr/

# Inspect whether a generated representation matches its source:
gene repr verify src/example.gene --binary build/repr/example.gnb
```

- `build` parses using **Gene's real source reader**, not a simplified reimplementation, and encodes the resulting source structure. It reports source parse errors with normal diagnostics and a nonzero exit status.
- `watch` first scans/builds missing or stale outputs, then responds to create, modify, rename, and delete events. It coalesces rapid saves and rebuilds only affected files; it uses a periodic rescan or polling fallback if native notifications are unavailable or lost.
- `verify` checks provenance and source freshness, as well as binary structural validity where requested; it never executes the stored Gene code.
- Multiple source paths must map deterministically to distinct output paths. A dedicated ignored cache directory is preferable by default, with side-by-side `.gnb` output as an explicit option for distribution or inspection. Generated caches should normally not be committed to source control.
- Prefer implementing the orchestration itself in **Gene**. If filesystem watching, hashing, or atomic file replacement is missing, add a reusable primitive to `gene/` or `genex/` rather than requiring Python or shell scripts for routine builds. Portable polling is an acceptable initial implementation.

### 8.2 Freshness and reproducibility contract

**A file existing at the expected path does not prove it matches the text source.** A generated `.gnb` carries provenance in its header or a linked, atomically published manifest:

```text
source_identity       normalized source path/relative key, for diagnostics
source_digest         cryptographic hash of exact source bytes
representation_abi    binary format version and required feature bits
encoder_version       writer/reader semantic encoding version
root_profile          source or data
optional_build_flags  only flags that change encoded semantics
```

At load time, compare the recorded digest with the current `.gene` bytes and check the supported representation/encoder contracts before trusting the cache. A timestamp and file size are useful **change-detection hints**, not sufficient correctness proofs. The consumer may compute a digest (linear in the source size) but still avoid lexing, parsing, and extensive allocations; measure the digest overhead when evaluating speedups. For a source-free binary distribution, explicitly opt into a *binary-primary* loader profile instead of pretending it has a checked `.gene` counterpart.

Do not put unrelated compiler configuration or transitive import contents into the representation digest unless they actually change the serialized source structure. Macro expansion, dependent-module invalidation, compiler optimizations, and bytecode caching have their **own** separate dependency and cache contracts.

The serializer should produce deterministic bytes for the same source, source-reader contract, and build options (or document unavoidable nondeterministic fields separately from the semantic payload). Repeat builds should not rewrite an identical binary unnecessarily, to avoid generating file-event loops and excessive filesystem I/O.

### 8.3 Publication and watch races

A successful rebuild must be atomic and correspond to a coherent source snapshot:

1. Read a stable source snapshot and compute its digest; parse exactly those bytes. If the file changes during that operation, retry rather than publishing output for an intermediate state.
2. Serialize and validate the candidate into a temporary file in the output directory; flush appropriately before atomic replacement.
3. Before publishing, recheck source freshness (and any newer queued generation). Discard obsolete candidates; only the latest confirmed source generation may become current.
4. Atomically replace the published cache. Readers hold their previous immutable buffer safely until they finish; no partially written `.gnb` becomes visible.
5. If parsing or writing fails, show diagnostics, retain the last known good binary as an historical artifact if useful, but mark it **stale**. A normal source loader must not silently execute that outdated binary as if it represented the current source.

After source deletion or rename, invalidate or remove the corresponding generated cache according to an explicit policy. On watcher restart, rescan from source rather than trusting prior notifications. Avoid watching the output directory as another input. If multiple watcher instances target the same cache, coordinate their ownership or rely on deterministic generation, freshness validation, and atomic replacement; do not allow an older writer to republish a stale result.

### 8.4 Loader behavior and editor separation

A development loader can use the following simple policy:

```text
if a source-backed .gnb exists and verifies as fresh and supported:
    load the binary representation
else:
    parse the .gene source
    optionally request/rebuild the cache
```

Fallback should be explicit in logs or diagnostics when debugging performance. A corrupt cache may be discarded and rebuilt, but must never bypass Gene syntax checks or execute an older version. The watcher is an optimization, **not a requirement for correctness**: stopping it or opening a repository on a fresh machine still leaves valid `.gene` source usable.

An editor may later modify a `.gnb` as its primary document. That is a distinct mode with its own save/export semantics. In **source-backed watch mode**, generated `.gnb` files are read-only from the developer's perspective. Do not silently merge binary-side edits into source or permit the watcher to overwrite edits presented as authoritative.

### 8.5 Initial workflow acceptance tests

- Starting a watcher builds previously missing outputs, detects a change after a rapid sequence of saves, and leaves an output matching the final source bytes.
- An intentionally malformed edit reports the normal parser error; neither the loader nor watcher runs a stale successful version without an explicit request.
- A deleted, moved, or renamed source cannot leave a usable *fresh* cache under the old source identity.
- Killing the writer before atomic replacement leaves either a valid previous artifact (now possibly stale) or a fully valid new artifact, never a truncated accepted file.
- Rebuilding identical content yields semantically identical and, under the deterministic encoding contract, byte-identical output without triggering endless watch events.
- Freshness verification catches changed source content even when its timestamp or byte count is unchanged.
- Running without `watch` still parses and executes `.gene` correctly, and a binary-only distribution uses an explicit source-free profile.
- Concurrent changes during parsing/serialization never produce an artifact advertised as fresh for a different source digest.

## 9. Integration with the compiler, VM, and libraries

A binary-source loader should expose the same compiler-facing syntax semantics as the text reader. It must not bypass macro expansion, name resolution, checking, or existing compilation and evaluation semantics. All supported source constructs need an explicit binary encoding or a faithful reader-level representation.

Two possible implementations:

1. **Binary-to-AST materialization:** deserialize semantic syntax into the existing compiler's structures. Easiest integration, with savings mostly in lexing/parsing.
2. **Compiler over a syntax-view interface:** let compiler passes traverse `FrozenGene` directly and materialize selectively. More promising for memory and allocation, but may require meaningful compiler changes and compatibility tests.

Implement option 1 first for validation and measurements. Attempt option 2 only after profiling shows tree materialization remains a significant cost.

For large ordinary data files, the view interface can be exposed independently of compiler integration. An API can return a view, a materialized value, or a stream of selected items, while making costs explicit.

Do not equate source persistence with VM continuation state. A binary document contains source/data structures, not runnable stacks, captured native resources, or arbitrary live closures.

## 10. Safety and format evolution

Binary files may be malformed, corrupt, or adversarial. Fast loading must not trade away sound validation.

Minimum checks:

- Verify magic, format version, header lengths, section boundaries, feature bits, and root references.
- Validate offset-plus-length arithmetic without overflow; reject overlapping regions where the format forbids them.
- Validate every tag, collection count, reference index, symbol/string length, and encoded scalar shape.
- Bound nesting depth, graph traversal work, expansion costs, decoded object count, and total allocation.
- Detect forbidden cycles, dangling references, invalid symbols, and malformed UTF-8.
- Reject unknown *required* extensions; skip only extensions explicitly marked optional and safely length-delimited.
- Ensure a view cannot retain references into an unmapped or prematurely closed buffer.
- Keep source evaluation a separate, explicit operation, never a side effect of opening data.

A reader may validate the file eagerly or lazily, but public accessors must never expose unchecked offsets or undefined behavior. A recommended approach is bounded structural validation at open, with guarded lazy payload decoding where safe.

The format needs a versioning policy. Prefer explicit major-version rejection on incompatible semantics rather than guessing how old or future files should be read. Golden byte fixtures, cross-platform tests, and a corpus of malformed files are part of the format contract.

## 11. Alternatives and trade-offs to benchmark

| Approach | Advantage | Limitation |
| --- | --- | --- |
| Plain text `.gene` | Readable, diffable, universally editable | Lexing/parsing and tree construction cost. |
| Compact TLV/varint binary | Simple streaming encoder, potentially small | Random access may scan preceding elements; more decoding. |
| Flat indexed binary | Predictable traversal, strong fit for immutable views | Index/offset bookkeeping, some storage overhead. |
| Fully materialized binary AST | Easy compiler integration | Still allocates whole tree and duplicates runtime objects. |
| Frozen binary view | Low allocation and partial access | View-aware APIs, lifetime management, validation. |
| Binary bytecode cache | Fast execution startup after compilation | Separate artifact tied to compiler/VM version; not a source/data format. |

Useful related work to study, **not dependencies or automatic design choices**:

- **FlexBuffers:** schema-less indexed binary data and read-only direct access.
- **Amazon Ion:** text/binary representations and symbol tables.
- **Tree-sitter:** incremental parsing and reuse of unchanged syntax structure in editors.

The Gene-specific requirement is fidelity to Gene nodes, syntax, and value distinctions, rather than adopting any external format unchanged.

## 12. Prototype plan

### Phase A — semantic codec

- Inventory serializable Gene value types and reader-visible source structures.
- Define a minimal versioned file header, typed value encoding, and basic node/list/map structures.
- Implement **text -> semantic representation -> binary -> semantic representation** round-trips.
- Implement a deterministic test corpus, nested structure tests, unsupported-type errors, and malformed-input tests.
- Keep the writer simple even if it initially rebuilds the complete file.

**Gate:** supported code/data survives semantic round-trips; malformed data fails safely. No execution semantics change.

### Phase A2 — build/watch pipeline (after the codec works)

- Expose one-shot `build`, source-backed `verify`, and development `watch` commands using the same codec/reader as Phase A.
- Store source digest and representation version provenance, and teach the loader to reject stale caches and fall back to text.
- Add debounce/coalescing, initial scan, missed-notification recovery, stable-snapshot reading, atomic output replacement, and parser-error diagnostics.
- Test rebuilds, deletes, concurrent saves, watcher crashes, identical content, and disabled-watcher operation.

**Gate:** text remains authoritative; source-backed binary cannot be mistaken for fresh when it is stale. The watcher is optional for correctness and does not need a dedicated editor.

### Phase B — load/parse benchmarks

- Establish and publish the **500-line startup benchmark in §13.1**, including fresh-process text/binary paths, source-backed digest verification, correctness markers, and p50/p95 results. Re-run it after compiler-view integration in Phase D.
- Compare text reader, binary full materialization, and raw binary validation on realistic Gene files.
- Record wall time, CPU, allocations, peak resident memory, file size, and startup overhead.
- Include small scripts, large nested source, repeated symbols/properties, and large data payloads.

**Gate:** measured advantage and a documented cost trade-off, not just a smaller or visually complex format.

### Phase C — FrozenGene reader

- Implement immutable buffer ownership and typed view accessors.
- Read scalar/head/properties/child ranges without constructing the full tree.
- Add optional memory-mapped loading with a buffered fallback.
- Prove materialization equivalence with the Phase A decoder.
- Benchmark random lookup, subtree iteration, selective reading, and handle copies.

**Gate:** selective reads allocate and touch materially less data than full materialization for representative workloads.

### Phase D — compiler integration

- Start by feeding materialized binary source into the existing compiler.
- Test semantic equivalence for macros, quote/unquote-related forms, source metadata, diagnostics, and module imports as supported.
- Profile end-to-end startup. Consider a shared syntax-view interface if materialization is still a substantial bottleneck.

**Gate:** binary source executes the same as equivalent text source, and load improvements survive compiler costs.

### Phase E — editing support

- Implement a minimal structural browser/editor over the shared document model.
- Add text view and explicit semantic-printing versus lossless editing modes.
- Optionally add trivia/token preservation, stable node IDs, and incremental edits.
- Add undo/redo and atomic file-save/reopen tests.

**Gate:** edits produce valid, re-openable files; source-preservation guarantees are stated and tested.

## 13. Benchmarks and acceptance criteria

### 13.1 Startup benchmark: one 500-line Gene script

**Question:** For an ordinary 500-line Gene program, how much end-to-end startup time does a prebuilt Binary Gene representation actually save compared with reading `.gene` text? Measure the answer, rather than assuming that faster parsing makes the entire process proportionally faster.

**Fixture.** Check in one deterministic `bench/startup-500.gene` fixture with **500 nonblank executable/source lines** (not 500 lines dominated by comments, empty lines, or repeated no-op expressions). Use normal Gene constructs: bindings, functions, calls, nested nodes, lists/maps, loops/branches, and a representative number of repeated symbols and properties. Keep it self-contained at first, without network access, disk reads during execution, random values, sleeps, or a model call. Its final computation should yield a deterministic checksum or marker that the harness verifies on every run, so neither path can silently skip execution or return a stale result. Record the exact fixture revision, line-count method, UTF-8 byte count, and structural counts (nodes, strings, symbols); use the **same source semantics** for every mode.

Generate the `.gnb` **ahead of the timed runs** with the proposed `gene repr build` command. A watcher may maintain the artifact in ordinary development, but watcher startup, conversion, and rebuild time do **not** belong inside the binary **runtime-startup** number. Measure conversion time separately as a build cost. Disable unrelated compiler/bytecode caches in the primary comparison unless they are identically enabled for both paths.

| Mode | What the timed invocation must do | Purpose |
| --- | --- | --- |
| **T — text** | Launch a fresh Gene process; read the `.gene` source, lex/parse, compile, execute, and produce the verified marker. Force the text path even if a `.gnb` exists. | Baseline end-to-end startup. |
| **B — binary, materialized** | Launch the same Gene runtime; read/validate the prebuilt `.gnb`, materialize compiler-facing syntax, then run the **same** compilation and execution path. | Isolate the benefit of avoiding the text reader without assuming a new compiler. |
| **V — binary syntax view** *(when implemented)* | Read/validate `.gnb` and compile through a `FrozenGene`/syntax-view adapter without full tree materialization; execute the same program. | Measure incremental benefit from a view-aware compiler. |
| **S — source-backed binary** | Request `.gene` as usual; validate freshness using the current source digest and format metadata, consume the matching `.gnb`, compile, and execute. | Measure **real developer-workflow startup**, including freshness verification. |
| **F — stale/missing binary fallback** | Make the cache absent or deliberately stale, invoke the ordinary source-backed loader, and confirm it parses current `.gene` with the same marker. | Check correctness and fallback overhead; **never** count this as a successful binary-cache hit. |

The invocation spelling for forcing a representation is **to be defined**; do not assume the CLI already implements a `--repr` flag. The benchmark harness must select and log the actual path and reject an unexpected fallback in modes B/V/S. A `.gnb` from a source-free distribution may be used for mode B or V, but **not** in place of mode S's required source-digest check.

**Primary metric:** elapsed monotonic wall-clock time from launching a new `gene` process to observing the validated end-of-program marker (and, separately, full process exit). This includes process initialization, file access, validation or parsing, compilation, and the script's work; exclude creation of the `.gnb` file. Where instrumentation permits, also report `process initialization`, `source read/hash or binary validation`, `parse/decode/materialization`, `macro/compile`, and `execution` as **nonoverlapping** phases. Avoid double-counting nested timings. Record CPU time, peak RSS, allocation counts/bytes when available, and `.gene`/`.gnb` sizes.

**Procedure and controls:**

1. Use the same Gene executable, build mode (prefer an optimized release build), compiler settings, machine, CPU/power policy, and script inputs throughout. Confirm that the resulting observable output/checksum is identical.
2. Warm up the benchmark driver and runtime, then run **at least 50 independent process launches per mode**. Randomize or interleave mode order to reduce drift; report **median (p50), p95, minimum, and spread**, not just a single best result. Include harness overhead measurement or explain how launch timing excludes unrelated driver work.
3. Treat **fresh process with warmed filesystem cache** as the primary reproducible case. If separately testing a genuinely cold filesystem cache, document how caches were cleared and the storage medium; simply starting a new process does not make the OS page cache cold. Label these conditions separately.
4. Repeat the 500-line fixture in two profiles if practical: (a) **parse-sensitive**, with many short forms, identifiers, and literals; (b) **execution-sensitive**, with more deterministic computation. Keep each fixture exactly 500 qualifying lines and publish their content/structural counts. This shows whether source parsing matters when useful work dominates.
5. Run a **parse/compile-only diagnostic** within the existing runtime (no separate process launch) to expose time spent in the source reader versus binary validation/materialization. Treat this as supporting evidence, **not** the end-to-end startup result.
6. Measure `.gnb` build cost and output size independently; if it takes much longer to create than startup saves, estimate the **break-even number of launches** for a prebuilt artifact. Source-backed mode S must include the source hash cost every time the specified loader contract requires it.

Report results using this template; **all cells remain TBD until the implementation is benchmarked**:

| Metric | T: text | B: binary materialized | V: view | S: source-backed binary |
| --- | ---: | ---: | ---: | ---: |
| End-to-end startup p50 (ms) | TBD | TBD | TBD | TBD |
| End-to-end startup p95 (ms) | TBD | TBD | TBD | TBD |
| Parse/decode + validation p50 (ms) | TBD | TBD | TBD | TBD |
| Macro/compile p50 (ms) | TBD | TBD | TBD | TBD |
| Peak RSS (MiB) | TBD | TBD | TBD | TBD |
| Representation size (bytes) | TBD | TBD | TBD | TBD |

Calculate **speedup** as `T_p50 / mode_p50`, and **time saved** as `T_p50 - mode_p50` (also compare p95). If binary build costs `C_build` milliseconds and saves `S` milliseconds per run under the applicable workflow, the simple amortized break-even is `ceil(C_build / S)` runs **when S > 0**; account separately for watch rebuilds after edits. Do not advertise a speedup when differences are within measurement noise or the workload is dominated by VM startup/compiler/execution.

**Benchmark acceptance gate:** the paths are semantically equivalent, 500-line fixtures and environment are reproducible, every run verifies the marker and representation used, and the table reports measured p50/p95. Binary Gene need not win every scenario: a neutral or slower result is evidence for simplifying the format or prioritizing data access over code startup.

### 13.2 Other benchmark workloads

Benchmark at least these dimensions **before** choosing a final layout:

| Workload | Compare / measure |
| --- | --- |
| Load a small code module | Text parse versus binary decode, including startup and validation; for source-backed cache, include source digest verification cost. |
| Load a large code module | Same, plus time to compile and execute. |
| Read one field from a 100 MB data file | Full text parse, full binary decode, `FrozenGene` selective access. |
| Traverse many nested children | Cache locality, bounds-check cost, allocation, page faults. |
| Copy an immutable subtree handle | Handle copy versus deep materialization / deep copy. |
| Export an edited subtree into a new file | Serialization, relocation, rewritten bytes, file size. |
| Save repeated small edits | Whole-file replacement versus any later segmented approach; track watcher CPU, debounce latency, and unnecessary rebuilds. |
| Open file after crash/partial write | Previous valid version remains usable; incomplete publication is rejected. |
| Fuzz malformed files | No crashes, memory corruption, unchecked accesses, or unbounded resource use. |

Use the same test data and report cold/warm cache conditions, platform, compiler/runtime version, storage medium, and memory usage. Do not promise a specific speedup until results exist.

### 13.3 Functional acceptance cases

1. Symbol and string with identical text remain distinct.
2. Node head, properties, children, and semantic metadata round-trip faithfully.
3. Lists, maps, numbers, bytes, and supported source forms round-trip without unintended coercions.
4. Binary code and equivalent text code produce the same compiler-visible structure and observable execution for the supported language subset.
5. File-local symbol indices do not escape as stable runtime identities.
6. Unchanged immutable views may be shared without duplicating payload bytes.
7. Materialized values are not silently aliases of writable mapped memory.
8. Invalid offsets, sizes, references, cycles, and tags fail safely.
9. Unsupported VM/runtime values are rejected explicitly, not serialized as meaningless pointers.
10. Lossless text reconstruction is guaranteed **only** when editing metadata sufficient for that guarantee was saved.
11. Unknown required format features fail explicitly; compatible optional sections can be skipped.
12. Full-file replacement and later segmented persistence preserve a coherent committed document after interrupted saves.
13. In source-backed mode, only matching, verified `.gnb` artifacts are used; changed, invalid, missing, or corrupt binary caches fall back to current `.gene` source.
14. Watch mode handles rapid edits, parse errors, deletes/renames, restart/rescan, and writer crashes without accepting stale or partial output.
15. Direct binary editing and source-backed generated caches are separate, explicitly selected workflows.

## 14. Decisions to resolve through experiments

| Question | Initial leaning |
| --- | --- |
| Flat indexed slots or streaming TLV? | Prototype both minimally; prioritize fast random access if measurements support it. |
| Fixed or variable-width references? | Start with a simple, portable fixed-width format and explicit size limits. |
| Eager or lazy validation? | Eager bounded structural validation; guarded lazy decoding of larger payloads. |
| Shared subtree references? | Support validated acyclic references only if identity semantics permit them. |
| Preserve comments and exact text in every file? | No; optional editor section and clear source-fidelity modes. |
| Is the first consumer the compiler or data access? | Test data-view access first; compiler integration initially via full materialization. |
| True in-place binary mutations? | No in v1; immutable views and atomic rewritten files first. |
| Schema-specific property indexes? | Add only if named lookup profiles justify them. |
| Binary Gene as the only project representation? | No; retain text as a first-class source format. |
| Development synchronization model? | `.gene` authoritative, `.gnb` generated and disposable; one-shot build and watch. No automatic two-way sync in v1. |
| How to decide whether a generated binary is fresh? | Source-content digest plus relevant representation/encoder version and options; timestamps only as hints. |

## 15. Core statement

> **Gene code and data share one structural model.** Binary Gene extends that model into a portable serialized representation. A simple codec can reduce text parsing overhead; a validated immutable `FrozenGene` view can enable selective reads and cheap structural sharing without materializing the whole tree. Text and structural editors can operate over one document model, with optional presentation metadata for lossless source editing. In ordinary development, `.gene` remains the source of truth while an optional Gene-native build/watch workflow publishes and verifies derived `.gnb` files. Compilation remains Gene compilation, and versioned binary persistence remains distinct from live VM state or bytecode caches.

**One structure; textual or binary representation; lazy views where useful; source semantics preserved.**

---

## Review comments (2026-10-12)

Reviewed against the tree at `bb22e64b`. These comments are about scope and premises; wording and layout details are left alone.

**Summary.** The proposal bundles three projects that have different answers: faster code startup, a structural editor, and selective access to large data. Measured here, the first is not worth building. The second is better served by text plus the source index that already exists. Only the third needs binary bytes, and it has no named consumer yet. I would narrow the proposal to the third and gate it on a consumer.

### R1. The startup question in §13.1 can be answered today, and the answer is small

The text reader is about 4% of fresh-process startup for a mid-size script, so that is the ceiling on what a binary source format can save.

Reader and digest cost, in-process (release build, macOS arm64; p50 of 50 rounds after 10 warm-up rounds, timing `readAllWithLocs` and `sha256Hex` on the same bytes):

| File | Lines | Bytes | Read p50 | SHA-256 p50 |
| --- | ---: | ---: | ---: | ---: |
| `examples/events.gene` | 328 | 13,310 | 0.30 ms | 0.07 ms |
| `examples/life/src/body/world_network.gene` | 900 | 46,394 | 1.30 ms | 0.22 ms |
| `examples/gene-harness/src/kernel.gene` | 1,545 | 64,216 | 1.72 ms | 0.28 ms |
| `examples/gene-harness/client/main.gene` | 1,909 | 77,212 | 2.24 ms | 0.34 ms |
| `examples/cordis/src/runtime.gene` | 3,563 | 145,948 | 4.16 ms | 0.66 ms |

Fresh-process launches of the release `bin/gene` (p50 of 40 launches after 5 warm-up; `/usr/bin/true` costs 1.7 ms through the same driver):

| Command | p50 | p95 |
| --- | ---: | ---: |
| `gene run` of a one-line file | 6.4 ms | 7.4 ms |
| `gene run examples/events.gene` (328 lines) | 7.3 ms | 9.4 ms |

What this says:

- The reader is 0.30 ms of the 7.3 ms. The whole cost of 328 lines over one line is 0.9 ms.
- With a decoder 3.76x faster than the reader (the figure the retired packed format measured, see R2), binary saves 0.22 ms, which is 3% of startup.
- Source-backed mode S pays 0.07 ms of that back for the digest, leaving 0.15 ms, or 2%.
- The p50-to-p95 spread of the same command is 2.1 ms, so §13.1's own rule against advertising differences inside measurement noise would apply.
- A 500-line file scales to roughly 0.5–0.7 ms of reading.

This is one machine, one script run end to end, and a scratch probe that is not checked in. It sets the order of magnitude; it does not replace a benchmark.

I would drop code startup as a goal: Goal 2 as it applies to source files, mode S, §8, Phase A2, and most of §13.1. The build, watch, and freshness machinery in §8 exists only for this case. If code startup becomes a concern, the larger terms are runtime initialization (6.4 ms before any user code) and compilation. The artifact that skips compilation already exists: `gene build` reuses executable GIR by derivation identity (`src/gene/gir_codec.nim`, `src/gene/build.nim`), with source snapshots and digest verification already in place. §8 would duplicate that pipeline for a smaller saving.

### R2. A packed format was already built, measured, and retired

`2ca4eb43` implemented a versioned, comment-preserving packed encoding of Gene programs (`program_document.nim`, `packed_format.nim`), with round-trip tests over the repository's `.gene` corpus and a benchmark that measured loading at 3.76x faster than `readAll`. `0b44059b` (2026-08-13) removed it because nothing consumed it.

The Status line is accurate about the tree, but the proposal should cite that work and say what has changed since August. Two things carry over:

- Phase A and most of Phase B are recoverable from git, including the value inventory §2 leaves open. That encoder covered nil, void, bool, int64, float, string, bytes, char, symbol, node, list, map, and hash map, and rejected regex, range, date, time, datetime, timezone, duration, and big integers at encode time. The §2 table lists none of the rejected kinds.
- It was retired for lack of a consumer. That is the question this proposal has to answer first.

### R3. Source mode has to reproduce `SourceUnit`, not a value tree

The compiler does not take forms. It takes a `SourceUnit` (`src/gene/reader.nim:92`): the forms, per-form locations, a `locs` table and a `wraps` table keyed by each value's bits (its identity), and the full source text, which is kept so an embedded block can slice the author's exact characters.

- Locations are required in the source profile. §4 puts spans in an optional editing/diagnostics section; without them every compile error loses its line.
- Phase D option 1 has to allocate the whole tree and rebuild both identity-keyed tables. That is the reader's allocation work minus lexing, which fits a 3.76x ceiling rather than an order of magnitude.
- Phase D option 2 has no value identity to key on, so the compiler's location lookup has to change along with its traversal.
- The `.gnb` has to embed the source text or re-read the `.gene`.

### R4. The cost of FrozenGene is in the VM, and the proposal does not size it

§5 shows `root/name` and `root/children` working on a view. For that to hold, every operation that accepts a node, list, or map needs either a second implementation for a byte-backed kind or a materialization on access: path access, iteration, equality, hashing, printing, matching, serde, freezing, and publication to workers. Phase C lists buffer ownership and accessors, which is the small part of that work.

I would make the v1 view an explicit handle with its own accessors (`get`, `children`, `materialize`) that return ordinary values, and state that it is not substitutable for a node. That leaves the VM untouched and still covers the 100 MB selective-read case.

"Frozen" already names deeply immutable values in Gene (`docs/spec/frozen-graph-proofs.md`). A byte-backed view is a different thing, and a different name avoids the question of whether a `FrozenGene` is frozen.

### R5. Data mode should be defined against serde

Gene's durable data path today is `$serde` (`write_data` / `read_data`) for values and `$store` for named records, both described in `docs/stdlib.md` under "Serialization and persistence". The Harness reads its config and web session state through `$serde/read_data`. The proposal does not mention either.

If Binary Gene data encodes raw reader output, it sits beside serde as a second data format with a different value model, and R2's inventory shows the gaps. If it encodes serde's model, the tag inventory comes from serde rather than from the reader, and "data mode" becomes "a binary encoding for `$serde`". That is smaller, clearer, and comes with callers already attached. I did not check how `$store` encodes its records, so whether it is a second caller is open.

### R6. The editor goal is better served by text and the existing source index

`src/tools/source_index.nim`, behind `gene view`, is already a lazy structural view. It stores token ranges over the text, derives children on demand, and keeps comments, duplicate properties, and exact byte spans. That is the concrete-syntax layer §3.3 and §7 say must be added to `.gnb` before editing can be lossless. Text has it for free.

A `.gnb`-primary editor also gives up diff, review, and merge. I would move §7 and Phase E to a separate proposal that builds structural editing as span edits over text, and remove the editing sections from the format.

### R7. What I would keep

Selective access to large data (§5, and the 100 MB row in §13.2) is the one case that needs binary bytes. The design for it is sound: flat indexed layout, eager bounded validation, no cycles, atomic whole-file writes.

Before building it, name the consumer and measure its real file: the cost of the text read against what the consumer actually needs from it. Without a consumer, this ends where the August format did.

### R8. Potential direction: a slot-based layout for random access

This is a candidate replacement for the table layout in §4, worked out in discussion after the review. It is a direction to evaluate, not a decision. It targets the large-data case in R7 and does not change the startup numbers in R1.

The record header and the keys-then-values ordering are the owner's design. Items marked *(review)* are the review's additions to it.

#### Slots

Everything after a record header is an 8-byte little-endian slot. A slot holds either a direct value or the address of a record. The encoding follows the VM's NaN-box in `src/gene/types.nim`, with the pointer range given a new meaning: the VM uses it for heap pointers, a file never stores one, so in a file that range means "file offset".

| Slot bits | Meaning |
| --- | --- |
| All 64 bits zero | nil |
| Top 16 bits below `0xFFF1` | An IEEE float64, stored directly |
| Top 16 bits `0xFFF1`–`0xFFF6` | An immediate: void, bool, small integer, char, `+0.0`, symbol |
| Top 16 bits equal to the address tag | An address: the low 48 bits are the file offset of a record |
| Other values from `0xFFF7` up | Reserved |

Telling a direct value from an address is one comparison. Four rules make that sound:

- *(review)* **Tag values belong to the format, not the VM.** They start equal to today's VM values, so nil, bool, integer, char, and float decode by copy. The numbers are written into the format spec, so the VM can repack its tags without breaking files.
- *(review)* **One address tag.** The record header already says what a record is, so a slot only has to say "address". The header is the single authority on type. The rest of the pointer range stays reserved; short inline strings are the obvious later use.
- *(review)* **Symbols are remapped.** In the VM a symbol's payload is a runtime intern id. In a file it is an index into the file's symbol table, and the reader maps it to a runtime symbol.
- *(review)* **Floats have two special cases.** The writer emits one canonical positive NaN, because a negative NaN falls in the tag range and would read as an address. `+0.0` has its own tag, as in the VM, because all-zero bits mean nil.

Integers that fit the 48-bit payload are inline. Larger ones are records.

#### Records

Every record starts with one 8-byte header, so records stay 8-byte aligned:

```text
header: [type:2 | nprops:3 | nchildren:3]

node:   header  head  key1..keyK  value1..valueK  child1..childN
map:    header        key1..keyK  value1..valueK                  (nchildren unused)
array:  header                                    child1..childN  (nprops unused)
string: [type:2 | byte length:6]  bytes, padded to 8
```

Node, map, and array are the same record with different regions in use, so one reader routine covers all three. Every position is computed from the header with no hop: child *i* of a node is at slot `2 + 2K + i`, value *j* of a map is at slot `1 + K + j`, and item *i* of an array is at slot `1 + i`. Other built-in types follow the same pattern, a header and then slots or a padded payload.

- *(review)* **The node's head is the first slot after the header.** The original sketch had no place for it.
- *(review)* **A count of `0xFFFFFF` means the real count is in an extra slot after the header**, property count first if both overflow. Three bytes cap a count at 16,777,215. An array that long is about 128 MB of slots, which is within reach of the large-data case, and adding the escape later would be a format break.
- *(review)* **Strings and bytes fuse the two 3-byte fields into one 48-bit byte length.** A 3-byte length would cap a payload at 16 MB.
- Node and property-map keys are symbol slots. General-map (`{{...}}`) keys can be any slot. Both keep insertion order and are scanned linearly, as the runtime's `PropTable` is.

#### Addresses only point backward

*(review)* The writer emits children before parents and the root last, and puts the root's address in a trailer.

- Cycles are impossible by construction, because every hop strictly decreases the offset. §10's cycle detection becomes one comparison per slot.
- Lazy validation is safe and bounded, so opening a 100 MB file costs constant time instead of a full validation pass.
- Shared subtrees need no extra machinery (§4.3).
- An edit can append a new root that reuses old subtrees, which covers most of what §6.2 defers.

Symbol slots hold indexes, not addresses, so the symbol table can be written last and found through the trailer.

#### Deferred to later type codes

The 2-byte type leaves room to add these without a format break, so neither needs deciding now:

- **An indexed map.** A linear key scan is fine for small maps and slow for very large ones.
- **A node with a shared key vector.** Keys are repeated in every node. A million rows with the same five properties carry 40 MB of duplicated keys. A node type that points to one shared key record would remove that.

#### Costs to accept

- At 8 bytes per atom, a source file is larger as `.gnb` than as text. That is acceptable for data, which is the case this layout serves.
- The writer works bottom-up. That is natural when serializing an in-memory tree, and it rules out streaming a document whose children are not known yet.

#### Still open

- The concrete tag and type code assignments.
- Absolute backward offsets or relative ones. Relative offsets make a subtree relocatable, apart from its symbol references.
- Record layouts for the remaining built-in types. R2 lists the ones the August encoder rejected: regex, range, the temporal types, and big integers.
- The trailer's contents (root address, symbol table, format version) and how it relates to the header in §4.

This layout would settle four rows of §14: indexed slots over streaming TLV, fixed-width references, lazy validation over eager, and shared acyclic references allowed.
