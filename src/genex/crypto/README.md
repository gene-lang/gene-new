# genex/crypto

`verify_rs256(modulus, exponent, message, signature)` verifies bytes using RSA
PKCS#1 v1.5 and SHA-256. The unsigned public components use network byte order.
It accepts 2048–8192 bit RSA public keys and messages up to 1 MiB. Invalid keys,
signatures and out-of-bound inputs return false. OpenSSL 3 is a declared system
dependency; missing build or loader dependencies raise an error.

`encode_url(data)` and `decode_url(text)` implement unpadded RFC 4648 base64url.
The decoder rejects padding, noncanonical encodings and payloads over 1 MiB.

An OIDC caller must obtain its JWKS from a trusted issuer, rather than
token-controlled key URLs.
`verify_id_token(token, jwks, issuer, audience, nonce, now)` pins RS256, requires
one matching signing key, and verifies signature, issuer, audience/authorized
party, subject, issued-at time, expiry, optional not-before time and nonce. It
allows five seconds of clock skew. If `at_hash` is present, supply the matching
`^access_token`; its binding is checked too. It returns verified claims and emits
only generic errors. The caller must still enforce its account selection and
granted permission scopes before activating a login.
For a refresh response only, `^require_nonce false` permits an absent nonce;
if the refreshed token includes one it must still match the original nonce.

The adapter uses OpenSSL's [public-key import](https://docs.openssl.org/3.0/man3/EVP_PKEY_fromdata/)
and [EVP verification](https://docs.openssl.org/3.0/man3/EVP_DigestVerifyInit/) APIs.

Run `gene run spec` from `tests/`. Its consumer package selects the library's
declared native recipe. Direct `gene test` source execution currently does not
materialize native build recipes; the consumer exercises ordinary package loading.

The native adapter and signed-token fixtures have been verified on macOS arm64
with OpenSSL 3.6.1. Linux build/runtime qualification remains open.
