# Harness kernel tidy verification

2026-10-28–29. Implements `tmp/harness-tidy.md`, beginning at `409e90e7`.
Implementation and verification are complete. All five stage-end full package
gates and the separately requested intermediate-cut full gate passed, with no
failed, errored or skipped examples.

## Changes and acceptance evidence

| Step | Result | Evidence |
| --- | --- | --- |
| 0: retire PluginHost:2 | Only version 3 is offered; unannotated source uses v3. Retired stored entries fail admission without blocking peers. No stored data is migrated. | Interface compatibility, restricted descriptor, command, input-mode and host-context checks: 29 passed. Mixed-version startup, re-registration and historical rejection are covered. Commit `fdad5d17`. |
| 1: split kernel | Seven implementation modules sit behind a 47-name facade. Dead definitions and imports are removed. Source loading uses the owning package root. | Intermediate invoke/registry cut: 11 passed. Completed split, compatibility and architecture checks: 21 passed. Commits `f3b6fef3` through `f2fd1f88`. |
| 2: status | One lazy entry-state map serves a publication or batch query. Sticky replacement failures survive unrelated reconciliation until retry. Absent and closed-harness checks avoid inspection. | Status, field ownership, facade and path checks: 10 passed. The counting composition observes one call per publication/query. Commit `491503c3`. |
| 3: state ownership | Runtime services own six product fields. The bridge owns grouped composition fields. Harness has 22 fields. Snapshots and composition retain their existing names. | Shape/ownership guards plus services, notifications, appearance and participant checks: 26 passed. Commit `55c0c98f`. |
| 4: callback retention | Registry, speech dispatch and cleanup tests use `runtime/retained_callbacks.gene`. Composition-call helpers and RegistryHost remain in the adapter. | Retention, speech lifecycle, registry supervision and architecture checks: 19 passed. Commit `ba366e0a`. |

The facade and layering guards parse complete import forms. Unconsumed kernel
definitions are module-private. The owner approved an exact, stale-checked
test-import exception for `plugin_states` and `retry`; the facade remains at
47 names. The callback-trio migration exception is removed in Step 4.

The field guard checks nested reads, writes, literal-container paths and
pipeline references while ignoring literal strings and regex patterns. It
confines sticky failures and the grouped bridge handle to the bridge module.

## Full package gates

Each gate runs `../../bin/gene test` from its checkpoint's
`examples/gene-harness` directory. Checkpoints have independent workspaces,
package stores and artifact stores. HTTP fixtures require local listener access.
Initial background runs used reduced scheduling priority; the final Step 3 and
Step 4 retries ran at normal priority with less concurrent load.

| Step | Source commit | Tracked source inputs checked | Full result |
| --- | --- | ---: | --- |
| 0 | `fdad5d17` | 461 | 654 passed, 0 failed, 0 errors, 0 skipped |
| 1a: intermediate invoke/registry cut | `16032785` | 465 | 656 passed, 0 failed, 0 errors, 0 skipped |
| 1 | `f2fd1f88` | 472 | 659 passed, 0 failed, 0 errors, 0 skipped |
| 2 | `491503c3` | 474 | 664 passed, 0 failed, 0 errors, 0 skipped |
| 3 | `55c0c98f` | 475 | 665 passed, 0 failed, 0 errors, 0 skipped |
| 4 | `ba366e0a` | 476 | 665 passed, 0 failed, 0 errors, 0 skipped |

Every checkpoint's `src/`, `tests/` and `probes/` input was checked against
the corresponding committed Git blob, with no extra source files. This keeps
the long-running gates independent of later worktree changes. The event catalog
check passed in all six checkpoints. `git diff --check` passes.

The intermediate cut's exact import layers and callback-trio exception were
also checked directly against `16032785`. Across the six full gates, 3,963
examples passed. The final implementation's complete suite has 665 examples.

An initial complete Step 0 run produced 653 passes and one pre-existing theme
guard failure. The session menu had raw shadow and fallback color literals.
Commit `6177a73a` moves the shadow into the theme and uses the existing danger
token; all four theme checks pass. The full gates above include that repair.
Interrupted diagnostic runs are not counted as full-suite results.

The initial concurrent, reduced-priority Step 3 and Step 4 runs each produced
664 passes and one timeout in the eleven-scenario HTTP crash-recovery fixture.
Both reached every named checkpoint and emitted no assertion diagnostic. The
unchanged case then passed at normal priority, with its five-minute outer
limit and all per-scenario assertions intact. Complete normal-priority reruns
then passed all 665 examples each. No tests were excluded and no timeout was
increased.

## Implementation observations

- The Composer retains its live Harness through a `Cell` identity handle.
  A raw `Composer -> Harness` back-reference made registry-table thawing recurse
  through a cyclic structural graph. The opaque handle preserves the existing
  cloning and cleanup behavior without changing language equality or thaw
  semantics. Kernel replacement, retirement and shutdown checks cover it.
- Direct host contributions have no activation policy. The public-context
  adapter therefore checks that a policy exists before classifying it as a
  non-host activation. This preserves the registry's host default and is covered
  by `public_context_spec.gene`.
- Gene's parser returns a Stream. The guards collect it only where indexed
  access is required. PipelineSyntax currently lacks a public child accessor;
  the field guard parses its canonical arrow spelling as inert tagged data for
  inspection. It does not execute syntax or rewrite source. A general read-only
  AST child API and cycle-aware thaw diagnostics remain language-tooling
  follow-ups, outside this structural tidy.

`runtime/composition.gene` is unchanged. `plugin_api.gene` changes only comments;
the PluginHost:3 message contract and interface version are unchanged. The
deliberate compatibility change is retirement of PluginHost:2, as approved by
the owner.
