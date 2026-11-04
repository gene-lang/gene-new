# Quick decisions and round check-ins

A quick decision answers a narrow question about a small state. It returns
probabilities over options the caller defined. It writes no text and runs
nothing, and the caller always has a default action. The main model is the
Harness's slow, deliberate layer; a quick decision is the fast one that only
chooses among options the caller already accepts.

Three properties make it safe to call from the turn loop:

- **Bounded.** The caller sets a timeout. A missing answer delays nothing
  beyond it, and the caller applies its default.
- **Closed.** An answer only picks one of the caller's options. A wrong or
  manipulated answer can pick a wrong option, never a new action.
- **Cheap.** It sends a small state and makes one round trip. It adds nothing
  to model context or history.

The first use is **round check-ins**, which replace the turn limit as the
reason a long task stops. Voice turn-taking will use the same service later;
it is not implemented yet.

## The decide call

```gene
(decide ^use "round/check_in" ^state state ^questions questions
        ^timeout_ms 10000 ^fence fence)
```

A successful call returns:

```gene
{^status "ok" ^engine "jev" ^model "jev-1.14.0" ^latency_ms 140 ^attempts 1
 ^answers {^progress {^choice "advancing" ^confidence 0.82
                      ^probabilities {^advancing 0.86 ^verifying 0.08 ^repeating 0.03
                                      ^blocked 0.02 ^drifting 0.01}}
           ^operator_now {^value 0.12}}}
```

Otherwise it returns `{^status S ^reason "..."}`, where `S` is `unavailable`,
`timeout`, `rate_limited`, `too_large`, `stale` or `error`.

- **Errors.** Engine and transport problems never raise. Malformed questions
  do raise `ServiceError` with code `invalid_request`, because they are a
  caller bug.
- **`use`** is a stable id such as `round/check_in` or `code/decide`. It
  selects the engine and appears in traces.
- **Questions** map snake_case ids to one of three portable types, which are
  TypeSafe Jev's primitives:
  - `{^type "choice" ^instructions ^criteria {^option "description" ...}}`
    with 2 to 255 options. Answers carry `choice` and `probabilities`.
  - `{^type "score" ^instructions ^criteria ["lowest level" ... "highest"]}`
    with 2 to 10 ordered levels, numbered from 0. Answers carry `score` and
    `probabilities` keyed `"0"`, `"1"`, and so on.
  - `{^type "noul" ^instructions}`, one value from 0 to 1. Answers carry
    `value`.
- **`fence`** is caller data. If it has an `^active` function that returns
  false when the answer arrives, the status is `stale`.

Write instructions literally and positively, and keep numbers the engine would
have to compare out of the state.

### Central validation

Strict JSON does not make answers closed, so the service checks every engine's
reply before returning `ok`:

- every requested question id is answered with its type's fields;
- each `choice` names one of the given options;
- every value is a number in [0, 1], and a score lies within its levels;
- each distribution covers exactly the options and sums to 1 within 0.02,
  and is then normalized.

Invalid output is status `error`. It is never a caller exception and never an
accepted answer. Answers to questions that were not asked are dropped.

### Deadline, retry and cancellation

`^timeout_ms` (default 10 s, at most 120 s) covers the whole call: opening the
engine, any retry and parsing. The service retries at most once, only for
`rate_limited` and `error`, and only if time remains. The engine call runs as
a supervised task. The deadline cancels it, and so does cancelling the caller,
for example Stop on a round, so a late answer's work is stopped rather than
ignored. The `model` engine calls `call_model` with `^!retry_timeouts`, so
retry policies never stack.

### Size limits

The service estimates the state plus the questions plus the engine's prompt
overhead at 2.4 bytes per token. That ratio is what Jev reported for
code-heavy check-in states (see the
[verification record](verification/check-in-jev-2026-11-03.md)). It checks the
estimate against the engine's request and per-question limits. A request that
is too big returns `too_large` without being sent. The caller trims in a way
it controls: check-ins drop the oldest turns. An engine's own size rejection
also maps to `too_large`.

### Traces and notices

Each call writes one ignorable `decision` event: use, engine, model, status,
latency, attempts and answers. The trace never includes the state. A use whose
answer drives control flow keeps its own durable record, as check-ins do.

The first time an engine is unreachable for a session (`unavailable`,
`timeout`, `rate_limited` or `error`), the service posts one warning notice
from the `decisions` source.

## Reaching the service

The host owns the service, published as the `decisions/host` seam with the
`DecisionHost` protocol: `decide request`, `engines` and `status ^use`. It is
also `workspace/services/values/decisions`. The built-in `decisions` plugin
contributes:

- the `jev` and `model` engine rows;
- the `decide` and `decision_engines` functions, so response code, `/run`, the
  REPL and cards can call it;
- the `harness/decisions` chapter;
- the Decisions settings group, whose section lists the engines and their
  availability.

Disable the plugin and no engine is installed. Every use then applies its
default, and round check-ins are off, so rounds pause at `turn_limit`. Another
plugin can still contribute an engine row of its own.

## Engines

The `decision_engines` registry holds rows of the form
`{^name ^doc ^summary ^auto ^available ^open ^close ^decide ^limits}`:

| Field | Meaning |
| --- | --- |
| `available settings` | nil when usable, otherwise a reason string |
| `open settings` | Returns the resource that `decide` and `close` receive. The host caches it per row and settings, and it closes with the contributing activation |
| `decide resource request` | `request` has `^use ^state ^questions ^settings ^timeout_ms ^deadline_ms ^fence ^model`. Returns `{^answers ^model ^usage ^call_id}` or `{^status ^reason}` |
| `limits settings` | `{^request_tokens ^question_tokens ^overhead_tokens}` |
| `auto` | Optional rank for automatic selection; lower wins |

`request/model` is a host function for engines that use a configured model:
`(request/model {^messages ^max_tokens})` returns `{^text ^call_id ^provider
^model}`.

| Engine | What it is | Latency measured 2026-11-03 | Where the state goes |
| --- | --- | --- | --- |
| `jev` | TypeSafe's System One API, `POST /v1/systemone`. Needs `TYPESAFE_API_KEY`. `^model` pins a version; the default is `jev-1.14.0`. Limits 60k per request and 30k per question, a margin under the documented 64k/32k | p50 about 80 ms at 500 tokens, 175 ms at 17k and 275 ms at 32k | TypeSafe |
| `model` | The questions as a JSON-only prompt through `call_model ^purpose "decision/<use>"`, with its own selection: `^preset` from `models.gene`, or `^provider`, `^model` and `^effort` (default `low`). Available only once one is configured | Seconds | The selected provider; a local endpoint keeps it on this machine |

The `model` engine's selection is its own snapshot, so launch and profile
pins on the main model do not redirect it. Its call is recorded like any model
call, as `model/request` and `model/result` with the decision purpose.

### Selection

The `decisions` setting is a map:

```gene
^decisions {^engine "jev" ^model "jev-1.14.0"
            ^uses {^"round/check_in" {^engine "model" ^preset "fast-judge"}}}
```

For each call, the use's entry wins, then the default entry. If neither names
an engine, `jev` is used when it is available, then the available row with the
lowest `auto` rank. An engine named by an entry is binding. If it is missing or
unavailable, the status is `unavailable`, and no other engine is tried, so a
selection made for privacy never silently falls back to a cloud engine.

### Privacy and cost

Check-ins send the task's request and up to 30 recent responses, including
code, paths and output excerpts. With `jev`, TypeSafe is a second recipient
besides the main provider. `jev` is the default when `TYPESAFE_API_KEY` is set,
so a host started with that key sends check-in states to TypeSafe unless you
select another engine. With `model` on the provider you already use, or on a
local endpoint, no new party sees the work. Jev charges $0.042 per million
input tokens, so a 17k-token check-in costs about $0.0007.

## Round check-ins

### Modes

An operator round has one of three continuation modes:

| Mode | Behavior |
| --- | --- |
| `checked` | No fixed ceiling while check-ins answer. Every `check_in_turns` task turns (default 10), the loop asks the decision service whether to continue or pause for you |
| `manual` | Pauses at `turn_limit` (default 24) and never asks |
| `automatic` | Continue until finished: never checks and never pauses at a limit |

New operator rounds are `checked` when `check_ins` is on (the default) and an
engine is available for `round/check_in`, and `manual` otherwise. **Continue**
keeps a checked task checked; **Continue until finished** switches it to
`automatic`. Trigger rounds and delegated children keep their own limits.

### Counters

The receipt keeps the counters durably, in task turns, which are cumulative
across continuation rounds:

| Field | Meaning |
| --- | --- |
| `next_check_turn` | When the next check is due: `check_in_turns` after the last check, or half that after an uncertain answer |
| `allowance_base` | The later of the last answered check-in and the last operator Continue |
| `allowance_source` | `check_in`, `operator` or `start` |

The **effective ceiling** is `allowance_base + turn_limit`. An answered check
at task turn `t` sets `allowance_base` to `t`. An unanswered check only moves
`next_check_turn`. Continue after any pause starts the successor with
`allowance_base` at the current task turn, source `operator`, and the next
check a full interval ahead.

With no answers at all, a checked round pauses at `turn_limit`, exactly like a
manual one. An engine outage costs at most `turn_limit` turns past the last
answered check-in. The round never pauses just because the judge was
unreachable.

The effective ceiling replaces the numeric limit throughout the loop: the
`while` test, the `limit` that turn participants receive, the model's remaining
budget, the next request's `at_limit` marker, delegation's final-turn rule and
drain-then-collect. Delegation therefore stays usable past 24 turns while the
judge keeps answering. The budget advisory says the round has periodic progress
check-ins instead of counting down. Reaching the effective ceiling behaves as
it does in manual mode: drain, collect, pause.

### When the check runs

The check runs in `run_round` once a turn's result is final, after its
`turn/end` is durable, and before the next request is recorded. Turns that
finished the task, were cancelled, asked questions or suspended for children
are skipped, and so is a collection turn. The next eligible turn checks
instead. The check blocks the next model call, bounded by its 10 s deadline.

### State

```json
{
  "setting": "A coding assistant is working on the operator's request by writing code that the harness runs. Turns are listed from older to newer. Each has the assistant's response and a short result.",
  "request": "Make quoted keys round-trip in the printer and the parser.",
  "latest_operator_message": "Also keep the old error message.",
  "earlier_turns_omitted": true,
  "turns": [
    {"response": "…", "result": "Patched src/parser.gene. Error: test_quoted_keys failed"},
    {"response": "…", "result": "Error: test_quoted_keys failed"}
  ]
}
```

- **The request** is the task root's original prompt, capped at 16 KiB. The
  current round's prompt is added as `latest_operator_message` when it differs.
- **Turns** are the task's last 30, across continuation rounds and restarts.
  Each response is the recorded, elided `turn/response` text, capped at 16 KiB.
- **Results** come from the turn's `turn/end` record. Each turn records a short
  `result_line` and an `evidence` map: Outcome kind, patched files, the first
  error line, and a digest of everything the code produced. They are built from
  the loop's own results, never from the assistant's prose. The model-written
  Outcome prompt is excluded. Turns recorded before this field existed get a
  line rebuilt from their `turn/patch` and `turn/end` records.
- **No numbers.** The state carries no turn numbers, counts or durations.
- **Trimming.** The oldest turns are dropped until the state fits the engine's
  reported limits, and `earlier_turns_omitted` says so. If the engine still
  rejects the size, half the remaining turns are dropped and the check retries
  within its deadline.
- **The state is untrusted.** Responses are model-written. The answer only
  chooses between continuing and pausing, so the worst case is a missed pause.

### Questions

```json
{
  "progress": {"type": "choice",
    "instructions": "Which describes the assistant's most recent turns?",
    "criteria": {
      "advancing": "The assistant is making steady progress on the operator's request.",
      "verifying": "The requested work looks complete and the assistant is testing or checking it.",
      "repeating": "The assistant keeps trying the same approach and gets the same failure, or undoes and redoes its own changes.",
      "blocked": "The assistant needs something only the operator can provide, such as a decision, a credential, access or missing information.",
      "drifting": "The assistant is working on something the operator did not ask for."}},
  "operator_now": {"type": "noul",
    "instructions": "The operator would want to look at this work before the assistant continues."}
}
```

### The unchanged-loop rule

One rule decides without an engine: when each of the last three turns has an
error, the same error, no changed file and identical results, the round pauses
with verdict `repeating`. Anything short of that goes to the engine: an
identical response with changing results, such as polling a job; the same
failing test after distinct edits; the same error with different output.

### Fusion

| Condition | Action |
| --- | --- |
| The rule fired | Pause, with the rule's evidence |
| `blocked` ≥ 0.7 | Pause |
| `repeating` ≥ 0.7, or `drifting` ≥ 0.7 | Pause, with that verdict |
| `operator_now` ≥ 0.85 | Pause |
| `advancing` or `verifying` ≥ 0.7, and `operator_now` < 0.5 | Continue |
| Anything else | Continue, and check again after half the interval |
| No answer | Continue; the `turn_limit` fallback applies |

The bands read class probabilities, never an engine's `confidence` statistic.
They are provisional until a labeled set calibrates them per engine, model and
question-set version (`check_in/questions-1`, `check_in/fusion-1`).

### Pausing

A pause verdict is its own boundary. No further parent model call runs, and no
collection turn runs. The next request is recorded unsent. The receipt ends:

```gene
{^state "paused" ^reason "check_in" ^continuation_mode "checked"
 ^check_in {^verdict "blocked" ^probabilities {...} ^operator_now 0.2 ^engine "jev"
            ^model "jev-1.14.0" ^latency_ms 140 ^evidence "..." ^boundary 40 ^key "..."}
 ^notice "Paused after turn 40: The assistant needs something only the operator can provide, ... Continue, or tell it what to change."
 ^children_running false ...}
```

The session is flagged for attention, and the browser shows
**Paused · progress check-in** with the notice. A fallback pause in checked
mode keeps reason `turn_limit` and carries the last check-in's status in
`check_in`, with a notice saying no check-in answered.

The check-in never enters model context. Continue, Continue until finished,
Stop and new input work as for any operator pause. New input supersedes the
paused task, and a Slack `!replace-paused` accepts a check-in pause like a
manual one.

**Running children** are neither cancelled nor collected at a check-in pause.
They keep running under their own budgets, and the notice says so. Continue
hands them to the successor: on its first turn it adopts the paused round's
unfinished children and unseen results, and receives their results like its
own. Stop, or new input that supersedes the pause, settles them the way an
ended round does: unfinished children are cancelled and their results carry
to the next round.

### Records

Each check-in is a durable `round/state` record under the key
`check_in/<round>/<task turn>`:

- the use, round, task root, boundary task turn and session turn;
- the window: first and last turn, turns sent, turns trimmed;
- the state-builder, question-set and fusion versions;
- the engine, model, selection source, status, answers and latency;
- the rule match, action, verdict and evidence;
- a digest of the exact input, and the input itself. Jev's and plugin engines'
  input is a content-addressed blob (`input_ref`). The `model` engine's is the
  call's own `model/request` record (`model_call`);
- the counters after the check.

The record is committed before the next model call. A committed boundary is
never asked again, including after a restart. A check that was in flight with
nothing committed is simply asked again, since it has no side effects. Stale
and cancelled answers commit nothing.

## Evaluation

The specs are model-free. `tests/unit/runtime/check_ins_spec.gene` covers
validation, reply mapping, result lines, the rule's fixtures, fusion and
trimming. `tests/integration/runtime/check_ins_spec.gene` covers these cases end
to end with a scripted engine:

- continuing past the limit with delegation still usable;
- pausing early while a child runs, then Continue adopting it;
- an outage that pauses at the fallback, then Continue;
- an answered check followed by an outage across a restart;
- Stop during a slow check;
- the unchanged-loop rule;
- mode selection;
- replacement by new input;
- `decide` from response code;
- the `model` engine.

`probes/check_in_bench.gene` is the opt-in bench:

- `--synthetic` runs the constructed cases in
  `tests/fixtures/check_in_cases.gene` (clean progress, verifying, repeating
  attempts, a credential block, drift, polling, distinct edits, an unchanged
  loop). `--pad TOKENS` brings them to real packed sizes, `--reversed`
  reverses option order, and `--engine jev` asks Jev.
- `--replay EVENTS_DIR` rebuilds every 10-turn boundary of a stopped
  workspace's recorded sessions. It reports the rule's and engine's decisions
  separately, with what the operator did within the next interval as a tuning
  signal. A Continue can mean "I accept the cost" and a Stop can mean "done",
  so those signals are not labels. `--labels FILE` takes human labels
  `{^session ^task_root ^boundary ^label "pause"|"continue"}` and reports
  correct, false and missed pauses. Split labeled sets by task and session,
  never by overlapping windows.

- `--engine model --workspace NEW_DIR --provider NAME [--model ID] [--effort L]`
  runs the synthetic cases through the `model` engine and the real decision
  service, to compare it with `jev` on the same cases (run it with `--snapshot`).
- `--replay EVENTS_DIR --label-template FILE` writes one entry per boundary with
  the request and the last five results, for a person to set each `^label` to
  `"pause"` or `"continue"`. Pass the filled file as `--labels`.

`probes/check_in_live.gene NEW_DIR` runs one scripted, model-free round in a
fresh workspace with whatever engine the host selects, and prints its check-in
records.

Replaying recorded sessions to a cloud engine sends real transcripts and needs
`--allow-cloud`. Whether real transcripts may go to TypeSafe is still the
owner's decision.

## Trigger rounds, delegated children and channel messages

The same service serves three more uses. Each has its own `use` id, so each can
have its own engine under `^uses` in the `decisions` setting.

| Use | Where | Default without an answer |
| --- | --- | --- |
| `trigger/check_in` | A trigger round, every `check_in_turns` of its own turns | The round runs to `trigger_turn_limit`, as before |
| `delegation/check_in` | A delegated child, every `check_in_turns` of its own turns | The child runs to its own turn limit and deadline, as before |
| `channel/addressed` | A top-level channel message that starts work without mentioning the assistant | The route's own rule: the message starts work |

- **Trigger rounds and children** use the same state, questions, rule and
  fusion bands as operator check-ins, and the same durable record
  (`check_in/<round>/<turn>`). Nothing pauses, because neither has an operator
  to continue it. A pause verdict **ends the round early**, as `failed`, with
  reason `check_in` and the message `ended at a progress check-in (<verdict>):
  <evidence>`. A trigger's failure is recorded as for any failed round. A
  child's failed result, with that evidence, is its report to the parent, so
  the parent can decide what to do next. An `uncertain` or unanswered check
  re-checks after half the interval, or at the next interval. The settings
  `check_ins` and `check_in_turns` apply.
- **Channel messages.** When a route does not require a mention and a top-level
  message does not mention the assistant, the handoff asks one `choice`
  question, `audience`, with options `assistant`, `people` and `unclear`, with
  a 1.5 s deadline and only the latest message as state. Only `people` at 0.7
  or more holds the message back, as if the route required a mention. Any
  other answer, and any other status, keeps the route's rule. Replies in an
  existing thread are not asked.

## Not implemented yet

- Voice turn-taking on this service.
- A human-labeled set. The bench's label format and report are ready for one.
