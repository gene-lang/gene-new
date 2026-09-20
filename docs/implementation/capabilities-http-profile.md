# Initial HTTP capability profile

This is the implementation profile for proposal section 12. Provider/schema
version: **http-components-v1**.

## Normalization

- Absolute HTTP/HTTPS URLs only. Schemes and ASCII DNS hosts normalize to
  lowercase. Empty paths become /; effective ports default to 80/443.
- DNS labels admit ASCII letters, digits and hyphens, with no empty labels,
  leading/trailing hyphens, Unicode spelling, trailing dot or encoded hostname.
  Labels are at most 63 bytes; hosts at most 253 bytes.
- IPv4 uses four decimal octets without leading zeroes. Numeric shorthand,
  octal and hexadecimal spellings are rejected. Bracketed IPv6 uses Nim's
  checked parser and canonical lowercase serialization; zone IDs are rejected.
  Normalization performs no DNS lookup.
- Reject user information, fragments, raw whitespace/control characters and
  raw backslashes. Percent-encode non-ASCII path/query UTF-8 bytes. Preserve
  valid existing percent escapes, query ordering and duplicate parameters.
- Reject literal/encoded dot-only path segments and encoded slash/backslash
  separators. Preserve absent, empty and nonempty queries distinctly.
- Exact URL shorthand becomes a full component conjunction, including queries.
  Source shorthand rejects raw asterisks; checked literal values can represent
  an actual asterisk. Only leading-star-dot DNS suffix patterns are admitted.
  Path globs stay within the path component; methods and queries are exact.

## Transport contract

The initial adapter uses fresh HTTP/1.1 transfers, without pooled connections,
automatic redirects/retries, proxies, a cookie store, netrc lookup or managed
client authentication. Following a returned redirect starts another prepared
and guarded request. Managed authentication needs a separately adopted policy.

The prepared URL, method and path-plus-query target are the guarded and transmitted
values. Set the adapter-owned request target explicitly to preserve an empty
query delimiter. [libcurl passes that target verbatim](https://curl.se/libcurl/c/CURLOPT_REQUEST_TARGET.html),
so preparation must reject controls/whitespace first. Callers cannot override it.

An explicit empty proxy string disables
[environment-selected proxies](https://curl.se/libcurl/c/CURLOPT_PROXY.html).
Set path-as-is and disable automatic redirects to prevent libcurl from
[normalizing dot segments](https://curl.se/libcurl/c/CURLOPT_PATH_AS_IS.html).
Check every enforcement option result and reject unavailable modes.

Reject caller Host/authority, proxy, upgrade and message-framing overrides.
Application-supplied Authorization/Cookie headers remain ordinary data. Reject
CONNECT, Upgrade requests and unexpected 101 responses; expose no upgraded
channel or raw socket. Check live authority at native-work start. A later
request/retry needs another guard; revocation does not undo in-progress I/O.

The worker prepares its fresh handle and then waits for a one-use start decision
from the owning scheduler. The scheduler guards the immutable prepared operation
against its complete retained context, including all independent rows and live
alternatives, and releases the ready worker directly into the transfer. That
decision is the operation's live-validity observation/start point. No application
code or another queue runs between that handoff and the native transfer. Denial
or cancellation releases the worker without sending. This avoids passing managed
capability objects to native threads. Revoking an unrelated or redundant grant
does not abort a request that another complete live entry still permits.

Every transfer explicitly sets HTTP/1.1, fresh/no-reuse connections, a validated
request target, path-as-is, no proxies/pre-proxy/tunnels, no redirects, no netrc
or automatic HTTP/proxy authentication, and TLS peer/hostname verification.
Fresh handles never enable cookie or client-certificate state. HEAD uses libcurl's
no-body mode; a nonempty HEAD request body is outside this profile. A 101 status
is rejected in the header callback before any switched-protocol bytes can reach
an application stream. The [header callback](https://curl.se/libcurl/c/CURLOPT_HEADERFUNCTION.html)
receives complete header lines and can abort the transfer. Explicit
[HTTP/1.1 selection](https://curl.se/libcurl/c/CURLOPT_HTTP_VERSION.html) is paired
with fresh connections to prevent a reused connection from changing protocols.
The adapter suppresses the automatic `Expect: 100-continue` handshake and rejects
caller `Expect` headers, preventing libcurl's implicit retry on a 417 response.
An adapter-owned [empty header override](https://curl.se/libcurl/c/CURLOPT_HTTPHEADER.html)
disables that internal header; explicit later attempts need a new guard.

## Verification gate

In addition to policy tests, use recording loopback transports to verify exact
request-target bytes, query presence, denied redirect targets, revoked queued
sends, proxy suppression, framing/authority overrides and CONNECT/101 rejection.
Matcher tests alone do not establish transport conformance.

The recording fixture requires Python 3 and binds loopback on an ephemeral port;
it performs no reverse-DNS lookup or external requests. The transport suite also
covers large request bodies without automatic expectation retries and checks
that cancellation and revocation of a queued request prevent it from reaching
the endpoint while independent live alternatives continue to work.
