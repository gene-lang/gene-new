# Protocol and message experiment: findings

Executes `tmp/protocol-message-exp.md` (owner: Codex; executed 2026-11-01). Retention of
protocols, messages and scoped implementations is the premise, so every result below
feeds an improvement plan (section 10). Native VM only.

## 1. Provenance and reproduction

| Item | Value |
| --- | --- |
| Source | `8351b585dc97555a32b6534a4dd2f203cd68e8e4` on branch `protocol-message-exp`; protocol/import semantics are unchanged since the plan's reviewed revision `f613a338` (the only `src/` drift is FFI four-buffer calls). |
| Before binary | `tmp/pm-exp-build/gene-before`, release, built from a clean tree with a fresh Nim cache (21 min); SHA-256 `e0448e59f195db03df7752234b355ed29f3cd12c5e718777eeb780490a909467`. `d1_reject_fn` prints `loaded` on it, confirming it predates the repairs. |
| After binary | `tmp/pm-exp-build/gene-after`, release, independent fresh Nim cache (29 min under machine load); SHA-256 `6deb08770ab7d869e37644c2b3ac7ab8d5cd458b6a89b503ddad981ea9f5aeb6`; source = HEAD plus a `src/` diff whose SHA-256 is `625a08e44261808c80e1ce442b56f0bdcc8785e570910ece993f25d3d3361f25`. |
| Build line (both) | `Gene 0.1.0 (release; macosx/arm64; Nim 2.2.12; mm=orc; nim-opt=speed; bounds=true; overflow=true)`; `nim c -d:release --path:src --hints:off --nimcache:<fresh> src/gene.nim`. |
| Machine | Apple arm64, 14 cores, AC power. The macOS contacts/calendar daemons repeatedly drove the load average to 100-200 during builds; every timing batch below ran at load 3-4 and records per-round load. |
| Fixtures | `examples/protocol-message-exp/tests/boundaries` (39 cases). `bin/gene test examples/protocol-message-exp/tests` runs them plus the matched-output specs and the frozen-core check. |

Reproduce any boundary case: `bin/gene run examples/protocol-message-exp/tests/boundaries/run.gene ID`.
Raw before/after outputs: `reports/evidence/before/boundaries` (first sweep, before any
repair), `before/boundaries-final` (final fixtures on the before binary), `after/boundaries`.

### Existing coverage confirmation (not relabelled as new work)

On the working tree with the repairs: `tests/test_all.nim` 1,803 OK and 3 failures that
predate this work (`gene harness recovery nucleus` reads a deleted `view_api.gene`;
`inference-depth` and `episode-depth` need deleted `tools/qualify_*.py`);
`tests/spec_runner.nim` exit 0; `tests/test_rc.nim` (`-d:geneRcStats`) 91 OK;
`tests/test_modules.nim` 124 OK including the new tests listed in section 8.

## 2. Contract versus observation (Phase 0)

Observations on the before binary unless noted; each row is a retained fixture.

| Contract (plan section 3) | Observed | Class |
| --- | --- | --- |
| Call-form `(P:m x)` normalizes to `(x .P:m)`, resolves at the send site | host without the pair: missing impl; at B's send site: B's body | as specified |
| Held Message keeps its authored scope; checked `(Callable ...)` view and an A-authored Path value behave the same; `.%` uses the send-site scope and rejects a view | `b2_transport` matrix below | as specified |
| Canonical impl needs protocol-or-type ownership | a third module implementing `Outline` for `Chart` is scoped (and the late `Chart` must own its canonical impl) | as specified |
| Ordinary `import_impl` effect is module-wide even in a function | function-local import registered for the whole defining module; sibling function sees it, a second installer raises `duplicate visible impl` | defect against D1 (fixed, section 7) |
| Hidden-impl advice names the module that governs the check | for an already exported provider it said "not exported; add `^^export`" once another module had imported the pair | defect (fixed) |
| Suggested `import_impl` is copyable | contained an absolute filesystem path | defect (fixed) |
| `import_impl ^from "./x"` resolves against the module that wrote it | resolved against the entry module's directory when executed after module init (functions, marked blocks in library functions); plain `import` in a function had the same flaw | defect (fixed) |
| Conflict diagnostics name the pair and governing module | `duplicate visible impl P for T` only; no origins; Self-binding conflict gave no reason | defect (fixed) |

## 3. Boundary gate results (Phase 1)

### B1. Recursive composition

All fixtures use the frozen core (`src/model.gene`, `contracts.gene`, `policies/*`,
consumers; hashes in `reports/evidence/frozen.sha256`, `tools/freeze.gene check` passes
after every extension task).

| Case | Result |
| --- | --- |
| Root-authored held message over Section / Article / Figure, nested Section, two policies in one process | `b1_recursion`: plain and compact outputs correct; identical on repeat; the tree is untouched between runs |
| Failing control: body-authored `child/.Render:render` | `b1_body_authored`: fails at the first child type whose pair is not imported in the *body's* module, even though the root imported it |
| Late type (Chart, Table) added to existing operations | needs two new extension modules per policy and root edits (`roots/plain.gene` +6/-2 lines, `compact.gene` +4/-0); zero edits to model, contract, container or consumers |
| Control child type with a canonical impl in its own module | `Callout` works with no import anywhere (body-authored and held) |
| Late operation, natural implementation | `Outline` is canonical in its own module; late types own their canonical impl; **no root edit, no `import_impl`, no `each` threading** |
| Late operation as scoped third-party pairs | `b1_late_operation`: identical output; needs a contract module, an impl module, 4-5 root pair imports and threaded `each depth` |
| Cross-protocol bodies (H7) | `b1_h7_context`: see H7 |
| Incomplete root | `b1_incomplete_root`: composes and starts, fails at the first unsupported type with partial effects `["enter S" "figure a"]`; `($runtime/signature op sample)` over a declared sample set reports exactly the 3 unsupported types without running any body, 0 for a complete root |
| Load order (H2) | `b1_load_order_plain_first` / `compact_first` give identical outputs and stable repeated interleaving |

### B2. Scope, transport and typed boundaries (`b2_transport`)

| Operation authored in A (plain) | Host without the pair | B send site (compact visible) |
| --- | --- | --- |
| Raw held Message `(op article)` | `plain:A` | `plain:A` |
| Message through `(Callable [Any] Str)` | `plain:A` | `plain:A` |
| A-authored closure | `plain:A` | `plain:A` |
| A-authored Path `/.Render:render` | `plain:A` | `plain:A` |
| `(article .%op)` | missing impl | `compact:A` |
| Fresh `(Render:render article)` / `article/.Render:render` | missing impl | `compact:A` |
| Callable view used with `.%` | rejected: `expected Message, got CallableView` | rejected |

Also: same-scope invocation and every escaping form give A's body; two separately
authored held messages compare unequal while a message equals itself, so `==` is not
an operation-identity test; a protocol-typed host parameter without the pair rejects
(`parameter 'x' expected Render`); `($runtime/signature op article)` reports
`dispatch_scope authored` for a held message and fails for a fresh one.

Scope placement fixtures (before D1 / after D1):

| Placement | Before | After |
| --- | --- | --- |
| Function body (with or without locals), either installer first | registers in the *defining module*; sibling sees it, outer module does not; a competing installer raises; the first stays intact | compile error (`b2_scope_fn_*`, `d1_reject_*`) |
| Plain `do` / `ns` body at module level | module-wide, as before | unchanged (allowed) |
| Macro-marked block inside a function / message / ctor / spawn / local macro | isolated per block, closures keep policy | unchanged (`d1_marked_scopes`) |
| Eval `import_impl` | refused | unchanged |
| Eval-local `impl` and function-local `impl` | overlay, no leak | unchanged |

### B3. Evolution, defaults and inherited policy

| Case | Result |
| --- | --- |
| Canonical impl added after a scoped plugin pair (`b3_canonical_v1`, `v2`) | v1 plugin policy works; v2 import is rejected with both origins and the migration; the canonical impl stays intact (no partial publication) |
| Mechanical migration (`b3_migration`) | plugin owns a dedicated policy protocol per policy; both policies and the core canonical impl coexist, interleaved, with unchanged outputs |
| Required message added after extensions exist | old extension rejected: `impl Render for Article is missing message: Render/weight` |
| Defaulted message added | old extension stays valid; default body used |
| `^^universal` fallback plus scoped specialization | specialization applies only where imported; an unrelated type keeps the default; an ordinary protocol is **not** equivalent (the unrelated type has no behavior) |
| Independent child impl vs parent pair, either order | rejected: `incompatible established Self bindings`, now with origins and the dependency explanation |
| Child built on the plain parent, composed with compact parent | Article `["c-head" "c-body"]`, Note `["note-head" "plain-body"]` (omitted body keeps the retained plain parent body), as the plan predicted |

### B4. Diagnostics

Before/after text for each retained reproduction is in `reports/evidence/before` and
`after`; summary in section 7.

## 4. Hypotheses

| ID | Verdict | Evidence |
| --- | --- | --- |
| H1 late type and third-party impl through a frozen recursive container with a root-authored operation | **supported** | Chart and Table render through the frozen Section container under P, P-closure, P-typed and F; the frozen-core hash check passes; costs: extension modules, root pair imports, the `each` parameter |
| H2 two policies coexist over one value graph | **supported** | `b1_recursion`, both load orders, repeated interleaving; plain/compact over identical object identities |
| H3 consumers need no impl imports | **supported** | `consumers/preview`, `export`, `outline_report` contain 0 `import_impl` and 0 imports; three consumers use two policies and one canonical operation unchanged |
| H4a canonical addition rejects at load, names both origins, mechanical migration verified | **supported after repair; the origins and migration advice were missing before** | `b3_canonical_v2` (before: bare `duplicate visible impl`; after: both origins plus migration), `b3_migration` reruns the intended outputs and isolation |
| H4b scoped pair surviving a canonical addition | **open owner design question** | not tested as a pass/fail; today the answer is no |
| H5 informed readers predict the selected body | **not assessed** | the optional reviewer exercise was not run; objective comparisons did not leave usability decisive |
| H6 cost of root-authored recursion | **measured, no verdict** | section 6 |
| H7 policy spanning Show and Style selected by the root, providers neutral | **supported with a recorded cost** | `b1_h7_context`: the body-authored second send fails (the control); separate parameters, a raw record and a checked record all select the root's policy and stay isolated across interleaved roots; costs below |

H7 counts (`b1_h7_context`; R = 2 independent policy roots, bracket and star; 2 receiver
types; secondary operation `Mark`). "Consumer edits" is analytic: each of the three Lens
consumers has one `(operation document operation)` call site and was not changed.

| Variant | Contract parameters | Extra type declarations | Annotation sites | Propagation sites in impl bodies | Consumer edits to carry it |
| --- | ---: | ---: | ---: | ---: | ---: |
| Separate parameters | 2 (`each mark`) | 0 | 0 | 2 (recursive call, mark use) | 3 signatures + 3 call sites |
| Raw record | 1 (`ops`) | 0 | 0 | 2 | 3 call sites (`ops/render document ops`) |
| Checked record | 1 (`ops : Ops`) | 1 (`Ops`, 2 Callable fields) | 3 (contract + 2 impls) | 2 | 3 call sites |
| Body-authored second send (control) | 1 | 0 | 0 | 0 | 0, but fails: `Mark` not visible in the body's module |

H7 costs (`b1_h7_context`, Mark selected at the root): separate parameters add one
parameter to the contract and to every recursive call; a raw record adds one parameter
but fails late and opaquely when a field is missing (`cannot call ops/mark: the value is
void (missing)` at traversal); a checked `Ops` record fails at construction (`missing
required field 'mark' for Ops`) but couples the shared schema to every protocol it
carries. A record assembled from two roots mixes policies silently (`S/*a/T/*b`): values
carry the selection, so authoring the record in one root function is the discipline.

## 5. Matched outputs, extension diffs and composition cost

Matched outputs: `tests/integration/lens_spec.gene` (9 tests) checks P, P-closure, P-typed,
F and N against the same goldens for the core tree, the late tree, interleaving, the
three consumers and the third operation (`Weight`, P = 3).

`reports/evidence/composition-counts.json` (text scan; supporting evidence only):

| Set | Files | Code lines | import_impl | `^^export` | `each` tokens | type tests | entries |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| P recursive (T=3, P=2, M=3) | 9 | 66 | 6 | 8 | 13 | 0 | 0 |
| P late additions (T=5, P=3) | 11 | 70 | 15 | 9 | 12 | 0 | 0 |
| P-closure late root (replaces `plain_late`) | 1 | 10 | 5 | 0 | 2 | 0 | 0 |
| P-typed (contract, plain policy, root) | 3 | 28 | 5 | 5 | 8 | 0 | 0 |
| N (named canonical policies + late Chart) | 3 | 25 | 0 | 1* | 0 | 0 | 0 |
| F recursive | 9 | 77 | 0 | 1* | 13 | 6 | 6 |
| F late additions | 8 | 51 | 0 | 0 | 11 | 9 | 9 |

\*a comment mentioning the marker. Root-authored P keeps every pair import at a root
and none in any consumer: 6 `import_impl` for the recursive sample (3 types x 2 policy
roots) and 15 for the late sample (Render 5 types x 2 roots plus Weight 5 types x 1
root), i.e. dense coverage costs P x T x R, not P x T x M.

Reading the table (section 9 rules; no "cleaner" claims):

- **Late type, canonical operation (Outline):** P needs 0 root edits and 0 imports; F
  needs an entry per type in every root. This is the only place P removes a dispatch
  layer rather than moving it, and it works because the type owner supplies the impl.
- **Late type, scoped policies (Render):** P needs per (type, policy) one extension
  module plus one root import; F needs one module with a matcher and handler per
  (type, policy) plus one root list entry. The counts are close (P 5 imports vs F 5
  entries in the late root); P moves type testing into dispatch, F keeps explicit
  matcher functions (9 for the late set).
- **P-closure vs P:** the closure removes the Message value but not the pair imports or
  the `each` threading (2 vs 13 `each` tokens in the *root*; the impl bodies are the
  same).
- **N:** removes threading and root imports entirely, but each type module must name
  every policy protocol and a third policy means editing every type module; scoped
  third-party impls cannot be recursed into (B1 control), so N does not reach the
  third-party-extension case P addresses.
- **Frozen-core promise:** held for all extension tasks (`frozen.sha256` unchanged).

## 6. Cordis contrast (capped: one C control, one P attempt)

Isolated copies in `ports/cordis/{c,p}`; neither touches production Cordis.

- **C control:** canonical `Clock` impl for `CounterClock` in the provider module, explicit
  `provide`/`require` service selection. Output: `reporter observed tick 1`, `host observed tick 2`.
- **P attempt (one pass, well inside the 90-minute cap):** `CounterClock` moved to
  `counter_type.gene`, its `Clock` impl moved to `clock_impl.gene` as an exported scoped
  pair, imported by the provider with `import_impl`, the held `Clock:tick` captured, and a
  canonical `ClockHandle` adapter (owned by the provider module) delegating to it so the
  contract's `check_clock` still passes. Identical output.
- **Cost charged to P:** +2 modules, +1 `import_impl`, +1 adapter type and canonical impl
  (14 code lines in `clock.gene` for C; 23 across three files for P), one extra
  indirection per tick. Unchanged: contract, provider selection, dependency activation and
  retirement ownership.
- **Same stale-provider scenario in both** (`src/stale_probe.gene`): removing the provider is
  rejected before publication, the provider stays available, restoring it is rejected on a
  candidate cleanup failure, the next tick is 3. The cleanup failure (`no implementation of
  message 'tick'` raised in the reporter's effect cleanup) occurs in C and P alike, so it is
  pre-existing and not attributable to P.
- **Conclusion:** Clock is not a natural third-party boundary: the same provider owns the
  type and the behavior and the contract wants a canonical check. This says nothing about
  the root-authored recursive pattern.

## 7. Reload and retained values (Phase 3)

Contract expectation, written before running (`tests/test_modules.nim`, "retained
transports follow their authoring module across reload"): a held Message, a checked
Callable view, an authored closure and a Path resolve at application time in the scope
they were authored in; reload recomposes that scope's imported impl atomically; so after
a same-interface replacement every transport and every send site sees the new body, and a
rejected replacement leaves the published body intact.

| Observation | Before reload | After successful same-interface reload | After rejected reload (export removed) |
| --- | --- | --- | --- |
| Previously warmed send site (author function) | `one` | `two` | `two` |
| Newly authored send (author function first called after reload) | `one` | `two` | `two` |
| Retained raw Message | `one` | `two` | `two` |
| Retained checked Callable view | `one` | `two` | `two` |
| Retained authored closure | `one` | `two` | `two` |
| Retained Path | `one` | `two` | `two` |
| Host send with no pair | missing | missing | missing |
| `implActivationEpoch` | n | n+1 | unchanged |

All rows matched the contract; **no owner decision is needed** for same-interface
replacement. Not covered because no Gene surface reloads a module: reload through a
retained operation whose *author* module is replaced, and lookup-time overlay combinations
beyond the marked-block fixtures.

Lifetime (`tests/test_rc.nim`, `-d:geneRcStats`, "retained transports stay usable across
reloads and release their generations"): a raw Message, a checked view, a closure and a Path
retained across three provider reloads still answer `one`; managed values stay above the
baseline while they live (intentional retention) and return to baseline (leak 0) after every
owner is dropped and two further reloads ran. RSS was not measured; one RSS sample would not
distinguish retention from a leak.

## 8. Repairs and D1 (separate commits on `protocol-message-exp`)

| Commit | Change | Regression coverage |
| --- | --- | --- |
| `edbdaaf0` | **D1**: direct `import_impl` in `fn`, lambda, `message`, `ctor`, `spawn` bodies (also through plain nested blocks, and a `fn` inside a marked block) is a compile error naming the placement and the two alternatives | `tests/test_modules.nim` four D1 tests; 13 boundary fixtures (`d1_reject_*`, `b2_scope_fn_*`) red on the before binary, green on the after binary |
| `b6fedcd0` | Conflict diagnostics name both origins and the Self-binding dependency, give the canonical-versus-scoped migration; hidden-impl advice ignores `import_impl` copies, lists multiple providers, spells a portable `^from`; runtime `import`/`import_impl` resolve relative paths lexically | three diagnostics tests and a lexical-path test (library function and marked block, entry in another directory); boundary fixtures `b4_*`, `b3_canonical_v2`, `b3_inherit_*`, `b2_scope_marked_cross_module` |

D1 acceptance checks (plan section 8.1): every rejected body kind with and without
locals and nested plain blocks (done; a never-called body is rejected); rejection registers
no pair and a prior valid composition stays intact (`D1: a rejected module registers no pair...`);
diagnostic names the placement and the module-root operation-passing / marked-macro
alternatives (done); module-level and in-body marked imports preserved, interleaved
plain/compact/plain/compact (done); an escaping closure keeps its marked-block policy and
module/sibling scopes cannot see it, local macro expansion included (done); nested marked
blocks with conflicting pairs still reject (done); marked imports valid in message, ctor and
spawn bodies (done); ordinary function-local `impl` and eval overlays unchanged (done,
controls in `d1_marked_scopes` and `b2_scope_eval_overlay`); a deferred body inside a
runtime-expanded macro is rejected at the expansion's compile (done).

B4 before/after (retained in `reports/evidence`):

| Reproduction | Before | After |
| --- | --- | --- |
| Exported provider after another module imported it | `scoped and not exported; add ^^export, then import it into <main>` | `not visible in <main>, which governs this check; add (import_impl Render for Article ^from "./prov") there` |
| Duplicate pair | `duplicate visible impl Render for Article` | `... (existing: canonical impl from core.gene; incoming: scoped impl from plugin.gene); a canonical impl applies application-wide ... give the policy its own protocol and pass that operation explicitly` |
| Incompatible Self bindings | `incompatible established Self bindings for Format on Note and Article` | same headline plus both origins and "the child impl must be built while the parent pair is visible" |
| Absolute path in suggested source | `^from "/Users/.../prov.gene"` | `^from "./prov"` |
| Several providers hidden | `exist in 2 modules but none is visible` | the two module paths are listed |

Additional finding fixed with them: `import` / `import_impl` that executes after module
initialization resolved a relative path against the entry module's directory (module loader
state), so a macro-marked `import_impl "./policy"` in a library function failed with
`MODULE_NOT_FOUND` when called from another directory. This broke the very pattern D1 retains.

## 9. Performance (H6 and the dispatch matrix)

No performance limit applies (owner decision A2); these are measurements with their data
quality. Release binaries only; per-round load averages are in each `summary.json`.

### 9.1 H6: root-authored recursion over the frozen 1,000-node tree

Fixture: `bench/h6/tree.gene`, depth 8, Section 234 / Article 466 / Figure 200 / Chart 100,
SHA-256 `48aa4313b71b676bc1572bbf824b4e6d5840dfc8546a23132387ee8b2d3b0dd8`; every variant
returns the same 12,463-byte result (SHA-256 `48ec2344cd94...`) and visits 1,000 nodes.
Median microseconds per complete traversal (input construction, fixture check and operation
acquisition excluded; the operation is applied at every node):

| Batch | Binary | F | F-typed | P | P-closure | P-typed |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 (7 rounds x 300 traversals, load 3.0-4.1) | before | 2,123 | 4,247 | 4,367 | 2,983 | 6,287 |
| 1 | after | 2,143 | 4,207 | 4,427 | 3,020 | 6,423 |
| 2 (reversed order, 7 x 250, load 2.8-3.9) | before | 2,140 | 4,196 | 4,300 | 2,992 | 6,308 |
| 2 | after | 2,148 | 4,248 | 4,360 | 3,024 | 6,420 |

Paired per-round ratios to F (median, [min, max] over the 7 paired rounds):

| Ratio | Batch 1 before | Batch 1 after | Batch 2 before | Batch 2 after |
| --- | --- | --- | --- | --- |
| P / F | 2.06 [1.96, 2.07] | 2.04 [2.03, 2.10] | 2.01 [1.98, 2.05] | 2.03 [2.00, 2.08] |
| P-closure / F | 1.42 [1.33, 1.44] | 1.41 [1.39, 1.44] | 1.40 [1.37, 1.48] | 1.42 [1.39, 1.43] |
| P-typed / F | 2.96 [2.82, 3.00] | 3.00 [2.93, 3.09] | 2.95 [2.93, 2.98] | 2.99 [2.98, 3.05] |
| F-typed / F | 1.97 [1.90, 2.01] | 1.97 [1.94, 1.99] | 1.96 [1.91, 2.02] | 1.98 [1.94, 2.00] |
| P-typed / F-typed | 1.49 [1.46, 1.53] | 1.53 [1.49, 1.56] | 1.50 [1.45, 1.55] | 1.52 [1.50, 1.54] |

Status: two independent batches at low load agree to within about 3%, so the differences
are stable for this fixture (checksums and node counts identical in all 140 timed samples).
The repairs change no measured cost (before and after agree). Observations without a
verdict: P costs about 2.0x F; the closure carrying the same pairs costs about 1.4x; the
checked `(Callable [Any Any] Str)` contract adds about 2.0 ms per traversal (~2 microseconds
per node) to F and to P alike, so most of P-typed's extra cost is the Callable contract,
not protocol dispatch (P-typed / F-typed is 1.5 and F-typed / F is 2.0). These are
microbenchmark-weight bodies; a heavier transform would shrink every ratio and is a
separate workload that was not run.

### 9.2 Dispatch matrix (net ns/op, empty loop subtracted, medians)

`bench/run_matrix.gene`, 7 rounds after a warm-up, fresh worker per cell, rotating order.
Batch 1: 200,000 iterations, load 4.2-4.8 (qualified). Batch 2: 300,000 iterations, medians
agree with batch 1 but rounds 4-7 ran at load 6.6, 7.3 and 49 (a daemon storm), so its
ranges are **contaminated** and only its medians are reported. Module and entry layouts and
the before and after binaries agree.

| Row | Module layout | Entry-file layout | Batch 2 module / entry |
| --- | ---: | ---: | ---: |
| function call | 150 | 150 | 150 / 150 |
| closure | 170 | 170 | 167 / 167 |
| type-direct send | 205 | 205 | 193 / 193 |
| qualified send, monomorphic | **280** | **280** | 267 / 277 |
| closure over a qualified send | 455 | 460 | 443 / 450 |
| type-direct send, alternating receivers | 340 | 335 | 333 / 320 |
| raw held Message | **1,885** | **1,875** | 1,900 / 1,850 |
| dynamic `.%` send | 1,885 | 1,890 | 1,907 / 1,890 |
| checked Callable view | **2,605** | **2,600** | 2,590 / 2,610 |
| qualified send, alternating receivers | **1,970** | **1,975** | 1,940 / 1,933 |
| held, alternating receivers | 1,915 | 1,925 | 1,883 / 1,927 |
| qualified send with an activation-local overlay (uncached by design) | **1,975** | **1,955** | 1,970 / 1,953 |

Findings:

1. **The plan's inherited lead does not reproduce.** The review's "entry-file sends cost
   ~1,950 ns vs ~330 ns in an imported module" is not a layout effect: with declarations
   and sends in the entry file, a monomorphic qualified send is 280 ns, identical to the
   imported-module layout. The review's slow case was an uncached path, not the entry file.
2. Four mechanisms land on the same ~1,900-2,000 ns plateau: a held Message, a dynamic
   `.%` send, a qualified send that alternates receiver types at one site, and a send
   whose scope holds an overlay impl. A monomorphic qualified send takes the inline cache
   (280 ns, 130 ns above a function call).
3. **Mechanism (profile, not guess).** `reports/evidence/raw/profile-held-call.txt`
   (macOS `sample`, 4 s of a held-message loop): 81% of 3,052 samples are under
   `resolveQualifiedSend` and 69% under `collectProtocolMatches`, dominated by
   `receiverDistance` and its retain/release traffic, i.e. a full resolution on every
   application. In source, an applied bound message calls `resolveQualifiedSend` and has
   no dispatch-cache site; the per-site cache holds one entry (recvType, message, epoch),
   so alternating receivers evict each other; `chainHasTransientImpls` deliberately refuses
   to cache a scope that holds an overlay.
4. The uncached path grows with the visible impl set. `raw/impl-scale.jsonl` (6 rounds, first
   excluded; started at load ~20 so indicative, ranges within 3%): held 1,860 / 2,950 /
   6,067 ns and alternating qualified 1,930 / 3,010 / 6,200 ns with 0 / 50 / 200 unrelated
   impls on the receiver type, about **21.7 ns per visible impl**; the cached monomorphic
   send stayed at 300 ns for all three sizes.
5. The checked view costs ~700 ns more than the raw Message on top of the same resolution.
6. **H6 context, without a named cause.** P applies a held Message at every node, and its
   extra ~2.2 microseconds per node over F is the size of the uncached plateau above, but the
   traversal was not instrumented for per-site hit rates, so this is consistent with, not
   proof of, that mechanism. P-closure's smaller gap (~0.9 microsecond per node over F) is
   unexplained: its send site also sees four receiver types, and a partial hit rate from
   runs of equal sibling types is a hypothesis, not a measurement.

### 9.3 Not measured

A macro-marked-block or eval overlay send (only the equivalent activation-local `impl`
overlay was timed; the cache refusal is the same `chainHasTransientImpls` check by source
reading); cold first-resolution cost per site; timing of the warmed unrelated call site across a
reload (reload has no Gene surface; its correctness is covered in section 7; the epoch bump
forces one re-resolution per site per reload by source reading, unmeasured); peak RSS;
the extended `vm.protocol_message.*` Nim rows (section 9.4). The optional reviewer exercise
(H5) was not run.

### 9.4 Core benchmark rows

`benchmarks/bench_core.nim` gains `vm.protocol_message.held`, `.callable_view`, `.dynamic` and
`.closure` rows (their own scope; operation acquired once outside the loop). One pass of the
release build at load ~5, so **indicative, not a qualified paired batch** (gross ns/op
including `run` entry, 500,000 iterations; raw in `evidence/raw/bench_core-protocol-rows.txt`):
one-argument Gene call 392, trivial-body qualified send 562, qualified send 635, type-direct
send 467, **held 3,099, dynamic 2,986, checked view 4,060**, closure over a qualified send 778.
The ratios match the Gene matrix: a held or dynamic call costs about 4.9x a cached qualified
send in gross terms (6.7x net), and a checked view about 1.3x a raw held call.

## 10. Improvement plan

Priorities follow plan section 9: correctness and lifetime first (none open), then
composition and diagnostic obstacles, then performance justified by application cost.

**Correctness gate:** no unexplained wrong-body selection, policy leakage, invalid partial
publication or unsafe retained value was found. All current-contract surprises are listed as
design limits, not defects: independent subtype impl rejection, third-party recursion through
body-authored sends, the retained-body behavior of a child built on a parent, `==` on
held messages being identity-per-authoring.

### Protocols and qualified sends

- Evidence for: canonical type-owner and operation-owner impls make late types and late
  operations free of root edits and threading (`Outline`); N (named policy protocols) works
  without threading.
- Contrary evidence: the same pattern cannot reach third-party types (N needs each type
  module to name every policy; a scoped impl is invisible to a canonical body).
- Next: keep as is; document the three ownership routes (below).

### Exported scoped impls and `import_impl`

- Evidence for: H1-H3, H7 pass with root-authored operations; consumers import no impls;
  the migration for a later canonical impl is mechanical (`b3_migration`).
- Contrary evidence: third-party recursion only works through root-authored threading; the
  threaded `each` parameter must exist before the container is frozen; incomplete roots fail
  at traversal; Section 9.2 shows the dispatch cost when many types share a site.
- Done: D1, diagnostics, lexical path (section 8).
- Next actions, in order:
  1. **Documented pattern** (done here): `docs/protocol-composition.md` records root-authored
     operations, the contract-first rule, and the ownership routes.
  2. **Pre-flight helper** (library, no new syntax): wrap `($runtime/signature op sample)` over
     a declared sample set as a stdlib helper; acceptance: reports exactly the unsupported types
     for `b1_incomplete_root` without running a body. Prototype is in that fixture.
  3. **Operations-record helper** (library): a typed record builder checking required fields at
     construction (already the behavior of a nominal record); decide only after a second use
     case beyond Show/Style.
- Owner decisions open: H4b (compatibility of a scoped pair with a later canonical addition
  without migration); whether to extend D1's rejection to `scope`/`supervisor` bodies.

### Held messages

- Evidence for: authored-scope transport works through Callable views, closures, Paths and
  reload; the profile puts a raw held call's cost in the uncached resolution, not in the
  Message value itself.
- Contrary evidence: held and dynamic calls are ~7x a cached send and ~12x a function call;
  a checked view adds ~2 microseconds per call; `==` does not identify an operation.
- Proposals (no semantic change; each needs the existing dispatch-cache soundness suite plus
  new cases):
  1. **Cache bound-message application and make site caches polymorphic (2-4 entries).**
     Key a held call on (bound-message authored scope serial, qualifier, name, receiver type,
     `implEpoch`) with a transient-scope refusal; acceptance: the `held`, `dynamic` and
     `qualified_alt` rows within 1.5x of the monomorphic `qualified` row, H6 P/F near 1.3,
     `vm.protocol_message.*` unchanged, all D1-cache soundness tests green.
  2. **Per-call view reuse for repeated equivalent `(Callable ...)` contracts**; acceptance:
     F-typed / F below 1.3 and unchanged rejection behavior.
  3. **Define equality and inspection for held messages** (owner decision): either
     `(protocol, name, authored scope)` identity or only `($runtime/signature ...)`
     `contract_identity`; today two authorings of the same message are unequal.

### Overlays and reload

- Evidence for: every retained transport follows reload, rejected reload preserves published
  behavior, no managed leak after owners drop; macro-marked blocks isolate per block.
- Contrary evidence: an overlay on the send scope forces the ~2,000 ns uncached path, so
  heavy use of block-scoped policies in hot code costs the plateau above.
- Next: after proposal 1, add a cache keyed on the overlay's activation identity or measure
  whether marked blocks in hot loops matter in a real application first.

### Cordis and sparse adoption

Clock is not a third-party boundary; the repository has no executable `import_impl` use
because its extension points (service keys, plugin specs) bind providers by value, which this
experiment finds is the right abstraction there. The Document Lens pattern, not Cordis, is
where scoped impls compose; keep `examples/protocol-message-exp` and
`docs/protocol-composition.md` as the executable adoption example.

## 11. Completion checklist (plan section 10)

| Required item | Where |
| --- | --- |
| Provenance and commands | section 1, `README.md` |
| Thin existing-coverage confirmation | section 1 |
| Boundary results, expected failures, unresolved semantics | sections 2-3, 10 |
| H1-H3, H4a, H5, H7 verdicts; H4b; H6 times and ratios without a limit | section 4, 9 |
| Matched outputs, late-extension diffs, composition cost | section 5 |
| Cordis C/P contrast | section 6 |
| Transport and reload matrices | sections 3 (B2), 7 |
| Raw performance evidence or early-stop statement | `reports/evidence/raw`, section 9 |
| Diagnostic defects and separate repair commits | section 8 |
| D1 owner decision and implementation status | section 8 |
| Prioritized improvement plan | section 10 |
