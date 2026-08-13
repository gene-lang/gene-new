## Runtime-owned provider for host facilities whose version-1 authority is
## nominal or exact-argument scoped.
##
## Filesystem authority has a dedicated provider because paths, rights, and
## handle-relative operations need resource-specific algebra. The remaining
## built-in facilities still need sealed grants rather than the old public
## name-only values. This provider gives them that trusted boundary while
## retaining exact selector arguments for facilities such as net/Connect.

import std/options
import ./capabilities

type
  HostCapabilityTypes* = object
    osEnv*: CapabilityType
    osExec*: CapabilityType
    osPty*: CapabilityType
    osProcess*: CapabilityType
    clockMonotonic*: CapabilityType
    cryptoRandom*: CapabilityType
    netConnect*: CapabilityType
    netHttp*: CapabilityType
    netListen*: CapabilityType
    dbPostgres*: CapabilityType
    deviceCompute*: CapabilityType
    ffiLoad*: CapabilityType

  HostCapabilityProvider* = ref object of CapabilityProvider
    types*: HostCapabilityTypes

proc appendArgumentKey(key: var string, argument: CapabilityArg) =
  key.add $ord(argument.kind)
  key.add ':'
  case argument.kind
  of cakNil:
    discard
  of cakBool:
    key.add(if argument.boolValue: "1" else: "0")
  of cakInt:
    key.add $argument.intValue
  of cakString:
    key.add $argument.stringValue.len
    key.add ':'
    key.add argument.stringValue
  of cakSymbol:
    key.add $argument.symbolValue.len
    key.add ':'
    key.add argument.symbolValue
  of cakList:
    key.add '['
    for item in argument.listValue:
      key.appendArgumentKey(item)
      key.add ';'
    key.add ']'
  of cakMap:
    key.add '{'
    for item in argument.mapValue:
      key.add $item.name.len
      key.add ':'
      key.add item.name
      key.add '='
      key.appendArgumentKey(item.value)
      key.add ';'
    key.add '}'

proc nominalScope(spec: CapabilitySpec): string =
  if spec.positional.len == 0 and spec.named.len == 0:
    return "*"
  if spec.positional.len == 1 and spec.named.len == 0 and
      spec.positional[0].kind == cakString and
      spec.positional[0].stringValue == "*":
    return "*"
  result = "p:"
  for argument in spec.positional:
    result.appendArgumentKey(argument)
    result.add ';'
  result.add "|n:"
  for argument in spec.named:
    result.add $argument.name.len
    result.add ':'
    result.add argument.name
    result.add '='
    result.appendArgumentKey(argument.value)
    result.add ';'

method validity*(provider: HostCapabilityProvider,
                 grant: CapabilityGrant): CapabilityValidity =
  discard provider
  grant.sealedValidity

method resolve*(provider: HostCapabilityProvider, parent: CapabilityGrant,
                requested: CapabilitySpec): Option[CapabilityGrant] =
  if not parent.isOwnedBy(provider) or
      parent.capabilityType != requested.capabilityType:
    return none(CapabilityGrant)
  let requestedScope = requested.nominalScope
  let narrowedScope =
    if parent.scope == "*":
      requestedScope
    elif requestedScope == "*" or requestedScope == parent.scope:
      parent.scope
    else:
      return none(CapabilityGrant)
  if narrowedScope == parent.scope:
    return some(parent)
  some(provider.deriveGrant(parent, requested.capabilityType, narrowedScope))

method intersect*(provider: HostCapabilityProvider,
                  left, right: openArray[CapabilityGrant]):
                  seq[CapabilityGrant] =
  for a in left:
    if not a.isOwnedBy(provider):
      raise newException(CapabilityError,
        "host capability intersection received a foreign grant")
    for b in right:
      if not b.isOwnedBy(provider):
        raise newException(CapabilityError,
          "host capability intersection received a foreign grant")
      if a.capabilityType != b.capabilityType:
        continue
      if a == b:
        result.add a
        continue
      let scope =
        if a.scope == "*":
          b.scope
        elif b.scope == "*":
          a.scope
        elif a.scope == b.scope:
          a.scope
        else:
          continue
      let grant = provider.intersectGrant(a, b, a.capabilityType, scope)
      var duplicate = false
      for existing in result:
        if existing.semanticKey == grant.semanticKey:
          duplicate = true
          break
      if not duplicate:
        result.add grant

method subsumes*(provider: HostCapabilityProvider,
                 broader, narrower: CapabilitySpec): CapabilitySubsumption =
  discard provider
  if broader.capabilityType != narrower.capabilityType:
    return csNo
  let broadScope = broader.nominalScope
  let narrowScope = narrower.nominalScope
  if broadScope == "*" or broadScope == narrowScope: csYes else: csNo

proc admitHostCapabilityProvider*(registry: CapabilityRegistry):
    HostCapabilityProvider =
  if registry == nil:
    raise newException(CapabilityError,
      "host capability provider requires a registry")
  result = HostCapabilityProvider()
  registry.admitProvider(result, "host/runtime")
  result.types.osEnv = registry.admitType(result, "os/Env")
  result.types.osExec = registry.admitType(result, "os/Exec")
  result.types.osPty = registry.admitType(result, "os/Pty")
  result.types.osProcess = registry.admitType(result, "os/Process")
  result.types.clockMonotonic = registry.admitType(result, "clock/Monotonic")
  result.types.cryptoRandom = registry.admitType(result, "crypto/Random")
  result.types.netConnect = registry.admitType(result, "net/Connect")
  result.types.netHttp = registry.admitType(result, "net/Http")
  result.types.netListen = registry.admitType(result, "net/Listen")
  result.types.dbPostgres = registry.admitType(result, "db/Postgres")
  result.types.deviceCompute = registry.admitType(result, "device/Compute")
  result.types.ffiLoad = registry.admitType(result, "ffi/Load")

proc grant*(provider: HostCapabilityProvider,
            capabilityType: CapabilityType): CapabilityGrant =
  if provider == nil:
    raise newException(CapabilityError, "nil host capability provider")
  provider.mintRootGrant(capabilityType, "*")

proc rootGrants*(provider: HostCapabilityProvider): seq[CapabilityGrant] =
  if provider == nil:
    raise newException(CapabilityError, "nil host capability provider")
  for capabilityType in [
      provider.types.osEnv,
      provider.types.osExec,
      provider.types.osPty,
      provider.types.osProcess,
      provider.types.clockMonotonic,
      provider.types.cryptoRandom,
      provider.types.netConnect,
      provider.types.netHttp,
      provider.types.netListen,
      provider.types.dbPostgres,
      provider.types.deviceCompute,
      provider.types.ffiLoad]:
    result.add provider.grant(capabilityType)
