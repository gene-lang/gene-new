import gene/[build, package, process_lock, reader, types, vm]
import std/[os, strutils, tables, unittest]
when defined(posix):
  import std/posix

proc buildTestRoot(): string =
  result = getTempDir() / "gene_build_engine"
  if dirExists(result):
    makeMaterializedTreeWritable(result)
    removeDir(result)
  createDir(result)

proc writeBuildFile(path, source: string) =
  createDir(parentDir(path))
  writeFile(path, source)

proc raisedBuildCode(body: proc ()): BuildErrorCode =
  try:
    body()
  except BuildError as error:
    return error.code
  raise newException(ValueError, "expected BuildError")

suite "build engine — pure Gene targets":
  test "planning snapshots only the selected target dependency closure":
    let root = buildTestRoot()
    writeBuildFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writeBuildFile(root / "src/main.gene", "(fn main [] 0)")
    writeBuildFile(root / "packages/tool/package.gene", """
{^format 1 ^name "acme/tool" ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writeBuildFile(root / "packages/tool/src/index.gene", "")
    let manager = newPackageManager(root / "package_store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let graph = manager.sync(resolution,
      SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
    var snapped: seq[string]
    let snapshotter: SourceSnapshotter = proc (
        pkg: Package, snapshotRoot: string): Package =
      snapped.add pkg.name
      pkg
    let engine = newBuildEngine(BuildEnvironment(
      artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
      toolchains: newToolchainSet("gene-test-compiler",
                                 "x86_64-test-linux-gnu"),
      sourceSnapshotter: snapshotter))
    discard engine.build(BuildRequest(rootPackageId: graph.activePackageId,
      target: "app", profile: "dev", mode: bmVm), graph)
    check snapped == @["acme/app"]

    check raisedBuildCode(proc () =
      discard engine.build(BuildRequest(
        rootPackageId: graph.activePackageId, target: "app",
        profile: "dev", mode: bmMixed), graph)) == becRecipeUnavailable

  test "an application builds its dependency libraries and reuses derivations":
    let root = buildTestRoot()
    writeBuildFile(root / "package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^library {^entry "src/index.gene"}
 ^applications [
   (application "cli" ^entry "src/cli.gene")
   (application "admin" ^entry "src/admin.gene")]
 ^dependencies {
   ^math (dep "acme/math" "1.0.0" ^workspace true)}}
""")
    writeBuildFile(root / "src/index.gene", "(var package_name \"app\")")
    writeBuildFile(root / "src/unused.gene", "((unterminated")
    writeBuildFile(root / "src/cli.gene", """
(import [answer twice!] from "." ^pkg "math")
(var doubled (twice! answer))
(fn main [] doubled)
""")
    writeBuildFile(root / "src/admin.gene", "(fn main [] 0)")
    writeBuildFile(root / "packages/math/package.gene", """
{^format 1
 ^name "acme/math"
 ^version "1.0.0"
 ^library {^entry "src/index.gene"}
 ^dependencies {
   ^core (dep "acme/core" "1.0.0" ^workspace true)}}
""")
    writeBuildFile(root / "packages/math/src/index.gene", """
(import [base] from "." ^pkg "core")
(var answer base)
(macro twice! [x] `(+ %x %x))
""")
    writeBuildFile(root / "packages/core/package.gene", """
{^format 1
 ^name "acme/core"
 ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writeBuildFile(root / "packages/core/src/index.gene", "(var base 42)")

    let manager = newPackageManager(root / "package_store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    discard resolution.writeResolutionLock()
    let graph = manager.sync(resolution,
      SyncPolicy(offline: true, locked: true,
                 userStoreRoot: root / "package_store"))
    let engine = newBuildEngine(BuildEnvironment(
      artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
      toolchains: newToolchainSet("gene-test-compiler",
                                 "x86_64-test-linux-gnu")))
    let request = BuildRequest(
      rootPackageId: graph.activePackageId,
      target: "cli",
      profile: "dev",
      mode: bmVm,
      maxParallelism: 2)

    let first = engine.build(request, graph)
    check first.rebuilt == 3
    check first.cacheHits == 0
    check first.artifacts.len == 3
    check fileExists(first.projectView / "artifact.gir")
    check "acme/app" in readFile(first.projectView / "metadata.gene")
    check "cli" in readFile(first.projectView / "metadata.gene")
    let metadata = readAll(readFile(first.projectView / "metadata.gene"),
                           first.projectView / "metadata.gene")
    check metadata.len == 1
    check metadata[0].kind == vkMap
    check first.rootArtifact.artifactDigest.startsWith("sha256:")
    check first.rootArtifact.compiledChunk != nil
    let observation = root / ".gene/artifacts/derivations/sha256" /
      first.rootArtifact.derivationId.replace("sha256:", "") /
      "observations" /
      (first.rootArtifact.artifactDigest.replace("sha256:", "") & ".gene")
    check fileExists(observation)

    let second = engine.build(request, graph)
    check second.rebuilt == 0
    check second.cacheHits == 3
    check second.rootArtifact.derivationId == first.rootArtifact.derivationId
    check second.rootArtifact.artifactDigest == first.rootArtifact.artifactDigest
    check second.rootArtifact.compiledChunk != nil
    check "cache hit" in second.explanation

    # A disposable view is authenticated against its object reference; a
    # forged payload beside an unchanged digest marker is repaired atomically.
    removeFile(second.projectView / "artifact.gir")
    writeFile(second.projectView / "artifact.gir", "forged view")
    discard engine.build(request, graph)
    check readFile(second.projectView / "artifact.gir") != "forged view"

    # Runtime imports consume verified dependency bundles, not their source
    # snapshots. Removing the dependency source after the build must not make
    # initialization invoke the compiler again.
    var dependencyEntries: seq[string]
    var dependencyRoots: seq[string]
    for _, compiledPackage in second.executionGraph.packagesById:
      if compiledPackage.name in ["acme/math", "acme/core"]:
        dependencyRoots.add compiledPackage.root
        dependencyEntries.add(
          compiledPackage.root / compiledPackage.library.entry)
    check dependencyEntries.len == 2
    for index, dependencyEntry in dependencyEntries:
      makeMaterializedTreeWritable(dependencyRoots[index])
      removeFile(dependencyEntry)
    # Another package's compiler consumes the verified library interface and
    # macro data from GIR; dependency source is not a hidden build input.
    let compilerApp = newApplication(second.executionGraph,
      second.executionGraph.packagesById[graph.activePackageId].root)
    let directDependencyId = second.executionGraph.packagesById[
      graph.activePackageId].dependencyEdges["math"]
    for artifact in second.artifacts:
      if artifact.packageId == directDependencyId:
        compilerApp.installCompiledModules(artifact.compiledModules)
    let rebuiltEntry = compilerApp.compileFileModuleBundle(
      second.executionGraph.packagesById[graph.activePackageId].root /
        "src/cli.gene", graph.activePackageId)
    check rebuiltEntry.modules.len > 0
    let app = newApplication(second.executionGraph,
      second.executionGraph.packagesById[graph.activePackageId].root)
    for artifact in second.artifacts:
      app.installCompiledModules(artifact.compiledModules)
    check app.loadCompiledFileModule(
      second.executionGraph.packagesById[graph.activePackageId].root /
        "src/cli.gene", second.rootArtifact.compiledChunk).kind == vkModule

    when defined(posix):
      setFilePermissions(second.rootArtifact.objectPath / "artifact.gir",
        {fpUserRead, fpUserWrite})
    writeBuildFile(second.rootArtifact.objectPath / "artifact.gir",
                   "corrupted artifact bytes")
    check raisedBuildCode(proc () =
      discard engine.build(request, graph)) == becNonReproducible

  test "custom profiles contribute their effective settings to identity":
    let root = buildTestRoot()
    writeBuildFile(root / "package.gene", """
{^format 1
 ^name "acme/profiled"
 ^version "1.0.0"
 ^applications [(application "cli" ^entry "src/main.gene")]
 ^profiles {
   ^release_small (profile
     ^inherits release
     ^optimization size
     ^debug_info none
     ^assertions false
     ^sealing sealed
     ^lto true)}}
""")
    writeBuildFile(root / "src/main.gene", "(fn main [] 0)")
    let manager = newPackageManager(root / "package_store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let graph = manager.sync(resolution,
      SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
    let engine = newBuildEngine(BuildEnvironment(
      artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
      toolchains: newToolchainSet("gene-test-compiler",
                                 "x86_64-test-linux-gnu")))

    let custom = engine.build(BuildRequest(
      rootPackageId: graph.activePackageId,
      target: "cli", profile: "release_small", mode: bmVm), graph)
    let release = engine.build(BuildRequest(
      rootPackageId: graph.activePackageId,
      target: "cli", profile: "release", mode: bmVm), graph)
    check custom.rootArtifact.derivationId != release.rootArtifact.derivationId
    check custom.rootArtifact.profile.optimization == "size"
    check custom.rootArtifact.profile.debugInfo == "none"
    check custom.rootArtifact.profile.sealing == "sealed"

  test "conflicting observations permanently poison a derivation":
    let root = buildTestRoot()
    writeBuildFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writeBuildFile(root / "src/main.gene", "(fn main [] 0)")
    let manager = newPackageManager(root / "package_store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let graph = manager.sync(resolution,
      SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
    let engine = newBuildEngine(BuildEnvironment(
      artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
      toolchains: newToolchainSet("gene-test-compiler",
                                 "x86_64-test-linux-gnu")))
    let request = BuildRequest(rootPackageId: graph.activePackageId,
      target: "app", profile: "dev", mode: bmVm)
    let first = engine.build(request, graph)
    let derivationRoot = root / ".gene/artifacts/derivations/sha256" /
      first.rootArtifact.derivationId.replace("sha256:", "")
    let activeIndex = readFile(derivationRoot / "index.gene")
    writeBuildFile(derivationRoot / "index.gene",
      "{^state active ^artifact_digest \"not-a-digest\"}\n")
    check raisedBuildCode(proc () =
      discard engine.build(request, graph)) == becNonReproducible
    writeBuildFile(derivationRoot / "index.gene", activeIndex)
    writeBuildFile(derivationRoot / "observations" /
      (repeat('b', 64) & ".gene"), "{}\n")
    var rebuild = request
    rebuild.rebuild = true
    check raisedBuildCode(proc () =
      discard engine.build(rebuild, graph)) == becNonReproducible
    check "^state poisoned" in readFile(derivationRoot / "index.gene")
    check raisedBuildCode(proc () =
      discard engine.build(request, graph)) == becNonReproducible

  test "a source edit invalidates only its reverse dependency closure":
    let root = buildTestRoot()
    writeBuildFile(root / "package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "cli" ^entry "src/main.gene")]
 ^dependencies {^math (dep "acme/math" "1.0.0" ^workspace true)}}
""")
    writeBuildFile(root / "src/main.gene",
      "(import [answer] from \".\" ^pkg \"math\") (fn main [] answer)")
    writeBuildFile(root / "packages/math/package.gene", """
{^format 1 ^name "acme/math" ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writeBuildFile(root / "packages/math/src/index.gene", "(var answer 1)")
    let manager = newPackageManager(root / "package_store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    var graph = manager.sync(resolution,
      SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
    let engine = newBuildEngine(BuildEnvironment(
      artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
      toolchains: newToolchainSet("gene-test-compiler",
                                 "x86_64-test-linux-gnu")))
    let request = BuildRequest(rootPackageId: graph.activePackageId,
      target: "cli", profile: "dev", mode: bmVm)
    discard engine.build(request, graph)

    writeBuildFile(root / "packages/math/src/index.gene", "(var answer 2)")
    let refreshed = manager.resolve(ResolveRequest(startDir: root))
    graph = manager.sync(refreshed,
      SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
    let changed = engine.build(request, graph)
    check changed.rebuilt == 2
    check changed.cacheHits == 0

  test "cache hits ignore snapshot source and rebuilds authenticate it":
    let root = buildTestRoot()
    writeBuildFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writeBuildFile(root / "src/main.gene", "(fn main [] 7)")
    let manager = newPackageManager(root / "package_store")
    let resolution = manager.resolve(ResolveRequest(startDir: root))
    let graph = manager.sync(resolution,
      SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
    let engine = newBuildEngine(BuildEnvironment(
      artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
      toolchains: newToolchainSet("gene-test-compiler",
                                 "x86_64-test-linux-gnu")))
    let request = BuildRequest(rootPackageId: graph.activePackageId,
      target: "app", profile: "dev", mode: bmVm)
    let first = engine.build(request, graph)
    let snapshotEntry = first.executionGraph.packagesById[
      graph.activePackageId].root / "src/main.gene"
    setFilePermissions(snapshotEntry,
      {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    writeBuildFile(snapshotEntry, "(fn main [] 999)")

    let second = engine.build(request, graph)
    check second.rootArtifact.cacheHit
    var rebuild = request
    rebuild.rebuild = true
    check raisedBuildCode(proc () =
      discard engine.build(rebuild, graph)) == becNonReproducible

  test "independent libraries honor the parallelism limit":
    when defined(posix):
      let root = buildTestRoot()
      writeBuildFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^one (dep "acme/one" "1.0.0" ^workspace true)
   ^two (dep "acme/two" "1.0.0" ^workspace true)}}
""")
      writeBuildFile(root / "src/main.gene", "(fn main [] 0)")
      for name in ["one", "two"]:
        writeBuildFile(root / "packages" / name / "package.gene",
          "{^format 1 ^name \"acme/" & name &
          "\" ^version \"1.0.0\" ^library {^entry \"src/index.gene\"}}")
        writeBuildFile(root / "packages" / name / "src/index.gene",
          "(var name \"" & name & "\")")
      let manager = newPackageManager(root / "package_store")
      let resolution = manager.resolve(ResolveRequest(startDir: root))
      let graph = manager.sync(resolution,
        SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
      let engine = newBuildEngine(BuildEnvironment(
        artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
        toolchains: newToolchainSet("gene-test-compiler",
                                   "x86_64-test-linux-gnu")))
      let built = engine.build(BuildRequest(
        rootPackageId: graph.activePackageId, target: "app",
        profile: "dev", mode: bmVm, maxParallelism: 2), graph)
      check built.rebuilt == 3
      check built.cacheHits == 0
      check built.artifacts.len == 3

  test "portable artifacts are shared across checkout roots":
    let root = buildTestRoot()
    let artifactRoot = root / "shared_artifacts"
    var artifacts: seq[BuildArtifact]
    for checkout in [root / "checkout_one", root / "checkout_two"]:
      writeBuildFile(checkout / "package.gene", """
{^format 1 ^name "acme/portable" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
      writeBuildFile(checkout / "src/main.gene", """
(ffi/struct CRecord ^fields [[value C/Int64]])
(fn main [] 0)
""")
      let manager = newPackageManager(checkout / "package_store")
      let resolution = manager.resolve(ResolveRequest(startDir: checkout))
      let graph = manager.sync(resolution,
        SyncPolicy(offline: true,
                   userStoreRoot: checkout / "package_store"))
      let engine = newBuildEngine(BuildEnvironment(
        artifactStore: newLocalArtifactStore(artifactRoot),
        toolchains: newToolchainSet("gene-test-compiler",
                                   "x86_64-test-linux-gnu")))
      artifacts.add engine.build(BuildRequest(
        rootPackageId: graph.activePackageId, target: "app",
        profile: "dev", mode: bmVm), graph).rootArtifact
    check artifacts[0].derivationId == artifacts[1].derivationId
    check artifacts[0].artifactDigest == artifacts[1].artifactDigest
    check not artifacts[0].cacheHit
    check artifacts[1].cacheHit

  test "crashed locks recover and concurrent project views converge":
    when defined(posix):
      let root = buildTestRoot()
      let crashLockPath = root / "crashed.lock"
      let child = posix.fork()
      if child == 0:
        try:
          discard acquireProcessFileLock(crashLockPath)
          posix.exitnow(0)
        except CatchableError:
          posix.exitnow(1)
      var childStatus: cint
      discard posix.waitpid(child, childStatus, 0)
      check childStatus == 0
      check fileExists(crashLockPath)
      let recovered = acquireProcessFileLock(crashLockPath, timeoutMs = 1000)
      recovered.release()
      check not fileExists(crashLockPath)

      writeBuildFile(root / "package.gene", """
{^format 1 ^name "acme/concurrent"
 ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
      writeBuildFile(root / "src/main.gene", "(fn main [] 0)")
      let manager = newPackageManager(root / "package_store")
      let resolution = manager.resolve(ResolveRequest(startDir: root))
      let graph = manager.sync(resolution,
        SyncPolicy(offline: true, userStoreRoot: root / "package_store"))
      let engine = newBuildEngine(BuildEnvironment(
        artifactStore: newLocalArtifactStore(root / ".gene/artifacts"),
        toolchains: newToolchainSet("gene-test-compiler",
                                   "x86_64-test-linux-gnu")))
      let request = BuildRequest(rootPackageId: graph.activePackageId,
        target: "app", profile: "dev", mode: bmVm)
      let initial = engine.build(request, graph)
      removeDir(initial.projectView)

      let publisher = posix.fork()
      if publisher == 0:
        try:
          discard engine.build(request, graph)
          posix.exitnow(0)
        except CatchableError:
          posix.exitnow(1)
      let concurrent = engine.build(request, graph)
      var publisherStatus: cint
      discard posix.waitpid(publisher, publisherStatus, 0)
      check publisherStatus == 0
      check readFile(concurrent.projectView / "artifact.digest").strip() ==
        concurrent.rootArtifact.artifactDigest
      check symlinkExists(concurrent.projectView / "artifact.gir")
      check symlinkExists(concurrent.projectView / "metadata.gene")
      check "acme/concurrent" in
        readFile(concurrent.projectView / "metadata.gene")
