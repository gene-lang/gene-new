## OpenSSL 3 Ed25519 adapter for signed package releases. PKG-3 keeps this
## dependency explicit: callers supply an absolute libcrypto path selected by
## their platform policy, and no package bytes are trusted merely because the
## library was available. Keys are raw RFC 8032 32-byte keys; signatures are
## exactly 64 bytes. Pure Ed25519 requires OpenSSL's one-shot EVP operations.

import std/[dynlib, os]

type
  NewRawKeyProc = proc(context: pointer, keyType, properties: cstring,
                       bytes: pointer, size: csize_t): pointer {.cdecl.}
  KeyFreeProc = proc(key: pointer) {.cdecl.}
  GetRawPublicProc = proc(key, output: pointer,
                          size: ptr csize_t): cint {.cdecl.}
  MdCtxNewProc = proc(): pointer {.cdecl.}
  MdCtxFreeProc = proc(context: pointer) {.cdecl.}
  DigestInitProc = proc(context, keyContext: pointer, digest, engine,
                        key: pointer): cint {.cdecl.}
  DigestSignProc = proc(context, output: pointer, outputSize: ptr csize_t,
                        message: pointer, messageSize: csize_t): cint {.cdecl.}
  DigestVerifyProc = proc(context, signature: pointer,
                          signatureSize: csize_t, message: pointer,
                          messageSize: csize_t): cint {.cdecl.}

  ReleaseCrypto* = ref object
    image: LibHandle
    newPrivate: NewRawKeyProc
    newPublic: NewRawKeyProc
    freeKey: KeyFreeProc
    rawPublic: GetRawPublicProc
    newContext: MdCtxNewProc
    freeContext: MdCtxFreeProc
    signInit: DigestInitProc
    sign: DigestSignProc
    verifyInit: DigestInitProc
    verify: DigestVerifyProc

proc loadReleaseCrypto*(libraryPath: string): ReleaseCrypto =
  ## An explicit absolute path prevents cwd or loader-path search from
  ## silently selecting a different crypto implementation for publication.
  if not libraryPath.isAbsolute or not fileExists(libraryPath):
    raise newException(IOError,
      "release crypto requires an absolute existing OpenSSL 3 library path")
  let image = loadLib(libraryPath)
  if image == nil:
    raise newException(IOError, "cannot load release crypto library")
  result = ReleaseCrypto(image: image,
    newPrivate: cast[NewRawKeyProc](symAddr(image,
      "EVP_PKEY_new_raw_private_key_ex")),
    newPublic: cast[NewRawKeyProc](symAddr(image,
      "EVP_PKEY_new_raw_public_key_ex")),
    freeKey: cast[KeyFreeProc](symAddr(image, "EVP_PKEY_free")),
    rawPublic: cast[GetRawPublicProc](symAddr(image,
      "EVP_PKEY_get_raw_public_key")),
    newContext: cast[MdCtxNewProc](symAddr(image, "EVP_MD_CTX_new")),
    freeContext: cast[MdCtxFreeProc](symAddr(image, "EVP_MD_CTX_free")),
    signInit: cast[DigestInitProc](symAddr(image, "EVP_DigestSignInit")),
    sign: cast[DigestSignProc](symAddr(image, "EVP_DigestSign")),
    verifyInit: cast[DigestInitProc](symAddr(image, "EVP_DigestVerifyInit")),
    verify: cast[DigestVerifyProc](symAddr(image, "EVP_DigestVerify")))
  if result.newPrivate == nil or result.newPublic == nil or
      result.freeKey == nil or result.rawPublic == nil or
      result.newContext == nil or result.freeContext == nil or
      result.signInit == nil or result.sign == nil or
      result.verifyInit == nil or result.verify == nil:
    unloadLib(image)
    raise newException(IOError,
      "release crypto library lacks the OpenSSL 3 Ed25519 EVP ABI")

proc close*(crypto: ReleaseCrypto) =
  if crypto != nil and crypto.image != nil:
    unloadLib(crypto.image)
    crypto.image = nil

proc ensureOpen(crypto: ReleaseCrypto) =
  if crypto == nil or crypto.image == nil:
    raise newException(IOError, "release crypto adapter is closed")

proc bytesPointer(bytes: string): pointer =
  if bytes.len == 0: nil else: unsafeAddr bytes[0]

proc privateKey(crypto: ReleaseCrypto, seed: string): pointer =
  crypto.ensureOpen()
  if seed.len != 32:
    raise newException(ValueError, "Ed25519 private seed must be 32 bytes")
  result = crypto.newPrivate(nil, "ED25519", nil,
    bytesPointer(seed), csize_t(seed.len))
  if result == nil:
    raise newException(IOError, "OpenSSL could not import Ed25519 private key")

proc publicKey(crypto: ReleaseCrypto, bytes: string): pointer =
  crypto.ensureOpen()
  if bytes.len != 32:
    raise newException(ValueError, "Ed25519 public key must be 32 bytes")
  result = crypto.newPublic(nil, "ED25519", nil,
    bytesPointer(bytes), csize_t(bytes.len))
  if result == nil:
    raise newException(IOError, "OpenSSL could not import Ed25519 public key")

proc ed25519PublicKey*(crypto: ReleaseCrypto, seed: string): string =
  let key = crypto.privateKey(seed)
  defer: crypto.freeKey(key)
  result = newString(32)
  var size: csize_t = 32
  if crypto.rawPublic(key, addr result[0], addr size) != 1 or size != 32:
    raise newException(IOError, "OpenSSL could not derive Ed25519 public key")

proc ed25519Sign*(crypto: ReleaseCrypto, seed, message: string): string =
  let key = crypto.privateKey(seed)
  defer: crypto.freeKey(key)
  let context = crypto.newContext()
  if context == nil:
    raise newException(IOError, "OpenSSL could not allocate signing context")
  defer: crypto.freeContext(context)
  if crypto.signInit(context, nil, nil, nil, key) != 1:
    raise newException(IOError, "OpenSSL could not initialize Ed25519 signing")
  result = newString(64)
  var size: csize_t = 64
  if crypto.sign(context, addr result[0], addr size,
                 bytesPointer(message), csize_t(message.len)) != 1 or
      size != 64:
    raise newException(IOError, "OpenSSL could not sign release bytes")

proc ed25519Verify*(crypto: ReleaseCrypto, publicKeyBytes, message,
                    signature: string): bool =
  if signature.len != 64:
    return false
  let key = crypto.publicKey(publicKeyBytes)
  defer: crypto.freeKey(key)
  let context = crypto.newContext()
  if context == nil:
    raise newException(IOError, "OpenSSL could not allocate verification context")
  defer: crypto.freeContext(context)
  if crypto.verifyInit(context, nil, nil, nil, key) != 1:
    raise newException(IOError, "OpenSSL could not initialize Ed25519 verification")
  crypto.verify(context, bytesPointer(signature), csize_t(signature.len),
                bytesPointer(message), csize_t(message.len)) == 1
