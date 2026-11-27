## File-backed Gene REPL wrapper.
##
## The reusable session loop lives in vm.nim so the CLI and in-language
## `repl/run` native use the same declaration-persistent evaluation behavior.

import std/terminal
import ./[types, vm]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import ./repl_completion
  import ./ext/term/repl_editor

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
  var options = ReplOptions(interactive: interactive, prompt: prompt)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if interactive:
      let completion = proc(source: string, cursor: int): ReplCompletion =
        completeRepl(scope, source, cursor)
      let editor = newReplTerminal(input, output, errors, prompt, completion)
      if editor != nil:
        defer: editor.close()
        options.editDraft = proc(source: var string, continuation: bool): bool =
          editor.readDraft(source, continuation)
        options.finishDraft = proc() = editor.finishDraft()
        options.recordSubmission = proc(source: string) = editor.record(source)
        return runReplSession(scope, reader, writeOut, writeErr, options)
  runReplSession(scope, reader, writeOut, writeErr, options)
