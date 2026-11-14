# Escape-inert stamps

A value that is returned from a function, or stored into a container, is
scanned for weak scope edges (`escapeWeakFunctions` in `src/gene/types.nim`).
The scan visits everything reachable from the value, and the usual answer is
that nothing needs doing. A stamp records that answer on the container, so the
next scan of the same data stops there. This is internal metadata. It does not
change identity, equality, serialization, mutation rules or which programs are
admitted.

## What a stamp says

A value is *escape-inert* when the scan (`mayNeedEscape`) answers "nothing to
do" for it under every guard and whether or not its holder is marked.

- A scalar, a string and every other value the scan does not look inside is
  inert, with these exceptions.
- A function is inert when it is not a scope binding (`weakable`) and either
  holds its scope strongly or has none. A binding can be promoted and weakened
  again, and a weak function needs its scope kept, so neither is inert.
- A type is inert unless it holds its scope only weakly. A bound message
  likewise.
- A callable view, pipeline, stream, task, channel, actor reference, actor
  context, actor step, reply target, environment, buffer and FFI callable are
  never inert. The scan answers "look at this" for most of them every time.
- A List, Map, Node, Set or HashMap is inert when everything it reaches is.

Every such container has an `inertEpoch` field. The process has one counter,
`escapeInertEpoch`. In a List, Map and Node the field shares a word with the
`shared` flag, which is half a word wide for that reason, so the stamp adds
nothing to the size of those objects.

**Invariant.** A container whose `inertEpoch` equals the counter is
escape-inert, and every container it reaches carries the same stamp or a
`FrozenNoWeakScope` proof.

While the invariant holds, skipping the scan of a stamped container gives the
result the scan would have given: it would have returned "nothing to do" and
changed nothing.

## How the invariant is kept

The scan stamps a container after it has walked that container's whole subtree
and met no leaf that is not inert. It counts such leaves as it goes and
compares the count before and after each subtree. A container reached a second
time without a stamp is either still being walked, which means a cycle, or was
found not inert. Either way it counts against whoever reached it. So a cyclic
graph is never stamped. It is scanned in full each time, as before.

Three events could break the invariant. Each one increments the counter
instead, which retires every stamp in the process at once.

1. **A store into a stamped container of a value that is not inert right
   now.** The test is constant time: a leaf by its kind, a container by its own
   stamp or proof. The store procedures in `types.nim` (`setListItem`,
   `pushListItem`, `putMapEntry`, `putMapEntryById`, `setNodeProp`,
   `setNodePropById`, `setNodeBody`, `pushNodeBody`, `pushCheckedNodeBody`,
   `setNodeBodyItem`, `setCheckedNodeBodyItem`) are the only way to write a container's contents from
   outside that module, because the container objects are private to it and
   are only lent out for reading. A store into a container with no current
   stamp needs nothing: by the invariant, no stamped container reaches it.
2. **A leaf that turns from inert to not inert.** Only a type does, when it
   drops its scope edge again (`weakenOwnedTypeEnvironment`).
3. **A pending module reference patched in place**, which can write a function
   into a container that already has a stamp.

The escape walk also writes containers in place, but only containers that hold
something it had to change, and those have no current stamp.

A store native scans the stored value before it stores it, so a container of
plain data is stamped by the time the store procedure tests it. A container
that was never scanned is not trusted: storing it into a stamped container
retires the stamps. Sets and hash maps cannot be changed after construction,
so they need no store procedure, only a stamp.

## Threads

The counter is read and incremented atomically, because containers cross
lanes. A container that has been published to another lane is never stamped,
since the scan would be writing to an object another thread can read. Without
a stamp it also counts against its holders, so nothing above it is stamped
either. A container stamped before it was published keeps its stamp, which is
only read from then on.

## Limits

- Stamps are 32 bits and the counter is 64. If the counter ever passes 2^32, no
  stamp matches again and every scan is a full scan, as before stamps.
- The worst case is the old cost plus one write per container: a program that
  keeps storing functions into data it has just returned retires the stamps
  each time.
- A cycle, a published container without a frozen proof, and data that holds a
  scope binding, a stream or a task are scanned in full each time.
- Two other whole-graph walks are not covered: the borrowed caller-environment
  check, which runs on stores once a program has used `fn!`, and the
  in-progress construction check. Deeply frozen plain data skips the first
  through its own proof (`docs/spec/frozen-graph-proofs.md`).

## Testing

`-d:geneInertStampVerify` keeps a copy of the scan as it was before stamps and
runs it wherever a stamp answered. The process exits with status 70 if the two
disagree. Running the test suites in that build is the check that no path
writes a container without going through the store procedures.

`-d:geneInertStampTests` exposes the counter and the number of scans a stamp
answered, for `tests/test_escape_inert.nim`. That file also puts a function, a
literal holding one, and a record of a local type into data after it was
stamped, by each store route, and then lets the data outlive the scope.

`benchmarks/boundaries.gene` times returns, accessors and stores by size.
