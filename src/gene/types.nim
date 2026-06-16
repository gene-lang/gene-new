## Canonical value / node model for Gene (design Section 1).
##
## Gene has one syntactic and semantic unit: the node. Every value exposes
## head / props / body / meta through the Node projection. Scalars are node
## fixpoints (head = self, empty props/body/meta).

import std/[tables, unicode]

type
  ValueKind* = enum
    vkNil       ## explicit absence (`nil` : Nil)
    vkVoid      ## no-value / skip / delete (`void` : Void)
    vkBool
    vkInt       ## MVP: 64-bit; design Int is arbitrary precision
    vkFloat     ## F64 (design `Float` alias)
    vkString    ## immutable UTF-8 string
    vkChar      ## one Unicode scalar value
    vkSymbol    ## interned simple symbol (Sym)
    vkList      ## pure body / list
    vkMap       ## pure props / PropMap (symbol-keyed)
    vkNode      ## general node (head + props + body + meta)

  ## Props and meta are symbol-keyed ordered maps. Keys are the bare symbol
  ## text (without the leading `^`/`@`). Order is preserved for deterministic
  ## printing per design Section 18.
  PropTable* = OrderedTable[string, Value]

  Value* = ref ValueObj
  ValueObj* = object
    case kind*: ValueKind
    of vkNil, vkVoid: discard
    of vkBool:   boolVal*:  bool
    of vkInt:    intVal*:   int64
    of vkFloat:  floatVal*: float64
    of vkString: strVal*:   string
    of vkChar:   charVal*:  Rune
    of vkSymbol: symVal*:   string
    of vkList:
      listItems*:     seq[Value]
      listImmutable*: bool
    of vkMap:
      mapEntries*:    PropTable
      mapImmutable*:  bool
    of vkNode:
      head*:          Value
      props*:         PropTable
      body*:          seq[Value]
      meta*:          PropTable
      nodeImmutable*: bool

# ---------------------------------------------------------------------------
# Singletons
# ---------------------------------------------------------------------------

let
  NIL*  = Value(kind: vkNil)
  VOID* = Value(kind: vkVoid)
  TRUE*  = Value(kind: vkBool, boolVal: true)
  FALSE* = Value(kind: vkBool, boolVal: false)

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newInt*(v: int64): Value = Value(kind: vkInt, intVal: v)
proc newFloat*(v: float64): Value = Value(kind: vkFloat, floatVal: v)
proc newStr*(v: string): Value = Value(kind: vkString, strVal: v)
proc newChar*(r: Rune): Value = Value(kind: vkChar, charVal: r)
proc newSym*(v: string): Value = Value(kind: vkSymbol, symVal: v)
proc newBool*(v: bool): Value = (if v: TRUE else: FALSE)

proc newList*(items: seq[Value] = @[], immutable = false): Value =
  Value(kind: vkList, listItems: items, listImmutable: immutable)

proc newMap*(entries: PropTable = initOrderedTable[string, Value](),
             immutable = false): Value =
  Value(kind: vkMap, mapEntries: entries, mapImmutable: immutable)

proc newNode*(head: Value,
              props: PropTable = initOrderedTable[string, Value](),
              body: seq[Value] = @[],
              meta: PropTable = initOrderedTable[string, Value](),
              immutable = false): Value =
  Value(kind: vkNode, head: head,
        props: props, body: body, meta: meta,
        nodeImmutable: immutable)

# ---------------------------------------------------------------------------
# Node projections (design Section 1.2 / 1.3). Scalars are fixpoints.
# ---------------------------------------------------------------------------

proc headOf*(v: Value): Value =
  if v.kind == vkNode: v.head else: v

proc propsOf*(v: Value): PropTable =
  case v.kind
  of vkNode: v.props
  of vkMap:  v.mapEntries
  else:      initOrderedTable[string, Value]()

proc bodyOf*(v: Value): seq[Value] =
  case v.kind
  of vkNode: v.body
  of vkList: v.listItems
  else:      @[]

proc metaOf*(v: Value): PropTable =
  if v.kind == vkNode: v.meta
  else: initOrderedTable[string, Value]()

# ---------------------------------------------------------------------------
# Truthiness (design Section 1.6): false, nil, void are falsy.
# ---------------------------------------------------------------------------

proc isTruthy*(v: Value): bool =
  case v.kind
  of vkNil, vkVoid: false
  of vkBool: v.boolVal
  else: true

proc isImmutable*(v: Value): bool =
  case v.kind
  of vkList: v.listImmutable
  of vkMap:  v.mapImmutable
  of vkNode: v.nodeImmutable
  else: false
