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
    opMakeNamespace
    opImport
    opCall
    opMatchBind       # pop target, destructure against a pattern (or MatchError)
    opTryMatch        # peek target, try a pattern, push bool
    opMatchFail       # raise MatchError (match with no matching clause)
    opForEach         # pop a collection, run a for-loop body per item
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

  ImportSelection* = object
    name*: string         # exported name in the source
    local*: string        # local name to bind (== name unless aliased)

  ImportSpec* = object
    fromModule*: bool                 # true: `from "path"`; false: namespace path
    modulePath*: string               # the `from "path"` string
    nsSegments*: seq[string]          # namespace-path segments (e.g. std/stream)
    alias*: string                    # `^as alias`, or ""
    selections*: seq[ImportSelection]

  ForProto* = ref object
    pattern*: Value              # loop-variable pattern
    body*: Chunk                 # loop body

  Chunk* = ref object
    constants*: seq[Value]
    instructions*: seq[Instruction]
    functions*: seq[FunctionProto]
    subchunks*: seq[Chunk]       # bodies of `ns` declarations
    imports*: seq[ImportSpec]
    forLoops*: seq[ForProto]

proc newChunk*(): Chunk =
  Chunk(constants: @[], instructions: @[], functions: @[], subchunks: @[],
        imports: @[], forLoops: @[])

proc addForLoop*(chunk: Chunk, fp: ForProto): int =
  result = chunk.forLoops.len
  chunk.forLoops.add fp

proc addSubchunk*(chunk: Chunk, body: Chunk): int =
  result = chunk.subchunks.len
  chunk.subchunks.add body

proc addImport*(chunk: Chunk, spec: ImportSpec): int =
  result = chunk.imports.len
  chunk.imports.add spec

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
  of opMakeNamespace:
    result.add " ns=" & $inst.intArg & " name=" & inst.name
  of opImport:
    result.add " import=" & $inst.intArg
  of opCall:
    result.add " argc=" & $inst.intArg
    if inst.names.len > 0:
      result.add " names=" & formatNames(inst.names)
  of opMatchBind, opTryMatch:
    result.add " pattern=" & $inst.intArg
  of opForEach:
    result.add " for=" & $inst.intArg
  of opJumpIfFalse, opJump:
    result.add " target=" & $inst.intArg
  of opPop, opReturn, opMatchFail:
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

  if chunk.subchunks.len > 0:
    lines.add indent & "namespaces:"
    for i, sub in chunk.subchunks:
      lines.add indent & "  [" & $i & "]"
      addDisassembly(lines, sub, indent & "    ")

  if chunk.forLoops.len > 0:
    lines.add indent & "for-loops:"
    for i, fp in chunk.forLoops:
      lines.add indent & "  [" & $i & "] pattern=" & fp.pattern.print()
      addDisassembly(lines, fp.body, indent & "    ")

  if chunk.imports.len > 0:
    lines.add indent & "imports:"
    for i, spec in chunk.imports:
      var src =
        if spec.fromModule: "\"" & spec.modulePath & "\""
        else: spec.nsSegments.join("/")
      var desc = indent & "  [" & $i & "] " & src
      if spec.alias.len > 0:
        desc.add " as=" & spec.alias
      if spec.selections.len > 0:
        var sels: seq[string]
        for s in spec.selections:
          sels.add (if s.name == s.local: s.name else: s.name & ":" & s.local)
        desc.add " " & formatNames(sels)
      lines.add desc

proc disassemble*(chunk: Chunk): string =
  var lines: seq[string]
  addDisassembly(lines, chunk)
  lines.join("\n")
