## File-backed Gene REPL wrapper.
##
## The reusable session loop lives in vm.nim so the CLI and in-language
## `repl/run` native use the same declaration-persistent evaluation behavior.

import std/terminal
import ./[types, vm]

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
