## Module path resolution, shared by the VM loader and the documentation
## builder (design §7, Q36).
##
## This is the part of the loader that answers "which file does this import
## name mean?" without owning a `Application`: the caller supplies the
## importing package and the importing module's directory, and gets back a
## canonical absolute module path. The VM keeps its other branches — URL
## modules, sandbox roots, module cache — because those are runtime concerns.
## A documentation build never loads a module, so it needs exactly these.

import std/[os, strutils, tables]
import ./package

proc isUrlModulePath*(path: string): bool =
  path.startsWith("https://") or path.startsWith("http://")

proc moduleCandidate*(base, relPath: string): string =
  ## One module base plus one module name, with the MVP extension policy
  ## applied. A name without an extension resolves to `<name>.gene`; a file
  ## literally named `<name>` sitting beside it makes the reference ambiguous
  ## rather than silently resolving to one of the two.
  let direct = normalizedPath(absolutePath(relPath, base))
  if splitFile(relPath).ext.len > 0:
    return direct
  result = direct & ".gene"
  if fileExists(result) and fileExists(direct):
    raisePackageError(pecModuleAmbiguous,
      "module reference \"" & relPath & "\" matches two files",
      ["candidate: " & result, "candidate: " & direct])

proc resolveInModuleBases*(pkg: Package, relPath: string): string =
  ## Resolve beneath the package's single declared library root. Ad-hoc
  ## packages use their synthesized root; regular packages have no root
  ## fallback.
  var fallback = ""
  for base in pkg.moduleBases():
    let candidate = moduleCandidate(base, relPath)
    if fallback.len == 0:
      fallback = candidate
    if fileExists(candidate):
      return candidate
  if fallback.len == 0:
    raisePackageError(pecModuleNotFound,
      pkg.describe & " has no library target")
  fallback

proc packageModulePath*(pkg: Package, rawPath: string): string =
  ## Module selection inside an already-selected package (§10). Every module
  ## name resolves literally; `"."` is the only path the resolver rewrites, and
  ## it rewrites to `main_module`. `"."` can never collide with a real module
  ## because `.` does not name a file, and it works identically for regular and
  ## ad-hoc packages.
  var p = rawPath
  if p == PackageEntryModulePath:
    if pkg.mainModule.len == 0:
      raisePackageError(pecModuleNotFound,
        "\".\" has no entry module in " & pkg.describe)
    p = pkg.mainModule
  if p.isUrlModulePath:
    raisePackageError(pecBoundary,
      "a package-qualified import cannot name a URL: " & rawPath,
      ["package: " & pkg.describe])
  if p.len == 0 or p.isAbsolute or p[0] == '/':
    raisePackageError(pecBoundary,
      "a package-qualified module path must be package-relative: " & rawPath,
      ["package: " & pkg.describe])
  for segment in p.replace('\\', '/').split('/'):
    if segment == "..":
      raisePackageError(pecBoundary,
        "a package-qualified import cannot use `..`: " & rawPath,
        ["package: " & pkg.describe])
  result = resolveInModuleBases(pkg, p)
  if not pkg.contains(result):
    raisePackageError(pecBoundary,
      "module path escapes package root: " & rawPath,
      ["package: " & pkg.describe, "root: " & pkg.root])

proc resolveFileModule*(pkg: Package, moduleDir, rawPath: string): string =
  ## The branch of `resolveModuleRef` that needs no `Application`: `"."` names
  ## the package entry module, `./x` and `../x` resolve against the importing
  ## module's directory, and a bare or leading-`/` path resolves against the
  ## package's library root.
  if rawPath.isUrlModulePath:
    raisePackageError(pecBoundary,
      "a URL module reference is not a file module path: " & rawPath,
      ["package: " & pkg.describe])
  if rawPath == PackageEntryModulePath:
    return packageModulePath(pkg, rawPath)
  if rawPath.startsWith("./") or rawPath.startsWith("../"):
    result = moduleCandidate(moduleDir, rawPath)
  else:
    var p = rawPath
    if p.startsWith("/"):     # bare and leading-"/" resolve from the package
      p = p[1 .. ^1]
    result = resolveInModuleBases(pkg, p)
  if not pkg.contains(result):
    raisePackageError(pecBoundary,
      "module path escapes package root: " & rawPath,
      ["package: " & pkg.describe, "root: " & pkg.root])

proc owningPackage*(graph: MaterializedGraph, absPath: string): Package =
  ## The deepest resolved package whose root contains `absPath`. Nested
  ## packages are real boundaries, so the deepest root wins. The VM keeps its
  ## own lookup because its package table also holds external sandbox roots,
  ## which are not members of the materialized graph.
  var bestLen = -1
  for _, pkg in graph.packagesById:
    if pkg.root.len > bestLen and containsPath(pkg.root, absPath):
      result = pkg
      bestLen = pkg.root.len
