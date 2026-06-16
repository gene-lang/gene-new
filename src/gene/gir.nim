## Gene Intermediate Representation for the MVP bytecode VM.
##
## GIR is intentionally small here: stack bytecode plus nested compiled function
## prototypes. It is the handoff boundary between syntax compilation and runtime
## execution.

import std/strutils
import ./[printer, types]

type
  OpCode* = enum
    opPushConst
    opLoadName
    opDefineName
    opSetName
    opPop
    opMakeList
    opMakeMap
    opMakeSelector
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

  ParamDefault* = object
    optional*: bool
    defaultChunk*: Chunk

  NamedParam* = object
    arg*: string
    local*: string
    defaultValue*: ParamDefault

  FunctionProto* = ref object of FunctionCode
    name*: string
    params*: seq[string]
    paramDefaults*: seq[ParamDefault]
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

proc formatNames(names: openArray[string]): string =
  "[" & names.join(",") & "]"

proc formatInstruction(inst: Instruction): string =
  result = $inst.op
  case inst.op
  of opPushConst:
    result.add " const=" & $inst.intArg
  of opLoadName, opDefineName, opSetName:
    result.add " name=" & inst.name
  of opMakeList:
    result.add " count=" & $inst.intArg
    if inst.flag: result.add " immutable=true"
  of opMakeMap:
    result.add " count=" & $inst.intArg & " names=" & formatNames(inst.names)
    if inst.flag: result.add " immutable=true"
  of opMakeSelector:
    result.add " count=" & $inst.intArg
  of opMakeFn:
    result.add " fn=" & $inst.intArg
  of opCall:
    result.add " argc=" & $inst.intArg
    if inst.names.len > 0:
      result.add " names=" & formatNames(inst.names)
  of opJumpIfFalse, opJump:
    result.add " target=" & $inst.intArg
  of opPop, opReturn:
    discard

proc addDisassembly(lines: var seq[string], chunk: Chunk, indent = "") =
  lines.add indent & "constants:"
  if chunk.constants.len == 0:
    lines.add indent & "  <none>"
  else:
    for i, value in chunk.constants:
      lines.add indent & "  [" & $i & "] " & value.print()

  lines.add indent & "instructions:"
  if chunk.instructions.len == 0:
    lines.add indent & "  <none>"
  else:
    for i, inst in chunk.instructions:
      lines.add indent & "  " & $i & ": " & formatInstruction(inst)

  if chunk.functions.len > 0:
    lines.add indent & "functions:"
    for i, fn in chunk.functions:
      let label = if fn.name.len > 0: fn.name else: "<anon>"
      var header = indent & "  [" & $i & "] " & label &
        " params=" & formatNames(fn.params)
      if fn.restParam.len > 0:
        header.add " rest=" & fn.restParam
      if fn.namedParams.len > 0:
        var names: seq[string]
        for p in fn.namedParams:
          if p.local == p.arg:
            names.add p.arg
          else:
            names.add p.arg & ":" & p.local
        header.add " named=" & formatNames(names)
      lines.add header
      addDisassembly(lines, fn.chunk, indent & "    ")

proc disassemble*(chunk: Chunk): string =
  var lines: seq[string]
  addDisassembly(lines, chunk)
  lines.join("\n")
