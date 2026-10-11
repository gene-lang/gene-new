# Imagination design and implementation review

Reviewed 2026-10-11 against commit `0c90a8b`. The findings below describe that
review baseline. All six have subsequently been fixed; no raster implementation
was introduced by these fixes.

## Resolution

- Request receipts now claim work durably before effects, serialize concurrent
  retries, check canonical request fingerprints and survive workbench restart.
  Project creation, line/run/selection operations and job cancel/steer/resume use
  the same mechanism. A stopped attempt without a committed receipt returns
  `idempotency_incomplete`; it never blindly repeats an uncertain effect.
- Steering consumes only its captured prefix in the same transaction as the goal
  update. Later arrivals stay queued and prevent premature completion. Goal IDs
  are reserved before planning, so concurrent plans cannot allocate one ID twice.
- Render bundles are verified in staging and published by directory rename.
  Incomplete unreferenced destinations can be retried; bundles referenced by a
  revision or committed event remain protected from automatic replacement.
- Profiles carry fingerprints of their stable configuration, executable bytes,
  versions and font digests. Reopen compares them and releases resources on
  refusal. Legacy profiles compare every field they recorded, excluding paths;
  comparisons do not claim equivalence for un-fingerprinted historical bundles.
- Model admission reserves calls before dispatch, including planners, reviewers
  and failures. Resume retains usage, attempted edits and the original absolute
  wall deadline. The deadline includes time between resumes; a new allowance
  requires a new run. Overlong calls are cancelled at the deadline.
- Recursive cleanup now removes empty directories explicitly without following
  symlinks. Raster design references now match the actual Gene/WebSocket client
  and identify the Media interface as proposed rather than implemented.

Validation after fixes: **120 tests pass**, including 16 new regressions in
`tests/reliability_spec.gene`. The three saved SVG drawing transcripts still pass.
The original probes below are retained as historical reproduction evidence.

The SVG application is a useful foundation: model output is parsed as bounded
domain data, patches are validated atomically, revisions retain their inputs and
rendered evidence, and completion is bound to the observed image and goal.
The current history implementation deliberately knows about SVG; the proposed
generic Media protocol has not been implemented yet.

## Validation

The documented `gene test` command, run from `examples/imagination` using the
current private release build, passed all 104 tests. Additional Gene probes
reproduced the six findings below without model/network calls. The probes and
output are in ignored scratch files:

- `examples/imagination/tmp/review_probe.gene`
- `tmp/imagination-review-probe.log`
- `tmp/imagination-review-tests.log`

The concurrency probes inject a callback at the same boundary where a real
model request yields. The publication probe simulates interruption immediately
after creating the final bundle directory. These are targeted fault/interleaving
tests, not claims that those failures occurred in the recorded live drawings.

## Findings

### P1: Concurrent retries can perform an operation twice

Location: `src/server.gene:378–393`, `idempotent`.

The helper checks for a receipt, executes the entire body, then stores the result.
Two requests with the same key can both pass the check while the first body is
awaiting planning/rendering. The project-scoped branch similarly stores its
receipt after the operation, outside its transaction; INSERT OR IGNORE cannot
undo the duplicate operation. It also does not bind the key to the operation's
kind or input digest. Project-creation receipts are only in memory.

The probe executed two overlapping calls using one key and observed
`same_request_side_effects=2`. A retry can therefore duplicate model spend and
project creation. Introduce admission/claim before effects, stable request
fingerprints, concurrent retry joining, and durable results coordinated with the
publication transaction. Expensive work should not hold a database transaction.

### P1: Steering can silently discard a newer instruction

Location: `src/jobs.gene:168–185`, `EvolutionSession.steer`.

The method reads the queued instruction, awaits `plan_goal`, then unconditionally
sets steering to NULL. An instruction added while planning is erased even though
it was not included in that planner request. The existing test covers two
instructions queued before planning, not one arriving during planning.

The probe queued “Add a border.” inside the planner callback: the final queue was
nil and the new goal did not contain that instruction. Give queue entries stable
identities and consume only the entries captured by that planning attempt, or
atomically detach a batch and preserve arrivals in a separate pending batch.

### P2: Partial bundle publication is not recoverable by retrying the bundle

Location: `src/store.gene:191–206`, `publish_bundle`.

The final digest directory is created before its files and manifest are written.
After interruption, another publication of that same bundle skips all copying
because the directory exists, then fails verification. Startup recovery clears
staging but does not repair this incomplete final directory.

The probe pre-created that directory to model the interruption and received
`missing_artifact` on publication. Publish a complete, verified sibling directory
with one rename, and define recovery for incomplete unreferenced publications.
Continue treating corruption of already referenced evidence as an error. This
becomes particularly important when deterministic raster output reuses bundle
identities reliably.

### P2: Renderer identity does not identify the actual rendering profile

Location: `src/render.gene:17,72–88`, `src/evolution.gene:280–287,447–459`.

All configured profiles retain `rsvg-pdf-poppler/v1`. Opening a project checks only
that string, not its saved edge, tool versions, fonts or other profile inputs.
Comparison likewise derives same_profile from that string alone.

The probe reopened a 1024-edge project using edge 512 successfully, with the same
profile ID. The design explicitly requires renderer upgrades to introduce a new
profile. Keep a readable profile family/version, but additionally identify the
immutable rendering configuration by a canonical fingerprint. Compare that
fingerprint and require explicit migration when it changes. A raster fingerprint
also needs the worker/build, brush algorithm, color and encoder settings.

### P2: Resume resets model-call and elapsed-time allowances

Location: `src/jobs.gene:249–258`, `src/agent.gene:451–465`.

Only prior edit count is deducted on resume. run_drawing initializes calls to 0
and starts a fresh elapsed-time clock, while the persisted run still carries the
original budgets and cumulative usage. Steering planner calls also bypass that
loop's call/usage accounting.

A run configured with `max_model_calls = 1` consumed 2 model calls after one resume.
Persist remaining budgets across all model purposes and resumes, or make an
explicit budget extension a separate operator action. Do not silently relabel a
fresh allowance as continuation of the original bounded run.

### P2: Staging cleanup leaves directories behind

Location: `src/store.gene:151–157`, `remove_tree`.

The recursive helper ends every branch with `$fs/remove`, which removes files,
not directories in the current runtime. The probe removed the files but both
directory levels remained. Every render/crop and startup cleanup can accumulate
empty staging directories. Use `$fs/remove_dir` after clearing a directory,
preserving the existing no-follow behavior for symlinks. That standard-library
operation is now available from the Harness media work.

## Raster readiness

The existing `imagine-raster.md` proposes an editable, deterministic painting
program and complete repaint after each edit. Its separation of program, pixel
and encoded-PNG identities is appropriate. A model-driven image-generation
service would need a different reproducibility contract: retain returned assets
and request provenance rather than promise that rerunning a remote generation
request recreates its pixels. Decide which backend is intended before extending
the schema; both can share history and observations.

The raster document has drifted from this repository. It refers to a missing
`imagination.md`, treats Media as already implemented, and assumes React/Vite and
SSE. The implementation uses Gene's web profile and WebSockets. It also includes
restoration/merge capabilities that the current first release explicitly defers.
Update those assumptions before using its milestones as an implementation plan.

| Boundary | Keep | Extract or change for raster |
| --- | --- | --- |
| Evolution/history | Immutable revisions, ancestry, lines, selection, transaction/outbox pattern | Inject a medium descriptor; remove direct SVG scene/patch/diff/render imports |
| Drawing loop | Observe/propose/review cycle, trial publication, budgets and completion | Medium-specific response/patch schema, summaries, inspection and structural checks |
| Artifacts | Immutable digests and manifest verification | Described artifact roles/capabilities instead of mandatory scene.svg/scene.pdf names |
| Renderer | Bounded worker invocation and explicit errors | Full painting-program replay to fresh raster surfaces; no PDF requirement |
| Workbench | Gene frontend, live jobs, revision graph, image previews and comparisons | Medium-aware inspector and export capabilities; the client currently reads scene.svg and SVG/PDF links directly |

Start with the smallest Media interface needed by two real implementations:
validate/canonicalize, apply/replay normalized edits, compare, summarize/inspect,
render/crop, and structural checks. Keep optional merge/restoration capabilities
out of the required interface until they exist. DrawingSession currently
abstracts storage/lifecycle, not the artwork medium.

For a deterministic raster backend, put the heavier rendering worker/bridge under
genex and keep schemas, orchestration and history in Gene. Preserve the domain-
data interpreter boundary: an editable painting program need not become arbitrary
executable model code. Add immutable binary assets by digest, resource budgets,
fresh-process determinism checks, explicit seeds, and separate pixel/PNG hashes.
Reuse image/file capabilities from the recent Harness work through shared library
APIs where appropriate, without importing Harness application internals.

Suggested order: fix the reproduced correctness issues; extract the minimum
medium/artifact/profile boundaries while preserving the SVG suite; then add the
chosen raster backend. A broad framework rewrite is not needed first.
