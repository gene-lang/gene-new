## Reusable Gene REPL loop.
##
## The CLI uses `runRepl`, while embedders can call `runReplSession` with
## custom read/write callbacks to drive a REPL from tests, a socket, or another
## host process.

import std/[terminal, strutils]
import ./[compiler, printer, reader, types, vm]

type
  ReplReadLine* = proc(line: var string): bool {.closure.}
  ReplWrite* = proc(text: string) {.closure.}
  ReplOptions* = object
    interactive*: bool
    prompt*: string

proc defaultReplOptions*(interactive = false): ReplOptions =
  ReplOptions(interactive: interactive, prompt: "gene> ")

proc runReplSession*(scope: Scope,
                     readLine: ReplReadLine,
                     writeOut: ReplWrite,
                     writeErr: ReplWrite,
                     options = defaultReplOptions()): int =
  ## Run a REPL against an existing scope. Returns 0 for a normal exit and 1
  ## when a panic aborts the session. Recoverable Gene/read errors are printed
  ## and the session continues.
  var line: string
  if options.interactive:
    writeOut(options.prompt)
  while readLine(line):
    let trimmed = line.strip()
    if trimmed.len == 0:
      if options.interactive:
        writeOut(options.prompt)
      continue
    if trimmed in [":quit", ":exit", "quit", "exit"]:
      return 0
    try:
      writeOut(run(compileEvalSource(line, useLocalSlots = false), scope).print() & "\n")
    except ReadError as e:
      writeErr("Read error: " & e.msg & "\n")
    except GenePanic as e:
      writeErr("Panic: " & e.msg & "\n")
      return 1
    except GeneError as e:
      writeErr("Error: " & e.msg & "\n")
    if options.interactive:
      writeOut(options.prompt)
  0

proc runRepl*(scope: Scope,
              input: File = stdin,
              output: File = stdout,
              errors: File = stderr,
              interactive = isatty(input),
              prompt = "gene> "): int =
  ## File-backed REPL wrapper used by the CLI.
  let reader = proc(line: var string): bool =
    input.readLine(line)
  let writeOut = proc(text: string) =
    output.write(text)
    output.flushFile()
  let writeErr = proc(text: string) =
    errors.write(text)
    errors.flushFile()
  runReplSession(scope, reader, writeOut, writeErr,
                 ReplOptions(interactive: interactive, prompt: prompt))
