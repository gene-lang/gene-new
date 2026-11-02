## Walks the data graph of a Value: the containers that printing, equality and
## freezing recurse through. Opaque runtime values (cells, functions, tasks) are
## leaves, because those operations do not enter them.

import std/sets
import ./types

const graphContainerKinds* = {vkList, vkMap, vkSet, vkHashMap, vkNode, vkPipeline}

proc graphChildren(v: Value): seq[Value] =
  case v.kind
  of vkList:
    for item in v.listItems: result.add item
  of vkMap:
    for item in v.mapEntries.values: result.add item
  of vkSet:
    for item in v.setItems: result.add item
  of vkHashMap:
    for entry in v.hashMapEntries:
      result.add entry.key
      result.add entry.val
  of vkNode:
    result.add v.head
    for item in v.props.values: result.add item
    for item in v.meta.values: result.add item
    for item in v.body: result.add item
  of vkPipeline:
    result.add v.pipelineInitial
    for stage in v.pipelineStages:
      result.add stage.head
      for item in stage.props.values: result.add item
      for item in stage.body: result.add item
  else:
    discard

proc valueHasCycle*(root: Value): bool =
  ## Iterative, so a very deep value cannot overflow the native stack here.
  if root.isNil or root.kind notin graphContainerKinds:
    return false
  type Frame = object
    bits: uint64
    children: seq[Value]
    next: int
  var onPath = initHashSet[uint64]()
  var finished = initHashSet[uint64]()
  var stack = @[Frame(bits: root.bits, children: graphChildren(root))]
  onPath.incl root.bits
  while stack.len > 0:
    let top = stack.high
    if stack[top].next >= stack[top].children.len:
      onPath.excl stack[top].bits
      finished.incl stack[top].bits
      stack.setLen(top)
      continue
    let child = stack[top].children[stack[top].next]
    inc stack[top].next
    if child.isNil or child.kind notin graphContainerKinds:
      continue
    if onPath.contains(child.bits):
      return true
    if finished.contains(child.bits):
      continue
    onPath.incl child.bits
    stack.add Frame(bits: child.bits, children: graphChildren(child))
  false
