## Hash index for the immutable general containers (`HashMap`, and `Set` for
## items that are not canonical immediates).
##
## A container keeps its items or entries in insertion order, which owns
## printing and iteration. The index sits beside that vector and answers "which
## positions might hold a key with this hash". It stores each position's hash
## and an open-addressing table of positions, so a lookup is one probe plus
## one `semanticEqual` per colliding candidate, whatever the container size.
##
## The index never calls Gene code. Hashing keys (which may run a user
## `ValueHash` witness) and comparing candidates stay with the caller, in
## `vm.nim`. Containers below `KeyIndexMin` keep no index and scan linearly,
## because probing costs more than comparing a handful of keys.
##
## An index is immutable once its container is published. `add` exists for
## builders, which grow one index while they deduplicate.

import std/hashes

type
  KeyIndex* = object
    hashes*: seq[Hash]   # one per position, in position order
    slots: seq[int32]    # open addressing; 0 is free, else position + 1
    refused*: bool       # a lazy build found keys it must not index; never retry

const KeyIndexMin* = 8
  ## Containers with fewer positions are scanned linearly.

const slotMixer = 0x9E3779B97F4A7C15'u64

proc slotStart(h: Hash, mask: int): int {.inline.} =
  # Witness hashes are often tiny integers, so spread them before masking. The
  # mixed word is masked while it is still unsigned: on wasm32 `int` is 32 bits
  # wide, and narrowing a word above 2^31 first raises a RangeDefect.
  let mixed = (cast[uint64](int64(h)) * slotMixer) shr 32
  int(uint32(mixed) and uint32(mask))

proc rebuildSlots(ix: var KeyIndex, size: int) =
  ix.slots.setLen(0)
  ix.slots.setLen(size)
  let mask = size - 1
  for position in 0 ..< ix.hashes.len:
    var pos = slotStart(ix.hashes[position], mask)
    while ix.slots[pos] != 0:
      pos = (pos + 1) and mask
    ix.slots[pos] = int32(position + 1)

proc add*(ix: var KeyIndex, h: Hash) =
  ## Append the hash of the next position.
  ix.hashes.add h
  if ix.hashes.len < KeyIndexMin:
    return
  # Keep the table at most half full.
  if ix.slots.len == 0:
    var size = 16
    while size < ix.hashes.len * 2: size = size shl 1
    rebuildSlots(ix, size)
  elif ix.hashes.len * 2 > ix.slots.len:
    rebuildSlots(ix, ix.slots.len * 2)
  else:
    let mask = ix.slots.len - 1
    var pos = slotStart(h, mask)
    while ix.slots[pos] != 0:
      pos = (pos + 1) and mask
    ix.slots[pos] = int32(ix.hashes.len)

proc covers*(ix: KeyIndex, count: int): bool {.inline.} =
  ## True when the index describes a container of `count` positions and is
  ## big enough to be worth probing.
  count >= KeyIndexMin and ix.hashes.len == count

iterator candidates*(ix: KeyIndex, h: Hash): int =
  ## Positions whose stored hash equals `h`, in no particular order. The
  ## caller still compares keys.
  if ix.slots.len == 0:
    for position in 0 ..< ix.hashes.len:
      if ix.hashes[position] == h:
        yield position
  else:
    let mask = ix.slots.len - 1
    var pos = slotStart(h, mask)
    while true:
      let slot = ix.slots[pos]
      if slot == 0: break
      if ix.hashes[slot - 1] == h:
        yield int(slot - 1)
      pos = (pos + 1) and mask
