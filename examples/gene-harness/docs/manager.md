# Workspace manager

This reference describes the single-root manager. Forced termination is not
implemented; see [unresponsive workspaces](#unresponsive-workspaces). Historical
checks and owner decisions are in the [verification record](verification/workspace-manager-history.md).

The manager is a Harness workspace for creating, opening and managing other
Gene Harness workspaces. Its directory is the **manager root**,
`$HOME/.gene-harness-root` by default, and every managed workspace is a child
directory of `ROOT/workspaces`. A manager plugin supplies its UI and functions,
so the user can manage workspaces from a plugin view or by asking the model in
a conversation. Each managed workspace keeps its own port, sessions and
plugins. The manager gives one place to find and control them, including
workspaces whose normal host cannot start.

## Ownership and scope

The manager is an ordinary Harness workspace with the manager profile. The
workspace directory is the registry: managed workspaces live under
ROOT/workspaces, and Archive/Restore move them through ROOT/archive. Separate
aliases and an external workspace registry are not supported. Older manager
roots are not migrated automatically.

Control uses each live owner's API and bounded graceful shutdown. Unresponsive
hosts require external process control. Permanent deletion stays a confirmed
view action, and function results never contain workspace credentials. These
are the owner's scope and layout decisions, reflected in the operations below.

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

On first run the manager workspace's configured port is **8580**, bound to
`127.0.0.1`. `--port` overrides it for one invocation. The manager command
ignores `GENE_HARNESS_PORT`. A fixed configured port must bind: if 8580 is
occupied, report the conflict and let the user choose another port. Do not
silently move the manager to a random port.

Existing manager roots keep their saved configured port. To change it, edit
the manager workspace's port setting and stop/start the launcher; a supervised
restart preserves the current listening port. `manager --port 8580` also
overrides the saved port for one launch.

The manager root's `workspace.gene` records `^role "manager"`. Any launch of
that directory uses the manager profile, so `web --workspace
$HOME/.gene-harness-root` behaves like `manager`. The existing `web` command
and its default behavior remain available for starting other workspaces
directly. Startup prints a ready-to-open browser link using the existing
terminal-output convention.

## Manager workspace

The manager runs the `manager` profile: the baseline profile's plugins plus
`workspace_manager`. It receives the same public PluginHost
receiver as a stored plugin and resolves WorkspaceHost through workspaces/host.
That narrow service owns detached launch and other workspaces' control endpoints.
Users and the model can extend the manager
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
is reported as status and does not block the host. Only conversations need a
provider, which
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
                                workspace.gene has ^role "manager" and port 8580
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

The manager controls workspaces through their APIs. Graceful Stop and Restart use a
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

## Workspace view

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
