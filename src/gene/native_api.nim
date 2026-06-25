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
  GeneModuleDefineProc* = proc(module: GeneModule, name: string,
                               value: Value): GeneResult
  GeneModuleDefineNativeProc* = proc(module: GeneModule, name: string,
                                     impl: NativeProc): GeneResult
  GeneModuleDefineNativeCallProc* = proc(module: GeneModule, name: string,
                                         impl: NativeCallProc,
                                         acceptsNamed: bool): GeneResult
  GeneNewCPtrProc* = proc(address: pointer, targetType: Value): Value
  GeneNewCConstPtrProc* = proc(address: pointer, targetType: Value): Value
  GeneNewCOwnedPtrProc* = proc(address: pointer, release: CPtrReleaseProc,
                               targetType: Value): Value
  GeneCloseCPtrProc* = proc(value: Value): GeneResult
  GeneNewCSliceProc* = proc(address: pointer, length: int,
                            targetType: Value): Value
  GeneModuleInitProc* = proc(api: ptr GeneApi, module: GeneModule): GeneResult

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

  GeneModule* = ref object
    value: Value
    scope: Scope

  GeneApi* = object
    version*: int
    featureCount*: int
    root*: GeneRootProc
    rootGet*: GeneRootGetProc
    rootRelease*: GeneRootReleaseProc
    call*: GeneCallProc
    moduleDefine*: GeneModuleDefineProc
    moduleDefineNative*: GeneModuleDefineNativeProc
    moduleDefineNativeCall*: GeneModuleDefineNativeCallProc
    newCPtr*: GeneNewCPtrProc
    newCConstPtr*: GeneNewCConstPtrProc
    newCOwnedPtr*: GeneNewCOwnedPtrProc
    closeCPtr*: GeneCloseCPtrProc
    newCSlice*: GeneNewCSliceProc

const GeneApiVersion* = 1
const GeneApiFeatureCount* = 12

proc geneApi*(): GeneApi

proc errorResult(e: ref GeneError): GeneResult =
  result.status = gsError
  result.message = e.msg
  result.hasErrorValue = e.hasErrVal
  if e.hasErrVal:
    result.errorValue = e.errVal

proc panicResult(e: ref GenePanic): GeneResult =
  result.status = gsPanic
  result.message = e.msg
  result.hasErrorValue = e.hasErrVal
  if e.hasErrVal:
    result.errorValue = e.errVal

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
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc newGeneModule*(name: string, path = "",
                    scope: Scope = nil): GeneModule =
  let moduleScope =
    if scope == nil: newGlobalScope()
    else: scope
  let moduleValue = bindThisModule(moduleScope, name, path)
  GeneModule(value: moduleValue, scope: moduleScope)

proc geneModuleValue*(module: GeneModule): Value =
  if module == nil:
    raise newException(GeneError, "native module is nil")
  module.value

proc geneModuleScope*(module: GeneModule): Scope =
  if module == nil:
    raise newException(GeneError, "native module is nil")
  module.scope

proc geneModuleDefine*(module: GeneModule, name: string,
                       value: Value): GeneResult =
  try:
    module.geneModuleScope.define(name, value)
    result.status = gsOk
    result.value = value
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneModuleDefineNative*(module: GeneModule, name: string,
                             impl: NativeProc): GeneResult =
  geneModuleDefine(module, name, newNativeFn(name, impl))

proc geneModuleDefineNativeCall*(module: GeneModule, name: string,
                                 impl: NativeCallProc,
                                 acceptsNamed: bool): GeneResult =
  geneModuleDefine(module, name,
                   newNativeCallFn(name, impl, acceptsNamed = acceptsNamed))

proc geneNewCPtr*(address: pointer, targetType: Value): Value =
  newCPtr(address, targetType)

proc geneNewCConstPtr*(address: pointer, targetType: Value): Value =
  newCConstPtr(address, targetType)

proc geneNewCOwnedPtr*(address: pointer, release: CPtrReleaseProc,
                       targetType: Value): Value =
  newCOwnedPtr(address, release, targetType)

proc geneCloseCPtr*(value: Value): GeneResult =
  try:
    value.closeCPtr()
    result.status = gsOk
    result.value = NIL
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewCSlice*(address: pointer, length: int, targetType: Value): Value =
  newCSlice(address, length, targetType)

proc geneInitModule*(init: GeneModuleInitProc, module: GeneModule,
                     api: GeneApi = geneApi()): GeneResult =
  if init == nil:
    result.status = gsError
    result.message = "native module initializer is nil"
    return
  var runtimeApi = api
  try:
    result = init(addr runtimeApi, module)
    if result.status == gsOk:
      result.value = module.geneModuleValue
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneApi*(): GeneApi =
  GeneApi(version: GeneApiVersion, featureCount: GeneApiFeatureCount,
          root: geneRoot, rootGet: geneRootGet,
          rootRelease: geneRootRelease, call: geneCall,
          moduleDefine: geneModuleDefine,
          moduleDefineNative: geneModuleDefineNative,
          moduleDefineNativeCall: geneModuleDefineNativeCall,
          newCPtr: geneNewCPtr,
          newCConstPtr: geneNewCConstPtr,
          newCOwnedPtr: geneNewCOwnedPtr,
          closeCPtr: geneCloseCPtr,
          newCSlice: geneNewCSlice)
