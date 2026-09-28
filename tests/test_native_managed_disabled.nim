## Normal AtomicArc SDK compatibility control; collection stays disabled.
when not defined(gcAtomicArc) or defined(gcOrc) or
    defined(geneAtomicGenerationRetirementProbe):
  {.error: "this control requires normal genuine AtomicArc".}

import gene/[native_managed, types, vm]
import std/os

initModuleContext(getCurrentDir())
let scope = newGlobalScope()
let domain = geneNewManagedDomain(scope)
let root = geneManagedRootFromVm(domain, scope, newInt(42))
doAssert geneWithNativeBorrow(root,
  proc(borrow: GeneNativeBorrow): int64 = geneManagedInt64(borrow)) == 42
geneManagedRelease(root)
doAssert geneManagedClose(domain)
echo "managed SDK normal AtomicArc control: pass"
