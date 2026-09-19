# Gene Capabilities: Grants, Requests, Block Boundaries, Checks, and Guards

**Status:** Consolidated proposed target design; not a claim about implemented behavior.  
**Date:** 2026-09-19.
**Scope:** Inert capability specifications; trusted grant configuration; module, function, and block requests; optional requirements; attenuation; provider-specific authorization; concrete-operation checks and mandatory guards; invocation and deferred-execution boundaries.

This is a complete replacement proposal, not an addendum. It preserves independent grant entries, whole-body and per-property matching of complete alternatives, namespace naming, and command-line precedence. Mandatory admission supports collective coverage of provider-defined alternatives as specified in section 3.4. It incorporates the review corrections and makes additional recommended decisions explicit in section 19. Once adopted, implementation and examples should move to this contract rather than accumulate parallel legacy authorization paths.

Names follow the updated document's `namespace/Name` convention: a lowercase namespace and CamelCase capability name. Thus the HTTP example is `(net/Http ^^optional)`. Identifiers are case-sensitive; `net/http` is not silently case-folded to `net/Http`. An alternate spelling requires an explicitly admitted alias. `cap/x` remains a schematic name only in the inherited comparison examples; it is not an exception to the production naming rule.

Source examples specify target behavior. New APIs and `require_capabilities` are proposed interfaces, not assertions that those names already exist. No Gene implementation or test suite was executed to prepare this revision. Section 15 gives the implementation sequence; section 17 identifies the remaining provider-specific details.

## Reading map

| Question | Section |
| --- | --- |
| What do grants, requests, block bounds, checks, and guards mean? | 1 |
| What can appear in a literal, including `^^optional`? | 2 |
| How do coverage and conservative admission differ? | 3, 6, 7 |
| How are modules, functions, and blocks restricted? | 7, 14 |
| How are CLI, files, and environment values selected? | 9 |
| Where does capability-specific logic live? | 10–12 |
| What must implementations test and preserve? | 13–17 |
| Which changes are new recommendations? | 19 |

## 1. Central decisions and the five roles

Use one small, inert capability format in command-line arguments, configuration files, environment variables, and source declarations:

```gene
[
  (fs/ReadWrite "/home/user/project" "/tmp")
  (net/Http ^hosts ["api.example.com"] ^methods ["GET"])
]
```

The same data can be supplied to different operations. Its receiving API determines whether it is trusted grant configuration, a requirement, or an upper bound. Its shape never establishes authority by itself.

### 1.1 Roles

| Role | Input and result | Responsibility |
| --- | --- | --- |
| Host grant | Trusted startup policy → opaque runtime authority | Establish what the application may potentially do, within administrator/embedding ceilings. |
| Code request | A module, function, or required block's declaration → admitted, restricted execution | Mandatory entries must match available authority; optional entries do not block entry. The declared row also limits the boundary. |
| Block grant / upper bound | Current authority plus a policy → restricted block execution | Delegate at most the intersection to everything executing through the block. This is attenuation, not creation of a root grant. |
| Programmatic check | A requirement row or concrete operation → a structured decision | Let code choose a fallback or explain missing authority without performing the requested effect. Policy checks and operation checks remain distinct. |
| Operation guard | The actual operation about to execute → proceed or raise | Enforce permission at the trusted effect boundary. An earlier successful check never removes this obligation. |

The user-facing phrase **grant capabilities to a block** means giving that block a restricted portion of authority already available to its caller. It never means that ordinary Gene code can mint a new permission or recover an earlier, broader root context.

### 1.2 Three representations

| Concept | Meaning |
| --- | --- |
| Capability specification | Inert data describing a set of permitted operations, with optional admission metadata when used as a request. |
| Granted runtime authority | Host-issued permission with provenance, validity, origin restrictions, and retained ceilings. It is opaque or internal. |
| Concrete operation | Actual resource and attributes derived by the trusted adapter from what it is about to do. Values are facts, not permission patterns. |

For example, `(net/Http ^hosts ["api.example.com"] ^methods ["GET"])` is a policy. The actual GET of `https://api.example.com/status` is an operation whose hostname and method are extracted from the prepared request. A missing `hosts` property in some other policy means unrestricted hosts; it does not mean an actual HTTP request lacks a hostname.

Reading a specification does not initialize a provider, execute a constructor, call a macro, or grant access. Permission also does not guarantee that the file exists, the remote service responds, or the operating system permits the operation.

### 1.3 Composition laws

```text
Entries in one row:                  alternatives (OR)
Constraints within one entry:         whole body AND each named restriction
Independent authority boundaries:    intersection (AND)
Mandatory request admission:          every requested alternative covered by
                                     a complete matching grant entry,
                                     in each applicable authority row
Concrete operation authorization:    one complete permitting entry per row,
                                     with every applicable ceiling satisfied
```

Separate entries must not contribute different fields to authorize one operation. GET on one host and POST on another must not become GET-or-POST on either host.

**Semantic coverage** means inclusion of operation sets. **Admission matching** uses complete-entry comparisons and exact provider-defined decomposition of requests into alternatives. Different alternatives may match different grants in the same row. The procedure remains conservative for unsupported decompositions and bounded proofs; a failed match need not mean that the union of grants forbids some requested concrete operation. Section 3 defines the distinction precisely.

### 1.4 Non-negotiable invariants

1. Ordinary code can narrow authority, but cannot increase it.
2. Provider identity and authorization behavior come from the trusted catalog, not application name resolution or scoped impl replacement.
3. The real effect uses a guard based on the actual operation. Neither declarations nor advisory checks substitute for it.
4. `^^optional` changes only whether a request blocks boundary entry. It never means optional enforcement.
5. Entering a boundary excludes authority not selected by its row; omitting a declaration is different from explicitly selecting `[]`.
6. Normalization never broadens permissions, loses cross-field correlations, or discards independent live-grant validity.
7. Narrowing follows executing calls and the defined task/stream/bound-callback boundaries. Restoration happens on every exit path.
8. External capabilities are not a complete sandbox for names, mutable references, CPU/memory use, or arbitrary native code.

## 2. Literal format

### 2.1 One restricted data grammar

```text
capability-row   := '[' capability-entry* ']'
capability-entry := capability-name
                  | '(' capability-name capability-component* ')'
capability-component := scalar | property | flag
property         := '^' property-name property-value
flag             := '^^' property-name
property-value   := scalar | '[' scalar* ']'
scalar           := '*' | string | integer | boolean
```

Whitespace separates components. Properties may be interleaved with positional body values. The reader retains the ordered body and named properties separately. `^^name` is the ordinary boolean-flag spelling of `^name true`, not a second permission language.

For version 1, property lists are flat. Lists as positional values, nested property lists, arbitrary nested nodes, and maps are excluded. Body values must be validated as a whole by the selected provider.

| Position | Permitted contents |
| --- | --- |
| Capability identifier | A catalog identifier such as `fs/Read`, or terminal namespace selector such as `fs/*`. |
| Body value | `*`, strings, integers, booleans. |
| Provider property | An admitted `^name` whose value satisfies that provider's schema. |
| Core admission property | `^optional true`, `^optional false`, or `^^optional`, only in request contexts. |
| Property value | A permitted scalar or a flat list of permitted scalars. |

### 2.2 Inert names and values

```gene
[
  fs/Read
  fs/*
  (fs/Read "/tmp")
  (net/Http * ^methods ["GET" "HEAD"])
]
```

A capability identifier may look like a symbol or path, but it is not evaluated as a variable or a property access. It resolves through the trusted catalog. Property labels are schema keys, not symbol-valued arguments.

`true`, `false`, and `*` are reserved literal values. All other symbol-valued arguments are invalid:

```gene
(fs/Read path)                    # Invalid: no variable lookup in a literal.
(net/Http ^methods [GET])         # Invalid: write "GET".
```

A literal does not admit executable expressions, interpolation, metadata, arbitrary maps, floating-point numbers, `nil`, or `void`:

```gene
(fs/Read (compute_path))          # Invalid.
(fs/Read $"${home}/data")         # Invalid.
(net/Http ^options {^port 8080})  # Invalid.
(cap/x 3.5)                      # Invalid in version 1.
(cap/x nil)                      # Invalid.
```

A launcher configuration may have a wrapper containing a capabilities field. That wrapper is outside this grammar.

Unknown names, unknown properties, unsupported body shapes, and invalid values are errors. Validate every entry before simplification, even when another entry is unrestricted or the invalid entry is marked optional.

The reader must detect duplicate properties before ordinary node/map construction can overwrite them. `^optional true ^^optional` is a duplicate, as are repeated provider fields. Reader extensions, macros, constructors, and evaluation do not run while reading capability data.

### 2.3 Unrestricted and empty forms

For a capability `C`, with no differing named constraints:

```text
C = (C) = (C *)
```

These specify an unrestricted body within C's operation domain. Omitting a known provider property or explicitly setting it to the token `*` leaves that dimension unrestricted:

```gene
(net/Http ^methods ["GET"])
(net/Http * ^methods ["GET"])
```

These two entries have the same operation coverage. They do not default to a specific host or scheme.

An empty allowed-alternatives list means no accepted alternative:

```gene
(net/Http ^methods [])            # No HTTP operation is permitted.
```

The provider rejects lists in fields for which it defines no list semantics. A mixed body containing `*` and other values is provider-validated; under alternative-body semantics `*` subsumes the other alternatives, but a structured provider must not inherit that simplification accidentally.

An empty outer row `[]` selects no authority. An omitted declaration or startup source is not an empty row. No unqualified row-level `*` is introduced; `fs/*` selects a namespace, while body/property `*` is an unrestricted constraint value.

The token `*` and the string `"*"` are distinct. The token is unrestricted in the field's entire valid domain. The string is a pattern over strings only.

### 2.4 The reserved `optional` property

```gene
(net/Http ^^optional)
(net/Http ^optional true)
(net/Http * ^optional true)
```

All three describe an unrestricted HTTP request that is optional at admission. `^optional false` is equivalent to omitting the flag in a request: the entry is mandatory. Only literal booleans are valid; `^optional *`, `^optional "true"`, and `^optional [true]` are errors.

`optional` belongs to the capability core. It is removed from provider properties before provider schema validation. Providers cannot redefine it, ignore it as an unknown field, or interpret it as a permission restriction.

| Receiving context | Is `optional` allowed? |
| --- | --- |
| Application/module/function/message/constructor request row | Yes. |
| `require_capabilities` block | Yes. |
| Programmatic requirement check | Yes; required and optional results remain distinguishable. |
| CLI/config/environment interpreted as host grant configuration | No, even when its value is false. Grants are not optional requests. |
| Administrator ceiling or `with_capabilities` upper-bound row | No. Attenuation already has no full-coverage obligation. |
| Concrete operation descriptor | No. An operation cannot request optional enforcement. |

An optional unknown provider or unsupported property still fails validation. Optionality handles missing authority, not unrecognized vocabulary or broken configuration.

The admission flag does not affect `Ops(entry)`, matching of actual operations, wildcard semantics, or grants' live validity. It affects whether failure to admit the request prevents boundary entry. See section 7 for partial availability.

### 2.5 Static literals versus dynamic policy values

A literal remains inert even in source declarations and boundary forms; it is not an ordinary expression list whose capability heads are invoked.

Dynamic hosts may parse configured text into an immutable `CapabilitySpecRow`, using a proposed operation such as:

```gene
(let bound ($capabilities/parse policy_text))
(with_capabilities bound
  (plugin input))
```

The whole `bound` expression is evaluated once before boundary entry. It must produce a validated spec-row value; it is not a symbol-valued argument inside a literal. Parsing uses an explicit source kind and normalization base, with the same size and schema limits as the CLI. This does not introduce textual interpolation or arbitrary execution within a capability literal.

Spec-row values carry data and normalization provenance, not authority. The runtime revalidates catalog compatibility and the receiving context's allowed admission metadata. A cached or serialized row cannot bypass those checks. A checked programmatic builder may be added using the same schema; arbitrary mutable maps are not accepted as runtime grants.

## 3. Semantic coverage and conservative admission matching

### 3.1 Two relations, not one

Let `Ops(P)` be the set of valid concrete operations denoted by policy P, ignoring the `optional` admission flag and evaluating live validity separately.

```text
Semantic coverage:
    A >= B  iff  Ops(B) ⊆ Ops(A)

Semantic equivalence:
    A = B   iff  Ops(A) = Ops(B)
```

These notations do not redefine Gene's ordinary comparison or structural equality.

Mandatory admission uses a narrower, implementable procedure:

```text
match_entry(grant, request):
    one grant entry establishes the identity, whole-body,
    and every property comparison for that request entry

match_row(grants, request):
    succeed if one valid grant entry matches the complete request;
    otherwise obtain the provider's exact finite request alternatives,
    and require a complete valid grant match for every alternative

The covering grant may differ between alternatives, but each alternative
retains all of its constraints. Repeat the proof within every applicable
authority row; grants from different ceilings cannot be pooled.
```

A successful match must imply semantic coverage. A failed match does not necessarily prove semantic noncoverage: unsupported decompositions, cross-field implications, or bounded proof limitations can prevent a match even when the operation sets are included. Grouping finite alternatives supported by the provider is not itself a reason to reject the request.

The core exposes admission results as `matched`, `unmatched`, or `cannot_prove`. `unmatched` means the supported matching procedure found no complete grant match for a necessary alternative; it is not automatically a proof of semantic noncoverage. Unsupported decomposition or an exhausted proof budget produces `cannot_prove`. The report identifies the authored request, relevant alternative, and authority row. Generic field comparators may internally use `covered`, `not_covered`, and `cannot_prove` for their own field domains.

### 3.2 Required comparison examples

```text
fs/Read = (fs/Read) = (fs/Read *)

(fs/Read *)
  >= (fs/Read "/home/user" "/tmp")
  >= (fs/Read "/tmp")

fs/* >= fs/Read
(fs/* "/tmp") >= (fs/Read "/tmp")

net/Http = (net/Http) = (net/Http *)

(net/Http *)
  >= (net/Http "http://localhost*")
  >= (net/Http "http://localhost:8080/status")
  >= (net/Http "http://localhost:8080/status" ^methods ["GET"])

(cap/x 5) >= (cap/x 4)             # Numeric body declared as an upper limit.
(cap/x "a" "b") >= (cap/x "a")     # Body declared as resource alternatives.
(cap/x "a*d") >= (cap/x "abcd")    # Full-string pattern semantics.
```

Namespace examples assume an admitted provider and a compatible schema. Filesystem examples use directory-tree roots. `localhost*` illustrates textual matching, not local-only network access. `cap/x` is the schematic provider described in the header.

### 3.3 Matching an entire requested entry

After validated, semantics-preserving provider normalization:

```text
identity:  grant capability equals or explicitly implies requested capability
body:      grant's complete body covers request's complete body
property:  for every provider field, grant's constraint covers request's constraint
```

Core admission metadata such as `optional` does not enter these comparisons.

Each `match_entry` compares the body as one unit. Row admission may first decompose provider-defined alternatives under section 3.4. The core must not guess that arbitrary body arguments are alternatives, compare structured bodies position by position, or assemble one alternative's properties from different grant entries.

For alternative bodies:

```gene
(fs/Read "/home/user" "/tmp")
```

denotes read operations under either root. It is not an operation requiring both roots on every call. A grant entry with both alternatives can match a requested entry containing either or both. Different provider-defined structured bodies retain their declared meaning.

After normalization, an unrestricted request field does not match a grant that restricts that field. HTTP normalization may refine omitted component fields using facts logically implied by a concrete URL body; section 12 explains why this does not change the policy's meaning. Normalization must retain the original body and correlations.

Composition of comparison results must be precise: any definite failed field makes that candidate a nonmatch, even if another field is unproved. A candidate is `cannot_prove` only when no field is definitely failed and at least one necessary comparison is unproved. A later complete matching entry succeeds regardless of an earlier inconclusive candidate.

For collective admission, apply that candidate search to each complete alternative. The row matches only when every alternative matches. An unmatched alternative prevents admission even if another alternative is inconclusive; otherwise any unresolved alternative makes the row `cannot_prove`.

### 3.4 Collective coverage of requested alternatives

```gene
# Grants:
[(fs/Read "/home/user") (fs/Read "/tmp")]

# One mandatory requested entry:
[(fs/Read "/home/user" "/tmp")]
```

This mandatory request succeeds. The filesystem provider defines the roots as alternatives, so every requested read is covered by one of the two grants. Admission must not depend on whether those roots were authored in one request entry or in two entries with the same remaining constraints and admission flag.

The provider can prove the request by decomposing it into:

```gene
[(fs/Read "/home/user") (fs/Read "/tmp")]
```

More generally, a provider may supply a finite decomposition into complete entries:

```text
alternatives(R) = [R1, ..., Rn]
with Ops(R) = Ops(R1) ∪ ... ∪ Ops(Rn)

For each applicable grant row G:
    for every Ri, some valid g in G must satisfy match_entry(g, Ri)
```

This is a coverage proof over the existing grant row. It does not merge grants or create a new live grant. Their provenance, revocation, and origin restrictions remain independent, and concrete-operation guards still check complete entries at the point of use.

The provider defines which body and property forms are alternatives. Filesystem roots and HTTP allowed-method lists support this decomposition. When several independent fields contain alternatives, the proof must cover every permitted combination. Each derived entry retains all other constraints, including the original body restrictions needed to preserve correlations. The proof representation may remain symbolic rather than materialize every combination.

For example, grants for GET on A and POST on B do not admit a request for both GET and POST on either host: POST on A and GET on B remain uncovered. Splitting alternatives never lets one grant supply the host while another supplies the method for the same operation.

Structured bodies and indivisible compound operations are not split merely because they have several arguments. Numeric limits are not added, and no new capability implication is inferred. A provider keeps an indivisible entry as its only alternative. More general union-containment proofs, such as partitioning an arbitrary wildcard language across grants, are not required in version 1. When a needed alternative decomposition is unsupported or exceeds its budget, the result is `cannot_prove`, never permission.

If `/tmp` is missing from the example's grants, the mandatory request fails with a diagnostic identifying the `/tmp` alternative. An upper-bound block or optional request still selects the exact available intersection, as in section 7; neither requires full mandatory admission.

### 3.5 Properties constrain the whole body

```gene
(net/Http
  "https://api.example.com/*"
  "https://backup.example.com/*"
  ^methods ["GET"])
```

means:

```text
(URL matches either body alternative)
AND (method is GET)
```

Omitted methods are unrestricted within the provider's supported operation domain; they do not secretly default to GET.

### 3.6 Keep cross-field correlations

```gene
[
  (net/Http "https://a.example/*" ^methods ["GET"])
  (net/Http "https://b.example/*" ^methods ["POST"])
]
```

must never become one entry containing both hosts and both methods. That would additionally permit POST to A and GET from B. The runtime checks one entire entry at a time and preserves that grouping. Collective request admission proves coverage of alternatives against these intact entries; it does not combine their independent fields.

A provider may define a concrete compound operation with several facts or resources. Its guard must check that declared operation shape; it must not split an indivisible operation merely to evade the single-entry rule. Exact compound-operation vocabularies belong to the provider contract.

## 4. Provider-defined constraint kinds

### 4.1 Value types do not determine permission ordering

The parser identifies a value as an integer, boolean, or string. The provider schema determines how that value constrains operations.

| Constraint kind | Coverage rule |
| --- | --- |
| Unrestricted | `*` covers every valid value in the field's domain. |
| Exact value | Covers the same normalized value. |
| String pattern | Covers concrete strings or narrower patterns whose entire match language is included. |
| Allowed alternatives | Covers a request when every requested alternative is covered by the grant's union. |
| Maximum integer | A greater maximum covers a smaller maximum. |
| Minimum integer | A smaller minimum covers a greater minimum. |
| Boolean choice | Exact matching by default; `*` admits both valid choices. |

These are reusable normalization and comparison components, not mandatory public Gene types or extra literal operators. A capability definition chooses the appropriate components or supplies specialized whole-body and field implementations. Those hooks and any admission decomposition must preserve complete-entry constraints and concrete guard rules; they do not replace the authority engine.

The schema also defines units, valid integer range, and meaningful combinations. An integer literal is accepted by the reader without implying that every provider accepts negative numbers or an arbitrarily large value.

### 4.2 Upper limits versus identifiers

For an upper-limit capability:

```text
(cap/x 5) >= (cap/x 4)
```

is correct. A per-operation maximum of five covers a per-operation maximum of four.

For a port selection:

```gene
(net/Http * ^ports [8081])
```

does not cover:

```gene
(net/Http * ^ports [8080])
```

Ports are exact identifiers in this proposed HTTP schema. No numeric greater-than comparison is appropriate.

A field representing a minimum follows the opposite ordering. These distinctions must be declared, not guessed from field names such as `limit`, `size`, or `port`.

### 4.3 Booleans

Do not globally define `true >= false`.

A mode flag can identify two different operation classes, in which case only equality supplies coverage. A provider may explicitly define an enable-permission flag with a different ordering, but that ordering belongs to its schema.

A present operation attribute is checked as its actual boolean value. Missing operation data must not be treated as unrestricted permission.

### 4.4 Lists

A list-valued property can represent allowed alternatives, as in methods, hosts, or ports. For such a field, duplicates and ordering do not change coverage; an empty list has empty coverage.

That does not give every provider permission to reorder every body or property list. A provider defining a structured or ordered list must retain its own semantics. Unsupported list meanings are rejected rather than handled by a generic subset shortcut.

### 4.5 Per-operation limits versus consumable budgets

These are different contracts:

```text
Each operation may consume at most 5 units.
All operations together may consume at most 5 units.
```

The first is a predicate on a concrete operation. The second requires shared, stateful accounting and atomic reservation or consumption.

Version 1 normalization focuses on operation predicates. Stateful quotas can use this format later, but copying or narrowing a context must not reset counters or multiply a budget. Two maximum-five grants do not automatically create a maximum-ten grant, and two references to one quota are not two independent quotas.

Budget accounting is not introduced merely because an integer occurs in a literal.

## 5. Namespace selectors and capability implications

### 5.1 Namespace selection

`fs/*` selects the host-admitted capability identities beneath the `fs/` namespace. `(fs/* "/tmp")` applies the same body and properties to every selected provider definition.

Conceptually, if the catalog contains the relevant providers:

```gene
(fs/* "/tmp")
```

can expand to normalized entries corresponding to:

```gene
[
  (fs/Read "/tmp")
  (fs/Write "/tmp")
  (fs/ReadWrite "/tmp")
]
```

The actual expansion is determined by the admitted catalog, not by this illustrative list.

Namespace selection follows identifier boundaries. `fs/*` is not a prefix match for unrelated names such as `fsx/Read`. For this version, use terminal namespace `/*`, not arbitrary wildcard patterns throughout capability names.

A capability name and a namespace selector are distinct:

```text
net/Http       the Http capability in the net namespace
net/*          every admitted capability in the net namespace
```

A capability name is not a namespace, so `net/Http/*` is not a valid selector. An alias or named group must be explicitly registered to provide another meaning.

### 5.2 Expansion must preserve restrictions

Every selected provider must validate the body and properties. If one selected capability does not accept `"/tmp"`, reject the constrained namespace specification.

Do not silently omit the incompatible provider, ignore the incompatible argument, or reinterpret the constrained wildcard as an unrestricted grant.

Resolve wildcard expansion against a fixed admitted catalog version. A new provider admitted later must not silently enlarge an already-established grant. Existing normalized contexts retain their resolved identities and semantics; any adoption of a new catalog is an explicit host policy action.

### 5.3 Explicit implications

A composite capability may imply others:

```text
fs/ReadWrite >= fs/Read
fs/ReadWrite >= fs/Write
```

The implication must be a trusted, constraint-preserving definition. For example, a read/write grant under `/tmp` must not imply read authority under every path.

Do not infer implications from a type's name, capitalization, nominal inheritance, or a plugin-defined implementation. Whether write authority includes deletion, rename, directory creation, or metadata mutation belongs to the provider's documented operation model.

The normalizer and coverage checker must account for these implications when comparing otherwise different capability identities. An implication satisfies only the identity check; the translated body and every property are still compared as in section 3.3. An implication between unlike schemas must include a trusted, sound constraint mapping; matching field names is not sufficient.


### 5.4 Optional selection and empty expansion

In a request, `(fs/* ^^optional)` propagates optional admission metadata to each selected concrete entry, but still validates every provider specification. The metadata is not a provider property.

An unknown namespace or a selector matching no admitted capability is rejected in version 1, including an optional selector. This catches unavailable vocabulary and misspellings rather than silently interpreting them as zero authority. A known capability with no current grant is the supported optional-availability case.

## 6. Normalization, policy representation, and live grants

### 6.1 Processing phases

```text
Read one inert row
→ validate syntax and context-appropriate core metadata
→ resolve trusted identities and namespace selectors
→ validate every complete provider specification
→ normalize body and property constraints
→ retain entry grouping and source provenance
→ perform admission matching and/or form an exact intersection
→ initialize permitted trusted-provider state where necessary
```

Parsing and symbolic normalization do not execute application code. Resource initialization is separate and occurs only after the host has established the relevant authority.

Retain source location, authored grouping, base-directory identity, catalog/provider version, and admission metadata. Diagnostics must be able to explain which declaration or host source introduced a restriction.

### 6.2 Safe transformations

Safe local transformations include shorthand expansion and provider-defined canonicalization, deduplication of alternatives with set semantics, and addition of constraints proved to be logically implied by the same entry's original constraints.

In particular, adding a host projection derived from a concrete URL is safe only while the original URL constraint remains. With several URLs, retaining both the body and its component projections prevents creating new host/path combinations.

Do not merge grant entries. Exact request decomposition for admission is permitted under section 3.4 while retaining the authored request and its metadata. Do not sort structured bodies, reinterpret arbitrary strings as numbers, discard unknown fields, or approximate an inconvenient intersection with a broader policy.

Do not prune a mandatory request because an optional entry semantically contains it: the mandatory admission obligation must remain. Request identity and failure-reporting information must survive normalization.

Cross-entry redundancy elimination is not needed in version 1. Any future symbolic pruning must preserve both operation meaning and the conservative admission behavior, not only set inclusion.

### 6.3 Policies and request metadata

Conceptually:

```text
Policy = Row(Entry...)                # OR across complete entries
       | Intersection(Policy...)     # AND across independent ceilings

Entry = (provider identity/version, normalized body, normalized properties)

RequestedEntry = (Entry, optional: Bool, source_location)
RequestedRow   = RequestedEntry[]
```

`optional` is deliberately not a field of the operation policy. Stripping it obtains a constraint but does not establish that it was admitted.

The empty row has empty coverage. An omitted boundary declaration is represented separately; it means no additional selector at that boundary, not `Row()`.

Exact intersection may remain `Intersection(A, B)`. There is no requirement that every intersection can be printed as a single entry or simple literal. Authorization checks each operand. Mandatory admission proves each requested entry's coverage independently within each authority operand. Different grants in one row may cover different complete request alternatives; grants from separate operands cannot be pooled.

### 6.4 Preserve independent grant provenance

A symbolic entry is not a live grant. A live grant additionally has host provenance, lifetime/validity, revocation dependencies, and possibly provider-owned resource state.

Suppose two independently revocable grants permit:

```text
A: reads under /
B: reads under /tmp
```

Do not delete B merely because A currently covers it. If A is revoked, B must continue to authorize its own operations. Sharing compiled symbolic matchers is safe; merging independent grant validity is not.

A retained resource must preserve its actual origin restrictions and relevant authorizing context, not accidentally become dependent only on whichever overlapping entry was searched first. Where multiple grant alternatives remain valid for the resource, their validity remains represented. Entry-order changes must not alter permission merely by choosing a different short-circuit winner.

New host grants do not silently appear in existing immutable contexts. Live revocation can invalidate referenced grants; adding or adopting authority requires an explicit trusted-host context operation. Source-file or environment changes alone do neither.

### 6.5 Cache symbolic work, not irrevocable permission

Normalization and field-containment proofs may be cached by content and provider/catalog version. A proof is not a live grant, and a successful operation check is not a durable authorization ticket.

Runtime decisions must still account for current context, grant validity, resource origin, and actual operation facts. If decision caching is used, those dependencies must be validated at every effect boundary. Keeping the pure matcher fast is preferable to caching a context-free boolean that can become stale.

## 7. Application requests, optional capabilities, and block bounds

### 7.1 Two source-level boundary operations

This proposal assigns the existing-style `with_capabilities` form to **upper-bound attenuation** and introduces a separate **required-entry** form:

```gene
(with_capabilities [ ... ]
  body...)

(require_capabilities [ ... ]
  body...)
```

The bodies retain ordinary lexical control flow. They are not automatically wrapped in lambdas, and the forms do not implicitly spawn, await, drain streams, retry work, or catch the body's failures.

Module and callable `^capabilities` declarations use the request semantics below. These are explicit target decisions, not assumptions about the current compiler.

### 7.2 Mandatory and optional requests

Partition a requested row into mandatory entries M and optional entries O. Let `constraints(R)` be the row obtained by stripping admission flags from every entry in R.

At request-boundary entry:

```text
A = current authority intersect all already-applicable ceilings

Require:
    every mandatory entry in M admission-matches A

If it does:
    effective = A intersect constraints(M + O)
```

All specs are validated before deciding admission. If any mandatory entry has no full match or cannot be proved, do not execute the boundary's body. If admission succeeds, unrequested authority is not retained simply because the caller had it.

An explicit empty request row enters with no external authority. An absent declaration inherits the available authority subject to its other ceilings. These cases must stay distinct in compiler metadata.

For a normal mandatory example:

```gene
(fn fetch_status []
  ^capabilities [
    (net/Http "https://api.example.com/status" ^methods ["GET"])
  ]
  (fetch_status_impl))
```

The full declared request is checked on invocation before callee-owned defaults or body effects. The helper name is illustrative; actual transport guards remain mandatory.

A mandatory bare `[net/Http]` means a request for the full unrestricted HTTP policy, not merely "some HTTP permission exists." A program needing to know whether a specific URL/method is available should use an operation check; a boundary selecting whatever HTTP is available should use an optional request or pure attenuation.

### 7.3 Optional means available overlap, not all-or-nothing acquisition

```gene
(fn status_or_cached []
  ^capabilities [(net/Http ^^optional)]
  ...)
```

This function may enter without any HTTP authority. If the caller has restricted HTTP authority, the function receives only that restricted overlap. It does not require unrestricted HTTP merely because its optional entry has an unrestricted body.

For example:

```gene
# Current authority:
[(net/Http ^hosts ["api.example.com"] ^methods ["GET"])]

# Function request:
[(net/Http ^^optional)]
```

The effective HTTP permission is still exactly the host/method restriction in the available context. A GET to that host may pass; a POST or another host remains denied.

**Do not drop an optional entry just because its whole requested policy cannot be admission-matched.** Retain its exact intersection with available authority. This is necessary for optional broad capability families to work with least-privilege grants.

```gene
# Current authority permits GET only.
# This optional request keeps GET, not POST:
(net/Http ^hosts ["api.example.com"] ^methods ["GET" "POST"] ^^optional)
```

Optionality does not suppress malformed literals, unknown identities, schema errors, execution limits, provider initialization errors, or errors raised while doing real work. It only removes that entry's full-admission precondition. A provider outage is not a missing permission, and neither is proof of permission a promise of resource availability.

`^optional false` restores the mandatory-entry obligation. Namespace expansion preserves the flag on each expanded requested entry and still validates every selected provider.

### 7.4 Optional checks and reporting

Optional requests do not trigger an implicit prompt or invent a new grant. Code uses the programmatic concrete-operation check to choose a fallback:

```text
construct/prepare the intended request without sending it
→ check that concrete request
→ choose HTTP execution or a local fallback
```

The actual send guards again.

A requirement report distinguishes whether each optional entry fully matched from whether it was simply admitted as an upper bound. Do not label a partially matched optional family as either universally granted or universally unavailable. The implementation may report:

```text
required: matched | unmatched | cannot_prove
optional: full_match | no_full_match | proof_incomplete
```

These are admission facts, not necessarily proofs that the resulting intersection is nonempty or empty. Unless an exact emptiness analysis was performed, concrete-operation checks answer what can actually be done.

An all-optional row can be admissible while permitting no operations. A function with fallback code must not make the same capability a mandatory entry and then expect to handle its absence inside the body.

### 7.5 Worked mandatory reconciliation

```gene
# Host grants:
[
  (fs/Read "/tmp")
  (net/Http "http://localhost:8080/*" ^methods ["GET"])
]

# Requested row:
[
  (fs/Read "/tmp" "/home/user")
  (net/Http "http://localhost:8080/status" ^methods ["GET" "POST"])
]
```

Mandatory admission fails: the single read grant does not cover `/home/user`, and the HTTP grant does not cover POST. A diagnostic identifies those failed fields; it distinguishes a proven missing value from an unproved comparison.

The exact attenuation result remains meaningful:

```gene
[
  (fs/Read "/tmp")
  (net/Http "http://localhost:8080/status" ^methods ["GET"])
]
```

A mandatory request does not silently use this smaller policy. A `with_capabilities` upper-bound block does. Making both request entries optional also permits entry under that intersection, but does not authorize operations outside it.

### 7.6 Block-level grant as an upper bound

```gene
(with_capabilities [
  (fs/Read "/home/user/project")
  (net/Http ^hosts ["api.example.com"] ^methods ["GET"])
]
  (untrusted_callback input))
```

Semantics:

```text
A = caller's effective authority at entry
U = requested upper bound, with no optional metadata

block authority = A intersect U
```

There is no obligation to prove that A covers all of U. If A has no HTTP authority, the block still enters without HTTP. If A permits reading only a subdirectory of the requested tree, only that subdirectory remains accessible.

All unrelated authority is excluded. A block that selects HTTP but no filesystem capability does not inherit the caller's file access.

```gene
(with_capabilities []
  (untrusted_callback input))
```

runs with no external-operation capabilities. It does not remove the supplied input's in-memory mutability or make native code harmless; see section 14.

### 7.7 Nested blocks cannot recover broader authority

```gene
(with_capabilities [(fs/Read "/tmp")]
  (with_capabilities [(fs/ReadWrite *)]
    (untrusted_callback input)))
```

The inner policy is intersected with the outer read-only restriction. It cannot add writing or access outside the outer tree, regardless of how broad the application root grant was.

Restoring the caller's context after exit is a runtime-managed operation, not a capability available to the block. A callee's own `^capabilities` declaration, imported implementation, or saved context cannot replace the active restriction with an older root.

`optional` is rejected in a pure upper-bound row rather than silently ignored. Write a plain bound for attenuation or `require_capabilities` when admission requirements are intended.

### 7.8 Required blocks

```gene
(require_capabilities [
  (fs/Read "/tmp")
  (net/Http ^hosts ["api.example.com"] ^methods ["GET"] ^^optional)
]
  (perform_work))
```

The read entry must fully match available authority before body execution. HTTP contributes its available intersection, possibly none. The body receives only the selected read/HTTP constraints, not every other caller permission.

This form is useful when failure must happen before starting a multi-step operation. It does not reserve resource access for the entire operation: guards still check live validity when effects occur, and later revocation can cause failure.

### 7.9 Modules, functions, messages, and constructors

| Boundary | Admission point | Effective authority |
| --- | --- | --- |
| Application manifest request, when provided | Before application-controlled initialization | Host authority ∩ request constraints. |
| Module `^capabilities` | Before that module's initialization | Current authority ∩ module selection and admitted origin ceilings. |
| Function/message/constructor `^capabilities` | At each invocation, before callee-owned defaults and body | Current authority ∩ applicable module/retained ceilings ∩ request constraints. |
| `require_capabilities` block | Before its first body form | Current authority ∩ requested constraints. |
| `with_capabilities` block | Before its first body form; no mandatory-coverage assertion | Current authority ∩ upper-bound row. |

Proposed module example:

```gene
(mod reporting
  ^capabilities [
    (fs/Read "/home/user/project")
    (net/Http ^^optional)
  ])
```

A module declaration establishes the module's admitted ceiling and an initialization requirement. Subsequent entries into module-defined code intersect that retained ceiling with the actual caller; they do not restore initialization authority. A mandatory condition that must be checked on every callable entry belongs on that callable. Merely retrieving an already-initialized module does not rerun initialization or grant its importer additional authority.

Unannotated helpers still execute under the current narrowed context. Their omission does not opt out of the module, block, task, or retained ceilings.

An explicit row selects its union of mandatory and optional constraints as a maximum. Two entries with the same provider but different flags do not cancel one another's obligations; a mandatory narrow entry remains mandatory even beside an optional broad entry.

### 7.10 Declaration contracts versus actual use

Entry admission is an early check and restriction, not static proof that the function never attempts another operation. Attempting an operation outside the effective selection fails at its real guard.

Caller-owned evaluation of the callee expression and explicit arguments retains the normal Gene call schedule. Callee-owned defaults and body execution occur after the callee boundary is installed. To bound an untrusted argument expression or factory too, put the complete call expression inside the block rather than computing that expression before the block.

Authority restoration must survive `return`, `break`, `continue`, errors, panic, cancellation, task suspension, and tail-call paths. Section 14 gives the execution and escape contract.

## 8. Strings and wildcard containment

### 8.1 Concrete matching

Version 1 string patterns use one wildcard:

```text
* matches zero or more characters.
Matching covers the complete string.
There is no implicit substring match.
```

The generic string matcher gives `*` no special directory-separator boundary. Provider-level path and URL semantics remain additional constraints.

```text
Pattern "a*d" matches:
    "ad"
    "abcd"
    "a/long/path/d"

Pattern "abcd" does not match:
    "xabcdy"
```

No regular-expression syntax, `?` wildcard, or character-class syntax is implied.

Provide a glob-layer escape for a literal asterisk. With ordinary Gene string escaping applied first:

```gene
(cap/x "a\\*d")
```

has a pattern-layer escaped asterisk and matches the literal resource string `a*d`. The parser, printer, and provider tests must agree on the two escaping layers.

A concrete operation's filename or other string is not parsed as a pattern. A real filename containing `*` does not acquire wildcard meaning during authorization.

### 8.2 Coverage is not pattern-against-text matching

These are separate questions:

```text
matches(grant_pattern, concrete_string)

covers(grant_pattern, requested_pattern)
```

The second asks whether every string accepted by the requested pattern is accepted by the granted pattern. Running the grant's matcher on the requested pattern's source text is not a sound containment test.

The provider must compare pattern languages or use a sound equivalent proof for its supported subset. A bounded comparison may return `cannot_prove` rather than consume unbounded work.

Suggested field-comparison proof outcomes (whole-entry admission uses section 3):

```text
covered
not_covered, with a counterexample or explanation when available
cannot_prove, with the unsupported case or comparison limit
```

Mandatory reconciliation treats `cannot_prove` as failure to establish the requirement, not as permission. It should not misreport that result as a demonstrated concrete denial.

An exact runtime intersection can retain both predicates even when simplifying or proving their relationship is difficult. Failure to simplify must never produce a broader grant.

## 9. Configuration sources

### 9.1 Command line

`--capabilities` takes a row as one argument. `--cap` is an alias:

```sh
gene run \
  --capabilities '[(fs/ReadWrite "/home/user/project" "/tmp") (net/Http "http://localhost:8080/*" ^methods ["GET"])]' \
  app.gene

gene run --cap '[(fs/Read "/tmp")]' app.gene
```

The shell passes one argument containing a row. Shell quoting protects the row from unintended word splitting and wildcard expansion; the capability reader receives the resulting text and does not run another shell.

### 9.2 Capability file

`--capabilities-file` takes the path of a file containing exactly one row. `--cap-file` is an alias:

```sh
gene run --capabilities-file caps.gene app.gene
gene run --cap-file caps.gene app.gene
```

Where `caps.gene` contains:

```gene
[
  (fs/ReadWrite "/home/user/project")
  (net/Http "https://api.example.com/*" ^methods ["GET" "POST"])
]
```

The file uses the same reader and semantics as `--capabilities`. A missing, unreadable, or invalid file is an error. Relative paths in the file resolve against the file's directory, so a capability file means the same thing wherever `gene` is launched.

At most one command-line capability source may be given. Supplying more than one of `--capabilities`, `--cap`, `--capabilities-file`, and `--cap-file`, or repeating one, is an error, not a union or a last-one-wins override.

A broader host configuration may instead designate a `capabilities` field containing the same row. File discovery and its wrapper format are launcher concerns, not another capability grammar.

### 9.3 Environment variable

A suggested variable name is `GENE_CAPABILITIES`:

```sh
export GENE_CAPABILITIES='[(fs/Read "/tmp") (net/Http "http://localhost:8080/*" ^methods ["GET"])]'
gene run app.gene
```

This name is a proposed convention. Its contents use exactly the same parser and semantics as the CLI and file forms. Do not add environment-only string substitutions, implicit separators, or a second wildcard language.

### 9.4 Source precedence

The launcher selects exactly one policy source. Sources replace each other; they are never unioned:

```text
Command-line policy (--capabilities, --cap, --capabilities-file, --cap-file)
    overrides GENE_CAPABILITIES
    overrides host configuration-file defaults
    overrides the built-in launcher default
```

The selected source replaces every lower source entirely, including the built-in default grants. When `--capabilities` is present, the program receives exactly the row it names and nothing from the built-in default. The built-in default applies only when no source is present.

An independent administrator or embedding ceiling always intersects the selected policy. A stale environment value must not widen an explicit restrictive command-line row.

An explicit `[]` is a valid selected policy and grants nothing. An invalid selected source is an error; it must not fall back silently to a lower-precedence source.

### 9.5 Source trust

CLI, environment, and files are transports, not intrinsic trust levels.

A trusted launcher may interpret its selected input as grant configuration. A file supplied by the application or a generated plugin is a request unless the host explicitly admitted it as grant policy.

Read startup configuration before application initialization, then establish the root context. Later edits to a file or environment variable do not mutate active authority. Dynamic grant changes, if supported separately, require an explicit host operation.

Relative resource strings use a normalization base captured at startup: the launch working directory for `--capabilities`, `--cap`, and `GENE_CAPABILITIES`, and the file's directory for a capability file. The base is not a permission grant, and changing the process working directory later must not change an established policy.


### 9.6 Host grants do not carry optional request metadata

A selected startup grant row and an administrator ceiling reject `^optional`/`^^optional`, including explicit false. Optionality belongs to code requests, not to whether the host means to enforce a grant. The same reader preserves the flag; validation of the receiving operation decides whether it is legal.

The selected host policy is intersected with independent administrator/embedding ceilings; it is not a promise that an application's later mandatory request will be satisfied. Initialize only the admitted effective authority. If a ceiling reduces the selected grant configuration, make that fact available to the host's diagnostics without silently widening either policy.

These startup inputs are read before application initialization. Reading a host-approved capability file is launcher control-plane work; it does not give the application's code general permission to reread that file or use the loader's handles.

## 10. Trusted providers, programmatic checks, and operation guards

### 10.1 The provider is the semantic authority

A trusted capability provider owns the interpretation of its configuration and the authorization logic for one operation family. Its definition supplies:

```text
schema and supported operation vocabulary
normalization of complete specs
whole-body and property containment comparisons
exact finite request decomposition for declared alternative forms
exact intersection or executable intersection predicates
trusted resource initialization, where required
operation-fact validation and family-specific authorization
```

Only the host admits definitions to the catalog. A source-level symbol, ordinary type declaration, or scoped `impl` named `net/Http` cannot replace the registered HTTP authorization function. A provider may be implemented internally in Gene; that does not make admission or root-grant creation available to application code.

Keep domain logic in its own functions and tests. The capability engine should not parse HTTP URLs, guess filesystem containment, or assign numeric order to ports. It invokes the admitted provider.

### 10.2 Division of responsibilities

| Component | Owns | Must not do |
| --- | --- | --- |
| Restricted reader | Literal shape, core flags, duplicate detection, source information | Evaluate capability heads, interpolate data, or acquire authority. |
| Capability engine | Catalog identity, rows/intersections, entry admission, current-context lookup, boundary restoration, provenance handling | Combine different entries' fields or substitute a saved root for a narrower caller. |
| Family-specific provider | Body/property meaning, comparisons, exact request alternatives, real-operation matching, provider state validity | Treat unknown fields as unrestricted, split indivisible operations, or use a different meaning for static matching and runtime guards. |
| Trusted effect adapter | Prepare the actual request/resource, invoke mandatory guard, bind it to the effect, clean up | Trust a caller-supplied hostname in place of the URL it will send to, or expose an unguarded effect path. |
| Application/plugin | Request and narrow authority; check and choose fallback | Forge operation admission tickets, provider identity, host grants, or another plugin's execution context. |

### 10.3 Conceptual provider interface

The following are semantic operations, not required public Gene protocol names:

```text
normalize(spec_entry, source_context) -> NormalizedEntry

covers_body(granted_body, requested_body) -> FieldCoverage
covers_property(name, granted_constraint, requested_constraint) -> FieldCoverage
    FieldCoverage = covered | not_covered | cannot_prove

admission_alternatives(normalized_request, proof_budget)
    -> exact finite alternatives (possibly symbolic) | cannot_prove
    their union must equal the original request's operation set;
    each alternative is a complete entry, not a partial set of fields

intersect_constraints(left, right) -> exact constraint | empty
    retaining both predicates is a valid exact representation

initialize(granted_policy, trusted_host_authority) -> RuntimeGrantState

validate_operation_facts(facts) -> ConcreteOperation | invalid_operation

authorize_entry(runtime_grant_state, normalized_entry, concrete_operation)
    -> allow | deny(reason) | provider_failure(cause)
```

The engine composes field-comparison results using section 3 and evaluates independent authority boundaries. It first tries whole-entry matching, then uses provider-defined alternatives for collective admission. `authorize_entry` checks an entire operation against an entire entry, including every supported restriction and relevant live provider state. Admission decomposition does not alter this operation guard.

For providers needing resolution-time enforcement, a guard/prepare operation may produce an internal, short-lived resource resolution that the adapter immediately uses. That value is not a public transferable permission ticket and must not be usable with a different operation. Pure comparisons alone are not enough to guard a filesystem open safely.

Normalization and comparison functions should be deterministic over validated inputs. Provider initialization and real resource operations are separately effectful. A checker must not invoke application callbacks as part of deciding permission.

### 10.4 Three public concepts: parse, requirement check, operation check

Recommended public semantic interfaces:

```text
parse(text, explicit_source_context) -> immutable CapabilitySpecRow

check_requirements(request_row) -> RequirementReport
    queries the current context; does not enter or narrow a block
    preserves mandatory versus optional admission results

check_operation(operation_description) -> CapabilityDecision
    queries one concrete operation; does not perform it
```

Suggested Gene spellings are `$capabilities/parse`, `$capabilities/check_requirements`, and `$capabilities/check_operation`. Final exported names should be selected once and used everywhere; these operations must remain semantically distinguishable even if a convenience façade shares a namespace.

`RequirementReport` includes `admitted` for mandatory entries and per-entry match status. Optional entries do not make `admitted` false merely because they lack a full match. A report must not claim that every optional operation is permitted.

`CapabilityDecision` includes at least `allowed` plus a stable reason category and safe operation/boundary summary. Reports and decisions are inert, read-only values. They contain no root grants, credentials, mutable context handles, or mechanism to suppress later guards.

A programmatic operation description may be constructed by ordinary code, using real strings and values. It can only ask a question. It must be validated, and the effect adapter independently derives the authoritative description from its prepared operation. Forging a favorable advisory description cannot authorize a different effect.

### 10.5 Check and guard share one authorization path

```text
authorize_current(operation):
    validate concrete facts and provider identity
    obtain current effective authority and applicable resource-origin restrictions
    for every independent authority boundary:
        require one valid complete entry that allows this operation
    return a structured decision

check_operation(operation):
    return authorize_current(operation)

guard_operation(operation):
    decision = authorize_current(operation)
    if decision is not allow:
        raise the corresponding typed denial or provider failure
    return normally
```

The public check can return `allowed = false` with a reason for denial or provider evaluation failure; it must preserve the distinction in the report. Invalid operation shapes are reported as invalid input, not silently treated as a normal lack of permission. Cancellation and panic are not converted into ordinary availability results.

The guard is used at the trusted effect boundary. If exposed for diagnostics, a user-callable guard still cannot authorize a later unguarded primitive; the real operation guards itself.

Under identical operation facts, context, resource origin, provider state, and grant-validity state, check and guard make the same decision. Their difference is control flow: a check lets the program choose, while a guard prevents the effect on denial.

### 10.6 A successful check is not a reservation

```text
check request → permitted
context narrows or grant is revoked
execute request → guard denies
```

This is correct. Checks may be followed by time, scheduling, redirects, resource changes, or code that changes the operation. The actual effect must guard again.

Do not cache a global `has_http` boolean as permission for arbitrary requests. A narrow grant can permit one hostname and method while denying others. Optional capabilities are especially likely to be partially available; check the action the application intends to perform.

Version 1 checks do not consume quota, perform HTTP traffic, prompt a human, write files, or acquire a new grant. Provider-level filesystem checks may require trusted metadata resolution to return a meaningful advisory result; that limited inspection must have a specified policy and must not perform the requested data effect. The guard remains authoritative at resolution/use time.

### 10.7 Example with an optional HTTP request

Conceptual client API, proposed for illustration:

```gene
(fn status_or_cached []
  ^capabilities [(net/Http ^^optional)]
  (let request
    ($net/http_client/prepare "GET" "https://api.example.com/status"))
  (let decision
    ($capabilities/check_operation
      ($net/http_client/describe_operation request)))
  (if decision/allowed
    (await ($net/http_client/send request))
    "offline"))
```

`prepare` and `describe_operation` here are proposed pure preparation/inspection operations. They must not connect or send. `send` revalidates the immutable prepared request, constructs trusted facts, guards, and then executes. The example illustrates boundary behavior, not existing library signatures.

If a host grants only GET for `api.example.com`, this function may use that request. If it grants no HTTP, the function enters and returns its fallback. A later network error is not converted into the fallback automatically, and later revocation can still make `send` fail.

A generic HTTP library must not install a mandatory unrestricted `[net/Http]` request on every client function or its module merely because it performs HTTP. That precondition would reject narrowly granted callers before the concrete guard is reached. The generic adapter should inherit the current constrained context, or select HTTP through an optional row/upper bound, and enforce the actual prepared request. Fixed-purpose APIs may declare narrower mandatory requirements when they genuinely need that complete policy.

### 10.8 Guard every sanctioned path, not just a convenient wrapper

Inventory each provider's entry points: high-level calls, lower-level supported operations, retained handles, async start/resume, redirect/retry handling, native adapters, and optimized code paths. Each real external effect must pass the same semantic enforcement boundary.

Keep unchecked transport functions private to trusted implementation code. A plugin must not be able to import a lower-level public function that bypasses the guard.

Checks must occur before the effect they protect: no request bytes sent before HTTP admission, no data opened or changed before the filesystem's constrained-resolution guard. If an implementation phase itself has a separately modeled effect, it needs its own authorization; permission for one operation is not blanket permission for unrelated setup work.

For a stream of external operations, guarding creation of the stream is not sufficient. Later reads, writes, sends, redirects, or resource reuse follow their provider's guarded operation contract. Cleanup-only release has a narrow special contract in section 14, not general effect permission.

### 10.9 Initialization and failure

Only the trusted host creates root runtime authority. Child contexts normally retain references to already-issued grants plus additional predicates rather than mint independent grants.

Initialize resource state only for authorized policy portions and under the existing host ceiling. Parsing a request cannot open arbitrary paths, contact arbitrary hosts, or create a privileged native resource to test whether permission might exist.

If constructing a set of grants fails partway, release already-acquired provider resources before publishing the root context. A selected invalid source or provider initialization failure does not fall back to broader defaults. Optional requests do not excuse operational initialization errors in authority the host actually chose to establish.

Provider exceptions never become `allow`. Unknown operations, invalid state, or inability to enforce the configured restriction deny execution or produce a typed unsupported/provider failure before the effect. Error reporting must preserve the original cause without calling an untrusted formatter in the authorization path.

## 11. Filesystem provider semantics

### 11.1 Tree roots and operation vocabulary

For the examples in this proposal:

```gene
(fs/Read "/tmp")
```

means read operations rooted at `/tmp` and its permitted descendants. It is not a string-prefix permission:

```text
/tmp                 inside the tree
/tmp/file            inside the tree
/tmp/sub/file        inside the tree
/tmp-old/file        outside the tree
```

Body alternatives are alternative roots; properties constrain the whole body. `fs/ReadWrite` can imply equally constrained `fs/Read` and `fs/Write` only through the admitted implication definition.

The provider must explicitly list which operation kinds belong to each capability. Enumeration, creation, deletion, rename, overwrite, metadata access, and handle reuse are not inferred from English names. Compound operations need an explicit demand model; do not decompose one merely to bypass complete-entry authorization.

### 11.2 Normalize against a stable source base

Relative policy strings resolve against the base defined by section 9 for CLI/files/environment, or the module's stable source base for static declarations. A dynamically parsed policy receives an explicit base. Changing process working directory later cannot move an established grant.

Module origins need not always be filesystem paths. A database-backed or otherwise virtual module must have a host-supplied resource base or use absolute configured resource strings; an origin URI is not permission to invent a physical directory. Missing required normalization context is a configuration error.

Use the target platform's actual path rules. Canonicalization and any glob restriction are not substitutes for safe resource resolution.

### 11.3 Keep policy logic and actual guarding connected

Recommended internal decomposition:

```text
normalize_fs_spec(body, properties, base)
match_fs_entry(grant_entry, concrete_operation_facts)
resolve_and_guard_fs_operation(current_context, prepared_operation)
perform_guarded_fs_operation(guarded_resolution)
```

The match function can be tested over roots and operation facts. The real resolution guard must preserve the same restriction during use. Lexically deleting `..` or approving a path string before an unrelated open is not sufficient when symlink traversal or concurrent changes can redirect the operation.

A provider may retain validated root handles and use platform-specific constrained resolution. Unsupported safety guarantees must be rejected explicitly, not replaced by a looser prefix test. A concrete filename containing `*` remains a filename, not a permission wildcard.

A retained file or directory handle must satisfy its origin restriction and the current context on every relevant effect. Passing a handle into a capability-empty block is not an alternate way to read data.

### 11.4 Advisory checks versus resource existence

A permission check answers whether the policy permits an operation under the provider's defined resolution model. It is not a general existence/readiness guarantee. Separate errors describe an absent file, broken device, access refused by the operating system, or failed resolution.

The check must not perform the requested read/write as a test. The actual read/write guards at use time even after a successful advisory result.

## 12. HTTP provider semantics and independently testable guard logic

### 12.1 The primary example

```gene
(net/Http ^hosts ["api.example.com"] ^methods ["GET"])
```

The body is unrestricted. This entry permits an HTTP operation only when its actual hostname is `api.example.com` under the provider's host normalization and its actual method is GET. It does not imply POST, HEAD, a subdomain, another port restriction, or local-network restriction beyond the fields actually configured.

With methods represented as exact alternatives, HEAD is not automatically implied by GET. Methods retain the exact semantics chosen by the transport/provider; do not invent case-folding or implicit verb implications in a generic string matcher.

### 12.2 Prepared requests and concrete facts

The trusted HTTP adapter prepares the request once, validates it, and derives a complete descriptor:

```text
HttpOperation:
    normalized_url
    scheme
    hostname
    effective_port
    path
    query facts, when supported by the configured schema
    actual_method
```

These fields are concrete values. They contain no admission flag and do not use an omitted field to mean unrestricted permission. If the caller omits a request method, the adapter fills the method it will actually send before checking. If necessary facts cannot be determined, it rejects the operation.

```text
prepared = prepare_request(actual_arguments)
facts    = describe_prepared_request(prepared)
guard_operation(net/Http, facts)
transport.send(prepared)
```

Use the same parser/normalizer for policy normalization and prepared operation facts. The guard must inspect the authority of the actual URL, not an unrelated caller-supplied `hostname` property. Connection reuse, proxy configuration, or an authority/header override must not send a materially different target from the guarded one; the initial adapter may reject conflicting overrides rather than support ambiguous behavior.

### 12.3 A dedicated HTTP authorization function

Keep the operation matcher small and independently tested:

```text
authorize_http_entry(entry, operation):
    require valid, complete HTTP operation facts
    require entry's complete URL-body constraint matches normalized_url
    require entry.schemes permits operation.scheme
    require entry.hosts permits operation.hostname
    require entry.ports permits operation.effective_port
    require entry.paths permits operation.path
    require entry.methods permits operation.actual_method
    check every other admitted HTTP restriction
    return allow only when all apply
```

The core selects entries and combines authority boundaries. This function handles HTTP meaning. Initialization and resource-origin validity may be checked by a wrapper, but cannot be omitted from the final decision.

Shared helpers can implement pattern alternatives and integer membership. Ports use exact integer alternatives, not numeric maximum ordering. The schema should use exact alternatives for schemes/methods and documented exact/pattern matching for hosts/paths. Unknown constraints fail schema validation, not open access at the guard.

### 12.4 Compact body patterns

```gene
(net/Http "http://localhost:8080/status" ^methods ["GET"])

(net/Http
  "https://api.example.com/*"
  "https://backup.example.com/*"
  ^methods ["GET"])
```

Body alternatives constrain complete normalized URL matching; all properties apply to every alternative.

Under the generic glob rule:

```gene
(net/Http "http://localhost*")
```

can match `http://localhost.evil.example/`. It is not an exact-localhost restriction. Do not describe that pattern as local-only access.

For structured restrictions:

```gene
(net/Http *
  ^schemes ["http"]
  ^hosts ["localhost"]
  ^ports [8080]
  ^paths ["/status"]
  ^methods ["GET"])
```

The body and properties are conjunctive. A broad body cannot cancel a narrow property.

### 12.5 Concrete URL normalization for requirement admission

Operation authorization already extracts hostname and method from a real request. Policy-to-policy admission needs an additional, explicit normalization rule for compact exact URLs.

Given:

```gene
# Grant:
(net/Http * ^hosts ["api.example.com"])

# Mandatory request:
(net/Http "https://api.example.com/status" ^methods ["GET"])
```

the request's exact URL logically restricts its hostname even though `^hosts` was omitted. The recommended normalizer derives provable scheme/host/effective-port/path projections from that exact URL and intersects them with explicitly authored component constraints. It retains the original URL-body constraint.

After this normalization, independent property matching can recognize the host restriction without requiring the programmer to repeat it. This is not adding permission: the added host constraint was already implied by the original body.

For multiple exact URL alternatives, each projection is the union of that component's possibilities, still conjoined with the original alternatives. The original body must remain to preserve host/path/port correlations. Do not replace it with independently combined projections.

Derive a projection only when it is proved for all body matches under the actual supported URL semantics. A wildcard in a location that prevents sound derivation leaves that projection unrestricted or represented by a conservative exact constraint. A proof limit may make mandatory admission inconclusive; it does not weaken operation guarding.

The reverse direction can remain conservative: a structured request and a compact grant might denote compatible sets without satisfying the per-field admission procedure. Diagnostics distinguish inability to match from a demonstrated forbidden request. The proposal does not require a general cross-field theorem prover.

### 12.6 Normalization details the provider must pin down

Before advertising support, the HTTP provider's own contract and fixtures must fix:

- supported URL schemes and treatment of host case/IDNA/trailing-dot spellings;
- explicit versus default ports, IPv4/IPv6 literals, and credential-bearing URLs;
- path/query percent encoding, empty paths, fragments, and any query restriction;
- method validation and exact matching; and
- which overrides, redirects, retries, proxies, and pooled connections are supported.

The design does not silently select an unrelated parser's behavior. Policy facts and actual transport targets must agree. Unsupported ambiguous forms are rejected. Avoid including secrets from URLs or headers in denial reports.

### 12.7 Redirects, retries, DNS, and later work

Each redirect is a new target operation with its resulting method and URL. Guard that operation before sending it; disable automatic unchecked redirect behavior in the underlying client.

A hostname policy is different from an IP/network destination policy. If the host installs both, enforce both at the appropriate resolution/connect point. `localhost` or a name beginning with that text is not a substitute for a loopback-address policy.

A logical hostname guard does not promise that DNS remains unchanged, and a successful prior check does not authorize a new redirect target or unlimited future retries. Revalidate at each new external-operation start and on relevant retained-resource reuse. An in-progress I/O operation need not be retroactively undone by revocation; subsequent effects remain subject to live guards.

Internal transport mechanics needed to implement an authorized HTTP operation stay inside the trusted adapter. Do not expose a general unguarded socket merely because an HTTP request passed. Whether a deployment adds an independent lower-level network restriction is an explicit provider/host policy, not a grant inferred from a namespace name.

## 13. Errors, reports, validation limits, and error-handling integration

### 13.1 Keep failure categories distinct

The following are semantic outcomes; implementations may reuse existing typed error families while exposing stable reason codes.

| Outcome | Required information/behavior |
| --- | --- |
| Invalid literal or metadata | Source, location, invalid form; reject even when optional or redundant. |
| Unknown capability/property | Catalog/schema identity and rejected name; no fallback provider. |
| Invalid provider configuration | Entry and expected whole-body/property shape. |
| Mandatory request remains unmatched | Authored request, uncovered alternative, authority row, and failed fields; do not automatically claim a concrete operation is denied. |
| Coverage proof incomplete | Limit/unsupported comparison; no fabricated counterexample. |
| Optional entry lacks a full match | Nonfatal admission information; no claim that its entire family is granted or unavailable. |
| Concrete operation denied | Actual operation summary and denying authority boundary; no effect started. |
| Invalid concrete operation | Missing/contradictory facts; not an unrestricted request. |
| Invalid or revoked live grant | Safe provenance and validity information; do not expose forgeable authority objects. |
| Provider initialization/evaluation failure | Original structured cause; no allow, no silent policy fallback. |

A field comparator's counterexample is a counterexample for that field. It is not automatically a valid counterexample operation for the full policy when other constraints correlate the fields. State that limitation in diagnostics.

### 13.2 A policy denial does not disappear in optional code

If code executes a denied action without first choosing a fallback, the real guard raises. `^^optional` does not convert the denial into nil, suppress I/O errors, or make the provider return a simulated success.

A failed block/function admission occurs before that boundary's body. Recovery belongs in the caller or an outer `try`. A guard failure during an already-entered body can be handled by the body's normal error handling. Cancellation and panic retain Gene's separate control paths.

The capability system does not redefine error provenance, `^errors`, or the draft static error-checking policy. Guard and provider failures use the language's established typed-failure machinery; any future static summaries must describe their real behavior rather than mark optional capability work as infallible.

### 13.3 No secret-bearing or authority-bearing reports

Inspection returns immutable summaries of requested/selected constraints, provider versions, entry status, and safe boundary identities. It does not return live grants, database credentials, API keys, mutable provider state, raw context restoration handles, or reusable authorization tickets.

Redaction must apply to URL user information, query values, sensitive paths, and provider-specific details. Avoid invoking application code while formatting a capability denial or recursively evaluating another capability to report a provider failure.

### 13.4 Bound normalization and checks

Publish implementation limits for literal bytes, row length, body/property/list size, namespace expansion, source nesting, admission-alternative expansion, and glob/containment work. Parsing the flag does not increase those bounds. A multi-field decomposition must stay within its proof budget, including when represented symbolically.

Exceeding a validation limit is an error. A bounded symbolic containment calculation may return `cannot_prove`. Runtime matching must either decide safely within its limits or reject before the effect; it never treats exhaustion as allow.

Automatic permission prompts, negated/deny rules, shared quota accounting, live root-grant editing, and a comprehensive static effect system are outside version 1. Optional requirements and block upper bounds are explicitly included in this revision.

## 14. Runtime boundaries, untrusted code, and integration

### 14.1 One capability system

Implement this format and behavior inside Gene's shared capability machinery. The CLI, module loader, function-entry machinery, block forms, library checks, native guards, and Harness policies must not each implement their own matcher.

The adopted target replaces conflicting names, literal semantics, launcher flags, and source precedence. Migration may produce clear diagnostics, but it must not preserve a parallel legacy authorization path that silently restores default permissions or old context-replacement semantics.

Namespace exposure, name/environment isolation, external authority, resource-origin restrictions, and execution budgets remain distinct. A capability selector does not answer all those questions.

### 14.2 Block entry and exit algorithm

Conceptual lowering for `with_capabilities`:

```text
1. Read an inline literal as data, or evaluate the entire policy-value operand
   exactly once using the caller's ordinary context.
2. Validate the immutable spec row for an upper-bound context; reject optional.
3. Resolve/normalize with the admitted catalog and captured source base.
4. Save the current dynamic authority state in private runtime continuation data.
5. Install Intersection(current_authority, normalized_bound).
6. Execute body forms with their ordinary lexical control-flow targets.
7. Run inner language-defined unwinding/cleanup under the applicable restricted
   context; do not temporarily elevate user cleanup.
8. Restore the saved caller state on every exit, then propagate the result,
   return/loop transfer, typed failure, panic, or cancellation unchanged.
```

`require_capabilities` adds mandatory entry matching before step 5, then selects the union of its mandatory and optional constraints. No body form executes if required admission fails.

This cannot be implemented as a context-variable assignment without guaranteed restoration, or as an ordinary function that evaluates its body argument eagerly. A compiler lowering/runtime primitive must preserve `return`, `break`, and `continue` targeting enclosing language constructs. Retained restoration state is private and cannot be read or invoked by the block.

### 14.3 Scheduling and optimization

Dynamic authority is execution-context local. If restricted task A suspends and unrelated task B executes, B must not inherit A's restriction and A must not resume with B's authority. Save/restore with the continuation, not one process-global mutable variable.

Tail-call elimination, inlining, message fast paths, native transitions, and JIT/AOT paths must preserve both entry checks and pending authority restoration. An optimization may elide an administrative frame only when it retains equivalent context semantics; a tail call is not permission to drop a boundary.

Capability literals in source can be parsed and symbolically normalized ahead of time against versioned catalog metadata. Actual admission and live validity remain runtime questions unless a sound host/runtime invariant proves them. Compilation cannot convert an optional permission into an unconditional effect grant.

### 14.4 Callable and module entry ordering

Caller-owned callee/receiver/argument expressions use Gene's existing evaluation schedule. Immediately before executing callee-owned defaults or body code:

```text
available = actual caller context
          ∩ callee module admission ceiling
          ∩ applicable import/bound/eval origin ceilings

if callable declares a request row:
    require full matching for its mandatory entries
    available = available ∩ constraints(complete request row)

execute defaults and body under available
restore caller on all returns/unwinds
```

A protocol message's dispatch still selects ordinary behavior. It cannot select a different capability provider, bypass the selected implementation's module ceiling, or replace current authority. Constructor default evaluation and initialization use the same ordering.

Module initialization follows its own request boundary and supplied loader policy before executing top-level application code. Once admitted, its retained maximum is combined with later callers rather than used as an alternative authority source. Do not infer current permission from a warm module cache or a successful earlier initialization.

This proposal does not introduce capability-row variance or a new static effect system. Public callable/protocol contract tooling must retain mandatory versus optional metadata. Comparing only the union of permitted operations loses an observable entry precondition: a required entry and an optional entry with the same constraints have different admission behavior.

### 14.5 Escaping values and deferred execution

| Value or boundary | Required authority behavior |
| --- | --- |
| Ordinary synchronous function or message call | Intersect actual caller with applicable declaration/module/retained ceilings. A call cannot elevate the restricted block. |
| Ordinary closure created inside a temporary block | Creation alone does not automatically capture that temporary dynamic bound. It uses its documented callable/module/eval ceilings when later invoked. Do not promise stronger capture without an explicit retained mechanism. |
| Bounded callable / `runtime/bind_call` | Retain the creating ceiling and intersect with every later caller. Bind inside the restricted block to preserve that bound across escape. |
| Eval-created code and sandboxed module code | Retain the admitted evaluation/module ceiling, installed before untrusted execution. A later broader caller cannot erase it. |
| Task started inside the boundary | Capture the effective context at spawn. Suspending and resuming do not replace it with a worker or host root context. Ordinary task lifetime rules remain separate. |
| Generator/lazy pipeline created under a boundary | Retain the defined creation/execution ceiling; pull and close also apply the actual consumer's relevant ceiling. Returning the stream is not executing or authorizing all its later effects. |
| Registered callback | The retaining API must bind its owner and ceiling explicitly. A plain function reference is not proof of captured registration authority. |
| Retained file/socket/database handle | Preserve origin constraints and check current permission at each relevant operation. Possession alone is not operation authority. |
| Native callback | Apply its admitted callback/owner ceiling and active invocation policy. Foreign-thread entry cannot silently borrow root authority. Unsupported modes are rejected. |

A useful retained-call pattern is:

```gene
(let bounded
  (with_capabilities [
    (net/Http ^hosts ["api.example.com"] ^methods ["GET"])
  ]
    ($runtime/bind_call callback [input])))

(bounded)
```

The binder name refers to the previously discussed Gene runtime seam; the normalized literal behavior here is part of this proposed revision. Creation does not call the target. Later invocation retains the restricted ceiling and still intersects the actual caller's context.

Do not silently make every plain closure capture temporary dynamic authority as an incidental implementation of block grants. If that language-wide semantic change is ever wanted, it needs its own design and migration. For untrusted generated extensions, use a sealed module/eval ceiling or an explicitly bounded callable.

### 14.6 Cleanup and lifetime are not new privileges

Capability-block exit does not automatically dispose every object created in the block or cancel every task. Existing lexical task scopes, stream contracts, resource managers, and Cordis effect ownership determine lifetimes.

User `ensure` bodies and cleanup callbacks run under their normal intersected authority. A provider can define a narrow release-only operation for closing an already-owned resource when permission has been removed; it must not use that mechanism to read more data, send a new request, or run arbitrary user cleanup with root privileges.

A revoked grant may prevent a new operation while cleanup remains possible. Revocation does not imply transactional undo of work already performed or guaranteed preemption of native I/O already in progress. Provider contracts identify revalidation points.

### 14.7 An upper bound is not a complete sandbox

Before calling untrusted code, the host must also decide:

```text
Which names and modules can it access?
Which mutable objects and callbacks can it retain?
What CPU, memory, wall-clock, and task limits apply?
Which native interfaces, subprocesses, and loaders are admitted?
Who owns and cancels its deferred work?
```

`with_capabilities []` prevents sanctioned external operations from acquiring permission, but cannot make a supplied live Harness cell immutable or stop an infinite pure loop without an execution budget. Arbitrary admitted native code or an unrestricted subprocess remains outside an in-process capability guarantee.

Install name isolation, admission restrictions, and numeric execution policies before compiling or initializing untrusted module graphs. Configuring a loaded module afterward cannot retroactively restrict its earlier effects.

### 14.8 Source normalization bases and host initialization

Static declaration paths use the declaring module's stable base; literals inside that module share the base. CLI, environment, and configuration files use section 9. A dynamic spec carries an explicit base supplied to its parser/normalizer. Base identity is metadata, not permission.

The trusted launcher may need narrowly admitted control-plane operations to read its selected configuration and approved source graph before application entry. Those operations are not default application capabilities and their handles must not be exposed to the program. Therefore `--cap []` can still load an approved application while giving its executed code no ordinary filesystem/network authority. Import/source acquisition remains governed by its own admitted source policy rather than arbitrary file access through a hidden back door.

### 14.9 Harness and Cordis integration

A generated plugin can propose an inert request row. The host validates it, installs an execution ceiling before running its untrusted code, and admits mandatory entries against actual authority. Optional entries keep available overlap. On restore, revalidate the stored specification against the current host policy and catalog; a historic acceptance is not a live grant.

Cordis contexts, plugin policies, retained callback revisions, and task/stream owners can add ceilings. They cannot replace a narrower caller with the authority present when the plugin was first installed.

An agent tool executor may deliberately service a validated, named request after untrusted code returns to trusted host control. That is an explicit host-mediated delegation boundary, not ordinary callback invocation recovering root authority. The host must authorize the request's operation, tool identity, owner/revision, and selected policy before executing it. Arbitrary queued closures or caller-supplied operation facts must not become an unsupervised privileged continuation.

Use the shared capability core for profile/module/block/check/guard logic. Persist specs, origin/version information, and approval records; never persist live grants as if deserialization restored them.

## 15. Implementation sequence and bounded scope

### Phase 1 — Reader, catalog, and normalized constraints

Implement the restricted reader with duplicate detection and preserved locations. Separate core admission metadata from provider restrictions. Reuse it across source literals, CLI text, capability files, environment values, and checked dynamic parsing.

Implement trusted catalog identities, frozen namespace expansion, constraint-preserving implications, and provider-local validators. Preserve the source naming convention and reject malformed optional entries.

Supply reusable exact, alternatives, maximum/minimum integer, boolean, and glob constraints. Keep structured bodies whole and define exact admission decomposition for provider-declared alternatives. Distinguish semantic coverage from conservative admission in types, diagnostics, and test names.

### Phase 2 — Provider matchers and actual effect guards

Implement filesystem and HTTP provider-specific authorization functions and a small synthetic provider for integer/boolean/pattern tests. Specify actual operation descriptors before wiring guards.

Create one shared concrete authorization evaluator used by programmatic checks and effect guards. Inventory sanctioned entry points and use fake transports/resources to verify that denied operations never start. Retained handles and redirect/retry paths participate from the beginning.

Pin the provider-specific details in section 17 rather than claiming that a generic literal matcher alone implements safe filesystem or HTTP access.

### Phase 3 — Host grants and startup sources

Select exactly one source with the precedence in section 9. Explicit rows replace lower defaults; `[]` contributes none. Apply administrator ceilings, initialize only authorized state, and roll back partial initialization on failure.

Keep startup source/loader authority separate from application authority. Neither a stored policy nor an environment edit mutates live grants after startup.

### Phase 4 — Requests, optionality, and block boundaries

Implement mandatory admission, including collective coverage of complete request alternatives within each authority row, and exact intersection with the full requested row. Implement `^^optional` as partial-availability selection without a full-match entry precondition.

Add `with_capabilities` as pure attenuation and the separate required-block operation. Install callable selection before callee-owned defaults. Define module initialization and retained ceiling behavior explicitly.

Test all control transfers and nested attempts to recover root authority. Do not ship only straight-line push/pop examples.

### Phase 5 — Deferred boundaries and lifecycle

Integrate tasks, lazy streams, bind_call/retained callbacks, module/eval origins, and native entry with the same policy state. Add authority restoration to every optimized and cancellation path accepted by each backend.

Preserve grant provenance and live revocation. Keep resource/callback cleanup independent of the ordinary policy predicates without turning cleanup into a privilege channel.

### Phase 6 — Tooling, migration, and applications

Provide safe requirement and operation reports. Update compiler metadata, diagnostics, documentation, examples, CLI, and Harness policy formats together. Remove obsolete selection/grant paths rather than maintaining silent compatibility behavior.

Validate one full Harness workflow with optional model access, a fallback, constrained generated code, a guarded delegated tool, a retained callback, cancellation, and restart under a narrower host policy. Validate the same provider/check behavior from an ordinary script without Cordis.

No phase is considered implemented merely because the schema, method name, or acceptance test is written here. A backend must enforce the supported contract or reject the feature explicitly; the browser backend cannot silently advertise VM capability confinement that its embedding does not provide.

## 16. Acceptance and conformance cases

Test the policy parser, admission procedure, provider matchers, and real guard placement separately, then exercise their interactions. The cases below specify expected behavior; they are not reported test results.

### 16.1 Literals, identity, and configuration sources

| ID | Case | Required result |
| --- | --- | --- |
| L01 | Same row from CLI, alias, file, environment, and source with the same base/catalog | Same normalized constraint meaning. |
| L02 | Symbol value, expression, interpolation, map, nested list, float, nil, or void | Rejected; no application code runs. |
| L03 | Unknown name/property or duplicate property beside an unrestricted entry | Still rejected. |
| L04 | `C`, `(C)`, `(C *)` | Equivalent policy coverage. |
| L05 | Omitted startup source versus explicit `[]` | Defaults only for omission; explicit empty selects no application authority. |
| L06 | Token `*` versus string `"*"` | Domain-unrestricted token is not silently a string pattern or numeric value. |
| L07 | `^^optional` and `^optional true` | Same request metadata; flag removed before provider checks. |
| L08 | `^optional false` | Mandatory request entry. |
| L09 | Optional unknown provider, unknown property, malformed body, or invalid boolean | Rejected before admission. |
| L10 | Optional flag in root grant, pure bound, admin ceiling, or operation facts | Rejected, not ignored. |
| L11 | Duplicate `^optional`/`^^optional` | Reader error before property overwrite. |
| L12 | Two CLI sources or a repeated source | Error, no union or last-one-wins behavior. |
| L13 | Explicit CLI row plus a broader environment/default | Only selected CLI policy, intersected with independent ceilings. |
| L14 | Selected malformed source | Error; do not fall back. |
| L15 | Relative policy paths from file/CLI/static module | Resolve against their documented stable source bases. |
| L16 | File/env changes or cwd changes after initialization | Existing contexts do not widen or change targets. |
| L17 | Namespace selection including an incompatible provider schema | Reject whole constrained selector. |
| L18 | Namespace has no admitted match or name is unknown | Reject even if optional. |
| L19 | Catalog changes after wildcard expansion | Existing authority unchanged. |
| L20 | Application-defined type/impl repeats a provider name | Cannot substitute for trusted authorization behavior. |

### 16.2 Algebra and mandatory admission

| ID | Case | Required result |
| --- | --- | --- |
| A01 | One read entry with two roots; request either or both | Complete body matching succeeds. |
| A02 | Two grants each with one root; one request naming both | Admission succeeds by covering each complete root alternative; grants retain separate provenance. |
| A03 | Same two grants; two corresponding request entries | Admission succeeds independently. |
| A04 | GET-on-A and POST-on-B | Deny POST-on-A and GET-on-B. |
| A05 | Same provider, multiple ceilings | Operation must pass one complete entry in every ceiling. |
| A06 | Unrepresentable glob intersection | Retain exact predicates; no broad approximation. |
| A07 | Maximum integer 5 against requested maximum 4 | Covered for that declared constraint kind. |
| A08 | Port 8081 versus port 8080 | No exact-ID match. |
| A09 | Boolean false versus true | No universal boolean ordering. |
| A10 | Empty alternatives versus omitted field | Empty allows none; omitted is unrestricted. |
| A11 | Composite ReadWrite under a root | Implies only equally constrained component operations. |
| A12 | One candidate field fails and another is unproved | Candidate is a nonmatch; report actual failed field. |
| A13 | Earlier candidate unproved, later candidate fully matches | Admission succeeds. |
| A14 | A necessary alternative has no matching candidate and at least one otherwise viable proof is incomplete | Report cannot prove, not a fabricated concrete counterexample. |
| A15 | Optional broad request plus mandatory narrow request | Preserve mandatory obligation during normalization. |
| A16 | Independent broad grant revoked while narrower grant remains | Narrower authority still works; no unsafe redundancy elimination. |
| A17 | Reorder overlapping grants | Same authorization outcomes and equivalent retained validity behavior. |
| A18 | Exact URL's implied host restriction | Normalization supports admission beneath exact host grant, retaining original URL constraint. |
| A19 | Several exact URLs projected to host/path lists | No extra cross-product URLs become permitted. |
| A20 | Grouped root request with one root absent from the grant row | Admission fails; identify the unmatched root alternative. |
| A21 | Separate GET and POST grants for the same URL; one request allowing both methods | Admission succeeds through exact method alternatives. |
| A22 | GET-on-A and POST-on-B grants; one request for GET or POST on A or B | Admission fails; POST-on-A and GET-on-B are not covered. |
| A23 | One ceiling grants only root A, another only root B; request names both | Admission fails; alternatives must be covered within every row, not pooled across ceilings. |
| A24 | Grouped roots admitted through separate grants; one grant is later revoked | Its operations fail the real guard; the other grant retains its own authority. |
| A25 | Provider-defined indivisible multi-resource operation | No decomposition into separately granted resource facts; match the complete operation shape. |
| A26 | Whole-entry match fails and alternative expansion exceeds its proof budget | Report `cannot_prove`; mandatory boundary does not execute. |

### 16.3 Optional requests and upper-bound blocks

| ID | Case | Required result |
| --- | --- | --- |
| B01 | Optional HTTP with no HTTP grant | Enter; no HTTP operation allowed. |
| B02 | Optional unrestricted HTTP with host/method-limited grant | Enter with the restricted available overlap, not zero and not unrestricted HTTP. |
| B03 | Optional GET/POST with GET-only grant | GET can pass a guard; POST cannot. |
| B04 | Mandatory HTTP missing, even beside other optional entries | Reject before body/default effects. |
| B05 | `with_capabilities` requests more than caller has | Enter with intersection; never escalate. |
| B06 | Block selects HTTP only; caller also has filesystem | Filesystem unavailable inside. |
| B07 | Nested block requests broad ReadWrite under outer Read-only tree | Remains read-only and inside outer boundary. |
| B08 | Explicit empty block or declaration | No external-operation authority. |
| B09 | Omitted declaration | Retain actual caller's other applicable ceilings. |
| B10 | Required block with optional HTTP | Required entries match; optional subset remains usable. |
| B11 | Optional operation actually denied during use | Guard raises; optional does not suppress it. |
| B12 | Optional provider configuration malformed or initialization fails | Not treated as mere missing permission. |
| B13 | Function with fallback makes HTTP mandatory | Admission fails before fallback; diagnostic explains this distinction. |
| B14 | Body return/break/continue/error/panic/cancellation | Context restored without changing ordinary control target. |
| B15 | Default expression performs an effect | Callee request/ceiling is already installed. |
| B16 | Explicit argument expression before callee entry | Uses caller schedule; wrapping the complete call bounds it. |
| B17 | Required module initializes once, later invoked by narrower caller | Cannot recover module initialization authority. |
| B18 | All-optional requirement check reports admitted | Does not imply any concrete operation is allowed. |

### 16.4 Concrete checks and guard placement

For these cases use `(net/Http ^hosts ["api.example.com"] ^methods ["GET"])` unless otherwise stated, and a recording transport that verifies whether any effect began.

| ID | Case | Required result |
| --- | --- | --- |
| G01 | Actual GET to the allowed hostname | Check allows; guarded send can execute. |
| G02 | POST or HEAD to the hostname | Denied; transport not called. |
| G03 | GET to another host or `api.example.com.evil.test` | Denied under exact host matching. |
| G04 | Advisory descriptor claims permitted hostname but actual URL differs | Actual adapter-derived operation denied. |
| G05 | Request omits method | Guard checks the actual default method; never wildcard. |
| G06 | Missing required operation facts | Invalid operation, not unrestricted access. |
| G07 | Check succeeds, then context narrows or grant revokes | Later guard denies. |
| G08 | Same frozen facts/context/provider validity | Check and guard agree. |
| G09 | Provider authorization throws or exhausts matching budget | No effect; distinguish provider failure from ordinary denial. |
| G10 | Redirect leaves allowed target or changes to a forbidden method | Second request denied before sending it. |
| G11 | Lazy request stream returned without consumption | No implicit external operations; each actual later operation is guarded. |
| G12 | Public alternative/lower-level adapter path | Cannot bypass common enforcement. |
| G13 | Actual resource name includes `*` | Checked as concrete text, not as a policy pattern. |
| G14 | Filesystem `/tmp-old` versus root `/tmp` | Denied; no prefix confusion. |
| G15 | Filesystem resolution changes or symlink traversal | Constrained resolution holds or operation is rejected; pure precheck not sufficient. |
| G16 | Retained handle under a narrower or empty block | No recovery of removed ordinary-operation authority. |
| G17 | Successful policy requirement check | Does not remove operation guards or reserve future permission. |
| G18 | Denial and provider diagnostics | Safe facts only; no credentials or live authority objects. |
| G19 | Generic HTTP client called under a narrow host/method grant | No artificial mandatory-unrestricted entry requirement; the permitted concrete request reaches its real guard. |

### 16.5 Deferred execution, runtime integration, and restoration

| ID | Case | Required result |
| --- | --- | --- |
| R01 | Restricted task suspends while unrelated task runs | Correct independent contexts on both continuations. |
| R02 | Tail call or optimized message crosses a restricted boundary | No dropped ceiling/restoration obligation. |
| R03 | Bound callable created in restricted block escapes to broad caller | Keeps creation ceiling. |
| R04 | Broad retained callable invoked by narrow caller | Uses intersection, never its saved context alone. |
| R05 | Plain closure created in temporary block without a retaining API | Matches explicitly documented plain-closure behavior; not falsely treated as sealed. |
| R06 | Generator/stream pulled or closed from another context | Creation/origin and consumer ceilings preserved. |
| R07 | Task spawned inside a block outlives that lexical block | Retains its captured authority; lifetime handled by existing task ownership. |
| R08 | User cleanup attempts an unrelated effect | Runs under normal narrowed authority; no teardown escalation. |
| R09 | Release-only provider cleanup after revocation | Can release owned resource according to its narrow cleanup contract, without new data effects. |
| R10 | Untrusted loading/compilation before initialization | Policies/name isolation/budgets installed before executing untrusted work. |
| R11 | Restore stored plugin specs on a narrower host | Revalidate; no automatic restoration of old grants. |
| R12 | Trusted host processes a plugin tool request | Validate named operation and owner policy; no arbitrary privileged closure execution. |
| R13 | Runtime backend cannot enforce the contract | Reject explicitly; no silent success or weaker advertised sandbox. |
| R14 | Capability block receives a mutable live object | External authority bound holds; tests do not mistake it for in-memory isolation. |

### 16.6 Model-based and property-based checks

Use finite synthetic providers to enumerate permitted operations and compare them with the implementation. Verify:

```text
match_entry(G, R) = matched  implies  Ops(R) ⊆ Ops(G)

Ops(R) = union of Ops(Ri) for every provider-produced decomposition [Ri]

match_row(Row(G...), R) = matched  implies  Ops(R) ⊆ union of Ops(G)

allows(A ∩ B, op) = allows(A, op) AND allows(B, op)

allows(Row(entries), op) = OR of complete valid-entry decisions

allows(attenuate(A, U), op) implies allows(A, op)

request admission with optional flags changes preconditions,
not the denoted constraints or the operation matcher's meaning
```

Do not assert that semantic inclusion always implies conservative admission. Include explicit negative fixtures for unsupported union proofs and bounded containment. Within supported decomposition limits, regrouping finite alternatives with identical other constraints and admission flags must preserve admission outcomes. Assert representation/idempotent normalization properties only while retaining admission flags, authored source grouping, and grant provenance as required.

For pattern comparators, check exact/literal escaping, whole-string matching, empty matches, and requested-pattern containment separately. A bounded comparator may be inconclusive; a false positive authorization is never acceptable.

A passing policy test does not prove the adapter used the guarded target. Integration tests must record the actual native/transport effect, redirects, cleanup, and execution context at the work site.

## 17. Provider and API details to finalize

The cross-cutting contract is fixed by this proposal, including optional semantics, block attenuation, mandatory admission, and shared operation checks/guards. The following choices still require concrete provider/API definitions and fixtures before their implementations can be advertised as complete:

| Area | Remaining specific decision |
| --- | --- |
| Filesystem | Final capability names, operation vocabulary, compound-operation demands, platform-safe path and symlink handling, and release-only behavior. |
| HTTP | Supported schemes and all normalization items in section 12.6; any separately required network-address policy. |
| Public API | Final names/layouts for validated SpecRow, RequirementReport, CapabilityDecision, and provider-specific operation-description helpers. |
| Compiler integration | Exact representation/opcodes for boundary entry/restoration and how request metadata appears in public callable interfaces. |
| Configuration | Host config wrapper/discovery, documented implementation size/proof limits, and admitted default root policy when no source is supplied. |
| Resource initialization | Per-provider rollback/release behavior and what advisory checks may inspect without performing the requested effect. |

These are not permission to reinterpret `^^optional`, allow block escalation, merge entries, or silently drop unsupported restrictions. Unsupported forms or enforcement modes must be rejected until their contract exists.

No general static effect inference, negative permissions, user-defined authority providers, consumable quotas, or arbitrary persistent authority objects are introduced by this document.

## 18. Core specification wording

> A capability literal is inert data identifying a trusted capability provider and its constraints. A host can establish root grants from admitted configuration; ordinary code can only request or narrow existing authority. Providers interpret the complete body and their named properties. Entries remain independent alternatives, while separate authority boundaries intersect.
>
> Semantic coverage is inclusion of permitted operation sets. Mandatory request admission uses sound whole-body and per-property matching of complete entries, with exact provider-defined decomposition allowing different request alternatives to match different grants in the same row. Every applicable authority row must cover the request independently. The procedure remains conservative for unsupported or bounded proofs. Optional requested entries do not prevent boundary entry when unmatched; they select whatever exact overlap is already available. The full request row bounds the entered code, and its optional metadata does not affect operation authorization.
>
> `with_capabilities` delegates an upper bound by intersecting the current context with its row. It cannot mint grants or restore broader saved authority. Required blocks and callable/module declarations perform their specified mandatory admission checks before their body or callee-owned defaults run. The runtime preserves and restores authority across ordinary control flow, failure, suspension, and supported optimized execution.
>
> Programmatic requirement checks and concrete-operation checks answer different questions. Checks and mandatory effect guards share the same provider authorization meaning, but a successful check does not reserve permission or replace the guard. Trusted adapters derive the actual operation facts and enforce permission at the point of work, including relevant redirects, retained-resource reuse, origin restrictions, and live validity. Optional capability requests never make guards optional.
>
> Normalization must not broaden permission, destroy entry correlations, erase mandatory obligations, or discard independent grant provenance. Unsupported enforcement and provider failures never become authorization.

**One literal format; trusted providers; explicit requests; optional availability; block-level upper bounds; shared checks and guards; no implicit escalation.**

## 19. Consolidation decisions, source basis, and status

### 19.1 What is preserved from the updated document

The baseline is the user-supplied `capabilities(1).md`, titled *Gene Capabilities: Normalized Literals, Coverage, and Reconciliation*, dated 2026-09-15.

Preserved decisions include the inert grammar; complete-body and per-property comparison; independent grant entries; `namespace/Name` identifiers and terminal namespace selectors; provider-selected numeric/boolean/list meaning; exact intersections; CLI aliases and one-source rule; CLI/environment/config/default precedence; explicit empty-policy replacement; trusted providers; resource origins; and the distinction between namespace exposure and authority. The earlier prohibition on collective request matching is superseded by section 3.4's exact alternative decomposition.

### 19.2 Review corrections incorporated

| Earlier concern | Resolution in this document |
| --- | --- |
| Exact semantic coverage was conflated with conservative admission matching. | Separate operation-set coverage from mandatory admission and distinguish their diagnostics; support exact finite alternatives without requiring arbitrary union-containment proofs. |
| A concrete URL implied its hostname, but independent policy fields could reject the precise request. | Provider normalization derives proved component projections while retaining the original body/correlations. Runtime operation checks independently extract actual facts. |
| Redundancy elimination could erase a separately revocable grant. | Preserve independent live provenance and validity; share symbolic matchers without collapsing grants. |

### 19.3 Additional decisions made in this consolidation

| Topic | Recommended target decision |
| --- | --- |
| Grant/request/check/guard separation | Distinct receiving operations using one format and shared trusted provider semantics. |
| Collective request coverage | Provider-defined alternatives may be covered by different complete grants in the same row; preserve every constraint, independent ceilings, and live grant provenance. |
| Granting to a block | `with_capabilities` means upper-bound attenuation of the actual caller, never elevation. |
| Required blocks | A separate `require_capabilities` operation performs admission plus restriction. |
| Optional spelling | `^^optional` / `^optional true`, rendered as `(net/Http ^^optional)` under the baseline naming convention. |
| Optional partial availability | Keep the exact available intersection, rather than discard an optional broad entry unless fully matched. |
| Optional validation | Only absence of authority is nonfatal to entry; invalid names, malformed constraints, and provider errors stay explicit. |
| Flag placement | Request contexts only; rejected in grants, pure ceilings/bounds, and operation facts. |
| Module row | Admission before initialization and a retained module maximum; callable entry requirements are checked on invocation. |
| Check versus guard | Shared evaluator; check is advisory, guard is mandatory at the real effect boundary. |
| Ordinary closure escape | No silent language-wide capture change; use admitted module/eval ceilings or explicit bounded/retained callables. |
| Dynamic configured policies | Immutable validated spec values may be computed/parsed outside a literal and supplied once to a boundary; they never carry grants. |

These rows identify proposed completions rather than presenting every API spelling as a prior user decision. They are included so an implementing agent can review one coherent target instead of inferring missing semantics independently.

### 19.4 Scope of evidence

This document is grounded in the supplied updated proposal and the subsequent design discussion, including the user's HTTP hostname/method guard example and requests for block upper bounds and optional capabilities. It does not incorporate unrelated error-checking or Self-type proposals as additional authority.

It is a design artifact, not a repository audit, standards compliance certification, security certification, or report of executed tests. Provider implementation details and runtime support must be verified through the acceptance cases before making support claims. No implementation is changed by creating this file.

## 20. Open review comments

These comments record a review of sections 1–19 and the author's responses to it. They are open items, not adopted decisions: sections 1–19 stand as written until one of them is resolved. Each comment states its status so an implementing agent does not mistake an unresolved question for a settled contract.

| # | Comment | Status |
| --- | --- | --- |
| 20.1 | Plain closures escape a block's upper bound | Open; needs further investigation |
| 20.2 | Dynamic policies are built by string interpolation | Open; needs further investigation |
| 20.3 | What `^^optional` means | Resolved by the author's definition; two consequences to keep visible |
| 20.4 | Module-level `^capabilities` may be removed | Proposed for removal in version 1 |
| 20.5 | Two URL representations in the HTTP provider | Open recommendation; no response yet |
| 20.6 | Retained resources recording which grants matched | Open recommendation; no response yet |
| 20.7 | Cost of per-invocation admission | Open recommendation; no response yet |
| 20.8 | Conversation residue in the header and section 19 | Editorial |

### 20.1 Plain closures escape a block's upper bound

**Status: open; needs further investigation.**

Section 7.6 illustrates a bound with `(with_capabilities [...] (untrusted_callback input))`, while section 14.5 states that a plain closure created inside a block does not retain that block's bound. Code running inside the block can therefore store a closure and have it executed later under the caller's broader authority:

```gene
(with_capabilities []
  (plugin_init registry))      # plugin stores (fn [] ($fs/write_text ...))

(run_handlers registry)        # handlers now execute with host authority
```

Tasks, generators, lazy pipelines, and bound callables all retain their creation ceiling; the plain closure is the one exception. Retaining a ceiling can only narrow authority, never widen it, so capture would be sound by construction, and a closure created outside any capability block would carry no ceiling at all.

Questions to settle before changing section 14.5:

- the cost of retaining a ceiling reference on closures created inside a block, and whether escape analysis can prove that a given closure never outlives the block;
- whether trusted code legitimately creates a closure inside a bounded block for deliberate later use under broader authority;
- whether escape should narrow the closure (invoke under creation ceiling ∩ caller) or be rejected outright at the escape point;
- how the rule interacts with the runtime's existing function-escape and scope-ownership machinery.

Until this is resolved, `with_capabilities` bounds a dynamic extent. It is not confinement of untrusted code, and the examples in sections 7.6 and 7.7 should not be read as such.

### 20.2 Dynamic policies are built by string interpolation

**Status: open; needs further investigation.**

Because literals reject variables (section 2.2), the only version-1 route from a runtime value to a bound is text through `$capabilities/parse` (section 2.5):

```gene
($capabilities/parse $"[(fs/Read \"${dir}\")]")
```

A `dir` of `x") (fs/ReadWrite "/` adds a second entry to the parsed row. Attenuation keeps the result within the caller's authority, so this is not an escalation past the caller, but it silently widens the bound the author intended to impose on the callee — which is the entire purpose of the block.

Options to weigh:

- promote the checked builder mentioned in section 2.5 to version 1, so that a row is constructed from values rather than from text, and reserve `parse` for host and configuration text;
- restrict `parse` to explicitly host-supplied source kinds, so an application cannot use it on assembled text at all;
- keep text parsing and supply a quoting/escaping operation, accepting that a missed call site is a silent widening.

Questions to settle: which normalization base a value-built row carries; whether such a row may appear in mandatory request positions or only in bounds; and whether the builder should reject a body value that is not already normalized against a base.

### 20.3 What `^^optional` means

**Author's definition: an optional entry means the code can choose an alternative route when the capability is not granted.**

This is the intended reading of sections 2.4, 7.3, and 7.4. Mandatory entries are for code that cannot proceed without the authority; optional entries are for code that carries a fallback. The earlier review suggestion to invert the default — bounds by default with an opt-in `^^required` — is withdrawn under this definition.

Two consequences must stay visible in the specification:

1. **"Not granted" is usually not a yes/no fact.** Section 7.3 keeps the available overlap, so partial availability is the normal case: GET granted, POST not. Code choosing a route must therefore ask about the concrete operation it intends to perform (sections 10.4 and 10.6), not about the capability family. A cached boolean such as `has_http` cannot express the answer, which section 10.6 already states.
2. **An optional entry and an upper-bound entry compute the same effective authority.** They differ in intent and in what the requirement report says (section 7.4), not in the resulting policy. That is acceptable, but the specification should say so plainly, so an implementer does not look for a behavioral difference that does not exist. An optional entry additionally documents "this code has a fallback", which a plain bound does not.

One caveat from section 10.7 survives unchanged: a general-purpose library function should not declare a mandatory unrestricted entry, because that rejects narrowly granted callers before any concrete guard runs.

### 20.4 Module-level `^capabilities` may be removed

**Status: removal proposed by the author; recommended for version 1.**

The review's concern: section 7.9 admits a module against the authority current at its initialization, and section 14.4 does not re-initialize a cached module. The first importer therefore decides what every later importer gets. A plugin running under `with_capabilities []` that imports `reporting` first leaves the application with a failed or empty result for the same module.

Removing module rows would:

- delete that order dependence, along with the retained-module-ceiling rules in sections 7.9 and 14.4 and case B17;
- leave module-defined code running under its caller's authority, intersected with loader and origin policy and with whatever each callable declares;
- keep confinement of untrusted modules where it already belongs — in the loader's admitted policy (section 14.7), which the host supplies rather than the module's own source.

What would be lost:

- a module-wide maximum covering every function a module defines, so an author who wants that must declare it per callable;
- an initialization-time requirement, so a module that cannot work at all without some authority fails at first use rather than at import.

Neither loss is severe: the first is a convenience, and the second trades an early failure for a failure at the real guard, which every other path already relies on.

If module rows are kept instead, the order dependence must be fixed directly: derive both initialization authority and the retained ceiling from the loader's policy for that module intersected with its declared row, never from the importing site's dynamic context.

### 20.5 Two URL representations in the HTTP provider

**Status: open recommendation.**

The projection machinery in section 12.5, cases A18 and A19, and the requirement to retain the original body for correlation all exist to reconcile a URL body with the `^schemes`/`^hosts`/`^ports`/`^paths` fields. One representation would remove all of it: allow at most one URL per `net/Http` entry and convert it into component fields during normalization, with several URLs written as several entries, as parallel rules already are. Restrict `*` to a single component, such as `*.example.com` or `/api/*`.

That also turns the pattern `"http://localhost*"` into a rejected literal rather than the documented hazard described in section 12.4.

### 20.6 Retained resources recording which grants matched

**Status: open recommendation.**

Section 6.4 requires that "where multiple grant alternatives remain valid for the resource, their validity remains represented", which prevents a retained handle from using the stop-at-first-match rule and forces it to track every covering grant. Sections 11.3 and 14.5 already require each use of a handle to be authorized against the current context, so recording the origin ceiling — a context — rather than the matching grant produces the same outcome, keeps first match order-independent as case A17 requires, and removes the bookkeeping.

### 20.7 Cost of per-invocation admission

**Status: open recommendation.**

Section 7.9 admits a declared row at every invocation, so a frequently called declared function repeats intersections and possibly bounded containment proofs on every call. Contexts are immutable, so admission and intersection results can be memoized by context identity, row identity, and catalog version. Guards remain responsible for live validity, so a memoized admission result can never authorize an effect by itself. Section 6.5 currently reads as discouraging this; it should distinguish a context-free cached boolean, which is unsafe, from a cache keyed by the context.

### 20.8 Conversation residue

**Status: editorial.**

The header's basis line refers to `capabilities(1).md` and "the subsequent review", and section 19 is largely a changelog of the discussion that produced this revision. Both will age badly once this document lands in the repository as the capability contract. Section 19.3 is worth keeping in some form, since it marks which decisions were proposed rather than chosen by the author; the rest can go.
