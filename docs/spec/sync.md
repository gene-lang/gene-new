# Root-lane synchronization

`gene/sync` is available as `$sync`. `($sync/gate)` creates a callable,
non-reentrant gate for work on one application's scheduler root lane:

```gene
(let gate ($sync/gate))
(let result (gate (fn []
  # This body may suspend. Other callers of this gate wait on a channel.
  (update_state)
  42)))
```

A gate invokes a zero-argument callable and returns its result. It provides
mutual exclusion across tasks and actor handler fibers on that root lane.
Creation and invocation on another lane raise `RuntimeLaneError`; this is
not a cross-thread mutex. A gate captures mutable local state and is not Send.
It is neither a durable lock nor a serializable application record.

The owning execution may suspend while inside the body. Another caller parks
using the existing channel wait mechanism; it does not repeatedly sleep and
retry. Recursive acquisition by the same execution raises `RuntimeError`
with a non-reentrant diagnostic. Code needing intentional reentry should
use a separate explicitly unlocked helper under the owning operation, rather
than treating recursive acquisition as a second lock.

Acquisition records native ownership in the same operation that consumes the
token. Cancellation while waiting does not consume ownership. Cancellation
after acquisition, a caught or uncaught body error, panic, execution-budget
exhaustion, and normal return all release the gate when its wrapper frame exits.
The original outcome propagates. Process death and uncooperative external code
remain outside this cleanup guarantee.
Waiting in a synchronous native callback retains the existing prohibition
on suspension; a gate does not bypass that boundary.

No FIFO acquisition order or starvation bound is promised. Existing channel
wakeups and scheduler choices determine which eligible caller acquires next.
The observable guarantee is exclusive ownership with cancellation-safe
release, not a particular opcode sequence or reference-count representation.

`($sync/track entries key thunk)` temporarily registers `key` with value `true`
in a mutable property Map, runs the zero-argument `thunk`, and returns its
result. `key` must be a Str absent from `entries`; duplicate registration fails
without removing the existing entry. The entry is removed on every wrapper
exit, including budget exhaustion. Callers must leave that key owned by the
registration until it exits. This is root-lane bookkeeping for operations such
as waiting for admitted invocations; it does not make the whole Map a transaction.

The wrappers live in `src/gene/lib/sync.gene`, embedded into the native standard
library. Private native leaves check lane ownership and register cleanup on the
VM's current call-frame depth, independently of lexical scopes that optimized
calls may share. Ownership follows suspended continuations and prevents tail
elimination of the owning wrapper until the body returns. Panic/cancellation
retire crossed structured children and native owners before entering an outer
Gene cleanup, which can then reacquire the gate or registration. Channel receive
is retried on resumption rather than transferring a token to a cancelled waiter.
Native cleanup only clears the private owner and returns the token, or removes
the tracked Map entry. It executes no Gene callback and grants no extra execution
budget. General `ensure` bodies remain subject to existing budget checks; no
scheduler safepoints or core language semantics are changed.

Qualification is in `tests/fixtures/sync_gate.gene`, including reentry, errors,
owner and waiter cancellation, release/cancellation races, distinct actor
handler identities, panic, nested ownership, and expired deadlines.
These fixtures run under the schedule-variation matrix.
