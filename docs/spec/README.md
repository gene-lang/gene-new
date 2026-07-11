# Gene implemented specification

**Status:** normative for the implemented language surface.

The contract is split by subsystem:

- [Reader and values](reader.md)
- [Calls, selectors, control, and eval](calls.md)
- [Types, construction, and mutation](types.md)
- [Protocols and message dispatch](protocols.md)
- [Streams and channels](streams.md)
- [Tasks and actors](concurrency.md)
- [Applications, modules, reflection, and native boundaries](modules.md)

`tests/spec_runner.nim` is the executable form of this contract. When a rule
marked implemented disagrees with that suite, the suite has temporary
precedence and the prose must be fixed. `docs/design.md` is architecture and
rationale; `docs/proposals/` and explicitly deferred material are
non-normative.

Run `nimble spec` after changing any rule. The compiler-head inventory in
[calls.md](calls.md) is checked directly against compiler dispatch.
