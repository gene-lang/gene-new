## Internal admission for the AtomicArc retirement experiment. This fences
## participating entry calls, never raw Values/Scopes after an entry returns.
## Production builds deliberately have no gate or admission-policy change.

when defined(geneAtomicGenerationRetirementProbe):
  import std/locks

  var gateLock: Lock
  var gateChanged: Cond
  var activeEntries, waitingEntries, collectorDepth, collectorThread: int
  var ownerDependentEntries: int
  var sealed: bool
  var entryDepth {.threadvar.}: int
  var entryOwnerDependent {.threadvar.}: bool
  initLock(gateLock)
  initCond(gateChanged)

  proc enterRetirementNativeAccess*(mayNeedOwnerProgress = false): bool =
    # Nested entries must be able to finish an already admitted operation while
    # the collector drains it. Count only the outermost entry globally.
    if entryDepth > 0:
      if mayNeedOwnerProgress and not entryOwnerDependent:
        withLock gateLock:
          inc ownerDependentEntries
          entryOwnerDependent = true
          broadcast(gateChanged)
      inc entryDepth
      return true
    withLock gateLock:
      if sealed and collectorThread == getThreadId():
        return false # the owning thread cannot reenter analysis
      else:
        if sealed:
          inc waitingEntries
          try:
            while sealed: wait(gateChanged, gateLock)
          finally:
            dec waitingEntries
      inc activeEntries
      if mayNeedOwnerProgress: inc ownerDependentEntries
      entryOwnerDependent = mayNeedOwnerProgress
      entryDepth = 1
    true

  proc leaveRetirementNativeAccess*() =
    doAssert entryDepth > 0
    dec entryDepth
    if entryDepth == 0:
      withLock gateLock:
        doAssert activeEntries > 0
        dec activeEntries
        if entryOwnerDependent:
          dec ownerDependentEntries
          entryOwnerDependent = false
        broadcast(gateChanged)

  proc trySealRetirementNativeAccess*(): bool =
    # A callback collecting from within an entry cannot wait for its own lease.
    if entryDepth > 0: return false
    withLock gateLock:
      if collectorDepth > 0:
        if collectorThread != getThreadId() or not sealed: return false
        inc collectorDepth
        return true
      if ownerDependentEntries > 0: return false
      sealed = true
      collectorThread = getThreadId()
      collectorDepth = 1
      while activeEntries > 0 and ownerDependentEntries == 0:
        wait(gateChanged, gateLock)
      if ownerDependentEntries > 0:
        # A nested operation upgraded an admitted entry while we were draining.
        # Reopen admission and defer: its cleanup may require the root lane.
        sealed = false
        collectorThread = 0
        collectorDepth = 0
        broadcast(gateChanged)
        return false
    true

  proc finishRetirementNativeAnalysis*() =
    withLock gateLock:
      doAssert sealed and collectorThread == getThreadId()
      doAssert activeEntries == 0 and collectorDepth == 1
      # All candidate Scope edges are already detached. Do not keep callbacks
      # waiting behind admission while last-owner cleanup may join them. Keep
      # the collector reservation until cleanup ends, preventing another pass.
      sealed = false
      broadcast(gateChanged)

  proc retirementNativeAnalysisAdmitted*(): bool =
    withLock gateLock:
      result = sealed and collectorThread == getThreadId() and
        activeEntries == 0 and collectorDepth == 1

  proc unsealRetirementNativeAccess*() =
    withLock gateLock:
      doAssert collectorThread == getThreadId() and collectorDepth > 0
      dec collectorDepth
      if collectorDepth == 0:
        if sealed: doAssert activeEntries == 0
        sealed = false
        collectorThread = 0
        broadcast(gateChanged)

  proc retirementNativeGateSnapshot*(): tuple[sealed: bool, active, waiting, depth: int] =
    ## Test diagnostic, not a per-class ownership snapshot or public SDK API.
    withLock gateLock:
      result = (sealed, activeEntries, waitingEntries, collectorDepth)
