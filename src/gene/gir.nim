## Gene Intermediate Representation for the MVP bytecode VM.
##
## GIR is intentionally small here: stack bytecode plus nested compiled function
## prototypes. It is the handoff boundary between syntax compilation and runtime
## execution.

import ./types

type
  OpCode* = enum
    opPushConst
    opLoadName
    opDefineName
    opSetName
    opPop
    opMakeList
    opMakeMap
    opMakeFn
    opCall
    opJumpIfFalse
    opJump
    opReturn

  Instruction* = object
    op*: OpCode
    intArg*: int
    name*: string
    names*: seq[string]
    flag*: bool

  NamedParam* = object
    arg*: string
    local*: string

  FunctionProto* = ref object of FunctionCode
    name*: string
    params*: seq[string]
    restParam*: string
    namedParams*: seq[NamedParam]
    chunk*: Chunk

  Chunk* = ref object
    constants*: seq[Value]
    instructions*: seq[Instruction]
    functions*: seq[FunctionProto]

proc newChunk*(): Chunk =
  Chunk(constants: @[], instructions: @[], functions: @[])

proc addConst*(chunk: Chunk, value: Value): int =
  result = chunk.constants.len
  chunk.constants.add value

proc addFunction*(chunk: Chunk, fn: FunctionProto): int =
  result = chunk.functions.len
  chunk.functions.add fn

proc emit*(chunk: Chunk, inst: Instruction): int =
  result = chunk.instructions.len
  chunk.instructions.add inst

proc patchJump*(chunk: Chunk, at, target: int) =
  chunk.instructions[at].intArg = target
