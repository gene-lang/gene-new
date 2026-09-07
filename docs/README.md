# Gene documentation

Start with the [project README](../README.md) for installation and commands,
[design overview](design.md) for the main choices, or
[implementation status](implementation-status.md) for what is available now.

## Contracts and language reference

The [implemented specification](spec/README.md) is normative. Executable specs
in `tests/spec_runner.nim` are the implementation contract; disagreements must
be resolved explicitly rather than treating design prose as shipped behavior.

- [Values and reader](spec/reader.md)
- [Calls, control, and eval](spec/calls.md)
- [Types and construction](spec/types.md)
- [Nil, void, and optional binding](spec/nil-void.md)
- [Protocols](spec/protocols.md)
- [Streams](spec/streams.md) and [concurrency](spec/concurrency.md)
- [Modules and native boundaries](spec/modules.md)
- [Authority and sandbox boundaries](spec/authority.md)

The [numbered language reference](reference/README.md) holds detailed examples
and rationale formerly collected in `design.md`. Its deferred sections do not
add to the implemented contract.

## Feature guides and implementation references

| Area | Documents |
| --- | --- |
| Calls and syntax | [Fexprs/macros](macro-design.md), [pipelines](pipelines.md), [tail calls](tail-calls.md), [style](style.md) |
| Types and behavior | [Core protocol/type model](core.md), [Self](self-type.md), [scoped impls](scoped-impls.md), [module references](gene-module-refs.md) |
| Packages and builds | [Packages](packages.md), [package builds](package-builds.md) |
| Runtime services | [Stdlib](stdlib.md), [HTTP/WebSocket server](http-server.md), [events](events.md), [logging](logging.md) |
| Data | [Serialization](serialization.md), [persistence](persistence.md) |
| Authority | [Implemented contract](spec/authority.md), [provider and propagation reference](capabilities.md) |
| Web | [Compilation](web-compilation.md), [supported profile](web-profile.md), [interop](web-interop.md), [wasm VM](wasm.md) |
| Native | [Managed wrappers and typed-native backend](native-types.md), [interop rationale](reference/native-interop.md) |
| Tools | [Editor](editor.md), [LSP](lsp.md), [VS Code extension](vscode-extension.md) |

Implemented references may contain explicitly deferred extensions. The status
at the top of each document identifies the supported slice; a detailed design
or historical checklist is not a claim of complete implementation.

## Evidence and future work

- [Reports](reports/README.md): dated implementation verification and measurements.
- [Proposals](proposals/README.md): unimplemented designs and research directions.
- [Archive](archive/README.md): retired work and superseded planning material.

When changing a feature, update its focused contract and guide. Keep
`design.md` short and link to the detail. Move implemented feature documents
out of `proposals/`; retain unresolved extensions with an explicit status.
