import std/[os, strutils, unittest]
import gene/[build, digest, package, printer, types, vm]

proc provenanceFixture(base, name: string): string =
  result = base / name
  createDir(result / "app/src")
  createDir(result / "lib/src")
  writeFile(result / "app/package.gene", """
{^format 1 ^name "probe/app" ^version "1.0.0"
 ^files {^include ["package.gene" "src/**"]}
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^lib (dep "probe/lib" "1.0.0" ^path "../lib")}}
""")
  writeFile(result / "lib/package.gene", """
{^format 1 ^name "probe/lib" ^version "1.0.0"
 ^files {^include ["package.gene" "src/**"]}
 ^library {^entry "src/main.gene"}}
""")
  writeFile(result / "lib/src/main.gene", "(var answer 7)")
  writeFile(result / "app/src/main.gene", """
(import [answer] ^from "." ^pkg "lib")
(var observed answer)
(var info ($pkg/application))
(var digests [($pkg/canonical_digest {^x 1 ^y 2})
              ($pkg/canonical_digest {^y 2 ^x 1})])
(var immutable (try (info .put "root" "changed") false catch Any true))
""")

proc provenanceGraph(root: string): MaterializedGraph =
  let manager = newPackageManager(root / ".packages")
  let resolution = manager.resolve(ResolveRequest(startDir: root / "app"))
  manager.sync(resolution, SyncPolicy(offline: true,
                                     userStoreRoot: root / ".packages"))

suite "execution provenance":
  let base = expandFilename(getTempDir()) / "gene_execution_provenance"
  if dirExists(base):
    makeMaterializedTreeWritable(base)
    removeDir(base)
  createDir(base)
  let engine = newBuildEngine(BuildEnvironment(
    artifactStore: newLocalArtifactStore(base / "artifacts"),
    toolchains: newToolchainSet("provenance-test", "test-host")))

  test "source snapshots execute the captured root and dependency bytes":
    let root = provenanceFixture(base, "frozen")
    let captured = engine.snapshotSources(provenanceGraph(root))
    let identity = executionProvenance(captured, "src/main.gene",
                                       runtimeDigest = "sha256:test-runtime")
    writeFile(root / "lib/src/main.gene", "(var answer 99)")
    writeFile(root / "app/src/main.gene", "(var observed 100)")
    let app = newApplication(captured)
    app.setExecutionProvenance(identity, root / "app")
    let entry = app.loadFileModule(app.packageRoot() / "src/main.gene")
    let scope = entry.moduleRootNamespace.nsScope
    check scope.lookup("observed").print() == "7"
    let info = scope.lookup("info")
    check info.mapEntries["source_root"].strVal == root / "app"
    check canonicalDigest(info.mapEntries["provenance"]) == canonicalDigest(identity)
    check scope.lookup("immutable").print() == "true"
    let digests = scope.lookup("digests").listItems
    check digests[0].strVal == digests[1].strVal
    expect GeneError:
      app.setExecutionProvenance(identity, root / "app")

  test "identity ignores checkout location and changes with captured inputs":
    let a = provenanceFixture(base, "location_a")
    let b = provenanceFixture(base, "location_b")
    let first = engine.snapshotSources(provenanceGraph(a))
    let second = engine.snapshotSources(provenanceGraph(b))
    let original = canonicalDigest(executionProvenance(first, "src/main.gene",
                                     runtimeDigest = "sha256:runtime-a"))
    check original == canonicalDigest(executionProvenance(second, "src/main.gene",
                                        runtimeDigest = "sha256:runtime-a"))
    check original != canonicalDigest(executionProvenance(first, "src/main.gene",
                                        runtimeDigest = "sha256:runtime-b"))
    writeFile(b / "lib/src/main.gene", "(var answer 8)")
    let changed = engine.snapshotSources(provenanceGraph(b))
    check original != canonicalDigest(executionProvenance(changed, "src/main.gene",
                                        runtimeDigest = "sha256:runtime-a"))
    check not executionProvenance(first, "src/main.gene").print().contains(base)

  test "mutable source execution does not claim captured provenance":
    let root = provenanceFixture(base, "mutable")
    let app = newApplication(provenanceGraph(root))
    let entry = app.loadFileModule(app.packageRoot() / "src/main.gene")
    check entry.moduleRootNamespace.nsScope.lookup("info").mapEntries["provenance"].kind == vkNil

  test "package resources cannot bypass filesystem or native-code grants":
    let root = provenanceFixture(base, "authority")
    let hadStore = existsEnv("GENE_USER_PACKAGES")
    let oldStore = getEnv("GENE_USER_PACKAGES")
    putEnv("GENE_USER_PACKAGES", base / "authority_store")
    defer:
      if hadStore: putEnv("GENE_USER_PACKAGES", oldStore)
      else: delEnv("GENE_USER_PACKAGES")
    createDir(root / "app/src/mods")
    writeFile(root / "app/src/data.txt", "resource")
    writeFile(root / "app/src/mods/reader.gene", """
(fn read [package] ($pkg/read_text package "src/data.txt"))
(fn materialize [package] ($pkg/materialize package "src/data.txt"))
(fn open_module [package] ($pkg/native_module package "not-selected"))
""")
    writeFile(root / "app/src/main.gene", """
(var restricted ($runtime/load_sandboxed ($path/join this_pkg/root "src/mods")
  "reader.gene" [] [] "restricted"))
(var data (restricted/read this_pkg))
(var fs_denied (try (restricted/materialize this_pkg) "unexpected" catch Any $err/message))
(var ffi_denied (try (restricted/open_module this_pkg) "unexpected" catch Any $err/message))
(var allowed ($runtime/load_sandboxed ($path/join this_pkg/root "src/mods")
  "reader.gene" ["fs"] [] "filesystem"))
(var lease (allowed/materialize this_pkg))
(var materialized ($fs/read_text lease/.path))
lease/.close
""")
    let captured = engine.snapshotSources(provenanceGraph(root))
    let app = newApplication(captured)
    let resource = app.packageRoot() / "src/data.txt"
    app.installPackageResource(captured.activePackageId, "src/data.txt",
      "sha256:" & sha256File(resource), 8)
    let entry = app.loadFileModule(app.packageRoot() / "src/main.gene")
    let scope = entry.moduleRootNamespace.nsScope
    check scope.lookup("data").strVal == "resource"
    check scope.lookup("fs_denied").strVal.contains("requires fs authority")
    check scope.lookup("ffi_denied").strVal.contains("requires ffi authority")
    check scope.lookup("materialized").strVal == "resource"
