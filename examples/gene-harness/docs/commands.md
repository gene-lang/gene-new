# Operator commands

Use `/help` for active slash-command usage or `/help run` for one command.
`(discover "topic" ^kind "commands")` returns usage, owner and doc references.
Model response code calls registered functions directly; commands belong to
operator input.

- `/run <Gene code>` evaluates Gene with session_id, workspace_root, discover,
  doc, plugin functions and the standard library. It records the result.
- `/sh <shell command>` runs a non-interactive process with streamed output.
- `/view <path>[:from-to]` reads a file or directory, up to 400 lines per page.
- `/repl` opens persistent evaluation if the repl plugin is active; load
  `harness/repl` for its state/import behavior.

`/run` is one evaluation; use the REPL for persistent local bindings. Commands
retain the submitting session and normal receipts/cancellation. Prefer Gene
APIs/tooling when available. Disabling core_commands removes its commands and
documentation; core cancellation controls remain available.
