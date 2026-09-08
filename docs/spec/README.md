# Implemented specification

These files define precise behavior for contributors and advanced users.
Start with [the language guide](../language.md) for examples and ordinary usage.

- [Reader and values](reader.md)
- [Calls, selectors, control, and eval](calls.md)
- [Types and construction](types.md)
- [Nil, void, and optional binding](nil-void.md)
- [Protocols and dispatch](protocols.md)
- [Streams](streams.md)
- [Tasks, channels, and actors](concurrency.md)
- [Modules and native boundaries](modules.md)
- [Authority and sandbox boundaries](authority.md)

`tests/spec_runner.nim` is the executable contract. If implemented prose and
those tests disagree, resolve the discrepancy explicitly. Historical design
proposals do not override current behavior.

The call spec's compiler-head inventory is checked against dispatch. Run
appropriate executable specs when changing a rule. See
[development](../development.md) for test commands and known limits.
