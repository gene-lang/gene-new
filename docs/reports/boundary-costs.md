# Boundary costs that grew with the data

Work on branch `perf/python-gap`, 2026-11-11, from `37bd3631`. It implements
the order suggested by a comparison of Gene with CPython 3.14: remove the
costs that grow with the size of the data first, then the largest constant
costs the comparison found.

Every change is internal. Programs see the same values, the same errors and
the same identities as before, with one exception that is a bug fix (section
7). Each fast path was compared against the runtime before it existed, on
the cases in `tests/test_boundary_fast_paths.nim` and
`tests/test_escape_inert.nim`.

## Result

Release builds of `37bd3631` ("before") and of the branch ("after") on an
Apple M4 Pro, CPython 3.14.3. Raw output and provenance are in
`benchmarks/baselines/2026-11-11-boundary-costs/`.

### By size

`benchmarks/boundaries.gene`, five alternating rounds. Nanoseconds per
iteration with the loop included, or milliseconds for a whole batch. The
value is the median of the rounds; the last column is the median of the
per-round ratios.

| Kernel | Before | After | Before / After |
| --- | ---: | ---: | ---: |
| loop only | 45 ns | 45 ns | 1.0x |
| return a list of 100 integers | 396 ns | 139 ns | 2.8x |
| return a list of 100 maps | 1,396 ns | 140 ns | 10.0x |
| return a list of 100 typed records | 2,285 ns | 140 ns | 16.3x |
| return a frozen list of 100 typed records | 2,441 ns | 135 ns | 18.0x |
| accessor returning 100 maps from a map | 1,411 ns | 159 ns | 8.8x |
| accessor returning 100 records from a typed record | 2,305 ns | 155 ns | 14.7x |
| store a list of 100 maps into a map | 1,270 ns | 61 ns | 20.8x |
| push a list of 100 maps onto a new list | 1,333 ns | 95 ns | 13.9x |
| push one integer, then return the list of 100+ integers | 26,719 ns | 167 ns | 159.3x |
| return a list of 10000 integers | 25,000 ns | 135 ns | 183.9x |
| return a list of 10000 maps | 133,750 ns | 138 ns | 995.8x |
| return a list of 10000 typed records | 167,500 ns | 138 ns | 1,214.3x |
| return a frozen list of 10000 typed records | 165,000 ns | 138 ns | 1,196.2x |
| accessor returning 10000 maps from a map | 136,250 ns | 159 ns | 857.1x |
| accessor returning 10000 records from a typed record | 165,000 ns | 154 ns | 1,073.2x |
| store a list of 10000 maps into a map | 132,500 ns | 60 ns | 2,192.8x |
| push a list of 10000 maps onto a new list | 132,500 ns | 97 ns | 1,361.1x |
| push one integer, then return the list of 10000+ integers | 31,562 ns | 170 ns | 186.0x |
| push 2000 integers to a typed node body | 87 ms | 1.0 ms | — |
| push 2000 integers to a plain node body | 0.0 ms | 0.0 ms | — |
| push 2000 integers to a list | 0.0 ms | 0.0 ms | — |
| push 8000 integers to a typed node body | 1,377 ms | 2.0 ms | 673.0x |
| push 8000 integers to a plain node body | 1.0 ms | 1.0 ms | — |
| push 8000 integers to a list | 1.0 ms | 1.0 ms | — |
| write 1000 items of a typed node body by index | 46 ms | 0.0 ms | — |
| write 4000 items of a typed node body by index | 740 ms | 1.0 ms | — |
| read a record field | 57 ns | 58 ns | 1.0x |
| write a record field | 210 ns | 79 ns | 2.6x |
| write a Map entry by path | 83 ns | 82 ns | 1.0x |
| send a message that increments a field | 377 ns | 250 ns | 1.5x |
| construct a two-field record | 258 ns | 265 ns | 0.9x |
| repeat loop summing | 52 ns | 50 ns | 1.0x |
| for over ($range 0 n) summing | 149 ns | 49 ns | 3.1x |
| call f(xs), untyped, 1000 integers | 126 ns | 127 ns | 1.0x |
| call f(xs : (List Int)), 1000 integers | 19,453 ns | 448 ns | 43.4x |
| call (id a), untyped | 110 ns | 109 ns | 1.0x |
| call (id a), [a : Int] | 170 ns | 115 ns | 1.5x |
| call (id a), [a : Int] : Int | 64 ns | 64 ns | 1.0x |
| call (add a b), untyped | 146 ns | 149 ns | 1.0x |
| call (add a b), Int parameters only | 211 ns | 160 ns | 1.3x |
| call (add a b), Int parameters and result | 93 ns | 96 ns | 1.0x |
| call (add a b) on floats, untyped | 146 ns | 157 ns | 0.9x |
| call (add a b), Float parameters and result | 225 ns | 237 ns | 0.9x |
| call (size s), untyped | 162 ns | 175 ns | 1.0x |
| call (size s), [s : Str] : Int | 210 ns | 214 ns | 1.0x |

In the fifth round the last ten rows of the "after" run were 40% to 120%
slow together, which is a burst on the machine and not the code; the medians
are unaffected. The rows no change touches differ by up to 7% between the
two binaries in the other four rounds, in both directions. That is within
what two builds of the same semantics differ by on this machine. Record
construction is the exception worth watching: it is 1% to 7% slower in every
round here and 3% slower in the kernel run below, and nothing in this work
should have touched it.

### Against Python

`benchmarks/run_kernels.gene` at the branch head `98f8e870`, five
alternating rounds of fresh processes after one warmup, with the baseline
binary in each round. Each ratio is the median of the per-round ratios. Times
are whole milliseconds, so the Python times under 20 ms carry several percent
of rounding. The same run before section 9's commits is in `kernels/`.

| Kernel | Gene ms | Python ms | Gene / Python | Baseline ms | Baseline / Python | Gene / Baseline |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| fib30 | 126 | 59 | 2.2 | 122 | 2.1 | 1.04 |
| while_arith_3M | 178 | 92 | 1.9 | 178 | 1.9 | 1.0 |
| for_range_3M | 148 | 54 | 2.7 | 443 | 8.1 | 0.34 |
| repeat_3M | 162 | 54 | 3.0 | 151 | 2.8 | 1.06 |
| list_push_index_1M | 166 | 45 | 3.7 | 166 | 3.7 | 1.0 |
| list_push_for_1M | 124 | 38 | 3.3 | 119 | 3.1 | 1.04 |
| map_strkey_500k | 257 | 86 | 3.0 | 254 | 3.0 | 1.02 |
| field_rw_2M | 341 | 77 | 4.4 | 589 | 7.6 | 0.57 |
| alloc_record_1M | 250 | 59 | 4.2 | 274 | 4.5 | 0.92 |
| send_2M | 484 | 57 | 8.5 | 734 | 12.9 | 0.66 |
| closure_2M | 292 | 52 | 5.6 | 313 | 6.1 | 0.95 |
| str_interp_500k | 128 | 57 | 2.2 | 138 | 2.4 | 0.93 |
| float_3M | 181 | 58 | 3.1 | 182 | 3.2 | 0.99 |
| map_literal_1M | 194 | 75 | 2.6 | 200 | 2.7 | 0.99 |
| accessor_10k_records_200k | 59 | 8 | 7.4 | 31107 | 3889.8 | 0.0 |
| store_10k_records_200k | 38 | 6 | 6.3 | 62096 | 10349.3 | 0.0 |
| typed_list_param_1k_500k | 205 | 12 | 17.4 | 9210 | 767.5 | 0.02 |
| field_write_2M | 157 | 17 | 9.6 | 407 | 24.3 | 0.39 |
| typed_call_3M | 277 | 73 | 3.8 | 276 | 3.8 | 1.0 |

Three loop kernels are slower than the baseline in both runs of this
comparison: `repeat_3M` by 4% and 6%, `fib30` by 3% and 4%, `list_push_for_1M`
by 4% and 4%. No change on the branch adds work to the `repeat` loop.
`fib30` was already 3% slower before section 9's commits, one of which made
its returns cheaper. `list_push_for_1M` pushes to a list, where the branch
added two byte tests per push (the stamp and the item kind), far too little
for 5 ms over a million pushes. Two builds of identical semantics have
differed by up to 17% on single kernels on this machine, which is the likely
cause, but it is not shown here. It would take a baseline
rebuilt with a perturbed layout, or the generated code compared for the loop
handlers, to settle it.

The general suite (`benchmarks/run_general.gene`, defaults) is unchanged, as
expected: none of its workloads passes a large value across a boundary.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.383 | 0.181 | 2.109 |
| closure_dispatch | 1.703 | 0.394 | 4.321 |
| records | 1.719 | 0.88 | 1.952 |
| text_index | 6.375 | 1.668 | 3.822 |
| json_roundtrip | 1.445 | 2.738 | 0.528 |
| event_replay | 1.828 | 0.634 | 2.883 |

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 0.363 | 0.383 | 0.949 |
| closure_dispatch | 1.672 | 1.703 | 0.982 |
| records | 1.797 | 1.719 | 1.045 |
| text_index | 6.5 | 6.375 | 1.02 |
| json_roundtrip | 1.438 | 1.445 | 0.995 |
| event_replay | 1.797 | 1.828 | 0.983 |

## 1. Returns and stores no longer rescan unchanged data

A returned or stored value is scanned for weak scope edges, and the scan
visited everything reachable from it every time. Returning a list of 10,000
maps cost 134 µs. It now costs 138 ns.

A container the scan has proven to hold nothing it acts on now carries a
stamp, and the next scan stops there. One process-wide counter retires every
stamp when something that needs the scan is stored into a stamped container,
when a type drops its scope edge again, or when a module reference is patched
in place. The invariant, the argument for it and its limits are in
[the specification note](../spec/escape-inert-stamps.md).

What makes the argument tractable is that containers are private to
`types.nim`: eleven store procedures are the only way to write one from
outside, and each tests the stored value in constant time.

The stamp costs no memory. A first version added a field to each container,
which pushed Maps and Nodes into the next allocation size and made record
construction about 6% slower in every round. The `shared` flag of a List, Map
and Node is now half a word and the stamp takes the other half.

Limits: a cyclic graph, a container published to another lane, and data that
holds a scope binding, a stream or a task are still scanned in full each
time. The borrowed caller-environment walk, which runs on stores in a program
that has used `fn!`, is a separate walk and is unchanged.

Verification: `-d:geneInertStampVerify` keeps the old scan and runs it
wherever a stamp answered, exiting if the two disagree. The Nim suite passes
in that build with no disagreement.

## 2. Pushing to a typed node's body is no longer quadratic

A push copied the props and the body and validated the whole node. That
revalidation is observable when a field holds a container that was changed
through another reference, so it cannot simply be dropped.

A node now carries a mark saying that every prop and body item was found to
need no boundary work against its schema, and that only a checked push has
written to it since. Whether a value needs boundary work depends on its kind
alone, and the node still holds the same values, so while the mark holds
revalidation would change nothing. A push then checks only the new item.
Every other writer of a node clears the mark. A node with a container
annotation never gets it and keeps the full validation.

An indexed write, `(set node/3 v)`, had the same shape: it copied the body,
strengthened every item again and validated the whole node. It now checks
only its own position when the node is checked and every body field is an
exact-kind scalar, which is when the items already there hold nothing to
strengthen. An untyped or `Any` body keeps the full route.

## 3. A `(List Int)` boundary no longer visits every item on every call

For an exact-kind scalar item type, an item of that kind matches. A list
found to hold only that kind remembers it, and a store of another kind
clears it. Nested and parameterized item types are checked item by item as
before. This does not settle what a parameterized annotation should mean at
run time; it makes the present meaning cheaper for the common case.

## 4. Scalar annotations on leaf functions

A leaf function with scalar annotations was slower than the same function
without them, because any annotation other than all-`Int` with an `Int`
result excluded it from the scopeless calling convention. A function whose
parameters are untyped or carry an exact-kind scalar annotation is now
admitted when it needs no return boundary: no declared result, or one the
compiler proved redundant. The call site tests each argument against its
annotation; a miss takes the classic convention, which adapts the value or
raises the usual error. GIR format 45.

Not covered: a function with a declared result the compiler cannot prove, and
a function that is not a leaf. Those still bind a scope and declare slot
types, and remain slower than untyped: the `Float` and `Str` call rows of
the table are unchanged.

## 5. Field writes

`(set p/x v)` on a typed record copied the type's whole field list, names
included, compared names as strings and stored by name. It now reads the
schema in place and works by key id. A value its annotation needs no boundary
work for is stored as it is.

## 6. `for` over a range

An inlined `for` handed a range to the frame loop, which wrapped it in a
stream and ran one frame per item. A range is immutable and yields integers,
so the inlined loop now steps it directly. The values and their order are the
stream's, including at the integer limits (section 8).

## 7. A bug fixed on the way

The `Int` fast binders skip declaring a parameter's type on the activation
when nothing can assign the parameter. That analysis did not look inside
nested functions, so this ran without an error:

```gene
(fn f [a : Int] : Int (fn g [] (set a "x")) (g) 1)
(f 1)
```

The same program with a `Str` parameter raised `set 'a' expected Str, got
Int`. A parameter a nested function assigns now keeps its type, and the
`Int` case raises too. This is the one change of behavior on the branch.

## 8. Found on the way

- **The general suite did not run.** It, one of its specs and `run_ops.gene`
  still iterated Maps with `for`, which no longer does that, so the suite
  stopped at its text-index workload. They use `map_for` now. This one was
  fixed because the measurements needed it; the next two were left alone.
- **A range stream drops its last value when the next one would overflow.**
  `($range 9223372036854775805 9223372036854775807 1 true)` yields two
  values, not three, and `($range 0 9223372036854775807 4611686018427387904)`
  yields `[0]`. `pullRangeStream` closes the stream as it produces such a
  value. The inlined loop keeps this so that it agrees with every other
  consumer of a range. Fixing it belongs in the stream.
- **Tests that fail on `37bd3631` itself**, and fail identically on the
  branch: five in `test_all` (one pipeline conversion test and the four `gene
  doc` tests, where `gene doc` prints a hidden `gene_ns` binding and then
  crashes), 54 in `test_rc`, and one in `test_value_backend_boundaries`.

## 9. The interpreter core, from caller-stack profiles

The comparison's last step asked for profiles with caller stacks before any
work on the interpreter core. `profiles/` in the evidence folder holds five,
taken with `sample` on the branch binary as of `51e3fbe8`: a send, a closure
call, record construction, a field read and write, and a list index read.
`profiles/self_and_callers.py` gives each leaf's self time and its callers.

What they show, beyond the dispatch loop itself (37% to 50% of samples):

- **Calls pay for hooks, not work.** In the closure and send kernels the
  largest named costs are `=sink`/`=copy` hooks on `Scope`, `Chunk`, seqs and
  exception refs, a `Value` copy, and the thread-local error flag those hooks
  read (`_tlv_get_addr`, 6% to 7%). Most of the sinks came from one place:
  every return reset fifteen frame registers to their defaults, though they
  already held them.
- **Construction copied names.** About a tenth of the construction kernel was
  `namedArgsFromStack` copying the call instruction's argument names, one
  string allocation each, plus the matching `rawAlloc`/`rawDealloc`.
- **An index read made three calls.** `xs/%i` was already fused, but still
  ran the borrowed-authority check on the integer and reached
  `readIndexedValue` through two generic lookup procs.
- **Scope pooling costs a cycle-candidate registration per call**
  (`rememberCycle` under `releaseCallScope`): releasing the pooled scope drops
  its parent reference. Keeping the parent in the pool would avoid it but
  retains the parent's graph, which was rejected before; it was left alone.

Changes, each measured in paired rounds against the commit before it:

| Commit | Change | Effect |
| --- | --- | --- |
| `b4ac7882` | Reset a frame register only when it is not already its default | Scoped calls 7% to 12% faster |
| `c3a4e3ac` | Direct construction reads the instruction's names in place, out of line | Record construction 12% to 15% faster |
| `98f8e870` | List and small-Int index skips the generic lookup and the authority check | Index reads 7% faster |

Tried and not kept:

- Turning the local-load check (`materializedModuleRefValue`) into a template
  removed a call per load, and calls got faster, but sixteen inlined copies
  made plain loops 5% to 7% slower in every round.
- The same construction path inline at the call site made loops 3% to 5%
  slower; out of line it does not.
- Guarding the field resets in `releaseCallScope` like the frame registers
  had no measurable effect, so it was reverted.

The pattern in all three: code added inline to the dispatch loop costs every
instruction a little, so new fast paths go in out-of-line procs.

## 10. Not done

- The per-instruction costs: instruction size, the dispatch preamble, and the
  frame and scope traffic of every call (section 9 removed part of the
  last). These are the remaining 2x to 6x on calls and loops.
- Message sends, which are still the largest ratio against Python among the
  constant costs (8.7x).
- What is left of the boundary kernels is the call itself: an accessor is one
  call and one return, about 300 ns against Python's 40, and a `(List Int)`
  parameter still takes the general binder, about 430 ns a call.
- Annotated calls outside the shapes in section 4.
- The run-time meaning of a parameterized annotation, which is an owner
  decision.

## Verification

The gate was run on a copy of the tree at `98f8e870`, the last code commit:
`test_all` in the verification build, the language specs, the poll-window
test, `test_rc` and `test_value_backend_boundaries`.

- `test_all` with `-d:geneInertStampVerify`: 1,929 pass. Five fail, the same
  five that fail on `37bd3631` (section 8). No stamp was contradicted by the
  reference scan.
- `spec_runner`: 942 pass.
- `test_poll_window`: 8 pass. Samples still land on the same instructions
  with windowed and exact polling.
- `test_rc` and `test_value_backend_boundaries`: the failures are the same
  54 and 1 as on `37bd3631`, compared by name.

Each fast path was also run against the baseline binary on edge cases
(errors, aliasing, frozen values, big integers, integer limits, arity) with
identical output; those cases are the expected values in the test files.

The AtomicArc and wasm configurations type-check (`nim check`). Their test
suites were not run, nor was ASan, nor the Harness suite. The changes to instruction counts in section 6 move scheduler
slice boundaries, which is the kind of change that has exposed latent races
in Harness code before, so that suite should run before a merge.

## Reproducing

```sh
nim c -o:bin/gene src/gene.nim
bin/gene run benchmarks/boundaries.gene
bin/gene run benchmarks/run_kernels.gene NEW_DIR bin/gene "$(command -v python3)" path/to/baseline-gene
bin/gene run benchmarks/run_general.gene NEW_DIR bin/gene "$(command -v python3)" 5000 path/to/baseline-gene
nim c -r -d:geneScopeReuseTests -d:geneInertStampTests -d:geneInertStampVerify \
  --path:src --hints:off tests/test_all.nim
```

The "By size" table alternates `boundaries.gene` on the two binaries by hand;
`boundaries.tsv` holds the rows with the round and the binary in front.
