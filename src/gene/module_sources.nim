## Immutable source bundles acquired by the trusted native loader. No authority
## or resource handles are retained in, or exposed through, a bundle.
import std/[algorithm, os, strutils, tables]
import ./[capabilities, digest, fs_capabilities]

type
  ModuleSourceLimits* = object
    maxFileBytes*, maxTotalBytes*, maxFiles*, maxEntries*, maxDepth*: int
  ModuleSourceSnapshot* = ref object
    directory: string
    identity: string
    byteCount: int
    sources: Table[string, string]

const DefaultModuleSourceLimits* = ModuleSourceLimits(
  maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 32 * 1024 * 1024,
  maxFiles: 1024, maxEntries: 16384, maxDepth: 64)

proc sourceDigest*(snapshot: ModuleSourceSnapshot): string = snapshot.identity
proc sourceBytes*(snapshot: ModuleSourceSnapshot): int = snapshot.byteCount
proc sourceCount*(snapshot: ModuleSourceSnapshot): int = snapshot.sources.len
proc sourcePaths*(snapshot: ModuleSourceSnapshot): seq[string] =
  if snapshot != nil:
    for path in snapshot.sources.keys: result.add path
    result.sort()
proc hasSource*(snapshot: ModuleSourceSnapshot, path: string): bool =
  snapshot != nil and snapshot.sources.hasKey(path)
proc sourceText*(snapshot: ModuleSourceSnapshot, path: string): string =
  if not snapshot.hasSource(path):
    raise newException(CapabilityError, "source is absent from the admitted snapshot: " & path)
  snapshot.sources[path]

proc sealSourceSnapshot(snapshot: ModuleSourceSnapshot) =
  var digest = initSha256()
  digest.update("gene-module-sources-v1:")
  for path in snapshot.sourcePaths:
    let relative = relativePath(path, snapshot.directory)
    let source = snapshot.sources[path]
    digest.update($relative.len & ":" & relative & $source.len & ":")
    digest.update(source)
  snapshot.identity = "sha256:" & digest.finishHex()

proc captureModuleSourceFile*(provider: FilesystemProvider, path: string,
    maxBytes = DefaultModuleSourceLimits.maxFileBytes): ModuleSourceSnapshot =
  ## The launcher entry admits this file, not neighboring modules.
  if not path.isAbsolute or '\0' in path or not path.endsWith(".gene") or
      maxBytes < 0 or maxBytes == high(int):
    raise newException(CapabilityError, "invalid admitted module source file")
  let absolute = normalizedPath(path)
  let root = parentDir(absolute)
  let registry = provider.capabilityRegistry
  let literal = buildCapabilityLiteral([
    CapabilityEntryLiteral(name: "fs/Read", body: @[capabilityText(root)])],
    cuGrant, CapabilitySourceContext(name: "entry source acquisition"))
  let policy = registry.normalizeCapabilityRow(literal, cuGrant)
  let grant = provider.initializeFilesystemGrant(policy.entries[0].policy)
  defer: provider.releaseFilesystemGrant(grant)
  let context = registry.newPolicyContext([grant])
  let file = provider.openFilesystemFile(context, absolute)
  defer: file.close()
  let source = file.readBytes(context, maxBytes + 1)
  if source.len > maxBytes:
    raise newException(CapabilityError, "module source byte limit exceeded")
  result = ModuleSourceSnapshot(directory: root, byteCount: source.len)
  result.sources[absolute] = source
  result.sealSourceSnapshot()

proc selectModuleSources*(snapshot: ModuleSourceSnapshot,
    paths: openArray[string]): ModuleSourceSnapshot =
  ## Host selection over already captured bytes, with no filesystem fallback.
  if snapshot == nil:
    raise newException(CapabilityError, "module source snapshot is nil")
  result = ModuleSourceSnapshot(directory: snapshot.directory)
  for path in paths:
    if result.sources.hasKey(path): continue
    let source = snapshot.sourceText(path)
    result.sources[path] = source
    result.byteCount += source.len
  result.sealSourceSnapshot()

proc captureModuleSources*(provider: FilesystemProvider, directory: string,
    limits = DefaultModuleSourceLimits): ModuleSourceSnapshot =
  if limits.maxFileBytes < 0 or limits.maxTotalBytes < 0 or
      limits.maxFileBytes == high(int) or limits.maxFiles < 1 or
      limits.maxEntries < 1 or limits.maxDepth < 0:
    raise newException(CapabilityError, "invalid module source limits")
  if not directory.isAbsolute or '\0' in directory:
    raise newException(CapabilityError, "source directory must be absolute")
  let root = normalizedPath(directory)
  let registry = provider.capabilityRegistry
  let literal = buildCapabilityLiteral([
    CapabilityEntryLiteral(name: "fs/Read", body: @[capabilityText(root)])],
    cuGrant, CapabilitySourceContext(name: "loader source acquisition"))
  let row = registry.normalizeCapabilityRow(literal, cuGrant)
  let grant = provider.initializeFilesystemGrant(row.entries[0].policy)
  defer: provider.releaseFilesystemGrant(grant)
  let privateContext = registry.newPolicyContext([grant])
  let captured = ModuleSourceSnapshot(directory: root)
  var entries = 0
  proc visit(path: string, depth: int) =
    if depth > limits.maxDepth:
      raise newException(CapabilityError, "module source directory depth limit exceeded")
    let children = provider.listDirectoryEntries(privateContext, path,
      limits.maxEntries - entries)
    entries += children.len
    for child in children:
      let target = path / child.name
      if child.kind == fekDirectory:
        visit(target, depth + 1)
      elif child.name.endsWith(".gene"):
        if child.kind != fekFile:
          raise newException(CapabilityError, "module source must be a regular non-symlink file: " & target)
        if captured.sources.len >= limits.maxFiles:
          raise newException(CapabilityError, "module source file count limit exceeded")
        let file = provider.openFilesystemFile(privateContext, target)
        let source = try: file.readBytes(privateContext,
                          min(limits.maxFileBytes, limits.maxTotalBytes - captured.byteCount) + 1)
                     finally: file.close()
        if source.len > limits.maxFileBytes or
            source.len > limits.maxTotalBytes - captured.byteCount:
          raise newException(CapabilityError, "module source byte limit exceeded")
        captured.sources[target] = source
        captured.byteCount += source.len
  visit(root, 0)
  captured.sealSourceSnapshot()
  captured
