# Experimental TCP byte I/O

**Status:** The native threaded POSIX VM implements the raw TCP adapter on
macOS arm64. Linux runtime qualification and HTTP body integration are open.
The executable contract is `tests/test_io_tcp.nim` under ORC and AtomicArc.

`($io/tcp_connect host port ^timeout_ms 10000)` and
`($io/tcp_listen host port ^backlog 128)` return fresh Tasks. Host is a
nonempty bounded Str without NUL; the initial adapter tries IPv4 and IPv6
for connections and binds the family selected by a listener's host. A connect
port is 1..65535, while listen allows 0 for an ephemeral port. Timeout is
1..300000 milliseconds and backlog is 1..1024. Invalid options fail before
admission; connection and bind failures settle the Task with `IoError`.

A listener implements `IoResource`. Its concrete `.accept` returns a Task
yielding a `TcpStream`; `.local_port` returns the bound port. One accept may
be pending. A second raises `IoBusy`, and close cancels a pending accept. A
cancelled accept retires its native ticket before another accept can proceed.

`TcpStream` implements qualified `AsyncReader`, `AsyncWriter`, and
`IoResource`. It permits one outstanding read and one outstanding write at
the same time. Reads yield nonempty Bytes up to the requested size or nil at
peer EOF; writes may accept a positive prefix. `flush` waits for adapter
buffers to reach the socket and does not promise peer receipt. Close requests
a full socket close and cancels pending operations. Repeated `wait_closed`
calls each return a fresh Task for physical retirement or the retained close
error. There is no local half-close, TLS, or implicit text decoding.

Read/write admissions use the same 1 MiB per-resource and 64 MiB
per-Application native payload budgets as files and pipes. Nonblocking socket
operations that would block park in a kernel `poll(2)` watcher; they do not
block the Gene root lane or occupy a worker while waiting for a peer. `IoError`
reports operation, resource ID, and an OS cause when available. Cancellation
can follow a partial external write; no automatic replay or rollback occurs.
