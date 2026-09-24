## Destructors that run while a Nim exception is still propagating.
##
## With goto-based exceptions Nim sometimes invokes a destructor before it
## clears the pending-exception flag: the assigned result temporary of a call
## that raised, and each element a container's generated destructor releases
## during unwinding. The destructor's own code then sees the flag after every
## call that could raise and returns at the first such check, skipping the rest
## of its cleanup. A destructor that does more than straight-line C calls must
## run its body as if nothing were pending and then restore the flag.

when compileOption("exceptions", "goto"):
  proc nimErrorFlag(): ptr bool {.importc, nodecl, raises: [], gcsafe.}

template pendingExceptionFlag*(): ptr bool =
  ## The runtime's pending-exception flag. Only meaningful with goto
  ## exceptions; callers guard with `when compileOption("exceptions", "goto")`.
  nimErrorFlag()

template withoutPendingException*(body: untyped) =
  ## Run a destructor body with the pending-exception flag cleared, restoring
  ## it afterwards. `body` must not `return`: that would skip the restore and
  ## lose the exception still propagating.
  when compileOption("exceptions", "goto"):
    let pendingException = nimErrorFlag()
    let wasPending = pendingException[]
    pendingException[] = false
    body
    if wasPending:
      pendingException[] = true
  else:
    body
