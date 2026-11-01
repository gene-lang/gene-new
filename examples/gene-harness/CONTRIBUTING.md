# Contributing to Harness

Read [design](docs/design.md) for owners and lifetimes and [protocol](docs/protocol.md)
for the response and record contract. Follow the repository's AGENTS.md.

## Source ownership

The static service table is runtime/runtime_services.gene. Loop construction and
resumption live in runtime/loop_services.gene; browser observers live in
web/observers.gene. Plugin APIs are plugin_api.gene and declared public/* modules.

Kernel imports have a per-module allowlist in kernel_boundaries_spec.gene.
The kernel facade has 45 exports; named test imports do not expand it. Keep
product implementations out of kernel/host and inject runtime callbacks.

Workspace persistence is split across composition_store, module_registry,
workspace_activation and workspace_repair. Keep their dependency direction
acyclic. Specs mirror source paths under tests/unit and tests/integration.

UI validation and outline generation operate on data. Runtime-dependent
rendering and action admission are separate modules. Browser reconciliation
receives handlers from its controller. Registered documentation stays with its
contributing plugin; do not merge chapters across owners.

## Verification

From examples/gene-harness, use ../../bin/gene test tests for the complete
package suite and select affected spec paths for focused checks. HTTP specs
need loopback listener access. The compiled browser and workspace-storage checks
run through tests/integration/web/client_contracts_spec.gene; Node executes the
emitted JavaScript while Gene owns the orchestration. See the
[test guide](tests/README.md) for focused commands and fixture conventions.

Edit [the event catalog](src/storage/event_catalog.gene) directly when changing
event definitions or payload validators. Preserve persisted names, versions
and ignorable flags unless explicitly changing the storage contract. Run the
storage and recovery specs after changing event schemas.
Keep reference chapters current. Retain measurement or live-service evidence
under docs/verification when automated tests cannot reproduce it, and index it
in docs/README.md. Completed rollout checklists and migration discussions belong
in Git history rather than permanent reference chapters.

## Tooling constraints

The current Gene web builder flattens output modules by source basename.
Imported browser modules must therefore have distinct filenames even when
they live in different directories (`client/state.gene` and
`client/ui/model.gene`, for example). Preserving directory identity in web
output is a tooling improvement to pursue in Gene; it requires no language
syntax change. Compile `client/main.gene` after changing its import graph.

Shell mode uses Gene's existing asynchronous subprocess pipes. Each persistent
shell occupies a captured-process worker until it closes; the current runtime
pool has 32 workers. A reusable persistent-process API with readiness-based
I/O would avoid dedicating workers to idle shells. This is a runtime/library
capability to develop if simultaneous shell sessions approach that limit.
The existing `stdout_chan` adapter also assembles a complete line before
delivery, independently of its captured-output cap. Shell mode bounds the
text it retains, but a bounded line adapter over `gene/io` byte readers would
also bound native buffering for long lines.

The kernel field guards inspect parsed Gene without evaluating it.
PipelineSyntax currently lacks a public child accessor, so the guards inspect
its canonical arrow spelling as inert tagged data. A read-only AST child API
and cycle-aware thaw diagnostics remain language-tooling follow-ups.

The web profile lacks the native `$order` API and full Unicode case-folding
parity. Spotlight currently compares UTF-8 bytes for deterministic ordering;
shared ordering and text APIs are standard-library follow-ups.
