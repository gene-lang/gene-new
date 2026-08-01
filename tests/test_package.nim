import gene/[digest, package, printer, types, unicode_package, vm]
import std/[os, strutils, tables, unittest]

proc packageTestRoot(name: string): string =
  result = getTempDir() / ("gene_package_" & name)
  if dirExists(result):
    makeMaterializedTreeWritable(result)
    removeDir(result)
  createDir(result)

proc writePackageFile(path, source: string) =
  createDir(parentDir(path))
  writeFile(path, source)

proc raisedPackageClass(body: proc ()): PackageErrorClass =
  try:
    body()
  except PackageError as error:
    return error.class
  raise newException(ValueError, "expected PackageError")

proc appendTestU64(bytes: var string, value: uint64) =
  for shift in countdown(56, 0, 8):
    bytes.add char((value shr shift) and 0xff'u64)

suite "package manager — format 1 workspace graph":
  test "package paths use pinned Unicode 15.1 NFC and full case folding":
    check unicodeNfc151("e\u0301") == "\u00E9"
    check unicodeNfc151("\u1100\u1161") == "\uAC00"
    check unicodeDefaultCaseFold151("Stra\u00DFe") == "strasse"
    check unicodeDefaultCaseFold151("\u0130") == "i\u0307"

    let root = packageTestRoot("manifest_unicode_nfc")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^library {^entry "src/e\u0301.gene"}}
""")
    check raisedPackageClass(proc () =
      discard loadPackageAt(root, poEntry)) == pecManifestInvalid

  test "manifest data rejects duplicate fields and non-canonical target paths":
    let root = packageTestRoot("manifest_hardening")
    writePackageFile(root / "package.gene", """
{^format 1 ^format 1 ^name "acme/app" ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    check raisedPackageClass(proc () =
      discard loadPackageAt(root, poEntry)) == pecManifestInvalid
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^library {^entry "../secret.gene"}}
""")
    check raisedPackageClass(proc () =
      discard loadPackageAt(root, poEntry)) == pecManifestInvalid

  test "source package digest hashes the specified gpkg byte stream":
    let root = packageTestRoot("source_package_digest")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/lib" ^version "1.2.3"
 ^library {^entry "src/index.gene"}}
""")
    writePackageFile(root / "src/index.gene", "(var answer 42)\n")
    let pkg = loadPackageAt(root, poRegistrySource)
    let treeDigest = sourceTreeDigest(pkg)
    var metadata = initPropTable()
    metadata["format"] = newInt(1)
    metadata["name"] = newStr(pkg.name)
    metadata["version"] = newStr(pkg.version)
    metadata["manifest_digest"] = newStr(pkg.manifestDigest)
    metadata["tree_digest"] = newStr(treeDigest)
    let metadataBytes = canonicalGeneData(newMap(metadata))
    var expectedBytes = "gene-gpkg-v1\0"
    expectedBytes.appendTestU64(uint64(metadataBytes.len))
    expectedBytes.add metadataBytes
    let treeBytes = sourceTreeBytes(pkg)
    expectedBytes.add treeBytes["gene-tree-v1\0".len .. ^1]

    check sourcePackageDigest(pkg, treeDigest) ==
      "sha256:" & sha256Hex(expectedBytes)

  test "source trees normalize safe symlinks and reject unselected targets":
    when defined(posix):
      let root = packageTestRoot("source_symlinks")
      writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/lib" ^version "1.0.0"
 ^library {^entry "src/data.gene"}}
""")
      writePackageFile(root / "src/data.gene", "(var answer 42)\n")
      createDir(root / "src/nested")
      createSymlink("./nested/../data.gene", root / "src/link.gene")
      let pkg = loadPackageAt(root, poRegistrySource)
      let bytes = sourceTreeBytes(pkg)
      check "nested" notin bytes
      check "data.gene" in bytes

      writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/lib" ^version "1.0.0"
 ^library {^entry "src/link.gene"}
 ^files {^include ["package.gene" "src/link.gene"]}}
""")
      let unselected = loadPackageAt(root, poRegistrySource)
      check raisedPackageClass(proc () =
        discard sourceTreeDigest(unselected)) == pecBoundary

      writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/lib" ^version "1.0.0"
 ^library {^entry "src/data.gene"}}
""")
      createSymlink("cycle_b", root / "src/cycle_a")
      createSymlink("cycle_a", root / "src/cycle_b")
      let cyclic = loadPackageAt(root, poRegistrySource)
      check raisedPackageClass(proc () =
        discard sourceTreeDigest(cyclic)) == pecBoundary
      removeFile(root / "src/cycle_a")
      removeFile(root / "src/cycle_b")
      createDir(root / "src/dir")
      writePackageFile(root / "src/dir/data.gene", "(var data 1)\n")
      createSymlink("dir", root / "src/a")
      createSymlink("../a", root / "src/dir/back")
      let directoryCycle = loadPackageAt(root, poRegistrySource)
      check raisedPackageClass(proc () =
        discard sourceTreeDigest(directoryCycle)) == pecBoundary

  test "source-tree collisions include implicit directory topology":
    let root = packageTestRoot("source_topology_collision")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/lib" ^version "1.0.0"
 ^library {^entry "src/ff"}}
""")
    writePackageFile(root / "src/ff", "file")
    var filesystemPermitsDistinctFoldedNames = true
    try:
      writePackageFile(root / "src/ﬀ/child.gene", "child")
    except IOError:
      filesystemPermitsDistinctFoldedNames = false
    if not filesystemPermitsDistinctFoldedNames:
      skip()
    else:
      let pkg = loadPackageAt(root, poRegistrySource)
      check raisedPackageClass(proc () =
        discard sourceTreeDigest(pkg)) == pecManifestInvalid

  test "one stable lock contains all scopes and commands project them":
    let root = packageTestRoot("dependency_scopes")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^runtime_lib (dep "acme/runtime_lib" "1.0.0" ^workspace true)}
 ^dev_dependencies {^test_tool (dep "acme/test_tool" "1.0.0" ^workspace true)}
 ^build_dependencies {^generator (dep "acme/generator" "1.0.0" ^workspace true)}}
""")
    writePackageFile(root / "src/main.gene", "(fn main [] 0)")
    for name in ["runtime_lib", "test_tool", "generator"]:
      writePackageFile(root / "packages" / name / "package.gene",
        "{^format 1 ^name \"acme/" & name &
        "\" ^version \"1.0.0\" ^library {^entry \"src/index.gene\"}}")
      writePackageFile(root / "packages" / name / "src/index.gene", "")
    let manager = newPackageManager(root / "store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let app = resolution.packagesById[resolution.activePackageId]
    check app.dependencyEdges.len == 3
    discard resolution.writeResolutionLock()
    let loaded = manager.loadResolutionLock(root)
    let graph = manager.sync(loaded,
      SyncPolicy(offline: true, locked: true, userStoreRoot: root / "store"))
    check graph.packageForAlias(app.id, "runtime_lib").name ==
      "acme/runtime_lib"
    check raisedPackageClass(proc () =
      discard graph.packageForAlias(app.id, "test_tool")) == pecNotDeclared
    graph.includeDevelopment = true
    check graph.packageForAlias(app.id, "test_tool").name == "acme/test_tool"
    check raisedPackageClass(proc () =
      discard graph.packageForAlias(app.id, "generator")) == pecNotDeclared

  test "locked edges cannot be omitted or redirect a path locator":
    let root = packageTestRoot("locked_edge_integrity")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^tool (dep "acme/tool" "1.0.0" ^path "deps/tool")}}
""")
    writePackageFile(root / "src/main.gene", "(fn main [] 0)")
    writePackageFile(root / "deps/tool/package.gene", """
{^format 1 ^name "acme/tool" ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writePackageFile(root / "deps/tool/src/index.gene", "")
    let manager = newPackageManager(root / "store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let lockPath = resolution.writeResolutionLock()
    let original = readFile(lockPath)
    writePackageFile(lockPath, original.replace(
      "^tool (locked_edge ^scope runtime ^target", 
      "^omitted (locked_edge ^scope runtime ^target"))
    check raisedPackageClass(proc () =
      discard manager.loadResolutionLock(root)) == pecIdentityMismatch
    writePackageFile(lockPath, original.replace(
      "(path ^path \"deps/tool\")", "(path ^path \"deps/redirected\")"))
    check raisedPackageClass(proc () =
      discard manager.loadResolutionLock(root)) == pecIdentityMismatch

  test "lock compiler compatibility is enforced when present":
    let root = packageTestRoot("lock_compiler_compatibility")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writePackageFile(root / "src/main.gene", "(fn main [] 0)")
    let manager = newPackageManager(root / "store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let lockPath = resolution.writeResolutionLock()
    let original = readFile(lockPath)
    writePackageFile(lockPath, original.replace(
      "^runtime \">=0.1.0 <0.2.0\"))",
      "^runtime \">=0.1.0 <0.2.0\" ^compiler \">=9.0.0\"))"))
    check raisedPackageClass(proc () =
      discard manager.loadResolutionLock(root)) == pecVersionMismatch

  test "an unqualified dependency uses the configured default registry":
    let root = packageTestRoot("default_registry")
    let appRoot = root / "app"
    writePackageFile(appRoot / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^lib (dep "acme/lib" "*")}}
""")
    writePackageFile(appRoot / "src/main.gene", "(fn main [] 0)")
    for item in [("one", "1.0.0"), ("two", "2.0.0")]:
      writePackageFile(root / item[0] / "acme/lib" / item[1] /
        "package.gene", "{^format 1 ^name \"acme/lib\" ^version \"" &
        item[1] & "\" ^library {^entry \"src/index.gene\"}}")
      writePackageFile(root / item[0] / "acme/lib" / item[1] /
        "src/index.gene", "")
    let registries = @[
      newFilesystemRegistry("one", root / "one"),
      newFilesystemRegistry("two", root / "two")]
    let manager = newPackageManager(root / "store", registries, nil, "two")
    let resolution = manager.resolve(ResolveRequest(startDir: appRoot))
    let app = resolution.packagesById[resolution.activePackageId]
    let selected = resolution.packagesById[app.dependencyEdges["lib"]]
    check selected.sourceName == "two"
    check selected.version == "2.0.0"

  test "one workspace lock roots every independently buildable member":
    let root = packageTestRoot("workspace_roots")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writePackageFile(root / "src/main.gene", "(fn main [] 0)")
    writePackageFile(root / "packages/tool/package.gene", """
{^format 1 ^name "acme/tool" ^version "1.0.0"
 ^applications [(application "tool" ^entry "src/main.gene")]}
""")
    writePackageFile(root / "packages/tool/src/main.gene", "(fn main [] 0)")

    let resolution = newPackageManager().resolve(ResolveRequest(startDir: root))
    check resolution.rootPackageIds.len == 2
    check resolution.packagesById.len == 2
    check resolution.activePackageId in resolution.rootPackageIds

  test "a declared co-lived member keeps its own package identity":
    let root = packageTestRoot("workspace_alias")
    writePackageFile(root / "package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^pkg1 (dep "acme/pkg1" "1.0.0" ^workspace true)}}
""")
    writePackageFile(root / "src/main.gene", "(fn main [] 0)")
    writePackageFile(root / "packages/pkg1/package.gene", """
{^format 1
 ^name "acme/pkg1"
 ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writePackageFile(root / "packages/pkg1/src/index.gene", "(var answer 42)")

    let manager = newPackageManager()
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let graph = manager.sync(resolution, SyncPolicy(offline: true))
    let active = graph.packagesById[graph.activePackageId]
    let member = graph.packageForAlias(active.id, "pkg1")

    check active.name == "acme/app"
    check member.name == "acme/pkg1"
    check member.root == normalizedPath(root / "packages/pkg1")
    check member.id != active.id

  test "a member path dependency stays relative to its declaring package":
    let root = packageTestRoot("member_relative_path")
    writePackageFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writePackageFile(root / "src/main.gene", "(fn main [] 0)")
    writePackageFile(root / "packages/pkg1/package.gene", """
{^format 1 ^name "acme/pkg1" ^version "1.0.0"
 ^library {^entry "src/index.gene"}
 ^dependencies {^external (dep "acme/external" "1.0.0"
   ^path "../../external")}}
""")
    writePackageFile(root / "packages/pkg1/src/index.gene", "")
    writePackageFile(root / "external/package.gene", """
{^format 1 ^name "acme/external" ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writePackageFile(root / "external/src/index.gene", "")
    let manager = newPackageManager(root / "store")
    let resolved = manager.resolve(ResolveRequest(
      startDir: root / "packages/pkg1"))
    let lockPath = resolved.writeResolutionLock()
    check "^path \"../../external\"" in readFile(lockPath)

    let loaded = manager.loadResolutionLock(root / "packages/pkg1")
    let graph = manager.sync(loaded,
      SyncPolicy(offline: true, locked: true,
                 userStoreRoot: root / "store"))
    var member: Package
    for _, pkg in graph.packagesById:
      if pkg.name == "acme/pkg1": member = pkg
    check member != nil
    check graph.packageForAlias(member.id, "external").root ==
      normalizedPath(root / "external")

  test "two aliases isolate two versions of the same package at runtime":
    let root = packageTestRoot("duplicate_versions")
    writePackageFile(root / "app/package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^c_v1 (dep "acme/c" "1.0.0" ^path "../c1")
   ^c_v2 (dep "acme/c" "2.0.0" ^path "../c2")}}
""")
    for (dir, version, answer) in [("c1", "1.0.0", 10),
                                    ("c2", "2.0.0", 20)]:
      writePackageFile(root / dir / "package.gene",
        "{^format 1 ^name \"acme/c\" ^version \"" & version &
        "\" ^library {^entry \"src/index.gene\"}}")
      writePackageFile(root / dir / "src/index.gene",
        "(var answer " & $answer & ")")
    writePackageFile(root / "app/src/main.gene", """
(import [answer : one] from "." ^pkg "c_v1")
(import [answer : two] from "." ^pkg "c_v2")
(var answers [one two])
""")

    let app = newApplicationForEntryFile(root / "app/src/main.gene")
    let module = app.loadFileModule(root / "app/src/main.gene")
    let scope = module.moduleRootNamespace.nsScope
    scope.materializeMirroredVars()
    check scope.vars["answers"].print() == "[10 20]"

    let first = app.locatePackage("c_v1")
    let second = app.locatePackage("c_v2")
    check first.name == second.name
    check first.version == "1.0.0"
    check second.version == "2.0.0"
    check first.id != second.id

  test "registry source is part of immutable package instance identity":
    let root = packageTestRoot("registry_identity")
    let appRoot = root / "app"
    writePackageFile(appRoot / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^from_one (dep "acme/c" "1.0.0" ^registry "one")
   ^from_two (dep "acme/c" "1.0.0" ^registry "two")}}
""")
    writePackageFile(appRoot / "src/main.gene", "(fn main [] 0)")
    for registry in ["one", "two"]:
      writePackageFile(root / registry / "acme/c/1.0.0/package.gene",
        "{^format 1 ^name \"acme/c\" ^version \"1.0.0\" " &
        "^library {^entry \"src/index.gene\"}}")
      writePackageFile(root / registry / "acme/c/1.0.0/src/index.gene",
        "(var answer 42)")
    let manager = newPackageManager(root / "store", @[
      newFilesystemRegistry("one", root / "one"),
      newFilesystemRegistry("two", root / "two")])
    let resolution = manager.resolve(ResolveRequest(startDir: appRoot))
    let app = resolution.packagesById[resolution.activePackageId]
    let one = resolution.packagesById[app.dependencyEdges["from_one"]]
    let two = resolution.packagesById[app.dependencyEdges["from_two"]]
    check one.id != two.id
    check one.sourceName == "one"
    check two.sourceName == "two"

  test "git selectors lock and reacquire one exact commit":
    let root = packageTestRoot("git_adapter")
    let appRoot = root / "app"
    let checkoutRoot = root / "checkout"
    let commit = repeat('a', 40)
    writePackageFile(appRoot / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^lib (dep "acme/lib" "^1.0.0"
   ^git "https://EXAMPLE.invalid/acme/./lib.git" ^branch "main")}}
""")
    writePackageFile(appRoot / "src/main.gene", "(fn main [] 0)")
    writePackageFile(checkoutRoot / "package.gene", """
{^format 1 ^name "acme/lib" ^version "1.2.0"
 ^library {^entry "src/index.gene"}}
""")
    writePackageFile(checkoutRoot / "src/index.gene", "(var answer 42)")
    var selectorKinds: seq[string]
    let gitAdapter: GitSourceAdapter = proc (
        canonicalUrl, selectorKind, selector: string,
        offline: bool): GitCheckout =
      check not offline
      check canonicalUrl == "https://example.invalid/acme/lib.git"
      selectorKinds.add selectorKind & ":" & selector
      GitCheckout(root: checkoutRoot, canonicalUrl: canonicalUrl,
                  commit: commit)
    let manager = newPackageManager(root / "store", @[], gitAdapter)
    let resolution = manager.resolve(ResolveRequest(startDir: appRoot))
    let app = resolution.packagesById[resolution.activePackageId]
    let gitPkg = resolution.packagesById[app.dependencyEdges["lib"]]
    check gitPkg.sourceName == "https://example.invalid/acme/lib.git"
    check gitPkg.sourcePath == commit
    discard resolution.writeResolutionLock()

    let restarted = newPackageManager(root / "fresh_store", @[], gitAdapter)
    let loaded = restarted.loadResolutionLock(appRoot)
    let graph = restarted.sync(loaded,
      SyncPolicy(locked: true, userStoreRoot: root / "fresh_store"))
    check graph.packageForAlias(graph.activePackageId, "lib").version == "1.2.0"
    check selectorKinds == @["branch:main", "commit:" & commit]

  test "package imports never fall back outside the declared library root":
    let root = packageTestRoot("no_root_fallback")
    writePackageFile(root / "app/package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^dep (dep "acme/dep" "1.0.0" ^path "../dep")}}
""")
    writePackageFile(root / "app/src/main.gene",
      "(import [secret] from \"secret\" ^pkg \"dep\")")
    writePackageFile(root / "dep/package.gene", """
{^format 1 ^name "acme/dep" ^version "1.0.0"
 ^library {^entry "lib/index.gene"}}
""")
    writePackageFile(root / "dep/lib/index.gene", "(var public true)")
    writePackageFile(root / "dep/secret.gene", "(var secret 42)")
    let class = raisedPackageClass(proc () =
      let app = newApplicationForEntryFile(root / "app/src/main.gene")
      discard app.loadFileModule(root / "app/src/main.gene"))
    check class == pecModuleNotFound

  test "a transitive graph vendors three versions as distinct objects":
    let root = packageTestRoot("transitive_versions")
    let registry = root / "registry"
    let appRoot = root / "app"
    let userStore = root / "user_store"
    writePackageFile(appRoot / "package.gene", """
{^format 1
 ^name "acme/a"
 ^version "1.0.0"
 ^applications [(application "a" ^entry "src/main.gene")]
 ^dependencies {
   ^b (dep "acme/b" "1.0.0")
   ^c (dep "acme/c" "1.1.0")
   ^d (dep "acme/d" "1.0.0")}}
""")
    writePackageFile(appRoot / "src/main.gene", "(fn main [] 0)")

    proc registryPackage(name, version, dependencies, answer: string) =
      let dir = registry / name / version
      writePackageFile(dir / "package.gene",
        "{^format 1 ^name \"" & name & "\" ^version \"" & version &
        "\" ^library {^entry \"src/index.gene\"}" & dependencies & "}")
      writePackageFile(dir / "src/index.gene",
        "(var answer \"" & answer & "\")")

    registryPackage("acme/b", "1.0.0",
      " ^dependencies {^c (dep \"acme/c\" \"1.0.0\")}", "b")
    registryPackage("acme/c", "1.0.0", "", "c10")
    registryPackage("acme/c", "1.1.0", "", "c11")
    registryPackage("acme/c", "1.2.0", "", "c12")
    registryPackage("acme/d", "1.0.0",
      " ^dependencies {^c (dep \"acme/c\" \"1.2.0\")}", "d")

    let manager = newPackageManager(userStore,
      @[newFilesystemRegistry("test", registry)])
    let resolution = manager.resolve(ResolveRequest(startDir: appRoot))
    discard resolution.writeResolutionLock()
    let graph = manager.sync(resolution,
      SyncPolicy(offline: true, locked: true, userStoreRoot: userStore))
    let a = graph.packagesById[graph.activePackageId]
    let b = graph.packageForAlias(a.id, "b")
    let c11 = graph.packageForAlias(a.id, "c")
    let d = graph.packageForAlias(a.id, "d")
    let c10 = graph.packageForAlias(b.id, "c")
    let c12 = graph.packageForAlias(d.id, "c")

    check [c10.version, c11.version, c12.version] ==
      ["1.0.0", "1.1.0", "1.2.0"]
    check c10.id != c11.id
    check c11.id != c12.id
    check c10.id != c12.id

    let receipt = manager.vendor(graph,
      VendorRequest(destination: appRoot / "vendor/packages"))
    for pkg in [c10, c11, c12]:
      check receipt.packagePaths.hasKey(pkg.id)
      check fileExists(receipt.packagePaths[pkg.id] / "package.gene")
      check ("/acme/c/" & pkg.version & "/") in
        receipt.packagePaths[pkg.id].replace('\\', '/')
    makeMaterializedTreeWritable(userStore)
    removeDir(userStore)
    removeDir(registry)
    let offlineManager = newPackageManager(userStore)
    let locked = offlineManager.loadResolutionLock(appRoot)
    let offlineGraph = offlineManager.sync(locked,
      SyncPolicy(offline: true, locked: true, userStoreRoot: userStore))
    let offlineA = offlineGraph.packagesById[offlineGraph.activePackageId]
    let offlineB = offlineGraph.packageForAlias(offlineA.id, "b")
    let offlineD = offlineGraph.packageForAlias(offlineA.id, "d")
    check offlineGraph.packageForAlias(offlineB.id, "c").version == "1.0.0"
    check offlineGraph.packageForAlias(offlineA.id, "c").version == "1.1.0"
    check offlineGraph.packageForAlias(offlineD.id, "c").version == "1.2.0"

  test "a format-1 lock round-trips without re-solving":
    let root = packageTestRoot("lock_round_trip")
    writePackageFile(root / "package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^tool (dep "acme/tool" "1.0.0" ^workspace true)}}
""")
    writePackageFile(root / "src/main.gene", "(fn main [] 0)")
    writePackageFile(root / "packages/tool/package.gene", """
{^format 1
 ^name "acme/tool"
 ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writePackageFile(root / "packages/tool/src/index.gene", "(var answer 42)")
    let manager = newPackageManager(root / "user_store")
    let resolved = manager.resolve(ResolveRequest(startDir: root))
    let lockPath = resolved.writeResolutionLock()
    let firstBytes = readFile(lockPath)
    discard resolved.writeResolutionLock()
    check readFile(lockPath) == firstBytes

    let loaded = manager.loadResolutionLock(root)
    let graph = manager.sync(loaded,
      SyncPolicy(offline: true, locked: true,
                 userStoreRoot: root / "user_store"))
    let active = graph.packagesById[graph.activePackageId]
    check graph.packageForAlias(active.id, "tool").name == "acme/tool"
    check loaded.lockDigest.startsWith("sha256:")

  test "offline sync reports every immutable object missing after restart":
    let root = packageTestRoot("offline_missing")
    let registry = root / "registry"
    let appRoot = root / "app"
    let store = root / "store"
    writePackageFile(appRoot / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^one (dep "acme/one" "1.0.0")
   ^two (dep "acme/two" "1.0.0")}}
""")
    writePackageFile(appRoot / "src/main.gene", "(fn main [] 0)")
    for name in ["one", "two"]:
      writePackageFile(registry / "acme" / name / "1.0.0/package.gene",
        "{^format 1 ^name \"acme/" & name &
        "\" ^version \"1.0.0\" ^library {^entry \"src/index.gene\"}}")
      writePackageFile(registry / "acme" / name / "1.0.0/src/index.gene",
        "(var name \"" & name & "\")")
    let manager = newPackageManager(store,
      @[newFilesystemRegistry("test", registry)])
    let solved = manager.resolve(ResolveRequest(startDir: appRoot))
    discard solved.writeResolutionLock()
    let loaded = manager.loadResolutionLock(appRoot)
    var message = ""
    try:
      discard manager.sync(loaded,
        SyncPolicy(offline: true, locked: true, userStoreRoot: store))
    except PackageError as error:
      message = error.msg
    check "acme/one@1.0.0" in message
    check "acme/two@1.0.0" in message

    discard manager.sync(loaded,
      SyncPolicy(locked: true, userStoreRoot: store))
    let offline = manager.sync(loaded,
      SyncPolicy(offline: true, locked: true, userStoreRoot: store))
    check offline.packagesById.len == 3

  test "cache GC preserves live locks and removes stale project roots":
    let root = packageTestRoot("cache_gc")
    let registry = root / "registry"
    let appRoot = root / "app"
    let store = root / "store"
    writePackageFile(appRoot / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^lib (dep "acme/lib" "1.0.0")}}
""")
    writePackageFile(appRoot / "src/main.gene", "(fn main [] 0)")
    writePackageFile(registry / "acme/lib/1.0.0/package.gene", """
{^format 1 ^name "acme/lib" ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writePackageFile(registry / "acme/lib/1.0.0/src/index.gene", "")
    let manager = newPackageManager(store,
      @[newFilesystemRegistry("test", registry)])
    let resolution = manager.resolve(ResolveRequest(startDir: appRoot))
    let lockPath = resolution.writeResolutionLock()
    discard manager.sync(resolution,
      SyncPolicy(locked: true, userStoreRoot: store))
    let live = manager.cacheGc()
    check live.keptObjects == 1
    check live.removedObjects == 0

    removeFile(lockPath)
    let stale = manager.cacheGc()
    check stale.keptObjects == 0
    check stale.removedObjects == 1
    check stale.removedRootReceipts == 1

  test "the solver minimizes instances, expands features, and enforces singleton":
    let root = packageTestRoot("solver_policy")
    let registry = root / "registry"
    let appRoot = root / "app"
    writePackageFile(appRoot / "package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^wide (dep "acme/c" "^1.0.0")
   ^narrow (dep "acme/c" ">=1.1.0 <2.0.0")
   ^plugin (dep "acme/plugin" "1.0.0" ^features [extra])}}
""")
    writePackageFile(appRoot / "src/main.gene", "(fn main [] 0)")
    for version in ["1.0.0", "1.2.0"]:
      writePackageFile(registry / "acme/c" / version / "package.gene",
        "{^format 1 ^name \"acme/c\" ^version \"" & version &
        "\" ^library {^entry \"src/index.gene\"}}")
      writePackageFile(registry / "acme/c" / version / "src/index.gene", "")
    writePackageFile(registry / "acme/plugin/1.0.0/package.gene", """
{^format 1
 ^name "acme/plugin"
 ^version "1.0.0"
 ^library {^entry "src/index.gene"}
 ^dependencies {
   ^helper (dep "acme/helper" "1.0.0" ^optional true)}
 ^features {^extra ["dep:helper"]}}
""")
    writePackageFile(registry / "acme/plugin/1.0.0/src/index.gene", "")
    writePackageFile(registry / "acme/helper/1.0.0/package.gene",
      "{^format 1 ^name \"acme/helper\" ^version \"1.0.0\" " &
      "^library {^entry \"src/index.gene\"}}")
    writePackageFile(registry / "acme/helper/1.0.0/src/index.gene", "")
    let manager = newPackageManager(root / "store",
      @[newFilesystemRegistry("test", registry)])
    let resolved = manager.resolve(ResolveRequest(startDir: appRoot))
    let app = resolved.packagesById[resolved.activePackageId]
    check app.dependencyEdges["wide"] == app.dependencyEdges["narrow"]
    check resolved.packagesById[app.dependencyEdges["wide"]].version == "1.2.0"
    let plugin = resolved.packagesById[app.dependencyEdges["plugin"]]
    check plugin.selectedFeatures == @["extra"]
    check plugin.dependencyEdges.hasKey("helper")

    writePackageFile(appRoot / "package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^old (dep "acme/single" "1.0.0")
   ^new (dep "acme/single" "2.0.0")}}
""")
    for version in ["1.0.0", "2.0.0"]:
      writePackageFile(registry / "acme/single" / version / "package.gene",
        "{^format 1 ^name \"acme/single\" ^version \"" & version &
        "\" ^singleton true ^library {^entry \"src/index.gene\"}}")
      writePackageFile(registry / "acme/single" / version / "src/index.gene", "")
    check raisedPackageClass(proc () =
      discard manager.resolve(ResolveRequest(startDir: appRoot))) ==
      pecVersionConflict

  test "prereleases require an explicit comparator prerelease":
    check matchesConstraint("1.2.0-beta.1", "^1.2.0-beta.1", "test")
    check not matchesConstraint("1.2.0-beta.1", ">=1.0.0 <2.0.0", "test")
    check parseSemVersion("1.2.0+linux.x86-64", "test").build ==
      "linux.x86-64"
    check raisedPackageClass(proc () =
      discard parseSemVersion("1.2.0+bad+metadata", "test")) ==
      pecManifestInvalid
    check raisedPackageClass(proc () =
      discard parseSemVersion("1.2.0+bad_metadata", "test")) ==
      pecManifestInvalid

  test "resolution retains valid locked edges until explicitly updated":
    let root = packageTestRoot("lock_retention")
    let registry = root / "registry"
    writePackageFile(root / "app/package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^c (dep "acme/c" "^1.0.0")}}
""")
    writePackageFile(root / "app/src/main.gene", "(fn main [] 0)")
    proc addC(version: string) =
      writePackageFile(registry / "acme/c" / version / "package.gene",
        "{^format 1 ^name \"acme/c\" ^version \"" & version &
        "\" ^library {^entry \"src/index.gene\"}}")
      writePackageFile(registry / "acme/c" / version / "src/index.gene", "")
    addC("1.0.0")
    let manager = newPackageManager(root / "store",
      @[newFilesystemRegistry("test", registry)])
    let initial = manager.resolve(ResolveRequest(startDir: root / "app"))
    discard initial.writeResolutionLock()
    addC("1.2.0")

    let retained = manager.resolve(ResolveRequest(startDir: root / "app"))
    let retainedRoot = retained.packagesById[retained.activePackageId]
    check retained.packagesById[retainedRoot.dependencyEdges["c"]].version ==
      "1.0.0"
    let updated = manager.resolve(ResolveRequest(
      startDir: root / "app", unlockAliases: @["c"]))
    let updatedRoot = updated.packagesById[updated.activePackageId]
    check updated.packagesById[updatedRoot.dependencyEdges["c"]].version ==
      "1.2.0"
