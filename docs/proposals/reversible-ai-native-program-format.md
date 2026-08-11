# Reversible AI-Native Gene Program Format

Status: durable format v0 implemented and passing its provisional gates
(2026-08-10); model-training track (Steps 6-7) has its pipeline and scoring
harness built and a first matched from-scratch pilot run, closing three
pre-registered gates and firing one routing rule (see "Model-training track
status" below); Steps 8-9 and the appendix not started. Non-textual program modality for training models, with
a durable encoding that loads faster than `.gene` and translates back to
canonical `.gene`.

**Durable format v0** (`src/gene/program_document.nim`,
`src/gene/packed_format.nim`, `tests/test_program_document.nim`,
`tests/test_packed_format.nim`, `benchmarks/bench_native_format.nim`, run via
`nimble native_format_perf`) covers Steps 1-4 of the sequence below: a
logical document (form tree plus a boundary-keyed positional comment
overlay), a canonical `.gene` writer, and a framed/limited/fail-closed packed
codec. Value coverage is nil, void, bool, int (int64 range), float, string,
bytes, char, symbol, node, list, map, and hash-map; regex, range,
date/time/datetime/timezone/duration, and bigint-overflow ints are cleanly
rejected at encode time (`PackedUnsupportedError`), not silently mishandled,
pending a v1 decision on their wire shape. Comment placement is fully
structural for node/list/map/hash-map and falls back to a coarser
whole-form anchor (never a silent drop) for quasiquote/unquote/interpolation
sugar and any other shape this module doesn't finely resolve.

Verified over every `.gene` file in `examples/` and `tests/`: zero crashes,
zero dropped comment bytes, and full round-trip/idempotence/semantic
equivalence on every file, with no exclusions.

Reaching "every file" required fixing two pre-existing reader/printer bugs
that this verification surfaced. Both reproduce with plain
`reader.nim`/`printer.nim` -- nothing routed through this format -- and both
affected `gene parse`'s existing canonical printer, so neither was
introduced here:

- A glued `~word` path segment (e.g. `obj/~method`) was glued into one
  symbol only during slash-path lexing, and split into two tokens when the
  same spelling was reread as an ordinary node body element. The reader now
  lexes `~` glued to a symbol character as one symbol everywhere; a spaced
  `~` is still the send operator (design §2.1).
- A bare `%` path segment produced an unquoted *empty* symbol, which the
  printer could not write back out, and silently swallowed the following
  form: `(!= xs/%(- i 1) "\n")` read as a three-argument `!=` whose second
  argument was the index expression. Design §2.1 already declared that short
  syntax invalid, so it is now a read error at the right column rather than
  a silent mis-parse. One real occurrence existed in this repo
  (`examples/ai_agent/src/tui.gene`), a latent wrong-arity bug that raised
  nothing; it is fixed.

The Step-3 load-speed benchmark passed on a provisional corpus (this repo's
own `.gene` files, not yet the full committed manifest with generated
fixtures, comment-density stratification, and a dependency-graph class that
Step 3/"Benchmark corpus and calculation" specifies): a 3.6x+ overall
geometric-mean speedup for `decodePacked` over `readAll`, every size class
comfortably above both the 0.95x per-class floor and the 2x overall bar.
Because the full manifest-gated corpus and fuzz-testing pass are still
open, this is "v0 implemented and passing its provisional gates," not yet
the Step-5 "frozen durable format version 1."

### Model-training track status

Steps 6-7 exist as working infrastructure (`src/gene/document_units.nim` and
its `gene docunits` / `gene docunits --decode` CLI pair; `training/` holds
the corpus pipeline, the two matched tokenizers, one shared model, the
matched training driver, and `training/evaluate.py`). `evaluate.py` reports
one verdict per pre-registered gate and treats a gate whose inputs are
missing as `NOT_MEASURABLE`, never as a pass.

A first matched from-scratch pilot has been run on one GB10 GPU: both arms
17.5M parameters, context 1024, 6000 steps, batch 16, identical
hyperparameters, over 186 documents (16.2M unit-arm training positions vs
16.55M byte-arm). Scorecard, in the pre-registered terms:

| gate | verdict | measured |
| --- | --- | --- |
| G1 zero representation loss | **pass** | 302/302 files, 186/186 corpus documents |
| G2 memorization >= 99% | **pass** | 99.33% (99.18% scored from document starts) |
| G3 structural validity >= 99% | not measurable | see below |
| G4 semantic pass rate >= 20% | not measurable | no task corpus with declared tests |
| G5 beat control 5pp / 20% rel. | not measurable | depends on G4 |
| G6 <=1.5x positions, >=80% throughput | **pass** | 0.981x positions, 1.019x throughput |
| R payload routing rule | **fires** | 95.6% of positions, 93.6% of held-out loss |

G2 was measured on a separate 24-document, 12,889-position corpus, which is
what "a deliberately tiny corpus" means here (`build_corpus.py
--max-source-bytes N --limit K --split 100,0,0` builds it reproducibly).
Reaching the bar needed dropout 0 and enough steps — 93.6% at 4k steps with
dropout 0.1, 98.98% at 12k with dropout 0, 99.33% at 36k — so the lever is
optimization budget, and dropout directly opposes the thing this gate
measures. G3 is not measurable *against this
corpus*: its median document is ~4,700 logical units, so whole-document
generation measures document length rather than structure — of 16 sampled
generations, 14 never closed within a 4096-unit budget, and the 2 that did
close were genuinely malformed (a role marker where a value belongs), which
is what a 6000-step model should be expected to produce. Making G3 mean
something needs either the designed held-out generation task (G4's blocker)
or a corpus whose documents fit a generation budget.

Note what G6 says: the structural modality is not merely affordable, it is
slightly *cheaper* than canonical text on both axes the study gates on. That
is a real result, and it is also not the question the study exists to answer
— G4 and G5 are, and they remain unmeasurable.

Two further results come from the corpus alone, before any training run:

- **Pilot gate 1 (zero representation loss) passes.** All 302 `.gene` files
  under `examples/` and `tests/` that v0 can encode round-trip
  document -> logical units -> JSONL -> document -> canonical text exactly,
  as do all 186 documents of the built corpus (302 files dedup and
  compile-filter down to 186). `build_corpus.py` enforces this per file, so
  a violating document is rejected from the corpus rather than trained on.
- **The payload-piece routing rule already fires.** Identifier, string, and
  comment payloads occupy 95.6% of unit-arm model positions in aggregate and
  79.1% in the median document -- both over the 70% threshold at which this
  document says the result "routes to a learned lossless payload-piece
  experiment rather than being blamed on the structural modality." The
  aggregate figure is inflated by a few serialized-session fixtures that are
  ~99.9% string payload, but the median clears the threshold on its own, so
  this is not only corpus skew.

The two gates that speak to modality *benefit* rather than sanity -- the
held-out semantic pass rate and beating the matched control -- remain
structurally unmeasurable: no task corpus with declared, executable tests
exists yet, and the held-out task set this document specifies (requiring
combinations of structural units absent from the training templates) has not
been designed. Until that exists, a pilot can be run but not scored on the
question the study is actually about.

## Idea and priority

Gene should have a structured, non-textual program modality on which a model
can be trained from scratch. Compatibility with models limited to ordinary
text tokenization is not the objective.

The model consumes and generates the program representation itself. It does
not call a program-building API, emit `.gene` text as an intermediate step, or
spell an opaque byte stream. Structural opcodes, value kinds, boundaries, and
payloads are first-class model inputs and outputs.

The top goal is to make native Gene program structure a trainable modality.
Independently, the durable encoding of that structure must load faster than
lexing and parsing `.gene`. A format that does not beat `readAll` remains an
experiment and must not become Gene's stable program artifact.

Every valid program in the format must also be translatable to a semantically
equivalent, canonically formatted `.gene` source file. Comments and
documentation must survive that translation in their corresponding positions,
after deterministic normalization to canonical structural boundaries. Original
whitespace and surface spelling do not need to survive.

This is a source-level representation. It is distinct from compiled GIR or VM
bytecode, which may lose reader structure through expansion, resolution, or
lowering and therefore cannot be the authoritative reversible form.

## Goals

- Define a non-textual Gene program modality suitable for training a model
  from scratch.
- Let the model consume and construct complete Gene programs directly as
  typed structural units, without a textual program representation in the
  model data path.
- Make structural validity locally learnable, constrainable, and repairable
  during generation.
- Make the durable program encoding load materially faster than ordinary
  `.gene` through the complete decode, validation, allocation, and interning
  path.
- Preserve all source-level forms before macro expansion and name resolution.
- Print every decoded program as semantically equivalent canonical `.gene`.
- Preserve positional comments and documentation at stable structural
  locations.
- Support streaming validation and bounded resource use for untrusted input.
- Keep comments and source tooling data off the runtime `Value` hot path.
- Define deterministic encoding, decoding, validation, and canonical printing.

## Non-goals

- Reproducing the author's original whitespace, indentation, or choice of
  reader sugar.
- Reconstructing source from compiled GIR or bytecode.
- Preserving datum comments (`#_`) or the forms they discard. They remain
  reader spacing and disappear when `.gene` is converted into this format.
- Compatibility with text-only LLM input/output interfaces or their existing
  text tokenizers.
- Freezing model-specific vocabulary IDs into Gene's durable file format.
- Making opaque raw bytes directly predictable by a model.
- Including source-location/provenance sections or compiled caches in version
  1. Those are deferred extensions with separate compatibility contracts.
- Exposing definition documentation through runtime reflection in version 1.
  Documentation is source-only.
- Replacing human-authored `.gene` source.
- Requiring comments or source locations to be materialized during ordinary
  execution.

## Central model

The format should be defined first as a logical program document. Physical
encodings are projections of that one model:

```text
                                      .gene
                              document  |  ^  canonical
                                reader  v  |  writer
model-native program units <--> program document <--> durable packed file
                                        |
                                        +--> compiler --> GIR / bytecode / native
                                             (one-directional; not part of the
                                             reversible contract)
```

The version 1 program document contains the semantic form tree plus positional
comments. It sits immediately after reading and before macro expansion,
binding resolution, type checking, or compilation. Both `.gene` and the
model-native representation produce this same logical document. A later schema
may add optional source metadata without changing the version 1 semantic tree.

This separation avoids forcing one physical encoding to satisfy every concern:

- The model generates typed program units rather than textual syntax, byte
  offsets, checksums, or string-table indexes.
- A packed file encodes the logical document compactly and may add framing,
  indexes, or deduplication without changing program meaning.
- The canonical writer operates on the logical document and does not need to
  decompile executable code.

Canonical `.gene` remains the human-readable interoperability projection and
the performance comparator for packed loading. It is not the model's primary
training representation.

## Model-native program modality

The modality consists of typed logical units corresponding to program
structure: container starts and ends, value kinds, literals, properties,
metadata, and positional comments. A training data loader maps those logical
units to model inputs; a generation decoder maps model outputs back to logical
units. Neither operation converts the complete program to ordinary text.

Training corpora can store the durable packed files directly. The data loader
streams their typed records into model tensors or embeddings without parsing
`.gene`; generated logical units serialize back to the same packed format. The
model therefore consumes and produces this format even though tensorization
and durable serialization necessarily use different in-memory layouts.

Structure and payload need not share one embedding scheme. Structural units
can use a small fixed vocabulary, while identifiers, string literals, and
comment text can use byte, Unicode, or learned payload units within explicitly
typed regions. The choice is part of model design, not Gene surface syntax.

### First model-pilot unit recommendation

The first training pilot uses the simplest lossless unit scheme that does not
depend on a text tokenizer:

- A small fixed structural vocabulary covers document and container
  boundaries, Gene value kinds, node head/body/property/metadata roles, literal
  kinds, and positional comment kinds.
- User identifiers, strings, regex patterns, and natural-language comments use
  UTF-8 byte units inside explicitly typed start/end regions. The surrounding
  type means these bytes are payload, not ordinary source text.
- Integers use a sign plus canonical base-128 magnitude units. Floating-point
  values carry their canonical IEEE-754 payload, with model-side numeric
  features permitted as additional embeddings. Other scalar types use their
  typed canonical fields rather than their `.gene` spelling.
- Registered or frequent Gene names may receive model-local shortcut IDs, but
  the logical representation remains a symbol payload and therefore does not
  freeze those IDs into the file ABI.
- User identifiers remain inline in the logical model stream for version 1.
  The model does not predict global string-table indexes or forward
  references. The durable encoder may intern and deduplicate strings after
  generation.
- Depth, enclosing value kind, and current structural role may be supplied as
  auxiliary model features. They are derived from the unit stream and are not
  serialized as program meaning.

Byte payloads are a deliberately conservative starting point. Learned payload
pieces can be evaluated later without changing the logical document schema,
provided their expansion back to canonical payload bytes is lossless.

The representation should favor local decisions:

- Use explicit structural tags rather than overloaded punctuation.
- Use end markers while generating; do not require the model to predict byte
  lengths before it has generated a subtree.
- Keep literal payloads adjacent to their type tags.
- Use canonical ordering wherever ordering is not semantically meaningful.
- Avoid forward references to global string tables in the generated form.
- Avoid model-generated offsets, hashes, checksums, and derived counts.
- Make every prefix either valid-incomplete or invalid with a precise local
  diagnostic.
- Allow a validator to report the structural path of an error and resume at a
  known boundary where practical.

### Model units are not the durable ABI

Model-specific integer IDs, embedding-table positions, tensor layouts, and
checkpoint vocabulary numbering are a training transport. They may change
between model families or training runs. The durable file stores versioned
logical kinds and payloads, never raw model vocabulary IDs.

A diagnostic tool may render logical units in a printable form for humans, but
that spelling is not the training representation and is not normative. This
keeps tokenizer evolution from becoming a Gene file-format compatibility
commitment.

### Training corpus pipeline

The initial corpus is produced by translating `.gene` source into the native
format. An LLM may generate tens of thousands of candidate `.gene` programs,
but a candidate enters the training corpus only after this pipeline succeeds:

```text
generated .gene
-> read and validate
-> compile and run declared tests
-> canonicalize
-> encode native document
-> decode and verify forms/comments
-> deduplicate
-> assign a stable train/validation/test split
```

This corpus is intended to prove the modality with a small model trained from
scratch. Its size is not assumed sufficient for a generally capable production
model; later scaling is driven by held-out capability measurements and corpus
diversity.

## Logical program document

The logical document must represent every reader-level Gene value and
source-unit boundary needed for canonical source reconstruction, including:

- multiple top-level forms, preserving their order;
- scalar literals with their semantic type and value;
- symbols and registered names;
- lists, maps, sets, hash maps, and mutable or immutable nodes;
- node head, body, properties, and metadata;
- reader-produced path and selector forms after their specified reader
  transformation;
- all other reader sugar in the canonical semantic shape chosen by Gene;
- positional comment/documentation records interleaved at structural
  boundaries.

The document schema must be versioned independently from the compiled GIR
artifact ABI. Its versioned contract includes value kinds, structural traversal
order, duplicate-property policy, and the preserve-versus-sort policy for maps,
sets, symbol tables, selectors, and every other collection. Any order that is
semantic is preserved exactly; every non-semantic order has a frozen canonical
rule. Schema evolution must either remain backward readable or fail closed
with an explicit unsupported-version diagnostic.

### Reader sugar policy

Version 1 represents canonical reader semantics, not source spelling choices.
The `.gene` translator applies the existing reader transformations before
encoding. Pipe syntax, interpolation, quasiquote/unquote spelling, spread
spelling, and other sugar therefore become their canonical reader-produced
values rather than separate modality units.

The format still preserves distinctions that survive reading and matter to the
compiler or canonical printer. In particular, selector literals remain
distinct from context-neutral slash paths, mutable and immutable containers
remain distinct, and node head/body/properties/metadata retain their separate
roles. The canonical `.gene` writer chooses one spelling for every resulting
semantic form.

## Comments and documentation

Comments are not executable Gene values, but they are part of the reversible
program document. They should live in an optional side structure rather than
inside NaN-boxed `Value`s.

This requirement serves the model-training goal directly. Documentation and
algorithm explanations are useful training data, and a model should be able to
place them between the program steps they describe. Comment support is not
being added merely to improve `gene fmt`.

The format should preserve position rather than require every comment to claim
semantic ownership of another value. Conceptually, standalone comment lines
are events interleaved into the program's structural stream. A comment event
occurs at the current nesting depth and traversal position, so it can appear:

- before, between, or after top-level forms;
- before, between, or after values inside an enclosing value;
- between a node head, property, metadata, or body entry;
- immediately before the close of an empty or non-empty enclosing value.

This is similar to inserting comment lines at arbitrary steps in an algorithm.
The event's stream position supplies its meaning; the logical model does not
need `previous`, `next`, or `enclosing` semantic-ownership tags.

The schema defines a canonical depth-first traversal and numbers the boundary
before and after every structural unit. A positional comment record contains a
boundary number, an ordinal for multiple comments at that boundary, a
placement kind, and its text. The packed comment section therefore contains
positional references, but those references identify traversal boundaries,
not semantic owners. The ordering and boundary-numbering rules are part of the
versioned format contract.

In the model-facing logical stream, comment units are interleaved directly at
those boundaries, making a comment as easy to generate as another sequential
program unit. When the document is packed, the encoder separates comment
payloads into the boundary-indexed overlay so an execution-only decoder can
skip the whole comment section. The training loader and canonical writer merge
the semantic and comment streams by their monotonically increasing boundary
positions.

There are two special placements:

- An optional bang line belongs to the source unit and is always emitted as
  the first line. Only a `#!` comment at byte offset zero is read as a bang
  line; any later `#!` text is an ordinary positional comment. Root comments
  that preceded a non-leading `#!` remain ordinary comments.
- A comment at the end of a line is represented as a trailing comment on the
  preceding completed value. If no value precedes it at that nesting depth, it
  is a standalone positional comment instead.

Module-level comments are simply positional comment events in the root source
unit. Documentation uses the same positional mechanism; a later design may
distinguish documentation as a comment kind if tools need to query it.

Whitespace is canonicalized. The writer chooses indentation, line wrapping,
and blank-line policy while keeping every standalone comment at the same
structural boundary and every trailing comment after its preceding value.
Block-comment input may be normalized into positional comment lines; preserving
the original comment delimiter style is not required.

The native document's positions are authoritative. When arbitrary `.gene`
source is imported, the document reader maps comments to canonical structural
boundaries deterministically. Comments written inside reader sugar may move to
the boundary of the canonical form produced by that sugar. Exact source-token
position is not promised. Once normalized, document -> canonical `.gene` ->
document preserves the normalized comment event stream.

Datum comments (`#_`) are deliberately unsupported. On `.gene` input they keep
their existing reader meaning as spacing: both the marker and its discarded
form are absent from the logical program tree.

The packed representation places comment text in a separable section so a
runtime load can skip it. Tooling, formatting, source translation, and model
training can request it explicitly.

Definition documentation is source-only in version 1. It is preserved and made
available to source tooling, model training, formatting, and canonical `.gene`
projection, but it is not runtime-reflectable metadata.

## Canonical `.gene` projection

Translation back to `.gene` is a required operation, not merely a debug dump.
The result may use canonical forms instead of the original reader sugar, but it
must preserve program meaning and comment/documentation placement.

The core invariants are:

```text
decodeUnits(encodeUnits(document)) == document
decodePacked(encodePacked(document)) == document
readAll(writeCanonical(document)).forms == document.forms
readDocument(writeCanonical(document)).comments ==
  normalizeComments(document.comments)
encodePacked(decodePacked(canonical_packed_program)) ==
  canonical_packed_program
```

`encodeUnits` and `decodeUnits` operate on logical units, not
model-specific vocabulary IDs. The final invariant applies only to the
canonical packed encoding. Optional derived sections are either excluded from
canonical equality or regenerated according to their section contract.

Round trips should additionally guarantee:

- `writeCanonical` is deterministic;
- formatting canonical output again is idempotent;
- comments retain their structural order and positions;
- `.gene` datum comments remain semantically discarded and do not appear in
  the packed representation or canonical output;
- duplicate-property policy and other reader validity rules do not change
  between the two inputs;
- multi-form source units remain multi-form source units.

## Packed file encoding

The exact wire layout is deliberately deferred. A candidate should have:

- a magic identifier and format version;
- explicit section framing with checked bounds;
- a required semantic form section;
- an optional comment/documentation section;
- deterministic literal and symbol encoding;
- versioned canonical ordering for non-semantic collection order;
- canonical integer and length encodings;
- hard limits for nesting depth, collection size, top-level form count,
  logical-unit count, individual string size, aggregate comment/documentation
  size, file size, and total allocation;
- rejection of unknown required sections and safe skipping of unknown optional
  sections whose framing and declared length are valid;
- no dependence on process pointers, current intern IDs, NaN-box payload bits,
  host endianness, or Nim object layout.

Raw bytes that do not form a valid framed section are rejected as trailing
data. This is distinct from an unknown optional section, which has valid
framing and can be skipped by length. Any future compiled-cache section must
define its own hash, compatibility, invalidation, and discard rules; it cannot
inherit the authoritative source section's integrity semantics implicitly.

Version 1 writers emit no source-location, provenance, or compiled-cache
section. Decoders reserve the framed optional-section mechanism for future
versions, while version 1 diagnostics identify logical-unit offsets and
structural paths.

The encoder may deduplicate strings and symbols or calculate subtree lengths
after generation. Those are storage decisions and should not become burdens the
model must satisfy while constructing the program.

Direct materialization into runtime values may be possible for many forms, but
zero-copy loading should not be assumed: Gene `Value`s can contain process-local
references and interned identities. Performance claims need measurements of
total decode, allocation, interning, validation, and compilation cost.

## Relationship to current Gene code

Gene already has several pieces that support this direction:

- `readAll` preserves multi-form source units and provides the semantic reader
  boundary the new format should target.
- The reader can capture line and block comments as spanned trivia tokens,
  while normal semantic reads omit that allocation.
- `gene parse` uses the canonical printer.
- `gene fmt` preserves comments today, but an interior comment forces it to
  retain the original form slice because the semantic reader drops comments.
  Structured comment events would remove that raw-source fallback.
- The current GIR codec is a compiler-internal executable artifact and stores
  reachable reader values as canonical Gene strings inside JSON. It should not
  be confused with this reversible source-program format.
- Gene's serde (`docs/serialization.md`) round-trips arbitrary runtime
  values, including nodes, through canonical Gene text with reserved-head
  escaping. It has no concept of comments, bang lines, or multi-form source
  units — those never survive the semantic reader into a runtime `Value` —
  and its wire format is Gene text itself, not a faster-loading binary
  encoding. It solves durable application data, not reversible program
  source, and should not be confused with this format either.

These existing boundaries suggest adding a source-document/form-tree layer
alongside `Value`, not enlarging `Value` or changing its eight-byte layout.

## Relationship to the general-intelligence research program

[`general_intelligence/architecture.md`](general_intelligence/architecture.md)
proposes a hybrid architecture in which an LLM or small learned model
proposes programs and Gene executes and verifies them. Its current
experiments qualify and pilot that proposer role with off-the-shelf,
text-tokenized models such as `gpt-oss-20b` (see
`general_intelligence/qualifications/`), reached through ordinary text
generation and tool calls.

This document's non-goal of text-tokenizer compatibility describes the model
trained from scratch here. It is not a requirement placed retroactively on
the proposer role those experiments already use. If the model-training study
below succeeds, its most direct integration point is as a candidate for that
proposer role — a Gene-native specialist competing with, not gating, the
general-purpose LLM proposer in use today. The two efforts are independent
until then: general-intelligence experiments do not wait on this modality,
and this modality's pilot gates do not depend on general-intelligence's
results.

## Validation and safety

AI-generated programs are untrusted input. Decoding must validate structure
before compilation or execution and must fail closed on:

- malformed framing or non-canonical encodings;
- excessive nesting or declared sizes;
- invalid UTF-8 or literal payloads;
- duplicate properties under the schema's frozen rejection policy;
- unsupported required schema features;
- invalid comment positions or references;
- raw trailing bytes that are not a valid framed optional section;
- any configured total-form, logical-unit, comment-size, file-size, or
  allocation limit.

Validation should be streaming where possible and should not require a second
full pass over the artifact merely to discover structural corruption.

## Evaluation plan

The durable format and the model modality have separate verdicts:

- The durable format can become stable after its schema, round-trip, safety,
  and load-speed gates pass. It does not wait for a successful model-training
  research program.
- The model-facing unit encoding remains experimental until it demonstrates
  both learnability and material benefit over a matched canonical `.gene`
  control. It may evolve without changing the durable ABI.

A failed modality pilot therefore triggers a model-interface or payload-design
revision without invalidating an otherwise useful fast reversible format. A
failed load gate prevents the packed encoding from becoming stable even if the
model experiment succeeds.

### Reversibility corpus

- Cover every reader literal and collection kind.
- Cover multiple top-level forms.
- Cover standalone comments at every structural boundary and nesting depth.
- Cover bang lines, module-level comments, and trailing comments.
- Verify that nested block-comment input can be normalized without changing
  executable forms.
- Verify that datum comments and their discarded forms are omitted.
- Cover reader sugars whose canonical output differs from input.
- Property-test source -> document -> packed -> document -> canonical source
  -> document.
- Property-test logical units -> document -> logical units.
- Require canonical logical-unit re-encoding to be unit-for-unit identical.
- Fuzz malformed, truncated, and interrupted logical-unit streams as well as
  packed files under the same resource limits.

### Model-training study

Train a small model from scratch on the structured modality without converting
whole programs to ordinary text. The study must include a matched canonical
`.gene` byte-model control. The two arms use the same backbone capacity,
optimizer, training-example pool, total training-FLOP budget, maximum context
positions, and evaluation tasks. Their input/output heads differ only where
the modality requires it. A later subword-text arm may provide an additional
practical baseline, but it does not replace the matched byte control.

The dataset split is structural, not random-by-file. Exact and near-duplicate
semantic trees, generated templates, and task families must not cross split
boundaries. Held-out tasks require combinations of structural units absent
from the training templates, and results are reported by semantic-tree novelty
distance.

The study measures:

- logical-unit count and payload cost;
- training and held-out loss by unit kind;
- exact reconstruction rate;
- structural validity rate;
- compile success rate;
- semantic test-pass rate;
- repair success after an injected local-unit error;
- frequency and distance of cascading structural failures;
- model positions and payload bytes per program;
- training throughput and memory at matched capacity and compute;
- each metric side by side with the canonical `.gene` control.

The memorization and structural-validity checks are sanity gates, not evidence
of modality benefit. Before a model-facing unit encoding can advance, a pilot
must:

- round-trip the training data loader and generated logical units with zero
  representation loss;
- memorize a deliberately tiny corpus to at least 99% exact unit-sequence
  accuracy, proving that the modality and output head are learnable;
- produce at least 99% structurally valid documents on the structurally
  held-out generation task;
- achieve at least a provisional 20% semantic test-pass rate on held-out tasks;
- beat the matched canonical `.gene` control's semantic pass rate by at least
  5 percentage points and 20% relative, with the bootstrap confidence interval
  for the difference excluding zero;
- use no more than 1.5x as many model positions per program and sustain at
  least 80% of the control's training throughput.

These provisional semantic and efficiency bars must be confirmed before the
corpus split and training run are created. If identifier, string, or comment
payloads occupy more than 70% of model positions or dominate more than 70% of
held-out loss, the result routes to a learned lossless payload-piece experiment
rather than being blamed on the structural modality.

Failure pauses advancement of the model-facing unit encoding and triggers a
modality or model-interface redesign. It does not block an independently
qualified durable format, and it does not silently fall back to `.gene` text
and claim the modality goal was met.

### Runtime benchmark

Compare `.gene` reading with packed decoding for small modules, large modules,
and dependency graphs:

- wall-clock load time;
- allocations and peak memory;
- symbol interning cost;
- validation cost;
- time until compilation begins;
- total cold and warm startup time.

### Benchmark corpus and calculation

The benchmark corpus is committed as a manifest before decoder optimization or
measurement. Every case contains one logical document and its canonical
`.gene` and canonical packed encodings. The manifest fixes file hashes,
generator versions, class membership, comment density, and the machine/runtime
profiles on which the acceptance result will be reported.

Classes use canonical `.gene` byte size, not packed size. The primary corpus
gives equal class weight to:

1. tiny source units up to 1 KiB;
2. small source units over 1 KiB and up to 16 KiB;
3. medium source units over 16 KiB and up to 256 KiB;
4. large source units over 256 KiB and up to 4 MiB;
5. dependency graphs of 50 to 500 modules totaling 256 KiB to 16 MiB.

Each single-unit class contains at least 20 cases and the graph class at least
10. Repository programs are preferred; deterministic generated fixtures fill
missing size, nesting, literal-diversity, symbol-reuse, and comment-density
cells. At least one quarter of each class is comment-heavy, defined as comment
bytes occupying at least 20% of canonical `.gene` bytes, so the cost of
skipping the comment section remains visible.

Each case runs at least 5 warmups and 30 measured repetitions. The case time is
the median measured time. A case speedup is `gene_time / packed_time`; a class
score is the geometric mean of its case speedups; and the overall score is the
equal-weight geometric mean of the five class scores. Allocation results use
the same class weighting. The benchmark reports in-memory decode, warm
file-to-forms load, and cold file-to-forms load separately; the acceptance bar
uses the warm file-to-forms result, which includes file read, validation,
allocation, and interning.

Benchmarks must separate source reading, form decoding, compilation, and GIR
loading so a faster source representation is not credited for unrelated cache
effects.

The provisional acceptance bar, to be confirmed before benchmarking, is at
least a 2x geometric-mean speedup over `readAll` for file read + decode/parse +
validation + interning across the representative corpus, with fewer
allocations and every workload-class score at least 0.95. Total cold and warm
startup are reported separately because later compilation can dominate both
inputs. Missing this bar keeps the format experimental and requires a
packed-layout redesign.

## Suggested sequence

1. Specify a provisional logical document schema, versioned ordering rules,
   and positional comment boundaries.
2. Build the smallest packed encoder/decoder and `.gene` bridge needed for a
   representative corpus.
3. Run the load-speed benchmark early; redesign or stop stabilization if the
   packed representation misses its acceptance bar.
4. Prove form and normalized-comment round trips, canonical determinism, and
   malformed-input safety over the reader corpus.
5. If the load and correctness gates pass, freeze the durable format version 1
   contract independently of model-training results.
6. Design candidate model-native unit and payload encodings over the proven
   document schema.
7. Implement the native data loader/output head and matched `.gene` control,
   then run the small training pilot.
8. Advance the model-facing encoding only if its learnability, novelty,
   semantic-benefit, and efficiency gates pass.
9. Keep source locations, provenance, compiled caches, and runtime-reflectable
   documentation outside version 1.

## Durable format version 1 decisions

- Version 1 carries canonical reader semantics and does not preserve the
  author's choice of reader sugar.
- Comments are sequential logical units at canonical structural boundaries.
  The packed file stores their payloads in a skippable positional overlay, and
  end-of-line comments trail the preceding completed value.
- Definition documentation is source-only.
- Source locations, provenance, compiled caches, and runtime-reflectable
  documentation are deferred and absent from version 1.
- Model-local shortcuts, embeddings, and vocabulary IDs are never durable
  format IDs.
- Durable stability requires the round-trip, canonicalization, safety, corpus,
  and load-speed gates; it does not require a successful model pilot.

## First model-pilot decisions

- The pilot model and matched canonical `.gene` byte control are trained from
  scratch at matched capacity, compute, data, and context budgets.
- The initial corpus comes from validated `.gene` programs translated into the
  native format. LLM-generated candidates must pass the corpus pipeline before
  training.
- Structural kinds use a small fixed vocabulary. Typed UTF-8 byte regions
  encode identifiers, strings, regex patterns, and comments; canonical typed
  fields encode numeric and other scalar values.
- The train/validation/test split holds out semantic-tree clusters and task
  families, not merely files.
- The pilot must pass the predeclared semantic-benefit and efficiency bars
  against the matched `.gene` control; grammar learning alone is insufficient.

The exact durable kind table, model structural vocabulary, model architecture,
training curriculum, and corpus contents are implementation design work within
these decisions. All provisional thresholds and corpus manifests must be
confirmed before their corresponding measurements begin.

## Appendix: base model for the first serious Gene model

This is a point-in-time candidate recommendation, dated 2026-08-10. Model
availability, licensing, and capability shift quickly; re-verify the
candidate list and its architecture claims against current model cards
before acting on it. Unlike the two decisions sections above, nothing in
this appendix is frozen.

It is also a later, separate effort from the sequence above, not another
name for the same pilot. Step 7 and "First model-pilot decisions" both
require the pilot model and its `.gene` control to be trained from scratch
at matched capacity, compute, data, and context budgets — that match is what
makes the Model-training study's semantic-benefit verdict valid. Adapting a
pretrained Qwen3.5 checkpoint with LoRA, as recommended below, does not
satisfy that requirement: a pretrained multimodal backbone brings capability
the matched control would not have, which would confound the comparison.
Read this appendix as a candidate for building a capable Gene model after
step 8's gates pass, not as a substitute for the from-scratch pilot itself.

### Recommendation

Use **Qwen3.5-4B-Base** for the first serious Gene model, but do **not**
full-fine-tune it on one 64 GB GPU. Freeze the existing vision tower, add a
small Gene encoder/projector, and train that component together with LoRA
adapters in the language backbone. If the experiment specifically requires
full-parameter continued pretraining, use **Qwen3.5-2B-Base** instead.

This is a training-regime split, not a close model-ranking call:

- **Best capability under the 64 GB constraint:** Qwen3.5-4B-Base plus a Gene
  adapter and decoder LoRA.
- **Best full-parameter candidate under the same constraint:**
  Qwen3.5-2B-Base, with short sequences, activation checkpointing, batch size
  one, and a memory-efficient optimizer.

The 4B checkpoint is the stronger default because it is an Apache-2.0 base
model intended for fine-tuning, has a 4B-parameter language model (about 5B
parameters including its vision side), and was pretrained as a unified
vision-language model on interleaved modality tokens. Qwen says its early
fusion foundation improves reasoning, coding, agents, and visual understanding
over Qwen3-VL. The same card says its existing chat control tokens were included
in base-model training specifically to make LoRA-style adaptation possible
without retraining the large embedding table. [Qwen3.5-4B-Base model
card](https://huggingface.co/Qwen/Qwen3.5-4B-Base)

### Why its architecture fits Gene

Qwen3.5 already implements the seam Gene needs. It has a modality-specific
encoder whose output vectors are projected to the language model hidden size,
placed into modality placeholder positions, and then processed by the shared
language model. The Transformers implementation literally replaces image/video
placeholder embeddings with encoder output before calling the language
backbone. [Qwen3.5 implementation](https://github.com/huggingface/transformers/blob/main/src/transformers/models/qwen3_5/modeling_qwen3_5.py)

For Gene, add a parallel path:

```text
packed Gene document
  -> deterministic unit decoder
  -> Gene unit encoder
  -> projection to 2560 dimensions
  -> <gene_unit> placeholder embeddings
  -> Qwen3.5-4B language backbone
```

The deterministic unit decoder is part of the model's data pipeline, not a
program-construction API. It exposes the optimized structural units directly:
node kinds, arities, typed values, symbol/string payload regions, and positional
comments. The packed-file ABI must remain independent of Qwen token IDs.

Use ordinary one-dimensional sequence positions for Gene units. Do not pretend
that a program has image height/width or inherit the vision tower's spatial
position scheme. The minimal model change is a Gene placeholder token, a Gene
encoder/projector, and a modality dispatch branch analogous to the existing
image branch. If the model must emit the non-textual unit stream directly, add
a Gene output head (structural-unit vocabulary plus typed payload handling)
rather than making it emit raw packed bytes.

Qwen3.5's text backbone uses three Gated DeltaNet layers for every full-attention
layer, while the vision tower is inherited from Qwen3-VL. This should make long
unit streams more economical, but the optimized `causal_conv1d` and `fla`
kernels matter: Transformers warns that the fallback implementation is slower
and uses more memory. [Transformers Qwen3.5
documentation](https://huggingface.co/docs/transformers/model_doc/qwen3_5)

### 64 GB feasibility

A conventional mixed-precision AdamW full fine-tune consumes roughly 18 bytes
per parameter before activations and temporary buffers. On that rule of thumb,
the complete 5B-parameter 4B checkpoint needs about 90 GB before activations,
so it is not a single-64-GB full-fine-tune model. The same estimate gives about
36 GB for the 2B checkpoint, leaving limited but usable room for activations
when the vision tower is frozen or omitted and sequence lengths are kept
modest. Hugging Face's current memory guide likewise estimates about 85 GB for
a mixed-precision 4B training example and explains how optimizer choice and
activation size change the result. [GPU memory
anatomy](https://huggingface.co/docs/transformers/en/model_memory_anatomy)

These are planning estimates, not a guarantee. Qwen3.5 has a very large tied
embedding table and hybrid-attention state, and actual peaks depend heavily on
GPU architecture, kernels, program-unit sequence length, and batch packing.
Before a long run, perform a one-batch forward/backward memory probe using the
real Gene length distribution.

For the recommended 4B run:

1. Keep the language weights in BF16 and frozen.
2. Freeze or omit the image encoder unless preserving image input is a product
   requirement.
3. Train the Gene encoder/projector and a decoder LoRA; start with 2K-8K unit
   sequences and gradient checkpointing.
4. Use QLoRA only if longer sequences or larger batches require it. QLoRA keeps
   the base frozen in 4-bit form and backpropagates into low-rank adapters; the
   original paper demonstrated that this changes the memory scale enough to
   tune a 65B model on a 48 GB GPU. [QLoRA
   paper](https://arxiv.org/abs/2305.14314) PEFT supports the corresponding
   all-linear adapter configuration. [PEFT LoRA
   guide](https://huggingface.co/docs/peft/main/en/package_reference/lora)

For the 2B full-parameter run, use the base checkpoint, omit/freeze the vision
tower, enable activation checkpointing and optimized Qwen3.5 kernels, and begin
with a short context and microbatch one. An 8-bit optimizer can reduce Adam
state memory, but full tuning should still be treated as a measured experiment,
not assumed to fit at arbitrary context lengths. The 2B model has a 2048-wide,
24-layer language backbone and the same native multimodal foundation as the 4B
model. [Qwen3.5-2B-Base model
card](https://huggingface.co/Qwen/Qwen3.5-2B-Base)

### Candidate comparison

| Candidate | License and size | Gene-modality fit | One 64 GB GPU |
|---|---|---|---|
| **Qwen3.5-4B-Base** | Apache-2.0; 4B language model, about 5B total | Best current balance: base checkpoint, unified early-fusion pretraining, strong coding/agent focus, standard Transformers model | **Recommended:** Gene encoder/projector + LoRA. Not conventional full AdamW. |
| **Qwen3.5-2B-Base** | Apache-2.0; 2B class | Same design with lower capability and a 2048-wide projector target | **Fallback:** safest Qwen3.5 choice for full-parameter work. |
| **Qwen3-VL-2B-Instruct** | Apache-2.0; 2B class | Mature separate vision encoder/projector design; Qwen publishes component-level tuning switches and LoRA examples, but it is an older instruction checkpoint rather than the newer unified base | Good fit for LoRA or component tuning; choose it if Qwen3.5 training-kernel/tooling issues block the pilot. [Model card](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct) [official tuning guide](https://github.com/QwenLM/Qwen3-VL/blob/main/qwen-vl-finetune/README.md) |
| **SmolVLM2-2.2B-Instruct** | Apache-2.0; 2.2B class | Simple Idefics3-style system with a SigLIP encoder and SmolLM2 decoder; easy to understand and modify, but English-focused and less attractive for a code-language model | Comfortable for adapters and plausible for careful full tuning. Good throwaway prototype base, not the primary long-term choice. [Model card](https://huggingface.co/HuggingFaceTB/SmolVLM2-2.2B-Instruct) |
| **Phi-4-multimodal-instruct** | MIT; 5.6B | The strongest architectural precedent: Microsoft added vision and speech to a 3.8B language backbone using modality encoders, adapters, and modality-specific LoRA routing. It is nevertheless an older instruct model with custom model code. | Adapter-only on 64 GB. Valuable as a design reference rather than the chosen checkpoint. [Model card](https://huggingface.co/microsoft/Phi-4-multimodal-instruct) [technical report](https://arxiv.org/abs/2503.01743) |

### Suggested first training sequence

1. **Alignment:** freeze Qwen; train only the Gene encoder/projector on
   packed-unit-to-canonical-Gene reconstruction, canonical-Gene-to-unit
   prediction, masked subtree recovery, and comment-placement tasks.
2. **Adaptation:** add language-backbone LoRA and train on mixed natural
   language, canonical `.gene`, packed Gene units, standard-library API tasks,
   and bidirectional translation. Retain ordinary text/code replay data so the
   base model does not forget system prompts and explanations.
3. **Instruction tuning:** teach tasks such as “generate,” “repair,” “explain,”
   and “translate to canonical `.gene`,” while requiring parse, round-trip, and
   execution checks in the evaluation pipeline.

Start with Qwen3.5-4B-Base plus adapters. Move to Qwen3.5-2B full-parameter
continued pretraining only if experiments show that adapters cannot internalize
the Gene unit grammar or reliably produce the non-textual output head.
