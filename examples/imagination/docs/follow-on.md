# Imagination follow-on design: merge, restoration, replay, and other media

**Status:** design, not scheduled  
**Depends on:** the first release described in [design.md](design.md)

This document holds the parts of the Imagination design that are not in the first release: three-way semantic merge, partial restoration, adaptive replay, a generic media protocol, and a raster backend. They were split out so that the first release can start without them. Section 6 lists what each of them adds to the first-release design.

Revisit this document after the drawing-loop spike (milestone 2 in [design.md](design.md)). If a model cannot reliably draw and correct a picture through patches, there is little worth merging, and this design should change before anyone builds it. Section numbers below are local to this document; "the first-release design" means `design.md`.

## 1. Three-way semantic merge

### 1.1 Merge inputs and base selection

Merge takes left revision `A`, right revision `B`, and common base `O`. Compute `diff(O, A)` and `diff(O, B)` from full snapshots, not just edit-message summaries. An intent can describe an attempted change that did not actually occur.

Find maximal common ancestors in the revision DAG. If exactly one exists, use it. If there are several incomparable bases, return `ambiguous_base`; the initial implementation requires an explicit chosen base or a reviewed synthesized base. Do not select whichever ID sorts first. If histories are unrelated, use a separately named composition/transplant operation with explicit object mapping; do not pretend it is an ordinary three-way merge.

```gene
(merge_request
  ^left "r003a"
  ^right "r003b"
  ^base "r002"
  ^goal "goal-merge-01"
  (instruction
    "Keep A's readable cat and B's rainy night atmosphere."))
```

The effective merge goal includes current explicit user requirements and selected branch intentions. If branch goals disagree on a hard requirement, record a goal conflict before drawing. An agent-created compromise cannot override a user's explicit “white cat” requirement.

### 1.2 Structural merge rules

Use an explicit missing-value marker internally. A missing field differs from a field containing `nil` or an empty string. For a mergeable atomic field, apply:

| Relative to base | Resolution |
| --- | --- |
| Neither side changed | Keep base |
| Only A changed | Take A |
| Only B changed | Take B |
| Both changed to the same canonical value | Take that value |
| Both changed differently | Record conflict |

Additional rules:

- Delete/delete resolves to deletion. Delete versus an unchanged subtree resolves to deletion.
- Delete versus any edit, new descendant, reparenting, or new incoming reference is a conflict.
- Concurrent additions with different globally allocated IDs can coexist, subject to ordering and visual review.
- A duplicated ID with divergent lineage is an identity conflict, never proof of object equivalence.
- Distinct fields may combine, but cross-field invariants still require validation.
- Path geometry is atomic in v1. Transform components can merge separately, subject to parent-space dependency conflicts.
- An ancestor transform or reparenting on one side plus dependent descendant geometry edits on the other is marked for semantic review even if the immediate field keys differ.
- Resource deletion/modification versus new consumers, and edits to locked effective appearance through a resource, require conflict/dependency handling.

For ordering, represent actual reordered IDs with before/after relations derived from stable anchors. Merge only changed order constraints plus unchanged base constraints not explicitly displaced by either side. Topologically sort the resulting sibling constraints, using base order and then stable new-ID order only for unconstrained ties. A cycle or incompatible parent assignment is a conflict. Record tie choices, since paint order can affect appearance even when the ordering graph is satisfiable.

This produces an initial merged scene, a conflict list, and a dependency/visual-risk list. Structural nonconflict does not prove visual independence.

For a preview, unresolved atomic conflicts temporarily retain the left value and are visibly marked as unresolved in the plan, never as a final resolution. If hierarchy/resource conflicts prevent any valid provisional scene, send base/A/B images without a provisional render and resolve those conflicts first. Render only validated drafts. Reserve fresh ID allocation for synthesized additions before each model call.

### 1.3 Conflict record and merge plan

```gene
(merge_plan
  ^schema 1
  ^id "merge-plan-01"
  ^base "r002" ^left "r003a" ^right "r003b"
  ^goal "goal-merge-01"
  ^status "needs_resolution"
  (take ^source "left" ^target "cat" ^scope "geometry")
  (take ^source "right" ^target "city" ^scope "subtree")
  (conflict
    ^id "conflict-01" ^kind "field"
    ^target "cat-body" ^field ["fill"]
    ^base "#c8894b" ^left "#f7edd8" ^right "#161c2c"
    (left_intent "Make the subject readable against the dark background.")
    (right_intent "Preserve a mysterious night silhouette.")))
```

Every conflict has stable ID, kind, affected objects/fields, base/left/right values or snapshot references, dependencies, relevant locks/requirements, and proposed resolutions. A plan is reviewable data; it is not a completed merge revision.

### 1.4 AI resolution

Give the model the clean base, A, B, provisional merge image, computed diffs, conflict records, relevant subtrees, intentions, and effective goal. Label each image explicitly. The model returns a constrained `merge_resolution` with a decision for every conflict and an optional patch against the provisional scene digest.

```gene
(merge_resolution
  ^schema 1 ^plan "merge-plan-01"
  ^draft "merge-draft-01" ^scene "sha256:PROVISIONAL_SCENE_DIGEST"
  (resolve ^conflict "conflict-01" ^decision "synthesize" ^operations [0 1 2]
    (explanation "Keep a dark silhouette and recover readability with an outline."))
  (patch
    ^schema 1 ^id "merge-patch-01"
    ^base_draft "merge-draft-01" ^base_scene "sha256:PROVISIONAL_SCENE_DIGEST"
    ^goal "goal-merge-01"
    (intent "Preserve atmosphere and subject readability.")
    (set ^target "cat-body" ^field ["fill"] ^value "#161c2c")
    (set ^target "cat-body" ^field ["stroke"] ^value "#9ac8ef")
    (set ^target "cat-body" ^field ["stroke_width"] ^value 4)))
```

Bind a synthesis decision to its affected operations; an explanation without an executable value/change does not resolve a conflict. Validate the plan ID, draft digest, complete conflict coverage, and each operation's scope. Additional coherence edits can affect other unlocked fields only when explicitly listed and justified in the merge plan.

Allowed decisions are `take_left`, `take_right`, `take_base`, `synthesize`, or `defer`. A synthesis must state which intentions it preserves and which it sacrifices. The interpreter validates all generated operations, checks locks, and recomputes the actual change. Never let free-form merge commentary bypass the ordinary drawing interpreter.

For the cat-color example, the model may synthesize a dark cat with a brighter outline. That can preserve B's atmosphere and A's readability if color itself is not a hard requirement. It is a new artistic choice, not an exact preservation of both source appearances.

When goals are ambiguous or incompatible, preserve the unresolved plan and optionally create alternative candidate revisions. Ask for the user's creative choice through the UI rather than inventing a preference. Obvious independent changes can be automatically combined and checked without interrupting the user.

### 1.5 Materialization and verification

1. Apply deterministic field resolutions and resolved ordering.
2. Apply validated AI synthesis operations; track source provenance per object/field.
3. Validate the complete scene and reference graph.
4. Render the merge and inspect it against the effective goal and preservation obligations.
5. If needed, perform at most a configured number of repair edits on the provisional merge, preserving the selected source decisions.
6. Publish a merge revision only when all structural conflicts are resolved. A valid unresolved preview can be saved as an ordinary trial revision based on A with a merge-plan reference. A structurally resolved but visually poor combination can be a two-parent trial merge.
7. Advance the target line only when the result passes its acceptance policy.

The merge revision stores `[A, B]` as parents, `O` as merge base, the resolution record, source-selection/synthesis provenance, and the executable normalized patch **from A to the final merged snapshot**. Verify applying that patch to A reproduces the saved scene digest. Also store `diff(B, merged)` for comparison; do not claim one patch is executable against both parents.

If repair edits occur before publication, keep their drafts and run events; optionally expose them as trial revisions. The final merge revision remains a truthful two-parent combination. Subsequent ordinary refinements have the merge revision as their single parent.

### 1.6 What merge must not claim

A renderer can combine fields exactly. AI evaluation can still be wrong about visual coherence. Use statuses that distinguish structurally merged, visually reviewed, and user accepted. Do not claim intentions were preserved merely because both intent strings were copied into metadata.

An exact field conflict is not the only problem. Independently added objects can overlap, a background can reduce subject contrast, and a new composition can break typography. These issues are detected by dependency analysis and the rendered-image loop.

## 2. Partial restoration and transplantation

“Keep this version, but restore the cat from an earlier step” creates a new revision based on the current target. It does not change either source revision.

Selections are explicit: an object's complete subtree, geometry, appearance, text, transform, or a list of field paths. Expand referenced gradients, clips, and other required definitions into a dependency closure. Record the exact expansion so “restore appearance” cannot silently import an unrelated background.

```gene
(restore_request
  ^target_revision "r010"
  ^source_revision "r007"
  ^target_object "cat"
  ^source_object "cat"
  ^scope "geometry"
  ^placement_policy "keep_target_transform")
```

An object that existed in both revisions preserves its identity. A subtree resurrected from history reuses its historical IDs if those IDs are absent from the target. A copied independent duplicate receives freshly allocated IDs and an explicit mapping. Never equate unrelated objects only because both have the label “cat.”

Geometry restoration keeps the current transform by default. Complete-subtree restoration explicitly chooses source-local, source-world, or target-placement behavior. If the selected geometry/resource references cannot be installed safely, return a conflict and request a resolution.

Finish with the same render/evaluate loop as other edits. A source cat may look excellent in its original composition and poor in the target composition.

Selecting the character from A, the background from B, and the composition from C is a multi-source transplant. Store the selected sources and dependency mapping as provenance. In v1, the resulting revision has the target as its sole parent and source revision references in its derivation record; it is not mislabeled as a two-parent merge. More general multi-parent revision semantics can be introduced later.

## 3. Replay and adapting later improvements

Distinguish three operations:

| Operation | Guarantee |
| --- | --- |
| Exact replay | Reapply stored normalized operations to their exact recorded bases, without a model call |
| Re-evaluate | Inspect a saved artifact with a new reviewer; do not alter its scene/history |
| Adaptive replay | Reapply the intentions of later edits onto a different base, potentially generating new geometry |

Exact replay verifies scene digests at every step. It never calls the model, even if the model name and seed were saved. Model calls are not guaranteed to reproduce the same output later.

For adaptive replay, the user chooses a linear source path and a new base. For each source edit, compare its old preconditions with the new current state. Apply its original operation only if its dependency footprint and goal remain compatible; otherwise propose a new patch using the saved intent, old before/after images, and new image. Render and evaluate each new state.

For example, after correcting the cat's proportions at an early revision, reapply the later “add sunset” and “add birds” intentions to the corrected scene. Do not blindly reuse the old outline coordinates if the cat's size has changed.

Each adaptive result has the new previous revision as its parent and records `replayed_from`, original intent, adaptations, and source-path choice. Keep the original line intact. If the source path crosses a merge, require an explicit first-parent path or named parent choice; do not replay both parent patches as if they were sequential.

Stop and preserve the last usable new revision when a source object no longer exists or intentions conflict with the new goal. The first release may implement exact replay and expose adaptive replay as an explicit later milestone.

## 4. A generic media protocol

The reusable part is typed evolution of creative state. The SVG implementation supplies the meaning of geometry, rendering, diff, and visual dependencies.

```text
Media[T]:
    descriptor() -> versioned media/schema identity
    validate(value, policy) -> ValidationReport
    canonicalize(value) -> bytes
    decode_snapshot(bytes) -> immutable T
    apply(value, patch, policy) -> Candidate[T, normalized_effects]
    compare(base, changed) -> Diff[T]
    merge_structure(base, left, right, policy) -> MergePlan[T]
    dependencies(value, selection) -> DependencyClosure
    render(value, profile) -> ArtifactBundle
    summarize(value, selection, limit) -> bounded Gene data
    evaluation_inputs(artifacts, goal) -> multimodal input bundle
```

The `Evolution` type handles ancestry, publication, reference updates, persistence, and provenance. The media adapter handles domain structure. The agent handles proposed artistic decisions. Do not put SVG-specific property rules into the generic history engine.

| Future domain | Authoritative state | Domain-specific merge dependencies |
| --- | --- | --- |
| Document | Sections, paragraphs, citations, style roles | Cross-references, numbering, argument consistency |
| Slides/UI | Component tree and layout constraints | Layout, typography, state transitions |
| Music | Tracks, notes/events, instrument state | Timing, harmony, tempo, phrase boundaries |
| Video | Shot/clip graph, timeline, effect parameters | Time alignment, continuity, linked audio |
| 3D | Scene graph, geometry/material references | Coordinate frames, topology, lighting |

These are extension points, not promised implementations. A domain may need audio or video perception instead of a still-image observer. Its replay and merge guarantees must be declared separately.

## 5. Optional textual raster backend

### 5.1 Why not make a flattened text bitmap the main state?

A plain text list of every pixel is easy to specify but expensive for a model to edit and poor at preserving object identity. A flattened bitmap can be an export format; it should not replace layered editable state when history and semantic merge are core features.

If raster work becomes necessary, implement `RasterScene` behind the same `Media` interface. Use stable layers, integer coordinates, bounded drawing operations, and immutable tile payloads. The model writes a compact drawing program; the runtime materializes pixels.

### 5.2 Suggested data format

```gene
(raster_scene
  ^schema 1 ^width 256 ^height 256 ^color_space "srgb"
  ^background "#101827ff"
  (palette
    (color ^id "ink" ^rgba "#111827ff")
    (color ^id "light" ^rgba "#f4d4a5ff"))
  (layer ^id "background" ^blend "source_over" ^opacity 1
    (tile ^x 0 ^y 0 ^width 32 ^height 32 ^encoding "row_rle"
      ^blob "sha256:TILE_DIGEST"))
  (layer ^id "cat" ^label "Sitting cat" ^blend "source_over" ^opacity 1))
```

Tile blobs are immutable pixel data, encoded as bounded row runs of palette entries or RGBA values. Empty tiles mean transparent pixels. Every row must decode to the declared width and every tile to its declared height. Do not allow overlapping tiles within a layer or unbounded compressed expansion.

Operations include `fill_rect`, `draw_line`, `fill_polygon`, `paint_span`, `replace_tile`, `clear_region`, and layer translation/order. Each materialized scene references complete current tile contents. Keep operation history outside the snapshot to avoid needing to replay thousands of strokes just to view one revision.

Choose one color/compositing specification before implementation: palette colors are encoded sRGB, operations convert to linear premultiplied RGBA for source-over blending, and PNG export converts back to straight encoded sRGB. Define pixel-center sampling, line rasterization, rounding, clipping, and antialiasing as versioned rules. Limit v1 to integer-aligned, non-antialiased primitives and integer translations to make replay precise.

Raster three-way merge operates by layer identity and changed tile regions. Distinct layers can combine structurally; overlapping changes within a tile require a conservative conflict or an explicit pixel-mask resolution. A model can propose synthesis by issuing raster operations. It cannot infer exact object ownership from a flattened PNG.

Start with small pixel art if this backend is added. SVG remains the first example's complete and required route.

## 6. Integration with the first-release design

The first release keeps the data these features need: complete snapshots per revision, original operations with before/after effects, a `^parents` list, stable object IDs with a project-wide allocation registry, and intent on every patch. This section collects what the features add.

### 6.1 Evolution and agent operations

```text
Evolution.plan_merge(left, right, base?, policy) -> MergePlan[T]
Evolution.materialize_merge(plan, resolution) -> Draft[T]
Evolution.restore(target, source, selection) -> Draft[T]
Evolution.replay(source_path, new_base, policy) -> ReplayPlan[T]
VisionAgent.resolve_merge(merge_bundle, response_schema) -> MergeResolution
```

A merge revision has two ordered parents, `[left, right]`, and an explicit merge-base reference. The first parent defines the baseline for the stored executable patch; it does not silently win conflicts.

### 6.2 Patch and interpreter additions

**Draft-based patches.** A normal patch has `base` referencing a stored revision. A patch used during merge preparation instead has `base_draft` and `base_scene`, identifying an application-issued draft ID and its current canonical scene digest. Exactly one base form is allowed. A draft patch is accepted only inside its owning operation, against that exact digest; it does not authorize mutation of an arbitrary stored revision.

**`attach_snapshot`.** A runtime-owned mechanism that imports a validated subtree from a pinned source revision with proven lineage. It allows historical restoration and importing B's additions into a merge based on A. It passes the same scene, lock, reference, and transaction checks as `add`, and is not accepted in ordinary model responses. An ID may be absent from the target scene while already belonging to the same historical object; this is different from allocating a new identity.

**Dependency footprints.** Every normalized effect gains the sets of fields it read and wrote:

```gene
(effect
  ^operation_index 1
  ^target "cat"
  ^field ["translate"]
  ^before [350 700]
  ^after [326 700]
  ^reads ["cat.translate" "cat.parent"]
  ^writes ["cat.translate"])
```

Real footprints use structured keys, not dotted strings. Include hierarchy, sibling order, resource references, and relevant ancestor transforms. The runtime computes these sets; model-supplied declarations are advisory only. For revisions made by the first release, compute them by re-running the stored original operations against the stored base snapshot.

### 6.3 Interface additions

| Surface | Additions |
| --- | --- |
| History actions | "Combine these versions" plans and verifies a semantic merge; "Restore this part" creates a new revision using selected source fields/subtrees; "Apply later improvements here" runs adaptive replay from a corrected base |
| Workbench panels | Merge panel: left/right/base previews, source intentions, conflicts, proposed resolutions, result preview. Restore panel: source revision/object, fields/subtree selection, placement policy, dependency summary |
| Workbench behavior | "Combine these versions" starts a merge job, defaulting to a new result line. Independent compatible changes can be combined automatically; ambiguous goal conflicts display choices. "Restore this part" previews the selection and its dependency closure, then creates a new revision through the ordinary validated application operation |
| CLI | `imagination merge <project> --left <r> --right <r> --line <name> --instruction "..."`; `imagination restore <project> --onto <r> --from <r> --object <id> --scope <scope>`; `imagination replay <project> --path <a>:<b> --onto <line> --mode adaptive` |
| API under `/api/v1` | `POST /projects/{p}/merges` creates a merge job/plan with explicit parents and instruction; `POST /projects/{p}/merge-plans/{m}/resolve` submits validated conflict choices against a plan version; `POST /projects/{p}/restores` creates a partial restoration/transplant job; `POST /projects/{p}/replays` gains an adaptive mode |
| Events and errors | A `merge_conflict` event; an `unresolved_goal_conflict` error |
| Limits and failures | Merge repair iterations: 3 after structural resolution. Semantic merge unresolved: save the plan/conflicts and keep both source versions intact |
| Modules | `merge.gene` (base selection, structural plans, conflicts, resolution validation), `restore.gene` (selections, dependency closure, identity mapping, transplantation), and adaptive replay planning in `replay.gene` |

### 6.4 Milestones

These follow the four first-release milestones.

**Follow-on milestone A: structural and AI-assisted semantic merge**

Implement common-base discovery, three-way field/tree/order rules, dependency conflicts, reviewable merge plans, AI resolution, and visual verification. Add partial restoration with dependency closure and working merge/restore panels in the web frontend.

**Exit condition:** combine independent subject/background improvements; resolve a conflicting subject appearance while honoring requirements; preserve both parents and reproduce the final snapshot from the first-parent merge patch.

**Follow-on milestone B: adaptive replay and richer exploration**

Implement correcting an early scene and adapting later intentions onto it, multi-source transplantation, goal steering, alternative resolution candidates, and richer viewer interactions.

**Exit condition:** a geometry correction does not get undone by later reused coordinates, all new revisions record derivation, and the original line remains available.

**Optional milestone: textual raster media**

Add `RasterScene` only after the SVG example demonstrates the full loop and merge. Verify the generic evolution engine does not need SVG-specific changes.

### 6.5 Tests and acceptance scenarios

Merge fixtures:

| Fixture | Expected result |
| --- | --- |
| A changes cat geometry; B changes city colors | Deterministic combination followed by visual review |
| Both set the same fill value | One canonical value, no field conflict |
| A removes cat; B changes its pose | Delete/edit conflict |
| A changes parent transform; B edits child coordinates | Dependency review, even with distinct field keys |
| A removes a gradient; B adds a consumer | Resource conflict |
| Branches impose incompatible sibling order | Ordering conflict, no arbitrary silent choice |
| Independently added objects overlap | Structural merge may pass; visual review must flag the overlap |
| Several incomparable common bases exist | Explicit ambiguous-base status |
| A wants white for contrast; B wants dark for mood | Optional synthesis if no hard color requirement exists |
| User explicitly requires white cat | Synthesis cannot quietly produce a black cat |

For the independent-edit fixture, also assert two-parent ancestry, stored base, provenance, and first-parent patch replay. Test a restore operation that pulls a referenced resource and a transplant that requires fresh ID mapping.

Live examples to add to the first-release set:

1. Two branches from the cat-at-a-window example: improve the cat in one and the city atmosphere in the other; combine them.
2. A correction to an early subject proportion followed by adaptive replay of later decorative edits.

Web acceptance scenarios to add:

1. Compare two versions, combine them on a new line, resolve a surfaced conflict, and inspect the reviewed result and both parents.
2. Restore selected geometry from an older revision and verify its dependency/provenance record.
