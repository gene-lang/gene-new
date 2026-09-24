# Experimental NET-3 direct TLS

`genex/tls` is an optional format-1 native package declaring OpenSSL 3 as a
system dependency. Its C ABI validates a complete certificate chain/private
key pair and requires TLS 1.2 or newer. Required client authentication needs
an explicit client CA and rejects peers without a trusted certificate before
application data. Handshake, read, and write return readiness codes for a
nonblocking host loop; they do not call Gene from the transport thread.

The server owner holds one immutable active context. A reload worker reads and
validates replacement material before a lock-protected publication; failure
or pre-commit cancellation leaves the old context active. Connections retain
the context chosen at creation, including after a reload or server-owner
close. Native counts report live contexts and connections until physical
retirement. At most 16 reload jobs may be retained.

An installed application declares `genex/tls` as dependency alias `tls`, then
passes `^tls {^cert_file "..." ^key_file "..." ^client_ca_file "..."
^client_auth "none"}` to `net/http/listen`. `client_ca_file` is optional and
`client_auth` defaults to `"none"`; `"required"` needs a CA. Relative material
paths resolve from the application's launch directory. The listener rejects
plaintext and failed TLS handshakes before parsing HTTP. A `Server` made
without `listen ^tls` cannot change transport through reload.

`(server .reload_tls config)` returns a Task. The adapter reads and validates
replacement material on a bounded worker, then atomically swaps the context
for newly accepted connections. Awaiting the Task succeeds with `nil` or
fails with a TLS reload error. An invalid replacement leaves the current
context active. Cancellation before publication prevents the swap; after
publication it cannot roll back a successful reload.

The C fixture covers mismatched cert/key, untrusted server, missing/valid
client certificate, canceled and successful reload, and old-session operation
after rotation and owner close. The offline installed-package fixture covers
HTTPS listener dispatch, plaintext and untrusted-server rejection, failed
reload, and successful rotation. The C source passes Linux x86_64 compile-only
checks; Linux runtime and sustained service qualification remain open. The
pinned reverse-proxy fixture remains the qualified HTTPS deployment path.
