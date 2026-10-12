import std/unittest
import gene/[compiler, types, vm]

proc value(source: string): Value =
  run(compileSource(source), newGlobalScope())

suite "frozen graph proof eligibility":
  test "deep scalar List and PropMap compose all three negative proofs":
    let data = value("($freeze [{^x [1 2 \"three\"]} true nil])")
    check data.frozenGraphProofs == (FrozenNoCallerEnv or FrozenNoScopeCapture or FrozenNoWeakScope)
  test "shallow freeze and thaw never inherit a certificate":
    check value("($freeze_shallow [1 2])").frozenGraphProofs == 0
    check value("($thaw ($freeze [1 2]))").frozenGraphProofs == 0
  test "frozen types and typed errors retain full checks":
    check value("(type T) ($freeze [T])").frozenGraphProofs == 0
    check value("($freeze [(RuntimeError ^message \"x\")])").frozenGraphProofs == 0
  test "nodes and their hidden runtime evidence are not certified":
    let node = value("($freeze (quote (data ^x [1 2])))")
    check node.frozenGraphProofs == 0
    check value("($freeze [(quote (data ^x [1 2]))])").frozenGraphProofs == 0
  test "a deep flag on a mutable constructor cannot authorize skipping":
    check newList(@[newInt(1)], deepFrozen = true).frozenGraphProofs == 0
    var props = initPropTable()
    props["x"] = newInt(1)
    check newMap(props, deepFrozen = true).frozenGraphProofs == 0
  test "native callers cannot certify a type by setting a deep flag":
    let typ = value("(type T) T")
    check newList(@[typ], immutable = true, deepFrozen = true).frozenGraphProofs == 0
