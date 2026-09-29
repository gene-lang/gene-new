# Implemented specification

These files define precise behavior for contributors and advanced users.
Start with [the language guide](../language.md) for examples and ordinary usage.

- [Reader and values](reader.md)
- [Calls, paths, control, and eval](calls.md)
- [Types and construction](types.md)
- [Nil, void, and optional binding](nil-void.md)
- [Protocols and dispatch](protocols.md)
- [Streams](streams.md)
- [Tasks, channels, and actors](concurrency.md)
- [Experimental TCP byte I/O](async-io-tcp.md)
- [Experimental streamed HTTP requests](http-stream-request.md)
- [Experimental streamed HTTP responses](http-stream-response.md)
- [Experimental owned HTTP Client](http-client-owned.md)
- [Experimental HTTP server shutdown](http-server-shutdown.md)
- [Native byte ingress foundation](native-ingress.md)
- [Packaged managed native modules](native-module.md)
- [Modules and native boundaries](modules.md)
- [Native paths, CSV, and filesystem walking](path-csv-walk.md)
- [Experimental temporal arithmetic and RFC3339](temporal.md)
- [Experimental pinned time zones](tzdb.md)
- [Experimental archives](archive.md)
- [Experimental direct TLS](tls-adapter.md)
- [Local package resources and installation](package-install.md)
- [Experimental release index and signatures](package-release.md)
- [Experimental persistent signed registry](registry-service.md)

`tests/spec_runner.nim` is the executable contract. If implemented prose and
those tests disagree, resolve the discrepancy explicitly. Historical design
proposals do not override current behavior.

The call spec's compiler-head inventory is checked against dispatch. Run
appropriate executable specs when changing a rule. See
[development](../development.md) for test commands and known limits.
