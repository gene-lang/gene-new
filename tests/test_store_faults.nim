import gene/[types, compiler, vm, printer]
import std/[os, unittest]

# Built with -d:geneStoreFaultTests, which lets a test make one directory's sync
# fail (vm.nim `fsSyncFailPath`).

proc eval(source: string): string =
  run(compileSource(source), newGlobalScope()).print()

proc freshRoot(name: string): string =
  result = getTempDir() / name
  if dirExists(result): removeDir(result)

suite "filesystem checkpoint sync failures":
  test "a sync that fails after CURRENT is renamed does not fail the checkpoint":
    # Readers can already see the new generation, and Harness advances its own
    # generation only when the checkpoint returns. Raising here made it retry a
    # generation that existed.
    let root = freshRoot("gene_store_fault_after_publish")
    fsSyncFailPath = root       # the store root is synced after the rename
    defer: fsSyncFailPath = ""
    check eval("(import $store/fs/[Store open:store_open]) " &
      "(var store (store_open ^root \"" & root & "\")) " &
      "[(store .Store:checkpoint 1 {^a 1}) (store .Store:checkpoint 2 {^a 2})]") ==
      "[1 2]"
    fsSyncFailPath = ""
    check eval("(import $store/fs/[Store open:store_open]) " &
      "(var store (store_open ^root \"" & root & "\")) " &
      "(let loaded (store .Store:load_checkpoint)) loaded/generation") == "2"

  test "a sync that fails before CURRENT is renamed fails the checkpoint, and a retry succeeds":
    let root = freshRoot("gene_store_fault_before_publish")
    fsSyncFailPath = root / "generations"
    defer: fsSyncFailPath = ""
    check eval("(import $store/fs/[Store StoreError open:store_open]) " &
      "(var store (store_open ^root \"" & root & "\")) " &
      "(try (store .Store:checkpoint 1 {^a 1}) catch StoreError \"failed\")") ==
      "\"failed\""
    fsSyncFailPath = ""
    check eval("(import $store/fs/[Store open:store_open]) " &
      "(var store (store_open ^root \"" & root & "\")) " &
      "(store .Store:checkpoint 1 {^a 1})") == "1"
