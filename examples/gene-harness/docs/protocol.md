# Harness protocol

The loop owns this response and record contract. [Design](design.md) explains
ownership and lifetimes; feature APIs live in their registered chapters.

## Code response pipeline

A turn builds instructions and history, invokes the provider, reads the raw
response, applies its patch, evaluates code, and interprets the final value.
The provider row is selected once from the turn's leased composition, so a
summary and main call use the same row. The loop owns every protocol record.
Its order is:

```text
request/prepare hook -> turn/request (full and settled next item)
turn/start -> prompt rows -> history/compact policy
  summary call, if needed: prepare -> model/request -> send -> model/result
prepare -> model/request -> send -> model/result
turn/response -> split, patch, evaluate, Outcome -> turn/end
```

`model/request` records the exact immutable value returned by the selected
provider row's `prepare`. The same value is passed to `send`; authentication
and transport details may be added afterward, but model-visible content may
not. Large strings in the prepared value are stored as content-addressed
blobs, so unchanged history parts share blobs across calls. The request record
is flushed before transport. Literal maps that resemble blob references are
escaped. Each logical call has one call id and one `model/result` per attempt.
The loop retries one reported timeout; each result records outcome, finality,
wall-clock time, elapsed timing and any provider usage. The successful main
result is linked from `turn/response`. Compaction summary calls use the same
path and are marked `history/summary`.

Provider errors, timeouts and cancellation produce results before the turn
ends. If a process stops with no final model result, recovery adds an
`interrupted` result with outcome unknown. Turn finalization is idempotent
across the loop, round controller and cold recovery. An error before model
dispatch writes a failed turn end with its stage and no invented model call.

Instructions come entirely from ordered `prompt` rows: the loop's response
grammar first, essential mounted plugin orientation next, and dynamic workspace,
session and discovery instructions last. Full manuals and callable catalogs are
loaded on demand. `working_instructions` owns the default goal-comment,
progress-reply, discovery and verification preferences. It is optional and
replaceable; response grammar, runtime constraints and helper contracts stay
with the host. `gene_reference` contributes a short language orientation;
the Gene skill is the `gene/overview` docs chapter. Plugin administration and
triggers contribute searchable functions and owned docs rather than full prompt
sections. The web entry contributes a short browser orientation.
`gene_reference` makes the `harness/web_components` chapter available, and
`ui_experiment` contributes configuration and preview functions. Prompts
submitted through the CLI can author and preview UI plugins in the same host.
Pull-only chapters come from `docs` rows and are read with `doc`. `discover`
searches active contribution metadata with kind/owner filters and pagination,
without reading chapter bodies or invoking callbacks. Its results include owners,
short summaries, signatures/usage and chapter references. Optional summary, tags
and docs fields support the same practice in generated plugins. Both helpers
use the caller's leased composition; no separate catalog is stored. Focused UI
recipes cover forms, drafts, revisions, configuration and verification. See
[discovery](discovery.md). Credentials are private transport inputs.

A response contains zero or more Gene forms followed by raw blocks:

```text
response   := code? block*
code       := Gene forms; the value of the last form is the outcome
block      := attachment | patch
attachment := "<<<" name SP terminator NL line* terminator (NL | EOF)
patch      := "*** Begin Patch" NL ... "*** End Patch" (NL | EOF)   at most one
name       := [A-Za-z0-9_.-]+, unique within the response
terminator := a token without whitespace, never a whole line of the body
```

```text
<<<name END
body preserved byte for byte
END
```

A block starts only at the beginning of a line. The code is the text before
the first block-start line whose preceding text reads as complete Gene forms,
so `<<<` inside a Gene string does not start a block. Only blank lines may
separate blocks. An unterminated block, a duplicate attachment name, a second
patch, other text after the blocks, or unreadable code is a read error, which
the next request reports. Line 1 is the first line of the response, so a
reported line maps directly to the model's own text. A response without code
takes the patch result as its outcome.

Code accesses the body through attachment. A response may contain one V4A
apply-patch block. Edits are workspace-relative. Preflight resolves all anchors
and computes all new bodies before any write. Matching tries exact, trailing
whitespace-insensitive, then leading/trailing whitespace-insensitive context,
requiring a unique anchor.
EOF can terminate the final block. CRLF structure is accepted without changing
attachment bytes. Patch hunks accept blank context lines, an implicit first
hunk, and insertion after an anchor without removed lines.

Temporary siblings are staged, then renamed in order; deletes and moves
follow. A write failure attempts restoration from the in-memory originals.
Updates and rollback preserve file permissions; symlink updates replace the
target's content while retaining the link. Physical destination aliases are
checked before staging.
Restoration failure reports partial application and attention. Before staging,
turn/response durably records the affected file list. Recovery reports possible
partial application and removes leftover staging siblings. A gate shared by
sessions in the same canonical workspace covers preparation, durable response
recording, commit and rollback. Each patch therefore prepares against the
previous patch's committed content. Shell commands and direct `$fs` writes
still require coordination between their authors.

Ordinary child sessions add durable delegation, waiting and result delivery to
the session machinery; see [Sub-agents](sub-agent.md). The host owns scheduling,
ownership and recovery behind `DelegationHost`, while the built-in `delegation`
plugin contributes the model-facing functions and prompt policy.

Patch failure skips code. Otherwise the forms execute in an Env whose bindings
are exactly:

| Group | Names |
| --- | --- |
| Loop | `Outcome`, `append_prompt` (rewritten to `append_prompt_at`), `attachment`, `recall` |
| Context | `session_id`, `workspace_root`, `discover`, `doc` |
| Functions | every row of the leased `functions` registry, by name; the built-in plugin and trigger functions appear only while their plugins are active |

The whole standard library is reachable through `$`. Relative paths resolve
against the workspace root, which is the process's working directory.
Evaluation happens in `agents/eval_site`, a module that defines and imports
nothing else, so a response that defines `h` cannot collide with Harness
internals. Located reading preserves source lines and columns through
evaluation, so errors report `line L`.

Before evaluation, each `(append_prompt "label" value)` call site is rewritten
to record its line and its original form. The label must be a literal string
matching `[a-z0-9_]+`. `(attachment "name")` returns the attachment's exact
text, and `(recall "57.smoke")` returns the full body of an elided item from
this session. Unknown names and ids are errors.

Each `(card "id" ...)` call site is rewritten to `card_at` with its line, and
its `^view` and `^update` functions, which must be literal `fn` forms, are
quoted. A card keeps their source and evaluates it in a fresh environment on
every call, so it never depends on the turn that made it. `card_update` and
`card_state` change and read a card. See [cards](cards.md).

| Last value | Effect |
| --- | --- |
| Outcome done + non-empty reply | Finish the round and display the reply |
| Outcome prompt | Continue with the prompt and appended outputs |
| Outcome questions | Persist the batch and wait |
| Outcome with a checked suspension extension | Let its owning participant suspend the round |
| Plain value | Continue with a labeled result |
| Reader/runtime/patch error | Continue with a labeled diagnostic |

Done rejects prompt/questions. Participants may defer completion when they
produce new context. Once completion is settled, unused appended prompt items
are dropped with a console note. A continuing Outcome needs a prompt, appended
output or an admitted owned suspension. Progress replies do not finish a round.

Console printing is never a model request item. `$print` and `$println` in
response code, in the plugin functions it calls, and in tasks they spawn write
to the session's console sink through the task context. The browser receives
`console` messages. The browser overlays them as collapsed, turn-owned live Output
disclosures; it does not hydrate output from snapshots or history. Page reload
clears this display. The CLI can still read diagnostic transcript records. Ignorable
`console` events are capped at 256 KiB per turn with a truncation marker.

```gene
(type Outcome ^props {^done Bool? ^prompt Any? ^reply Str? ^questions Any?
                       ^attention Bool? ^extensions Any?})
```

The `Outcome` binding is a constructor derived from the same leased extension
rows used by schemas and participants. Declared short spellings such as `wait`
and `audio_reply` translate to owned extension keys before the core value is
built. Supplying both spellings is an error. Feature schemas own their data and
restrictions; [turn participants](turn-participants.md) specifies suspension
admission and participant completion.

`^^attention` flags the session for the operator. An operator round defaults to
24 turns; reaching the limit pauses it and retains the unsent input. Continue
admits a linked round with another budget, while Continue until finished admits
successors automatically and shows cumulative task turns. The browser hides the
unrun turn. Trigger rounds default to 12 turns and retain their existing failure
and parent/trigger completion policies.

### Next request

A request is text with one item per output, in this order: patch result,
append_prompt items in call order, the Outcome's prompt, errors, answers.

```text
[57.patch] applied: src/report.gene +40 -0 (new)
[57.smoke] line 7: (append_prompt "smoke" (run_smoke "fixtures/orders.csv"))
ok 12 records
[57.result] line 9: Outcome ^prompt
report written; smoke output above
```

- Ids are `<turn>.<label>`. A repeated label gets a suffix, `smoke#2`.
- A header from code reads `line L: <form>`, with the form printed and cut to
  100 characters. An item appended by a plugin function reads `fn <name>`.
  An error header shows the failing line when it is known.
- A Str value is sent verbatim; any other value is printed as Gene data.

A round's first request is the user's prompt, preceded by the items of slash
commands that explicitly attach since the previous user request, such as
a `/view` file pointer. `/run`, `/sh` and `/repl` remain in the operator transcript.
A trigger round's first request is the
trigger's request text prefixed with `[trigger <id> occurrence <occurrence>]`.

### Questions

A batch holds one to eight questions. Each has a unique `^id` and a non-empty
`^prompt`. `^choices` is optional; without it the answer is free text.
`^^multi` allows several choices, `^kind "confirm"` asks yes or no, and
`^recommended` must be one of the choices. Plugins add question kinds as rows
of the `interactions` registry, which validate both the question and its
answer; an optional `render` draws the kind's question view.

The operator may answer any subset or dismiss the batch. Submission is final;
the round resumes with a new turn whose request carries
`[58.answers]` and the frozen answer map, such as
`#{^db "postgres" ^wipe unanswered}`.
Re-sending the same answers is accepted, and conflicting ones are rejected.
A retry is compared with the digest of the reply as submitted before any
validator or round admission runs, so it succeeds after a validator changes
or after the session moves on, and it never resumes a round again.
Batches are durable (`question/asked`, `question/answered`) and survive
restart. Cancelling the round cancels its questions.

Finalizing a batch records the intended round action with it: answers and
dismissal continue the round, Cancel round cancels it. If the process stops
between finalizing the batch and updating the round, recovery applies exactly
that recorded action once: a recorded continuation resumes with the recorded
request, a recorded cancellation cancels without a model call, and a batch with
no recorded action is interrupted. A question may also carry a `^view`, a card
tree whose answer buttons select draft values (see [cards](cards.md)).

## Plugin contract

A plugin is a Gene `mod` whose `init` receives an inert DescriptorContext and
returns a Plugin. `^activate` is the activation function itself and receives
the host; a plugin keeps the host for later callbacks.

```gene
(mod plugin @interfaces {^core "gene-harness/PluginHost:3"}
  (import ^from "src/plugin_api.gene" [Plugin PluginHost])
  (fn init [descriptor]
    (Plugin ^id "line_counter" ^provides [["functions" "count_lines"]]
      ^activate (fn [host]
        (host .PluginHost:contribute "functions"
          {^name "count_lines" ^doc "Count non-empty lines in a file."
           ^fn (fn [path : Str] : Int ...)})))))
```

| PluginHost message | Purpose |
| --- | --- |
| `execution_budget []` | Current callback execution limits |
| `defer [cleanup]` | Activation-owned cleanup after its final reader |
| `registry_names []` | Inspect registry names |
| `row_keys [registry]` | Inspect selected keys |
| `rows [registry]` | Immutable selected row payloads |
| `row [registry key]` | One immutable selected payload |
| `run_hooks [point context]` | Dispatch at a declared generic hook point |
| `create_registry [spec]` | Declare an activation-owned registry |
| `resolve [seam]` | Resolve a selected service handle or value |
| `provide [seam value]` | Provide a seam |
| `replace [seam value]` | Explicitly replace a seam |
| `contribute [registry payload]` | Contribute an owned row |
| `replace_contribution [registry payload]` | Explicitly replace a row |
| `subscribe [selector handler]` | Observe the public event surface |
| `emit_event [name payload]` | Validate and append an event type owned by this plugin |
| `state [^session session = nil]` | Read workspace or explicit session state |
| `update_state [value ^session session = nil]` | Append managed state with the executing writer's provenance |
| `notify [message]` | Publish a source-owned notification |
| `notifications []` | List this source's notifications |
| `notification_update [id changes]` | Update this source's keyed publication |
| `notification_clear [id revision]` | Clear this source's message with a revision check |

These 21 messages are declared in `src/plugin_api.gene`. `NotificationHost` is
the separate operator-inbox seam; see [notifications](notification.md).

The registries are `functions`, `commands`, `input_modes`, `prompt`, `docs`,
`providers`, `image_generators`, `speech_recognizers`, `speech_synthesizers`,
`hook_points`, `hooks`, `interactions`, `web_components`, `browser_clients`,
`ui_actions`, `ui_links`, `event_types`, `subscriptions`, `seams` and `triggers`.
Normal runtime boot also installs `turn_participants`, `outcome_extensions`
and `initiators`; their [transaction contract](turn-participants.md) defines
leased dispatch, owned model fields and persisted source policy. A
`functions` row is `{^name ^fn ^doc}`. Names are unique across the workspace,
and discovery returns each with its captured `$runtime/signature` and short doc.
Contributions may add a summary, topic tags and docs chapter references. A
`prompt` row has `^name` and exactly one of `^text` or callable `^render`;
`docs` rows have `^name` and `^text` or `^path`. The core reserves command
names by owner: `core_commands` owns `/help`, `/run` and `/view`, `shell` owns
`/sh` and its input mode, the loop (`core`) owns `/cancel`, `/stop` and
`/restart`, `core` also reserves `/theme`, and `repl` owns `/repl`.
The [versioned plugin contract](plugins.md#interface-versions-and-callback-contexts)
uses version-3 opaque receivers and public command/prompt projections, and
rejects retired stored interface versions. Exact entry requirements are checked
against host-supported version sets, including on historical reversion. The
terminal-view contracts have been retired without rewriting archived source.
The shared API requirement is `gene-harness/Plugin:3`; the receiver requirement
is `gene-harness/PluginHost:3`. `plugin_api` contains declarations only.
`src/public/response.gene` exports `append_prompt` and `show_card` helpers.
`append_prompt` forwards to the current turn and labels the item `fn <name>`.
Outside an open turn it raises `TurnClosed`.

`(register_plugin id source ^dependencies [...] ^!replace)` takes a quoted
`mod` form, or text such as an attachment that reads as one form. It
validates the source, preflights `init` under its bounded budget, stores
content-addressed module blobs, and queues the composition change for the turn
boundary. A failing `init` makes the call fail and stores nothing. An entry
whose activation fails, or a stored entry that no longer loads at boot, is
quarantined; `doctor`, `enable`, `disable` and `restore` repair it.

Model adapters are `providers` rows. The profile may pin one; otherwise the
environment, `config.gene`, then the lowest available `^auto` rank select it.
Each row reports cheap availability, configures public model settings,
prepares model-visible input as plain data, and sends one transport attempt.
The loop retries one HTTP timeout. A missing or unavailable selected provider
refuses round admission with `not_ready`; the same check runs before each
turn. The `triggers` plugin resolves `TriggerHost` through `triggers/host`.
The host owns durable definitions and occurrences; plugin activation owns the
scheduler. Disabling it stops scheduling, and its HTTP routes report unavailable.

Long-lived background work belongs in a plugin's activation effect scope,
not in a detached task from response code. Its console output goes to the
workspace log, and it cannot append to a turn.

## Transcript and history

The transcript is the complete durable record shown to the operator: requests,
response code/stubs, patch results, replies, questions, commands and console.
History is the model-facing view, with console excluded.

The canonical event vocabulary is [events.catalog](../events.catalog), with
payload validators in `src/storage/generated_event_catalog.gene`. It includes
core records and feature records such as card and delegation state. The
repository's `tools/generate_harness_event_catalog.gene` generates both files;
`--check` verifies them. This reference does not keep a second enumeration.

The loop allocates numeric session turns and records one ending for each
started turn. `turn/request` describes the receiving turn's input, rather than
the complete provider context. `model/request` and `model/result` record the
actual prepared input and each transport attempt. Console and trace records
are ignorable diagnostics. Required core payloads are validated before repair.

Output bodies larger than 16 KiB retain bounded head/tail text. Request items
share a 64 KiB aggregate limit. Bodies over 16 KiB settle to labeled stubs after
their first full context. The active round's initiating request is preserved,
including when its older intermediate messages are compacted. The latest
assistant response stays full through its following request, including failed
patches; older attachments and patches settle to stubs. Transcript events
always use the compact rendering.
Recall maps ids to verified content-addressed blobs and survives restart.
Loaded history is cached in the session. Older full request bodies are replaced
by their settled form in storage. Periodic idle blob collection retains the
latest references and the event store's fallback generations.

Settlement can change the previous full request and the assistant body from
the preceding turn; older message content remains stable. The
`budget_advisory` hook adds `[harness_budget]` to the full request only; its
settled form omits that item. A limit continuation replaces only its identified,
unsent trailing request with fresh preparation, preserving settled input and
media; it does not append that request twice. Automatic continuation explains
the mode instead of counting down to forced completion at every round boundary.
Anthropic transport places cache checkpoints
on the last two assistant messages. Compaction is the exceptional operation
that rewrites old history.
The stable-prefix invariant compares serialized message-content bytes from
actual provider requests, excluding cache-control metadata. Moving those
checkpoints can change older wire JSON while preserving the content boundary:
all messages through the previous assistant response remain byte-identical,
and its following full request is the first content message that settles.

Tokens are estimated from bytes when no provider count is available. The
`history_basic` hook decides at 75% of the configured window; by default,
compaction first keeps comments, append_prompt and Outcome lines with stubs.
A policy can disable that elision, protect named rounds and customize summary
instructions. Retained rounds keep their existing representation through both
elision and summarization. If more reduction
is required, one provider call
summarizes old whole rounds into a durable history/summary message. The newest
request is preserved; the default policy target is below 55%. If protected
context cannot fit, the host fails without publishing replacement history.

Session collection removes its index entry and stream. Blob writers lease
the store through admission and receipt publication. Collection closes new
body-writer admission and runs at an idle opportunity, preserving every body
reachable from remaining workspace/session projections.
