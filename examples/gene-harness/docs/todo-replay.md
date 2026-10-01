# Replay the todo-app harness experiment

From the repository root, launch the web harness with your host Codex OAuth
login, model `gpt-6.1-sol`, and high reasoning. Use a current checkout and build
the binaries with `nimble build` if needed.

The original run used workspace `tmp/harness-todo`, harness port 8095, and app
port 8096. A replay uses `tmp/harness-todo-replay`, harness port 8097, app port
8098, and issue log `tmp/harness-todo-replay-issues.md`. Both the replay
workspace **and its issue log** should be unused. If either exists, choose a
new suffix and update the launch command and task prompt together. Keep old
results for comparison.

Check before launch:

```sh
bin/gene eval '($assert (! ($fs/exists? "tmp/harness-todo-replay")) "Choose an unused workspace") ($assert (! ($fs/exists? "tmp/harness-todo-replay-issues.md")) "Choose an unused issue-log path")'
```

The original run led to commit `3c0015b`: nested result headers no longer leak
reader metadata, copied ELIDED attachments are rejected before writes, and
patch results coexist with prompt/error items. Later changes added preferred
zero-argument sends and displayed final replies once outside turn disclosures.
The replay at `c279192` completed after 38 session turns, with one continuation,
10 passing app tests, and passing HTTP/restart and browser checks. Its findings
led to better context retention, diagnostics, visible turn budgets and UI fixes.
The original app completed in 33 turns with 4 tests. These are observations,
not expected turn counts or a fixed generated layout.

## Launch and connect

```sh
GENE_BINARY="$PWD/bin/gene" \
PATH="$PWD/bin:$PATH" \
CODEX_AUTH_FILE="$HOME/.codex/auth.json" \
GENE_HARNESS_PROVIDER=codex \
GENE_HARNESS_MODEL=gpt-6.1-sol \
GENE_HARNESS_THINKING_EFFORT=high \
examples/gene-harness/bin/gene-harness web \
  --workspace "$PWD/tmp/harness-todo-replay" --port 8097
```

Keep the terminal running. The provider reads `tokens.access_token` and
`tokens.account_id` from the host OAuth file; credentials stay out of the
workspace and model context. Set `CODEX_AUTH_FILE` to a different path if your
login is stored elsewhere. If credentials are missing or rejected, sign in
through Codex with file credential storage and retry.

Open the actual `http://127.0.0.1:8097/#token=...` link printed by this process.
Its one-use token expires after ten minutes and establishes an eight-hour
browser cookie that survives restarts. The header and Workspace status should
show `gpt-6.1-sol · codex · high`.

The Gene supervisor launcher supports automatic `/restart`. A server launched
directly with `gene run` must be started again manually. Only one harness can
own a workspace. Choose another port if 8097 is occupied.

## Send the task

Paste this into the composer with placeholder **Ask a question or describe a
task…**, then click **Send**. Change the issue-log filename and app port if you
chose a different replay suffix or ports.

```text
Create a complete, polished todo web app in workspace_root. Use Gene for the backend, persistence, tests, and project tooling; HTML/CSS/JavaScript is fine in the browser. Bind to 127.0.0.1:8098.

Implement add, edit, complete/uncomplete, delete, All/Active/Completed filters, remaining count, and clear completed. Persist tasks across reloads and server restarts. Use a calm, responsive design, accessible labels, and keyboard controls. Provide README.md with exact launch/test commands and a small Gene build/test/serve launcher.

Read the repository's AGENTS.md, two directories above this workspace. Preserve Gene syntax and semantics. Probe uncertain APIs and consult (doc "gene/stdlib"). Imports require a source file run with gene run, not gene eval. Prefer Gene over Python or shell for project tooling. Use workspace-relative paths in patch blocks. Never copy ELIDED history stubs into source; recall original bodies or provide full new contents. Do not read credential files or copy secrets.

Record issues as encountered in ../harness-todo-replay-issues.md, preserving earlier findings. Fix minor issues; record larger language issues for review. Use reasonable defaults without optional design questions. Run meaningful Gene tests and an HTTP smoke test with restart persistence and isolated disposable storage. Stop smoke-test servers before finishing. Finish with results and exact launch instructions.
```

Expand **Turn** disclosures for code, patches, errors and next requests.
Console output has its own pane. Wait for **Completed** and the final reply
before starting the generated server, so it does not compete with a smoke test.

## Continue and recover

User rounds default to **24 turns**, trigger rounds to 12. The model receives
the current round's remaining budget with each request. A new message in the
same conversation starts a fresh user-round budget while retaining files and
history. For example:

```text
Continue and finish the existing todo app. Inspect current files, fix the error below, run tests, align frontend IDs/selectors/styles, and finish README plus Gene build/test/serve tooling. Avoid broad documentation exploration. Preserve issue-log entries and use workspace-relative patch paths. Keep port 8098. Finish with passing results and exact launch commands.

Current error:
[paste the relevant error and test output]
```

To raise the budget, edit `turn_limit` in the workspace's
`.gene-harness/config.gene` between rounds. For example, from the repository
root in a second terminal:

```sh
bin/gene eval '(let path "tmp/harness-todo-replay/.gene-harness/config.gene") (let config ($serde/read_data ($fs/read_text path))) (config .put "turn_limit" 48) ($fs/write_text_atomic path ($serde/write_data config))'
```

The next round reads the new value. HTTP providers default to 600 seconds per
attempt, with one retry on timeout. Set `provider_timeout_ms` in the same
config file to change this independently of turn and evaluation limits.
The older 180-second timeout appeared as `net/http_client: Timeout was reached`.
Current failures identify the provider and configured duration, for example
`codex model provider request exceeded 600.0 s (2 attempts)`, with continuation
and configuration guidance. Only a completed response reaches evaluation.

| Composer command | Effect |
| --- | --- |
| `/cancel` | Cancel the selected session's running round or pending questions. |
| `/view model.gene` | Inspect a generated file; substitute its actual filename. |
| `/restart` | Restart the supervised harness after source changes. |
| `/stop` | Stop the workspace process. |

Do not launch a second harness in the same workspace. After restarting, use
the recovered conversation. If the browser cookie expires, open a fresh
connection link printed by the server.

## Verify the generated app

Follow its README using the repository's `bin/gene`. **Use the actual generated
filenames**: the original app had `project.gene` and SQLite, while the replay
had `tool.gene` and JSON. Run its build, tests, and smoke test with port 8098
free. Check whether the smoke test isolates storage before running it against
data you want to keep. Then run the README's serve command and open
`http://127.0.0.1:8098/`.

1. Add tasks with Enter and the Add button.
2. Edit a title, save with Enter, and cancel an edit with Escape.
3. Complete/uncomplete tasks and check the remaining count and all filters.
4. Delete a disposable task and clear completed tasks; check confirmations if
   the app asks for them.
5. Reload, then stop/relaunch the server and verify persistence.
6. Check a narrow window, keyboard-only use, and browser console errors.

For the original **31-test harness selection**, run from `examples/gene-harness`:

```sh
../../bin/gene test tests/outcome_spec.gene tests/response_spec.gene tests/provider_blocks_spec.gene tests/turn_eval_spec.gene tests/turn_loop_spec.gene tests/patch_transcript_spec.gene
```

The test count grows with newer checkouts. Run `../../bin/gene test` there for
the full suite. Stop the app with Ctrl+C and the harness with `/stop`. Keep the
workspace, `.gene-harness/`, issue log, and whatever persistence file the app
actually generated if you want to resume or retain its tasks.
