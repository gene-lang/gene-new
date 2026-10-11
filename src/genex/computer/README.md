# genex/computer

Gene transport for Cua Driver 0.34.0's public CLI. Uses argument arrays, bounded
async subprocess output and deadlines. No shell commands or browser automation
runtime are embedded in Gene.

The public CLI returns plain structured JSON. The adapter normalizes it into
content plus structured state and explicitly requests screenshot output into a
private temporary file, then converts those bytes into an image block and removes
the temporary file. This path is verified against the real 0.34.0 driver.

`open_driver root ^command "cua-driver" ^socket "/path/to/socket"` connects to an
operator-started daemon. It never changes OS permissions, starts an unrestricted
daemon, or attaches to a user's existing browser profile automatically.

Host code calls `grant_window driver owner pid window_id`, then exposes only the
opaque target ID to its agent. `observe driver owner target` returns an observation
ID and the driver's MCP result, including image content. `action driver owner
target observation name params request_id` supports click/type/key/scroll on a
granted native window. Every dispatch consumes its observation. Tokens must match
the observation; pixel clicks require its immutable capture ID. Native scrolling
uses accessibility tokens.

For web content, `grant_browser driver owner pid window_id` binds exactly one
active tab through an authorized endpoint. It does not prepare endpoints, change
profiles or grant existing-profile access. Browser observations use semantic_v2
and an exact viewport screenshot. Actions use observed refs; click/type/scroll/
navigate map to typed driver browser tools. Screenshot coordinates are converted
using the observation's pixel-to-CSS scale. Explicit foreground delivery is
supported where the trusted click route refuses background input; no fallback
is selected silently.

The host must publish image blocks as model image content, not base64 prose, and
must verify effects from another observation. `completed` means the driver
returned, not that the intended application state is verified. A transport failure
or cancellation after admission leaves `unknown` on disk. Repeating the same
request returns its receipt without dispatch; reusing it with different inputs
fails. Receipts remain readable after a host restart using
`action_receipt driver owner request_id`. Grants and observations expire at
restart so PIDs/windows must be selected again.

`close_session driver owner` revokes local grants and asks the driver to release
that session. It does not stop a shared daemon. The driver remains responsible for
OS permission enforcement. This library is an application-level scope boundary,
not a sandbox against agents that also have unrestricted process access.

Official interface: https://cua.ai/docs/cua-driver/reference/cli/mcp
