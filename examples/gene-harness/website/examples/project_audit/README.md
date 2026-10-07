# Project audit example

This example registers `project_audit_scan` and `project_audit_last` as ordinary
Harness functions. It reads up to eight relative files, counts non-empty/TODO/
FIXME lines, writes a Markdown report and saves the latest successful summary
in workspace plugin state. A failed read leaves that summary unchanged.

From the repository root:

```text
bin/gene run examples/gene-harness/website/examples/project_audit/check.gene
```

The checker creates a scratch workspace under the package's ignored `tmp/`,
copies the fixture files, registers the plugin through the normal loader,
executes the commands in `commands.gene` and verifies results after reopening
the workspace. It makes no model call. `expected/` contains the summary,
caught error fields and report used by the checker and the informational site.

`request.txt` is the original request from a recorded session using an older
tool-based Harness API. It is preserved as provenance. The plugin, commands
and checker have been migrated to the current function API; the source no
longer claims to match the recorded module digest. Use `plugin.gene` and the
[plugin guide](../../../docs/plugins.md) as the current contract.
