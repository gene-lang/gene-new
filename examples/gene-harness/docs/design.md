# Gene Harness — implemented design

Status: stages 1–7 implemented. Human-reviewed promotion into checked-in
profiles remains deferred.

The normative source is [`tmp/harness.md`](../../../tmp/harness.md). This file
maps that design to the implementation in `examples/gene-harness` and records
the behavior users and tests can rely on.

## 1. Purpose and resume boundary

The harness is a substrate for a general-purpose agent. It converges the useful
parts of `examples/ai_agent`, `examples/safe_ai_agent`, and the earlier
in-memory harness prototype.

Resume means the last flushed, committed turn boundary. It does not serialize
or resume fibers, tasks, sockets, subprocesses, or partial model responses. An
interrupted turn is an event-log fact; live resources are reconstructed from
configuration and durable plugin state.

After event-catalog validation, `hydrate_harness_log` folds retained text events
into the core session log before plugins activate. The real LLM provider restores its bounded conversation
window through `PluginHost:state`, persists it with `update_state`, and `ask`
flushes the completed exchange. Resume is therefore exercised by the actual
agent path, not only by a synthetic state fixture.

Three stores have distinct jobs:

| Store | Contents | Implementation |
|---|---|---|
| composition generations | desired plugin entries and config | `src/workspace.gene`, atomic `Store/checkpoint` generations |
| module blobs | canonical generated Gene modules | owner-only atomic Store records, materialized under a workspace-keyed loader cache |
| event streams | history and full plugin state | `src/state.gene`, scoped segmented streams and projection checkpoints |

No past program is replayed.

## 2. Registry kernel

`src/kernel.gene` has one extension mechanism: named registries. The built-in
registries are:

- `seams`
- `commands`
- `tools`
- `prompt`
- `views`
- `event_types`
- `subscriptions`

Each registry defines uniqueness, deterministic ordering, row validation, and
optional cleanup. Every contribution receives an immutable `row_id`; the
ledger indexes owner to row IDs. Unloading an owner removes rows in reverse
acquisition order through the registry's cleanup hook. If a plugin owns a
registry, unloading it first removes every row in that registry and then the
registry itself.

```gene
(registry h "routes" ^owner "router" ^unique true
  ^schema validate_route ^on_remove close_route)

(contribute h "api" "routes"
  {^name "status" ^run status_handler}
  ^priority 10 ^config_order 0)

(rows h "routes")
(row h "routes" "status")
(remove_owner h "api")
```

Ordered registries sort by `(priority, config_order, owner, row_id)`, not
activation timing. Explicit replacement permanently supersedes the prior row;
unloading the replacement does not reveal an older provider.

The compatibility functions `provide`, `replace`, `resolve`, and
`bound_seams` are thin operations over the `seams` registry. Subscriptions are
ordinary owned rows whose cleanup cancels the subscription. There is no second
effect-kind table.

## 3. Plugins and the capability-safe host context

The stable generated-plugin contract is in `src/plugin_api.gene`:

```gene
(type Plugin
  ^props {^id Str ^provides Any ^requires Any?
          ^activate Any ^deactivate Any? ^contextual Any? ^events Any?})
```

Requirements and provisions may use the seam shorthand or an explicit
registry/key pair:

```gene
^requires ["HarnessFs" ["tools" "search"]]
^provides [["commands" "status"] ["prompt" "status_help"]]
```

Lifecycle states remain `pending`, `ready`, and `error`. `settle` demotes before
it promotes and continues to a fixpoint, so dependencies may arrive in any
profile order. A failed activation is unwound and remains inspectable in
`error`; it is retried only by an explicit operator action.

Generated `init` receives an inert `DescriptorContext` containing stable module
and core-interface identity only. It cannot discover registries, contribute
rows, or carry authority, so descriptor preflight is deterministic.

Only activation and later callbacks receive `PluginContext`, containing an
unforgeable Cell-identity token. The token maps to
host state in a private kernel table and supports only `PluginHost` messages:

- registry-name/key discovery;
- seam resolve/provide/replace;
- owned registry creation, contribution/replacement, and subscription;
- schema-validated, core-stamped plugin event emission;
- scoped durable state read/update.

The context remains valid for the plugin lifetime so contributed callbacks can
use state later. Demotion or uninstall expires it. A fabricated or expired
token is rejected.

Generated command and view callback receiver slots are rewritten to that
retained context; checked-in adapters may receive the Harness. Model programs
get the complete structural operation set as functions already bound to the
active transaction, but no `h` binding, so they cannot mutate Harness cells
around the ledger.
Deactivation and registry cleanup receive the still-valid owner context; it is
expired only after reverse-order cleanup completes.

## 4. Turn transactions

The turn boundary is deliberately limited, not a claim
that arbitrary I/O can be rolled back.

- registry and composition changes are made in cloned staging state;
- lifecycle logs and bus notifications are held until commit;
- abort cleans newly acquired rows and leaves committed rows untouched;
- plugin/status/policy tables stage too, committed-plugin deactivation is
  deferred, and repeated composition writes to one id coalesce to the final
  descriptor;
- replacement defers old-row cleanup until commit;
- cleanup failure produces `recovery_required`;
- panic/cancellation reaches an `ensure` path that removes the staging overlay.
- `transaction_diff` and the `diff` command expose staged registry and
  composition changes before commit.

Publishing composition `CURRENT` is the durable linearization point. Generated
plugin rows appear during post-commit reconciliation; activation failure leaves
the desired entry committed in `error`. Committed and aborted turn boundaries
are structured durable events, and a flush occurs before the next turn may be
claimed.

## 5. Event streams and plugin state

`src/state.gene` stores version-2 recovery-self-describing event envelopes:

```gene
{^format 2 ^origin "core" ^owner "core" ^projection "todo"
 ^scope "session" ^stream "s1" ^seq 7
 ^type "plugin/state" ^version 1 ^ignorable false ^payload {...}}
```

There is one workspace stream and one stream per session. An entry's `^scope`
chooses its instance and state ownership:

| Scope | Instance | Durable state |
|---|---|---|
| `workspace` | one live replica per Harness, one shared durable projection | workspace stream |
| `session` | one instance per Harness/session | that session's stream |

`PluginHost:update_state` updates the in-memory projection and appends the
versioned full-state record in one core operation. Plugins do not coordinate a
private file with memory themselves. Disjoint streams from stale processes merge
and retry; a stale write to the same ordered stream restores the winner and
raises `HarnessStateConflict` at the outer callback boundary.

Flush partitions each stream into bounded content-addressed segments, retains a
configured segment window, persists projection checkpoints, and publishes the
manifest with `Store/checkpoint`. The current manifest retains references needed
by the newest fallback generations before garbage-collecting older segment
records. Event and state byte caps reject oversized records.

Core event vocabulary comes from `events.catalog` and the generated
`src/generated_event_catalog.gene`. CI checks it with:

```bash
python3 tools/generate_harness_event_catalog.py --check
```

Plugin descriptors may add event schemas. During restore, unknown required
plugin events quarantine only that plugin projection; unknown required core
events refuse reconstruction. Ignorable records may be skipped. Cold recovery
runs only after catalog validation and appends a synthetic
`turn/end {^reason "interrupted" ^synthetic true}` for every unmatched start.
Core event keys and the `core`/`descriptor:` owner ids are reserved.
`event_types` replacement is owner-checked, and model code can record a fixed
`message` event but cannot choose an arbitrary core event type.

## 6. Desired composition and CAS

`src/workspace.gene` opens the composition Store and exposes revision-CAS
writes:

- one Gene lane serializes in-process writes;
- filesystem publication takes a short-lived crash-recoverable process lock;
- SQLite publication claims inside `BEGIN IMMEDIATE`;
- two processes racing from revision `N` both attempt generation `N+1`, and
  exactly one complete generation is published;
- the loser refreshes rather than overwriting the winner.

`CURRENT` is authoritative. A complete directory above it is unpublished crash
debris, never selected by load, and is reclaimed under the next publication
lock. Corrupt published generations fall back without crossing `CURRENT`.

Composition envelopes and event envelopes report format direction explicitly:
a newer format asks the user to upgrade; an older unsupported format says this
build ships no upgrade path. Corruption remains a separate error.

## 7. Durable generated modules

`register_module` accepts a quoted module AST:

```gene
(register_module workspace h "echo"
  (quote
    (mod plugin
      (import [Plugin DescriptorContext PluginContext PluginHost]
        from "../../../src/plugin_api")
      (import_impl PluginHost for PluginContext from "../../../src/kernel")
      (fn init [ctx : DescriptorContext] : Plugin
        ^capabilities []
        ...)))
  ^scope "session"
  ^selectors []
  ^dependencies [])
```

The registration sequence is:

1. validate a filename-safe ID and an inert quoted `mod` node;
2. unless `^replace` is set, refuse an ID the effective entry list already
   claims — the staged entries of an active transaction, otherwise the
   committed ones;
3. reject executable top-level forms and source over 256 KiB;
4. canonicalize source and compute SHA-256;
5. validate every relative import against a supplied dependency blob;
6. atomically materialize unreferenced validation cache files;
7. sandbox-load with only namespaces implied by selectors and an entry-policy
   isolation key;
8. attach the immutable module capability/budget policy, then execute
   capability-empty `init` under step/time/memory budgets and panic
   containment;
9. validate the returned descriptor without installing it;
10. atomically persist the validated root/dependency blobs;
11. commit the new composition generation by CAS;
12. register descriptor event vocabulary and activate once, after commit.

Step 2 is early because the entry list is the only thing that can answer it and
nothing before it is written. The same refusal still guards the entry list at
step 11, but reaching it there meant a name collision had already materialized
every dependency blob and the module itself, leaving cache files no entry
references and no way to tell them from ones a live entry needs. So an
unreferenced cache file now only ever comes from a preflight failure.

Dependencies are also quoted modules. `module_digest` lets a caller construct a
relative digest import, and `^dependencies` supplies the exact closure. Shared
imports are restricted to fingerprinted contract modules. Ordinary generated
code imports `plugin_api`; kernel sharing is accepted only for
`import_impl PluginHost for PluginContext`, so untrusted code cannot bind the
recovery kernel as a utility module. Restore checks every digest and interface
fingerprint before loading. A missing loader-cache file is rematerialized from
the authoritative blob Store and verified.

Activation failure does not roll desired state backward. The entry remains
committed and appears in `doctor` as quarantined.

### 7.1 Where the source comes from

`register_module` takes a quoted module; it does not care who wrote one.
`build <name> <request>` resolves the `HarnessCodegen` seam and registers
whatever it returns, so authorship is a deployment choice rather than a
constant:

| Profile | Provider | `build` means |
|---|---|---|
| `web`, `cli` | `TemplateCodegen` | fill the checked-in template; no authority, no network |
| `chat` | `ModelCodegen` | ask the bound model to write the module |

A provider returns an inert quoted node, never a string and never a live
function, and the consumer trusts none of it. Every check in the sequence above
already applied to the template and applies unchanged to a model: a
`(mod plugin ...)` root, an inert top level, a defined `init`, imports inside
the declared closure, capability-empty `init` under the module ceiling. An
author is therefore untrusted by construction, which is what makes a remote one
admissible at all.

`HarnessCodegen` has a second message for the same reason it has the first:
authorship is provider knowledge. `build` asks the resolved provider who it is
and records the answer on the durable entry as `^by`/`^model`, with `^at` from
the clock. Validation still does not care who wrote a module — that is what
makes a remote author admissible — but the record does, and until it asked,
every model-authored entry read `^by "" ^model "" ^at ""` while the thing that
wrote it stood right there.

`build` passes `^replace true`. It is the only verb that claims a durable name
and there is no verb that releases one, so create-only made iterating on a
generated tool mean inventing a name per attempt. Replacement is already a
recorded outcome: the change is logged as `replaced` rather than `registered`,
the superseded blob stays in the store, and each attempt is a revision.

The model provider sends the checked-in Gene skill (`SKILL.md`, the pitfalls
and stdlib chapters) as its system prompt alongside the module contract, and
reads the reply as data — `read_all`, never `eval` on text. One recovery is
attempted for a reply that opens with prose, and none for a reply that is not
readable Gene; a build is one turn.

Registration proves shape and `init`, never the body of `run`. `build`
therefore invokes the new tool with its own name and with the request text, and
reports a raised error alongside the revision (`ready; first call raised: ...`).
The calls are safe because a generated tool holds no capabilities and runs under
the module ceiling, and advisory because the arguments are guesses. Two probes
rather than one because a short one exercises a single branch: a length-
conditional tool passed on its nine-byte name while its long path was broken.

### 7.2 What the model's own program may reach

A reply's `^code` is evaluated in an `Env` minted with the structural harness
bindings and `^capabilities []`. The two authorities are deliberately opposite:
structural authority over the harness is total, because every binding is an
ordinary Gene call needing no grant and rebuilding the harness is the whole
point; host authority is nil, so reading a file or the environment comes back
as a `refused: ...` value the next round is shown.

`register_module` is the one operation that needs both, and a grant only ever
attenuates (§8) — nothing called from inside an empty context can recover the
authority that hashing source, writing a blob, loading the module and running
`init` require. Calling straight through refused at `fs/exists?` and lost the
turn, which made the durable path the prompt advertises unreachable.

So the binding queues instead. It validates that the id is a non-empty `Str`
and the source an inert `mod` node, appends the request to the turn's queue,
and says so. After the program returns, still inside the same
`run_workspace_turn` body but back under the harness's own capability context,
the queue is drained through the ordinary `register_module` path and the result
string reports each committed revision. A registration that fails to load
raises like any other error in the body, so it never becomes a revision.

The consequence is part of the contract and is stated in the prompt: a tool
registered this way is callable from the *next* program, not the one that
queued it. The turn body also carries an explicit budget rather than the 2 000
ms callback default, because a body that may hash a module, write a blob, load
it and run its `init` is not a local computation. Steps and memory are
unchanged.

## 8. Execution supervision and attenuation

Gene `Env ^policy` now enforces:

- transitive maximum steps across calls into module-defined functions;
- wall-clock timeout;
- incremental process-memory ceiling;
- disabled FFI and native compilation.

`runtime/guard_call` is the explicit supervision boundary that turns a Gene
panic into a data failure for the recovery kernel. Cancellation remains a
control signal. The loader also installs an immutable execution policy on the
sandbox module root. Every later external entry creates a fresh budget and
intersects the caller with that module ceiling, including escaped functions and
direct typed protocol methods that never pass through a registry wrapper.

Capability selectors stored in composition are inert maps:

```gene
{^type "fs/ReadDir" ^root "workspace" ^path "docs"}
{^type "fs/ReadWriteDir" ^root "state" ^path "cache"}
```

Only the named roots `workspace` (package root) and `state` (harness state root)
exist in version 1. Relative traversal and absolute paths are rejected. At
activation the harness expands the map to an ordinary absolute capability
selector and evaluates the activation under `with_capabilities`. Resolution is
against the application's immutable host ceiling and therefore fails rather
than widens. Namespace visibility in the module sandbox is not authority; the
active capability context remains the native enforcement boundary.

A profile may carry `^limits`, applied to every plugin it installs with the
capability context left inherited. The default budget suits a callback doing
local computation; a deployment whose author is a remote model has commands
that legitimately block on a network round trip, and there the default is not a
guard against runaway code but a guarantee that the deployment cannot work.
Steps and memory are unchanged by that choice — only the deadline moves.

Generic command/tool/seam callbacks, schemas, cleanup hooks, subscribers, and
views additionally pass through owner-aware wrappers. The core boundary flushes
state only after the attenuated callback scope unwinds, so opaque retained Store
authority is never lent to plugin code.

A budget bounds a unit of work, so the unit has to be chosen where the work is,
and it must not contain a wait. `HarnessView` therefore has two messages —
render the prompt, handle the line — each returning `nil` to be called again,
and the owner-aware wrapper enters each once, so both draw a fresh deadline and
a fresh step/memory allowance. The caller owns the loop and the blocking read
that sits between them; the read is under no budget, because reading the
process's own stdin is host authority rather than plugin work.

Both properties were learned the same way. A view that owned its loop drew one
budget for the whole conversation and an interactive shell died two minutes in.
Moving the loop out but leaving the read inside only moved the failure: the
turn that printed the prompt was the one that expired, and the diagnostic
surfaced at the first budget check after the keystroke — a line with nothing to
do with the cause.

## 9. Phased boot and recovery

Boot is ordered to break the event-schema/state cycle:

1. read the composition generation using core formats;
2. bounded-load every descriptor without activation;
3. register event schemas from valid descriptors;
4. validate/fold event streams and state projections, then repair interrupted
   turns;
5. quarantine missing or incompatible plugin projections;
6. settle and activate the remaining descriptors.

One entry cannot refuse the workspace. Missing blobs, digest/interface
mismatches, invalid descriptors, exhausted limits, and panics become attached
quarantine reasons. Dependents remain `pending`.

The irreducible core recovery surface is independent of plugins:

- `doctor`
- `enable <id>`
- `disable <id>`
- safe shutdown/flush

`disable` and `enable` run before descriptor or profile activation. `doctor`
bounded-loads descriptors and validates their event vocabulary without
activating them. Normal boot performs the same read-only preparation before any
effectful baseline profile plugin. A recovery shell is not implicitly granted,
and shutdown reverses plugins before closing stores.

## 10. Commands, tools, prompt, and views

The command interpreter no longer contains a command-name branch chain.
`command_plugin` contributes command rows with `name`, `doc`, and `run`;
`dispatch` looks up the row. Help is rendered from those same rows.

Generated tools contribute `tools` rows rather than `Tool:*` seams. A durable
build therefore extends `tools`, help/introspection, and behavior without core
knowing the tool name — or, under `chat`, without anyone having written the
tool: `build` resolves `HarnessCodegen` (§7.1) and the row comes from whatever
that provider authored.

Prompt sections are ordered `prompt` rows. `render_prompt` combines pushed rows
with live registry key introspection; `doc` returns pull-only rows from the same
registry. The checked-in `tools/gene-lang-skill/SKILL.md` is pushed and its
reference chapters are pull-only. The old handwritten Gene primer is gone.

Views replace the one `views/active` row. The loop over a view's turns belongs
to `main.gene`, which re-reads that row between turns — which is the whole of
handoff: a replacement committed during a turn takes effect at the next prompt,
an absent row ends the session, and no view has to check for its own successor.

User-visible agent output is a typed durable core event; terminal and recording
views consume the same feed. A recording view plus the command-agent stub
provides deterministic tests with no terminal or network.

## 11. Entry point and filesystem layout

`main.gene` uses `GENE_HARNESS_HOME`, defaulting to
`examples/gene-harness/tmp/workspace`, and creates:

```text
<home>/
  composition/   Store generations and CURRENT
  modules/       immutable content-addressed module Store records
  events/        event segments, projections, generations and CURRENT

plugins/generated/
  <workspace-sha256>/
    <module-sha256>.gene  verified loader cache (ignored by git)
```

An external home must be granted by the launcher with
`--allow_read_write_dir`. The environment variable chooses a path; it does not
mint filesystem authority.

Core first prepares authored descriptors and validates their event schemas.
Baseline profiles then install checked-in provider/agent/view plugins, and the
prepared desired entries activate. On exit, core reverses plugins, flushes
events, and closes all three stores.

## 12. Implementation map

| File | Responsibility |
|---|---|
| `src/kernel.gene` | registry, ledger, transactions/diff, lifecycle, PluginContext, prompt/output events |
| `src/plugin_api.gene` | stable generated-plugin types and protocol |
| `src/state.gene` | scoped durable event segments and full-state projections |
| `src/workspace.gene` | composition CAS, blobs, register/restore, quarantine |
| `src/agent.gene` | registry-backed commands, tools, offline prompt provider |
| `src/llm.gene` | model provider; prompt rendered from registries |
| `src/repl.gene` | terminal view plugin |
| `src/view_api.gene`, `src/recording_view.gene` | typed view contract and deterministic recording view |
| `src/profile.gene`, `src/profiles/` | checked-in baseline composition |
| `src/main.gene` | durable boot, recovery nucleus, view/one-shot dispatch |

Runtime support used by the harness lives in `src/gene/vm.nim` (transitive and
module-entry budgets, immutable module ceilings, panic guard),
`src/gene/stdlib.nim` (exclusive Store generations and atomic text writes), and
`src/gene/fs_capabilities.nim`
(missing intermediate path is a false existence result, while symlinks still
fail closed).

## 13. Tests and deferred work

Public-seam smoke programs live in `examples/gene-harness/tests/` and are run by
`tests/test_cli.nim`. They cover registries and cleanup, seam migration,
transaction diff/abort/commit, event retention/catalog/concurrency and cold
repair, cross-process Store claims, workspace CAS, module registration/reopen
and cache rematerialization, dependency closure/shared-contract confinement,
quarantine, named-root attenuation, callback and typed-provider supervision,
plugin events, active-view output/swap, prompt-skill loading, provenance audit
and recorded build provenance, queued registration draining at the turn
boundary, build replacement, duplicate-id refusal writing no blob, and
session/workspace state conflicts.

Still deferred:

- human-reviewed promotion into a checked-in profile;
- protocol migration beyond strict interface-fingerprint refusal;
- cross-workspace sharing/GC of module blobs;
- restoration of live in-flight resources (explicitly outside the resume
  boundary).
