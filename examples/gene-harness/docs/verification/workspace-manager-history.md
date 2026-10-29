# Workspace manager implementation history — 2026-10-17 to 2026-10-23

Archived from manager.md during the 2026-10-29 ownership cleanup. This is
dated implementation evidence and review discussion. Several proposals and
paths were superseded by the owner's single-root decision. The current
contract is [Workspace manager](../manager.md).

## First milestone checks

- On a fresh home directory, `gene-harness manager` creates
  `$HOME/.gene-harness-root` with `^role "manager"`, port 8580 and an empty
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
     workspace's `config.gene` ([Claude providers](../claude.md): "a non-empty
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
