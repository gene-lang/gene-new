## Explicit local PKG-3 trust bootstrap. This file is inert Gene data, never
## evaluated, and is supplied by the operator rather than downloaded from a
## registry. No package import or ordinary run command reads it implicitly.

import std/[base64, os, tables]
import ./[hosted_registry, package, reader, registry_https, release_crypto,
          types]

const MaxRegistryConfigBytes* = 64 * 1024

type
  ConfiguredRegistry* = ref object
    name*: string
    transport*: RegistryHttpsTransport
    crypto*: ReleaseCrypto
    trust*: ReleaseTrust
    adapter*: PackageSourceAdapter
    publishTokenFile*: string

  RegistryConfig* = object
    registries*: seq[ConfiguredRegistry]
    defaultRegistry*: string

proc configError(message: string) {.noreturn.} =
  raisePackageError(pecManifestInvalid, "registry configuration: " & message)

proc fieldsExactly(value: Value, allowed, required: openArray[string],
                   context: string): PropTable =
  if value.kind != vkMap:
    configError(context & " must be a Map")
  result = value.mapEntries
  for name in result.keys:
    if name notin allowed:
      configError(context & " has unexpected ^" & name)
  for name in required:
    if not result.hasKey(name):
      configError(context & " requires ^" & name)

proc strField(fields: PropTable, name, context: string): string =
  if fields[name].kind != vkString or fields[name].strVal.len == 0:
    configError(context & " ^" & name & " must be a nonempty Str")
  fields[name].strVal

proc decodedKey(encoded, context: string): string =
  if encoded.len != 44:
    configError(context & " must be canonical base64 Ed25519 public key")
  try:
    result = base64.decode(encoded)
  except ValueError:
    configError(context & " is not base64")
  if result.len != 32 or base64.encode(result) != encoded:
    configError(context & " must be canonical base64 Ed25519 public key")

proc loadRegistryConfig*(configPath: string): RegistryConfig =
  if configPath.len == 0:
    configError("an explicit config file is required")
  let path = normalizedPath(absolutePath(configPath))
  if not fileExists(path) or getFileSize(path) > MaxRegistryConfigBytes:
    configError("file is missing or exceeds 64 KiB")
  var forms: seq[Value]
  try:
    forms = readAll(readFile(path), path,
      ReadOptions(maxDepth: 8, rejectDuplicateProps: true))
  except ReadError as error:
    configError(error.msg)
  if forms.len != 1:
    configError("file must contain exactly one Map")
  let config = fieldsExactly(forms[0],
    ["registry_config_format", "registries", "default"],
    ["registry_config_format", "registries"], "root")
  if config["registry_config_format"].kind != vkInt or
      config["registry_config_format"].intVal != 1:
    configError("^registry_config_format must be 1")
  if config["registries"].kind != vkList or
      config["registries"].listItems.len > 16:
    configError("^registries must be a List of at most 16 entries")
  var adapters: seq[PackageSourceAdapter]
  for value in config["registries"].listItems:
    let entry = fieldsExactly(value,
      ["name", "url", "registry_key", "curl", "crypto", "ca_file",
       "cache_root", "pinned_owner_keys", "publish_token_file",
       "timeout_seconds"],
      ["name", "url", "registry_key", "curl", "crypto", "cache_root"],
      "registry")
    let name = strField(entry, "name", "registry")
    let url = strField(entry, "url", "registry")
    let curl = strField(entry, "curl", "registry")
    let cryptoPath = strField(entry, "crypto", "registry")
    let cacheRoot = strField(entry, "cache_root", "registry")
    let key = decodedKey(strField(entry, "registry_key", "registry"),
      "registry ^registry_key")
    var caFile = ""
    if entry.hasKey("ca_file"):
      caFile = strField(entry, "ca_file", "registry")
    var tokenFile = ""
    if entry.hasKey("publish_token_file"):
      tokenFile = strField(entry, "publish_token_file", "registry")
      if not tokenFile.isAbsolute or not fileExists(tokenFile) or
          getFileInfo(tokenFile, followSymlink = true).isSpecial or
          getFileSize(tokenFile) > 4096:
        configError("registry ^publish_token_file must be a bounded absolute file")
    var timeoutSeconds = DefaultRegistryTimeoutSeconds
    if entry.hasKey("timeout_seconds"):
      if entry["timeout_seconds"].kind != vkInt or
          entry["timeout_seconds"].intVal < 1 or
          entry["timeout_seconds"].intVal > 300:
        configError("registry ^timeout_seconds must be between 1 and 300")
      timeoutSeconds = int(entry["timeout_seconds"].intVal)
    var pinned = initTable[string, string]()
    if entry.hasKey("pinned_owner_keys"):
      if entry["pinned_owner_keys"].kind != vkMap or
          entry["pinned_owner_keys"].mapEntries.len > 64:
        configError("registry ^pinned_owner_keys must be a bounded Map")
      for owner, encoded in entry["pinned_owner_keys"].mapEntries:
        if encoded.kind != vkString:
          configError("owner pin must be a base64 Str")
        pinned[owner] = decodedKey(encoded.strVal, "owner pin")
    if not cacheRoot.isAbsolute:
      configError("registry ^cache_root must be an absolute path")
    let transport = newRegistryHttpsTransport(url, curl, caFile,
                                               timeoutSeconds)
    let crypto = loadReleaseCrypto(cryptoPath)
    let trust = newReleaseTrust(key, pinned)
    let adapter = newHostedRegistry(name, transport, crypto, trust, cacheRoot)
    result.registries.add ConfiguredRegistry(name: name, transport: transport,
      crypto: crypto, trust: trust, adapter: adapter,
      publishTokenFile: tokenFile)
    adapters.add adapter
  let defaultRegistry =
    if config.hasKey("default"):
      strField(config, "default", "root")
    else: ""
  let validated = newPackageManager(registries = adapters,
                                    defaultRegistry = defaultRegistry)
  result.defaultRegistry = validated.defaultRegistry

proc packageManagerFromRegistryConfig*(configPath: string,
                                       userStoreRoot = ""):
                                       PackageManager =
  if configPath.len == 0:
    return newPackageManager(userStoreRoot)
  let config = loadRegistryConfig(configPath)
  var adapters: seq[PackageSourceAdapter]
  for registry in config.registries:
    adapters.add registry.adapter
  newPackageManager(userStoreRoot, adapters,
                    defaultRegistry = config.defaultRegistry)

proc configuredRegistryForPublish*(configPath, requestedName: string):
                                   ConfiguredRegistry =
  let config = loadRegistryConfig(configPath)
  let name = if requestedName.len > 0: requestedName
             else: config.defaultRegistry
  for registry in config.registries:
    if registry.name == name:
      if registry.publishTokenFile.len == 0:
        configError("selected registry has no ^publish_token_file")
      return registry
  configError("publish registry is not configured: " & name)
