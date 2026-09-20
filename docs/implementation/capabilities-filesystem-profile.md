# Initial filesystem capability profile

The initial native profile targets POSIX directory-descriptor operations on
macOS and Linux. Other backends reject native filesystem authority until they
implement an equivalent profile. This implements the operation table in proposal
section 11; it does not interpret a directory selector as a string prefix.

## Names and root initialization

Policy roots normalize lexically against the captured source base, without
filesystem inspection. Operation-relative paths use the provider's captured
launch directory. A root's logical absolute spelling remains fixed.

Only host grant initialization opens an existing root and retains its descriptor.
The acquisition walk opens each component without following symlinks. Root
aliases are rejected too: on macOS use /private/tmp rather than the /tmp symlink.
This prevents a selected root from following a link beyond an administrator's
tree restriction during initialization.
Subsequent operations start from that retained descriptor. Before admission or
a new operation, verify that each contributing root still names the retained inode
through a no-follow walk. Moving/replacing a binding removes that root's available
portion; other roots and independent grants remain available. Restoring the same
inode may restore availability, but never undo explicit revocation. A binding
change never retargets the grant to a replacement directory. Alternate external
spellings are not implicitly added to a policy. Resource validity checks remain
live and cannot be replaced by a registry-revocation epoch alone.

Only a proved missing, non-directory, symlinked, or replaced binding removes a
root's available portion. Inspection failures preserve their native error code
and cause: path-local failures such as denied metadata access are entry failures;
invalid owned descriptors and process/system descriptor or memory exhaustion are
shared failures. They are not ordinary missing authority. A grouped entry whose
root inspection fails cannot establish availability; an independently allowing
entry can still satisfy an entry-local failure. Resolution itself revalidates
each candidate root so a live broader root never revives a displaced narrower
anchor in the same grant.

Each independent grant owns its root handles and revocation lineage. Live
handles are never evicted and reopened by name. Exceeding the root-handle limit
fails initialization, and partial acquisition is rolled back before publishing
the grant.

## Resolution and effect binding

1. Derive the actual operation and all resource demands from its arguments.
   Writes include the target and containing directory; rename includes both
   source/destination entries and parents in one complete-entry demand.
2. Check policy selection, then resolve through an eligible root descriptor,
   opening intermediate directories with no-follow semantics.
3. Keep the resulting parent/directory descriptors in private prepared state.
   Every applicable live root row must authorize the same resolved parents,
   verified by device/inode identity; bounds still apply their full predicates.
4. Recheck live authorization with that prepared state immediately before work.
   Perform the operation using those exact held descriptors and leaf names.
   Never reopen an unchecked absolute path after the guard.
5. Invalidate prepared state and close its temporary descriptors on every exit.

Regular-file data handles use no-follow/nonblocking acquisition and are checked
as regular files before data transfer or truncation. Symlink traversal is
rejected. Deletion/rename operate on directory entries without following their
targets. Copy is a guarded read followed by guarded write, with both demands
preflighted; it does not promise transactional rollback.

Release-only cleanup closes descriptors without flushing application data.
Permissions/ownership changes, links, special files, mappings and file locks
remain unsupported under this profile until separately specified.

The initial application adapter surface is synchronous. `fs/read_text_async`
and `fs/write_text_async` reject normalized execution until their worker-context
transfer and operation-start revalidation profile is completed. They cannot use
the legacy asynchronous adapter as a fallback. This restriction is recorded in
the native effect inventory and remains migration work.

## Retained resources and verification

A retained data handle must keep its origin context, mode, and resource identity.
Later use intersects the current context and revalidates the retained resource;
closing remains possible after revocation. Renaming/replacing its original
binding cannot silently authorize a different inode.

The native handle is opaque and unbuffered. Before each data-transfer chunk or
explicit synchronization, recheck the current/origin intersection, the open
mode, the held file's device/inode, and its original no-follow directory-entry
binding. Removing, moving, or replacing that binding makes later uses fail;
the provider does not discover a new name or reopen the file. Restoring the same
binding can restore availability but cannot undo revocation. The final guarded
identity observation is that chunk's start point; a concurrent change after it
does not retarget the held descriptor. Close and final release only close owned
descriptors and never flush buffered application data.

## Atomic replacement

Atomic writes stage an exclusively created regular file in the target's parent
directory, write through a guarded retained handle, synchronize it, and publish
with a separately guarded same-directory rename. The rename demand includes
both entries and their parents in one complete permitting entry in every row.
The held parent must still be the resolution authorized by every live root.
No destination mutation occurs when staging or publication is denied.
Staging files are created with mode 0600. Publication is followed by an internal
`sync_directory` operation requiring `fs/Write` for that directory. A failure
after publication can therefore leave the complete replacement in place while
reporting that durability could not be established.

Publication is an atomic namespace replacement, not a transaction over other
writers. Concurrent directory-entry changes can cause failure or ordinary rename
races within the authorized directory; they cannot redirect traversal through
a symlink or switch the held parent. The staged file's binding is checked before
publication, and a known replacement is rejected.

Aborting always closes the staged descriptor. Unlinking the staging entry is an
ordinary guarded write, not a release-only privilege: it requires the current
and origin authority and the retained parent/binding checks. If revocation,
replacement, or an I/O failure prevents that cleanup, the temporary entry may
remain for separately authorized cleanup. Failure does not imply rollback of
already-written staging data. No cleanup path recovers an older grant or writes
buffered contents after revocation.

The low-level staged-write interface is host-only and supports testing live
changes between staging and publication. Application `fs/write_text_atomic`
uses the same stages internally. The legacy raw-`File` interface is not admitted
for normalized execution; application logging remains subject to its separately
adopted effect contract.

Required tests cover path-prefix confusion, symlink races/traversal, root
replacement after initialization, complete rename demands, independent
revocation, current/origin intersections, forbidden writes before mutation,
partial initialization cleanup, and release after revocation.
