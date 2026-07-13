# Gene Logging and Diagnostics

Status: **implemented MVP, revision 2**. Implemented 2026-07-12. Live reload,
task/actor correlation, asynchronous exporters, and rotation remain explicitly
deferred as described below.

Goal: give Gene applications, the runtime, and native extensions one structured
diagnostic pipeline that is cheap when disabled, safe under concurrency, and
explicit about output authority. Logging must not become a second error model,
an audit-log substitute, or hidden work in VM hot paths.

This proposal draws from the unified logging work in the legacy repository:

- `~/gene-workspace/gene/openspec/changes/add-logging-support/design.md`
- `~/gene-workspace/gene/src/gene/logging_core.nim`
- `~/gene-workspace/gene/src/gene/logging_config.nim`
- `~/gene-workspace/gene/src/genex/logging.nim`
- `~/gene-workspace/gene/tests/test_logging.nim`

The old design found the right overall shape—one event, hierarchical routing,
multiple sinks, and early filtering—but its implementation also exposes the
places where this runtime should make different choices.

## 1. Recommendation in one page

Build logging as two APIs over one internal event pipeline:

1. A small native runtime API for parser/compiler/VM/stdlib/extension
   diagnostics. Runtime logger handles are resolved during initialization and
   have an allocation-free, lock-free disabled path.
2. A public `log` namespace for applications. A `Logger` is an immutable,
   attenuated handle with a bound name and optional base payload. Ordinary
   `logger ~ info`-style methods are eager and ergonomic; corresponding
   `error!`/`warn!`/`info!`/`debug!`/`trace!` macros defer message and payload
   evaluation until after the level check.

Use:

- levels `error`, `warn`, `info`, `debug`, and `trace`, plus `off` in config;
- segment-aware hierarchical names such as `gene/vm`, `gene/http`, and
  `app/orders/worker`;
- immutable startup configuration with independently inherited level and sink
  selection;
- synchronous `stderr` and buffered file sinks initially;
- human-readable text and JSON Lines renderers;
- structured payloads, redaction before fan-out, and bounded value rendering;
- per-sink serialization, with no global write lock;
- explicit configuration (`--log-config` or an embedding API), never an
  implicitly executed file found in the process working directory.

Keep authoritative event logs, security audit logs, metrics, and instruction
traces separate. They have different durability, loss, ordering, and query
contracts.

## 2. Lessons from the legacy design

### 2.1 Keep these ideas

| Legacy idea | Recommendation here |
|---|---|
| One backend for Gene, Nim runtime code, and extensions | Keep. Divergent diagnostic paths are difficult to configure and test. |
| Stable hierarchical logger names | Keep, with segment-aware matching and normalization once at logger creation. |
| Longest-prefix configuration | Keep, but resolve a logger to a route handle once rather than scanning on every emission. |
| Filter before event construction | Keep as a hard performance contract. Lazy forms also avoid evaluating the message and payload. |
| Construct one event and fan it out | Keep. Render lazily once per format for all sinks using that format. |
| Separate sink transport from rendering | Keep. A file can use text or JSON Lines without changing callers. |
| Console and append-only file sinks | Keep for the MVP. They cover development and ordinary service use. |
| Stable runtime names (`gene/parser`, `gene/compiler`, `gene/vm`, `gene/stdlib/*`) | Keep, adjusted to this repository's module boundaries. |
| Do not replace program output, diagnostics, or explicit tracing indiscriminately | Keep and sharpen the boundary in §3. |

### 2.2 Change these parts

The legacy implementation performs normalization and route lookup under a
global configuration lock for every `log_enabled` and `log_message` call. It
then snapshots sinks, takes a second global write lock, flushes every sink for
every event, and may have already built the Gene message before filtering.
That is serviceable for occasional logs but is the wrong default for this
repository's parser, reader, compiler, and future dispatch loop.

Specific changes:

- **Resolve once.** A `Logger` stores a resolved route (threshold and sink
  indexes), not just a name. Disabled checks are an integer comparison.
- **Do not call arbitrary `to_s` to name a logger.** Names are `Str`. Running
  user code while constructing infrastructure objects complicates failures,
  reentrancy, and reproducibility.
- **Offer explicit lazy counterparts.** Ordinary `logger ~ info` methods are
  the concise eager default. They cannot prevent interpolation or payload
  construction, so `info!`/`debug!`-style macros provide opt-in laziness for
  expensive or hot-path calls; eager `emit` remains the adapter primitive.
- **Avoid a global emission lock.** Each sink serializes its own writes.
  Ordering is defined per sink, not globally across unrelated outputs.
- **Do not flush files after every line.** Buffer ordinary records and expose
  explicit flush/close behavior. Error-level flushing is a configurable
  policy.
- **Do not auto-load `config/logging.gene` from CWD.** The working directory is
  mutable ambient state, and a config that names file sinks is output
  authority. The launcher or embedder selects and reads configuration
  explicitly.
- **Do not use a Gene-map line as the primary machine format.** JSON Lines has
  better operational tooling and does not pretend that best-effort logs are
  durable `serde` records. Gene-record rendering can be added later if a real
  native consumer requires it.
- **Do not make thread id the primary correlation key.** Gene tasks and actors
  are the semantic units; future scheduler work may move them between threads.
- **Define sink failure and redaction behavior.** The legacy proposal leaves
  both underspecified for a system-wide facility.

## 3. Boundaries: what logging is and is not

These outputs must remain distinct even if they eventually share exporters:

| Facility | Contract | Examples |
|---|---|---|
| Program output | User-visible command result; exact stdout/stderr behavior may be API | `println`, REPL prompts, compiler disassembly |
| Diagnostic logging | Best-effort, filterable observations for operators/developers | server started, retry, cache miss, internal warning |
| Errors | Typed control flow or a process-boundary diagnostic | `GeneError`, `SerdeError`, CLI error with source location |
| Authoritative event/audit log | Durable, queryable domain history with explicit ordering and failure semantics | agent tool events, confirmations, security audit trail |
| Metrics | Aggregated numeric state | request count, queue depth, latency histogram |
| Execution trace | High-volume specialized stream | VM instruction trace, scheduler trace |

Consequences:

- The AI agent's versioned event log stays an event log. Sending a copy to a
  diagnostic sink is optional; logging cannot become its source of truth.
- `net/http` access/error callbacks remain application hooks. A default adapter
  may translate their records to logs, but logging does not replace their
  callback and redaction contract.
- CLI usage, parse errors, and requested compiler output remain direct output.
  Only incidental internal diagnostics move to the logging backend.
- A logging failure never changes language control flow. Applications that
  require durable recording must use a store/event-log API that can fail
  explicitly.

## 4. Public Gene API

Primary namespace: `log`.

```gene
(import log [LogLevel new_logger new_file_logger
             info! warn! error! debug! trace!])
(import Fs [WriteDir])

(var logger
  (new_logger "app/http"
    ^payload {^service "api" ^version build_version}))

(logger ~ info "listening" ^payload {^host host ^port port})
(debug! logger $"accepted request ${request/id}"
  ^payload {^request_id request/id ^route route/name})
```

The `!` suffix follows the language convention for visible rewriting and
avoids reserving common local names such as `error`, `info`, and `trace` in
every importing module. Expansion is conceptually:

```gene
(scope
  (var generated_logger logger)
  (if (generated_logger ~ enabled? LogLevel/debug)
    (generated_logger ~ emit LogLevel/debug
      $"accepted request ${request/id}"
      ^payload {^request_id request/id ^route route/name})
    nil))
```

The real expansion evaluates `logger` exactly once. Its introduced temporary
uses the macro system's hygienic fresh-name handling for template-introduced
`var` binders; it does not invent a separate logging gensym mechanism.

### 4.1 Macro delivery dependency

Today namespace-path imports cannot carry macros: only file-module
`from "path"` imports read a dependency's compile artifact. The symmetric
`(import log [...])` surface above therefore has one explicit language
prerequisite:

> Built-in namespaces may register compiler-known template macros. A
> namespace-path import can select those macros using the same visibility,
> collision, hygiene, and head-position-only rules as file-module macros.

This is a narrow compiler/stdlib facility, useful for future standard-library
sugar as well as logging. The logging forms remain ordinary template
expansions; logging does not become a special form and `fn!` is not used on the
hot path. The implementation adds this language rule and its compiler/spec
tests before registering `error!`, `warn!`, `info!`, `debug!`, and `trace!` in
`log`.

Eager level methods are the concise default when their arguments are already
cheap values. They delegate to the lower-level `emit` primitive:

```gene
(logger ~ enabled? LogLevel/info)                  # -> Bool
(logger ~ info "ready" ^payload {})                # eager -> nil
(logger ~ emit LogLevel/info "ready" ^payload {})  # eager -> nil
(logger ~ child "worker" ^payload {^pool 2})  # -> Logger
(logger ~ with {^request_id id})              # -> Logger

# Explicit authority creates an attenuated direct-to-file logger without
# mutating hierarchical process configuration.
(var audit_debug
  (new_file_logger WriteDir "app/debug_file" "logs/debug.jsonl"
    ^level LogLevel/debug ^format "jsonl" ^flush "error"))
```

API rules:

- Logger names are non-empty `Str` values. `/` separates hierarchy segments.
- `gene/*` is reserved for the runtime and `extension/*` for host-assigned
  extension identities. Ordinary code creates `app/*` loggers (or receives an
  application-root `Logger` from its launcher) and derives descendants with
  `child`; it cannot impersonate or select a reserved route.
- `child` appends one or more validated segments. Empty, `.`, `..`, control
  characters, and empty segments are rejected.
- A logger is an immutable native object kind with unconditional `Send`
  conformance. At `new_logger`, `child`, and `with`, base-payload entries are
  validated as data, redacted, copied, and deep-frozen (including node
  metadata) before the handle becomes visible to another task or worker.
- An event payload overlays the logger's base payload; duplicate event keys
  win. Reserved event keys cannot be supplied in either payload.
- A payload is a PropMap or general map, not an arbitrary scalar/list value,
  because merge, redaction, and text rendering are key-based. Keys are symbols
  or strings. Values accept the `serde` data bucket,
  subject to logging-specific depth, item, string, and byte caps.
- `emit` returns `nil`. Boundary/programming errors—an invalid level, logger
  name, reserved field key, or non-data field value—raise the normal typed
  `TypeError`/logging usage error. Once an event is accepted, renderer and sink
  I/O failures neither raise nor report whether the event was physically
  written.
- `Logger` is not authority to create a new file sink or reconfigure routing.
  It can only emit through routes selected by the host, within its bound name
  subtree. Libraries should accept a logger from their application and call
  `child` rather than claiming a process-global name.
- `new_file_logger` is the explicit exception: it requires `Fs/WriteDir` and
  returns a logger attenuated to one newly opened file sink. It does not alter
  global routes or other loggers. Its `^level`, `^format`, `^flush`, and
  `^payload` options follow the ordinary configuration vocabulary and it is
  unavailable under wasm.

### 4.2 Why macros instead of only methods

This expression is already evaluated before an ordinary eager method can
filter it:

```gene
(logger ~ debug (expensive_render value) ^payload (expensive_payload value))
```

A thunk-based API avoids the work but allocates a closure and is awkward at
every call site. A `debug!` macro can guard evaluation with the normal
`enabled?` primitive and remains inspectable after expansion. The eager level
methods keep common call sites concise; `emit` remains the ordinary adapter
and embedding primitive.

## 5. Event model

An emitted event is immutable and Send-safe. The internal representation is a
native structure, not a general mutable Gene map. Its logical fields are:

```gene
{^schema "gene.log.v1"
 ^time "2026-07-12T18:42:13.123456Z"
 ^level "info"
 ^logger "app/http"
 ^message "listening"
 ^payload {^service "api" ^host "127.0.0.1" ^port 8080}
 ^seq 1042
 ^pid 4102
 ^thread 1
 ^source {^module "app/server.gene" ^line 42 ^column 3}}
```

Only `schema`, `time`, `level`, `logger`, `message`, `payload`, and `seq` are
conceptually stable. Runtime context and source fields are optional and
omitted when unavailable or disabled.

Decisions:

- Internally, time is captured in the runtime's native timestamp
  representation. RFC 3339 UTC is its logical/wire representation and is
  produced lazily by text/JSON renderers, not formatted during event capture.
  Local time is a renderer option, never an event-storage choice.
- `seq` is process-local, monotonic, and assigned with an atomic increment in
  threaded builds. It is useful for relating events with equal timestamps; it
  is not a durable global id.
- `thread` is diagnostic context only. Task and actor ids would be better
  semantic correlation keys, but this runtime does not yet expose stable ids
  for either. They are omitted from Stage 1. If cheap monotonic ids are later
  added at task/actor creation, optional `task` and `actor` fields may expose
  them without changing the stable schema.
- Worker-lane capture reads only worker-safe state: native time, atomic
  sequence, the pre-resolved route, immutable payload, and context stored on the
  running fiber itself. It never reaches into scheduler-global mutable tables.
  Context unavailable safely on a worker lane is omitted.
- Source capture is enabled for `debug`/`trace` by default and configurable
  for higher levels. Macro call-site metadata should populate Gene source
  without a runtime stack walk.
- Errors are structured payload entries (`error_kind`, `error_message`, optional
  bounded trace), not preformatted multiline message conventions.
- Newline and control-character escaping belongs to renderers. Every rendered
  event occupies exactly one physical line in the MVP formats.

## 6. Levels, names, and routing

Severity order:

```text
error > warn > info > debug > trace
```

`off` is a configuration threshold, not an emitted level. A route whose
effective threshold is `off` suppresses every emitted level, including
`error`.

Logger matching is segment-aware. An override for `gene/vm` matches
`gene/vm` and `gene/vm/dispatch`, but not `gene/vm2`. Names are normalized
once at logger creation:

- backslashes become `/` only at host/platform boundaries;
- repeated or trailing separators are rejected rather than silently changed;
- matching is case-sensitive;
- runtime names are stable identifiers, not absolute source paths.

Level and sink selection inherit independently down the hierarchy. At each
matching prefix, an explicitly present value replaces the inherited value;
an omitted value continues inheritance. An explicit empty sink list disables
output for that subtree.

```text
root:             level=warn, sinks=[stderr]
gene:             level=info                  # inherits [stderr]
gene/vm:                      sinks=[vm_file] # inherits info
gene/vm/dispatch: level=trace                 # inherits [vm_file]
```

Routes do not propagate additively. Replacement avoids accidental duplicate
records when both a parent and child name the same sink.

## 7. Configuration and authority

Configuration is selected explicitly by the launcher or embedding host:

```bash
gene run --log-config ./config/logging.gene app.gene
```

An embedder may install an equivalent already-validated configuration through
the native API. A future `GENE_LOG` environment shorthand may set a root level
for developer convenience, but it must not silently grant file output.

The config file is one Gene data map parsed without evaluation or imports.
Its parser reuses the ordinary reader plus `serde`'s data-only validation and
resource-limit machinery (without requiring a `serde_v1` envelope), rather
than introducing a third recursive data validator:

```gene
{^level "warn"
 ^sinks {
   ^stderr {^type "console"
            ^stream "stderr"
            ^format "text"
            ^color "auto"}
   ^main {^type "file"
          ^path "logs/app.jsonl"
          ^format "jsonl"
          ^flush "error"}
 }
 ^targets ["stderr"]
 ^loggers {{
   "gene" : {^level "info"}
   "gene/vm" : {^level "warn"}
   "app" : {^level "debug" ^targets ["stderr" "main"]}
 }}
 ^redact_keys ["authorization" "cookie" "set-cookie" "api_key" "token"]
 ^limits {^max_depth 8 ^max_items 256 ^max_string_bytes 8192
          ^max_event_bytes 65536}}
```

`^loggers` is a general map because logger names are strings and may contain
`/`; PropMap keys are symbols, and `gene/vm` in a PropMap key position would
tokenize as a path rather than remain one logger name.

Rules:

- Default configuration is `warn` to `stderr`, text format, color `auto`.
  `--debug` may override `gene` to `debug` without changing application
  routes.
- Configuration is validated completely before installation. Unknown keys,
  invalid levels, duplicate sink names, unknown targets, and unsafe paths are
  diagnostics. The launcher either rejects the config or installs a clearly
  documented fallback; partial silent installation is forbidden.
- File paths are resolved relative to the config file, not CWD.
- In the CLI, selecting `--log-config` authorizes the trusted launcher to open
  the declared files. Untrusted Gene code cannot select that file.
- A programmatic file sink requires an `Fs/WriteDir` capability and resolves
  its path through that capability. Logger creation itself needs no filesystem
  authority.
- Configuration is installed before entry-module execution begins and remains
  immutable for the process lifetime in the MVP. Workers may start lazily
  during program execution; that does not define the installation boundary.
  Startup installation eliminates configuration/file-handle replacement
  races. Runtime route materialization remains synchronized, while a safe
  registry reload protocol is deferred (§13).

## 8. Sinks and formats

### 8.1 Console sink

- Writes to stdout or stderr; stderr is the default.
- Color modes are `auto`, `always`, and `never`. `auto` respects TTY status,
  `NO_COLOR`, and `TERM=dumb`.
- The sink does not own or close process stdio.
- TUI applications should normally route diagnostics to a file. Writing
  arbitrary diagnostic lines behind ncurses corrupts the display.

### 8.2 File sink

- Opens once in append mode and owns the handle until logging shutdown.
- Creates parent directories only through launcher authority or an explicit
  `Fs/WriteDir` capability.
- Buffers writes. `^flush` supports `always`, `error`, and `close`; default is
  `error` (flush error-level records and flush everything on orderly close).
- Rotation, retention, compression, multi-process file locking, and crash-safe
  delivery are non-goals for the first version.

### 8.3 Callback/test sink

Provide an internal in-memory or callback sink for tests and embedders. It is
not enabled from untrusted data config. A callback runs outside registry locks,
must not retain borrowed native event storage, and follows the same failure
containment as other sinks.

### 8.4 Renderers

MVP formats:

- `text`: concise human output, one line per event. Example:
  `2026-07-12T18:42:13.123Z INFO app/http listening host=127.0.0.1 port=8080`
- `jsonl`: one JSON object per line using the logical event schema in §5.

Renderer and transport stay orthogonal. One event is rendered at most once per
format during fan-out. JSON Lines is the machine format because it is broadly
ingestible; it is not a persistence promise. OpenTelemetry export can later
map the same structured event without changing callers.

### 8.5 WebAssembly host sink

`geneWasm` has neither native file sinks nor a dependable process stderr.
Under wasm:

- the console sink writes through a host-provided logging callback, falling
  back to the runtime's captured-output channel when no callback is installed;
- the emergency path uses that same host callback/capture channel without
  recursively entering the normal renderer;
- file sinks and CLI `--log-config` file loading are unavailable;
- an embedder may install a validated in-memory configuration and host sink;
- the disabled path and logical event schema remain identical to native
  builds.

This mapping is part of Stage 1 so wasm does not acquire a divergent logging
API later.

## 9. Redaction and bounded rendering

Redaction occurs at both binding and emission boundaries. Base-payload entries
are redacted before they are copied into a long-lived `Logger`; per-event
payload entries are redacted as the event snapshot is constructed. The merged
structured event is therefore already safe before any renderer or sink sees
it. This prevents a safe file sink and an unsafe console sink from receiving
different secret-bearing variants of the same event, and avoids repeatedly
processing unchanged base-payload entries.

- Exact, case-insensitive field-key redaction is built in and configurable.
- Known header maps can use protocol-specific redactors before calling the
  logger (`net/http` already has a header-redaction contract).
- Values under redacted keys become `"[redacted]"`; they are never formatted
  first.
- Arbitrary message-string secret scanning is not promised. Callers must not
  interpolate secrets into message text. Applications with known token values
  may install an explicit value redactor before events enter the pipeline.
- Field rendering has depth, item-count, string-byte, and total-event-byte
  caps. Truncation is represented explicitly (`truncated=true` or a stable
  marker), never silently.
- Rendering arbitrary values must not invoke user `to_str`, constructors,
  hooks, or module loading. Accepted payload entries are data snapshots only.

Logging configuration itself can reveal file paths but must never contain
credentials. Network sinks are deferred, so the MVP has no exporter secrets.

## 10. Failure and reentrancy semantics

Logging is best effort:

- A sink write or render failure does not raise into the parser, VM, task, or
  application call site.
- The failing sink is marked unhealthy. The backend writes one bounded
  emergency diagnostic directly to raw stderr, without formatting through the
  logger, then suppresses repeated reports with a counter/rate limit.
- Healthy sinks still receive the event.
- No sink failure is reported by recursively logging it.
- An `emit` made recursively from a callback/renderer is rejected by a
  thread-local reentrancy guard and counted. Built-in renderers execute no Gene
  code.
- Explicit `flush`/`shutdown` APIs may return structured operational errors to
  the launcher. Ordinary `emit` does not.
- Panic handling may use an emergency raw-stderr path when the runtime is too
  compromised to allocate or acquire sink locks.

This contract is intentionally unsuitable for audit trails. If losing a
record must fail the operation, use a durable event/store API.

## 11. Runtime architecture and performance

### 11.1 Initialization

1. Before configuration, an emergency bootstrap logger can write `warn` and
   `error` diagnostics to raw stderr.
2. The launcher parses and validates config, opens sinks, and installs an
   immutable configuration registry. Resolved routes are immutable objects
   materialized in a synchronized append-only cache as logger names appear.
3. Runtime modules and application code create logger handles. Native
   `RuntimeLogger` values cache a direct immutable route reference. Gene
   `Logger` values keep a compact route id plus their canonical name and base
   payload; in threaded builds, resolving that id briefly takes the route-cache
   lock because the cache may grow concurrently.
4. Entry-module execution begins only after the immutable registry is
   installed. Worker threads may then start lazily without changing config.

### 11.2 Disabled path

There are two distinct budgets.

For a pre-resolved native `RuntimeLogger`, a disabled log performs:

```text
load threshold -> integer compare -> return
```

The native disabled path must not:

- normalize or hash a logger name;
- acquire a mutex;
- read a clock or thread/task context;
- construct a Gene value, event, message, or payload map;
- iterate sinks;
- allocate.

Runtime Nim call sites use templates or an explicit guard so interpolation and
string concatenation are also skipped:

```nim
if RuntimeVmLogger.enabled(llDebug):
  RuntimeVmLogger.emit(llDebug, expensiveMessage())
```

For Gene code, `debug!` expands to one `Logger/enabled?` message send plus an
enum member access and branch. It still allocates nothing and does not evaluate
the message or payload, but it is not a single native integer compare. On the
current VM a dynamic send is materially slower than a plain call; applications
must not assume native-path cost in a per-item hot loop. A statically typed
`Logger` should use a type-direct call when the compiler can select it, and the
planned send inline cache can reduce the remaining dynamic case later. The
native cached route keeps its check lock-free; Gene's route-id check also takes
the short route-cache lock in threaded builds so concurrent
`new_logger`/`child` calls cannot race the backing route table. Single-threaded
builds elide that lock entirely.

### 11.3 Enabled path

- Capture time/context and snapshot the bounded payload after filtering.
- Assign `seq` atomically.
- Fan out to pre-resolved sink references.
- Each sink has its own lock/queue and preserves the order in which it accepts
  events. There is no cross-sink ordering guarantee.
- Never hold a registry/configuration lock while formatting, writing, or
  invoking a callback.
- Renderer caches live only for one emission and are not retained by sinks.

The synchronous MVP deliberately avoids an asynchronous global logging queue.
Such a queue needs explicit capacity, overflow, shutdown-drain, crash-loss,
and priority policies. Add it only when measurements show sink I/O is harming
real workloads; do not smuggle in an unbounded channel.

### 11.4 Benchmarks and invariants

Add benchmarks before broad runtime adoption:

- disabled constant runtime log;
- disabled Gene `debug!` with an expensive expression proving it is not run,
  recording allocations and send count as well as elapsed time;
- disabled typed-`Logger` `debug!` versus its dynamic-send form;
- enabled text event with no payload;
- enabled structured event with 8 payload entries;
- fan-out to two sinks using one renderer and two renderers;
- concurrent producers to one file sink.

Required invariants:

- disabled native emission allocates zero bytes, takes no lock, and reads no
  clock/context;
- disabled Gene macro emission allocates zero bytes and does not evaluate
  message/payload expressions; its one send/branch budget is reported
  separately from the native integer-compare budget;
- logging does not change `sizeof(Value)` or zero-value semantics;
- no log check is added directly to the VM instruction dispatch loop until
  benchmark evidence justifies it;
- record all `nimble perf` before/after numbers when runtime call sites are
  migrated.

## 12. Runtime and extension integration

Use stable internal names:

```text
gene/reader
gene/compiler
gene/vm
gene/vm/scheduler
gene/stdlib/<namespace>
gene/http
gene/lsp
extension/<package>
```

The internal Nim API should expose an opaque/resolved `RuntimeLogger`, not
`log_message(level, name, message)` as the primary hot-path call. A string-name
fallback is acceptable for cold extension boundaries.

The extension ABI should provide both:

```text
log_enabled(logger_handle_or_name, level) -> bool
log_emit(logger_handle_or_name, level, message, payload) -> status
```

The enabled check is necessary; a host callback that receives an already-built
string cannot recover disabled-path cost. ABI field values should use a small,
versioned C representation or encoded JSON initially—not borrowed Gene heap
values whose ownership is ambiguous across the boundary.

Adoption rules:

- Replace only writes that are logically diagnostics.
- Keep CLI results, source diagnostics, requested traces, and user output on
  their existing channels.
- Remove ad hoc subsystem environment flags only after an equivalent named
  logger route exists. For example, `GENE_LSP_LOG=1` can map to
  `gene/lsp=debug` during migration.
- HTTP handler/access-log failures may use the emergency runtime logger, but
  application access records keep their existing structured hook.

## 13. Configuration reload is deferred

The MVP installs one immutable registry before concurrent execution. This is
both faster and safer than the legacy pattern of swapping state and closing old
file handles while another thread may hold a sink reference.

If live reload becomes necessary, it needs a real lifetime protocol:

1. Parse/open a complete new registry off to the side.
2. Atomically publish it with a new generation.
3. Logger handles detect the generation and lazily re-resolve.
4. Retire the old registry only after all in-flight emitters release it
   (reference counting or an epoch scheme).
5. Flush and close retired sinks after quiescence.

Until those steps exist, runtime mutation/reload should be rejected rather
than approximated with a global lock or risking a write to a closed handle.

## 14. Staged implementation

### Stage 1 — Internal core and contract (shipped)

- Define levels, immutable events, logger handles, route resolution, text
  renderer, stderr/wasm-host sinks, emergency path, and callback test sink.
- Default to `warn` on stderr.
- Add routing, concurrency, reentrancy, failure, and performance tests.
- Do not migrate broad runtime call sites yet.

### Stage 2 — Public `log` API (shipped)

- Extend built-in namespace registration/imports to carry compiler-known
  template macros, with the same collision and hygiene rules as file-module
  macros.
- Add `Logger`, `new_logger`, eager level methods, `enabled?`, `emit`, `child`,
  and `with`.
- Add lazy `error!`/`warn!`/`info!`/`debug!`/`trace!` macros with source
  metadata and a hygienic single-evaluation logger temporary.
- Enforce immutable data payloads, reserved keys, bounds, and pre-sink
  redaction.
- Add spec tests proving disabled expressions are not evaluated.

### Stage 3 — Configuration and file output (shipped)

- Add explicit `--log-config` loading and complete schema validation.
- Add buffered file sinks, JSON Lines, color policy, flush/shutdown, and
  capability-gated programmatic file creation.
- Add PTY tests ensuring console color policy and TUI-safe file routing.

### Stage 4 — Runtime adoption (shipped where diagnostics exist)

- Reserve stable names for reader, compiler, VM/scheduler, stdlib, HTTP, LSP,
  and extension host. Instantiate them only in modules that actually emit
  diagnostics; the shipped migration currently uses `gene/http`, `gene/lsp`,
  and the extension logging API rather than adding dormant checks to hot paths.
- Classify existing direct writes before replacing them; preserve command and
  error output contracts.
- Compare `nimble perf` before and after each performance-sensitive migration.

### Stage 5 — Optional exporters, based on evidence

- Consider bounded asynchronous sinks only with explicit overflow policy.
- Consider OpenTelemetry log export and trace/span correlation.
- Consider safe configuration reload using §13's generation/lifetime model.
- Add rotation/retention through a dedicated file-management component rather
  than growing the core emitter.

## 15. Recommended decisions to lock before implementation

1. **Default level:** `warn` to stderr. `info` by default makes a language
   runtime unexpectedly noisy and can corrupt protocol/TUI stdout behavior.
2. **Public ergonomics and laziness:** `(logger ~ info ...)`-style methods are
   eager; `!`-suffixed forms provide opt-in lazy evaluation for expensive or
   hot-path expressions; `emit` is the eager adapter primitive.
3. **Logger identity:** explicit string names only; no arbitrary `to_str`.
4. **Configuration:** data-only and explicitly selected; no ambient CWD load.
5. **Routing:** segment-aware hierarchy, independently inherited threshold and
   sink list, replacement rather than additive propagation.
6. **Machine format:** JSON Lines first; human text for console.
7. **Concurrency:** immutable startup registry, pre-resolved logger handles,
   per-sink locking, no global emission lock.
8. **Failure:** best effort with a non-recursive emergency path; never an audit
   guarantee.
9. **Security:** structured pre-sink redaction, bounded data rendering, and
   capability-gated file creation.
10. **Scope:** no async queue, reload, rotation, network exporter, metrics, or
    VM instruction tracing in the MVP.
11. **Macro delivery:** built-in namespaces gain compiler-known template macro
    exports before the public logging sugar ships; `fn!` is not the fallback.
12. **Macro naming:** use `error!`, `warn!`, `info!`, `debug!`, and `trace!` to
    mark visible rewriting and avoid poisoning common local identifiers.
13. **Two performance budgets:** native disabled logging is an allocation-free,
    lock-free integer compare; Gene disabled logging is one send/access/branch
    with no allocation or message/field evaluation, measured separately.

These decisions retain the legacy design's best architectural insight—a
single structured event routed once to multiple outputs—while fitting this
runtime's capability model, macro system, shared-nothing concurrency, and
performance constraints.
