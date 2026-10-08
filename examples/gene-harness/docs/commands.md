# Operator commands

Use `/help` for active slash-command usage or `/help run` for one command.
`(discover "topic" ^kind "commands")` returns usage, owner and doc references.
Model response code calls registered functions directly; commands belong to
operator input.

CLI operations connect to the running web host. Use `--session ID run CODE`,
`sh COMMAND`, `view PATH`, or `command /NAME ARGS`. They wait for the durable
command result unless `--no-wait` is given. `send TEXT` submits a literal model
prompt, including text beginning with `/`; `send --wait` also waits for its
round. Use `--file FILE` for complete multiline code or prompt text.

`sessions create --title TITLE` returns an id. `sessions` lists conversations;
there are no `/new` or `/sessions` slash commands. `receipt ID` and `wait ID`
address rounds; add `--command ID` for operator commands. `receipt --request-id
ID --kind command` resolves a retained command submission. Reusing a request
requires identical text and its original `--sequence N`. A lost response is
resolved through receipts rather than automatic execution retries.

For questions, use `answer --batch ID --answers JSON` or `dismiss --batch ID`.
Cancel with `cancel --round ID` or `cancel --command ID`. Exiting or interrupting
a client never cancels the host's work. `stop` and `restart` act on the host;
other running sessions require `--confirm`.

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
