## Nim-facing native extension foundation.
##
## This module intentionally exposes stable concepts rather than VM internals:
## roots keep Gene values alive across native-owned lifetimes, and `geneCall`
## is the trampoline native code can use to call any Gene callable through the
## normal dynamic boundary.

import ./[types, vm]

type
  GeneRootProc* = proc(value: Value): GeneRoot
  GeneRootGetProc* = proc(root: GeneRoot): Value
  GeneRootReleaseProc* = proc(root: GeneRoot)
  GeneCallProc* = proc(callee: Value, call: GeneCall): GeneResult

  GeneStatus* = enum
    gsOk
    gsError
    gsPanic

  GeneRoot* = ref object
    value: Value
    released: bool

  GeneCall* = object
    args*: seq[Value]
    namedNames*: seq[string]
    namedValues*: seq[Value]
    dispatchScope*: Scope
    site*: Value

  GeneResult* = object
    status*: GeneStatus
    value*: Value
    message*: string
    errorValue*: Value
    hasErrorValue*: bool

  GeneApi* = object
    version*: int
    root*: GeneRootProc
    rootGet*: GeneRootGetProc
    rootRelease*: GeneRootReleaseProc
    call*: GeneCallProc

const GeneApiVersion* = 1

proc geneRoot*(value: Value): GeneRoot =
  GeneRoot(value: value)

proc geneRootGet*(root: GeneRoot): Value =
  if root == nil or root.released:
    raise newException(GeneError, "native root has been released")
  root.value

proc geneRootRelease*(root: GeneRoot) =
  if root == nil or root.released:
    return
  root.value = NIL
  root.released = true

proc geneCall*(callee: Value, call: GeneCall): GeneResult =
  try:
    result.status = gsOk
    result.value = vm.call(callee, call.args, call.namedNames, call.namedValues,
                           call.dispatchScope, call.site)
  except GeneError as e:
    result.status = gsError
    result.message = e.msg
    result.hasErrorValue = e.hasErrVal
    if e.hasErrVal:
      result.errorValue = e.errVal
  except GenePanic as e:
    result.status = gsPanic
    result.message = e.msg
    result.hasErrorValue = e.hasErrVal
    if e.hasErrVal:
      result.errorValue = e.errVal

proc geneApi*(): GeneApi =
  GeneApi(version: GeneApiVersion, root: geneRoot, rootGet: geneRootGet,
          rootRelease: geneRootRelease, call: geneCall)
