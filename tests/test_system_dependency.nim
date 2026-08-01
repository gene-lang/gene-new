import gene/[package, system_dependency]
import std/[os, strutils, tables, unittest]

proc systemDependencyRoot(): string =
  result = getTempDir() / "gene_system_dependency"
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "system dependency resolver — pkg_config":
  test "manifest providers can only narrow host policy":
    var requirement = SystemLibraryRequirement(
      alias: "sqlite", name: "sqlite3", version: "*",
      providers: @[spkPkgConfig])
    let resolver = newSystemDependencyResolver(SystemDependencyPolicy(
      providerOrder: @[spkVcpkg]))
    var code = sdecQueryFailed
    try:
      discard resolver.resolve(SystemDependencyRequest(
        requirement: requirement,
        targetTriple: "x86_64-test-linux-gnu",
        toolchainIdentity: "cc:test"))
    except SystemDependencyError as error:
      code = error.code
    check code == sdecProviderUnavailable

  test "a declared system library resolves through explicit host policy":
    when defined(posix):
      let root = systemDependencyRoot()
      let includeDir = root / "include"
      let libraryDir = root / "lib"
      let tracePath = root / "pkg_config_path.txt"
      createDir(includeDir)
      createDir(libraryDir)
      writeFile(includeDir / "sqlite3.h", "#define SQLITE_VERSION 3045001\n")
      createDir(root / "external")
      let externalHeader = root / "external/sqlite_ext.h"
      writeFile(externalHeader, "#define SQLITE_EXT 1\n")
      createSymlink(externalHeader, includeDir / "sqlite_ext.h")
      writeFile(libraryDir / "libsqlite3.a", "test archive bytes")
      let executable = root / "pkg-config"
      writeFile(executable, """#!/bin/sh
printf '%s' "$PKG_CONFIG_PATH" > "$TRACE_FILE"
case "$1" in
  --modversion) printf '3.45.1\n' ;;
  --cflags) printf '%s\n' "$TEST_CFLAGS" ;;
  --libs) printf '%s\n' "$TEST_LIBS" ;;
  *) exit 2 ;;
esac
""")
      setFilePermissions(executable,
        {fpUserRead, fpUserWrite, fpUserExec})
      writeFile(root / "package.gene", """
{^format 1
 ^name "acme/native_app"
 ^version "1.0.0"
 ^applications [(application "native_app" ^entry "src/main.gene")]
 ^system_dependencies {
   ^sqlite (system_library
     ^name "sqlite3"
     ^version ">=3.40.0 <4"
     ^providers [pkg_config]
     ^linkage static)}}
""")
      createDir(root / "src")
      writeFile(root / "src/main.gene", "(fn main [] 0)")
      let pkg = loadPackageAt(root, poEntry)
      let requirement = pkg.systemDependencies["sqlite"]
      var environment = initTable[string, string]()
      environment["TRACE_FILE"] = tracePath
      environment["TEST_CFLAGS"] =
        "-I" & includeDir & " -DSQLITE_THREADSAFE=1 -pthread"
      environment["TEST_LIBS"] =
        "-L" & libraryDir & " -lsqlite3 -pthread"
      let resolver = newSystemDependencyResolver(SystemDependencyPolicy(
        providerOrder: @[spkPkgConfig],
        pkgConfig: PkgConfigPolicy(
          executable: executable,
          searchPaths: @[root / "pkgconfig"],
          environment: environment)))
      let resolved = resolver.resolve(SystemDependencyRequest(
        requirement: requirement,
        targetTriple: "x86_64-test-linux-gnu",
        toolchainIdentity: "cc:test"))

      check resolved.alias == "sqlite"
      check resolved.name == "sqlite3"
      check resolved.version == "3.45.1"
      check resolved.provider == spkPkgConfig
      check resolved.linkage == slStatic
      check resolved.headerRoots.len == 1
      check resolved.headerRoots[0].path == includeDir
      check resolved.headerRoots[0].digest.startsWith("sha256:")
      check resolved.libraryFiles.len == 1
      check resolved.libraryFiles[0].path == libraryDir / "libsqlite3.a"
      check resolved.libraryFiles[0].digest.startsWith("sha256:")
      check resolved.compileDefinitions == @["SQLITE_THREADSAFE=1"]
      check resolved.compileOptions == @["-pthread"]
      check resolved.linkNames == @["sqlite3"]
      check resolved.linkOptions == @["-pthread"]
      check resolved.canonicalDigest.startsWith("sha256:")
      check readFile(tracePath) == root / "pkgconfig"

      let firstHeaderDigest = resolved.headerRoots[0].digest
      writeFile(externalHeader, "#define SQLITE_EXT 2\n")
      let changed = resolver.resolve(SystemDependencyRequest(
        requirement: requirement,
        targetTriple: "x86_64-test-linux-gnu",
        toolchainIdentity: "cc:test"))
      check changed.headerRoots[0].digest != firstHeaderDigest
