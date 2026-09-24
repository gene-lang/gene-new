import gene/io_lifecycle
import std/unittest
when compileOption("threads"):
  import std/typedthreads

  proc raceAdmissions(resource: IoLifecycle) {.thread.} =
    for _ in 0 ..< 1000:
      let admission = resource.admitIoOperation(iodWrite, 1)
      if admission.accepted:
        discard resource.finishIoOperation(admission.ticket)

suite "I/O lifecycle — admission and retirement":
  test "read and write slots are independent; flush occupies write":
    let budget = newIoBudget()
    let resource = newIoLifecycle(budget, 1)
    let read = resource.admitIoOperation(iodRead, 64)
    let write = resource.admitIoOperation(iodWrite, 32)
    check read.accepted and write.accepted
    check resource.admitIoOperation(iodRead, 1).failure == iaBusy
    check resource.admitIoOperation(iodFlush, 0).failure == iaBusy
    check resource.ioSnapshot().activeOperations == 2
    check budget.ioBudgetSnapshot() == (retainedBytes: 96, cleanupLeases: 2)
    check resource.finishIoOperation(read.ticket).accepted
    check resource.finishIoOperation(write.ticket).accepted
    check budget.ioBudgetSnapshot() == (retainedBytes: 0, cleanupLeases: 0)
    let flush = resource.admitIoOperation(iodFlush, 0)
    check flush.accepted and not flush.immediate
    check resource.admitIoOperation(iodWrite, 1).failure == iaBusy
    check resource.finishIoOperation(flush.ticket).accepted

  test "close retains operation and close leases until physical retirement":
    let budget = newIoBudget()
    let resource = newIoLifecycle(budget, 7)
    let write = resource.admitIoOperation(iodWrite, 100)
    check write.accepted
    check not resource.requestIoClose()
    check resource.ioSnapshot().phase == iopClosing
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 100, cleanupLeases: 2)
    check resource.admitIoOperation(iodRead, 1).failure == iaClosed
    check not resource.retireIoClose()
    let finished = resource.finishIoOperation(write.ticket)
    check finished.accepted and finished.retireReady
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 0, cleanupLeases: 1)
    check resource.retireIoClose("close failed")
    check resource.ioSnapshot().phase == iopClosed
    check resource.ioSnapshot().closeError == "close failed"
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 0, cleanupLeases: 0)
    check not resource.requestIoClose()
    check not resource.retireIoClose()

  test "close waits for both independent directions":
    let budget = newIoBudget()
    let resource = newIoLifecycle(budget, 8)
    let read = resource.admitIoOperation(iodRead, 3)
    let write = resource.admitIoOperation(iodWrite, 2)
    check not resource.requestIoClose()
    let first = resource.finishIoOperation(read.ticket)
    check first.accepted and not first.retireReady
    check resource.ioSnapshot().phase == iopClosing
    let second = resource.finishIoOperation(write.ticket)
    check second.accepted and second.retireReady
    check resource.retireIoClose()
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 0, cleanupLeases: 0)

  test "stale and duplicate completions never free a live reservation":
    let budget = newIoBudget()
    let resource = newIoLifecycle(budget, 23)
    let first = resource.admitIoOperation(iodRead, 8)
    var forged = first.ticket
    forged.resourceId = 24
    check not resource.finishIoOperation(forged).accepted
    forged = first.ticket
    forged.sequence += 1
    check not resource.finishIoOperation(forged).accepted
    forged = first.ticket
    forged.reservedBytes = 100
    check not resource.finishIoOperation(forged).accepted
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 8, cleanupLeases: 1)
    check resource.finishIoOperation(first.ticket).accepted
    check not resource.finishIoOperation(first.ticket).accepted
    let second = resource.admitIoOperation(iodRead, 4)
    check second.ticket.sequence != first.ticket.sequence
    check not resource.finishIoOperation(first.ticket).accepted
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 4, cleanupLeases: 1)
    check resource.finishIoOperation(second.ticket).accepted

  test "resource and Application byte budgets include active payloads":
    let budget = newIoBudget(5)
    let first = newIoLifecycle(budget, 1, maxBytes = 4)
    let second = newIoLifecycle(budget, 2, maxBytes = 4)
    let write = first.admitIoOperation(iodWrite, 4)
    check write.accepted
    check second.admitIoOperation(iodRead, 2).failure == iaBackpressure
    let read = second.admitIoOperation(iodRead, 1)
    check read.accepted
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 5, cleanupLeases: 2)
    check budget.ioBudgetPeak() == 5
    check first.finishIoOperation(write.ticket).accepted
    check second.finishIoOperation(read.ticket).accepted
    check first.admitIoOperation(iodWrite, 5).failure == iaBackpressure
    check first.admitIoOperation(iodWrite, 1_048_577).failure == iaBackpressure

  test "empty write has a fresh immediate result and no cleanup lease":
    let budget = newIoBudget()
    let resource = newIoLifecycle(budget, 1)
    check resource.admitIoOperation(iodRead, 0).failure == iaInvalid
    let empty = resource.admitIoOperation(iodWrite, 0)
    check empty.accepted and empty.immediate
    check budget.ioBudgetSnapshot() ==
      (retainedBytes: 0, cleanupLeases: 0)
    check resource.requestIoClose()
    check resource.admitIoOperation(iodWrite, 0).failure == iaClosed
    check resource.retireIoClose()

  when compileOption("threads"):
    test "concurrent admissions leave no busy slot or leaked lease":
      let budget = newIoBudget()
      let resource = newIoLifecycle(budget, 1)
      var left, right: Thread[IoLifecycle]
      createThread(left, raceAdmissions, resource)
      createThread(right, raceAdmissions, resource)
      joinThread(left)
      joinThread(right)
      check resource.ioSnapshot().activeOperations == 0
      check budget.ioBudgetSnapshot() ==
        (retainedBytes: 0, cleanupLeases: 0)
