# genex/tls (experimental NET-3 direct TLS)

This optional format-1 package builds a native TLS adapter against a declared
OpenSSL 3 system dependency. Its C ABI validates a complete server certificate,
private key, optional client CA and authentication policy before publishing an
immutable context. Reload constructs a replacement before swapping it; live
connections retain the old context until their physical close. Contexts require
TLS 1.2 or newer and negotiate TLS 1.3 where supported.

An installed application declares this package as dependency alias `tls`.
`net/http/listen ^tls` then uses its native binary for nonblocking HTTPS and
optional required client certificates. `(server .reload_tls config)` returns
an external Task backed by the adapter's bounded 16-job reload service. The
package's `adapter_abi` function verifies PKG-2 loading. macOS arm64 functional
fixtures pass; Linux runtime and sustained service qualification remain open.
The existing pinned HTTPS reverse-proxy fixture is the qualified deployment
path until those gates pass.
