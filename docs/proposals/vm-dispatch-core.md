# VM dispatch core

**Status:** Proposed 2026-11-12. The default build (no profile) stays the
build Gene is measured and shipped with: a PGO build takes about 13 minutes
against about 2. On `perf/python-gap` the call-budget guard (`113c9fa9`) is
kept. D1's shared return paths (`908bb4e0`) were reverted (`0f225ea6`)
because they paid only with a profile, and call entry stays inline after two
attempts. D2 is answered: without a profile, block placement, not code size,
decides the dispatch loop's speed. D5, a separate small loop for the hot
instructions, is implemented; D3 and D4 are open. Evidence is in
`benchmarks/baselines/2026-11-12-dispatch-core/`.

**Stages:** D1 (one copy of the frame paths), D2 (layout check), D3 (frame-local
slots), D4 (threaded dispatch, optional), D5 (a small loop for the hot
instructions).

## Why

A Gene call costs 45 ns without a scope, 78 ns for a function with a local and
83 ns for a closure, against about 15 ns in CPython 3.14 (net of the loop, see
[boundary costs](../reports/boundary-costs.md)). The attempts to cut the scope
cost directly were each within a few percent, and that is the size of the swing
`runLoop` shows when unrelated code is added to it: plain loops move by 1–10%
in every paired round, and two builds of the same source differ by up to 4%.
Small call-path wins cannot be measured until that settles.

## What `runLoop` is made of

`runLoop` compiles to 901 KB of machine code, about 225,000 instructions, and
to 160,000 lines of C. The dispatch `switch` takes 5.7 M characters of that C,
shared out by case like this:

| Cases | Share |
| --- | ---: |
| Returns: `opReturnIntAdd2` 18.7%, `opReturnLocalIfIntLt*` 6.3%, `opReturnBareInt` 6.2%, `opReturn` 2.9%, `opExplicitReturn` 2.9% | 37% |
| Calls: `opCallName*`/`opCallLocal1`/`opCallOuterLocal1` 13.7%, `opCall*` 11.8%, `opCallLocal0` 7.7%, `opCallSplice`/`opCallPrepared` 7.2% | 40% |
| The other ~140 cases | 23% |

The returns and calls are large because two templates are expanded many times:

- `frameReturn` and `finishFrameReturn` handle every frame kind's return
  (function, `try`, `ensure`, `for` body, task scope, supervisor, namespace),
  with about ten `loadFrameRegs` expansions each. `frameReturnBareInt`
  expands both, and `opReturnIntAdd2` expands it three times: about six copies
  of the general return path in one case, and about fifteen in `runLoop`.
- `enterBytecodeCall` handles tail-call replacement, match-arm frame
  collapse, the frame push and the register setup. It is expanded about 34
  times, directly or through `maybeEnterUserCallableBytecode` and
  `maybeEnterBoundMessageBytecode`.

The `{.computedGoto.}` pragma on the dispatch loop has no effect. Nim wraps a
loop body that contains `continue` in a block (`transformLoopBody`), the code
generator no longer finds the pragma, and the C is an ordinary `switch`, which
LLVM lowers to one jump table. Dispatch is central, not threaded.

## What the layout swing is (D2)

The size was not the cause. Sharing the return paths (D1) cut `runLoop` from
901 KB to 705 KB, and in a default build `while` and `repeat` loops, which run
no return, became 6% slower in every round.

The machine code shows why. A default build has no branch weights, so LLVM
places a handler's likely successor wherever its block chains end up, and it
merges identical tails of different handlers into shared blocks. One
`opLoadLocal` runs through four regions spread over about 170 KB of `runLoop`
before it reaches the next dispatch; another build arranges the same handler
differently. Every change to `runLoop` rearranges every handler, which is the
swing. Turning off tail merging (`-enable-tail-merge=false`) made `runLoop` 14%
larger and left the hot path scattered.

With a profile (`nimble speedy_pgo`, which builds with
`-fprofile-instr-generate`, runs `tools/pgo/train.sh` and rebuilds with the
profile), the blocks of `opLoadLocal`'s hot path follow each other, and LLVM
copies the dispatch into the hot handlers (54 indirect branches instead of
14), which is the threaded dispatch D4 was after. Changes then measure as what
they are. Medians of per-round ratios, kernels and call-cost program:

| Paired rounds, 7 each | Result |
| --- | --- |
| PGO against the same flags without it, at `b25adf33` | 0.73–0.97 on every kernel, most 0.74–0.88 |
| D1 returns against `b25adf33`, both PGO, two batches | 0.81–1.00 on every kernel (`while` 0.81 and 0.83, `repeat` 0.93 and 0.91, `fib` 0.94–0.95, calls 0.97–1.00) |
| D1 returns against `b25adf33`, both default builds | 1.01–1.13, except `fib` 0.92–0.96 |

The training inputs had broken on main's collection migration
(`examples/pipeline.gene` and `tools/pgo/workload.gene`), and `train.sh` runs
with `set -e`, so `nimble speedy_pgo` built from an almost empty profile
until `dd124778`.

## Plan

**D1. One copy of the frame paths.** A return instruction parks its value,
saves `ip` and sets it past every chunk's end. The dispatch header's
end-of-chunk test, which runs before every instruction anyway, sends it to the
one copy of the return paths. Implemented in `908bb4e0` and reverted in
`0f225ea6`: it paid only in the profiled build.

For calls, neither way of sharing `enterBytecodeCall` paid, so call entry
stays inline:

- Sharing all of it the same way (`runLoop` 479 KB) lost 2–6% on call-heavy
  kernels against D1 under PGO. At each call site most of its arguments are
  constants the inline copy is specialized for; the shared copy reads all
  fourteen from memory.
- Keeping a call without a tail mark from a plain frame inline and sharing the
  rest (514 KB) kept the calls but gave back most of D1's gain on loops: the
  `while` kernel ran 10% more instructions (27.66 G against 25.18 G for 20 M
  iterations), because the inline frame pushes at about 34 sites change how the
  registers of every handler are allocated. Instruction counts from
  `/usr/bin/time -l` repeat to within 0.1%, so they show this independently of
  the machine's load.

Each simple call also ran `applyCallBudget`, which with nothing budgeted reads a
thread-local and walks the callee's and the caller's scope chains to their
module roots. The dispatch loop now skips it exactly when it would do nothing:
no budget on the caller's scope or running in the loop, none bound to the
function or on the callee's scope, and no module policy installed anywhere
(`modulePoliciesInstalled`, kept by the only writer of the field). In the
default build, without the shared returns, a call with a local runs 68 fewer
instructions and is 0.96 (7 of 7 rounds), closures and sends 0.96–0.99, fib
0.96–0.99; loops run the same instructions and are within 2%.

**D3. Frame-local slots.** A function whose scope cannot escape keeps its
locals in its frame's region of the operand stack, as scopeless calls already
keep their arguments. Under PGO a call costs about 35 ns without a scope and
about 60 ns with one, so this is the largest remaining per-call item.

The function's own scope is not needed for name lookups if the scope register
holds the function's defining scope and outer-local depths drop by one, which
also covers closures. The return, unwinding and tail-call paths assume the
scope register belongs to the activation (`finishUnpooledReturn`,
`retireUnwoundScope`, `retireAbandonedCallScope`,
`releaseUnwoundFrameScope`, `finishImplAssembly`), so such a frame must mark its
scope as borrowed. The compiler admits only bodies that create no closure and
use no `eval`, macro, caller environment (which includes calling an `fn!`),
generator, error lease, private slot or annotation self type, and no `for`
loop or block scope, which make a child of the current scope. The VM takes the
convention only when no budget or policy applies to the call, since
`applyCallBudget` may need a scope of the call's own to hold one.

**D5. A small loop for the hot instructions.** Implemented. Without a
profile, the hot handlers' code depends on register allocation over all of
`runLoop`: the `while` kernel spent about 94 instructions per dispatch, and
both profile-free attempts to steer the compiler moved it the wrong way. D1's
shared returns made loops slower; declaring Nim's raising procs `cold` made the
`while` loop run 8.6% more instructions.

`fastLoop` is a separate small proc that runs the fast paths of 30 simple
instructions (local loads and stores, constants, pops, jumps, `!`, `&&`/`||`
jumps, and the small-Int cases of the native and typed arithmetic and
comparisons, fused compare-and-jump included) exactly as their `runLoop`
handlers do, and returns at the first instruction it does not run, or the
first case its handler would raise in or treat beyond its fast path. It runs
only with no budget active. `runLoop` enters it at `opLoopEnter`, once per
loop, and only for a loop made only of those instructions, worked out once
per loop (`Chunk.fastLoopJumps`). Entering at every backward jump put a call
in `opJump`, which every iteration runs, and changed the code of other
handlers: a call with a local ran 3.2% more instructions.

Two extensions followed. Numbers other than small Ints go through
`tryFastNativeKind2`, as `opNativeFast2`'s and `opNativeFastConst`'s handlers
send them, for the kinds it answers without raising (add, subtract, multiply,
the orderings): the `float` kernel is 0.59–0.64. `opForInlineNext`'s range
case runs there too, so `for` over a range stays in `fastLoop`: `for_range` is
0.74. Both 7 of 7 rounds, with no other kernel running more instructions.

In the default build, `repeat` is 0.60 of its time, a bare loop 0.62 and
`while` 0.67 (7 of 7 rounds each, `while` now about CPython's time), with 26%
fewer instructions in the `while` loop; every other kernel runs the same
instructions and is within 2%. `tests/test_fast_loop.nim` runs a corpus of
loops with it on and off (`fastLoopEnabled`) and compares results and errors,
checks that the kernels do run in it (`-d:geneFastLoopTests`), and that a
budgeted loop still stops at its deadline. Its cost is a second
implementation of each covered fast path; a change to one of those handlers
must change `fastLoop` too, and the differential test is where a difference
shows. Loops that call, send, construct or `break` stay in `runLoop`.

**D4. Threaded dispatch.** PGO copies the dispatch into hot handlers; the
default build keeps one central dispatch block. LLVM duplicates a block that
ends in an indirect branch into its predecessors only while it is small, so a
dispatch header with fewer instructions, or a source-level computed goto,
which needs that code free of `continue`, would give the default build
threaded dispatch.

## Decision: the default build

`bin/gene` from `nim c src/gene.nim` has no profile, so its speed after any
change to `runLoop` is partly the luck of block placement, and D1 made it
1–13% slower while making the profiled build 0–19% faster. A PGO build takes
about 13 minutes on this machine against about 2 for the default: 2 for the
instrumented build, 10 for the training (mostly the Harness specs) and 1 for
the final build. The owner chose the default build (2026-11-12), so a change
to `runLoop` must pay without a profile. Branch weights given in the source
(`likely`, `unlikely`) are the profile-free way to tell the compiler which
paths are hot.

## Measurement

`train.sh`'s counts are dominated by the Harness specs (30 times the rest
together), whose paths depend on timing, so two builds of nearly the same source
with it differ by up to 3% in the instructions a kernel runs. Without the specs
(`benchmarks/baselines/2026-11-12-dispatch-core/scripts/train-quick.sh`, 20 s
instead of 10 minutes) the profile repeats (100.000% edge overlap) and two
builds of one source run the same instructions to within 0.003%. That build is
also faster on these kernels: 12% fewer instructions in the `while` loop and 5%
fewer per call than with the full training.

Every stage is measured in paired rotating rounds against its parent
(`benchmarks/baselines/2026-11-12-panics/pairs/pairn.sh`), on the kernels and
on a call-cost program, and by instructions retired, with both sides default
builds. Instruction counts separate the work a change removes from the
placement it disturbs; a PGO comparison with the quick training is a useful
second view, since its builds repeat.
Every stage must pass `tests/test_all.nim`, the spec runner,
`tests/test_poll_window.nim`, `tests/test_rc.nim` (with `-d:geneRcStats`) and
`tests/test_value_backend_boundaries.nim` with the parent's results. A stage
that does not help is not committed.
