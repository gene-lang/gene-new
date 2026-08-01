## Experimental native-example bridge to the package-declared system resolver.
## Output is one tab-separated kind/flag pair per line: C for compile, L for
## link. It is intentionally not a second build interface.

import gene/[package, system_dependency]
import std/[os, tables]

if paramCount() != 2:
  stderr.writeLine "usage: system_dependency_flags <package-root> <alias>"
  quit(2)

let root = normalizedPath(absolutePath(paramStr(1)))
let alias = paramStr(2)
let pkg = loadPackageAt(root, poEntry)
if not pkg.systemDependencies.hasKey(alias):
  stderr.writeLine "unknown system dependency alias: " & alias
  quit(2)

var policy = defaultSystemDependencyPolicy()
let configured = getEnv("PKG_CONFIG")
if configured.len > 0:
  policy.pkgConfig.executable = normalizedPath(absolutePath(configured))
let resolved = newSystemDependencyResolver(policy).resolve(
  SystemDependencyRequest(
    requirement: pkg.systemDependencies[alias],
    targetTriple: hostCPU & "-unknown-" & hostOS,
    toolchainIdentity: getEnv("CC", "cc")))

for root in resolved.headerRoots:
  echo "C\t-I" & root.path
for definition in resolved.compileDefinitions:
  echo "C\t-D" & definition
for option in resolved.compileOptions:
  echo "C\t" & option
for root in resolved.libraryRoots:
  echo "L\t-L" & root.path
for name in resolved.linkNames:
  echo "L\t-l" & name
for option in resolved.linkOptions:
  echo "L\t" & option

