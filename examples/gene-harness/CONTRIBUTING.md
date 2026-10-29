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
need loopback listener access. Run ../../bin/gene run tools/verify_workspace_storage.gene
for the rendered-page and compiled-browser storage boundary; Node executes the
emitted JavaScript while Gene owns the orchestration.

The repository event-catalog generator's --check mode verifies events.catalog
and its generated Gene companion. Regenerate both after changing event schemas.
Record implementation evidence under docs/verification and index new records
in docs/README.md. Reference chapters describe current behavior.

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
