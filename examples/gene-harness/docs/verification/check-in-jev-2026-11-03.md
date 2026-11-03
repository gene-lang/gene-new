# Jev on round check-in states, 2026-11-03

`probes/check_in_bench.gene --synthetic --engine jev` sent the constructed
cases in `tests/fixtures/check_in_cases.gene` to `jev-1.14.0` from a Mac. No
recorded transcripts were sent. Each case is a task request and three or four
turns, optionally padded in front with earlier progress turns, to reach a real
packed size.

```text
TYPESAFE_API_KEY=… ../../bin/gene run probes/check_in_bench.gene --synthetic --engine jev [--pad TOKENS] [--reversed] [--rounds N]
```

## Answers

The rule decided `unchanged_failure_loop` without asking Jev. Of the seven
engine cases, six matched the written expectation at every size and in both
option orders. The results were stable across repeated rounds.

| Case | Expected | Jev | Notes |
| --- | --- | --- | --- |
| clean_progress | continue | continue, uncertain | advancing 0.52–0.69, under the 0.7 band; the next check comes after half the interval |
| verifying | continue | continue | verifying 0.99–1.0 |
| repeating_attempts | pause | pause, repeating | repeating 1.0 |
| blocked_on_credential | pause | pause, blocked | blocked 1.0 |
| drifting | pause | pause, drifting | drifting 1.0 |
| polling_job | continue | continue | advancing 0.75–0.95 |
| same_failure_distinct_edits | continue | pause, repeating | repeating 0.85–0.91. Three different edits that all failed the same test; a person could label it either way |

`operator_now` was compressed, as in the voice smoke test: 0.23–0.42 for the
continue cases and 0.61–0.83 for the pause cases. Nothing reached the 0.85
band, so that band never fired here.

## Size and latency

The service first estimated 3.5 bytes per token. For these code-heavy states
Jev reported about 1.46 times that estimate (2.4 bytes per token), and a state
the estimate put at 24k tokens was rejected as too large. The estimate is now
2.4 bytes per token. With it, the estimate tracked Jev's count to within 2%
(31.5k estimated, 31.9k reported). The Jev row also reports limits of 60k and
30k, a margin under the documented 64k and 32k.

| Packed size (reported input tokens) | p50 | p95 | max |
| --- | --- | --- | --- |
| about 500 | 81 ms | 100 ms | 136 ms |
| about 9k | 140–173 ms | 196–222 ms | 236 ms |
| about 17.5k | 176 ms | 208 ms | 233 ms |
| about 21k | 184 ms | 203 ms | 291 ms |
| about 26.6k | 276 ms | 311 ms | 318 ms |
| about 32k | 274 ms | 281 ms | 323 ms |

The check-in timeout is 10 s, so latency is not a constraint at these sizes.

## The `model` engine on the same cases

`--engine model` runs the real decision service on a fresh workspace, so its
call is selected, recorded under `decision/round/check_in` and validated like a
check-in's. Run with OpenRouter and `deepseek/deepseek-v4-flash-0731` at effort
low (synthetic cases only):

```text
OPENROUTER_API_KEY=… ../../bin/gene run --snapshot probes/check_in_bench.gene --synthetic --engine model --workspace NEW_DIR --provider openrouter --model deepseek/deepseek-v4-flash-0731 --effort low
```

| Run | Valid answers | Matched the expected action | Not valid |
| --- | --- | --- | --- |
| Output cap 1,024 tokens | 4 of 7 | 4 of 4 | 2 truncated; 1 rejected by central validation (`operator_now` was not a map) |
| Output cap 4,096 tokens (now the default) | 6 of 7 | 6 of 6 | 1 truncated |

Latency was seconds, against about 0.1–0.3 s for Jev: p50 6.3 s, p95 16.5 s and
max 26 s with the larger cap. The model also scored `same_failure_distinct_edits`
as `uncertain` (0.6) rather than `repeating`. A non-valid answer is a status
(`error`), never a pause or an accepted "continue", so the round falls back to
the turn limit. Single runs of one model differ between runs, so this shows the
path works, not which engine is better.

## Through the loop

`probes/check_in_live.gene NEW_DIR` runs a scripted, model-free round in a fresh
workspace with the key set. The round was admitted as `checked`, because Jev
was available. Six turns of passing cases were followed by four retries of one
failing spec, each reported as output rather than an error, so the rule stayed
out. The check at turn 10 went through the service to Jev. In 208 ms it
returned `repeating` 1.0 and `operator_now` 0.73. The round paused with reason
`check_in` and the notice, and its input was stored as a blob.

## Limits of this evidence

These are eight hand-written cases, so they show that the request shape and
bands work, not how accurate Jev is. Real long tasks and a human-labeled set are
still needed (docs/decisions.md, Evaluation).
