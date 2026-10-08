# Persistent Gene REPL

Enter in the browser with `/repl`. Input remains in a session-specific Gene environment until
exit/quit (also :exit/:quit) or the host Leave control. Multiline incomplete
syntax waits for more input. Empty input is ignored.

The workspace directory is cwd. Imports are supported, subject to normal package
boundaries. The environment exposes session_id, workspace_root, discover, doc,
the standard library and active plugin functions. Discover and doc read the
composition leased for the current input.

Local definitions persist. Saved plugin-function forwarders resolve the current
activation on each input; replacement can add new names while user shadowing is
preserved. A removed function fails when called. Durable data still belongs to
PluginHost state, not local REPL variables.

The REPL does not send each input to the model; its results belong to the operator
transcript. `/run` is useful for one-shot evaluation. Leave closes native resources;
mode cleanup also runs when the session/plugin/viewer lifecycle ends.

The CLI has no interactive REPL loop. Use `--session ID run CODE` or `run --file
FILE` for independent evaluations against the running host. Its wait and cancel
operations use the same durable command receipts as the browser.
