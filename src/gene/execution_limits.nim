## Cold execution-limit sampling and exceptional cleanup policy. The VM keeps
## its inline instruction-charge path; none of this adds work to plain dispatch.
import std/[monotimes, times]
import ./types

var activeBudgetCleanup* {.threadvar.}: ptr EvalCleanup
var activeBudgetExecution* {.threadvar.}: uint64
var activeVmBudget* {.threadvar.}: ptr EvalBudget
var externalBudgetOwners {.threadvar.}: seq[EvalBudget]

proc pushBudgetOwner*(budget: EvalBudget) = externalBudgetOwners.add budget
proc popBudgetOwner*() = externalBudgetOwners.setLen(externalBudgetOwners.len - 1)
proc budgetOwnedExternally*(budget: EvalBudget): bool =
  for owner in externalBudgetOwners:
    if owner == budget: return true

proc currentBudgetCleanup*(): EvalCleanup {.inline.} =
  if activeBudgetCleanup != nil: activeBudgetCleanup[] else: nil

proc budgetContains*(budget, owner: EvalBudget): bool =
  var current {.cursor.} = budget
  while current != nil:
    if current == owner: return true
    current = current.parent

proc newExecutionBudget*(maxSteps, maxMemoryMb, timeoutMs: int64,
                         parent: EvalBudget = nil): EvalBudget =
  if maxSteps < 0 and maxMemoryMb < 0 and timeoutMs < 0: return parent
  result = EvalBudget(remaining: if maxSteps < 0: high(int64) else: maxSteps,
                      parent: parent, ownerExecution: activeBudgetExecution)
  if timeoutMs >= 0:
    result.hasDeadline = true
    result.hasTimeoutDuration = true
    result.timeoutMs = timeoutMs
    result.deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  if maxMemoryMb >= 0:
    if maxMemoryMb > high(int64) div (1024 * 1024):
      raise newException(GeneError, "execution memory limit is too large")
    result.hasMemoryLimit = true
    result.memoryBaseline = getOccupiedMem().int64
    result.memoryLimitBytes = maxMemoryMb * 1024 * 1024

proc budgetExpiry*(budget: EvalBudget, skipCleanup = false): ref GeneBudgetExpiry =
  result = newException(GeneBudgetExpiry, budget.expiryError.msg)
  result.budget = budget
  result.skipCleanup = skipCleanup or budget.closed or
    (budget.cleanup != nil and budget.cleanup.truncated.len > 0)

proc truncateCleanup(root: EvalBudget, cleanup: EvalCleanup, reason: string) =
  cleanup.truncated = reason
  var current {.cursor.} = root
  while current != nil:
    if current.cleanup == cleanup: current.sampleCountdown = 0
    current = current.parent

proc activateBudgetChain*(budget: EvalBudget) =
  ## At VM entry/resumption, another fiber may already have observed expiry.
  ## It must not lend its cleanup permission to this execution's normal body.
  var current {.cursor.} = budget
  while current != nil:
    if current.ownerExecution == 0: current.ownerExecution = activeBudgetExecution
    if current.cleanup != nil and current.cleanup != currentBudgetCleanup():
      current.sampleCountdown = 0
    current = current.parent

proc markBudgetExpiry*(budget, root: EvalBudget, memory: bool,
                       prefix = "eval"): ref GeneBudgetExpiry =
  let now = getMonoTime()
  var shared = currentBudgetCleanup()
  if shared == nil:
    var current {.cursor.} = root
    while current != nil:
      if current.cleanup != nil:
        shared = current.cleanup
        break
      current = current.parent
  let allowance = if budget.hasTimeoutDuration: min(1000'i64, budget.timeoutMs)
                  else: 1000'i64
  let until = now + initDuration(milliseconds = allowance)
  if shared == nil: shared = EvalCleanup(deadline: until)
  elif until < shared.deadline: shared.deadline = until
  if budget.expiryError == nil:
    budget.expiryError = newException(GeneError,
      prefix & (if memory: " memory limit exceeded" else: " timeout exceeded"))
  budget.cleanup = shared
  budget.hasDeadline = true
  budget.deadline = shared.deadline
  if memory and not budget.memoryExpired:
    budget.memoryExpired = true
    budget.memoryLimitBytes =
      if budget.memoryLimitBytes > high(int64) div 2: high(int64)
      else: budget.memoryLimitBytes * 2
  # Keep snapshots and older expired ancestors on the same shortened deadline.
  var current {.cursor.} = root
  while current != nil:
    if current.cleanup == shared: current.deadline = shared.deadline
    current = current.parent
  if budget.memoryExpired and
      getOccupiedMem().int64 - budget.memoryBaseline > budget.memoryLimitBytes:
    truncateCleanup(root, shared, "memory")
  result = budget.budgetExpiry()

proc checkExecutionBudgetSample*(budget, root: EvalBudget, prefix = "eval") =
  if budget.cleanup != nil:
    if budget.closed or budget.cleanup.truncated.len > 0:
      raise budget.budgetExpiry(skipCleanup = true)
    if getMonoTime() >= budget.cleanup.deadline:
      truncateCleanup(root, budget.cleanup, "timeout")
      raise budget.budgetExpiry(skipCleanup = true)
    if budget.cleanup != currentBudgetCleanup():
      raise budget.budgetExpiry()
  elif budget.hasDeadline and getMonoTime() >= budget.deadline:
    raise markBudgetExpiry(budget, root, false, prefix)
  if budget.hasMemoryLimit and
      getOccupiedMem().int64 - budget.memoryBaseline > budget.memoryLimitBytes:
    if budget.memoryExpired:
      truncateCleanup(root, budget.cleanup, "memory")
      raise budget.budgetExpiry(skipCleanup = true)
    raise markBudgetExpiry(budget, root, true, prefix)

proc sampleCleanupBudgets*(root: EvalBudget): ref GeneBudgetExpiry =
  ## Cleanup entry is exceptional: sample all applicable guards without
  ## charging steps or changing their normal sampling phases. An expired
  ## guard joins the pending unwind; it cannot replace its primary reason.
  var current {.cursor.} = root
  while current != nil:
    try:
      if current.hasDeadline or current.hasMemoryLimit:
        checkExecutionBudgetSample(current, root)
    except GeneBudgetExpiry as failure:
      result = failure
    current = current.parent

proc attachCleanupDiagnostics*(budget: EvalBudget) =
  if budget.cleanup != nil and budget.cleanup.truncated.len > 0 and
      budget.expiryError.hasErrVal:
    let reason = budget.cleanup.truncated
    budget.expiryError.errVal.updateErrorEvidence(proc(evidence: ErrorEvidence) =
      evidence.diagnostics["cleanup_truncated"] = TRUE
      evidence.diagnostics["cleanup_reason"] = newStr(reason))

proc enclosingBudgetExpiry*(failure: ref GeneBudgetExpiry): ref GeneBudgetExpiry =
  ## Before converting at an inner boundary, observe already-expired ancestors.
  ## This does not charge instructions or change normal sampling frequency.
  result = failure
  var current {.cursor.} = failure.budget.parent
  while current != nil:
    if current.expiryError != nil:
      result = current.budgetExpiry(failure.skipCleanup)
    elif current.hasDeadline and getMonoTime() >= current.deadline:
      result = markBudgetExpiry(current, failure.budget, false)
    elif current.hasMemoryLimit and
        getOccupiedMem().int64 - current.memoryBaseline > current.memoryLimitBytes:
      result = markBudgetExpiry(current, failure.budget, true)
    current = current.parent

proc closeExpiredBudget*(budget: EvalBudget) =
  budget.closed = true
  # Force the existing inline path to the cold check if this dynamic budget
  # is retained by a host or a captured scope and is used again.
  budget.sampleCountdown = 0
