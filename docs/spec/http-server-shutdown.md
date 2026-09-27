# Experimental HTTP server shutdown

`($net/http/stop server)` requests a graceful stop and returns nil. The
`serve` loop closes admission, allows active requests up to
`^drain_timeout_ms` (5,000 by default), then closes any remaining sockets and
cancels their request tasks. Idle connections and WebSockets close when the
drain starts.

Cancellation requests unwind Gene handler and response-read Fibers so their
`ensure` blocks and structured child cleanup run. The server retains these
Tasks after removing their sockets and waits for settlement under the same
cleanup deadline. A truncated upload follows this path too.

`serve` now returns a Map when it exits normally:

| Field | Meaning |
| --- | --- |
| `complete` | Server-owned close Tasks and cancelled handler/read Tasks settled as expected, and tracked cleanup leases and I/O file resources returned to their entry baselines by the deadline. |
| `graceful` | No connection was still open when the final close pass began. |
| `forced_connections` | Connections closed in that final pass. |
| `cleanup_leases` | Cleanup leases still above the entry baseline. |
| `open_io_resources` | I/O file resources still above the entry baseline. |
| `pending_cleanup_tasks` | Server-owned close Tasks or cancelled handler/read Tasks still pending. |
| `close_failed` | A tracked Task failed or panicked, or a close Task was unexpectedly cancelled. Requested handler/read cancellation is an expected outcome. |
| `served_requests` | Responses fully served during this call. |

The final close pass pumps root-lane completions until the server-owned cleanup
Tasks finish and tracked cleanup counts return to their entry baselines, or
the drain deadline expires. Completed close Tasks are pruned during normal
service, so a long-lived server does not retain one Task per request.
`complete: false` reports cleanup that did not finish by that deadline;
it does not turn a partial response into a successful one. `graceful: false`
reports forced socket closure even when later physical cleanup completes.
Exceptions from `serve` still propagate after cleanup is requested.

The [native-app service fixture](../../tests/profiles/native-app/service)
uses pinned Caddy TLS termination and validates the return Map alongside
post-stop runtime counters. The fixture does not claim direct TLS support in
Gene. Linux runtime qualification and complete VM lifetime gates remain open.
