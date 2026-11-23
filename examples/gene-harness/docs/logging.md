# Logging

Every diagnostic output in the Harness is a structured log record. The console,
the in-process ring and the launcher's `host.log` are sinks fed by the
same record; no feature prints free text.

There are two deliberate presenters outside this rule:

- the **CLI result presenter**: `gene-harness composition`, `transcript`,
  `--json` and the usage/error text they print as their result;
- the **browser-link presenter**: the launcher (when supervising) and a direct
  host print the owner link or the `gene-harness link` hint.

The launcher's terminal renderer and CLI stream passthrough are presenters;
its own diagnostics are `supervisor/*` records. `src/audio/build_mac.gene` is a
standalone build tool, not part of the host.

`tests/unit/runtime/no_raw_print_spec.gene` enforces the rule over
`src/**/*.gene`.

## Record

```gene
{^schema "harness.log.v1"
 ^run "e41c9a07" ^seq 8841 ^time_ms 1795269802418 ^level "info"
 ^type "turn/start"
 ^target {^workspace "w_1" ^session "s_7" ^round "r_3" ^turn 3}
 ^message "turn 3 started"
 ^data {^model "provider/x" ^request_bytes 18211}
 ^event {^stream "s_7" ^seq 42}}
```

| Field | Meaning |
| --- | --- |
| `schema` | `harness.log.v1` |
| `run`, `seq` | A random id allocated at process entry and the record's order in that run. A replacement host process gets a new `run` |
| `time_ms` | `$os/wall_ms`; display only, never cross-process ordering |
| `level` | `error`, `warn`, `info`, `debug` or `trace` |
| `type` | `family/name`, snake_case; the family is the first segment |
| `target` | The object the event is about; `workspace` is always present |
| `message` | One human sentence; never the only place a fact lives |
| `data` | Typed detail such as counts, digests and error codes; bodies belong in blobs |
| `event` | Optional `{stream, seq}` of the durable event this record projects |

The console renders a record as:

```
14:03:22.418 INFO   turn/start  s_7 r_3 t3  turn 3 started
```

`render_text` uses UTC because the runtime has no local-time formatter. The
time is decoration; `(run, seq)` is the identity.

## Types and targets

Core types are closed and listed in `src/kernel/log_catalog.gene`. Plugin types
are free-form under `plugin/<id>/...` and require a `plugin` target.

| Family | Types | Required target |
| --- | --- | --- |
| `host` | `start`, `ready`, `recovery_ready`, `port_changed`, `restart_unsupported`, `stopping` | `workspace` |
| `supervisor` | `child_started`, `child_exited`, `child_output`, `output_discarded`, `startup_failed`, `restart` | `workspace` |
| `web` | `request_failed` | `request` |
| `web` | `connection_failed` | `client`, `session` |
| `turn` | `start` (info), `end` (info), `failed` (error) | `session`, `round`, `turn` |
| `model` | `call` (debug), `result` (info), `error` (warn) | `session`, `round`, `turn`, `call` |
| `command` | `start`, `end` | `session`, `command` |
| `ui_action` | `finished` | `input`, `view` |
| `composition` | `changed` | `revision` |
| `plugin` | `state`, `output`, `error` | `plugin` (`output` also `revision`) |
| `output` | `print` | `session` and either `turn` or `command` |
| `mode` | `cleanup_failed` | `session` |
| `housekeeping` | `failed` | `workspace` |
| `trigger` | `fired`, `tick_failed` | `trigger` |
| `channel` | `status` | `channel` |
| `log` | `dropped`, `invalid` | `workspace` |

Target keys are `workspace`, `session`, `round`, `turn`, `call`, `command`,
`input`, `plugin`, `view`, `revision`, `trigger`, `delegation`, `channel`,
`request` and `client`. A type lists the keys it requires; a missing key is a
bug that strict-mode tests catch.

## API

```gene
(log_event "turn/start" $"turn ${n} started"
  ^target {^turn n} ^data {^model m ^request_bytes size})
```

- `^target` is merged over the ambient target (see `log_scope`).
- `^level` defaults to the catalog's level for the type.
- `^data` is a map or a zero-argument function. The function is called only
  when the record is emitted, so hot paths build detail lazily.
- An unknown type, a missing required target key or an unrepresentable value
  becomes a `log/invalid` record. In strict mode it raises instead.
- Log calls never throw into the caller outside strict mode, and the writer
  contains sink failures.

`(log_scope target body)` runs `body` with `target` merged into the runtime
context's `log_target`. The turn loop, command execution, UI action execution
and view rendering carry it, so nested records inherit their session, round,
turn, command, input, view or revision. Trigger records pass their trigger
target explicitly.

`(log_recent ^limit 50 ^type "model/*")` returns the newest ring records,
optionally filtered by exact type or family wildcard. The ring holds 2048
records and overwrites the oldest.

`(log_run)` returns the current process run id. Specs use
`(log_reset ^strict true ^quiet true)` to reset the process-global facade.

## Levels and settings

`log_level` (default `info`) and `log_levels` (a map from family to level) are
workspace settings that apply immediately:

```gene
(workspace .set_settings {^log_level "debug" ^log_levels {^model "trace"}})
```

A family override wins for its types. A filtered record is never created.
The facade caches the table; the host applies it after opening the workspace
and again on every `SettingsChanged`.

## Durable links

Core types with a durable counterpart carry `^event {^stream ^seq}` pointing at
the committed event:

| Operational record | Durable event |
| --- | --- |
| `turn/start`, `turn/end` | `turn/start`, `turn/end` |
| `model/result` | `model/result` (`model/request` precedes it) |
| `command/start`, `command/end` | the `command` core-state write |
| `composition/changed` | `composition/changed` |
| `plugin/state` | `plugin/state` |
| `channel/status` | the `trace` `channel/status` event |
| `output/print` from a turn | the `console` event, when one is committed |

A command's streamed `output/print` is not one durable event per chunk; it is
projected beside the command state and carries no `event`. The durable
`console`, `trace`, `message`, `output` and `lifecycle` producers are unchanged.
`HarnessLog` and `hydrate_harness_log` remain for the transcript/UI feed; the
operational records are added beside them.

## Sinks and modes

`log_start` runs at process entry. Once options are parsed, `log_configure`
selects the mode:

| Mode | Writer |
| --- | --- |
| `host_direct` | Human text to stdout |
| `host_supervised` | JSONL records to stdout for the launcher |
| `recovery` | Human text to stdout when direct; supervised recovery uses `host_supervised` |
| `cli` | Human text to stderr |
| `launcher` | Launcher presenter |
| `silent` | No console writer (specs) |

Before `log_configure`, records go to the ring and to stderr as text.
`host/ready` and `host/recovery_ready` are credential-free; the browser-link
presenter is separate and does not depend on the log level.

A relay line is the JSON serialization plus a newline, bounded at
`log_line_budget` (8192 bytes) including escaping. An oversized record keeps
its identity, a shortened message and `{truncated true, data_bytes N}`; if it
still does not fit, it becomes a `log/invalid` notice. Known secrets are
replaced before bounding, so a secret cannot cross a truncation boundary. The
host reads the workspace secrets once while opening the workspace and caches
them; a turn or command never performs file I/O just to redact a log line.

The launcher reads the supervised child's stdout and stderr through byte pipes.
It frames complete lines before redacting, accepts a line as a record only when
it parses, matches the schema and fits the budget, and wraps every other line as
`supervisor/child_output` with its stream. A raw line over the budget is
discarded whole and reported as `supervisor/output_discarded` with its byte
count and no text. The launcher is the only `host.log` writer; it rotates
before a record that would cross 1 MiB, keeps one previous segment, and never
splits a record across segments. On a terminal it renders records and prints
raw lines as they arrived; managed workspaces get JSONL `host.log`; redirected
supervised hosts get JSONL stdout. CLI commands keep their exact stdout and
stderr.

Harness launchers configure Gene runtime diagnostics on stderr as text. The
host's Harness records still use JSONL on the supervised relay.

The browser-link presenter lives in the launcher for supervised hosts. It
follows the readiness marker rather than a log record, so a filtered
`host/ready` changes nothing: a terminal gets `Browser: <link>`, redirected
output gets the `gene-harness --workspace W link` hint, and a restart prints
again for the new child. A direct host keeps its own presenter.

The core Logs route (`GET /api/v9/logs`) reads retained `host.log` records and
falls back to the host's in-process ring when no log file is available. It
filters by type, target key, minimum level and `since`, and redacts each
complete file line before it truncates for display. The editor Logs tab uses
the same route.

`gene-harness logs [--type T] [--level L] [--session ID] [--since MS] [--lines N] [--follow]`
prints matching records through the same route. `--follow` polls with the
returned cursor. `--json` returns the route's records and cursor instead of
lines.

The REPL object `workspace/.logs` queries the in-process ring:
`(workspace/.logs ^type "model/*" ^target {^session "s"})`.

Each delivery subscriber has a bounded queue. Publishing uses a non-waiting
send; a full queue drops the record, counts it, and the next accepted message
carries the gap range. Consumers turn that into a synthetic `log/dropped`
record. Browser sockets receive `log` frames on the existing stream with a
separate `log_sequence`, sent through `ws_try_send` below a lower backlog than
state frames. A full or slow browser socket drops diagnostics without closing
the stream or advancing state sequences, so state delivery keeps its ordering.
Plugins subscribe with `host .PluginHost:subscribe_log {^type "model/*"
^target {^session "s"} ^capacity 256} handler`; the subscription is owned by
the activation and closes with it. A plugin writes its own records through
`(plugin_log host)`: the returned logger stamps `plugin/<id>/<type>` and the
`plugin` target, so it cannot impersonate another plugin.

## Why not `$log`

Gene's `$log` resolves destinations from process configuration, so its default
route sends only warnings and errors to stderr and has no fixed stdout sink. It
also rewrites oversized payloads inside its envelope, which would discard the
record's type and target. The facade writes its own bounded line and uses
`$print`/`$println` only in its single writer and the presenters.
