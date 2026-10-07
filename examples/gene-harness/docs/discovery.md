# Progressive discovery

The starting prompt contains execution rules, essential orientation and workspace
context. It does not include the Gene manual, plugin manuals or every callable
signature. The model finds capabilities as it needs them:

```gene
(discover "ui")
(discover "forms" ^kind "docs")
(doc "harness/ui/forms")
(discover "register" ^kind "functions")
(doc "harness/plugins")
```

`discover` takes an optional query (default empty) and optional named arguments:

| Argument | Meaning |
| --- | --- |
| `kind` | docs, functions, commands, input_modes, providers, hooks, web_components or seams; empty searches all |
| `owner` | Exact contribution owner/plugin ID; empty searches all |
| `limit` | 1–100 matches, default 12 |
| `offset` | Nonnegative match offset, default 0 |

Query words are case-insensitive AND matches against registry kind, owner, name,
summary, doc description, tags and chapter references. An empty query lists
active contributions. Results contain matches, total and next_offset (nil when
finished). Continue with the same query/filters and that offset. Discovery is
substring search, not semantic search or an external service.

Each match contains kind, name, owner, a summary capped at 240 UTF-8 bytes, tags
and docs references. Functions also have their captured signature; commands have
usage; web components have slot. No callback, renderer or provider is executed.
Documentation bodies and file paths are not loaded or returned. `doc` loads one
selected chapter. Missing documentation gives a discovery hint.

Both helpers read the caller's leased composition. Replacing a plugin cannot
change an in-progress turn's catalog or docs. New turns see the new contributions;
disabling/retiring a plugin removes its catalog rows and owned documentation.
They are available in model responses, `/run` and the persistent REPL.
Function contributions cannot take the reserved names discover or doc, which
would otherwise advertise signatures different from the shared bindings.

## Every plugin participates

Discovery is derived from ordinary contribution rows. No additional central
catalog needs updating when a plugin is registered. A function's existing doc
description is the fallback summary, so older plugins remain discoverable.

All plugins should provide concise descriptions and optional metadata:

- `summary`: a string describing the capability/chapter without its full manual.
- `tags`: a list of nonempty topic strings to help search.
- `docs`: a list of owned/relevant chapter names to load next.

Contribute detailed instructions and examples as docs rows, with a summary and
tags. Give chapter names a plugin prefix. Keep essential behavioral rules and
orientation in prompt rows; place API catalogs and tutorials in pull-only docs.
The host validates metadata types but does not require metadata on legacy rows
or impose a hard size limit on plugin instructions.

See [plugins](plugins.md) for a self-describing plugin example and
[UI overview](recipes/ui.md) for choosing focused recipes.
