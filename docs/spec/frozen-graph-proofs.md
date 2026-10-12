# Frozen data and repeated graph checks

The native runtime may attach predicate-specific negative proofs to freshly
constructed, deeply frozen Lists and property Maps. This is internal metadata;
it does not change identity, equality, serialization, mutation rules or which
programs are admitted.

The initial eligible subset is deliberately narrow: nil/void, booleans,
integers, floats, strings, Bytes, characters, symbols, and certified Lists or
property Maps containing only that subset. Proof bits distinguish absence of
borrowed caller environments, absence of scope captures, and absence of weak
scope edges requiring promotion. An eligible container composes its proof
from immediate children once at construction, after freezing them. Reading
an existing proof is constant time and does not mutate published values.

`deepFrozen` alone is not a substitute. Types can retain scope state, and even
structurally frozen Nodes can carry or acquire mutable runtime error evidence.
Nodes, types, Set/HashMap, functions, environments, cells, streams, native
resources and all other unproven kinds retain the original checks. A mixed
parent receives no whole-subtree proof, but its eligible children can still
be skipped when visited. A shallow freeze, thaw or ordinary constructor does
not inherit a certificate. Mutable constructors cannot acquire a certificate
merely because an internal caller supplied the deep-frozen flag.

The borrowed-authority check, tail-call capture check and weak-function escape
scan/walk use only the proof relevant to their predicate. An unchanged pure
data subtree has no caller-dependent scope relationship, so the negative
answer applies to any current caller. Context-dependent values remain on the
full path. The optimization does not skip in-progress construction checks or
change worker publication/Send admission.

`-d:geneGraphProofTests` enables private `runtime/test_graph_scans` start/stop
instrumentation for visited/skipped nodes in each check. Ordinary builds omit
these counters and entry points. `-d:geneDisableFrozenGraphProofs` retains the
full scans for differential qualification. These switches are testing tools,
not language features or production tuning contracts.

Tests: `tests/test_frozen_graph_proofs.nim` checks certificate eligibility and
`tests/fixtures/frozen_graph_proofs.gene` checks traversal scaling, mutable and
shallow aliases, borrowed authority, escaping closures and cyclic fallbacks.
`tools/benchmark_frozen_checks.gene` times repeated stores/returns after data
construction and freezing; this intentionally measures the repeated check,
not the cost of constructing or serializing a whole history.
Its optional `--stats` argument records graph visits with an instrumented
runtime. `tests/test_thread_workers.nim` also verifies certificate preservation
through publication to multiple atomicArc worker threads and repeated stores
there; certificates remain construction-time metadata rather than lazy writes.
