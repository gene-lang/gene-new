# Workspace manager

Status: MVP implemented and verified (2026-10-17). Single-root layout
implemented 2026-10-23. Forced termination of unresponsive hosts is deferred;
see the end of the first milestone checks.

The manager is a Harness workspace for creating, opening and managing other
Gene Harness workspaces. Its directory is the **manager root**,
`$HOME/.gene-harness-root` by default, and every managed workspace is a child
directory of `ROOT/workspaces`. A manager plugin supplies its UI and functions,
so the user can manage workspaces from a plugin view or by asking the model in
a conversation. Each managed workspace keeps its own port, sessions and
plugins. The manager gives one place to find and control them, including
workspaces whose normal host cannot start.

## Launch

```text
gene-harness manager
gene-harness manager --port 8081
gene-harness manager --root ~/work/harness
```

`manager` starts the Harness host for the manager root, creating it on first
run. The root is `--root DIR`, then a non-empty `GENE_HARNESS_ROOT`, then
`$HOME/.gene-harness-root`; a relative path uses the launch directory. The
command runs under the existing per-workspace launcher, as `web` does, so
host-requested restarts and the recovery fallback work as they do for any
workspace. The root does not depend on `GENE_HARNESS_WORKSPACE`. This command
rejects `--workspace`, and other commands reject `--root`.

A chosen root can be a new or existing directory, but not an ordinary Harness
workspace. The manager refuses a directory with a `.gene-harness/config.gene`,
or with a `workspace.gene` that lacks the manager role, rather than converting
it.

On first run the manager workspace's configured port is **8080**, bound to
`127.0.0.1`. `--port` overrides it for one invocation. The manager command
ignores `GENE_HARNESS_PORT`. A fixed configured port must bind: if 8080 is
occupied, report the conflict and let the user choose another port. Do not
silently move the manager to a random port.

The manager root's `workspace.gene` records `^role "manager"`. Any launch of
that directory uses the manager profile, so `web --workspace
$HOME/.gene-harness-root` behaves like `manager`. The existing `web` command
and its default behavior remain available for starting other workspaces
directly. Startup prints a ready-to-open browser link using the existing
terminal-output convention.

## Manager workspace

The manager runs the `manager` profile: the baseline profile's plugins plus a
host plugin, `workspace_manager`. As a profile plugin it receives the Harness
itself, so it can use host services such as the detached launch below and
other workspaces' control endpoints. Users and the model can extend the manager
with ordinary plugins, such as extra views or reports. The normal plugin
manager and recovery interface apply to it.

`workspace_manager` contributes:

- **A `workspaces` view.** It is a `web_components` row with `slot: view`, and
  the manager workspace's default full-screen view. Classic Harness, the
  conversation, stays available through the View picker, docked beside it or
  alone. See [workspace views](workspace-views.md).
- **Functions for the model.** `workspace_list`, `workspace_inspect`,
  `workspace_create`, `workspace_start`, `workspace_stop`,
  `workspace_restart`, `workspace_set_port`, `workspace_rename`,
  `workspace_archive` and `workspace_restore`. A workspace's name is its ID.
- **A docs row** describing the operations and the rules below.

The view and the functions share one implementation, so the two paths cannot
drift apart. Which operations go where:

- **Delete permanently is a view action only.** Its confirmation names the
  workspace and its directory. No function deletes a workspace
  directory. Model code can still reach `$fs`, as in every workspace, so this
  rule is about confirming the user's intent, not a security boundary.
- **Stopping active work needs the user.** Functions never confirm
  interruption of active work. When a stop or restart needs confirmation, the
  function returns that requirement, and the user confirms it in the view.
- **View actions stay out of conversations.** They are recorded in the
  workspace action log, following the existing workspace-view rule.

Function results and view state never contain workspace links, tokens, CLI
cookies or other credentials. Conversation content goes to the model provider.
Open is a view action that sends the browser to the workspace's authenticated
link; only the manager backend reads that link.

The view and its actions work without a configured model provider. Readiness
is reported as status and does not block the host
(`src/runtime/bootstrap.gene:143`). Only conversations need a provider, which
the manager workspace configures in its own settings like any workspace.

The list of workspaces is the `ROOT/workspaces` directory itself, so it is
independent of plugin activation and survives replacement of
`workspace_manager` and use of the recovery interface. The manager's own state
lives in `ROOT/.gene-harness` and can never be addressed as a workspace.
Managed workspaces
run in detached launchers, so stopping, restarting or breaking the manager
leaves them running. If `workspace_manager` is replaced badly or fails to
activate, the manager workspace uses its normal recovery interface, where
`restore workspace_manager`, or Restore default in the plugin manager, brings
back the built-in profile plugin.

## Workspace information and persistence

| Information | Source of truth |
| --- | --- |
| Name | The workspace's directory name under `ROOT/workspaces`; also its ID. |
| Configured port | Saved inside the workspace; a fixed port or automatic selection. |
| Actual port and endpoint | The running host's existing connection descriptor. |
| Status | Observed from the host and process state; never trusted from a saved running flag. |

The directory layout is the registry:

```text
$HOME/.gene-harness-root/       the manager root (--root or GENE_HARNESS_ROOT)
  .gene-harness/                the manager's own Harness state; its
                                workspace.gene has ^role "manager" and port 8080
  workspaces/
    todo-app/                   a managed workspace named todo-app
      .gene-harness/
        workspace.gene          configured port
        web_port                existing last successfully selected port
        connection              existing live host descriptor
        link                    existing authenticated browser URL
        bootstrap.log           early launcher output; replaced on each launch
        host.log                bounded host and launcher diagnostics
        host.log.1              previous log segment
  archive/
    old-demo/                   an archived workspace, restorable by name
```

Example workspace metadata, stored as inert Gene data:

```gene
{^version 1 ^port 8091}
```

Use `port: 0` for automatic selection. A fixed port must be in the existing
supported range, 1024–65535. The manager reads the configured port from the
workspace instead of maintaining another authoritative copy. Settings written
before this layout may contain an `alias`; it is accepted and dropped on the
next write.

A new name (Create, Rename) is 1–64 letters, digits, dots, hyphens or
underscores, starting with a letter or digit. Names are unique because they are
directory names. Every real directory directly under `ROOT/workspaces` is
listed, including one copied or cloned there by hand; files, hidden directories
and symbolic links are not. Operations address a listed workspace by its exact
directory name, never a trimmed or normalized one, so a hand-placed
`project ` (with a trailing space) is distinct from `project`.
To manage an existing project, clone or move it into `ROOT/workspaces`. Ordinary
listing never initializes a directory or loads workspace plugins.

## Workspace operations

| Operation | Behavior |
| --- | --- |
| Create | Choose a name and port; create `ROOT/workspaces/NAME` and save its port. Refuse an existing name. |
| List / inspect | Show name, configured port, actual address, status and any startup error, plus the names in `ROOT/archive`. |
| Edit port | Save the configured port in the workspace. A running host keeps its current listener until restarted; show the pending change and offer Restart. |
| Rename | Rename the workspace directory. The workspace must be stopped, and the new name must be free. |
| Start | Launch the workspace host, or discover and use its existing running host. |
| Open | Open the current authenticated workspace link in a new browser tab, keeping the manager open (view action). Offer Start when stopped. |
| Stop / restart | Stop through the existing host control flow. Manager Restart stops the host and launches it again using saved workspace settings. Both respect active-work confirmation. |
| Archive | Move a stopped workspace to `ROOT/archive/NAME`, keeping every file. A name already in the archive gets a numeric suffix (`NAME-2`), shortening the name so the result stays within 64 bytes. |
| Restore | Move an archived workspace back to `ROOT/workspaces`. Refuse when a workspace with that name exists; rename it first. |
| Delete permanently | View action only. Stop the workspace, then delete its entire directory. |

Creating a workspace does not invoke a model or create a conversation in the
new workspace. Rename, Archive and Restore hold the moved directory's workspace
lock and launcher lock for the whole move, as Delete does, so a host cannot
start in a directory while it is being moved; a held lock refuses the move.

**Archive** and **Delete permanently** are separate actions. Archive is
reversible and available to the model. The deletion confirmation names the
workspace and its full directory and states that project files, sessions,
plugins and Harness state will be deleted. Deletion is not limited to
`.gene-harness/` and does not imply a backup or undo. Removing only Harness
state would be a separate feature.

Permanent deletion requires the workspace to be stopped and exclusive
ownership to be acquired. If stopping is cancelled, times out or the workspace
remains busy, leave the files alone. Do not follow symlinks inside the
workspace into other directories. Only a real directory directly under
`ROOT/workspaces` can be deleted; also refuse one that contains the user's home
directory, the manager root or the active Harness/Gene installation. Resolve
these paths before checking containment. If filesystem deletion fails partway
through, the workspace stays listed and the failure is reported so the
remaining contents can be inspected.

## Port selection

Extend the shared workspace listener selection so normal startup and recovery
both honor the saved setting. Use this order:

1. The existing supervised restart handoff port.
2. An explicit `web --port PORT` (or `manager --port PORT`) for this
   invocation.
3. A non-empty `GENE_HARNESS_PORT` for a directly launched host other than the
   manager.
4. A nonzero configured port in `.gene-harness/workspace.gene`.
5. The existing remembered `web_port`, then a free port if necessary.

The normal server currently reads `GENE_HARNESS_PORT`, while the recovery
entry point does not. Move this resolution into shared startup code so both
follow the same rules. Manager-launched workspaces have this variable removed,
as described below.

A fixed configured or explicitly requested port must bind successfully;
otherwise report the conflict. Automatic selection can fall back from an
occupied remembered port and persists the selected port in `web_port`, as it
does today. Explicit `--port 0`, or environment value `0` when no flag is given,
requests a fresh free port for that invocation, bypassing configured and
remembered ports. The live connection descriptor always determines the actual
address to open.

The configured setting and the last successful port have different purposes:
starting with a temporary CLI override updates `web_port`, but does not rewrite
the saved configured port. The UI shows both values when they differ.

An ordinary host-requested restart preserves its listening port through the
existing handoff. Manager Restart performs a graceful stop followed by a fresh
launch, so the old handoff cannot override a changed configured port. If the
new port is unavailable, show a stopped workspace with the bind error and keep
the requested setting for correction or retry.

Detect obvious conflicts with the manager's own port or another managed
workspace and show them in the UI. The listener bind remains authoritative;
an unused port cannot be reserved just by saving its number.

## Process ownership and recovery

The existing [per-workspace launcher](../src/runtime/supervisor.gene) already
handles requested restarts and a bounded fallback to recovery. Reuse that
behavior for each managed workspace and for the manager workspace itself. The
manager coordinates these independent launchers instead of loading several
Harness runtimes into its own process.

Managed workspaces' launchers must live independently of browser requests and
of the manager host's lifetime. Closing the browser, stopping or restarting the
manager (including a restart after publishing a manager plugin) leaves running
workspaces alone. On its next start, the manager rediscovers their hosts
through their existing connection metadata and status API. It does not start
all stopped workspaces automatically.

A host started directly in a directory under `ROOT/workspaces` is listed,
inspected and opened like any other. Starting an already running workspace
reuses it. Preserve the existing
exclusive workspace lock; a live lock with an unreachable host is shown as
unavailable or busy, not treated as permission to start a second owner.

Manager Restart always uses **stop, wait for shutdown, then launch**, whether
the current host has a per-workspace launcher or was started directly with
`gene run`. A directly started host cannot restart itself today: its restart
request only stops it. Using the same manager sequence for both avoids that
failure without requiring a new launcher-detection protocol.

Wait for the old owner to release the workspace before starting its replacement.
If stopping needs confirmation, is cancelled or times out, do not start another
host. Report completion only after a new connection instance is ready, showing
normal or recovery status. A fresh launch uses saved workspace settings and
the child environment below; it does not reconstruct the old process's CLI
overrides. Host-requested `/restart` keeps its existing behavior.

The manager is an ordinary Harness host, so its UI uses the existing loopback,
cookie and CSRF authentication. Its list and UI remain usable when another
workspace's configuration or plugins are broken. Opening a workspace uses that
workspace's own authenticated link. Opening recovery goes to that workspace's
existing recovery interface.

Manager operations are serialized. Save workspace metadata through the live
owner when running, or under the existing workspace lock when stopped. Neither
path needs to activate plugins. Report metadata write failures rather than
showing unsaved settings as applied.

### Unresponsive workspaces

The MVP manages workspaces through their APIs. Graceful Stop and Restart use a
bounded wait: ten seconds for control and shutdown. If that wait expires while
the workspace lock remains held, show the workspace as **unavailable**, with
its last diagnostics, and stop the operation. Do not start a replacement, and
do not delete it. Neither Restart nor Delete resumes later on its own.

The manager has no forced termination in this version. The UI tells the user to
stop the process with external tools (the `owner` record's PID is a starting
point) and then refresh. Once the lock is free, the workspace shows as stopped
and Start works again.

Do not signal a process or process group using the PID in
`.gene-harness/owner`. That record's `started` field is a timestamp written by
Harness, not an OS process identity. A held lock plus a live PID does not
establish ownership of that particular process, and a directly started host may
share its terminal's process group.

A later Force stop goes through the launcher, the host's parent, rather than
through a PID signal. The launcher would serve an authenticated loopback
control channel. It would cancel the host Task it owns (TERM, grace, KILL) and
treat subprocess cleanup as unverified only when it had to escalate to KILL.
The review comments below work this design out; it is deferred, not part of the
MVP.

### Detached execution and diagnostics

Detached process launch is required work for this milestone. Gene's current
`exec` APIs either capture output through the parent or inherit its terminal;
neither supplies the independent launcher lifetime described here. Detaching
a Gene Task does not detach an OS process from its terminal and pipes.

The reusable `$os/spawn_detached` capability starts a new session, connects stdin
to `/dev/null`, redirects stdout/stderr to a named file and returns the child
PID or a launch error. For workspace launchers, this file is
`.gene-harness/bootstrap.log`, truncated on each fresh launcher start. It
captures failures after process creation but before the launcher initializes,
such as module-load errors. Failure to execute Gene or open the output file
must be returned as a launch error; the manager must not depend on a child
having printed it.

The capability must support the existing child directory/environment
conventions and survive manager exit or restart without task cancellation
terminating the child. Keep the existing `exec` cancellation semantics. The
detached launcher, in turn, can continue using captured execution to supervise
its own workspace host. The process API needs file redirection, not log
rotation.

`$os/process_alive?` supplies a process-liveness query for diagnostics. A live PID alone does not prove
that the intended workspace is healthy or still owns that PID; use the
workspace lock and matching live connection/status for ownership and readiness.

Once initialized, the detached launcher writes its own diagnostics and the
host output received on its channel directly to `.gene-harness/host.log` using
file APIs. Keep a 1 MiB segment limit and one previous segment; oversized
output must also respect this limit. The launcher closes the active log before
rotation and opens the new file afterward. It does not forward routine output
to its inherited stdout/stderr or use those descriptors for `host.log`.
Foreground workspace launches, including `gene-harness manager` itself, keep
their existing terminal output behavior.

This separates startup redirection from steady-state logging: renaming a file
does not redirect an already-open stdout descriptor. Logging and rotation
continue while the manager is absent. The manager shows launch errors and
bounded tails of `bootstrap.log`, `host.log` and the previous segment, alongside
the existing `startup_failure` diagnostic. Externally started hosts may have no
retained log until their first manager restart.

The manager and launcher are implemented in Gene. The native process additions
are ordinary `$os` functions, with no language syntax changes. See the
[standard library contract](../../../docs/stdlib.md) for literal arguments,
child directory/environment handling and detached lifetime semantics.

### Child environment

Managed workspaces inherit the manager host's environment with
`GENE_HARNESS_WORKSPACE`, `GENE_HARNESS_PORT` and `GENE_HARNESS_OFFLINE` removed
using the existing `^env` convention (`nil` values). Pass the selected workspace
explicitly and let its saved setting choose the port. The launcher establishes
its own supervision and stdout-TTY markers instead of inheriting stale
`GENE_HARNESS_SUPERVISED` or `GENE_HARNESS_STDOUT_TTY` values from the manager.
Detached output is non-TTY.

Retain provider, model and effort environment values as defaults. For
manager-launched hosts, the shared provider-selection code uses this order:

| Setting | Selection order |
| --- | --- |
| Provider | Non-empty saved `provider`, then `GENE_HARNESS_PROVIDER`, then existing provider auto-selection. |
| Model | Non-empty saved `model`, then an applicable `GENE_HARNESS_MODEL`, then the selected provider's default. |
| Effort | Non-empty saved `effort`, then an applicable `GENE_HARNESS_THINKING_EFFORT`, then the selected provider's default. |

Empty or whitespace-only saved values count as unset. An explicit internal
profile pin keeps its existing precedence. If the inherited provider names a
different provider from the saved one, do not apply its generic model/effort
defaults to that saved provider. `OPENROUTER_MODEL` remains an OpenRouter-only
fallback after the saved and applicable generic model values.

For example, with no saved provider, `GENE_HARNESS_PROVIDER=codex` remains
effective even when `OPENROUTER_API_KEY` is present. Saving `provider=anthropic`
in that workspace overrides the manager's Codex default. A selected provider
that is unavailable reports an error rather than silently selecting another.

Carry this launch policy through the per-workspace launcher and its restarts.
Apply it consistently in readiness, plugin-plan validation and model requests;
do not rewrite `config.gene` or let each caller invent its own precedence.
Recovery continues to work without reading a broken provider configuration.
Direct `web` launches keep their existing environment-first selection.

Keep ordinary environment values, credentials and executable/auth-location
settings, including `PATH`, `HOME`, `GENE_BINARY`,
`GENE_HARNESS_CLAUDE_COMMAND`, provider API keys, `CODEX_HOME` and
`CODEX_AUTH_FILE`. Do not copy them into workspace metadata.

The environment comes from the shell that ran `gene-harness manager`. Later
shell changes do not update the manager or existing launchers; to pick them up,
restart the manager from a shell with the new environment and restart the
affected workspace through it. Workspace settings are reread on fresh launch.

## First UI

The `workspaces` view shows the workspaces directory and a table with **Name**,
**Port**, **Status** and **Actions** columns, with **Create workspace** above
it. Each row offers Open, Start/Stop, Restart and Edit (port); its menu
contains Diagnostics, Rename, Archive and Delete permanently. Archived names
appear in a collapsed **Archived** list with Restore. After a graceful-control
timeout, show the workspace as unavailable, with its diagnostics and the
instruction to stop it externally. Show the actual port separately when a
saved change is awaiting restart. Docking the conversation beside the view lets
the user ask the model to do the same operations.

Useful states are stopped, starting, running, recovery, stopping and
unavailable/error. Startup failures expose the last useful diagnostic and an
action to open recovery when available. One failed workspace does not block
the rest of the list.

## First milestone checks

- On a fresh home directory, `gene-harness manager` creates
  `$HOME/.gene-harness-root` with `^role "manager"`, port 8080 and an empty
  `workspaces` directory, and opens the `workspaces` view by default. The view
  works with no model provider configured. `web --workspace
  $HOME/.gene-harness-root` loads the same manager profile. `--root` and
  `GENE_HARNESS_ROOT` select another root; an ordinary workspace is refused.
- Create two workspaces, run both and open their correct authenticated links.
- In a conversation, ask the model to list, create, start, stop and rename
  workspaces. Verify that function results and conversation history contain no
  links, tokens or cookies, that no function deletes a directory, and that
  stopping a busy workspace asks for confirmation in the view.
- Restart the manager, both host-requested and after publishing a plugin, and
  retain the workspace list, port settings and running workspace discovery.
  Managed workspaces keep running throughout.
- Replace `workspace_manager` with a broken plugin. Verify that managed
  workspaces keep running, the workspaces directory is unchanged, and `restore
  workspace_manager` brings the manager back.
- Exit or terminate the manager and its terminal, then verify that detached
  launchers keep running, accept requests and retain bounded logs. Check launch
  failures and log rotation with no manager present. Verify early module-load
  failures appear in `bootstrap.log`, execution failures are returned to the
  manager, and continued output reaches the new `host.log` after rotation.
- Archive and restore a workspace without losing files, sessions or settings;
  archiving and renaming a running workspace are refused.
- List a directory placed in `ROOT/workspaces` by hand and a host started there
  independently, without creating a second owner or changing existing state.
  Names that would leave `ROOT/workspaces` are refused.
- Restart a directly started host through the manager and verify a replacement
  becomes ready. Cancel a busy-work confirmation and verify no replacement is
  started.
- Make a host stop responding while it holds its lock. Verify that Stop and
  Restart give up after ten seconds, and that the workspace shows as
  unavailable with diagnostics. Verify that no replacement starts, Delete is
  refused, and no PID from `owner` metadata is signalled. After the process is
  stopped externally, a refresh shows the workspace stopped and Start works.
- Launch the manager with workspace, port, provider, model and offline overrides
  in its environment. Verify saved settings win, port/workspace/offline
  overrides are removed, and credentials and executable lookup still work.
  Check direct-host port precedence in normal and recovery startup.
- With no saved provider, an inherited Codex selection and an OpenRouter key,
  verify manager launch still selects Codex. With a different saved provider,
  verify that provider wins and does not inherit the Codex model/effort defaults.
  Check readiness, plugin validation and model requests agree after restart.
- Change a port, show the pending change and apply it through stop/start.
  Verify fixed-port conflicts and automatic fallback.
- Rename a stopped workspace and retain its workspace-local settings.
- Exercise delete cancellation, busy-work handling, deletion failure and
  successful removal. Verify that symbolic links inside a workspace are not
  followed and that protected paths, including the manager root and the
  installation, are refused.
- Keep the manager usable while a managed workspace enters recovery.

Keep this milestone focused on local workspace management. Automatic startup
at login, remote machines, reverse proxying workspaces through one port,
filesystem moves, backups and workspace cloning can follow separately.

Forced termination of unresponsive hosts is also deferred. Its intended design
is a launcher-mediated Force stop: an authenticated launcher control channel,
TERM/grace/KILL of the launcher-owned host Task, and an unverified-cleanup
state only after KILL escalation. The third to fifth review comments below
work this design out. Termination of hosts without a responsive managed
launcher, and automatic verification of subprocess cleanup, come after that.

## Implementation and verification

The shared service is in `src/runtime/workspace_manager.gene`; the profile and
plugin are `src/profiles/manager.gene` and `src/builtin/workspace_manager.gene`.
The plugin contributes the ten model functions listed above, a browser-only
action in `ui_actions`, and an authenticated redirect in `ui_links`. Its view
uses the existing theme without custom CSS. The runtime owns its observation
task and operation gate across plugin replacement.

`src/runtime/workspace_settings.gene` owns validation and atomic writes.
Normal and recovery hosts expose owner-authenticated
`GET /api/v8/workspace/settings` and `POST /api/v8/workspace/settings`. Updates
accept only port changes; they preserve the role. A supplied settings digest
is checked under the same write gate, so a stale browser editor cannot replace
newer settings. The manager keeps no copy of workspace settings or
credentials.

The launcher holds a separate `launcher_lock` while starting, running and
restarting its child. This prevents overlapping launchers and lets Stop wait
for both host ownership and launcher shutdown. Managed launchers write bounded
logs through `src/runtime/host_log.gene`; foreground launchers keep their normal
terminal output. Detached spawn redirects only bootstrap output and does not
register a child for cancellation when the calling manager exits.

Readiness waiting uses the authenticated endpoint instead of repeatedly taking
the child's workspace lock. Host and launcher startup allow a 250 ms lock
handoff for short diagnostic probes; a real existing owner still prevents
startup. Offline maintenance keeps its immediate ownership check.

Verification sources:

- `tests/unit/runtime/manager_settings_spec.gene`: metadata validation,
  legacy alias handling, manager root resolution and refusal of ordinary
  workspaces, provider precedence and UTF-8 log rotation.
- `tests/integration/runtime/workspace_manager_spec.gene`: directory listing,
  create/rename/archive/restore by name, exact-name identity, moves refused
  under either lock, bounded archive suffixes, unsafe names, view keys that
  cannot collide with workspace names, encoded Open links, deletion of a
  hand-placed directory without Harness state, real detached hosts,
  live port changes, duplicate Start, busy-work confirmation, stale editors,
  deletion guards and failures, and bounded control of an unresponsive host.
  It also adopts a host started directly under `ROOT/workspaces` and replaces
  it on explicit Restart without losing files, sessions or credentials.
- `tests/integration/web/manager_ports_spec.gene`: fixed, automatic, explicit
  and supervised-restart port behavior.
- `tests/integration/web/workspace_manager_spec.gene`: fresh HOME, provider-free
  UI, `--workspace`/`--root` validation, actual model-code execution,
  credential-free results, authenticated Open, manager restart and abrupt
  termination, profile-aware plugin repair and recovery metadata.
- `tests/fixtures/manager_browser.gene`: an isolated, provider-free manager for
  browser verification. Stop its managed hosts and manager when finished.
- Repository `tests/test_detached_process.nim`, `tests/test_process_launch.nim`
  and `tests/test_exec.nim`: process lifetime, launch failures and the public
  `$os` contract. `nimble execTest` includes the detached suite.

Live Chrome checks (2026-10-17, before the single-root layout) covered
creation, Start/Open, alias edits, pending ports and conflict feedback, docked
conversations, removal/re-addition without stopping the target, deletion
cancellation, and manager restart with a surviving host. No browser JavaScript
errors were reported.

Long-lived browser testing exposed a Gene VM bug: default arguments on captured
closures were evaluated under an expired creation budget. Invocation setup now
applies the current budget before evaluating defaults, and keeps that budget
through the function body. `tests/test_runtime_budget.nim` checks the language
contract; the manager suite and live Chrome checks exercise delayed view actions
after their activation deadline has passed. No timeout increase or periodic
manager restart is required.

Verification included the Harness UI, runtime, profile, authentication,
startup and recovery regression suites. After the final fixes, the focused
manager/locking/recovery run passed 18 tests. The callback fix also passed the
9-case execution-budget suite, the core VM suite and 892 language specification
checks. Process qualification passed 39 process/exec checks on macOS and 18
process checks in a native Linux ARM64 container.

The review discussion below is historical and predates the single-root layout.
The owner decisions at the end and the behavior above govern implementation;
the proposed Force stop work is deferred.

## Review comments (Claude, 2026-10-17)

Disposition: points 1, 2 and 4 are incorporated above. Point 3 is incorporated
for protected paths and explicit whole-directory confirmation. Its proposed
restriction to supervisor-created directories is not adopted: permanent
deletion remains available for an added workspace, as required. No
directory-creation provenance flag or separate state-only deletion action is
needed for this milestone. Manager Restart uses stop/start for every host,
which addresses point 4 without a new detection API. Original comments follow.

The direction is right: workspace-local metadata, a separate registry, reuse of
the per-workspace launcher, and a clear port precedence. Four substantive
points, checked against the code. Paths are relative to `examples/gene-harness/`
unless they start with `docs/stdlib.md`, which is the repository-root standard
library reference.

1. **Detached launching is required work, not a conditional.** "If independent
   child lifetime management exposes a missing process API" will certainly
   apply. `$os` offers only `exec`, `exec_stream`, `exec_stdio` and their async
   forms.
   - **Captured forms** pipe the child's output into the parent, and cancelling
     their Task kills the child's process group (`docs/stdlib.md:187`).
   - **`exec_stdio`** inherits the parent's terminal.
   - **The existing per-workspace launcher** streams the host's output into its
     own stdout (`src/runtime/supervisor.gene:34`). Launched by the manager
     through a captured exec, that stdout is a pipe the manager reads, so once
     the manager exits, the launcher's next write fails.

   "Launchers live independently of the manager's lifetime" therefore needs
   three things:
   - **A detached spawn.** It starts a new session, takes stdin from
     `/dev/null`, writes output to a file and returns a PID, and nothing kills
     the child when the manager exits.
   - **A liveness check by PID.** "Status observed from process state" has no
     API today.
   - **A defined place for host output.** Today only a failed normal startup
     leaves a diagnostic (`.gene-harness/startup_failure`), and everything else
     goes to the launcher's terminal. "Show the last useful diagnostic" needs a
     bounded per-workspace log that the manager can read.

   Plan these as part of the first milestone.

2. **The children's environment overrides workspace settings.** Workspaces
   launched by the manager inherit its environment.
   - **`GENE_HARNESS_PORT`** is read at `src/web/server.gene:121` and binds as
     strictly as `--port`, but it is missing from the port precedence above.
     When it is set in the shell that started the manager, every workspace
     tries the same fixed port and all but one fail.
   - **`GENE_HARNESS_PROVIDER` and `GENE_HARNESS_MODEL`** override each
     workspace's `config.gene` ([Claude providers](claude.md): "a non-empty
     `GENE_HARNESS_PROVIDER` still wins"). One manager would force one provider
     onto every workspace.

   Define the child environment. Scrub the per-workspace overrides (port,
   workspace, provider and model), keep credentials, and note that the
   environment is captured when the manager starts.

3. **"Delete permanently" can delete a user's project.** A workspace is a
   project directory, and "Add existing" registers any existing directory,
   such as a git checkout. Deleting an entire directory that the supervisor did
   not create is a large step for a local web UI.
   - Record in the registry whether the supervisor created the directory.
   - Allow full deletion only for directories it created. For added ones,
     offer deleting `.gene-harness/` only.
   - Also refuse a directory that contains the registry (`~/.gene`), the
     running Harness or Gene installation, or the manager's launch directory.
     Registering the Gene repository itself is an easy mistake.

4. **Restart of an independently started host only stops it.** When a host is
   not running under the launcher, `request_stop` turns exit code 75 into 0
   and prints "restart stops this process"
   (`src/runtime/round_controller.gene:411`). The proposal reuses that control
   flow for Restart and also supports independently started workspaces, so a
   Restart from the manager leaves such a workspace stopped. Detect an
   unsupervised host, then stop it and launch it under the manager's own
   launcher, or tell the user that Restart will stop it.

## Second review (Claude, 2026-10-17)

Disposition: both points are incorporated above. Saved provider/model/effort
settings win over compatible inherited defaults, preserving an explicit
provider selection when the workspace has none saved. Bootstrap redirection
and launcher-owned rotating logs are separate; process execution errors are
returned by the spawn API rather than assumed to appear in child output.
Original comments follow.

The revision covers the first review. Detached launch, the child environment
and the stop-then-launch Restart are now specified, and the owner's decision on
deleting added workspaces stands. The new claims check out:
- the recovery entry point binds only `--port` (`src/web/recovery.gene:28`);
- `^env` removes a variable when its value is `nil` (`docs/stdlib.md:167`).

Two substantive points remain.

1. **Scrubbing the provider override can silently switch a workspace to paid
   API billing.** Provider auto-selection ranks OpenRouter first, then
   Anthropic, then Codex (`^auto` 0, 1 and 2 in `src/builtin/provider_*.gene`).
   It picks the first provider whose credentials are present.

   Consider a user who exports `OPENROUTER_API_KEY` for other work and runs
   their workspaces with `GENE_HARNESS_PROVIDER=codex` (subscription). A
   workspace that has no saved `^provider` uses Codex when launched directly.
   Launched by the manager, it gets OpenRouter, because the override is
   removed while the key is kept.

   Most existing workspaces have no saved provider, so this is the common case.
   Two options:
   - For manager launches, pass the environment's provider, model and effort
     only when the workspace has no saved value. Saved settings then win, and
     an unconfigured workspace behaves as it does when launched directly.
   - Alternatively, show the effective provider and model in List / inspect,
     and on Add existing, offer to save the provider that is in effect.

   The milestone check should include a workspace with no saved provider.

2. **Spawn-level output redirection and launcher-owned rotation conflict.**
   The detached spawn "redirects output to files", while `host.log` rotation
   "belongs to the launcher". If the spawn points the launcher's stdout at
   `host.log`, the launcher cannot rotate that file. Renaming it leaves the
   open file descriptor writing to the renamed file, and nothing reopens it.

   Specify two layers:
   - **The spawn** sends the launcher's own stdout and stderr to a small
     bootstrap file, rewritten on each launch. It catches failures that happen
     before the launcher runs, such as a missing `gene` binary or a crash at
     load.
   - **The launcher** writes `host.log` and `host.log.1` itself with file APIs.
     It already receives every host line on its channel
     (`src/runtime/supervisor.gene:37`).

   The manager then shows the bootstrap file and the log tail, which also
   pins down the process API: the spawn needs output to a named file, not
   rotation.

## Third review (Claude, 2026-10-17)

Disposition: the unresponsive-host gap is accepted, with Force stop included
for managed launchers. It uses an independent launcher control channel and the
existing owned-Task cancellation policy. The proposed PID/liveness check does
not establish process identity or safe group ownership, so raw PID signalling
is not adopted. Force termination without a responsive managed launcher is
explicitly deferred. Original comments follow.

Both second-review points are in. Saved settings now win and the environment
is only a fallback, with a test for the Codex/OpenRouter case. The bootstrap
file is separate from launcher-written `host.log` rotation. The file APIs the
launcher needs exist: `$io/open_write ^mode "append"`. The launcher's `^max_bytes`
on `exec_stream_async` caps only the captured result, not the streamed lines,
so long-running hosts are not truncated. One substantive point remains.

1. **The manager cannot stop a host that stops responding.** Stop, Restart and
   Delete all go through the host's HTTP control flow, and the process API adds
   only spawn and liveness. A hung host still holds its lock and is shown as
   "unavailable or busy". The manager then cannot stop, restart or delete it,
   so the user is back to a terminal and `kill`.

   That is the case the supervisor exists for ("including workspaces whose
   normal host cannot start"). It is not hypothetical either: the SERVICE
   heartbeat stall has been seen and is still unreproduced.

   Add a **Force stop** for a workspace whose lock is held while its HTTP
   control does not respond within a timeout.
   - Signal the owner's process group with TERM, wait a grace period, then
     KILL. This is the same policy as captured-exec cancellation
     (`docs/stdlib.md:187`).
   - Take the PID from `.gene-harness/owner`, which is written under the lock.
   - Before signalling, confirm that the lock is still held and that the PID
     is alive, to guard against PID reuse.
   - Afterwards, wait for the lock to be released and keep the log tail.

   This adds a signal call to the process capability alongside spawn and
   liveness. If you want to defer it, say so explicitly in the
   first-milestone scope.

## Fourth review (Claude, 2026-10-17)

Disposition: channel authentication is now explicit, with a random bearer
secret, server-side-only access and rejection before command parsing. The
subprocess point exposes a real guarantee gap, but the native TERM handler
already cleans captured groups independently of the scheduler. The proposal
now distinguishes host termination from unverified subprocess cleanup and
blocks manager Start/Restart/Delete until external cleanup is confirmed.
Planned checks cover a stalled handler with an active shell child and a suspended
host that requires KILL. A persisted PID ledger is not adopted as termination
authority; automatic descendant cleanup remains deferred. Original comments
follow.

The third-review point is in, and the design is better than my suggestion.
Terminating through the launcher's own captured-exec Task, with launch and
host-start IDs, avoids the PID-reuse and shared-terminal-group problems that
signalling the PID in `owner` would have. Restricting Force stop to managed
launchers is a reasonable first-milestone limit. Two substantive points remain.

1. **Force stop leaves the host's own subprocesses running.** The host's
   captured children each get their own process group. Every captured `$os`
   exec starts with `poDaemon` (`src/gene/stdlib.nim:3019`). That covers:
   - shell sessions (`src/runtime/shell_sessions.gene`);
   - the Claude CLI provider (`src/builtin/provider_claude.gene:79`);
   - Poppler and `textutil` conversions in `genex/documents`;
   - the computer driver.

   TERM then KILL to the host's group therefore does not reach them. A hung
   host also cannot run the cancellation that would normally clean them up. So
   after a Force stop, a running build in a shell session, or a Claude CLI
   turn, can keep running and writing into the workspace. That includes
   running after the lock is released, while a new host starts or Delete
   proceeds.

   "TERM/KILL cleanup completes" in the milestone check does not hold as
   written. Two options:
   - **Child ledger.** The exec layer, or the host, records each captured
     child's process group in an owner-only file under `.gene-harness/` when it
     spawns and when it reaps. The launcher signals those groups after the host
     group, using the same TERM, grace, KILL sequence.
   - **Report survivors.** Force stop reports surviving descendants and does
     not allow Start or Delete until they are gone.

   The ledger is the simpler guarantee. Either way, the milestone check should
   cover a host that is hung with a shell-session child still running.

2. **State the control channel's authentication.** The launcher channel can
   terminate a workspace, and a loopback TCP port is reachable by any local
   process, including a browser page that sends a simple cross-origin POST.
   "Requests target both IDs" works as authentication only if the launch ID is
   a random secret, such as the existing `$crypto/random_hex 16`, that every
   request must present. It is readable only through the owner-only `launcher`
   record.

   Say that explicitly. Also say that the channel rejects requests without the
   secret, and requests with a browser `Origin`, before parsing anything else.

## Fifth review (Claude, 2026-10-17)

Both fourth-review points are in, and the new claims check out:
- `src/gene/process_launch.c` installs SIGINT, SIGTERM and SIGHUP handlers that
  SIGKILL every registered captured group. They run independently of the
  scheduler, on every native POSIX build (`nativeProcessBackend`,
  `src/gene/stdlib.nim:2369`).
- `$crypto/secure_equal?` is the existing constant-time comparison
  (`src/web/auth.gene:30`).

The launcher channel's authentication is now explicit. One design point
remains.

1. **Use the host's exit signal to decide whether cleanup is unverified.**
   As written, every Force stop puts the workspace into `cleanup_required`
   and needs a manual Confirm cleanup. In the common case that is not needed.
   - **When the host exits during the TERM grace period**, its native handler
     has already SIGKILLed every registered captured group before re-raising.
     That is the same guarantee a graceful Stop provides, and graceful Stop
     needs no confirmation.
   - **Only an escalation to KILL** (the host was stopped, ignored TERM or
     blocked it), or an exit the launcher cannot attribute, leaves cleanup
     genuinely unverified.

   The launcher already sees the difference in the captured result. The
   existing launcher treats -15 and 143 as TERM exits
   (`src/runtime/supervisor.gene:57`), and -9 is KILL. So:
   - write `cleanup_required` only for KILL escalation or an unknown cause;
   - report "Host stopped; captured subprocesses terminated" for a TERM exit.

   This keeps the manual step for the case it protects. If every Force stop
   requires Confirm cleanup, users will learn to click it without checking.
   The suspended-host milestone check already covers the KILL path. Add a
   check that a TERM exit does not set the marker.

## MVP scope decision (owner, 2026-10-17)

The MVP manages workspaces through their APIs: status, graceful Stop and
Restart, and metadata writes through the live owner. Starting uses the new
detached launch. Forced termination is deferred. A host that does not respond
within the graceful timeout is shown as unavailable and stopped with external
tools. The third to fifth reviews above describe the deferred launcher-mediated
Force stop; they do not apply to the MVP.

## Manager workspace decision (owner, 2026-10-17)

The supervisor is renamed **manager**, and this file moved from
`docs/supervisor.md` to `docs/manager.md`. The review comments above use the
earlier name. The manager now runs as a Harness workspace at
`$HOME/.gene-harness-manager`, with the `manager` profile and its
`workspace_manager` plugin. That plugin provides the `workspaces` view and
functions, so the user can manage workspaces from the view or through a
conversation. This replaces the separate small manager host and the
`~/.gene/harness-supervisor/` registry location. Delete permanently stays a
confirmed view action, and no model-visible result carries workspace
credentials.

## Single-root layout decision (owner, 2026-10-23)

The manager root replaces `$HOME/.gene-harness-manager` and its
`registry.gene`. The root is `$HOME/.gene-harness-root` by default, or
`--root DIR` / `GENE_HARNESS_ROOT`; the manager's state is in
`ROOT/.gene-harness`, and every managed workspace is `ROOT/workspaces/NAME`.
The directory is the registry. Add existing, Update directory and the separate
alias are removed: a workspace's name is its directory name, and an existing
project is cloned or moved into `ROOT/workspaces`. Remove from manager is
replaced by Archive (`ROOT/archive/NAME`) and Restore. Delete permanently stays
a confirmed view-only action, and the earlier decisions on Force stop and
credential-free results still apply. The old `~/.gene-harness-manager` is not
migrated automatically.
