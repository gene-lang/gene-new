## Nim-facing native extension foundation.
##
## This module intentionally exposes stable concepts rather than VM internals:
## roots keep Gene values alive across native-owned lifetimes, and `geneCall`
## is the trampoline native code can use to call any Gene callable through the
## normal dynamic boundary.

import std/dynlib

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
  GeneNewBufferProc* = proc(elemType: Value, items: seq[Value],
                            scope: Scope): GeneResult
  GeneBufferLenProc* = proc(buffer: Value): GeneResult
  GeneBufferGetProc* = proc(buffer: Value, index: int): GeneResult
  GeneBufferSetProc* = proc(buffer: Value, index: int, item: Value,
                            scope: Scope): GeneResult
  GeneChannelTrySendProc* = proc(channel: Value, item: GeneRoot,
                                 scope: Scope): GeneResult
  GeneChannelTryRecvProc* = proc(channel: Value, scope: Scope): GeneResult
  GeneActorTrySendProc* = proc(actor: Value, message: GeneRoot,
                               scope: Scope): GeneResult
  GeneNewAsyncTaskProc* = proc(): Value
  GeneTaskCompleteProc* = proc(task: Value, value: GeneRoot,
                               scope: Scope): GeneResult
  GeneTaskFailProc* = proc(task: Value, message: string, value: GeneRoot,
                           hasValue: bool, scope: Scope): GeneResult
  GeneTaskCancelProc* = proc(task: Value, scope: Scope): GeneResult
  GeneNewCallbackProc* = proc(callee: Value): GeneCallbackHandle
  GeneCallCallbackProc* = proc(callback: GeneCallbackHandle,
                               call: GeneCall): GeneResult
  GeneReleaseCallbackProc* = proc(callback: GeneCallbackHandle)
  GeneNewFfiLoadProc* = proc(): Value
  GeneAttachThreadProc* = proc(): GeneThreadAttachment
  GeneDetachThreadProc* = proc(attachment: GeneThreadAttachment)
  GeneThreadAttachedProc* = proc(): bool
  GeneModuleInitProc* = proc(api: ptr GeneApi,
                             module: GeneModule): GeneResult {.nimcall.}

  GeneStatus* = enum
    gsOk
    gsError
    gsPanic

  GeneRoot* = ref object
    value: Value
    released: bool

  GeneCallbackHandle* = ref object
    callee: GeneRoot
    released: bool

  GeneThreadAttachment* = ref object
    ownerThreadId: int
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
    newBuffer*: GeneNewBufferProc
    bufferLen*: GeneBufferLenProc
    bufferGet*: GeneBufferGetProc
    bufferSet*: GeneBufferSetProc
    channelTrySend*: GeneChannelTrySendProc
    channelTryRecv*: GeneChannelTryRecvProc
    actorTrySend*: GeneActorTrySendProc
    newAsyncTask*: GeneNewAsyncTaskProc
    taskComplete*: GeneTaskCompleteProc
    taskFail*: GeneTaskFailProc
    taskCancel*: GeneTaskCancelProc
    newCallback*: GeneNewCallbackProc
    callCallback*: GeneCallCallbackProc
    releaseCallback*: GeneReleaseCallbackProc
    newFfiLoad*: GeneNewFfiLoadProc
    attachThread*: GeneAttachThreadProc
    detachThread*: GeneDetachThreadProc
    threadAttached*: GeneThreadAttachedProc

const GeneApiVersion* = 1
const GeneApiFeatureCount* = 30
const GeneModuleInitSymbol* = "gene_module_init"

var geneThreadAttachDepth {.threadvar.}: int

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

proc geneNewBuffer*(elemType: Value, items: seq[Value],
                    scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value = newCheckedBuffer(elemType, items, scope)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneBufferLen*(buffer: Value): GeneResult =
  try:
    if buffer.kind != vkBuffer:
      raise newException(GeneError, "Buffer/len expects a Buffer")
    result.status = gsOk
    result.value = newInt(buffer.bufferLen)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneBufferGet*(buffer: Value, index: int): GeneResult =
  try:
    result.status = gsOk
    result.value = getCheckedBufferItem(buffer, index)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneBufferSet*(buffer: Value, index: int, item: Value,
                    scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value = setCheckedBufferItem(buffer, index, item, scope)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneChannelTrySend*(channel: Value, item: GeneRoot,
                         scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeChannelTrySend(channel, geneRootGet(item), scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneChannelTryRecv*(channel: Value, scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value = vm.nativeChannelTryRecv(channel, scope)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneActorTrySend*(actor: Value, message: GeneRoot,
                       scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeActorTrySend(actor, geneRootGet(message), scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewAsyncTask*(): Value =
  vm.nativeNewAsyncTask()

proc geneTaskComplete*(task: Value, value: GeneRoot,
                       scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeTaskComplete(task, geneRootGet(value), scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneTaskFail*(task: Value, message: string, value: GeneRoot,
                   hasValue: bool, scope: Scope): GeneResult =
  try:
    result.status = gsOk
    let errValue =
      if hasValue: geneRootGet(value)
      else: NIL
    result.value =
      if vm.nativeTaskFail(task, message, errValue, hasValue, scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneTaskCancel*(task: Value, scope: Scope): GeneResult =
  try:
    result.status = gsOk
    result.value =
      if vm.nativeTaskCancel(task, scope): TRUE
      else: FALSE
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneNewCallback*(callee: Value): GeneCallbackHandle =
  GeneCallbackHandle(callee: geneRoot(callee))

proc geneCallCallback*(callback: GeneCallbackHandle,
                       call: GeneCall): GeneResult =
  try:
    if callback == nil or callback.released:
      result.status = gsError
      result.message = "native callback has been released"
      return
    if geneThreadAttachDepth <= 0:
      result.status = gsError
      result.message = "native thread is not attached"
      return
    result = geneCall(geneRootGet(callback.callee), call)
  except GeneError as e:
    result = errorResult(e)
  except GenePanic as e:
    result = panicResult(e)

proc geneReleaseCallback*(callback: GeneCallbackHandle) =
  if callback == nil or callback.released:
    return
  geneRootRelease(callback.callee)
  callback.released = true

proc geneNewFfiLoad*(): Value =
  newFfiLoadCapability()

proc geneAttachThread*(): GeneThreadAttachment =
  inc geneThreadAttachDepth
  GeneThreadAttachment(ownerThreadId: getThreadId())

proc geneDetachThread*(attachment: GeneThreadAttachment) =
  if attachment == nil or attachment.released:
    return
  if attachment.ownerThreadId != getThreadId() or geneThreadAttachDepth <= 0:
    return
  dec geneThreadAttachDepth
  attachment.released = true

proc geneThreadAttached*(): bool =
  geneThreadAttachDepth > 0

proc geneInitModule*(init: GeneModuleInitProc, module: GeneModule,
                     api: GeneApi = geneApi()): GeneResult =
  if init == nil:
    result.status = gsError
    result.message = "native module initializer is nil"
    return
  if api.version != GeneApiVersion:
    result.status = gsError
    result.message = "native API version mismatch: runtime " &
      $GeneApiVersion & ", requested " & $api.version
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

proc geneLoadModule*(library: Value, name: string,
                     scope: Scope = nil,
                     initSymbol = GeneModuleInitSymbol,
                     api: GeneApi = geneApi()): GeneResult =
  try:
    if library.kind != vkFfiLibrary:
      raise newException(GeneError, "native module load expects an Ffi/Library")
    if library.ffiLibraryClosed:
      raise newException(GeneError, "native module load library is closed")
    if name.len == 0:
      raise newException(GeneError, "native module name must not be empty")
    if initSymbol.len == 0:
      raise newException(GeneError, "native module initializer symbol must not be empty")
    let symbol = symAddr(cast[LibHandle](library.ffiLibraryHandle), initSymbol)
    if symbol == nil:
      raise newException(GeneError,
        "native module initializer not found: " & initSymbol)
    let module = newGeneModule(name, library.ffiLibraryPath, scope)
    result = geneInitModule(cast[GeneModuleInitProc](symbol), module, api)
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
          newCSlice: geneNewCSlice,
          newBuffer: geneNewBuffer,
          bufferLen: geneBufferLen,
          bufferGet: geneBufferGet,
          bufferSet: geneBufferSet,
          channelTrySend: geneChannelTrySend,
          channelTryRecv: geneChannelTryRecv,
          actorTrySend: geneActorTrySend,
          newAsyncTask: geneNewAsyncTask,
          taskComplete: geneTaskComplete,
          taskFail: geneTaskFail,
          taskCancel: geneTaskCancel,
          newCallback: geneNewCallback,
          callCallback: geneCallCallback,
          releaseCallback: geneReleaseCallback,
          newFfiLoad: geneNewFfiLoad,
          attachThread: geneAttachThread,
          detachThread: geneDetachThread,
          threadAttached: geneThreadAttached)
