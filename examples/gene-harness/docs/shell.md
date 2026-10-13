# Shell commands and mode

The built-in `shell` plugin supplies `/sh` and the `sh` input mode. The default
profile loads it alongside `core_commands` and `repl`. Use
`(discover "shell" ^kind "commands")` or `(doc "harness/shell")` for guidance.

`/sh <command>` runs once in the workspace, streams stdout and stderr, and
reports the exit status. It uses the configured `SHELL` environment value,
falling back to `/bin/sh`. Its result attaches to the next user-initiated model
request, matching `/run` and `/view`.

## Shell mode

Bare `/sh` opens a session-specific Shell mode. Enter commands directly;
`exit`, `quit`, `:exit`, `:quit`, or the browser's Leave Shell control returns
to chat. Its non-interactive `/bin/sh` process starts in the workspace and
preserves cwd, variables, exports and functions across inputs. The browser
shows a Run button while idle and Stop while executing.

Commands receive empty stdin and have no terminal emulation. Shell-mode
activity belongs to the operator transcript and does not attach to model
history. Inputs use ordinary command receipts and stable input identities;
repeating the same admitted input id retrieves its receipt without executing
the command again. Retained output is capped at 1 MiB and supports recall.

Stop or an input deadline resets the shell process. A command that exits the
shell also resets it; the next input starts a fresh process. Ordinary nonzero
command exit statuses preserve shell state. The host owns admission,
cancellation and the cleanup backstop for `reset_on_interrupt`.

## Plugin lifecycle

The plugin owns transient shell resources in activation memory. Leaving,
session removal, viewer-grace expiry, plugin disable or replacement, and host
shutdown close them. State is not restored after restarting the host.

Use the Harness CLI's `disable shell`, `enable shell`, and `restore shell`
operations to manage this built-in plugin. Disabling `shell` removes `/sh`,
its input mode, and this documentation chapter, and closes running modes.
`core_commands` continues to supply `/help`, `/run` and `/view`. Disabling
`core_commands` leaves shell support available. Replacing `shell` closes old
mode instances; subsequent entries use the replacement's resources.
